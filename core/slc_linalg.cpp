/* core/slc_linalg.cpp – Cholesky, Band-Cholesky, Dreieckslöser, SPD-Löser, symmetrische Eigenwerte
 * (SimLev core)
 * Verfahren:  Cholesky A = R'R spaltenweise (Golub/Van Loan 2013, §4.2.5, Alg. 4.2.2 in der
 *             Skalarprodukt-Form): r_ij = (a_ij - sum_{k<i} r_ki r_kj) / r_ii, r_jj = sqrt(a_jj -
 *             sum_{k<j} r_kj^2); gelesen wird nur das obere Dreieck. Band-Cholesky A = LL' derselbe
 *             Ablauf auf dem unteren Band der Halbbandbreite kd (Golub/Van Loan 2013, §4.3.5).
 *             Dreieckslöser durch Vorwärts- bzw. Rückwärtseinsetzen mit mehreren rechten Seiten
 *             (Golub/Van Loan 2013, §3.1.1–3.1.4). SPD-Löser = Cholesky und zwei Dreieckslöser;
 *             log det A = 2 sum log r_ii; Konditionsprüfung min r_ii^2 / max r_ii^2 < 2^-52 als grobe,
 *             dokumentierte Abschätzung (Higham 2002, Kap. 10). Alle Summen in fester, aufsteigender
 *             Indexreihenfolge und kompensiert nach Neumaier (slc_la_internal.h).
 *             Symmetrische Eigenwerte (seit 1.6.2; bis 1.6.1 zyklisches Jacobi): Householder-
 *             Tridiagonalisierung A = Q T Q' (Golub/Van Loan 2013, Alg. 8.3.1; Spiegelung mit Vorzeichen-
 *             wahl ohne Auslöschung, Alg. 5.1.1), Q rückwärts aufgebaut (§5.1.6); Eigenwerte und -vektoren
 *             von T mit implizitem QL bzw. QR und Wilkinson-Verschiebung (Bowdler, Martin, Reinsch,
 *             Wilkinson 1968; Golub/Van Loan 2013, §8.3.3), die Drehungen auf die Spalten von Q. Abspaltung,
 *             wenn e_m^2 <= u^2 |d_m| |d_m+1| + 2^-1022 (u = 2^-53); Richtung je unzerlegtem Block QL, wenn
 *             |d| am Blockende nicht kleiner ist als am Anfang, sonst QR (Regel wie LAPACK dsteqr); höchstens
 *             30 n Schritte. Einträge über 2^400 bzw. unter 2^-400 vorher mit einer Zweierpotenz skaliert
 *             (exakt). Gelesen wird das untere Dreieck. Ausgabe absteigend (stabil sortiert); Vorzeichen
 *             jedes Vektors: die betragsgrößte Komponente ist positiv, bei Gleichstand die erste (wie bis
 *             1.6.1). Skalarprodukte in fester, aufsteigender Reihenfolge; Rang-2-Änderung symmetrisch
 *             (v_i w_j + w_i v_j), die Matrix bleibt exakt symmetrisch. Gemessen gegen das Jacobi-Verfahren
 *             bis 1.6.1 (n = 5 bis 500, Referenz in 113 Bit): orthogonaler (bei n = 500 8e-15 gegen 1,5e-13),
 *             Residuum und Eigenwertfehler bezogen auf ||A|| ab n = 20 kleiner, darunter bis zum Faktor 2
 *             größer (<= 1,6e-15); bei n = 500 etwa 12-mal so schnell; konvergiert auch bei vielfachen
 *             Eigenwerten (Jacobi brach bei n >= 100 mit drei 50-fachen Eigenwerten ab). Relativ genauer
 *             bleibt Jacobi bei sehr kleinen Eigenwerten stark abgestufter Matrizen (Demmel/Veselić 1992);
 *             SimLev nutzt die Zerlegung nur mit absoluten Schranken (Korrektur auf positiv definit,
 *             Schrittweite, Entrauschen von Korrelationen).
 * Quellen:    Golub, G. H., Van Loan, C. F. (2013). Matrix Computations, 4. Aufl., Johns Hopkins
 *             University Press, §3.1, §4.2, §4.3, §5.1, §8.3.
 *             Bowdler, H., Martin, R. S., Reinsch, C., Wilkinson, J. H. (1968). The QR and QL algorithms
 *             for symmetric matrices. Numerische Mathematik 11, 293–306; auch in Wilkinson, J. H.,
 *             Reinsch, C. (1971). Handbook for Automatic Computation II: Linear Algebra, Springer, II/3.
 *             Demmel, J., Veselić, K. (1992). Jacobi's method is more accurate than QR. SIAM Journal
 *             on Matrix Analysis and Applications 13(4), 1204–1245 (Grenzen der Wahl).
 *             Higham, N. J. (2002). Accuracy and Stability of Numerical Algorithms, 2. Aufl., SIAM,
 *             Kap. 4 (kompensierte Summen), Kap. 8 (Dreieckssysteme), Kap. 10 (Cholesky).
 *             Neumaier, A. (1974). ZAMM 54(1), 39–51 (kompensierte Summe).
 * Konstanten: 2^-52, 2^-53, 2^-1022 (Gleitkomma-Grenzen, slc_constants.h); 30 n Schritte, Skalierungsgrenzen
 *             2^+-400 eigene Festlegung.
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: R 4.3.3 chol, backsolve, solve, determinant, eigen(symmetric = TRUE) (nur
 *             Plausibilität).
 */
#include "slc_internal.h"
#include "slc_la_internal.h"
#include "slc_constants.h"

#include <stdlib.h>

#define IX(i, j, ld) ((size_t) (i) + (size_t) (j) * (size_t) (ld))

/* ── Cholesky ── */

static int chol_upper(sl_ctx *cx, int n, const double *A, double *R, const char *fn)
{
    int i, j, k;
    slc_acc a;
    double s;
    for (j = 0; j < n; j++)
        for (i = 0; i <= j; i++)
            if (!isfinite(A[IX(i, j, n)])) return sl_fail(cx, SL_ENONFINITE, "%s: NA/NaN/Inf in der Matrix", fn);
    for (j = 0; j < n; j++) {
        for (i = j + 1; i < n; i++) R[IX(i, j, n)] = 0.0;
        for (i = 0; i <= j; i++) {
            slc_acc_init(&a, A[IX(i, j, n)]);
            for (k = 0; k < i; k++) slc_acc_add(&a, -(R[IX(k, i, n)] * R[IX(k, j, n)]));
            s = slc_acc_val(&a);
            if (i < j) {
                R[IX(i, j, n)] = s / R[IX(i, i, n)];
            } else {
                if (!(s > 0.0) || !isfinite(s))
                    return sl_fail(cx, SL_ENOTPD, "%s: Matrix nicht positiv definit (führende Minore der Ordnung %d)", fn, j + 1);
                R[IX(j, j, n)] = sqrt(s);
            }
        }
    }
    return SL_OK;
}

int sl_chol(sl_ctx *cx, int n, const double *A, double *R)
{
    if (n < 0) return sl_fail(cx, SL_EARG, "chol: negative Dimension");
    return chol_upper(cx, n, A, R, "chol");
}

int sl_chol_band(sl_ctx *cx, int n, int kd, double *ab)
{
    int i, j, k, lo, ld = kd + 1;
    slc_acc a;
    double d;
    if (n < 0 || kd < 0) return sl_fail(cx, SL_EARG, "chol_band: negative Dimension");
    for (j = 0; j < n; j++)
        for (i = j; i <= j + kd && i < n; i++)
            if (!isfinite(ab[IX(i - j, j, ld)])) return sl_fail(cx, SL_ENONFINITE, "chol_band: NA/NaN/Inf in der Matrix");
    for (j = 0; j < n; j++) {
        lo = j - kd > 0 ? j - kd : 0;
        slc_acc_init(&a, ab[IX(0, j, ld)]);
        for (k = lo; k < j; k++) slc_acc_add(&a, -(ab[IX(j - k, k, ld)] * ab[IX(j - k, k, ld)]));
        d = slc_acc_val(&a);
        if (!(d > 0.0) || !isfinite(d))
            return sl_fail(cx, SL_ENOTPD, "chol_band: Matrix nicht positiv definit (führende Minore der Ordnung %d)", j + 1);
        d = sqrt(d);
        ab[IX(0, j, ld)] = d;
        for (i = j + 1; i <= j + kd && i < n; i++) {
            lo = i - kd > 0 ? i - kd : 0;
            slc_acc_init(&a, ab[IX(i - j, j, ld)]);
            for (k = lo; k < j; k++) slc_acc_add(&a, -(ab[IX(i - k, k, ld)] * ab[IX(j - k, k, ld)]));
            ab[IX(i - j, j, ld)] = slc_acc_val(&a) / d;
        }
    }
    return SL_OK;
}

/* ── Dreieckslöser ── */

static int trisolve(sl_ctx *cx, int n, int nrhs, const double *R, int upper, int trans, double *B, const char *fn,
                    int check)
{
    int i, j, c;
    slc_acc a;
    double *b;
    if (n < 0 || nrhs < 0) return sl_fail(cx, SL_EARG, "%s: negative Dimension", fn);
    if (check) {
        for (j = 0; j < n; j++)
            for (i = upper ? 0 : j; i < (upper ? j + 1 : n); i++)
                if (!isfinite(R[IX(i, j, n)])) return sl_fail(cx, SL_ENONFINITE, "%s: NA/NaN/Inf in der Matrix", fn);
        if (!slc_all_finite((int64_t) n * nrhs, B))
            return sl_fail(cx, SL_ENONFINITE, "%s: NA/NaN/Inf in der rechten Seite", fn);
        for (i = 0; i < n; i++)
            if (R[IX(i, i, n)] == 0.0) return sl_fail(cx, SL_ESINGULAR, "%s: singuläre Matrix (Diagonale %d ist 0)", fn, i + 1);
    }
    /* upper && !trans bzw. !upper && trans: rückwärts; sonst vorwärts. T_ij = R_ij (ohne trans)
     * bzw. R_ji (trans). */
    for (c = 0; c < nrhs; c++) {
        b = B + (size_t) c * (size_t) n;
        if (upper != trans) {             /* rückwärts: x_i = (b_i - sum_{j>i} T_ij x_j) / T_ii */
            for (i = n - 1; i >= 0; i--) {
                slc_acc_init(&a, b[i]);
                for (j = i + 1; j < n; j++)
                    slc_acc_add(&a, -((trans ? R[IX(j, i, n)] : R[IX(i, j, n)]) * b[j]));
                b[i] = slc_acc_val(&a) / R[IX(i, i, n)];
            }
        } else {                          /* vorwärts: x_i = (b_i - sum_{j<i} T_ij x_j) / T_ii */
            for (i = 0; i < n; i++) {
                slc_acc_init(&a, b[i]);
                for (j = 0; j < i; j++)
                    slc_acc_add(&a, -((trans ? R[IX(j, i, n)] : R[IX(i, j, n)]) * b[j]));
                b[i] = slc_acc_val(&a) / R[IX(i, i, n)];
            }
        }
    }
    return SL_OK;
}

int sl_trisolve(sl_ctx *cx, int n, int nrhs, const double *R, int upper, int trans, double *B)
{
    return trisolve(cx, n, nrhs, R, upper != 0, trans != 0, B, "backsolve", 1);
}

/* ── SPD-Löser ── */

static double logdet_of(int n, const double *R)
{
    slc_acc a;
    int i;
    slc_acc_init(&a, 0.0);
    for (i = 0; i < n; i++) slc_acc_add(&a, log(R[IX(i, i, n)]));
    return 2.0 * slc_acc_val(&a);
}

int sl_solve_spd(sl_ctx *cx, int n, int nrhs, const double *A, double *B, double *logdet)
{
    double *R, d, dmin, dmax;
    int i, st;
    if (n < 0 || nrhs < 0) return sl_fail(cx, SL_EARG, "solve: negative Dimension");
    if (n == 0) { if (logdet) *logdet = 0.0; return SL_OK; }
    if (!slc_all_finite((int64_t) n * nrhs, B)) return sl_fail(cx, SL_ENONFINITE, "solve: NA/NaN/Inf in der rechten Seite");
    R = (double *) malloc(sizeof(double) * (size_t) n * (size_t) n);
    if (!R) return sl_fail(cx, SL_ENOMEM, "solve: kein Speicher");
    st = chol_upper(cx, n, A, R, "solve");
    if (st == SL_OK) {
        dmin = dmax = R[0] * R[0];
        for (i = 1; i < n; i++) {
            d = R[IX(i, i, n)] * R[IX(i, i, n)];
            if (d < dmin) dmin = d;
            if (d > dmax) dmax = d;
        }
        if (dmin / dmax < SLC_TWO_M52) st = sl_fail(cx, SL_ESINGULAR, "solve: Matrix numerisch singulär");
    }
    if (st == SL_OK) {
        if (logdet) *logdet = logdet_of(n, R);
        trisolve(cx, n, nrhs, R, 1, 1, B, "solve", 0);     /* R' z = b */
        trisolve(cx, n, nrhs, R, 1, 0, B, "solve", 0);     /* R x = z */
    }
    free(R);
    return st;
}

int sl_logdet_spd(sl_ctx *cx, int n, const double *A, double *logdet)
{
    double *R;
    int st;
    if (n < 0) return sl_fail(cx, SL_EARG, "determinant: negative Dimension");
    if (n == 0) { *logdet = 0.0; return SL_OK; }
    R = (double *) malloc(sizeof(double) * (size_t) n * (size_t) n);
    if (!R) return sl_fail(cx, SL_ENOMEM, "determinant: kein Speicher");
    st = chol_upper(cx, n, A, R, "determinant");
    if (st == SL_OK) *logdet = logdet_of(n, R);
    free(R);
    return st;
}

/* ── Symmetrische Eigenwerte (Householder-Tridiagonalisierung, implizites QL/QR; seit 1.6.2) ── */

/* Rotation zweier Spalten auf den Zeilen lo ... hi-1: x' = c x - s y, y' = s x + c y (mit GCC/Clang in Vektoren zu je
 * zwei Werten; dieselben Operationen je Element wie die Schleife, Ergebnis unabhängig davon) */
#if defined(__GNUC__) || defined(__clang__)
typedef double slc_v2d __attribute__((vector_size(16), aligned(8)));
#endif

static void rot_cols(double *__restrict x, double *__restrict y, int lo, int hi, double c, double s)
{
    int r = lo;
#if defined(__GNUC__) || defined(__clang__)
    const slc_v2d vc = { c, c }, vs = { s, s };
    for (; r + 2 <= hi; r += 2) {
        slc_v2d a = *(const slc_v2d *) (x + r), b = *(const slc_v2d *) (y + r);
        *(slc_v2d *) (x + r) = vc * a - vs * b;
        *(slc_v2d *) (y + r) = vs * a + vc * b;
    }
#endif
    for (; r < hi; r++) {
        const double a = x[r], b = y[r];
        x[r] = c * a - s * b;
        y[r] = s * a + c * b;
    }
}

/* y[0 .. m-1] += x[0 .. m-1] * t */
static void axpy_(double *__restrict y, const double *__restrict x, int m, double t)
{
    int r = 0;
#if defined(__GNUC__) || defined(__clang__)
    const slc_v2d vt = { t, t };
    for (; r + 2 <= m; r += 2) {
        slc_v2d a = *(const slc_v2d *) (x + r), b = *(const slc_v2d *) (y + r);
        *(slc_v2d *) (y + r) = b + a * vt;
    }
#endif
    for (; r < m; r++) y[r] += x[r] * t;
}

/* b[0 .. m-1] -= v * wj + w * vj (symmetrische Rang-2-Änderung je Spalte; v_i w_j + w_i v_j ist in i und j
 * vertauschbar, die Matrix bleibt exakt symmetrisch) */
static void rank2_col_(double *__restrict b, const double *__restrict v, const double *__restrict w, int m,
                       double wj, double vj)
{
    int r = 0;
#if defined(__GNUC__) || defined(__clang__)
    const slc_v2d vw = { wj, wj }, vv = { vj, vj };
    for (; r + 2 <= m; r += 2) {
        slc_v2d a = *(const slc_v2d *) (v + r), c = *(const slc_v2d *) (w + r), d = *(const slc_v2d *) (b + r);
        *(slc_v2d *) (b + r) = d - (a * vw + c * vv);
    }
#endif
    for (; r < m; r++) b[r] -= v[r] * wj + w[r] * vj;
}

/* Skalarprodukt in fester, aufsteigender Reihenfolge */
static double dot_(const double *x, const double *y, int m)
{
    double s = 0.0;
    int r;
    for (r = 0; r < m; r++) s += x[r] * y[r];
    return s;
}

/* Householder-Tridiagonalisierung A = Q T Q' (Golub/Van Loan 2013, Alg. 8.3.1; Spiegelung wie Alg. 5.1.1 mit
 * Vorzeichenwahl ohne Auslöschung): Schritt k spiegelt x = a[k+1:n, k] auf beta e_1, beta = -sign(x_1) ||x||,
 * v = (1, x_2:/(x_1 - beta)), tau = (beta - x_1) / beta; Restblock B = a[k+1:, k+1:] wird H B H mit
 * p = tau B v, w = p - (tau / 2) (p'v) v, B -= v w' + w v' (beide Dreiecke). Ergebnis: d (Diagonale),
 * e (Nebendiagonale, e[n-1] = 0), v in a[k+2:, k], tau[k]. */
static void tridiag_(double *a, int n, double *d, double *e, double *tau, double *p)
{
    int k, j, m;
    for (k = 0; k + 2 < n; k++) {
        double *x = a + IX(k + 1, k, n), alpha = x[0], xnorm, beta, scal, t, pv;
        m = n - k - 1;
        d[k] = a[IX(k, k, n)];
        xnorm = slc_nrm2((int64_t) (m - 1), x + 1, 1);
        if (xnorm == 0.0) { tau[k] = 0.0; e[k] = alpha; continue; }
        beta = -copysign(hypot(alpha, xnorm), alpha);
        t = (beta - alpha) / beta;
        scal = alpha - beta;
        for (j = 1; j < m; j++) x[j] /= scal;
        x[0] = 1.0;
        tau[k] = t;
        e[k] = beta;
        /* p = tau B v (Summe der Spalten, aufsteigend) */
        for (j = 0; j < m; j++) p[j] = 0.0;
        for (j = 0; j < m; j++) axpy_(p, a + IX(k + 1, k + 1 + j, n), m, x[j]);
        for (j = 0; j < m; j++) p[j] *= t;
        pv = dot_(p, x, m);
        for (j = 0; j < m; j++) p[j] -= (0.5 * t * pv) * x[j];
        for (j = 0; j < m; j++) rank2_col_(a + IX(k + 1, k + 1 + j, n), x, p, m, p[j], x[j]);
        x[0] = beta;                                       /* v_1 = 1 steht nicht im Speicher */
    }
    if (n >= 2) { d[n - 2] = a[IX(n - 2, n - 2, n)]; e[n - 2] = a[IX(n - 1, n - 2, n)]; }
    d[n - 1] = a[IX(n - 1, n - 1, n)];
    e[n - 1] = 0.0;
}

/* Q = H_0 H_1 ... H_{n-3} rückwärts aufbauen (Golub/Van Loan 2013, §5.1.6): Q = I, für k = n-3, ..., 0
 * Q[k+1:, k+1:] -= tau_k v (v' Q[k+1:, k+1:]) spaltenweise */
static void form_q_(const double *a, int n, const double *tau, double *q)
{
    int k, i, j, m;
    for (j = 0; j < n; j++) for (i = 0; i < n; i++) q[IX(i, j, n)] = (i == j) ? 1.0 : 0.0;
    for (k = n - 3; k >= 0; k--) {
        const double *x = a + IX(k + 1, k, n);              /* x[1:] = v[1:], v_0 = 1 */
        m = n - k - 1;
        if (tau[k] == 0.0) continue;
        for (j = k + 1; j < n; j++) {
            double *c = q + IX(k + 1, j, n), s = c[0] + dot_(x + 1, c + 1, m - 1);
            s *= tau[k];
            c[0] -= s;
            axpy_(c + 1, x + 1, m - 1, -s);
        }
    }
}

/* Eigenwerte (und Rotation der Spalten von z) der symmetrischen Tridiagonalmatrix (d, e) mit implizitem QL bzw.
 * QR und Wilkinson-Verschiebung (Bowdler, Martin, Reinsch, Wilkinson 1968; Golub/Van Loan 2013, §8.3.3, Alg.
 * 8.3.2). Abspaltung, wenn e_m^2 <= u^2 |d_m| |d_m+1| + 2^-1022 (u = 2^-53; relatives Kriterium, genau auch
 * für abgestufte Matrizen). Richtung je unzerlegtem Block wie LAPACK dsteqr: QL, wenn |d| am Ende nicht kleiner
 * ist als am Anfang, sonst QR (= QL auf dem gespiegelten Block). Höchstens 30 n Schritte. */
static int tql_(double *d, double *e, double *z, int n, int nz)
{
    const double u2 = SLC_TWO_M53 * SLC_TWO_M53, tiny = 0x1p-1022;
    int lo = 0, hi, l, m, i, it = 0, rev, maxit = 30 * n;
    while (lo < n) {
        for (hi = lo; hi < n - 1; hi++) {
            if (e[hi] * e[hi] <= (u2 * fabs(d[hi])) * fabs(d[hi + 1]) + tiny) { e[hi] = 0.0; break; }
        }
        if (hi == lo) { lo++; continue; }
        rev = fabs(d[hi]) < fabs(d[lo]);
        /* gespiegelte Indizes: Lage j des Blocks -> lo + hi - j; Nebendiagonale zwischen j und j + 1 */
#define DJ(j) d[rev ? lo + hi - (j) : (j)]
#define EJ(j) e[rev ? lo + hi - (j) - 1 : (j)]
#define CJ(j) (rev ? lo + hi - (j) : (j))
        for (l = lo; l <= hi; l++) {
            for (;;) {
                double g, r, s, c, p, f, b;
                for (m = l; m < hi; m++)
                    if (EJ(m) * EJ(m) <= (u2 * fabs(DJ(m))) * fabs(DJ(m + 1)) + tiny) { EJ(m) = 0.0; break; }
                if (m == l) break;
                if (++it > maxit) return 1;
                g = (DJ(l + 1) - DJ(l)) / (2.0 * EJ(l));
                r = hypot(g, 1.0);
                g = DJ(m) - DJ(l) + EJ(l) / (g + copysign(r, g));
                s = c = 1.0; p = 0.0;
                for (i = m - 1; i >= l; i--) {
                    f = s * EJ(i);
                    b = c * EJ(i);
                    r = hypot(f, g);
                    if (i + 1 < m) EJ(i + 1) = r;           /* EJ(m) bleibt 0 (Abspaltung bzw. Blockende) */
                    if (r == 0.0) {                         /* Unterlauf: Schritt abbrechen, neu abspalten */
                        DJ(i + 1) -= p;
                        break;
                    }
                    s = f / r;
                    c = g / r;
                    g = DJ(i + 1) - p;
                    r = (DJ(i) - g) * s + 2.0 * c * b;
                    p = s * r;
                    DJ(i + 1) = g + p;
                    g = c * r - b;
                    if (z) rot_cols(z + IX(0, CJ(i), nz), z + IX(0, CJ(i + 1), nz), 0, nz, c, s);
                }
                if (r == 0.0 && i >= l) continue;
                DJ(l) -= p;
                EJ(l) = g;
            }
        }
#undef DJ
#undef EJ
#undef CJ
        lo = hi + 1;
    }
    return 0;
}

int sl_eigen_sym(sl_ctx *cx, int n, const double *A, int want_vectors, double *values, double *vectors)
{
    double *a = NULL, *v = NULL, *d = NULL, *e = NULL, *w = NULL, tmp, big, mx = 0.0, sc = 1.0;
    int *idx = NULL, i, j, st = SL_OK, k, imax, ex;
    if (n < 0) return sl_fail(cx, SL_EARG, "eigen: negative Dimension");
    if (n == 0) return SL_OK;
    for (j = 0; j < n; j++)
        for (i = j; i < n; i++)
            if (!isfinite(A[IX(i, j, n)])) return sl_fail(cx, SL_ENONFINITE, "eigen: NA/NaN/Inf in der Matrix");
    a = (double *) malloc(sizeof(double) * (size_t) n * (size_t) n);
    d = (double *) malloc(sizeof(double) * (size_t) n);
    e = (double *) malloc(sizeof(double) * (size_t) n);
    w = (double *) malloc(sizeof(double) * (size_t) n * 2);
    idx = (int *) malloc(sizeof(int) * (size_t) n);
    if (want_vectors) v = (double *) malloc(sizeof(double) * (size_t) n * (size_t) n);
    if (!a || !d || !e || !w || !idx || (want_vectors && !v)) { st = sl_fail(cx, SL_ENOMEM, "eigen: kein Speicher"); goto done; }
    /* unteres Dreieck in beide Dreiecke; sehr große bzw. kleine Einträge mit einer Zweierpotenz skalieren (exakt) */
    for (j = 0; j < n; j++)
        for (i = j; i < n; i++) { a[IX(i, j, n)] = a[IX(j, i, n)] = A[IX(i, j, n)]; if (fabs(A[IX(i, j, n)]) > mx) mx = fabs(A[IX(i, j, n)]); }
    if (mx > 0x1p400 || (mx > 0.0 && mx < 0x1p-400)) {
        (void) frexp(mx, &ex);
        sc = ldexp(1.0, -ex);
        for (j = 0; j < n; j++) for (i = 0; i < n; i++) a[IX(i, j, n)] *= sc;
    }
    if (sl_interrupted(cx)) { st = SL_EINTR; goto done; }
    tridiag_(a, n, d, e, w + n, w);
    if (v) form_q_(a, n, w + n, v);
    if (sl_interrupted(cx)) { st = SL_EINTR; goto done; }
    if (tql_(d, e, v, n, n)) { st = sl_fail(cx, SL_ECONV, "eigen: QL-Verfahren konvergiert nicht (30 n Schritte)"); goto done; }
    if (sc != 1.0) for (i = 0; i < n; i++) d[i] /= sc;
    /* absteigend, stabil (Einfügen) */
    for (i = 0; i < n; i++) idx[i] = i;
    for (i = 1; i < n; i++) {
        k = idx[i];
        for (j = i - 1; j >= 0 && d[idx[j]] < d[k]; j--) idx[j + 1] = idx[j];
        idx[j + 1] = k;
    }
    for (i = 0; i < n; i++) values[i] = d[idx[i]];
    if (v) {
        for (j = 0; j < n; j++) {
            k = idx[j];
            big = -1.0; imax = 0;
            for (i = 0; i < n; i++)
                if (fabs(v[IX(i, k, n)]) > big) { big = fabs(v[IX(i, k, n)]); imax = i; }
            tmp = v[IX(imax, k, n)] < 0.0 ? -1.0 : 1.0;
            for (i = 0; i < n; i++) vectors[IX(i, j, n)] = tmp * v[IX(i, k, n)];
        }
    }
done:
    free(a); free(v); free(d); free(e); free(w); free(idx);
    return st;
}
