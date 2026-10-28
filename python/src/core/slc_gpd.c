/* core/slc_gpd.c – verallgemeinerte Pareto-Verteilung: Punktschätzer der Überschreitungen
 *                  (SimLev core, Etappe 9.4)
 * Verfahren:  Überschreitungen x_i >= 0 einer Schwelle mit Dichte
 *             sigma^-1 (1 + xi x / sigma)^(-1/xi - 1) (Pickands 1975; Davison, Smith 1990),
 *             Träger 1 + xi x_i / sigma > 0, sonst NLL = +Inf.
 *             NLL = n log sigma + sum (log1p(xi y_i) + log1p(xi y_i) / xi), y = x / sigma,
 *             kompensiert summiert (Neumaier 1974). log1p ist relativ genau, die Division durch xi
 *             daher für jedes xi != 0 ohne Auslöschung; für |xi| < 1e-8 und |xi y| < 1e-4 wird
 *             log1p(t)/xi über die Reihe y (1 - t/2 + t^2/3 - t^3/4) mit t = xi y gerechnet
 *             (Grenzfall exponentiell bei xi = 0, Fehler < t^4/5).
 *             ML in theta = (log sigma, xi) mit dem projizierten BFGS (slc_opt.c) und numerischem
 *             Gradienten, xi in [-0.999, 10], log sigma frei. Für xi < -1 ist die Likelihood
 *             unbeschränkt; endet die Suche an der Grenze -0.999 (oder 10), ist das SL_ECONV und
 *             der Aufrufer fällt zurück (.fit_tail: Momente).
 *             Startwerte in dieser Reihenfolge (der erste mit endlicher NLL im Kasten):
 *               1. wahrscheinlichkeitsgewichtete Momente nach Hosking, Wallis (1987), Abschnitt 4,
 *                  mit deren Vorzeichen k = -xi: a0 = mean(x), a1 = n^-1 sum (1 - p_i) x_(i) mit
 *                  der Plotting-Position p_i = (i - 0.35)/n, k = a0/(a0 - 2 a1) - 2,
 *                  sigma = 2 a0 a1 / (a0 - 2 a1) (aus E[X (1 - F)^s] = sigma / ((s+1)(s+1+k)),
 *                  selbst nachgerechnet);
 *               2. der Momentenschätzer, den .fit_tail als Rückfall nutzt (eigener SimLev-Code,
 *                  r/R/bootstrap.R): r = m^2/v, xi = max(-0.5, min(1, (1 - r)/2)),
 *                  sigma = max(1e-3, m (1 + r)/2);
 *               3. (sigma, xi) = (sd, 0.1).
 *             Ein eindimensionales Verfahren nach Grimshaw (1993) bleibt als Reserve vermerkt und
 *             ist nicht gebaut. Nur Punktschätzer (F4), keine Standardfehler.
 * Quellen:    Pickands, J. (1975). Statistical inference using extreme order statistics. The
 *               Annals of Statistics 3(1), 119–131.
 *             Davison, A. C., Smith, R. L. (1990). Models for exceedances over high thresholds.
 *               Journal of the Royal Statistical Society, Series B 52(3), 393–442.
 *             Hosking, J. R. M., Wallis, J. R. (1987). Parameter and quantile estimation for the
 *               generalized Pareto distribution. Technometrics 29(3), 339–349.
 *             Neumaier, A. (1974). Rundungsfehleranalyse einiger Verfahren zur Summation endlicher
 *               Summen. ZAMM 54(1), 39–51.
 *             Bertsekas, D. P. (1982); Kelley, C. T. (1999) (projizierter BFGS, über slc_opt.c).
 *             Eigener SimLev-Code: .fit_tail aus r/R/bootstrap.R (Momentenschätzer).
 * Konstanten: keine; Verfahrensparameter (eigene Wahl, SPEZ-9 B.12): Kasten [-0.999, 10],
 *             maxit 500, reltol 1e-12, Plotting-Position nach Hosking, Wallis (1987).
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen (evd nicht
 *             gelesen).
 * Prüforakel: evd 2.3-7.1 fpot (nur Plausibilität, scratchpad/e94/).
 */
#include "slc_internal.h"
#include "slc_la_internal.h"
#include "slc_opt.h"

#include <stdlib.h>
#include <string.h>

#define GPD_XI_LO (-0.999)
#define GPD_XI_HI 10.0

static double gpd_nll_raw(int n, const double *x, double sigma, double xi)
{
    slc_acc a;
    int i;
    double tot;
    if (!(sigma > 0.0) || !isfinite(sigma) || !isfinite(xi)) return INFINITY;
    slc_acc_init(&a, 0.0);
    for (i = 0; i < n; i++) {
        const double y = x[i] / sigma, t = xi * y;
        double l1, q;
        if (!(1.0 + t > 0.0)) return INFINITY;
        l1 = log1p(t);
        if (xi == 0.0 || (fabs(xi) < 1e-8 && fabs(t) < 1e-4))
            q = y * (1.0 - t * (1.0 / 2.0 - t * (1.0 / 3.0 - t / 4.0)));
        else
            q = l1 / xi;
        slc_acc_add(&a, l1 + q);
    }
    tot = (double) n * log(sigma) + slc_acc_val(&a);
    return isfinite(tot) ? tot : INFINITY;
}

static int check_exc(sl_ctx *cx, int n, const double *x, int nmin)
{
    int i;
    if (n < nmin || x == NULL)
        return sl_fail(cx, SL_ESMALL, "GPD: zu wenige Überschreitungen (n = %d, mindestens %d)", n, nmin);
    for (i = 0; i < n; i++) {
        if (!isfinite(x[i])) return sl_fail(cx, SL_ENONFINITE, "GPD: Überschreitungen enthalten nicht endliche Werte");
        if (x[i] < 0.0) return sl_fail(cx, SL_EARG, "GPD: Überschreitungen müssen >= 0 sein");
    }
    return SL_OK;
}

int sl_gpd_nll(sl_ctx *cx, int n, const double *x, double scale, double shape, double *nll)
{
    int st = check_exc(cx, n, x, 1);
    if (st != SL_OK) return st;
    *nll = gpd_nll_raw(n, x, scale, shape);
    return SL_OK;
}

/* PWM-Schätzer; 0 = ok, -1 = nicht bestimmbar */
static int pwm_raw(int n, const double *x, double *sigma, double *xi)
{
    int64_t *idx, *wk;
    slc_acc s0, s1;
    double a0, a1, d;
    int i;
    idx = (int64_t *) malloc(2 * (size_t) n * sizeof(int64_t));
    if (idx == NULL) return -2;
    wk = idx + n;
    slc_sort_index(n, x, idx, wk);
    slc_acc_init(&s0, 0.0); slc_acc_init(&s1, 0.0);
    for (i = 0; i < n; i++) {
        const double xi_ = x[idx[i]];
        slc_acc_add(&s0, xi_);
        slc_acc_add(&s1, (1.0 - ((double) (i + 1) - 0.35) / n) * xi_);
    }
    free(idx);
    a0 = slc_acc_val(&s0) / n;
    a1 = slc_acc_val(&s1) / n;
    d = a0 - 2.0 * a1;
    if (!(d > 0.0) || !(a0 > 0.0) || !(a1 > 0.0)) return -1;
    *xi = -(a0 / d - 2.0);
    *sigma = 2.0 * a0 * a1 / d;
    if (!isfinite(*xi) || !(*sigma > 0.0) || !isfinite(*sigma)) return -1;
    return 0;
}

int sl_gpd_pwm(sl_ctx *cx, int n, const double *x, double *scale, double *shape)
{
    int st = check_exc(cx, n, x, 2), r;
    if (st != SL_OK) return st;
    r = pwm_raw(n, x, scale, shape);
    if (r == -2) return sl_fail(cx, SL_ENOMEM, "GPD: kein Speicher");
    if (r != 0) return sl_fail(cx, SL_EARG, "GPD: wahrscheinlichkeitsgewichtete Momente nicht bestimmbar");
    return SL_OK;
}

typedef struct { int n; const double *x; } gpd_data;

static double gpd_obj(const double *th, void *data)
{
    const gpd_data *d = (const gpd_data *) data;
    return gpd_nll_raw(d->n, d->x, exp(th[0]), th[1]);
}

static int start_ok(int n, const double *x, double sigma, double xi)
{
    return sigma > 0.0 && isfinite(sigma) && xi > GPD_XI_LO && xi < GPD_XI_HI &&
           isfinite(gpd_nll_raw(n, x, sigma, xi));
}

int sl_gpd_fit(sl_ctx *cx, int n, const double *x, const sl_opt_ctrl *ctrl, double *scale,
               double *shape, double *loglik, int *code)
{
    gpd_data d;
    sl_opt_ctrl c;
    slc_acc a;
    double sg, xs, m, v, th[2], lo[2], hi[2], fmin;
    int st, i, iter, nfev, r, found = 0;
    st = check_exc(cx, n, x, 10);
    if (st != SL_OK) return st;
    slc_acc_init(&a, 0.0);
    for (i = 0; i < n; i++) slc_acc_add(&a, x[i]);
    m = slc_acc_val(&a) / n;
    slc_acc_init(&a, 0.0);
    for (i = 0; i < n; i++) { double q = x[i] - m; slc_acc_add(&a, q * q); }
    v = slc_acc_val(&a) / (n - 1);
    if (!(m > 0.0)) return sl_fail(cx, SL_EARG, "GPD: alle Überschreitungen sind 0");
    /* 1. PWM */
    r = pwm_raw(n, x, &sg, &xs);
    if (r == -2) return sl_fail(cx, SL_ENOMEM, "GPD: kein Speicher");
    if (r == 0 && start_ok(n, x, sg, xs)) found = 1;
    /* 2. Momente wie .fit_tail */
    if (!found && v > 0.0) {
        double ratio = m * m / v;
        xs = 0.5 * (1.0 - ratio);
        if (xs > 1.0) xs = 1.0;
        if (xs < -0.5) xs = -0.5;
        sg = 0.5 * m * (1.0 + ratio);
        if (sg < 1e-3) sg = 1e-3;
        if (start_ok(n, x, sg, xs)) found = 1;
    }
    /* 3. (sd, 0.1) */
    if (!found) {
        sg = v > 0.0 ? sqrt(v) : m;
        xs = 0.1;
        if (start_ok(n, x, sg, xs)) found = 1;
    }
    if (!found) return sl_fail(cx, SL_ENONFINITE, "GPD: Log-Likelihood an allen Startwerten nicht endlich");
    d.n = n; d.x = x;
    th[0] = log(sg); th[1] = xs;
    lo[0] = -INFINITY; lo[1] = GPD_XI_LO;
    hi[0] = INFINITY; hi[1] = GPD_XI_HI;
    if (ctrl) c = *ctrl;
    else { sl_opt_ctrl_default(&c, SL_OPT_PBFGS); c.maxit = 500; c.reltol = 1e-12; }
    st = sl_minimize(cx, SL_OPT_PBFGS, 2, th, lo, hi, &c, gpd_obj, NULL, &d, &fmin, code, &iter, &nfev);
    if (st != SL_OK) return st;
    if (!isfinite(fmin)) return sl_fail(cx, SL_ECONV, "GPD: Log-Likelihood nicht endlich (Code %d)", *code);
    *scale = exp(th[0]);
    *shape = th[1];
    *loglik = -fmin;
    if (th[1] <= GPD_XI_LO + 1e-6)
        return sl_fail(cx, SL_ECONV, "GPD: Formparameter an der Untergrenze -0.999 (Likelihood unbeschränkt)");
    if (th[1] >= GPD_XI_HI - 1e-6)
        return sl_fail(cx, SL_ECONV, "GPD: Formparameter an der Obergrenze 10");
    return SL_OK;
}
