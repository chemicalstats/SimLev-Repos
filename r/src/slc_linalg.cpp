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
 *             Symmetrische Eigenwerte: zyklisches Jacobi-Verfahren (Jacobi 1846; Golub/Van Loan
 *             2013, §8.5.2–8.5.3) zeilenweise (p < q); Drehung nach Alg. 8.5.1 mit
 *             tau = (a_qq - a_pp) / (2 a_pq), t = sign(tau) / (|tau| + sqrt(1 + tau^2)),
 *             c = 1 / sqrt(1 + t^2), s = t c; neue Diagonale a_pp - t a_pq bzw. a_qq + t a_pq,
 *             a_pq = 0 exakt. Schwellenstrategie (eigene Regel, nach dem Gedanken in §8.5.3): in
 *             den ersten drei Durchläufen wird a_pq übergangen, wenn |a_pq| kleiner ist als die
 *             Hälfte des quadratischen Mittels der Nebendiagonale zu Beginn des Durchlaufs. Ende,
 *             wenn off(A) <= 2^-53 ||A||_F (||A||_F der Eingabe); höchstens 60 Durchläufe. Gelesen
 *             wird das untere Dreieck. Ausgabe absteigend (stabil sortiert); Vorzeichen jedes
 *             Vektors: die betragsgrößte Komponente ist positiv, bei Gleichstand die erste.
 *             Speicher (seit 1.6.0): je Drehung nur die Spalten p und q (zusammenhängend, mit GCC/Clang in
 *             Vektoren zu je zwei Werten); die Zeilen trägt die Schleife blockweise nach (siehe sl_eigen_sym).
 *             Drehfolge und Rechnung je Element wie bis 1.5.2, Ergebnis bitgleich, bei n = 500 etwa 2,4-mal so schnell.
 * Quellen:    Golub, G. H., Van Loan, C. F. (2013). Matrix Computations, 4. Aufl., Johns Hopkins
 *             University Press, §3.1, §4.2, §4.3, §8.5.
 *             Jacobi, C. G. J. (1846). Über ein leichtes Verfahren, die in der Theorie der
 *             Säcularstörungen vorkommenden Gleichungen numerisch aufzulösen. Journal für die reine
 *             und angewandte Mathematik 30, 51–94.
 *             Demmel, J., Veselić, K. (1992). Jacobi's method is more accurate than QR. SIAM Journal
 *             on Matrix Analysis and Applications 13(4), 1204–1245 (Begründung der Wahl).
 *             Higham, N. J. (2002). Accuracy and Stability of Numerical Algorithms, 2. Aufl., SIAM,
 *             Kap. 4 (kompensierte Summen), Kap. 8 (Dreieckssysteme), Kap. 10 (Cholesky).
 *             Neumaier, A. (1974). ZAMM 54(1), 39–51 (kompensierte Summe).
 * Konstanten: 2^-52, 2^-53 (Gleitkomma-Grenzen, slc_constants.h); 60 Durchläufe und Schwelle 1/2
 *             eigene Festlegung.
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

/* ── Symmetrische Eigenwerte (zyklisches Jacobi) ── */

/* Rotation zweier Spalten auf den Zeilen lo ... hi-1: x' = c x - s y, y' = s x + c y (seit 1.6.0 als eigene
 * Schleife über zusammenhängende Spalten, mit GCC/Clang in Vektoren zu je zwei Werten; dieselben Operationen
 * je Element, also dasselbe Ergebnis wie bis 1.5.2) */
#if defined(__GNUC__) || defined(__clang__)
typedef double slc_v2d __attribute__((vector_size(16), aligned(8)));
#endif
/* Blockgröße der Umlagerungen im Jacobi-Verfahren */
#define SLC_JB 32

/* a[j, i] = a[i, j] für lo <= i < j < n (unteres Dreieck aus dem oberen, blockweise) */
static void sym_lower(double *a, int n, int lo)
{
    int ib, jb, i, j, ie, je;
    for (ib = lo; ib < n; ib += SLC_JB) {
        ie = ib + SLC_JB < n ? ib + SLC_JB : n;
        for (jb = ib; jb < n; jb += SLC_JB) {
            je = jb + SLC_JB < n ? jb + SLC_JB : n;
            for (j = jb; j < je; j++)
                for (i = ib; i < ie && i < j; i++) a[IX(j, i, n)] = a[IX(i, j, n)];
        }
    }
}

/* Spalten x = q ... n-1: Zeilen s in [lo, q) aus Spalte s (Zeile x), blockweise */
static void pre_gather(double *a, int n, int lo, int q)
{
    int xb, x, s, xe;
    for (xb = q; xb < n; xb += SLC_JB) {
        xe = xb + SLC_JB < n ? xb + SLC_JB : n;
        for (s = lo; s < q; s++)
            for (x = xb; x < xe; x++) a[IX(s, x, n)] = a[IX(x, s, n)];
    }
}

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

/* off(A) = sqrt(sum_{p != q} a_pq^2) mit Skalierung (kein Über-/Unterlauf) */
static double offnorm(int n, const double *a)
{
    double mx = 0.0, q;
    slc_acc s;
    int p, r;
    for (r = 1; r < n; r++)
        for (p = 0; p < r; p++)
            if (fabs(a[IX(p, r, n)]) > mx) mx = fabs(a[IX(p, r, n)]);
    if (mx == 0.0) return 0.0;
    slc_acc_init(&s, 0.0);
    for (r = 1; r < n; r++)
        for (p = 0; p < r; p++) { q = a[IX(p, r, n)] / mx; slc_acc_add(&s, q * q); }
    return mx * sqrt(2.0 * slc_acc_val(&s));
}

int sl_eigen_sym(sl_ctx *cx, int n, const double *A, int want_vectors, double *values, double *vectors)
{
    double *a = NULL, *v = NULL, *d = NULL, normA, off, thr, apq, tau, t, c, s, tmp, big;
    int *idx = NULL, i, j, p, q, r, sweep, conv = 0, st = SL_OK, k, imax;
    if (n < 0) return sl_fail(cx, SL_EARG, "eigen: negative Dimension");
    if (n == 0) return SL_OK;
    for (j = 0; j < n; j++)
        for (i = j; i < n; i++)
            if (!isfinite(A[IX(i, j, n)])) return sl_fail(cx, SL_ENONFINITE, "eigen: NA/NaN/Inf in der Matrix");
    a = (double *) malloc(sizeof(double) * (size_t) n * (size_t) n);
    d = (double *) malloc(sizeof(double) * (size_t) n);
    idx = (int *) malloc(sizeof(int) * (size_t) n);
    if (want_vectors) v = (double *) malloc(sizeof(double) * (size_t) n * (size_t) n);
    if (!a || !d || !idx || (want_vectors && !v)) { st = sl_fail(cx, SL_ENOMEM, "eigen: kein Speicher"); goto done; }
    for (j = 0; j < n; j++)
        for (i = j; i < n; i++) a[IX(i, j, n)] = a[IX(j, i, n)] = A[IX(i, j, n)];
    if (v) for (j = 0; j < n; j++) for (i = 0; i < n; i++) v[IX(i, j, n)] = (i == j) ? 1.0 : 0.0;
    normA = slc_nrm2((int64_t) n * n, a, 1);
    for (sweep = 0; sweep < 60; sweep++) {
        if (sweep > 0) sym_lower(a, n, 0);                 /* oberes Dreieck ist aktuell (siehe unten) */
        off = offnorm(n, a);
        if (off <= SLC_TWO_M53 * normA) { conv = 1; break; }
        if (sl_interrupted(cx)) { st = SL_EINTR; goto done; }
        thr = sweep < 3 ? 0.5 * off / sqrt((double) n * (double) (n - 1)) : 0.0;
        /* Dieselben Drehungen in derselben Reihenfolge wie bis 1.5.2 (dort wurden je Drehung die Spalten und
         * die Zeilen p und q geschrieben). Jetzt nur die Spalten: Zu Beginn der Schleife über q für festes p ist
         * der Block [p, n)^2 symmetrisch und die Spalten x >= p sind in den Zeilen < p aktuell. Vor der Drehung
         * (p, q) holt Spalte q die Zeilen s in (p, q) aus Spalte s (Zeile q; dort steht der Wert seit Schritt s),
         * blockweise vorab für die folgenden Spalten; danach die Drehung der Spalten p und q. Nach der Schleife:
         * Zeile p aus Spalte p (Spalten > p) und unteres Dreieck des Blocks (p, n)^2 aus dem oberen. */
        for (p = 0; p < n - 1; p++) {
            double *cp = a + IX(0, p, n);
            int blk = p + 1;
            for (q = p + 1; q < n; q++) {
                double *cq = a + IX(0, q, n);
                if (q - blk >= SLC_JB) { pre_gather(a, n, blk, q); blk = q; }
                for (r = blk; r < q; r++) cq[r] = a[IX(q, r, n)];
                apq = cp[q];                           /* = a[p, q] */
                if (apq == 0.0 || fabs(apq) < thr) continue;
                tau = (cq[q] - cp[p]) / (2.0 * apq);
                if (fabs(tau) > 1e150) t = 0.5 / tau;
                else t = (tau >= 0.0 ? 1.0 : -1.0) / (fabs(tau) + sqrt(1.0 + tau * tau));
                c = 1.0 / sqrt(1.0 + t * t);
                s = t * c;
                rot_cols(cp, cq, 0, p, c, s);          /* Spalten p und q ohne die Zeilen p und q */
                rot_cols(cp, cq, p + 1, q, c, s);
                rot_cols(cp, cq, q + 1, n, c, s);
                cp[p] -= t * apq;
                cq[q] += t * apq;
                cq[p] = cp[q] = 0.0;
                if (v) rot_cols(v + IX(0, p, n), v + IX(0, q, n), 0, n, c, s);
            }
            for (r = p + 1; r < n; r++) a[IX(p, r, n)] = cp[r];
            sym_lower(a, n, p + 1);
        }
    }
    if (!conv) { st = sl_fail(cx, SL_ECONV, "eigen: Jacobi-Verfahren konvergiert nicht (60 Durchläufe)"); goto done; }
    /* absteigend, stabil (Einfügen) */
    for (i = 0; i < n; i++) { d[i] = a[IX(i, i, n)]; idx[i] = i; }
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
    free(a); free(v); free(d); free(idx);
    return st;
}
