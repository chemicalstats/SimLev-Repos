/* core/slc_internal.h – gemeinsame interne Hilfen der Kerndateien (SimLev core, Etappe 9)
 * Verfahren:  keine Rechnung; Gleitkomma-Schutz, Schleifen-Abbruchprüfung, NaN-Regeln (B.0).
 * Quellen:    ISO/IEC 9899:1999 (C99), Abschnitte 7.12 (math.h) und 6.10.6 (STDC FP_CONTRACT).
 * Konstanten: keine.
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: –
 */
#ifndef SLC_INTERNAL_H
#define SLC_INTERNAL_H

/* Gleitkomma (C.3): kein fast-math; kein Zusammenziehen zu fma. GCC beachtet das Pragma nicht
 * und bekommt -ffp-contract=off als Flag (alle drei Builds); Clang zusätzlich das Pragma. */
#ifdef __FAST_MATH__
#error "slc: nicht mit -ffast-math uebersetzen (C.3)"
#endif
#if defined(__clang__)
#pragma STDC FP_CONTRACT OFF
#endif

#include <math.h>
#include <stdint.h>

#include "slc.h"

/* Benutzerabbruch höchstens alle 2^16 Elemente prüfen (B.0) */
#define SL_POLL(cx, i) \
    do { if ((((i) + 1) & 0xFFFF) == 0 && sl_interrupted(cx)) return SL_EINTR; } while (0)

/* interne Hilfen über Dateigrenzen (nicht öffentlich) */
double slc_qnorm_std(double p, int lower);     /* slc_normal.c: Quantil ohne Prüfung, p in (0, 1) */
double slc_lgamma_pos(double x);               /* slc_special.c: x > 0 */

#endif /* SLC_INTERNAL_H */
