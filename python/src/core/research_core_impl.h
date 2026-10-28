// core/research_core_impl.h
// Rechenkerne fuer Optimierung, Regression, Regime und Zeitreihen-Hilfen, reine
// Rechnung ohne R und Python.
//
// GEMEINSAME QUELLE FUER R UND PYTHON (Etappe 7.3a): R ruft die Kerne ueber die
// .Call-Huellen in r/src/research_core.cpp auf (sie wandeln nur die R-Objekte um),
// Python ueber das Erweiterungsmodul simlev._ext (python/src/_ext_research.cpp).
// Kanonisch in core/ (seit Etappe 9.6c, F16); R und Python bauen aus
// Byte-fuer-Byte-Kopien in r/src/ bzw. python/src/core/ (tools/core_sync.py
// --write/--check); Aenderungen nur in core/ vornehmen und danach kopieren.
// Die Python-Huellen (simlev/_optimize_core.py, _dependence_core.py, _signals_core.py)
// rufen nur noch diese Kerne; die reinen Python-Kerne als Rueckfall sind seit 9.6c entfallen.
//
// Aufbau wie alle C++-Kerne (simlev_core.h): statische Funktionen ueber den Sichten
// simlev_host::NumVec/IntVec/NumMat und den Host-Makros SIMLEV_* (Fehler, NA,
// Anlegen der Ergebnisse), die die einbindende Huelle festlegt (R: simlev_capi.h,
// Python: _ext_common.h). Die Rechnung ist Zeile fuer Zeile die fruehere aus
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
//   hmm_forward_backward  skalierter Vorwaerts-Rueckwaerts-Schritt (Baum-Welch)
//   (garch_filter: in N2 entfernt; seit 9.6b ohne Aufrufer, ersetzt durch sl_garch11_filter)
//   roll_mean_core     rollierender Mittelwert mit kompensierter Summe
//   kendall_tau_core   Kendalls Tau-b (long double, auf x86-64 80 Bit)
//   roll_cov_core      rollierende Kovarianz
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

#include <vector>
#include <cmath>
#include <algorithm>
#include <numeric>

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

// Quantil Typ 7 (wie stats::quantile Standard) einer Kopie von x.
static double quantile7(std::vector<double> x, double p) {
  const int n = (int) x.size();
  if (n == 0) return SIMLEV_NA;
  const double h = (n - 1) * p;
  const int lo = (int) std::floor(h);
  const double frac = h - lo;
  std::nth_element(x.begin(), x.begin() + lo, x.end());
  const double xl = x[lo];
  if (frac == 0.0 || lo + 1 >= n) return xl;
  const double xh = *std::min_element(x.begin() + lo + 1, x.end());
  return xl + frac * (xh - xl);
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
static inline double logistic(double z) { return z >= 0.0 ? 1.0 / (1.0 + std::exp(-z)) : std::exp(z) / (1.0 + std::exp(z)); }

static auto min_cvar_core(simlev_host::NumMat R, double alpha, simlev_host::NumVec lo, simlev_host::NumVec hi, simlev_host::NumVec w0, double zeta0, simlev_host::NumVec scales, int maxit) {
  const int T = R.nrow(), N = R.ncol();
  const double aT = alpha * T;
  std::vector<double> x(N + 1), yv(N + 1), xn(N + 1), g(N + 1), tmp(N + 1), loss(T);
  for (int i = 0; i < N; ++i) x[i] = w0[i];
  x[N] = zeta0;
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
    auto grad = [&](const std::vector<double>& z, std::vector<double>& gr) {
      port_loss(z); std::fill(gr.begin(), gr.end(), 0.0); double sp = 0.0;
      for (int s = 0; s < T; ++s) { const double p = logistic((loss[s] - z[N]) / sc); loss[s] = p; sp += p; }
      for (int i = 0; i < N; ++i) { double acc = 0.0; for (int s = 0; s < T; ++s) acc += R(s, i) * loss[s]; gr[i] = -acc / aT; }
      gr[N] = 1.0 - sp / aT;
    };
    yv = x; double t = 1.0, L = 1.0 / (alpha * sc);
    for (int it = 0; it < maxit; ++it) {
      grad(yv, g); const double fy = f(yv); L /= 2.0;
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
      if (dmax < 1e-9) { x = xn; break; }
      if (dir > 0.0) { t = 1.0; yv = xn; x = xn; continue; }
      const double tn = (1.0 + std::sqrt(1.0 + 4.0 * t * t)) / 2.0, mom = (t - 1.0) / tn;
      for (int i = 0; i <= N; ++i) yv[i] = xn[i] + mom * (xn[i] - x[i]);
      x = xn; t = tn;
    }
  }
  return SIMLEV_COPY(x.begin(), x.begin() + N);
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

// B: Emissionsdichten (T x K, je Zeile skaliert), A: Uebergangsmatrix, p0: Start.
static auto hmm_forward_backward(simlev_host::NumMat B, simlev_host::NumMat A, simlev_host::NumVec p0) {
  const int T = B.nrow(), K = B.ncol();
  auto al = SIMLEV_MATRIX(T, K), be = SIMLEV_MATRIX(T, K), ga = SIMLEV_MATRIX(T, K), xi = SIMLEV_MATRIX(K, K);
  auto cs = SIMLEV_NUM(T);
  std::vector<double> a(K), tmp(K);
  double s = 0.0;
  for (int j = 0; j < K; ++j) { a[j] = p0[j] * B(0, j); s += a[j]; }
  cs[0] = s; for (int j = 0; j < K; ++j) al(0, j) = a[j] / s;
  for (int t = 1; t < T; ++t) {
    s = 0.0;
    for (int j = 0; j < K; ++j) { double v = 0.0; for (int i = 0; i < K; ++i) v += al(t - 1, i) * A(i, j); a[j] = v * B(t, j); s += a[j]; }
    cs[t] = s; for (int j = 0; j < K; ++j) al(t, j) = a[j] / s;
  }
  for (int j = 0; j < K; ++j) be(T - 1, j) = 1.0;
  for (int t = T - 2; t >= 0; --t) {
    for (int j = 0; j < K; ++j) tmp[j] = B(t + 1, j) * be(t + 1, j);
    for (int i = 0; i < K; ++i) { double v = 0.0; for (int j = 0; j < K; ++j) v += A(i, j) * tmp[j]; be(t, i) = v / cs[t + 1]; }
  }
  for (int t = 0; t < T; ++t) {
    double rs = 0.0; for (int j = 0; j < K; ++j) { ga(t, j) = al(t, j) * be(t, j); rs += ga(t, j); }
    for (int j = 0; j < K; ++j) ga(t, j) /= rs;
  }
  for (int t = 0; t < T - 1; ++t) {
    for (int j = 0; j < K; ++j) tmp[j] = B(t + 1, j) * be(t + 1, j);
    for (int i = 0; i < K; ++i) for (int j = 0; j < K; ++j) xi(i, j) += al(t, i) * tmp[j] * A(i, j) / cs[t + 1];
  }
  return SIMLEV_LIST("filtered", al, "smoothed", ga, "xi", xi, "scale", cs);
}

// ---------------------------------------------------------------------------
// Rollierender Mittelwert (Fenster n inklusive aktueller Zeile)
// ---------------------------------------------------------------------------

// Gleitende Summe mit Neumaier-Kompensation; alle 4096 Schritte wird die
// Fenstersumme neu aufgebaut, damit sich keine Rundungsfehler ansammeln.
// NA/NaN im Fenster ergeben NA (wie die kumulierte Summe in R).
static auto roll_mean_core(simlev_host::NumVec x, int n) {
  const int m = x.size();
  auto out = SIMLEV_NUM(m, SIMLEV_NA);
  if (n < 1 || n > m) return SIMLEV_DONE(out);
  int bad = 0;                                   // Anzahl nicht endlicher Werte im Fenster
  double sum = 0.0, comp = 0.0;
  auto add = [&](double v) { const double t = sum + v;
    if (std::fabs(sum) >= std::fabs(v)) comp += (sum - t) + v; else comp += (v - t) + sum; sum = t; };
  auto rebuild = [&](int end) { sum = 0.0; comp = 0.0; bad = 0;
    for (int k = end - n + 1; k <= end; ++k) { if (std::isfinite(x[k])) add(x[k]); else ++bad; } };
  rebuild(n - 1);
  out[n - 1] = bad ? SIMLEV_NA : (sum + comp) / n;
  for (int i = n; i < m; ++i) {
    if ((i - n) % 4096 == 4095) rebuild(i);
    else {
      if (std::isfinite(x[i])) add(x[i]); else ++bad;
      if (std::isfinite(x[i - n])) add(-x[i - n]); else --bad;
    }
    out[i] = bad ? SIMLEV_NA : (sum + comp) / n;
  }
  return SIMLEV_DONE(out);
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

static double kendall_tau_core(simlev_host::NumVec x, simlev_host::NumVec y) {
  const int n = x.size();
  if (n < 2) return SIMLEV_NA;
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
  const long double num = (long double) n0 - n1 - n2 + n3 - 2.0L * swaps;
  const long double den = std::sqrt((long double) (n0 - n1) * (long double) (n0 - n2));
  if (den == 0.0L) return SIMLEV_NA;
  return (double) (num / den);
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

}  // namespace simlev

#endif
