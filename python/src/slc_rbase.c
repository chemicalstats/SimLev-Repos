/* core/slc_rbase.c – Summen, Mittel, Varianz, Kumulationen und Potenz mit R-Regeln (SimLev core)
 * Verfahren:  sequenzielle Akkumulation in long double in der Reihenfolge der Elemente, wie R sie
 *             für sum, prod, mean, var, cumsum, cumprod, rowSums/colSums dokumentiert ("accumulated
 *             in long double where available", ?sum, ?cumsum, ?colSums):
 *             - sum/prod: Summe bzw. Produkt in long double; liegt sie jenseits ±DBL_MAX, ±Inf,
 *               sonst auf double gerundet.
 *             - mean: Summe/n in long double, danach ein Korrekturdurchlauf s + Σ(x_i − s)/n
 *               (?mean: "the mean is computed in long double with a second pass"); ist die erste
 *               Summe nicht endlich, wird Σ(x_i/n) gebildet (Logik der Ports rnum.r_mean).
 *             - var: Mittel wie oben, als double gespeichert, dann Σ(x_i − m)²/(n − 1) in long double.
 *             - cumsum/cumprod: laufende Summe/Produkt in long double, je Schritt auf double gerundet;
 *               ab dem ersten NaN steht NA, sobald ein NA vorkam, sonst NaN (?cumsum: "An NA value
 *               in x causes the corresponding and following elements of the return value to be NA,
 *               as does integer overflow"; Logik der Ports `_handle_nan`).
 *             - cummax/cummin: in double, ab dem ersten NaN wie cumsum.
 *             - colSums/colMeans je Spalte wie sum; rowSums/rowMeans mit einem long-double-Akkumulator
 *               je Zeile, spaltenweise aufaddiert; Mittel durch die Anzahl (bei narm je Zeile).
 *             - pow: R's ^ für Doubles: y == 2 → x·x, x == 1 oder y == 0 → 1, sonst libm pow mit
 *               R's Randfällen (?Arithmetic: 1^y und y^0 sind 1, auch für NA/NaN).
 *             - zeroin2: Brent-Verfahren (inverse quadratische bzw. lineare Interpolation mit
 *               Bisektion als Rückfall) wie R_zeroin2 hinter stats::uniroot, Schritt für Schritt in derselben
 *               Rechenfolge.
 *             Leere Eingabe: mean ist 0/0 in long double (NaN mit gesetztem Vorzeichenbit wie in R).
 *             NaN-Ergebnisse (welche Nutzlast bei zwei NaN-Operanden gewinnt) folgen der Hardware
 *             (x87 bei long double), genau wie in R; die Ports bildeten dafür die x87-Regel nach.
 * Quellen:    R-Hilfeseiten (R 4.3.3) wie oben; ISO/IEC 9899:1999 7.12 (math.h), Annex F;
 *             Intel 64 and IA-32 Architectures Software Developer's Manual, Vol. 1, Kap. 8 (x87).
 * Konstanten: DBL_MAX aus <float.h>; NA und NaN als Bitmuster (slc_rbase.h).
 * long double: absichtlich (siehe slc_rbase.h): nur so gleich zu R auf derselben Plattform.
 * Herkunft:           übersetzt aus R 4.3.3, src/main/summary.c, cum.c (handleNaN), array.c,
 *                     arithmetic.c (R_POW), src/library/stats/src/zeroin.c (R_zeroin2; dort: aus Netlib
 *                     c/brent.shar, Brents Prozedur zero, R. P. Brent, Algorithms for Minimization without
 *                     Derivatives, 1973), über die Port-Funktionen python/simlev/_r/rnum.py,
 *                     base.py und julia/src/r/rnum.jl (r_zeroin2), base.jl, ld80.jl
 * Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation
 *                     (laut Kopf der jeweiligen R-Quelle)
 * Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
 * Änderungen:         C99 ohne R-Datenstrukturen, gemeinsamer Kern für Python und Julia (nicht Teil
 *                     des R-Pakets); long double nur dort, wo R es nutzt.
 * Prüforakel: R 4.3.3 (Gleichlauf: rbase_fuzz.R).
 */
#include "slc_internal.h"
#include "slc_rbase.h"

#include <float.h>
#include <stdlib.h>
#include <string.h>

typedef long double ldouble;

static double bits_d(uint64_t u)
{
    double d;
    memcpy(&d, &u, sizeof d);
    return d;
}

static int is_na(double x)
{
    uint64_t u;
    if (x == x) return 0;
    memcpy(&u, &x, sizeof u);
    return (u & UINT64_C(0xFFFFFFFF)) == 1954;
}

static double quiet(double x)
{
    uint64_t u;
    memcpy(&u, &x, sizeof u);
    return bits_d(u | UINT64_C(0x0008000000000000));
}

#define R_NA  bits_d(UINT64_C(0x7FF00000000007A2))
#define R_NAN bits_d(UINT64_C(0x7FF8000000000000))

static double ld_to_d_clamped(ldouble s)
{
    if (s > (ldouble) DBL_MAX) return INFINITY;
    if (s < -(ldouble) DBL_MAX) return -INFINITY;
    return (double) s;
}

double sl_r_sum(int64_t n, const double *x, int narm)
{
    ldouble s = 0.0L;
    int64_t i;
    for (i = 0; i < n; i++)
        if (!narm || !isnan(x[i])) s += x[i];
    return ld_to_d_clamped(s);
}

double sl_r_prod(int64_t n, const double *x, int narm)
{
    ldouble s = 1.0L;
    int64_t i;
    for (i = 0; i < n; i++)
        if (!narm || !isnan(x[i])) s *= x[i];
    return ld_to_d_clamped(s);
}

double sl_r_mean(int64_t n, const double *x)
{
    ldouble s = 0.0L, t, ln = (ldouble) n;
    int64_t i;
    int finite_s;
    for (i = 0; i < n; i++) s += x[i];
    finite_s = isfinite((double) s);
    if (finite_s) {
        s /= ln;
    } else {
        s = 0.0L;
        for (i = 0; i < n; i++) s += x[i] / (double) n;
    }
    if (finite_s && isfinite((double) s)) {
        t = 0.0L;
        for (i = 0; i < n; i++) t += (x[i] - s);
        s += t / ln;
    } else if (isfinite((double) s)) {
        t = 0.0L;
        for (i = 0; i < n; i++) t += (x[i] - s) / ln;
        s += t;
    }
    return (double) s;
}

double sl_r_mean_int(int64_t n, const int64_t *x)
{
    ldouble s = 0.0L;
    int64_t i;
    for (i = 0; i < n; i++) s += (ldouble) x[i];
    return (double) (s / (ldouble) n);
}

/* Mittel wie in cov/var: Summe/n, Korrektur nur bei endlichem Zwischenwert; Ergebnis long double */
static ldouble mean_ld(int64_t n, const double *x)
{
    ldouble s = 0.0L, t, ln = (ldouble) n;
    int64_t i;
    for (i = 0; i < n; i++) s += x[i];
    t = s / ln;
    if (isfinite((double) t)) {
        s = 0.0L;
        for (i = 0; i < n; i++) s += (x[i] - t);
        t = t + s / ln;
    }
    return t;
}

double sl_r_var(int64_t n, const double *x)
{
    ldouble s = 0.0L, d, xm;
    int64_t i;
    if (n <= 1) return R_NA;
    xm = (ldouble) (double) mean_ld(n, x);        /* Mittelwert als double gespeichert */
    for (i = 0; i < n; i++) { d = x[i] - xm; s += d * d; }
    return (double) (s / (ldouble) (n - 1));
}

/* ab dem ersten NaN: NA, sobald ein NA vorkam, sonst NaN */
static void handle_nan(int64_t n, const double *x, double *out)
{
    int has_nan = 0, has_na = 0;
    int64_t i;
    for (i = 0; i < n; i++) {
        if (!has_nan && isnan(x[i])) has_nan = 1;
        if (has_nan && !has_na && is_na(x[i])) has_na = 1;
        if (has_na) out[i] = R_NA;
        else if (has_nan) out[i] = R_NAN;
    }
}

void sl_r_cumsum(int64_t n, const double *x, double *out)
{
    ldouble s = 0.0L;
    int64_t i;
    for (i = 0; i < n; i++) { s += x[i]; out[i] = (double) s; }
    if (n > 0 && isnan(out[n - 1])) handle_nan(n, x, out);
}

void sl_r_cumprod(int64_t n, const double *x, double *out)
{
    ldouble s = 1.0L;
    int64_t i;
    for (i = 0; i < n; i++) { s *= x[i]; out[i] = (double) s; }
    if (n > 0 && isnan(out[n - 1])) handle_nan(n, x, out);
}

static void cumext(int64_t n, const double *x, double *out, int max)
{
    double m = max ? -INFINITY : INFINITY;
    int64_t i;
    for (i = 0; i < n; i++) {
        if (isnan(x[i])) { handle_nan(n, x, out); return; }
        if (max ? !(m > x[i]) : !(m < x[i])) m = x[i];
        out[i] = m;
    }
}

void sl_r_cummax(int64_t n, const double *x, double *out) { cumext(n, x, out, 1); }
void sl_r_cummin(int64_t n, const double *x, double *out) { cumext(n, x, out, 0); }

void sl_r_colsums(int64_t nr, int64_t nc, const double *x, int narm, int mean, double *out)
{
    int64_t i, j, cnt;
    for (j = 0; j < nc; j++) {
        const double *c = x + j * nr;
        ldouble s = 0.0L;
        cnt = 0;
        for (i = 0; i < nr; i++)
            if (!narm || !isnan(c[i])) { s += c[i]; cnt++; }
        if (mean && !isnan((double) s)) s /= (ldouble) cnt;
        out[j] = (double) s;
    }
}

int sl_r_rowsums(int64_t nr, int64_t nc, const double *x, int narm, int mean, double *out)
{
    ldouble *acc;
    int64_t *cnt = NULL, i, j;
    acc = (ldouble *) calloc((size_t) (nr > 0 ? nr : 1), sizeof(ldouble));
    if (narm) cnt = (int64_t *) calloc((size_t) (nr > 0 ? nr : 1), sizeof(int64_t));
    if (acc == NULL || (narm && cnt == NULL)) { free(acc); free(cnt); return SL_ENOMEM; }
    for (j = 0; j < nc; j++) {
        const double *c = x + j * nr;
        if (narm) {
            for (i = 0; i < nr; i++)
                if (!isnan(c[i])) { acc[i] += c[i]; cnt[i]++; }
        } else {
            for (i = 0; i < nr; i++) acc[i] += c[i];
        }
    }
    for (i = 0; i < nr; i++) {
        ldouble s = acc[i];
        if (mean) s /= (ldouble) (narm ? cnt[i] : nc);
        out[i] = (double) s;
    }
    free(acc); free(cnt);
    return SL_OK;
}

/* R's x ^ y für Doubles */
static double r_pow1(double x, double y)
{
    if (y == 2.0) return x * x;
    if (x == 1.0 || y == 0.0) return 1.0;
    if (x == 0.0) {
        if (y > 0.0) return 0.0;
        if (y < 0.0) return INFINITY;
        return y;                                   /* NaN */
    }
    if (isfinite(x) && isfinite(y)) return pow(x, y);   /* negative Basis, gebrochener Exponent: NaN von pow */
    if (isnan(y)) return quiet(y);                  /* NaN-Operand: der von y gewinnt, sonst der von x (wie R) */
    if (isnan(x)) return quiet(x);
    if (!isfinite(x)) {
        if (x > 0) return y < 0.0 ? 0.0 : INFINITY;
        if (isfinite(y) && y == floor(y))
            return y < 0.0 ? 0.0 : (fmod(y, 2.0) != 0.0 ? x : -x);
    }
    if (!isfinite(y)) {
        if (x >= 0) {
            if (y > 0) return x >= 1 ? INFINITY : 0.0;
            return x < 1 ? INFINITY : 0.0;
        }
    }
    return R_NAN;
}

double sl_r_pow1(double x, double y) { return r_pow1(x, y); }

void sl_r_pow(int64_t n, const double *x, double y, double *out)
{
    int64_t i;
    if (y == 2.0) {
        for (i = 0; i < n; i++) out[i] = x[i] * x[i];
        return;
    }
    for (i = 0; i < n; i++) out[i] = r_pow1(x[i], y);
}

/* R_zeroin2 (stats/src/zeroin.c) über den Port julia/src/r/rnum.jl (r_zeroin2): a, b Klammer, c Gegenpunkt
 * mit f(c) von anderem Vorzeichen als f(b); je Schritt inverse quadratische (a != c) bzw. lineare
 * Interpolation, wenn sie innerhalb von 3/4 der Klammer und unter der Hälfte des vorletzten Schritts bleibt,
 * sonst Bisektion; Schritte mindestens tol_act = 2 eps |b| + tol/2. Rechenfolge wie R (-ffp-contract=off). */
double sl_r_zeroin2(sl_r_fn1 f, void *info, double ax, double bx, double fa, double fb, double tol, int maxit,
                    int *iter)
{
    double a = ax, b = bx, c = a, fc = fa;
    int maxit_c = maxit + 1;
    if (fa == 0.0) { *iter = 0; return a; }
    if (fb == 0.0) { *iter = 0; return b; }
    while (maxit_c != 0) {
        double prev_step, tol_act, new_step, p, q;
        maxit_c--;
        prev_step = b - a;
        if (fabs(fc) < fabs(fb)) {
            a = b; b = c; c = a;
            fa = fb; fb = fc; fc = fa;
        }
        tol_act = 2 * DBL_EPSILON * fabs(b) + tol / 2;
        new_step = (c - b) / 2;
        if (fabs(new_step) <= tol_act || fb == 0.0) {
            *iter = maxit - maxit_c;
            return b;
        }
        if (fabs(prev_step) >= tol_act && fabs(fa) > fabs(fb)) {
            double t1, cb, t2;
            cb = c - b;
            if (a == c) {
                t1 = fb / fa;
                p = cb * t1;
                q = 1.0 - t1;
            } else {
                q = fa / fc;
                t1 = fb / fc;
                t2 = fb / fa;
                p = t2 * (cb * q * (q - t1) - (b - a) * (t1 - 1.0));
                q = (q - 1.0) * (t1 - 1.0) * (t2 - 1.0);
            }
            if (p > 0.0) q = -q;
            else p = -p;
            if (p < (0.75 * cb * q - fabs(tol_act * q) / 2) && p < fabs(prev_step * q / 2))
                new_step = p / q;
        }
        if (fabs(new_step) < tol_act) new_step = new_step > 0.0 ? tol_act : -tol_act;
        a = b; fa = fb;
        b += new_step;
        fb = f(b, info);
        if ((fb > 0 && fc > 0) || (fb < 0 && fc < 0)) {
            c = a; fc = fa;
        }
    }
    *iter = -1;
    return b;
}
