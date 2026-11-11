/* core/slc_gpd.cpp – verallgemeinerte Pareto-Verteilung: Punktschätzer der Überschreitungen
 *                  (SimLev core)
 * Verfahren:  Überschreitungen x_i >= 0 einer Schwelle mit Dichte
 *             sigma^-1 (1 + xi x / sigma)^(-1/xi - 1) (Pickands 1975; Davison, Smith 1990),
 *             Träger 1 + xi x_i / sigma > 0, sonst NLL = +Inf.
 *             NLL = n log sigma + sum (log1p(xi y_i) + log1p(xi y_i) / xi), y = x / sigma,
 *             kompensiert summiert (Neumaier 1974). log1p ist relativ genau, die Division durch xi
 *             daher für jedes xi != 0 ohne Auslöschung; für |xi| < 1e-8 und |xi y| < 1e-4 wird
 *             log1p(t)/xi über die Reihe y (1 - t/2 + t^2/3 - t^3/4) mit t = xi y gerechnet
 *             (Grenzfall exponentiell bei xi = 0, Fehler < t^4/5).
 *             ML in theta = (log sigma, xi) mit dem projizierten BFGS (slc_opt.cpp), xi in
 *             [-0.999, 10], log sigma frei. Analytischer Gradient (geschlossen, gpd_fg; f und g
 *             in einem Durchlauf, Grenzfall xi -> 0 über eine Reihe) statt zentraler Differenzen. Für xi < -1 ist die Likelihood
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
 *             ist nicht gebaut. Nur Punktschätzer, keine Standardfehler.
 * Quellen:    Pickands, J. (1975). Statistical inference using extreme order statistics. The
 *               Annals of Statistics 3(1), 119–131.
 *             Davison, A. C., Smith, R. L. (1990). Models for exceedances over high thresholds.
 *               Journal of the Royal Statistical Society, Series B 52(3), 393–442.
 *             Hosking, J. R. M., Wallis, J. R. (1987). Parameter and quantile estimation for the
 *               generalized Pareto distribution. Technometrics 29(3), 339–349.
 *             Neumaier, A. (1974). Rundungsfehleranalyse einiger Verfahren zur Summation endlicher
 *               Summen. ZAMM 54(1), 39–51.
 *             Bertsekas, D. P. (1982); Kelley, C. T. (1999) (projizierter BFGS, über slc_opt.cpp).
 *             Eigener SimLev-Code: .fit_tail aus r/R/bootstrap.R (Momentenschätzer).
 * Konstanten: keine; Verfahrensparameter (eigene Wahl): Kasten [-0.999, 10],
 *             maxit 500, reltol 1e-12, Plotting-Position nach Hosking, Wallis (1987).
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen (evd nicht
 *             gelesen).
 * Prüforakel: evd 2.3-7.1 fpot (nur Plausibilität).
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

/* NLL und analytischer Gradient in theta = (log sigma, xi) in einem Durchlauf. Der Wert ist
 * Operation für Operation der von gpd_nll_raw (bitgleich). Mit u_i = y_i / (1 + t_i):
 *   d NLL / d log sigma = n - (1 + xi) sum u_i,
 *   d NLL / d xi        = sum [u_i + y_i^2 H(t_i)],  H(t) = (t / (1 + t) - log1p(t)) / t^2,
 * aus d/dxi [(1 + 1/xi) log1p(t)] = (1 + 1/xi) y / (1 + t) - log1p(t) / xi^2
 * = u + (xi u - log1p(t)) / xi^2 mit xi u = t / (1 + t). Für |t| < 1e-3 (auch xi = 0)
 * wird H über die Reihe H(t) = sum_j (-1)^(j+1) (j+1)/(j+2) t^j = -1/2 + 2t/3 - 3t^2/4 + 4t^3/5 - 5t^4/6
 * gerechnet (Abbruchfehler < t^5, relativ < 2e-15), sonst direkt (Auslöschung relativ <= 2 eps / |t|
 * <= 5e-13). Ausserhalb des Trägers (1 + t <= 0) oder bei nicht endlichem Wert: f = +Inf, g = NaN. */
static double gpd_fg(int n, const double *x, const double *th, double *g)
{
    const double sigma = exp(th[0]), xi = th[1];
    slc_acc a, su, sh;
    int i;
    double tot;
    if (!(sigma > 0.0) || !isfinite(sigma) || !isfinite(xi)) goto bad;
    slc_acc_init(&a, 0.0); slc_acc_init(&su, 0.0); slc_acc_init(&sh, 0.0);
    for (i = 0; i < n; i++) {
        const double y = x[i] / sigma, t = xi * y;
        double l1, q, u, hh;
        if (!(1.0 + t > 0.0)) goto bad;
        l1 = log1p(t);
        if (xi == 0.0 || (fabs(xi) < 1e-8 && fabs(t) < 1e-4))
            q = y * (1.0 - t * (1.0 / 2.0 - t * (1.0 / 3.0 - t / 4.0)));
        else
            q = l1 / xi;
        slc_acc_add(&a, l1 + q);
        u = y / (1.0 + t);
        if (fabs(t) < 1e-3)
            hh = y * y * (-1.0 / 2.0 + t * (2.0 / 3.0 - t * (3.0 / 4.0 - t * (4.0 / 5.0 - t * (5.0 / 6.0)))));
        else
            hh = (xi * u - l1) / (xi * xi);
        slc_acc_add(&su, u);
        slc_acc_add(&sh, u + hh);
    }
    tot = (double) n * log(sigma) + slc_acc_val(&a);
    if (!isfinite(tot)) goto bad;
    g[0] = (double) n - (1.0 + xi) * slc_acc_val(&su);
    g[1] = slc_acc_val(&sh);
    return tot;
bad:
    g[0] = g[1] = NAN;
    return INFINITY;
}

typedef struct { int n; const double *x; double xc[2], gc[2]; int have; } gpd_data;

/* f und g aus einem Durchlauf; der Gradient zum zuletzt bewerteten Punkt kommt aus dem Speicher */
static double gpd_obj(const double *th, void *data)
{
    gpd_data *d = (gpd_data *) data;
    double f = gpd_fg(d->n, d->x, th, d->gc);
    d->xc[0] = th[0]; d->xc[1] = th[1];
    d->have = 1;
    return f;
}

static void gpd_gr(const double *th, double *g, void *data)
{
    gpd_data *d = (gpd_data *) data;
    if (d->have && memcmp(d->xc, th, 2 * sizeof(double)) == 0) { g[0] = d->gc[0]; g[1] = d->gc[1]; }
    else (void) gpd_fg(d->n, d->x, th, g);
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
    double sg, xs, m, v, th[2], lo[2], hi[2], fmin;
    int st, iter, nfev, r, found = 0;
    st = check_exc(cx, n, x, 10);
    if (st != SL_OK) return st;
    m = slc_mean(n, x);                     /* n >= 10 (check_exc) */
    v = slc_var_m(n, x, m);
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
    d.n = n; d.x = x; d.have = 0;
    th[0] = log(sg); th[1] = xs;
    lo[0] = -INFINITY; lo[1] = GPD_XI_LO;
    hi[0] = INFINITY; hi[1] = GPD_XI_HI;
    if (ctrl) c = *ctrl;
    else { sl_opt_ctrl_default(&c, SL_OPT_PBFGS); c.maxit = 500; c.reltol = 1e-12; }
    st = sl_minimize(cx, SL_OPT_PBFGS, 2, th, lo, hi, &c, gpd_obj, gpd_gr, &d, &fmin, code, &iter, &nfev);
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
