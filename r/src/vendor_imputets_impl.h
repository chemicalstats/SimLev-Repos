/*
 * vendor_imputets_impl.h  --  uebernommener C++-Code des R-Pakets imputeTS, reine Rechnung
 *
 * Paket:    imputeTS 3.4 (CRAN, 2025-08-25), Datei src/locf.cpp (Funktion locf)
 * Autoren:  Steffen Moritz [aut, cre, cph], Sebastian Gatscha [aut],
 *           Earo Wang [ctb], Ron Hause [ctb]
 * Lizenz:   GPL-3
 * Angepasst fuer SimLev (siehe inst/COPYRIGHTS):
 *   - locf heisst hier imputets_locf (static). Der Funktionsrumpf ist
 *     unveraendert bis auf die Aufrufe, die die einbindende Datei stellt (Host der
 *     gemeinsamen Kerne, simlev_core.h): SIMLEV_CLONE (R: sl::clone =
 *     Rf_duplicate, wie frueher Rcpp::clone), SIMLEV_CHECK_INTERRUPT (R:
 *     sl::check_interrupt wie Rcpp::checkUserInterrupt; Python: PyErr_CheckSignals),
 *     SIMLEV_R_FINITE (R: R_finite; Python: std::isfinite) und SIMLEV_DONE.
 *   - GEMEINSAME QUELLE FUER R UND PYTHON (Etappe 7.3a): frueher Teil von
 *     src/vendor_imputets.cpp, die jetzt diese Datei einbindet (derselbe
 *     Maschinencode wie vor der Teilung) und nur noch die .Call-Huelle enthaelt.
 *     Python bindet sie in python/src/_ext_imputets.cpp ein (simlev._ext) und baut
 *     aus einer Byte-fuer-Byte-Kopie in python/src/ (python/tests/test_shared_c.py);
 *     Aenderungen nur hier vornehmen und danach kopieren. Der reine Python-Port
 *     (simlev/_r/imputets.py) bleibt der Rueckfall.
 *   - ma() aus imputeTS src/ma.cpp ist nicht uebernommen. Keine Zufallszahlen.
 */
#ifndef SIMLEV_VENDOR_IMPUTETS_IMPL_H
#define SIMLEV_VENDOR_IMPUTETS_IMPL_H

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
#if !defined(SIMLEV_CLONE) || !defined(SIMLEV_CHECK_INTERRUPT) || !defined(SIMLEV_R_FINITE)
#error "Vor diesem Kern den Host einbinden: R simlev_capi.h, Python _ext_common.h (siehe simlev_core.h)."
#endif

namespace simlev {

static auto imputets_locf(simlev_host::NumVec x, bool reverse)
{

  auto z = SIMLEV_CLONE(x);

  long n = z.size();

  if (!reverse) {
    for(long i = 0; i < n; i++ ) {

      if (i % 1024 == 0) {SIMLEV_CHECK_INTERRUPT();}


      if(i > 0 && !SIMLEV_R_FINITE(z[i]) && SIMLEV_R_FINITE(z[i-1]))
      {
        z[i] = z[i-1];
      }
    }
  }
  else {
    for(long i = n-1; i >= 0; i-- ) {

      if (i % 1024 == 0) {SIMLEV_CHECK_INTERRUPT();}


      if(i < n-1 && !SIMLEV_R_FINITE(z[i]) && SIMLEV_R_FINITE(z[i+1]))
      {
        z[i] = z[i+1];
      }
    }

  }
return SIMLEV_DONE(z);

}

}  // namespace simlev

#endif
