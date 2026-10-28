# Referenzfälle für die aus evd 2.3-7.1 übernommene Fassung von fpot
# (R: SimLev:::.evd_fpot in r/R/vendor_evd.R, nlgpd in r/src/vendor_evd.c;
# Python: simlev/_r/evd.py, Julia: src/r/evd.jl) und den GPD-Weg in
# .fit_tail / bootstrap(…, "evt"). evd selbst wird nicht benötigt; die Fälle
# waren zuvor mit dem echten Paket erzeugt und sind mit der Übernahme
# bitgleich.
# Aufruf aus der Repo-Wurzel:
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript golden/modules/gen_evd.R
source("golden/modules/ref_tools.R"); ref_init("evd")

P <- "import numpy as np\nimport pandas as pd\nfrom simlev._r import evd as E\nimport simlev.bootstrap as B\nfrom simlev.bootstrap import *\n"
JP <- "const E = SL.REvd\nconst B = SL.Bootstrap\nusing SimLev.Bootstrap\n"
case <- function(id, r, py, inputs = list(), jl = NULL, ...)
  ref_case(id, r = r, py = paste0(P, py), inputs = inputs, jl = if (is.null(jl)) NULL else paste0(JP, jl), ...)

# ── Daten ───────────────────────────────────────────────────────────────────
set.seed(1); xe <- rexp(50)                        # shape ≈ 0
set.seed(2); xs <- rexp(200, 150)                  # Renditen-Größenordnung
set.seed(3); xh <- abs(rt(120, 2.5)) * 0.01        # shape > 0
set.seed(4); xp <- runif(60)^(-0.6) - 1            # Pareto, shape ≈ 0.6
set.seed(5); xb <- 1 - runif(80)^0.3               # beschränkt, shape < 0
set.seed(6); xu <- runif(45, 0, 0.02)              # gleichverteilt, shape ≈ -1
set.seed(7); xc <- abs(rcauchy(40))^3              # sehr schwer: Iterationsgrenze
set.seed(8); xn <- c(rnorm(70), NA, NaN)           # mit NA, Schwelle > 0
xi <- c(3L, 1L, 4L, 1L, 5L, 9L, 2L, 6L, 5L, 3L, 5L, 8L, 9L, 7L, 9L)
I <- list(xe = xe, xs = xs, xh = xh, xp = xp, xb = xb, xu = xu, xc = xc, xn = xn, xi = xi)

F <- function(id, args, pargs = args, jargs = args, inputs = I)
  case(paste0("fpot_", id), paste0("SimLev:::.evd_fpot(", args, ")"), paste0("result = E.fpot(", pargs, ")"), inputs,
       jl = paste0("result = E.fpot(", jargs, ")"))

# ── fpot direkt: Lagen ──────────────────────────────────────────────────────
for (v in c("xe", "xs", "xh", "xp", "xb", "xu", "xc", "xi")) {
  F(paste0(v, "_nose"), paste0(v, ", threshold = 0, std.err = FALSE"), paste0(v, ", threshold=0, std_err=False"),
    paste0(v, ", 0; std_err = false"))
  F(v, paste0(v, ", 0"), paste0(v, ", 0"), paste0(v, ", 0"))
}
F("xe_thr", "xe, 0.5, std.err = FALSE", "xe, 0.5, std_err=False", "xe, 0.5; std_err = false")
F("xe_thr_neg", "xe - 1, -0.25", "xe - 1, -0.25", "xe .- 1, -0.25")
F("xn_thr", "xn, 0.3", "xn, 0.3", "xn, 0.3")
F("xh_corr", "xh, 0, corr = TRUE", "xh, 0, corr=True", "xh, 0; corr = true")
F("xb_corr", "xb, 0.05, corr = TRUE", "xb, 0.05, corr=True", "xb, 0.05; corr = true")
F("xe_npp", "xe, 0, npp = 365, std.err = FALSE", "xe, 0, npp=365, std_err=False", "xe, 0; npp = 365, std_err = false")
F("xe_big", "xe * 1e10, 0", "xe * 1e10, 0", "xe .* 1e10, 0")
F("xe_huge", "c(xe, 1e300), 0, std.err = FALSE", "np.append(xe, 1e300), 0, std_err=False", "vcat(xe, 1e300), 0; std_err = false")
F("xe_tiny", "xe * 1e-300, 0, std.err = FALSE", "xe * 1e-300, 0, std_err=False", "xe .* 1e-300, 0; std_err = false")
F("one", "0.5, 0, std.err = FALSE", "[0.5], 0, std_err=False", "[0.5], 0; std_err = false")
F("two", "c(0.5, 1), 0, std.err = FALSE", "[0.5, 1.0], 0, std_err=False", "[0.5, 1.0], 0; std_err = false")
F("const", "rep(0.01, 40), 0, std.err = FALSE", "np.full(40, 0.01), 0, std_err=False", "fill(0.01, 40), 0; std_err = false")
# Startwerte, feste Parameter, optim-Argumente
F("start", "xe, 0, start = list(scale = 1, shape = 0.5)", "xe, 0, start={'scale': 1, 'shape': 0.5}",
  'xe, 0; start = (scale = 1, shape = 0.5)')
F("start_rev", "xh, 0, start = list(shape = 0.2, scale = 0.02)", "xh, 0, start={'shape': 0.2, 'scale': 0.02}",
  'xh, 0; start = (shape = 0.2, scale = 0.02)')
F("start_bad", "xe, 0, start = list(scale = -1, shape = 0), std.err = FALSE", "xe, 0, start={'scale': -1, 'shape': 0}, std_err=False",
  'xe, 0; start = (scale = -1, shape = 0), std_err = false')
F("start_bad_nowarn", "xe, 0, start = list(scale = 1, shape = -2), warn.inf = FALSE, std.err = FALSE",
  "xe, 0, start={'scale': 1, 'shape': -2}, warn_inf=False, std_err=False",
  'xe, 0; start = (scale = 1, shape = -2), warn_inf = false, std_err = false')
F("fix_shape0", "xe, 0, shape = 0", "xe, 0, shape=0", "xe, 0; shape = 0")
F("fix_shape_eps", "xs, 0, shape = 1e-5", "xs, 0, shape=1e-5", "xs, 0; shape = 1e-5")
F("fix_shape_eps2", "xs, 0, shape = 2.1e-5, std.err = FALSE", "xs, 0, shape=2.1e-5, std_err=False", "xs, 0; shape = 2.1e-5, std_err = false")
F("fix_shape", "xh, 0, shape = 0.3, std.err = FALSE", "xh, 0, shape=0.3, std_err=False", "xh, 0; shape = 0.3, std_err = false")
F("fix_scale", "xe, 0, scale = 1", "xe, 0, scale=1", "xe, 0; scale = 1")
F("fix_scale_start", "xb, 0, scale = 0.3, start = list(shape = -0.1)", "xb, 0, scale=0.3, start={'shape': -0.1}",
  "xb, 0; scale = 0.3, start = (shape = -0.1,)")
F("maxit", "xe, 0, control = list(maxit = 2)", "xe, 0, control={'maxit': 2}", 'xe, 0; control = Dict("maxit" => 2)')
F("maxit0", "xh, 0, control = list(maxit = 0), std.err = FALSE", "xh, 0, control={'maxit': 0}, std_err=False",
  'xh, 0; control = Dict("maxit" => 0), std_err = false')
F("reltol", "xp, 0, control = list(reltol = 1e-12, parscale = c(0.5, 0.1))", "xp, 0, control={'reltol': 1e-12, 'parscale': [0.5, 0.1]}",
  'xp, 0; control = Dict("reltol" => 1e-12, "parscale" => [0.5, 0.1])')
F("nm", "xe, 0, method = 'Nelder-Mead'", "xe, 0, method='Nelder-Mead'", 'xe, 0; method = "Nelder-Mead"')
F("cg", "xb, 0, method = 'CG', std.err = FALSE", "xb, 0, method='CG', std_err=False", 'xb, 0; method = "CG", std_err = false')
F("lbfgsb", "xe, 0, method = 'L-BFGS-B', lower = c(0.01, -1), upper = c(10, 1)",
  "xe, 0, method='L-BFGS-B', lower=[0.01, -1], upper=[10, 1]", 'xe, 0; method = "L-BFGS-B", lower = [0.01, -1], upper = [10, 1]')
F("lower_bfgs", "xh, 0, lower = c(0.001, -0.5)", "xh, 0, lower=[0.001, -0.5]", "xh, 0; lower = [0.001, -0.5]")
# Fehler
F("err_empty", "numeric(0), 0", "np.zeros(0), 0", "Float64[], 0")
F("err_chr", "'a', 0", "['a'], 0", '["a"], 0')
F("err_thr_len", "xe, c(0, 1)", "xe, [0, 1]", "xe, [0, 1]")
F("err_thr_chr", "xe, 'a'", "xe, 'a'", 'xe, "a"')
F("err_nodata", "-xe, 0", "-xe, 0", "-xe, 0")
F("err_thr_na", "xe, NA_real_", "xe, simlev._r.fmt.NA_REAL", "xe, SL.NA")
F("err_inf", "c(xe, Inf), 0, std.err = FALSE", "np.append(xe, np.inf), 0, std_err=False", "vcat(xe, Inf), 0; std_err = false")
F("err_inf_mean", "c(xe, 1.7e308, 1.7e308), 0, std.err = FALSE", "np.append(xe, [1.7e308, 1.7e308]), 0, std_err=False",
  "vcat(xe, [1.7e308, 1.7e308]), 0; std_err = false")
F("err_denorm", "xe * 1e-310, 0, std.err = FALSE", "xe * 1e-310, 0, std_err=False", "xe .* 1e-310, 0; std_err = false")
F("err_singular", "rep(0.01, 40), 0", "np.full(40, 0.01), 0", "fill(0.01, 40), 0")
F("err_singular2", "c(0.5, 1), 0", "[0.5, 1.0], 0", "[0.5, 1.0], 0")
F("err_singular_start", "xe, 0, start = list(scale = -1, shape = 0)", "xe, 0, start={'scale': -1, 'shape': 0}",
  'xe, 0; start = (scale = -1, shape = 0)')
F("err_start_vec", "xe, 0, start = c(scale = 1, shape = 0.1)", "xe, 0, start=pd.Series([1, 0.1], index=['scale', 'shape'])",
  'xe, 0; start = SL.RVector([1, 0.1]; names = ["scale", "shape"])')
F("err_start_unknown", "xe, 0, start = list(scale = 1, foo = 0.1)", "xe, 0, start={'scale': 1, 'foo': 0.1}",
  'xe, 0; start = (scale = 1, foo = 0.1)')
F("err_unspec", "xe, 0, start = list(scale = 1)", "xe, 0, start={'scale': 1}", 'xe, 0; start = (scale = 1,)')
F("err_noparam", "xe, 0, scale = 1, shape = 0", "xe, 0, scale=1, shape=0", "xe, 0; scale = 1, shape = 0")
F("err_start_empty", "xe, 0, start = list()", "xe, 0, start={}", "xe, 0; start = (;)")
F("err_mper_pp", "xe, 0, model = 'pp', mper = 10", "xe, 0, model='pp', mper=10", 'xe, 0; model = "pp", mper = 10')

# Zufallsstichproben aus der GPD (Inversion) in vielen Lagen
GP <- list(); k <- 0
for (sh in c(-0.45, -0.2, -1e-6, 0, 0.05, 0.2, 0.45, 0.9)) for (nn in c(30, 100, 400)) {
  k <- k + 1; set.seed(100 + k); u <- runif(nn); sc <- 0.006 * k / 4
  GP[[k]] <- if (sh == 0) -sc * log(u) else sc * (u^(-sh) - 1) / sh
  se <- k %% 2 == 0
  case(sprintf("fpot_gpd%02d", k), sprintf("SimLev:::.evd_fpot(g, 0, std.err = %s)", se),
       sprintf("result = E.fpot(g, 0, std_err=%s)", if (se) "True" else "False"), list(g = GP[[k]]),
       jl = sprintf("result = E.fpot(g, 0; std_err = %s)", if (se) "true" else "false"))
}

# nlgpd direkt (Grenzfall |shape| <= DBL_EPSILON^0.3, Strafwert)
NL <- function(id, sc, sh, thr = "0")
  case(paste0("nlgpd_", id), sprintf(".Call(SimLev:::C_evd_nlgpd, as.double(xs), length(xs), %s, %s, %s)", thr, sc, sh),
       sprintf("result = E.nlgpd(xs.tolist(), %s, %s, %s)", thr, sc, sh), I,
       jl = sprintf("result = E.nlgpd(xs, %s, %s, %s)", thr, sc, sh))
NL("exp", "0.007", "0")
NL("eps_in", "0.007", "2.0416e-5")
NL("eps_out", "0.007", "2.0417e-5")
NL("neg_eps", "0.007", "-2.0416e-5")
NL("pos", "0.006", "0.25")
NL("neg", "0.009", "-0.3")
NL("support", "0.001", "-0.5")
NL("scale0", "0", "0.1")
NL("scale_neg", "-1", "0.1")
NL("thr", "0.004", "0.1", thr = "0.001")

# ── .fit_tail (GPD-Weg) ─────────────────────────────────────────────────────
set.seed(11); br1 <- 1 + rnorm(1000, 3e-4, 0.011)
set.seed(12); br2 <- 1 + 0.008 * rt(1500, 3)
set.seed(13); br3 <- 1 + rnorm(250, 0, 0.01)                 # ne < 30: Momente
set.seed(14); br4 <- 1 + c(rnorm(900, 0, 0.01), -abs(rcauchy(100, 0, 0.02)))
br4[br4 <= 0.05] <- 0.05
set.seed(15); br5 <- 1e-309 * rnorm(400)                     # Denormale: optim scheitert
set.seed(16); br6 <- 1 + c(rnorm(950, 0, 0.01), 0.01 * abs(rcauchy(50))^3)
IT <- list(br1 = br1, br2 = br2, br3 = br3, br4 = br4, br5 = br5, br6 = br6)
T <- function(id, br, prob, side)
  case(paste0("tail_", id), sprintf("SimLev:::.fit_tail(%s, %s, '%s')", br, prob, side),
       sprintf("result = B._fit_tail(%s, %s, '%s')", br, prob, side), IT,
       jl = sprintf('result = B._fit_tail(%s, %s, "%s")', br, prob, side))
T("n_left", "br1", "0.05", "left")
T("n_right", "br1", "0.05", "right")
T("n_left10", "br1", "0.1", "left")
T("n_30", "br1", "0.03", "left")
T("n_29", "br1", "0.029", "left")
T("t_left", "br2", "0.05", "left")
T("t_right", "br2", "0.02", "right")
T("short", "br3", "0.05", "left")
T("short_mle", "br3", "0.15", "right")
T("cauchy_left", "br4", "0.1", "left")
T("cauchy_right", "br4", "0.1", "right")
T("denorm", "br5", "0.1", "left")
T("heavy_right", "br6", "0.05", "right")
for (k in 1:12) {
  set.seed(200 + k); nb <- c(600, 900, 1500, 2000)[(k - 1) %% 4 + 1]; df <- 2 + (k %% 5)
  brk <- 1 + 0.01 * rt(nb, df) / sqrt(df / (df - 2 + 0.5))
  case(sprintf("tail_rand%02d", k), sprintf("list(SimLev:::.fit_tail(b, %s, 'left'), SimLev:::.fit_tail(b, %s, 'right'))", 0.02 + 0.01 * (k %% 4), 0.02 + 0.01 * (k %% 3)),
       sprintf("result = [B._fit_tail(b, %s, 'left'), B._fit_tail(b, %s, 'right')]", 0.02 + 0.01 * (k %% 4), 0.02 + 0.01 * (k %% 3)), list(b = brk),
       jl = sprintf('result = [B._fit_tail(b, %s, "left"), B._fit_tail(b, %s, "right")]', 0.02 + 0.01 * (k %% 4), 0.02 + 0.01 * (k %% 3)))
}

# ── öffentliche API: bootstrap(…, "evt") ───────────────────────────────────
set.seed(5); n <- 400
us <- 1 + rnorm(n, 3e-4, 0.011)
d <- data.frame(us = us, eu = us * (1 + rnorm(n, 0, 0.004)), rate = 2 + cumsum(rnorm(n, 0, 0.005)))
set.seed(17); n2 <- 1200
d2 <- data.frame(a = 1 + 0.009 * rt(n2, 3), b = 1 + rnorm(n2, 0, 0.012))
d2$b <- d2$b * (1 + 0.3 * (d2$a - 1))
IB <- list(d = d, d2 = d2)
CFG_R <- "cfg <- bootstrap_config(c(us = 'us', eu = 'eu'), regime_index = 'us', aux = c(rate = 'rate'))\n"
CFG_P <- "cfg = bootstrap_config({'us': 'us', 'eu': 'eu'}, regime_index='us', aux={'rate': 'rate'})\n"
CFG_J <- 'cfg = bootstrap_config((us = "us", eu = "eu"), regime_index = "us", aux = (rate = "rate",))\n'
C2_R <- "cfg2 <- bootstrap_config(c(a = 'a', b = 'b'))\n"
C2_P <- "cfg2 = bootstrap_config({'a': 'a', 'b': 'b'})\n"
C2_J <- 'cfg2 = bootstrap_config((a = "a", b = "b"))\n'
BS <- function(id, cr, cp, cj, dat, cfg, extra = "", pextra = "", jextra = "", n = 2, seed = 1)
  case(paste0("bs_", id), paste0(cr, sprintf("bootstrap(%s, %s, 'evt', n = %d, seed = %d, progress = FALSE%s)", dat, cfg, n, seed, extra)),
       paste0(cp, sprintf("result = bootstrap(%s, %s, method='evt', n=%d, seed=%d, progress=False%s)", dat, cfg, n, seed, pextra)), IB,
       jl = paste0(cj, sprintf('result = bootstrap(%s, %s, "evt"; n = %d, seed = %d, progress = false%s)', dat, cfg, n, seed, jextra)))
BS("evt", CFG_R, CFG_P, CFG_J, "d", "cfg")
BS("evt_p10", CFG_R, CFG_P, CFG_J, "d", "cfg", ", params = list(tail_prob = 0.1, both_tails = FALSE)",
   ", params={'tail_prob': 0.1, 'both_tails': False}", ", params = (tail_prob = 0.1, both_tails = false)")
BS("evt_p03", CFG_R, CFG_P, CFG_J, "d", "cfg", ", params = list(tail_prob = 0.03)", ", params={'tail_prob': 0.03}",
   ", params = (tail_prob = 0.03,)")
BS("evt_t", C2_R, C2_P, C2_J, "d2", "cfg2", ", path_length = 300", ", path_length=300", ", path_length = 300", seed = 3)
BS("evt_t_both", C2_R, C2_P, C2_J, "d2", "cfg2", ", params = list(tail_prob = 0.08, both_tails = TRUE), path_length = 200",
   ", params={'tail_prob': 0.08, 'both_tails': True}, path_length=200", ", params = (tail_prob = 0.08, both_tails = true), path_length = 200",
   n = 3, seed = 4)
BS("evt_ess", C2_R, C2_P, C2_J, "d2", "cfg2", ", ess = TRUE, ess_grid = list(tail_prob = c(0.02, 0.1)), path_length = 100",
   ", ess=True, ess_grid={'tail_prob': [0.02, 0.1]}, path_length=100", ", ess = true, ess_grid = (tail_prob = [0.02, 0.1],), path_length = 100",
   n = 4, seed = 5)
# bootstrap_study mit Tail-Modell
set.seed(1); ns <- 2 * 365
ds <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = ns))
ds$aktien <- 100 * cumprod(1 + 0.01 * rt(ns, 3) / sqrt(3)); ds$zins <- 2
SR <- "cfgs <- bootstrap_config(c(akt = 'aktien'), aux = c(zins = 'zins'), input = 'prices')\nstrats <- list(bnh = create_strategy(akt = asset_config('etf', 'bnh', spread = 0.1)))\n"
SP <- "import simlev\ncfgs = bootstrap_config({'akt': 'aktien'}, aux={'zins': 'zins'}, input='prices')\nstrats = {'bnh': simlev.create_strategy(akt=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.1))}\n"
SJ <- 'cfgs = bootstrap_config((akt = "aktien",), aux = (zins = "zins",), input = "prices")\nstrats = (bnh = create_strategy(akt = asset_config("etf", "bnh", spread = 0.1)),)\n'
case("study_evt", paste0(SR, "st <- bootstrap_study(ds, cfgs, 'evt', n = 2, path_length = 300, seed = 1, progress = FALSE, strategies = strats, params = list(both_tails = TRUE)); st$elapsed <- 0; st"),
     paste0(SP, "st = bootstrap_study(ds, cfgs, 'evt', n=2, path_length=300, seed=1, progress=False, strategies=strats, params={'both_tails': True}); st['elapsed'] = 0; result = st"), list(ds = ds),
     jl = paste0(SJ, 'st = bootstrap_study(ds, cfgs, "evt"; n = 2, path_length = 300, seed = 1, progress = false, strategies = strats, params = (both_tails = true,)); st["elapsed"] = 0; result = st'))
ref_done()
