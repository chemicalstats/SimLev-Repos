// src/withdrawal_core.cpp
// Entnahme-Simulationen (Decumulation) fuer SimLev
//
// Bewusst getrennt von simulation(): Die Entnahmephase rechnet auf
// Periodenrenditen (historische Kohorten, Bootstrap-Pfade oder gespeicherte
// Ergebnisse von simulation()/bootstrap_study()).
//
// Enthaelt
//   * rule_amount  : Zustandsautomat aller Entnahmeregeln
//   * .wd_simulate : schneller Monte-Carlo-/Kohorten-Kern ueber viele Pfade
//                    mit vereinfachter deutscher Besteuerung
//
// Zeitkonvention (Guyton & Klinger 2006, Suarez et al. 2015): Die Jahresentnahme
// wird zu Beginn eines Planjahres festgelegt; mit Periodenschritten (Monat,
// Quartal) wird sie gleichmaessig zu Periodenbeginn (oder -ende) ausgezahlt.
//
// Regeln (Parameter dezimal; die R-Schicht rechnet die Prozent-Konvention um):
//   1 constant        Bengen (1994) / Trinity: W1 = rate * P1, danach W * Inflation
//   2 percent         W = rate * P
//   3 vanguard        Vanguard Dynamic Spending: rate * P, real begrenzt auf
//                     [-floor, +ceiling] ggue. Vorjahr (Standard -2,5 % / +5 %)
//   4 guyton_klinger  Guyton & Klinger (2006): Withdrawal-, Capital-Preservation-
//                     und Prosperity-Rule
//   5 floor_ceiling   Bengen (2001): rate * P in [W1_real*(1-floor), W1_real*(1+ceiling)]
//   6 clyatt          Clyatt 95 %: max(rate * P, 0.95 * W_vorjahr)
//   7 ratchet         Kitces: konstant real, +raise wenn P_real > thr * P1_real,
//                     hoechstens alle gap Jahre
//   8 endowment       Yale/Tobin: lambda * W_vj * Infl + (1 - lambda) * rate * P
//   9 one_over_n      P / Restjahre
//  10 vpw             Bogleheads VPW: P * PMT(r, max_age - age)
//  11 abw             Amortisation: PMT(r_real, Restjahre, P_real - FV_disk)
//  12 cape            (a + b / CAPE) * P
//  13 sensible        Basis (rate * P1 real) + e * realer Vorjahresgewinn
//  14 hebeler         Autopilot II: lambda * W_vj * Infl + (1 - lambda) * PMT(r, Restjahre) * P

#include <Rcpp.h>
#include <cmath>
#include <algorithm>
#include <limits>
using namespace Rcpp;

// Parameter-Slots (siehe R: .wd_param_vector)
enum { P_RATE = 0, P_CEIL, P_FLOOR, P_CUT, P_RAISE, P_CPR_YEARS, P_INFL_CAP, P_SMOOTH,
       P_EXP_RET, P_HORIZON, P_CAPE_A, P_CAPE_B, P_RATCH_THR, P_RATCH_GAP, P_EXTRA,
       P_MIN_REAL, P_MAX_REAL, P_AGE, P_MAX_AGE, P_FV, P_FLOOR95, P_SKIP_NEG, P_MAX_RATE,
       P_N };
// Zustands-Slots
enum { S_T = 0, S_WPREV, S_W1, S_P1, S_WR0, S_LAST_RATCH, S_PREAL_AFTER, S_CPI1, S_N };

static inline double pmt_due(double r, double n) {          // Annuitaet (vorschuessig) je 1 Kapital
  if (n <= 1.0) return 1.0;
  if (std::fabs(r) < 1e-12) return 1.0 / n;
  return r / ((1.0 - std::pow(1.0 + r, -n)) * (1.0 + r));
}

// Kern der Regelberechnung. P: Depotwert vor der Entnahme (nominal),
// infl_prev: Brutto-Inflation seit der letzten Festlegung, cpi_rel: CPI_t / CPI_0,
// r_prev: Depotrendite des Vorjahres (netto, z. B. -0.12), years_rem: Restjahre
// inkl. aktuellem Jahr. Rueckgabe: nominaler Jahresbetrag; st wird fortgeschrieben.
static double rule_amount(int rule, const double* rp, double* st, double P, double infl_prev,
                          double cpi_rel, double r_prev, double cape, double years_rem) {
  st[S_T] += 1.0;
  const double t = st[S_T];
  const double rate = rp[P_RATE];
  double W = 0.0;
  if (P < 0) P = 0;
  const bool first = (t <= 1.0);
  if (first) { st[S_P1] = P; st[S_CPI1] = cpi_rel; st[S_LAST_RATCH] = 1.0; }
  const double W1_real = st[S_W1] / std::max(st[S_CPI1], 1e-12);

  switch (rule) {
  case 1: W = first ? rate * P : st[S_WPREV] * infl_prev; break;
  case 2: W = rate * P; break;
  case 3: {
    if (first) { W = rate * P; break; }
    double base = st[S_WPREV] * infl_prev, target = rate * P;
    W = std::min(std::max(target, base * (1.0 - rp[P_FLOOR])), base * (1.0 + rp[P_CEIL]));
    break; }
  case 4: {
    if (first) { W = rate * P; break; }
    W = st[S_WPREV];
    double inc = std::min(infl_prev, 1.0 + rp[P_INFL_CAP]);
    double cand = W * inc;
    bool skip = rp[P_SKIP_NEG] > 0.5 && r_prev < 0.0 && (P <= 0 || cand / P > st[S_WR0]);
    if (!skip) W = cand;
    double wr = P > 0 ? W / P : std::numeric_limits<double>::infinity();
    if (wr > st[S_WR0] * (1.0 + rp[P_CEIL]) && years_rem > rp[P_CPR_YEARS]) W *= (1.0 - rp[P_CUT]);
    else if (wr < st[S_WR0] * (1.0 - rp[P_FLOOR])) W *= (1.0 + rp[P_RAISE]);
    break; }
  case 5: {
    if (first) { W = rate * P; break; }
    W = std::min(std::max(rate * P, (1.0 - rp[P_FLOOR]) * W1_real * cpi_rel), (1.0 + rp[P_CEIL]) * W1_real * cpi_rel);
    break; }
  case 6: W = first ? rate * P : std::max(rate * P, rp[P_FLOOR95] * st[S_WPREV]); break;
  case 7: {
    if (first) { W = rate * P; break; }
    W = st[S_WPREV] * infl_prev;
    double p_real = P / cpi_rel, p1_real = st[S_P1] / st[S_CPI1];
    if (p_real > rp[P_RATCH_THR] * p1_real && t - st[S_LAST_RATCH] >= rp[P_RATCH_GAP]) {
      W *= (1.0 + rp[P_RAISE]); st[S_LAST_RATCH] = t;
    }
    break; }
  case 8: W = first ? rate * P : rp[P_SMOOTH] * st[S_WPREV] * infl_prev + (1.0 - rp[P_SMOOTH]) * rate * P; break;
  case 9: W = P / std::max(1.0, years_rem); break;
  case 10: {
    double n = rp[P_MAX_AGE] - (rp[P_AGE] + t - 1.0);
    double pct = (n <= 1.0) ? 1.0 : std::min(pmt_due(rp[P_EXP_RET], n), rp[P_MAX_RATE]);
    W = pct * P; break; }
  case 11: {
    double r = rp[P_EXP_RET], n = std::max(1.0, years_rem);
    double p_real = P / cpi_rel, fv_disc = rp[P_FV] / std::pow(1.0 + r, n);
    W = std::max(0.0, (p_real - fv_disc) * pmt_due(r, n)) * cpi_rel; break; }
  case 12: W = (rp[P_CAPE_A] + (cape > 0 ? rp[P_CAPE_B] / cape : 0.0)) * P; break;
  case 13: {
    double base = first ? rate * P : W1_real * cpi_rel;
    double gain = first ? 0.0 : std::max(0.0, P / cpi_rel - st[S_PREAL_AFTER]);
    W = base + rp[P_EXTRA] * gain * cpi_rel; break; }
  case 14: {
    double n = std::max(1.0, years_rem);
    double pm = pmt_due(rp[P_EXP_RET], n) * P;
    W = first ? pm : rp[P_SMOOTH] * st[S_WPREV] * infl_prev + (1.0 - rp[P_SMOOTH]) * pm; break; }
  default: stop("Unbekannte Entnahmeregel %d", rule);
  }
  // Reale Unter-/Obergrenze (absolute Betraege in Startkaufkraft)
  if (rp[P_MIN_REAL] > 0) W = std::max(W, rp[P_MIN_REAL] * cpi_rel);
  if (std::isfinite(rp[P_MAX_REAL])) W = std::min(W, rp[P_MAX_REAL] * cpi_rel);
  if (!std::isfinite(W) || W < 0) W = 0.0;
  if (first) { st[S_W1] = W; st[S_WR0] = P > 0 ? W / P : 0.0; }
  st[S_WPREV] = W;
  st[S_PREAL_AFTER] = std::max(0.0, P - W) / cpi_rel;
  return W;
}

// ---------------------------------------------------------------------------
// Vereinfachte Steuer (ein Fondsbestand, Durchschnittskosten = FIFO bei einer
// Einmalanlage): Verkaufsbetrag G so, dass netto X uebrig bleibt.
// ---------------------------------------------------------------------------
struct TaxState { double loss, spb; };

// Steuer auf einen Verkaufserloes-Gewinn 'gain' (vor Teilfreistellung); mutiert Toepfe
static double tax_on_gain(double gain, double tfs, double rate, TaxState& ts) {
  double taxable = gain * (1.0 - tfs);
  if (taxable <= 0) { ts.loss += -taxable; return 0.0; }
  double use = std::min(ts.loss, taxable); ts.loss -= use; taxable -= use;
  use = std::min(ts.spb, taxable); ts.spb -= use; taxable -= use;
  return taxable * rate;
}

// Brutto-Verkauf G fuer Netto-Ziel X (geschlossene Form, stueckweise linear)
static double gross_for_net(double X, double V, double basis, double tfs, double rate, double cost,
                            const TaxState& ts, bool tax_on) {
  double keep = 1.0 - cost;
  if (X <= 0) return 0.0;
  if (!tax_on || V <= 0) return X / keep;
  double g = keep - basis / V;                 // Gewinnanteil je Euro Verkauf (nach Kosten)
  if (g <= 0) return X / keep;
  double a = g * (1.0 - tfs), A = ts.loss + ts.spb;
  if ((X / keep) * a <= A) return X / keep;
  return (X - A * rate) / (keep - a * rate);
}

//' Schneller Entnahme-Kern
//' @keywords internal
// [[Rcpp::export(name = ".wd_simulate")]]
List wd_simulate(NumericMatrix R, NumericMatrix INF, NumericMatrix CAPE, NumericMatrix BASE,
                 int ppy, int rule, NumericVector rp, bool start_timing,
                 double start_value, NumericVector income_real,
                 bool tax_on, double tax_rate, double tfs, double spb_annual, bool vp_on,
                 double cost, double basis_ratio, double loss0, bool keep) {
  const int np = R.nrow(), paths = R.ncol();
  const int ny = (np + ppy - 1) / ppy;
  const bool has_cape = CAPE.ncol() > 0;
  NumericMatrix wealth(keep ? ny + 1 : 0, keep ? paths : 0);    // real, Jahresanfang
  NumericMatrix spend(ny, paths);                                 // real, Konsum je Planjahr
  NumericMatrix planned(ny, paths);                               // real, geplante Entnahme
  NumericVector terminal(paths), terminal_nom(paths), taxes(paths), depl(paths), fail(paths);
  NumericVector st(S_N);

  for (int k = 0; k < paths; k++) {
    std::fill(st.begin(), st.end(), 0.0);
    double u = 1.0, n = start_value, basis = start_value * basis_ratio, cpi = 1.0, cpi_dec = 1.0;
    double yr_ret = 1.0, W = 0.0, vp_due = 0.0, u0 = 1.0, tax_sum = 0.0;
    TaxState ts{loss0, spb_annual};
    bool failed = false; double depl_p = NA_REAL;
    for (int p = 0; p < np; p++) {
      int y = p / ppy, ypos = p % ppy;
      double V = n * u;
      if (ypos == 0) {
        if (keep) wealth(y, k) = V / cpi;
        ts.spb = spb_annual;                                     // neues Steuerjahr
        double infl_prev = (y == 0) ? 1.0 : cpi / cpi_dec;
        double cp = has_cape ? CAPE(p, k) : 0.0;
        W = rule_amount(rule, rp.begin(), st.begin(), V, infl_prev, cpi, yr_ret - 1.0, cp, (double)(ny - y));
        planned(y, k) = W / cpi;
        cpi_dec = cpi; yr_ret = 1.0; u0 = u;
      }
      double inc = income_real[std::min(y, (int) income_real.size() - 1)] * cpi / ppy;
      double need = std::max(0.0, W / ppy - inc);
      // Entnahme (Beginn oder Ende der Periode)
      auto withdraw = [&](void) {
        double target = need + vp_due;
        double paid_vp = 0.0, paid = 0.0;
        V = n * u;
        if (target > 0 && V > 0) {
          double G = gross_for_net(target, V, basis, tfs, tax_rate, cost, ts, tax_on);
          bool all = false;
          if (G >= V) { G = V; all = true; }
          double bpart = basis * G / V;
          double tax = tax_on ? tax_on_gain(G * (1.0 - cost) - bpart, tfs, tax_rate, ts) : 0.0;
          double net = G * (1.0 - cost) - tax;
          tax_sum += (tax + vp_due) / cpi;
          basis -= bpart; n -= G / u; if (all) { n = 0.0; basis = 0.0; }
          paid_vp = std::min(net, vp_due); paid = net - paid_vp;
          tax_sum -= (vp_due - paid_vp) / cpi;                    // nicht beglichene VP nicht zaehlen
        }
        vp_due = 0.0;
        spend(y, k) += (paid + inc) / cpi;
        if (paid < need - 1e-8 * std::max(1.0, need)) {
          if (!failed) { failed = true; depl_p = p + 1; }
        }
      };
      if (start_timing) withdraw();
      u *= R(p, k);
      if (u < 0) u = 0;
      cpi *= INF(p, k);
      yr_ret *= R(p, k);
      if (!start_timing) withdraw();
      // Jahresende: Vorabpauschale (§ 18 InvStG), faellig zu Beginn des Folgejahres
      if (ypos == ppy - 1 && tax_on && vp_on && n > 0) {
        double br = std::max(0.0, BASE(p, k)) / 100.0;
        double vp_ps = std::max(0.0, std::min(u0 * 0.7 * br, u - u0));
        double vp = n * vp_ps;
        if (vp > 0) {
          vp_due += tax_on_gain(vp, tfs, tax_rate, ts);
          basis += vp;                                          // § 19 InvStG: Anrechnung beim Verkauf
        }
      }
    }
    double Vend = n * u;
    if (keep) wealth(ny, k) = Vend / cpi;
    terminal[k] = Vend / cpi; terminal_nom[k] = Vend; taxes[k] = tax_sum;
    fail[k] = failed ? 1.0 : 0.0; depl[k] = depl_p;
  }
  return List::create(Named("wealth") = wealth, Named("spending") = spend, Named("planned") = planned,
                      Named("terminal_real") = terminal, Named("terminal_nominal") = terminal_nom,
                      Named("taxes_real") = taxes, Named("failed") = fail, Named("depletion_period") = depl);
}
