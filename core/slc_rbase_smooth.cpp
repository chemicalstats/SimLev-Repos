/* core/slc_rbase_smooth.cpp – regularize.values und filter mit R-Regeln (SimLev core, seit 1.6.0)
 * Verfahren:  - regularize.values (approx, approxfun): Paare mit NA entfernen (na.rm) oder behalten, stabil nach x
 *               sortieren (fehlende hinten), sofern nicht "ordered" und x[ok] nicht schon aufsteigend; gleiche x
 *               (−0 = 0, NA/NaN als eine Gruppe) in der Reihenfolge des ersten Auftretens zusammenfassen, y je Gruppe
 *               über mean (long double wie mean()) oder über eine Funktion des Hosts (Gruppennummern) (?approx).
 *             - filter(method = "convolution"): y[i] = sum_j f[j] x[i + o − j], o = floor(nf/2) bei sides = 2, sonst 0;
 *               außerhalb NA bzw. zyklisch; ein fehlender Summand ergibt NA.
 *               filter(method = "recursive"): y[i] = x[i] + sum_j f[j] y[i − j] mit Startwerten init (umgekehrt);
 *               NA in x oder in einem früheren y ergibt NA (?filter).
 * Quellen:    R-Hilfeseiten (R 4.3.3) ?approx, ?filter, ?mean, ?unique, ?order.
 * Konstanten: keine.
 * Herkunft:           übersetzt aus R 4.3.3, src/library/stats/R/approx.R (regularize.values),
 *                     src/library/stats/src/filter.c über die Port-Funktionen python/simlev/_r/stats_smooth.py
 *                     (_regularize, filter) und julia/src/r/stats_smooth.jl (bis 1.5.2)
 * Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut Kopf der
 *                     jeweiligen R-Quelle)
 * Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
 * Änderungen:         C++ im gemeinsamen Teil von C und C++, ohne R-Datenstrukturen, gemeinsamer Kern für Python und
 *                     Julia (seit 1.6.4 filter auch für R, r/R/slc_stats.R); ties als Funktion rechnet der Host über die Gruppennummern.
 * Prüforakel: R 1.5.2 von SimLev (stats::approx, approxfun, filter; Gleichlauf smooth_fuzz.R).
 */
#include "slc_internal.h"
#include "slc_rbase2.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>



/* stabiles Mischsortieren der Indizes nach x (NaN hinten, −0 = 0) */
static void msort(const double *x, int64_t *a, int64_t *t, int64_t lo, int64_t hi)
{
    int64_t mid, i, j, k;
    if (hi - lo < 2) return;
    mid = (lo + hi) / 2;
    msort(x, a, t, lo, mid);
    msort(x, a, t, mid, hi);
    for (i = lo, j = mid, k = lo; k < hi; k++) {
        int takej;
        if (i >= mid) takej = 1;
        else if (j >= hi) takej = 0;
        else {
            double u = x[a[i]], v = x[a[j]];
            takej = isnan(u) ? !isnan(v) : (!isnan(v) && v < u);
        }
        t[k] = takej ? a[j++] : a[i++];
    }
    for (k = lo; k < hi; k++) a[k] = t[k];
}

/* gleicher x-Wert wie R's unique/match: NA und NaN sind verschieden (seit 1.6.4, C-051; bis 1.6.3 eine Gruppe, und im
 * Fehlerfall kam vor R's Meldung eine ueberzaehlige Warnung "collapsing to unique 'x' values") */
static int same_x(double a, double b)
{
    return (isnan(a) && isnan(b) && slr_is_na(a) == slr_is_na(b)) || a == b;
}

int sl_r_regularize(int64_t n, const double *x, const double *y, int narm, int mode, int mean, double *xo, double *yo,
                    int64_t *grp, int64_t *m_out, int64_t *nout, int *collapsed, int *kept_na)
{
    int64_t i, j, m = 0, nx, ng = 0;
    int64_t *idx, *tmp;
    *collapsed = 0;
    *kept_na = 0;
    idx = (int64_t *) malloc((size_t) (2 * (n > 0 ? n : 1)) * sizeof(int64_t));
    if (!idx) return SL_ENOMEM;
    tmp = idx + (n > 0 ? n : 1);
    nx = 0;
    for (i = 0; i < n; i++) {
        int bad = isnan(x[i]) || isnan(y[i]);
        if (bad && narm) continue;
        if (bad) *kept_na = 1;
        else nx++;
        idx[m++] = i;
    }
    if (mode != 2) {
        /* sortieren, wenn nicht "ordered" und x[ok] nicht aufsteigend */
        if (mode == 0) {
            int unsorted = 0;
            double prev = 0.0;
            int have = 0;
            for (i = 0; i < m && !unsorted; i++) {
                double v = x[idx[i]];
                if (*kept_na && (isnan(v) || isnan(y[idx[i]]))) continue;
                if (have && v < prev) unsorted = 1;
                prev = v;
                have = 1;
            }
            if (unsorted && m > 1) msort(x, idx, tmp, 0, m);
        }
        /* Gruppen in der Reihenfolge des ersten Auftretens. Seit 1.6.3: fällt die Folge ohne NaN nicht (nach dem
         * Sortieren bzw. bei aufsteigender Eingabe), stehen gleiche x nebeneinander; dann genügt der Vergleich mit
         * der letzten Gruppe ohne NaN und eine eigene Gruppe für NaN (gleiche Gruppennummern wie die Suche über
         * alle Gruppen, O(m) statt O(m ng)). Sonst wie bisher. */
        int mono = 1;
        {
            int have = 0;
            double prev = 0.0;
            for (i = 0; i < m && mono; i++) {
                double v = x[idx[i]];
                if (isnan(v)) continue;
                if (have && v < prev) mono = 0;
                prev = v;
                have = 1;
            }
        }
        if (mono) {
            int64_t last = -1, gnan = -1, gna = -1;
            for (i = 0; i < m; i++) {
                double v = x[idx[i]];
                if (isnan(v)) {   /* NA und NaN je eine eigene Gruppe (seit 1.6.4, C-051) */
                    int64_t *g = slr_is_na(v) ? &gna : &gnan;
                    if (*g < 0) { *g = ng; xo[ng++] = v; }
                    grp[i] = *g;
                } else {
                    if (last < 0 || !same_x(xo[last], v)) { last = ng; xo[ng++] = v; }
                    grp[i] = last;
                }
            }
        } else {
            for (i = 0; i < m; i++) {
                double v = x[idx[i]];
                for (j = 0; j < ng; j++)
                    if (same_x(xo[j], v)) break;
                if (j == ng) xo[ng++] = v;
                grp[i] = j;
            }
        }
        if (ng < nx) {
            *collapsed = 1;
            if (mean) {
                /* y je Gruppe in der Reihenfolge von i (seit 1.6.3 in einem Durchgang über Zähler statt je Gruppe
                 * über alle m; gleiche Werte und Reihenfolge für sl_r_mean) */
                double *w = (double *) malloc((size_t) (m > 0 ? m : 1) * sizeof(double));
                int64_t *off = (int64_t *) calloc((size_t) (ng + 1), sizeof(int64_t));
                if (!w || !off) { free(w); free(off); free(idx); return SL_ENOMEM; }
                for (i = 0; i < m; i++) off[grp[i] + 1]++;
                for (j = 0; j < ng; j++) off[j + 1] += off[j];
                for (i = 0; i < m; i++) w[off[grp[i]]++] = y[idx[i]];
                for (j = ng; j > 0; j--) off[j] = off[j - 1];
                off[0] = 0;
                for (j = 0; j < ng; j++) yo[j] = sl_r_mean(off[j + 1] - off[j], w + off[j]);
                free(w); free(off);
            } else {
                for (i = 0; i < m; i++) yo[i] = y[idx[i]];
            }
            *m_out = m;
            *nout = ng;
            free(idx);
            return 0;
        }
    }
    for (i = 0; i < m; i++) {
        xo[i] = x[idx[i]];
        yo[i] = y[idx[i]];
    }
    *m_out = m;
    *nout = m;
    free(idx);
    return 0;
}

void sl_r_filter_conv(int64_t n, const double *x, int64_t nf, const double *f, int sides, int circular, double *out)
{
    int64_t i, j, nshift = sides == 2 ? nf / 2 : 0;
    for (i = 0; i < n; i++) {
        double z = 0.0;
        int bad = 0;
        if (!circular && (i + nshift - (nf - 1) < 0 || i + nshift >= n)) {
            out[i] = SLR_NA;
            continue;
        }
        for (j = 0; j < nf; j++) {
            int64_t ii = i + nshift - j;
            double t;
            if (circular) {
                if (ii < 0) ii += n;
                if (ii >= n) ii -= n;
            }
            t = x[ii];
            if (isnan(t)) bad = 1;
            z = z + f[j] * t;
        }
        out[i] = bad ? SLR_NA : z;
    }
}

int sl_r_filter_rec(int64_t n, const double *x, int64_t nf, const double *f, const double *init, double *out)
{
    int64_t i, j;
    double *r = (double *) malloc((size_t) (nf + n > 0 ? nf + n : 1) * sizeof(double));
    if (!r) return SL_ENOMEM;
    for (j = 0; j < nf; j++) r[j] = init[nf - 1 - j];
    for (i = 0; i < n; i++) {
        double sm = x[i];
        int bad = 0;
        if (isnan(sm)) {
            r[nf + i] = SLR_NA;
            continue;
        }
        for (j = 0; j < nf; j++) {
            double t = r[nf + i - j - 1];
            if (!isnan(t)) {
                sm += t * f[j];
            } else {
                r[nf + i] = SLR_NA;
                bad = 1;
                break;
            }
        }
        if (!bad) r[nf + i] = sm;
    }
    for (i = 0; i < n; i++) out[i] = r[nf + i];
    free(r);
    return 0;
}
