# Huellen der Modelle der C-Bibliothek slc (SimLev core, Etappe 9.4): GARCH/GJR(1,1), GPD,
# DCC(1,1), MS-GARCH und univariates HMM, Bootstrap-Kerne. Die Rechnung steht in
# src/slc_{garch,gpd,dcc,msgarch,boot}.c (Kopien von core/, tools/core_sync.py), die .Call-Huellen
# in src/slc_r_models.c (Registrierung in src/init.c, in R als C_sl_*).
#
# Seit Etappe 9.6a ziehen die Bootstrap-Verfahren ueber .sl_boot_*(..., stream) mit dem Strom je
# Pfad (R/bootstrap.R, .generate_returns) bzw. dem Hauptstrom (sharpe_test, dependence_analysis
# u. a.). Seit Etappe 9.6b rufen .fit_garch11, .fit_tail, dependence_dcc und .ms_garch_fit die
# Huellen hier auf (sie geben dieselben Ergebnisstrukturen zurueck wie die frueheren Wege):
#   .sl_fit_garch11(e, gjr, quiet)  wie .fit_garch11 (Methode "ml" statt "rugarch"/"optim", F10)
#   .sl_gpd_fit(exc)                ersetzt .evd_fpot(exc, threshold = 0, std.err = FALSE)
#   .sl_dcc_fit(Z, Qbar)            ersetzt optim(Nelder-Mead) in dependence_dcc
#   .sl_ms_garch_fit(y, K, model)   wie .ms_garch_fit (ganz in C)
#   .sl_boot_*(..., stream)         wie .boot_* mit Zug aus einem SimLev-Strom (Entwurf C.5)

# ── GARCH(1,1) / GJR-GARCH(1,1) ──────────────────────────────────────────────

.sl_garch_methods <- c("konstant", "ml", "momente")

# Filter: s2[1] = s2_init, Untergrenze 1e-14 (wie der frühere .garch_filter)
.sl_garch11_filter <- function(eps, omega, alpha, beta, gamma, s2_init)
  .Call(C_sl_garch11_filter, as.double(eps), as.double(omega), as.double(alpha), as.double(beta),
        as.double(gamma), as.double(s2_init))

# NLL an par = c(mu, omega, alpha, beta, gamma); s2_init = NULL: Stichprobenvarianz
.sl_garch11_nll <- function(e, par, gjr = FALSE, s2_init = NULL)
  .Call(C_sl_garch11_nll, as.double(e), as.double(rep_len(c(par, 0), 5)), as.logical(gjr),
        if (is.null(s2_init)) NaN else as.double(s2_init))

# ML-Punktschaetzer (Fehler, wenn die Schaetzung scheitert)
.sl_garch11_fit <- function(e, gjr = FALSE) {
  f <- .Call(C_sl_garch11_fit, as.double(e), as.logical(gjr))
  c(f, list(method = "ml"))
}

#' GARCH(1,1) / GJR-GARCH(1,1) wie .fit_garch11 mit der C-Bibliothek slc (ML -> Momente)
#' @keywords internal
#' @noRd
.sl_fit_garch11 <- function(e, gjr = FALSE, quiet = FALSE) {
  f <- .Call(C_sl_garch11_estimate, as.double(e), as.logical(gjr))
  method <- .sl_garch_methods[f$method + 1L]
  if (method == "konstant")
    return(list(mu = f$mu, omega = f$omega, alpha = 0, beta = 0, gamma = 0, s2 = f$s2, z = f$z,
                method = "konstant", s2_init = f$s2_init))
  if (method == "momente" && !quiet) warning("GARCH: ML-Sch\u00e4tzung fehlgeschlagen, verwende Moment-Sch\u00e4tzer", call. = FALSE)
  list(mu = f$mu, omega = f$omega, alpha = f$alpha, beta = f$beta, gamma = f$gamma, s2 = f$s2, z = f$z,
       method = method, persistence = f$persistence, s2_init = f$s2_init)
}

# ── Verallgemeinerte Pareto-Verteilung ───────────────────────────────────────

.sl_gpd_nll <- function(x, scale, shape) .Call(C_sl_gpd_nll, as.double(x), as.double(scale), as.double(shape))

.sl_gpd_pwm <- function(x) { v <- .Call(C_sl_gpd_pwm, as.double(x)); list(scale = v[1], shape = v[2]) }

# ML der Ueberschreitungen (>= 0); list(scale, shape, loglik, convergence)
.sl_gpd_fit <- function(x) .Call(C_sl_gpd_fit, as.double(x))

# ── DCC(1,1) ─────────────────────────────────────────────────────────────────

# Matrix (auch data.frame) als double-Matrix
.sl_mmat <- function(x) { x <- as.matrix(x); storage.mode(x) <- "double"; x }

# wie .dcc_filter: list(nll, R, ok)
.sl_dcc_filter <- function(Z, a, b, Qbar, keep)
  .Call(C_sl_dcc_filter, .sl_mmat(Z), as.double(a), as.double(b), .sl_mmat(Qbar), as.logical(keep))

# Schaetzung von (a, b) ganz in C (Nelder-Mead wie dependence_dcc); list(a, b, nll, convergence, par)
.sl_dcc_fit <- function(Z, Qbar) .Call(C_sl_dcc_fit, .sl_mmat(Z), .sl_mmat(Qbar))

# ── MS-GARCH und HMM ─────────────────────────────────────────────────────────

# wie .ms_garch_filter: list(loglik, h, pred, filt, lB)
.sl_ms_garch_filter <- function(y, omega, alpha, beta, gamma, P, xi0, h1)
  .Call(C_sl_ms_garch_filter, as.double(y), as.double(omega), as.double(alpha), as.double(beta),
        as.double(gamma), as.double(P), as.double(xi0), as.double(h1))

.sl_ms_gjr <- function(model) {
  if (!is.character(model) || length(model) != 1L || is.na(model) || !model %in% c("sGARCH", "gjrGARCH"))
    stop("interner Fehler: model muss \"sGARCH\" oder \"gjrGARCH\" sein", call. = FALSE)
  model == "gjrGARCH"
}

# h1 = NULL: Stichprobenvarianz von y (im Kern)
.sl_h1 <- function(h1) if (is.null(h1)) NaN else as.double(h1)

# negative Log-Likelihood an theta (Parametrisierung wie sl_ms_garch_unpack in src/slc_msgarch.c; nicht endlich -> Inf)
.sl_ms_garch_nll <- function(theta, y, K, model, h1 = NULL)
  .Call(C_sl_ms_garch_nll, as.double(y), as.double(theta), as.integer(K), .sl_ms_gjr(model), .sl_h1(h1))

# N1: NLL und analytischer Gradient an theta (vorwaerts mitdifferenzierter Hamilton-Filter);
# list(value, gradient), nicht endliche Likelihood: value = Inf, gradient = NaN
.sl_ms_garch_grad <- function(theta, y, K, model, h1 = NULL)
  .Call(C_sl_ms_garch_grad, as.double(y), as.double(theta), as.integer(K), .sl_ms_gjr(model), .sl_h1(h1))

# Startpunkte wie .ms_garch_fit (Spalten: HMM-Start, falls gelungen, dann Rang-Start); all = TRUE:
# danach die uebrigen Rasterpunkte beider Familien (so rechnet .sl_ms_garch_fit, 9.4; N1: bei
# gjrGARCH 20 statt 12 Spalten)
.sl_ms_garch_starts <- function(y, K, model, h1 = NULL, all = FALSE)
  .Call(C_sl_ms_garch_starts, as.double(y), as.integer(K), .sl_ms_gjr(model), .sl_h1(h1), as.logical(all))

# BFGS von gegebenen Startpunkten (Spalten); list(par, value, convergence)
.sl_ms_garch_fitstarts <- function(y, K, model, starts, h1 = NULL)
  .Call(C_sl_ms_garch_fitstarts, as.double(y), as.integer(K), .sl_ms_gjr(model), .sl_mmat(starts), .sl_h1(h1))

#' MS-GARCH-Modell wie .ms_garch_fit, ganz in C (Starts, BFGS, Sortierung, Viterbi); BFGS laeuft von
#' allen Rasterpunkten der beiden Startfamilien (die zwei bisherigen zuerst; sGARCH 12, gjrGARCH seit
#' N1 20), seit N1 mit analytischem Gradienten
#' @keywords internal
#' @noRd
.sl_ms_garch_fit <- function(y, K, model) {
  .ms_garch_check(K, model)
  .Call(C_sl_ms_garch_estimate, as.double(y), as.integer(K), model == "gjrGARCH")
}

# univariates Gauss-HMM wie .hmm_em(X, K, .hmm_init_rank(X, K, win, ridge), max_iter, tol, ridge)
.sl_hmm_em_univ <- function(x, K, win = 21L, max_iter = 300L, tol = 1e-7)
  .Call(C_sl_hmm_em_univ, as.double(x), as.integer(K), as.integer(win), as.integer(max_iter), as.double(tol))

.sl_hmm_viterbi <- function(lB, lA, lp0) .Call(C_sl_hmm_viterbi, .sl_mmat(lB), .sl_mmat(lA), as.double(lp0))

# ── Bootstrap-Kerne (Zufall aus stream bzw. dem globalen Zustand, Entwurf C.5) ──

.sl_boot_idx_iid <- function(n_src, n_out, stream = NULL)
  .sl_draw(C_sl_boot_idx_iid, stream, as.integer(n_src), as.integer(n_out))

.sl_boot_idx_block <- function(n_src, n_out, block_length, circular, stream = NULL)
  .sl_draw(C_sl_boot_idx_block, stream, as.integer(n_src), as.integer(n_out), as.integer(block_length),
           as.logical(circular))

.sl_boot_idx_stationary <- function(n_src, n_out, L, stream = NULL)
  .sl_draw(C_sl_boot_idx_stationary, stream, as.integer(n_src), as.integer(n_out), as.double(L))

.sl_boot_idx_regime <- function(regimes, trans, n_out, stream = NULL)
  .sl_draw(C_sl_boot_idx_regime, stream, as.integer(regimes), .sl_mmat(trans), as.integer(n_out))

.sl_boot_idx_tails <- function(n_out, p_l, p_r, bulk_idx, left_idx, right_idx, stream = NULL)
  .sl_draw(C_sl_boot_idx_tails, stream, as.integer(n_out), as.double(p_l), as.double(p_r),
           as.integer(bulk_idx), as.integer(left_idx), as.integer(right_idx))

.sl_boot_wild <- function(returns, type, stream = NULL)
  .sl_draw(C_sl_boot_wild, stream, .sl_mmat(returns), as.integer(type))

.sl_boot_reset <- function(returns, p_break, stream = NULL)
  .sl_draw(C_sl_boot_reset, stream, .sl_mmat(returns), as.double(p_break))

.sl_boot_evt <- function(returns, base, n_out, p_l, thresh_l, scale_l, shape_l, pool_l,
                         p_r, thresh_r, scale_r, shape_r, pool_r, bulk_idx, stream = NULL)
  .sl_draw(C_sl_boot_evt, stream, .sl_mmat(returns), as.integer(base), as.integer(n_out),
           as.double(c(p_l, thresh_l, scale_l, shape_l)), as.integer(pool_l),
           as.double(c(p_r, thresh_r, scale_r, shape_r)), as.integer(pool_r), as.integer(bulk_idx))

.sl_boot_cross <- function(cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross)
  list(as.integer(cross_cols), as.double(cmu), as.double(com), as.double(cal), as.double(cbe),
       as.integer(as.logical(cratio)), as.double(cs2),
       if (length(cross_cols)) .sl_mmat(z_cross) else matrix(0, 0, 0))

.sl_boot_garch <- function(n_out, base, k, mu, omega, alpha, beta, gamma, s2_init, z_base, valid,
                           cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross, stream = NULL)
  .sl_draw(C_sl_boot_garch, stream, as.integer(n_out), as.integer(base), as.integer(k),
           as.double(c(mu, omega, alpha, beta, gamma, s2_init)), as.double(z_base), as.integer(valid),
           .sl_boot_cross(cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross))

.sl_boot_ms_garch <- function(n_out, base, k, K, mu, omega, alpha, beta, gamma, phi, lambda,
                              trans, delta, unc_var, stat_prob, pools, z_base, cross_cols,
                              cmu, com, cal, cbe, cratio, cs2, z_cross, stream = NULL) {
  pools <- lapply(pools, as.integer)
  if (length(pools) != K) stop("interner Fehler: pools muss K Eintraege haben", call. = FALSE)
  off <- as.integer(c(0L, cumsum(lengths(pools))))
  m <- list(as.double(mu), as.double(omega), as.double(alpha), as.double(beta), as.double(gamma),
            as.double(phi), as.double(lambda), .sl_mmat(trans), .sl_mmat(delta), as.double(unc_var),
            as.double(stat_prob))
  .sl_draw(C_sl_boot_ms_garch, stream, as.integer(n_out), as.integer(base), as.integer(k), m, off,
           as.integer(unlist(pools)), as.double(z_base),
           .sl_boot_cross(cross_cols, cmu, com, cal, cbe, cratio, cs2, z_cross))
}

.sl_rolling_vol <- function(x, window) .Call(C_sl_rolling_vol, as.double(x), as.integer(window))

.sl_assign_regimes <- function(vol, thresh) .Call(C_sl_assign_regimes, as.double(vol), as.double(thresh))

.sl_estimate_trans_mat <- function(regimes, K, alpha = 0.1)
  .Call(C_sl_estimate_trans_mat, as.integer(regimes), as.integer(K), as.double(alpha))
