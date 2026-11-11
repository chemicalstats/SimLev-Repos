/*
 * src/slc_r_stats.cpp -- R-Huellen (.Call) der Statistikwege der C-Bibliothek slc (seit 1.6.4, C-035)
 *
 * Bis 1.6.3 rechnete R cov/cor/var/sd, optimize, approx, filter, dist und hclust mit R's eigenem C- bzw.
 * Fortran-Code (stats), Python und Julia mit den Kernen. R's eigener Code wird ohne -ffp-contract=off
 * uebersetzt und darf auf ARM (aarch64, Apple Silicon) zu fma zusammenziehen; die Kerne nicht. Seit 1.6.4
 * rechnen auch die R-Wege mit den Kernen (R/slc_stats.R); auf x86-64 bitgleich zum bisherigen R-Ergebnis.
 *
 * Kerne: slc_rbase_cov.cpp (sl_r_cov), slc_rbase.cpp (sl_r_approx), slc_opt_fmin.cpp (sl_fmin_*),
 * slc_rbase_smooth.cpp (sl_r_filter_conv/_rec), slc_rbase_clust.cpp (sl_r_dist, sl_r_hclust); Kopien aus
 * core/ (core/sync.py). Registrierung in init.cpp.
 *
 * Rueckmeldungen: anders als die uebrigen Huellen geben diese Huellen Fehler und Warnungen nicht selbst aus.
 * Ein Fehler kommt als Text (character(1)) zurueck, eine Warnung als Kennzeichen im Ergebnis; die R-Seite
 * meldet beide mit dem Aufruf, den R's eigene Funktion gemeldet haette (z. B. stats::cor(x, y)), und mit
 * R's Uebersetzung (gleiche Meldungen wie bis 1.6.3).
 *
 * Herkunft:           Pruefungen, Dimensionen und Namen nach R 4.3.3, src/library/stats/src/cov.c (corcov),
 *                     approx.c (ApproxTest, Approx), filter.c (cfilter, rfilter), distance.c (Cdist,
 *                     R_distance), optimize.c (do_fmin)
 * Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut Kopf der
 *                     jeweiligen R-Quelle)
 * Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
 * Aenderungen:        Rechnung in den Kernen; Fehler und Warnungen als Rueckgabe an die R-Seite.
 */
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Utils.h>

#include <float.h>
#include <string.h>

#include "slc.h"
#include "slc_opt.h"
#include "slc_rbase2.h"

/* .Call-Huellen mit C-Bindung (Registrierung in init.cpp) */
extern "C" {

#include "huelle_r.h"   /* Kontext, Rueckmeldungen, Argumentpruefungen (seit 1.6.3 gemeinsam) */

/* Fehlertext als Rueckgabe (die R-Seite meldet ihn mit dem Aufruf von R's Funktion) */
static SEXP err_text(const char *msg, int nprot)
{
    SEXP s;
    if (nprot) UNPROTECT(nprot);
    PROTECT(s = Rf_mkString(msg));
    UNPROTECT(1);
    return s;
}

/* ── cov/cor/var (stats/src/cov.c, corcov) ──────────────────────────────────
 * Rueckgabe list(ans, sd0) oder Fehlertext; ans wie corcov (Matrix mit Namen bzw. Vektor). */
SEXP C_sl_r_corcov(SEXP x, SEXP y, SEXP na_method, SEXP skendall, SEXP scor)
{
    SEXP ans, ind, out;
    int ansmat, kendall, cor = Rf_asLogical(scor), method, n, ncx, ncy, nprotect = 1, sd0 = 0, st;
    int empty_err;
    sl_ctx cx;
    static const char *var_factor =
        "Calling var(x) on a factor x is defunct.\n  Use something like 'all(duplicated(x)[-1L])' to test for a constant vector.";

    if (Rf_isNull(x)) return err_text("'x' is NULL", 0);
    if (Rf_isFactor(x)) return err_text(var_factor, 0);
    x = PROTECT(Rf_coerceVector(x, REALSXP));
    if ((ansmat = Rf_isMatrix(x))) {
        n = Rf_nrows(x);
        ncx = Rf_ncols(x);
    } else {
        n = Rf_length(x);
        ncx = 1;
    }
    if (Rf_isNull(y)) {
        ncy = ncx;
    } else {
        if (Rf_isFactor(y)) return err_text(var_factor, nprotect);
        y = PROTECT(Rf_coerceVector(y, REALSXP));
        nprotect++;
        if (Rf_isMatrix(y)) {
            if (Rf_nrows(y) != n) return err_text("incompatible dimensions", nprotect);
            ncy = Rf_ncols(y);
            ansmat = 1;
        } else {
            if (Rf_length(y) != n) return err_text("incompatible dimensions", nprotect);
            ncy = 1;
        }
    }
    method = Rf_asInteger(na_method);
    kendall = Rf_asLogical(skendall);
    empty_err = 1;
    switch (method) {
    case 1: case 3: break;
    case 2: if (!LENGTH(x)) return err_text("no complete element pairs", nprotect); break;
    case 4: case 5: empty_err = 0; break;
    default: return err_text("invalid 'use' (computational method)", nprotect);
    }
    if (empty_err && !LENGTH(x)) return err_text("'x' is empty", nprotect);
    if (ansmat) PROTECT(ans = Rf_allocMatrix(REALSXP, ncx, ncy));
    else PROTECT(ans = Rf_allocVector(REALSXP, (R_xlen_t) ncx * ncy));
    nprotect++;
    ctx_init(&cx);
    st = sl_r_cov(&cx, n, ncx, REAL(x), ncy, Rf_isNull(y) ? NULL : REAL(y), method, kendall != 0, cor != 0,
                  REAL(ans), &sd0);
    if (st == SL_ENOMEM) { UNPROTECT(nprotect); Rf_errorcall(R_NilValue, "cov: kein Speicher"); }
    if (st != SL_OK) {
        /* Fehlertexte des Kerns wie R ("missing observations in cov/cor", "no complete element pairs") */
        char msg[SL_MSG_LEN];
        memcpy(msg, cx.msg, SL_MSG_LEN);
        return err_text(msg, nprotect);
    }
    if (ansmat) {   /* Namen wie corcov */
        if (Rf_isNull(y)) {
            SEXP dn = Rf_getAttrib(x, R_DimNamesSymbol);
            if (!Rf_isNull(dn) && !Rf_isNull(VECTOR_ELT(dn, 1))) {
                PROTECT(ind = Rf_allocVector(VECSXP, 2));
                SET_VECTOR_ELT(ind, 0, Rf_duplicate(VECTOR_ELT(dn, 1)));
                SET_VECTOR_ELT(ind, 1, Rf_duplicate(VECTOR_ELT(dn, 1)));
                Rf_setAttrib(ans, R_DimNamesSymbol, ind);
                UNPROTECT(1);
            }
        } else {
            SEXP dx = Rf_getAttrib(x, R_DimNamesSymbol), dy = Rf_getAttrib(y, R_DimNamesSymbol);
            if ((Rf_length(dx) >= 2 && !Rf_isNull(VECTOR_ELT(dx, 1))) ||
                (Rf_length(dy) >= 2 && !Rf_isNull(VECTOR_ELT(dy, 1)))) {
                PROTECT(ind = Rf_allocVector(VECSXP, 2));
                if (Rf_length(dx) >= 2 && !Rf_isNull(VECTOR_ELT(dx, 1)))
                    SET_VECTOR_ELT(ind, 0, Rf_duplicate(VECTOR_ELT(dx, 1)));
                if (Rf_length(dy) >= 2 && !Rf_isNull(VECTOR_ELT(dy, 1)))
                    SET_VECTOR_ELT(ind, 1, Rf_duplicate(VECTOR_ELT(dy, 1)));
                Rf_setAttrib(ans, R_DimNamesSymbol, ind);
                UNPROTECT(1);
            }
        }
    }
    PROTECT(out = Rf_allocVector(VECSXP, 2));
    SET_VECTOR_ELT(out, 0, ans);
    SET_VECTOR_ELT(out, 1, Rf_ScalarLogical(sd0 != 0));
    UNPROTECT(nprotect + 1);
    return out;
}

/* ── approx (stats/src/approx.c, ApproxTest und Approx) ─────────────────────
 * x, y double (gleich lang, von der R-Seite aufbereitet); Rueckgabe yout oder Fehlertext. */
SEXP C_sl_r_approx(SEXP x, SEXP y, SEXP v, SEXP smethod, SEXP yleft, SEXP yright, SEXP sf, SEXP na_rm)
{
    SEXP xout, yout;
    R_xlen_t nx, nout, i;
    int method = Rf_asInteger(smethod), narm = Rf_asLogical(na_rm);
    double f = Rf_asReal(sf);
    const double *rx, *ry;
    need_real(x, "x");
    need_real(y, "y");
    nx = XLENGTH(x);
    if (XLENGTH(y) < nx) Rf_errorcall(R_NilValue, "interner Fehler: y kuerzer als x");
    rx = REAL(x); ry = REAL(y);
    switch (method) {   /* R_approxtest */
    case 1: break;
    case 2: if (!R_FINITE(f) || f < 0 || f > 1) return err_text("approx(): invalid f value", 0); break;
    default: return err_text("approx(): invalid interpolation method", 0);
    }
    if (narm) {
        for (i = 0; i < nx; i++)
            if (ISNAN(rx[i]) || ISNAN(ry[i])) return err_text("approx(): attempted to interpolate NA values", 0);
    } else {
        for (i = 0; i < nx; i++)
            if (ISNAN(rx[i])) return err_text("approx(x,y, .., na.rm=FALSE): NA values in x are not allowed", 0);
    }
    xout = PROTECT(Rf_coerceVector(v, REALSXP));
    nout = XLENGTH(xout);
    yout = PROTECT(Rf_allocVector(REALSXP, nout));
    sl_r_approx((int64_t) nx, rx, ry, (int64_t) nout, REAL(xout), method, Rf_asReal(yleft), Rf_asReal(yright), f,
                REAL(yout));
    UNPROTECT(2);
    return yout;
}

/* ── filter (stats/src/filter.c, cfilter und rfilter) ───────────────────────
 * Faltung: x, filter double; sides, circular wie cfilter. Rekursiv: init nf Startwerte in der Reihenfolge von
 * R (init[, i], neuester zuletzt; der Kern nimmt sie umgekehrt wie c(rev(init), ...) in rfilter). */
SEXP C_sl_r_cfilter(SEXP sx, SEXP sfilter, SEXP ssides, SEXP scircular)
{
    SEXP ans;
    int sides, circular;
    if (TYPEOF(sx) != REALSXP || TYPEOF(sfilter) != REALSXP) return err_text("invalid input", 0);
    sides = Rf_asInteger(ssides);
    circular = Rf_asLogical(scircular);
    if (sides == NA_INTEGER || circular == NA_LOGICAL) return err_text("invalid input", 0);
    PROTECT(ans = Rf_allocVector(REALSXP, XLENGTH(sx)));
    sl_r_filter_conv((int64_t) XLENGTH(sx), REAL(sx), (int64_t) XLENGTH(sfilter), REAL(sfilter), sides, circular,
                     REAL(ans));
    UNPROTECT(1);
    return ans;
}

SEXP C_sl_r_rfilter(SEXP x, SEXP filter, SEXP init)
{
    SEXP ans;
    R_xlen_t nf;
    if (TYPEOF(x) != REALSXP || TYPEOF(filter) != REALSXP) return err_text("invalid input", 0);
    nf = XLENGTH(filter);
    need_real(init, "init");
    if (XLENGTH(init) != nf) Rf_errorcall(R_NilValue, "interner Fehler: init passt nicht zum Filter");
    /* der Kern liest init[nf - 1 - j] als r[j], also wie c(rev(init[, i]), ...) in rfilter */
    PROTECT(ans = Rf_allocVector(REALSXP, XLENGTH(x)));
    if (sl_r_filter_rec((int64_t) XLENGTH(x), REAL(x), (int64_t) nf, REAL(filter), REAL(init), REAL(ans)) != 0) {
        UNPROTECT(1);
        Rf_errorcall(R_NilValue, "filter: kein Speicher");
    }
    UNPROTECT(1);
    return ans;
}

/* ── dist (stats/src/distance.c, Cdist und R_distance) ──────────────────────
 * Rueckgabe list(d, warn) oder Fehlertext; die Attribute setzt die R-Seite wie Cdist. */
SEXP C_sl_r_dist(SEXP x, SEXP smethod, SEXP sp)
{
    SEXP ans, out;
    int nr = Rf_nrows(x), nc = Rf_ncols(x), method = Rf_asInteger(smethod), warn = 0;
    double p = Rf_asReal(sp);
    R_xlen_t N = (R_xlen_t) nr * (nr - 1) / 2;
    if (method == 6) {
        if (!R_FINITE(p) || p <= 0) return err_text("distance(): invalid p", 0);
    } else if (method < 1 || method > 5) {
        return err_text("distance(): invalid distance", 0);
    }
    PROTECT(ans = Rf_allocVector(REALSXP, N));
    if (TYPEOF(x) != REALSXP) x = Rf_coerceVector(x, REALSXP);
    PROTECT(x);
    sl_r_dist((int64_t) nr, (int64_t) nc, REAL(x), method, p, REAL(ans), &warn);
    PROTECT(out = Rf_allocVector(VECSXP, 2));
    SET_VECTOR_ELT(out, 0, ans);
    SET_VECTOR_ELT(out, 1, Rf_ScalarLogical(warn != 0));
    UNPROTECT(3);
    return out;
}

/* ── hclust (stats/src/hclust.f, hclust und hcass2) ─────────────────────────
 * n >= 2, iopt 1-8, members und diss double ohne NA (geprueft von der R-Seite); Rueckgabe
 * list(merge (n-1) x 2 integer, height, order). */
SEXP C_sl_r_hclust(SEXP sn, SEXP siopt, SEXP members, SEXP diss)
{
    SEXP out, merge, height, order;
    int n = int1_strict(sn, "n"), iopt = int1_strict(siopt, "method"), st;
    int64_t *m64, *o64, i, len;
    if (n < 2) Rf_errorcall(R_NilValue, "interner Fehler: n < 2");
    len = (int64_t) n * (n - 1) / 2;
    need_real(members, "members");
    need_real(diss, "diss");
    if (XLENGTH(members) != n || XLENGTH(diss) < len)
        Rf_errorcall(R_NilValue, "interner Fehler: members bzw. diss passen nicht zu n");
    m64 = (int64_t *) R_alloc((size_t) 2 * (n - 1), sizeof(int64_t));
    o64 = (int64_t *) R_alloc((size_t) n, sizeof(int64_t));
    PROTECT(height = Rf_allocVector(REALSXP, n - 1));
    st = sl_r_hclust((int64_t) n, iopt, REAL(members), REAL(diss), m64, REAL(height), o64);
    if (st != 0) { UNPROTECT(1); Rf_errorcall(R_NilValue, "hclust: %s", st == SL_ENOMEM ? "kein Speicher" : "interner Fehler"); }
    PROTECT(merge = Rf_allocMatrix(INTSXP, n - 1, 2));
    for (i = 0; i < 2 * (int64_t) (n - 1); i++) INTEGER(merge)[i] = (int) m64[i];
    PROTECT(order = Rf_allocVector(INTSXP, n));
    for (i = 0; i < n; i++) INTEGER(order)[i] = (int) o64[i];
    PROTECT(out = Rf_allocVector(VECSXP, 3));
    SET_VECTOR_ELT(out, 0, merge);
    SET_VECTOR_ELT(out, 1, height);
    SET_VECTOR_ELT(out, 2, order);
    UNPROTECT(4);
    return out;
}

/* ── optimize (stats/src/optimize.c, do_fmin und fcn1; Verfahren Brent_fmin im Kern) ──
 * C_sl_fmin(fn, rho, xmin, xmax, tol, call, msg) seit 1.6.4 (T4-R5; bis dahin die Frage/Antwort-Schleife
 * C_sl_fmin_init/_next in R): xmin < xmax endlich und tol > 0 geprueft von der R-Seite (.sl_fmin, in der Reihenfolge von
 * do_fmin). Die Schleife ruft fn(x) wie fcn1 in rho; ungueltige Werte melden Warnung bzw. Fehler wie fcn1 mit dem
 * Aufruf call. Die Texte holt msg(i) erst im Bedarfsfall (i = 1: NA bei integer, 2: NA/Inf bei double, 3: ungueltiger
 * Wert; R's Uebersetzung mit gettext(domain = "stats")). Ein Fehler in fn verlaesst die Schleife per longjmp; das
 * Arbeitsfeld liegt auf dem Stapel. Ausnahme zu den Rueckmeldungen oben: Warnungen und Fehler hier direkt. */
static const char *fmin_msg(SEXP msg, int i, char *buf, size_t nb)
{
    SEXP e = PROTECT(Rf_lang2(msg, Rf_ScalarInteger(i)));
    SEXP r = PROTECT(Rf_eval(e, R_BaseEnv));
    buf[0] = 0;
    if (TYPEOF(r) == STRSXP && XLENGTH(r) == 1) {
        strncpy(buf, Rf_translateChar(STRING_ELT(r, 0)), nb - 1);
        buf[nb - 1] = 0;
    }
    UNPROTECT(2);
    return buf;
}

SEXP C_sl_fmin(SEXP fn, SEXP rho, SEXP xmin, SEXP xmax, SEXP tol, SEXP call, SEXP msg)
{
    double ws[SL_FMIN_WS], x;
    char buf[1024];
    SEXP fcall, s, sx;
    sl_fmin_init(ws, num1(xmin, "xmin"), num1(xmax, "xmax"), num1(tol, "tol"));
    PROTECT(fcall = Rf_lang2(fn, R_NilValue));
    while (sl_fmin_ask(ws, &x)) {
        double v = 0.0;
        PROTECT(sx = Rf_ScalarReal(x));
        SETCADR(fcall, sx);
        PROTECT(s = Rf_eval(fcall, rho));
        switch (TYPEOF(s)) {
        case INTSXP:
            if (XLENGTH(s) != 1) goto bad;
            if (INTEGER(s)[0] == NA_INTEGER) { Rf_warningcall(call, "%s", fmin_msg(msg, 1, buf, sizeof buf)); v = DBL_MAX; }
            else v = (double) INTEGER(s)[0];
            break;
        case REALSXP:
            if (XLENGTH(s) != 1) goto bad;
            if (!R_FINITE(REAL(s)[0])) { Rf_warningcall(call, "%s", fmin_msg(msg, 2, buf, sizeof buf)); v = DBL_MAX; }
            else v = REAL(s)[0];
            break;
        default:
            goto bad;
        }
        UNPROTECT(2);
        sl_fmin_tell(ws, v);
    }
    UNPROTECT(1);
    return Rf_ScalarReal(x);
bad:
    Rf_errorcall(call, "%s", fmin_msg(msg, 3, buf, sizeof buf));
    return R_NilValue;
}

}   /* extern "C" */
