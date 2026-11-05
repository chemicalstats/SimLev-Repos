// src/research_core.cpp
// .Call-Huellen der Rechenkerne fuer Optimierung, Regression, Regime und
// Zeitreihen-Hilfen.
//
// Die Rechnung steht in src/research_core_impl.h (ohne R-Bezug,
// gemeinsam mit Python und Julia; kanonisch in core/, Kopie hier ueber
// core/sync.py). Diese Datei wandelt
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
//   .hmm_em_core        Baum-Welch-EM aus einem Startwert (seit 1.5.0)
//   .goal_dp            Rueckwaertsrekursion von planning_goal() (seit 1.5.0)
//   .pbo_cscv           Aufteilungen der CSCV von overfit_pbo() (seit 1.5.0)
//   .wrapper_nav_core   Tagesschleife des NAV von wrapper_nav() (seit 1.5.1; src/wrapper_core_impl.h)
//   (.garch_filter: bis 1.0.0, ersetzt durch die C-Bibliothek slc)
//   .roll_mean_core     rollierender Mittelwert mit kompensierter Summe
//   .kendall_tau_core   Kendalls Tau-b
//   .roll_cov_core      rollierende Kovarianz
//   C_roll_max_core     rollierendes Maximum (seit 1.6.3; ohne R-Huelle, .Call direkt)
//
// Alle Kerne ziehen keine Zufallszahlen.

#include "simlev_capi.h"
#include "research_core_impl.h"
#include "wrapper_core_impl.h"
#include <vector>

static SEXP proj_box_simplex_r(sl::NumVec v, sl::NumVec lo, sl::NumVec hi) {
  const int n = v.size();
  sl::NumVec out = sl::new_num(n);
  simlev::proj_box_simplex(v.begin(), lo.begin(), hi.begin(), n, out.begin());
  return out.sexp;
}

// ---------------------------------------------------------------------------
// .Call-Huellen (registriert in init.cpp; R-Seite in R/cores.R)
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

// Baum-Welch-EM (simlev::hmm_em): X (Tn x d), k, mu (k x d), S (d x d x k als Vektor), A (k x k), Zahl der
// Iterationen, tol, ridge (d x d) -> NULL bei Fehler, sonst list(mu, S, A, p0, ll, filtered, smoothed, lB, iter)
extern "C" SEXP C_hmm_em_core(SEXP s_X, SEXP s_k, SEXP s_mu, SEXP s_S, SEXP s_A, SEXP s_n, SEXP s_tol, SEXP s_ridge) {
  return sl::call([&]() -> SEXP {
    sl::NumMat X = sl::num_mat(s_X);
    const int Tn = X.nrow(), d = X.ncol(), k = sl::as_int(s_k);
    sl::NumVec mu0 = sl::num_vec(s_mu), S0 = sl::num_vec(s_S), A0 = sl::num_vec(s_A), ridge = sl::num_vec(s_ridge);
    if (k < 1 || Tn < 1 || d < 1 || mu0.size() != (R_xlen_t) k * d || S0.size() != (R_xlen_t) d * d * k ||
        A0.size() != (R_xlen_t) k * k || ridge.size() != (R_xlen_t) d * d)
      sl::stop("hmm_em: Abmessungen passen nicht");
    sl::NumMat mu = sl::new_mat(k, d), A = sl::new_mat(k, k), filt = sl::new_mat(Tn, k), smooth = sl::new_mat(Tn, k),
               lB = sl::new_mat(Tn, k);
    sl::NumVec S = sl::new_num(S0.size()), p0 = sl::new_num(k);
    std::copy(mu0.begin(), mu0.end(), mu.ptr); std::copy(S0.begin(), S0.end(), S.ptr); std::copy(A0.begin(), A0.end(), A.ptr);
    double ll = 0.0;
    int iter = 0;
    if (simlev::hmm_em(Tn, d, k, X.ptr, mu.ptr, S.ptr, A.ptr, p0.ptr, sl::as_int(s_n), sl::as_double(s_tol), ridge.ptr,
                       &ll, filt.ptr, smooth.ptr, lB.ptr, &iter))
      return R_NilValue;
    return sl::named_list("mu", mu, "S", S, "A", A, "p0", p0, "ll", ll, "filtered", filt, "smoothed", smooth, "lB", lB,
                          "iter", iter);
  });
}

// Zielplanung (simlev::goal_dp): R (S x K), grid, cf, goal, wmin, wmax, start_value, tie_score
// -> list(static, policy (horizon x ng, ganzzahlig), value (ng x (horizon + 1)), p_dp, collapsed)
extern "C" SEXP C_goal_dp(SEXP s_R, SEXP s_grid, SEXP s_cf, SEXP s_goal, SEXP s_wmin, SEXP s_wmax, SEXP s_sv,
                          SEXP s_tie) {
  return sl::call([&]() -> SEXP {
    sl::NumMat R = sl::num_mat(s_R);
    sl::NumVec grid = sl::num_vec(s_grid), cf = sl::num_vec(s_cf), tie = sl::num_vec(s_tie);
    const int S = R.nrow(), K = R.ncol(), ng = (int) grid.size(), h = (int) cf.size();
    if (S < 1 || K < 1 || ng < 2 || h < 1 || tie.size() != K) sl::stop("goal_dp: Abmessungen passen nicht");
    sl::NumVec stat = sl::new_num(K);
    sl::NumMat value = sl::new_mat(ng, h + 1);
    SEXP pol = sl::keep(Rf_allocMatrix(INTSXP, h, ng));
    double p_dp = 0.0;
    const int64_t nc = simlev::goal_dp(S, K, R.ptr, ng, grid.ptr, h, cf.ptr, sl::as_double(s_goal), sl::as_double(s_wmin),
                                       sl::as_double(s_wmax), sl::as_double(s_sv), tie.ptr, stat.ptr, INTEGER(pol),
                                       value.ptr, &p_dp);
    if (nc < 0) sl::stop("goal_dp: Fehler der Normalverteilung");
    return sl::named_list("static", stat, "policy", pol, "value", value, "p_dp", p_dp, "collapsed", (int) nc);
  });
}

// CSCV (simlev::pbo_cscv): B (5 Blocksummen S x N hintereinander), T (5 x N Spaltensummen), combos (S/2 x C,
// ganzzahlig), half, metric (0 sharpe, 1 sortino, 2 geometric, 3 mean), S, N -> list(lambda, is_best, oos_best, oos_median)
extern "C" SEXP C_pbo_cscv(SEXP s_B, SEXP s_T, SEXP s_combos, SEXP s_half, SEXP s_metric, SEXP s_S, SEXP s_N) {
  return sl::call([&]() -> SEXP {
    sl::NumVec B = sl::num_vec(s_B), T = sl::num_vec(s_T);
    sl::IntVec cb = sl::int_vec(s_combos);
    const int S = sl::as_int(s_S), N = sl::as_int(s_N);
    if (S < 2 || S % 2 || N < 1 || B.size() != (R_xlen_t) 5 * S * N || T.size() != (R_xlen_t) 5 * N || cb.size() % (S / 2))
      sl::stop("pbo_cscv: Abmessungen passen nicht");
    const int C = (int) (cb.size() / (S / 2));
    for (R_xlen_t i = 0; i < cb.size(); i++) if (cb[i] < 1 || cb[i] > S) sl::stop("pbo_cscv: Block ausserhalb 1..%d", S);
    sl::NumVec lam = sl::new_num(C), isb = sl::new_num(C), oosb = sl::new_num(C), oosm = sl::new_num(C);
    simlev::pbo_cscv(S, N, C, B.ptr, T.ptr, cb.ptr, sl::as_double(s_half), sl::as_int(s_metric), lam.ptr, isb.ptr, oosb.ptr,
                     oosm.ptr);
    return sl::named_list("lambda", lam, "is_best", isb, "oos_best", oosb, "oos_median", oosm);
  });
}

// NAV eines Fonds-Wrappers (simlev::wrapper_nav_core): G, day, yr (ganzzahlig), fee, pf, S, d0
// -> list(bad (0 = ok, sonst erster Tag 1-basiert), nav, gross, fee, perf_fee, perf_paid, hwm)
extern "C" SEXP C_wrapper_nav_core(SEXP s_G, SEXP s_day, SEXP s_yr, SEXP s_fee, SEXP s_pf, SEXP s_S, SEXP s_d0) {
  return sl::call([&]() -> SEXP {
    sl::NumVec G = sl::num_vec(s_G), day = sl::num_vec(s_day);
    sl::IntVec yi = sl::int_vec(s_yr);
    const R_xlen_t n = G.size();
    if (day.size() != n || yi.size() != n) sl::stop("wrapper_nav_core: Abmessungen passen nicht");
    std::vector<int64_t> yr((std::size_t) n);
    for (R_xlen_t i = 0; i < n; i++) yr[i] = yi[i];
    sl::NumVec nav = sl::new_num(n), gross = sl::new_num(n), fee = sl::new_num(n), acc = sl::new_num(n),
               paid = sl::new_num(n), hwm = sl::new_num(n);
    const int64_t bad = simlev::wrapper_nav_core(n, G.ptr, day.ptr, yr.data(), sl::as_double(s_fee), sl::as_double(s_pf),
                                                 sl::as_double(s_S), sl::as_double(s_d0), nav.ptr, gross.ptr, fee.ptr,
                                                 acc.ptr, paid.ptr, hwm.ptr);
    return sl::named_list("bad", (double) (bad + 1), "nav", nav, "gross", gross, "fee", fee, "perf_fee", acc,
                          "perf_paid", paid, "hwm", hwm);
  });
}

extern "C" SEXP C_roll_mean_core(SEXP s_x, SEXP s_n) {
  return sl::call([&]() {
    sl::NumVec x = sl::num_vec(s_x);
    int n = sl::as_int(s_n);
    return simlev::roll_mean_core(x, n);
  });
}

// Rollierendes Maximum (seit 1.6.3, research_core_impl.h roll_max_core): x double (NaN/NA zaehlen als -Inf),
// w >= 1 (Fenster), zero 0 (R: erstes Auftreten) bzw. 1 (-0 < +0); Ergebnis double wie x
extern "C" SEXP C_roll_max_core(SEXP s_x, SEXP s_w, SEXP s_zero) {
  return sl::call([&]() {
    sl::NumVec x = sl::num_vec(s_x);
    const double w = sl::as_double(s_w);
    const int zero = sl::as_int(s_zero);
    if (!(w >= 1)) sl::stop("roll_max_core: Fenster muss >= 1 sein");
    sl::NumVec out = sl::new_num(x.len);
    if (simlev::roll_max_core(x.len, x.ptr, w >= 9.0e18 ? INT64_MAX : (int64_t) w, zero, out.ptr) != 0)
      sl::stop("roll_max_core: zero muss 0 oder 1 sein");
    return out.sexp;
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
