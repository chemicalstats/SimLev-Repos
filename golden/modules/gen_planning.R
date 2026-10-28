# Referenzfälle für r/R/planning.R (series_shift_return, .period_gross, bootstrap_pooled,
# portfolio_returns, planning_goal, print.SimLevGoalPlan) -> python/simlev/planning.py
source("golden/modules/ref_tools.R"); ref_init("planning")
P <- "from simlev import planning as PL\nfrom simlev._r import rng as RNG\n"
JH <- "PL = SL.Planning\n"   # Kopf des Julia-Codes (jl)
SH <- function(call) sprintf("x <- %s; list(data = x, shift = attr(x, 'shift'))", call)
PSH <- function(call) paste0(P, sprintf("x = %s\nresult = {'data': x, 'shift': x.attrs['shift']}", call))

# ── series_shift_return ─────────────────────────────────────────────────────
set.seed(1)
d <- data.frame(date = seq.Date(as.Date("2000-01-01"), by = "day", length.out = 1500))
d$us <- exp(rnorm(1500, 3e-4, 0.01)); d$eu <- exp(rnorm(1500, 1e-4, 0.012)); d$x <- 1
pr <- data.frame(date = d$date, us = 100 * cumprod(d$us), eu = 100 * cumprod(d$eu))
set.seed(2); o <- sample(nrow(pr)); prs <- pr[o, ]
dn <- d; dn$us[c(3, 700)] <- NA
I <- list(d = d, pr = pr, prs = prs, dn = dn)
ref_case("ser_ret", SH("series_shift_return(d, 'us', 4)"), PSH("PL.series_shift_return(d, 'us', 4)"), I,
         jl = paste0(JH, 'x = PL.series_shift_return(d, "us", 4)
result = SL.RList("data" => x, "shift" => SL.attrs(x)["shift"])'))
ref_case("ser_named", SH("series_shift_return(d, c('us', 'eu'), c(eu = 3, us = 5))"), PSH("PL.series_shift_return(d, ['us', 'eu'], pd.Series({'eu': 3, 'us': 5}))"), I,
         jl = paste0(JH, 'x = PL.series_shift_return(d, ["us", "eu"], SL.named("eu" => 3, "us" => 5))
result = SL.RList("data" => x, "shift" => SL.attrs(x)["shift"])'))
ref_case("ser_two_scalar", SH("series_shift_return(d, c('eu', 'us'), -1.5, ppy = 250)"), PSH("PL.series_shift_return(d, ['eu', 'us'], -1.5, ppy=250)"), I,
         jl = paste0(JH, 'x = PL.series_shift_return(d, ["eu", "us"], -1.5; ppy = 250)
result = SL.RList("data" => x, "shift" => SL.attrs(x)["shift"])'))
ref_case("ser_prices", SH("series_shift_return(pr, c('us', 'eu'), 6, type = 'prices')"), PSH("PL.series_shift_return(pr, ['us', 'eu'], 6, type='prices')"), I,
         jl = paste0(JH, 'x = PL.series_shift_return(pr, ["us", "eu"], 6; type = "prices")
result = SL.RList("data" => x, "shift" => SL.attrs(x)["shift"])'))
ref_case("ser_prices_unsorted", SH("series_shift_return(prs, 'us', 4, type = 'prices')"), PSH("PL.series_shift_return(prs, 'us', 4, type='prices')"), I,
         jl = paste0(JH, 'x = PL.series_shift_return(prs, "us", 4; type = "prices")
result = SL.RList("data" => x, "shift" => SL.attrs(x)["shift"])'))
ref_case("ser_nodate", SH("series_shift_return(d[, c('us', 'eu')], 'eu', 2)"), PSH("PL.series_shift_return(d[['us', 'eu']], 'eu', 2)"), I,
         jl = paste0(JH, 'x = PL.series_shift_return(SL.RFrame("us" => d.us, "eu" => d.eu), "eu", 2)
result = SL.RList("data" => x, "shift" => SL.attrs(x)["shift"])'))
ref_case("ser_nodate_prices", SH("series_shift_return(pr[1:300, c('us', 'eu')], 'eu', 2, 'prices', ppy = 12)"), PSH("PL.series_shift_return(pr.iloc[:300][['us', 'eu']], 'eu', 2, type='prices', ppy=12)"), I,
         jl = paste0(JH, 'x = PL.series_shift_return(SL.RFrame("us" => pr.us[1:300], "eu" => pr.eu[1:300]), "eu", 2; type = "prices", ppy = 12)
result = SL.RList("data" => x, "shift" => SL.attrs(x)["shift"])'))
ref_case("ser_na", SH("series_shift_return(dn, 'us', 0)"), PSH("PL.series_shift_return(dn, 'us', 0)"), I,
         jl = paste0(JH, 'x = PL.series_shift_return(dn, "us", 0)
result = SL.RList("data" => x, "shift" => SL.attrs(x)["shift"])'))
ref_case("ser_chr_date", "x <- series_shift_return(transform(d[1:200, ], date = format(date)), 'us', 3); x$date <- as.Date(x$date); list(data = x, shift = attr(x, 'shift'))",
         paste0(P, "x = PL.series_shift_return(d.iloc[:200].assign(date=np.datetime_as_string(d['date'].to_numpy()[:200])), 'us', 3)\nresult = {'data': x.assign(date=pd.to_datetime(x['date'])), 'shift': x.attrs['shift']}"), I,
         jl = paste0(JH, 'd2 = SL.rows(d, 1:200); d2.date = string.(d2.date)
x = PL.series_shift_return(d2, "us", 3); x.date = Date.(x.date)
result = SL.RList("data" => x, "shift" => SL.attrs(x)["shift"])'))
ref_case("ser_err_df", "series_shift_return(as.matrix(d[, 2:3]), 'us', 4)", paste0(P, "result = PL.series_shift_return(d[['us', 'eu']].to_numpy(), 'us', 4)"), I,
         jl = paste0(JH, 'result = PL.series_shift_return(hcat(d.us, d.eu), "us", 4)'))
ref_case("ser_err_col", "series_shift_return(d, c('us', 'jp', 'cn'), 4)", paste0(P, "result = PL.series_shift_return(d, ['us', 'jp', 'cn'], 4)"), I,
         jl = paste0(JH, 'result = PL.series_shift_return(d, ["us", "jp", "cn"], 4)'))
ref_case("ser_err_target", "series_shift_return(d, 'us', '4')", paste0(P, "result = PL.series_shift_return(d, 'us', '4')"), I,
         jl = paste0(JH, 'result = PL.series_shift_return(d, "us", "4")'))
ref_case("ser_err_target_na", "series_shift_return(d, 'us', NA_real_)", paste0(P, "result = PL.series_shift_return(d, 'us', simlev._r.fmt.NA_REAL)"), I,
         jl = paste0(JH, 'result = PL.series_shift_return(d, "us", SL.NA)'))
ref_case("ser_err_named", "series_shift_return(data.frame(us = rep(1.001, 10), eu = 1.001), c('us', 'eu'), c(us = 4))",
         paste0(P, "result = PL.series_shift_return(pd.DataFrame({'us': np.repeat(1.001, 10), 'eu': 1.001}), ['us', 'eu'], pd.Series({'us': 4}))"),
         jl = paste0(JH, 'result = PL.series_shift_return(SL.RFrame("us" => fill(1.001, 10), "eu" => fill(1.001, 10)), ["us", "eu"], SL.named("us" => 4))'))
ref_case("ser_err_unnamed", "series_shift_return(d, c('us', 'eu'), c(4, 5))", paste0(P, "result = PL.series_shift_return(d, ['us', 'eu'], [4, 5])"), I,
         jl = paste0(JH, 'result = PL.series_shift_return(d, ["us", "eu"], [4, 5])'))
ref_case("ser_err_dup", "series_shift_return(rbind(pr[1:10, ], pr[5, ]), 'us', 4, type = 'prices')", paste0(P, "result = PL.series_shift_return(pd.concat([pr.iloc[:10], pr.iloc[[4]]]), 'us', 4, type='prices')"), I,
         jl = paste0(JH, 'result = PL.series_shift_return(SL.rows(pr, [1:10; 5]), "us", 4; type = "prices")'))
ref_case("ser_err_type", "series_shift_return(d, 'us', 4, type = 'level')", paste0(P, "result = PL.series_shift_return(d, 'us', 4, type='level')"), I,
         jl = paste0(JH, 'result = PL.series_shift_return(d, "us", 4; type = "level")'))

# ── .period_gross ───────────────────────────────────────────────────────────
pg <- pr[seq(1, 1500, 3), ]; pg$us[c(1, 2, 40)] <- NA
ref_case("period_gross", "list(SimLev:::.period_gross(pg, c('us', 'eu'), 'month'), SimLev:::.period_gross(pg, 'eu', 'quarter'), SimLev:::.period_gross(pg, c('eu', 'us'), 'year'))",
         paste0(P, "result = [PL._period_gross(pg, ['us', 'eu'], 'month'), PL._period_gross(pg, ['eu'], 'quarter'), PL._period_gross(pg, ['eu', 'us'], 'year')]"), list(pg = pg),
         jl = paste0(JH, 'result = Any[PL._period_gross(pg, ["us", "eu"], "month"), PL._period_gross(pg, "eu", "quarter"), PL._period_gross(pg, ["eu", "us"], "year")]'))

# ── bootstrap_pooled ────────────────────────────────────────────────────────
set.seed(1)
land <- function(mu, n = 70) {
  d <- data.frame(date = seq.Date(as.Date("1950-12-31"), by = "year", length.out = n))
  d$aktien <- 100 * cumprod(exp(rnorm(n, mu, 0.18)))
  d$anleihen <- 100 * cumprod(exp(rnorm(n, 0.02, 0.06)))
  d$cpi <- 100 * cumprod(exp(rnorm(n, 0.025, 0.02)))
  d
}
ds <- list(de = land(0.05), us = land(0.07), jp = land(0.03, 40))
mland <- function(mu, n = 240) {
  d <- data.frame(date = seq.Date(as.Date("1990-01-31"), by = "month", length.out = n))
  d$aktien <- 100 * cumprod(exp(rnorm(n, mu / 12, 0.05))); d$anleihen <- 100 * cumprod(exp(rnorm(n, 0.002, 0.01)))
  d$cpi <- 100 * cumprod(exp(rnorm(n, 0.002, 0.003))); d
}
dm <- list(a = mland(0.06), b = mland(0.02, 180))
dm$b$aktien[c(5, 6)] <- NA
I <- list(ds = ds, dm = dm)
ref_case("pb_ex", "bootstrap_pooled(ds[1:2], c('aktien', 'anleihen'), weights = c(aktien = 0.6, anleihen = 0.4), inflation = 'cpi', n = 50, years = 30, L = 5, seed = 1)",
         paste0(P, "result = PL.bootstrap_pooled({k: ds[k] for k in ['de', 'us']}, ['aktien', 'anleihen'], weights=pd.Series({'aktien': 0.6, 'anleihen': 0.4}), inflation='cpi', n=50, years=30, L=5, seed=1)"), I,
         jl = paste0(JH, 'result = PL.bootstrap_pooled(SL.RList("de" => ds.de, "us" => ds.us), ["aktien", "anleihen"]; weights = SL.named("aktien" => 0.6, "anleihen" => 0.4), inflation = "cpi", n = 50, years = 30, L = 5, seed = 1)'))
ref_case("pb_default", "bootstrap_pooled(ds, 'aktien', n = 20, seed = 2)", paste0(P, "result = PL.bootstrap_pooled(ds, 'aktien', n=20, seed=2)"), I,
         jl = paste0(JH, 'result = PL.bootstrap_pooled(ds, "aktien"; n = 20, seed = 2)'))
ref_case("pb_unnamed_w", "bootstrap_pooled(ds, c('aktien', 'anleihen'), weights = c(3, 1), n = 10, years = 12, L = 2.5, country_weights = c(1, 2, 1), seed = 3)",
         paste0(P, "result = PL.bootstrap_pooled(ds, ['aktien', 'anleihen'], weights=[3, 1], n=10, years=12, L=2.5, country_weights=[1, 2, 1], seed=3)"), I,
         jl = paste0(JH, 'result = PL.bootstrap_pooled(ds, ["aktien", "anleihen"]; weights = [3, 1], n = 10, years = 12, L = 2.5, country_weights = [1, 2, 1], seed = 3)'))
ref_case("pb_target", "bootstrap_pooled(ds, c('aktien', 'anleihen'), weights = c(anleihen = 0.5, aktien = 0.5), n = 15, years = 20, L = 4, target = 4, inflation = 'cpi', seed = 4)",
         paste0(P, "result = PL.bootstrap_pooled(ds, ['aktien', 'anleihen'], weights=pd.Series({'anleihen': 0.5, 'aktien': 0.5}), n=15, years=20, L=4, target=4, inflation='cpi', seed=4)"), I,
         jl = paste0(JH, 'result = PL.bootstrap_pooled(ds, ["aktien", "anleihen"]; weights = SL.named("anleihen" => 0.5, "aktien" => 0.5), n = 15, years = 20, L = 4, target = 4, inflation = "cpi", seed = 4)'))
ref_case("pb_target_named", "bootstrap_pooled(ds, c('aktien', 'anleihen'), n = 15, years = 10, L = 3, target = c(aktien = 5), seed = 5)",
         paste0(P, "result = PL.bootstrap_pooled(ds, ['aktien', 'anleihen'], n=15, years=10, L=3, target=pd.Series({'aktien': 5}), seed=5)"), I,
         jl = paste0(JH, 'result = PL.bootstrap_pooled(ds, ["aktien", "anleihen"]; n = 15, years = 10, L = 3, target = SL.named("aktien" => 5), seed = 5)'))
ref_case("pb_quarter", "bootstrap_pooled(dm, c('aktien', 'anleihen'), frequency = 'quarter', inflation = 'cpi', n = 12, years = 8, seed = 6)",
         paste0(P, "result = PL.bootstrap_pooled(dm, ['aktien', 'anleihen'], frequency='quarter', inflation='cpi', n=12, years=8, seed=6)"), I,
         jl = paste0(JH, 'result = PL.bootstrap_pooled(dm, ["aktien", "anleihen"]; frequency = "quarter", inflation = "cpi", n = 12, years = 8, seed = 6)'))
ref_case("pb_month", "bootstrap_pooled(dm, 'aktien', frequency = 'month', n = 6, years = 3, L = 6, country_weights = c(0.9, 0.1), seed = 7)",
         paste0(P, "result = PL.bootstrap_pooled(dm, 'aktien', frequency='month', n=6, years=3, L=6, country_weights=[0.9, 0.1], seed=7)"), I,
         jl = paste0(JH, 'result = PL.bootstrap_pooled(dm, "aktien"; frequency = "month", n = 6, years = 3, L = 6, country_weights = [0.9, 0.1], seed = 7)'))
ref_case("pb_noseed", "set.seed(42); a <- bootstrap_pooled(ds, 'aktien', n = 8, years = 5, L = 2); list(a, runif(1))",
         paste0(P, "RNG.set_seed(42); a = PL.bootstrap_pooled(ds, 'aktien', n=8, years=5, L=2); result = [a, RNG.runif(1)]"), I,
         jl = paste0(JH, 'SL.RRng.set_seed(42); a = PL.bootstrap_pooled(ds, "aktien"; n = 8, years = 5, L = 2); result = Any[a, SL.RRng.runif(1)]'))
ref_case("pb_seed_restore", "set.seed(42); a <- bootstrap_pooled(ds, 'aktien', n = 3, years = 5, L = 2, seed = 1); runif(2)",
         paste0(P, "RNG.set_seed(42); a = PL.bootstrap_pooled(ds, 'aktien', n=3, years=5, L=2, seed=1); result = RNG.runif(2)"), I,
         jl = paste0(JH, 'SL.RRng.set_seed(42); a = PL.bootstrap_pooled(ds, "aktien"; n = 3, years = 5, L = 2, seed = 1); result = SL.RRng.runif(2)'))
ref_case("pb_err_names", "bootstrap_pooled(unname(ds), 'aktien', n = 5)", paste0(P, "result = PL.bootstrap_pooled(list(ds.values()), 'aktien', n=5)"), I,
         jl = paste0(JH, 'result = PL.bootstrap_pooled(collect(values(ds)), "aktien"; n = 5)'))
ref_case("pb_err_w", "bootstrap_pooled(ds, c('aktien', 'anleihen'), weights = 1, n = 5, L = 5, seed = 1)", paste0(P, "result = PL.bootstrap_pooled(ds, ['aktien', 'anleihen'], weights=1, n=5, L=5, seed=1)"), I,
         jl = paste0(JH, 'result = PL.bootstrap_pooled(ds, ["aktien", "anleihen"]; weights = 1, n = 5, L = 5, seed = 1)'))
ref_case("pb_err_w_neg", "bootstrap_pooled(ds, c('aktien', 'anleihen'), weights = c(1, -1), n = 5)", paste0(P, "result = PL.bootstrap_pooled(ds, ['aktien', 'anleihen'], weights=[1, -1], n=5)"), I,
         jl = paste0(JH, 'result = PL.bootstrap_pooled(ds, ["aktien", "anleihen"]; weights = [1, -1], n = 5)'))
ref_case("pb_err_w_names", "bootstrap_pooled(ds, c('aktien', 'anleihen'), weights = c(aktien = 0.6, bonds = 0.4), n = 5, L = 5, seed = 1)",
         paste0(P, "result = PL.bootstrap_pooled(ds, ['aktien', 'anleihen'], weights=pd.Series({'aktien': 0.6, 'bonds': 0.4}), n=5, L=5, seed=1)"), I,
         jl = paste0(JH, 'result = PL.bootstrap_pooled(ds, ["aktien", "anleihen"]; weights = SL.named("aktien" => 0.6, "bonds" => 0.4), n = 5, L = 5, seed = 1)'))
ref_case("pb_err_few", "bootstrap_pooled(list(a = ds$de[1:2, ], b = ds$us), 'aktien', n = 5)", paste0(P, "result = PL.bootstrap_pooled({'a': ds['de'].iloc[:2], 'b': ds['us']}, 'aktien', n=5)"), I,
         jl = paste0(JH, 'result = PL.bootstrap_pooled(SL.RList("a" => SL.rows(ds.de, 1:2), "b" => ds.us), "aktien"; n = 5)'))
ref_case("pb_err_freq", "bootstrap_pooled(ds, 'aktien', frequency = 'week')", paste0(P, "result = PL.bootstrap_pooled(ds, 'aktien', frequency='week')"), I,
         jl = paste0(JH, 'result = PL.bootstrap_pooled(ds, "aktien"; frequency = "week")'))

# ── portfolio_returns ───────────────────────────────────────────────────────
set.seed(1); n <- 1300
pd0 <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "3 days", length.out = n))
pd0$aktien <- 100 * cumprod(1 + rnorm(n, 1e-3, 0.02)); pd0$anleihen <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.004))
pd0$gold <- 100 * cumprod(1 + rnorm(n, 2e-4, 0.01)); pd0$gold[1:200] <- NA; pd0$anleihen[c(500, 501)] <- NA
cand <- lapply(c(a20 = 0.2, a60 = 0.6, a100 = 1), function(a) c(aktien = a, anleihen = 1 - a))
I <- list(pd0 = pd0, cand = cand)
PC <- "cand = {k: pd.Series(v) for k, v in cand.items()}\n"
ref_case("pr_year", "portfolio_returns(pd0, cand)", paste0(P, PC, "result = PL.portfolio_returns(pd0, cand)"), I,
         jl = paste0(JH, 'result = PL.portfolio_returns(pd0, cand)'))
ref_case("pr_quarter", "portfolio_returns(pd0, cand, 'quarter')", paste0(P, PC, "result = PL.portfolio_returns(pd0, cand, frequency='quarter')"), I,
         jl = paste0(JH, 'result = PL.portfolio_returns(pd0, cand; frequency = "quarter")'))
ref_case("pr_month_gold", "portfolio_returns(pd0, list(c(gold = 1, aktien = 1), c(anleihen = 2)), frequency = 'month')",
         paste0(P, "result = PL.portfolio_returns(pd0, [pd.Series({'gold': 1, 'aktien': 1}), pd.Series({'anleihen': 2})], frequency='month')"), I,
         jl = paste0(JH, 'result = PL.portfolio_returns(pd0, Any[SL.named("gold" => 1.0, "aktien" => 1.0), SL.named("anleihen" => 2.0)]; frequency = "month")'))
ref_case("pr_single", "portfolio_returns(pd0, list(x = c(aktien = 0.3, gold = 0.7)), 'year')", paste0(P, "result = PL.portfolio_returns(pd0, {'x': pd.Series({'aktien': 0.3, 'gold': 0.7})}, frequency='year')"), I,
         jl = paste0(JH, 'result = PL.portfolio_returns(pd0, SL.RList("x" => SL.named("aktien" => 0.3, "gold" => 0.7)); frequency = "year")'))
ref_case("pr_err_freq", "portfolio_returns(pd0, cand, 'day')", paste0(P, PC, "result = PL.portfolio_returns(pd0, cand, frequency='day')"), I,
         jl = paste0(JH, 'result = PL.portfolio_returns(pd0, cand; frequency = "day")'))

# ── planning_goal ───────────────────────────────────────────────────────────
set.seed(1)
R <- sapply(c(a20 = 0.2, a60 = 0.6, a100 = 1), function(a) exp(rnorm(120, 0.01 + 0.04 * a, 0.02 + 0.16 * a)))
I <- list(R = R)
ref_case("go_ex", "planning_goal(R, start_value = 100000, goal = 150000, horizon = 6, contributions = 2000, n_grid = 41, n_sim = 400, seed = 1)",
         paste0(P, "result = PL.planning_goal(R, start_value=100000, goal=150000, horizon=6, contributions=2000, n_grid=41, n_sim=400, seed=1)"), I,
         jl = paste0(JH, 'result = PL.planning_goal(R, 100000, 150000, 6; contributions = 2000, n_grid = 41, n_sim = 400, seed = 1)'))
ref_case("go_goal0", "planning_goal(R, 1e5, 0, 8, contributions = -12000, n_grid = 31, n_sim = 300, seed = 2)",
         paste0(P, "result = PL.planning_goal(R, 1e5, 0, 8, contributions=-12000, n_grid=31, n_sim=300, seed=2)"), I,
         jl = paste0(JH, 'result = PL.planning_goal(R, 1e5, 0, 8; contributions = -12000, n_grid = 31, n_sim = 300, seed = 2)'))
ref_case("go_vec_cf", "planning_goal(R[1:60, ], 5e4, 8e4, 5, contributions = c(1000, -500), n_grid = 25, n_sim = 200, seed = 3)",
         paste0(P, "result = PL.planning_goal(R[:60], 5e4, 8e4, 5, contributions=[1000, -500], n_grid=25, n_sim=200, seed=3)"), I,
         jl = paste0(JH, 'result = PL.planning_goal(SL.NamedMat(R.data[1:60, :]; colnames = R.colnames[:]), 5e4, 8e4, 5; contributions = [1000, -500], n_grid = 25, n_sim = 200, seed = 3)'))
ref_case("go_tie", "planning_goal(R, 2e5, 1e5, 4, n_grid = 51, n_sim = 300, seed = 1)",
         paste0(P, "result = PL.planning_goal(R, 2e5, 1e5, 4, n_grid=51, n_sim=300, seed=1)"), I,
         jl = paste0(JH, 'result = PL.planning_goal(R, 2e5, 1e5, 4; n_grid = 51, n_sim = 300, seed = 1)'))
ref_case("go_noname", "planning_goal(unname(R[1:50, 2:3]), 100, 130, 3, n_grid = 15, n_sim = 100, seed = 4)",
         paste0(P, "result = PL.planning_goal(R.to_numpy()[:50, 1:3], 100, 130, 3, n_grid=15, n_sim=100, seed=4)"), I,
         jl = paste0(JH, 'result = PL.planning_goal(R.data[1:50, 2:3], 100, 130, 3; n_grid = 15, n_sim = 100, seed = 4)'))
ref_case("go_one", "planning_goal(R[1:40, 1, drop = FALSE], 100, 105, 2, n_grid = 10, n_sim = 50, seed = 5)",
         paste0(P, "result = PL.planning_goal(R.iloc[:40, [0]], 100, 105, 2, n_grid=10, n_sim=50, seed=5)"), I,
         jl = paste0(JH, 'result = PL.planning_goal(SL.NamedMat(R.data[1:40, 1:1]; colnames = R.colnames[1:1]), 100, 105, 2; n_grid = 10, n_sim = 50, seed = 5)'))
ref_case("go_df", "planning_goal(as.data.frame(R[1:30, ]), 100, 110, 1, n_grid = 8, n_sim = 60, seed = 6)",
         paste0(P, "result = PL.planning_goal(R.iloc[:30], 100, 110, 1, n_grid=8, n_sim=60, seed=6)"), I,
         jl = paste0(JH, 'result = PL.planning_goal(SL.RFrame(R.colnames, [R.data[1:30, j] for j in 1:3]), 100, 110, 1; n_grid = 8, n_sim = 60, seed = 6)'))
set.seed(3)
S5 <- cbind(safe = exp(rnorm(5, 0.02, 0.01)), mid = exp(rnorm(5, 0.04, 0.1)), risky = exp(rnorm(5, 0.06, 0.25)))
ref_case("go_warn", "planning_goal(S5, 100, 123.4, 4, n_grid = 301, n_sim = 3000, seed = 1)",
         paste0(P, "result = PL.planning_goal(S5, 100, 123.4, 4, n_grid=301, n_sim=3000, seed=1)"), list(S5 = S5),
         jl = paste0(JH, 'result = PL.planning_goal(S5, 100, 123.4, 4; n_grid = 301, n_sim = 3000, seed = 1)'))
ref_case("go_noseed", "set.seed(8); g <- planning_goal(R[1:30, ], 100, 120, 3, n_grid = 12, n_sim = 80); list(g, runif(1))",
         paste0(P, "RNG.set_seed(8); g = PL.planning_goal(R.iloc[:30], 100, 120, 3, n_grid=12, n_sim=80); result = [g, RNG.runif(1)]"), I,
         jl = paste0(JH, 'SL.RRng.set_seed(8); g = PL.planning_goal(SL.NamedMat(R.data[1:30, :]; colnames = R.colnames[:]), 100, 120, 3; n_grid = 12, n_sim = 80); result = Any[g, SL.RRng.runif(1)]'))
ref_case("go_err_R", "planning_goal(-R, 1, 2, 3)", paste0(P, "result = PL.planning_goal(-R, 1, 2, 3)"), I,
         jl = paste0(JH, 'result = PL.planning_goal(-R.data, 1, 2, 3)'))
ref_case("go_err_R_na", "x <- R; x[2, 2] <- NA; planning_goal(x, 1, 2, 3)", paste0(P, "x = R.copy(); x.iloc[1, 1] = simlev._r.fmt.NA_REAL; result = PL.planning_goal(x, 1, 2, 3)"), I,
         jl = paste0(JH, 'x = copy(R.data); x[2, 2] = SL.NA; result = PL.planning_goal(x, 1, 2, 3)'))
ref_case("go_err_start", "planning_goal(R, 0, 1e5, 10)", paste0(P, "result = PL.planning_goal(R, 0, 1e5, 10)"), I,
         jl = paste0(JH, 'result = PL.planning_goal(R, 0, 1e5, 10)'))
ref_case("go_err_start2", "planning_goal(R, c(1, 2), 1e5, 10)", paste0(P, "result = PL.planning_goal(R, [1, 2], 1e5, 10)"), I,
         jl = paste0(JH, 'result = PL.planning_goal(R, [1, 2], 1e5, 10)'))
ref_case("go_err_goal", "planning_goal(R, 1e5, -1, 10)", paste0(P, "result = PL.planning_goal(R, 1e5, -1, 10)"), I,
         jl = paste0(JH, 'result = PL.planning_goal(R, 1e5, -1, 10)'))
ref_case("go_err_h0", "planning_goal(R, 1e5, 1.5e5, 0)", paste0(P, "result = PL.planning_goal(R, 1e5, 1.5e5, 0)"), I,
         jl = paste0(JH, 'result = PL.planning_goal(R, 1e5, 1.5e5, 0)'))
ref_case("go_err_h", "planning_goal(R, 1e5, 1.5e5, 2.5)", paste0(P, "result = PL.planning_goal(R, 1e5, 1.5e5, 2.5)"), I,
         jl = paste0(JH, 'result = PL.planning_goal(R, 1e5, 1.5e5, 2.5)'))
ref_case("go_err_grid", "planning_goal(R, 1e5, 1.5e5, 2, n_grid = 1)", paste0(P, "result = PL.planning_goal(R, 1e5, 1.5e5, 2, n_grid=1)"), I,
         jl = paste0(JH, 'result = PL.planning_goal(R, 1e5, 1.5e5, 2; n_grid = 1)'))
ref_case("go_err_sim", "planning_goal(R, 1e5, 1.5e5, 2, n_sim = 0)", paste0(P, "result = PL.planning_goal(R, 1e5, 1.5e5, 2, n_sim=0)"), I,
         jl = paste0(JH, 'result = PL.planning_goal(R, 1e5, 1.5e5, 2; n_sim = 0)'))
ref_case("go_err_cf", "planning_goal(R, 1e5, 1.5e5, 2, contributions = NA)", paste0(P, "result = PL.planning_goal(R, 1e5, 1.5e5, 2, contributions=simlev._r.fmt.NA_REAL)"), I,
         jl = paste0(JH, 'result = PL.planning_goal(R, 1e5, 1.5e5, 2; contributions = missing)'))
ref_case("go_err_cf0", "planning_goal(R, 1e5, 1.5e5, 2, contributions = numeric(0))", paste0(P, "result = PL.planning_goal(R, 1e5, 1.5e5, 2, contributions=[])"), I,
         jl = paste0(JH, 'result = PL.planning_goal(R, 1e5, 1.5e5, 2; contributions = Float64[])'))
ref_done()
