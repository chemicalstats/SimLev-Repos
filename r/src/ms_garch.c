/*
 * src/ms_garch.c -- .Call-Huelle des MS-GARCH-Filters
 *
 * Die Rechnung steht seit Etappe 7.2 in src/ms_garch_impl.c (ohne R-Bezug,
 * Modell, Formeln und fester Rechenablauf siehe dort); diese Datei prueft und
 * wandelt die Argumente wie as.numeric, legt die Ergebnismatrizen an und ruft
 * simlev_ms_garch_filter auf. Den Kern nutzt auch Python
 * (simlev._ext, Kopie in python/src/).
 *
 * .Call-Huelle C_ms_garch_filter (registriert in init.c, R-Seite
 * .ms_garch_filter in R/cores.R).
 */
#include <R.h>
#include <Rinternals.h>
#include <limits.h>

#include "ms_garch_impl.h"

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
    simlev_ms_garch_filter(REAL(s_y), n, K, REAL(s_omega), REAL(s_alpha), REAL(s_beta), REAL(s_gamma),
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
