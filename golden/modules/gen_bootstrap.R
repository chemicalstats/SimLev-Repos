# Referenzfälle für r/R/bootstrap.R (Python: simlev/bootstrap.py).
# Aufruf aus der Repo-Wurzel:
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript golden/modules/gen_bootstrap.R
source("golden/modules/ref_tools.R"); ref_init("bootstrap")

P <- "from simlev.bootstrap import *\nfrom simlev.withdrawal import *\nimport simlev.bootstrap as B\nimport simlev._r.rng as RNG\n"
CFG_R <- "cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'),
  letfs = list(list(base = 'eu', leverage = 2, finance = 'rate', expense = 0.5), list(base = 'us', leverage = -1, finance = 'rate', expense = 0.6)))\n"
CFG_P <- "cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'},
  letfs=[{'base': 'eu', 'leverage': 2, 'finance': 'rate', 'expense': 0.5}, {'base': 'us', 'leverage': -1, 'finance': 'rate', 'expense': 0.6}])\n"
JP <- "using SimLev.Bootstrap, SimLev.Withdrawal\nconst B = SimLev.Bootstrap\nconst RNG = SimLev.RRng\n"
CFG_J <- 'cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",),
  letfs = [(base = "eu", leverage = 2, finance = "rate", expense = 0.5), (base = "us", leverage = -1, finance = "rate", expense = 0.6)])\n'
case <- function(id, r, py, inputs = list(), jl = NULL, ...) ref_case(id, r = r, py = paste0(P, py), inputs = inputs,
                                                                   jl = if (is.null(jl)) NULL else paste0(JP, jl), ...)

# ── Daten ───────────────────────────────────────────────────────────────────
set.seed(5); n <- 400
us <- 1 + rnorm(n, 3e-4, 0.011)
d <- data.frame(us = us, eu = us * (1 + rnorm(n, 0, 0.004)), rate = 2 + cumsum(rnorm(n, 0, 0.005)))
set.seed(21); n2 <- 300
dp <- data.frame(us = 100 * cumprod(c(1, 1 + rnorm(n2, 3e-4, 0.01))), cpi = 100 * 1.02^((0:n2) / 365),
                 infl = 2, zins = 2 + sin((0:n2) / 40))
set.seed(3); dv <- data.frame(us = 1 + rnorm(200, 0, 0.3)); dv$us[dv$us <= 0.05] <- 0.05
I <- list(d = d, dp = dp, dv = dv)

# ── bootstrap_config ────────────────────────────────────────────────────────
case("cfg_basic", paste0(CFG_R, "cfg"), paste0(CFG_P, "result = cfg"), I,
     jl = paste0(CFG_J, 'result = cfg'))
case("cfg_auxtype", "bootstrap_config(c(us = 'us_ret'), aux = c(cpi = 'us_cpi', zins = 'us_rate', z = 'z'), aux_type = c(cpi = 'level', zins = 'rate'), cross = 'joint')",
     "result = bootstrap_config({'us': 'us_ret'}, aux={'cpi': 'us_cpi', 'zins': 'us_rate', 'z': 'z'}, aux_type={'cpi': 'level', 'zins': 'rate'}, cross='joint')",
     jl = 'result = bootstrap_config((us = "us_ret",), aux = (cpi = "us_cpi", zins = "us_rate", z = "z"), aux_type = (cpi = "level", zins = "rate"), cross = "joint")')
case("cfg_auxtype_empty", "bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi'), aux_type = character(0), cross = 'j', input = 'p')",
     "result = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi'}, aux_type=[], cross='j', input='p')",
     jl = 'result = bootstrap_config((us = "us",), aux = (cpi = "cpi",), aux_type = String[], cross = "j", input = "p")')
case("cfg_days_aux", "bootstrap_config(c(a = 'a', b = 'b'), aux = c(t = 'tage', r = 'r'), letfs = list(list(base = 'b', leverage = 3, finance = 'r', days = 't')))",
     "result = bootstrap_config({'a': 'a', 'b': 'b'}, aux={'t': 'tage', 'r': 'r'}, letfs=[{'base': 'b', 'leverage': 3, 'finance': 'r', 'days': 't'}])",
     jl = 'result = bootstrap_config((a = "a", b = "b"), aux = (t = "tage", r = "r"), letfs = [(base = "b", leverage = 3, finance = "r", days = "t")])')
case("cfg_negfin", "bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', finance = -1)))",
     "result = bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'finance': -1}])",
     jl = 'result = bootstrap_config((a = "a",), letfs = [(base = "a", finance = -1)])')
errs <- list(
  unnamed = c("bootstrap_config(c('a'))", "bootstrap_config(['a'])",
    'bootstrap_config(["a"])'),
  emptyname = c("bootstrap_config(c(a = 'a', 'b'))", "bootstrap_config(pd.Series(['a', 'b'], index=['a', '']))",
    'bootstrap_config(SL.RVector(["a", "b"]; names = ["a", ""]))'),
  dupidx = c("bootstrap_config(c(a = 'a', a = 'b'))", "bootstrap_config(pd.Series(['a', 'b'], index=['a', 'a']))",
    'bootstrap_config(["a" => "a", "a" => "b"])'),
  auxunnamed = c("bootstrap_config(c(a = 'a'), aux = 'x')", "bootstrap_config({'a': 'a'}, aux='x')",
    'bootstrap_config((a = "a",), aux = "x")'),
  base_missing = c("bootstrap_config(c(a = 'a'), letfs = list(list(leverage = 2)))", "bootstrap_config({'a': 'a'}, letfs=[{'leverage': 2}])",
    'bootstrap_config((a = "a",), letfs = [(leverage = 2,)])'),
  base_bad = c("bootstrap_config(c(a = 'a'), letfs = list(list(base = 'x')))", "bootstrap_config({'a': 'a'}, letfs=[{'base': 'x'}])",
    'bootstrap_config((a = "a",), letfs = [(base = "x",)])'),
  lev0 = c("bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', leverage = 0)))", "bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'leverage': 0}])",
    'bootstrap_config((a = "a",), letfs = [(base = "a", leverage = 0)])'),
  fin_bad = c("bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', finance = 'rate')))", "bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'finance': 'rate'}])",
    'bootstrap_config((a = "a",), letfs = [(base = "a", finance = "rate")])'),
  exp_neg = c("bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', expense = -1)))", "bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'expense': -1}])",
    'bootstrap_config((a = "a",), letfs = [(base = "a", expense = -1)])'),
  days_bad = c("bootstrap_config(c(a = 'a'), letfs = list(list(base = 'a', days = 'tage')))", "bootstrap_config({'a': 'a'}, letfs=[{'base': 'a', 'days': 'tage'}])",
    'bootstrap_config((a = "a",), letfs = [(base = "a", days = "tage")])'),
  fin_level = c("bootstrap_config(c(us = 'us'), aux = c(z = 'z'), aux_type = c(z = 'level'), letfs = list(list(base = 'us', finance = 'z')))",
                "bootstrap_config({'us': 'us'}, aux={'z': 'z'}, aux_type={'z': 'level'}, letfs=[{'base': 'us', 'finance': 'z'}])",
    'bootstrap_config((us = "us",), aux = (z = "z",), aux_type = (z = "level",), letfs = [(base = "us", finance = "z")])'),
  days_level = c("bootstrap_config(c(us = 'us'), aux = c(z = 'z'), aux_type = c(z = 'level'), letfs = list(list(base = 'us', days = 'z')))",
                 "bootstrap_config({'us': 'us'}, aux={'z': 'z'}, aux_type={'z': 'level'}, letfs=[{'base': 'us', 'days': 'z'}])",
    'bootstrap_config((us = "us",), aux = (z = "z",), aux_type = (z = "level",), letfs = [(base = "us", days = "z")])'),
  dupnames = c("bootstrap_config(c(a = 'a'), aux = c(a_l2 = 'x'), letfs = list(list(base = 'a')))", "bootstrap_config({'a': 'a'}, aux={'a_l2': 'x'}, letfs=[{'base': 'a'}])",
    'bootstrap_config((a = "a",), aux = (a_l2 = "x",), letfs = [(base = "a",)])'),
  regime_bad = c("bootstrap_config(c(a = 'a'), regime_index = 'b')", "bootstrap_config({'a': 'a'}, regime_index='b')",
    'bootstrap_config((a = "a",), regime_index = "b")'),
  at_notaux = c("bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi'), aux_type = c(cp = 'level'))", "bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi'}, aux_type={'cp': 'level'})",
    'bootstrap_config((us = "us",), aux = (cpi = "cpi",), aux_type = (cp = "level",))'),
  at_noaux = c("bootstrap_config(c(us = 'us'), aux_type = c(cpi = 'level', x = 'rate'))", "bootstrap_config({'us': 'us'}, aux_type={'cpi': 'level', 'x': 'rate'})",
    'bootstrap_config((us = "us",), aux_type = (cpi = "level", x = "rate"))'),
  at_value = c("bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi'), aux_type = c(cpi = 'niveau'))", "bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi'}, aux_type={'cpi': 'niveau'})",
    'bootstrap_config((us = "us",), aux = (cpi = "cpi",), aux_type = (cpi = "niveau",))'),
  at_unnamed = c("bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi'), aux_type = 'level')", "bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi'}, aux_type='level')",
    'bootstrap_config((us = "us",), aux = (cpi = "cpi",), aux_type = "level")'),
  at_dup = c("bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi'), aux_type = c(cpi = 'level', cpi = 'rate'))", "bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi'}, aux_type=pd.Series(['level', 'rate'], index=['cpi', 'cpi']))",
    'bootstrap_config((us = "us",), aux = (cpi = "cpi",), aux_type = ["cpi" => "level", "cpi" => "rate"])'),
  cross_bad = c("bootstrap_config(c(us = 'us'), cross = 'x')", "bootstrap_config({'us': 'us'}, cross='x')",
    'bootstrap_config((us = "us",), cross = "x")'))
for (k in names(errs)) case(paste0("cfg_err_", k), errs[[k]][1], paste0("result = ", errs[[k]][2]), jl = paste0("result = ", errs[[k]][3]))
case("cfg_print_aux", "bootstrap_config(c(us = 'us'), aux = c(cpi = 'eu_cpi', z = 'z'), aux_type = c(cpi = 'level'))",
     "result = bootstrap_config({'us': 'us'}, aux={'cpi': 'eu_cpi', 'z': 'z'}, aux_type={'cpi': 'level'})",
     jl = 'result = bootstrap_config((us = "us",), aux = (cpi = "eu_cpi", z = "z"), aux_type = (cpi = "level",))')

# ── block_length ────────────────────────────────────────────────────────────
set.seed(1); xa <- as.numeric(arima.sim(list(ar = 0.6), 1500)); xi <- rnorm(800)
Ib <- list(xa = xa, xi = xi, M = cbind(a = xa[1:800], b = xi))
case("bl_ar", "block_length(xa)", "result = block_length(xa)", Ib,
     jl = 'result = block_length(xa)')
case("bl_abs", "block_length(xa, transform = 'abs')", "result = block_length(xa, transform='abs')", Ib,
     jl = 'result = block_length(xa, transform = "abs")')
case("bl_sq", "block_length(xi, 'squared')", "result = block_length(xi, 'squared')", Ib,
     jl = 'result = block_length(xi, "squared")')
case("bl_mat", "block_length(M)", "result = block_length(M)", Ib,
     jl = 'result = block_length(M)')
case("bl_short", "block_length(xa[1:15])", "result = block_length(xa[:15])", Ib,
     jl = 'result = block_length(xa[1:15])')
case("bl_const", "block_length(rep(1, 50))", "result = block_length(np.ones(50))",
     jl = 'result = block_length(ones(50))')
case("bl_nonfinite", "x <- xa[1:300]; x[c(5, 50)] <- c(NA, Inf); block_length(cbind(x, y = xi[1:300]))",
     "x = xa[:300].copy(); x[[4, 49]] = [simlev._r.fmt.NA_REAL, np.inf]; result = block_length(pd.DataFrame({'x': x, 'y': xi[:300]}))", Ib,
     jl = 'x = xa[1:300]; x[[5, 50]] = [SL.NA, Inf]; result = block_length(SL.NamedMat(hcat(x, xi[1:300]); colnames = ["x", "y"]))')
case("bl_trend", "block_length(cumsum(xi))", "result = block_length(np.cumsum(xi))", Ib,
     jl = 'result = block_length(SL.r_cumsum(xi))')
case("bl_pw", "SimLev:::.pw_block(xa)", "result = B._pw_block(xa)", Ib,
     jl = 'result = B._pw_block(xa)')

# ── bootstrap: Verfahren ────────────────────────────────────────────────────
B1 <- function(m, extra = "", pextra = "", jextra = "") {
  case(paste0("bs_", m, gsub("[^a-z0-9]", "", extra)),
       paste0(CFG_R, "b <- bootstrap(d, cfg, '", m, "', n = 2, seed = 1, progress = FALSE", extra, "); b"),
       paste0(CFG_P, "result = bootstrap(d, cfg, '", m, "', n=2, seed=1, progress=False", pextra, ")"), I,
       jl = paste0(CFG_J, "result = bootstrap(d, cfg, \"", m, "\"; n = 2, seed = 1, progress = false", jextra, ")"))
}
for (m in c("raw", "stationary", "wild", "regime", "evt", "tails", "reset", "garch", "gjr_garch")) B1(m)
B1("block", ", params = list(block_length = 30)", ", params={'block_length': 30}", ', params = (block_length = 30,)')
B1("circular", ", params = list(block_length = 25), path_length = 600", ", params={'block_length': 25}, path_length=600", ', params = (block_length = 25,), path_length = 600')
B1("stationary", ", params = list(L = 7.5), path_length = 150", ", params={'L': 7.5}, path_length=150", ', params = (L = 7.5,), path_length = 150')
B1("wild", ", params = list(wild_type = 1)", ", params={'wild_type': 1}", ', params = (wild_type = 1,)')
B1("wild", ", params = list(wild_type = 2)", ", params={'wild_type': 2}", ', params = (wild_type = 2,)')
B1("regime", ", params = list(n_regimes = 3, vol_window = 10), path_length = 250", ", params={'n_regimes': 3, 'vol_window': 10}, path_length=250", ', params = (n_regimes = 3, vol_window = 10), path_length = 250')
B1("evt", ", params = list(tail_prob = 0.1, both_tails = FALSE)", ", params={'tail_prob': 0.1, 'both_tails': False}", ', params = (tail_prob = 0.1, both_tails = false)')
B1("tails", ", params = list(tail_prob = 0.02), path_length = 120", ", params={'tail_prob': 0.02}, path_length=120", ', params = (tail_prob = 0.02,), path_length = 120')
B1("reset", ", params = list(p_break = 0.1)", ", params={'p_break': 0.1}", ', params = (p_break = 0.1,)')
B1("stationary", ", params = list(L = 'auto')", ", params={'L': 'auto'}", ', params = (L = "auto",)')
B1("block", ", params = list(block_length = 'auto'), path_length = 90", ", params={'block_length': 'auto'}, path_length=90", ', params = (block_length = "auto",), path_length = 90')
B1("raw", ", cores = 2L, path_length = 50", ", cores=2, path_length=50", ', cores = 2, path_length = 50')
case("bs_garch_joint", "cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), cross = 'joint'); bootstrap(d, cfg, 'gjr_garch', n = 2, seed = 4, progress = FALSE, path_length = 100)",
     "cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, cross='joint'); result = bootstrap(d, cfg, 'gjr_garch', n=2, seed=4, progress=False, path_length=100)", I,
     jl = 'cfg = bootstrap_config((us = "us", eu = "eu"), cross = "joint"); result = bootstrap(d, cfg, "gjr_garch"; n = 2, seed = 4, progress = false, path_length = 100)')
case("bs_garch_regime_eu", "cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'eu'); bootstrap(d, cfg, 'garch', n = 1, seed = 2, progress = FALSE, path_length = 80)",
     "cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='eu'); result = bootstrap(d, cfg, 'garch', n=1, seed=2, progress=False, path_length=80)", I,
     jl = 'cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "eu"); result = bootstrap(d, cfg, "garch"; n = 1, seed = 2, progress = false, path_length = 80)')
case("bs_garch_single", "bootstrap(d, bootstrap_config(c(eu = 'eu')), 'garch', n = 2, seed = 3, progress = FALSE, path_length = 60)",
     "result = bootstrap(d, bootstrap_config({'eu': 'eu'}), 'garch', n=2, seed=3, progress=False, path_length=60)", I,
     jl = 'result = bootstrap(d, bootstrap_config((eu = "eu",)), "garch"; n = 2, seed = 3, progress = false, path_length = 60)')
case("bs_garch_hivol", "bootstrap(dv, bootstrap_config(c(us = 'us')), 'garch', n = 2, seed = 1, progress = FALSE)$stats",
     "result = bootstrap(dv, bootstrap_config({'us': 'us'}), 'garch', n=2, seed=1, progress=False)['stats']", I,
     jl = 'result = bootstrap(dv, bootstrap_config((us = "us",)), "garch"; n = 2, seed = 1, progress = false)["stats"]')
case("bs_wild_ko", "b <- bootstrap(dv, bootstrap_config(c(us = 'us')), 'wild', n = 3, params = list(wild_type = 2), seed = 1, progress = FALSE, max_tries = 50); list(b$stats, b$knockout_rate, b$paths[[1]][1:5, ])",
     "b = bootstrap(dv, bootstrap_config({'us': 'us'}), 'wild', n=3, params={'wild_type': 2}, seed=1, progress=False, max_tries=50); result = [b['stats'], b['knockout_rate'], b['paths'][0].iloc[:5]]", I,
     jl = 'b = bootstrap(dv, bootstrap_config((us = "us",)), "wild"; n = 3, params = (wild_type = 2,), seed = 1, progress = false, max_tries = 50); result = [b["stats"], b["knockout_rate"], b["paths"][1][1:5, :]]')
case("bs_wild_allfail", "bootstrap(dv, bootstrap_config(c(us = 'us')), 'wild', n = 2, params = list(wild_type = 2), seed = 1, progress = FALSE, max_tries = 1)",
     "result = bootstrap(dv, bootstrap_config({'us': 'us'}), 'wild', n=2, params={'wild_type': 2}, seed=1, progress=False, max_tries=1)", I,
     jl = 'result = bootstrap(dv, bootstrap_config((us = "us",)), "wild"; n = 2, params = (wild_type = 2,), seed = 1, progress = false, max_tries = 1)')
case("bs_garch_const", "bootstrap(data.frame(us = rep(1.0001, 50)), bootstrap_config(c(us = 'us')), 'garch', n = 1, seed = 1)",
     "result = bootstrap(pd.DataFrame({'us': np.full(50, 1.0001)}), bootstrap_config({'us': 'us'}), 'garch', n=1, seed=1)",
     jl = 'result = bootstrap(SL.RFrame("us" => fill(1.0001, 50)), bootstrap_config((us = "us",)), "garch"; n = 1, seed = 1)')
case("bs_cross_const", "dd <- d[1:120, 1:2]; dd$eu <- dd$us; bootstrap(dd, bootstrap_config(c(us = 'us', eu = 'eu')), 'garch', n = 1, seed = 1, progress = FALSE, path_length = 30)",
     "dd = d.iloc[:120, :2].copy(); dd['eu'] = dd['us']; result = bootstrap(dd, bootstrap_config({'us': 'us', 'eu': 'eu'}), 'garch', n=1, seed=1, progress=False, path_length=30)", I,
     jl = 'dd = SL.RFrame("us" => d.us[1:120], "eu" => d.us[1:120]); result = bootstrap(dd, bootstrap_config((us = "us", eu = "eu")), "garch"; n = 1, seed = 1, progress = false, path_length = 30)')
case("bs_msgarch", paste0(CFG_R, "bootstrap(d, cfg, 'ms_garch', n = 1, seed = 1)"), paste0(CFG_P, "result = bootstrap(d, cfg, 'ms_garch', n=1, seed=1)"), I,
     jl = paste0(CFG_J, 'result = bootstrap(d, cfg, "ms_garch"; n = 1, seed = 1)'))
case("bs_tvtp", paste0(CFG_R, "bootstrap(d, cfg, 'tvtp_ms_garch', n = 1, seed = 1)"), paste0(CFG_P, "result = bootstrap(d, cfg, 'tvtp_ms_garch', n=1, seed=1)"), I,
     jl = paste0(CFG_J, 'result = bootstrap(d, cfg, "tvtp_ms_garch"; n = 1, seed = 1)'))
# MS-GARCH-Verfahren mit Parametern (eigene Schätzung .ms_garch_fit), Fehlerwege der Prüfung
MS <- list(
  bs_ms_ar = c("ms_ar_garch_m", "list()", "{}", "(;)"),
  bs_ms_sgarch = c("ms_garch", "list(ms_garch_model = 'sGARCH')", "{'ms_garch_model': 'sGARCH'}", '(ms_garch_model = "sGARCH",)'),
  bs_ms_K3 = c("ms_garch", "list(ms_n_regimes = 3)", "{'ms_n_regimes': 3}", "(ms_n_regimes = 3,)"),
  bs_tvtp_K3 = c("tvtp_ms_garch", "list(tvtp_n_regimes = 3)", "{'tvtp_n_regimes': 3}", "(tvtp_n_regimes = 3,)"),
  bs_ms_err_egarch = c("ms_garch", "list(ms_garch_model = 'eGARCH')", "{'ms_garch_model': 'eGARCH'}", '(ms_garch_model = "eGARCH",)'),
  bs_ms_err_K1 = c("tvtp_ms_garch", "list(tvtp_n_regimes = 1)", "{'tvtp_n_regimes': 1}", "(tvtp_n_regimes = 1,)"))
for (k in names(MS)) {
  a <- MS[[k]]
  case(k, paste0(CFG_R, sprintf("bootstrap(d, cfg, '%s', n = 1, seed = 1, params = %s)", a[1], a[2])),
       paste0(CFG_P, sprintf("result = bootstrap(d, cfg, '%s', n=1, seed=1, params=%s)", a[1], a[3])), I,
       jl = paste0(CFG_J, sprintf('result = bootstrap(d, cfg, "%s"; n = 1, seed = 1, params = %s)', a[1], a[4])))
}

# Zusatzreihen als Niveau / Rate, Kursniveaus, Attribut aux_level
CF3_R <- "cfg3 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', zins = 'zins', infl = 'infl'), input = 'prices', aux_type = c(cpi = 'level', zins = 'rate'), letfs = list(list(base = 'us', leverage = 3, finance = 'zins', spread = 0.5)))\n"
CF3_J <- 'cfg3 = bootstrap_config((us = "us",), aux = (cpi = "cpi", zins = "zins", infl = "infl"), input = "prices", aux_type = (cpi = "level", zins = "rate"), letfs = [(base = "us", leverage = 3, finance = "zins", spread = 0.5)])\n'
CF3_P <- "cfg3 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'zins': 'zins', 'infl': 'infl'}, input='prices', aux_type={'cpi': 'level', 'zins': 'rate'}, letfs=[{'base': 'us', 'leverage': 3, 'finance': 'zins', 'spread': 0.5}])\n"
for (m in c("stationary", "wild", "evt", "garch", "block")) {
  case(paste0("aux_level_", m), paste0(CF3_R, "b <- suppressWarnings(bootstrap(dp, cfg3, '", m, "', n = 2, seed = 2, progress = FALSE, params = list(block_length = 10))); c(b$paths, lapply(b$paths, attr, 'aux_level'))"),
       paste0(CF3_P, "b = bootstrap(dp, cfg3, '", m, "', n=2, seed=2, progress=False, params={'block_length': 10}); result = b['paths'] + [p.attrs['aux_level'] for p in b['paths']]"), I,
       jl = paste0(CF3_J, "result = B._quiet(() -> (b = bootstrap(dp, cfg3, \"", m, "\"; n = 2, seed = 2, progress = false, params = (block_length = 10,)); vcat(b[\"paths\"], [p.attrs[\"aux_level\"] for p in b[\"paths\"]])))"))
}
case("aux_noattr_old", "cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi'), input = 'prices'); cfg$aux_type <- NULL; cfg$aux_type_set <- NULL; b <- bootstrap(dp, cfg, 'stationary', n = 2, params = list(L = 20), seed = 4, progress = FALSE); c(b$paths, lapply(b$paths, attr, 'aux_level'))",
     "cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi'}, input='prices'); del cfg['aux_type']; del cfg['aux_type_set']; b = bootstrap(dp, cfg, 'stationary', n=2, params={'L': 20}, seed=4, progress=False); result = b['paths'] + [p.attrs['aux_level'] for p in b['paths']]", I,
     jl = 'cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi",), input = "prices"); delete!(cfg, "aux_type"); delete!(cfg, "aux_type_set"); b = bootstrap(dp, cfg, "stationary"; n = 2, params = (L = 20,), seed = 4, progress = false); result = vcat(b["paths"], [p.attrs["aux_level"] for p in b["paths"]])')
case("aux_returns_input", "dd <- d; dd$cpi <- 100 * 1.0001^(1:400); cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', rate = 'rate'), aux_type = c(cpi = 'level')); b <- bootstrap(dd, cfg, 'raw', n = 1, seed = 7, progress = FALSE, path_length = 40); list(b$paths[[1]], attr(b$paths[[1]], 'aux_level'))",
     "dd = d.copy(); dd['cpi'] = 100 * np.array([1.0001 ** k for k in range(1, 401)]); cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'rate': 'rate'}, aux_type={'cpi': 'level'}); b = bootstrap(dd, cfg, 'raw', n=1, seed=7, progress=False, path_length=40); result = [b['paths'][0], b['paths'][0].attrs['aux_level']]", I,
     jl = 'dd = copy(d); dd["cpi"] = 100 .* [SL.r_pow(1.0001, k) for k in 1:400]; cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi", rate = "rate"), aux_type = (cpi = "level",)); b = bootstrap(dd, cfg, "raw"; n = 1, seed = 7, progress = false, path_length = 40); result = [b["paths"][1], b["paths"][1].attrs["aux_level"]]')
case("aux_level_err", "dd <- dp; dd$cpi[40] <- -1; bootstrap(dd, bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi'), input = 'prices', aux_type = c(cpi = 'level')), 'raw', n = 1, seed = 1)",
     "dd = dp.copy(); dd.loc[39, 'cpi'] = -1; result = bootstrap(dd, bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi'}, input='prices', aux_type={'cpi': 'level'}), 'raw', n=1, seed=1)", I,
     jl = 'dd = copy(dp); dd.cpi[40] = -1; result = bootstrap(dd, bootstrap_config((us = "us",), aux = (cpi = "cpi",), input = "prices", aux_type = (cpi = "level",)), "raw"; n = 1, seed = 1)')
case("aux_level_err_inf", "dd <- dp; dd$cpi[1] <- Inf; bootstrap(dd, bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi'), input = 'prices', aux_type = c(cpi = 'level')), 'raw', n = 1, seed = 1)",
     "dd = dp.copy(); dd.loc[0, 'cpi'] = np.inf; result = bootstrap(dd, bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi'}, input='prices', aux_type={'cpi': 'level'}), 'raw', n=1, seed=1)", I,
     jl = 'dd = copy(dp); dd.cpi[1] = Inf; result = bootstrap(dd, bootstrap_config((us = "us",), aux = (cpi = "cpi",), input = "prices", aux_type = (cpi = "level",)), "raw"; n = 1, seed = 1)')
case("aux_rate_zero_ok", "dd <- dp[1:60, ]; dd$cpi[40] <- 0; bootstrap(dd, bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi'), input = 'prices', aux_type = c(cpi = 'rate')), 'raw', n = 1, seed = 1, progress = FALSE)$paths",
     "dd = dp.iloc[:60].copy(); dd.loc[39, 'cpi'] = 0; result = bootstrap(dd, bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi'}, input='prices', aux_type={'cpi': 'rate'}), 'raw', n=1, seed=1, progress=False)['paths']", I,
     jl = 'dd = SL.rows(dp, 1:60); dd.cpi[40] = 0; result = bootstrap(dd, bootstrap_config((us = "us",), aux = (cpi = "cpi",), input = "prices", aux_type = (cpi = "rate",)), "raw"; n = 1, seed = 1, progress = false)["paths"]')
case("na_rows", "dd <- d[1:100, ]; dd$us[c(3, 50)] <- NA; dd$rate[10] <- NA; b <- bootstrap(dd, bootstrap_config(c(us = 'us'), aux = c(rate = 'rate')), 'raw', n = 1, seed = 1, progress = FALSE); list(b$paths[[1]], attr(b$paths[[1]], 'aux_level'))",
     "dd = d.iloc[:100].copy(); dd.loc[[2, 49], 'us'] = simlev._r.fmt.NA_REAL; dd.loc[9, 'rate'] = simlev._r.fmt.NA_REAL; b = bootstrap(dd, bootstrap_config({'us': 'us'}, aux={'rate': 'rate'}), 'raw', n=1, seed=1, progress=False); result = [b['paths'][0], b['paths'][0].attrs['aux_level']]", I,
     jl = 'dd = SL.rows(d, 1:100); dd.us[[3, 50]] .= SL.NA; dd.rate[10] = SL.NA; b = bootstrap(dd, bootstrap_config((us = "us",), aux = (rate = "rate",)), "raw"; n = 1, seed = 1, progress = false); result = [b["paths"][1], b["paths"][1].attrs["aux_level"]]')
case("na_prices_first", "dd <- dp[1:80, ]; dd$us[2] <- NA; dd$cpi[1] <- NA; b <- bootstrap(dd, bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', zins = 'zins'), input = 'prices'), 'stationary', params = list(L = 5), n = 1, seed = 3, progress = FALSE); list(b$paths[[1]], attr(b$paths[[1]], 'aux_level'))",
     "dd = dp.iloc[:80].copy(); dd.loc[1, 'us'] = simlev._r.fmt.NA_REAL; dd.loc[0, 'cpi'] = simlev._r.fmt.NA_REAL; b = bootstrap(dd, bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'zins': 'zins'}, input='prices'), 'stationary', params={'L': 5}, n=1, seed=3, progress=False); result = [b['paths'][0], b['paths'][0].attrs['aux_level']]", I,
     jl = 'dd = SL.rows(dp, 1:80); dd.us[2] = SL.NA; dd.cpi[1] = SL.NA; b = bootstrap(dd, bootstrap_config((us = "us",), aux = (cpi = "cpi", zins = "zins"), input = "prices"), "stationary"; params = (L = 5,), n = 1, seed = 3, progress = false); result = [b["paths"][1], b["paths"][1].attrs["aux_level"]]')
case("letf_knockout", "dd <- d[1:200, ]; dd$us[100] <- 0.7; b <- bootstrap(dd, bootstrap_config(c(us = 'us'), letfs = list(list(base = 'us', leverage = 4, finance = 1))), 'block', params = list(block_length = 199), n = 1, seed = 2, progress = FALSE); b$paths",
     "dd = d.iloc[:200].copy(); dd.loc[99, 'us'] = 0.7; b = bootstrap(dd, bootstrap_config({'us': 'us'}, letfs=[{'base': 'us', 'leverage': 4, 'finance': 1}]), 'block', params={'block_length': 199}, n=1, seed=2, progress=False); result = b['paths']", I,
     jl = 'dd = SL.rows(d, 1:200); dd.us[100] = 0.7; b = bootstrap(dd, bootstrap_config((us = "us",), letfs = [(base = "us", leverage = 4, finance = 1)]), "block"; params = (block_length = 199,), n = 1, seed = 2, progress = false); result = b["paths"]')

# ESS-Design
case("ess_grid", "b <- bootstrap(d, bootstrap_config(c(us = 'us')), 'stationary', n = 7, ess = TRUE, ess_grid = list(L = c(10, 100)), seed = 1, progress = FALSE, path_length = 30); list(b$weights, b$ess_design, b$param_values, b$paths, b$params, b$ess)",
     "b = bootstrap(d, bootstrap_config({'us': 'us'}), 'stationary', n=7, ess=True, ess_grid={'L': [10, 100]}, seed=1, progress=False, path_length=30); result = [b['weights'], b['ess_design'], b['param_values'], b['paths'], b['params'], b['ess']]", I,
     jl = 'b = bootstrap(d, bootstrap_config((us = "us",)), "stationary"; n = 7, ess = true, ess_grid = (L = [10, 100],), seed = 1, progress = false, path_length = 30); result = [b["weights"], b["ess_design"], b["param_values"], b["paths"], b["params"], b["ess"]]')
case("ess_default_block", "b <- bootstrap(d[1:60, ], bootstrap_config(c(us = 'us')), 'block', n = 9, ess = TRUE, seed = 2, progress = FALSE, path_length = 20); list(b$weights, b$ess_design, length(b$paths))",
     "b = bootstrap(d.iloc[:60], bootstrap_config({'us': 'us'}), 'block', n=9, ess=True, seed=2, progress=False, path_length=20); result = [b['weights'], b['ess_design'], len(b['paths'])]", I,
     jl = 'b = bootstrap(SL.rows(d, 1:60), bootstrap_config((us = "us",)), "block"; n = 9, ess = true, seed = 2, progress = false, path_length = 20); result = [b["weights"], b["ess_design"], length(b["paths"])]')
case("ess_wild_group", "b <- bootstrap(d, bootstrap_config(c(us = 'us')), 'wild', n = 5, ess = TRUE, seed = 3, progress = FALSE); list(b$weights, b$ess_design)",
     "b = bootstrap(d, bootstrap_config({'us': 'us'}), 'wild', n=5, ess=True, seed=3, progress=False); result = [b['weights'], b['ess_design']]", I,
     jl = 'b = bootstrap(d, bootstrap_config((us = "us",)), "wild"; n = 5, ess = true, seed = 3, progress = false); result = [b["weights"], b["ess_design"]]')
case("ess_mixed_group", "b <- bootstrap(d, bootstrap_config(c(us = 'us')), 'regime', n = 10, ess = TRUE, ess_grid = list(n_regimes = c(2, 3), vol_window = c(10, 20, 40)), seed = 3, progress = FALSE, path_length = 25); list(b$weights, b$ess_design, b$param_values)",
     "b = bootstrap(d, bootstrap_config({'us': 'us'}), 'regime', n=10, ess=True, ess_grid={'n_regimes': [2, 3], 'vol_window': [10, 20, 40]}, seed=3, progress=False, path_length=25); result = [b['weights'], b['ess_design'], b['param_values']]", I,
     jl = 'b = bootstrap(d, bootstrap_config((us = "us",)), "regime"; n = 10, ess = true, ess_grid = (n_regimes = [2, 3], vol_window = [10, 20, 40]), seed = 3, progress = false, path_length = 25); result = [b["weights"], b["ess_design"], b["param_values"]]')
case("ess_tails_print", "bootstrap(d, bootstrap_config(c(us = 'us')), 'tails', n = 8, ess = TRUE, seed = 5, progress = FALSE, path_length = 20)",
     "result = bootstrap(d, bootstrap_config({'us': 'us'}), 'tails', n=8, ess=True, seed=5, progress=False, path_length=20)", I,
     jl = 'result = bootstrap(d, bootstrap_config((us = "us",)), "tails"; n = 8, ess = true, seed = 5, progress = false, path_length = 20)')
case("ess_none", "b <- bootstrap(d, bootstrap_config(c(us = 'us')), 'raw', n = 2, ess = TRUE, seed = 1, progress = FALSE, path_length = 10); list(b$ess, b$ess_design, b$paths)",
     "b = bootstrap(d, bootstrap_config({'us': 'us'}), 'raw', n=2, ess=True, seed=1, progress=False, path_length=10); result = [b['ess'], b['ess_design'], b['paths']]", I,
     jl = 'b = bootstrap(d, bootstrap_config((us = "us",)), "raw"; n = 2, ess = true, seed = 1, progress = false, path_length = 10); result = [b["ess"], b["ess_design"], b["paths"]]')
case("ess_budget_trim", "b <- bootstrap(d, bootstrap_config(c(us = 'us')), 'stationary', n = 3, ess = TRUE, seed = 1, progress = FALSE, path_length = 10); b$ess_design",
     "result = bootstrap(d, bootstrap_config({'us': 'us'}), 'stationary', n=3, ess=True, seed=1, progress=False, path_length=10)['ess_design']", I,
     jl = 'result = bootstrap(d, bootstrap_config((us = "us",)), "stationary"; n = 3, ess = true, seed = 1, progress = false, path_length = 10)["ess_design"]')
case("ess_internal", "SimLev:::.ess_design('evt', list(), NULL, 50L, 1000L)", "result = B._ess_design('evt', {}, None, 50, 1000)",
     jl = 'result = B._ess_design("evt", (;), nothing, 50, 1000)')
case("ess_internal_ms", "SimLev:::.ess_design('ms_garch', list(), NULL, 20L, 1000L)", "result = B._ess_design('ms_garch', {}, None, 20, 1000)",
     jl = 'result = B._ess_design("ms_garch", (;), nothing, 20, 1000)')
case("ess_grid_short", "SimLev:::.get_ess_grid('circular', 12)", "result = B._get_ess_grid('circular', 12)",
     jl = 'result = B._get_ess_grid("circular", 12)')
case("calc_ess", "c(SimLev:::.calculate_ess(1000, 'regime', list(n_regimes = 3), list(trans = matrix(c(.9, .1, .2, .8), 2))), SimLev:::.calculate_ess(10, 'evt', list(tail_prob = 0.6)), SimLev:::.calculate_ess(100, 'tvtp_ms_garch', list()))",
     "result = [B._calculate_ess(1000, 'regime', {'n_regimes': 3}, {'trans': np.array([[.9, .2], [.1, .8]])}), B._calculate_ess(10, 'evt', {'tail_prob': 0.6}), B._calculate_ess(100, 'tvtp_ms_garch', {})]",
     jl = 'result = [B._calculate_ess(1000, "regime", (n_regimes = 3,), (trans = [.9 .2; .1 .8],)), B._calculate_ess(10, "evt", (tail_prob = 0.6,)), B._calculate_ess(100, "tvtp_ms_garch", (;))]')
case("base_params", "SimLev:::.get_base_params('raw', list(L = 3, foo = 1), 10)", "result = B._get_base_params('raw', {'L': 3, 'foo': 1}, 10)",
     jl = 'result = B._get_base_params("raw", (L = 3, foo = 1), 10)')

# Seeds und globaler Zufallszustand
case("seed_null", "set.seed(3); b <- bootstrap(d, bootstrap_config(c(us = 'us')), 'raw', n = 1, progress = FALSE, path_length = 5); list(b$seed, b$paths, runif(2))",
     "RNG.set_seed(3); b = bootstrap(d, bootstrap_config({'us': 'us'}), 'raw', n=1, progress=False, path_length=5); result = [b['seed'], b['paths'], RNG.runif(2)]", I,
     jl = 'RNG.set_seed(3); b = bootstrap(d, bootstrap_config((us = "us",)), "raw"; n = 1, progress = false, path_length = 5); result = [b["seed"], b["paths"], RNG.runif(2)]')
case("seed_keeps_state", "set.seed(99); invisible(bootstrap(d, bootstrap_config(c(us = 'us')), 'stationary', n = 2, seed = 1, progress = FALSE)); runif(3)",
     "RNG.set_seed(99); bootstrap(d, bootstrap_config({'us': 'us'}), 'stationary', n=2, seed=1, progress=False); result = RNG.runif(3)", I,
     jl = 'RNG.set_seed(99); bootstrap(d, bootstrap_config((us = "us",)), "stationary"; n = 2, seed = 1, progress = false); result = RNG.runif(3)')
case("seed_lecuyer_global", "set.seed(5, kind = \"L'Ecuyer-CMRG\"); b <- bootstrap(d, bootstrap_config(c(us = 'us')), 'raw', n = 1, seed = 2, progress = FALSE, path_length = 4); x <- c(runif(2), b$paths[[1]]); RNGkind('Mersenne-Twister'); x",
     "RNG.set_seed(5, kind=\"L'Ecuyer-CMRG\"); b = bootstrap(d, bootstrap_config({'us': 'us'}), 'raw', n=1, seed=2, progress=False, path_length=4); result = np.concatenate([RNG.runif(2), b['paths'][0].to_numpy().ravel()]); RNG.rng_kind('Mersenne-Twister')", I,
     jl = 'RNG.set_seed(5; kind = "L\'Ecuyer-CMRG"); b = bootstrap(d, bootstrap_config((us = "us",)), "raw"; n = 1, seed = 2, progress = false, path_length = 4); x = vcat(RNG.runif(2), vec(b["paths"][1].data)); RNG.rng_kind("Mersenne-Twister"); result = x')
case("streams", "SimLev:::.make_streams(7, 3)", "result = B._make_streams(7, 3)",
     jl = 'result = B._make_streams(7, 3)')
case("rng_restore", "set.seed(42); a <- SimLev:::.with_rng_restore(runif(2)); b <- runif(2); c1 <- SimLev:::.with_rng_restore(runif(1), seed = 1); c2 <- runif(1); e <- SimLev:::.with_rng_restore(runif(1), seed = NULL); f <- runif(1); list(a, b, c1, c2, e, f)",
     "RNG.set_seed(42); a = B._with_rng_restore(lambda: RNG.runif(2)); b = RNG.runif(2); c1 = B._with_rng_restore(lambda: RNG.runif(1), seed=1); c2 = RNG.runif(1); e = B._with_rng_restore(lambda: RNG.runif(1), seed=None); f = RNG.runif(1); result = [a, b, c1, c2, e, f]",
     jl = 'RNG.set_seed(42); a = B._with_rng_restore(() -> RNG.runif(2)); b = RNG.runif(2); c1 = B._with_rng_restore(() -> RNG.runif(1); seed = 1); c2 = RNG.runif(1); e = B._with_rng_restore(() -> RNG.runif(1); seed = nothing); f = RNG.runif(1); result = [a, b, c1, c2, e, f]')
case("par_lapply", "set.seed(1); a <- SimLev:::.par_lapply(1:3, function(i) runif(1), 2L); b <- runif(1); c1 <- SimLev:::.par_lapply(1:2, function(i) runif(1), 1L); list(a, b, c1)",
     "RNG.set_seed(1); a = B._par_lapply([1, 2, 3], lambda i: RNG.runif(1), 2); b = RNG.runif(1); c1 = B._par_lapply([1, 2], lambda i: RNG.runif(1), 1); result = [a, b, c1]",
     jl = 'RNG.set_seed(1); a = B._par_lapply(1:3, i -> RNG.runif(1), 2); b = RNG.runif(1); c1 = B._par_lapply(1:2, i -> RNG.runif(1), 1); result = [a, b, c1]')

# Fehler und Warnungen
E <- list(
  method = c("bootstrap(d, cfg, 'foo', n = 1)", "bootstrap(d, cfg, 'foo', n=1)",
    'bootstrap(d, cfg, "foo"; n = 1)'),
  n0 = c("bootstrap(d, cfg, n = 0)", "bootstrap(d, cfg, n=0)",
    'bootstrap(d, cfg; n = 0)'),
  nchr = c("bootstrap(d, cfg, n = 'a')", "bootstrap(d, cfg, n='a')",
    'bootstrap(d, cfg; n = "a")'),
  pl = c("bootstrap(d, cfg, n = 1, path_length = 2.5)", "bootstrap(d, cfg, n=1, path_length=2.5)",
    'bootstrap(d, cfg; n = 1, path_length = 2.5)'),
  pl0 = c("bootstrap(d, cfg, n = 1, path_length = 0)", "bootstrap(d, cfg, n=1, path_length=0)",
    'bootstrap(d, cfg; n = 1, path_length = 0)'),
  wildpl = c("bootstrap(d, cfg, 'wild', n = 1, path_length = 10)", "bootstrap(d, cfg, 'wild', n=1, path_length=10)",
    'bootstrap(d, cfg, "wild"; n = 1, path_length = 10)'),
  resetpl = c("bootstrap(d, cfg, 'reset', n = 1, path_length = 10)", "bootstrap(d, cfg, 'reset', n=1, path_length=10)",
    'bootstrap(d, cfg, "reset"; n = 1, path_length = 10)'),
  cfg = c("bootstrap(d, list(a = 1), n = 1)", "bootstrap(d, {'a': 1}, n=1)",
    'bootstrap(d, (a = 1,); n = 1)'),
  data = c("bootstrap(1:3, cfg, n = 1)", "bootstrap([1, 2, 3], cfg, n=1)",
    'bootstrap([1, 2, 3], cfg; n = 1)'),
  empty = c("bootstrap(d[0, ], cfg, n = 1)", "bootstrap(d.iloc[:0], cfg, n=1)",
    'bootstrap(SL.rows(d, Int[]), cfg; n = 1)'),
  col = c("bootstrap(d[, c('us', 'rate')], cfg, n = 1)", "bootstrap(d[['us', 'rate']], cfg, n=1)",
    'bootstrap(SL.RFrame("us" => d.us, "rate" => d.rate), cfg; n = 1)'),
  allna = c("dd <- d[1:5, ]; dd$us <- NA; bootstrap(dd, cfg, n = 1)", "dd = d.iloc[:5].copy(); dd['us'] = simlev._r.fmt.NA_REAL; bootstrap(dd, cfg, n=1)",
    '(dd = SL.rows(d, 1:5); dd.us .= SL.NA; bootstrap(dd, cfg; n = 1))'),
  inf = c("dd <- d[1:50, ]; dd$eu[c(7, 9)] <- Inf; dd$us[30] <- -Inf; bootstrap(dd, cfg, n = 1)", "dd = d.iloc[:50].copy(); dd.loc[[6, 8], 'eu'] = np.inf; dd.loc[29, 'us'] = -np.inf; bootstrap(dd, cfg, n=1)",
    '(dd = SL.rows(d, 1:50); dd.eu[[7, 9]] .= Inf; dd.us[30] = -Inf; bootstrap(dd, cfg; n = 1))'),
  neg = c("dd <- d[1:50, ]; dd$eu[7] <- -0.5; bootstrap(dd, cfg, n = 1)", "dd = d.iloc[:50].copy(); dd.loc[6, 'eu'] = -0.5; bootstrap(dd, cfg, n=1)",
    '(dd = SL.rows(d, 1:50); dd.eu[7] = -0.5; bootstrap(dd, cfg; n = 1))'),
  L = c("bootstrap(d, cfg, 'stationary', n = 1, params = list(L = 0.5))", "bootstrap(d, cfg, 'stationary', n=1, params={'L': 0.5})",
    'bootstrap(d, cfg, "stationary"; n = 1, params = (L = 0.5,))'),
  Lvec = c("bootstrap(d, cfg, 'stationary', n = 1, params = list(L = c(5, 10)))", "bootstrap(d, cfg, 'stationary', n=1, params={'L': [5, 10]})",
    'bootstrap(d, cfg, "stationary"; n = 1, params = (L = [5, 10],))'),
  bl = c("bootstrap(d, cfg, 'block', n = 1, params = list(block_length = 400))", "bootstrap(d, cfg, 'block', n=1, params={'block_length': 400})",
    'bootstrap(d, cfg, "block"; n = 1, params = (block_length = 400,))'),
  blc = c("bootstrap(d, cfg, 'circular', n = 1, params = list(block_length = 2.5))", "bootstrap(d, cfg, 'circular', n=1, params={'block_length': 2.5})",
    'bootstrap(d, cfg, "circular"; n = 1, params = (block_length = 2.5,))'),
  wt = c("bootstrap(d, cfg, 'wild', n = 1, params = list(wild_type = 3))", "bootstrap(d, cfg, 'wild', n=1, params={'wild_type': 3})",
    'bootstrap(d, cfg, "wild"; n = 1, params = (wild_type = 3,))'),
  pb = c("bootstrap(d, cfg, 'reset', n = 1, params = list(p_break = 1.5))", "bootstrap(d, cfg, 'reset', n=1, params={'p_break': 1.5})",
    'bootstrap(d, cfg, "reset"; n = 1, params = (p_break = 1.5,))'))
for (k in names(E)) case(paste0("bs_err_", k), paste0(CFG_R, E[[k]][1]), paste0(CFG_P, "result = ", E[[k]][2]), I, jl = paste0(CFG_J, "result = ", E[[k]][3]))
case("bs_warn_prices", "b <- bootstrap(dp, bootstrap_config(c(us = 'us')), 'raw', n = 1, seed = 1, progress = FALSE, path_length = 3); b$paths",
     "result = bootstrap(dp, bootstrap_config({'us': 'us'}), 'raw', n=1, seed=1, progress=False, path_length=3)['paths']", I,
     jl = 'result = bootstrap(dp, bootstrap_config((us = "us",)), "raw"; n = 1, seed = 1, progress = false, path_length = 3)["paths"]')
case("bs_matrix_data", "m <- as.matrix(d); b <- bootstrap(m, bootstrap_config(c(us = 'us'), aux = c(r = 'rate')), 'raw', n = 1, seed = 9, progress = FALSE, path_length = 6); b$paths",
     "result = bootstrap(d, bootstrap_config({'us': 'us'}, aux={'r': 'rate'}), 'raw', n=1, seed=9, progress=False, path_length=6)['paths']", I,
     jl = 'm = SL.NamedMat(hcat(d.us, d.eu, d.rate); colnames = ["us", "eu", "rate"]); result = bootstrap(m, bootstrap_config((us = "us",), aux = (r = "rate",)), "raw"; n = 1, seed = 9, progress = false, path_length = 6)["paths"]')
case("bs_n_fraction", "b <- bootstrap(d, bootstrap_config(c(us = 'us')), 'raw', n = 2.7, seed = 1, progress = FALSE, path_length = 3); list(length(b$paths), b$weights)",
     "b = bootstrap(d, bootstrap_config({'us': 'us'}), 'raw', n=2.7, seed=1, progress=False, path_length=3); result = [len(b['paths']), b['weights']]", I,
     jl = 'b = bootstrap(d, bootstrap_config((us = "us",)), "raw"; n = 2.7, seed = 1, progress = false, path_length = 3); result = [length(b["paths"]), b["weights"]]')

# Interne Bausteine
case("extract", paste0(CFG_R, "SimLev:::.extract_returns(d[1:30, ], cfg)"), paste0(CFG_P, "result = B._extract_returns(d.iloc[:30], cfg)"), I,
     jl = paste0(CFG_J, 'result = B._extract_returns(SL.rows(d, 1:30), cfg)'))
case("extract_prices", "SimLev:::.extract_returns(dp[1:30, ], bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', zins = 'zins'), input = 'prices'))",
     "result = B._extract_returns(dp.iloc[:30], bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'zins': 'zins'}, input='prices'))", I,
     jl = 'result = B._extract_returns(SL.rows(dp, 1:30), bootstrap_config((us = "us",), aux = (cpi = "cpi", zins = "zins"), input = "prices"))')
case("fit_garch", "SimLev:::.fit_garch11(d$us - 1)", "result = B._fit_garch11(d['us'].to_numpy() - 1)", I,
     jl = 'result = B._fit_garch11(d.us .- 1)')
case("fit_gjr", "SimLev:::.fit_garch11(d$eu - 1, gjr = TRUE)", "result = B._fit_garch11(d['eu'].to_numpy() - 1, gjr=True)", I,
     jl = 'result = B._fit_garch11(d.eu .- 1; gjr = true)')
case("fit_garch_short", "SimLev:::.fit_garch11(d$us[1:30] - 1)", "result = B._fit_garch11(d['us'].to_numpy()[:30] - 1)", I,
     jl = 'result = B._fit_garch11(d.us[1:30] .- 1)')
case("fit_tail", "list(SimLev:::.fit_tail(d$us, 0.05, 'left'), SimLev:::.fit_tail(d$us, 0.05, 'right'), SimLev:::.fit_tail(d$us[1:150], 0.05, 'left'), SimLev:::.fit_tail(d$us[1:60], 0.05, 'left'))",
     "result = [B._fit_tail(d['us'].to_numpy(), 0.05, 'left'), B._fit_tail(d['us'].to_numpy(), 0.05, 'right'), B._fit_tail(d['us'].to_numpy()[:150], 0.05, 'left'), B._fit_tail(d['us'].to_numpy()[:60], 0.05, 'left')]", I,
     jl = 'result = [B._fit_tail(d.us, 0.05, "left"), B._fit_tail(d.us, 0.05, "right"), B._fit_tail(d.us[1:150], 0.05, "left"), B._fit_tail(d.us[1:60], 0.05, "left")]')
case("fit_tail_heavy", "set.seed(8); x <- 1 + c(rnorm(380, 0, 0.01), -rexp(20, 10)); SimLev:::.fit_tail(x, 0.05, 'left')",
     "RNG.set_seed(8); x = 1 + np.concatenate([RNG.rnorm(380, 0, 0.01), -RNG.rexp(20, 10)]); result = B._fit_tail(x, 0.05, 'left')",
     jl = 'RNG.set_seed(8); x = 1 .+ vcat(RNG.rnorm(380, 0, 0.01), -RNG.rexp(20, 10)); result = B._fit_tail(x, 0.05, "left")')
case("regime_info", "SimLev:::.prepare_regime_info(d$us, 15, 3)", "result = B._prepare_regime_info(d['us'].to_numpy(), 15, 3)", I,
     jl = 'result = B._prepare_regime_info(d.us, 15, 3)')
case("letf_ret", "SimLev:::.letf_returns(d$us[1:10], list(leverage = -2, finance = 'r', days = 'tg', expense = 0.4, spread = 0.2, rate_basis = 360, ter_basis = 365), cbind(r = d$rate[1:10], tg = c(1, 3, 1, 1, 1, 3, 1, 1, 1, 2)))",
     "result = B._letf_returns(d['us'].to_numpy()[:10], {'leverage': -2, 'finance': 'r', 'days': 'tg', 'expense': 0.4, 'spread': 0.2, 'rate_basis': 360, 'ter_basis': 365}, np.column_stack([d['rate'].to_numpy()[:10], [1, 3, 1, 1, 1, 3, 1, 1, 1, 2]]), ['r', 'tg'])", I,
     jl = 'result = B._letf_returns(d.us[1:10], (leverage = -2, finance = "r", days = "tg", expense = 0.4, spread = 0.2, rate_basis = 360, ter_basis = 365), SL.NamedMat(hcat(d.rate[1:10], [1, 3, 1, 1, 1, 3, 1, 1, 1, 2.0]); colnames = ["r", "tg"]))')

# ── validate_bootstrap ─────────────────────────────────────────────────────
VB_R <- "b <- bootstrap(d, bootstrap_config(c(us = 'us')), 'stationary', n = 4, params = list(L = 20), seed = 1, progress = FALSE, path_length = 20)\n"
VB_P <- "b = bootstrap(d, bootstrap_config({'us': 'us'}), 'stationary', n=4, params={'L': 20}, seed=1, progress=False, path_length=20)\n"
VB_J <- 'b = bootstrap(d, bootstrap_config((us = "us",)), "stationary"; n = 4, params = (L = 20,), seed = 1, progress = false, path_length = 20)\n'
case("vb_na", paste0(VB_R, "b$paths[[2]][10, 1] <- NA; b$weights <- c(1, 2, 3, 4); validate_bootstrap(b)"),
     paste0(VB_P, "b['paths'][1].iloc[9, 0] = simlev._r.fmt.NA_REAL; b['weights'] = np.array([1., 2, 3, 4]); result = validate_bootstrap(b)"), I,
     jl = paste0(VB_J, 'b["paths"][2][10, 1] = SL.NA; b["weights"] = [1.0, 2, 3, 4]; result = validate_bootstrap(b)'))
case("vb_len", paste0(VB_R, "b$paths[[3]] <- b$paths[[3]][1:5, , drop = FALSE]; b$paths[[1]] <- b$paths[[1]][1:5, , drop = FALSE]; b$paths[[4]] <- b$paths[[4]][1:7, , drop = FALSE]; validate_bootstrap(b)$paths"),
     paste0(VB_P, "b['paths'][2] = b['paths'][2].iloc[:5]; b['paths'][0] = b['paths'][0].iloc[:5]; b['paths'][3] = b['paths'][3].iloc[:7]; result = validate_bootstrap(b)['paths']"), I,
     jl = paste0(VB_J, 'b["paths"][3] = b["paths"][3][1:5, :]; b["paths"][1] = b["paths"][1][1:5, :]; b["paths"][4] = b["paths"][4][1:7, :]; result = validate_bootstrap(b)["paths"]'))
case("vb_tie", paste0(VB_R, "b$paths[[1]] <- b$paths[[1]][1:5, , drop = FALSE]; b$paths[[3]] <- b$paths[[3]][1:5, , drop = FALSE]; x <- validate_bootstrap(b, verbose = FALSE); list(x$paths, x$weights)"),
     paste0(VB_P, "b['paths'][0] = b['paths'][0].iloc[:5]; b['paths'][2] = b['paths'][2].iloc[:5]; x = validate_bootstrap(b, verbose=False); result = [x['paths'], x['weights']]"), I,
     jl = paste0(VB_J, 'b["paths"][1] = b["paths"][1][1:5, :]; b["paths"][3] = b["paths"][3][1:5, :]; x = validate_bootstrap(b; verbose = false); result = [x["paths"], x["weights"]]'))
case("vb_minrows", paste0(VB_R, "validate_bootstrap(b, min_rows = 30)"), paste0(VB_P, "result = validate_bootstrap(b, min_rows=30)"), I,
     jl = paste0(VB_J, 'result = validate_bootstrap(b; min_rows = 30)'))
case("vb_ok", paste0(VB_R, "validate_bootstrap(b)"), paste0(VB_P, "result = validate_bootstrap(b)"), I,
     jl = paste0(VB_J, 'result = validate_bootstrap(b)'))
case("vb_inf", paste0(VB_R, "b$paths[[4]][2, 1] <- Inf; validate_bootstrap(b)$weights"), paste0(VB_P, "b['paths'][3].iloc[1, 0] = np.inf; result = validate_bootstrap(b)['weights']"), I,
     jl = paste0(VB_J, 'b["paths"][4][2, 1] = Inf; result = validate_bootstrap(b)["weights"]'))
case("vb_err_class", "validate_bootstrap(list(paths = list()))", "result = validate_bootstrap({'paths': []})",
     jl = 'result = validate_bootstrap((paths = [],))')
case("vb_err_empty", paste0(VB_R, "b$paths <- list(); validate_bootstrap(b)"), paste0(VB_P, "b['paths'] = []; result = validate_bootstrap(b)"), I,
     jl = paste0(VB_J, 'b["paths"] = []; result = validate_bootstrap(b)'))
case("vb_ess", "b <- bootstrap(d, bootstrap_config(c(us = 'us')), 'stationary', n = 5, ess = TRUE, ess_grid = list(L = c(5, 50)), seed = 1, progress = FALSE, path_length = 10); b$paths[[2]][3, 1] <- NaN; x <- validate_bootstrap(b, verbose = FALSE); list(x$weights, x$param_values)",
     "b = bootstrap(d, bootstrap_config({'us': 'us'}), 'stationary', n=5, ess=True, ess_grid={'L': [5, 50]}, seed=1, progress=False, path_length=10); b['paths'][1].iloc[2, 0] = np.nan; x = validate_bootstrap(b, verbose=False); result = [x['weights'], x['param_values']]", I,
     jl = 'b = bootstrap(d, bootstrap_config((us = "us",)), "stationary"; n = 5, ess = true, ess_grid = (L = [5, 50],), seed = 1, progress = false, path_length = 10); b["paths"][2][3, 1] = NaN; x = validate_bootstrap(b; verbose = false); result = [x["weights"], x["param_values"]]')

# ── bootstrap_data ─────────────────────────────────────────────────────────
BD_R <- paste0(CFG_R, "b <- bootstrap(d, cfg, 'stationary', n = 2, params = list(L = 20), seed = 1, progress = FALSE, path_length = 8)\n")
BD_P <- paste0(CFG_P, "b = bootstrap(d, cfg, 'stationary', n=2, params={'L': 20}, seed=1, progress=False, path_length=8)\n")
BD_J <- paste0(CFG_J, 'b = bootstrap(d, cfg, "stationary"; n = 2, params = (L = 20,), seed = 1, progress = false, path_length = 8)\n')
case("bd_default", paste0(BD_R, "bootstrap_data(b, 2)"), paste0(BD_P, "result = bootstrap_data(b, 2)"), I,
     jl = paste0(BD_J, 'result = bootstrap_data(b, 2)'))
case("bd_start", paste0(BD_R, "bootstrap_data(b, start_date = '2030-02-27')"), paste0(BD_P, "result = bootstrap_data(b, start_date='2030-02-27')"), I,
     jl = paste0(BD_J, 'result = bootstrap_data(b; start_date = "2030-02-27")'))
case("bd_dates", paste0(BD_R, "bootstrap_data(b, 1, dates = as.Date('2001-01-01') + c(0, 1, 2, 5, 6, 7, 8, 9, 12))"),
     paste0(BD_P, "result = bootstrap_data(b, 1, dates=np.datetime64('2001-01-01') + np.array([0, 1, 2, 5, 6, 7, 8, 9, 12])) "), I,
     jl = paste0(BD_J, 'result = bootstrap_data(b, 1; dates = Date(2001, 1, 1) .+ Day.([0, 1, 2, 5, 6, 7, 8, 9, 12]))'))
case("bd_dates_chr", paste0(BD_R, "bootstrap_data(b$paths[[1]][1:3, ], dates = c('2020-01-01', '2020-01-02', '2020-01-05'))"),
     paste0(BD_P, "result = bootstrap_data(b['paths'][0].iloc[:3], dates=['2020-01-01', '2020-01-02', '2020-01-05'])"), I,
     jl = paste0(BD_J, 'result = bootstrap_data(b["paths"][1][1:3, :]; dates = ["2020-01-01", "2020-01-02", "2020-01-05"])'))
case("bd_err_len", paste0(BD_R, "bootstrap_data(b, dates = as.Date('2001-01-01') + 0:3)"), paste0(BD_P, "result = bootstrap_data(b, dates=np.datetime64('2001-01-01') + np.arange(4))"), I,
     jl = paste0(BD_J, 'result = bootstrap_data(b; dates = Date(2001, 1, 1) .+ Day.(0:3))'))
case("bd_err_matrix", "bootstrap_data(matrix(1:4, 2, dimnames = list(NULL, c('a', 'b'))))", "result = bootstrap_data(np.array([[1., 3], [2, 4]]))",
     jl = 'result = bootstrap_data(SL.NamedMat([1.0 3; 2 4]; colnames = ["a", "b"]))')
case("bd_attr", "b <- bootstrap(dp, bootstrap_config(c(us = 'us'), aux = c(infl = 'infl', cpi = 'cpi', zins = 'zins'), input = 'prices', aux_type = c(infl = 'rate', cpi = 'level')), 'raw', n = 1, seed = 1, progress = FALSE, path_length = 4); x <- bootstrap_data(b, 1); list(x, attr(x, 'aux_type'))",
     "b = bootstrap(dp, bootstrap_config({'us': 'us'}, aux={'infl': 'infl', 'cpi': 'cpi', 'zins': 'zins'}, input='prices', aux_type={'infl': 'rate', 'cpi': 'level'}), 'raw', n=1, seed=1, progress=False, path_length=4); x = bootstrap_data(b, 1); result = [x, x.attrs.get('aux_type')]", I,
     jl = 'b = bootstrap(dp, bootstrap_config((us = "us",), aux = (infl = "infl", cpi = "cpi", zins = "zins"), input = "prices", aux_type = (infl = "rate", cpi = "level")), "raw"; n = 1, seed = 1, progress = false, path_length = 4); x = bootstrap_data(b, 1); result = [x, get(SL.attrs(x), "aux_type", nothing)]')
case("bd_noattr", "b <- bootstrap(dp, bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi'), input = 'prices', aux_type = c(cpi = 'level')), 'raw', n = 1, seed = 1, progress = FALSE, path_length = 4); x <- bootstrap_data(b, 1); list(x, attr(x, 'aux_type'))",
     "b = bootstrap(dp, bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi'}, input='prices', aux_type={'cpi': 'level'}), 'raw', n=1, seed=1, progress=False, path_length=4); x = bootstrap_data(b, 1); result = [x, x.attrs.get('aux_type')]", I,
     jl = 'b = bootstrap(dp, bootstrap_config((us = "us",), aux = (cpi = "cpi",), input = "prices", aux_type = (cpi = "level",)), "raw"; n = 1, seed = 1, progress = false, path_length = 4); x = bootstrap_data(b, 1); result = [x, get(SL.attrs(x), "aux_type", nothing)]')

# ── wquantile ──────────────────────────────────────────────────────────────
set.seed(5); wx <- rnorm(40); ww <- runif(40)
Iw <- list(wx = wx, ww = ww)
case("wq_equal", "SimLev:::.wquantile(wx, rep(2, 40), c(0, 0.05, 0.5, 0.95, 1))", "result = B._wquantile(wx, np.full(40, 2.0), [0, 0.05, 0.5, 0.95, 1])", Iw,
     jl = 'result = B._wquantile(wx, fill(2.0, 40), [0, 0.05, 0.5, 0.95, 1])')
case("wq_weights", "SimLev:::.wquantile(wx, ww, c(0, 0.05, 0.25, 0.5, 0.75, 0.95, 1))", "result = B._wquantile(wx, ww, [0, 0.05, 0.25, 0.5, 0.75, 0.95, 1])", Iw,
     jl = 'result = B._wquantile(wx, ww, [0, 0.05, 0.25, 0.5, 0.75, 0.95, 1])')
case("wq_nearly", "SimLev:::.wquantile(c(1, 2, 3, 4), c(1, 1, 1, 1 + 1e-12), c(0.5, 0.05))", "result = B._wquantile([1, 2, 3, 4], [1, 1, 1, 1 + 1e-12], [0.5, 0.05])",
     jl = 'result = B._wquantile([1, 2, 3, 4], [1, 1, 1, 1 + 1e-12], [0.5, 0.05])')
case("wq_zero", "list(SimLev:::.wquantile(c(1, 2, 3, 4), c(1, 0, 1, 1), c(0, 0.5, 1)), SimLev:::.wquantile(c(1, NA, 3, Inf, 2), c(1, 2, NA, 1, 3), 0.5), SimLev:::.wquantile(c(NA, NA), c(1, 1), c(.1, .2)), SimLev:::.wquantile(c(1, 2), c(0, 0), 0.5), SimLev:::.wquantile(c(3, 1, 3, 2), c(1, 3, 1, 3), 0.5))",
     "result = [B._wquantile([1, 2, 3, 4], [1, 0, 1, 1], [0, 0.5, 1]), B._wquantile([1, simlev._r.fmt.NA_REAL, 3, np.inf, 2], [1, 2, simlev._r.fmt.NA_REAL, 1, 3], 0.5), B._wquantile([simlev._r.fmt.NA_REAL, simlev._r.fmt.NA_REAL], [1, 1], [.1, .2]), B._wquantile([1, 2], [0, 0], 0.5), B._wquantile([3, 1, 3, 2], [1, 3, 1, 3], 0.5)]",
     jl = 'result = [B._wquantile([1, 2, 3, 4], [1, 0, 1, 1], [0, 0.5, 1]), B._wquantile([1, SL.NA, 3, Inf, 2], [1, 2, SL.NA, 1, 3], 0.5), B._wquantile([SL.NA, SL.NA], [1, 1], [.1, .2]), B._wquantile([1, 2], [0, 0], 0.5), B._wquantile([3, 1, 3, 2], [1, 3, 1, 3], 0.5)]')

# ── simulation-basierte Teile: study_metrics, bootstrap_study, probability ──
set.seed(1); ns <- 2 * 365
ds <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = ns))
ds$aktien <- 100 * cumprod(1 + rnorm(ns, 3e-4, 0.01)); ds$zins <- 2
Is <- c(I, list(ds = ds))
case("sm_basic", "res <- simulation(ds, create_strategy(aktien = asset_config('etf', 'bnh'))); study_metrics(res)",
     "res = simlev.simulation(ds, simlev.create_strategy(aktien=simlev.asset_config('etf', 'bnh'))); result = study_metrics(res)", Is,
     jl = 'res = simulation(ds, create_strategy(aktien = asset_config("etf", "bnh"))); result = study_metrics(res)')
case("sm_tax", "res <- simulation(ds, create_strategy(aktien = asset_config('etf', 'bnh', asset_bonus = 30)), tax_mode = 'person', start_value = 1e5); study_metrics(res)",
     "res = simlev.simulation(ds, simlev.create_strategy(aktien=simlev.asset_config('etf', 'bnh', asset_bonus=30)), tax_mode='person', start_value=1e5); result = study_metrics(res)", Is,
     jl = 'res = simulation(ds, create_strategy(aktien = asset_config("etf", "bnh", asset_bonus = 30)); tax_mode = "person", start_value = 1e5); result = study_metrics(res)')
STR_R <- "cfgs <- bootstrap_config(c(akt = 'aktien'), aux = c(zins = 'zins'), input = 'prices', letfs = list(list(base = 'akt', leverage = 2, finance = 'zins', expense = 0.6)))
sma <- function(df, k = 30) { s <- stats::filter(df$akt_l2, rep(1 / k, k), sides = 1); list(buy = df$akt_l2 >= s, sell = df$akt_l2 < s) }
strats <- list(bnh = create_strategy(akt_l2 = asset_config('etf', 'bnh', asset_bonus = 30)),
  sma = list(strategy = create_strategy(letf = asset_config('etf', 'signal', asset_bonus = 30, signal_buy = 'buy', signal_sell = 'sell')), signal = sma, map = c(letf = 'akt_l2')))\n"
STR_P <- "cfgs = bootstrap_config({'akt': 'aktien'}, aux={'zins': 'zins'}, input='prices', letfs=[{'base': 'akt', 'leverage': 2, 'finance': 'zins', 'expense': 0.6}])
def _filt(x, k):
    x = np.asarray(x, dtype=float); f = 1.0 / k; out = np.full(len(x), simlev._r.fmt.NA_REAL)
    for i in range(k - 1, len(x)):
        z = 0.0
        for j in range(k):
            z += f * x[i - j]
        out[i] = z
    return out
def sma(df, k=30):
    s = _filt(df['akt_l2'], k); v = df['akt_l2'].to_numpy()
    with np.errstate(invalid='ignore'):
        return {'buy': v >= s, 'sell': v < s}
strats = {'bnh': simlev.create_strategy(akt_l2=simlev.asset_config('etf', 'bnh', asset_bonus=30)),
  'sma': {'strategy': simlev.create_strategy(letf=simlev.asset_config('etf', 'signal', asset_bonus=30, signal_buy='buy', signal_sell='sell')), 'signal': sma, 'map': {'letf': 'akt_l2'}}}\n"
STR_J <- 'cfgs = bootstrap_config((akt = "aktien",), aux = (zins = "zins",), input = "prices", letfs = [(base = "akt", leverage = 2, finance = "zins", expense = 0.6)])
function sma(df; k = 30)
    x = df["akt_l2"]; s = fill(SL.NA, length(x))
    for i in k:length(x)
        z = 0.0
        for j in 0:k-1
            z += (1 / k) * x[i - j]
        end
        s[i] = z
    end
    (buy = x .>= s, sell = x .< s)
end
strats = (bnh = create_strategy(akt_l2 = asset_config("etf", "bnh", asset_bonus = 30)),
  sma = (strategy = create_strategy(letf = asset_config("etf", "signal", asset_bonus = 30, signal_buy = "buy", signal_sell = "sell")), signal = sma, map = (letf = "akt_l2",)))
'
case("study_basic", paste0(STR_R, "st <- bootstrap_study(ds, cfgs, 'stationary', n = 3, params = list(L = 30), path_length = 400, burn_in = 35, seed = 1, progress = FALSE, benchmark = 'bnh', strategies = strats, chunk_size = 2); st$elapsed <- 0; st"),
     paste0(STR_P, "st = bootstrap_study(ds, cfgs, 'stationary', n=3, params={'L': 30}, path_length=400, burn_in=35, seed=1, progress=False, benchmark='bnh', strategies=strats, chunk_size=2); st['elapsed'] = 0; result = st"), Is,
     jl = paste0(STR_J, 'st = bootstrap_study(ds, cfgs, "stationary"; n = 3, params = (L = 30,), path_length = 400, burn_in = 35, seed = 1, progress = false, benchmark = "bnh", strategies = strats, chunk_size = 2); st["elapsed"] = 0; result = st'))
case("study_returns", paste0(STR_R, "st <- bootstrap_study(ds, cfgs, 'block', n = 2, params = list(block_length = 40), path_length = 800, burn_in = 10, seed = 2, progress = FALSE, strategies = strats, keep_returns = 'quarter', keep_aux = 'zins', keep_paths = 1, cores = 2); st$elapsed <- 0; st"),
     paste0(STR_P, "st = bootstrap_study(ds, cfgs, 'block', n=2, params={'block_length': 40}, path_length=800, burn_in=10, seed=2, progress=False, strategies=strats, keep_returns='quarter', keep_aux='zins', keep_paths=1, cores=2); st['elapsed'] = 0; result = st"), Is,
     jl = paste0(STR_J, 'st = bootstrap_study(ds, cfgs, "block"; n = 2, params = (block_length = 40,), path_length = 800, burn_in = 10, seed = 2, progress = false, strategies = strats, keep_returns = "quarter", keep_aux = "zins", keep_paths = 1, cores = 2); st["elapsed"] = 0; result = st'))
case("study_summary", paste0(STR_R, "st <- bootstrap_study(ds, cfgs, 'raw', n = 4, path_length = 300, seed = 3, progress = FALSE, benchmark = 'bnh', strategies = strats); summary(st, metrics = c('cagr', 'max_drawdown', 'dd_q50', 'final_value', 'taxes', 'trades', 'foo'), probs = c(0.1, 0.5))"),
     paste0(STR_P, "st = bootstrap_study(ds, cfgs, 'raw', n=4, path_length=300, seed=3, progress=False, benchmark='bnh', strategies=strats); result = summary(st, metrics=['cagr', 'max_drawdown', 'dd_q50', 'final_value', 'taxes', 'trades', 'foo'], probs=[0.1, 0.5])"), Is,
     jl = paste0(STR_J, 'st = bootstrap_study(ds, cfgs, "raw"; n = 4, path_length = 300, seed = 3, progress = false, benchmark = "bnh", strategies = strats); result = r_summary(st; metrics = ["cagr", "max_drawdown", "dd_q50", "final_value", "taxes", "trades", "foo"], probs = [0.1, 0.5])'))
case("study_prob", paste0(STR_R, "st <- bootstrap_study(ds, cfgs, 'raw', n = 4, path_length = 300, seed = 3, progress = FALSE, strategies = strats); thr <- 0.0; bootstrap_probability(st, cagr > thr, joint = cagr > 0 & max_drawdown <= 0.3, thresholds = list(sma = list(ziel = quote(cagr > 0.1), x = quote(sharpe > 0 | path == 2))))"),
     paste0(STR_P, "st = bootstrap_study(ds, cfgs, 'raw', n=4, path_length=300, seed=3, progress=False, strategies=strats); thr = 0.0; result = bootstrap_probability(st, 'cagr > thr', joint='cagr > 0 & max_drawdown <= 0.3', thresholds={'sma': {'ziel': 'cagr > 0.1', 'x': 'sharpe > 0 | path == 2'}})"), Is,
     jl = paste0(STR_J, 'st = bootstrap_study(ds, cfgs, "raw"; n = 4, path_length = 300, seed = 3, progress = false, strategies = strats); thr = 0.0; result = bootstrap_probability(st, "cagr > thr"; joint = "cagr > 0 & max_drawdown <= 0.3", thresholds = (sma = (ziel = "cagr > 0.1", x = "sharpe > 0 | path == 2"),), env = @__MODULE__)'))
case("study_ess", "st <- bootstrap_study(ds, bootstrap_config(c(akt = 'aktien'), input = 'prices'), 'stationary', n = 4, ess = TRUE, ess_grid = list(L = c(10, 50)), path_length = 200, seed = 4, progress = FALSE, strategies = list(a = create_strategy(akt = asset_config('etf', 'bnh')))); st$elapsed <- 0; list(st, summary(st), bootstrap_probability(st, cagr > 0))",
     "st = bootstrap_study(ds, bootstrap_config({'akt': 'aktien'}, input='prices'), 'stationary', n=4, ess=True, ess_grid={'L': [10, 50]}, path_length=200, seed=4, progress=False, strategies={'a': simlev.create_strategy(akt=simlev.asset_config('etf', 'bnh'))}); st['elapsed'] = 0; result = [st, summary(st), bootstrap_probability(st, 'cagr > 0')]", Is,
     jl = 'st = bootstrap_study(ds, bootstrap_config((akt = "aktien",), input = "prices"), "stationary"; n = 4, ess = true, ess_grid = (L = [10, 50],), path_length = 200, seed = 4, progress = false, strategies = (a = create_strategy(akt = asset_config("etf", "bnh")),)); st["elapsed"] = 0; result = [st, r_summary(st), bootstrap_probability(st, "cagr > 0")]')
case("study_auxlevel", "cfg <- bootstrap_config(c(akt = 'aktien'), aux = c(zins = 'zins', z2 = 'zins'), input = 'prices', aux_type = c(z2 = 'rate')); st <- bootstrap_study(ds, cfg, 'stationary', n = 2, params = list(L = 50), path_length = 730, seed = 5, progress = FALSE, keep_returns = 'year', keep_aux = c('zins', 'z2'), dates = seq.Date(as.Date('2003-03-31'), by = 'day', length.out = 731), strategies = list(a = create_strategy(akt = asset_config('etf', 'bnh')))); list(st$returns, st$aux_returns, st$returns_dates, st$returns_frequency)",
     "cfg = bootstrap_config({'akt': 'aktien'}, aux={'zins': 'zins', 'z2': 'zins'}, input='prices', aux_type={'z2': 'rate'}); st = bootstrap_study(ds, cfg, 'stationary', n=2, params={'L': 50}, path_length=730, seed=5, progress=False, keep_returns='year', keep_aux=['zins', 'z2'], dates=np.datetime64('2003-03-31') + np.arange(731), strategies={'a': simlev.create_strategy(akt=simlev.asset_config('etf', 'bnh'))}); result = [st['returns'], st['aux_returns'], st['returns_dates'], st['returns_frequency']]", Is,
     jl = 'cfg = bootstrap_config((akt = "aktien",), aux = (zins = "zins", z2 = "zins"), input = "prices", aux_type = (z2 = "rate",)); st = bootstrap_study(ds, cfg, "stationary"; n = 2, params = (L = 50,), path_length = 730, seed = 5, progress = false, keep_returns = "year", keep_aux = ["zins", "z2"], dates = Date(2003, 3, 31) .+ Day.(0:730), strategies = (a = create_strategy(akt = asset_config("etf", "bnh")),)); result = [st["returns"], st["aux_returns"], st["returns_dates"], st["returns_frequency"]]')
case("study_errfail", "bootstrap_study(ds, bootstrap_config(c(akt = 'aktien'), input = 'prices'), 'raw', n = 2, path_length = 100, seed = 1, progress = FALSE, strategies = list(sig = list(strategy = create_strategy(akt = asset_config('etf', 'signal', signal_buy = 'b', signal_sell = 's')), signal = function(df) stop('Spalte fehlt'))))",
     "def bad(df):\n    raise ValueError('Spalte fehlt')\nresult = bootstrap_study(ds, bootstrap_config({'akt': 'aktien'}, input='prices'), 'raw', n=2, path_length=100, seed=1, progress=False, strategies={'sig': {'strategy': simlev.create_strategy(akt=simlev.asset_config('etf', 'signal', signal_buy='b', signal_sell='s')), 'signal': bad}})", Is,
     jl = 'bad(df) = error("Spalte fehlt"); result = bootstrap_study(ds, bootstrap_config((akt = "aktien",), input = "prices"), "raw"; n = 2, path_length = 100, seed = 1, progress = false, strategies = (sig = (strategy = create_strategy(akt = asset_config("etf", "signal", signal_buy = "b", signal_sell = "s")), signal = bad),))')
case("study_partial", "st <- bootstrap_study(ds, bootstrap_config(c(akt = 'aktien'), input = 'prices'), 'raw', n = 2, path_length = 100, seed = 1, progress = FALSE, strategies = list(ok = create_strategy(akt = asset_config('etf', 'bnh')), kaputt = list(strategy = create_strategy(akt = asset_config('etf', 'bnh')), signal = function(df) NULL), w = list(strategy = create_strategy(akt = asset_config('etf', 'bnh')), signal = function(df) { warning('Achtung'); warning('Achtung'); list(x = df$akt > 100) }))); st$elapsed <- 0; list(st$results, st$errors, st$warnings)",
     "def wsig(df):\n    import warnings as _w\n    _w.warn('Achtung'); _w.warn('Achtung')\n    return {'x': df['akt'].to_numpy() > 100}\nst = bootstrap_study(ds, bootstrap_config({'akt': 'aktien'}, input='prices'), 'raw', n=2, path_length=100, seed=1, progress=False, strategies={'ok': simlev.create_strategy(akt=simlev.asset_config('etf', 'bnh')), 'kaputt': {'strategy': simlev.create_strategy(akt=simlev.asset_config('etf', 'bnh')), 'signal': lambda df: None}, 'w': {'strategy': simlev.create_strategy(akt=simlev.asset_config('etf', 'bnh')), 'signal': wsig}}); result = [st['results'], st['errors'], st['warnings']]", Is,
     jl = 'function wsig(df)
    @warn "Achtung"; @warn "Achtung"
    (x = df["akt"] .> 100,)
end
st = bootstrap_study(ds, bootstrap_config((akt = "aktien",), input = "prices"), "raw"; n = 2, path_length = 100, seed = 1, progress = false, strategies = (ok = create_strategy(akt = asset_config("etf", "bnh")), kaputt = (strategy = create_strategy(akt = asset_config("etf", "bnh")), signal = df -> nothing), w = (strategy = create_strategy(akt = asset_config("etf", "bnh")), signal = wsig))); result = [st["results"], st["errors"], st["warnings"]]')
case("study_unused", "bootstrap_study(ds, bootstrap_config(c(akt = 'aktien'), input = 'prices'), 'raw', n = 2, path_length = 100, seed = 1, progress = FALSE, sim_args = list(taxmode = 'person'), strategies = list(bnh = create_strategy(akt = asset_config('etf', 'bnh'))))",
     "result = bootstrap_study(ds, bootstrap_config({'akt': 'aktien'}, input='prices'), 'raw', n=2, path_length=100, seed=1, progress=False, sim_args={'taxmode': 'person'}, strategies={'bnh': simlev.create_strategy(akt=simlev.asset_config('etf', 'bnh'))})", Is,
     jl = 'result = bootstrap_study(ds, bootstrap_config((akt = "aktien",), input = "prices"), "raw"; n = 2, path_length = 100, seed = 1, progress = false, sim_args = (taxmode = "person",), strategies = (bnh = create_strategy(akt = asset_config("etf", "bnh")),))')
SE <- list(
  nostrat = c("bootstrap_study(ds, cfgs, n = 2)", "bootstrap_study(ds, cfgs, n=2)",
    'bootstrap_study(ds, cfgs; n = 2)'),
  unnamed = c("bootstrap_study(ds, cfgs, n = 2, strategies = list(strats$bnh))", "bootstrap_study(ds, cfgs, n=2, strategies=[strats['bnh']])",
    'bootstrap_study(ds, cfgs; n = 2, strategies = [strats.bnh])'),
  bench = c("bootstrap_study(ds, cfgs, n = 2, strategies = strats, benchmark = 'x')", "bootstrap_study(ds, cfgs, n=2, strategies=strats, benchmark='x')",
    'bootstrap_study(ds, cfgs; n = 2, strategies = strats, benchmark = "x")'),
  keepaux = c("bootstrap_study(ds, cfgs, n = 2, strategies = strats, keep_aux = 'cpi')", "bootstrap_study(ds, cfgs, n=2, strategies=strats, keep_aux='cpi')",
    'bootstrap_study(ds, cfgs; n = 2, strategies = strats, keep_aux = "cpi")'),
  burnin = c("bootstrap_study(ds, cfgs, n = 2, strategies = strats, path_length = 50, burn_in = 50)", "bootstrap_study(ds, cfgs, n=2, strategies=strats, path_length=50, burn_in=50)",
    'bootstrap_study(ds, cfgs; n = 2, strategies = strats, path_length = 50, burn_in = 50)'),
  dates = c("bootstrap_study(ds, cfgs, n = 2, strategies = strats, path_length = 50, dates = as.Date('2001-01-01') + 0:10)", "bootstrap_study(ds, cfgs, n=2, strategies=strats, path_length=50, dates=np.datetime64('2001-01-01') + np.arange(11))",
    'bootstrap_study(ds, cfgs; n = 2, strategies = strats, path_length = 50, dates = Date(2001, 1, 1) .+ Day.(0:10))'),
  short = c("bootstrap_study(ds, cfgs, n = 2, strategies = strats, path_length = 300, keep_returns = 'year')", "bootstrap_study(ds, cfgs, n=2, strategies=strats, path_length=300, keep_returns='year')",
    'bootstrap_study(ds, cfgs; n = 2, strategies = strats, path_length = 300, keep_returns = "year")'),
  kr = c("bootstrap_study(ds, cfgs, n = 2, strategies = strats, keep_returns = 'week')", "bootstrap_study(ds, cfgs, n=2, strategies=strats, keep_returns='week')",
    'bootstrap_study(ds, cfgs; n = 2, strategies = strats, keep_returns = "week")'))
for (k in names(SE)) case(paste0("study_err_", k), paste0(STR_R, SE[[k]][1]), paste0(STR_P, "result = ", SE[[k]][2]), Is, jl = paste0(STR_J, "result = ", SE[[k]][3]))
case("prob_err", "bootstrap_probability(list(), cagr > 0)", "result = bootstrap_probability({}, 'cagr > 0')",
     jl = 'result = bootstrap_probability((;), "cagr > 0")')

# bootstrap_probability: Bedingungen in R-Syntax (gemeinsamer Auswerter, Modul rexpr) auf einer festen Ergebnistabelle
set.seed(11)
PT <- data.frame(strategy = rep(c("a", "b"), each = 6), path = rep(1:6, 2), weight = c(rep(1, 6), 0.5, 1, 1.5, 2, 1, 1),
                 cagr = c(round(rnorm(11, 0.05, 0.08), 4), NA), max_drawdown = round(runif(12, 0.05, 0.6), 3),
                 sharpe = round(rnorm(12, 0.4, 0.5), 3))
PB_R <- "st <- structure(list(results = PT), class = 'SimLevBootstrapStudy'); thr <- 0.02; f2 <- function(x) x > 0.3\n"
PB_P <- "st = B.SimLevBootstrapStudy(results=PT); thr = 0.02\ndef f2(x):\n    return x > 0.3\n"
PB_J <- 'st = SL.RList(; class = ["SimLevBootstrapStudy"]); st["results"] = PT; thr = 0.02; f2(x) = x .> 0.3\n'
PBC <- list(a1 = "!cagr < 0", a2 = "cagr > 0 & !is.na(sharpe) | path %in% c(1, 2)", a3 = "path %% 2 == 0",
            a4 = "cagr > quantile(cagr, 0.5, na.rm = TRUE)", a5 = "if (mean(cagr, na.rm = TRUE) > 0) sharpe > 0 else max_drawdown < 0.3",
            a6 = "cagr >= median(cagr, na.rm = TRUE) - sd(cagr, na.rm = TRUE)", a7 = "max_drawdown <= max(max_drawdown) / 2",
            a8 = "f2(sharpe)", a9 = "cagr[path] > 0 & path >= 2L", b1 = "TRUE", b2 = "mean(cagr, na.rm = TRUE) > 0", b3 = "NA",
            b4 = "c(TRUE, FALSE)", b5 = "rep(c(TRUE, NA), 4)", b6 = "\"TRUE\"", b7 = "sharpe > 0.2 |\n cagr < 0", b8 = "max_drawdown > 0.3 # Kommentar\n")
pbq <- function(x) paste0("'", gsub("\n", "\\n", gsub("'", "\\'", x, fixed = TRUE), fixed = TRUE), "'")
pbj <- function(x) paste0('"', gsub("$", "\\$", gsub("\n", "\\n", gsub('"', '\\"', x, fixed = TRUE), fixed = TRUE), fixed = TRUE), '"')
pb_case <- function(id, conds, thresholds = NULL) {
  nm <- names(conds); if (is.null(nm)) nm <- rep("", length(conds)); nm[is.na(nm)] <- ""
  r_args <- paste(ifelse(nm == "", conds, paste(nm, "=", conds)), collapse = ", ")
  p_args <- paste(c(vapply(conds[nm == ""], pbq, ""), if (any(nm != "")) paste0(nm[nm != ""], "=", vapply(conds[nm != ""], pbq, ""))), collapse = ", ")
  j_pos <- paste(vapply(conds[nm == ""], pbj, ""), collapse = ", ")
  j_kw <- paste(c(if (any(nm != "")) paste0(nm[nm != ""], " = ", vapply(conds[nm != ""], pbj, "")), "env = @__MODULE__"), collapse = ", ")
  r_th <- p_th <- j_th <- ""
  if (!is.null(thresholds)) {
    r_th <- sprintf(", thresholds = list(b = list(t1 = quote(%s)))", thresholds)
    p_th <- sprintf(", thresholds={'b': {'t1': %s}}", pbq(thresholds))
    j_th <- sprintf(", thresholds = (b = (t1 = %s,),)", pbj(thresholds))
  }
  case(id, paste0(PB_R, "bootstrap_probability(st, ", r_args, r_th, ")"),
       paste0(PB_P, "result = bootstrap_probability(st, ", p_args, p_th, ")"), list(PT = PT),
       jl = paste0(PB_J, "result = bootstrap_probability(st", if (nzchar(j_pos)) paste0(", ", j_pos) else "", "; ", j_kw, j_th, ")"))
}
pb_case("prob_rsyntax", c(list("cagr > thr"), PBC[1:9]))
pb_case("prob_scalar", PBC[10:15])
pb_case("prob_multiline", PBC[16:17])
pb_case("prob_rs_thr", list("cagr > 0"), thresholds = "sharpe > thr & !is.na(cagr)")
pb_case("prob_rs_err1", list("zz > 0"))
pb_case("prob_rs_err2", list(x = "cagr > 0 && sharpe > 0"))
pb_case("prob_rs_err3", list(x = "cagr[[0]] > 0"))

SB_R <- "cfgb <- bootstrap_config(c(akt = 'aktien'), input = 'prices'); bnh <- create_strategy(akt = asset_config('etf', 'bnh'))\n"
SB_P <- "cfgb = bootstrap_config({'akt': 'aktien'}, input='prices'); bnh = simlev.create_strategy(akt=simlev.asset_config('etf', 'bnh'))\nimport tempfile, os\n"
SB_J <- 'cfgb = bootstrap_config((akt = "aktien",), input = "prices"); bnh = create_strategy(akt = asset_config("etf", "bnh"))\n'
case("study_chunkdir", paste0(SB_R, "td <- tempfile(); a <- bootstrap_study(ds, cfgb, 'raw', n = 4, path_length = 200, seed = 2, chunk_size = 2, chunk_dir = td, progress = FALSE, keep_returns = 'month', strategies = list(b = bnh)); b <- bootstrap_study(ds, cfgb, 'raw', n = 4, path_length = 200, seed = 2, chunk_size = 2, chunk_dir = td, progress = FALSE, keep_returns = 'month', strategies = list(b = bnh)); list(a$results, b$results, b$returns, length(list.files(td)), sort(list.files(td)))"),
     paste0(SB_P, "td = os.path.join(tempfile.mkdtemp(), 'x'); a = bootstrap_study(ds, cfgb, 'raw', n=4, path_length=200, seed=2, chunk_size=2, chunk_dir=td, progress=False, keep_returns='month', strategies={'b': bnh}); b = bootstrap_study(ds, cfgb, 'raw', n=4, path_length=200, seed=2, chunk_size=2, chunk_dir=td, progress=False, keep_returns='month', strategies={'b': bnh}); result = [a['results'], b['results'], b['returns'], len(os.listdir(td)), sorted(os.listdir(td))]"), Is,
     jl = paste0(SB_J, 'td = joinpath(mktempdir(), "x"); a = bootstrap_study(ds, cfgb, "raw"; n = 4, path_length = 200, seed = 2, chunk_size = 2, chunk_dir = td, progress = false, keep_returns = "month", strategies = (b = bnh,)); b = bootstrap_study(ds, cfgb, "raw"; n = 4, path_length = 200, seed = 2, chunk_size = 2, chunk_dir = td, progress = false, keep_returns = "month", strategies = (b = bnh,)); result = [a["results"], b["results"], b["returns"], length(readdir(td)), sort(readdir(td))]'))
case("study_sigdf_args", paste0(SB_R, "sg <- function(df) { df$akt <- df$akt * 2; df }; st <- bootstrap_study(ds, cfgb, 'raw', n = 2, path_length = 150, seed = 3, progress = FALSE, sim_args = list(start_value = 500), strategies = list(a = bnh, b = list(strategy = bnh, signal = sg, args = list(start_value = 2000)))); st$results"),
     paste0(SB_P, "def sg(df):\n    df = df.copy(); df['akt'] = df['akt'] * 2; return df\nst = bootstrap_study(ds, cfgb, 'raw', n=2, path_length=150, seed=3, progress=False, sim_args={'start_value': 500}, strategies={'a': bnh, 'b': {'strategy': bnh, 'signal': sg, 'args': {'start_value': 2000}}}); result = st['results']"), Is,
     jl = paste0(SB_J, 'function sg(df)
    df = copy(df); df["akt"] = df["akt"] .* 2; df
end
st = bootstrap_study(ds, cfgb, "raw"; n = 2, path_length = 150, seed = 3, progress = false, sim_args = (start_value = 500,), strategies = (a = bnh, b = (strategy = bnh, signal = sg, args = (start_value = 2000,)))); result = st["results"]'))
case("study_manywarn", paste0(SB_R, "mk <- function(k) function(df) { for (j in seq_len(k)) warning(paste('W', j)); list(x = 1) }; st <- bootstrap_study(ds, cfgb, 'raw', n = 2, path_length = 100, seed = 1, progress = FALSE, strategies = list(a = list(strategy = bnh, signal = mk(3)), b = list(strategy = bnh, signal = mk(2)))); st$warnings"),
     paste0(SB_P, "import warnings as _w\ndef mk(k):\n    def f(df):\n        for j in range(1, k + 1):\n            _w.warn('W %d' % j)\n        return {'x': 1.0}\n    return f\nst = bootstrap_study(ds, cfgb, 'raw', n=2, path_length=100, seed=1, progress=False, strategies={'a': {'strategy': bnh, 'signal': mk(3)}, 'b': {'strategy': bnh, 'signal': mk(2)}}); result = st['warnings']"), Is,
     jl = paste0(SB_J, 'mk(k) = df -> (for j in 1:k; @warn "W $j"; end; (x = 1.0,))
st = bootstrap_study(ds, cfgb, "raw"; n = 2, path_length = 100, seed = 1, progress = false, strategies = (a = (strategy = bnh, signal = mk(3)), b = (strategy = bnh, signal = mk(2)))); result = st["warnings"]'))
case("study_metrics_custom", paste0(SB_R, "m1 <- function(res) c(cg = res$cagr, fv = tail(res$worth, 1)); st <- bootstrap_study(ds, cfgb, 'raw', n = 2, path_length = 100, seed = 1, progress = FALSE, metrics = m1, strategies = list(a = bnh)); list(st$results, summary(st, metrics = c('cg', 'fv')))"),
     paste0(SB_P, "m1 = lambda res: pd.Series([res['cagr'], res['worth'][-1]], index=['cg', 'fv'])\nst = bootstrap_study(ds, cfgb, 'raw', n=2, path_length=100, seed=1, progress=False, metrics=m1, strategies={'a': bnh}); result = [st['results'], summary(st, metrics=['cg', 'fv'])]"), Is,
     jl = paste0(SB_J, 'm1(res) = SL.named("cg" => res.cagr, "fv" => res.worth[end])
st = bootstrap_study(ds, cfgb, "raw"; n = 2, path_length = 100, seed = 1, progress = false, metrics = m1, strategies = (a = bnh,)); result = [st["results"], r_summary(st; metrics = ["cg", "fv"])]'))
case("study_metrics_fail", paste0(SB_R, "bootstrap_study(ds, cfgb, 'raw', n = 2, path_length = 100, seed = 1, progress = FALSE, metrics = function(res) NULL, strategies = list(a = bnh))"),
     paste0(SB_P, "result = bootstrap_study(ds, cfgb, 'raw', n=2, path_length=100, seed=1, progress=False, metrics=lambda res: None, strategies={'a': bnh})"), Is,
     jl = paste0(SB_J, 'result = bootstrap_study(ds, cfgb, "raw"; n = 2, path_length = 100, seed = 1, progress = false, metrics = res -> nothing, strategies = (a = bnh,))'))
case("study_metrics_err", paste0(SB_R, "bootstrap_study(ds, cfgb, 'raw', n = 2, path_length = 100, seed = 1, progress = FALSE, metrics = function(res) stop('kaputt'), strategies = list(a = bnh))"),
     paste0(SB_P, "def mf(res):\n    raise ValueError('kaputt')\nresult = bootstrap_study(ds, cfgb, 'raw', n=2, path_length=100, seed=1, progress=False, metrics=mf, strategies={'a': bnh})"), Is,
     jl = paste0(SB_J, 'mf(res) = error("kaputt")
result = bootstrap_study(ds, cfgb, "raw"; n = 2, path_length = 100, seed = 1, progress = false, metrics = mf, strategies = (a = bnh,))'))
case("study_print_paired", paste0(SB_R, "st <- bootstrap_study(ds, cfgb, 'stationary', n = 3, params = list(L = 20), path_length = 150, seed = 6, progress = FALSE, benchmark = 'a', strategies = list(a = bnh, h = create_strategy(akt = asset_config('etf', 'bnh', asset_share = 0.5)))); st$elapsed <- 2.25; st"),
     paste0(SB_P, "st = bootstrap_study(ds, cfgb, 'stationary', n=3, params={'L': 20}, path_length=150, seed=6, progress=False, benchmark='a', strategies={'a': bnh, 'h': simlev.create_strategy(akt=simlev.asset_config('etf', 'bnh', asset_share=0.5))}); st['elapsed'] = 2.25; result = st"), Is,
     jl = paste0(SB_J, 'st = bootstrap_study(ds, cfgb, "stationary"; n = 3, params = (L = 20,), path_length = 150, seed = 6, progress = false, benchmark = "a", strategies = (a = bnh, h = create_strategy(akt = asset_config("etf", "bnh", asset_share = 0.5)))); st["elapsed"] = 2.25; result = st'))

# ── cores = 2 (Etappe 5): Ergebnis und Zufallszustand danach wie bei Fork ───
case("bs_cores2_rng", paste0(CFG_R, "set.seed(4); b <- bootstrap(d, cfg, 'stationary', n = 5, seed = 1, progress = FALSE, cores = 2, path_length = 120); list(b, runif(1))"),
     paste0(CFG_P, "RNG.set_seed(4); b = bootstrap(d, cfg, 'stationary', n=5, seed=1, progress=False, cores=2, path_length=120); result = [b, RNG.runif(1)]"), I,
     jl = paste0(CFG_J, 'RNG.set_seed(4); b = bootstrap(d, cfg, "stationary"; n = 5, seed = 1, progress = false, cores = 2, path_length = 120); result = [b, RNG.runif(1)]'))
case("bs_cores2_garch", "bootstrap(d, bootstrap_config(c(us = 'us', eu = 'eu')), 'gjr_garch', n = 3, seed = 6, progress = FALSE, path_length = 80, cores = 2)",
     "result = bootstrap(d, bootstrap_config({'us': 'us', 'eu': 'eu'}), 'gjr_garch', n=3, seed=6, progress=False, path_length=80, cores=2)", I,
     jl = 'result = bootstrap(d, bootstrap_config((us = "us", eu = "eu")), "gjr_garch"; n = 3, seed = 6, progress = false, path_length = 80, cores = 2)')
case("study_cores2", paste0(STR_R, "set.seed(8); st <- bootstrap_study(ds, cfgs, 'stationary', n = 4, params = list(L = 30), path_length = 400, burn_in = 35, seed = 1, progress = FALSE, benchmark = 'bnh', strategies = strats, chunk_size = 1, cores = 2); st$elapsed <- 0; list(st, runif(1))"),
     paste0(STR_P, "RNG.set_seed(8); st = bootstrap_study(ds, cfgs, 'stationary', n=4, params={'L': 30}, path_length=400, burn_in=35, seed=1, progress=False, benchmark='bnh', strategies=strats, chunk_size=1, cores=2); st['elapsed'] = 0; result = [st, RNG.runif(1)]"), Is,
     jl = paste0(STR_J, 'RNG.set_seed(8); st = bootstrap_study(ds, cfgs, "stationary"; n = 4, params = (L = 30,), path_length = 400, burn_in = 35, seed = 1, progress = false, benchmark = "bnh", strategies = strats, chunk_size = 1, cores = 2); st["elapsed"] = 0; result = [st, RNG.runif(1)]'))
case("study_cores2_warn", paste0(SB_R, "mk <- function(k) function(df) { for (j in seq_len(k)) warning(paste('W', j)); list(x = 1) }; st <- bootstrap_study(ds, cfgb, 'raw', n = 3, path_length = 100, seed = 1, progress = FALSE, chunk_size = 1, cores = 2, strategies = list(a = list(strategy = bnh, signal = mk(3)), b = list(strategy = bnh, signal = mk(2)))); list(st$results, st$warnings)"),
     paste0(SB_P, "def mk(k):\n    def f(df):\n        for j in range(1, k + 1):\n            warnings.warn('W %d' % j)\n        return {'x': 1}\n    return f\nimport warnings\nst = bootstrap_study(ds, cfgb, 'raw', n=3, path_length=100, seed=1, progress=False, chunk_size=1, cores=2, strategies={'a': {'strategy': bnh, 'signal': mk(3)}, 'b': {'strategy': bnh, 'signal': mk(2)}}); result = [st['results'], st['warnings']]"), Is,
     jl = paste0(SB_J, 'mk(k) = df -> (for j in 1:k; @warn "W $j"; end; (x = 1,))
st = bootstrap_study(ds, cfgb, "raw"; n = 3, path_length = 100, seed = 1, progress = false, chunk_size = 1, cores = 2, strategies = (a = (strategy = bnh, signal = mk(3)), b = (strategy = bnh, signal = mk(2)))); result = [st["results"], st["warnings"]]'))

ref_done()
