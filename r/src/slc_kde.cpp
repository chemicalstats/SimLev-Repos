/* core/slc_kde.cpp – Gauß-Kerndichte und Bandbreite nach Silverman (SimLev core)
 * Verfahren:  f(u_j) = sum_i w_i phi((u_j - x_i) / h) / h auf ngrid gleichabständigen Punkten
 *             u_j = from + j (to - from) / (ngrid - 1) (u_{ngrid-1} = to), phi(z) =
 *             e^(-z^2/2) / sqrt(2 pi); w_i = 1/n ohne Gewichte. Direkte Summation in fester
 *             Reihenfolge; bei n ngrid > 10^7 (und allen x in [from, to]) lineares Binning auf das
 *             Gitter (Gewicht w (1 - r) an den linken, w r an den rechten Gitterpunkt) und diskrete
 *             Faltung mit den Kernwerten an den Gitterabständen (Wand/Jones 1995, Anhang D). Keine FFT.
 *             Bandbreite (sl_kde_bw): Silvermans Faustregel h = 0.9 min(sd, IQR/1.34) n^(-1/5)
 *             (Silverman 1986, Gl. 3.31); sd mit kompensierten Summen in zwei Durchgängen, IQR aus
 *             den Quartilen nach Hyndman/Fan (1996), Definition 7 (lineare Interpolation der
 *             Ordnungsstatistiken an (n - 1) p). Ist min(sd, IQR/1.34) = 0, gilt der Reihe nach sd,
 *             |x_1|, 1 (eigene Regel, damit h > 0).
 * Quellen:    Silverman, B. W. (1986). Density Estimation for Statistics and Data Analysis. Chapman &
 *             Hall, §3.4.2, Gl. (3.31).
 *             Scott, D. W. (1992). Multivariate Density Estimation. Wiley, Kap. 6 (Gauß-Kern).
 *             Wand, M. P., Jones, M. C. (1995). Kernel Smoothing. Chapman & Hall, Anhang D
 *             (Binning und diskrete Faltung).
 *             Hyndman, R. J., Fan, Y. (1996). Sample quantiles in statistical packages. The American
 *             Statistician 50(4), 361–365.
 *             Neumaier, A. (1974). ZAMM 54(1), 39–51 (kompensierte Summe).
 * Konstanten: 1/sqrt(2 pi) aus slc_constants.h (gen_constants.py); 0.9, 1.34, -1/5 aus Silverman (1986).
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: R 4.3.3 density(x) und bw.nrd0 (nur Plausibilität; density nutzt Binning und FFT).
 */
#include "slc_internal.h"
#include "slc_la_internal.h"
#include "slc_constants.h"

#include <stdlib.h>
#include <string.h>

static double kern(double z) { return z * z > 1500.0 ? 0.0 : exp(-0.5 * z * z); }

int sl_kde(sl_ctx *cx, int64_t n, const double *x, const double *w, double bw,
           int ngrid, double from, double to, double *xgrid, double *y)
{
    int64_t i;
    int j, k, li, inside = 1;
    double step, s, wi, pos, fr, c0, *cnt = NULL, *kv = NULL;
    if (n < 1) return sl_fail(cx, SL_ESMALL, "density: mindestens ein Wert nötig");
    if (!slc_all_finite(n, x)) return sl_fail(cx, SL_ENONFINITE, "density: NA/NaN/Inf in x");
    if (w) {
        if (!slc_all_finite(n, w)) return sl_fail(cx, SL_ENONFINITE, "density: NA/NaN/Inf in den Gewichten");
        for (i = 0; i < n; i++) if (w[i] < 0.0) return sl_fail(cx, SL_EARG, "density: negative Gewichte");
    }
    if (!(bw > 0.0) || !isfinite(bw)) return sl_fail(cx, SL_EARG, "density: Bandbreite muss positiv und endlich sein");
    if (ngrid < 2) return sl_fail(cx, SL_EARG, "density: mindestens 2 Gitterpunkte");
    if (!isfinite(from) || !isfinite(to) || !(to > from)) return sl_fail(cx, SL_EARG, "density: from < to (endlich) nötig");
    step = (to - from) / (double) (ngrid - 1);
    for (j = 0; j < ngrid; j++) xgrid[j] = from + (double) j * step;
    xgrid[ngrid - 1] = to;
    c0 = SLC_M_1_SQRT2PI / bw;
    for (i = 0; i < n; i++) if (x[i] < from || x[i] > to) { inside = 0; break; }
    if ((double) n * (double) ngrid <= 1e7 || !inside) {
        for (j = 0; j < ngrid; j++) {
            s = 0.0;
            for (i = 0; i < n; i++) {
                wi = w ? w[i] : 1.0;
                s += wi * kern((xgrid[j] - x[i]) / bw);
                SL_POLL(cx, i);
            }
            y[j] = w ? s * c0 : s * c0 / (double) n;
        }
        return SL_OK;
    }
    cnt = (double *) calloc((size_t) ngrid, sizeof(double));
    kv = (double *) malloc(sizeof(double) * (size_t) ngrid);
    if (!cnt || !kv) { free(cnt); free(kv); return sl_fail(cx, SL_ENOMEM, "density: kein Speicher"); }
    for (i = 0; i < n; i++) {
        wi = w ? w[i] : 1.0;
        pos = (x[i] - from) / step;
        li = (int) floor(pos);
        if (li >= ngrid - 1) { cnt[ngrid - 1] += wi; continue; }
        if (li < 0) li = 0;
        fr = pos - (double) li;
        cnt[li] += wi * (1.0 - fr);
        cnt[li + 1] += wi * fr;
        if ((((i + 1) & 0xFFFF) == 0) && sl_interrupted(cx)) { free(cnt); free(kv); return SL_EINTR; }
    }
    for (k = 0; k < ngrid; k++) kv[k] = kern((double) k * step / bw);
    for (j = 0; j < ngrid; j++) {
        s = 0.0;
        for (k = 0; k < ngrid; k++) s += cnt[k] * kv[j > k ? j - k : k - j];
        y[j] = w ? s * c0 : s * c0 / (double) n;
    }
    free(cnt); free(kv);
    return SL_OK;
}

int sl_kde_bw(sl_ctx *cx, int64_t n, const double *x, double *bw)
{
    double *xs = NULL, mean, sd, iqr, q75, lo;
    if (n < 2) return sl_fail(cx, SL_ESMALL, "bw.nrd0: mindestens 2 Werte nötig");
    if (!slc_all_finite(n, x)) return sl_fail(cx, SL_ENONFINITE, "bw.nrd0: NA/NaN/Inf in x");
    xs = (double *) malloc(sizeof(double) * (size_t) n);
    if (!xs) return sl_fail(cx, SL_ENOMEM, "bw.nrd0: kein Speicher");
    mean = slc_mean(n, x);                  /* n >= 2 (oben geprüft) */
    sd = sqrt(slc_var_m(n, x, mean));
    /* Quartile ohne Sortieren (seit 1.6.3, slc_quantile7; gleiche Ordnungsstatistiken, nur das Vorzeichen einer
     * Null kann wechseln, und eine IQR von ±0 führt unten gleich zu sd) */
    memcpy(xs, x, sizeof(double) * (size_t) n);
    q75 = slc_quantile7(xs, n, 0.75);
    iqr = q75 - slc_quantile7(xs, n, 0.25);
    lo = iqr / 1.34 < sd ? iqr / 1.34 : sd;
    if (!(lo > 0.0)) lo = sd;
    if (!(lo > 0.0)) lo = fabs(x[0]);
    if (!(lo > 0.0)) lo = 1.0;
    *bw = 0.9 * lo * pow((double) n, -0.2);
    free(xs);
    return SL_OK;
}
