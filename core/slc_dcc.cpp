/* core/slc_dcc.cpp – DCC(1,1): Filter und Schätzung des Korrelationsteils (SimLev core)
 * Verfahren:  Dynamische bedingte Korrelation nach Engle (2002) auf standardisierten Residuen
 *             z_t (Stufe 1: univariate GARCH, slc_garch.cpp):
 *               Q_t = (1 - a - b) Qbar + a z_{t-1} z_{t-1}' + b Q_{t-1},  Q_1 = Qbar,
 *               R_t = diag(Q_t)^{-1/2} Q_t diag(Q_t)^{-1/2},
 *               -l = 1/2 sum_t (log|R_t| + z_t' R_t^{-1} z_t - z_t' z_t).
 *             Der Filter ist der eigene Kern dcc_filter (r/src/dependence_core_impl.h), Zeile für
 *             Zeile als C-ABI überführt: dieselbe Rechenfolge, dieselbe Cholesky-Zerlegung der
 *             kleinen Matrix (Pivot <= 1e-14: nicht positiv definit -> nll = 1e10, ok = 0,
 *             Korrelationen ab dieser Zeile NA).
 *             Schätzung (Stufe 2) ganz in C über die logistische Abbildung der eigenen R-Funktion
 *             dependence_dcc (r/R/dependence.R): s = 0.999 plogis(th1), a = s plogis(th2), b = s - a
 *             (damit a, b > 0, a + b < 0.999); Start (qlogis(0.98/0.999), qlogis(0.03/0.98)).
 *             Bis 1.1.0 Nelder-Mead (höchstens 2000 Auswertungen, reltol 1e-10). BFGS mit
 *             analytischem Gradienten (dcc_fg: Vorwärtsrekursion von dQ_t/da, dQ_t/db, Kettenregel
 *             über die logistische Abbildung), maxit 500, reltol 1e-12, gtol 1e-8, vom bisherigen
 *             Start. Die Likelihood hat oft mehrere lokale Minima (Grat kleines a / b nahe 1 gegen
 *             den Rand a -> 0); BFGS findet häufig ein besseres Becken als der bisherige Nelder-Mead,
 *             auf 160 simulierten Datensätzen in 2 bis 6 Fällen aber ein schlechteres (bewusst
 *             reiner BFGS ohne Nelder-Mead-Vorlauf). Scheitert
 *             BFGS (Start nicht endlich), läuft als Rückfall der bisherige Nelder-Mead.
 *             Ersetzt optim(Nelder-Mead) in dependence_dcc; zusammen mit slc_garch.cpp entfällt
 *             der zufällige gosolnp-Rückfall der GARCH-Stufe.
 * Quellen:    Engle, R. (2002). Dynamic conditional correlation: A simple class of multivariate
 *               generalized autoregressive conditional heteroskedasticity models. Journal of
 *               Business & Economic Statistics 20(3), 339–350.
 *             Nelder, J. A., Mead, R. (1965); Lagarias, J. C. u. a. (1998); Nocedal, J., Wright,
 *               S. J. (2006) (über slc_opt.cpp). Griewank, A., Walther, A. (2008). Evaluating
 *               Derivatives, 2. Aufl., SIAM (Vorwärtsmodus). Magnus, J. R., Neudecker, H. (2019).
 *               Matrix Differential Calculus, 3. Aufl., Wiley (d log|R| = tr(R^-1 dR),
 *               d R^-1 = -R^-1 dR R^-1).
 *             Eigener SimLev-Code: dcc_filter (r/src/dependence_core_impl.h), dependence_dcc
 *               (r/R/dependence.R).
 * Konstanten: keine; Verfahrensparameter wie dependence_dcc.
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen (rugarch,
 *             Rsolnp nicht gelesen).
 * Prüforakel: der frühere eigene Weg dependence_dcc (optim, .dcc_filter).
 */
#include "slc_internal.h"
#include "slc_la_internal.h"
#include "slc_opt.h"

#include <stdlib.h>
#include <string.h>

/* Cholesky einer kleinen Matrix (zeilenweise k x k) wie chol_small im eigenen Kern; 0 = nicht PD */
static int chol_small(const double *A, double *L, int k)
{
    int i, j, m;
    for (i = 0; i < k * k; i++) L[i] = 0.0;
    for (i = 0; i < k; ++i) {
        for (j = 0; j <= i; ++j) {
            double s = A[i * k + j];
            for (m = 0; m < j; ++m) s -= L[i * k + m] * L[j * k + m];
            if (i == j) {
                if (s <= 1e-14) return 0;
                L[i * k + i] = sqrt(s);
            } else {
                L[i * k + j] = s / L[j * k + j];
            }
        }
    }
    return 1;
}

/* Kern ohne Prüfung; work: 3 k^2 + k double */
static double dcc_run(int n, int k, const double *Z, double a, double b, const double *Qbar, int keep,
                      double *Rt, int *okp, double *work)
{
    const int np = k * (k - 1) / 2;
    double *Q = work, *R = Q + k * k, *L = R + k * k, *y = L + k * k;
    double nll = 0.0;
    int ok = 1, t, i, j, m, p;
    for (i = 0; i < k; ++i) for (j = 0; j < k; ++j) Q[i * k + j] = Qbar[i + (size_t) k * j];
    if (keep && Rt) {
        const double na = slc_na_real();
        for (p = 0; p < n * np; p++) Rt[p] = na;
    }
    for (t = 0; t < n; ++t) {
        if (t > 0) {
            for (i = 0; i < k; ++i) for (j = 0; j < k; ++j)
                Q[i * k + j] = (1.0 - a - b) * Qbar[i + (size_t) k * j] +
                               a * Z[(t - 1) + (size_t) n * i] * Z[(t - 1) + (size_t) n * j] + b * Q[i * k + j];
        }
        for (i = 0; i < k; ++i) for (j = 0; j < k; ++j)
            R[i * k + j] = Q[i * k + j] / sqrt(Q[i * k + i] * Q[j * k + j]);
        if (!chol_small(R, L, k)) { ok = 0; break; }
        {
            double logdet = 0.0, quad = 0.0, zz = 0.0;
            for (i = 0; i < k; ++i) {                  /* L y = z (Vorwärtseinsetzen) */
                double s = Z[t + (size_t) n * i];
                for (m = 0; m < i; ++m) s -= L[i * k + m] * y[m];
                y[i] = s / L[i * k + i];
                quad += y[i] * y[i];
                zz += Z[t + (size_t) n * i] * Z[t + (size_t) n * i];
                logdet += 2.0 * log(L[i * k + i]);
            }
            nll += 0.5 * (logdet + quad - zz);
        }
        if (keep && Rt) {
            p = 0;
            for (i = 0; i < k; ++i) for (j = i + 1; j < k; ++j) Rt[t + (size_t) n * p++] = R[i * k + j];
        }
    }
    if (!ok) nll = 1e10;
    *okp = ok;
    return nll;
}

static int check_in(sl_ctx *cx, int n, int k, const double *Z, const double *Qbar)
{
    if (n < 1 || k < 1) return sl_fail(cx, SL_ESMALL, "dcc: leere Eingabe (n = %d, k = %d)", n, k);
    if (!slc_all_finite((int64_t) n * k, Z)) return sl_fail(cx, SL_ENONFINITE, "dcc: Z enthält nicht endliche Werte");
    if (!slc_all_finite((int64_t) k * k, Qbar)) return sl_fail(cx, SL_ENONFINITE, "dcc: Qbar enthält nicht endliche Werte");
    return SL_OK;
}

int sl_dcc_filter(sl_ctx *cx, int n, int k, const double *Z, double a, double b, const double *Qbar,
                  int keep, double *nll, double *Rt, int *ok)
{
    double *w;
    int st = check_in(cx, n, k, Z, Qbar);
    if (st != SL_OK) return st;
    w = (double *) malloc((size_t) (3 * k * k + k) * sizeof(double));
    if (w == NULL) return sl_fail(cx, SL_ENOMEM, "dcc: kein Speicher");
    *nll = dcc_run(n, k, Z, a, b, Qbar, keep, Rt, ok, w);
    free(w);
    return SL_OK;
}

/* NLL und analytischer Gradient nach (a, b) in einem Durchlauf (Vorwärtsrekursion).
 *   dQ_t/da = -Qbar + z_{t-1} z_{t-1}' + b dQ_{t-1}/da,  dQ_t/db = -Qbar + Q_{t-1} + b dQ_{t-1}/db,
 *   dQ_1 = 0. Mit M = R^-1 - w w', w = R^-1 z_t, und dR_ij = dQ_ij / sqrt(q_ii q_jj)
 *   - R_ij (dq_ii / q_ii + dq_jj / q_jj) / 2 gilt d l_t = tr(M dR) / 2 = sum_ij N_ij dQ_ij / 2 mit
 *   N_ij = M_ij / sqrt(q_ii q_jj) (i != j), N_ii = (M_ii - 1 + w_i z_i) / q_ii, denn
 *   sum_j M_ij R_ij = (M R)_ii = 1 - w_i z_i (R w = z). R^-1 = L^-T L^-1 aus der Cholesky-Zerlegung.
 * Rechnung wie dcc_run (dieselbe Rekursion für Q, dieselbe Cholesky-Zerlegung und Schranke 1e-14),
 * aber mit zwei Beschleunigungen: R_ij = Q_ij / (r_i r_j) mit r_i = sqrt(q_ii) (k statt k^2 Wurzeln,
 * R_ii = 1 gesetzt) und log|R_t| = 2 log prod_i L_ii über ein laufendes Produkt, das vor dem
 * Unterlauf (< 1e-280; L_ii > 1e-7) und am Ende logarithmiert wird (ein Logarithmus für viele
 * Zeitpunkte statt k je Zeitpunkt). Der Wert weicht daher von dcc_run in den letzten Stellen ab.
 * Nicht positiv definit: +Inf (statt 1e10, damit die Liniensuche zurückgeht), Gradient NaN.
 * want_g = 0: nur der Wert (derzeit ungenutzt). work: 6 k^2 + 3 k double. g: (dl/da, dl/db). */
#if defined(__GNUC__) || defined(__clang__)
#define DCC_FG_INLINE static inline __attribute__((always_inline))
#else
#define DCC_FG_INLINE static inline
#endif
DCC_FG_INLINE double dcc_fg_impl(int n, int k, const double *Z, double a, double b, const double *Qbar,
                                 double *g, double *work, const int want_g)
{
    double *Q = work, *R = Q + k * k, *L = R + k * k, *y = L + k * k, *Da = y + k, *Db = Da + k * k,
           *Li = Db + k * k, *w = Li + k * k, *r = w + k;
    double qz = 0.0, lsum = 0.0, lp = 1.0, ga = 0.0, gb = 0.0, nll;
    const double c0 = 1.0 - a - b;
    int t, i, j, m;
    for (i = 0; i < k; ++i) for (j = 0; j < k; ++j) {
        Q[i * k + j] = Qbar[i + (size_t) k * j];
        if (want_g) { Da[i * k + j] = 0.0; Db[i * k + j] = 0.0; }
    }
    for (t = 0; t < n; ++t) {
        const double *zt = Z + t;
        if (t > 0) {
            const double *zp = Z + (t - 1);
            for (i = 0; i < k; ++i) for (j = 0; j < k; ++j) {
                const double qb = Qbar[i + (size_t) k * j], zz = zp[(size_t) n * i] * zp[(size_t) n * j];
                if (want_g) {
                    Da[i * k + j] = (zz - qb) + b * Da[i * k + j];
                    Db[i * k + j] = (Q[i * k + j] - qb) + b * Db[i * k + j];
                }
                Q[i * k + j] = c0 * qb + a * zz + b * Q[i * k + j];
            }
        }
        for (i = 0; i < k; ++i) r[i] = sqrt(Q[i * k + i]);
        for (i = 0; i < k; ++i) for (j = 0; j < k; ++j)
            R[i * k + j] = (i == j) ? 1.0 : Q[i * k + j] / (r[i] * r[j]);
        if (!chol_small(R, L, k)) goto bad;
        {
            double quad = 0.0, zz = 0.0;
            for (i = 0; i < k; ++i) {
                double s = zt[(size_t) n * i];
                for (m = 0; m < i; ++m) s -= L[i * k + m] * y[m];
                y[i] = s / L[i * k + i];
                quad += y[i] * y[i];
                zz += zt[(size_t) n * i] * zt[(size_t) n * i];
                lp *= L[i * k + i];
                if (lp < 1e-280) { lsum += log(lp); lp = 1.0; }
            }
            qz += quad - zz;
        }
        if (!want_g || t == 0) continue;           /* dQ_1 = 0 */
        for (i = k - 1; i >= 0; --i) {             /* L' w = y */
            double s = y[i];
            for (m = i + 1; m < k; ++m) s -= L[m * k + i] * w[m];
            w[i] = s / L[i * k + i];
        }
        for (j = 0; j < k; ++j) {                  /* Li = L^-1 (unteres Dreieck) */
            Li[j * k + j] = 1.0 / L[j * k + j];
            for (i = j + 1; i < k; ++i) {
                double s = 0.0;
                for (m = j; m < i; ++m) s -= L[i * k + m] * Li[m * k + j];
                Li[i * k + j] = s / L[i * k + i];
            }
        }
        {
            double sa = 0.0, sb = 0.0;
            for (i = 0; i < k; ++i) for (j = i; j < k; ++j) {
                double ri = 0.0, nij;                  /* (R^-1)_ij = sum_{m >= j} Li_mi Li_mj */
                for (m = j; m < k; ++m) ri += Li[m * k + i] * Li[m * k + j];
                if (i == j) nij = (ri - w[i] * w[i] - 1.0 + w[i] * zt[(size_t) n * i]) / Q[i * k + i];
                else nij = 2.0 * (ri - w[i] * w[j]) / (r[i] * r[j]);
                sa += nij * Da[i * k + j]; sb += nij * Db[i * k + j];
            }
            ga += sa; gb += sb;
        }
    }
    nll = (lsum + log(lp)) + 0.5 * qz;
    if (!isfinite(nll)) goto bad;
    if (want_g) { g[0] = 0.5 * ga; g[1] = 0.5 * gb; }
    return nll;
bad:
    if (want_g) g[0] = g[1] = NAN;
    return INFINITY;
}

static double dcc_fg(int n, int k, const double *Z, double a, double b, const double *Qbar, double *g, double *work)
{
    return dcc_fg_impl(n, k, Z, a, b, Qbar, g, work, 1);
}

typedef struct { int n, k; const double *Z, *Qbar; double *work; sl_ctx *cx; double xc[2], gc[2]; int have; } dcc_data;

static void dcc_par(sl_ctx *cx, const double *th, double *a, double *b)
{
    double p[2], s;
    sl_plogis(cx, 2, th, p);
    s = 0.999 * p[0];
    *a = s * p[1];
    *b = s - *a;
}

static double dcc_obj(const double *th, void *data)
{
    dcc_data *d = (dcc_data *) data;
    double a, b;
    int ok;
    dcc_par(d->cx, th, &a, &b);
    return dcc_run(d->n, d->k, d->Z, a, b, d->Qbar, 0, NULL, &ok, d->work);
}

/* f und Gradient in theta (logistische Abbildung wie bisher); Kettenregel über
 * s = 0.999 p1, a = s p2, b = s - a mit p_i = plogis(th_i), dp_i/dth_i = plogis(th_i) plogis(-th_i)
 * (ohne Auslöschung in 1 - p). */
static double dcc_fg_th(dcc_data *d, const double *th, double *g)
{
    double v[4], p[4], a, b, s, gab[2], f;
    v[0] = th[0]; v[1] = th[1]; v[2] = -th[0]; v[3] = -th[1];
    sl_plogis(d->cx, 4, v, p);
    s = 0.999 * p[0];
    a = s * p[1];
    b = s - a;
    f = dcc_fg(d->n, d->k, d->Z, a, b, d->Qbar, gab, d->work);
    g[0] = 0.999 * p[0] * p[2] * (gab[0] * p[1] + gab[1] * p[3]);
    g[1] = s * p[1] * p[3] * (gab[0] - gab[1]);
    return f;
}

static double dcc_fobj(const double *th, void *data)
{
    dcc_data *d = (dcc_data *) data;
    double f = dcc_fg_th(d, th, d->gc);
    d->xc[0] = th[0]; d->xc[1] = th[1];
    d->have = 1;
    return f;
}

static void dcc_fgr(const double *th, double *g, void *data)
{
    dcc_data *d = (dcc_data *) data;
    if (d->have && memcmp(d->xc, th, 2 * sizeof(double)) == 0) { g[0] = d->gc[0]; g[1] = d->gc[1]; }
    else (void) dcc_fg_th(d, th, g);
}

int sl_dcc_fit(sl_ctx *cx, int n, int k, const double *Z, const double *Qbar, const sl_opt_ctrl *ctrl,
               double *a, double *b, double *nll, int *code, double *theta)
{
    dcc_data d;
    sl_opt_ctrl c;
    sl_ctx scratch, sub;
    double th[2], th0[2], q[2], fmin = INFINITY;
    int st = check_in(cx, n, k, Z, Qbar), iter, nfev;
    if (st != SL_OK) return st;
    if (k < 2) return sl_fail(cx, SL_ESMALL, "dcc: mindestens zwei Reihen");
    d.work = (double *) malloc((size_t) (6 * k * k + 3 * k) * sizeof(double));
    if (d.work == NULL) return sl_fail(cx, SL_ENOMEM, "dcc: kein Speicher");
    sl_ctx_init(&scratch);
    d.n = n; d.k = k; d.Z = Z; d.Qbar = Qbar; d.cx = &scratch; d.have = 0;
    q[0] = 0.98 / 0.999; q[1] = 0.03 / 0.98;
    sl_qlogis(&scratch, 2, q, th0);
    /* BFGS mit analytischem Gradienten vom bisherigen Start */
    th[0] = th0[0]; th[1] = th0[1];
    if (ctrl) c = *ctrl;
    else { sl_opt_ctrl_default(&c, SL_OPT_BFGS); c.maxit = 500; c.reltol = 1e-12; }
    sl_ctx_init(&sub);
    st = sl_minimize(&sub, SL_OPT_BFGS, 2, th, NULL, NULL, &c, dcc_fobj, dcc_fgr, &d, &fmin, code, &iter, &nfev);
    if (st == SL_EINTR) { free(d.work); return sl_fail(cx, SL_EINTR, "%s", sub.msg); }
    if (st != SL_OK || !isfinite(fmin)) {
        /* Rückfall wie bis 1.1.0: Nelder-Mead über dcc_run (nicht positiv definit: 1e10) */
        th[0] = th0[0]; th[1] = th0[1];
        sl_opt_ctrl_default(&c, SL_OPT_NM); c.maxfev = 2000; c.reltol = 1e-10;
        st = sl_minimize(cx, SL_OPT_NM, 2, th, NULL, NULL, &c, dcc_obj, NULL, &d, &fmin, code, &iter, &nfev);
    }
    free(d.work);
    if (st != SL_OK) return st;
    dcc_par(&scratch, th, a, b);
    *nll = fmin;
    if (theta) { theta[0] = th[0]; theta[1] = th[1]; }
    return SL_OK;
}
