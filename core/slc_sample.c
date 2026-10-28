/* core/slc_sample.c – Ziehungen: ganze Zahlen, Stichproben, normal, exponentiell, geometrisch,
 *                     Gamma, Chi-Quadrat (SimLev core, Etappe 9)
 * Verfahren:  ganze Zahl in [0, n): Multiplikation x * n (64 x 64 -> 128 Bit, portabel aus
 *             32-Bit-Hälften) mit Ablehnung, wenn der untere Teil < 2^64 mod n ist.
 *             Stichprobe ohne Zurücklegen: Fisher-Yates von vorn (für i = 0 ... size-1 ein
 *             j in [i, n) ziehen und tauschen). Mit Gewichten: Inversion über die kumulierten
 *             Gewichte (Neumaier-Summe in gegebener Reihenfolge), Suche durch Halbieren;
 *             ohne Zurücklegen je Ziehung neu über die verbliebenen Gewichte.
 *             Normal: Inversion z = qnorm(u), genau eine Gleichverteilte je Wert.
 *             Exponentiell: -log(u). Geometrisch (Zahl der Fehlschläge): floor(log(u) / log1p(-p)).
 *             Gamma(alpha >= 1): Marsaglia-Tsang mit d = alpha - 1/3, c = 1/sqrt(9 d), je Versuch
 *             eine Normal- und eine Gleichverteilte, Quetschtest u < 1 - 0.0331 x^4, sonst
 *             log(u) < x^2/2 + d (1 - v + log v). Gamma(alpha < 1) = Gamma(alpha + 1) u^(1/alpha).
 *             Chi-Quadrat(nu) = 2 Gamma(nu/2).
 * Quellen:    Lemire, D. (2019). Fast random integer generation in an interval. ACM Transactions
 *               on Modeling and Computer Simulation 29(1), 1–12; arXiv:1805.10941 (Algorithmus 5).
 *             Knuth, D. E. (1997). The Art of Computer Programming, Bd. 2: Seminumerical
 *               Algorithms, 3. Aufl., Addison-Wesley, §3.4.2, Algorithmus P.
 *             Devroye, L. (1986). Non-Uniform Random Variate Generation. Springer, New York;
 *               Kap. II.2 (Inversion), III.2 (diskrete Inversion, Suche), X.2 (geometrisch),
 *               IX (Chi-Quadrat über Gamma).
 *             Marsaglia, G., Tsang, W. W. (2000). A simple method for generating gamma variables.
 *               ACM Transactions on Mathematical Software 26(3), 363–372 (Verfahren, Quetsch-
 *               konstante 0.0331, Fall alpha < 1).
 *             Neumaier, A. (1974). Rundungsfehleranalyse einiger Verfahren zur Summation endlicher
 *               Summen. ZAMM 54(1), 39–51.
 * Konstanten: 0.0331 und 1/3 aus Marsaglia/Tsang (2000); sonst keine.
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: Momente, KS- und Chi-Quadrat-Tests (scratchpad/e91/).
 */
#include "slc_internal.h"

#include <stdlib.h>

/* ── ganze Zahl in [0, n) (Lemire 2019, Alg. 5) ── */

static uint64_t mul128(uint64_t a, uint64_t b, uint64_t *lo)
{
    const uint64_t M = UINT64_C(0xffffffff);
    uint64_t a0 = a & M, a1 = a >> 32, b0 = b & M, b1 = b >> 32;
    uint64_t p00 = a0 * b0, p01 = a0 * b1, p10 = a1 * b0, p11 = a1 * b1;
    uint64_t mid = (p00 >> 32) + (p01 & M) + (p10 & M);
    *lo = (mid << 32) | (p00 & M);
    return p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
}

int64_t sl_rint(sl_rng *r, int64_t n)
{
    uint64_t s = (uint64_t) n, lo, hi;
    hi = mul128(sl_rng_next(r), s, &lo);
    if (lo < s) {
        uint64_t t = (UINT64_C(0) - s) % s;        /* 2^64 mod s */
        while (lo < t) hi = mul128(sl_rng_next(r), s, &lo);
    }
    return (int64_t) hi;
}

/* ── Gewichte ── */

/* kumulierte Summen nach Neumaier; cum[i] = w[0] + ... + w[i] */
static void cumsum_neumaier(int64_t n, const double *w, double *cum)
{
    double s = 0.0, c = 0.0;
    int64_t i;
    for (i = 0; i < n; i++) {
        double t = s + w[i];
        if (fabs(s) >= fabs(w[i])) c += (s - t) + w[i];
        else c += (w[i] - t) + s;
        s = t;
        cum[i] = s + c;
    }
}

/* kleinster Index i mit cum[i] > target; sonst der letzte Index mit Gewicht > 0 */
static int64_t search_cum(int64_t n, const double *cum, const double *w, double target)
{
    int64_t lo = 0, hi = n;            /* Ergebnis in [lo, hi) */
    while (lo < hi) {
        int64_t mid = lo + (hi - lo) / 2;
        if (cum[mid] > target) hi = mid;
        else lo = mid + 1;
    }
    if (lo >= n) {                     /* Rundung u * total == total */
        lo = n - 1;
        while (lo > 0 && !(w[lo] > 0)) lo--;
    }
    return lo;
}

int sl_sample(sl_ctx *cx, sl_rng *r, int64_t n, int64_t size, int replace,
              const double *prob, int32_t *out)
{
    int64_t i, j;
    if (n < 0 || size < 0) return sl_fail(cx, SL_EARG, "sample: ungültige Größe");
    if (n > INT32_MAX) return sl_fail(cx, SL_EARG, "sample: Grundgesamtheit zu groß (höchstens 2^31 - 1)");
    if (size == 0) return SL_OK;
    if (n == 0) return sl_fail(cx, SL_EARG, "sample: leere Grundgesamtheit");
    if (!replace && size > n)
        return sl_fail(cx, SL_EARG, "sample: Stichprobe größer als die Grundgesamtheit (replace = FALSE)");

    if (prob == NULL) {
        if (replace || size == 1) {
            for (i = 0; i < size; i++) {
                out[i] = (int32_t) (1 + sl_rint(r, n));
                SL_POLL(cx, i);
            }
            return SL_OK;
        }
        {
            int32_t *perm = (int32_t *) malloc((size_t) n * sizeof(int32_t));
            if (perm == NULL) return sl_fail(cx, SL_ENOMEM, "sample: kein Speicher");
            for (i = 0; i < n; i++) perm[i] = (int32_t) (i + 1);
            for (i = 0; i < size; i++) {
                int32_t tmp;
                j = i + sl_rint(r, n - i);
                tmp = perm[i]; perm[i] = perm[j]; perm[j] = tmp;
                out[i] = perm[i];
                if ((((i) + 1) & 0xFFFF) == 0 && sl_interrupted(cx)) { free(perm); return SL_EINTR; }
            }
            free(perm);
            return SL_OK;
        }
    }

    /* mit Gewichten */
    {
        int64_t npos = 0;
        double *cum, *w;
        for (i = 0; i < n; i++) {
            if (!(isfinite(prob[i]) && prob[i] >= 0)) return sl_fail(cx, SL_EARG, "sample: ungültige Gewichte");
            if (prob[i] > 0) npos++;
        }
        if (npos == 0) return sl_fail(cx, SL_EARG, "sample: ungültige Gewichte");
        if (!replace && size > npos)
            return sl_fail(cx, SL_EARG, "sample: zu wenige positive Gewichte für eine Stichprobe ohne Zurücklegen");
        cum = (double *) malloc((size_t) n * sizeof(double));
        w = (double *) malloc((size_t) n * sizeof(double));
        if (cum == NULL || w == NULL) { free(cum); free(w); return sl_fail(cx, SL_ENOMEM, "sample: kein Speicher"); }
        for (i = 0; i < n; i++) w[i] = prob[i];
        cumsum_neumaier(n, w, cum);
        for (i = 0; i < size; i++) {
            double total = cum[n - 1];
            int64_t k = search_cum(n, cum, w, sl_unif01(r) * total);
            out[i] = (int32_t) (k + 1);
            if (!replace && i + 1 < size) {
                w[k] = 0.0;
                cumsum_neumaier(n, w, cum);
            }
            if ((((i) + 1) & 0xFFFF) == 0 && sl_interrupted(cx)) { free(cum); free(w); return SL_EINTR; }
        }
        free(cum);
        free(w);
        return SL_OK;
    }
}

/* ── stetige Verteilungen ── */

static void fill_nan_warn(sl_ctx *cx, int64_t n, double *out, const char *fn)
{
    int64_t i;
    for (i = 0; i < n; i++) out[i] = NAN;
    if (n > 0) sl_warn(cx, "%s: NaN erzeugt", fn);
}

int sl_rnorm(sl_ctx *cx, sl_rng *r, int64_t n, double mu, double sd, double *out)
{
    int64_t i;
    if (!(isfinite(mu) && isfinite(sd) && sd >= 0)) { fill_nan_warn(cx, n, out, "rnorm"); return SL_OK; }
    for (i = 0; i < n; i++) {
        out[i] = mu + sd * slc_qnorm_std(sl_unif01(r), 1);
        SL_POLL(cx, i);
    }
    return SL_OK;
}

int sl_rexp(sl_ctx *cx, sl_rng *r, int64_t n, double rate, double *out)
{
    int64_t i;
    if (!(rate > 0)) { fill_nan_warn(cx, n, out, "rexp"); return SL_OK; }
    for (i = 0; i < n; i++) {
        out[i] = -log(sl_unif01(r)) / rate;
        SL_POLL(cx, i);
    }
    return SL_OK;
}

int sl_rgeom(sl_ctx *cx, sl_rng *r, int64_t n, double p, double *out)
{
    int64_t i;
    double lq;
    if (!(p > 0 && p <= 1)) { fill_nan_warn(cx, n, out, "rgeom"); return SL_OK; }
    lq = log1p(-p);                     /* p = 1: -Inf, Ergebnis 0 */
    for (i = 0; i < n; i++) {
        double u = sl_unif01(r);
        out[i] = (p == 1) ? 0.0 : floor(log(u) / lq);
        SL_POLL(cx, i);
    }
    return SL_OK;
}

/* Marsaglia-Tsang für alpha >= 1 (Einheitsskala) */
static double gamma_mt(sl_rng *r, double alpha)
{
    const double d = alpha - 1.0 / 3.0, c = 1.0 / sqrt(9.0 * d);
    for (;;) {
        double x, v, u;
        do {
            x = slc_qnorm_std(sl_unif01(r), 1);
            v = 1.0 + c * x;
        } while (v <= 0.0);
        v = v * v * v;
        u = sl_unif01(r);
        if (u < 1.0 - 0.0331 * (x * x) * (x * x)) return d * v;
        if (log(u) < 0.5 * x * x + d * (1.0 - v + log(v))) return d * v;
    }
}

static double gamma_draw(sl_rng *r, double alpha)
{
    if (alpha >= 1.0) return gamma_mt(r, alpha);
    {
        double g = gamma_mt(r, alpha + 1.0);
        double u = sl_unif01(r);
        return g * pow(u, 1.0 / alpha);
    }
}

int sl_rgamma(sl_ctx *cx, sl_rng *r, int64_t n, double shape, double scale, double *out)
{
    int64_t i;
    if (!(shape > 0 && isfinite(shape) && scale > 0 && isfinite(scale))) {
        fill_nan_warn(cx, n, out, "rgamma");
        return SL_OK;
    }
    for (i = 0; i < n; i++) {
        out[i] = scale * gamma_draw(r, shape);
        SL_POLL(cx, i);
    }
    return SL_OK;
}

int sl_rchisq(sl_ctx *cx, sl_rng *r, int64_t n, double df, double *out)
{
    int64_t i;
    if (!(df > 0 && isfinite(df))) { fill_nan_warn(cx, n, out, "rchisq"); return SL_OK; }
    for (i = 0; i < n; i++) {
        out[i] = 2.0 * gamma_draw(r, 0.5 * df);
        SL_POLL(cx, i);
    }
    return SL_OK;
}
