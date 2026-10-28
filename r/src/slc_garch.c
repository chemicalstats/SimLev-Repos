/* core/slc_garch.c – GARCH(1,1) und GJR-GARCH(1,1) mit Normalverteilung (SimLev core, Etappe 9.4)
 * Verfahren:  Modell e_t = mu + eps_t, eps_t = sigma_t z_t, z_t ~ N(0, 1),
 *             sigma_t^2 = omega + (alpha + gamma 1{eps_{t-1} < 0}) eps_{t-1}^2 + beta sigma_{t-1}^2
 *             (Bollerslev 1986; GJR: Glosten, Jagannathan, Runkle 1993), Start sigma_1^2 =
 *             Stichprobenvarianz von e (eigene Wahl wie h1 im eigenen MS-GARCH, SPEZ-9 B.10).
 *             Punktschätzer per Maximum Likelihood, NLL = 1/2 sum (log 2 pi + log sigma_t^2 +
 *             eps_t^2 / sigma_t^2), kompensiert summiert (Neumaier 1974). Parameter ohne
 *             Nebenbedingungen über die Umparametrisierung des eigenen MS-GARCH mit einem Regime
 *             (SimLev r/R/ms_garch.R, .ms_garch_unpack): mu frei, omega = exp(theta_omega),
 *             sGARCH (alpha, beta) = exp(a, b) / (1 + Summe); GJR (N1) (alpha/2, (alpha + gamma)/2,
 *             beta) = exp(a, g, b) / (1 + Summe). Damit gelten omega, alpha, beta > 0, bei GJR
 *             alpha + gamma > 0 (gamma < 0 zulässig; bis 1.0.0 (alpha, gamma/2, beta), also
 *             gamma >= 0, F9) und alpha + gamma/2 + beta < 1 von selbst: Das Bild ist genau das
 *             Innere des Bereichs, in dem die bedingte Varianz für jedes Vorzeichen von eps
 *             positiv bleibt und das Modell unter der Normalverteilung (E 1{eps < 0} = 1/2)
 *             stationär ist (Glosten, Jagannathan, Runkle 1993).
 *             Startwerte: mu = Mittelwert, festes Raster (alpha, gamma, beta) wie in .ms_garch_fit
 *             (sGARCH drei Punkte; GJR seit N1 sieben: die drei bisherigen, zwei mit gamma < 0,
 *             zwei mit kleinem beta), omega über Varianz-Targeting. sGARCH: genommen wird der
 *             Rasterpunkt mit der kleinsten NLL, bei Gleichstand der erste. GJR (N1): BFGS von
 *             jedem Rasterpunkt, der beste Lauf gewinnt, bei Gleichstand der erste. Optimierung mit
 *             BFGS (slc_opt.c, sl_minimize) und numerischem Gradienten; mu in Einheiten der
 *             Standardabweichung (parscale), damit die Hesse-Matrix gut skaliert ist.
 *             Filter: wie der frühere eigene Kern garch_filter (bis 1.0.0): s2[0] =
 *             s2_init, Rekursion wie oben, Untergrenze 1e-14.
 *             Ganze Stufe sl_garch11_estimate wie die eigene R-Funktion .fit_garch11
 *             (r/R/bootstrap.R) ohne die Übernahme: Varianz < 1e-16 "konstant", sonst ML,
 *             Rückfall Momente (F10, ohne Nelder-Mead-Stufe), Filter, standardisierte Residuen.
 *             Nur Punktschätzer (F4): keine Standardfehler, keine Hesse-Matrix.
 * Quellen:    Bollerslev, T. (1986). Generalized autoregressive conditional heteroskedasticity.
 *               Journal of Econometrics 31(3), 307–327.
 *             Glosten, L. R., Jagannathan, R., Runkle, D. E. (1993). On the relation between the
 *               expected value and the volatility of the nominal excess return on stocks. The
 *               Journal of Finance 48(5), 1779–1801.
 *             Neumaier, A. (1974). Rundungsfehleranalyse einiger Verfahren zur Summation endlicher
 *               Summen. ZAMM 54(1), 39–51.
 *             Nocedal, J., Wright, S. J. (2006). Numerical Optimization, 2. Aufl., Springer
 *               (BFGS, über slc_opt.c).
 *             Eigener SimLev-Code: .ms_garch_unpack/.ms_garch_pack und das Raster aus
 *               r/R/ms_garch.R, .fit_garch11 aus r/R/bootstrap.R (bis zur Grenze des
 *               rugarch-Aufrufs), früher garch_filter (bis 1.0.0).
 * Konstanten: ln(2 pi) aus slc_constants.h (gen_constants.py). Verfahrensparameter (eigene Wahl,
 *             SPEZ-9 B.10): Raster wie .ms_garch_fit (GJR ergänzt in N1), maxit 500, reltol 1e-10,
 *             Momente alpha 0.08, beta 0.88, gamma 0.04 wie .fit_garch11.
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen (rugarch,
 *             Rsolnp nicht gelesen).
 * Prüforakel: rugarch 1.5-6 ugarchfit (nur Plausibilität, scratchpad/e94/, N1: scratchpad/en1/).
 */
#include "slc_internal.h"
#include "slc_la_internal.h"
#include "slc_opt.h"
#include "slc_constants.h"

#include <stdlib.h>
#include <string.h>

#define GARCH_FLOOR 1e-14

/* Raster (alpha, gamma, beta) wie in .ms_garch_fit */
static const double grid_s[3][3] = {{0.05, 0.0, 0.90}, {0.10, 0.0, 0.85}, {0.03, 0.0, 0.95}};
/* N1: GJR zusätzlich mit gamma < 0 (alpha + gamma > 0) und mit kleinem beta (fast unabhängige Reihen:
 * dort liegt das Optimum oft bei beta -> 0); die drei bisherigen Punkte zuerst. BFGS läuft bei GJR von
 * jedem Rasterpunkt (siehe sl_garch11_fit). */
#define GRID_NG 7
static const double grid_g[GRID_NG][3] = {{0.03, 0.06, 0.90}, {0.05, 0.10, 0.82}, {0.02, 0.04, 0.94},
                                          {0.06, -0.03, 0.90}, {0.12, -0.05, 0.80},
                                          {0.02, 0.06, 0.50}, {0.05, 0.05, 0.10}};

/* ── Hilfen ── */

static double mean_c(int n, const double *x)
{
    slc_acc a;
    int i;
    slc_acc_init(&a, 0.0);
    for (i = 0; i < n; i++) slc_acc_add(&a, x[i]);
    return slc_acc_val(&a) / n;
}

/* Stichprobenvarianz (Nenner n - 1), zwei Durchgänge, kompensiert */
static double var_c(int n, const double *x, double m)
{
    slc_acc a;
    int i;
    if (n < 2) return NAN;
    slc_acc_init(&a, 0.0);
    for (i = 0; i < n; i++) { double d = x[i] - m; slc_acc_add(&a, d * d); }
    return slc_acc_val(&a) / (n - 1);
}

static int check_series(sl_ctx *cx, int n, const double *e, int nmin, const char *who)
{
    if (n < nmin || e == NULL)
        return sl_fail(cx, SL_ESMALL, "%s: zu wenige Beobachtungen (n = %d, mindestens %d)", who, n, nmin);
    if (!slc_all_finite(n, e))
        return sl_fail(cx, SL_ENONFINITE, "%s: Reihe enthält nicht endliche Werte", who);
    return SL_OK;
}

/* ── Filter ── */

int sl_garch11_filter(sl_ctx *cx, int n, const double *eps, double omega, double alpha, double beta,
                      double gamma, double s2_init, double *s2)
{
    double v = s2_init;
    int t;
    if (n < 0) return sl_fail(cx, SL_EARG, "garch11_filter: n < 0");
    for (t = 0; t < n; t++) {
        s2[t] = v;
        v = omega + (alpha + gamma * (eps[t] < 0.0 ? 1.0 : 0.0)) * (eps[t] * eps[t]) + beta * v;
        if (v < GARCH_FLOOR) v = GARCH_FLOOR;
        SL_POLL(cx, t);
    }
    return SL_OK;
}

/* ── Umparametrisierung ── */

int sl_garch11_npar(int gjr) { return gjr ? 5 : 4; }

void sl_garch11_unpack(int gjr, const double *th, double *par)
{
    par[0] = th[0];
    par[1] = exp(th[1]);
    if (gjr) {
        /* N1: (alpha/2, (alpha + gamma)/2, beta) = exp(a, g, b) / (1 + Summe); gamma < 0 zulässig,
         * solange alpha + gamma > 0 (bis 1.0.0: (alpha, gamma/2, beta), also gamma >= 0, F9) */
        double e1 = exp(th[2]), e2 = exp(th[3]), e3 = exp(th[4]);
        double d = 1.0 + ((e1 + e2) + e3);
        par[2] = 2.0 * e1 / d; par[4] = 2.0 * (e2 - e1) / d; par[3] = e3 / d;
    } else {
        double e1 = exp(th[2]), e2 = exp(th[3]);
        double d = 1.0 + (e1 + e2);
        par[2] = e1 / d; par[3] = e2 / d; par[4] = 0.0;
    }
}

int sl_garch11_pack(sl_ctx *cx, int gjr, const double *par, double *th)
{
    double om = par[1], al = par[2], be = par[3], ga = gjr ? par[4] : 0.0;
    double r = 1.0 - al - ga / 2.0 - be;
    if (!isfinite(par[0]) || !(om > 0.0) || !(al > 0.0) || !(be > 0.0) || (gjr && !(al + ga > 0.0)) || !(r > 0.0) ||
        !isfinite(om))
        return sl_fail(cx, SL_EARG, "garch11_pack: Parameter außerhalb des Bereichs (omega, alpha, beta > 0, alpha + gamma > 0, Persistenz < 1)");
    th[0] = par[0];
    th[1] = log(om);
    if (gjr) { th[2] = log((al / 2.0) / r); th[3] = log(((al + ga) / 2.0) / r); th[4] = log(be / r); }   /* N1 */
    else { th[2] = log(al / r); th[3] = log(be / r); }
    return SL_OK;
}

/* ── Likelihood ── */

/* NLL an par (mu, omega, alpha, beta, gamma); nicht endlich -> +Inf */
static double nll_par(int n, const double *e, const double *par, double s2_init)
{
    const double mu = par[0], om = par[1], al = par[2], be = par[3], ga = par[4];
    double v = s2_init, tot;
    slc_acc a;
    int t;
    if (!isfinite(mu) || !isfinite(om) || !isfinite(al) || !isfinite(be) || !isfinite(ga)) return INFINITY;
    slc_acc_init(&a, 0.0);
    for (t = 0; t < n; t++) {
        const double ep = e[t] - mu;
        slc_acc_add(&a, log(v) + (ep * ep) / v);
        v = om + (al + ga * (ep < 0.0 ? 1.0 : 0.0)) * (ep * ep) + be * v;
        if (v < GARCH_FLOOR) v = GARCH_FLOOR;
    }
    tot = 0.5 * ((double) n * SLC_LN_2PI + slc_acc_val(&a));
    return isfinite(tot) ? tot : INFINITY;
}

int sl_garch11_nll(sl_ctx *cx, int n, const double *e, int gjr, const double *par, double s2_init,
                   double *nll)
{
    double p[5];
    int st = check_series(cx, n, e, 1, "garch11_nll");
    if (st != SL_OK) return st;
    memcpy(p, par, 4 * sizeof(double));
    p[4] = gjr ? par[4] : 0.0;
    if (isnan(s2_init)) s2_init = var_c(n, e, mean_c(n, e));
    *nll = nll_par(n, e, p, s2_init);
    return SL_OK;
}

typedef struct { int n, gjr; const double *e; double s2_init; } garch_data;

static double garch_obj(const double *th, void *data)
{
    const garch_data *d = (const garch_data *) data;
    double par[5];
    sl_garch11_unpack(d->gjr, th, par);
    return nll_par(d->n, d->e, par, d->s2_init);
}

/* ── ML-Schätzung ── */

/* N1: GJR – BFGS von jedem Rasterpunkt mit endlicher NLL (Varianz-Targeting wie bei sGARCH), der beste
 * Lauf gewinnt, bei Gleichstand der erste. Von nur einem Start (dem besten Rasterpunkt) blieb BFGS im
 * erweiterten Bereich (gamma < 0) auf fast unabhängigen Reihen an der Grenze beta -> 1 hängen, während
 * das Optimum bei beta -> 0 lag (scratchpad/en1/). */
static int fit_gjr(sl_ctx *cx, garch_data *d, double m, double v, const sl_opt_ctrl *ctrl, double *par,
                   double *loglik, int *code)
{
    sl_opt_ctrl c;
    double ths[GRID_NG][5], fs[GRID_NG], th[5], best_th[5], best = INFINITY, ps[5], fmin;
    int i, st, iter, nfev, cd, have = 0, any = 0;
    for (i = 0; i < GRID_NG; i++) {
        double p[5];
        p[0] = m;
        p[1] = v * (1.0 - grid_g[i][0] - grid_g[i][1] / 2.0 - grid_g[i][2]);
        p[2] = grid_g[i][0]; p[3] = grid_g[i][2]; p[4] = grid_g[i][1];
        if (sl_garch11_pack(cx, 1, p, ths[i]) != SL_OK) return cx->status;
        fs[i] = garch_obj(ths[i], d);
        if (isfinite(fs[i])) any = 1;
    }
    if (!any) return sl_fail(cx, SL_ENONFINITE, "GARCH: Log-Likelihood an allen Startwerten nicht endlich");
    if (ctrl) c = *ctrl;
    else { sl_opt_ctrl_default(&c, SL_OPT_BFGS); c.maxit = 500; c.reltol = 1e-10; }
    if (c.parscale == NULL) {
        ps[0] = sqrt(v);
        for (i = 1; i < 5; i++) ps[i] = 1.0;
        c.parscale = ps;
    }
    *code = -1;
    for (i = 0; i < GRID_NG; i++) {
        if (!isfinite(fs[i])) continue;
        memcpy(th, ths[i], sizeof th);
        st = sl_minimize(cx, SL_OPT_BFGS, 5, th, NULL, NULL, &c, garch_obj, NULL, d, &fmin, &cd, &iter, &nfev);
        if (st != SL_OK) return st;
        if (!have || fmin < best) { memcpy(best_th, th, sizeof th); best = fmin; *code = cd; have = 1; }
    }
    if (!isfinite(best)) return sl_fail(cx, SL_ECONV, "GARCH: Log-Likelihood nicht endlich (Code %d)", *code);
    sl_garch11_unpack(1, best_th, par);
    *loglik = -best;
    return SL_OK;
}

int sl_garch11_fit(sl_ctx *cx, int n, const double *e, int gjr, const sl_opt_ctrl *ctrl,
                   double *par, double *loglik, int *code)
{
    garch_data d;
    sl_opt_ctrl c;
    double m, v, th[5], best_th[5], best = INFINITY, ps[5], fmin, g[5];
    int i, np = sl_garch11_npar(gjr), st, iter, nfev, have = 0;
    const double (*grid)[3] = gjr ? grid_g : grid_s;
    st = check_series(cx, n, e, 10, "GARCH");
    if (st != SL_OK) return st;
    m = mean_c(n, e);
    v = var_c(n, e, m);
    if (!(v > 0.0) || !isfinite(v)) return sl_fail(cx, SL_EARG, "GARCH: Varianz der Reihe ist 0");
    d.n = n; d.gjr = gjr; d.e = e; d.s2_init = v;
    if (gjr) return fit_gjr(cx, &d, m, v, ctrl, par, loglik, code);   /* N1 */
    /* Raster mit Varianz-Targeting; kleinste NLL, bei Gleichstand der erste Punkt */
    for (i = 0; i < 3; i++) {
        double p[5], f;
        p[0] = m;
        p[1] = v * (1.0 - grid[i][0] - grid[i][1] / 2.0 - grid[i][2]);
        p[2] = grid[i][0]; p[3] = grid[i][2]; p[4] = grid[i][1];
        if (sl_garch11_pack(cx, gjr, p, th) != SL_OK) return cx->status;
        f = garch_obj(th, &d);
        if (!have || f < best) { memcpy(best_th, th, (size_t) np * sizeof(double)); best = f; have = 1; }
    }
    if (!isfinite(best)) return sl_fail(cx, SL_ENONFINITE, "GARCH: Log-Likelihood an allen Startwerten nicht endlich");
    if (ctrl) c = *ctrl;
    else { sl_opt_ctrl_default(&c, SL_OPT_BFGS); c.maxit = 500; c.reltol = 1e-10; }
    if (c.parscale == NULL) {
        ps[0] = sqrt(v);
        for (i = 1; i < np; i++) ps[i] = 1.0;
        c.parscale = ps;
    }
    st = sl_minimize(cx, SL_OPT_BFGS, np, best_th, NULL, NULL, &c, garch_obj, NULL, &d,
                     &fmin, code, &iter, &nfev);
    if (st != SL_OK) return st;
    if (!isfinite(fmin)) return sl_fail(cx, SL_ECONV, "GARCH: Log-Likelihood nicht endlich (Code %d)", *code);
    sl_garch11_unpack(gjr, best_th, g);
    memcpy(par, g, 5 * sizeof(double));
    *loglik = -fmin;
    return SL_OK;
}

/* ── ganze Stufe wie .fit_garch11 ── */

int sl_garch11_estimate(sl_ctx *cx, int n, const double *e, int gjr, double *par, double *loglik,
                        int *code, int *method, double *s2, double *z, double *s2_init,
                        double *persistence)
{
    double mu, sv, om, al, be, ga, v0, mz, sz, pers;
    double *eps;
    int t, st;
    st = check_series(cx, n, e, 2, "GARCH");
    if (st != SL_OK) return st;
    mu = mean_c(n, e);
    sv = var_c(n, e, mu);
    *loglik = NAN; *code = -1;
    if (sv < 1e-16) {
        par[0] = mu; par[1] = 1e-20; par[2] = 0.0; par[3] = 0.0; par[4] = 0.0;
        for (t = 0; t < n; t++) { s2[t] = 1e-20; z[t] = 0.0; }
        *method = SL_GARCH_KONSTANT; *s2_init = 1e-20; *persistence = 0.0;
        return SL_OK;
    }
    {
        sl_ctx c2;
        double p[5], ll;
        int cd;
        sl_ctx_init(&c2);
        c2.interrupted = cx->interrupted; c2.host = cx->host;
        st = sl_garch11_fit(&c2, n, e, gjr, NULL, p, &ll, &cd);
        if (st == SL_EINTR) return sl_fail(cx, SL_EINTR, "%s", c2.msg);
        if (st == SL_OK && isfinite(ll) && slc_all_finite(5, p)) {
            memcpy(par, p, 5 * sizeof(double));
            *loglik = ll; *code = cd; *method = SL_GARCH_ML;
        } else {
            par[0] = mu; par[2] = 0.08; par[3] = 0.88; par[4] = gjr ? 0.04 : 0.0;
            par[1] = sv * (1.0 - par[2] - par[3] - par[4] / 2.0);
            *method = SL_GARCH_MOMENTE;
        }
    }
    mu = par[0]; om = par[1]; al = par[2]; be = par[3]; ga = par[4];
    eps = (double *) malloc((size_t) n * sizeof(double));
    if (eps == NULL) return sl_fail(cx, SL_ENOMEM, "GARCH: kein Speicher");
    for (t = 0; t < n; t++) eps[t] = e[t] - mu;
    v0 = 1.0 - al - be - ga / 2.0;
    if (!(v0 > 1e-6)) v0 = 1e-6;
    v0 = om / v0;
    st = sl_garch11_filter(cx, n, eps, om, al, be, ga, v0, s2);
    if (st != SL_OK) { free(eps); return st; }
    for (t = 0; t < n; t++) {
        z[t] = eps[t] / sqrt(s2[t]);
        if (!isfinite(z[t])) z[t] = 0.0;
    }
    free(eps);
    mz = mean_c(n, z);
    sz = sqrt(var_c(n, z, mz));
    if (sz > 0.0) for (t = 0; t < n; t++) z[t] = (z[t] - mz) / sz;
    pers = al + be + ga / 2.0;
    *persistence = pers;
    *s2_init = pers < 0.9999 ? om / (1.0 - pers) : sv;
    return SL_OK;
}
