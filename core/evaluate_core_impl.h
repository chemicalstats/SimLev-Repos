// core/evaluate_core_impl.h
// Auswertung von simulation() als gemeinsamer C++-Kern: Depotwert und Zufluesse je Tag, CAGR
// (mit Einzahlungen geldgewichtet ueber XIRR), TTWROR, zeitgewichteter Wertindex, Drawdowns, Tagesrenditen,
// Performance- und Risikokennzahlen, mittlere Kaeufe/Verkaeufe je Jahr und die Ursachen nicht definierter
// Kennzahlen (undefined_metrics) als Codes; dazu der interne Zinsfuss xirr (.xirr_rate) fuer die Sprachen.
//
// Herkunft:           uebersetzt aus SimLev 1.3.0, r/R/sim_evaluate.R (.sim_returns, .sim_risk_stats,
//                     .sim_undefined_metrics) und r/R/sim_base.R (.xirr_rate, calculate_skewness,
//                     calculate_kurtosis, calculate_partials); Vorlage der Uebersetzung war der typisierte
//                     Julia-Port (julia/src/sim_evaluate.jl, engine.jl)
// Rechte:             SimLev (eigener Code)
// Lizenz der Vorlage: GPL-3 (SimLev)
// Aenderungen:        Warnungen, Abbrueche (NA in einer Bedingung) und die Ursachen nicht definierter Kennzahlen
//                     als Codes mit Werten (Texte in den Hosts, wortgleich zu R 1.3.0); stats::uniroot ueber
//                     sl_r_zeroin2 (core/slc_rbase.cpp); Rechenfolge wie R.
//
// GEMEINSAME QUELLE FUER R, PYTHON UND JULIA: reine Rechnung ohne Host-Objekte. R bindet sie ueber
// r/src/engine_core.cpp ein (C_sim_evaluate, C_sim_xirr), Python ueber python/src/_ext_engine.cpp (sim_evaluate,
// sim_xirr), Julia ueber core/simlev_cabi.cpp (simlev_c_eval_*, simlev_c_xirr).
// Regeln wie engine_core_impl.h: kein globaler Zustand, Rechenfolge wie R, Operationen mit zwei Operanden aus
// Eingaben ueber simlev_add/_sub/_mul/_div (NA vor NaN); sum, prod, mean, var, cumsum, cumprod, cummax,
// rowSums wie R in long double bzw. mit R's Regeln ueber core/slc_rbase.cpp (bewusste Ausnahme "kein long double").
//
// R-Semantik, die der Kern nachbildet:
//   - ifelse() mit NA im Test liefert NA_real_ (v_pre, Drawdowns bei NaN im laufenden Maximum).
//   - x[x > 0] mit NaN in x waehlt NA aus (Downside-Abweichung, mittlerer Drawdown).
//   - if () mit NA bricht ab ("missing value where TRUE/FALSE needed"); der Kern meldet die Stelle (Site), der
//     Host loest den Fehler mit dem Text von R aus (R seit 1.4.1 mit dem Aufruf von simulation()).
//   - difftime(Datum, Datum, units = "days") ueber Sekunden: (a * 86400 - b * 86400) / 86400.
//   - calculate_skewness/_kurtosis geben bei zu wenigen Werten bzw. Standardabweichung 0 ein logisches NA
//     zurueck (Merker skew_lgl, kurt_lgl fuer R).
// Die Abfolge der Meldungen: alle Warnungen stammen aus .sim_returns (vor der Spalte risk_free); ein Abbruch in
// .sim_returns (phase 1) kommt vor, einer in .sim_risk_stats (phase 2) nach den Meldungen zu risk_free, die der
// Host selbst rechnet (Spalte, as.numeric) und zwischen beide stellt.

#ifndef SIMLEV_EVALUATE_CORE_IMPL_H
#define SIMLEV_EVALUATE_CORE_IMPL_H

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
#include "slc_rbase.h"
#include "slc_internal.h"   // slc_quantile7 (seit 1.6.5, Serenity)
#include "engine_core_impl.h"   // simlev_engine::r_gt (seit 1.6.4)

#include <cfloat>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace simlev_eval {

// statistics (Reihenfolge wie die Liste in R)
enum Stat {
  ST_MEAN = 0, ST_SD, ST_CV, ST_RF, ST_SKEW, ST_KURT, ST_LPM, ST_HPM, ST_SHARPE, ST_SORTINO, ST_CALMAR, ST_OMEGA,
  ST_GTP, ST_SERENITY, ST_MARTIN, ST_MAXDD, ST_AVGDD, ST_ULCER, ST_LONGEST, ST_RECOVERY, ST_N
};
// Kennzahl einer Zeile von undefined_metrics: cagr, ttwror, statistics (M_STAT + Stat), buys, sells
enum Metric { M_CAGR = 0, M_TTWROR = 1, M_STAT = 2, M_BUYS = 2 + ST_N, M_SELLS = 3 + ST_N };
// Ursache (reason)
enum Reason {
  RS_TOO_SHORT = 0, RS_NEG_END, RS_NO_IRR, RS_ZERO_START, RS_NONPOS_TWR, RS_NOT_FINITE, RS_ZERO_MEAN, RS_ZERO_VOL,
  RS_NO_NEG, RS_NO_DD, RS_NO_RECOVERY
};
// Klartext (detail) mit Werten v
enum Detail {
  D_PERIOD = 0,      // "Zeitraum <n Tage>, Laufzeit 0 Jahre (Einzeltag)"; v0 Tage
  D_NEG_END,         // "Endwert %.2f EUR negativ"; v0
  D_NEG_END_DEBT,    // "Endwert %.2f EUR negativ: offene Steuerschuld %.2f EUR"; v0, v1
  D_NO_IRR,          // "kein interner Zinsfuss: Startwert, Einzahlungen, Endwert"; v0..v2
  D_ZERO_START,      // "Depotwert am Starttag %.2f EUR"; v0
  D_NONPOS_TWR,      // "zeitgewichteter Wertindex am <Datum> nicht positiv (Tagesrendite %.2f %%)"; v0 Tag, v1
  D_NOT_FINITE,      // "Rechnung ergibt keinen endlichen Wert"
  D_FEW0,            // "keine Tagesrendite (Einzeltag)"
  D_FEW,             // "nur %d Tagesrendite(n), mindestens %d noetig"; v0 n_r, v1 k
  D_NO_DD,           // "kein Drawdown im Zeitraum (max_drawdown 0)"
  D_ZERO_VOL,        // "Standardabweichung der %d Tagesrenditen ist 0 (konstanter Verlauf)"; v0 n_r
  D_ZERO_MEAN,       // "mittlere Tagesrendite ist 0"
  D_SHARPE_VOL,      // "Standardabweichung der %d Ueberschussrenditen ist 0"; v0 n_r
  D_SORTINO,         // "keine negativen Ueberschussrenditen (Downside-Abweichung 0)"
  D_NO_NEG,          // "keine negativen Tagesrenditen"
  D_MARTIN,          // "kein Drawdown im Zeitraum (Ulcer Index 0)"
  D_NO_DD_PLAIN,     // "kein Drawdown im Zeitraum"
  D_NOT_RECOVERED,   // "Drawdown bis zum Ende nicht aufgeholt (laengster Drawdown <n Tage>)"; v0
  D_COUNT_SHORT,     // "Zeitraum <n Tage>, Laufzeit 0 Jahre: keine Anzahl je Jahr (Einzeltag)"; v0 Tage
  D_INHERIT          // "<cagr|ttwror> nicht definiert: <Klartext der Ursache dort>"; v0 M_CAGR bzw. M_TTWROR
};
// Warnungen (Texte in den Hosts) mit Werten v
enum Warn {
  W_ZEROIN_NEGINF = 1,  // uniroot: "-Inf replaced by maximally negative value"
  W_ZEROIN_INF = 2,     // uniroot: "NA/Inf replaced by maximum positive value"
  W_ZEROIN_NOCONV = 3,  // uniroot: "_NOT_ converged in 1000 iterations"
  W_NO_IRR = 10,        // cagr mit Einzahlungen nicht bestimmbar; v: Startwert brutto, Einzahlungen, Endwert
  W_END_NEG = 11,       // Endwert negativ; v: Endwert, offene Steuerschuld
  W_TTWROR_NAN = 12,    // zeitgewichteter Wertindex wird negativ (ttwror NaN)
  W_ZERO_YEARS = 13,    // Laufzeit 0 Jahre; v: Tage
  W_ZERO_START = 14,    // Depotwert am Starttag; v: Wert
  W_TWR_NONPOS = 15,    // Wertindex nicht positiv; v: Tag, Tagesrendite in %, Depotwert am Vortag, Einzahlung
  W_NEG_WORTH = 16,     // Depotwert negativ; v: Tag, Wert
  W_MAX_EMPTY = 17      // max(drawdowns, na.rm = TRUE) ohne Werte
};
// Stellen eines Abbruchs (if () mit NA) in .sim_returns (1-4) bzw. .sim_risk_stats (5, 6)
enum Site { S_CAGR = 1, S_TAX_DEBT = 2, S_TTWROR = 3, S_TWR = 4, S_SORTINO = 5, S_DD_LOOP = 6 };

struct Msg {
  int code;
  double v[4];
};
struct Row {
  int metric, reason, detail;
  double v[3];
};

struct In {
  int64_t n = 0, na = 0;                    // Tage, Assets
  const double* const* total = nullptr;     // je Asset report$total (n)
  const double* const* flows = nullptr;     // report$flows
  const double* const* worth = nullptr;     // report$worth
  const double* const* money = nullptr;     // report$money
  const double* const* price = nullptr;     // market$asset_price nach dem Lauf (Splits)
  const double* day = nullptr;              // flag_date als Tageszahl (n)
  const int32_t* filled = nullptr;          // flag_filled (n, 0/1) oder nullptr (kein Tag aufgefuellt)
  double start_date = 0.0, stopp_date = 0.0, start_value = 0.0, tax_unpaid = 0.0;
  const double* status_money = nullptr;     // je Asset status$money nach dem Lauf
  const double* n_buys = nullptr;           // je Asset Zahl der Kaeufe bzw. Verkaeufe
  const double* n_sells = nullptr;
  const double* rf = nullptr;               // rf_series_full (as.numeric der Spalte bzw. rep(risk_free, n))
  int64_t n_rf = 0;
  int rf_ok = 1;                            // 0: risk_free ergab einen Fehler (nur .sim_returns rechnen)
};

struct Result {
  // .sim_returns
  std::vector<double> total_worth, twr_index, invested, drawdowns;
  double cagr = 0.0, ttwror = 0.0, open_tax_debt = 0.0;
  int has_ext_flows = 0;
  // .sim_risk_stats
  double stats[ST_N] = {0};
  int skew_lgl = 0, kurt_lgl = 0;           // calculate_skewness/_kurtosis: logisches NA
  int longest_dd = 0;
  // .sim_undefined_metrics
  std::vector<double> buys, sells;
  Row why[2]{};                             // Ursache fuer cagr bzw. ttwror (gueltig, wenn NA)
  int why_set[2] = {0, 0};
  std::vector<Row> um;                      // Zeilen von undefined_metrics in der Reihenfolge von R
  // Protokoll
  std::vector<Msg> msgs;                    // Warnungen in der Reihenfolge von R
  int err_site = 0, err_phase = 0;          // Abbruch: Stelle, Phase (1 .sim_returns, 2 .sim_risk_stats)
};

static inline bool is_nan_strict(double x) { return x != x && !simlev_is_na(x); }   // is.nan()
// R-Wahrheitswerte (0 FALSE, 1 TRUE, 2 NA): x > 0 ueber simlev_engine::r_gt (engine_core_impl.h; seit 1.6.4 statt
// eigener Kopie gt0), NA ueber SIMLEV_NA_REAL (statt na_real)
using simlev_engine::r_gt;
// R's &, min(a, b), max(a, b): simlev_r_and, simlev_r_min2, simlev_r_max2 (simlev_core.h, seit 1.6.3)
// difftime(a, b, units = "days") fuer Datumswerte (as.POSIXct.Date: Tage * 86400)
static inline double days_between(double a, double b) { return (a * 86400.0 - b * 86400.0) / 86400.0; }
// q^(1/yrs) - 1 (seit 1.6.2): expm1(log(q) / yrs) für q >= 0 und endliche Jahre != 0, sonst wie bisher R's `^`
// (gleich .cagr_q in R, _util._cagr_q in Python, cagr_q in Julia)
static inline double cagr_q(double q, double yrs) {
  return (q >= 0 && std::isfinite(yrs) && yrs != 0) ? std::expm1(std::log(q) / yrs) : sl_r_pow1(q, 1 / yrs) - 1;
}
// mean() und sd() mit na.rm = TRUE in einem Schritt (seit 1.6.3; vorher je eine gefilterte Kopie): y = x ohne
// NA/NaN, *mean = sl_r_mean(y), *sd = sqrt(sl_r_var(y))
static inline void mean_sd_narm(const std::vector<double>& x, std::vector<double>& y, double* mean, double* sd) {
  y.clear();
  y.reserve(x.size());
  for (double v : x) if (v == v) y.push_back(v);
  *mean = sl_r_mean((int64_t) y.size(), y.data());
  *sd = std::sqrt(sl_r_var((int64_t) y.size(), y.data()));
}
// seit 1.6.5 (MA2-4, Entscheidungen 186 M7 und 187): eine Streuung im Rundungsrauschen gilt als 0, damit eine
// Kennzahl ohne Schwankung (Sharpe, Schiefe, Woelbung, Variationskoeffizient) "nicht definiert" ist statt rund 1e13:
// sd <= 16 sqrt(N) eps (1 + max|x|) (bis 1.6.4 nur sd == 0). Massstab 1 + max|x|: eine Tagesrendite x = W_t / W_{t-1} - 1
// traegt den Rundungsfehler des Quotienten (rund eps, nicht eps |x|); mit max|x| allein (Vorschlag MA2-4) bliebe der
// Beleg des Befunds (Kurs 100 * 1.0001^t, sd 8.8e-17 bei max|x| 1e-4) ueber der Schwelle
static inline double sd_eff(double sd, const std::vector<double>& x) {
  if (!(sd > 0)) return sd;
  double mx = 0.0;
  for (double v : x) {
    const double a = std::fabs(v);
    if (a > mx) mx = a;
  }
  return sd <= 16.0 * std::sqrt((double) x.size()) * 2.220446049250313e-16 * (1.0 + mx) ? 0.0 : sd;
}
static inline void msg(std::vector<Msg>* m, int code, double a = 0.0, double b = 0.0, double c = 0.0, double d = 0.0) {
  if (m) m->push_back(Msg{code, {a, b, c, d}});
}

// ── .xirr_rate(t, amount, end_value, horizon): interner Zinsfuss p. a. (Brent in u = T log(1 + r)) ───────────
struct XirrFn {
  std::vector<double> a, e, buf;
  double end_value;
  std::vector<Msg>* msgs;
  double g(double u) {   // sum(amount * exp(u * e)) - end_value
    for (std::size_t i = 0; i < e.size(); i++) buf[i] = a[i] * std::exp(u * e[i]);
    return sl_r_sum((int64_t) buf.size(), buf.data(), 0) - end_value;
  }
};
// Rueckruf von uniroot (R: fcn2 in zeroin.c): nicht endliche Werte durch -DBL_MAX bzw. DBL_MAX mit Warnung
inline double xirr_fcn2(double u, void* info) {
  XirrFn* F = static_cast<XirrFn*>(info);
  const double v = F->g(u);
  if (!std::isfinite(v)) {
    if (v == -INFINITY) {
      msg(F->msgs, W_ZEROIN_NEGINF);
      return -DBL_MAX;
    }
    msg(F->msgs, W_ZEROIN_INF);
    return DBL_MAX;
  }
  return v;
}

inline double xirr(int64_t n, const double* t_in, const double* amount_in, double end_value, double horizon,
                   std::vector<Msg>* msgs) {
  XirrFn F;
  F.msgs = msgs;
  F.end_value = end_value;
  std::vector<double> t;
  for (int64_t i = 0; i < n; i++)
    if (std::isfinite(amount_in[i]) && amount_in[i] != 0) {
      t.push_back(t_in[i]);
      F.a.push_back(amount_in[i]);
    }
  if (F.a.empty() || !(horizon > 0) || !std::isfinite(end_value)) return SIMLEV_NA_REAL;
  if (end_value == 0) {
    bool nonneg = true;
    for (double v : F.a) if (!(v >= 0)) nonneg = false;
    if (nonneg) return -1.0;
  }
  F.e.resize(t.size());
  F.buf.resize(t.size());
  for (std::size_t i = 0; i < t.size(); i++) F.e[i] = simlev_div(simlev_sub(horizon, t[i]), horizon);
  // Startgitter u = -200, -195, ..., 200; gesucht ist das erste Intervall mit Vorzeichenwechsel. Seit 1.6.4 (A-080)
  // wird g nur bis zu diesem Intervall ausgewertet (bis 1.6.3 an allen 81 Punkten): g hat keine Seiteneffekte, die
  // uebrigen Werte las niemand (ohne Treffer nur gv[0]); gleiche Werte
  double grid[81], gv[81];
  for (int i = 0; i <= 80; i++) grid[i] = -200.0 + (double) i * 5.0;
  gv[0] = F.g(grid[0]);
  int k = -1;
  for (int i = 0; i < 80; i++) {
    gv[i + 1] = F.g(grid[i + 1]);
    if (gv[i + 1] * gv[i] <= 0) {
      k = i;
      break;
    }
  }
  double br0, br1, fb0, fb1;
  if (k >= 0) {
    br0 = grid[k]; br1 = grid[k + 1]; fb0 = gv[k]; fb1 = gv[k + 1];
  } else {
    // Beinahe-Totalverlust: Nullstelle unter u = -200; untere Grenze verdoppeln, bis g das Vorzeichen wechselt
    // oder exp(u * e) fuer alle e > 0 unterlaeuft
    double emin = INFINITY;
    bool any_pos = false;
    for (double v : F.e)
      if (v > 0) {
        any_pos = true;
        if (v < emin) emin = v;
      }
    if (!(gv[0] > 0) || !any_pos) return SIMLEV_NA_REAL;
    const double lo_lim = -800.0 / emin;
    double hi = grid[0], ghi = gv[0], lo = hi, glo = ghi;
    while (glo > 0 && lo > lo_lim) {
      hi = lo; ghi = glo;
      lo = simlev_r_max2(2 * lo, lo_lim);
      glo = F.g(lo);
    }
    if (glo > 0) return SIMLEV_NA_REAL;
    br0 = lo; br1 = hi; fb0 = glo; fb1 = ghi;
  }
  // stats::uniroot(g, br, f.lower = fb[1], f.upper = fb[2], tol = 1e-14, maxiter = 1000): Funktionswerte an den
  // Enden auf [-DBL_MAX, DBL_MAX] begrenzt, dann R_zeroin2
  if (fb0 != fb0 || fb1 != fb1) return SIMLEV_NA_REAL;
  const double fl = std::fmax(std::fmin(fb0, DBL_MAX), -DBL_MAX), fu = std::fmax(std::fmin(fb1, DBL_MAX), -DBL_MAX);
  int iter = 0;
  const double u = sl_r_zeroin2(xirr_fcn2, &F, br0, br1, fl, fu, 1e-14, 1000, &iter);
  if (iter < 0) msg(msgs, W_ZEROIN_NOCONV);
  return std::expm1(u / horizon);
}

// ── calculate_skewness/_kurtosis/_partials fuer die Tagesrenditen ─────────────────────────────────────────
// x: Werte ohne NA/NaN, mean_x = sl_r_mean(x), sd_x = sqrt(sl_r_var(x)) (seit 1.6.3 einmal fuer beide Momente
// und die Tagesstatistik, mean_sd_narm). Rueckgabe je Moment: Wert; *lgl = 1 fuer R's logisches NA (zu wenige
// Werte bzw. Standardabweichung 0). Seit 1.6.4 (K43 T1-R11, Entscheidungen 124, 127) beide Momente in einer
// Schleife ueber d = x - mean, q = d * d, Summanden q * d und q * q statt (x - mean)^3 und ^4 ueber pow (je
// Auswertung von 30 Jahren rund 0,5 auf 0,07 ms); wie calculate_skewness/_kurtosis in R, Python und Julia
// (gleiche Rechenfolge, untereinander bitgleich). Gegen den exakten Wert so genau wie pow (Probe K43 T1).
inline void moments(const std::vector<double>& x, double mean_x, double sd_x, double* skew, int* skew_lgl,
                    double* kurt, int* kurt_lgl) {
  const int64_t n = (int64_t) x.size();
  *skew_lgl = n < 3 || sd_x == 0;
  *kurt_lgl = n < 4 || sd_x == 0;
  *skew = *kurt = SIMLEV_NA_REAL;
  if (*skew_lgl && *kurt_lgl) return;
  std::vector<double> d3((std::size_t) n), d4((std::size_t) n);
  for (int64_t i = 0; i < n; i++) {
    const double d = x[i] - mean_x, q = d * d;
    d3[i] = q * d;
    d4[i] = q * q;
  }
  const double nf = (double) n;
  if (!*skew_lgl) *skew = (nf / ((nf - 1) * (nf - 2))) * sl_r_sum(n, d3.data(), 0) / sl_r_pow1(sd_x, 3.0);
  if (!*kurt_lgl) {
    double k = (nf * (nf + 1)) / ((nf - 1) * (nf - 2) * (nf - 3)) * sl_r_sum(n, d4.data(), 0) / sl_r_pow1(sd_x, 4.0);
    const double nm1 = nf - 1;
    k = k - (3 * (nm1 * nm1)) / ((nf - 2) * (nf - 3));
    *kurt = k;
  }
}
// mean(pmax(0, -r)^1, na.rm = TRUE) bzw. mean(pmax(0, r)^1, na.rm = TRUE). Seit 1.6.4 (A-081) ohne sl_r_pow1(p, 1):
// p ist hier nie NaN (NaN faellt vorher heraus) und nie -0 (y > 0 ? y : +0), und R's x^1 ist fuer solche p exakt p
// (sl_r_pow1: +0 -> +0, sonst pow(p, 1) = p); gleiche Werte. Die Tagesrenditen rr sind ohnehin endlich (evaluate).
inline double partial(const std::vector<double>& r, bool lower) {
  std::vector<double> v;
  v.reserve(r.size());
  for (double x : r) {
    const double y = lower ? -x : x;
    if (y != y) continue;
    v.push_back(y > 0.0 ? y : 0.0);
  }
  return sl_r_mean((int64_t) v.size(), v.data());
}

// ── Auswertung (.sim_returns, .sim_risk_stats, .sim_undefined_metrics) ─────────────────────────────────────
// Rueckgabe 0 in Ordnung, 1 Abbruch (err_site, err_phase), 2 fehlerhafte Eingabe
inline int evaluate(const In& I, Result& R) {
  if (I.n < 1 || I.na < 1 || !I.total || !I.flows || !I.worth || !I.money || !I.price || !I.day ||
      !I.status_money || !I.n_buys || !I.n_sells || (I.n_rf > 0 && !I.rf))
    return 2;
  const int64_t n = I.n, na = I.na;
  const double NA = SIMLEV_NA_REAL;
  auto abort = [&](int site, int phase) {
    R.err_site = site;
    R.err_phase = phase;
    return 1;
  };
  // Depotwert und Zufluesse je Tag: rowSums(sapply(report, `[[`, field), na.rm = TRUE); seit 1.6.3 direkt ueber
  // die Spalten (gleiche Reihenfolge der Summanden, ohne Kopie in eine Matrix)
  std::vector<double>& tw = R.total_worth;
  std::vector<double> tf((std::size_t) n);
  tw.assign((std::size_t) n, 0.0);
  sl_r_rowsums_cols(n, na, I.total, 1, 0, tw.data());
  sl_r_rowsums_cols(n, na, I.flows, 1, 0, tf.data());
  const double stopp_worth = tw[(std::size_t) (n - 1)];
  const int64_t n_days = n;
  const double ann = days_between(I.stopp_date, I.start_date) / 365.25;
  // seit 1.6.5 (MA2-1, Entscheidung 186 M4): Bezug aller Renditen ist das eingesetzte Kapital am ersten Tag (Startwert
  // plus Sparrate des ersten Tags), nicht der Depotwert nach dem Startkauf; Spread und Gebuehren des Startkaufs
  // mindern damit CAGR, TTWROR, Wertindex, Drawdowns und die Tagesrenditen (bis 1.6.4 nur mit spaeteren Einzahlungen)
  const double f0 = tf[0] == tf[0] ? tf[0] : 0.0;
  const double start_worth = simlev_add(I.start_value, f0);
  // CAGR
  {
    const int c = simlev_r_and(r_gt(start_worth, 0), r_gt(ann, 0));
    if (c == 2) return abort(S_CAGR, 1);
    R.cagr = c ? cagr_q(simlev_div(stopp_worth, start_worth), ann) : NA;   // seit 1.6.2 expm1(log(q) / Jahre)
  }
  // Rendite des ersten Tags: Kosten des Startkaufs (seit 1.6.5, M4)
  const double r0 = (start_worth == start_worth && start_worth > 0) ? simlev_div(tw[0], start_worth) - 1 : 0.0;
  // TTWROR: Periodenrenditen, an Zuflusstagen zum Zeitpunkt der Zahlung bewertet
  std::vector<double> pr;
  if (n >= 2) {
    pr.assign((std::size_t) n, 0.0);
    for (int64_t i = 1; i < n; i++) {
      const double pc = simlev_sub(simlev_sub(tw[i], tw[i - 1]), tf[i]);
      const double pt = tw[i - 1];
      pr[i] = (pt == pt && pt > 0) ? simlev_div(pc, pt) : 0.0;
    }
    std::vector<int64_t> fday;
    for (int64_t i = 1; i < n; i++) if (tf[i] == tf[i] && tf[i] != 0) fday.push_back(i);
    if (!fday.empty()) {
      std::vector<double> v_pre(fday.size(), 0.0);
      for (int64_t a = 0; a < na; a++) {
        for (std::size_t k = 0; k < fday.size(); k++) {
          const int64_t i = fday[k];
          const double w_prev = I.worth[a][i - 1];
          const double gr = simlev_div(I.price[a][i], I.price[a][i - 1]);
          double val;
          if (w_prev != w_prev) val = std::isfinite(gr) ? NA : 0.0;     // (NA != 0) & is.finite(gr)
          else val = (w_prev != 0 && std::isfinite(gr)) ? simlev_mul(w_prev, gr) : 0.0;
          v_pre[k] = simlev_add(simlev_add(v_pre[k], val), I.money[a][i - 1]);
        }
      }
      for (std::size_t k = 0; k < fday.size(); k++) {
        const int64_t i = fday[k];
        const double pt = tw[i - 1];
        const double g1 = (pt == pt && pt > 0) ? simlev_div(v_pre[k], pt) : 1.0;
        const double den = simlev_add(v_pre[k], tf[i]);
        const double g2 = (std::isfinite(den) && den > 0) ? simlev_div(tw[i], den) : 1.0;
        pr[i] = simlev_mul(g1, g2) - 1;
      }
    }
    pr[0] = r0;   // seit 1.6.5 (M4; bis 1.6.4 NA)
  } else {
    pr.assign(1, r0);
  }
  if (ann > 0) {
    std::vector<double> g1p(pr.size());
    for (std::size_t i = 0; i < pr.size(); i++) g1p[i] = 1 + pr[i];
    R.ttwror = cagr_q(sl_r_prod((int64_t) g1p.size(), g1p.data(), 1), ann);   // seit 1.6.2 wie cagr
  } else {
    R.ttwror = NA;
  }
  // externe Zufluesse ab Tag 2; eingezahlt = Startwert + Einzahlungen; zeitgewichteter Wertindex
  bool has_ext = false;
  for (int64_t i = 1; i < n; i++) if (tf[i] == tf[i] && tf[i] != 0) has_ext = true;
  R.has_ext_flows = has_ext;
  std::vector<double> fl0(tf);
  for (double& x : fl0) if (x != x) x = 0.0;
  R.invested.assign((std::size_t) n, 0.0);
  sl_r_cumsum(n, fl0.data(), R.invested.data());
  for (double& x : R.invested) x = simlev_add(I.start_value, x);
  {
    std::vector<double> g(1, std::isfinite(1 + r0) ? 1 + r0 : 1.0);   // seit 1.6.5 (M4): erste Stufe W_0 / (S + F_0)
    for (int64_t i = 1; i < n; i++) {
      const double x = 1 + pr[i];
      g.push_back(std::isfinite(x) ? x : 1.0);
    }
    R.twr_index.assign(g.size(), 0.0);
    sl_r_cumprod((int64_t) g.size(), g.data(), R.twr_index.data());
  }
  const std::vector<double>& twr = R.twr_index;
  double start_gross = NA, sum_fi = NA;
  if (has_ext) {
    std::vector<double> t(1, 0.0), amt;
    std::vector<double> ffi;
    for (int64_t i = 1; i < n; i++)
      if (tf[i] == tf[i] && tf[i] != 0) {
        t.push_back(days_between(I.day[i], I.start_date) / 365.25);
        ffi.push_back(tf[i]);
      }
    start_gross = simlev_add(I.start_value, fl0[0]);
    amt.push_back(start_gross);
    amt.insert(amt.end(), ffi.begin(), ffi.end());
    sum_fi = sl_r_sum((int64_t) ffi.size(), ffi.data(), 0);
    R.cagr = ann > 0 ? xirr((int64_t) t.size(), t.data(), amt.data(), stopp_worth, ann, &R.msgs) : NA;
    if (R.cagr != R.cagr && ann > 0 && !(std::isfinite(stopp_worth) && stopp_worth < 0))
      msg(&R.msgs, W_NO_IRR, start_gross, sum_fi, stopp_worth);
  }
  // offene Steuerschuld; negativer Endwert
  {
    const int c = r_gt(I.tax_unpaid, 0);
    if (c == 2) return abort(S_TAX_DEBT, 1);
    if (c) {
      std::vector<double> d((std::size_t) na);
      for (int64_t a = 0; a < na; a++) d[a] = simlev_r_max2(0.0, -I.status_money[a]);
      R.open_tax_debt = sl_r_sum(na, d.data(), 0);
    } else {
      R.open_tax_debt = 0.0;
    }
  }
  const double debt = R.open_tax_debt;
  const bool neg_end = std::isfinite(stopp_worth) && stopp_worth < 0;
  // any(twr_index <= 0) dreiwertig
  int any_twr_le0 = 0;
  int64_t i0_twr = -1;
  for (std::size_t i = 0; i < twr.size(); i++) {
    if (twr[i] != twr[i]) {
      if (any_twr_le0 == 0) any_twr_le0 = 2;
    } else if (twr[i] <= 0) {
      any_twr_le0 = 1;
      if (i0_twr < 0) i0_twr = (int64_t) i;
    }
  }
  if (neg_end) {
    if (!has_ext) R.cagr = NA;
    if (is_nan_strict(R.ttwror)) R.ttwror = NA;
    msg(&R.msgs, W_END_NEG, stopp_worth, debt);
  } else if (is_nan_strict(R.ttwror)) {
    R.ttwror = NA;
    const int c = simlev_r_and(has_ext ? 1 : 0, any_twr_le0);
    if (c == 2) return abort(S_TTWROR, 1);
    if (c == 0) msg(&R.msgs, W_TTWROR_NAN);
  }
  // Ursachen nicht definierter Jahresrenditen (.why_na)
  auto why_na = [&](int metric) {
    Row w{metric, 0, 0, {0.0, 0.0, 0.0}};
    if (ann <= 0) { w.reason = RS_TOO_SHORT; w.detail = D_PERIOD; w.v[0] = (double) n_days; return w; }
    if (neg_end) {
      w.reason = RS_NEG_END;
      if (debt > 0) { w.detail = D_NEG_END_DEBT; w.v[0] = stopp_worth; w.v[1] = debt; }
      else { w.detail = D_NEG_END; w.v[0] = stopp_worth; }
      return w;
    }
    if (metric == M_CAGR && has_ext) {
      w.reason = RS_NO_IRR; w.detail = D_NO_IRR; w.v[0] = start_gross; w.v[1] = sum_fi; w.v[2] = stopp_worth;
      return w;
    }
    if (metric == M_CAGR && !(start_worth > 0)) {
      w.reason = RS_ZERO_START; w.detail = D_ZERO_START; w.v[0] = start_worth;
      return w;
    }
    if (i0_twr >= 0) {
      w.reason = RS_NONPOS_TWR; w.detail = D_NONPOS_TWR; w.v[0] = I.day[i0_twr]; w.v[1] = 100 * pr[(std::size_t) i0_twr];
      return w;
    }
    w.reason = RS_NOT_FINITE; w.detail = D_NOT_FINITE;
    return w;
  };
  if (R.cagr != R.cagr) { R.why[0] = why_na(M_CAGR); R.why_set[0] = 1; }
  if (R.ttwror != R.ttwror) { R.why[1] = why_na(M_TTWROR); R.why_set[1] = 1; }
  if (ann <= 0) msg(&R.msgs, W_ZERO_YEARS, (double) n_days);
  else if (!has_ext && R.cagr != R.cagr && R.why_set[0] && R.why[0].reason == RS_ZERO_START)
    msg(&R.msgs, W_ZERO_START, start_worth);
  const double ret_dd = has_ext ? R.ttwror : R.cagr;
  const std::vector<double>& dd_series = has_ext ? R.twr_index : R.total_worth;
  // Drawdowns (mit NaN-Schutz)
  std::vector<double> running_max(dd_series.size());
  sl_r_cummax((int64_t) dd_series.size(), dd_series.data(), running_max.data());
  // seit 1.6.5 (M4): Hoechststand ab dem eingesetzten Kapital (Wertindex 1 bzw. Startwert plus erste Sparrate)
  {
    const double top0 = has_ext ? 1.0 : start_worth;
    if (top0 == top0 && top0 > 0)
      for (double& x : running_max) if (x == x && x < top0) x = top0;
  }
  std::vector<double>& dd = R.drawdowns;
  dd.assign(dd_series.size(), 0.0);
  for (std::size_t i = 0; i < dd.size(); i++) {
    const double rm = running_max[i];
    dd[i] = rm != rm ? NA : (rm > 0 ? simlev_div(simlev_sub(rm, dd_series[i]), rm) : 0.0);
  }
  {
    const int c = simlev_r_and(has_ext ? 1 : 0, any_twr_le0);
    if (c == 2) return abort(S_TWR, 1);
    if (c == 1) {
      const int64_t i0 = i0_twr;
      msg(&R.msgs, W_TWR_NONPOS, I.day[i0], 100 * pr[(std::size_t) i0], tw[(std::size_t) (i0 - 1)], tf[(std::size_t) i0]);
      for (double& d : dd) if (d == d) d = simlev_r_min2(d, 1.0);
    }
  }
  {
    int64_t i0 = -1;
    for (std::size_t i = 0; i < dd.size(); i++)
      if (dd[i] == dd[i] && dd[i] > 1) { i0 = (int64_t) i; break; }
    if (i0 >= 0) {
      if (!neg_end) msg(&R.msgs, W_NEG_WORTH, I.day[i0], tw[(std::size_t) i0]);
      for (double& d : dd) if (d == d) d = simlev_r_min2(d, 1.0);
    }
  }
  double max_dd = -INFINITY;
  bool any_dd = false;
  for (double d : dd)
    if (d == d) {
      if (!any_dd || d > max_dd) max_dd = d;
      any_dd = true;
    }
  if (!any_dd) msg(&R.msgs, W_MAX_EMPTY);
  if (!std::isfinite(max_dd)) max_dd = 0.0;
  // Tagesrenditen: zeitgewichtet bei Zufluessen, sonst einfach; ohne aufgefuellte Tage (A-2)
  bool has_flows = false;
  for (double x : tf) if (x == x && x != 0) has_flows = true;
  std::vector<double> rr;
  for (int64_t i = 1; i < n; i++) {
    double r;
    if (has_flows) r = pr[i];
    else r = simlev_div(simlev_sub(tw[i], tw[i - 1]), tw[i - 1]);
    if (!std::isfinite(r)) r = 0.0;
    const bool masked = I.filled && I.filled[i] != 0;
    // seit 1.6.5 (M4): die Kosten des Startkaufs gehen in die erste Tagesrendite ein ((1 + r0)(1 + r) - 1)
    if (!masked && rr.empty() && r0 != 0 && std::isfinite(r0)) r = simlev_mul(1 + r0, 1 + r) - 1;
    if (!masked) rr.push_back(r);
  }
  bool any_mask = false;
  if (I.filled) for (int64_t i = 1; i < n; i++) if (I.filled[i] != 0) any_mask = true;
  const int64_t n_r = (int64_t) rr.size();
  const double dpy = (ann > 0 && n_r > 0) ? (double) n_r / ann : 365.25;
  // mittlere Kaeufe/Verkaeufe je Jahr (Einzeltag NA)
  R.buys.assign((std::size_t) na, NA);
  R.sells.assign((std::size_t) na, NA);
  for (int64_t a = 0; a < na; a++)
    if (ann > 0) {
      R.buys[a] = I.n_buys[a] / ann;
      R.sells[a] = I.n_sells[a] / ann;
    }
  if (!I.rf_ok) return 0;
  // ── .sim_risk_stats ──
  double* S = R.stats;
  std::vector<double> rr_ok, ex_ok;   // rr bzw. excess ohne NA/NaN
  double rr_mean, rr_sd;
  mean_sd_narm(rr, rr_ok, &rr_mean, &rr_sd);
  const double rr_sd0 = sd_eff(rr_sd, rr_ok);   // seit 1.6.5 (M7): Rauschen gilt als 0 (cv, Schiefe, Woelbung)
  double daily_mean = rr_mean, daily_sd = rr_sd;
  if (!std::isfinite(daily_mean)) daily_mean = 0.0;
  if (!std::isfinite(daily_sd)) daily_sd = 0.0;
  S[ST_MEAN] = daily_mean;
  S[ST_SD] = daily_sd;
  S[ST_CV] = daily_mean != 0 ? std::fabs((std::isfinite(rr_sd0) ? rr_sd0 : 0.0) / daily_mean) : NA;
  // risk_free in Prozent p. a. je Tag (A-4): tagesaequivalent abziehen
  std::vector<double> rf_full(I.rf, I.rf + I.n_rf);
  for (double& x : rf_full) {
    if (!std::isfinite(x)) x = 0.0;
    x = x / 100;
  }
  std::vector<double> rf_ret;
  if (rf_full.size() >= 2) rf_ret.assign(rf_full.begin() + 1, rf_full.end());
  if ((int64_t) rf_ret.size() == n - 1 && any_mask) {
    std::vector<double> k;
    for (int64_t i = 1; i < n; i++) if (I.filled[i] == 0) k.push_back(rf_ret[(std::size_t) (i - 1)]);
    rf_ret.swap(k);
  }
  if ((int64_t) rf_ret.size() != n_r) {
    const double fill = rf_ret.empty() ? 0.0 : sl_r_mean((int64_t) rf_ret.size(), rf_ret.data());
    rf_ret.assign((std::size_t) n_r, fill);
  }
  std::vector<double> base(rf_ret.size()), rf_daily(rf_ret.size()), excess(rf_ret.size());
  for (std::size_t i = 0; i < rf_ret.size(); i++) base[i] = 1 + rf_ret[i];
  // (1 + rf)^(1 / dpy) wie sl_r_pow; seit 1.6.4 (K43 T1-R12) je Folge gleicher Basen (gleiches Bitmuster, auch
  // NaN) nur einmal potenziert (risk_free als Zahl: eine Potenz statt n); gleiche Werte
  {
    const double ey = 1 / dpy;
    uint64_t pb = 0;
    for (std::size_t i = 0; i < base.size(); i++) {
      uint64_t bb;
      std::memcpy(&bb, &base[i], sizeof bb);
      if (i > 0 && bb == pb) {
        rf_daily[i] = rf_daily[i - 1];
      } else {
        sl_r_pow(1, &base[i], ey, &rf_daily[i]);
        pb = bb;
      }
    }
  }
  for (std::size_t i = 0; i < rf_ret.size(); i++) excess[i] = simlev_sub(rr[i], rf_daily[i] - 1);
  S[ST_RF] = rf_ret.empty() ? 0.0 : sl_r_mean((int64_t) rf_ret.size(), rf_ret.data()) * 100;
  double mean_excess, sd_excess;
  mean_sd_narm(excess, ex_ok, &mean_excess, &sd_excess);
  sd_excess = sd_eff(sd_excess, ex_ok);   // seit 1.6.5 (M7): Sharpe ohne Schwankung nicht definiert
  if (!std::isfinite(mean_excess)) mean_excess = 0.0;
  if (!std::isfinite(sd_excess)) sd_excess = 0.0;
  double down_sd = 0.0;
  {
    std::size_t nd = 0;   // length(excess[excess < 0]) zaehlt NA mit
    for (double x : excess) if (x != x || x < 0) nd++;
    if (nd > 0) {
      std::vector<double> sq;
      for (double x : excess) {
        const double p = x != x ? x : (0.0 < x ? 0.0 : x);
        const double q = p * p;
        if (q == q) sq.push_back(q);
      }
      down_sd = std::sqrt(sl_r_mean((int64_t) sq.size(), sq.data()));
    }
  }
  S[ST_SHARPE] = sd_excess > 0 ? (mean_excess * dpy) / (sd_excess * std::sqrt(dpy)) : NA;
  if (down_sd != down_sd) return abort(S_SORTINO, 2);
  S[ST_SORTINO] = down_sd > 0 ? (mean_excess * dpy) / (down_sd * std::sqrt(dpy)) : NA;
  const bool rd_na = ret_dd != ret_dd;
  S[ST_CALMAR] = (max_dd > 0 && !rd_na) ? ret_dd / max_dd : NA;
  double ulcer;
  {
    std::vector<double> sq;
    for (double d : dd) {
      const double q = d * d;
      if (q == q) sq.push_back(q);
    }
    ulcer = std::sqrt(sl_r_mean((int64_t) sq.size(), sq.data()));
    if (!std::isfinite(ulcer)) ulcer = 0.0;
  }
  // seit 1.6.5 (MA2-3, Entscheidung 186 M6): Zaehler mit Abzug des mittleren risikolosen Zinses (wie statistics$risk_free;
  // Martin, Ulcer Performance Index); bis 1.6.4 ohne Abzug
  const double rf_mean = rf_ret.empty() ? 0.0 : sl_r_mean((int64_t) rf_ret.size(), rf_ret.data());
  S[ST_MARTIN] = (ulcer > 0 && !rd_na) ? (ret_dd - rf_mean) / ulcer : NA;
  // seit 1.6.5 (MA2-2, Entscheidungen 186 M5 und 194): Serenity Ratio nach KeyQuant (Baguenault de Vieville u. a. 2018,
  // wiedergegeben bei AlternativeSoft): (Rendite - risikoloser Zins) / (Ulcer Index * Pitfall), Pitfall = CDaR / Volatilitaet.
  // Eigene Festlegungen (die Quelle nennt sie nicht): CDaR zum Niveau 95 % = Mittel der Tages-Drawdowns ab ihrem
  // 95-%-Quantil (Typ 7), Volatilitaet jaehrlich wie bei Sharpe (sd der Ueberschussrenditen * sqrt(dpy)), Rendite und
  // Zins jaehrlich wie bei martin_ratio. Bis 1.6.4: Rendite / (Ulcer Index * Max Drawdown).
  double cdar = 0.0;
  {
    std::vector<double> q;
    for (double d : dd) if (d == d) q.push_back(d);
    if (!q.empty()) {
      std::vector<double> qs(q);
      const double v = slc_quantile7(qs.data(), (int64_t) qs.size(), 0.95);
      std::vector<double> tail;
      for (double d : q) if (d >= v) tail.push_back(d);
      cdar = tail.empty() ? 0.0 : sl_r_mean((int64_t) tail.size(), tail.data());
    }
  }
  const double vol_ann = sd_excess * std::sqrt(dpy);
  S[ST_SERENITY] = (ulcer > 0 && cdar > 0 && vol_ann > 0 && !rd_na) ? (ret_dd - rf_mean) * vol_ann / (ulcer * cdar) : NA;
  {
    std::vector<double> pos, negv;
    for (double x : rr) {
      if (x != x) { pos.push_back(NA); negv.push_back(NA); continue; }
      if (x > 0) pos.push_back(x);
      if (x < 0) negv.push_back(x);
    }
    const double gains = sl_r_sum((int64_t) pos.size(), pos.data(), 1);
    const double losses = std::fabs(sl_r_sum((int64_t) negv.size(), negv.data(), 1));
    S[ST_OMEGA] = losses > 0 ? gains / losses : NA;
    S[ST_GTP] = losses > 0 ? sl_r_sum(n_r, rr.data(), 1) / losses : NA;
  }
  {
    std::vector<double> act;
    for (double d : dd) {
      if (d != d) act.push_back(NA);
      else if (d > 0) act.push_back(d);
    }
    S[ST_AVGDD] = act.empty() ? 0.0 : sl_r_mean((int64_t) act.size(), act.data());
  }
  // laengster Drawdown und mittlere Erholungszeit (Tage)
  int longest = 0, current = 0, dd_start = 0;
  bool in_dd = false;
  std::vector<int64_t> rec;
  for (std::size_t i = 0; i < dd_series.size(); i++) {
    if (dd_series[i] != dd_series[i] || running_max[i] != running_max[i]) return abort(S_DD_LOOP, 2);
    if (dd_series[i] < running_max[i]) {
      current++;
      if (current > longest) longest = current;
    } else {
      current = 0;
    }
  }
  for (std::size_t i = 0; i < dd_series.size(); i++) {
    if (dd_series[i] < running_max[i]) {
      if (!in_dd) { dd_start = (int) i + 1; in_dd = true; }
    } else if (in_dd) {
      rec.push_back((int64_t) i + 1 - dd_start);
      in_dd = false;
    }
  }
  R.longest_dd = longest;
  moments(rr_ok, rr_mean, rr_sd0 == 0 ? 0.0 : rr_sd, &S[ST_SKEW], &R.skew_lgl, &S[ST_KURT], &R.kurt_lgl);
  S[ST_LPM] = partial(rr, true);
  S[ST_HPM] = partial(rr, false);
  S[ST_MAXDD] = max_dd;
  S[ST_ULCER] = ulcer;
  S[ST_LONGEST] = (double) longest;
  S[ST_RECOVERY] = rec.empty() ? NA : sl_r_mean_int((int64_t) rec.size(), rec.data());
  // ── .sim_undefined_metrics: eine Zeile je NA-Kennzahl ──
  auto row = [&](int metric, int reason, int detail, double v0 = 0.0, double v1 = 0.0) {
    R.um.push_back(Row{metric, reason, detail, {v0, v1, 0.0}});
  };
  auto few = [&](int metric, int k) {
    if (n_r == 0) row(metric, RS_TOO_SHORT, D_FEW0);
    else row(metric, RS_TOO_SHORT, D_FEW, (double) n_r, (double) k);
  };
  const int ret_metric = has_ext ? M_TTWROR : M_CAGR;
  auto inherit = [&](int metric) {
    R.um.push_back(Row{metric, R.why[ret_metric].reason, D_INHERIT, {(double) ret_metric, 0.0, 0.0}});
  };
  for (int k = 0; k < 2; k++) if (R.why_set[k]) R.um.push_back(R.why[k]);
  for (int s = 0; s < ST_N; s++) {
    const double v = S[s];
    if (v == v && !((s == ST_SKEW && R.skew_lgl) || (s == ST_KURT && R.kurt_lgl))) continue;
    const int mt = M_STAT + s;
    switch (s) {
      case ST_CV:
        if (n_r == 0) few(mt, 1); else row(mt, RS_ZERO_MEAN, D_ZERO_MEAN);
        break;
      case ST_SKEW:
        if (n_r < 3) few(mt, 3); else row(mt, RS_ZERO_VOL, D_ZERO_VOL, (double) n_r);
        break;
      case ST_KURT:
        if (n_r < 4) few(mt, 4); else row(mt, RS_ZERO_VOL, D_ZERO_VOL, (double) n_r);
        break;
      case ST_LPM: case ST_HPM:
        few(mt, 1);
        break;
      case ST_SHARPE:
        if (n_r < 2) few(mt, 2); else row(mt, RS_ZERO_VOL, D_SHARPE_VOL, (double) n_r);
        break;
      case ST_SORTINO:
        if (n_r < 1) few(mt, 1); else row(mt, RS_NO_NEG, D_SORTINO);
        break;
      case ST_CALMAR:
        if (rd_na) inherit(mt); else row(mt, RS_NO_DD, D_NO_DD);
        break;
      case ST_SERENITY:   // seit 1.6.5 (194): ohne Schwankung wie Sharpe nicht definiert
        if (rd_na) inherit(mt);
        else if (!(ulcer > 0 && cdar > 0)) row(mt, RS_NO_DD, D_NO_DD);
        else if (n_r < 2) few(mt, 2);
        else row(mt, RS_ZERO_VOL, D_SHARPE_VOL, (double) n_r);
        break;
      case ST_OMEGA: case ST_GTP:
        if (n_r < 1) few(mt, 1); else row(mt, RS_NO_NEG, D_NO_NEG);
        break;
      case ST_MARTIN:
        if (rd_na) inherit(mt); else row(mt, RS_NO_DD, D_MARTIN);
        break;
      case ST_RECOVERY:
        if (ann <= 0) row(mt, RS_TOO_SHORT, D_PERIOD, (double) n_days);
        else if (longest == 0) row(mt, RS_NO_RECOVERY, D_NO_DD_PLAIN);
        else row(mt, RS_NO_RECOVERY, D_NOT_RECOVERED, (double) longest);
        break;
      default:
        row(mt, RS_NOT_FINITE, D_NOT_FINITE);
    }
  }
  if (!(ann > 0)) {
    row(M_BUYS, RS_TOO_SHORT, D_COUNT_SHORT, (double) n_days);
    row(M_SELLS, RS_TOO_SHORT, D_COUNT_SHORT, (double) n_days);
  }
  return 0;
}

}  // namespace simlev_eval

// ---- Vorbereiteter Kernlauf (seit 1.6.5, Paket E, Entscheidung 176; FB-12) ----
// Tagesengine (mit Vorbereitung) und Auswertung in einem Aufruf: Studien (bootstrap_study, param_search,
// sensitivity_*, planning_*) bereiten Strategie, Kalender und Bausteine einmal vor und tauschen je Pfad bzw. Punkt nur
// die Kurs- und Signalreihen (Hosts: r/R/sim_prepared.R, python/simlev/_sim_prepared.py, julia/src/sim_prepared.jl).
// Rechnet dieselben Kernaufrufe in derselben Reihenfolge wie die Hosts mit sim_engine_run und sim_evaluate: die
// Eingabe der Auswertung (Report-Reihen, Kurse nach Splits, Geld je Asset, Zahl der Kaeufe und Verkaeufe, nicht
// gedeckte Steuer) stammt hier direkt aus dem Engine-Objekt statt ueber den Host. Die Auswertung rechnet nur nach einem
// Engine-Lauf ohne Abbruch (sonst bricht der Host mit der Meldung der Engine ab, bevor er die Auswertung liest).
// Rueckgabe: 0 Engine und Auswertung gerechnet, 1 Eingabe der Engine passt nicht (*bad = Code von setup_prepared),
// 2 Abbruch der Engine (E.err; R nicht gerechnet), 3 Eingabe der Auswertung passt nicht.
namespace simlev_run {

struct EvalStatic {                         // Teile der Auswertung, die nicht vom Engine-Lauf abhaengen
  const double* day = nullptr;              // flag_date als Tageszahl (n)
  const int32_t* filled = nullptr;          // flag_filled (0/1) oder nullptr
  double start_date = 0.0, stopp_date = 0.0, start_value = 0.0;
  const double* rf = nullptr;               // risk_free je Tag oder nullptr
  int64_t n_rf = 0;
  int rf_ok = 1;
};

inline int run_prepared(simlev_engine::Engine& E, const simlev_engine::Input& I, const simlev_prepare::PrepFlat& F,
                        const EvalStatic& S, simlev_eval::Result& R, int* bad = nullptr) {
  const int b = E.setup_prepared(I, F);
  if (bad) *bad = b;
  if (b) return 1;
  if (E.run() != 0) return 2;
  const std::size_t na = (std::size_t) I.na;
  std::vector<const double*> tot(na), flo(na), wor(na), mon(na), pri(na);
  std::vector<double> st(8 * na), sm(na), nb(na), ns(na);
  E.status_out(st.data());
  for (std::size_t a = 0; a < na; a++) {
    double* const* r = I.reports + 5 * a;   // worth, money, flows, total, share
    wor[a] = r[0]; mon[a] = r[1]; flo[a] = r[2]; tot[a] = r[3];
    pri[a] = E.px_changed[a] ? E.px[a].data() : I.price[a];
    sm[a] = st[8 * a + 3];
    nb[a] = (double) E.buys[a].size();
    ns[a] = (double) E.sells[a].size();
  }
  simlev_eval::In V;
  V.n = I.n; V.na = I.na;
  V.total = tot.data(); V.flows = flo.data(); V.worth = wor.data(); V.money = mon.data(); V.price = pri.data();
  V.day = S.day; V.filled = S.filled;
  V.start_date = S.start_date; V.stopp_date = S.stopp_date; V.start_value = S.start_value; V.tax_unpaid = E.tax_unpaid;
  V.status_money = sm.data(); V.n_buys = nb.data(); V.n_sells = ns.data();
  V.rf = S.rf; V.n_rf = S.n_rf; V.rf_ok = S.rf_ok;
  return simlev_eval::evaluate(V, R) == 2 ? 3 : 0;
}

}  // namespace simlev_run

#endif
