# Referenzfälle für r/R/analysis_tests.R (signal_analysis, sharpe_test, overfit_reality_check,
# sharpe_min_track_record, result_heatmap, .ret_from, .hac_cov) -> python/simlev/analysis_tests.py
source("golden/modules/ref_tools.R"); ref_init("analysis_tests")
P <- "from simlev import analysis_tests as AT\nfrom simlev._r import rng as RNG\n"
JH <- "AT = SL.AnalysisTests\n"   # Kopf des Julia-Codes (jl)
# lm-Objekt auf vergleichbare Teile reduzieren (call/terms/qr/model sind R-intern)
# table2d$n: Klasse table und benannte (leere) dimnames-Namen entfernen (reftree vergleicht dimnames als Liste)
LM <- "sa$fit$model <- unclass(sa$fit$model)[c('coefficients', 'residuals', 'fitted.values', 'rank', 'df.residual')]
  if (!is.null(sa$table2d)) { sa$table2d$n <- unclass(sa$table2d$n); dimnames(sa$table2d$n) <- unname(dimnames(sa$table2d$n)) }; sa"

# ── signal_analysis ─────────────────────────────────────────────────────────
set.seed(1); n <- 3 * 365
d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
d$mom <- c(rep(NA, 60), d$aktien[-(1:60)] / d$aktien[1:(n - 60)] - 1)
d$inv <- as.numeric(signal_state(signal_sma(d$aktien, 100)))
d$vol <- c(rep(NA, 20), vapply(21:n, function(i) sd(diff(log(d$aktien[(i - 20):i]))), 0))
d$const <- 1
I <- list(d = d)
ref_case("sa_basic", paste("sa <- signal_analysis(d, 'mom', 'aktien', horizon = 21, bins = 4, splits = 2);", LM),
         paste0(P, "result = AT.signal_analysis(d, 'mom', 'aktien', horizon=21, bins=4, splits=2)"), I,
         jl = paste0(JH, 'result = AT.signal_analysis(d, "mom", "aktien"; horizon = 21, bins = 4, splits = 2)'))
ref_case("sa_default", paste("sa <- signal_analysis(d, 'mom', 'aktien');", LM),
         paste0(P, "result = AT.signal_analysis(d, 'mom', 'aktien')"), I,
         jl = paste0(JH, 'result = AT.signal_analysis(d, "mom", "aktien")'))
ref_case("sa_breaks", paste("sa <- signal_analysis(d, 'mom', 'aktien', horizon = 10, step = 5, breaks = c(-1, -0.02, 0, 0.03, 1), degree = 3);", LM),
         paste0(P, "result = AT.signal_analysis(d, 'mom', 'aktien', horizon=10, step=5, breaks=[-1, -0.02, 0, 0.03, 1], degree=3)"), I,
         jl = paste0(JH, 'result = AT.signal_analysis(d, "mom", "aktien"; horizon = 10, step = 5, breaks = [-1, -0.02, 0, 0.03, 1], degree = 3)'))
ref_case("sa_binary", paste("sa <- signal_analysis(d, 'inv', 'aktien', horizon = 15);", LM),
         paste0(P, "result = AT.signal_analysis(d, 'inv', 'aktien', horizon=15)"), I,
         jl = paste0(JH, 'result = AT.signal_analysis(d, "inv", "aktien"; horizon = 15)'))
ref_case("sa_2d", paste("sa <- signal_analysis(d, d$mom, 'aktien', horizon = 7, bins = 3, signal2 = 'vol', bins2 = 2, splits = 3, degree = 0);", LM),
         paste0(P, "result = AT.signal_analysis(d, d['mom'].to_numpy(), 'aktien', horizon=7, bins=3, signal2='vol', bins2=2, splits=3, degree=0)"), I,
         jl = paste0(JH, 'result = AT.signal_analysis(d, d.mom, "aktien"; horizon = 7, bins = 3, signal2 = "vol", bins2 = 2, splits = 3, degree = 0)'))
ref_case("sa_2d_vec", paste("sa <- signal_analysis(d, 'mom', 'aktien', horizon = 5, signal2 = d$vol, splits = 4, degree = 1);", LM),
         paste0(P, "result = AT.signal_analysis(d, 'mom', 'aktien', horizon=5, signal2=d['vol'].to_numpy(), splits=4, degree=1)"), I,
         jl = paste0(JH, 'result = AT.signal_analysis(d, "mom", "aktien"; horizon = 5, signal2 = d.vol, splits = 4, degree = 1)'))
# unsortiert, doppelte Daten, fehlende Kurse, Datum als Text
d2 <- d[c(n:1, 100, 200, 300), ]; d2$aktien[c(50, 51, 400)] <- NA; d2$date <- format(d2$date)
ref_case("sa_unsorted", paste("sa <- signal_analysis(d2, 'mom', 'aktien', horizon = 30, bins = 6);", LM),
         paste0(P, "result = AT.signal_analysis(d2, 'mom', 'aktien', horizon=30, bins=6)"), list(d2 = d2),
         jl = paste0(JH, 'result = AT.signal_analysis(d2, "mom", "aktien"; horizon = 30, bins = 6)'))
small <- d[1:200, ]
ref_case("sa_small_ties", paste("sa <- signal_analysis(small, round(small$aktien) %% 3, 'aktien', horizon = 3, bins = 2, splits = 2);", LM),
         paste0(P, "result = AT.signal_analysis(small, np.round(small['aktien'].to_numpy()) % 3, 'aktien', horizon=3, bins=2, splits=2)"), list(small = small),
         jl = paste0(JH, 'result = AT.signal_analysis(small, mod.(round.(small.aktien), 3), "aktien"; horizon = 3, bins = 2, splits = 2)'))
ref_case("sa_err_df", "signal_analysis(list(a = 1), 'a', 'b')", paste0(P, "result = AT.signal_analysis({'a': 1}, 'a', 'b')"),
         jl = paste0(JH, 'result = AT.signal_analysis(SL.RList("a" => 1), "a", "b")'))
ref_case("sa_err_col", "signal_analysis(small, 'Mom', 'aktien')", paste0(P, "result = AT.signal_analysis(small, 'Mom', 'aktien')"), list(small = small),
         jl = paste0(JH, 'result = AT.signal_analysis(small, "Mom", "aktien")'))
ref_case("sa_err_len", "signal_analysis(small, small$mom[-1], 'aktien')", paste0(P, "result = AT.signal_analysis(small, small['mom'].to_numpy()[1:], 'aktien')"), list(small = small),
         jl = paste0(JH, 'result = AT.signal_analysis(small, small.mom[2:end], "aktien")'))
ref_case("sa_err_target", "signal_analysis(small, 'mom', 2)", paste0(P, "result = AT.signal_analysis(small, 'mom', 2)"), list(small = small),
         jl = paste0(JH, 'result = AT.signal_analysis(small, "mom", 2)'))
ref_case("sa_err_target_col", "signal_analysis(small, 'mom', 'x')", paste0(P, "result = AT.signal_analysis(small, 'mom', 'x')"), list(small = small),
         jl = paste0(JH, 'result = AT.signal_analysis(small, "mom", "x")'))
ref_case("sa_err_horizon", "signal_analysis(small, 'mom', 'aktien', horizon = 5000)", paste0(P, "result = AT.signal_analysis(small, 'mom', 'aktien', horizon=5000)"), list(small = small),
         jl = paste0(JH, 'result = AT.signal_analysis(small, "mom", "aktien"; horizon = 5000)'))
ref_case("sa_err_horizon0", "signal_analysis(small, 'mom', 'aktien', horizon = 0)", paste0(P, "result = AT.signal_analysis(small, 'mom', 'aktien', horizon=0)"), list(small = small),
         jl = paste0(JH, 'result = AT.signal_analysis(small, "mom", "aktien"; horizon = 0)'))
ref_case("sa_err_step", "signal_analysis(small, 'mom', 'aktien', step = 0)", paste0(P, "result = AT.signal_analysis(small, 'mom', 'aktien', step=0)"), list(small = small),
         jl = paste0(JH, 'result = AT.signal_analysis(small, "mom", "aktien"; step = 0)'))
ref_case("sa_err_breaks", "signal_analysis(small, 'mom', 'aktien', breaks = 0)", paste0(P, "result = AT.signal_analysis(small, 'mom', 'aktien', breaks=0)"), list(small = small),
         jl = paste0(JH, 'result = AT.signal_analysis(small, "mom", "aktien"; breaks = 0)'))
ref_case("sa_err_breaks2", "signal_analysis(small, 'mom', 'aktien', breaks = c(0, 2, 1))", paste0(P, "result = AT.signal_analysis(small, 'mom', 'aktien', breaks=[0, 2, 1])"), list(small = small),
         jl = paste0(JH, 'result = AT.signal_analysis(small, "mom", "aktien"; breaks = [0, 2, 1])'))
ref_case("sa_err_bins", "signal_analysis(small, 'mom', 'aktien', bins = 1)", paste0(P, "result = AT.signal_analysis(small, 'mom', 'aktien', bins=1)"), list(small = small),
         jl = paste0(JH, 'result = AT.signal_analysis(small, "mom", "aktien"; bins = 1)'))
ref_case("sa_err_few", "signal_analysis(small, 'mom', 'aktien', horizon = 21)", paste0(P, "result = AT.signal_analysis(small, 'mom', 'aktien', horizon=21)"), list(small = small),
         jl = paste0(JH, 'result = AT.signal_analysis(small, "mom", "aktien"; horizon = 21)'))
ref_case("sa_err_const", "signal_analysis(d, 'const', 'aktien')", paste0(P, "result = AT.signal_analysis(d, 'const', 'aktien')"), I,
         jl = paste0(JH, 'result = AT.signal_analysis(d, "const", "aktien")'))
ref_case("sa_err_date", "signal_analysis(data.frame(date = 1:30, p = 1:30), 'p', 'p')",
         paste0(P, "result = AT.signal_analysis(pd.DataFrame({'date': np.arange(1, 31), 'p': np.arange(1, 31)}), 'p', 'p')"),
         jl = paste0(JH, 'result = AT.signal_analysis(SL.RFrame("date" => collect(1:30), "p" => collect(1:30)), "p", "p")'))

# ── .hac_cov ────────────────────────────────────────────────────────────────
set.seed(2); Y <- matrix(rnorm(400), 100) + 0.3 * matrix(rnorm(400), 100)
ref_case("hac", "list(SimLev:::.hac_cov(Y), SimLev:::.hac_cov(Y, 0), SimLev:::.hac_cov(Y[1:30, ], 7))",
         paste0(P, "result = [AT._hac_cov(Y), AT._hac_cov(Y, 0), AT._hac_cov(Y[:30], 7)]"), list(Y = Y),
         jl = paste0(JH, 'result = Any[AT._hac_cov(Y), AT._hac_cov(Y, 0), AT._hac_cov(Y[1:30, :], 7)]'))

# ── sharpe_test ─────────────────────────────────────────────────────────────
set.seed(1); n <- 3 * 365
p <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
p$a <- 100 * cumprod(1 + rnorm(n, 4e-4, 0.01)); p$b <- 100 * cumprod(1 + rnorm(n, 2e-4, 0.01))
ra <- diff(p$a) / p$a[-n]; rb <- diff(p$b) / p$b[-n]
I <- list(p = p, ra = ra, rb = rb)
PA <- "pa = p[['date', 'a']]; pb = p[['date', 'b']]\n"
ref_case("st_df_week", "sharpe_test(p[, c('date', 'a')], p[, c('date', 'b')])", paste0(P, PA, "result = AT.sharpe_test(pa, pb)"), I,
         jl = paste0(JH, 'pa = SL.RFrame("date" => p.date, "a" => p.a); pb = SL.RFrame("date" => p.date, "b" => p.b)
result = AT.sharpe_test(pa, pb)'))
ref_case("st_df_month", "sharpe_test(p[, c('date', 'a')], p[, c('date', 'b')], frequency = 'month')", paste0(P, PA, "result = AT.sharpe_test(pa, pb, frequency='month')"), I,
         jl = paste0(JH, 'pa = SL.RFrame("date" => p.date, "a" => p.a); pb = SL.RFrame("date" => p.date, "b" => p.b)
result = AT.sharpe_test(pa, pb; frequency = "month")'))
ref_case("st_df_day", "sharpe_test(p[, c('date', 'a')], p[, c('date', 'b')], frequency = 'day', ppy = 365)", paste0(P, PA, "result = AT.sharpe_test(pa, pb, frequency='day', ppy=365)"), I,
         jl = paste0(JH, 'pa = SL.RFrame("date" => p.date, "a" => p.a); pb = SL.RFrame("date" => p.date, "b" => p.b)
result = AT.sharpe_test(pa, pb; frequency = "day", ppy = 365)'))
ref_case("st_df_boot", "sharpe_test(p[, c('date', 'a')], p[, c('date', 'b')], method = 'bootstrap', B = 300, seed = 1)",
         paste0(P, PA, "result = AT.sharpe_test(pa, pb, method='bootstrap', B=300, seed=1)"), I,
         jl = paste0(JH, 'pa = SL.RFrame("date" => p.date, "a" => p.a); pb = SL.RFrame("date" => p.date, "b" => p.b)
result = AT.sharpe_test(pa, pb; method = "bootstrap", B = 300, seed = 1)'))
ref_case("st_vec_hac", "sharpe_test(ra, rb, ppy = 365)", paste0(P, "result = AT.sharpe_test(ra, rb, ppy=365)"), I,
         jl = paste0(JH, 'result = AT.sharpe_test(ra, rb; ppy = 365)'))
ref_case("st_vec_hac_day", "sharpe_test(ra[1:300], rb[1:300], frequency = 'day')", paste0(P, "result = AT.sharpe_test(ra[:300], rb[:300], frequency='day')"), I,
         jl = paste0(JH, 'result = AT.sharpe_test(ra[1:300], rb[1:300]; frequency = "day")'))
ref_case("st_vec_boot_block", "sharpe_test(ra, rb, method = 'bootstrap', B = 200, block = 5.5, seed = 7, frequency = 'month')",
         paste0(P, "result = AT.sharpe_test(ra, rb, method='bootstrap', B=200, block=5.5, seed=7, frequency='month')"), I,
         jl = paste0(JH, 'result = AT.sharpe_test(ra, rb; method = "bootstrap", B = 200, block = 5.5, seed = 7, frequency = "month")'))
ref_case("st_vec_boot_noseed", "set.seed(9); x <- sharpe_test(ra[1:200], rb[1:200], method = 'bootstrap', B = 100); c(x, runif(1))",
         paste0(P, "RNG.set_seed(9); x = AT.sharpe_test(ra[:200], rb[:200], method='bootstrap', B=100); result = np.append(x.to_numpy(), RNG.runif(1))"), I,
         jl = paste0(JH, 'SL.RRng.set_seed(9); x = AT.sharpe_test(ra[1:200], rb[1:200]; method = "bootstrap", B = 100); result = vcat(x.values, SL.RRng.runif(1))'))
ref_case("st_vec_na", "x <- ra; x[c(3, 10)] <- NA; y <- rb; y[20] <- Inf; sharpe_test(x, y)",
         paste0(P, "x = ra.copy(); x[[2, 9]] = simlev._r.fmt.NA_REAL; y = rb.copy(); y[19] = np.inf; result = AT.sharpe_test(x, y)"), I,
         jl = paste0(JH, 'x = copy(ra); x[[3, 10]] .= SL.NA; y = copy(rb); y[20] = Inf; result = AT.sharpe_test(x, y)'))
ref_case("st_identical", "sharpe_test(ra, ra, ppy = 365)", paste0(P, "result = AT.sharpe_test(ra, ra, ppy=365)"), I,
         jl = paste0(JH, 'result = AT.sharpe_test(ra, ra; ppy = 365)'))
ref_case("st_identical_df", "sharpe_test(p[, c('date', 'a')], p[, c('date', 'a')], method = 'bootstrap')", paste0(P, PA, "result = AT.sharpe_test(pa, pa, method='bootstrap')"), I,
         jl = paste0(JH, 'pa = SL.RFrame("date" => p.date, "a" => p.a); pb = SL.RFrame("date" => p.date, "b" => p.b)
result = AT.sharpe_test(pa, pa; method = "bootstrap")'))
ref_case("st_df_offset", "q <- p[200:n, c('date', 'b')]; q$date <- q$date; sharpe_test(p[, c('date', 'a')], q[seq(1, nrow(q), 2), ], frequency = 'week')",
         paste0(P, PA, "q = p.iloc[199:][['date', 'b']]; result = AT.sharpe_test(pa, q.iloc[::2], frequency='week')"), I,
         jl = paste0(JH, 'pa = SL.RFrame("date" => p.date, "a" => p.a); pb = SL.RFrame("date" => p.date, "b" => p.b)
q = SL.RFrame("date" => p.date[200:end], "b" => p.b[200:end]); result = AT.sharpe_test(pa, SL.rows(q, 1:2:SL.nrow(q)); frequency = "week")'))
ref_case("st_err_mixed", "sharpe_test(ra, p[, c('date', 'a')])", paste0(P, PA, "result = AT.sharpe_test(ra, pa)"), I,
         jl = paste0(JH, 'pa = SL.RFrame("date" => p.date, "a" => p.a); pb = SL.RFrame("date" => p.date, "b" => p.b)
result = AT.sharpe_test(ra, pa)'))
ref_case("st_err_len", "sharpe_test(ra[1:1000], ra[1:500])", paste0(P, "result = AT.sharpe_test(ra[:1000], ra[:500])"), I,
         jl = paste0(JH, 'result = AT.sharpe_test(ra[1:1000], ra[1:500])'))
ref_case("st_err_var", "sharpe_test(ra[1:500], rep(0.001, 500))", paste0(P, "result = AT.sharpe_test(ra[:500], np.repeat(0.001, 500))"), I,
         jl = paste0(JH, 'result = AT.sharpe_test(ra[1:500], fill(0.001, 500))'))
ref_case("st_err_var_x", "sharpe_test(rep(0.001, 500), ra[1:500])", paste0(P, "result = AT.sharpe_test(np.repeat(0.001, 500), ra[:500])"), I,
         jl = paste0(JH, 'result = AT.sharpe_test(fill(0.001, 500), ra[1:500])'))
ref_case("st_err_few", "sharpe_test(ra[1:3], ra[3:1] + 0.01)", paste0(P, "result = AT.sharpe_test(ra[:3], ra[2::-1] + 0.01)"), I,
         jl = paste0(JH, 'result = AT.sharpe_test(ra[1:3], ra[3:-1:1] .+ 0.01)'))
ref_case("st_err_freq", "sharpe_test(ra, rb, frequency = 'year')", paste0(P, "result = AT.sharpe_test(ra, rb, frequency='year')"), I,
         jl = paste0(JH, 'result = AT.sharpe_test(ra, rb; frequency = "year")'))
ref_case("st_err_input", "sharpe_test(list(1), list(2))", paste0(P, "result = AT.sharpe_test({'a': 1}, {'b': 2})"), I,
         jl = paste0(JH, 'result = AT.sharpe_test(Any[1], Any[2])'))
SIM <- "sa = simlev.simulation(p[['date', 'a']], simlev.create_strategy(a=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)))\nsb = simlev.simulation(p[['date', 'b']], simlev.create_strategy(b=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)), dca=simlev.dca_plan(value=100, span=1))\n"
ref_case("st_sim", "sa <- simulation(p[, c('date', 'a')], create_strategy(a = asset_config('etf', 'bnh', spread = 0.1)))
  sb <- simulation(p[, c('date', 'b')], create_strategy(b = asset_config('etf', 'bnh', spread = 0.1)), dca = dca_plan(value = 100, span = 1))
  list(sharpe_test(sa, sb, frequency = 'month'), sharpe_test(sa, sb, frequency = 'day'), sharpe_min_track_record(sb), sharpe_min_track_record(sa, frequency = 'day', target = 0.2))",
  paste0(P, SIM, "result = [AT.sharpe_test(sa, sb, frequency='month'), AT.sharpe_test(sa, sb, frequency='day'), AT.sharpe_min_track_record(sb), AT.sharpe_min_track_record(sa, frequency='day', target=0.2)]"), I,
         jl = paste0(JH, 'sa = SL.simulation(SL.RFrame("date" => p.date, "a" => p.a), SL.create_strategy("a" => SL.asset_config("etf", "bnh", spread = 0.1)))
sb = SL.simulation(SL.RFrame("date" => p.date, "b" => p.b), SL.create_strategy("b" => SL.asset_config("etf", "bnh", spread = 0.1)); dca = SL.dca_plan(; value = 100, span = 1))
result = Any[AT.sharpe_test(sa, sb; frequency = "month"), AT.sharpe_test(sa, sb; frequency = "day"), AT.sharpe_min_track_record(sb), AT.sharpe_min_track_record(sa; frequency = "day", target = 0.2)]'))

# ── .ret_from ───────────────────────────────────────────────────────────────
q <- p[c(1:40, 45:300), c("date", "a")]; q$a[c(5, 6)] <- NA
ref_case("ret_from", "list(SimLev:::.ret_from(q, 'week'), SimLev:::.ret_from(q, 'month'), SimLev:::.ret_from(q, 'day'), SimLev:::.ret_from(q, 'month', 2), SimLev:::.ret_from(1:5 / 100, 'day'))",
         paste0(P, "result = [AT._ret_from(q, 'week'), AT._ret_from(q, 'month'), AT._ret_from(q, 'day'), AT._ret_from(q, 'month', 2), AT._ret_from(np.arange(1, 6) / 100, 'day')]"), list(q = q),
         jl = paste0(JH, 'result = Any[AT._ret_from(q, "week"), AT._ret_from(q, "month"), AT._ret_from(q, "day"), AT._ret_from(q, "month", 2), AT._ret_from(collect(1:5) ./ 100, "day")]'))

# ── overfit_reality_check ───────────────────────────────────────────────────────────
set.seed(4); R <- matrix(rnorm(800 * 10, 0, 0.01), 800); R[, 2] <- R[, 2] + 0.003
I <- list(R = R)
ref_case("rc_day", "overfit_reality_check(R, B = 200, frequency = 'day', seed = 1)", paste0(P, "result = AT.overfit_reality_check(R, B=200, frequency='day', seed=1)"), I,
         jl = paste0(JH, 'result = AT.overfit_reality_check(R; B = 200, frequency = "day", seed = 1)'))
ref_case("rc_default", "overfit_reality_check(R[, 1:4], B = 99, seed = 3)", paste0(P, "result = AT.overfit_reality_check(R[:, :4], B=99, seed=3)"), I,
         jl = paste0(JH, 'result = AT.overfit_reality_check(R[:, 1:4]; B = 99, seed = 3)'))
ref_case("rc_block", "overfit_reality_check(R, B = 150, block = 12.5, frequency = 'month', seed = 2)", paste0(P, "result = AT.overfit_reality_check(R, B=150, block=12.5, frequency='month', seed=2)"), I,
         jl = paste0(JH, 'result = AT.overfit_reality_check(R; B = 150, block = 12.5, frequency = "month", seed = 2)'))
ref_case("rc_bench_num", "overfit_reality_check(R, benchmark = 3, B = 100, frequency = 'day', seed = 1)", paste0(P, "result = AT.overfit_reality_check(R, benchmark=3, B=100, frequency='day', seed=1)"), I,
         jl = paste0(JH, 'result = AT.overfit_reality_check(R; benchmark = 3, B = 100, frequency = "day", seed = 1)'))
ref_case("rc_bench_vec", "overfit_reality_check(R[, 1:5], benchmark = R[, 6], B = 100, frequency = 'day', seed = 1)", paste0(P, "result = AT.overfit_reality_check(R[:, :5], benchmark=R[:, 5], B=100, frequency='day', seed=1)"), I,
         jl = paste0(JH, 'result = AT.overfit_reality_check(R[:, 1:5]; benchmark = R[:, 6], B = 100, frequency = "day", seed = 1)'))
Rn <- R[, 1:4]; colnames(Rn) <- c("a", "b", "c", "d"); Rn[1:10, 4] <- NA; Rn <- cbind(Rn, e = NA)
ref_case("rc_bench_name", "overfit_reality_check(Rn, benchmark = 'c', B = 100, frequency = 'day', seed = 1)", paste0(P, "result = AT.overfit_reality_check(Rn, benchmark='c', B=100, frequency='day', seed=1)"), list(Rn = Rn),
         jl = paste0(JH, 'result = AT.overfit_reality_check(Rn; benchmark = "c", B = 100, frequency = "day", seed = 1)'))
ref_case("rc_df", "overfit_reality_check(as.data.frame(Rn), B = 50, frequency = 'day', seed = 5)", paste0(P, "result = AT.overfit_reality_check(Rn, B=50, frequency='day', seed=5)"), list(Rn = as.data.frame(Rn)),
         jl = paste0(JH, 'result = AT.overfit_reality_check(Rn; B = 50, frequency = "day", seed = 5)'))
dts <- seq.Date(as.Date("2018-01-01"), by = "day", length.out = 800)
ref_case("rc_dates_week", "overfit_reality_check(R[, 1:6], dates = dts, B = 120, seed = 1)", paste0(P, "result = AT.overfit_reality_check(R[:, :6], dates=dts, B=120, seed=1)"), list(R = R, dts = dts),
         jl = paste0(JH, 'result = AT.overfit_reality_check(R[:, 1:6]; dates = dts, B = 120, seed = 1)'))
ref_case("rc_dates_month", "overfit_reality_check(R[, 1:6], benchmark = 1, dates = format(dts), frequency = 'month', B = 120, seed = 1)",
         paste0(P, "result = AT.overfit_reality_check(R[:, :6], benchmark=1, dates=np.datetime_as_string(dts), frequency='month', B=120, seed=1)"), list(R = R, dts = dts),
         jl = paste0(JH, 'result = AT.overfit_reality_check(R[:, 1:6]; benchmark = 1, dates = string.(dts), frequency = "month", B = 120, seed = 1)'))
set.seed(1); r1 <- matrix(rnorm(500, 0.0004, 0.01), ncol = 1)
ref_case("rc_one", "list(overfit_reality_check(r1, B = 199, frequency = 'day', seed = 1), overfit_reality_check(cbind(r1, r1), B = 199, frequency = 'day', seed = 1))",
         paste0(P, "result = [AT.overfit_reality_check(r1, B=199, frequency='day', seed=1), AT.overfit_reality_check(np.column_stack([r1, r1]), B=199, frequency='day', seed=1)]"), list(r1 = r1),
         jl = paste0(JH, 'result = Any[AT.overfit_reality_check(r1; B = 199, frequency = "day", seed = 1), AT.overfit_reality_check(hcat(r1, r1); B = 199, frequency = "day", seed = 1)]'))
ref_case("rc_print_one", "overfit_reality_check(r1, B = 99, frequency = 'day', seed = 1)", paste0(P, "result = AT.overfit_reality_check(r1, B=99, frequency='day', seed=1)"), list(r1 = r1),
         jl = paste0(JH, 'result = AT.overfit_reality_check(r1; B = 99, frequency = "day", seed = 1)'))
ref_case("rc_noseed", "set.seed(11); x <- overfit_reality_check(R[1:200, 1:3], B = 50, frequency = 'day'); list(x, runif(2))",
         paste0(P, "RNG.set_seed(11); x = AT.overfit_reality_check(R[:200, :3], B=50, frequency='day'); result = [x, RNG.runif(2)]"), I,
         jl = paste0(JH, 'SL.RRng.set_seed(11); x = AT.overfit_reality_check(R[1:200, 1:3]; B = 50, frequency = "day"); result = Any[x, SL.RRng.runif(2)]'))
ref_case("rc_err_bench", "overfit_reality_check(R, benchmark = 'zz', B = 10, seed = 1)", paste0(P, "result = AT.overfit_reality_check(R, benchmark='zz', B=10, seed=1)"), I,
         jl = paste0(JH, 'result = AT.overfit_reality_check(R; benchmark = "zz", B = 10, seed = 1)'))
ref_case("rc_err_bench_num", "overfit_reality_check(R, benchmark = 11, B = 10, seed = 1)", paste0(P, "result = AT.overfit_reality_check(R, benchmark=11, B=10, seed=1)"), I,
         jl = paste0(JH, 'result = AT.overfit_reality_check(R; benchmark = 11, B = 10, seed = 1)'))
ref_case("rc_err_bench_len", "overfit_reality_check(R, benchmark = c(0.1, 0.2), B = 10, seed = 1)", paste0(P, "result = AT.overfit_reality_check(R, benchmark=[0.1, 0.2], B=10, seed=1)"), I,
         jl = paste0(JH, 'result = AT.overfit_reality_check(R; benchmark = [0.1, 0.2], B = 10, seed = 1)'))
ref_case("rc_err_x", "overfit_reality_check(letters, B = 10)", paste0(P, "result = AT.overfit_reality_check(np.array(list('abcdefghijklmnopqrstuvwxyz'), dtype=object), B=10)"), I,
         jl = paste0(JH, 'result = AT.overfit_reality_check(string.(collect("abcdefghijklmnopqrstuvwxyz")); B = 10)'))

# ── sharpe_min_track_record ────────────────────────────────────────────────────────
set.seed(1); r <- rnorm(520, 0.002, 0.02)
nn <- 10 * 365
dm <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = nn)[seq(1, nn, 2)])
dm$value <- 100 * cumprod(1 + rnorm(nrow(dm), 4e-4, 0.01)); dm$other <- 1
I <- list(r = r, dm = dm)
ref_case("mt_vec", "sharpe_min_track_record(r, target = 0, ppy = 52)", paste0(P, "result = AT.sharpe_min_track_record(r, target=0, ppy=52)"), I,
         jl = paste0(JH, 'result = AT.sharpe_min_track_record(r; target = 0, ppy = 52)'))
ref_case("mt_vec2", "sharpe_min_track_record(r, target = 0.5, prob = 0.9, ppy = 52)", paste0(P, "result = AT.sharpe_min_track_record(r, target=0.5, prob=0.9, ppy=52)"), I,
         jl = paste0(JH, 'result = AT.sharpe_min_track_record(r; target = 0.5, prob = 0.9, ppy = 52)'))
ref_case("mt_vec_inf", "sharpe_min_track_record(r, target = 3)", paste0(P, "result = AT.sharpe_min_track_record(r, target=3)"), I,
         jl = paste0(JH, 'result = AT.sharpe_min_track_record(r; target = 3)'))
ref_case("mt_vec_month", "x <- r; x[5] <- NA; sharpe_min_track_record(x, frequency = 'month')", paste0(P, "x = r.copy(); x[4] = simlev._r.fmt.NA_REAL; result = AT.sharpe_min_track_record(x, frequency='month')"), I,
         jl = paste0(JH, 'x = copy(r); x[5] = SL.NA; result = AT.sharpe_min_track_record(x; frequency = "month")'))
ref_case("mt_df_month", "sharpe_min_track_record(dm, frequency = 'month')", paste0(P, "result = AT.sharpe_min_track_record(dm, frequency='month')"), I,
         jl = paste0(JH, 'result = AT.sharpe_min_track_record(dm; frequency = "month")'))
ref_case("mt_df_week", "sharpe_min_track_record(dm, target = 0.1, prob = 0.99)", paste0(P, "result = AT.sharpe_min_track_record(dm, target=0.1, prob=0.99)"), I,
         jl = paste0(JH, 'result = AT.sharpe_min_track_record(dm; target = 0.1, prob = 0.99)'))
ref_case("mt_df_day", "sharpe_min_track_record(dm, frequency = 'day', ppy = 182.6)", paste0(P, "result = AT.sharpe_min_track_record(dm, frequency='day', ppy=182.6)"), I,
         jl = paste0(JH, 'result = AT.sharpe_min_track_record(dm; frequency = "day", ppy = 182.6)'))
ref_case("mt_err_freq", "sharpe_min_track_record(r, frequency = 'x')", paste0(P, "result = AT.sharpe_min_track_record(r, frequency='x')"), I,
         jl = paste0(JH, 'result = AT.sharpe_min_track_record(r; frequency = "x")'))

# ── result_heatmap ──────────────────────────────────────────────────────────
set.seed(1)
wk <- data.frame(date = seq.Date(as.Date("2005-01-01"), by = "week", length.out = 16 * 52 + 10))
wk$value <- 100 * cumprod(1 + rnorm(nrow(wk), 1.5e-3, 0.02))
dt <- seq.Date(as.Date("2010-01-01"), as.Date("2015-01-31"), by = "day")
lin <- data.frame(date = dt, value = 100 * 1.10^(as.numeric(dt - dt[1]) / 365.25))
cal <- seq.Date(as.Date("2012-01-01"), as.Date("2016-12-30"), by = "day"); td <- cal[!format(cal, "%u") %in% c("6", "7")]
set.seed(2); tdd <- data.frame(date = td, value = 100 * cumprod(1 + rnorm(length(td), 3e-4, 0.01)))
cpi <- data.frame(date = seq.Date(as.Date("2004-01-01"), by = "month", length.out = 240), value = 100 * 1.002^(0:239))
I <- list(wk = wk, lin = lin, tdd = tdd, cpi = cpi)
ref_case("hm_week", "result_heatmap(wk, max_years = 10)", paste0(P, "result = AT.result_heatmap(wk, max_years=10)"), I,
         jl = paste0(JH, 'result = AT.result_heatmap(wk; max_years = 10)'))
ref_case("hm_week_all", "result_heatmap(wk)", paste0(P, "result = AT.result_heatmap(wk)"), I,
         jl = paste0(JH, 'result = AT.result_heatmap(wk)'))
ref_case("hm_week_infl", "result_heatmap(wk, inflation = 2, max_years = 4)", paste0(P, "result = AT.result_heatmap(wk, inflation=2, max_years=4)"), I,
         jl = paste0(JH, 'result = AT.result_heatmap(wk; inflation = 2, max_years = 4)'))
ref_case("hm_week_cpi", "result_heatmap(wk, inflation = cpi, max_years = 30)", paste0(P, "result = AT.result_heatmap(wk, inflation=cpi, max_years=30)"), I,
         jl = paste0(JH, 'result = AT.result_heatmap(wk; inflation = cpi, max_years = 30)'))
ref_case("hm_cpi_vec", "result_heatmap(wk[wk$date >= as.Date('2006-01-01'), ], inflation = setNames(cpi$value, format(cpi$date)))",
         paste0(P, "w2 = wk[wk['date'] >= np.datetime64('2006-01-01')]\nresult = AT.result_heatmap(w2, inflation=pd.Series(cpi['value'].to_numpy(), index=np.datetime_as_string(cpi['date'].to_numpy())))"), I,
         jl = paste0(JH, 'w2 = SL.rows(wk, wk.date .>= Date(2006, 1, 1))
result = AT.result_heatmap(w2; inflation = SL.RVector(cpi.value; names = string.(cpi.date)))'))
ref_case("hm_cpi_late", "result_heatmap(wk, inflation = cpi[cpi$date >= as.Date('2006-01-01'), ])", paste0(P, "result = AT.result_heatmap(wk, inflation=cpi[cpi['date'] >= np.datetime64('2006-01-01')])"), I,
         jl = paste0(JH, 'result = AT.result_heatmap(wk; inflation = SL.rows(cpi, cpi.date .>= Date(2006, 1, 1)))'))
ref_case("hm_stub", "result_heatmap(lin)", paste0(P, "result = AT.result_heatmap(lin)"), I,
         jl = paste0(JH, 'result = AT.result_heatmap(lin)'))
ref_case("hm_trading", "result_heatmap(tdd)", paste0(P, "result = AT.result_heatmap(tdd)"), I,
         jl = paste0(JH, 'result = AT.result_heatmap(tdd)'))
ref_case("hm_unsorted", "result_heatmap(tdd[nrow(tdd):1, ], max_years = 2)", paste0(P, "result = AT.result_heatmap(tdd.iloc[::-1], max_years=2)"), I,
         jl = paste0(JH, 'result = AT.result_heatmap(SL.rows(tdd, SL.nrow(tdd):-1:1); max_years = 2)'))
ref_case("hm_short", "result_heatmap(tdd[1:300, ])", paste0(P, "result = AT.result_heatmap(tdd.iloc[:300])"), I,
         jl = paste0(JH, 'result = AT.result_heatmap(SL.rows(tdd, 1:300))'))
ref_case("hm_oneyear", "result_heatmap(lin[1:366, ])", paste0(P, "result = AT.result_heatmap(lin.iloc[:366])"), I,
         jl = paste0(JH, 'result = AT.result_heatmap(SL.rows(lin, 1:366))'))
ref_case("hm_err_list", "result_heatmap(list(a = lin, b = lin))", paste0(P, "result = AT.result_heatmap({'a': lin, 'b': lin})"), I,
         jl = paste0(JH, 'result = AT.result_heatmap(SL.RList("a" => lin, "b" => lin))'))
SIMH <- "rr = simlev.simulation(tdd.rename(columns={'value': 'A'}), simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)), dca=simlev.dca_plan(value=50, span=1))\n"
ref_case("hm_sim", "rr <- simulation(setNames(tdd, c('date', 'A')), create_strategy(A = asset_config('etf', 'bnh', spread = 0.1)), dca = dca_plan(value = 50, span = 1)); result_heatmap(rr, inflation = 1.5)",
         paste0(P, SIMH, "result = AT.result_heatmap(rr, inflation=1.5)"), I,
         jl = paste0(JH, 'rr = SL.simulation(SL.RFrame("date" => tdd.date, "A" => tdd.value), SL.create_strategy("A" => SL.asset_config("etf", "bnh", spread = 0.1)); dca = SL.dca_plan(; value = 50, span = 1))
result = AT.result_heatmap(rr; inflation = 1.5)'))
ref_done()
