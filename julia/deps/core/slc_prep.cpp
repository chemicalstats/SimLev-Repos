/* core/slc_prep.cpp – Threads, Kalenderauffüllung von simulation(), Momentum-Scores (SimLev core, seit 1.6.0)
 * Verfahren:  Threads: n Elemente in nt zusammenhängende Teile, Teil 0 im aufrufenden Thread, die übrigen
 *               über POSIX-Threads (nur mit SLC_THREADS); jeder Teil schreibt nur seine Elemente.
 *             Kalenderauffüllung (bis 1.5.2: R merge() über die Datumsspalte, Python und Julia je eine
 *               Schleife): Zeile je Kalendertag über die ganzzahlige Tagesnummer, Spalten auf das Raster
 *               kopieren, fehlende Tage NA; Zahlen danach LOCF (NA und NaN fehlen; führende Lücken mit dem
 *               ersten Wert; nur fehlende Werte: unverändert), logische Werte NA -> FALSE bzw. TRUE (.filled).
 *             Momentum-Scores (bis 1.5.2 je Sprache): Rückblickzeile = Zahl der Tage am oder vor dem gleichen
 *               Kalendertag m Monate zuvor (auf das Monatsende begrenzt), ganzzahlig über den proleptisch
 *               gregorianischen Kalender; Renditen x / x[Rückblick] - 1 nach LOCF mit führenden NA;
 *               Mittel über die Rückblicke in long double wie rowMeans (sl_r_rowsums) bzw. gewichtet
 *               (12 r1 + 4 r2 + 2 r3 + r4) / 4.
 * Quellen:    IEEE 754-2008, Abschnitt 6.2 (NaN-Weitergabe); POSIX.1-2008 (pthread_create, pthread_join);
 *             Keller, W. J., Keuning, J. W. (2016). Breadth Momentum and the Canary Universe: Defensive Asset
 *               Allocation (DAA). SSRN 3212862 (Gewichte 12, 4, 2, 1).
 * Konstanten: keine.
 * Reinraum:   eigener SimLev-Code (Regeln von r/R/sim_prepare.R und r/R/tactical.R aus SimLev 1.5.2); kein
 *             Code aus R oder Paketen. Kalender: Teil-Block unten.
 * Prüforakel: R 1.5.2 (/home/claude/rlib152; Gleichlauf: prep_fuzz.R).
 */
#include "slc_internal.h"
#include "slc_prep.h"
#include "slc_rbase.h"
#include "slc_la_internal.h"

#include <limits.h>
#include <stdio.h>
#if defined(__linux__)
#include <dirent.h>
#include <signal.h>
#include <sys/prctl.h>
#include <unistd.h>
#endif
#include <stdlib.h>
#include <string.h>

#ifdef SLC_THREADS
#include <pthread.h>
#include <unistd.h>
#elif defined(_WIN32)
#include <windows.h>
#endif

/* ── Threads ── */

/* Zahl der logischen Prozessoren, die das System meldet (POSIX: sysconf(_SC_NPROCESSORS_ONLN), Windows:
 * GetSystemInfo), mindestens 1; Hoechstwert fuer Parallelitaet (cores der Funktionen, Threads der Kerne), eine Quelle
 * fuer R, Python und Julia (seit 1.6.4, Entscheidung 41b; bis 1.6.3 ohne SIMLEV_THREADS hoechstens 8 Threads, sonst bis
 * 64). */
int sl_nprocs(void)
{
    long c = 1;
#ifdef SLC_THREADS
    c = sysconf(_SC_NPROCESSORS_ONLN);
#elif defined(_WIN32)
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    c = (long) si.dwNumberOfProcessors;
#endif
    if (c < 1) c = 1;
    if (c > INT_MAX) c = INT_MAX;
    return (int) c;
}

/* Freier Arbeitsspeicher in Bytes, den das System meldet (seit 1.6.4, Planer fuer cores = "auto"): Linux
 * MemAvailable aus /proc/meminfo, sonst POSIX sysconf(_SC_AVPHYS_PAGES) * sysconf(_SC_PAGESIZE), Windows
 * GlobalMemoryStatusEx (ullAvailPhys); unbekannt: -1 (der Planer begrenzt dann nicht nach Speicher). */
double sl_mem_avail(void)
{
#if defined(_WIN32)
    MEMORYSTATUSEX ms;
    ms.dwLength = sizeof(ms);
    if (GlobalMemoryStatusEx(&ms)) return (double) ms.ullAvailPhys;
    return -1.0;
#else
    FILE *f = fopen("/proc/meminfo", "r");
    if (f != NULL) {
        char line[256];
        double kb = -1.0;
        while (fgets(line, (int) sizeof(line), f) != NULL) {
            if (strncmp(line, "MemAvailable:", 13) == 0) {
                char *e = NULL;
                double v = strtod(line + 13, &e);
                if (e != line + 13 && v >= 0) kb = v;
                break;
            }
        }
        fclose(f);
        if (kb >= 0) return kb * 1024.0;
    }
#if defined(_SC_AVPHYS_PAGES) && defined(_SC_PAGESIZE)
    {
        long pg = sysconf(_SC_AVPHYS_PAGES), sz = sysconf(_SC_PAGESIZE);
        if (pg > 0 && sz > 0) return (double) pg * (double) sz;
    }
#endif
    return -1.0;
#endif
}

/* Arbeitsspeicher des eigenen Prozesses in Bytes (resident; Linux /proc/self/statm), unbekannt -1 (seit 1.6.4, Planer
 * fuer cores = "auto": ein Fork kopiert beim Schreiben, was das Kind beruehrt, etwa bei der Speicherbereinigung). */
double sl_mem_self(void)
{
#if defined(_WIN32)
    return -1.0;
#else
    FILE *f = fopen("/proc/self/statm", "r");
    double size = -1, res = -1;
    long pg = 4096;
    if (f == NULL) return -1.0;
    if (fscanf(f, "%lf %lf", &size, &res) != 2) res = -1;
    fclose(f);
#if defined(_SC_PAGESIZE)
    pg = sysconf(_SC_PAGESIZE);
    if (pg <= 0) pg = 4096;
#endif
    return res >= 0 ? res * (double) pg : -1.0;
#endif
}

#if defined(__linux__)
/* Zustand (Feld 3), nice (Feld 19) und Zahl der Threads (Feld 20) aus /proc/.../stat (Felder 4 bis 17 als Woerter
 * uebersprungen, Feld 18 Prioritaet); 0: nicht lesbar */
static int sl_stat_fields(const char *path, char *state, long *nice, long *nthr)
{
    char buf[1024];
    const char *q;
    FILE *g = fopen(path, "r");
    int ok = 0;
    if (g == NULL) return 0;
    if (fgets(buf, (int) sizeof(buf), g) != NULL && (q = strrchr(buf, ')')) != NULL && q[1] == ' ') {
        long pr = 0;
        ok = sscanf(q + 2, "%c" "%*s %*s %*s %*s %*s %*s %*s %*s %*s %*s %*s %*s %*s %*s" " %ld %ld %ld",
                    state, &pr, nice, nthr) == 4;
    }
    fclose(g);
    return ok;
}

/* Laufende Threads anderer Prozesse mit niedrigerer Prioritaet als der eigene (nice groesser als das eigene; seit
 * 1.6.4, Entscheidung 139): je Prozess /proc/<pid>/stat, bei mehreren Threads /proc/<pid>/task/<tid>/stat (Zustand R).
 * Sichtbar sind nur die Prozesse des eigenen PID-Namensraums. */
static double sl_load_lower(void)
{
    char state;
    long own_nice, nthr;
    double low = 0;
    DIR *dir;
    struct dirent *e;
    long self = (long) getpid();
    if (!sl_stat_fields("/proc/self/stat", &state, &own_nice, &nthr)) return 0;
    dir = opendir("/proc");
    if (dir == NULL) return 0;
    while ((e = readdir(dir)) != NULL) {
        char path[96];
        long nice, pid;
        if (e->d_name[0] < '1' || e->d_name[0] > '9') continue;
        pid = strtol(e->d_name, NULL, 10);
        if (pid == self) continue;
        snprintf(path, sizeof(path), "/proc/%.20s/stat", e->d_name);
        if (!sl_stat_fields(path, &state, &nice, &nthr)) continue;
        if (nthr <= 1) {
            if (state == 'R' && nice > own_nice) low += 1;
            continue;
        }
        {   /* mehrere Threads: nice und Zustand je Thread */
            DIR *td;
            struct dirent *t;
            snprintf(path, sizeof(path), "/proc/%.20s/task", e->d_name);
            td = opendir(path);
            if (td == NULL) continue;
            while ((t = readdir(td)) != NULL) {
                char tp[128];
                long tn, tt;
                char ts;
                if (t->d_name[0] < '1' || t->d_name[0] > '9') continue;
                snprintf(tp, sizeof(tp), "/proc/%.20s/task/%.20s/stat", e->d_name, t->d_name);
                if (sl_stat_fields(tp, &ts, &tn, &tt) && ts == 'R' && tn > own_nice) low += 1;
            }
            closedir(td);
        }
    }
    closedir(dir);
    return low;
}
#endif

/* Laufende Prozesse laut System einschliesslich des eigenen (seit 1.6.4, Entscheidung 112): Linux /proc/loadavg
 * (viertes Feld "laufend/gesamt", Zahl vor dem Schraegstrich; laufende Threads des eigenen Prozesses zaehlen als einer;
 * seit Entscheidung 139 zaehlen laufende Threads anderer Prozesse mit niedrigerer Prioritaet, also groesserem nice als
 * der eigene Prozess, nicht mit, gleich und hoeher priorisierte weiter voll),
 * macOS getloadavg() (Mittel der letzten Minute,
 * gerundet); sonst (Windows) unbekannt: -1 (der Planer rechnet dann nur mit der Zahl der Prozessoren). Testschalter
 * (nicht oeffentlich): SIMLEV_TEST_RUNNING (ASCII-Ziffern) ersetzt die Angabe des Systems. */
double sl_load_running(void)
{
    /* Testschalter (nicht oeffentlich): SIMLEV_TEST_RUNNING = ASCII-Ziffern ersetzt die Angabe des Systems */
    const char *t = getenv("SIMLEV_TEST_RUNNING");
    if (t != NULL && *t != '\0') {
        const char *q = t;
        double v = 0;
        while (*q >= '0' && *q <= '9') { v = v * 10 + (*q - '0'); q++; }
        if (*q == '\0' && q - t <= 9) return v;
    }
    {
#if defined(__linux__)
    FILE *f = fopen("/proc/loadavg", "r");
    double a1, a5, a15, run = -1, tot, own = 0;
    DIR *dir;
    if (f == NULL) return -1.0;
    if (fscanf(f, "%lf %lf %lf %lf/%lf", &a1, &a5, &a15, &run, &tot) != 5) run = -1;
    fclose(f);
    if (run < 0) return -1.0;
    /* eigene laufende Threads (Zustand R in /proc/self/task/<tid>/stat, etwa noch wartende BLAS-Threads) zaehlen
     * zusammen als ein Prozess */
    dir = opendir("/proc/self/task");
    if (dir != NULL) {
        struct dirent *e;
        while ((e = readdir(dir)) != NULL) {
            char path[64], buf[512];
            FILE *g;
            if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
            snprintf(path, sizeof(path), "/proc/self/task/%.20s/stat", e->d_name);
            g = fopen(path, "r");
            if (g == NULL) continue;
            if (fgets(buf, (int) sizeof(buf), g) != NULL) {
                const char *q = strrchr(buf, ')');
                if (q != NULL && q[1] == ' ' && q[2] == 'R') own += 1;
            }
            fclose(g);
        }
        closedir(dir);
    }
    if (own > 1) run -= own - 1;
    run -= sl_load_lower();                         /* seit Entscheidung 139: niedriger priorisierte zaehlen nicht */
    return run >= 1 ? run : 1.0;
#elif defined(__APPLE__)
    double la[1];
    if (getloadavg(la, 1) == 1 && la[0] >= 0) return (double) (int64_t) (la[0] + 0.5);
    return -1.0;
#else
    return -1.0;
#endif
    }
}

/* Schutz eines Kindprozesses (Fork der Huellen R und Python; seit 1.6.4, K43 T2-B4): unter Linux erhaelt das Kind
 * SIGTERM, wenn der Elternprozess endet (PR_SET_PDEATHSIG), auch nach einem harten Ende (SIGKILL); endete er schon
 * zwischen Fork und Aufruf (getppid() ist nicht mehr parent_pid), beendet sich das Kind sofort mit SIGTERM. Sonst
 * (macOS, Windows) ohne Wirkung. Rueckgabe 1 mit Schutz, 0 ohne. */
int sl_child_guard(long parent_pid)
{
#if defined(__linux__)
    if (prctl(PR_SET_PDEATHSIG, SIGTERM) != 0) return 0;
    if ((long) getppid() != parent_pid) kill(getpid(), SIGTERM);
    return 1;
#else
    (void) parent_pid;
    return 0;
#endif
}

/* Freie Prozessoren (seit 1.6.4, Entscheidung 112): max(1, nprocs - (running - 1)); der eigene Prozess zaehlt in
 * running mit und wird abgezogen; running < 0 (unbekannt): nprocs. */
int sl_par_free(int nprocs, double running)
{
    double fr;
    if (nprocs < 1) nprocs = 1;
    if (!(running >= 0) || !(running < 1e15)) return nprocs;
    fr = (double) nprocs - (running > 1 ? running - 1 : 0);
    if (fr < 1) fr = 1;
    return fr > nprocs ? nprocs : (int) fr;
}

/* Planer fuer cores = "auto" (seit 1.6.4, Entscheidungen 41b/41c): Kosten je System, gemessen am 08.11.2026 auf der
 * Entwicklungsmaschine (Linux x86-64, 2 logische Prozessoren, 7 GB, ein zweiter Agent rechnete nebenher; Messskripte
 * und Absolutzeiten im Bericht des Pakets K42 PAR):
 *   fork_s    Start eines Kinds (R: Fork mit mcparallel/mccollect je Paket, 25 ms fuer 4 Forks bei kleinem Speicher;
 *             Python: Prozess mit Pipe, 6-10 ms; Julia: Task, 0,07 ms), aus synthetischen Einheiten (2/10/50 ms, 8 und
 *             32 Einheiten, 2 Laeufe gegen nacheinander),
 *   fork_b    Zusatz je Byte des eigenen Prozesses (sl_mem_self): Fork, Speicherbereinigung im Kind und Ende bei
 *             71/126/331/872 MB (R: 0,044/0,066/0,100/0,216 s, Steigung 0,215 ms je MB) bzw. 30/84/277/758 MB (Python:
 *             0,013/0,026/0,101/0,313 s, 0,41 ms je MB); Julia ohne Fork 0,
 *   unit_s    Zusatz je Einheit (Mitschnitt der Ausgaben: R 0,044 ms; Auftrag ueber die Pipe: Python 0,02 ms; Channel:
 *             Julia 0,0013 ms),
 *   byte_s    Ruecktransport je Byte des Ergebnisses (1 MB aus einem Fork: R 3 ms, Python 2 ms; Julia ohne Transport),
 *   mem0,     privater Arbeitsspeicher eines Kinds: mem0 + mem_b * eigener Prozess (R: 42/62/99/227 MB bei den Groessen
 *   mem_b     oben, also etwa 26 MB + 0,23; Python 8/15/46/122 MB, etwa 3 MB + 0,16; Julia: Task im selben Prozess, 0),
 *   packs     Pakete (R: Forks) je Lauf.
 * Der Plan haengt nur von diesen Kosten, der gemessenen Rechenzeit je Einheit und den Grenzen ab, nie das Ergebnis
 * (die Einheiten sind unabhaengig; Strom je Einheit). Seit Entscheidung 112 zaehlen nur freie Prozessoren
 * (sl_par_free: Zahl der Prozessoren minus andere laufende Prozesse laut sl_load_running). */
typedef struct { double fork_s, fork_b, unit_s, byte_s, mem0, mem_b; int packs; } sl_par_cost;
static const sl_par_cost SL_PAR_COST[3] = {
    /* 0 R (Unix, Fork) */      { 6.0e-3, 0.215e-9, 5.0e-5, 3.0e-9, 26.0e6, 0.23, 2 },
    /* 1 Python (Fork) */       { 8.0e-3, 0.41e-9,  2.0e-5, 2.0e-9,  3.0e6, 0.16, 1 },
    /* 2 Julia (Task) */        { 7.0e-5, 0.0,      1.3e-6, 0.0,     0.0,   0.0,  1 },
};

/* Start eines weiteren Laufs in Sekunden bei self_bytes Bytes im eigenen Prozess (< 0: unbekannt, wie 0) */
static double par_start(const sl_par_cost *k, double self_bytes)
{
    if (!(self_bytes > 0) || !(self_bytes < 1e300)) self_bytes = 0;
    return (double) k->packs * (k->fork_s + k->fork_b * self_bytes);
}

double sl_par_probe(int sys, double self_bytes)
{
    return (sys < 0 || sys > 2) ? 0.0 : par_start(&SL_PAR_COST[sys], self_bytes);
}

int sl_par_plan(int sys, int nprocs, int max_runs, int env_threads, int64_t n, double unit_s, double unit_bytes,
                double mem_avail, double self_bytes, double running, int *threads)
{
    const sl_par_cost *k;
    int64_t cmax, c, best = 1;
    double t1, tbest, start, mem_run;
    int pfree;
    if (nprocs < 1) nprocs = 1;
    pfree = sl_par_free(nprocs, running);
    if (env_threads > nprocs) env_threads = nprocs;
    if (threads != NULL) *threads = env_threads >= 1 ? env_threads : nprocs;   /* ein Lauf: alle Prozessoren */
    if (sys < 0 || sys > 2 || n < 2 || !(unit_s > 0) || !(unit_s < 1e300)) return 1;
    if (!(unit_bytes >= 0) || !(unit_bytes < 1e300)) unit_bytes = 0;
    if (!(self_bytes > 0) || !(self_bytes < 1e300)) self_bytes = 0;
    k = &SL_PAR_COST[sys];
    start = par_start(k, self_bytes);
    mem_run = k->mem0 + k->mem_b * self_bytes;
    cmax = pfree;                                             /* Laeufe <= freie Prozessoren (41c, 112) */
    if (max_runs < cmax) cmax = max_runs;
    if (n < cmax) cmax = n;
    for (c = 2; c <= cmax; c++) {                             /* Speicher: alle Laeufe zusammen <= frei */
        int64_t per = (n + k->packs * c - 1) / (k->packs * c);        /* Einheiten je Paket */
        double need = (double) c * (mem_run + 2.0 * unit_bytes * (double) per);
        if (mem_avail >= 0 && need > mem_avail) { cmax = c - 1; break; }
    }
    t1 = (double) n * unit_s;
    tbest = t1;
    for (c = 2; c <= cmax; c++) {                             /* geschaetzte Laufzeit, kleinstes c bei Gleichstand */
        double t = (double) c * start
                 + (double) ((n + c - 1) / c) * (unit_s + k->unit_s + unit_bytes * k->byte_s);
        if (t < tbest) { tbest = t; best = c; }
    }
    if (threads != NULL && best > 1) {                        /* Kern-Threads je Lauf: P frei / c, mindestens 1 */
        int t = pfree / (int) best;
        if (t < 1) t = 1;
        if (env_threads >= 1 && env_threads < t) t = env_threads;
        *threads = t;
    }
    return (int) best;
}

int sl_par_threads(int nthreads, int64_t n, int64_t min_per)
{
    int64_t nt = nthreads;
#ifdef SLC_THREADS
    /* nthreads <= 0: Hoechstwert; mehr als der Hoechstwert (die Sprachen begrenzen schon, mit Hinweis):
     * Sicherheitsgrenze (seit 1.6.4, Entscheidung 41b) */
    {
        int64_t mx = sl_nprocs();
        if (nt <= 0 || nt > mx) nt = mx;
    }
#else
    nt = 1;
#endif
    if (min_per < 1) min_per = 1;
    if (nt > n / min_per) nt = n / min_per;
    return nt < 1 ? 1 : (int) nt;
}

typedef struct {
    sl_range_fn fn;
    void *arg;
    int64_t lo, hi;
    int part;
} par_part;

#ifdef SLC_THREADS
static void *par_thread(void *p)
{
    par_part *q = (par_part *) p;
    q->fn(q->arg, q->lo, q->hi, q->part);
    return NULL;
}
#endif

void sl_par_run(int nt, int64_t n, sl_range_fn fn, void *arg)
{
    int t;
    if (nt <= 1 || n <= 1) { fn(arg, 0, n, 0); return; }
#ifdef SLC_THREADS
    {
        /* Felder je Aufruf (seit 1.6.4 ohne die feste Grenze 64); ohne Speicher nacheinander */
        par_part *part = (par_part *) malloc((size_t) nt * sizeof(par_part));
        pthread_t *th = (pthread_t *) malloc((size_t) nt * sizeof(pthread_t));
        int *ok = (int *) malloc((size_t) nt * sizeof(int));
        if (part == NULL || th == NULL || ok == NULL) {
            free(part); free(th); free(ok);
            fn(arg, 0, n, 0);
            return;
        }
        for (t = 0; t < nt; t++) {
            part[t].fn = fn; part[t].arg = arg; part[t].part = t;
            part[t].lo = (int64_t) ((__int128) n * t / nt);
            part[t].hi = (int64_t) ((__int128) n * (t + 1) / nt);
        }
        for (t = 1; t < nt; t++) ok[t] = pthread_create(&th[t], NULL, par_thread, &part[t]) == 0;
        fn(arg, part[0].lo, part[0].hi, 0);
        for (t = 1; t < nt; t++) {
            if (ok[t]) pthread_join(th[t], NULL);
            else fn(arg, part[t].lo, part[t].hi, t);     /* Thread nicht gestartet: hier rechnen */
        }
        free(part); free(th); free(ok);
    }
#else
    (void) t;
    fn(arg, 0, n, 0);
#endif
}

/* ── NaN-Regeln: slc_lnan (slc_internal.h; Ergebnis r von a op b, der linke NaN-Operand gewinnt, still gemacht) ── */

/* ── Kalenderauffüllung ── */

int sl_cal_index(sl_ctx *cx, int64_t n, const double *day, double d0, int64_t nd, int64_t *src)
{
    int64_t i, j;
    if (n < 0 || nd < 0) return sl_fail(cx, SL_EARG, "cal_index: negative Länge");
    for (j = 0; j < nd; j++) src[j] = -1;
    for (i = 0; i < n; i++) {
        double z = day[i] - d0;
        if (!(z >= 0 && z < (double) nd)) continue;
        j = (int64_t) z;
        if ((double) j == z) src[j] = i;
    }
    return SL_OK;
}

void sl_cal_fill_real(int64_t nd, const int64_t *src, const double *x, int locf, double *out)
{
    const double na = slc_na_real();
    int64_t j, first = -1, last;
    for (j = 0; j < nd; j++) out[j] = src[j] >= 0 ? x[src[j]] : na;
    if (!locf) return;
    for (j = 0; j < nd && first < 0; j++) if (!isnan(out[j])) first = j;
    if (first < 0) return;                                  /* nur fehlende Werte: unverändert */
    last = first;
    for (j = 0; j < nd; j++) {
        if (!isnan(out[j])) last = j;
        else out[j] = out[last];                            /* führende Lücken: last = first */
    }
}

void sl_cal_fill_int(int64_t nd, const int64_t *src, const int *x, int mode, int fill, int *out)
{
    int64_t j, first = -1, last;
    for (j = 0; j < nd; j++) out[j] = src[j] >= 0 ? x[src[j]] : INT_MIN;
    if (mode == 2) {
        for (j = 0; j < nd; j++) if (out[j] == INT_MIN) out[j] = fill;
        return;
    }
    if (mode != 1) return;
    for (j = 0; j < nd && first < 0; j++) if (out[j] != INT_MIN) first = j;
    if (first < 0) return;
    last = first;
    for (j = 0; j < nd; j++) {
        if (out[j] != INT_MIN) last = j;
        else out[j] = out[last];
    }
}

/* ── Momentum-Scores ── */

/* Kalender: sl_r_civil_from_days, sl_r_days_from_civil, sl_r_fdiv (slc_rbase.h/.cpp; seit 1.6.3 statt Kopie) */

int sl_mom_back(sl_ctx *cx, int64_t n, const double *d, int nlb, const int *lb, int64_t *back)
{
    int64_t i, y, y2, lo, hi, mid, first, nxt, len;
    int mon, mday, c, mo, mo2;
    double target;
    if (n < 0 || nlb < 0) return sl_fail(cx, SL_EARG, "mom_back: negative Länge");
    /* seit 1.6.4 (C-019): Rueckblicke im Bereich +-1200000 Monate (bis 1.6.3 lief mon - lb in int ueber und lieferte
     * still Leerwerte); momentum_score prueft vorher 1 ... 1200 */
    for (c = 0; c < nlb; c++)
        if (lb[c] < -1200000 || lb[c] > 1200000) return sl_fail(cx, SL_EARG, "mom_back: Rückblick außerhalb des Bereichs");
    for (i = 0; i < n; i++) {
        if (!isfinite(d[i]) || fabs(d[i]) > 1e9) return sl_fail(cx, SL_EARG, "mom_back: Datum nicht endlich");
        if (i > 0 && d[i] < d[i - 1]) return sl_fail(cx, SL_EARG, "mom_back: Daten nicht sortiert");
    }
    for (i = 0; i < n; i++) {
        sl_r_civil_from_days((int64_t) floor(d[i]), &y, &mon, &mday);
        mon -= 1;                                          /* 0 ... 11 wie POSIXlt$mon */
        for (c = 0; c < nlb; c++) {
            mo = mon - lb[c];
            y2 = y + sl_r_fdiv(mo, 12);
            mo2 = (int) (mo - 12 * sl_r_fdiv(mo, 12));
            first = sl_r_days_from_civil(y2, mo2 + 1, 1);
            nxt = sl_r_days_from_civil(y2 + (mo2 + 1) / 12, (mo2 + 1) % 12 + 1, 1);
            len = nxt - first;
            target = (double) (first + (mday < len ? mday : len) - 1);
            lo = 0; hi = n;                                /* Zahl der d[j] <= target */
            while (lo < hi) {
                mid = lo + (hi - lo) / 2;
                if (d[mid] <= target) lo = mid + 1; else hi = mid;
            }
            back[(int64_t) c * n + i] = lo;
        }
    }
    return SL_OK;
}

/* LOCF mit führenden NA wie .fill_na(v, "locf", keep_leading = TRUE) */
static void locf_lead_(int64_t n, const double *v, double *out)
{
    int64_t i, first = -1, last, cnt = 0;
    for (i = 0; i < n; i++) if (!isnan(v[i])) { if (first < 0) first = i; cnt++; }
    if (cnt == 0 || cnt == n) { memcpy(out, v, sizeof(double) * (size_t) n); return; }
    last = first;
    for (i = 0; i < n; i++) {
        if (!isnan(v[i])) last = i;
        out[i] = v[last];
    }
    for (i = 0; i < first; i++) out[i] = slc_na_real();
}

int sl_mom_score(sl_ctx *cx, int64_t n, int64_t na, const double *X, int nlb, const int64_t *back, int type,
                 double *S)
{
    const double NA = slc_na_real();
    double *x = NULL, *R = NULL, r1, r2, r3, r4, a, b;
    int64_t i, j, k;
    int c, st = SL_OK;
    if (n < 0 || na < 0 || nlb < 1) return sl_fail(cx, SL_EARG, "mom_score: ungültige Größen");
    if (type == 1 && nlb != 4) return sl_fail(cx, SL_EARG, "mom_score: 13612w verlangt vier Rückblicke");
    x = (double *) malloc(sizeof(double) * (size_t) (n > 0 ? n : 1));
    R = (double *) malloc(sizeof(double) * (size_t) (n > 0 ? n : 1) * (size_t) nlb);
    if (!x || !R) { st = sl_fail(cx, SL_ENOMEM, "mom_score: kein Speicher"); goto done; }
    for (j = 0; j < na; j++) {
        locf_lead_(n, X + j * n, x);
        for (c = 0; c < nlb; c++)
            for (i = 0; i < n; i++) {
                k = back[(int64_t) c * n + i];
                if (k > 0) {
                    a = x[i] / x[k - 1];
                    a = slc_lnan(a, x[i], x[k - 1]);
                    b = a - 1.0;
                    R[(int64_t) c * n + i] = slc_lnan(b, a, 1.0);
                } else R[(int64_t) c * n + i] = NA;
            }
        if (type == 1) {
            for (i = 0; i < n; i++) {
                r1 = 12.0 * R[i]; r1 = slc_lnan(r1, R[i], 12.0);
                r2 = 4.0 * R[n + i]; r2 = slc_lnan(r2, R[n + i], 4.0);
                r3 = 2.0 * R[2 * n + i]; r3 = slc_lnan(r3, R[2 * n + i], 2.0);
                r4 = R[3 * n + i];
                a = r1 + r2; a = slc_lnan(a, r1, r2);
                b = a + r3; b = slc_lnan(b, a, r3);
                a = b + r4; a = slc_lnan(a, b, r4);
                b = a / 4.0;
                S[j * n + i] = slc_lnan(b, a, 4.0);
            }
        } else {
            st = sl_r_rowsums(n, nlb, R, 0, 1, S + j * n);
            if (st != SL_OK) { st = sl_fail(cx, SL_ENOMEM, "mom_score: kein Speicher"); goto done; }
        }
        if (sl_interrupted(cx)) { st = SL_EINTR; goto done; }
    }
done:
    free(x); free(R);
    return st;
}
