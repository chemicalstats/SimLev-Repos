/* core/slc_msgarch.c – MS-GARCH(1,1) mit Normalverteilung und univariates Gauß-HMM
 *                      (SimLev core, Etappe 9.4)
 * Verfahren:  Modell nach Haas, Mittnik, Paolella (2004): K Regime mit je einem GARCH(1,1)- bzw.
 *             GJR-GARCH(1,1)-Varianzpfad, die parallel auf den Daten laufen; Mittelwert 0;
 *             Regimewechsel als Markov-Kette mit Übergangsmatrix P (Zeile = von). Likelihood über
 *             den Hamilton-Filter (Hamilton 1989): h[1,k] = h1, h[t,k] = omega_k + (alpha_k +
 *             gamma_k 1{y_{t-1} < 0}) y_{t-1}^2 + beta_k h[t-1,k], f_t = sum_k pred[t,k] phi_k,
 *             filt = pred phi / f_t, pred[t+1,j] = sum_i P[i,j] filt[t,i], loglik = sum log f_t.
 *             Der Filter ist der eigene Kern simlev_ms_garch_filter (r/src/ms_garch_impl.c),
 *             Zeile für Zeile als C-ABI überführt (gleiche Rechenfolge und Klammerung); die
 *             Zielfunktion rechnet dieselben Schritte ohne die n x K-Felder.
 *             Umparametrisierung, stationäre Verteilung, Startwerte und Ablauf wie die eigene
 *             R-Funktion .ms_garch_fit (r/R/ms_garch.R, eigener Code seit Etappe 2):
 *             .ms_garch_unpack/.ms_garch_pack, .ms_garch_stat (Potenziteration), Startfamilie 1 aus
 *             dem Baum-Welch-EM des Gauß-HMM (Baum u. a. 1970; wie .hmm_em mit Start
 *             .hmm_init_rank, r/R/regimes.R), Startfamilie 2 aus der Rangeinteilung der
 *             rollierenden Volatilität (.rolling_vol, Quantile, .assign_regimes,
 *             .estimate_trans_mat), je mit dem festen Raster (alpha, gamma, beta) und den
 *             Start-Übergangsmatrizen P0 und P99. Optimierung ganz in C mit BFGS (slc_opt.c,
 *             maxit 500, reltol 1e-10; seit N1 mit analytischem Gradienten, siehe ms_grad_w) von
 *             jedem Startpunkt; der beste Lauf gewinnt, bei Gleichstand der erste. Ergänzung 9.4:
 *             sl_msgarch_estimate startet nach den beiden bisherigen Punkten (bester Rasterpunkt je
 *             Familie) auch von den übrigen Rasterpunkten; von denselben zwei Starts fand BFGS auf
 *             flachen, mehrgipfligen Likelihoods mitunter ein anderes lokales Maximum als optim
 *             (scratchpad/e94/). N1: GJR je Regime mit gamma < 0, solange alpha + gamma > 0
 *             (Umparametrisierung (alpha/2, (alpha + gamma)/2, beta) wie in slc_garch.c; Glosten,
 *             Jagannathan, Runkle 1993), Raster dafür um zwei Punkte mit gamma < 0 ergänzt (GJR 20
 *             statt 12 Starts, sGARCH unverändert 12). Danach Regime aufsteigend nach unbedingter
 *             Varianz, letzter Filterlauf, Mischungsvarianz und Viterbi-Pfad (Viterbi 1967; wie
 *             .hmm_viterbi, erstes Maximum). Ein nicht endlicher Wert der Zielfunktion zählt als
 *             +Inf (statt des Strafwerts 1e10 in R, SPEZ-9 B.8).
 *             HMM: skalierter Vorwärts-Rückwärts-Schritt wie der eigene Kern hmm_forward_backward
 *             (r/src/research_core_impl.h); M-Schritt mit gewichteten Mitteln und Varianzen
 *             (plus ridge), Abbruch bei |l - l_alt| < tol (1 + |l|).
 *             Quantile Typ 7 nach der dokumentierten Formel (1 - g) x_j + g x_{j+1}
 *             (Hyndman, Fan 1996); Rang mit Mittelrängen bei Bindungen; Einteilung in K gleich
 *             breite Intervalle der Ränge mit um 0.1 % der Spannweite erweiterten Rändern
 *             (dokumentiertes Verhalten von cut); Median als Mittel der beiden mittleren Werte.
 *             Summen über die Zeit kompensiert (Neumaier 1974), außer im überführten Filter.
 * Quellen:    Haas, M., Mittnik, S., Paolella, M. S. (2004). A new approach to Markov-switching
 *               GARCH models. Journal of Financial Econometrics 2(4), 493–530.
 *             Hamilton, J. D. (1989). A new approach to the economic analysis of nonstationary
 *               time series and the business cycle. Econometrica 57(2), 357–384.
 *             Baum, L. E., Petrie, T., Soules, G., Weiss, N. (1970). A maximization technique
 *               occurring in the statistical analysis of probabilistic functions of Markov chains.
 *               The Annals of Mathematical Statistics 41(1), 164–171.
 *             Viterbi, A. J. (1967). Error bounds for convolutional codes and an asymptotically
 *               optimum decoding algorithm. IEEE Transactions on Information Theory 13(2), 260–269.
 *             Hyndman, R. J., Fan, Y. (1996). Sample quantiles in statistical packages. The
 *               American Statistician 50(4), 361–365.
 *             Neumaier, A. (1974). ZAMM 54(1), 39–51. Nocedal, Wright (2006) (BFGS, slc_opt.c).
 *             N1: Glosten, L. R., Jagannathan, R., Runkle, D. E. (1993). The Journal of Finance
 *               48(5), 1779–1801 (Bereich der GJR-Parameter).
 *             Griewank, A., Walther, A. (2008). Evaluating Derivatives: Principles and Techniques
 *               of Algorithmic Differentiation, 2. Aufl., SIAM (Vorwärtsmodus; der Gradient ist
 *               von Hand nach der Kettenregel geschrieben, kein Werkzeug).
 *             Golub, G. H., Van Loan, C. F. (2013). Matrix Computations, 4. Aufl., Johns Hopkins
 *               University Press. Alg. 3.4.1 (LU mit Spaltenpivotsuche, Ableitung der stationären
 *               Verteilung).
 *             Eigener SimLev-Code: r/R/ms_garch.R, r/src/ms_garch_impl.c, r/R/regimes.R (.hmm_em,
 *               .hmm_init_rank, .hmm_init_cl, .hmm_viterbi, .ldmvn), hmm_forward_backward und
 *               roll_mean_core (r/src/research_core_impl.h).
 * Konstanten: 2 pi wie im eigenen Filter (2.0 * pi, pi aus slc_constants.h); Verfahrensparameter
 *             wie .ms_garch_fit (Raster, P99, 0.9 bei leeren Zeilen, HMM 300 Schritte, tol 1e-7,
 *             Fenster 21, ridge 1e-10 + 1e-6 var).
 * Reinraum:   geschrieben nur nach den genannten Quellen; kein Code und keine
 *             Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen (MSGARCH nicht
 *             gelesen).
 * Prüforakel: der bisherige eigene Fit .ms_garch_fit (optim-BFGS) und MSGARCH 2.51 (nur
 *             Plausibilität, scratchpad/e94/); N1: SimLev 1.0.0 und die MSGARCH-Werte aus M2,
 *             Gradient gegen zentrale Differenzen (scratchpad/en1/).
 */
#include "slc_internal.h"
#include "slc_la_internal.h"
#include "slc_opt.h"
#include "slc_constants.h"

#include <stdlib.h>
#include <string.h>

#define TWO_PI (2.0 * SLC_PI)

static double var_c(int n, const double *x);

/* ── Filter (überführt aus ms_garch_impl.c) ─────────────────────────────── */

static void filter_run(const double *y, int n, int K, const double *omega, const double *alpha,
                       const double *beta, const double *gamma, const double *P, const double *xi0,
                       double h1, double *h, double *pred, double *filt, double *lB, double *loglik)
{
    const double two_pi = TWO_PI;
    double ll = 0.0;
    int ok = 1, t, k, i, j;
    for (k = 0; k < K; k++) pred[(ptrdiff_t) n * k] = xi0[k];
    for (t = 0; t < n; t++) {
        if (t == 0) {
            for (k = 0; k < K; k++) h[(ptrdiff_t) n * k] = h1;
        } else {
            const double e = y[t - 1];
            const double e2 = e * e;
            const double ind = e < 0.0 ? 1.0 : 0.0;
            for (k = 0; k < K; k++) {
                const double a = alpha[k] + gamma[k] * ind;
                h[t + (ptrdiff_t) n * k] = omega[k] + a * e2 + beta[k] * h[t - 1 + (ptrdiff_t) n * k];
            }
        }
        {
            const double y2 = y[t] * y[t];
            double f = 0.0;
            for (k = 0; k < K; k++) {
                const double hk = h[t + (ptrdiff_t) n * k];
                const double q = (-0.5 * y2) / hk;
                const double phi = exp(q) / sqrt(two_pi * hk);
                lB[t + (ptrdiff_t) n * k] = q - 0.5 * log(two_pi * hk);
                filt[t + (ptrdiff_t) n * k] = pred[t + (ptrdiff_t) n * k] * phi;
                f = f + filt[t + (ptrdiff_t) n * k];
            }
            if (!isfinite(f) || f <= 0.0) ok = 0;
            else ll = ll + log(f);
            for (k = 0; k < K; k++) filt[t + (ptrdiff_t) n * k] = filt[t + (ptrdiff_t) n * k] / f;
        }
        if (t + 1 < n) {
            for (j = 0; j < K; j++) {
                double s = 0.0;
                for (i = 0; i < K; i++) s = s + P[i + (ptrdiff_t) K * j] * filt[t + (ptrdiff_t) n * i];
                pred[t + 1 + (ptrdiff_t) n * j] = s;
            }
        }
    }
    *loglik = ok ? ll : -INFINITY;
}

/* dieselbe Log-Likelihood ohne die n x K-Felder (gleiche Rechenschritte); w: 4 K double */
static double ms_loglik(const double *y, int n, int K, const double *omega, const double *alpha,
                        const double *beta, const double *gamma, const double *P, const double *xi0,
                        double h1, double *w)
{
    const double two_pi = TWO_PI;
    double *h = w, *pr = w + K, *fl = w + 2 * K, *pn = w + 3 * K;
    double ll = 0.0;
    int t, k, i, j;
    for (k = 0; k < K; k++) { pr[k] = xi0[k]; h[k] = h1; }
    for (t = 0; t < n; t++) {
        if (t > 0) {
            const double e = y[t - 1];
            const double e2 = e * e;
            const double ind = e < 0.0 ? 1.0 : 0.0;
            for (k = 0; k < K; k++) {
                const double a = alpha[k] + gamma[k] * ind;
                h[k] = omega[k] + a * e2 + beta[k] * h[k];
            }
        }
        {
            const double y2 = y[t] * y[t];
            double f = 0.0;
            for (k = 0; k < K; k++) {
                const double hk = h[k];
                const double q = (-0.5 * y2) / hk;
                const double phi = exp(q) / sqrt(two_pi * hk);
                fl[k] = pr[k] * phi;
                f = f + fl[k];
            }
            if (!isfinite(f) || f <= 0.0) return -INFINITY;
            ll = ll + log(f);
            for (k = 0; k < K; k++) fl[k] = fl[k] / f;
        }
        if (t + 1 < n) {
            for (j = 0; j < K; j++) {
                double s = 0.0;
                for (i = 0; i < K; i++) s = s + P[i + (ptrdiff_t) K * j] * fl[i];
                pn[j] = s;
            }
            memcpy(pr, pn, (size_t) K * sizeof(double));
        }
    }
    return ll;
}

int sl_msgarch_filter(sl_ctx *cx, int n, const double *y, int K, const double *omega,
                      const double *alpha, const double *beta, const double *gamma, const double *P,
                      const double *xi0, double h1, double *h, double *pred, double *filt, double *lB,
                      double *loglik)
{
    if (n < 1) return sl_fail(cx, SL_ESMALL, "ms_garch_filter: 'y' darf nicht leer sein.");
    if (K < 1 || K > 1000) return sl_fail(cx, SL_EARG, "ms_garch_filter: 'omega' muss 1 bis 1000 Werte haben (einen je Regime).");
    filter_run(y, n, K, omega, alpha, beta, gamma, P, xi0, h1, h, pred, filt, lB, loglik);
    return SL_OK;
}

/* ── Umparametrisierung, stationäre Verteilung (wie r/R/ms_garch.R) ─────── */

int sl_msgarch_npar(int K, int gjr) { return K * (gjr ? 4 : 3) + K * (K - 1); }

void sl_msgarch_unpack(int K, int gjr, const double *th, double *om, double *al, double *be,
                       double *ga, double *P)
{
    const int np = gjr ? 4 : 3;
    int k, i, j, pos;
    for (k = 0; k < K; k++) {
        const int b = k * np;
        om[k] = exp(th[b]);
        if (gjr) {
            /* N1: (alpha/2, (alpha + gamma)/2, beta) = exp(.) / (1 + Summe); gamma < 0 zulässig, solange
             * alpha + gamma > 0 (bis 1.0.0: (alpha, gamma/2, beta), also gamma >= 0, F9) */
            const double e1 = exp(th[b + 1]), e2 = exp(th[b + 2]), e3 = exp(th[b + 3]);
            const double d = 1.0 + ((e1 + e2) + e3);
            al[k] = 2.0 * e1 / d; ga[k] = 2.0 * (e2 - e1) / d; be[k] = e3 / d;
        } else {
            const double e1 = exp(th[b + 1]), e2 = exp(th[b + 2]);
            const double d = 1.0 + (e1 + e2);
            al[k] = e1 / d; be[k] = e2 / d; ga[k] = 0.0;
        }
    }
    pos = K * np;
    for (i = 0; i < K; i++) {
        double s = 0.0;
        for (j = 0; j < K; j++) P[i + K * j] = (j == i) ? 1.0 : exp(th[pos++]);
        for (j = 0; j < K; j++) s = s + P[i + K * j];
        for (j = 0; j < K; j++) P[i + K * j] = P[i + K * j] / s;
    }
}

void sl_msgarch_pack(int K, int gjr, const double *om, const double *al, const double *be,
                     const double *ga, const double *P, double *th)
{
    int k, i, j, p = 0;
    for (k = 0; k < K; k++) {
        const double g = gjr ? ga[k] : 0.0;
        const double r = 1.0 - al[k] - g / 2.0 - be[k];
        th[p++] = log(om[k]);
        if (gjr) { th[p++] = log((al[k] / 2.0) / r); th[p++] = log(((al[k] + g) / 2.0) / r); }   /* N1 */
        else th[p++] = log(al[k] / r);
        th[p++] = log(be[k] / r);
    }
    for (i = 0; i < K; i++) for (j = 0; j < K; j++) if (j != i) th[p++] = log(P[i + K * j] / P[i + K * i]);
}

void sl_msgarch_stat(int K, const double *P, double *pi)
{
    double p2[64], *q = K <= 64 ? p2 : (double *) malloc((size_t) K * sizeof(double));
    int it, i, j, k;
    for (k = 0; k < K; k++) pi[k] = 1.0 / K;
    if (q == NULL) return;
    for (it = 0; it < 1000; it++) {
        double mx = 0.0;
        for (j = 0; j < K; j++) {
            double s = 0.0;
            for (i = 0; i < K; i++) s += pi[i] * P[i + K * j];
            q[j] = s;
        }
        for (j = 0; j < K; j++) { double d = fabs(q[j] - pi[j]); if (!(d <= mx)) mx = d; }
        if (mx < 1e-12) break;
        memcpy(pi, q, (size_t) K * sizeof(double));
    }
    if (q != p2) free(q);
}

/* Arbeitsfeld der Zielfunktion: om, al, be, ga, xi0 (je K), P (K^2), Filter (4 K) */
typedef struct { int n, K, gjr; const double *y; double h1; double *w; double *gw; } ms_data;   /* gw: N1 */

static double ms_nll_w(const ms_data *d, const double *th)
{
    const int K = d->K;
    double *om = d->w, *al = om + K, *be = al + K, *ga = be + K, *xi0 = ga + K, *P = xi0 + K, *fw = P + K * K;
    double ll;
    int k;
    sl_msgarch_unpack(K, d->gjr, th, om, al, be, ga, P);
    for (k = 0; k < K; k++)
        if (!isfinite(om[k]) || !isfinite(al[k]) || !isfinite(be[k]) || !isfinite(ga[k])) return INFINITY;
    for (k = 0; k < K * K; k++) if (!isfinite(P[k])) return INFINITY;
    sl_msgarch_stat(K, P, xi0);
    ll = ms_loglik(d->y, d->n, K, om, al, be, ga, P, xi0, d->h1, fw);
    return isfinite(ll) ? -ll : INFINITY;
}

static double ms_obj(const double *th, void *data) { return ms_nll_w((const ms_data *) data, th); }

/* N1: Länge des Arbeitsfelds des analytischen Gradienten (ms_grad_w) */
static size_t ms_gw_len(int K, int gjr)
{
    const size_t G = (size_t) sl_msgarch_npar(K, gjr), nP = (size_t) K * (K - 1), Kz = (size_t) K;
    return 3 * Kz + Kz * 4 + 4 * Kz * G + 2 * G + 2 * Kz * nP + 4 * Kz + 5 * Kz + Kz * Kz;
}

/* N1: analytischer Gradient der negativen Log-Likelihood (dieselbe Funktion wie ms_nll_w), vorwärts
 * mitdifferenziert (Vorwärtsmodus der Kettenregel):
 *   Parameter je Regime k: omega = exp(t0); sGARCH (alpha, beta) = s(t1, t2), GJR (alpha/2,
 *   (alpha + gamma)/2, beta) = s(t1, t2, t3) mit s = Softmax mit 1 im Nenner, ds_i/dt_j = s_i (d_ij - s_j);
 *   Übergangsmatrix je Zeile i: P_ij = exp(t_ij) / (1 + sum_m exp(t_im)) (P_ii mit 1 im Zähler),
 *   dP_ij/dt_im = P_ij (d_jm - P_im).
 *   Stationäre Verteilung pi (Potenziteration wie sl_msgarch_stat): nach Konvergenz die exakte Ableitung
 *   aus dpi (I - P) = pi dP, sum dpi = 0; an der Grenze von 1000 Schritten die mitgeführte Ableitung der
 *   Iteration (Einzelheiten unten).
 *   Varianz: dh_t = d omega + d a_t y_{t-1}^2 + d beta h_{t-1} + beta dh_{t-1}, a_t = alpha + gamma 1{y_{t-1} < 0}
 *   (alpha bzw. alpha + gamma), dh_1 = 0 (h1 fest).
 *   Filter: phi_k = N(y_t; 0, h_k), d log phi_k = c_k dh_k mit c_k = (y_t^2 / h_k - 1) / (2 h_k);
 *   f = sum_k pr_k phi_k, d log f = sum_k [(phi_k / f) dpr_k + post_k c_k dh_k] mit post_k = pr_k phi_k / f;
 *   dpost_k = (phi_k / f) dpr_k + post_k c_k dh_k - post_k d log f;
 *   pr_{t+1,j} = sum_i P_ij post_i, dpr_{t+1,j} = sum_i (P_ij dpost_i + dP_ij post_i).
 * Rückgabe 0; bei nicht endlicher Likelihood -1 (g = NaN). gw: ms_gw_len(K, gjr) double. */
static int ms_grad_w(const ms_data *d, const double *th, double *g, double *gw)
{
    const int K = d->K, gjr = d->gjr, np = gjr ? 4 : 3, G = sl_msgarch_npar(K, gjr), nP = K * (K - 1), off = K * np;
    const int n = d->n;
    const double *y = d->y;
    const double two_pi = TWO_PI;
    double *om = d->w, *al = om + K, *be = al + K, *ga = be + K, *xi0 = ga + K, *P = xi0 + K;
    double *S = gw, *dh = S + 3 * K, *dpr = dh + 4 * K, *dps = dpr + (size_t) K * G, *dpn = dps + (size_t) K * G,
           *dfl = dpn + (size_t) K * G, *dll = dfl + (size_t) K * G, *dlf = dll + G, *dpi = dlf + G,
           *dq = dpi + (size_t) K * nP, *h = dq + (size_t) K * nP, *pr = h + K, *post = pr + K, *wk = post + K,
           *pi = wk + K, *q = pi + K, *ck = q + K, *pn = ck + K, *phi = pn + K, *Pm = phi + K;
    int t, k, i, j, m, a, it;
    sl_msgarch_unpack(K, gjr, th, om, al, be, ga, P);
    for (k = 0; k < K; k++)
        if (!isfinite(om[k]) || !isfinite(al[k]) || !isfinite(be[k]) || !isfinite(ga[k])) goto bad;
    for (k = 0; k < K * K; k++) if (!isfinite(P[k])) goto bad;
    /* Anteile s je Regime (aus theta wie in sl_msgarch_unpack) */
    for (k = 0; k < K; k++) {
        const int b = k * np;
        if (gjr) {
            const double e1 = exp(th[b + 1]), e2 = exp(th[b + 2]), e3 = exp(th[b + 3]);
            const double dd = 1.0 + ((e1 + e2) + e3);
            S[3 * k] = e1 / dd; S[3 * k + 1] = e2 / dd; S[3 * k + 2] = e3 / dd;
        } else {
            const double e1 = exp(th[b + 1]), e2 = exp(th[b + 2]);
            const double dd = 1.0 + (e1 + e2);
            S[3 * k] = e1 / dd; S[3 * k + 1] = e2 / dd; S[3 * k + 2] = 0.0;
        }
    }
    /* stationäre Verteilung wie sl_msgarch_stat (dieselben Schritte, also derselbe Wert wie in ms_nll_w),
     * mit Ableitung nach den P-Parametern. Erreicht die Potenziteration die Grenze von 1000 Schritten
     * (fast zerlegbares P, Eigenwert nahe 1), ist die gerechnete Näherung noch merklich von der exakten
     * Verteilung entfernt; dann gilt die mitgeführte Ableitung der Iteration, d(pi P) = dpi P + pi dP.
     * Bricht sie vorher ab (konvergiert), gilt die exakte Ableitung aus dpi (I - P) = pi dP mit
     * sum dpi = 0 (letzte Spalte von I - P durch Einsen ersetzt, LU mit Spaltenpivotsuche; Golub, Van
     * Loan 2013, Alg. 3.4.1): Die mitgeführte Ableitung ist dort unbrauchbar, weil die Iteration je nach
     * Startpunkt schon nach 0 Schritten endet (z. B. symmetrisches P). */
    for (k = 0; k < K; k++) pi[k] = 1.0 / K;
    for (k = 0; k < K * nP; k++) dpi[k] = 0.0;
    for (it = 0; it < 1000; it++) {
        double mx = 0.0;
        for (j = 0; j < K; j++) {
            double s2 = 0.0;
            for (i = 0; i < K; i++) s2 += pi[i] * P[i + K * j];
            q[j] = s2;
        }
        for (j = 0; j < K; j++) { double dd = fabs(q[j] - pi[j]); if (!(dd <= mx)) mx = dd; }
        if (mx < 1e-12) break;
        for (j = 0; j < K; j++) {
            for (a = 0; a < nP; a++) {
                const int r = a / (K - 1), c0 = a % (K - 1), mm = c0 < r ? c0 : c0 + 1;
                double s2 = 0.0;
                for (i = 0; i < K; i++) s2 += dpi[i * nP + a] * P[i + K * j];
                s2 += pi[r] * P[r + K * j] * ((j == mm ? 1.0 : 0.0) - P[r + K * mm]);
                dq[j * nP + a] = s2;
            }
        }
        memcpy(pi, q, (size_t) K * sizeof(double));
        memcpy(dpi, dq, (size_t) K * nP * sizeof(double));
    }
    if (nP > 0 && it < 1000) {
        double *A = Pm;
        int *piv = (int *) (void *) q;   /* K int passen in K double */
        for (j = 0; j < K; j++) for (i = 0; i < K; i++)      /* A = (I - P)' mit letzter Zeile 1 */
            A[j + K * i] = (j == K - 1) ? 1.0 : ((i == j ? 1.0 : 0.0) - P[i + K * j]);
        for (k = 0; k < K; k++) {                           /* LU mit Zeilentausch, A = L U */
            int ip = k;
            double mx = fabs(A[k + K * k]);
            for (i = k + 1; i < K; i++) if (fabs(A[i + K * k]) > mx) { mx = fabs(A[i + K * k]); ip = i; }
            piv[k] = ip;
            if (ip != k) for (j = 0; j < K; j++) { double tt = A[k + K * j]; A[k + K * j] = A[ip + K * j]; A[ip + K * j] = tt; }
            if (A[k + K * k] == 0.0) goto bad;
            for (i = k + 1; i < K; i++) {
                const double l = A[i + K * k] / A[k + K * k];
                A[i + K * k] = l;
                for (j = k + 1; j < K; j++) A[i + K * j] -= l * A[k + K * j];
            }
        }
        for (a = 0; a < nP; a++) {
            const int r = a / (K - 1), c0 = a % (K - 1), mm = c0 < r ? c0 : c0 + 1;
            double *x = dq + (size_t) a * K;
            for (j = 0; j < K; j++) x[j] = (j == K - 1) ? 0.0 : pi[r] * P[r + K * j] * ((j == mm ? 1.0 : 0.0) - P[r + K * mm]);
            for (k = 0; k < K; k++) if (piv[k] != k) { double tt = x[k]; x[k] = x[piv[k]]; x[piv[k]] = tt; }
            for (i = 1; i < K; i++) for (j = 0; j < i; j++) x[i] -= A[i + K * j] * x[j];
            for (i = K - 1; i >= 0; i--) {
                for (j = i + 1; j < K; j++) x[i] -= A[i + K * j] * x[j];
                x[i] /= A[i + K * i];
            }
            for (k = 0; k < K; k++) dpi[k * nP + a] = x[k];
        }
    }
    /* Filter mit Ableitungen */
    for (k = 0; k < K; k++) {
        pr[k] = pi[k]; h[k] = d->h1;
        for (a = 0; a < 4; a++) dh[4 * k + a] = 0.0;
        for (a = 0; a < G; a++) dpr[(size_t) k * G + a] = 0.0;
        for (a = 0; a < nP; a++) dpr[(size_t) k * G + off + a] = dpi[k * nP + a];
    }
    for (a = 0; a < G; a++) dll[a] = 0.0;
    for (t = 0; t < n; t++) {
        if (t > 0) {
            const double e = y[t - 1];
            const double e2 = e * e;
            const double ind = e < 0.0 ? 1.0 : 0.0;
            for (k = 0; k < K; k++) {
                const double ak = al[k] + ga[k] * ind, hp = h[k], bk = be[k];
                double *D = dh + 4 * k;
                const double *sk = S + 3 * k;
                D[0] = om[k] + bk * D[0];
                if (gjr) {
                    /* a = 2 s1 (y >= 0) bzw. 2 s2 (y < 0), beta = s3 */
                    const int ia = ind > 0.0 ? 1 : 0;
                    for (j = 0; j < 3; j++) {
                        const double ds_a = 2.0 * sk[ia] * ((ia == j ? 1.0 : 0.0) - sk[j]);
                        const double ds_b = sk[2] * ((j == 2 ? 1.0 : 0.0) - sk[j]);
                        D[1 + j] = ds_a * e2 + ds_b * hp + bk * D[1 + j];
                    }
                } else {
                    for (j = 0; j < 2; j++) {
                        const double ds_a = sk[0] * ((j == 0 ? 1.0 : 0.0) - sk[j]);
                        const double ds_b = sk[1] * ((j == 1 ? 1.0 : 0.0) - sk[j]);
                        D[1 + j] = ds_a * e2 + ds_b * hp + bk * D[1 + j];
                    }
                }
                h[k] = om[k] + ak * e2 + bk * hp;
            }
        }
        {
            const double y2 = y[t] * y[t];
            double f = 0.0;
            for (k = 0; k < K; k++) {
                const double hk = h[k];
                const double qq = (-0.5 * y2) / hk;
                phi[k] = exp(qq) / sqrt(two_pi * hk);
                post[k] = pr[k] * phi[k];
                f = f + post[k];
                ck[k] = (y2 / hk - 1.0) / (2.0 * hk);
            }
            if (!isfinite(f) || f <= 0.0) goto bad;
            for (k = 0; k < K; k++) { wk[k] = phi[k] / f; post[k] = post[k] / f; }
            for (a = 0; a < G; a++) dlf[a] = 0.0;
            for (k = 0; k < K; k++) {
                double *F = dfl + (size_t) k * G;
                const double *R = dpr + (size_t) k * G;
                const double pc = post[k] * ck[k];
                for (a = 0; a < G; a++) F[a] = wk[k] * R[a];
                for (j = 0; j < np; j++) F[k * np + j] += pc * dh[4 * k + j];
                for (a = 0; a < G; a++) dlf[a] += F[a];
            }
            for (a = 0; a < G; a++) dll[a] += dlf[a];
            for (k = 0; k < K; k++) {
                double *F = dfl + (size_t) k * G, *Q = dps + (size_t) k * G;
                for (a = 0; a < G; a++) Q[a] = F[a] - post[k] * dlf[a];
            }
        }
        if (t + 1 < n) {
            for (j = 0; j < K; j++) {
                double *Q = dpn + (size_t) j * G;
                double s2 = 0.0;
                for (a = 0; a < G; a++) Q[a] = 0.0;
                for (i = 0; i < K; i++) {
                    const double pij = P[i + K * j];
                    const double *Rp = dps + (size_t) i * G;
                    for (a = 0; a < G; a++) Q[a] += pij * Rp[a];
                    s2 = s2 + pij * post[i];
                }
                pn[j] = s2;
                /* dP_ij / dt_im = P_ij (d_jm - P_im), Parameter (i, m) an off + i (K - 1) + Rang von m */
                for (i = 0; i < K; i++) {
                    for (m = 0; m < K; m++) {
                        if (m == i) continue;
                        Q[off + i * (K - 1) + (m < i ? m : m - 1)] +=
                            post[i] * P[i + K * j] * ((j == m ? 1.0 : 0.0) - P[i + K * m]);
                    }
                }
            }
            memcpy(pr, pn, (size_t) K * sizeof(double));
            memcpy(dpr, dpn, (size_t) K * G * sizeof(double));
        }
    }
    for (a = 0; a < G; a++) g[a] = -dll[a];
    return 0;
bad:
    for (a = 0; a < G; a++) g[a] = NAN;
    return -1;
}

static void ms_gr(const double *th, double *g, void *data)
{
    const ms_data *d = (const ms_data *) data;
    ms_grad_w(d, th, g, d->gw);
}

static int ms_data_init(sl_ctx *cx, ms_data *d, int n, const double *y, int K, int gjr, double h1)
{
    d->n = n; d->K = K; d->gjr = gjr; d->y = y; d->h1 = h1;
    d->gw = NULL;
    d->w = (double *) malloc((size_t) (5 * K + K * K + 4 * K) * sizeof(double));
    if (d->w == NULL) return sl_fail(cx, SL_ENOMEM, "MS-GARCH: kein Speicher");
    return SL_OK;
}

/* N1: Arbeitsfeld des Gradienten anlegen (nur für Fit und sl_msgarch_grad) */
static int ms_data_grad(sl_ctx *cx, ms_data *d)
{
    d->gw = (double *) malloc(ms_gw_len(d->K, d->gjr) * sizeof(double));
    if (d->gw == NULL) { free(d->w); d->w = NULL; return sl_fail(cx, SL_ENOMEM, "MS-GARCH: kein Speicher"); }
    return SL_OK;
}

static void ms_data_free(ms_data *d) { free(d->w); free(d->gw); }

static int check_ms(sl_ctx *cx, int n, const double *y, int K, int Kmin)
{
    if (K < Kmin || K > 1000) return sl_fail(cx, SL_EARG, "MS-GARCH: Anzahl Regime muss zwischen %d und 1000 liegen (erhalten: %d)", Kmin, K);
    if (n < 10 || y == NULL) return sl_fail(cx, SL_ESMALL, "MS-GARCH: zu wenige Beobachtungen (n = %d, mindestens 10)", n);
    if (!slc_all_finite(n, y)) return sl_fail(cx, SL_ENONFINITE, "MS-GARCH: Reihe enthält nicht endliche Werte");
    return SL_OK;
}

int sl_msgarch_nll(sl_ctx *cx, int n, const double *y, int K, int gjr, const double *theta,
                   double h1, double *nll)
{
    ms_data d;
    int st = check_ms(cx, n, y, K, 1);
    if (st != SL_OK) return st;
    if (isnan(h1)) h1 = var_c(n, y);              /* h1 = NaN: Stichprobenvarianz */
    st = ms_data_init(cx, &d, n, y, K, gjr, h1);
    if (st != SL_OK) return st;
    *nll = ms_nll_w(&d, theta);
    ms_data_free(&d);
    return SL_OK;
}

int sl_msgarch_grad(sl_ctx *cx, int n, const double *y, int K, int gjr, const double *theta,
                    double h1, double *nll, double *grad)
{
    ms_data d;
    int st = check_ms(cx, n, y, K, 1);
    if (st != SL_OK) return st;
    if (K > 64) return sl_fail(cx, SL_EARG, "MS-GARCH: höchstens 64 Regime");
    if (isnan(h1)) h1 = var_c(n, y);              /* h1 = NaN: Stichprobenvarianz */
    st = ms_data_init(cx, &d, n, y, K, gjr, h1);
    if (st != SL_OK) return st;
    st = ms_data_grad(cx, &d);
    if (st != SL_OK) return st;
    *nll = ms_nll_w(&d, theta);
    ms_grad_w(&d, theta, grad, d.gw);
    ms_data_free(&d);
    return SL_OK;
}

int sl_msgarch_fit(sl_ctx *cx, int n, const double *y, int K, int gjr, int nstart,
                   const double *starts, double h1, const sl_opt_ctrl *ctrl, double *theta,
                   double *nll, int *code)
{
    ms_data d;
    sl_opt_ctrl c;
    const int np = sl_msgarch_npar(K, gjr);
    double *x, best = INFINITY, fmin;
    int st, s, cd, iter, nfev, have = 0;
    st = check_ms(cx, n, y, K, 1);
    if (st != SL_OK) return st;
    if (isnan(h1)) h1 = var_c(n, y);              /* h1 = NaN: Stichprobenvarianz */
    if (nstart < 1) return sl_fail(cx, SL_EARG, "MS-GARCH: keine Startpunkte");
    if (ctrl) c = *ctrl;
    else { sl_opt_ctrl_default(&c, SL_OPT_BFGS); c.maxit = 500; c.reltol = 1e-10; }
    if (K > 64) return sl_fail(cx, SL_EARG, "MS-GARCH: höchstens 64 Regime");    /* N1: Gradient */
    st = ms_data_init(cx, &d, n, y, K, gjr, h1);
    if (st != SL_OK) return st;
    st = ms_data_grad(cx, &d);
    if (st != SL_OK) return st;
    x = (double *) malloc((size_t) np * sizeof(double));
    if (x == NULL) { ms_data_free(&d); return sl_fail(cx, SL_ENOMEM, "MS-GARCH: kein Speicher"); }
    *code = -1;
    for (s = 0; s < nstart; s++) {
        memcpy(x, starts + (size_t) np * s, (size_t) np * sizeof(double));
        if (!isfinite(ms_obj(x, &d))) continue;        /* Start ohne endliche Likelihood auslassen */
        st = sl_minimize(cx, SL_OPT_BFGS, np, x, NULL, NULL, &c, ms_obj, ms_gr, &d, &fmin, &cd, &iter, &nfev);   /* N1: analytischer Gradient */
        if (st != SL_OK) break;
        if (!have || fmin < best) { memcpy(theta, x, (size_t) np * sizeof(double)); best = fmin; *code = cd; have = 1; }
    }
    free(x); ms_data_free(&d);
    if (st != SL_OK) return st;
    if (!have) return sl_fail(cx, SL_ENONFINITE, "MS-GARCH: Log-Likelihood an allen Startpunkten nicht endlich");
    *nll = best;
    return SL_OK;
}

/* ── kleine Hilfen ───────────────────────────────────────────────────────── */

static double mean_c(int n, const double *x)
{
    slc_acc a;
    int i;
    slc_acc_init(&a, 0.0);
    for (i = 0; i < n; i++) slc_acc_add(&a, x[i]);
    return slc_acc_val(&a) / n;
}

static double var_c(int n, const double *x)
{
    slc_acc a;
    double m;
    int i;
    if (n < 2) return NAN;
    m = mean_c(n, x);
    slc_acc_init(&a, 0.0);
    for (i = 0; i < n; i++) { double d = x[i] - m; slc_acc_add(&a, d * d); }
    return slc_acc_val(&a) / (n - 1);
}

/* stabile Reihenfolge (wie order): idx 0-basiert */
static int order_k(int K, const double *key, int *ord)
{
    int i, j;
    for (i = 0; i < K; i++) ord[i] = i;
    for (i = 1; i < K; i++) {               /* Einfügen, stabil */
        int v = ord[i];
        for (j = i - 1; j >= 0 && key[ord[j]] > key[v]; j--) ord[j + 1] = ord[j];
        ord[j + 1] = v;
    }
    return 0;
}

/* Zeilen mit Nullen oder nicht endlichen Werten: 0.9 auf der Diagonale, Rest gleich verteilt */
static void fix_P(int K, double *P)
{
    int i, j;
    for (i = 0; i < K; i++) {
        int bad = 0;
        for (j = 0; j < K; j++) if (!isfinite(P[i + K * j]) || P[i + K * j] == 0.0) bad = 1;
        if (bad) { for (j = 0; j < K; j++) P[i + K * j] = 0.1 / (K - 1); P[i + K * i] = 0.9; }
    }
}

/* Rasterpunkte einer Familie (Varianzen s2k aufsteigend, Start-Übergangsmatrizen P0 und P99, je MS_NG
 * Rasterpunkte): out = bester Punkt (kleinste NLL, bei Gleichstand der erste; wie .ms_garch_fit),
 * rest = die übrigen 2 MS_NG - 1 in Rasterreihenfolge (Ergänzung 9.4, siehe sl_msgarch_starts).
 * N1: bei GJR zwei Rasterpunkte mehr mit gamma < 0 (alpha + gamma > 0), hinter den bisherigen drei. */
#define MS_NG_S 3
#define MS_NG_G 5
#define MS_NG(gjr) ((gjr) ? MS_NG_G : MS_NG_S)
static void best_start(const ms_data *d, const double *s2k, const double *P0, double *out, double *rest)
{
    static const double gs[MS_NG_S][3] = {{0.05, 0.0, 0.90}, {0.10, 0.0, 0.85}, {0.03, 0.0, 0.95}};
    static const double gg[MS_NG_G][3] = {{0.03, 0.06, 0.90}, {0.05, 0.10, 0.82}, {0.02, 0.04, 0.94},
                                          {0.06, -0.03, 0.90}, {0.12, -0.05, 0.80}};
    const int K = d->K, np = sl_msgarch_npar(K, d->gjr), ng = MS_NG(d->gjr);
    const double (*grid)[3] = d->gjr ? gg : gs;
    double om[64], al[64], be[64], ga[64], P99[64 * 64], best = INFINITY;
    double *all = (double *) malloc(2 * (size_t) ng * (size_t) np * sizeof(double));
    int pst, g, k, i, j, have = 0, ib = 0, c = 0, r = 0;
    if (all == NULL) return;
    for (i = 0; i < K; i++) for (j = 0; j < K; j++) P99[i + K * j] = (i == j) ? 0.99 : 0.01 / (K - 1);
    for (pst = 0; pst < 2; pst++) for (g = 0; g < ng; g++) {
        double v, *th = all + (size_t) np * c;
        for (k = 0; k < K; k++) {
            al[k] = grid[g][0]; ga[k] = grid[g][1]; be[k] = grid[g][2];
            om[k] = s2k[k] * (1.0 - grid[g][0] - grid[g][1] / 2.0 - grid[g][2]);
        }
        sl_msgarch_pack(K, d->gjr, om, al, be, ga, pst == 0 ? P0 : P99, th);
        v = ms_nll_w(d, th);
        if (!have || v < best) { ib = c; best = v; have = 1; }
        c++;
    }
    memcpy(out, all + (size_t) np * ib, (size_t) np * sizeof(double));
    for (c = 0; c < 2 * ng; c++) if (c != ib) memcpy(rest + (size_t) np * r++, all + (size_t) np * c, (size_t) np * sizeof(double));
    free(all);
}

/* ── univariates Gauß-HMM (wie .hmm_em, .hmm_init_rank, .hmm_viterbi) ───── */

/* gleitender Mittelwert wie roll_mean_core (Fenster w inkl. aktueller Zeile; davor NaN) */
static void roll_mean(int m, const double *x, int w, double *out)
{
    double sum = 0.0, comp = 0.0;
    int bad = 0, i, k;
#define RM_ADD(v) do { const double t_ = sum + (v); \
    if (fabs(sum) >= fabs(v)) comp += (sum - t_) + (v); else comp += ((v) - t_) + sum; sum = t_; } while (0)
    for (i = 0; i < m; i++) out[i] = NAN;
    if (w < 1 || w > m) return;
    for (k = 0; k < w; k++) { if (isfinite(x[k])) RM_ADD(x[k]); else ++bad; }
    out[w - 1] = bad ? NAN : (sum + comp) / w;
    for (i = w; i < m; ++i) {
        if ((i - w) % 4096 == 4095) {
            sum = 0.0; comp = 0.0; bad = 0;
            for (k = i - w + 1; k <= i; ++k) { if (isfinite(x[k])) RM_ADD(x[k]); else ++bad; }
        } else {
            if (isfinite(x[i])) RM_ADD(x[i]); else ++bad;
            if (isfinite(x[i - w])) RM_ADD(-x[i - w]); else --bad;
        }
        out[i] = bad ? NAN : (sum + comp) / w;
    }
#undef RM_ADD
}

/* Startzuordnung .hmm_init_rank: cl (1 … K) */
static int init_rank(int n, const double *x, int K, int win, int32_t *cl, double *work)
{
    double *x2 = work, *vol = work + n, *key = work + 2 * (size_t) n, *rk = work + 3 * (size_t) n;
    int64_t *idx = (int64_t *) malloc(2 * (size_t) n * sizeof(int64_t));
    double med, lo, hi, dx;
    int i, nv = 0, j;
    if (idx == NULL) return -1;
    for (i = 0; i < n; i++) x2[i] = x[i] * x[i];
    roll_mean(n, x2, win, vol);
    for (i = 0; i < n; i++) { vol[i] = sqrt(vol[i]); if (!isnan(vol[i])) key[nv++] = vol[i]; }
    if (nv == 0) { free(idx); return -1; }
    slc_sort_index(nv, key, idx, idx + n);
    med = (nv % 2) ? key[idx[nv / 2]] : (key[idx[nv / 2 - 1]] + key[idx[nv / 2]]) / 2.0;
    for (i = 0; i < n; i++) if (isnan(vol[i])) vol[i] = med;
    /* Mittelränge */
    slc_sort_index(n, vol, idx, idx + n);
    for (i = 0; i < n; ) {
        int e = i;
        while (e + 1 < n && vol[idx[e + 1]] == vol[idx[i]]) e++;
        for (j = i; j <= e; j++) rk[idx[j]] = (double) (i + 1 + e + 1) / 2.0;
        i = e + 1;
    }
    free(idx);
    /* cut(rank, K): K gleich breite Intervalle (a, b], Ränder um 0.1 % der Spannweite erweitert */
    lo = rk[0]; hi = rk[0];
    for (i = 1; i < n; i++) { if (rk[i] < lo) lo = rk[i]; if (rk[i] > hi) hi = rk[i]; }
    dx = hi - lo;
    for (i = 0; i < n; i++) {
        int g = K;
        if (dx == 0.0) g = (K + 1) / 2;
        else {
            for (j = 1; j <= K; j++) {
                double b = (j == K) ? hi + dx / 1000.0 : lo + j * (dx / K);
                if (rk[i] <= b) { g = j; break; }
            }
        }
        cl[i] = g;
    }
    return 0;
}

/* skalierter Vorwärts-Rückwärts-Schritt (wie hmm_forward_backward); B, al, be, ga n x K, xi K x K */
static void fwd_bwd(int T, int K, const double *B, const double *A, const double *p0, double *al,
                    double *be, double *ga, double *xi, double *cs, double *tmp)
{
    int t, i, j;
    double s = 0.0;
    for (j = 0; j < K * K; j++) xi[j] = 0.0;
    for (j = 0; j < K; j++) { tmp[j] = p0[j] * B[(size_t) T * j]; s += tmp[j]; }
    cs[0] = s; for (j = 0; j < K; j++) al[(size_t) T * j] = tmp[j] / s;
    for (t = 1; t < T; ++t) {
        s = 0.0;
        for (j = 0; j < K; ++j) {
            double v = 0.0;
            for (i = 0; i < K; ++i) v += al[t - 1 + (size_t) T * i] * A[i + K * j];
            tmp[j] = v * B[t + (size_t) T * j]; s += tmp[j];
        }
        cs[t] = s; for (j = 0; j < K; ++j) al[t + (size_t) T * j] = tmp[j] / s;
    }
    for (j = 0; j < K; ++j) be[T - 1 + (size_t) T * j] = 1.0;
    for (t = T - 2; t >= 0; --t) {
        for (j = 0; j < K; ++j) tmp[j] = B[t + 1 + (size_t) T * j] * be[t + 1 + (size_t) T * j];
        for (i = 0; i < K; ++i) {
            double v = 0.0;
            for (j = 0; j < K; ++j) v += A[i + K * j] * tmp[j];
            be[t + (size_t) T * i] = v / cs[t + 1];
        }
    }
    for (t = 0; t < T; ++t) {
        double rs = 0.0;
        for (j = 0; j < K; ++j) { ga[t + (size_t) T * j] = al[t + (size_t) T * j] * be[t + (size_t) T * j]; rs += ga[t + (size_t) T * j]; }
        for (j = 0; j < K; ++j) ga[t + (size_t) T * j] /= rs;
    }
    for (t = 0; t < T - 1; ++t) {
        for (j = 0; j < K; ++j) tmp[j] = B[t + 1 + (size_t) T * j] * be[t + 1 + (size_t) T * j];
        for (i = 0; i < K; ++i) for (j = 0; j < K; ++j)
            xi[i + K * j] += al[t + (size_t) T * i] * tmp[j] * A[i + K * j] / cs[t + 1];
    }
}

/* E-Schritt: lB, B; Rückgabe ll (NaN bei Fehler) */
static double estep(int n, int K, const double *x, const double *mu, const double *S, const double *A,
                    const double *p0, double *lB, double *B, double *al, double *be, double *ga,
                    double *xi, double *cs, double *tmp)
{
    slc_acc a1, a2;
    int t, j;
    for (j = 0; j < K; j++) {
        const double L = sqrt(S[j]);
        if (!(L > 0.0) || !isfinite(L)) return NAN;
        for (t = 0; t < n; t++) {
            const double z = (x[t] - mu[j]) / L;
            lB[t + (size_t) n * j] = -0.5 * (z * z) - log(L) - 0.5 * 1.0 * log(TWO_PI);
        }
    }
    slc_acc_init(&a2, 0.0);
    for (t = 0; t < n; t++) {
        double m = lB[t];
        for (j = 1; j < K; j++) { double v = lB[t + (size_t) n * j]; m = (v > m || isnan(m)) ? v : m; }
        for (j = 0; j < K; j++) B[t + (size_t) n * j] = exp(lB[t + (size_t) n * j] - m);
        slc_acc_add(&a2, m);
    }
    fwd_bwd(n, K, B, A, p0, al, be, ga, xi, cs, tmp);
    slc_acc_init(&a1, 0.0);
    for (t = 0; t < n; t++) slc_acc_add(&a1, log(cs[t]));
    return slc_acc_val(&a1) + slc_acc_val(&a2);
}

/* EM ab Startzuordnung; lB (n x K) am Ende zu den gelieferten Parametern; 0 = ok, -1 Fehler */
static int hmm_em_core(int n, const double *x, int K, const int32_t *cl, double ridge, int max_iter,
                       double tol, double *mu, double *S, double *A, double *ll_out, int *iter_out,
                       double *lB_out)
{
    double *buf, *lB, *B, *al, *be, *ga, *xi, *cs, *tmp, *p0, ll = NAN, ll_old = -INFINITY;
    int it = 0, j, t, i, ok = 0;
    const double off = 0.1 / (K - 1 > 1 ? K - 1 : 1);
    buf = (double *) malloc(((size_t) 5 * n * K + (size_t) K * K + n + 2 * (size_t) K) * sizeof(double));
    if (buf == NULL) return -2;
    lB = buf; B = lB + (size_t) n * K; al = B + (size_t) n * K; be = al + (size_t) n * K; ga = be + (size_t) n * K;
    xi = ga + (size_t) n * K; cs = xi + K * K; tmp = cs + n; p0 = tmp + K;
    /* .hmm_init_cl */
    for (j = 0; j < K; j++) {
        slc_acc a;
        int c = 0;
        double m, v;
        slc_acc_init(&a, 0.0);
        for (t = 0; t < n; t++) if (cl[t] == j + 1) { slc_acc_add(&a, x[t]); c++; }
        if (c < 2) goto done;
        m = slc_acc_val(&a) / c;
        slc_acc_init(&a, 0.0);
        for (t = 0; t < n; t++) if (cl[t] == j + 1) { double d = x[t] - m; slc_acc_add(&a, d * d); }
        v = slc_acc_val(&a) / (c - 1);
        mu[j] = m; S[j] = v + ridge;
    }
    for (i = 0; i < K; i++) for (j = 0; j < K; j++) A[i + K * j] = off + (i == j ? 0.9 - off : 0.0);
    for (j = 0; j < K; j++) p0[j] = 1.0 / K;
    for (it = 1; it <= max_iter; it++) {
        ll = estep(n, K, x, mu, S, A, p0, lB, B, al, be, ga, xi, cs, tmp);
        if (!isfinite(ll)) goto done;
        for (j = 0; j < K; j++) p0[j] = ga[(size_t) n * j];
        for (i = 0; i < K; i++) {
            double rs = 0.0;
            for (j = 0; j < K; j++) rs += xi[i + K * j];
            for (j = 0; j < K; j++) A[i + K * j] = xi[i + K * j] / rs;
        }
        for (j = 0; j < K; j++) {
            slc_acc sw, sx, sv;
            double w, m;
            slc_acc_init(&sw, 0.0); slc_acc_init(&sx, 0.0);
            for (t = 0; t < n; t++) { w = ga[t + (size_t) n * j]; slc_acc_add(&sw, w); slc_acc_add(&sx, x[t] * w); }
            m = slc_acc_val(&sx) / slc_acc_val(&sw);
            slc_acc_init(&sv, 0.0);
            for (t = 0; t < n; t++) { double d = x[t] - m; slc_acc_add(&sv, d * d * ga[t + (size_t) n * j]); }
            mu[j] = m;
            S[j] = slc_acc_val(&sv) / slc_acc_val(&sw) + ridge;
        }
        if (fabs(ll - ll_old) < tol * (1.0 + fabs(ll))) break;
        ll_old = ll;
    }
    if (it > max_iter) it = max_iter;
    ll = estep(n, K, x, mu, S, A, p0, lB, B, al, be, ga, xi, cs, tmp);
    if (!isfinite(ll)) goto done;
    for (j = 0; j < K; j++) if (!isfinite(mu[j]) || !(S[j] > 0.0) || !isfinite(S[j])) goto done;
    for (j = 0; j < K * K; j++) if (!isfinite(A[j])) goto done;
    if (lB_out) memcpy(lB_out, lB, (size_t) n * K * sizeof(double));
    ok = 1;
done:
    free(buf);
    *ll_out = ll;
    *iter_out = it;
    return ok ? 0 : -1;
}

int sl_hmm_em_univ(sl_ctx *cx, int n, const double *x, int K, int win, int max_iter, double tol,
                   double *mu, double *S, double *A, double *ll, int *iter)
{
    double *work, ridge;
    int32_t *cl;
    int r;
    if (K < 2 || K > 64) return sl_fail(cx, SL_EARG, "HMM: Anzahl Zustände muss zwischen 2 und 64 liegen (erhalten: %d)", K);
    if (n < 2 * K || x == NULL) return sl_fail(cx, SL_ESMALL, "HMM: zu wenige Beobachtungen (n = %d)", n);
    if (!slc_all_finite(n, x)) return sl_fail(cx, SL_ENONFINITE, "HMM: Reihe enthält nicht endliche Werte");
    if (win < 1 || max_iter < 1 || !(tol >= 0.0)) return sl_fail(cx, SL_EARG, "HMM: ungültige Steuerwerte");
    work = (double *) malloc(4 * (size_t) n * sizeof(double) + (size_t) n * sizeof(int32_t));
    if (work == NULL) return sl_fail(cx, SL_ENOMEM, "HMM: kein Speicher");
    cl = (int32_t *) (work + 4 * (size_t) n);
    if (init_rank(n, x, K, win, cl, work) != 0) { free(work); return sl_fail(cx, SL_ENOMEM, "HMM: Startzuordnung nicht bestimmbar"); }
    ridge = 1e-10 + 1e-6 * var_c(n, x);
    r = hmm_em_core(n, x, K, cl, ridge, max_iter, tol, mu, S, A, ll, iter, NULL);
    free(work);
    if (r == -2) return sl_fail(cx, SL_ENOMEM, "HMM: kein Speicher");
    if (r != 0) return sl_fail(cx, SL_ECONV, "HMM: EM ohne endliches Ergebnis");
    return SL_OK;
}

int sl_hmm_viterbi(sl_ctx *cx, int n, int K, const double *lB, const double *lA, const double *lp0,
                   int32_t *path)
{
    double *dl, *nd;
    int32_t *bp;
    int t, i, j;
    if (n < 1 || K < 1) return sl_fail(cx, SL_ESMALL, "Viterbi: leere Eingabe");
    dl = (double *) malloc(2 * (size_t) K * sizeof(double));
    bp = (int32_t *) malloc((size_t) n * K * sizeof(int32_t));
    if (dl == NULL || bp == NULL) { free(dl); free(bp); return sl_fail(cx, SL_ENOMEM, "Viterbi: kein Speicher"); }
    nd = dl + K;
    for (j = 0; j < K; j++) { dl[j] = lp0[j] + lB[(size_t) n * j]; bp[(size_t) n * j] = 0; }
    for (t = 1; t < n; t++) {
        for (j = 0; j < K; j++) {
            int im = -1;
            double mx = 0.0;
            for (i = 0; i < K; i++) {
                const double c = dl[i] + lA[i + K * j];
                if (isnan(c)) continue;
                if (im < 0 || c > mx) { im = i; mx = c; }
            }
            if (im < 0) { im = 0; mx = NAN; }
            bp[t + (size_t) n * j] = im;
            nd[j] = mx + lB[t + (size_t) n * j];
        }
        memcpy(dl, nd, (size_t) K * sizeof(double));
    }
    {
        int im = -1;
        double mx = 0.0;
        for (j = 0; j < K; j++) { if (isnan(dl[j])) continue; if (im < 0 || dl[j] > mx) { im = j; mx = dl[j]; } }
        path[n - 1] = im < 0 ? 0 : im;
    }
    for (t = n - 1; t > 0; t--) path[t - 1] = bp[t + (size_t) n * path[t]];
    for (t = 0; t < n; t++) path[t] += 1;
    free(dl); free(bp);
    return SL_OK;
}

/* ── Startpunkte und ganzer Fit ─────────────────────────────────────────── */

/* Quantil Typ 7 der sortierten Werte xs (n), p in [0, 1] */
static double q7(int n, const double *xs, double p)
{
    const double index = 1.0 + (n - 1 > 0 ? n - 1 : 0) * p;
    const int lo = (int) floor(index), hi = (int) ceil(index);
    double qs = xs[lo - 1];
    const double h = index - lo;
    if (index > lo && xs[hi - 1] != qs) qs = (1.0 - h) * qs + h * xs[hi - 1];
    return qs;
}

int sl_msgarch_starts(sl_ctx *cx, int n, const double *y, int K, int gjr, double h1, int all_pts,
                      int *nstart, double *starts)
{
    ms_data d;
    const int np = sl_msgarch_npar(K, gjr);
    int nr = 0;
    double *rest = NULL;
    double *work = NULL, mu[64], S[64], A[64 * 64], ll, s2k[64], tmp[64] = {0}, P0[64 * 64];
    int32_t *cl = NULL, *reg = NULL;
    int st, it, ord[64], i, j, k, ns = 0, r;
    st = check_ms(cx, n, y, K, 2);
    if (st != SL_OK) return st;
    if (isnan(h1)) h1 = var_c(n, y);              /* h1 = NaN: Stichprobenvarianz */
    if (K > 64) return sl_fail(cx, SL_EARG, "MS-GARCH: höchstens 64 Regime");
    st = ms_data_init(cx, &d, n, y, K, gjr, h1);
    if (st != SL_OK) return st;
    work = (double *) malloc(4 * (size_t) n * sizeof(double) + 2 * (size_t) n * sizeof(int32_t));
    if (work == NULL) { ms_data_free(&d); return sl_fail(cx, SL_ENOMEM, "MS-GARCH: kein Speicher"); }
    cl = (int32_t *) (work + 4 * (size_t) n);
    reg = cl + n;
    rest = (double *) malloc(2 * (2 * (size_t) MS_NG(gjr) - 1) * (size_t) np * sizeof(double));
    if (rest == NULL) { free(work); ms_data_free(&d); return sl_fail(cx, SL_ENOMEM, "MS-GARCH: kein Speicher"); }
    /* Familie 1: HMM-EM wie regime_hmm (Rangeinteilung, Fenster 21), bei Abbruch nur Familie 2 */
    if (init_rank(n, y, K, 21, cl, work) == 0) {
        const double ridge = 1e-10 + 1e-6 * var_c(n, y);
        r = hmm_em_core(n, y, K, cl, ridge, 300, 1e-7, mu, S, A, &ll, &it, NULL);
        if (r == -2) { st = sl_fail(cx, SL_ENOMEM, "MS-GARCH: kein Speicher"); goto out; }
        if (r == 0) {
            int good = 1;
            for (k = 0; k < K; k++) if (!isfinite(S[k]) || !(S[k] > 0.0)) good = 0;
            for (k = 0; k < K * K; k++) if (!isfinite(A[k])) good = 0;
            if (good) {
                order_k(K, S, ord);
                for (k = 0; k < K; k++) s2k[k] = S[ord[k]];
                for (i = 0; i < K; i++) for (j = 0; j < K; j++) P0[i + K * j] = A[ord[i] + K * ord[j]];
                fix_P(K, P0);
                best_start(&d, s2k, P0, starts + (size_t) np * ns, rest + (size_t) np * nr);
                ns++; nr += 2 * MS_NG(gjr) - 1;
            }
        }
    }
    if (sl_interrupted(cx)) { st = SL_EINTR; goto out; }
    /* Familie 2: Regime aus Quantilen der rollierenden Volatilität (Bruttorenditen y + 1) */
    {
        double *x1 = work, *vol = work + n, *xs = work + 2 * (size_t) n, th[65];
        int64_t *idx = (int64_t *) malloc(2 * (size_t) n * sizeof(int64_t));
        if (idx == NULL) { st = sl_fail(cx, SL_ENOMEM, "MS-GARCH: kein Speicher"); goto out; }
        for (i = 0; i < n; i++) x1[i] = y[i] + 1.0;
        st = sl_rolling_vol(cx, n, x1, 21, vol);
        if (st != SL_OK) { free(idx); goto out; }
        slc_sort_index(n, vol, idx, idx + n);
        for (i = 0; i < n; i++) xs[i] = vol[idx[i]];
        free(idx);
        for (k = 0; k <= K; k++) th[k] = q7(n, xs, k == K ? 1.0 : k * (1.0 / K));
        th[K] = th[K] + 1e-10;
        st = sl_assign_regimes(cx, n, vol, K + 1, th, reg);
        if (st != SL_OK) goto out;
        st = sl_estimate_trans_mat(cx, n, reg, K, 0.1, P0);
        if (st != SL_OK) goto out;
        fix_P(K, P0);
        for (k = 0; k < K; k++) {
            int c = 0;
            for (i = 0; i < n; i++) if (reg[i] == k + 1) xs[c++] = y[i];
            s2k[k] = c < 30 ? h1 : var_c(c, xs);
        }
        for (k = 0; k < K; k++) tmp[k] = s2k[k];
        order_k(K, tmp, ord);
        for (k = 0; k < K; k++) s2k[k] = tmp[ord[k]];
        best_start(&d, s2k, P0, starts + (size_t) np * ns, rest + (size_t) np * nr);
        ns++; nr += 2 * MS_NG(gjr) - 1;
    }
    /* 9.4: danach die übrigen Rasterpunkte beider Familien (BFGS von denselben Starts wie heute findet
     * auf flachen, mehrgipfligen Likelihoods teils andere lokale Maxima als optim; scratchpad/e94/) */
    if (all_pts) {
        memcpy(starts + (size_t) np * ns, rest, (size_t) np * nr * sizeof(double));
        ns += nr;
    }
    st = SL_OK;
out:
    free(work); ms_data_free(&d); free(rest);
    *nstart = ns;
    return st;
}

int sl_msgarch_estimate(sl_ctx *cx, int n, const double *y, int K, int gjr, double *omega,
                        double *alpha, double *beta, double *gamma, double *P, int32_t *regimes,
                        double *s2, double *loglik, int *code)
{
    const int np = sl_msgarch_npar(K, gjr);
    double *starts = NULL, *theta = NULL, *buf = NULL, h1, nll, om[64], al[64], be[64], ga[64], Pu[64 * 64],
           unc[64] = {0}, xi0[64], lA[64 * 64], lp0[64], ll;
    int st, ns = 0, ord[64], i, j, k, t;
    st = check_ms(cx, n, y, K, 2);
    if (st != SL_OK) return st;
    if (K > 64) return sl_fail(cx, SL_EARG, "MS-GARCH: höchstens 64 Regime");
    h1 = var_c(n, y);
    starts = (double *) malloc((SL_MSGARCH_MAXSTART + 1) * (size_t) np * sizeof(double));
    if (starts == NULL) return sl_fail(cx, SL_ENOMEM, "MS-GARCH: kein Speicher");
    theta = starts + (size_t) SL_MSGARCH_MAXSTART * np;
    st = sl_msgarch_starts(cx, n, y, K, gjr, h1, 1, &ns, starts);
    if (st != SL_OK) goto out;
    st = sl_msgarch_fit(cx, n, y, K, gjr, ns, starts, h1, NULL, theta, &nll, code);
    if (st != SL_OK) goto out;
    if (!isfinite(nll) || !slc_all_finite(np, theta)) {
        st = sl_fail(cx, SL_ECONV, "Log-Likelihood nicht endlich (Optimierer-Code %d).", *code);
        goto out;
    }
    sl_msgarch_unpack(K, gjr, theta, om, al, be, ga, Pu);
    for (k = 0; k < K; k++) unc[k] = om[k] / (1.0 - al[k] - ga[k] / 2.0 - be[k]);
    order_k(K, unc, ord);
    for (k = 0; k < K; k++) { omega[k] = om[ord[k]]; alpha[k] = al[ord[k]]; beta[k] = be[ord[k]]; gamma[k] = ga[ord[k]]; }
    for (i = 0; i < K; i++) for (j = 0; j < K; j++) P[i + K * j] = Pu[ord[i] + K * ord[j]];
    sl_msgarch_stat(K, P, xi0);
    buf = (double *) malloc(4 * (size_t) n * K * sizeof(double));
    if (buf == NULL) { st = sl_fail(cx, SL_ENOMEM, "MS-GARCH: kein Speicher"); goto out; }
    {
        double *h = buf, *pred = h + (size_t) n * K, *filt = pred + (size_t) n * K, *lB = filt + (size_t) n * K;
        filter_run(y, n, K, omega, alpha, beta, gamma, P, xi0, h1, h, pred, filt, lB, &ll);
        if (!isfinite(ll)) { st = sl_fail(cx, SL_ECONV, "Log-Likelihood nicht endlich (letzter Filterlauf)."); goto out; }
        for (t = 0; t < n; t++) {
            double v = pred[t] * h[t];
            for (k = 1; k < K; k++) v = v + pred[t + (size_t) n * k] * h[t + (size_t) n * k];
            s2[t] = v;
        }
        for (k = 0; k < K * K; k++) lA[k] = log(P[k]);
        for (k = 0; k < K; k++) lp0[k] = log(xi0[k]);
        st = sl_hmm_viterbi(cx, n, K, lB, lA, lp0, regimes);
        if (st != SL_OK) goto out;
    }
    *loglik = ll;
out:
    free(starts); free(buf);
    return st;
}
