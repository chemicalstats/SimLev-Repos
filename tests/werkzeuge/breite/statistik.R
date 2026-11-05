# tests/werkzeuge/breite/statistik.R – Referenzfälle des Bereichs statistik: statistische Tests und Tiefenanalyse.
# Module: analysis_tests, deep_analysis (bis 1.4.0 je ein Generator gen_<modul>.R, hier wörtlich hintereinander).
# Aufruf (Repo-Wurzel): LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/breite/statistik.R
# Breitenprüfung, nichts abgelegt: alle bisherigen Einzelfälle des Bereichs (bis 1.4.1 Generator des Katalogs) flach nach
# <ordner>/breite_statistik.jsonl.gz; tests/werkzeuge/gleichlauf/run.py vergleicht Python und Julia damit. Abgelegt sind die Szenarien
# und Tabellen aus tests/gleichlauf/erzeugen/statistik.R (Format und Umgebung: tests/gleichlauf/erzeugen/ref_tools.R).
source("tests/gleichlauf/erzeugen/ref_tools.R")
ref_bereich("breite_statistik", alle = TRUE)

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul analysis_tests
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Referenzfälle für r/R/analysis_tests.R (signal_analysis, sharpe_test, overfit_reality_check,
# sharpe_min_track_record, result_heatmap, .ret_from, .hac_cov) -> python/simlev/analysis_tests.py
ref_init("analysis_tests")
P <- "from simlev import analysis_tests as AT\n"
JH <- "AT = SL.AnalysisTests\n"   # Kopf des Julia-Codes (jl)
# seit 1.0.0: fit$model ist kein lm-Objekt mehr, sondern list(coefficients, fitted, degree, basis)
# table2d$n: Klasse table und benannte (leere) dimnames-Namen entfernen (reftree vergleicht dimnames als Liste)
LM <- "if (!is.null(sa$table2d)) { sa$table2d$n <- unclass(sa$table2d$n); dimnames(sa$table2d$n) <- unname(dimnames(sa$table2d$n)) }; sa"

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
ref_case("sa_err_col", "signal_analysis(small, 'Mom', 'aktien')", paste0(P, "result = AT.signal_analysis(small, 'Mom', 'aktien')"), list(small = small),
         jl = paste0(JH, 'result = AT.signal_analysis(small, "Mom", "aktien")'))
ref_case("sa_err_horizon", "signal_analysis(small, 'mom', 'aktien', horizon = 5000)", paste0(P, "result = AT.signal_analysis(small, 'mom', 'aktien', horizon=5000)"), list(small = small),
         jl = paste0(JH, 'result = AT.signal_analysis(small, "mom", "aktien"; horizon = 5000)'))
ref_case("sa_err_breaks", "signal_analysis(small, 'mom', 'aktien', breaks = 0)", paste0(P, "result = AT.signal_analysis(small, 'mom', 'aktien', breaks=0)"), list(small = small),
         jl = paste0(JH, 'result = AT.signal_analysis(small, "mom", "aktien"; breaks = 0)'))
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
ref_case("st_vec_na", "x <- ra; x[c(3, 10)] <- NA; y <- rb; y[20] <- Inf; sharpe_test(x, y)",
         paste0(P, "x = ra.copy(); x[[2, 9]] = simlev._r.fmt.NA_REAL; y = rb.copy(); y[19] = np.inf; result = AT.sharpe_test(x, y)"), I,
         jl = paste0(JH, 'x = copy(ra); x[[3, 10]] .= SL.NA; y = copy(rb); y[20] = Inf; result = AT.sharpe_test(x, y)'))
ref_case("st_identical_df", "sharpe_test(p[, c('date', 'a')], p[, c('date', 'a')], method = 'bootstrap')", paste0(P, PA, "result = AT.sharpe_test(pa, pa, method='bootstrap')"), I,
         jl = paste0(JH, 'pa = SL.RFrame("date" => p.date, "a" => p.a); pb = SL.RFrame("date" => p.date, "b" => p.b)
result = AT.sharpe_test(pa, pa; method = "bootstrap")'))
ref_case("st_df_offset", "q <- p[200:n, c('date', 'b')]; q$date <- q$date; sharpe_test(p[, c('date', 'a')], q[seq(1, nrow(q), 2), ], frequency = 'week')",
         paste0(P, PA, "q = p.iloc[199:][['date', 'b']]; result = AT.sharpe_test(pa, q.iloc[::2], frequency='week')"), I,
         jl = paste0(JH, 'pa = SL.RFrame("date" => p.date, "a" => p.a); pb = SL.RFrame("date" => p.date, "b" => p.b)
q = SL.RFrame("date" => p.date[200:end], "b" => p.b[200:end]); result = AT.sharpe_test(pa, SL.rows(q, 1:2:SL.nrow(q)); frequency = "week")'))
ref_case("st_err_var_x", "sharpe_test(rep(0.001, 500), ra[1:500])", paste0(P, "result = AT.sharpe_test(np.repeat(0.001, 500), ra[:500])"), I,
         jl = paste0(JH, 'result = AT.sharpe_test(fill(0.001, 500), ra[1:500])'))
ref_case("st_err_freq", "sharpe_test(ra, rb, frequency = 'year')", paste0(P, "result = AT.sharpe_test(ra, rb, frequency='year')"), I,
         jl = paste0(JH, 'result = AT.sharpe_test(ra, rb; frequency = "year")'))
ref_case("st_err_input", "sharpe_test(list(1), list(2))", paste0(P, "result = AT.sharpe_test({'a': 1}, {'b': 2})"), I,
         jl = paste0(JH, 'result = AT.sharpe_test(Any[1], Any[2])'))
SIM <- "sa = simlev.simulation(p[['date', 'a']], simlev.create_strategy(a=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)))\nsb = simlev.simulation(p[['date', 'b']], simlev.create_strategy(b=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)), dca=simlev.dca_plan(value=100, span=1))\n"

# ── .ret_from ───────────────────────────────────────────────────────────────
q <- p[c(1:40, 45:300), c("date", "a")]; q$a[c(5, 6)] <- NA

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
ref_case("rc_noseed", "simlev_seed(11); x <- overfit_reality_check(R[1:200, 1:3], B = 50, frequency = 'day'); list(x, SimLev:::.sl_runif(2))",
         paste0(P, "simlev.simlev_seed(11); x = AT.overfit_reality_check(R[:200, :3], B=50, frequency='day'); result = [x, simlev._lib.runif(2)]"), I,
         jl = paste0(JH, 'SL.simlev_seed(11); x = AT.overfit_reality_check(R[1:200, 1:3]; B = 50, frequency = "day"); result = Any[x, SL.SLib.runif(2)]'))
ref_case("rc_err_bench", "overfit_reality_check(R, benchmark = 'zz', B = 10, seed = 1)", paste0(P, "result = AT.overfit_reality_check(R, benchmark='zz', B=10, seed=1)"), I,
         jl = paste0(JH, 'result = AT.overfit_reality_check(R; benchmark = "zz", B = 10, seed = 1)'))

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

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul deep_analysis
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Referenzfälle für r/R/deep_analysis.R (result_analysis, print/summary, .da_*-Helfer)
# -> python/simlev/deep_analysis.py
ref_init("deep_analysis")
P <- "from simlev import deep_analysis as DA\n"
JH <- "DA = SL.DeepAnalysis\n"   # Kopf des Julia-Codes (jl)
SIM_J <- 'a = SL.simulation(d, SL.create_strategy("A" => SL.asset_config("etf", "bnh"; spread = 0)))
b = SL.simulation(d, SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.6, spread = 0.1), "B" => SL.asset_config("etf", "bnh", 0.4, spread = 0.1)); dca = SL.dca_plan(; value = 300, span = 1), rebalance = SL.rebalance_plan(; span = 1, unit = "year"))
'
ST_J <- 'st = SL.create_strategy("A" => SL.asset_config("etf", "bnh"; share = 1, spread = 0))\n'

set.seed(1); n <- 3 * 365 + 20
d <- data.frame(date = seq.Date(as.Date("2012-01-01"), by = "day", length.out = n))
d$A <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.010))
d$B <- 100 * cumprod(1 + rnorm(n, 1.5e-4, 0.004))
I <- list(d = d)
SIM_R <- "a <- simulation(d, create_strategy(A = asset_config('etf', 'bnh', spread = 0)))
b <- simulation(d, create_strategy(A = asset_config('etf', 'bnh', 0.6, spread = 0.1), B = asset_config('etf', 'bnh', 0.4, spread = 0.1)), dca = dca_plan(value = 300, span = 1), rebalance = rebalance_plan(span = 1, unit = 'year'))
"
SIM_P <- paste0(P, "a = simlev.simulation(d, simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', spread=0)))
b = simlev.simulation(d, simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=0.6, spread=0.1), B=simlev.asset_config(asset_class='etf', trading='bnh', share=0.4, spread=0.1)), dca=simlev.dca_plan(value=300, span=1), rebalance=simlev.rebalance_plan(span=1, unit='year'))
")
ref_case("da_sim_bench", paste0(SIM_R, "result_analysis(list(A = a, Mix = b), benchmark = 'A', risk_free = 1, rolling_years = 1)"),
         paste0(SIM_P, "result = DA.result_analysis({'A': a, 'Mix': b}, benchmark='A', risk_free=1, rolling_years=1)"), I,
         jl = paste0(JH, SIM_J, 'result = DA.result_analysis(SL.RList("A" => a, "Mix" => b); benchmark = "A", risk_free = 1, rolling_years = 1)'))
ref_case("da_sim_summary", paste0(SIM_R, "summary(result_analysis(list(A = a, Mix = b), benchmark = 'A', rolling_years = 1))"),
         paste0(SIM_P, "result = DA.result_analysis({'A': a, 'Mix': b}, benchmark='A', rolling_years=1).summary()"), I,
         jl = paste0(JH, SIM_J, 'result = SL.r_summary(DA.result_analysis(SL.RList("A" => a, "Mix" => b); benchmark = "A", rolling_years = 1))'))
ref_case("da_sim_self", paste0(SIM_R, "result_analysis(list(A = a, A2 = a), benchmark = 'A', rolling_years = 2)"),
         paste0(SIM_P, "result = DA.result_analysis({'A': a, 'A2': a}, benchmark='A', rolling_years=2)"), I,
         jl = paste0(JH, SIM_J, 'result = DA.result_analysis(SL.RList("A" => a, "A2" => a); benchmark = "A", rolling_years = 2)'))
ref_case("da_sim_df_bench_infl", paste0(SIM_R, "result_analysis(b, benchmark = d[, c('date', 'B')], inflation = 2, risk_free = 2, rolling_years = 0.5)"),
         paste0(SIM_P, "result = DA.result_analysis(b, benchmark=d[['date', 'B']], inflation=2, risk_free=2, rolling_years=0.5)"), I,
         jl = paste0(JH, SIM_J, 'result = DA.result_analysis(b; benchmark = SL.RFrame("date" => d.date, "B" => d.B), inflation = 2, risk_free = 2, rolling_years = 0.5)'))
ref_case("da_sim_nofilled", paste0(SIM_R, "a$filled <- NULL; result_analysis(a)"),
         paste0(SIM_P, "a.filled = None\nresult = DA.result_analysis(a)"), I,
         jl = paste0(JH, SIM_J, 'a = DA._without_filled(a)
result = DA.result_analysis(a)'))
# Kalendertage mit Luecken: Engine fuellt auf (filled), .da_series uebernimmt
td <- d[!format(d$date, "%u") %in% c("6", "7"), c("date", "A")]
ref_case("da_sim_trading", "r <- simulation(td, create_strategy(A = asset_config('etf', 'bnh', spread = 0)), dca = dca_plan(value = 100, span = 1)); result_analysis(r, risk_free = 3, rolling_years = 1)",
         paste0(P, "r = simlev.simulation(td, simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', spread=0)), dca=simlev.dca_plan(value=100, span=1))\nresult = DA.result_analysis(r, risk_free=3, rolling_years=1)"),
         list(td = td),
         jl = paste0(JH, 'r = SL.simulation(td, SL.create_strategy("A" => SL.asset_config("etf", "bnh"; spread = 0)); dca = SL.dca_plan(; value = 100, span = 1))
result = DA.result_analysis(r; risk_free = 3, rolling_years = 1)'))

# data.frame-Eingaben
x1 <- data.frame(date = d$date, value = d$A)
x2 <- data.frame(date = d$date[200:n], Kurs = d$B[200:n], Volumen = 1:(n - 199))
ref_case("da_df_single", "result_analysis(x1)", paste0(P, "result = DA.result_analysis(x1)"), list(x1 = x1),
         jl = paste0(JH, 'result = DA.result_analysis(x1)'))
ref_case("da_df_list_unnamed", "result_analysis(list(x1, x2), benchmark = 'S2', top_drawdowns = 3, var_levels = c(0.025, 0.2), rolling_years = 1)",
         paste0(P, "result = DA.result_analysis([x1, x2], benchmark='S2', top_drawdowns=3, var_levels=[0.025, 0.2], rolling_years=1)"), list(x1 = x1, x2 = x2),
         jl = paste0(JH, 'result = DA.result_analysis(Any[x1, x2]; benchmark = "S2", top_drawdowns = 3, var_levels = [0.025, 0.2], rolling_years = 1)'))
ref_case("da_df_list_partial", "result_analysis(list(a = x1, x2), rolling_years = 4)",
         paste0(P, "result = DA.result_analysis([x1, x2], rolling_years=4)"), list(x1 = x1, x2 = x2),
         jl = paste0(JH, 'result = DA.result_analysis(SL.RList("a" => x1, "" => x2); rolling_years = 4)'))
rf <- data.frame(date = as.Date(c("2012-01-01", "2013-06-01", "2014-01-01")), rate = c(0, 3, 1.5))
ref_case("da_df_rf_df", "result_analysis(list(X = x1, Y = x2), benchmark = x1, risk_free = rf, rolling_years = 1)",
         paste0(P, "result = DA.result_analysis({'X': x1, 'Y': x2}, benchmark=x1, risk_free=rf, rolling_years=1)"), list(x1 = x1, x2 = x2, rf = rf),
         jl = paste0(JH, 'result = DA.result_analysis(SL.RList("X" => x1, "Y" => x2); benchmark = x1, risk_free = rf, rolling_years = 1)'))
ref_case("da_df_rf_vec", "result_analysis(x1, risk_free = c('2012-01-01' = 1, '2013-01-01' = 2), inflation = 1.5, rolling_years = 1)",
         paste0(P, "result = DA.result_analysis(x1, risk_free=pd.Series({'2012-01-01': 1, '2013-01-01': 2}), inflation=1.5, rolling_years=1)"), list(x1 = x1),
         jl = paste0(JH, 'result = DA.result_analysis(x1; risk_free = SL.named("2012-01-01" => 1.0, "2013-01-01" => 2.0), inflation = 1.5, rolling_years = 1)'))
cpi <- data.frame(date = seq.Date(as.Date("2011-12-01"), by = "month", length.out = 48), value = 100 * 1.003^(0:47))
ref_case("da_df_cpi", "result_analysis(list(X = x1, Y = x2), benchmark = 'X', inflation = cpi, risk_free = 2, rolling_years = 1)",
         paste0(P, "result = DA.result_analysis({'X': x1, 'Y': x2}, benchmark='X', inflation=cpi, risk_free=2, rolling_years=1)"), list(x1 = x1, x2 = x2, cpi = cpi),
         jl = paste0(JH, 'result = DA.result_analysis(SL.RList("X" => x1, "Y" => x2); benchmark = "X", inflation = cpi, risk_free = 2, rolling_years = 1)'))
ref_case("da_df_cpi_vec", "result_analysis(x2, inflation = setNames(cpi$value, format(cpi$date)), rolling_years = 1)",
         paste0(P, "result = DA.result_analysis(x2, inflation=pd.Series(cpi['value'].to_numpy(), index=np.datetime_as_string(cpi['date'].to_numpy())), rolling_years=1)"), list(x2 = x2, cpi = cpi),
         jl = paste0(JH, 'result = DA.result_analysis(x2; inflation = SL.RVector(cpi.value; names = string.(cpi.date)), rolling_years = 1)'))
# Handelstage, series_align (attr filled), unsortiert, doppelt, NA innen, Text-Datum
tdv <- data.frame(date = td$date, value = td$A)
ref_case("da_df_trading", "result_analysis(tdv, risk_free = 4, rolling_years = 1)", paste0(P, "result = DA.result_analysis(tdv, risk_free=4, rolling_years=1)"), list(tdv = tdv),
         jl = paste0(JH, 'result = DA.result_analysis(tdv; risk_free = 4, rolling_years = 1)'))
ref_case("da_df_aligned", "al <- series_align(value = tdv); result_analysis(list(al = al, raw = tdv), benchmark = 'raw', risk_free = 4, rolling_years = 1)",
         paste0(P, "from simlev.data_prep import series_align\nal = series_align(value=tdv)\nresult = DA.result_analysis({'al': al, 'raw': tdv}, benchmark='raw', risk_free=4, rolling_years=1)"), list(tdv = tdv),
         jl = paste0(JH, 'al = SL.DataPrep.series_align(value = tdv)
result = DA.result_analysis(SL.RList("al" => al, "raw" => tdv); benchmark = "raw", risk_free = 4, rolling_years = 1)'))
xm <- x1[c(n:1, 100, 500, 900), ]; xm$value[c(n - 99, n - 499)] <- xm$value[c(n - 99, n - 499)] * 1.05
xm$value[c(10, 11, 12, 300)] <- NA; xm$value[1:3] <- NA; xm$date <- format(xm$date)
ref_case("da_df_messy", "result_analysis(xm, rolling_years = 1)", paste0(P, "result = DA.result_analysis(xm, rolling_years=1)"), list(xm = xm),
         jl = paste0(JH, 'result = DA.result_analysis(xm; rolling_years = 1)'))
mo <- data.frame(date = seq.Date(as.Date("1791-01-31"), by = "month", length.out = 120)); set.seed(2); mo$v <- 100 * cumprod(1 + rnorm(120, 0.004, 0.03))
ref_case("da_df_monthly_old", "result_analysis(transform(mo, date = format(date)), rolling_years = 2)", paste0(P, "result = DA.result_analysis(mo.assign(date=np.datetime_as_string(mo['date'].to_numpy())), rolling_years=2)"), list(mo = mo),
         jl = paste0(JH, 'result = DA.result_analysis(SL.RFrame("date" => string.(mo.date), "v" => mo.v); rolling_years = 2)'))
ref_case("da_short_series", "result_analysis(list(k = x1[1:40, ], l = x1[20:60, ]), benchmark = 'k', rolling_years = 1)",
         paste0(P, "result = DA.result_analysis({'k': x1.iloc[:40], 'l': x1.iloc[19:60]}, benchmark='k', rolling_years=1)"), list(x1 = x1),
         jl = paste0(JH, 'result = DA.result_analysis(SL.RList("k" => SL.rows(x1, 1:40), "l" => SL.rows(x1, 20:60)); benchmark = "k", rolling_years = 1)'))
ref_case("da_print_infl", "result_analysis(list(a = x1, b = x2), benchmark = 'a', inflation = 2.5)",
         paste0(P, "result = DA.result_analysis({'a': x1, 'b': x2}, benchmark='a', inflation=2.5)"), list(x1 = x1, x2 = x2),
         jl = paste0(JH, 'result = DA.result_analysis(SL.RList("a" => x1, "b" => x2); benchmark = "a", inflation = 2.5)'))
ref_case("da_summary_df", "summary(result_analysis(list(lang_name_fuer_breite = x1, b = x2)))",
         paste0(P, "result = DA.result_analysis({'lang_name_fuer_breite': x1, 'b': x2}).summary()"), list(x1 = x1, x2 = x2),
         jl = paste0(JH, 'result = SL.r_summary(DA.result_analysis(SL.RList("lang_name_fuer_breite" => x1, "b" => x2)))'))
up <- data.frame(date = d$date[1:500], value = 100 * 1.0004^(0:499))
ref_case("da_no_drawdown", "result_analysis(list(up = up, x = x1[1:500, ]), benchmark = 'up', rolling_years = 1)",
         paste0(P, "result = DA.result_analysis({'up': up, 'x': x1.iloc[:500]}, benchmark='up', rolling_years=1)"), list(up = up, x1 = x1),
         jl = paste0(JH, 'result = DA.result_analysis(SL.RList("up" => up, "x" => SL.rows(x1, 1:500)); benchmark = "up", rolling_years = 1)'))
ref_case("da_summary_nodd", "summary(result_analysis(list(up = up, x = x1[1:500, ]), benchmark = x1, rolling_years = 1))",
         paste0(P, "result = DA.result_analysis({'up': up, 'x': x1.iloc[:500]}, benchmark=x1, rolling_years=1).summary()"), list(up = up, x1 = x1),
         jl = paste0(JH, 'result = SL.r_summary(DA.result_analysis(SL.RList("up" => up, "x" => SL.rows(x1, 1:500)); benchmark = x1, rolling_years = 1))'))
ref_case("da_sim_tax_bench_obj", paste0(SIM_R, "t <- simulation(d, create_strategy(A = asset_config('etf', 'bnh', 0.5, spread = 0.1), B = asset_config('etf', 'bnh', 0.5, spread = 0.1)), start_value = 1e6, rebalance = rebalance_plan(span = 1, unit = 'quarter'), tax = tax_profile(), liquidate = TRUE)
  x <- result_analysis(list(tax = t, a = a), benchmark = b, rolling_years = 1.5, top_drawdowns = 4); x$metrics[c('taxes', 'trades_per_year'), ]; x"),
         paste0(SIM_P, "t = simlev.simulation(d, simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1), B=simlev.asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1)), start_value=1e6, rebalance=simlev.rebalance_plan(span=1, unit='quarter'), tax=simlev.tax_profile(), liquidate=True)
result = DA.result_analysis({'tax': t, 'a': a}, benchmark=b, rolling_years=1.5, top_drawdowns=4)"), I,
         jl = paste0(JH, SIM_J, 't = SL.simulation(d, SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.5, spread = 0.1), "B" => SL.asset_config("etf", "bnh", 0.5, spread = 0.1)); start_value = 1e6, rebalance = SL.rebalance_plan(; span = 1, unit = "quarter"), tax = SL.tax_profile(), liquidate = true)
result = DA.result_analysis(SL.RList("tax" => t, "a" => a); benchmark = b, rolling_years = 1.5, top_drawdowns = 4)'))
# Extremfaelle der MWRR: Beinahe-Totalverlust und sehr hohe Rendite mit Sparplan
dd1 <- seq.Date(as.Date("2020-01-01"), as.Date("2023-12-31"), by = "day"); p1 <- rep(100, length(dd1)); p1[dd1 >= as.Date("2023-12-20")] <- 1e-3
dd2 <- seq.Date(as.Date("2020-01-01"), as.Date("2020-03-31"), by = "day"); p2 <- 100 * 3^(seq_along(dd2) / length(dd2))
ex <- list(e1 = data.frame(date = dd1, A = p1), e2 = data.frame(date = dd2, A = p2))
ST <- "st = simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=1, spread=0))\n"
ref_case("da_mwrr_extreme", "st <- create_strategy(A = asset_config('etf', 'bnh', share = 1, spread = 0))
  r1 <- suppressWarnings(simulation(ex$e1, st, start_value = 1000, dca = dca_plan(value = 100, span = 1)))
  r2 <- suppressWarnings(simulation(ex$e2, st, start_value = 1000, dca = dca_plan(value = 100, span = 1)))
  r3 <- simulation(ex$e2, st, start_value = 1000)
  list(result_analysis(r1)$metrics[, 1], result_analysis(r2)$metrics[, 1], result_analysis(r3, inflation = 3)$metrics[, 1], c(r1$cagr, r2$cagr, r3$cagr))",
  paste0(P, ST, "import warnings\nwith warnings.catch_warnings():\n    warnings.simplefilter('ignore')\n    r1 = simlev.simulation(ex['e1'], st, start_value=1000, dca=simlev.dca_plan(value=100, span=1))\n    r2 = simlev.simulation(ex['e2'], st, start_value=1000, dca=simlev.dca_plan(value=100, span=1))\nr3 = simlev.simulation(ex['e2'], st, start_value=1000)\nresult = [DA.result_analysis(r1)['metrics'].iloc[:, 0], DA.result_analysis(r2)['metrics'].iloc[:, 0], DA.result_analysis(r3, inflation=3)['metrics'].iloc[:, 0], [r1.cagr, r2.cagr, r3.cagr]]"),
  list(ex = ex),
         jl = paste0(JH, ST_J, 'import Logging
r1, r2 = Logging.with_logger(Logging.NullLogger()) do
    (SL.simulation(ex.e1, st; start_value = 1000, dca = SL.dca_plan(; value = 100, span = 1)),
     SL.simulation(ex.e2, st; start_value = 1000, dca = SL.dca_plan(; value = 100, span = 1)))
end
r3 = SL.simulation(ex.e2, st; start_value = 1000)
result = Any[DA.result_analysis(r1)["metrics"][:, 1], DA.result_analysis(r2)["metrics"][:, 1], DA.result_analysis(r3; inflation = 3)["metrics"][:, 1], [r1.cagr, r2.cagr, r3.cagr]]'))
ref_case("da_err_rf_col", "result_analysis(x1, risk_free = 'zins')", paste0(P, "result = DA.result_analysis(x1, risk_free='zins')"), list(x1 = x1),
         jl = paste0(JH, 'result = DA.result_analysis(x1; risk_free = "zins")'))
ref_case("da_err_rf_len", "result_analysis(x1, risk_free = c(1, 2))", paste0(P, "result = DA.result_analysis(x1, risk_free=[1, 2])"), list(x1 = x1),
         jl = paste0(JH, 'result = DA.result_analysis(x1; risk_free = [1, 2])'))
ref_case("da_bench_self_only", "result_analysis(x1[1:400, ], benchmark = 'Strategie', var_levels = 0.05)", paste0(P, "result = DA.result_analysis(x1.iloc[:400], benchmark='Strategie', var_levels=0.05)"), list(x1 = x1),
         jl = paste0(JH, 'result = DA.result_analysis(SL.rows(x1, 1:400); benchmark = "Strategie", var_levels = 0.05)'))
# interne Helfer
ref_case("da_drawdowns", "v <- c(1, 2, 1.5, 1.8, 2.5, 2.4, 2.6, 2, 1); dt <- as.Date('2020-01-01') + c(0:5, 8, 9, 30); list(SimLev:::.da_drawdowns(dt, v), SimLev:::.da_drawdowns(dt, v, 2), SimLev:::.da_drawdowns(dt, cumsum(1:9)))",
         paste0(P, "v = np.array([1, 2, 1.5, 1.8, 2.5, 2.4, 2.6, 2, 1]); dt = np.datetime64('2020-01-01') + np.array([0, 1, 2, 3, 4, 5, 8, 9, 30])\nresult = [DA._da_drawdowns(dt, v), DA._da_drawdowns(dt, v, 2), DA._da_drawdowns(dt, np.cumsum(np.arange(1.0, 10)))]"),
         jl = paste0(JH, 'v = [1, 2, 1.5, 1.8, 2.5, 2.4, 2.6, 2, 1]; dt = Date(2020, 1, 1) .+ Day.([0, 1, 2, 3, 4, 5, 8, 9, 30])
result = Any[DA._da_drawdowns(dt, v), DA._da_drawdowns(dt, v, 2), DA._da_drawdowns(dt, cumsum(1.0:9.0))]'))
ref_case("da_rf", "dt <- as.Date('2020-01-01') + c(0, 1, 3, 4, 10, 40); list(SimLev:::.da_rf(dt, c(1, 1, 2, 2, 3, 3), c(1L, 3L, 6L)), SimLev:::.da_rf(dt, rep(2, 6), 1:6, defl = 1.001^(0:5)))",
         paste0(P, "dt = np.datetime64('2020-01-01') + np.array([0, 1, 3, 4, 10, 40])\nresult = [DA._da_rf(dt, np.array([1, 1, 2, 2, 3, 3.0]), np.array([0, 2, 5])), DA._da_rf(dt, np.repeat(2.0, 6), np.arange(6), defl=np.array([simlev._r.rnum.r_pow(1.001, k) for k in range(6)]))]"),
         jl = paste0(JH, 'dt = Date(2020, 1, 1) .+ Day.([0, 1, 3, 4, 10, 40])
result = Any[DA._da_rf(dt, [1, 1, 2, 2, 3, 3.0], [1, 3, 6]), DA._da_rf(dt, fill(2.0, 6), 1:6, [SL.r_pow(1.001, k) for k in 0:5])]'))
# Fehler
ref_case("da_err_nodate", "result_analysis(data.frame(datum = d$date, v = d$A))", paste0(P, "result = DA.result_analysis(pd.DataFrame({'datum': d['date'], 'v': d['A']}))"), I,
         jl = paste0(JH, 'result = DA.result_analysis(SL.RFrame("datum" => d.date, "v" => d.A))'))
ref_case("da_err_nonum", "result_analysis(data.frame(date = d$date[1:5], v = letters[1:5]))", paste0(P, "result = DA.result_analysis(pd.DataFrame({'date': d['date'][:5], 'v': list('abcde')}))"), I,
         jl = paste0(JH, 'result = DA.result_analysis(SL.RFrame("date" => d.date[1:5], "v" => ["a", "b", "c", "d", "e"]))'))
ref_case("da_err_value_chr", "result_analysis(data.frame(date = d$date[1:5], value = letters[1:5]))", paste0(P, "result = DA.result_analysis(pd.DataFrame({'date': d['date'][:5], 'value': list('abcde')}))"), I,
         jl = paste0(JH, 'result = DA.result_analysis(SL.RFrame("date" => d.date[1:5], "value" => ["a", "b", "c", "d", "e"]))'))
ref_case("da_err_value_lgl", "result_analysis(data.frame(date = d$date[1:5], value = TRUE))", paste0(P, "result = DA.result_analysis(pd.DataFrame({'date': d['date'][:5], 'value': True}))"), I,
         jl = paste0(JH, 'result = DA.result_analysis(SL.RFrame("date" => d.date[1:5], "value" => fill(true, 5)))'))
ref_case("da_err_text_num", "result_analysis(data.frame(date = d$date[1:5], value = c('1,5', '2,5', '3,1', '4', '5')))",
         paste0(P, "result = DA.result_analysis(pd.DataFrame({'date': d['date'][:5], 'value': ['1,5', '2,5', '3,1', '4', '5']}))"), I,
         jl = paste0(JH, 'result = DA.result_analysis(SL.RFrame("date" => d.date[1:5], "value" => ["1,5", "2,5", "3,1", "4", "5"]))'))
ref_case("da_err_text_kurs", "result_analysis(data.frame(date = d$date[1:5], Kurs = c('1,5', '2,5', '3,1', '4', '5'), Vol = 1:5))",
         paste0(P, "result = DA.result_analysis(pd.DataFrame({'date': d['date'][:5], 'Kurs': ['1,5', '2,5', '3,1', '4', '5'], 'Vol': np.arange(1, 6)}))"), I,
         jl = paste0(JH, 'result = DA.result_analysis(SL.RFrame("date" => d.date[1:5], "Kurs" => ["1,5", "2,5", "3,1", "4", "5"], "Vol" => collect(1:5)))'))
ref_case("da_err_factor", "result_analysis(data.frame(date = d$date[1:5], value = factor(c('1,5', '2,5', '3,1', '4', '5'))))",
         paste0(P, "result = DA.result_analysis(pd.DataFrame({'date': d['date'][:5], 'value': pd.Categorical(['1,5', '2,5', '3,1', '4', '5'])}))"), I,
         jl = paste0(JH, 'result = DA.result_analysis(SL.RFrame("date" => d.date[1:5], "value" => ["1,5", "2,5", "3,1", "4", "5"]))'))
ref_case("da_err_novalues", "result_analysis(data.frame(date = d$date[1:5], value = NA_real_))", paste0(P, "result = DA.result_analysis(pd.DataFrame({'date': d['date'][:5], 'value': simlev._r.fmt.NA_REAL}))"), I,
         jl = paste0(JH, 'result = DA.result_analysis(SL.RFrame("date" => d.date[1:5], "value" => fill(SL.NA, 5)))'))
ref_case("da_err_nonpos", "z <- x1; z$value[100] <- 0; result_analysis(z)", paste0(P, "z = x1.copy(); z.loc[99, 'value'] = 0.0\nresult = DA.result_analysis(z)"), list(x1 = x1),
         jl = paste0(JH, 'z = copy(x1); z.value[100] = 0.0
result = DA.result_analysis(z)'))
ref_case("da_err_one", "result_analysis(x1[1, ])", paste0(P, "result = DA.result_analysis(x1.iloc[:1])"), list(x1 = x1),
         jl = paste0(JH, 'result = DA.result_analysis(SL.rows(x1, 1:1))'))
ref_case("da_err_short", "result_analysis(x1[1:2, ])", paste0(P, "result = DA.result_analysis(x1.iloc[:2])"), list(x1 = x1),
         jl = paste0(JH, 'result = DA.result_analysis(SL.rows(x1, 1:2))'))
ref_case("da_err_num", "result_analysis(1:10)", paste0(P, "result = DA.result_analysis(np.arange(1, 11))"),
         jl = paste0(JH, 'result = DA.result_analysis(collect(1:10))'))
ref_case("da_err_bench_name", "result_analysis(list(a = x1, b = x1), benchmark = 'c')", paste0(P, "result = DA.result_analysis({'a': x1, 'b': x1}, benchmark='c')"), list(x1 = x1),
         jl = paste0(JH, 'result = DA.result_analysis(SL.RList("a" => x1, "b" => x1); benchmark = "c")'))
ref_case("da_err_bench_exists", "result_analysis(list(Strategie = x1, Benchmark = x1), benchmark = x1)", paste0(P, "result = DA.result_analysis({'Strategie': x1, 'Benchmark': x1}, benchmark=x1)"), list(x1 = x1),
         jl = paste0(JH, 'result = DA.result_analysis(SL.RList("Strategie" => x1, "Benchmark" => x1); benchmark = x1)'))
ref_case("da_err_bench_common", "b2 <- x1; b2$date <- b2$date + 3000; result_analysis(x1, benchmark = b2)",
         paste0(P, "b2 = x1.assign(date=x1['date'] + pd.Timedelta(days=3000))\nresult = DA.result_analysis(x1, benchmark=b2)"), list(x1 = x1),
         jl = paste0(JH, 'b2 = copy(x1); b2.date = b2.date .+ Day(3000)
result = DA.result_analysis(x1; benchmark = b2)'))
ref_case("da_err_rolling", "result_analysis(x1, rolling_years = 0)", paste0(P, "result = DA.result_analysis(x1, rolling_years=0)"), list(x1 = x1),
         jl = paste0(JH, 'result = DA.result_analysis(x1; rolling_years = 0)'))
ref_case("da_err_rolling2", "result_analysis(x1, rolling_years = c(1, 2))", paste0(P, "result = DA.result_analysis(x1, rolling_years=[1, 2])"), list(x1 = x1),
         jl = paste0(JH, 'result = DA.result_analysis(x1; rolling_years = [1, 2])'))
ref_case("da_err_var", "result_analysis(x1, var_levels = c(0.05, 1))", paste0(P, "result = DA.result_analysis(x1, var_levels=[0.05, 1])"), list(x1 = x1),
         jl = paste0(JH, 'result = DA.result_analysis(x1; var_levels = [0.05, 1])'))
ref_case("da_err_cpi_late", "result_analysis(x1, inflation = cpi[cpi$date >= as.Date('2013-01-01'), ])",
         paste0(P, "result = DA.result_analysis(x1, inflation=cpi[cpi['date'] >= np.datetime64('2013-01-01')])"), list(x1 = x1, cpi = cpi),
         jl = paste0(JH, 'result = DA.result_analysis(x1; inflation = SL.rows(cpi, cpi.date .>= Date(2013, 1, 1)))'))
ref_case("da_err_date_fmt", "result_analysis(data.frame(date = format(d$date[1:50], '%d.%m.%Y'), value = d$A[1:50]))",
         paste0(P, "result = DA.result_analysis(pd.DataFrame({'date': pd.to_datetime(d['date'][:50]).dt.strftime('%d.%m.%Y'), 'value': d['A'][:50]}))"), I,
         jl = paste0(JH, 'result = DA.result_analysis(SL.RFrame("date" => Dates.format.(d.date[1:50], "dd.mm.yyyy"), "value" => d.A[1:50]))'))
ref_case("da_err_plot_series", "pdf(NULL); on.exit(dev.off()); plot(result_analysis(x1[1:400, ]), type = 'monthly', series = 3)",
         paste0(P, "result = DA.result_analysis(x1.iloc[:400]).plot(type='monthly', series=3)"), list(x1 = x1),
         jl = paste0(JH, 'result = SL.r_plot(DA.result_analysis(SL.rows(x1, 1:400)); type = "monthly", series = 3, file = nothing)'))
ref_case("da_err_plot_metric", "pdf(NULL); on.exit(dev.off()); plot(result_analysis(x1[1:400, ]), metric = 'x')",
         paste0(P, "result = DA.result_analysis(x1.iloc[:400]).plot(metric='x')"), list(x1 = x1),
         jl = paste0(JH, 'result = SL.r_plot(DA.result_analysis(SL.rows(x1, 1:400)); metric = "x", file = nothing)'))
ref_done()

ref_schreiben()
