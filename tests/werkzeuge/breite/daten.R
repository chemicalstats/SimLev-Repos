# tests/werkzeuge/breite/daten.R – Referenzfälle des Bereichs daten: Datenaufbereitung, Portfolio-Vorlagen, Rückrechnung (backcast), Signale.
# Module: data_prep, backcast, signals (bis 1.4.0 je ein Generator gen_<modul>.R, hier wörtlich hintereinander).
# Aufruf (Repo-Wurzel): LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/breite/daten.R
# Breitenprüfung, nichts abgelegt: alle bisherigen Einzelfälle des Bereichs (bis 1.4.1 Generator des Katalogs) flach nach
# <ordner>/breite_daten.jsonl.gz; tests/werkzeuge/gleichlauf/run.py vergleicht Python und Julia damit. Abgelegt sind die Szenarien
# und Tabellen aus tests/gleichlauf/erzeugen/daten.R (Format und Umgebung: tests/gleichlauf/erzeugen/ref_tools.R).
source("tests/gleichlauf/erzeugen/ref_tools.R")
ref_bereich("breite_daten", alle = TRUE)

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul data_prep
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Referenzfälle für simlev.data_prep und simlev.bonds (r/R/data_prep.R, r/R/bonds.R).
ref_init("data_prep")
P <- "from simlev import data_prep as DP, bonds as BO\n"
# ── Julia-Code je Fall (Feld jl; Eingaben als Variablen, siehe tests/lib/faelle.jl) ──
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
  al_basic = ALJ('DP.series_align(us = a, eu = b)'),
  al_maxgap = ALJ('DP.series_align(us = a, eu = b, max_gap = 10)'),
  al_maxgap2 = ALJ('DP.series_align(us = a, eu = b, max_gap = 2.5, fill = "linear")'),
  al_inter = ALJ('DP.series_align(us = a, eu = b, calendar = "intersect", range = "all")'),
  al_union = ALJ('DP.series_align(us = a, eu = b, calendar = "union", range = "all")'),
  al_union_c = ALJ('DP.series_align(us = a, eu = b, calendar = "uni")'),
  al_all_lin = ALJ('DP.series_align(us = a, eu = b, range = "all", fill = "linear")'),
  al_none = ALJ('DP.series_align(us = a, eu = b, range = "all", fill = "none")'),
  al_startend = ALJ('DP.series_align(us = a, eu = b, range = "all", start = "2024-01-03", end_ = Date(2024, 1, 20))'),
  al_err_name = 'result = DP.series_align(a, b)',
  al_err_none = 'result = DP.series_align()',
  al_err_overlap = 'result = DP.series_align(us = a, eu = b, start = "2025-01-01")',
  al_err_dup = 'result = DP.series_align(us = RFrame("date" => a.date, "A" => collect(1:5), "B" => collect(2:6)), eu = RFrame("date" => a.date, "A" => collect(1:5), "C" => fill(1.0, 5)))',
  al_err_arg = 'result = DP.series_align(us = a, fill = "spline")',
  al_named = ALJ('DP.series_align(x = named("2024-01-03" => 1.0, "2024-01-01" => 2.0, "2024-01-07" => 3.0), y = b)'),
  al_multi = ALJ('DP.series_align(us = RFrame("date" => b.date, "A" => b.close, "B" => reverse(b.close), "txt" => fill("x", nrow(b))), eu = a)'),
  al_rownum = ALJ('DP.series_align(etf = roh)'),
  al_rownum1 = ALJ('DP.series_align(etf = RFrame("X" => roh.X, "Kurs" => roh.Kurs), b = RFrame("Datum" => roh.Datum, "Kurs" => roh.Kurs))'),
  al_numdate = 'result = DP.series_align(etf = RFrame("X" => collect(1:30), "Kurs" => roh.Kurs))',
  al_firstcol = ALJ('DP.series_align(etf = RFrame("tag" => string.(tage), "Kurs" => roh.Kurs))'),
  al_baddate = 'result = DP.series_align(a = x20)',
  al_dotdate = 'x20.date = Dates.format.(tage, "dd.mm.yyyy")\nresult = DP.series_align(a = x20)',
  al_text = 'result = DP.series_align(a = RFrame("date" => dft.date, "Kurs" => dft.kurs, "Volumen" => collect(1:60)))',
  al_factor = 'result = DP.series_align(a = RFrame("date" => dft.date, "Kurs" => dft.kurs))',
  al_nonum = 'result = DP.series_align(a = RFrame("date" => dft.date, "n" => dft.name))',
  al_notdf = 'result = DP.series_align(a = collect(1:3))',
  al_posix = ALJ('DP.series_align(a = RFrame("date" => DateTime.(tage), "value" => roh.Kurs))'),
  al_dups = ALJ('DP.series_align(v = xd, w = b)'),
  al_trading = ALJ('DP.series_align(us = us)'),
  al_trading_end = ALJ('DP.series_align(A = us, end_ = "2021-02-13")'),
  al_int = ALJ('DP.series_align(a = RFrame("date" => a.date, "v" => [1, missing, 3, 4, 5]), b = b)'),
  al_nainside = ALJ('DP.series_align(a = RFrame("date" => a.date, "v" => [1, NA, 3, NA, 5]), b = b, fill = "linear", range = "all")'),
  cs_doc = 'result = DP.series_check(d)',
  cs_multi = 'result = DP.series_check(d; jump = 15, stale = 5, revert = 0.5)',
  cs_cols = 'result = DP.series_check(d; columns = "B")',
  cs_neg = 'result = DP.series_check(d)',
  cs_neg2 = 'result = DP.series_check(d)',
  cs_nadate = 'result = DP.series_check(x)',
  cs_dates = 'result = DP.series_check(d)',
  cs_dates_c = 'result = DP.series_check(d; columns = ["A", "C"])',
  cs_many = 'result = DP.series_check(d)',
  cs_print_n = 'result = split(DP.format_SimLevDataCheck(DP.series_check(d); max_issues = 3), "\\n")',
  cs_clean = 'result = DP.series_check(d)',
  cs_split3 = 'result = DP.series_check(RFrame("date" => d6.date, "A" => [90, 91, 92, 30.5, 31, 31.2, 31.3, 31.1, 93.3, 93]))',
  cs_firstna = 'result = DP.series_check(d)',
  cs_onlyna = 'result = DP.series_check(d; columns = ["C", "C"])',
  cs_nocols = 'result = DP.series_check(d; columns = String[])',
  cs_err = 'result = DP.series_check(RFrame("x" => [1.0]))',
  am_yoy = 'result = DP.series_align_macro(d, cpi; name = "infl", lag = 45, transform = "yoy")',
  am_month = 'result = DP.series_align_macro(d.date, cpi; lag = 1, lag_unit = "month")',
  am_diff = 'result = DP.series_align_macro(d.date, cpi; transform = "diff")',
  am_mom = 'result = DP.series_align_macro(d, cpi; transform = "mom", lag = 10.5)',
  am_yoyd = 'result = DP.series_align_macro(d, cpi; name = "x", transform = "yoy_diff", lag = 2, lag_unit = "month")',
  am_gap = 'c29 = rows(cpi, setdiff(1:nrow(cpi), 30))\nresult = [DP.series_align_macro(dts, c29; transform = "yoy"), DP.series_align_macro(dts, cpi; transform = "yoy"), DP.series_align_macro(Date(2020, 7, 15), c29; transform = "mom")]',
  am_monthend = 'result = DP.series_align_macro(d, m; name = "cpi", lag = 1, lag_unit = "month")',
  am_q = 'result = DP.series_align_macro(d, q; name = "g", transform = "yoy", lag = 30)',
  am_qmom = 'result = DP.series_align_macro(d.date, q; transform = "mom")',
  am_y = 'result = DP.series_align_macro(d.date, m; transform = "yoy_diff")',
  am_w = 'result = DP.series_align_macro(d.date, m; transform = "yoy")',
  am_wp = 'result = DP.series_align_macro(d.date, m; transform = "yoy", periods = 12)',
  am_wp5 = 'result = DP.series_align_macro(d.date, m; transform = "yoy", periods = 5)',
  am_daily = 'result = DP.series_align_macro(d.date, m; transform = "yoy", lag = 1)',
  am_named = 'result = DP.series_align_macro(d.date, named("2020-01-15" => 1.0, "2020-03-01" => 2.0, "2020-02-01" => 3.0))',
  am_err = 'result = DP.series_align_macro(d, cpi; transform = "abc")',
  cc_col = 'result = DP.series_convert_currency(d, "A", "fx")',
  cc_mult = 'result = DP.series_convert_currency(d, "A", 2; method = "multiply", suffix = "_x")',
  cc_df = 'result = DP.series_convert_currency(d, ["A", "fx"], RFrame("date" => Date.(["2024-01-03", "2024-01-02"]), "value" => [1.05, 1.1]); suffix = "_eur")',
  cc_named = 'result = DP.series_convert_currency(d, "A", named("2024-01-02" => 1.2, "2023-12-01" => 1.0))',
  cc_vec = 'result = DP.series_convert_currency(d, "A", [1.0, 2, 3, 4])',
  cc_errcol = 'result = DP.series_convert_currency(d, ["USD", "A", "x"], "fx")',
  cc_errfx = 'result = DP.series_convert_currency(d, "A", 0)',
  cc_errfx2 = 'result = DP.series_convert_currency(d, "A", [1, -2.5, NA, 1])',
  cc_errfx3 = 'result = DP.series_convert_currency(d, "A", "nope")',
  cc_errfx4 = 'result = DP.series_convert_currency(d, "A", collect(1:3))',
  cc_errfx5 = 'result = DP.series_convert_currency(d, "A", RFrame("date" => d.date))',
  tri_div = 'result = DP.index_total_return([100.0, 100, 98, 99]; dividends = [0.0, 0, 2, 0], withholding = 15)',
  tri_yield = 'result = DP.index_total_return(fill(100.0, 366); yield = 2, dates = Date(2021, 1, 1) .+ Day.(0:365))',
  tri_full = 'result = DP.index_total_return(p; dividends = dv, yield = vcat(1.0, 1.0 .+ collect(1:198) .* (2 / 199), 3.0), withholding = 26.375, dates = dts, start = 1000)',
  tri_ychr = 'result = DP.index_total_return(p; yield = [1.0, 2.0], dates = string.(dts))',
  tri_err = 'result = DP.index_total_return(fill(100.0, 6); yield = 2, dates = dts[[1, 2, 3, 6, 5, 4]])',
  tri_err2 = 'result = DP.index_total_return(fill(100.0, 6); dates = dts[1:5])',
  tri_one = 'result = DP.index_total_return(5.0)',
  df_col = 'result = DP.series_deflate(RFrame("date" => d.date, "A" => d.A, "cpi" => [100.0, 110, 121, 130]), "A", "cpi")',
  df_macro = 'd1 = DP.series_align_macro(d, cpi; name = "cpi")\nresult = DP.series_deflate(d1, ["depot", "d2"], "cpi"; suffix = "_r")',
  df_dfcpi = 'result = DP.series_deflate(d, "depot", cpi)',
  df_base = 'result = DP.series_deflate(d, "d2", cpi; base_date = "2020-03-17")',
  df_named = 'result = DP.series_deflate(d, "d2", named("2020-01-01" => 100.0, "2020-02-15" => 101.0, "2020-04-01" => 103.0))',
  df_vec = 'result = DP.series_deflate(d, "d2", 100 .+ collect(1:200) ./ 10; base_date = Date(2020, 12, 31))',
  df_errbase = 'd1 = DP.series_align_macro(d, cpi; name = "cpi")\nresult = DP.series_deflate(d1, "depot", "cpi"; base_date = "2019-12-01")',
  df_errnone = 'result = DP.series_deflate(d, "depot", RFrame("date" => [Date(2030, 1, 1)], "v" => [1.0]))',
  df_errcol = 'result = DP.series_deflate(d, "depot", "cpi")',
  cpilevel = 'result = DP._cpi_level(cpi, d, d.date, "cpi")',
  sp_basic = 'result = DP.series_splice(fund = f1, proxy = f2)',
  sp_gap = 'result = DP.series_splice(fonds = fonds, proxy = proxy)',
  sp_trading = 'result = DP.series_splice(f = f2b, p = p2)',
  sp_we = 'result = DP.series_splice(etf = etf, idx = idx)',
  sp_we2 = 'result = DP.series_splice(etf = e2, idx = idx, other = rows(etf, etf.date .> Date(2020, 3, 4)))',
  sp_vec = 'result = DP.series_splice(a = v1, b = v2, c = v3, dates = Date(2024, 1, 1) .+ Day.(0:7))',
  sp_vec2 = 'result = DP.series_splice(a = v1, b = v2, dates = string.(Date(2024, 1, 1) .+ Day.(0:7)))',
  sp_err1 = 'result = DP.series_splice(a = f1)',
  sp_err2 = 'result = DP.series_splice(a = collect(1:3), b = collect(1:3))',
  sp_err3 = 'result = DP.series_splice(a = [NA, NA], b = collect(1:2), dates = Date(2024, 1, 1) .+ Day.(0:1))',
  sp_err4 = 'result = DP.series_splice(f1, f2)',
  sw_doc = 'result = DP.strategy_from_weights(named("world" => 0.6, "bonds" => 0.4); spread = named("world" => 0.1, "bonds" => 0.05))',
  sw_class = 'result = DP.strategy_from_weights(named("aktien" => 0.7, "gold" => 0.3); asset_class = named("aktien" => "etf", "gold" => "etc"), partial_exemption = named("aktien" => 30.0, "gold" => 0.0), spread = 0.1)',
  sw_one = 'result = DP.strategy_from_weights(named("aktien" => 0.7, "gold" => 0.3); partial_exemption = named("aktien" => 30.0), spread = 0.1)',
  sw_all = 'result = DP.strategy_from_weights(named("a" => 0.5, "b" => 0.5); spread = 0.2, asset_class = "etc", deliverable = true)',
  sw_namedall = 'result = DP.strategy_from_weights(named("a" => 0.5, "b" => 0.5); spread = named("x" => 0.3))',
  sw_na = 'result = DP.strategy_from_weights(named("a" => 0.5, "b" => 0.5); spread = NA)',
  sw_err_sum = 'result = DP.strategy_from_weights(named("a" => 0.3, "b" => 0.3))',
  sw_err_dup = 'result = DP.strategy_from_weights(named("a" => 0.5, "a" => 0.5))',
  sw_err_pos = 'result = DP.strategy_from_weights(named("a" => 1.0, "b" => 0.0))',
  sw_err_name = 'result = DP.strategy_from_weights([0.5, 0.5])',
  sw_err_cfg = 'result = DP.strategy_from_weights(named("a" => 0.5, "b" => 0.5); partial_exemption = named("a" => 130.0))',
  pt_perm = 'result = DP.portfolio_template("permanent"; map = named("stocks" => "msci_world", "long_bonds" => "bund_10y", "cash" => "geldmarkt", "gold" => "gold_eur"), spread = 0.1)',
  pt_partial = 'result = DP.portfolio_template("permanent"; map = named("stocks" => "W"), spread = 0)',
  pt_list = 'result = DP.portfolio_template()',
  pt_err1 = 'result = DP.portfolio_template("xyz")',
  pt_err2 = 'result = DP.portfolio_template("60_40"; map = named("stock" => "A", "bonds" => "B"))',
  pt_err3 = 'result = DP.portfolio_template("60_40"; map = named("stocks" => "A", "bonds" => "A"))',
  pt_err4 = 'result = DP.portfolio_template("60_40"; map = ["A", "B"])',
  pt_err5 = 'result = DP.portfolio_template(; map = named("stocks" => "A"))',
  bond_small = BIJ('BO.index_bond(d, "y"; maturity = 10, coupon_frequency = 1)'),
  bond_doc = BIJ('BO.index_bond(d, "y10"; maturity = 10, coupon_frequency = 1)'),
  bond_dur = BIJ('BO.index_bond(d, "y10"; method = "duration", maturity = 7, coupon_frequency = 2, start = 1)'),
  bond_df = BIJ('BO.index_bond(d, RFrame("date" => Date.(["2020-01-01", "2020-06-01"]), "v" => [1.0, 4.0]); maturity = 30)'),
  bond_td = BIJ('BO.index_bond(d, 2.5; method = "dur")'),
  bond_zero = BIJ('BO.index_bond(z, "y")'),
  mm_col = 'result = BO.index_money_market(d, "y")',
  mm_spread = 'result = BO.index_money_market(d, 3; spread = 1, basis = 365, start = 1)',
  mm_df = 'result = BO.index_money_market(d, RFrame("date" => Date.(["2020-12-01", "2021-06-01"]), "value" => [1.0, 2.0]))',
  mm_named = 'result = BO.index_money_market(d, named("2020-01-01" => 0.0, "2021-01-01" => 2.0))',
  mm_td = 'result = BO.index_money_market(d, "r")',
  mm_err = 'result = BO.index_money_market(d, "zz")',
  ch_basic = 'result = BO.index_currency_hedged(d, "x", 3, 1)',
  ch_doc = 'result = BO.index_currency_hedged(d, "sp500", 3, "rf"; cost = 0.1)',
  ch_vec = 'result = BO.index_currency_hedged(d, d.sp500 .* 2, named("2020-01-01" => 1.0, "2020-08-01" => 2.0), RFrame("date" => [Date(2020, 1, 1)], "r" => [0.5]); basis = 365, start = 10)'
)
for (tn in names(SimLev:::.portfolio_templates)) JL[[paste0("pt_", tn)]] <- sprintf('result = DP.portfolio_template("%s"; spread = 0.1)', tn)
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
rc("todate_lax", "SimLev:::.to_date(c('31-12-2024', '2021-02-30', '2020-02-29', '99999-01-01'), strict = FALSE)",
   "result = DP._to_date(['31-12-2024', '2021-02-30', '2020-02-29', '99999-01-01'], strict=False)")
rc("todate_date", "SimLev:::.to_date(d)", "result = DP._to_date(d)", list(d = as.Date(c("2020-01-01", NA, "1900-02-28"))))

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

# ── series_align ───────────────────────────────────────────────────────────
a <- data.frame(date = as.Date("2024-01-01") + c(0, 1, 2, 5, 30), value = c(100, 101, 102, 103, 110))
b <- data.frame(date = as.Date("2024-01-02") + 0:40, close = 50 + 0:40)
AL <- function(call) sprintf("x <- %s; list(df = x, filled = attr(x, 'filled'))", call)
ALP <- function(call) sprintf("x = %s\nresult = dict(df=x, filled=x.attrs['filled'])", call)
rc("al_basic", AL("series_align(us = a, eu = b)"), ALP("DP.series_align(us=a, eu=b)"), list(a = a, b = b))
rc("al_maxgap2", AL("series_align(us = a, eu = b, max_gap = 2.5, fill = 'linear')"), ALP("DP.series_align(us=a, eu=b, max_gap=2.5, fill='linear')"), list(a = a, b = b))
rc("al_union", AL("series_align(us = a, eu = b, calendar = 'union', range = 'all')"),
   ALP("DP.series_align(us=a, eu=b, calendar='union', range='all')"), list(a = a, b = b))
rc("al_all_lin", AL("series_align(us = a, eu = b, range = 'all', fill = 'linear')"),
   ALP("DP.series_align(us=a, eu=b, range='all', fill='linear')"), list(a = a, b = b))
rc("al_none", AL("series_align(us = a, eu = b, range = 'all', fill = 'none')"),
   ALP("DP.series_align(us=a, eu=b, range='all', fill='none')"), list(a = a, b = b))
rc("al_err_name", "series_align(a, b)", "result = DP.series_align(a, b)", list(a = a, b = b))
rc("al_err_overlap", "series_align(us = a, eu = b, start = '2025-01-01')", "result = DP.series_align(us=a, eu=b, start='2025-01-01')", list(a = a, b = b))
rc("al_err_arg", "series_align(us = a, fill = 'spline')", "result = DP.series_align(us=a, fill='spline')", list(a = a))
rc("al_named", AL("series_align(x = c('2024-01-03' = 1, '2024-01-01' = 2, '2024-01-07' = 3), y = b)"),
   ALP("DP.series_align(x=pd.Series([1., 2, 3], index=['2024-01-03', '2024-01-01', '2024-01-07']), y=b)"), list(b = b))
rc("al_multi", AL("series_align(us = data.frame(date = b$date, A = b$close, B = rev(b$close), txt = 'x'), eu = a)"),
   ALP("DP.series_align(us=pd.DataFrame(dict(date=b['date'], A=b['close'], B=b['close'].to_numpy()[::-1], txt='x')), eu=a)"), list(a = a, b = b))
set.seed(1); tage <- seq.Date(as.Date("2022-01-03"), by = "day", length.out = 30)
roh <- data.frame(X = 1:30, Datum = tage, Kurs = 100 * cumprod(1 + rnorm(30, 3e-4, 0.01)))
rc("al_rownum1", AL("series_align(etf = roh[, c('X', 'Kurs')], b = roh[, c('Datum', 'Kurs')])"),
   ALP("DP.series_align(etf=roh[['X', 'Kurs']], b=roh[['Datum', 'Kurs']])"), list(roh = roh))
rc("al_firstcol", AL("series_align(etf = data.frame(tag = format(tage), Kurs = roh$Kurs))"),
   ALP("DP.series_align(etf=pd.DataFrame(dict(tag=[str(t) for t in tage], Kurs=roh['Kurs'])))"), list(roh = roh, tage = tage))
x20 <- data.frame(date = format(tage, "%d-%m-%Y"), value = roh$Kurs)
rc("al_baddate", "series_align(a = x20)", "result = DP.series_align(a=x20)", list(x20 = x20))
rc("al_dotdate", "series_align(a = transform(x20, date = format(tage, '%d.%m.%Y')))",
   "x20['date'] = [pd.Timestamp(t).strftime('%d.%m.%Y') for t in tage]\nresult = DP.series_align(a=x20)", list(x20 = x20, tage = tage))
rc("al_text", "series_align(a = data.frame(date = dft$date, Kurs = dft$kurs, Volumen = 1:60))",
   "result = DP.series_align(a=pd.DataFrame(dict(date=dft['date'], Kurs=dft['kurs'], Volumen=np.arange(1, 61))))", list(dft = dft))
rc("al_posix", AL("series_align(a = data.frame(date = as.POSIXct(format(tage), tz = 'Europe/Berlin'), value = roh$Kurs))"),
   ALP("DP.series_align(a=pd.DataFrame(dict(date=pd.Series(pd.to_datetime([str(t) for t in tage])).dt.tz_localize('Europe/Berlin'), value=roh['Kurs'])))"),
   list(roh = roh, tage = tage))
xd <- rbind(transform(roh[c(10, 3, 20), ], Kurs = Kurs * 1.05), roh)[, c("Datum", "Kurs")]
xd <- xd[c(5, 1, 3, 2, 4, 6:nrow(xd)), ]; xd$Datum[7] <- NA
set.seed(3); tdd <- td("2021-01-04", 60)
us <- data.frame(date = tdd, aktien = 100 * cumprod(1 + rnorm(length(tdd), 0, 0.01)), geld = 100)
rc("al_trading", AL("series_align(us = us)"), ALP("DP.series_align(us=us)"), list(us = us))
rc("al_trading_end", AL("series_align(A = us, end = '2021-02-13')"), ALP("DP.series_align(A=us, end='2021-02-13')"), list(us = us))
rc("al_nainside", AL("series_align(a = data.frame(date = a$date, v = c(1, NA, 3, NA, 5)), b = b, fill = 'linear', range = 'all')"),
   ALP("DP.series_align(a=pd.DataFrame(dict(date=a['date'], v=[1, simlev._r.fmt.NA_REAL, 3, simlev._r.fmt.NA_REAL, 5])), b=b, fill='linear', range='all')"), list(a = a, b = b))

# ── series_check ───────────────────────────────────────────────────────────
set.seed(1); n <- 400
d1 <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n), A = 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)))
d1$A[100] <- d1$A[100] * 1.5; d1$A[300:n] <- d1$A[300:n] / 2; d1$A[200:215] <- d1$A[200]
rc("cs_doc", "series_check(d)", "result = DP.series_check(d)", list(d = d1))
set.seed(1); n <- 600
p <- 100 * cumprod(1 + rnorm(n, 0, 0.01)); p[300:n] <- p[300:n] / 2; p[400] <- p[400] * 1.6; p[500:515] <- p[500]
d2 <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n), A = p, B = c(rep(NA, 20), 1:580 * 0.1 + 10))
d2$B[c(50, 60:62)] <- NA; d2$B[c(100, 300)] <- d2$B[c(100, 300)] * 3; d2$B[301] <- d2$B[301] * 3
rc("cs_multi", "series_check(d, jump = 15, stale = 5, revert = 0.5)", "result = DP.series_check(d, jump=15, stale=5, revert=0.5)", list(d = d2))
rc("cs_cols", "series_check(d, columns = 'B')", "result = DP.series_check(d, columns='B')", list(d = d2))
set.seed(1)
d3 <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 300))
d3$kurs <- 100 * cumprod(1 + rnorm(300, 3e-4, 0.01))
d3$zins <- c(seq(1, -0.5, length.out = 150), seq(-0.5, 2, length.out = 150))
rc("cs_neg", "series_check(d)", "result = DP.series_check(d)", list(d = d3))
d3b <- d3; d3b$zins <- NULL; d3b$kurs[50] <- -1
rc("cs_neg2", "series_check(d)", "result = DP.series_check(d)", list(d = d3b))
set.seed(1)
x28 <- data.frame(date = c(format(seq.Date(as.Date("2020-01-01"), by = "day", length.out = 50)), "", "2020/03/01", "x"), A = c(100 + cumsum(rnorm(50)), NA, 99, NA))
rc("cs_nadate", "series_check(x)", "result = DP.series_check(x)", list(x = x28))
dd4 <- data.frame(date = as.Date(c("2020-01-01", "2020-01-02", "2020-01-02", "2020-01-10", "2020-01-05", "2020-01-30", "2020-02-01")),
                  A = c(1, 1, 1, 1, 1, 1, 2), C = NA_real_)
rc("cs_dates", "series_check(d)", "result = DP.series_check(d)", list(d = dd4))
rc("cs_dates_c", "series_check(d, columns = c('A', 'C'))", "result = DP.series_check(d, columns=['A', 'C'])", list(d = dd4))
set.seed(9); n <- 300
d5 <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n), A = 100 * cumprod(1 + rnorm(n, 0, 0.03)))
d5$A[seq(10, 290, by = 9)] <- d5$A[seq(10, 290, by = 9)] * c(1.5, 0.6)
rc("cs_many", "series_check(d)", "result = DP.series_check(d)", list(d = d5))
d6 <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 10), A = 1:10 + 100)
rc("cs_clean", "series_check(d)", "result = DP.series_check(d)", list(d = d6))
rc("cs_split3", "series_check(data.frame(date = d6$date, A = c(90, 91, 92, 30.5, 31, 31.2, 31.3, 31.1, 93.3, 93)))",
   "result = DP.series_check(pd.DataFrame(dict(date=d6['date'], A=[90, 91, 92, 30.5, 31, 31.2, 31.3, 31.1, 93.3, 93])))", list(d6 = d6))
dna <- data.frame(date = as.Date("2020-01-01") + 0:4, C = NA_real_, A = c(1, 2, 3, 4, 5))
rc("cs_firstna", "series_check(d)", "result = DP.series_check(d)", list(d = dna))
rc("cs_onlyna", "series_check(d, columns = c('C', 'C'))", "result = DP.series_check(d, columns=['C', 'C'])", list(d = dna))
rc("cs_nocols", "series_check(d, columns = character(0))", "result = DP.series_check(d, columns=[])", list(d = dna))

# ── series_align_macro ────────────────────────────────────────────────────────────
cpi <- data.frame(date = seq.Date(as.Date("2019-01-01"), by = "month", length.out = 36), value = 100 * 1.003^(0:35))
dm <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 120))
rc("am_yoy", "series_align_macro(d, cpi, 'infl', lag = 45, transform = 'yoy')", "result = DP.series_align_macro(d, cpi, name='infl', lag=45, transform='yoy')", list(d = dm, cpi = cpi))
rc("am_month", "series_align_macro(d$date, cpi, lag = 1, lag_unit = 'month')", "result = DP.series_align_macro(d['date'], cpi, lag=1, lag_unit='month')", list(d = dm, cpi = cpi))
rc("am_mom", "series_align_macro(d, cpi, transform = 'mom', lag = 10.5)", "result = DP.series_align_macro(d, cpi, transform='mom', lag=10.5)", list(d = dm, cpi = cpi))
cpi48 <- data.frame(date = seq.Date(as.Date("2018-01-01"), by = "month", length.out = 48), value = 100 * 1.002^(0:47))
rc("am_gap", "list(series_align_macro(dts, cpi[-30, ], transform = 'yoy'), series_align_macro(dts, cpi, transform = 'yoy'), series_align_macro(as.Date('2020-07-15'), cpi[-30, ], transform = 'mom'))",
   "result = [DP.series_align_macro(dts, cpi.drop(index=29), transform='yoy'), DP.series_align_macro(dts, cpi, transform='yoy'), DP.series_align_macro(np.array(['2020-07-15'], dtype='datetime64[D]'), cpi.drop(index=29), transform='mom')]",
   list(dts = as.Date(c("2021-03-15", "2021-06-15")), cpi = cpi48))
m5 <- data.frame(date = as.Date(c("2023-12-31", "2024-01-31", "2024-02-29", "2024-03-31", "2024-04-30")), cpi = 1:5)
d5m <- data.frame(date = seq.Date(as.Date("2024-01-25"), as.Date("2024-06-05"), by = "day"))
rc("am_monthend", "series_align_macro(d, m, 'cpi', lag = 1, lag_unit = 'month')", "result = DP.series_align_macro(d, m, name='cpi', lag=1, lag_unit='month')", list(d = d5m, m = m5))
q <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "quarter", length.out = 20), gdp = 100 + (1:20)^1.3)
rc("am_q", "series_align_macro(d, q, 'g', transform = 'yoy', lag = 30)", "result = DP.series_align_macro(d, q, name='g', transform='yoy', lag=30)",
   list(d = data.frame(date = seq.Date(as.Date("2015-06-01"), by = "week", length.out = 200)), q = q))
rc("am_qmom", "series_align_macro(d$date, q, transform = 'mom')", "result = DP.series_align_macro(d['date'], q, transform='mom')",
   list(d = data.frame(date = seq.Date(as.Date("2015-06-01"), by = "week", length.out = 200)), q = q))
yy <- data.frame(date = seq.Date(as.Date("2000-07-01"), by = "year", length.out = 15), v = seq(1, 5, length.out = 15)^2)
rc("am_y", "series_align_macro(d$date, m, transform = 'yoy_diff')", "result = DP.series_align_macro(d['date'], m, transform='yoy_diff')",
   list(d = data.frame(date = seq.Date(as.Date("2001-01-01"), by = "month", length.out = 100)), m = yy))
wk <- data.frame(date = seq.Date(as.Date("2020-01-06"), by = "week", length.out = 120), v = sin(1:120) + 3)
rc("am_w", "series_align_macro(d$date, m, transform = 'yoy')", "result = DP.series_align_macro(d['date'], m, transform='yoy')",
   list(d = data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 900)), m = wk))
rc("am_wp", "series_align_macro(d$date, m, transform = 'yoy', periods = 12)", "result = DP.series_align_macro(d['date'], m, transform='yoy', periods=12)",
   list(d = data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 900)), m = wk))
rc("am_wp5", "series_align_macro(d$date, m, transform = 'yoy', periods = 5)", "result = DP.series_align_macro(d['date'], m, transform='yoy', periods=5)",
   list(d = data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 300)), m = wk))
rc("am_daily", "series_align_macro(d$date, m, transform = 'yoy', lag = 1)", "result = DP.series_align_macro(d['date'], m, transform='yoy', lag=1)",
   list(d = data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 400)),
        m = data.frame(date = seq.Date(as.Date("2019-01-01"), by = "day", length.out = 600), v = 1:600 / 7)))
rc("am_err", "series_align_macro(d, cpi, transform = 'abc')", "result = DP.series_align_macro(d, cpi, transform='abc')", list(d = dm, cpi = cpi))

# ── series_convert_currency ───────────────────────────────────────────────────────
dcc <- data.frame(date = as.Date("2024-01-01") + 0:3, A = c(110, 121, 132, 143), fx = c(1.1, 1.1, 1.2, 1.3))
rc("cc_col", "series_convert_currency(d, 'A', 'fx')", "result = DP.series_convert_currency(d, 'A', 'fx')", list(d = dcc))
rc("cc_mult", "series_convert_currency(d, 'A', 2, 'multiply', '_x')", "result = DP.series_convert_currency(d, 'A', 2, method='multiply', suffix='_x')", list(d = dcc))
rc("cc_named", "series_convert_currency(d, 'A', c('2024-01-02' = 1.2, '2023-12-01' = 1.0))",
   "result = DP.series_convert_currency(d, 'A', pd.Series([1.2, 1.0], index=['2024-01-02', '2023-12-01']))", list(d = dcc))
rc("cc_vec", "series_convert_currency(d, 'A', c(1, 2, 3, 4))", "result = DP.series_convert_currency(d, 'A', np.array([1., 2, 3, 4]))", list(d = dcc))
rc("cc_errfx", "series_convert_currency(d, 'A', fx = 0)", "result = DP.series_convert_currency(d, 'A', fx=0)", list(d = dcc))

# ── index_total_return ─────────────────────────────────────────────────────
rc("tri_div", "index_total_return(c(100, 100, 98, 99), dividends = c(0, 0, 2, 0), withholding = 15)",
   "result = DP.index_total_return(np.array([100., 100, 98, 99]), dividends=np.array([0., 0, 2, 0]), withholding=15)")
rc("tri_yield", "index_total_return(rep(100, 366), yield = 2, dates = seq.Date(as.Date('2021-01-01'), by = 'day', length.out = 366))",
   "result = DP.index_total_return(np.full(366, 100.), yield_=2, dates=np.datetime64('2021-01-01') + np.arange(366).astype('m8[D]'))")
set.seed(2); pp <- 100 * cumprod(1 + rnorm(200, 2e-4, 0.01)); pp[c(1, 5, 6, 100)] <- NA
divv <- rep(NA, 200); divv[c(50, 120, 190)] <- c(0.5, 0.7, 0.4)
rc("tri_ychr", "index_total_return(p, yield = c(1, 2), dates = format(td('2020-01-01', 280)))",
   "result = DP.index_total_return(p, yield_=np.array([1., 2]), dates=[str(x) for x in dts])", list(p = pp, dts = td("2020-01-01", 280)))

# ── series_deflate ────────────────────────────────────────────────────────────────
rc("df_col", "series_deflate(data.frame(date = d$date, A = d$A, cpi = c(100, 110, 121, 130)), 'A', 'cpi')",
   "result = DP.series_deflate(pd.DataFrame(dict(date=d['date'], A=d['A'], cpi=[100., 110, 121, 130])), 'A', 'cpi')", list(d = dcc))
cpi24 <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "month", length.out = 24), value = 100 * 1.01^(0:23))
ddf <- data.frame(date = seq.Date(as.Date("2019-11-01"), by = "day", length.out = 200), depot = 100, d2 = 1:200)
rc("df_macro", "d1 <- series_align_macro(d, cpi, 'cpi'); series_deflate(d1, c('depot', 'd2'), cpi = 'cpi', suffix = '_r')",
   "d1 = DP.series_align_macro(d, cpi, name='cpi'); result = DP.series_deflate(d1, ['depot', 'd2'], cpi='cpi', suffix='_r')", list(d = ddf, cpi = cpi24))
rc("df_dfcpi", "series_deflate(d, 'depot', cpi = cpi)", "result = DP.series_deflate(d, 'depot', cpi=cpi)", list(d = ddf, cpi = cpi24))
rc("df_base", "series_deflate(d, 'd2', cpi = cpi, base_date = '2020-03-17')", "result = DP.series_deflate(d, 'd2', cpi=cpi, base_date='2020-03-17')", list(d = ddf, cpi = cpi24))
rc("df_named", "series_deflate(d, 'd2', cpi = c('2020-01-01' = 100, '2020-02-15' = 101, '2020-04-01' = 103))",
   "result = DP.series_deflate(d, 'd2', cpi=pd.Series([100., 101, 103], index=['2020-01-01', '2020-02-15', '2020-04-01']))", list(d = ddf))
rc("df_vec", "series_deflate(d, 'd2', cpi = 100 + (1:200) / 10, base_date = as.Date('2020-12-31'))",
   "result = DP.series_deflate(d, 'd2', cpi=100 + np.arange(1, 201) / 10, base_date=np.datetime64('2020-12-31'))", list(d = ddf))
rc("cpilevel", "SimLev:::.cpi_level(cpi, d, d$date, 'cpi')", "result = DP._cpi_level(cpi, d, d['date'], 'cpi')", list(d = ddf, cpi = cpi24))

# ── series_splice ──────────────────────────────────────────────────────────
f1 <- data.frame(date = as.Date("2024-03-01") + 0:5, value = c(10, 11, 12, 12.5, 13, 14))
f2 <- data.frame(date = as.Date("2024-02-20") + 0:20, value = 200 + 0:20)
rc("sp_basic", "series_splice(fund = f1, proxy = f2)", "result = DP.series_splice(fund=f1, proxy=f2)", list(f1 = f1, f2 = f2))
proxy <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = 400))
proxy$value <- 100 * cumprod(1 + c(0, rep(0.001, 399)))
fonds <- proxy[proxy$date >= as.Date("2010-03-01"), ]; fonds$value <- fonds$value / 2
fonds <- fonds[!(fonds$date > as.Date("2010-06-01") & fonds$date < as.Date("2010-07-01")), ]
rc("sp_gap", "series_splice(fonds = fonds, proxy = proxy)", "result = DP.series_splice(fonds=fonds, proxy=proxy)", list(fonds = fonds, proxy = proxy))
tdx <- td("2020-01-01", 200)
p2 <- data.frame(date = tdx, value = 100 * 1.001^seq_along(tdx)); f2b <- p2[p2$date >= as.Date("2020-03-01"), ]
rc("sp_trading", "series_splice(f = f2b, p = p2)", "result = DP.series_splice(f=f2b, p=p2)", list(f2b = f2b, p2 = p2))
set.seed(1)
cal <- seq.Date(as.Date("2020-01-01"), by = "day", length.out = 120)
idx <- data.frame(date = cal, value = 100 * cumprod(1 + rnorm(120, 0, 0.01)))
etf <- idx[!format(cal, "%u") %in% c("6", "7") & cal >= as.Date("2020-02-01"), ]; etf$value <- etf$value / 2
e2 <- etf[!(etf$date > as.Date("2020-03-02") & etf$date < as.Date("2020-03-09")), ]
rc("sp_we", "series_splice(etf = etf, idx = idx)", "result = DP.series_splice(etf=etf, idx=idx)", list(etf = etf, idx = idx))
vv1 <- c(NA, NA, NA, 5, 5.5, NA, 6, 6.1); vv2 <- c(1, 1.1, NA, 1.2, 1.3, 1.25, 1.4, 1.5); vv3 <- c(2, 2.2, 2.3, 2.4, NA, 2.5, 2.6, 2.7)
rc("sp_vec", "series_splice(a = v1, b = v2, c = v3, dates = as.Date('2024-01-01') + 0:7)",
   "result = DP.series_splice(a=v1, b=v2, c=v3, dates=np.datetime64('2024-01-01') + np.arange(8).astype('m8[D]'))", list(v1 = vv1, v2 = vv2, v3 = vv3))
rc("sp_err4", "series_splice(f1, f2)", "result = DP.series_splice(f1, f2)", list(f1 = f1, f2 = f2))

# ── strategy_from_weights / portfolio_template ─────────────────────────────
rc("sw_doc", "strategy_from_weights(c(world = 0.6, bonds = 0.4), spread = c(world = 0.1, bonds = 0.05))",
   "result = DP.strategy_from_weights(pd.Series([0.6, 0.4], index=['world', 'bonds']), spread=pd.Series([0.1, 0.05], index=['world', 'bonds']))")
rc("sw_class", "strategy_from_weights(c(aktien = 0.7, gold = 0.3), asset_class = c(aktien = 'etf', gold = 'etc'), partial_exemption = c(aktien = 30, gold = 0), spread = 0.1)",
   "result = DP.strategy_from_weights({'aktien': 0.7, 'gold': 0.3}, asset_class={'aktien': 'etf', 'gold': 'etc'}, partial_exemption={'aktien': 30, 'gold': 0}, spread=0.1)")
rc("sw_one", "strategy_from_weights(c(aktien = 0.7, gold = 0.3), partial_exemption = c(aktien = 30), spread = 0.1)",
   "result = DP.strategy_from_weights({'aktien': 0.7, 'gold': 0.3}, partial_exemption={'aktien': 30}, spread=0.1)")
rc("sw_all", "strategy_from_weights(c(a = 0.5, b = 0.5), spread = 0.2, asset_class = 'etc', deliverable = TRUE)",
   "result = DP.strategy_from_weights({'a': 0.5, 'b': 0.5}, spread=0.2, asset_class='etc', deliverable=True)")
rc("sw_namedall", "strategy_from_weights(c(a = 0.5, b = 0.5), spread = c(x = 0.3))",
   "result = DP.strategy_from_weights({'a': 0.5, 'b': 0.5}, spread={'x': 0.3})")
rc("sw_na", "strategy_from_weights(c(a = 0.5, b = 0.5), spread = NA)",
   "result = DP.strategy_from_weights({'a': 0.5, 'b': 0.5}, spread=simlev._r.fmt.NA_REAL)")
rc("pt_perm", "portfolio_template('permanent', map = c(stocks = 'msci_world', long_bonds = 'bund_10y', cash = 'geldmarkt', gold = 'gold_eur'), spread = 0.1)",
   "result = DP.portfolio_template(name='permanent', map={'stocks': 'msci_world', 'long_bonds': 'bund_10y', 'cash': 'geldmarkt', 'gold': 'gold_eur'}, spread=0.1)")
rc("pt_partial", "portfolio_template('permanent', map = c(stocks = 'W'), spread = 0)",
   "result = DP.portfolio_template(name='permanent', map={'stocks': 'W'}, spread=0)")
for (tn in names(SimLev:::.portfolio_templates))
  rc(paste0("pt_", tn), sprintf("portfolio_template('%s', spread = 0.1)", tn), sprintf("result = DP.portfolio_template(name='%s', spread=0.1)", tn))
rc("pt_list", "portfolio_template()", "result = DP.portfolio_template()")

# ── bonds ──────────────────────────────────────────────────────────────────
db <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 3), y = c(2, 2, 3))
BI <- "b <- %s; list(b = as.numeric(b), duration = attr(b, 'duration'))"
BIP <- "b = %s\nresult = dict(b=np.asarray(b), duration=b.attrs['duration'])"
rc("bond_small", sprintf(BI, "index_bond(d, 'y', maturity = 10, coupon_frequency = 1)"),
   sprintf(BIP, "BO.index_bond(d, yield_='y', maturity=10, coupon_frequency=1)"), list(d = db))
set.seed(1); dbl <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 400)); dbl$y10 <- 2 + cumsum(rnorm(400, 0, 0.03))
dbl$y10[150:160] <- -0.0000000001 * (1:11); dbl$y10[161] <- 0
rc("bond_doc", sprintf(BI, "index_bond(d, 'y10', maturity = 10, coupon_frequency = 1)"),
   sprintf(BIP, "BO.index_bond(d, yield_='y10', maturity=10, coupon_frequency=1)"), list(d = dbl))
rc("bond_dur", sprintf(BI, "index_bond(d, 'y10', method = 'duration', maturity = 7, coupon_frequency = 2, start = 1)"),
   sprintf(BIP, "BO.index_bond(d, yield_='y10', method='duration', maturity=7, coupon_frequency=2, start=1)"), list(d = dbl))
rc("bond_df", sprintf(BI, "index_bond(d, data.frame(date = as.Date(c('2020-01-01', '2020-06-01')), v = c(1, 4)), maturity = 30)"),
   sprintf(BIP, "BO.index_bond(d, yield_=pd.DataFrame(dict(date=np.array(['2020-01-01', '2020-06-01'], dtype='datetime64[D]'), v=[1., 4])), maturity=30)"), list(d = dbl))
rc("bond_td", sprintf(BI, "index_bond(d, 2.5, method = 'dur')"),
   sprintf(BIP, "BO.index_bond(d, yield_=2.5, method='dur')"), list(d = data.frame(date = td("2020-01-01", 40))))
rc("bond_zero", sprintf(BI, "index_bond(z, 'y')"), sprintf(BIP, "BO.index_bond(z, yield_='y')"),
   list(z = data.frame(date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = 30), y = 0)))
dc <- data.frame(date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = 366), y = 3, x = 100)
rc("mm_col", "index_money_market(d, 'y')", "result = BO.index_money_market(d, 'y')", list(d = dc))
rc("mm_spread", "index_money_market(d, 3, spread = 1, basis = 365, start = 1)", "result = BO.index_money_market(d, 3, spread=1, basis=365, start=1)", list(d = dc))
rc("mm_df", "index_money_market(d, data.frame(date = as.Date(c('2020-12-01', '2021-06-01')), value = c(1, 2)))",
   "result = BO.index_money_market(d, pd.DataFrame(dict(date=np.array(['2020-12-01', '2021-06-01'], dtype='datetime64[D]'), value=[1., 2])))", list(d = dc))
rc("mm_named", "index_money_market(d, c('2020-01-01' = 0, '2021-01-01' = 2))",
   "result = BO.index_money_market(d, pd.Series([0., 2], index=['2020-01-01', '2021-01-01']))",
   list(d = data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 730))))
rc("mm_td", "index_money_market(d, 'r')", "result = BO.index_money_market(d, 'r')",
   list(d = data.frame(date = td("2020-01-01", 100), r = c(rep(1, 30), NA, rep(4, 41)))))
rc("mm_err", "index_money_market(d, 'zz')", "result = BO.index_money_market(d, 'zz')", list(d = dc))
rc("ch_basic", "index_currency_hedged(d, 'x', 3, 1)", "result = BO.index_currency_hedged(d, 'x', 3, 1)", list(d = dc))
set.seed(1); dh <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 730)); dh$sp500 <- 100 * cumprod(1 + rnorm(730, 3e-4, 0.01))
dh$sp500[c(1:3, 100, 400:402)] <- NA; dh$rf <- seq(5, 1, length.out = 730)
rc("ch_doc", "index_currency_hedged(d, 'sp500', domestic_rate = 3, foreign_rate = 'rf', cost = 0.1)",
   "result = BO.index_currency_hedged(d, 'sp500', domestic_rate=3, foreign_rate='rf', cost=0.1)", list(d = dh))
rc("ch_vec", "index_currency_hedged(d, d$sp500 * 2, c('2020-01-01' = 1, '2020-08-01' = 2), data.frame(date = as.Date('2020-01-01'), r = 0.5), basis = 365, start = 10)",
   "result = BO.index_currency_hedged(d, d['sp500'] * 2, pd.Series([1., 2], index=['2020-01-01', '2020-08-01']), pd.DataFrame(dict(date=np.array(['2020-01-01'], dtype='datetime64[D]'), r=[0.5])), basis=365, start=10)",
   list(d = dh))

# ── strategy_from_weights / portfolio_template mit Fonds-Wrapper je Asset ──
WR_R <- paste0("inner <- create_strategy(A = asset_config('etf', 'bnh', 0.6), B = asset_config('etf', 'bnh', 0.4))\n",
               "wb <- wrapper_config(inner, costs = funds_costs(0.95, 10))\n",
               "w2 <- wrapper_config(create_strategy(C = asset_config('etf', 'bnh', 1)), costs = funds_costs(0.2, 0))\n")
WR_P <- paste0("inner = simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=0.6), B=simlev.asset_config(asset_class='etf', trading='bnh', share=0.4))\n",
               "wb = simlev.wrapper_config(inner, costs=simlev.funds_costs(fee=0.95, performance_fee=10))\n",
               "w2 = simlev.wrapper_config(simlev.create_strategy(C=simlev.asset_config(asset_class='etf', trading='bnh', share=1)), costs=simlev.funds_costs(fee=0.2, performance_fee=0))\n")
WR_J <- paste0('inner = SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.6), "B" => SL.asset_config("etf", "bnh", 0.4))\n',
               'wb = SL.wrapper_config(inner; costs = SL.funds_costs(0.95, 10))\n',
               'w2 = SL.wrapper_config(SL.create_strategy("C" => SL.asset_config("etf", "bnh", 1)); costs = SL.funds_costs(0.2, 0))\n')
WRC <- list(
  sw_wr_all = list("strategy_from_weights(c(world = 0.6, bonds = 0.4), wrapper = wb)",
                   "result = DP.strategy_from_weights({'world': 0.6, 'bonds': 0.4}, wrapper=wb)",
                   'result = DP.strategy_from_weights(named("world" => 0.6, "bonds" => 0.4); wrapper = wb)',
                   "ein SimLevWrapperConfig gilt für alle Assets"),
  sw_wr_each = list("strategy_from_weights(c(world = 0.6, bonds = 0.3, gold = 0.1), asset_class = c(world = 'certificate', gold = 'etc'), spread = 0.1, wrapper = list(world = wb, bonds = w2))",
                    "result = DP.strategy_from_weights({'world': 0.6, 'bonds': 0.3, 'gold': 0.1}, asset_class={'world': 'certificate', 'gold': 'etc'}, spread=0.1, wrapper={'world': wb, 'bonds': w2})",
                    'result = DP.strategy_from_weights(named("world" => 0.6, "bonds" => 0.3, "gold" => 0.1); asset_class = named("world" => "certificate", "gold" => "etc"), spread = 0.1, wrapper = (world = wb, bonds = w2))',
                    "benannte Liste je Asset; gold ohne Wrapper"),
  sw_wr_one = list("strategy_from_weights(c(world = 0.6, bonds = 0.4), partial_exemption = c(world = 30), wrapper = list(bonds = w2))",
                   "result = DP.strategy_from_weights({'world': 0.6, 'bonds': 0.4}, partial_exemption={'world': 30}, wrapper={'bonds': w2})",
                   'result = DP.strategy_from_weights(named("world" => 0.6, "bonds" => 0.4); partial_exemption = named("world" => 30.0), wrapper = Dict("bonds" => w2))',
                   "ein Eintrag (Julia: Dict)"),
  sw_wr_null = list("strategy_from_weights(c(world = 0.6, bonds = 0.4), spread = 0.1, wrapper = NULL)",
                    "result = DP.strategy_from_weights({'world': 0.6, 'bonds': 0.4}, spread=0.1, wrapper=None)",
                    'result = DP.strategy_from_weights(named("world" => 0.6, "bonds" => 0.4); spread = 0.1, wrapper = nothing)',
                    "wrapper = NULL: ohne Wrapper"),
  pt_wr_all = list("portfolio_template('60_40', wrapper = wb)", "result = DP.portfolio_template(name='60_40', wrapper=wb)",
                   'result = DP.portfolio_template("60_40"; wrapper = wb)', NULL),
  pt_wr_map = list("portfolio_template('permanent', map = c(stocks = 'msci_world', gold = 'gold_eur'), spread = 0.1, wrapper = list(msci_world = wb, cash = w2))",
                   "result = DP.portfolio_template(name='permanent', map={'stocks': 'msci_world', 'gold': 'gold_eur'}, spread=0.1, wrapper={'msci_world': wb, 'cash': w2})",
                   'result = DP.portfolio_template("permanent"; map = named("stocks" => "msci_world", "gold" => "gold_eur"), spread = 0.1, wrapper = (msci_world = wb, cash = w2))',
                   "Namen nach map; Rolle cash ohne map-Eintrag"),
  sw_wr_err_name = list("strategy_from_weights(c(world = 0.6, bonds = 0.4), wrapper = list(world = wb, x = wb, y = w2))",
                        "result = DP.strategy_from_weights({'world': 0.6, 'bonds': 0.4}, wrapper={'world': wb, 'x': wb, 'y': w2})",
                        'result = DP.strategy_from_weights(named("world" => 0.6, "bonds" => 0.4); wrapper = (world = wb, x = wb, y = w2))', NULL),
  pt_wr_err_role = list("portfolio_template('60_40', map = c(stocks = 'A'), wrapper = list(stocks = wb))",
                        "result = DP.portfolio_template(name='60_40', map={'stocks': 'A'}, wrapper={'stocks': wb})",
                        'result = DP.portfolio_template("60_40"; map = named("stocks" => "A"), wrapper = (stocks = wb,))',
                        "Rollenname statt Name nach map"),
  sw_wr_err_elem = list("strategy_from_weights(c(world = 0.6, bonds = 0.4), wrapper = list(world = wb, bonds = inner))",
                        "result = DP.strategy_from_weights({'world': 0.6, 'bonds': 0.4}, wrapper={'world': wb, 'bonds': inner})",
                        'result = DP.strategy_from_weights(named("world" => 0.6, "bonds" => 0.4); wrapper = (world = wb, bonds = inner))', NULL),
  sw_wr_err_elem2 = list("strategy_from_weights(c(world = 0.6, bonds = 0.4), wrapper = list(world = 1))",
                         "result = DP.strategy_from_weights({'world': 0.6, 'bonds': 0.4}, wrapper={'world': 1})",
                         'result = DP.strategy_from_weights(named("world" => 0.6, "bonds" => 0.4); wrapper = (world = 1,))', NULL),
  sw_wr_err_type = list("strategy_from_weights(c(world = 0.6, bonds = 0.4), wrapper = 'wb')",
                        "result = DP.strategy_from_weights({'world': 0.6, 'bonds': 0.4}, wrapper='wb')",
                        'result = DP.strategy_from_weights(named("world" => 0.6, "bonds" => 0.4); wrapper = "wb")', NULL),
  sw_wr_err_unnamed = list("strategy_from_weights(c(world = 0.6, bonds = 0.4), wrapper = list(wb, w2))",
                           "result = DP.strategy_from_weights({'world': 0.6, 'bonds': 0.4}, wrapper=[wb, w2])",
                           'result = DP.strategy_from_weights(named("world" => 0.6, "bonds" => 0.4); wrapper = [wb, w2])', NULL),
  sw_wr_err_dup = list("strategy_from_weights(c(world = 0.6, bonds = 0.4), wrapper = list(world = wb, world = w2))",
                       "result = DP.strategy_from_weights({'world': 0.6, 'bonds': 0.4}, wrapper=pd.Series([wb, w2], index=['world', 'world'], dtype=object))",
                       'result = DP.strategy_from_weights(named("world" => 0.6, "bonds" => 0.4); wrapper = ["world" => wb, "world" => w2])', NULL),
  sw_wr_err_signal = list("strategy_from_weights(c(world = 0.6, bonds = 0.4), trading = c(world = 'signal'), signal_buy = 'b', signal_sell = 's', wrapper = list(world = wb))",
                          "result = DP.strategy_from_weights({'world': 0.6, 'bonds': 0.4}, trading={'world': 'signal'}, signal_buy='b', signal_sell='s', wrapper={'world': wb})",
                          'result = DP.strategy_from_weights(named("world" => 0.6, "bonds" => 0.4); trading = named("world" => "signal"), signal_buy = "b", signal_sell = "s", wrapper = (world = wb,))',
                          "wrapper und trading = 'signal' für dasselbe Asset: Meldung nennt das Asset"),
  pt_wr_err_signal = list("portfolio_template('60_40', trading = 'signal', signal_buy = 'b', signal_sell = 's', wrapper = wb)",
                          "result = DP.portfolio_template(name='60_40', trading='signal', signal_buy='b', signal_sell='s', wrapper=wb)",
                          'result = DP.portfolio_template("60_40"; trading = "signal", signal_buy = "b", signal_sell = "s", wrapper = wb)', NULL))
for (id in names(WRC)) {
  cs <- WRC[[id]]
  JL[[id]] <- paste0(WR_J, cs[[3]])
  rc(id, paste0(WR_R, cs[[1]]), paste0(WR_P, cs[[2]]), note = cs[[4]])
}
ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul backcast
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Referenzfälle für simlev.backcast (r/R/backcast.R).
ref_init("backcast")
P <- "from simlev import backcast as BC\n"
# ── Julia-Code je Fall (Feld jl; Eingaben als Variablen, siehe tests/lib/faelle.jl) ──
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
rc("rs_df", "SimLev:::.resolve_series(data.frame(date = as.Date(c('2020-01-03')), ter = 0.7), d, 'ter')",
   "result = BC._resolve_series(pd.DataFrame(dict(date=np.array(['2020-01-03'], dtype='datetime64[D]'), ter=[0.7])), d, 'ter')", list(d = dt10))
rc("rs_df2", "SimLev:::.resolve_series(data.frame(tag = c('2020-01-08', '2020-01-02'), wert = c(1, 2), x = 3), d, 'ter')",
   "result = BC._resolve_series(pd.DataFrame(dict(tag=['2020-01-08', '2020-01-02'], wert=[1., 2], x=3.)), d, 'ter')", list(d = dt10))
rc("rs_vec", "SimLev:::.resolve_series(1:10, d, 'ter')", "result = BC._resolve_series(np.arange(1, 11), d, 'ter')", list(d = dt10))
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
rc("bf_warn_spread", "backcast_fit(s, 'etf', 'idx', ter = 0.5, fit = c('drag', 'spread'), validate = FALSE)",
   "result = BC.backcast_fit(s, 'etf', 'idx', ter=0.5, fit=['drag', 'spread'], validate=False)", list(s = s2))
rc("bf_err_bounds3", "backcast_fit(s, 'etf', 'idx', bounds = list(beta = c(0.5, NA)))", "result = BC.backcast_fit(s, 'etf', 'idx', bounds={'beta': [0.5, simlev._r.fmt.NA_REAL]})", list(s = s2))
rc("bf_err_sort", "backcast_fit(s[c(2, 1, 3:20), ], 'etf', 'idx')", "result = BC.backcast_fit(s.iloc[[1, 0] + list(range(2, 20))], 'etf', 'idx')", list(s = s2))
rc("bf_err_model", "backcast_fit(s, 'etf', 'idx', model = 'gam')", "result = BC.backcast_fit(s, 'etf', 'idx', model='gam')", list(s = s2))

# ── backcast ───────────────────────────────────────────────────────────────
F2 <- sprintf("f <- backcast_fit(s, 'etf', 'idx', ter = %s, leverage = 2, rate = 'rate')", TER)
F2P <- sprintf("f = BC.backcast_fit(s, 'etf', 'idx', ter=%s, leverage=2, rate='rate')", TERP)
ATTR <- "list(bc = bc, params = attr(bc, 'params'), splice = attr(bc, 'splice_date'))"
ATTRP <- "result = dict(bc=bc, params=bc.attrs['params'], splice=bc.attrs['splice_date'])"
rc("bc_fit", paste0(F2, "; backcast(f)"), paste0(F2P, "; result = BC.backcast(fit=f)"), list(s = s2))
rc("bc_fit_attr", paste0(F2, "; bc <- backcast(f, params = list(drag = 0.5), fill = 'linear', rebase = 100); ", ATTR),
   paste0(F2P, "; bc = BC.backcast(fit=f, params={'drag': 0.5}, fill='linear', rebase=100)\n", ATTRP), list(s = s2))
rc("bc_model", paste0(F2, "; backcast(f, fill = 'model')"), paste0(F2P, "; result = BC.backcast(fit=f, fill='model')"), list(s = s2))
rc("bc_stine", paste0(F2, "; backcast(f, fill = 'stine', splice = '2006-08-15')"), paste0(F2P, "; result = BC.backcast(fit=f, fill='stine', splice='2006-08-15')"), list(s = s2))
rc("bc_none", paste0(F2, "; bc <- backcast(f, splice = 'none'); ", ATTR), paste0(F2P, "; bc = BC.backcast(fit=f, splice='none')\n", ATTRP), list(s = s2))
rc("bc_none_print", paste0(F2, "; backcast(f, splice = 'none')"), paste0(F2P, "; result = BC.backcast(fit=f, splice='none')"), list(s = s2))
rc("bc_otherdata", paste0(F2, "; s2 <- s[1:1000, ]; s2$etf[990:1000] <- NA; backcast(f, data = s2, fill = 'model')"),
   paste0(F2P, "; s2 = s.iloc[:1000].copy(); v = s2['etf'].to_numpy(dtype=float, copy=True); v[989:1000] = simlev._r.fmt.NA_REAL; s2['etf'] = v; result = BC.backcast(fit=f, data=s2, fill='model')"), list(s = s2))
rc("bc_linear", "f <- backcast_fit(s, 'etf', 'idx', ter = 0.2, model = 'linear'); backcast(f, rebase = 100)",
   "f = BC.backcast_fit(s, 'etf', 'idx', ter=0.2, model='linear'); result = BC.backcast(fit=f, rebase=100)", list(s = s1))
rc("bc_spline", "f <- backcast_fit(s, 'etf', 'idx', model = 'spline', fx = 'fx', validate = FALSE); backcast(f)",
   "f = BC.backcast_fit(s, 'etf', 'idx', model='spline', fx='fx', validate=False); result = BC.backcast(fit=f)", list(s = sp))
rc("bc_nofit", sprintf("backcast(NULL, data = s, product = 'etf', index = 'idx', ter = %s, leverage = 2, rate = 'rate', params = list(drag = 0.4), fill = 'model')", TER),
   sprintf("result = BC.backcast(fit=None, data=s, product='etf', index='idx', ter=%s, leverage=2, rate='rate', params={'drag': 0.4}, fill='model')", TERP), list(s = s2))
rc("bc_nofit_attr", "bc <- backcast(data = s, product = 'etf', index = 'idx', leverage = 2, rate = 2, ter = 0.6, splice = '2006-01-01', lag = 1, accrual = 'geometric', unknown = 5); list(bc = bc, params = attr(bc, 'params'), splice = attr(bc, 'splice_date'))",
   "bc = BC.backcast(data=s, product='etf', index='idx', leverage=2, rate=2, ter=0.6, splice='2006-01-01', lag=1, accrual='geometric', unknown=5)\nresult = dict(bc=bc, params=bc.attrs['params'], splice=bc.attrs['splice_date'])", list(s = s2))
rc("bc_noprod", "s$etf <- NA; backcast(data = s, product = 'etf', index = 'idx', fx = 'fx', index_fill = 'linear')",
   "s['etf'] = simlev._r.fmt.NA_REAL\nresult = BC.backcast(data=s, product='etf', index='idx', fx='fx', index_fill='linear')", list(s = sp))
rc("bc_lead", "s$idx[1:5] <- NA; backcast(data = s, product = 'etf', index = 'idx', rebase = 1)",
   "v = s['idx'].to_numpy(dtype=float, copy=True); v[0:5] = simlev._r.fmt.NA_REAL; s['idx'] = v\nresult = BC.backcast(data=s, product='etf', index='idx', rebase=1)", list(s = sp))
rc("bc_err_splice2", "backcast(data = s, product = 'etf', index = 'idx', splice = 'gestern')",
   "result = BC.backcast(data=s, product='etf', index='idx', splice='gestern')", list(s = s2))
rc("bc_err_fill", "backcast(data = s, product = 'etf', index = 'idx', fill = 'x')", "result = BC.backcast(data=s, product='etf', index='idx', fill='x')", list(s = s2))
ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul signals
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Referenzfälle für simlev.signals und simlev._signals_core (r/R/signals.R, .roll_mean_core, .roll_cov_core).
ref_init("signals")
P <- "from simlev import signals as SG\nfrom simlev import _signals_core as SC\n"
# ── Julia-Code je Fall (Feld jl; Eingaben als Variablen, siehe tests/lib/faelle.jl) ──
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
rc("core_cov", "SimLev:::.roll_cov_core(x, rev(x), 50L)", "result = SC.roll_cov_core(x, x[::-1], 50)", list(x = xc))
rc("core_cov_na", "SimLev:::.roll_cov_core(x, sqrt(x), 15L)", "with np.errstate(invalid='ignore'):\n    y = np.sqrt(x)\nresult = SC.roll_cov_core(x, y, 15)", list(x = xna))
rc("core_cov_edge", "list(SimLev:::.roll_cov_core(1:3 + 0, 1:4 + 0, 2L), SimLev:::.roll_cov_core(1:3 + 0, 3:1 + 0, 3L), SimLev:::.roll_cov_core(1:3 + 0, 3:1 + 0, 4L))",
   "result = [SC.roll_cov_core(np.arange(1, 4.), np.arange(1, 5.), 2), SC.roll_cov_core(np.arange(1, 4.), np.arange(3, 0, -1.), 3), SC.roll_cov_core(np.arange(1, 4.), np.arange(3, 0, -1.), 4)]")
rc("roll_mean", "SimLev:::.roll_mean(x, 50)", "result = SG._roll_mean(x, 50)", list(x = xc))
rc("roll_var", "SimLev:::.roll_var(x, 50)", "result = SG._roll_var(x, 50)", list(x = xc))
rc("roll_var_int", "SimLev:::.roll_var(1:30, 7.9)", "result = SG._roll_var(np.arange(1, 31), 7.9)")
rc("roll_cov", "SimLev:::.roll_cov(x, y, 30)", "result = SG._roll_cov(x, y, 30)", list(x = px, y = rev(px)))
rc("ema_int", "SimLev:::.ema(x, 10)", "result = SG._ema(x, 10)", list(x = px))
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
rc("cross_sma", "signal_crossover(x)", "result = SG.signal_crossover(x)", list(x = px))
rc("cross_ema", "signal_crossover(x, 20, 100, type = 'ema', band = 0.3, lag = 1)", "result = SG.signal_crossover(x, fast=20, slow=100, type='ema', band=0.3, lag=1)", list(x = px))
rc("cross_e", "signal_crossover(x, 20, 100, type = 'e')", "result = SG.signal_crossover(x, fast=20, slow=100, type='e')", list(x = px))
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
rc("vol_def", "signal_volatility(x)", "result = SG.signal_volatility(x)", list(x = px))
rc("vol_opts", "signal_volatility(x, 30, threshold = 14, band = 1, ppy = 252, lag = 1)", "result = SG.signal_volatility(x, n=30, threshold=14, band=1, ppy=252, lag=1)", list(x = px))
rc("vol_one", "signal_volatility(x, 1, threshold = 15)", "result = SG.signal_volatility(x, n=1, threshold=15)", list(x = px[1:50]))
rc("vol_na", "signal_volatility(x, 10, threshold = 15)", "result = SG.signal_volatility(x, n=10, threshold=15)", list(x = xna))
rc("vol_short", "signal_volatility(x, 20)", "result = SG.signal_volatility(x, n=20)", list(x = x10))
set.seed(2); xv <- 100 * cumprod(1 + rnorm(300, 0, 0.01))
rc("vol_test", "signal_volatility(x, 20, threshold = 1000)", "result = SG.signal_volatility(x, n=20, threshold=1000)", list(x = xv))
rc("comb_small", "signal_combine(list(buy = c(TRUE, TRUE), sell = c(FALSE, FALSE)), list(buy = c(TRUE, FALSE), sell = c(FALSE, TRUE)))",
   "result = SG.signal_combine(dict(buy=np.array([True, True]), sell=np.array([False, False])), dict(buy=np.array([True, False]), sell=np.array([False, True])))")
rc("comb_one", "signal_combine(signal_sma(x, 50))", "result = SG.signal_combine(SG.signal_sma(x, n=50))", list(x = px))
rc("comb_err_op", "signal_combine(signal_sma(x, 50), op = 'xor')", "result = SG.signal_combine(SG.signal_sma(x, n=50), op='xor')", list(x = px))
ref_done()

ref_schreiben()
