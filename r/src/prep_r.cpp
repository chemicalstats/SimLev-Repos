/*
 * src/prep_r.cpp -- .Call-Huellen der Kerne fuer Wirtsfunktionen (seit 1.6.0; core/slc_prep.h)
 *
 * Kalenderauffuellung von simulation() (C_sl_cal_fill, R/sim_prepare.R), Momentum-Scores (C_sl_mom_score,
 * R/tactical.R), Pfadaufbau im Bootstrap (C_sl_boot_path, R/bootstrap.R), qt/pt auf mehreren Threads
 * (C_sl_qt_mt, C_sl_pt_mt, R/slc.R) und die Profil-Likelihood der t-Copula (C_sl_tcop_fit, C_sl_tcop_nu,
 * R/dependence.R, R/scenarios.R). Die R-Seite prueft die Eingaben und baut die Ergebnisobjekte; die Huellen
 * pruefen nur Typen und Laengen (interne Fehler). Registrierung in init.cpp.
 */
#include <R.h>
#include <Rinternals.h>

#include <stdint.h>
#include <string.h>

#include "slc_prep.h"

extern "C" {

static void chk_int(void *d) { (void) d; R_CheckUserInterrupt(); }
static int r_interrupted(void *h) { (void) h; return !R_ToplevelExec(chk_int, NULL); }

static void ctx_init(sl_ctx *cx)
{
    sl_ctx_init(cx);
    cx->interrupted = r_interrupted;
}

/* Warnungen ausgeben, bei Fehler abbrechen (nprot Schutzstufen vorher freigeben) */
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

static void bad(const char *what) { Rf_errorcall(R_NilValue, "interner Fehler: %s", what); }

static double num1(SEXP x, const char *what)
{
    if (TYPEOF(x) != REALSXP || XLENGTH(x) != 1) bad(what);
    return REAL(x)[0];
}

static int int1(SEXP x, const char *what)
{
    if (TYPEOF(x) != INTSXP || XLENGTH(x) != 1 || INTEGER(x)[0] == NA_INTEGER) bad(what);
    return INTEGER(x)[0];
}

/* ── Kalenderauffuellung: cols (Liste der Spalten ohne date), day (Tage), d0, nd, filled (1-basierte Stelle von
 * .filled in cols oder 0) -> Liste der aufgefuellten Spalten ── */
SEXP C_sl_cal_fill(SEXP cols, SEXP day, SEXP d0, SEXP nd, SEXP filled)
{
    sl_ctx cx;
    R_xlen_t j, k, m, n;
    int64_t *src;
    int fpos, st;
    SEXP out, v, o;
    if (TYPEOF(cols) != VECSXP || TYPEOF(day) != REALSXP) bad("cal_fill: Typen");
    n = XLENGTH(day);
    m = (R_xlen_t) num1(nd, "cal_fill: nd");
    fpos = int1(filled, "cal_fill: filled");
    src = (int64_t *) R_alloc((size_t) (m > 0 ? m : 1), sizeof(int64_t));
    ctx_init(&cx);
    st = sl_cal_index(&cx, n, REAL(day), num1(d0, "cal_fill: d0"), m, src);
    finish(&cx, st, 0);
    out = PROTECT(Rf_allocVector(VECSXP, XLENGTH(cols)));
    for (k = 0; k < XLENGTH(cols); k++) {
        v = VECTOR_ELT(cols, k);
        if (XLENGTH(v) != n) bad("cal_fill: Spaltenlaenge");
        switch (TYPEOF(v)) {
        case REALSXP:
            o = Rf_allocVector(REALSXP, m); SET_VECTOR_ELT(out, k, o);
            sl_cal_fill_real(m, src, REAL(v), 1, REAL(o));
            break;
        case INTSXP:
            o = Rf_allocVector(INTSXP, m); SET_VECTOR_ELT(out, k, o);
            sl_cal_fill_int(m, src, INTEGER(v), 1, 0, INTEGER(o));
            break;
        case LGLSXP:
            o = Rf_allocVector(LGLSXP, m); SET_VECTOR_ELT(out, k, o);
            sl_cal_fill_int(m, src, LOGICAL(v), 2, k + 1 == fpos ? 1 : 0, LOGICAL(o));
            break;
        case STRSXP:
            o = Rf_allocVector(STRSXP, m); SET_VECTOR_ELT(out, k, o);
            for (j = 0; j < m; j++) SET_STRING_ELT(o, j, src[j] >= 0 ? STRING_ELT(v, src[j]) : NA_STRING);
            break;
        default:
            UNPROTECT(1);
            bad("cal_fill: Spaltentyp");
        }
    }
    UNPROTECT(1);
    return out;
}

/* ── Momentum: d (Tage, sortiert), lb (ganze Monate), X (n x na, double), type (0/1) -> S (n x na) ── */
SEXP C_sl_mom_score(SEXP d, SEXP lb, SEXP X, SEXP type)
{
    sl_ctx cx;
    R_xlen_t n, na;
    int64_t *back;
    int st;
    SEXP S;
    if (TYPEOF(d) != REALSXP || TYPEOF(lb) != INTSXP || TYPEOF(X) != REALSXP) bad("mom_score: Typen");
    n = XLENGTH(d);
    na = n > 0 ? XLENGTH(X) / n : 0;
    if (na * n != XLENGTH(X)) bad("mom_score: Laengen");
    back = (int64_t *) R_alloc((size_t) (n > 0 ? n : 1) * (size_t) (XLENGTH(lb) > 0 ? XLENGTH(lb) : 1), sizeof(int64_t));
    ctx_init(&cx);
    st = sl_mom_back(&cx, n, REAL(d), (int) XLENGTH(lb), INTEGER(lb), back);
    finish(&cx, st, 0);
    S = PROTECT(Rf_allocMatrix(REALSXP, (int) n, (int) na));
    st = sl_mom_score(&cx, n, na, REAL(X), (int) XLENGTH(lb), back, int1(type, "mom_score: type"), REAL(S));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return S;
}

/* ── Bootstrap-Pfad: ret (n_out x k), idx (ganze Zahlen, 1-basiert), aux/aux_ratio (n_aux x na oder NULL),
 * aux_start (na oder NULL), level (na, logisch), letf (Matrix nL x 10: base, L, rate_col, rate, days_col, days,
 * rate_basis, ter_basis, expense, spread; Spalten 0-basiert, -1 = Wert), start -> list(P, lv) oder NULL ── */
SEXP C_sl_boot_path(SEXP ret, SEXP idx, SEXP aux, SEXP aux_ratio, SEXP aux_start, SEXP level, SEXP letf, SEXP start)
{
    sl_ctx cx;
    SEXP dim, P, lv = R_NilValue, out;
    int64_t n_out, n_aux = 0, i, *ix;
    int k, na = 0, nL, l, st, *lev = NULL;
    sl_letf *L = NULL;
    if (TYPEOF(ret) != REALSXP || TYPEOF(idx) != INTSXP || TYPEOF(letf) != REALSXP) bad("boot_path: Typen");
    dim = Rf_getAttrib(ret, R_DimSymbol);
    if (TYPEOF(dim) != INTSXP || XLENGTH(dim) != 2) bad("boot_path: ret ist keine Matrix");
    n_out = INTEGER(dim)[0]; k = INTEGER(dim)[1];
    if (XLENGTH(idx) != n_out) bad("boot_path: idx");
    if (aux != R_NilValue) {
        dim = Rf_getAttrib(aux, R_DimSymbol);
        if (TYPEOF(aux) != REALSXP || TYPEOF(dim) != INTSXP || XLENGTH(dim) != 2) bad("boot_path: aux");
        n_aux = INTEGER(dim)[0]; na = INTEGER(dim)[1];
        if (aux_ratio != R_NilValue && (TYPEOF(aux_ratio) != REALSXP || XLENGTH(aux_ratio) != n_aux * na)) bad("boot_path: aux_ratio");
        if (aux_start != R_NilValue && (TYPEOF(aux_start) != REALSXP || XLENGTH(aux_start) != na)) bad("boot_path: aux_start");
        if (TYPEOF(level) != LGLSXP || XLENGTH(level) != na) bad("boot_path: level");
        lev = LOGICAL(level);
    }
    nL = XLENGTH(letf) / 10;
    if (nL * 10 != XLENGTH(letf)) bad("boot_path: letf");
    ix = (int64_t *) R_alloc((size_t) (n_out > 0 ? n_out : 1), sizeof(int64_t));
    for (i = 0; i < n_out; i++) ix[i] = INTEGER(idx)[i];
    if (nL > 0) {
        const double *q = REAL(letf);
        L = (sl_letf *) R_alloc((size_t) nL, sizeof(sl_letf));
        for (l = 0; l < nL; l++) {                 /* Matrix nL x 10, spaltenweise */
            L[l].base = (int) q[l]; L[l].L = q[nL + l];
            L[l].rate_col = (int) q[2 * nL + l]; L[l].rate = q[3 * nL + l];
            L[l].days_col = (int) q[4 * nL + l]; L[l].days = q[5 * nL + l];
            L[l].rate_basis = q[6 * nL + l]; L[l].ter_basis = q[7 * nL + l];
            L[l].expense = q[8 * nL + l]; L[l].spread = q[9 * nL + l];
        }
    }
    P = PROTECT(Rf_allocMatrix(REALSXP, (int) (n_out + 1), k + nL + na));
    if (aux_ratio != R_NilValue && na > 0) lv = Rf_allocMatrix(REALSXP, (int) (n_out + 1), na);
    PROTECT(lv);
    ctx_init(&cx);
    st = sl_boot_path(&cx, n_out, k, REAL(ret), ix, n_aux, na, na > 0 ? REAL(aux) : NULL,
                      lv != R_NilValue ? REAL(aux_ratio) : NULL, aux_start != R_NilValue ? REAL(aux_start) : NULL,
                      lev, nL, L, num1(start, "boot_path: start"), REAL(P), lv != R_NilValue ? REAL(lv) : NULL);
    if (st < 0) finish(&cx, -st, 2);
    if (st == 0) { UNPROTECT(2); return R_NilValue; }
    out = PROTECT(Rf_allocVector(VECSXP, 2));
    SET_VECTOR_ELT(out, 0, P);
    SET_VECTOR_ELT(out, 1, lv);
    UNPROTECT(3);
    return out;
}

/* ── qt/pt auf mehreren Threads ── */
typedef int (*tmt_fn)(sl_ctx *, int64_t, const double *, double, int, double *, int);

static SEXP tdist_mt(tmt_fn f, SEXP x, SEXP df, SEXP lower, SEXP nthreads)
{
    sl_ctx cx;
    SEXP out;
    int st;
    if (TYPEOF(x) != REALSXP) bad("x muss double sein");
    if (TYPEOF(lower) != LGLSXP || XLENGTH(lower) != 1 || LOGICAL(lower)[0] == NA_LOGICAL)
        Rf_errorcall(R_NilValue, "interner Fehler: lower.tail muss TRUE oder FALSE sein");
    ctx_init(&cx);
    out = PROTECT(Rf_allocVector(REALSXP, XLENGTH(x)));
    st = f(&cx, XLENGTH(x), REAL(x), num1(df, "df"), LOGICAL(lower)[0], REAL(out), int1(nthreads, "nthreads"));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}

SEXP C_sl_pt_mt(SEXP x, SEXP df, SEXP lower, SEXP nt) { return tdist_mt(sl_pt_mt, x, df, lower, nt); }
SEXP C_sl_qt_mt(SEXP p, SEXP df, SEXP lower, SEXP nt) { return tdist_mt(sl_qt_mt, p, df, lower, nt); }

/* ── t-Copula: Ergebnis oder NULL (Merker: der Host rechnet wie bisher) ── */
SEXP C_sl_tcop_fit(SEXP u, SEXP v, SEXP nthreads)
{
    sl_ctx cx;
    SEXP out;
    int st, flag;
    if (TYPEOF(u) != REALSXP || TYPEOF(v) != REALSXP || XLENGTH(u) != XLENGTH(v)) bad("tcop_fit: u, v");
    out = PROTECT(Rf_allocVector(REALSXP, 3));
    ctx_init(&cx);
    st = sl_tcop_fit(&cx, XLENGTH(u), REAL(u), REAL(v), int1(nthreads, "nthreads"), REAL(out), &flag);
    UNPROTECT(1);
    if (st == SL_EINTR) R_CheckUserInterrupt();
    return (st != SL_OK || flag) ? R_NilValue : out;
}

SEXP C_sl_tcop_nu(SEXP U, SEXP Ri, SEXP ldR, SEXP lower, SEXP upper, SEXP tol, SEXP nthreads)
{
    sl_ctx cx;
    SEXP dim;
    double nu;
    int st, flag, k;
    dim = Rf_getAttrib(U, R_DimSymbol);
    if (TYPEOF(U) != REALSXP || TYPEOF(dim) != INTSXP || XLENGTH(dim) != 2 || TYPEOF(Ri) != REALSXP) bad("tcop_nu: Typen");
    k = INTEGER(dim)[1];
    if (XLENGTH(Ri) != (R_xlen_t) k * k) bad("tcop_nu: Ri");
    ctx_init(&cx);
    st = sl_tcop_nu(&cx, INTEGER(dim)[0], k, REAL(U), REAL(Ri), num1(ldR, "ldR"), num1(lower, "lower"),
                    num1(upper, "upper"), num1(tol, "tol"), int1(nthreads, "nthreads"), &nu, &flag);
    if (st == SL_EINTR) R_CheckUserInterrupt();
    return (st != SL_OK || flag) ? R_NilValue : Rf_ScalarReal(nu);
}

}  /* extern "C" */
