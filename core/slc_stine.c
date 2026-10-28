/* core/slc_stine.c – Stineman-Interpolation (SimLev core, Etappe 9.2)
 * Verfahren:  stückweise rationale Interpolation nach Stineman (1980).
 *             Steigungen an den inneren Stützstellen: Steigung des Kreises durch die Stützstelle
 *             und ihre beiden Nachbarn. Mit a = P_i - P_{i-1}, b = P_{i+1} - P_i ist die Tangente
 *             dieses Kreises in P_i parallel zu |b|^2 a + |a|^2 b (hergeleitet: mit P_i = 0 und
 *             Mittelpunkt C gilt |a|^2 = -2 C.a, |b|^2 = 2 C.b, also (|b|^2 a + |a|^2 b).C = 0), d. h.
 *             yp_i = (|b|^2 dy_a + |a|^2 dy_b) / (|b|^2 dx_a + |a|^2 dx_b), ein gewichtetes Mittel der
 *             beiden Sekantensteigungen.
 *             Randsteigungen (am linken Rand mit der ersten Sekante s und der Nachbarsteigung yp_2,
 *             rechts spiegelbildlich): yp_1 = 2 s - yp_2 (Randsteigung der Parabel, deren Sekante
 *             das Mittel der Endsteigungen ist); haben s und yp_2 dasselbe Vorzeichen und ist
 *             |yp_2| > |s|, dann yp_1 = s^2 / yp_2 (geometrisches statt arithmetisches Spiegeln:
 *             yp_1 / s = s / yp_2, Vorzeichen und Monotonie bleiben erhalten). Die Fallunterscheidung
 *             ist mit stinepack 1.5 als Black-Box-Orakel bestätigt (scratchpad/e92/tools/probe_stine*.R;
 *             Abweichung < 2e-15 relativ zur Spannweite).
 *             Zwischen x_i und x_{i+1}: y0 = linearer Interpolant, d1 = (yp_i - s)(x - x_i),
 *             d2 = (yp_{i+1} - s)(x - x_{i+1}); y = y0 + d1 d2 / (d1 + d2) bei d1 d2 > 0,
 *             y = y0 + d1 d2 (x - x_i + x - x_{i+1}) / ((d1 - d2)(x_{i+1} - x_i)) bei d1 d2 < 0,
 *             sonst y0 (Stineman 1980, Fallunterscheidung nach dem Vorzeichen der Abweichungen).
 *             Skalierung (scale = 1, F19; stinepack-Standard "scaledstineman"): die Steigungen
 *             werden für (x, f y) mit f = (x_n - x_1) / (max y - min y) berechnet und durch f geteilt,
 *             damit die Kreisgeometrie nicht von den Einheiten abhängt (eigene Regel, mit dem Orakel
 *             bestätigt; bei max y = min y ist f = 1). Der Interpolant ist in (y, yp) homogen vom
 *             Grad 1, daher genügt die Skalierung der Steigungen.
 *             Überläuft |a|^2 oder |b|^2, wird die Kreissteigung mit je auf das Betragsmaximum
 *             skalierten Vektoren gebildet (gleicher Wert, eigene Umformung). Nicht endliche
 *             Steigungen (etwa bei Überlauf der Differenzen) pflanzen sich als NaN fort.
 *             Ränder: n = 1 konstant (nur x_1 selbst), n = 2 linear; xout außerhalb [x_1, x_n] oder
 *             NaN ergibt NA.
 * Quellen:    Stineman, R. W. (1980). A consistently well-behaved method of interpolation. Creative
 *             Computing 6(7), 54–57.
 * Konstanten: keine.
 * Reinraum:   geschrieben nur nach der genannten Quelle und eigener Herleitung; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen (stinepack nur
 *             als Black-Box-Orakel).
 * Prüforakel: stinepack 1.5 stinterp, stinemanSlopes (nur Plausibilität).
 */
#include "slc_internal.h"
#include "slc_la_internal.h"

#include <stdlib.h>

static int check_xy(sl_ctx *cx, int n, const double *x, const double *y)
{
    int i;
    if (n < 1) return sl_fail(cx, SL_ESMALL, "stinterp: mindestens ein Wert nötig");
    for (i = 0; i < n; i++)
        if (!isfinite(x[i])) return sl_fail(cx, SL_EARG, "stinterp: x muss endlich und streng steigend sein");
    for (i = 1; i < n; i++)
        if (!(x[i] > x[i - 1])) return sl_fail(cx, SL_EARG, "stinterp: x muss endlich und streng steigend sein");
    for (i = 0; i < n; i++)
        if (!isfinite(y[i])) return sl_fail(cx, SL_ENONFINITE, "stinterp: NA/NaN/Inf in y");
    return SL_OK;
}

/* dieselbe Kreissteigung ohne Überlauf der Quadrate: a und b je mit ihrem Betragsmaximum skaliert,
 * Zähler und Nenner durch s_a s_b geteilt */
static double circle_slope_scaled(double dxa, double dya, double dxb, double dyb)
{
    double sa = fmax(fabs(dxa), fabs(dya)), sb = fmax(fabs(dxb), fabs(dyb));
    double ua = dxa / sa, va = dya / sa, ub = dxb / sb, vb = dyb / sb;
    double a2 = ua * ua + va * va, b2 = ub * ub + vb * vb;
    return (sb * b2 * va + sa * a2 * vb) / (sb * b2 * ua + sa * a2 * ub);
}

static double end_slope(double s, double ypn)
{
    if (s * ypn > 0.0 && fabs(ypn) > fabs(s)) return s * s / ypn;
    return 2.0 * s - ypn;
}

int sl_stineman_slopes(sl_ctx *cx, int n, const double *x, const double *y, int scale, double *yp)
{
    int i, st;
    double f = 1.0, ymin, ymax, dxa, dya, dxb, dyb, a2, b2;
    if ((st = check_xy(cx, n, x, y)) != SL_OK) return st;
    if (n == 1) { yp[0] = 0.0; return SL_OK; }
    if (n == 2) { yp[0] = yp[1] = (y[1] - y[0]) / (x[1] - x[0]); return SL_OK; }
    if (scale) {
        ymin = ymax = y[0];
        for (i = 1; i < n; i++) { if (y[i] < ymin) ymin = y[i]; if (y[i] > ymax) ymax = y[i]; }
        if (ymax > ymin) f = (x[n - 1] - x[0]) / (ymax - ymin);
        if (!isfinite(f) || f == 0.0) f = 1.0;
    }
    for (i = 1; i < n - 1; i++) {
        dxa = x[i] - x[i - 1]; dya = f * (y[i] - y[i - 1]);
        dxb = x[i + 1] - x[i]; dyb = f * (y[i + 1] - y[i]);
        a2 = dxa * dxa + dya * dya;
        b2 = dxb * dxb + dyb * dyb;
        yp[i] = (b2 * dya + a2 * dyb) / (b2 * dxa + a2 * dxb);
        if (!isfinite(yp[i])) yp[i] = circle_slope_scaled(dxa, dya, dxb, dyb);
    }
    yp[0] = end_slope(f * (y[1] - y[0]) / (x[1] - x[0]), yp[1]);
    yp[n - 1] = end_slope(f * (y[n - 1] - y[n - 2]) / (x[n - 1] - x[n - 2]), yp[n - 2]);
    if (f != 1.0) for (i = 0; i < n; i++) yp[i] /= f;
    return SL_OK;
}

int sl_stineman_eval(sl_ctx *cx, int n, const double *x, const double *y, const double *yp,
                     int nout, const double *xout, double *yout)
{
    int j, lo, hi, mid, i, st;
    double v, h, s, y0, d1, d2, p, na = slc_na_real();
    if ((st = check_xy(cx, n, x, y)) != SL_OK) return st;
    if (nout < 0) return sl_fail(cx, SL_EARG, "stinterp: negative Länge von xout");
    for (j = 0; j < nout; j++) {
        v = xout[j];
        if (isnan(v) || v < x[0] || v > x[n - 1]) { yout[j] = na; continue; }
        if (n == 1) { yout[j] = y[0]; continue; }
        lo = 0; hi = n - 1;                     /* x[lo] <= v <= x[hi] */
        while (hi - lo > 1) {
            mid = lo + (hi - lo) / 2;
            if (x[mid] <= v) lo = mid; else hi = mid;
        }
        i = lo;
        if (v == x[i]) { yout[j] = y[i]; continue; }
        if (v == x[i + 1]) { yout[j] = y[i + 1]; continue; }
        h = x[i + 1] - x[i];
        s = (y[i + 1] - y[i]) / h;
        y0 = y[i] + s * (v - x[i]);
        d1 = (yp[i] - s) * (v - x[i]);
        d2 = (yp[i + 1] - s) * (v - x[i + 1]);
        p = d1 * d2;
        if (p > 0.0) yout[j] = y0 + p / (d1 + d2);
        else if (p < 0.0) yout[j] = y0 + p * ((v - x[i]) + (v - x[i + 1])) / ((d1 - d2) * h);
        else yout[j] = y0;
    }
    return SL_OK;
}

int sl_stineman(sl_ctx *cx, int n, const double *x, const double *y, int nout, const double *xout,
                double *yout)
{
    double *yp;
    int st;
    if ((st = check_xy(cx, n, x, y)) != SL_OK) return st;
    yp = (double *) malloc(sizeof(double) * (size_t) n);
    if (!yp) return sl_fail(cx, SL_ENOMEM, "stinterp: kein Speicher");
    st = sl_stineman_slopes(cx, n, x, y, 1, yp);
    if (st == SL_OK) st = sl_stineman_eval(cx, n, x, y, yp, nout, xout, yout);
    free(yp);
    return st;
}
