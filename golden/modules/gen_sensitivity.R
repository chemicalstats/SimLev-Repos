# Referenzfälle für sensitivity.R (sensitivity_grid, sensitivity_rebalancing,
# planning_lumpsum_vs_dca, series_leverage, sensitivity_leverage, print-Methoden).
source("golden/modules/ref_tools.R"); ref_init("sensitivity")
P <- paste0("import simlev.sensitivity as SE\nfrom simlev.config import create_strategy, asset_config\n",
            "from simlev import dca_plan, rebalance_plan, tax_profile, income_rate\n",
            "st = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.6), B=asset_config(asset_class='etf', trading='bnh', share=0.4))\n",
            "st0 = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.6, spread=0), B=asset_config(asset_class='etf', trading='bnh', share=0.4, spread=0))\n",
            "st1 = create_strategy(A=asset_config(asset_class='etf', trading='bnh'))\n")
R0 <- paste0("st <- create_strategy(A = asset_config('etf', 'bnh', 0.6), B = asset_config('etf', 'bnh', 0.4))\n",
             "st0 <- create_strategy(A = asset_config('etf', 'bnh', 0.6, spread = 0), B = asset_config('etf', 'bnh', 0.4, spread = 0))\n",
             "st1 <- create_strategy(A = asset_config('etf', 'bnh'))\n")
set.seed(1); n <- 1100
d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
d$A <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)); d$B <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.004))
d$zins <- 1 + (seq_len(n) > 500)
set.seed(2); m <- 5 * 365
d5 <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = m))
d5$A <- 100 * cumprod(1 + rnorm(m, 3e-4, 0.01)); d5$B <- 100 * cumprod(1 + rnorm(m, 1e-4, 0.004))
dn <- d; dn$A[c(5, 6, 300)] <- NA
rdf <- data.frame(date = as.Date(c("2015-01-01", "2016-01-01")), value = c(1, 3))
I <- list(d = d, d5 = d5, dn = dn, rdf = rdf)
J0 <- 'const SE = SL.Sensitivity
st = create_strategy("A" => asset_config("etf", "bnh", 0.6), "B" => asset_config("etf", "bnh", 0.4))
st0 = create_strategy("A" => asset_config("etf", "bnh", 0.6; spread = 0), "B" => asset_config("etf", "bnh", 0.4; spread = 0))
st1 = create_strategy("A" => asset_config("etf", "bnh"))
'
case <- function(id, r, p, j, inputs = I, print = NA) ref_case(id, paste0(R0, r), paste0(P, p), inputs, print = print, jl = paste0(J0, j))

# ── sensitivity_grid ────────────────────────────────────────────────────────
case("sg_basic", "sensitivity_grid(d, st, list(rebalance.unit = c('month', 'year'), rebalance.thresh = c(NA, 5)), sim_args = list(rebalance = rebalance_plan(span = 1)))",
     "result = SE.sensitivity_grid(d, st, {'rebalance.unit': ['month', 'year'], 'rebalance.thresh': [None, 5]}, sim_args={'rebalance': rebalance_plan(span=1)})",
     'result = SE.sensitivity_grid(d, st, RList("rebalance.unit" => ["month", "year"], "rebalance.thresh" => [NA, 5.0]); sim_args = RList("rebalance" => SL.rebalance_plan(; span = 1)))')
case("sg_df", "g <- data.frame(row.names = 1:2); g$splits.thresh <- list(c(50, 120), c(80, 110)); sensitivity_grid(d, st1, g)",
     "g = pd.DataFrame({'splits.thresh': pd.Series([[50.0, 120.0], [80.0, 110.0]], dtype=object)}); result = SE.sensitivity_grid(d, st1, g)",
     'g = RFrame("splits.thresh" => [[50.0, 120.0], [80.0, 110.0]]); result = SE.sensitivity_grid(d, st1, g)')
case("sg_keep", "g <- sensitivity_grid(d, st, list(rebalance.span = c(1, 3)), sim_args = list(rebalance = rebalance_plan()), keep_results = TRUE); r <- attr(g, 'results'); c(length(r), r[[2]]$cagr, r[[1]]$worth[100])",
     "g = SE.sensitivity_grid(d, st, {'rebalance.span': [1, 3]}, sim_args={'rebalance': rebalance_plan()}, keep_results=True); r = g.attrs['results']; result = [len(r), r[1].cagr, r[0].worth[99]]",
     'g = SE.sensitivity_grid(d, st, RList("rebalance.span" => [1.0, 3.0]); sim_args = RList("rebalance" => SL.rebalance_plan()), keep_results = true); r = attrs(g)["results"]; result = [length(r), r[2].cagr, r[1].worth[100]]')
case("sg_errsome", "sensitivity_grid(d, st, list(rebalance.unit = c('month', 'monat')), sim_args = list(rebalance = rebalance_plan(span = 1)))",
     "result = SE.sensitivity_grid(d, st, {'rebalance.unit': ['month', 'monat']}, sim_args={'rebalance': rebalance_plan(span=1)})",
     'result = SE.sensitivity_grid(d, st, RList("rebalance.unit" => ["month", "monat"]); sim_args = RList("rebalance" => SL.rebalance_plan(; span = 1)))')
case("sg_errall", "sensitivity_grid(d, st, list(rebalance.thresh = c(5, 10), rebalance.unit = 'monat'))",
     "result = SE.sensitivity_grid(d, st, {'rebalance.thresh': [5, 10], 'rebalance.unit': ['monat']})",
     'result = SE.sensitivity_grid(d, st, RList("rebalance.thresh" => [5.0, 10.0], "rebalance.unit" => ["monat"]))')
case("sg_empty", "sensitivity_grid(d, st, data.frame(rebalance.thresh = numeric(0)))",
     "result = SE.sensitivity_grid(d, st, pd.DataFrame({'rebalance.thresh': np.zeros(0)}))",
     'result = SE.sensitivity_grid(d, st, RFrame("rebalance.thresh" => Float64[]))')
case("sg_metric1", "sensitivity_grid(d, st, list(start_value = c(1000, 5000)), metrics = function(r) c(end = tail(r$worth, 1)))",
     "result = SE.sensitivity_grid(d, st, {'start_value': [1000.0, 5000.0]}, metrics=lambda r: pd.Series({'end': r.worth[-1]}))",
     'result = SE.sensitivity_grid(d, st, RList("start_value" => [1000.0, 5000.0]); metrics = r -> named("end" => r.worth[end]))')
# Pfade zu Bausteinparametern (Etappe 6.4, F1)
case("sg_path_tax", "sensitivity_grid(d, st, list(tax.rate = c(20, 26.375), dca.value = c(100, 200)), sim_args = list(tax = tax_profile(), dca = dca_plan(50, 1), liquidate = TRUE))",
     "result = SE.sensitivity_grid(d, st, {'tax.rate': [20, 26.375], 'dca.value': [100, 200]}, sim_args={'tax': tax_profile(), 'dca': dca_plan(50, 1), 'liquidate': True})",
     'result = SE.sensitivity_grid(d, st, RList("tax.rate" => [20, 26.375], "dca.value" => [100, 200]); sim_args = RList("tax" => SL.tax_profile(), "dca" => SL.dca_plan(50, 1), "liquidate" => true))')
case("sg_path_church", "sensitivity_grid(d, st, list(tax.church_tax = c(0, 9)), sim_args = list(tax = tax_profile(church_tax = 8), liquidate = TRUE))",
     "result = SE.sensitivity_grid(d, st, {'tax.church_tax': [0, 9]}, sim_args={'tax': tax_profile(church_tax=8), 'liquidate': True})",
     'result = SE.sensitivity_grid(d, st, RList("tax.church_tax" => [0, 9]); sim_args = RList("tax" => SL.tax_profile(; church_tax = 8), "liquidate" => true))')
case("sg_path_sub", "sensitivity_grid(d, st, list(tax.income.marginal_rate = c(14, 42), tax.harvest.day = c('06-30', '12-15')), sim_args = list(tax = tax_profile(guenstigerpruefung = TRUE)))",
     "result = SE.sensitivity_grid(d, st, {'tax.income.marginal_rate': [14, 42], 'tax.harvest.day': ['06-30', '12-15']}, sim_args={'tax': tax_profile(guenstigerpruefung=True)})",
     'result = SE.sensitivity_grid(d, st, RList("tax.income.marginal_rate" => [14, 42], "tax.harvest.day" => ["06-30", "12-15"]); sim_args = RList("tax" => SL.tax_profile(; guenstigerpruefung = true)))')
case("sg_path_nobase", "sensitivity_grid(d, st, list(dca.value = c(100, 200), dca.span = c(1, 3)))",
     "result = SE.sensitivity_grid(d, st, {'dca.value': [100, 200], 'dca.span': [1, 3]})",
     'result = SE.sensitivity_grid(d, st, RList("dca.value" => [100, 200], "dca.span" => [1, 3]))')
case("sg_path_novalue", "sensitivity_grid(d, st, list(dca.span = c(1, 3)))",
     "result = SE.sensitivity_grid(d, st, {'dca.span': [1, 3]})",
     'result = SE.sensitivity_grid(d, st, RList("dca.span" => [1, 3]))')
case("sg_err_flat", "sensitivity_grid(d, st, list(balance_unit = c('month', 'year')))",
     "result = SE.sensitivity_grid(d, st, {'balance_unit': ['month', 'year']})",
     'result = SE.sensitivity_grid(d, st, RList("balance_unit" => ["month", "year"]))')
case("sg_err_flat2", "sensitivity_grid(d, st, list(marginal_tax_rate = c(14, 42)))",
     "result = SE.sensitivity_grid(d, st, {'marginal_tax_rate': [14, 42]})",
     'result = SE.sensitivity_grid(d, st, RList("marginal_tax_rate" => [14, 42]))')
case("sg_err_simargs", "sensitivity_grid(d, st, list(start_value = 1000), sim_args = list(dca_mode = TRUE, dca_value = 100))",
     "result = SE.sensitivity_grid(d, st, {'start_value': [1000]}, sim_args={'dca_mode': True, 'dca_value': 100})",
     'result = SE.sensitivity_grid(d, st, RList("start_value" => [1000]); sim_args = RList("dca_mode" => true, "dca_value" => 100))')
case("sg_err_path", "sensitivity_grid(d, st, list(dca.valu = 1))", "result = SE.sensitivity_grid(d, st, {'dca.valu': [1]})",
     'result = SE.sensitivity_grid(d, st, RList("dca.valu" => [1]))')
case("sg_err_block", "sensitivity_grid(d, st, list(foo.bar = 1))", "result = SE.sensitivity_grid(d, st, {'foo.bar': [1]})",
     'result = SE.sensitivity_grid(d, st, RList("foo.bar" => [1]))')
case("sg_err_arg", "sensitivity_grid(d, st, list(foo = 1))", "result = SE.sensitivity_grid(d, st, {'foo': [1]})",
     'result = SE.sensitivity_grid(d, st, RList("foo" => [1]))')

# ── sensitivity_rebalancing ─────────────────────────────────────────────────
case("rs_bands", "sensitivity_rebalancing(d, st, frequencies = list(monthly = c('month', 1), yearly = c('year', 1)), bands = c(NA, 5))",
     "result = SE.sensitivity_rebalancing(d, st, frequencies={'monthly': ('month', 1), 'yearly': ('year', 1)}, bands=[None, 5])",
     'result = SE.sensitivity_rebalancing(d, st; frequencies = ["monthly" => ("month", 1), "yearly" => ("year", 1)], bands = [NA, 5.0])')
case("rs_offsets", "sensitivity_rebalancing(d, st, frequencies = list(quarterly = c('quarter', 1)), offsets = c(0, 5), include_none = FALSE)",
     "result = SE.sensitivity_rebalancing(d, st, frequencies={'quarterly': ('quarter', 1)}, offsets=[0, 5], include_none=False)",
     'result = SE.sensitivity_rebalancing(d, st; frequencies = ["quarterly" => ("quarter", 1)], offsets = [0, 5], include_none = false)')
case("rs_relative", "sensitivity_rebalancing(d, st, frequencies = list(q = c('quarter', 1), y = c('year', 1)), offsets = c(0, 5), bands = c(NA, 10), band_type = 'relative')",
     "result = SE.sensitivity_rebalancing(d, st, frequencies={'q': ('quarter', 1), 'y': ('year', 1)}, offsets=[0, 5], bands=[None, 10], band_type='relative')",
     'result = SE.sensitivity_rebalancing(d, st; frequencies = ["q" => ("quarter", 1), "y" => ("year", 1)], offsets = [0, 5], bands = [NA, 10.0], band_type = "relative")')
case("rs_band1", "sensitivity_rebalancing(d, st, frequencies = list(y = c('year', 1)), bands = 3)",
     "result = SE.sensitivity_rebalancing(d, st, frequencies={'y': ('year', 1)}, bands=3)",
     'result = SE.sensitivity_rebalancing(d, st; frequencies = ["y" => ("year", 1)], bands = 3)')
case("rs_dca", "sensitivity_rebalancing(d, st, frequencies = list(yearly = c('year', 1)), sim_args = list(dca = dca_plan(100, 1)))",
     "result = SE.sensitivity_rebalancing(d, st, frequencies={'yearly': ('year', 1)}, sim_args={'dca': dca_plan(100, 1)})",
     'result = SE.sensitivity_rebalancing(d, st; frequencies = ["yearly" => ("year", 1)], sim_args = RList("dca" => SL.dca_plan(100, 1)))')
# rebalance_plan() in sim_args liefert die Grundwerte (Etappe 6.4): Bezugsdatum bleibt je Lauf erhalten
case("rs_base", "sensitivity_rebalancing(d, st, frequencies = list(q = c('quarter', 1), y = c('year', 1)), bands = c(NA, 5), sim_args = list(rebalance = rebalance_plan(start = '2015-02-15', skip = TRUE)))",
     "result = SE.sensitivity_rebalancing(d, st, frequencies={'q': ('quarter', 1), 'y': ('year', 1)}, bands=[None, 5], sim_args={'rebalance': rebalance_plan(start='2015-02-15', skip=True)})",
     'result = SE.sensitivity_rebalancing(d, st; frequencies = ["q" => ("quarter", 1), "y" => ("year", 1)], bands = [NA, 5.0], sim_args = RList("rebalance" => SL.rebalance_plan(; start = "2015-02-15", skip = true)))')
case("rs_default", "sensitivity_rebalancing(d, st)", "result = SE.sensitivity_rebalancing(d, st)",
     'result = SE.sensitivity_rebalancing(d, st)')
case("rs_errall", "sensitivity_rebalancing(d, st, frequencies = list(x = c('monat', 1)), include_none = FALSE)",
     "result = SE.sensitivity_rebalancing(d, st, frequencies={'x': ('monat', 1)}, include_none=False)",
     'result = SE.sensitivity_rebalancing(d, st; frequencies = ["x" => ("monat", 1)], include_none = false)')
case("rs_badtype", "sensitivity_rebalancing(d, st, band_type = 'foo')", "result = SE.sensitivity_rebalancing(d, st, band_type='foo')",
     'result = SE.sensitivity_rebalancing(d, st; band_type = "foo")')
case("rs_kind", "x <- sensitivity_rebalancing(d, st, frequencies = list(y = c('year', 1)), include_none = FALSE); attr(x, 'kind')",
     "x = SE.sensitivity_rebalancing(d, st, frequencies={'y': ('year', 1)}, include_none=False); result = x.attrs['kind']",
     'x = SE.sensitivity_rebalancing(d, st; frequencies = ["y" => ("year", 1)], include_none = false); result = attrs(x)["kind"]')

# ── planning_lumpsum_vs_dca ──────────────────────────────────────────────────────────
case("ls_basic", "planning_lumpsum_vs_dca(d5, st1, amount = 12000, months = 12, horizon = 3, step = 6)",
     "result = SE.planning_lumpsum_vs_dca(d5, st1, amount=12000, months=12, horizon=3, step=6)",
     'result = SE.planning_lumpsum_vs_dca(d5, st1; amount = 12000, months = 12, horizon = 3, step = 6)')
case("ls_summary", "x <- planning_lumpsum_vs_dca(d5, st1, amount = 12000, months = 12, horizon = 3, step = 6); list(attr(x, 'summary'), attr(x, 'settings'))",
     "x = SE.planning_lumpsum_vs_dca(d5, st1, amount=12000, months=12, horizon=3, step=6); result = [x.attrs['summary'], x.attrs['settings']]",
     'x = SE.planning_lumpsum_vs_dca(d5, st1; amount = 12000, months = 12, horizon = 3, step = 6); result = [attrs(x)["summary"], attrs(x)["settings"]]')
case("ls_exact2", "planning_lumpsum_vs_dca(d5, st0, amount = 6000, months = 6, horizon = 2, step = 12)",
     "result = SE.planning_lumpsum_vs_dca(d5, st0, amount=6000, months=6, horizon=2, step=12)",
     'result = SE.planning_lumpsum_vs_dca(d5, st0; amount = 6000, months = 6, horizon = 2, step = 12)')
case("ls_rebal", "x <- planning_lumpsum_vs_dca(d5, st0, amount = 6000, months = 6, horizon = 2, step = 12, sim_args = list(rebalance = rebalance_plan(span = 3))); list(x, attr(x, 'summary'))",
     "x = SE.planning_lumpsum_vs_dca(d5, st0, amount=6000, months=6, horizon=2, step=12, sim_args={'rebalance': rebalance_plan(span=3)}); result = [x, x.attrs['summary']]",
     'x = SE.planning_lumpsum_vs_dca(d5, st0; amount = 6000, months = 6, horizon = 2, step = 12, sim_args = RList("rebalance" => SL.rebalance_plan(; span = 3))); result = [x, attrs(x)["summary"]]')
case("ls_months1", "planning_lumpsum_vs_dca(d5, create_strategy(A = asset_config('etf', 'bnh', spread = 0)), months = 1, horizon = 2, step = 12)",
     "result = SE.planning_lumpsum_vs_dca(d5, create_strategy(A=asset_config(asset_class='etf', trading='bnh', spread=0)), months=1, horizon=2, step=12)",
     'result = SE.planning_lumpsum_vs_dca(d5, create_strategy("A" => asset_config("etf", "bnh"; spread = 0)); months = 1, horizon = 2, step = 12)')
case("ls_frac", "planning_lumpsum_vs_dca(d5, st1, months = 3, horizon = 2.5, step = 20)",
     "result = SE.planning_lumpsum_vs_dca(d5, st1, months=3, horizon=2.5, step=20)",
     'result = SE.planning_lumpsum_vs_dca(d5, st1; months = 3, horizon = 2.5, step = 20)')
case("ls_tax", "planning_lumpsum_vs_dca(d5, st1, months = 6, horizon = 3, step = 12, sim_args = list(tax = tax_profile()))",
     "result = SE.planning_lumpsum_vs_dca(d5, st1, months=6, horizon=3, step=12, sim_args={'tax': tax_profile()})",
     'result = SE.planning_lumpsum_vs_dca(d5, st1; months = 6, horizon = 3, step = 12, sim_args = RList("tax" => SL.tax_profile()))')
case("ls_err_sv", "planning_lumpsum_vs_dca(d5, st1, horizon = 2, step = 6, sim_args = list(start_value = 5000))",
     "result = SE.planning_lumpsum_vs_dca(d5, st1, horizon=2, step=6, sim_args={'start_value': 5000})",
     'result = SE.planning_lumpsum_vs_dca(d5, st1; horizon = 2, step = 6, sim_args = RList("start_value" => 5000))')
case("ls_err_dca", "planning_lumpsum_vs_dca(d5, st1, horizon = 2, step = 6, sim_args = list(dca_skip = FALSE, dca_mode = TRUE))",
     "result = SE.planning_lumpsum_vs_dca(d5, st1, horizon=2, step=6, sim_args={'dca_skip': False, 'dca_mode': True})",
     'result = SE.planning_lumpsum_vs_dca(d5, st1; horizon = 2, step = 6, sim_args = RList("dca_skip" => false, "dca_mode" => true))')
case("ls_err_dca_block", "planning_lumpsum_vs_dca(d5, st1, horizon = 2, step = 6, sim_args = list(dca = dca_plan(100, 1)))",
     "result = SE.planning_lumpsum_vs_dca(d5, st1, horizon=2, step=6, sim_args={'dca': dca_plan(100, 1)})",
     'result = SE.planning_lumpsum_vs_dca(d5, st1; horizon = 2, step = 6, sim_args = RList("dca" => SL.dca_plan(100, 1)))')
case("ls_err_flat", "planning_lumpsum_vs_dca(d5, st1, horizon = 2, step = 6, sim_args = list(tax_mode = 'person'))",
     "result = SE.planning_lumpsum_vs_dca(d5, st1, horizon=2, step=6, sim_args={'tax_mode': 'person'})",
     'result = SE.planning_lumpsum_vs_dca(d5, st1; horizon = 2, step = 6, sim_args = RList("tax_mode" => "person"))')
case("ls_err_short", "planning_lumpsum_vs_dca(d5, st1, horizon = 10)", "result = SE.planning_lumpsum_vs_dca(d5, st1, horizon=10)",
     'result = SE.planning_lumpsum_vs_dca(d5, st1; horizon = 10)')
case("ls_unsorted", "planning_lumpsum_vs_dca(d5[rev(seq_len(nrow(d5))), ], st1, months = 6, horizon = 4, step = 3)",
     "result = SE.planning_lumpsum_vs_dca(d5.iloc[::-1].reset_index(drop=True), st1, months=6, horizon=4, step=3)",
     'result = SE.planning_lumpsum_vs_dca(rows(d5, nrow(d5):-1:1), st1; months = 6, horizon = 4, step = 3)')

# ── series_leverage ────────────────────────────────────────────────────────
case("lev_basic", "list(series_leverage(d, 'A', leverage = 2, rate = 2, expense = 0.6, spread = 0.3), series_leverage(d, 'A', leverage = -1, rate = 'zins', expense = 0.6),
  series_leverage(d, 'A', leverage = 1), series_leverage(d, 'B', 3, rate = rdf, start = 1), series_leverage(dn, 'A', 0.5, rate = d$zins))",
  "result = [SE.series_leverage(d, 'A', leverage=2, rate=2, expense=0.6, spread=0.3), SE.series_leverage(d, 'A', leverage=-1, rate='zins', expense=0.6),
  SE.series_leverage(d, 'A', leverage=1), SE.series_leverage(d, 'B', leverage=3, rate=rdf, start=1), SE.series_leverage(dn, 'A', leverage=0.5, rate=d['zins'].to_numpy())]",
     'result = [SE.series_leverage(d, "A"; leverage = 2, rate = 2, expense = 0.6, spread = 0.3), SE.series_leverage(d, "A"; leverage = -1, rate = "zins", expense = 0.6), SE.series_leverage(d, "A"; leverage = 1), SE.series_leverage(d, "B"; leverage = 3, rate = rdf, start = 1), SE.series_leverage(dn, "A"; leverage = 0.5, rate = d["zins"])]')
case("lev_ko", "series_leverage(d, 'A', leverage = 80)", "result = SE.series_leverage(d, 'A', leverage=80)",
     'result = SE.series_leverage(d, "A"; leverage = 80)')
case("lev_gap", "series_leverage(d[c(1:10, 15:30), ], 'A', leverage = 2, rate = 5, expense = 1)",
     "result = SE.series_leverage(d.iloc[list(range(10)) + list(range(14, 30))].reset_index(drop=True), 'A', leverage=2, rate=5, expense=1)",
     'result = SE.series_leverage(rows(d, vcat(1:10, 15:30)), "A"; leverage = 2, rate = 5, expense = 1)')

# ── sensitivity_leverage ────────────────────────────────────────────────────
case("lvs_basic", "sensitivity_leverage(d, 'A', leverages = c(1, 2, 3), rate = 2, expense = 0.5)",
     "result = SE.sensitivity_leverage(d, 'A', leverages=[1, 2, 3], rate=2, expense=0.5)",
     'result = SE.sensitivity_leverage(d, "A"; leverages = [1, 2, 3], rate = 2, expense = 0.5)')
case("lvs_opt", "x <- sensitivity_leverage(d, 'A', leverages = c(1, 1.5, 2), rate = 2, spread = 0.4); list(attr(x, 'optimal'), attr(x, 'kind'))",
     "x = SE.sensitivity_leverage(d, 'A', leverages=[1, 1.5, 2], rate=2, spread=0.4); result = [x.attrs['optimal'], x.attrs['kind']]",
     'x = SE.sensitivity_leverage(d, "A"; leverages = [1, 1.5, 2], rate = 2, spread = 0.4); result = [attrs(x)["optimal"], attrs(x)["kind"]]')
case("lvs_default", "sensitivity_leverage(d[1:400, ], 'B')", "result = SE.sensitivity_leverage(d.iloc[:400], 'B')",
     'result = SE.sensitivity_leverage(rows(d, 1:400), "B")')
case("lvs_metric", "x <- sensitivity_leverage(d, 'A', leverages = c(-1, 1, 20), strategy = create_strategy(LEV = asset_config('etf', 'bnh')), metrics = function(r) c(cagr = r$cagr, max_drawdown = r$statistics$max_drawdown)); list(x, attr(x, 'optimal'))",
     "x = SE.sensitivity_leverage(d, 'A', leverages=[-1, 1, 20], strategy=create_strategy(LEV=asset_config(asset_class='etf', trading='bnh')), metrics=lambda r: pd.Series({'cagr': r.cagr, 'max_drawdown': r.statistics['max_drawdown']})); result = [x, x.attrs['optimal']]",
     'x = SE.sensitivity_leverage(d, "A"; leverages = [-1, 1, 20], strategy = create_strategy("LEV" => asset_config("etf", "bnh")), metrics = r -> named("cagr" => r.cagr, "max_drawdown" => r.statistics.max_drawdown)); result = [x, attrs(x)["optimal"]]')
case("lvs_dca", "sensitivity_leverage(d, 'A', leverages = c(1, 2), sim_args = list(dca = dca_plan(50, 1)))",
     "result = SE.sensitivity_leverage(d, 'A', leverages=[1, 2], sim_args={'dca': dca_plan(50, 1)})",
     'result = SE.sensitivity_leverage(d, "A"; leverages = [1, 2], sim_args = RList("dca" => SL.dca_plan(50, 1)))')
case("lvs_none", "x <- sensitivity_leverage(d, 'A', leverages = c(1, 2), strategy = create_strategy(X = asset_config('etf', 'bnh'))); list(x, attr(x, 'optimal'))",
     "x = SE.sensitivity_leverage(d, 'A', leverages=[1, 2], strategy=create_strategy(X=asset_config(asset_class='etf', trading='bnh'))); result = [x, x.attrs['optimal']]",
     'x = SE.sensitivity_leverage(d, "A"; leverages = [1, 2], strategy = create_strategy("X" => asset_config("etf", "bnh"))); result = [x, attrs(x)["optimal"]]')
case("lvs_nocagr", "x <- sensitivity_leverage(d, 'A', leverages = c(1, 2), metrics = function(r) c(max_drawdown = r$statistics$max_drawdown)); list(x, attr(x, 'optimal'))",
     "x = SE.sensitivity_leverage(d, 'A', leverages=[1, 2], metrics=lambda r: pd.Series({'max_drawdown': r.statistics['max_drawdown']})); result = [x, x.attrs['optimal']]",
     'x = SE.sensitivity_leverage(d, "A"; leverages = [1, 2], metrics = r -> named("max_drawdown" => r.statistics.max_drawdown)); result = [x, attrs(x)["optimal"]]')
# ── cores > 1 (Etappe 5): jede Einheit mit dem Zufallszustand des Aufrufers ─
case("sg_cores2_rng", "set.seed(7); g <- sensitivity_grid(d, st, list(rebalance.unit = c('month', 'quarter', 'year')), sim_args = list(rebalance = rebalance_plan(span = 1)), metrics = function(r) c(u = runif(1), cagr = r$cagr), cores = 2); list(g, runif(1))",
     "from simlev._r import rng as RNG\nRNG.set_seed(7); g = SE.sensitivity_grid(d, st, {'rebalance.unit': ['month', 'quarter', 'year']}, sim_args={'rebalance': rebalance_plan(span=1)}, metrics=lambda r: pd.Series({'u': RNG.runif(1)[0], 'cagr': r.cagr}), cores=2); result = [g, RNG.runif(1)]",
     'SL.RRng.set_seed(7); g = SE.sensitivity_grid(d, st, RList("rebalance.unit" => ["month", "quarter", "year"]); sim_args = RList("rebalance" => SL.rebalance_plan(; span = 1)), metrics = r -> named("u" => SL.RRng.runif(1)[1], "cagr" => r.cagr), cores = 2); result = [g, SL.RRng.runif(1)]')
case("sg_cores1_rng", "set.seed(7); g <- sensitivity_grid(d, st, list(rebalance.unit = c('month', 'quarter', 'year')), sim_args = list(rebalance = rebalance_plan(span = 1)), metrics = function(r) c(u = runif(1), cagr = r$cagr), cores = 1); list(g, runif(1))",
     "from simlev._r import rng as RNG\nRNG.set_seed(7); g = SE.sensitivity_grid(d, st, {'rebalance.unit': ['month', 'quarter', 'year']}, sim_args={'rebalance': rebalance_plan(span=1)}, metrics=lambda r: pd.Series({'u': RNG.runif(1)[0], 'cagr': r.cagr}), cores=1); result = [g, RNG.runif(1)]",
     'SL.RRng.set_seed(7); g = SE.sensitivity_grid(d, st, RList("rebalance.unit" => ["month", "quarter", "year"]); sim_args = RList("rebalance" => SL.rebalance_plan(; span = 1)), metrics = r -> named("u" => SL.RRng.runif(1)[1], "cagr" => r.cagr), cores = 1); result = [g, SL.RRng.runif(1)]')
case("sg_cores3_keep", "g <- sensitivity_grid(d, st, list(rebalance.span = c(1, 3, 6, 12)), sim_args = list(rebalance = rebalance_plan()), keep_results = TRUE, cores = 3); r <- attr(g, 'results'); list(g, length(r), r[[4]]$cagr, r[[1]]$worth[100])",
     "g = SE.sensitivity_grid(d, st, {'rebalance.span': [1, 3, 6, 12]}, sim_args={'rebalance': rebalance_plan()}, keep_results=True, cores=3); r = g.attrs['results']; result = [g, len(r), r[3].cagr, r[0].worth[99]]",
     'g = SE.sensitivity_grid(d, st, RList("rebalance.span" => [1.0, 3.0, 6.0, 12.0]); sim_args = RList("rebalance" => SL.rebalance_plan()), keep_results = true, cores = 3); r = attrs(g)["results"]; result = [g, length(r), r[4].cagr, r[1].worth[100]]')
case("sg_cores2_err", "sensitivity_grid(d, st, list(rebalance.unit = c('month', 'monat', 'year')), sim_args = list(rebalance = rebalance_plan(span = 1)), cores = 2)",
     "result = SE.sensitivity_grid(d, st, {'rebalance.unit': ['month', 'monat', 'year']}, sim_args={'rebalance': rebalance_plan(span=1)}, cores=2)",
     'result = SE.sensitivity_grid(d, st, RList("rebalance.unit" => ["month", "monat", "year"]); sim_args = RList("rebalance" => SL.rebalance_plan(; span = 1)), cores = 2)')
case("rs_cores2", "sensitivity_rebalancing(d, st, frequencies = list(monthly = c('month', 1), yearly = c('year', 1)), bands = c(NA, 5), cores = 2)",
     "result = SE.sensitivity_rebalancing(d, st, frequencies={'monthly': ('month', 1), 'yearly': ('year', 1)}, bands=[None, 5], cores=2)",
     'result = SE.sensitivity_rebalancing(d, st; frequencies = ["monthly" => ("month", 1), "yearly" => ("year", 1)], bands = [NA, 5.0], cores = 2)')
case("ls_cores2", "x <- planning_lumpsum_vs_dca(d5, st1, amount = 12000, months = 12, horizon = 3, step = 6, cores = 2); list(x, attr(x, 'summary'))",
     "x = SE.planning_lumpsum_vs_dca(d5, st1, amount=12000, months=12, horizon=3, step=6, cores=2); result = [x, x.attrs['summary']]",
     'x = SE.planning_lumpsum_vs_dca(d5, st1; amount = 12000, months = 12, horizon = 3, step = 6, cores = 2); result = [x, attrs(x)["summary"]]')
case("lvs_cores2", "x <- sensitivity_leverage(d, 'A', leverages = c(1, 1.5, 2, 3), rate = 2, expense = 0.5, cores = 2); list(x, attr(x, 'optimal'))",
     "x = SE.sensitivity_leverage(d, 'A', leverages=[1, 1.5, 2, 3], rate=2, expense=0.5, cores=2); result = [x, x.attrs['optimal']]",
     'x = SE.sensitivity_leverage(d, "A"; leverages = [1, 1.5, 2, 3], rate = 2, expense = 0.5, cores = 2); result = [x, attrs(x)["optimal"]]')

ref_done()
