/* core/slc_normal.c – Normalverteilung: erfc, pnorm, qnorm, dnorm (SimLev core, Etappe 9)
 * Verfahren:  Q(x) = 1 - Phi(x) für x >= 0 in zwei Zonen.
 *             (1) 0 <= x <= 5: Taylor-Entwicklung um den nächsten Stützpunkt c = j/8 mit
 *                 |h| = |x - c| <= 1/16. Aus phi' = -x phi (DLMF 7.10.1 mit n = 0) folgt
 *                 phi(c + h) = phi(c) sum_n b_n h^n mit b_0 = 1, b_1 = -c,
 *                 (n+1) b_{n+1} = -c b_n - b_{n-1}; also Phi(c + h) - Phi(c) =
 *                 phi(c) sum_n b_n h^(n+1) / (n+1). Die Stützwerte phi(c), Phi(c) - 1/2 und Q(c)
 *                 (je als Paar hi + lo) berechnet gen_constants.py mit 60 Dezimalstellen aus
 *                 DLMF 7.6.2, die Taylor-Polynome je Stützpunkt exakt mit Brüchen (Grad 11–13,
 *                 Restglied < 2^-63 relativ). Für c = 0 ist das die Potenzreihe DLMF 7.6.1.
 *                 Diese Zone braucht keine Exponentialfunktion.
 *             (2) x > 5: sqrt(pi) e^(z^2) erfc(z) als Kettenbruch DLMF 7.9.2 (gerader Teil von
 *                 7.9.1) mit z = x/sqrt 2, von unten ausgewertet mit fester Tiefe
 *                 N = 6 + ceil(140/z^2) (bei x = 5 also 18 Glieder; gemessen in 9.1). Das
 *                 modifizierte Lentz-Verfahren (DLMF 3.10(iii)) wurde verworfen: das Produkt seiner
 *                 Faktoren häufte bis 2e-15 relativen Fehler an.
 *                 e^(-x^2/2) ohne Auslöschung: x_h = x auf 26 Bit (Teilung nach Veltkamp/Dekker),
 *                 x^2/2 = x_h^2/2 + x_l (x + x_h)/2 mit exaktem x_h^2; im tiefen Rand (x_h^2/2 > 700)
 *                 wird e^(-a) als e^(-a/2) * (...) * e^(-a/2) gebildet, damit erst das Ergebnis
 *                 subnormal wird.
 *             pnorm über die Symmetrie ohne 1 - p im kleinen Ende; im großen Ende 1/2 + D(x)
 *             mit D = Phi - 1/2 aus der Tabelle (bzw. 1 - Q für x > 5).
 *             erfc(z) entsprechend mit eigener Tabelle an z_j = j/8 (z <= 3.5; Taylor aus
 *             (e^(-z^2))' = -2z e^(-z^2): (n+1) a_{n+1} = -2c a_n - 2 a_{n-1}; Grad <= 14) und
 *             Kettenbruch 7.9.2 für z > 3.5; erfc(-z) = 2 - erfc(z).
 *             qnorm(p) (N2, drei Zonen; rationale Näherungen selbst angepasst in gen_constants.py,
 *             qnorm_fits: kleinste Quadrate im relativen Fehler, Sanathanan-Koerner und Lawson, an der
 *             eigenen Referenz; keine Koeffizienten aus AS 241 oder anderen Programmen):
 *             (A) |p - 1/2| <= Phi(1.5) - 1/2: x = s (1 + w G(z)) mit s = sqrt(2 pi) q, q = p - 1/2,
 *                 w = q^2, z = 1/4 - w = p (1 - p), G = P_7(z)/Q_8(z) (G - 1 Reihenumkehr von DLMF
 *                 7.6.1; in z liegen die Pole bei z < 0, alle Koeffizienten positiv). q exakt per
 *                 Fast2Sum, s als Doppelwort (Produkt nach Dekker 1971); kein Korrekturschritt.
 *             (B) Phi(-1.5) > min(p, 1 - p) >= 2.8e-7: Start -x = P_4(t)/Q_4(t), t = sqrt(-2 ln p)
 *                 (Fehler < 1e-11 relativ), dann ein Halley-Schritt
 *                 x <- x - d / (1 + x d / 2), d = (Phi(x) - p)/phi(x) (die Schleife endet nach dem
 *                 Schritt mit |d| <= 2^-20 |x|; kubische Konvergenz: Restfehler ~ |d|^3). Phi(x) - p
 *                 und phi(x) kommen aus denselben Taylor-Polynomen wie pnorm, aber nach Estrin
 *                 ausgewertet (kürzere Abhängigkeitskette; gemessen gleiche Genauigkeit).
 *             (C) p < 2.8e-7 (x < -5): Start -x = P_5(t)/Q_5(t) (Fehler < 1e-10 relativ), dann ein
 *                 Newton-Schritt auf ln Q(-x) - ln p mit dem Mills-Quotienten
 *                 M = Q/phi = F(z)/sqrt 2 aus dem Kettenbruch (ohne Exponentialfunktion, daher auch für
 *                 subnormales p genau); Ende nach |d| <= 2^-30 |x| (quadratische Konvergenz).
 *             Oberes Ende über qnorm(p) = -qnorm(1 - p) (1 - p exakt für p >= 1/2). Phi(x) - p wird im
 *             passenden Teil gebildet: für |x| <= 1/2 als (1/2 - p) - D(|x|) (1/2 - p exakt), sonst als
 *             Q(|x|) - p. Bis 1.0.0 (9.1): Startwert aus der Umkehrreihe bzw. DLMF 7.12.1 und bis zu
 *             acht Halley-Schritte (7-mal langsamer als R).
 *             dnorm(x) = phi(x): für |x| <= 5 aus der Tabelle (phi(c) sum b_n h^n), sonst
 *             e^(-x^2/2)/sqrt(2 pi) mit derselben Teilung; log-Dichte -x_h^2/2 - x_l(x+x_h)/2 -
 *             ln sqrt(2 pi).
 * Quellen:    Olver, F. W. J. u. a. (Hrsg.). NIST Digital Library of Mathematical Functions,
 *               https://dlmf.nist.gov/, Release 1.2: 7.6.1, 7.6.2 (Potenzreihen), 7.9.1, 7.9.2
 *               (Kettenbruch, gerader Teil), 7.10.1 (Ableitungen), 7.12.1 (Asymptotik),
 *               3.10(iii) (Auswertung von Kettenbrüchen).
 *             Lentz, W. J. (1976). Generating Bessel functions in Mie scattering calculations using
 *               continued fractions. Applied Optics 15(3), 668–671.
 *             Thompson, I. J., Barnett, A. R. (1986). Coulomb and Bessel functions of complex
 *               arguments and order. Journal of Computational Physics 64(2), 490–509, Abschnitt 3
 *               (modifiziertes Lentz-Verfahren).
 *             Dekker, T. J. (1971). A floating-point technique for extending the available
 *               precision. Numerische Mathematik 18(3), 224–242 (Teilung nach Veltkamp).
 *             Halley-Verfahren: z. B. Householder, A. S. (1970). The Numerical Treatment of a
 *               Single Nonlinear Equation. McGraw-Hill, Kap. 4.
 *             N2: Sanathanan, C. K., Koerner, J. (1963). Transfer function synthesis as a ratio of two
 *               complex polynomials. IEEE Transactions on Automatic Control 8(1), 56–58.
 *             Lawson, C. L. (1961). Contributions to the Theory of Linear Least Maximum
 *               Approximation. Dissertation, University of California, Los Angeles.
 *             Fast2Sum und Produktfehler: Dekker (1971), siehe oben.
 * Konstanten: selbst hergeleitet (core/tools/gen_constants.py): Stützwerte phi, Phi - 1/2, Q an
 *             j/8 (j <= 40) und erfc, (2/sqrt pi) e^(-z^2) an j/8 (j <= 28), Umkehrreihe 1/6, 7/120,
 *             sqrt(2 pi), ln 2 pi, 1/sqrt(pi), 1/sqrt 2. Veltkamp-Faktor 2^27 + 1 (Dekker 1971).
 *             N2: Koeffizienten der Zonen A, B, C (slc_qn_*), sqrt(2 pi) als hi + lo und geteilt,
 *             Zonengrenzen SLC_QN_QA = Phi(1.5) - 1/2, SLC_QN_PC = 2.8e-7.
 *             Zonengrenzen 5 und 3.5 gemessen in 9.1 (e91/); Taylor-Polynome je Stützpunkt.
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen.
 * Prüforakel: R 4.3.3 pnorm, qnorm, dnorm; eigene Rechnung mit decimal (scratchpad/e91/, N2: en2/).
 */
#define SLC_NEED_NORMAL_TABLES
#include "slc_internal.h"
#include "slc_constants.h"

#define Q_ZERO_AT 40.0          /* Q(x) < 2^-1075 für x > 38.6: Ergebnis 0 */
#define ERFC_ZERO_AT 28.0       /* erfc(z) < 2^-1075 für z > 27.3 */

/* ── Hilfen ── */

/* Teilung nach Veltkamp: hi mit 26 Bit, x = hi + lo exakt (|x| < 1e300) */
static void split26(double x, double *hi, double *lo)
{
    double c = 134217729.0 * x;
    double h = c - (c - x);
    *hi = h;
    *lo = x - h;
}

/* k * e^(-s x^2), s = 1/2 oder 1, x >= 0 endlich, k > 0; erst das Ergebnis darf subnormal werden */
static double k_exp_negsq(double x, double s, double k)
{
    double xh, xl, a, b, eb;
    split26(x, &xh, &xl);
    a = s * (xh * xh);              /* exakt */
    b = s * (xl * (x + xh));        /* s x^2 = a + b */
    eb = exp(-b);
    if (a < 700.0) return k * (exp(-a) * eb);
    {
        double e1 = exp(-0.5 * a);
        return (e1 * (k * eb)) * e1;
    }
}

/* Taylor um c = j/8 (Normal-Tabelle): S = sum b_n h^(n+1)/(n+1), E = sum b_n h^n (Horner mit den
 * vorberechneten Polynomen slc_npoly_S/E; Grad je Stützpunkt in Spalte 0) */
static int ntay(double x, double *S, double *E)
{
    int j = (int) (x * 8.0 + 0.5), n, N;
    double h = x - 0.125 * j, s, e;      /* h exakt */
    const double *ps = slc_npoly_S[j], *pe = slc_npoly_E[j];
    N = (int) ps[0];
    s = ps[N + 1];
    e = pe[N + 1];
    for (n = N; n >= 1; n--) {
        s = ps[n] + h * s;
        e = pe[n] + h * e;
    }
    *S = h * s;
    *E = e;
    return j;
}

/* nur S (ohne Dichte) */
static int ntayS(double x, double *S)
{
    int j = (int) (x * 8.0 + 0.5), n, N;
    double h = x - 0.125 * j, s;
    const double *ps = slc_npoly_S[j];
    N = (int) ps[0];
    s = ps[N + 1];
    for (n = N; n >= 1; n--) s = ps[n] + h * s;
    *S = h * s;
    return j;
}

/* sqrt(pi) e^(z^2) erfc(z), z >= 3.4, Kettenbruch DLMF 7.9.2 von unten ausgewertet mit fester
 * Tiefe N = 6 + ceil(140/z^2) (gemessen in 9.1: die nötige Tiefe für 2^-58 relativ liegt für
 * 3.4 <= z <= 30 um mindestens ein Glied darunter; e91/tools/cfdepth.py). Von unten gerechnet
 * häufen sich die Rundungsfehler nicht an wie beim Produkt der Lentz-Faktoren. */
static double cf_erfcx(double z)
{
    double z2 = 2.0 * z * z, t;
    int N = 6 + (int) ceil(140.0 / (z * z)), k;
    if (N > 40) N = 40;
    t = z2 + (double) (4 * N - 3);
    for (k = N - 1; k >= 1; k--)
        t = (z2 + (double) (4 * k - 3)) - (double) (2 * k - 1) * (double) (2 * k) / t;
    return 2.0 * z / t;
}

/* ln Q(a) und Mills-Quotient Q(a)/phi(a) für a > 5, ohne Unterlauf */
static double lnq_tail(double a, double *mills)
{
    double ah, al, F = cf_erfcx(a * SLC_M_1_SQRT2);
    split26(a, &ah, &al);
    *mills = F * SLC_M_1_SQRT2;
    return -(0.5 * (ah * ah) + 0.5 * (al * (a + ah))) + log(F * (0.5 * SLC_M_1_SQRTPI));
}

/* Q(a) = 1 - Phi(a), a >= 0 */
static double qtail(double a)
{
    if (a <= SLC_NT_XMAX) {
        double S;
        const double *t = slc_ntab[ntayS(a, &S)];
        return t[3] + (t[4] - t[0] * S);
    }
    if (a > Q_ZERO_AT) return 0.0;
    return k_exp_negsq(a, 0.5, cf_erfcx(a * SLC_M_1_SQRT2) * (0.5 * SLC_M_1_SQRTPI));
}

/* Phi(a) für a >= 0 (großes Ende) */
static double phead(double a)
{
    if (a <= SLC_NT_XMAX) {
        double S;
        const double *t = slc_ntab[ntayS(a, &S)];
        return 0.5 + (t[1] + (t[2] + t[0] * S));
    }
    return 1.0 - qtail(a);
}

/* phi(a), a >= 0 */
static double dens(double a)
{
    if (a <= SLC_NT_XMAX) {
        double S, E;
        const double *t = slc_ntab[ntay(a, &S, &E)];
        return t[0] * E;
    }
    if (a > Q_ZERO_AT) return 0.0;
    return k_exp_negsq(a, 0.5, SLC_M_1_SQRT2PI);
}

/* ── erfc ── */

double sl_erfc(double x)
{
    double z = fabs(x), v;
    if (isnan(x)) return x;
    if (z <= SLC_ET_ZMAX) {
        int j = (int) (z * 8.0 + 0.5), n, N;
        double h = z - 0.125 * j, s;
        const double *ps = slc_epoly_S[j], *t = slc_etab[j];
        N = (int) ps[0];
        s = ps[N + 1];
        for (n = N; n >= 1; n--) s = ps[n] + h * s;
        v = t[0] + (t[1] - t[2] * (h * s));
    } else if (z > ERFC_ZERO_AT) {
        v = 0.0;
    } else {
        v = k_exp_negsq(z, 1.0, cf_erfcx(z) * SLC_M_1_SQRTPI);
    }
    return (x < 0) ? 2.0 - v : v;
}

/* ── pnorm ── */

double sl_pnorm1(double x, int lower)
{
    double a;
    int small;
    if (isnan(x)) return x;
    a = fabs(x);
    small = (x < 0) ? (lower != 0) : (lower == 0);
    return small ? qtail(a) : phead(a);
}

/* ── dnorm ── */

double sl_dnorm1(double x, int give_log)
{
    double a;
    if (isnan(x)) return x;
    a = fabs(x);
    if (!give_log) return isinf(a) ? 0.0 : dens(a);
    if (isinf(a)) return -INFINITY;
    if (a <= SLC_NT_XMAX) return log(dens(a));
    if (a > 1e150) return -INFINITY;
    {
        double xh, xl;
        split26(a, &xh, &xl);
        return -(0.5 * (xh * xh) + 0.5 * (xl * (a + xh))) - SLC_LN_SQRT2PI;
    }
}

/* ── qnorm ── */

/* N2: wie ntay, aber nach Estrin (Grad SLC_NPOLY_DEG fest, die Tabellen sind mit 0 aufgefüllt): kürzere
 * Abhängigkeitskette für den Korrekturschritt von qnorm; S und E bis auf Rundung wie ntay */
static int ntay_estrin(double x, double *S, double *E)
{
    int j = (int) (x * 8.0 + 0.5);
    double h = x - 0.125 * j, h2 = h * h, h4 = h2 * h2, h8 = h4 * h4;
    const double *c = slc_npoly_S[j] + 1, *e = slc_npoly_E[j] + 1;
#if SLC_NPOLY_DEG != 13
#error "ntay_estrin: Grad 13 erwartet"
#endif
    double s = (((c[0] + c[1] * h) + (c[2] + c[3] * h) * h2) + ((c[4] + c[5] * h) + (c[6] + c[7] * h) * h2) * h4)
               + (((c[8] + c[9] * h) + (c[10] + c[11] * h) * h2) + (c[12] + c[13] * h) * h4) * h8;
    double f = (((e[0] + e[1] * h) + (e[2] + e[3] * h) * h2) + ((e[4] + e[5] * h) + (e[6] + e[7] * h) * h2) * h4)
               + (((e[8] + e[9] * h) + (e[10] + e[11] * h) * h2) + (e[12] + e[13] * h) * h4) * h8;
    *S = h * s;
    *E = f;
    return j;
}

/* Phi(x) - p und phi(x); p in (0, 1/2], pm = 1/2 - p */
static void qn_eval(double x, double p, double pm, double *res, double *ph)
{
    double a = fabs(x);
    if (a <= SLC_NT_XMAX) {
        double S, E, Dv;
        const double *t = slc_ntab[ntay_estrin(a, &S, &E)];
        *ph = t[0] * E;
        if (a <= 0.5 || x > 0) {
            Dv = t[1] + (t[2] + t[0] * S);           /* Phi(a) - 1/2 */
            *res = ((x < 0) ? -Dv : Dv) + pm;        /* (Phi(x) - 1/2) + (1/2 - p) */
        } else {
            *res = (t[3] + (t[4] - t[0] * S)) - p;   /* Q(a) - p */
        }
    } else {
        double Qv = qtail(a);
        *ph = dens(a);
        *res = (x < 0) ? Qv - p : (1.0 - Qv) - p;
    }
}

/* N2: Zone A (|p - 1/2| <= SLC_QN_QA, |x| <= 1.5) ohne Korrekturschritt:
 * x = s (1 + w G(z)) mit s = sqrt(2 pi) q, w = q^2, z = 1/4 - w, G = P_7(z)/Q_8(z) (gen_constants.py).
 * q = qh + ql exakt (Fast2Sum mit |1/2| >= |p| für p <= 1/2; für p > 1/2 ist p - 1/2 exakt, ql = 0);
 * s = sh + sl als Doppelwort (Produktfehler nach Dekker 1971 mit der Veltkamp-Teilung von sqrt(2 pi));
 * x = sh + (sl + sh w G). Der Rest sh w G ist höchstens 28 % von x, sein Rundungsfehler geht also
 * stark verkleinert ein (gemessen: höchstens ~1,5 ulp, scratchpad/en2/). Ungerade in q: x(1 - p) = -x(p). */
static double qn_zone_a(double p)
{
    double qh = p - 0.5, ql = p - (qh + 0.5);
    double w = qh * qh + 2.0 * qh * ql, z = 0.25 - w;
    const double *a = slc_qn_ap, *b = slc_qn_aq;
    double P = ((((((a[7] * z + a[6]) * z + a[5]) * z + a[4]) * z + a[3]) * z + a[2]) * z + a[1]) * z + a[0];
    double Q = (((((((b[8] * z + b[7]) * z + b[6]) * z + b[5]) * z + b[4]) * z + b[3]) * z + b[2]) * z + b[1]) * z
               + b[0];
    double G = P / Q, sh = SLC_SQRT2PI * qh, qa, qb, se, sl;
    split26(qh, &qa, &qb);
    se = ((SLC_SQRT2PI_H26 * qa - sh) + SLC_SQRT2PI_H26 * qb + SLC_SQRT2PI_L26 * qa) + SLC_SQRT2PI_L26 * qb;
    sl = se + (SLC_SQRT2PI_LO * qh + SLC_SQRT2PI * ql);
    return sh + (sl + sh * (w * G));
}

/* 0 < p <= 1/2 außerhalb der Zone A; Ergebnis < 0.
 * N2: Startwert aus den rationalen Näherungen der Zonen B und C in t = sqrt(-2 ln p) (Fehler < 1e-11
 * bzw. 1e-10 relativ); die Schleifen unten enden daher nach einem Schritt. */
static double qnorm_low(double p)
{
    double x, pm = 0.5 - p, lp = log(p), t = sqrt(-2.0 * lp);
    int it;
    if (p >= SLC_QN_PC) {
        const double *a = slc_qn_bp, *b = slc_qn_bq;
        x = -((((a[4] * t + a[3]) * t + a[2]) * t + a[1]) * t + a[0])
            / ((((b[4] * t + b[3]) * t + b[2]) * t + b[1]) * t + b[0]);
    } else {
        const double *a = slc_qn_cp, *b = slc_qn_cq;
        x = -(((((a[5] * t + a[4]) * t + a[3]) * t + a[2]) * t + a[1]) * t + a[0])
            / (((((b[5] * t + b[4]) * t + b[3]) * t + b[2]) * t + b[1]) * t + b[0]);
        /* tiefer Rand (x < -5): Newton auf ln Q(-x) - ln p mit d ln Q(-x)/dx = 1/M (Mills-Quotient
         * M = Q/phi aus dem Kettenbruch); keine Exponentialfunktion, also auch für subnormales p */
        for (it = 0; it < 12 && -x > SLC_NT_XMAX; it++) {
            double M, d = (lnq_tail(-x, &M) - lp) * M;
            x = x - d;
            /* quadratische Konvergenz: nach |d| <= 2^-30 |x| ist der Restfehler < 2^-60 |x| */
            if (fabs(d) <= 0x1p-30 * fabs(x)) return x;
        }
    }
    for (it = 0; it < 8; it++) {
        double res, ph, d;
        qn_eval(x, p, pm, &res, &ph);
        if (!(ph > 0.0)) break;
        d = res / ph;
        if (!isfinite(d)) break;
        x = x - d / (1.0 + 0.5 * x * d);
        /* Halley konvergiert kubisch: nach |d| <= 2^-20 |x| ist der Fehler des neuen x
         * von der Größe |d|^3 / |x|^2 < 2^-60 |x| (in 9.1 gegen R und decimal gemessen) */
        if (fabs(d) <= 0x1p-20 * fabs(x)) break;
    }
    return x;
}

double slc_qnorm_std(double p, int lower)
{
    double x;
    if (!lower) return -slc_qnorm_std(p, 1);
    if (fabs(p - 0.5) <= SLC_QN_QA) x = qn_zone_a(p);               /* N2 */
    else x = (p > 0.5) ? -qnorm_low(1.0 - p) : qnorm_low(p);
    return x + 0.0;        /* -0 -> +0 */
}

double sl_qnorm1(double p, int lower)
{
    if (isnan(p)) return p;
    if (p < 0 || p > 1) return NAN;
    if (p == 0) return lower ? -INFINITY : INFINITY;
    if (p == 1) return lower ? INFINITY : -INFINITY;
    return slc_qnorm_std(p, lower) + 0.0;
}

/* ── Vektorfunktionen ── */

int sl_erfc_v(sl_ctx *cx, int64_t n, const double *x, double *out)
{
    int64_t i;
    for (i = 0; i < n; i++) {
        out[i] = sl_erfc(x[i]);
        SL_POLL(cx, i);
    }
    return SL_OK;
}

/* Parameter prüfen: 0 = gültig, 1 = NaN-Parameter (Ausgabe = Parameter), 2 = ungültig (NaN + Warnung) */
static int check_musd(double mu, double sd, double *nanval)
{
    if (isnan(mu)) { *nanval = mu; return 1; }
    if (isnan(sd)) { *nanval = sd; return 1; }
    if (sd < 0) return 2;
    return 0;
}

int sl_pnorm(sl_ctx *cx, int64_t n, const double *x, double mu, double sd, int lower, double *out)
{
    int64_t i;
    double nv = 0.0;
    int st = check_musd(mu, sd, &nv), warned = 0;
    for (i = 0; i < n; i++) {
        double xi = x[i];
        if (isnan(xi)) out[i] = xi;
        else if (st == 1) out[i] = nv;
        else if (st == 2) { out[i] = NAN; warned = 1; }
        else if (sd == 0) out[i] = (xi < mu) ? (lower ? 0.0 : 1.0) : (lower ? 1.0 : 0.0);
        else out[i] = sl_pnorm1((xi - mu) / sd, lower);
        SL_POLL(cx, i);
    }
    if (warned) sl_warn(cx, "pnorm: NaN erzeugt");
    return SL_OK;
}

int sl_qnorm(sl_ctx *cx, int64_t n, const double *p, double mu, double sd, int lower, double *out)
{
    int64_t i;
    double nv = 0.0;
    int st = check_musd(mu, sd, &nv), warned = 0;
    for (i = 0; i < n; i++) {
        double pi = p[i];
        if (isnan(pi)) out[i] = pi;
        else if (st == 1) out[i] = nv;
        else if (st == 2 || pi < 0 || pi > 1) { out[i] = NAN; warned = 1; }
        else if (pi == 0 || pi == 1) out[i] = sl_qnorm1(pi, lower);
        else if (sd == 0) out[i] = mu;
        else out[i] = mu + sd * slc_qnorm_std(pi, lower);
        SL_POLL(cx, i);
    }
    if (warned) sl_warn(cx, "qnorm: NaN erzeugt");
    return SL_OK;
}

int sl_dnorm(sl_ctx *cx, int64_t n, const double *x, double mu, double sd, int give_log, double *out)
{
    int64_t i;
    double nv = 0.0;
    int st = check_musd(mu, sd, &nv), warned = 0;
    for (i = 0; i < n; i++) {
        double xi = x[i];
        if (isnan(xi)) out[i] = xi;
        else if (st == 1) out[i] = nv;
        else if (st == 2) { out[i] = NAN; warned = 1; }
        else if (sd == 0) out[i] = (xi == mu) ? INFINITY : (give_log ? -INFINITY : 0.0);
        else {
            double z = (xi - mu) / sd;
            if (isnan(z)) out[i] = z;
            else out[i] = give_log ? sl_dnorm1(z, 1) - log(sd) : sl_dnorm1(z, 0) / sd;
        }
        SL_POLL(cx, i);
    }
    if (warned) sl_warn(cx, "dnorm: NaN erzeugt");
    return SL_OK;
}
