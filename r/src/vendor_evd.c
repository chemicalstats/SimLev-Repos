/*
 * vendor_evd.c  --  .Call-Huelle fuer den uebernommenen C-Code des R-Pakets evd
 *
 * Paket:    evd 2.3-7.1 (CRAN, 2024-09-21), Datei src/pot.c (Funktion nlgpd)
 * Autoren:  Alec Stephenson. Function fbvpot by Chris Ferro.
 * Lizenz:   GPL-3
 * Angepasst fuer SimLev (siehe inst/COPYRIGHTS):
 *   - nlgpd heisst hier evd_nlgpd (static); der Funktionsrumpf steht seit
 *     Etappe 7.3a in src/vendor_evd_impl.h (gemeinsam mit Python, Einzelheiten
 *     dort) und wird hier eingebunden. Kopfdateien R.h/Rmath.h direkt statt
 *     evd's header.h.
 *   - evd ruft nlgpd ueber .C auf. SimLev registriert in init.c nur
 *     .Call-Routinen (frueher erzeugte Rcpp::compileAttributes die
 *     Registrierung), deshalb ruft R/vendor_evd.R die Huelle C_evd_nlgpd
 *     ueber .Call auf. Sie bildet nach, was .C(C_nlgpd, exceed, nhigh,
 *     threshold, scale, shape, dns = double(1))$dns tut: Pruefung der
 *     Argumente wie .C mit NAOK = FALSE (gleiche Meldungen, gleiche
 *     Argumentnummern), Kopie von data (nlgpd ueberschreibt sie), dns = 0
 *     als Startwert, Rueckgabe dns.
 */
#include <R.h>
#include <Rinternals.h>
#include <Rmath.h>

/* Host des gemeinsamen Kerns (vendor_evd_impl.h): die frueheren R-Aufrufe */
#define SIMLEV_EVD_ALLOC(n) (double *)R_alloc(n, sizeof(double))
#define SIMLEV_EVD_POW(x, y) R_pow(x, y)
#include "vendor_evd_impl.h"

/* .C-Argument (double) kopieren und wie .C mit NAOK = FALSE pruefen */
static double *evd_c_real(SEXP x, int argno)
{
  R_xlen_t i, len;
  double *p;
  if(TYPEOF(x) != REALSXP)
    error("evd_nlgpd: argument %d must be double", argno);
  len = XLENGTH(x);
  p = (double *) R_alloc(len > 0 ? len : 1, sizeof(double));
  for(i = 0; i < len; i++) {
    p[i] = REAL(x)[i];
    if(!R_FINITE(p[i]))
      error("NA/NaN/Inf in foreign function call (arg %d)", argno);
  }
  return p;
}

SEXP C_evd_nlgpd(SEXP data, SEXP n, SEXP loc, SEXP scale, SEXP shape)
{
  double *d, *l, *sc, *sh, dns = 0.0;
  int nn;
  d = evd_c_real(data, 1);
  if(TYPEOF(n) != INTSXP || XLENGTH(n) < 1)
    error("evd_nlgpd: argument 2 must be integer");
  nn = INTEGER(n)[0];
  if(nn == NA_INTEGER)
    error("NAs in foreign function call (arg %d)", 2);
  l = evd_c_real(loc, 3);
  sc = evd_c_real(scale, 4);
  sh = evd_c_real(shape, 5);
  evd_nlgpd(d, &nn, l, sc, sh, &dns);
  return ScalarReal(dns);
}
