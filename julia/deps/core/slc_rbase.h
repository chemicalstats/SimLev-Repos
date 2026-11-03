/* core/slc_rbase.h – Grundfunktionen mit R-Regeln für Python und Julia (SimLev core, N8)
 * Verfahren:  siehe slc_rbase.c (Summen, Mittel, Varianz, Kumulationen, Potenz in long double bzw.
 *             double wie R), slc_rbase_sort.c (Ordnung, Rang, partielle Sortierung, Quantile Typ 1–9,
 *             tabulate, findInterval) und slc_rbase_cov.c (cov/cor: pearson, kendall; spearman über
 *             die Ränge im Host), slc_rbase_date.c (Datumsformat und -lesen, N10),
 *             slc_rbase_num.c (R_strtod, %%, %/%, scientific() in long double, N10).
 * Zweck:      Python (simlev._ext) und Julia (ccall auf libslc) bildeten diese Grundfunktionen von R
 *             je für sich nach (python/simlev/_r/, julia/src/r/); seit N8 rechnen beide mit diesen
 *             Kernen. R selbst behält seine Grundfunktionen (Entscheidung 9.0 (4)); nur slc_rbase.c und
 *             diese Datei gehen seit E17 auch nach r/src/ (Summen der Tagesengine, seit Stufe 3 die
 *             Auswertung evaluate_core_impl.h mit sl_r_zeroin2); nicht von slc.h eingebunden.
 * long double: Anders als die SimLev-eigenen Kerne (seit N5 ohne long double) akkumulieren diese
 *             Kerne dort in long double, wo R es tut (sum, prod, mean, var, cumsum, cumprod,
 *             rowSums/colSums, cov/cor). Bitgleich zu R sind sie damit nur auf derselben Plattform mit
 *             demselben Compiler (hier x86-64 Linux, gcc: long double = x87 80 Bit; R und slc mit
 *             -O2 -ffp-contract=off). Auf Plattformen, deren long double 64 oder 128 Bit breit ist,
 *             rechnet R dort ebenso mit diesem Typ; die Kerne bleiben korrekt, die Bitgleichheit
 *             folgt dann aus demselben Typ.
 * NA:         R's NA_real_ ist das NaN mit Nutzlast 1954 (0x7FF00000000007A2), R's NaN das ruhige
 *             0x7FF8000000000000. Die Kerne unterscheiden beide wie R.
 * Herkunft:           übersetzt aus R 4.3.3 über die Port-Funktionen
 *                     python/simlev/_r/{rnum,base,stats_sort,stats_cor}.py und
 *                     julia/src/r/{rnum,base,stats_sort,stats_cor}.jl (diese nach
 *                     src/main/summary.c, cum.c, array.c, arithmetic.c, sort.c, qsort-body.c,
 *                     util.c, format.c und src/library/stats/src/cov.c, zeroin.c); Verhalten laut
 *                     R-Hilfeseiten (?sum, ?mean, ?cumsum, ?quantile, ?order, ?rank, ?sort, ?cor,
 *                     ?tabulate, ?findInterval, ?Arithmetic); Einzelheiten in den Köpfen der
 *                     .c-Dateien
 * Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation
 *                     (laut Kopf der jeweiligen R-Quelle)
 * Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
 * Änderungen:         C99 ohne R-Datenstrukturen, gemeinsamer Kern für Python und Julia (nicht Teil
 *                     des R-Pakets).
 * Prüforakel: R 4.3.3 (Gleichlauf: rbase_fuzz.R, ≥ 10.000 Fälle je Kern).
 */
#ifndef SLC_RBASE_H
#define SLC_RBASE_H

#include <stdint.h>

#include "slc.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ── slc_rbase.c: Summen und Kumulationen ────────────────────────────────────
 * narm: NaN/NA auslassen. Leere Eingaben: sum 0, prod 1, mean NaN, var NA. */
double sl_r_sum(int64_t n, const double *x, int narm);
double sl_r_prod(int64_t n, const double *x, int narm);
double sl_r_mean(int64_t n, const double *x);                 /* mean(x) für Doubles */
double sl_r_mean_int(int64_t n, const int64_t *x);            /* mean(x) für ganze Zahlen */
double sl_r_var(int64_t n, const double *x);                  /* var(x) ohne NA; n <= 1: NA */
void   sl_r_cumsum(int64_t n, const double *x, double *out);
void   sl_r_cumprod(int64_t n, const double *x, double *out);
void   sl_r_cummax(int64_t n, const double *x, double *out);
void   sl_r_cummin(int64_t n, const double *x, double *out);
/* x: nr × nc spaltenweise; mean: Mittel statt Summe; out: nc (colSums) bzw. nr (rowSums) */
void   sl_r_colsums(int64_t nr, int64_t nc, const double *x, int narm, int mean, double *out);
int    sl_r_rowsums(int64_t nr, int64_t nc, const double *x, int narm, int mean, double *out);
/* x ^ y elementweise (R's Operator ^ für Doubles); y mit Länge 1 */
void   sl_r_pow(int64_t n, const double *x, double y, double *out);
double sl_r_pow1(double x, double y);
/* Nullstelle nach Brent wie R_zeroin2 (stats::uniroot, E17 Stufe 3): f im Intervall [ax, bx] mit den
 * Funktionswerten fa, fb (Vorzeichenwechsel vom Aufrufer geprüft), Toleranz tol, höchstens maxit Schritte.
 * Rückgabe die Näherung; *iter die Zahl der Schritte, -1 ohne Konvergenz. f rechnet der Aufrufer (bei
 * uniroot mit der Ersetzung nicht endlicher Werte durch ±DBL_MAX und deren Warnungen). */
typedef double (*sl_r_fn1)(double x, void *info);
double sl_r_zeroin2(sl_r_fn1 f, void *info, double ax, double bx, double fa, double fb, double tol, int maxit,
                    int *iter);

/* ── slc_rbase_sort.c: Ordnung, Rang, Quantile ───────────────────────────────
 * Rückgabe 0 oder SL_ENOMEM. Indizes 1-basiert wie R. */
/* order(k_1, ..., k_nkey, na.last, decreasing) für Zahlenschlüssel (stabil, -0 == 0, NA und NaN als
 * fehlend): keys nkey Spalten der Länge n; nalast 1 = hinten, 0 = vorne, -1 = entfernen;
 * out: n Plätze, *nout: Anzahl Ergebnisse */
int    sl_r_order(int64_t n, int nkey, const double *keys, const int *decreasing, int nalast,
                  int64_t *out, int64_t *nout);
/* rank(x, ties.method) für x ohne NA: ties 0 average, 1 first, 2 last, 3 min, 4 max */
int    sl_r_rank(int64_t n, const double *x, int ties, double *out);
/* sort(x, partial = k) an Ort und Stelle für x ohne NA; k 1-basiert (1 <= k <= n) */
int    sl_r_psort(int64_t n, double *x, int64_t nk, const int64_t *k);
/* quantile(x, probs, type) für x ohne NA; p: auf [0, 1] begrenzte Wahrscheinlichkeiten oder NaN
 * (Ergebnis dann p); type 1–9 */
int    sl_r_quantile(int64_t n, const double *x, int64_t np, const double *p, int type, double *out);
/* tabulate(bin, nbins): bin ganzzahlig abgeschnitten, NaN ignoriert */
void   sl_r_tabulate(int64_t n, const double *bin, int64_t nbins, int64_t *out);
/* findInterval(x, vec, rightmost.closed, all.inside, left.open); vec aufsteigend ohne NA;
 * out double (NA für NA/NaN in x) */
void   sl_r_findinterval(int64_t nv, const double *vec, int64_t nx, const double *x,
                         int rightmost_closed, int all_inside, int left_open, double *out);

/* ── slc_rbase_cov.c: cov/cor ────────────────────────────────────────────────
 * x: n × ncx, y: n × ncy oder NULL (dann ncy = ncx), spaltenweise; use 1 all.obs, 2 complete.obs,
 * 3 pairwise.complete.obs, 4 everything, 5 na.or.complete; kendall, cor 0/1; ans ncx × ncy
 * spaltenweise; *sd0 = 1, wenn eine Standardabweichung null ist (Warnung des Hosts). Fehlertexte
 * wie R ("missing observations in cov/cor", "no complete element pairs") mit SL_EARG. */
int    sl_r_cov(sl_ctx *cx, int64_t n, int64_t ncx, const double *x, int64_t ncy, const double *y,
                int use, int kendall, int cor, double *ans, int *sd0);

/* ── slc_rbase_num.c: weitere long-double-Rechenwege (N10) ──────────────────
 * sl_r_strtod_num: Zahlteil von R_strtod ab s (nach Vorzeichen): *used = gelesene Bytes (-1: keine
 * Ziffer, NA), *gt_max = Betrag > DBL_MAX in long double. sl_r_fmod_ld/sl_r_idiv_ld: long-double-Teil
 * von %% und %/% (endliche Operanden). sl_r_scientific: scientific() von formatReal für r > 0 endlich,
 * 1 <= digits <= 15; Rückgabe "roundingwidens". */
double  sl_r_strtod_num(const char *s, int64_t len, int64_t *used, int *gt_max);
double  sl_r_fmod_ld(double x1, double x2);
double  sl_r_idiv_ld(double x1, double x2);
int     sl_r_scientific(double r, int digits, int *kpower, int *nsig);

/* ── slc_rbase_date.c: Datum (N10) ───────────────────────────────────────────
 * Tage seit 1970-01-01, proleptisch gregorianisch. sl_r_strftime: format.Date(z, fmt) in der C-Locale
 * (Schalter, Breiten, E/O wie glibc unter Linux; digits_secs = getOption("digits.secs") für %OS ohne Ziffer,
 * nicht gesetzt 0) nach buf (höchstens cap Bytes, ohne abschließende 0); Rückgabe die volle Länge (höchstens
 * 2048; cap >= 2048 genügt immer), -1 bei |z| >= 1e14 (NA), -2 bei mehr als 2048 Bytes (Fehler wie R:
 * "output string exceeded 2048 bytes"), -3 ohne Speicher. sl_r_strptime_ymd: as.Date(s, format =
 * "%Y<sep>%m<sep>%d"); 1 = gelesen (*z), 0 = NA. */
void    sl_r_civil_from_days(int64_t z, int64_t *y, int *m, int *d);
int64_t sl_r_days_from_civil(int64_t y, int m, int d);
int64_t sl_r_strftime(int64_t z, const char *fmt, int64_t flen, int digits_secs, char *buf, int64_t cap);
int     sl_r_strptime_ymd(const char *s, int64_t len, int sep, int64_t *z);

#ifdef __cplusplus
}
#endif

#endif /* SLC_RBASE_H */
