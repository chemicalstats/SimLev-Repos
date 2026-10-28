/*
 * src/slc_r_linalg.c -- R-Huellen (.Call) der Etappe 9.2 der C-Bibliothek slc: lineare Algebra,
 * Matrixprodukt, kleinste Quadrate und Logit-IRLS, Stineman, Glaettungsspline, Kerndichte
 *
 * Die Kerne (slc_linalg.c, slc_matmul.c, slc_lsq.c, slc_stine.c, slc_spline.c, slc_kde.c) sind
 * Kopien der kanonischen Quellen in core/ (tools/core_sync.py); nur diese Huelle gibt es nur hier.
 * Registrierung in init.c (Block 9.2), die R-Seite steht in R/slc_linalg.R (interne Funktionen
 * .sl_*). Rueckmeldungen wie slc_r.c (Entwurf C.4): Warnungen nach dem Aufruf in Reihenfolge,
 * Fehler mit dem Text des Kerns (Rf_errorcall(R_NilValue, ...), wie stop(call. = FALSE)).
 * Die Huellen pruefen nur Typ und Laenge; Matrizen kommen als double mit dim-Attribut.
 */
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Utils.h>

#include <string.h>

#include "slc.h"

/* ── Kontext und Rueckmeldungen (wie slc_r.c) ── */

static void chk_int(void *d) { (void) d; R_CheckUserInterrupt(); }
static int r_interrupted(void *h) { (void) h; return !R_ToplevelExec(chk_int, NULL); }

static void ctx_init(sl_ctx *cx)
{
    sl_ctx_init(cx);
    cx->interrupted = r_interrupted;
}

static void finish(sl_ctx *cx, int st, int nprot)
{
    int i;
    char msg[SL_MSG_LEN];
    for (i = 0; i < cx->n_warn; i++) Rf_warningcall(R_NilValue, "%s", cx->warn[i]);
    if (st != SL_OK) {
        memcpy(msg, cx->msg, SL_MSG_LEN);
        if (nprot) UNPROTECT(nprot);
        if (st == SL_EINTR) R_CheckUserInterrupt();
        Rf_errorcall(R_NilValue, "%s", msg);
    }
}

static void need_real(SEXP x, const char *what)
{
    if (TYPEOF(x) != REALSXP) Rf_errorcall(R_NilValue, "interner Fehler: %s muss double sein", what);
}

static int len_int(SEXP x, const char *what)
{
    need_real(x, what);
    if (XLENGTH(x) > 2147483647) Rf_errorcall(R_NilValue, "interner Fehler: %s ist zu lang", what);
    return (int) XLENGTH(x);
}

static void dims(SEXP x, int *nr, int *nc, const char *what)
{
    SEXP d;
    need_real(x, what);
    d = Rf_getAttrib(x, R_DimSymbol);
    if (TYPEOF(d) != INTSXP || XLENGTH(d) != 2) Rf_errorcall(R_NilValue, "interner Fehler: %s muss eine Matrix sein", what);
    *nr = INTEGER(d)[0];
    *nc = INTEGER(d)[1];
}

static double num1(SEXP x, const char *what)
{
    if (TYPEOF(x) != REALSXP || XLENGTH(x) != 1)
        Rf_errorcall(R_NilValue, "interner Fehler: %s muss eine Zahl (double, Laenge 1) sein", what);
    return REAL(x)[0];
}

static int int1(SEXP x, const char *what)
{
    double v = num1(x, what);
    if (!(v >= -2147483647.0 && v <= 2147483647.0) || v != (double) (int) v)
        Rf_errorcall(R_NilValue, "interner Fehler: %s muss ganzzahlig sein", what);
    return (int) v;
}

static int lgl1(SEXP x, const char *what)
{
    if (TYPEOF(x) != LGLSXP || XLENGTH(x) != 1 || LOGICAL(x)[0] == NA_LOGICAL)
        Rf_errorcall(R_NilValue, "interner Fehler: %s muss TRUE oder FALSE sein", what);
    return LOGICAL(x)[0];
}

static SEXP new_mat(int nr, int nc)
{
    return Rf_allocMatrix(REALSXP, nr, nc);
}

static SEXP named_list(int n, const char **names)
{
    SEXP out = PROTECT(Rf_allocVector(VECSXP, n)), nm = PROTECT(Rf_allocVector(STRSXP, n));
    int i;
    for (i = 0; i < n; i++) SET_STRING_ELT(nm, i, Rf_mkChar(names[i]));
    Rf_setAttrib(out, R_NamesSymbol, nm);
    UNPROTECT(2);
    return out;
}

/* ── lineare Algebra ── */

SEXP C_sl_chol(SEXP A)
{
    sl_ctx cx;
    int nr, nc, st;
    SEXP R;
    dims(A, &nr, &nc, "x");
    if (nr != nc) Rf_errorcall(R_NilValue, "chol: Matrix nicht quadratisch");
    ctx_init(&cx);
    R = PROTECT(new_mat(nr, nr));
    st = sl_chol(&cx, nr, REAL(A), REAL(R));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return R;
}

SEXP C_sl_chol_band(SEXP ab, SEXP kd)
{
    sl_ctx cx;
    int nr, nc, st;
    SEXP out;
    dims(ab, &nr, &nc, "ab");
    if (nr != int1(kd, "kd") + 1) Rf_errorcall(R_NilValue, "interner Fehler: ab muss kd + 1 Zeilen haben");
    ctx_init(&cx);
    out = PROTECT(Rf_duplicate(ab));
    st = sl_chol_band(&cx, nc, nr - 1, REAL(out));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}

SEXP C_sl_trisolve(SEXP R, SEXP B, SEXP upper, SEXP trans)
{
    sl_ctx cx;
    int nr, nc, br, bc, st;
    SEXP out;
    dims(R, &nr, &nc, "r");
    dims(B, &br, &bc, "x");
    if (nr != nc || br != nr) Rf_errorcall(R_NilValue, "backsolve: Dimensionen passen nicht");
    ctx_init(&cx);
    out = PROTECT(Rf_duplicate(B));
    st = sl_trisolve(&cx, nr, bc, REAL(R), lgl1(upper, "upper.tri"), lgl1(trans, "transpose"), REAL(out));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}

SEXP C_sl_solve_spd(SEXP A, SEXP B)
{
    sl_ctx cx;
    int nr, nc, br, bc, st;
    SEXP out;
    dims(A, &nr, &nc, "a");
    dims(B, &br, &bc, "b");
    if (nr != nc) Rf_errorcall(R_NilValue, "solve: Matrix nicht quadratisch");
    if (br != nr) Rf_errorcall(R_NilValue, "solve: Dimensionen von a und b passen nicht");
    ctx_init(&cx);
    out = PROTECT(Rf_duplicate(B));
    st = sl_solve_spd(&cx, nr, bc, REAL(A), REAL(out), NULL);
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}

SEXP C_sl_logdet_spd(SEXP A)
{
    sl_ctx cx;
    int nr, nc, st;
    double ld = 0.0;
    dims(A, &nr, &nc, "x");
    if (nr != nc) Rf_errorcall(R_NilValue, "determinant: Matrix nicht quadratisch");
    ctx_init(&cx);
    st = sl_logdet_spd(&cx, nr, REAL(A), &ld);
    finish(&cx, st, 0);
    return Rf_ScalarReal(ld);
}

SEXP C_sl_eigen_sym(SEXP A, SEXP vectors)
{
    static const char *nm[] = {"values", "vectors"};
    sl_ctx cx;
    int nr, nc, st, wv;
    SEXP out, val, vec = R_NilValue;
    dims(A, &nr, &nc, "x");
    if (nr != nc) Rf_errorcall(R_NilValue, "eigen: Matrix nicht quadratisch");
    wv = lgl1(vectors, "vectors");
    ctx_init(&cx);
    out = PROTECT(named_list(2, nm));
    val = Rf_allocVector(REALSXP, nr);
    SET_VECTOR_ELT(out, 0, val);
    if (wv) { vec = new_mat(nr, nr); SET_VECTOR_ELT(out, 1, vec); }
    st = sl_eigen_sym(&cx, nr, REAL(A), wv, REAL(val), wv ? REAL(vec) : NULL);
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}

/* ── Matrixprodukt ── */

/* dimnames(C) = list(Namen ia von A, Namen ib von B), wenn eine Seite Namen hat (wie %*%) */
static void set_dn(SEXP C, SEXP A, int ia, SEXP B, int ib)
{
    SEXP da = Rf_getAttrib(A, R_DimNamesSymbol), db = Rf_getAttrib(B, R_DimNamesSymbol), dn;
    SEXP ra = Rf_isNull(da) ? R_NilValue : VECTOR_ELT(da, ia), rb = Rf_isNull(db) ? R_NilValue : VECTOR_ELT(db, ib);
    if (Rf_isNull(ra) && Rf_isNull(rb)) return;
    dn = PROTECT(Rf_allocVector(VECSXP, 2));
    SET_VECTOR_ELT(dn, 0, ra);
    SET_VECTOR_ELT(dn, 1, rb);
    Rf_setAttrib(C, R_DimNamesSymbol, dn);
    UNPROTECT(1);
}

SEXP C_sl_matmul(SEXP A, SEXP B)
{
    int m, k, k2, n;
    SEXP C;
    dims(A, &m, &k, "x");
    dims(B, &k2, &n, "y");
    if (k != k2) Rf_errorcall(R_NilValue, "%%m%%: nicht passende Argumente");
    C = PROTECT(new_mat(m, n));
    sl_matmul(m, k, n, REAL(A), REAL(B), REAL(C));
    set_dn(C, A, 0, B, 1);
    UNPROTECT(1);
    return C;
}

SEXP C_sl_crossprod(SEXP X, SEXP Y)
{
    int m, k, m2, n;
    SEXP C;
    dims(X, &m, &k, "x");
    dims(Y, &m2, &n, "y");
    if (m != m2) Rf_errorcall(R_NilValue, "crossprod: nicht passende Argumente");
    C = PROTECT(new_mat(k, n));
    sl_crossprod(m, k, n, REAL(X), REAL(Y), REAL(C));
    set_dn(C, X, 1, Y, 1);
    UNPROTECT(1);
    return C;
}

SEXP C_sl_tcrossprod(SEXP X, SEXP Y)
{
    int m, k, n, k2;
    SEXP C;
    dims(X, &m, &k, "x");
    dims(Y, &n, &k2, "y");
    if (k != k2) Rf_errorcall(R_NilValue, "tcrossprod: nicht passende Argumente");
    C = PROTECT(new_mat(m, n));
    sl_tcrossprod(m, k, n, REAL(X), REAL(Y), REAL(C));
    set_dn(C, X, 0, Y, 0);
    UNPROTECT(1);
    return C;
}

/* ── kleinste Quadrate, Logit-IRLS ── */

SEXP C_sl_lsfit(SEXP X, SEXP y, SEXP w, SEXP tol, SEXP pivot)
{
    static const char *nm[] = {"coefficients", "fitted.values", "rank", "pivot"};
    sl_ctx cx;
    int m, n, st, rank = 0;
    SEXP out, coef, fit, perm;
    dims(X, &m, &n, "x");
    if (len_int(y, "y") != m) Rf_errorcall(R_NilValue, "lm: Längen von x und y passen nicht");
    if (w != R_NilValue && len_int(w, "w") != m) Rf_errorcall(R_NilValue, "lm: Längen von x und w passen nicht");
    ctx_init(&cx);
    out = PROTECT(named_list(4, nm));
    coef = Rf_allocVector(REALSXP, n); SET_VECTOR_ELT(out, 0, coef);
    fit = Rf_allocVector(REALSXP, m); SET_VECTOR_ELT(out, 1, fit);
    perm = Rf_allocVector(INTSXP, n); SET_VECTOR_ELT(out, 3, perm);
    st = sl_lsfit(&cx, m, n, REAL(X), REAL(y), w == R_NilValue ? NULL : REAL(w), num1(tol, "tol"),
                  int1(pivot, "pivot"), REAL(coef), REAL(fit), &rank, INTEGER(perm));
    finish(&cx, st, 1);
    SET_VECTOR_ELT(out, 2, Rf_ScalarInteger(rank));
    UNPROTECT(1);
    return out;
}

SEXP C_sl_logit_irls(SEXP X, SEXP y, SEXP maxit, SEXP tol)
{
    static const char *nm[] = {"coefficients", "converged"};
    sl_ctx cx;
    int m, n, st, conv = 0;
    SEXP out, coef;
    dims(X, &m, &n, "x");
    if (len_int(y, "y") != m) Rf_errorcall(R_NilValue, "glm: Längen von x und y passen nicht");
    ctx_init(&cx);
    out = PROTECT(named_list(2, nm));
    coef = Rf_allocVector(REALSXP, n); SET_VECTOR_ELT(out, 0, coef);
    st = sl_logit_irls(&cx, m, n, REAL(X), REAL(y), int1(maxit, "maxit"), num1(tol, "tol"), REAL(coef), &conv);
    finish(&cx, st, 1);
    SET_VECTOR_ELT(out, 1, Rf_ScalarLogical(conv));
    UNPROTECT(1);
    return out;
}

/* ── Stineman ── */

SEXP C_sl_stineman(SEXP x, SEXP y, SEXP xout)
{
    sl_ctx cx;
    int n = len_int(x, "x"), no = len_int(xout, "xout"), st;
    SEXP out;
    if (len_int(y, "y") != n) Rf_errorcall(R_NilValue, "stinterp: x und y ungleich lang");
    ctx_init(&cx);
    out = PROTECT(Rf_allocVector(REALSXP, no));
    st = sl_stineman(&cx, n, REAL(x), REAL(y), no, REAL(xout), REAL(out));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}

SEXP C_sl_stineman_slopes(SEXP x, SEXP y, SEXP scale)
{
    sl_ctx cx;
    int n = len_int(x, "x"), st;
    SEXP out;
    if (len_int(y, "y") != n) Rf_errorcall(R_NilValue, "stinterp: x und y ungleich lang");
    ctx_init(&cx);
    out = PROTECT(Rf_allocVector(REALSXP, n));
    st = sl_stineman_slopes(&cx, n, REAL(x), REAL(y), lgl1(scale, "scale"), REAL(out));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}

SEXP C_sl_stineman_eval(SEXP x, SEXP y, SEXP yp, SEXP xout)
{
    sl_ctx cx;
    int n = len_int(x, "x"), no = len_int(xout, "xout"), st;
    SEXP out;
    if (len_int(y, "y") != n || len_int(yp, "yp") != n) Rf_errorcall(R_NilValue, "stinterp: x, y und yp ungleich lang");
    ctx_init(&cx);
    out = PROTECT(Rf_allocVector(REALSXP, no));
    st = sl_stineman_eval(&cx, n, REAL(x), REAL(y), REAL(yp), no, REAL(xout), REAL(out));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}

/* ── Glaettungsspline ── */

SEXP C_sl_smspline_fit(SEXP x, SEXP y, SEXP w, SEXP lambda)
{
    static const char *nm[] = {"x", "y", "gam", "lambda", "df", "gcv"};
    sl_ctx cx;
    int n = len_int(x, "x"), st, nk = 0, i;
    double lam = 0.0, df = 0.0, gcv = 0.0;
    SEXP out, kn, g, gam, tmp;
    if (len_int(y, "y") != n) Rf_errorcall(R_NilValue, "smooth.spline: x und y ungleich lang");
    if (w != R_NilValue && len_int(w, "w") != n) Rf_errorcall(R_NilValue, "smooth.spline: x und w ungleich lang");
    ctx_init(&cx);
    tmp = PROTECT(Rf_allocVector(REALSXP, 3 * (R_xlen_t) (n > 0 ? n : 1)));
    st = sl_smspline_fit(&cx, n, REAL(x), REAL(y), w == R_NilValue ? NULL : REAL(w), num1(lambda, "lambda"),
                         &nk, REAL(tmp), REAL(tmp) + n, REAL(tmp) + 2 * (R_xlen_t) n, &lam, &df, &gcv);
    finish(&cx, st, 1);
    out = PROTECT(named_list(6, nm));
    kn = Rf_allocVector(REALSXP, nk); SET_VECTOR_ELT(out, 0, kn);
    g = Rf_allocVector(REALSXP, nk); SET_VECTOR_ELT(out, 1, g);
    gam = Rf_allocVector(REALSXP, nk); SET_VECTOR_ELT(out, 2, gam);
    for (i = 0; i < nk; i++) {
        REAL(kn)[i] = REAL(tmp)[i];
        REAL(g)[i] = REAL(tmp)[n + i];
        REAL(gam)[i] = REAL(tmp)[2 * (R_xlen_t) n + i];
    }
    SET_VECTOR_ELT(out, 3, Rf_ScalarReal(lam));
    SET_VECTOR_ELT(out, 4, Rf_ScalarReal(df));
    SET_VECTOR_ELT(out, 5, Rf_ScalarReal(gcv));
    UNPROTECT(2);
    return out;
}

SEXP C_sl_smspline_predict(SEXP kn, SEXP g, SEXP gam, SEXP xout)
{
    sl_ctx cx;
    int nk = len_int(kn, "knots"), no = len_int(xout, "x"), st;
    SEXP out;
    if (len_int(g, "y") != nk || len_int(gam, "gam") != nk) Rf_errorcall(R_NilValue, "predict.smooth.spline: ungültiges Splineobjekt");
    ctx_init(&cx);
    out = PROTECT(Rf_allocVector(REALSXP, no));
    st = sl_smspline_predict(&cx, nk, REAL(kn), REAL(g), REAL(gam), no, REAL(xout), REAL(out));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}

/* ── Kerndichte ── */

SEXP C_sl_kde(SEXP x, SEXP w, SEXP bw, SEXP ngrid, SEXP from, SEXP to)
{
    static const char *nm[] = {"x", "y"};
    sl_ctx cx;
    int ng = int1(ngrid, "n"), st;
    SEXP out, gx, gy;
    need_real(x, "x");
    if (w != R_NilValue && (TYPEOF(w) != REALSXP || XLENGTH(w) != XLENGTH(x)))
        Rf_errorcall(R_NilValue, "density: x und weights ungleich lang");
    if (ng < 2) Rf_errorcall(R_NilValue, "density: mindestens 2 Gitterpunkte");
    ctx_init(&cx);
    out = PROTECT(named_list(2, nm));
    gx = Rf_allocVector(REALSXP, ng); SET_VECTOR_ELT(out, 0, gx);
    gy = Rf_allocVector(REALSXP, ng); SET_VECTOR_ELT(out, 1, gy);
    st = sl_kde(&cx, (int64_t) XLENGTH(x), REAL(x), w == R_NilValue ? NULL : REAL(w), num1(bw, "bw"), ng,
                num1(from, "from"), num1(to, "to"), REAL(gx), REAL(gy));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}

SEXP C_sl_kde_bw(SEXP x)
{
    sl_ctx cx;
    int st;
    double bw = 0.0;
    need_real(x, "x");
    ctx_init(&cx);
    st = sl_kde_bw(&cx, (int64_t) XLENGTH(x), REAL(x), &bw);
    finish(&cx, st, 0);
    return Rf_ScalarReal(bw);
}
