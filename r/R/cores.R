# R-Huellen der C++-Kerne (src/*.cpp).
#
# Seit 0.5.0 ohne Rcpp: Die Kerne sind ueber R's C-Schnittstelle angebunden
# (src/simlev_capi.h, Registrierung in src/init.cpp). NAMESPACE laedt die
# Routinen mit useDynLib(SimLev, .registration = TRUE, .fixes = "C_"); jede
# registrierte Routine <name> steht in R als C_<name> bereit. Die Huellen
# entsprechen den frueheren, von Rcpp::compileAttributes() erzeugten
# (RcppExports.R): gleiche Argumente und Standardwerte, Funktionen ohne
# Rueckgabewert liefern unsichtbar NULL.
#
# Die Rechnung der Kerne steht in den geteilten Dateien *_impl.h, kanonisch in core/ (Kopien
# in src/ ueber core/sync.py). Die frueheren Bootstrap-, DCC-
# und MS-GARCH-Kerne (bootstrap_core.cpp, dependence_core.cpp, ms_garch.c) und
# die C-Uebernahmen (vendor_*) sind seit 1.0.0 entfallen; ihre Aufgaben rechnet die
# C-Bibliothek slc (R/slc*.R).

# ── Optimierung, Regression, Regime, Zeitreihen (src/research_core.cpp) ──────

.proj_box_simplex <- function(v, lo, hi) {
  .Call(C_proj_box_simplex, v, lo, hi)
}

.qp_box_simplex <- function(Q, cvec, lo, hi, w0, L, maxit, tol) {
  .Call(C_qp_box_simplex, Q, cvec, lo, hi, w0, L, maxit, tol)
}

.min_cvar_core <- function(R, alpha, lo, hi, w0, zeta0, scales, maxit) {
  .Call(C_min_cvar_core, R, alpha, lo, hi, w0, zeta0, scales, maxit)
}

.min_cdar_core <- function(R, alpha, lo, hi, iters) {
  .Call(C_min_cdar_core, R, alpha, lo, hi, iters)
}

.quantile_reg_core <- function(y, X, tau, beta0, sc, tol, maxit) {
  .Call(C_quantile_reg_core, y, X, tau, beta0, sc, tol, maxit)
}

# Baum-Welch-EM aus einem Startwert (seit 1.5.0): NULL bei Fehler, sonst list(mu, S (d x d x k als Vektor), A, p0, ll,
# filtered, smoothed, lB, iter)
.hmm_em_core <- function(X, k, mu, S, A, n_iter, tol, ridge)
  .Call(C_hmm_em_core, X, as.integer(k), mu, as.numeric(S), A, as.integer(n_iter), as.numeric(tol), ridge)

# Rueckwaertsrekursion von planning_goal() (seit 1.5.0): list(static, policy, value (ng x (horizon + 1)), p_dp,
# collapsed = Zahl der approx-Aufrufe mit zusammengefassten gleichen log(grid)-Werten)
.goal_dp <- function(R, grid, cf, goal, wmin, wmax, start_value, tie_score)
  .Call(C_goal_dp, R, as.numeric(grid), as.numeric(cf), as.numeric(goal), as.numeric(wmin), as.numeric(wmax),
        as.numeric(start_value), as.numeric(tie_score))

# Aufteilungen der CSCV von overfit_pbo() (seit 1.5.0): list(lambda, is_best, oos_best, oos_median)
.pbo_cscv <- function(B, T, combos, half, metric, S, N)
  .Call(C_pbo_cscv, as.numeric(B), as.numeric(T), combos, as.numeric(half),
        match(metric, c("sharpe", "sortino", "geometric", "mean")) - 1L, as.integer(S), as.integer(N))

# Tagesschleife des NAV von wrapper_nav() (seit 1.5.1): list(bad (0 oder erster Tag ohne Anteilswert), nav, gross,
# fee, perf_fee, perf_paid, hwm)
.wrapper_nav_core <- function(G, day, yr, fee, pf, S, d0)
  .Call(C_wrapper_nav_core, as.numeric(G), as.numeric(day), as.integer(yr), as.numeric(fee), as.numeric(pf),
        as.numeric(S), as.numeric(d0))

.roll_mean_core <- function(x, n) {
  .Call(C_roll_mean_core, x, n)
}

.kendall_tau_core <- function(x, y) {
  .Call(C_kendall_tau_core, x, y)
}

.roll_cov_core <- function(x, y, n) {
  .Call(C_roll_cov_core, x, y, n)
}

# Die Tagesengine von simulation() ruft .sim_engine_run (R/sim_engine.R) direkt ueber .Call(C_sim_engine_run)
# (src/engine_core.cpp, Kern engine_core_impl.h); die frueheren Engine-Kerne simulation_core, fifo_core und
# tax_core mit ihren Huellen sind seit 1.4.0 entfallen.

# ── Entnahme (src/withdrawal_core.cpp) ───────────────────────────────────────

# Schneller Entnahme-Kern ueber viele Pfade (withdrawal_simulation())
.wd_simulate <- function(R, INF, CAPE, BASE, ppy, rule, rp, start_timing, start_value, income_real,
                         tax_on, tax_rate, tfs, spb_annual, vp_on, cost, basis_ratio, loss0, keep,
                         lot_n = as.numeric(c()), lot_basis = as.numeric(c()),
                         lot_vp = as.numeric(c()), lot_group = as.integer(c()),
                         spb_first = -1.0, horizon_end = FALSE, tariff_par = as.numeric(c()),
                         zve = as.numeric(c())) {
  r <- .Call(C_wd_simulate, R, INF, CAPE, BASE, ppy, rule, rp, start_timing, start_value, income_real,
             tax_on, tax_rate, tfs, spb_annual, vp_on, cost, basis_ratio, loss0, keep,
             lot_n, lot_basis, lot_vp, lot_group, spb_first, horizon_end, tariff_par, zve)
  if (!length(tariff_par)) r$tariff_years <- NULL   # Jahreszeilen nur mit Tarifweg (sonst Liste wie bisher)
  r
}

# Auswertung je Pfad (seit 1.5.0, core/withdrawal_core_impl.h): Kennzahlen der Entnahmen (Liste mean_spending,
# min_spending, spending_drawdown, ce_spending, total_spending; H = NULL oder Horizont je Pfad), Perfect Withdrawal
# Rate (Liste pwr, status 0/1 nicht endlich/2 Median < 0.5/3 negativ, path), Jahresprodukte je ppy Perioden und
# Jahreszeilen des Tarifwegs ohne Jahre NA (Matrix: Pfad, dann die 25 Zeilen von core$tariff_years)
.wd_metrics <- function(sp, nfy, H, gamma, start_value)
  .Call(C_wd_metrics, sp, as.integer(nfy), H, as.numeric(gamma), as.numeric(start_value))
.wd_pwr <- function(AR, legacy, H = NULL) .Call(C_wd_pwr, AR, as.numeric(legacy), H)
.wd_annual_prod <- function(real, ppy) .Call(C_wd_annual_prod, real, as.integer(ppy))
.wd_tariff_compact <- function(M, ny) .Call(C_wd_tariff_compact, M, as.integer(ny))

# Pruefzugang zum Tarifkern (core/tariff_core_impl.h) fuer den Zufallsvergleich mit .tariff_income_tax,
# .tariff_soli und .tariff_close (Gleichlauf: tariff_fuzz.R); mode 1 ESt, 2 Soli, 3 Jahresabschluss
.wd_tariff_check <- function(par, x, mode) .Call(C_wd_tariff_check, as.numeric(par), x, as.integer(mode))
