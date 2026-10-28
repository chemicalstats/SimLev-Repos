/* core/slc.h – öffentliche Schnittstelle der C-Bibliothek slc (SimLev core, Etappe 9)
 *
 * Verfahren:  siehe die Kerndateien slc_ctx.c (Kontext), slc_rng.c (Zufallsgenerator),
 *             slc_sample.c (Ziehungen), slc_normal.c (Normalverteilung), slc_special.c
 *             (lgamma, unvollständige Beta, t, logistisch); jede nennt ihre Quellen.
 * Quellen:    Entwurf SPEZ-9 (Abschnitte B.0–B.4, C.1–C.5); Literatur je Kerndatei.
 * Konstanten: core/slc_constants.h, erzeugt von core/tools/gen_constants.py.
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: R 4.3.3 (nur Plausibilität, scratchpad/e91/).
 *
 * Regeln (B.0):
 *   - reines C99, kein longjmp, kein exit, keine Ausgabe; kein globaler Zustand,
 *     alle Funktionen wiedereintrittsfähig;
 *   - Funktionen, die scheitern oder warnen können, nehmen sl_ctx * als erstes Argument und
 *     geben den Status zurück (SL_OK = 0); der Text steht in cx->msg, Warnungen in cx->warn
 *     (der Host gibt sie nach dem Aufruf in Reihenfolge aus);
 *   - Ausgabefelder legt der Host an; Längen int64_t; Indizes in Ergebnissen 1-basiert (int32_t);
 *   - elementweise Funktionen geben bei NaN-Eingabe die Eingabe selbst zurück (NA bleibt NA);
 *     ein ungültiger Parameter ergibt NaN und genau eine Warnung "<funktion>: NaN erzeugt";
 *   - nur double, kein fma (-ffp-contract=off), kein fast-math.
 *
 * Kanonischer Ort: core/. Kopien (tools/core_sync.py): r/src/, python/src/core/, julia/deps/core/.
 */
#ifndef SLC_H
#define SLC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SLC_VERSION "0.1.0"   /* Etappe 9.1 */

/* ── Kontext: Fehler, Warnungen, Abbruch (slc_ctx.c) ──────────────────────── */

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

void        sl_ctx_init(sl_ctx *cx);                 /* alles leer, interrupted = NULL */
sl_ctx     *sl_ctx_alloc(void);                      /* für Hosts ohne Kenntnis des Layouts */
void        sl_ctx_free(sl_ctx *cx);
void        sl_ctx_reset(sl_ctx *cx);                /* Status und Warnungen leeren */
int         sl_ctx_status(const sl_ctx *cx);
const char *sl_ctx_msg(const sl_ctx *cx);
int         sl_ctx_nwarn(const sl_ctx *cx);
const char *sl_ctx_warn(const sl_ctx *cx, int i);    /* i = 0 ... nwarn-1 */
int         sl_fail(sl_ctx *cx, int code, const char *fmt, ...);   /* setzt Status, gibt code */
void        sl_warn(sl_ctx *cx, const char *fmt, ...);             /* gleiche Texte nur einmal */
int         sl_interrupted(sl_ctx *cx);              /* 1 (und SL_EINTR) bei Benutzerabbruch */
const char *sl_version(void);

/* ── Zufallsgenerator xoshiro256** (slc_rng.c, B.1) ───────────────────────── */

typedef struct sl_rng { uint64_t s[4]; } sl_rng;     /* 32 Byte, Host-Bytereihenfolge */

uint64_t sl_splitmix64(uint64_t *x);                 /* nächste Ausgabe, x rückt um gamma vor */
void     sl_rng_seed(sl_rng *r, int64_t seed);       /* Zustand = 4 Ausgaben von SplitMix64(seed) */
void     sl_rng_seed_entropy(sl_rng *r, uint64_t t_ns, uint64_t pid, uint64_t counter);
uint64_t sl_rng_next(sl_rng *r);
void     sl_rng_jump(sl_rng *r);                     /* 2^128 Schritte weiter */
int      sl_rng_streams(sl_ctx *cx, const sl_rng *base, int64_t n, sl_rng *out); /* out[i] = J^(i+1)(base) */
int32_t  sl_rng_seed31(sl_rng *global);              /* nächster Startwert 0 ... 2^31-1: next() >> 33 */
double   sl_unif01(sl_rng *r);                       /* (floor(x / 2^11) + 1/2) 2^-53 in (0, 1) */
int      sl_runif(sl_ctx *cx, sl_rng *r, int64_t n, double a, double b, double *out);

/* ── Ziehungen (slc_sample.c, B.2) ─────────────────────────────────────────── */

int64_t sl_rint(sl_rng *r, int64_t n);               /* gleichverteilt in [0, n), n >= 1 */
int sl_sample(sl_ctx *cx, sl_rng *r, int64_t n, int64_t size, int replace,
              const double *prob /* NULL */, int32_t *out /* 1-basiert */);
int sl_rnorm(sl_ctx *cx, sl_rng *r, int64_t n, double mu, double sd, double *out);
int sl_rexp(sl_ctx *cx, sl_rng *r, int64_t n, double rate, double *out);
int sl_rgeom(sl_ctx *cx, sl_rng *r, int64_t n, double p, double *out);
int sl_rgamma(sl_ctx *cx, sl_rng *r, int64_t n, double shape, double scale, double *out);
int sl_rchisq(sl_ctx *cx, sl_rng *r, int64_t n, double df, double *out);

/* ── Normalverteilung (slc_normal.c, B.3) ─────────────────────────────────── */

double sl_erfc(double x);
double sl_pnorm1(double x, int lower);               /* Standardnormal, ein Wert */
double sl_qnorm1(double p, int lower);               /* Standardnormal, p in [0, 1] */
double sl_dnorm1(double x, int give_log);
int    sl_erfc_v(sl_ctx *cx, int64_t n, const double *x, double *out);
int    sl_pnorm(sl_ctx *cx, int64_t n, const double *x, double mu, double sd, int lower, double *out);
int    sl_qnorm(sl_ctx *cx, int64_t n, const double *p, double mu, double sd, int lower, double *out);
int    sl_dnorm(sl_ctx *cx, int64_t n, const double *x, double mu, double sd, int give_log, double *out);

/* ── lgamma, unvollständige Beta, t, logistisch (slc_special.c, B.4) ──────── */

double sl_lgamma1(double x);                         /* x > 0; sonst NaN */
int    sl_lgamma(sl_ctx *cx, int64_t n, const double *x, double *out);
int    sl_pbeta(sl_ctx *cx, int64_t n, const double *x, double a, double b, int lower, double *out);
int    sl_pt(sl_ctx *cx, int64_t n, const double *t, double df, int lower, double *out);
int    sl_qt(sl_ctx *cx, int64_t n, const double *p, double df, int lower, double *out);
int    sl_plogis(sl_ctx *cx, int64_t n, const double *x, double *out);
int    sl_qlogis(sl_ctx *cx, int64_t n, const double *p, double *out);

#ifdef __cplusplus
}
#endif

#include "slc_linalg.h"   /* 9.2: lineare Algebra, Matrixprodukt, kleinste Quadrate, Stineman, Spline, Kerndichte */

#endif /* SLC_H */

#include "slc_opt.h"   /* 9.3: Optimierer und numerischer Gradient */
#include "slc_models.h"   /* 9.4: Modelle (GARCH/GJR, GPD, DCC, MS-GARCH und HMM, Bootstrap-Kerne) */
