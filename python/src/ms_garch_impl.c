/*
 * src/ms_garch_impl.c -- Hamilton-Filter des MS-GARCH-Modells, reine Rechnung
 *
 * GEMEINSAME QUELLE FUER R UND PYTHON (Etappe 7.2, seit 7.3a unter diesem Namen):
 * Diese Datei kennt kein R (keine R-Header). R ruft sie ueber die .Call-Huelle
 * C_ms_garch_filter in src/ms_garch.c auf, Python ueber das Erweiterungsmodul
 * simlev._ext (python/src/_ext_ms_garch.cpp). Python baut aus einer
 * Byte-fuer-Byte-Kopie in python/src/ (python/tests/test_shared_c.py prueft die
 * Gleichheit); Aenderungen nur hier vornehmen und danach nach python/src/
 * kopieren. Der reine Python-Port in python/simlev/_bootstrap_core.py
 * (ms_garch_filter) rechnet dasselbe und bleibt der Rueckfall.
 *
 * Modell nach Haas, Mittnik und Paolella (2004): K Regime mit je einem
 * GARCH(1,1)- bzw. GJR-GARCH(1,1)-Varianzpfad, die parallel auf den Daten
 * laufen; Normalverteilung mit Mittelwert 0; Regimewechsel als Markov-Kette
 * mit Uebergangsmatrix P (Zeile = von, Spalte = nach).
 *
 *   h[1, k] = h1
 *   h[t, k] = omega_k + (alpha_k + gamma_k * (y[t-1] < 0)) * y[t-1]^2 + beta_k * h[t-1, k]
 *   phi_k   = exp(-0.5 * y[t]^2 / h[t, k]) / sqrt(2 pi h[t, k])
 *   f_t     = sum_k pred[t, k] * phi_k
 *   filt[t, k]   = pred[t, k] * phi_k / f_t
 *   pred[t+1, j] = sum_i P[i, j] * filt[t, i]          (t(P) %*% filt)
 *   loglik  = sum_t log(f_t), -Inf sobald ein f_t nicht endlich oder <= 0 ist
 *   lB[t, k] = -0.5 * y[t]^2 / h[t, k] - 0.5 * log(2 pi h[t, k])
 *
 * Fester Rechenablauf fuer die Ports: alle Summen beginnen bei 0.0 und laufen
 * ueber k (bzw. i, t) aufsteigend; jede Formel wird genau in der oben
 * geschriebenen Klammerung ausgewertet (y^2 als y * y, 2 pi als 2.0 * M_PI),
 * ohne Umformungen und ohne fma(). Die Rechnung laeuft auch nach einem
 * ungueltigen f_t weiter (NaN pflanzen sich fort); nur loglik wird -Inf.
 * Keine Zufallszahlen.
 *
 * Gleitkomma: Die Pragmas unten schalten das Zusammenziehen von a * b + c zu
 * einer fma-Anweisung ab (wie -ffp-contract=off), damit R, Python und der
 * reine Python-Port auch auf Rechnern mit FMA (aarch64, -march=native)
 * dasselbe rechnen (seit 7.3a wie in allen Kerndateien nur dort, wo fma
 * erzeugt werden kann; auf x86-64 aendert das Pragma hier nichts, siehe Pilot).
 * Mit -ffast-math bricht der Bau ab. exp, log und sqrt kommen aus der libm des
 * Systems (unter Linux glibc), in R wie in Python.
 */
// Gleitkomma wie im Pilot (simlev_core.h): Abbruch bei -ffast-math; kein
// Zusammenziehen von a * b + c zu fma. Das Pragma steht nur dort, wo der Compiler
// fma ueberhaupt erzeugen kann (__FP_FAST_FMA, etwa aarch64 oder -mfma): auf
// x86-64 ohne FMA ist -ffp-contract=off wirkungslos, das GCC-Pragma optimize
// veraendert dort aber die Codeerzeugung der ganzen Datei (geprueft), und R soll
// denselben Maschinencode wie vor der Teilung ausfuehren. Python baut immer mit
// -ffp-contract=off (setup.py) und setzt SIMLEV_FP_CONTRACT_BY_FLAG.
#if defined(__FAST_MATH__)
#error "Gemeinsame Kerne duerfen nicht mit -ffast-math uebersetzt werden (Bitgleichheit)."
#endif
#if defined(__clang__)
#pragma STDC FP_CONTRACT OFF
#elif defined(_MSC_VER)
#pragma fp_contract (off)
#elif defined(__GNUC__) && (defined(__FP_FAST_FMA) || defined(__FP_FAST_FMAF)) && !defined(SIMLEV_FP_CONTRACT_BY_FLAG)
#pragma GCC optimize ("fp-contract=off")
#endif

#include <math.h>
#include <stddef.h>

#include "ms_garch_impl.h"

#ifndef M_PI
#define M_PI 3.141592653589793238462643383279502884197169399375
#endif

void simlev_ms_garch_filter(const double *y, int n, int K, const double *omega,
                            const double *alpha, const double *beta, const double *gamma,
                            const double *P, const double *xi0, double h1,
                            double *h, double *pred, double *filt, double *lB, double *loglik)
{
    const double two_pi = 2.0 * M_PI;
    double ll = 0.0;
    int ok = 1;
    for (int k = 0; k < K; k++) pred[(ptrdiff_t) n * k] = xi0[k];
    for (int t = 0; t < n; t++) {
        /* Varianzpfade */
        if (t == 0) {
            for (int k = 0; k < K; k++) h[(ptrdiff_t) n * k] = h1;
        } else {
            const double e = y[t - 1];
            const double e2 = e * e;
            const double ind = e < 0.0 ? 1.0 : 0.0;
            for (int k = 0; k < K; k++) {
                const double a = alpha[k] + gamma[k] * ind;
                h[t + (ptrdiff_t) n * k] = omega[k] + a * e2 + beta[k] * h[t - 1 + (ptrdiff_t) n * k];
            }
        }
        /* Dichten, Mischungsdichte und Log-Emissionen */
        const double y2 = y[t] * y[t];
        double f = 0.0;
        for (int k = 0; k < K; k++) {
            const double hk = h[t + (ptrdiff_t) n * k];
            const double q = (-0.5 * y2) / hk;
            const double phi = exp(q) / sqrt(two_pi * hk);
            lB[t + (ptrdiff_t) n * k] = q - 0.5 * log(two_pi * hk);
            filt[t + (ptrdiff_t) n * k] = pred[t + (ptrdiff_t) n * k] * phi;   /* Zaehler, unten geteilt */
            f = f + filt[t + (ptrdiff_t) n * k];
        }
        if (!isfinite(f) || f <= 0.0) ok = 0;
        else ll = ll + log(f);
        for (int k = 0; k < K; k++) filt[t + (ptrdiff_t) n * k] = filt[t + (ptrdiff_t) n * k] / f;
        /* Vorhersage fuer t + 1 */
        if (t + 1 < n) {
            for (int j = 0; j < K; j++) {
                double s = 0.0;
                for (int i = 0; i < K; i++) s = s + P[i + (ptrdiff_t) K * j] * filt[t + (ptrdiff_t) n * i];
                pred[t + 1 + (ptrdiff_t) n * j] = s;
            }
        }
    }
    *loglik = ok ? ll : -INFINITY;
}
