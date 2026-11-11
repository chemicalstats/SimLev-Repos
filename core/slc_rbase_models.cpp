/* core/slc_rbase_models.cpp – p.adjust und ecdf mit R-Regeln (SimLev core, seit 1.6.0)
 * Verfahren:  - p.adjust: Bonferroni (min(1, n p)), Holm (kumuliertes Maximum von (n + 1 − i) p(i) aufsteigend),
 *               Hochberg, Benjamini/Hochberg, Benjamini/Yekutieli (kumuliertes Minimum absteigend, BY mit
 *               q = sum(1/(1:n)) in long double wie sum()), Hommel (Schleife über j = n − 1, …, 2 wie ?p.adjust);
 *               Ordnung stabil über sl_r_order, Rückordnung über die Ordnung der Ordnung.
 *             - ecdf: Sprungstellen = sortierte eindeutige Werte (stabil, −0 = 0, erster Vertreter), Höhen
 *               cumsum(tabulate(match(x, vals)))/n (?ecdf).
 * Quellen:    R-Hilfeseiten (R 4.3.3) ?p.adjust, ?ecdf; Holm, S. (1979). A simple sequentially rejective multiple
 *             test procedure. Scand. J. Statist. 6, 65–70; Hochberg, Y. (1988). Biometrika 75, 800–803; Hommel, G.
 *             (1988). Biometrika 75, 383–386; Benjamini, Y., Hochberg, Y. (1995). JRSS B 57, 289–300; Benjamini, Y.,
 *             Yekutieli, D. (2001). Ann. Statist. 29, 1165–1188.
 * Konstanten: keine.
 * Herkunft:           übersetzt aus R 4.3.3, src/library/stats/R/p.adjust.R und ecdf.R über die Port-Funktionen
 *                     python/simlev/_r/stats_models.py (p_adjust) und julia/src/r/stats_models.jl (p_adjust, ecdf)
 *                     (bis 1.5.2)
 * Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut Kopf der
 *                     jeweiligen R-Quelle)
 * Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
 * Änderungen:         C++ im gemeinsamen Teil von C und C++, ohne R-Datenstrukturen, gemeinsamer Kern für Python und
 *                     Julia (nicht Teil des R-Pakets).
 * Prüforakel: R 1.5.2 von SimLev (stats::p.adjust, ecdf; Gleichlauf padj_fuzz.R).
 */
#include "slc_internal.h"
#include "slc_rbase2.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

static double pmin1(double t) { return isnan(t) ? t : (t < 1.0 ? t : 1.0); }

/* stabile Ordnung (0-basiert) und ihre Umkehrung */
static int order_inv(int64_t n, const double *x, int dec, int64_t *o, int64_t *ro)
{
    int64_t i, nout = 0;
    int d = dec;
    if (sl_r_order(n, 1, x, &d, 1, o, &nout)) return SL_ENOMEM;
    for (i = 0; i < n; i++) o[i] -= 1;
    for (i = 0; i < n; i++) ro[o[i]] = i;
    return 0;
}

int sl_r_p_adjust(int64_t lp, const double *p, double n, int method, double *out)
{
    int64_t i, j, nn, m;
    int64_t *o, *ro;
    double *a, *b, *c;
    /* seit 1.6.4 (C-017): n nur fuer hommel und BY ganzzahlig (zur Null hin) und dann endlich und < 2^62, sonst
     * SL_EARG; die Felder nur fuer diese beiden Verfahren n lang, sonst lp (bis 1.6.3 (int64_t) Inf/NaN und
     * 3 max(lp, n) Werte fuer jedes Verfahren). Die Huellen melden n = Inf vorher wie R. */
    if (method == SL_PADJ_HOMMEL || method == SL_PADJ_BY) {
        if (!(n >= 0.0 && n < 4.6e18)) return SL_EARG;
        nn = (int64_t) n;
    } else {
        if (!(n >= 0.0)) return SL_EARG;
        nn = 0;
    }
    m = lp > nn ? lp : nn;
    o = (int64_t *) malloc((size_t) (2 * (m > 0 ? m : 1)) * sizeof(int64_t));
    a = (double *) calloc((size_t) (3 * (m > 0 ? m : 1)), sizeof(double));
    if (!o || !a) { free(o); free(a); return SL_ENOMEM; }
    ro = o + (m > 0 ? m : 1);
    b = a + (m > 0 ? m : 1);
    c = b + (m > 0 ? m : 1);
    if (n == 2 && method == SL_PADJ_HOMMEL) method = SL_PADJ_HOCHBERG;
    switch (method) {
    case SL_PADJ_BONFERRONI:
        for (i = 0; i < lp; i++) out[i] = pmin1(n * p[i]);
        break;
    case SL_PADJ_HOLM:
        if (order_inv(lp, p, 0, o, ro)) goto nomem;
        for (i = 0; i < lp; i++) a[i] = (n + 1 - (double) (i + 1)) * p[o[i]];
        sl_r_cummax(lp, a, b);
        for (i = 0; i < lp; i++) out[i] = pmin1(b[ro[i]]);
        break;
    case SL_PADJ_HOCHBERG: case SL_PADJ_BH: case SL_PADJ_BY: {
        double q = 0.0;
        if (method == SL_PADJ_BY) {
            for (i = 0; i < nn; i++) c[i] = 1.0 / (double) (i + 1);
            q = sl_r_sum(nn, c, 0);
        }
        if (order_inv(lp, p, 1, o, ro)) goto nomem;
        for (i = 0; i < lp; i++) {
            double ii = (double) (lp - i);
            if (method == SL_PADJ_HOCHBERG) a[i] = (n + 1 - ii) * p[o[i]];
            else if (method == SL_PADJ_BH) a[i] = n / ii * p[o[i]];
            else a[i] = q * n / ii * p[o[i]];
        }
        sl_r_cummin(lp, a, b);
        for (i = 0; i < lp; i++) out[i] = pmin1(b[ro[i]]);
        break;
    }
    case SL_PADJ_HOMMEL: {
        double mn, *q = b, *pa = c, *qp = a;
        double *qs = (double *) malloc((size_t) (nn > 0 ? nn : 1) * sizeof(double));
        if (!qs) goto nomem;
        for (i = 0; i < nn; i++) qp[i] = i < lp ? p[i] : 1.0;
        if (order_inv(nn, qp, 0, o, ro)) { free(qs); goto nomem; }
        for (i = 0; i < nn; i++) qs[i] = qp[o[i]];
        mn = (double) nn * qs[0] / 1.0;
        for (i = 1; i < nn; i++) {
            double t = (double) nn * qs[i] / (double) (i + 1);
            if (t < mn || isnan(t)) mn = t;
        }
        for (i = 0; i < nn; i++) q[i] = pa[i] = mn;
        for (j = nn - 1; j >= 2; j--) {
            double q1 = (double) j * qs[nn - j + 1] / 2.0;
            int64_t k;
            for (k = nn - j + 2; k < nn; k++) {
                double t = (double) j * qs[k] / (double) (k - (nn - j + 1) + 2);
                if (t < q1 || isnan(t)) q1 = t;
            }
            for (k = 0; k <= nn - j; k++) {
                double t = (double) j * qs[k];
                q[k] = (t <= q1 || isnan(t)) ? t : q1;
            }
            for (k = nn - j + 1; k < nn; k++) q[k] = q[nn - j];
            for (k = 0; k < nn; k++) pa[k] = (pa[k] >= q[k] || isnan(pa[k])) ? pa[k] : q[k];
        }
        for (i = 0; i < lp; i++) {
            int64_t t = ro[i];
            out[i] = (pa[t] >= qs[t] || isnan(pa[t])) ? pa[t] : qs[t];
        }
        free(qs);
        break;
    }
    default:
        for (i = 0; i < lp; i++) out[i] = p[i];
        break;
    }
    free(o); free(a);
    return 0;
nomem:
    free(o); free(a);
    return SL_ENOMEM;
}

int sl_r_ecdf(int64_t n, const double *x, double *vals, double *y, int64_t *nv)
{
    int64_t i, m = 0, k = 0, nout = 0;
    int dec = 0;
    double *s = (double *) malloc((size_t) (n > 0 ? n : 1) * sizeof(double));
    int64_t *o = (int64_t *) malloc((size_t) (n > 0 ? n : 1) * sizeof(int64_t));
    *nv = 0;
    if (!s || !o) { free(s); free(o); return SL_ENOMEM; }
    for (i = 0; i < n; i++)
        if (!isnan(x[i])) s[m++] = x[i];
    if (m == 0) { free(s); free(o); return SL_EARG; }
    if (sl_r_order(m, 1, s, &dec, 1, o, &nout)) { free(s); free(o); return SL_ENOMEM; }
    for (i = 0; i < m; i++) {
        double v = s[o[i] - 1];
        if (k == 0 || !(v == vals[k - 1])) {
            vals[k] = v;
            y[k] = 0.0;
            k++;
        }
        y[k - 1] += 1.0;
    }
    {
        int64_t cum = 0;
        for (i = 0; i < k; i++) {
            cum += (int64_t) y[i];
            y[i] = (double) cum / (double) m;
        }
    }
    *nv = k;
    free(s); free(o);
    return 0;
}
