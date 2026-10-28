// core/withdrawal_core_impl.h
// Entnahme-Simulationen (Decumulation) fuer SimLev, reine Rechnung ohne R und Python
//
// GEMEINSAME QUELLE FUER R UND PYTHON (Etappe 7.3a): R ruft den Kern ueber die
// .Call-Huelle in r/src/withdrawal_core.cpp auf (sie wandelt nur die R-Objekte um),
// Python ueber das Erweiterungsmodul simlev._ext (python/src/_ext_withdrawal.cpp).
// Kanonisch in core/ (seit Etappe 9.6c, F16); R und Python bauen aus
// Byte-fuer-Byte-Kopien in r/src/ bzw. python/src/core/ (tools/core_sync.py
// --write/--check); Aenderungen nur in core/ vornehmen und danach kopieren.
// Die Python-Huelle (simlev/_withdrawal_core.py) ruft nur noch diesen Kern; der reine
// Python-Kern als Rueckfall ist seit 9.6c entfallen.
//
// Aufbau wie alle C++-Kerne (simlev_core.h): statische Funktionen ueber den Sichten
// simlev_host::NumVec/IntVec/NumMat und den Host-Makros SIMLEV_* (Fehler, NA,
// Anlegen der Ergebnisse), die die einbindende Huelle festlegt (R: simlev_capi.h,
// Python: _ext_common.h). Die Rechnung ist Zeile fuer Zeile die fruehere aus
// withdrawal_core.cpp; fuer R setzen die Makros genau die frueheren Aufrufe ein, der
// Compiler erzeugt daher denselben Maschinencode wie vor der Teilung (geprueft per
// Disassemblierung).
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
//   4 guyton_klinger  Guyton & Klinger (2006): Entnahme- (Withdrawal), Kapitalerhalt- (Capital-Preservation)
//                     und Wohlstandsregel (Prosperity Rule)
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

#ifndef SIMLEV_WITHDRAWAL_CORE_IMPL_H
#define SIMLEV_WITHDRAWAL_CORE_IMPL_H

// Gleitkomma wie im Pilot (simlev_core.h): Abbruch bei -ffast-math; kein
// Zusammenziehen von a * b + c zu fma. Das Pragma steht nur dort, wo der Compiler
// fma ueberhaupt erzeugen kann (__FP_FAST_FMA, etwa aarch64 oder -mfma): auf
// x86-64 ohne FMA ist -ffp-contract=off wirkungslos, das GCC-Pragma optimize
// veraendert dort aber die Codeerzeugung der ganzen Datei (geprueft), und R soll
// denselben Maschinencode wie vor der Teilung ausfuehren. Python baut immer mit
// -ffp-contract=off (setup.py) und setzt SIMLEV_FP_CONTRACT_BY_FLAG.
#if defined(__FAST_MATH__)
#error "Gemeinsame Kerne duerfen nicht mit -ffast-math uebersetzt werden (Bitgleichheit)."
#endif
#if defined(__clang__)
#pragma STDC FP_CONTRACT OFF
#elif defined(_MSC_VER)
#pragma fp_contract (off)
#elif defined(__GNUC__) && (defined(__FP_FAST_FMA) || defined(__FP_FAST_FMAF)) && !defined(SIMLEV_FP_CONTRACT_BY_FLAG)
#pragma GCC optimize ("fp-contract=off")
#endif

#include "simlev_core.h"
#if !defined(SIMLEV_NA) || !defined(SIMLEV_FAIL) || !defined(SIMLEV_NUM)
#error "Vor diesem Kern den Host einbinden: R simlev_capi.h, Python _ext_common.h (siehe simlev_core.h)."
#endif

#include <cmath>
#include <algorithm>
#include <limits>
#include <vector>

namespace simlev {

// Parameter-Slots (siehe R: .wd_param_vector)
// Restjahre kommen aus der Zahl der Planjahre (years_rem), nicht aus der Regel.
enum { P_RATE = 0, P_CEIL, P_FLOOR, P_CUT, P_RAISE, P_CPR_YEARS, P_INFL_CAP, P_SMOOTH,
       P_EXP_RET, P_CAPE_A, P_CAPE_B, P_RATCH_THR, P_RATCH_GAP, P_EXTRA,
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
  default: SIMLEV_FAIL("Unbekannte Entnahmeregel %d", rule);
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
// Einmalanlage): Verkaufsbetrag G so, dass netto X uebrig bleibt. Mit den Lots
// einer Ansparphase (FifoLots, unten) wird stattdessen nach FIFO verkauft.
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

// ---------------------------------------------------------------------------
// FIFO-Bestand aus den offenen Lots der Ansparphase (simulation()$open_lots).
// Einheit = Depotanteil mit Wert 1 EUR zu Beginn (wie n im Kern); Lot j hat
// n0[j] Einheiten, Anschaffungskosten bu[j] und anzurechnende Vorabpauschale
// vpu[j] je Einheit. Gruppen = Assets (je Gruppe FIFO-Reihenfolge) plus ggf.
// eine Cash-Gruppe (Basis = Betrag). Alle Gruppen haben in der Entnahmephase
// dieselbe Rendite; Verkaeufe nehmen jeder Gruppe ihren Wertanteil w[g]
// (konstant), innerhalb der Gruppe nach FIFO. Neue Vorabpauschalen sind je
// Einheit fuer alle Lots gleich (alle ganzjaehrig gehalten) und stehen in
// vp_acc. Zustand je Pfad: FIFO-Zeiger und Rest des vordersten Lots je Gruppe.
// ---------------------------------------------------------------------------
struct FifoLots {
  int ng = 0;
  std::vector<double> n0, bu, vpu, w;
  std::vector<int> gs, ge;              // Gruppenbereiche [gs, ge)
  std::vector<int> ptr; std::vector<double> nf;
  double vp_acc = 0.0;
  void reset() {
    for (int g = 0; g < ng; g++) { ptr[g] = gs[g]; nf[g] = n0[gs[g]]; }
    vp_acc = 0.0;
  }
  // Verkauf fuer Netto-Ziel X bei Anteilswert u: Gewinn je Lot (Erloes x (1 - cost) minus
  // Anschaffungskosten minus VP-Anrechnung) wird ueber alle verkauften Lots summiert und wie im
  // Durchschnittsmodell versteuert (Teilfreistellung, Topf, Pauschbetrag, Satz).
  // Rueckgabe: Brutto-Verkauf G; gain = Summe der Gewinne; all = Bestand aufgebraucht.
  double sell(double X, double u, double keep, double tfs, double rate, const TaxState& ts,
              double& gain, bool& all) {
    const double A = ts.loss + ts.spb, c1 = 1.0 - tfs;
    double Gd = 0.0, C = 0.0; all = false;
    while (true) {
      double L = std::numeric_limits<double>::infinity(), s = 0.0; bool any = false, done = false;
      for (int g = 0; g < ng; g++) {
        if (w[g] == 0.0) continue;
        if (ptr[g] >= ge[g]) { done = true; break; }
        const int j = ptr[g];
        const double val = nf[g] * u, len = val / w[g];
        if (len < L) L = len;
        s += w[g] * (keep - (bu[j] + vpu[j] + vp_acc) * nf[g] / val);
        any = true;
      }
      if (done || !any || !std::isfinite(L)) {                         // Bestand aufgebraucht: Reste mitverkaufen
        all = true;
        for (int g = 0; g < ng; g++) {
          for (int j = ptr[g]; j < ge[g]; j++) {
            const double nn = (j == ptr[g]) ? nf[g] : n0[j];
            C += keep * nn * u - (bu[j] + vpu[j] + vp_acc) * nn; Gd += nn * u;
          }
          ptr[g] = ge[g]; nf[g] = 0.0;
        }
        break;
      }
      // Netto nach t weiteren Euro Brutto: keep (Gd + t) - rate max(0, c1 (C + s t) - A); monoton steigend
      const double T0 = c1 * C - A, k = c1 * s;
      auto net = [&](double t) { double tx = T0 + k * t; return keep * (Gd + t) - (tx > 0 ? rate * tx : 0.0); };
      double t = L;
      if (net(L) >= X) {
        double tk = (k != 0.0) ? -T0 / k : -1.0;
        double cuts[3] = {0.0, (tk > 0.0 && tk < L) ? tk : L, L};
        t = L;
        for (int q = 0; q < 2; q++) {
          double a = cuts[q], b = cuts[q + 1];
          if (b <= a && q > 0) continue;
          bool taxed = T0 + k * 0.5 * (a + b) > 0.0;
          double r = taxed ? (X - keep * Gd + rate * T0) / (keep - rate * k) : (X - keep * Gd) / keep;
          if (r <= b * (1.0 + 1e-12) + 1e-12) { t = std::min(std::max(r, a), b); break; }
        }
      }
      // t Euro Brutto verkaufen: je Gruppe w[g] t, aus dem vordersten Lot
      for (int g = 0; g < ng; g++) {
        if (w[g] == 0.0) continue;
        const int j = ptr[g];
        const double val = nf[g] * u, part = w[g] * t;
        const double cost_u = bu[j] + vpu[j] + vp_acc;
        if (std::fabs(part) >= std::fabs(val) * (1.0 - 1e-12)) {       // Lot ganz verkauft
          C += keep * val - cost_u * nf[g];
          ptr[g]++; nf[g] = ptr[g] < ge[g] ? n0[ptr[g]] : 0.0;
        } else {
          const double du = part / u;
          C += keep * part - cost_u * du;
          nf[g] -= du;
        }
      }
      Gd += t;
      if (t < L) break;
    }
    gain = C;
    return Gd;
  }
};

// Schneller Entnahme-Kern (.wd_simulate)
// Ueber den Host: SIMLEV_FAIL meldet Fehler, SIMLEV_NA liefert NA; SIMLEV_MATRIX(nr, nc)
// und SIMLEV_NUM(n) legen die Ergebnisfelder an (mit 0 gefuellt, in derselben Reihenfolge
// wie frueher), SIMLEV_LIST gibt die benannte Ergebnisliste zurueck (in R die frueheren
// Aufrufe new_mat, new_num, named_list).
static auto wd_simulate(simlev_host::NumMat R, simlev_host::NumMat INF, simlev_host::NumMat CAPE, simlev_host::NumMat BASE,
                        int ppy, int rule, simlev_host::NumVec rp, bool start_timing,
                        double start_value, simlev_host::NumVec income_real,
                        bool tax_on, double tax_rate, double tfs, double spb_annual, bool vp_on,
                        double cost, double basis_ratio, double loss0, bool keep,
                        simlev_host::NumVec lot_n, simlev_host::NumVec lot_basis,
                        simlev_host::NumVec lot_vp, simlev_host::IntVec lot_group,
                        double spb_first, bool horizon_end) {
  const int np = R.nrow(), paths = R.ncol();
  // FIFO-Lots (nur mit Steuern; ohne Lots unveraendert das Durchschnittsmodell mit basis_ratio)
  const int nlot = lot_n.size();
  if (lot_basis.size() != nlot || lot_vp.size() != nlot || lot_group.size() != nlot)
    SIMLEV_FAIL("Lot-Vektoren haben verschiedene L\u00e4ngen");
  const bool use_lots = tax_on && nlot > 0;
  FifoLots FL;
  if (use_lots) {
    double tot = 0.0;
    for (int j = 0; j < nlot; j++) {
      if (!(lot_n[j] > 0.0 || lot_n[j] < 0.0) || !std::isfinite(lot_basis[j]) || !std::isfinite(lot_vp[j]))
        SIMLEV_FAIL("Lot %d: Einheiten m\u00fcssen ungleich 0 und alle Werte endlich sein", j + 1);
      if (j > 0 && lot_group[j] < lot_group[j - 1]) SIMLEV_FAIL("Lots m\u00fcssen nach Gruppe sortiert sein");
      tot += lot_n[j];
    }
    if (!(tot > 0.0)) SIMLEV_FAIL("Summe der Lot-Einheiten muss positiv sein");
    for (int j = 0; j < nlot; j++) {
      if (j == 0 || lot_group[j] != lot_group[j - 1]) { FL.gs.push_back(j); FL.ge.push_back(j); FL.w.push_back(0.0); }
      FL.ge.back() = j + 1; FL.w.back() += lot_n[j] / tot;
      FL.n0.push_back(lot_n[j]); FL.bu.push_back(lot_basis[j] / lot_n[j]); FL.vpu.push_back(lot_vp[j] / lot_n[j]);
    }
    FL.ng = (int) FL.gs.size(); FL.ptr.assign(FL.ng, 0); FL.nf.assign(FL.ng, 0.0);
  }
  // Bereichspruefung: alle Matrizen werden mit (Periode, Pfad) gelesen
  if (ppy < 1) SIMLEV_FAIL("ppy muss >= 1 sein");
  if (rp.size() < P_N) SIMLEV_FAIL("Parametervektor zu kurz (%d statt %d)", (int) rp.size(), (int) P_N);
  if (INF.nrow() != np || INF.ncol() != paths)
    SIMLEV_FAIL("Inflationsmatrix %d x %d passt nicht zu den Renditen %d x %d", INF.nrow(), INF.ncol(), np, paths);
  const bool has_cape = CAPE.ncol() > 0;
  if (has_cape && (CAPE.nrow() < np || CAPE.ncol() != paths))
    SIMLEV_FAIL("CAPE-Matrix %d x %d passt nicht zu den Renditen %d x %d", CAPE.nrow(), CAPE.ncol(), np, paths);
  if (tax_on && vp_on && (BASE.nrow() < np || BASE.ncol() != paths))
    SIMLEV_FAIL("Basiszins-Matrix %d x %d passt nicht zu den Renditen %d x %d", BASE.nrow(), BASE.ncol(), np, paths);
  if (np > 0 && income_real.size() < 1) SIMLEV_FAIL("income_real darf nicht leer sein");
  const int ny = (np + ppy - 1) / ppy;
  auto wealth = SIMLEV_MATRIX(keep ? ny + 1 : 0, keep ? paths : 0);    // real, Jahresanfang
  auto spend = SIMLEV_MATRIX(ny, paths);                                 // real, Konsum je Planjahr
  auto planned = SIMLEV_MATRIX(ny, paths);                               // real, geplante Entnahme
  auto terminal = SIMLEV_NUM(paths), terminal_nom = SIMLEV_NUM(paths), taxes = SIMLEV_NUM(paths),
       depl = SIMLEV_NUM(paths), fail = SIMLEV_NUM(paths);
  // horizon_end: je Jahresende Endvermoegen und Steuern, als ende der Pfad dort (mit Abrechnung der offenen
  // Vorabpauschale wie am Pfadende); Zeile y + 1 = nach Planjahr y, Zeile 1 = Start
  auto wealth_end = SIMLEV_MATRIX(horizon_end ? ny + 1 : 0, horizon_end ? paths : 0),
       taxes_end = SIMLEV_MATRIX(horizon_end ? ny + 1 : 0, horizon_end ? paths : 0);
  auto st = SIMLEV_NUM(S_N);

  for (int k = 0; k < paths; k++) {
    std::fill(st.begin(), st.end(), 0.0);
    double u = 1.0, n = start_value, basis = start_value * basis_ratio, cpi = 1.0, cpi_dec = 1.0;
    double yr_ret = 1.0, W = 0.0, vp_due = 0.0, vp_pending = 0.0, u0 = 1.0, tax_sum = 0.0;
    TaxState ts{loss0, spb_annual};
    if (use_lots) FL.reset();
    bool failed = false; double depl_p = SIMLEV_NA;
    // Verkauf fuer Netto-Ziel target (FIFO-Lots oder Durchschnittskosten); setzt G, tax, all, mindert n
    auto sale = [&](double target, double V, double& G, double& tax, bool& all) {
      all = false;
      if (use_lots) {                                             // FIFO ueber die Lots der Ansparphase
        double gain = 0.0;
        G = FL.sell(target, u, 1.0 - cost, tfs, tax_rate, ts, gain, all);
        if (all) G = V;
        tax = tax_on_gain(gain, tfs, tax_rate, ts);
      } else {                                                    // Durchschnittskosten (eine Basis)
        G = gross_for_net(target, V, basis, tfs, tax_rate, cost, ts, tax_on);
        if (G >= V) { G = V; all = true; }
        double bpart = basis * G / V;
        tax = tax_on ? tax_on_gain(G * (1.0 - cost) - bpart, tfs, tax_rate, ts) : 0.0;
        basis -= bpart;
      }
      n -= G / u; if (all) { n = 0.0; basis = 0.0; }
    };
    // Abrechnung der offenen Vorabpauschale am Pfadende (wie simulation() bei Datenende am 31.12., A7-11):
    // 1. VP-Steuer vorab mit den Toepfen des Folgejahres vor dem Verkauf (neuer Pauschbetrag, Verlusttopf am
    //    Jahresende) bestimmen und per Zwangsverkauf noch im ablaufenden Jahr (dessen Toepfe) zahlen;
    // 2. endgueltige VP-Steuer mit dem Verlusttopf nach diesem Verkauf; Differenz wie .pay_vp(prepaid):
    //    Nachzahlung per Verkauf im Folgejahr (dessen Toepfe nach der VP) bzw. Erstattung ins Depot.
    // Gibt die Steuern (nominal) zurueck; ts steht danach auf den Toepfen des Folgejahres.
    auto settle_end = [&](void) -> double {
      double add = 0.0;
      if (vp_pending > 0) {
        TaxState t0{ts.loss, spb_annual};
        double vtax0 = tax_on_gain(vp_pending, tfs, tax_rate, t0);   // Vorauszahlung (Kopie der Toepfe)
        double V = n * u;
        bool paid_all = true;
        if (vtax0 > 0 && V > 0) {
          double G, tax; bool all;
          sale(vtax0, V, G, tax, all);
          double net = G * (1.0 - cost) - tax;
          add = tax + std::min(net, vtax0);                       // nicht beglichene VP nicht zaehlen
          paid_all = net >= vtax0 * (1.0 - 1e-12);
        }
        TaxState tn{ts.loss, spb_annual};                         // Folgejahr: Verlusttopf nach dem Verkauf
        double vtax1 = tax_on_gain(vp_pending, tfs, tax_rate, tn);
        vp_pending = 0.0;
        double diff = vtax1 - vtax0;
        if (paid_all && vtax0 > 0 && diff != 0.0) {
          ts = tn;                                                // Toepfe des Folgejahres nach der VP
          if (diff > 0) {
            V = n * u;
            if (V > 0) {
              double G, tax; bool all;
              sale(diff, V, G, tax, all);
              double net = G * (1.0 - cost) - tax;
              add += tax + std::min(net, diff);
            }
          } else {                                                // Erstattung als Geld ins Depot (Basis = Betrag)
            if (u > 0) { n += -diff / u; basis += -diff; }
            add += diff;
          }
        }
      }
      return add;
    };
    double V_ys = 0.0; bool plan_all = false;
    if (horizon_end) { wealth_end(0, k) = start_value; taxes_end(0, k) = 0.0; }
    for (int p = 0; p < np; p++) {
      int y = p / ppy, ypos = p % ppy;
      double V = n * u;
      if (ypos == 0) {
        if (keep) wealth(y, k) = V / cpi;
        ts.spb = (y == 0 && spb_first >= 0.0) ? spb_first : spb_annual;   // neues Steuerjahr (Jahr 1: ggf. Rest)
        // § 18 Abs. 3 InvStG: Vorabpauschale des Vorjahres gilt am ersten Werktag als zugeflossen,
        // Steuer mit Verlusttopf und Pauschbetrag dieses Jahres (wie simulation())
        if (vp_pending > 0) { vp_due += tax_on_gain(vp_pending, tfs, tax_rate, ts); vp_pending = 0.0; }
        double infl_prev = (y == 0) ? 1.0 : cpi / cpi_dec;
        double cp = has_cape ? CAPE(p, k) : 0.0;
        W = rule_amount(rule, rp.begin(), st.begin(), V, infl_prev, cpi, yr_ret - 1.0, cp, (double)(ny - y));
        planned(y, k) = W / cpi;
        cpi_dec = cpi; yr_ret = 1.0; u0 = u;
        // Verzehrregeln (one_over_n, vpw, abw, hebeler) leeren das Depot planmaessig: im Jahr, fuer das sie das
        // ganze Depot vorsehen, bzw. im letzten Planjahr, sofern der Plan das Depot (vor Steuern) nicht uebersteigt
        V_ys = V;
        plan_all = (rule == 9 || rule == 10 || rule == 11 || rule == 14) && V_ys > 0 && W <= V_ys * (1.0 + 1e-9) &&
                   (W >= V_ys * (1.0 - 1e-12) || y == ny - 1);
      }
      double inc = income_real[std::min(y, (int) income_real.size() - 1)] * cpi / ppy;
      double need = std::max(0.0, W / ppy - inc);
      // Entnahme (Beginn oder Ende der Periode)
      auto withdraw = [&](void) {
        double target = need + vp_due;
        double paid_vp = 0.0, paid = 0.0;
        V = n * u;
        if (target > 0 && V > 0) {
          double G, tax; bool all;
          sale(target, V, G, tax, all);
          double net = G * (1.0 - cost) - tax;
          tax_sum += (tax + vp_due) / cpi;
          paid_vp = std::min(net, vp_due); paid = net - paid_vp;
          tax_sum -= (vp_due - paid_vp) / cpi;                    // nicht beglichene VP nicht zaehlen
        }
        vp_due = 0.0;
        spend(y, k) += (paid + inc) / cpi;
        // Fehlschlag: geplante Entnahme nicht voll bezahlt, ausser eine Verzehrregel leert das Depot planmaessig
        // und es ist vollstaendig verkauft (Steuern und Kosten aus dem Erloes bezahlt)
        if (paid < need - 1e-8 * std::max(1.0, need) && !(plan_all && n <= 0.0)) {
          if (!failed) { failed = true; depl_p = p + 1; }
        }
      };
      if (start_timing) withdraw();
      u *= R(p, k);
      if (u < 0) u = 0;
      cpi *= INF(p, k);
      yr_ret *= R(p, k);
      if (!start_timing) withdraw();
      // Jahresende: Vorabpauschale (§ 18 InvStG) festsetzen; Steuer zu Beginn des Folgejahres
      if (ypos == ppy - 1 && tax_on && vp_on && n > 0) {
        double br = std::max(0.0, BASE(p, k)) / 100.0;
        double vp_ps = std::max(0.0, std::min(u0 * 0.7 * br, u - u0));
        double vp = n * vp_ps;
        if (vp > 0) {
          vp_pending += vp;
          basis += vp;                                          // § 19 InvStG: Anrechnung beim Verkauf
          if (use_lots) FL.vp_acc += vp_ps;                     // je Einheit fuer alle Lots gleich
        }
      }
      // Horizont nach Planjahr y (nicht am Pfadende, das folgt unten): Abrechnung probehalber, Zustand zuruecksetzen
      if (horizon_end && ypos == ppy - 1 && p < np - 1) {
        const double n_s = n, b_s = basis, vpp_s = vp_pending; const TaxState ts_s = ts;
        std::vector<int> ptr_s; std::vector<double> nf_s; const double acc_s = use_lots ? FL.vp_acc : 0.0;
        if (use_lots) { ptr_s = FL.ptr; nf_s = FL.nf; }
        double add = settle_end();
        wealth_end(y + 1, k) = n * u / cpi; taxes_end(y + 1, k) = tax_sum + add / cpi;
        n = n_s; basis = b_s; vp_pending = vpp_s; ts = ts_s;
        if (use_lots) { FL.ptr = ptr_s; FL.nf = nf_s; FL.vp_acc = acc_s; }
      }
    }
    // Pfadende: Vorabpauschale des letzten Planjahres (Steuer mit den Toepfen des Folgejahres, Zwangsverkauf im
    // ablaufenden Jahr wie simulation() am letzten Tag); die Steuer dieses Verkaufs zaehlt mit, das Endvermoegen sinkt
    tax_sum += settle_end() / cpi;
    double Vend = n * u;
    if (keep) wealth(ny, k) = Vend / cpi;
    if (horizon_end) { wealth_end(ny, k) = Vend / cpi; taxes_end(ny, k) = tax_sum; }
    terminal[k] = Vend / cpi; terminal_nom[k] = Vend; taxes[k] = tax_sum;
    fail[k] = failed ? 1.0 : 0.0; depl[k] = depl_p;
  }
  return SIMLEV_LIST("wealth", wealth, "spending", spend, "planned", planned,
                    "terminal_real", terminal, "terminal_nominal", terminal_nom,
                    "taxes_real", taxes, "failed", fail, "depletion_period", depl,
                    "wealth_end", wealth_end, "taxes_end", taxes_end);
}

}  // namespace simlev

#endif
