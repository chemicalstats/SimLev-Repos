/* core/slc_special.c – lgamma, unvollständige Beta, t-Verteilung, logistisch (SimLev core, Etappe 9)
 * Verfahren:  lgamma(x), x > 0:
 *               x >= 10: Stirling-Reihe DLMF 5.11.1 mit 8 Gliedern B_2k/(2k(2k-1) x^(2k-1)),
 *                 gebildet als (x - 1/2)(ln x - 1) - 1/2 + ln sqrt(2 pi) + omega(x);
 *               1.5 < x <= 2.5: ln Gamma(2 + e) = (1 - gamma) e + sum_{k=2}^{30} (-1)^k (zeta(k) - 1)
 *                 e^k / k mit e = x - 2 exakt (DLMF 5.7.3 und ln Gamma(2+e) = ln Gamma(1+e) + ln(1+e));
 *               0.5 <= x <= 1.5: dieselbe Reihe mit e = x - 1, minus log1p(e);
 *               0 < x < 0.5: Reihe mit e = x, minus log1p(x), minus ln x (DLMF 5.5.1);
 *               2.5 < x < 10: Rekursion DLMF 5.5.1 nach unten in (1.5, 2.5] (höchstens 8 Faktoren
 *                 x - k, exakt darstellbar), Produkt im Logarithmus addiert.
 *             Unvollständige Beta I_x(a, b): Kettenbruch DLMF 8.17.22 mit den Gliedern 8.17.23,
 *               als gerader Teil mit selbst umgeformten Teilnennern ohne Auslöschung (siehe ibeta_cf);
 *               Tiefe per modifiziertem Lentz-Verfahren, ab 40 Stufen Auswertung von unten.
 *               Orientierung: für x > (a + 1)/(a + b + 2) die Symmetrie 8.17.4; bei genau einem
 *               großen Parameter steht dieser vorn, außer die Variable des kleinen liegt klar unter
 *               der Schwelle (siehe ibeta_eval). Beide Enden werden zurückgegeben
 *               (das direkt berechnete genau, das andere als 1 - ...). Vorfaktor
 *               x^a (1 - x)^b / (a B(a, b)) im Logarithmus:
 *               - a, b < 10: ln B = lgamma(a) + lgamma(b) - lgamma(a + b);
 *               - genau eines >= 10 (p < 10 <= q): ln B = lgamma(p) + ln Gamma(q) - ln Gamma(q + p),
 *                 die Differenz über die Stirling-Reihe als -(q - 1/2) log1p(p/q) - p ln(q + p) + p
 *                 + omega(q) - omega(q + p) ohne Auslöschung;
 *               - a, b >= 10: ln Vorfaktor = a l(t1) + b l(t2) + 1/2 ln(b/(a s)) - ln sqrt(2 pi)
 *                 - (omega(a) + omega(b) - omega(s)), s = a + b, t1 = D/a, t2 = -D/b,
 *                 D = x s - a (exaktes Produkt nach Dekker), l(t) = log1p(t) - t; für
 *                 -1/2 <= t <= 1 über u = t/(2 + t): l(t) = -t u + 2 u^3 sum u^(2k)/(2k + 3)
 *                 (log1p(t) = 2 artanh u, DLMF 4.6.4; die linearen Glieder heben sich exakt).
 *             pt(t, nu): A&S 26.7.1 mit 26.5.27: P(T <= -|t|) = I_x(nu/2, 1/2) / 2,
 *               x = nu/(nu + t^2), 1 - x = t^2/(nu + t^2) je einzeln ohne Auslöschung gebildet; das
 *               andere Ende über die Symmetrie in t (1/2 + I_(1-x)(1/2, nu/2)/2, wo dieses Ende direkt
 *               berechnet ist). nu = Inf: Normalverteilung. Kein Wechsel auf die Normalverteilung für
 *               große endliche nu (in 9.1 gemessen: bei nu = 4e5 wäre der Fehler 3e-7).
 *             qt(p, nu): nu = 1 exakt über tan (p >= 1/4: tan(pi (p - 1/2)), sonst -1/tan(pi p));
 *               nu = 2 exakt: t = -(1 - 2p)/sqrt(2 p (1 - p)) aus F(t) = 1/2 + t/(2 sqrt(2 + t^2));
 *               sonst Startwert aus der Entwicklung um das Normalquantil (A&S 26.7.5, vier Glieder)
 *               bzw. für |t| > 2 sqrt(nu) aus dem Randverhalten P(T < -t) ~ nu^(nu/2 - 1) t^-nu / B,
 *               danach Newton-Schritte auf F(t) - p (für p < 0.01 auf ln F(t) - ln p in der Variablen
 *               u = ln|t|, in der der Potenzrand linear ist; Überlauf: -DBL_MAX bzw. -Inf) mit
 *               Einschluss; verlässt ein Schritt das Intervall, wird halbiert (bzw. verdoppelt);
 *               bis |Delta| <= 1e-14 |t|, höchstens 50 Schritte. Unteres Ende über qt(p) =
 *               -qt(1 - p) für p > 1/2 (1 - p exakt) und oberes Ende über die Symmetrie.
 *             plogis(x) = 1/(1 + e^-x) für x >= 0, sonst e^x/(1 + e^x); qlogis(p) = ln p - log1p(-p),
 *             für 1/3 <= p <= 2/3 als log1p((2p - 1)/(1 - p)) ohne Auslöschung (2p - 1 exakt).
 * Quellen:    Olver, F. W. J. u. a. (Hrsg.). NIST Digital Library of Mathematical Functions,
 *               https://dlmf.nist.gov/, Release 1.2: 4.6.4, 5.5.1, 5.7.3, 5.11.1, 8.17.4, 8.17.22,
 *               8.17.23, 24.2 (Bernoulli-Zahlen), 3.10(iii).
 *             Abramowitz, M., Stegun, I. A. (1964). Handbook of Mathematical Functions. National
 *               Bureau of Standards, Applied Mathematics Series 55: 26.5.27, 26.7.1,
 *               26.7.5.
 *             Lentz (1976); Thompson, Barnett (1986), Abschnitt 3 (Lentz-Verfahren); Dekker (1971)
 *               (exaktes Produkt mit Teilung nach Veltkamp) – vollständige Angaben in slc_normal.c.
 * Konstanten: selbst hergeleitet (core/tools/gen_constants.py): Bernoulli-Glieder der Stirling-
 *             Reihe, gamma und zeta(k) - 1 (Euler-Maclaurin), ln sqrt(2 pi), ln sqrt(pi), pi.
 *             Aus der Quelle: die Polynome g1 ... g4 von A&S 26.7.5 (nur Startwert).
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: R 4.3.3 lgamma, pbeta, pt, qt, plogis, qlogis (scratchpad/e91/).
 */
#define SLC_NEED_GAMMA_TABLES
#include "slc_internal.h"
#include "slc_constants.h"

#include <float.h>

#define BIG 10.0

/* ── lgamma ── */

/* omega(x) = sum_{k=1}^{8} B_2k / (2k (2k-1) x^(2k-1)), x >= 10 */
static double stirling_omega(double x)
{
    double w = 1.0 / (x * x), s = 0.0;
    int k;
    for (k = SLC_STIRLING_N - 1; k >= 0; k--) s = slc_stirling[k] + w * s;
    return s / x;
}

/* ln Gamma(2 + e), |e| <= 1/2 */
static double lg2(double e)
{
    double s = 0.0;
    int k;
    for (k = SLC_LG2_N - 1; k >= 0; k--) s = slc_lg2[k] + e * s;
    return e * s;
}

double slc_lgamma_pos(double x)
{
    if (x >= BIG) {
        if (isinf(x)) return x;
        return (x - 0.5) * (log(x) - 1.0) - 0.5 + SLC_LN_SQRT2PI + stirling_omega(x);
    }
    if (x > 2.5) {
        double prod = 1.0, y = x;
        while (y > 2.5) { y -= 1.0; prod *= y; }     /* y = x - k exakt */
        return lg2(y - 2.0) + log(prod);
    }
    if (x > 1.5) return lg2(x - 2.0);
    if (x >= 0.5) return lg2(x - 1.0) - log1p(x - 1.0);
    return lg2(x) - log1p(x) - log(x);
}

double sl_lgamma1(double x)
{
    if (isnan(x)) return x;
    if (!(x > 0)) return NAN;
    return slc_lgamma_pos(x);
}

int sl_lgamma(sl_ctx *cx, int64_t n, const double *x, double *out)
{
    int64_t i;
    int warned = 0;
    for (i = 0; i < n; i++) {
        double xi = x[i];
        if (isnan(xi)) out[i] = xi;
        else if (!(xi > 0)) { out[i] = NAN; warned = 1; }
        else out[i] = slc_lgamma_pos(xi);
        SL_POLL(cx, i);
    }
    if (warned) sl_warn(cx, "lgamma: NaN erzeugt");
    return SL_OK;
}

/* ── unvollständige Beta ── */

/* l(t) = log1p(t) - t, t > -1 */
static double log1pmx(double t)
{
    if (t >= -0.5 && t <= 1.0) {
        double u = t / (2.0 + t), u2 = u * u, s = 0.0;
        int k;
        for (k = 20; k >= 0; k--) s = 1.0 / (double) (2 * k + 3) + u2 * s;
        return -t * u + 2.0 * u * u2 * s;
    }
    return log1p(t) - t;
}

/* exaktes Produkt a * b = p + e (Dekker 1971, Teilung nach Veltkamp) */
static double two_prod(double a, double b, double *e)
{
    const double C = 134217729.0;
    double p = a * b, ca = C * a, cb = C * b;
    double ah = ca - (ca - a), al = a - ah, bh = cb - (cb - b), bl = b - bh;
    *e = ((ah * bh - p) + ah * bl + al * bh) + al * bl;
    return p;
}

typedef struct {
    double a, b;          /* Parameter */
    int kind;             /* 0: beide < BIG; 1: genau einer >= BIG; 2: beide >= BIG */
    double lnB;           /* kind 0, 1 */
    double lna, lnb;      /* ln a, ln b */
    double dom;           /* kind 2: omega(a) + omega(b) - omega(a + b) */
    double ha, hb;        /* kind 2: 1/2 ln(b/(a s)), 1/2 ln(a/(b s)) */
} ibeta_par;

static void ibeta_init(ibeta_par *P, double a, double b)
{
    double p = (a < b) ? a : b, q = (a < b) ? b : a, s = a + b;
    P->a = a;
    P->b = b;
    P->lna = log(a);
    P->lnb = log(b);
    P->lnB = 0.0;
    P->dom = 0.0;
    P->ha = P->hb = 0.0;
    if (q < BIG) {
        P->kind = 0;
        P->lnB = slc_lgamma_pos(a) + slc_lgamma_pos(b) - slc_lgamma_pos(s);
    } else if (p < BIG) {
        P->kind = 1;
        P->lnB = slc_lgamma_pos(p)
                 + (-(q - 0.5) * log1p(p / q) - p * log(q + p) + p
                    + stirling_omega(q) - stirling_omega(q + p));
    } else {
        P->kind = 2;
        P->dom = stirling_omega(a) + stirling_omega(b) - stirling_omega(s);
        P->ha = 0.5 * (P->lnb - P->lna - log(s));
        P->hb = 0.5 * (P->lna - P->lnb - log(s));
    }
}

/* ln(x^a y^b / (a B(a, b))) in der Orientierung (a, b) = swap ? (P->b, P->a) : (P->a, P->b);
 * y = 1 - x; lx = ln x, ly = ln y (vom Aufrufer genau gebildet, auch wenn x oder y unterläuft) */
static double ibeta_lnpre(const ibeta_par *P, int swap, double x, double y, double lx, double ly)
{
    double a = swap ? P->b : P->a, b = swap ? P->a : P->b;
    if (P->kind == 2) {
        double s = a + b, Dv, e, t1, t2, l1, l2;
        if (x <= y) { Dv = two_prod(x, s, &e); Dv = (Dv - a) + e; }       /* x s - a */
        else { Dv = two_prod(y, s, &e); Dv = b - Dv - e; }                /* b - y s */
        t1 = Dv / a;                                                      /* x s/a - 1 */
        t2 = -Dv / b;                                                     /* y s/b - 1 */
        /* l = ln(1 + t) - t; nahe 0 über die Reihe, sonst direkt (keine Auslöschung) */
        l1 = (t1 >= -0.5 && t1 <= 1.0) ? log1pmx(t1) : (lx + log(s / a)) - t1;
        l2 = (t2 >= -0.5 && t2 <= 1.0) ? log1pmx(t2) : (ly + log(s / b)) - t2;
        return a * l1 + b * l2 + (swap ? P->hb : P->ha) - SLC_LN_SQRT2PI - P->dom;
    }
    return a * lx + b * ly - (swap ? P->lnb : P->lna) - P->lnB;
}

/* Kettenbruch DLMF 8.17.22 (Glieder 8.17.23) als gerader Teil (Zusammenziehen je zweier Stufen):
 *   K = 1/(beta_0 + alpha_1/(beta_1 + alpha_2/(beta_2 + ...))),
 *   beta_0 = 1 + d_1, beta_m = 1 + d_2m + d_2m+1, alpha_m = -d_2m-1 d_2m (m >= 1).
 * Die Teilnenner werden mit y = 1 - x umgeformt, damit sie ohne Auslöschung entstehen
 * (selbst hergeleitet, c = a + 2m):
 *   beta_0 = (1 - b + (a + b) y)/(a + 1),
 *   beta_m = [c (a (2m + 1 - b) + 2m^2 + b - 1) + y C] / ((c - 1) c (c + 1)),
 *   C = (c - 1)(a + m)(a + b + m) - m (b - m)(c + 1);
 * für b < 1 sind alle Summanden positiv. Diese Form gilt für x >= 1/2 (dort liegt d_2m+1 nahe -1);
 * für x < 1/2 sind alle |d_k| klein und die Teilnenner werden direkt summiert. */
static double cf_beta0(double a, double b, double x, double y)
{
    return (x >= 0.5) ? (1.0 - b + (a + b) * y) / (a + 1.0) : 1.0 - (a + b) * x / (a + 1.0);
}

/* Teilnenner beta_m und Teilzähler alpha_m (m >= 1) */
static void cf_terms(double a, double b, double x, double y, long m, double *beta, double *alpha)
{
    double dm = (double) m, c = a + 2.0 * dm;
    if (x >= 0.5) {         /* umgeformt (d_2m+1 nahe -1) */
        double Cc = (c - 1.0) * (a + dm) * (a + b + dm) - dm * (b - dm) * (c + 1.0);
        *beta = (c * (a * (2.0 * dm + 1.0 - b) + 2.0 * dm * dm + b - 1.0) + y * Cc)
                / ((c - 1.0) * c * (c + 1.0));
    } else {                /* direkt 1 + d_2m + d_2m+1 (|d| klein) */
        *beta = 1.0 + dm * (b - dm) * x / ((c - 1.0) * c)
                - (a + dm) * (a + b + dm) * x / (c * (c + 1.0));
    }
    *alpha = (a + dm - 1.0) * (a + b + dm - 1.0) * dm * (b - dm) * x * x
             / ((c - 2.0) * (c - 1.0) * (c - 1.0) * c);
}

/* Das Lentz-Verfahren bestimmt die nötige Tiefe M (bis |Delta - 1| <= 2^-52). Braucht es mehr als
 * 40 Stufen, wird der Kettenbruch mit der Tiefe M + M/8 + 4 von unten neu ausgewertet: das
 * Produkt der Lentz-Faktoren häuft sonst Rundungsfehler an (gemessen in 9.1: 1e-11 bei
 * a = 1e6, b = 0.01); von unten werden sie gedämpft. */
static double ibeta_cf(double a, double b, double x, double y, int *conv)
{
    const double tiny = 1e-300;
    double f, C, Dd, beta, alpha;
    long m, M = 0, N;
    *conv = 1;
    f = cf_beta0(a, b, x, y);
    if (fabs(f) < tiny) f = tiny;
    C = f;
    Dd = 0.0;
    for (m = 1; m <= 100000; m++) {
        double d;
        cf_terms(a, b, x, y, m, &beta, &alpha);
        Dd = beta + alpha * Dd;
        if (fabs(Dd) < tiny) Dd = tiny;
        Dd = 1.0 / Dd;
        C = beta + alpha / C;
        if (fabs(C) < tiny) C = tiny;
        d = C * Dd;
        f *= d;
        if (fabs(d - 1.0) <= SLC_TWO_M52) { M = m; break; }
    }
    if (M == 0) { *conv = 0; return 1.0 / f; }
    if (M <= 40) return 1.0 / f;
    N = M + M / 8 + 4;
    {
        double t, an;
        cf_terms(a, b, x, y, N, &beta, &an);
        t = beta;
        for (m = N - 1; m >= 1; m--) {
            cf_terms(a, b, x, y, m, &beta, &alpha);
            t = beta + an / t;
            an = alpha;
        }
        t = cf_beta0(a, b, x, y) + an / t;
        return 1.0 / t;
    }
}

/* w = I_x(a, b), w1 = 1 - w; *direct = 0: w direkt (genau), 1: w1 direkt; *conv wie oben.
 * lx = ln x, ly = ln y vom Aufrufer (genau). */
static void ibeta_eval(const ibeta_par *P, double x, double y, double lx, double ly,
                       double *w, double *w1, int *direct, int *conv)
{
    int swap;
    double a, b, xs, ys, lxs, lys, v;
    if (P->kind == 1) {
        /* genau ein großer Parameter L, ein kleiner S: L vorn (umgeformte Teilnenner ohne
         * Auslöschung), außer die Variable v von S liegt klar unter der Schwelle ihres
         * Kettenbruchs: (S + L) v <= (S + 1)/2 bzw. (S + 1)/8 für S < 1 (dann sind alle |d_k|
         * klein); in 9.1 gemessen */
        int a_large = P->a >= P->b;
        double S = a_large ? P->b : P->a, v = a_large ? y : x;
        /* Grenze: für S < 1 liefert diese Orientierung meist das große Ende (Komplement), daher
         * enger (gemessen in 9.1, e91/tools/sfexp.py) */
        int small_first = (P->a + P->b) * v <= ((S < 1.0) ? 0.125 : 0.5) * (S + 1.0);
        swap = a_large ? small_first : !small_first;
    } else {
        /* Schwelle des Kettenbruchs (DLMF 8.17.22); zwischen Schwelle und Mittelwert a/(a + b)
         * liegt aber das kleine Ende auf der anderen Seite: ist dort der zweite Parameter < 1 und
         * die Variable >= 1/2, wird das kleine Ende direkt mit den umgeformten (positiven)
         * Teilnennern berechnet statt als Komplement (in 9.1 gemessen) */
        double mu = P->a / (P->a + P->b);
        swap = x > (P->a + 1.0) / (P->a + P->b + 2.0);
        if (swap && P->b < 1.0 && x < mu && x >= 0.5) swap = 0;
        else if (!swap && P->a < 1.0 && x > mu && y >= 0.5) swap = 1;
    }
    a = swap ? P->b : P->a;
    b = swap ? P->a : P->b;
    xs = swap ? y : x;
    ys = swap ? x : y;
    lxs = swap ? ly : lx;
    lys = swap ? lx : ly;
    *conv = 1;
    if (isinf(lxs) && lxs < 0) v = 0.0;
    else {
        double f = ibeta_cf(a, b, xs, ys, conv);
        v = exp(ibeta_lnpre(P, swap, xs, ys, lxs, lys)) * f;
        if (v > 1.0) v = 1.0;
    }
    *direct = swap;
    if (!swap) { *w = v; *w1 = 1.0 - v; }
    else { *w1 = v; *w = 1.0 - v; }
}

int sl_pbeta(sl_ctx *cx, int64_t n, const double *x, double a, double b, int lower, double *out)
{
    int64_t i;
    ibeta_par P;
    int bad = !(a > 0 && b > 0 && isfinite(a) && isfinite(b)), warned = 0, noconv = 0;
    if (!bad && !isnan(a) && !isnan(b)) ibeta_init(&P, a, b);
    for (i = 0; i < n; i++) {
        double xi = x[i], yi, w, w1, lx, ly;
        int direct, conv;
        if (isnan(xi)) { out[i] = xi; continue; }
        if (isnan(a)) { out[i] = a; continue; }
        if (isnan(b)) { out[i] = b; continue; }
        if (bad) { out[i] = NAN; warned = 1; continue; }
        if (xi <= 0) { out[i] = lower ? 0.0 : 1.0; continue; }
        if (xi >= 1) { out[i] = lower ? 1.0 : 0.0; continue; }
        yi = 1.0 - xi;                                   /* exakt für x >= 1/2 */
        lx = (xi <= 0.5) ? log(xi) : log1p(-yi);
        ly = (xi >= 0.5) ? log(yi) : log1p(-xi);
        ibeta_eval(&P, xi, yi, lx, ly, &w, &w1, &direct, &conv);
        if (!conv) noconv = 1;
        out[i] = lower ? w : w1;
        SL_POLL(cx, i);
    }
    if (warned) sl_warn(cx, "pbeta: NaN erzeugt");
    if (noconv) sl_warn(cx, "pbeta: Kettenbruch nicht konvergiert");
    return SL_OK;
}

/* ── t-Verteilung ── */

typedef struct {
    double nu;
    ibeta_par P;          /* (nu/2, 1/2) */
    double lnc;           /* ln der Dichtekonstante: -1/2 ln nu - ln B(nu/2, 1/2) */
    double lnnu;
} t_par;

static void t_init(t_par *T, double nu)
{
    T->nu = nu;
    T->lnnu = log(nu);
    ibeta_init(&T->P, 0.5 * nu, 0.5);
    T->lnc = -0.5 * T->lnnu - T->P.lnB;
}

/* x = nu/(nu + t^2), y = t^2/(nu + t^2) und ihre Logarithmen, je ohne Auslöschung oder Unterlauf */
static void t_xy(const t_par *T, double t, double *x, double *y, double *lx, double *ly)
{
    const double nu = T->nu;
    double at = fabs(t), t2 = at * at;
    if (t2 <= nu) {
        double u = t2 / nu, l1 = log1p(u);
        double lu = (u > 1e-290) ? log(u) : 2.0 * log(at) - T->lnnu;
        *x = 1.0 / (1.0 + u);
        *y = u / (1.0 + u);
        *lx = -l1;
        *ly = lu - l1;
    } else {
        double w = isinf(t2) ? (nu / at) / at : nu / t2, l1 = log1p(w);
        double lw = (w > 1e-290 && !isinf(t2)) ? log(w) : T->lnnu - 2.0 * log(at);
        *x = w / (1.0 + w);
        *y = 1.0 / (1.0 + w);
        *lx = lw - l1;
        *ly = -l1;
    }
}

/* kleines Ende P(T <= -|t|) und großes Ende P(T <= |t|); h: direkt berechneter Teil
 * (direct = 0: small = h; direct = 1: small = 1/2 - h, large = 1/2 + h); *conv wie oben */
static void t_tails(const t_par *T, double t, double *small, double *large, double *h, int *direct, int *conv)
{
    double x, y, lx, ly, w, w1;
    *conv = 1;
    if (t == 0) { *small = *large = 0.5; *h = 0.0; *direct = 1; return; }
    t_xy(T, t, &x, &y, &lx, &ly);
    ibeta_eval(&T->P, x, y, lx, ly, &w, &w1, direct, conv);
    if (!*direct) { *h = 0.5 * w; *small = *h; *large = 1.0 - *h; }
    else { *h = 0.5 * w1; *small = 0.5 - *h; *large = 0.5 + *h; }
}

/* ln f(t) (Dichte), ohne Überlauf von t^2 */
static double t_logdens(const t_par *T, double t)
{
    double at = fabs(t), t2 = at * at, L;
    if (t2 <= T->nu) L = log1p(t2 / T->nu);
    else L = 2.0 * log(at) - T->lnnu + log1p(isinf(t2) ? (T->nu / at) / at : T->nu / t2);
    return T->lnc - 0.5 * (T->nu + 1.0) * L;
}

int sl_pt(sl_ctx *cx, int64_t n, const double *t, double df, int lower, double *out)
{
    int64_t i;
    t_par T;
    int bad = !(df > 0), warned = 0, noconv = 0, normal = isinf(df) && df > 0;
    if (!bad && !normal && !isnan(df)) t_init(&T, df);
    for (i = 0; i < n; i++) {
        double ti = t[i], sm, lg, h;
        int conv = 1, direct;
        if (isnan(ti)) { out[i] = ti; continue; }
        if (isnan(df)) { out[i] = df; continue; }
        if (bad) { out[i] = NAN; warned = 1; continue; }
        if (normal) { out[i] = sl_pnorm1(ti, lower); continue; }
        if (isinf(ti)) { out[i] = ((ti < 0) == (lower != 0)) ? 0.0 : 1.0; continue; }
        t_tails(&T, ti, &sm, &lg, &h, &direct, &conv);
        if (!conv) noconv = 1;
        out[i] = ((ti < 0) == (lower != 0)) ? sm : lg;
        SL_POLL(cx, i);
    }
    if (warned) sl_warn(cx, "pt: NaN erzeugt");
    if (noconv) sl_warn(cx, "pt: Kettenbruch nicht konvergiert");
    return SL_OK;
}

/* qt im unteren Ende: 0 < p <= 1/2, Ergebnis <= 0 */
static double qt_low(const t_par *T, double p, int *conv)
{
    const double nu = T->nu;
    double t, lo = -INFINITY, hi = 0.0, pm = 0.5 - p, lp = log(p);
    int it, logspace = p < 0.01;
    *conv = 1;
    if (pm == 0.0) return 0.0;
    if (nu == 1.0) return (p >= 0.25) ? tan(SLC_PI * (p - 0.5)) : -1.0 / tan(SLC_PI * p);
    if (nu == 2.0) return -(1.0 - 2.0 * p) / sqrt(2.0 * p * (1.0 - p));
    {
        /* Startwert: A&S 26.7.5 um das Normalquantil; im schweren Rand das Randverhalten */
        double x = slc_qnorm_std(p, 1), x2 = x * x;
        double g1 = (x2 + 1.0) * x / 4.0;
        double g2 = ((5.0 * x2 + 16.0) * x2 + 3.0) * x / 96.0;
        double g3 = (((3.0 * x2 + 19.0) * x2 + 17.0) * x2 - 15.0) * x / 384.0;
        double g4 = ((((79.0 * x2 + 776.0) * x2 + 1482.0) * x2 - 1920.0) * x2 - 945.0) * x / 92160.0;
        double tas = x + (g1 + (g2 + (g3 + g4 / nu) / nu) / nu) / nu;
        t = tas;
        if (fabs(tas) > 2.0 * sqrt(nu)) {
            double ltt = ((0.5 * nu - 1.0) * log(nu) - T->P.lnB - lp) / nu;
            double tt = -exp(ltt);
            if (isinf(tt)) return -INFINITY;            /* Quantil jenseits des Zahlbereichs */
            if (tt < t) t = tt;
        }
        if (!(t < 0)) t = -1e-300;
    }
    for (it = 0; it < 50; it++) {
        double sm, lg, h, lf, d, tn;
        int cv, direct;
        t_tails(T, t, &sm, &lg, &h, &direct, &cv);
        if (!cv) *conv = 0;
        lf = t_logdens(T, t);
        if (sm > p || (t > 0)) hi = t; else lo = t;
        if (t > 0) { d = (direct ? h + pm : pm + (0.5 - h)) / exp(lf); tn = t - d; }  /* F(t) - p, F = large */
        else if (logspace) {
            /* Newton auf ln F(t) - ln p in u = ln(-t): du = (ln F - ln p) F / (|t| f); im Potenzrand
             * F ~ c |t|^-nu ist ln F linear in u */
            double lF = log(sm), du = (lF - lp) * exp(lF - lf) / (-t);
            tn = t * exp(du);
            if (isinf(tn)) {                                        /* jenseits des Zahlbereichs */
                if (t == -DBL_MAX) return -INFINITY;
                tn = -DBL_MAX;
            }
            d = t - tn;
        } else { d = (direct ? pm - h : h - p) / exp(lf); tn = t - d; }   /* F(t) - p, F = small */
        if (isfinite(tn) && fabs(d) <= 1e-14 * fabs(t)) { t = tn; break; }   /* konvergiert */
        if (!isfinite(tn) || !(tn > lo && tn < hi)) {               /* Einschluss verlassen */
            tn = isinf(lo) ? 2.0 * t : 0.5 * lo + 0.5 * hi;         /* ohne Überlauf */
            if (isinf(tn)) tn = -DBL_MAX;
            if (!isinf(lo) && (hi - lo) <= 1e-15 * fabs(lo)) { t = tn; break; }
            t = tn;
            continue;
        }
        t = tn;
        if (fabs(d) <= 1e-14 * fabs(t)) break;
    }
    return t;
}

int sl_qt(sl_ctx *cx, int64_t n, const double *p, double df, int lower, double *out)
{
    int64_t i;
    t_par T;
    int bad = !(df > 0), warned = 0, noconv = 0, normal = isinf(df) && df > 0;
    if (!bad && !normal && !isnan(df)) t_init(&T, df);
    for (i = 0; i < n; i++) {
        double pi = p[i], q, r;
        int conv = 1, neg;
        if (isnan(pi)) { out[i] = pi; continue; }
        if (isnan(df)) { out[i] = df; continue; }
        if (bad || pi < 0 || pi > 1) { out[i] = NAN; warned = 1; continue; }
        if (pi == 0) { out[i] = lower ? -INFINITY : INFINITY; continue; }
        if (pi == 1) { out[i] = lower ? INFINITY : -INFINITY; continue; }
        if (normal) { out[i] = slc_qnorm_std(pi, lower); continue; }
        /* auf das untere Ende mit q <= 1/2 zurückführen */
        neg = !lower;                       /* oberes Ende: -qt(p, lower) */
        if (pi > 0.5) { q = 1.0 - pi; neg = !neg; } else q = pi;
        r = qt_low(&T, q, &conv);           /* <= 0 */
        if (!conv) noconv = 1;
        out[i] = (neg ? -r : r) + 0.0;
        SL_POLL(cx, i);
    }
    if (warned) sl_warn(cx, "qt: NaN erzeugt");
    if (noconv) sl_warn(cx, "qt: Kettenbruch nicht konvergiert");
    return SL_OK;
}

/* ── logistisch ── */

int sl_plogis(sl_ctx *cx, int64_t n, const double *x, double *out)
{
    int64_t i;
    for (i = 0; i < n; i++) {
        double xi = x[i];
        if (isnan(xi)) out[i] = xi;
        else if (xi >= 0) out[i] = 1.0 / (1.0 + exp(-xi));
        else { double e = exp(xi); out[i] = e / (1.0 + e); }
        SL_POLL(cx, i);
    }
    return SL_OK;
}

int sl_qlogis(sl_ctx *cx, int64_t n, const double *p, double *out)
{
    int64_t i;
    int warned = 0;
    for (i = 0; i < n; i++) {
        double pi = p[i];
        if (isnan(pi)) out[i] = pi;
        else if (pi < 0 || pi > 1) { out[i] = NAN; warned = 1; }
        else if (pi >= 1.0 / 3.0 && pi <= 2.0 / 3.0) out[i] = log1p((2.0 * pi - 1.0) / (1.0 - pi));  /* 2p - 1 exakt */
        else out[i] = log(pi) - log1p(-pi);
        SL_POLL(cx, i);
    }
    if (warned) sl_warn(cx, "qlogis: NaN erzeugt");
    return SL_OK;
}
