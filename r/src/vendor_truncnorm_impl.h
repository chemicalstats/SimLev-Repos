/*
 * vendor_truncnorm_impl.h  --  uebernommener C-Code des R-Pakets truncnorm, reine Rechnung
 *
 * Paket:    truncnorm 1.0-9 (CRAN, 2023-03-20), Datei src/rtruncnorm.c
 * Autoren:  Olaf Mersmann [aut, cre], Heike Trautmann [aut],
 *           Detlef Steuer [aut], Bjoern Bornkamp [aut]
 * Lizenz:   GPL (>= 2); in SimLev unter GPL-3 weitergegeben
 * Angepasst fuer SimLev (siehe inst/COPYRIGHTS):
 *   - Uebernommen ist nur der Zufallszahlengenerator (do_rtruncnorm mit den
 *     Samplern), den Rsolnp::gosolnp ueber rtruncnorm() nutzt (Startwerte
 *     von gosolnp, Verteilung 2, in R/vendor_rsolnp.R). Die Sampler sind
 *     static und tragen den Praefix truncnorm_; die Funktionsruempfe sind
 *     unveraendert.
 *   - GEMEINSAME QUELLE FUER R UND PYTHON (Etappe 7.3b): frueher Teil von
 *     src/vendor_truncnorm.c, die jetzt diese Datei einbindet (derselbe
 *     Maschinencode wie vor der Teilung) und nur noch die .Call-Huelle
 *     C_truncnorm_rtruncnorm (frueher do_rtruncnorm) enthaelt. Deren Schleife ueber
 *     die Werte steht unveraendert in truncnorm_rtruncnorm_loop. Python bindet die
 *     Datei in python/src/_ext_truncnorm_c.c ein (Erweiterungsmodul simlev._ext) und
 *     baut aus einer Byte-fuer-Byte-Kopie in python/src/
 *     (python/tests/test_shared_c.py); Aenderungen nur hier vornehmen und danach
 *     kopieren. Der reine Python-Port (simlev/_r/truncnorm.py, rtruncnorm) bleibt
 *     der Rueckfall.
 *   - Host: Die Ruempfe nutzen die Namen aus R's Rmath.h und R.h, die die
 *     einbindende Datei stellt: runif, rnorm, rexp, dnorm (R: Rf_runif, Rf_rnorm,
 *     Rf_rexp, Rf_dnorm4 aus R's nmath; Python: die C-Nachbildung von R's
 *     Zufallszahlen und dnorm in python/src/_rng_r.c auf dem Zustand von
 *     simlev._r.rng), R_CheckUserInterrupt, NA_REAL, R_PosInf, R_NegInf, R_FINITE,
 *     M_1_SQRT_2PI, R_INLINE, R_len_t. exp und pow aus der libm des Systems.
 */
#ifndef SIMLEV_VENDOR_TRUNCNORM_IMPL_H
#define SIMLEV_VENDOR_TRUNCNORM_IMPL_H

/* Gleitkomma wie im Pilot (simlev_core.h): Abbruch bei -ffast-math; kein
 * Zusammenziehen von a * b + c zu fma. Das Pragma steht nur dort, wo der Compiler
 * fma ueberhaupt erzeugen kann (__FP_FAST_FMA, etwa aarch64 oder -mfma): auf
 * x86-64 ohne FMA ist -ffp-contract=off wirkungslos, das GCC-Pragma optimize
 * veraendert dort aber die Codeerzeugung der ganzen Datei (geprueft), und R soll
 * denselben Maschinencode wie vor der Teilung ausfuehren. Python baut immer mit
 * -ffp-contract=off (setup.py) und setzt SIMLEV_FP_CONTRACT_BY_FLAG. */
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

#if !defined(runif) || !defined(rnorm) || !defined(rexp) || !defined(dnorm) || !defined(R_INLINE) || !defined(NA_REAL)
#error "Vor vendor_truncnorm_impl.h den Host einbinden (R: Rmath.h in src/vendor_truncnorm.c, Python: _ext_truncnorm_c.c)."
#endif

#ifdef DEBUG
#define SAMPLER_DEBUG(N, A, B) Rprintf("%8s(%f, %f)\n", N, A, B)
#else
#define SAMPLER_DEBUG(N, A, B)
#endif

static const double t1 = 0.15;
static const double t2 = 2.18;
static const double t3 = 0.725;
static const double t4 = 0.45;

/* Exponential rejection sampling (a,inf) */
static R_INLINE double truncnorm_ers_a_inf(double a) {
  SAMPLER_DEBUG("ers_a_inf", a, R_PosInf);
  const double ainv = 1.0 / a;
  double x, rho;
  do {
    x = rexp(ainv) + a; /* rexp works with 1/lambda */
    rho = exp(-0.5 * pow((x - a), 2));
  } while (runif(0, 1) > rho);
  return x;
}

/* Exponential rejection sampling (a,b) */
static R_INLINE double truncnorm_ers_a_b(double a, double b) {
  SAMPLER_DEBUG("ers_a_b", a, b);
  const double ainv = 1.0 / a;
  double x, rho;
  do {
    x = rexp(ainv) + a; /* rexp works with 1/lambda */
    rho = exp(-0.5 * pow((x - a), 2));
  } while (runif(0, 1) > rho || x > b);
  return x;
}

/* Normal rejection sampling (a,b) */
static R_INLINE double truncnorm_nrs_a_b(double a, double b) {
  SAMPLER_DEBUG("nrs_a_b", a, b);
  double x = -DBL_MAX;
  while (x < a || x > b) {
    x = rnorm(0, 1);
  }
  return x;
}

/* Normal rejection sampling (a,inf) */
static R_INLINE double truncnorm_nrs_a_inf(double a) {
  SAMPLER_DEBUG("nrs_a_inf", a, R_PosInf);
  double x = -DBL_MAX;
  while (x < a) {
    x = rnorm(0, 1);
  }
  return x;
}

/* Half-normal rejection sampling */
static double truncnorm_hnrs_a_b(double a, double b) {
  SAMPLER_DEBUG("hnrs_a_b", a, b);
  double x = a - 1.0;
  while (x < a || x > b) {
    x = rnorm(0, 1);
    x = fabs(x);
  }
  return x;
}

/* Uniform rejection sampling */
static R_INLINE double truncnorm_urs_a_b(double a, double b) {
  SAMPLER_DEBUG("urs_a_b", a, b);
  const double phi_a = dnorm(a, 0.0, 1.0, FALSE);
  double x = 0.0, u = 0.0;

  /* Upper bound of normal density on [a, b] */
  const double ub = a < 0 && b > 0 ? M_1_SQRT_2PI : phi_a;
  do {
    x = runif(a, b);
  } while (runif(0, 1) * ub > dnorm(x, 0, 1, 0));
  return x;
}

/* Previously this was refered to as type 1 sampling: */
static inline double truncnorm_r_lefttruncnorm(double a, double mean, double sd) {
  const double alpha = (a - mean) / sd;
  if (alpha < t4) {
    return mean + sd * truncnorm_nrs_a_inf(alpha);
  } else {
    return mean + sd * truncnorm_ers_a_inf(alpha);
  }
}

static R_INLINE double truncnorm_r_righttruncnorm(double b, double mean, double sd) {
  const double beta = (b - mean) / sd;
  /* Exploit symmetry: */
  return mean - sd * truncnorm_r_lefttruncnorm(-beta, 0.0, 1.0);
}

static R_INLINE double truncnorm_r_truncnorm(double a, double b, double mean, double sd) {
  const double alpha = (a - mean) / sd;
  const double beta = (b - mean) / sd;
  const double phi_a = dnorm(alpha, 0.0, 1.0, FALSE);
  const double phi_b = dnorm(beta, 0.0, 1.0, FALSE);
  if (beta <= alpha) {
    return NA_REAL;
  } else if (alpha <= 0 && 0 <= beta) { /* 2 */
    if (phi_a <= t1 || phi_b <= t1) {   /* 2 (a) */
      return mean + sd * truncnorm_nrs_a_b(alpha, beta);
    } else { /* 2 (b) */
      return mean + sd * truncnorm_urs_a_b(alpha, beta);
    }
  } else if (alpha > 0) {      /* 3 */
    if (phi_a / phi_b <= t2) { /* 3 (a) */
      return mean + sd * truncnorm_urs_a_b(alpha, beta);
    } else {
      if (alpha < t3) { /* 3 (b) */
        return mean + sd * truncnorm_hnrs_a_b(alpha, beta);
      } else { /* 3 (c) */
        return mean + sd * truncnorm_ers_a_b(alpha, beta);
      }
    }
  } else {                     /* 3s */
    if (phi_b / phi_a <= t2) { /* 3s (a) */
      return mean - sd * truncnorm_urs_a_b(-beta, -alpha);
    } else {
      if (beta > -t3) { /* 3s (b) */
        return mean - sd * truncnorm_hnrs_a_b(-beta, -alpha);
      } else { /* 3s (c) */
        return mean - sd * truncnorm_ers_a_b(-beta, -alpha);
      }
    }
  }
}

/* Schleife von do_rtruncnorm ueber die Werte (Recycling der Argumente auf die Laenge nn) */
static R_INLINE void truncnorm_rtruncnorm_loop(R_len_t nn, double *a, R_len_t n_a, double *b, R_len_t n_b,
                                               double *mean, R_len_t n_mean, double *sd, R_len_t n_sd,
                                               double *ret) {
  R_len_t i;
  for (i = 0; i < nn; ++i) {
    const double ca = a[i % n_a];
    const double cb = b[i % n_b];
    const double cmean = mean[i % n_mean];
    const double csd = sd[i % n_sd];

    if (R_FINITE(ca) && R_FINITE(cb)) {
      ret[i] = truncnorm_r_truncnorm(ca, cb, cmean, csd);
    } else if (R_NegInf == ca && R_FINITE(cb)) {
      ret[i] = truncnorm_r_righttruncnorm(cb, cmean, csd);
    } else if (R_FINITE(ca) && R_PosInf == cb) {
      ret[i] = truncnorm_r_lefttruncnorm(ca, cmean, csd);
    } else if (R_NegInf == ca && R_PosInf == cb) {
      ret[i] = rnorm(cmean, csd);
    } else {
      ret[i] = NA_REAL;
    }
    R_CheckUserInterrupt();
  }
}

#endif
