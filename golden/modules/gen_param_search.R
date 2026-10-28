# Referenzfälle für param_search.R (param_space, param_range, param_search,
# plateau, print/summary, .ps_*-Helfer, .run_spec, .as_spec).
source("golden/modules/ref_tools.R"); ref_init("param_search")
P <- paste0("import simlev.param_search as PS\nimport simlev.overfitting as OF\nimport simlev.signals as SG\n",
            "from simlev._r import rng\nfrom simlev.config import create_strategy, asset_config\n")
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
ref_case("design_lhs", paste0(SP3, "; set.seed(3); list(SimLev:::.ps_design(sp, 'lhs', 20, NULL), runif(1))"),
         py(paste0(SP3P, "rng.set_seed(3); result = [PS._ps_design(sp, 'lhs', 20, None), rng.runif(1)]")), jl = jl(paste0(SP3J, 'SL.RRng.set_seed(3); result = [PS._ps_design(sp, "lhs", 20, nothing), SL.RRng.runif(1)]')))
ref_case("design_rand", paste0(SP3, "; set.seed(4); list(SimLev:::.ps_design(sp, 'random', 15, function(p) p$w < 0.5), runif(1))"),
         py(paste0(SP3P, "rng.set_seed(4); result = [PS._ps_design(sp, 'random', 15, lambda p: p['w'] < 0.5), rng.runif(1)]")), jl = jl(paste0(SP3J, 'SL.RRng.set_seed(4); result = [PS._ps_design(sp, "random", 15, p -> p["w"] < 0.5), SL.RRng.runif(1)]')))
ref_case("design_disc", "set.seed(5); sp <- param_space(a = c(1, 2), b = c('u', 'v', 'w')); list(SimLev:::.ps_design(sp, 'random', 10, NULL), runif(1))",
         py("rng.set_seed(5); sp = PS.param_space(a=[1.0, 2.0], b=['u', 'v', 'w']); result = [PS._ps_design(sp, 'random', 10, None), rng.runif(1)]"), jl = jl('SL.RRng.set_seed(5); sp = PS.param_space(a = [1.0, 2.0], b = ["u", "v", "w"]); result = [PS._ps_design(sp, "random", 10, nothing), SL.RRng.runif(1)]'))
ref_case("design_lhs1", "set.seed(6); sp <- param_space(a = param_range(0, 1)); list(SimLev:::.ps_design(sp, 'lhs', 1, NULL), SimLev:::.ps_design(sp, 'lhs', 3, NULL))",
         py("rng.set_seed(6); sp = PS.param_space(a=PS.param_range(0, 1)); result = [PS._ps_design(sp, 'lhs', 1, None), PS._ps_design(sp, 'lhs', 3, None)]"), jl = jl('SL.RRng.set_seed(6); sp = PS.param_space(a = PS.param_range(0, 1)); result = [PS._ps_design(sp, "lhs", 1, nothing), PS._ps_design(sp, "lhs", 3, nothing)]'))
ref_case("as_spec", "st <- create_strategy(A = asset_config('etf', 'bnh')); list(SimLev:::.as_spec(st), SimLev:::.as_spec(list(strategy = st, args = list(a = 1))), SimLev:::.as_spec(list(a = 1)))",
         py("st = create_strategy(A=asset_config('etf', 'bnh')); result = [PS._as_spec(st), PS._as_spec({'strategy': st, 'args': {'a': 1}}), PS._as_spec({'a': 1})]"), jl = jl('st = create_strategy("A" => asset_config("etf", "bnh")); result = [PS._as_spec(st), PS._as_spec(RList("strategy" => st, "args" => RList("a" => 1))), PS._as_spec(RList("a" => 1))]'))

# ── Daten für Suchen ────────────────────────────────────────────────────────
set.seed(1); n <- 600
d <- data.frame(date = seq.Date(as.Date("2012-01-30"), by = "day", length.out = n))
d$A <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.011)); d$B <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.004))
I <- list(d = d)
RS <- "st <- create_strategy(A = asset_config('etf', 'signal', signal_buy = 'buy', signal_sell = 'sell'))
b <- function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, p$band))
st2 <- create_strategy(A = asset_config('etf', 'bnh', 0.5), B = asset_config('etf', 'bnh', 0.5))\n"
PSS <- "st = create_strategy(A=asset_config('etf', 'signal', signal_buy='buy', signal_sell='sell'))
def b(p):
    return {'strategy': st, 'signal': lambda df: SG.signal_sma(df['A'], p['n'], p['band'])}
st2 = create_strategy(A=asset_config('etf', 'bnh', 0.5), B=asset_config('etf', 'bnh', 0.5))
def z(x):
    x['elapsed'] = 0.0
    return x
def dropE(s):
    s['best'] = s['best'].drop(columns='error'); s['best_plateau'] = s['best_plateau'].drop(columns='error')
    return s
"
PSJ <- 'st = create_strategy("A" => asset_config("etf", "signal"; signal_buy = "buy", signal_sell = "sell"))
b(p) = RList("strategy" => st, "signal" => df -> SL.Signals.signal_sma(df["A"]; n = p["n"], band = p["band"]))
st2 = create_strategy("A" => asset_config("etf", "bnh", 0.5), "B" => asset_config("etf", "bnh", 0.5))
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
ps_case("ps_plateau", "x <- z(param_search(d, b, param_space(n = c(10, 20, 40), band = c(0, 2)), burn_in = 50)); list(plateau(x), plateau(x, 'cagr'), plateau(x, 'max_drawdown', radius = 2))",
        "x = z(PS.param_search(d, b, PS.param_space(n=[10.0, 20.0, 40.0], band=[0.0, 2.0]), burn_in=50)); result = [PS.plateau(x), PS.plateau(x, 'cagr'), PS.plateau(x, 'max_drawdown', radius=2)]",
        'x = z(PS.param_search(d, b, PS.param_space(n = [10.0, 20.0, 40.0], band = [0.0, 2.0]); burn_in = 50)); result = [PS.plateau(x), PS.plateau(x; metric = "cagr"), PS.plateau(x; metric = "max_drawdown", radius = 2)]')
ps_case("ps_noBuilder", "z(param_search(d, space = param_space(balance_thresh = c(2, 5, 10)), strategy = st2, sim_args = list(balance_mode = TRUE, balance_span = 1, balance_unit = 'month')))",
        "result = z(PS.param_search(d, space=PS.param_space(balance_thresh=[2.0, 5.0, 10.0]), strategy=st2, sim_args={'balance_mode': True, 'balance_span': 1, 'balance_unit': 'month'}))",
        'result = z(PS.param_search(d; space = PS.param_space(balance_thresh = [2.0, 5.0, 10.0]), strategy = st2, sim_args = RList("balance_mode" => true, "balance_span" => 1, "balance_unit" => "month")))')
ps_case("ps_listspace", "z(param_search(d, space = list(balance_unit = c('month', 'year')), strategy = st2, sim_args = list(balance_mode = TRUE, balance_span = 1), objective = 'cagr'))",
        "result = z(PS.param_search(d, space={'balance_unit': ['month', 'year']}, strategy=st2, sim_args={'balance_mode': True, 'balance_span': 1}, objective='cagr'))",
        'result = z(PS.param_search(d; space = RList("balance_unit" => ["month", "year"]), strategy = st2, sim_args = RList("balance_mode" => true, "balance_span" => 1), objective = "cagr"))')
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
ps_case("ps_random", "set.seed(9); x <- z(param_search(d, b, param_space(n = param_range(5, 60, integer = TRUE), band = param_range(0, 3)), method = 'random', n = 5, seed = 2, burn_in = 60)); list(x, runif(1), plateau(x), plateau(x, k = 2))",
        "rng.set_seed(9); x = z(PS.param_search(d, b, PS.param_space(n=PS.param_range(5, 60, integer=True), band=PS.param_range(0, 3)), method='random', n=5, seed=2, burn_in=60)); result = [x, rng.runif(1), PS.plateau(x), PS.plateau(x, k=2)]",
        'SL.RRng.set_seed(9); x = z(PS.param_search(d, b, PS.param_space(n = PS.param_range(5, 60; integer = true), band = PS.param_range(0, 3)); method = "random", n = 5, seed = 2, burn_in = 60)); result = [x, SL.RRng.runif(1), PS.plateau(x), PS.plateau(x; k = 2)]')
ps_case("ps_lhs", "set.seed(9); x <- z(param_search(d, b, param_space(n = param_range(5, 60, integer = TRUE, log = TRUE), band = c(0, 1)), method = 'lhs', n = 4, burn_in = 60)); list(x, runif(1), dropE(summary(x)))",
        "rng.set_seed(9); x = z(PS.param_search(d, b, PS.param_space(n=PS.param_range(5, 60, integer=True, log=True), band=[0.0, 1.0]), method='lhs', n=4, burn_in=60)); result = [x, rng.runif(1), dropE(PS.summary(x))]",
        'SL.RRng.set_seed(9); x = z(PS.param_search(d, b, PS.param_space(n = PS.param_range(5, 60; integer = true, log = true), band = [0.0, 1.0]); method = "lhs", n = 4, burn_in = 60)); result = [x, SL.RRng.runif(1), dropE(r_summary(x))]')
ps_case("ps_noret", "z(param_search(d, b, param_space(n = c(10, 20), band = 0), keep_returns = FALSE, burn_in = 30))",
        "result = z(PS.param_search(d, b, PS.param_space(n=[10.0, 20.0], band=0.0), keep_returns=False, burn_in=30))",
        'result = z(PS.param_search(d, b, PS.param_space(n = [10.0, 20.0], band = 0.0); keep_returns = false, burn_in = 30))')
ps_case("ps_metrics", "z(param_search(d, b, param_space(n = c(10, 20, 30), band = 0), metrics = function(r) if (r$cagr > 0.5) stop('x') else c(sharpe = r$statistics$sharpe, cagr = r$cagr), burn_in = 30))",
        "def mt(r):\n    if r.cagr > 0.5:\n        raise ValueError('x')\n    return pd.Series({'sharpe': r.statistics['sharpe'], 'cagr': r.cagr})\nresult = z(PS.param_search(d, b, PS.param_space(n=[10.0, 20.0, 30.0], band=0.0), metrics=mt, burn_in=30))",
        'mt(r) = r.cagr > 0.5 ? error("x") : named("sharpe" => r.statistics.sharpe, "cagr" => r.cagr)
result = z(PS.param_search(d, b, PS.param_space(n = [10.0, 20.0, 30.0], band = 0.0); metrics = mt, burn_in = 30))')
ps_case("ps_metric1", "z(param_search(d, b, param_space(n = c(10, 20), band = 0), metrics = function(r) c(cagr = r$cagr), objective = 'cagr', burn_in = 30))",
        "result = z(PS.param_search(d, b, PS.param_space(n=[10.0, 20.0], band=0.0), metrics=lambda r: pd.Series({'cagr': r.cagr}), objective='cagr', burn_in=30))",
        'result = z(PS.param_search(d, b, PS.param_space(n = [10.0, 20.0], band = 0.0); metrics = r -> named("cagr" => r.cagr), objective = "cagr", burn_in = 30))')
ps_case("ps_minimize", "x <- z(param_search(d, b, param_space(n = c(10, 20, 40), band = c(0, 2)), objective = 'max_drawdown', maximize = FALSE, burn_in = 50)); list(x, plateau(x))",
        "x = z(PS.param_search(d, b, PS.param_space(n=[10.0, 20.0, 40.0], band=[0.0, 2.0]), objective='max_drawdown', maximize=False, burn_in=50)); result = [x, PS.plateau(x)]",
        'x = z(PS.param_search(d, b, PS.param_space(n = [10.0, 20.0, 40.0], band = [0.0, 2.0]); objective = "max_drawdown", maximize = false, burn_in = 50)); result = [x, PS.plateau(x)]')
ps_case("ps_spec", "bs <- function(p) list(strategy = create_strategy(L = asset_config('etf', 'bnh')), data = function(df) { df$L2 <- leveraged_series(df, 'A', p$lev); df }, map = c(L = 'L2'), args = list(start_value = p$sv))
  z(param_search(d, bs, param_space(lev = c(1, 2), sv = c(1000, 5000)), sim_args = list(start_value = 1)))",
        "import simlev.sensitivity as SE\ndef bs(p):\n    def dat(df):\n        df = df.copy(); df['L2'] = SE.leveraged_series(df, 'A', p['lev']); return df\n    return {'strategy': create_strategy(L=asset_config('etf', 'bnh')), 'data': dat, 'map': {'L': 'L2'}, 'args': {'start_value': p['sv']}}\nresult = z(PS.param_search(d, bs, PS.param_space(lev=[1.0, 2.0], sv=[1000.0, 5000.0]), sim_args={'start_value': 1}))",
        'bs(p) = RList("strategy" => create_strategy("L" => asset_config("etf", "bnh")), "data" => df -> (df["L2"] = SL.Sensitivity.leveraged_series(df, "A"; leverage = p["lev"]); df), "map" => named("L" => "L2"), "args" => RList("start_value" => p["sv"]))
result = z(PS.param_search(d, bs, PS.param_space(lev = [1.0, 2.0], sv = [1000.0, 5000.0]); sim_args = RList("start_value" => 1)))')
ps_case("ps_plainstrat", "z(param_search(d, function(p) create_strategy(A = asset_config('etf', 'bnh', p$w), B = asset_config('etf', 'bnh', 1 - p$w)), param_space(w = c(0.3, 0.7))))",
        "result = z(PS.param_search(d, lambda p: create_strategy(A=asset_config('etf', 'bnh', p['w']), B=asset_config('etf', 'bnh', 1 - p['w'])), PS.param_space(w=[0.3, 0.7])))",
        'result = z(PS.param_search(d, p -> create_strategy("A" => asset_config("etf", "bnh", p["w"]), "B" => asset_config("etf", "bnh", 1 - p["w"])), PS.param_space(w = [0.3, 0.7])))')
ps_case("ps_sigdf", "sgd <- function(p) list(strategy = st, signal = function(df) { s <- signal_sma(df$A, p$n); df$buy <- s$buy; df$sell <- s$sell; df })
  z(param_search(d, sgd, param_space(n = c(10, 20)), burn_in = 25))",
        "def sgd(p):\n    def sg(df):\n        s = SG.signal_sma(df['A'], p['n']); df = df.copy(); df['buy'] = s['buy']; df['sell'] = s['sell']; return df\n    return {'strategy': st, 'signal': sg}\nresult = z(PS.param_search(d, sgd, PS.param_space(n=[10.0, 20.0]), burn_in=25))",
        'sgd(p) = RList("strategy" => st, "signal" => df -> (s = SL.Signals.signal_sma(df["A"]; n = p["n"]); df["buy"] = s["buy"]; df["sell"] = s["sell"]; df))
result = z(PS.param_search(d, sgd, PS.param_space(n = [10.0, 20.0]); burn_in = 25))')
ps_case("ps_signa", "sgn <- function(p) list(strategy = st, signal = function(df) list(buy = c(NA, df$A[-1] > df$A[-nrow(df)]), sell = c(NA, df$A[-1] < df$A[-nrow(df)] * (1 - p$k))))
  z(param_search(d, sgn, param_space(k = c(0, 0.01))))",
        "def sgn(p):\n    def sg(df):\n        a = df['A'].to_numpy()\n        return {'buy': np.array([None] + list(a[1:] > a[:-1]), dtype=object), 'sell': np.array([None] + list(a[1:] < a[:-1] * (1 - p['k'])), dtype=object)}\n    return {'strategy': st, 'signal': sg}\nresult = z(PS.param_search(d, sgn, PS.param_space(k=[0.0, 0.01])))",
        'sgn(p) = RList("strategy" => st, "signal" => df -> (a = df["A"]; RList("buy" => vcat(missing, a[2:end] .> a[1:end-1]), "sell" => vcat(missing, a[2:end] .< a[1:end-1] .* (1 - p["k"])))))
result = z(PS.param_search(d, sgn, PS.param_space(k = [0.0, 0.01])))')
ps_case("ps_constraint", "z(param_search(d, space = param_space(balance_thresh = c(2, 5, 10), balance_unit = c('month', 'year')), strategy = st2, constraint = function(p) p$balance_thresh < 10 || p$balance_unit == 'year', sim_args = list(balance_mode = TRUE, balance_span = 1)))",
        "result = z(PS.param_search(d, space=PS.param_space(balance_thresh=[2.0, 5.0, 10.0], balance_unit=['month', 'year']), strategy=st2, constraint=lambda p: p['balance_thresh'] < 10 or p['balance_unit'] == 'year', sim_args={'balance_mode': True, 'balance_span': 1}))",
        'result = z(PS.param_search(d; space = PS.param_space(balance_thresh = [2.0, 5.0, 10.0], balance_unit = ["month", "year"]), strategy = st2, constraint = p -> p["balance_thresh"] < 10 || p["balance_unit"] == "year", sim_args = RList("balance_mode" => true, "balance_span" => 1)))')
ps_case("ps_plateau_c", "x <- z(param_search(d, space = param_space(balance_thresh = c(2, 5, 10), balance_unit = c('month', 'year')), strategy = st2, constraint = function(p) p$balance_thresh < 10 || p$balance_unit == 'year', sim_args = list(balance_mode = TRUE, balance_span = 1))); list(plateau(x), dropE(summary(x)))",
        "x = z(PS.param_search(d, space=PS.param_space(balance_thresh=[2.0, 5.0, 10.0], balance_unit=['month', 'year']), strategy=st2, constraint=lambda p: p['balance_thresh'] < 10 or p['balance_unit'] == 'year', sim_args={'balance_mode': True, 'balance_span': 1})); result = [PS.plateau(x), dropE(PS.summary(x))]",
        'x = z(PS.param_search(d; space = PS.param_space(balance_thresh = [2.0, 5.0, 10.0], balance_unit = ["month", "year"]), strategy = st2, constraint = p -> p["balance_thresh"] < 10 || p["balance_unit"] == "year", sim_args = RList("balance_mode" => true, "balance_span" => 1))); result = [PS.plateau(x), dropE(r_summary(x))]')

# ── plateau auf nachgebautem Objekt (test-blue-planning) ────────────────────
FK <- "x <- structure(list(results = data.frame(id = 1:4, n = c(10, 20, 30, 40), sharpe = c(1, 2, 3, 4), max_drawdown = c(0.1, 0.5, 0.2, 0.3), cagr = c(0.05, 0.02, 0.04, 0.01)),
  params = 'n', method = 'grid', space = param_space(n = c(10, 20, 30, 40)), objective = 'sharpe', maximize = TRUE), class = 'SimLevParamSearch')\n"
FKP <- "x = PS.SimLevParamSearch(results=pd.DataFrame({'id': [1, 2, 3, 4], 'n': [10.0, 20.0, 30.0, 40.0], 'sharpe': [1.0, 2.0, 3.0, 4.0], 'max_drawdown': [0.1, 0.5, 0.2, 0.3], 'cagr': [0.05, 0.02, 0.04, 0.01]}),
  params=['n'], method='grid', space=PS.param_space(n=[10.0, 20.0, 30.0, 40.0]), objective='sharpe', maximize=True)\n"
FKJ <- 'x = RList("results" => RFrame("id" => [1, 2, 3, 4], "n" => [10.0, 20.0, 30.0, 40.0], "sharpe" => [1.0, 2.0, 3.0, 4.0], "max_drawdown" => [0.1, 0.5, 0.2, 0.3], "cagr" => [0.05, 0.02, 0.04, 0.01]), "params" => "n", "method" => "grid", "space" => PS.param_space(n = [10.0, 20.0, 30.0, 40.0]), "objective" => "sharpe", "maximize" => true; class = "SimLevParamSearch")\n'
ref_case("plateau_fake", paste0(FK, "list(plateau(x, metric = 'max_drawdown'), plateau(x, metric = 'cagr'), plateau(x), {x$maximize <- FALSE; x$objective <- 'max_drawdown'; plateau(x)})"),
         py(paste0(FKP, "r1 = [PS.plateau(x, metric='max_drawdown'), PS.plateau(x, metric='cagr'), PS.plateau(x)]\nx['maximize'] = False; x['objective'] = 'max_drawdown'\nresult = r1 + [PS.plateau(x)]")), jl = jl(paste0(FKJ, 'r1 = [PS.plateau(x; metric = "max_drawdown"), PS.plateau(x; metric = "cagr"), PS.plateau(x)]\nx["maximize"] = false; x["objective"] = "max_drawdown"\nresult = vcat(r1, [PS.plateau(x)])')))
ref_case("plateau_rnd1", paste0(FK, "x$method <- 'random'; x$results <- x$results[2, ]; x$results$m <- 'q'; x$params <- c('n', 'm'); SimLev:::.ps_neighbours(x)"),
         py(paste0(FKP, "x['method'] = 'random'; x['results'] = x['results'].iloc[[1]].reset_index(drop=True); x['results']['m'] = 'q'; x['params'] = ['n', 'm']; result = PS._ps_neighbours(x)")), jl = jl(paste0(FKJ, 'x["method"] = "random"; x["results"] = rows(x["results"], [2]); x["results"]["m"] = "q"; x["params"] = ["n", "m"]; result = PS._ps_neighbours(x)')))
ref_case("plateau_rnd", paste0(FK, "x$method <- 'lhs'; x$results$s <- c('b', 'a', 'b', 'c'); x$results$f <- c(TRUE, FALSE, TRUE, TRUE); x$params <- c('n', 's', 'f'); list(SimLev:::.ps_neighbours(x, k = 3), plateau(x, k = 2))"),
         py(paste0(FKP, "x['method'] = 'lhs'; x['results']['s'] = ['b', 'a', 'b', 'c']; x['results']['f'] = [True, False, True, True]; x['params'] = ['n', 's', 'f']; result = [PS._ps_neighbours(x, k=3), PS.plateau(x, k=2)]")), jl = jl(paste0(FKJ, 'x["method"] = "lhs"; x["results"]["s"] = ["b", "a", "b", "c"]; x["results"]["f"] = [true, false, true, true]; x["params"] = ["n", "s", "f"]; result = [PS._ps_neighbours(x; k = 3), PS.plateau(x; k = 2)]')))
# Zeichen-Parameter: factor()-Stufen nach R's Kollation (ICU "root": a A b B)
FKC <- function(sv, sh) sprintf("x <- structure(list(results = data.frame(id = seq_along(%s), n = 10 * seq_along(%s), s = %s, sharpe = %s, cagr = %s / 100),
  params = 's', method = 'random', space = param_space(s = unique(%s)), objective = 'sharpe', maximize = TRUE, elapsed = 0), class = 'SimLevParamSearch')\n", sv, sv, sv, sh, sh, sv)
FKCP <- function(sv, sh) sprintf("sv = %s; sh = %s\nx = PS.SimLevParamSearch(results=pd.DataFrame({'id': list(range(1, len(sv) + 1)), 'n': [10.0 * (i + 1) for i in range(len(sv))], 's': sv, 'sharpe': sh, 'cagr': [v / 100 for v in sh]}),
  params=['s'], method='random', space=PS.param_space(s=list(dict.fromkeys(sv))), objective='sharpe', maximize=True, elapsed=0.0)\n", sv, sh)
FKCJ <- function(sv, sh) sprintf('sv = %s; sh = %s\nx = RList("results" => RFrame("id" => collect(1:length(sv)), "n" => [10.0 * i for i in 1:length(sv)], "s" => sv, "sharpe" => sh, "cagr" => sh ./ 100), "params" => "s", "method" => "random", "space" => PS.param_space(s = unique(sv)), "objective" => "sharpe", "maximize" => true, "elapsed" => 0.0; class = "SimLevParamSearch")\n', sv, sh)
s4r <- "c('b', 'A', 'a', 'B')"; s4p <- "['b', 'A', 'a', 'B']"; h4 <- "c(1, 4, 2, 3)"; h4p <- "[1.0, 4.0, 2.0, 3.0]"
ref_case("plateau_chr", paste0(FKC(s4r, h4), "list(SimLev:::.ps_neighbours(x, k = 2), plateau(x, k = 2), plateau(x, 'cagr', k = 3))"),
         py(paste0(FKCP(s4p, h4p), "result = [PS._ps_neighbours(x, k=2), PS.plateau(x, k=2), PS.plateau(x, 'cagr', k=3)]")),
         jl = jl(paste0(FKCJ('["b", "A", "a", "B"]', "[1.0, 4.0, 2.0, 3.0]"), 'result = [PS._ps_neighbours(x; k = 2), PS.plateau(x; k = 2), PS.plateau(x; metric = "cagr", k = 3)]')))
s6r <- "c('b', 'A', 'a', 'B', 'c', 'C')"; s6p <- "['b', 'A', 'a', 'B', 'c', 'C']"; h6 <- "c(1, 6, 2, 5, 3, 4)"; h6p <- "[1.0, 6.0, 2.0, 5.0, 3.0, 4.0]"
ref_case("summary_chr", paste0(FKC(s6r, h6), "list(SimLev:::.ps_neighbours(x), summary(x, top = 3))"),
         py(paste0(FKCP(s6p, h6p), "result = [PS._ps_neighbours(x), PS.summary(x, top=3)]")),
         jl = jl(paste0(FKCJ('["b", "A", "a", "B", "c", "C"]', "[1.0, 6.0, 2.0, 5.0, 3.0, 4.0]"), 'result = [PS._ps_neighbours(x), r_summary(x; top = 3)]')))
ref_case("summary_chr_print", paste0(FKC(s6r, h6), "summary(x, top = 4)"),
         py(paste0(FKCP(s6p, h6p), "result = PS.summary(x, top=4)")),
         jl = jl(paste0(FKCJ('["b", "A", "a", "B", "c", "C"]', "[1.0, 6.0, 2.0, 5.0, 3.0, 4.0]"), 'result = r_summary(x; top = 4)')))
ref_case("plateau_notps", "plateau(list(a = 1))", py("result = PS.plateau({'a': 1})"), jl = jl('result = PS.plateau(RList("a" => 1))'))
ref_case("summary_print", "sm <- structure(list(top = data.frame(id = 1L, n = 50, cagr = 0.05, sharpe = 0.4, plateau = 0.4),
  best = data.frame(id = 1L, n = 50, sharpe = 0.4), best_plateau = data.frame(id = 1L, n = 50, sharpe = 0.4, plateau = 0.4),
  n = 1L, n_failed = 0L, objective = 'sharpe', method = 'grid', params = 'n', elapsed = 0), class = 'summary.SimLevParamSearch'); sm",
  py("result = PS.SummarySimLevParamSearch(top=pd.DataFrame({'id': [1], 'n': [50.0], 'cagr': [0.05], 'sharpe': [0.4], 'plateau': [0.4]}),
  best=pd.DataFrame({'id': [1], 'n': [50.0], 'sharpe': [0.4]}), best_plateau=pd.DataFrame({'id': [1], 'n': [50.0], 'sharpe': [0.4], 'plateau': [0.4]}),
  n=1, n_failed=0, objective='sharpe', method='grid', params=['n'], elapsed=0.0)"), jl = jl('result = RList("top" => RFrame("id" => [1], "n" => [50.0], "cagr" => [0.05], "sharpe" => [0.4], "plateau" => [0.4]), "best" => RFrame("id" => [1], "n" => [50.0], "sharpe" => [0.4]), "best_plateau" => RFrame("id" => [1], "n" => [50.0], "sharpe" => [0.4], "plateau" => [0.4]), "n" => 1, "n_failed" => 0, "objective" => "sharpe", "method" => "grid", "params" => "n", "elapsed" => 0.0; class = "summary.SimLevParamSearch")'))
# ── cores = 2 (Etappe 5) ────────────────────────────────────────────────────
ps_case("ps_cores2", "z(param_search(d, b, param_space(n = c(10, 20, 40), band = c(0, 2)), burn_in = 50, cores = 2))",
        "result = z(PS.param_search(d, b, PS.param_space(n=[10.0, 20.0, 40.0], band=[0.0, 2.0]), burn_in=50, cores=2))",
        'result = z(PS.param_search(d, b, PS.param_space(n = [10.0, 20.0, 40.0], band = [0.0, 2.0]); burn_in = 50, cores = 2))')
ps_case("ps_cores2_random", "set.seed(3); x <- z(param_search(d, b, param_space(n = param_range(5, 60, integer = TRUE), band = param_range(0, 2)), method = 'random', n = 5, seed = 11, burn_in = 60, cores = 2)); list(x, runif(1))",
        "rng.set_seed(3); x = z(PS.param_search(d, b, PS.param_space(n=PS.param_range(5, 60, integer=True), band=PS.param_range(0, 2)), method='random', n=5, seed=11, burn_in=60, cores=2)); result = [x, rng.runif(1)]",
        'SL.RRng.set_seed(3); x = z(PS.param_search(d, b, PS.param_space(n = PS.param_range(5, 60; integer = true), band = PS.param_range(0, 2)); method = "random", n = 5, seed = 11, burn_in = 60, cores = 2)); result = [x, SL.RRng.runif(1)]')
ps_case("ps_cores2_err", "z(param_search(d, function(p) if (p$n > 15) stop('kaputt') else b(p), param_space(n = c(10, 20, 30), band = 0), burn_in = 50, cores = 2))",
        "def bb(p):\n    if p['n'] > 15:\n        raise ValueError('kaputt')\n    return b(p)\nresult = z(PS.param_search(d, bb, PS.param_space(n=[10.0, 20.0, 30.0], band=0.0), burn_in=50, cores=2))",
        'bb(p) = p["n"] > 15 ? error("kaputt") : b(p)
result = z(PS.param_search(d, bb, PS.param_space(n = [10.0, 20.0, 30.0], band = 0.0); burn_in = 50, cores = 2))')

ref_done()
