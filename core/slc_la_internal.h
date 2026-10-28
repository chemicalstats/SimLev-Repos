/* core/slc_la_internal.h – interne Hilfen der Etappe 9.2 (SimLev core): kompensierte Summen, NA
 * Verfahren:  Summation nach Neumaier (1974): neben der laufenden Summe s wird der Rundungsfehler
 *             jeder Addition exakt bestimmt (für |s| >= |a|: (s - (s + a)) + a, sonst
 *             (a - (s + a)) + s) und in c aufsummiert; Ergebnis s + c. Skalarprodukte summieren die
 *             (gerundeten) Produkte so in fester, aufsteigender Indexreihenfolge (Higham 2002, §4.3).
 *             NA ist das NaN mit Nutzlast 1954 (Bitmuster 0x7FF00000000007A2), wie es R, Python
 *             (simlev._r.rnum.NA_REAL) und Julia (SimLev.NA) von NaN unterscheiden.
 * Quellen:    Neumaier, A. (1974). Rundungsfehleranalyse einiger Verfahren zur Summation endlicher
 *             Summen. ZAMM 54(1), 39–51.
 *             Higham, N. J. (2002). Accuracy and Stability of Numerical Algorithms, 2. Aufl., SIAM,
 *             Kap. 4 (Summation), §4.3.
 * Konstanten: keine.
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: –
 */
#ifndef SLC_LA_INTERNAL_H
#define SLC_LA_INTERNAL_H

#include <math.h>
#include <stdint.h>
#include <string.h>

typedef struct { double s, c; } slc_acc;

static inline void slc_acc_init(slc_acc *a, double v) { a->s = v; a->c = 0.0; }

static inline void slc_acc_add(slc_acc *a, double v)
{
    double t = a->s + v;
    if (fabs(a->s) >= fabs(v)) a->c += (a->s - t) + v;
    else a->c += (v - t) + a->s;
    a->s = t;
}

static inline double slc_acc_val(const slc_acc *a) { return a->s + a->c; }

/* sum_{i < n} x[i * incx] y[i * incy], kompensiert, aufsteigend */
static inline double slc_dot(int64_t n, const double *x, int64_t incx, const double *y, int64_t incy)
{
    slc_acc a;
    int64_t i;
    slc_acc_init(&a, 0.0);
    for (i = 0; i < n; i++) slc_acc_add(&a, x[i * incx] * y[i * incy]);
    return slc_acc_val(&a);
}

/* Euklidische Norm ohne Über- und Unterlauf: Skalierung mit dem Betragsmaximum, kompensierte Summe */
static inline double slc_nrm2(int64_t n, const double *x, int64_t incx)
{
    double mx = 0.0, q;
    slc_acc a;
    int64_t i;
    for (i = 0; i < n; i++) if (fabs(x[i * incx]) > mx) mx = fabs(x[i * incx]);
    if (mx == 0.0 || !(mx <= 1.79769313486231570815e+308)) return mx;
    slc_acc_init(&a, 0.0);
    for (i = 0; i < n; i++) { q = x[i * incx] / mx; slc_acc_add(&a, q * q); }
    return mx * sqrt(slc_acc_val(&a));
}

static inline double slc_na_real(void)
{
    uint64_t u = UINT64_C(0x7FF00000000007A2);
    double d;
    memcpy(&d, &u, sizeof d);
    return d;
}

static inline int slc_all_finite(int64_t n, const double *x)
{
    int64_t i;
    for (i = 0; i < n; i++) if (!isfinite(x[i])) return 0;
    return 1;
}

/* stabile Sortierung der Indizes 0 ... n-1 nach key (aufsteigend; Mischsortierung von unten,
 * Knuth 1998, §5.2.4); work hat n Plätze. Definiert in slc_spline.c. */
void slc_sort_index(int64_t n, const double *key, int64_t *idx, int64_t *work);

#endif /* SLC_LA_INTERNAL_H */
