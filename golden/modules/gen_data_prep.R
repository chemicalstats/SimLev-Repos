# Referenzfälle für simlev.data_prep und simlev.bonds (r/R/data_prep.R, r/R/bonds.R).
source("golden/modules/ref_tools.R"); ref_init("data_prep")
P <- "from simlev import data_prep as DP, bonds as BO\n"
# ── Julia-Code je Fall (Feld jl; Eingaben als Variablen, siehe julia/test/reftree.jl) ──
J <- "const DP = SL.DataPrep; const BO = SL.Bonds\n"
ALJ <- function(call) sprintf('x = %s\nresult = RList("df" => x, "filled" => attrs(x)["filled"])', call)
BIJ <- function(call) sprintf('b = %s\nresult = RList("b" => b.values, "duration" => attrs(b)["duration"])', call)
JL <- list(
  todate_iso = 'result = DP._to_date(["2020-01-05", "1650-03-01", "1799/12/31", missing, "", " 2021-3-7 ", "2020-01-01xyz"])',
  todate_err1 = 'result = DP._to_date("31-12-2024")',
  todate_err2 = 'result = DP._to_date("24-12-31", "x")',
  todate_err3 = 'result = DP._to_date(["2020-01-01", "2021-02-30", "2021-13-01"], "feld")',
  todate_lax = 'result = DP._to_date(["31-12-2024", "2021-02-30", "2020-02-29", "99999-01-01"]; strict = false)',
  todate_num = 'result = DP._to_date([18000.5, 1], "d")',
  todate_int = 'result = DP._to_date(5)',
  todate_date = 'result = DP._to_date(d)',
  todate_factor = 'result = DP._to_date(["2020-01-02", "2020-01-01", "2020-01-02"])',
  todate_posix = 'result = DP._to_date([DateTime(2020, 1, 1, 0, 30), DateTime(2020, 6, 30, 23, 59)])',
  addm1 = 'result = DP._add_months(Date.(["2024-01-31", "2023-01-31", "2024-02-29", "2024-03-31", "2024-01-15", "2024-12-31"]), [1, 1, 12, -1, 1, 2])',
  addm2 = 'result = DP._add_months(d, -25)',
  addm3 = 'result = DP._add_months("2020-08-31", 0:13)',
  numtext1 = 'result = DP._num_text_cols(x, ["date"])',
  numtext2 = 'result = DP._num_text_cols(x)',
  numtext3 = 'result = DP._num_text_stop(x, ["kurs", "date"], "q")',
  al_basic = ALJ('DP.align_series(us = a, eu = b)'),
  al_maxgap = ALJ('DP.align_series(us = a, eu = b, max_gap = 10)'),
  al_maxgap2 = ALJ('DP.align_series(us = a, eu = b, max_gap = 2.5, fill = "linear")'),
  al_inter = ALJ('DP.align_series(us = a, eu = b, calendar = "intersect", range = "all")'),
  al_union = ALJ('DP.align_series(us = a, eu = b, calendar = "union", range = "all")'),
  al_union_c = ALJ('DP.align_series(us = a, eu = b, calendar = "uni")'),
  al_all_lin = ALJ('DP.align_series(us = a, eu = b, range = "all", fill = "linear")'),
  al_none = ALJ('DP.align_series(us = a, eu = b, range = "all", fill = "none")'),
  al_startend = ALJ('DP.align_series(us = a, eu = b, range = "all", start = "2024-01-03", end_ = Date(2024, 1, 20))'),
  al_err_name = 'result = DP.align_series(a, b)',
  al_err_none = 'result = DP.align_series()',
  al_err_overlap = 'result = DP.align_series(us = a, eu = b, start = "2025-01-01")',
  al_err_dup = 'result = DP.align_series(us = RFrame("date" => a.date, "A" => collect(1:5), "B" => collect(2:6)), eu = RFrame("date" => a.date, "A" => collect(1:5), "C" => fill(1.0, 5)))',
  al_err_arg = 'result = DP.align_series(us = a, fill = "spline")',
  al_named = ALJ('DP.align_series(x = named("2024-01-03" => 1.0, "2024-01-01" => 2.0, "2024-01-07" => 3.0), y = b)'),
  al_multi = ALJ('DP.align_series(us = RFrame("date" => b.date, "A" => b.close, "B" => reverse(b.close), "txt" => fill("x", nrow(b))), eu = a)'),
  al_rownum = ALJ('DP.align_series(etf = roh)'),
  al_rownum1 = ALJ('DP.align_series(etf = RFrame("X" => roh.X, "Kurs" => roh.Kurs), b = RFrame("Datum" => roh.Datum, "Kurs" => roh.Kurs))'),
  al_numdate = 'result = DP.align_series(etf = RFrame("X" => collect(1:30), "Kurs" => roh.Kurs))',
  al_firstcol = ALJ('DP.align_series(etf = RFrame("tag" => string.(tage), "Kurs" => roh.Kurs))'),
  al_baddate = 'result = DP.align_series(a = x20)',
  al_dotdate = 'x20.date = Dates.format.(tage, "dd.mm.yyyy")\nresult = DP.align_series(a = x20)',
  al_text = 'result = DP.align_series(a = RFrame("date" => dft.date, "Kurs" => dft.kurs, "Volumen" => collect(1:60)))',
  al_factor = 'result = DP.align_series(a = RFrame("date" => dft.date, "Kurs" => dft.kurs))',
  al_nonum = 'result = DP.align_series(a = RFrame("date" => dft.date, "n" => dft.name))',
  al_notdf = 'result = DP.align_series(a = collect(1:3))',
  al_posix = ALJ('DP.align_series(a = RFrame("date" => DateTime.(tage), "value" => roh.Kurs))'),
  al_dups = ALJ('DP.align_series(v = xd, w = b)'),
  al_trading = ALJ('DP.align_series(us = us)'),
  al_trading_end = ALJ('DP.align_series(A = us, end_ = "2021-02-13")'),
  al_int = ALJ('DP.align_series(a = RFrame("date" => a.date, "v" => [1, missing, 3, 4, 5]), b = b)'),
  al_nainside = ALJ('DP.align_series(a = RFrame("date" => a.date, "v" => [1, NA, 3, NA, 5]), b = b, fill = "linear", range = "all")'),
  cs_doc = 'result = DP.check_series(d)',
  cs_multi = 'result = DP.check_series(d; jump = 15, stale = 5, revert = 0.5)',
  cs_cols = 'result = DP.check_series(d; columns = "B")',
  cs_neg = 'result = DP.check_series(d)',
  cs_neg2 = 'result = DP.check_series(d)',
  cs_nadate = 'result = DP.check_series(x)',
  cs_dates = 'result = DP.check_series(d)',
  cs_dates_c = 'result = DP.check_series(d; columns = ["A", "C"])',
  cs_many = 'result = DP.check_series(d)',
  cs_print_n = 'result = split(DP.format_SimLevDataCheck(DP.check_series(d); max_issues = 3), "\\n")',
  cs_clean = 'result = DP.check_series(d)',
  cs_split3 = 'result = DP.check_series(RFrame("date" => d6.date, "A" => [90, 91, 92, 30.5, 31, 31.2, 31.3, 31.1, 93.3, 93]))',
  cs_firstna = 'result = DP.check_series(d)',
  cs_onlyna = 'result = DP.check_series(d; columns = ["C", "C"])',
  cs_nocols = 'result = DP.check_series(d; columns = String[])',
  cs_err = 'result = DP.check_series(RFrame("x" => [1.0]))',
  am_yoy = 'result = DP.align_macro(d, cpi; name = "infl", lag = 45, transform = "yoy")',
  am_month = 'result = DP.align_macro(d.date, cpi; lag = 1, lag_unit = "month")',
  am_diff = 'result = DP.align_macro(d.date, cpi; transform = "diff")',
  am_mom = 'result = DP.align_macro(d, cpi; transform = "mom", lag = 10.5)',
  am_yoyd = 'result = DP.align_macro(d, cpi; name = "x", transform = "yoy_diff", lag = 2, lag_unit = "month")',
  am_gap = 'c29 = rows(cpi, setdiff(1:nrow(cpi), 30))\nresult = [DP.align_macro(dts, c29; transform = "yoy"), DP.align_macro(dts, cpi; transform = "yoy"), DP.align_macro(Date(2020, 7, 15), c29; transform = "mom")]',
  am_monthend = 'result = DP.align_macro(d, m; name = "cpi", lag = 1, lag_unit = "month")',
  am_q = 'result = DP.align_macro(d, q; name = "g", transform = "yoy", lag = 30)',
  am_qmom = 'result = DP.align_macro(d.date, q; transform = "mom")',
  am_y = 'result = DP.align_macro(d.date, m; transform = "yoy_diff")',
  am_w = 'result = DP.align_macro(d.date, m; transform = "yoy")',
  am_wp = 'result = DP.align_macro(d.date, m; transform = "yoy", periods = 12)',
  am_wp5 = 'result = DP.align_macro(d.date, m; transform = "yoy", periods = 5)',
  am_daily = 'result = DP.align_macro(d.date, m; transform = "yoy", lag = 1)',
  am_named = 'result = DP.align_macro(d.date, named("2020-01-15" => 1.0, "2020-03-01" => 2.0, "2020-02-01" => 3.0))',
  am_err = 'result = DP.align_macro(d, cpi; transform = "abc")',
  cc_col = 'result = DP.convert_currency(d, "A", "fx")',
  cc_mult = 'result = DP.convert_currency(d, "A", 2; method = "multiply", suffix = "_x")',
  cc_df = 'result = DP.convert_currency(d, ["A", "fx"], RFrame("date" => Date.(["2024-01-03", "2024-01-02"]), "value" => [1.05, 1.1]); suffix = "_eur")',
  cc_named = 'result = DP.convert_currency(d, "A", named("2024-01-02" => 1.2, "2023-12-01" => 1.0))',
  cc_vec = 'result = DP.convert_currency(d, "A", [1.0, 2, 3, 4])',
  cc_errcol = 'result = DP.convert_currency(d, ["USD", "A", "x"], "fx")',
  cc_errfx = 'result = DP.convert_currency(d, "A", 0)',
  cc_errfx2 = 'result = DP.convert_currency(d, "A", [1, -2.5, NA, 1])',
  cc_errfx3 = 'result = DP.convert_currency(d, "A", "nope")',
  cc_errfx4 = 'result = DP.convert_currency(d, "A", collect(1:3))',
  cc_errfx5 = 'result = DP.convert_currency(d, "A", RFrame("date" => d.date))',
  tri_div = 'result = DP.total_return_index([100.0, 100, 98, 99]; dividends = [0.0, 0, 2, 0], withholding = 15)',
  tri_yield = 'result = DP.total_return_index(fill(100.0, 366); yield = 2, dates = Date(2021, 1, 1) .+ Day.(0:365))',
  tri_full = 'result = DP.total_return_index(p; dividends = dv, yield = vcat(1.0, 1.0 .+ collect(1:198) .* (2 / 199), 3.0), withholding = 26.375, dates = dts, start = 1000)',
  tri_ychr = 'result = DP.total_return_index(p; yield = [1.0, 2.0], dates = string.(dts))',
  tri_err = 'result = DP.total_return_index(fill(100.0, 6); yield = 2, dates = dts[[1, 2, 3, 6, 5, 4]])',
  tri_err2 = 'result = DP.total_return_index(fill(100.0, 6); dates = dts[1:5])',
  tri_one = 'result = DP.total_return_index(5.0)',
  df_col = 'result = DP.deflate(RFrame("date" => d.date, "A" => d.A, "cpi" => [100.0, 110, 121, 130]), "A", "cpi")',
  df_macro = 'd1 = DP.align_macro(d, cpi; name = "cpi")\nresult = DP.deflate(d1, ["depot", "d2"], "cpi"; suffix = "_r")',
  df_dfcpi = 'result = DP.deflate(d, "depot", cpi)',
  df_base = 'result = DP.deflate(d, "d2", cpi; base_date = "2020-03-17")',
  df_named = 'result = DP.deflate(d, "d2", named("2020-01-01" => 100.0, "2020-02-15" => 101.0, "2020-04-01" => 103.0))',
  df_vec = 'result = DP.deflate(d, "d2", 100 .+ collect(1:200) ./ 10; base_date = Date(2020, 12, 31))',
  df_errbase = 'd1 = DP.align_macro(d, cpi; name = "cpi")\nresult = DP.deflate(d1, "depot", "cpi"; base_date = "2019-12-01")',
  df_errnone = 'result = DP.deflate(d, "depot", RFrame("date" => [Date(2030, 1, 1)], "v" => [1.0]))',
  df_errcol = 'result = DP.deflate(d, "depot", "cpi")',
  cpilevel = 'result = DP._cpi_level(cpi, d, d.date, "cpi")',
  sp_basic = 'result = DP.splice_series(fund = f1, proxy = f2)',
  sp_gap = 'result = DP.splice_series(fonds = fonds, proxy = proxy)',
  sp_trading = 'result = DP.splice_series(f = f2b, p = p2)',
  sp_we = 'result = DP.splice_series(etf = etf, idx = idx)',
  sp_we2 = 'result = DP.splice_series(etf = e2, idx = idx, other = rows(etf, etf.date .> Date(2020, 3, 4)))',
  sp_vec = 'result = DP.splice_series(a = v1, b = v2, c = v3, dates = Date(2024, 1, 1) .+ Day.(0:7))',
  sp_vec2 = 'result = DP.splice_series(a = v1, b = v2, dates = string.(Date(2024, 1, 1) .+ Day.(0:7)))',
  sp_err1 = 'result = DP.splice_series(a = f1)',
  sp_err2 = 'result = DP.splice_series(a = collect(1:3), b = collect(1:3))',
  sp_err3 = 'result = DP.splice_series(a = [NA, NA], b = collect(1:2), dates = Date(2024, 1, 1) .+ Day.(0:1))',
  sp_err4 = 'result = DP.splice_series(f1, f2)',
  sw_doc = 'result = DP.strategy_from_weights(named("world" => 0.6, "bonds" => 0.4); asset_spread = named("world" => 0.1, "bonds" => 0.05))',
  sw_class = 'result = DP.strategy_from_weights(named("aktien" => 0.7, "gold" => 0.3); asset_class = named("aktien" => "etf", "gold" => "etc"), asset_bonus = named("aktien" => 30.0, "gold" => 0.0))',
  sw_one = 'result = DP.strategy_from_weights(named("aktien" => 0.7, "gold" => 0.3); asset_bonus = named("aktien" => 30.0))',
  sw_all = 'result = DP.strategy_from_weights(named("a" => 0.5, "b" => 0.5); asset_spread = 0.2, asset_class = "etc", deliverable = true)',
  sw_namedall = 'result = DP.strategy_from_weights(named("a" => 0.5, "b" => 0.5); asset_spread = named("x" => 0.3))',
  sw_na = 'result = DP.strategy_from_weights(named("a" => 0.5, "b" => 0.5); asset_spread = NA)',
  sw_err_sum = 'result = DP.strategy_from_weights(named("a" => 0.3, "b" => 0.3))',
  sw_err_dup = 'result = DP.strategy_from_weights(named("a" => 0.5, "a" => 0.5))',
  sw_err_pos = 'result = DP.strategy_from_weights(named("a" => 1.0, "b" => 0.0))',
  sw_err_name = 'result = DP.strategy_from_weights([0.5, 0.5])',
  sw_err_cfg = 'result = DP.strategy_from_weights(named("a" => 0.5, "b" => 0.5); asset_bonus = named("a" => 130.0))',
  pt_perm = 'result = DP.portfolio_template("permanent"; map = named("stocks" => "msci_world", "long_bonds" => "bund_10y", "cash" => "geldmarkt", "gold" => "gold_eur"))',
  pt_partial = 'result = DP.portfolio_template("permanent"; map = named("stocks" => "W"), asset_spread = 0)',
  pt_list = 'result = DP.portfolio_templates()',
  pt_err1 = 'result = DP.portfolio_template("xyz")',
  pt_err2 = 'result = DP.portfolio_template("60_40"; map = named("stock" => "A", "bonds" => "B"))',
  pt_err3 = 'result = DP.portfolio_template("60_40"; map = named("stocks" => "A", "bonds" => "A"))',
  pt_err4 = 'result = DP.portfolio_template("60_40"; map = ["A", "B"])',
  bond_small = BIJ('BO.bond_index_from_yields(d, "y"; maturity = 10, coupon_frequency = 1)'),
  bond_doc = BIJ('BO.bond_index_from_yields(d, "y10"; maturity = 10, coupon_frequency = 1)'),
  bond_dur = BIJ('BO.bond_index_from_yields(d, "y10"; method = "duration", maturity = 7, coupon_frequency = 2, start = 1)'),
  bond_df = BIJ('BO.bond_index_from_yields(d, RFrame("date" => Date.(["2020-01-01", "2020-06-01"]), "v" => [1.0, 4.0]); maturity = 30)'),
  bond_td = BIJ('BO.bond_index_from_yields(d, 2.5; method = "dur")'),
  bond_zero = BIJ('BO.bond_index_from_yields(z, "y")'),
  mm_col = 'result = BO.money_market_index(d, "y")',
  mm_spread = 'result = BO.money_market_index(d, 3; spread = 1, basis = 365, start = 1)',
  mm_df = 'result = BO.money_market_index(d, RFrame("date" => Date.(["2020-12-01", "2021-06-01"]), "value" => [1.0, 2.0]))',
  mm_named = 'result = BO.money_market_index(d, named("2020-01-01" => 0.0, "2021-01-01" => 2.0))',
  mm_td = 'result = BO.money_market_index(d, "r")',
  mm_err = 'result = BO.money_market_index(d, "zz")',
  ch_basic = 'result = BO.currency_hedged_index(d, "x", 3, 1)',
  ch_doc = 'result = BO.currency_hedged_index(d, "sp500", 3, "rf"; cost = 0.1)',
  ch_vec = 'result = BO.currency_hedged_index(d, d.sp500 .* 2, named("2020-01-01" => 1.0, "2020-08-01" => 2.0), RFrame("date" => [Date(2020, 1, 1)], "r" => [0.5]); basis = 365, start = 10)'
)
for (tn in names(SimLev:::.portfolio_templates)) JL[[paste0("pt_", tn)]] <- sprintf('result = DP.portfolio_template("%s")', tn)
rc <- function(id, r, py, inputs = list(), ...) {
  if (is.null(JL[[id]])) stop("kein Julia-Code (jl) für Fall ", id)
  ref_case(id, r, paste0(P, py), inputs, jl = paste0(J, JL[[id]]), ...)
}
ss <- function(...) suppressMessages(...)
td <- function(from, n_cal) { cal <- seq.Date(as.Date(from), by = "day", length.out = n_cal); cal[!format(cal, "%u") %in% c("6", "7")] }

# ── .to_date ────────────────────────────────────────────────────────────────
rc("todate_iso", "SimLev:::.to_date(c('2020-01-05', '1650-03-01', '1799/12/31', NA, '', ' 2021-3-7 ', '2020-01-01xyz'))",
   "result = DP._to_date(['2020-01-05', '1650-03-01', '1799/12/31', None, '', ' 2021-3-7 ', '2020-01-01xyz'])")
rc("todate_err1", "SimLev:::.to_date('31-12-2024')", "result = DP._to_date('31-12-2024')")
rc("todate_err2", "SimLev:::.to_date('24-12-31', 'x')", "result = DP._to_date('24-12-31', 'x')")
rc("todate_err3", "SimLev:::.to_date(c('2020-01-01', '2021-02-30', '2021-13-01'), 'feld')",
   "result = DP._to_date(['2020-01-01', '2021-02-30', '2021-13-01'], 'feld')")
rc("todate_lax", "SimLev:::.to_date(c('31-12-2024', '2021-02-30', '2020-02-29', '99999-01-01'), strict = FALSE)",
   "result = DP._to_date(['31-12-2024', '2021-02-30', '2020-02-29', '99999-01-01'], strict=False)")
rc("todate_num", "SimLev:::.to_date(c(18000.5, 1), 'd')", "result = DP._to_date(np.array([18000.5, 1]), 'd')")
rc("todate_int", "SimLev:::.to_date(5L)", "result = DP._to_date(5)")
rc("todate_date", "SimLev:::.to_date(d)", "result = DP._to_date(d)", list(d = as.Date(c("2020-01-01", NA, "1900-02-28"))))
rc("todate_factor", "SimLev:::.to_date(factor(c('2020-01-02', '2020-01-01', '2020-01-02')))",
   "result = DP._to_date(pd.Categorical(['2020-01-02', '2020-01-01', '2020-01-02']))")
rc("todate_posix", "SimLev:::.to_date(as.POSIXct(c('2020-01-01 00:30', '2020-06-30 23:59'), tz = 'Europe/Berlin'))",
   "result = DP._to_date(pd.Series(pd.to_datetime(['2020-01-01 00:30', '2020-06-30 23:59'])).dt.tz_localize('Europe/Berlin'))")

# ── .add_months ─────────────────────────────────────────────────────────────
rc("addm1", "SimLev:::.add_months(as.Date(c('2024-01-31', '2023-01-31', '2024-02-29', '2024-03-31', '2024-01-15', '2024-12-31')), c(1, 1, 12, -1, 1, 2))",
   "result = DP._add_months(np.array(['2024-01-31', '2023-01-31', '2024-02-29', '2024-03-31', '2024-01-15', '2024-12-31'], dtype='datetime64[D]'), [1, 1, 12, -1, 1, 2])")
rc("addm2", "SimLev:::.add_months(d, -25)", "result = DP._add_months(d, -25)",
   list(d = seq.Date(as.Date("2019-12-28"), by = "day", length.out = 70)))
rc("addm3", "SimLev:::.add_months('2020-08-31', 0:13)", "result = DP._add_months('2020-08-31', np.arange(14))")

# ── .num_text_cols / .num_text_stop ────────────────────────────────────────
set.seed(1); n <- 60
v <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
txt <- sub(".", ",", format(round(v, 2), nsmall = 2), fixed = TRUE)
dft <- data.frame(date = format(seq.Date(as.Date("2020-01-01"), by = "day", length.out = n)), kurs = txt,
                  name = rep(c("a", "b"), n / 2), datum2 = rep("01.02.2020", n), zahl = v, stringsAsFactors = FALSE)
rc("numtext1", "SimLev:::.num_text_cols(x, 'date')", "result = DP._num_text_cols(x, ['date'])", list(x = dft))
rc("numtext2", "SimLev:::.num_text_cols(x)", "result = DP._num_text_cols(x)", list(x = dft))
rc("numtext3", "SimLev:::.num_text_stop(x, c('kurs', 'date'), 'q')", "result = DP._num_text_stop(x, ['kurs', 'date'], 'q')", list(x = dft))

# ── align_series ───────────────────────────────────────────────────────────
a <- data.frame(date = as.Date("2024-01-01") + c(0, 1, 2, 5, 30), value = c(100, 101, 102, 103, 110))
b <- data.frame(date = as.Date("2024-01-02") + 0:40, close = 50 + 0:40)
AL <- function(call) sprintf("x <- %s; list(df = x, filled = attr(x, 'filled'))", call)
ALP <- function(call) sprintf("x = %s\nresult = dict(df=x, filled=x.attrs['filled'])", call)
rc("al_basic", AL("align_series(us = a, eu = b)"), ALP("DP.align_series(us=a, eu=b)"), list(a = a, b = b))
rc("al_maxgap", AL("align_series(us = a, eu = b, max_gap = 10)"), ALP("DP.align_series(us=a, eu=b, max_gap=10)"), list(a = a, b = b))
rc("al_maxgap2", AL("align_series(us = a, eu = b, max_gap = 2.5, fill = 'linear')"), ALP("DP.align_series(us=a, eu=b, max_gap=2.5, fill='linear')"), list(a = a, b = b))
rc("al_inter", AL("align_series(us = a, eu = b, calendar = 'intersect', range = 'all')"),
   ALP("DP.align_series(us=a, eu=b, calendar='intersect', range='all')"), list(a = a, b = b))
rc("al_union", AL("align_series(us = a, eu = b, calendar = 'union', range = 'all')"),
   ALP("DP.align_series(us=a, eu=b, calendar='union', range='all')"), list(a = a, b = b))
rc("al_union_c", AL("align_series(us = a, eu = b, calendar = 'uni')"), ALP("DP.align_series(us=a, eu=b, calendar='uni')"), list(a = a, b = b))
rc("al_all_lin", AL("align_series(us = a, eu = b, range = 'all', fill = 'linear')"),
   ALP("DP.align_series(us=a, eu=b, range='all', fill='linear')"), list(a = a, b = b))
rc("al_none", AL("align_series(us = a, eu = b, range = 'all', fill = 'none')"),
   ALP("DP.align_series(us=a, eu=b, range='all', fill='none')"), list(a = a, b = b))
rc("al_startend", AL("align_series(us = a, eu = b, range = 'all', start = '2024-01-03', end = as.Date('2024-01-20'))"),
   ALP("DP.align_series(us=a, eu=b, range='all', start='2024-01-03', end=np.datetime64('2024-01-20'))"), list(a = a, b = b))
rc("al_err_name", "align_series(a, b)", "result = DP.align_series(a, b)", list(a = a, b = b))
rc("al_err_none", "align_series()", "result = DP.align_series()")
rc("al_err_overlap", "align_series(us = a, eu = b, start = '2025-01-01')", "result = DP.align_series(us=a, eu=b, start='2025-01-01')", list(a = a, b = b))
rc("al_err_dup", "align_series(us = data.frame(date = a$date, A = 1:5, B = 2:6), eu = data.frame(date = a$date, A = 1:5, C = 1))",
   "result = DP.align_series(us=pd.DataFrame(dict(date=a['date'], A=np.arange(1, 6), B=np.arange(2, 7))), eu=pd.DataFrame(dict(date=a['date'], A=np.arange(1, 6), C=1.0)))",
   list(a = a))
rc("al_err_arg", "align_series(us = a, fill = 'spline')", "result = DP.align_series(us=a, fill='spline')", list(a = a))
rc("al_named", AL("align_series(x = c('2024-01-03' = 1, '2024-01-01' = 2, '2024-01-07' = 3), y = b)"),
   ALP("DP.align_series(x=pd.Series([1., 2, 3], index=['2024-01-03', '2024-01-01', '2024-01-07']), y=b)"), list(b = b))
rc("al_multi", AL("align_series(us = data.frame(date = b$date, A = b$close, B = rev(b$close), txt = 'x'), eu = a)"),
   ALP("DP.align_series(us=pd.DataFrame(dict(date=b['date'], A=b['close'], B=b['close'].to_numpy()[::-1], txt='x')), eu=a)"), list(a = a, b = b))
set.seed(1); tage <- seq.Date(as.Date("2022-01-03"), by = "day", length.out = 30)
roh <- data.frame(X = 1:30, Datum = tage, Kurs = 100 * cumprod(1 + rnorm(30, 3e-4, 0.01)))
rc("al_rownum", AL("align_series(etf = roh)"), ALP("DP.align_series(etf=roh)"), list(roh = roh))
rc("al_rownum1", AL("align_series(etf = roh[, c('X', 'Kurs')], b = roh[, c('Datum', 'Kurs')])"),
   ALP("DP.align_series(etf=roh[['X', 'Kurs']], b=roh[['Datum', 'Kurs']])"), list(roh = roh))
rc("al_numdate", "align_series(etf = data.frame(X = 1:30, Kurs = roh$Kurs))",
   "result = DP.align_series(etf=pd.DataFrame(dict(X=np.arange(1, 31), Kurs=roh['Kurs'])))", list(roh = roh))
rc("al_firstcol", AL("align_series(etf = data.frame(tag = format(tage), Kurs = roh$Kurs))"),
   ALP("DP.align_series(etf=pd.DataFrame(dict(tag=[str(t) for t in tage], Kurs=roh['Kurs'])))"), list(roh = roh, tage = tage))
x20 <- data.frame(date = format(tage, "%d-%m-%Y"), value = roh$Kurs)
rc("al_baddate", "align_series(a = x20)", "result = DP.align_series(a=x20)", list(x20 = x20))
rc("al_dotdate", "align_series(a = transform(x20, date = format(tage, '%d.%m.%Y')))",
   "x20['date'] = [pd.Timestamp(t).strftime('%d.%m.%Y') for t in tage]\nresult = DP.align_series(a=x20)", list(x20 = x20, tage = tage))
rc("al_text", "align_series(a = data.frame(date = dft$date, Kurs = dft$kurs, Volumen = 1:60))",
   "result = DP.align_series(a=pd.DataFrame(dict(date=dft['date'], Kurs=dft['kurs'], Volumen=np.arange(1, 61))))", list(dft = dft))
rc("al_factor", "align_series(a = data.frame(date = dft$date, Kurs = factor(dft$kurs)))",
   "result = DP.align_series(a=pd.DataFrame(dict(date=dft['date'], Kurs=pd.Categorical(dft['kurs']))))", list(dft = dft))
rc("al_nonum", "align_series(a = data.frame(date = dft$date, n = dft$name))",
   "result = DP.align_series(a=pd.DataFrame(dict(date=dft['date'], n=dft['name'])))", list(dft = dft))
rc("al_notdf", "align_series(a = 1:3)", "result = DP.align_series(a=np.arange(1, 4))")
rc("al_posix", AL("align_series(a = data.frame(date = as.POSIXct(format(tage), tz = 'Europe/Berlin'), value = roh$Kurs))"),
   ALP("DP.align_series(a=pd.DataFrame(dict(date=pd.Series(pd.to_datetime([str(t) for t in tage])).dt.tz_localize('Europe/Berlin'), value=roh['Kurs'])))"),
   list(roh = roh, tage = tage))
xd <- rbind(transform(roh[c(10, 3, 20), ], Kurs = Kurs * 1.05), roh)[, c("Datum", "Kurs")]
xd <- xd[c(5, 1, 3, 2, 4, 6:nrow(xd)), ]; xd$Datum[7] <- NA
rc("al_dups", AL("align_series(v = xd, w = b)"), ALP("DP.align_series(v=xd, w=b)"), list(xd = xd, b = b))
set.seed(3); tdd <- td("2021-01-04", 60)
us <- data.frame(date = tdd, aktien = 100 * cumprod(1 + rnorm(length(tdd), 0, 0.01)), geld = 100)
rc("al_trading", AL("align_series(us = us)"), ALP("DP.align_series(us=us)"), list(us = us))
rc("al_trading_end", AL("align_series(A = us, end = '2021-02-13')"), ALP("DP.align_series(A=us, end='2021-02-13')"), list(us = us))
rc("al_int", AL("align_series(a = data.frame(date = a$date, v = c(1L, NA, 3L, 4L, 5L)), b = b)"),
   ALP("DP.align_series(a=pd.DataFrame(dict(date=a['date'], v=[1, simlev._r.fmt.NA_REAL, 3, 4, 5])), b=b)"), list(a = a, b = b))
rc("al_nainside", AL("align_series(a = data.frame(date = a$date, v = c(1, NA, 3, NA, 5)), b = b, fill = 'linear', range = 'all')"),
   ALP("DP.align_series(a=pd.DataFrame(dict(date=a['date'], v=[1, simlev._r.fmt.NA_REAL, 3, simlev._r.fmt.NA_REAL, 5])), b=b, fill='linear', range='all')"), list(a = a, b = b))

# ── check_series ───────────────────────────────────────────────────────────
set.seed(1); n <- 400
d1 <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n), A = 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)))
d1$A[100] <- d1$A[100] * 1.5; d1$A[300:n] <- d1$A[300:n] / 2; d1$A[200:215] <- d1$A[200]
rc("cs_doc", "check_series(d)", "result = DP.check_series(d)", list(d = d1))
set.seed(1); n <- 600
p <- 100 * cumprod(1 + rnorm(n, 0, 0.01)); p[300:n] <- p[300:n] / 2; p[400] <- p[400] * 1.6; p[500:515] <- p[500]
d2 <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n), A = p, B = c(rep(NA, 20), 1:580 * 0.1 + 10))
d2$B[c(50, 60:62)] <- NA; d2$B[c(100, 300)] <- d2$B[c(100, 300)] * 3; d2$B[301] <- d2$B[301] * 3
rc("cs_multi", "check_series(d, jump = 15, stale = 5, revert = 0.5)", "result = DP.check_series(d, jump=15, stale=5, revert=0.5)", list(d = d2))
rc("cs_cols", "check_series(d, columns = 'B')", "result = DP.check_series(d, columns='B')", list(d = d2))
set.seed(1)
d3 <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 300))
d3$kurs <- 100 * cumprod(1 + rnorm(300, 3e-4, 0.01))
d3$zins <- c(seq(1, -0.5, length.out = 150), seq(-0.5, 2, length.out = 150))
rc("cs_neg", "check_series(d)", "result = DP.check_series(d)", list(d = d3))
d3b <- d3; d3b$zins <- NULL; d3b$kurs[50] <- -1
rc("cs_neg2", "check_series(d)", "result = DP.check_series(d)", list(d = d3b))
set.seed(1)
x28 <- data.frame(date = c(format(seq.Date(as.Date("2020-01-01"), by = "day", length.out = 50)), "", "2020/03/01", "x"), A = c(100 + cumsum(rnorm(50)), NA, 99, NA))
rc("cs_nadate", "check_series(x)", "result = DP.check_series(x)", list(x = x28))
dd4 <- data.frame(date = as.Date(c("2020-01-01", "2020-01-02", "2020-01-02", "2020-01-10", "2020-01-05", "2020-01-30", "2020-02-01")),
                  A = c(1, 1, 1, 1, 1, 1, 2), C = NA_real_)
rc("cs_dates", "check_series(d)", "result = DP.check_series(d)", list(d = dd4))
rc("cs_dates_c", "check_series(d, columns = c('A', 'C'))", "result = DP.check_series(d, columns=['A', 'C'])", list(d = dd4))
set.seed(9); n <- 300
d5 <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n), A = 100 * cumprod(1 + rnorm(n, 0, 0.03)))
d5$A[seq(10, 290, by = 9)] <- d5$A[seq(10, 290, by = 9)] * c(1.5, 0.6)
rc("cs_many", "check_series(d)", "result = DP.check_series(d)", list(d = d5))
rc("cs_print_n", "capture.output(print(check_series(d), max_issues = 3))",
   "import io, contextlib\nb = io.StringIO()\nwith contextlib.redirect_stdout(b):\n    DP.check_series(d).print(max_issues=3)\nresult = b.getvalue().rstrip('\\n').split('\\n')", list(d = d5))
d6 <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 10), A = 1:10 + 100)
rc("cs_clean", "check_series(d)", "result = DP.check_series(d)", list(d = d6))
rc("cs_split3", "check_series(data.frame(date = d6$date, A = c(90, 91, 92, 30.5, 31, 31.2, 31.3, 31.1, 93.3, 93)))",
   "result = DP.check_series(pd.DataFrame(dict(date=d6['date'], A=[90, 91, 92, 30.5, 31, 31.2, 31.3, 31.1, 93.3, 93])))", list(d6 = d6))
dna <- data.frame(date = as.Date("2020-01-01") + 0:4, C = NA_real_, A = c(1, 2, 3, 4, 5))
rc("cs_firstna", "check_series(d)", "result = DP.check_series(d)", list(d = dna))
rc("cs_onlyna", "check_series(d, columns = c('C', 'C'))", "result = DP.check_series(d, columns=['C', 'C'])", list(d = dna))
rc("cs_nocols", "check_series(d, columns = character(0))", "result = DP.check_series(d, columns=[])", list(d = dna))
rc("cs_err", "check_series(data.frame(x = 1))", "result = DP.check_series(pd.DataFrame(dict(x=[1.])))")

# ── align_macro ────────────────────────────────────────────────────────────
cpi <- data.frame(date = seq.Date(as.Date("2019-01-01"), by = "month", length.out = 36), value = 100 * 1.003^(0:35))
dm <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 120))
rc("am_yoy", "align_macro(d, cpi, 'infl', lag = 45, transform = 'yoy')", "result = DP.align_macro(d, cpi, 'infl', lag=45, transform='yoy')", list(d = dm, cpi = cpi))
rc("am_month", "align_macro(d$date, cpi, lag = 1, lag_unit = 'month')", "result = DP.align_macro(d['date'], cpi, lag=1, lag_unit='month')", list(d = dm, cpi = cpi))
rc("am_diff", "align_macro(d$date, cpi, transform = 'diff')", "result = DP.align_macro(d['date'], cpi, transform='diff')", list(d = dm, cpi = cpi))
rc("am_mom", "align_macro(d, cpi, transform = 'mom', lag = 10.5)", "result = DP.align_macro(d, cpi, transform='mom', lag=10.5)", list(d = dm, cpi = cpi))
rc("am_yoyd", "align_macro(d, cpi, 'x', transform = 'yoy_diff', lag = 2, lag_unit = 'month')",
   "result = DP.align_macro(d, cpi, 'x', transform='yoy_diff', lag=2, lag_unit='month')", list(d = dm, cpi = cpi))
cpi48 <- data.frame(date = seq.Date(as.Date("2018-01-01"), by = "month", length.out = 48), value = 100 * 1.002^(0:47))
rc("am_gap", "list(align_macro(dts, cpi[-30, ], transform = 'yoy'), align_macro(dts, cpi, transform = 'yoy'), align_macro(as.Date('2020-07-15'), cpi[-30, ], transform = 'mom'))",
   "result = [DP.align_macro(dts, cpi.drop(index=29), transform='yoy'), DP.align_macro(dts, cpi, transform='yoy'), DP.align_macro(np.array(['2020-07-15'], dtype='datetime64[D]'), cpi.drop(index=29), transform='mom')]",
   list(dts = as.Date(c("2021-03-15", "2021-06-15")), cpi = cpi48))
m5 <- data.frame(date = as.Date(c("2023-12-31", "2024-01-31", "2024-02-29", "2024-03-31", "2024-04-30")), cpi = 1:5)
d5m <- data.frame(date = seq.Date(as.Date("2024-01-25"), as.Date("2024-06-05"), by = "day"))
rc("am_monthend", "align_macro(d, m, 'cpi', lag = 1, lag_unit = 'month')", "result = DP.align_macro(d, m, 'cpi', lag=1, lag_unit='month')", list(d = d5m, m = m5))
q <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "quarter", length.out = 20), gdp = 100 + (1:20)^1.3)
rc("am_q", "align_macro(d, q, 'g', transform = 'yoy', lag = 30)", "result = DP.align_macro(d, q, 'g', transform='yoy', lag=30)",
   list(d = data.frame(date = seq.Date(as.Date("2015-06-01"), by = "week", length.out = 200)), q = q))
rc("am_qmom", "align_macro(d$date, q, transform = 'mom')", "result = DP.align_macro(d['date'], q, transform='mom')",
   list(d = data.frame(date = seq.Date(as.Date("2015-06-01"), by = "week", length.out = 200)), q = q))
yy <- data.frame(date = seq.Date(as.Date("2000-07-01"), by = "year", length.out = 15), v = seq(1, 5, length.out = 15)^2)
rc("am_y", "align_macro(d$date, m, transform = 'yoy_diff')", "result = DP.align_macro(d['date'], m, transform='yoy_diff')",
   list(d = data.frame(date = seq.Date(as.Date("2001-01-01"), by = "month", length.out = 100)), m = yy))
wk <- data.frame(date = seq.Date(as.Date("2020-01-06"), by = "week", length.out = 120), v = sin(1:120) + 3)
rc("am_w", "align_macro(d$date, m, transform = 'yoy')", "result = DP.align_macro(d['date'], m, transform='yoy')",
   list(d = data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 900)), m = wk))
rc("am_wp", "align_macro(d$date, m, transform = 'yoy', periods = 12)", "result = DP.align_macro(d['date'], m, transform='yoy', periods=12)",
   list(d = data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 900)), m = wk))
rc("am_wp5", "align_macro(d$date, m, transform = 'yoy', periods = 5)", "result = DP.align_macro(d['date'], m, transform='yoy', periods=5)",
   list(d = data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 300)), m = wk))
rc("am_daily", "align_macro(d$date, m, transform = 'yoy', lag = 1)", "result = DP.align_macro(d['date'], m, transform='yoy', lag=1)",
   list(d = data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 400)),
        m = data.frame(date = seq.Date(as.Date("2019-01-01"), by = "day", length.out = 600), v = 1:600 / 7)))
rc("am_named", "align_macro(d$date, c('2020-01-15' = 1, '2020-03-01' = 2, '2020-02-01' = 3))",
   "result = DP.align_macro(d['date'], pd.Series([1., 2, 3], index=['2020-01-15', '2020-03-01', '2020-02-01']))", list(d = dm))
rc("am_err", "align_macro(d, cpi, transform = 'abc')", "result = DP.align_macro(d, cpi, transform='abc')", list(d = dm, cpi = cpi))

# ── convert_currency ───────────────────────────────────────────────────────
dcc <- data.frame(date = as.Date("2024-01-01") + 0:3, A = c(110, 121, 132, 143), fx = c(1.1, 1.1, 1.2, 1.3))
rc("cc_col", "convert_currency(d, 'A', 'fx')", "result = DP.convert_currency(d, 'A', 'fx')", list(d = dcc))
rc("cc_mult", "convert_currency(d, 'A', 2, 'multiply', '_x')", "result = DP.convert_currency(d, 'A', 2, 'multiply', '_x')", list(d = dcc))
rc("cc_df", "convert_currency(d, c('A', 'fx'), fx = data.frame(date = as.Date(c('2024-01-03', '2024-01-02')), value = c(1.05, 1.1)), suffix = '_eur')",
   "result = DP.convert_currency(d, ['A', 'fx'], fx=pd.DataFrame(dict(date=np.array(['2024-01-03', '2024-01-02'], dtype='datetime64[D]'), value=[1.05, 1.1])), suffix='_eur')",
   list(d = dcc))
rc("cc_named", "convert_currency(d, 'A', c('2024-01-02' = 1.2, '2023-12-01' = 1.0))",
   "result = DP.convert_currency(d, 'A', pd.Series([1.2, 1.0], index=['2024-01-02', '2023-12-01']))", list(d = dcc))
rc("cc_vec", "convert_currency(d, 'A', c(1, 2, 3, 4))", "result = DP.convert_currency(d, 'A', np.array([1., 2, 3, 4]))", list(d = dcc))
rc("cc_errcol", "convert_currency(d, c('USD', 'A', 'x'), fx = 'fx')", "result = DP.convert_currency(d, ['USD', 'A', 'x'], fx='fx')", list(d = dcc))
rc("cc_errfx", "convert_currency(d, 'A', fx = 0)", "result = DP.convert_currency(d, 'A', fx=0)", list(d = dcc))
rc("cc_errfx2", "convert_currency(d, 'A', fx = c(1, -2.5, NA, 1))", "result = DP.convert_currency(d, 'A', fx=np.array([1, -2.5, simlev._r.fmt.NA_REAL, 1]))", list(d = dcc))
rc("cc_errfx3", "convert_currency(d, 'A', fx = 'nope')", "result = DP.convert_currency(d, 'A', fx='nope')", list(d = dcc))
rc("cc_errfx4", "convert_currency(d, 'A', fx = 1:3)", "result = DP.convert_currency(d, 'A', fx=np.arange(1, 4))", list(d = dcc))
rc("cc_errfx5", "convert_currency(d, 'A', fx = data.frame(date = d$date))", "result = DP.convert_currency(d, 'A', fx=pd.DataFrame(dict(date=d['date'])))", list(d = dcc))

# ── total_return_index ─────────────────────────────────────────────────────
rc("tri_div", "total_return_index(c(100, 100, 98, 99), dividends = c(0, 0, 2, 0), withholding = 15)",
   "result = DP.total_return_index(np.array([100., 100, 98, 99]), dividends=np.array([0., 0, 2, 0]), withholding=15)")
rc("tri_yield", "total_return_index(rep(100, 366), yield = 2, dates = seq.Date(as.Date('2021-01-01'), by = 'day', length.out = 366))",
   "result = DP.total_return_index(np.full(366, 100.), yield_=2, dates=np.datetime64('2021-01-01') + np.arange(366).astype('m8[D]'))")
set.seed(2); pp <- 100 * cumprod(1 + rnorm(200, 2e-4, 0.01)); pp[c(1, 5, 6, 100)] <- NA
divv <- rep(NA, 200); divv[c(50, 120, 190)] <- c(0.5, 0.7, 0.4)
rc("tri_full", "total_return_index(p, dividends = dv, yield = seq(1, 3, length.out = 200), withholding = 26.375, dates = td('2020-01-01', 280), start = 1000)",
   "result = DP.total_return_index(p, dividends=dv, **{'yield': np.linspace(1, 3, 200)}, withholding=26.375, dates=dts, start=1000)",
   list(p = pp, dv = divv, dts = td("2020-01-01", 280)))
rc("tri_ychr", "total_return_index(p, yield = c(1, 2), dates = format(td('2020-01-01', 280)))",
   "result = DP.total_return_index(p, yield_=np.array([1., 2]), dates=[str(x) for x in dts])", list(p = pp, dts = td("2020-01-01", 280)))
rc("tri_err", "total_return_index(rep(100, 6), yield = 2, dates = dts[c(1, 2, 3, 6, 5, 4)])",
   "result = DP.total_return_index(np.full(6, 100.), yield_=2, dates=dts[[0, 1, 2, 5, 4, 3]])",
   list(dts = seq.Date(as.Date("2024-01-01"), by = "day", length.out = 6)))
rc("tri_err2", "total_return_index(rep(100, 6), dates = dts[1:5])", "result = DP.total_return_index(np.full(6, 100.), dates=dts[:5])",
   list(dts = seq.Date(as.Date("2024-01-01"), by = "day", length.out = 6)))
rc("tri_one", "total_return_index(5)", "result = DP.total_return_index(5.)")

# ── deflate ────────────────────────────────────────────────────────────────
rc("df_col", "deflate(data.frame(date = d$date, A = d$A, cpi = c(100, 110, 121, 130)), 'A', 'cpi')",
   "result = DP.deflate(pd.DataFrame(dict(date=d['date'], A=d['A'], cpi=[100., 110, 121, 130])), 'A', 'cpi')", list(d = dcc))
cpi24 <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "month", length.out = 24), value = 100 * 1.01^(0:23))
ddf <- data.frame(date = seq.Date(as.Date("2019-11-01"), by = "day", length.out = 200), depot = 100, d2 = 1:200)
rc("df_macro", "d1 <- align_macro(d, cpi, 'cpi'); deflate(d1, c('depot', 'd2'), cpi = 'cpi', suffix = '_r')",
   "d1 = DP.align_macro(d, cpi, 'cpi'); result = DP.deflate(d1, ['depot', 'd2'], cpi='cpi', suffix='_r')", list(d = ddf, cpi = cpi24))
rc("df_dfcpi", "deflate(d, 'depot', cpi = cpi)", "result = DP.deflate(d, 'depot', cpi=cpi)", list(d = ddf, cpi = cpi24))
rc("df_base", "deflate(d, 'd2', cpi = cpi, base_date = '2020-03-17')", "result = DP.deflate(d, 'd2', cpi=cpi, base_date='2020-03-17')", list(d = ddf, cpi = cpi24))
rc("df_named", "deflate(d, 'd2', cpi = c('2020-01-01' = 100, '2020-02-15' = 101, '2020-04-01' = 103))",
   "result = DP.deflate(d, 'd2', cpi=pd.Series([100., 101, 103], index=['2020-01-01', '2020-02-15', '2020-04-01']))", list(d = ddf))
rc("df_vec", "deflate(d, 'd2', cpi = 100 + (1:200) / 10, base_date = as.Date('2020-12-31'))",
   "result = DP.deflate(d, 'd2', cpi=100 + np.arange(1, 201) / 10, base_date=np.datetime64('2020-12-31'))", list(d = ddf))
rc("df_errbase", "d1 <- align_macro(d, cpi, 'cpi'); deflate(d1, 'depot', cpi = 'cpi', base_date = '2019-12-01')",
   "d1 = DP.align_macro(d, cpi, 'cpi'); result = DP.deflate(d1, 'depot', cpi='cpi', base_date='2019-12-01')", list(d = ddf, cpi = cpi24))
rc("df_errnone", "deflate(d, 'depot', cpi = data.frame(date = as.Date('2030-01-01'), v = 1))",
   "result = DP.deflate(d, 'depot', cpi=pd.DataFrame(dict(date=np.array(['2030-01-01'], dtype='datetime64[D]'), v=[1.])))", list(d = ddf))
rc("df_errcol", "deflate(d, 'depot', cpi = 'cpi')", "result = DP.deflate(d, 'depot', cpi='cpi')", list(d = ddf))
rc("cpilevel", "SimLev:::.cpi_level(cpi, d, d$date, 'cpi')", "result = DP._cpi_level(cpi, d, d['date'], 'cpi')", list(d = ddf, cpi = cpi24))

# ── splice_series ──────────────────────────────────────────────────────────
f1 <- data.frame(date = as.Date("2024-03-01") + 0:5, value = c(10, 11, 12, 12.5, 13, 14))
f2 <- data.frame(date = as.Date("2024-02-20") + 0:20, value = 200 + 0:20)
rc("sp_basic", "splice_series(fund = f1, proxy = f2)", "result = DP.splice_series(fund=f1, proxy=f2)", list(f1 = f1, f2 = f2))
proxy <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = 400))
proxy$value <- 100 * cumprod(1 + c(0, rep(0.001, 399)))
fonds <- proxy[proxy$date >= as.Date("2010-03-01"), ]; fonds$value <- fonds$value / 2
fonds <- fonds[!(fonds$date > as.Date("2010-06-01") & fonds$date < as.Date("2010-07-01")), ]
rc("sp_gap", "splice_series(fonds = fonds, proxy = proxy)", "result = DP.splice_series(fonds=fonds, proxy=proxy)", list(fonds = fonds, proxy = proxy))
tdx <- td("2020-01-01", 200)
p2 <- data.frame(date = tdx, value = 100 * 1.001^seq_along(tdx)); f2b <- p2[p2$date >= as.Date("2020-03-01"), ]
rc("sp_trading", "splice_series(f = f2b, p = p2)", "result = DP.splice_series(f=f2b, p=p2)", list(f2b = f2b, p2 = p2))
set.seed(1)
cal <- seq.Date(as.Date("2020-01-01"), by = "day", length.out = 120)
idx <- data.frame(date = cal, value = 100 * cumprod(1 + rnorm(120, 0, 0.01)))
etf <- idx[!format(cal, "%u") %in% c("6", "7") & cal >= as.Date("2020-02-01"), ]; etf$value <- etf$value / 2
e2 <- etf[!(etf$date > as.Date("2020-03-02") & etf$date < as.Date("2020-03-09")), ]
rc("sp_we", "splice_series(etf = etf, idx = idx)", "result = DP.splice_series(etf=etf, idx=idx)", list(etf = etf, idx = idx))
rc("sp_we2", "splice_series(etf = e2, idx = idx, other = etf[etf$date > as.Date('2020-03-04'), ])",
   "result = DP.splice_series(etf=e2, idx=idx, other=etf[etf['date'] > np.datetime64('2020-03-04')])", list(etf = etf, e2 = e2, idx = idx))
vv1 <- c(NA, NA, NA, 5, 5.5, NA, 6, 6.1); vv2 <- c(1, 1.1, NA, 1.2, 1.3, 1.25, 1.4, 1.5); vv3 <- c(2, 2.2, 2.3, 2.4, NA, 2.5, 2.6, 2.7)
rc("sp_vec", "splice_series(a = v1, b = v2, c = v3, dates = as.Date('2024-01-01') + 0:7)",
   "result = DP.splice_series(a=v1, b=v2, c=v3, dates=np.datetime64('2024-01-01') + np.arange(8).astype('m8[D]'))", list(v1 = vv1, v2 = vv2, v3 = vv3))
rc("sp_vec2", "splice_series(a = v1, b = v2, dates = format(as.Date('2024-01-01') + 0:7))",
   "result = DP.splice_series(a=v1, b=v2, dates=[str(np.datetime64('2024-01-01') + np.timedelta64(i, 'D')) for i in range(8)])", list(v1 = vv1, v2 = vv2))
rc("sp_err1", "splice_series(a = f1)", "result = DP.splice_series(a=f1)", list(f1 = f1))
rc("sp_err2", "splice_series(a = 1:3, b = 1:3)", "result = DP.splice_series(a=np.arange(1, 4), b=np.arange(1, 4))")
rc("sp_err3", "splice_series(a = c(NA, NA), b = 1:2, dates = as.Date('2024-01-01') + 0:1)",
   "result = DP.splice_series(a=np.array([simlev._r.fmt.NA_REAL, simlev._r.fmt.NA_REAL]), b=np.arange(1, 3), dates=np.datetime64('2024-01-01') + np.arange(2).astype('m8[D]'))")
rc("sp_err4", "splice_series(f1, f2)", "result = DP.splice_series(f1, f2)", list(f1 = f1, f2 = f2))

# ── strategy_from_weights / portfolio_template ─────────────────────────────
rc("sw_doc", "strategy_from_weights(c(world = 0.6, bonds = 0.4), asset_spread = c(world = 0.1, bonds = 0.05))",
   "result = DP.strategy_from_weights(pd.Series([0.6, 0.4], index=['world', 'bonds']), asset_spread=pd.Series([0.1, 0.05], index=['world', 'bonds']))")
rc("sw_class", "strategy_from_weights(c(aktien = 0.7, gold = 0.3), asset_class = c(aktien = 'etf', gold = 'etc'), asset_bonus = c(aktien = 30, gold = 0))",
   "result = DP.strategy_from_weights({'aktien': 0.7, 'gold': 0.3}, asset_class={'aktien': 'etf', 'gold': 'etc'}, asset_bonus={'aktien': 30, 'gold': 0})")
rc("sw_one", "strategy_from_weights(c(aktien = 0.7, gold = 0.3), asset_bonus = c(aktien = 30))",
   "result = DP.strategy_from_weights({'aktien': 0.7, 'gold': 0.3}, asset_bonus={'aktien': 30})")
rc("sw_all", "strategy_from_weights(c(a = 0.5, b = 0.5), asset_spread = 0.2, asset_class = 'etc', deliverable = TRUE)",
   "result = DP.strategy_from_weights({'a': 0.5, 'b': 0.5}, asset_spread=0.2, asset_class='etc', deliverable=True)")
rc("sw_namedall", "strategy_from_weights(c(a = 0.5, b = 0.5), asset_spread = c(x = 0.3))",
   "result = DP.strategy_from_weights({'a': 0.5, 'b': 0.5}, asset_spread={'x': 0.3})")
rc("sw_na", "strategy_from_weights(c(a = 0.5, b = 0.5), asset_spread = NA)",
   "result = DP.strategy_from_weights({'a': 0.5, 'b': 0.5}, asset_spread=simlev._r.fmt.NA_REAL)")
rc("sw_err_sum", "strategy_from_weights(c(a = 0.3, b = 0.3))", "result = DP.strategy_from_weights({'a': 0.3, 'b': 0.3})")
rc("sw_err_dup", "strategy_from_weights(c(a = 0.5, a = 0.5))", "result = DP.strategy_from_weights(pd.Series([0.5, 0.5], index=['a', 'a']))")
rc("sw_err_pos", "strategy_from_weights(c(a = 1, b = 0))", "result = DP.strategy_from_weights({'a': 1., 'b': 0.})")
rc("sw_err_name", "strategy_from_weights(c(0.5, 0.5))", "result = DP.strategy_from_weights(np.array([0.5, 0.5]))")
rc("sw_err_cfg", "strategy_from_weights(c(a = 0.5, b = 0.5), asset_bonus = c(a = 130))", "result = DP.strategy_from_weights({'a': 0.5, 'b': 0.5}, asset_bonus={'a': 130})")
rc("pt_perm", "portfolio_template('permanent', map = c(stocks = 'msci_world', long_bonds = 'bund_10y', cash = 'geldmarkt', gold = 'gold_eur'))",
   "result = DP.portfolio_template('permanent', map={'stocks': 'msci_world', 'long_bonds': 'bund_10y', 'cash': 'geldmarkt', 'gold': 'gold_eur'})")
rc("pt_partial", "portfolio_template('permanent', map = c(stocks = 'W'), asset_spread = 0)",
   "result = DP.portfolio_template('permanent', map={'stocks': 'W'}, asset_spread=0)")
for (tn in names(SimLev:::.portfolio_templates))
  rc(paste0("pt_", tn), sprintf("portfolio_template('%s')", tn), sprintf("result = DP.portfolio_template('%s')", tn))
rc("pt_list", "portfolio_templates()", "result = DP.portfolio_templates()")
rc("pt_err1", "portfolio_template('xyz')", "result = DP.portfolio_template('xyz')")
rc("pt_err2", "portfolio_template('60_40', map = c(stock = 'A', bonds = 'B'))", "result = DP.portfolio_template('60_40', map={'stock': 'A', 'bonds': 'B'})")
rc("pt_err3", "portfolio_template('60_40', map = c(stocks = 'A', bonds = 'A'))", "result = DP.portfolio_template('60_40', map={'stocks': 'A', 'bonds': 'A'})")
rc("pt_err4", "portfolio_template('60_40', map = c('A', 'B'))", "result = DP.portfolio_template('60_40', map=['A', 'B'])")

# ── bonds ──────────────────────────────────────────────────────────────────
db <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 3), y = c(2, 2, 3))
BI <- "b <- %s; list(b = as.numeric(b), duration = attr(b, 'duration'))"
BIP <- "b = %s\nresult = dict(b=np.asarray(b), duration=b.attrs['duration'])"
rc("bond_small", sprintf(BI, "bond_index_from_yields(d, 'y', maturity = 10, coupon_frequency = 1)"),
   sprintf(BIP, "BO.bond_index_from_yields(d, 'y', maturity=10, coupon_frequency=1)"), list(d = db))
set.seed(1); dbl <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 400)); dbl$y10 <- 2 + cumsum(rnorm(400, 0, 0.03))
dbl$y10[150:160] <- -0.0000000001 * (1:11); dbl$y10[161] <- 0
rc("bond_doc", sprintf(BI, "bond_index_from_yields(d, 'y10', maturity = 10, coupon_frequency = 1)"),
   sprintf(BIP, "BO.bond_index_from_yields(d, 'y10', maturity=10, coupon_frequency=1)"), list(d = dbl))
rc("bond_dur", sprintf(BI, "bond_index_from_yields(d, 'y10', method = 'duration', maturity = 7, coupon_frequency = 2, start = 1)"),
   sprintf(BIP, "BO.bond_index_from_yields(d, 'y10', method='duration', maturity=7, coupon_frequency=2, start=1)"), list(d = dbl))
rc("bond_df", sprintf(BI, "bond_index_from_yields(d, data.frame(date = as.Date(c('2020-01-01', '2020-06-01')), v = c(1, 4)), maturity = 30)"),
   sprintf(BIP, "BO.bond_index_from_yields(d, pd.DataFrame(dict(date=np.array(['2020-01-01', '2020-06-01'], dtype='datetime64[D]'), v=[1., 4])), maturity=30)"), list(d = dbl))
rc("bond_td", sprintf(BI, "bond_index_from_yields(d, 2.5, method = 'dur')"),
   sprintf(BIP, "BO.bond_index_from_yields(d, 2.5, method='dur')"), list(d = data.frame(date = td("2020-01-01", 40))))
rc("bond_zero", sprintf(BI, "bond_index_from_yields(z, 'y')"), sprintf(BIP, "BO.bond_index_from_yields(z, 'y')"),
   list(z = data.frame(date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = 30), y = 0)))
dc <- data.frame(date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = 366), y = 3, x = 100)
rc("mm_col", "money_market_index(d, 'y')", "result = BO.money_market_index(d, 'y')", list(d = dc))
rc("mm_spread", "money_market_index(d, 3, spread = 1, basis = 365, start = 1)", "result = BO.money_market_index(d, 3, spread=1, basis=365, start=1)", list(d = dc))
rc("mm_df", "money_market_index(d, data.frame(date = as.Date(c('2020-12-01', '2021-06-01')), value = c(1, 2)))",
   "result = BO.money_market_index(d, pd.DataFrame(dict(date=np.array(['2020-12-01', '2021-06-01'], dtype='datetime64[D]'), value=[1., 2])))", list(d = dc))
rc("mm_named", "money_market_index(d, c('2020-01-01' = 0, '2021-01-01' = 2))",
   "result = BO.money_market_index(d, pd.Series([0., 2], index=['2020-01-01', '2021-01-01']))",
   list(d = data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 730))))
rc("mm_td", "money_market_index(d, 'r')", "result = BO.money_market_index(d, 'r')",
   list(d = data.frame(date = td("2020-01-01", 100), r = c(rep(1, 30), NA, rep(4, 41)))))
rc("mm_err", "money_market_index(d, 'zz')", "result = BO.money_market_index(d, 'zz')", list(d = dc))
rc("ch_basic", "currency_hedged_index(d, 'x', 3, 1)", "result = BO.currency_hedged_index(d, 'x', 3, 1)", list(d = dc))
set.seed(1); dh <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 730)); dh$sp500 <- 100 * cumprod(1 + rnorm(730, 3e-4, 0.01))
dh$sp500[c(1:3, 100, 400:402)] <- NA; dh$rf <- seq(5, 1, length.out = 730)
rc("ch_doc", "currency_hedged_index(d, 'sp500', domestic_rate = 3, foreign_rate = 'rf', cost = 0.1)",
   "result = BO.currency_hedged_index(d, 'sp500', domestic_rate=3, foreign_rate='rf', cost=0.1)", list(d = dh))
rc("ch_vec", "currency_hedged_index(d, d$sp500 * 2, c('2020-01-01' = 1, '2020-08-01' = 2), data.frame(date = as.Date('2020-01-01'), r = 0.5), basis = 365, start = 10)",
   "result = BO.currency_hedged_index(d, d['sp500'] * 2, pd.Series([1., 2], index=['2020-01-01', '2020-08-01']), pd.DataFrame(dict(date=np.array(['2020-01-01'], dtype='datetime64[D]'), r=[0.5])), basis=365, start=10)",
   list(d = dh))
ref_done()
