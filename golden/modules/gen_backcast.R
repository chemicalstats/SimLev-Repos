# Referenzfälle für simlev.backcast (r/R/backcast.R).
source("golden/modules/ref_tools.R"); ref_init("backcast")
P <- "from simlev import backcast as BC\n"
# ── Julia-Code je Fall (Feld jl; Eingaben als Variablen, siehe julia/test/reftree.jl) ──
J <- "const BC = SL.Backcast\n"
TERJ <- 'named("2005-01-01" => 0.35, "2006-06-01" => 0.6)'
FITJ <- function(args) sprintf('result = BC.backcast_fit(s, "etf", "idx"; %s)', args)
F2J <- sprintf('f = BC.backcast_fit(s, "etf", "idx"; ter = %s, leverage = 2, rate = "rate")\n', TERJ)
ATTRJ <- 'result = RList("bc" => bc, "params" => attrs(bc)["params"], "splice" => attrs(bc)["splice_date"])'
JL <- list(
  rs_scalar = 'result = BC._resolve_series(0.3, d, "ter")',
  rs_null = 'result = BC._resolve_series(nothing, d, "ter"; default = 2)',
  rs_col = 'result = BC._resolve_series("t2", d, "ter")',
  rs_named = 'result = BC._resolve_series(named("2020-01-01" => 0.2, "2020-01-05" => 0.4), d, "ter")',
  rs_named2 = 'result = BC._resolve_series(named("2020/01/09" => 0.2, "2020/01/03" => 0.4), d, "ter")',
  rs_df = 'result = BC._resolve_series(RFrame("date" => [Date(2020, 1, 3)], "ter" => [0.7]), d, "ter")',
  rs_df2 = 'result = BC._resolve_series(RFrame("tag" => ["2020-01-08", "2020-01-02"], "wert" => [1.0, 2.0], "x" => [3.0, 3.0]), d, "ter")',
  rs_vec = 'result = BC._resolve_series(collect(1:10), d, "ter")',
  rs_namednodate = 'result = BC._resolve_series(named("a" => 1.0), d, "ter")',
  rs_err_col = 'result = BC._resolve_series("nope", d, "ter")',
  rs_err_len = 'result = BC._resolve_series(collect(1:3), d, "ter")',
  rs_err_df = 'result = BC._resolve_series(RFrame("date" => d.date), d, "ter")',
  rs_err_chr = 'result = BC._resolve_series(["a", "b"], d, "ter")',
  fill_def = 'result = [BC._fill_na(v), BC._fill_na([NA, NA]), BC._fill_na([1.0, 2, 3], "linear"), BC._fill_na([1, NA, 1 / 3], "linear")]',
  fill_lin_big = 'result = BC._fill_na(v, "linear")',
  fill_err = 'result = BC._fill_na(v, "spline")',
  shift = 'result = [BC._shift([1.0, 2, 3, 4, 5], 2), BC._shift([1.0, 2, 3, 4, 5], -1), BC._shift([1.0, 2, 3, 4, 5], 0)]',
  step = 'result = BC._step_series(Date.(["2020-01-05", "2020-01-02", "2020-01-05"]), [1.0, 2, 3], d.date)',
  bf_basic = FITJ(sprintf('ter = %s, leverage = 2, rate = "rate"', TERJ)),
  bf_grid = FITJ(sprintf('ter = %s, leverage = 2, rate = "rate", method = "grid", grid = min.(-1 .+ collect(0:200) .* 0.01, 1.0)', TERJ)),
  bf_grid_def = FITJ('ter = 0.5, leverage = 2, rate = "rate", method = "grid", objective = "return", validate = false'),
  bf_grid_spread = FITJ('ter = 0.5, leverage = 2, rate = "rate", method = "grid", fit = "spread", grid = [0.5, -0.2, 0, 0.1], loss = "max"'),
  bf_hybrid = FITJ(sprintf('ter = %s, leverage = 2, rate = "rate", fit = ["drag", "beta"], objective = "hybrid"', TERJ)),
  bf_three = FITJ('ter = 0.5, leverage = 2, rate = "rate", fit = ["beta", "spread", "drag"], hybrid_weight = 0.2, objective = "hyb"'),
  bf_return = FITJ('ter = 0.5, leverage = 2, rate = "rate", objective = "return", horizon = 5, loss = "mae", fit = ["drag", "drag"]'),
  bf_nofit = FITJ('ter = 0.5, leverage = 2, rate = "rate", fit = String[], fixed = RList("drag" => 0.3, "beta" => 1.01)'),
  bf_fixed = FITJ('ter = 0.5, leverage = 2, rate = "rate", fixed = RList("spread" => 0.4), start = "2006-08-01", end_ = Date(2006, 12, 31)'),
  bf_bounds = FITJ('ter = 0.6, leverage = 2, rate = 2, fit = ["drag", "spread"], bounds = RList("drag" => [-5.0, 5.0]), validate = false'),
  bf_bounds1 = FITJ('ter = 0.6, leverage = 2, rate = 2, fit = "spread", bounds = RList("spread" => [-1.0, 1.0])'),
  bf_geom = FITJ('ter = 0.5, leverage = 2, rate = "rate", accrual = "geometric", ter_basis = 360, rate_basis = 365, lag = 1, rate_lag = 2'),
  bf_lagauto = FITJ('ter = 0.5, leverage = 2, rate = "rate", lag = "auto"'),
  bf_short = 'result = BC.backcast_fit(s, "etf", "idx"; ter = 0.5, leverage = -1, rate = "rate", lag = "auto", fit = ["drag", "spread"])',
  bf_linear = 'result = BC.backcast_fit(s, "etf", "idx"; ter = 0.2, model = "linear")',
  bf_linear_w = 'result = BC.backcast_fit(s, "etf", "idx"; model = "linear", fit = ["drag", "beta", "spread"], fx = "fx", index_fill = "linear")',
  bf_spline = 'result = BC.backcast_fit(s, "etf", "idx"; model = "spline", fx = "fx", objective = "return")\ndelete!(result, "regression")',
  bf_stine = 'result = BC.backcast_fit(s, "etf", "idx"; index_fill = "stine", validate = false)',
  bf_fxvec = 'result = BC.backcast_fit(s, "etf", "idx"; fx = s.fx, rate = RFrame("date" => [Date(2005, 1, 1)], "r" => [3.0]), leverage = 1.5, fit = ["spread", "drag"], method = "optimize")',
  bf_chrdate = 's.date = string.(s.date)\nresult = BC.backcast_fit(rows(s, s.date .>= "2006-04-01"), "etf", "idx"; ter = 0.5, leverage = 2, rate = "rate", fit = "beta")',
  bf_summary = 'f = BC.backcast_fit(s, "etf", "idx"; ter = 0.5, leverage = 2, rate = "rate")\nresult = BC.summary_SimLevBackcastFit(f)',
  bf_err_col = 'result = BC.backcast_fit(s, "etf", "missing")',
  bf_err_lev = 'result = BC.backcast_fit(s, "etf", "idx"; leverage = 0)',
  bf_err_few = 's.etf = fill(NA, nrow(s))\nresult = BC.backcast_fit(s, "etf", "idx")',
  bf_warn_spread = 'result = BC.backcast_fit(s, "etf", "idx"; ter = 0.5, fit = ["drag", "spread"], validate = false)',
  bf_err_bounds = 'result = BC.backcast_fit(s, "etf", "idx"; bounds = RList("drag" => [5.0, -5.0]))',
  bf_err_bounds2 = 'result = BC.backcast_fit(s, "etf", "idx"; bounds = RList("alpha" => [0.0, 1.0]))',
  bf_err_bounds3 = 'result = BC.backcast_fit(s, "etf", "idx"; bounds = RList("beta" => [0.5, NA]))',
  bf_err_fit = 'result = BC.backcast_fit(s, "etf", "idx"; fit = "alpha")',
  bf_err_grid2 = 'result = BC.backcast_fit(s, "etf", "idx"; leverage = 2, fit = ["drag", "beta"], method = "grid")',
  bf_err_sort = 'result = BC.backcast_fit(rows(s, vcat([2, 1], 3:20)), "etf", "idx")',
  bf_err_dup = 'result = BC.backcast_fit(rows(s, vcat([1], 1:20)), "etf", "idx")',
  bf_err_na = 'dd = Vector{Union{Missing,Date}}(s.date); dd[5] = missing; s.date = dd\nresult = BC.backcast_fit(s, "etf", "idx")',
  bf_err_nodate = 'result = BC.backcast_fit(RFrame(names(s)[2:end], [s[k] for k in names(s)[2:end]]), "etf", "idx")',
  bf_err_df = 'result = BC.backcast_fit(collect(1:3), "etf", "idx")',
  bf_err_idx = 's.idx[10] = -1\nresult = BC.backcast_fit(s, "etf", "idx")',
  bf_err_model = 'result = BC.backcast_fit(s, "etf", "idx"; model = "gam")',
  bc_fit = paste0(F2J, 'result = BC.backcast(f)'),
  bc_fit_attr = paste0(F2J, 'bc = BC.backcast(f; params = RList("drag" => 0.5), fill = "linear", rebase = 100)\n', ATTRJ),
  bc_model = paste0(F2J, 'result = BC.backcast(f; fill = "model")'),
  bc_stine = paste0(F2J, 'result = BC.backcast(f; fill = "stine", splice = "2006-08-15")'),
  bc_none = paste0(F2J, 'bc = BC.backcast(f; splice = "none")\n', ATTRJ),
  bc_none_print = paste0(F2J, 'result = BC.backcast(f; splice = "none")'),
  bc_otherdata = paste0(F2J, 's2 = rows(s, 1:1000); s2.etf[990:1000] .= NA\nresult = BC.backcast(f; data = s2, fill = "model")'),
  bc_linear = 'f = BC.backcast_fit(s, "etf", "idx"; ter = 0.2, model = "linear")\nresult = BC.backcast(f; rebase = 100)',
  bc_spline = 'f = BC.backcast_fit(s, "etf", "idx"; model = "spline", fx = "fx", validate = false)\nresult = BC.backcast(f)',
  bc_nofit = sprintf('result = BC.backcast(nothing; data = s, product = "etf", index = "idx", ter = %s, leverage = 2, rate = "rate", params = RList("drag" => 0.4), fill = "model")', TERJ),
  bc_nofit_attr = paste0('bc = BC.backcast(; data = s, product = "etf", index = "idx", leverage = 2, rate = 2, ter = 0.6, splice = "2006-01-01", lag = 1, accrual = "geometric", unknown = 5)\n', ATTRJ),
  bc_noprod = 's.etf = fill(NA, nrow(s))\nresult = BC.backcast(; data = s, product = "etf", index = "idx", fx = "fx", index_fill = "linear")',
  bc_lead = 's.idx[1:5] .= NA\nresult = BC.backcast(; data = s, product = "etf", index = "idx", rebase = 1)',
  bc_err_splice = 'result = BC.backcast(; data = s, product = "etf", index = "idx", leverage = 2, rate = 2, ter = 0.6, splice = "2030-01-01")',
  bc_err_splice2 = 'result = BC.backcast(; data = s, product = "etf", index = "idx", splice = "gestern")',
  bc_err_splice3 = 'result = BC.backcast(; data = s, product = "etf", index = "idx", splice = missing)',
  bc_err_data = 'result = BC.backcast()',
  bc_err_prod = 'result = BC.backcast(; data = s, index = "idx")',
  bc_err_model = 'result = BC.backcast(; data = s, product = "etf", index = "idx", model = "linear")',
  bc_err_fit = 'result = BC.backcast(RList("a" => 1))',
  bc_err_fill = 'result = BC.backcast(; data = s, product = "etf", index = "idx", fill = "x")'
)
for (m in c("locf", "linear", "stine", "none")) for (kl in c(FALSE, TRUE))
  JL[[sprintf("fill_%s_%d", m, kl)]] <- sprintf('result = BC._fill_na(v, "%s"; keep_leading = %s)', m, tolower(kl))
for (ls in c("mse", "mae", "median", "max"))
  JL[[paste0("bf_loss_", ls)]] <- FITJ(sprintf('ter = 0.5, leverage = 2, rate = "rate", loss = "%s", validate = false', ls))
rc <- function(id, r, py, inputs = list(), ...) {
  if (is.null(JL[[id]])) stop("kein Julia-Code (jl) für Fall ", id)
  ref_case(id, r, paste0(P, py), inputs, jl = paste0(J, JL[[id]]), ...)
}

make_bc_data <- function(n = 1200, drag = 0.4, lev = 2, seed = 1, weekends = TRUE, from = "2005-01-01") {
  set.seed(seed)
  d <- seq.Date(as.Date(from), by = "day", length.out = n)
  idx <- 100 * cumprod(1 + c(0, rnorm(n - 1, 3e-4, 0.01)))
  rate <- 2 + sin(seq_len(n) / 400)
  ter <- ifelse(d >= as.Date("2006-06-01"), 0.6, 0.35)
  x <- c(0, diff(idx) / head(idx, -1))
  r <- lev * x + (1 - lev) * rate / 100 / 360 - ter / 100 / 365 - drag / 100 / 365
  r[1] <- 0
  truth <- 50 * cumprod(1 + r)
  etf <- truth
  etf[seq_len(n / 2)] <- NA
  if (weekends) etf[as.POSIXlt(d)$wday %in% c(0, 6)] <- NA
  data.frame(date = d, etf = etf, idx = idx, rate = rate)
}
TER <- "c('2005-01-01' = 0.35, '2006-06-01' = 0.6)"
TERP <- "pd.Series([0.35, 0.6], index=['2005-01-01', '2006-06-01'])"
s2 <- make_bc_data()
s1 <- make_bc_data(lev = 1, drag = 0.1, weekends = FALSE, seed = 2)
sm <- make_bc_data(lev = -1, drag = 0.2, seed = 3)
set.seed(5); sp <- make_bc_data(lev = 1, drag = 0, weekends = TRUE, seed = 5)
sp$etf <- sp$etf * exp(c(0, cumsum(rnorm(nrow(sp) - 1, 0, 0.002))))   # Proxy mit Rauschen
sp$idx[c(3, 4, 700, 701, 702)] <- NA
sp$fx <- 1 + 0.1 * sin(seq_len(nrow(sp)) / 100)

# ── Interne Helfer ─────────────────────────────────────────────────────────
dt10 <- data.frame(date = as.Date("2020-01-01") + 0:9, ter = rep(0.5, 10), t2 = c(NA, 1, NA, NA, 2, 3, NA, 4, NA, NA))
rc("rs_scalar", "SimLev:::.resolve_series(0.3, d, 'ter')", "result = BC._resolve_series(0.3, d, 'ter')", list(d = dt10))
rc("rs_null", "SimLev:::.resolve_series(NULL, d, 'ter', default = 2)", "result = BC._resolve_series(None, d, 'ter', default=2)", list(d = dt10))
rc("rs_col", "SimLev:::.resolve_series('t2', d, 'ter')", "result = BC._resolve_series('t2', d, 'ter')", list(d = dt10))
rc("rs_named", "SimLev:::.resolve_series(c('2020-01-01' = 0.2, '2020-01-05' = 0.4), d, 'ter')",
   "result = BC._resolve_series(pd.Series([0.2, 0.4], index=['2020-01-01', '2020-01-05']), d, 'ter')", list(d = dt10))
rc("rs_named2", "SimLev:::.resolve_series(c('2020/01/09' = 0.2, '2020/01/03' = 0.4), d, 'ter')",
   "result = BC._resolve_series({'2020/01/09': 0.2, '2020/01/03': 0.4}, d, 'ter')", list(d = dt10))
rc("rs_df", "SimLev:::.resolve_series(data.frame(date = as.Date(c('2020-01-03')), ter = 0.7), d, 'ter')",
   "result = BC._resolve_series(pd.DataFrame(dict(date=np.array(['2020-01-03'], dtype='datetime64[D]'), ter=[0.7])), d, 'ter')", list(d = dt10))
rc("rs_df2", "SimLev:::.resolve_series(data.frame(tag = c('2020-01-08', '2020-01-02'), wert = c(1, 2), x = 3), d, 'ter')",
   "result = BC._resolve_series(pd.DataFrame(dict(tag=['2020-01-08', '2020-01-02'], wert=[1., 2], x=3.)), d, 'ter')", list(d = dt10))
rc("rs_vec", "SimLev:::.resolve_series(1:10, d, 'ter')", "result = BC._resolve_series(np.arange(1, 11), d, 'ter')", list(d = dt10))
rc("rs_namednodate", "SimLev:::.resolve_series(c(a = 1), d, 'ter')", "result = BC._resolve_series(pd.Series([1.], index=['a']), d, 'ter')", list(d = dt10))
rc("rs_err_col", "SimLev:::.resolve_series('nope', d, 'ter')", "result = BC._resolve_series('nope', d, 'ter')", list(d = dt10))
rc("rs_err_len", "SimLev:::.resolve_series(1:3, d, 'ter')", "result = BC._resolve_series(np.arange(1, 4), d, 'ter')", list(d = dt10))
rc("rs_err_df", "SimLev:::.resolve_series(data.frame(date = d$date), d, 'ter')", "result = BC._resolve_series(pd.DataFrame(dict(date=d['date'])), d, 'ter')", list(d = dt10))
rc("rs_err_chr", "SimLev:::.resolve_series(c('a', 'b'), d, 'ter')", "result = BC._resolve_series(np.array(['a', 'b'], dtype=object), d, 'ter')", list(d = dt10))
vna <- c(NA, NA, 1, NA, NA, 4, 5, NA, 2, NA)
for (m in c("locf", "linear", "stine", "none")) for (kl in c(FALSE, TRUE))
  rc(sprintf("fill_%s_%d", m, kl), sprintf("SimLev:::.fill_na(v, '%s', keep_leading = %s)", m, kl),
     sprintf("result = BC._fill_na(v, '%s', keep_leading=%s)", m, if (kl) "True" else "False"), list(v = vna))
rc("fill_def", "list(SimLev:::.fill_na(v), SimLev:::.fill_na(c(NA, NA)), SimLev:::.fill_na(1:3 + 0, 'linear'), SimLev:::.fill_na(c(1, NA, 1/3), 'linear'))",
   "result = [BC._fill_na(v), BC._fill_na(np.array([simlev._r.fmt.NA_REAL, simlev._r.fmt.NA_REAL])), BC._fill_na(np.arange(1, 4.), 'linear'), BC._fill_na(np.array([1, simlev._r.fmt.NA_REAL, 1/3]), 'linear')]", list(v = vna))
set.seed(3); vlin <- cumsum(rnorm(500)); vlin[sample(500, 200)] <- NA
rc("fill_lin_big", "SimLev:::.fill_na(v, 'linear')", "result = BC._fill_na(v, 'linear')", list(v = vlin))
rc("fill_err", "SimLev:::.fill_na(v, 'spline')", "result = BC._fill_na(v, 'spline')", list(v = vna))
rc("shift", "list(SimLev:::.shift(1:5 + 0, 2L), SimLev:::.shift(1:5 + 0, -1L), SimLev:::.shift(1:5 + 0, 0L))",
   "result = [BC._shift(np.arange(1, 6.), 2), BC._shift(np.arange(1, 6.), -1), BC._shift(np.arange(1, 6.), 0)]")
rc("step", "SimLev:::.step_series(as.Date(c('2020-01-05', '2020-01-02', '2020-01-05')), c(1, 2, 3), d$date)",
   "result = BC._step_series(np.array(['2020-01-05', '2020-01-02', '2020-01-05'], dtype='datetime64[D]'), [1., 2, 3], d['date'])", list(d = dt10))

# ── backcast_fit ───────────────────────────────────────────────────────────
FIT <- function(args) sprintf("backcast_fit(s, 'etf', 'idx', %s)", args)
FITP <- function(args) sprintf("result = BC.backcast_fit(s, 'etf', 'idx', %s)", args)
rc("bf_basic", FIT(sprintf("ter = %s, leverage = 2, rate = 'rate'", TER)), FITP(sprintf("ter=%s, leverage=2, rate='rate'", TERP)), list(s = s2))
rc("bf_grid", FIT(sprintf("ter = %s, leverage = 2, rate = 'rate', method = 'grid', grid = seq(-1, 1, by = 0.01)", TER)),
   FITP(sprintf("ter=%s, leverage=2, rate='rate', method='grid', grid=np.minimum(-1 + np.arange(201) * 0.01, 1)", TERP)), list(s = s2))
rc("bf_grid_def", FIT("ter = 0.5, leverage = 2, rate = 'rate', method = 'grid', objective = 'return', validate = FALSE"),
   FITP("ter=0.5, leverage=2, rate='rate', method='grid', objective='return', validate=False"), list(s = s2))
rc("bf_grid_spread", FIT("ter = 0.5, leverage = 2, rate = 'rate', method = 'grid', fit = 'spread', grid = c(0.5, -0.2, 0, 0.1), loss = 'max'"),
   FITP("ter=0.5, leverage=2, rate='rate', method='grid', fit='spread', grid=[0.5, -0.2, 0, 0.1], loss='max'"), list(s = s2))
rc("bf_hybrid", FIT(sprintf("ter = %s, leverage = 2, rate = 'rate', fit = c('drag', 'beta'), objective = 'hybrid'", TER)),
   FITP(sprintf("ter=%s, leverage=2, rate='rate', fit=['drag', 'beta'], objective='hybrid'", TERP)), list(s = s2))
rc("bf_three", FIT("ter = 0.5, leverage = 2, rate = 'rate', fit = c('beta', 'spread', 'drag'), hybrid_weight = 0.2, objective = 'hyb'"),
   FITP("ter=0.5, leverage=2, rate='rate', fit=['beta', 'spread', 'drag'], hybrid_weight=0.2, objective='hyb'"), list(s = s2))
for (ls in c("mse", "mae", "median", "max"))
  rc(paste0("bf_loss_", ls), FIT(sprintf("ter = 0.5, leverage = 2, rate = 'rate', loss = '%s', validate = FALSE", ls)),
     FITP(sprintf("ter=0.5, leverage=2, rate='rate', loss='%s', validate=False", ls)), list(s = s2))
rc("bf_return", FIT("ter = 0.5, leverage = 2, rate = 'rate', objective = 'return', horizon = 5, loss = 'mae', fit = c('drag', 'drag')"),
   FITP("ter=0.5, leverage=2, rate='rate', objective='return', horizon=5, loss='mae', fit=['drag', 'drag']"), list(s = s2))
rc("bf_nofit", FIT("ter = 0.5, leverage = 2, rate = 'rate', fit = character(0), fixed = list(drag = 0.3, beta = 1.01)"),
   FITP("ter=0.5, leverage=2, rate='rate', fit=[], fixed={'drag': 0.3, 'beta': 1.01}"), list(s = s2))
rc("bf_fixed", FIT("ter = 0.5, leverage = 2, rate = 'rate', fixed = list(spread = 0.4), start = '2006-08-01', end = as.Date('2006-12-31')"),
   FITP("ter=0.5, leverage=2, rate='rate', fixed={'spread': 0.4}, start='2006-08-01', end=np.datetime64('2006-12-31')"), list(s = s2))
rc("bf_bounds", FIT("ter = 0.6, leverage = 2, rate = 2, fit = c('drag', 'spread'), bounds = list(drag = c(-5, 5)), validate = FALSE"),
   FITP("ter=0.6, leverage=2, rate=2, fit=['drag', 'spread'], bounds={'drag': [-5, 5]}, validate=False"), list(s = s2))
rc("bf_bounds1", FIT("ter = 0.6, leverage = 2, rate = 2, fit = 'spread', bounds = list(spread = c(-1, 1))"),
   FITP("ter=0.6, leverage=2, rate=2, fit='spread', bounds={'spread': [-1, 1]}"), list(s = s2))
rc("bf_geom", FIT("ter = 0.5, leverage = 2, rate = 'rate', accrual = 'geometric', ter_basis = 360, rate_basis = 365, lag = 1, rate_lag = 2"),
   FITP("ter=0.5, leverage=2, rate='rate', accrual='geometric', ter_basis=360, rate_basis=365, lag=1, rate_lag=2"), list(s = s2))
rc("bf_lagauto", FIT("ter = 0.5, leverage = 2, rate = 'rate', lag = 'auto'"), FITP("ter=0.5, leverage=2, rate='rate', lag='auto'"), list(s = s2))
rc("bf_short", "backcast_fit(s, 'etf', 'idx', ter = 0.5, leverage = -1, rate = 'rate', lag = 'auto', fit = c('drag', 'spread'))",
   "result = BC.backcast_fit(s, 'etf', 'idx', ter=0.5, leverage=-1, rate='rate', lag='auto', fit=['drag', 'spread'])", list(s = sm))
rc("bf_linear", "backcast_fit(s, 'etf', 'idx', ter = 0.2, model = 'linear')", "result = BC.backcast_fit(s, 'etf', 'idx', ter=0.2, model='linear')", list(s = s1))
rc("bf_linear_w", "backcast_fit(s, 'etf', 'idx', model = 'linear', fit = c('drag', 'beta', 'spread'), fx = 'fx', index_fill = 'linear')",
   "result = BC.backcast_fit(s, 'etf', 'idx', model='linear', fit=['drag', 'beta', 'spread'], fx='fx', index_fill='linear')", list(s = sp))
rc("bf_spline", "f <- backcast_fit(s, 'etf', 'idx', model = 'spline', fx = 'fx', objective = 'return'); f$regression <- NULL; f",
   "result = BC.backcast_fit(s, 'etf', 'idx', model='spline', fx='fx', objective='return'); result['regression'] = None", list(s = sp))
rc("bf_stine", "backcast_fit(s, 'etf', 'idx', index_fill = 'stine', validate = FALSE)", "result = BC.backcast_fit(s, 'etf', 'idx', index_fill='stine', validate=False)", list(s = sp))
rc("bf_fxvec", "backcast_fit(s, 'etf', 'idx', fx = s$fx, rate = data.frame(date = as.Date('2005-01-01'), r = 3), leverage = 1.5, fit = c('spread', 'drag'), method = 'optimize')",
   "result = BC.backcast_fit(s, 'etf', 'idx', fx=s['fx'].to_numpy(), rate=pd.DataFrame(dict(date=np.array(['2005-01-01'], dtype='datetime64[D]'), r=[3.])), leverage=1.5, fit=['spread', 'drag'], method='optimize')",
   list(s = sp))
rc("bf_chrdate", "s$date <- format(s$date); backcast_fit(s[s$date >= '2006-04-01', ], 'etf', 'idx', ter = 0.5, leverage = 2, rate = 'rate', fit = 'beta')",
   "s['date'] = [str(x)[:10] for x in s['date']]\nresult = BC.backcast_fit(s[s['date'] >= '2006-04-01'], 'etf', 'idx', ter=0.5, leverage=2, rate='rate', fit='beta')", list(s = s2))
rc("bf_summary", "f <- backcast_fit(s, 'etf', 'idx', ter = 0.5, leverage = 2, rate = 'rate'); summary(f)",
   "f = BC.backcast_fit(s, 'etf', 'idx', ter=0.5, leverage=2, rate='rate'); result = BC.summary_SimLevBackcastFit(f)", list(s = s2))
rc("bf_err_col", "backcast_fit(s, 'etf', 'missing')", "result = BC.backcast_fit(s, 'etf', 'missing')", list(s = s2))
rc("bf_err_lev", "backcast_fit(s, 'etf', 'idx', leverage = 0)", "result = BC.backcast_fit(s, 'etf', 'idx', leverage=0)", list(s = s2))
rc("bf_err_few", "s$etf <- NA; backcast_fit(s, 'etf', 'idx')", "s['etf'] = simlev._r.fmt.NA_REAL\nresult = BC.backcast_fit(s, 'etf', 'idx')", list(s = s2))
rc("bf_warn_spread", "backcast_fit(s, 'etf', 'idx', ter = 0.5, fit = c('drag', 'spread'), validate = FALSE)",
   "result = BC.backcast_fit(s, 'etf', 'idx', ter=0.5, fit=['drag', 'spread'], validate=False)", list(s = s2))
rc("bf_err_bounds", "backcast_fit(s, 'etf', 'idx', bounds = list(drag = c(5, -5)))", "result = BC.backcast_fit(s, 'etf', 'idx', bounds={'drag': [5, -5]})", list(s = s2))
rc("bf_err_bounds2", "backcast_fit(s, 'etf', 'idx', bounds = list(alpha = c(0, 1)))", "result = BC.backcast_fit(s, 'etf', 'idx', bounds={'alpha': [0, 1]})", list(s = s2))
rc("bf_err_bounds3", "backcast_fit(s, 'etf', 'idx', bounds = list(beta = c(0.5, NA)))", "result = BC.backcast_fit(s, 'etf', 'idx', bounds={'beta': [0.5, simlev._r.fmt.NA_REAL]})", list(s = s2))
rc("bf_err_fit", "backcast_fit(s, 'etf', 'idx', fit = 'alpha')", "result = BC.backcast_fit(s, 'etf', 'idx', fit='alpha')", list(s = s2))
rc("bf_err_grid2", "backcast_fit(s, 'etf', 'idx', leverage = 2, fit = c('drag', 'beta'), method = 'grid')",
   "result = BC.backcast_fit(s, 'etf', 'idx', leverage=2, fit=['drag', 'beta'], method='grid')", list(s = s2))
rc("bf_err_sort", "backcast_fit(s[c(2, 1, 3:20), ], 'etf', 'idx')", "result = BC.backcast_fit(s.iloc[[1, 0] + list(range(2, 20))], 'etf', 'idx')", list(s = s2))
rc("bf_err_dup", "backcast_fit(s[c(1, 1:20), ], 'etf', 'idx')", "result = BC.backcast_fit(s.iloc[[0] + list(range(20))], 'etf', 'idx')", list(s = s2))
rc("bf_err_na", "s$date[5] <- NA; backcast_fit(s, 'etf', 'idx')", "s.loc[4, 'date'] = pd.NaT\nresult = BC.backcast_fit(s, 'etf', 'idx')", list(s = s2))
rc("bf_err_nodate", "backcast_fit(s[, -1], 'etf', 'idx')", "result = BC.backcast_fit(s.iloc[:, 1:], 'etf', 'idx')", list(s = s2))
rc("bf_err_df", "backcast_fit(1:3, 'etf', 'idx')", "result = BC.backcast_fit(np.arange(1, 4), 'etf', 'idx')")
rc("bf_err_idx", "s$idx[10] <- -1; backcast_fit(s, 'etf', 'idx')", "s.loc[9, 'idx'] = -1\nresult = BC.backcast_fit(s, 'etf', 'idx')", list(s = s2))
rc("bf_err_model", "backcast_fit(s, 'etf', 'idx', model = 'gam')", "result = BC.backcast_fit(s, 'etf', 'idx', model='gam')", list(s = s2))

# ── backcast ───────────────────────────────────────────────────────────────
F2 <- sprintf("f <- backcast_fit(s, 'etf', 'idx', ter = %s, leverage = 2, rate = 'rate')", TER)
F2P <- sprintf("f = BC.backcast_fit(s, 'etf', 'idx', ter=%s, leverage=2, rate='rate')", TERP)
ATTR <- "list(bc = bc, params = attr(bc, 'params'), splice = attr(bc, 'splice_date'))"
ATTRP <- "result = dict(bc=bc, params=bc.attrs['params'], splice=bc.attrs['splice_date'])"
rc("bc_fit", paste0(F2, "; backcast(f)"), paste0(F2P, "; result = BC.backcast(f)"), list(s = s2))
rc("bc_fit_attr", paste0(F2, "; bc <- backcast(f, params = list(drag = 0.5), fill = 'linear', rebase = 100); ", ATTR),
   paste0(F2P, "; bc = BC.backcast(f, params={'drag': 0.5}, fill='linear', rebase=100)\n", ATTRP), list(s = s2))
rc("bc_model", paste0(F2, "; backcast(f, fill = 'model')"), paste0(F2P, "; result = BC.backcast(f, fill='model')"), list(s = s2))
rc("bc_stine", paste0(F2, "; backcast(f, fill = 'stine', splice = '2006-08-15')"), paste0(F2P, "; result = BC.backcast(f, fill='stine', splice='2006-08-15')"), list(s = s2))
rc("bc_none", paste0(F2, "; bc <- backcast(f, splice = 'none'); ", ATTR), paste0(F2P, "; bc = BC.backcast(f, splice='none')\n", ATTRP), list(s = s2))
rc("bc_none_print", paste0(F2, "; backcast(f, splice = 'none')"), paste0(F2P, "; result = BC.backcast(f, splice='none')"), list(s = s2))
rc("bc_otherdata", paste0(F2, "; s2 <- s[1:1000, ]; s2$etf[990:1000] <- NA; backcast(f, data = s2, fill = 'model')"),
   paste0(F2P, "; s2 = s.iloc[:1000].copy(); v = s2['etf'].to_numpy(dtype=float, copy=True); v[989:1000] = simlev._r.fmt.NA_REAL; s2['etf'] = v; result = BC.backcast(f, data=s2, fill='model')"), list(s = s2))
rc("bc_linear", "f <- backcast_fit(s, 'etf', 'idx', ter = 0.2, model = 'linear'); backcast(f, rebase = 100)",
   "f = BC.backcast_fit(s, 'etf', 'idx', ter=0.2, model='linear'); result = BC.backcast(f, rebase=100)", list(s = s1))
rc("bc_spline", "f <- backcast_fit(s, 'etf', 'idx', model = 'spline', fx = 'fx', validate = FALSE); backcast(f)",
   "f = BC.backcast_fit(s, 'etf', 'idx', model='spline', fx='fx', validate=False); result = BC.backcast(f)", list(s = sp))
rc("bc_nofit", sprintf("backcast(NULL, data = s, product = 'etf', index = 'idx', ter = %s, leverage = 2, rate = 'rate', params = list(drag = 0.4), fill = 'model')", TER),
   sprintf("result = BC.backcast(None, data=s, product='etf', index='idx', ter=%s, leverage=2, rate='rate', params={'drag': 0.4}, fill='model')", TERP), list(s = s2))
rc("bc_nofit_attr", "bc <- backcast(data = s, product = 'etf', index = 'idx', leverage = 2, rate = 2, ter = 0.6, splice = '2006-01-01', lag = 1, accrual = 'geometric', unknown = 5); list(bc = bc, params = attr(bc, 'params'), splice = attr(bc, 'splice_date'))",
   "bc = BC.backcast(data=s, product='etf', index='idx', leverage=2, rate=2, ter=0.6, splice='2006-01-01', lag=1, accrual='geometric', unknown=5)\nresult = dict(bc=bc, params=bc.attrs['params'], splice=bc.attrs['splice_date'])", list(s = s2))
rc("bc_noprod", "s$etf <- NA; backcast(data = s, product = 'etf', index = 'idx', fx = 'fx', index_fill = 'linear')",
   "s['etf'] = simlev._r.fmt.NA_REAL\nresult = BC.backcast(data=s, product='etf', index='idx', fx='fx', index_fill='linear')", list(s = sp))
rc("bc_lead", "s$idx[1:5] <- NA; backcast(data = s, product = 'etf', index = 'idx', rebase = 1)",
   "v = s['idx'].to_numpy(dtype=float, copy=True); v[0:5] = simlev._r.fmt.NA_REAL; s['idx'] = v\nresult = BC.backcast(data=s, product='etf', index='idx', rebase=1)", list(s = sp))
rc("bc_err_splice", "backcast(data = s, product = 'etf', index = 'idx', leverage = 2, rate = 2, ter = 0.6, splice = '2030-01-01')",
   "result = BC.backcast(data=s, product='etf', index='idx', leverage=2, rate=2, ter=0.6, splice='2030-01-01')", list(s = s2))
rc("bc_err_splice2", "backcast(data = s, product = 'etf', index = 'idx', splice = 'gestern')",
   "result = BC.backcast(data=s, product='etf', index='idx', splice='gestern')", list(s = s2))
rc("bc_err_splice3", "backcast(data = s, product = 'etf', index = 'idx', splice = NA_character_)",
   "result = BC.backcast(data=s, product='etf', index='idx', splice=np.array([None], dtype=object))", list(s = s2))
rc("bc_err_data", "backcast()", "result = BC.backcast()")
rc("bc_err_prod", "backcast(data = s, index = 'idx')", "result = BC.backcast(data=s, index='idx')", list(s = s2))
rc("bc_err_model", "backcast(data = s, product = 'etf', index = 'idx', model = 'linear')",
   "result = BC.backcast(data=s, product='etf', index='idx', model='linear')", list(s = s2))
rc("bc_err_fit", "backcast(list(a = 1))", "result = BC.backcast({'a': 1})")
rc("bc_err_fill", "backcast(data = s, product = 'etf', index = 'idx', fill = 'x')", "result = BC.backcast(data=s, product='etf', index='idx', fill='x')", list(s = s2))
ref_done()
