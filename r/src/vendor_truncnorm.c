/*
 * vendor_truncnorm.c  --  uebernommener C-Code des R-Pakets truncnorm
 *
 * Paket:    truncnorm 1.0-9 (CRAN, 2023-03-20), Datei src/rtruncnorm.c
 *           (mit den benoetigten Makros aus src/sexp_macros.h)
 * Autoren:  Olaf Mersmann [aut, cre], Heike Trautmann [aut],
 *           Detlef Steuer [aut], Bjoern Bornkamp [aut]
 * Lizenz:   GPL (>= 2); in SimLev unter GPL-3 weitergegeben
 * Angepasst fuer SimLev (siehe inst/COPYRIGHTS):
 *   - Uebernommen ist nur der Zufallszahlengenerator (do_rtruncnorm mit den
 *     Samplern), den Rsolnp::gosolnp ueber rtruncnorm() nutzt (Startwerte
 *     von gosolnp, Verteilung 2, in R/vendor_rsolnp.R). Die Sampler sind
 *     static und tragen den Praefix truncnorm_, do_rtruncnorm heisst hier
 *     C_truncnorm_rtruncnorm; die Funktionsruempfe sind unveraendert. Sampler und
 *     Schleife stehen seit Etappe 7.3b in src/vendor_truncnorm_impl.h (gemeinsam
 *     mit Python, Einzelheiten dort) und werden hier eingebunden.
 *   - Aufgerufen wie im Original ueber .Call (aus .truncnorm_rtruncnorm in
 *     R/vendor_truncnorm.R).
 */
#include <R.h>
#include <Rdefines.h>
#include <Rmath.h>
#include <Rinternals.h>
#include <R_ext/Applic.h>
#include <float.h>

/* ---- src/sexp_macros.h (Auszug) ----------------------------------------- */

#define CHECK_ARG_IS_REAL_VECTOR(A)					\
    if (!isReal(A) || !isVector(A))					\
	error("Argument '" #A "' is not a real vector.");

#define CHECK_ARG_IS_INT_VECTOR(A)					\
    if (!isInteger(A) || !isVector(A))					\
	error("Argument '" #A "' is not an integer vector.");

/*
 * Unpack a real vector stored in SEXP S.
 */
#define UNPACK_REAL_VECTOR(S, D, N)             \
    CHECK_ARG_IS_REAL_VECTOR(S);		\
    double *D = REAL(S);			\
    const R_len_t N = length(S);

/*
 * Unpack a single integer stored in SEXP S.
 */
#define UNPACK_INT(S, I)			\
    CHECK_ARG_IS_INT_VECTOR(S);			\
    int I = INTEGER(S)[0];			\

/* ---- src/rtruncnorm.c --------------------------------------------------- */

#define ALLOC_REAL_VECTOR(S, D, N)                                             \
  SEXP S;                                                                      \
  PROTECT(S = allocVector(REALSXP, N));                                        \
  double *D = REAL(S);

#ifndef MAX
#define MAX(A, B) ((A > B) ? (A) : (B))
#endif

/* Host des gemeinsamen Kerns (vendor_truncnorm_impl.h): R's Rmath.h und R.h oben
 * (runif, rnorm, rexp, dnorm = Rf_runif, Rf_rnorm, Rf_rexp, Rf_dnorm4) */
#include "vendor_truncnorm_impl.h"

SEXP C_truncnorm_rtruncnorm(SEXP s_n, SEXP s_a, SEXP s_b, SEXP s_mean, SEXP s_sd) {
  R_len_t nn;
  UNPACK_INT(s_n, n);
  if (NA_INTEGER == n)
    error("n is NA - aborting.");
  UNPACK_REAL_VECTOR(s_a, a, n_a);
  UNPACK_REAL_VECTOR(s_b, b, n_b);
  UNPACK_REAL_VECTOR(s_mean, mean, n_mean);
  UNPACK_REAL_VECTOR(s_sd, sd, n_sd);

  nn = MAX(n, MAX(MAX(n_a, n_b), MAX(n_mean, n_sd)));
  ALLOC_REAL_VECTOR(s_ret, ret, nn);

  GetRNGstate();
  truncnorm_rtruncnorm_loop(nn, a, n_a, b, n_b, mean, n_mean, sd, n_sd, ret);
  PutRNGstate();
  UNPROTECT(1); /* s_ret */
  return s_ret;
}
