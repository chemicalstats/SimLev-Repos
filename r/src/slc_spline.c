/* core/slc_spline.c – kubischer Glättungsspline mit GCV und Vorhersage (SimLev core, Etappe 9.2)
 * Verfahren:  Minimiert wird sum_i w_i (y_i - f(x_i))^2 + lambda int f''^2 über natürliche kubische
 *             Splines mit Knoten an allen verschiedenen x_i (Reinsch 1967). Mit h_i = t_{i+1} - t_i,
 *             der Bandmatrix Q (n x (n-2); q_{j-1,j} = 1/h_{j-1}, q_{jj} = -1/h_{j-1} - 1/h_j,
 *             q_{j+1,j} = 1/h_j) und R ((n-2) x (n-2); r_jj = (h_{j-1} + h_j)/3, r_{j,j+1} = h_j/6)
 *             gilt (R + lambda Q'W^-1 Q) gamma = Q'y und g = y - lambda W^-1 Q gamma
 *             (Green/Silverman 1994, §2.1.2 und §2.3.3, Reinsch-Algorithmus). Das System ist
 *             fünfbandig und wird mit dem Band-Cholesky (sl_chol_band, Halbbandbreite 2) gelöst;
 *             Q'y als Differenz der dividierten Differenzen, das Residuum y - g = lambda W^-1 Q gamma
 *             direkt (ohne Auslöschung).
 *             Spur der Hutmatrix A (Hutchinson/de Hoog 1985): I - A = lambda W^-1 Q M^-1 Q', also
 *             tr A = n - lambda tr(M^-1 P) mit M = R + lambda P, P = Q'W^-1 Q (fünfbandig); wegen
 *             lambda M^-1 P = I - M^-1 R gilt tr A = 2 + tr(M^-1 R) und 1 - tr A / n =
 *             lambda tr(M^-1 P) / n (beides ohne Auslöschung, eigene Umformung); gebraucht
 *             werden nur die fünf mittleren Bänder von M^-1. Aus M = LL' folgt L' S = L^-1, also
 *             für j >= i: S_ij = (delta_ij / l_ii - sum_{k=i+1}^{i+2} l_ki S_kj) / l_ii, rückwärts
 *             über i und je i zuerst j = i+2, i+1, dann j = i (eigene Herleitung in der Form von
 *             Hutchinson/de Hoog); O(n).
 *             GCV(lambda) = n^-1 RSS_w / (1 - tr A / n)^2 (Craven/Wahba 1979) mit n = Zahl der
 *             verschiedenen Knoten und RSS_w = sum w_i (ybar_i - g_i)^2 der zusammengefassten Daten.
 *             Suche auf s = log10(lambda / r0) mit r0 = tr R / tr P (macht lambda maßstabsfrei):
 *             Raster mit 25 Punkten auf [-6, 4 log10(n) + 4] (gemessen: die effektiven
 *             Freiheitsgrade laufen dort von n - 1e-4 (n - df(-2) zwischen 0.02 und 0.7 % von n)
 *             bis etwa 2, scratchpad/e92/df_ends.txt; das Minimum liegt mitunter am Rand
 *             lambda -> 0), dann Goldener Schnitt (Kiefer 1953) in den Intervallen um die bis zu drei
 *             kleinsten lokalen Rasterminima (GCV ist oft zweigipflig) bis zur Breite 1e-6 in s;
 *             genommen wird der beste ausgewertete Punkt. Ist das Bandsystem für ein lambda
 *             numerisch nicht positiv definit (sehr großes lambda bei vielen Knoten), zählt der
 *             Punkt als GCV = +Inf.
 *             Bindungen in x: Werte, die höchstens 1e-6 (max x - min x) hinter dem ersten Wert einer
 *             Gruppe liegen, werden zu einem Knoten zusammengefasst (gewichtete Mittel von x und y,
 *             Gewichtssumme; eigene Regel nach dem dokumentierten Verhalten von smooth.spline).
 *             Vorhersage: in [t_1, t_n] g(x) = ((x - t_i) g_{i+1} + (t_{i+1} - x) g_i) / h_i
 *             - (x - t_i)(t_{i+1} - x) ((1 + (x - t_i)/h_i) gamma_{i+1} + (1 + (t_{i+1} - x)/h_i) gamma_i) / 6
 *             (Green/Silverman 1994, §2.1.2); außerhalb lineare Fortsetzung mit der Randsteigung
 *             g'(t_1) = (g_2 - g_1)/h_1 - h_1 gamma_2 / 6, g'(t_n) = (g_n - g_{n-1})/h_{n-1}
 *             + h_{n-1} gamma_{n-1} / 6 (aus f'' = 0 am Rand).
 *             Sortierung: stabile Mischsortierung von unten (Knuth 1998, §5.2.4).
 * Quellen:    Reinsch, C. H. (1967). Smoothing by spline functions. Numerische Mathematik 10(3),
 *             177–183.
 *             Green, P. J., Silverman, B. W. (1994). Nonparametric Regression and Generalized Linear
 *             Models: A Roughness Penalty Approach. Chapman & Hall, Kap. 2 und 3.
 *             Craven, P., Wahba, G. (1979). Smoothing noisy data with spline functions. Numerische
 *             Mathematik 31(4), 377–403.
 *             Hutchinson, M. F., de Hoog, F. R. (1985). Smoothing noisy data with spline functions.
 *             Numerische Mathematik 47(1), 99–106.
 *             Kiefer, J. (1953). Sequential minimax search for a maximum. Proceedings of the American
 *             Mathematical Society 4(3), 502–506.
 *             Golub, G. H., Van Loan, C. F. (2013). Matrix Computations, 4. Aufl., §4.3 (Band-Cholesky).
 *             Knuth, D. E. (1998). The Art of Computer Programming, Bd. 3, 2. Aufl., §5.2.4.
 *             R Core Team: Hilfeseiten ?smooth.spline, ?predict.smooth.spline (nur dokumentiertes
 *             Verhalten: GCV bei cv = FALSE, Bindungen, lineare Fortsetzung).
 * Konstanten: (sqrt 5 - 1)/2 aus sqrt(5) zur Laufzeit; Raster und Grenzen eigene Festlegung (B.15).
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: R 4.3.3 smooth.spline(x, y, cv = FALSE), predict (nur Plausibilität; R wählt für
 *             n > 49 weniger Knoten, F20).
 */
#include "slc_internal.h"
#include "slc_la_internal.h"

#include <stdlib.h>

/* ── stabile Sortierung ── */

void slc_sort_index(int64_t n, const double *key, int64_t *idx, int64_t *work)
{
    int64_t w, lo, mid, hi, i, j, k, *src = idx, *dst = work, *t;
    for (i = 0; i < n; i++) idx[i] = i;
    for (w = 1; w < n; w *= 2) {
        for (lo = 0; lo < n; lo += 2 * w) {
            mid = lo + w < n ? lo + w : n;
            hi = lo + 2 * w < n ? lo + 2 * w : n;
            i = lo; j = mid; k = lo;
            while (i < mid && j < hi) dst[k++] = (key[src[j]] < key[src[i]]) ? src[j++] : src[i++];
            while (i < mid) dst[k++] = src[i++];
            while (j < hi) dst[k++] = src[j++];
        }
        t = src; src = dst; dst = t;
    }
    if (src != idx) for (i = 0; i < n; i++) idx[i] = src[i];
}

/* ── Arbeitsdaten ── */

typedef struct {
    int nk, N;                       /* Knoten, N = nk - 2 */
    double *t, *yb, *wb;             /* Knoten, gewichtete Mittel, Gewichtssummen */
    double *h, *qty, *Rd, *Ro;       /* Abstände, Q'y, R (Diagonale, erste Nebendiagonale) */
    double *P0, *P1, *P2;            /* Bänder von P = Q'W^-1 Q */
    double *ab, *gam, *S0, *S1, *S2, *res;
    double r0;                       /* tr R / tr P */
} spl;

/* Q[a + d, a] für d = 0, 1, 2 (Spalte a gehört zum inneren Knoten a + 1) */
static double qel(const spl *s, int a, int d)
{
    if (d == 0) return 1.0 / s->h[a];
    if (d == 1) return -(1.0 / s->h[a] + 1.0 / s->h[a + 1]);
    return 1.0 / s->h[a + 1];
}

static void setup(spl *s)
{
    int a, N = s->N, i;
    slc_acc tr, tp;
    for (i = 0; i < s->nk - 1; i++) s->h[i] = s->t[i + 1] - s->t[i];
    slc_acc_init(&tr, 0.0); slc_acc_init(&tp, 0.0);
    for (a = 0; a < N; a++) {
        s->qty[a] = (s->yb[a + 2] - s->yb[a + 1]) / s->h[a + 1] - (s->yb[a + 1] - s->yb[a]) / s->h[a];
        s->Rd[a] = (s->h[a] + s->h[a + 1]) / 3.0;
        s->Ro[a] = a + 1 < N ? s->h[a + 1] / 6.0 : 0.0;
        s->P0[a] = qel(s, a, 0) * qel(s, a, 0) / s->wb[a] + qel(s, a, 1) * qel(s, a, 1) / s->wb[a + 1]
                 + qel(s, a, 2) * qel(s, a, 2) / s->wb[a + 2];
        /* P[a, a+1] = sum_i Q[i, a] Q[i, a+1] / w_i, i = a+1, a+2 */
        s->P1[a] = a + 1 < N ? qel(s, a, 1) * qel(s, a + 1, 0) / s->wb[a + 1] + qel(s, a, 2) * qel(s, a + 1, 1) / s->wb[a + 2] : 0.0;
        s->P2[a] = a + 2 < N ? qel(s, a, 2) * qel(s, a + 2, 0) / s->wb[a + 2] : 0.0;
        slc_acc_add(&tr, s->Rd[a]);
        slc_acc_add(&tp, s->P0[a]);
    }
    s->r0 = slc_acc_val(&tr) / slc_acc_val(&tp);
}

/* Anpassung für lambda: gamma, Residuen, df, GCV */
static int fit_lambda(sl_ctx *cx, spl *s, double lam, double *df, double *gcv)
{
    int N = s->N, nk = s->nk, i, a, st;
    double *ab = s->ab, *u = s->gam, v, l0, l1, l2, d;
    slc_acc acc, tr, trr;
    for (a = 0; a < N; a++) {
        ab[3 * a] = s->Rd[a] + lam * s->P0[a];
        ab[3 * a + 1] = a + 1 < N ? s->Ro[a] + lam * s->P1[a] : 0.0;
        ab[3 * a + 2] = a + 2 < N ? lam * s->P2[a] : 0.0;
    }
    st = sl_chol_band(cx, N, 2, ab);
    if (st != SL_OK) return sl_fail(cx, SL_ENOTPD, "smooth.spline: Bandsystem nicht positiv definit (lambda = %g)", lam);
    /* L u = Q'y, L' gamma = u (an Ort und Stelle in gam) */
    for (i = 0; i < N; i++) {
        v = s->qty[i];
        if (i >= 1) v -= ab[3 * (i - 1) + 1] * u[i - 1];
        if (i >= 2) v -= ab[3 * (i - 2) + 2] * u[i - 2];
        u[i] = v / ab[3 * i];
    }
    for (i = N - 1; i >= 0; i--) {
        v = u[i];
        if (i + 1 < N) v -= ab[3 * i + 1] * u[i + 1];
        if (i + 2 < N) v -= ab[3 * i + 2] * u[i + 2];
        u[i] = v / ab[3 * i];
    }
    /* Residuen y - g = lambda W^-1 Q gamma */
    slc_acc_init(&acc, 0.0);
    for (i = 0; i < nk; i++) {
        slc_acc tq;
        slc_acc_init(&tq, 0.0);
        for (a = i - 2; a <= i; a++) if (a >= 0 && a < N) slc_acc_add(&tq, qel(s, a, i - a) * s->gam[a]);
        s->res[i] = lam * slc_acc_val(&tq) / s->wb[i];
        slc_acc_add(&acc, s->wb[i] * s->res[i] * s->res[i]);
    }
    /* Bänder von M^-1 (Hutchinson/de Hoog) */
    for (i = N - 1; i >= 0; i--) {
        l0 = ab[3 * i]; l1 = ab[3 * i + 1]; l2 = ab[3 * i + 2];
        s->S2[i] = (i + 2 < N) ? -(l1 * s->S1[i + 1] + l2 * s->S0[i + 2]) / l0 : 0.0;
        if (i + 1 < N) s->S1[i] = -(l1 * s->S0[i + 1] + (i + 2 < N ? l2 * s->S1[i + 1] : 0.0)) / l0;
        else s->S1[i] = 0.0;
        s->S0[i] = (1.0 / l0 - (i + 1 < N ? l1 * s->S1[i] : 0.0) - (i + 2 < N ? l2 * s->S2[i] : 0.0)) / l0;
    }
    /* lambda M^-1 P = I - M^-1 R: tr A = 2 + tr(M^-1 R) und 1 - tr A / n = lambda tr(M^-1 P) / n,
     * beides ohne Auslöschung (für großes bzw. kleines lambda) */
    slc_acc_init(&tr, 0.0);
    slc_acc_init(&trr, 0.0);
    for (a = 0; a < N; a++) {
        slc_acc_add(&tr, s->S0[a] * s->P0[a]);
        slc_acc_add(&trr, s->S0[a] * s->Rd[a]);
        if (a + 1 < N) { slc_acc_add(&tr, 2.0 * s->S1[a] * s->P1[a]); slc_acc_add(&trr, 2.0 * s->S1[a] * s->Ro[a]); }
        if (a + 2 < N) slc_acc_add(&tr, 2.0 * s->S2[a] * s->P2[a]);
    }
    *df = 2.0 + slc_acc_val(&trr);
    d = lam * slc_acc_val(&tr) / (double) nk;
    *gcv = (slc_acc_val(&acc) / (double) nk) / (d * d);
    if (!isfinite(*gcv)) *gcv = HUGE_VAL;
    return SL_OK;
}

/* Auswertung in der Suche: ist das Bandsystem numerisch nicht positiv definit (sehr großes
 * lambda bei vielen Knoten), zählt der Punkt als GCV = +Inf (kein Fehler) */
static int try_lambda(sl_ctx *cx, spl *s, double lam, double *gcv)
{
    double df;
    int st = fit_lambda(cx, s, lam, &df, gcv);
    if (st == SL_ENOTPD) { cx->status = SL_OK; cx->msg[0] = '\0'; *gcv = HUGE_VAL; return SL_OK; }
    return st;
}

/* Goldener Schnitt (Kiefer 1953) auf s in [a, b] bis zur Breite 1e-6; bester Punkt in (bs, bg) */
static int golden(sl_ctx *cx, spl *s, double a, double b, double *bs, double *bg)
{
    double phi = (sqrt(5.0) - 1.0) / 2.0, c, d, fc, fd;
    int st, it;
    c = b - phi * (b - a); d = a + phi * (b - a);
    if ((st = try_lambda(cx, s, s->r0 * pow(10.0, c), &fc)) != SL_OK) return st;
    if ((st = try_lambda(cx, s, s->r0 * pow(10.0, d), &fd)) != SL_OK) return st;
    if (fc < *bg) { *bg = fc; *bs = c; }
    if (fd < *bg) { *bg = fd; *bs = d; }
    for (it = 0; it < 200 && b - a > 1e-6; it++) {
        if (fc <= fd) {
            b = d; d = c; fd = fc; c = b - phi * (b - a);
            if ((st = try_lambda(cx, s, s->r0 * pow(10.0, c), &fc)) != SL_OK) return st;
            if (fc < *bg) { *bg = fc; *bs = c; }
        } else {
            a = c; c = d; fc = fd; d = a + phi * (b - a);
            if ((st = try_lambda(cx, s, s->r0 * pow(10.0, d), &fd)) != SL_OK) return st;
            if (fd < *bg) { *bg = fd; *bs = d; }
        }
    }
    return SL_OK;
}

int sl_smspline_fit(sl_ctx *cx, int n, const double *x, const double *y, const double *w,
                    double lambda, int *nk_out, double *knots, double *g, double *gam,
                    double *lambda_out, double *df_out, double *gcv_out)
{
    spl s;
    int64_t *idx = NULL, *wk = NULL;
    double *buf = NULL, xmin, xmax, tolx, x0, wi, lam, df, gcv, bs, bg, sl, sh;
    int i, p, q, k, nk, st = SL_OK, kb;
    slc_acc sw, sx, sy;
    double sgrid[25], ggrid[25];
    int used[25] = {0};
    if (n < 0) return sl_fail(cx, SL_EARG, "smooth.spline: negative Länge");
    if (isnan(lambda)) return sl_fail(cx, SL_EARG, "smooth.spline: lambda ist NaN");
    if (!slc_all_finite(n, x) || !slc_all_finite(n, y)) return sl_fail(cx, SL_ENONFINITE, "smooth.spline: NA/NaN/Inf in x oder y");
    if (w) {
        if (!slc_all_finite(n, w)) return sl_fail(cx, SL_ENONFINITE, "smooth.spline: NA/NaN/Inf in w");
        for (i = 0; i < n; i++) if (!(w[i] > 0.0)) return sl_fail(cx, SL_EARG, "smooth.spline: Gewichte müssen positiv sein");
    }
    if (n < 4) return sl_fail(cx, SL_ESMALL, "smooth.spline: mindestens 4 verschiedene x-Werte");
    idx = (int64_t *) malloc(sizeof(int64_t) * (size_t) n);
    wk = (int64_t *) malloc(sizeof(int64_t) * (size_t) n);
    buf = (double *) malloc(sizeof(double) * (size_t) n * 16);
    if (!idx || !wk || !buf) { st = sl_fail(cx, SL_ENOMEM, "smooth.spline: kein Speicher"); goto done; }
    slc_sort_index(n, x, idx, wk);
    xmin = x[idx[0]]; xmax = x[idx[n - 1]];
    tolx = 1e-6 * (xmax - xmin);
    s.t = buf; s.yb = buf + n; s.wb = buf + 2 * (size_t) n;
    nk = 0;
    for (p = 0; p < n; p = q) {
        x0 = x[idx[p]];
        slc_acc_init(&sw, 0.0); slc_acc_init(&sx, 0.0); slc_acc_init(&sy, 0.0);
        for (q = p; q < n && x[idx[q]] - x0 <= tolx; q++) {
            wi = w ? w[idx[q]] : 1.0;
            slc_acc_add(&sw, wi);
            slc_acc_add(&sx, wi * x[idx[q]]);
            slc_acc_add(&sy, wi * y[idx[q]]);
        }
        if (q == p + 1) { s.t[nk] = x0; s.yb[nk] = y[idx[p]]; s.wb[nk] = w ? w[idx[p]] : 1.0; }
        else {
            s.wb[nk] = slc_acc_val(&sw);
            s.t[nk] = slc_acc_val(&sx) / s.wb[nk];
            s.yb[nk] = slc_acc_val(&sy) / s.wb[nk];
        }
        nk++;
    }
    if (nk < 4) { st = sl_fail(cx, SL_ESMALL, "smooth.spline: mindestens 4 verschiedene x-Werte"); goto done; }
    s.nk = nk; s.N = nk - 2;
    s.h = buf + 3 * (size_t) n; s.qty = buf + 4 * (size_t) n; s.Rd = buf + 5 * (size_t) n; s.Ro = buf + 6 * (size_t) n;
    s.P0 = buf + 7 * (size_t) n; s.P1 = buf + 8 * (size_t) n; s.P2 = buf + 9 * (size_t) n;
    s.ab = buf + 10 * (size_t) n;   /* 3 n Plätze */
    s.gam = buf + 13 * (size_t) n; s.res = buf + 14 * (size_t) n;
    s.S0 = (double *) malloc(sizeof(double) * (size_t) n * 3);
    if (!s.S0) { st = sl_fail(cx, SL_ENOMEM, "smooth.spline: kein Speicher"); goto done; }
    s.S1 = s.S0 + n; s.S2 = s.S0 + 2 * (size_t) n;
    setup(&s);
    if (lambda > 0.0) {
        lam = lambda;
    } else {
        sl = -6.0; sh = 4.0 * log10((double) nk) + 4.0;
        kb = 0;
        for (k = 0; k < 25; k++) {
            sgrid[k] = sl + (sh - sl) * (double) k / 24.0;
            st = try_lambda(cx, &s, s.r0 * pow(10.0, sgrid[k]), &ggrid[k]);
            if (st != SL_OK) goto done2;
            if (ggrid[k] < ggrid[kb]) kb = k;
        }
        if (sl_interrupted(cx)) { st = SL_EINTR; goto done2; }
        bs = sgrid[kb]; bg = ggrid[kb];
        /* die (bis zu) drei kleinsten lokalen Minima des Rasters verfeinern */
        for (q = 0; q < 3; q++) {
            kb = -1;
            for (k = 0; k < 25; k++) {
                if (used[k] || !(ggrid[k] < HUGE_VAL)) continue;
                if ((k > 0 && ggrid[k - 1] < ggrid[k]) || (k < 24 && ggrid[k + 1] < ggrid[k])) continue;
                if (kb < 0 || ggrid[k] < ggrid[kb]) kb = k;
            }
            if (kb < 0) break;
            used[kb] = 1;
            st = golden(cx, &s, sgrid[kb > 0 ? kb - 1 : 0], sgrid[kb < 24 ? kb + 1 : 24], &bs, &bg);
            if (st != SL_OK) goto done2;
        }
        if (!(bg < HUGE_VAL)) { st = sl_fail(cx, SL_ENOTPD, "smooth.spline: kein lambda mit lösbarem Bandsystem"); goto done2; }
        lam = s.r0 * pow(10.0, bs);
    }
    if ((st = fit_lambda(cx, &s, lam, &df, &gcv)) != SL_OK) goto done2;
    *nk_out = nk;
    for (i = 0; i < nk; i++) {
        knots[i] = s.t[i];
        g[i] = s.yb[i] - s.res[i];
    }
    gam[0] = gam[nk - 1] = 0.0;
    for (i = 0; i < s.N; i++) gam[i + 1] = s.gam[i];
    if (lambda_out) *lambda_out = lam;
    if (df_out) *df_out = df;
    if (gcv_out) *gcv_out = gcv;
done2:
    free(s.S0);
done:
    free(idx); free(wk); free(buf);
    return st;
}

int sl_smspline_predict(sl_ctx *cx, int nk, const double *t, const double *g, const double *gam,
                        int nout, const double *xout, double *yout)
{
    int j, lo, hi, mid, i;
    double v, h, d1, d2, sl, na = slc_na_real();
    if (nk < 2) return sl_fail(cx, SL_ESMALL, "predict.smooth.spline: mindestens 2 Knoten nötig");
    if (nout < 0) return sl_fail(cx, SL_EARG, "predict.smooth.spline: negative Länge");
    for (i = 1; i < nk; i++)
        if (!(t[i] > t[i - 1])) return sl_fail(cx, SL_EARG, "predict.smooth.spline: Knoten müssen streng steigen");
    if (!slc_all_finite(nk, t) || !slc_all_finite(nk, g) || !slc_all_finite(nk, gam))
        return sl_fail(cx, SL_ENONFINITE, "predict.smooth.spline: NA/NaN/Inf im Spline");
    for (j = 0; j < nout; j++) {
        v = xout[j];
        if (isnan(v)) { yout[j] = na; continue; }
        if (v < t[0]) {
            h = t[1] - t[0];
            sl = (g[1] - g[0]) / h - h * gam[1] / 6.0;
            yout[j] = g[0] + (v - t[0]) * sl;
            continue;
        }
        if (v > t[nk - 1]) {
            h = t[nk - 1] - t[nk - 2];
            sl = (g[nk - 1] - g[nk - 2]) / h + h * gam[nk - 2] / 6.0;
            yout[j] = g[nk - 1] + (v - t[nk - 1]) * sl;
            continue;
        }
        lo = 0; hi = nk - 1;
        while (hi - lo > 1) {
            mid = lo + (hi - lo) / 2;
            if (t[mid] <= v) lo = mid; else hi = mid;
        }
        i = lo;
        h = t[i + 1] - t[i];
        d1 = v - t[i]; d2 = t[i + 1] - v;
        yout[j] = (d1 * g[i + 1] + d2 * g[i]) / h
                - d1 * d2 * ((1.0 + d1 / h) * gam[i + 1] + (1.0 + d2 / h) * gam[i]) / 6.0;
    }
    return SL_OK;
}
