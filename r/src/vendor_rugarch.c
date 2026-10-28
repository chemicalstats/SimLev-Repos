/*
 * vendor_rugarch.c  --  .Call-Huellen fuer den uebernommenen C-Code des R-Pakets rugarch
 *
 * Paket:    rugarch 1.5-6 (CRAN, 2026-07-18), Dateien src/garchmodels.c
 *           (sgarchfilterC, gjrgarchfilterC), src/filters.c (sgarchfilter,
 *           gjrgarchfilter, arfimaxfilter) und src/distributions.c
 *           (garchdistribution, dnormstd)
 * Autoren:  Alexios Galanos [aut, cre, cph], Tobias Kley [ctb]
 * Lizenz:   GPL-3
 * Angepasst fuer SimLev (siehe inst/COPYRIGHTS):
 *   - Die uebernommenen Filter (sgarchfilterC, gjrgarchfilterC mit ihren
 *     Hilfen) stehen seit Etappe 7.3a in src/vendor_rugarch_impl.h (ohne R-Bezug,
 *     gemeinsame Quelle fuer R und Python; Einzelheiten dort); diese Datei bindet
 *     sie ein und enthaelt die .Call-Huellen.
 *   - rugarch ruft sgarchfilterC und gjrgarchfilterC ueber .C auf. SimLev
 *     registriert in init.c nur .Call-Routinen (frueher erzeugte
 *     Rcpp::compileAttributes die Registrierung), deshalb rufen die
 *     R-Funktionen die Huellen C_rugarch_sgarchfilterC und
 *     C_rugarch_gjrgarchfilterC ueber .Call auf.
 *     Sie bilden .C(..., NAOK = FALSE) nach: Pruefung der Argumente (gleiche
 *     Meldungen und Argumentnummern), Kopie aller Argumente, Rueckgabe der
 *     Liste aller Argumente mit ihren Namen.
 */
#include <R.h>
#include <Rinternals.h>
#include <math.h>

#include "vendor_rugarch_impl.h"

/* ---- .C-Nachbildung (SimLev) -------------------------------------------- */

/* Argument wie .C kopieren und wie .C mit NAOK = FALSE pruefen; die R-Seite
 * uebergibt wie in rugarch as.integer()/as.double() */
static SEXP rugarch_c_arg(SEXP x, int argno)
{
  R_xlen_t i, n;
  SEXP y;
  if(TYPEOF(x) == REALSXP) {
    n = XLENGTH(x);
    for(i = 0; i < n; i++)
      if(!R_FINITE(REAL(x)[i]))
        error("NA/NaN/Inf in foreign function call (arg %d)", argno);
  } else if(TYPEOF(x) == INTSXP) {
    n = XLENGTH(x);
    for(i = 0; i < n; i++)
      if(INTEGER(x)[i] == NA_INTEGER)
        error("NAs in foreign function call (arg %d)", argno);
  } else {
    error("invalid mode (%s) to pass to C or Fortran (arg %d)", type2char(TYPEOF(x)), argno);
  }
  y = duplicate(x);
  return y;
}

/* Liste der kopierten Argumente mit den Namen wie .C(...) */
static SEXP rugarch_c_call(SEXP args, int nargs)
{
  SEXP out, nms, onms;
  int k;
  if(TYPEOF(args) != VECSXP || LENGTH(args) != nargs)
    error("rugarch-Uebernahme: interne Argumentliste ungueltig");
  PROTECT(out = allocVector(VECSXP, nargs));
  for(k = 0; k < nargs; k++)
    SET_VECTOR_ELT(out, k, rugarch_c_arg(VECTOR_ELT(args, k), k + 1));
  nms = getAttrib(args, R_NamesSymbol);
  PROTECT(onms = duplicate(nms));
  setAttrib(out, R_NamesSymbol, onms);
  UNPROTECT(2);
  return out;
}

#define RG_I(k) INTEGER(VECTOR_ELT(out, k))
#define RG_D(k) REAL(VECTOR_ELT(out, k))

/* .C("sgarchfilterC", model, pars, idx, hEst, x, res, e, mexdata, vexdata,
 *    zrf, constm, condm, m, T, h, z, llh, LHT) */
SEXP C_rugarch_sgarchfilterC(SEXP args)
{
  SEXP out;
  PROTECT(out = rugarch_c_call(args, 18));
  if(TYPEOF(VECTOR_ELT(out, 0)) != INTSXP || TYPEOF(VECTOR_ELT(out, 2)) != INTSXP ||
     TYPEOF(VECTOR_ELT(out, 12)) != INTSXP || TYPEOF(VECTOR_ELT(out, 13)) != INTSXP)
    error("rugarch-Uebernahme: interne Argumenttypen ungueltig");
  rugarch_sgarchfilterC(RG_I(0), RG_D(1), RG_I(2), RG_D(3), RG_D(4), RG_D(5), RG_D(6), RG_D(7),
                        RG_D(8), RG_D(9), RG_D(10), RG_D(11), RG_I(12), RG_I(13), RG_D(14),
                        RG_D(15), RG_D(16), RG_D(17));
  UNPROTECT(1);
  return out;
}

/* .C("gjrgarchfilterC", model, pars, idx, hEst, x, res, nres, e, mexdata,
 *    vexdata, zrf, constm, condm, m, T, h, z, llh, LHT) */
SEXP C_rugarch_gjrgarchfilterC(SEXP args)
{
  SEXP out;
  PROTECT(out = rugarch_c_call(args, 19));
  if(TYPEOF(VECTOR_ELT(out, 0)) != INTSXP || TYPEOF(VECTOR_ELT(out, 2)) != INTSXP ||
     TYPEOF(VECTOR_ELT(out, 13)) != INTSXP || TYPEOF(VECTOR_ELT(out, 14)) != INTSXP)
    error("rugarch-Uebernahme: interne Argumenttypen ungueltig");
  rugarch_gjrgarchfilterC(RG_I(0), RG_D(1), RG_I(2), RG_D(3), RG_D(4), RG_D(5), RG_D(6), RG_D(7),
                          RG_D(8), RG_D(9), RG_D(10), RG_D(11), RG_D(12), RG_I(13), RG_I(14),
                          RG_D(15), RG_D(16), RG_D(17), RG_D(18));
  UNPROTECT(1);
  return out;
}
