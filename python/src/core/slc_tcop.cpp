/* core/slc_tcop.cpp – Profil-Likelihood der t-Copula (SimLev core, seit 1.6.0)
 * Verfahren:  Bivariat (copula_fit, dependence_analysis): für festes nu hängt die Log-Likelihood nur über
 *             x = qt(u, nu), y = qt(v, nu) von nu ab; Maximum in rho über th = atanh rho in [-20, 20] mit Brent
 *             (tol 1e-10); Raster nu = 2 + 2^k, k = -4 ... 12, und nu = Inf (Gauss-Copula); um den besten
 *             Rasterpunkt Brent in log(nu - 2) zwischen den Nachbarn (unten bis 2^-4 e^-30, tol 1e-6), am oberen
 *             Ende in s = 1/nu auf [0, 1/(2 + 2^11)] (tol 1e-9). Ergebnis: bester ausgewerteter Punkt
 *             (atanh rho, nu, -loglik). Dichteteile je Beobachtung
 *               Gauss: -1/2 log(1 - r^2) - (r^2 (x^2 + y^2) - 2 r x y) / (2 (1 - r^2)),
 *               t: c0 - 1/2 log(1 - r^2) - (nu + 2)/2 log1p((x^2 - 2 r x y + y^2) / (nu (1 - r^2)))
 *                  + (nu + 1)/2 (log1p(x^2/nu) + log1p(y^2/nu)),
 *             seit 1.6.2 log(1 - r^2) als log1p(-r^2) (r^2 < 1/2) bzw. log((1 - r)(1 + r)) und 1 - r^2 als (1 - r)(1 + r),
 *             c0 = lgamma((nu + 2)/2) + lgamma(nu/2) - 2 lgamma((nu + 1)/2), für nu > 64 die Stirling-Reihe mit
 *             Bernoulli-Polynomen 1/(4a) - 1/(96 a^3) + 1/(320 a^5) - 17/(7168 a^7) + 31/(9216 a^9), a = nu/2.
 *             Mehrdimensional (scenario_copula): nu = argmin -ll(nu) mit Brent auf [lower, upper],
 *             ll(nu) = sum_t [lgamma((nu + k)/2) + (k - 1) lgamma(nu/2) - k lgamma((nu + 1)/2) - 1/2 log det R
 *             - (nu + k)/2 log1p(z_t' R^-1 z_t / nu) + (nu + 1)/2 sum_j log1p(z_tj^2 / nu)], z = qt(U, nu).
 *             Rechenfolge wie SimLev 1.5.2 in R (r/R/dependence.R .cop_fit_t, r/R/scenarios.R ll_t): Summen in
 *             long double (sl_r_sum, sl_r_rowsums), Matrixprodukt sl_matmul, Brent wie stats::optimize
 *             (sl_fmin, danach eine Auswertung am Ergebnis). qt über alle Elemente auf mehreren Threads
 *             (sl_qt_mt). Bis 1.5.2 rechneten R, Python und Julia die Profil-Likelihood je für sich.
 * Quellen:    Demarta, S., McNeil, A. J. (2005). The t Copula and Related Copulas. International Statistical
 *               Review 73(1), 111–129 (Dichte der t-Copula).
 *             Genest, C., Ghoudi, K., Rivest, L.-P. (1995). A semiparametric estimation procedure of dependence
 *               parameters in multivariate families of distributions. Biometrika 82(3), 543–552.
 *             Olver, F. W. J. u. a. (Hrsg.). NIST Digital Library of Mathematical Functions, 5.11.8 (Reihe für c0).
 * Konstanten: Koeffizienten der Reihe für c0 (aus den Bernoulli-Polynomen, siehe r/R/dependence.R .cop_t_c0).
 * Reinraum:   eigener SimLev-Code; kein Code aus R oder Paketen.
 * Prüforakel: R 1.5.2 (/home/claude/rlib152; Gleichlauf: copula_fuzz.R).
 */
#include "slc_internal.h"
#include "slc_opt.h"
#include "slc_prep.h"
#include "slc_rbase.h"

#include <float.h>
#include <stdlib.h>
#include <string.h>

/* stats::optimize ruft f über fcn1: nicht endlich -> DBL_MAX (in R mit Warnung; hier Merker für den Host) */
typedef struct {
    double (*f)(double, void *);
    void *data;
    int *flag;
} fcn1_data;

static double fcn1_(double x, void *p)
{
    fcn1_data *F = (fcn1_data *) p;
    double v = F->f(x, F->data);
    if (!isfinite(v)) { *F->flag = 1; return DBL_MAX; }
    return v;
}

/* optimize(f, c(lo, hi), tol): Brent, danach f am Ergebnis; *obj = dieser Wert */
static double optimize_(double (*f)(double, void *), void *data, double lo, double hi, double tol, int *flag,
                        double *obj)
{
    fcn1_data F = { f, data, flag };
    double x = sl_fmin(lo, hi, fcn1_, &F, tol);
    *obj = f(x, data);
    return x;
}

static double lgamma1_(sl_ctx *cx, double x)
{
    double y;
    sl_lgamma(cx, 1, &x, &y);
    return y;
}

/* ── bivariat ── */

typedef struct {
    sl_ctx *cx;
    int64_t n;
    const double *u, *v;
    double *uv, *xy, *x2, *y2, *B, *terms;
    double nu, c0, best[3];
    int gauss, nthreads, *flag, st;
} cop_t;

static double cop_c0_(sl_ctx *cx, double nu)
{
    double a, ia2;
    if (nu <= 64) return lgamma1_(cx, (nu + 2) / 2) + lgamma1_(cx, nu / 2) - 2 * lgamma1_(cx, (nu + 1) / 2);
    a = nu / 2; ia2 = 1 / (a * a);
    return ((((31.0 / 9216 * ia2 - 17.0 / 7168) * ia2 + 1.0 / 320) * ia2 - 1.0 / 96) * ia2 + 1.0 / 4) / a;
}

/* log(1 - r^2) seit 1.6.2: log1p(-r^2) für r^2 < 1/2, sonst log((1 - r)(1 + r)); höchstens 1,4 ulp (wie .log1mr2) */
static double log1mr2_(double r)
{
    return (r * r < 0.5) ? log1p(-(r * r)) : log((1 - r) * (1 + r));
}

/* g(th) = -sum(ll(tanh th)), nicht endlich -> 1e10 */
static double cop_g_(double th, void *p)
{
    cop_t *C = (cop_t *) p;
    const int64_t n = C->n;
    const double *x = C->xy, *y = C->xy + n, *x2 = C->x2, *y2 = C->y2;
    double r = tanh(th), s, A, D, tr = 2 * r;
    int64_t i;
    if (C->gauss) {
        const double r2 = r * r;
        A = -0.5 * log1mr2_(r);
        D = 2 * ((1 - r) * (1 + r));
        for (i = 0; i < n; i++) C->terms[i] = A - (r2 * (x2[i] + y2[i]) - tr * x[i] * y[i]) / D;
    } else {
        const double E = (C->nu + 2) / 2;
        A = C->c0 - 0.5 * log1mr2_(r);
        D = C->nu * ((1 - r) * (1 + r));
        for (i = 0; i < n; i++) C->terms[i] = A - E * log1p((x2[i] - tr * x[i] * y[i] + y2[i]) / D) + C->B[i];
    }
    s = sl_r_sum(n, C->terms, 0);
    return isfinite(s) ? -s : 1e10;
}

static double cop_prof_(double nu, void *p)
{
    cop_t *C = (cop_t *) p;
    const int64_t n = C->n;
    double mn, ob;
    int64_t i;
    if (C->st != SL_OK) return 0.0;
    C->nu = nu;
    C->gauss = isinf(nu);
    if (C->gauss) {
        C->st = sl_qnorm(C->cx, n, C->u, 0.0, 1.0, 1, C->xy);
        if (C->st == SL_OK) C->st = sl_qnorm(C->cx, n, C->v, 0.0, 1.0, 1, C->xy + n);
    } else C->st = sl_qt_mt(C->cx, 2 * n, C->uv, nu, 1, C->xy, C->nthreads);
    if (C->st != SL_OK) return 0.0;
    for (i = 0; i < n; i++) { C->x2[i] = C->xy[i] * C->xy[i]; C->y2[i] = C->xy[n + i] * C->xy[n + i]; }
    if (!C->gauss) {
        const double h = (nu + 1) / 2;
        for (i = 0; i < n; i++) C->B[i] = h * (log1p(C->x2[i] / nu) + log1p(C->y2[i] / nu));
        C->c0 = cop_c0_(C->cx, nu);
    }
    mn = optimize_(cop_g_, C, -20, 20, 1e-10, C->flag, &ob);
    if (ob < C->best[2]) { C->best[0] = mn; C->best[1] = nu; C->best[2] = ob; }
    return ob;
}

static double cop_inv_(double s, void *p) { return cop_prof_(s == 0 ? INFINITY : 1 / s, p); }
static double cop_exp_(double t2, void *p) { return cop_prof_(2 + exp(t2), p); }

int sl_tcop_fit(sl_ctx *cx, int64_t n, const double *u, const double *v, int nthreads, double *best, int *flag)
{
    cop_t C;
    double nus[18], f[18], ob, lo;
    int K = 18, k, i;
    *flag = 0;
    if (n < 1) return sl_fail(cx, SL_EARG, "tcop_fit: keine Beobachtungen");
    memset(&C, 0, sizeof C);
    C.cx = cx; C.n = n; C.u = u; C.v = v; C.nthreads = nthreads; C.flag = flag; C.st = SL_OK;
    C.best[0] = 0; C.best[1] = INFINITY; C.best[2] = INFINITY;
    C.uv = (double *) malloc(sizeof(double) * (size_t) (7 * n));
    if (!C.uv) return sl_fail(cx, SL_ENOMEM, "tcop_fit: kein Speicher");
    C.xy = C.uv + 2 * n; C.x2 = C.xy + 2 * n; C.y2 = C.x2 + n; C.B = C.y2 + n;
    C.terms = (double *) malloc(sizeof(double) * (size_t) n);
    if (!C.terms) { free(C.uv); return sl_fail(cx, SL_ENOMEM, "tcop_fit: kein Speicher"); }
    memcpy(C.uv, u, sizeof(double) * (size_t) n);
    memcpy(C.uv + n, v, sizeof(double) * (size_t) n);
    for (i = 0; i < K - 1; i++) nus[i] = 2 + ldexp(1.0, i - 4);
    nus[K - 1] = INFINITY;
    for (i = 0; i < K; i++) f[i] = cop_prof_(nus[i], &C);
    k = 0;
    for (i = 1; i < K; i++) if (f[i] < f[k]) k = i;   /* which.min (erster) */
    if (k + 1 >= K - 1) {
        optimize_(cop_inv_, &C, 0, 1 / nus[K - 3], 1e-9, flag, &ob);
    } else {
        lo = k == 0 ? log(nus[0] - 2) - 30 : log(nus[k - 1] - 2);
        optimize_(cop_exp_, &C, lo, log(nus[k + 1] - 2), 1e-6, flag, &ob);
    }
    free(C.uv); free(C.terms);
    if (C.st != SL_OK) return C.st;
    if (cx->n_warn > 0) *flag = 1;
    memcpy(best, C.best, sizeof C.best);
    return SL_OK;
}

/* ── mehrdimensional (scenario_copula) ── */

typedef struct {
    sl_ctx *cx;
    int64_t Tn;
    int k, nthreads, st;
    const double *U, *Ri;
    double ldR, *Z, *M, *q, *rs, *terms;
} nu_t;

/* -ll_t(nu) */
static double nu_f_(double nu, void *p)
{
    nu_t *N = (nu_t *) p;
    const int64_t Tn = N->Tn, m = Tn * N->k;
    const int k = N->k;
    double c0, E, F, s;
    int64_t i;
    if (N->st != SL_OK) return 0.0;
    N->st = sl_qt_mt(N->cx, m, N->U, nu, 1, N->Z, N->nthreads);
    if (N->st != SL_OK) return 0.0;
    sl_matmul((int) Tn, k, k, N->Z, N->Ri, N->M);
    for (i = 0; i < m; i++) N->M[i] = N->M[i] * N->Z[i];
    if (sl_r_rowsums(Tn, k, N->M, 0, 0, N->q) != SL_OK) { N->st = sl_fail(N->cx, SL_ENOMEM, "tcop_nu: kein Speicher"); return 0.0; }
    for (i = 0; i < m; i++) N->M[i] = log1p(N->Z[i] * N->Z[i] / nu);
    if (sl_r_rowsums(Tn, k, N->M, 0, 0, N->rs) != SL_OK) { N->st = sl_fail(N->cx, SL_ENOMEM, "tcop_nu: kein Speicher"); return 0.0; }
    c0 = lgamma1_(N->cx, (nu + k) / 2) + (k - 1) * lgamma1_(N->cx, nu / 2) - k * lgamma1_(N->cx, (nu + 1) / 2) - 0.5 * N->ldR;
    E = (nu + k) / 2; F = (nu + 1) / 2;
    for (i = 0; i < Tn; i++) N->terms[i] = c0 - E * log1p(N->q[i] / nu) + F * N->rs[i];
    s = sl_r_sum(Tn, N->terms, 0);
    return -s;
}

int sl_tcop_nu(sl_ctx *cx, int64_t Tn, int k, const double *U, const double *Ri, double ldR, double lower,
               double upper, double tol, int nthreads, double *nu, int *flag)
{
    nu_t N;
    double ob;
    const int64_t m = Tn * (int64_t) k;
    *flag = 0;
    if (Tn < 1 || k < 1) return sl_fail(cx, SL_EARG, "tcop_nu: leere Eingabe");
    memset(&N, 0, sizeof N);
    N.cx = cx; N.Tn = Tn; N.k = k; N.nthreads = nthreads; N.U = U; N.Ri = Ri; N.ldR = ldR; N.st = SL_OK;
    N.Z = (double *) malloc(sizeof(double) * (size_t) (2 * m + 3 * Tn));
    if (!N.Z) return sl_fail(cx, SL_ENOMEM, "tcop_nu: kein Speicher");
    N.M = N.Z + m; N.q = N.M + m; N.rs = N.q + Tn; N.terms = N.rs + Tn;
    *nu = optimize_(nu_f_, &N, lower, upper, tol, flag, &ob);
    if (!isfinite(ob)) *flag = 1;
    free(N.Z);
    if (N.st != SL_OK) return N.st;
    if (cx->n_warn > 0) *flag = 1;
    return SL_OK;
}
