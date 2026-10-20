# Referenzfälle für scenarios.R.
source("golden/modules/ref_tools.R"); ref_init("scenarios")
P <- "from simlev import scenarios as SC\n"
J <- 'SC = SL.Scenarios\n'

# ── Annahmen ─────────────────────────────────────────────────────────────
ref_case("views", "list(view_mean('a', -0.2), view_prob('a < -2', 0.15, '>='), view_vol('b', 0.8, '<='), view_mean('a', 1L, '<'), view_prob('x', 1))",
         paste0(P, "result = [SC.view_mean('a', -0.2), SC.view_prob('a < -2', 0.15, '>='), SC.view_vol('b', 0.8, '<='), SC.view_mean('a', 1, '<'), SC.view_prob('x', 1)]"),
         jl = paste0(J, 'result = [SC.view_mean("a", -0.2), SC.view_prob("a < -2", 0.15, ">="), SC.view_vol("b", 0.8, "<="), SC.view_mean("a", 1, "<"), SC.view_prob("x", 1)]'))
ref_case("view_err1", "view_mean('a', NA)", paste0(P, "result = SC.view_mean('a', simlev._r.fmt.NA_REAL)"), jl = paste0(J, 'result = SC.view_mean("a", missing)'))
ref_case("view_err2", "view_prob('a > 1', 1.5)", paste0(P, "result = SC.view_prob('a > 1', 1.5)"), jl = paste0(J, 'result = SC.view_prob("a > 1", 1.5)'))
ref_case("view_err3", "view_vol('a', -1)", paste0(P, "result = SC.view_vol('a', -1)"), jl = paste0(J, 'result = SC.view_vol("a", -1)'))
ref_case("view_err4", "view_mean('a', c(1, 2))", paste0(P, "result = SC.view_mean('a', [1, 2])"), jl = paste0(J, 'result = SC.view_mean("a", [1, 2])'))
ref_case("view_err5", "view_mean('a', 'x')", paste0(P, "result = SC.view_mean('a', 'x')"), jl = paste0(J, 'result = SC.view_mean("a", "x")'))
ref_case("view_err6", "view_mean('a', 1, '==')", paste0(P, "result = SC.view_mean('a', 1, '==')"), jl = paste0(J, 'result = SC.view_mean("a", 1, "==")'))

# ── entropy_pooling ──────────────────────────────────────────────────────
set.seed(1); X <- data.frame(a = rnorm(400, 0.2, 2), b = rnorm(400, 0.05, 0.5)); X$b <- X$b + 0.1 * X$a
EI <- list(X = X)
ref_case("ep_table", "entropy_pooling(X, c('a', 'b'), list(view_mean('a', -0.3), view_prob('a < -2', 0.2), view_vol('b', 0.5, '<=')))",
         paste0(P, "result = SC.entropy_pooling(X, ['a', 'b'], [SC.view_mean('a', -0.3), SC.view_prob('a < -2', 0.2), SC.view_vol('b', 0.5, '<=')])"), inputs = EI,
         jl = paste0(J, 'result = SC.entropy_pooling(X, ["a", "b"], [SC.view_mean("a", -0.3), SC.view_prob("a < -2", 0.2), SC.view_vol("b", 0.5, "<=")])'))
ref_case("ep_vol_mean", "entropy_pooling(X, c('a', 'b'), list(view_vol('a', 1.5), view_mean('a', 0.5), view_mean('b', 0, '>=')), frequency = 'month')",
         paste0(P, "result = SC.entropy_pooling(X, ['a', 'b'], [SC.view_vol('a', 1.5), SC.view_mean('a', 0.5), SC.view_mean('b', 0, '>=')], frequency='month')"), inputs = EI,
         jl = paste0(J, 'result = SC.entropy_pooling(X, ["a", "b"], [SC.view_vol("a", 1.5), SC.view_mean("a", 0.5), SC.view_mean("b", 0, ">=")]; frequency = "month")'))
ref_case("ep_empty", "entropy_pooling(X, 'a', list())", paste0(P, "result = SC.entropy_pooling(X, 'a', [])"), inputs = EI,
         jl = paste0(J, 'result = SC.entropy_pooling(X, "a", [])'))
ref_case("ep_prior", "entropy_pooling(X, c('a', 'b'), list(view_mean('b', 0.1)), prior = seq_len(400))",
         paste0(P, "result = SC.entropy_pooling(X, ['a', 'b'], [SC.view_mean('b', 0.1)], prior=np.arange(1, 401))"), inputs = EI,
         jl = paste0(J, 'result = SC.entropy_pooling(X, ["a", "b"], [SC.view_mean("b", 0.1)]; prior = collect(1:400))'))
ref_case("ep_infeasible", "entropy_pooling(X, c('a', 'b'), list(view_mean('a', 50)))",
         paste0(P, "result = SC.entropy_pooling(X, ['a', 'b'], [SC.view_mean('a', 50)])"), inputs = EI,
         jl = paste0(J, 'result = SC.entropy_pooling(X, ["a", "b"], [SC.view_mean("a", 50)])'))
ref_case("ep_ineq", "entropy_pooling(X, c('a', 'b'), list(view_prob('a > 0 & b > 0', 0.5, '>='), view_mean('a', 1, '<=')))",
         paste0(P, "result = SC.entropy_pooling(X, ['a', 'b'], [SC.view_prob('a > 0 & b > 0', 0.5, '>='), SC.view_mean('a', 1, '<=')])"), inputs = EI,
         jl = paste0(J, 'result = SC.entropy_pooling(X, ["a", "b"], [SC.view_prob("a > 0 & b > 0", 0.5, ">="), SC.view_mean("a", 1, "<=")])'))
ref_case("ep_matrix", "entropy_pooling(unname(as.matrix(X)), c('V1', 'V2'), list(view_mean('V1', 0)))",
         paste0(P, "result = SC.entropy_pooling(X.to_numpy(), ['V1', 'V2'], [SC.view_mean('V1', 0)])"), inputs = EI,
         jl = paste0(J, 'result = SC.entropy_pooling(Matrix(hcat(X["a"], X["b"])), ["V1", "V2"], [SC.view_mean("V1", 0)])'))
ref_case("ep_err_prior1", "entropy_pooling(X, 'a', list(), prior = c(1, -1))", paste0(P, "result = SC.entropy_pooling(X, 'a', [], prior=[1, -1])"), inputs = EI,
         jl = paste0(J, 'result = SC.entropy_pooling(X, "a", []; prior = [1, -1])'))
ref_case("ep_err_prior2", "entropy_pooling(X, 'a', list(), prior = c(rep(1, 399), NA))", paste0(P, "result = SC.entropy_pooling(X, 'a', [], prior=np.r_[np.ones(399), simlev._r.fmt.NA_REAL])"), inputs = EI,
         jl = paste0(J, 'result = SC.entropy_pooling(X, "a", []; prior = vcat(ones(399), SL.NA))'))
ref_case("ep_err_prior3", "entropy_pooling(X, 'a', list(), prior = rep(0, 400))", paste0(P, "result = SC.entropy_pooling(X, 'a', [], prior=np.zeros(400))"), inputs = EI,
         jl = paste0(J, 'result = SC.entropy_pooling(X, "a", []; prior = zeros(400))'))
ref_case("ep_err_view1", "entropy_pooling(X, 'a', list(view_mean('zz', 1)))", paste0(P, "result = SC.entropy_pooling(X, 'a', [SC.view_mean('zz', 1)])"), inputs = EI,
         jl = paste0(J, 'result = SC.entropy_pooling(X, "a", [SC.view_mean("zz", 1)])'))
ref_case("ep_err_view2", "entropy_pooling(X, 'a', list(view_prob('TRUE', 0.5)))", paste0(P, "result = SC.entropy_pooling(X, 'a', [SC.view_prob('TRUE', 0.5)])"), inputs = EI,
         jl = paste0(J, 'result = SC.entropy_pooling(X, "a", [SC.view_prob("TRUE", 0.5)])'))
ref_case("ep_err_view3", "entropy_pooling(X, 'a', list(view_vol('zz', 1)))", paste0(P, "result = SC.entropy_pooling(X, 'a', [SC.view_vol('zz', 1)])"), inputs = EI,
         jl = paste0(J, 'result = SC.entropy_pooling(X, "a", [SC.view_vol("zz", 1)])'))
ref_case("ep_err_view4", "entropy_pooling(X, 'a', list(list(type = 'skew', var = 'a', value = 1, op = '=')))",
         paste0(P, "result = SC.entropy_pooling(X, 'a', [{'type': 'skew', 'var': 'a', 'value': 1, 'op': '='}])"), inputs = EI,
         jl = paste0(J, 'result = SC.entropy_pooling(X, "a", [SL.RList("type" => "skew", "var" => "a", "value" => 1, "op" => "=")])'))

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
ref_case("ep_prices", "entropy_pooling(d, c('aktien', 'anleihen'), list(view_mean('inflation', 3), view_prob('aktien < -2 & inflation > 2', 0.1)), states = 'inflation')",
         paste0(P, "result = SC.entropy_pooling(d, ['aktien', 'anleihen'], [SC.view_mean('inflation', 3), SC.view_prob('aktien < -2 & inflation > 2', 0.1)], states='inflation')"), inputs = DI,
         jl = paste0(J, 'result = SC.entropy_pooling(d, ["aktien", "anleihen"], [SC.view_mean("inflation", 3), SC.view_prob("aktien < -2 & inflation > 2", 0.1)]; states = "inflation")'))
# view_prob: Ausdrücke in R-Syntax (gemeinsamer Auswerter, Modul rexpr); freie Variablen global (R: parent.frame() von entropy_pooling)
EPV <- c("a < -2 | !b > 0", "abs(a) > 2 * sd(a)", "a > quantile(a, 0.9)", "if (lim > 1) b > 0.5 else FALSE", "(a %/% 1) %% 2 == 0",
         "ifelse(a > 0, \"1\", \"0\")", "a > 0 &\n b > 0")
epq <- function(x) paste0("'", gsub("\n", "\\n", x, fixed = TRUE), "'")
epj <- function(x) paste0('"', gsub("\n", "\\n", gsub('"', '\\"', x, fixed = TRUE), fixed = TRUE), '"')
EPO <- c("=", "<=", "=", "=", ">=", "=", "=")
EPP <- c(0.6, 0.1, 0.15, 0.2, 0.4, 0.5, 0.3)
for (k in seq_along(EPV))
  ref_case(sprintf("ep_rx_%02d", k), sprintf("lim <<- 1.5; entropy_pooling(X, c('a', 'b'), list(view_prob(%s, %s, '%s')))", deparse(EPV[k]), EPP[k], EPO[k]),
           paste0(P, sprintf("lim = 1.5\nresult = SC.entropy_pooling(X, ['a', 'b'], [SC.view_prob(%s, %s, '%s')])", epq(EPV[k]), EPP[k], EPO[k])), inputs = EI,
           jl = paste0(J, sprintf('lim = 1.5; result = SC.entropy_pooling(X, ["a", "b"], [SC.view_prob(%s, %s, "%s")]; env = @__MODULE__)', epj(EPV[k]), EPP[k], EPO[k])))
for (k in seq_along(EPE <- c("a < ", "zz > 0", "a[1] > 0", "a > \"x\"")))
  ref_case(sprintf("ep_rx_err%d", k), sprintf("entropy_pooling(X, 'a', list(view_prob(%s, 0.5)))", deparse(EPE[k])),
           paste0(P, sprintf("result = SC.entropy_pooling(X, 'a', [SC.view_prob(%s, 0.5)])", epq(EPE[k]))), inputs = EI,
           jl = paste0(J, sprintf('result = SC.entropy_pooling(X, "a", [SC.view_prob(%s, 0.5)])', epj(EPE[k]))))
ref_case("ep_prices_day", "entropy_pooling(d[1:300, ], c('aktien', 'gold'), list(view_vol('gold', 1)), frequency = 'day')",
         paste0(P, "result = SC.entropy_pooling(d.iloc[:300], ['aktien', 'gold'], [SC.view_vol('gold', 1)], frequency='day')"), inputs = DI,
         jl = paste0(J, 'result = SC.entropy_pooling(SL.rows(d, 1:300), ["aktien", "gold"], [SC.view_vol("gold", 1)]; frequency = "day")'))

# ── copula_scenarios ─────────────────────────────────────────────────────
ref_case("cs_t", "copula_scenarios(d, c('aktien', 'anleihen'), n = 500, seed = 1)",
         paste0(P, "result = SC.copula_scenarios(d, ['aktien', 'anleihen'], n=500, seed=1)"), inputs = DI,
         jl = paste0(J, 'result = SC.copula_scenarios(d, ["aktien", "anleihen"]; n = 500, seed = 1)'))
ref_case("cs_gauss", "copula_scenarios(d, c('aktien', 'anleihen', 'gold'), n = 300, family = 'gaussian', frequency = 'month', seed = 2)",
         paste0(P, "result = SC.copula_scenarios(d, ['aktien', 'anleihen', 'gold'], n=300, family='gaussian', frequency='month', seed=2)"), inputs = DI,
         jl = paste0(J, 'result = SC.copula_scenarios(d, ["aktien", "anleihen", "gold"]; n = 300, family = "gaussian", frequency = "month", seed = 2)'))
ref_case("cs_stress1", "copula_scenarios(d, c('aktien', 'anleihen', 'gold'), n = 400, stress = list(aktien = c(0, 0.05)), seed = 3)",
         paste0(P, "result = SC.copula_scenarios(d, ['aktien', 'anleihen', 'gold'], n=400, stress={'aktien': [0, 0.05]}, seed=3)"), inputs = DI,
         jl = paste0(J, 'result = SC.copula_scenarios(d, ["aktien", "anleihen", "gold"]; n = 400, stress = (aktien = [0, 0.05],), seed = 3)'))
ref_case("cs_stress1g", "copula_scenarios(d, c('aktien', 'anleihen'), n = 200, family = 'gaussian', stress = list(anleihen = c(0.9, 1)), seed = 4)",
         paste0(P, "result = SC.copula_scenarios(d, ['aktien', 'anleihen'], n=200, family='gaussian', stress={'anleihen': [0.9, 1]}, seed=4)"), inputs = DI,
         jl = paste0(J, 'result = SC.copula_scenarios(d, ["aktien", "anleihen"]; n = 200, family = "gaussian", stress = (anleihen = [0.9, 1],), seed = 4)'))
ref_case("cs_stress2", "copula_scenarios(d, c('aktien', 'anleihen', 'gold'), n = 100, stress = list(gold = c(0, 0.3), aktien = c(0, 0.3)), seed = 5)",
         paste0(P, "result = SC.copula_scenarios(d, ['aktien', 'anleihen', 'gold'], n=100, stress={'gold': [0, 0.3], 'aktien': [0, 0.3]}, seed=5)"), inputs = DI,
         jl = paste0(J, 'result = SC.copula_scenarios(d, ["aktien", "anleihen", "gold"]; n = 100, stress = (gold = [0, 0.3], aktien = [0, 0.3]), seed = 5)'))
ref_case("cs_stress_all", "copula_scenarios(d, c('aktien', 'anleihen'), n = 50, family = 'gaussian', stress = list(aktien = c(0, 0.5), anleihen = c(0.2, 1)), seed = 6)",
         paste0(P, "result = SC.copula_scenarios(d, ['aktien', 'anleihen'], n=50, family='gaussian', stress={'aktien': [0, 0.5], 'anleihen': [0.2, 1]}, seed=6)"), inputs = DI,
         jl = paste0(J, 'result = SC.copula_scenarios(d, ["aktien", "anleihen"]; n = 50, family = "gaussian", stress = (aktien = [0, 0.5], anleihen = [0.2, 1]), seed = 6)'))
set.seed(7); XS <- data.frame(x = rnorm(150), y = rnorm(150)); XS$z <- XS$x + 1e-9 * rnorm(150)
ref_case("cs_table_psd", "copula_scenarios(XS, c('x', 'y', 'z'), n = 200, seed = 8)",
         paste0(P, "result = SC.copula_scenarios(XS, ['x', 'y', 'z'], n=200, seed=8)"), inputs = list(XS = XS),
         jl = paste0(J, 'result = SC.copula_scenarios(XS, ["x", "y", "z"]; n = 200, seed = 8)'))
ref_case("cs_seednull", "set.seed(10); x <- copula_scenarios(XS, c('x', 'y'), n = 100, family = 'gaussian'); list(x, runif(2))",
         paste0(P, "simlev._r.rng.set_seed(10); x = SC.copula_scenarios(XS, ['x', 'y'], n=100, family='gaussian'); result = [x, simlev._r.rng.runif(2)]"), inputs = list(XS = XS),
         jl = paste0(J, 'SL.RRng.set_seed(10); x = SC.copula_scenarios(XS, ["x", "y"]; n = 100, family = "gaussian"); result = [x, SL.RRng.runif(2)]'))
JST <- c("1" = "[[0, 0.1]]", "2" = "(zz = [0, 0.1],)", "3" = "(x = [0.2, 0.1],)", "4" = "(x = [0, 5],)", "5" = "(x = 0.1,)",
         "6" = "SL.RList()", "7" = "(x = [SL.NA, 0.1],)")
for (st in list(c("1", "list(c(0, 0.1))", "[[0, 0.1]]"), c("2", "list(zz = c(0, 0.1))", "{'zz': [0, 0.1]}"), c("3", "list(x = c(0.2, 0.1))", "{'x': [0.2, 0.1]}"),
                c("4", "list(x = c(0, 5))", "{'x': [0, 5]}"), c("5", "list(x = 0.1)", "{'x': 0.1}"), c("6", "list()", "{}"), c("7", "list(x = c(NA, 0.1))", "{'x': [simlev._r.fmt.NA_REAL, 0.1]}")))
  ref_case(paste0("cs_err", st[1]), sprintf("copula_scenarios(XS, c('x', 'y'), n = 10, family = 'gaussian', stress = %s)", st[2]),
           paste0(P, sprintf("result = SC.copula_scenarios(XS, ['x', 'y'], n=10, family='gaussian', stress=%s)", st[3])), inputs = list(XS = XS),
           jl = paste0(J, sprintf('result = SC.copula_scenarios(XS, ["x", "y"]; n = 10, family = "gaussian", stress = %s)', JST[[st[1]]])))
ref_case("cs_err_fam", "copula_scenarios(XS, 'x', family = 'clayton')", paste0(P, "result = SC.copula_scenarios(XS, 'x', family='clayton')"), inputs = list(XS = XS),
         jl = paste0(J, 'result = SC.copula_scenarios(XS, "x"; family = "clayton")'))

# ── scenario_risk ────────────────────────────────────────────────────────
ref_case("risk", "ep <- entropy_pooling(X, c('a', 'b'), list(view_mean('a', -0.2))); cs <- copula_scenarios(X, c('a', 'b'), n = 300, seed = 1)
  list(scenario_risk(ep, c(a = 0.6, b = 0.4)), scenario_risk(ep, c(b = 1), alpha = 0.2), scenario_risk(cs, c(a = 0.5, b = 0.5), 0.01))",
         paste0(P, "ep = SC.entropy_pooling(X, ['a', 'b'], [SC.view_mean('a', -0.2)]); cs = SC.copula_scenarios(X, ['a', 'b'], n=300, seed=1)\nresult = [SC.scenario_risk(ep, {'a': 0.6, 'b': 0.4}), SC.scenario_risk(ep, pd.Series({'b': 1.0}), alpha=0.2), SC.scenario_risk(cs, {'a': 0.5, 'b': 0.5}, 0.01)]"),
         inputs = EI,
         jl = paste0(J, 'ep = SC.entropy_pooling(X, ["a", "b"], [SC.view_mean("a", -0.2)]); cs = SC.copula_scenarios(X, ["a", "b"]; n = 300, seed = 1)\nresult = [SC.scenario_risk(ep, SL.named("a" => 0.6, "b" => 0.4)), SC.scenario_risk(ep, SL.named("b" => 1.0); alpha = 0.2), SC.scenario_risk(cs, (a = 0.5, b = 0.5); alpha = 0.01)]'))
PE <- paste0(P, "ep = SC.entropy_pooling(X, ['a', 'b'], [])\n")
JE <- paste0(J, 'ep = SC.entropy_pooling(X, ["a", "b"], [])\n')
ref_case("risk_err1", "scenario_risk(list(), c(a = 1))", paste0(P, "result = SC.scenario_risk({}, {'a': 1})"), jl = paste0(J, 'result = SC.scenario_risk(SL.RList(), (a = 1,))'))
ref_case("risk_err2", "ep <- entropy_pooling(X, c('a', 'b'), list()); scenario_risk(ep, c(a = 1), alpha = 1)", paste0(PE, "result = SC.scenario_risk(ep, {'a': 1}, alpha=1)"), inputs = EI, jl = paste0(JE, 'result = SC.scenario_risk(ep, (a = 1,); alpha = 1)'))
ref_case("risk_err3", "ep <- entropy_pooling(X, c('a', 'b'), list()); scenario_risk(ep, c(1, 2))", paste0(PE, "result = SC.scenario_risk(ep, [1, 2])"), inputs = EI, jl = paste0(JE, 'result = SC.scenario_risk(ep, [1, 2])'))
ref_case("risk_err4", "ep <- entropy_pooling(X, c('a', 'b'), list()); scenario_risk(ep, c(a = 1, q = 2))", paste0(PE, "result = SC.scenario_risk(ep, {'a': 1, 'q': 2})"), inputs = EI, jl = paste0(JE, 'result = SC.scenario_risk(ep, (a = 1, q = 2))'))

# ── crisis_replay ────────────────────────────────────────────────────────
set.seed(3); n <- 6 * 365
dc <- data.frame(date = seq.Date(as.Date("2006-06-01"), by = "day", length.out = n))
dc$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.012)); dc$anleihen <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.003))
dc$aktien[c(500, 501)] <- NA
CI <- list(dc = dc)
ref_case("crisis_default", "crisis_replay(dc, c(aktien = 0.6, anleihen = 0.4))",
         paste0(P, "result = SC.crisis_replay(dc, {'aktien': 0.6, 'anleihen': 0.4})"), inputs = CI,
         jl = paste0(J, 'result = SC.crisis_replay(dc, (aktien = 0.6, anleihen = 0.4))'))
kr <- data.frame(crisis = c("A", "B", "C", "D"), start = as.Date(c("2007-05-01", "2008-01-01", "2012-05-01", "2001-01-01")),
                 end = as.Date(c("2007-09-30", "2008-01-01", "2012-05-30", "2001-06-01")))
ref_case("crisis_custom", "list(crisis_replay(dc, c(aktien = 3, anleihen = 1), kr, rebalance = TRUE), crisis_replay(dc, c(anleihen = 1), kr))",
         paste0(P, "result = [SC.crisis_replay(dc, {'aktien': 3, 'anleihen': 1}, kr, rebalance=True), SC.crisis_replay(dc, {'anleihen': 1}, kr)]"),
         inputs = list(dc = dc, kr = kr),
         jl = paste0(J, 'result = [SC.crisis_replay(dc, (aktien = 3, anleihen = 1), kr; rebalance = true), SC.crisis_replay(dc, (anleihen = 1,), kr)]'))
dlate <- dc[dc$date >= as.Date("2008-01-10"), ]
ref_case("crisis_chr", "kc <- data.frame(crisis = 'X', start = '2009-01-05', end = '2010-02-01'); crisis_replay(dlate[c(2, 1, 3:nrow(dlate)), ], c(aktien = 0.5, anleihen = 0.5), kc)",
         paste0(P, "kc = pd.DataFrame({'crisis': ['X'], 'start': ['2009-01-05'], 'end': ['2010-02-01']}); result = SC.crisis_replay(dlate.iloc[[1, 0] + list(range(2, len(dlate)))], {'aktien': 0.5, 'anleihen': 0.5}, kc)"),
         inputs = list(dlate = dlate),
         jl = paste0(J, 'kc = SL.RFrame("crisis" => ["X"], "start" => ["2009-01-05"], "end" => ["2010-02-01"]); result = SC.crisis_replay(SL.rows(dlate, vcat([2, 1], 3:SL.nrow(dlate))), (aktien = 0.5, anleihen = 0.5), kc)'))
ref_case("crisis_err1", "crisis_replay(as.matrix(dc[, -1]), c(aktien = 1))", paste0(P, "result = SC.crisis_replay(dc.iloc[:, 1:].to_numpy(), {'aktien': 1})"), inputs = list(dc = dc[1:5, ]), jl = paste0(J, 'result = SC.crisis_replay(hcat(dc["aktien"], dc["anleihen"]), (aktien = 1,))'))
ref_case("crisis_err2", "crisis_replay(dc, c(aktien = 1), data.frame(a = 1))", paste0(P, "result = SC.crisis_replay(dc, {'aktien': 1}, pd.DataFrame({'a': [1]}))"), inputs = list(dc = dc[1:5, ]), jl = paste0(J, 'result = SC.crisis_replay(dc, (aktien = 1,), SL.RFrame("a" => [1]))'))
ref_case("crisis_err3", "crisis_replay(dc, c(aktien = NA))", paste0(P, "result = SC.crisis_replay(dc, {'aktien': simlev._r.fmt.NA_REAL})"), inputs = list(dc = dc[1:5, ]), jl = paste0(J, 'result = SC.crisis_replay(dc, (aktien = SL.NA,))'))
ref_case("crisis_err4", "crisis_replay(dc, c(aktien = 1, zz = 1))", paste0(P, "result = SC.crisis_replay(dc, {'aktien': 1, 'zz': 1})"), inputs = list(dc = dc[1:5, ]), jl = paste0(J, 'result = SC.crisis_replay(dc, (aktien = 1, zz = 1))'))
ref_case("crisis_err5", "crisis_replay(dc, c(aktien = 1, anleihen = -1.5))", paste0(P, "result = SC.crisis_replay(dc, {'aktien': 1, 'anleihen': -1.5})"), inputs = list(dc = dc[1:5, ]), jl = paste0(J, 'result = SC.crisis_replay(dc, (aktien = 1, anleihen = -1.5))'))
ref_case("crisis_err6", "crisis_replay(dc, c(aktien = 1))", paste0(P, "result = SC.crisis_replay(dc, {'aktien': 1})"), inputs = list(dc = dc[1:50, ]), jl = paste0(J, 'result = SC.crisis_replay(dc, (aktien = 1,))'))
ref_case("crisis_err7", "crisis_replay(dc, c(0.5, 0.5))", paste0(P, "result = SC.crisis_replay(dc, [0.5, 0.5])"), inputs = list(dc = dc[1:5, ]), jl = paste0(J, 'result = SC.crisis_replay(dc, [0.5, 0.5])'))
ref_done()
