/* core/slc_rbase_cov.cpp – cov/cor mit R-Regeln (SimLev core)
 * Verfahren:  Kovarianz bzw. Korrelation je Spaltenpaar wie ?cor beschreibt:
 *             - pearson: Mittel je Spalte in long double (Summe/n, Korrekturdurchlauf bei endlichem
 *               Zwischenwert), als double gespeichert; Kreuzsumme Σ(x_i − m_x)(y_i − m_y) in long
 *               double, durch n − 1. Bei use = "pairwise.complete.obs" je Paar über die gemeinsamen
 *               Beobachtungen, Mittel dort in long double ohne Korrektur und ohne Rundung auf double,
 *               Korrelation in long double.
 *             - kendall: Σ sign(x_k − x_j) sign(y_k − y_j) über alle geordneten Paare (bei
 *               pairwise über k > j), Standardisierung mit der Anzahl verschiedener Paare.
 *             - cor: Division durch das Produkt der Standardabweichungen, auf [−1, 1] begrenzt;
 *               Standardabweichung null ergibt NA und die Warnung des Hosts.
 *             - use: all.obs (Fehler bei fehlenden Werten), complete.obs/na.or.complete (nur
 *               vollständige Zeilen), pairwise.complete.obs, everything (NA für Spalten mit NA).
 *             Spearman rechnet der Host über die Ränge (?cor) mit diesem Kern (pearson).
 * Quellen:    R-Hilfeseite ?cor (R 4.3.3); Kendall, M. G. (1938). A new measure of rank correlation.
 *             Biometrika 30, 81–93.
 *             use = "everything", kendall, cor: für Paare mit einer NA-Spalte liest R ein nicht
 *             gesetztes Hilfsfeld; das Ergebnis ist NA, aber ob still oder signalisierend, hängt dort
 *             vom Speicherinhalt ab. Der Kern teilt wie bei pearson (stilles NA, Logik der Ports).
 * Konstanten: keine.
 * long double: absichtlich (siehe slc_rbase.h): nur so gleich zu R auf derselben Plattform.
 * Herkunft:           übersetzt aus R 4.3.3, src/library/stats/src/cov.c, über die Port-Funktionen
 *                     python/simlev/_r/stats_cor.py und julia/src/r/stats_cor.jl
 * Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation
 *                     (laut Kopf der jeweiligen R-Quelle)
 * Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
 * Änderungen:         C99 ohne R-Datenstrukturen, gemeinsamer Kern für Python und Julia (nicht Teil
 *                     des R-Pakets); bei use = "everything" mit NA-Spalte stilles NA statt des
 *                     speicherabhängigen Ergebnisses von R (siehe Quellen).
 * Prüforakel: R 4.3.3 (Gleichlauf: rbase_fuzz.R).
 */
#include "slc_internal.h"
#include "slc_rbase.h"

#include <stdlib.h>
#include <string.h>

typedef long double ldouble;

static double bits_d(uint64_t u)
{
    double d;
    memcpy(&d, &u, sizeof d);
    return d;
}

#define R_NA  bits_d(UINT64_C(0x7FF00000000007A2))
#define R_NAN bits_d(UINT64_C(0x7FF8000000000000))

/* sign(a) * sign(b) für Differenzen a, b: NaN bleibt NaN mit seinem Vorzeichen (eine NaN-Differenz,
 * etwa Inf - Inf, setzt sich wie bei der Multiplikation durch; ausdrücklich, damit der Compiler das
 * Produkt mit -1 nicht als Vorzeichenwechsel übersetzt, der das Vorzeichen des NaN umdreht) */
static double sgnprod(double a, double b)
{
    if (isnan(a)) return a;
    if (isnan(b)) return b;
    if (a == 0 || b == 0) return 0.0;
    return ((a > 0) == (b > 0)) ? 1.0 : -1.0;
}
static double clamp1(double v) { return v >= 1.0 ? 1.0 : (v <= -1.0 ? -1.0 : v); }

/* Zeilen rows[0..m-1] (NULL: alle n) */
#define ROW(r, t) ((r) ? (r)[t] : (t))

static double mean_rows(const double *c, const int64_t *rows, int64_t m)
{
    ldouble s = 0.0L, t, lm = (ldouble) m;
    int64_t k;
    for (k = 0; k < m; k++) s += c[ROW(rows, k)];
    t = s / lm;
    if (isfinite((double) t)) {
        s = 0.0L;
        for (k = 0; k < m; k++) s += (c[ROW(rows, k)] - t);
        t = t + s / lm;
    }
    return (double) t;
}

static ldouble cross(const double *a, double am, const double *b, double bm, const int64_t *rows, int64_t m)
{
    ldouble s = 0.0L;
    int64_t k;
    for (k = 0; k < m; k++) {
        int64_t r = ROW(rows, k);
        s += ((ldouble) a[r] - (ldouble) am) * ((ldouble) b[r] - (ldouble) bm);
    }
    return s;
}

static double kendall_sum(const double *a, const double *b, const int64_t *rows, int64_t m)
{
    ldouble s = 0.0L;
    int64_t k, j;
    for (k = 0; k < m; k++) {
        int64_t rk = ROW(rows, k);
        for (j = 0; j < m; j++) {
            int64_t rj = ROW(rows, j);
            s += sgnprod(a[rk] - a[rj], b[rk] - b[rj]);
        }
    }
    return (double) s;
}

static double kendall_ne(const double *a, const int64_t *rows, int64_t m)
{
    int64_t k, j, c = 0;
    for (k = 0; k < m; k++)
        for (j = 0; j < m; j++) c += a[ROW(rows, k)] != a[ROW(rows, j)];
    return (double) c;
}

/* Standardabweichung (cov_complete2/cov_na_2): (double) sqrtl(Σ/(n−1)) bzw. sqrtl(Anzahl) */
static double sdev2(const double *c, double m, int64_t n1, int kendall, const int64_t *rows, int64_t mm)
{
    ldouble s;
    if (!kendall) s = cross(c, m, c, m, rows, mm) / (ldouble) n1;
    else s = (ldouble) kendall_ne(c, rows, mm);
    return (double) sqrtl(s);
}

/* ein Satz x (symmetrisch) über die Zeilen rows (vollständige) */
static void cov_complete1(int64_t n, int64_t ncx, const double *x, const int64_t *rows, int64_t nobs,
                          double *ans, double *xm, int *sd0, int cor, int kendall)
{
    int64_t i, j, n1 = nobs - 1;
    (void) n;
    if (nobs <= 1) {
        for (i = 0; i < ncx * ncx; i++) ans[i] = R_NA;
        return;
    }
    if (!kendall)
        for (i = 0; i < ncx; i++) xm[i] = mean_rows(x + i * n, rows, nobs);
    for (i = 0; i < ncx; i++)
        for (j = 0; j <= i; j++) {
            double v;
            if (!kendall) v = (double) (cross(x + i * n, xm[i], x + j * n, xm[j], rows, nobs) / (ldouble) n1);
            else v = kendall_sum(x + i * n, x + j * n, rows, nobs);
            ans[i + j * ncx] = ans[j + i * ncx] = v;
        }
    if (cor) {
        for (i = 0; i < ncx; i++) xm[i] = sqrt(ans[i + i * ncx]);
        for (i = 0; i < ncx; i++) {
            for (j = 0; j < i; j++) {
                if (xm[i] == 0 || xm[j] == 0) {
                    *sd0 = 1;
                    ans[i + j * ncx] = ans[j + i * ncx] = R_NA;
                } else {
                    ans[i + j * ncx] = ans[j + i * ncx] = clamp1(ans[i + j * ncx] / (xm[i] * xm[j]));
                }
            }
            ans[i + i * ncx] = 1.0;
        }
    }
}

static void cov_na_1(int64_t n, int64_t ncx, const double *x, const int *has_na, double *ans, double *xm,
                     int *sd0, int cor, int kendall)
{
    int64_t i, j, n1 = n - 1;
    if (n <= 1) {
        for (i = 0; i < ncx * ncx; i++) ans[i] = R_NA;
        return;
    }
    for (i = 0; i < ncx; i++) xm[i] = R_NAN;
    if (!kendall)
        for (i = 0; i < ncx; i++) xm[i] = has_na[i] ? R_NA : mean_rows(x + i * n, NULL, n);
    for (i = 0; i < ncx; i++) {
        if (has_na[i]) {
            for (j = 0; j <= i; j++) ans[i + j * ncx] = ans[j + i * ncx] = R_NA;
            continue;
        }
        for (j = 0; j <= i; j++) {
            double v;
            if (has_na[j]) v = R_NA;
            else if (!kendall) v = (double) (cross(x + i * n, xm[i], x + j * n, xm[j], NULL, n) / (ldouble) n1);
            else v = kendall_sum(x + i * n, x + j * n, NULL, n);
            ans[i + j * ncx] = ans[j + i * ncx] = v;
        }
    }
    if (cor) {
        for (i = 0; i < ncx; i++)
            if (!has_na[i]) xm[i] = sqrt(ans[i + i * ncx]);
        for (i = 0; i < ncx; i++) {
            if (!has_na[i])
                for (j = 0; j < i; j++) {
                    if (xm[i] == 0 || xm[j] == 0) {
                        *sd0 = 1;
                        ans[i + j * ncx] = ans[j + i * ncx] = R_NA;
                    } else {
                        ans[i + j * ncx] = ans[j + i * ncx] = clamp1(ans[i + j * ncx] / (xm[i] * xm[j]));
                    }
                }
            ans[i + i * ncx] = 1.0;
        }
    }
}

static void cov_complete2(int64_t n, int64_t ncx, const double *x, int64_t ncy, const double *y,
                          const int64_t *rows, int64_t nobs, double *ans, double *xm, double *ym,
                          int *sd0, int cor, int kendall)
{
    int64_t i, j, n1 = nobs - 1;
    if (nobs <= 1) {
        for (i = 0; i < ncx * ncy; i++) ans[i] = R_NA;
        return;
    }
    for (i = 0; i < ncx; i++) xm[i] = 0.0;
    for (i = 0; i < ncy; i++) ym[i] = 0.0;
    if (!kendall) {
        for (i = 0; i < ncx; i++) xm[i] = mean_rows(x + i * n, rows, nobs);
        for (i = 0; i < ncy; i++) ym[i] = mean_rows(y + i * n, rows, nobs);
    }
    for (i = 0; i < ncx; i++)
        for (j = 0; j < ncy; j++) {
            if (!kendall) ans[i + j * ncx] = (double) (cross(x + i * n, xm[i], y + j * n, ym[j], rows, nobs) / (ldouble) n1);
            else ans[i + j * ncx] = kendall_sum(x + i * n, y + j * n, rows, nobs);
        }
    if (cor) {
        double *xs = xm, *ys = ym;        /* Mittel werden danach nicht mehr gebraucht */
        for (i = 0; i < ncx; i++) xs[i] = sdev2(x + i * n, xm[i], n1, kendall, rows, nobs);
        for (j = 0; j < ncy; j++) ys[j] = sdev2(y + j * n, ym[j], n1, kendall, rows, nobs);
        for (i = 0; i < ncx; i++)
            for (j = 0; j < ncy; j++) {
                if (xs[i] == 0.0 || ys[j] == 0.0) { *sd0 = 1; ans[i + j * ncx] = R_NA; }
                else ans[i + j * ncx] = clamp1(ans[i + j * ncx] / (xs[i] * ys[j]));
            }
    }
}

static void cov_na_2(int64_t n, int64_t ncx, const double *x, int64_t ncy, const double *y,
                     const int *hx, const int *hy, double *ans, double *xm, double *ym, int *sd0,
                     int cor, int kendall)
{
    int64_t i, j, n1 = n - 1;
    if (n <= 1) {
        for (i = 0; i < ncx * ncy; i++) ans[i] = R_NA;
        return;
    }
    for (i = 0; i < ncx; i++) xm[i] = 0.0;
    for (i = 0; i < ncy; i++) ym[i] = 0.0;
    if (!kendall) {
        for (i = 0; i < ncx; i++) xm[i] = hx[i] ? R_NA : mean_rows(x + i * n, NULL, n);
        for (i = 0; i < ncy; i++) ym[i] = hy[i] ? R_NA : mean_rows(y + i * n, NULL, n);
    }
    for (i = 0; i < ncx; i++) {
        if (hx[i]) { for (j = 0; j < ncy; j++) ans[i + j * ncx] = R_NA; continue; }
        for (j = 0; j < ncy; j++) {
            if (hy[j]) ans[i + j * ncx] = R_NA;
            else if (!kendall) ans[i + j * ncx] = (double) (cross(x + i * n, xm[i], y + j * n, ym[j], NULL, n) / (ldouble) n1);
            else ans[i + j * ncx] = kendall_sum(x + i * n, y + j * n, NULL, n);
        }
    }
    if (cor) {
        double *xs = xm, *ys = ym;
        for (i = 0; i < ncx; i++) xs[i] = hx[i] ? R_NA : sdev2(x + i * n, xm[i], n1, kendall, NULL, n);
        for (j = 0; j < ncy; j++) ys[j] = hy[j] ? R_NA : sdev2(y + j * n, ym[j], n1, kendall, NULL, n);
        for (i = 0; i < ncx; i++) {
            if (hx[i]) continue;
            for (j = 0; j < ncy; j++) {
                if (hy[j]) continue;
                if (xs[i] == 0.0 || ys[j] == 0.0) { *sd0 = 1; ans[i + j * ncx] = R_NA; }
                else ans[i + j * ncx] = clamp1(ans[i + j * ncx] / (xs[i] * ys[j]));
            }
        }
    }
}

static void cov_pairwise(int64_t n, int64_t ncx, const double *x, int64_t ncy, const double *y,
                         int64_t *rows, double *ans, int *sd0, int cor, int kendall, int sym)
{
    int64_t i, j, k, t, nobs;
    for (i = 0; i < ncx; i++) {
        int64_t jmax = sym ? i + 1 : ncy;
        for (j = 0; j < jmax; j++) {
            const double *xx = x + i * n, *yy = y + j * n;
            double val;
            nobs = 0;
            for (k = 0; k < n; k++) if (!isnan(xx[k]) && !isnan(yy[k])) rows[nobs++] = k;
            if (nobs >= 2) {
                ldouble s = 0.0L, xsd = 0.0L, ysd = 0.0L;
                int64_t n1 = nobs - 1;
                if (!kendall) {
                    ldouble xmean = 0.0L, ymean = 0.0L, xd, yd;
                    for (k = 0; k < nobs; k++) xmean += xx[rows[k]];
                    xmean /= (ldouble) nobs;
                    for (k = 0; k < nobs; k++) ymean += yy[rows[k]];
                    ymean /= (ldouble) nobs;
                    for (k = 0; k < nobs; k++) {
                        xd = xx[rows[k]] - xmean;
                        yd = yy[rows[k]] - ymean;
                        s += xd * yd;
                        xsd += xd * xd;
                        ysd += yd * yd;
                    }
                } else {
                    for (k = 0; k < nobs; k++)
                        for (t = 0; t < k; t++) {
                            double dx = xx[rows[k]] - xx[rows[t]], dy = yy[rows[k]] - yy[rows[t]];
                            s += sgnprod(dx, dy);
                            xsd += sgnprod(dx, dx);
                            ysd += sgnprod(dy, dy);
                        }
                }
                if (cor) {
                    if (xsd == 0 || ysd == 0) {
                        *sd0 = 1;
                        val = R_NA;
                    } else {
                        if (!kendall) {
                            xsd /= (ldouble) n1;
                            ysd /= (ldouble) n1;
                            s /= (ldouble) n1;
                        }
                        s /= (sqrtl(xsd) * sqrtl(ysd));
                        s = s >= 1 ? 1.0L : (s <= -1 ? -1.0L : s);
                        val = (double) s;
                    }
                } else if (!kendall) {
                    val = (double) (s / (ldouble) n1);
                } else {
                    val = (double) s;
                }
            } else {
                val = R_NA;
            }
            ans[i + j * ncx] = val;
            if (sym) ans[j + i * ncx] = val;
        }
    }
}

/* vollständige Zeilen (ohne NaN in x und y) */
static int64_t complete_rows(int64_t n, int64_t ncx, const double *x, int64_t ncy, const double *y, int64_t *rows)
{
    int64_t i, j, m = 0;
    for (i = 0; i < n; i++) {
        int ok = 1;
        for (j = 0; j < ncx && ok; j++) if (isnan(x[i + j * n])) ok = 0;
        if (y) for (j = 0; j < ncy && ok; j++) if (isnan(y[i + j * n])) ok = 0;
        if (ok) rows[m++] = i;
    }
    return m;
}

int sl_r_cov(sl_ctx *cx, int64_t n, int64_t ncx, const double *x, int64_t ncy, const double *y,
             int use, int kendall, int cor, double *ans, int *sd0)
{
    int64_t *rows = NULL, nobs, i, j;
    double *xm = NULL, *ym = NULL;
    int *hx = NULL, *hy = NULL, st = SL_OK;
    int na_fail = use == 1, everything = use == 4, pair = use == 3, empty_err = use != 4 && use != 5;
    if (use < 1 || use > 5) return sl_fail(cx, SL_EARG, "invalid 'use' (computational method)");
    if (y == NULL) ncy = ncx;
    *sd0 = 0;
    for (i = 0; i < ncx * ncy; i++) ans[i] = R_NA;
    rows = (int64_t *) malloc((size_t) (n > 0 ? n : 1) * sizeof(int64_t));
    xm = (double *) malloc((size_t) (ncx > 0 ? ncx : 1) * sizeof(double));
    ym = (double *) malloc((size_t) (ncy > 0 ? ncy : 1) * sizeof(double));
    hx = (int *) calloc((size_t) (ncx > 0 ? ncx : 1), sizeof(int));
    hy = (int *) calloc((size_t) (ncy > 0 ? ncy : 1), sizeof(int));
    if (!rows || !xm || !ym || !hx || !hy) { st = sl_fail(cx, SL_ENOMEM, "cov: kein Speicher"); goto done; }
    if (everything) {
        for (j = 0; j < ncx; j++) for (i = 0; i < n; i++) if (isnan(x[i + j * n])) { hx[j] = 1; break; }
        if (y) for (j = 0; j < ncy; j++) for (i = 0; i < n; i++) if (isnan(y[i + j * n])) { hy[j] = 1; break; }
        if (y == NULL) cov_na_1(n, ncx, x, hx, ans, xm, sd0, cor, kendall);
        else cov_na_2(n, ncx, x, ncy, y, hx, hy, ans, xm, ym, sd0, cor, kendall);
    } else if (!pair) {
        nobs = complete_rows(n, ncx, x, ncy, y, rows);
        if (na_fail && nobs < n) { st = sl_fail(cx, SL_EARG, "missing observations in cov/cor"); goto done; }
        if (y == NULL) cov_complete1(n, ncx, x, rows, nobs, ans, xm, sd0, cor, kendall);
        else cov_complete2(n, ncx, x, ncy, y, rows, nobs, ans, xm, ym, sd0, cor, kendall);
        if (empty_err && nobs == 0) { st = sl_fail(cx, SL_EARG, "no complete element pairs"); goto done; }
    } else {
        cov_pairwise(n, ncx, x, ncy, y ? y : x, rows, ans, sd0, cor, kendall, y == NULL);
    }
done:
    free(rows); free(xm); free(ym); free(hx); free(hy);
    return st;
}
