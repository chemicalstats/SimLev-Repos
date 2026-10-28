// src/research_core.cpp
// .Call-Huellen der Rechenkerne fuer Optimierung, Regression, Regime und
// Zeitreihen-Hilfen.
//
// Die Rechnung steht seit Etappe 7.3a in src/research_core_impl.h (ohne R-Bezug,
// gemeinsam mit Python: simlev._ext, Kopie in python/src/). Diese Datei wandelt
// nur die Argumente um (wie die frueheren Rcpp-Huellen) und ruft die Kerne auf; die
// Sichten und Aufrufe der Kerne bindet simlev_capi.h an R (Abschnitt "R als Host
// der gemeinsamen Kerne").
//
//   .proj_box_simplex   exakte Projektion auf {w : sum w = 1, lo <= w <= hi}
//   .qp_box_simplex     min 0.5 w'Qw + c'w auf dem beschraenkten Simplex
//   .min_cvar_core      minimaler CVaR
//   .min_cdar_core      minimaler Conditional Drawdown at Risk
//   .quantile_reg_core  lineare Quantilsregression
//   .hmm_forward_backward  skalierter Vorwaerts-Rueckwaerts-Schritt (Baum-Welch)
//   .garch_filter       bedingte Varianzen eines GARCH(1,1)/GJR-Modells
//   .roll_mean_core     rollierender Mittelwert mit kompensierter Summe
//   .kendall_tau_core   Kendalls Tau-b
//   .roll_cov_core      rollierende Kovarianz
//
// Alle Kerne ziehen keine Zufallszahlen.

#include "simlev_capi.h"
#include "research_core_impl.h"
#include <vector>

static SEXP proj_box_simplex_r(sl::NumVec v, sl::NumVec lo, sl::NumVec hi) {
  const int n = v.size();
  sl::NumVec out = sl::new_num(n);
  simlev::proj_box_simplex(v.begin(), lo.begin(), hi.begin(), n, out.begin());
  return out.sexp;
}

// ---------------------------------------------------------------------------
// .Call-Huellen (registriert in init.c; R-Seite in R/cores.R)
// ---------------------------------------------------------------------------

extern "C" SEXP C_proj_box_simplex(SEXP s_v, SEXP s_lo, SEXP s_hi) {
  return sl::call([&]() {
    sl::NumVec v = sl::num_vec(s_v);
    sl::NumVec lo = sl::num_vec(s_lo);
    sl::NumVec hi = sl::num_vec(s_hi);
    return proj_box_simplex_r(v, lo, hi);
  });
}

extern "C" SEXP C_qp_box_simplex(SEXP s_Q, SEXP s_cvec, SEXP s_lo, SEXP s_hi, SEXP s_w0, SEXP s_L,
                                 SEXP s_maxit, SEXP s_tol) {
  return sl::call([&]() {
    sl::NumMat Q = sl::num_mat(s_Q);
    sl::NumVec cvec = sl::num_vec(s_cvec);
    sl::NumVec lo = sl::num_vec(s_lo);
    sl::NumVec hi = sl::num_vec(s_hi);
    sl::NumVec w0 = sl::num_vec(s_w0);
    double L = sl::as_double(s_L);
    int maxit = sl::as_int(s_maxit);
    double tol = sl::as_double(s_tol);
    return simlev::qp_box_simplex(Q, cvec, lo, hi, w0, L, maxit, tol);
  });
}

extern "C" SEXP C_min_cvar_core(SEXP s_R, SEXP s_alpha, SEXP s_lo, SEXP s_hi, SEXP s_w0, SEXP s_zeta0,
                                SEXP s_scales, SEXP s_maxit) {
  return sl::call([&]() {
    sl::NumMat R = sl::num_mat(s_R);
    double alpha = sl::as_double(s_alpha);
    sl::NumVec lo = sl::num_vec(s_lo);
    sl::NumVec hi = sl::num_vec(s_hi);
    sl::NumVec w0 = sl::num_vec(s_w0);
    double zeta0 = sl::as_double(s_zeta0);
    sl::NumVec scales = sl::num_vec(s_scales);
    int maxit = sl::as_int(s_maxit);
    return simlev::min_cvar_core(R, alpha, lo, hi, w0, zeta0, scales, maxit);
  });
}

extern "C" SEXP C_min_cdar_core(SEXP s_R, SEXP s_alpha, SEXP s_lo, SEXP s_hi, SEXP s_iters) {
  return sl::call([&]() {
    sl::NumMat R = sl::num_mat(s_R);
    double alpha = sl::as_double(s_alpha);
    sl::NumVec lo = sl::num_vec(s_lo);
    sl::NumVec hi = sl::num_vec(s_hi);
    int iters = sl::as_int(s_iters);
    return simlev::min_cdar_core(R, alpha, lo, hi, iters);
  });
}

extern "C" SEXP C_quantile_reg_core(SEXP s_y, SEXP s_X, SEXP s_tau, SEXP s_beta0, SEXP s_sc, SEXP s_tol,
                                    SEXP s_maxit) {
  return sl::call([&]() {
    sl::NumVec y = sl::num_vec(s_y);
    sl::NumMat X = sl::num_mat(s_X);
    double tau = sl::as_double(s_tau);
    sl::NumVec beta0 = sl::num_vec(s_beta0);
    double sc = sl::as_double(s_sc);
    double tol = sl::as_double(s_tol);
    int maxit = sl::as_int(s_maxit);
    return simlev::quantile_reg_core(y, X, tau, beta0, sc, tol, maxit);
  });
}

extern "C" SEXP C_hmm_forward_backward(SEXP s_B, SEXP s_A, SEXP s_p0) {
  return sl::call([&]() {
    sl::NumMat B = sl::num_mat(s_B);
    sl::NumMat A = sl::num_mat(s_A);
    sl::NumVec p0 = sl::num_vec(s_p0);
    return simlev::hmm_forward_backward(B, A, p0);
  });
}

extern "C" SEXP C_garch_filter(SEXP s_ep, SEXP s_om, SEXP s_al, SEXP s_be, SEXP s_ga, SEXP s_v0) {
  return sl::call([&]() {
    sl::NumVec ep = sl::num_vec(s_ep);
    double om = sl::as_double(s_om);
    double al = sl::as_double(s_al);
    double be = sl::as_double(s_be);
    double ga = sl::as_double(s_ga);
    double v0 = sl::as_double(s_v0);
    return simlev::garch_filter(ep, om, al, be, ga, v0);
  });
}

extern "C" SEXP C_roll_mean_core(SEXP s_x, SEXP s_n) {
  return sl::call([&]() {
    sl::NumVec x = sl::num_vec(s_x);
    int n = sl::as_int(s_n);
    return simlev::roll_mean_core(x, n);
  });
}

extern "C" SEXP C_kendall_tau_core(SEXP s_x, SEXP s_y) {
  return sl::call([&]() {
    sl::NumVec x = sl::num_vec(s_x);
    sl::NumVec y = sl::num_vec(s_y);
    return sl::wrap(simlev::kendall_tau_core(x, y));
  });
}

extern "C" SEXP C_roll_cov_core(SEXP s_x, SEXP s_y, SEXP s_n) {
  return sl::call([&]() {
    sl::NumVec x = sl::num_vec(s_x);
    sl::NumVec y = sl::num_vec(s_y);
    int n = sl::as_int(s_n);
    return simlev::roll_cov_core(x, y, n);
  });
}
