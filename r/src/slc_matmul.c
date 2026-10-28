/* core/slc_matmul.c – Matrixprodukt A B, X'Y, X Y' (SimLev core, Etappe 9.2)
 * Verfahren:  C_ij = sum_l A_il B_lj; je Element beginnt die Summe mit 0.0 und läuft in
 *             aufsteigender Reihenfolge von l (Entwurf B.6). Die Schleifen sind für die
 *             spaltenweise Ablage geschachtelt (A B: j, l, i; X'Y: j, i, l; X Y': j, l, i); die
 *             Reihenfolge je Element bleibt dabei gleich, kein Blocking über l, keine Umordnung.
 *             Ohne fast-math und mit -ffp-contract=off ordnet der Compiler die Summen nicht um und
 *             zieht nicht zu fma zusammen. NaN und Inf folgen IEEE 754 (0 * Inf = NaN usw.).
 *             Fehlerschranke |C^ - C| <= k u |A||B| komponentenweise (Higham 2002, §3.5).
 * Quellen:    Higham, N. J. (2002). Accuracy and Stability of Numerical Algorithms, 2. Aufl., SIAM,
 *             §3.1 (Skalarprodukte), §3.5 (Matrixmultiplikation).
 *             Golub, G. H., Van Loan, C. F. (2013). Matrix Computations, 4. Aufl., §1.1.
 * Konstanten: keine.
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: R 4.3.3 %*%, crossprod, tcrossprod (Referenz-BLAS; nur Plausibilität, relativ).
 */
#include "slc_internal.h"

#include <stddef.h>

void sl_matmul(int m, int k, int n, const double *A, const double *B, double *C)
{
    int i, j, l;
    double b;
    double *c;
    const double *a;
    for (j = 0; j < n; j++) {
        c = C + (size_t) j * (size_t) m;
        for (i = 0; i < m; i++) c[i] = 0.0;
        for (l = 0; l < k; l++) {
            b = B[(size_t) l + (size_t) j * (size_t) k];
            a = A + (size_t) l * (size_t) m;
            for (i = 0; i < m; i++) c[i] += a[i] * b;
        }
    }
}

void sl_crossprod(int m, int k, int n, const double *X, const double *Y, double *C)
{
    int i, j, l;
    double s;
    const double *x, *y;
    for (j = 0; j < n; j++) {
        y = Y + (size_t) j * (size_t) m;
        for (i = 0; i < k; i++) {
            x = X + (size_t) i * (size_t) m;
            s = 0.0;
            for (l = 0; l < m; l++) s += x[l] * y[l];
            C[(size_t) i + (size_t) j * (size_t) k] = s;
        }
    }
}

void sl_tcrossprod(int m, int k, int n, const double *X, const double *Y, double *C)
{
    int i, j, l;
    double b;
    double *c;
    const double *x;
    for (j = 0; j < n; j++) {
        c = C + (size_t) j * (size_t) m;
        for (i = 0; i < m; i++) c[i] = 0.0;
        for (l = 0; l < k; l++) {
            b = Y[(size_t) j + (size_t) l * (size_t) n];
            x = X + (size_t) l * (size_t) m;
            for (i = 0; i < m; i++) c[i] += x[i] * b;
        }
    }
}
