# tests/werkzeuge/breite/planung.R – Referenzfälle des Bereichs planung: Planung, Szenarien, taktische Allokation.
# Module: planning, scenarios, tactical (bis 1.4.0 je ein Generator gen_<modul>.R, hier wörtlich hintereinander).
# Aufruf (Repo-Wurzel): LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/breite/planung.R
# Breitenprüfung, nichts abgelegt: alle bisherigen Einzelfälle des Bereichs (bis 1.4.1 Generator des Katalogs) flach nach
# <ordner>/breite_planung.jsonl.gz; tests/werkzeuge/gleichlauf/run.sh vergleicht Python und Julia damit. Abgelegt sind die Szenarien
# und Tabellen aus tests/gleichlauf/erzeugen/planung.R (Format und Umgebung: tests/gleichlauf/erzeugen/ref_tools.R).
source("tests/gleichlauf/erzeugen/ref_tools.R")
ref_bereich("breite_planung", alle = TRUE)

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul planning
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Referenzfälle für r/R/planning.R (series_shift_return, .period_gross, bootstrap_pooled,
# portfolio_returns, planning_goal, print.SimLevGoalPlan) -> python/simlev/planning.py
ref_init("planning")
P <- "from simlev import planning as PL\n"
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
ref_case("pb_noseed", "simlev_seed(42); a <- bootstrap_pooled(ds, 'aktien', n = 8, years = 5, L = 2); list(a, SimLev:::.sl_runif(1))",
         paste0(P, "simlev.simlev_seed(42); a = PL.bootstrap_pooled(ds, 'aktien', n=8, years=5, L=2); result = [a, simlev._lib.runif(1)]"), I,
         jl = paste0(JH, 'SL.simlev_seed(42); a = PL.bootstrap_pooled(ds, "aktien"; n = 8, years = 5, L = 2); result = Any[a, SL.SLib.runif(1)]'))
ref_case("pb_seed_restore", "simlev_seed(42); a <- bootstrap_pooled(ds, 'aktien', n = 3, years = 5, L = 2, seed = 1); SimLev:::.sl_runif(2)",
         paste0(P, "simlev.simlev_seed(42); a = PL.bootstrap_pooled(ds, 'aktien', n=3, years=5, L=2, seed=1); result = simlev._lib.runif(2)"), I,
         jl = paste0(JH, 'SL.simlev_seed(42); a = PL.bootstrap_pooled(ds, "aktien"; n = 3, years = 5, L = 2, seed = 1); result = SL.SLib.runif(2)'))
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
ref_case("go_noseed", "simlev_seed(8); g <- planning_goal(R[1:30, ], 100, 120, 3, n_grid = 12, n_sim = 80); list(g, SimLev:::.sl_runif(1))",
         paste0(P, "simlev.simlev_seed(8); g = PL.planning_goal(R.iloc[:30], 100, 120, 3, n_grid=12, n_sim=80); result = [g, simlev._lib.runif(1)]"), I,
         jl = paste0(JH, 'SL.simlev_seed(8); g = PL.planning_goal(SL.NamedMat(R.data[1:30, :]; colnames = R.colnames[:]), 100, 120, 3; n_grid = 12, n_sim = 80); result = Any[g, SL.SLib.runif(1)]'))
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

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul scenarios
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Referenzfälle für scenarios.R.
ref_init("scenarios")
P <- "from simlev import scenarios as SC\n"
J <- 'SC = SL.Scenarios\n'

# ── Annahmen ─────────────────────────────────────────────────────────────
ref_case("views", "list(view_mean('a', -0.2), view_prob('a < -2', 0.15, '>='), view_vol('b', 0.8, '<='), view_mean('a', 1L, '<'), view_prob('x', 1))",
         paste0(P, "result = [SC.view_mean('a', -0.2), SC.view_prob('a < -2', 0.15, op='>='), SC.view_vol('b', 0.8, op='<='), SC.view_mean('a', 1, op='<'), SC.view_prob('x', 1)]"),
         jl = paste0(J, 'result = [SC.view_mean("a", -0.2), SC.view_prob("a < -2", 0.15, ">="), SC.view_vol("b", 0.8, "<="), SC.view_mean("a", 1, "<"), SC.view_prob("x", 1)]'))
ref_case("view_err1", "view_mean('a', NA)", paste0(P, "result = SC.view_mean('a', simlev._r.fmt.NA_REAL)"), jl = paste0(J, 'result = SC.view_mean("a", missing)'))
ref_case("view_err2", "view_prob('a > 1', 1.5)", paste0(P, "result = SC.view_prob('a > 1', 1.5)"), jl = paste0(J, 'result = SC.view_prob("a > 1", 1.5)'))
ref_case("view_err3", "view_vol('a', -1)", paste0(P, "result = SC.view_vol('a', -1)"), jl = paste0(J, 'result = SC.view_vol("a", -1)'))
ref_case("view_err4", "view_mean('a', c(1, 2))", paste0(P, "result = SC.view_mean('a', [1, 2])"), jl = paste0(J, 'result = SC.view_mean("a", [1, 2])'))
ref_case("view_err5", "view_mean('a', 'x')", paste0(P, "result = SC.view_mean('a', 'x')"), jl = paste0(J, 'result = SC.view_mean("a", "x")'))
ref_case("view_err6", "view_mean('a', 1, '==')", paste0(P, "result = SC.view_mean('a', 1, op='==')"), jl = paste0(J, 'result = SC.view_mean("a", 1, "==")'))

# ── scenario_entropy_pooling ──────────────────────────────────────────────────────
set.seed(1); X <- data.frame(a = rnorm(400, 0.2, 2), b = rnorm(400, 0.05, 0.5)); X$b <- X$b + 0.1 * X$a
EI <- list(X = X)
ref_case("ep_table", "scenario_entropy_pooling(X, c('a', 'b'), list(view_mean('a', -0.3), view_prob('a < -2', 0.2), view_vol('b', 0.5, '<=')))",
         paste0(P, "result = SC.scenario_entropy_pooling(X, ['a', 'b'], [SC.view_mean('a', -0.3), SC.view_prob('a < -2', 0.2), SC.view_vol('b', 0.5, op='<=')])"), inputs = EI,
         jl = paste0(J, 'result = SC.scenario_entropy_pooling(X, ["a", "b"], [SC.view_mean("a", -0.3), SC.view_prob("a < -2", 0.2), SC.view_vol("b", 0.5, "<=")])'))
ref_case("ep_vol_mean", "scenario_entropy_pooling(X, c('a', 'b'), list(view_vol('a', 1.5), view_mean('a', 0.5), view_mean('b', 0, '>=')), frequency = 'month')",
         paste0(P, "result = SC.scenario_entropy_pooling(X, ['a', 'b'], [SC.view_vol('a', 1.5), SC.view_mean('a', 0.5), SC.view_mean('b', 0, op='>=')], frequency='month')"), inputs = EI,
         jl = paste0(J, 'result = SC.scenario_entropy_pooling(X, ["a", "b"], [SC.view_vol("a", 1.5), SC.view_mean("a", 0.5), SC.view_mean("b", 0, ">=")]; frequency = "month")'))
ref_case("ep_empty", "scenario_entropy_pooling(X, 'a', list())", paste0(P, "result = SC.scenario_entropy_pooling(X, 'a', [])"), inputs = EI,
         jl = paste0(J, 'result = SC.scenario_entropy_pooling(X, "a", [])'))
ref_case("ep_prior", "scenario_entropy_pooling(X, c('a', 'b'), list(view_mean('b', 0.1)), prior = seq_len(400))",
         paste0(P, "result = SC.scenario_entropy_pooling(X, ['a', 'b'], [SC.view_mean('b', 0.1)], prior=np.arange(1, 401))"), inputs = EI,
         jl = paste0(J, 'result = SC.scenario_entropy_pooling(X, ["a", "b"], [SC.view_mean("b", 0.1)]; prior = collect(1:400))'))
ref_case("ep_infeasible", "scenario_entropy_pooling(X, c('a', 'b'), list(view_mean('a', 50)))",
         paste0(P, "result = SC.scenario_entropy_pooling(X, ['a', 'b'], [SC.view_mean('a', 50)])"), inputs = EI,
         jl = paste0(J, 'result = SC.scenario_entropy_pooling(X, ["a", "b"], [SC.view_mean("a", 50)])'))
ref_case("ep_ineq", "scenario_entropy_pooling(X, c('a', 'b'), list(view_prob('a > 0 & b > 0', 0.5, '>='), view_mean('a', 1, '<=')))",
         paste0(P, "result = SC.scenario_entropy_pooling(X, ['a', 'b'], [SC.view_prob('a > 0 & b > 0', 0.5, op='>='), SC.view_mean('a', 1, op='<=')])"), inputs = EI,
         jl = paste0(J, 'result = SC.scenario_entropy_pooling(X, ["a", "b"], [SC.view_prob("a > 0 & b > 0", 0.5, ">="), SC.view_mean("a", 1, "<=")])'))
ref_case("ep_matrix", "scenario_entropy_pooling(unname(as.matrix(X)), c('V1', 'V2'), list(view_mean('V1', 0)))",
         paste0(P, "result = SC.scenario_entropy_pooling(X.to_numpy(), ['V1', 'V2'], [SC.view_mean('V1', 0)])"), inputs = EI,
         jl = paste0(J, 'result = SC.scenario_entropy_pooling(Matrix(hcat(X["a"], X["b"])), ["V1", "V2"], [SC.view_mean("V1", 0)])'))
ref_case("ep_err_prior1", "scenario_entropy_pooling(X, 'a', list(), prior = c(1, -1))", paste0(P, "result = SC.scenario_entropy_pooling(X, 'a', [], prior=[1, -1])"), inputs = EI,
         jl = paste0(J, 'result = SC.scenario_entropy_pooling(X, "a", []; prior = [1, -1])'))
ref_case("ep_err_prior2", "scenario_entropy_pooling(X, 'a', list(), prior = c(rep(1, 399), NA))", paste0(P, "result = SC.scenario_entropy_pooling(X, 'a', [], prior=np.r_[np.ones(399), simlev._r.fmt.NA_REAL])"), inputs = EI,
         jl = paste0(J, 'result = SC.scenario_entropy_pooling(X, "a", []; prior = vcat(ones(399), SL.NA))'))
ref_case("ep_err_prior3", "scenario_entropy_pooling(X, 'a', list(), prior = rep(0, 400))", paste0(P, "result = SC.scenario_entropy_pooling(X, 'a', [], prior=np.zeros(400))"), inputs = EI,
         jl = paste0(J, 'result = SC.scenario_entropy_pooling(X, "a", []; prior = zeros(400))'))
ref_case("ep_err_view1", "scenario_entropy_pooling(X, 'a', list(view_mean('zz', 1)))", paste0(P, "result = SC.scenario_entropy_pooling(X, 'a', [SC.view_mean('zz', 1)])"), inputs = EI,
         jl = paste0(J, 'result = SC.scenario_entropy_pooling(X, "a", [SC.view_mean("zz", 1)])'))
ref_case("ep_err_view2", "scenario_entropy_pooling(X, 'a', list(view_prob('TRUE', 0.5)))", paste0(P, "result = SC.scenario_entropy_pooling(X, 'a', [SC.view_prob('TRUE', 0.5)])"), inputs = EI,
         jl = paste0(J, 'result = SC.scenario_entropy_pooling(X, "a", [SC.view_prob("TRUE", 0.5)])'))
ref_case("ep_err_view3", "scenario_entropy_pooling(X, 'a', list(view_vol('zz', 1)))", paste0(P, "result = SC.scenario_entropy_pooling(X, 'a', [SC.view_vol('zz', 1)])"), inputs = EI,
         jl = paste0(J, 'result = SC.scenario_entropy_pooling(X, "a", [SC.view_vol("zz", 1)])'))
ref_case("ep_err_view4", "scenario_entropy_pooling(X, 'a', list(list(type = 'skew', var = 'a', value = 1, op = '=')))",
         paste0(P, "result = SC.scenario_entropy_pooling(X, 'a', [{'type': 'skew', 'var': 'a', 'value': 1, 'op': '='}])"), inputs = EI,
         jl = paste0(J, 'result = SC.scenario_entropy_pooling(X, "a", [SL.RList("type" => "skew", "var" => "a", "value" => 1, "op" => "=")])'))

# Kursdaten mit Zuständen
set.seed(2); n <- 3 * 365
d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
e <- rnorm(n)
d$aktien <- 100 * cumprod(1 + 0.01 * e)
d$anleihen <- 100 * cumprod(1 + 0.004 * (0.3 * e + rnorm(n)))
d$gold <- 100 * cumprod(1 + 0.008 * rnorm(n))
d$inflation <- 2 + cumsum(rnorm(n, 0, 0.05))
d$aktien[c(30, 31)] <- NA
DI <- list(d = d)
ref_case("ep_prices", "scenario_entropy_pooling(d, c('aktien', 'anleihen'), list(view_mean('inflation', 3), view_prob('aktien < -2 & inflation > 2', 0.1)), states = 'inflation')",
         paste0(P, "result = SC.scenario_entropy_pooling(d, ['aktien', 'anleihen'], [SC.view_mean('inflation', 3), SC.view_prob('aktien < -2 & inflation > 2', 0.1)], states='inflation')"), inputs = DI,
         jl = paste0(J, 'result = SC.scenario_entropy_pooling(d, ["aktien", "anleihen"], [SC.view_mean("inflation", 3), SC.view_prob("aktien < -2 & inflation > 2", 0.1)]; states = "inflation")'))
# view_prob: Ausdrücke in R-Syntax (gemeinsamer Auswerter, Modul rexpr); freie Variablen global (R: parent.frame() von scenario_entropy_pooling)
EPV <- c("a < -2 | !b > 0", "abs(a) > 2 * sd(a)", "a > quantile(a, 0.9)", "if (lim > 1) b > 0.5 else FALSE", "(a %/% 1) %% 2 == 0",
         "ifelse(a > 0, \"1\", \"0\")", "a > 0 &\n b > 0")
epq <- function(x) paste0("'", gsub("\n", "\\n", x, fixed = TRUE), "'")
epj <- function(x) paste0('"', gsub("\n", "\\n", gsub('"', '\\"', x, fixed = TRUE), fixed = TRUE), '"')
EPO <- c("=", "<=", "=", "=", ">=", "=", "=")
EPP <- c(0.6, 0.1, 0.15, 0.2, 0.4, 0.5, 0.3)
for (k in seq_along(EPV))
  ref_case(sprintf("ep_rx_%02d", k), sprintf("lim <<- 1.5; scenario_entropy_pooling(X, c('a', 'b'), list(view_prob(%s, %s, '%s')))", deparse(EPV[k]), EPP[k], EPO[k]),
           paste0(P, sprintf("lim = 1.5\nresult = SC.scenario_entropy_pooling(X, ['a', 'b'], [SC.view_prob(%s, %s, op='%s')])", epq(EPV[k]), EPP[k], EPO[k])), inputs = EI,
           jl = paste0(J, sprintf('lim = 1.5; result = SC.scenario_entropy_pooling(X, ["a", "b"], [SC.view_prob(%s, %s, "%s")]; env = @__MODULE__)', epj(EPV[k]), EPP[k], EPO[k])))
for (k in seq_along(EPE <- c("a < ", "zz > 0", "a[1] > 0", "a > \"x\"")))
  ref_case(sprintf("ep_rx_err%d", k), sprintf("scenario_entropy_pooling(X, 'a', list(view_prob(%s, 0.5)))", deparse(EPE[k])),
           paste0(P, sprintf("result = SC.scenario_entropy_pooling(X, 'a', [SC.view_prob(%s, 0.5)])", epq(EPE[k]))), inputs = EI,
           jl = paste0(J, sprintf('result = SC.scenario_entropy_pooling(X, "a", [SC.view_prob(%s, 0.5)])', epj(EPE[k]))))
ref_case("ep_prices_day", "scenario_entropy_pooling(d[1:300, ], c('aktien', 'gold'), list(view_vol('gold', 1)), frequency = 'day')",
         paste0(P, "result = SC.scenario_entropy_pooling(d.iloc[:300], ['aktien', 'gold'], [SC.view_vol('gold', 1)], frequency='day')"), inputs = DI,
         jl = paste0(J, 'result = SC.scenario_entropy_pooling(SL.rows(d, 1:300), ["aktien", "gold"], [SC.view_vol("gold", 1)]; frequency = "day")'))

# ── scenario_copula ─────────────────────────────────────────────────────
ref_case("cs_t", "scenario_copula(d, c('aktien', 'anleihen'), n = 500, seed = 1)",
         paste0(P, "result = SC.scenario_copula(d, ['aktien', 'anleihen'], n=500, seed=1)"), inputs = DI,
         jl = paste0(J, 'result = SC.scenario_copula(d, ["aktien", "anleihen"]; n = 500, seed = 1)'))
ref_case("cs_gauss", "scenario_copula(d, c('aktien', 'anleihen', 'gold'), n = 300, family = 'gaussian', frequency = 'month', seed = 2)",
         paste0(P, "result = SC.scenario_copula(d, ['aktien', 'anleihen', 'gold'], n=300, family='gaussian', frequency='month', seed=2)"), inputs = DI,
         jl = paste0(J, 'result = SC.scenario_copula(d, ["aktien", "anleihen", "gold"]; n = 300, family = "gaussian", frequency = "month", seed = 2)'))
ref_case("cs_stress1", "scenario_copula(d, c('aktien', 'anleihen', 'gold'), n = 400, stress = list(aktien = c(0, 0.05)), seed = 3)",
         paste0(P, "result = SC.scenario_copula(d, ['aktien', 'anleihen', 'gold'], n=400, stress={'aktien': [0, 0.05]}, seed=3)"), inputs = DI,
         jl = paste0(J, 'result = SC.scenario_copula(d, ["aktien", "anleihen", "gold"]; n = 400, stress = (aktien = [0, 0.05],), seed = 3)'))
ref_case("cs_stress1g", "scenario_copula(d, c('aktien', 'anleihen'), n = 200, family = 'gaussian', stress = list(anleihen = c(0.9, 1)), seed = 4)",
         paste0(P, "result = SC.scenario_copula(d, ['aktien', 'anleihen'], n=200, family='gaussian', stress={'anleihen': [0.9, 1]}, seed=4)"), inputs = DI,
         jl = paste0(J, 'result = SC.scenario_copula(d, ["aktien", "anleihen"]; n = 200, family = "gaussian", stress = (anleihen = [0.9, 1],), seed = 4)'))
ref_case("cs_stress2", "scenario_copula(d, c('aktien', 'anleihen', 'gold'), n = 100, stress = list(gold = c(0, 0.3), aktien = c(0, 0.3)), seed = 5)",
         paste0(P, "result = SC.scenario_copula(d, ['aktien', 'anleihen', 'gold'], n=100, stress={'gold': [0, 0.3], 'aktien': [0, 0.3]}, seed=5)"), inputs = DI,
         jl = paste0(J, 'result = SC.scenario_copula(d, ["aktien", "anleihen", "gold"]; n = 100, stress = (gold = [0, 0.3], aktien = [0, 0.3]), seed = 5)'))
ref_case("cs_stress_all", "scenario_copula(d, c('aktien', 'anleihen'), n = 50, family = 'gaussian', stress = list(aktien = c(0, 0.5), anleihen = c(0.2, 1)), seed = 6)",
         paste0(P, "result = SC.scenario_copula(d, ['aktien', 'anleihen'], n=50, family='gaussian', stress={'aktien': [0, 0.5], 'anleihen': [0.2, 1]}, seed=6)"), inputs = DI,
         jl = paste0(J, 'result = SC.scenario_copula(d, ["aktien", "anleihen"]; n = 50, family = "gaussian", stress = (aktien = [0, 0.5], anleihen = [0.2, 1]), seed = 6)'))
set.seed(7); XS <- data.frame(x = rnorm(150), y = rnorm(150)); XS$z <- XS$x + 1e-9 * rnorm(150)
ref_case("cs_table_psd", "scenario_copula(XS, c('x', 'y', 'z'), n = 200, seed = 8)",
         paste0(P, "result = SC.scenario_copula(XS, ['x', 'y', 'z'], n=200, seed=8)"), inputs = list(XS = XS),
         jl = paste0(J, 'result = SC.scenario_copula(XS, ["x", "y", "z"]; n = 200, seed = 8)'))
ref_case("cs_seednull", "simlev_seed(10); x <- scenario_copula(XS, c('x', 'y'), n = 100, family = 'gaussian'); list(x, SimLev:::.sl_runif(2))",
         paste0(P, "simlev.simlev_seed(10); x = SC.scenario_copula(XS, ['x', 'y'], n=100, family='gaussian'); result = [x, simlev._lib.runif(2)]"), inputs = list(XS = XS),
         jl = paste0(J, 'SL.simlev_seed(10); x = SC.scenario_copula(XS, ["x", "y"]; n = 100, family = "gaussian"); result = [x, SL.SLib.runif(2)]'))
JST <- c("1" = "[[0, 0.1]]", "2" = "(zz = [0, 0.1],)", "3" = "(x = [0.2, 0.1],)", "4" = "(x = [0, 5],)", "5" = "(x = 0.1,)",
         "6" = "SL.RList()", "7" = "(x = [SL.NA, 0.1],)")
for (st in list(c("1", "list(c(0, 0.1))", "[[0, 0.1]]"), c("2", "list(zz = c(0, 0.1))", "{'zz': [0, 0.1]}"), c("3", "list(x = c(0.2, 0.1))", "{'x': [0.2, 0.1]}"),
                c("4", "list(x = c(0, 5))", "{'x': [0, 5]}"), c("5", "list(x = 0.1)", "{'x': 0.1}"), c("6", "list()", "{}"), c("7", "list(x = c(NA, 0.1))", "{'x': [simlev._r.fmt.NA_REAL, 0.1]}")))
  ref_case(paste0("cs_err", st[1]), sprintf("scenario_copula(XS, c('x', 'y'), n = 10, family = 'gaussian', stress = %s)", st[2]),
           paste0(P, sprintf("result = SC.scenario_copula(XS, ['x', 'y'], n=10, family='gaussian', stress=%s)", st[3])), inputs = list(XS = XS),
           jl = paste0(J, sprintf('result = SC.scenario_copula(XS, ["x", "y"]; n = 10, family = "gaussian", stress = %s)', JST[[st[1]]])))
ref_case("cs_err_fam", "scenario_copula(XS, 'x', family = 'clayton')", paste0(P, "result = SC.scenario_copula(XS, 'x', family='clayton')"), inputs = list(XS = XS),
         jl = paste0(J, 'result = SC.scenario_copula(XS, "x"; family = "clayton")'))

# ── scenario_risk ────────────────────────────────────────────────────────
ref_case("risk", "ep <- scenario_entropy_pooling(X, c('a', 'b'), list(view_mean('a', -0.2))); cs <- scenario_copula(X, c('a', 'b'), n = 300, seed = 1)
  list(scenario_risk(ep, c(a = 0.6, b = 0.4)), scenario_risk(ep, c(b = 1), alpha = 0.2), scenario_risk(cs, c(a = 0.5, b = 0.5), 0.01))",
         paste0(P, "ep = SC.scenario_entropy_pooling(X, ['a', 'b'], [SC.view_mean('a', -0.2)]); cs = SC.scenario_copula(X, ['a', 'b'], n=300, seed=1)\nresult = [SC.scenario_risk(ep, {'a': 0.6, 'b': 0.4}), SC.scenario_risk(ep, pd.Series({'b': 1.0}), alpha=0.2), SC.scenario_risk(cs, {'a': 0.5, 'b': 0.5}, alpha=0.01)]"),
         inputs = EI,
         jl = paste0(J, 'ep = SC.scenario_entropy_pooling(X, ["a", "b"], [SC.view_mean("a", -0.2)]); cs = SC.scenario_copula(X, ["a", "b"]; n = 300, seed = 1)\nresult = [SC.scenario_risk(ep, SL.named("a" => 0.6, "b" => 0.4)), SC.scenario_risk(ep, SL.named("b" => 1.0); alpha = 0.2), SC.scenario_risk(cs, (a = 0.5, b = 0.5); alpha = 0.01)]'))
PE <- paste0(P, "ep = SC.scenario_entropy_pooling(X, ['a', 'b'], [])\n")
JE <- paste0(J, 'ep = SC.scenario_entropy_pooling(X, ["a", "b"], [])\n')
ref_case("risk_err1", "scenario_risk(list(), c(a = 1))", paste0(P, "result = SC.scenario_risk({}, {'a': 1})"), jl = paste0(J, 'result = SC.scenario_risk(SL.RList(), (a = 1,))'))
ref_case("risk_err2", "ep <- scenario_entropy_pooling(X, c('a', 'b'), list()); scenario_risk(ep, c(a = 1), alpha = 1)", paste0(PE, "result = SC.scenario_risk(ep, {'a': 1}, alpha=1)"), inputs = EI, jl = paste0(JE, 'result = SC.scenario_risk(ep, (a = 1,); alpha = 1)'))
ref_case("risk_err3", "ep <- scenario_entropy_pooling(X, c('a', 'b'), list()); scenario_risk(ep, c(1, 2))", paste0(PE, "result = SC.scenario_risk(ep, [1, 2])"), inputs = EI, jl = paste0(JE, 'result = SC.scenario_risk(ep, [1, 2])'))
ref_case("risk_err4", "ep <- scenario_entropy_pooling(X, c('a', 'b'), list()); scenario_risk(ep, c(a = 1, q = 2))", paste0(PE, "result = SC.scenario_risk(ep, {'a': 1, 'q': 2})"), inputs = EI, jl = paste0(JE, 'result = SC.scenario_risk(ep, (a = 1, q = 2))'))

# ── scenario_crisis ────────────────────────────────────────────────────────
set.seed(3); n <- 6 * 365
dc <- data.frame(date = seq.Date(as.Date("2006-06-01"), by = "day", length.out = n))
dc$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.012)); dc$anleihen <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.003))
dc$aktien[c(500, 501)] <- NA
CI <- list(dc = dc)
ref_case("crisis_default", "scenario_crisis(dc, c(aktien = 0.6, anleihen = 0.4))",
         paste0(P, "result = SC.scenario_crisis(dc, {'aktien': 0.6, 'anleihen': 0.4})"), inputs = CI,
         jl = paste0(J, 'result = SC.scenario_crisis(dc, (aktien = 0.6, anleihen = 0.4))'))
kr <- data.frame(crisis = c("A", "B", "C", "D"), start = as.Date(c("2007-05-01", "2008-01-01", "2012-05-01", "2001-01-01")),
                 end = as.Date(c("2007-09-30", "2008-01-01", "2012-05-30", "2001-06-01")))
ref_case("crisis_custom", "list(scenario_crisis(dc, c(aktien = 3, anleihen = 1), kr, rebalance = TRUE), scenario_crisis(dc, c(anleihen = 1), kr))",
         paste0(P, "result = [SC.scenario_crisis(dc, {'aktien': 3, 'anleihen': 1}, crises=kr, rebalance=True), SC.scenario_crisis(dc, {'anleihen': 1}, crises=kr)]"),
         inputs = list(dc = dc, kr = kr),
         jl = paste0(J, 'result = [SC.scenario_crisis(dc, (aktien = 3, anleihen = 1), kr; rebalance = true), SC.scenario_crisis(dc, (anleihen = 1,), kr)]'))
dlate <- dc[dc$date >= as.Date("2008-01-10"), ]
ref_case("crisis_chr", "kc <- data.frame(crisis = 'X', start = '2009-01-05', end = '2010-02-01'); scenario_crisis(dlate[c(2, 1, 3:nrow(dlate)), ], c(aktien = 0.5, anleihen = 0.5), kc)",
         paste0(P, "kc = pd.DataFrame({'crisis': ['X'], 'start': ['2009-01-05'], 'end': ['2010-02-01']}); result = SC.scenario_crisis(dlate.iloc[[1, 0] + list(range(2, len(dlate)))], {'aktien': 0.5, 'anleihen': 0.5}, crises=kc)"),
         inputs = list(dlate = dlate),
         jl = paste0(J, 'kc = SL.RFrame("crisis" => ["X"], "start" => ["2009-01-05"], "end" => ["2010-02-01"]); result = SC.scenario_crisis(SL.rows(dlate, vcat([2, 1], 3:SL.nrow(dlate))), (aktien = 0.5, anleihen = 0.5), kc)'))
ref_case("crisis_err1", "scenario_crisis(as.matrix(dc[, -1]), c(aktien = 1))", paste0(P, "result = SC.scenario_crisis(dc.iloc[:, 1:].to_numpy(), {'aktien': 1})"), inputs = list(dc = dc[1:5, ]), jl = paste0(J, 'result = SC.scenario_crisis(hcat(dc["aktien"], dc["anleihen"]), (aktien = 1,))'))
ref_case("crisis_err2", "scenario_crisis(dc, c(aktien = 1), data.frame(a = 1))", paste0(P, "result = SC.scenario_crisis(dc, {'aktien': 1}, crises=pd.DataFrame({'a': [1]}))"), inputs = list(dc = dc[1:5, ]), jl = paste0(J, 'result = SC.scenario_crisis(dc, (aktien = 1,), SL.RFrame("a" => [1]))'))
ref_case("crisis_err3", "scenario_crisis(dc, c(aktien = NA))", paste0(P, "result = SC.scenario_crisis(dc, {'aktien': simlev._r.fmt.NA_REAL})"), inputs = list(dc = dc[1:5, ]), jl = paste0(J, 'result = SC.scenario_crisis(dc, (aktien = SL.NA,))'))
ref_case("crisis_err4", "scenario_crisis(dc, c(aktien = 1, zz = 1))", paste0(P, "result = SC.scenario_crisis(dc, {'aktien': 1, 'zz': 1})"), inputs = list(dc = dc[1:5, ]), jl = paste0(J, 'result = SC.scenario_crisis(dc, (aktien = 1, zz = 1))'))
ref_case("crisis_err5", "scenario_crisis(dc, c(aktien = 1, anleihen = -1.5))", paste0(P, "result = SC.scenario_crisis(dc, {'aktien': 1, 'anleihen': -1.5})"), inputs = list(dc = dc[1:5, ]), jl = paste0(J, 'result = SC.scenario_crisis(dc, (aktien = 1, anleihen = -1.5))'))
ref_case("crisis_err6", "scenario_crisis(dc, c(aktien = 1))", paste0(P, "result = SC.scenario_crisis(dc, {'aktien': 1})"), inputs = list(dc = dc[1:50, ]), jl = paste0(J, 'result = SC.scenario_crisis(dc, (aktien = 1,))'))
ref_case("crisis_err7", "scenario_crisis(dc, c(0.5, 0.5))", paste0(P, "result = SC.scenario_crisis(dc, [0.5, 0.5])"), inputs = list(dc = dc[1:5, ]), jl = paste0(J, 'result = SC.scenario_crisis(dc, [0.5, 0.5])'))
ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul tactical
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Referenzfälle für tactical.R (Gewichts-Erzeuger, Druckausgabe, tactical_simulation).
# Aufruf aus der Repo-Wurzel:
ref_init("tactical")

P <- "from simlev import tactical as T\nimport numpy as np, pandas as pd, math\n"
J <- "T = SL.Tactical\n"   # Kopf des Julia-Codes (jl)
cs <- function(id, r, py, inputs = I, jl = NULL, ...) {
  used <- names(inputs)[vapply(names(inputs), function(k) grepl(sprintf("(^|[^A-Za-z0-9_.])%s([^A-Za-z0-9_.]|$)", k), r), TRUE)]
  ref_case(id, r, paste0(P, py), inputs = inputs[used], jl = if (is.null(jl)) NULL else paste0(J, jl), ...)
}

make_mkt <- function(n = 365 * 4, seed = 1) {
  set.seed(seed)
  d <- data.frame(date = seq.Date(as.Date("2012-01-01"), by = "day", length.out = n))
  d$A <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.012)); d$B <- 100 * cumprod(1 + rnorm(n, 2e-4, 0.009))
  d$C <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.004)); d$CASH <- 100 * cumprod(rep(1 + 0.02 / 365, n))
  d
}
d <- make_mkt()
d$infl <- round(2 + cumsum(rnorm(nrow(d), 0, 0.05)), 2)
dna <- d; dna$A[c(1:3, 400:410)] <- NA; dna$B[700] <- NA
set.seed(5)
buy <- runif(nrow(d)) < 0.02; sell <- runif(nrow(d)) < 0.02
I <- list(d = d, buy = buy, sell = sell)

# ── signal_state ─────────────────────────────────────────────────────────────
cs("ss_basic", "signal_state(list(buy = c(F, T, F, F, F, T), sell = c(F, F, F, T, F, F)))",
   "result = T.signal_state({'buy': [False, True, False, False, False, True], 'sell': [False, False, False, True, False, False]})",
   jl = 'result = T.signal_state(SL.RList("buy" => [false, true, false, false, false, true], "sell" => [false, false, false, true, false, false]))')
cs("ss_init", "signal_state(list(buy = c(F, F, T, T, F), sell = c(F, T, T, F, T)), initial = TRUE)",
   "result = T.signal_state({'buy': [False, False, True, True, False], 'sell': [False, True, True, False, True]}, initial=True)",
   jl = 'result = T.signal_state(SL.RList("buy" => [false, false, true, true, false], "sell" => [false, true, true, false, true]); initial = true)')
cs("ss_none", "signal_state(list(buy = c(F, F, F), sell = c(F, F, F)))", "result = T.signal_state({'buy': [False] * 3, 'sell': [False] * 3})",
   jl = 'result = T.signal_state(SL.RList("buy" => fill(false, 3), "sell" => fill(false, 3)))')
cs("ss_long", "signal_state(list(buy = buy, sell = sell))", "result = T.signal_state({'buy': buy, 'sell': sell})",
   jl = 'result = T.signal_state(SL.RList("buy" => buy, "sell" => sell))')
cs("ss_example", "x <- c(100, 102, 105, 103, 99, 97, 100, 104); signal_state(list(buy = x > 101, sell = x < 98))",
   "x = np.array([100, 102, 105, 103, 99, 97, 100, 104.]); result = T.signal_state({'buy': x > 101, 'sell': x < 98})",
   jl = 'x = [100, 102, 105, 103, 99, 97, 100, 104.0]; result = T.signal_state(SL.RList("buy" => x .> 101, "sell" => x .< 98))')

# ── momentum_score ───────────────────────────────────────────────────────────
cs("ms_default", "momentum_score(d, c('A', 'B'))", "result = T.momentum_score(d, ['A', 'B'])",
   jl = 'result = T.momentum_score(d, ["A", "B"])')
cs("ms_lb", "momentum_score(d, c('A', 'B', 'C'), lookbacks = c(1, 12))", "result = T.momentum_score(d, ['A', 'B', 'C'], lookbacks=[1, 12])",
   jl = 'result = T.momentum_score(d, ["A", "B", "C"]; lookbacks = [1, 12])')
cs("ms_13612w", "momentum_score(d, c('A', 'CASH'), type = '13612w')", "result = T.momentum_score(d, ['A', 'CASH'], type='13612w')",
   jl = 'result = T.momentum_score(d, ["A", "CASH"]; type = "13612w")')
cs("ms_single", "momentum_score(d, 'B', lookbacks = 3)", "result = T.momentum_score(d, 'B', lookbacks=3)",
   jl = 'result = T.momentum_score(d, "B"; lookbacks = 3)')
cs("ms_na", "momentum_score(dna, c('A', 'B'), lookbacks = c(1, 2))", "result = T.momentum_score(dna, ['A', 'B'], lookbacks=[1, 2])",
   inputs = list(dna = dna),
   jl = 'result = T.momentum_score(dna, ["A", "B"]; lookbacks = [1, 2])')
dme <- data.frame(date = seq.Date(as.Date("2019-01-01"), as.Date("2021-12-31"), by = "day"))
dme$A <- as.numeric(dme$date - dme$date[1]) + 100
cs("ms_month_end", "momentum_score(dme, 'A', lookbacks = c(1, 12))", "result = T.momentum_score(dme, 'A', lookbacks=[1, 12])", inputs = list(dme = dme),
   jl = 'result = T.momentum_score(dme, "A"; lookbacks = [1, 12])')
wd <- d[!format(d$date, "%u") %in% c("6", "7"), c("date", "A", "B")]
cs("ms_weekdays", "momentum_score(wd, c('A', 'B'), lookbacks = c(1, 6))", "result = T.momentum_score(wd, ['A', 'B'], lookbacks=[1, 6])", inputs = list(wd = wd),
   jl = 'result = T.momentum_score(wd, ["A", "B"]; lookbacks = [1, 6])')
cs("ms_chrdate", "x <- data.frame(date = format(d$date[1:400]), A = d$A[1:400]); momentum_score(x, 'A', lookbacks = 1)",
   "x = pd.DataFrame({'date': [str(v)[:10] for v in d['date'][:400]], 'A': d['A'][:400]}); result = T.momentum_score(x, 'A', lookbacks=1)",
   jl = 'x = SL.RFrame("date" => Dates.format.(d.date[1:400], "yyyy-mm-dd"), "A" => d.A[1:400]); result = T.momentum_score(x, "A"; lookbacks = 1)')
cs("ms_posixct", "x2 <- data.frame(date = as.POSIXct(format(d$date[1:400]), tz = 'Europe/Berlin'), A = d$A[1:400]); momentum_score(x2, 'A', lookbacks = c(1, 2))",
   "x2 = pd.DataFrame({'date': pd.to_datetime(d['date'][:400]).dt.tz_localize('Europe/Berlin'), 'A': d['A'][:400]}); result = T.momentum_score(x2, 'A', lookbacks=[1, 2])",
   jl = 'x2 = SL.RFrame("date" => DateTime.(d.date[1:400]), "A" => d.A[1:400]); result = T.momentum_score(x2, "A"; lookbacks = [1, 2])')
cs("tr_env", "thr <- 101; tactical_rules(d, list(list(when = 'A > thr', weights = c(A = 1, B = 1))), default = c(C = 1))",
   "thr = 101\nresult = T.tactical_rules(d, [{'when': 'A > thr', 'weights': {'A': 1, 'B': 1}}], default={'C': 1})",
   jl = 'thr = 101; result = T.tactical_rules(d, [SL.RList("when" => "A > thr", "weights" => SL.named("A" => 1, "B" => 1))], SL.named("C" => 1); env = @__MODULE__)')
cs("rot_top_frac", "tactical_rotation(d, c('A', 'B', 'C'), top = 2.7, safe = 'CASH', lookbacks = c(2, 4))",
   "result = T.tactical_rotation(d, ['A', 'B', 'C'], top=2.7, safe='CASH', lookbacks=[2, 4])",
   jl = 'result = T.tactical_rotation(d, ["A", "B", "C"]; top = 2.7, safe = "CASH", lookbacks = [2, 4])')
cs("ms_err_miss", "momentum_score(d, c('A', 'X', 'Y'))", "result = T.momentum_score(d, ['A', 'X', 'Y'])",
   jl = 'result = T.momentum_score(d, ["A", "X", "Y"])')
cs("ms_err_type", "momentum_score(d, 'A', type = 'foo')", "result = T.momentum_score(d, 'A', type='foo')",
   jl = 'result = T.momentum_score(d, "A"; type = "foo")')

# ── tactical_rules ───────────────────────────────────────────────────────────
cs("tr_basic", "tactical_rules(d, list(list(when = 'A > B', weights = c(A = 1)), list(when = rep(TRUE, nrow(d)), weights = c(B = 0.5, C = 0.5))),
                 default = c(C = 1))",
   "result = T.tactical_rules(d, [{'when': 'A > B', 'weights': {'A': 1}}, {'when': np.repeat(True, len(d)), 'weights': {'B': 0.5, 'C': 0.5}}],
                    default={'C': 1})",
   jl = 'result = T.tactical_rules(d, [SL.RList("when" => "A > B", "weights" => SL.named("A" => 1)), SL.RList("when" => fill(true, SL.nrow(d)), "weights" => SL.named("B" => 0.5, "C" => 0.5))], SL.named("C" => 1))')
cs("tr_regime", "attr(tactical_rules(d, list(list(when = 'infl > 2.2', weights = c(C = 0.7, CASH = 0.3)), list(when = 'A > B', weights = c(A = 1))),
                 default = c(B = 2, C = 2)), 'regime')",
   "result = T.tactical_rules(d, [{'when': 'infl > 2.2', 'weights': {'C': 0.7, 'CASH': 0.3}}, {'when': 'A > B', 'weights': {'A': 1}}],
                    default={'B': 2, 'C': 2}).attrs['regime']",
   jl = 'result = SL.attrs(T.tactical_rules(d, [SL.RList("when" => "infl > 2.2", "weights" => SL.named("C" => 0.7, "CASH" => 0.3)), SL.RList("when" => "A > B", "weights" => SL.named("A" => 1))], SL.named("B" => 2, "C" => 2)))["regime"]')
cs("tr_signal", "tactical_rules(d, list(list(when = list(buy = buy, sell = sell), weights = c(A = 0.8, B = 0.2))), default = c(CASH = 1))",
   "result = T.tactical_rules(d, [{'when': {'buy': buy, 'sell': sell}, 'weights': {'A': 0.8, 'B': 0.2}}], default={'CASH': 1})",
   jl = 'result = T.tactical_rules(d, [SL.RList("when" => SL.RList("buy" => buy, "sell" => sell), "weights" => SL.named("A" => 0.8, "B" => 0.2))], SL.named("CASH" => 1))')
cs("tr_na", "w <- d$A > 105; w[1:50] <- NA; tactical_rules(d, list(list(when = w, weights = c(A = 1))), default = c(C = 1, A = -1))",
   "w = (d['A'] > 105).to_numpy(dtype=object); w[:50] = None\nresult = T.tactical_rules(d, [{'when': w, 'weights': {'A': 1}}], default={'C': 1, 'A': -1})",
   jl = 'w = Union{Missing,Bool}[v for v in (d.A .> 105)]; w[1:50] .= missing
result = T.tactical_rules(d, [SL.RList("when" => w, "weights" => SL.named("A" => 1))], SL.named("C" => 1, "A" => -1))')
cs("tr_empty", "tactical_rules(d, list(), default = c(A = 0.6, C = 0.4))", "result = T.tactical_rules(d, [], default={'A': 0.6, 'C': 0.4})",
   jl = 'result = T.tactical_rules(d, [], SL.named("A" => 0.6, "C" => 0.4))')
cs("tr_err_len", "tactical_rules(d, list(list(when = c(TRUE, FALSE), weights = c(A = 1))), default = c(C = 1))",
   "result = T.tactical_rules(d, [{'when': [True, False], 'weights': {'A': 1}}], default={'C': 1})",
   jl = 'result = T.tactical_rules(d, [SL.RList("when" => [true, false], "weights" => SL.named("A" => 1))], SL.named("C" => 1))')
cs("tr_err_zero", "tactical_rules(d, list(list(when = 'A > B', weights = c(A = 0))), default = c(C = 1))",
   "result = T.tactical_rules(d, [{'when': 'A > B', 'weights': {'A': 0}}], default={'C': 1})",
   jl = 'result = T.tactical_rules(d, [SL.RList("when" => "A > B", "weights" => SL.named("A" => 0))], SL.named("C" => 1))')
cs("tr_numeric", "tactical_rules(d, list(list(when = as.numeric(d$A > d$B), weights = c(A = 1))), default = c(C = 1))",
   "result = T.tactical_rules(d, [{'when': (d['A'] > d['B']).astype(float).to_numpy(), 'weights': {'A': 1}}], default={'C': 1})",
   jl = 'result = T.tactical_rules(d, [SL.RList("when" => Float64.(d.A .> d.B), "weights" => SL.named("A" => 1))], SL.named("C" => 1))')

# ── tactical_rules: Bedingungen als Text in R-Syntax (gemeinsamer Auswerter, Modul rexpr) ──
qpy <- function(x) paste0('"', gsub('"', '\\"', gsub("\n", "\\n", gsub("\\", "\\\\", x, fixed = TRUE), fixed = TRUE), fixed = TRUE), '"')
qjl <- function(x) paste0('"', gsub("$", "\\$", gsub('"', '\\"', gsub("\n", "\\n", gsub("\\", "\\\\", x, fixed = TRUE), fixed = TRUE), fixed = TRUE), fixed = TRUE), '"')
trx <- function(id, when, pre_r = "", pre_p = "", pre_j = "") {
  cs(id, sprintf("%sattr(tactical_rules(d, list(list(when = %s, weights = c(A = 1)), list(when = 'B > 100', weights = c(B = 1))), default = c(C = 1)), 'regime')",
                 pre_r, deparse(when)),
     sprintf("%sresult = T.tactical_rules(d, [{'when': %s, 'weights': {'A': 1}}, {'when': 'B > 100', 'weights': {'B': 1}}], default={'C': 1}).attrs['regime']",
             pre_p, qpy(when)),
     jl = sprintf('%sresult = SL.attrs(T.tactical_rules(d, [SL.RList("when" => %s, "weights" => SL.named("A" => 1)), SL.RList("when" => "B > 100", "weights" => SL.named("B" => 1))], SL.named("C" => 1); env = @__MODULE__))["regime"]',
                  pre_j, qjl(when)))
}
TRX <- c("!A > B", "A > B & !infl > 2.2", "infl %in% c(2, 2.05, 2.1)", "A > mean(A)", "A > quantile(A, 0.8)",
         "date >= as.Date('2013-06-01') & date < as.Date('2014-01-01')", "(A %/% 5) %% 2 == 0", "A > 105 & NA",
         "A > max(A) - 10 | B < min(B) + 2", "infl > c(2, 2.2)", "cumsum(A > 110) > 0", "abs(A - B) < 5",
         "sqrt(A) > 10.2", "log(A / B) > 0.05", "is.na(infl) | infl > 2.3", "\"TRUE\"", "ifelse(A > B, 1, 0)",
         "as.character(A > B)", "A > B\n& infl > 2", "A > ", "A >> B", "Z > 1", "A > B && infl > 2",
         "TRUE + (A > 100) == 2L", "A[-1] > A[-length(A)]", "{a <- A / B; a > 1.05}", "A > B # Kommentar",
         "date > \"2014-03-01\"", "infl == 2 | infl == 2.25", "!(A > B | B > C)")
for (k in seq_along(TRX)) trx(sprintf("tr_rx_%02d", k), TRX[[k]])
trx("tr_rx_env", "if (thr > 100) A > thr else B > thr", "thr <- 101; ", "thr = 101\n", "thr = 101; ")
trx("tr_rx_fun", "up(A) & !up(B)", "up <- function(x) x > 100; ", "def up(x):\n    return x > 100\n", "up(x) = x .> 100; ")
trx("tr_rx_fun2", "lag1(A) > A", "lag1 <- function(x) c(NA, x[-length(x)]); ",
    "def lag1(x):\n    return np.concatenate([[simlev._r.fmt.NA_REAL], np.asarray(x)[:-1]])\n", "lag1(x) = vcat(SL.NA, x[1:end-1]); ")

# ── tactical_rotation ────────────────────────────────────────────────────────
cs("rot_basic", "tactical_rotation(d, c('A', 'B'), top = 1, safe = c('C', 'CASH'))", "result = T.tactical_rotation(d, ['A', 'B'], top=1, safe=['C', 'CASH'])",
   jl = 'result = T.tactical_rotation(d, ["A", "B"]; top = 1, safe = ["C", "CASH"])')
cs("rot_attrs", "w <- tactical_rotation(d, c('A', 'B'), top = 1, safe = c('C', 'CASH')); list(attr(w, 'scores'), attr(w, 'decision_rows'))",
   "w = T.tactical_rotation(d, ['A', 'B'], top=1, safe=['C', 'CASH']); result = [w.attrs['scores'], w.attrs['decision_rows']]",
   jl = 'w = T.tactical_rotation(d, ["A", "B"]; top = 1, safe = ["C", "CASH"]); result = [SL.attrs(w)["scores"], SL.attrs(w)["decision_rows"]]')
cs("rot_canary", "tactical_rotation(d, c('A', 'B'), top = 2, safe = 'CASH', canary = c('A', 'B'), absolute = FALSE)",
   "result = T.tactical_rotation(d, ['A', 'B'], top=2, safe='CASH', canary=['A', 'B'], absolute=False)",
   jl = 'result = T.tactical_rotation(d, ["A", "B"]; top = 2, safe = "CASH", canary = ["A", "B"], absolute = false)')
cs("rot_breadth", "tactical_rotation(d, c('A', 'B', 'C'), top = 2, safe = 'CASH', canary = c('A', 'B', 'C'), breadth = 2, type = '13612w', every = 'quarter')",
   "result = T.tactical_rotation(d, ['A', 'B', 'C'], top=2, safe='CASH', canary=['A', 'B', 'C'], breadth=2, type='13612w', every='quarter')",
   jl = 'result = T.tactical_rotation(d, ["A", "B", "C"]; top = 2, safe = "CASH", canary = ["A", "B", "C"], breadth = 2, type = "13612w", every = "quarter")')
cs("rot_week", "tactical_rotation(d, c('A', 'B', 'C'), top = 2, safe = 'CASH', lookbacks = c(1, 3), every = 'week')",
   "result = T.tactical_rotation(d, ['A', 'B', 'C'], top=2, safe='CASH', lookbacks=[1, 3], every='week')",
   jl = 'result = T.tactical_rotation(d, ["A", "B", "C"]; top = 2, safe = "CASH", lookbacks = [1, 3], every = "week")')
cs("rot_invvol", "tactical_rotation(d, c('A', 'B', 'C'), top = 2, safe = 'CASH', weighting = 'inverse_vol', lookbacks = c(1, 6))",
   "result = T.tactical_rotation(d, ['A', 'B', 'C'], top=2, safe='CASH', weighting='inverse_vol', lookbacks=[1, 6])",
   jl = 'result = T.tactical_rotation(d, ["A", "B", "C"]; top = 2, safe = "CASH", weighting = "inverse_vol", lookbacks = [1, 6])')
cs("rot_nosafe", "tactical_rotation(d, c('B', 'A'), top = 1, absolute = FALSE, lookbacks = 3)",
   "result = T.tactical_rotation(d, ['B', 'A'], top=1, absolute=False, lookbacks=3)",
   jl = 'result = T.tactical_rotation(d, ["B", "A"]; top = 1, absolute = false, lookbacks = 3)')
cs("rot_na", "tactical_rotation(dna, c('A', 'B', 'C'), top = 3, safe = 'CASH', lookbacks = c(1, 2))",
   "result = T.tactical_rotation(dna, ['A', 'B', 'C'], top=3, safe='CASH', lookbacks=[1, 2])", inputs = list(dna = dna),
   jl = 'result = T.tactical_rotation(dna, ["A", "B", "C"]; top = 3, safe = "CASH", lookbacks = [1, 2])')
cs("rot_err_safe", "tactical_rotation(d, c('A', 'B'))", "result = T.tactical_rotation(d, ['A', 'B'])",
   jl = 'result = T.tactical_rotation(d, ["A", "B"])')
cs("rot_err_canary", "tactical_rotation(d, c('A', 'B'), absolute = FALSE, canary = 'C')", "result = T.tactical_rotation(d, ['A', 'B'], absolute=False, canary='C')",
   jl = 'result = T.tactical_rotation(d, ["A", "B"]; absolute = false, canary = "C")')
cs("rot_err_top", "tactical_rotation(d, c('A', 'B'), safe = 'CASH', top = 3)", "result = T.tactical_rotation(d, ['A', 'B'], safe='CASH', top=3)",
   jl = 'result = T.tactical_rotation(d, ["A", "B"]; safe = "CASH", top = 3)')
cs("rot_err_top0", "tactical_rotation(d, c('A', 'B'), safe = 'CASH', top = 0)", "result = T.tactical_rotation(d, ['A', 'B'], safe='CASH', top=0)",
   jl = 'result = T.tactical_rotation(d, ["A", "B"]; safe = "CASH", top = 0)')
cs("rot_err_breadth", "tactical_rotation(d, c('A', 'B'), safe = 'CASH', canary = 'A', breadth = 0)",
   "result = T.tactical_rotation(d, ['A', 'B'], safe='CASH', canary='A', breadth=0)",
   jl = 'result = T.tactical_rotation(d, ["A", "B"]; safe = "CASH", canary = "A", breadth = 0)')
cs("rot_err_short", "tactical_rotation(d[1:300, ], c('A', 'B'), safe = 'CASH')", "result = T.tactical_rotation(d.iloc[:300], ['A', 'B'], safe='CASH')",
   jl = 'result = T.tactical_rotation(SL.rows(d, 1:300), ["A", "B"]; safe = "CASH")')
cs("rot_err_every", "tactical_rotation(d, c('A', 'B'), safe = 'CASH', every = 'year')", "result = T.tactical_rotation(d, ['A', 'B'], safe='CASH', every='year')",
   jl = 'result = T.tactical_rotation(d, ["A", "B"]; safe = "CASH", every = "year")')

# ── tactical_target_volatility ────────────────────────────────────────────────────────
cs("tv_static", "tactical_target_volatility(d, c(A = 0.8, B = 0.2), safe = 'CASH', target = 8)",
   "result = T.tactical_target_volatility(d, {'A': 0.8, 'B': 0.2}, safe='CASH', target=8)",
   jl = 'result = T.tactical_target_volatility(d, SL.named("A" => 0.8, "B" => 0.2), "CASH"; target = 8)')
cs("tv_attrs", "w <- tactical_target_volatility(d, c(A = 1), safe = 'CASH', target = 5, every = 'week', window = 21); list(attr(w, 'exposure'), attr(w, 'volatility'))",
   "w = T.tactical_target_volatility(d, {'A': 1}, safe='CASH', target=5, every='week', window=21); result = [w.attrs['exposure'], w.attrs['volatility']]",
   jl = 'w = T.tactical_target_volatility(d, SL.named("A" => 1), "CASH"; target = 5, every = "week", window = 21); result = [SL.attrs(w)["exposure"], SL.attrs(w)["volatility"]]')
cs("tv_rot", "tactical_target_volatility(d, tactical_rotation(d, c('A', 'B'), safe = 'C'), safe = 'CASH', target = 6, every = 'day', max_exposure = 0.9)",
   "result = T.tactical_target_volatility(d, T.tactical_rotation(d, ['A', 'B'], safe='C'), safe='CASH', target=6, every='day', max_exposure=0.9)",
   jl = 'result = T.tactical_target_volatility(d, T.tactical_rotation(d, ["A", "B"]; safe = "C"), "CASH"; target = 6, every = "day", max_exposure = 0.9)')
cs("tv_ppy", "w <- tactical_target_volatility(wd2, c(A = 0.5, B = 0.5), safe = 'CASH', ppy = 252, every = 'quarter'); list(w, attr(w, 'exposure'))",
   "w = T.tactical_target_volatility(wd2, {'A': 0.5, 'B': 0.5}, safe='CASH', ppy=252, every='quarter'); result = [w, w.attrs['exposure']]",
   inputs = list(wd2 = d[!format(d$date, "%u") %in% c("6", "7"), ]),
   jl = 'w = T.tactical_target_volatility(wd2, SL.named("A" => 0.5, "B" => 0.5), "CASH"; ppy = 252, every = "quarter"); result = [w, SL.attrs(w)["exposure"]]')
cs("tv_safe_in_w", "tactical_target_volatility(d, c(A = 0.6, CASH = 0.4), safe = 'CASH', target = 20)",
   "result = T.tactical_target_volatility(d, pd.Series({'A': 0.6, 'CASH': 0.4}), safe='CASH', target=20)",
   jl = 'result = T.tactical_target_volatility(d, SL.named("A" => 0.6, "CASH" => 0.4), "CASH"; target = 20)')
cs("tv_warn", "tactical_target_volatility(d, c(A = 1), safe = 'CASH', target = 0.1)", "result = T.tactical_target_volatility(d, {'A': 1}, safe='CASH', target=0.1)",
   jl = 'result = T.tactical_target_volatility(d, SL.named("A" => 1), "CASH"; target = 0.1)')
cs("tv_err_kredit", "tactical_target_volatility(d, c(A = 1), safe = 'CASH', max_exposure = 2)", "result = T.tactical_target_volatility(d, {'A': 1}, safe='CASH', max_exposure=2)",
   jl = 'result = T.tactical_target_volatility(d, SL.named("A" => 1), "CASH"; max_exposure = 2)')
cs("tv_err_miss", "tactical_target_volatility(d, c(A = 1, gold = 0.5, x = 1), safe = 'CASH')", "result = T.tactical_target_volatility(d, {'A': 1, 'gold': 0.5, 'x': 1}, safe='CASH')",
   jl = 'result = T.tactical_target_volatility(d, SL.named("A" => 1, "gold" => 0.5, "x" => 1), "CASH")')
cs("tv_err_safe", "tactical_target_volatility(d, c(A = 1), safe = 'geld')", "result = T.tactical_target_volatility(d, {'A': 1}, safe='geld')",
   jl = 'result = T.tactical_target_volatility(d, SL.named("A" => 1), "geld")')
cs("tv_err_unnamed", "tactical_target_volatility(d, c(1, 2), safe = 'CASH')", "result = T.tactical_target_volatility(d, [1, 2], safe='CASH')",
   jl = 'result = T.tactical_target_volatility(d, [1, 2], "CASH")')
cs("tv_err_mismatch", "tactical_target_volatility(d, tactical_rules(d[1:100, ], list(), default = c(A = 1)), safe = 'CASH')",
   "result = T.tactical_target_volatility(d, T.tactical_rules(d.iloc[:100], [], default={'A': 1}), safe='CASH')",
   jl = 'result = T.tactical_target_volatility(d, T.tactical_rules(SL.rows(d, 1:100), [], SL.named("A" => 1)), "CASH")')
cs("tv_err_short", "tactical_target_volatility(d[1:50, ], c(A = 1), safe = 'CASH')", "result = T.tactical_target_volatility(d.iloc[:50], {'A': 1}, safe='CASH')",
   jl = 'result = T.tactical_target_volatility(SL.rows(d, 1:50), SL.named("A" => 1), "CASH")')

# ── tactical_conditional_volatility ───────────────────────────────────────────────────
cs("cv_basic", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 0.8, min_history = 1)",
   "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=0.8, min_history=1)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 0.8, min_history = 1)')
cs("cv_attrs", "w <- tactical_conditional_volatility(d, c(A = 0.7, B = 0.3), safe = 'CASH', base = 0.8, min_history = 1, every = 'week')
   list(attr(w, 'exposure'), attr(w, 'volatility'), attr(w, 'state'), attr(w, 'thresholds'))",
   "w = T.tactical_conditional_volatility(d, {'A': 0.7, 'B': 0.3}, safe='CASH', base=0.8, min_history=1, every='week')
result = [w.attrs['exposure'], w.attrs['volatility'], w.attrs['state'], w.attrs['thresholds']]",
   jl = 'w = T.tactical_conditional_volatility(d, SL.named("A" => 0.7, "B" => 0.3), "CASH"; base = 0.8, min_history = 1, every = "week")
result = [SL.attrs(w)["exposure"], SL.attrs(w)["volatility"], SL.attrs(w)["state"], SL.attrs(w)["thresholds"]]')
cs("cv_fixed", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 0.7, min_history = 1, scaling = 'fixed', high_exposure = 0.3, low_exposure = 0.9)",
   "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=0.7, min_history=1, scaling='fixed', high_exposure=0.3, low_exposure=0.9)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 0.7, min_history = 1, scaling = "fixed", high_exposure = 0.3, low_exposure = 0.9)')
cs("cv_fixed_nolow", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 0.7, min_history = 1, scaling = 'fixed', high_exposure = 0.2, lower = NULL)",
   "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=0.7, min_history=1, scaling='fixed', high_exposure=0.2, lower=None)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 0.7, min_history = 1, scaling = "fixed", high_exposure = 0.2, lower = nothing)')
cs("cv_msg", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', min_history = 1)", "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', min_history=1)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; min_history = 1)')
cs("cv_nolower", "w <- tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', lower = NULL, min_history = 1, upper = 0.7, target = 12, every = 'day'); list(w, attr(w, 'thresholds'), attr(w, 'state'))",
   "w = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', lower=None, min_history=1, upper=0.7, target=12, every='day'); result = [w, w.attrs['thresholds'], w.attrs['state']]",
   jl = 'w = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; lower = nothing, min_history = 1, upper = 0.7, target = 12, every = "day"); result = [w, SL.attrs(w)["thresholds"], SL.attrs(w)["state"]]')
cs("cv_target_warn", "tactical_conditional_volatility(d, c(B = 1), safe = 'C', base = 0.5, min_history = 1.5, target = 0.12, min_exposure = 0.2, max_exposure = 0.9, every = 'quarter')",
   "result = T.tactical_conditional_volatility(d, {'B': 1}, safe='C', base=0.5, min_history=1.5, target=0.12, min_exposure=0.2, max_exposure=0.9, every='quarter')",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("B" => 1), "C"; base = 0.5, min_history = 1.5, target = 0.12, min_exposure = 0.2, max_exposure = 0.9, every = "quarter")')
cs("cv_warn_hist", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 0.8, min_history = 10)",
   "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=0.8, min_history=10)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 0.8, min_history = 10)')
cs("cv_err_kredit", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', max_exposure = 1.5)", "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', max_exposure=1.5)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; max_exposure = 1.5)')
cs("cv_err_base", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 1.2, max_exposure = 1)", "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=1.2)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 1.2, max_exposure = 1)')
cs("cv_err_min", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 0.5, min_exposure = 0.6)", "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=0.5, min_exposure=0.6)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 0.5, min_exposure = 0.6)')
cs("cv_err_upper", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', upper = 1)", "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', upper=1)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; upper = 1)')
cs("cv_err_lower", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', lower = 0.9)", "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', lower=0.9)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; lower = 0.9)')
cs("cv_err_fixed", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', scaling = 'fixed', high_exposure = 0.3)",
   "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', scaling='fixed', high_exposure=0.3)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; scaling = "fixed", high_exposure = 0.3)')
cs("cv_err_high", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 0.5, scaling = 'fixed', high_exposure = 0.6, lower = NULL)",
   "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=0.5, scaling='fixed', high_exposure=0.6, lower=None)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 0.5, scaling = "fixed", high_exposure = 0.6, lower = nothing)')
cs("cv_err_low", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 0.5, scaling = 'fixed', high_exposure = 0.3, low_exposure = 0.4)",
   "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=0.5, scaling='fixed', high_exposure=0.3, low_exposure=0.4)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 0.5, scaling = "fixed", high_exposure = 0.3, low_exposure = 0.4)')
cs("cv_err_short", "tactical_conditional_volatility(d[1:40, ], c(A = 1), safe = 'CASH', base = 0.8)", "result = T.tactical_conditional_volatility(d.iloc[:40], {'A': 1}, safe='CASH', base=0.8)",
   jl = 'result = T.tactical_conditional_volatility(SL.rows(d, 1:40), SL.named("A" => 1), "CASH"; base = 0.8)')

# ── tactical_glidepath, tactical_blend ─────────────────────────────────────────────────
cs("gp_basic", "tactical_glidepath(d, from = c(A = 0.9, C = 0.1), to = c(A = 0.3, C = 0.7))", "result = T.tactical_glidepath(d, from_={'A': 0.9, 'C': 0.1}, to={'A': 0.3, 'C': 0.7})",
   jl = 'result = T.tactical_glidepath(d, SL.named("A" => 0.9, "C" => 0.1), SL.named("A" => 0.3, "C" => 0.7))')
cs("gp_dates", "tactical_glidepath(seq.Date(as.Date('2025-01-01'), as.Date('2030-12-31'), by = 'day'), from = c(aktien = 0.9, anleihen = 0.1),
                 to = c(anleihen = 0.6, geld = 0.4), start = '2026-03-01', end = as.Date('2029-06-30'), every = 'quarter')",
   "result = T.tactical_glidepath(np.arange(np.datetime64('2025-01-01'), np.datetime64('2031-01-01')), from_={'aktien': 0.9, 'anleihen': 0.1},
                    to={'anleihen': 0.6, 'geld': 0.4}, start='2026-03-01', end=np.datetime64('2029-06-30'), every='quarter')",
   jl = 'result = T.tactical_glidepath(collect(Date(2025, 1, 1):Day(1):Date(2030, 12, 31)), SL.named("aktien" => 0.9, "anleihen" => 0.1),
                    SL.named("anleihen" => 0.6, "geld" => 0.4); start = "2026-03-01", end_ = Date(2029, 6, 30), every = "quarter")')
cs("gp_month", "tactical_glidepath(d, from = c(A = 1), to = c(B = 1), every = 'month', start = '2011-01-01', end = '2014-01-01')",
   "result = T.tactical_glidepath(d, from_={'A': 1}, to={'B': 1}, every='month', start='2011-01-01', end='2014-01-01')",
   jl = 'result = T.tactical_glidepath(d, SL.named("A" => 1), SL.named("B" => 1); every = "month", start = "2011-01-01", end_ = "2014-01-01")')
cs("gp_jump", "tactical_glidepath(d, from = c(A = 0.9, C = 0.1), to = c(A = 0.4, C = 0.6), start = '2013-06-15', end = '2013-06-15')",
   "result = T.tactical_glidepath(d, from_={'A': 0.9, 'C': 0.1}, to={'A': 0.4, 'C': 0.6}, start='2013-06-15', end='2013-06-15')",
   jl = 'result = T.tactical_glidepath(d, SL.named("A" => 0.9, "C" => 0.1), SL.named("A" => 0.4, "C" => 0.6); start = "2013-06-15", end_ = "2013-06-15")')
cs("gp_err", "tactical_glidepath(d, from = c(A = 0.9, C = 0.1), to = c(A = 0.4, C = 0.6), start = '2014-01-01', end = '2013-01-01')",
   "result = T.tactical_glidepath(d, from_={'A': 0.9, 'C': 0.1}, to={'A': 0.4, 'C': 0.6}, start='2014-01-01', end='2013-01-01')",
   jl = 'result = T.tactical_glidepath(d, SL.named("A" => 0.9, "C" => 0.1), SL.named("A" => 0.4, "C" => 0.6); start = "2014-01-01", end_ = "2013-01-01")')
cs("gp_err_date", "tactical_glidepath(d, from = c(A = 1), to = c(B = 1), start = '01.01.2013')", "result = T.tactical_glidepath(d, from_={'A': 1}, to={'B': 1}, start='01.01.2013')",
   jl = 'result = T.tactical_glidepath(d, SL.named("A" => 1), SL.named("B" => 1); start = "01.01.2013")')
cs("bl_basic", "gp <- tactical_glidepath(d, from = c(A = 0.9, C = 0.1), to = c(A = 0.3, C = 0.7)); ro <- tactical_rotation(d, c('A', 'B'), top = 1, safe = c('C', 'CASH'))
   tactical_blend(x = gp, y = ro, shares = c(0.5, 0.5))",
   "gp = T.tactical_glidepath(d, from_={'A': 0.9, 'C': 0.1}, to={'A': 0.3, 'C': 0.7}); ro = T.tactical_rotation(d, ['A', 'B'], top=1, safe=['C', 'CASH'])
result = T.tactical_blend(gp, ro, shares=[0.5, 0.5])",
   jl = 'gp = T.tactical_glidepath(d, SL.named("A" => 0.9, "C" => 0.1), SL.named("A" => 0.3, "C" => 0.7)); ro = T.tactical_rotation(d, ["A", "B"]; top = 1, safe = ["C", "CASH"])
result = T.tactical_blend(gp, ro; shares = [0.5, 0.5])')
cs("bl_default", "tactical_blend(tactical_rules(d, list(), default = c(A = 1)), tactical_rules(d, list(), default = c(B = 1)), tactical_rules(d, list(list(when = 'A > B', weights = c(C = 1))), default = c(CASH = 1)))",
   "result = T.tactical_blend(T.tactical_rules(d, [], default={'A': 1}), T.tactical_rules(d, [], default={'B': 1}), T.tactical_rules(d, [{'when': 'A > B', 'weights': {'C': 1}}], default={'CASH': 1}))",
   jl = 'result = T.tactical_blend(T.tactical_rules(d, [], SL.named("A" => 1)), T.tactical_rules(d, [], SL.named("B" => 1)), T.tactical_rules(d, [SL.RList("when" => "A > B", "weights" => SL.named("C" => 1))], SL.named("CASH" => 1)))')
cs("bl_shares", "tactical_blend(tactical_rules(d, list(), default = c(A = 1)), tactical_rules(d, list(), default = c(B = 1)), shares = c(3, 1))",
   "result = T.tactical_blend(T.tactical_rules(d, [], default={'A': 1}), T.tactical_rules(d, [], default={'B': 1}), shares=[3, 1])",
   jl = 'result = T.tactical_blend(T.tactical_rules(d, [], SL.named("A" => 1)), T.tactical_rules(d, [], SL.named("B" => 1)); shares = [3, 1])')
cs("bl_err_shares", "tactical_blend(tactical_rules(d, list(), default = c(A = 1)), tactical_rules(d, list(), default = c(B = 1)), shares = 0.7)",
   "result = T.tactical_blend(T.tactical_rules(d, [], default={'A': 1}), T.tactical_rules(d, [], default={'B': 1}), shares=0.7)",
   jl = 'result = T.tactical_blend(T.tactical_rules(d, [], SL.named("A" => 1)), T.tactical_rules(d, [], SL.named("B" => 1)); shares = 0.7)')
cs("bl_err_neg", "tactical_blend(tactical_rules(d, list(), default = c(A = 1)), tactical_rules(d, list(), default = c(B = 1)), shares = c(0.5, -0.25))",
   "result = T.tactical_blend(T.tactical_rules(d, [], default={'A': 1}), T.tactical_rules(d, [], default={'B': 1}), shares=[0.5, -0.25])",
   jl = 'result = T.tactical_blend(T.tactical_rules(d, [], SL.named("A" => 1)), T.tactical_rules(d, [], SL.named("B" => 1)); shares = [0.5, -0.25])')
cs("bl_err_type", "tactical_blend(c(A = 1))", "result = T.tactical_blend({'A': 1})",
   jl = 'result = T.tactical_blend(SL.named("A" => 1))')
cs("bl_err_empty", "tactical_blend()", "result = T.tactical_blend()",
   jl = 'result = T.tactical_blend()')
cs("bl_err_dates", "tactical_blend(tactical_rules(d, list(), default = c(A = 1)), tactical_rules(d[1:10, ], list(), default = c(B = 1)))",
   "result = T.tactical_blend(T.tactical_rules(d, [], default={'A': 1}), T.tactical_rules(d.iloc[:10], [], default={'B': 1}))",
   jl = 'result = T.tactical_blend(T.tactical_rules(d, [], SL.named("A" => 1)), T.tactical_rules(SL.rows(d, 1:10), [], SL.named("B" => 1)))')

# ── interne Helfer ───────────────────────────────────────────────────────────
cs("helpers", "dd <- d$date[1:800]; list(SimLev:::.period_last(dd, 'day')[1:5], SimLev:::.period_last(dd, 'week'), SimLev:::.period_last(dd, 'month'),
                SimLev:::.period_last(dd, 'quarter'), SimLev:::.period_last(dd, 'year'),
                SimLev:::.hold_rows(10L, c(3L, 7L), matrix(1:6, 2, dimnames = list(NULL, c('x', 'y', 'z')))))",
   "dd = d['date'].to_numpy()[:800]; result = [T._period_last(dd, 'day')[:5], T._period_last(dd, 'week'), T._period_last(dd, 'month'),
          T._period_last(dd, 'quarter'), T._period_last(dd, 'year'),
          T._hold_rows(10, [3, 7], pd.DataFrame([[1., 3, 5], [2, 4, 6]], columns=['x', 'y', 'z']))]",
   jl = 'dd = d.date[1:800]; result = [T._period_last(dd, "day")[1:5], T._period_last(dd, "week"), T._period_last(dd, "month"),
          T._period_last(dd, "quarter"), T._period_last(dd, "year"),
          T._hold_rows(10, [3, 7], SL.NamedMat([1.0 3 5; 2 4 6]; colnames = ["x", "y", "z"]))]')
cs("helpers_err", "SimLev:::.period_last(d$date, 'decade')", "result = T._period_last(d['date'], 'decade')",
   jl = 'result = T._period_last(d.date, "decade")')
cs("as_weights_err", "SimLev:::.as_weights(d$date[1:3], matrix(c(1, 0, NA, 0, -1, 0), 3))", "result = T._as_weights(d['date'][:3], np.array([[1, 0], [0, -1], [simlev._r.fmt.NA_REAL, 0]]))",
   jl = 'result = T._as_weights(d.date[1:3], [1 0; 0 -1; SL.NA 0])')

# ── tactical_simulation ──────────────────────────────────────────────────────
ds <- make_mkt(365 * 3)[, c("date", "A", "C")]
set.seed(9); b2 <- runif(nrow(ds)) < 0.01; s2 <- runif(nrow(ds)) < 0.01
I3 <- list(ds = ds, b2 = b2, s2 = s2)
tsim <- function(id, r, py, inputs = I3, jl) cs(id, paste0(r, "; list(tactical = res$tactical, worth = res$worth, dates = res$dates)"),
                                            paste0(py, "\nresult = {'tactical': res.tactical, 'worth': res.worth, 'dates': res.dates}"), inputs = inputs,
                                            jl = paste0(jl, '\nresult = SL.RList("tactical" => res.tactical, "worth" => res.worth, "dates" => res.dates)'))
tsim("ts_rules", "wr <- tactical_rules(ds, list(list(when = list(buy = b2, sell = s2), weights = c(A = 1))), default = c(C = 1))
   res <- tactical_simulation(ds, wr, lag = 1, asset_args = list(spread = 0))",
   "wr = T.tactical_rules(ds, [{'when': {'buy': b2, 'sell': s2}, 'weights': {'A': 1}}], default={'C': 1})
res = T.tactical_simulation(ds, wr, lag=1, asset_args={'spread': 0})",
   jl = 'wr = T.tactical_rules(ds, [SL.RList("when" => SL.RList("buy" => b2, "sell" => s2), "weights" => SL.named("A" => 1))], SL.named("C" => 1))
res = T.tactical_simulation(ds, wr; lag = 1, asset_args = (spread = 0,))')
tsim("ts_year_lag0", "ws <- tactical_rules(ds, list(), default = c(A = 0.6, C = 0.4))
   res <- tactical_simulation(ds, ws, rebalance = 'year', lag = 0, asset_args = list(spread = 0))",
   "ws = T.tactical_rules(ds, [], default={'A': 0.6, 'C': 0.4})
res = T.tactical_simulation(ds, ws, rebalance='year', lag=0, asset_args={'spread': 0})",
   jl = 'ws = T.tactical_rules(ds, [], SL.named("A" => 0.6, "C" => 0.4))
res = T.tactical_simulation(ds, ws; rebalance = "year", lag = 0, asset_args = (spread = 0,))')
tsim("ts_tol", "ws <- tactical_glidepath(ds, from = c(A = 0.8, C = 0.2), to = c(A = 0.4, C = 0.6), every = 'quarter')
   res <- tactical_simulation(ds, ws, rebalance = 'month', tolerance = 5, lag = 2, asset_args = list(spread = 0.1, partial_exemption = c(A = 30, C = 0)))",
   "ws = T.tactical_glidepath(ds, from_={'A': 0.8, 'C': 0.2}, to={'A': 0.4, 'C': 0.6}, every='quarter')
res = T.tactical_simulation(ds, ws, rebalance='month', tolerance=5, lag=2, asset_args={'spread': 0.1, 'partial_exemption': pd.Series({'A': 30, 'C': 0})})",
   jl = 'ws = T.tactical_glidepath(ds, SL.named("A" => 0.8, "C" => 0.2), SL.named("A" => 0.4, "C" => 0.6); every = "quarter")
res = T.tactical_simulation(ds, ws; rebalance = "month", tolerance = 5, lag = 2, asset_args = (spread = 0.1, partial_exemption = SL.named("A" => 30, "C" => 0)))')
tsim("ts_rel_tax", "ws <- tactical_rules(ds, list(list(when = list(buy = b2, sell = s2), weights = c(A = 0.7, C = 0.3))), default = c(A = 0.2, C = 0.8))
   res <- tactical_simulation(ds, ws, rebalance = 'quarter', tolerance = 20, tolerance_type = 'relative', tax = tax_profile(), start_value = 50000, asset_args = list(spread = 0.1))",
   "ws = T.tactical_rules(ds, [{'when': {'buy': b2, 'sell': s2}, 'weights': {'A': 0.7, 'C': 0.3}}], default={'A': 0.2, 'C': 0.8})
res = T.tactical_simulation(ds, ws, rebalance='quarter', tolerance=20, tolerance_type='relative', tax=simlev.tax_profile(), start_value=50000, asset_args={'spread': 0.1})",
   jl = 'ws = T.tactical_rules(ds, [SL.RList("when" => SL.RList("buy" => b2, "sell" => s2), "weights" => SL.named("A" => 0.7, "C" => 0.3))], SL.named("A" => 0.2, "C" => 0.8))
res = T.tactical_simulation(ds, ws; rebalance = "quarter", tolerance = 20, tolerance_type = "relative", tax = SL.tax_profile(), start_value = 50000, asset_args = (spread = 0.1,))')
tsim("ts_dca", "ws <- tactical_rules(ds, list(list(when = list(buy = b2, sell = s2), weights = c(A = 1))), default = c(A = 0.3, C = 0.7))
   res <- tactical_simulation(ds, ws, dca = dca_plan(500, 1, unit = 'quarter'), asset_args = list(spread = 0.1))",
   "ws = T.tactical_rules(ds, [{'when': {'buy': b2, 'sell': s2}, 'weights': {'A': 1}}], default={'A': 0.3, 'C': 0.7})
res = T.tactical_simulation(ds, ws, dca=simlev.dca_plan(500, 1, unit='quarter'), asset_args={'spread': 0.1})",
   jl = 'ws = T.tactical_rules(ds, [SL.RList("when" => SL.RList("buy" => b2, "sell" => s2), "weights" => SL.named("A" => 1))], SL.named("A" => 0.3, "C" => 0.7))
res = T.tactical_simulation(ds, ws; dca = SL.dca_plan(500, 1; unit = "quarter"), asset_args = (spread = 0.1,))')
cal <- seq.Date(as.Date("2021-01-04"), as.Date("2021-03-31"), by = "day")
wkd <- cal[!format(cal, "%u") %in% c("6", "7")]
set.seed(11); al <- data.frame(date = cal, aktien = NA_real_, geld = 100)
al$aktien[match(wkd, cal)] <- 100 * cumprod(1 + rnorm(length(wkd), 0, 0.01))
fl <- cbind(aktien = is.na(al$aktien), geld = !cal %in% wkd)
al$aktien <- SimLev:::.fill_na(al$aktien, "locf")
I4 <- list(al = al, fl = fl)
tsim("ts_filled", "a2 <- al; attr(a2, 'filled') <- fl
   w <- tactical_rules(a2, list(list(when = a2$date >= as.Date('2021-02-05'), weights = c(aktien = 1))), default = c(geld = 1))
   res <- tactical_simulation(a2, w, lag = 1, asset_args = list(spread = 0))",
   "a2 = al.copy(); a2.attrs['filled'] = fl
w = T.tactical_rules(a2, [{'when': a2['date'] >= np.datetime64('2021-02-05'), 'weights': {'aktien': 1}}], default={'geld': 1})
res = T.tactical_simulation(a2, w, lag=1, asset_args={'spread': 0})", inputs = I4,
   jl = 'a2 = copy(al); SL.attrs(a2)["filled"] = fl
w = T.tactical_rules(a2, [SL.RList("when" => a2.date .>= Date(2021, 2, 5), "weights" => SL.named("aktien" => 1))], SL.named("geld" => 1))
res = T.tactical_simulation(a2, w; lag = 1, asset_args = (spread = 0,))')
tsim("ts_nofilled", "w <- tactical_rules(al, list(list(when = al$date >= as.Date('2021-02-05'), weights = c(aktien = 1))), default = c(geld = 1))
   res <- tactical_simulation(al, w, lag = 1, asset_args = list(spread = 0))",
   "w = T.tactical_rules(al, [{'when': al['date'] >= np.datetime64('2021-02-05'), 'weights': {'aktien': 1}}], default={'geld': 1})
res = T.tactical_simulation(al, w, lag=1, asset_args={'spread': 0})", inputs = I4,
   jl = 'w = T.tactical_rules(al, [SL.RList("when" => al.date .>= Date(2021, 2, 5), "weights" => SL.named("aktien" => 1))], SL.named("geld" => 1))
res = T.tactical_simulation(al, w; lag = 1, asset_args = (spread = 0,))')
tsim("ts_gaps", "ws <- tactical_rules(ds[seq(1, nrow(ds), 3), ], list(list(when = 'A > 101', weights = c(A = 1))), default = c(C = 1))
   res <- tactical_simulation(ds, ws, lag = 3, asset_args = list(spread = 0.1))",
   "ws = T.tactical_rules(ds.iloc[::3].reset_index(drop=True), [{'when': 'A > 101', 'weights': {'A': 1}}], default={'C': 1})
res = T.tactical_simulation(ds, ws, lag=3, asset_args={'spread': 0.1})",
   jl = 'ws = T.tactical_rules(SL.rows(ds, 1:3:SL.nrow(ds)), [SL.RList("when" => "A > 101", "weights" => SL.named("A" => 1))], SL.named("C" => 1))
res = T.tactical_simulation(ds, ws; lag = 3, asset_args = (spread = 0.1,))')
cs("ts_err_w", "tactical_simulation(ds, c(A = 1))", "result = T.tactical_simulation(ds, {'A': 1})", inputs = I3,
   jl = 'result = T.tactical_simulation(ds, SL.named("A" => 1))')
cs("ts_err_flat", "tactical_simulation(ds, tactical_rules(ds, list(), default = c(A = 1)), dca_mode = TRUE, dca_value = 100)",
   "result = T.tactical_simulation(ds, T.tactical_rules(ds, [], default={'A': 1}), dca_mode=True, dca_value=100)", inputs = I3,
   jl = 'result = T.tactical_simulation(ds, T.tactical_rules(ds, [], SL.named("A" => 1)); dca_mode = true, dca_value = 100)')
cs("ts_err_args", "tactical_simulation(ds, tactical_rules(ds, list(), default = c(A = 1)), balance_mode = TRUE, event_col = 'x')",
   "result = T.tactical_simulation(ds, T.tactical_rules(ds, [], default={'A': 1}), balance_mode=True, event_col='x')", inputs = I3,
   jl = 'result = T.tactical_simulation(ds, T.tactical_rules(ds, [], SL.named("A" => 1)); balance_mode = true, event_col = "x")')
cs("ts_err_cols", "tactical_simulation(ds, tactical_rules(ds, list(), default = c(A = 1, X = 1, Y = 1)))",
   "result = T.tactical_simulation(ds, T.tactical_rules(ds, [], default={'A': 1, 'X': 1, 'Y': 1}))", inputs = I3,
   jl = 'result = T.tactical_simulation(ds, T.tactical_rules(ds, [], SL.named("A" => 1, "X" => 1, "Y" => 1)))')
cs("ts_err_lag", "tactical_simulation(ds, tactical_rules(ds, list(), default = c(A = 1)), lag = -1)",
   "result = T.tactical_simulation(ds, T.tactical_rules(ds, [], default={'A': 1}), lag=-1)", inputs = I3,
   jl = 'result = T.tactical_simulation(ds, T.tactical_rules(ds, [], SL.named("A" => 1)); lag = -1)')
cs("ts_err_lag2", "tactical_simulation(ds, tactical_rules(ds, list(), default = c(A = 1)), lag = 'x')",
   "result = T.tactical_simulation(ds, T.tactical_rules(ds, [], default={'A': 1}), lag='x')", inputs = I3,
   jl = 'result = T.tactical_simulation(ds, T.tactical_rules(ds, [], SL.named("A" => 1)); lag = "x")')
ref_done()

ref_schreiben()
