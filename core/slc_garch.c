/* core/slc_garch.c – GARCH(1,1) und GJR-GARCH(1,1) mit Normalverteilung (SimLev core, Etappe 9.4)
 * Verfahren:  Modell e_t = mu + eps_t, eps_t = sigma_t z_t, z_t ~ N(0, 1),
 *             sigma_t^2 = omega + (alpha + gamma 1{eps_{t-1} < 0}) eps_{t-1}^2 + beta sigma_{t-1}^2
 *             (Bollerslev 1986; GJR: Glosten, Jagannathan, Runkle 1993), Start sigma_1^2 =
 *             Stichprobenvarianz von e (eigene Wahl wie h1 im eigenen MS-GARCH, SPEZ-9 B.10).
 *             Punktschätzer per Maximum Likelihood, NLL = 1/2 sum (log 2 pi + log sigma_t^2 +
 *             eps_t^2 / sigma_t^2), kompensiert summiert (Neumaier 1974). Parameter ohne
 *             Nebenbedingungen über die Umparametrisierung des eigenen MS-GARCH mit einem Regime
 *             (SimLev r/R/ms_garch.R, .ms_garch_unpack): mu frei, omega = exp(theta_omega),
 *             sGARCH (alpha, beta) = exp(a, b) / (1 + Summe); GJR (N1) (alpha/2, (alpha + gamma)/2,
 *             beta) = exp(a, g, b) / (1 + Summe). Damit gelten omega, alpha, beta > 0, bei GJR
 *             alpha + gamma > 0 (gamma < 0 zulässig; bis 1.0.0 (alpha, gamma/2, beta), also
 *             gamma >= 0, F9) und alpha + gamma/2 + beta < 1 von selbst: Das Bild ist genau das
 *             Innere des Bereichs, in dem die bedingte Varianz für jedes Vorzeichen von eps
 *             positiv bleibt und das Modell unter der Normalverteilung (E 1{eps < 0} = 1/2)
 *             stationär ist (Glosten, Jagannathan, Runkle 1993).
 *             Startwerte: mu = Mittelwert, festes Raster (alpha, gamma, beta) wie in .ms_garch_fit
 *             (sGARCH drei Punkte; GJR seit N1 sieben: die drei bisherigen, zwei mit gamma < 0,
 *             zwei mit kleinem beta), omega über Varianz-Targeting. sGARCH: genommen wird der
 *             Rasterpunkt mit der kleinsten NLL, bei Gleichstand der erste; N6: endet BFGS am Rand
 *             alpha < 0.01, zweiter Lauf vom besten Punkt einer zweiten Familie mit kleinerem beta,
 *             das bessere Ergebnis gilt. GJR (N1): BFGS von
 *             jedem Rasterpunkt, der beste Lauf gewinnt, bei Gleichstand der erste. Optimierung mit
 *             BFGS (slc_opt.c, sl_minimize), GJR seit N3 und sGARCH seit N4 (bis N3 numerischer
 *             Gradient) mit dem analytischen Gradienten aus einer Vorwärtsrekursion der Ableitungen
 *             von sigma_t^2 (garch_fg: f und g in einem Durchlauf, Logarithmen über ein laufendes
 *             Produkt);
 *             mu in Einheiten der Standardabweichung (parscale), damit die Hesse-Matrix gut
 *             skaliert ist.
 *             Filter: wie der frühere eigene Kern garch_filter (bis 1.0.0): s2[0] =
 *             s2_init, Rekursion wie oben, Untergrenze 1e-14.
 *             Ganze Stufe sl_garch11_estimate wie die eigene R-Funktion .fit_garch11
 *             (r/R/bootstrap.R) ohne die Übernahme: Varianz < 1e-16 "konstant", sonst ML,
 *             Rückfall Momente (F10, ohne Nelder-Mead-Stufe), Filter, standardisierte Residuen.
 *             Nur Punktschätzer (F4): keine Standardfehler, keine Hesse-Matrix.
 * Quellen:    Bollerslev, T. (1986). Generalized autoregressive conditional heteroskedasticity.
 *               Journal of Econometrics 31(3), 307–327.
 *             Glosten, L. R., Jagannathan, R., Runkle, D. E. (1993). On the relation between the
 *               expected value and the volatility of the nominal excess return on stocks. The
 *               Journal of Finance 48(5), 1779–1801.
 *             Neumaier, A. (1974). Rundungsfehleranalyse einiger Verfahren zur Summation endlicher
 *               Summen. ZAMM 54(1), 39–51.
 *             Nocedal, J., Wright, S. J. (2006). Numerical Optimization, 2. Aufl., Springer
 *               (BFGS, über slc_opt.c).
 *             Fiorentini, G., Calzolari, G., Panattoni, L. (1996). Analytic derivatives and the
 *               computation of GARCH estimates. Journal of Applied Econometrics 11(4), 399–417
 *               (N3/N4: Rekursion der Ableitungen der bedingten Varianz).
 *             Griewank, A., Walther, A. (2008). Evaluating Derivatives, 2. Aufl., SIAM
 *               (N3/N4: Vorwärtsmodus, von Hand geschrieben).
 *             Eigener SimLev-Code: .ms_garch_unpack/.ms_garch_pack und das Raster aus
 *               r/R/ms_garch.R, .fit_garch11 aus r/R/bootstrap.R (bis zur Grenze des
 *               rugarch-Aufrufs), früher garch_filter (bis 1.0.0).
 * Konstanten: ln(2 pi) aus slc_constants.h (gen_constants.py). Verfahrensparameter (eigene Wahl,
 *             SPEZ-9 B.10): Raster wie .ms_garch_fit (GJR ergänzt in N1; zweite sGARCH-Familie und
 *             Schwelle alpha < 0.01 N6), maxit 500, reltol 1e-10,
 *             Momente alpha 0.08, beta 0.88, gamma 0.04 wie .fit_garch11.
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen (rugarch,
 *             Rsolnp nicht gelesen).
 * Prüforakel: rugarch 1.5-6 ugarchfit (nur Plausibilität, scratchpad/e94/, N1: scratchpad/en1/,
 *             N3: scratchpad/en3/, N4: scratchpad/en4/, N6: scratchpad/en6/).
 */
#include "slc_internal.h"
#include "slc_la_internal.h"
#include "slc_opt.h"
#include "slc_constants.h"

#include <stdlib.h>
#include <string.h>

#define GARCH_FLOOR 1e-14

/* Raster (alpha, gamma, beta) wie in .ms_garch_fit */
static const double grid_s[3][3] = {{0.05, 0.0, 0.90}, {0.10, 0.0, 0.85}, {0.03, 0.0, 0.95}};
/* N1: GJR zusätzlich mit gamma < 0 (alpha + gamma > 0) und mit kleinem beta (fast unabhängige Reihen:
 * dort liegt das Optimum oft bei beta -> 0); die drei bisherigen Punkte zuerst. BFGS läuft bei GJR von
 * jedem Rasterpunkt (siehe sl_garch11_fit). */
#define GRID_NG 7
static const double grid_g[GRID_NG][3] = {{0.03, 0.06, 0.90}, {0.05, 0.10, 0.82}, {0.02, 0.04, 0.94},
                                          {0.06, -0.03, 0.90}, {0.12, -0.05, 0.80},
                                          {0.02, 0.06, 0.50}, {0.05, 0.05, 0.10}};

/* ── Hilfen ── */

static double mean_c(int n, const double *x)
{
    slc_acc a;
    int i;
    slc_acc_init(&a, 0.0);
    for (i = 0; i < n; i++) slc_acc_add(&a, x[i]);
    return slc_acc_val(&a) / n;
}

/* Stichprobenvarianz (Nenner n - 1), zwei Durchgänge, kompensiert */
static double var_c(int n, const double *x, double m)
{
    slc_acc a;
    int i;
    if (n < 2) return NAN;
    slc_acc_init(&a, 0.0);
    for (i = 0; i < n; i++) { double d = x[i] - m; slc_acc_add(&a, d * d); }
    return slc_acc_val(&a) / (n - 1);
}

static int check_series(sl_ctx *cx, int n, const double *e, int nmin, const char *who)
{
    if (n < nmin || e == NULL)
        return sl_fail(cx, SL_ESMALL, "%s: zu wenige Beobachtungen (n = %d, mindestens %d)", who, n, nmin);
    if (!slc_all_finite(n, e))
        return sl_fail(cx, SL_ENONFINITE, "%s: Reihe enthält nicht endliche Werte", who);
    return SL_OK;
}

/* ── Filter ── */

int sl_garch11_filter(sl_ctx *cx, int n, const double *eps, double omega, double alpha, double beta,
                      double gamma, double s2_init, double *s2)
{
    double v = s2_init;
    int t;
    if (n < 0) return sl_fail(cx, SL_EARG, "garch11_filter: n < 0");
    for (t = 0; t < n; t++) {
        s2[t] = v;
        v = omega + (alpha + gamma * (eps[t] < 0.0 ? 1.0 : 0.0)) * (eps[t] * eps[t]) + beta * v;
        if (v < GARCH_FLOOR) v = GARCH_FLOOR;
        SL_POLL(cx, t);
    }
    return SL_OK;
}

/* ── Umparametrisierung ── */

int sl_garch11_npar(int gjr) { return gjr ? 5 : 4; }

void sl_garch11_unpack(int gjr, const double *th, double *par)
{
    par[0] = th[0];
    par[1] = exp(th[1]);
    if (gjr) {
        /* N1: (alpha/2, (alpha + gamma)/2, beta) = exp(a, g, b) / (1 + Summe); gamma < 0 zulässig,
         * solange alpha + gamma > 0 (bis 1.0.0: (alpha, gamma/2, beta), also gamma >= 0, F9) */
        double e1 = exp(th[2]), e2 = exp(th[3]), e3 = exp(th[4]);
        double d = 1.0 + ((e1 + e2) + e3);
        par[2] = 2.0 * e1 / d; par[4] = 2.0 * (e2 - e1) / d; par[3] = e3 / d;
    } else {
        double e1 = exp(th[2]), e2 = exp(th[3]);
        double d = 1.0 + (e1 + e2);
        par[2] = e1 / d; par[3] = e2 / d; par[4] = 0.0;
    }
}

int sl_garch11_pack(sl_ctx *cx, int gjr, const double *par, double *th)
{
    double om = par[1], al = par[2], be = par[3], ga = gjr ? par[4] : 0.0;
    double r = 1.0 - al - ga / 2.0 - be;
    if (!isfinite(par[0]) || !(om > 0.0) || !(al > 0.0) || !(be > 0.0) || (gjr && !(al + ga > 0.0)) || !(r > 0.0) ||
        !isfinite(om))
        return sl_fail(cx, SL_EARG, "garch11_pack: Parameter außerhalb des Bereichs (omega, alpha, beta > 0, alpha + gamma > 0, Persistenz < 1)");
    th[0] = par[0];
    th[1] = log(om);
    if (gjr) { th[2] = log((al / 2.0) / r); th[3] = log(((al + ga) / 2.0) / r); th[4] = log(be / r); }   /* N1 */
    else { th[2] = log(al / r); th[3] = log(be / r); }
    return SL_OK;
}

/* ── Likelihood ── */

/* NLL an par (mu, omega, alpha, beta, gamma); nicht endlich -> +Inf */
static double nll_par(int n, const double *e, const double *par, double s2_init)
{
    const double mu = par[0], om = par[1], al = par[2], be = par[3], ga = par[4];
    double v = s2_init, tot;
    slc_acc a;
    int t;
    if (!isfinite(mu) || !isfinite(om) || !isfinite(al) || !isfinite(be) || !isfinite(ga)) return INFINITY;
    slc_acc_init(&a, 0.0);
    for (t = 0; t < n; t++) {
        const double ep = e[t] - mu;
        slc_acc_add(&a, log(v) + (ep * ep) / v);
        v = om + (al + ga * (ep < 0.0 ? 1.0 : 0.0)) * (ep * ep) + be * v;
        if (v < GARCH_FLOOR) v = GARCH_FLOOR;
    }
    tot = 0.5 * ((double) n * SLC_LN_2PI + slc_acc_val(&a));
    return isfinite(tot) ? tot : INFINITY;
}

int sl_garch11_nll(sl_ctx *cx, int n, const double *e, int gjr, const double *par, double s2_init,
                   double *nll)
{
    double p[5];
    int st = check_series(cx, n, e, 1, "garch11_nll");
    if (st != SL_OK) return st;
    memcpy(p, par, 4 * sizeof(double));
    p[4] = gjr ? par[4] : 0.0;
    if (isnan(s2_init)) s2_init = var_c(n, e, mean_c(n, e));
    *nll = nll_par(n, e, p, s2_init);
    return SL_OK;
}

typedef struct { int n, gjr; const double *e; double s2_init; } garch_data;

static double garch_obj(const double *th, void *data)
{
    const garch_data *d = (const garch_data *) data;
    double par[5];
    sl_garch11_unpack(d->gjr, th, par);
    return nll_par(d->n, d->e, par, d->s2_init);
}

/* N3: GJR-Zielfunktion und ihr analytischer Gradient nach theta = (mu, log omega, a, g, b) in einem
 * Durchlauf (Vorwärtsmodus, Griewank/Walther 2008; Ableitungen der GARCH-Likelihood wie bei
 * Fiorentini/Calzolari/Panattoni 1996, hier für die Umparametrisierung und GJR). Mit
 * c+ = alpha, c- = alpha + gamma (Koeffizient von eps^2 bei eps >= 0 bzw. eps < 0) gilt
 * s2_{t+1} = omega + c_t eps_t^2 + beta s2_t; die Ableitungen D = d s2_t / d(mu, omega, c+, c-, beta)
 * laufen mit derselben Rekursion mit (s2_1 fest, also D_1 = 0; an der Untergrenze D = 0):
 *   D_mu' = beta D_mu - 2 c_t eps_t,  D_omega' = 1 + beta D_omega,  D_c+' = 1{eps_t >= 0} eps_t^2 + beta D_c+,
 *   D_c-' = 1{eps_t < 0} eps_t^2 + beta D_c-,  D_beta' = s2_t + beta D_beta,
 * und dNLL = 1/2 sum q_t D_t mit q_t = (1 - eps_t^2/s2_t)/s2_t, für mu zusätzlich -eps_t/s2_t. Zum Schluss die
 * Kettenregel über omega = exp(theta_omega) und (c+/2, c-/2, beta) = softmax: d s_i / d th_j = s_i (1{i=j} - s_j).
 * N4: sGARCH (gjr = 0, theta = (mu, log omega, a, b)) mit demselben Durchlauf ohne den Asymmetrie-Term:
 * c_t = alpha für beide Vorzeichen, D_alpha' = eps_t^2 + beta D_alpha (an der Stelle von D_c+, D_c- entfällt),
 * Kettenregel über (alpha, beta) = softmax.
 * Je Zeitpunkt eine Division und kein Logarithmus: sum log s2_t läuft über ein Produkt, das bei Verlassen von
 * [2^-600, 2^600] logarithmiert und neu begonnen wird (s2_t >= 1e-14 > 2^-47; s2_t > 2^400 geht einzeln in
 * die Summe, damit das Produkt endlich bleibt). Der Indikator 1{eps < 0} wird je Zeitpunkt einmal bestimmt.
 * NLL: eps_t^2/s2_t in Teilsummen über je 32 Zeitpunkte, diese und die Logarithmen kompensiert (Neumaier);
 * Summen des Gradienten einfach. Gemessen (scratchpad/en3/): relativer Fehler von f gegen eine Rechnung in
 * long double höchstens 7e-16 wie bei sl_garch11_nll (Logarithmus je Zeitpunkt, alles kompensiert).
 * gjr ist in beiden Aufrufen (gjr_fg, sg_fg) eine Konstante; mit GARCH_FG_INLINE (GCC, Clang) wird die
 * Schleife je Modell eigens übersetzt (gemessen, scratchpad/en4/: GJR sonst bis 14 % langsamer als in N3,
 * sGARCH 15 %). Die Ergebnisse hängen davon nicht ab. Nicht endlich: +Inf, g = NaN (4 bzw. 5 Werte). */
#if defined(__GNUC__)
#define GARCH_FG_INLINE inline __attribute__((always_inline))
#else
#define GARCH_FG_INLINE inline
#endif
static GARCH_FG_INLINE double garch_fg(int n, const double *e, const double *th, double s2_init, double *g, const int gjr)
{
    const int np = gjr ? 5 : 4;
    const double e1 = exp(th[2]), e2 = exp(th[3]), e3 = gjr ? exp(th[4]) : 0.0;
    const double d = gjr ? 1.0 + ((e1 + e2) + e3) : 1.0 + (e1 + e2);
    const double mu = th[0], om = exp(th[1]), al = gjr ? 2.0 * e1 / d : e1 / d, ga = gjr ? 2.0 * (e2 - e1) / d : 0.0,
                 be = gjr ? e3 / d : e2 / d;
    const double cp = al + ga * 0.0, cn = al + ga * 1.0;   /* wie (alpha + gamma 1{eps < 0}) in nll_par */
    double v = s2_init, P = 1.0, tot, bs = 0.0;
    double Dm = 0.0, Do = 0.0, Dp = 0.0, Dn = 0.0, Db = 0.0, Gm = 0.0, Go = 0.0, Gp = 0.0, Gn = 0.0, Gb = 0.0;
    slc_acc a;
    int t;
    if (!isfinite(mu) || !isfinite(om) || !isfinite(al) || !isfinite(be) || !isfinite(ga)) goto bad;
    slc_acc_init(&a, 0.0);
    for (t = 0; t < n; t++) {
        const double ep = e[t] - mu, ep2 = ep * ep, iv = 1.0 / v, r = ep2 * iv, q = (1.0 - r) * iv, m2ep = -2.0 * ep;
        const int neg = gjr && ep < 0.0;
        const double c = neg ? cn : cp, pn = neg ? ep2 : 0.0;
        double vn;
        if (v > 0x1p400) slc_acc_add(&a, log(v)); else P *= v;
        if (P < 0x1p-600 || P > 0x1p600) { slc_acc_add(&a, log(P)); P = 1.0; }
        bs += r;
        if ((t & 31) == 31) { slc_acc_add(&a, bs); bs = 0.0; }
        Gm += q * Dm + m2ep * iv; Go += q * Do; Gp += q * Dp; Gb += q * Db;
        if (gjr) Gn += q * Dn;
        vn = om + c * ep2 + be * v;
        if (vn < GARCH_FLOOR) { vn = GARCH_FLOOR; Dm = Do = Dp = Dn = Db = 0.0; }
        else {
            Dm = be * Dm + c * m2ep; Do = 1.0 + be * Do;
            Dp = (ep2 - pn) + be * Dp; Db = v + be * Db;   /* sGARCH: Dp = D_alpha (pn = 0) */
            if (gjr) Dn = pn + be * Dn;
        }
        v = vn;
    }
    slc_acc_add(&a, bs);
    slc_acc_add(&a, log(P));
    tot = 0.5 * ((double) n * SLC_LN_2PI + slc_acc_val(&a));
    if (!isfinite(tot)) goto bad;
    g[0] = 0.5 * Gm; g[1] = 0.5 * Go * om;
    if (gjr) {
        const double s1 = e1 / d, s2 = e2 / d, s3 = e3 / d;
        const double A = Gp * s1, B = Gn * s2, C = 0.5 * Gb * s3, T = (A + B) + C;   /* c+ = 2 s1, c- = 2 s2 */
        g[2] = A - s1 * T; g[3] = B - s2 * T; g[4] = C - s3 * T;
    } else {
        const double s1 = e1 / d, s2 = e2 / d;
        const double A = 0.5 * Gp * s1, C = 0.5 * Gb * s2, T = A + C;   /* alpha = s1, beta = s2 */
        g[2] = A - s1 * T; g[3] = C - s2 * T;
    }
    for (t = 0; t < np; t++) if (!isfinite(g[t])) goto bad;
    return tot;
bad:
    for (t = 0; t < np; t++) g[t] = NAN;
    return INFINITY;
}

static double gjr_fg(int n, const double *e, const double *th, double s2_init, double *g)
{
    return garch_fg(n, e, th, s2_init, g, 1);
}

/* N4: sGARCH, theta = (mu, log omega, a, b) */
static double sg_fg(int n, const double *e, const double *th, double s2_init, double *g)
{
    return garch_fg(n, e, th, s2_init, g, 0);
}

/* N6: sGARCH-NLL an K Startpunkten (alle mit mu = m, Parameter q[j] = (omega, alpha, beta)) in einem
 * Durchlauf, ohne Gradient, für die Auswahl des Startpunkts. Je Punkt dieselbe Rekursion wie nll_par, aber
 * ohne Logarithmus je Zeitpunkt (laufendes Produkt wie garch_fg) und mit unabhängigen Ketten je Punkt, die
 * der Prozessor überlappt; gemessen (scratchpad/en6/) etwa ein Drittel der Zeit von K Aufrufen nll_par.
 * Summen wie in garch_fg: eps^2/s2 in Teilsummen über 32 Zeitpunkte, Teilsummen und Logarithmen
 * kompensiert (Neumaier). Nicht endlich: +Inf. Genutzt nur für Vergleiche (kleinste NLL). */
#define SCR_MAX 6
static GARCH_FG_INLINE void nll_screen(int n, const double *e, double mu, const double (*q)[3], double s2_init,
                                       double *f, const int K)
{
    double v[SCR_MAX], P[SCR_MAX], bs[SCR_MAX];
    slc_acc a[SCR_MAX];
    int t, j;
    for (j = 0; j < K; j++) { v[j] = s2_init; P[j] = 1.0; bs[j] = 0.0; slc_acc_init(&a[j], 0.0); }
    for (t = 0; t < n; t++) {
        const double ep = e[t] - mu, ep2 = ep * ep;
        for (j = 0; j < K; j++) {
            const double vj = v[j];
            double vn;
            if (vj > 0x1p400) slc_acc_add(&a[j], log(vj)); else P[j] *= vj;
            if (P[j] < 0x1p-600 || P[j] > 0x1p600) { slc_acc_add(&a[j], log(P[j])); P[j] = 1.0; }
            bs[j] += ep2 / vj;
            vn = q[j][0] + q[j][1] * ep2 + q[j][2] * vj;
            v[j] = vn < GARCH_FLOOR ? GARCH_FLOOR : vn;
        }
        if ((t & 31) == 31) for (j = 0; j < K; j++) { slc_acc_add(&a[j], bs[j]); bs[j] = 0.0; }
    }
    for (j = 0; j < K; j++) {
        double tot;
        slc_acc_add(&a[j], bs[j]);
        slc_acc_add(&a[j], log(P[j]));
        tot = 0.5 * ((double) n * SLC_LN_2PI + slc_acc_val(&a[j]));
        f[j] = isfinite(tot) ? tot : INFINITY;
    }
}

/* N6: zweite Startfamilie des sGARCH-Fits (alpha, beta) mit kleinerem beta, für Ergebnisse am Rand alpha -> 0
 * (siehe sl_garch11_fit) */
#define SG2_N 6
#define SG2_ALPHA 0.01
static const double grid_s2[SG2_N][2] = {{0.05, 0.50}, {0.10, 0.10}, {0.01, 0.70}, {0.02, 0.50}, {0.20, 0.10}, {0.10, 0.30}};

int sl_garch11_grad(sl_ctx *cx, int n, const double *e, int gjr, const double *theta, double s2_init,
                    double *nll, double *grad)
{
    int st = check_series(cx, n, e, 1, "garch11_grad");
    if (st != SL_OK) return st;
    if (isnan(s2_init)) s2_init = var_c(n, e, mean_c(n, e));
    *nll = gjr ? gjr_fg(n, e, theta, s2_init, grad) : sg_fg(n, e, theta, s2_init, grad);   /* N4: auch sGARCH */
    return SL_OK;
}

/* ── ML-Schätzung ── */

/* N3: GJR – BFGS mit analytischem Gradienten (gjr_fg) über sl_minimize von jedem Rasterpunkt mit endlicher
 * NLL (Varianz-Targeting wie bei sGARCH), der beste Lauf gewinnt, bei Gleichstand der erste. f und g kommen
 * aus einem Durchlauf: Bei jeder Anfrage nach f wird g mitgerechnet und aufbewahrt; die Anfrage nach g am
 * selben Punkt (BFGS fragt sie nach erfüllter Abnahmebedingung, in den Messungen bei 92 % der Punkte) liest
 * nur den Speicher. Alle sieben Starts laufen bis zum Ende: Ein kurzer Vorlauf mit Fortsetzung nur der besten
 * Starts sparte 13–35 %, traf aber auf neuen Reihen nicht immer das Optimum (scratchpad/en3/). (N1: von nur
 * einem Start blieb BFGS auf fast unabhängigen Reihen an der Grenze beta -> 1 hängen, scratchpad/en1/.)
 * N4: sGARCH ebenso mit sg_fg und demselben Speicher, Start wie bisher nur vom besten Rasterpunkt. */
typedef struct { const garch_data *d; double xc[5], gc[5]; int have; } fg_cache;

static double fg_obj(const double *th, void *data)
{
    fg_cache *k = (fg_cache *) data;
    const garch_data *d = k->d;
    const size_t sz = (size_t) sl_garch11_npar(d->gjr) * sizeof(double);
    double f = d->gjr ? gjr_fg(d->n, d->e, th, d->s2_init, k->gc) : sg_fg(d->n, d->e, th, d->s2_init, k->gc);
    memcpy(k->xc, th, sz);
    k->have = 1;
    return f;
}

static void fg_gr(const double *th, double *g, void *data)
{
    fg_cache *k = (fg_cache *) data;
    const garch_data *d = k->d;
    const size_t sz = (size_t) sl_garch11_npar(d->gjr) * sizeof(double);
    if (k->have && memcmp(k->xc, th, sz) == 0) memcpy(g, k->gc, sz);
    else if (d->gjr) gjr_fg(d->n, d->e, th, d->s2_init, g);
    else sg_fg(d->n, d->e, th, d->s2_init, g);
}

static int fit_gjr(sl_ctx *cx, garch_data *d, double m, double v, const sl_opt_ctrl *ctrl, double *par,
                   double *loglik, int *code)
{
    sl_opt_ctrl c;
    double ths[GRID_NG][5], fs[GRID_NG], th[5], best_th[5], best = INFINITY, ps[5], fmin;
    int i, st, iter, nfev, cd, have = 0, any = 0;
    fg_cache k;
    for (i = 0; i < GRID_NG; i++) {
        double p[5];
        p[0] = m;
        p[1] = v * (1.0 - grid_g[i][0] - grid_g[i][1] / 2.0 - grid_g[i][2]);
        p[2] = grid_g[i][0]; p[3] = grid_g[i][2]; p[4] = grid_g[i][1];
        if (sl_garch11_pack(cx, 1, p, ths[i]) != SL_OK) return cx->status;
        fs[i] = garch_obj(ths[i], d);
        if (isfinite(fs[i])) any = 1;
    }
    if (!any) return sl_fail(cx, SL_ENONFINITE, "GARCH: Log-Likelihood an allen Startwerten nicht endlich");
    if (ctrl) c = *ctrl;
    else { sl_opt_ctrl_default(&c, SL_OPT_BFGS); c.maxit = 500; c.reltol = 1e-10; }
    if (c.parscale == NULL) {
        ps[0] = sqrt(v);
        for (i = 1; i < 5; i++) ps[i] = 1.0;
        c.parscale = ps;
    }
    k.d = d;
    *code = -1;
    for (i = 0; i < GRID_NG; i++) {
        if (!isfinite(fs[i])) continue;
        memcpy(th, ths[i], sizeof th);
        k.have = 0;
        st = sl_minimize(cx, SL_OPT_BFGS, 5, th, NULL, NULL, &c, fg_obj, fg_gr, &k, &fmin, &cd, &iter, &nfev);   /* N3 */
        if (st != SL_OK) return st;
        if (!have || fmin < best) { memcpy(best_th, th, sizeof th); best = fmin; *code = cd; have = 1; }
    }
    if (!isfinite(best)) return sl_fail(cx, SL_ECONV, "GARCH: Log-Likelihood nicht endlich (Code %d)", *code);
    sl_garch11_unpack(1, best_th, par);
    *loglik = -best;
    return SL_OK;
}

int sl_garch11_fit(sl_ctx *cx, int n, const double *e, int gjr, const sl_opt_ctrl *ctrl,
                   double *par, double *loglik, int *code)
{
    garch_data d;
    sl_opt_ctrl c;
    double m, v, ths[3][5], q[SCR_MAX][3], fs[SCR_MAX], best_th[5], best = INFINITY, ps[5], fmin, g[5];
    int i, np = sl_garch11_npar(gjr), st, iter, nfev, ib = 0;
    fg_cache k;
    st = check_series(cx, n, e, 10, "GARCH");
    if (st != SL_OK) return st;
    m = mean_c(n, e);
    v = var_c(n, e, m);
    if (!(v > 0.0) || !isfinite(v)) return sl_fail(cx, SL_EARG, "GARCH: Varianz der Reihe ist 0");
    d.n = n; d.gjr = gjr; d.e = e; d.s2_init = v;
    if (gjr) return fit_gjr(cx, &d, m, v, ctrl, par, loglik, code);   /* N1 */
    /* Raster mit Varianz-Targeting; kleinste NLL, bei Gleichstand der erste Punkt (N6: die drei NLL in einem
     * Durchlauf, nll_screen) */
    for (i = 0; i < 3; i++) {
        double p[5];
        p[0] = m;
        p[1] = v * (1.0 - grid_s[i][0] - grid_s[i][1] / 2.0 - grid_s[i][2]);
        p[2] = grid_s[i][0]; p[3] = grid_s[i][2]; p[4] = grid_s[i][1];
        if (sl_garch11_pack(cx, gjr, p, ths[i]) != SL_OK) return cx->status;
        q[i][0] = p[1]; q[i][1] = p[2]; q[i][2] = p[3];
    }
    nll_screen(n, e, m, (const double (*)[3]) q, v, fs, 3);
    for (i = 0; i < 3; i++) if (i == 0 || fs[i] < best) { best = fs[i]; ib = i; }
    memcpy(best_th, ths[ib], (size_t) np * sizeof(double));
    if (!isfinite(best)) return sl_fail(cx, SL_ENONFINITE, "GARCH: Log-Likelihood an allen Startwerten nicht endlich");
    if (ctrl) c = *ctrl;
    else { sl_opt_ctrl_default(&c, SL_OPT_BFGS); c.maxit = 500; c.reltol = 1e-10; }
    if (c.parscale == NULL) {
        ps[0] = sqrt(v);
        for (i = 1; i < np; i++) ps[i] = 1.0;
        c.parscale = ps;
    }
    k.d = &d; k.have = 0;
    st = sl_minimize(cx, SL_OPT_BFGS, np, best_th, NULL, NULL, &c, fg_obj, fg_gr, &k,
                     &fmin, code, &iter, &nfev);   /* N4: analytischer Gradient (sg_fg) */
    if (st != SL_OK) return st;
    /* N6: Liegt das Ergebnis am Rand alpha < 0.01, läuft BFGS ein zweites Mal, vom besten Punkt (kleinste NLL,
     * bei Gleichstand der erste) der zweiten Familie grid_s2 mit kleinerem beta; das bessere Ergebnis gilt
     * (bei Gleichstand das erste). Von den drei Rasterpunkten mit beta >= 0.85 endet BFGS auf schwach
     * heteroskedastischen Reihen oft am Rand alpha -> 0 (beta -> 1 oder langer Grat in beta), obwohl ein
     * inneres Maximum mit kleinerem beta höher liegt (scratchpad/en6/: auf 160 Prüfreihen 37 Fälle um bis
     * 10,5 in der LL; ein Neustart am Ergebnis fand nur 2 davon, und nicht das Optimum). Ohne Randlage
     * bleibt alles wie bisher (bitgleich), mit Randlage ist das Ergebnis nie schlechter als bisher. */
    sl_garch11_unpack(gjr, best_th, g);
    if (g[2] < SG2_ALPHA) {
        double ths2[SG2_N][4], th2[4], f2;
        int cd2;
        for (i = 0; i < SG2_N; i++) {
            double p[5];
            p[0] = m; p[1] = v * (1.0 - grid_s2[i][0] - grid_s2[i][1]); p[2] = grid_s2[i][0]; p[3] = grid_s2[i][1]; p[4] = 0.0;
            if (sl_garch11_pack(cx, 0, p, ths2[i]) != SL_OK) return cx->status;
            q[i][0] = p[1]; q[i][1] = p[2]; q[i][2] = p[3];
        }
        nll_screen(n, e, m, (const double (*)[3]) q, v, fs, SG2_N);
        ib = 0;
        for (i = 1; i < SG2_N; i++) if (fs[i] < fs[ib]) ib = i;
        if (isfinite(fs[ib])) {
            memcpy(th2, ths2[ib], sizeof th2);
            k.have = 0;
            st = sl_minimize(cx, SL_OPT_BFGS, np, th2, NULL, NULL, &c, fg_obj, fg_gr, &k, &f2, &cd2, &iter, &nfev);
            if (st != SL_OK) return st;
            if (f2 < fmin) { memcpy(best_th, th2, sizeof th2); fmin = f2; *code = cd2; }
        }
    }
    if (!isfinite(fmin)) return sl_fail(cx, SL_ECONV, "GARCH: Log-Likelihood nicht endlich (Code %d)", *code);
    sl_garch11_unpack(gjr, best_th, g);
    memcpy(par, g, 5 * sizeof(double));
    *loglik = -fmin;
    return SL_OK;
}

/* ── ganze Stufe wie .fit_garch11 ── */

int sl_garch11_estimate(sl_ctx *cx, int n, const double *e, int gjr, double *par, double *loglik,
                        int *code, int *method, double *s2, double *z, double *s2_init,
                        double *persistence)
{
    double mu, sv, om, al, be, ga, v0, mz, sz, pers;
    double *eps;
    int t, st;
    st = check_series(cx, n, e, 2, "GARCH");
    if (st != SL_OK) return st;
    mu = mean_c(n, e);
    sv = var_c(n, e, mu);
    *loglik = NAN; *code = -1;
    if (sv < 1e-16) {
        par[0] = mu; par[1] = 1e-20; par[2] = 0.0; par[3] = 0.0; par[4] = 0.0;
        for (t = 0; t < n; t++) { s2[t] = 1e-20; z[t] = 0.0; }
        *method = SL_GARCH_KONSTANT; *s2_init = 1e-20; *persistence = 0.0;
        return SL_OK;
    }
    {
        sl_ctx c2;
        double p[5], ll;
        int cd;
        sl_ctx_init(&c2);
        c2.interrupted = cx->interrupted; c2.host = cx->host;
        st = sl_garch11_fit(&c2, n, e, gjr, NULL, p, &ll, &cd);
        if (st == SL_EINTR) return sl_fail(cx, SL_EINTR, "%s", c2.msg);
        if (st == SL_OK && isfinite(ll) && slc_all_finite(5, p)) {
            memcpy(par, p, 5 * sizeof(double));
            *loglik = ll; *code = cd; *method = SL_GARCH_ML;
        } else {
            par[0] = mu; par[2] = 0.08; par[3] = 0.88; par[4] = gjr ? 0.04 : 0.0;
            par[1] = sv * (1.0 - par[2] - par[3] - par[4] / 2.0);
            *method = SL_GARCH_MOMENTE;
        }
    }
    mu = par[0]; om = par[1]; al = par[2]; be = par[3]; ga = par[4];
    eps = (double *) malloc((size_t) n * sizeof(double));
    if (eps == NULL) return sl_fail(cx, SL_ENOMEM, "GARCH: kein Speicher");
    for (t = 0; t < n; t++) eps[t] = e[t] - mu;
    v0 = 1.0 - al - be - ga / 2.0;
    if (!(v0 > 1e-6)) v0 = 1e-6;
    v0 = om / v0;
    st = sl_garch11_filter(cx, n, eps, om, al, be, ga, v0, s2);
    if (st != SL_OK) { free(eps); return st; }
    for (t = 0; t < n; t++) {
        z[t] = eps[t] / sqrt(s2[t]);
        if (!isfinite(z[t])) z[t] = 0.0;
    }
    free(eps);
    mz = mean_c(n, z);
    sz = sqrt(var_c(n, z, mz));
    if (sz > 0.0) for (t = 0; t < n; t++) z[t] = (z[t] - mz) / sz;
    pers = al + be + ga / 2.0;
    *persistence = pers;
    *s2_init = pers < 0.9999 ? om / (1.0 - pers) : sv;
    return SL_OK;
}
