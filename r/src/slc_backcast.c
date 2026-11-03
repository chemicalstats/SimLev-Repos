/* core/slc_backcast.c – Zielfunktion und Fit von backcast_fit (SimLev core)
 * Verfahren:  Zielfunktion der eigenen R-Funktion backcast_fit (r/R/backcast.R: .bc_model_returns,
 *             .bc_errors, .bc_loss, .bc_objective) für die Fits mit mehreren Parametern, dort
 *             bisher über .sl_optim(method = "L-BFGS-B") mit Rückfragen an den Host und
 *             numerischem Gradienten. Mit theta = (drag, spread, beta) (Prozent p. a. bzw. Faktor):
 *               r_t  = ((beta L) x_t + c1_t) - c2_t - spread sp_t - drag dr_t   (Strukturmodell),
 *               r_t  = c1_t - spread sp_t - drag dr_t                         (Regression; c1 = Basis),
 *               rr_t = r_t, rr_1 = 0, nicht endlich -> 0,
 *               ls_t = sum_{s <= t} log1p(max(rr_s, -0.999999)),
 *               e_lvl_j = (ls(p_j) - ls(p_1)) - (lp_j - lp_1),
 *               e_ret_j = (ls(p_{j+h}) - ls(p_j)) - (lp_{j+h} - lp_j)   (h = horizon),
 *             Verlust rmse, mse, mae, median (der Beträge) oder max über die endlichen Fehler
 *             (keiner: +Inf), hybrid sqrt(w mean(e_ret^2) + (1 - w) mean(e_lvl^2)).
 *             Summen, kumulierte Summe und Mittel kompensiert (Neumaier 1974) in double statt der
 *             long-double-Summen von R; der Wert weicht daher von R in den letzten Stellen ab.
 *             Gradient analytisch (Kettenregel): d ls_t / d theta_k = sum_{s <= t} u_ks / (1 + rr_s)
 *             mit u_drag = -dr, u_spread = -sp, u_beta = L x (0 für s = 1, nicht endliche rr_s und
 *             rr_s < -0.999999); dF = sum_j q_j de_j mit q = e / (n F) (rmse), 2 e / n (mse),
 *             w e_ret / (n_ret F) bzw. (1 - w) e_lvl / (n_lvl F) (hybrid). Für mae, median und max
 *             ist F nicht überall differenzierbar (Knicke bei e_j = 0 bzw. bei Gleichstand); der
 *             Fit nimmt dort wie bisher zentrale Differenzen (in C), sl_backcast_obj gibt
 *             den Gradienten des aktiven Zweigs (sign(e_j) / n bzw. sign(e_k) an den Rangstellen).
 *             backcast_fit ruft sl_backcast_fit nur für rmse, mse und hybrid; für mae, median und max
 *             bleibt dort .sl_optim mit der Zielfunktion des Hosts (Ergebnisse wie 1.1.0): Mit der
 *             C-Zielfunktion lagen die Optima bei mae je nach Rundung der Summen bis 9e-9 relativ
 *             besser oder schlechter, mit dem Gradienten des aktiven Zweigs bei median und max bis
 *             zum Faktor 4 schlechter.
 *             Fit: projizierter BFGS (slc_opt.c) mit den Steuerwerten von .sl_optim für
 *             "L-BFGS-B" (maxit 100, reltol 1e7 eps, gtol 1e-8, xtol eps), Start und Schranken
 *             wie in backcast_fit.
 * Quellen:    Nocedal, J., Wright, S. J. (2006). Numerical Optimization, 2. Aufl., Springer
 *               (über slc_opt.c). Neumaier, A. (1974). Rundungsfehleranalyse einiger Verfahren zur
 *               Summation endlicher Summen. ZAMM 54(1), 39–51.
 *             Eigener SimLev-Code: backcast_fit und Helfer (r/R/backcast.R).
 * Konstanten: keine; -0.999999 wie .bc_errors.
 * Reinraum:   geschrieben nur nach den genannten Quellen und dem eigenen SimLev-Code; kein Code
 *             und keine Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: backcast_fit aus SimLev 1.1.0 (R, .sl_optim).
 */
#include "slc_internal.h"
#include "slc_la_internal.h"
#include "slc_opt.h"

#include <stdlib.h>
#include <string.h>

#define BC_FLOOR (-0.999999)

typedef struct {
    int m, nobs, objective, loss, horizon, nfit, fit[3];
    const double *x, *c1, *c2, *sp, *dr, *logp;
    const int32_t *pos;
    double lev, hw, par[3];
    double *rr, *w, *D, *e, *q, *a;   /* Arbeitsfelder */
} bc_prob;

static int cmp_abs(const void *pa, const void *pb)
{
    const double x = *(const double *) pa, y = *(const double *) pb;
    return (x > y) - (x < y);
}

/* Verlust über e[0..L) (nur endliche Werte); q (L Werte, darf NULL sein): dF/de_j */
static double bc_loss(int loss, int L, const double *e, double *q, double *a)
{
    slc_acc s;
    int i, n = 0;
    double v;
    for (i = 0; i < L; i++) if (isfinite(e[i])) n++;
    if (q) for (i = 0; i < L; i++) q[i] = 0.0;
    if (n == 0) return INFINITY;
    slc_acc_init(&s, 0.0);
    switch (loss) {
    case 1: case 2:
        for (i = 0; i < L; i++) if (isfinite(e[i])) slc_acc_add(&s, e[i] * e[i]);
        v = slc_acc_val(&s) / n;
        if (loss == 1) {
            v = sqrt(v);
            if (q && v > 0.0) for (i = 0; i < L; i++) if (isfinite(e[i])) q[i] = e[i] / (n * v);
        } else if (q) {
            for (i = 0; i < L; i++) if (isfinite(e[i])) q[i] = 2.0 * e[i] / n;
        }
        return v;
    case 3:
        for (i = 0; i < L; i++) if (isfinite(e[i])) {
            slc_acc_add(&s, fabs(e[i]));
            if (q) q[i] = (double) ((e[i] > 0.0) - (e[i] < 0.0)) / n;
        }
        return slc_acc_val(&s) / n;
    case 4: {
        int j = 0, lo, hi;
        double mlo, mhi;
        for (i = 0; i < L; i++) if (isfinite(e[i])) a[j++] = fabs(e[i]);
        qsort(a, (size_t) n, sizeof(double), cmp_abs);
        lo = (n - 1) / 2; hi = n / 2;
        mlo = a[lo]; mhi = a[hi];
        v = (lo == hi) ? mlo : 0.5 * (mlo + mhi);
        if (q) {   /* aktiver Zweig: erste Fehler mit dem Betrag der Rangstellen */
            int dl = 0, dh = (lo == hi);
            for (i = 0; i < L && !(dl && dh); i++) if (isfinite(e[i])) {
                const double ae = fabs(e[i]), sg = (double) ((e[i] > 0.0) - (e[i] < 0.0));
                if (!dl && ae == mlo) { q[i] += (lo == hi ? 1.0 : 0.5) * sg; dl = 1; }
                else if (!dh && ae == mhi) { q[i] += 0.5 * sg; dh = 1; }
            }
        }
        return v;
    }
    default: {
        int im = -1;
        v = -1.0;
        for (i = 0; i < L; i++) if (isfinite(e[i]) && fabs(e[i]) > v) { v = fabs(e[i]); im = i; }
        if (q && im >= 0) q[im] = (double) ((e[im] > 0.0) - (e[im] < 0.0));
        return v;
    }
    }
}

/* Wert und (g != NULL) Gradient nach den nfit gefitteten Parametern */
static double bc_fg(bc_prob *p, const double *th, double *g)
{
    const int m = p->m, no = p->nobs, h = p->horizon, nf = p->nfit;
    double par[3], *rr = p->rr, *w = p->w, *D = p->D, *e = p->e, *q = p->q, val;
    slc_acc ls;
    int t, j, k, o, L;
    memcpy(par, p->par, sizeof par);
    for (k = 0; k < nf; k++) par[p->fit[k]] = th[k];
    for (t = 0; t < m; t++) {
        double r;
        if (p->x) r = ((par[2] * p->lev) * p->x[t] + p->c1[t]) - (p->c2 ? p->c2[t] : 0.0);
        else r = p->c1[t];
        r = (r - par[1] * p->sp[t]) - par[0] * p->dr[t];
        if (t == 0 || !isfinite(r)) { rr[t] = 0.0; w[t] = 0.0; }
        else if (r < BC_FLOOR) { rr[t] = BC_FLOOR; w[t] = 0.0; }
        else { rr[t] = r; w[t] = 1.0 / (1.0 + r); }
    }
    /* kumulierte Summe an den Beobachtungen; Ableitungen nur dort gespeichert (D[k * no + j]) */
    {
        double dk[3] = {0.0, 0.0, 0.0};
        slc_acc_init(&ls, 0.0);
        for (t = 0, o = 0; t < m && o < no; t++) {
            slc_acc_add(&ls, log1p(rr[t]));
            if (g && w[t] != 0.0) for (k = 0; k < nf; k++) {
                const int c = p->fit[k];
                const double u = c == 0 ? -p->dr[t] : c == 1 ? -p->sp[t] : p->lev * p->x[t];
                dk[k] += u * w[t];
            }
            while (o < no && p->pos[o] - 1 == t) {
                p->a[o] = slc_acc_val(&ls);
                if (g) for (k = 0; k < nf; k++) D[k * no + o] = dk[k];
                o++;
            }
        }
    }
    /* Fehler; e und q: zuerst Niveau (no Werte), dann Rendite (no - h Werte) */
    L = 0;
    if (p->objective != 2) {
        for (j = 0; j < no; j++) e[j] = (p->a[j] - p->a[0]) - (p->logp[j] - p->logp[0]);
        L = no;
    }
    if (p->objective != 1 && no > h)
        for (j = 0; j < no - h; j++) e[L + j] = (p->a[j + h] - p->a[j]) - (p->logp[j + h] - p->logp[j]);
    if (p->objective != 3) {
        const int n = p->objective == 1 ? no : (no > h ? no - h : 0);
        double *qq = g ? q : NULL;
        val = bc_loss(p->loss, n, e, qq, p->a + no);
        if (g) {
            for (k = 0; k < nf; k++) {
                slc_acc s;
                slc_acc_init(&s, 0.0);
                for (j = 0; j < n; j++) if (q[j] != 0.0) {
                    const double de = p->objective == 1 ? D[k * no + j] - D[k * no]
                                                         : D[k * no + j + h] - D[k * no + j];
                    slc_acc_add(&s, q[j] * de);
                }
                g[k] = slc_acc_val(&s);
            }
        }
    } else {
        const int nr = no > h ? no - h : 0;
        slc_acc sa, sb;
        double A, B;
        slc_acc_init(&sa, 0.0); slc_acc_init(&sb, 0.0);
        for (j = 0; j < nr; j++) slc_acc_add(&sa, e[no + j] * e[no + j]);
        for (j = 0; j < no; j++) slc_acc_add(&sb, e[j] * e[j]);
        A = nr ? slc_acc_val(&sa) / nr : NAN;          /* mean(numeric(0)) = NaN wie in R */
        B = slc_acc_val(&sb) / no;
        val = sqrt(p->hw * A + (1.0 - p->hw) * B);
        if (g) for (k = 0; k < nf; k++) {
            slc_acc s;
            slc_acc_init(&s, 0.0);
            if (val > 0.0 && isfinite(val)) {
                for (j = 0; j < no; j++) slc_acc_add(&s, (1.0 - p->hw) * e[j] / (no * val) * (D[k * no + j] - D[k * no]));
                for (j = 0; j < nr; j++) slc_acc_add(&s, p->hw * e[no + j] / (nr * val) * (D[k * no + j + h] - D[k * no + j]));
            }
            g[k] = slc_acc_val(&s);
        }
    }
    if (!isfinite(val)) {
        if (g) for (k = 0; k < nf; k++) g[k] = NAN;
        return isnan(val) ? val : INFINITY;
    }
    return val;
}

static int bc_setup(sl_ctx *cx, bc_prob *p, int m, const double *x, const double *c1, const double *c2, double lev,
                    const double *sp, const double *dr, int nobs, const int32_t *pos, const double *logp,
                    int objective, int loss, int horizon, double hw, const double *par, int nfit,
                    const int32_t *fit)
{
    int j, k;
    if (m < 1 || nobs < 1 || c1 == NULL || sp == NULL || dr == NULL || pos == NULL || logp == NULL || par == NULL)
        return sl_fail(cx, SL_EARG, "backcast: leere Eingabe");
    if (objective < 1 || objective > 3 || loss < 1 || loss > 5)
        return sl_fail(cx, SL_EARG, "backcast: objective (1 bis 3) oder loss (1 bis 5) ungültig");
    if (horizon < 1) return sl_fail(cx, SL_EARG, "backcast: horizon muss >= 1 sein");
    if (nfit < 0 || nfit > 3 || (nfit > 0 && fit == NULL)) return sl_fail(cx, SL_EARG, "backcast: 0 bis 3 Parameter");
    for (j = 0; j < nobs; j++)
        if (pos[j] < 1 || pos[j] > m || (j > 0 && pos[j] <= pos[j - 1]))
            return sl_fail(cx, SL_EARG, "backcast: Beobachtungspositionen müssen aufsteigend in 1..%d liegen", m);
    for (k = 0; k < nfit; k++) {
        if (fit[k] < 1 || fit[k] > 3) return sl_fail(cx, SL_EARG, "backcast: Parameterindex %d ungültig (1 drag, 2 spread, 3 beta)", fit[k]);
        if (fit[k] == 3 && x == NULL) return sl_fail(cx, SL_EARG, "backcast: beta nur im Strukturmodell");
        for (j = 0; j < k; j++) if (fit[j] == fit[k]) return sl_fail(cx, SL_EARG, "backcast: Parameter doppelt");
    }
    memset(p, 0, sizeof *p);
    p->m = m; p->nobs = nobs; p->objective = objective; p->loss = loss; p->horizon = horizon; p->nfit = nfit;
    for (k = 0; k < nfit; k++) p->fit[k] = fit[k] - 1;
    p->x = x; p->c1 = c1; p->c2 = c2; p->sp = sp; p->dr = dr; p->logp = logp; p->pos = pos;
    p->lev = lev; p->hw = hw;
    for (k = 0; k < 3; k++) p->par[k] = par[k];
    p->rr = (double *) malloc(((size_t) 2 * m + (size_t) (3 + 2 + 2 + 3) * nobs) * sizeof(double));
    if (p->rr == NULL) return sl_fail(cx, SL_ENOMEM, "backcast: kein Speicher");
    p->w = p->rr + m; p->D = p->w + m; p->e = p->D + 3 * (size_t) nobs; p->q = p->e + 2 * (size_t) nobs;
    p->a = p->q + 2 * (size_t) nobs;   /* nobs Werte ls an den Beobachtungen, dahinter 2 nobs für median */
    return SL_OK;
}

int sl_backcast_obj(sl_ctx *cx, int m, const double *x, const double *c1, const double *c2, double lev,
                    const double *sp, const double *dr, int nobs, const int32_t *pos, const double *logp,
                    int objective, int loss, int horizon, double hw, const double *par, int nfit,
                    const int32_t *fit, double *f, double *g)
{
    bc_prob p;
    double th[3];
    int k, st = bc_setup(cx, &p, m, x, c1, c2, lev, sp, dr, nobs, pos, logp, objective, loss, horizon, hw, par,
                         nfit, fit);
    if (st != SL_OK) return st;
    for (k = 0; k < nfit; k++) th[k] = par[fit[k] - 1];
    *f = bc_fg(&p, th, (g && nfit > 0) ? g : NULL);
    free(p.rr);
    return SL_OK;
}

typedef struct { bc_prob *p; double xc[3], gc[3]; int have, use_g; } bc_data;

static double bc_obj(const double *th, void *data)
{
    bc_data *d = (bc_data *) data;
    double f;
    if (!d->use_g) return bc_fg(d->p, th, NULL);
    f = bc_fg(d->p, th, d->gc);
    memcpy(d->xc, th, (size_t) d->p->nfit * sizeof(double));
    d->have = 1;
    return f;
}

static void bc_gr(const double *th, double *g, void *data)
{
    bc_data *d = (bc_data *) data;
    const size_t sz = (size_t) d->p->nfit * sizeof(double);
    if (d->have && memcmp(d->xc, th, sz) == 0) memcpy(g, d->gc, sz);
    else (void) bc_fg(d->p, th, g);
}

int sl_backcast_fit(sl_ctx *cx, int m, const double *x, const double *c1, const double *c2, double lev,
                    const double *sp, const double *dr, int nobs, const int32_t *pos, const double *logp,
                    int objective, int loss, int horizon, double hw, const double *par0, int nfit,
                    const int32_t *fit, const double *lo, const double *hi, const struct sl_opt_ctrl *ctrl,
                    double *par, double *value, int *code)
{
    bc_prob p;
    bc_data d;
    sl_opt_ctrl c;
    double th[3], fmin;
    int k, st, iter, nfev;
    if (nfit < 1) return sl_fail(cx, SL_EARG, "backcast: mindestens ein Parameter");
    if (lo == NULL || hi == NULL) return sl_fail(cx, SL_EARG, "backcast: Schranken fehlen");
    st = bc_setup(cx, &p, m, x, c1, c2, lev, sp, dr, nobs, pos, logp, objective, loss, horizon, hw, par0, nfit, fit);
    if (st != SL_OK) return st;
    for (k = 0; k < nfit; k++) th[k] = par0[fit[k] - 1];
    d.p = &p; d.have = 0;
    d.use_g = (objective == 3 || loss <= 2);    /* glatte Verluste: analytisch; sonst Differenzen */
    if (ctrl) c = *ctrl;
    else { sl_opt_ctrl_default(&c, SL_OPT_PBFGS); c.maxit = 100; c.reltol = 1e7 * 2.220446049250313080847e-16; }
    st = sl_minimize(cx, SL_OPT_PBFGS, nfit, th, lo, hi, &c, bc_obj, d.use_g ? bc_gr : NULL, &d, &fmin, code,
                     &iter, &nfev);
    free(p.rr);
    if (st != SL_OK) return st;
    for (k = 0; k < nfit; k++) par[k] = th[k];
    *value = fmin;
    return SL_OK;
}
