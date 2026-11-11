/* core/slc_internal.h – gemeinsame interne Hilfen der Kerndateien (SimLev core)
 * Verfahren:  keine Rechnung; Gleitkomma-Schutz, Schleifen-Abbruchprüfung, NaN-Regeln.
 * Quellen:    ISO/IEC 9899:1999 (C99), Abschnitte 7.12 (math.h) und 6.10.6 (STDC FP_CONTRACT);
 *             ISO/IEC 14882:2017 (C++17), [c.math] (<math.h> in C++). Seit 1.6.0 übersetzt als C++
 *             (gnu++17); <math.h> statt <cmath>, nur double-Aufrufe (keine float/long-double-Überladung).
 * Konstanten: keine.
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: –
 */
#ifndef SLC_INTERNAL_H
#define SLC_INTERNAL_H

/* Gleitkomma: kein fast-math; kein Zusammenziehen zu fma. GCC beachtet das Pragma nicht
 * und bekommt -ffp-contract=off als Flag (alle drei Builds); Clang zusätzlich das Pragma. */
#ifdef __FAST_MATH__
#error "slc: nicht mit -ffast-math uebersetzen"
#endif
#if defined(__clang__)
#pragma STDC FP_CONTRACT OFF
#endif

#include <math.h>
#include <stdint.h>
#include <string.h>

#include "slc.h"

/* Benutzerabbruch höchstens alle 2^16 Elemente prüfen */
#define SL_POLL(cx, i) \
    do { if ((((i) + 1) & 0xFFFF) == 0 && sl_interrupted(cx)) return SL_EINTR; } while (0)

/* NaN-Regeln von R auf x86-64 (seit 1.6.4 eine Fassung für slc_prep.cpp, slc_bootpath.cpp und slc_rbase.cpp; bis
 * 1.6.3 je Datei): slc_quiet macht ein NaN still (Bit 51 gesetzt, Nutzlast bleibt), slc_lnan gibt für das Ergebnis r
 * von a op b bei NaN den linken NaN-Operanden (still gemacht) zurück */
static inline double slc_quiet(double x)
{
    uint64_t b;
    memcpy(&b, &x, sizeof b);
    b |= UINT64_C(0x0008000000000000);
    memcpy(&x, &b, sizeof b);
    return x;
}
static inline double slc_lnan(double r, double a, double b)
{
    if (r == r) return r;
    if (a != a) return slc_quiet(a);
    if (b != b) return slc_quiet(b);
    return r;
}

/* interne Hilfen über Dateigrenzen (nicht öffentlich; C-Bindung wie bis 1.5.2, Symbole unverändert) */
#ifdef __cplusplus
extern "C" {
#endif
double slc_qnorm_std(double p, int lower) SL_NOTHROW;     /* slc_normal.cpp: Quantil ohne Prüfung, p in (0, 1) */
double slc_lgamma_pos(double x) SL_NOTHROW;               /* slc_special.cpp: x > 0 */
#ifdef __cplusplus
}
#endif

#ifdef __cplusplus
#include <algorithm>
/* Quantil Typ 7 (Hyndman/Fan 1996, Definition 7) der n >= 1 Werte x, die dabei umgeordnet werden (nth_element):
 * xl + frac (xh - xl) mit den Ordnungsstatistiken xl, xh an h = (n - 1) p (0-basiert), bei frac == 0 oder p = 1 xl
 * ohne Rechnung. Nicht bitgleich zu stats::quantile: R rechnet mit dem Index 1 + (n - 1) p und (1 - h) xl + h xh und
 * weicht daher in den letzten Stellen ab (in R, Python und Julia gleich; Befund C-093, Umstellung in 1.6.5,
 * Entscheidung 66). Seit 1.6.3 eine Fassung für die Bandbreite (slc_kde.cpp, vorher quant7 auf sortierten Werten) und
 * CDaR (research_core_impl.h, quantile7). */
static inline double slc_quantile7(double *x, int64_t n, double p)
{
    const double h = (double) (n - 1) * p;
    const int64_t lo = (int64_t) floor(h);
    const double frac = h - (double) lo;
    std::nth_element(x, x + lo, x + n);
    const double xl = x[lo];
    if (frac == 0.0 || lo + 1 >= n) return xl;
    return xl + frac * (*std::min_element(x + lo + 1, x + n) - xl);
}
#endif

#endif /* SLC_INTERNAL_H */
