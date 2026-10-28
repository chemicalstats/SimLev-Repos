# Referenzfälle für simlev.signals und simlev._signals_core (r/R/signals.R, .roll_mean_core, .roll_cov_core).
source("golden/modules/ref_tools.R"); ref_init("signals")
P <- "from simlev import signals as SG\nfrom simlev import _signals_core as SC\n"
# ── Julia-Code je Fall (Feld jl; Eingaben als Variablen, siehe julia/test/reftree.jl) ──
J <- "const SG = SL.Signals; const SC = SL.SignalsCore\n"
JL <- list(
  core_mean = 'result = SC.roll_mean_core(x, 50)',
  core_mean_long = 'result = SC.roll_mean_core(x, 7)',
  core_mean_long2 = 'result = SC.roll_mean_core(x, 3000)',
  core_mean_na = 'result = SC.roll_mean_core(x, 20)',
  core_mean_inf = 'result = SC.roll_mean_core(x, 5)',
  core_mean_edge = 'result = [SC.roll_mean_core(collect(1.0:5.0), 5), SC.roll_mean_core(collect(1.0:5.0), 6), SC.roll_mean_core(collect(1.0:5.0), 0), SC.roll_mean_core([0.1, 0.2, 0.3], 1)]',
  core_cov = 'result = SC.roll_cov_core(x, reverse(x), 50)',
  core_cov_na = 'result = SC.roll_cov_core(x, sqrt.(x), 15)',
  core_cov_edge = 'result = [SC.roll_cov_core([1.0, 2, 3], [1.0, 2, 3, 4], 2), SC.roll_cov_core([1.0, 2, 3], [3.0, 2, 1], 3), SC.roll_cov_core([1.0, 2, 3], [3.0, 2, 1], 4)]',
  roll_mean = 'result = SG._roll_mean(x, 50)',
  roll_var = 'result = SG._roll_var(x, 50)',
  roll_var_int = 'result = SG._roll_var(collect(1:30), 7.9)',
  roll_cov = 'result = SG._roll_cov(x, y, 30)',
  ema_int = 'result = SG._ema(x, 10)',
  ema_edge = 'result = [SG._ema(collect(1.0:5.0), 5), SG._ema(collect(1.0:5.0), 6), SG._ema(collect(1.0:5.0), 0), SG._ema([1, NA, 3, 4, 5, 6], 2)]',
  sigout = 'result = SG._sig_out([true, missing, false, true], [missing, true, true, false], 2)',
  sma_small = 'result = SG.signal_sma(x, 3)',
  sma_band = 'result = SG.signal_sma(x, 3; band = 5)',
  sma_lag = 'result = SG.signal_sma(x, 3; lag = 1)',
  sma_px = 'result = SG.signal_sma(x, 200; band = 1, lag = 2)',
  sma_def = 'result = SG.signal_sma(x)',
  sma_na = 'result = SG.signal_sma(x, 20)',
  sma_long = 'result = SG.signal_sma(x, 20)',
  ema_small = 'result = SG.signal_ema(cumsum(ones(50)), 10)',
  ema_px = 'result = SG.signal_ema(x, 50; band = 0.5, lag = 3)',
  ema_def = 'result = SG.signal_ema(x)',
  ema_na = 'result = SG.signal_ema(x, 20)',
  cross_sma = 'result = SG.signal_crossover(x)',
  cross_ema = 'result = SG.signal_crossover(x, 20, 100; type = "ema", band = 0.3, lag = 1)',
  cross_e = 'result = SG.signal_crossover(x, 20, 100; type = "e")',
  cross_err = 'result = SG.signal_crossover(x, 100, 100)',
  cross_err2 = 'result = SG.signal_crossover(x, 10, 100; type = "wma")',
  mom_small = 'result = SG.signal_momentum(x, 2)',
  mom_px = 'result = SG.signal_momentum(x, 60; threshold = 2, band = 1, lag = 1)',
  mom_def = 'result = SG.signal_momentum(x)',
  mom_long = 'result = SG.signal_momentum(x, 10)',
  mom_na = 'result = SG.signal_momentum(x, 5.7)',
  dd_small = 'result = SG.signal_drawdown([100.0, 89, 79, 85, 95]; sell_dd = 20, buy_dd = 10)',
  dd_px = 'result = SG.signal_drawdown(x, 8, 3)',
  dd_win = 'result = SG.signal_drawdown(x, 6, 2; window = 60, lag = 2)',
  dd_na = 'result = SG.signal_drawdown(x, 8, 3)',
  dd_na2 = 'result = SG.signal_drawdown([NA, NA, 5, 4, NA, 3], 30, 10; window = 2)',
  dd_err = 'result = SG.signal_drawdown(x, 10, 20)',
  vol_def = 'result = SG.signal_volatility(x)',
  vol_opts = 'result = SG.signal_volatility(x, 30; threshold = 14, band = 1, ppy = 252, lag = 1)',
  vol_one = 'result = SG.signal_volatility(x, 1; threshold = 15)',
  vol_na = 'result = SG.signal_volatility(x, 10; threshold = 15)',
  vol_short = 'result = SG.signal_volatility(x, 20)',
  vol_test = 'result = SG.signal_volatility(x, 20; threshold = 1000)',
  comb_small = 'result = SG.signal_combine(RList("buy" => [true, true], "sell" => [false, false]), RList("buy" => [true, false], "sell" => [false, true]))',
  comb_and = 'result = SG.signal_combine(SG.signal_sma(x, 200), SG.signal_volatility(x, 20; threshold = 15), SG.signal_momentum(x, 100))',
  comb_or = 'result = SG.signal_combine(SG.signal_sma(x, 200), SG.signal_drawdown(x, 8, 3); op = "or")',
  comb_one = 'result = SG.signal_combine(SG.signal_sma(x, 50))',
  comb_err = 'result = SG.signal_combine(SG.signal_sma(x, 200), SG.signal_sma(x[1:500], 50))',
  comb_err0 = 'result = SG.signal_combine()',
  comb_err_op = 'result = SG.signal_combine(SG.signal_sma(x, 50); op = "xor")'
)
rc <- function(id, r, py, inputs = list(), ...) {
  if (is.null(JL[[id]])) stop("kein Julia-Code (jl) für Fall ", id)
  ref_case(id, r, paste0(P, py), inputs, jl = paste0(J, JL[[id]]), ...)
}

x10 <- c(10, 11, 12, 13, 12, 11, 10, 9, 10, 11)
set.seed(1); px <- 100 * cumprod(1 + rnorm(1000, 2e-4, 0.01))
set.seed(4); xc <- 1e4 + cumsum(rnorm(3000))
set.seed(7); xl <- 50 + cumsum(rnorm(9000, 0, 0.5)) + 1e3 * sin(1:9000 / 50)
xna <- px; xna[c(10, 300, 301, 700)] <- NA
xinf <- px[1:300]; xinf[c(50, 200)] <- c(Inf, NaN)

# ── Kerne ──────────────────────────────────────────────────────────────────
rc("core_mean", "SimLev:::.roll_mean_core(x, 50L)", "result = SC.roll_mean_core(x, 50)", list(x = xc))
rc("core_mean_long", "SimLev:::.roll_mean_core(x, 7L)", "result = SC.roll_mean_core(x, 7)", list(x = xl))
rc("core_mean_long2", "SimLev:::.roll_mean_core(x, 3000L)", "result = SC.roll_mean_core(x, 3000)", list(x = xl))
rc("core_mean_na", "SimLev:::.roll_mean_core(x, 20L)", "result = SC.roll_mean_core(x, 20)", list(x = xna))
rc("core_mean_inf", "SimLev:::.roll_mean_core(x, 5L)", "result = SC.roll_mean_core(x, 5)", list(x = xinf))
rc("core_mean_edge", "list(SimLev:::.roll_mean_core(1:5 + 0, 5L), SimLev:::.roll_mean_core(1:5 + 0, 6L), SimLev:::.roll_mean_core(1:5 + 0, 0L), SimLev:::.roll_mean_core(c(0.1, 0.2, 0.3), 1L))",
   "result = [SC.roll_mean_core(np.arange(1, 6.), 5), SC.roll_mean_core(np.arange(1, 6.), 6), SC.roll_mean_core(np.arange(1, 6.), 0), SC.roll_mean_core(np.array([0.1, 0.2, 0.3]), 1)]")
rc("core_cov", "SimLev:::.roll_cov_core(x, rev(x), 50L)", "result = SC.roll_cov_core(x, x[::-1], 50)", list(x = xc))
rc("core_cov_na", "SimLev:::.roll_cov_core(x, sqrt(x), 15L)", "with np.errstate(invalid='ignore'):\n    y = np.sqrt(x)\nresult = SC.roll_cov_core(x, y, 15)", list(x = xna))
rc("core_cov_edge", "list(SimLev:::.roll_cov_core(1:3 + 0, 1:4 + 0, 2L), SimLev:::.roll_cov_core(1:3 + 0, 3:1 + 0, 3L), SimLev:::.roll_cov_core(1:3 + 0, 3:1 + 0, 4L))",
   "result = [SC.roll_cov_core(np.arange(1, 4.), np.arange(1, 5.), 2), SC.roll_cov_core(np.arange(1, 4.), np.arange(3, 0, -1.), 3), SC.roll_cov_core(np.arange(1, 4.), np.arange(3, 0, -1.), 4)]")
rc("roll_mean", "SimLev:::.roll_mean(x, 50)", "result = SG._roll_mean(x, 50)", list(x = xc))
rc("roll_var", "SimLev:::.roll_var(x, 50)", "result = SG._roll_var(x, 50)", list(x = xc))
rc("roll_var_int", "SimLev:::.roll_var(1:30, 7.9)", "result = SG._roll_var(np.arange(1, 31), 7.9)")
rc("roll_cov", "SimLev:::.roll_cov(x, y, 30)", "result = SG._roll_cov(x, y, 30)", list(x = px, y = rev(px)))
rc("ema_int", "SimLev:::.ema(x, 10)", "result = SG._ema(x, 10)", list(x = px))
rc("ema_edge", "list(SimLev:::.ema(1:5 + 0, 5), SimLev:::.ema(1:5 + 0, 6), SimLev:::.ema(1:5 + 0, 0), SimLev:::.ema(c(1, NA, 3, 4, 5, 6), 2))",
   "result = [SG._ema(np.arange(1, 6.), 5), SG._ema(np.arange(1, 6.), 6), SG._ema(np.arange(1, 6.), 0), SG._ema(np.array([1, simlev._r.fmt.NA_REAL, 3, 4, 5, 6]), 2)]")
rc("sigout", "SimLev:::.sig_out(c(TRUE, NA, FALSE, TRUE), c(NA, TRUE, TRUE, FALSE), 2)",
   "result = SG._sig_out(np.array([True, None, False, True], dtype=object), np.array([None, True, True, False], dtype=object), 2)")

# ── Bausteine ──────────────────────────────────────────────────────────────
rc("sma_small", "signal_sma(x, 3)", "result = SG.signal_sma(x, n=3)", list(x = x10))
rc("sma_band", "signal_sma(x, 3, band = 5)", "result = SG.signal_sma(x, n=3, band=5)", list(x = x10))
rc("sma_lag", "signal_sma(x, 3, lag = 1)", "result = SG.signal_sma(x, n=3, lag=1)", list(x = x10))
rc("sma_px", "signal_sma(x, 200, band = 1, lag = 2)", "result = SG.signal_sma(x, n=200, band=1, lag=2)", list(x = px))
rc("sma_def", "signal_sma(x)", "result = SG.signal_sma(x)", list(x = px))
rc("sma_na", "signal_sma(x, 20)", "result = SG.signal_sma(x, n=20)", list(x = xna))
rc("sma_long", "signal_sma(x, 20)", "result = SG.signal_sma(x, n=20)", list(x = x10))
rc("ema_small", "signal_ema(cumsum(rep(1, 50)), 10)", "result = SG.signal_ema(np.cumsum(np.ones(50)), n=10)")
rc("ema_px", "signal_ema(x, 50, band = 0.5, lag = 3)", "result = SG.signal_ema(x, n=50, band=0.5, lag=3)", list(x = px))
rc("ema_def", "signal_ema(x)", "result = SG.signal_ema(x)", list(x = px))
rc("ema_na", "signal_ema(x, 20)", "result = SG.signal_ema(x, n=20)", list(x = xna))
rc("cross_sma", "signal_crossover(x)", "result = SG.signal_crossover(x)", list(x = px))
rc("cross_ema", "signal_crossover(x, 20, 100, type = 'ema', band = 0.3, lag = 1)", "result = SG.signal_crossover(x, fast=20, slow=100, type='ema', band=0.3, lag=1)", list(x = px))
rc("cross_e", "signal_crossover(x, 20, 100, type = 'e')", "result = SG.signal_crossover(x, fast=20, slow=100, type='e')", list(x = px))
rc("cross_err", "signal_crossover(x, 100, 100)", "result = SG.signal_crossover(x, fast=100, slow=100)", list(x = px))
rc("cross_err2", "signal_crossover(x, 10, 100, type = 'wma')", "result = SG.signal_crossover(x, fast=10, slow=100, type='wma')", list(x = px))
rc("mom_small", "signal_momentum(x, 2)", "result = SG.signal_momentum(x, n=2)", list(x = x10))
rc("mom_px", "signal_momentum(x, 60, threshold = 2, band = 1, lag = 1)", "result = SG.signal_momentum(x, n=60, threshold=2, band=1, lag=1)", list(x = px))
rc("mom_def", "signal_momentum(x)", "result = SG.signal_momentum(x)", list(x = px))
rc("mom_long", "signal_momentum(x, 10)", "result = SG.signal_momentum(x, n=10)", list(x = x10))
rc("mom_na", "signal_momentum(x, 5.7)", "result = SG.signal_momentum(x, n=5.7)", list(x = xna))
rc("dd_small", "signal_drawdown(c(100, 89, 79, 85, 95), sell_dd = 20, buy_dd = 10)", "result = SG.signal_drawdown(np.array([100., 89, 79, 85, 95]), sell_dd=20, buy_dd=10)")
rc("dd_px", "signal_drawdown(x, 8, 3)", "result = SG.signal_drawdown(x, sell_dd=8, buy_dd=3)", list(x = px))
rc("dd_win", "signal_drawdown(x, 6, 2, window = 60, lag = 2)", "result = SG.signal_drawdown(x, sell_dd=6, buy_dd=2, window=60, lag=2)", list(x = px))
rc("dd_na", "signal_drawdown(x, 8, 3)", "result = SG.signal_drawdown(x, sell_dd=8, buy_dd=3)", list(x = xna))
rc("dd_na2", "signal_drawdown(c(NA, NA, 5, 4, NA, 3), 30, 10, window = 2)", "result = SG.signal_drawdown(np.array([simlev._r.fmt.NA_REAL, simlev._r.fmt.NA_REAL, 5, 4, simlev._r.fmt.NA_REAL, 3]), sell_dd=30, buy_dd=10, window=2)")
rc("dd_err", "signal_drawdown(x, 10, 20)", "result = SG.signal_drawdown(x, sell_dd=10, buy_dd=20)", list(x = px))
rc("vol_def", "signal_volatility(x)", "result = SG.signal_volatility(x)", list(x = px))
rc("vol_opts", "signal_volatility(x, 30, threshold = 14, band = 1, ppy = 252, lag = 1)", "result = SG.signal_volatility(x, n=30, threshold=14, band=1, ppy=252, lag=1)", list(x = px))
rc("vol_one", "signal_volatility(x, 1, threshold = 15)", "result = SG.signal_volatility(x, n=1, threshold=15)", list(x = px[1:50]))
rc("vol_na", "signal_volatility(x, 10, threshold = 15)", "result = SG.signal_volatility(x, n=10, threshold=15)", list(x = xna))
rc("vol_short", "signal_volatility(x, 20)", "result = SG.signal_volatility(x, n=20)", list(x = x10))
set.seed(2); xv <- 100 * cumprod(1 + rnorm(300, 0, 0.01))
rc("vol_test", "signal_volatility(x, 20, threshold = 1000)", "result = SG.signal_volatility(x, n=20, threshold=1000)", list(x = xv))
rc("comb_small", "signal_combine(list(buy = c(TRUE, TRUE), sell = c(FALSE, FALSE)), list(buy = c(TRUE, FALSE), sell = c(FALSE, TRUE)))",
   "result = SG.signal_combine(dict(buy=np.array([True, True]), sell=np.array([False, False])), dict(buy=np.array([True, False]), sell=np.array([False, True])))")
rc("comb_and", "signal_combine(signal_sma(x, 200), signal_volatility(x, 20, threshold = 15), signal_momentum(x, 100))",
   "result = SG.signal_combine(SG.signal_sma(x, n=200), SG.signal_volatility(x, n=20, threshold=15), SG.signal_momentum(x, n=100))", list(x = px))
rc("comb_or", "signal_combine(signal_sma(x, 200), signal_drawdown(x, 8, 3), op = 'or')",
   "result = SG.signal_combine(SG.signal_sma(x, n=200), SG.signal_drawdown(x, sell_dd=8, buy_dd=3), op='or')", list(x = px))
rc("comb_one", "signal_combine(signal_sma(x, 50))", "result = SG.signal_combine(SG.signal_sma(x, n=50))", list(x = px))
rc("comb_err", "signal_combine(signal_sma(x, 200), signal_sma(x[1:500], 50))", "result = SG.signal_combine(SG.signal_sma(x, n=200), SG.signal_sma(x[:500], n=50))", list(x = px))
rc("comb_err0", "signal_combine()", "result = SG.signal_combine()")
rc("comb_err_op", "signal_combine(signal_sma(x, 50), op = 'xor')", "result = SG.signal_combine(SG.signal_sma(x, n=50), op='xor')", list(x = px))
ref_done()
