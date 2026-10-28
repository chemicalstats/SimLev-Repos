/*
 * src/ms_garch_impl.h -- Hamilton-Filter des MS-GARCH-Modells, reine Rechnung
 *
 * Gemeinsame Quelle fuer R und Python: R ruft den Kern ueber die .Call-Huelle
 * in src/ms_garch.c auf, Python ueber das Erweiterungsmodul simlev._ext
 * (python/src/_ext_ms_garch.cpp). Die Python-Seite fuehrt eine Byte-fuer-Byte-
 * Kopie dieser Datei und von ms_garch_impl.c in python/src/ (geprueft von
 * python/tests/test_shared_c.py). Aenderungen nur hier, danach kopieren.
 */
#ifndef SIMLEV_MS_GARCH_IMPL_H
#define SIMLEV_MS_GARCH_IMPL_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * y[n]; omega, alpha, beta, gamma, xi0 je K Werte; P K x K spaltenweise
 * (Zeile = von, Spalte = nach); h1 Startvarianz. Ausgaben h, pred, filt, lB
 * je n x K spaltenweise (vom Aufrufer bereitgestellt), *loglik.
 * Voraussetzung: n >= 1, K >= 1 (prueft der Aufrufer).
 */
void simlev_ms_garch_filter(const double *y, int n, int K, const double *omega,
                            const double *alpha, const double *beta, const double *gamma,
                            const double *P, const double *xi0, double h1,
                            double *h, double *pred, double *filt, double *lB, double *loglik);

#ifdef __cplusplus
}
#endif

#endif
