/*
 * vendor_evd_impl.h  --  uebernommener C-Code des R-Pakets evd, reine Rechnung
 *
 * Paket:    evd 2.3-7.1 (CRAN, 2024-09-21), Datei src/pot.c (Funktion nlgpd)
 * Autoren:  Alec Stephenson. Function fbvpot by Chris Ferro.
 * Lizenz:   GPL-3
 * Angepasst fuer SimLev (siehe inst/COPYRIGHTS):
 *   - nlgpd heisst hier evd_nlgpd (static); der Funktionsrumpf ist unveraendert
 *     bis auf die beiden R-Aufrufe, die die einbindende Datei als Makros stellt:
 *       SIMLEV_EVD_ALLOC(n)    Arbeitsfeld mit n doubles (R: R_alloc)
 *       SIMLEV_EVD_POW(x, y)   R_pow (R: R_pow; Python: dieselben Faelle wie
 *                              R_pow in R 4.3.3, arithmetic.c, mit pow aus der libm)
 *   - GEMEINSAME QUELLE FUER R UND PYTHON (Etappe 7.3a): frueher Teil von
 *     src/vendor_evd.c, die jetzt diese Datei einbindet (derselbe Maschinencode wie
 *     vor der Teilung) und nur noch die .Call-Huelle (Nachbildung von .C) enthaelt.
 *     Python bindet sie in python/src/_ext_evd_c.c ein (Erweiterungsmodul
 *     simlev._ext) und baut aus einer Byte-fuer-Byte-Kopie in python/src/
 *     (python/tests/test_shared_c.py); Aenderungen nur hier vornehmen und danach
 *     kopieren. Der reine Python-Port (simlev/_r/evd.py, nlgpd) bleibt der Rueckfall.
 *   - log aus der libm des Systems. Keine Zufallszahlen.
 */
#ifndef SIMLEV_VENDOR_EVD_IMPL_H
#define SIMLEV_VENDOR_EVD_IMPL_H

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

#include <float.h>
#include <math.h>

#if !defined(SIMLEV_EVD_ALLOC) || !defined(SIMLEV_EVD_POW)
#error "Vor vendor_evd_impl.h SIMLEV_EVD_ALLOC und SIMLEV_EVD_POW festlegen (R: src/vendor_evd.c)."
#endif

static void evd_nlgpd(double *data, int *n, double *loc, double *scale,
    double *shape, double *dns)
{
  int i;
  double *dvec, eps;

  dvec = SIMLEV_EVD_ALLOC(*n);
  eps = SIMLEV_EVD_POW(DBL_EPSILON, 0.3);

  if(*scale <= 0) {
     *dns = 1e6;
     return;
  }

  for(i=0;i<*n;i++)  {
    data[i] = (data[i] - *loc) / *scale;
    if(fabs(*shape) <= eps)
      dvec[i] = log(1 / *scale) - data[i];
    else {
      data[i] = 1 + *shape * data[i];
      if(data[i] <= 0) {
        *dns = 1e6;
        return;
      }
      dvec[i] = log(1 / *scale) - (1 / *shape + 1) * log(data[i]);
    }
  }

  for(i=0;i<*n;i++)
    *dns = *dns - dvec[i];
}

#endif
