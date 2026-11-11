/*
 * src/slc_r.cpp -- R-Huellen (.Call) der C-Bibliothek slc (SimLev core)
 *
 * Die Kerne (slc*.cpp, slc*.h) sind Kopien der kanonischen Quellen in core/ (core/sync.py);
 * nur diese Huelle gibt es nur hier. Registrierung in init.cpp (Namen sl_*, in R C_sl_*), die
 * R-Seite steht in R/slc.R (interne Funktionen .sl_*).
 *
 * Rueckmeldungen: der Kern springt nie; nach dem Aufruf gibt die Huelle die
 * gesammelten Warnungen in Reihenfolge mit Rf_warningcall(R_NilValue, ...) aus (wie
 * warning(call. = FALSE)) und einen Fehler mit Rf_errorcall(R_NilValue, ...) (wie
 * stop(call. = FALSE)); das longjmp entsteht also nur hier. Benutzerabbruch: Rueckruf ueber
 * R_ToplevelExec (kein longjmp im Kern); bei SL_EINTR danach Rf_onintr() (seit 1.6.5, huelle_r.h).
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
#include "slc_rbase.h"   /* sl_r_colsums_idx (seit 1.6.3) */

/* .Call-Huellen mit C-Bindung (Registrierung in init.cpp) */
extern "C" {

#include "huelle_r.h"   /* Kontext, Rueckmeldungen, Argumentpruefungen (seit 1.6.3 gemeinsam) */

/* ── weitere Hilfen ── */

static int64_t count1(SEXP x, const char *what)
{
    double v = num1(x, what);
    if (!(v >= 0 && v <= 4503599627370496.0) || v != (double) (int64_t) v)
        Rf_errorcall(R_NilValue, "interner Fehler: %s muss eine ganze Zahl >= 0 sein", what);
    return (int64_t) v;
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

/* Länderblöcke von bootstrap_pooled (seit 1.6.5, Paket E, K40/CR2-6; R/planning.R): nr Zeilen je Land (double),
 * cw Ländergewichte, L, nper, n -> list(list(c, r) als ganzzahlige nper x n-Matrizen, Zustand) */
SEXP C_sl_pooled_draw(SEXP state, SEXP nr, SEXP cw, SEXP L, SEXP nper, SEXP n)
{
    sl_rng r;
    sl_ctx cx;
    int64_t np = count1(nper, "nper"), nn = count1(n, "n"), nc, i;
    int64_t *rows;
    int st;
    SEXP ctry, row, val, nms, res;
    get_state(state, &r);
    need_real(nr, "nr");
    need_real(cw, "cw");
    nc = (int64_t) XLENGTH(nr);
    if (XLENGTH(cw) != nc) Rf_errorcall(R_NilValue, "pooled_draw: Länge von cw passt nicht zu nr");
    rows = (int64_t *) R_alloc((size_t) (nc > 0 ? nc : 1), sizeof(int64_t));
    for (i = 0; i < nc; i++) rows[i] = (int64_t) REAL(nr)[i];
    ctry = PROTECT(Rf_allocMatrix(INTSXP, (int) np, (int) nn));
    row = PROTECT(Rf_allocMatrix(INTSXP, (int) np, (int) nn));
    ctx_init(&cx);
    st = sl_pooled_draw(&cx, &r, nc, rows, REAL(cw), num1(L, "L"), np, nn, INTEGER(ctry), INTEGER(row));
    finish(&cx, st, 1);
    val = PROTECT(Rf_allocVector(VECSXP, 2));
    SET_VECTOR_ELT(val, 0, ctry);
    SET_VECTOR_ELT(val, 1, row);
    nms = PROTECT(Rf_allocVector(STRSXP, 2));
    SET_STRING_ELT(nms, 0, Rf_mkChar("c"));
    SET_STRING_ELT(nms, 1, Rf_mkChar("r"));
    Rf_setAttrib(val, R_NamesSymbol, nms);
    res = pair(val, &r);
    UNPROTECT(4);
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

/* colSums/colMeans(x[idx, , drop = FALSE]) ohne die Kopie (seit 1.6.3, sl_r_colsums_idx in slc_rbase.cpp): x double-
 * Matrix, idx Zeilennummern (integer oder ganzzahliges double, 1-basiert), narm, mean logisch; Ergebnis double der
 * Laenge ncol(x) ohne Namen. Bit fuer Bit wie die Grundfunktion auf der Kopie (long double je Spalte). */
SEXP C_sl_r_colsums_idx(SEXP x, SEXP idx, SEXP narm, SEXP mean)
{
    SEXP out, dim;
    int64_t *ix;
    R_xlen_t m, i;
    int st;
    need_real(x, "x");
    dim = Rf_getAttrib(x, R_DimSymbol);
    if (TYPEOF(dim) != INTSXP || XLENGTH(dim) != 2) Rf_errorcall(R_NilValue, "interner Fehler: x muss eine Matrix sein");
    const int64_t nr = INTEGER(dim)[0], nc = INTEGER(dim)[1];
    if (TYPEOF(idx) != INTSXP && TYPEOF(idx) != REALSXP)
        Rf_errorcall(R_NilValue, "interner Fehler: idx muss integer oder double sein");
    m = XLENGTH(idx);
    ix = (int64_t *) R_alloc((size_t) (m > 0 ? m : 1), sizeof(int64_t));
    for (i = 0; i < m; i++) {
        if (TYPEOF(idx) == INTSXP) {
            const int v = INTEGER(idx)[i];
            ix[i] = v == NA_INTEGER ? 0 : (int64_t) v;
        } else {
            const double v = REAL(idx)[i];
            ix[i] = (v >= 1 && v <= (double) nr && v == (double) (int64_t) v) ? (int64_t) v : 0;
        }
    }
    out = PROTECT(Rf_allocVector(REALSXP, (R_xlen_t) nc));
    st = sl_r_colsums_idx(nr, nc, REAL(x), 1, nr, (int64_t) m, ix, 1, lgl1(narm, "narm"), lgl1(mean, "mean"), REAL(out));
    UNPROTECT(1);
    if (st == SL_ENOMEM) Rf_errorcall(R_NilValue, "kein Speicher");
    if (st != SL_OK) Rf_errorcall(R_NilValue, "sl_r_colsums_idx: Zeilennummer ausserhalb");
    return out;
}

}  /* extern "C" */
