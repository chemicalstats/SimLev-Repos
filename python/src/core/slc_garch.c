/* core/slc_garch.c – GARCH(1,1) und GJR-GARCH(1,1) mit Normalverteilung (SimLev core)
 * Verfahren:  Modell e_t = mu + eps_t, eps_t = sigma_t z_t, z_t ~ N(0, 1),
 *             sigma_t^2 = omega + (alpha + gamma 1{eps_{t-1} < 0}) eps_{t-1}^2 + beta sigma_{t-1}^2
 *             (Bollerslev 1986; GJR: Glosten, Jagannathan, Runkle 1993), Start sigma_1^2 =
 *             Stichprobenvarianz von e (eigene Wahl wie h1 im eigenen MS-GARCH).
 *             Punktschätzer per Maximum Likelihood, NLL = 1/2 sum (log 2 pi + log sigma_t^2 +
 *             eps_t^2 / sigma_t^2), kompensiert summiert (Neumaier 1974). Parameter (GJR-Fit,
 *             sl_garch11_pack/unpack/grad; zum sGARCH-Fit siehe unten) ohne
 *             Nebenbedingungen über die Umparametrisierung des eigenen MS-GARCH mit einem Regime
 *             (SimLev r/R/ms_garch.R, .ms_garch_unpack): mu frei, omega = exp(theta_omega),
 *             sGARCH (alpha, beta) = exp(a, b) / (1 + Summe); GJR (alpha/2, (alpha + gamma)/2,
 *             beta) = exp(a, g, b) / (1 + Summe). Damit gelten omega, alpha, beta > 0, bei GJR
 *             alpha + gamma > 0 (gamma < 0 zulässig; bis 1.0.0 (alpha, gamma/2, beta), also
 *             gamma >= 0) und alpha + gamma/2 + beta < 1 von selbst: Das Bild ist genau das
 *             Innere des Bereichs, in dem die bedingte Varianz für jedes Vorzeichen von eps
 *             positiv bleibt und das Modell unter der Normalverteilung (E 1{eps < 0} = 1/2)
 *             stationär ist (Glosten, Jagannathan, Runkle 1993).
 *             Startwerte GJR: mu = Mittelwert, festes Raster (alpha, gamma, beta) wie in .ms_garch_fit
 *             (sieben Punkte: die drei sGARCH-Punkte mit gamma, zwei mit gamma < 0, zwei mit kleinem
 *             beta), omega über Varianz-Targeting; BFGS (slc_opt.c, sl_minimize) von jedem Rasterpunkt, der
 *             beste Lauf gewinnt, bei Gleichstand der erste; mit dem analytischen Gradienten aus einer
 *             Vorwärtsrekursion der Ableitungen von sigma_t^2 (garch_fg: f und g in einem Durchlauf,
 *             Logarithmen über ein laufendes Produkt);
 *             mu in Einheiten der Standardabweichung (parscale), damit die Hesse-Matrix gut
 *             skaliert ist.
 *             sGARCH (bis 1.1.0 BFGS in der Umparametrisierung, zuletzt mit zweitem Lauf bei Randlage): ein
 *             Optimierungslauf, Trust-Region-Newton mit exakter Hesse-Matrix (sg_fgh: f, g, H in einem
 *             Durchlauf) in den natürlichen Parametern ((mu - m)/sd, omega/v, alpha, beta) mit den
 *             Schranken omega >= 0, alpha >= 0, beta >= 0, alpha + beta <= 1 - 2^-50 über eine aktive
 *             Menge (der Abschluss des bisherigen Bereichs; an seinem Rand verschwindet der Gradient nicht wie
 *             unter exp/softmax). Startpunkt: kleinste NLL unter 12 Punkten mit Varianz-Targeting (die drei
 *             bisherigen, drei ARCH-Punkte mit großem alpha, sechs im Inneren) und 8 Momentenschätzern
 *             (kleinste Quadrate von eps_t^2 auf die GARCH-Regressoren je beta, sg_ls), nur ausgewertet,
 *             ohne Optimierung. Die Likelihood mit festem s2_1 hat echte lokale Optima am Rand (alpha = 0
 *             mit beta -> 1: dort ist dNLL/dalpha proportional zu -sum_k beta^k gamma_k(eps^2) > 0) und
 *             im Inneren; die Startwahl entscheidet, welches der Lauf erreicht.
 *             Filter: wie der frühere eigene Kern garch_filter (bis 1.0.0): s2[0] =
 *             s2_init, Rekursion wie oben, Untergrenze 1e-14.
 *             Ganze Stufe sl_garch11_estimate wie die eigene R-Funktion .fit_garch11
 *             (r/R/bootstrap.R) ohne die Übernahme: Varianz < 1e-16 "konstant", sonst ML,
 *             Rückfall Momente (ohne Nelder-Mead-Stufe), Filter, standardisierte Residuen.
 *             Nur Punktschätzer: keine Standardfehler, keine Hesse-Matrix.
 * Quellen:    Bollerslev, T. (1986). Generalized autoregressive conditional heteroskedasticity.
 *               Journal of Econometrics 31(3), 307–327.
 *             Glosten, L. R., Jagannathan, R., Runkle, D. E. (1993). On the relation between the
 *               expected value and the volatility of the nominal excess return on stocks. The
 *               Journal of Finance 48(5), 1779–1801.
 *             Neumaier, A. (1974). Rundungsfehleranalyse einiger Verfahren zur Summation endlicher
 *               Summen. ZAMM 54(1), 39–51.
 *             Nocedal, J., Wright, S. J. (2006). Numerical Optimization, 2. Aufl., Springer
 *               (BFGS, über slc_opt.c; Trust-Region-Verfahren Kap. 4, aktive Menge Kap. 16).
 *             Moré, J. J., Sorensen, D. C. (1983). Computing a trust region step. SIAM Journal on
 *               Scientific and Statistical Computing 4(3), 553–572 (Teilproblem, harter Fall).
 *             Golub, G. H., Van Loan, C. F. (2013). Matrix Computations, 4. Aufl., Johns Hopkins
 *               (Jacobi-Verfahren für die Eigenzerlegung, 8.5).
 *             Kristensen, D., Linton, O. (2006). A closed-form estimator for the GARCH(1,1) model.
 *               Econometric Theory 22(2), 323–337 (Momente der quadrierten Renditen als Startwahl).
 *             Fiorentini, G., Calzolari, G., Panattoni, L. (1996). Analytic derivatives and the
 *               computation of GARCH estimates. Journal of Applied Econometrics 11(4), 399–417
 *               (Rekursion der Ableitungen der bedingten Varianz; zweite Ableitungen).
 *             Griewank, A., Walther, A. (2008). Evaluating Derivatives, 2. Aufl., SIAM
 *               (Vorwärtsmodus, von Hand geschrieben).
 *             Eigener SimLev-Code: .ms_garch_unpack/.ms_garch_pack und das Raster aus
 *               r/R/ms_garch.R, .fit_garch11 aus r/R/bootstrap.R (bis zur Grenze des
 *               rugarch-Aufrufs), früher garch_filter (bis 1.0.0).
 * Konstanten: ln(2 pi) aus slc_constants.h (gen_constants.py). Verfahrensparameter (eigene Wahl,
 *             Raster wie .ms_garch_fit (GJR um Punkte mit gamma < 0 ergänzt), maxit 500, reltol 1e-10 (GJR);
 *             sGARCH Startpunkte sg_vt, sg_beta, Trust-Region-Radius 1 am Start, maxit 200, Ende bei
 *             pred <= 1e-8 |f| nach innerem Newton-Schritt bzw. pred <= 1e-15 |f|,
 *             Momente alpha 0.08, beta 0.88, gamma 0.04 wie .fit_garch11.
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen (rugarch,
 *             Rsolnp nicht gelesen).
 * Prüforakel: rugarch 1.5-6 ugarchfit (nur Plausibilität).
 */
#include "slc_internal.h"
#include "slc_la_internal.h"
#include "slc_opt.h"
#include "slc_constants.h"

#include <stdlib.h>
#include <string.h>

#define GARCH_FLOOR 1e-14

/* GJR zusätzlich mit gamma < 0 (alpha + gamma > 0) und mit kleinem beta (fast unabhängige Reihen:
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
        /* (alpha/2, (alpha + gamma)/2, beta) = exp(a, g, b) / (1 + Summe); gamma < 0 zulässig,
         * solange alpha + gamma > 0 (bis 1.0.0: (alpha, gamma/2, beta), also gamma >= 0) */
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
    if (gjr) { th[2] = log((al / 2.0) / r); th[3] = log(((al + ga) / 2.0) / r); th[4] = log(be / r); }
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

/* GJR-Zielfunktion und ihr analytischer Gradient nach theta = (mu, log omega, a, g, b) in einem
 * Durchlauf (Vorwärtsmodus, Griewank/Walther 2008; Ableitungen der GARCH-Likelihood wie bei
 * Fiorentini/Calzolari/Panattoni 1996, hier für die Umparametrisierung und GJR). Mit
 * c+ = alpha, c- = alpha + gamma (Koeffizient von eps^2 bei eps >= 0 bzw. eps < 0) gilt
 * s2_{t+1} = omega + c_t eps_t^2 + beta s2_t; die Ableitungen D = d s2_t / d(mu, omega, c+, c-, beta)
 * laufen mit derselben Rekursion mit (s2_1 fest, also D_1 = 0; an der Untergrenze D = 0):
 *   D_mu' = beta D_mu - 2 c_t eps_t,  D_omega' = 1 + beta D_omega,  D_c+' = 1{eps_t >= 0} eps_t^2 + beta D_c+,
 *   D_c-' = 1{eps_t < 0} eps_t^2 + beta D_c-,  D_beta' = s2_t + beta D_beta,
 * und dNLL = 1/2 sum q_t D_t mit q_t = (1 - eps_t^2/s2_t)/s2_t, für mu zusätzlich -eps_t/s2_t. Zum Schluss die
 * Kettenregel über omega = exp(theta_omega) und (c+/2, c-/2, beta) = softmax: d s_i / d th_j = s_i (1{i=j} - s_j).
 * sGARCH (gjr = 0, theta = (mu, log omega, a, b)) mit demselben Durchlauf ohne den Asymmetrie-Term:
 * c_t = alpha für beide Vorzeichen, D_alpha' = eps_t^2 + beta D_alpha (an der Stelle von D_c+, D_c- entfällt),
 * Kettenregel über (alpha, beta) = softmax.
 * Je Zeitpunkt eine Division und kein Logarithmus: sum log s2_t läuft über ein Produkt, das bei Verlassen von
 * [2^-600, 2^600] logarithmiert und neu begonnen wird (s2_t >= 1e-14 > 2^-47; s2_t > 2^400 geht einzeln in
 * die Summe, damit das Produkt endlich bleibt). Der Indikator 1{eps < 0} wird je Zeitpunkt einmal bestimmt.
 * NLL: eps_t^2/s2_t in Teilsummen über je 32 Zeitpunkte, diese und die Logarithmen kompensiert (Neumaier);
 * Summen des Gradienten einfach. Gemessen: relativer Fehler von f gegen eine Rechnung in
 * long double höchstens 7e-16 wie bei sl_garch11_nll (Logarithmus je Zeitpunkt, alles kompensiert).
 * gjr ist in beiden Aufrufen (gjr_fg, sg_fg) eine Konstante; mit GARCH_FG_INLINE (GCC, Clang) wird die
 * Schleife je Modell eigens übersetzt (gemessen: GJR sonst bis 14 % langsamer als mit eigener Schleife,
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

/* sGARCH, theta = (mu, log omega, a, b) */
static double sg_fg(int n, const double *e, const double *th, double s2_init, double *g)
{
    return garch_fg(n, e, th, s2_init, g, 0);
}

/* sGARCH-NLL an K Startpunkten (alle mit mu = m, Parameter q[j] = (omega, alpha, beta)) in einem
 * Durchlauf, ohne Gradient, für die Auswahl des Startpunkts. Je Punkt dieselbe Rekursion wie nll_par, aber
 * ohne Logarithmus je Zeitpunkt (laufendes Produkt wie garch_fg) und mit unabhängigen Ketten je Punkt, die
 * der Prozessor überlappt; gemessen etwa ein Drittel der Zeit von K Aufrufen nll_par.
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

int sl_garch11_grad(sl_ctx *cx, int n, const double *e, int gjr, const double *theta, double s2_init,
                    double *nll, double *grad)
{
    int st = check_series(cx, n, e, 1, "garch11_grad");
    if (st != SL_OK) return st;
    if (isnan(s2_init)) s2_init = var_c(n, e, mean_c(n, e));
    *nll = gjr ? gjr_fg(n, e, theta, s2_init, grad) : sg_fg(n, e, theta, s2_init, grad);   /* auch sGARCH */
    return SL_OK;
}

/* ── sGARCH-Fit in einem Lauf (Trust-Region-Newton mit Schranken) ── */

/* f, Gradient und Hesse-Matrix der sGARCH-NLL nach den natürlichen Parametern u = (mu, omega, alpha, beta)
 * in einem Durchlauf (Vorwärtsmodus, Griewank/Walther 2008; Fiorentini/Calzolari/Panattoni 1996). Mit
 * eps_t = e_t - mu, s_{t+1} = omega + alpha eps_t^2 + beta s_t, D = ds/du, H = d^2 s/du^2 (s_1 fest):
 *   D' = beta D + (-2 alpha eps, 1, eps^2, s),
 *   H' = beta H + e_beta D' + D e_beta' + C,  C_mu,mu = 2 alpha, C_mu,alpha = -2 eps
 * (nur mu-mu, mu-alpha und die Zeile beta sind besetzt: s ist linear in omega und alpha). Mit r = eps^2/s,
 * q = (1 - r)/s, c = (2r - 1)/s^2, w = 2 eps/s^2 ist 2 d^2 l_t = q H + c D D' + w (D e_mu' + e_mu D') + 2/s e_mu e_mu'
 * und 2 dl_t = q D - 2 eps/s e_mu. f wie in garch_fg (Produkt statt Logarithmus je Zeitpunkt, Teilsummen,
 * Neumaier), daher dieselbe Zahl wie sg_fg an demselben Punkt bis auf die Rundung in den Parametern.
 * An der Untergrenze GARCH_FLOOR sind D und H null. want = 0: nur f (g, h werden nicht geschrieben).
 * h: 4 x 4 voll, zeilenweise. Nicht endlich: +Inf. */
static GARCH_FG_INLINE double sg_fgh(int n, const double *e, const double *u, double s2_init, double *g, double *h,
                                      const int want)
{
    const double mu = u[0], om = u[1], al = u[2], be = u[3];
    double v = s2_init, P = 1.0, tot, bs = 0.0;
    double D0 = 0.0, D1 = 0.0, D2 = 0.0, D3 = 0.0, G0 = 0.0, G1 = 0.0, G2 = 0.0, G3 = 0.0;
    double Hmm = 0.0, Hma = 0.0, Hmb = 0.0, Hob = 0.0, Hab = 0.0, Hbb = 0.0;
    double A00 = 0.0, A01 = 0.0, A02 = 0.0, A03 = 0.0, A11 = 0.0, A12 = 0.0, A13 = 0.0, A22 = 0.0, A23 = 0.0, A33 = 0.0;
    double Qmm = 0.0, Qma = 0.0, Qmb = 0.0, Qob = 0.0, Qab = 0.0, Qbb = 0.0, E0 = 0.0, E1 = 0.0, E2 = 0.0, E3 = 0.0, Emm = 0.0;
    slc_acc a;
    int t;
    if (!isfinite(mu) || !isfinite(om) || !isfinite(al) || !isfinite(be)) return INFINITY;
    slc_acc_init(&a, 0.0);
    for (t = 0; t < n; t++) {
        const double ep = e[t] - mu, ep2 = ep * ep, iv = 1.0 / v, r = ep2 * iv;
        double vn;
        if (v > 0x1p400) slc_acc_add(&a, log(v)); else P *= v;
        if (P < 0x1p-600 || P > 0x1p600) { slc_acc_add(&a, log(P)); P = 1.0; }
        bs += r;
        if ((t & 31) == 31) { slc_acc_add(&a, bs); bs = 0.0; }
        if (want) {
            const double iv2 = iv * iv, q = (1.0 - r) * iv, c = (2.0 * r - 1.0) * iv2, w = 2.0 * ep * iv2;
            const double c0 = c * D0, c1 = c * D1, c2 = c * D2, c3 = c * D3;
            G0 += q * D0 - 2.0 * ep * iv; G1 += q * D1; G2 += q * D2; G3 += q * D3;
            A00 += c0 * D0; A01 += c0 * D1; A02 += c0 * D2; A03 += c0 * D3;
            A11 += c1 * D1; A12 += c1 * D2; A13 += c1 * D3; A22 += c2 * D2; A23 += c2 * D3; A33 += c3 * D3;
            Qmm += q * Hmm; Qma += q * Hma; Qmb += q * Hmb; Qob += q * Hob; Qab += q * Hab; Qbb += q * Hbb;
            E0 += w * D0; E1 += w * D1; E2 += w * D2; E3 += w * D3; Emm += iv;
        }
        vn = om + al * ep2 + be * v;
        if (vn < GARCH_FLOOR) {
            vn = GARCH_FLOOR;
            D0 = D1 = D2 = D3 = 0.0; Hmm = Hma = Hmb = Hob = Hab = Hbb = 0.0;
        } else if (want) {
            Hmm = be * Hmm + 2.0 * al; Hma = be * Hma - 2.0 * ep; Hmb = be * Hmb + D0;
            Hob = be * Hob + D1; Hab = be * Hab + D2; Hbb = be * Hbb + 2.0 * D3;
            D0 = be * D0 - 2.0 * al * ep; D1 = 1.0 + be * D1; D2 = ep2 + be * D2; D3 = v + be * D3;
        }
        v = vn;
    }
    slc_acc_add(&a, bs);
    slc_acc_add(&a, log(P));
    tot = 0.5 * ((double) n * SLC_LN_2PI + slc_acc_val(&a));
    if (!isfinite(tot)) return INFINITY;
    if (want) {
        g[0] = 0.5 * G0; g[1] = 0.5 * G1; g[2] = 0.5 * G2; g[3] = 0.5 * G3;
        h[0] = 0.5 * (((A00 + Qmm) + 2.0 * E0) + 2.0 * Emm);
        h[1] = 0.5 * (A01 + E1); h[2] = 0.5 * ((A02 + Qma) + E2); h[3] = 0.5 * ((A03 + Qmb) + E3);
        h[5] = 0.5 * A11; h[6] = 0.5 * A12; h[7] = 0.5 * (A13 + Qob);
        h[10] = 0.5 * A22; h[11] = 0.5 * (A23 + Qab); h[15] = 0.5 * (A33 + Qbb);
        h[4] = h[1]; h[8] = h[2]; h[12] = h[3]; h[9] = h[6]; h[13] = h[7]; h[14] = h[11];
        for (t = 0; t < 4; t++) if (!isfinite(g[t])) return INFINITY;
        for (t = 0; t < 16; t++) if (!isfinite(h[t])) return INFINITY;
    }
    return tot;
}

/* Arbeitsvariablen x = ((mu - m)/sd, omega/v, alpha, beta) mit m, v = Mittelwert und Varianz der Reihe, sd = sqrt(v):
 * alle Größen von der Ordnung 1, die Hesse-Matrix ist nur skaliert (keine Krümmung durch eine Abbildung). */
typedef struct { int n; const double *e; double m, sd, v; } sg_prob;

static double sg_eval(const sg_prob *p, const double *x, double *g, double *h, int want)
{
    const double sc[4] = {p->sd, p->v, 1.0, 1.0};
    double u[4], f;
    int i, j;
    u[0] = p->m + p->sd * x[0]; u[1] = p->v * x[1]; u[2] = x[2]; u[3] = x[3];
    f = want ? sg_fgh(p->n, p->e, u, p->v, g, h, 1) : sg_fgh(p->n, p->e, u, p->v, g, h, 0);   /* je eigens übersetzt */
    if (want && isfinite(f)) {
        for (i = 0; i < 4; i++) {
            g[i] *= sc[i];
            for (j = i; j < 4; j++) h[4 * i + j] = h[4 * j + i] = sc[i] * h[4 * i + j] * sc[j];
        }
    }
    return f;
}

/* Jacobi-Verfahren für eine symmetrische k x k-Matrix (k <= 4; Golub/Van Loan 2013, 8.5): A wird zerstört,
 * lam die Eigenwerte, V (zeilenweise k x k) die Eigenvektoren als Spalten. */
static void sym_eig(int k, double *A, double *lam, double *V)
{
    int i, j, p, q, sw;
    for (i = 0; i < k * k; i++) V[i] = 0.0;
    for (i = 0; i < k; i++) V[i * k + i] = 1.0;
    for (sw = 0; sw < 60; sw++) {
        double off = 0.0, nrm = 0.0;
        for (i = 0; i < k; i++)
            for (j = 0; j < k; j++) { nrm += A[i * k + j] * A[i * k + j]; if (i != j) off += A[i * k + j] * A[i * k + j]; }
        if (!(off > 1e-30 * nrm)) break;
        for (p = 0; p < k; p++)
            for (q = p + 1; q < k; q++) {
                const double apq = A[p * k + q];
                double th, t, c, s;
                if (apq == 0.0) continue;
                th = (A[q * k + q] - A[p * k + p]) / (2.0 * apq);
                t = (th >= 0.0 ? 1.0 : -1.0) / (fabs(th) + sqrt(th * th + 1.0));
                c = 1.0 / sqrt(t * t + 1.0); s = t * c;
                for (i = 0; i < k; i++) { const double x = A[i * k + p], y = A[i * k + q]; A[i * k + p] = c * x - s * y; A[i * k + q] = s * x + c * y; }
                for (i = 0; i < k; i++) { const double x = A[p * k + i], y = A[q * k + i]; A[p * k + i] = c * x - s * y; A[q * k + i] = s * x + c * y; }
                for (i = 0; i < k; i++) { const double x = V[i * k + p], y = V[i * k + q]; V[i * k + p] = c * x - s * y; V[i * k + q] = s * x + c * y; }
            }
    }
    for (i = 0; i < k; i++) lam[i] = A[i * k + i];
}

/* Trust-Region-Teilproblem min g'd + d'Hd/2 unter |d| <= del (k <= 4) über die Eigenzerlegung (Moré/Sorensen
 * 1983; Nocedal/Wright 2006, 4.3): d = -(H + lambda I)^{-1} g mit lambda >= max(0, -lambda_min) und |d| = del,
 * sonst der Newton-Schritt; harter Fall mit Anteil längs des kleinsten Eigenvektors. Rückgabe 1, wenn d der
 * Newton-Schritt im Inneren ist. */
static int tr_sub(int k, const double *H, const double *g, double del, double *d)
{
    double A[16], lam[4], V[16], gt[4], lmin, lo, hi, gn = 0.0, l;
    int i, j, imin = 0, it;
    memcpy(A, H, (size_t) (k * k) * sizeof(double));
    sym_eig(k, A, lam, V);
    for (i = 0; i < k; i++) {
        gt[i] = 0.0;
        for (j = 0; j < k; j++) gt[i] += V[j * k + i] * g[j];
        gn += g[i] * g[i];
    }
    gn = sqrt(gn);
    for (i = 1; i < k; i++) if (lam[i] < lam[imin]) imin = i;
    lmin = lam[imin];
    if (lmin > 0.0) {
        double s = 0.0;
        for (i = 0; i < k; i++) s += (gt[i] / lam[i]) * (gt[i] / lam[i]);
        if (sqrt(s) <= del) {
            for (j = 0; j < k; j++) { d[j] = 0.0; for (i = 0; i < k; i++) d[j] -= V[j * k + i] * gt[i] / lam[i]; }
            return 1;
        }
    }
    lo = lmin > 0.0 ? 0.0 : -lmin;
    if (lmin <= 0.0 && fabs(gt[imin]) <= 1e-12 * gn) {   /* harter Fall */
        double s = 0.0;
        for (i = 0; i < k; i++) if (i != imin && lam[i] > lmin) s += (gt[i] / (lam[i] - lmin)) * (gt[i] / (lam[i] - lmin));
        if (sqrt(s) <= del) {
            const double tau = sqrt(del * del - s);
            for (j = 0; j < k; j++) {
                d[j] = tau * V[j * k + imin];
                for (i = 0; i < k; i++) if (i != imin && lam[i] > lmin) d[j] -= V[j * k + i] * gt[i] / (lam[i] - lmin);
            }
            return 0;
        }
    }
    hi = lo + gn / del;
    l = lo + 0.5 * (hi - lo);
    for (it = 0; it < 100; it++) {   /* Newton für 1/|d(lambda)| = 1/del, mit Einschluss [lo, hi] */
        double s = 0.0, s3 = 0.0, nd, ln;
        for (i = 0; i < k; i++) { const double den = lam[i] + l, a2 = gt[i] * gt[i]; s += a2 / (den * den); s3 += a2 / (den * den * den); }
        nd = sqrt(s);
        if (fabs(nd - del) <= 1e-10 * del) break;
        if (nd > del) lo = l; else hi = l;
        ln = l - (1.0 / nd - 1.0 / del) / (s3 / (s * nd));
        if (!(ln > lo && ln < hi)) ln = 0.5 * (lo + hi);
        if (hi - lo <= 1e-15 * hi) break;
        l = ln;
    }
    for (j = 0; j < k; j++) { d[j] = 0.0; for (i = 0; i < k; i++) d[j] -= V[j * k + i] * gt[i] / (lam[i] + l); }
    return 0;
}

/* Nebenbedingungen a_j'x >= b_j: omega >= 0, alpha >= 0, beta >= 0, alpha + beta <= SG_PMAX (das Bild der
 * Abbildung bis 1.1.0 ist das Innere dieses Bereichs, Grenzwerte inklusive) */
#define SG_PMAX (1.0 - 0x1p-50)
#define SG_TOL1 1e-8   /* Ende nach innerem Newton-Schritt mit pred <= SG_TOL1 |f| (gemessen: LL wie mit 1e-10 bis 3e-12 relativ) */
static const double sg_a[4][4] = {{0, 1, 0, 0}, {0, 0, 1, 0}, {0, 0, 0, 1}, {0, 0, -1, -1}};
static double sg_slack(int j, const double *x) { return j < 3 ? x[j + 1] : SG_PMAX - (x[2] + x[3]); }

/* orthonormale Basis Z (4 x k, zeilenweise mit Zeilenlänge 4) des Nullraums der aktiven Normalen */
static int sg_null(const int *act, double *Z)
{
    double N[4][4], C[4][4];
    int m = 0, k = 0, i, j, l;
    for (j = 0; j < 4; j++) {
        double nr = 0.0;
        if (!act[j]) continue;
        for (i = 0; i < 4; i++) N[m][i] = sg_a[j][i];
        for (l = 0; l < m; l++) { double dp = 0.0; for (i = 0; i < 4; i++) dp += N[l][i] * N[m][i]; for (i = 0; i < 4; i++) N[m][i] -= dp * N[l][i]; }
        for (i = 0; i < 4; i++) nr += N[m][i] * N[m][i];
        nr = sqrt(nr);
        if (nr < 1e-12) continue;
        for (i = 0; i < 4; i++) N[m][i] /= nr;
        m++;
    }
    for (j = 0; j < 4 && k < 4 - m; j++) {
        double w[4] = {0.0, 0.0, 0.0, 0.0}, nr = 0.0;
        w[j] = 1.0;
        for (l = 0; l < m; l++) { const double dp = N[l][j]; for (i = 0; i < 4; i++) w[i] -= dp * N[l][i]; }
        for (l = 0; l < k; l++) { double dp = 0.0; for (i = 0; i < 4; i++) dp += C[l][i] * w[i]; for (i = 0; i < 4; i++) w[i] -= dp * C[l][i]; }
        for (i = 0; i < 4; i++) nr += w[i] * w[i];
        nr = sqrt(nr);
        if (nr < 1e-8) continue;
        for (i = 0; i < 4; i++) C[k][i] = w[i] / nr;
        k++;
    }
    for (l = 0; l < k; l++) for (i = 0; i < 4; i++) Z[i * 4 + l] = C[l][i];
    return k;
}

/* Trust-Region-Newton mit aktiver Menge (Nocedal/Wright 2006, Kap. 4 und 16.5) ab zulässigem x.
 * Je Schritt: aktive Menge = Nebenbedingungen auf der Grenze, außer denen mit negativem Multiplikator
 * (g = sum lambda_j a_j, kleinste Quadrate); Teilproblem im Nullraum; der Schritt endet an der ersten
 * verletzten Nebenbedingung (diese wird dort genau erfüllt); zeigt er sofort hinaus, wird sie aktiv und der
 * Schritt neu bestimmt. Annahme bei rho = (f - f_neu)/pred > 1e-4, Radius wie Nocedal/Wright Alg. 4.1.
 * Ende: pred <= 1e-15 |f|; angenommener innerer Newton-Schritt mit pred <= 1e-10 |f| (danach ist der Rest
 * quadratisch klein; an diesem Punkt nur f); Radius < 1e-14; code 1 bei maxit. */
static int sg_newton(sl_ctx *cx, const sg_prob *p, double *x, int maxit, double *fmin, int *code, int *nit)
{
    double g[4], H[16], f, del = 1.0;
    int it;
    f = sg_eval(p, x, g, H, 1);
    *code = 1;
    if (!isfinite(f)) { *fmin = f; *nit = 0; return SL_OK; }
    for (it = 0; it < maxit; it++) {
        int act[4], at[4], i, j, l, k = 0, inter = 0, rep, hit = -1, last;
        double Z[16], gz[4], Hz[16], dz[4], dd[4], xt[4], gt[4], Ht[16], ft, pred, rho, sn = 0.0, t = 1.0, gd = 0.0, dHd = 0.0;
        if (sl_interrupted(cx)) return SL_EINTR;
        for (j = 0; j < 4; j++) at[j] = act[j] = sg_slack(j, x) <= (j == 3 ? 4e-16 : 0.0);
        {   /* Multiplikatoren der Nebenbedingungen auf der Grenze */
            int idx[4], m = 0, r, c;
            double M[9], rhs[3], lam[3];
            for (j = 0; j < 4; j++) if (act[j]) idx[m++] = j;
            if (m > 3) m = 3;   /* nicht möglich: höchstens omega und zwei der übrigen */
            for (r = 0; r < m; r++) {
                rhs[r] = 0.0;
                for (i = 0; i < 4; i++) rhs[r] += sg_a[idx[r]][i] * g[i];
                for (c = 0; c < m; c++) { M[r * m + c] = 0.0; for (i = 0; i < 4; i++) M[r * m + c] += sg_a[idx[r]][i] * sg_a[idx[c]][i]; }
            }
            for (c = 0; c < m; c++)
                for (r = c + 1; r < m; r++) {
                    const double fc = M[r * m + c] / M[c * m + c];
                    for (l = c; l < m; l++) M[r * m + l] -= fc * M[c * m + l];
                    rhs[r] -= fc * rhs[c];
                }
            for (r = m - 1; r >= 0; r--) { double s = rhs[r]; for (l = r + 1; l < m; l++) s -= M[r * m + l] * lam[l]; lam[r] = s / M[r * m + r]; }
            for (r = 0; r < m; r++) if (lam[r] < 0.0) act[idx[r]] = 0;
        }
        for (rep = 0; rep < 5; rep++) {
            k = sg_null(act, Z);
            for (i = 0; i < k; i++) { gz[i] = 0.0; for (l = 0; l < 4; l++) gz[i] += Z[l * 4 + i] * g[l]; }
            for (i = 0; i < k; i++)
                for (j = 0; j < k; j++) {
                    double s = 0.0;
                    int a, b;
                    for (a = 0; a < 4; a++) for (b = 0; b < 4; b++) s += Z[a * 4 + i] * H[a * 4 + b] * Z[b * 4 + j];
                    Hz[i * k + j] = s;
                }
            for (i = 0; i < k; i++) for (j = 0; j < i; j++) Hz[i * k + j] = Hz[j * k + i] = 0.5 * (Hz[i * k + j] + Hz[j * k + i]);
            inter = tr_sub(k, Hz, gz, del, dz);
            for (l = 0; l < 4; l++) { dd[l] = 0.0; for (i = 0; i < k; i++) dd[l] += Z[l * 4 + i] * dz[i]; }
            t = 1.0; hit = -1;
            for (j = 0; j < 4; j++) {
                double ad = 0.0, sl;
                if (act[j]) continue;
                sl = sg_slack(j, x);
                for (i = 0; i < 4; i++) ad += sg_a[j][i] * dd[i];
                if (ad < 0.0 && sl + ad < 0.0) { const double tj = sl / (-ad); if (tj < t) { t = tj; hit = j; } }
            }
            if (hit >= 0 && t < 1e-8 && (at[hit] || t < 1e-12)) { act[hit] = 1; continue; }
            break;
        }
        if (t < 0.0) t = 0.0;
        for (i = 0; i < 4; i++) xt[i] = x[i] + t * dd[i];
        if (hit == 3) xt[3] = SG_PMAX - xt[2]; else if (hit >= 0) xt[hit + 1] = 0.0;
        for (i = 1; i < 4; i++) if (xt[i] < 0.0) xt[i] = 0.0;
        if (xt[2] + xt[3] > SG_PMAX) xt[3] = SG_PMAX - xt[2];
        for (i = 0; i < 4; i++) { gd += g[i] * dd[i]; for (j = 0; j < 4; j++) dHd += dd[i] * H[4 * i + j] * dd[j]; }
        pred = -(t * gd + 0.5 * t * t * dHd);
        if (!(pred > 1e-15 * fabs(f))) { *code = 0; break; }
        for (i = 0; i < 4; i++) sn += (xt[i] - x[i]) * (xt[i] - x[i]);
        sn = sqrt(sn);
        last = inter && t == 1.0 && pred <= SG_TOL1 * fabs(f);
        ft = sg_eval(p, xt, gt, Ht, !last);
        rho = isfinite(ft) ? (f - ft) / pred : -1.0;
        if (rho < 0.25) del = 0.25 * sn; else if (rho > 0.75 && sn > 0.99 * del) del *= 2.0;
        if (rho > 1e-4) {
            memcpy(x, xt, sizeof xt); f = ft;
            if (last) { *code = 0; it++; break; }
            memcpy(g, gt, sizeof g); memcpy(H, Ht, sizeof H);
        }
        if (del < 1e-14) { *code = 0; break; }
    }
    *fmin = f; *nit = it;
    return SL_OK;
}

/* Kleinste Quadrate je beta (Momente, ohne Optimierung): eps_t^2 - beta^(t-1) s_1 ~ omega A_t + alpha B_t
 * (t >= 2) mit A_t = sum_{j < t-1} beta^j, B_t = sum_j beta^j eps_{t-1-j}^2, also E(eps_t^2 | Vergangenheit) = s_t
 * (vgl. Kristensen/Linton 2006 für Momentenschätzer des GARCH(1,1)). Lösung der 2 x 2-Normalgleichungen;
 * negative Werte: die bessere der beiden Einparameter-Lösungen; alpha <= SG_PMAX - beta. K <= 6 Werte von beta in
 * einem Durchlauf (unabhängige Ketten). Ergebnis q[j] = (omega, alpha, beta). */
static void sg_ls(int n, const double *e, double mu, double s1, const double *be, int K, double (*q)[3])
{
    double A[SCR_MAX], B[SCR_MAX], C[SCR_MAX], saa[SCR_MAX], sab[SCR_MAX], sbb[SCR_MAX], say[SCR_MAX], sby[SCR_MAX];
    int t, j;
    for (j = 0; j < K; j++) { A[j] = B[j] = 0.0; C[j] = s1; saa[j] = sab[j] = sbb[j] = say[j] = sby[j] = 0.0; }
    for (t = 0; t < n; t++) {
        const double ep = e[t] - mu, y = ep * ep;
        for (j = 0; j < K; j++) {
            if (t > 0) {
                const double yy = y - C[j];
                saa[j] += A[j] * A[j]; sab[j] += A[j] * B[j]; sbb[j] += B[j] * B[j]; say[j] += A[j] * yy; sby[j] += B[j] * yy;
            }
            A[j] = 1.0 + be[j] * A[j]; B[j] = y + be[j] * B[j]; C[j] *= be[j];
            if (C[j] < 1e-290) C[j] = 0.0;   /* keine subnormalen Zahlen */
        }
    }
    for (j = 0; j < K; j++) {
        const double det = saa[j] * sbb[j] - sab[j] * sab[j], amax = SG_PMAX - be[j] > 0.0 ? SG_PMAX - be[j] : 0.0;
        double om = -1.0, al = -1.0;
        if (det > 1e-12 * (saa[j] * sbb[j])) { om = (sbb[j] * say[j] - sab[j] * sby[j]) / det; al = (saa[j] * sby[j] - sab[j] * say[j]) / det; }
        if (!(om >= 0.0) || !(al >= 0.0)) {
            double o1 = saa[j] > 0.0 ? say[j] / saa[j] : 0.0, a1 = sbb[j] > 0.0 ? sby[j] / sbb[j] : 0.0;
            if (!(o1 > 0.0)) o1 = 0.0;
            if (!(a1 > 0.0)) a1 = 0.0;
            if (o1 * say[j] >= a1 * sby[j]) { om = o1; al = 0.0; } else { om = 0.0; al = a1; }   /* kleinere Restsumme */
        }
        if (al > amax) al = amax;
        q[j][0] = om; q[j][1] = al; q[j][2] = be[j];
    }
}

/* Startpunkte des sGARCH-Fits (alpha, beta), omega über Varianz-Targeting: das bisherige Raster, ARCH-Punkte
 * mit großem alpha (große Ausreißer) und Punkte im Inneren; dazu die Momentenschätzer sg_ls für ein Raster in beta.
 * Gewählt nach Messung auf 211 bekannten und 480 neuen simulierten Reihen. */
#define SG_NV 12
static const double sg_vt[SG_NV][2] = {{0.05, 0.90}, {0.10, 0.85}, {0.03, 0.95}, {0.30, 0.0}, {0.60, 0.0}, {0.90, 0.0},
                                       {0.20, 0.50}, {0.35, 0.50}, {0.10, 0.70}, {0.35, 0.10}, {0.50, 0.10}, {0.20, 0.30}};
#define SG_NB 8
static const double sg_beta[SG_NB] = {0.0, 0.4, 0.7, 0.85, 0.92, 0.97, 0.995, 0.9999};

/* sGARCH-Fit in einem Optimierungslauf. Startpunkt: kleinste NLL (nll_screen, mu = Mittelwert, bei Gleichstand
 * der erste) unter den SG_NV + SG_NB Punkten oben; ausgewertet wird nur die NLL, ohne Optimierung. Von dort ein
 * Lauf sg_newton in den natürlichen Parametern mit den Schranken des Modells (omega >= 0, alpha, beta >= 0,
 * alpha + beta <= SG_PMAX). */
static int fit_sgarch(sl_ctx *cx, int n, const double *e, double m, double v, const sl_opt_ctrl *ctrl, double *par,
                      double *loglik, int *code)
{
    sg_prob p;
    double q[SG_NV + SG_NB][3], fs[SG_NV + SG_NB], x[4], f, best;
    int i, ib = 0, nit, st, maxit = (ctrl != NULL && ctrl->maxit > 0) ? ctrl->maxit : 200;
    for (i = 0; i < SG_NV; i++) { q[i][0] = v * (1.0 - sg_vt[i][0] - sg_vt[i][1]); q[i][1] = sg_vt[i][0]; q[i][2] = sg_vt[i][1]; }
    for (i = 0; i < SG_NB; i += SCR_MAX) sg_ls(n, e, m, v, sg_beta + i, SG_NB - i < SCR_MAX ? SG_NB - i : SCR_MAX, q + SG_NV + i);
    for (i = 0; i < SG_NV + SG_NB; i += SCR_MAX)
        nll_screen(n, e, m, (const double (*)[3]) (q + i), v, fs + i, SG_NV + SG_NB - i < SCR_MAX ? SG_NV + SG_NB - i : SCR_MAX);
    best = fs[0];
    for (i = 1; i < SG_NV + SG_NB; i++) if (fs[i] < best) { best = fs[i]; ib = i; }
    if (!isfinite(best)) return sl_fail(cx, SL_ENONFINITE, "GARCH: Log-Likelihood an allen Startwerten nicht endlich");
    p.n = n; p.e = e; p.m = m; p.v = v; p.sd = sqrt(v);
    x[0] = 0.0; x[1] = q[ib][0] / v; x[2] = q[ib][1]; x[3] = q[ib][2];
    st = sg_newton(cx, &p, x, maxit, &f, code, &nit);
    if (st != SL_OK) return st;
    if (!isfinite(f)) return sl_fail(cx, SL_ECONV, "GARCH: Log-Likelihood nicht endlich (Code %d)", *code);
    par[0] = m + p.sd * x[0]; par[1] = v * x[1]; par[2] = x[2]; par[3] = x[3]; par[4] = 0.0;
    *loglik = -f;
    return SL_OK;
}

/* ── ML-Schätzung ── */

/* GJR – BFGS mit analytischem Gradienten (gjr_fg) über sl_minimize von jedem Rasterpunkt mit endlicher
 * NLL (Varianz-Targeting wie bei sGARCH), der beste Lauf gewinnt, bei Gleichstand der erste. f und g kommen
 * aus einem Durchlauf: Bei jeder Anfrage nach f wird g mitgerechnet und aufbewahrt; die Anfrage nach g am
 * selben Punkt (BFGS fragt sie nach erfüllter Abnahmebedingung, in den Messungen bei 92 % der Punkte) liest
 * nur den Speicher. Alle sieben Starts laufen bis zum Ende: Ein kurzer Vorlauf mit Fortsetzung nur der besten
 * Starts sparte 13–35 %, traf aber auf neuen Reihen nicht immer das Optimum. Von nur einem Start blieb
 * BFGS auf fast unabhängigen Reihen an der Grenze beta -> 1 hängen, daher sieben Starts.
 * sGARCH bis 1.1.0 ebenso mit sg_fg und demselben Speicher (seitdem eigener Löser, fit_sgarch). */
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
        st = sl_minimize(cx, SL_OPT_BFGS, 5, th, NULL, NULL, &c, fg_obj, fg_gr, &k, &fmin, &cd, &iter, &nfev);
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
    double m, v;
    int st = check_series(cx, n, e, 10, "GARCH");
    if (st != SL_OK) return st;
    m = mean_c(n, e);
    v = var_c(n, e, m);
    if (!(v > 0.0) || !isfinite(v)) return sl_fail(cx, SL_EARG, "GARCH: Varianz der Reihe ist 0");
    d.n = n; d.gjr = gjr; d.e = e; d.s2_init = v;
    if (gjr) return fit_gjr(cx, &d, m, v, ctrl, par, loglik, code);
    return fit_sgarch(cx, n, e, m, v, ctrl, par, loglik, code);
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
