# R-Huellen der C++-Kerne (src/*.cpp).
#
# Seit 0.5.0 ohne Rcpp: Die Kerne sind ueber R's C-Schnittstelle angebunden
# (src/simlev_capi.h, Registrierung in src/init.c). NAMESPACE laedt die
# Routinen mit useDynLib(SimLev, .registration = TRUE, .fixes = "C_"); jede
# registrierte Routine <name> steht in R als C_<name> bereit. Die Huellen
# entsprechen den frueheren, von Rcpp::compileAttributes() erzeugten
# (RcppExports.R): gleiche Argumente und Standardwerte, Funktionen ohne
# Rueckgabewert liefern unsichtbar NULL.
#
# Die Rechnung der Kerne steht in den geteilten Dateien *_impl.h, kanonisch in core/ (seit
# Etappe 9.6c, F16; Kopien in src/ ueber core/sync.py). Die frueheren Bootstrap-, DCC-
# und MS-GARCH-Kerne (bootstrap_core.cpp, dependence_core.cpp, ms_garch.c) und
# die C-Uebernahmen (vendor_*) sind mit Etappe 9.6c entfallen; ihre Aufgaben rechnet die
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

.hmm_forward_backward <- function(B, A, p0) {
  .Call(C_hmm_forward_backward, B, A, p0)
}

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
# tax_core mit ihren Huellen sind mit E17 Stufe 1c entfallen.

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
  if (!length(tariff_par)) r$tariff_years <- NULL   # T14: Jahreszeilen nur mit Tarifweg (sonst Liste wie bisher)
  r
}

# T14: Pruefzugang zum Tarifkern (core/tariff_core_impl.h) fuer den Zufallsvergleich mit .tariff_income_tax,
# .tariff_soli und .tariff_close (Gleichlauf: tariff_fuzz.R); mode 1 ESt, 2 Soli, 3 Jahresabschluss
.wd_tariff_check <- function(par, x, mode) .Call(C_wd_tariff_check, as.numeric(par), x, as.integer(mode))
