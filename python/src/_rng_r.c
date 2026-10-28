/*
 * python/src/_rng_r.c -- C-Nachbildung von R's Zufallszahlen fuer simlev._ext (Etappe 7.3b)
 *
 * Herkunft: R 4.3.3 (https://www.R-project.org/), nach C uebernommen und angepasst fuer
 * SimLev (siehe python/COPYRIGHTS.md):
 *   src/main/RNG.c     unif_rand (Mersenne-Twister, L'Ecuyer-CMRG), fixup, MT_genrand,
 *                      MT_sgenrand   -- Copyright (C) 1997--2021 The R Core Team,
 *                      Copyright (C) 1995, 1996 Robert Gentleman and Ross Ihaka
 *   src/nmath/snorm.c  norm_rand (N01_kind Inversion)
 *                      -- Copyright (C) 1998 Ross Ihaka, (C) 2000-2022 The R Core Team
 *   src/nmath/qnorm.c  qnorm5 (Wichura, AS 241)
 *                      -- Copyright (C) 2000--2022 The R Core Team, (C) 2005-2022 The R
 *                      Foundation, (C) 1998 Ross Ihaka
 *   src/nmath/sexp.c   exp_rand (Ahrens & Dieter 1972)
 *                      -- Copyright (C) 1998 Ross Ihaka, (C) 2000--2011 The R Core Team
 *   src/nmath/runif.c, rnorm.c, rexp.c, rgeom.c, rpois.c (Ahrens & Dieter 1982), fsign.c,
 *   dnorm.c            -- Copyright (C) 1998 Ross Ihaka, (C) 2000--2021 The R Core Team
 * Lizenz: GPL (>= 2); in SimLev unter GPL-3 weitergegeben.
 *
 * Mersenne-Twister (aus RNG.c, dort mit diesem Vermerk):
 *   A C-program for MT19937: Real number version([0,1)-interval) (1999/10/28)
 *   Coded by Takuji Nishimura, considering the suggestions by Topher Cooper and Marc
 *   Rieffel in July-Aug. 1997.
 *   Copyright (C) 1997, 1999 Makoto Matsumoto and Takuji Nishimura.
 *   When you use this, send an email to: matumoto@math.keio.ac.jp with an appropriate
 *   reference to your work.
 *   REFERENCE: M. Matsumoto and T. Nishimura, "Mersenne Twister: A 623-Dimensionally
 *   Equidistributed Uniform Pseudo-Random Number Generator", ACM Transactions on
 *   Modeling and Computer Simulation, Vol. 8, No. 1, January 1998, pp 3--30.
 *
 * Angepasst:
 *   - Nur die Arten, die die Python-Nachbildung simlev._r.rng kennt: RNG_kind
 *     Mersenne-Twister und L'Ecuyer-CMRG, N01_kind Inversion. Die Funktionsruempfe
 *     sind die von R; statt der statischen Variablen von RNG.c (dummy, mt, mti,
 *     RNG_Table[kind].i_seed) und rpois.c arbeiten sie auf dem gebundenen Zustand
 *     (simlev_rng_bind, Aufbau in _rng_r.h), den die Huelle aus simlev._r.rng uebergibt
 *     und danach zurueckschreibt. Nach dem Kern ist der Python-Zustand derselbe, als
 *     haette der reine Python-Kern gezogen.
 *   - ML_NAN ist R_NaN (+NaN wie NAN); Warnungen der nmath (ME_DOMAIN) gibt R keine aus.
 *   - R_forceint wie in R unter Linux nearbyint; exp, log, sqrt, pow aus der libm.
 *   - Ein Aufruf von rpois ohne gebundenen rpois-Zustand setzt pois_missing (die Huelle
 *     meldet dann einen Fehler); die Kerne, die rgeom ziehen, binden ihn immer.
 *
 * Gleitkomma wie in den gemeinsamen Kernen: kein -ffast-math, kein fma (setup.py baut mit
 * -ffp-contract=off). Die Bitgleichheit zu R und zum reinen Python-Kern pruefen
 * python/tests/test_shared_c.py und der Zufallsvergleich gegen R (Etappe 7.3b).
 */
#if defined(__FAST_MATH__)
#error "_rng_r.c darf nicht mit -ffast-math uebersetzt werden (Bitgleichheit)."
#endif
#if defined(__clang__)
#pragma STDC FP_CONTRACT OFF
#elif defined(_MSC_VER)
#pragma fp_contract (off)
#endif

#include "_rng_r.h"

#include <float.h>
#include <math.h>
#include <stddef.h>

static simlev_rng_state *rs = NULL;

/* R_NaReal, R_PosInf, R_NegInf und R_finite wie in der libR (fuer _ext_truncnorm_c.c, das sie
 * wie R als Variablen bzw. Funktion ausserhalb der Uebersetzungseinheit sieht) */
simlev_na_bits simlev_R_NaReal = {UINT64_C(0x7FF00000000007A2)};   /* R's NA_real_ (Nutzlast 1954) */
double simlev_R_PosInf = HUGE_VAL, simlev_R_NegInf = -HUGE_VAL;
int simlev_R_finite(double x)
{
    return isfinite(x);
}

void simlev_rng_bind(simlev_rng_state *st)
{
    rs = st;
}

#define ML_NAN NAN
#define ML_WARN_return_NAN { return ML_NAN; }
#define R_FINITE(x) isfinite(x)
#define ISNAN(x) isnan(x)
#define ML_POSINF INFINITY
#define M_1_SQRT_2PI 0.398942280401432677939946059934
#define M_LN_SQRT_2PI 0.918938533204672741780329736406
#define M_LN2_R 0.693147180559945309417232121458
#define M_SQRT2_R 1.41421356237309504880168872421
#define M_2PI_R 6.283185307179586476925286766559
#define R_forceint(x) nearbyint(x)

/* ── src/main/RNG.c ──────────────────────────────────────────────────────── */

typedef unsigned int Int32;

#define i2_32m1 2.328306437080797e-10 /* = 1/(2^32 - 1) */

static double fixup(double x)
{
    /* ensure 0 and 1 are never returned */
    if(x <= 0.0) return 0.5*i2_32m1;
    if((1.0 - x) <= 0.0) return 1.0 - 0.5*i2_32m1;
    return x;
}

/* Period parameters */
#define N 624
#define M 397
#define MATRIX_A 0x9908b0df   /* constant vector a */
#define UPPER_MASK 0x80000000 /* most significant w-r bits */
#define LOWER_MASK 0x7fffffff /* least significant r bits */

/* Tempering parameters */
#define TEMPERING_MASK_B 0x9d2c5680
#define TEMPERING_MASK_C 0xefc60000
#define TEMPERING_SHIFT_U(y)  (y >> 11)
#define TEMPERING_SHIFT_S(y)  (y << 7)
#define TEMPERING_SHIFT_T(y)  (y << 15)
#define TEMPERING_SHIFT_L(y)  (y >> 18)

/* mt = rs->mt (dummy+1 in R), mti = rs->mti (dummy[0]) */

/* Initializing the array with a seed */
static void
MT_sgenrand(Int32 seed)
{
    int i;
    Int32 *mt = rs->mt;

    for (i = 0; i < N; i++) {
	mt[i] = seed & 0xffff0000;
	seed = 69069 * seed + 1;
	mt[i] |= (seed & 0xffff0000) >> 16;
	seed = 69069 * seed + 1;
    }
    rs->mti = N;
}

static double MT_genrand(void)
{
    Int32 y;
    static const Int32 mag01[2]={0x0, MATRIX_A};
    /* mag01[x] = x * MATRIX_A  for x=0,1 */
    Int32 *mt = rs->mt;
    int mti = rs->mti;

    if (mti >= N) { /* generate N words at one time */
	int kk;

	if (mti == N+1)   /* if sgenrand() has not been called, */
	    MT_sgenrand(4357); /* a default initial seed is used   */

	for (kk = 0; kk < N - M; kk++) {
	    y = (mt[kk] & UPPER_MASK) | (mt[kk+1] & LOWER_MASK);
	    mt[kk] = mt[kk+M] ^ (y >> 1) ^ mag01[y & 0x1];
	}
	for (; kk < N - 1; kk++) {
	    y = (mt[kk] & UPPER_MASK) | (mt[kk+1] & LOWER_MASK);
	    mt[kk] = mt[kk+(M-N)] ^ (y >> 1) ^ mag01[y & 0x1];
	}
	y = (mt[N-1] & UPPER_MASK) | (mt[0] & LOWER_MASK);
	mt[N-1] = mt[M-1] ^ (y >> 1) ^ mag01[y & 0x1];

	mti = 0;
	rs->twisted = 1;
    }

    y = mt[mti++];
    y ^= TEMPERING_SHIFT_U(y);
    y ^= TEMPERING_SHIFT_S(y) & TEMPERING_MASK_B;
    y ^= TEMPERING_SHIFT_T(y) & TEMPERING_MASK_C;
    y ^= TEMPERING_SHIFT_L(y);
    rs->mti = mti;

    return ( (double)y * 2.3283064365386963e-10 ); /* reals: [0,1)-interval */
}

#define II(i) (rs->lec[i])
#define m1    4294967087
#define m2    4294944443
#define normc  2.328306549295727688e-10
#define a12     (int_least64_t)1403580
#define a13n    (int_least64_t)810728
#define a21     (int_least64_t)527612
#define a23n    (int_least64_t)1370589

double simlev_rng_unif_rand(void)
{
    switch(rs->kind) {

    case SIMLEV_RNG_MERSENNE_TWISTER:
	return fixup(MT_genrand());

    case SIMLEV_RNG_LECUYER_CMRG:
    {
	/* Based loosely on the GPL-ed version of
	   http://www.iro.umontreal.ca/~lecuyer/myftp/streams00/c2010/RngStream.c
	   but using int_least64_t, which C99 guarantees.
	*/
	int k;
	int_least64_t p1, p2;

	p1 = a12 * (unsigned int)II(1) - a13n * (unsigned int)II(0);
	/* p1 % m1 would surely do */
	k = (int) (p1 / m1);
	p1 -= k * m1;
	if (p1 < 0.0) p1 += m1;
	II(0) = II(1); II(1) = II(2); II(2) = (int) p1;

	p2 = a21 * (unsigned int)II(5) - a23n * (unsigned int)II(3);
	k = (int) (p2 / m2);
	p2 -= k * m2;
	if (p2 < 0.0) p2 += m2;
	II(3) = II(4); II(4) = II(5); II(5) = (int) p2;

	return (double)((p1 > p2) ? (p1 - p2) : (p1 - p2 + m1)) * normc;
    }
    default:
	/* von der Huelle ausgeschlossen (nur die Arten von simlev._r.rng) */
	return ML_NAN;
    }
}

/* ── src/nmath/qnorm.c ───────────────────────────────────────────────────── */

/* R_DT_qIv, R_DT_CIv, R_Q_P01_boundaries aus src/nmath/dpq.h */
#define R_D_Lval(p)	(lower_tail ? (p) : (0.5 - (p) + 0.5))
#define R_D_Cval(p)	(lower_tail ? (0.5 - (p) + 0.5) : (p))
#define R_DT_qIv(p)	(log_p ? (lower_tail ? exp(p) : - expm1(p)) : R_D_Lval(p))
#define R_DT_CIv(p)	(log_p ? (lower_tail ? -expm1(p) : exp(p)) : R_D_Cval(p))
#define R_Q_P01_boundaries(p, _LEFT_, _RIGHT_)		\
    if (log_p) {					\
	if(p > 0)					\
	    ML_WARN_return_NAN;				\
	if(p == 0) /* upper bound*/			\
	    return lower_tail ? _RIGHT_ : _LEFT_;	\
	if(p == -INFINITY)				\
	    return lower_tail ? _LEFT_ : _RIGHT_;	\
    }							\
    else { /* !log_p */					\
	if(p < 0 || p > 1)				\
	    ML_WARN_return_NAN;				\
	if(p == 0)					\
	    return lower_tail ? _LEFT_ : _RIGHT_;	\
	if(p == 1)					\
	    return lower_tail ? _RIGHT_ : _LEFT_;	\
    }

double simlev_rng_qnorm5(double p, double mu, double sigma, int lower_tail, int log_p)
{
    double p_, q, r, val;

    if (ISNAN(p) || ISNAN(mu) || ISNAN(sigma))
	return p + mu + sigma;
    R_Q_P01_boundaries(p, -INFINITY, INFINITY);

    if(sigma  < 0)	ML_WARN_return_NAN;
    if(sigma == 0)	return mu;

    p_ = R_DT_qIv(p);/* real lower_tail prob. p */
    q = p_ - 0.5;

/*-- use AS 241 --- */
/* double ppnd16_(double *p, long *ifault)*/
/*      ALGORITHM AS241  APPL. STATIST. (1988) VOL. 37, NO. 3

        Produces the normal deviate Z corresponding to a given lower
        tail area of P; Z is accurate to about 1 part in 10**16.
*/
    if (fabs(q) <= .425) {/* |p~ - 0.5| <= .425  <==> 0.075 <= p~ <= 0.925 */
        r = .180625 - q * q; // = .425^2 - q^2  >= 0
	val =
            q * (((((((r * 2509.0809287301226727 +
                       33430.575583588128105) * r + 67265.770927008700853) * r +
                     45921.953931549871457) * r + 13731.693765509461125) * r +
                   1971.5909503065514427) * r + 133.14166789178437745) * r +
                 3.387132872796366608)
            / (((((((r * 5226.495278852854561 +
                     28729.085735721942674) * r + 39307.89580009271061) * r +
                   21213.794301586595867) * r + 5394.1960214247511077) * r +
                 687.1870074920579083) * r + 42.313330701600911252) * r + 1.);
    }
    else { /* closer than 0.075 from {0,1} boundary :
	    *  r := log(p~);  p~ = min(p, 1-p) < 0.075 :  */
	double lp;
	if(log_p && ((lower_tail && q <= 0) || (!lower_tail && q > 0))) {
	    lp = p;
	} else {
	    lp = log( (q > 0) ? R_DT_CIv(p) /* 1-p */ : p_ /* = R_DT_Iv(p) ^=  p */);
	}
	// r = sqrt( - log(min(p,1-p)) )  <==>  min(p, 1-p) = exp( - r^2 ) :
        r = sqrt(-lp);
        if (r <= 5.) { /* <==> min(p,1-p) >= exp(-25) ~= 1.3888e-11 */
            r += -1.6;
            val = (((((((r * 7.7454501427834140764e-4 +
                       .0227238449892691845833) * r + .24178072517745061177) *
                     r + 1.27045825245236838258) * r +
                    3.64784832476320460504) * r + 5.7694972214606914055) *
                  r + 4.6303378461565452959) * r +
                 1.42343711074968357734)
                / (((((((r *
                         1.05075007164441684324e-9 + 5.475938084995344946e-4) *
                        r + .0151986665636164571966) * r +
                       .14810397642748007459) * r + .68976733498510000455) *
                     r + 1.6763848301838038494) * r +
                    2.05319162663775882187) * r + 1.);
        }
	else if(r <= 27) { /* p is very close to  0 or 1: r in (5, 27] */
	    // Wichura, p.478: minimax rational approx R_3(t) is for 5 <= t <= 27  (t :== r)
            r += -5.;
            val = (((((((r * 2.01033439929228813265e-7 +
                       2.71155556874348757815e-5) * r +
                      .0012426609473880784386) * r + .026532189526576123093) *
                    r + .29656057182850489123) * r +
                   1.7848265399172913358) * r + 5.4637849111641143699) *
                 r + 6.6579046435011037772)
                / (((((((r *
                         2.04426310338993978564e-15 + 1.4215117583164458887e-7)*
                        r + 1.8463183175100546818e-5) * r +
                       7.868691311456132591e-4) * r + .0148753612908506148525)
                     * r + .13692988092273580531) * r +
                    .59983220655588793769) * r + 1.);
        }
        else { // r > 27: p is *really* close to 0 or 1 .. practically only when log_p =TRUE
	    if(r >= 6.4e8) { // p is *very extremely* close to 0 or 1
		// Using the asymptotical formula ("0-th order"): qn = sqrt(2*s)
		val = r * M_SQRT2_R;
	    } else {
		double s2 = -ldexp(lp, 1), // = -2*lp = 2s
		    x2 = s2 - log(M_2PI_R * s2); // = xs_1
		// if(r >= 36000.)  # <==> s >= 36000^2   use x2 = xs_1  above
		if(r < 36000.) {
		    x2 = s2 - log(M_2PI_R * x2) - 2./(2. + x2); // == xs_2
		    if(r < 840.) { // 27 < r < 840
			x2 = s2 - log(M_2PI_R * x2) + 2*log1p(- (1 - 1/(4 + x2))/(2. + x2)); // == xs_3
			if(r < 109.) { // 27 < r < 109
			  x2 = s2 - log(M_2PI_R * x2) +
			      2*log1p(- (1 - (1 - 5/(6 + x2))/(4. + x2))/(2. + x2)); // == xs_4
			  if(r < 55.) { // 27 < r < 55
			    x2 = s2 - log(M_2PI_R * x2) +
			      2*log1p(- (1 - (1 - (5 - 9/(8. + x2))/(6. + x2))/(4. + x2))/(2. + x2)); // == xs_5
			  }
			}
		    }
		}
                val = sqrt(x2);
	    }
	}
	if(q < 0.0)
	    val = -val;
    }
    return mu + sigma * val;
}

/* ── src/nmath/snorm.c (N01_kind Inversion) ──────────────────────────────── */

double simlev_rng_norm_rand(void)
{
    double u1;

    /* case INVERSION: */
#define BIG 134217728 /* 2^27 */
	/* unif_rand() alone is not of high enough precision */
	u1 = simlev_rng_unif_rand();
	u1 = (int)(BIG*u1) + simlev_rng_unif_rand();
	return simlev_rng_qnorm5(u1/BIG, 0.0, 1.0, 1, 0);
}

/* ── src/nmath/sexp.c ────────────────────────────────────────────────────── */

double simlev_rng_exp_rand(void)
{
    /* q[k-1] = sum(log(2)^k / k!)  k=1,..,n, */
    /* The highest n (here 16) is determined by q[n-1] = 1.0 */
    /* within standard precision */
    const static double q[] =
    {
	0.6931471805599453,
	0.9333736875190459,
	0.9888777961838675,
	0.9984959252914960,
	0.9998292811061389,
	0.9999833164100727,
	0.9999985691438767,
	0.9999998906925558,
	0.9999999924734159,
	0.9999999995283275,
	0.9999999999728814,
	0.9999999999985598,
	0.9999999999999289,
	0.9999999999999968,
	0.9999999999999999,
	1.0000000000000000
    };

    double a = 0.;
    double u = simlev_rng_unif_rand();    /* precaution if u = 0 is ever returned */
    while(u <= 0. || u >= 1.) u = simlev_rng_unif_rand();
    for (;;) {
	u += u;
	if (u > 1.)
	    break;
	a += q[0];
    }
    u -= 1.;

    if (u <= q[0])
	return a + u;

    int i = 0;
    double ustar = simlev_rng_unif_rand(), umin = ustar;
    do {
	ustar = simlev_rng_unif_rand();
	if (umin > ustar)
	    umin = ustar;
	i++;
    } while (u > q[i]);
    return a + umin * q[0];
}

/* ── src/nmath/runif.c, rnorm.c, rexp.c, rgeom.c ─────────────────────────── */

double simlev_rng_runif(double a, double b)
{
    if (!R_FINITE(a) || !R_FINITE(b) || b < a)	ML_WARN_return_NAN;

    if (a == b)
	return a;
    else {
	double u;
	/* This is true of all builtin generators, but protect against
	   user-supplied ones */
	do {u = simlev_rng_unif_rand();} while (u <= 0 || u >= 1);
	return a + (b - a) * u;
    }
}

double simlev_rng_rnorm(double mu, double sigma)
{
    if (ISNAN(mu) || !R_FINITE(sigma) || sigma < 0.)
	ML_WARN_return_NAN;
    if (sigma == 0. || !R_FINITE(mu))
	return mu; /* includes mu = +/- Inf with finite sigma */
    else
	return mu + sigma * simlev_rng_norm_rand();
}

double simlev_rng_rexp(double scale)
{
    if (!R_FINITE(scale) || scale <= 0.0) {
	if(scale == 0.) return 0.;
	/* else */
	ML_WARN_return_NAN;
    }
    return scale * simlev_rng_exp_rand(); // --> in ./sexp.c
}

double simlev_rng_rgeom(double p)
{
    if (!R_FINITE(p) || p <= 0 || p > 1) ML_WARN_return_NAN;

    return simlev_rng_rpois(simlev_rng_exp_rand() * ((1 - p) / p));
}

/* ── src/nmath/fsign.c ───────────────────────────────────────────────────── */

static double fsign(double x, double y)
{
    if (ISNAN(x) || ISNAN(y))
	return x + y;
    return ((y >= 0) ? fabs(x) : -fabs(x));
}

/* ── src/nmath/rpois.c ───────────────────────────────────────────────────── */

#define a0	-0.5
#define a1	 0.3333333
#define a2	-0.2500068
#define a3	 0.2000118
#define a4	-0.1661269
#define a5	 0.1421878
#define a6	-0.1384794
#define a7	 0.1250060

#define one_7	0.1428571428571428571
#define one_12	0.0833333333333333333
#define one_24	0.0416666666666666667

#define repeat for(;;)

static int imax2(int x, int y) { return (x < y) ? y : x; }
static int imin2(int x, int y) { return (x < y) ? x : y; }

double simlev_rng_rpois(double mu)
{
    /* Factorial Table (0:9)! */
    const static double fact[10] =
    {
	1., 1., 2., 6., 24., 120., 720., 5040., 40320., 362880.
    };

    /* These are static --- persistent between calls for same mu : */
    /* (hier im gebundenen Zustand rs->pois, in Python _RP in simlev._r.rng) */
    simlev_rpois_state *P = rs->pois;
#define l (P->l)
#define m (P->m)
#define b1 (P->b1)
#define b2 (P->b2)
#define c (P->c)
#define c0 (P->c0)
#define c1 (P->c1)
#define c2 (P->c2)
#define c3 (P->c3)
#define pp (P->pp)
#define p0 (P->p0)
#define p (P->p)
#define q (P->q)
#define s (P->s)
#define d (P->d)
#define omega (P->omega)
#define big_l (P->big_l)
#define muprev (P->muprev)
#define muprev2 (P->muprev2)

    /* Local Vars  [initialize some for -Wall]: */
    double del, difmuk= 0., E= 0., fk= 0., fx, fy, g, px, py, t, u= 0., v, x;
    double pois = -1.;
    int k, kflag, big_mu, new_big_mu = 0;

    if (P == NULL) {
	rs->pois_missing = 1;
	return ML_NAN;
    }

    if (!R_FINITE(mu) || mu < 0)
	ML_WARN_return_NAN;

    if (mu <= 0.)
	return 0.;

    big_mu = mu >= 10.;
    if(big_mu)
	new_big_mu = 0;

    if (!(big_mu && mu == muprev)) {/* maybe compute new persistent par.s */

	if (big_mu) {
	    new_big_mu = 1;
	    /* Case A. (recalculation of s,d,l	because mu has changed):
	     * The poisson probabilities pk exceed the discrete normal
	     * probabilities fk whenever k >= m(mu).
	     */
	    muprev = mu;
	    s = sqrt(mu);
	    d = 6. * mu * mu;
	    big_l = floor(mu - 1.1484);
	    /* = an upper bound to m(mu) for all mu >= 10.*/
	}
	else { /* Small mu ( < 10) -- not using normal approx. */

	    /* Case B. (start new table and calculate p0 if necessary) */

	    /*muprev = 0.;-* such that next time, mu != muprev ..*/
	    if (mu != muprev) {
		muprev = mu;
		m = imax2(1, (int) mu);
		l = 0; /* pp[] is already ok up to pp[l] */
		q = p0 = p = exp(-mu);
	    }

	    repeat {
		/* Step U. uniform sample for inversion method */
		u = simlev_rng_unif_rand();
		if (u <= p0)
		    return 0.;

		/* Step T. table comparison until the end pp[l] of the
		   pp-table of cumulative poisson probabilities
		   (0.458 > ~= pp[9](= 0.45792971447) for mu=10 ) */
		if (l != 0) {
		    for (k = (u <= 0.458) ? 1 : imin2(l, m);  k <= l; k++)
			if (u <= pp[k])
			    return (double)k;
		    if (l == 35) /* u > pp[35] */
			continue;
		}
		/* Step C. creation of new poisson
		   probabilities p[l..] and their cumulatives q =: pp[k] */
		l++;
		for (k = l; k <= 35; k++) {
		    p *= mu / k;
		    q += p;
		    pp[k] = q;
		    if (u <= q) {
			l = k;
			return (double)k;
		    }
		}
		l = 35;
	    } /* end(repeat) */
	}/* mu < 10 */

    } /* end {initialize persistent vars} */

/* Only if mu >= 10 : ----------------------- */

    /* Step N. normal sample */
    g = mu + s * simlev_rng_norm_rand();/* norm_rand() ~ N(0,1), standard normal */

    if (g >= 0.) {
	pois = floor(g);
	/* Step I. immediate acceptance if pois is large enough */
	if (pois >= big_l)
	    return pois;
	/* Step S. squeeze acceptance */
	fk = pois;
	difmuk = mu - fk;
	u = simlev_rng_unif_rand(); /* ~ U(0,1) - sample */
	if (d * u >= difmuk * difmuk * difmuk)
	    return pois;
    }

    /* Step P. preparations for steps Q and H.
       (recalculations of parameters if necessary) */

    if (new_big_mu || mu != muprev2) {
        /* Careful! muprev2 is not always == muprev
	   because one might have exited in step I or S
	   */
        muprev2 = mu;
	omega = M_1_SQRT_2PI / s;
	/* The quantities b1, b2, c3, c2, c1, c0 are for the Hermite
	 * approximations to the discrete normal probabilities fk. */

	b1 = one_24 / mu;
	b2 = 0.3 * b1 * b1;
	c3 = one_7 * b1 * b2;
	c2 = b2 - 15. * c3;
	c1 = b1 - 6. * b2 + 45. * c3;
	c0 = 1. - b1 + 3. * b2 - 15. * c3;
	c = 0.1069 / mu; /* guarantees majorization by the 'hat'-function. */
    }

    if (g >= 0.) {
	/* 'Subroutine' F is called (kflag=0 for correct return) */
	kflag = 0;
	goto Step_F;
    }


    repeat {
	/* Step E. Exponential Sample */

	E = simlev_rng_exp_rand();	/* ~ Exp(1) (standard exponential) */

	/*  sample t from the laplace 'hat'
	    (if t <= -0.6744 then pk < fk for all mu >= 10.) */
	u = 2 * simlev_rng_unif_rand() - 1.;
	t = 1.8 + fsign(E, u);
	if (t > -0.6744) {
	    pois = floor(mu + s * t);
	    fk = pois;
	    difmuk = mu - fk;

	    /* 'subroutine' F is called (kflag=1 for correct return) */
	    kflag = 1;

	  Step_F: /* 'subroutine' F : calculation of px,py,fx,fy. */

	    if (pois < 10) { /* use factorials from table fact[] */
		px = -mu;
		py = pow(mu, pois) / fact[(int)pois];
	    }
	    else {
		/* Case pois >= 10 uses polynomial approximation
		   a0-a7 for accuracy when advisable */
		del = one_12 / fk;
		del = del * (1. - 4.8 * del * del);
		v = difmuk / fk;
		if (fabs(v) <= 0.25)
		    px = fk * v * v * (((((((a7 * v + a6) * v + a5) * v + a4) *
					  v + a3) * v + a2) * v + a1) * v + a0)
			- del;
		else /* |v| > 1/4 */
		    px = fk * log(1. + v) - difmuk - del;
		py = M_1_SQRT_2PI / sqrt(fk);
	    }
	    x = (0.5 - difmuk) / s;
	    x *= x;/* x^2 */
	    fx = -0.5 * x;
	    fy = omega * (((c3 * x + c2) * x + c1) * x + c0);
	    if (kflag > 0) {
		/* Step H. Hat acceptance (E is repeated on rejection) */
		if (c * fabs(u) <= py * exp(px + E) - fy * exp(fx + E))
		    break;
	    } else
		/* Step Q. Quotient acceptance (rare case) */
		if (fy - u * fy <= py * exp(px - fx))
		    break;
	}/* t > -.67.. */
    }
    return pois;
#undef l
#undef m
#undef b1
#undef b2
#undef c
#undef c0
#undef c1
#undef c2
#undef c3
#undef pp
#undef p0
#undef p
#undef q
#undef s
#undef d
#undef omega
#undef big_l
#undef muprev
#undef muprev2
}

/* ── src/nmath/dnorm.c ───────────────────────────────────────────────────── */

#define R_D__0	(give_log ? -INFINITY : 0.)		/* 0 */

double simlev_rng_dnorm4(double x, double mu, double sigma, int give_log)
{
    if (ISNAN(x) || ISNAN(mu) || ISNAN(sigma))
	return x + mu + sigma;
    if (sigma < 0) ML_WARN_return_NAN;
    if(!R_FINITE(sigma)) return R_D__0;
    if(!R_FINITE(x) && mu == x) return ML_NAN;/* x-mu is NaN */
    if (sigma == 0)
	return (x == mu) ? ML_POSINF : R_D__0;
    x = (x - mu) / sigma;

    if(!R_FINITE(x)) return R_D__0;

    x = fabs (x);
    if (x >= 2 * sqrt(DBL_MAX)) return R_D__0;
    if (give_log)
	return -(M_LN_SQRT_2PI + 0.5 * x * x + log(sigma));
    //  M_1_SQRT_2PI = 1 / sqrt(2 * pi)
    // more accurate, less fast :
    if (x < 5)    return M_1_SQRT_2PI * exp(-0.5 * x * x) / sigma;

    /* ELSE: (Morten Welinder's proposal for PR#15620, siehe R's dnorm.c) */
    if (x > sqrt(-2*M_LN2_R*(DBL_MIN_EXP + 1-DBL_MANT_DIG))) return 0.;

    /* Now, to get full accuracy, split x into two parts,
     *  x = x1+x2, such that |x2| <= 2^-16. */
    double x1 = //  R_forceint(x * 65536) / 65536 =
	ldexp( R_forceint(ldexp(x, 16)), -16);
    double x2 = x - x1;
    return M_1_SQRT_2PI / sigma *
	(exp(-0.5 * x1 * x1) * exp( (-0.5 * x2 - x1) * x2 ) );
}
