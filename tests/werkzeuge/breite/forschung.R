# tests/werkzeuge/breite/forschung.R – Referenzfälle des Bereichs forschung: Parametersuche, Overfitting-Diagnosen, Sensitivität.
# Module: param_search, overfitting, sensitivity (bis 1.4.0 je ein Generator gen_<modul>.R, hier wörtlich hintereinander).
# Aufruf (Repo-Wurzel): LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/breite/forschung.R
# Breitenprüfung, nichts abgelegt: alle bisherigen Einzelfälle des Bereichs (bis 1.4.1 Generator des Katalogs) flach nach
# <ordner>/breite_forschung.jsonl.gz; tests/werkzeuge/gleichlauf/run.sh vergleicht Python und Julia damit. Abgelegt sind die Szenarien
# und Tabellen aus tests/gleichlauf/erzeugen/forschung.R (Format und Umgebung: tests/gleichlauf/erzeugen/ref_tools.R).
source("tests/gleichlauf/erzeugen/ref_tools.R")
ref_bereich("breite_forschung", alle = TRUE)

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul param_search
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Referenzfälle für param_search.R (param_space, param_range, param_search,
# param_plateau, print/summary, .ps_*-Helfer, .run_spec, .as_spec).
ref_init("param_search")
P <- paste0("import simlev.param_search as PS\nimport simlev.overfitting as OF\nimport simlev.signals as SG\n",
            "from simlev.config import create_strategy, asset_config\n")
py <- function(code) paste0(P, code)
J <- "const PS = SL.ParamSearch\n"
jl <- function(code) paste0(J, code)

# ── Suchraum ────────────────────────────────────────────────────────────────
SP <- "sp <- param_space(n = param_range(50, 400, n = 8, integer = TRUE, log = TRUE), band = c(0, 1, 2), w = param_range(0.3, 0.9, step = 0.1), s = c('x', 'yy'), f = c(TRUE, FALSE), m = param_range(1, 2))"
SPP <- "sp = PS.param_space(n=PS.param_range(50, 400, n=8, integer=True, log=True), band=[0.0, 1.0, 2.0], w=PS.param_range(0.3, 0.9, step=0.1), s=['x', 'yy'], f=[True, False], m=PS.param_range(1, 2))\n"
SPJ <- 'sp = PS.param_space(n = PS.param_range(50, 400; n = 8, integer = true, log = true), band = [0.0, 1.0, 2.0], w = PS.param_range(0.3, 0.9; step = 0.1), s = ["x", "yy"], f = [true, false], m = PS.param_range(1, 2))\n'
ref_case("space", paste0(SP, "; sp"), py(paste0(SPP, "result = sp")), jl = jl(paste0(SPJ, 'result = sp')))
ref_case("space_long", "param_space(a = 1:20, b = param_range(0.001, 1234.5, step = 0.25))",
         py("result = PS.param_space(a=list(range(1, 21)), b=PS.param_range(0.001, 1234.5, step=0.25))"), jl = jl('result = PS.param_space(a = collect(1:20), b = PS.param_range(0.001, 1234.5; step = 0.25))'))
ref_case("space_err0", "param_space()", py("result = PS.param_space()"), jl = jl('result = PS.param_space()'))
ref_case("space_err1", "param_space(1:3)", py("result = PS.param_space([1, 2, 3])"), jl = jl('result = PS.param_space([1, 2, 3])'))
ref_case("space_err2", "param_space(a = list(1, 2))", py("result = PS.param_space(a={'x': 1, 'y': 2})"), jl = jl('result = PS.param_space(a = Dict("x" => 1, "y" => 2))'))
ref_case("space_err3", "param_space(a = numeric(0))", py("result = PS.param_space(a=[])"), jl = jl('result = PS.param_space(a = Float64[])'))
ref_case("range_err_n0", "param_range(1, 2, n = 0)", py("result = PS.param_range(1, 2, n=0)"), jl = jl('result = PS.param_range(1, 2; n = 0)'))
ref_case("range_err_n", "param_range(1, 2, n = 2.5)", py("result = PS.param_range(1, 2, n=2.5)"), jl = jl('result = PS.param_range(1, 2; n = 2.5)'))
ref_case("range_err_ord", "param_range(2, 1)", py("result = PS.param_range(2, 1)"), jl = jl('result = PS.param_range(2, 1)'))
ref_case("range_err_log", "param_range(0, 1, log = TRUE)", py("result = PS.param_range(0, 1, log=True)"), jl = jl('result = PS.param_range(0, 1; log = true)'))
ref_case("range_err_step", "param_range(1, 5, step = -1)", py("result = PS.param_range(1, 5, step=-1)"), jl = jl('result = PS.param_range(1, 5; step = -1)'))
ref_case("range_err_chr", "param_range('a', 2)", py("result = PS.param_range('a', 2)"), jl = jl('result = PS.param_range("a", 2)'))
ref_case("range_step_n", "param_range(1, 5, n = 2.7, step = 1)", py("result = PS.param_range(1, 5, n=2.7, step=1)"), jl = jl('result = PS.param_range(1, 5; n = 2.7, step = 1)'))

# ── Raster und Abbildung ────────────────────────────────────────────────────
ref_case("levels", paste0(SP, "; unname(c(lapply(sp, SimLev:::.ps_levels), list(SimLev:::.ps_levels(param_range(1, 3, n = 9, integer = TRUE)),
  SimLev:::.ps_levels(param_range(2, 2, n = 3)), SimLev:::.ps_levels(param_range(2, 5, n = 1)), SimLev:::.ps_levels(param_range(0, 1, step = 0.3)),
  SimLev:::.ps_levels(param_range(0, 0, step = 1)), SimLev:::.ps_levels(param_range(10, 1000, n = 7, log = TRUE, integer = TRUE)),
  SimLev:::.ps_levels(param_range(0.1, 0.7, step = 0.2)))))"),
  py(paste0(SPP, "result = [PS._ps_levels(v) for v in sp.values()] + [PS._ps_levels(PS.param_range(1, 3, n=9, integer=True)),
  PS._ps_levels(PS.param_range(2, 2, n=3)), PS._ps_levels(PS.param_range(2, 5, n=1)), PS._ps_levels(PS.param_range(0, 1, step=0.3)),
  PS._ps_levels(PS.param_range(0, 0, step=1)), PS._ps_levels(PS.param_range(10, 1000, n=7, log=True, integer=True)),
  PS._ps_levels(PS.param_range(0.1, 0.7, step=0.2))]")), jl = jl(paste0(SPJ, 'result = vcat([PS._ps_levels(v) for (k, v) in sp], [PS._ps_levels(PS.param_range(1, 3; n = 9, integer = true)), PS._ps_levels(PS.param_range(2, 2; n = 3)), PS._ps_levels(PS.param_range(2, 5; n = 1)), PS._ps_levels(PS.param_range(0, 1; step = 0.3)), PS._ps_levels(PS.param_range(0, 0; step = 1)), PS._ps_levels(PS.param_range(10, 1000; n = 7, log = true, integer = true)), PS._ps_levels(PS.param_range(0.1, 0.7; step = 0.2))])')))
ref_case("map", paste0(SP, "; u <- c(0, 0.1, 0.33, 0.5, 0.999, 1); lapply(sp, SimLev:::.ps_map, u = u)"),
         py(paste0(SPP, "u = np.array([0, 0.1, 0.33, 0.5, 0.999, 1]); result = {k: PS._ps_map(v, u) for k, v in sp.items()}")), jl = jl(paste0(SPJ, 'u = [0, 0.1, 0.33, 0.5, 0.999, 1]; result = RList((k => PS._ps_map(v, u) for (k, v) in sp)...)')))
SP2 <- "sp <- param_space(a = param_range(1, 5, n = 5, integer = TRUE), b = c('x', 'y'))"
SP2P <- "sp = PS.param_space(a=PS.param_range(1, 5, n=5, integer=True), b=['x', 'y'])\n"
SP2J <- 'sp = PS.param_space(a = PS.param_range(1, 5; n = 5, integer = true), b = ["x", "y"])\n'
ref_case("design_grid", paste0(SP2, "; SimLev:::.ps_design(sp, 'grid', 0, NULL)"), py(paste0(SP2P, "result = PS._ps_design(sp, 'grid', 0, None)")), jl = jl(paste0(SP2J, 'result = PS._ps_design(sp, "grid", 0, nothing)')))
ref_case("design_grid_c", paste0(SP2, "; SimLev:::.ps_design(sp, 'grid', 0, function(p) p$a + (p$b == 'y') <= 4)"),
         py(paste0(SP2P, "result = PS._ps_design(sp, 'grid', 0, lambda p: p['a'] + (p['b'] == 'y') <= 4)")), jl = jl(paste0(SP2J, 'result = PS._ps_design(sp, "grid", 0, p -> p["a"] + (p["b"] == "y") <= 4)')))
ref_case("design_none", paste0(SP2, "; SimLev:::.ps_design(sp, 'grid', 0, function(p) FALSE)"),
         py(paste0(SP2P, "result = PS._ps_design(sp, 'grid', 0, lambda p: False)")), jl = jl(paste0(SP2J, 'result = PS._ps_design(sp, "grid", 0, p -> false)')))
SP3 <- "sp <- param_space(w = param_range(0, 1), n = param_range(10, 1000, log = TRUE, integer = TRUE), k = c(1, 2, 3))"
SP3P <- "sp = PS.param_space(w=PS.param_range(0, 1), n=PS.param_range(10, 1000, log=True, integer=True), k=[1.0, 2.0, 3.0])\n"
SP3J <- 'sp = PS.param_space(w = PS.param_range(0, 1), n = PS.param_range(10, 1000; log = true, integer = true), k = [1.0, 2.0, 3.0])\n'
ref_case("design_lhs", paste0(SP3, "; simlev_seed(3); list(SimLev:::.ps_design(sp, 'lhs', 20, NULL), SimLev:::.sl_runif(1))"),
         py(paste0(SP3P, "simlev.simlev_seed(3); result = [PS._ps_design(sp, 'lhs', 20, None), simlev._lib.runif(1)]")), jl = jl(paste0(SP3J, 'SL.simlev_seed(3); result = [PS._ps_design(sp, "lhs", 20, nothing), SL.SLib.runif(1)]')))
ref_case("design_rand", paste0(SP3, "; simlev_seed(4); list(SimLev:::.ps_design(sp, 'random', 15, function(p) p$w < 0.5), SimLev:::.sl_runif(1))"),
         py(paste0(SP3P, "simlev.simlev_seed(4); result = [PS._ps_design(sp, 'random', 15, lambda p: p['w'] < 0.5), simlev._lib.runif(1)]")), jl = jl(paste0(SP3J, 'SL.simlev_seed(4); result = [PS._ps_design(sp, "random", 15, p -> p["w"] < 0.5), SL.SLib.runif(1)]')))
ref_case("design_disc", "simlev_seed(5); sp <- param_space(a = c(1, 2), b = c('u', 'v', 'w')); list(SimLev:::.ps_design(sp, 'random', 10, NULL), SimLev:::.sl_runif(1))",
         py("simlev.simlev_seed(5); sp = PS.param_space(a=[1.0, 2.0], b=['u', 'v', 'w']); result = [PS._ps_design(sp, 'random', 10, None), simlev._lib.runif(1)]"), jl = jl('SL.simlev_seed(5); sp = PS.param_space(a = [1.0, 2.0], b = ["u", "v", "w"]); result = [PS._ps_design(sp, "random", 10, nothing), SL.SLib.runif(1)]'))
ref_case("design_lhs1", "simlev_seed(6); sp <- param_space(a = param_range(0, 1)); list(SimLev:::.ps_design(sp, 'lhs', 1, NULL), SimLev:::.ps_design(sp, 'lhs', 3, NULL))",
         py("simlev.simlev_seed(6); sp = PS.param_space(a=PS.param_range(0, 1)); result = [PS._ps_design(sp, 'lhs', 1, None), PS._ps_design(sp, 'lhs', 3, None)]"), jl = jl('SL.simlev_seed(6); sp = PS.param_space(a = PS.param_range(0, 1)); result = [PS._ps_design(sp, "lhs", 1, nothing), PS._ps_design(sp, "lhs", 3, nothing)]'))
ref_case("as_spec", "st <- create_strategy(A = asset_config('etf', 'bnh', spread = 0.1)); list(SimLev:::.as_spec(st), SimLev:::.as_spec(list(strategy = st, args = list(a = 1))), SimLev:::.as_spec(list(a = 1)))",
         py("st = create_strategy(A=asset_config(asset_class='etf', trading='bnh', spread=0.1)); result = [PS._as_spec(st), PS._as_spec({'strategy': st, 'args': {'a': 1}}), PS._as_spec({'a': 1})]"), jl = jl('st = create_strategy("A" => asset_config("etf", "bnh", spread = 0.1)); result = [PS._as_spec(st), PS._as_spec(RList("strategy" => st, "args" => RList("a" => 1))), PS._as_spec(RList("a" => 1))]'))

# ── Daten für Suchen ────────────────────────────────────────────────────────
set.seed(1); n <- 600
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
ps_case <- function(id, r, p, j, print = NA)
  ref_case(id, paste0(RS, "z <- function(x) { x$elapsed <- 0; x }\ndropE <- function(s) { s$best$error <- NULL; s$best_plateau$error <- NULL; s }\n", r), py(paste0(PSS, p)), I, print = print,
           jl = jl(paste0(PSJ, j)))
ps_case("ps_grid", "z(param_search(d, b, param_space(n = c(10, 20, 40), band = c(0, 2)), burn_in = 50))",
        "result = z(PS.param_search(d, b, PS.param_space(n=[10.0, 20.0, 40.0], band=[0.0, 2.0]), burn_in=50))",
        'result = z(PS.param_search(d, b, PS.param_space(n = [10.0, 20.0, 40.0], band = [0.0, 2.0]); burn_in = 50))')
ps_case("ps_grid_summary", "x <- z(param_search(d, b, param_space(n = c(10, 20, 40), band = c(0, 2)), burn_in = 50)); dropE(summary(x, top = 3))",
        "x = z(PS.param_search(d, b, PS.param_space(n=[10.0, 20.0, 40.0], band=[0.0, 2.0]), burn_in=50)); result = dropE(PS.summary(x, top=3))",
        'x = z(PS.param_search(d, b, PS.param_space(n = [10.0, 20.0, 40.0], band = [0.0, 2.0]); burn_in = 50)); result = dropE(r_summary(x; top = 3))')
ps_case("ps_plateau", "x <- z(param_search(d, b, param_space(n = c(10, 20, 40), band = c(0, 2)), burn_in = 50)); list(param_plateau(x), param_plateau(x, 'cagr'), param_plateau(x, 'max_drawdown', radius = 2))",
        "x = z(PS.param_search(d, b, PS.param_space(n=[10.0, 20.0, 40.0], band=[0.0, 2.0]), burn_in=50)); result = [PS.param_plateau(x), PS.param_plateau(x, metric='cagr'), PS.param_plateau(x, metric='max_drawdown', radius=2)]",
        'x = z(PS.param_search(d, b, PS.param_space(n = [10.0, 20.0, 40.0], band = [0.0, 2.0]); burn_in = 50)); result = [PS.param_plateau(x), PS.param_plateau(x; metric = "cagr"), PS.param_plateau(x; metric = "max_drawdown", radius = 2)]')
ps_case("ps_noBuilder", "z(param_search(d, space = param_space(rebalance.thresh = c(2, 5, 10)), strategy = st2, sim_args = list(rebalance = rebalance_plan(span = 1, unit = 'month'))))",
        "result = z(PS.param_search(d, space=PS.param_space(**{'rebalance.thresh': [2.0, 5.0, 10.0]}), strategy=st2, sim_args={'rebalance': simlev.rebalance_plan(span=1, unit='month')}))",
        'result = z(PS.param_search(d; space = PS.param_space("rebalance.thresh" => [2.0, 5.0, 10.0]), strategy = st2, sim_args = RList("rebalance" => SL.rebalance_plan(; span = 1, unit = "month"))))')
ps_case("ps_listspace", "z(param_search(d, space = list(rebalance.unit = c('month', 'year')), strategy = st2, sim_args = list(rebalance = rebalance_plan(span = 1)), objective = 'cagr'))",
        "result = z(PS.param_search(d, space={'rebalance.unit': ['month', 'year']}, strategy=st2, sim_args={'rebalance': simlev.rebalance_plan(span=1)}, objective='cagr'))",
        'result = z(PS.param_search(d; space = RList("rebalance.unit" => ["month", "year"]), strategy = st2, sim_args = RList("rebalance" => SL.rebalance_plan(; span = 1)), objective = "cagr"))')
# Pfade in den args des builder, alte flache Namen und unbekannte Pfade
ps_case("ps_path_builder", "z(param_search(d, function(p) list(strategy = st2, args = list(rebalance.thresh = p$band, dca.value = p$v)), param_space(band = c(2, 5), v = c(100, 200)), sim_args = list(rebalance = rebalance_plan(span = 1), dca = dca_plan(50, 1))))",
        "result = z(PS.param_search(d, lambda p: {'strategy': st2, 'args': {'rebalance.thresh': p['band'], 'dca.value': p['v']}}, PS.param_space(band=[2.0, 5.0], v=[100.0, 200.0]), sim_args={'rebalance': simlev.rebalance_plan(span=1), 'dca': simlev.dca_plan(50, 1)}))",
        'result = z(PS.param_search(d, p -> RList("strategy" => st2, "args" => RList("rebalance.thresh" => p["band"], "dca.value" => p["v"])), PS.param_space(band = [2.0, 5.0], v = [100.0, 200.0]); sim_args = RList("rebalance" => SL.rebalance_plan(; span = 1), "dca" => SL.dca_plan(50, 1))))')
ps_case("ps_err_flat_space", "param_search(d, space = param_space(balance_thresh = c(2, 5)), strategy = st2)",
        "result = PS.param_search(d, space=PS.param_space(balance_thresh=[2.0, 5.0]), strategy=st2)",
        'result = PS.param_search(d; space = PS.param_space(balance_thresh = [2.0, 5.0]), strategy = st2)')
ps_case("ps_err_flat_args", "param_search(d, b, param_space(n = 10, band = 0), sim_args = list(tax_mode = 'person'))",
        "result = PS.param_search(d, b, PS.param_space(n=10.0, band=0.0), sim_args={'tax_mode': 'person'})",
        'result = PS.param_search(d, b, PS.param_space(n = 10.0, band = 0.0); sim_args = RList("tax_mode" => "person"))')
ps_case("ps_err_path", "param_search(d, space = param_space(rebalance.tresh = c(2, 5)), strategy = st2)",
        "result = PS.param_search(d, space=PS.param_space(**{'rebalance.tresh': [2.0, 5.0]}), strategy=st2)",
        'result = PS.param_search(d; space = PS.param_space("rebalance.tresh" => [2.0, 5.0]), strategy = st2)')
ps_case("ps_err_point", "z(param_search(d, function(p) if (p$n > 15) stop('kaputt') else b(p), param_space(n = c(10, 20), band = 0), burn_in = 50))",
        "def bb(p):\n    if p['n'] > 15:\n        raise ValueError('kaputt')\n    return b(p)\nresult = z(PS.param_search(d, bb, PS.param_space(n=[10.0, 20.0], band=0.0), burn_in=50))",
        'bb(p) = p["n"] > 15 ? error("kaputt") : b(p)
result = z(PS.param_search(d, bb, PS.param_space(n = [10.0, 20.0], band = 0.0); burn_in = 50))')
ps_case("ps_err_all", "param_search(d, function(p) stop('alles kaputt'), param_space(n = c(10, 20)))",
        "def bb(p):\n    raise ValueError('alles kaputt')\nresult = PS.param_search(d, bb, PS.param_space(n=[10.0, 20.0]))",
        'result = PS.param_search(d, p -> error("alles kaputt"), PS.param_space(n = [10.0, 20.0]))')
ps_case("ps_err_obj", "param_search(d, b, param_space(n = 10, band = 0), objective = 'foo')",
        "result = PS.param_search(d, b, PS.param_space(n=10.0, band=0.0), objective='foo')",
        'result = PS.param_search(d, b, PS.param_space(n = 10.0, band = 0.0); objective = "foo")')
ps_case("ps_err_none", "param_search(d, space = param_space(n = 10))", "result = PS.param_search(d, space=PS.param_space(n=10.0))",
        'result = PS.param_search(d; space = PS.param_space(n = 10.0))')
ps_case("ps_random", "simlev_seed(9); x <- z(param_search(d, b, param_space(n = param_range(5, 60, integer = TRUE), band = param_range(0, 3)), method = 'random', n = 5, seed = 2, burn_in = 60)); list(x, SimLev:::.sl_runif(1), param_plateau(x), param_plateau(x, k = 2))",
        "simlev.simlev_seed(9); x = z(PS.param_search(d, b, PS.param_space(n=PS.param_range(5, 60, integer=True), band=PS.param_range(0, 3)), method='random', n=5, seed=2, burn_in=60)); result = [x, simlev._lib.runif(1), PS.param_plateau(x), PS.param_plateau(x, k=2)]",
        'SL.simlev_seed(9); x = z(PS.param_search(d, b, PS.param_space(n = PS.param_range(5, 60; integer = true), band = PS.param_range(0, 3)); method = "random", n = 5, seed = 2, burn_in = 60)); result = [x, SL.SLib.runif(1), PS.param_plateau(x), PS.param_plateau(x; k = 2)]')
ps_case("ps_lhs", "simlev_seed(9); x <- z(param_search(d, b, param_space(n = param_range(5, 60, integer = TRUE, log = TRUE), band = c(0, 1)), method = 'lhs', n = 4, burn_in = 60)); list(x, SimLev:::.sl_runif(1), dropE(summary(x)))",
        "simlev.simlev_seed(9); x = z(PS.param_search(d, b, PS.param_space(n=PS.param_range(5, 60, integer=True, log=True), band=[0.0, 1.0]), method='lhs', n=4, burn_in=60)); result = [x, simlev._lib.runif(1), dropE(PS.summary(x))]",
        'SL.simlev_seed(9); x = z(PS.param_search(d, b, PS.param_space(n = PS.param_range(5, 60; integer = true, log = true), band = [0.0, 1.0]); method = "lhs", n = 4, burn_in = 60)); result = [x, SL.SLib.runif(1), dropE(r_summary(x))]')
ps_case("ps_noret", "z(param_search(d, b, param_space(n = c(10, 20), band = 0), keep_returns = 'none', burn_in = 30))",
        "result = z(PS.param_search(d, b, PS.param_space(n=[10.0, 20.0], band=0.0), keep_returns='none', burn_in=30))",
        'result = z(PS.param_search(d, b, PS.param_space(n = [10.0, 20.0], band = 0.0); keep_returns = "none", burn_in = 30))')
# seit 1.1.0: keep_returns = "day"/"none"; TRUE/FALSE ohne Alias ein Fehler
ps_case("ps_ret_day", "z(param_search(d, b, param_space(n = c(10, 20), band = 0), keep_returns = 'day', burn_in = 30))",
        "result = z(PS.param_search(d, b, PS.param_space(n=[10.0, 20.0], band=0.0), keep_returns='day', burn_in=30))",
        'result = z(PS.param_search(d, b, PS.param_space(n = [10.0, 20.0], band = 0.0); keep_returns = "day", burn_in = 30))')
ps_case("ps_err_keepret_true", "param_search(d, b, param_space(n = c(10, 20), band = 0), keep_returns = TRUE)",
        "result = PS.param_search(d, b, PS.param_space(n=[10.0, 20.0], band=0.0), keep_returns=True)",
        'result = PS.param_search(d, b, PS.param_space(n = [10.0, 20.0], band = 0.0); keep_returns = true)')
ps_case("ps_err_keepret_false", "param_search(d, b, param_space(n = c(10, 20), band = 0), keep_returns = FALSE)",
        "result = PS.param_search(d, b, PS.param_space(n=[10.0, 20.0], band=0.0), keep_returns=False)",
        'result = PS.param_search(d, b, PS.param_space(n = [10.0, 20.0], band = 0.0); keep_returns = false)')
ps_case("ps_err_keepret_chr", "param_search(d, b, param_space(n = c(10, 20), band = 0), keep_returns = 'week')",
        "result = PS.param_search(d, b, PS.param_space(n=[10.0, 20.0], band=0.0), keep_returns='week')",
        'result = PS.param_search(d, b, PS.param_space(n = [10.0, 20.0], band = 0.0); keep_returns = "week")')
ps_case("ps_metrics", "z(param_search(d, b, param_space(n = c(10, 20, 30), band = 0), metrics = function(r) if (r$cagr > 0.5) stop('x') else c(sharpe = r$statistics$sharpe, cagr = r$cagr), burn_in = 30))",
        "def mt(r):\n    if r.cagr > 0.5:\n        raise ValueError('x')\n    return pd.Series({'sharpe': r.statistics['sharpe'], 'cagr': r.cagr})\nresult = z(PS.param_search(d, b, PS.param_space(n=[10.0, 20.0, 30.0], band=0.0), metrics=mt, burn_in=30))",
        'mt(r) = r.cagr > 0.5 ? error("x") : named("sharpe" => r.statistics.sharpe, "cagr" => r.cagr)
result = z(PS.param_search(d, b, PS.param_space(n = [10.0, 20.0, 30.0], band = 0.0); metrics = mt, burn_in = 30))')
ps_case("ps_metric1", "z(param_search(d, b, param_space(n = c(10, 20), band = 0), metrics = function(r) c(cagr = r$cagr), objective = 'cagr', burn_in = 30))",
        "result = z(PS.param_search(d, b, PS.param_space(n=[10.0, 20.0], band=0.0), metrics=lambda r: pd.Series({'cagr': r.cagr}), objective='cagr', burn_in=30))",
        'result = z(PS.param_search(d, b, PS.param_space(n = [10.0, 20.0], band = 0.0); metrics = r -> named("cagr" => r.cagr), objective = "cagr", burn_in = 30))')
ps_case("ps_minimize", "x <- z(param_search(d, b, param_space(n = c(10, 20, 40), band = c(0, 2)), objective = 'max_drawdown', maximize = FALSE, burn_in = 50)); list(x, param_plateau(x))",
        "x = z(PS.param_search(d, b, PS.param_space(n=[10.0, 20.0, 40.0], band=[0.0, 2.0]), objective='max_drawdown', maximize=False, burn_in=50)); result = [x, PS.param_plateau(x)]",
        'x = z(PS.param_search(d, b, PS.param_space(n = [10.0, 20.0, 40.0], band = [0.0, 2.0]); objective = "max_drawdown", maximize = false, burn_in = 50)); result = [x, PS.param_plateau(x)]')
ps_case("ps_spec", "bs <- function(p) list(strategy = create_strategy(L = asset_config('etf', 'bnh', spread = 0.1)), data = function(df) { df$L2 <- series_leverage(df, 'A', p$lev); df }, map = c(L = 'L2'), args = list(start_value = p$sv))
  z(param_search(d, bs, param_space(lev = c(1, 2), sv = c(1000, 5000)), sim_args = list(start_value = 1)))",
        "import simlev.sensitivity as SE\ndef bs(p):\n    def dat(df):\n        df = df.copy(); df['L2'] = SE.series_leverage(df, 'A', leverage=p['lev']); return df\n    return {'strategy': create_strategy(L=asset_config(asset_class='etf', trading='bnh', spread=0.1)), 'data': dat, 'map': {'L': 'L2'}, 'args': {'start_value': p['sv']}}\nresult = z(PS.param_search(d, bs, PS.param_space(lev=[1.0, 2.0], sv=[1000.0, 5000.0]), sim_args={'start_value': 1}))",
        'bs(p) = RList("strategy" => create_strategy("L" => asset_config("etf", "bnh", spread = 0.1)), "data" => df -> (df["L2"] = SL.Sensitivity.series_leverage(df, "A"; leverage = p["lev"]); df), "map" => named("L" => "L2"), "args" => RList("start_value" => p["sv"]))
result = z(PS.param_search(d, bs, PS.param_space(lev = [1.0, 2.0], sv = [1000.0, 5000.0]); sim_args = RList("start_value" => 1)))')
ps_case("ps_plainstrat", "z(param_search(d, function(p) create_strategy(A = asset_config('etf', 'bnh', p$w, spread = 0.1), B = asset_config('etf', 'bnh', 1 - p$w, spread = 0.1)), param_space(w = c(0.3, 0.7))))",
        "result = z(PS.param_search(d, lambda p: create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=p['w'], spread=0.1), B=asset_config(asset_class='etf', trading='bnh', share=1 - p['w'], spread=0.1)), PS.param_space(w=[0.3, 0.7])))",
        'result = z(PS.param_search(d, p -> create_strategy("A" => asset_config("etf", "bnh", p["w"], spread = 0.1), "B" => asset_config("etf", "bnh", 1 - p["w"], spread = 0.1)), PS.param_space(w = [0.3, 0.7])))')
ps_case("ps_sigdf", "sgd <- function(p) list(strategy = st, signal = function(df) { s <- signal_sma(df$A, p$n); df$buy <- s$buy; df$sell <- s$sell; df })
  z(param_search(d, sgd, param_space(n = c(10, 20)), burn_in = 25))",
        "def sgd(p):\n    def sg(df):\n        s = SG.signal_sma(df['A'], n=p['n']); df = df.copy(); df['buy'] = s['buy']; df['sell'] = s['sell']; return df\n    return {'strategy': st, 'signal': sg}\nresult = z(PS.param_search(d, sgd, PS.param_space(n=[10.0, 20.0]), burn_in=25))",
        'sgd(p) = RList("strategy" => st, "signal" => df -> (s = SL.Signals.signal_sma(df["A"]; n = p["n"]); df["buy"] = s["buy"]; df["sell"] = s["sell"]; df))
result = z(PS.param_search(d, sgd, PS.param_space(n = [10.0, 20.0]); burn_in = 25))')
ps_case("ps_signa", "sgn <- function(p) list(strategy = st, signal = function(df) list(buy = c(NA, df$A[-1] > df$A[-nrow(df)]), sell = c(NA, df$A[-1] < df$A[-nrow(df)] * (1 - p$k))))
  z(param_search(d, sgn, param_space(k = c(0, 0.01))))",
        "def sgn(p):\n    def sg(df):\n        a = df['A'].to_numpy()\n        return {'buy': np.array([None] + list(a[1:] > a[:-1]), dtype=object), 'sell': np.array([None] + list(a[1:] < a[:-1] * (1 - p['k'])), dtype=object)}\n    return {'strategy': st, 'signal': sg}\nresult = z(PS.param_search(d, sgn, PS.param_space(k=[0.0, 0.01])))",
        'sgn(p) = RList("strategy" => st, "signal" => df -> (a = df["A"]; RList("buy" => vcat(missing, a[2:end] .> a[1:end-1]), "sell" => vcat(missing, a[2:end] .< a[1:end-1] .* (1 - p["k"])))))
result = z(PS.param_search(d, sgn, PS.param_space(k = [0.0, 0.01])))')
ps_case("ps_constraint", "z(param_search(d, space = param_space(rebalance.thresh = c(2, 5, 10), rebalance.unit = c('month', 'year')), strategy = st2, constraint = function(p) p$rebalance.thresh < 10 || p$rebalance.unit == 'year', sim_args = list(rebalance = rebalance_plan(span = 1))))",
        "result = z(PS.param_search(d, space=PS.param_space(**{'rebalance.thresh': [2.0, 5.0, 10.0], 'rebalance.unit': ['month', 'year']}), strategy=st2, constraint=lambda p: p['rebalance.thresh'] < 10 or p['rebalance.unit'] == 'year', sim_args={'rebalance': simlev.rebalance_plan(span=1)}))",
        'result = z(PS.param_search(d; space = PS.param_space("rebalance.thresh" => [2.0, 5.0, 10.0], "rebalance.unit" => ["month", "year"]), strategy = st2, constraint = p -> p["rebalance.thresh"] < 10 || p["rebalance.unit"] == "year", sim_args = RList("rebalance" => SL.rebalance_plan(; span = 1))))')
ps_case("ps_plateau_c", "x <- z(param_search(d, space = param_space(rebalance.thresh = c(2, 5, 10), rebalance.unit = c('month', 'year')), strategy = st2, constraint = function(p) p$rebalance.thresh < 10 || p$rebalance.unit == 'year', sim_args = list(rebalance = rebalance_plan(span = 1)))); list(param_plateau(x), dropE(summary(x)))",
        "x = z(PS.param_search(d, space=PS.param_space(**{'rebalance.thresh': [2.0, 5.0, 10.0], 'rebalance.unit': ['month', 'year']}), strategy=st2, constraint=lambda p: p['rebalance.thresh'] < 10 or p['rebalance.unit'] == 'year', sim_args={'rebalance': simlev.rebalance_plan(span=1)})); result = [PS.param_plateau(x), dropE(PS.summary(x))]",
        'x = z(PS.param_search(d; space = PS.param_space("rebalance.thresh" => [2.0, 5.0, 10.0], "rebalance.unit" => ["month", "year"]), strategy = st2, constraint = p -> p["rebalance.thresh"] < 10 || p["rebalance.unit"] == "year", sim_args = RList("rebalance" => SL.rebalance_plan(; span = 1)))); result = [PS.param_plateau(x), dropE(r_summary(x))]')

# ── param_plateau auf nachgebautem Objekt (test-blue-planning) ────────────────────
FK <- "x <- structure(list(results = data.frame(id = 1:4, n = c(10, 20, 30, 40), sharpe = c(1, 2, 3, 4), max_drawdown = c(0.1, 0.5, 0.2, 0.3), cagr = c(0.05, 0.02, 0.04, 0.01)),
  params = 'n', method = 'grid', space = param_space(n = c(10, 20, 30, 40)), objective = 'sharpe', maximize = TRUE), class = 'SimLevParamSearch')\n"
FKP <- "x = PS.SimLevParamSearch(results=pd.DataFrame({'id': [1, 2, 3, 4], 'n': [10.0, 20.0, 30.0, 40.0], 'sharpe': [1.0, 2.0, 3.0, 4.0], 'max_drawdown': [0.1, 0.5, 0.2, 0.3], 'cagr': [0.05, 0.02, 0.04, 0.01]}),
  params=['n'], method='grid', space=PS.param_space(n=[10.0, 20.0, 30.0, 40.0]), objective='sharpe', maximize=True)\n"
FKJ <- 'x = RList("results" => RFrame("id" => [1, 2, 3, 4], "n" => [10.0, 20.0, 30.0, 40.0], "sharpe" => [1.0, 2.0, 3.0, 4.0], "max_drawdown" => [0.1, 0.5, 0.2, 0.3], "cagr" => [0.05, 0.02, 0.04, 0.01]), "params" => "n", "method" => "grid", "space" => PS.param_space(n = [10.0, 20.0, 30.0, 40.0]), "objective" => "sharpe", "maximize" => true; class = "SimLevParamSearch")\n'
ref_case("plateau_fake", paste0(FK, "list(param_plateau(x, metric = 'max_drawdown'), param_plateau(x, metric = 'cagr'), param_plateau(x), {x$maximize <- FALSE; x$objective <- 'max_drawdown'; param_plateau(x)})"),
         py(paste0(FKP, "r1 = [PS.param_plateau(x, metric='max_drawdown'), PS.param_plateau(x, metric='cagr'), PS.param_plateau(x)]\nx['maximize'] = False; x['objective'] = 'max_drawdown'\nresult = r1 + [PS.param_plateau(x)]")), jl = jl(paste0(FKJ, 'r1 = [PS.param_plateau(x; metric = "max_drawdown"), PS.param_plateau(x; metric = "cagr"), PS.param_plateau(x)]\nx["maximize"] = false; x["objective"] = "max_drawdown"\nresult = vcat(r1, [PS.param_plateau(x)])')))
ref_case("plateau_rnd1", paste0(FK, "x$method <- 'random'; x$results <- x$results[2, ]; x$results$m <- 'q'; x$params <- c('n', 'm'); SimLev:::.ps_neighbours(x)"),
         py(paste0(FKP, "x['method'] = 'random'; x['results'] = x['results'].iloc[[1]].reset_index(drop=True); x['results']['m'] = 'q'; x['params'] = ['n', 'm']; result = PS._ps_neighbours(x)")), jl = jl(paste0(FKJ, 'x["method"] = "random"; x["results"] = rows(x["results"], [2]); x["results"]["m"] = "q"; x["params"] = ["n", "m"]; result = PS._ps_neighbours(x)')))
ref_case("plateau_rnd", paste0(FK, "x$method <- 'lhs'; x$results$s <- c('b', 'a', 'b', 'c'); x$results$f <- c(TRUE, FALSE, TRUE, TRUE); x$params <- c('n', 's', 'f'); list(SimLev:::.ps_neighbours(x, k = 3), param_plateau(x, k = 2))"),
         py(paste0(FKP, "x['method'] = 'lhs'; x['results']['s'] = ['b', 'a', 'b', 'c']; x['results']['f'] = [True, False, True, True]; x['params'] = ['n', 's', 'f']; result = [PS._ps_neighbours(x, k=3), PS.param_plateau(x, k=2)]")), jl = jl(paste0(FKJ, 'x["method"] = "lhs"; x["results"]["s"] = ["b", "a", "b", "c"]; x["results"]["f"] = [true, false, true, true]; x["params"] = ["n", "s", "f"]; result = [PS._ps_neighbours(x; k = 3), PS.param_plateau(x; k = 2)]')))
# Zeichen-Parameter: factor()-Stufen nach R's Kollation (ICU "root": a A b B)
FKC <- function(sv, sh) sprintf("x <- structure(list(results = data.frame(id = seq_along(%s), n = 10 * seq_along(%s), s = %s, sharpe = %s, cagr = %s / 100),
  params = 's', method = 'random', space = param_space(s = unique(%s)), objective = 'sharpe', maximize = TRUE, elapsed = 0), class = 'SimLevParamSearch')\n", sv, sv, sv, sh, sh, sv)
FKCP <- function(sv, sh) sprintf("sv = %s; sh = %s\nx = PS.SimLevParamSearch(results=pd.DataFrame({'id': list(range(1, len(sv) + 1)), 'n': [10.0 * (i + 1) for i in range(len(sv))], 's': sv, 'sharpe': sh, 'cagr': [v / 100 for v in sh]}),
  params=['s'], method='random', space=PS.param_space(s=list(dict.fromkeys(sv))), objective='sharpe', maximize=True, elapsed=0.0)\n", sv, sh)
FKCJ <- function(sv, sh) sprintf('sv = %s; sh = %s\nx = RList("results" => RFrame("id" => collect(1:length(sv)), "n" => [10.0 * i for i in 1:length(sv)], "s" => sv, "sharpe" => sh, "cagr" => sh ./ 100), "params" => "s", "method" => "random", "space" => PS.param_space(s = unique(sv)), "objective" => "sharpe", "maximize" => true, "elapsed" => 0.0; class = "SimLevParamSearch")\n', sv, sh)
s4r <- "c('b', 'A', 'a', 'B')"; s4p <- "['b', 'A', 'a', 'B']"; h4 <- "c(1, 4, 2, 3)"; h4p <- "[1.0, 4.0, 2.0, 3.0]"
ref_case("plateau_chr", paste0(FKC(s4r, h4), "list(SimLev:::.ps_neighbours(x, k = 2), param_plateau(x, k = 2), param_plateau(x, 'cagr', k = 3))"),
         py(paste0(FKCP(s4p, h4p), "result = [PS._ps_neighbours(x, k=2), PS.param_plateau(x, k=2), PS.param_plateau(x, metric='cagr', k=3)]")),
         jl = jl(paste0(FKCJ('["b", "A", "a", "B"]', "[1.0, 4.0, 2.0, 3.0]"), 'result = [PS._ps_neighbours(x; k = 2), PS.param_plateau(x; k = 2), PS.param_plateau(x; metric = "cagr", k = 3)]')))
s6r <- "c('b', 'A', 'a', 'B', 'c', 'C')"; s6p <- "['b', 'A', 'a', 'B', 'c', 'C']"; h6 <- "c(1, 6, 2, 5, 3, 4)"; h6p <- "[1.0, 6.0, 2.0, 5.0, 3.0, 4.0]"
ref_case("summary_chr", paste0(FKC(s6r, h6), "list(SimLev:::.ps_neighbours(x), summary(x, top = 3))"),
         py(paste0(FKCP(s6p, h6p), "result = [PS._ps_neighbours(x), PS.summary(x, top=3)]")),
         jl = jl(paste0(FKCJ('["b", "A", "a", "B", "c", "C"]', "[1.0, 6.0, 2.0, 5.0, 3.0, 4.0]"), 'result = [PS._ps_neighbours(x), r_summary(x; top = 3)]')))
ref_case("summary_chr_print", paste0(FKC(s6r, h6), "summary(x, top = 4)"),
         py(paste0(FKCP(s6p, h6p), "result = PS.summary(x, top=4)")),
         jl = jl(paste0(FKCJ('["b", "A", "a", "B", "c", "C"]', "[1.0, 6.0, 2.0, 5.0, 3.0, 4.0]"), 'result = r_summary(x; top = 4)')))
ref_case("plateau_notps", "param_plateau(list(a = 1))", py("result = PS.param_plateau({'a': 1})"), jl = jl('result = PS.param_plateau(RList("a" => 1))'))
ref_case("summary_print", "sm <- structure(list(top = data.frame(id = 1L, n = 50, cagr = 0.05, sharpe = 0.4, plateau = 0.4),
  best = data.frame(id = 1L, n = 50, sharpe = 0.4), best_plateau = data.frame(id = 1L, n = 50, sharpe = 0.4, plateau = 0.4),
  n = 1L, n_failed = 0L, objective = 'sharpe', method = 'grid', params = 'n', elapsed = 0), class = 'summary.SimLevParamSearch'); sm",
  py("result = PS.SummarySimLevParamSearch(top=pd.DataFrame({'id': [1], 'n': [50.0], 'cagr': [0.05], 'sharpe': [0.4], 'plateau': [0.4]}),
  best=pd.DataFrame({'id': [1], 'n': [50.0], 'sharpe': [0.4]}), best_plateau=pd.DataFrame({'id': [1], 'n': [50.0], 'sharpe': [0.4], 'plateau': [0.4]}),
  n=1, n_failed=0, objective='sharpe', method='grid', params=['n'], elapsed=0.0)"), jl = jl('result = RList("top" => RFrame("id" => [1], "n" => [50.0], "cagr" => [0.05], "sharpe" => [0.4], "plateau" => [0.4]), "best" => RFrame("id" => [1], "n" => [50.0], "sharpe" => [0.4]), "best_plateau" => RFrame("id" => [1], "n" => [50.0], "sharpe" => [0.4], "plateau" => [0.4]), "n" => 1, "n_failed" => 0, "objective" => "sharpe", "method" => "grid", "params" => "n", "elapsed" => 0.0; class = "summary.SimLevParamSearch")'))
# ── cores = 2 ────────────────────────────────────────────────────
ps_case("ps_cores2", "z(param_search(d, b, param_space(n = c(10, 20, 40), band = c(0, 2)), burn_in = 50, cores = 2))",
        "result = z(PS.param_search(d, b, PS.param_space(n=[10.0, 20.0, 40.0], band=[0.0, 2.0]), burn_in=50, cores=2))",
        'result = z(PS.param_search(d, b, PS.param_space(n = [10.0, 20.0, 40.0], band = [0.0, 2.0]); burn_in = 50, cores = 2))')
ps_case("ps_cores2_random", "simlev_seed(3); x <- z(param_search(d, b, param_space(n = param_range(5, 60, integer = TRUE), band = param_range(0, 2)), method = 'random', n = 5, seed = 11, burn_in = 60, cores = 2)); list(x, SimLev:::.sl_runif(1))",
        "simlev.simlev_seed(3); x = z(PS.param_search(d, b, PS.param_space(n=PS.param_range(5, 60, integer=True), band=PS.param_range(0, 2)), method='random', n=5, seed=11, burn_in=60, cores=2)); result = [x, simlev._lib.runif(1)]",
        'SL.simlev_seed(3); x = z(PS.param_search(d, b, PS.param_space(n = PS.param_range(5, 60; integer = true), band = PS.param_range(0, 2)); method = "random", n = 5, seed = 11, burn_in = 60, cores = 2)); result = [x, SL.SLib.runif(1)]')
ps_case("ps_cores2_err", "z(param_search(d, function(p) if (p$n > 15) stop('kaputt') else b(p), param_space(n = c(10, 20, 30), band = 0), burn_in = 50, cores = 2))",
        "def bb(p):\n    if p['n'] > 15:\n        raise ValueError('kaputt')\n    return b(p)\nresult = z(PS.param_search(d, bb, PS.param_space(n=[10.0, 20.0, 30.0], band=0.0), burn_in=50, cores=2))",
        'bb(p) = p["n"] > 15 ? error("kaputt") : b(p)
result = z(PS.param_search(d, bb, PS.param_space(n = [10.0, 20.0, 30.0], band = 0.0); burn_in = 50, cores = 2))')

ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul overfitting
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Referenzfälle für overfitting.R (overfit_pbo, sharpe_probabilistic, sharpe_deflated,
# overfit_walk_forward, param_bootstrap, sharpe_haircut, .of_*-Helfer).
ref_init("overfitting")
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

# ── .of_returns / .of_metric / .of_col_metric ───────────────────────────────
ref_case("ofret_day", "SimLev:::.of_returns(Rs, 'day')", py("result = OF._of_returns(Rs, 'day')"), I, jl = jl('result = OF._of_returns(Rs, "day")'))
ref_case("ofret_week", "SimLev:::.of_returns(Rs, 'week', dts, risk_free = 2)", py("result = OF._of_returns(Rs, 'week', dts, risk_free=2)"), I, jl = jl('result = OF._of_returns(Rs, "week", dts, 2)'))
ref_case("ofret_month", "SimLev:::.of_returns(Rs, 'month', dts)", py("result = OF._of_returns(Rs, 'month', dts)"), I, jl = jl('result = OF._of_returns(Rs, "month", dts)'))
ref_case("ofret_dayd", "SimLev:::.of_returns(Rs, 'day', dts, risk_free = 3)", py("result = OF._of_returns(Rs, 'day', dts, risk_free=3)"), I, jl = jl('result = OF._of_returns(Rs, "day", dts, 3)'))
ref_case("ofret_na", "SimLev:::.of_returns(Rn, 'week', dts)", py("result = OF._of_returns(Rn, 'week', dts)"), I, jl = jl('result = OF._of_returns(Rn, "week", dts)'))
ref_case("ofret_nadf", "SimLev:::.of_returns(Rdf, 'month')", py("result = OF._of_returns(Rdf, 'month')"), I, jl = jl('result = OF._of_returns(Rdf, "month")'))
ref_case("ofret_chr", "SimLev:::.of_returns(data.frame(a = c('x', 'y')), 'day')",
         py("result = OF._of_returns(pd.DataFrame({'a': ['x', 'y']}), 'day')"), jl = jl('result = OF._of_returns(RFrame("a" => ["x", "y"]), "day")'))
ref_case("ofret_vec", "SimLev:::.of_returns(Rs[, 1], 'month')", py("result = OF._of_returns(Rs[:, 0], 'month')"), I, jl = jl('result = OF._of_returns(Rs[:, 1], "month")'))
ref_case("ofmetric_err", "SimLev:::.of_metric(10, 1, 1, 1, 1, 'foo')", py("result = OF._of_metric(10, 1.0, 1.0, 1.0, 1.0, 'foo')"), jl = jl('result = OF._of_metric(10, 1.0, 1.0, 1.0, 1.0, "foo")'))
ref_case("ofcolmetric", "lapply(c('sharpe', 'sortino', 'geometric', 'mean'), function(m) SimLev:::.of_col_metric(Mb, m))",
         py("result = [OF._of_col_metric(Mb, m) for m in ('sharpe', 'sortino', 'geometric', 'mean')]"), I, jl = jl('result = [OF._of_col_metric(Mb, m) for m in ("sharpe", "sortino", "geometric", "mean")]'))

# ── overfit_pbo ─────────────────────────────────────────────────────────────────────
ref_case("pbo_sharpe", "overfit_pbo(R, S = 6, frequency = 'day')", py("result = OF.overfit_pbo(R, S=6, frequency='day')"), I, jl = jl('result = OF.overfit_pbo(R; S = 6, frequency = "day")'))
for (m in c("sortino", "geometric", "mean"))
  ref_case(paste0("pbo_", m), sprintf("overfit_pbo(R, S = 4, metric = '%s', frequency = 'day')", m),
           py(sprintf("result = OF.overfit_pbo(R, S=4, metric='%s', frequency='day')", m)), I,
           jl = jl(sprintf('result = OF.overfit_pbo(R; S = 4, metric = "%s", frequency = "day")', m)))
ref_case("pbo_week", "overfit_pbo(Rs, S = 2, dates = dts, risk_free = 2)", py("result = OF.overfit_pbo(Rs, S=2, dates=dts, risk_free=2)"), I, jl = jl('result = OF.overfit_pbo(Rs; S = 2, dates = dts, risk_free = 2)'))
ref_case("pbo_skill", "R2 <- R; R2[, 1] <- R2[, 1] + 0.003; overfit_pbo(R2, S = 6, frequency = 'day')",
         py("R2 = R.copy(); R2[:, 0] += 0.003; result = OF.overfit_pbo(R2, S=6, frequency='day')"), I, jl = jl('R2 = copy(R); R2[:, 1] .+= 0.003; result = OF.overfit_pbo(R2; S = 6, frequency = "day")'))
ref_case("pbo_odd", "overfit_pbo(R3, S = 8, frequency = 'day')", py("result = OF.overfit_pbo(R3, S=8, frequency='day')"), I, jl = jl('result = OF.overfit_pbo(R3; S = 8, frequency = "day")'))
ref_case("pbo_ties", "overfit_pbo(cbind(R3, R3[, 1]), S = 8, frequency = 'day')",
         py("result = OF.overfit_pbo(np.column_stack([R3, R3[:, 0]]), S=8, frequency='day')"), I, jl = jl('result = OF.overfit_pbo(hcat(R3, R3[:, 1]); S = 8, frequency = "day")'))
ref_case("pbo_S16", "overfit_pbo(R3[1:200, ], frequency = 'day')", py("result = OF.overfit_pbo(R3[:200], frequency='day')"), I, jl = jl('result = OF.overfit_pbo(R3[1:200, :]; frequency = "day")'))
ref_case("pbo_Sodd", "overfit_pbo(R, S = 5)", py("result = OF.overfit_pbo(R, S=5)"), I, jl = jl('result = OF.overfit_pbo(R; S = 5)'))
ref_case("pbo_S1", "overfit_pbo(R, S = 1)", py("result = OF.overfit_pbo(R, S=1)"), I, jl = jl('result = OF.overfit_pbo(R; S = 1)'))
ref_case("pbo_short", "overfit_pbo(R[1:30, ], S = 8, frequency = 'day')", py("result = OF.overfit_pbo(R[:30], S=8, frequency='day')"), I, jl = jl('result = OF.overfit_pbo(R[1:30, :]; S = 8, frequency = "day")'))
ref_case("pbo_onecol", "overfit_pbo(R[, 1, drop = FALSE], S = 4, frequency = 'day')", py("result = OF.overfit_pbo(R[:, :1], S=4, frequency='day')"), I, jl = jl('result = OF.overfit_pbo(R[:, 1:1]; S = 4, frequency = "day")'))
ref_case("pbo_flat", "overfit_pbo(cbind(Rc, cash), S = 4, frequency = 'day')", py("result = OF.overfit_pbo(np.column_stack([Rc, cash]), S=4, frequency='day')"), I, jl = jl('result = OF.overfit_pbo(hcat(Rc, cash); S = 4, frequency = "day")'))
ref_case("pbo_flat_mean", "overfit_pbo(cbind(Rc, cash), S = 4, metric = 'mean', frequency = 'day')",
         py("result = OF.overfit_pbo(np.column_stack([Rc, cash]), S=4, metric='mean', frequency='day')"), I, jl = jl('result = OF.overfit_pbo(hcat(Rc, cash); S = 4, metric = "mean", frequency = "day")'))
ref_case("pbo_allflat", "overfit_pbo(cbind(cash, cash), S = 4, frequency = 'day')",
         py("result = OF.overfit_pbo(np.column_stack([cash, cash]), S=4, frequency='day')"), I, jl = jl('result = OF.overfit_pbo(hcat(cash, cash); S = 4, frequency = "day")'))
ref_case("pbo_badmetric", "overfit_pbo(R, metric = 'foo')", py("result = OF.overfit_pbo(R, metric='foo')"), I, jl = jl('result = OF.overfit_pbo(R; metric = "foo")'))

# ── sharpe_probabilistic ────────────────────────────────────────────────────
ref_case("psr_0", "sharpe_probabilistic(r520, benchmark = 0, ppy = 52)", py("result = OF.sharpe_probabilistic(r520, benchmark=0, ppy=52)"), I, jl = jl('result = OF.sharpe_probabilistic(r520; benchmark = 0, ppy = 52)'))
ref_case("psr_1", "sharpe_probabilistic(r520, benchmark = 1, ppy = 52)", py("result = OF.sharpe_probabilistic(r520, benchmark=1, ppy=52)"), I, jl = jl('result = OF.sharpe_probabilistic(r520; benchmark = 1, ppy = 52)'))
ref_case("psr_def", "sharpe_probabilistic(R[, 2])", py("result = OF.sharpe_probabilistic(R[:, 1])"), I, jl = jl('result = OF.sharpe_probabilistic(R[:, 2])'))
ref_case("psr_neg", "sharpe_probabilistic(-abs(R[, 3]), 0.5, 252)", py("result = OF.sharpe_probabilistic(-np.abs(R[:, 2]), benchmark=0.5, ppy=252)"), I, jl = jl('result = OF.sharpe_probabilistic(-abs.(R[:, 3]); benchmark = 0.5, ppy = 252)'))

# ── sharpe_deflated ─────────────────────────────────────────────────────────
ref_case("dsr_def", "sharpe_deflated(R, frequency = 'day')", py("result = OF.sharpe_deflated(R, frequency='day')"), I, jl = jl('result = OF.sharpe_deflated(R; frequency = "day")'))
ref_case("dsr_id", "sharpe_deflated(R, id = 3, frequency = 'day')", py("result = OF.sharpe_deflated(R, id=3, frequency='day')"), I, jl = jl('result = OF.sharpe_deflated(R; id = 3, frequency = "day")'))
ref_case("dsr_ntr", "sharpe_deflated(R, frequency = 'day', n_trials = 100)", py("result = OF.sharpe_deflated(R, frequency='day', n_trials=100)"), I, jl = jl('result = OF.sharpe_deflated(R; frequency = "day", n_trials = 100)'))
ref_case("dsr_noeff", "sharpe_deflated(R, frequency = 'day', effective = FALSE)", py("result = OF.sharpe_deflated(R, frequency='day', effective=False)"), I, jl = jl('result = OF.sharpe_deflated(R; frequency = "day", effective = false)'))
ref_case("dsr_week", "sharpe_deflated(Rs, dates = dts, risk_free = 1)", py("result = OF.sharpe_deflated(Rs, dates=dts, risk_free=1)"), I, jl = jl('result = OF.sharpe_deflated(Rs; dates = dts, risk_free = 1)'))
ref_case("dsr_badid", "sharpe_deflated(R, id = 9, frequency = 'day')", py("result = OF.sharpe_deflated(R, id=9, frequency='day')"), I, jl = jl('result = OF.sharpe_deflated(R; id = 9, frequency = "day")'))
ref_case("dsr_flat", "sharpe_deflated(cbind(Rc, cash), frequency = 'day', id = 1)",
         py("result = OF.sharpe_deflated(np.column_stack([Rc, cash]), frequency='day', id=1)"), I, jl = jl('result = OF.sharpe_deflated(hcat(Rc, cash); frequency = "day", id = 1)'))
ref_case("dsr_one", "sharpe_deflated(R[, 1, drop = FALSE], frequency = 'day')", py("result = OF.sharpe_deflated(R[:, :1], frequency='day')"), I, jl = jl('result = OF.sharpe_deflated(R[:, 1:1]; frequency = "day")'))
ref_case("dsr_neg", "x <- R[, 1:2]; x[, 2] <- -x[, 1] + 1e-4 * R[, 3]; sharpe_deflated(x, frequency = 'day')",
         py("x = R[:, :2].copy(); x[:, 1] = -x[:, 0] + 1e-4 * R[:, 2]; result = OF.sharpe_deflated(x, frequency='day')"), I, jl = jl('x = R[:, 1:2]; x[:, 2] = -x[:, 1] .+ 1e-4 .* R[:, 3]; result = OF.sharpe_deflated(x; frequency = "day")'))
ref_case("dsr_rho_nan", "sharpe_deflated(R[, 2:3] * 1e160, frequency = 'day')",
         py("result = OF.sharpe_deflated(R[:, 1:3] * 1e160, frequency='day')"), I, jl = jl('result = OF.sharpe_deflated(R[:, 2:3] .* 1e160; frequency = "day")'))
ref_case("dsr_ntr1", "sharpe_deflated(R, frequency = 'month', n_trials = 1)", py("result = OF.sharpe_deflated(R, frequency='month', n_trials=1)"), I, jl = jl('result = OF.sharpe_deflated(R; frequency = "month", n_trials = 1)'))

# ── sharpe_haircut ──────────────────────────────────────────────────────────
ref_case("hc_vec", "sharpe_haircut(c(1, 0.5), n_obs = 520, n_tests = 50, ppy = 52)",
         py("result = OF.sharpe_haircut([1, 0.5], n_obs=520, n_tests=50, ppy=52)"), jl = jl('result = OF.sharpe_haircut([1, 0.5]; n_obs = 520, n_tests = 50, ppy = 52)'))
ref_case("hc_vec2", "sharpe_haircut(c(0.3, -0.8, 0, 1.4), n_obs = 120, ppy = 12)",
         py("result = OF.sharpe_haircut(np.array([0.3, -0.8, 0, 1.4]), n_obs=120, ppy=12)"), jl = jl('result = OF.sharpe_haircut([0.3, -0.8, 0, 1.4]; n_obs = 120, ppy = 12)'))
ref_case("hc_mat", "sharpe_haircut(R, frequency = 'day')", py("result = OF.sharpe_haircut(R, frequency='day')"), I, jl = jl('result = OF.sharpe_haircut(R; frequency = "day")'))
ref_case("hc_mat_nt", "sharpe_haircut(Rs, n_tests = 20, dates = dts)", py("result = OF.sharpe_haircut(Rs, n_tests=20, dates=dts)"), I, jl = jl('result = OF.sharpe_haircut(Rs; n_tests = 20, dates = dts)'))
ref_case("hc_mat_nt2", "sharpe_haircut(R, n_tests = 3, frequency = 'day')", py("result = OF.sharpe_haircut(R, n_tests=3, frequency='day')"), I, jl = jl('result = OF.sharpe_haircut(R; n_tests = 3, frequency = "day")'))
ref_case("hc_err", "sharpe_haircut(c(1, 0.5))", py("result = OF.sharpe_haircut([1, 0.5])"), jl = jl('result = OF.sharpe_haircut([1, 0.5])'))
ref_case("hc_flat", "sharpe_haircut(cbind(Rc, cash), frequency = 'day')",
         py("result = OF.sharpe_haircut(np.column_stack([Rc, cash]), frequency='day')"), I, jl = jl('result = OF.sharpe_haircut(hcat(Rc, cash); frequency = "day")'))
ref_case("hc_attr", "h <- sharpe_haircut(c(1, 0.5, 2), n_obs = 100, n_tests = 7); c(attr(h, 'n_tests'), attr(h, 'n_obs'))",
         py("h = OF.sharpe_haircut([1, 0.5, 2], n_obs=100, n_tests=7); result = [h.attrs['n_tests'], h.attrs['n_obs']]"), jl = jl('h = OF.sharpe_haircut([1, 0.5, 2]; n_obs = 100, n_tests = 7); result = [attrs(h)["n_tests"], attrs(h)["n_obs"]]'))

# ── overfit_walk_forward auf einer nachgebauten Suche ───────────────────────────────
set.seed(11); n <- 900
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
wf <- function(id, rargs, pargs, jargs, m = "grid")
  ref_case(id, sprintf("overfit_walk_forward(mkps('%s')%s)", m, rargs), py(paste0(MK, sprintf("result = OF.overfit_walk_forward(mkps('%s')%s)", m, pargs))), I2,
           jl = jl(paste0(MKJ, sprintf('result = OF.overfit_walk_forward(mkps("%s")%s)', m, jargs))))
wf("wf_basic", ", train = 1, test = 0.5", ", train=1, test=0.5", '; train = 1, test = 0.5')
wf("wf_overlap", ", train = 1, test = 0.5, step = 0.25", ", train=1, test=0.5, step=0.25", '; train = 1, test = 0.5, step = 0.25')
wf("wf_gap", ", train = 0.5, test = 1/12, step = 0.5", ", train=0.5, test=1/12, step=0.5", '; train = 0.5, test = 1/12, step = 0.5')
wf("wf_anchored", ", train = 1, test = 1/3, anchored = TRUE", ", train=1, test=1/3, anchored=True", '; train = 1, test = 1/3, anchored = true')
wf("wf_plateau", ", train = 1, test = 0.5, select = 'plateau'", ", train=1, test=0.5, select='plateau'", '; train = 1, test = 0.5, select = "plateau"')
wf("wf_plateau_rnd", ", train = 1, test = 0.5, select = 'plateau'", ", train=1, test=0.5, select='plateau'", '; train = 1, test = 0.5, select = "plateau"', m = "random")
wf("wf_sortino", ", train = 1, test = 0.5, metric = 'sortino', risk_free = 2", ", train=1, test=0.5, metric='sortino', risk_free=2", '; train = 1, test = 0.5, metric = "sortino", risk_free = 2')
wf("wf_geom", ", train = 1.5, test = 0.25, metric = 'geometric'", ", train=1.5, test=0.25, metric='geometric'", '; train = 1.5, test = 0.25, metric = "geometric"')
wf("wf_mean", ", train = 1, test = 1, metric = 'mean'", ", train=1, test=1, metric='mean'", '; train = 1, test = 1, metric = "mean"')
wf("wf_short", ", train = 3, test = 1", ", train=3, test=1", '; train = 3, test = 1')
ref_case("wf_notps", "overfit_walk_forward(Rw)", py("result = OF.overfit_walk_forward(Rw)"), I2, jl = jl('result = OF.overfit_walk_forward(Rw)'))
ref_case("wf_noret", "x <- mkps(); x$returns <- NULL; overfit_walk_forward(x)",
         py(paste0(MK, "x = mkps(); x['returns'] = None; result = OF.overfit_walk_forward(x)")), I2, jl = jl(paste0(MKJ, 'x = mkps(); x["returns"] = nothing; result = OF.overfit_walk_forward(x)')))
ref_case("of_noret", "x <- mkps(); x$returns <- NULL; overfit_pbo(x)",
         py(paste0(MK, "x = mkps(); x['returns'] = None; result = OF.overfit_pbo(x)")), I2, jl = jl(paste0(MKJ, 'x = mkps(); x["returns"] = nothing; result = OF.overfit_pbo(x)')))
ref_case("ps_pbo", "overfit_pbo(mkps(), S = 4)", py(paste0(MK, "result = OF.overfit_pbo(mkps(), S=4)")), I2, jl = jl(paste0(MKJ, 'result = OF.overfit_pbo(mkps(); S = 4)')))
ref_case("ps_dsr", "sharpe_deflated(mkps(), id = 4, frequency = 'month')", py(paste0(MK, "result = OF.sharpe_deflated(mkps(), id=4, frequency='month')")), I2, jl = jl(paste0(MKJ, 'result = OF.sharpe_deflated(mkps(); id = 4, frequency = "month")')))
ref_case("ps_hc", "sharpe_haircut(mkps())", py(paste0(MK, "result = OF.sharpe_haircut(mkps())")), I2, jl = jl(paste0(MKJ, 'result = OF.sharpe_haircut(mkps())')))
ref_case("ps_ofret", "SimLev:::.of_returns(mkps(), 'week')", py(paste0(MK, "result = OF._of_returns(mkps(), 'week')")), I2, jl = jl(paste0(MKJ, 'result = OF._of_returns(mkps(), "week")')))

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
bcase <- function(id, r, p, j) ref_case(id, paste0(BR, r), py(paste0(BP, p)), I3, jl = jl(paste0(BJ, j)))
bcase("pb_top", "bs <- param_bootstrap(ps, h, cfg, top = 2, method = 'stationary', n = 3, params = list(L = 50), seed = 1, progress = FALSE); list(attr(bs, 'param_ids'), bs$results)",
      "bs = OF.param_bootstrap(ps, h, cfg, top=2, method='stationary', n=3, params={'L': 50}, seed=1, progress=False); result = [bs.attrs['param_ids'], bs['results']]",
      'bs = OF.param_bootstrap(ps, h, cfg; top = 2, method = "stationary", n = 3, params = RList("L" => 50), seed = 1, progress = false); result = [OF.param_ids(bs), bs["results"]]')
bcase("pb_plateau", "bs <- param_bootstrap(ps, h, cfg, top = 1, by = 'plateau', method = 'block', n = 2, params = list(block_length = 20), seed = 3, progress = FALSE); list(attr(bs, 'param_ids'), bs$results)",
      "bs = OF.param_bootstrap(ps, h, cfg, top=1, by='plateau', method='block', n=2, params={'block_length': 20}, seed=3, progress=False); result = [bs.attrs['param_ids'], bs['results']]",
      'bs = OF.param_bootstrap(ps, h, cfg; top = 1, by = "plateau", method = "block", n = 2, params = RList("block_length" => 20), seed = 3, progress = false); result = [OF.param_ids(bs), bs["results"]]')
bcase("pb_ids", "bs <- param_bootstrap(ps, h, cfg, ids = c(3, 1), map = c(x = 'us'), include = list(bh = create_strategy(us = asset_config('etf', 'bnh', spread = 0.1))), method = 'raw', n = 2, seed = 4, progress = FALSE, burn_in = 60); list(attr(bs, 'param_ids'), bs$results)",
      "bs = OF.param_bootstrap(ps, h, cfg, ids=[3, 1], map={'x': 'us'}, include={'bh': create_strategy(us=asset_config(asset_class='etf', trading='bnh', spread=0.1))}, method='raw', n=2, seed=4, progress=False, burn_in=60); result = [bs.attrs['param_ids'], bs['results']]",
      'bs = OF.param_bootstrap(ps, h, cfg; ids = [3, 1], map = named("x" => "us"), include = RList("bh" => create_strategy("us" => asset_config("etf", "bnh", spread = 0.1))), method = "raw", n = 2, seed = 4, progress = false, burn_in = 60); result = [OF.param_ids(bs), bs["results"]]')
bcase("pb_err", "param_bootstrap(list(a = 1), h, cfg)", "result = OF.param_bootstrap({'a': 1}, h, cfg)",
      'result = OF.param_bootstrap(RList("a" => 1), h, cfg)')
bcase("ps_real_checks", "list(overfit_pbo(ps, S = 2, frequency = 'week'), sharpe_deflated(ps, frequency = 'day')$psr, sharpe_haircut(ps, frequency = 'month'), overfit_walk_forward(ps, train = 0.5, test = 0.25)$summary)",
      "result = [OF.overfit_pbo(ps, S=2, frequency='week'), OF.sharpe_deflated(ps, frequency='day')['psr'], OF.sharpe_haircut(ps, frequency='month'), OF.overfit_walk_forward(ps, train=0.5, test=0.25)['summary']]",
      'result = [OF.overfit_pbo(ps; S = 2, frequency = "week"), OF.sharpe_deflated(ps; frequency = "day")["psr"], OF.sharpe_haircut(ps; frequency = "month"), OF.overfit_walk_forward(ps; train = 0.5, test = 0.25)["summary"]]')
# ── cores = 2: param_bootstrap reicht cores an bootstrap_study ──
bcase("pb_cores2", "bs <- param_bootstrap(ps, h, cfg, top = 2, method = 'stationary', n = 3, params = list(L = 50), seed = 1, progress = FALSE, chunk_size = 1, cores = 2); list(attr(bs, 'param_ids'), bs$results)",
      "bs = OF.param_bootstrap(ps, h, cfg, top=2, method='stationary', n=3, params={'L': 50}, seed=1, progress=False, chunk_size=1, cores=2); result = [bs.attrs['param_ids'], bs['results']]",
      'bs = OF.param_bootstrap(ps, h, cfg; top = 2, method = "stationary", n = 3, params = RList("L" => 50), seed = 1, progress = false, chunk_size = 1, cores = 2); result = [OF.param_ids(bs), bs["results"]]')

ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul sensitivity
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Referenzfälle für sensitivity.R (sensitivity_grid, sensitivity_rebalancing,
# planning_lumpsum_vs_dca, series_leverage, sensitivity_leverage, print-Methoden).
ref_init("sensitivity")
P <- paste0("import simlev.sensitivity as SE\nfrom simlev.config import create_strategy, asset_config\n",
            "from simlev import dca_plan, rebalance_plan, tax_profile, income_rate\n",
            "st = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.6, spread=0.1), B=asset_config(asset_class='etf', trading='bnh', share=0.4, spread=0.1))\n",
            "st0 = create_strategy(A=asset_config(asset_class='etf', trading='bnh', share=0.6, spread=0), B=asset_config(asset_class='etf', trading='bnh', share=0.4, spread=0))\n",
            "st1 = create_strategy(A=asset_config(asset_class='etf', trading='bnh', spread=0.1))\n")
R0 <- paste0("st <- create_strategy(A = asset_config('etf', 'bnh', 0.6, spread = 0.1), B = asset_config('etf', 'bnh', 0.4, spread = 0.1))\n",
             "st0 <- create_strategy(A = asset_config('etf', 'bnh', 0.6, spread = 0), B = asset_config('etf', 'bnh', 0.4, spread = 0))\n",
             "st1 <- create_strategy(A = asset_config('etf', 'bnh', spread = 0.1))\n")
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
st = create_strategy("A" => asset_config("etf", "bnh", 0.6, spread = 0.1), "B" => asset_config("etf", "bnh", 0.4, spread = 0.1))
st0 = create_strategy("A" => asset_config("etf", "bnh", 0.6; spread = 0), "B" => asset_config("etf", "bnh", 0.4; spread = 0))
st1 = create_strategy("A" => asset_config("etf", "bnh", spread = 0.1))
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
# Pfade zu Bausteinparametern
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
# rebalance_plan() in sim_args liefert die Grundwerte: Bezugsdatum bleibt je Lauf erhalten
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
case("lvs_basic", "sensitivity_leverage(d, 'A', leverages = c(1, 2, 3), rate = 2, expense = 0.5, strategy = create_strategy(LEV = asset_config('etf', 'bnh', partial_exemption = 30, spread = 0.1)))",
     "result = SE.sensitivity_leverage(d, 'A', leverages=[1, 2, 3], rate=2, expense=0.5, strategy=create_strategy(LEV=asset_config(asset_class='etf', trading='bnh', partial_exemption=30, spread=0.1)))",
     'result = SE.sensitivity_leverage(d, "A"; leverages = [1, 2, 3], rate = 2, expense = 0.5, strategy = create_strategy("LEV" => asset_config("etf", "bnh", partial_exemption = 30, spread = 0.1)))')
case("lvs_opt", "x <- sensitivity_leverage(d, 'A', leverages = c(1, 1.5, 2), rate = 2, spread = 0.4); list(attr(x, 'optimal'), attr(x, 'kind'))",
     "x = SE.sensitivity_leverage(d, 'A', leverages=[1, 1.5, 2], rate=2, spread=0.4); result = [x.attrs['optimal'], x.attrs['kind']]",
     'x = SE.sensitivity_leverage(d, "A"; leverages = [1, 1.5, 2], rate = 2, spread = 0.4); result = [attrs(x)["optimal"], attrs(x)["kind"]]')
case("lvs_default", "sensitivity_leverage(d[1:400, ], 'B')", "result = SE.sensitivity_leverage(d.iloc[:400], 'B')",
     'result = SE.sensitivity_leverage(rows(d, 1:400), "B")')
case("lvs_metric", "x <- sensitivity_leverage(d, 'A', leverages = c(-1, 1, 20), strategy = create_strategy(LEV = asset_config('etf', 'bnh', spread = 0.1)), metrics = function(r) c(cagr = r$cagr, max_drawdown = r$statistics$max_drawdown)); list(x, attr(x, 'optimal'))",
     "x = SE.sensitivity_leverage(d, 'A', leverages=[-1, 1, 20], strategy=create_strategy(LEV=asset_config(asset_class='etf', trading='bnh', spread=0.1)), metrics=lambda r: pd.Series({'cagr': r.cagr, 'max_drawdown': r.statistics['max_drawdown']})); result = [x, x.attrs['optimal']]",
     'x = SE.sensitivity_leverage(d, "A"; leverages = [-1, 1, 20], strategy = create_strategy("LEV" => asset_config("etf", "bnh", spread = 0.1)), metrics = r -> named("cagr" => r.cagr, "max_drawdown" => r.statistics.max_drawdown)); result = [x, attrs(x)["optimal"]]')
case("lvs_dca", "sensitivity_leverage(d, 'A', leverages = c(1, 2), sim_args = list(dca = dca_plan(50, 1)), strategy = create_strategy(LEV = asset_config('etf', 'bnh', partial_exemption = 30, spread = 0.1)))",
     "result = SE.sensitivity_leverage(d, 'A', leverages=[1, 2], sim_args={'dca': dca_plan(50, 1)}, strategy=create_strategy(LEV=asset_config(asset_class='etf', trading='bnh', partial_exemption=30, spread=0.1)))",
     'result = SE.sensitivity_leverage(d, "A"; leverages = [1, 2], sim_args = RList("dca" => SL.dca_plan(50, 1)), strategy = create_strategy("LEV" => asset_config("etf", "bnh", partial_exemption = 30, spread = 0.1)))')
case("lvs_none", "x <- sensitivity_leverage(d, 'A', leverages = c(1, 2), strategy = create_strategy(X = asset_config('etf', 'bnh', spread = 0.1))); list(x, attr(x, 'optimal'))",
     "x = SE.sensitivity_leverage(d, 'A', leverages=[1, 2], strategy=create_strategy(X=asset_config(asset_class='etf', trading='bnh', spread=0.1))); result = [x, x.attrs['optimal']]",
     'x = SE.sensitivity_leverage(d, "A"; leverages = [1, 2], strategy = create_strategy("X" => asset_config("etf", "bnh", spread = 0.1))); result = [x, attrs(x)["optimal"]]')
case("lvs_nocagr", "x <- sensitivity_leverage(d, 'A', leverages = c(1, 2), metrics = function(r) c(max_drawdown = r$statistics$max_drawdown), strategy = create_strategy(LEV = asset_config('etf', 'bnh', partial_exemption = 30, spread = 0.1))); list(x, attr(x, 'optimal'))",
     "x = SE.sensitivity_leverage(d, 'A', leverages=[1, 2], metrics=lambda r: pd.Series({'max_drawdown': r.statistics['max_drawdown']}), strategy=create_strategy(LEV=asset_config(asset_class='etf', trading='bnh', partial_exemption=30, spread=0.1))); result = [x, x.attrs['optimal']]",
     'x = SE.sensitivity_leverage(d, "A"; leverages = [1, 2], metrics = r -> named("max_drawdown" => r.statistics.max_drawdown), strategy = create_strategy("LEV" => asset_config("etf", "bnh", partial_exemption = 30, spread = 0.1))); result = [x, attrs(x)["optimal"]]')
# ── cores > 1: jede Einheit mit dem Zufallszustand des Aufrufers ─
case("sg_cores2_rng", "simlev_seed(7); g <- sensitivity_grid(d, st, list(rebalance.unit = c('month', 'quarter', 'year')), sim_args = list(rebalance = rebalance_plan(span = 1)), metrics = function(r) c(cagr = r$cagr), cores = 2); list(g, SimLev:::.sl_runif(1))",
     "simlev.simlev_seed(7); g = SE.sensitivity_grid(d, st, {'rebalance.unit': ['month', 'quarter', 'year']}, sim_args={'rebalance': rebalance_plan(span=1)}, metrics=lambda r: pd.Series({'cagr': r.cagr}), cores=2); result = [g, simlev._lib.runif(1)]",
     'SL.simlev_seed(7); g = SE.sensitivity_grid(d, st, RList("rebalance.unit" => ["month", "quarter", "year"]); sim_args = RList("rebalance" => SL.rebalance_plan(; span = 1)), metrics = r -> named("cagr" => r.cagr), cores = 2); result = [g, SL.SLib.runif(1)]')
case("sg_cores1_rng", "simlev_seed(7); g <- sensitivity_grid(d, st, list(rebalance.unit = c('month', 'quarter', 'year')), sim_args = list(rebalance = rebalance_plan(span = 1)), metrics = function(r) c(cagr = r$cagr), cores = 1); list(g, SimLev:::.sl_runif(1))",
     "simlev.simlev_seed(7); g = SE.sensitivity_grid(d, st, {'rebalance.unit': ['month', 'quarter', 'year']}, sim_args={'rebalance': rebalance_plan(span=1)}, metrics=lambda r: pd.Series({'cagr': r.cagr}), cores=1); result = [g, simlev._lib.runif(1)]",
     'SL.simlev_seed(7); g = SE.sensitivity_grid(d, st, RList("rebalance.unit" => ["month", "quarter", "year"]); sim_args = RList("rebalance" => SL.rebalance_plan(; span = 1)), metrics = r -> named("cagr" => r.cagr), cores = 1); result = [g, SL.SLib.runif(1)]')
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
case("lvs_cores2", "x <- sensitivity_leverage(d, 'A', leverages = c(1, 1.5, 2, 3), rate = 2, expense = 0.5, cores = 2, strategy = create_strategy(LEV = asset_config('etf', 'bnh', partial_exemption = 30, spread = 0.1))); list(x, attr(x, 'optimal'))",
     "x = SE.sensitivity_leverage(d, 'A', leverages=[1, 1.5, 2, 3], rate=2, expense=0.5, cores=2, strategy=create_strategy(LEV=asset_config(asset_class='etf', trading='bnh', partial_exemption=30, spread=0.1))); result = [x, x.attrs['optimal']]",
     'x = SE.sensitivity_leverage(d, "A"; leverages = [1, 1.5, 2, 3], rate = 2, expense = 0.5, cores = 2, strategy = create_strategy("LEV" => asset_config("etf", "bnh", partial_exemption = 30, spread = 0.1))); result = [x, attrs(x)["optimal"]]')

ref_done()

ref_schreiben()
