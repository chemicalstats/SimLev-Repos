/*
 * src/slc_r_opt.c -- R-Huellen (.Call) der Optimierer der C-Bibliothek slc (Etappe 9.3)
 *
 * Kerne: slc_opt.c, slc_opt_test.c (Kopien aus core/, tools/core_sync.py); Registrierung in
 * init.c (Block "9.3"), die R-Seite steht in R/slc_opt.R (.sl_optim und Pruefhilfen).
 *
 * Rueckfrage an den Host (Entwurf B.8): Das Arbeitsfeld ist ein R-Vektor (double), den
 * C_sl_opt_init neu anlegt und den nur .sl_optim haelt; C_sl_opt_next aendert ihn an Ort und
 * Stelle (er wird nie kopiert oder geteilt). Zwischen zwei Aufrufen rechnet R die Zielfunktion;
 * Fehler dort laufen als gewoehnliche R-Fehler durch.
 *
 * Rueckmeldungen wie slc_r.c: Warnungen nach dem Aufruf, Fehler mit Rf_errorcall(R_NilValue,
 * ...) (wie stop(call. = FALSE)), Benutzerabbruch ueber R_ToplevelExec.
 */
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Utils.h>

#include <string.h>

#include "slc.h"
#include "slc_opt.h"

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

static int int1(SEXP x, const char *what)
{
    if (TYPEOF(x) != INTSXP || XLENGTH(x) != 1 || INTEGER(x)[0] == NA_INTEGER)
        Rf_errorcall(R_NilValue, "interner Fehler: %s muss eine ganze Zahl (integer, Laenge 1) sein", what);
    return INTEGER(x)[0];
}

static void need_real_n(SEXP x, R_xlen_t n, const char *what)
{
    if (TYPEOF(x) != REALSXP || (n >= 0 && XLENGTH(x) != n))
        Rf_errorcall(R_NilValue, "interner Fehler: %s muss double der Laenge %ld sein", what, (long) n);
}

/* ctrl = c(maxit, maxfev, reltol, gtol, xtol, fnscale); parscale NULL oder double(n) */
static void get_ctrl(SEXP ctrl, SEXP parscale, int n, sl_opt_ctrl *c, int method)
{
    const double *v;
    sl_opt_ctrl_default(c, method);
    need_real_n(ctrl, 6, "ctrl");
    v = REAL(ctrl);
    c->maxit = (int) v[0];
    c->maxfev = (int) v[1];
    c->reltol = v[2];
    c->gtol = v[3];
    c->xtol = v[4];
    c->fnscale = v[5];
    if (parscale != R_NilValue) {
        need_real_n(parscale, n, "parscale");
        c->parscale = REAL(parscale);
    }
}

static const double *opt_bound(SEXP b, int n, const char *what)
{
    if (b == R_NilValue) return NULL;
    need_real_n(b, n, what);
    return REAL(b);
}

static void check_ws(SEXP ws)
{
    if (TYPEOF(ws) != REALSXP || XLENGTH(ws) < 64 || sl_opt_dim(REAL(ws)) < 1 ||
        XLENGTH(ws) < sl_opt_wsize(SL_OPT_BFGS, sl_opt_dim(REAL(ws))))
        Rf_errorcall(R_NilValue, "interner Fehler: Arbeitsfeld des Optimierers ungueltig");
}

/* Arbeitsfeld anlegen und initialisieren */
SEXP C_sl_opt_init(SEXP method, SEXP x0, SEXP lo, SEXP hi, SEXP ctrl, SEXP parscale, SEXP have_grad)
{
    int m = int1(method, "method"), n, st;
    int64_t len;
    sl_opt_ctrl c;
    sl_ctx cx;
    SEXP ws;
    need_real_n(x0, -1, "par");
    n = (int) XLENGTH(x0);
    len = sl_opt_wsize(m, n);
    if (len < 0) Rf_errorcall(R_NilValue, "%s: Verfahren oder Zahl der Parameter ungueltig (n = %d)", sl_opt_method_name(m), n);
    get_ctrl(ctrl, parscale, n, &c, m);
    ws = PROTECT(Rf_allocVector(REALSXP, (R_xlen_t) len));
    ctx_init(&cx);
    st = sl_opt_init(&cx, m, n, REAL(x0), opt_bound(lo, n, "lower"), opt_bound(hi, n, "upper"), &c,
                     int1(have_grad, "have_grad"), REAL(ws));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return ws;
}

/* Antwort (val: NULL beim ersten Aufruf, sonst f bzw. Gradient) geben und naechste Anfrage holen:
 * list(need, x) bzw. NULL, wenn der Optimierer fertig ist */
SEXP C_sl_opt_next(SEXP ws, SEXP val)
{
    sl_ctx cx;
    int need, st, n;
    SEXP x, out;
    check_ws(ws);
    ctx_init(&cx);
    n = sl_opt_dim(REAL(ws));
    if (val != R_NilValue) {
        sl_opt_ask(&cx, REAL(ws), NULL, &need);
        if (need == SL_NEED_F) { need_real_n(val, 1, "Funktionswert"); st = sl_opt_tell(&cx, REAL(ws), REAL(val)[0], NULL); }
        else { need_real_n(val, n, "Gradient"); st = sl_opt_tell(&cx, REAL(ws), 0.0, REAL(val)); }
        finish(&cx, st, 0);
    }
    x = PROTECT(Rf_allocVector(REALSXP, n));
    st = sl_opt_ask(&cx, REAL(ws), REAL(x), &need);
    finish(&cx, st, 1);
    if (need == SL_DONE) { UNPROTECT(1); return R_NilValue; }
    out = PROTECT(Rf_allocVector(VECSXP, 2));
    SET_VECTOR_ELT(out, 0, Rf_ScalarInteger(need));
    SET_VECTOR_ELT(out, 1, x);
    UNPROTECT(2);
    return out;
}

static SEXP result_list(const double *par, int n, double f, int code, int iter, int nfev, int ngev, int ntot, int reason)
{
    const char *nm[] = {"par", "value", "convergence", "iterations", "nfev", "ngev", "evaluations", "message"};
    SEXP out = PROTECT(Rf_allocVector(VECSXP, 8)), names = PROTECT(Rf_allocVector(STRSXP, 8)), p;
    int i;
    p = Rf_allocVector(REALSXP, n);
    SET_VECTOR_ELT(out, 0, p);
    memcpy(REAL(p), par, (size_t) n * sizeof(double));
    SET_VECTOR_ELT(out, 1, Rf_ScalarReal(f));
    SET_VECTOR_ELT(out, 2, Rf_ScalarInteger(code));
    SET_VECTOR_ELT(out, 3, Rf_ScalarInteger(iter));
    SET_VECTOR_ELT(out, 4, Rf_ScalarInteger(nfev));
    SET_VECTOR_ELT(out, 5, Rf_ScalarInteger(ngev));
    SET_VECTOR_ELT(out, 6, Rf_ScalarInteger(ntot));
    SET_VECTOR_ELT(out, 7, reason < 0 ? Rf_ScalarString(NA_STRING) : Rf_mkString(sl_opt_message(reason)));
    for (i = 0; i < 8; i++) SET_STRING_ELT(names, i, Rf_mkChar(nm[i]));
    Rf_setAttrib(out, R_NamesSymbol, names);
    UNPROTECT(2);
    return out;
}

SEXP C_sl_opt_result(SEXP ws)
{
    int n, code, iter, nfev, ngev, reason, ntot;
    double f;
    SEXP par, out;
    check_ws(ws);
    n = sl_opt_dim(REAL(ws));
    par = PROTECT(Rf_allocVector(REALSXP, n));
    sl_opt_result(REAL(ws), REAL(par), &f, &code, &iter, &nfev, &ngev);
    sl_opt_info(REAL(ws), &reason, &ntot);
    out = result_list(REAL(par), n, f, code, iter, nfev, ngev, ntot, reason);
    UNPROTECT(1);
    return out;
}

/* ── Pruefhilfen: dieselbe C-Zielfunktion fuer R, Python und Julia ── */

SEXP C_sl_opt_testfn(SEXP id, SEXP x, SEXP grad)
{
    int k = int1(id, "id"), n, g;
    SEXP out, gv;
    need_real_n(x, -1, "x");
    n = (int) XLENGTH(x);
    g = int1(grad, "grad");
    if (!g) return Rf_ScalarReal(sl_opt_testfn(k, n, REAL(x), NULL));
    gv = PROTECT(Rf_allocVector(REALSXP, n));
    out = PROTECT(Rf_allocVector(VECSXP, 2));
    SET_VECTOR_ELT(out, 0, Rf_ScalarReal(sl_opt_testfn(k, n, REAL(x), REAL(gv))));
    SET_VECTOR_ELT(out, 1, gv);
    UNPROTECT(2);
    return out;
}

/* direkter C-Weg (sl_minimize) mit einer Pruefffunktion */
SEXP C_sl_opt_minimize_test(SEXP id, SEXP method, SEXP x0, SEXP lo, SEXP hi, SEXP ctrl, SEXP parscale, SEXP use_grad)
{
    int m = int1(method, "method"), n, st, code = 0, iter = 0, nfev = 0, ntot = 0;
    double f = 0.0;
    sl_opt_ctrl c;
    sl_ctx cx;
    SEXP x, out;
    need_real_n(x0, -1, "par");
    n = (int) XLENGTH(x0);
    get_ctrl(ctrl, parscale, n, &c, m);
    x = PROTECT(Rf_duplicate(x0));
    ctx_init(&cx);
    st = sl_opt_test_minimize(&cx, int1(id, "id"), m, n, REAL(x), opt_bound(lo, n, "lower"), opt_bound(hi, n, "upper"),
                              &c, int1(use_grad, "use_grad"), &f, &code, &iter, &nfev, &ntot);
    finish(&cx, st, 1);
    out = result_list(REAL(x), n, f, code, iter, nfev, NA_INTEGER, ntot, -1);
    UNPROTECT(1);
    return out;
}

/* numerischer Gradient (B.9) einer Prueffunktion */
SEXP C_sl_numgrad_test(SEXP id, SEXP x, SEXP lo, SEXP hi)
{
    int n, st, cnt = 0;
    sl_ctx cx;
    SEXP g;
    need_real_n(x, -1, "x");
    n = (int) XLENGTH(x);
    g = PROTECT(Rf_allocVector(REALSXP, n));
    ctx_init(&cx);
    st = sl_opt_test_numgrad(&cx, int1(id, "id"), n, REAL(x), opt_bound(lo, n, "lower"), opt_bound(hi, n, "upper"),
                             REAL(g), &cnt);
    finish(&cx, st, 1);
    UNPROTECT(1);
    return g;
}
