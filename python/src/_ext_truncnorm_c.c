/*
 * python/src/_ext_truncnorm_c.c -- C-Teil der Python-Huelle von rtruncnorm (truncnorm 1.0-9,
 * simlev._ext)
 *
 * Etappe 7.3b. Bindet den gemeinsamen Kern vendor_truncnorm_impl.h (Byte-fuer-Byte-Kopie
 * von r/src/vendor_truncnorm_impl.h) als C ein, wie src/vendor_truncnorm.c in R, und
 * stellt die Namen aus R's Rmath.h und R.h, die die Ruempfe nutzen:
 *   runif, rnorm, rexp, dnorm   C-Nachbildung von R's Zufallszahlen und dnorm4 (_rng_r.c)
 *                               auf dem gebundenen Zustand von simlev._r.rng
 *   R_CheckUserInterrupt        simlev_py_check_interrupt (_ext_truncnorm.cpp):
 *                               PyErr_CheckSignals(); nach einem Signal laeuft die Schleife zu
 *                               Ende, danach meldet die Huelle KeyboardInterrupt. Mit GIL.
 *   NA_REAL, R_PosInf, R_NegInf, R_FINITE  wie in R ausserhalb dieser Datei (_rng_r.c)
 *   M_1_SQRT_2PI, R_INLINE, R_len_t, FALSE wie in R
 */
#include <math.h>

#include "_rng_r.h"

typedef int R_len_t;
/* wie in R ausserhalb der eigenen Uebersetzungseinheit (R: Variablen und Funktionen der
 * libR, R_FINITE ohne HAVE_WORKING_ISFINITE als Aufruf von R_finite), damit der Compiler
 * die Ruempfe wie in R uebersetzt (Reihenfolge der Operanden bei zwei NaN) */
void simlev_py_check_interrupt(void);
#define R_INLINE inline
#define NA_REAL (simlev_R_NaReal.d)
#define R_PosInf simlev_R_PosInf
#define R_NegInf simlev_R_NegInf
#define R_FINITE(x) simlev_R_finite(x)
#ifndef M_1_SQRT_2PI
#define M_1_SQRT_2PI 0.398942280401432677939946059934
#endif
#ifndef FALSE
#define FALSE 0
#endif
#define runif simlev_rng_runif
#define rnorm simlev_rng_rnorm
#define rexp simlev_rng_rexp
#define dnorm simlev_rng_dnorm4
#define R_CheckUserInterrupt() simlev_py_check_interrupt()

#include "vendor_truncnorm_impl.h"

/* Schleife von do_rtruncnorm */
void simlev_py_truncnorm(int nn, double *a, int n_a, double *b, int n_b, double *mean, int n_mean, double *sd,
                         int n_sd, double *ret)
{
    truncnorm_rtruncnorm_loop(nn, a, n_a, b, n_b, mean, n_mean, sd, n_sd, ret);
}
