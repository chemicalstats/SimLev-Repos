/* core/slc_rbase.cpp – Summen, Mittel, Varianz, Kumulationen und Potenz mit R-Regeln (SimLev core)
 * Verfahren:  sequenzielle Akkumulation in long double in der Reihenfolge der Elemente, wie R sie
 *             für sum, prod, mean, var, cumsum, cumprod, rowSums/colSums dokumentiert ("accumulated
 *             in long double where available", ?sum, ?cumsum, ?colSums):
 *             - sum/prod: Summe bzw. Produkt in long double; liegt sie jenseits ±DBL_MAX, ±Inf,
 *               sonst auf double gerundet.
 *             - mean: Summe/n in long double, danach ein Korrekturdurchlauf s + Σ(x_i − s)/n
 *               (?mean: "the mean is computed in long double with a second pass"); ist die erste
 *               Summe nicht endlich, wird Σ(x_i/n) gebildet (Logik der Ports rnum.r_mean).
 *             - var: Mittel wie oben, als double gespeichert, dann Σ(x_i − m)²/(n − 1) in long double.
 *             - cumsum/cumprod: laufende Summe/Produkt in long double, je Schritt auf double gerundet;
 *               ab dem ersten NaN steht NA, sobald ein NA vorkam, sonst NaN (?cumsum: "An NA value
 *               in x causes the corresponding and following elements of the return value to be NA,
 *               as does integer overflow"; Logik der Ports `_handle_nan`).
 *             - cummax/cummin: in double, ab dem ersten NaN wie cumsum.
 *             - colSums/colMeans je Spalte wie sum; rowSums/rowMeans mit einem long-double-Akkumulator
 *               je Zeile, spaltenweise aufaddiert; Mittel durch die Anzahl (bei narm je Zeile). Seit 1.6.3
 *               colSums/colMeans auch über ausgewählte Zeilen (sl_r_colsums_idx, colMeans(x[idx, ]) ohne Kopie).
 *             - pow: R's ^ für Doubles: y == 2 → x·x, x == 1 oder y == 0 → 1, sonst libm pow mit
 *               R's Randfällen (?Arithmetic: 1^y und y^0 sind 1, auch für NA/NaN).
 *             - math1 (seit 1.5.2): exp, log, log1p, expm1, log2, log10 elementweise mit libm wie R's math1
 *               (?log: log(0) = -Inf, negative Werte NaN; NA/NaN bleiben erhalten).
 *             - round/signif (seit 1.6.3 hier, vorher slc_rbase_fmt.cpp): siehe den Block unten.
 *             - zeroin2: Brent-Verfahren (inverse quadratische bzw. lineare Interpolation mit
 *               Bisektion als Rückfall) wie R_zeroin2 hinter stats::uniroot, Schritt für Schritt in derselben
 *               Rechenfolge.
 *             - approx: Interpolation je Ausgabepunkt wie R_approxfun/approx1 hinter stats::approx und
 *               approxfun (nach der Aufbereitung von x und y in der Sprache): Bisektion des Intervalls,
 *               linear y_i + (y_j − y_i)((v − x_i)/(x_j − x_i)) bzw. konstant f1 y_i + f2 y_j (Summand 0,
 *               wenn das Gewicht 0 ist); außerhalb yleft/yright, NA/NaN in v bleibt v.
 *             Leere Eingabe: mean ist 0/0 in long double (NaN mit gesetztem Vorzeichenbit wie in R).
 *             NaN-Ergebnisse (welche Nutzlast bei zwei NaN-Operanden gewinnt) folgen der Hardware
 *             (x87 bei long double), genau wie in R; die Ports bildeten dafür die x87-Regel nach.
 * Quellen:    R-Hilfeseiten (R 4.3.3) wie oben; ISO/IEC 9899:1999 7.12 (math.h), Annex F;
 *             Intel 64 and IA-32 Architectures Software Developer's Manual, Vol. 1, Kap. 8 (x87).
 * Konstanten: DBL_MAX aus <float.h>; NA und NaN als Bitmuster (slc_rbase.h).
 * long double: absichtlich (siehe slc_rbase.h): nur so gleich zu R auf derselben Plattform.
 * Herkunft:           übersetzt aus R 4.3.3, src/main/summary.c, cum.c (handleNaN), array.c,
 *                     arithmetic.c (R_POW), src/nmath/fround.c, fprec.c (seit 1.6.3 hier), src/library/stats/src/zeroin.c (R_zeroin2; dort: aus Netlib
 *                     c/brent.shar, Brents Prozedur zero, R. P. Brent, Algorithms for Minimization without
 *                     Derivatives, 1973), src/library/stats/src/approx.c (approx1, R_approxfun; seit
 *                     1.5.0), über die Port-Funktionen python/simlev/_r/rnum.py, base.py, stats_smooth.py
 *                     (_approx_core) und julia/src/r/rnum.jl (r_zeroin2), base.jl, ld80.jl
 * Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation
 *                     (laut Kopf der jeweiligen R-Quelle)
 * Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
 * Änderungen:         C99 ohne R-Datenstrukturen, gemeinsamer Kern für Python und Julia (nicht Teil
 *                     des R-Pakets); long double nur dort, wo R es nutzt.
 * Prüforakel: R 4.3.3 (Gleichlauf: rbase_fuzz.R).
 */
#include "slc_internal.h"
#include "slc_rbase.h"

#include <float.h>
#include <stdlib.h>
#include <string.h>

typedef long double ldouble;

static double bits_d(uint64_t u)
{
    double d;
    memcpy(&d, &u, sizeof d);
    return d;
}

static int is_na(double x)
{
    uint64_t u;
    if (x == x) return 0;
    memcpy(&u, &x, sizeof u);
    return (u & UINT64_C(0xFFFFFFFF)) == 1954;
}

static double quiet(double x)
{
    uint64_t u;
    memcpy(&u, &x, sizeof u);
    return bits_d(u | UINT64_C(0x0008000000000000));
}

#define R_NA  bits_d(UINT64_C(0x7FF00000000007A2))
#define R_NAN bits_d(UINT64_C(0x7FF8000000000000))

static double ld_to_d_clamped(ldouble s)
{
    if (s > (ldouble) DBL_MAX) return INFINITY;
    if (s < -(ldouble) DBL_MAX) return -INFINITY;
    return (double) s;
}

double sl_r_sum(int64_t n, const double *x, int narm)
{
    ldouble s = 0.0L;
    int64_t i;
    for (i = 0; i < n; i++)
        if (!narm || !isnan(x[i])) s += x[i];
    return ld_to_d_clamped(s);
}

double sl_r_prod(int64_t n, const double *x, int narm)
{
    ldouble s = 1.0L;
    int64_t i;
    for (i = 0; i < n; i++)
        if (!narm || !isnan(x[i])) s *= x[i];
    return ld_to_d_clamped(s);
}

double sl_r_mean(int64_t n, const double *x)
{
    ldouble s = 0.0L, t, ln = (ldouble) n;
    int64_t i;
    int finite_s;
    for (i = 0; i < n; i++) s += x[i];
    finite_s = isfinite((double) s);
    if (finite_s) {
        s /= ln;
    } else {
        s = 0.0L;
        for (i = 0; i < n; i++) s += x[i] / (double) n;
    }
    if (finite_s && isfinite((double) s)) {
        t = 0.0L;
        for (i = 0; i < n; i++) t += (x[i] - s);
        s += t / ln;
    } else if (isfinite((double) s)) {
        t = 0.0L;
        for (i = 0; i < n; i++) t += (x[i] - s) / ln;
        s += t;
    }
    return (double) s;
}

double sl_r_mean_int(int64_t n, const int64_t *x)
{
    ldouble s = 0.0L;
    int64_t i;
    for (i = 0; i < n; i++) s += (ldouble) x[i];
    return (double) (s / (ldouble) n);
}

/* Mittel wie in cov/var: Summe/n, Korrektur nur bei endlichem Zwischenwert; Ergebnis long double */
static ldouble mean_ld(int64_t n, const double *x)
{
    ldouble s = 0.0L, t, ln = (ldouble) n;
    int64_t i;
    for (i = 0; i < n; i++) s += x[i];
    t = s / ln;
    if (isfinite((double) t)) {
        s = 0.0L;
        for (i = 0; i < n; i++) s += (x[i] - t);
        t = t + s / ln;
    }
    return t;
}

double sl_r_var(int64_t n, const double *x)
{
    ldouble s = 0.0L, d, xm;
    int64_t i;
    if (n <= 1) return R_NA;
    xm = (ldouble) (double) mean_ld(n, x);        /* Mittelwert als double gespeichert */
    for (i = 0; i < n; i++) { d = x[i] - xm; s += d * d; }
    return (double) (s / (ldouble) (n - 1));
}

/* ab dem ersten NaN: NA, sobald ein NA vorkam, sonst NaN */
static void handle_nan(int64_t n, const double *x, double *out)
{
    int has_nan = 0, has_na = 0;
    int64_t i;
    for (i = 0; i < n; i++) {
        if (!has_nan && isnan(x[i])) has_nan = 1;
        if (has_nan && !has_na && is_na(x[i])) has_na = 1;
        if (has_na) out[i] = R_NA;
        else if (has_nan) out[i] = R_NAN;
    }
}

void sl_r_cumsum(int64_t n, const double *x, double *out)
{
    ldouble s = 0.0L;
    int64_t i;
    for (i = 0; i < n; i++) { s += x[i]; out[i] = (double) s; }
    if (n > 0 && isnan(out[n - 1])) handle_nan(n, x, out);
}

void sl_r_cumprod(int64_t n, const double *x, double *out)
{
    ldouble s = 1.0L;
    int64_t i;
    for (i = 0; i < n; i++) { s *= x[i]; out[i] = (double) s; }
    if (n > 0 && isnan(out[n - 1])) handle_nan(n, x, out);
}

static void cumext(int64_t n, const double *x, double *out, int max)
{
    double m = max ? -INFINITY : INFINITY;
    int64_t i;
    for (i = 0; i < n; i++) {
        if (isnan(x[i])) { handle_nan(n, x, out); return; }
        if (max ? !(m > x[i]) : !(m < x[i])) m = x[i];
        out[i] = m;
    }
}

void sl_r_cummax(int64_t n, const double *x, double *out) { cumext(n, x, out, 1); }
void sl_r_cummin(int64_t n, const double *x, double *out) { cumext(n, x, out, 0); }

void sl_r_colsums(int64_t nr, int64_t nc, const double *x, int narm, int mean, double *out)
{
    int64_t i, j, cnt;
    for (j = 0; j < nc; j++) {
        const double *c = x + j * nr;
        ldouble s = 0.0L;
        cnt = 0;
        for (i = 0; i < nr; i++)
            if (!narm || !isnan(c[i])) { s += c[i]; cnt++; }
        if (mean && !isnan((double) s)) s /= (ldouble) cnt;
        out[j] = (double) s;
    }
}

/* colSums/colMeans der Zeilen idx einer Matrix (seit 1.6.3): wie sl_r_colsums auf der Matrix x[idx, ] (Zeilen in der
 * Reihenfolge von idx, Wiederholungen erlaubt), ohne sie zu bilden. Element (r, j) bei x[r rs + j cs] (spaltenweise
 * rs = 1, cs = nr; zeilenweise rs = nc, cs = 1). idx: m Zeilennummern ab base (0 oder 1). Je Spalte dieselben
 * Summanden in derselben Reihenfolge wie sl_r_colsums auf der Kopie (long double, Mittel durch die Anzahl): Bit
 * fuer Bit gleich; bei rs > cs laeuft die Schleife zeilenweise mit einem Akkumulator je Spalte (gleiche Folge je
 * Spalte). Rueckgabe SL_OK, SL_EARG (Zeilennummer ausserhalb, out unveraendert), SL_ENOMEM. */
int sl_r_colsums_idx(int64_t nr, int64_t nc, const double *x, int64_t rs, int64_t cs, int64_t m, const int64_t *idx,
                     int64_t base, int narm, int mean, double *out)
{
    int64_t i, j;
    if (nr < 0 || nc < 0 || m < 0) return SL_EARG;
    for (i = 0; i < m; i++)
        if (idx[i] - base < 0 || idx[i] - base >= nr) return SL_EARG;
    if (rs <= cs) {
        for (j = 0; j < nc; j++) {
            const double *c = x + j * cs;
            ldouble s = 0.0L;
            int64_t cnt = 0;
            for (i = 0; i < m; i++) {
                const double v = c[(idx[i] - base) * rs];
                if (!narm || !isnan(v)) { s += v; cnt++; }
            }
            if (mean && !isnan((double) s)) s /= (ldouble) cnt;
            out[j] = (double) s;
        }
        return SL_OK;
    }
    {
        ldouble *acc = (ldouble *) calloc((size_t) (nc > 0 ? nc : 1), sizeof(ldouble));
        int64_t *cnt = (int64_t *) calloc((size_t) (nc > 0 ? nc : 1), sizeof(int64_t));
        if (acc == NULL || cnt == NULL) { free(acc); free(cnt); return SL_ENOMEM; }
        for (i = 0; i < m; i++) {
            const double *row = x + (idx[i] - base) * rs;
            for (j = 0; j < nc; j++) {
                const double v = row[j * cs];
                if (!narm || !isnan(v)) { acc[j] += v; cnt[j]++; }
            }
        }
        for (j = 0; j < nc; j++) {
            ldouble s = acc[j];
            if (mean && !isnan((double) s)) s /= (ldouble) cnt[j];
            out[j] = (double) s;
        }
        free(acc); free(cnt);
    }
    return SL_OK;
}

/* Spalte j: cols[j] bzw. x + j nr */
static int rowsums_(int64_t nr, int64_t nc, const double *x, const double *const *cols, int narm, int mean,
                    double *out)
{
    ldouble *acc;
    int64_t *cnt = NULL, i, j;
    acc = (ldouble *) calloc((size_t) (nr > 0 ? nr : 1), sizeof(ldouble));
    if (narm) cnt = (int64_t *) calloc((size_t) (nr > 0 ? nr : 1), sizeof(int64_t));
    if (acc == NULL || (narm && cnt == NULL)) { free(acc); free(cnt); return SL_ENOMEM; }
    for (j = 0; j < nc; j++) {
        const double *c = cols ? cols[j] : x + j * nr;
        if (narm) {
            for (i = 0; i < nr; i++)
                if (!isnan(c[i])) { acc[i] += c[i]; cnt[i]++; }
        } else {
            for (i = 0; i < nr; i++) acc[i] += c[i];
        }
    }
    for (i = 0; i < nr; i++) {
        ldouble s = acc[i];
        if (mean) s /= (ldouble) (narm ? cnt[i] : nc);
        out[i] = (double) s;
    }
    free(acc); free(cnt);
    return SL_OK;
}

int sl_r_rowsums(int64_t nr, int64_t nc, const double *x, int narm, int mean, double *out)
{
    return rowsums_(nr, nc, x, NULL, narm, mean, out);
}

int sl_r_rowsums_cols(int64_t nr, int64_t nc, const double *const *cols, int narm, int mean, double *out)
{
    return rowsums_(nr, nc, NULL, cols, narm, mean, out);
}

/*
 * Teil:               sl_r_civil_from_days, sl_r_days_from_civil, sl_r_fdiv (slc_rbase.h); seit 1.6.3 hier
 *                     statt in slc_rbase_date.cpp und als Kopie in slc_prep.cpp
 * Herkunft:           übersetzt aus H. Hinnant, chrono-Compatible Low-Level Date Algorithms,
 *                     https://howardhinnant.github.io/date_algorithms.html
 * Rechte:             gemeinfrei ("Consider these donated to the public domain.")
 * Lizenz der Vorlage: keine (gemeinfrei)
 * Änderungen:         int64_t mit Abrundungsdivision sl_r_fdiv statt der Fallunterscheidung für
 *                     negative Werte.
 */
void sl_r_civil_from_days(int64_t z, int64_t *y, int *m, int *d)
{
    z += 719468;
    const int64_t era = sl_r_fdiv(z, 146097);
    const int64_t doe = z - era * 146097;                                  /* 0 .. 146096 */
    const int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const int64_t mp = (5 * doy + 2) / 153;
    *d = (int) (doy - (153 * mp + 2) / 5 + 1);
    *m = (int) (mp < 10 ? mp + 3 : mp - 9);
    *y = yoe + era * 400 + (*m <= 2);
}

int64_t sl_r_days_from_civil(int64_t y, int m, int d)
{
    y -= m <= 2;
    const int64_t era = sl_r_fdiv(y, 400);
    const int64_t yoe = y - era * 400;
    const int64_t doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    const int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

/* ── round / signif (seit 1.6.3 hier statt in slc_rbase_fmt.cpp; der Tarif, tariff_core_impl.h, rundet damit) ──
 * round (fround, R >= 4.0.0): Kandidaten floor/ceil von x·10^d, der nähere gewinnt, bei Gleichstand der gerade;
 * signif (fprec): Runden auf d signifikante Stellen über 10^e mit Schutz vor Über- und Unterlauf; NA, wenn x oder d
 * NA ist, sonst NaN bei NaN (wie Math2 von R). Konstanten: log10(2) = 0.301029995663981195213738894724; DBL_DIG 15;
 * größter Zehnerexponent 308. Herkunft: R 4.3.3, src/nmath/fround.c, fprec.c über python/simlev/_r/fmt.py (fround,
 * fprec) und julia/src/r/_fmt_core.jl (bis 1.5.2). */
#define M_LOG10_2_ 0.301029995663981195213738894724
#define DBL_DIG_ 15
#define MAX10E_ 308

static double pow_di(double x, int n)
{
    double xn = 1.0;
    if (isnan(x)) return x;
    if (n != 0) {
        int neg;
        if (!isfinite(x)) return pow(x, (double) n);
        neg = n < 0;
        if (neg) n = -n;
        for (;;) {
            if (n & 1) xn *= x;
            n >>= 1;
            if (n) x *= x;
            else break;
        }
        if (neg) xn = 1.0 / xn;
    }
    return xn;
}

/* NA/NaN wie math2 von R: NA, wenn ein Operand NA ist, sonst NaN */
static double na_math2(double a, double b)
{
    double r;
    uint64_t u = (is_na(a) || is_na(b)) ? UINT64_C(0x7FF00000000007A2) : UINT64_C(0x7FF8000000000000);
    memcpy(&r, &u, sizeof r);
    return r;
}

static double logb_(double x)
{
    int e;
    (void) frexp(x, &e);
    return (double) (e - 1);
}

double sl_r_fround(double x, double digits)
{
    const double max_digits = 308 + 15;
    int dig;
    double sgn = 1.0, l10x, pow10, x10, i10, xd, xu, du, dd;
    if (isnan(x) || isnan(digits)) return na_math2(x, digits);
    if (!isfinite(x)) return x;
    if (digits > max_digits || x == 0.0) return x;
    if (digits < -MAX10E_) return 0.0;
    if (digits == 0.0) return nearbyint(x);
    dig = (int) floor(digits + 0.5);
    if (x < 0.0) { sgn = -1.0; x = -x; }
    l10x = M_LOG10_2_ * (0.5 + logb_(x));
    if (l10x + dig > DBL_DIG_) return sgn * x;
    if (dig <= MAX10E_) {
        pow10 = pow_di(10.0, dig);
        x10 = x * pow10;
        i10 = floor(x10);
        xd = i10 / pow10;
        xu = ceil(x10) / pow10;
    } else {
        int e10 = dig - MAX10E_;
        double p10 = pow_di(10.0, e10);
        pow10 = pow_di(10.0, MAX10E_);
        x10 = (x * pow10) * p10;
        i10 = floor(x10);
        xd = i10 / pow10 / p10;
        xu = ceil(x10) / pow10 / p10;
    }
    du = xu - x;
    dd = x - xd;
    return sgn * ((du < dd || (fmod(i10, 2.0) == 1 && du == dd)) ? xu : xd);
}

double sl_r_fprec(double x, double digits)
{
    const int max_digits = 22;
    int dig, e10;
    double sgn = 1.0, l10;
    if (isnan(x) || isnan(digits)) return na_math2(x, digits);
    if (!isfinite(x)) return x;
    if (!isfinite(digits)) {
        if (digits > 0.0) return x;
        digits = 1.0;
    }
    if (x == 0) return x;
    if (fabs(digits) > 1e9) dig = digits > 0 ? max_digits + 1 : 1;
    else dig = (int) floor(fabs(digits) + 0.5) * (digits >= 0 ? 1 : -1);
    if (dig > max_digits) return x;
    if (dig < 1) dig = 1;
    if (x < 0.0) { sgn = -sgn; x = -x; }
    l10 = log10(x);
    e10 = (int) (dig - 1 - floor(l10));
    if (fabs(l10) < MAX10E_ - 2) {
        double p10 = 1.0, pow10;
        if (e10 > MAX10E_) {
            p10 = pow_di(10.0, e10 - MAX10E_);
            e10 = MAX10E_;
        }
        if (e10 > 0) {
            pow10 = pow_di(10.0, e10);
            return sgn * (nearbyint((x * pow10) * p10) / pow10) / p10;
        }
        pow10 = pow_di(10.0, -e10);
        return sgn * (nearbyint(x / pow10) * pow10);
    } else {
        int do_round = MAX10E_ - l10 >= pow_di(10.0, -dig);
        int e2 = dig + (e10 > 0 ? 1 : -1) * max_digits;
        double p10 = pow_di(10.0, e2), P10;
        x *= p10;
        P10 = pow_di(10.0, e10 - e2);
        x *= P10;
        if (do_round) x += 0.5;
        x = floor(x) / p10;
        return sgn * x / P10;
    }
}

void sl_r_round_vec(int kind, int64_t nx, const double *x, int64_t nd, const double *digits, double *out)
{
    int64_t i, n = nx > nd ? nx : nd;
    if (nx == 0 || nd == 0) return;
    for (i = 0; i < n; i++) {
        double a = x[i % nx], b = digits[i % nd];
        out[i] = kind ? sl_r_fprec(a, b) : sl_r_fround(a, b);
    }
}

/* R's x ^ y für Doubles */
static double r_pow1(double x, double y)
{
    if (y == 2.0) return x * x;
    if (x == 1.0 || y == 0.0) return 1.0;
    if (x == 0.0) {
        if (y > 0.0) return 0.0;
        if (y < 0.0) return INFINITY;
        return y;                                   /* NaN */
    }
    if (isfinite(x) && isfinite(y)) return pow(x, y);   /* negative Basis, gebrochener Exponent: NaN von pow */
    if (isnan(y)) return quiet(y);                  /* NaN-Operand: der von y gewinnt, sonst der von x (wie R) */
    if (isnan(x)) return quiet(x);
    if (!isfinite(x)) {
        if (x > 0) return y < 0.0 ? 0.0 : INFINITY;
        if (isfinite(y) && y == floor(y))
            return y < 0.0 ? 0.0 : (fmod(y, 2.0) != 0.0 ? x : -x);
    }
    if (!isfinite(y)) {
        if (x >= 0) {
            if (y > 0) return x >= 1 ? INFINITY : 0.0;
            return x < 1 ? INFINITY : 0.0;
        }
    }
    return R_NAN;
}

double sl_r_pow1(double x, double y) { return r_pow1(x, y); }

void sl_r_pow(int64_t n, const double *x, double y, double *out)
{
    int64_t i;
    if (y == 2.0) {
        for (i = 0; i < n; i++) out[i] = x[i] * x[i];
        return;
    }
    for (i = 0; i < n; i++) out[i] = r_pow1(x[i], y);
}

/* x ^ y elementweise mit R-Recycling (nx, ny >= 1; Länge max(nx, ny)) */
void sl_r_pow_rec(int64_t nx, const double *x, int64_t ny, const double *y, double *out)
{
    int64_t i, n = nx > ny ? nx : ny;
    for (i = 0; i < n; i++) out[i] = r_pow1(x[i % nx], y[i % ny]);
}

/* libm elementweise mit den Randregeln von R (arithmetic.c R_log, math1): NaN in x bleibt x
 * (Nutzlast erhalten), log(0) = -Inf, log(< 0) = NaN, log1p(-1) = -Inf, log1p(< -1) = NaN; exp, expm1 direkt
 * (Überlauf Inf, NaN von libm). kind: SL_R_EXP, SL_R_LOG, SL_R_LOG1P, SL_R_EXPM1, SL_R_LOG2, SL_R_LOG10. */
void sl_r_math1(int kind, int64_t n, const double *x, double *out)
{
    int64_t i;
    double v;
    switch (kind) {
    case SL_R_EXP:   for (i = 0; i < n; i++) out[i] = exp(x[i]); break;
    case SL_R_EXPM1: for (i = 0; i < n; i++) out[i] = expm1(x[i]); break;
    case SL_R_LOG:   for (i = 0; i < n; i++) out[i] = sl_r_log1(x[i]); break;
    case SL_R_LOG1P:
        for (i = 0; i < n; i++) { v = x[i]; out[i] = v > -1 ? log1p(v) : v == -1 ? -INFINITY : isnan(v) ? v : R_NAN; }
        break;
    case SL_R_LOG2:
        for (i = 0; i < n; i++) { v = x[i]; out[i] = v > 0 ? log2(v) : v == 0 ? -INFINITY : isnan(v) ? v : R_NAN; }
        break;
    case SL_R_LOG10:
        for (i = 0; i < n; i++) { v = x[i]; out[i] = v > 0 ? log10(v) : v == 0 ? -INFINITY : isnan(v) ? v : R_NAN; }
        break;
    default:
        for (i = 0; i < n; i++) out[i] = R_NAN;
    }
}

/* R_zeroin2 (stats/src/zeroin.c) über den Port julia/src/r/rnum.jl (r_zeroin2): a, b Klammer, c Gegenpunkt
 * mit f(c) von anderem Vorzeichen als f(b); je Schritt inverse quadratische (a != c) bzw. lineare
 * Interpolation, wenn sie innerhalb von 3/4 der Klammer und unter der Hälfte des vorletzten Schritts bleibt,
 * sonst Bisektion; Schritte mindestens tol_act = 2 eps |b| + tol/2. Rechenfolge wie R (-ffp-contract=off). */
double sl_r_zeroin2(sl_r_fn1 f, void *info, double ax, double bx, double fa, double fb, double tol, int maxit,
                    int *iter)
{
    double a = ax, b = bx, c = a, fc = fa;
    int maxit_c = maxit + 1;
    if (fa == 0.0) { *iter = 0; return a; }
    if (fb == 0.0) { *iter = 0; return b; }
    while (maxit_c != 0) {
        double prev_step, tol_act, new_step, p, q;
        maxit_c--;
        prev_step = b - a;
        if (fabs(fc) < fabs(fb)) {
            a = b; b = c; c = a;
            fa = fb; fb = fc; fc = fa;
        }
        tol_act = 2 * DBL_EPSILON * fabs(b) + tol / 2;
        new_step = (c - b) / 2;
        if (fabs(new_step) <= tol_act || fb == 0.0) {
            *iter = maxit - maxit_c;
            return b;
        }
        if (fabs(prev_step) >= tol_act && fabs(fa) > fabs(fb)) {
            double t1, cb, t2;
            cb = c - b;
            if (a == c) {
                t1 = fb / fa;
                p = cb * t1;
                q = 1.0 - t1;
            } else {
                q = fa / fc;
                t1 = fb / fc;
                t2 = fb / fa;
                p = t2 * (cb * q * (q - t1) - (b - a) * (t1 - 1.0));
                q = (q - 1.0) * (t1 - 1.0) * (t2 - 1.0);
            }
            if (p > 0.0) q = -q;
            else p = -p;
            if (p < (0.75 * cb * q - fabs(tol_act * q) / 2) && p < fabs(prev_step * q / 2))
                new_step = p / q;
        }
        if (fabs(new_step) < tol_act) new_step = new_step > 0.0 ? tol_act : -tol_act;
        a = b; fa = fb;
        b += new_step;
        fb = f(b, info);
        if ((fb > 0 && fc > 0) || (fb < 0 && fc < 0)) {
            c = a; fc = fa;
        }
    }
    *iter = -1;
    return b;
}

/* approx1/R_approxfun (stats/src/approx.c) über den Port python/simlev/_r/stats_smooth.py (_approx_core):
 * x aufsteigend ohne NA (Länge n), y gleich lang; je v = xout[k] Bisektion i < j mit x[i] <= v <= x[j]. */
static double approx1(double v, const double *x, const double *y, int64_t n, int method, double yleft,
                      double yright, double f1, double f2)
{
    int64_t i = 0, j = n - 1;
    if (!n) return R_NAN;
    if (v < x[i]) return yleft;
    if (v > x[j]) return yright;
    while (i < j - 1) {
        int64_t ij = (i + j) / 2;
        if (v < x[ij]) j = ij; else i = ij;
    }
    if (v == x[j]) return y[j];
    if (v == x[i]) return y[i];
    if (method == 1) return y[i] + (y[j] - y[i]) * ((v - x[i]) / (x[j] - x[i]));
    return (f1 != 0.0 ? y[i] * f1 : 0.0) + (f2 != 0.0 ? y[j] * f2 : 0.0);
}

void sl_r_approx(int64_t n, const double *x, const double *y, int64_t nout, const double *xout, int method,
                 double yleft, double yright, double f, double *yout)
{
    const double f2 = f, f1 = 1 - f;
    for (int64_t k = 0; k < nout; k++)
        yout[k] = isnan(xout[k]) ? xout[k] : approx1(xout[k], x, y, n, method, yleft, yright, f1, f2);
}
