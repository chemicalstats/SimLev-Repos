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
#include <stdlib.h>
#include <string.h>

#ifdef SLC_THREADS
#include <pthread.h>
#include <unistd.h>
#endif

/* ── Threads ── */

int sl_par_threads(int nthreads, int64_t n, int64_t min_per)
{
    int64_t nt = nthreads;
#ifdef SLC_THREADS
    if (nt <= 0) {
        long c = sysconf(_SC_NPROCESSORS_ONLN);
        nt = c < 1 ? 1 : (c > 8 ? 8 : c);
    }
#else
    nt = 1;
#endif
    if (nt > 64) nt = 64;
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
    if (nt > 64) nt = 64;
#ifdef SLC_THREADS
    {
        par_part part[64];
        pthread_t th[64];
        int ok[64];
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
    }
#else
    (void) t;
    fn(arg, 0, n, 0);
#endif
}

/* ── NaN-Regeln ── */

static inline double quiet_(double x)
{
    uint64_t b;
    memcpy(&b, &x, sizeof b);
    b |= UINT64_C(0x0008000000000000);
    memcpy(&x, &b, sizeof b);
    return x;
}
/* Ergebnis r von a op b mit der NaN-Regel von R auf x86-64: der linke NaN-Operand gewinnt (still gemacht) */
static inline double lnan_(double r, double a, double b)
{
    if (r == r) return r;
    if (a != a) return quiet_(a);
    if (b != b) return quiet_(b);
    return r;
}

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

/*
 * Teil:               civil_ (Datum aus Tagesnummer), days_ (Tagesnummer aus Datum), fdiv_
 * Herkunft:           übersetzt aus H. Hinnant, chrono-Compatible Low-Level Date Algorithms,
 *                     https://howardhinnant.github.io/date_algorithms.html (wie sl_r_civil_from_days in
 *                     slc_rbase_date.cpp, das nicht nach r/src/ geht)
 * Rechte:             gemeinfrei ("Consider these donated to the public domain.")
 * Lizenz der Vorlage: keine (gemeinfrei)
 * Änderungen:         int64_t mit Abrundungsdivision fdiv_ statt der Fallunterscheidung für negative Werte.
 */
static int64_t fdiv_(int64_t a, int64_t b)
{
    int64_t q = a / b;
    if ((a % b != 0) && ((a < 0) != (b < 0))) q--;
    return q;
}

static void civil_(int64_t z, int64_t *y, int *m, int *d)
{
    z += 719468;
    const int64_t era = fdiv_(z, 146097);
    const int64_t doe = z - era * 146097;
    const int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const int64_t mp = (5 * doy + 2) / 153;
    *d = (int) (doy - (153 * mp + 2) / 5 + 1);
    *m = (int) (mp < 10 ? mp + 3 : mp - 9);
    *y = yoe + era * 400 + (*m <= 2);
}

static int64_t days_(int64_t y, int m, int d)
{
    y -= m <= 2;
    const int64_t era = fdiv_(y, 400);
    const int64_t yoe = y - era * 400;
    const int64_t doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    const int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

int sl_mom_back(sl_ctx *cx, int64_t n, const double *d, int nlb, const int *lb, int64_t *back)
{
    int64_t i, y, y2, lo, hi, mid, first, nxt, len;
    int mon, mday, c, mo, mo2;
    double target;
    if (n < 0 || nlb < 0) return sl_fail(cx, SL_EARG, "mom_back: negative Länge");
    for (i = 0; i < n; i++) {
        if (!isfinite(d[i]) || fabs(d[i]) > 1e9) return sl_fail(cx, SL_EARG, "mom_back: Datum nicht endlich");
        if (i > 0 && d[i] < d[i - 1]) return sl_fail(cx, SL_EARG, "mom_back: Daten nicht sortiert");
    }
    for (i = 0; i < n; i++) {
        civil_((int64_t) floor(d[i]), &y, &mon, &mday);
        mon -= 1;                                          /* 0 ... 11 wie POSIXlt$mon */
        for (c = 0; c < nlb; c++) {
            mo = mon - lb[c];
            y2 = y + fdiv_(mo, 12);
            mo2 = (int) (mo - 12 * fdiv_(mo, 12));
            first = days_(y2, mo2 + 1, 1);
            nxt = days_(y2 + (mo2 + 1) / 12, (mo2 + 1) % 12 + 1, 1);
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
                    a = lnan_(a, x[i], x[k - 1]);
                    b = a - 1.0;
                    R[(int64_t) c * n + i] = lnan_(b, a, 1.0);
                } else R[(int64_t) c * n + i] = NA;
            }
        if (type == 1) {
            for (i = 0; i < n; i++) {
                r1 = 12.0 * R[i]; r1 = lnan_(r1, R[i], 12.0);
                r2 = 4.0 * R[n + i]; r2 = lnan_(r2, R[n + i], 4.0);
                r3 = 2.0 * R[2 * n + i]; r3 = lnan_(r3, R[2 * n + i], 2.0);
                r4 = R[3 * n + i];
                a = r1 + r2; a = lnan_(a, r1, r2);
                b = a + r3; b = lnan_(b, a, r3);
                a = b + r4; a = lnan_(a, b, r4);
                b = a / 4.0;
                S[j * n + i] = lnan_(b, a, 4.0);
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
