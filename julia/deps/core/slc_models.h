/* core/slc_models.h – Modelle der C-Bibliothek slc (SimLev core, Etappe 9.4): GARCH/GJR(1,1),
 * verallgemeinerte Pareto-Verteilung, DCC(1,1), MS-GARCH mit HMM-Starts, Bootstrap-Kerne
 *
 * Verfahren:  siehe die Kerndateien slc_garch.c (B.10), slc_gpd.c (B.12), slc_dcc.c (B.11),
 *             slc_msgarch.c (B.13), slc_boot.c (B.17); jede nennt ihre Quellen.
 * Quellen:    Entwurf SPEZ-9, Abschnitte B.10–B.13, B.17; Literatur je Kerndatei.
 * Konstanten: keine.
 * Reinraum:   geschrieben nur nach den genannten Quellen und dem eigenen SimLev-Code; kein Code und
 *             keine Koeffizienten aus R, Netlib, ACM- oder RSS-Algorithmen oder Paketen (rugarch,
 *             Rsolnp, evd, MSGARCH).
 * Prüforakel: rugarch 1.5-6, evd 2.3-7.1, MSGARCH 2.51 und die bisherigen eigenen Kerne (nur
 *             Plausibilität, scratchpad/e94/).
 *
 * Eingebunden von slc.h (eine Zeile); nicht direkt einbinden.
 *
 * Felder: double spaltenweise, führende Dimension = Zeilenzahl; Indizes in Ein- und Ausgaben
 * 1-basiert (int32_t). Nur Punktschätzer (keine Standardfehler, keine Hesse-Matrix; F4).
 * Ziehende Funktionen (sl_boot_*) ziehen nur aus dem übergebenen Strom sl_rng *.
 */
#ifndef SLC_MODELS_H
#define SLC_MODELS_H

#include <stdint.h>

#include "slc.h"

struct sl_opt_ctrl;   /* slc_opt.h (Steuerwerte der Optimierer; NULL = Standard des Modells) */

#ifdef __cplusplus
extern "C" {
#endif

/* ── GARCH(1,1) und GJR-GARCH(1,1) (slc_garch.c, B.10) ─────────────────────── */

/* Schätzweg (sl_garch11_estimate) */
enum { SL_GARCH_KONSTANT = 0, SL_GARCH_ML = 1, SL_GARCH_MOMENTE = 2 };

/* s2[0] = s2_init, s2[t] = omega + (alpha + gamma 1{eps[t-1] < 0}) eps[t-1]^2 + beta s2[t-1],
 * Untergrenze 1e-14 (wie der frühere Filter garch_filter) */
int sl_garch11_filter(sl_ctx *cx, int n, const double *eps, double omega, double alpha, double beta,
                      double gamma, double s2_init, double *s2);
/* Umparametrisierung (wie .ms_garch_unpack mit K = 1): theta = (mu, log omega, a, [g], b) mit
 * (alpha, beta) = exp(a, b) / (1 + Summe) bzw. bei GJR (N1) (alpha/2, (alpha + gamma)/2, beta) =
 * exp(a, g, b) / (1 + Summe), also gamma < 0 zulässig, solange alpha + gamma > 0 (bis 1.0.0
 * (alpha, gamma/2, beta) mit gamma >= 0); par = (mu, omega, alpha, beta, gamma).
 * theta hat 4 (gjr = 0) bzw. 5 Werte. pack: Umkehrung; verlangt omega, alpha, beta > 0,
 * alpha + gamma > 0 (gjr) und alpha + gamma/2 + beta < 1, sonst SL_EARG. */
int sl_garch11_npar(int gjr);
void sl_garch11_unpack(int gjr, const double *theta, double *par);
int sl_garch11_pack(sl_ctx *cx, int gjr, const double *par, double *theta);
/* NLL = 1/2 sum (log 2 pi + log s2_t + eps_t^2 / s2_t), eps = e - mu, an par (5 Werte; gamma
 * wird bei gjr = 0 nicht gelesen); s2_init = NaN: Stichprobenvarianz von e. Nicht endlich -> +Inf. */
int sl_garch11_nll(sl_ctx *cx, int n, const double *e, int gjr, const double *par, double s2_init,
                   double *nll);
/* ML-Punktschätzer (Raster-Startwerte, BFGS mit numerischem Gradienten, ctrl NULL: maxit 500,
 * reltol 1e-10; sGARCH vom besten Rasterpunkt, GJR seit N1 von allen sieben Rasterpunkten);
 * par = (mu, omega, alpha, beta, gamma), loglik, code (wie optim$convergence).
 * Fehler: n < 10 SL_ESMALL, nicht endliche Werte SL_ENONFINITE, Varianz 0 SL_EARG. */
int sl_garch11_fit(sl_ctx *cx, int n, const double *e, int gjr, const struct sl_opt_ctrl *ctrl,
                   double *par, double *loglik, int *code);
/* Ganze Stufe wie .fit_garch11 (F10): Varianz < 1e-16 -> "konstant"; sonst ML, bei Fehler oder
 * nicht endlichem Ergebnis Momente (alpha 0.08, beta 0.88, gamma 0.04 bei gjr). Danach Filter mit
 * Start omega / max(1e-6, 1 - alpha - beta - gamma/2), z = (e - mu)/sqrt(s2) (nicht endlich -> 0,
 * dann standardisiert), s2_init = omega / (1 - Persistenz) bzw. Stichprobenvarianz ab 0.9999.
 * par (5), loglik (NaN außer bei ML), code (-1 außer bei ML), method (SL_GARCH_*), s2 (n), z (n),
 * s2_init, persistence. Fehler nur bei leeren oder nicht endlichen Eingaben und Abbruch. */
int sl_garch11_estimate(sl_ctx *cx, int n, const double *e, int gjr, double *par, double *loglik,
                        int *code, int *method, double *s2, double *z, double *s2_init,
                        double *persistence);

/* ── Verallgemeinerte Pareto-Verteilung (slc_gpd.c, B.12) ─────────────────── */

/* NLL der Überschreitungen x (>= 0) an (scale, shape); außerhalb des Trägers +Inf */
int sl_gpd_nll(sl_ctx *cx, int n, const double *x, double scale, double shape, double *nll);
/* Startwerte aus wahrscheinlichkeitsgewichteten Momenten (Hosking, Wallis 1987) */
int sl_gpd_pwm(sl_ctx *cx, int n, const double *x, double *scale, double *shape);
/* ML in (log scale, shape), shape in [-0.999, 10], projizierter BFGS (ctrl NULL: maxit 500,
 * reltol 1e-12). Fehler: n < 10 SL_ESMALL; shape an einer Schranke SL_ECONV. */
int sl_gpd_fit(sl_ctx *cx, int n, const double *x, const struct sl_opt_ctrl *ctrl, double *scale,
               double *shape, double *loglik, int *code);

/* ── DCC(1,1) (slc_dcc.c, B.11) ───────────────────────────────────────────── */

/* Korrelationsteil der Quasi-Log-Likelihood; Z n x k, Qbar k x k. Rt (NULL oder n x k(k-1)/2,
 * nur bei keep). Nicht positiv definit: nll = 1e10, ok = 0, Rt ab dieser Zeile NA. */
int sl_dcc_filter(sl_ctx *cx, int n, int k, const double *Z, double a, double b, const double *Qbar,
                  int keep, double *nll, double *Rt, int *ok);
/* Nelder-Mead über s = 0.999 plogis(th1), a = s plogis(th2), b = s - a, Start
 * (qlogis(0.98/0.999), qlogis(0.03/0.98)); ctrl NULL: maxfev 2000, reltol 1e-10.
 * theta (NULL oder 2 Werte) = bester Punkt. */
int sl_dcc_fit(sl_ctx *cx, int n, int k, const double *Z, const double *Qbar, const struct sl_opt_ctrl *ctrl,
               double *a, double *b, double *nll, int *code, double *theta);

/* ── MS-GARCH und HMM (slc_msgarch.c, B.13) ───────────────────────────────── */

/* Hamilton-Filter mit parallelen Varianzpfaden (wie der eigene Kern ms_garch_impl.c): h, pred,
 * filt, lB je n x K; loglik = -Inf, sobald eine Mischungsdichte nicht endlich oder <= 0 ist. */
int sl_msgarch_filter(sl_ctx *cx, int n, const double *y, int K, const double *omega,
                      const double *alpha, const double *beta, const double *gamma, const double *P,
                      const double *xi0, double h1, double *h, double *pred, double *filt, double *lB,
                      double *loglik);
int sl_msgarch_npar(int K, int gjr);                 /* K (3 bzw. 4) + K (K - 1) */
/* wie .ms_garch_unpack bzw. .ms_garch_pack (P K x K spaltenweise, Zeile = von); GJR je Regime seit N1
 * (alpha/2, (alpha + gamma)/2, beta) statt (alpha, gamma/2, beta), also gamma < 0 mit alpha + gamma > 0 */
void sl_msgarch_unpack(int K, int gjr, const double *theta, double *omega, double *alpha,
                       double *beta, double *gamma, double *P);
void sl_msgarch_pack(int K, int gjr, const double *omega, const double *alpha, const double *beta,
                     const double *gamma, const double *P, double *theta);
/* stationäre Verteilung wie .ms_garch_stat (Potenziteration, höchstens 1000 Schritte) */
void sl_msgarch_stat(int K, const double *P, double *pi);
/* negative Log-Likelihood an theta (nicht endlich -> +Inf); h1 = NaN: Stichprobenvarianz von y
 * (ebenso in sl_msgarch_fit und sl_msgarch_starts) */
int sl_msgarch_nll(sl_ctx *cx, int n, const double *y, int K, int gjr, const double *theta,
                   double h1, double *nll);
/* N1: negative Log-Likelihood (wie sl_msgarch_nll) und ihr analytischer Gradient nach theta (npar
 * Werte; vorwärts mitdifferenzierter Hamilton-Filter, siehe slc_msgarch.c). Nicht endliche
 * Likelihood: nll = +Inf, grad = NaN. K höchstens 64. */
int sl_msgarch_grad(sl_ctx *cx, int n, const double *y, int K, int gjr, const double *theta,
                    double h1, double *nll, double *grad);
/* BFGS (analytischer Gradient seit N1; ctrl NULL: maxit 500, reltol 1e-10) von jedem der nstart
 * Startpunkte (starts: npar x nstart); der beste Lauf gewinnt, bei Gleichstand der erste. K höchstens 64. */
int sl_msgarch_fit(sl_ctx *cx, int n, const double *y, int K, int gjr, int nstart,
                   const double *starts, double h1, const struct sl_opt_ctrl *ctrl, double *theta,
                   double *nll, int *code);
/* Startpunkte wie .ms_garch_fit: Familie 1 aus dem HMM-EM (falls es gelingt), Familie 2 aus der
 * Rangeinteilung der rollierenden Volatilität; je bester Rasterpunkt (all_pts = 0: höchstens 2
 * Spalten). all_pts = 1: danach die übrigen Rasterpunkte je Familie (sGARCH 5, GJR seit N1 9 mit
 * zwei Rasterpunkten gamma < 0; höchstens SL_MSGARCH_MAXSTART Spalten, sGARCH 12, GJR 20).
 * starts: npar x SL_MSGARCH_MAXSTART. */
#define SL_MSGARCH_MAXSTART 20   /* N1: bis 1.0.0 12 */
int sl_msgarch_starts(sl_ctx *cx, int n, const double *y, int K, int gjr, double h1, int all_pts,
                      int *nstart, double *starts);
/* ganzer Fit wie .ms_garch_fit: Starts (all_pts = 1; sGARCH 12, GJR 20), BFGS mit analytischem
 * Gradienten (N1), Sortierung nach unbedingter Varianz,
 * letzter Filterlauf, Mischungsvarianz s2 (n), Viterbi-Pfad regimes (n, 1-basiert). */
int sl_msgarch_estimate(sl_ctx *cx, int n, const double *y, int K, int gjr, double *omega,
                        double *alpha, double *beta, double *gamma, double *P, int32_t *regimes,
                        double *s2, double *loglik, int *code);
/* Baum-Welch-EM des univariaten Gauß-HMM wie .hmm_em mit Start .hmm_init_rank (Fenster win,
 * ridge = 1e-10 + 1e-6 var(x)); mu, S (Varianzen) je K, A K x K, ll, iter. */
int sl_hmm_em_univ(sl_ctx *cx, int n, const double *x, int K, int win, int max_iter, double tol,
                   double *mu, double *S, double *A, double *ll, int *iter);
/* Viterbi-Pfad wie .hmm_viterbi (lB n x K, lA K x K, lp0 K; erstes Maximum) */
int sl_hmm_viterbi(sl_ctx *cx, int n, int K, const double *lB, const double *lA, const double *lp0,
                   int32_t *path);

/* ── Bootstrap-Kerne (slc_boot.c, B.17) ─────────────────────────────────────── */

int sl_boot_idx_iid(sl_ctx *cx, sl_rng *r, int n_src, int n_out, int32_t *idx);
int sl_boot_idx_block(sl_ctx *cx, sl_rng *r, int n_src, int n_out, int block_length, int circular,
                      int32_t *idx);
int sl_boot_idx_stationary(sl_ctx *cx, sl_rng *r, int n_src, int n_out, double L, int32_t *idx);
/* regimes (n, Werte 1 … K; andere zählen nicht), trans K x K */
int sl_boot_idx_regime(sl_ctx *cx, sl_rng *r, int n, const int32_t *regimes, int K,
                       const double *trans, int n_out, int32_t *idx);
int sl_boot_idx_tails(sl_ctx *cx, sl_rng *r, int n_out, double p_l, double p_r, int nb,
                      const int32_t *bulk_idx, int nl, const int32_t *left_idx, int nr,
                      const int32_t *right_idx, int32_t *idx);
/* ret n x k; type 0 Rademacher, 1 Mammen, 2 Standardnormal */
int sl_boot_wild(sl_ctx *cx, sl_rng *r, int n, int k, const double *ret, int type, double *out);
int sl_boot_reset(sl_ctx *cx, sl_rng *r, int n, int k, const double *ret, double p_break, double *out);
/* base 0-basiert; out n_out x k, idx n_out */
int sl_boot_evt(sl_ctx *cx, sl_rng *r, int n, int k, const double *ret, int base, int n_out,
                double p_l, double thresh_l, double scale_l, double shape_l, int nl, const int32_t *pool_l,
                double p_r, double thresh_r, double scale_r, double shape_r, int nr, const int32_t *pool_r,
                int nb, const int32_t *bulk_idx, double *out, int32_t *idx);
/* Nicht-Basisreihen (m Stück): Spalten cols (0-basiert), GARCH-Parameter, ratio (0/1), s2 und
 * standardisierte Residuen z_cross (n_src x m). z_base n_src, valid (nv, 1-basiert). */
int sl_boot_garch(sl_ctx *cx, sl_rng *r, int n_out, int base, int k, double mu, double omega,
                  double alpha, double beta, double gamma, double s2_init, int n_src,
                  const double *z_base, int nv, const int32_t *valid, int m, const int32_t *cross_cols,
                  const double *cmu, const double *com, const double *cal, const double *cbe,
                  const int32_t *cratio, const double *cs2, const double *z_cross, double *out,
                  int32_t *idx);
/* Regime-Pools als Verkettung pool_idx (1-basiert) mit Grenzen pool_off (K + 1 Werte, 0-basiert);
 * trans, delta K x K; regime n_out (1-basiert) */
int sl_boot_ms_garch(sl_ctx *cx, sl_rng *r, int n_out, int base, int k, int K, const double *mu,
                     const double *omega, const double *alpha, const double *beta,
                     const double *gamma, const double *phi, const double *lambda,
                     const double *trans, const double *delta, const double *unc_var,
                     const double *stat_prob, const int32_t *pool_off, const int32_t *pool_idx,
                     int n_src, const double *z_base, int m, const int32_t *cross_cols,
                     const double *cmu, const double *com, const double *cal, const double *cbe,
                     const int32_t *cratio, const double *cs2, const double *z_cross, double *out,
                     int32_t *idx, int32_t *regime);
/* ohne Zufall */
int sl_rolling_vol(sl_ctx *cx, int n, const double *x, int window, double *vol);
int sl_assign_regimes(sl_ctx *cx, int n, const double *vol, int nth, const double *thresh, int32_t *reg);
int sl_estimate_trans_mat(sl_ctx *cx, int n, const int32_t *regimes, int K, double alpha, double *P);

#ifdef __cplusplus
}
#endif

#endif /* SLC_MODELS_H */
