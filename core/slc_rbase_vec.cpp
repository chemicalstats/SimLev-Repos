/* core/slc_rbase_vec.cpp – Einteilen, Folgen und Median mit R-Regeln (SimLev core, seit 1.6.0)
 * Verfahren:  - .bincode (cut): Bisektion über die aufsteigenden Grenzen; Intervalle rechts geschlossen (right) oder
 *               links geschlossen, include.lowest schließt das erste bzw. letzte Intervall; NA/NaN und Werte
 *               außerhalb ergeben NA (?cut, ?.bincode).
 *             - seq.int(from, to, length.out = n): Schritt (to − from)/(n − 1), bei nicht endlicher Differenz über
 *               to/(n − 1) − from/(n − 1) mit Viertelung gegen Überlauf; erster und letzter Wert exakt (?seq).
 *             - median.default: partielle Sortierung um die Mitte (sl_r_psort) und Mittel der beiden mittleren
 *               Werte wie mean() (long double; ganzzahlige Eingaben über das ganzzahlige Mittel); NA ohne na.rm
 *               und leere Eingabe ergeben NA (?median).
 * Quellen:    R-Hilfeseiten (R 4.3.3) ?cut, ?.bincode, ?seq, ?median, ?mean.
 * Konstanten: keine.
 * Herkunft:           übersetzt aus R 4.3.3, src/library/base/R/cut.R, src/main/util.c (bincode), src/main/seq.c
 *                     (seq.int mit length.out) und src/library/stats/R/median.R über die Port-Funktionen
 *                     python/simlev/_r/stats_sort.py (_bincode, seq_len_out, median) und julia/src/r/stats_sort.jl
 *                     (bis 1.5.2)
 * Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut Kopf der
 *                     jeweiligen R-Quelle)
 * Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
 * Änderungen:         C++ im gemeinsamen Teil von C und C++, ohne R-Datenstrukturen, gemeinsamer Kern für Python und
 *                     Julia (nicht Teil des R-Pakets).
 * Prüforakel: R 1.5.2 von SimLev (base::cut, .bincode, seq, stats::median; Gleichlauf vec_fuzz.R).
 */
#include "slc_internal.h"
#include "slc_rbase2.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>



void sl_r_bincode(int64_t n, const double *x, int64_t nb, const double *b, int right, int include_lowest,
                  double *out)
{
    int64_t i, nb1 = nb - 1;
    int lft = !right;
    for (i = 0; i < n; i++) {
        double xi = x[i];
        int64_t lo = 0, hi = nb1;
        out[i] = SLR_NA;
        /* seit 1.6.5 (CR2-D-14) wie R .bincode auch mit einer Grenze (include.lowest trifft sie; bis 1.6.4 dort NA);
         * ohne Grenze NA */
        if (isnan(xi) || nb1 < 0) continue;
        if (xi < b[lo] || b[hi] < xi || (xi == b[lft ? hi : lo] && !include_lowest)) continue;
        while (hi - lo >= 2) {
            int64_t mid = (hi + lo) / 2;
            if (xi > b[mid] || (lft && xi == b[mid])) lo = mid;
            else hi = mid;
        }
        out[i] = (double) (lo + 1);
    }
}

void sl_r_seq_len(double from, double to, int64_t n, double *out)
{
    int64_t i;
    if (n <= 0) return;
    out[0] = from;
    if (n > 1) out[n - 1] = to;
    if (n > 2) {
        double nint = (double) (n - 1), rby = to - from;
        if (isfinite(rby)) {
            rby = rby / nint;
            for (i = 1; i < n - 1; i++) out[i] = from + (double) i * rby;
        } else {
            double f4, b4;
            rby = to / nint - from / nint;
            f4 = from / 4.0;
            b4 = rby / 4.0;
            for (i = 1; i < n - 1; i++) out[i] = (f4 + (double) i * b4) * 4.0;
        }
    }
}

int sl_r_median(int64_t n, const double *x, int narm, int isint, double *res)
{
    int64_t i, m = 0, half, k[2];
    double *s;
    *res = SLR_NA;
    for (i = 0; i < n; i++)
        if (isnan(x[i]) && !narm) return 1;
    s = (double *) malloc((size_t) (n > 0 ? n : 1) * sizeof(double));
    if (!s) return SL_ENOMEM;
    for (i = 0; i < n; i++)
        if (!isnan(x[i])) s[m++] = x[i];
    if (m == 0) { free(s); return 1; }
    half = (m + 1) / 2;
    k[0] = half;
    k[1] = half + 1;
    if (sl_r_psort(m, s, m % 2 == 1 ? 1 : 2, k)) { free(s); return SL_ENOMEM; }
    if (m % 2 == 1) {
        *res = s[half - 1];
    } else if (isint) {
        int64_t p[2];
        p[0] = (int64_t) s[half - 1];
        p[1] = (int64_t) s[half];
        *res = sl_r_mean_int(2, p);
    } else {
        *res = sl_r_mean(2, s + half - 1);
    }
    free(s);
    return 0;
}
