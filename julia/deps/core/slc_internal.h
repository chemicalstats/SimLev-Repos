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
/* Quantil Typ 7 (Hyndman/Fan 1996, Definition 7) der n >= 1 Werte x, die dabei umgeordnet werden (nth_element).
 * Seit 1.6.5 wie stats::quantile in R 4.3.3 (Befund C-093, Entscheidung 66): Index 1 + (n - 1) p, lo = floor(Index),
 * h = Index - lo, Ordnungsstatistiken xl = x(lo), xh = x(lo + 1) (1-basiert); bei h > 0 und xh != xl (1 - h) xl + h xh,
 * sonst xl ohne Rechnung (bis 1.6.4 xl + frac (xh - xl) mit frac aus (n - 1) p, in den letzten Stellen anders).
 * Eine Fassung fuer die Bandbreite (slc_kde.cpp), CDaR (research_core_impl.h, quantile7) und Serenity
 * (evaluate_core_impl.h). */
static inline double slc_quantile7(double *x, int64_t n, double p)
{
    const double index = 1.0 + (double) (n - 1) * p;
    const double lof = floor(index);
    const int64_t lo = (int64_t) lof - 1;                       /* 0-basiert */
    std::nth_element(x, x + lo, x + n);
    const double xl = x[lo];
    if (!(index > lof) || lo + 1 >= n) return xl;
    const double xh = *std::min_element(x + lo + 1, x + n);
    if (xh == xl) return xl;
    const double h = index - lof;
    return (1.0 - h) * xl + h * xh;
}
#endif

#endif /* SLC_INTERNAL_H */
