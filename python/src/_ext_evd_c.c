/*
 * python/src/_ext_evd_c.c -- C-Teil der Python-Huelle von nlgpd (evd 2.3-7.1, simlev._ext)
 *
 * Etappe 7.3a. Bindet den gemeinsamen Kern vendor_evd_impl.h (Byte-fuer-Byte-Kopie von
 * r/src/vendor_evd_impl.h) als C ein, wie src/vendor_evd.c in R, und stellt dessen
 * beiden Host-Aufrufe:
 *   SIMLEV_EVD_ALLOC(n)   Arbeitsfeld (vorab in simlev_py_evd_nlgpd angelegt, statt R_alloc)
 *   SIMLEV_EVD_POW(x, y)  R_pow aus R 4.3.3 (src/main/arithmetic.c), mit pow aus der libm
 *                         wie R unter Linux
 */
#include <math.h>
#include <stdlib.h>

static double *evd_work = NULL;

/* R_pow (R 4.3.3): Sonderfaelle wie in R, sonst pow */
static double simlev_r_pow(double x, double y)
{
    if (y == 2.0) return x * x;
    if (x == 1. || y == 0.) return 1.;
    if (x == 0.) {
        if (y > 0.) return 0.;
        else if (y < 0) return INFINITY;
        else return y;
    }
    if (isfinite(x) && isfinite(y)) return pow(x, y);
    if (isnan(x) || isnan(y)) return x + y;
    if (!isfinite(x)) {
        if (x > 0) return (y < 0.) ? 0. : INFINITY;
        else {
            if (isfinite(y) && y == floor(y))
                return (y < 0.) ? 0. : (fmod(y, 2.) != 0 ? x : -x);
        }
    }
    if (!isfinite(y)) {
        if (x >= 0) {
            if (y > 0) return (x >= 1) ? INFINITY : 0.;
            else return (x < 1) ? INFINITY : 0.;
        }
    }
    return NAN;
}

#define SIMLEV_EVD_ALLOC(n) evd_work
#define SIMLEV_EVD_POW(x, y) simlev_r_pow(x, y)
#include "vendor_evd_impl.h"

/* nlgpd auf data (wird ueberschrieben, Kopie vom Aufrufer); 0 = Speicher fehlt */
int simlev_py_evd_nlgpd(double *data, int n, double loc, double scale, double shape, double *dns)
{
    evd_work = (double *) malloc((size_t) (n > 0 ? n : 1) * sizeof(double));
    if (!evd_work) return 0;
    *dns = 0.0;
    evd_nlgpd(data, &n, &loc, &scale, &shape, dns);
    free(evd_work);
    evd_work = NULL;
    return 1;
}
