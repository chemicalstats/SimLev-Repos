/* core/slc_linalg.h – Schnittstelle der C-Bibliothek slc (SimLev core): lineare Algebra, Matrixprodukt,
 * kleinste Quadrate und Logit-IRLS, Stineman-Interpolation, kubischer Glättungsspline, Kerndichte
 *
 * Verfahren:  siehe die Kerndateien slc_linalg.cpp (Cholesky, Band-Cholesky, Dreieckslöser,
 *             SPD-Löser, symmetrische Eigenwerte per Householder + QL), slc_matmul.cpp (Matrixprodukt),
 *             slc_lsq.cpp (Householder-QR mit begrenzter Spaltenpivotisierung, Logit-IRLS),
 *             slc_stine.cpp (Stineman), slc_spline.cpp (Reinsch-Spline mit GCV), slc_kde.cpp
 *             (Gauß-Kerndichte); jede nennt ihre Quellen.
 * Quellen:    Literatur je Kerndatei.
 * Konstanten: keine.
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: R 4.3.3, stinepack 1.5 (nur Plausibilität).
 *
 * Eingebunden von slc.h (eine Zeile); nicht direkt einbinden.
 *
 * Felder: double spaltenweise, führende Dimension = Zeilenzahl. Indizes in Ergebnissen 1-basiert.
 * Matrix- und Modellfunktionen: nicht endliche Eingaben ergeben SL_ENONFINITE (mit Funktionsnamen),
 * leere bzw. zu kleine Eingaben SL_ESMALL, sofern unten nichts anderes steht. Das Matrixprodukt
 * folgt IEEE (NaN pflanzt sich fort) und kann nicht scheitern.
 */
#ifndef SLC_LINALG_H
#define SLC_LINALG_H

#include <stdint.h>

/* C++ (seit 1.6.0): Die Funktionen von slc werfen nie (C-Regeln, kein longjmp). SL_NOTHROW sagt das dem
 * Übersetzer; ohne die Angabe legt g++ an jedem Aufruf über Dateigrenzen Ausnahmepfade an und ordnet heiße
 * Schleifen anders (gemessen: MS-GARCH-Fit in Julia 7 % langsamer). Ändert weder Bindung noch ABI. */
#ifndef SL_NOTHROW
#if defined(__cplusplus) && (defined(__GNUC__) || defined(__clang__))
#define SL_NOTHROW __attribute__((nothrow))
#else
#define SL_NOTHROW
#endif
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ── Lineare Algebra (slc_linalg.cpp) ──────────────────────────────────── */

/* A = R'R, R obere Dreiecksmatrix (n x n, unteres Dreieck 0); gelesen wird das obere Dreieck von A */
int sl_chol(sl_ctx *cx, int n, const double *A, double *R) SL_NOTHROW;
/* op(T) X = B mit T = oberes (upper = 1) bzw. unteres Dreieck von R (n x n), op = T' bei trans = 1;
 * B (n x nrhs) wird überschrieben */
int sl_trisolve(sl_ctx *cx, int n, int nrhs, const double *R, int upper, int trans, double *B) SL_NOTHROW;
/* A X = B für symmetrisch positiv definites A (oberes Dreieck gelesen); B wird überschrieben;
 * logdet (NULL oder) = log det A */
int sl_solve_spd(sl_ctx *cx, int n, int nrhs, const double *A, double *B, double *logdet) SL_NOTHROW;
/* log det A für symmetrisch positiv definites A (ohne Konditionsprüfung) */
int sl_logdet_spd(sl_ctx *cx, int n, const double *A, double *logdet) SL_NOTHROW;
/* symmetrische Eigenwerte (absteigend) und -vektoren (Spalten); gelesen wird das untere Dreieck */
int sl_eigen_sym(sl_ctx *cx, int n, const double *A, int want_vectors, double *values, double *vectors) SL_NOTHROW;
/* Band-Cholesky A = L L' für symmetrisch positiv definites Band A (Halbbandbreite kd) an Ort und
 * Stelle; Speicher ab[(i - j) + j (kd + 1)] = A[i, j] für j <= i <= min(n - 1, j + kd) (unteres Band) */
int sl_chol_band(sl_ctx *cx, int n, int kd, double *ab) SL_NOTHROW;

/* ── Matrixprodukt (slc_matmul.cpp) ─────────────────────────────────────── */

void sl_matmul(int m, int k, int n, const double *A, const double *B, double *C) SL_NOTHROW;      /* A B:  A m x k, B k x n */
void sl_crossprod(int m, int k, int n, const double *X, const double *Y, double *C) SL_NOTHROW;   /* X'Y:  X m x k, Y m x n */
void sl_tcrossprod(int m, int k, int n, const double *X, const double *Y, double *C) SL_NOTHROW;  /* X Y': X m x k, Y n x k */

/* ── Kleinste Quadrate und Logit-IRLS (slc_lsq.cpp) ─────────────────────── */

/* y ~ X (m x n) mit Gewichten w (NULL: 1); pivot = 1 begrenzte, 2 volle Spaltenpivotisierung.
 * coef (n): ausgefallene Koeffizienten NA (NaN mit Nutzlast 1954); fitted (m, NULL erlaubt) = X b;
 * rank; perm (n): Spaltenreihenfolge der Zerlegung, 1-basiert (die ersten rank Spalten zählen) */
int sl_lsfit(sl_ctx *cx, int m, int n, const double *X, const double *y, const double *w,
             double tol, int pivot, double *coef, double *fitted, int *rank, int32_t *perm) SL_NOTHROW;
/* Logit-Modell y ~ X per IRLS; y in [0, 1]; maxit Schritte, tol Abbruch der Devianz;
 * coef (n) wie sl_lsfit; converged 1/0 */
int sl_logit_irls(sl_ctx *cx, int m, int n, const double *X, const double *y,
                  int maxit, double tol, double *coef, int *converged) SL_NOTHROW;

/* ── Stineman-Interpolation (slc_stine.cpp) ────────────────────────────── */

/* x streng steigend (n >= 1); scale = 1: Steigungen auf skalierten Daten (wie heute "scaledstineman");
 * yout = NA außerhalb [x_1, x_n] bzw. für NaN in xout */
int sl_stineman(sl_ctx *cx, int n, const double *x, const double *y, int nout, const double *xout,
                double *yout) SL_NOTHROW;
int sl_stineman_slopes(sl_ctx *cx, int n, const double *x, const double *y, int scale, double *yp) SL_NOTHROW;
int sl_stineman_eval(sl_ctx *cx, int n, const double *x, const double *y, const double *yp,
                     int nout, const double *xout, double *yout) SL_NOTHROW;

/* ── Kubischer Glättungsspline (slc_spline.cpp) ────────────────────────── */

/* x, y, w (NULL: 1) Länge n; lambda <= 0: Wahl per GCV. Ausgabe (Felder der Länge n):
 * nk verschiedene Knoten, g = Werte, gam = zweite Ableitungen an den Knoten (0 an den Rändern) */
int sl_smspline_fit(sl_ctx *cx, int n, const double *x, const double *y, const double *w,
                    double lambda, int *nk, double *knots, double *g, double *gam,
                    double *lambda_out, double *df, double *gcv) SL_NOTHROW;
int sl_smspline_predict(sl_ctx *cx, int nk, const double *knots, const double *g, const double *gam,
                        int nout, const double *xout, double *yout) SL_NOTHROW;

/* ── Gauß-Kerndichte (slc_kde.cpp) ─────────────────────────────────────── */

/* Dichte auf ngrid Punkten von from bis to; w (NULL: 1/n) */
int sl_kde(sl_ctx *cx, int64_t n, const double *x, const double *w, double bw,
           int ngrid, double from, double to, double *xgrid, double *y) SL_NOTHROW;
/* Bandbreite nach Silvermans Faustregel 0.9 min(sd, IQR/1.34) n^(-1/5) */
int sl_kde_bw(sl_ctx *cx, int64_t n, const double *x, double *bw) SL_NOTHROW;

#ifdef __cplusplus
}
#endif

#endif /* SLC_LINALG_H */
