// tests/werkzeuge/kern/t_threads.cpp – Kernprobe sl_pt_mt/sl_qt_mt mit vorgetäuschter Prozessorzahl (seit 1.6.4, T4-R1)
//
// Bis zur Behebung hielt t_mt die Merker der Teile in festen Feldern für 64 Threads: ab 65 Threads (Rechner mit mehr
// als 64 logischen Prozessoren, ab 65 · 512 Werten) kam eine falsche Warnung „Kettenbruch nicht konvergiert“, ab 69
// Threads las t_mt hinter der Struktur. Die Probe täuscht die Prozessorzahl über --wrap=sysconf vor (Umgebung
// FAKE_NPROCS) und vergleicht sl_pt_mt/sl_qt_mt mit sl_pt/sl_qt auf einem Thread, bitweise und in den Warnungen
// (72 Fälle: n, df, lower, pt/qt, ungültiges p bzw. NaN nur im letzten Teil). Erwartet: 0 Abweichungen bei jeder Zahl.
//
// Aus der Repo-Wurzel (Schalter wie die Pakete; -fsanitize=address für die Speicherprobe):
//   g++ -std=gnu++17 -O2 -ffp-contract=off -fno-fast-math -DSLC_THREADS=1 -Icore tests/werkzeuge/kern/t_threads.cpp \
//       core/*.cpp -Wl,--wrap=sysconf -lpthread -o /tmp/t_threads
//   for p in 1 2 64 65 69 130 256; do FAKE_NPROCS=$p /tmp/t_threads; done
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "slc.h"
#include "slc_prep.h"

extern "C" long __real_sysconf(int);
extern "C" long __wrap_sysconf(int name)
{
    if (name == _SC_NPROCESSORS_ONLN) {
        const char *e = getenv("FAKE_NPROCS");
        if (e) return atol(e);
    }
    return __real_sysconf(name);
}

static unsigned long long st = 88172645463325252ULL;
static double u01(void) { st ^= st << 13; st ^= st >> 7; st ^= st << 17; return (double) (st >> 11) * 0x1p-53; }

static void warns(sl_ctx *c, char *b, size_t nb)
{
    b[0] = 0;
    for (int i = 0; i < c->n_warn; i++) {
        strncat(b, c->warn[i], nb - strlen(b) - 2);
        strncat(b, "|", nb - strlen(b) - 1);
    }
}

int main(void)
{
    const int64_t ns[] = {65 * 512, 200 * 512 + 17, 300000};
    const double dfs[] = {0.7, 3.7, 30.0};
    int bad = 0, tot = 0;
    for (int in = 0; in < 3; in++) for (int idf = 0; idf < 3; idf++) for (int lower = 0; lower < 2; lower++)
    for (int kind = 0; kind < 4; kind++) {
        int64_t n = ns[in];
        int qt = kind >= 2;
        double *x = (double *) malloc(n * 8), *a = (double *) malloc(n * 8), *b = (double *) malloc(n * 8);
        for (int64_t i = 0; i < n; i++) x[i] = qt ? u01() : (u01() - 0.5) * 40;
        if (!qt) { x[0] = 0.0; x[1] = -0.0; x[2] = INFINITY; x[3] = -INFINITY; x[4] = NAN; x[5] = 1e300; x[6] = -5e-324; }
        else { x[0] = 0.0; x[1] = -0.0; x[2] = 1.0; x[3] = NAN; x[4] = 5e-324; x[5] = 1 - 0x1p-53; }
        if (kind == 3) x[n - 1] = 1.5;            /* ungültiges p nur im letzten Teil */
        if (kind == 1) x[n - 1] = NAN;
        sl_ctx c1, c2;
        char w1[4096], w2[4096];
        sl_ctx_init(&c1); sl_ctx_init(&c2);
        if (qt) { sl_qt(&c1, n, x, dfs[idf], lower, a); sl_qt_mt(&c2, n, x, dfs[idf], lower, b, 0); }
        else { sl_pt(&c1, n, x, dfs[idf], lower, a); sl_pt_mt(&c2, n, x, dfs[idf], lower, b, 0); }
        warns(&c1, w1, sizeof w1); warns(&c2, w2, sizeof w2);
        int same = memcmp(a, b, n * 8) == 0, sw = strcmp(w1, w2) == 0;
        tot++;
        if (!same || !sw) {
            bad++;
            if (bad <= 6)
                printf("  ABW n=%lld df=%g lower=%d %s kind=%d Bits %s, Warnungen [%s] / [%s]\n", (long long) n,
                       dfs[idf], lower, qt ? "qt" : "pt", kind, same ? "gleich" : "VERSCHIEDEN", w1, w2);
        }
        free(x); free(a); free(b);
    }
    printf("FAKE_NPROCS=%s Threads(n=300000)=%d: %d/%d Fälle mit Abweichung gegen einen Thread\n",
           getenv("FAKE_NPROCS") ? getenv("FAKE_NPROCS") : "-", sl_par_threads(0, 300000, 512), bad, tot);
    return bad != 0;
}
