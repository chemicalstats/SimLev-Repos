/* core/slc_opt_test.c – Prüffunktionen der Optimierer (SimLev core, Etappe 9.3)
 * Verfahren:  Standardtestfunktionen der unbeschränkten Optimierung mit analytischem Gradienten,
 *             für die Plausibilitätsprüfung gegen optim und den Gleichlauf der Sprachen (dieselbe
 *             C-Zielfunktion über die Hüllen in R, Python und Julia): 1 Rosenbrock (verkettet),
 *             2 Beale, 3 Powell singulär, 4 Wood, 5 schlecht skalierte Quadratik
 *             sum 10^(6 i/(n-1)) (x_i - 1)^2 + sum (x_i - x_i+1)^2, 6 nicht glatt
 *             sum (i+1) |x_i - (i+1)/2|, 7 sum (i+1) x_i - log x_i (NaN für x_i < 0, +Inf für
 *             x_i = 0), 8 sum (x_i - c_i)^2 + 0.5 sum x_i x_i+1 mit c_i = 2 (gerade i), -2
 *             (ungerade i) für Tests mit aktiven Schranken.
 * Quellen:    Moré, J. J., Garbow, B. S., Hillstrom, K. E. (1981). Testing unconstrained
 *               optimization software. ACM Transactions on Mathematical Software 7(1), 17–41
 *               (Definitionen der Funktionen 1 bis 4 als Formeln: Rosenbrock, Beale, Powell
 *               singular, Wood; nur die mathematischen Ausdrücke, kein Programmcode).
 *             Rosenbrock, H. H. (1960). An automatic method for finding the greatest or least
 *               value of a function. The Computer Journal 3(3), 175–184.
 *             Funktionen 5 bis 8: eigene Wahl.
 * Konstanten: die Koeffizienten der Formeln (100, 1.5, 2.25, 2.625, 10, 5, 90, 10.1, 19.8).
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: –
 */
#include "slc_internal.h"
#include "slc_opt.h"

static double sq(double v) { return v * v; }

double sl_opt_testfn(int id, int n, const double *x, double *g)
{
    double f = 0.0, t, t1, t2, t3, a, b, c, d;
    int i;
    if (n < 1 || x == NULL) return NAN;
    switch (id) {
    case 1:                                   /* Rosenbrock, verkettet */
        if (n < 2) return NAN;
        if (g) for (i = 0; i < n; i++) g[i] = 0.0;
        for (i = 0; i < n - 1; i++) {
            t = x[i + 1] - x[i] * x[i];
            a = 1.0 - x[i];
            f += 100.0 * t * t + a * a;
            if (g) { g[i] += -400.0 * x[i] * t - 2.0 * a; g[i + 1] += 200.0 * t; }
        }
        return f;
    case 2:                                   /* Beale */
        if (n != 2) return NAN;
        a = x[0]; b = x[1];
        t1 = 1.5 - a + a * b;
        t2 = 2.25 - a + a * b * b;
        t3 = 2.625 - a + a * b * b * b;
        if (g) {
            g[0] = 2.0 * t1 * (b - 1.0) + 2.0 * t2 * (b * b - 1.0) + 2.0 * t3 * (b * b * b - 1.0);
            g[1] = 2.0 * t1 * a + 2.0 * t2 * (2.0 * a * b) + 2.0 * t3 * (3.0 * a * b * b);
        }
        return t1 * t1 + t2 * t2 + t3 * t3;
    case 3:                                   /* Powell singulär */
        if (n != 4) return NAN;
        a = x[0] + 10.0 * x[1]; b = x[2] - x[3]; c = x[1] - 2.0 * x[2]; d = x[0] - x[3];
        if (g) {
            g[0] = 2.0 * a + 40.0 * d * d * d;
            g[1] = 20.0 * a + 4.0 * c * c * c;
            g[2] = 10.0 * b - 8.0 * c * c * c;
            g[3] = -10.0 * b - 40.0 * d * d * d;
        }
        return a * a + 5.0 * b * b + sq(c * c) + 10.0 * sq(d * d);
    case 4:                                   /* Wood */
        if (n != 4) return NAN;
        a = x[1] - x[0] * x[0]; b = x[3] - x[2] * x[2];
        if (g) {
            g[0] = -400.0 * x[0] * a - 2.0 * (1.0 - x[0]);
            g[1] = 200.0 * a + 20.2 * (x[1] - 1.0) + 19.8 * (x[3] - 1.0);
            g[2] = -360.0 * x[2] * b - 2.0 * (1.0 - x[2]);
            g[3] = 180.0 * b + 20.2 * (x[3] - 1.0) + 19.8 * (x[1] - 1.0);
        }
        return 100.0 * a * a + sq(1.0 - x[0]) + 90.0 * b * b + sq(1.0 - x[2]) +
               10.1 * (sq(x[1] - 1.0) + sq(x[3] - 1.0)) + 19.8 * (x[1] - 1.0) * (x[3] - 1.0);
    case 5:                                   /* schlecht skalierte Quadratik */
        if (n < 2) return NAN;
        if (g) for (i = 0; i < n; i++) g[i] = 0.0;
        for (i = 0; i < n; i++) {
            a = pow(10.0, 6.0 * i / (n - 1));
            t = x[i] - 1.0;
            f += a * t * t;
            if (g) g[i] += 2.0 * a * t;
        }
        for (i = 0; i < n - 1; i++) {
            t = x[i] - x[i + 1];
            f += t * t;
            if (g) { g[i] += 2.0 * t; g[i + 1] -= 2.0 * t; }
        }
        return f;
    case 6:                                   /* nicht glatt */
        for (i = 0; i < n; i++) {
            t = x[i] - (i + 1) / 2.0;
            f += (i + 1) * fabs(t);
            if (g) g[i] = (t > 0.0) ? (i + 1) : (t < 0.0 ? -(double) (i + 1) : 0.0);
        }
        return f;
    case 7:                                   /* log-Schranke */
        for (i = 0; i < n; i++) {
            f += (i + 1) * x[i] - log(x[i]);
            if (g) g[i] = (i + 1) - 1.0 / x[i];
        }
        return f;
    case 8:                                   /* gekoppelte Quadratik (Schranken) */
        if (g) for (i = 0; i < n; i++) g[i] = 0.0;
        for (i = 0; i < n; i++) {
            c = (i % 2 == 0) ? 2.0 : -2.0;
            t = x[i] - c;
            f += t * t;
            if (g) g[i] += 2.0 * t;
        }
        for (i = 0; i < n - 1; i++) {
            f += 0.5 * x[i] * x[i + 1];
            if (g) { g[i] += 0.5 * x[i + 1]; g[i + 1] += 0.5 * x[i]; }
        }
        return f;
    default:
        return NAN;
    }
}

/* ── direkter C-Weg mit Prüffunktion (für die Hüllen aller drei Sprachen) ── */

typedef struct { int id, n, cnt; } tf_data;

static double tf_f(const double *x, void *d)
{
    tf_data *t = (tf_data *) d;
    t->cnt++;
    return sl_opt_testfn(t->id, t->n, x, NULL);
}

static void tf_g(const double *x, double *g, void *d)
{
    tf_data *t = (tf_data *) d;
    (void) sl_opt_testfn(t->id, t->n, x, g);
}

int sl_opt_test_minimize(sl_ctx *cx, int id, int method, int n, double *x, const double *lo, const double *hi,
                         const sl_opt_ctrl *ctrl, int use_grad, double *fmin, int *code, int *iter, int *nfev,
                         int *ntot)
{
    tf_data d;
    int st;
    d.id = id; d.n = n; d.cnt = 0;
    st = sl_minimize(cx, method, n, x, lo, hi, ctrl, tf_f, use_grad ? tf_g : NULL, &d, fmin, code, iter, nfev);
    if (ntot) *ntot = d.cnt;
    return st;
}

int sl_opt_test_numgrad(sl_ctx *cx, int id, int n, const double *x, const double *lo, const double *hi,
                        double *g, int *nfev)
{
    tf_data d;
    d.id = id; d.n = n; d.cnt = 0;
    return sl_numgrad(cx, n, x, lo, hi, sl_opt_testfn(id, n, x, NULL), tf_f, &d, g, nfev);
}
