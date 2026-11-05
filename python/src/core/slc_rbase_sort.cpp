/* core/slc_rbase_sort.cpp – Ordnung, Rang, partielle Sortierung, Quantile, tabulate, findInterval mit
 * R-Regeln (SimLev core)
 * Verfahren:  - order: stabile Sortierung (Mischsortieren, Knuth TAOCP Bd. 3, 5.2.4) mit
 *               lexikographischem Vergleich der Schlüssel; -0 und +0 sind gleich, NA und NaN fehlend
 *               (vorn, hinten oder entfernt); Gleichstände in der ursprünglichen Reihenfolge, auch
 *               absteigend (?order: "any unresolved ties will be left in their original ordering",
 *               method = "radix" ist stabil).
 *             - rank: über die stabile Ordnung; average/min/max über Gleichstandsgruppen, first nach
 *               Position, last mit umgekehrter Positionsfolge (?rank).
 *             - partielle Sortierung (sort(x, partial = k)): bis 10 Indizes Auswahl nach Hoare (FIND,
 *               Hoare 1961) mit Teilung um das Element an Position k, rekursiv um den mittleren der
 *               Indizes; mehr Indizes: vollständige Sortierung (Quicksort nach Singleton 1969 mit
 *               Einfügesortieren kurzer Abschnitte). Die Reihenfolge gleicher Werte (nur -0/+0 sind
 *               verschieden darstellbar) hängt vom Verfahren ab; die Ports bildeten es nach, damit
 *               quantile()/median() das Vorzeichen der Null wie R liefern. Logik wie
 *               python/simlev/_r/stats_sort.py (_rpsort2, _psort0, _r_qsort).
 *             - quantile Typ 1–9 nach Hyndman/Fan (1996) wie ?quantile: Typ 7 mit
 *               index = 1 + (n − 1) p, sonst m = a + p (n + 1 − a − b), j = floor(m + 4 eps),
 *               h = m − j (|h| < 4 eps → 0), unstetige Typen 1–3 wie dort definiert; Werte außerhalb
 *               1..n am Rand fortgesetzt.
 *             - tabulate: Zählen der abgeschnittenen ganzen Zahlen 1..nbins.
 *             - findInterval: Bisektion (Anzahl vec_j <= x bzw. < x bei left.open), Randregeln wie
 *               ?findInterval.
 * Quellen:    R-Hilfeseiten (R 4.3.3) ?order, ?sort, ?rank, ?quantile, ?tabulate, ?findInterval;
 *             Hyndman, R. J., Fan, Y. (1996). Sample quantiles in statistical packages. The American
 *             Statistician 50(4), 361–365; Hoare, C. A. R. (1961). Algorithm 65: FIND. CACM 4(7), 321;
 *             Singleton, R. C. (1969). Algorithm 347: An efficient algorithm for sorting with
 *             minimal storage. CACM 12(3), 185–186; Knuth, D. E. (1998). The Art of Computer
 *             Programming, Bd. 3, 2. Aufl.
 * Konstanten: DBL_EPSILON aus <float.h>; Schrittfaktoren des Quicksort (0.375, +0.0390625,
 *             −0.21875, Grenze 0.5898437) nach Singleton (1969).
 * Herkunft:           übersetzt aus R 4.3.3, src/main/sort.c (psort_body, Psort0) und qsort-body.c
 *                     (Quicksort qsort_singleton Schritt für Schritt), über die Port-Funktionen
 *                     python/simlev/_r/stats_sort.py und julia/src/r/stats_sort.jl; order, rank,
 *                     quantile, tabulate, findInterval nachgebildet nach den R-Hilfeseiten
 * Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation
 *                     (laut Kopf der jeweiligen R-Quelle); qsort-body.c nach R. C. Singleton,
 *                     CACM-Algorithmus 347 (1969)
 * Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
 * Änderungen:         C99 ohne R-Datenstrukturen, gemeinsamer Kern für Python und Julia (nicht Teil
 *                     des R-Pakets); nur double-Werte und int64_t-Indizes; order als stabiles
 *                     Mischsortieren.
 * Prüforakel: R 4.3.3 (Gleichlauf: rbase_fuzz.R).
 */
#include "slc_internal.h"
#include "slc_rbase.h"

#include <float.h>
#include <stdlib.h>
#include <string.h>

static double bits_d(uint64_t u)
{
    double d;
    memcpy(&d, &u, sizeof d);
    return d;
}

#define R_NA bits_d(UINT64_C(0x7FF00000000007A2))

/* ── order ─────────────────────────────────────────────────────────────── */

typedef struct {
    int64_t n;
    int nkey;
    const double *keys;
    const int *dec;
    int nafirst;
} ord_t;

/* < 0: Element a vor b; Gleichstand 0 (dann entscheidet die Stabilität) */
static int ord_cmp(const ord_t *o, int64_t a, int64_t b)
{
    int k;
    for (k = 0; k < o->nkey; k++) {
        const double *v = o->keys + (int64_t) k * o->n;
        double x = v[a], y = v[b];
        int nx = isnan(x), ny = isnan(y);
        if (nx || ny) {
            if (nx && ny) continue;
            return (nx ? 1 : -1) * (o->nafirst ? -1 : 1);
        }
        if (x < y) return o->dec[k] ? 1 : -1;
        if (x > y) return o->dec[k] ? -1 : 1;
    }
    return 0;
}

static void msort(const ord_t *o, int64_t *a, int64_t *w, int64_t n)
{
    int64_t i, j, k, h;
    if (n < 2) return;
    if (n <= 16) {                                 /* Einfügesortieren (stabil) */
        for (i = 1; i < n; i++) {
            int64_t t = a[i];
            for (j = i; j > 0 && ord_cmp(o, a[j - 1], t) > 0; j--) a[j] = a[j - 1];
            a[j] = t;
        }
        return;
    }
    h = n / 2;
    msort(o, a, w, h);
    msort(o, a + h, w, n - h);
    if (ord_cmp(o, a[h - 1], a[h]) <= 0) return;
    memcpy(w, a, (size_t) h * sizeof(int64_t));
    i = 0; j = h; k = 0;
    while (i < h && j < n) {
        if (ord_cmp(o, a[j], w[i]) < 0) a[k++] = a[j++];
        else a[k++] = w[i++];
    }
    while (i < h) a[k++] = w[i++];
}

static int order0(int64_t n, int nkey, const double *keys, const int *dec, int nafirst, int64_t *idx)
{
    ord_t o;
    int64_t *w, i;
    o.n = n; o.nkey = nkey; o.keys = keys; o.dec = dec; o.nafirst = nafirst;
    for (i = 0; i < n; i++) idx[i] = i;
    w = (int64_t *) malloc((size_t) (n / 2 + 1) * sizeof(int64_t));
    if (w == NULL) return SL_ENOMEM;
    msort(&o, idx, w, n);
    free(w);
    return SL_OK;
}

int sl_r_order(int64_t n, int nkey, const double *keys, const int *decreasing, int nalast,
               int64_t *out, int64_t *nout)
{
    int64_t i, m = 0;
    int k, st = order0(n, nkey, keys, decreasing, nalast == 0, out);
    if (st != SL_OK) return st;
    if (nalast < 0) {
        for (i = 0; i < n; i++) {
            int bad = 0;
            for (k = 0; k < nkey; k++) if (isnan(keys[(int64_t) k * n + out[i]])) { bad = 1; break; }
            if (!bad) out[m++] = out[i];
        }
    } else {
        m = n;
    }
    for (i = 0; i < m; i++) out[i] += 1;
    *nout = m;
    return SL_OK;
}

int sl_r_rank(int64_t n, const double *x, int ties, double *out)
{
    int64_t *o, i, j, k;
    int dec = 0, st;
    if (n == 0) return SL_OK;
    o = (int64_t *) malloc((size_t) n * sizeof(int64_t));
    if (o == NULL) return SL_ENOMEM;
    if (ties == 2) {
        /* last: absteigend stabil sortieren und umkehren = aufsteigend, Gleichstände mit der
         * späteren Position zuerst */
        int d1 = 1;
        st = order0(n, 1, x, &d1, 0, o);
        if (st != SL_OK) { free(o); return st; }
        for (i = 0; i < n; i++) out[o[n - 1 - i]] = (double) (i + 1);
        free(o);
        return SL_OK;
    }
    st = order0(n, 1, x, &dec, 0, o);
    if (st != SL_OK) { free(o); return st; }
    if (ties == 1) {
        for (i = 0; i < n; i++) out[o[i]] = (double) (i + 1);
        free(o);
        return SL_OK;
    }
    i = 0;
    while (i < n) {
        j = i;
        while (j < n - 1 && x[o[j]] == x[o[j + 1]]) j++;
        for (k = i; k <= j; k++) {
            if (ties == 0) out[o[k]] = ((double) i + (double) j + 2.0) / 2.0;
            else if (ties == 4) out[o[k]] = (double) (j + 1);
            else out[o[k]] = (double) (i + 1);
        }
        i = j + 1;
    }
    free(o);
    return SL_OK;
}

/* ── partielle Sortierung ──────────────────────────────────────────────── */

/* Auswahl: x[k] an die richtige Stelle, links nicht größer, rechts nicht kleiner (0-basiert) */
static void psort2(double *x, int64_t lo, int64_t hi, int64_t k)
{
    int64_t L = lo, R = hi, i, j;
    double v, w;
    while (L < R) {
        v = x[k];
        i = L; j = R;
        while (i <= j) {
            while (x[i] < v) i++;
            while (v < x[j]) j--;
            if (i <= j) { w = x[i]; x[i] = x[j]; x[j] = w; i++; j--; }
        }
        if (j < k) L = i;
        if (k < i) R = j;
    }
}

/* ind: aufsteigend, 1-basiert */
static void psort0(double *x, int64_t lo, int64_t hi, const int64_t *ind, int64_t nind)
{
    int64_t i, mid, z, this_ = 0;
    if (nind < 1 || hi - lo < 1) return;
    if (nind <= 1) { psort2(x, lo, hi, ind[0] - 1); return; }
    mid = (lo + hi) / 2;
    for (i = 0; i < nind; i++) if (ind[i] - 1 <= mid) this_ = i;
    z = ind[this_] - 1;
    psort2(x, lo, hi, z);
    psort0(x, lo, z - 1, ind, this_);
    psort0(x, z + 1, hi, ind + this_ + 1, nind - this_ - 1);
}

/* vollständige Sortierung nach Singleton (1969), 1-basiert auf v[1..n] */
static void qsort_singleton(double *v0, int64_t n)
{
    double *v = v0 - 1, vt, vtt;
    double R = 0.375;
    int64_t il[40], iu[40], i, j, k, l, ij, ii, m;
    if (n < 2) return;
    i = 1; j = n; ii = i; m = 1;
    goto L10;
L10:
    if (i < j) {
        if (R < 0.5898437) R += 0.0390625; else R -= 0.21875;
        goto L20;
    }
    goto L80;
L20:
    k = i;
    ij = i + (int64_t) ((double) (j - i) * R);
    vt = v[ij];
    if (v[i] > vt) { v[ij] = v[i]; v[i] = vt; vt = v[ij]; }
    l = j;
    if (v[j] < vt) {
        v[ij] = v[j]; v[j] = vt; vt = v[ij];
        if (v[i] > vt) { v[ij] = v[i]; v[i] = vt; vt = v[ij]; }
    }
    for (;;) {
        l--;
        while (v[l] > vt) l--;
        vtt = v[l];
        k++;
        while (v[k] < vt) k++;
        if (k > l) break;
        v[l] = v[k]; v[k] = vtt;
    }
    m++;
    if (l - i <= j - k) { il[m] = k; iu[m] = j; j = l; }
    else { il[m] = i; iu[m] = l; i = k; }
    goto L90;
L80:
    if (m == 1) return;
    i = il[m]; j = iu[m]; m--;
    goto L90;
L90:
    if (j - i > 10) goto L20;
    if (i == ii) goto L10;
    i--;
L100:
    do {
        i++;
        if (i == j) goto L80;
        vt = v[i + 1];
    } while (v[i] <= vt);
    k = i;
    do { v[k + 1] = v[k]; k--; } while (vt < v[k]);
    v[k + 1] = vt;
    goto L100;
}

static int cmp_i64(const void *a, const void *b)
{
    int64_t x = *(const int64_t *) a, y = *(const int64_t *) b;
    return (x > y) - (x < y);
}

int sl_r_psort(int64_t n, double *x, int64_t nk, const int64_t *k)
{
    int64_t *s;
    if (nk > 10) { qsort_singleton(x, n); return SL_OK; }
    if (nk < 1 || n < 2) return SL_OK;
    s = (int64_t *) malloc((size_t) nk * sizeof(int64_t));
    if (s == NULL) return SL_ENOMEM;
    memcpy(s, k, (size_t) nk * sizeof(int64_t));
    qsort(s, (size_t) nk, sizeof(int64_t), cmp_i64);
    psort0(x, 0, n - 1, s, nk);
    free(s);
    return SL_OK;
}

/* ── quantile ──────────────────────────────────────────────────────────── */

/* Wert an 1-basierter Stelle i oder NA außerhalb */
static double at1(const double *x, int64_t n, int64_t i) { return (i >= 1 && i <= n) ? x[i - 1] : R_NA; }

static int64_t add_unique(int64_t *part, int64_t np, double v)
{
    int64_t i, iv = (int64_t) v;
    for (i = 0; i < np; i++) if (part[i] == iv) return np;
    part[np] = iv;
    return np + 1;
}

int sl_r_quantile(int64_t n, const double *x, int64_t np, const double *p, int type, double *out)
{
    const double fuzz = 4 * DBL_EPSILON;
    double *xs = NULL, *xx = NULL;
    int64_t *part = NULL, npart = 0, k;
    int st = SL_OK;
    double a = 0, b = 0;
    if (type < 1 || type > 9) return SL_EARG;
    switch (type) {
    case 4: a = 0.0; b = 1.0; break;
    case 5: a = 0.5; b = 0.5; break;
    case 6: a = 0.0; b = 0.0; break;
    case 7: a = 1.0; b = 1.0; break;
    case 8: a = 1.0 / 3; b = 1.0 / 3; break;
    case 9: a = 3.0 / 8; b = 3.0 / 8; break;
    default: break;
    }
    xs = (double *) malloc((size_t) (n > 0 ? n : 1) * sizeof(double));
    part = (int64_t *) calloc((size_t) (2 * np + 2), sizeof(int64_t));
    xx = (double *) malloc((size_t) (n + 4) * sizeof(double));
    if (xs == NULL || part == NULL || xx == NULL) { st = SL_ENOMEM; goto done; }
    if (n > 0) memcpy(xs, x, (size_t) n * sizeof(double));
    /* Indizes der partiellen Sortierung (Reihenfolge des ersten Auftretens, ohne Wiederholung) */
    if (n > 0) {
        if (type == 7) {
            double nm1 = (double) (n - 1 > 0 ? n - 1 : 0);
            for (k = 0; k < np; k++) if (p[k] == p[k]) npart = add_unique(part, npart, floor(1 + nm1 * p[k]));
            for (k = 0; k < np; k++) if (p[k] == p[k]) npart = add_unique(part, npart, ceil(1 + nm1 * p[k]));
        } else {
            double j;
            npart = add_unique(part, npart, 1.0);
            for (k = 0; k < np; k++) {
                if (type <= 3) j = floor(type == 3 ? (double) n * p[k] - 0.5 : (double) n * p[k]);
                else j = floor(a + p[k] * ((double) n + 1 - a - b) + fuzz);
                if (p[k] == p[k] && j > 0 && j <= (double) n) npart = add_unique(part, npart, j);
            }
            for (k = 0; k < np; k++) {
                if (type <= 3) j = floor(type == 3 ? (double) n * p[k] - 0.5 : (double) n * p[k]);
                else j = floor(a + p[k] * ((double) n + 1 - a - b) + fuzz);
                if (p[k] == p[k] && j > 0 && j < (double) n) npart = add_unique(part, npart, j + 1);
            }
            npart = add_unique(part, npart, (double) n);
        }
        st = sl_r_psort(n, xs, npart, part);
        if (st != SL_OK) goto done;
    }
    if (type == 7) {
        double nm1 = (double) (n - 1 > 0 ? n - 1 : 0);
        for (k = 0; k < np; k++) {
            double index, lo, hi, q, xh, hh;
            if (p[k] != p[k]) { out[k] = p[k]; continue; }
            index = 1 + nm1 * p[k];
            lo = floor(index); hi = ceil(index);
            q = at1(xs, n, (int64_t) lo);
            xh = at1(xs, n, (int64_t) hi);
            if (index > lo && xh == xh && q == q && xh != q) {
                hh = index - lo;
                q = (1 - hh) * q + hh * xh;
            }
            out[k] = q;
        }
    } else {
        int64_t nxx;
        if (n > 0) {
            xx[0] = xs[0]; xx[1] = xs[0];
            memcpy(xx + 2, xs, (size_t) n * sizeof(double));
            xx[n + 2] = xs[n - 1]; xx[n + 3] = xs[n - 1];
            nxx = n + 4;
        } else {
            xx[0] = R_NA; xx[1] = R_NA;
            nxx = 2;
        }
        for (k = 0; k < np; k++) {
            double nppm, j, h, x2, x3, q;
            int pok = p[k] == p[k];
            int64_t jj;
            if (!pok) { out[k] = p[k]; continue; }
            if (type <= 3) {
                nppm = type == 3 ? (double) n * p[k] - 0.5 : (double) n * p[k];
                j = floor(nppm);
                if (type == 1) h = (nppm > j) ? 1.0 : 0.0;
                else if (type == 2) h = ((nppm > j ? 1.0 : 0.0) + 1) / 2;
                else h = (nppm != j || fmod(j, 2.0) == 1.0) ? 1.0 : 0.0;
            } else {
                nppm = a + p[k] * ((double) n + 1 - a - b);
                j = floor(nppm + fuzz);
                h = nppm - j;
                if (fabs(h) < fuzz) h = 0.0;
            }
            jj = (int64_t) j;
            x2 = at1(xx, nxx, jj + 2);
            x3 = at1(xx, nxx, jj + 3);
            q = x2;
            if (h == 1) q = x3;
            if (!(h == h) || !(x2 == x2) || !(x3 == x3)) {
                /* NA in einem Vergleich: (0 < h) & (h < 1) & (x2 != x3) ist FALSE nur bei einem FALSE */
                int fa = (h == h) && !(0 < h);
                int fb = (h == h) && !(h < 1);
                int fc = (x2 == x2 && x3 == x3) && !(x2 != x3);
                if (!(fa || fb || fc)) q = (1 - h) * x2 + h * x3;
            } else if (0 < h && h < 1 && x2 != x3) {
                q = (1 - h) * x2 + h * x3;
            }
            out[k] = q;
        }
    }
done:
    free(xs); free(part); free(xx);
    return st;
}

/* ── tabulate, findInterval ────────────────────────────────────────────── */

void sl_r_tabulate(int64_t n, const double *bin, int64_t nbins, int64_t *out)
{
    int64_t i;
    for (i = 0; i < nbins; i++) out[i] = 0;
    for (i = 0; i < n; i++) {
        double b = bin[i];
        if (b != b) continue;
        b = trunc(b);
        if (b >= 1 && b <= (double) nbins) out[(int64_t) b - 1]++;
    }
}

/* Anzahl vec_j <= x (right = 1) bzw. vec_j < x (right = 0) */
static int64_t count_le(const double *v, int64_t n, double x, int right)
{
    int64_t lo = 0, hi = n, mid;
    while (lo < hi) {
        mid = lo + (hi - lo) / 2;
        if (right ? (v[mid] <= x) : (v[mid] < x)) lo = mid + 1; else hi = mid;
    }
    return lo;
}

void sl_r_findinterval(int64_t nv, const double *vec, int64_t nx, const double *x,
                       int rightmost_closed, int all_inside, int left_open, double *out)
{
    int64_t i, r;
    for (i = 0; i < nx; i++) {
        double xi = x[i];
        if (xi != xi) { out[i] = R_NA; continue; }
        r = count_le(vec, nv, xi, !left_open);
        if (all_inside && nv > 0) {                 /* 0 -> 1, N -> N - 1 */
            if (r == 0) r = 1;
            else if (r == nv) r = nv - 1;
        }
        if (rightmost_closed && nv > 0) {           /* left.open: am linken Rand geschlossen */
            if (left_open) { if (xi == vec[0]) r = 1; }
            else if (xi == vec[nv - 1]) r = nv - 1;
        }
        out[i] = (double) r;
    }
}
