// src/dependence_core.cpp
// Kern fuer zeitvariable Korrelationen (DCC(1,1), Engle 2002).
//
//   Q_t = (1 - a - b) Qbar + a z_{t-1} z_{t-1}' + b Q_{t-1},   Q_1 = Qbar
//   R_t = diag(Q_t)^{-1/2} Q_t diag(Q_t)^{-1/2}
//
// Zweite Stufe der Quasi-Likelihood (Korrelationsteil):
//   -l = 0.5 * sum_t ( log|R_t| + z_t' R_t^{-1} z_t - z_t' z_t )
// z sind die mit univariaten GARCH-Modellen standardisierten Residuen.
// Fehlende Werte sind nicht erlaubt (in R vorher entfernen). Ist R_t nicht
// positiv definit, bricht der Filter ab: nll = 1e10, ok = false, die
// Korrelationen ab dieser Zeile sind NA.

#include "simlev_capi.h"
#include <vector>
#include <cmath>

// Cholesky-Zerlegung einer kleinen symmetrischen Matrix (zeilenweise, k x k).
// Liefert false, wenn die Matrix nicht positiv definit ist.
static bool chol_small(const std::vector<double>& A, std::vector<double>& L, int k) {
  std::fill(L.begin(), L.end(), 0.0);
  for (int i = 0; i < k; ++i) {
    for (int j = 0; j <= i; ++j) {
      double s = A[i * k + j];
      for (int m = 0; m < j; ++m) s -= L[i * k + m] * L[j * k + m];
      if (i == j) {
        if (s <= 1e-14) return false;
        L[i * k + i] = std::sqrt(s);
      } else {
        L[i * k + j] = s / L[j * k + j];
      }
    }
  }
  return true;
}

static SEXP dcc_filter(sl::NumMat Z, double a, double b, sl::NumMat Qbar, bool keep) {
  const int n = Z.nrow(), k = Z.ncol();
  const int np = k * (k - 1) / 2;
  std::vector<double> Q(k * k), R(k * k), L(k * k), y(k);
  for (int i = 0; i < k; ++i) for (int j = 0; j < k; ++j) Q[i * k + j] = Qbar(i, j);
  sl::NumMat out = sl::new_mat(keep ? n : 0, keep ? np : 0);
  if (keep) std::fill(out.begin(), out.end(), NA_REAL);  // nicht berechnete Zeilen bleiben NA
  double nll = 0.0;
  bool ok = true;
  for (int t = 0; t < n; ++t) {
    if (t > 0) {
      for (int i = 0; i < k; ++i) for (int j = 0; j < k; ++j)
        Q[i * k + j] = (1.0 - a - b) * Qbar(i, j) + a * Z(t - 1, i) * Z(t - 1, j) + b * Q[i * k + j];
    }
    for (int i = 0; i < k; ++i) for (int j = 0; j < k; ++j)
      R[i * k + j] = Q[i * k + j] / std::sqrt(Q[i * k + i] * Q[j * k + j]);
    if (!chol_small(R, L, k)) { ok = false; break; }
    double logdet = 0.0, quad = 0.0, zz = 0.0;
    for (int i = 0; i < k; ++i) {                 // L y = z (Vorwaertseinsetzen)
      double s = Z(t, i);
      for (int m = 0; m < i; ++m) s -= L[i * k + m] * y[m];
      y[i] = s / L[i * k + i];
      quad += y[i] * y[i];
      zz += Z(t, i) * Z(t, i);
      logdet += 2.0 * std::log(L[i * k + i]);
    }
    nll += 0.5 * (logdet + quad - zz);
    if (keep) {
      int p = 0;
      for (int i = 0; i < k; ++i) for (int j = i + 1; j < k; ++j) out(t, p++) = R[i * k + j];
    }
  }
  if (!ok) nll = 1e10;
  return sl::named_list("nll", nll, "R", out, "ok", ok);
}

// ===========================================================================
// .CALL-HUELLE (registriert in init.c; R-Seite in R/cores.R)
// ===========================================================================

extern "C" SEXP C_dcc_filter(SEXP s_Z, SEXP s_a, SEXP s_b, SEXP s_Qbar, SEXP s_keep) {
  return sl::call([&]() {
    sl::NumMat Z = sl::num_mat(s_Z);
    double a = sl::as_double(s_a);
    double b = sl::as_double(s_b);
    sl::NumMat Qbar = sl::num_mat(s_Qbar);
    bool keep = sl::as_bool(s_keep);
    return dcc_filter(Z, a, b, Qbar, keep);
  });
}
