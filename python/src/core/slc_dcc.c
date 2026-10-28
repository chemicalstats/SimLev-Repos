/* core/slc_dcc.c – DCC(1,1): Filter und Schätzung des Korrelationsteils (SimLev core, Etappe 9.4)
 * Verfahren:  Dynamische bedingte Korrelation nach Engle (2002) auf standardisierten Residuen
 *             z_t (Stufe 1: univariate GARCH, slc_garch.c):
 *               Q_t = (1 - a - b) Qbar + a z_{t-1} z_{t-1}' + b Q_{t-1},  Q_1 = Qbar,
 *               R_t = diag(Q_t)^{-1/2} Q_t diag(Q_t)^{-1/2},
 *               -l = 1/2 sum_t (log|R_t| + z_t' R_t^{-1} z_t - z_t' z_t).
 *             Der Filter ist der eigene Kern dcc_filter (r/src/dependence_core_impl.h), Zeile für
 *             Zeile als C-ABI überführt: dieselbe Rechenfolge, dieselbe Cholesky-Zerlegung der
 *             kleinen Matrix (Pivot <= 1e-14: nicht positiv definit -> nll = 1e10, ok = 0,
 *             Korrelationen ab dieser Zeile NA).
 *             Schätzung (Stufe 2) ganz in C mit Nelder-Mead (slc_opt.c) über die logistische
 *             Abbildung der eigenen R-Funktion dependence_dcc (r/R/dependence.R):
 *             s = 0.999 plogis(th1), a = s plogis(th2), b = s - a; Start
 *             (qlogis(0.98/0.999), qlogis(0.03/0.98)), höchstens 2000 Auswertungen, reltol 1e-10.
 *             Ersetzt optim(Nelder-Mead) in dependence_dcc; zusammen mit slc_garch.c entfällt
 *             der zufällige gosolnp-Rückfall der GARCH-Stufe.
 * Quellen:    Engle, R. (2002). Dynamic conditional correlation: A simple class of multivariate
 *               generalized autoregressive conditional heteroskedasticity models. Journal of
 *               Business & Economic Statistics 20(3), 339–350.
 *             Nelder, J. A., Mead, R. (1965); Lagarias, J. C. u. a. (1998) (über slc_opt.c).
 *             Eigener SimLev-Code: dcc_filter (r/src/dependence_core_impl.h), dependence_dcc
 *               (r/R/dependence.R).
 * Konstanten: keine; Verfahrensparameter wie dependence_dcc.
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen (rugarch,
 *             Rsolnp nicht gelesen).
 * Prüforakel: der bisherige eigene Weg dependence_dcc (optim, .dcc_filter); scratchpad/e94/.
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

typedef struct { int n, k; const double *Z, *Qbar; double *work; sl_ctx *cx; } dcc_data;

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

int sl_dcc_fit(sl_ctx *cx, int n, int k, const double *Z, const double *Qbar, const sl_opt_ctrl *ctrl,
               double *a, double *b, double *nll, int *code, double *theta)
{
    dcc_data d;
    sl_opt_ctrl c;
    sl_ctx scratch;
    double th[2], q[2], fmin;
    int st = check_in(cx, n, k, Z, Qbar), iter, nfev;
    if (st != SL_OK) return st;
    if (k < 2) return sl_fail(cx, SL_ESMALL, "dcc: mindestens zwei Reihen");
    d.work = (double *) malloc((size_t) (3 * k * k + k) * sizeof(double));
    if (d.work == NULL) return sl_fail(cx, SL_ENOMEM, "dcc: kein Speicher");
    sl_ctx_init(&scratch);
    d.n = n; d.k = k; d.Z = Z; d.Qbar = Qbar; d.cx = &scratch;
    q[0] = 0.98 / 0.999; q[1] = 0.03 / 0.98;
    sl_qlogis(&scratch, 2, q, th);
    if (ctrl) c = *ctrl;
    else { sl_opt_ctrl_default(&c, SL_OPT_NM); c.maxfev = 2000; c.reltol = 1e-10; }
    st = sl_minimize(cx, SL_OPT_NM, 2, th, NULL, NULL, &c, dcc_obj, NULL, &d, &fmin, code, &iter, &nfev);
    free(d.work);
    if (st != SL_OK) return st;
    dcc_par(&scratch, th, a, b);
    *nll = fmin;
    if (theta) { theta[0] = th[0]; theta[1] = th[1]; }
    return SL_OK;
}
