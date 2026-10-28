/*
 * src/init.c -- Registrierung der .Call-Routinen von SimLev
 *
 * Seit 0.5.0 ohne Rcpp: Die C++-Kerne haben extern "C"-Huellen (am Ende der
 * jeweiligen .cpp-Datei, Rahmen in simlev_capi.h). Die C-Uebernahmen (vendor_*.c), der
 * MS-GARCH-Filter (ms_garch.c), der DCC-Filter (dependence_core.cpp) und die
 * frueheren Bootstrap-Kerne (bootstrap_core.cpp) sind mit Etappe 9.6c entfallen;
 * ihre Aufgaben rechnet die C-Bibliothek slc. Registriert sind nur .Call-Routinen
 * unter Namen ohne Praefix; NAMESPACE laedt sie mit
 * useDynLib(SimLev, .registration = TRUE, .fixes = "C_"), in R heissen sie
 * daher C_<name> (z. B. C_sim_buy, gerufen von .sim_buy_cpp in R/cores.R).
 * Dynamische Symbolsuche ist abgeschaltet. Seit Etappe 9.1 auch die Huellen der C-Bibliothek slc
 * (slc_r.c; Kerne slc*.c als Kopien aus core/, tools/core_sync.py).
 */
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

/* fifo_core.cpp */
extern SEXP C_sim_fifo_price(SEXP, SEXP, SEXP);
extern SEXP C_sim_fifo_vp(SEXP, SEXP, SEXP);
extern SEXP C_sim_private_sale_tax(SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sim_fifo_consume(SEXP, SEXP, SEXP);
/* research_core.cpp */
extern SEXP C_proj_box_simplex(SEXP, SEXP, SEXP);
extern SEXP C_qp_box_simplex(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_min_cvar_core(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_min_cdar_core(SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_quantile_reg_core(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_hmm_forward_backward(SEXP, SEXP, SEXP);
extern SEXP C_roll_mean_core(SEXP, SEXP);
extern SEXP C_kendall_tau_core(SEXP, SEXP);
extern SEXP C_roll_cov_core(SEXP, SEXP, SEXP);
/* simulation_core.cpp */
extern SEXP C_sim_dca_flows(SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sim_buy_report(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sim_sell_report(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sim_total_report(SEXP, SEXP, SEXP);
extern SEXP C_sim_buy(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sim_market_update(SEXP, SEXP, SEXP);
extern SEXP C_sim_market_update_batch(SEXP, SEXP, SEXP, SEXP);
/* slc_r.c (C-Bibliothek slc, Etappe 9.1) */
extern SEXP C_sl_version(void);
extern SEXP C_sl_rng_seed(SEXP);
extern SEXP C_sl_rng_seed_entropy(SEXP, SEXP, SEXP);
extern SEXP C_sl_rng_jump(SEXP);
extern SEXP C_sl_rng_streams(SEXP, SEXP);
extern SEXP C_sl_rng_seed31(SEXP);
extern SEXP C_sl_rng_hex(SEXP);
extern SEXP C_sl_rng_u64(SEXP, SEXP);
extern SEXP C_sl_runif(SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_rnorm(SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_rgamma(SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_rexp(SEXP, SEXP, SEXP);
extern SEXP C_sl_rgeom(SEXP, SEXP, SEXP);
extern SEXP C_sl_rchisq(SEXP, SEXP, SEXP);
extern SEXP C_sl_sample(SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_pnorm(SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_qnorm(SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_dnorm(SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_erfc(SEXP);
extern SEXP C_sl_lgamma(SEXP);
extern SEXP C_sl_plogis(SEXP);
extern SEXP C_sl_qlogis(SEXP);
extern SEXP C_sl_pbeta(SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_pt(SEXP, SEXP, SEXP);
extern SEXP C_sl_qt(SEXP, SEXP, SEXP);
/* 9.2: slc_r_linalg.c (lineare Algebra, Matrixprodukt, kleinste Quadrate, Stineman, Spline, Kerndichte) */
extern SEXP C_sl_chol(SEXP);
extern SEXP C_sl_chol_band(SEXP, SEXP);
extern SEXP C_sl_trisolve(SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_solve_spd(SEXP, SEXP);
extern SEXP C_sl_logdet_spd(SEXP);
extern SEXP C_sl_eigen_sym(SEXP, SEXP);
extern SEXP C_sl_matmul(SEXP, SEXP);
extern SEXP C_sl_crossprod(SEXP, SEXP);
extern SEXP C_sl_tcrossprod(SEXP, SEXP);
extern SEXP C_sl_lsfit(SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_logit_irls(SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_stineman(SEXP, SEXP, SEXP);
extern SEXP C_sl_stineman_slopes(SEXP, SEXP, SEXP);
extern SEXP C_sl_stineman_eval(SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_smspline_fit(SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_smspline_predict(SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_kde(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_kde_bw(SEXP);
/* tax_core.cpp */
extern SEXP C_sim_flat_rate(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sim_p20_tax(SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sim_vp_tax(SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sim_sell_count(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
/* withdrawal_core.cpp */
extern SEXP C_wd_simulate(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
/* 9.3: slc_r_opt.c (Optimierer der C-Bibliothek slc) */
extern SEXP C_sl_opt_init(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_opt_next(SEXP, SEXP);
extern SEXP C_sl_opt_result(SEXP);
extern SEXP C_sl_opt_testfn(SEXP, SEXP, SEXP);
extern SEXP C_sl_opt_minimize_test(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_numgrad_test(SEXP, SEXP, SEXP, SEXP);
/* 9.4: slc_r_models.c (Modelle der C-Bibliothek slc: GARCH/GJR, GPD, DCC, MS-GARCH und HMM, Bootstrap-Kerne) */
extern SEXP C_sl_garch11_filter(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_garch11_nll(SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_garch11_fit(SEXP, SEXP);
extern SEXP C_sl_garch11_estimate(SEXP, SEXP);
extern SEXP C_sl_gpd_nll(SEXP, SEXP, SEXP);
extern SEXP C_sl_gpd_pwm(SEXP);
extern SEXP C_sl_gpd_fit(SEXP);
extern SEXP C_sl_dcc_filter(SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_dcc_fit(SEXP, SEXP);
extern SEXP C_sl_ms_garch_filter(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_ms_garch_nll(SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_ms_garch_grad(SEXP, SEXP, SEXP, SEXP, SEXP);   /* N1 */
extern SEXP C_sl_ms_garch_starts(SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_ms_garch_fitstarts(SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_ms_garch_estimate(SEXP, SEXP, SEXP);
extern SEXP C_sl_hmm_em_univ(SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_hmm_viterbi(SEXP, SEXP, SEXP);
extern SEXP C_sl_boot_idx_iid(SEXP, SEXP, SEXP);
extern SEXP C_sl_boot_idx_block(SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_boot_idx_stationary(SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_boot_idx_regime(SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_boot_idx_tails(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_boot_wild(SEXP, SEXP, SEXP);
extern SEXP C_sl_boot_reset(SEXP, SEXP, SEXP);
extern SEXP C_sl_boot_evt(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_boot_garch(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_boot_ms_garch(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sl_rolling_vol(SEXP, SEXP);
extern SEXP C_sl_assign_regimes(SEXP, SEXP);
extern SEXP C_sl_estimate_trans_mat(SEXP, SEXP, SEXP);

static const R_CallMethodDef CallEntries[] = {
    /* fifo_core.cpp */
    {"sim_fifo_price", (DL_FUNC) &C_sim_fifo_price, 3},
    {"sim_fifo_vp", (DL_FUNC) &C_sim_fifo_vp, 3},
    {"sim_private_sale_tax", (DL_FUNC) &C_sim_private_sale_tax, 5},
    {"sim_fifo_consume", (DL_FUNC) &C_sim_fifo_consume, 3},
    /* research_core.cpp */
    {"proj_box_simplex", (DL_FUNC) &C_proj_box_simplex, 3},
    {"qp_box_simplex", (DL_FUNC) &C_qp_box_simplex, 8},
    {"min_cvar_core", (DL_FUNC) &C_min_cvar_core, 8},
    {"min_cdar_core", (DL_FUNC) &C_min_cdar_core, 5},
    {"quantile_reg_core", (DL_FUNC) &C_quantile_reg_core, 7},
    {"hmm_forward_backward", (DL_FUNC) &C_hmm_forward_backward, 3},
    {"roll_mean_core", (DL_FUNC) &C_roll_mean_core, 2},
    {"kendall_tau_core", (DL_FUNC) &C_kendall_tau_core, 2},
    {"roll_cov_core", (DL_FUNC) &C_roll_cov_core, 3},
    /* simulation_core.cpp */
    {"sim_dca_flows", (DL_FUNC) &C_sim_dca_flows, 4},
    {"sim_buy_report", (DL_FUNC) &C_sim_buy_report, 6},
    {"sim_sell_report", (DL_FUNC) &C_sim_sell_report, 7},
    {"sim_total_report", (DL_FUNC) &C_sim_total_report, 3},
    {"sim_buy", (DL_FUNC) &C_sim_buy, 6},
    {"sim_market_update", (DL_FUNC) &C_sim_market_update, 3},
    {"sim_market_update_batch", (DL_FUNC) &C_sim_market_update_batch, 4},
    /* slc_r.c (C-Bibliothek slc, Etappe 9.1) */
    {"sl_version", (DL_FUNC) &C_sl_version, 0},
    {"sl_rng_seed", (DL_FUNC) &C_sl_rng_seed, 1},
    {"sl_rng_seed_entropy", (DL_FUNC) &C_sl_rng_seed_entropy, 3},
    {"sl_rng_jump", (DL_FUNC) &C_sl_rng_jump, 1},
    {"sl_rng_streams", (DL_FUNC) &C_sl_rng_streams, 2},
    {"sl_rng_seed31", (DL_FUNC) &C_sl_rng_seed31, 1},
    {"sl_rng_hex", (DL_FUNC) &C_sl_rng_hex, 1},
    {"sl_rng_u64", (DL_FUNC) &C_sl_rng_u64, 2},
    {"sl_runif", (DL_FUNC) &C_sl_runif, 4},
    {"sl_rnorm", (DL_FUNC) &C_sl_rnorm, 4},
    {"sl_rgamma", (DL_FUNC) &C_sl_rgamma, 4},
    {"sl_rexp", (DL_FUNC) &C_sl_rexp, 3},
    {"sl_rgeom", (DL_FUNC) &C_sl_rgeom, 3},
    {"sl_rchisq", (DL_FUNC) &C_sl_rchisq, 3},
    {"sl_sample", (DL_FUNC) &C_sl_sample, 5},
    {"sl_pnorm", (DL_FUNC) &C_sl_pnorm, 4},
    {"sl_qnorm", (DL_FUNC) &C_sl_qnorm, 4},
    {"sl_dnorm", (DL_FUNC) &C_sl_dnorm, 4},
    {"sl_erfc", (DL_FUNC) &C_sl_erfc, 1},
    {"sl_lgamma", (DL_FUNC) &C_sl_lgamma, 1},
    {"sl_plogis", (DL_FUNC) &C_sl_plogis, 1},
    {"sl_qlogis", (DL_FUNC) &C_sl_qlogis, 1},
    {"sl_pbeta", (DL_FUNC) &C_sl_pbeta, 4},
    {"sl_pt", (DL_FUNC) &C_sl_pt, 3},
    {"sl_qt", (DL_FUNC) &C_sl_qt, 3},
    /* 9.2: slc_r_linalg.c */
    {"sl_chol", (DL_FUNC) &C_sl_chol, 1},
    {"sl_chol_band", (DL_FUNC) &C_sl_chol_band, 2},
    {"sl_trisolve", (DL_FUNC) &C_sl_trisolve, 4},
    {"sl_solve_spd", (DL_FUNC) &C_sl_solve_spd, 2},
    {"sl_logdet_spd", (DL_FUNC) &C_sl_logdet_spd, 1},
    {"sl_eigen_sym", (DL_FUNC) &C_sl_eigen_sym, 2},
    {"sl_matmul", (DL_FUNC) &C_sl_matmul, 2},
    {"sl_crossprod", (DL_FUNC) &C_sl_crossprod, 2},
    {"sl_tcrossprod", (DL_FUNC) &C_sl_tcrossprod, 2},
    {"sl_lsfit", (DL_FUNC) &C_sl_lsfit, 5},
    {"sl_logit_irls", (DL_FUNC) &C_sl_logit_irls, 4},
    {"sl_stineman", (DL_FUNC) &C_sl_stineman, 3},
    {"sl_stineman_slopes", (DL_FUNC) &C_sl_stineman_slopes, 3},
    {"sl_stineman_eval", (DL_FUNC) &C_sl_stineman_eval, 4},
    {"sl_smspline_fit", (DL_FUNC) &C_sl_smspline_fit, 4},
    {"sl_smspline_predict", (DL_FUNC) &C_sl_smspline_predict, 4},
    {"sl_kde", (DL_FUNC) &C_sl_kde, 6},
    {"sl_kde_bw", (DL_FUNC) &C_sl_kde_bw, 1},

    /* 9.3: slc_r_opt.c */
    {"sl_opt_init", (DL_FUNC) &C_sl_opt_init, 7},
    {"sl_opt_next", (DL_FUNC) &C_sl_opt_next, 2},
    {"sl_opt_result", (DL_FUNC) &C_sl_opt_result, 1},
    {"sl_opt_testfn", (DL_FUNC) &C_sl_opt_testfn, 3},
    {"sl_opt_minimize_test", (DL_FUNC) &C_sl_opt_minimize_test, 8},
    {"sl_numgrad_test", (DL_FUNC) &C_sl_numgrad_test, 4},
    /* 9.4: slc_r_models.c */
    {"sl_garch11_filter", (DL_FUNC) &C_sl_garch11_filter, 6},
    {"sl_garch11_nll", (DL_FUNC) &C_sl_garch11_nll, 4},
    {"sl_garch11_fit", (DL_FUNC) &C_sl_garch11_fit, 2},
    {"sl_garch11_estimate", (DL_FUNC) &C_sl_garch11_estimate, 2},
    {"sl_gpd_nll", (DL_FUNC) &C_sl_gpd_nll, 3},
    {"sl_gpd_pwm", (DL_FUNC) &C_sl_gpd_pwm, 1},
    {"sl_gpd_fit", (DL_FUNC) &C_sl_gpd_fit, 1},
    {"sl_dcc_filter", (DL_FUNC) &C_sl_dcc_filter, 5},
    {"sl_dcc_fit", (DL_FUNC) &C_sl_dcc_fit, 2},
    {"sl_ms_garch_filter", (DL_FUNC) &C_sl_ms_garch_filter, 8},
    {"sl_ms_garch_nll", (DL_FUNC) &C_sl_ms_garch_nll, 5},
    {"sl_ms_garch_grad", (DL_FUNC) &C_sl_ms_garch_grad, 5},   /* N1 */
    {"sl_ms_garch_starts", (DL_FUNC) &C_sl_ms_garch_starts, 5},
    {"sl_ms_garch_fitstarts", (DL_FUNC) &C_sl_ms_garch_fitstarts, 5},
    {"sl_ms_garch_estimate", (DL_FUNC) &C_sl_ms_garch_estimate, 3},
    {"sl_hmm_em_univ", (DL_FUNC) &C_sl_hmm_em_univ, 5},
    {"sl_hmm_viterbi", (DL_FUNC) &C_sl_hmm_viterbi, 3},
    {"sl_boot_idx_iid", (DL_FUNC) &C_sl_boot_idx_iid, 3},
    {"sl_boot_idx_block", (DL_FUNC) &C_sl_boot_idx_block, 5},
    {"sl_boot_idx_stationary", (DL_FUNC) &C_sl_boot_idx_stationary, 4},
    {"sl_boot_idx_regime", (DL_FUNC) &C_sl_boot_idx_regime, 4},
    {"sl_boot_idx_tails", (DL_FUNC) &C_sl_boot_idx_tails, 7},
    {"sl_boot_wild", (DL_FUNC) &C_sl_boot_wild, 3},
    {"sl_boot_reset", (DL_FUNC) &C_sl_boot_reset, 3},
    {"sl_boot_evt", (DL_FUNC) &C_sl_boot_evt, 9},
    {"sl_boot_garch", (DL_FUNC) &C_sl_boot_garch, 8},
    {"sl_boot_ms_garch", (DL_FUNC) &C_sl_boot_ms_garch, 9},
    {"sl_rolling_vol", (DL_FUNC) &C_sl_rolling_vol, 2},
    {"sl_assign_regimes", (DL_FUNC) &C_sl_assign_regimes, 2},
    {"sl_estimate_trans_mat", (DL_FUNC) &C_sl_estimate_trans_mat, 3},
    /* tax_core.cpp */
    {"sim_flat_rate", (DL_FUNC) &C_sim_flat_rate, 7},
    {"sim_p20_tax", (DL_FUNC) &C_sim_p20_tax, 5},
    {"sim_vp_tax", (DL_FUNC) &C_sim_vp_tax, 5},
    {"sim_sell_count", (DL_FUNC) &C_sim_sell_count, 10},
    /* withdrawal_core.cpp */
    {"wd_simulate", (DL_FUNC) &C_wd_simulate, 25},
    {NULL, NULL, 0}
};

void R_init_SimLev(DllInfo *dll)
{
    R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
}
