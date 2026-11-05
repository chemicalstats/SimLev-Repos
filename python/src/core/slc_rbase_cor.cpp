/* core/slc_rbase_cor.cpp – cor/cov mit Rangverfahren, cov2cor und scale mit R-Regeln (SimLev core, seit 1.6.0)
 * Verfahren:  - cor/cov(x, y, use, method): pearson direkt über sl_r_cov (slc_rbase_cov.cpp); kendall und spearman
 *               über die Ränge je Spalte (Mittelränge, NA bleibt NA; eine Zeile einer Matrix: Rang 1) wie ?cor:
 *               complete.obs/na.or.complete erst ohne die Zeilen mit NA, pairwise.complete.obs je Spaltenpaar über
 *               die gemeinsamen Werte (nur cor; Ergebnis r + t(r) − diag(diag(r)) ohne y).
 *             - cov2cor: D^(−1/2) V D^(−1/2) mit Is = sqrt(1/diag) für positive Diagonale, sonst NaN und Warnung;
 *               Ergebnis NA genau dort, wo V NA ist, jedes andere NaN ist NaN; Diagonale 1 (?cov2cor).
 *             - scale: Zentrieren mit colMeans(x, na.rm = TRUE) bzw. vorgegebenen Werten, Skalieren mit
 *               sqrt(sum(v^2)/max(1, n − 1)) über die Werte ohne NA bzw. vorgegebenen Werten (?scale).
 * Quellen:    R-Hilfeseiten (R 4.3.3) ?cor, ?cov2cor, ?scale, ?rank, ?colMeans.
 * Konstanten: keine.
 * Herkunft:           übersetzt aus R 4.3.3, src/library/stats/R/cor.R, cov2cor in cor.R, src/library/base/R/scale.R
 *                     über die Port-Funktionen python/simlev/_r/stats_cor.py (_cor_cov, _corcov, _rank_cols,
 *                     cov2cor, scale) und julia/src/r/stats_cor.jl (bis 1.5.2)
 * Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut Kopf der
 *                     jeweiligen R-Quelle)
 * Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
 * Änderungen:         C++ im gemeinsamen Teil von C und C++, ohne R-Datenstrukturen, gemeinsamer Kern für Python und
 *                     Julia (nicht Teil des R-Pakets).
 * Prüforakel: R 1.5.2 von SimLev (stats::cor, cov, cov2cor, base::scale; Gleichlauf cor_fuzz.R).
 */
#include "slc_internal.h"
#include "slc_rbase2.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

static double bits_d(uint64_t u)
{
    double d;
    memcpy(&d, &u, sizeof d);
    return d;
}

static int is_na(double x)
{
    uint64_t u;
    if (!isnan(x)) return 0;
    memcpy(&u, &x, sizeof u);
    return (u & UINT64_C(0xFFFFFFFF)) == 1954;
}

#define R_NA bits_d(UINT64_C(0x7FF00000000007A2))
#define R_NAN bits_d(UINT64_C(0x7FF8000000000000))

/* _corcov: Prüfungen wie die Ports, dann sl_r_cov */
static int corcov(sl_ctx *cx, int64_t n, int64_t ncx, const double *x, int64_t ncy, const double *y, int use,
                  int kendall, int cor, double *ans, int *sd0)
{
    int s0 = 0, st;
    if (use == 2 && n * ncx == 0) return sl_fail(cx, SL_EARG, "no complete element pairs");
    if ((use == 1 || use == 2 || use == 3) && n * ncx == 0) return sl_fail(cx, SL_EARG, "'x' is empty");
    st = sl_r_cov(cx, n, ncx, x, ncy, y, use, kendall, cor, ans, &s0);
    if (s0) *sd0 = 1;
    return st;
}

/* Ränge einer Spalte (Mittelränge), NA bleibt NA; out darf nicht x sein */
static int rank_keep(int64_t n, const double *x, double *out, double *w1, double *w2)
{
    int64_t i, m = 0;
    for (i = 0; i < n; i++)
        if (!isnan(x[i])) w1[m++] = x[i];
    if (m > 0 && sl_r_rank(m, w1, 0, w2)) return SL_ENOMEM;
    m = 0;
    for (i = 0; i < n; i++) out[i] = isnan(x[i]) ? R_NA : w2[m++];
    return 0;
}

/* Rank(u): je Spalte rank(na.last = "keep"); Matrix mit einer Zeile: row(u) = 1 */
static int rank_cols(int64_t n, int64_t nc, const double *x, int mat, double *out, double *w1, double *w2)
{
    int64_t j;
    if (mat && n == 1) {
        for (j = 0; j < nc; j++) out[j] = 1.0;
        return 0;
    }
    for (j = 0; j < nc; j++)
        if (rank_keep(n, x + j * n, out + j * n, w1, w2)) return SL_ENOMEM;
    return 0;
}

int sl_r_cor(sl_ctx *cx, int64_t n, int64_t ncx, const double *x, int xmat, int64_t ncy, const double *y, int ymat,
             int use, int method, int cor, double *ans, int *sd0)
{
    int kend = method == 1, st = 0;
    int64_t i, j, k, nn;
    double *rx = NULL, *ry = NULL, *w1 = NULL, *w2 = NULL, *a = NULL, *b = NULL;
    *sd0 = 0;
    if (use < 1 || use > 5) return sl_fail(cx, SL_EARG, "invalid 'use' (computational method)");
    if (method == 0) return corcov(cx, n, ncx, x, ncy, y, use, 0, cor, ans, sd0);
    if (y == NULL) ncy = ncx;
    if (use == 3 && !cor) return sl_fail(cx, SL_EARG, "cannot handle 'pairwise.complete.obs'");
    if (use == 3 && y == NULL && ncx == 0) return sl_fail(cx, SL_EARG, "'x' is empty");
    if (use == 3 && y != NULL && (n * ncx == 0 || n * ncy == 0))
        return sl_fail(cx, SL_EARG, "both 'x' and 'y' must be non-empty");
    nn = n > 0 ? n : 1;
    rx = (double *) malloc((size_t) (nn * (ncx > 0 ? ncx : 1)) * sizeof(double));
    ry = (double *) malloc((size_t) (nn * (ncy > 0 ? ncy : 1)) * sizeof(double));
    w1 = (double *) malloc((size_t) nn * sizeof(double));
    w2 = (double *) malloc((size_t) nn * sizeof(double));
    a = (double *) malloc((size_t) nn * sizeof(double));
    b = (double *) malloc((size_t) nn * sizeof(double));
    if (!rx || !ry || !w1 || !w2 || !a || !b) { st = SL_ENOMEM; goto done; }
    if (use == 2 || use == 5) {
        /* na.omit (bzw. dropNA über cbind(x, y)), dann Rank */
        int64_t m = 0;
        for (i = 0; i < n; i++) {
            int ok = 1;
            for (j = 0; j < ncx && ok; j++) ok = !isnan(x[i + j * n]);
            if (y) for (j = 0; j < ncy && ok; j++) ok = !isnan(y[i + j * n]);
            if (!ok) continue;
            for (j = 0; j < ncx; j++) rx[m + j * n] = x[i + j * n];
            if (y) for (j = 0; j < ncy; j++) ry[m + j * n] = y[i + j * n];
            m++;
        }
        /* kompakt spaltenweise mit Länge m */
        for (j = 1; j < ncx; j++) memmove(rx + j * m, rx + j * n, (size_t) m * sizeof(double));
        if (y) for (j = 1; j < ncy; j++) memmove(ry + j * m, ry + j * n, (size_t) m * sizeof(double));
        if (m > 0) {
            int64_t cmax = ncx > ncy ? ncx : ncy;
            double *tx = (double *) malloc((size_t) (m * (cmax > 0 ? cmax : 1)) * sizeof(double));
            if (!tx) { st = SL_ENOMEM; goto done; }
            if (rank_cols(m, ncx, rx, xmat, tx, w1, w2)) { free(tx); st = SL_ENOMEM; goto done; }
            for (i = 0; i < m * ncx; i++) rx[i] = tx[i];
            if (y) {
                if (rank_cols(m, ncy, ry, ymat, tx, w1, w2)) { free(tx); st = SL_ENOMEM; goto done; }
                for (i = 0; i < m * ncy; i++) ry[i] = tx[i];
            }
            free(tx);
        }
        st = corcov(cx, m, ncx, rx, ncy, y ? ry : NULL, use, kend, cor, ans, sd0);
        goto done;
    }
    if (use != 3) {
        if (n * ncx > 0 && rank_cols(n, ncx, x, xmat, rx, w1, w2)) { st = SL_ENOMEM; goto done; }
        if (y && n * ncy > 0 && rank_cols(n, ncy, y, ymat, ry, w1, w2)) { st = SL_ENOMEM; goto done; }
        st = corcov(cx, n, ncx, rx, ncy, y ? ry : NULL, use, kend, cor, ans, sd0);
        goto done;
    }
    /* paarweise: je Paar die gemeinsamen Werte ranken, cor mit use = all.obs */
    {
        const double *Y = y ? y : x;
        for (i = 0; i < ncx; i++) {
            for (j = 0; j < (y ? ncy : i + 1); j++) {
                const double *x2 = x + i * n, *y2 = Y + j * n;
                int64_t m = 0;
                double r;
                for (k = 0; k < n; k++) {
                    if (isnan(x2[k]) || isnan(y2[k])) continue;
                    a[m] = x2[k];
                    b[m] = y2[k];
                    m++;
                }
                if (m == 0) {
                    r = R_NA;
                } else {
                    if (sl_r_rank(m, a, 0, rx) || sl_r_rank(m, b, 0, ry)) { st = SL_ENOMEM; goto done; }
                    st = corcov(cx, m, 1, rx, 1, ry, 1, kend, 1, &r, sd0);
                    if (st) goto done;
                }
                ans[i + j * ncx] = r;
            }
            if (!y)
                for (j = i + 1; j < ncx; j++) ans[i + j * ncx] = 0.0;
        }
        if (!y && ncx > 1) {
            /* r + t(r) - diag(diag(r)) */
            int64_t q = ncx * ncx;
            double *rr = (double *) malloc((size_t) q * sizeof(double));
            if (!rr) { st = SL_ENOMEM; goto done; }
            memcpy(rr, ans, (size_t) q * sizeof(double));
            for (i = 0; i < ncx; i++)
                for (j = 0; j < ncx; j++)
                    ans[i + j * ncx] = (rr[i + j * ncx] + rr[j + i * ncx]) - (i == j ? rr[i + i * ncx] : 0.0);
            free(rr);
        }
    }
done:
    free(rx); free(ry); free(w1); free(w2); free(a); free(b);
    if (st == SL_ENOMEM) return sl_fail(cx, SL_ENOMEM, "out of memory");
    return st;
}

void sl_r_cov2cor(int64_t p, const double *v, double *out, int *warn)
{
    int64_t i, j;
    double *is = (double *) malloc((size_t) (p > 0 ? p : 1) * sizeof(double));
    *warn = 0;
    if (!is) return;
    for (i = 0; i < p; i++) {
        double d = v[i + i * p];
        if (!isnan(d) && d > 0) {
            is[i] = sqrt(1.0 / d);
            if (!isfinite(is[i])) *warn = 1;
        } else {
            is[i] = R_NAN;
            *warn = 1;
        }
    }
    for (j = 0; j < p; j++)
        for (i = 0; i < p; i++) {
            double a = v[i + j * p], r = (is[i] * a) * is[j];
            if (is_na(a)) r = R_NA;
            else if (isnan(r)) r = R_NAN;
            out[i + j * p] = r;
        }
    for (i = 0; i < p; i++) out[i + i * p] = 1.0;
    free(is);
}

int sl_r_scale(int64_t nr, int64_t nc, double *x, int center, double *cen, int scale, double *sc)
{
    int64_t i, j;
    double *v;
    if (center == 1) sl_r_colsums(nr, nc, x, 1, 1, cen);
    if (center)
        for (j = 0; j < nc; j++)
            for (i = 0; i < nr; i++) x[i + j * nr] = x[i + j * nr] - cen[j];
    if (scale == 1) {
        v = (double *) malloc((size_t) (nr > 0 ? nr : 1) * sizeof(double));
        if (!v) return SL_ENOMEM;
        for (j = 0; j < nc; j++) {
            int64_t m = 0;
            for (i = 0; i < nr; i++) {
                double t = x[i + j * nr];
                if (!isnan(t)) { v[m] = t * t; m++; }
            }
            sc[j] = sqrt(sl_r_sum(m, v, 0) / (double) (m - 1 > 1 ? m - 1 : 1));
        }
        free(v);
    }
    if (scale)
        for (j = 0; j < nc; j++)
            for (i = 0; i < nr; i++) x[i + j * nr] = x[i + j * nr] / sc[j];
    return 0;
}
