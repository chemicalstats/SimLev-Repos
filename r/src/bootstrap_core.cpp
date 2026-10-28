// src/bootstrap_core.cpp
// .Call-Huellen der Bootstrap-Kerne fuer SimLev (portiert und verallgemeinert aus
// '00 Bootstraps').
//
// Die Rechnung steht seit Etappe 7.3b in src/bootstrap_core_impl.h (ohne R-Bezug,
// Verfahren und Referenzen siehe dort; gemeinsam mit Python: simlev._ext, Kopie in
// python/src/). Diese Datei wandelt nur die Argumente um (wie die fruehere
// Rcpp-Huelle) und ruft die Kerne auf; die Sichten, Aufrufe und Zufallszahlen der
// Kerne bindet simlev_capi.h an R (Abschnitt "R als Host der gemeinsamen Kerne":
// simlev_host::runif/rgeom/rnorm = Rf_runif/Rf_rgeom/Rf_rnorm aus R's nmath).
// GetRNGstate/PutRNGstate setzt der Rahmen sl::call (simlev_capi.h).

#include "simlev_capi.h"
#include "bootstrap_core_impl.h"

// ===========================================================================
// .CALL-HUELLEN (registriert in init.c; R-Seite in R/cores.R)
// ===========================================================================

extern "C" SEXP C_boot_idx_iid(SEXP s_n_src, SEXP s_n_out) {
  return sl::call([&]() {
    int n_src = sl::as_int(s_n_src);
    int n_out = sl::as_int(s_n_out);
    return simlev::boot_idx_iid(n_src, n_out);
  });
}

extern "C" SEXP C_boot_idx_block(SEXP s_n_src, SEXP s_n_out, SEXP s_block_length, SEXP s_circular) {
  return sl::call([&]() {
    int n_src = sl::as_int(s_n_src);
    int n_out = sl::as_int(s_n_out);
    int block_length = sl::as_int(s_block_length);
    bool circular = sl::as_bool(s_circular);
    return simlev::boot_idx_block(n_src, n_out, block_length, circular);
  });
}

extern "C" SEXP C_boot_idx_stationary(SEXP s_n_src, SEXP s_n_out, SEXP s_L) {
  return sl::call([&]() {
    int n_src = sl::as_int(s_n_src);
    int n_out = sl::as_int(s_n_out);
    double L = sl::as_double(s_L);
    return simlev::boot_idx_stationary(n_src, n_out, L);
  });
}

extern "C" SEXP C_boot_idx_regime(SEXP s_regimes, SEXP s_trans, SEXP s_n_out) {
  return sl::call([&]() {
    sl::IntVec regimes = sl::int_vec(s_regimes);
    sl::NumMat trans = sl::num_mat(s_trans);
    int n_out = sl::as_int(s_n_out);
    return simlev::boot_idx_regime(regimes, trans, n_out);
  });
}

extern "C" SEXP C_boot_idx_tails(SEXP s_n_out, SEXP s_p_l, SEXP s_p_r, SEXP s_bulk_idx,
                                 SEXP s_left_idx, SEXP s_right_idx) {
  return sl::call([&]() {
    int n_out = sl::as_int(s_n_out);
    double p_l = sl::as_double(s_p_l);
    double p_r = sl::as_double(s_p_r);
    sl::IntVec bulk_idx = sl::int_vec(s_bulk_idx);
    sl::IntVec left_idx = sl::int_vec(s_left_idx);
    sl::IntVec right_idx = sl::int_vec(s_right_idx);
    return simlev::boot_idx_tails(n_out, p_l, p_r, bulk_idx, left_idx, right_idx);
  });
}

extern "C" SEXP C_boot_wild(SEXP s_returns, SEXP s_type) {
  return sl::call([&]() {
    sl::NumMat returns = sl::num_mat(s_returns);
    int type = sl::as_int(s_type);
    return simlev::boot_wild(returns, type);
  });
}

extern "C" SEXP C_boot_reset(SEXP s_returns, SEXP s_p_break) {
  return sl::call([&]() {
    sl::NumMat returns = sl::num_mat(s_returns);
    double p_break = sl::as_double(s_p_break);
    return simlev::boot_reset(returns, p_break);
  });
}

extern "C" SEXP C_boot_evt(SEXP s_returns, SEXP s_base, SEXP s_n_out, SEXP s_p_l, SEXP s_thresh_l,
                           SEXP s_scale_l, SEXP s_shape_l, SEXP s_pool_l, SEXP s_p_r, SEXP s_thresh_r,
                           SEXP s_scale_r, SEXP s_shape_r, SEXP s_pool_r, SEXP s_bulk_idx) {
  return sl::call([&]() {
    sl::NumMat returns = sl::num_mat(s_returns);
    int base = sl::as_int(s_base);
    int n_out = sl::as_int(s_n_out);
    double p_l = sl::as_double(s_p_l);
    double thresh_l = sl::as_double(s_thresh_l);
    double scale_l = sl::as_double(s_scale_l);
    double shape_l = sl::as_double(s_shape_l);
    sl::IntVec pool_l = sl::int_vec(s_pool_l);
    double p_r = sl::as_double(s_p_r);
    double thresh_r = sl::as_double(s_thresh_r);
    double scale_r = sl::as_double(s_scale_r);
    double shape_r = sl::as_double(s_shape_r);
    sl::IntVec pool_r = sl::int_vec(s_pool_r);
    sl::IntVec bulk_idx = sl::int_vec(s_bulk_idx);
    return simlev::boot_evt(returns, base, n_out, p_l, thresh_l, scale_l, shape_l, pool_l,
                    p_r, thresh_r, scale_r, shape_r, pool_r, bulk_idx);
  });
}

extern "C" SEXP C_boot_garch(SEXP s_n_out, SEXP s_base, SEXP s_k, SEXP s_mu, SEXP s_omega, SEXP s_alpha,
                             SEXP s_beta, SEXP s_gamma, SEXP s_s2_init, SEXP s_z_base, SEXP s_valid,
                             SEXP s_cross_cols, SEXP s_cmu, SEXP s_com, SEXP s_cal, SEXP s_cbe,
                             SEXP s_cratio, SEXP s_cs2, SEXP s_z_cross) {
  return sl::call([&]() {
    int n_out = sl::as_int(s_n_out);
    int base = sl::as_int(s_base);
    int k = sl::as_int(s_k);
    double mu = sl::as_double(s_mu);
    double omega = sl::as_double(s_omega);
    double alpha = sl::as_double(s_alpha);
    double beta = sl::as_double(s_beta);
    double gamma = sl::as_double(s_gamma);
    double s2_init = sl::as_double(s_s2_init);
    sl::NumVec z_base = sl::num_vec(s_z_base);
    sl::IntVec valid = sl::int_vec(s_valid);
    sl::IntVec cross_cols = sl::int_vec(s_cross_cols);
    sl::NumVec cmu = sl::num_vec(s_cmu);
    sl::NumVec com = sl::num_vec(s_com);
    sl::NumVec cal = sl::num_vec(s_cal);
    sl::NumVec cbe = sl::num_vec(s_cbe);
    sl::LglVec cratio = sl::lgl_vec(s_cratio);
    sl::NumVec cs2 = sl::num_vec(s_cs2);
    sl::NumMat z_cross = sl::num_mat(s_z_cross);
    return simlev::boot_garch(n_out, base, k, mu, omega, alpha, beta, gamma, s2_init, z_base, valid,
                      cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross);
  });
}

extern "C" SEXP C_boot_ms_garch(SEXP s_n_out, SEXP s_base, SEXP s_k, SEXP s_K, SEXP s_mu, SEXP s_omega,
                                SEXP s_alpha, SEXP s_beta, SEXP s_gamma, SEXP s_phi, SEXP s_lambda,
                                SEXP s_trans, SEXP s_delta, SEXP s_unc_var, SEXP s_stat_prob,
                                SEXP s_pools, SEXP s_z_base, SEXP s_cross_cols, SEXP s_cmu, SEXP s_com,
                                SEXP s_cal, SEXP s_cbe, SEXP s_cratio, SEXP s_cs2, SEXP s_z_cross) {
  return sl::call([&]() {
    int n_out = sl::as_int(s_n_out);
    int base = sl::as_int(s_base);
    int k = sl::as_int(s_k);
    int K = sl::as_int(s_K);
    sl::NumVec mu = sl::num_vec(s_mu);
    sl::NumVec omega = sl::num_vec(s_omega);
    sl::NumVec alpha = sl::num_vec(s_alpha);
    sl::NumVec beta = sl::num_vec(s_beta);
    sl::NumVec gamma = sl::num_vec(s_gamma);
    sl::NumVec phi = sl::num_vec(s_phi);
    sl::NumVec lambda = sl::num_vec(s_lambda);
    sl::NumMat trans = sl::num_mat(s_trans);
    sl::NumMat delta = sl::num_mat(s_delta);
    sl::NumVec unc_var = sl::num_vec(s_unc_var);
    sl::NumVec stat_prob = sl::num_vec(s_stat_prob);
    SEXP pools = sl::as_list(s_pools);
    sl::NumVec z_base = sl::num_vec(s_z_base);
    sl::IntVec cross_cols = sl::int_vec(s_cross_cols);
    sl::NumVec cmu = sl::num_vec(s_cmu);
    sl::NumVec com = sl::num_vec(s_com);
    sl::NumVec cal = sl::num_vec(s_cal);
    sl::NumVec cbe = sl::num_vec(s_cbe);
    sl::LglVec cratio = sl::lgl_vec(s_cratio);
    sl::NumVec cs2 = sl::num_vec(s_cs2);
    sl::NumMat z_cross = sl::num_mat(s_z_cross);
    return simlev::boot_ms_garch(n_out, base, k, K, mu, omega, alpha, beta, gamma, phi, lambda, trans, delta,
                         unc_var, stat_prob, pools, z_base, cross_cols, cmu, com, cal, cbe, cratio,
                         cs2, z_cross);
  });
}

extern "C" SEXP C_rolling_vol(SEXP s_x, SEXP s_window) {
  return sl::call([&]() {
    sl::NumVec x = sl::num_vec(s_x);
    int window = sl::as_int(s_window);
    return simlev::rolling_vol(x, window);
  });
}

extern "C" SEXP C_assign_regimes(SEXP s_vol, SEXP s_thresh) {
  return sl::call([&]() {
    sl::NumVec vol = sl::num_vec(s_vol);
    sl::NumVec thresh = sl::num_vec(s_thresh);
    return simlev::assign_regimes(vol, thresh);
  });
}

extern "C" SEXP C_estimate_trans_mat(SEXP s_regimes, SEXP s_K, SEXP s_alpha) {
  return sl::call([&]() {
    sl::IntVec regimes = sl::int_vec(s_regimes);
    int K = sl::as_int(s_K);
    double alpha = sl::as_double(s_alpha);
    return simlev::estimate_trans_mat(regimes, K, alpha);
  });
}
