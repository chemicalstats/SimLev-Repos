# Referenzfälle für overfitting.R (overfit_pbo, sharpe_probabilistic, sharpe_deflated,
# overfit_walk_forward, param_bootstrap, sharpe_haircut, .of_*-Helfer).
source("golden/modules/ref_tools.R"); ref_init("overfitting")
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
# ── cores = 2 (Etappe 5): param_bootstrap reicht cores an bootstrap_study ──
bcase("pb_cores2", "bs <- param_bootstrap(ps, h, cfg, top = 2, method = 'stationary', n = 3, params = list(L = 50), seed = 1, progress = FALSE, chunk_size = 1, cores = 2); list(attr(bs, 'param_ids'), bs$results)",
      "bs = OF.param_bootstrap(ps, h, cfg, top=2, method='stationary', n=3, params={'L': 50}, seed=1, progress=False, chunk_size=1, cores=2); result = [bs.attrs['param_ids'], bs['results']]",
      'bs = OF.param_bootstrap(ps, h, cfg; top = 2, method = "stationary", n = 3, params = RList("L" => 50), seed = 1, progress = false, chunk_size = 1, cores = 2); result = [OF.param_ids(bs), bs["results"]]')

ref_done()
