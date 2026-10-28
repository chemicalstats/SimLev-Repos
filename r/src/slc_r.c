/*
 * src/slc_r.c -- R-Huellen (.Call) der C-Bibliothek slc (SimLev core, Etappe 9.1)
 *
 * Die Kerne (slc*.c, slc*.h) sind Kopien der kanonischen Quellen in core/ (tools/core_sync.py);
 * nur diese Huelle gibt es nur hier. Registrierung in init.c (Namen sl_*, in R C_sl_*), die
 * R-Seite steht in R/slc.R (interne Funktionen .sl_*).
 *
 * Rueckmeldungen (Entwurf C.4): der Kern springt nie; nach dem Aufruf gibt die Huelle die
 * gesammelten Warnungen in Reihenfolge mit Rf_warningcall(R_NilValue, ...) aus (wie
 * warning(call. = FALSE)) und einen Fehler mit Rf_errorcall(R_NilValue, ...) (wie
 * stop(call. = FALSE)); das longjmp entsteht also nur hier. Benutzerabbruch: Rueckruf ueber
 * R_ToplevelExec (kein longjmp im Kern); bei SL_EINTR danach R_CheckUserInterrupt().
 *
 * Zufallszustand: raw(32) (Host-Bytereihenfolge von uint64_t[4]). Ziehende Huellen geben
 * list(Ergebnis, neuer Zustand) zurueck; R ersetzt den Zustand (kein Aendern an Ort und Stelle).
 */
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Utils.h>

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#include "slc.h"

/* ── Kontext und Rueckmeldungen ── */

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

static void get_state(SEXP s, sl_rng *r)
{
    if (TYPEOF(s) != RAWSXP || XLENGTH(s) != 32)
        Rf_errorcall(R_NilValue, "interner Fehler: Zufallszustand muss raw(32) sein");
    memcpy(r->s, RAW(s), 32);
}

static SEXP new_state(const sl_rng *r)
{
    SEXP s = PROTECT(Rf_allocVector(RAWSXP, 32));
    memcpy(RAW(s), r->s, 32);
    UNPROTECT(1);
    return s;
}

static double num1(SEXP x, const char *what)
{
    if (TYPEOF(x) != REALSXP || XLENGTH(x) != 1)
        Rf_errorcall(R_NilValue, "interner Fehler: %s muss eine Zahl (double, Laenge 1) sein", what);
    return REAL(x)[0];
}

static int lgl1(SEXP x, const char *what)
{
    if (TYPEOF(x) != LGLSXP || XLENGTH(x) != 1 || LOGICAL(x)[0] == NA_LOGICAL)
        Rf_errorcall(R_NilValue, "interner Fehler: %s muss TRUE oder FALSE sein", what);
    return LOGICAL(x)[0];
}

static int64_t count1(SEXP x, const char *what)
{
    double v = num1(x, what);
    if (!(v >= 0 && v <= 4503599627370496.0) || v != (double) (int64_t) v)
        Rf_errorcall(R_NilValue, "interner Fehler: %s muss eine ganze Zahl >= 0 sein", what);
    return (int64_t) v;
}

static void need_real(SEXP x, const char *what)
{
    if (TYPEOF(x) != REALSXP) Rf_errorcall(R_NilValue, "interner Fehler: %s muss double sein", what);
}

static SEXP pair(SEXP a, const sl_rng *r)
{
    SEXP out = PROTECT(Rf_allocVector(VECSXP, 2));
    SET_VECTOR_ELT(out, 0, a);
    SET_VECTOR_ELT(out, 1, new_state(r));
    UNPROTECT(1);
    return out;
}

/* ── Zustand ── */

SEXP C_sl_version(void) { return Rf_mkString(sl_version()); }

SEXP C_sl_rng_seed(SEXP seed)
{
    sl_rng r;
    double v = num1(seed, "seed");
    sl_rng_seed(&r, (int64_t) v);        /* R/slc.R prueft: ganzzahlig, |seed| < 2^53 */
    return new_state(&r);
}

SEXP C_sl_rng_seed_entropy(SEXP t_ns, SEXP pid, SEXP counter)
{
    sl_rng r;
    double a = num1(t_ns, "t_ns"), b = num1(pid, "pid"), c = num1(counter, "counter");
    uint64_t ua = (a > 0 && a < 1.8e19) ? (uint64_t) a : 0u;
    uint64_t ub = (b > 0 && b < 1.8e19) ? (uint64_t) b : 0u;
    uint64_t uc = (c > 0 && c < 1.8e19) ? (uint64_t) c : 0u;
    sl_rng_seed_entropy(&r, ua, ub, uc);
    return new_state(&r);
}

SEXP C_sl_rng_jump(SEXP state)
{
    sl_rng r;
    get_state(state, &r);
    sl_rng_jump(&r);
    return new_state(&r);
}

SEXP C_sl_rng_streams(SEXP state, SEXP n)
{
    sl_rng r, *buf;
    sl_ctx cx;
    int64_t k = count1(n, "n"), i;
    int st;
    SEXP out;
    get_state(state, &r);
    ctx_init(&cx);
    buf = (sl_rng *) R_alloc((size_t) (k > 0 ? k : 1), sizeof(sl_rng));
    st = sl_rng_streams(&cx, &r, k, buf);
    finish(&cx, st, 0);
    out = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t) k));
    for (i = 0; i < k; i++) SET_VECTOR_ELT(out, (R_xlen_t) i, new_state(&buf[i]));
    UNPROTECT(1);
    return out;
}

SEXP C_sl_rng_seed31(SEXP state)
{
    sl_rng r;
    SEXP v;
    get_state(state, &r);
    v = PROTECT(Rf_ScalarInteger((int) sl_rng_seed31(&r)));
    v = pair(v, &r);
    UNPROTECT(1);
    return v;
}

SEXP C_sl_rng_hex(SEXP state)
{
    sl_rng r;
    char buf[17];
    int i;
    SEXP out;
    get_state(state, &r);
    out = PROTECT(Rf_allocVector(STRSXP, 4));
    for (i = 0; i < 4; i++) {
        snprintf(buf, sizeof buf, "%016" PRIx64, r.s[i]);
        SET_STRING_ELT(out, i, Rf_mkChar(buf));
    }
    UNPROTECT(1);
    return out;
}

SEXP C_sl_rng_u64(SEXP state, SEXP n)
{
    sl_rng r;
    char buf[17];
    int64_t k = count1(n, "n"), i;
    SEXP out, res;
    get_state(state, &r);
    out = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t) k));
    for (i = 0; i < k; i++) {
        snprintf(buf, sizeof buf, "%016" PRIx64, sl_rng_next(&r));
        SET_STRING_ELT(out, (R_xlen_t) i, Rf_mkChar(buf));
    }
    res = pair(out, &r);
    UNPROTECT(1);
    return res;
}

/* ── Ziehungen ── */

typedef int (*draw2_fn)(sl_ctx *, sl_rng *, int64_t, double, double, double *);
typedef int (*draw1_fn)(sl_ctx *, sl_rng *, int64_t, double, double *);

static SEXP draw2(draw2_fn f, SEXP state, SEXP n, SEXP a, SEXP b)
{
    sl_rng r;
    sl_ctx cx;
    int64_t k = count1(n, "n");
    double pa = num1(a, "Parameter"), pb = num1(b, "Parameter");
    int st;
    SEXP out, res;
    get_state(state, &r);
    ctx_init(&cx);
    out = PROTECT(Rf_allocVector(REALSXP, (R_xlen_t) k));
    st = f(&cx, &r, k, pa, pb, REAL(out));
    finish(&cx, st, 1);
    res = pair(out, &r);
    UNPROTECT(1);
    return res;
}

static SEXP draw1(draw1_fn f, SEXP state, SEXP n, SEXP a)
{
    sl_rng r;
    sl_ctx cx;
    int64_t k = count1(n, "n");
    double pa = num1(a, "Parameter");
    int st;
    SEXP out, res;
    get_state(state, &r);
    ctx_init(&cx);
    out = PROTECT(Rf_allocVector(REALSXP, (R_xlen_t) k));
    st = f(&cx, &r, k, pa, REAL(out));
    finish(&cx, st, 1);
    res = pair(out, &r);
    UNPROTECT(1);
    return res;
}

SEXP C_sl_runif(SEXP state, SEXP n, SEXP a, SEXP b) { return draw2(sl_runif, state, n, a, b); }
SEXP C_sl_rnorm(SEXP state, SEXP n, SEXP mu, SEXP sd) { return draw2(sl_rnorm, state, n, mu, sd); }
SEXP C_sl_rgamma(SEXP state, SEXP n, SEXP shape, SEXP scale) { return draw2(sl_rgamma, state, n, shape, scale); }
SEXP C_sl_rexp(SEXP state, SEXP n, SEXP rate) { return draw1(sl_rexp, state, n, rate); }
SEXP C_sl_rgeom(SEXP state, SEXP n, SEXP p) { return draw1(sl_rgeom, state, n, p); }
SEXP C_sl_rchisq(SEXP state, SEXP n, SEXP df) { return draw1(sl_rchisq, state, n, df); }

SEXP C_sl_sample(SEXP state, SEXP n, SEXP size, SEXP replace, SEXP prob)
{
    sl_rng r;
    sl_ctx cx;
    int64_t nn = count1(n, "n"), sz = count1(size, "size");
    int rep = lgl1(replace, "replace"), st;
    const double *pp = NULL;
    SEXP out, res;
    get_state(state, &r);
    if (prob != R_NilValue) {
        need_real(prob, "prob");
        if (XLENGTH(prob) != nn) Rf_errorcall(R_NilValue, "sample: Länge von prob passt nicht zu n");
        pp = REAL(prob);
    }
    ctx_init(&cx);
    out = PROTECT(Rf_allocVector(INTSXP, (R_xlen_t) sz));
    st = sl_sample(&cx, &r, nn, sz, rep, pp, INTEGER(out));
    finish(&cx, st, 1);
    res = pair(out, &r);
    UNPROTECT(1);
    return res;
}

/* ── Verteilungen (elementweise; Parameter skalar) ── */

SEXP C_sl_pnorm(SEXP x, SEXP mu, SEXP sd, SEXP lower)
{
    sl_ctx cx;
    SEXP out;
    int st;
    need_real(x, "x");
    ctx_init(&cx);
    out = PROTECT(Rf_allocVector(REALSXP, XLENGTH(x)));
    st = sl_pnorm(&cx, XLENGTH(x), REAL(x), num1(mu, "mean"), num1(sd, "sd"), lgl1(lower, "lower.tail"), REAL(out));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}

SEXP C_sl_qnorm(SEXP p, SEXP mu, SEXP sd, SEXP lower)
{
    sl_ctx cx;
    SEXP out;
    int st;
    need_real(p, "p");
    ctx_init(&cx);
    out = PROTECT(Rf_allocVector(REALSXP, XLENGTH(p)));
    st = sl_qnorm(&cx, XLENGTH(p), REAL(p), num1(mu, "mean"), num1(sd, "sd"), lgl1(lower, "lower.tail"), REAL(out));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}

SEXP C_sl_dnorm(SEXP x, SEXP mu, SEXP sd, SEXP give_log)
{
    sl_ctx cx;
    SEXP out;
    int st;
    need_real(x, "x");
    ctx_init(&cx);
    out = PROTECT(Rf_allocVector(REALSXP, XLENGTH(x)));
    st = sl_dnorm(&cx, XLENGTH(x), REAL(x), num1(mu, "mean"), num1(sd, "sd"), lgl1(give_log, "log"), REAL(out));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}

typedef int (*unary_fn)(sl_ctx *, int64_t, const double *, double *);

static SEXP unary(unary_fn f, SEXP x)
{
    sl_ctx cx;
    SEXP out;
    int st;
    need_real(x, "x");
    ctx_init(&cx);
    out = PROTECT(Rf_allocVector(REALSXP, XLENGTH(x)));
    st = f(&cx, XLENGTH(x), REAL(x), REAL(out));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}

SEXP C_sl_erfc(SEXP x) { return unary(sl_erfc_v, x); }
SEXP C_sl_lgamma(SEXP x) { return unary(sl_lgamma, x); }
SEXP C_sl_plogis(SEXP x) { return unary(sl_plogis, x); }
SEXP C_sl_qlogis(SEXP p) { return unary(sl_qlogis, p); }

SEXP C_sl_pbeta(SEXP x, SEXP a, SEXP b, SEXP lower)
{
    sl_ctx cx;
    SEXP out;
    int st;
    need_real(x, "x");
    ctx_init(&cx);
    out = PROTECT(Rf_allocVector(REALSXP, XLENGTH(x)));
    st = sl_pbeta(&cx, XLENGTH(x), REAL(x), num1(a, "shape1"), num1(b, "shape2"), lgl1(lower, "lower.tail"), REAL(out));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}

typedef int (*tdist_fn)(sl_ctx *, int64_t, const double *, double, int, double *);

static SEXP tdist(tdist_fn f, SEXP x, SEXP df, SEXP lower)
{
    sl_ctx cx;
    SEXP out;
    int st;
    need_real(x, "x");
    ctx_init(&cx);
    out = PROTECT(Rf_allocVector(REALSXP, XLENGTH(x)));
    st = f(&cx, XLENGTH(x), REAL(x), num1(df, "df"), lgl1(lower, "lower.tail"), REAL(out));
    finish(&cx, st, 1);
    UNPROTECT(1);
    return out;
}

SEXP C_sl_pt(SEXP x, SEXP df, SEXP lower) { return tdist(sl_pt, x, df, lower); }
SEXP C_sl_qt(SEXP p, SEXP df, SEXP lower) { return tdist(sl_qt, p, df, lower); }
