/*
 * src/ms_garch.c -- Hamilton-Filter des MS-GARCH-Modells (eigene Fassung)
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
 * .Call-Huelle C_ms_garch_filter (registriert in init.c, R-Seite
 * .ms_garch_filter in R/cores.R).
 */
#include <R.h>
#include <Rinternals.h>
#include <math.h>
#include <limits.h>

/* Argument als double-Vektor (umgewandelt wie as.numeric) mit Laengenpruefung */
static SEXP msg_num(SEXP x, R_xlen_t len, const char *name)
{
    if (!isNumeric(x) && !isLogical(x))
        error("ms_garch_filter: '%s' muss numerisch sein.", name);
    if (len >= 0 && XLENGTH(x) != len)
        error("ms_garch_filter: '%s' muss die L\303\244nge %d haben (erhalten: %d).",
              name, (int) len, (int) XLENGTH(x));
    return coerceVector(x, REALSXP);
}

static void ms_garch_filter(const double *y, int n, int K, const double *omega,
                            const double *alpha, const double *beta, const double *gamma,
                            const double *P, const double *xi0, double h1,
                            double *h, double *pred, double *filt, double *lB, double *loglik)
{
    const double two_pi = 2.0 * M_PI;
    double ll = 0.0;
    int ok = 1;
    for (int k = 0; k < K; k++) pred[(R_xlen_t) n * k] = xi0[k];
    for (int t = 0; t < n; t++) {
        /* Varianzpfade */
        if (t == 0) {
            for (int k = 0; k < K; k++) h[(R_xlen_t) n * k] = h1;
        } else {
            const double e = y[t - 1];
            const double e2 = e * e;
            const double ind = e < 0.0 ? 1.0 : 0.0;
            for (int k = 0; k < K; k++) {
                const double a = alpha[k] + gamma[k] * ind;
                h[t + (R_xlen_t) n * k] = omega[k] + a * e2 + beta[k] * h[t - 1 + (R_xlen_t) n * k];
            }
        }
        /* Dichten, Mischungsdichte und Log-Emissionen */
        const double y2 = y[t] * y[t];
        double f = 0.0;
        for (int k = 0; k < K; k++) {
            const double hk = h[t + (R_xlen_t) n * k];
            const double q = (-0.5 * y2) / hk;
            const double phi = exp(q) / sqrt(two_pi * hk);
            lB[t + (R_xlen_t) n * k] = q - 0.5 * log(two_pi * hk);
            filt[t + (R_xlen_t) n * k] = pred[t + (R_xlen_t) n * k] * phi;   /* Zaehler, unten geteilt */
            f = f + filt[t + (R_xlen_t) n * k];
        }
        if (!R_FINITE(f) || f <= 0.0) ok = 0;
        else ll = ll + log(f);
        for (int k = 0; k < K; k++) filt[t + (R_xlen_t) n * k] = filt[t + (R_xlen_t) n * k] / f;
        /* Vorhersage fuer t + 1 */
        if (t + 1 < n) {
            for (int j = 0; j < K; j++) {
                double s = 0.0;
                for (int i = 0; i < K; i++) s = s + P[i + (R_xlen_t) K * j] * filt[t + (R_xlen_t) n * i];
                pred[t + 1 + (R_xlen_t) n * j] = s;
            }
        }
    }
    *loglik = ok ? ll : R_NegInf;
}

SEXP C_ms_garch_filter(SEXP s_y, SEXP s_omega, SEXP s_alpha, SEXP s_beta, SEXP s_gamma,
                       SEXP s_P, SEXP s_xi0, SEXP s_h1)
{
    s_y = PROTECT(msg_num(s_y, -1, "y"));
    const R_xlen_t nn = XLENGTH(s_y);
    if (nn < 1) error("ms_garch_filter: 'y' darf nicht leer sein.");
    if (nn > INT_MAX) error("ms_garch_filter: 'y' ist zu lang.");
    const int n = (int) nn;
    s_omega = PROTECT(msg_num(s_omega, -1, "omega"));
    const R_xlen_t KK = XLENGTH(s_omega);
    if (KK < 1 || KK > 1000) error("ms_garch_filter: 'omega' muss 1 bis 1000 Werte haben (einen je Regime).");
    const int K = (int) KK;
    s_alpha = PROTECT(msg_num(s_alpha, K, "alpha"));
    s_beta = PROTECT(msg_num(s_beta, K, "beta"));
    s_gamma = PROTECT(msg_num(s_gamma, K, "gamma"));
    s_P = PROTECT(msg_num(s_P, (R_xlen_t) K * K, "P"));
    s_xi0 = PROTECT(msg_num(s_xi0, K, "xi0"));
    s_h1 = PROTECT(msg_num(s_h1, 1, "h1"));

    SEXP h = PROTECT(allocMatrix(REALSXP, n, K));
    SEXP pred = PROTECT(allocMatrix(REALSXP, n, K));
    SEXP filt = PROTECT(allocMatrix(REALSXP, n, K));
    SEXP lB = PROTECT(allocMatrix(REALSXP, n, K));
    double loglik = 0.0;
    ms_garch_filter(REAL(s_y), n, K, REAL(s_omega), REAL(s_alpha), REAL(s_beta), REAL(s_gamma),
                    REAL(s_P), REAL(s_xi0), REAL(s_h1)[0],
                    REAL(h), REAL(pred), REAL(filt), REAL(lB), &loglik);

    SEXP out = PROTECT(allocVector(VECSXP, 5));
    SEXP nms = PROTECT(allocVector(STRSXP, 5));
    SET_VECTOR_ELT(out, 0, ScalarReal(loglik)); SET_STRING_ELT(nms, 0, mkChar("loglik"));
    SET_VECTOR_ELT(out, 1, h);                  SET_STRING_ELT(nms, 1, mkChar("h"));
    SET_VECTOR_ELT(out, 2, pred);               SET_STRING_ELT(nms, 2, mkChar("pred"));
    SET_VECTOR_ELT(out, 3, filt);               SET_STRING_ELT(nms, 3, mkChar("filt"));
    SET_VECTOR_ELT(out, 4, lB);                 SET_STRING_ELT(nms, 4, mkChar("lB"));
    setAttrib(out, R_NamesSymbol, nms);
    UNPROTECT(14);
    return out;
}
