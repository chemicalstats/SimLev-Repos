/* core/slc_lsq.c – kleinste Quadrate (Householder-QR mit begrenzter Spaltenpivotisierung) und
 * Logit-IRLS (SimLev core, Etappe 9.2)
 * Verfahren:  sl_lsfit: die Zeilen von X und y werden mit sqrt(w_i) skaliert; dann Householder-QR
 *             (Golub/Van Loan 2013, §5.1.2–5.1.3, §5.2.2): je Schritt k der Spiegel
 *             H = I - beta v v' mit v = x + sign(x_1) ||x|| e_1 (ohne Auslöschung), beta =
 *             1 / (||x|| (||x|| + |x_1|)), angewandt auf die übrigen Spalten und auf y.
 *             Begrenzte Spaltenpivotisierung (pivot = 1, dokumentiertes Verhalten von qr()/lm() in
 *             R, Hilfeseite ?qr: Toleranz, "limited column pivoting"): die Spalten bleiben in ihrer
 *             Reihenfolge; ist die Restnorm der Spalte k nach den vorigen Spiegelungen
 *             <= tol * ihre Ausgangsnorm, wandert sie ans Ende (die übrigen rücken vor, auch zuvor
 *             ausgefallene; diese Reihenfolge entspricht der von qr()$pivot im Orakel) und zählt
 *             nicht zum Rang. pivot = 2: volle Pivotisierung nach Businger/Golub (1965), je Schritt
 *             die Spalte mit der größten Restnorm; Ende, wenn diese <= tol * die größte
 *             Ausgangsnorm der übrigen Spalten ist. Lösung R b = (Q'y)_{1..rank} durch
 *             Rückwärtseinsetzen; ausgefallene Koeffizienten NA. fitted = y - r mit dem
 *             Residuum r = W^-1/2 Q (0, (Q'y)_{rank+1..m}) (genauer als X b bei kleinem Residuum;
 *             Zeilen mit Gewicht 0: X b, NA als 0). Skalarprodukte und Normen kompensiert (Neumaier 1974),
 *             Normen mit Skalierung.
 *             sl_logit_irls: iterativ neu gewichtete kleinste Quadrate für das Logit-Modell
 *             (McCullagh/Nelder 1989, §2.5 und §4.4): Arbeitsgröße z = eta + (y - mu) / (mu (1 - mu)),
 *             Gewichte mu (1 - mu), Schritt über sl_lsfit (Toleranz 1e-7). Start
 *             mu_0 = (y + 1/2) / 2 (McCullagh/Nelder 1989, §4.4.1, wie binomial()$initialize in R).
 *             mu = 1 / (1 + e^-eta) wird auf [2^-52, 1 - 2^-52] begrenzt (eigene Regel; die Devianz
 *             bleibt dadurch endlich, eine Schrittweitenhalbierung entfällt). Abbruch, wenn
 *             |D - D_alt| / (|D| + 0.1) < tol (dokumentierte Vorgabe von glm.control), höchstens maxit
 *             Schritte. Warnungen: keine Konvergenz; angepasste Wahrscheinlichkeiten < 10 * 2^-52
 *             bzw. > 1 - 10 * 2^-52 ("numerisch 0 oder 1").
 * Quellen:    Golub, G. H., Van Loan, C. F. (2013). Matrix Computations, 4. Aufl., Johns Hopkins
 *             University Press, §5.1 (Householder), §5.2 (QR), §5.4.2 (Rang und Pivotisierung).
 *             Businger, P., Golub, G. H. (1965). Linear least squares solutions by Householder
 *             transformations. Numerische Mathematik 7(3), 269–276.
 *             Higham, N. J. (2002). Accuracy and Stability of Numerical Algorithms, 2. Aufl., SIAM,
 *             Kap. 19 (Householder-QR, kleinste Quadrate), Kap. 4 (Summation).
 *             McCullagh, P., Nelder, J. A. (1989). Generalized Linear Models, 2. Aufl., Chapman &
 *             Hall, §2.5, Kap. 4.
 *             R Core Team: Hilfeseiten ?qr, ?lm.fit, ?glm.control, ?family (nur dokumentiertes
 *             Verhalten: Toleranz 1e-7, begrenzte Pivotisierung, epsilon 1e-8, maxit 25, Startwert).
 *             Neumaier, A. (1974). ZAMM 54(1), 39–51.
 * Konstanten: 2^-52 (Gleitkomma-Grenze); Toleranzen aus der Schnittstelle.
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: R 4.3.3 qr, qr.coef, lm.fit, lm.wfit, glm(family = binomial()) (nur Plausibilität).
 */
#include "slc_internal.h"
#include "slc_la_internal.h"
#include "slc_constants.h"

#include <stdlib.h>

#define IX(i, j, ld) ((size_t) (i) + (size_t) (j) * (size_t) (ld))

/* Spalte k ans Ende (Stelle lim - 1) rotieren, die übrigen rücken vor (Matrix, Ausgangsnormen,
 * Reihenfolge); mit lim = n stehen ausgefallene Spalten am Ende in der Reihenfolge, in der sie
 * erkannt wurden */
static void rotate_left(int m, int k, int lim, double *A, double *onorm, int *perm, double *tmp)
{
    int i, j, pk = perm[k];
    double ok = onorm[k];
    for (i = 0; i < m; i++) tmp[i] = A[IX(i, k, m)];
    for (j = k; j < lim - 1; j++) {
        for (i = 0; i < m; i++) A[IX(i, j, m)] = A[IX(i, j + 1, m)];
        onorm[j] = onorm[j + 1];
        perm[j] = perm[j + 1];
    }
    for (i = 0; i < m; i++) A[IX(i, lim - 1, m)] = tmp[i];
    onorm[lim - 1] = ok;
    perm[lim - 1] = pk;
}

static void swap_cols(int m, int a, int b, double *A, double *onorm, int *perm)
{
    int i, t;
    double d;
    if (a == b) return;
    for (i = 0; i < m; i++) { d = A[IX(i, a, m)]; A[IX(i, a, m)] = A[IX(i, b, m)]; A[IX(i, b, m)] = d; }
    d = onorm[a]; onorm[a] = onorm[b]; onorm[b] = d;
    t = perm[a]; perm[a] = perm[b]; perm[b] = t;
}

/* Spiegel (v_k = vk, v_i = A[i, k] für i > k, beta) auf den Vektor b (Zeilen k ... m-1) anwenden */
static void apply_house(int m, int k, const double *A, double vk, double beta, double *b)
{
    slc_acc a;
    double g;
    int i;
    slc_acc_init(&a, vk * b[k]);
    for (i = k + 1; i < m; i++) slc_acc_add(&a, A[IX(i, k, m)] * b[i]);
    g = beta * slc_acc_val(&a);
    if (g == 0.0) return;
    b[k] -= g * vk;
    for (i = k + 1; i < m; i++) b[i] -= g * A[IX(i, k, m)];
}

int sl_lsfit(sl_ctx *cx, int m, int n, const double *X, const double *y, const double *w,
             double tol, int pivot, double *coef, double *fitted, int *rank, int32_t *perm)
{
    double *A = NULL, *b = NULL, *onorm = NULL, *tmp = NULL, *vks = NULL, *betas = NULL, *sol = NULL;
    int *pm = NULL, i, j, k, lim, st = SL_OK, best;
    double sw, r, x1, sigma, alpha, vk, beta, rmax, omax, na = slc_na_real();
    slc_acc a;
    if (m < 0 || n < 0) return sl_fail(cx, SL_EARG, "lm: negative Dimension");
    if (m == 0) return sl_fail(cx, SL_ESMALL, "lm: 0 (nicht-NA) Fälle");
    if (pivot != 1 && pivot != 2) return sl_fail(cx, SL_EARG, "lm: pivot muss 1 oder 2 sein");
    if (!(tol >= 0.0) || !isfinite(tol)) return sl_fail(cx, SL_EARG, "lm: tol muss eine Zahl >= 0 sein");
    if (!slc_all_finite((int64_t) m * n, X)) return sl_fail(cx, SL_ENONFINITE, "lm: NA/NaN/Inf in x");
    if (!slc_all_finite(m, y)) return sl_fail(cx, SL_ENONFINITE, "lm: NA/NaN/Inf in y");
    if (w) {
        if (!slc_all_finite(m, w)) return sl_fail(cx, SL_ENONFINITE, "lm: NA/NaN/Inf in w");
        for (i = 0; i < m; i++) if (w[i] < 0.0) return sl_fail(cx, SL_EARG, "lm: negative Gewichte");
    }
    A = (double *) malloc(sizeof(double) * ((size_t) m * (size_t) n + 1));
    b = (double *) malloc(sizeof(double) * (size_t) m);
    tmp = (double *) malloc(sizeof(double) * (size_t) m);
    onorm = (double *) malloc(sizeof(double) * ((size_t) n + 1));
    vks = (double *) malloc(sizeof(double) * ((size_t) n + 1));
    betas = (double *) malloc(sizeof(double) * ((size_t) n + 1));
    sol = (double *) malloc(sizeof(double) * ((size_t) n + 1));
    pm = (int *) malloc(sizeof(int) * ((size_t) n + 1));
    if (!A || !b || !tmp || !onorm || !vks || !betas || !sol || !pm) { st = sl_fail(cx, SL_ENOMEM, "lm: kein Speicher"); goto done; }
    for (i = 0; i < m; i++) {
        sw = w ? sqrt(w[i]) : 1.0;
        b[i] = sw * y[i];
        for (j = 0; j < n; j++) A[IX(i, j, m)] = sw * X[IX(i, j, m)];
    }
    for (j = 0; j < n; j++) { onorm[j] = slc_nrm2(m, A + (size_t) j * (size_t) m, 1); pm[j] = j; }
    k = 0; lim = n;
    while (k < lim && k < m) {
        if (pivot == 2) {
            rmax = -1.0; omax = 0.0; best = k;
            for (j = k; j < lim; j++) {
                r = slc_nrm2(m - k, A + IX(k, j, m), 1);
                if (r > rmax) { rmax = r; best = j; }
                if (onorm[j] > omax) omax = onorm[j];
            }
            if (rmax <= tol * omax) break;
            swap_cols(m, k, best, A, onorm, pm);
            sigma = rmax;
        } else {
            sigma = slc_nrm2(m - k, A + IX(k, k, m), 1);
            if (sigma <= tol * onorm[k]) {
                rotate_left(m, k, n, A, onorm, pm, tmp);
                lim--;
                continue;
            }
        }
        /* Spiegel für A[k:m, k] */
        x1 = A[IX(k, k, m)];
        alpha = x1 >= 0.0 ? -sigma : sigma;          /* R_kk */
        vk = x1 - alpha;                             /* = x1 + sign(x1) sigma */
        beta = 1.0 / (sigma * (sigma + fabs(x1)));
        vks[k] = vk; betas[k] = beta;
        for (j = k + 1; j < n; j++) apply_house(m, k, A, vk, beta, A + (size_t) j * (size_t) m);
        apply_house(m, k, A, vk, beta, b);
        A[IX(k, k, m)] = alpha;
        k++;
        if (((k + 1) & 0xFF) == 0 && sl_interrupted(cx)) { st = SL_EINTR; goto done; }
    }
    /* Rückwärtseinsetzen R b = (Q'y)_{0..k-1} */
    for (i = k - 1; i >= 0; i--) {
        slc_acc_init(&a, b[i]);
        for (j = i + 1; j < k; j++) slc_acc_add(&a, -(A[IX(i, j, m)] * sol[j]));
        sol[i] = slc_acc_val(&a) / A[IX(i, i, m)];
    }
    for (j = 0; j < n; j++) coef[j] = na;
    for (j = 0; j < k; j++) coef[pm[j]] = sol[j];
    if (rank) *rank = k;
    if (perm) for (j = 0; j < n; j++) perm[j] = (int32_t) (pm[j] + 1);
    if (fitted) {
        /* Residuum r_w = Q (0, ..., 0, (Q'y_w)_{rank+1..m}) wie qr.resid, fitted = y - r_w / sqrt(w);
         * Zeilen mit Gewicht 0: fitted = X b */
        for (i = 0; i < m; i++) tmp[i] = i < k ? 0.0 : b[i];
        for (j = k - 1; j >= 0; j--) apply_house(m, j, A, vks[j], betas[j], tmp);
        for (i = 0; i < m; i++) {
            sw = w ? sqrt(w[i]) : 1.0;
            if (sw > 0.0) { fitted[i] = y[i] - tmp[i] / sw; continue; }
            slc_acc_init(&a, 0.0);
            for (j = 0; j < n; j++) if (!isnan(coef[j])) slc_acc_add(&a, X[IX(i, j, m)] * coef[j]);
            fitted[i] = slc_acc_val(&a);
        }
    }
done:
    free(A); free(b); free(tmp); free(onorm); free(vks); free(betas); free(sol); free(pm);
    return st;
}

/* ── Logit-IRLS ── */

#define MU_EPS SLC_TWO_M52

static double plogis_clamped(double eta, int *edge)
{
    double e, mu;
    if (eta >= 0.0) { e = exp(-eta); mu = 1.0 / (1.0 + e); }
    else { e = exp(eta); mu = e / (1.0 + e); }
    if (mu < 10.0 * MU_EPS || mu > 1.0 - 10.0 * MU_EPS) *edge = 1;
    if (mu < MU_EPS) mu = MU_EPS;
    if (mu > 1.0 - MU_EPS) mu = 1.0 - MU_EPS;
    return mu;
}

static double deviance(int m, const double *y, const double *mu)
{
    slc_acc a;
    int i;
    slc_acc_init(&a, 0.0);
    for (i = 0; i < m; i++) {
        if (y[i] > 0.0) slc_acc_add(&a, y[i] * log(y[i] / mu[i]));
        if (y[i] < 1.0) slc_acc_add(&a, (1.0 - y[i]) * log((1.0 - y[i]) / (1.0 - mu[i])));
    }
    return 2.0 * slc_acc_val(&a);
}

int sl_logit_irls(sl_ctx *cx, int m, int n, const double *X, const double *y,
                  int maxit, double tol, double *coef, int *converged)
{
    double *mu = NULL, *eta = NULL, *z = NULL, *wt = NULL, *fit = NULL, dold, dnew, v;
    int i, it, st = SL_OK, conv = 0, edge = 0, rk;
    if (m < 0 || n < 0) return sl_fail(cx, SL_EARG, "glm: negative Dimension");
    if (m == 0) return sl_fail(cx, SL_ESMALL, "glm: 0 (nicht-NA) Fälle");
    if (maxit < 1) return sl_fail(cx, SL_EARG, "glm: maxit muss >= 1 sein");
    if (!(tol > 0.0) || !isfinite(tol)) return sl_fail(cx, SL_EARG, "glm: tol muss positiv sein");
    if (!slc_all_finite((int64_t) m * n, X)) return sl_fail(cx, SL_ENONFINITE, "glm: NA/NaN/Inf in x");
    if (!slc_all_finite(m, y)) return sl_fail(cx, SL_ENONFINITE, "glm: NA/NaN/Inf in y");
    for (i = 0; i < m; i++)
        if (y[i] < 0.0 || y[i] > 1.0) return sl_fail(cx, SL_EARG, "glm: y muss in [0, 1] liegen");
    mu = (double *) malloc(sizeof(double) * (size_t) m);
    eta = (double *) malloc(sizeof(double) * (size_t) m);
    z = (double *) malloc(sizeof(double) * (size_t) m);
    wt = (double *) malloc(sizeof(double) * (size_t) m);
    fit = (double *) malloc(sizeof(double) * (size_t) m);
    if (!mu || !eta || !z || !wt || !fit) { st = sl_fail(cx, SL_ENOMEM, "glm: kein Speicher"); goto done; }
    for (i = 0; i < m; i++) {
        mu[i] = (y[i] + 0.5) / 2.0;
        eta[i] = log(mu[i] / (1.0 - mu[i]));
    }
    dold = deviance(m, y, mu);
    for (it = 0; it < maxit; it++) {
        for (i = 0; i < m; i++) {
            v = mu[i] * (1.0 - mu[i]);
            wt[i] = v;
            z[i] = eta[i] + (y[i] - mu[i]) / v;
        }
        st = sl_lsfit(cx, m, n, X, z, wt, 1e-7, 1, coef, fit, &rk, NULL);
        if (st != SL_OK) {
            if (st == SL_ENONFINITE) sl_fail(cx, st, "glm: nicht endliche Arbeitsgröße im IRLS-Schritt %d", it + 1);
            goto done;
        }
        edge = 0;
        for (i = 0; i < m; i++) { eta[i] = fit[i]; mu[i] = plogis_clamped(eta[i], &edge); }
        dnew = deviance(m, y, mu);
        if (fabs(dnew - dold) / (fabs(dnew) + 0.1) < tol) { conv = 1; break; }
        dold = dnew;
    }
    if (!conv) sl_warn(cx, "glm: Algorithmus konvergiert nicht");
    if (edge) sl_warn(cx, "glm: angepasste Wahrscheinlichkeiten numerisch 0 oder 1");
    if (converged) *converged = conv;
done:
    free(mu); free(eta); free(z); free(wt); free(fit);
    return st;
}
