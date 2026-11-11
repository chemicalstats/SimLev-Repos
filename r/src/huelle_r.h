/*
 * src/huelle_r.h -- gemeinsame Hilfen der R-Huellen (.Call) der C-Bibliothek slc (seit 1.6.3)
 *
 * Bis 1.6.2 stand jede dieser Funktionen wortgleich in mehreren Huellen (slc_r.cpp, prep_r.cpp,
 * slc_r_linalg.cpp, slc_r_models.cpp, slc_r_opt.cpp). Einbinden innerhalb von extern "C" { ... }, nach
 * R.h, Rinternals.h, string.h und slc.h. Der Name beginnt bewusst nicht mit "slc": core/sync.py haelt
 * slc*-Dateien in r/src/ ohne Gegenstueck in core/ fuer veraltete Kernkopien.
 *
 * Rueckmeldungen: der Kern springt nie; finish() gibt die gesammelten Warnungen in Reihenfolge mit
 * Rf_warningcall(R_NilValue, ...) aus (wie warning(call. = FALSE)) und einen Fehler mit
 * Rf_errorcall(R_NilValue, ...) (wie stop(call. = FALSE)). Benutzerabbruch: Rueckruf ueber R_ToplevelExec
 * (kein longjmp im Kern); bei SL_EINTR danach Rf_onintr() (seit 1.6.5; bis 1.6.4 R_CheckUserInterrupt(), das
 * nichts mehr fand, dann der Fehler "Benutzerabbruch").
 */
#ifndef SIMLEV_HUELLE_R_H
#define SIMLEV_HUELLE_R_H

/* ── Kontext und Rueckmeldungen ── */

/* Rinterface.h (nur Unix) deklariert Rf_onintr; wie simlev_capi.h hier selbst deklariert */
void Rf_onintr(void);

static inline void chk_int(void *d) { (void) d; R_CheckUserInterrupt(); }
static inline int r_interrupted(void *h) { (void) h; return !R_ToplevelExec(chk_int, NULL); }

static inline void ctx_init(sl_ctx *cx)
{
    sl_ctx_init(cx);
    cx->interrupted = r_interrupted;
}

/* Warnungen ausgeben, bei Fehler abbrechen (nprot Schutzstufen vorher freigeben) */
static inline void finish(sl_ctx *cx, int st, int nprot)
{
    int i;
    char msg[SL_MSG_LEN];
    for (i = 0; i < cx->n_warn; i++) Rf_warningcall(R_NilValue, "%s", cx->warn[i]);
    if (st != SL_OK) {
        memcpy(msg, cx->msg, SL_MSG_LEN);
        if (nprot) UNPROTECT(nprot);
        /* seit 1.6.5 (C-033, Entscheidung 171): R_ToplevelExec hat den Abbruch verbraucht; eine echte Unterbrechung
         * (Bedingung interrupt) statt des Fehlers "Benutzerabbruch", den tryCatch(error = ) verschluckte */
        if (st == SL_EINTR) Rf_onintr();
        Rf_errorcall(R_NilValue, "%s", msg);
    }
}

/* ── Argumente (interne Fehler: die R-Seite uebergibt passende Typen) ── */

static inline void get_state(SEXP s, sl_rng *r)
{
    if (TYPEOF(s) != RAWSXP || XLENGTH(s) != 32)
        Rf_errorcall(R_NilValue, "interner Fehler: Zufallszustand muss raw(32) sein");
    memcpy(r->s, RAW(s), 32);
}

static inline double num1(SEXP x, const char *what)
{
    if (TYPEOF(x) != REALSXP || XLENGTH(x) != 1)
        Rf_errorcall(R_NilValue, "interner Fehler: %s muss eine Zahl (double, Laenge 1) sein", what);
    return REAL(x)[0];
}

static inline int lgl1(SEXP x, const char *what)
{
    if (TYPEOF(x) != LGLSXP || XLENGTH(x) != 1 || LOGICAL(x)[0] == NA_LOGICAL)
        Rf_errorcall(R_NilValue, "interner Fehler: %s muss TRUE oder FALSE sein", what);
    return LOGICAL(x)[0];
}

static inline void need_real(SEXP x, const char *what)
{
    if (TYPEOF(x) != REALSXP) Rf_errorcall(R_NilValue, "interner Fehler: %s muss double sein", what);
}

/* integer der Laenge 1 ohne NA (seit 1.6.4 hier; bis 1.6.3 wortgleich als int1 in slc_r_opt.cpp und i1 in
 * slc_r_models.cpp; prep_r.cpp und slc_r_linalg.cpp haben eigene int1 mit anderen Regeln) */
static inline int int1_strict(SEXP x, const char *what)
{
    if (TYPEOF(x) != INTSXP || XLENGTH(x) != 1 || INTEGER(x)[0] == NA_INTEGER)
        Rf_errorcall(R_NilValue, "interner Fehler: %s muss eine ganze Zahl (integer, Laenge 1) sein", what);
    return INTEGER(x)[0];
}

/* Zufallszustand als raw(32) bzw. Paar list(Ergebnis, Zustand) (seit 1.6.4 hier; bis 1.6.3 in slc_r.cpp und
 * gleichwertig in slc_r_models.cpp) */
static inline SEXP new_state(const sl_rng *r)
{
    SEXP s = PROTECT(Rf_allocVector(RAWSXP, 32));
    memcpy(RAW(s), r->s, 32);
    UNPROTECT(1);
    return s;
}

static inline SEXP pair(SEXP a, const sl_rng *r)
{
    SEXP out = PROTECT(Rf_allocVector(VECSXP, 2));
    SET_VECTOR_ELT(out, 0, a);
    SET_VECTOR_ELT(out, 1, new_state(r));
    UNPROTECT(1);
    return out;
}

#endif
