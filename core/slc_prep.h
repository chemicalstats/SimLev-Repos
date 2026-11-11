/* core/slc_prep.h – Kerne für Wirtsfunktionen großer Fälle (SimLev core, seit 1.6.0)
 * Zweck:      Rechenarbeit, die bis 1.5.2 jede Sprache selbst erledigte (R, Python, Julia je eine Fassung), in
 *             einem Kern: Kalenderauffüllung von simulation() (slc_prep.cpp), Momentum-Scores
 *             (slc_prep.cpp), Pfadaufbau im Bootstrap (slc_bootpath.cpp), qt/pt elementweise auf mehreren
 *             Threads (slc_special.cpp, eigener Abschnitt) und die Profil-Likelihood der t-Copula
 *             (slc_tcop.cpp). Eingabeprüfung, Meldungen und Ergebnisobjekte bleiben in den Sprachen.
 * Bitgleich:  Die Kerne rechnen dieselben Operationen in derselben Reihenfolge wie R 1.5.2 (Summen,
 *             Mittel und Kumulationen über slc_rbase.cpp in long double wie R); bei zwei NaN-Operanden
 *             gewinnt wie in R der linke (Hilfen in slc_prep.cpp und slc_bootpath.cpp).
 * Threads:    nthreads <= 0: Höchstwert sl_nprocs() = Zahl der Prozessoren, mindestens 1 (seit 1.6.4, Entscheidung 41b;
 *             bis 1.6.3 Zahl der Prozessoren, höchstens 8); mehr wird auf den Höchstwert begrenzt; 1: nacheinander. Nur mit SLC_THREADS
 *             übersetzt (alle Builds außer Windows), sonst nacheinander. Das Ergebnis hängt nicht von der
 *             Zahl der Threads ab (jedes Element unabhängig, Warnungen als Vereinigung der Merker).
 */
#ifndef SLC_PREP_H
#define SLC_PREP_H

#include <stdint.h>

#include "slc.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ── Threads (slc_prep.cpp) ─────────────────────────────────────────────────
 * Zahl der logischen Prozessoren (mindestens 1) = Höchstwert für Parallelität (seit 1.6.4, eine Quelle für cores und
 * Threads in R, Python und Julia). */
int  sl_nprocs(void) SL_NOTHROW;
/* Zahl der Threads für n Elemente: nthreads <= 0 oder größer als sl_nprocs(): sl_nprocs(); höchstens n / min_per
 * Threads (mindestens 1). */
int  sl_par_threads(int nthreads, int64_t n, int64_t min_per) SL_NOTHROW;
/* Freier Arbeitsspeicher in Bytes laut System (Linux MemAvailable), unbekannt -1 (seit 1.6.4). */
double sl_mem_avail(void) SL_NOTHROW;
/* Arbeitsspeicher des eigenen Prozesses in Bytes (resident, Linux /proc/self/statm), unbekannt -1 (seit 1.6.4). */
double sl_mem_self(void) SL_NOTHROW;
/* Laufende Prozesse laut System einschliesslich des eigenen (Linux /proc/loadavg ohne laufende Threads anderer Prozesse
 * mit groesserem nice, Entscheidung 139; macOS getloadavg), unbekannt -1, und
 * freie Prozessoren max(1, nprocs - (running - 1)) (running < 0: nprocs) (seit 1.6.4, Entscheidung 112). */
double sl_load_running(void) SL_NOTHROW;
int  sl_par_free(int nprocs, double running) SL_NOTHROW;
/* Kindprozess nach dem Fork schuetzen (seit 1.6.4, K43 T2-B4): Linux PR_SET_PDEATHSIG = SIGTERM, beim Ende des
 * Elternprozesses parent_pid endet das Kind; 1 mit Schutz, 0 ohne (macOS, Windows). */
int  sl_child_guard(long parent_pid) SL_NOTHROW;
/* Messzeit vor dem Plan: die Huellen rechnen Einheiten nacheinander, bis so viel Zeit vergangen ist (Start eines weiteren
 * Laufs des Systems sys in Sekunden bei self_bytes Bytes im eigenen Prozess), und planen dann den Rest (seit 1.6.4). */
double sl_par_probe(int sys, double self_bytes) SL_NOTHROW;
/* Planer fuer cores = "auto" (seit 1.6.4, Entscheidungen 41b/41c): Zahl der Laeufe c (Rueckgabe, 1 ... min(nprocs,
 * max_runs, n)) und Kern-Threads je Lauf (*threads) fuer n weitere Einheiten mit gemessener Rechenzeit unit_s (Sekunden)
 * und Ergebnisgroesse unit_bytes je Einheit; sys: 0 R (Fork), 1 Python (Fork-Prozess), 2 Julia (Task); self_bytes:
 * Arbeitsspeicher des eigenen Prozesses (sl_mem_self; Start und Speicher eines Forks wachsen damit); running: laufende
 * Prozesse einschliesslich des eigenen (sl_load_running; < 0 unbekannt), c hoechstens sl_par_free(nprocs, running). Waehlt das
 * kleinste c mit der kuerzesten geschaetzten Laufzeit c * Start + ceil(n / c) * (unit_s + Zusatz je Einheit), c = 1,
 * wenn kein c > 1 schneller ist; alle Laeufe zusammen hoechstens mem_avail Bytes (mem_avail < 0: ohne Grenze).
 * Threads: c = 1: env_threads (>= 1, hoechstens nprocs), sonst nprocs; c > 1: freie Prozessoren / c, mindestens 1, hoechstens
 * env_threads. nprocs und running sind Argumente (Probe der Regel fuer andere Rechnergroessen und Fremdlast); die
 * Huellen geben sl_nprocs() und sl_load_running(). */
int  sl_par_plan(int sys, int nprocs, int max_runs, int env_threads, int64_t n, double unit_s, double unit_bytes,
                 double mem_avail, double self_bytes, double running, int *threads) SL_NOTHROW;
/* fn(arg, lo, hi, part) für nt zusammenhängende Teile part = 0 ... nt-1 von [0, n) (Teil 0 im aufrufenden Thread) */
typedef void (*sl_range_fn)(void *arg, int64_t lo, int64_t hi, int part);
void sl_par_run(int nt, int64_t n, sl_range_fn fn, void *arg) SL_NOTHROW;

/* ── Kalenderauffüllung von simulation() (slc_prep.cpp) ─────────────────────
 * day: n ganzzahlige Tagesnummern; src[j] (j = 0 ... nd-1, Tag d0 + j) = Zeile i (0-basiert) mit day[i] = d0 + j,
 * sonst -1 (doppelte Tage: die letzte Zeile). */
int  sl_cal_index(sl_ctx *cx, int64_t n, const double *day, double d0, int64_t nd, int64_t *src) SL_NOTHROW;
/* Spalte auf das Raster: out[j] = x[src[j]], fehlend NA_real_; locf != 0: danach LOCF mit R's Regeln von
 * .locf_fill (NA und NaN gelten als fehlend, führende Lücken mit dem ersten Wert, nur NA: unverändert) */
void sl_cal_fill_real(int64_t nd, const int64_t *src, const double *x, int locf, double *out) SL_NOTHROW;
/* ganze Zahlen und logische Werte (NA = INT_MIN): mode 0 fehlend NA; 1 danach LOCF; 2 fehlend und NA -> fill */
void sl_cal_fill_int(int64_t nd, const int64_t *src, const int *x, int mode, int fill, int *out) SL_NOTHROW;

/* ── Momentum-Scores (slc_prep.cpp) ─────────────────────────────────────────
 * d: n Tagesnummern, aufsteigend (nicht fallend), endlich; lb: nlb Rückblicke in ganzen Monaten.
 * back (n × nlb, spaltenweise): Zahl der Tage d[i] <= Ziel (findInterval), Ziel = gleicher Tag m Monate zuvor,
 * auf das Monatsende begrenzt. */
int  sl_mom_back(sl_ctx *cx, int64_t n, const double *d, int nlb, const int *lb, int64_t *back) SL_NOTHROW;
/* X: n × na Kurse (spaltenweise); je Spalte LOCF mit führenden NA (wie .fill_na(, "locf", keep_leading = TRUE)),
 * Renditen x / x[back] - 1 (back = 0: NA), Score: type 0 Zeilenmittel (rowMeans), 1 (12 r1 + 4 r2 + 2 r3 + r4) / 4
 * (verlangt nlb = 4). S: n × na. */
int  sl_mom_score(sl_ctx *cx, int64_t n, int64_t na, const double *X, int nlb, const int64_t *back, int type,
                  double *S) SL_NOTHROW;

/* ── Pfadaufbau im Bootstrap (slc_bootpath.cpp) ───────────────────────────── */
typedef struct sl_letf {
    int    base;             /* Spalte der Indexrenditen (0-basiert) */
    double L;                /* Hebel */
    int    rate_col;         /* Zusatzspalte der Finanzierung (0-basiert) oder -1: rate */
    double rate;
    int    days_col;         /* Zusatzspalte der Tage oder -1: days */
    double days;
    double rate_basis, ter_basis, expense, spread;
} sl_letf;
/* ret: n_out × k Renditen (spaltenweise); idx: n_out Quellzeilen (1-basiert) der Zusatzreihen aux (n_aux × na);
 * aux_ratio: NULL oder n_aux × na; aux_start: NULL oder na Werte (sonst aux[1, ] / aux_ratio[1, ]); level: na
 * Merker. P: (n_out + 1) × (k + nL + na); lv: NULL oder (n_out + 1) × na (Niveau-Variante, falls aux_ratio).
 * Rückgabe 1 = gültiger Pfad, 0 = ungültig (Rendite nicht endlich oder <= 0, Hebelrendite nicht endlich),
 * sonst Fehlerstatus < 0 (-SL_EARG). */
int  sl_boot_path(sl_ctx *cx, int64_t n_out, int k, const double *ret, const int64_t *idx, int64_t n_aux, int na,
                  const double *aux, const double *aux_ratio, const double *aux_start, const int *level, int nL,
                  const sl_letf *letf, double start, double *P, double *lv) SL_NOTHROW;
/* wie sl_boot_path mit ret = src[idx, ] (seit 1.6.3): src n_src × k mit Element (r, j) bei src[r rs + j cs], idx
 * n_out Zeilen (1-basiert, 1..n_src) für Renditen und Zusatzreihen; Ergebnis Bit für Bit wie sl_boot_path auf der
 * Kopie. */
int  sl_boot_path_src(sl_ctx *cx, int64_t n_out, int k, const double *src, int64_t n_src, int64_t rs, int64_t cs,
                      const int64_t *idx, int64_t n_aux, int na, const double *aux, const double *aux_ratio,
                      const double *aux_start, const int *level, int nL, const sl_letf *letf, double start, double *P,
                      double *lv) SL_NOTHROW;

/* ── t-Verteilung auf mehreren Threads (slc_special.cpp) ──────────────────── */
int  sl_pt_mt(sl_ctx *cx, int64_t n, const double *t, double df, int lower, double *out, int nthreads) SL_NOTHROW;
int  sl_qt_mt(sl_ctx *cx, int64_t n, const double *p, double df, int lower, double *out, int nthreads) SL_NOTHROW;

/* ── t-Copula (slc_tcop.cpp) ────────────────────────────────────────────────
 * Profil-Likelihood in nu wie .cop_fit_t (R 1.5.2): best = (atanh rho, nu, -loglik). *flag = 1, wenn eine
 * Auswertung nicht endlich war oder der Kontext Warnungen sammelte (dann rechnet der Host wie bisher). */
int  sl_tcop_fit(sl_ctx *cx, int64_t n, const double *u, const double *v, int nthreads, double *best,
                 int *flag) SL_NOTHROW;
/* nu der t-Copula von scenario_copula: optimize(-ll_t, c(lower, upper), tol); U Tn × k Pseudo-Beobachtungen,
 * Ri = R^-1 (k × k), ldR = log det R. *flag wie oben. */
int  sl_tcop_nu(sl_ctx *cx, int64_t Tn, int k, const double *U, const double *Ri, double ldR, double lower,
                double upper, double tol, int nthreads, double *nu, int *flag) SL_NOTHROW;

#ifdef __cplusplus
}
#endif

#endif /* SLC_PREP_H */
