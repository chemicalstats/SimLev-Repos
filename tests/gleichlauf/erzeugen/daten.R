# tests/gleichlauf/erzeugen/daten.R – Bereich daten als Szenarien und Tabellen (seit 1.4.2; bis 1.4.1 Einzelfälle je Modul und Funktion).
# Datenaufbereitung (series_align, series_check, Makro- und Währungsreihen, Indizes, Splice, Portfolio-Vorlagen),
# Rückrechnung (backcast_fit, backcast) und Signale, Eingabeprüfungen.
#   gleichlauf  Szenarien: je Szenario ein Aufruf bzw. eine kurze Aufrufkette, die mehrere Ergebnisse zugleich prüft
#               (Teile; Name = bisherige Fallkennung). Feld note: "prüft: …"
#   fehler      je Funktion eine Tabelle "Eingabe -> Meldung" (jede Zeile ein eigener Aufruf)
#   ausgabe     print()/summary() als Tabelle
# Herkunft der Erwartung: R. Daten und Hilfen wie in tests/werkzeuge/breite/daten.R (Breitenprüfung mit allen bisherigen Fällen).
# Aufruf (Repo-Wurzel): LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript tests/gleichlauf/erzeugen/daten.R
# Ausgabe tests/{gleichlauf,fehler,ausgabe}/faelle/daten.jsonl.gz (Format: ref_tools.R, Szenarien: szenario_tools.R).
source("tests/gleichlauf/erzeugen/ref_tools.R"); source("tests/gleichlauf/erzeugen/szenario_tools.R")
ref_bereich("daten")
EIN <- list()   # Eingaben je bisherigem Fall (Momentaufnahme an der Stelle, an der der Fall im alten Generator stand)

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul data_prep
# ════════════════════════════════════════════════════════════════════════════════════════════════════
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
ss <- function(...) suppressMessages(...)
td <- function(from, n_cal) { cal <- seq.Date(as.Date(from), by = "day", length.out = n_cal); cal[!format(cal, "%u") %in% c("6", "7")] }
EIN[["data_prep/todate_err3"]] <- list()
EIN[["data_prep/todate_num"]] <- list()
EIN[["data_prep/todate_int"]] <- list()
EIN[["data_prep/todate_factor"]] <- list()
EIN[["data_prep/todate_posix"]] <- list()
# ── .num_text_cols / .num_text_stop ────────────────────────────────────────
set.seed(1); n <- 60
v <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
txt <- sub(".", ",", format(round(v, 2), nsmall = 2), fixed = TRUE)
dft <- data.frame(date = format(seq.Date(as.Date("2020-01-01"), by = "day", length.out = n)), kurs = txt,
                  name = rep(c("a", "b"), n / 2), datum2 = rep("01.02.2020", n), zahl = v, stringsAsFactors = FALSE)
# ── series_align ───────────────────────────────────────────────────────────
a <- data.frame(date = as.Date("2024-01-01") + c(0, 1, 2, 5, 30), value = c(100, 101, 102, 103, 110))
b <- data.frame(date = as.Date("2024-01-02") + 0:40, close = 50 + 0:40)
AL <- function(call) sprintf("x <- %s; list(df = x, filled = attr(x, 'filled'))", call)
ALP <- function(call) sprintf("x = %s\nresult = dict(df=x, filled=x.attrs['filled'])", call)
EIN[["data_prep/al_maxgap"]] <- list(a = a, b = b)
EIN[["data_prep/al_inter"]] <- list(a = a, b = b)
EIN[["data_prep/al_union_c"]] <- list(a = a, b = b)
EIN[["data_prep/al_startend"]] <- list(a = a, b = b)
EIN[["data_prep/al_err_none"]] <- list()
EIN[["data_prep/al_err_dup"]] <- list(a = a)
set.seed(1); tage <- seq.Date(as.Date("2022-01-03"), by = "day", length.out = 30)
roh <- data.frame(X = 1:30, Datum = tage, Kurs = 100 * cumprod(1 + rnorm(30, 3e-4, 0.01)))
EIN[["data_prep/al_rownum"]] <- list(roh = roh)
EIN[["data_prep/al_numdate"]] <- list(roh = roh)
x20 <- data.frame(date = format(tage, "%d-%m-%Y"), value = roh$Kurs)
EIN[["data_prep/al_factor"]] <- list(dft = dft)
EIN[["data_prep/al_nonum"]] <- list(dft = dft)
EIN[["data_prep/al_notdf"]] <- list()
xd <- rbind(transform(roh[c(10, 3, 20), ], Kurs = Kurs * 1.05), roh)[, c("Datum", "Kurs")]
xd <- xd[c(5, 1, 3, 2, 4, 6:nrow(xd)), ]; xd$Datum[7] <- NA
EIN[["data_prep/al_dups"]] <- list(xd = xd, b = b)
set.seed(3); tdd <- td("2021-01-04", 60)
us <- data.frame(date = tdd, aktien = 100 * cumprod(1 + rnorm(length(tdd), 0, 0.01)), geld = 100)
EIN[["data_prep/al_int"]] <- list(a = a, b = b)
# ── series_check ───────────────────────────────────────────────────────────
set.seed(1); n <- 400
d1 <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n), A = 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)))
d1$A[100] <- d1$A[100] * 1.5; d1$A[300:n] <- d1$A[300:n] / 2; d1$A[200:215] <- d1$A[200]
EIN[["data_prep/cs_doc"]] <- list(d = d1)
set.seed(1); n <- 600
p <- 100 * cumprod(1 + rnorm(n, 0, 0.01)); p[300:n] <- p[300:n] / 2; p[400] <- p[400] * 1.6; p[500:515] <- p[500]
d2 <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n), A = p, B = c(rep(NA, 20), 1:580 * 0.1 + 10))
d2$B[c(50, 60:62)] <- NA; d2$B[c(100, 300)] <- d2$B[c(100, 300)] * 3; d2$B[301] <- d2$B[301] * 3
EIN[["data_prep/cs_cols"]] <- list(d = d2)
set.seed(1)
d3 <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 300))
d3$kurs <- 100 * cumprod(1 + rnorm(300, 3e-4, 0.01))
d3$zins <- c(seq(1, -0.5, length.out = 150), seq(-0.5, 2, length.out = 150))
EIN[["data_prep/cs_neg"]] <- list(d = d3)
d3b <- d3; d3b$zins <- NULL; d3b$kurs[50] <- -1
set.seed(1)
x28 <- data.frame(date = c(format(seq.Date(as.Date("2020-01-01"), by = "day", length.out = 50)), "", "2020/03/01", "x"), A = c(100 + cumsum(rnorm(50)), NA, 99, NA))
EIN[["data_prep/cs_nadate"]] <- list(x = x28)
dd4 <- data.frame(date = as.Date(c("2020-01-01", "2020-01-02", "2020-01-02", "2020-01-10", "2020-01-05", "2020-01-30", "2020-02-01")),
                  A = c(1, 1, 1, 1, 1, 1, 2), C = NA_real_)
EIN[["data_prep/cs_dates"]] <- list(d = dd4)
set.seed(9); n <- 300
d5 <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n), A = 100 * cumprod(1 + rnorm(n, 0, 0.03)))
d5$A[seq(10, 290, by = 9)] <- d5$A[seq(10, 290, by = 9)] * c(1.5, 0.6)
EIN[["data_prep/cs_print_n"]] <- list(d = d5)
d6 <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 10), A = 1:10 + 100)
dna <- data.frame(date = as.Date("2020-01-01") + 0:4, C = NA_real_, A = c(1, 2, 3, 4, 5))
EIN[["data_prep/cs_firstna"]] <- list(d = dna)
EIN[["data_prep/cs_onlyna"]] <- list(d = dna)
EIN[["data_prep/cs_nocols"]] <- list(d = dna)
EIN[["data_prep/cs_err"]] <- list()
# ── series_align_macro ────────────────────────────────────────────────────────────
cpi <- data.frame(date = seq.Date(as.Date("2019-01-01"), by = "month", length.out = 36), value = 100 * 1.003^(0:35))
dm <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 120))
EIN[["data_prep/am_diff"]] <- list(d = dm, cpi = cpi)
EIN[["data_prep/am_yoyd"]] <- list(d = dm, cpi = cpi)
cpi48 <- data.frame(date = seq.Date(as.Date("2018-01-01"), by = "month", length.out = 48), value = 100 * 1.002^(0:47))
EIN[["data_prep/am_gap"]] <- list(dts = as.Date(c("2021-03-15", "2021-06-15")), cpi = cpi48)
m5 <- data.frame(date = as.Date(c("2023-12-31", "2024-01-31", "2024-02-29", "2024-03-31", "2024-04-30")), cpi = 1:5)
d5m <- data.frame(date = seq.Date(as.Date("2024-01-25"), as.Date("2024-06-05"), by = "day"))
q <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "quarter", length.out = 20), gdp = 100 + (1:20)^1.3)
yy <- data.frame(date = seq.Date(as.Date("2000-07-01"), by = "year", length.out = 15), v = seq(1, 5, length.out = 15)^2)
wk <- data.frame(date = seq.Date(as.Date("2020-01-06"), by = "week", length.out = 120), v = sin(1:120) + 3)
EIN[["data_prep/am_named"]] <- list(d = dm)
# ── series_convert_currency ───────────────────────────────────────────────────────
dcc <- data.frame(date = as.Date("2024-01-01") + 0:3, A = c(110, 121, 132, 143), fx = c(1.1, 1.1, 1.2, 1.3))
EIN[["data_prep/cc_df"]] <- list(d = dcc)
EIN[["data_prep/cc_errcol"]] <- list(d = dcc)
EIN[["data_prep/cc_errfx2"]] <- list(d = dcc)
EIN[["data_prep/cc_errfx3"]] <- list(d = dcc)
EIN[["data_prep/cc_errfx4"]] <- list(d = dcc)
EIN[["data_prep/cc_errfx5"]] <- list(d = dcc)
set.seed(2); pp <- 100 * cumprod(1 + rnorm(200, 2e-4, 0.01)); pp[c(1, 5, 6, 100)] <- NA
divv <- rep(NA, 200); divv[c(50, 120, 190)] <- c(0.5, 0.7, 0.4)
EIN[["data_prep/tri_full"]] <- list(p = pp, dv = divv, dts = td("2020-01-01", 280))
EIN[["data_prep/tri_err"]] <- list(dts = seq.Date(as.Date("2024-01-01"), by = "day", length.out = 6))
EIN[["data_prep/tri_err2"]] <- list(dts = seq.Date(as.Date("2024-01-01"), by = "day", length.out = 6))
EIN[["data_prep/tri_one"]] <- list()
cpi24 <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "month", length.out = 24), value = 100 * 1.01^(0:23))
ddf <- data.frame(date = seq.Date(as.Date("2019-11-01"), by = "day", length.out = 200), depot = 100, d2 = 1:200)
EIN[["data_prep/df_macro"]] <- list(d = ddf, cpi = cpi24)
EIN[["data_prep/df_errbase"]] <- list(d = ddf, cpi = cpi24)
EIN[["data_prep/df_errnone"]] <- list(d = ddf)
EIN[["data_prep/df_errcol"]] <- list(d = ddf)
# ── series_splice ──────────────────────────────────────────────────────────
f1 <- data.frame(date = as.Date("2024-03-01") + 0:5, value = c(10, 11, 12, 12.5, 13, 14))
f2 <- data.frame(date = as.Date("2024-02-20") + 0:20, value = 200 + 0:20)
proxy <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = 400))
proxy$value <- 100 * cumprod(1 + c(0, rep(0.001, 399)))
fonds <- proxy[proxy$date >= as.Date("2010-03-01"), ]; fonds$value <- fonds$value / 2
fonds <- fonds[!(fonds$date > as.Date("2010-06-01") & fonds$date < as.Date("2010-07-01")), ]
tdx <- td("2020-01-01", 200)
p2 <- data.frame(date = tdx, value = 100 * 1.001^seq_along(tdx)); f2b <- p2[p2$date >= as.Date("2020-03-01"), ]
set.seed(1)
cal <- seq.Date(as.Date("2020-01-01"), by = "day", length.out = 120)
idx <- data.frame(date = cal, value = 100 * cumprod(1 + rnorm(120, 0, 0.01)))
etf <- idx[!format(cal, "%u") %in% c("6", "7") & cal >= as.Date("2020-02-01"), ]; etf$value <- etf$value / 2
e2 <- etf[!(etf$date > as.Date("2020-03-02") & etf$date < as.Date("2020-03-09")), ]
EIN[["data_prep/sp_we2"]] <- list(etf = etf, e2 = e2, idx = idx)
vv1 <- c(NA, NA, NA, 5, 5.5, NA, 6, 6.1); vv2 <- c(1, 1.1, NA, 1.2, 1.3, 1.25, 1.4, 1.5); vv3 <- c(2, 2.2, 2.3, 2.4, NA, 2.5, 2.6, 2.7)
EIN[["data_prep/sp_vec2"]] <- list(v1 = vv1, v2 = vv2)
EIN[["data_prep/sp_err1"]] <- list(f1 = f1)
EIN[["data_prep/sp_err2"]] <- list()
EIN[["data_prep/sp_err3"]] <- list()
EIN[["data_prep/sw_namedall"]] <- list()
EIN[["data_prep/sw_err_sum"]] <- list()
EIN[["data_prep/sw_err_dup"]] <- list()
EIN[["data_prep/sw_err_pos"]] <- list()
EIN[["data_prep/sw_err_name"]] <- list()
EIN[["data_prep/sw_err_cfg"]] <- list()
for (tn in names(SimLev:::.portfolio_templates)) EIN[[paste0("data_prep/", paste0("pt_", tn))]] <- list()
EIN[["data_prep/pt_list"]] <- list()
EIN[["data_prep/pt_err1"]] <- list()
EIN[["data_prep/pt_err2"]] <- list()
EIN[["data_prep/pt_err3"]] <- list()
EIN[["data_prep/pt_err4"]] <- list()
EIN[["data_prep/pt_err5"]] <- list()
# ── bonds ──────────────────────────────────────────────────────────────────
db <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 3), y = c(2, 2, 3))
BI <- "b <- %s; list(b = as.numeric(b), duration = attr(b, 'duration'))"
BIP <- "b = %s\nresult = dict(b=np.asarray(b), duration=b.attrs['duration'])"
EIN[["data_prep/bond_small"]] <- list(d = db)
set.seed(1); dbl <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 400)); dbl$y10 <- 2 + cumsum(rnorm(400, 0, 0.03))
dbl$y10[150:160] <- -0.0000000001 * (1:11); dbl$y10[161] <- 0
EIN[["data_prep/bond_td"]] <- list(d = data.frame(date = td("2020-01-01", 40)))
dc <- data.frame(date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = 366), y = 3, x = 100)
EIN[["data_prep/mm_td"]] <- list(d = data.frame(date = td("2020-01-01", 100), r = c(rep(1, 30), NA, rep(4, 41))))
EIN[["data_prep/ch_basic"]] <- list(d = dc)
set.seed(1); dh <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 730)); dh$sp500 <- 100 * cumprod(1 + rnorm(730, 3e-4, 0.01))
dh$sp500[c(1:3, 100, 400:402)] <- NA; dh$rf <- seq(5, 1, length.out = 730)
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
    EIN[[paste0("data_prep/", id)]] <- list()
}

# Vorspann je Szenario bzw. Tabellenzeile (gemeinsame Objekte des Moduls)
VOR <- list(r = r"()",
            py = r"(from simlev import data_prep as DP, bonds as BO)",
            jl = r"(const DP = SL.DataPrep; const BO = SL.Bonds)")

ref_init("data_prep", gruppe = "gleichlauf")
SZ("datum_umwandeln", ".to_date aus Faktor und POSIXct (Zeitzone)", vor = VOR, teile = list(
  todate_factor = teil(
    r"(SimLev:::.to_date(factor(c('2020-01-02', '2020-01-01', '2020-01-02'))))",
    r"(result = DP._to_date(pd.Categorical(['2020-01-02', '2020-01-01', '2020-01-02'])))",
    r"(result = DP._to_date(["2020-01-02", "2020-01-01", "2020-01-02"]))", inp = ein("data_prep/todate_factor", c())),
  todate_posix = teil(
    r"(SimLev:::.to_date(as.POSIXct(c('2020-01-01 00:30', '2020-06-30 23:59'), tz = 'Europe/Berlin')))",
    r"(result = DP._to_date(pd.Series(pd.to_datetime(['2020-01-01 00:30', '2020-06-30 23:59'])).dt.tz_localize('Europe/Berlin')))",
    r"(result = DP._to_date([DateTime(2020, 1, 1, 0, 30), DateTime(2020, 6, 30, 23, 59)]))", inp = ein("data_prep/todate_posix", c()))))
SZ("reihen_ausrichten", "series_align mit max_gap, Kalender intersect bzw. union, Start und Ende, Zeilennummern statt Datum, Ganzzahlen", vor = VOR, teile = list(
  al_maxgap = teil(
    r"(x <- series_align(us = a, eu = b, max_gap = 10); list(df = x, filled = attr(x, 'filled')))",
    r"(x = DP.series_align(us=a, eu=b, max_gap=10)
result = dict(df=x, filled=x.attrs['filled']))",
    r"(x = DP.series_align(us = a, eu = b, max_gap = 10)
result = RList("df" => x, "filled" => attrs(x)["filled"]))", inp = ein("data_prep/al_maxgap", c("a", "b"))),
  al_inter = teil(
    r"(x <- series_align(us = a, eu = b, calendar = 'intersect', range = 'all'); list(df = x, filled = attr(x, 'filled')))",
    r"(x = DP.series_align(us=a, eu=b, calendar='intersect', range='all')
result = dict(df=x, filled=x.attrs['filled']))",
    r"(x = DP.series_align(us = a, eu = b, calendar = "intersect", range = "all")
result = RList("df" => x, "filled" => attrs(x)["filled"]))", inp = ein("data_prep/al_inter", c("a", "b"))),
  al_union_c = teil(
    r"(x <- series_align(us = a, eu = b, calendar = 'uni'); list(df = x, filled = attr(x, 'filled')))",
    r"(x = DP.series_align(us=a, eu=b, calendar='uni')
result = dict(df=x, filled=x.attrs['filled']))",
    r"(x = DP.series_align(us = a, eu = b, calendar = "uni")
result = RList("df" => x, "filled" => attrs(x)["filled"]))", inp = ein("data_prep/al_union_c", c("a", "b"))),
  al_startend = teil(
    r"(x <- series_align(us = a, eu = b, range = 'all', start = '2024-01-03', end = as.Date('2024-01-20')); list(df = x, filled = attr(x, 'filled')))",
    r"(x = DP.series_align(us=a, eu=b, range='all', start='2024-01-03', end=np.datetime64('2024-01-20'))
result = dict(df=x, filled=x.attrs['filled']))",
    r"(x = DP.series_align(us = a, eu = b, range = "all", start = "2024-01-03", end_ = Date(2024, 1, 20))
result = RList("df" => x, "filled" => attrs(x)["filled"]))", inp = ein("data_prep/al_startend", c("a", "b"))),
  al_rownum = teil(
    r"(x <- series_align(etf = roh); list(df = x, filled = attr(x, 'filled')))",
    r"(x = DP.series_align(etf=roh)
result = dict(df=x, filled=x.attrs['filled']))",
    r"(x = DP.series_align(etf = roh)
result = RList("df" => x, "filled" => attrs(x)["filled"]))", inp = ein("data_prep/al_rownum", c("roh"))),
  al_int = teil(
    r"(x <- series_align(a = data.frame(date = a$date, v = c(1L, NA, 3L, 4L, 5L)), b = b); list(df = x, filled = attr(x, 'filled')))",
    r"(x = DP.series_align(a=pd.DataFrame(dict(date=a['date'], v=[1, simlev._r.fmt.NA_REAL, 3, 4, 5])), b=b)
result = dict(df=x, filled=x.attrs['filled']))",
    r"(x = DP.series_align(a = RFrame("date" => a.date, "v" => [1, missing, 3, 4, 5]), b = b)
result = RList("df" => x, "filled" => attrs(x)["filled"]))", inp = ein("data_prep/al_int", c("a", "b")))))
# Beispielreihe (Sprung, Split, Stillstand) mit einer Spalte nur aus NA vorn und einer Zinsreihe mit negativen Werten: ein Aufruf
dk <- local({ x <- EIN[["data_prep/cs_doc"]]$d; data.frame(date = x$date, C = NA_real_, A = x$A, zins = c(seq(1, -0.5, length.out = 200), seq(-0.5, 2, length.out = 200))) })
SZ("reihen_pruefen", "series_check: Beispiel mit negativen Werten und einer Spalte nur aus NA in einem Aufruf, Spaltenwahl, NA-Datum, Datumsfehler, nur NA, keine Spalten", vor = VOR, teile = list(
  cs_doc_neg_firstna = teil(
    r"(series_check(dk))",
    r"(result = DP.series_check(dk))",
    r"(result = DP.series_check(dk))", druck = TRUE, inp = list(dk = dk)),
  cs_cols = teil(
    r"(series_check(d, columns = 'B'))",
    r"(result = DP.series_check(d, columns='B'))",
    r"(result = DP.series_check(d; columns = "B"))", druck = TRUE, inp = ein("data_prep/cs_cols", c("d"))),
  cs_nadate = teil(
    r"(series_check(x))",
    r"(result = DP.series_check(x))",
    r"(result = DP.series_check(x))", druck = TRUE, inp = ein("data_prep/cs_nadate", c("x"))),
  cs_dates = teil(
    r"(series_check(d))",
    r"(result = DP.series_check(d))",
    r"(result = DP.series_check(d))", druck = TRUE, inp = ein("data_prep/cs_dates", c("d"))),
  cs_onlyna = teil(
    r"(series_check(d, columns = c('C', 'C')))",
    r"(result = DP.series_check(d, columns=['C', 'C']))",
    r"(result = DP.series_check(d; columns = ["C", "C"]))", druck = TRUE, inp = ein("data_prep/cs_onlyna", c("d"))),
  cs_nocols = teil(
    r"(series_check(d, columns = character(0)))",
    r"(result = DP.series_check(d, columns=[]))",
    r"(result = DP.series_check(d; columns = String[]))", druck = TRUE, inp = ein("data_prep/cs_nocols", c("d")))))
SZ("makroreihen_und_deflation", "series_align_macro (diff, yoy_diff mit Verzögerung, Lücken, benannter Vektor) und series_deflate", vor = VOR, teile = list(
  am_diff = teil(
    r"(series_align_macro(d$date, cpi, transform = 'diff'))",
    r"(result = DP.series_align_macro(d['date'], cpi, transform='diff'))",
    r"(result = DP.series_align_macro(d.date, cpi; transform = "diff"))", inp = ein("data_prep/am_diff", c("d", "cpi"))),
  am_yoyd = teil(
    r"(series_align_macro(d, cpi, 'x', transform = 'yoy_diff', lag = 2, lag_unit = 'month'))",
    r"(result = DP.series_align_macro(d, cpi, name='x', transform='yoy_diff', lag=2, lag_unit='month'))",
    r"(result = DP.series_align_macro(d, cpi; name = "x", transform = "yoy_diff", lag = 2, lag_unit = "month"))", inp = ein("data_prep/am_yoyd", c("d", "cpi"))),
  am_gap = teil(
    r"(list(series_align_macro(dts, cpi[-30, ], transform = 'yoy'), series_align_macro(dts, cpi, transform = 'yoy'), series_align_macro(as.Date('2020-07-15'), cpi[-30, ], transform = 'mom')))",
    r"(result = [DP.series_align_macro(dts, cpi.drop(index=29), transform='yoy'), DP.series_align_macro(dts, cpi, transform='yoy'), DP.series_align_macro(np.array(['2020-07-15'], dtype='datetime64[D]'), cpi.drop(index=29), transform='mom')])",
    r"(c29 = rows(cpi, setdiff(1:nrow(cpi), 30))
result = [DP.series_align_macro(dts, c29; transform = "yoy"), DP.series_align_macro(dts, cpi; transform = "yoy"), DP.series_align_macro(Date(2020, 7, 15), c29; transform = "mom")])", inp = ein("data_prep/am_gap", c("dts", "cpi"))),
  am_named = teil(
    r"(series_align_macro(d$date, c('2020-01-15' = 1, '2020-03-01' = 2, '2020-02-01' = 3)))",
    r"(result = DP.series_align_macro(d['date'], pd.Series([1., 2, 3], index=['2020-01-15', '2020-03-01', '2020-02-01'])))",
    r"(result = DP.series_align_macro(d.date, named("2020-01-15" => 1.0, "2020-03-01" => 2.0, "2020-02-01" => 3.0)))", inp = ein("data_prep/am_named", c("d"))),
  df_macro = teil(
    r"(d1 <- series_align_macro(d, cpi, 'cpi'); series_deflate(d1, c('depot', 'd2'), cpi = 'cpi', suffix = '_r'))",
    r"(d1 = DP.series_align_macro(d, cpi, name='cpi'); result = DP.series_deflate(d1, ['depot', 'd2'], cpi='cpi', suffix='_r'))",
    r"(d1 = DP.series_align_macro(d, cpi; name = "cpi")
result = DP.series_deflate(d1, ["depot", "d2"], "cpi"; suffix = "_r"))", inp = ein("data_prep/df_macro", c("d", "cpi")))))
SZ("waehrung_und_indizes", "series_convert_currency, index_total_return (voll und Einzelwert), index_bond, index_money_market, index_currency_hedged", vor = VOR, teile = list(
  cc_df = teil(
    r"(series_convert_currency(d, c('A', 'fx'), fx = data.frame(date = as.Date(c('2024-01-03', '2024-01-02')), value = c(1.05, 1.1)), suffix = '_eur'))",
    r"(result = DP.series_convert_currency(d, ['A', 'fx'], fx=pd.DataFrame(dict(date=np.array(['2024-01-03', '2024-01-02'], dtype='datetime64[D]'), value=[1.05, 1.1])), suffix='_eur'))",
    r"(result = DP.series_convert_currency(d, ["A", "fx"], RFrame("date" => Date.(["2024-01-03", "2024-01-02"]), "value" => [1.05, 1.1]); suffix = "_eur"))", inp = ein("data_prep/cc_df", c("d"))),
  tri_full = teil(
    r"(index_total_return(p, dividends = dv, yield = seq(1, 3, length.out = 200), withholding = 26.375, dates = td('2020-01-01', 280), start = 1000))",
    r"(result = DP.index_total_return(p, dividends=dv, **{'yield': np.linspace(1, 3, 200)}, withholding=26.375, dates=dts, start=1000))",
    r"(result = DP.index_total_return(p; dividends = dv, yield = vcat(1.0, 1.0 .+ collect(1:198) .* (2 / 199), 3.0), withholding = 26.375, dates = dts, start = 1000))", inp = ein("data_prep/tri_full", c("p", "dv", "dts"))),
  tri_one = teil(
    r"(index_total_return(5))",
    r"(result = DP.index_total_return(5.))",
    r"(result = DP.index_total_return(5.0))", inp = ein("data_prep/tri_one", c())),
  bond_small = teil(
    r"(b <- index_bond(d, 'y', maturity = 10, coupon_frequency = 1); list(b = as.numeric(b), duration = attr(b, 'duration')))",
    r"(b = BO.index_bond(d, yield_='y', maturity=10, coupon_frequency=1)
result = dict(b=np.asarray(b), duration=b.attrs['duration']))",
    r"(b = BO.index_bond(d, "y"; maturity = 10, coupon_frequency = 1)
result = RList("b" => b.values, "duration" => attrs(b)["duration"]))", inp = ein("data_prep/bond_small", c("d"))),
  bond_td = teil(
    r"(b <- index_bond(d, 2.5, method = 'dur'); list(b = as.numeric(b), duration = attr(b, 'duration')))",
    r"(b = BO.index_bond(d, yield_=2.5, method='dur')
result = dict(b=np.asarray(b), duration=b.attrs['duration']))",
    r"(b = BO.index_bond(d, 2.5; method = "dur")
result = RList("b" => b.values, "duration" => attrs(b)["duration"]))", inp = ein("data_prep/bond_td", c("d"))),
  mm_td = teil(
    r"(index_money_market(d, 'r'))",
    r"(result = BO.index_money_market(d, 'r'))",
    r"(result = BO.index_money_market(d, "r"))", inp = ein("data_prep/mm_td", c("d"))),
  ch_basic = teil(
    r"(index_currency_hedged(d, 'x', 3, 1))",
    r"(result = BO.index_currency_hedged(d, 'x', 3, 1))",
    r"(result = BO.index_currency_hedged(d, "x", 3, 1))", inp = ein("data_prep/ch_basic", c("d")))))
SZ("reihen_verketten", "series_splice mit Wochenenden und Vektoren", vor = VOR, teile = list(
  sp_we2 = teil(
    r"(series_splice(etf = e2, idx = idx, other = etf[etf$date > as.Date('2020-03-04'), ]))",
    r"(result = DP.series_splice(etf=e2, idx=idx, other=etf[etf['date'] > np.datetime64('2020-03-04')]))",
    r"(result = DP.series_splice(etf = e2, idx = idx, other = rows(etf, etf.date .> Date(2020, 3, 4))))", inp = ein("data_prep/sp_we2", c("etf", "e2", "idx"))),
  sp_vec2 = teil(
    r"(series_splice(a = v1, b = v2, dates = format(as.Date('2024-01-01') + 0:7)))",
    r"(result = DP.series_splice(a=v1, b=v2, dates=[str(np.datetime64('2024-01-01') + np.timedelta64(i, 'D')) for i in range(8)]))",
    r"(result = DP.series_splice(a = v1, b = v2, dates = string.(Date(2024, 1, 1) .+ Day.(0:7))))", inp = ein("data_prep/sp_vec2", c("v1", "v2")))))
SZ("strategie_aus_gewichten", "strategy_from_weights mit benannten Werten und Wrapper (ein Eintrag, NULL), portfolio_template", vor = VOR, teile = list(
  sw_namedall = teil(
    r"(strategy_from_weights(c(a = 0.5, b = 0.5), spread = c(x = 0.3)))",
    r"(result = DP.strategy_from_weights({'a': 0.5, 'b': 0.5}, spread={'x': 0.3}))",
    r"(result = DP.strategy_from_weights(named("a" => 0.5, "b" => 0.5); spread = named("x" => 0.3)))", druck = TRUE, inp = ein("data_prep/sw_namedall", c())),
  sw_wr_one = teil(
    r"(inner <- create_strategy(A = asset_config('etf', 'bnh', 0.6), B = asset_config('etf', 'bnh', 0.4))
wb <- wrapper_config(inner, costs = funds_costs(0.95, 10))
w2 <- wrapper_config(create_strategy(C = asset_config('etf', 'bnh', 1)), costs = funds_costs(0.2, 0))
strategy_from_weights(c(world = 0.6, bonds = 0.4), partial_exemption = c(world = 30), wrapper = list(bonds = w2)))",
    r"(inner = simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=0.6), B=simlev.asset_config(asset_class='etf', trading='bnh', share=0.4))
wb = simlev.wrapper_config(inner, costs=simlev.funds_costs(fee=0.95, performance_fee=10))
w2 = simlev.wrapper_config(simlev.create_strategy(C=simlev.asset_config(asset_class='etf', trading='bnh', share=1)), costs=simlev.funds_costs(fee=0.2, performance_fee=0))
result = DP.strategy_from_weights({'world': 0.6, 'bonds': 0.4}, partial_exemption={'world': 30}, wrapper={'bonds': w2}))",
    r"(inner = SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.6), "B" => SL.asset_config("etf", "bnh", 0.4))
wb = SL.wrapper_config(inner; costs = SL.funds_costs(0.95, 10))
w2 = SL.wrapper_config(SL.create_strategy("C" => SL.asset_config("etf", "bnh", 1)); costs = SL.funds_costs(0.2, 0))
result = DP.strategy_from_weights(named("world" => 0.6, "bonds" => 0.4); partial_exemption = named("world" => 30.0), wrapper = Dict("bonds" => w2)))", druck = TRUE, inp = ein("data_prep/sw_wr_one", c())),
  sw_wr_null = teil(
    r"(inner <- create_strategy(A = asset_config('etf', 'bnh', 0.6), B = asset_config('etf', 'bnh', 0.4))
wb <- wrapper_config(inner, costs = funds_costs(0.95, 10))
w2 <- wrapper_config(create_strategy(C = asset_config('etf', 'bnh', 1)), costs = funds_costs(0.2, 0))
strategy_from_weights(c(world = 0.6, bonds = 0.4), spread = 0.1, wrapper = NULL))",
    r"(inner = simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=0.6), B=simlev.asset_config(asset_class='etf', trading='bnh', share=0.4))
wb = simlev.wrapper_config(inner, costs=simlev.funds_costs(fee=0.95, performance_fee=10))
w2 = simlev.wrapper_config(simlev.create_strategy(C=simlev.asset_config(asset_class='etf', trading='bnh', share=1)), costs=simlev.funds_costs(fee=0.2, performance_fee=0))
result = DP.strategy_from_weights({'world': 0.6, 'bonds': 0.4}, spread=0.1, wrapper=None))",
    r"(inner = SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.6), "B" => SL.asset_config("etf", "bnh", 0.4))
wb = SL.wrapper_config(inner; costs = SL.funds_costs(0.95, 10))
w2 = SL.wrapper_config(SL.create_strategy("C" => SL.asset_config("etf", "bnh", 1)); costs = SL.funds_costs(0.2, 0))
result = DP.strategy_from_weights(named("world" => 0.6, "bonds" => 0.4); spread = 0.1, wrapper = nothing))", druck = TRUE, inp = ein("data_prep/sw_wr_null", c())),
  pt_list = teil(
    r"(portfolio_template())",
    r"(result = DP.portfolio_template())",
    r"(result = DP.portfolio_template())", inp = ein("data_prep/pt_list", c()))))
ref_done()

ref_init("data_prep", gruppe = "fehler")
TB(".to_date", "Meldungen und Warnungen von .to_date je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("todate_err3",
    r"(SimLev:::.to_date(c('2020-01-01', '2021-02-30', '2021-13-01'), 'feld'))",
    r"(result = DP._to_date(['2020-01-01', '2021-02-30', '2021-13-01'], 'feld'))",
    r"(result = DP._to_date(["2020-01-01", "2021-02-30", "2021-13-01"], "feld"))", inp = ein("data_prep/todate_err3", c())),
  zeile("todate_num",
    r"(SimLev:::.to_date(c(18000.5, 1), 'd'))",
    r"(result = DP._to_date(np.array([18000.5, 1]), 'd'))",
    r"(result = DP._to_date([18000.5, 1], "d"))", inp = ein("data_prep/todate_num", c())),
  zeile("todate_int",
    r"(SimLev:::.to_date(5L))",
    r"(result = DP._to_date(5))",
    r"(result = DP._to_date(5))", inp = ein("data_prep/todate_int", c()))))
TB("series_align", "Meldungen und Warnungen von series_align je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("al_err_none",
    r"(series_align())",
    r"(result = DP.series_align())",
    r"(result = DP.series_align())", inp = ein("data_prep/al_err_none", c())),
  zeile("al_err_dup",
    r"(series_align(us = data.frame(date = a$date, A = 1:5, B = 2:6), eu = data.frame(date = a$date, A = 1:5, C = 1)))",
    r"(result = DP.series_align(us=pd.DataFrame(dict(date=a['date'], A=np.arange(1, 6), B=np.arange(2, 7))), eu=pd.DataFrame(dict(date=a['date'], A=np.arange(1, 6), C=1.0))))",
    r"(result = DP.series_align(us = RFrame("date" => a.date, "A" => collect(1:5), "B" => collect(2:6)), eu = RFrame("date" => a.date, "A" => collect(1:5), "C" => fill(1.0, 5))))", inp = ein("data_prep/al_err_dup", c("a"))),
  zeile("al_numdate",
    r"(series_align(etf = data.frame(X = 1:30, Kurs = roh$Kurs)))",
    r"(result = DP.series_align(etf=pd.DataFrame(dict(X=np.arange(1, 31), Kurs=roh['Kurs']))))",
    r"(result = DP.series_align(etf = RFrame("X" => collect(1:30), "Kurs" => roh.Kurs)))", inp = ein("data_prep/al_numdate", c("roh"))),
  zeile("al_factor",
    r"(series_align(a = data.frame(date = dft$date, Kurs = factor(dft$kurs))))",
    r"(result = DP.series_align(a=pd.DataFrame(dict(date=dft['date'], Kurs=pd.Categorical(dft['kurs'])))))",
    r"(result = DP.series_align(a = RFrame("date" => dft.date, "Kurs" => dft.kurs)))", inp = ein("data_prep/al_factor", c("dft"))),
  zeile("al_nonum",
    r"(series_align(a = data.frame(date = dft$date, n = dft$name)))",
    r"(result = DP.series_align(a=pd.DataFrame(dict(date=dft['date'], n=dft['name']))))",
    r"(result = DP.series_align(a = RFrame("date" => dft.date, "n" => dft.name)))", inp = ein("data_prep/al_nonum", c("dft"))),
  zeile("al_notdf",
    r"(series_align(a = 1:3))",
    r"(result = DP.series_align(a=np.arange(1, 4)))",
    r"(result = DP.series_align(a = collect(1:3)))", inp = ein("data_prep/al_notdf", c())),
  zeile("al_dups",
    r"(x <- series_align(v = xd, w = b); list(df = x, filled = attr(x, 'filled')))",
    r"(x = DP.series_align(v=xd, w=b)
result = dict(df=x, filled=x.attrs['filled']))",
    r"(x = DP.series_align(v = xd, w = b)
result = RList("df" => x, "filled" => attrs(x)["filled"]))", inp = ein("data_prep/al_dups", c("xd", "b")))))
TB("series_check", "Meldungen und Warnungen von series_check je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("cs_err",
    r"(series_check(data.frame(x = 1)))",
    r"(result = DP.series_check(pd.DataFrame(dict(x=[1.]))))",
    r"(result = DP.series_check(RFrame("x" => [1.0])))", inp = ein("data_prep/cs_err", c()))))
TB("series_convert_currency", "Meldungen und Warnungen von series_convert_currency je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("cc_errcol",
    r"(series_convert_currency(d, c('USD', 'A', 'x'), fx = 'fx'))",
    r"(result = DP.series_convert_currency(d, ['USD', 'A', 'x'], fx='fx'))",
    r"(result = DP.series_convert_currency(d, ["USD", "A", "x"], "fx"))", inp = ein("data_prep/cc_errcol", c("d"))),
  zeile("cc_errfx2",
    r"(series_convert_currency(d, 'A', fx = c(1, -2.5, NA, 1)))",
    r"(result = DP.series_convert_currency(d, 'A', fx=np.array([1, -2.5, simlev._r.fmt.NA_REAL, 1])))",
    r"(result = DP.series_convert_currency(d, "A", [1, -2.5, NA, 1]))", inp = ein("data_prep/cc_errfx2", c("d"))),
  zeile("cc_errfx3",
    r"(series_convert_currency(d, 'A', fx = 'nope'))",
    r"(result = DP.series_convert_currency(d, 'A', fx='nope'))",
    r"(result = DP.series_convert_currency(d, "A", "nope"))", inp = ein("data_prep/cc_errfx3", c("d"))),
  zeile("cc_errfx4",
    r"(series_convert_currency(d, 'A', fx = 1:3))",
    r"(result = DP.series_convert_currency(d, 'A', fx=np.arange(1, 4)))",
    r"(result = DP.series_convert_currency(d, "A", collect(1:3)))", inp = ein("data_prep/cc_errfx4", c("d"))),
  zeile("cc_errfx5",
    r"(series_convert_currency(d, 'A', fx = data.frame(date = d$date)))",
    r"(result = DP.series_convert_currency(d, 'A', fx=pd.DataFrame(dict(date=d['date']))))",
    r"(result = DP.series_convert_currency(d, "A", RFrame("date" => d.date)))", inp = ein("data_prep/cc_errfx5", c("d")))))
TB("index_total_return", "Meldungen und Warnungen von index_total_return je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("tri_err",
    r"(index_total_return(rep(100, 6), yield = 2, dates = dts[c(1, 2, 3, 6, 5, 4)]))",
    r"(result = DP.index_total_return(np.full(6, 100.), yield_=2, dates=dts[[0, 1, 2, 5, 4, 3]]))",
    r"(result = DP.index_total_return(fill(100.0, 6); yield = 2, dates = dts[[1, 2, 3, 6, 5, 4]]))", inp = ein("data_prep/tri_err", c("dts"))),
  zeile("tri_err2",
    r"(index_total_return(rep(100, 6), dates = dts[1:5]))",
    r"(result = DP.index_total_return(np.full(6, 100.), dates=dts[:5]))",
    r"(result = DP.index_total_return(fill(100.0, 6); dates = dts[1:5]))", inp = ein("data_prep/tri_err2", c("dts")))))
TB("series_align_macro", "Meldungen und Warnungen von series_align_macro je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("df_errbase",
    r"(d1 <- series_align_macro(d, cpi, 'cpi'); series_deflate(d1, 'depot', cpi = 'cpi', base_date = '2019-12-01'))",
    r"(d1 = DP.series_align_macro(d, cpi, name='cpi'); result = DP.series_deflate(d1, 'depot', cpi='cpi', base_date='2019-12-01'))",
    r"(d1 = DP.series_align_macro(d, cpi; name = "cpi")
result = DP.series_deflate(d1, "depot", "cpi"; base_date = "2019-12-01"))", inp = ein("data_prep/df_errbase", c("d", "cpi")))))
TB("series_deflate", "Meldungen und Warnungen von series_deflate je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("df_errnone",
    r"(series_deflate(d, 'depot', cpi = data.frame(date = as.Date('2030-01-01'), v = 1)))",
    r"(result = DP.series_deflate(d, 'depot', cpi=pd.DataFrame(dict(date=np.array(['2030-01-01'], dtype='datetime64[D]'), v=[1.]))))",
    r"(result = DP.series_deflate(d, "depot", RFrame("date" => [Date(2030, 1, 1)], "v" => [1.0])))", inp = ein("data_prep/df_errnone", c("d"))),
  zeile("df_errcol",
    r"(series_deflate(d, 'depot', cpi = 'cpi'))",
    r"(result = DP.series_deflate(d, 'depot', cpi='cpi'))",
    r"(result = DP.series_deflate(d, "depot", "cpi"))", inp = ein("data_prep/df_errcol", c("d")))))
TB("series_splice", "Meldungen und Warnungen von series_splice je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("sp_err1",
    r"(series_splice(a = f1))",
    r"(result = DP.series_splice(a=f1))",
    r"(result = DP.series_splice(a = f1))", inp = ein("data_prep/sp_err1", c("f1"))),
  zeile("sp_err2",
    r"(series_splice(a = 1:3, b = 1:3))",
    r"(result = DP.series_splice(a=np.arange(1, 4), b=np.arange(1, 4)))",
    r"(result = DP.series_splice(a = collect(1:3), b = collect(1:3)))", inp = ein("data_prep/sp_err2", c())),
  zeile("sp_err3",
    r"(series_splice(a = c(NA, NA), b = 1:2, dates = as.Date('2024-01-01') + 0:1))",
    r"(result = DP.series_splice(a=np.array([simlev._r.fmt.NA_REAL, simlev._r.fmt.NA_REAL]), b=np.arange(1, 3), dates=np.datetime64('2024-01-01') + np.arange(2).astype('m8[D]')))",
    r"(result = DP.series_splice(a = [NA, NA], b = collect(1:2), dates = Date(2024, 1, 1) .+ Day.(0:1)))", inp = ein("data_prep/sp_err3", c()))))
TB("strategy_from_weights", "Meldungen und Warnungen von strategy_from_weights je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("sw_err_sum",
    r"(strategy_from_weights(c(a = 0.3, b = 0.3)))",
    r"(result = DP.strategy_from_weights({'a': 0.3, 'b': 0.3}))",
    r"(result = DP.strategy_from_weights(named("a" => 0.3, "b" => 0.3)))", inp = ein("data_prep/sw_err_sum", c())),
  zeile("sw_err_dup",
    r"(strategy_from_weights(c(a = 0.5, a = 0.5)))",
    r"(result = DP.strategy_from_weights(pd.Series([0.5, 0.5], index=['a', 'a'])))",
    r"(result = DP.strategy_from_weights(named("a" => 0.5, "a" => 0.5)))", inp = ein("data_prep/sw_err_dup", c())),
  zeile("sw_err_pos",
    r"(strategy_from_weights(c(a = 1, b = 0)))",
    r"(result = DP.strategy_from_weights({'a': 1., 'b': 0.}))",
    r"(result = DP.strategy_from_weights(named("a" => 1.0, "b" => 0.0)))", inp = ein("data_prep/sw_err_pos", c())),
  zeile("sw_err_name",
    r"(strategy_from_weights(c(0.5, 0.5)))",
    r"(result = DP.strategy_from_weights(np.array([0.5, 0.5])))",
    r"(result = DP.strategy_from_weights([0.5, 0.5]))", inp = ein("data_prep/sw_err_name", c())),
  zeile("sw_err_cfg",
    r"(strategy_from_weights(c(a = 0.5, b = 0.5), partial_exemption = c(a = 130)))",
    r"(result = DP.strategy_from_weights({'a': 0.5, 'b': 0.5}, partial_exemption={'a': 130}))",
    r"(result = DP.strategy_from_weights(named("a" => 0.5, "b" => 0.5); partial_exemption = named("a" => 130.0)))", inp = ein("data_prep/sw_err_cfg", c())),
  zeile("sw_wr_err_elem",
    r"(inner <- create_strategy(A = asset_config('etf', 'bnh', 0.6), B = asset_config('etf', 'bnh', 0.4))
wb <- wrapper_config(inner, costs = funds_costs(0.95, 10))
w2 <- wrapper_config(create_strategy(C = asset_config('etf', 'bnh', 1)), costs = funds_costs(0.2, 0))
strategy_from_weights(c(world = 0.6, bonds = 0.4), wrapper = list(world = wb, bonds = inner)))",
    r"(inner = simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=0.6), B=simlev.asset_config(asset_class='etf', trading='bnh', share=0.4))
wb = simlev.wrapper_config(inner, costs=simlev.funds_costs(fee=0.95, performance_fee=10))
w2 = simlev.wrapper_config(simlev.create_strategy(C=simlev.asset_config(asset_class='etf', trading='bnh', share=1)), costs=simlev.funds_costs(fee=0.2, performance_fee=0))
result = DP.strategy_from_weights({'world': 0.6, 'bonds': 0.4}, wrapper={'world': wb, 'bonds': inner}))",
    r"(inner = SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.6), "B" => SL.asset_config("etf", "bnh", 0.4))
wb = SL.wrapper_config(inner; costs = SL.funds_costs(0.95, 10))
w2 = SL.wrapper_config(SL.create_strategy("C" => SL.asset_config("etf", "bnh", 1)); costs = SL.funds_costs(0.2, 0))
result = DP.strategy_from_weights(named("world" => 0.6, "bonds" => 0.4); wrapper = (world = wb, bonds = inner)))", inp = ein("data_prep/sw_wr_err_elem", c())),
  zeile("sw_wr_err_type",
    r"(inner <- create_strategy(A = asset_config('etf', 'bnh', 0.6), B = asset_config('etf', 'bnh', 0.4))
wb <- wrapper_config(inner, costs = funds_costs(0.95, 10))
w2 <- wrapper_config(create_strategy(C = asset_config('etf', 'bnh', 1)), costs = funds_costs(0.2, 0))
strategy_from_weights(c(world = 0.6, bonds = 0.4), wrapper = 'wb'))",
    r"(inner = simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=0.6), B=simlev.asset_config(asset_class='etf', trading='bnh', share=0.4))
wb = simlev.wrapper_config(inner, costs=simlev.funds_costs(fee=0.95, performance_fee=10))
w2 = simlev.wrapper_config(simlev.create_strategy(C=simlev.asset_config(asset_class='etf', trading='bnh', share=1)), costs=simlev.funds_costs(fee=0.2, performance_fee=0))
result = DP.strategy_from_weights({'world': 0.6, 'bonds': 0.4}, wrapper='wb'))",
    r"(inner = SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.6), "B" => SL.asset_config("etf", "bnh", 0.4))
wb = SL.wrapper_config(inner; costs = SL.funds_costs(0.95, 10))
w2 = SL.wrapper_config(SL.create_strategy("C" => SL.asset_config("etf", "bnh", 1)); costs = SL.funds_costs(0.2, 0))
result = DP.strategy_from_weights(named("world" => 0.6, "bonds" => 0.4); wrapper = "wb"))", inp = ein("data_prep/sw_wr_err_type", c())),
  zeile("sw_wr_err_unnamed",
    r"(inner <- create_strategy(A = asset_config('etf', 'bnh', 0.6), B = asset_config('etf', 'bnh', 0.4))
wb <- wrapper_config(inner, costs = funds_costs(0.95, 10))
w2 <- wrapper_config(create_strategy(C = asset_config('etf', 'bnh', 1)), costs = funds_costs(0.2, 0))
strategy_from_weights(c(world = 0.6, bonds = 0.4), wrapper = list(wb, w2)))",
    r"(inner = simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=0.6), B=simlev.asset_config(asset_class='etf', trading='bnh', share=0.4))
wb = simlev.wrapper_config(inner, costs=simlev.funds_costs(fee=0.95, performance_fee=10))
w2 = simlev.wrapper_config(simlev.create_strategy(C=simlev.asset_config(asset_class='etf', trading='bnh', share=1)), costs=simlev.funds_costs(fee=0.2, performance_fee=0))
result = DP.strategy_from_weights({'world': 0.6, 'bonds': 0.4}, wrapper=[wb, w2]))",
    r"(inner = SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.6), "B" => SL.asset_config("etf", "bnh", 0.4))
wb = SL.wrapper_config(inner; costs = SL.funds_costs(0.95, 10))
w2 = SL.wrapper_config(SL.create_strategy("C" => SL.asset_config("etf", "bnh", 1)); costs = SL.funds_costs(0.2, 0))
result = DP.strategy_from_weights(named("world" => 0.6, "bonds" => 0.4); wrapper = [wb, w2]))", inp = ein("data_prep/sw_wr_err_unnamed", c())),
  zeile("sw_wr_err_dup",
    r"(inner <- create_strategy(A = asset_config('etf', 'bnh', 0.6), B = asset_config('etf', 'bnh', 0.4))
wb <- wrapper_config(inner, costs = funds_costs(0.95, 10))
w2 <- wrapper_config(create_strategy(C = asset_config('etf', 'bnh', 1)), costs = funds_costs(0.2, 0))
strategy_from_weights(c(world = 0.6, bonds = 0.4), wrapper = list(world = wb, world = w2)))",
    r"(inner = simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=0.6), B=simlev.asset_config(asset_class='etf', trading='bnh', share=0.4))
wb = simlev.wrapper_config(inner, costs=simlev.funds_costs(fee=0.95, performance_fee=10))
w2 = simlev.wrapper_config(simlev.create_strategy(C=simlev.asset_config(asset_class='etf', trading='bnh', share=1)), costs=simlev.funds_costs(fee=0.2, performance_fee=0))
result = DP.strategy_from_weights({'world': 0.6, 'bonds': 0.4}, wrapper=pd.Series([wb, w2], index=['world', 'world'], dtype=object)))",
    r"(inner = SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.6), "B" => SL.asset_config("etf", "bnh", 0.4))
wb = SL.wrapper_config(inner; costs = SL.funds_costs(0.95, 10))
w2 = SL.wrapper_config(SL.create_strategy("C" => SL.asset_config("etf", "bnh", 1)); costs = SL.funds_costs(0.2, 0))
result = DP.strategy_from_weights(named("world" => 0.6, "bonds" => 0.4); wrapper = ["world" => wb, "world" => w2]))", inp = ein("data_prep/sw_wr_err_dup", c()))))
TB("portfolio_template", "Meldungen und Warnungen von portfolio_template je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("pt_err1",
    r"(portfolio_template('xyz'))",
    r"(result = DP.portfolio_template(name='xyz'))",
    r"(result = DP.portfolio_template("xyz"))", inp = ein("data_prep/pt_err1", c())),
  zeile("pt_err2",
    r"(portfolio_template('60_40', map = c(stock = 'A', bonds = 'B')))",
    r"(result = DP.portfolio_template(name='60_40', map={'stock': 'A', 'bonds': 'B'}))",
    r"(result = DP.portfolio_template("60_40"; map = named("stock" => "A", "bonds" => "B")))", inp = ein("data_prep/pt_err2", c())),
  zeile("pt_err3",
    r"(portfolio_template('60_40', map = c(stocks = 'A', bonds = 'A')))",
    r"(result = DP.portfolio_template(name='60_40', map={'stocks': 'A', 'bonds': 'A'}))",
    r"(result = DP.portfolio_template("60_40"; map = named("stocks" => "A", "bonds" => "A")))", inp = ein("data_prep/pt_err3", c())),
  zeile("pt_err4",
    r"(portfolio_template('60_40', map = c('A', 'B')))",
    r"(result = DP.portfolio_template(name='60_40', map=['A', 'B']))",
    r"(result = DP.portfolio_template("60_40"; map = ["A", "B"]))", inp = ein("data_prep/pt_err4", c())),
  zeile("pt_err5",
    r"(portfolio_template(map = c(stocks = 'A')))",
    r"(result = DP.portfolio_template(map={'stocks': 'A'}))",
    r"(result = DP.portfolio_template(; map = named("stocks" => "A")))", inp = ein("data_prep/pt_err5", c())),
  zeile("pt_wr_err_role",
    r"(inner <- create_strategy(A = asset_config('etf', 'bnh', 0.6), B = asset_config('etf', 'bnh', 0.4))
wb <- wrapper_config(inner, costs = funds_costs(0.95, 10))
w2 <- wrapper_config(create_strategy(C = asset_config('etf', 'bnh', 1)), costs = funds_costs(0.2, 0))
portfolio_template('60_40', map = c(stocks = 'A'), wrapper = list(stocks = wb)))",
    r"(inner = simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=0.6), B=simlev.asset_config(asset_class='etf', trading='bnh', share=0.4))
wb = simlev.wrapper_config(inner, costs=simlev.funds_costs(fee=0.95, performance_fee=10))
w2 = simlev.wrapper_config(simlev.create_strategy(C=simlev.asset_config(asset_class='etf', trading='bnh', share=1)), costs=simlev.funds_costs(fee=0.2, performance_fee=0))
result = DP.portfolio_template(name='60_40', map={'stocks': 'A'}, wrapper={'stocks': wb}))",
    r"(inner = SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.6), "B" => SL.asset_config("etf", "bnh", 0.4))
wb = SL.wrapper_config(inner; costs = SL.funds_costs(0.95, 10))
w2 = SL.wrapper_config(SL.create_strategy("C" => SL.asset_config("etf", "bnh", 1)); costs = SL.funds_costs(0.2, 0))
result = DP.portfolio_template("60_40"; map = named("stocks" => "A"), wrapper = (stocks = wb,)))", inp = ein("data_prep/pt_wr_err_role", c())),
  zeile("pt_wr_err_signal",
    r"(inner <- create_strategy(A = asset_config('etf', 'bnh', 0.6), B = asset_config('etf', 'bnh', 0.4))
wb <- wrapper_config(inner, costs = funds_costs(0.95, 10))
w2 <- wrapper_config(create_strategy(C = asset_config('etf', 'bnh', 1)), costs = funds_costs(0.2, 0))
portfolio_template('60_40', trading = 'signal', signal_buy = 'b', signal_sell = 's', wrapper = wb))",
    r"(inner = simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=0.6), B=simlev.asset_config(asset_class='etf', trading='bnh', share=0.4))
wb = simlev.wrapper_config(inner, costs=simlev.funds_costs(fee=0.95, performance_fee=10))
w2 = simlev.wrapper_config(simlev.create_strategy(C=simlev.asset_config(asset_class='etf', trading='bnh', share=1)), costs=simlev.funds_costs(fee=0.2, performance_fee=0))
result = DP.portfolio_template(name='60_40', trading='signal', signal_buy='b', signal_sell='s', wrapper=wb))",
    r"(inner = SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.6), "B" => SL.asset_config("etf", "bnh", 0.4))
wb = SL.wrapper_config(inner; costs = SL.funds_costs(0.95, 10))
w2 = SL.wrapper_config(SL.create_strategy("C" => SL.asset_config("etf", "bnh", 1)); costs = SL.funds_costs(0.2, 0))
result = DP.portfolio_template("60_40"; trading = "signal", signal_buy = "b", signal_sell = "s", wrapper = wb))", inp = ein("data_prep/pt_wr_err_signal", c()))))
ref_done()

ref_init("data_prep", gruppe = "ausgabe")
TB("series_check", "Druckausgabe von series_check je Zeile", vor = VOR, zeilen = list(
  zeile("cs_print_n",
    r"(capture.output(print(series_check(d), max_issues = 3)))",
    r"(import io, contextlib
b = io.StringIO()
with contextlib.redirect_stdout(b):
    DP.series_check(d).print(max_issues=3)
result = b.getvalue().rstrip('\n').split('\n'))",
    r"(result = split(DP.format_SimLevDataCheck(DP.series_check(d); max_issues = 3), "\n"))", inp = ein("data_prep/cs_print_n", c("d")))))
ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul backcast
# ════════════════════════════════════════════════════════════════════════════════════════════════════
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
EIN[["backcast/rs_named2"]] <- list(d = dt10)
EIN[["backcast/rs_namednodate"]] <- list(d = dt10)
vna <- c(NA, NA, 1, NA, NA, 4, 5, NA, 2, NA)
for (m in c("locf", "linear", "stine", "none")) for (kl in c(FALSE, TRUE)) EIN[[paste0("backcast/", sprintf("fill_%s_%d", 
    m, kl))]] <- list(v = vna)
set.seed(3); vlin <- cumsum(rnorm(500)); vlin[sample(500, 200)] <- NA
# ── backcast_fit ───────────────────────────────────────────────────────────
FIT <- function(args) sprintf("backcast_fit(s, 'etf', 'idx', %s)", args)
FITP <- function(args) sprintf("result = BC.backcast_fit(s, 'etf', 'idx', %s)", args)
EIN[["backcast/bf_basic"]] <- list(s = s2)
EIN[["backcast/bf_grid"]] <- list(s = s2)
for (ls in c("mse", "mae", "median", "max")) EIN[[paste0("backcast/", paste0("bf_loss_", ls))]] <- list(s = s2)
EIN[["backcast/bf_nofit"]] <- list(s = s2)
EIN[["backcast/bf_fixed"]] <- list(s = s2)
EIN[["backcast/bf_geom"]] <- list(s = s2)
EIN[["backcast/bf_short"]] <- list(s = sm)
EIN[["backcast/bf_linear_w"]] <- list(s = sp)
EIN[["backcast/bf_spline"]] <- list(s = sp)
EIN[["backcast/bf_summary"]] <- list(s = s2)
EIN[["backcast/bf_err_col"]] <- list(s = s2)
EIN[["backcast/bf_err_lev"]] <- list(s = s2)
EIN[["backcast/bf_err_few"]] <- list(s = s2)
EIN[["backcast/bf_err_bounds"]] <- list(s = s2)
EIN[["backcast/bf_err_bounds2"]] <- list(s = s2)
EIN[["backcast/bf_err_fit"]] <- list(s = s2)
EIN[["backcast/bf_err_grid2"]] <- list(s = s2)
EIN[["backcast/bf_err_dup"]] <- list(s = s2)
EIN[["backcast/bf_err_na"]] <- list(s = s2)
EIN[["backcast/bf_err_nodate"]] <- list(s = s2)
EIN[["backcast/bf_err_df"]] <- list()
EIN[["backcast/bf_err_idx"]] <- list(s = s2)
# ── backcast ───────────────────────────────────────────────────────────────
F2 <- sprintf("f <- backcast_fit(s, 'etf', 'idx', ter = %s, leverage = 2, rate = 'rate')", TER)
F2P <- sprintf("f = BC.backcast_fit(s, 'etf', 'idx', ter=%s, leverage=2, rate='rate')", TERP)
ATTR <- "list(bc = bc, params = attr(bc, 'params'), splice = attr(bc, 'splice_date'))"
ATTRP <- "result = dict(bc=bc, params=bc.attrs['params'], splice=bc.attrs['splice_date'])"
EIN[["backcast/bc_fit"]] <- list(s = s2)
EIN[["backcast/bc_otherdata"]] <- list(s = s2)
EIN[["backcast/bc_nofit_attr"]] <- list(s = s2)
EIN[["backcast/bc_noprod"]] <- list(s = sp)
EIN[["backcast/bc_lead"]] <- list(s = sp)
EIN[["backcast/bc_err_splice"]] <- list(s = s2)
EIN[["backcast/bc_err_splice3"]] <- list(s = s2)
EIN[["backcast/bc_err_data"]] <- list()
EIN[["backcast/bc_err_prod"]] <- list(s = s2)
EIN[["backcast/bc_err_model"]] <- list(s = s2)
EIN[["backcast/bc_err_fit"]] <- list()

# Vorspann je Szenario bzw. Tabellenzeile (gemeinsame Objekte des Moduls)
VOR <- list(r = r"()",
            py = r"(from simlev import backcast as BC)",
            jl = r"(const BC = SL.Backcast)")

ref_init("backcast", gruppe = "gleichlauf")
SZ("hilfsfunktionen", ".resolve_series mit benannten Werten und .fill_na (linear, stine)", vor = VOR, teile = list(
  rs_named2 = teil(
    r"(SimLev:::.resolve_series(c('2020/01/09' = 0.2, '2020/01/03' = 0.4), d, 'ter'))",
    r"(result = BC._resolve_series({'2020/01/09': 0.2, '2020/01/03': 0.4}, d, 'ter'))",
    r"(result = BC._resolve_series(named("2020/01/09" => 0.2, "2020/01/03" => 0.4), d, "ter"))", inp = ein("backcast/rs_named2", c("d"))),
  rs_namednodate = teil(
    r"(SimLev:::.resolve_series(c(a = 1), d, 'ter'))",
    r"(result = BC._resolve_series(pd.Series([1.], index=['a']), d, 'ter'))",
    r"(result = BC._resolve_series(named("a" => 1.0), d, "ter"))", inp = ein("backcast/rs_namednodate", c("d"))),
  fill_linear_1 = teil(
    r"(SimLev:::.fill_na(v, 'linear', keep_leading = TRUE))",
    r"(result = BC._fill_na(v, 'linear', keep_leading=True))",
    r"(result = BC._fill_na(v, "linear"; keep_leading = true))", inp = ein("backcast/fill_linear_1", c("v"))),
  fill_stine_1 = teil(
    r"(SimLev:::.fill_na(v, 'stine', keep_leading = TRUE))",
    r"(result = BC._fill_na(v, 'stine', keep_leading=True))",
    r"(result = BC._fill_na(v, "stine"; keep_leading = true))", inp = ein("backcast/fill_stine_1", c("v")))))
SZ("anpassung_varianten", "backcast_fit: zeitabhängige TER, Gitter, ohne Anpassung, feste Parameter, geometrische Abgrenzung, Short-Hebel mit Verzögerung, Spline-Modell mit Währung, summary()", vor = VOR, teile = list(
  bf_basic = teil(
    r"(backcast_fit(s, 'etf', 'idx', ter = c('2005-01-01' = 0.35, '2006-06-01' = 0.6), leverage = 2, rate = 'rate'))",
    r"(result = BC.backcast_fit(s, 'etf', 'idx', ter=pd.Series([0.35, 0.6], index=['2005-01-01', '2006-06-01']), leverage=2, rate='rate'))",
    r"(result = BC.backcast_fit(s, "etf", "idx"; ter = named("2005-01-01" => 0.35, "2006-06-01" => 0.6), leverage = 2, rate = "rate"))", druck = TRUE, inp = ein("backcast/bf_basic", c("s"))),
  bf_grid = teil(
    r"(backcast_fit(s, 'etf', 'idx', ter = c('2005-01-01' = 0.35, '2006-06-01' = 0.6), leverage = 2, rate = 'rate', method = 'grid', grid = seq(-1, 1, by = 0.01)))",
    r"(result = BC.backcast_fit(s, 'etf', 'idx', ter=pd.Series([0.35, 0.6], index=['2005-01-01', '2006-06-01']), leverage=2, rate='rate', method='grid', grid=np.minimum(-1 + np.arange(201) * 0.01, 1)))",
    r"(result = BC.backcast_fit(s, "etf", "idx"; ter = named("2005-01-01" => 0.35, "2006-06-01" => 0.6), leverage = 2, rate = "rate", method = "grid", grid = min.(-1 .+ collect(0:200) .* 0.01, 1.0)))", druck = TRUE, inp = ein("backcast/bf_grid", c("s"))),
  bf_nofit = teil(
    r"(backcast_fit(s, 'etf', 'idx', ter = 0.5, leverage = 2, rate = 'rate', fit = character(0), fixed = list(drag = 0.3, beta = 1.01)))",
    r"(result = BC.backcast_fit(s, 'etf', 'idx', ter=0.5, leverage=2, rate='rate', fit=[], fixed={'drag': 0.3, 'beta': 1.01}))",
    r"(result = BC.backcast_fit(s, "etf", "idx"; ter = 0.5, leverage = 2, rate = "rate", fit = String[], fixed = RList("drag" => 0.3, "beta" => 1.01)))", druck = TRUE, inp = ein("backcast/bf_nofit", c("s"))),
  bf_fixed = teil(
    r"(backcast_fit(s, 'etf', 'idx', ter = 0.5, leverage = 2, rate = 'rate', fixed = list(spread = 0.4), start = '2006-08-01', end = as.Date('2006-12-31')))",
    r"(result = BC.backcast_fit(s, 'etf', 'idx', ter=0.5, leverage=2, rate='rate', fixed={'spread': 0.4}, start='2006-08-01', end=np.datetime64('2006-12-31')))",
    r"(result = BC.backcast_fit(s, "etf", "idx"; ter = 0.5, leverage = 2, rate = "rate", fixed = RList("spread" => 0.4), start = "2006-08-01", end_ = Date(2006, 12, 31)))", druck = TRUE, inp = ein("backcast/bf_fixed", c("s"))),
  bf_geom = teil(
    r"(backcast_fit(s, 'etf', 'idx', ter = 0.5, leverage = 2, rate = 'rate', accrual = 'geometric', ter_basis = 360, rate_basis = 365, lag = 1, rate_lag = 2))",
    r"(result = BC.backcast_fit(s, 'etf', 'idx', ter=0.5, leverage=2, rate='rate', accrual='geometric', ter_basis=360, rate_basis=365, lag=1, rate_lag=2))",
    r"(result = BC.backcast_fit(s, "etf", "idx"; ter = 0.5, leverage = 2, rate = "rate", accrual = "geometric", ter_basis = 360, rate_basis = 365, lag = 1, rate_lag = 2))", druck = TRUE, inp = ein("backcast/bf_geom", c("s"))),
  bf_short = teil(
    r"(backcast_fit(s, 'etf', 'idx', ter = 0.5, leverage = -1, rate = 'rate', lag = 'auto', fit = c('drag', 'spread')))",
    r"(result = BC.backcast_fit(s, 'etf', 'idx', ter=0.5, leverage=-1, rate='rate', lag='auto', fit=['drag', 'spread']))",
    r"(result = BC.backcast_fit(s, "etf", "idx"; ter = 0.5, leverage = -1, rate = "rate", lag = "auto", fit = ["drag", "spread"]))", druck = TRUE, inp = ein("backcast/bf_short", c("s"))),
  bf_spline = teil(
    r"(f <- backcast_fit(s, 'etf', 'idx', model = 'spline', fx = 'fx', objective = 'return'); f$regression <- NULL; f)",
    r"(result = BC.backcast_fit(s, 'etf', 'idx', model='spline', fx='fx', objective='return'); result['regression'] = None)",
    r"(result = BC.backcast_fit(s, "etf", "idx"; model = "spline", fx = "fx", objective = "return")
delete!(result, "regression"))", druck = TRUE, inp = ein("backcast/bf_spline", c("s"))),
  bf_summary = teil(
    r"(f <- backcast_fit(s, 'etf', 'idx', ter = 0.5, leverage = 2, rate = 'rate'); summary(f))",
    r"(f = BC.backcast_fit(s, 'etf', 'idx', ter=0.5, leverage=2, rate='rate'); result = BC.summary_SimLevBackcastFit(f))",
    r"(f = BC.backcast_fit(s, "etf", "idx"; ter = 0.5, leverage = 2, rate = "rate")
result = BC.summary_SimLevBackcastFit(f))", inp = ein("backcast/bf_summary", c("s")))))
SZ("verlustfunktionen", "backcast_fit mit den Verlustfunktionen mse, mae, median und max", vor = VOR, teile = list(
  bf_loss_mse = teil(
    r"(backcast_fit(s, 'etf', 'idx', ter = 0.5, leverage = 2, rate = 'rate', loss = 'mse', validate = FALSE))",
    r"(result = BC.backcast_fit(s, 'etf', 'idx', ter=0.5, leverage=2, rate='rate', loss='mse', validate=False))",
    r"(result = BC.backcast_fit(s, "etf", "idx"; ter = 0.5, leverage = 2, rate = "rate", loss = "mse", validate = false))", druck = TRUE, inp = ein("backcast/bf_loss_mse", c("s"))),
  bf_loss_mae = teil(
    r"(backcast_fit(s, 'etf', 'idx', ter = 0.5, leverage = 2, rate = 'rate', loss = 'mae', validate = FALSE))",
    r"(result = BC.backcast_fit(s, 'etf', 'idx', ter=0.5, leverage=2, rate='rate', loss='mae', validate=False))",
    r"(result = BC.backcast_fit(s, "etf", "idx"; ter = 0.5, leverage = 2, rate = "rate", loss = "mae", validate = false))", druck = TRUE, inp = ein("backcast/bf_loss_mae", c("s"))),
  bf_loss_median = teil(
    r"(backcast_fit(s, 'etf', 'idx', ter = 0.5, leverage = 2, rate = 'rate', loss = 'median', validate = FALSE))",
    r"(result = BC.backcast_fit(s, 'etf', 'idx', ter=0.5, leverage=2, rate='rate', loss='median', validate=False))",
    r"(result = BC.backcast_fit(s, "etf", "idx"; ter = 0.5, leverage = 2, rate = "rate", loss = "median", validate = false))", druck = TRUE, inp = ein("backcast/bf_loss_median", c("s"))),
  bf_loss_max = teil(
    r"(backcast_fit(s, 'etf', 'idx', ter = 0.5, leverage = 2, rate = 'rate', loss = 'max', validate = FALSE))",
    r"(result = BC.backcast_fit(s, 'etf', 'idx', ter=0.5, leverage=2, rate='rate', loss='max', validate=False))",
    r"(result = BC.backcast_fit(s, "etf", "idx"; ter = 0.5, leverage = 2, rate = "rate", loss = "max", validate = false))", druck = TRUE, inp = ein("backcast/bf_loss_max", c("s")))))
SZ("rueckrechnung", "Kette backcast_fit (einmal gerechnet) -> backcast auf den eigenen und auf anderen Daten; ohne Anpassung (Attribute), ohne Produktreihe, mit führenden NA im Index", vor = VOR,
  gemein = teil(
    r"(f <- backcast_fit(s, 'etf', 'idx', ter = c('2005-01-01' = 0.35, '2006-06-01' = 0.6), leverage = 2, rate = 'rate'))",
    r"(f = BC.backcast_fit(s, 'etf', 'idx', ter=pd.Series([0.35, 0.6], index=['2005-01-01', '2006-06-01']), leverage=2, rate='rate'))",
    r"(f = BC.backcast_fit(s, "etf", "idx"; ter = named("2005-01-01" => 0.35, "2006-06-01" => 0.6), leverage = 2, rate = "rate"))"),
  teile = list(
  bc_fit = teil(
    r"(backcast(f))",
    r"(result = BC.backcast(fit=f))",
    r"(result = BC.backcast(f))", druck = TRUE, inp = ein("backcast/bc_fit", c("s"))),
  bc_otherdata = teil(
    r"(s2 <- s[1:1000, ]; s2$etf[990:1000] <- NA; backcast(f, data = s2, fill = 'model'))",
    r"(s2 = s.iloc[:1000].copy(); v = s2['etf'].to_numpy(dtype=float, copy=True); v[989:1000] = simlev._r.fmt.NA_REAL; s2['etf'] = v; result = BC.backcast(fit=f, data=s2, fill='model'))",
    r"(s2 = rows(s, 1:1000); s2.etf[990:1000] .= NA
result = BC.backcast(f; data = s2, fill = "model"))", druck = TRUE, inp = ein("backcast/bc_otherdata", c("s"))),
  bc_nofit_attr = teil(
    r"(bc <- backcast(data = s, product = 'etf', index = 'idx', leverage = 2, rate = 2, ter = 0.6, splice = '2006-01-01', lag = 1, accrual = 'geometric', unknown = 5); list(bc = bc, params = attr(bc, 'params'), splice = attr(bc, 'splice_date')))",
    r"(bc = BC.backcast(data=s, product='etf', index='idx', leverage=2, rate=2, ter=0.6, splice='2006-01-01', lag=1, accrual='geometric', unknown=5)
result = dict(bc=bc, params=bc.attrs['params'], splice=bc.attrs['splice_date']))",
    r"(bc = BC.backcast(; data = s, product = "etf", index = "idx", leverage = 2, rate = 2, ter = 0.6, splice = "2006-01-01", lag = 1, accrual = "geometric", unknown = 5)
result = RList("bc" => bc, "params" => attrs(bc)["params"], "splice" => attrs(bc)["splice_date"]))", inp = ein("backcast/bc_nofit_attr", c("s"))),
  bc_noprod = teil(
    r"(s$etf <- NA; backcast(data = s, product = 'etf', index = 'idx', fx = 'fx', index_fill = 'linear'))",
    r"(s['etf'] = simlev._r.fmt.NA_REAL
result = BC.backcast(data=s, product='etf', index='idx', fx='fx', index_fill='linear'))",
    r"(s.etf = fill(NA, nrow(s))
result = BC.backcast(; data = s, product = "etf", index = "idx", fx = "fx", index_fill = "linear"))", druck = TRUE, inp = ein("backcast/bc_noprod", c("s"))),
  bc_lead = teil(
    r"(s$idx[1:5] <- NA; backcast(data = s, product = 'etf', index = 'idx', rebase = 1))",
    r"(v = s['idx'].to_numpy(dtype=float, copy=True); v[0:5] = simlev._r.fmt.NA_REAL; s['idx'] = v
result = BC.backcast(data=s, product='etf', index='idx', rebase=1))",
    r"(s.idx[1:5] .= NA
result = BC.backcast(; data = s, product = "etf", index = "idx", rebase = 1))", druck = TRUE, inp = ein("backcast/bc_lead", c("s")))))
ref_done()

ref_init("backcast", gruppe = "fehler")
TB("backcast_fit", "Meldungen und Warnungen von backcast_fit je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("bf_linear_w",
    r"(backcast_fit(s, 'etf', 'idx', model = 'linear', fit = c('drag', 'beta', 'spread'), fx = 'fx', index_fill = 'linear'))",
    r"(result = BC.backcast_fit(s, 'etf', 'idx', model='linear', fit=['drag', 'beta', 'spread'], fx='fx', index_fill='linear'))",
    r"(result = BC.backcast_fit(s, "etf", "idx"; model = "linear", fit = ["drag", "beta", "spread"], fx = "fx", index_fill = "linear"))", print = TRUE, inp = ein("backcast/bf_linear_w", c("s"))),
  zeile("bf_err_col",
    r"(backcast_fit(s, 'etf', 'missing'))",
    r"(result = BC.backcast_fit(s, 'etf', 'missing'))",
    r"(result = BC.backcast_fit(s, "etf", "missing"))", inp = ein("backcast/bf_err_col", c("s"))),
  zeile("bf_err_lev",
    r"(backcast_fit(s, 'etf', 'idx', leverage = 0))",
    r"(result = BC.backcast_fit(s, 'etf', 'idx', leverage=0))",
    r"(result = BC.backcast_fit(s, "etf", "idx"; leverage = 0))", inp = ein("backcast/bf_err_lev", c("s"))),
  zeile("bf_err_few",
    r"(s$etf <- NA; backcast_fit(s, 'etf', 'idx'))",
    r"(s['etf'] = simlev._r.fmt.NA_REAL
result = BC.backcast_fit(s, 'etf', 'idx'))",
    r"(s.etf = fill(NA, nrow(s))
result = BC.backcast_fit(s, "etf", "idx"))", inp = ein("backcast/bf_err_few", c("s"))),
  zeile("bf_err_bounds",
    r"(backcast_fit(s, 'etf', 'idx', bounds = list(drag = c(5, -5))))",
    r"(result = BC.backcast_fit(s, 'etf', 'idx', bounds={'drag': [5, -5]}))",
    r"(result = BC.backcast_fit(s, "etf", "idx"; bounds = RList("drag" => [5.0, -5.0])))", inp = ein("backcast/bf_err_bounds", c("s"))),
  zeile("bf_err_bounds2",
    r"(backcast_fit(s, 'etf', 'idx', bounds = list(alpha = c(0, 1))))",
    r"(result = BC.backcast_fit(s, 'etf', 'idx', bounds={'alpha': [0, 1]}))",
    r"(result = BC.backcast_fit(s, "etf", "idx"; bounds = RList("alpha" => [0.0, 1.0])))", inp = ein("backcast/bf_err_bounds2", c("s"))),
  zeile("bf_err_fit",
    r"(backcast_fit(s, 'etf', 'idx', fit = 'alpha'))",
    r"(result = BC.backcast_fit(s, 'etf', 'idx', fit='alpha'))",
    r"(result = BC.backcast_fit(s, "etf", "idx"; fit = "alpha"))", inp = ein("backcast/bf_err_fit", c("s"))),
  zeile("bf_err_grid2",
    r"(backcast_fit(s, 'etf', 'idx', leverage = 2, fit = c('drag', 'beta'), method = 'grid'))",
    r"(result = BC.backcast_fit(s, 'etf', 'idx', leverage=2, fit=['drag', 'beta'], method='grid'))",
    r"(result = BC.backcast_fit(s, "etf", "idx"; leverage = 2, fit = ["drag", "beta"], method = "grid"))", inp = ein("backcast/bf_err_grid2", c("s"))),
  zeile("bf_err_dup",
    r"(backcast_fit(s[c(1, 1:20), ], 'etf', 'idx'))",
    r"(result = BC.backcast_fit(s.iloc[[0] + list(range(20))], 'etf', 'idx'))",
    r"(result = BC.backcast_fit(rows(s, vcat([1], 1:20)), "etf", "idx"))", inp = ein("backcast/bf_err_dup", c("s"))),
  zeile("bf_err_na",
    r"(s$date[5] <- NA; backcast_fit(s, 'etf', 'idx'))",
    r"(s.loc[4, 'date'] = pd.NaT
result = BC.backcast_fit(s, 'etf', 'idx'))",
    r"(dd = Vector{Union{Missing,Date}}(s.date); dd[5] = missing; s.date = dd
result = BC.backcast_fit(s, "etf", "idx"))", inp = ein("backcast/bf_err_na", c("s"))),
  zeile("bf_err_nodate",
    r"(backcast_fit(s[, -1], 'etf', 'idx'))",
    r"(result = BC.backcast_fit(s.iloc[:, 1:], 'etf', 'idx'))",
    r"(result = BC.backcast_fit(RFrame(names(s)[2:end], [s[k] for k in names(s)[2:end]]), "etf", "idx"))", inp = ein("backcast/bf_err_nodate", c("s"))),
  zeile("bf_err_df",
    r"(backcast_fit(1:3, 'etf', 'idx'))",
    r"(result = BC.backcast_fit(np.arange(1, 4), 'etf', 'idx'))",
    r"(result = BC.backcast_fit(collect(1:3), "etf", "idx"))", inp = ein("backcast/bf_err_df", c())),
  zeile("bf_err_idx",
    r"(s$idx[10] <- -1; backcast_fit(s, 'etf', 'idx'))",
    r"(s.loc[9, 'idx'] = -1
result = BC.backcast_fit(s, 'etf', 'idx'))",
    r"(s.idx[10] = -1
result = BC.backcast_fit(s, "etf", "idx"))", inp = ein("backcast/bf_err_idx", c("s")))))
TB("backcast", "Meldungen und Warnungen von backcast je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("bc_err_splice",
    r"(backcast(data = s, product = 'etf', index = 'idx', leverage = 2, rate = 2, ter = 0.6, splice = '2030-01-01'))",
    r"(result = BC.backcast(data=s, product='etf', index='idx', leverage=2, rate=2, ter=0.6, splice='2030-01-01'))",
    r"(result = BC.backcast(; data = s, product = "etf", index = "idx", leverage = 2, rate = 2, ter = 0.6, splice = "2030-01-01"))", inp = ein("backcast/bc_err_splice", c("s"))),
  zeile("bc_err_splice3",
    r"(backcast(data = s, product = 'etf', index = 'idx', splice = NA_character_))",
    r"(result = BC.backcast(data=s, product='etf', index='idx', splice=np.array([None], dtype=object)))",
    r"(result = BC.backcast(; data = s, product = "etf", index = "idx", splice = missing))", inp = ein("backcast/bc_err_splice3", c("s"))),
  zeile("bc_err_data",
    r"(backcast())",
    r"(result = BC.backcast())",
    r"(result = BC.backcast())", inp = ein("backcast/bc_err_data", c())),
  zeile("bc_err_prod",
    r"(backcast(data = s, index = 'idx'))",
    r"(result = BC.backcast(data=s, index='idx'))",
    r"(result = BC.backcast(; data = s, index = "idx"))", inp = ein("backcast/bc_err_prod", c("s"))),
  zeile("bc_err_model",
    r"(backcast(data = s, product = 'etf', index = 'idx', model = 'linear'))",
    r"(result = BC.backcast(data=s, product='etf', index='idx', model='linear'))",
    r"(result = BC.backcast(; data = s, product = "etf", index = "idx", model = "linear"))", inp = ein("backcast/bc_err_model", c("s"))),
  zeile("bc_err_fit",
    r"(backcast(list(a = 1)))",
    r"(result = BC.backcast(fit={'a': 1}))",
    r"(result = BC.backcast(RList("a" => 1)))", inp = ein("backcast/bc_err_fit", c()))))
ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul signals
# ════════════════════════════════════════════════════════════════════════════════════════════════════
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
x10 <- c(10, 11, 12, 13, 12, 11, 10, 9, 10, 11)
set.seed(1); px <- 100 * cumprod(1 + rnorm(1000, 2e-4, 0.01))
set.seed(4); xc <- 1e4 + cumsum(rnorm(3000))
set.seed(7); xl <- 50 + cumsum(rnorm(9000, 0, 0.5)) + 1e3 * sin(1:9000 / 50)
xna <- px; xna[c(10, 300, 301, 700)] <- NA
xinf <- px[1:300]; xinf[c(50, 200)] <- c(Inf, NaN)
EIN[["signals/core_mean_edge"]] <- list()
EIN[["signals/ema_edge"]] <- list()
EIN[["signals/ema_na"]] <- list(x = xna)
EIN[["signals/cross_ema"]] <- list(x = px)
EIN[["signals/cross_err"]] <- list(x = px)
EIN[["signals/dd_na2"]] <- list()
EIN[["signals/dd_err"]] <- list(x = px)
set.seed(2); xv <- 100 * cumprod(1 + rnorm(300, 0, 0.01))
EIN[["signals/comb_and"]] <- list(x = px)
EIN[["signals/comb_or"]] <- list(x = px)
EIN[["signals/comb_err"]] <- list(x = px)
EIN[["signals/comb_err0"]] <- list()

# Vorspann je Szenario bzw. Tabellenzeile (gemeinsame Objekte des Moduls)
VOR <- list(r = r"()",
            py = r"(from simlev import signals as SG
from simlev import _signals_core as SC)",
            jl = r"(const SG = SL.Signals; const SC = SL.SignalsCore)")

ref_init("signals", gruppe = "gleichlauf")
SZ("kerne_an_den_raendern", "gleitender Mittelwert und EMA an den Rändern (Fensterlänge = n, > n, 0)", vor = VOR, teile = list(
  core_mean_edge = teil(
    r"(list(SimLev:::.roll_mean_core(1:5 + 0, 5L), SimLev:::.roll_mean_core(1:5 + 0, 6L), SimLev:::.roll_mean_core(1:5 + 0, 0L), SimLev:::.roll_mean_core(c(0.1, 0.2, 0.3), 1L)))",
    r"(result = [SC.roll_mean_core(np.arange(1, 6.), 5), SC.roll_mean_core(np.arange(1, 6.), 6), SC.roll_mean_core(np.arange(1, 6.), 0), SC.roll_mean_core(np.array([0.1, 0.2, 0.3]), 1)])",
    r"(result = [SC.roll_mean_core(collect(1.0:5.0), 5), SC.roll_mean_core(collect(1.0:5.0), 6), SC.roll_mean_core(collect(1.0:5.0), 0), SC.roll_mean_core([0.1, 0.2, 0.3], 1)])", inp = ein("signals/core_mean_edge", c())),
  ema_edge = teil(
    r"(list(SimLev:::.ema(1:5 + 0, 5), SimLev:::.ema(1:5 + 0, 6), SimLev:::.ema(1:5 + 0, 0), SimLev:::.ema(c(1, NA, 3, 4, 5, 6), 2)))",
    r"(result = [SG._ema(np.arange(1, 6.), 5), SG._ema(np.arange(1, 6.), 6), SG._ema(np.arange(1, 6.), 0), SG._ema(np.array([1, simlev._r.fmt.NA_REAL, 3, 4, 5, 6]), 2)])",
    r"(result = [SG._ema(collect(1.0:5.0), 5), SG._ema(collect(1.0:5.0), 6), SG._ema(collect(1.0:5.0), 0), SG._ema([1, NA, 3, 4, 5, 6], 2)])", inp = ein("signals/ema_edge", c()))))
SZ("signale_mit_luecken", "signal_ema mit NA, signal_crossover (ema, Band, Verzögerung), signal_drawdown mit NA", vor = VOR, teile = list(
  ema_na = teil(
    r"(signal_ema(x, 20))",
    r"(result = SG.signal_ema(x, n=20))",
    r"(result = SG.signal_ema(x, 20))", inp = ein("signals/ema_na", c("x"))),
  cross_ema = teil(
    r"(signal_crossover(x, 20, 100, type = 'ema', band = 0.3, lag = 1))",
    r"(result = SG.signal_crossover(x, fast=20, slow=100, type='ema', band=0.3, lag=1))",
    r"(result = SG.signal_crossover(x, 20, 100; type = "ema", band = 0.3, lag = 1))", inp = ein("signals/cross_ema", c("x"))),
  dd_na2 = teil(
    r"(signal_drawdown(c(NA, NA, 5, 4, NA, 3), 30, 10, window = 2))",
    r"(result = SG.signal_drawdown(np.array([simlev._r.fmt.NA_REAL, simlev._r.fmt.NA_REAL, 5, 4, simlev._r.fmt.NA_REAL, 3]), sell_dd=30, buy_dd=10, window=2))",
    r"(result = SG.signal_drawdown([NA, NA, 5, 4, NA, 3], 30, 10; window = 2))", inp = ein("signals/dd_na2", c()))))
SZ("signale_kombinieren", "signal_combine mit and (SMA, Volatilität, Momentum) und or (SMA, Drawdown)", vor = VOR, teile = list(
  comb_and = teil(
    r"(signal_combine(signal_sma(x, 200), signal_volatility(x, 20, threshold = 15), signal_momentum(x, 100)))",
    r"(result = SG.signal_combine(SG.signal_sma(x, n=200), SG.signal_volatility(x, n=20, threshold=15), SG.signal_momentum(x, n=100)))",
    r"(result = SG.signal_combine(SG.signal_sma(x, 200), SG.signal_volatility(x, 20; threshold = 15), SG.signal_momentum(x, 100)))", inp = ein("signals/comb_and", c("x"))),
  comb_or = teil(
    r"(signal_combine(signal_sma(x, 200), signal_drawdown(x, 8, 3), op = 'or'))",
    r"(result = SG.signal_combine(SG.signal_sma(x, n=200), SG.signal_drawdown(x, sell_dd=8, buy_dd=3), op='or'))",
    r"(result = SG.signal_combine(SG.signal_sma(x, 200), SG.signal_drawdown(x, 8, 3); op = "or"))", inp = ein("signals/comb_or", c("x")))))
ref_done()

ref_init("signals", gruppe = "fehler")
TB("signal_crossover", "Meldungen und Warnungen von signal_crossover je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("cross_err",
    r"(signal_crossover(x, 100, 100))",
    r"(result = SG.signal_crossover(x, fast=100, slow=100))",
    r"(result = SG.signal_crossover(x, 100, 100))", inp = ein("signals/cross_err", c("x")))))
TB("signal_drawdown", "Meldungen und Warnungen von signal_drawdown je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("dd_err",
    r"(signal_drawdown(x, 10, 20))",
    r"(result = SG.signal_drawdown(x, sell_dd=10, buy_dd=20))",
    r"(result = SG.signal_drawdown(x, 10, 20))", inp = ein("signals/dd_err", c("x")))))
TB("signal_combine", "Meldungen und Warnungen von signal_combine je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("comb_err",
    r"(signal_combine(signal_sma(x, 200), signal_sma(x[1:500], 50)))",
    r"(result = SG.signal_combine(SG.signal_sma(x, n=200), SG.signal_sma(x[:500], n=50)))",
    r"(result = SG.signal_combine(SG.signal_sma(x, 200), SG.signal_sma(x[1:500], 50)))", inp = ein("signals/comb_err", c("x"))),
  zeile("comb_err0",
    r"(signal_combine())",
    r"(result = SG.signal_combine())",
    r"(result = SG.signal_combine())", inp = ein("signals/comb_err0", c()))))
ref_done()

ref_schreiben()
