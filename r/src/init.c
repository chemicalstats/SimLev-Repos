/*
 * src/init.c -- Registrierung der .Call-Routinen von SimLev
 *
 * Seit 0.5.0 ohne Rcpp: Die C++-Kerne haben extern "C"-Huellen (am Ende der
 * jeweiligen .cpp-Datei, Rahmen in simlev_capi.h), die C-Uebernahmen
 * (vendor_*.c) ihre eigenen .Call-Huellen. Registriert sind nur .Call-Routinen
 * unter Namen ohne Praefix; NAMESPACE laedt sie mit
 * useDynLib(SimLev, .registration = TRUE, .fixes = "C_"), in R heissen sie
 * daher C_<name> (z. B. C_sim_buy, gerufen von .sim_buy_cpp in R/cores.R).
 * Dynamische Symbolsuche ist abgeschaltet.
 */
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

/* bootstrap_core.cpp */
extern SEXP C_boot_idx_iid(SEXP, SEXP);
extern SEXP C_boot_idx_block(SEXP, SEXP, SEXP, SEXP);
extern SEXP C_boot_idx_stationary(SEXP, SEXP, SEXP);
extern SEXP C_boot_idx_regime(SEXP, SEXP, SEXP);
extern SEXP C_boot_idx_tails(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_boot_wild(SEXP, SEXP);
extern SEXP C_boot_reset(SEXP, SEXP);
extern SEXP C_boot_evt(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_boot_garch(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_boot_ms_garch(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_rolling_vol(SEXP, SEXP);
extern SEXP C_assign_regimes(SEXP, SEXP);
extern SEXP C_estimate_trans_mat(SEXP, SEXP, SEXP);
/* dependence_core.cpp */
extern SEXP C_dcc_filter(SEXP, SEXP, SEXP, SEXP, SEXP);
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
extern SEXP C_garch_filter(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
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
/* tax_core.cpp */
extern SEXP C_sim_flat_rate(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sim_p20_tax(SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sim_vp_tax(SEXP, SEXP, SEXP, SEXP, SEXP);
extern SEXP C_sim_sell_count(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
/* vendor_imputets.cpp */
extern SEXP C_imputets_locf(SEXP, SEXP);
/* withdrawal_core.cpp */
extern SEXP C_wd_simulate(SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP, SEXP);
/* vendor_evd.c */
extern SEXP C_evd_nlgpd(SEXP, SEXP, SEXP, SEXP, SEXP);
/* vendor_rugarch.c */
extern SEXP C_rugarch_gjrgarchfilterC(SEXP);
extern SEXP C_rugarch_sgarchfilterC(SEXP);
/* vendor_truncnorm.c */
extern SEXP C_truncnorm_rtruncnorm(SEXP, SEXP, SEXP, SEXP, SEXP);

static const R_CallMethodDef CallEntries[] = {
    /* bootstrap_core.cpp */
    {"boot_idx_iid", (DL_FUNC) &C_boot_idx_iid, 2},
    {"boot_idx_block", (DL_FUNC) &C_boot_idx_block, 4},
    {"boot_idx_stationary", (DL_FUNC) &C_boot_idx_stationary, 3},
    {"boot_idx_regime", (DL_FUNC) &C_boot_idx_regime, 3},
    {"boot_idx_tails", (DL_FUNC) &C_boot_idx_tails, 6},
    {"boot_wild", (DL_FUNC) &C_boot_wild, 2},
    {"boot_reset", (DL_FUNC) &C_boot_reset, 2},
    {"boot_evt", (DL_FUNC) &C_boot_evt, 14},
    {"boot_garch", (DL_FUNC) &C_boot_garch, 19},
    {"boot_ms_garch", (DL_FUNC) &C_boot_ms_garch, 25},
    {"rolling_vol", (DL_FUNC) &C_rolling_vol, 2},
    {"assign_regimes", (DL_FUNC) &C_assign_regimes, 2},
    {"estimate_trans_mat", (DL_FUNC) &C_estimate_trans_mat, 3},
    /* dependence_core.cpp */
    {"dcc_filter", (DL_FUNC) &C_dcc_filter, 5},
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
    {"garch_filter", (DL_FUNC) &C_garch_filter, 6},
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
    /* tax_core.cpp */
    {"sim_flat_rate", (DL_FUNC) &C_sim_flat_rate, 7},
    {"sim_p20_tax", (DL_FUNC) &C_sim_p20_tax, 5},
    {"sim_vp_tax", (DL_FUNC) &C_sim_vp_tax, 5},
    {"sim_sell_count", (DL_FUNC) &C_sim_sell_count, 10},
    /* vendor_imputets.cpp */
    {"imputets_locf", (DL_FUNC) &C_imputets_locf, 2},
    /* withdrawal_core.cpp */
    {"wd_simulate", (DL_FUNC) &C_wd_simulate, 25},
    /* vendor_evd.c */
    {"evd_nlgpd", (DL_FUNC) &C_evd_nlgpd, 5},
    /* vendor_rugarch.c */
    {"rugarch_gjrgarchfilterC", (DL_FUNC) &C_rugarch_gjrgarchfilterC, 1},
    {"rugarch_sgarchfilterC", (DL_FUNC) &C_rugarch_sgarchfilterC, 1},
    /* vendor_truncnorm.c */
    {"truncnorm_rtruncnorm", (DL_FUNC) &C_truncnorm_rtruncnorm, 5},
    {NULL, NULL, 0}
};

void R_init_SimLev(DllInfo *dll)
{
    R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
}
