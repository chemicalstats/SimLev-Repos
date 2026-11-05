/* core/slc_rbase_fmt.cpp – Zahlformat und sprintf mit R-Regeln (SimLev core, seit 1.6.0)
 * Verfahren:  - round (fround, R >= 4.0.0): Kandidaten floor/ceil von x·10^d, der nähere gewinnt, bei Gleichstand der
 *               gerade; signif (fprec): Runden auf d signifikante Stellen über 10^e mit Schutz vor Über- und Unterlauf;
 *               NA, wenn x oder d NA ist, sonst NaN bei NaN (wie Math2 von R).
 *             - formatReal: gemeinsame Breite w, Nachkommastellen d und Exponentenbreite e eines Vektors für digits
 *               signifikante Stellen (scientific(): Mantisse in long double, sl_r_scientific; ab 16 Stellen über
 *               "%#.*e"), Festkomma, wenn es höchstens scipen Zeichen breiter ist als die wissenschaftliche Form, nsmall.
 *             - encodeReal: "%*.*f", "%*.*e" bzw. "%#*.*e" über snprintf der C-Bibliothek, NA/NaN/Inf rechtsbündig,
 *               −0 als 0, Dezimalzeichen; as.character für Zahlen = formatReal mit 15 Stellen je Wert ohne Endnullen.
 *             - str_signif (formatC): je Wert snprintf mit "%<flag>*.*<format>", "fg" als Festkomma mit digits
 *               signifikanten Stellen (Exponent über log10, Runden über fround, "%.*f" bei kleinem Exponenten).
 *             - sprintf: Vektorsemantik von ?sprintf (Recycling, %%, %n$, * und *n$ für Breite/Genauigkeit, einmalige
 *               Umwandlung je Argument: ganzzahlige Doubles für %d, Zahlen für %f…, as.character für %s), jede
 *               Umwandlung über snprintf der C-Bibliothek wie R (Breiten bei %s in Bytes), NA/NaN/Inf als Text mit
 *               Breite, höchstens 8192 Bytes je Umwandlung.
 * Quellen:    R-Hilfeseiten (R 4.3.3) ?round, ?signif, ?format, ?formatC, ?sprintf, ?as.character, ?options (digits,
 *             scipen, OutDec); ISO/IEC 9899:2011, 7.21.6.1 (fprintf).
 * Konstanten: log10(2) = 0.301029995663981195213738894724; DBL_DIG 15; größter Zehnerexponent 308.
 * Herkunft:           übersetzt aus R 4.3.3, src/nmath/fround.c, fprec.c, src/main/format.c (formatReal, scientific),
 *                     printutils.c (encodeReal0), util.c (str_signif), sprintf.c über die Port-Funktionen
 *                     python/simlev/_r/fmt.py (fround, fprec, _format_real, _encode_real, _str_signif, sprintf) und
 *                     julia/src/r/_fmt_core.jl, _fmt_format.jl (bis 1.5.2)
 * Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut Kopf der
 *                     jeweiligen R-Quelle); sprintf.c: ursprünglich Jonathan Rougier
 * Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
 * Änderungen:         C++ im gemeinsamen Teil von C und C++, ohne R-Datenstrukturen, gemeinsamer Kern für Python und
 *                     Julia (nicht Teil des R-Pakets); Argumente von sprintf als Felder mit Typkennung.
 * Prüforakel: R 1.5.2 von SimLev (round, signif, format, formatC, prettyNum, sprintf, as.character; Gleichlauf
 *             fmt_fuzz.R).
 */
#include "slc_internal.h"
#include "slc_rbase2.h"

#include <float.h>
#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define M_LOG10_2_ 0.301029995663981195213738894724
#define DBL_DIG_ 15
#define MAX10E_ 308
#define MAXLINE_ 8192
#define NA_INT_ INT_MIN

static int is_na(double x)
{
    uint64_t u;
    if (!isnan(x)) return 0;
    memcpy(&u, &x, sizeof u);
    return (u & UINT64_C(0xFFFFFFFF)) == 1954;
}

void sl_r_free(void *p) { free(p); }

/* ── round / signif ─────────────────────────────────────────────────────── */

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

/* ── formatReal / encodeReal ─────────────────────────────────────────────── */

static void scientific1(double r, int digits, int *kpower, int *nsig, int *rw)
{
    if (digits >= DBL_DIG_ + 1) {
        char buff[512];
        int j;
        snprintf(buff, sizeof buff, "%#.*e", digits - 1, r);
        *kpower = (int) strtol(buff + digits + 2, NULL, 10);
        for (j = digits; j >= 2; j--)
            if (buff[j] != '0') break;
        *nsig = j;
        *rw = 0;
        return;
    }
    *rw = sl_r_scientific(r, digits, kpower, nsig);
}

void sl_r_format_real(int64_t n, const double *x, const unsigned char *na, int digits, int nsmall, int scipen,
                      int *w, int *d, int *e)
{
    int64_t i;
    int naflag = 0, nanflag = 0, posinf = 0, neginf = 0, neg = 0, have = 0;
    int rgt = 0, mxl = 0, mnl = 0, mxsl = 0, mxns = 0;
    for (i = 0; i < n; i++) {
        double xi = x[i];
        if (!isfinite(xi)) {
            int isna_ = na ? na[i] != 0 : is_na(xi);
            if (isnan(xi)) {
                if (isna_) naflag = 1;
                else nanflag = 1;
            } else if (xi > 0) {
                posinf = 1;
            } else {
                neginf = 1;
            }
            continue;
        }
        {
            int kpower = 0, nsig = 1, rw = 0, left, sleft, right, negi = xi < 0;
            double r = fabs(xi);
            if (r != 0.0) scientific1(r, digits, &kpower, &nsig, &rw);
            left = kpower + 1 - rw;
            sleft = negi + (left <= 0 ? 1 : left);
            right = nsig - left;
            if (negi) neg = 1;
            if (!have) {
                rgt = right; mxl = left; mnl = left; mxsl = sleft; mxns = nsig;
                have = 1;
            } else {
                if (right > rgt) rgt = right;
                if (left > mxl) mxl = left;
                if (left < mnl) mnl = left;
                if (sleft > mxsl) mxsl = sleft;
                if (nsig > mxns) mxns = nsig;
            }
        }
    }
    if (have) {
        int wF;
        if (digits == 0) rgt = 0;
        if (mxl < 0) mxsl = 1 + neg;
        if (rgt < 0) rgt = 0;
        wF = mxsl + rgt + (rgt != 0);
        *e = (mxl > 100 || mnl <= -99) ? 2 : 1;
        *d = mxns - 1;
        *w = neg + (*d > 0) + *d + 4 + *e;
        if (wF <= *w + scipen) {
            *e = 0;
            if (nsmall > rgt) {
                rgt = nsmall;
                wF = mxsl + rgt + (rgt != 0);
            }
            *d = rgt;
            *w = wF;
        }
    } else {
        *w = *d = *e = 0;
    }
    if (naflag && *w < 2) *w = 2;
    if (nanflag && *w < 3) *w = 3;
    if (posinf && *w < 3) *w = 3;
    if (neginf && *w < 4) *w = 4;
}

/* dynamischer Puffer */
/* ext: p zeigt auf fremden Speicher (Stapel), beim Wachsen wird kopiert */
typedef struct { char *p; int64_t n, cap; int bad; int ext; } sbuf;

static void sb_put(sbuf *b, const char *s, int64_t len)
{
    if (b->bad) return;
    if (b->n + len + 1 > b->cap) {
        int64_t c = b->cap ? b->cap : 256;
        char *q;
        while (b->n + len + 1 > c) c *= 2;
        if (b->ext) {
            q = (char *) malloc((size_t) c);
            if (q && b->n) memcpy(q, b->p, (size_t) b->n);
            b->ext = 0;
        } else {
            q = (char *) realloc(b->p, (size_t) c);
        }
        if (!q) { b->bad = 1; return; }
        b->p = q;
        b->cap = c;
    }
    memcpy(b->p + b->n, s, (size_t) len);
    b->n += len;
    b->p[b->n] = 0;
}

static void sb_pad(sbuf *b, int64_t k)
{
    while (k-- > 0) sb_put(b, " ", 1);
}

/* encodeReal0 eines Werts nach b; drop0: Endnullen entfernen (EncodeRealDrop0) */
static void encode1(sbuf *b, double x, int isna_, int w, int d, int e, const char *dec, const char *nastr, int drop0)
{
    char tmp[1024];
    int len;
    if (!isfinite(x)) {
        const char *s = isnan(x) ? (isna_ ? nastr : "NaN") : (x > 0 ? "Inf" : "-Inf");
        int64_t ls = (int64_t) strlen(s);
        sb_pad(b, w - ls);
        sb_put(b, s, ls);
        return;
    }
    if (x == 0.0) x = 0.0;
    if (e) len = snprintf(tmp, sizeof tmp, d ? "%#*.*e" : "%*.*e", w, d, x);
    else len = snprintf(tmp, sizeof tmp, "%*.*f", w, d, x);
    if (len < 0) len = 0;
    if (len >= (int) sizeof tmp) len = (int) sizeof tmp - 1;
    if (drop0) {
        char *p = strchr(tmp, '.');
        if (p) {
            char *q = p + 1, *rep = p;
            while (*q >= '0' && *q <= '9') {
                if (*q != '0') rep = q + 1;
                q++;
            }
            memmove(rep, q, strlen(q) + 1);
            len = (int) strlen(tmp);
        }
    }
    if (dec && strcmp(dec, ".") != 0) {
        char *p = strchr(tmp, '.');
        if (p) {
            sb_put(b, tmp, p - tmp);
            sb_put(b, dec, (int64_t) strlen(dec));
            sb_put(b, p + 1, len - (p + 1 - tmp));
            return;
        }
    }
    sb_put(b, tmp, len);
}

static int finish_strs(sbuf *b, int64_t *offs, int64_t n, char **out, int64_t **off)
{
    (void) n;
    if (b->bad) { free(b->p); free(offs); return SL_ENOMEM; }
    if (!b->p) sb_put(b, "", 0);
    if (b->bad) { free(b->p); free(offs); return SL_ENOMEM; }
    *out = b->p;
    *off = offs;
    return 0;
}

int sl_r_encode_real(int64_t n, const double *x, const unsigned char *na, int w, int d, int e, const char *dec,
                     const char *nastr, int drop0, char **out, int64_t **off)
{
    int64_t i, *offs = (int64_t *) malloc((size_t) (n + 1) * sizeof(int64_t));
    sbuf b = {NULL, 0, 0, 0, 0};
    if (!offs) return SL_ENOMEM;
    offs[0] = 0;
    for (i = 0; i < n; i++) {
        encode1(&b, x[i], na ? na[i] != 0 : is_na(x[i]), w, d, e, dec, nastr, drop0);
        offs[i + 1] = b.n;
    }
    return finish_strs(&b, offs, n, out, off);
}

/* as.character eines Doubles (StringFromReal, 15 Stellen) nach b */
static void real_to_str(sbuf *b, double x, int scipen, const char *dec)
{
    int w, d, e;
    sl_r_format_real(1, &x, NULL, 15, 0, scipen, &w, &d, &e);
    encode1(b, x, is_na(x), w, d, e, dec, "NA", 1);
}

int sl_r_as_character_real(int64_t n, const double *x, int scipen, const char *dec, char **out, int64_t **off)
{
    int64_t i, *offs = (int64_t *) malloc((size_t) (n + 1) * sizeof(int64_t));
    sbuf b = {NULL, 0, 0, 0, 0};
    if (!offs) return SL_ENOMEM;
    offs[0] = 0;
    for (i = 0; i < n; i++) {
        real_to_str(&b, x[i], scipen, dec);
        offs[i + 1] = b.n;
    }
    return finish_strs(&b, offs, n, out, off);
}

/* ── str_signif (formatC) ───────────────────────────────────────────────── */

static void put_cut(sbuf *b, const char *s, int len, int64_t lim)
{
    if (len < 0) len = 0;
    sb_put(b, s, len < lim ? len : lim);
}

int sl_r_str_signif(sl_ctx *cx, int64_t n, const double *x, int isint, int width, int digits, const char *format,
                    const char *flag, const int64_t *istrlen, char **out, int64_t **off)
{
    int dig = abs(digits), rm0 = digits >= 0, dofg = strcmp(format, "fg") == 0, aw = abs(width);
    int64_t i, *offs;
    char form[64], f0[64], tmp[MAXLINE_ + 512];
    sbuf b = {NULL, 0, 0, 0, 0};
    if (width == 0) return sl_fail(cx, SL_EARG, "width cannot be zero");
    if (strlen(flag) > 16 || strlen(format) > 8) return sl_fail(cx, SL_EARG, "invalid format");
    offs = (int64_t *) malloc((size_t) (n + 1) * sizeof(int64_t));
    if (!offs) return SL_ENOMEM;
    offs[0] = 0;
    if (strcmp(format, "d") == 0) {
        if (!isint) { free(offs); return sl_fail(cx, SL_EARG, "'type' must be \"integer\" for  \"d\"-format"); }
        snprintf(form, sizeof form, "%%%s%s*d", flag, width < 0 ? "-" : "");
        for (i = 0; i < n; i++) {
            int len = snprintf(tmp, sizeof tmp, form, aw, (int) x[i]);
            put_cut(&b, tmp, len, istrlen[i] + 2);
            offs[i + 1] = b.n;
        }
        return finish_strs(&b, offs, n, out, off);
    }
    snprintf(form, sizeof form, "%%%s%s*.*%s", flag, width < 0 ? "-" : "", dofg ? "g" : format);
    snprintf(f0, sizeof f0, "%%%s.*f", flag);
    for (i = 0; i < n; i++) {
        double xx = x[i];
        int64_t lim = istrlen[i] + 2;
        int len;
        if (dofg) {
            if (xx == 0.0) {
                sb_put(&b, "0", 1);
            } else {
                double xxx = fabs(xx), X;
                int iex = (int) floor(log10(xxx) + 1e-12);
                X = sl_r_fround(xxx / pow(10.0, (double) iex) + 1e-12, (double) (dig - 1));
                if (iex > 0 && X >= 10) {
                    xx = X * pow(10.0, (double) iex);
                    iex++;
                }
                if (iex == -4 && fabs(xx) < 1e-4) iex = -5;
                if (iex < -4) {
                    len = snprintf(tmp, sizeof tmp, f0, dig - 1 + -iex, xx);
                    if (len < 0) len = 0;
                    if (len > lim) len = (int) lim;
                    if (len >= (int) sizeof tmp) len = (int) sizeof tmp - 1;
                    if (rm0)
                        while (len > 0 && tmp[len - 1] == '0') len--;
                    sb_put(&b, tmp, len);
                } else {
                    len = snprintf(tmp, sizeof tmp, form, aw, iex >= dig ? iex + 1 : dig, xx);
                    put_cut(&b, tmp, len, lim);
                }
            }
        } else {
            len = snprintf(tmp, sizeof tmp, form, aw, dig, xx);
            put_cut(&b, tmp, len, lim);
        }
        offs[i + 1] = b.n;
    }
    return finish_strs(&b, offs, n, out, off);
}

/* ── sprintf ─────────────────────────────────────────────────────────────── */

#define SPEC_CHARS "diosfeEgGxXaA"

typedef struct {
    int type;               /* SL_RS_* nach der Umwandlung */
    int64_t n;
    const int32_t *iv;
    const double *dv;
    const char *const *sv;  /* Text je Element (NULL = NA) */
    int32_t *own_i;         /* eigene Felder nach Umwandlung */
    double *own_d;
    char **own_s;
    int coerced;
} sarg;

static void sarg_free(sarg *a)
{
    int64_t i;
    free(a->own_i);
    free(a->own_d);
    if (a->own_s) {
        for (i = 0; i < a->n; i++) free(a->own_s[i]);
        free(a->own_s);
    }
}

static char *dupn(const char *s, int64_t n)
{
    char *p = (char *) malloc((size_t) n + 1);
    if (p) { memcpy(p, s, (size_t) n); p[n] = 0; }
    return p;
}

/* Position des Umwandlungszeichens (findspec) */
static size_t findspec(const char *f)
{
    size_t p = 1;
    if (f[0] != '%') return 0;
    while (f[p] && (strchr("-+ #.*", f[p]) || (f[p] >= '0' && f[p] <= '9'))) p++;
    return p;
}

static int checkfmt(const char *f, const char *pattern)
{
    size_t p;
    if (f[0] != '%') return 1;
    p = findspec(f);
    if (!f[p]) return 1;
    return strchr(pattern, f[p]) == NULL;
}

/* eine Umwandlung über snprintf (direkt in den Puffer, wenn er reicht); Fehler bei mehr als 8192 Bytes */
static int cvt(sl_ctx *cx, sbuf *b, const char *fmt, int kind, int32_t iv, double dv, const char *sv)
{
    char tmp[MAXLINE_ + 1];
    int nc;
    if (!b->bad && b->p && b->cap - b->n > 1) {
        size_t room = (size_t) (b->cap - b->n);
        if (kind == 0) nc = snprintf(b->p + b->n, room, fmt, (int) iv);
        else if (kind == 1) nc = snprintf(b->p + b->n, room, fmt, dv);
        else nc = snprintf(b->p + b->n, room, fmt, sv);
        if (nc >= 0 && (size_t) nc < room) {
            if (nc > MAXLINE_)
                return sl_fail(cx, SL_EARG, "required resulting string length %d is greater than maximal %d", nc, MAXLINE_);
            b->n += nc;
            return 0;
        }
        b->p[b->n] = 0;
    }
    if (kind == 0) nc = snprintf(tmp, sizeof tmp, fmt, (int) iv);
    else if (kind == 1) nc = snprintf(tmp, sizeof tmp, fmt, dv);
    else nc = snprintf(tmp, sizeof tmp, fmt, sv);
    if (nc < 0) nc = 0;
    if (nc > MAXLINE_)
        return sl_fail(cx, SL_EARG, "required resulting string length %d is greater than maximal %d", nc, MAXLINE_);
    sb_put(b, tmp, nc);
    return 0;
}

/* Format mit anderem Umwandlungszeichen: f bis ausschließlich pos, dann conv */
static void with_conv(char *dst, size_t cap, const char *f, size_t pos, char conv)
{
    size_t k = pos < cap - 2 ? pos : cap - 2;
    memcpy(dst, f, k);
    dst[k] = conv;
    dst[k + 1] = 0;
}

/* %n$ am Anfang von s (nach dem ersten Zeichen): Rückgabe Argumentnummer (1-basiert) und Länge, sonst 0 */
static int dollar(const char *s, size_t len, int *skip)
{
    if (len > 3 && s[1] >= '1' && s[1] <= '9') {
        int v = s[1] - '0';
        if (s[2] == '$') { *skip = 3; return v; }
        if (s[2] >= '0' && s[2] <= '9' && len > 4 && s[3] == '$') { *skip = 4; return 10 * v + (s[2] - '0'); }
    }
    return 0;
}

static int coerce_once(sarg *a, char sc, int scipen, const char *dec)
{
    int64_t i;
    if (a->coerced) return 0;
    a->coerced = 1;
    if (strchr("dioxX", sc)) {
        if (a->type == SL_RS_DBL) {
            int exact = 1;
            for (i = 0; i < a->n && exact; i++) {
                double r = a->dv[i];
                if (is_na(r)) continue;
                if (!isfinite(r) || !(fabs(r) < 2147483648.0) || trunc(r) != r) exact = 0;
            }
            if (exact) {
                a->own_i = (int32_t *) malloc((size_t) (a->n > 0 ? a->n : 1) * sizeof(int32_t));
                if (!a->own_i) return SL_ENOMEM;
                for (i = 0; i < a->n; i++) a->own_i[i] = is_na(a->dv[i]) ? NA_INT_ : (int32_t) a->dv[i];
                a->iv = a->own_i;
                a->type = SL_RS_INT;
                a->sv = NULL;
            }
        }
    } else if (strchr("aAefgEG", sc)) {
        if (a->type == SL_RS_LGL || a->type == SL_RS_INT || a->type == SL_RS_FACTOR) {
            a->own_d = (double *) malloc((size_t) (a->n > 0 ? a->n : 1) * sizeof(double));
            if (!a->own_d) return SL_ENOMEM;
            for (i = 0; i < a->n; i++) {
                double na = 0;
                uint64_t u = UINT64_C(0x7FF00000000007A2);
                memcpy(&na, &u, sizeof na);
                a->own_d[i] = a->iv[i] == NA_INT_ ? na : (double) a->iv[i];
            }
            a->dv = a->own_d;
            a->type = SL_RS_DBL;
            a->sv = NULL;
        }
    } else if (sc == 's') {
        if (a->type != SL_RS_CHR) {
            if (!a->sv) {
                a->own_s = (char **) calloc((size_t) (a->n > 0 ? a->n : 1), sizeof(char *));
                if (!a->own_s) return SL_ENOMEM;
                for (i = 0; i < a->n; i++) {
                    char t[64];
                    if (a->type == SL_RS_DBL) {
                        sbuf b = {NULL, 0, 0, 0, 0};
                        if (is_na(a->dv[i])) continue;
                        real_to_str(&b, a->dv[i], scipen, dec);
                        if (b.bad) return SL_ENOMEM;
                        a->own_s[i] = b.p;
                    } else {
                        if (a->iv[i] == NA_INT_) continue;
                        if (a->type == SL_RS_LGL) snprintf(t, sizeof t, "%s", a->iv[i] ? "TRUE" : "FALSE");
                        else snprintf(t, sizeof t, "%d", (int) a->iv[i]);
                        a->own_s[i] = dupn(t, (int64_t) strlen(t));
                        if (!a->own_s[i]) return SL_ENOMEM;
                    }
                }
                a->sv = (const char *const *) a->own_s;
            }
            a->type = SL_RS_CHR;
        }
    }
    return 0;
}

/* Kern von sprintf: Ergebnisse nach *pb (ext: Stapel des Aufrufers), Grenzen nach offs (maxlen + 1 Plätze, NULL:
 * malloc, dann *poffs); Rückgabe Status; ohne Fehler *nout und *nunused */
static int sprintf_impl(sl_ctx *cx, int64_t nfmt, const char *const *fmt, int nargs, const int *type, const int64_t *len,
                        const void *const *data, const char *const *const *str, int scipen, const char *dec, sbuf *pb,
                        int64_t *offs_ext, int64_t **poffs, int64_t *nout, int *nunused)
{
    enum { NSTACK = 16 };
    sarg a_st[NSTACK];
    char used_st[NSTACK];
    sarg *a = NULL;
    char *used = NULL;
    int64_t maxlen, ns, *offs = NULL;
    int k, st = 0;
    sbuf b = *pb;   /* Kopie, zurück nach *pb an den Ausgängen done/empty */
    char spec[MAXLINE_ + 64], fmtp[MAXLINE_ + 64], f2[MAXLINE_ + 64];
    *nout = 0;
    *nunused = 0;
    *poffs = NULL;
    if (nfmt == 0) goto empty;
    for (k = 0; k < nargs; k++)
        if (len[k] == 0) goto empty;
    maxlen = nfmt;
    for (k = 0; k < nargs; k++)
        if (len[k] > maxlen) maxlen = len[k];
    if (maxlen % nfmt) return sl_fail(cx, SL_EARG, "arguments cannot be recycled to the same length");
    for (k = 0; k < nargs; k++)
        if (maxlen % len[k]) return sl_fail(cx, SL_EARG, "arguments cannot be recycled to the same length");
    if (nargs <= NSTACK) {
        memset(a_st, 0, sizeof a_st);
        memset(used_st, 0, sizeof used_st);
        a = a_st;
        used = used_st;
    } else {
        a = (sarg *) calloc((size_t) nargs, sizeof(sarg));
        used = (char *) calloc((size_t) nargs, 1);
    }
    offs = offs_ext && maxlen == 1 ? offs_ext : (int64_t *) malloc((size_t) (maxlen + 1) * sizeof(int64_t));
    if (!a || !used || !offs) { st = SL_ENOMEM; goto done; }
    for (k = 0; k < nargs; k++) {
        a[k].type = type[k];
        a[k].n = len[k];
        if (type[k] == SL_RS_DBL || type[k] == SL_RS_DATE) a[k].dv = (const double *) data[k];
        else if (type[k] != SL_RS_CHR) a[k].iv = (const int32_t *) data[k];
        a[k].sv = str ? str[k] : NULL;
    }
    offs[0] = 0;
    for (ns = 0; ns < maxlen; ns++) {
        const char *f = fmt[ns % nfmt] ? fmt[ns % nfmt] : "NA";
        size_t n = strlen(f), cur = 0;
        int cnt = 0;
        while (cur < n) {
            if (f[cur] == '%') {
                size_t j, sl, pstar;
                int nthis = -1, has_star = 0, skip = 0, v;
                int32_t star_arg = 0;
                char *sp;
                sarg *th;
                int64_t i;
                char sc;
                if (cur < n - 1 && f[cur + 1] == '%') {
                    sb_put(&b, "%", 1);
                    cur += 2;
                    continue;
                }
                j = cur + 1;
                while (j < n && !strchr(SPEC_CHARS, f[j])) j++;
                if (j >= n) { st = sl_fail(cx, SL_EARG, "unrecognised format specification '%s'", f + cur); goto done; }
                sl = j - cur + 1;
                if (sl > MAXLINE_) { st = sl_fail(cx, SL_EARG, "'fmt' length exceeds maximal format length %d", MAXLINE_); goto done; }
                memcpy(spec, f + cur, sl);
                spec[sl] = 0;
                cur = j + 1;
                v = dollar(spec, sl, &skip);
                if (v) {
                    if (v > nargs) { st = sl_fail(cx, SL_EARG, "reference to non-existent argument %d", v); goto done; }
                    nthis = v - 1;
                    memmove(spec + 1, spec + skip, strlen(spec + skip) + 1);
                }
                sp = strchr(spec, '*');
                if (sp) {
                    int nstar = -1;
                    sarg *s;
                    pstar = (size_t) (sp - spec);
                    v = dollar(sp, strlen(sp), &skip);
                    if (v) {
                        if (v > nargs) { st = sl_fail(cx, SL_EARG, "reference to non-existent argument %d", v); goto done; }
                        nstar = v - 1;
                        memmove(sp + 1, sp + skip, strlen(sp + skip) + 1);
                    }
                    if (nstar < 0) {
                        if (cnt >= nargs) { st = sl_fail(cx, SL_EARG, "too few arguments"); goto done; }
                        nstar = cnt++;
                    }
                    if (strchr(spec + pstar + 1, '*')) {
                        st = sl_fail(cx, SL_EARG, "at most one asterisk '*' is supported in each conversion specification");
                        goto done;
                    }
                    s = &a[nstar];
                    used[nstar] = 1;
                    if (ns == 0 && s->type == SL_RS_DBL && !s->own_i) {
                        s->own_i = (int32_t *) malloc((size_t) (s->n > 0 ? s->n : 1) * sizeof(int32_t));
                        if (!s->own_i) { st = SL_ENOMEM; goto done; }
                        for (i = 0; i < s->n; i++) {
                            double r = s->dv[i];
                            s->own_i[i] = (isnan(r) || !(fabs(r) < 2147483648.0)) ? NA_INT_ : (int32_t) r;
                        }
                        s->iv = s->own_i;
                        s->type = SL_RS_INT;
                    }
                    if (s->type != SL_RS_INT || s->n < 1 || s->iv[ns % s->n] == NA_INT_) {
                        st = sl_fail(cx, SL_EARG, "argument for '*' conversion specification must be a number");
                        goto done;
                    }
                    star_arg = s->iv[ns % s->n];
                    has_star = 1;
                }
                if (spec[strlen(spec) - 1] == '%') {
                    if (has_star) { if ((st = cvt(cx, &b, spec, 0, star_arg, 0, NULL))) goto done; }
                    else sb_put(&b, spec, (int64_t) strlen(spec));
                    continue;
                }
                if (nthis < 0) {
                    if (cnt >= nargs) { st = sl_fail(cx, SL_EARG, "too few arguments"); goto done; }
                    nthis = cnt++;
                }
                used[nthis] = 1;
                if (has_star) {
                    size_t ps = (size_t) (strchr(spec, '*') - spec);
                    char num[32];
                    snprintf(num, sizeof num, "%d", (int) star_arg);
                    memcpy(fmtp, spec, ps);
                    fmtp[ps] = 0;
                    strcat(fmtp, num);
                    strcat(fmtp, spec + ps + 1);
                } else {
                    strcpy(fmtp, spec);
                }
                th = &a[nthis];
                {
                    size_t p = findspec(fmtp);
                    sc = fmtp[p] ? fmtp[p] : fmtp[strlen(fmtp) - 1];
                }
                if (ns == 0 && (st = coerce_once(th, sc, scipen, dec))) goto done;
                i = ns % th->n;
                switch (th->type) {
                case SL_RS_LGL:
                    if (checkfmt(fmtp, "di")) {
                        st = sl_fail(cx, SL_EARG, "invalid format '%s'; use format %%d or %%i for logical objects", fmtp);
                        goto done;
                    }
                    if (th->iv[i] == NA_INT_) {
                        with_conv(f2, sizeof f2, fmtp, strlen(fmtp) - 1, 's');
                        st = cvt(cx, &b, f2, 2, 0, 0, "NA");
                    } else {
                        st = cvt(cx, &b, fmtp, 0, th->iv[i] != 0, 0, NULL);
                    }
                    break;
                case SL_RS_INT: case SL_RS_FACTOR:
                    if (checkfmt(fmtp, "dioxX")) {
                        st = sl_fail(cx, SL_EARG, "invalid format '%s'; use format %%d, %%i, %%o, %%x or %%X for integer objects", fmtp);
                        goto done;
                    }
                    if (th->iv[i] == NA_INT_) {
                        with_conv(f2, sizeof f2, fmtp, strlen(fmtp) - 1, 's');
                        st = cvt(cx, &b, f2, 2, 0, 0, "NA");
                    } else {
                        st = cvt(cx, &b, fmtp, 0, th->iv[i], 0, NULL);
                    }
                    break;
                case SL_RS_DBL: case SL_RS_DATE: {
                    double x = th->dv[i];
                    if (checkfmt(fmtp, "aAfeEgG")) {
                        st = sl_fail(cx, SL_EARG, "invalid format '%s'; use format %%f, %%e, %%g or %%a for numeric objects", fmtp);
                        goto done;
                    }
                    if (isfinite(x)) {
                        st = cvt(cx, &b, fmtp, 1, 0, x, NULL);
                    } else {
                        char *dot = strchr(fmtp, '.');
                        int spc;
                        with_conv(f2, sizeof f2, fmtp, dot ? (size_t) (dot - fmtp) : strlen(fmtp) - 1, 's');
                        spc = strchr(f2, ' ') != NULL;
                        if (isnan(x)) {
                            const char *word = is_na(x) ? (spc ? " NA" : "NA") : (spc ? " NaN" : "NaN");
                            st = cvt(cx, &b, f2, 2, 0, 0, word);
                        } else if (x > 0) {
                            st = cvt(cx, &b, f2, 2, 0, 0, strchr(f2, '+') ? "+Inf" : (spc ? " Inf" : "Inf"));
                        } else {
                            st = cvt(cx, &b, f2, 2, 0, 0, "-Inf");
                        }
                    }
                    break;
                }
                default: {
                    const char *s;
                    if (checkfmt(fmtp, "s")) {
                        st = sl_fail(cx, SL_EARG, "invalid format '%s'; use format %%s for character objects", fmtp);
                        goto done;
                    }
                    s = th->sv && th->sv[i] ? th->sv[i] : "NA";
                    if (fmtp[1] != 's') st = cvt(cx, &b, fmtp, 2, 0, 0, s);
                    else sb_put(&b, s, (int64_t) strlen(s));
                    break;
                }
                }
                if (st) goto done;
            } else {
                size_t j = cur;
                while (j < n && f[j] != '%') j++;
                sb_put(&b, f + cur, (int64_t) (j - cur));
                cur = j;
            }
        }
        if (b.bad) { st = SL_ENOMEM; goto done; }
        offs[ns + 1] = b.n;
    }
    for (k = 0; k < nargs; k++)
        if (!used[k]) (*nunused)++;
    *nout = maxlen;
done:
    *pb = b;
    if (a) for (k = 0; k < nargs; k++) sarg_free(&a[k]);
    if (a != a_st) free(a);
    if (used != used_st) free(used);
    if (st) {
        if (offs != offs_ext) free(offs);
        if (st == SL_ENOMEM) return sl_fail(cx, SL_ENOMEM, "out of memory");
        return st;
    }
    *poffs = offs;
    return 0;
empty:
    *pb = b;
    offs = offs_ext ? offs_ext : (int64_t *) malloc(sizeof(int64_t));
    if (!offs) return SL_ENOMEM;
    offs[0] = 0;
    *poffs = offs;
    return 0;
}

int sl_r_sprintf(sl_ctx *cx, int64_t nfmt, const char *const *fmt, int nargs, const int *type, const int64_t *len,
                 const void *const *data, const char *const *const *str, int scipen, const char *dec, char **out,
                 int64_t **off, int64_t *nout, int *nunused)
{
    sbuf b = {NULL, 0, 0, 0, 0};
    int64_t *offs = NULL;
    int st;
    *out = NULL;
    *off = NULL;
    st = sprintf_impl(cx, nfmt, fmt, nargs, type, len, data, str, scipen, dec, &b, NULL, &offs, nout, nunused);
    if (st) {
        free(b.p);
        return st;
    }
    return finish_strs(&b, offs, *nout, out, off);
}

/* sprintf für ein Format und skalare Argumente (schneller Weg der Engine-Texte): Ergebnis nach out (höchstens cap Bytes,
 * ohne abschließende 0); Rückgabe die volle Länge (> cap: mit größerem Puffer wiederholen), -1 bei Fehler (Text nach
 * err, höchstens errcap Bytes mit 0), -2 ohne Speicher. Argumente: Typ je Wert, Double dv[k] bzw. Int32 iv[k], Text
 * sv[k] (character, Date). */
int64_t sl_r_sprintf1(const char *fmt, int nargs, const int *type, const double *dv, const int32_t *iv,
                      const char *const *sv, int scipen, const char *dec, char *out, int64_t cap, char *err,
                      int64_t errcap, int *nunused)
{
    enum { NMAX = 16 };
    const void *data[NMAX];
    const char *const *str[NMAX];
    int64_t len[NMAX], nout = 0, offs[2], *po = NULL, n;
    char stack[1024];
    sbuf b = {stack, 0, (int64_t) sizeof stack, 0, 1};
    sl_ctx cx;
    int k, st;
    if (nargs > NMAX) {
        snprintf(err, (size_t) errcap, "%s", "zu viele Argumente");
        return -1;
    }
    for (k = 0; k < nargs; k++) {
        data[k] = (type[k] == SL_RS_DBL || type[k] == SL_RS_DATE) ? (const void *) (dv + k)
                  : type[k] == SL_RS_CHR ? NULL : (const void *) (iv + k);
        str[k] = (type[k] == SL_RS_CHR || type[k] == SL_RS_DATE) ? sv + k : NULL;
        len[k] = 1;
    }
    /* nur die Felder setzen, die sl_fail braucht (sl_ctx_init löscht 2,6 KB) */
    cx.status = 0;
    cx.msg[0] = 0;
    cx.n_warn = 0;
    cx.interrupted = NULL;
    cx.host = NULL;
    stack[0] = 0;
    st = sprintf_impl(&cx, 1, &fmt, nargs, type, len, data, str, scipen, dec, &b, offs, &po, &nout, nunused);
    if (st) {
        if (!b.ext) free(b.p);
        if (st == SL_ENOMEM) return -2;
        snprintf(err, (size_t) errcap, "%s", cx.msg);
        return -1;
    }
    if (b.bad) return -2;
    n = nout > 0 ? po[1] - po[0] : 0;
    if (n <= cap && n > 0) memcpy(out, b.p + po[0], (size_t) n);
    if (po != offs) free(po);
    if (!b.ext) free(b.p);
    return n;
}
