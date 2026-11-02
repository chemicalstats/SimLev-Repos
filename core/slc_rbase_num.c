/* core/slc_rbase_num.c – long-double-Rechenwege von R außerhalb der Summen (SimLev core, N10)
 *
 * Verfahren:  sl_r_strtod_num: Zahlteil von R_strtod (as.numeric(<Text>), Parser): Dezimalziffern mit
 *             Punkt und Exponent e[+-]n bzw. Hexadezimal 0x… mit Punkt und Binärexponent p[+-]n,
 *             akkumuliert in long double (ans = 10 * ans + Ziffer), danach Skalierung mit Zehner- bzw.
 *             Zweierpotenzen durch wiederholtes Quadrieren (bei sehr kleinen Exponenten zuerst Division
 *             durch 10 je Ziffer); Zehnerpotenzen in long double, Zweierpotenzen in double (N11: ab 2^1024
 *             Inf wie R); Vorzeichen, Leerraum, NA, NaN, Inf prüft der Host.
 *             sl_r_fmod_ld/sl_r_idiv_ld: der long-double-Teil von R's %% und %/% (myfmod, myfloor) für
 *             endliche Operanden nach den Sonderfällen im Host.
 *             NaN bei %% (N11, R 4.3.3 als Orakel, x86-64): x2 == ±0 ergibt im Host R_NaN (0x7FF8000000000000,
 *             positiv, auch bei NA in x1); sonst bei NaN-Operanden (NA eingeschlossen) liefert sl_r_fmod_ld: beide
 *             beruhigt, ist nur einer NaN dieser (Vorzeichen und Nutzlast bleiben), sonst der mit der größeren
 *             Mantisse, bei gleicher Mantisse der positive (z. B. NA %% 1 = NA beruhigt 0x7FF80000000007A2,
 *             NaN %% NA = NA, -NaN %% NaN = NaN, -NaN %% 1 = -NaN). Aus Inf entstehende NaN (Inf %% 1, 1e300 %%
 *             1e-300) sind die der Hardware (x87: negativ). %/% folgt der Division in double (erster NaN-Operand).
 *             sl_r_scientific: scientific() aus formatReal (signifikante Stellen, Zehnerexponent,
 *             "Rundung verbreitert") mit long double und nearbyintl wie R; Zehnerpotenzen 1e0..1e27 als
 *             double-Werte (wie R), sonst powl(10, kp).
 * Zweck:      Julia rechnete diese Stellen mit der Nachbildung von long double (julia/src/r/ld80.jl,
 *             F80); seit N10 mit diesen Kernen (ld80.jl entfällt). Python rechnete mit numpy.longdouble;
 *             seit N11 ebenfalls mit diesen Kernen (python/src/_ext_slc_rbase.c).
 * long double: wie slc_rbase.c (x86-64: x87 80 Bit, wie R).
 * Herkunft:           übersetzt aus R 4.3.3, src/main/util.c (R_strtod), arithmetic.c (myfmod,
 *                     myfloor), format.c (scientific), über die Julia-Nachbildungen
 *                     julia/src/r/rnum.jl, rexpr.jl, rformat.jl, _fmt_core.jl
 * Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation
 *                     (laut Kopf der jeweiligen R-Quelle)
 * Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
 * Änderungen:         C99 ohne R-Datenstrukturen, gemeinsamer Kern für Python und Julia (nicht Teil
 *                     des R-Pakets); nur die long-double-Rechenwege, Vorzeichen, Leerraum und
 *                     Sonderwerte prüft der Host.
 */
#include <float.h>
#include <math.h>
#include <stdint.h>

#include "slc_rbase.h"

typedef long double ldouble;

static int hexval_(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* 2^k (k >= 0) durch Quadrieren in double: ab k >= 1024 Inf (N11: so verhält sich R beim Binärexponenten
 * hexadezimaler Zahlen, z. B. as.numeric("0x1p-1024") = 0, "0x1p-1023" = 1.1e-308; R 4.3.3 als Orakel) */
static double pow2_dbl_(int64_t k)
{
    double fac = 1.0, p = 2.0;
    while (k != 0) {
        if (k & 1) fac *= p;
        k >>= 1;
        p *= p;
    }
    return fac;
}

static ldouble pow_int_(ldouble base, int64_t k)       /* base^k, k >= 0, durch Quadrieren */
{
    ldouble fac = 1.0L, p = base;
    while (k != 0) {
        if (k & 1) fac *= p;
        k >>= 1;
        p *= p;
    }
    return fac;
}

double sl_r_strtod_num(const char *s, int64_t len, int64_t *used, int *gt_max)
{
    int64_t p = 0;
    ldouble ans = 0.0L;
    int64_t expn = 0;
    *gt_max = 0;
#define AT(k) ((k) < len ? s[(k)] : '\0')
    if (len > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        int64_t exph = -1;
        p = 2;
        for (;;) {
            const char c = AT(p);
            const int h = hexval_(c);
            if (h >= 0) {
                ans = 16.0L * ans + (ldouble) h;
            } else if (c == '.') {
                exph = 0;
                p++;
                continue;
            } else {
                break;
            }
            if (exph >= 0) exph += 4;
            p++;
        }
        if (AT(p) == 'p' || AT(p) == 'P') {
            int64_t es = 1, m = 0;
            p++;
            if (AT(p) == '-') { es = -1; p++; }
            else if (AT(p) == '+') p++;
            while (AT(p) >= '0' && AT(p) <= '9') {
                m = m < 9999 ? m * 10 + (AT(p) - '0') : m;
                p++;
            }
            if (ans != 0.0L) {
                expn += es * m;
                if (exph > 0) {
                    if (expn - exph < -122) ans /= (ldouble) pow2_dbl_(exph);
                    else expn -= exph;
                }
                const ldouble fac = (ldouble) pow2_dbl_(expn < 0 ? -expn : expn);
                ans = expn < 0 ? ans / fac : ans * fac;
            }
        }
        *used = p;
        *gt_max = ans > (ldouble) DBL_MAX;
        return (double) ans;
    }
    int64_t nd = 0;
    while (AT(p) >= '0' && AT(p) <= '9') {
        ans = 10.0L * ans + (ldouble) (AT(p) - '0');
        p++;
        nd++;
    }
    if (AT(p) == '.') {
        p++;
        while (AT(p) >= '0' && AT(p) <= '9') {
            ans = 10.0L * ans + (ldouble) (AT(p) - '0');
            p++;
            nd++;
            expn--;
        }
    }
    if (nd == 0) {
        *used = -1;
        return 0.0;
    }
    if (AT(p) == 'e' || AT(p) == 'E') {
        int64_t es = 1, m = 0;
        p++;
        if (AT(p) == '-') { es = -1; p++; }
        else if (AT(p) == '+') p++;
        while (AT(p) >= '0' && AT(p) <= '9') {
            m = m < 9999 ? m * 10 + (AT(p) - '0') : m;
            p++;
        }
        expn += es * m;
    }
#undef AT
    if (expn + nd < -300) {
        for (int64_t i = 0; i < nd; i++) ans /= 10.0L;
        expn += nd;
    }
    if (expn < -307) {
        /* Kehrwert schrittweise: fac = 1 / 10^-expn durch Division */
        ldouble fac = 1.0L, p10 = 10.0L;
        int64_t k = -expn;
        while (k != 0) {
            if (k & 1) fac /= p10;
            k >>= 1;
            p10 *= p10;
        }
        ans *= fac;
    } else if (expn < 0) {
        ans /= pow_int_(10.0L, -expn);
    } else if (ans != 0.0L) {
        ans *= pow_int_(10.0L, expn);
    }
    *used = p;
    *gt_max = ans > (ldouble) DBL_MAX;
    return (double) ans;
}

/* NaN-Operanden von %% (N11): beide beruhigt (Bit 51 gesetzt); ist nur einer NaN, dieser; sonst der mit der
 * größeren Mantisse (Bits 0..51), bei gleicher Mantisse positiv, wenn einer positiv ist (x87-Regel wie in R) */
static double nan_pick_(double x1, double x2)
{
    union { double d; uint64_t u; } a, b;
    a.d = x1;
    b.d = x2;
    const uint64_t Q = UINT64_C(0x0008000000000000), M = UINT64_C(0x000FFFFFFFFFFFFF), SG = UINT64_C(0x8000000000000000);
    a.u |= Q;
    b.u |= Q;
    if (x2 == x2) return a.d;
    if (x1 == x1) return b.d;
    if ((a.u & M) != (b.u & M)) return (a.u & M) > (b.u & M) ? a.d : b.d;
    if (!(a.u & SG)) return a.d;
    return b.d;
}

double sl_r_fmod_ld(double x1, double x2)
{
    if (x1 != x1 || x2 != x2) return nan_pick_(x1, x2);
    const double q = x1 / x2;
    const ldouble tmp = (ldouble) x1 - (ldouble) floor(q) * (ldouble) x2;
    return (double) (tmp - floorl(tmp / (ldouble) x2) * (ldouble) x2);
}

double sl_r_idiv_ld(double x1, double x2)
{
    const double q = x1 / x2;
    const ldouble tmp = (ldouble) x1 - (ldouble) floor(q) * (ldouble) x2;
    return (double) ((ldouble) floor(q) + floorl(tmp / (ldouble) x2));
}

/* Zehnerpotenzen als double-Konstanten (1e23 .. 1e27 sind in double nicht exakt; R rechnet mit diesen Werten,
 * geprüft am Fall r_fmt/aschar_special: -7.3639995566896e-09 mit 15 Stellen) */
static const ldouble TBL_[28] = {1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14,
                                 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22, 1e23, 1e24, 1e25, 1e26, 1e27};
static const double TBLD_[28] = {1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14,
                                 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22, 1e23, 1e24, 1e25, 1e26, 1e27};

int sl_r_scientific(double r, int digits, int *kpower, int *nsig)
{
    int kp = (int) floor(log10(r)) - digits + 1;
    ldouble rp = (ldouble) r;
    if (kp >= -27 && kp <= 27) {
        if (kp > 0) rp /= TBL_[kp];
        else if (kp < 0) rp *= TBL_[-kp];
    } else {
        rp /= powl(10.0L, (ldouble) kp);
    }
    if (rp < TBL_[digits - 1]) {
        rp *= 10.0L;
        kp--;
    }
    double alpha = (double) nearbyintl(rp);
    int ns = digits;
    for (int j = 1; j <= digits; j++) {
        alpha /= 10.0;
        if (alpha == floor(alpha)) ns--;
        else break;
    }
    if (ns == 0 && digits > 0) {
        ns = 1;
        kp++;
    }
    const int kpw = kp + digits - 1;
    int rgt = digits - kpw;
    rgt = rgt < 0 ? 0 : (rgt > 27 ? 27 : rgt);
    const double fuzz = 0.5 / TBLD_[rgt];
    *kpower = kpw;
    *nsig = ns;
    return kpw > 0 && kpw <= 27 && (ldouble) r < TBL_[kpw] - (ldouble) fuzz;
}
