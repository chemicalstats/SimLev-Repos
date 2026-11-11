/* core/slc_rbase_clust.cpp – Distanzen und hierarchische Clusteranalyse mit R-Regeln (SimLev core, seit 1.6.0)
 * Verfahren:  - dist: Abstände der Zeilen einer Matrix (euclidean, maximum, manhattan, canberra, binary,
 *               minkowski) über die Spalten mit gemeinsamen Werten; fehlende Spalten hochgerechnet
 *               (Summe / (Anzahl / Spalten)) wie ?dist; ohne gemeinsamen Wert NA. Reihenfolge des Ergebnisses
 *               spaltenweise im unteren Dreieck.
 *             - hclust: agglomerative Clusteranalyse nach Lance/Williams mit Liste nächster Nachbarn (Murtagh
 *               1983/1985): ward.D, single, complete, average, mcquitty, median, centroid, ward.D2 (quadrierte
 *               Abstände), anschließend Umnummerierung der Verschmelzungen und Reihenfolge der Blätter (hcass2).
 * Quellen:    R-Hilfeseiten (R 4.3.3) ?dist, ?hclust; Murtagh, F. (1985). Multidimensional Clustering
 *             Algorithms. COMPSTAT Lectures 4, Physica-Verlag; Lance, G. N., Williams, W. T. (1967). A general
 *             theory of classificatory sorting strategies. The Computer Journal 9(4), 373–380.
 * Konstanten: DBL_MIN, DBL_MAX aus <float.h>; 1e300 als „unendlich“ der Nachbarsuche wie hclust.f.
 * Herkunft:           übersetzt aus R 4.3.3, src/library/stats/src/distance.c und hclust.f (hclust, hcass2)
 *                     über die Port-Funktionen python/simlev/_r/stats_cluster.py (_dist1, _hclust_f, _hcass2)
 *                     und julia/src/r/stats_cluster.jl (bis 1.5.2)
 * Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut Kopf der
 *                     R-Quelle); hclust.f: F. Murtagh (1986), Änderungen Ross Ihaka, Fritz Leisch, Martin
 *                     Maechler (ohne eigenen Lizenzvermerk)
 * Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
 * Änderungen:         C++ im gemeinsamen Teil von C und C++, ohne R-Datenstrukturen, gemeinsamer Kern für Python
 *                     und Julia (seit 1.6.4 auch für R, r/R/slc_stats.R); Indizes 1-basiert wie Fortran in eigenen Feldern.
 * Prüforakel: R 1.5.2 von SimLev (stats::dist, stats::hclust; Gleichlauf clust_fuzz.R).
 */
#include "slc_internal.h"
#include "slc_rbase2.h"

#include <float.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>



/* Abstand der Zeilen i1 und i2 (0-basiert) einer nr × nc-Matrix (spaltenweise). Seit 1.6.4 (T4-R6) eine Schleife je
 * Methode wie R_euclidean, R_maximum, … in distance.c (bis dahin switch je Element); Rechenfolge je Element und
 * Ergebnis unverändert. Die Spalte k liegt bei Versatz o = k * nr (fortgezählt). */
#define DIST_LOOP(...)                                               \
    for (k = 0, o = 0; k < nc; k++, o += nr) {                       \
        double a = x[i1 + o], b = x[i2 + o];                         \
        if (isnan(a) || isnan(b)) continue;                          \
        __VA_ARGS__                                                  \
    }
static double dist1(int64_t nr, int64_t nc, const double *x, int64_t i1, int64_t i2, int method, double p,
                    int *warn)
{
    double d = 0.0, dev;
    int64_t cnt = 0, k, o;
    switch (method) {
    case 1:                                                 /* euclidean */
        DIST_LOOP(dev = a - b; if (!isnan(dev)) { d += dev * dev; cnt++; })
        if (cnt == 0) return SLR_NA;
        if (cnt != nc) d /= ((double) cnt / (double) nc);
        return sqrt(d);
    case 2:                                                 /* maximum */
        d = -DBL_MAX;
        DIST_LOOP(dev = fabs(a - b); if (!isnan(dev)) { if (dev > d) d = dev; cnt++; })
        if (cnt == 0) return SLR_NA;
        return d;
    case 3:                                                 /* manhattan */
        DIST_LOOP(dev = fabs(a - b); if (!isnan(dev)) { d += dev; cnt++; })
        if (cnt == 0) return SLR_NA;
        if (cnt != nc) d /= ((double) cnt / (double) nc);
        return d;
    case 4:                                                 /* canberra */
        DIST_LOOP(
            double s = fabs(a) + fabs(b), df = fabs(a - b);
            if (s > DBL_MIN || df > DBL_MIN) {
                dev = df / s;
                if (!isnan(dev) || (!isfinite(df) && df == s)) {
                    if (isnan(dev)) dev = 1.0;
                    d += dev;
                    cnt++;
                }
            })
        if (cnt == 0) return SLR_NA;
        if (cnt != nc) d /= ((double) cnt / (double) nc);
        return d;
    case 5: {                                               /* binary */
        int64_t total = 0, count = 0, dd = 0;
        DIST_LOOP(
            if (!(isfinite(a) && isfinite(b))) {
                *warn = 1;
            } else {
                if (a != 0.0 || b != 0.0) {
                    count++;
                    if (!(a != 0.0 && b != 0.0)) dd++;
                }
                total++;
            })
        if (total == 0) return SLR_NA;
        if (count == 0) return 0.0;
        return (double) dd / (double) count;
    }
    default:                                                /* minkowski */
        DIST_LOOP(dev = a - b; if (!isnan(dev)) { d += sl_r_pow1(fabs(dev), p); cnt++; })
        if (cnt == 0) return SLR_NA;
        if (cnt != nc) d /= ((double) cnt / (double) nc);
        return method == 6 ? sl_r_pow1(d, 1.0 / p) : d;
    }
}
#undef DIST_LOOP

void sl_r_dist(int64_t nr, int64_t nc, const double *x, int method, double p, double *out, int *warn)
{
    int64_t i, j, ij = 0;
    *warn = 0;
    for (j = 0; j < nr; j++)
        for (i = j + 1; i < nr; i++) out[ij++] = dist1(nr, nc, x, i, j, method, p, warn);
}

/* Stelle von (i, j), i < j, 1-basiert im unteren Dreieck der Länge n(n-1)/2 (hclust.f IOFFST) */
static int64_t ioffst(int64_t n, int64_t i, int64_t j)
{
    return j + (i - 1) * n - (i * (i + 1)) / 2;
}

/* hclust: Lance-Williams mit Nachbarliste; ia, ib, crit 1-basiert (Länge n + 1) */
static void hclust_f(int64_t n, int64_t ln, int iopt, double *membr, double *diss, int64_t *ia, int64_t *ib,
                     double *crit, int64_t *nn, double *disnn, char *flag)
{
    const double INF = 1.0e300;
    int64_t i, j, k, im = 0, jj = 0, jm = 0, ncl = n;
    int isward = iopt == 1 || iopt == 8;
    for (i = 1; i <= n; i++) flag[i] = 1;
    if (iopt == 8)
        for (i = 1; i <= ln; i++) diss[i] = diss[i] * diss[i];
    for (i = 1; i < n; i++) {
        double dmin = INF;
        int found = 0;
        for (j = i + 1; j <= n; j++) {
            int64_t ind = ioffst(n, i, j);
            if (dmin > diss[ind]) { dmin = diss[ind]; jm = j; found = 1; }
        }
        nn[i] = found ? jm : i + 1;   /* seit 1.6.4 (C-016): ohne Abstand < 1e300 ein gueltiger Nachbar statt des alten */
        disnn[i] = dmin;
    }
    for (;;) {
        double dmin = INF, d12;
        int64_t i2, j2;
        im = jm = 0;
        for (i = 1; i < n; i++)
            if (flag[i] && disnn[i] < dmin) { dmin = disnn[i]; im = i; jm = nn[i]; }
        /* seit 1.6.4 (C-016): ohne gueltiges Paar (alle Abstaende NaN oder >= 1e300, nur ohne Pruefung der Huellen
         * erreichbar) die ersten beiden noch aktiven Objekte verbinden; bis 1.6.3 blieben im/jm alt und ioffst las und
         * schrieb ausserhalb von diss. Fuer Abstaende < 1e300 unveraendert. */
        if (!(im >= 1 && im <= n && jm >= 1 && jm <= n && im != jm && flag[im] && flag[jm])) {
            im = jm = 0;
            for (i = 1; i <= n && !jm; i++)
                if (flag[i]) { if (!im) im = i; else jm = i; }
            if (!jm) break;
            dmin = diss[ioffst(n, im, jm)];
        }
        ncl--;
        i2 = im < jm ? im : jm;
        j2 = im < jm ? jm : im;
        ia[n - ncl] = i2;
        ib[n - ncl] = j2;
        if (iopt == 8) dmin = sqrt(dmin);
        crit[n - ncl] = dmin;
        flag[j2] = 0;
        dmin = INF;
        for (k = 1; k <= n; k++) {
            if (flag[k] && k != i2) {
                int64_t ind1 = i2 < k ? ioffst(n, i2, k) : ioffst(n, k, i2);
                int64_t ind2 = j2 < k ? ioffst(n, j2, k) : ioffst(n, k, j2);
                d12 = diss[ioffst(n, i2, j2)];
                if (isward) {
                    double v = ((membr[i2] + membr[k]) * diss[ind1] + (membr[j2] + membr[k]) * diss[ind2])
                               - membr[k] * d12;
                    diss[ind1] = v / ((membr[i2] + membr[j2]) + membr[k]);
                } else if (iopt == 2) {
                    diss[ind1] = diss[ind1] <= diss[ind2] ? diss[ind1] : diss[ind2];
                } else if (iopt == 3) {
                    diss[ind1] = diss[ind1] >= diss[ind2] ? diss[ind1] : diss[ind2];
                } else if (iopt == 4) {
                    diss[ind1] = (membr[i2] * diss[ind1] + membr[j2] * diss[ind2]) / (membr[i2] + membr[j2]);
                } else if (iopt == 5) {
                    diss[ind1] = (diss[ind1] + diss[ind2]) / 2;
                } else if (iopt == 6) {
                    diss[ind1] = ((diss[ind1] + diss[ind2]) - d12 / 2) / 2;
                } else if (iopt == 7) {
                    diss[ind1] = (membr[i2] * diss[ind1] + membr[j2] * diss[ind2]
                                  - membr[i2] * membr[j2] * d12 / (membr[i2] + membr[j2])) / (membr[i2] + membr[j2]);
                }
                if (i2 < k) {
                    if (diss[ind1] < dmin) { dmin = diss[ind1]; jj = k; }
                } else if (diss[ind1] < disnn[k]) {
                    disnn[k] = diss[ind1];
                    nn[k] = i2;
                }
            }
        }
        membr[i2] = membr[i2] + membr[j2];
        disnn[i2] = dmin;
        nn[i2] = jj;
        for (i = 1; i < n; i++) {
            if (flag[i] && (nn[i] == i2 || nn[i] == j2)) {
                dmin = INF;
                for (j = i + 1; j <= n; j++) {
                    if (flag[j]) {
                        int64_t ind = ioffst(n, i, j);
                        if (diss[ind] < dmin) { dmin = diss[ind]; jj = j; }
                    }
                }
                nn[i] = jj;
                disnn[i] = dmin;
            }
        }
        if (!(ncl > 1)) break;
    }
}

/* hcass2: Verschmelzungen umnummerieren (Singletons negativ), Reihenfolge der Blätter */
static void hcass2(int64_t n, const int64_t *ia, const int64_t *ib, int64_t *iia, int64_t *iib, int64_t *iorder)
{
    int64_t i, j, k, loc;
    for (i = 1; i <= n; i++) { iia[i] = ia[i]; iib[i] = ib[i]; }
    for (i = 1; i <= n - 2; i++) {
        k = ia[i] < ib[i] ? ia[i] : ib[i];
        for (j = i + 1; j <= n - 1; j++) {
            if (ia[j] == k) iia[j] = -i;
            if (ib[j] == k) iib[j] = -i;
        }
    }
    for (i = 1; i <= n - 1; i++) { iia[i] = -iia[i]; iib[i] = -iib[i]; }
    for (i = 1; i <= n - 1; i++) {
        if (iia[i] > 0 && iib[i] < 0) { k = iia[i]; iia[i] = iib[i]; iib[i] = k; }
        if (iia[i] > 0 && iib[i] > 0) {
            int64_t k1 = iia[i] < iib[i] ? iia[i] : iib[i], k2 = iia[i] < iib[i] ? iib[i] : iia[i];
            iia[i] = k1;
            iib[i] = k2;
        }
    }
    iorder[1] = iia[n - 1];
    iorder[2] = iib[n - 1];
    loc = 2;
    for (i = n - 2; i >= 1; i--) {
        for (j = 1; j <= loc; j++) {
            if (iorder[j] == i) {
                iorder[j] = iia[i];
                if (j == loc) {
                    loc++;
                    iorder[loc] = iib[i];
                } else {
                    loc++;
                    for (k = loc; k >= j + 2; k--) iorder[k] = iorder[k - 1];
                    iorder[j + 1] = iib[i];
                }
                break;
            }
        }
    }
    for (i = 1; i <= n; i++) iorder[i] = -iorder[i];
}

int sl_r_hclust(int64_t n, int iopt, const double *membr, const double *diss, int64_t *merge, double *height,
                int64_t *order)
{
    int64_t ln = n * (n - 1) / 2, i;
    double *dw, *mw, *crit, *disnn;
    int64_t *iw;
    char *flag;
    if (n < 2) return SL_EARG;
    dw = (double *) malloc((size_t) (ln + 1) * sizeof(double));
    mw = (double *) malloc((size_t) (3 * (n + 1)) * sizeof(double));
    iw = (int64_t *) malloc((size_t) (6 * (n + 1)) * sizeof(int64_t));
    flag = (char *) malloc((size_t) (n + 1));
    if (!dw || !mw || !iw || !flag) {
        free(dw); free(mw); free(iw); free(flag);
        return SL_ENOMEM;
    }
    crit = mw + (n + 1);
    disnn = mw + 2 * (n + 1);
    memset(iw, 0, (size_t) (6 * (n + 1)) * sizeof(int64_t));
    for (i = 0; i <= n; i++) crit[i] = disnn[i] = 0.0;
    dw[0] = 0.0;
    memcpy(dw + 1, diss, (size_t) ln * sizeof(double));
    mw[0] = 0.0;
    memcpy(mw + 1, membr, (size_t) n * sizeof(double));
    {
        int64_t *ia = iw, *ib = iw + (n + 1), *nn = iw + 2 * (n + 1), *iia = iw + 3 * (n + 1),
                *iib = iw + 4 * (n + 1), *ior = iw + 5 * (n + 1);
        hclust_f(n, ln, iopt, mw, dw, ia, ib, crit, nn, disnn, flag);
        hcass2(n, ia, ib, iia, iib, ior);
        for (i = 0; i < n - 1; i++) {
            merge[i] = iia[i + 1];
            merge[(n - 1) + i] = iib[i + 1];
            height[i] = crit[i + 1];
        }
        for (i = 0; i < n; i++) order[i] = ior[i + 1];
    }
    free(dw); free(mw); free(iw); free(flag);
    return 0;
}
