// src/dependence_core_impl.h
// Kern fuer zeitvariable Korrelationen (DCC(1,1), Engle 2002), reine Rechnung ohne R
// und Python.
//
// GEMEINSAME QUELLE FUER R UND PYTHON (Etappe 7.3a): R ruft den Kern ueber die
// .Call-Huelle in src/dependence_core.cpp auf (sie wandelt nur die R-Objekte um),
// Python ueber das Erweiterungsmodul simlev._ext (python/src/_ext_dependence.cpp).
// Python baut aus einer Byte-fuer-Byte-Kopie in python/src/
// (python/tests/test_shared_c.py); Aenderungen nur hier vornehmen und danach
// kopieren. Der reine Python-Kern (simlev/_dependence_core.py, dcc_filter) rechnet
// dasselbe und bleibt der Rueckfall.
//
// Aufbau wie alle C++-Kerne (simlev_core.h): statische Funktionen ueber den Sichten
// simlev_host::NumVec/IntVec/NumMat und den Host-Makros SIMLEV_* (Fehler, NA,
// Anlegen der Ergebnisse), die die einbindende Huelle festlegt (R: simlev_capi.h,
// Python: _ext_common.h). Die Rechnung ist Zeile fuer Zeile die fruehere aus
// dependence_core.cpp; fuer R setzen die Makros genau die frueheren Aufrufe ein, der
// Compiler erzeugt daher denselben Maschinencode wie vor der Teilung (geprueft per
// Disassemblierung).
//
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

#ifndef SIMLEV_DEPENDENCE_CORE_IMPL_H
#define SIMLEV_DEPENDENCE_CORE_IMPL_H

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

namespace simlev {

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

// Ueber den Host: SIMLEV_NA (NA), SIMLEV_MATRIX legt das Ergebnis an, SIMLEV_LIST gibt
// die benannte Liste zurueck (R: new_mat, named_list wie frueher).
static auto dcc_filter(simlev_host::NumMat Z, double a, double b, simlev_host::NumMat Qbar, bool keep) {
  const int n = Z.nrow(), k = Z.ncol();
  const int np = k * (k - 1) / 2;
  std::vector<double> Q(k * k), R(k * k), L(k * k), y(k);
  for (int i = 0; i < k; ++i) for (int j = 0; j < k; ++j) Q[i * k + j] = Qbar(i, j);
  auto out = SIMLEV_MATRIX(keep ? n : 0, keep ? np : 0);
  if (keep) std::fill(out.begin(), out.end(), SIMLEV_NA);  // nicht berechnete Zeilen bleiben NA
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
  return SIMLEV_LIST("nll", nll, "R", out, "ok", ok);
}

}  // namespace simlev

#endif
