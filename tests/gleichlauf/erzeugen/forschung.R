# tests/gleichlauf/erzeugen/forschung.R – Bereich forschung als Szenarien und Tabellen (seit 1.4.2; bis 1.4.1 Einzelfälle je Modul und Funktion).
# Forschung: Parametersuche (param_space, param_search, Plateau), Overfitting-Diagnosen (PBO, Walk-Forward,
# Sharpe-Korrekturen, Bootstrap-Prüfung) und Sensitivität (Gitter, Umschichtung, Hebel), Eingabeprüfungen.
#   gleichlauf  Szenarien: je Szenario ein Aufruf bzw. eine kurze Aufrufkette, die mehrere Ergebnisse zugleich prüft
#               (Teile; Name = bisherige Fallkennung). Feld note: "prüft: …"
#   fehler      je Funktion eine Tabelle "Eingabe -> Meldung" (jede Zeile ein eigener Aufruf)
#   ausgabe     print()/summary() als Tabelle
# Herkunft der Erwartung: R. Daten und Hilfen wie in tests/werkzeuge/breite/forschung.R (Breitenprüfung mit allen bisherigen Fällen).
# Aufruf (Repo-Wurzel): LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript tests/gleichlauf/erzeugen/forschung.R
# Ausgabe tests/{gleichlauf,fehler,ausgabe}/faelle/forschung.jsonl.gz (Format: ref_tools.R, Szenarien: szenario_tools.R).
source("tests/gleichlauf/erzeugen/ref_tools.R"); source("tests/gleichlauf/erzeugen/szenario_tools.R")
ref_bereich("forschung")
EIN <- list()   # Eingaben je bisherigem Fall (Momentaufnahme an der Stelle, an der der Fall im alten Generator stand)

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul param_search
# ════════════════════════════════════════════════════════════════════════════════════════════════════
P <- paste0("import simlev.param_search as PS\nimport simlev.overfitting as OF\nimport simlev.signals as SG\n",
            "from simlev.config import create_strategy, asset_config\n")
py <- function(code) paste0(P, code)
J <- "const PS = SL.ParamSearch\n"
jl <- function(code) paste0(J, code)
# ── Suchraum ────────────────────────────────────────────────────────────────
SP <- "sp <- param_space(n = param_range(50, 400, n = 8, integer = TRUE, log = TRUE), band = c(0, 1, 2), w = param_range(0.3, 0.9, step = 0.1), s = c('x', 'yy'), f = c(TRUE, FALSE), m = param_range(1, 2))"
SPP <- "sp = PS.param_space(n=PS.param_range(50, 400, n=8, integer=True, log=True), band=[0.0, 1.0, 2.0], w=PS.param_range(0.3, 0.9, step=0.1), s=['x', 'yy'], f=[True, False], m=PS.param_range(1, 2))\n"
SPJ <- 'sp = PS.param_space(n = PS.param_range(50, 400; n = 8, integer = true, log = true), band = [0.0, 1.0, 2.0], w = PS.param_range(0.3, 0.9; step = 0.1), s = ["x", "yy"], f = [true, false], m = PS.param_range(1, 2))\n'
EIN[["param_search/space_long"]] <- list()
EIN[["param_search/space_err0"]] <- list()
EIN[["param_search/space_err2"]] <- list()
EIN[["param_search/range_err_n0"]] <- list()
EIN[["param_search/range_err_ord"]] <- list()
EIN[["param_search/range_err_log"]] <- list()
EIN[["param_search/range_err_step"]] <- list()
EIN[["param_search/levels"]] <- list()
SP2 <- "sp <- param_space(a = param_range(1, 5, n = 5, integer = TRUE), b = c('x', 'y'))"
SP2P <- "sp = PS.param_space(a=PS.param_range(1, 5, n=5, integer=True), b=['x', 'y'])\n"
SP2J <- 'sp = PS.param_space(a = PS.param_range(1, 5; n = 5, integer = true), b = ["x", "y"])\n'
EIN[["param_search/design_none"]] <- list()
SP3 <- "sp <- param_space(w = param_range(0, 1), n = param_range(10, 1000, log = TRUE, integer = TRUE), k = c(1, 2, 3))"
SP3P <- "sp = PS.param_space(w=PS.param_range(0, 1), n=PS.param_range(10, 1000, log=True, integer=True), k=[1.0, 2.0, 3.0])\n"
SP3J <- 'sp = PS.param_space(w = PS.param_range(0, 1), n = PS.param_range(10, 1000; log = true, integer = true), k = [1.0, 2.0, 3.0])\n'
EIN[["param_search/design_lhs"]] <- list()
EIN[["param_search/design_disc"]] <- list()
EIN[["param_search/as_spec"]] <- list()
# ── Daten für Suchen ────────────────────────────────────────────────────────
set.seed(1); n <- 300   # bis 1.4.1 n <- 600 (kürzer, Abdeckung gleich)
d <- data.frame(date = seq.Date(as.Date("2012-01-30"), by = "day", length.out = n))
d$A <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.011)); d$B <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.004))
I <- list(d = d)
RS <- "st <- create_strategy(A = asset_config('etf', 'signal', signal_buy = 'buy', signal_sell = 'sell', spread = 0.1))
b <- function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, p$band))
st2 <- create_strategy(A = asset_config('etf', 'bnh', 0.5, spread = 0.1), B = asset_config('etf', 'bnh', 0.5, spread = 0.1))\n"
PSS <- "st = create_strategy(A=asset_config(asset_class='etf', trading='signal', signal_buy='buy', signal_sell='sell', spread=0.1))
def b(p):
    return {'strategy': st, 'signal': lambda df: SG.signal_sma(df['A'], n=p['n'], band=p['band'])}
st2 = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1), B=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1))
def z(x):
    x['elapsed'] = 0.0
    return x
def dropE(s):
    s['best'] = s['best'].drop(columns='error'); s['best_plateau'] = s['best_plateau'].drop(columns='error')
    return s
"
PSJ <- 'st = create_strategy("A" => asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell", spread = 0.1))
b(p) = RList("strategy" => st, "signal" => df -> SL.Signals.signal_sma(df["A"]; n = p["n"], band = p["band"]))
st2 = create_strategy("A" => asset_config("etf", "bnh", 0.5, spread = 0.1), "B" => asset_config("etf", "bnh", 0.5, spread = 0.1))
z(x) = (x["elapsed"] = 0.0; x)
dropcol(f, c) = RFrame([k => f[k] for k in names(f) if k != c]...)
dropE(s) = (s["best"] = dropcol(s["best"], "error"); s["best_plateau"] = dropcol(s["best_plateau"], "error"); s)
'
EIN[["param_search/ps_grid"]] <- I
EIN[["param_search/ps_listspace"]] <- I
EIN[["param_search/ps_err_flat_space"]] <- I
EIN[["param_search/ps_err_path"]] <- I
EIN[["param_search/ps_err_all"]] <- I
EIN[["param_search/ps_err_obj"]] <- I
EIN[["param_search/ps_err_none"]] <- I
EIN[["param_search/ps_random"]] <- I
EIN[["param_search/ps_noret"]] <- I
EIN[["param_search/ps_err_keepret_true"]] <- I
EIN[["param_search/ps_err_keepret_chr"]] <- I
EIN[["param_search/ps_spec"]] <- I
EIN[["param_search/ps_sigdf"]] <- I
EIN[["param_search/ps_signa"]] <- I
EIN[["param_search/ps_plateau_c"]] <- I
# ── param_plateau auf nachgebautem Objekt (test-blue-planning) ────────────────────
FK <- "x <- structure(list(results = data.frame(id = 1:4, n = c(10, 20, 30, 40), sharpe = c(1, 2, 3, 4), max_drawdown = c(0.1, 0.5, 0.2, 0.3), cagr = c(0.05, 0.02, 0.04, 0.01)),
  params = 'n', method = 'grid', space = param_space(n = c(10, 20, 30, 40)), objective = 'sharpe', maximize = TRUE), class = 'SimLevParamSearch')\n"
FKP <- "x = PS.SimLevParamSearch(results=pd.DataFrame({'id': [1, 2, 3, 4], 'n': [10.0, 20.0, 30.0, 40.0], 'sharpe': [1.0, 2.0, 3.0, 4.0], 'max_drawdown': [0.1, 0.5, 0.2, 0.3], 'cagr': [0.05, 0.02, 0.04, 0.01]}),
  params=['n'], method='grid', space=PS.param_space(n=[10.0, 20.0, 30.0, 40.0]), objective='sharpe', maximize=True)\n"
FKJ <- 'x = RList("results" => RFrame("id" => [1, 2, 3, 4], "n" => [10.0, 20.0, 30.0, 40.0], "sharpe" => [1.0, 2.0, 3.0, 4.0], "max_drawdown" => [0.1, 0.5, 0.2, 0.3], "cagr" => [0.05, 0.02, 0.04, 0.01]), "params" => "n", "method" => "grid", "space" => PS.param_space(n = [10.0, 20.0, 30.0, 40.0]), "objective" => "sharpe", "maximize" => true; class = "SimLevParamSearch")\n'
EIN[["param_search/plateau_rnd1"]] <- list()
# Zeichen-Parameter: factor()-Stufen nach R's Kollation (ICU "root": a A b B)
FKC <- function(sv, sh) sprintf("x <- structure(list(results = data.frame(id = seq_along(%s), n = 10 * seq_along(%s), s = %s, sharpe = %s, cagr = %s / 100),
  params = 's', method = 'random', space = param_space(s = unique(%s)), objective = 'sharpe', maximize = TRUE, elapsed = 0), class = 'SimLevParamSearch')\n", sv, sv, sv, sh, sh, sv)
FKCP <- function(sv, sh) sprintf("sv = %s; sh = %s\nx = PS.SimLevParamSearch(results=pd.DataFrame({'id': list(range(1, len(sv) + 1)), 'n': [10.0 * (i + 1) for i in range(len(sv))], 's': sv, 'sharpe': sh, 'cagr': [v / 100 for v in sh]}),
  params=['s'], method='random', space=PS.param_space(s=list(dict.fromkeys(sv))), objective='sharpe', maximize=True, elapsed=0.0)\n", sv, sh)
FKCJ <- function(sv, sh) sprintf('sv = %s; sh = %s\nx = RList("results" => RFrame("id" => collect(1:length(sv)), "n" => [10.0 * i for i in 1:length(sv)], "s" => sv, "sharpe" => sh, "cagr" => sh ./ 100), "params" => "s", "method" => "random", "space" => PS.param_space(s = unique(sv)), "objective" => "sharpe", "maximize" => true, "elapsed" => 0.0; class = "SimLevParamSearch")\n', sv, sh)
s4r <- "c('b', 'A', 'a', 'B')"; s4p <- "['b', 'A', 'a', 'B']"; h4 <- "c(1, 4, 2, 3)"; h4p <- "[1.0, 4.0, 2.0, 3.0]"
EIN[["param_search/plateau_chr"]] <- list()
s6r <- "c('b', 'A', 'a', 'B', 'c', 'C')"; s6p <- "['b', 'A', 'a', 'B', 'c', 'C']"; h6 <- "c(1, 6, 2, 5, 3, 4)"; h6p <- "[1.0, 6.0, 2.0, 5.0, 3.0, 4.0]"
EIN[["param_search/plateau_notps"]] <- list()
EIN[["param_search/ps_cores2_err"]] <- I

# Vorspann je Szenario bzw. Tabellenzeile (gemeinsame Objekte des Moduls)
VOR <- list(r = r"()",
            py = r"(import simlev.param_search as PS
import simlev.overfitting as OF
import simlev.signals as SG
from simlev.config import create_strategy, asset_config)",
            jl = r"(const PS = SL.ParamSearch)")

ref_init("param_search", gruppe = "gleichlauf")
SZ("suchraum_und_versuchsplan", "param_space mit langer Reihe und Schrittweite, Latin Hypercube (log, ganzzahlig), diskreter Plan, Stufen, .as_spec", vor = VOR, teile = list(
  space_long = teil(
    r"(param_space(a = 1:20, b = param_range(0.001, 1234.5, step = 0.25)))",
    r"(result = PS.param_space(a=list(range(1, 21)), b=PS.param_range(0.001, 1234.5, step=0.25)))",
    r"(result = PS.param_space(a = collect(1:20), b = PS.param_range(0.001, 1234.5; step = 0.25)))", druck = TRUE, inp = ein("param_search/space_long", c())),
  design_lhs = teil(
    r"(sp <- param_space(w = param_range(0, 1), n = param_range(10, 1000, log = TRUE, integer = TRUE), k = c(1, 2, 3)); simlev_seed(3); list(SimLev:::.ps_design(sp, 'lhs', 20, NULL), SimLev:::.sl_runif(1)))",
    r"(sp = PS.param_space(w=PS.param_range(0, 1), n=PS.param_range(10, 1000, log=True, integer=True), k=[1.0, 2.0, 3.0])
simlev.simlev_seed(3); result = [PS._ps_design(sp, 'lhs', 20, None), simlev._lib.runif(1)])",
    r"(sp = PS.param_space(w = PS.param_range(0, 1), n = PS.param_range(10, 1000; log = true, integer = true), k = [1.0, 2.0, 3.0])
SL.simlev_seed(3); result = [PS._ps_design(sp, "lhs", 20, nothing), SL.SLib.runif(1)])", inp = ein("param_search/design_lhs", c())),
  design_disc = teil(
    r"(simlev_seed(5); sp <- param_space(a = c(1, 2), b = c('u', 'v', 'w')); list(SimLev:::.ps_design(sp, 'random', 10, NULL), SimLev:::.sl_runif(1)))",
    r"(simlev.simlev_seed(5); sp = PS.param_space(a=[1.0, 2.0], b=['u', 'v', 'w']); result = [PS._ps_design(sp, 'random', 10, None), simlev._lib.runif(1)])",
    r"(SL.simlev_seed(5); sp = PS.param_space(a = [1.0, 2.0], b = ["u", "v", "w"]); result = [PS._ps_design(sp, "random", 10, nothing), SL.SLib.runif(1)])", inp = ein("param_search/design_disc", c())),
  levels = teil(
    r"(sp <- param_space(n = param_range(50, 400, n = 8, integer = TRUE, log = TRUE), band = c(0, 1, 2), w = param_range(0.3, 0.9, step = 0.1), s = c('x', 'yy'), f = c(TRUE, FALSE), m = param_range(1, 2)); unname(c(lapply(sp, SimLev:::.ps_levels), list(SimLev:::.ps_levels(param_range(1, 3, n = 9, integer = TRUE)),
  SimLev:::.ps_levels(param_range(2, 2, n = 3)), SimLev:::.ps_levels(param_range(2, 5, n = 1)), SimLev:::.ps_levels(param_range(0, 1, step = 0.3)),
  SimLev:::.ps_levels(param_range(0, 0, step = 1)), SimLev:::.ps_levels(param_range(10, 1000, n = 7, log = TRUE, integer = TRUE)),
  SimLev:::.ps_levels(param_range(0.1, 0.7, step = 0.2))))))",
    r"(sp = PS.param_space(n=PS.param_range(50, 400, n=8, integer=True, log=True), band=[0.0, 1.0, 2.0], w=PS.param_range(0.3, 0.9, step=0.1), s=['x', 'yy'], f=[True, False], m=PS.param_range(1, 2))
result = [PS._ps_levels(v) for v in sp.values()] + [PS._ps_levels(PS.param_range(1, 3, n=9, integer=True)),
  PS._ps_levels(PS.param_range(2, 2, n=3)), PS._ps_levels(PS.param_range(2, 5, n=1)), PS._ps_levels(PS.param_range(0, 1, step=0.3)),
  PS._ps_levels(PS.param_range(0, 0, step=1)), PS._ps_levels(PS.param_range(10, 1000, n=7, log=True, integer=True)),
  PS._ps_levels(PS.param_range(0.1, 0.7, step=0.2))])",
    r"(sp = PS.param_space(n = PS.param_range(50, 400; n = 8, integer = true, log = true), band = [0.0, 1.0, 2.0], w = PS.param_range(0.3, 0.9; step = 0.1), s = ["x", "yy"], f = [true, false], m = PS.param_range(1, 2))
result = vcat([PS._ps_levels(v) for (k, v) in sp], [PS._ps_levels(PS.param_range(1, 3; n = 9, integer = true)), PS._ps_levels(PS.param_range(2, 2; n = 3)), PS._ps_levels(PS.param_range(2, 5; n = 1)), PS._ps_levels(PS.param_range(0, 1; step = 0.3)), PS._ps_levels(PS.param_range(0, 0; step = 1)), PS._ps_levels(PS.param_range(10, 1000; n = 7, log = true, integer = true)), PS._ps_levels(PS.param_range(0.1, 0.7; step = 0.2))]))", inp = ein("param_search/levels", c())),
  as_spec = teil(
    r"(st <- create_strategy(A = asset_config('etf', 'bnh', spread = 0.1)); list(SimLev:::.as_spec(st), SimLev:::.as_spec(list(strategy = st, args = list(a = 1))), SimLev:::.as_spec(list(a = 1))))",
    r"(st = create_strategy(A=asset_config(asset_class='etf', trading='bnh', spread=0.1)); result = [PS._as_spec(st), PS._as_spec({'strategy': st, 'args': {'a': 1}}), PS._as_spec({'a': 1})])",
    r"(st = create_strategy("A" => asset_config("etf", "bnh", spread = 0.1)); result = [PS._as_spec(st), PS._as_spec(RList("strategy" => st, "args" => RList("a" => 1))), PS._as_spec(RList("a" => 1))])", inp = ein("param_search/as_spec", c()))))
SZ("suche_raster_und_zufall", "param_search als Raster und Zufallssuche (Grafikdaten), Liste als Suchraum, ohne Renditen, mit Spezifikation", vor = VOR, gemein = teil(
    r"(st <- create_strategy(A = asset_config('etf', 'signal', signal_buy = 'buy', signal_sell = 'sell', spread = 0.1))
b <- function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, p$band))
st2 <- create_strategy(A = asset_config('etf', 'bnh', 0.5, spread = 0.1), B = asset_config('etf', 'bnh', 0.5, spread = 0.1))
z <- function(x) { x$elapsed <- 0; x }
dropE <- function(s) { s$best$error <- NULL; s$best_plateau$error <- NULL; s })",
    r"(st = create_strategy(A=asset_config(asset_class='etf', trading='signal', signal_buy='buy', signal_sell='sell', spread=0.1))
def b(p):
    return {'strategy': st, 'signal': lambda df: SG.signal_sma(df['A'], n=p['n'], band=p['band'])}
st2 = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1), B=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1))
def z(x):
    x['elapsed'] = 0.0
    return x
def dropE(s):
    s['best'] = s['best'].drop(columns='error'); s['best_plateau'] = s['best_plateau'].drop(columns='error')
    return s)",
    r"(st = create_strategy("A" => asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell", spread = 0.1))
b(p) = RList("strategy" => st, "signal" => df -> SL.Signals.signal_sma(df["A"]; n = p["n"], band = p["band"]))
st2 = create_strategy("A" => asset_config("etf", "bnh", 0.5, spread = 0.1), "B" => asset_config("etf", "bnh", 0.5, spread = 0.1))
z(x) = (x["elapsed"] = 0.0; x)
dropcol(f, c) = RFrame([k => f[k] for k in names(f) if k != c]...)
dropE(s) = (s["best"] = dropcol(s["best"], "error"); s["best_plateau"] = dropcol(s["best_plateau"], "error"); s))"), teile = list(
  ps_grid = teil(
    r"(z(param_search(d, b, param_space(n = c(10, 20, 40), band = c(0, 2)), burn_in = 50)))",
    r"(result = z(PS.param_search(d, b, PS.param_space(n=[10.0, 20.0, 40.0], band=[0.0, 2.0]), burn_in=50)))",
    r"(result = z(PS.param_search(d, b, PS.param_space(n = [10.0, 20.0, 40.0], band = [0.0, 2.0]); burn_in = 50)))", druck = TRUE, inp = ein("param_search/ps_grid", c("d"))),
  ps_random = teil(
    r"(simlev_seed(9); x <- z(param_search(d, b, param_space(n = param_range(5, 60, integer = TRUE), band = param_range(0, 3)), method = 'random', n = 5, seed = 2, burn_in = 60)); list(x, SimLev:::.sl_runif(1), param_plateau(x), param_plateau(x, k = 2)))",
    r"(simlev.simlev_seed(9); x = z(PS.param_search(d, b, PS.param_space(n=PS.param_range(5, 60, integer=True), band=PS.param_range(0, 3)), method='random', n=5, seed=2, burn_in=60)); result = [x, simlev._lib.runif(1), PS.param_plateau(x), PS.param_plateau(x, k=2)])",
    r"(SL.simlev_seed(9); x = z(PS.param_search(d, b, PS.param_space(n = PS.param_range(5, 60; integer = true), band = PS.param_range(0, 3)); method = "random", n = 5, seed = 2, burn_in = 60)); result = [x, SL.SLib.runif(1), PS.param_plateau(x), PS.param_plateau(x; k = 2)])", inp = ein("param_search/ps_random", c("d")), oben = TRUE),
  ps_listspace = teil(
    r"(z(param_search(d, space = list(rebalance.unit = c('month', 'year')), strategy = st2, sim_args = list(rebalance = rebalance_plan(span = 1)), objective = 'cagr')))",
    r"(result = z(PS.param_search(d, space={'rebalance.unit': ['month', 'year']}, strategy=st2, sim_args={'rebalance': simlev.rebalance_plan(span=1)}, objective='cagr')))",
    r"(result = z(PS.param_search(d; space = RList("rebalance.unit" => ["month", "year"]), strategy = st2, sim_args = RList("rebalance" => SL.rebalance_plan(; span = 1)), objective = "cagr")))", druck = TRUE, inp = ein("param_search/ps_listspace", c("d"))),
  ps_noret = teil(
    r"(z(param_search(d, b, param_space(n = c(10, 20), band = 0), keep_returns = 'none', burn_in = 30)))",
    r"(result = z(PS.param_search(d, b, PS.param_space(n=[10.0, 20.0], band=0.0), keep_returns='none', burn_in=30)))",
    r"(result = z(PS.param_search(d, b, PS.param_space(n = [10.0, 20.0], band = 0.0); keep_returns = "none", burn_in = 30)))", druck = TRUE, inp = ein("param_search/ps_noret", c("d"))),
  ps_spec = teil(
    r"(bs <- function(p) list(strategy = create_strategy(L = asset_config('etf', 'bnh', spread = 0.1)), data = function(df) { df$L2 <- series_leverage(df, 'A', p$lev); df }, map = c(L = 'L2'), args = list(start_value = p$sv))
  z(param_search(d, bs, param_space(lev = c(1, 2), sv = c(1000, 5000)), sim_args = list(start_value = 1))))",
    r"(import simlev.sensitivity as SE
def bs(p):
    def dat(df):
        df = df.copy(); df['L2'] = SE.series_leverage(df, 'A', leverage=p['lev']); return df
    return {'strategy': create_strategy(L=asset_config(asset_class='etf', trading='bnh', spread=0.1)), 'data': dat, 'map': {'L': 'L2'}, 'args': {'start_value': p['sv']}}
result = z(PS.param_search(d, bs, PS.param_space(lev=[1.0, 2.0], sv=[1000.0, 5000.0]), sim_args={'start_value': 1})))",
    r"(bs(p) = RList("strategy" => create_strategy("L" => asset_config("etf", "bnh", spread = 0.1)), "data" => df -> (df["L2"] = SL.Sensitivity.series_leverage(df, "A"; leverage = p["lev"]); df), "map" => named("L" => "L2"), "args" => RList("start_value" => p["sv"]))
result = z(PS.param_search(d, bs, PS.param_space(lev = [1.0, 2.0], sv = [1000.0, 5000.0]); sim_args = RList("start_value" => 1))))", druck = TRUE, inp = ein("param_search/ps_spec", c("d")))))
SZ("suche_mit_signalen", "param_search mit Signal-Tabelle und Signalfunktion mit NA, Plateau aus Ergebnissen, cores = 2 mit Fehler in einem Lauf", vor = VOR, gemein = teil(
    r"(st <- create_strategy(A = asset_config('etf', 'signal', signal_buy = 'buy', signal_sell = 'sell', spread = 0.1))
b <- function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, p$band))
st2 <- create_strategy(A = asset_config('etf', 'bnh', 0.5, spread = 0.1), B = asset_config('etf', 'bnh', 0.5, spread = 0.1))
z <- function(x) { x$elapsed <- 0; x }
dropE <- function(s) { s$best$error <- NULL; s$best_plateau$error <- NULL; s })",
    r"(st = create_strategy(A=asset_config(asset_class='etf', trading='signal', signal_buy='buy', signal_sell='sell', spread=0.1))
def b(p):
    return {'strategy': st, 'signal': lambda df: SG.signal_sma(df['A'], n=p['n'], band=p['band'])}
st2 = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1), B=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1))
def z(x):
    x['elapsed'] = 0.0
    return x
def dropE(s):
    s['best'] = s['best'].drop(columns='error'); s['best_plateau'] = s['best_plateau'].drop(columns='error')
    return s)",
    r"(st = create_strategy("A" => asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell", spread = 0.1))
b(p) = RList("strategy" => st, "signal" => df -> SL.Signals.signal_sma(df["A"]; n = p["n"], band = p["band"]))
st2 = create_strategy("A" => asset_config("etf", "bnh", 0.5, spread = 0.1), "B" => asset_config("etf", "bnh", 0.5, spread = 0.1))
z(x) = (x["elapsed"] = 0.0; x)
dropcol(f, c) = RFrame([k => f[k] for k in names(f) if k != c]...)
dropE(s) = (s["best"] = dropcol(s["best"], "error"); s["best_plateau"] = dropcol(s["best_plateau"], "error"); s))"), teile = list(
  ps_sigdf = teil(
    r"(sgd <- function(p) list(strategy = st, signal = function(df) { s <- signal_sma(df$A, p$n); df$buy <- s$buy; df$sell <- s$sell; df })
  z(param_search(d, sgd, param_space(n = c(10, 20)), burn_in = 25)))",
    r"(def sgd(p):
    def sg(df):
        s = SG.signal_sma(df['A'], n=p['n']); df = df.copy(); df['buy'] = s['buy']; df['sell'] = s['sell']; return df
    return {'strategy': st, 'signal': sg}
result = z(PS.param_search(d, sgd, PS.param_space(n=[10.0, 20.0]), burn_in=25)))",
    r"(sgd(p) = RList("strategy" => st, "signal" => df -> (s = SL.Signals.signal_sma(df["A"]; n = p["n"]); df["buy"] = s["buy"]; df["sell"] = s["sell"]; df))
result = z(PS.param_search(d, sgd, PS.param_space(n = [10.0, 20.0]); burn_in = 25)))", druck = TRUE, inp = ein("param_search/ps_sigdf", c("d"))),
  ps_signa = teil(
    r"(sgn <- function(p) list(strategy = st, signal = function(df) list(buy = c(NA, df$A[-1] > df$A[-nrow(df)]), sell = c(NA, df$A[-1] < df$A[-nrow(df)] * (1 - p$k))))
  z(param_search(d, sgn, param_space(k = c(0, 0.01)))))",
    r"(def sgn(p):
    def sg(df):
        a = df['A'].to_numpy()
        return {'buy': np.array([None] + list(a[1:] > a[:-1]), dtype=object), 'sell': np.array([None] + list(a[1:] < a[:-1] * (1 - p['k'])), dtype=object)}
    return {'strategy': st, 'signal': sg}
result = z(PS.param_search(d, sgn, PS.param_space(k=[0.0, 0.01]))))",
    r"(sgn(p) = RList("strategy" => st, "signal" => df -> (a = df["A"]; RList("buy" => vcat(missing, a[2:end] .> a[1:end-1]), "sell" => vcat(missing, a[2:end] .< a[1:end-1] .* (1 - p["k"])))))
result = z(PS.param_search(d, sgn, PS.param_space(k = [0.0, 0.01]))))", druck = TRUE, inp = ein("param_search/ps_signa", c("d"))),
  ps_plateau_c = teil(
    r"(x <- z(param_search(d, space = param_space(rebalance.thresh = c(2, 5, 10), rebalance.unit = c('month', 'year')), strategy = st2, constraint = function(p) p$rebalance.thresh < 10 || p$rebalance.unit == 'year', sim_args = list(rebalance = rebalance_plan(span = 1)))); list(param_plateau(x), dropE(summary(x))))",
    r"(x = z(PS.param_search(d, space=PS.param_space(**{'rebalance.thresh': [2.0, 5.0, 10.0], 'rebalance.unit': ['month', 'year']}), strategy=st2, constraint=lambda p: p['rebalance.thresh'] < 10 or p['rebalance.unit'] == 'year', sim_args={'rebalance': simlev.rebalance_plan(span=1)})); result = [PS.param_plateau(x), dropE(PS.summary(x))])",
    r"(x = z(PS.param_search(d; space = PS.param_space("rebalance.thresh" => [2.0, 5.0, 10.0], "rebalance.unit" => ["month", "year"]), strategy = st2, constraint = p -> p["rebalance.thresh"] < 10 || p["rebalance.unit"] == "year", sim_args = RList("rebalance" => SL.rebalance_plan(; span = 1)))); result = [PS.param_plateau(x), dropE(r_summary(x))])", inp = ein("param_search/ps_plateau_c", c("d"))),
  ps_cores2_err = teil(
    r"(z(param_search(d, function(p) if (p$n > 15) stop('kaputt') else b(p), param_space(n = c(10, 20, 30), band = 0), burn_in = 50, cores = 2)))",
    r"(def bb(p):
    if p['n'] > 15:
        raise ValueError('kaputt')
    return b(p)
result = z(PS.param_search(d, bb, PS.param_space(n=[10.0, 20.0, 30.0], band=0.0), burn_in=50, cores=2)))",
    r"(bb(p) = p["n"] > 15 ? error("kaputt") : b(p)
result = z(PS.param_search(d, bb, PS.param_space(n = [10.0, 20.0, 30.0], band = 0.0); burn_in = 50, cores = 2)))", druck = TRUE, inp = ein("param_search/ps_cores2_err", c("d")))))
SZ("plateau_auswahl", "Plateau bei Zufallssuche mit einem Parameter und bei Text-Parametern (Sortierung)", vor = VOR, teile = list(
  plateau_rnd1 = teil(
    r"(x <- structure(list(results = data.frame(id = 1:4, n = c(10, 20, 30, 40), sharpe = c(1, 2, 3, 4), max_drawdown = c(0.1, 0.5, 0.2, 0.3), cagr = c(0.05, 0.02, 0.04, 0.01)),
  params = 'n', method = 'grid', space = param_space(n = c(10, 20, 30, 40)), objective = 'sharpe', maximize = TRUE), class = 'SimLevParamSearch')
x$method <- 'random'; x$results <- x$results[2, ]; x$results$m <- 'q'; x$params <- c('n', 'm'); SimLev:::.ps_neighbours(x))",
    r"(x = PS.SimLevParamSearch(results=pd.DataFrame({'id': [1, 2, 3, 4], 'n': [10.0, 20.0, 30.0, 40.0], 'sharpe': [1.0, 2.0, 3.0, 4.0], 'max_drawdown': [0.1, 0.5, 0.2, 0.3], 'cagr': [0.05, 0.02, 0.04, 0.01]}),
  params=['n'], method='grid', space=PS.param_space(n=[10.0, 20.0, 30.0, 40.0]), objective='sharpe', maximize=True)
x['method'] = 'random'; x['results'] = x['results'].iloc[[1]].reset_index(drop=True); x['results']['m'] = 'q'; x['params'] = ['n', 'm']; result = PS._ps_neighbours(x))",
    r"(x = RList("results" => RFrame("id" => [1, 2, 3, 4], "n" => [10.0, 20.0, 30.0, 40.0], "sharpe" => [1.0, 2.0, 3.0, 4.0], "max_drawdown" => [0.1, 0.5, 0.2, 0.3], "cagr" => [0.05, 0.02, 0.04, 0.01]), "params" => "n", "method" => "grid", "space" => PS.param_space(n = [10.0, 20.0, 30.0, 40.0]), "objective" => "sharpe", "maximize" => true; class = "SimLevParamSearch")
x["method"] = "random"; x["results"] = rows(x["results"], [2]); x["results"]["m"] = "q"; x["params"] = ["n", "m"]; result = PS._ps_neighbours(x))", inp = ein("param_search/plateau_rnd1", c())),
  plateau_chr = teil(
    r"(x <- structure(list(results = data.frame(id = seq_along(c('b', 'A', 'a', 'B')), n = 10 * seq_along(c('b', 'A', 'a', 'B')), s = c('b', 'A', 'a', 'B'), sharpe = c(1, 4, 2, 3), cagr = c(1, 4, 2, 3) / 100),
  params = 's', method = 'random', space = param_space(s = unique(c('b', 'A', 'a', 'B'))), objective = 'sharpe', maximize = TRUE, elapsed = 0), class = 'SimLevParamSearch')
list(SimLev:::.ps_neighbours(x, k = 2), param_plateau(x, k = 2), param_plateau(x, 'cagr', k = 3)))",
    r"(sv = ['b', 'A', 'a', 'B']; sh = [1.0, 4.0, 2.0, 3.0]
x = PS.SimLevParamSearch(results=pd.DataFrame({'id': list(range(1, len(sv) + 1)), 'n': [10.0 * (i + 1) for i in range(len(sv))], 's': sv, 'sharpe': sh, 'cagr': [v / 100 for v in sh]}),
  params=['s'], method='random', space=PS.param_space(s=list(dict.fromkeys(sv))), objective='sharpe', maximize=True, elapsed=0.0)
result = [PS._ps_neighbours(x, k=2), PS.param_plateau(x, k=2), PS.param_plateau(x, metric='cagr', k=3)])",
    r"(sv = ["b", "A", "a", "B"]; sh = [1.0, 4.0, 2.0, 3.0]
x = RList("results" => RFrame("id" => collect(1:length(sv)), "n" => [10.0 * i for i in 1:length(sv)], "s" => sv, "sharpe" => sh, "cagr" => sh ./ 100), "params" => "s", "method" => "random", "space" => PS.param_space(s = unique(sv)), "objective" => "sharpe", "maximize" => true, "elapsed" => 0.0; class = "SimLevParamSearch")
result = [PS._ps_neighbours(x; k = 2), PS.param_plateau(x; k = 2), PS.param_plateau(x; metric = "cagr", k = 3)])", inp = ein("param_search/plateau_chr", c()))))
ref_done()

ref_init("param_search", gruppe = "fehler")
TB("param_space", "Meldungen und Warnungen von param_space je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("space_err0",
    r"(param_space())",
    r"(result = PS.param_space())",
    r"(result = PS.param_space())", inp = ein("param_search/space_err0", c())),
  zeile("space_err2",
    r"(param_space(a = list(1, 2)))",
    r"(result = PS.param_space(a={'x': 1, 'y': 2}))",
    r"(result = PS.param_space(a = Dict("x" => 1, "y" => 2)))", inp = ein("param_search/space_err2", c())),
  zeile("design_none",
    r"(sp <- param_space(a = param_range(1, 5, n = 5, integer = TRUE), b = c('x', 'y')); SimLev:::.ps_design(sp, 'grid', 0, function(p) FALSE))",
    r"(sp = PS.param_space(a=PS.param_range(1, 5, n=5, integer=True), b=['x', 'y'])
result = PS._ps_design(sp, 'grid', 0, lambda p: False))",
    r"(sp = PS.param_space(a = PS.param_range(1, 5; n = 5, integer = true), b = ["x", "y"])
result = PS._ps_design(sp, "grid", 0, p -> false))", inp = ein("param_search/design_none", c()))))
TB("param_range", "Meldungen und Warnungen von param_range je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("range_err_n0",
    r"(param_range(1, 2, n = 0))",
    r"(result = PS.param_range(1, 2, n=0))",
    r"(result = PS.param_range(1, 2; n = 0))", inp = ein("param_search/range_err_n0", c())),
  zeile("range_err_ord",
    r"(param_range(2, 1))",
    r"(result = PS.param_range(2, 1))",
    r"(result = PS.param_range(2, 1))", inp = ein("param_search/range_err_ord", c())),
  zeile("range_err_log",
    r"(param_range(0, 1, log = TRUE))",
    r"(result = PS.param_range(0, 1, log=True))",
    r"(result = PS.param_range(0, 1; log = true))", inp = ein("param_search/range_err_log", c())),
  zeile("range_err_step",
    r"(param_range(1, 5, step = -1))",
    r"(result = PS.param_range(1, 5, step=-1))",
    r"(result = PS.param_range(1, 5; step = -1))", inp = ein("param_search/range_err_step", c()))))
TB("param_search", "Meldungen und Warnungen von param_search je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("ps_err_flat_space",
    r"(st <- create_strategy(A = asset_config('etf', 'signal', signal_buy = 'buy', signal_sell = 'sell', spread = 0.1))
b <- function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, p$band))
st2 <- create_strategy(A = asset_config('etf', 'bnh', 0.5, spread = 0.1), B = asset_config('etf', 'bnh', 0.5, spread = 0.1))
z <- function(x) { x$elapsed <- 0; x }
dropE <- function(s) { s$best$error <- NULL; s$best_plateau$error <- NULL; s }
param_search(d, space = param_space(balance_thresh = c(2, 5)), strategy = st2))",
    r"(st = create_strategy(A=asset_config(asset_class='etf', trading='signal', signal_buy='buy', signal_sell='sell', spread=0.1))
def b(p):
    return {'strategy': st, 'signal': lambda df: SG.signal_sma(df['A'], n=p['n'], band=p['band'])}
st2 = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1), B=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1))
def z(x):
    x['elapsed'] = 0.0
    return x
def dropE(s):
    s['best'] = s['best'].drop(columns='error'); s['best_plateau'] = s['best_plateau'].drop(columns='error')
    return s
result = PS.param_search(d, space=PS.param_space(balance_thresh=[2.0, 5.0]), strategy=st2))",
    r"(st = create_strategy("A" => asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell", spread = 0.1))
b(p) = RList("strategy" => st, "signal" => df -> SL.Signals.signal_sma(df["A"]; n = p["n"], band = p["band"]))
st2 = create_strategy("A" => asset_config("etf", "bnh", 0.5, spread = 0.1), "B" => asset_config("etf", "bnh", 0.5, spread = 0.1))
z(x) = (x["elapsed"] = 0.0; x)
dropcol(f, c) = RFrame([k => f[k] for k in names(f) if k != c]...)
dropE(s) = (s["best"] = dropcol(s["best"], "error"); s["best_plateau"] = dropcol(s["best_plateau"], "error"); s)
result = PS.param_search(d; space = PS.param_space(balance_thresh = [2.0, 5.0]), strategy = st2))", inp = ein("param_search/ps_err_flat_space", c("d"))),
  zeile("ps_err_path",
    r"(st <- create_strategy(A = asset_config('etf', 'signal', signal_buy = 'buy', signal_sell = 'sell', spread = 0.1))
b <- function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, p$band))
st2 <- create_strategy(A = asset_config('etf', 'bnh', 0.5, spread = 0.1), B = asset_config('etf', 'bnh', 0.5, spread = 0.1))
z <- function(x) { x$elapsed <- 0; x }
dropE <- function(s) { s$best$error <- NULL; s$best_plateau$error <- NULL; s }
param_search(d, space = param_space(rebalance.tresh = c(2, 5)), strategy = st2))",
    r"(st = create_strategy(A=asset_config(asset_class='etf', trading='signal', signal_buy='buy', signal_sell='sell', spread=0.1))
def b(p):
    return {'strategy': st, 'signal': lambda df: SG.signal_sma(df['A'], n=p['n'], band=p['band'])}
st2 = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1), B=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1))
def z(x):
    x['elapsed'] = 0.0
    return x
def dropE(s):
    s['best'] = s['best'].drop(columns='error'); s['best_plateau'] = s['best_plateau'].drop(columns='error')
    return s
result = PS.param_search(d, space=PS.param_space(**{'rebalance.tresh': [2.0, 5.0]}), strategy=st2))",
    r"(st = create_strategy("A" => asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell", spread = 0.1))
b(p) = RList("strategy" => st, "signal" => df -> SL.Signals.signal_sma(df["A"]; n = p["n"], band = p["band"]))
st2 = create_strategy("A" => asset_config("etf", "bnh", 0.5, spread = 0.1), "B" => asset_config("etf", "bnh", 0.5, spread = 0.1))
z(x) = (x["elapsed"] = 0.0; x)
dropcol(f, c) = RFrame([k => f[k] for k in names(f) if k != c]...)
dropE(s) = (s["best"] = dropcol(s["best"], "error"); s["best_plateau"] = dropcol(s["best_plateau"], "error"); s)
result = PS.param_search(d; space = PS.param_space("rebalance.tresh" => [2.0, 5.0]), strategy = st2))", inp = ein("param_search/ps_err_path", c("d"))),
  zeile("ps_err_all",
    r"(st <- create_strategy(A = asset_config('etf', 'signal', signal_buy = 'buy', signal_sell = 'sell', spread = 0.1))
b <- function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, p$band))
st2 <- create_strategy(A = asset_config('etf', 'bnh', 0.5, spread = 0.1), B = asset_config('etf', 'bnh', 0.5, spread = 0.1))
z <- function(x) { x$elapsed <- 0; x }
dropE <- function(s) { s$best$error <- NULL; s$best_plateau$error <- NULL; s }
param_search(d, function(p) stop('alles kaputt'), param_space(n = c(10, 20))))",
    r"(st = create_strategy(A=asset_config(asset_class='etf', trading='signal', signal_buy='buy', signal_sell='sell', spread=0.1))
def b(p):
    return {'strategy': st, 'signal': lambda df: SG.signal_sma(df['A'], n=p['n'], band=p['band'])}
st2 = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1), B=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1))
def z(x):
    x['elapsed'] = 0.0
    return x
def dropE(s):
    s['best'] = s['best'].drop(columns='error'); s['best_plateau'] = s['best_plateau'].drop(columns='error')
    return s
def bb(p):
    raise ValueError('alles kaputt')
result = PS.param_search(d, bb, PS.param_space(n=[10.0, 20.0])))",
    r"(st = create_strategy("A" => asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell", spread = 0.1))
b(p) = RList("strategy" => st, "signal" => df -> SL.Signals.signal_sma(df["A"]; n = p["n"], band = p["band"]))
st2 = create_strategy("A" => asset_config("etf", "bnh", 0.5, spread = 0.1), "B" => asset_config("etf", "bnh", 0.5, spread = 0.1))
z(x) = (x["elapsed"] = 0.0; x)
dropcol(f, c) = RFrame([k => f[k] for k in names(f) if k != c]...)
dropE(s) = (s["best"] = dropcol(s["best"], "error"); s["best_plateau"] = dropcol(s["best_plateau"], "error"); s)
result = PS.param_search(d, p -> error("alles kaputt"), PS.param_space(n = [10.0, 20.0])))", inp = ein("param_search/ps_err_all", c("d"))),
  zeile("ps_err_obj",
    r"(st <- create_strategy(A = asset_config('etf', 'signal', signal_buy = 'buy', signal_sell = 'sell', spread = 0.1))
b <- function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, p$band))
st2 <- create_strategy(A = asset_config('etf', 'bnh', 0.5, spread = 0.1), B = asset_config('etf', 'bnh', 0.5, spread = 0.1))
z <- function(x) { x$elapsed <- 0; x }
dropE <- function(s) { s$best$error <- NULL; s$best_plateau$error <- NULL; s }
param_search(d, b, param_space(n = 10, band = 0), objective = 'foo'))",
    r"(st = create_strategy(A=asset_config(asset_class='etf', trading='signal', signal_buy='buy', signal_sell='sell', spread=0.1))
def b(p):
    return {'strategy': st, 'signal': lambda df: SG.signal_sma(df['A'], n=p['n'], band=p['band'])}
st2 = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1), B=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1))
def z(x):
    x['elapsed'] = 0.0
    return x
def dropE(s):
    s['best'] = s['best'].drop(columns='error'); s['best_plateau'] = s['best_plateau'].drop(columns='error')
    return s
result = PS.param_search(d, b, PS.param_space(n=10.0, band=0.0), objective='foo'))",
    r"(st = create_strategy("A" => asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell", spread = 0.1))
b(p) = RList("strategy" => st, "signal" => df -> SL.Signals.signal_sma(df["A"]; n = p["n"], band = p["band"]))
st2 = create_strategy("A" => asset_config("etf", "bnh", 0.5, spread = 0.1), "B" => asset_config("etf", "bnh", 0.5, spread = 0.1))
z(x) = (x["elapsed"] = 0.0; x)
dropcol(f, c) = RFrame([k => f[k] for k in names(f) if k != c]...)
dropE(s) = (s["best"] = dropcol(s["best"], "error"); s["best_plateau"] = dropcol(s["best_plateau"], "error"); s)
result = PS.param_search(d, b, PS.param_space(n = 10.0, band = 0.0); objective = "foo"))", inp = ein("param_search/ps_err_obj", c("d"))),
  zeile("ps_err_cores",   # Standard "auto"; ungültig -> Meldung par.cores (seit 1.6.4, Entscheidung 113)
    r"(st <- create_strategy(A = asset_config('etf', 'signal', signal_buy = 'buy', signal_sell = 'sell', spread = 0.1))
b <- function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, p$band))
st2 <- create_strategy(A = asset_config('etf', 'bnh', 0.5, spread = 0.1), B = asset_config('etf', 'bnh', 0.5, spread = 0.1))
z <- function(x) { x$elapsed <- 0; x }
dropE <- function(s) { s$best$error <- NULL; s$best_plateau$error <- NULL; s }
param_search(d, b, param_space(n = 10, band = 0), cores = 0))",
    r"(st = create_strategy(A=asset_config(asset_class='etf', trading='signal', signal_buy='buy', signal_sell='sell', spread=0.1))
def b(p):
    return {'strategy': st, 'signal': lambda df: SG.signal_sma(df['A'], n=p['n'], band=p['band'])}
st2 = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1), B=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1))
def z(x):
    x['elapsed'] = 0.0
    return x
def dropE(s):
    s['best'] = s['best'].drop(columns='error'); s['best_plateau'] = s['best_plateau'].drop(columns='error')
    return s
result = PS.param_search(d, b, PS.param_space(n=10.0, band=0.0), cores=0))",
    r"(st = create_strategy("A" => asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell", spread = 0.1))
b(p) = RList("strategy" => st, "signal" => df -> SL.Signals.signal_sma(df["A"]; n = p["n"], band = p["band"]))
st2 = create_strategy("A" => asset_config("etf", "bnh", 0.5, spread = 0.1), "B" => asset_config("etf", "bnh", 0.5, spread = 0.1))
z(x) = (x["elapsed"] = 0.0; x)
dropcol(f, c) = RFrame([k => f[k] for k in names(f) if k != c]...)
dropE(s) = (s["best"] = dropcol(s["best"], "error"); s["best_plateau"] = dropcol(s["best_plateau"], "error"); s)
result = PS.param_search(d, b, PS.param_space(n = 10.0, band = 0.0); cores = 0))", inp = ein("param_search/ps_err_obj", c("d"))),
  zeile("ps_err_none",
    r"(st <- create_strategy(A = asset_config('etf', 'signal', signal_buy = 'buy', signal_sell = 'sell', spread = 0.1))
b <- function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, p$band))
st2 <- create_strategy(A = asset_config('etf', 'bnh', 0.5, spread = 0.1), B = asset_config('etf', 'bnh', 0.5, spread = 0.1))
z <- function(x) { x$elapsed <- 0; x }
dropE <- function(s) { s$best$error <- NULL; s$best_plateau$error <- NULL; s }
param_search(d, space = param_space(n = 10)))",
    r"(st = create_strategy(A=asset_config(asset_class='etf', trading='signal', signal_buy='buy', signal_sell='sell', spread=0.1))
def b(p):
    return {'strategy': st, 'signal': lambda df: SG.signal_sma(df['A'], n=p['n'], band=p['band'])}
st2 = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1), B=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1))
def z(x):
    x['elapsed'] = 0.0
    return x
def dropE(s):
    s['best'] = s['best'].drop(columns='error'); s['best_plateau'] = s['best_plateau'].drop(columns='error')
    return s
result = PS.param_search(d, space=PS.param_space(n=10.0)))",
    r"(st = create_strategy("A" => asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell", spread = 0.1))
b(p) = RList("strategy" => st, "signal" => df -> SL.Signals.signal_sma(df["A"]; n = p["n"], band = p["band"]))
st2 = create_strategy("A" => asset_config("etf", "bnh", 0.5, spread = 0.1), "B" => asset_config("etf", "bnh", 0.5, spread = 0.1))
z(x) = (x["elapsed"] = 0.0; x)
dropcol(f, c) = RFrame([k => f[k] for k in names(f) if k != c]...)
dropE(s) = (s["best"] = dropcol(s["best"], "error"); s["best_plateau"] = dropcol(s["best_plateau"], "error"); s)
result = PS.param_search(d; space = PS.param_space(n = 10.0)))", inp = ein("param_search/ps_err_none", c("d"))),
  zeile("ps_err_keepret_true",
    r"(st <- create_strategy(A = asset_config('etf', 'signal', signal_buy = 'buy', signal_sell = 'sell', spread = 0.1))
b <- function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, p$band))
st2 <- create_strategy(A = asset_config('etf', 'bnh', 0.5, spread = 0.1), B = asset_config('etf', 'bnh', 0.5, spread = 0.1))
z <- function(x) { x$elapsed <- 0; x }
dropE <- function(s) { s$best$error <- NULL; s$best_plateau$error <- NULL; s }
param_search(d, b, param_space(n = c(10, 20), band = 0), keep_returns = TRUE))",
    r"(st = create_strategy(A=asset_config(asset_class='etf', trading='signal', signal_buy='buy', signal_sell='sell', spread=0.1))
def b(p):
    return {'strategy': st, 'signal': lambda df: SG.signal_sma(df['A'], n=p['n'], band=p['band'])}
st2 = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1), B=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1))
def z(x):
    x['elapsed'] = 0.0
    return x
def dropE(s):
    s['best'] = s['best'].drop(columns='error'); s['best_plateau'] = s['best_plateau'].drop(columns='error')
    return s
result = PS.param_search(d, b, PS.param_space(n=[10.0, 20.0], band=0.0), keep_returns=True))",
    r"(st = create_strategy("A" => asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell", spread = 0.1))
b(p) = RList("strategy" => st, "signal" => df -> SL.Signals.signal_sma(df["A"]; n = p["n"], band = p["band"]))
st2 = create_strategy("A" => asset_config("etf", "bnh", 0.5, spread = 0.1), "B" => asset_config("etf", "bnh", 0.5, spread = 0.1))
z(x) = (x["elapsed"] = 0.0; x)
dropcol(f, c) = RFrame([k => f[k] for k in names(f) if k != c]...)
dropE(s) = (s["best"] = dropcol(s["best"], "error"); s["best_plateau"] = dropcol(s["best_plateau"], "error"); s)
result = PS.param_search(d, b, PS.param_space(n = [10.0, 20.0], band = 0.0); keep_returns = true))", inp = ein("param_search/ps_err_keepret_true", c("d"))),
  zeile("ps_err_keepret_chr",
    r"(st <- create_strategy(A = asset_config('etf', 'signal', signal_buy = 'buy', signal_sell = 'sell', spread = 0.1))
b <- function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, p$band))
st2 <- create_strategy(A = asset_config('etf', 'bnh', 0.5, spread = 0.1), B = asset_config('etf', 'bnh', 0.5, spread = 0.1))
z <- function(x) { x$elapsed <- 0; x }
dropE <- function(s) { s$best$error <- NULL; s$best_plateau$error <- NULL; s }
param_search(d, b, param_space(n = c(10, 20), band = 0), keep_returns = 'week'))",
    r"(st = create_strategy(A=asset_config(asset_class='etf', trading='signal', signal_buy='buy', signal_sell='sell', spread=0.1))
def b(p):
    return {'strategy': st, 'signal': lambda df: SG.signal_sma(df['A'], n=p['n'], band=p['band'])}
st2 = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1), B=asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.1))
def z(x):
    x['elapsed'] = 0.0
    return x
def dropE(s):
    s['best'] = s['best'].drop(columns='error'); s['best_plateau'] = s['best_plateau'].drop(columns='error')
    return s
result = PS.param_search(d, b, PS.param_space(n=[10.0, 20.0], band=0.0), keep_returns='week'))",
    r"(st = create_strategy("A" => asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell", spread = 0.1))
b(p) = RList("strategy" => st, "signal" => df -> SL.Signals.signal_sma(df["A"]; n = p["n"], band = p["band"]))
st2 = create_strategy("A" => asset_config("etf", "bnh", 0.5, spread = 0.1), "B" => asset_config("etf", "bnh", 0.5, spread = 0.1))
z(x) = (x["elapsed"] = 0.0; x)
dropcol(f, c) = RFrame([k => f[k] for k in names(f) if k != c]...)
dropE(s) = (s["best"] = dropcol(s["best"], "error"); s["best_plateau"] = dropcol(s["best_plateau"], "error"); s)
result = PS.param_search(d, b, PS.param_space(n = [10.0, 20.0], band = 0.0); keep_returns = "week"))", inp = ein("param_search/ps_err_keepret_chr", c("d")))))
TB("param_plateau", "Meldungen und Warnungen von param_plateau je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("plateau_notps",
    r"(param_plateau(list(a = 1)))",
    r"(result = PS.param_plateau({'a': 1}))",
    r"(result = PS.param_plateau(RList("a" => 1)))", inp = ein("param_search/plateau_notps", c()))))
ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul overfitting
# ════════════════════════════════════════════════════════════════════════════════════════════════════
P <- "import simlev.overfitting as OF\nimport simlev.param_search as PS\n"
py <- function(code) paste0(P, code)
J <- "const OF = SL.Overfitting\nconst PS = SL.ParamSearch\n"
jl <- function(code) paste0(J, code)
# ── Daten ───────────────────────────────────────────────────────────────────
set.seed(5); R <- matrix(rnorm(400 * 7, 1e-4, 0.01), 400)
set.seed(6); Rs <- matrix(rnorm(120 * 4, 2e-4, 0.01), 120)
dts <- seq.Date(as.Date("2019-12-27"), by = "day", length.out = 120)
Rn <- Rs; Rn[, 2] <- NA; Rn[c(3, 50), 3] <- NA
Rdf <- as.data.frame(Rs); names(Rdf) <- c("a", "b", "c", "d")
set.seed(1); R3 <- matrix(rnorm(400 * 3, 0, 0.01), 400)
set.seed(1); Rc <- matrix(rnorm(1000 * 3, 4e-4, 0.01), 1000)
cash <- 100 * cumprod(rep(1 + 0.02 / 365, 1001)); cash <- cash[-1] / cash[-1001] - 1
set.seed(2); xb <- 1e-3 + 1e-9 * rnorm(500); Mb <- cbind(xb, rnorm(500, 0, 0.01))
set.seed(1); r520 <- rnorm(520, 0.002, 0.02); r520[c(5, 9)] <- c(NA, Inf)
I <- list(R = R, Rs = Rs, dts = dts, Rn = Rn, Rdf = Rdf, R3 = R3, Rc = Rc, cash = cash, Mb = Mb, r520 = r520)
EIN[["overfitting/ofret_na"]] <- I
EIN[["overfitting/ofret_chr"]] <- list()
EIN[["overfitting/ofret_vec"]] <- I
EIN[["overfitting/ofmetric_err"]] <- list()
EIN[["overfitting/ofcolmetric"]] <- I
EIN[["overfitting/pbo_sharpe"]] <- I
for (m in c("sortino", "geometric", "mean")) EIN[[paste0("overfitting/", paste0("pbo_", m))]] <- I
EIN[["overfitting/pbo_S1"]] <- I
EIN[["overfitting/pbo_short"]] <- I
EIN[["overfitting/pbo_onecol"]] <- I
EIN[["overfitting/pbo_allflat"]] <- I
EIN[["overfitting/psr_def"]] <- I
EIN[["overfitting/dsr_def"]] <- I
EIN[["overfitting/dsr_badid"]] <- I
EIN[["overfitting/dsr_flat"]] <- I
EIN[["overfitting/dsr_one"]] <- I
EIN[["overfitting/dsr_rho_nan"]] <- I
EIN[["overfitting/hc_err"]] <- list()
EIN[["overfitting/hc_attr"]] <- list()
# ── overfit_walk_forward auf einer nachgebauten Suche ───────────────────────────────
set.seed(11); n <- 450   # bis 1.4.1 n <- 900 (kürzer, Abdeckung gleich)
wdates <- seq.Date(as.Date("2010-01-30"), by = "day", length.out = n)
Rw <- matrix(rnorm(n * 6, 3e-4, 0.01), n, dimnames = list(NULL, paste0("p", 1:6)))
Rw[, 2] <- Rw[, 2] + 4e-4
wres <- data.frame(id = 1:6, n = rep(c(50, 100, 200), 2), band = rep(c(0, 2), each = 3),
                   sharpe = apply(Rw, 2, function(r) mean(r) / sd(r)), error = NA_character_)
mkps <- function(method = "grid") structure(list(results = wres, returns = Rw, dates = wdates, space = param_space(n = c(50, 100, 200), band = c(0, 2)),
                                                 params = c("n", "band"), method = method, objective = "sharpe", maximize = TRUE,
                                                 sim_args = list(), burn_in = 0L), class = "SimLevParamSearch")
I2 <- c(I, list(Rw = Rw, wres = wres, wdates = wdates))
MK <- "def mkps(method='grid'):\n    return PS.SimLevParamSearch(results=wres, returns=Rw, dates=wdates, space=PS.param_space(n=[50.0, 100.0, 200.0], band=[0.0, 2.0]), params=['n', 'band'], method=method, objective='sharpe', maximize=True, sim_args={}, burn_in=0)\n"
MKJ <- 'mkps(method = "grid") = RList("results" => wres, "returns" => Rw, "dates" => wdates, "space" => PS.param_space(n = [50.0, 100.0, 200.0], band = [0.0, 2.0]), "params" => ["n", "band"], "method" => method, "objective" => "sharpe", "maximize" => true, "sim_args" => RList(), "burn_in" => 0; class = "SimLevParamSearch")\n'
# ── echte Suche: param_bootstrap und Prüfungen ──────────────────────────────
set.seed(2); nb <- 500
h <- data.frame(us = 1 + rnorm(nb, 3e-4, 0.01))
db <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = nb + 1), us = 100 * cumprod(c(1, h$us)))
I3 <- list(h = h, db = db)
BR <- "cfg <- bootstrap_config(c(us = 'us'))
st <- create_strategy(us = asset_config('etf', 'signal', signal_buy = 'buy', signal_sell = 'sell', spread = 0.1))
ps <- param_search(db, function(p) list(strategy = st, signal = function(df) signal_sma(df$us, p$n)), param_space(n = c(10, 20, 40)), burn_in = 50)\n"
BP <- "import simlev.signals as SG\nimport simlev.bootstrap as BS\nfrom simlev.config import create_strategy, asset_config\ncfg = BS.bootstrap_config({'us': 'us'})
st = create_strategy(us=asset_config(asset_class='etf', trading='signal', signal_buy='buy', signal_sell='sell', spread=0.1))
ps = PS.param_search(db, lambda p: {'strategy': st, 'signal': lambda df: SG.signal_sma(df['us'], n=p['n'])}, PS.param_space(n=[10.0, 20.0, 40.0]), burn_in=50)\n"
BJ <- 'cfg = SL.Bootstrap.bootstrap_config(named("us" => "us"))
st = create_strategy("us" => asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell", spread = 0.1))
ps = PS.param_search(db, p -> RList("strategy" => st, "signal" => df -> SL.Signals.signal_sma(df["us"]; n = p["n"])), PS.param_space(n = [10.0, 20.0, 40.0]); burn_in = 50)\n'

# Vorspann je Szenario bzw. Tabellenzeile (gemeinsame Objekte des Moduls)
VOR <- list(r = r"()",
            py = r"(import simlev.overfitting as OF
import simlev.param_search as PS)",
            jl = r"(const OF = SL.Overfitting
const PS = SL.ParamSearch)")

ref_init("overfitting", gruppe = "gleichlauf")
SZ("renditen_und_kennzahlen", ".of_returns mit NA (Wochen) und Vektor (Monate), .of_col_metric für sharpe, sortino, geometric, mean", vor = VOR, teile = list(
  ofret_na = teil(
    r"(SimLev:::.of_returns(Rn, 'week', dts))",
    r"(result = OF._of_returns(Rn, 'week', dts))",
    r"(result = OF._of_returns(Rn, "week", dts))", inp = ein("overfitting/ofret_na", c("dts", "Rn"))),
  ofret_vec = teil(
    r"(SimLev:::.of_returns(Rs[, 1], 'month'))",
    r"(result = OF._of_returns(Rs[:, 0], 'month'))",
    r"(result = OF._of_returns(Rs[:, 1], "month"))", inp = ein("overfitting/ofret_vec", c("Rs"))),
  ofcolmetric = teil(
    r"(lapply(c('sharpe', 'sortino', 'geometric', 'mean'), function(m) SimLev:::.of_col_metric(Mb, m)))",
    r"(result = [OF._of_col_metric(Mb, m) for m in ('sharpe', 'sortino', 'geometric', 'mean')])",
    r"(result = [OF._of_col_metric(Mb, m) for m in ("sharpe", "sortino", "geometric", "mean")])", inp = ein("overfitting/ofcolmetric", c("Mb")))))
SZ("pbo_und_bootstrap_pruefung", "overfit_pbo mit Sharpe; Kette param_search (einmal gerechnet) -> overfit_pbo, sharpe_deflated, sharpe_haircut, overfit_walk_forward bzw. param_bootstrap realer Strategien (Kennungen, cores = 2)", vor = VOR,
  gemein = teil(
    r"(cfg <- bootstrap_config(c(us = 'us'))
st <- create_strategy(us = asset_config('etf', 'signal', signal_buy = 'buy', signal_sell = 'sell', spread = 0.1))
ps <- param_search(db, function(p) list(strategy = st, signal = function(df) signal_sma(df$us, p$n)), param_space(n = c(10, 20, 40)), burn_in = 50))",
    r"(import simlev.signals as SG
import simlev.bootstrap as BS
from simlev.config import create_strategy, asset_config
cfg = BS.bootstrap_config({'us': 'us'})
st = create_strategy(us=asset_config(asset_class='etf', trading='signal', signal_buy='buy', signal_sell='sell', spread=0.1))
ps = PS.param_search(db, lambda p: {'strategy': st, 'signal': lambda df: SG.signal_sma(df['us'], n=p['n'])}, PS.param_space(n=[10.0, 20.0, 40.0]), burn_in=50))",
    r"(cfg = SL.Bootstrap.bootstrap_config(named("us" => "us"))
st = create_strategy("us" => asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell", spread = 0.1))
ps = PS.param_search(db, p -> RList("strategy" => st, "signal" => df -> SL.Signals.signal_sma(df["us"]; n = p["n"])), PS.param_space(n = [10.0, 20.0, 40.0]); burn_in = 50))"),
  teile = list(
  pbo_sharpe = teil(
    r"(overfit_pbo(R, S = 6, frequency = 'day'))",
    r"(result = OF.overfit_pbo(R, S=6, frequency='day'))",
    r"(result = OF.overfit_pbo(R; S = 6, frequency = "day"))", druck = TRUE, inp = ein("overfitting/pbo_sharpe", c("R"))),
  ps_real_checks = teil(
    r"(list(overfit_pbo(ps, S = 2, frequency = 'week'), sharpe_deflated(ps, frequency = 'day')$psr, sharpe_haircut(ps, frequency = 'month'), overfit_walk_forward(ps, train = 0.5, test = 0.25)$summary))",
    r"(result = [OF.overfit_pbo(ps, S=2, frequency='week'), OF.sharpe_deflated(ps, frequency='day')['psr'], OF.sharpe_haircut(ps, frequency='month'), OF.overfit_walk_forward(ps, train=0.5, test=0.25)['summary']])",
    r"(result = [OF.overfit_pbo(ps; S = 2, frequency = "week"), OF.sharpe_deflated(ps; frequency = "day")["psr"], OF.sharpe_haircut(ps; frequency = "month"), OF.overfit_walk_forward(ps; train = 0.5, test = 0.25)["summary"]])", inp = ein("overfitting/ps_real_checks", c("db"))),
  pb_ids = teil(
    r"(bs <- param_bootstrap(ps, h, cfg, ids = c(3, 1), map = c(x = 'us'), include = list(bh = create_strategy(us = asset_config('etf', 'bnh', spread = 0.1))), method = 'raw', n = 2, seed = 4, progress = FALSE, burn_in = 60); list(attr(bs, 'param_ids'), bs$results))",
    r"(bs = OF.param_bootstrap(ps, h, cfg, ids=[3, 1], map={'x': 'us'}, include={'bh': create_strategy(us=asset_config(asset_class='etf', trading='bnh', spread=0.1))}, method='raw', n=2, seed=4, progress=False, burn_in=60); result = [bs.attrs['param_ids'], bs['results']])",
    r"(bs = OF.param_bootstrap(ps, h, cfg; ids = [3, 1], map = named("x" => "us"), include = RList("bh" => create_strategy("us" => asset_config("etf", "bnh", spread = 0.1))), method = "raw", n = 2, seed = 4, progress = false, burn_in = 60); result = [OF.param_ids(bs), bs["results"]])", inp = ein("overfitting/pb_ids", c("h", "db"))),
  pb_cores2 = teil(
    r"(bs <- param_bootstrap(ps, h, cfg, top = 2, method = 'stationary', n = 3, params = list(L = 50), seed = 1, progress = FALSE, chunk_size = 1, cores = 2); list(attr(bs, 'param_ids'), bs$results))",
    r"(bs = OF.param_bootstrap(ps, h, cfg, top=2, method='stationary', n=3, params={'L': 50}, seed=1, progress=False, chunk_size=1, cores=2); result = [bs.attrs['param_ids'], bs['results']])",
    r"(bs = OF.param_bootstrap(ps, h, cfg; top = 2, method = "stationary", n = 3, params = RList("L" => 50), seed = 1, progress = false, chunk_size = 1, cores = 2); result = [OF.param_ids(bs), bs["results"]])", inp = ein("overfitting/pb_cores2", c("h", "db")))))
SZ("sharpe_korrekturen", "sharpe_probabilistic, sharpe_deflated (mehrere und eine Strategie), sharpe_haircut mit Attributen", vor = VOR, teile = list(
  psr_def = teil(
    r"(sharpe_probabilistic(R[, 2]))",
    r"(result = OF.sharpe_probabilistic(R[:, 1]))",
    r"(result = OF.sharpe_probabilistic(R[:, 2]))", inp = ein("overfitting/psr_def", c("R"))),
  dsr_def = teil(
    r"(sharpe_deflated(R, frequency = 'day'))",
    r"(result = OF.sharpe_deflated(R, frequency='day'))",
    r"(result = OF.sharpe_deflated(R; frequency = "day"))", druck = TRUE, inp = ein("overfitting/dsr_def", c("R"))),
  dsr_one = teil(
    r"(sharpe_deflated(R[, 1, drop = FALSE], frequency = 'day'))",
    r"(result = OF.sharpe_deflated(R[:, :1], frequency='day'))",
    r"(result = OF.sharpe_deflated(R[:, 1:1]; frequency = "day"))", druck = TRUE, inp = ein("overfitting/dsr_one", c("R"))),
  hc_attr = teil(
    r"(h <- sharpe_haircut(c(1, 0.5, 2), n_obs = 100, n_tests = 7); c(attr(h, 'n_tests'), attr(h, 'n_obs')))",
    r"(h = OF.sharpe_haircut([1, 0.5, 2], n_obs=100, n_tests=7); result = [h.attrs['n_tests'], h.attrs['n_obs']])",
    r"(h = OF.sharpe_haircut([1, 0.5, 2]; n_obs = 100, n_tests = 7); result = [attrs(h)["n_tests"], attrs(h)["n_obs"]])", inp = ein("overfitting/hc_attr", c()))))
SZ("walk_forward", "overfit_walk_forward mit bestem Punkt und mit Plateau-Auswahl", vor = VOR, teile = list(
  wf_basic = teil(
    r"(overfit_walk_forward(mkps('grid'), train = 1, test = 0.5))",
    r"(def mkps(method='grid'):
    return PS.SimLevParamSearch(results=wres, returns=Rw, dates=wdates, space=PS.param_space(n=[50.0, 100.0, 200.0], band=[0.0, 2.0]), params=['n', 'band'], method=method, objective='sharpe', maximize=True, sim_args={}, burn_in=0)
result = OF.overfit_walk_forward(mkps('grid'), train=1, test=0.5))",
    r"(mkps(method = "grid") = RList("results" => wres, "returns" => Rw, "dates" => wdates, "space" => PS.param_space(n = [50.0, 100.0, 200.0], band = [0.0, 2.0]), "params" => ["n", "band"], "method" => method, "objective" => "sharpe", "maximize" => true, "sim_args" => RList(), "burn_in" => 0; class = "SimLevParamSearch")
result = OF.overfit_walk_forward(mkps("grid"); train = 1, test = 0.5))", druck = TRUE, inp = ein("overfitting/wf_basic", c("Rw", "wres", "wdates"))),
  wf_plateau = teil(
    r"(overfit_walk_forward(mkps('grid'), train = 1, test = 0.5, select = 'plateau'))",
    r"(def mkps(method='grid'):
    return PS.SimLevParamSearch(results=wres, returns=Rw, dates=wdates, space=PS.param_space(n=[50.0, 100.0, 200.0], band=[0.0, 2.0]), params=['n', 'band'], method=method, objective='sharpe', maximize=True, sim_args={}, burn_in=0)
result = OF.overfit_walk_forward(mkps('grid'), train=1, test=0.5, select='plateau'))",
    r"(mkps(method = "grid") = RList("results" => wres, "returns" => Rw, "dates" => wdates, "space" => PS.param_space(n = [50.0, 100.0, 200.0], band = [0.0, 2.0]), "params" => ["n", "band"], "method" => method, "objective" => "sharpe", "maximize" => true, "sim_args" => RList(), "burn_in" => 0; class = "SimLevParamSearch")
result = OF.overfit_walk_forward(mkps("grid"); train = 1, test = 0.5, select = "plateau"))", druck = TRUE, inp = ein("overfitting/wf_plateau", c("Rw", "wres", "wdates")))))
ref_done()

ref_init("overfitting", gruppe = "fehler")
TB(".of_returns", "Meldungen und Warnungen von .of_returns je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("ofret_chr",
    r"(SimLev:::.of_returns(data.frame(a = c('x', 'y')), 'day'))",
    r"(result = OF._of_returns(pd.DataFrame({'a': ['x', 'y']}), 'day'))",
    r"(result = OF._of_returns(RFrame("a" => ["x", "y"]), "day"))", inp = ein("overfitting/ofret_chr", c()))))
TB(".of_metric", "Meldungen und Warnungen von .of_metric je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("ofmetric_err",
    r"(SimLev:::.of_metric(10, 1, 1, 1, 1, 'foo'))",
    r"(result = OF._of_metric(10, 1.0, 1.0, 1.0, 1.0, 'foo'))",
    r"(result = OF._of_metric(10, 1.0, 1.0, 1.0, 1.0, "foo"))", inp = ein("overfitting/ofmetric_err", c()))))
TB("overfit_pbo", "Meldungen und Warnungen von overfit_pbo je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("pbo_S1",
    r"(overfit_pbo(R, S = 1))",
    r"(result = OF.overfit_pbo(R, S=1))",
    r"(result = OF.overfit_pbo(R; S = 1))", inp = ein("overfitting/pbo_S1", c("R"))),
  zeile("pbo_short",
    r"(overfit_pbo(R[1:30, ], S = 8, frequency = 'day'))",
    r"(result = OF.overfit_pbo(R[:30], S=8, frequency='day'))",
    r"(result = OF.overfit_pbo(R[1:30, :]; S = 8, frequency = "day"))", inp = ein("overfitting/pbo_short", c("R"))),
  zeile("pbo_onecol",
    r"(overfit_pbo(R[, 1, drop = FALSE], S = 4, frequency = 'day'))",
    r"(result = OF.overfit_pbo(R[:, :1], S=4, frequency='day'))",
    r"(result = OF.overfit_pbo(R[:, 1:1]; S = 4, frequency = "day"))", inp = ein("overfitting/pbo_onecol", c("R"))),
  zeile("pbo_allflat",
    r"(overfit_pbo(cbind(cash, cash), S = 4, frequency = 'day'))",
    r"(result = OF.overfit_pbo(np.column_stack([cash, cash]), S=4, frequency='day'))",
    r"(result = OF.overfit_pbo(hcat(cash, cash); S = 4, frequency = "day"))", inp = ein("overfitting/pbo_allflat", c("cash"))),
  zeile("of_noret",
    r"(x <- mkps(); x$returns <- NULL; overfit_pbo(x))",
    r"(def mkps(method='grid'):
    return PS.SimLevParamSearch(results=wres, returns=Rw, dates=wdates, space=PS.param_space(n=[50.0, 100.0, 200.0], band=[0.0, 2.0]), params=['n', 'band'], method=method, objective='sharpe', maximize=True, sim_args={}, burn_in=0)
x = mkps(); x['returns'] = None; result = OF.overfit_pbo(x))",
    r"(mkps(method = "grid") = RList("results" => wres, "returns" => Rw, "dates" => wdates, "space" => PS.param_space(n = [50.0, 100.0, 200.0], band = [0.0, 2.0]), "params" => ["n", "band"], "method" => method, "objective" => "sharpe", "maximize" => true, "sim_args" => RList(), "burn_in" => 0; class = "SimLevParamSearch")
x = mkps(); x["returns"] = nothing; result = OF.overfit_pbo(x))", inp = ein("overfitting/of_noret", c("Rw", "wres", "wdates")))))
TB("sharpe_deflated", "Meldungen und Warnungen von sharpe_deflated je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("dsr_badid",
    r"(sharpe_deflated(R, id = 9, frequency = 'day'))",
    r"(result = OF.sharpe_deflated(R, id=9, frequency='day'))",
    r"(result = OF.sharpe_deflated(R; id = 9, frequency = "day"))", inp = ein("overfitting/dsr_badid", c("R"))),
  zeile("dsr_flat",
    r"(sharpe_deflated(cbind(Rc, cash), frequency = 'day', id = 1))",
    r"(result = OF.sharpe_deflated(np.column_stack([Rc, cash]), frequency='day', id=1))",
    r"(result = OF.sharpe_deflated(hcat(Rc, cash); frequency = "day", id = 1))", print = TRUE, inp = ein("overfitting/dsr_flat", c("Rc", "cash"))),
  zeile("dsr_rho_nan",
    r"(sharpe_deflated(R[, 2:3] * 1e160, frequency = 'day'))",
    r"(result = OF.sharpe_deflated(R[:, 1:3] * 1e160, frequency='day'))",
    r"(result = OF.sharpe_deflated(R[:, 2:3] .* 1e160; frequency = "day"))", inp = ein("overfitting/dsr_rho_nan", c("R")))))
TB("sharpe_haircut", "Meldungen und Warnungen von sharpe_haircut je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("hc_err",
    r"(sharpe_haircut(c(1, 0.5)))",
    r"(result = OF.sharpe_haircut([1, 0.5]))",
    r"(result = OF.sharpe_haircut([1, 0.5]))", inp = ein("overfitting/hc_err", c()))))
TB("overfit_walk_forward", "Meldungen und Warnungen von overfit_walk_forward je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("wf_short",
    r"(overfit_walk_forward(mkps('grid'), train = 3, test = 1))",
    r"(def mkps(method='grid'):
    return PS.SimLevParamSearch(results=wres, returns=Rw, dates=wdates, space=PS.param_space(n=[50.0, 100.0, 200.0], band=[0.0, 2.0]), params=['n', 'band'], method=method, objective='sharpe', maximize=True, sim_args={}, burn_in=0)
result = OF.overfit_walk_forward(mkps('grid'), train=3, test=1))",
    r"(mkps(method = "grid") = RList("results" => wres, "returns" => Rw, "dates" => wdates, "space" => PS.param_space(n = [50.0, 100.0, 200.0], band = [0.0, 2.0]), "params" => ["n", "band"], "method" => method, "objective" => "sharpe", "maximize" => true, "sim_args" => RList(), "burn_in" => 0; class = "SimLevParamSearch")
result = OF.overfit_walk_forward(mkps("grid"); train = 3, test = 1))", inp = ein("overfitting/wf_short", c("Rw", "wres", "wdates"))),
  zeile("wf_notps",
    r"(overfit_walk_forward(Rw))",
    r"(result = OF.overfit_walk_forward(Rw))",
    r"(result = OF.overfit_walk_forward(Rw))", inp = ein("overfitting/wf_notps", c("Rw")))))
TB("param_bootstrap", "Meldungen und Warnungen von param_bootstrap je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("pb_err",
    r"(cfg <- bootstrap_config(c(us = 'us'))
st <- create_strategy(us = asset_config('etf', 'signal', signal_buy = 'buy', signal_sell = 'sell', spread = 0.1))
ps <- param_search(db, function(p) list(strategy = st, signal = function(df) signal_sma(df$us, p$n)), param_space(n = c(10, 20, 40)), burn_in = 50)
param_bootstrap(list(a = 1), h, cfg))",
    r"(import simlev.signals as SG
import simlev.bootstrap as BS
from simlev.config import create_strategy, asset_config
cfg = BS.bootstrap_config({'us': 'us'})
st = create_strategy(us=asset_config(asset_class='etf', trading='signal', signal_buy='buy', signal_sell='sell', spread=0.1))
ps = PS.param_search(db, lambda p: {'strategy': st, 'signal': lambda df: SG.signal_sma(df['us'], n=p['n'])}, PS.param_space(n=[10.0, 20.0, 40.0]), burn_in=50)
result = OF.param_bootstrap({'a': 1}, h, cfg))",
    r"(cfg = SL.Bootstrap.bootstrap_config(named("us" => "us"))
st = create_strategy("us" => asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell", spread = 0.1))
ps = PS.param_search(db, p -> RList("strategy" => st, "signal" => df -> SL.Signals.signal_sma(df["us"]; n = p["n"])), PS.param_space(n = [10.0, 20.0, 40.0]); burn_in = 50)
result = OF.param_bootstrap(RList("a" => 1), h, cfg))", inp = ein("overfitting/pb_err", c("h", "db")))))
ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul sensitivity
# ════════════════════════════════════════════════════════════════════════════════════════════════════
P <- paste0("import simlev.sensitivity as SE\nfrom simlev.config import create_strategy, asset_config\n",
            "from simlev import dca_plan, rebalance_plan, tax_profile, income_rate\n",
            "st = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.6, spread=0.1), B=asset_config(asset_class='etf', trading='bnh', share=0.4, spread=0.1))\n",
            "st0 = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.6, spread=0), B=asset_config(asset_class='etf', trading='bnh', share=0.4, spread=0))\n",
            "st1 = create_strategy(A=asset_config(asset_class='etf', trading='bnh', spread=0.1))\n")
R0 <- paste0("st <- create_strategy(A = asset_config('etf', 'bnh', 0.6, spread = 0.1), B = asset_config('etf', 'bnh', 0.4, spread = 0.1))\n",
             "st0 <- create_strategy(A = asset_config('etf', 'bnh', 0.6, spread = 0), B = asset_config('etf', 'bnh', 0.4, spread = 0))\n",
             "st1 <- create_strategy(A = asset_config('etf', 'bnh', spread = 0.1))\n")
set.seed(1); n <- 550   # bis 1.4.1 n <- 1100 (kürzer, Abdeckung gleich)
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
st = create_strategy("A" => asset_config("etf", "bnh", 0.6, spread = 0.1), "B" => asset_config("etf", "bnh", 0.4, spread = 0.1))
st0 = create_strategy("A" => asset_config("etf", "bnh", 0.6; spread = 0), "B" => asset_config("etf", "bnh", 0.4; spread = 0))
st1 = create_strategy("A" => asset_config("etf", "bnh", spread = 0.1))
'
EIN[["sensitivity/sg_df"]] <- I
EIN[["sensitivity/sg_keep"]] <- I
EIN[["sensitivity/sg_empty"]] <- I
EIN[["sensitivity/sg_path_church"]] <- I
EIN[["sensitivity/sg_path_sub"]] <- I
EIN[["sensitivity/sg_path_novalue"]] <- I
EIN[["sensitivity/sg_err_flat2"]] <- I
EIN[["sensitivity/sg_err_block"]] <- I
EIN[["sensitivity/rs_bands"]] <- I
EIN[["sensitivity/rs_relative"]] <- I
EIN[["sensitivity/rs_dca"]] <- I
EIN[["sensitivity/rs_errall"]] <- I
EIN[["sensitivity/ls_rebal"]] <- I
EIN[["sensitivity/ls_tax"]] <- I
EIN[["sensitivity/ls_err_sv"]] <- I
EIN[["sensitivity/ls_err_short"]] <- I
EIN[["sensitivity/lev_ko"]] <- I
EIN[["sensitivity/lvs_basic"]] <- I
EIN[["sensitivity/lvs_opt"]] <- I
EIN[["sensitivity/lvs_none"]] <- I

# Vorspann je Szenario bzw. Tabellenzeile (gemeinsame Objekte des Moduls)
VOR <- list(r = r"(st <- create_strategy(A = asset_config('etf', 'bnh', 0.6, spread = 0.1), B = asset_config('etf', 'bnh', 0.4, spread = 0.1))
st0 <- create_strategy(A = asset_config('etf', 'bnh', 0.6, spread = 0), B = asset_config('etf', 'bnh', 0.4, spread = 0))
st1 <- create_strategy(A = asset_config('etf', 'bnh', spread = 0.1)))",
            py = r"(import simlev.sensitivity as SE
from simlev.config import create_strategy, asset_config
from simlev import dca_plan, rebalance_plan, tax_profile, income_rate
st = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.6, spread=0.1), B=asset_config(asset_class='etf', trading='bnh', share=0.4, spread=0.1))
st0 = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.6, spread=0), B=asset_config(asset_class='etf', trading='bnh', share=0.4, spread=0))
st1 = create_strategy(A=asset_config(asset_class='etf', trading='bnh', spread=0.1)))",
            jl = r"(const SE = SL.Sensitivity
st = create_strategy("A" => asset_config("etf", "bnh", 0.6, spread = 0.1), "B" => asset_config("etf", "bnh", 0.4, spread = 0.1))
st0 = create_strategy("A" => asset_config("etf", "bnh", 0.6; spread = 0), "B" => asset_config("etf", "bnh", 0.4; spread = 0))
st1 = create_strategy("A" => asset_config("etf", "bnh", spread = 0.1)))")

ref_init("sensitivity", gruppe = "gleichlauf")
SZ("gitter", "sensitivity_grid mit Tabelle als Gitter (Splits), keep, Pfaden in tax (church_tax, income.marginal_rate, harvest.day)", vor = VOR, teile = list(
  sg_df = teil(
    r"(g <- data.frame(row.names = 1:2); g$splits.thresh <- list(c(50, 120), c(80, 110)); sensitivity_grid(d, st1, g))",
    r"(g = pd.DataFrame({'splits.thresh': pd.Series([[50.0, 120.0], [80.0, 110.0]], dtype=object)}); result = SE.sensitivity_grid(d, st1, g))",
    r"(g = RFrame("splits.thresh" => [[50.0, 120.0], [80.0, 110.0]]); result = SE.sensitivity_grid(d, st1, g))", inp = ein("sensitivity/sg_df", c("d"))),
  sg_keep = teil(
    r"(g <- sensitivity_grid(d, st, list(rebalance.span = c(1, 3)), sim_args = list(rebalance = rebalance_plan()), keep_results = TRUE); r <- attr(g, 'results'); c(length(r), r[[2]]$cagr, r[[1]]$worth[100]))",
    r"(g = SE.sensitivity_grid(d, st, {'rebalance.span': [1, 3]}, sim_args={'rebalance': rebalance_plan()}, keep_results=True); r = g.attrs['results']; result = [len(r), r[1].cagr, r[0].worth[99]])",
    r"(g = SE.sensitivity_grid(d, st, RList("rebalance.span" => [1.0, 3.0]); sim_args = RList("rebalance" => SL.rebalance_plan()), keep_results = true); r = attrs(g)["results"]; result = [length(r), r[2].cagr, r[1].worth[100]])", inp = ein("sensitivity/sg_keep", c("d"))),
  sg_path_church = teil(
    r"(sensitivity_grid(d, st, list(tax.church_tax = c(0, 9)), sim_args = list(tax = tax_profile(church_tax = 8), liquidate = TRUE)))",
    r"(result = SE.sensitivity_grid(d, st, {'tax.church_tax': [0, 9]}, sim_args={'tax': tax_profile(church_tax=8), 'liquidate': True}))",
    r"(result = SE.sensitivity_grid(d, st, RList("tax.church_tax" => [0, 9]); sim_args = RList("tax" => SL.tax_profile(; church_tax = 8), "liquidate" => true)))", inp = ein("sensitivity/sg_path_church", c("d"))),
  sg_path_sub = teil(
    r"(sensitivity_grid(d, st, list(tax.income.marginal_rate = c(14, 42), tax.harvest.day = c('06-30', '12-15')), sim_args = list(tax = tax_profile(guenstigerpruefung = TRUE))))",
    r"(result = SE.sensitivity_grid(d, st, {'tax.income.marginal_rate': [14, 42], 'tax.harvest.day': ['06-30', '12-15']}, sim_args={'tax': tax_profile(guenstigerpruefung=True)}))",
    r"(result = SE.sensitivity_grid(d, st, RList("tax.income.marginal_rate" => [14, 42], "tax.harvest.day" => ["06-30", "12-15"]); sim_args = RList("tax" => SL.tax_profile(; guenstigerpruefung = true))))", inp = ein("sensitivity/sg_path_sub", c("d")))))
SZ("umschichten", "sensitivity_rebalancing mit Bändern, relativ und mit Sparplan; planning_lumpsum_vs_dca mit Umschichten", vor = VOR, teile = list(
  rs_bands = teil(
    r"(sensitivity_rebalancing(d, st, frequencies = list(monthly = c('month', 1), yearly = c('year', 1)), bands = c(NA, 5)))",
    r"(result = SE.sensitivity_rebalancing(d, st, frequencies={'monthly': ('month', 1), 'yearly': ('year', 1)}, bands=[None, 5]))",
    r"(result = SE.sensitivity_rebalancing(d, st; frequencies = ["monthly" => ("month", 1), "yearly" => ("year", 1)], bands = [NA, 5.0]))", druck = TRUE, inp = ein("sensitivity/rs_bands", c("d"))),
  rs_relative = teil(
    r"(sensitivity_rebalancing(d, st, frequencies = list(q = c('quarter', 1), y = c('year', 1)), offsets = c(0, 5), bands = c(NA, 10), band_type = 'relative'))",
    r"(result = SE.sensitivity_rebalancing(d, st, frequencies={'q': ('quarter', 1), 'y': ('year', 1)}, offsets=[0, 5], bands=[None, 10], band_type='relative'))",
    r"(result = SE.sensitivity_rebalancing(d, st; frequencies = ["q" => ("quarter", 1), "y" => ("year", 1)], offsets = [0, 5], bands = [NA, 10.0], band_type = "relative"))", druck = TRUE, inp = ein("sensitivity/rs_relative", c("d"))),
  rs_dca = teil(
    r"(sensitivity_rebalancing(d, st, frequencies = list(yearly = c('year', 1)), sim_args = list(dca = dca_plan(100, 1))))",
    r"(result = SE.sensitivity_rebalancing(d, st, frequencies={'yearly': ('year', 1)}, sim_args={'dca': dca_plan(100, 1)}))",
    r"(result = SE.sensitivity_rebalancing(d, st; frequencies = ["yearly" => ("year", 1)], sim_args = RList("dca" => SL.dca_plan(100, 1))))", druck = TRUE, inp = ein("sensitivity/rs_dca", c("d"))),
  ls_rebal = teil(
    r"(x <- planning_lumpsum_vs_dca(d5, st0, amount = 6000, months = 6, horizon = 2, step = 12, sim_args = list(rebalance = rebalance_plan(span = 3))); list(x, attr(x, 'summary')))",
    r"(x = SE.planning_lumpsum_vs_dca(d5, st0, amount=6000, months=6, horizon=2, step=12, sim_args={'rebalance': rebalance_plan(span=3)}); result = [x, x.attrs['summary']])",
    r"(x = SE.planning_lumpsum_vs_dca(d5, st0; amount = 6000, months = 6, horizon = 2, step = 12, sim_args = RList("rebalance" => SL.rebalance_plan(; span = 3))); result = [x, attrs(x)["summary"]])", inp = ein("sensitivity/ls_rebal", c("d5")))))
SZ("hebel", "series_leverage mit Knock-out, sensitivity_leverage mit Strategie, mit Spread und ohne passende Strategie", vor = VOR, teile = list(
  lev_ko = teil(
    r"(series_leverage(d, 'A', leverage = 80))",
    r"(result = SE.series_leverage(d, 'A', leverage=80))",
    r"(result = SE.series_leverage(d, "A"; leverage = 80))", inp = ein("sensitivity/lev_ko", c("d"))),
  lvs_basic = teil(
    r"(sensitivity_leverage(d, 'A', leverages = c(1, 2, 3), rate = 2, expense = 0.5, strategy = create_strategy(LEV = asset_config('etf', 'bnh', partial_exemption = 30, spread = 0.1))))",
    r"(result = SE.sensitivity_leverage(d, 'A', leverages=[1, 2, 3], rate=2, expense=0.5, strategy=create_strategy(LEV=asset_config(asset_class='etf', trading='bnh', partial_exemption=30, spread=0.1))))",
    r"(result = SE.sensitivity_leverage(d, "A"; leverages = [1, 2, 3], rate = 2, expense = 0.5, strategy = create_strategy("LEV" => asset_config("etf", "bnh", partial_exemption = 30, spread = 0.1))))", druck = TRUE, inp = ein("sensitivity/lvs_basic", c("d"))),
  lvs_opt = teil(
    r"(x <- sensitivity_leverage(d, 'A', leverages = c(1, 1.5, 2), rate = 2, spread = 0.4); list(attr(x, 'optimal'), attr(x, 'kind')))",
    r"(x = SE.sensitivity_leverage(d, 'A', leverages=[1, 1.5, 2], rate=2, spread=0.4); result = [x.attrs['optimal'], x.attrs['kind']])",
    r"(x = SE.sensitivity_leverage(d, "A"; leverages = [1, 1.5, 2], rate = 2, spread = 0.4); result = [attrs(x)["optimal"], attrs(x)["kind"]])", inp = ein("sensitivity/lvs_opt", c("d"))),
  lvs_none = teil(
    r"(x <- sensitivity_leverage(d, 'A', leverages = c(1, 2), strategy = create_strategy(X = asset_config('etf', 'bnh', spread = 0.1))); list(x, attr(x, 'optimal')))",
    r"(x = SE.sensitivity_leverage(d, 'A', leverages=[1, 2], strategy=create_strategy(X=asset_config(asset_class='etf', trading='bnh', spread=0.1))); result = [x, x.attrs['optimal']])",
    r"(x = SE.sensitivity_leverage(d, "A"; leverages = [1, 2], strategy = create_strategy("X" => asset_config("etf", "bnh", spread = 0.1))); result = [x, attrs(x)["optimal"]])", inp = ein("sensitivity/lvs_none", c("d")))))
ref_done()

ref_init("sensitivity", gruppe = "fehler")
TB("sensitivity_grid", "Meldungen und Warnungen von sensitivity_grid je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("sg_empty",
    r"(sensitivity_grid(d, st, data.frame(rebalance.thresh = numeric(0))))",
    r"(result = SE.sensitivity_grid(d, st, pd.DataFrame({'rebalance.thresh': np.zeros(0)})))",
    r"(result = SE.sensitivity_grid(d, st, RFrame("rebalance.thresh" => Float64[])))", inp = ein("sensitivity/sg_empty", c("d"))),
  zeile("sg_path_novalue",
    r"(sensitivity_grid(d, st, list(dca.span = c(1, 3))))",
    r"(result = SE.sensitivity_grid(d, st, {'dca.span': [1, 3]}))",
    r"(result = SE.sensitivity_grid(d, st, RList("dca.span" => [1, 3])))", inp = ein("sensitivity/sg_path_novalue", c("d"))),
  zeile("sg_err_cores",   # Standard "auto"; ungültig -> Meldung par.cores (seit 1.6.4, Entscheidung 113)
    r"(sensitivity_grid(d, st, list(rebalance.thresh = c(5, 10)), cores = 0))",
    r"(result = SE.sensitivity_grid(d, st, {'rebalance.thresh': [5.0, 10.0]}, cores=0))",
    r"(result = SE.sensitivity_grid(d, st, RList("rebalance.thresh" => [5.0, 10.0]); cores = 0))", inp = ein("sensitivity/sg_path_novalue", c("d"))),
  zeile("sg_err_flat2",
    r"(sensitivity_grid(d, st, list(marginal_tax_rate = c(14, 42))))",
    r"(result = SE.sensitivity_grid(d, st, {'marginal_tax_rate': [14, 42]}))",
    r"(result = SE.sensitivity_grid(d, st, RList("marginal_tax_rate" => [14, 42])))", inp = ein("sensitivity/sg_err_flat2", c("d"))),
  zeile("sg_err_block",
    r"(sensitivity_grid(d, st, list(foo.bar = 1)))",
    r"(result = SE.sensitivity_grid(d, st, {'foo.bar': [1]}))",
    r"(result = SE.sensitivity_grid(d, st, RList("foo.bar" => [1])))", inp = ein("sensitivity/sg_err_block", c("d")))))
TB("sensitivity_rebalancing", "Meldungen und Warnungen von sensitivity_rebalancing je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("rs_errall",
    r"(sensitivity_rebalancing(d, st, frequencies = list(x = c('monat', 1)), include_none = FALSE))",
    r"(result = SE.sensitivity_rebalancing(d, st, frequencies={'x': ('monat', 1)}, include_none=False))",
    r"(result = SE.sensitivity_rebalancing(d, st; frequencies = ["x" => ("monat", 1)], include_none = false))", inp = ein("sensitivity/rs_errall", c("d"))),
  zeile("rs_err_cores",   # Standard "auto"; ungültig -> Meldung par.cores (seit 1.6.4, Entscheidung 113)
    r"(sensitivity_rebalancing(d, st, frequencies = list(x = c('month', 1)), include_none = FALSE, cores = 0))",
    r"(result = SE.sensitivity_rebalancing(d, st, frequencies={'x': ('month', 1)}, include_none=False, cores=0))",
    r"(result = SE.sensitivity_rebalancing(d, st; frequencies = ["x" => ("month", 1)], include_none = false, cores = 0))", inp = ein("sensitivity/rs_errall", c("d")))))
TB("sensitivity_leverage", "Meldungen und Warnungen von sensitivity_leverage je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("lvs_err_cores",   # Standard "auto"; ungültig -> Meldung par.cores (seit 1.6.4, Entscheidung 113)
    r"(sensitivity_leverage(d, 'A', leverages = c(1, 1.5, 2), rate = 2, spread = 0.4, cores = 0))",
    r"(result = SE.sensitivity_leverage(d, 'A', leverages=[1, 1.5, 2], rate=2, spread=0.4, cores=0))",
    r"(result = SE.sensitivity_leverage(d, "A"; leverages = [1, 1.5, 2], rate = 2, spread = 0.4, cores = 0))", inp = ein("sensitivity/lvs_opt", c("d")))))
TB("planning_lumpsum_vs_dca", "Meldungen und Warnungen von planning_lumpsum_vs_dca je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("ls_tax",
    r"(planning_lumpsum_vs_dca(d5, st1, months = 6, horizon = 3, step = 12, sim_args = list(tax = tax_profile())))",
    r"(result = SE.planning_lumpsum_vs_dca(d5, st1, months=6, horizon=3, step=12, sim_args={'tax': tax_profile()}))",
    r"(result = SE.planning_lumpsum_vs_dca(d5, st1; months = 6, horizon = 3, step = 12, sim_args = RList("tax" => SL.tax_profile())))", print = TRUE, inp = ein("sensitivity/ls_tax", c("d5"))),
  zeile("ls_err_cores",   # Standard "auto"; ungültig -> Meldung par.cores (seit 1.6.4, Entscheidung 113)
    r"(planning_lumpsum_vs_dca(d5, st1, months = 6, horizon = 3, step = 12, cores = 0))",
    r"(result = SE.planning_lumpsum_vs_dca(d5, st1, months=6, horizon=3, step=12, cores=0))",
    r"(result = SE.planning_lumpsum_vs_dca(d5, st1; months = 6, horizon = 3, step = 12, cores = 0))", inp = ein("sensitivity/ls_tax", c("d5"))),
  zeile("ls_err_sv",
    r"(planning_lumpsum_vs_dca(d5, st1, horizon = 2, step = 6, sim_args = list(start_value = 5000)))",
    r"(result = SE.planning_lumpsum_vs_dca(d5, st1, horizon=2, step=6, sim_args={'start_value': 5000}))",
    r"(result = SE.planning_lumpsum_vs_dca(d5, st1; horizon = 2, step = 6, sim_args = RList("start_value" => 5000)))", inp = ein("sensitivity/ls_err_sv", c("d5"))),
  zeile("ls_err_short",
    r"(planning_lumpsum_vs_dca(d5, st1, horizon = 10))",
    r"(result = SE.planning_lumpsum_vs_dca(d5, st1, horizon=10))",
    r"(result = SE.planning_lumpsum_vs_dca(d5, st1; horizon = 10))", inp = ein("sensitivity/ls_err_short", c("d5")))))
ref_done()

ref_schreiben()
