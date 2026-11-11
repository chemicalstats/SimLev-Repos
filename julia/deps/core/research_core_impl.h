// core/research_core_impl.h
// Rechenkerne fuer Optimierung, Regression, Regime und Zeitreihen-Hilfen, reine
// Rechnung ohne R, Python und Julia.
//
// GEMEINSAME QUELLE FUER R, PYTHON UND JULIA: R ruft die Kerne ueber die
// .Call-Huellen in r/src/research_core.cpp auf (sie wandeln nur die R-Objekte um),
// Python ueber das Erweiterungsmodul simlev._ext (python/src/_ext_research.cpp).
// Kanonisch in core/; R und Python bauen aus
// Byte-fuer-Byte-Kopien in r/src/ bzw. python/src/core/ (core/sync.py
// --write/--check); Aenderungen nur in core/ vornehmen und danach kopieren.
// Die Python-Huellen (simlev/_optimize_core.py, _dependence_core.py, _signals_core.py)
// rufen nur diese Kerne (reine Python-Kerne als Rueckfall gibt es seit 1.0.0 nicht mehr).
// Julia ruft die Kerne ueber die C-ABI-Huelle core/simlev_cabi.cpp auf (simlev_c_*; ccall aus
// julia/src/optimize_core.jl, dependence_core.jl, signals_core.jl) und baut aus der Byte-fuer-Byte-Kopie
// in julia/deps/core/ (libslc, julia/deps/build.jl); die frueheren Julia-Ports sind entfallen.
//
// Aufbau wie alle C++-Kerne (simlev_core.h): statische Funktionen ueber den Sichten
// simlev_host::NumVec/IntVec/NumMat und den Host-Makros SIMLEV_* (Fehler, NA,
// Anlegen der Ergebnisse), die die einbindende Huelle festlegt (R: simlev_capi.h,
// Python: _ext_common.h, Julia: simlev_cabi.cpp). Die Rechnung ist Zeile fuer Zeile die fruehere aus
// research_core.cpp; fuer R setzen die Makros genau die frueheren Aufrufe ein, der
// Compiler erzeugt daher denselben Maschinencode wie vor der Teilung (geprueft per
// Disassemblierung).
//
//   proj_box_simplex   exakte Projektion auf {w : sum w = 1, lo <= w <= hi}
//                      (Knickpunkt-Verfahren, statt Bisektion)
//   qp_box_simplex     min 0.5 w'Qw + c'w auf dem beschraenkten Simplex
//                      (FISTA mit adaptivem Neustart, O'Donoghue & Candes 2015)
//   min_cvar_core      minimaler CVaR (geglaettete Rockafellar-Uryasev-
//                      Formulierung, FISTA mit Schrittweitensuche)
//   min_cdar_core      minimaler Conditional Drawdown at Risk (projizierter
//                      Subgradient, Chekhlov, Uryasev & Zabarankin 2005)
//   quantile_reg_core  lineare Quantilsregression (MM-Algorithmus,
//                      Hunter & Lange 2000, mit exakter Ecken-Politur bzw.
//                      Austauschschritten bis zum Optimalitaetsnachweis)
//   hmm_fb_raw          skalierter Vorwaerts-Rueckwaerts-Schritt (Baum-Welch; der Einstieg
//                      hmm_forward_backward ohne Aufrufer im Paket entfaellt seit 1.6.4)
//   hmm_em              Baum-Welch-EM aus einem Startwert (seit 1.5.0)
//   goal_dp             Rueckwaertsrekursion von planning_goal() (seit 1.5.0)
//   pbo_cscv            Aufteilungen der CSCV von overfit_pbo() (seit 1.5.0)
//   (garch_filter: bis 1.0.0, ersetzt durch sl_garch11_filter in core/slc_garch.cpp)
//   roll_mean_core     rollierender Mittelwert mit kompensierter Summe
//   roll_max_core      rollierendes Maximum in O(n) (seit 1.6.3; Hoch von signal_drawdown(window))
//   kendall_tau_core   Kendalls Tau-b (ganzzahlig und double-double statt long double)
//   roll_cov_core      rollierende Kovarianz
//   research_vec       Hilfskerne seit 1.6.5 (erwartetes Maximum, harmonische Summe, Risikozustand, Median,
//                      Drawdown-Polster, Log-Ende t/Normal; seit Paket B2b HAC nach Ledoit & Wolf mit QS-Kern
//                      und Prewhitening, Stichprobe des studentisierten zirkulaeren Block-Bootstraps)
//
// Alle Kerne rechnen dieselben Formeln wie die frueheren R-Fassungen; sie
// ziehen keine Zufallszahlen.
#ifndef SIMLEV_RESEARCH_CORE_IMPL_H
#define SIMLEV_RESEARCH_CORE_IMPL_H

// Gleitkomma wie im Pilot (simlev_core.h): Abbruch bei -ffast-math; kein
// Zusammenziehen von a * b + c zu fma. Das Pragma steht nur dort, wo der Compiler
// fma ueberhaupt erzeugen kann (__FP_FAST_FMA, etwa aarch64 oder -mfma): auf
// x86-64 ohne FMA ist -ffp-contract=off wirkungslos, das GCC-Pragma optimize
// veraendert dort aber die Codeerzeugung der ganzen Datei (geprueft), und R soll
// denselben Maschinencode wie vor der Teilung ausfuehren. Python baut immer mit
// -ffp-contract=off (setup.py) und setzt SIMLEV_FP_CONTRACT_BY_FLAG; Julia ebenso
// (julia/deps/build.jl, C-ABI-Huelle in libslc).
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
#include "slc.h"
#include "slc_internal.h"
#include "slc_rbase.h"
#if !defined(SIMLEV_NA) || !defined(SIMLEV_FAIL) || !defined(SIMLEV_NUM)
#error "Vor diesem Kern den Host einbinden: R simlev_capi.h, Python _ext_common.h (siehe simlev_core.h)."
#endif

#include <vector>
#include <cmath>
#include <algorithm>
#include <numeric>
#include <limits>
#include <climits>

namespace simlev {

// ---------------------------------------------------------------------------
// Hilfen
// ---------------------------------------------------------------------------

// Projektion auf den Simplex mit Grenzen. g(t) = sum_i clip(v_i - t, lo_i, hi_i)
// faellt stueckweise linear in t; gesucht ist g(t) = 1. Die Knickpunkte sind
// v_i - hi_i (Komponente verlaesst die Obergrenze) und v_i - lo_i (erreicht die
// Untergrenze). Ergebnis ist exakt bis auf Rundung.
static void proj_box_simplex(const double* v, const double* lo, const double* hi, int n, double* out) {
  double slo = 0.0, shi = 0.0;
  for (int i = 0; i < n; ++i) { slo += lo[i]; shi += hi[i]; }
  if (shi <= 1.0) { for (int i = 0; i < n; ++i) out[i] = hi[i]; return; }
  if (slo >= 1.0) { for (int i = 0; i < n; ++i) out[i] = lo[i]; return; }
  std::vector<std::pair<double, int> > bp(2 * n);
  for (int i = 0; i < n; ++i) { bp[2 * i] = std::make_pair(v[i] - hi[i], +1); bp[2 * i + 1] = std::make_pair(v[i] - lo[i], -1); }
  std::sort(bp.begin(), bp.end());
  double t = bp[0].first, g = shi, t_star = bp[0].first;
  int k = 0;                                   // Anzahl freier Komponenten (Steigung -k)
  bool found = false;
  for (int j = 0; j < 2 * n; ++j) {
    const double tn = bp[j].first;
    const double gn = g - k * (tn - t);
    if (gn <= 1.0 && k > 0) { t_star = t + (g - 1.0) / k; found = true; break; }
    g = gn; t = tn; k += bp[j].second;
  }
  if (!found) t_star = t + (k > 0 ? (g - 1.0) / k : 0.0);
  for (int i = 0; i < n; ++i) out[i] = std::min(hi[i], std::max(lo[i], v[i] - t_star));
}

// Quantil Typ 7 (wie stats::quantile Standard) einer Kopie von x; leer NA. Seit 1.6.3 ueber slc_quantile7
// (slc_internal.h, auch fuer die Bandbreite in slc_kde.cpp).
static double quantile7(std::vector<double> x, double p) {
  if (x.empty()) return SIMLEV_NA;
  return slc_quantile7(x.data(), (int64_t) x.size(), p);
}

// ---------------------------------------------------------------------------
// Projektion und quadratisches Programm
// ---------------------------------------------------------------------------

static auto qp_box_simplex(simlev_host::NumMat Q, simlev_host::NumVec cvec, simlev_host::NumVec lo, simlev_host::NumVec hi, simlev_host::NumVec w0, double L, int maxit, double tol) {
  const int n = Q.ncol();
  std::vector<double> w(n), y(n), wn(n), g(n), tmp(n);
  proj_box_simplex(w0.begin(), lo.begin(), hi.begin(), n, w.data());
  y = w;
  double t = 1.0;
  for (int it = 0; it < maxit; ++it) {
    for (int i = 0; i < n; ++i) {
      double s = cvec[i];
      for (int j = 0; j < n; ++j) s += Q(i, j) * y[j];
      g[i] = s;
      tmp[i] = y[i] - s / L;
    }
    proj_box_simplex(tmp.data(), lo.begin(), hi.begin(), n, wn.data());
    double dmax = 0.0, dir = 0.0;
    for (int i = 0; i < n; ++i) { dmax = std::max(dmax, std::fabs(wn[i] - w[i])); dir += g[i] * (wn[i] - w[i]); }
    if (dmax < tol) { w = wn; break; }
    if (dir > 0.0) { t = 1.0; y = wn; w = wn; continue; }      // Neustart
    const double tn = (1.0 + std::sqrt(1.0 + 4.0 * t * t)) / 2.0;
    const double mom = (t - 1.0) / tn;
    for (int i = 0; i < n; ++i) y[i] = wn[i] + mom * (wn[i] - w[i]);
    w = wn; t = tn;
  }
  return SIMLEV_COPY(w.begin(), w.end());
}

// ---------------------------------------------------------------------------
// Minimaler CVaR
// ---------------------------------------------------------------------------

static inline double softplus(double z) { return z > 30.0 ? z : std::log1p(std::exp(z)); }
// seit 1.6.4 fuer z < 0 exp(z) einmal (B-077; derselbe Wert wie zwei Aufrufe)
static inline double logistic(double z) {
  if (z >= 0.0) return 1.0 / (1.0 + std::exp(-z));
  const double e = std::exp(z);
  return e / (1.0 + e);
}

// Rueckgabe seit 1.6.5 (K39, CR1-2): N Gewichte und als (N + 1)-ter Wert 1, wenn die letzte Glaettungsstufe die
// Schrittgrenze maxit erreicht hat (ohne Abbruch durch dmax < 1e-9), sonst 0; die Gewichte bitgleich wie bis 1.6.4.
static auto min_cvar_core(simlev_host::NumMat R, double alpha, simlev_host::NumVec lo, simlev_host::NumVec hi, simlev_host::NumVec w0, double zeta0, simlev_host::NumVec scales, int maxit) {
  const int T = R.nrow(), N = R.ncol();
  const double aT = alpha * T;
  std::vector<double> x(N + 1), yv(N + 1), xn(N + 1), g(N + 1), tmp(N + 1), loss(T);
  for (int i = 0; i < N; ++i) x[i] = w0[i];
  x[N] = zeta0;
  double limit = 0.0;
  auto port_loss = [&](const std::vector<double>& z) {      // -R w
    for (int s = 0; s < T; ++s) loss[s] = 0.0;
    for (int i = 0; i < N; ++i) { const double wi = z[i]; if (wi == 0.0) continue;
      for (int s = 0; s < T; ++s) loss[s] -= R(s, i) * wi; }
  };
  for (int k = 0; k < scales.size(); ++k) {
    const double sc = scales[k];
    auto f = [&](const std::vector<double>& z) {
      port_loss(z); double acc = 0.0;
      for (int s = 0; s < T; ++s) acc += softplus((loss[s] - z[N]) / sc);
      return z[N] + sc * acc / aT;
    };
    // Gradient und Wert am selben Punkt (seit 1.6.4, B-077; bis 1.6.3 grad und danach f, also port_loss zweimal):
    // je s dieselben Ausdruecke, beide Summen in derselben Folge wie in f bzw. grad
    auto grad_f = [&](const std::vector<double>& z, std::vector<double>& gr) {
      port_loss(z); std::fill(gr.begin(), gr.end(), 0.0); double sp = 0.0, acc = 0.0;
      for (int s = 0; s < T; ++s) {
        const double u = (loss[s] - z[N]) / sc;
        acc += softplus(u);
        const double p = logistic(u); loss[s] = p; sp += p;
      }
      for (int i = 0; i < N; ++i) { double a = 0.0; for (int s = 0; s < T; ++s) a += R(s, i) * loss[s]; gr[i] = -a / aT; }
      gr[N] = 1.0 - sp / aT;
      return z[N] + sc * acc / aT;
    };
    yv = x; double t = 1.0, L = 1.0 / (alpha * sc);
    limit = 1.0;
    for (int it = 0; it < maxit; ++it) {
      const double fy = grad_f(yv, g); L /= 2.0;
      for (int ls = 0; ls < 60; ++ls) {
        for (int i = 0; i <= N; ++i) tmp[i] = yv[i] - g[i] / L;
        proj_box_simplex(tmp.data(), lo.begin(), hi.begin(), N, xn.data()); xn[N] = tmp[N];
        double lin = 0.0, sq = 0.0;
        for (int i = 0; i <= N; ++i) { const double dx = xn[i] - yv[i]; lin += g[i] * dx; sq += dx * dx; }
        if (f(xn) <= fy + lin + L / 2.0 * sq + 1e-15) break;
        L *= 2.0;
      }
      double dmax = 0.0, dir = 0.0;
      for (int i = 0; i <= N; ++i) { dmax = std::max(dmax, std::fabs(xn[i] - x[i])); dir += g[i] * (xn[i] - x[i]); }
      if (dmax < 1e-9) { x = xn; limit = 0.0; break; }
      if (dir > 0.0) { t = 1.0; yv = xn; x = xn; continue; }
      const double tn = (1.0 + std::sqrt(1.0 + 4.0 * t * t)) / 2.0, mom = (t - 1.0) / tn;
      for (int i = 0; i <= N; ++i) yv[i] = xn[i] + mom * (xn[i] - x[i]);
      x = xn; t = tn;
    }
  }
  x[N] = scales.size() > 0 ? limit : 0.0;
  return SIMLEV_COPY(x.begin(), x.end());
}

// ---------------------------------------------------------------------------
// Minimaler CDaR
// ---------------------------------------------------------------------------

// CDaR einer Renditereihe: Drawdowns der kumulierten (nicht aufgezinsten)
// Rendite, Mittel der Drawdowns ab dem (1 - alpha)-Quantil.
static double cdar_of(const std::vector<double>& r, double alpha, std::vector<double>& D) {
  const int T = (int) r.size();
  double c = 0.0, pk = 0.0;
  for (int s = 0; s < T; ++s) { c += r[s]; pk = std::max(pk, c); D[s] = pk - c; }
  const double v = quantile7(D, 1.0 - alpha);
  double acc = 0.0; int m = 0;
  for (int s = 0; s < T; ++s) if (D[s] >= v) { acc += D[s]; ++m; }
  return m ? acc / m : 0.0;
}

static auto min_cdar_core(simlev_host::NumMat R, double alpha, simlev_host::NumVec lo, simlev_host::NumVec hi, int iters) {
  const int T = R.nrow(), N = R.ncol();
  // kumulierte Renditen je Anlage, Zeile 0 = 0
  std::vector<double> CR((T + 1) * N, 0.0);
  double sabs = 0.0;
  for (int i = 0; i < N; ++i) { double c = 0.0; for (int s = 0; s < T; ++s) { c += R(s, i); CR[(s + 1) * N + i] = c; sabs += std::fabs(R(s, i)); } }
  const double sc = sabs / ((double) T * N) * std::sqrt((double) T);
  std::vector<double> w(N), best(N), tmp(N), g(N), r(T), D(T), C(T + 1), Dt(T);
  std::vector<int> arg(T + 1);
  std::vector<double> eq(N, 1.0 / N);
  proj_box_simplex(eq.data(), lo.begin(), hi.begin(), N, w.data());
  auto port = [&](const std::vector<double>& z) {
    for (int s = 0; s < T; ++s) { double a = 0.0; for (int i = 0; i < N; ++i) a += R(s, i) * z[i]; r[s] = a; }
  };
  port(w); double fbest = cdar_of(r, alpha, D); best = w;
  // seit 1.6.4 (K43 T2-N6): lauter Nullrenditen (sc = 0): kein Schritt, Ergebnis der Start (bis dahin Schrittweite Inf,
  // Inf * 0 = NaN und std::sort ueber NaN in proj_box_simplex; Ergebnis zufaellig derselbe Start)
  if (sc == 0.0) return SIMLEV_COPY(best.begin(), best.end());
  const double sqN = std::sqrt((double) N);
  for (int it = 1; it <= iters; ++it) {
    double pk = -INFINITY; int am = 0;
    for (int s = 0; s <= T; ++s) {
      double a = 0.0; for (int i = 0; i < N; ++i) a += CR[s * N + i] * w[i];
      C[s] = a;
      if (a >= pk) { pk = a; am = s; }
      arg[s] = am;
      if (s > 0) Dt[s - 1] = pk - a;
    }
    const double v = quantile7(Dt, 1.0 - alpha);
    std::fill(g.begin(), g.end(), 0.0); int m = 0;
    for (int s = 0; s < T; ++s) if (Dt[s] >= v) {
      const int ti = s + 1, pi = arg[ti];
      for (int i = 0; i < N; ++i) g[i] += CR[pi * N + i] - CR[ti * N + i];
      ++m;
    }
    double gn = 0.0;
    for (int i = 0; i < N; ++i) { g[i] /= m; gn += g[i] * g[i]; }
    const double step = 0.5 / (sc * std::sqrt((double) it)) / std::max(1e-12, std::sqrt(gn) / sqN);
    for (int i = 0; i < N; ++i) tmp[i] = w[i] - step * g[i] / sqN;
    proj_box_simplex(tmp.data(), lo.begin(), hi.begin(), N, w.data());
    port(w); const double f = cdar_of(r, alpha, D);
    if (f < fbest) { fbest = f; best = w; }
  }
  return SIMLEV_COPY(best.begin(), best.end());
}

// ---------------------------------------------------------------------------
// Quantilsregression (MM-Algorithmus mit schrittweise kleinerem eps)
// ---------------------------------------------------------------------------

// Loest A x = b fuer symmetrisch positiv definites A (p x p) per Cholesky;
// faellt bei fehlender Definitheit auf Gauss-Elimination mit Pivotsuche zurueck.
static bool solve_spd(std::vector<double> A, std::vector<double>& b, int p) {
  std::vector<double> Lm(p * p, 0.0);
  bool ok = true;
  for (int i = 0; i < p && ok; ++i) for (int j = 0; j <= i; ++j) {
    double s = A[i * p + j];
    for (int k = 0; k < j; ++k) s -= Lm[i * p + k] * Lm[j * p + k];
    if (i == j) { if (s <= 0.0) { ok = false; break; } Lm[i * p + i] = std::sqrt(s); }
    else Lm[i * p + j] = s / Lm[j * p + j];
  }
  if (ok) {
    for (int i = 0; i < p; ++i) { double s = b[i]; for (int k = 0; k < i; ++k) s -= Lm[i * p + k] * b[k]; b[i] = s / Lm[i * p + i]; }
    for (int i = p - 1; i >= 0; --i) { double s = b[i]; for (int k = i + 1; k < p; ++k) s -= Lm[k * p + i] * b[k]; b[i] = s / Lm[i * p + i]; }
    return true;
  }
  for (int c = 0; c < p; ++c) {                                  // Gauss mit Pivot
    int piv = c; for (int r = c + 1; r < p; ++r) if (std::fabs(A[r * p + c]) > std::fabs(A[piv * p + c])) piv = r;
    if (std::fabs(A[piv * p + c]) < 1e-300) return false;
    if (piv != c) { for (int k = 0; k < p; ++k) std::swap(A[c * p + k], A[piv * p + k]); std::swap(b[c], b[piv]); }
    for (int r = c + 1; r < p; ++r) {
      const double f = A[r * p + c] / A[c * p + c];
      for (int k = c; k < p; ++k) A[r * p + k] -= f * A[c * p + k];
      b[r] -= f * b[c];
    }
  }
  for (int i = p - 1; i >= 0; --i) { double s = b[i]; for (int k = i + 1; k < p; ++k) s -= A[i * p + k] * b[k]; b[i] = s / A[i * p + i]; }
  return true;
}

// Zielfunktion sum rho_tau(y - X b)
static double qr_objective(const simlev_host::NumVec& y, const simlev_host::NumMat& X, const std::vector<double>& b, double tau) {
  const int n = X.nrow(), p = X.ncol();
  double acc = 0.0;
  for (int i = 0; i < n; ++i) { double fit = 0.0; for (int j = 0; j < p; ++j) fit += X(i, j) * b[j];
    const double r = y[i] - fit; acc += r * (tau - (r < 0.0 ? 1.0 : 0.0)); }
  return acc;
}

// Gauss-Elimination mit Pivotsuche fuer eine allgemeine p x p-Matrix (zeilenweise).
static bool solve_general(std::vector<double> A, std::vector<double>& b, int p) {
  for (int c = 0; c < p; ++c) {
    int piv = c; for (int rr = c + 1; rr < p; ++rr) if (std::fabs(A[rr * p + c]) > std::fabs(A[piv * p + c])) piv = rr;
    if (std::fabs(A[piv * p + c]) < 1e-300) return false;
    if (piv != c) { for (int k = 0; k < p; ++k) std::swap(A[c * p + k], A[piv * p + k]); std::swap(b[c], b[piv]); }
    for (int rr = c + 1; rr < p; ++rr) {
      const double f = A[rr * p + c] / A[c * p + c];
      for (int k = c; k < p; ++k) A[rr * p + k] -= f * A[c * p + k];
      b[rr] -= f * b[c];
    }
  }
  for (int i = p - 1; i >= 0; --i) { double s = b[i]; for (int k = i + 1; k < p; ++k) s -= A[i * p + k] * b[k]; b[i] = s / A[i * p + i]; }
  return true;
}

// Basis einer Ecke: p linear unabhaengige Beobachtungen mit den kleinsten
// Residuen |y_i - x_i'beta| (Gram-Schmidt fuer die Unabhaengigkeit).
static std::vector<int> qr_pick(const simlev_host::NumVec& y, const simlev_host::NumMat& X, const std::vector<double>& beta) {
  const int n = X.nrow(), p = X.ncol();
  std::vector<double> r(n);
  for (int i = 0; i < n; ++i) { double fit = 0.0; for (int j = 0; j < p; ++j) fit += X(i, j) * beta[j]; r[i] = std::fabs(y[i] - fit); }
  std::vector<int> ord(n); std::iota(ord.begin(), ord.end(), 0);
  std::sort(ord.begin(), ord.end(), [&](int a, int b) { return r[a] < r[b]; });
  std::vector<int> pick; std::vector<double> Q;
  for (int idx = 0; idx < n && (int) pick.size() < p; ++idx) {
    const int i = ord[idx];
    std::vector<double> v(p); double nv = 0.0, n0 = 0.0;
    for (int j = 0; j < p; ++j) { v[j] = X(i, j); n0 += v[j] * v[j]; }
    for (int q = 0; q < (int) pick.size(); ++q) { double d = 0.0; for (int j = 0; j < p; ++j) d += Q[q * p + j] * v[j];
      for (int j = 0; j < p; ++j) v[j] -= d * Q[q * p + j]; }
    for (int j = 0; j < p; ++j) nv += v[j] * v[j];
    if (nv <= 1e-10 * std::max(n0, 1e-300)) continue;
    nv = std::sqrt(nv); for (int j = 0; j < p; ++j) Q.push_back(v[j] / nv);
    pick.push_back(i);
  }
  return pick;
}

// Inverse einer p x p-Matrix (zeilenweise) per Gauss-Jordan mit Pivotsuche.
static bool invert_small(std::vector<double> A, std::vector<double>& Inv, int p) {
  Inv.assign(p * p, 0.0); for (int i = 0; i < p; ++i) Inv[i * p + i] = 1.0;
  for (int c = 0; c < p; ++c) {
    int piv = c; for (int r = c + 1; r < p; ++r) if (std::fabs(A[r * p + c]) > std::fabs(A[piv * p + c])) piv = r;
    if (std::fabs(A[piv * p + c]) < 1e-300) return false;
    if (piv != c) for (int k = 0; k < p; ++k) { std::swap(A[c * p + k], A[piv * p + k]); std::swap(Inv[c * p + k], Inv[piv * p + k]); }
    const double d = A[c * p + c];
    for (int k = 0; k < p; ++k) { A[c * p + k] /= d; Inv[c * p + k] /= d; }
    for (int r = 0; r < p; ++r) if (r != c && A[r * p + c] != 0.0) {
      const double f = A[r * p + c];
      for (int k = 0; k < p; ++k) { A[r * p + k] -= f * A[c * p + k]; Inv[r * p + k] -= f * Inv[c * p + k]; }
    }
  }
  return true;
}

// Optimalitaetsnachweis an einer entarteten Ecke: Das Teildifferential enthaelt
// 0 genau dann, wenn es lambda_j in [tau - 1, tau] (j in G = Basis und weitere
// Nullresiduen) gibt mit sum_j lambda_j x_j = v, v = -sum_{r_i != 0} psi_tau(r_i) x_i
// (Koenker 2005, Abschnitt 2.2). Geprueft als lineares Zulaessigkeitsproblem:
// gleiche Zeilen x_j werden zusammengefasst (k gleiche Zeilen: lambda in
// [k (tau - 1), k tau]), dann Phase 1 des Simplex-Verfahrens mit beschraenkten
// Variablen mu = lambda - k (tau - 1) in [0, k] und p Hilfsvariablen (Auswahl
// nach Dantzig, bei Stillstand Bland-Regel gegen Kreisen). Zulaessig, wenn die Summe der Hilfsvariablen auf 0 faellt
// (relativ 1e-9 zur Groessenordnung von v und der Erzeugenden).
static bool qr_subgrad_lp(const simlev_host::NumMat& X, const std::vector<int>& G, const std::vector<double>& v, double tau) {
  const int p = X.ncol();
  std::vector<int> o(G);
  std::sort(o.begin(), o.end(), [&](int a, int b) { for (int j = 0; j < p; ++j) { if (X(a, j) != X(b, j)) return X(a, j) < X(b, j); } return a < b; });
  std::vector<double> A; std::vector<double> U;                 // A spaltenweise (Spalte q: A[q * p + i])
  for (int t = 0; t < (int) o.size(); ++t) {
    bool same = t > 0; for (int j = 0; j < p && same; ++j) same = X(o[t], j) == X(o[t - 1], j);
    if (same) { U.back() += 1.0; continue; }
    for (int j = 0; j < p; ++j) A.push_back(X(o[t], j));
    U.push_back(1.0);
  }
  const int m = (int) U.size(), nv = m + p;                     // Variablen: m Erzeugende, dann p Hilfsvariablen
  std::vector<double> w(v), sgn(p);
  double S = 0.0;
  for (int i = 0; i < p; ++i) {
    double si = std::fabs(v[i]);
    for (int q = 0; q < m; ++q) { w[i] -= (tau - 1.0) * U[q] * A[q * p + i]; si += U[q] * std::fabs(A[q * p + i]); }
    sgn[i] = w[i] >= 0.0 ? 1.0 : -1.0; S = std::max(S, si);
  }
  const double ftol = 1e-9 * std::max(S, 1e-300);
  auto col = [&](int k, int i) { return k < m ? A[k * p + i] : (k - m == i ? sgn[i] : 0.0); };
  std::vector<int> basis(p); std::vector<char> upper(nv, 0), inb(nv, 0);
  for (int i = 0; i < p; ++i) { basis[i] = m + i; inb[m + i] = 1; }
  std::vector<double> B(p * p), Bi, rhs(p), xB(p), pi(p), al(p);
  const int maxit = 50 * nv + 1000;
  double obj_old = INFINITY; int stall = 0;
  for (int it = 0; it < maxit; ++it) {
    for (int i = 0; i < p; ++i) for (int r = 0; r < p; ++r) B[i * p + r] = col(basis[r], i);
    if (!invert_small(B, Bi, p)) return false;
    for (int i = 0; i < p; ++i) { rhs[i] = w[i]; for (int q = 0; q < m; ++q) if (upper[q]) rhs[i] -= U[q] * A[q * p + i]; }
    double obj = 0.0;
    for (int r = 0; r < p; ++r) { double s = 0.0; for (int i = 0; i < p; ++i) s += Bi[r * p + i] * rhs[i]; xB[r] = s;
      if (basis[r] >= m) obj += s; }
    if (obj <= ftol) return true;
    if (obj < obj_old - 1e-12 * S) stall = 0; else ++stall;
    obj_old = std::min(obj_old, obj);
    for (int i = 0; i < p; ++i) { double s = 0.0; for (int r = 0; r < p; ++r) if (basis[r] >= m) s += Bi[r * p + i]; pi[i] = s; }
    // Eintretende Variable: groesste Verbesserung je Einheit (Dantzig); nach
    // mehreren Schritten ohne Fortschritt kleinster zulaessiger Index (Bland)
    const bool bland = stall > 2 * p + 10;
    int ent = -1; double dir = 0.0, dbest = 0.0;
    for (int q = 0; q < m; ++q) if (!inb[q]) {
      double d = 0.0; for (int i = 0; i < p; ++i) d -= pi[i] * A[q * p + i];
      const double gain = upper[q] ? d : -d;
      if (gain > 1e-11 && gain > dbest) { ent = q; dir = upper[q] ? -1.0 : 1.0; dbest = gain; if (bland) break; }
    }
    if (ent < 0) return false;                                    // Phase-1-Optimum > 0: unzulaessig
    double amax = 0.0;
    for (int r = 0; r < p; ++r) { double s = 0.0; for (int i = 0; i < p; ++i) s += Bi[r * p + i] * A[ent * p + i]; al[r] = dir * s; amax = std::max(amax, std::fabs(s)); }
    const double ptol = 1e-12 * std::max(amax, 1.0);
    double tmax = U[ent]; int leave = -1; bool to_upper = false;
    for (int r = 0; r < p; ++r) {
      const int k = basis[r]; double lim;
      if (al[r] > ptol) lim = std::max(xB[r], 0.0) / al[r];
      else if (al[r] < -ptol && k < m) lim = std::max(U[k] - xB[r], 0.0) / -al[r];
      else continue;
      if (lim < tmax || (lim == tmax && leave >= 0 && k < basis[leave])) { tmax = lim; leave = r; to_upper = al[r] < 0.0; }
    }
    if (leave < 0) { upper[ent] = !upper[ent]; continue; }        // nur Schranke gewechselt
    const int k = basis[leave];
    inb[k] = 0; if (k < m) upper[k] = to_upper;                   // Hilfsvariablen kehren nicht zurueck
    basis[leave] = ent; inb[ent] = 1; upper[ent] = 0;
  }
  return false;
}

// Ecken-Politur: Die exakte Loesung der Quantilsregression interpoliert p
// Beobachtungen (eine Ecke des linearen Programms). Aus den p Beobachtungen
// mit den kleinsten Residuen der MM-Naeherung (linear unabhaengig gewaehlt)
// wird die Ecke berechnet. Rueckgabe: 0 = keine bessere Ecke, 1 = Ecke
// besser als die Naeherung, 2 = Ecke nachweislich optimal (Subgradienten-
// bedingung: X_h' lambda = -sum_{i nicht in h} psi_tau(r_i) x_i mit
// lambda in [tau - 1, tau], Koenker 2005, Abschnitt 2.2; bei weiteren
// Nullresiduen ueber qr_subgrad_lp()).
static int qr_polish(const simlev_host::NumVec& y, const simlev_host::NumMat& X, const std::vector<double>& beta,
                     double tau, std::vector<double>& out) {
  const int n = X.nrow(), p = X.ncol();
  std::vector<int> pick = qr_pick(y, X, beta);
  if ((int) pick.size() < p) return 0;
  std::vector<double> A(p * p), b(p);
  for (int a = 0; a < p; ++a) { b[a] = y[pick[a]]; for (int j = 0; j < p; ++j) A[a * p + j] = X(pick[a], j); }
  if (!solve_general(A, b, p)) return 0;
  const double f_mm = qr_objective(y, X, beta, tau), f_v = qr_objective(y, X, b, tau);
  if (!(f_v <= f_mm)) return 0;
  out = b;
  // Optimalitaetsnachweis
  std::vector<char> inh(n, 0); for (int a = 0; a < p; ++a) inh[pick[a]] = 1;
  std::vector<double> g(p, 0.0);
  double yscale = 0.0; for (int i = 0; i < n; ++i) yscale = std::max(yscale, std::fabs(y[i]));
  std::vector<int> Z;
  for (int i = 0; i < n; ++i) if (!inh[i]) {
    double fit = 0.0; for (int j = 0; j < p; ++j) fit += X(i, j) * b[j];
    const double ri = y[i] - fit;
    if (std::fabs(ri) <= 1e-12 * (1.0 + yscale)) { Z.push_back(i); continue; }   // weiteres Nullresiduum
    const double psi = tau - (ri < 0.0 ? 1.0 : 0.0);
    for (int j = 0; j < p; ++j) g[j] += psi * X(i, j);
  }
  if (!Z.empty()) {                                               // entartete Ecke: Nachweis per LP
    std::vector<int> G(pick.begin(), pick.end()); G.insert(G.end(), Z.begin(), Z.end());
    std::vector<double> v(p); for (int j = 0; j < p; ++j) v[j] = -g[j];
    return qr_subgrad_lp(X, G, v, tau) ? 2 : 1;
  }
  std::vector<double> At(p * p), lam(p);                          // X_h' lambda = -g
  for (int a = 0; a < p; ++a) for (int j = 0; j < p; ++j) At[j * p + a] = A[a * p + j];
  for (int j = 0; j < p; ++j) lam[j] = -g[j];
  if (!solve_general(At, lam, p)) return 1;
  for (int a = 0; a < p; ++a) if (lam[a] < tau - 1.0 - 1e-9 || lam[a] > tau + 1e-9) return 1;
  return 2;
}

// Exakter Abschluss per Austauschschritten (Simplex-Verfahren auf den Ecken,
// wie Barrodale & Roberts 1974): An der Ecke mit Basis h (X_h b = y_h) ist
// D = X_h^{-1}; die Kante "Beobachtung a verlaesst die Basis" hat die Richtung
// s * D[, a] (s = +1 bzw. -1). Ihre Richtungsableitung ist exakt
//   (1 - tau) + lambda_a  bzw.  tau - lambda_a,   lambda = -D' g,
// zuzueglich der Beitraege weiterer Beobachtungen mit Residuum 0. Solange eine
// Kante abwaerts fuehrt, wird entlang der steilsten Kante bis zum Minimum der
// stueckweise linearen Zielfunktion gegangen (gewichteter Median der Knicke);
// die dort auf 0 fallende Beobachtung tritt in die Basis ein. Die Zielfunktion
// faellt dabei streng, ein Kreisen ist ausgeschlossen. Rueckgabe: 2 = keine
// Abstiegskante und Optimalitaet nachgewiesen (ohne weitere Nullresiduen
// ueber lambda, sonst ueber qr_subgrad_lp()), 1 = keine Abstiegskante,
// Nachweis gescheitert (entartete Ecke), 0 = Abbruch (Rundung, singulaere
// Basis). out = letzte Ecke.
static int qr_exchange(const simlev_host::NumVec& y, const simlev_host::NumMat& X, double tau, std::vector<int> h,
                       std::vector<double>& out) {
  const int n = X.nrow(), p = X.ncol();
  if ((int) h.size() != p) return 0;
  double yscale = 0.0; for (int i = 0; i < n; ++i) yscale = std::max(yscale, std::fabs(y[i]));
  std::vector<double> A(p * p), D(p * p), b(p), r(n), g(p), lam(p), c(n), e(p);
  std::vector<char> inh(n);
  double f_old = INFINITY;
  const int maxit = 20 * n + 100;
  for (int it = 0; it < maxit; ++it) {
    for (int a = 0; a < p; ++a) { b[a] = y[h[a]]; for (int j = 0; j < p; ++j) A[a * p + j] = X(h[a], j); }
    if (!solve_general(A, b, p)) return 0;
    for (int col = 0; col < p; ++col) {                           // D = X_h^{-1} (D[j * p + a])
      std::fill(e.begin(), e.end(), 0.0); e[col] = 1.0;
      if (!solve_general(A, e, p)) return 0;
      for (int j = 0; j < p; ++j) D[j * p + col] = e[j];
    }
    std::fill(inh.begin(), inh.end(), 0); for (int a = 0; a < p; ++a) inh[h[a]] = 1;
    double f = 0.0, fscale = yscale;
    for (int i = 0; i < n; ++i) { double fit = 0.0; for (int j = 0; j < p; ++j) fit += X(i, j) * b[j];
      r[i] = y[i] - fit; fscale = std::max(fscale, std::fabs(fit)); f += r[i] * (tau - (r[i] < 0.0 ? 1.0 : 0.0)); }
    if (f > f_old + 1e-12 * (1.0 + std::fabs(f_old))) return 0;   // kein Fortschritt (Rundung)
    out = b; f_old = f;
    const double ztol = 1e-12 * (1.0 + fscale);
    std::fill(g.begin(), g.end(), 0.0);
    std::vector<int> Z;
    for (int i = 0; i < n; ++i) if (!inh[i]) {
      if (std::fabs(r[i]) <= ztol) { Z.push_back(i); continue; }
      const double psi = tau - (r[i] < 0.0 ? 1.0 : 0.0);
      for (int j = 0; j < p; ++j) g[j] += psi * X(i, j);
    }
    for (int a = 0; a < p; ++a) { double s = 0.0; for (int j = 0; j < p; ++j) s += D[j * p + a] * g[j]; lam[a] = -s; }
    const int nz = (int) Z.size();
    std::vector<double> K(nz * p);                                // x_j' D fuer Nullresiduen
    for (int z = 0; z < nz; ++z) for (int a = 0; a < p; ++a) {
      double s = 0.0; for (int j = 0; j < p; ++j) s += X(Z[z], j) * D[j * p + a]; K[z * p + a] = s; }
    double best = -1e-9; int ba = -1, bs = 0;
    for (int a = 0; a < p; ++a) for (int s = 1; s >= -1; s -= 2) {
      double sl = s > 0 ? (1.0 - tau) + lam[a] : tau - lam[a];
      for (int z = 0; z < nz; ++z) { const double cj = s * K[z * p + a]; sl += cj > 0.0 ? (1.0 - tau) * cj : -tau * cj; }
      if (sl < best) { best = sl; ba = a; bs = s; }
    }
    if (ba < 0) {                                                 // keine Abstiegskante
      if (p == 1 || nz == 0) return 2;
      std::vector<int> G(h.begin(), h.end()); G.insert(G.end(), Z.begin(), Z.end());
      std::vector<double> v(p); for (int j = 0; j < p; ++j) v[j] = -g[j];
      return qr_subgrad_lp(X, G, v, tau) ? 2 : 1;
    }
    // Liniensuche entlang s * D[, a]: Knicke bei t_i = r_i / c_i > 0
    std::vector<std::pair<double, int> > kinks;
    for (int i = 0; i < n; ++i) if (!inh[i]) {
      double ci = 0.0; for (int j = 0; j < p; ++j) ci += X(i, j) * D[j * p + ba];
      c[i] = bs * ci;
      if (std::fabs(r[i]) <= ztol || c[i] == 0.0) continue;
      const double t = r[i] / c[i];
      if (t > 0.0) kinks.push_back(std::make_pair(t, i));
    }
    std::sort(kinks.begin(), kinks.end());
    double sl = best; int inew = -1;
    for (int k = 0; k < (int) kinks.size(); ++k) { sl += std::fabs(c[kinks[k].second]); if (sl >= 0.0) { inew = kinks[k].second; break; } }
    if (inew < 0) return 0;
    h[ba] = inew;
  }
  return 0;
}

static auto quantile_reg_core(simlev_host::NumVec y, simlev_host::NumMat X, double tau, simlev_host::NumVec beta0, double sc, double tol, int maxit) {
  const int n = X.nrow(), p = X.ncol();
  std::vector<double> beta(beta0.begin(), beta0.end()), nb(p), A(p * p), c1(p, 0.0), r(n), w(n);
  if (p == 0) return SIMLEV_DONE(SIMLEV_NUM(0));
  // seit 1.6.4 (B-030): tau in [0, 1] (bis 1.6.3 lieferte tau = NaN still Zahlen); die Aufrufer pruefen vorher
  if (!(tau >= 0.0 && tau <= 1.0)) SIMLEV_FAIL("Quantilsregression: tau muss in [0, 1] liegen.");
  bool proven = false;
  for (int j = 0; j < p; ++j) { double s = 0.0; for (int i = 0; i < n; ++i) s += X(i, j); c1[j] = s * (tau - 0.5); }
  const double epss[4] = {1e-2, 1e-4, 1e-6, 1e-8};
  for (int e = 0; e < 4; ++e) {
    const double eps = sc * epss[e];
    bool early = false;
    for (int it = 0; it < maxit; ++it) {
      for (int i = 0; i < n; ++i) { double fit = 0.0; for (int j = 0; j < p; ++j) fit += X(i, j) * beta[j];
        r[i] = y[i] - fit; w[i] = 1.0 / (2.0 * (eps + std::fabs(r[i]))); }
      std::fill(A.begin(), A.end(), 0.0);
      for (int j = 0; j < p; ++j) {
        double s = c1[j];
        for (int i = 0; i < n; ++i) s += X(i, j) * w[i] * y[i];
        nb[j] = s;
        for (int k = 0; k <= j; ++k) { double a = 0.0; for (int i = 0; i < n; ++i) a += X(i, j) * w[i] * X(i, k); A[j * p + k] = a; A[k * p + j] = a; }
      }
      if (!solve_spd(A, nb, p)) SIMLEV_FAIL("Quantilsregression: singul\u00e4res Gleichungssystem.");
      double dmax = 0.0, bmax = 0.0;
      for (int j = 0; j < p; ++j) { dmax = std::max(dmax, std::fabs(nb[j] - beta[j])); bmax = std::max(bmax, std::fabs(beta[j])); }
      // fruehe Stufen nur grob loesen; das Ergebnis haengt nicht davon ab, weil
      // am Ende die nachweislich optimale Ecke (oder die feinste Stufe) zaehlt
      const bool done = dmax <= (e < 3 ? std::max(tol, 1e-7) : tol) * (1.0 + bmax);
      beta = nb;
      if (done) break;
      if (it % 25 == 24) {                                     // unterwegs: Ecke schon nachweislich optimal?
        std::vector<double> vb;
        if (qr_polish(y, X, beta, tau, vb) == 2) { beta = vb; proven = true; early = true; break; }
      }
    }
    if (early) break;
    // Ecke pruefen: nachweislich optimal -> fertig (exakt); sonst naechste Stufe
    std::vector<double> vb;
    const int st = qr_polish(y, X, beta, tau, vb);
    if (st == 2) { beta = vb; proven = true; break; }
    if (e == 3) {
      // kein Nachweis bis zur feinsten Stufe: exakter Abschluss per
      // Austauschschritten, ausgehend von der Ecke der MM-Naeherung
      const double f_mm = qr_objective(y, X, beta, tau);
      std::vector<double> xb;
      const int sx = qr_exchange(y, X, tau, qr_pick(y, X, beta), xb);
      if (sx == 2) { beta = xb; proven = true; }
      else if ((int) xb.size() == p && qr_objective(y, X, xb, tau) <= f_mm) beta = xb;
      else if (st == 1) beta = vb;
    }
  }
  auto out = SIMLEV_COPY_VEC(beta.begin(), beta.end());
  SIMLEV_SET_FLAG(out, "optimal", proven);
  return SIMLEV_DONE(out);
}

// ---------------------------------------------------------------------------
// Hidden-Markov-Modell: skalierter Vorwaerts-Rueckwaerts-Schritt
// ---------------------------------------------------------------------------

// B: Emissionsdichten (T x K, je Zeile skaliert), A: Uebergangsmatrix (lda Zeilen), p0: Start. Ergebnisse auf
// Zeigern (al, be, ga T x K, xi K x K, cs T); seit 1.5.0 auch vom HMM-EM (hmm_em) genutzt. Seit 1.6.3 rechnet
// sl_hmm_fb (slc_msgarch.cpp, auch fuer den HMM-Start von MS-GARCH; gleiche Rechenfolge).
static void hmm_fb_raw(int T, int K, const double* B, const double* A, int lda, const double* p0, double* al,
                       double* be, double* ga, double* xi, double* cs) {
  std::vector<double> tmp(K);
  sl_hmm_fb(T, K, B, A, lda, p0, al, be, ga, xi, cs, tmp.data());
}

// ---------------------------------------------------------------------------
// Hidden-Markov-Modell: Baum-Welch-EM aus einem Startwert (seit 1.5.0; bis 1.4.3 .hmm_em/_hmm_em in den Sprachen)
// ---------------------------------------------------------------------------
// Gauss'sches HMM mit k Zustaenden auf X (Tn x d). Rechnung Schritt fuer Schritt wie die fruehere Sprachfassung:
//   E-Schritt: lB[, j] = -0.5 rowSums(Z^2) - sum(log(diag(L))) - 0.5 d log(2 pi), L = chol(S_j) (sl_chol),
//     Z = t(backsolve(L, t(X - mu_j), transpose = TRUE)) (sl_trisolve); m = Zeilenmaximum wie pmax (NA/NaN
//     gewinnt), Vorwaerts-Rueckwaerts auf exp(lB - m) (hmm_fb_raw), ll = sum(log(scale)) + sum(m).
//   M-Schritt: p0 = ga[1, ], A = xi / rowSums(xi), je j: w = ga[, j], mu_j = colSums(X w) / sum(w),
//     S_j = crossprod((X - mu_j) sqrt(w)) / sum(w) + ridge (sl_crossprod).
//   Abbruch, wenn |ll - ll_alt| < tol (1 + |ll|); danach ein E-Schritt zu den gelieferten Parametern.
// Summen wie R ueber slc_rbase (long double), log/exp/sqrt wie R's math1 (NaN bleibt).
// Rueckgabe 0 oder 1 = Fehler (R: Fehler in .hmm_em, z. B. Matrix nicht positiv definit, NA im Abbruchtest).
// mu (k x d), S (d x d x k), A (k x k) sind Start- und Ergebniswerte; p0 (k), ll, filt, smooth, lB (Tn x k), iter.
// R's log: sl_r_log1 (slc_rbase.h; seit 1.6.3 statt eigener Kopie hmm_r_log)
static inline double hmm_keepnan(double x, double y) { return std::isnan(x) ? x : y; }

static int hmm_em(int Tn, int d, int k, const double* X, double* mu, double* S, double* A, double* p0, int n_iter,
                  double tol, const double* ridge, double* ll_out, double* filt, double* smooth, double* lB, int* iter) {
  const std::size_t T = (std::size_t) Tn, D = (std::size_t) d, K = (std::size_t) k;
  std::vector<double> L(D * D), Bt(D * T), Z2(T * D), rs(T), ld(D), m(T), Be(T * K), be(T * K), xi(K * K), cs(T),
      lcs(T), w(T), xw(T * D), cmu(D), C(D * D), rsx(K);
  sl_ctx cx;
  const double c0 = 0.5 * d * std::log(2 * M_PI);
  if (n_iter < 0) return 1;   // seit 1.6.4 (B-030): bis 1.6.3 Erfolg mit iter = -1
  for (int j = 0; j < k; ++j) p0[j] = 1.0 / k;
  double ll = 0.0, ll_old = -std::numeric_limits<double>::infinity();
  auto estep = [&]() -> int {
    for (int j = 0; j < k; ++j) {
      sl_ctx_init(&cx);
      if (sl_chol(&cx, d, S + D * D * j, L.data()) != SL_OK) return 1;
      for (std::size_t t = 0; t < T; ++t)
        for (std::size_t c = 0; c < D; ++c) Bt[c + D * t] = X[t + T * c] - mu[j + K * c];
      if (sl_trisolve(&cx, d, Tn, L.data(), 1, 1, Bt.data()) != SL_OK) return 1;
      for (std::size_t t = 0; t < T; ++t)
        for (std::size_t c = 0; c < D; ++c) { const double z = Bt[c + D * t]; Z2[t + T * c] = z * z; }
      sl_r_rowsums(Tn, d, Z2.data(), 0, 0, rs.data());
      for (std::size_t c = 0; c < D; ++c) ld[c] = sl_r_log1(L[c + D * c]);
      const double sld = sl_r_sum(d, ld.data(), 0);
      for (std::size_t t = 0; t < T; ++t) lB[t + T * j] = -0.5 * rs[t] - sld - c0;
    }
    for (std::size_t t = 0; t < T; ++t) m[t] = lB[t];
    for (int j = 1; j < k; ++j)
      for (std::size_t t = 0; t < T; ++t) {                     // pmax(m, lB[, j])
        const double b = lB[t + T * j];
        if ((!std::isnan(m[t]) && !std::isnan(b) && b > m[t]) || std::isnan(b)) m[t] = b;
      }
    for (std::size_t j = 0; j < K; ++j)
      for (std::size_t t = 0; t < T; ++t) { const double v = lB[t + T * j] - m[t]; Be[t + T * j] = hmm_keepnan(v, std::exp(v)); }
    std::fill(xi.begin(), xi.end(), 0.0);
    hmm_fb_raw(Tn, k, Be.data(), A, k, p0, filt, be.data(), smooth, xi.data(), cs.data());
    for (std::size_t t = 0; t < T; ++t) lcs[t] = sl_r_log1(cs[t]);
    ll = sl_r_sum(Tn, lcs.data(), 0) + sl_r_sum(Tn, m.data(), 0);
    return 0;
  };
  int it = 0;
  for (it = 1; it <= n_iter; ++it) {
    SIMLEV_CHECK_INTERRUPT();
    if (estep()) return 1;
    for (int j = 0; j < k; ++j) p0[j] = smooth[T * j];
    sl_r_rowsums(k, k, xi.data(), 0, 0, rsx.data());
    for (std::size_t j = 0; j < K; ++j) for (std::size_t i = 0; i < K; ++i) A[i + K * j] = xi[i + K * j] / rsx[i];
    for (std::size_t j = 0; j < K; ++j) {
      const double* wj = smooth + T * j;
      const double sw = sl_r_sum(Tn, wj, 0);
      for (std::size_t c = 0; c < D; ++c) for (std::size_t t = 0; t < T; ++t) xw[t + T * c] = X[t + T * c] * wj[t];
      sl_r_colsums(Tn, d, xw.data(), 0, 0, cmu.data());
      for (std::size_t c = 0; c < D; ++c) mu[j + K * c] = cmu[c] / sw;
      for (std::size_t t = 0; t < T; ++t) w[t] = hmm_keepnan(wj[t], std::sqrt(wj[t]));
      for (std::size_t c = 0; c < D; ++c)
        for (std::size_t t = 0; t < T; ++t) xw[t + T * c] = (X[t + T * c] - mu[j + K * c]) * w[t];
      sl_crossprod(Tn, d, d, xw.data(), xw.data(), C.data());
      for (std::size_t q = 0; q < D * D; ++q) S[D * D * j + q] = C[q] / sw + ridge[q];
    }
    const double lhs = std::fabs(ll - ll_old), rhs = tol * (1 + std::fabs(ll));
    if (std::isnan(lhs) || std::isnan(rhs)) return 1;              // R: if (NA) -> Fehler
    if (lhs < rhs) break;
    ll_old = ll;
  }
  if (it > n_iter) it = n_iter;
  if (estep()) return 1;
  *ll_out = ll;
  *iter = it;
  return 0;
}

// ---------------------------------------------------------------------------
// Zielplanung: Rueckwaertsrekursion von planning_goal() ueber das Vermoegensgitter (seit 1.5.0; bis 1.4.3 in den
// Sprachen)
// ---------------------------------------------------------------------------
// R: S x K Brutto-Renditen, grid (ng, aufsteigend), cf (horizon Zahlungen), goal, wmin, wmax, sv (Startwert),
// tie_score (K: K + 1 - Rang der Streuung). Rechnung wie die fruehere Sprachfassung:
//   term(W) = W >= goal; interp(Vn, W): 1 * (wmax >= goal) fuer W >= wmax, 0 fuer W <= 0, dazwischen unter wmin
//     (goal > 0 ? 0 : Vn[1]), sonst pnorm(approx(log(grid), qnorm(pmin(1 - 1e-12, pmax(1e-12, Vn))), log(W),
//     rule = 2)) (sl_qnorm, sl_pnorm, sl_r_approx; approx wie ifelse() nur, wenn ein W in [wmin, wmax) liegt);
//   expect(Vn, base, k, last) = rowMeans(term bzw. interp von outer(base, R[, k])), 0 wo base <= 0;
//   static[k]: Rekursion mit festem Kandidaten, dann interp(., sv); Politik je Periode: erstes Maximum von
//   (E >= max - 1e-9) * tie_score (max.col, ties "first"), V = E[, pol]; p_dp = interp(V, sv).
// Haben log(grid) gleiche Werte, fasst approx sie wie R mit mean zusammen (je Aufruf eine Warnung
// "collapsing to unique 'x' values"): Rueckgabe = Zahl dieser approx-Aufrufe (sonst 0), -1 bei Fehler der Verteilungen.
// Ausgaben: stat (K), pol (horizon x ng, NA = INT_MIN), Vt (ng x (horizon + 1): Spalte t = Wertfunktion nach
// Periode t - 1, letzte = term(grid)), p_dp.
static int64_t goal_dp(int S, int K, const double* R, int ng, const double* grid, int horizon, const double* cf,
                       double goal, double wmin, double wmax, double sv, const double* tie_score, double* stat,
                       int* pol, double* Vt, double* p_dp) {
  const std::size_t NG = (std::size_t) ng, NS = (std::size_t) S;
  sl_ctx cx;
  bool bad = false;
  // seit 1.6.4 (B-030): Renditen und Startvermoegen endlich (bis 1.6.3 still Wahrscheinlichkeiten 1e-12/0/1); Fehler
  // wie bei der Normalverteilung (Rueckgabe -1), die Aufrufer pruefen vorher
  if (!std::isfinite(sv)) return -1;
  for (std::size_t i = 0; i < NS * (std::size_t) K; ++i) if (!std::isfinite(R[i])) return -1;
  // log(grid) und die Bindungen von approx (regularize.values mit ties = mean)
  std::vector<double> lg(NG);
  for (std::size_t i = 0; i < NG; ++i) lg[i] = sl_r_log1(grid[i]);
  std::vector<std::size_t> gs;                         // Anfang jeder Gruppe gleicher Werte
  for (std::size_t i = 0; i < NG; ++i) if (i == 0 || !(lg[i] == lg[i - 1])) gs.push_back(i);
  const bool ties = gs.size() < NG;
  std::vector<double> ux(gs.size()), uy(gs.size());
  for (std::size_t g = 0; g < gs.size(); ++g) ux[g] = lg[gs[g]];
  int64_t ncoll = 0;
  std::vector<double> p(NG), z(NG), lw, yo, X, v(NG);
  auto interp = [&](const double* Vn, std::size_t n, const double* W, double* out) {
    for (std::size_t i = 0; i < NG; ++i) {             // pmin(1 - 1e-12, pmax(1e-12, Vn))
      double a = 1e-12, t = Vn[i];
      if ((!std::isnan(a) && !std::isnan(t) && t > a) || std::isnan(t)) a = t;
      double b = 1 - 1e-12;
      if ((!std::isnan(b) && !std::isnan(a) && a < b) || std::isnan(a)) b = a;
      p[i] = b;
    }
    sl_ctx_init(&cx);
    if (sl_qnorm(&cx, ng, p.data(), 0.0, 1.0, 1, z.data()) != SL_OK) bad = true;
    const double* yy = z.data();
    if (ties) {
      for (std::size_t g = 0; g < gs.size(); ++g) {
        const std::size_t e = g + 1 < gs.size() ? gs[g + 1] : NG;
        uy[g] = sl_r_mean((int64_t) (e - gs[g]), z.data() + gs[g]);
      }
      yy = uy.data();
    }
    lw.clear();
    bool any_hi = false;                               // ifelse(): approx nur, wenn ein W[mid] >= wmin
    for (std::size_t i = 0; i < n; ++i)
      if (W[i] > 0 && W[i] < wmax) { lw.push_back(sl_r_log1(W[i])); if (!(W[i] < wmin)) any_hi = true; }
    if (ties && any_hi) ++ncoll;
    yo.assign(lw.size(), 0.0);
    sl_r_approx((int64_t) ux.size(), ux.data(), yy, (int64_t) lw.size(), lw.data(), 1, yy[0], yy[ux.size() - 1], 0.0,
                yo.data());
    sl_ctx_init(&cx);
    if (!yo.empty() && sl_pnorm(&cx, (int64_t) yo.size(), yo.data(), 0.0, 1.0, 1, yo.data()) != SL_OK) bad = true;
    const double alt = goal > 0 ? 0.0 : Vn[0];
    std::size_t q = 0;
    for (std::size_t i = 0; i < n; ++i) {
      double o = 0.0;
      if (W[i] >= wmax) o = 1 * (double) (wmax >= goal);
      if (W[i] <= 0) o = 0.0;
      if (W[i] > 0 && W[i] < wmax) { o = W[i] < wmin ? alt : yo[q]; ++q; }
      out[i] = o;
    }
  };
  auto expect = [&](const double* Vn, const std::vector<double>& base, int k, bool last, double* e) {
    X.resize(NG * NS);
    for (std::size_t s = 0; s < NS; ++s) {
      const double r = R[s + NS * (std::size_t) k];
      for (std::size_t i = 0; i < NG; ++i) X[i + NG * s] = base[i] * r;
    }
    if (last) for (std::size_t q = 0; q < NG * NS; ++q) X[q] = X[q] >= goal ? 1.0 : 0.0;
    else { std::vector<double> o(NG * NS); interp(Vn, NG * NS, X.data(), o.data()); X.swap(o); }
    sl_r_rowsums(ng, S, X.data(), 0, 1, e);
    for (std::size_t i = 0; i < NG; ++i) if (base[i] <= 0) e[i] = 0.0;
  };
  double* V = Vt + NG * (std::size_t) horizon;          // term(grid)
  for (std::size_t i = 0; i < NG; ++i) V[i] = grid[i] >= goal ? 1.0 : 0.0;
  std::vector<double> base(NG), Vs(NG), tmp(NG), one(1);
  for (int k = 0; k < K; ++k) {
    std::copy(V, V + NG, Vs.begin());
    for (int t = horizon; t >= 1; --t) {
      for (std::size_t i = 0; i < NG; ++i) base[i] = grid[i] + cf[t - 1];
      expect(Vs.data(), base, k, t == horizon, tmp.data());
      Vs.swap(tmp);
    }
    interp(Vs.data(), 1, &sv, one.data());
    stat[k] = one[0];
  }
  std::vector<double> E(NG * (std::size_t) K);
  const double* Vn = V;
  for (int t = horizon; t >= 1; --t) {
    SIMLEV_CHECK_INTERRUPT();
    for (std::size_t i = 0; i < NG; ++i) base[i] = grid[i] + cf[t - 1];
    for (int k = 0; k < K; ++k) expect(Vn, base, k, t == horizon, E.data() + NG * (std::size_t) k);
    double* Vo = Vt + NG * (std::size_t) (t - 1);
    for (std::size_t i = 0; i < NG; ++i) {
      double mx = 0.0; bool upd = false, na = false;  // max je Zeile wie R (NaN bleibt)
      for (int k = 0; k < K; ++k) {
        const double x = E[i + NG * k];
        if (std::isnan(x)) { na = true; if (!upd || !std::isnan(mx)) mx = x; upd = true; }
        else if (!upd || (!std::isnan(mx) && x > mx)) { mx = x; upd = true; }
      }
      int best = -1; double bs = 0.0;
      for (int k = 0; k < K && !na; ++k) {             // max.col(ifelse(E >= mx - 1e-9, tie_score, 0), "first")
        const double sc = E[i + NG * k] >= mx - 1e-9 ? tie_score[k] : 0.0;
        if (best < 0 || sc > bs) { best = k; bs = sc; }
      }
      if (na || best < 0) { pol[(t - 1) + (std::size_t) horizon * i] = INT_MIN; Vo[i] = SIMLEV_NA; }
      else { pol[(t - 1) + (std::size_t) horizon * i] = best + 1; Vo[i] = E[i + NG * best]; }
    }
    Vn = Vo;
  }
  interp(Vn, 1, &sv, one.data());
  *p_dp = one[0];
  return bad ? -1 : ncoll;
}

// ---------------------------------------------------------------------------
// CSCV von overfit_pbo() (seit 1.5.0; bis 1.4.3 in den Sprachen): je Aufteilung der S Bloecke in Haelften
// ---------------------------------------------------------------------------
// B: fuenf Blocksummen S x N (Reihenfolge B1 = R, B2 = (R - Mittel)^2, Bd = pmin(R, 0)^2, Bl = log1p(R), Bc = R - Mittel),
// T: deren Spaltensummen (5 x N), combos: S/2 x C (1-basiert, utils::combn), half = Beobachtungen je Haelfte,
// metric 0 sharpe, 1 sortino, 2 geometric, 3 mean. Wie die fruehere Sprachfassung in Bloecken zu 2000 Aufteilungen:
//   In-Sample-Summen = Ind %*% B (sl_matmul), Out-of-Sample = T - In-Sample; Kennzahl wie .of_metric
//   (m = s1 / n; sharpe m / sqrt(pmax((s2 - c1^2 / n) / (n - 1), 1e-300)), sortino m / sqrt(pmax(sdn / n, 1e-300)),
//   geometric expm1(sl / n), mean m); best = max.col(IS, "first") (NA bei NaN in der Zeile), ob = OOS[best],
//   Rang = #(OOS < ob) + (#(OOS == ob) + 1) / 2 (seit 1.6.5 mit Toleranz near_eq), w = Rang / (N + 1), lambda = log(w / (1 - w)), Median je Zeile
//   wie median.default (NA bei NA/NaN). NA wie R (NA_real_).
// Ausgaben lam, isb, oosb, oosm (je C).
// Seit 1.6.5 (CR2-P-1, Entscheidungen 187, 189): Sharpe bzw. Sortino einer Haelfte ohne Schwankung (Standardabweichung
// bzw. Abwaertsschwankung <= 1e-10 je Periode, Schwelle von .of_drop_flat) ist NA statt m / sqrt(1e-300) (bis 1.6.4
// ~1e146, der Punkt wurde in jeder solchen Aufteilung gewaehlt). CR2-P-2: bei "geometric" traegt c1 die Zahl der
// Totalverluste (Rendite <= -1; sl dann ohne diese Perioden); eine Haelfte mit Totalverlust hat die Kennzahl -1 (bis
// 1.6.4 -Inf - (-Inf) = NaN in allen Aufteilungen).
static inline double pbo_metric(double n, double s1, double s2, double sdn, double sl, double c1, int metric) {
  const double m = s1 / n, na = SIMLEV_NA;
  switch (metric) {
    case 0: {
      const double v = (s2 - c1 * c1 / n) / (n - 1);
      if (std::isnan(v)) return v;
      const double sd = v > 0 ? std::sqrt(v) : 0.0;
      return sd > 1e-10 ? m / sd : na;
    }
    case 1: {
      const double v = sdn / n;
      if (std::isnan(v)) return v;
      const double dd = v > 0 ? std::sqrt(v) : 0.0;
      return dd > 1e-10 ? m / dd : na;
    }
    case 2: {
      if (c1 > 0) return -1.0;
      const double x = sl / n; return std::isnan(x) ? x : std::expm1(x);
    }
    default: return m;
  }
}

// Vergleich mit Toleranz (seit 1.6.5, CR2-W2-1, Entscheidung 189; dieselbe Regel wie .near_eq in R):
// |a - b| <= 1e-12 * max(1, |a|, |b|); NaN ergibt false
static inline bool near_eq(double a, double b) {
  const double d = std::fabs(a - b);
  double s = std::fabs(a) > std::fabs(b) ? std::fabs(a) : std::fabs(b);
  if (!(s > 1.0)) s = 1.0;
  return d <= 1e-12 * s;
}

static void pbo_cscv(int S, int N, int C, const double* B, const double* T, const int* combos, double half, int metric,
                     double* lam, double* isb, double* oosb, double* oosm) {
  const std::size_t SN = (std::size_t) S * N, H = (std::size_t) (S / 2);
  const double na = SIMLEV_NA;
  std::vector<double> Ind, I(5), IS, OOS, row((std::size_t) N), acc((std::size_t) N);
  std::vector<std::vector<double>> Im(5);
  // Seit 1.6.4 (B-076): sind alle Blocksummen endlich, die In-Sample-Summen direkt als Summe der gewaehlten Bloecke in
  // aufsteigender Folge ab 0.0 (B zeilenweise umgelegt); das ist Bit fuer Bit sl_matmul mit der 0/1-Matrix Ind, weil
  // x + 0 b = x fuer endliches b (auch fuer +-0: die Summe ab +0.0 wird nie -0). Mit nicht endlichen Werten (0 Inf =
  // NaN wie R's %*%) oder nicht aufsteigenden Kombinationen wie bisher ueber sl_matmul.
  bool fin = true;
  for (std::size_t i = 0; i < 5 * SN && fin; ++i) fin = std::isfinite(B[i]);
  std::vector<double> Bt;
  if (fin) {
    Bt.resize(5 * SN);
    for (int b = 0; b < 5; ++b)
      for (std::size_t j = 0; j < (std::size_t) N; ++j)
        for (std::size_t l = 0; l < (std::size_t) S; ++l) Bt[SN * b + l * N + j] = B[SN * b + l + (std::size_t) S * j];
  }
  for (int st = 0; st < C; st += 2000) {
    SIMLEV_CHECK_INTERRUPT();
    const int k = std::min(C, st + 2000) - st;
    const std::size_t K = (std::size_t) k;
    bool asc = fin;
    for (std::size_t r = 0; r < K && asc; ++r)
      for (std::size_t q = 1; q < H; ++q)
        if (combos[q + H * (st + r)] <= combos[q - 1 + H * (st + r)]) { asc = false; break; }
    if (asc) {
      for (int b = 0; b < 5; ++b) {
        Im[b].resize(K * N);
        const double* Bb = Bt.data() + SN * b;
        for (std::size_t r = 0; r < K; ++r) {
          std::fill(acc.begin(), acc.end(), 0.0);
          for (std::size_t q = 0; q < H; ++q) {
            const double* br = Bb + (std::size_t) (combos[q + H * (st + r)] - 1) * N;
            for (std::size_t j = 0; j < (std::size_t) N; ++j) acc[j] += br[j];
          }
          for (std::size_t j = 0; j < (std::size_t) N; ++j) Im[b][r + K * j] = acc[j];
        }
      }
    } else {
      Ind.assign(K * S, 0.0);
      for (std::size_t r = 0; r < K; ++r)
        for (std::size_t q = 0; q < H; ++q) Ind[r + K * (std::size_t) (combos[q + H * (st + r)] - 1)] = 1.0;
      for (int b = 0; b < 5; ++b) { Im[b].resize(K * N); sl_matmul(k, S, N, Ind.data(), B + SN * b, Im[b].data()); }
    }
    IS.resize(K * N); OOS.resize(K * N);
    for (std::size_t j = 0; j < (std::size_t) N; ++j)
      for (std::size_t r = 0; r < K; ++r) {
        const std::size_t q = r + K * j;
        IS[q] = pbo_metric(half, Im[0][q], Im[1][q], Im[2][q], Im[3][q], Im[4][q], metric);
        OOS[q] = pbo_metric(half, T[j] - Im[0][q], T[N + j] - Im[1][q], T[2 * N + j] - Im[2][q], T[3 * N + j] - Im[3][q],
                            T[4 * N + j] - Im[4][q], metric);
      }
    for (std::size_t r = 0; r < K; ++r) {
      const std::size_t c = st + r;
      bool rna = false;                                  // max.col(IS, ties.method = "first")
      for (int j = 0; j < N; ++j) if (std::isnan(IS[r + K * j])) { rna = true; break; }
      // seit 1.6.5 (CR2-W2-1): der erste Punkt, dessen Kennzahl dem Hoechstwert bis auf 1e-12 relativ gleicht
      int best = 0;
      if (!rna) {
        double a = IS[r]; for (int j = 1; j < N; ++j) { const double b = IS[r + K * j]; if (a < b) a = b; }
        for (int j = 0; j < N; ++j) if (near_eq(IS[r + K * j], a)) { best = j; break; }
      }
      const double ob = rna ? na : OOS[r + K * best];
      isb[c] = rna ? na : IS[r + K * best];
      oosb[c] = ob;
      bool ona = false;
      for (int j = 0; j < N; ++j) { row[j] = OOS[r + K * j]; if (std::isnan(row[j])) ona = true; }
      if (rna || ona || std::isnan(ob)) lam[c] = na;
      else {
        double lt = 0.0, eq = 0.0;                     // seit 1.6.5 (CR2-W2-1): Gleichstand mit Toleranz (near_eq)
        for (int j = 0; j < N; ++j) { const bool e = near_eq(row[j], ob); lt += (!e && row[j] < ob); eq += e; }
        const double w = (lt + (eq + 1) / 2) / (N + 1);
        lam[c] = sl_r_log1(w / (1 - w));
      }
      if (ona) oosm[c] = na;                             // median.default
      else {
        const std::size_t hh = ((std::size_t) N + 1) / 2;
        std::nth_element(row.begin(), row.begin() + (hh - 1), row.end());
        if (N % 2 == 1) oosm[c] = row[hh - 1];
        else { double two[2] = {row[hh - 1], *std::min_element(row.begin() + hh, row.end())}; oosm[c] = sl_r_mean(2, two); }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Rollierender Mittelwert (Fenster n inklusive aktueller Zeile)
// ---------------------------------------------------------------------------

// Gleitende Summe mit Neumaier-Kompensation; alle 4096 Schritte wird die
// Fenstersumme neu aufgebaut, damit sich keine Rundungsfehler ansammeln.
// NA/NaN im Fenster ergeben NA (wie die kumulierte Summe in R). Seit 1.6.3 ueber sl_roll_mean (slc_msgarch.cpp).
static auto roll_mean_core(simlev_host::NumVec x, int n) {
  const int m = x.size();
  auto out = SIMLEV_NUM(m, SIMLEV_NA);
  if (n < 1 || n > m) return SIMLEV_DONE(out);
  sl_roll_mean(m, &x[0], n, SIMLEV_NA, &out[0]);
  return SIMLEV_DONE(out);
}

// ---------------------------------------------------------------------------
// Rollierendes Maximum (seit 1.6.3; Fenster w inklusive aktueller Zeile, am Anfang verkuerzt)
// ---------------------------------------------------------------------------

// out[i] = max(x[max(0, i - w + 1) .. i]) fuer i = 0 .. m - 1, mit NaN (auch NA) als -Inf: das Hoch von
// signal_drawdown(window = w) (R signals.R, Python signals.py, Julia signals.jl: xp = NaN -> -Inf, je Zeile
// max/np.max/maximum ueber das Fenster, O(m w)) in O(m) ueber eine monotone Schlange der Zeilen (jede Zeile kommt
// einmal hinein und hoechstens einmal heraus). Gleich grosse Werte unterscheiden sich nur bei -0/+0; zero waehlt:
//   0  der frueheste unter den groessten Werten des Fensters (R: max() = rmax mit '>', erstes Auftreten);
//   1  -0 < +0 (Julia: maximum, "maximum([0.0, -0.0]) === 0.0").
// Python (np.max) haengt bei gemischten Nullen von den SIMD-Bahnen von numpy ab und ist dort keiner der Regeln
// gleich; sonst (kein Fenster, dessen Maximum 0 ist und beide Vorzeichen enthaelt) ist jede Regel bitgleich.
// Gelesen wird nur x, geschrieben nur out (m Werte, Speicher des Aufrufers; x und out duerfen nicht ueberlappen).
// Rueckgabe 0 in Ordnung, 1 w < 1 oder zero nicht 0/1 (dann bleibt out unveraendert; die Sprachen behalten fuer
// w < 1 ihren bisherigen Weg). w > m wirkt wie w = m (kumuliertes Maximum). m = 0: nichts zu tun.
static inline int roll_max_core(int64_t m, const double* x, int64_t w, int zero, double* out) {
  if (w < 1 || (zero != 0 && zero != 1)) return 1;
  if (m <= 0) return 0;
  if (w > m) w = m;
  std::vector<int64_t> q((std::size_t) m);   // Zeilennummern, Werte fallend (zero 0: nicht steigend)
  std::vector<double> v((std::size_t) m);    // x mit NaN -> -Inf
  int64_t h = 0, t = 0;                      // Schlange q[h .. t - 1]
  for (int64_t i = 0; i < m; ++i) {
    const double xi = std::isnan(x[i]) ? -INFINITY : x[i];
    v[(std::size_t) i] = xi;
    if (zero == 0) {
      while (t > h && v[(std::size_t) q[(std::size_t) (t - 1)]] < xi) --t;      // gleiche bleiben (frueheste vorn)
    } else {
      while (t > h) {
        const double b = v[(std::size_t) q[(std::size_t) (t - 1)]];
        if (b < xi || (b == xi && std::signbit(b) && !std::signbit(xi))) --t;  // -0 < +0
        else break;
      }
    }
    q[(std::size_t) t++] = i;
    if (q[(std::size_t) h] <= i - w) ++h;     // vorderste Zeile faellt aus dem Fenster
    out[i] = v[(std::size_t) q[(std::size_t) h]];
  }
  return 0;
}

// ---------------------------------------------------------------------------
// Kendalls Tau-b in O(n log n) (Knight 1966)
// ---------------------------------------------------------------------------

// Zaehlt die Vertauschungen beim stabilen Sortieren von y (Merge-Sort).
static long long merge_count(std::vector<double>& y, std::vector<double>& buf, int lo, int hi) {
  if (hi - lo < 2) return 0;
  const int mid = (lo + hi) / 2;
  long long s = merge_count(y, buf, lo, mid) + merge_count(y, buf, mid, hi);
  int i = lo, j = mid, k = lo;
  while (i < mid && j < hi) {
    if (y[j] < y[i]) { buf[k++] = y[j++]; s += mid - i; }
    else buf[k++] = y[i++];
  }
  while (i < mid) buf[k++] = y[i++];
  while (j < hi) buf[k++] = y[j++];
  for (int t = lo; t < hi; ++t) y[t] = buf[t];
  return s;
}

// double-double-Hilfen fuer kendall_tau_core. Kein fma (fp-contract off). Quellen: Dekker, T. J. (1971).
// A floating-point technique for extending the available precision. Numerische Mathematik 18(3), 224-242
// (exakte Summe und Produkt mit Aufspaltung 2^27 + 1); Shewchuk, J. R. (1997). Adaptive precision
// floating-point arithmetic and fast robust geometric predicates. Discrete & Computational Geometry 18(3),
// 305-363 (Two-Sum, Fast-Two-Sum). Eigene Umsetzung.
struct kt_dd { double hi, lo; };
static inline kt_dd kt_fast_two_sum(double a, double b) {   // |a| >= |b|
  const double s = a + b;
  return {s, b - (s - a)};
}
static inline void kt_split(double a, double& hi, double& lo) {
  const double c = 134217729.0 * a;                        // 2^27 + 1
  hi = c - (c - a); lo = a - hi;
}
static inline kt_dd kt_two_prod(double a, double b) {
  double ah, al, bh, bl;
  const double p = a * b;
  kt_split(a, ah, al); kt_split(b, bh, bl);
  return {p, ((ah * bh - p) + ah * bl + al * bh) + al * bl};
}
static inline kt_dd kt_from_ll(long long v) {               // exakt fuer |v| < 2^62
  const double hi = (double) v;
  return {hi, (double) (v - (long long) hi)};
}
// num / sqrt(A B) fuer ganze Zahlen A, B > 0, |num| <= max(A, B) < 2^62, auf double gerundet
static double kt_ratio(long long num, long long A, long long B) {
  const kt_dd a = kt_from_ll(A), b = kt_from_ll(B), z = kt_from_ll(num);
  kt_dd p = kt_two_prod(a.hi, b.hi);                       // P = A B
  p = kt_fast_two_sum(p.hi, p.lo + ((a.hi * b.lo + a.lo * b.hi) + a.lo * b.lo));
  const double s0 = std::sqrt(p.hi);                       // S = sqrt(P), ein Newton-Schritt
  const kt_dd q = kt_two_prod(s0, s0);
  const kt_dd sq = kt_fast_two_sum(s0, (((p.hi - q.hi) - q.lo) + p.lo) / (2.0 * s0));
  const double t0 = z.hi / sq.hi;                          // num / S, eine Korrektur
  const kt_dd t = kt_two_prod(t0, sq.hi);
  const double rem = (((z.hi - t.hi) - t.lo) - t0 * sq.lo) + z.lo;
  return t0 + rem / sq.hi;
}

static double kendall_tau_core(simlev_host::NumVec x, simlev_host::NumVec y) {
  const int n = x.size();
  if (n < 2) return SIMLEV_NA;
  // seit 1.6.4 (B-030): NaN/NA ergibt NA wie R .kendall (bis 1.6.3 sortierte std::sort mit NaN ohne strenge Ordnung,
  // ein undefiniertes Verhalten, und lieferte still Zahlen); die Aufrufer filtern vorher
  for (int i = 0; i < n; ++i) if (x[i] != x[i] || y[i] != y[i]) return SIMLEV_NA;
  std::vector<int> o(n); std::iota(o.begin(), o.end(), 0);
  std::sort(o.begin(), o.end(), [&](int a, int b) { return x[a] < x[b] || (x[a] == x[b] && y[a] < y[b]); });
  std::vector<double> ys(n), buf(n);
  for (int i = 0; i < n; ++i) ys[i] = y[o[i]];
  long long n1 = 0, n3 = 0, tx = 1, txy = 1;
  for (int i = 1; i < n; ++i) {
    if (x[o[i]] == x[o[i - 1]]) { ++tx; if (y[o[i]] == y[o[i - 1]]) ++txy; else { n3 += txy * (txy - 1) / 2; txy = 1; } }
    else { n1 += tx * (tx - 1) / 2; n3 += txy * (txy - 1) / 2; tx = 1; txy = 1; }
  }
  n1 += tx * (tx - 1) / 2; n3 += txy * (txy - 1) / 2;
  const long long swaps = merge_count(ys, buf, 0, n);
  long long n2 = 0, ty = 1;
  for (int i = 1; i < n; ++i) { if (ys[i] == ys[i - 1]) ++ty; else { n2 += ty * (ty - 1) / 2; ty = 1; } }
  n2 += ty * (ty - 1) / 2;
  const long long n0 = (long long) n * (n - 1) / 2;
  // Zaehler und die Faktoren des Nenners exakt ganzzahlig; Wurzel und Division in doppelter
  // double-Genauigkeit (Dekker 1971: Summe und Produkt ohne Rundungsfehler, ein Newton-Schritt fuer die
  // Wurzel, eine Korrektur fuer den Quotienten; relativer Fehler vor dem Runden < 1e-30), erst das
  // Ergebnis wird auf double gerundet. Ersetzt long double (x86-64 80 Bit, aarch64 128 Bit): gleiche
  // Ergebnisse auf allen Plattformen, korrekt gerundet ausser im Abstand < 1e-30 zu einer Rundungsgrenze.
  const long long num = (n0 - n1) - n2 + n3 - 2 * swaps, A = n0 - n1, B = n0 - n2;
  if (A <= 0 || B <= 0) return SIMLEV_NA;
  return kt_ratio(num, A, B);
}

// ---------------------------------------------------------------------------
// Rollierende Kovarianz (Populationsform, Fenster n inklusive aktueller Zeile)
// ---------------------------------------------------------------------------

// Zwei Durchgaenge je Fenster (erst Mittelwerte, dann zentrierte Produkte):
// vermeidet die Ausloeschung von E[xy] - E[x]E[y]. Aufwand O(n * Fenster).
// Fenster mit nicht endlichen Werten ergeben NA.
static auto roll_cov_core(simlev_host::NumVec x, simlev_host::NumVec y, int n) {
  const int m = x.size();
  auto out = SIMLEV_NUM(m, SIMLEV_NA);
  if (n < 1 || n > m || y.size() != m) return SIMLEV_DONE(out);
  for (int i = n - 1; i < m; ++i) {
    double sx = 0.0, sy = 0.0; bool ok = true;
    for (int k = i - n + 1; k <= i; ++k) { if (!std::isfinite(x[k]) || !std::isfinite(y[k])) { ok = false; break; } sx += x[k]; sy += y[k]; }
    if (!ok) continue;
    const double mx = sx / n, my = sy / n;
    double c = 0.0, cx = 0.0, cy = 0.0;
    for (int k = i - n + 1; k <= i; ++k) { const double dx = x[k] - mx, dy = y[k] - my; c += dx * dy; cx += dx; cy += dy; }
    out[i] = (c - cx * cy / n) / n;                 // Korrektur fuer Rundung im Mittelwert
  }
  return SIMLEV_DONE(out);
}

// ---------------------------------------------------------------------------
// Seit 1.6.5 (Paket B2): Hilfskerne fuer sharpe_deflated, sharpe_haircut, tactical_target_volatility und
// tactical_conditional_volatility; ein gemeinsamer Einstieg research_vec(op, x, par, out) fuer alle drei Sprachen
// ---------------------------------------------------------------------------

// Erwartetes Maximum von N unabhaengigen Standardnormalverteilten fuer reelles N >= 1 (CR2-K-2, Entscheidung 189):
// E = int_0^inf (1 - Phi(z)^N) dz - int_-inf^0 Phi(z)^N dz (= int z dPhi(z)^N); zusammengesetzte Gauss-Legendre-
// Quadratur mit 20 Knoten je Teilstueck der Breite 1/4 auf [-38.5, 40] (Teilstueckgrenze bei 0, wo der Integrand
// springt; ausserhalb Phi^N < 1e-300 bzw. N (1 - Phi) < 1e-300 fuer N bis DBL_MAX). Phi^N = exp(N log Phi), fuer
// z > 0 ueber log1p(-Q) (Q oberes Ende). N = 1 genau 0, Ergebnis >= 0; N < 1 oder NaN: NA, N = Inf: Inf.
static double exp_max_normal(double N) {
  static const double gl[10][2] = {
    {0x1.3973df98b86b0p-4, 0x1.38d6c490a3380p-3}, {0x1.d281636928bc0p-3, 0x1.31819b52c59a4p-3},
    {0x1.7eaccf15652c4p-2, 0x1.230348f34a542p-3}, {0x1.05905c13f7ff7p-1, 0x1.0db2c5db26e08p-3},
    {0x1.45a8d3fa710dbp-1, 0x1.e41ff31573b56p-4}, {0x1.7e1f37346a54ep-1, 0x1.a1817a317a834p-4},
    {0x1.ada0bd5efd6e7p-1, 0x1.5519fe196e247p-4}, {0x1.d31064173fd92p-1, 0x1.00b467df7e461p-4},
    {0x1.ed8dba7bd769fp-1, 0x1.4c9b5ea53b638p-5}, {0x1.fc7b5a0c71ce1p-1, 0x1.209680274e74ep-6}};
  if (!(N >= 1)) return SIMLEV_NA;
  if (N == 1) return 0.0;
  if (std::isinf(N)) return INFINITY;
  const double h = 0.25, a = -38.5;
  const int np = 314;                                   // (40 - (-38.5)) / 0.25
  double s = 0.0;
  for (int k = 0; k < np; ++k) {
    const double c = a + (k + 0.5) * h, r = 0.5 * h;
    double sp = 0.0;
    for (int j = 0; j < 10; ++j)
      for (int sg = -1; sg <= 1; sg += 2) {
        const double z = c + sg * r * gl[j][0];
        double f;
        if (z > 0) f = -std::expm1(N * std::log1p(-sl_pnorm1(z, 0)));
        else f = -std::exp(N * std::log(sl_pnorm1(z, 1)));
        sp += gl[j][1] * f;
      }
    s += r * sp;
  }
  return s > 0 ? s : 0.0;
}

// sum(1 / (1:n)) wie R (Kehrwerte in double, Summe im long-double-Akkumulator wie sum()), ohne den Vektor (CR2-I-1:
// Faktor des Verfahrens von Benjamini-Hochberg-Yekutieli in sharpe_haircut bis n = 10^8)
static double harmonic_r(double n) {
  long double s = 0.0L;
  const long long m = (long long) n;
  for (long long i = 1; i <= m; ++i) s += 1.0 / (double) i;
  return (double) s;
}

// Expandierender Median (lit1 S4, Entscheidung 192): out[t] = Median der endlichen Werte x[0..t] wie
// stats::median (gerade Anzahl: mean() der beiden mittleren Werte), NA bei weniger als k endlichen Werten
static void expanding_median(int64_t n, const double* x, double k, double* out) {
  std::vector<double> lo, hi;                           // lo: Max-Heap (untere Haelfte), hi: Min-Heap
  auto gt = [](double a, double b) { return a > b; };
  for (int64_t t = 0; t < n; ++t) {
    const double v = x[t];
    if (std::isfinite(v)) {
      if (lo.empty() || v <= lo.front()) { lo.push_back(v); std::push_heap(lo.begin(), lo.end()); }
      else { hi.push_back(v); std::push_heap(hi.begin(), hi.end(), gt); }
      if (lo.size() > hi.size() + 1) {
        std::pop_heap(lo.begin(), lo.end()); hi.push_back(lo.back()); lo.pop_back(); std::push_heap(hi.begin(), hi.end(), gt);
      } else if (hi.size() > lo.size()) {
        std::pop_heap(hi.begin(), hi.end(), gt); lo.push_back(hi.back()); hi.pop_back(); std::push_heap(lo.begin(), lo.end());
      }
    }
    const double cnt = (double) (lo.size() + hi.size());
    if (cnt < k || cnt == 0) { out[t] = SIMLEV_NA; continue; }
    if (lo.size() > hi.size()) out[t] = lo.front();
    else { const double two[2] = {lo.front(), hi.front()}; out[t] = sl_r_mean(2, two); }
  }
}

// Wurzel der Ordnung q (1, 2 genau; sonst pow)
static inline double root_q(double v, double q) {
  if (!(v > 0)) return std::isnan(v) ? v : 0.0;
  if (q == 1) return v;
  if (q == 2) return std::sqrt(v);
  return std::pow(v, 1.0 / q);
}

// Beitrag einer Rendite zum Moment: 0 sd (x^2), 1/2 LPM der Ordnung q (max(-x, 0)^q)
static inline double moment_g(double x, int measure, double q) {
  if (measure == 0) return x * x;
  const double d = x < 0 ? -x : 0.0;
  if (q == 1) return d;
  if (q == 2) return d * d;
  return std::pow(d, q);
}

// Risikozustand je Zeile fuer tactical_target_volatility / tactical_conditional_volatility (seit 1.6.5: CR2-V1-1,
// CR2-R-2, lit1 S2/S3, Entscheidungen 175, 189, 192). R, W: n x A spaltenweise (Tagesrenditen der Risikoanlagen und
// je Zeile normierte Gewichte, Summe 1 oder 0), day: n Tageszahlen. In Zeile t gilt die Portfoliorendite mit den
// Gewichten von t: r_s = sum_a W[t, a] R[s, a] (s <= t, Summe in fester Folge); Bewegungstage: r_s != 0.
// measure 0 sd (Stichprobe, Teiler w - 1, zwei Durchgaenge), 2 LPM der Ordnung q ((mean(max(-r, 0)^q))^(1/q);
// Abwaertsschwankung = q 2), 3 VaR (-x_(k), k = max(1, floor(alpha w))), 4 ES (EWMA-gefiltert:
// z = r_s / sqrt(v_{s-1}), ES = -mean der k kleinsten der letzten w Residuen * sqrt(v_t)).
// est 0: Fenster der letzten w Bewegungstage; est 1: EWMA v = lam v + (1 - lam) g(r), Start = Mittel von g ueber die
// ersten 21 Bewegungstage (Mittelwert 0, RiskMetrics); VaR dann ebenfalls gefiltert. ppy > 0: fest, sonst gleitend
// (Bewegungstage der letzten 365.25 Kalendertage; im ersten Jahr der Daten deren Dichte seit dem ersten Tag).
// Ergebnis: Mass * sqrt(ppy_t); NA, solange zu wenige Bewegungstage vorliegen oder alle Gewichte 0 sind.
static void risk_state(int64_t n, int64_t A, const double* R, const double* W, const double* day, int w, int measure,
                       double q, double alpha, int est, double lam, double ppy_fix, double* out) {
  const double na = SIMLEV_NA;
  const int seed = 21;
  const bool filt = measure == 4 || (measure == 3 && est == 1);
  std::vector<double> wt((size_t) A), mr, md, z, v, buf;   // Bewegungstage: Rendite, Tag; Residuen; EWMA-Werte
  bool zero = true;
  int64_t seg = -1;                                         // Zeile, deren Gewichte gelten (-1 = keine)
  auto push = [&](int64_t s) {                              // Rendite der Zeile s mit den Gewichten wt
    double r = 0.0;
    for (int64_t a = 0; a < A; ++a) r += wt[(size_t) a] * R[s + n * a];
    if (r == 0.0 || !std::isfinite(r)) return;
    mr.push_back(r); md.push_back(day[s]);
    const size_t m = mr.size();
    if (est == 1 || filt) {
      const double g = filt ? r * r : moment_g(r, measure, q);
      if ((int) m < seed) { v.push_back(na); return; }
      if ((int) m == seed) {
        double sg = 0.0;
        for (size_t i = 0; i < m; ++i) sg += filt ? mr[i] * mr[i] : moment_g(mr[i], measure, q);
        v.push_back(sg / seed);
        return;
      }
      const double vp = v[m - 2];
      if (filt) z.push_back(r / std::sqrt(vp));
      v.push_back(lam * vp + (1 - lam) * g);
    }
  };
  for (int64_t t = 0; t < n; ++t) {
    bool same = seg >= 0;
    for (int64_t a = 0; a < A && same; ++a) same = W[t + n * a] == W[seg + n * a];
    if (!same) {                                            // neue Gewichte: Bewegungstage bis t neu bilden
      seg = t; zero = true;
      for (int64_t a = 0; a < A; ++a) { wt[(size_t) a] = W[t + n * a]; if (wt[(size_t) a] != 0) zero = false; }
      mr.clear(); md.clear(); z.clear(); v.clear();
      if (!zero) for (int64_t s = 0; s < t; ++s) push(s);
    }
    if (zero) { out[t] = na; continue; }
    push(t);
    const int64_t m = (int64_t) mr.size();
    double ppy = ppy_fix;
    if (!(ppy > 0)) {
      if (!m) { out[t] = na; continue; }
      const double span = day[t] - day[0];
      if (span >= 365.25) {
        const double lim = day[t] - 365.25;
        ppy = (double) (md.end() - std::upper_bound(md.begin(), md.end(), lim));
      } else ppy = span > 0 ? (double) m / (span / 365.25) : na;
      if (!(ppy > 0)) { out[t] = na; continue; }
    }
    double rho = na;
    if (filt) {
      const int64_t nz = (int64_t) z.size();
      if (nz >= w) {
        buf.assign(z.end() - w, z.end());
        const int k = std::max(1, (int) std::floor(alpha * w));
        std::nth_element(buf.begin(), buf.begin() + (k - 1), buf.end());
        double val;
        if (measure == 3) val = -buf[(size_t) (k - 1)];
        else {
          std::sort(buf.begin(), buf.begin() + k);
          double sz = 0.0;
          for (int i = 0; i < k; ++i) sz += buf[(size_t) i];
          val = -(sz / k);
        }
        rho = val * std::sqrt(v[(size_t) (m - 1)]);
      }
    } else if (est == 1) {
      if (m >= seed) rho = root_q(v[(size_t) (m - 1)], measure == 0 ? 2.0 : q);
    } else if (m >= w) {
      const double* x = mr.data() + (m - w);
      if (measure == 0) {
        double sx = 0.0;
        for (int i = 0; i < w; ++i) sx += x[i];
        const double mx = sx / w;
        double c = 0.0, cx = 0.0;
        for (int i = 0; i < w; ++i) { const double dx = x[i] - mx; c += dx * dx; cx += dx; }
        const double var = (c - cx * cx / w) / (w - 1);
        rho = var > 0 ? std::sqrt(var) : 0.0;
      } else if (measure == 2) {
        double sg = 0.0;
        for (int i = 0; i < w; ++i) sg += moment_g(x[i], 2, q);
        rho = root_q(sg / w, q);
      } else {
        buf.assign(x, x + w);
        const int k = std::max(1, (int) std::floor(alpha * w));
        std::nth_element(buf.begin(), buf.begin() + (k - 1), buf.end());
        rho = -buf[(size_t) (k - 1)];
      }
    }
    out[t] = std::isnan(rho) ? na : rho * std::sqrt(ppy);
  }
}

// Drawdown-Polster (lit1 S7, Entscheidung 192 L6): Index P aus den Portfoliorenditen pr (P_0 = 1, P_s = P_{s-1} (1 +
// pr_s)), Hoch ueber die letzten w Bewegungstage (pr != 0; Zeile 0 zaehlt als Start), DDP = 1 - P / Hoch,
// m = min(1, max(0, (D - DDP) / (D (1 - DDP)))) mit D = Tiefe als Anteil
static void cushion_mult(int64_t n, const double* pr, int w, double D, double* out) {
  std::vector<double> pts; pts.reserve((size_t) n);
  double P = 1.0;
  pts.push_back(P);
  for (int64_t t = 0; t < n; ++t) {
    if (t > 0 && pr[t] != 0 && std::isfinite(pr[t])) { P = P * (1 + pr[t]); pts.push_back(P); }
    const size_t m = pts.size(), from = m > (size_t) w ? m - (size_t) w : 0;
    double hi = pts[from];
    for (size_t i = from + 1; i < m; ++i) if (pts[i] > hi) hi = pts[i];
    const double dd = hi > 0 ? 1 - P / hi : 1.0;
    double mt;
    if (!(dd < D)) mt = 0.0;
    else { mt = (D - dd) / (D * (1 - dd)); if (mt > 1) mt = 1.0; if (mt < 0) mt = 0.0; }
    out[t] = mt;
  }
}

// Logarithmus des unteren Endes P(T <= -t) der t-Verteilung (nu Freiheitsgrade; nu > 1e20 oder Inf: Normalverteilung)
// fuer grosse t > 0, wo pt/pnorm unterlaufen (CR2-I-2, Entscheidung 189 Weg a): log P = lnc + L0(t) + log I(t) mit der
// Dichte exp(lnc + L0(s)), L0(s) = -(nu + 1) / 2 log1p(s^2 / nu) (normal -s^2 / 2), und
// I(t) = int_0^inf exp(L0(t + u) - L0(t)) du, zusammengesetzte Gauss-Legendre-Quadratur (20 Knoten) mit Teilstuecken der
// Breite 1 / (2 lambda), lambda = -L0'(t), bis L0(t + u) - L0(t) < -60. Gibt log P und I(t) zurueck.
static double tail_L0(double s, double nu, bool normal) {
  return normal ? -0.5 * s * s : -0.5 * (nu + 1) * std::log1p((s / nu) * s);
}
static double tail_logp(double t, double nu, double* I_out) {
  static const double gl[10][2] = {
    {0x1.3973df98b86b0p-4, 0x1.38d6c490a3380p-3}, {0x1.d281636928bc0p-3, 0x1.31819b52c59a4p-3},
    {0x1.7eaccf15652c4p-2, 0x1.230348f34a542p-3}, {0x1.05905c13f7ff7p-1, 0x1.0db2c5db26e08p-3},
    {0x1.45a8d3fa710dbp-1, 0x1.e41ff31573b56p-4}, {0x1.7e1f37346a54ep-1, 0x1.a1817a317a834p-4},
    {0x1.ada0bd5efd6e7p-1, 0x1.5519fe196e247p-4}, {0x1.d31064173fd92p-1, 0x1.00b467df7e461p-4},
    {0x1.ed8dba7bd769fp-1, 0x1.4c9b5ea53b638p-5}, {0x1.fc7b5a0c71ce1p-1, 0x1.209680274e74ep-6}};
  const bool normal = !(nu <= 1e20);
  const double lnc = normal ? -0.5 * std::log(2 * M_PI)
                            : std::lgamma(0.5 * (nu + 1)) - std::lgamma(0.5 * nu) - 0.5 * std::log(nu * M_PI);
  const double L0t = tail_L0(t, nu, normal);
  const double lam = normal ? t : (nu + 1) * t / (nu + t * t);
  const double h = 0.5 / lam, r = 0.5 * h;
  double I = 0.0;
  for (int k = 0; k < 200000; ++k) {
    const double c = t + (k + 0.5) * h;
    double sp = 0.0;
    for (int j = 0; j < 10; ++j)
      for (int sg = -1; sg <= 1; sg += 2) sp += gl[j][1] * std::exp(tail_L0(c + sg * r * gl[j][0], nu, normal) - L0t);
    I += r * sp;
    if (tail_L0(t + (k + 1) * h, nu, normal) - L0t < -60) break;
  }
  if (I_out) *I_out = I;
  return lnc + L0t + std::log(I);
}
// Umkehrung: t > 0 mit log P(T <= -t) = g (Newton t <- t + (logP(t) - g) I(t), Einschluss mit Halbierung)
static double tail_logp_inv(double g, double nu) {
  if (std::isnan(g)) return SIMLEV_NA;
  if (g >= std::log(0.5)) return 0.0;
  double t = std::sqrt(-2 * (g + 0.5 * std::log(2 * M_PI))), lo = 0.0, hi = INFINITY;
  if (!(t > 1)) t = 1.0;
  for (int it = 0; it < 200; ++it) {
    double I = 0.0;
    const double f = tail_logp(t, nu, &I) - g;           // fallend in t
    if (f > 0) lo = t; else hi = t;
    double tn = t + f * I;
    if (!(tn > lo && tn < hi)) tn = std::isinf(hi) ? 2 * t : 0.5 * (lo + hi);
    if (std::fabs(tn - t) <= 1e-15 * t) { t = tn; break; }
    t = tn;
  }
  return t;
}

// ---------------------------------------------------------------------------
// Seit 1.6.5 (Paket B2b, Entscheidung 177): sharpe_test nach Ledoit & Wolf (2008)
// ---------------------------------------------------------------------------

// Inverse einer kleinen k x k-Matrix (zeilenweise) nach Gauss-Jordan mit Spaltenpivot; false bei Pivot 0 bzw. nicht
// endlichem Ergebnis
static bool lw_inverse(int k, const double* A, double* Ai) {
  std::vector<double> M((size_t) k * 2 * k, 0.0);
  for (int i = 0; i < k; ++i) {
    for (int j = 0; j < k; ++j) M[(size_t) i * 2 * k + j] = A[(size_t) i * k + j];
    M[(size_t) i * 2 * k + k + i] = 1.0;
  }
  for (int c = 0; c < k; ++c) {
    int p = c;
    for (int r = c + 1; r < k; ++r)
      if (std::fabs(M[(size_t) r * 2 * k + c]) > std::fabs(M[(size_t) p * 2 * k + c])) p = r;
    const double piv = M[(size_t) p * 2 * k + c];
    if (!(piv != 0.0) || !std::isfinite(piv)) return false;
    if (p != c) for (int j = 0; j < 2 * k; ++j) std::swap(M[(size_t) p * 2 * k + j], M[(size_t) c * 2 * k + j]);
    for (int j = 0; j < 2 * k; ++j) M[(size_t) c * 2 * k + j] /= piv;
    for (int r = 0; r < k; ++r) {
      if (r == c) continue;
      const double f = M[(size_t) r * 2 * k + c];
      if (f == 0.0) continue;
      for (int j = 0; j < 2 * k; ++j) M[(size_t) r * 2 * k + j] -= f * M[(size_t) c * 2 * k + j];
    }
  }
  for (int i = 0; i < k; ++i)
    for (int j = 0; j < k; ++j) {
      Ai[(size_t) i * k + j] = M[(size_t) i * 2 * k + k + j];
      if (!std::isfinite(Ai[(size_t) i * k + j])) return false;
    }
  return true;
}

// Quadratic-Spectral-Kern (Andrews 1991, Gl. 2.7): k(x) = 25 / (12 pi^2 x^2) (sin(6 pi x / 5) / (6 pi x / 5) -
// cos(6 pi x / 5)), k(0) = 1
static double lw_qs(double x) {
  if (x == 0.0) return 1.0;
  const double z = 6.0 * M_PI * x / 5.0;
  return 25.0 / (12.0 * M_PI * M_PI * x * x) * (std::sin(z) / z - std::cos(z));
}

// Kern-Schaetzer der Langfristkovarianz nach Ledoit & Wolf (2008, Abschnitt 3.1): Psi = T / (T - k) sum_j
// w(j) C(j) mit C(j) = 1/m sum_t v_t v_{t-j}' der zentrierten Spalten von Y (T x k, spaltenweise). kern 1: Bartlett mit
// Lag L = floor(4 (T/100)^(2/9)) (Newey-West wie bisher), w(j) = 1 - j / (L + 1); kern 2: Quadratic Spectral mit
// automatischer Bandbreite S = 1.3221 (alpha(2) m)^(1/5) nach Andrews (1991, Gl. 6.2 und 6.4) aus univariaten
// AR(1)-Naeherungen je Spalte (Gewichte 1): rho = sum v_t v_{t-1} / sum v_{t-1}^2, s2 = sum (v_t - rho v_{t-1})^2 /
// (m - 1), alpha(2) = sum 4 rho^2 s2^2 / (1 - rho)^8 / sum s2^2 / (1 - rho)^4. prew: Prewhitening nach Andrews &
// Monahan (1992): VAR(1) ohne Konstante per KQ, v = Residuen (m = T - 1), Kern-Schaetzer auf v und Rueckfaerbung
// (I - A)^-1 Psi_v (I - A)^-1'. out: k x k (spaltenweise), Status (0 gut, 1 VAR(1) singulaer, 2 Bandbreite nicht
// bestimmbar), Bandbreite bzw. Lag.
static void lw_hac(int64_t T, int k, const double* Y, int kern, bool prew, double* out) {
  const int64_t kk = (int64_t) k * k;
  for (int64_t i = 0; i < kk + 2; ++i) out[i] = SIMLEV_NA;
  std::vector<double> U((size_t) (T * k));                    // zeilenweise T x k, zentriert
  for (int a = 0; a < k; ++a) {
    double s = 0.0;
    for (int64_t t = 0; t < T; ++t) s += Y[a * T + t];
    const double mu = s / (double) T;
    for (int64_t t = 0; t < T; ++t) U[(size_t) (t * k + a)] = Y[a * T + t] - mu;
  }
  std::vector<double> Bi((size_t) kk, 0.0);                   // (I - A)^-1 bei Prewhitening
  const double* V = U.data(); int64_t m = T;
  std::vector<double> E;
  if (prew) {
    std::vector<double> S10((size_t) kk, 0.0), S00((size_t) kk, 0.0), S00i((size_t) kk), A((size_t) kk, 0.0);
    for (int64_t t = 1; t < T; ++t)
      for (int i = 0; i < k; ++i)
        for (int j = 0; j < k; ++j) {
          S10[(size_t) (i * k + j)] += U[(size_t) (t * k + i)] * U[(size_t) ((t - 1) * k + j)];
          S00[(size_t) (i * k + j)] += U[(size_t) ((t - 1) * k + i)] * U[(size_t) ((t - 1) * k + j)];
        }
    if (!lw_inverse(k, S00.data(), S00i.data())) { out[kk] = 1.0; return; }
    for (int i = 0; i < k; ++i)
      for (int j = 0; j < k; ++j) {
        double s = 0.0;
        for (int l = 0; l < k; ++l) s += S10[(size_t) (i * k + l)] * S00i[(size_t) (l * k + j)];
        A[(size_t) (i * k + j)] = s;
      }
    std::vector<double> IA((size_t) kk);
    for (int i = 0; i < k; ++i) for (int j = 0; j < k; ++j) IA[(size_t) (i * k + j)] = (i == j ? 1.0 : 0.0) - A[(size_t) (i * k + j)];
    if (!lw_inverse(k, IA.data(), Bi.data())) { out[kk] = 1.0; return; }
    m = T - 1;
    E.assign((size_t) (m * k), 0.0);
    for (int64_t t = 1; t < T; ++t)
      for (int i = 0; i < k; ++i) {
        double s = U[(size_t) (t * k + i)];
        for (int j = 0; j < k; ++j) s -= A[(size_t) (i * k + j)] * U[(size_t) ((t - 1) * k + j)];
        E[(size_t) ((t - 1) * k + i)] = s;
      }
    V = E.data();
  }
  double bw;
  if (kern == 1) bw = std::floor(4.0 * std::pow((double) T / 100.0, 2.0 / 9.0));
  else {
    double num = 0.0, den = 0.0;
    for (int a = 0; a < k; ++a) {
      double sxy = 0.0, sxx = 0.0;
      for (int64_t t = 1; t < m; ++t) { sxy += V[t * k + a] * V[(t - 1) * k + a]; sxx += V[(t - 1) * k + a] * V[(t - 1) * k + a]; }
      const double rho = sxy / sxx;
      double se = 0.0;
      for (int64_t t = 1; t < m; ++t) { const double e = V[t * k + a] - rho * V[(t - 1) * k + a]; se += e * e; }
      const double s2 = se / (double) (m - 1), s4 = s2 * s2, om = 1.0 - rho;
      num += 4.0 * rho * rho * s4 / std::pow(om, 8.0);
      den += s4 / std::pow(om, 4.0);
    }
    bw = 1.3221 * std::pow(num / den * (double) m, 0.2);
    if (!std::isfinite(bw) || !(bw >= 0.0)) { out[kk] = 2.0; return; }
  }
  std::vector<double> P((size_t) kk, 0.0);
  for (int64_t j = 0; j < m; ++j) {
    double w;
    if (kern == 1) { if ((double) j > bw) break; w = 1.0 - (double) j / (bw + 1.0); }
    else w = bw > 0.0 ? lw_qs((double) j / bw) : (j == 0 ? 1.0 : 0.0);
    if (w == 0.0 && j > 0) continue;
    std::vector<double> C((size_t) kk, 0.0);
    for (int64_t t = j; t < m; ++t)
      for (int a = 0; a < k; ++a) {
        const double va = V[t * k + a];
        for (int b = 0; b < k; ++b) C[(size_t) (a * k + b)] += va * V[(t - j) * k + b];
      }
    for (int a = 0; a < k; ++a)
      for (int b = 0; b < k; ++b) {
        const double c = C[(size_t) (a * k + b)] / (double) m;
        if (j == 0) P[(size_t) (a * k + b)] += c;
        else { P[(size_t) (a * k + b)] += w * c; P[(size_t) (b * k + a)] += w * c; }
      }
  }
  if (prew) {                                                  // Rueckfaerbung Bi P Bi'
    std::vector<double> Q((size_t) kk, 0.0), R((size_t) kk, 0.0);
    for (int i = 0; i < k; ++i) for (int j = 0; j < k; ++j) {
      double s = 0.0; for (int l = 0; l < k; ++l) s += Bi[(size_t) (i * k + l)] * P[(size_t) (l * k + j)]; Q[(size_t) (i * k + j)] = s; }
    for (int i = 0; i < k; ++i) for (int j = 0; j < k; ++j) {
      double s = 0.0; for (int l = 0; l < k; ++l) s += Q[(size_t) (i * k + l)] * Bi[(size_t) (j * k + l)]; R[(size_t) (i * k + j)] = s; }
    P.swap(R);
  }
  const double f = (double) T / (double) (T - k);              // Ledoit & Wolf (2008, Abschnitt 3.1): T / (T - 4)
  for (int a = 0; a < k; ++a) for (int b = 0; b < k; ++b) out[b * k + a] = f * P[(size_t) (a * k + b)];
  out[kk] = 0.0; out[kk + 1] = bw;
}

// Eine Stichprobe des studentisierten zirkulaeren Block-Bootstraps (Ledoit & Wolf 2008, Abschnitt 3.2.2): x = (r_a,
// r_b) der Laenge 2 T, Blocklaenge b. Delta = mu_a / sd_a - mu_b / sd_b (sd mit Teiler T - 1 wie sharpe_test),
// Gradient der Delta-Methode (Gl. 4, Schwankung ueber die Abweichungen vom Mittel wie Entscheidung 142),
// y_t = (r_a - mu_a, r_b - mu_b, r_a^2 - g_a, r_b^2 - g_b), Psi* = 1/l sum_j zeta_j zeta_j' mit zeta_j = b^(-1/2)
// sum_{t=1..b} y_{(j-1)b+t} und l = floor(T / b) (nur die ersten l b Beobachtungen), s = sqrt(grad' Psi* grad / T)
// (Gl. 8). out = (Delta, s); NA, wenn eine Reihe ohne Schwankung ist.
static void lw_boot_stat(int64_t T, const double* x, int64_t b, double* out) {
  const double* r[2] = {x, x + T};
  double mu[2], g[2], v[2], sd[2];
  for (int i = 0; i < 2; ++i) {
    double s = 0.0, q = 0.0;
    for (int64_t t = 0; t < T; ++t) { s += r[i][t]; q += r[i][t] * r[i][t]; }
    mu[i] = s / (double) T; g[i] = q / (double) T;
    double d2 = 0.0;
    for (int64_t t = 0; t < T; ++t) { const double e = r[i][t] - mu[i]; d2 += e * e; }
    v[i] = d2 / (double) T; sd[i] = std::sqrt(d2 / (double) (T - 1));
  }
  out[0] = out[1] = SIMLEV_NA;
  if (!(sd[0] > 0.0) || !(sd[1] > 0.0)) return;
  const double v0 = std::pow(v[0], 1.5), v1 = std::pow(v[1], 1.5);
  const double grad[4] = {g[0] / v0, -g[1] / v1, -0.5 * mu[0] / v0, 0.5 * mu[1] / v1};
  const int64_t l = T / b;
  const double sb = std::sqrt((double) b);
  double P[16] = {0.0};
  for (int64_t j = 0; j < l; ++j) {
    double z[4] = {0.0, 0.0, 0.0, 0.0};
    for (int64_t t = j * b; t < (j + 1) * b; ++t) {
      z[0] += r[0][t] - mu[0]; z[1] += r[1][t] - mu[1];
      z[2] += r[0][t] * r[0][t] - g[0]; z[3] += r[1][t] * r[1][t] - g[1];
    }
    for (int a = 0; a < 4; ++a) z[a] /= sb;
    for (int a = 0; a < 4; ++a) for (int c = 0; c < 4; ++c) P[a * 4 + c] += z[a] * z[c];
  }
  double q = 0.0;
  for (int a = 0; a < 4; ++a) for (int c = 0; c < 4; ++c) q += grad[a] * (P[a * 4 + c] / (double) l) * grad[c];
  out[0] = mu[0] / sd[0] - mu[1] / sd[1];
  out[1] = std::sqrt(q / (double) T);
}

// Gemeinsamer Einstieg (seit 1.6.5) fuer R (.research_vec), Python (_ext.research_vec) und Julia
// (simlev_c_research_vec): op 1 exp_max_normal je x[i]; op 2 harmonic_r je x[i]; op 3 risk_state mit
// x = (R, W, day), par = (n, A, w, measure, q, alpha, est, lambda, ppy); op 4 expanding_median mit par = (k);
// op 5 cushion_mult mit par = (w, D); op 6 tail_logp je x[i] mit par = (nu); op 7 tail_logp_inv je x[i] mit
// par = (nu); op 8 lw_hac mit x = Y (T x k spaltenweise), par = (T, k, kern, prew), out k*k + 2; op 9 lw_boot_stat mit
// x = (r_a, r_b), par = (T, b), out 2. Gibt false zurueck, wenn die Abmessungen nicht passen.
static bool research_vec(int op, int64_t nx, const double* x, int64_t np, const double* par, int64_t nout, double* out) {
  switch (op) {
    case 1: case 2:
      if (nout != nx) return false;
      for (int64_t i = 0; i < nx; ++i) out[i] = op == 1 ? exp_max_normal(x[i]) : harmonic_r(x[i]);
      return true;
    case 3: {
      if (np != 9) return false;
      const int64_t n = (int64_t) par[0], A = (int64_t) par[1];
      if (n < 0 || A < 1 || nx != n * (2 * A + 1) || nout != n || !(par[2] >= 1)) return false;
      risk_state(n, A, x, x + n * A, x + 2 * n * A, (int) par[2], (int) par[3], par[4], par[5], (int) par[6], par[7],
                 par[8], out);
      return true;
    }
    case 4:
      if (np != 1 || nout != nx) return false;
      expanding_median(nx, x, par[0], out);
      return true;
    case 5:
      if (np != 2 || nout != nx || !(par[0] >= 1)) return false;
      cushion_mult(nx, x, (int) par[0], par[1], out);
      return true;
    case 6: case 7:
      if (np != 1 || nout != nx || !(par[0] > 0)) return false;
      for (int64_t i = 0; i < nx; ++i)
        out[i] = op == 6 ? (x[i] > 0 ? tail_logp(x[i], par[0], nullptr) : SIMLEV_NA) : tail_logp_inv(x[i], par[0]);
      return true;
    case 8: {
      if (np != 4) return false;
      const int64_t T = (int64_t) par[0], k = (int64_t) par[1];
      if (T < 3 || k < 1 || k > 16 || T <= k || nx != T * k || nout != k * k + 2 || !(par[2] == 1 || par[2] == 2)) return false;
      lw_hac(T, (int) k, x, (int) par[2], par[3] != 0.0, out);
      return true;
    }
    case 9: {
      if (np != 2) return false;
      const int64_t T = (int64_t) par[0], b = (int64_t) par[1];
      if (T < 2 || b < 1 || b > T || nx != 2 * T || nout != 2) return false;
      lw_boot_stat(T, x, b, out);
      return true;
    }
    default:
      return false;
  }
}

}  // namespace simlev

#endif
