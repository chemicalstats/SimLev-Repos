# tests/gleichlauf/erzeugen/statistik.R – Bereich statistik als Szenarien und Tabellen (seit 1.4.2; bis 1.4.1 Einzelfälle je Modul und Funktion).
# Statistik: Signalanalyse, Sharpe-Tests, Reality Check, Mindestlänge, Heatmap und Tiefenanalyse (result_analysis),
# Eingabeprüfungen.
#   gleichlauf  Szenarien: je Szenario ein Aufruf bzw. eine kurze Aufrufkette, die mehrere Ergebnisse zugleich prüft
#               (Teile; Name = bisherige Fallkennung). Feld note: "prüft: …"
#   fehler      je Funktion eine Tabelle "Eingabe -> Meldung" (jede Zeile ein eigener Aufruf)
#   ausgabe     print()/summary() als Tabelle
# Herkunft der Erwartung: R. Daten und Hilfen wie in tests/werkzeuge/breite/statistik.R (Breitenprüfung mit allen bisherigen Fällen).
# Aufruf (Repo-Wurzel): LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript tests/gleichlauf/erzeugen/statistik.R
# Ausgabe tests/{gleichlauf,fehler,ausgabe}/faelle/statistik.jsonl.gz (Format: ref_tools.R, Szenarien: szenario_tools.R).
source("tests/gleichlauf/erzeugen/ref_tools.R"); source("tests/gleichlauf/erzeugen/szenario_tools.R")
ref_bereich("statistik")
EIN <- list()   # Eingaben je bisherigem Fall (Momentaufnahme an der Stelle, an der der Fall im alten Generator stand)

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul analysis_tests
# ════════════════════════════════════════════════════════════════════════════════════════════════════
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
EIN[["analysis_tests/sa_basic"]] <- I
EIN[["analysis_tests/sa_breaks"]] <- I
EIN[["analysis_tests/sa_binary"]] <- I
EIN[["analysis_tests/sa_2d"]] <- I
# unsortiert, doppelte Daten, fehlende Kurse, Datum als Text
d2 <- d[c(n:1, 100, 200, 300), ]; d2$aktien[c(50, 51, 400)] <- NA; d2$date <- format(d2$date)
EIN[["analysis_tests/sa_unsorted"]] <- list(d2 = d2)
small <- d[1:200, ]
EIN[["analysis_tests/sa_err_df"]] <- list()
EIN[["analysis_tests/sa_err_len"]] <- list(small = small)
EIN[["analysis_tests/sa_err_target"]] <- list(small = small)
EIN[["analysis_tests/sa_err_target_col"]] <- list(small = small)
EIN[["analysis_tests/sa_err_horizon0"]] <- list(small = small)
EIN[["analysis_tests/sa_err_step"]] <- list(small = small)
EIN[["analysis_tests/sa_err_breaks2"]] <- list(small = small)
EIN[["analysis_tests/sa_err_bins"]] <- list(small = small)
EIN[["analysis_tests/sa_err_few"]] <- list(small = small)
EIN[["analysis_tests/sa_err_const"]] <- I
# ── .hac_cov ────────────────────────────────────────────────────────────────
set.seed(2); Y <- matrix(rnorm(400), 100) + 0.3 * matrix(rnorm(400), 100)
# ── sharpe_test ─────────────────────────────────────────────────────────────
set.seed(1); n <- 3 * 365
p <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
p$a <- 100 * cumprod(1 + rnorm(n, 4e-4, 0.01)); p$b <- 100 * cumprod(1 + rnorm(n, 2e-4, 0.01))
ra <- diff(p$a) / p$a[-n]; rb <- diff(p$b) / p$b[-n]
I <- list(p = p, ra = ra, rb = rb)
PA <- "pa = p[['date', 'a']]; pb = p[['date', 'b']]\n"
EIN[["analysis_tests/st_vec_boot_noseed"]] <- I
EIN[["analysis_tests/st_identical"]] <- I
EIN[["analysis_tests/st_err_mixed"]] <- I
EIN[["analysis_tests/st_err_len"]] <- I
EIN[["analysis_tests/st_err_var"]] <- I
EIN[["analysis_tests/st_err_few"]] <- I
SIM <- "sa = simlev.simulation(p[['date', 'a']], simlev.create_strategy(a=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)))\nsb = simlev.simulation(p[['date', 'b']], simlev.create_strategy(b=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)), dca=simlev.dca_plan(value=100, span=1))\n"
EIN[["analysis_tests/st_sim"]] <- I
# ── .ret_from ───────────────────────────────────────────────────────────────
q <- p[c(1:40, 45:300), c("date", "a")]; q$a[c(5, 6)] <- NA
EIN[["analysis_tests/ret_from"]] <- list(q = q)
# ── overfit_reality_check ───────────────────────────────────────────────────────────
set.seed(4); R <- matrix(rnorm(800 * 10, 0, 0.01), 800); R[, 2] <- R[, 2] + 0.003
I <- list(R = R)
Rn <- R[, 1:4]; colnames(Rn) <- c("a", "b", "c", "d"); Rn[1:10, 4] <- NA; Rn <- cbind(Rn, e = NA)
EIN[["analysis_tests/rc_bench_name"]] <- list(Rn = Rn)
EIN[["analysis_tests/rc_df"]] <- list(Rn = as.data.frame(Rn))
dts <- seq.Date(as.Date("2018-01-01"), by = "day", length.out = 800)
set.seed(1); r1 <- matrix(rnorm(500, 0.0004, 0.01), ncol = 1)
EIN[["analysis_tests/rc_err_bench_num"]] <- I
EIN[["analysis_tests/rc_err_bench_len"]] <- I
EIN[["analysis_tests/rc_err_x"]] <- I
# ── sharpe_min_track_record ────────────────────────────────────────────────────────
set.seed(1); r <- rnorm(520, 0.002, 0.02)
nn <- 10 * 365
dm <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = nn)[seq(1, nn, 2)])
dm$value <- 100 * cumprod(1 + rnorm(nrow(dm), 4e-4, 0.01)); dm$other <- 1
I <- list(r = r, dm = dm)
EIN[["analysis_tests/mt_vec_inf"]] <- I
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
EIN[["analysis_tests/hm_week_all"]] <- I
EIN[["analysis_tests/hm_short"]] <- I
SIMH <- "rr = simlev.simulation(tdd.rename(columns={'value': 'A'}), simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)), dca=simlev.dca_plan(value=50, span=1))\n"
EIN[["analysis_tests/hm_sim"]] <- I

# Vorspann je Szenario bzw. Tabellenzeile (gemeinsame Objekte des Moduls)
VOR <- list(r = r"()",
            py = r"(from simlev import analysis_tests as AT)",
            jl = r"(AT = SL.AnalysisTests)")

ref_init("analysis_tests", gruppe = "gleichlauf")
SZ("signalanalyse", "signal_analysis mit Klassen (Grafikdaten), Grenzen, binärem Signal, zweitem Signal (2D), unsortierten Daten", vor = VOR, teile = list(
  sa_basic = teil(
    r"(sa <- signal_analysis(d, 'mom', 'aktien', horizon = 21, bins = 4, splits = 2); if (!is.null(sa$table2d)) { sa$table2d$n <- unclass(sa$table2d$n); dimnames(sa$table2d$n) <- unname(dimnames(sa$table2d$n)) }; sa)",
    r"(result = AT.signal_analysis(d, 'mom', 'aktien', horizon=21, bins=4, splits=2))",
    r"(result = AT.signal_analysis(d, "mom", "aktien"; horizon = 21, bins = 4, splits = 2))", druck = TRUE, inp = ein("analysis_tests/sa_basic", c("d"))),
  sa_breaks = teil(
    r"(sa <- signal_analysis(d, 'mom', 'aktien', horizon = 10, step = 5, breaks = c(-1, -0.02, 0, 0.03, 1), degree = 3); if (!is.null(sa$table2d)) { sa$table2d$n <- unclass(sa$table2d$n); dimnames(sa$table2d$n) <- unname(dimnames(sa$table2d$n)) }; sa)",
    r"(result = AT.signal_analysis(d, 'mom', 'aktien', horizon=10, step=5, breaks=[-1, -0.02, 0, 0.03, 1], degree=3))",
    r"(result = AT.signal_analysis(d, "mom", "aktien"; horizon = 10, step = 5, breaks = [-1, -0.02, 0, 0.03, 1], degree = 3))", druck = TRUE, inp = ein("analysis_tests/sa_breaks", c("d"))),
  sa_binary = teil(
    r"(sa <- signal_analysis(d, 'inv', 'aktien', horizon = 15); if (!is.null(sa$table2d)) { sa$table2d$n <- unclass(sa$table2d$n); dimnames(sa$table2d$n) <- unname(dimnames(sa$table2d$n)) }; sa)",
    r"(result = AT.signal_analysis(d, 'inv', 'aktien', horizon=15))",
    r"(result = AT.signal_analysis(d, "inv", "aktien"; horizon = 15))", druck = TRUE, inp = ein("analysis_tests/sa_binary", c("d"))),
  sa_2d = teil(
    r"(sa <- signal_analysis(d, d$mom, 'aktien', horizon = 7, bins = 3, signal2 = 'vol', bins2 = 2, splits = 3, degree = 0); if (!is.null(sa$table2d)) { sa$table2d$n <- unclass(sa$table2d$n); dimnames(sa$table2d$n) <- unname(dimnames(sa$table2d$n)) }; sa)",
    r"(result = AT.signal_analysis(d, d['mom'].to_numpy(), 'aktien', horizon=7, bins=3, signal2='vol', bins2=2, splits=3, degree=0))",
    r"(result = AT.signal_analysis(d, d.mom, "aktien"; horizon = 7, bins = 3, signal2 = "vol", bins2 = 2, splits = 3, degree = 0))", druck = TRUE, inp = ein("analysis_tests/sa_2d", c("d"))),
  sa_unsorted = teil(
    r"(sa <- signal_analysis(d2, 'mom', 'aktien', horizon = 30, bins = 6); if (!is.null(sa$table2d)) { sa$table2d$n <- unclass(sa$table2d$n); dimnames(sa$table2d$n) <- unname(dimnames(sa$table2d$n)) }; sa)",
    r"(result = AT.signal_analysis(d2, 'mom', 'aktien', horizon=30, bins=6))",
    r"(result = AT.signal_analysis(d2, "mom", "aktien"; horizon = 30, bins = 6))", druck = TRUE, inp = ein("analysis_tests/sa_unsorted", c("d2")))))
SZ("sharpe_tests", "sharpe_test Bootstrap ohne Startwert, identische Reihen, aus Simulationen; sharpe_min_track_record unendlich; .ret_from", vor = VOR, teile = list(
  st_vec_boot_noseed = teil(
    r"(simlev_seed(9); x <- sharpe_test(ra[1:200], rb[1:200], method = 'bootstrap', B = 100); c(x, SimLev:::.sl_runif(1)))",
    r"(simlev.simlev_seed(9); x = AT.sharpe_test(ra[:200], rb[:200], method='bootstrap', B=100); result = np.append(x.to_numpy(), simlev._lib.runif(1)))",
    r"(SL.simlev_seed(9); x = AT.sharpe_test(ra[1:200], rb[1:200]; method = "bootstrap", B = 100); result = vcat(x.values, SL.SLib.runif(1)))", inp = ein("analysis_tests/st_vec_boot_noseed", c("ra", "rb"))),
  st_identical = teil(
    r"(sharpe_test(ra, ra, ppy = 365))",
    r"(result = AT.sharpe_test(ra, ra, ppy=365))",
    r"(result = AT.sharpe_test(ra, ra; ppy = 365))", inp = ein("analysis_tests/st_identical", c("ra"))),
  st_sim = teil(
    r"(sa <- simulation(p[, c('date', 'a')], create_strategy(a = asset_config('etf', 'bnh', spread = 0.1)))
  sb <- simulation(p[, c('date', 'b')], create_strategy(b = asset_config('etf', 'bnh', spread = 0.1)), dca = dca_plan(value = 100, span = 1))
  list(sharpe_test(sa, sb, frequency = 'month'), sharpe_test(sa, sb, frequency = 'day'), sharpe_min_track_record(sb), sharpe_min_track_record(sa, frequency = 'day', target = 0.2)))",
    r"(sa = simlev.simulation(p[['date', 'a']], simlev.create_strategy(a=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)))
sb = simlev.simulation(p[['date', 'b']], simlev.create_strategy(b=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)), dca=simlev.dca_plan(value=100, span=1))
result = [AT.sharpe_test(sa, sb, frequency='month'), AT.sharpe_test(sa, sb, frequency='day'), AT.sharpe_min_track_record(sb), AT.sharpe_min_track_record(sa, frequency='day', target=0.2)])",
    r"(sa = SL.simulation(SL.RFrame("date" => p.date, "a" => p.a), SL.create_strategy("a" => SL.asset_config("etf", "bnh", spread = 0.1)))
sb = SL.simulation(SL.RFrame("date" => p.date, "b" => p.b), SL.create_strategy("b" => SL.asset_config("etf", "bnh", spread = 0.1)); dca = SL.dca_plan(; value = 100, span = 1))
result = Any[AT.sharpe_test(sa, sb; frequency = "month"), AT.sharpe_test(sa, sb; frequency = "day"), AT.sharpe_min_track_record(sb), AT.sharpe_min_track_record(sa; frequency = "day", target = 0.2)])", inp = ein("analysis_tests/st_sim", c("p"))),
  mt_vec_inf = teil(
    r"(sharpe_min_track_record(r, target = 3))",
    r"(result = AT.sharpe_min_track_record(r, target=3))",
    r"(result = AT.sharpe_min_track_record(r; target = 3))", inp = ein("analysis_tests/mt_vec_inf", c("r"))),
  ret_from = teil(
    r"(list(SimLev:::.ret_from(q, 'week'), SimLev:::.ret_from(q, 'month'), SimLev:::.ret_from(q, 'day'), SimLev:::.ret_from(q, 'month', 2), SimLev:::.ret_from(1:5 / 100, 'day')))",
    r"(result = [AT._ret_from(q, 'week'), AT._ret_from(q, 'month'), AT._ret_from(q, 'day'), AT._ret_from(q, 'month', 2), AT._ret_from(np.arange(1, 6) / 100, 'day')])",
    r"(result = Any[AT._ret_from(q, "week"), AT._ret_from(q, "month"), AT._ret_from(q, "day"), AT._ret_from(q, "month", 2), AT._ret_from(collect(1:5) ./ 100, "day")])", inp = ein("analysis_tests/ret_from", c("q")))))
SZ("reality_check", "overfit_reality_check mit benanntem Vergleich und mit Tabelle", vor = VOR, teile = list(
  rc_bench_name = teil(
    r"(overfit_reality_check(Rn, benchmark = 'c', B = 100, frequency = 'day', seed = 1))",
    r"(result = AT.overfit_reality_check(Rn, benchmark='c', B=100, frequency='day', seed=1))",
    r"(result = AT.overfit_reality_check(Rn; benchmark = "c", B = 100, frequency = "day", seed = 1))", druck = TRUE, inp = ein("analysis_tests/rc_bench_name", c("Rn"))),
  rc_df = teil(
    r"(overfit_reality_check(as.data.frame(Rn), B = 50, frequency = 'day', seed = 5))",
    r"(result = AT.overfit_reality_check(Rn, B=50, frequency='day', seed=5))",
    r"(result = AT.overfit_reality_check(Rn; B = 50, frequency = "day", seed = 5))", druck = TRUE, inp = ein("analysis_tests/rc_df", c("Rn")))))
SZ("heatmap", "result_heatmap auf Wochen und aus einer Simulation (Grafikdaten)", vor = VOR, teile = list(
  hm_week_all = teil(
    r"(result_heatmap(wk))",
    r"(result = AT.result_heatmap(wk))",
    r"(result = AT.result_heatmap(wk))", druck = TRUE, inp = ein("analysis_tests/hm_week_all", c("wk"))),
  hm_sim = teil(
    r"(rr <- simulation(setNames(tdd, c('date', 'A')), create_strategy(A = asset_config('etf', 'bnh', spread = 0.1)), dca = dca_plan(value = 50, span = 1)); result_heatmap(rr, inflation = 1.5))",
    r"(rr = simlev.simulation(tdd.rename(columns={'value': 'A'}), simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1)), dca=simlev.dca_plan(value=50, span=1))
result = AT.result_heatmap(rr, inflation=1.5))",
    r"(rr = SL.simulation(SL.RFrame("date" => tdd.date, "A" => tdd.value), SL.create_strategy("A" => SL.asset_config("etf", "bnh", spread = 0.1)); dca = SL.dca_plan(; value = 50, span = 1))
result = AT.result_heatmap(rr; inflation = 1.5))", druck = TRUE, inp = ein("analysis_tests/hm_sim", c("tdd")))))
ref_done()

ref_init("analysis_tests", gruppe = "fehler")
TB("signal_analysis", "Meldungen und Warnungen von signal_analysis je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("sa_err_df",
    r"(signal_analysis(list(a = 1), 'a', 'b'))",
    r"(result = AT.signal_analysis({'a': 1}, 'a', 'b'))",
    r"(result = AT.signal_analysis(SL.RList("a" => 1), "a", "b"))", inp = ein("analysis_tests/sa_err_df", c())),
  zeile("sa_err_len",
    r"(signal_analysis(small, small$mom[-1], 'aktien'))",
    r"(result = AT.signal_analysis(small, small['mom'].to_numpy()[1:], 'aktien'))",
    r"(result = AT.signal_analysis(small, small.mom[2:end], "aktien"))", inp = ein("analysis_tests/sa_err_len", c("small"))),
  zeile("sa_err_target",
    r"(signal_analysis(small, 'mom', 2))",
    r"(result = AT.signal_analysis(small, 'mom', 2))",
    r"(result = AT.signal_analysis(small, "mom", 2))", inp = ein("analysis_tests/sa_err_target", c("small"))),
  zeile("sa_err_target_col",
    r"(signal_analysis(small, 'mom', 'x'))",
    r"(result = AT.signal_analysis(small, 'mom', 'x'))",
    r"(result = AT.signal_analysis(small, "mom", "x"))", inp = ein("analysis_tests/sa_err_target_col", c("small"))),
  zeile("sa_err_horizon0",
    r"(signal_analysis(small, 'mom', 'aktien', horizon = 0))",
    r"(result = AT.signal_analysis(small, 'mom', 'aktien', horizon=0))",
    r"(result = AT.signal_analysis(small, "mom", "aktien"; horizon = 0))", inp = ein("analysis_tests/sa_err_horizon0", c("small"))),
  zeile("sa_err_step",
    r"(signal_analysis(small, 'mom', 'aktien', step = 0))",
    r"(result = AT.signal_analysis(small, 'mom', 'aktien', step=0))",
    r"(result = AT.signal_analysis(small, "mom", "aktien"; step = 0))", inp = ein("analysis_tests/sa_err_step", c("small"))),
  zeile("sa_err_breaks2",
    r"(signal_analysis(small, 'mom', 'aktien', breaks = c(0, 2, 1)))",
    r"(result = AT.signal_analysis(small, 'mom', 'aktien', breaks=[0, 2, 1]))",
    r"(result = AT.signal_analysis(small, "mom", "aktien"; breaks = [0, 2, 1]))", inp = ein("analysis_tests/sa_err_breaks2", c("small"))),
  zeile("sa_err_bins",
    r"(signal_analysis(small, 'mom', 'aktien', bins = 1))",
    r"(result = AT.signal_analysis(small, 'mom', 'aktien', bins=1))",
    r"(result = AT.signal_analysis(small, "mom", "aktien"; bins = 1))", inp = ein("analysis_tests/sa_err_bins", c("small"))),
  zeile("sa_err_few",
    r"(signal_analysis(small, 'mom', 'aktien', horizon = 21))",
    r"(result = AT.signal_analysis(small, 'mom', 'aktien', horizon=21))",
    r"(result = AT.signal_analysis(small, "mom", "aktien"; horizon = 21))", inp = ein("analysis_tests/sa_err_few", c("small"))),
  zeile("sa_err_const",
    r"(signal_analysis(d, 'const', 'aktien'))",
    r"(result = AT.signal_analysis(d, 'const', 'aktien'))",
    r"(result = AT.signal_analysis(d, "const", "aktien"))", inp = ein("analysis_tests/sa_err_const", c("d")))))
TB("sharpe_test", "Meldungen und Warnungen von sharpe_test je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("st_err_mixed",
    r"(sharpe_test(ra, p[, c('date', 'a')]))",
    r"(pa = p[['date', 'a']]; pb = p[['date', 'b']]
result = AT.sharpe_test(ra, pa))",
    r"(pa = SL.RFrame("date" => p.date, "a" => p.a); pb = SL.RFrame("date" => p.date, "b" => p.b)
result = AT.sharpe_test(ra, pa))", inp = ein("analysis_tests/st_err_mixed", c("p", "ra"))),
  zeile("st_err_len",
    r"(sharpe_test(ra[1:1000], ra[1:500]))",
    r"(result = AT.sharpe_test(ra[:1000], ra[:500]))",
    r"(result = AT.sharpe_test(ra[1:1000], ra[1:500]))", inp = ein("analysis_tests/st_err_len", c("ra"))),
  zeile("st_err_var",
    r"(sharpe_test(ra[1:500], rep(0.001, 500)))",
    r"(result = AT.sharpe_test(ra[:500], np.repeat(0.001, 500)))",
    r"(result = AT.sharpe_test(ra[1:500], fill(0.001, 500)))", inp = ein("analysis_tests/st_err_var", c("ra"))),
  zeile("st_err_few",
    r"(sharpe_test(ra[1:3], ra[3:1] + 0.01))",
    r"(result = AT.sharpe_test(ra[:3], ra[2::-1] + 0.01))",
    r"(result = AT.sharpe_test(ra[1:3], ra[3:-1:1] .+ 0.01))", inp = ein("analysis_tests/st_err_few", c("ra")))))
TB("overfit_reality_check", "Meldungen und Warnungen von overfit_reality_check je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("rc_err_bench_num",
    r"(overfit_reality_check(R, benchmark = 11, B = 10, seed = 1))",
    r"(result = AT.overfit_reality_check(R, benchmark=11, B=10, seed=1))",
    r"(result = AT.overfit_reality_check(R; benchmark = 11, B = 10, seed = 1))", inp = ein("analysis_tests/rc_err_bench_num", c("R"))),
  zeile("rc_err_bench_len",
    r"(overfit_reality_check(R, benchmark = c(0.1, 0.2), B = 10, seed = 1))",
    r"(result = AT.overfit_reality_check(R, benchmark=[0.1, 0.2], B=10, seed=1))",
    r"(result = AT.overfit_reality_check(R; benchmark = [0.1, 0.2], B = 10, seed = 1))", inp = ein("analysis_tests/rc_err_bench_len", c("R"))),
  zeile("rc_err_x",
    r"(overfit_reality_check(letters, B = 10))",
    r"(result = AT.overfit_reality_check(np.array(list('abcdefghijklmnopqrstuvwxyz'), dtype=object), B=10))",
    r"(result = AT.overfit_reality_check(string.(collect("abcdefghijklmnopqrstuvwxyz")); B = 10))", inp = ein("analysis_tests/rc_err_x", c()))))
TB("result_heatmap", "Meldungen und Warnungen von result_heatmap je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("hm_short",
    r"(result_heatmap(tdd[1:300, ]))",
    r"(result = AT.result_heatmap(tdd.iloc[:300]))",
    r"(result = AT.result_heatmap(SL.rows(tdd, 1:300)))", inp = ein("analysis_tests/hm_short", c("tdd")))))
ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul deep_analysis
# ════════════════════════════════════════════════════════════════════════════════════════════════════
P <- "from simlev import deep_analysis as DA\n"
JH <- "DA = SL.DeepAnalysis\n"   # Kopf des Julia-Codes (jl)
SIM_J <- 'a = SL.simulation(d, SL.create_strategy("A" => SL.asset_config("etf", "bnh"; spread = 0)))
b = SL.simulation(d, SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.6, spread = 0.1), "B" => SL.asset_config("etf", "bnh", 0.4, spread = 0.1)); dca = SL.dca_plan(; value = 300, span = 1), rebalance = SL.rebalance_plan(; span = 1, unit = "year"))
'
ST_J <- 'st = SL.create_strategy("A" => SL.asset_config("etf", "bnh"; share = 1, spread = 0))\n'
set.seed(1); n <- 558   # bis 1.4.1 n <- 3 * 365 + 20 (kürzer, Abdeckung gleich)
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
EIN[["deep_analysis/da_sim_df_bench_infl"]] <- I
EIN[["deep_analysis/da_sim_nofilled"]] <- I
# Kalendertage mit Luecken: Engine fuellt auf (filled), .da_series uebernimmt
td <- d[!format(d$date, "%u") %in% c("6", "7"), c("date", "A")]
# data.frame-Eingaben
x1 <- data.frame(date = d$date, value = d$A)
x2 <- data.frame(date = d$date[200:n], Kurs = d$B[200:n], Volumen = 1:(n - 199))
rf <- data.frame(date = as.Date(c("2012-01-01", "2013-06-01", "2014-01-01")), rate = c(0, 3, 1.5))
cpi <- data.frame(date = seq.Date(as.Date("2011-12-01"), by = "month", length.out = 48), value = 100 * 1.003^(0:47))
EIN[["deep_analysis/da_df_cpi_vec"]] <- list(x2 = x2, cpi = cpi)
# Handelstage, series_align (attr filled), unsortiert, doppelt, NA innen, Text-Datum
tdv <- data.frame(date = td$date, value = td$A)
EIN[["deep_analysis/da_df_aligned"]] <- list(tdv = tdv)
xm <- x1[c(n:1, 100, 500, 900), ]; xm$value[c(n - 99, n - 499)] <- xm$value[c(n - 99, n - 499)] * 1.05
xm$value[c(10, 11, 12, 300)] <- NA; xm$value[1:3] <- NA; xm$date <- format(xm$date)
EIN[["deep_analysis/da_df_messy"]] <- list(xm = xm)
mo <- data.frame(date = seq.Date(as.Date("1791-01-31"), by = "month", length.out = 120)); set.seed(2); mo$v <- 100 * cumprod(1 + rnorm(120, 0.004, 0.03))
EIN[["deep_analysis/da_short_series"]] <- list(x1 = x1)
up <- data.frame(date = d$date[1:500], value = 100 * 1.0004^(0:499))
EIN[["deep_analysis/da_summary_nodd"]] <- list(up = up, x1 = x1)
# Extremfaelle der MWRR: Beinahe-Totalverlust und sehr hohe Rendite mit Sparplan
dd1 <- seq.Date(as.Date("2020-01-01"), as.Date("2023-12-31"), by = "day"); p1 <- rep(100, length(dd1)); p1[dd1 >= as.Date("2023-12-20")] <- 1e-3
dd2 <- seq.Date(as.Date("2020-01-01"), as.Date("2020-03-31"), by = "day"); p2 <- 100 * 3^(seq_along(dd2) / length(dd2))
ex <- list(e1 = data.frame(date = dd1, A = p1), e2 = data.frame(date = dd2, A = p2))
ST <- "st = simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=1, spread=0))\n"
EIN[["deep_analysis/da_bench_self_only"]] <- list(x1 = x1)
EIN[["deep_analysis/da_err_onecol"]] <- list()
EIN[["deep_analysis/da_err_nonum"]] <- I
EIN[["deep_analysis/da_err_value_chr"]] <- I
EIN[["deep_analysis/da_err_value_lgl"]] <- I
EIN[["deep_analysis/da_err_text_kurs"]] <- I
EIN[["deep_analysis/da_err_factor"]] <- I
EIN[["deep_analysis/da_err_novalues"]] <- I
EIN[["deep_analysis/da_err_nonpos"]] <- list(x1 = x1)
EIN[["deep_analysis/da_err_one"]] <- list(x1 = x1)
EIN[["deep_analysis/da_err_short"]] <- list(x1 = x1)
EIN[["deep_analysis/da_err_type"]] <- list()
EIN[["deep_analysis/da_err_empty"]] <- list()
EIN[["deep_analysis/da_err_bench_name"]] <- list(x1 = x1)
EIN[["deep_analysis/da_err_bench_exists"]] <- list(x1 = x1)
EIN[["deep_analysis/da_err_bench_common"]] <- list(x1 = x1)
EIN[["deep_analysis/da_err_rolling"]] <- list(x1 = x1)
EIN[["deep_analysis/da_err_var"]] <- list(x1 = x1)
EIN[["deep_analysis/da_err_cpi_late"]] <- list(x1 = x1, cpi = cpi)
EIN[["deep_analysis/da_err_plot_series"]] <- list(x1 = x1)
EIN[["deep_analysis/da_err_plot_metric"]] <- list(x1 = x1)

# Vorspann je Szenario bzw. Tabellenzeile (gemeinsame Objekte des Moduls)
VOR <- list(r = r"()",
            py = r"(from simlev import deep_analysis as DA)",
            jl = r"(DA = SL.DeepAnalysis)")

ref_init("deep_analysis", gruppe = "gleichlauf")
SZ("tiefenanalyse_simulation", "result_analysis aus Simulationen mit Vergleich und Inflation, ohne filled", vor = VOR, gemein = teil(
    r"(a <- simulation(d, create_strategy(A = asset_config('etf', 'bnh', spread = 0)))
b <- simulation(d, create_strategy(A = asset_config('etf', 'bnh', 0.6, spread = 0.1), B = asset_config('etf', 'bnh', 0.4, spread = 0.1)), dca = dca_plan(value = 300, span = 1), rebalance = rebalance_plan(span = 1, unit = 'year')))",
    r"(a = simlev.simulation(d, simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', spread=0)))
b = simlev.simulation(d, simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=0.6, spread=0.1), B=simlev.asset_config(asset_class='etf', trading='bnh', share=0.4, spread=0.1)), dca=simlev.dca_plan(value=300, span=1), rebalance=simlev.rebalance_plan(span=1, unit='year')))",
    r"(a = SL.simulation(d, SL.create_strategy("A" => SL.asset_config("etf", "bnh"; spread = 0)))
b = SL.simulation(d, SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.6, spread = 0.1), "B" => SL.asset_config("etf", "bnh", 0.4, spread = 0.1)); dca = SL.dca_plan(; value = 300, span = 1), rebalance = SL.rebalance_plan(; span = 1, unit = "year")))"), teile = list(
  da_sim_df_bench_infl = teil(
    r"(result_analysis(b, benchmark = d[, c('date', 'B')], inflation = 2, risk_free = 2, rolling_years = 0.5))",
    r"(result = DA.result_analysis(b, benchmark=d[['date', 'B']], inflation=2, risk_free=2, rolling_years=0.5))",
    r"(result = DA.result_analysis(b; benchmark = SL.RFrame("date" => d.date, "B" => d.B), inflation = 2, risk_free = 2, rolling_years = 0.5))", druck = TRUE, inp = ein("deep_analysis/da_sim_df_bench_infl", c("d"))),
  da_sim_nofilled = teil(
    r"(a$filled <- NULL; result_analysis(a))",
    r"(a.filled = None
result = DA.result_analysis(a))",
    r"(a = DA._without_filled(a)
result = DA.result_analysis(a))", druck = TRUE, inp = ein("deep_analysis/da_sim_nofilled", c("d")))))
SZ("tiefenanalyse_tabellen", "result_analysis mit CPI-Vektor, unsauberen Daten, kurzen Reihen, nur sich selbst als Vergleich, ausgerichteter Tabelle (Grafikdaten)", vor = VOR, teile = list(
  da_df_cpi_vec = teil(
    r"(result_analysis(x2, inflation = setNames(cpi$value, format(cpi$date)), rolling_years = 1))",
    r"(result = DA.result_analysis(x2, inflation=pd.Series(cpi['value'].to_numpy(), index=np.datetime_as_string(cpi['date'].to_numpy())), rolling_years=1))",
    r"(result = DA.result_analysis(x2; inflation = SL.RVector(cpi.value; names = string.(cpi.date)), rolling_years = 1))", druck = TRUE, inp = ein("deep_analysis/da_df_cpi_vec", c("x2", "cpi"))),
  da_df_messy = teil(
    r"(result_analysis(xm, rolling_years = 1))",
    r"(result = DA.result_analysis(xm, rolling_years=1))",
    r"(result = DA.result_analysis(xm; rolling_years = 1))", druck = TRUE, inp = ein("deep_analysis/da_df_messy", c("xm"))),
  da_short_series = teil(
    r"(result_analysis(list(k = x1[1:40, ], l = x1[20:60, ]), benchmark = 'k', rolling_years = 1))",
    r"(result = DA.result_analysis({'k': x1.iloc[:40], 'l': x1.iloc[19:60]}, benchmark='k', rolling_years=1))",
    r"(result = DA.result_analysis(SL.RList("k" => SL.rows(x1, 1:40), "l" => SL.rows(x1, 20:60)); benchmark = "k", rolling_years = 1))", druck = TRUE, inp = ein("deep_analysis/da_short_series", c("x1"))),
  da_bench_self_only = teil(
    r"(result_analysis(x1[1:400, ], benchmark = 'Strategie', var_levels = 0.05))",
    r"(result = DA.result_analysis(x1.iloc[:400], benchmark='Strategie', var_levels=0.05))",
    r"(result = DA.result_analysis(SL.rows(x1, 1:400); benchmark = "Strategie", var_levels = 0.05))", druck = TRUE, inp = ein("deep_analysis/da_bench_self_only", c("x1"))),
  da_df_aligned = teil(
    r"(al <- series_align(value = tdv); result_analysis(list(al = al, raw = tdv), benchmark = 'raw', risk_free = 4, rolling_years = 1))",
    r"(from simlev.data_prep import series_align
al = series_align(value=tdv)
result = DA.result_analysis({'al': al, 'raw': tdv}, benchmark='raw', risk_free=4, rolling_years=1))",
    r"(al = SL.DataPrep.series_align(value = tdv)
result = DA.result_analysis(SL.RList("al" => al, "raw" => tdv); benchmark = "raw", risk_free = 4, rolling_years = 1))", druck = TRUE, inp = ein("deep_analysis/da_df_aligned", c("tdv")))))
# NaN und später NA in der Reihe (seit 1.6.3 rechnet Julia cummax wie R und Python; ohne Zufall)
dn <- data.frame(date = as.Date("2010-01-01") + 0:799, value = 100 * cumprod(1 + sin(seq_len(800) / 7) / 100))
dn$value[300] <- NaN; dn$value[420] <- NA
SZ("tiefenanalyse_luecken", "result_analysis mit NaN und später NA in der Reihe: Drawdown-Episoden, rollierende Kennzahlen, Druck", vor = VOR, teile = list(
  da_nan_na = teil(
    r"(result_analysis(dn, rolling_years = 1))",
    r"(result = DA.result_analysis(dn, rolling_years=1))",
    r"(result = DA.result_analysis(dn; rolling_years = 1))", druck = TRUE, inp = list(dn = dn))))
ref_done()

ref_init("deep_analysis", gruppe = "fehler")
TB("result_analysis", "Meldungen und Warnungen von result_analysis je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("da_err_onecol",
    r"(result_analysis(data.frame(x = 'a;b')))",
    r"(result = DA.result_analysis(pd.DataFrame({'x': ['a;b']})))",
    r"(result = DA.result_analysis(SL.RFrame("x" => ["a;b"])))", inp = ein("deep_analysis/da_err_onecol", c())),
  zeile("da_err_nonum",
    r"(result_analysis(data.frame(date = d$date[1:5], v = letters[1:5])))",
    r"(result = DA.result_analysis(pd.DataFrame({'date': d['date'][:5], 'v': list('abcde')})))",
    r"(result = DA.result_analysis(SL.RFrame("date" => d.date[1:5], "v" => ["a", "b", "c", "d", "e"])))", inp = ein("deep_analysis/da_err_nonum", c("d"))),
  zeile("da_err_value_chr",
    r"(result_analysis(data.frame(date = d$date[1:5], value = letters[1:5])))",
    r"(result = DA.result_analysis(pd.DataFrame({'date': d['date'][:5], 'value': list('abcde')})))",
    r"(result = DA.result_analysis(SL.RFrame("date" => d.date[1:5], "value" => ["a", "b", "c", "d", "e"])))", inp = ein("deep_analysis/da_err_value_chr", c("d"))),
  zeile("da_err_value_lgl",
    r"(result_analysis(data.frame(date = d$date[1:5], value = TRUE)))",
    r"(result = DA.result_analysis(pd.DataFrame({'date': d['date'][:5], 'value': True})))",
    r"(result = DA.result_analysis(SL.RFrame("date" => d.date[1:5], "value" => fill(true, 5))))", inp = ein("deep_analysis/da_err_value_lgl", c("d"))),
  zeile("da_err_text_kurs",
    r"(result_analysis(data.frame(date = d$date[1:5], Kurs = c('1,5', '2,5', '3,1', '4', '5'), Vol = 1:5)))",
    r"(result = DA.result_analysis(pd.DataFrame({'date': d['date'][:5], 'Kurs': ['1,5', '2,5', '3,1', '4', '5'], 'Vol': np.arange(1, 6)})))",
    r"(result = DA.result_analysis(SL.RFrame("date" => d.date[1:5], "Kurs" => ["1,5", "2,5", "3,1", "4", "5"], "Vol" => collect(1:5))))", inp = ein("deep_analysis/da_err_text_kurs", c("d"))),
  zeile("da_err_factor",
    r"(result_analysis(data.frame(date = d$date[1:5], value = factor(c('1,5', '2,5', '3,1', '4', '5')))))",
    r"(result = DA.result_analysis(pd.DataFrame({'date': d['date'][:5], 'value': pd.Categorical(['1,5', '2,5', '3,1', '4', '5'])})))",
    r"(result = DA.result_analysis(SL.RFrame("date" => d.date[1:5], "value" => ["1,5", "2,5", "3,1", "4", "5"])))", inp = ein("deep_analysis/da_err_factor", c("d"))),
  zeile("da_err_novalues",
    r"(result_analysis(data.frame(date = d$date[1:5], value = NA_real_)))",
    r"(result = DA.result_analysis(pd.DataFrame({'date': d['date'][:5], 'value': simlev._r.fmt.NA_REAL})))",
    r"(result = DA.result_analysis(SL.RFrame("date" => d.date[1:5], "value" => fill(SL.NA, 5))))", inp = ein("deep_analysis/da_err_novalues", c("d"))),
  zeile("da_err_nonpos",
    r"(z <- x1; z$value[100] <- 0; result_analysis(z))",
    r"(z = x1.copy(); z.loc[99, 'value'] = 0.0
result = DA.result_analysis(z))",
    r"(z = copy(x1); z.value[100] = 0.0
result = DA.result_analysis(z))", inp = ein("deep_analysis/da_err_nonpos", c("x1"))),
  zeile("da_err_one",
    r"(result_analysis(x1[1, ]))",
    r"(result = DA.result_analysis(x1.iloc[:1]))",
    r"(result = DA.result_analysis(SL.rows(x1, 1:1)))", inp = ein("deep_analysis/da_err_one", c("x1"))),
  zeile("da_err_short",
    r"(result_analysis(x1[1:2, ]))",
    r"(result = DA.result_analysis(x1.iloc[:2]))",
    r"(result = DA.result_analysis(SL.rows(x1, 1:2)))", inp = ein("deep_analysis/da_err_short", c("x1"))),
  zeile("da_err_type",
    r"(result_analysis(list(1)))",
    r"(result = DA.result_analysis([1]))",
    r"(result = DA.result_analysis(Any[1]))", inp = ein("deep_analysis/da_err_type", c())),
  zeile("da_err_empty",
    r"(result_analysis(list()))",
    r"(result = DA.result_analysis([]))",
    r"(result = DA.result_analysis(Any[]))", inp = ein("deep_analysis/da_err_empty", c())),
  zeile("da_err_bench_name",
    r"(result_analysis(list(a = x1, b = x1), benchmark = 'c'))",
    r"(result = DA.result_analysis({'a': x1, 'b': x1}, benchmark='c'))",
    r"(result = DA.result_analysis(SL.RList("a" => x1, "b" => x1); benchmark = "c"))", inp = ein("deep_analysis/da_err_bench_name", c("x1"))),
  zeile("da_err_bench_exists",
    r"(result_analysis(list(Strategie = x1, Benchmark = x1), benchmark = x1))",
    r"(result = DA.result_analysis({'Strategie': x1, 'Benchmark': x1}, benchmark=x1))",
    r"(result = DA.result_analysis(SL.RList("Strategie" => x1, "Benchmark" => x1); benchmark = x1))", inp = ein("deep_analysis/da_err_bench_exists", c("x1"))),
  zeile("da_err_bench_common",
    r"(b2 <- x1; b2$date <- b2$date + 3000; result_analysis(x1, benchmark = b2))",
    r"(b2 = x1.assign(date=x1['date'] + pd.Timedelta(days=3000))
result = DA.result_analysis(x1, benchmark=b2))",
    r"(b2 = copy(x1); b2.date = b2.date .+ Day(3000)
result = DA.result_analysis(x1; benchmark = b2))", inp = ein("deep_analysis/da_err_bench_common", c("x1"))),
  zeile("da_err_rolling",
    r"(result_analysis(x1, rolling_years = 0))",
    r"(result = DA.result_analysis(x1, rolling_years=0))",
    r"(result = DA.result_analysis(x1; rolling_years = 0))", inp = ein("deep_analysis/da_err_rolling", c("x1"))),
  zeile("da_err_var",
    r"(result_analysis(x1, var_levels = c(0.05, 1)))",
    r"(result = DA.result_analysis(x1, var_levels=[0.05, 1]))",
    r"(result = DA.result_analysis(x1; var_levels = [0.05, 1]))", inp = ein("deep_analysis/da_err_var", c("x1"))),
  zeile("da_err_cpi_late",
    r"(result_analysis(x1, inflation = cpi[cpi$date >= as.Date('2013-01-01'), ]))",
    r"(result = DA.result_analysis(x1, inflation=cpi[cpi['date'] >= np.datetime64('2013-01-01')]))",
    r"(result = DA.result_analysis(x1; inflation = SL.rows(cpi, cpi.date .>= Date(2013, 1, 1))))", inp = ein("deep_analysis/da_err_cpi_late", c("x1", "cpi"))),
  zeile("da_err_plot_series",
    r"(pdf(NULL); on.exit(dev.off()); plot(result_analysis(x1[1:400, ]), type = 'monthly', series = 3))",
    r"(result = DA.result_analysis(x1.iloc[:400]).plot(type='monthly', series=3))",
    r"(result = SL.r_plot(DA.result_analysis(SL.rows(x1, 1:400)); type = "monthly", series = 3, file = nothing))", inp = ein("deep_analysis/da_err_plot_series", c("x1"))),
  zeile("da_err_plot_metric",
    r"(pdf(NULL); on.exit(dev.off()); plot(result_analysis(x1[1:400, ]), metric = 'x'))",
    r"(result = DA.result_analysis(x1.iloc[:400]).plot(metric='x'))",
    r"(result = SL.r_plot(DA.result_analysis(SL.rows(x1, 1:400)); metric = "x", file = nothing))", inp = ein("deep_analysis/da_err_plot_metric", c("x1")))))
ref_done()

ref_init("deep_analysis", gruppe = "ausgabe")
TB("result_analysis", "Druckausgabe von result_analysis je Zeile", vor = VOR, zeilen = list(
  zeile("da_summary_nodd",
    r"(summary(result_analysis(list(up = up, x = x1[1:500, ]), benchmark = x1, rolling_years = 1)))",
    r"(result = DA.result_analysis({'up': up, 'x': x1.iloc[:500]}, benchmark=x1, rolling_years=1).summary())",
    r"(result = SL.r_summary(DA.result_analysis(SL.RList("up" => up, "x" => SL.rows(x1, 1:500)); benchmark = x1, rolling_years = 1)))", inp = ein("deep_analysis/da_summary_nodd", c("up", "x1")))))
ref_done()

ref_schreiben()
