/*
 * python/src/_rng_r.h -- Schnittstelle der C-Nachbildung von R's Zufallszahlen (_rng_r.c)
 *
 * Etappe 7.3b. Nur Python-Seite: R nutzt in den gemeinsamen Kernen sein eigenes RNG
 * (r/src/simlev_capi.h). Die Kerne mit Zufallszahlen (r/src/bootstrap_core_impl.h,
 * r/src/vendor_truncnorm_impl.h) ziehen in simlev._ext ueber diese Funktionen; sie
 * arbeiten auf dem Zustand der Python-Nachbildung simlev._r.rng, den die Huelle vor dem
 * Kern bindet (simlev_rng_bind) und danach zurueckschreibt (ext::Rng in _ext_common.h).
 *
 * Nachgebildet sind genau die Arten, die simlev._r.rng kennt: RNG_kind
 * "Mersenne-Twister" (3) und "L'Ecuyer-CMRG" (7), N01_kind "Inversion" (4). Andere
 * Arten weist die Huelle ab; die Python-Seite rechnet dann mit dem reinen Python-Kern.
 */
#ifndef SIMLEV_RNG_R_H
#define SIMLEV_RNG_R_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SIMLEV_RNG_MERSENNE_TWISTER 3
#define SIMLEV_RNG_LECUYER_CMRG 7
#define SIMLEV_RNG_INVERSION 4

/* Statische Variablen von rpois (R 4.3.3, src/nmath/rpois.c), die R zwischen Aufrufen
 * behaelt; in Python _RP in simlev._r.rng */
typedef struct simlev_rpois_state {
    int l, m;
    double b1, b2, c, c0, c1, c2, c3;
    double pp[36], p0, p, q, s, d, omega;
    double big_l;
    double muprev, muprev2;
} simlev_rpois_state;

/* Zustand des Generators (RNG_kind, N01_kind, .Random.seed) */
typedef struct simlev_rng_state {
    int kind;                    /* RNG_kind: 3 oder 7 */
    int n01;                     /* N01_kind: 4 */
    int mti;                     /* Mersenne-Twister: dummy[0] = .Random.seed[2] */
    int twisted;                 /* Ausgabe: 1, wenn der Mersenne-Twister neu erzeugt hat */
    uint32_t *mt;                /* Mersenne-Twister: 624 Woerter (dummy[1..624]) */
    uint32_t lec[6];             /* L'Ecuyer-CMRG: i_seed[0..5] */
    simlev_rpois_state *pois;    /* NULL: rpois nicht vorgesehen (dann pois_missing = 1) */
    int pois_missing;
} simlev_rng_state;

/* Fuer den truncnorm-Kern (_ext_truncnorm_c.c): R's NA_real_, R_PosInf, R_NegInf und R_finite
 * wie in der libR als Variablen bzw. Funktion einer anderen Uebersetzungseinheit */
typedef union simlev_na_bits { uint64_t u; double d; } simlev_na_bits;
extern simlev_na_bits simlev_R_NaReal;
extern double simlev_R_PosInf, simlev_R_NegInf;
int simlev_R_finite(double x);

/* Zustand fuer die folgenden Ziehungen festlegen (NULL: loesen) */
void simlev_rng_bind(simlev_rng_state *st);

/* R's unif_rand, norm_rand (Inversion), exp_rand */
double simlev_rng_unif_rand(void);
double simlev_rng_norm_rand(void);
double simlev_rng_exp_rand(void);

/* R's nmath: runif, rnorm, rexp (Skala), rgeom, rpois, dnorm4, qnorm5 */
double simlev_rng_runif(double a, double b);
double simlev_rng_rnorm(double mu, double sigma);
double simlev_rng_rexp(double scale);
double simlev_rng_rgeom(double p);
double simlev_rng_rpois(double mu);
double simlev_rng_dnorm4(double x, double mu, double sigma, int give_log);
double simlev_rng_qnorm5(double p, double mu, double sigma, int lower_tail, int log_p);

#ifdef __cplusplus
}
#endif

#endif
