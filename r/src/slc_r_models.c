/*
 * src/slc_r_models.c -- R-Huellen (.Call) der Modelle der C-Bibliothek slc (Etappe 9.4)
 *
 * Kerne: slc_garch.c, slc_gpd.c, slc_dcc.c, slc_msgarch.c, slc_boot.c (Kopien aus core/,
 * tools/core_sync.py); Registrierung in init.c (Block "9.4"), die R-Seite steht in
 * R/slc_models.R (interne Funktionen .sl_*).
 *
 * Rueckmeldungen wie slc_r.c: Warnungen nach dem Aufruf, Fehler mit Rf_errorcall(R_NilValue, ...)
 * (wie stop(call. = FALSE)), Benutzerabbruch ueber R_ToplevelExec. Ziehende Huellen bekommen den
 * Zufallszustand als raw(32) und geben list(Ergebnis, neuer Zustand) zurueck. Die R-Seite wandelt
 * die Argumente (as.double, as.integer); hier werden nur Typ und Laenge geprueft.
 */
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Utils.h>

#include <math.h>
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

/* ── Argumente ── */

static const double *dvec(SEXP x, R_xlen_t n, const char *what)
{
    if (TYPEOF(x) != REALSXP || (n >= 0 && XLENGTH(x) != n))
        Rf_errorcall(R_NilValue, "interner Fehler: %s muss double%s sein", what, n >= 0 ? " passender Laenge" : "");
    return REAL(x);
}

static const int32_t *ivec(SEXP x, R_xlen_t n, const char *what)
{
    if (TYPEOF(x) != INTSXP || (n >= 0 && XLENGTH(x) != n))
        Rf_errorcall(R_NilValue, "interner Fehler: %s muss integer%s sein", what, n >= 0 ? " passender Laenge" : "");
    return (const int32_t *) INTEGER(x);
}

static double d1(SEXP x, const char *what) { return dvec(x, 1, what)[0]; }

static int i1(SEXP x, const char *what)
{
    if (TYPEOF(x) != INTSXP || XLENGTH(x) != 1 || INTEGER(x)[0] == NA_INTEGER)
        Rf_errorcall(R_NilValue, "interner Fehler: %s muss eine ganze Zahl (integer, Laenge 1) sein", what);
    return INTEGER(x)[0];
}

static int l1(SEXP x, const char *what)
{
    if (TYPEOF(x) != LGLSXP || XLENGTH(x) != 1 || LOGICAL(x)[0] == NA_LOGICAL)
        Rf_errorcall(R_NilValue, "interner Fehler: %s muss TRUE oder FALSE sein", what);
    return LOGICAL(x)[0];
}

static int len_int(SEXP x)
{
    if (XLENGTH(x) > 2147483647) Rf_errorcall(R_NilValue, "interner Fehler: Vektor zu lang");
    return (int) XLENGTH(x);
}

/* Matrix (double): Zeilen und Spalten */
static const double *dmat(SEXP x, int *nr, int *nc, const char *what)
{
    SEXP d;
    if (TYPEOF(x) != REALSXP) Rf_errorcall(R_NilValue, "interner Fehler: %s muss eine double-Matrix sein", what);
    d = Rf_getAttrib(x, R_DimSymbol);
    if (d == R_NilValue || XLENGTH(d) != 2) Rf_errorcall(R_NilValue, "interner Fehler: %s muss eine Matrix sein", what);
    *nr = INTEGER(d)[0]; *nc = INTEGER(d)[1];
    return REAL(x);
}

static void get_state(SEXP s, sl_rng *r)
{
    if (TYPEOF(s) != RAWSXP || XLENGTH(s) != 32)
        Rf_errorcall(R_NilValue, "interner Fehler: Zufallszustand muss raw(32) sein");
    memcpy(r->s, RAW(s), 32);
}

static SEXP pair(SEXP a, const sl_rng *r)
{
    SEXP out = PROTECT(Rf_allocVector(VECSXP, 2)), s = PROTECT(Rf_allocVector(RAWSXP, 32));
    memcpy(RAW(s), r->s, 32);
    SET_VECTOR_ELT(out, 0, a);
    SET_VECTOR_ELT(out, 1, s);
    UNPROTECT(2);
    return out;
}

/* benannte Liste aus nn Elementen (Elemente geschuetzt uebergeben) */
static SEXP named(int nn, const char **nm, SEXP *el)
{
    SEXP out = PROTECT(Rf_allocVector(VECSXP, nn)), names = PROTECT(Rf_allocVector(STRSXP, nn));
    int i;
    for (i = 0; i < nn; i++) { SET_VECTOR_ELT(out, i, el[i]); SET_STRING_ELT(names, i, Rf_mkCharCE(nm[i], CE_UTF8)); }
    Rf_setAttrib(out, R_NamesSymbol, names);
    UNPROTECT(2);
    return out;
}

static SEXP rvec(int n, const double *v)
{
    SEXP x = PROTECT(Rf_allocVector(REALSXP, n));
    if (n) memcpy(REAL(x), v, (size_t) n * sizeof(double));
    UNPROTECT(1);
    return x;
}

/* ── GARCH ── */

SEXP C_sl_garch11_filter(SEXP eps, SEXP om, SEXP al, SEXP be, SEXP ga, SEXP s2i)
{
    sl_ctx cx;
    int n = len_int(eps), st;
    SEXP out = PROTECT(Rf_allocVector(REALSXP, n));
    ctx_init(&cx);
    st = sl_garch11_filter(&cx, n, dvec(eps, -1, "eps"), d1(om, "omega"), d1(al, "alpha"), d1(be, "beta"),
                           d1(ga, "gamma"), d1(s2i, "s2_init"), REAL(out));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}

SEXP C_sl_garch11_nll(SEXP e, SEXP par, SEXP gjr, SEXP s2i)
{
    sl_ctx cx;
    double v = 0.0;
    int st;
    ctx_init(&cx);
    st = sl_garch11_nll(&cx, len_int(e), dvec(e, -1, "e"), l1(gjr, "gjr"), dvec(par, 5, "par"), d1(s2i, "s2_init"), &v);
    finish(&cx, st, 0);
    return Rf_ScalarReal(v);
}

SEXP C_sl_garch11_fit(SEXP e, SEXP gjr)
{
    static const char *nm[] = {"mu", "omega", "alpha", "beta", "gamma", "loglik", "convergence"};
    sl_ctx cx;
    double par[5], ll = 0.0;
    int st, code = 0, i;
    SEXP el[7];
    ctx_init(&cx);
    st = sl_garch11_fit(&cx, len_int(e), dvec(e, -1, "e"), l1(gjr, "gjr"), NULL, par, &ll, &code);
    finish(&cx, st, 0);
    for (i = 0; i < 5; i++) el[i] = PROTECT(Rf_ScalarReal(par[i]));
    el[5] = PROTECT(Rf_ScalarReal(ll));
    el[6] = PROTECT(Rf_ScalarInteger(code));
    {
        SEXP out = named(7, nm, el);
        UNPROTECT(7);
        return out;
    }
}

SEXP C_sl_garch11_estimate(SEXP e, SEXP gjr)
{
    static const char *nm[] = {"mu", "omega", "alpha", "beta", "gamma", "s2", "z", "method", "persistence",
                               "s2_init", "loglik", "convergence"};
    sl_ctx cx;
    double par[5], ll = 0.0, s2i = 0.0, pers = 0.0;
    int n = len_int(e), st, code = 0, meth = 0, i;
    SEXP el[12], s2 = PROTECT(Rf_allocVector(REALSXP, n)), z = PROTECT(Rf_allocVector(REALSXP, n));
    ctx_init(&cx);
    st = sl_garch11_estimate(&cx, n, dvec(e, -1, "e"), l1(gjr, "gjr"), par, &ll, &code, &meth, REAL(s2), REAL(z),
                             &s2i, &pers);
    finish(&cx, st, 2);
    for (i = 0; i < 5; i++) el[i] = PROTECT(Rf_ScalarReal(par[i]));
    el[5] = s2; el[6] = z;
    el[7] = PROTECT(Rf_ScalarInteger(meth));
    el[8] = PROTECT(Rf_ScalarReal(pers));
    el[9] = PROTECT(Rf_ScalarReal(s2i));
    el[10] = PROTECT(Rf_ScalarReal(ll));
    el[11] = PROTECT(Rf_ScalarInteger(code));
    {
        SEXP out = named(12, nm, el);
        UNPROTECT(12);
        return out;
    }
}

/* ── GPD ── */

SEXP C_sl_gpd_nll(SEXP x, SEXP scale, SEXP shape)
{
    sl_ctx cx;
    double v = 0.0;
    int st;
    ctx_init(&cx);
    st = sl_gpd_nll(&cx, len_int(x), dvec(x, -1, "x"), d1(scale, "scale"), d1(shape, "shape"), &v);
    finish(&cx, st, 0);
    return Rf_ScalarReal(v);
}

SEXP C_sl_gpd_pwm(SEXP x)
{
    sl_ctx cx;
    double v[2] = {0.0, 0.0};
    int st;
    ctx_init(&cx);
    st = sl_gpd_pwm(&cx, len_int(x), dvec(x, -1, "x"), &v[0], &v[1]);
    finish(&cx, st, 0);
    return rvec(2, v);
}

SEXP C_sl_gpd_fit(SEXP x)
{
    static const char *nm[] = {"scale", "shape", "loglik", "convergence"};
    sl_ctx cx;
    double sc = 0.0, sh = 0.0, ll = 0.0;
    int st, code = 0;
    SEXP el[4], out;
    ctx_init(&cx);
    st = sl_gpd_fit(&cx, len_int(x), dvec(x, -1, "x"), NULL, &sc, &sh, &ll, &code);
    finish(&cx, st, 0);
    el[0] = PROTECT(Rf_ScalarReal(sc)); el[1] = PROTECT(Rf_ScalarReal(sh));
    el[2] = PROTECT(Rf_ScalarReal(ll)); el[3] = PROTECT(Rf_ScalarInteger(code));
    out = named(4, nm, el);
    UNPROTECT(4);
    return out;
}

/* ── DCC ── */

SEXP C_sl_dcc_filter(SEXP Z, SEXP a, SEXP b, SEXP Qbar, SEXP keep)
{
    static const char *nm[] = {"nll", "R", "ok"};
    sl_ctx cx;
    int n, k, qr, qc, kp = l1(keep, "keep"), ok = 0, st, np;
    const double *z = dmat(Z, &n, &k, "Z"), *q = dmat(Qbar, &qr, &qc, "Qbar");
    double nll = 0.0;
    SEXP el[3], R, out;
    if (qr != k || qc != k) Rf_errorcall(R_NilValue, "interner Fehler: Qbar muss k x k sein");
    np = k * (k - 1) / 2;
    R = PROTECT(Rf_allocMatrix(REALSXP, kp ? n : 0, kp ? np : 0));
    ctx_init(&cx);
    st = sl_dcc_filter(&cx, n, k, z, d1(a, "a"), d1(b, "b"), q, kp, &nll, kp ? REAL(R) : NULL, &ok);
    finish(&cx, st, 1);
    el[0] = PROTECT(Rf_ScalarReal(nll)); el[1] = R; el[2] = PROTECT(Rf_ScalarLogical(ok));
    out = named(3, nm, el);
    UNPROTECT(3);
    return out;
}

SEXP C_sl_dcc_fit(SEXP Z, SEXP Qbar)
{
    static const char *nm[] = {"a", "b", "nll", "convergence", "par"};
    sl_ctx cx;
    int n, k, qr, qc, st, code = 0;
    const double *z = dmat(Z, &n, &k, "Z"), *q = dmat(Qbar, &qr, &qc, "Qbar");
    double a = 0.0, b = 0.0, nll = 0.0, th[2] = {0.0, 0.0};
    SEXP el[5], out;
    if (qr != k || qc != k) Rf_errorcall(R_NilValue, "interner Fehler: Qbar muss k x k sein");
    ctx_init(&cx);
    st = sl_dcc_fit(&cx, n, k, z, q, NULL, &a, &b, &nll, &code, th);
    finish(&cx, st, 0);
    el[0] = PROTECT(Rf_ScalarReal(a)); el[1] = PROTECT(Rf_ScalarReal(b)); el[2] = PROTECT(Rf_ScalarReal(nll));
    el[3] = PROTECT(Rf_ScalarInteger(code)); el[4] = PROTECT(rvec(2, th));
    out = named(5, nm, el);
    UNPROTECT(5);
    return out;
}

/* ── MS-GARCH, HMM ── */

SEXP C_sl_ms_garch_filter(SEXP y, SEXP om, SEXP al, SEXP be, SEXP ga, SEXP P, SEXP xi0, SEXP h1)
{
    static const char *nm[] = {"loglik", "h", "pred", "filt", "lB"};
    sl_ctx cx;
    int n = len_int(y), K = len_int(om), st;
    double ll = 0.0;
    SEXP el[5], out, h, pr, fl, lB;
    const double *yy = dvec(y, -1, "y");
    if (K < 1 || K > 1000) Rf_errorcall(R_NilValue, "ms_garch_filter: 'omega' muss 1 bis 1000 Werte haben (einen je Regime).");
    h = PROTECT(Rf_allocMatrix(REALSXP, n, K)); pr = PROTECT(Rf_allocMatrix(REALSXP, n, K));
    fl = PROTECT(Rf_allocMatrix(REALSXP, n, K)); lB = PROTECT(Rf_allocMatrix(REALSXP, n, K));
    ctx_init(&cx);
    st = sl_msgarch_filter(&cx, n, yy, K, REAL(om), dvec(al, K, "alpha"), dvec(be, K, "beta"), dvec(ga, K, "gamma"),
                           dvec(P, (R_xlen_t) K * K, "P"), dvec(xi0, K, "xi0"), d1(h1, "h1"),
                           REAL(h), REAL(pr), REAL(fl), REAL(lB), &ll);
    finish(&cx, st, 4);
    el[0] = PROTECT(Rf_ScalarReal(ll)); el[1] = h; el[2] = pr; el[3] = fl; el[4] = lB;
    out = named(5, nm, el);
    UNPROTECT(5);
    return out;
}

SEXP C_sl_ms_garch_nll(SEXP y, SEXP theta, SEXP K, SEXP gjr, SEXP h1)
{
    sl_ctx cx;
    int k = i1(K, "K"), g = l1(gjr, "gjr"), st;
    double v = 0.0;
    if (k < 1 || k > 1000) Rf_errorcall(R_NilValue, "interner Fehler: K");
    ctx_init(&cx);
    st = sl_msgarch_nll(&cx, len_int(y), dvec(y, -1, "y"), k, g, dvec(theta, sl_msgarch_npar(k, g), "theta"),
                        d1(h1, "h1"), &v);
    finish(&cx, st, 0);
    return Rf_ScalarReal(v);
}

/* N1: NLL und analytischer Gradient an theta -> list(value, gradient) */
SEXP C_sl_ms_garch_grad(SEXP y, SEXP theta, SEXP K, SEXP gjr, SEXP h1)
{
    static const char *nm[] = {"value", "gradient"};
    sl_ctx cx;
    int k = i1(K, "K"), g = l1(gjr, "gjr"), st, np;
    double v = 0.0;
    SEXP gr, el[2], out;
    if (k < 1 || k > 64) Rf_errorcall(R_NilValue, "interner Fehler: K");
    np = sl_msgarch_npar(k, g);
    gr = PROTECT(Rf_allocVector(REALSXP, np));
    ctx_init(&cx);
    st = sl_msgarch_grad(&cx, len_int(y), dvec(y, -1, "y"), k, g, dvec(theta, np, "theta"), d1(h1, "h1"), &v, REAL(gr));
    finish(&cx, st, 1);
    el[0] = PROTECT(Rf_ScalarReal(v)); el[1] = gr;
    out = named(2, nm, el);
    UNPROTECT(2);
    return out;
}

SEXP C_sl_ms_garch_starts(SEXP y, SEXP K, SEXP gjr, SEXP h1, SEXP all)
{
    sl_ctx cx;
    int k = i1(K, "K"), g = l1(gjr, "gjr"), st, ns = 0, np;
    SEXP buf, out;
    if (k < 2 || k > 64) Rf_errorcall(R_NilValue, "MS-GARCH: Anzahl Regime muss zwischen 2 und 64 liegen (erhalten: %d)", k);
    np = sl_msgarch_npar(k, g);
    buf = PROTECT(Rf_allocVector(REALSXP, SL_MSGARCH_MAXSTART * (R_xlen_t) np));
    ctx_init(&cx);
    st = sl_msgarch_starts(&cx, len_int(y), dvec(y, -1, "y"), k, g, d1(h1, "h1"), l1(all, "all"), &ns, REAL(buf));
    finish(&cx, st, 1);
    out = PROTECT(Rf_allocMatrix(REALSXP, np, ns));
    if (ns) memcpy(REAL(out), REAL(buf), (size_t) np * ns * sizeof(double));
    UNPROTECT(2);
    return out;
}

SEXP C_sl_ms_garch_fitstarts(SEXP y, SEXP K, SEXP gjr, SEXP starts, SEXP h1)
{
    static const char *nm[] = {"par", "value", "convergence"};
    sl_ctx cx;
    int k = i1(K, "K"), g = l1(gjr, "gjr"), st, nr, nc, code = 0, np;
    const double *s = dmat(starts, &nr, &nc, "starts");
    double v = 0.0;
    SEXP th, el[3], out;
    if (k < 1 || k > 1000) Rf_errorcall(R_NilValue, "interner Fehler: K");
    np = sl_msgarch_npar(k, g);
    if (nr != np) Rf_errorcall(R_NilValue, "interner Fehler: starts muss %d Zeilen haben", np);
    th = PROTECT(Rf_allocVector(REALSXP, np));
    ctx_init(&cx);
    st = sl_msgarch_fit(&cx, len_int(y), dvec(y, -1, "y"), k, g, nc, s, d1(h1, "h1"), NULL, REAL(th), &v, &code);
    finish(&cx, st, 1);
    el[0] = th; el[1] = PROTECT(Rf_ScalarReal(v)); el[2] = PROTECT(Rf_ScalarInteger(code));
    out = named(3, nm, el);
    UNPROTECT(3);
    return out;
}

SEXP C_sl_ms_garch_estimate(SEXP y, SEXP K, SEXP gjr)
{
    static const char *nm[] = {"omega", "alpha", "beta", "gamma", "P", "regimes", "s2", "loglik", "convergence"};
    sl_ctx cx;
    int k = i1(K, "K"), g = l1(gjr, "gjr"), n = len_int(y), st, code = 0;
    double ll = 0.0;
    SEXP el[9], out;
    if (k < 2 || k > 64) Rf_errorcall(R_NilValue, "MS-GARCH: Anzahl Regime muss zwischen 2 und 64 liegen (erhalten: %d)", k);
    el[0] = PROTECT(Rf_allocVector(REALSXP, k)); el[1] = PROTECT(Rf_allocVector(REALSXP, k));
    el[2] = PROTECT(Rf_allocVector(REALSXP, k)); el[3] = PROTECT(Rf_allocVector(REALSXP, k));
    el[4] = PROTECT(Rf_allocMatrix(REALSXP, k, k)); el[5] = PROTECT(Rf_allocVector(INTSXP, n));
    el[6] = PROTECT(Rf_allocVector(REALSXP, n));
    ctx_init(&cx);
    st = sl_msgarch_estimate(&cx, n, dvec(y, -1, "y"), k, g, REAL(el[0]), REAL(el[1]), REAL(el[2]), REAL(el[3]),
                             REAL(el[4]), (int32_t *) INTEGER(el[5]), REAL(el[6]), &ll, &code);
    finish(&cx, st, 7);
    el[7] = PROTECT(Rf_ScalarReal(ll)); el[8] = PROTECT(Rf_ScalarInteger(code));
    out = named(9, nm, el);
    UNPROTECT(9);
    return out;
}

SEXP C_sl_hmm_em_univ(SEXP x, SEXP K, SEXP win, SEXP maxit, SEXP tol)
{
    static const char *nm[] = {"mu", "S", "A", "ll", "iter"};
    sl_ctx cx;
    int k = i1(K, "K"), st, it = 0;
    double ll = 0.0;
    SEXP el[5], out;
    if (k < 2 || k > 64) Rf_errorcall(R_NilValue, "HMM: Anzahl Zustände muss zwischen 2 und 64 liegen (erhalten: %d)", k);
    el[0] = PROTECT(Rf_allocVector(REALSXP, k)); el[1] = PROTECT(Rf_allocVector(REALSXP, k));
    el[2] = PROTECT(Rf_allocMatrix(REALSXP, k, k));
    ctx_init(&cx);
    st = sl_hmm_em_univ(&cx, len_int(x), dvec(x, -1, "x"), k, i1(win, "win"), i1(maxit, "max_iter"), d1(tol, "tol"),
                        REAL(el[0]), REAL(el[1]), REAL(el[2]), &ll, &it);
    finish(&cx, st, 3);
    el[3] = PROTECT(Rf_ScalarReal(ll)); el[4] = PROTECT(Rf_ScalarInteger(it));
    out = named(5, nm, el);
    UNPROTECT(5);
    return out;
}

SEXP C_sl_hmm_viterbi(SEXP lB, SEXP lA, SEXP lp0)
{
    sl_ctx cx;
    int n, K, ar, ac, st;
    const double *b = dmat(lB, &n, &K, "lB"), *a = dmat(lA, &ar, &ac, "lA");
    SEXP out;
    if (ar != K || ac != K) Rf_errorcall(R_NilValue, "interner Fehler: lA muss K x K sein");
    out = PROTECT(Rf_allocVector(INTSXP, n));
    ctx_init(&cx);
    st = sl_hmm_viterbi(&cx, n, K, b, a, dvec(lp0, K, "lp0"), (int32_t *) INTEGER(out));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}

/* ── Bootstrap-Kerne (Zustand raw(32) -> list(Ergebnis, Zustand)) ── */

#define BOOT_BEGIN(state) sl_rng r; sl_ctx cx; int st; get_state(state, &r); ctx_init(&cx)

static int count_out(SEXP n_out)
{
    int v = i1(n_out, "n_out");
    if (v < 0) Rf_errorcall(R_NilValue, "n_out muss >= 0 sein");
    return v;
}

SEXP C_sl_boot_idx_iid(SEXP state, SEXP n_src, SEXP n_out)
{
    BOOT_BEGIN(state);
    int no = count_out(n_out);
    SEXP out = PROTECT(Rf_allocVector(INTSXP, no)), res;
    st = sl_boot_idx_iid(&cx, &r, i1(n_src, "n_src"), no, (int32_t *) INTEGER(out));
    finish(&cx, st, 1);
    res = pair(out, &r);
    UNPROTECT(1);
    return res;
}

SEXP C_sl_boot_idx_block(SEXP state, SEXP n_src, SEXP n_out, SEXP bl, SEXP circ)
{
    BOOT_BEGIN(state);
    int no = count_out(n_out);
    SEXP out = PROTECT(Rf_allocVector(INTSXP, no)), res;
    st = sl_boot_idx_block(&cx, &r, i1(n_src, "n_src"), no, i1(bl, "block_length"), l1(circ, "circular"),
                           (int32_t *) INTEGER(out));
    finish(&cx, st, 1);
    res = pair(out, &r);
    UNPROTECT(1);
    return res;
}

SEXP C_sl_boot_idx_stationary(SEXP state, SEXP n_src, SEXP n_out, SEXP L)
{
    BOOT_BEGIN(state);
    int no = count_out(n_out);
    SEXP out = PROTECT(Rf_allocVector(INTSXP, no)), res;
    st = sl_boot_idx_stationary(&cx, &r, i1(n_src, "n_src"), no, d1(L, "L"), (int32_t *) INTEGER(out));
    finish(&cx, st, 1);
    res = pair(out, &r);
    UNPROTECT(1);
    return res;
}

SEXP C_sl_boot_idx_regime(SEXP state, SEXP regimes, SEXP trans, SEXP n_out)
{
    BOOT_BEGIN(state);
    int no = count_out(n_out), K, kc;
    const double *tr = dmat(trans, &K, &kc, "trans");
    SEXP out, res;
    if (kc != K) Rf_errorcall(R_NilValue, "interner Fehler: trans muss quadratisch sein");
    out = PROTECT(Rf_allocVector(INTSXP, no));
    st = sl_boot_idx_regime(&cx, &r, len_int(regimes), ivec(regimes, -1, "regimes"), K, tr, no, (int32_t *) INTEGER(out));
    finish(&cx, st, 1);
    res = pair(out, &r);
    UNPROTECT(1);
    return res;
}

SEXP C_sl_boot_idx_tails(SEXP state, SEXP n_out, SEXP pl, SEXP pr, SEXP bulk, SEXP left, SEXP right)
{
    BOOT_BEGIN(state);
    int no = count_out(n_out);
    SEXP out = PROTECT(Rf_allocVector(INTSXP, no)), res;
    st = sl_boot_idx_tails(&cx, &r, no, d1(pl, "p_l"), d1(pr, "p_r"), len_int(bulk), ivec(bulk, -1, "bulk_idx"),
                           len_int(left), ivec(left, -1, "left_idx"), len_int(right), ivec(right, -1, "right_idx"),
                           (int32_t *) INTEGER(out));
    finish(&cx, st, 1);
    res = pair(out, &r);
    UNPROTECT(1);
    return res;
}

SEXP C_sl_boot_wild(SEXP state, SEXP ret, SEXP type)
{
    BOOT_BEGIN(state);
    int n, k;
    const double *x = dmat(ret, &n, &k, "returns");
    SEXP out = PROTECT(Rf_allocMatrix(REALSXP, n, k)), res;
    st = sl_boot_wild(&cx, &r, n, k, x, i1(type, "type"), REAL(out));
    finish(&cx, st, 1);
    res = pair(out, &r);
    UNPROTECT(1);
    return res;
}

SEXP C_sl_boot_reset(SEXP state, SEXP ret, SEXP p_break)
{
    BOOT_BEGIN(state);
    int n, k;
    const double *x = dmat(ret, &n, &k, "returns");
    SEXP out = PROTECT(Rf_allocMatrix(REALSXP, n, k)), res;
    st = sl_boot_reset(&cx, &r, n, k, x, d1(p_break, "p_break"), REAL(out));
    finish(&cx, st, 1);
    res = pair(out, &r);
    UNPROTECT(1);
    return res;
}

static SEXP ret_idx(SEXP ret, SEXP idx)
{
    static const char *nm[] = {"ret", "idx"};
    SEXP el[2];
    el[0] = ret; el[1] = idx;
    return named(2, nm, el);
}

/* par_l, par_r = c(p, thresh, scale, shape) */
SEXP C_sl_boot_evt(SEXP state, SEXP ret, SEXP base, SEXP n_out, SEXP par_l, SEXP pool_l, SEXP par_r, SEXP pool_r,
                   SEXP bulk)
{
    BOOT_BEGIN(state);
    int n, k, no = count_out(n_out);
    const double *x = dmat(ret, &n, &k, "returns"), *a = dvec(par_l, 4, "par_l"), *b = dvec(par_r, 4, "par_r");
    SEXP out = PROTECT(Rf_allocMatrix(REALSXP, no, k)), idx = PROTECT(Rf_allocVector(INTSXP, no)), res, lst;
    st = sl_boot_evt(&cx, &r, n, k, x, i1(base, "base"), no, a[0], a[1], a[2], a[3], len_int(pool_l),
                     ivec(pool_l, -1, "pool_l"), b[0], b[1], b[2], b[3], len_int(pool_r), ivec(pool_r, -1, "pool_r"),
                     len_int(bulk), ivec(bulk, -1, "bulk_idx"), REAL(out), (int32_t *) INTEGER(idx));
    finish(&cx, st, 2);
    lst = PROTECT(ret_idx(out, idx));
    res = pair(lst, &r);
    UNPROTECT(3);
    return res;
}

/* cross = list(cols (int, 0-basiert), mu, om, al, be, ratio (int), s2, z (Matrix n_src x m)) */
typedef struct { int m; const int32_t *cols, *ratio; const double *mu, *om, *al, *be, *s2, *z; } cross_args;

static void get_cross(SEXP cr, int n_src, cross_args *c)
{
    int zr, zc;
    if (TYPEOF(cr) != VECSXP || XLENGTH(cr) != 8) Rf_errorcall(R_NilValue, "interner Fehler: cross muss eine Liste mit 8 Elementen sein");
    c->m = len_int(VECTOR_ELT(cr, 0));
    c->cols = ivec(VECTOR_ELT(cr, 0), -1, "cross_cols");
    c->mu = dvec(VECTOR_ELT(cr, 1), c->m, "cmu");
    c->om = dvec(VECTOR_ELT(cr, 2), c->m, "com");
    c->al = dvec(VECTOR_ELT(cr, 3), c->m, "cal");
    c->be = dvec(VECTOR_ELT(cr, 4), c->m, "cbe");
    c->ratio = ivec(VECTOR_ELT(cr, 5), c->m, "cratio");
    c->s2 = dvec(VECTOR_ELT(cr, 6), c->m, "cs2");
    c->z = dmat(VECTOR_ELT(cr, 7), &zr, &zc, "z_cross");
    if (zc != c->m || (c->m > 0 && zr != n_src)) Rf_errorcall(R_NilValue, "interner Fehler: z_cross muss n_src x m sein");
}

/* g = c(mu, omega, alpha, beta, gamma, s2_init) */
SEXP C_sl_boot_garch(SEXP state, SEXP n_out, SEXP base, SEXP k, SEXP g, SEXP z_base, SEXP valid, SEXP cross)
{
    BOOT_BEGIN(state);
    int no = count_out(n_out), kk = i1(k, "k"), ns = len_int(z_base);
    const double *p = dvec(g, 6, "garch");
    cross_args c;
    SEXP out, idx, lst, res;
    get_cross(cross, ns, &c);
    out = PROTECT(Rf_allocMatrix(REALSXP, no, kk));
    idx = PROTECT(Rf_allocVector(INTSXP, no));
    st = sl_boot_garch(&cx, &r, no, i1(base, "base"), kk, p[0], p[1], p[2], p[3], p[4], p[5], ns, REAL(z_base),
                       len_int(valid), ivec(valid, -1, "valid"), c.m, c.cols, c.mu, c.om, c.al, c.be, c.ratio, c.s2, c.z,
                       REAL(out), (int32_t *) INTEGER(idx));
    finish(&cx, st, 2);
    lst = PROTECT(ret_idx(out, idx));
    res = pair(lst, &r);
    UNPROTECT(3);
    return res;
}

/* m = list(mu, omega, alpha, beta, gamma, phi, lambda, trans, delta, unc_var, stat_prob) */
SEXP C_sl_boot_ms_garch(SEXP state, SEXP n_out, SEXP base, SEXP k, SEXP m, SEXP pool_off, SEXP pool_idx,
                        SEXP z_base, SEXP cross)
{
    static const char *nm[] = {"ret", "idx", "regime"};
    BOOT_BEGIN(state);
    int no = count_out(n_out), kk = i1(k, "k"), ns = len_int(z_base), K, tr, tc, dr, dc, i;
    const double *v[11];
    cross_args c;
    SEXP out, idx, reg, el[3], lst, res;
    if (TYPEOF(m) != VECSXP || XLENGTH(m) != 11) Rf_errorcall(R_NilValue, "interner Fehler: m muss eine Liste mit 11 Elementen sein");
    K = len_int(VECTOR_ELT(m, 0));
    for (i = 0; i < 7; i++) v[i] = dvec(VECTOR_ELT(m, i), K, "Regimeparameter");
    v[7] = dmat(VECTOR_ELT(m, 7), &tr, &tc, "trans");
    v[8] = dmat(VECTOR_ELT(m, 8), &dr, &dc, "delta");
    if (tr != K || tc != K || dr != K || dc != K) Rf_errorcall(R_NilValue, "interner Fehler: trans und delta muessen K x K sein");
    v[9] = dvec(VECTOR_ELT(m, 9), K, "unc_var");
    v[10] = dvec(VECTOR_ELT(m, 10), K, "stat_prob");
    get_cross(cross, ns, &c);
    out = PROTECT(Rf_allocMatrix(REALSXP, no, kk));
    idx = PROTECT(Rf_allocVector(INTSXP, no));
    reg = PROTECT(Rf_allocVector(INTSXP, no));
    st = sl_boot_ms_garch(&cx, &r, no, i1(base, "base"), kk, K, v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8],
                          v[9], v[10], ivec(pool_off, K + 1, "pool_off"), ivec(pool_idx, -1, "pool_idx"), ns, REAL(z_base),
                          c.m, c.cols, c.mu, c.om, c.al, c.be, c.ratio, c.s2, c.z, REAL(out), (int32_t *) INTEGER(idx),
                          (int32_t *) INTEGER(reg));
    finish(&cx, st, 3);
    el[0] = out; el[1] = idx; el[2] = reg;
    lst = PROTECT(named(3, nm, el));
    res = pair(lst, &r);
    UNPROTECT(4);
    return res;
}

SEXP C_sl_rolling_vol(SEXP x, SEXP window)
{
    sl_ctx cx;
    int n = len_int(x), st;
    SEXP out = PROTECT(Rf_allocVector(REALSXP, n));
    ctx_init(&cx);
    st = sl_rolling_vol(&cx, n, dvec(x, -1, "x"), i1(window, "window"), REAL(out));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}

SEXP C_sl_assign_regimes(SEXP vol, SEXP thresh)
{
    sl_ctx cx;
    int n = len_int(vol), st;
    SEXP out = PROTECT(Rf_allocVector(INTSXP, n));
    ctx_init(&cx);
    st = sl_assign_regimes(&cx, n, dvec(vol, -1, "vol"), len_int(thresh), dvec(thresh, -1, "thresh"),
                           (int32_t *) INTEGER(out));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}

SEXP C_sl_estimate_trans_mat(SEXP regimes, SEXP K, SEXP alpha)
{
    sl_ctx cx;
    int k = i1(K, "K"), st;
    SEXP out;
    if (k < 1) Rf_errorcall(R_NilValue, "K muss >= 1 sein");
    out = PROTECT(Rf_allocMatrix(REALSXP, k, k));
    ctx_init(&cx);
    st = sl_estimate_trans_mat(&cx, len_int(regimes), ivec(regimes, -1, "regimes"), k, d1(alpha, "alpha"), REAL(out));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}
