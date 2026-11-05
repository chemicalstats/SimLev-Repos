/* core/slc.h – öffentliche Schnittstelle (C-ABI) der Bibliothek slc (SimLev core)
 *
 * Verfahren:  siehe die Kerndateien slc_ctx.cpp (Kontext), slc_rng.cpp (Zufallsgenerator),
 *             slc_sample.cpp (Ziehungen), slc_normal.cpp (Normalverteilung), slc_special.cpp
 *             (lgamma, unvollständige Beta, t, logistisch); jede nennt ihre Quellen.
 * Quellen:    Literatur je Kerndatei.
 * Konstanten: core/slc_constants.h, erzeugt von core/gen_constants.py.
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: R 4.3.3 (nur Plausibilität).
 *
 * Regeln:
 *   - C++17 (gnu++17, seit 1.6.0; bis 1.5.2 C99) im gemeinsamen Teil von C und C++: keine Klassen,
 *     keine Ausnahmen, Schnittstelle mit C-Bindung (extern "C"); kein longjmp, kein exit, keine
 *     Ausgabe; kein globaler Zustand, alle Funktionen wiedereintrittsfähig;
 *   - Funktionen, die scheitern oder warnen können, nehmen sl_ctx * als erstes Argument und
 *     geben den Status zurück (SL_OK = 0); der Text steht in cx->msg, Warnungen in cx->warn
 *     (der Host gibt sie nach dem Aufruf in Reihenfolge aus);
 *   - Ausgabefelder legt der Host an; Längen int64_t; Indizes in Ergebnissen 1-basiert (int32_t);
 *   - elementweise Funktionen geben bei NaN-Eingabe die Eingabe selbst zurück (NA bleibt NA);
 *     ein ungültiger Parameter ergibt NaN und genau eine Warnung "<funktion>: NaN erzeugt";
 *   - nur double, kein fma (-ffp-contract=off), kein fast-math.
 *
 * Kanonischer Ort: core/. Kopien (core/sync.py): r/src/, python/src/core/, julia/deps/core/.
 */
#ifndef SLC_H
#define SLC_H

#include <stddef.h>
#include <stdint.h>

/* C++ (seit 1.6.0): Die Funktionen von slc werfen nie (C-Regeln, kein longjmp). SL_NOTHROW sagt das dem
 * Übersetzer; ohne die Angabe legt g++ an jedem Aufruf über Dateigrenzen Ausnahmepfade an und ordnet heiße
 * Schleifen anders (gemessen: MS-GARCH-Fit in Julia 7 % langsamer). Ändert weder Bindung noch ABI. */
#ifndef SL_NOTHROW
#if defined(__cplusplus) && (defined(__GNUC__) || defined(__clang__))
#define SL_NOTHROW __attribute__((nothrow))
#else
#define SL_NOTHROW
#endif
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define SLC_VERSION "0.1.0"

/* ── Kontext: Fehler, Warnungen, Abbruch (slc_ctx.cpp) ──────────────────────── */

#define SL_MSG_LEN 512
#define SL_WARN_MAX 8
#define SL_WARN_LEN 256

typedef struct sl_ctx {
    int    status;                      /* 0 = ok, sonst SL_E* */
    char   msg[SL_MSG_LEN];             /* Fehlertext, UTF-8, deutsch */
    int    n_warn;                      /* gesammelte Warnungen (höchstens SL_WARN_MAX) */
    char   warn[SL_WARN_MAX][SL_WARN_LEN];
    int  (*interrupted)(void *host);    /* NULL oder != 0 bei Benutzerabbruch */
    void  *host;
} sl_ctx;

enum { SL_OK = 0, SL_EARG = 1, SL_ENONFINITE = 2, SL_ENOTPD = 3, SL_ESINGULAR = 4,
       SL_ECONV = 5, SL_EINTR = 6, SL_ENOMEM = 7, SL_ESMALL = 8 };

void        sl_ctx_init(sl_ctx *cx) SL_NOTHROW;                 /* alles leer, interrupted = NULL */
sl_ctx     *sl_ctx_alloc(void) SL_NOTHROW;                      /* für Hosts ohne Kenntnis des Layouts */
void        sl_ctx_free(sl_ctx *cx) SL_NOTHROW;
const char *sl_ctx_msg(const sl_ctx *cx) SL_NOTHROW;
int         sl_ctx_nwarn(const sl_ctx *cx) SL_NOTHROW;
const char *sl_ctx_warn(const sl_ctx *cx, int i) SL_NOTHROW;    /* i = 0 ... nwarn-1 */
int         sl_fail(sl_ctx *cx, int code, const char *fmt, ...) SL_NOTHROW;   /* setzt Status, gibt code */
void        sl_warn(sl_ctx *cx, const char *fmt, ...) SL_NOTHROW;             /* gleiche Texte nur einmal */
int         sl_interrupted(sl_ctx *cx) SL_NOTHROW;              /* 1 (und SL_EINTR) bei Benutzerabbruch */
const char *sl_version(void) SL_NOTHROW;

/* ── Zufallsgenerator xoshiro256** (slc_rng.cpp) ───────────────────────── */

typedef struct sl_rng { uint64_t s[4]; } sl_rng;     /* 32 Byte, Host-Bytereihenfolge */

uint64_t sl_splitmix64(uint64_t *x) SL_NOTHROW;                 /* nächste Ausgabe, x rückt um gamma vor */
void     sl_rng_seed(sl_rng *r, int64_t seed) SL_NOTHROW;       /* Zustand = 4 Ausgaben von SplitMix64(seed) */
void     sl_rng_seed_entropy(sl_rng *r, uint64_t t_ns, uint64_t pid, uint64_t counter) SL_NOTHROW;
uint64_t sl_rng_next(sl_rng *r) SL_NOTHROW;
void     sl_rng_jump(sl_rng *r) SL_NOTHROW;                     /* 2^128 Schritte weiter */
int      sl_rng_streams(sl_ctx *cx, const sl_rng *base, int64_t n, sl_rng *out) SL_NOTHROW; /* out[i] = J^(i+1)(base) */
int32_t  sl_rng_seed31(sl_rng *global) SL_NOTHROW;              /* nächster Startwert 0 ... 2^31-1: next() >> 33 */
double   sl_unif01(sl_rng *r) SL_NOTHROW;                       /* (floor(x / 2^11) + 1/2) 2^-53 in (0, 1) */
int      sl_runif(sl_ctx *cx, sl_rng *r, int64_t n, double a, double b, double *out) SL_NOTHROW;

/* ── Ziehungen (slc_sample.cpp) ─────────────────────────────────────────── */

int64_t sl_rint(sl_rng *r, int64_t n) SL_NOTHROW;               /* gleichverteilt in [0, n), n >= 1 */
int sl_sample(sl_ctx *cx, sl_rng *r, int64_t n, int64_t size, int replace,
              const double *prob /* NULL */, int32_t *out /* 1-basiert */) SL_NOTHROW;
int sl_rnorm(sl_ctx *cx, sl_rng *r, int64_t n, double mu, double sd, double *out) SL_NOTHROW;
int sl_rexp(sl_ctx *cx, sl_rng *r, int64_t n, double rate, double *out) SL_NOTHROW;
int sl_rgeom(sl_ctx *cx, sl_rng *r, int64_t n, double p, double *out) SL_NOTHROW;
int sl_rgamma(sl_ctx *cx, sl_rng *r, int64_t n, double shape, double scale, double *out) SL_NOTHROW;
int sl_rchisq(sl_ctx *cx, sl_rng *r, int64_t n, double df, double *out) SL_NOTHROW;

/* ── Normalverteilung (slc_normal.cpp) ─────────────────────────────────── */

double sl_erfc(double x) SL_NOTHROW;
double sl_pnorm1(double x, int lower) SL_NOTHROW;               /* Standardnormal, ein Wert */
double sl_qnorm1(double p, int lower) SL_NOTHROW;               /* Standardnormal, p in [0, 1] */
double sl_dnorm1(double x, int give_log) SL_NOTHROW;
int    sl_erfc_v(sl_ctx *cx, int64_t n, const double *x, double *out) SL_NOTHROW;
int    sl_pnorm(sl_ctx *cx, int64_t n, const double *x, double mu, double sd, int lower, double *out) SL_NOTHROW;
int    sl_qnorm(sl_ctx *cx, int64_t n, const double *p, double mu, double sd, int lower, double *out) SL_NOTHROW;
int    sl_dnorm(sl_ctx *cx, int64_t n, const double *x, double mu, double sd, int give_log, double *out) SL_NOTHROW;

/* ── lgamma, unvollständige Beta, t, logistisch (slc_special.cpp) ──────── */

int    sl_lgamma(sl_ctx *cx, int64_t n, const double *x, double *out) SL_NOTHROW;
int    sl_pbeta(sl_ctx *cx, int64_t n, const double *x, double a, double b, int lower, double *out) SL_NOTHROW;
int    sl_pt(sl_ctx *cx, int64_t n, const double *t, double df, int lower, double *out) SL_NOTHROW;
int    sl_qt(sl_ctx *cx, int64_t n, const double *p, double df, int lower, double *out) SL_NOTHROW;
int    sl_plogis(sl_ctx *cx, int64_t n, const double *x, double *out) SL_NOTHROW;
int    sl_qlogis(sl_ctx *cx, int64_t n, const double *p, double *out) SL_NOTHROW;

#ifdef __cplusplus
}
#endif

#include "slc_linalg.h"   /* lineare Algebra, Matrixprodukt, kleinste Quadrate, Stineman, Spline, Kerndichte */

#endif /* SLC_H */

#include "slc_opt.h"   /* Optimierer und numerischer Gradient */
#include "slc_models.h"   /* Modelle (GARCH/GJR, GPD, DCC, MS-GARCH und HMM, Bootstrap-Kerne) */
