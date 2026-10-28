# R-Huellen der C++-Kerne (src/*.cpp).
#
# Seit 0.5.0 ohne Rcpp: Die Kerne sind ueber R's C-Schnittstelle angebunden
# (src/simlev_capi.h, Registrierung in src/init.c). NAMESPACE laedt die
# Routinen mit useDynLib(SimLev, .registration = TRUE, .fixes = "C_"); jede
# registrierte Routine <name> steht in R als C_<name> bereit. Die Huellen
# entsprechen den frueheren, von Rcpp::compileAttributes() erzeugten
# (RcppExports.R): gleiche Argumente und Standardwerte, Funktionen ohne
# Rueckgabewert liefern unsichtbar NULL. Die Engine-Kerne aendern sim_mem bzw.
# die uebergebenen Listen an Ort und Stelle.
#
# Die Rechnung der Kerne steht in den geteilten Dateien *_impl.h, kanonisch in core/ (seit
# Etappe 9.6c, F16; Kopien in src/ ueber tools/core_sync.py). Die frueheren Bootstrap-, DCC-
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

# ── Engine: Tagesschritte (src/simulation_core.cpp) ──────────────────────────
# Alle aendern sim_mem (input) an Ort und Stelle; Aufruf ohne Zuweisung.

# DCA-Zufluss einem Asset zuordnen (flows, money, total)
.sim_dca_flows_cpp <- function(input, name, flows, index) {
  invisible(.Call(C_sim_dca_flows, input, name, flows, index))
}

# Report und Status nach einem Kauf
.sim_buy_report_cpp <- function(input, name, index, trade_count, trade_price, market_price) {
  invisible(.Call(C_sim_buy_report, input, name, index, trade_count, trade_price, market_price))
}

# Report und Status nach einem Verkauf
.sim_sell_report_cpp <- function(input, name, index, trade_count, trade_price, market_price,
                                 capital_gains_tax) {
  invisible(.Call(C_sim_sell_report, input, name, index, trade_count, trade_price, market_price,
                  capital_gains_tax))
}

# Gesamtreport aller Assets eines Tages (Kurse, Werte, Gewichte in "differ")
.sim_total_report_cpp <- function(input, assets, index) {
  invisible(.Call(C_sim_total_report, input, assets, index))
}

# Kauf: Report- und Status-Update, neuer FIFO-Lot, buy_count + 1
.sim_buy_cpp <- function(input, name, index, trade_count, trade_price, market_price) {
  invisible(.Call(C_sim_buy, input, name, index, trade_count, trade_price, market_price))
}

# Markt-Update fuer einen Tag (Fast Path)
.sim_market_update_cpp <- function(input, assets, index) {
  invisible(.Call(C_sim_market_update, input, assets, index))
}

# Markt-Update fuer einen Block zusammenhaengender Fast-Path-Tage
.sim_market_update_batch_cpp <- function(input, assets, start_idx, end_idx) {
  invisible(.Call(C_sim_market_update_batch, input, assets, start_idx, end_idx))
}

# ── Engine: FIFO (src/fifo_core.cpp) ────────────────────────────────────

# FIFO-gewichteter Einstandspreis (Port von .calculate_fifo_price)
.sim_fifo_price_cpp <- function(buys, units, front_index) {
  .Call(C_sim_fifo_price, buys, units, front_index)
}

# Anteilige Vorabpauschale fuer FIFO-Verkauf (Port von .calculate_fifo_vorabpauschale)
.sim_fifo_vp_cpp <- function(buys, units, front_index) {
  .Call(C_sim_fifo_vp, buys, units, front_index)
}

# § 23 EStG lot-weise (Port von .calculate_private_sale_tax); current_date als
# Integer (Tage seit 1970-01-01)
.sim_private_sale_tax_cpp <- function(buys, front_index, trade_count, sell_price, current_date) {
  .Call(C_sim_private_sale_tax, buys, front_index, trade_count, sell_price, current_date)
}

# FIFO-Verbrauch nach Verkauf (Port des Loops aus .perform_trade_sell); aendert
# remaining und vp der Lots und fifo_front an Ort und Stelle
.sim_fifo_consume_cpp <- function(input, name, trade_count) {
  invisible(.Call(C_sim_fifo_consume, input, name, trade_count))
}

# ── Engine: Steuern (src/tax_core.cpp) ──────────────────────────────────

# Vorabpauschale je Lot (Port des Kerns von .calculate_flat_rate); base_rate
# dezimal (> 0), Datumsargumente als Tage seit 1970-01-01
.sim_flat_rate_cpp <- function(buys, front_index, base_rate, year_start_price, market_price,
                               soy_days, eoy_days) {
  .Call(C_sim_flat_rate, buys, front_index, base_rate, year_start_price, market_price,
        soy_days, eoy_days)
}

# § 20-Steuerkern (Port von .calculate_paragraph_20_tax); aendert totals an Ort und Stelle
.sim_p20_tax_cpp <- function(trade_gain, bonus, totals, tax_rate, use_spb) {
  .Call(C_sim_p20_tax, trade_gain, bonus, totals, tax_rate, use_spb)
}

# Steuer auf die Vorabpauschale (Port von .calculate_vorabpauschale_tax, R-2);
# aendert totals an Ort und Stelle
.sim_vp_tax_cpp <- function(flat_rate, bonus, totals, tax_rate, use_spb) {
  .Call(C_sim_vp_tax, flat_rate, bonus, totals, tax_rate, use_spb)
}

# Verkaufsstueckzahl fuer einen Ziel-Nettoerloes (Port von .calculate_sell_count);
# regime: 0 = none, 1 = investment_fund, 2 = capital_gains, 3 = private_sale
.sim_sell_count_cpp <- function(buys, front_index, target, trade_price, total_shares, fractions,
                                regime, bonus, loss_pool, tax_rate) {
  .Call(C_sim_sell_count, buys, front_index, target, trade_price, total_shares, fractions,
        regime, bonus, loss_pool, tax_rate)
}

# ── Entnahme (src/withdrawal_core.cpp) ───────────────────────────────────────

# Schneller Entnahme-Kern ueber viele Pfade (withdrawal_simulation())
.wd_simulate <- function(R, INF, CAPE, BASE, ppy, rule, rp, start_timing, start_value, income_real,
                         tax_on, tax_rate, tfs, spb_annual, vp_on, cost, basis_ratio, loss0, keep,
                         lot_n = as.numeric(c()), lot_basis = as.numeric(c()),
                         lot_vp = as.numeric(c()), lot_group = as.integer(c()),
                         spb_first = -1.0, horizon_end = FALSE) {
  .Call(C_wd_simulate, R, INF, CAPE, BASE, ppy, rule, rp, start_timing, start_value, income_real,
        tax_on, tax_rate, tfs, spb_annual, vp_on, cost, basis_ratio, loss0, keep,
        lot_n, lot_basis, lot_vp, lot_group, spb_first, horizon_end)
}
