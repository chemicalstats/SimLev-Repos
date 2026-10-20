# Referenzfälle für simlev._r.stats (und Ergänzungen in simlev._r.base).
# Aufruf aus der Repo-Wurzel:
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript golden/modules/gen_r_stats.R
source("golden/modules/ref_tools.R")
ref_init("r_stats")

HDR <- "import math\nimport simlev._r.stats as st\nimport simlev._r.base as rb\n"
JHDR <- "const st = SL.RStats\nconst rb = SL.RBase\n"
cs <- function(id, r, py, inputs = list(), jl = NULL, ...)
  ref_case(id, r = r, py = paste0(HDR, py), inputs = inputs, jl = if (is.null(jl)) NULL else paste0(JHDR, jl), ...)

set.seed(11)
x1 <- rnorm(37); x2 <- round(rnorm(40) * 3)            # x2 mit Bindungen
x3 <- c(4.5, 1.25); x4 <- 2.5; xna <- c(x1[1:9], NA, x1[10:20])
y1 <- 0.4 * x1 + rnorm(37); y2 <- round(x2 + rnorm(40))
M <- matrix(rnorm(60), 20, 3); colnames(M) <- c("a", "b", "c")
Mna <- M; Mna[c(3, 17), 1] <- NA; Mna[5, 3] <- NA
Mu <- unname(matrix(round(rnorm(48) * 2), 12, 4))
pr <- c(0, 0.013, 0.25, 0.5, 2/3, 0.9, 0.999, 1)

## ── quantile / median ───────────────────────────────────────────────────
for (t in 1:9) {
  cs(sprintf("quantile_t%d_a", t), sprintf("quantile(x, pr, type = %d)", t),
     sprintf("result = st.quantile(x, pr, type=%d)", t), list(x = x1, pr = pr),
     jl = sprintf("result = st.quantile(x, pr; type = %d)", t))
  cs(sprintf("quantile_t%d_ties", t), sprintf("quantile(x, pr, type = %d, names = FALSE)", t),
     sprintf("result = st.quantile(x, pr, type=%d, names=False)", t), list(x = x2, pr = pr),
     jl = sprintf("result = st.quantile(x, pr; type = %d, names = false)", t))
  cs(sprintf("quantile_t%d_n2", t), sprintf("quantile(x, c(0.1, 0.5, 0.77), type = %d)", t),
     sprintf("result = st.quantile(x, [0.1, 0.5, 0.77], type=%d)", t), list(x = x3),
     jl = sprintf("result = st.quantile(x, [0.1, 0.5, 0.77]; type = %d)", t))
}
cs("quantile_default", "quantile(x)", "result = st.quantile(x)", list(x = x1), jl = "result = st.quantile(x)")
cs("quantile_n1", "quantile(x, c(0.3, 0.9))", "result = st.quantile(x, [0.3, 0.9])", list(x = x4), jl = "result = st.quantile(x, [0.3, 0.9])")
cs("quantile_probsNA", "quantile(x, c(0.1, NA, 0.8))", "result = st.quantile(x, [0.1, rb.NA_REAL, 0.8])", list(x = x1), jl = "result = st.quantile(x, [0.1, SL.NA, 0.8])")
cs("quantile_narm", "quantile(x, c(0.05, 0.95), na.rm = TRUE)", "result = st.quantile(x, [0.05, 0.95], na_rm=True)", list(x = xna), jl = "result = st.quantile(x, [0.05, 0.95]; na_rm = true)")
cs("quantile_err_na", "quantile(x, 0.5)", "result = st.quantile(x, 0.5)", list(x = xna), jl = "result = st.quantile(x, 0.5)")
cs("quantile_err_probs", "quantile(x, 1.2)", "result = st.quantile(x, 1.2)", list(x = x1), jl = "result = st.quantile(x, 1.2)")
cs("quantile_scalar", "quantile(x, 0.37, names = FALSE)", "result = st.quantile(x, 0.37, names=False)", list(x = x1), jl = "result = st.quantile(x, 0.37; names = false)")
cs("quantile_names_odd", "quantile(x, c(0.001, 0.0125, 1/3, 0.99999))",
   "result = st.quantile(x, [0.001, 0.0125, 1/3, 0.99999])", list(x = x1), jl = "result = st.quantile(x, [0.001, 0.0125, 1/3, 0.99999])")
cs("quantile_empty", "quantile(x, 0.5)", "result = st.quantile(x, 0.5)", list(x = numeric(0)), jl = "result = st.quantile(x, 0.5)")
cs("median_odd", "median(x)", "result = st.median(x)", list(x = x1), jl = "result = st.median(x)")
cs("median_even", "median(x)", "result = st.median(x)", list(x = x1[1:36]), jl = "result = st.median(x)")
cs("median_na", "median(x)", "result = st.median(x)", list(x = xna), jl = "result = st.median(x)")
cs("median_narm", "median(x, na.rm = TRUE)", "result = st.median(x, na_rm=True)", list(x = xna), jl = "result = st.median(x; na_rm = true)")
cs("median_int", "median(c(3L, 1L, 4L, 2L))", "result = st.median(np.array([3, 1, 4, 2]))", jl = "result = st.median([3, 1, 4, 2])")

## ── var / sd / cov / cor ─────────────────────────────────────────────────
cs("var_vec", "var(x)", "result = st.var(x)", list(x = x1), jl = "result = st.var(x)")
cs("var_na", "var(x)", "result = st.var(x)", list(x = xna), jl = "result = st.var(x)")
cs("var_narm", "var(x, na.rm = TRUE)", "result = st.var(x, na_rm=True)", list(x = xna), jl = "result = st.var(x; na_rm = true)")
cs("var_n1", "var(x)", "result = st.var(x)", list(x = x4), jl = "result = st.var(x)")
cs("var_mat", "var(M)", "result = st.var(M)", list(M = M), jl = "result = st.var(M)")
cs("var_xy", "var(x, y)", "result = st.var(x, y)", list(x = x1, y = y1), jl = "result = st.var(x, y)")
cs("sd_vec", "sd(x)", "result = st.sd(x)", list(x = x1), jl = "result = st.sd(x)")
cs("sd_narm", "sd(x, na.rm = TRUE)", "result = st.sd(x, na_rm=True)", list(x = xna), jl = "result = st.sd(x; na_rm = true)")
cs("sd_big", "sd(x)", "result = st.sd(x)", list(x = 1e8 + x1), jl = "result = st.sd(x)")
for (m in c("pearson", "kendall", "spearman")) {
  for (u in c("everything", "complete.obs", "pairwise.complete.obs", "na.or.complete", "all.obs")) {
    cs(sprintf("cor_M_%s_%s", m, u), sprintf('cor(M, use = "%s", method = "%s")', u, m),
       sprintf('result = st.cor(M, use="%s", method="%s")', u, m), list(M = Mna),
       jl = sprintf('result = st.cor(M; use = "%s", method = "%s")', u, m))
  }
  cs(sprintf("cor_xy_%s", m), sprintf('cor(x, y, method = "%s")', m), sprintf('result = st.cor(x, y, method="%s")', m),
     list(x = x2, y = y2), jl = sprintf('result = st.cor(x, y; method = "%s")', m))
  cs(sprintf("cor_Mu_%s", m), sprintf('cor(M, method = "%s")', m), sprintf('result = st.cor(M, method="%s")', m), list(M = Mu), jl = sprintf('result = st.cor(M; method = "%s")', m))
  cs(sprintf("cor_My_%s", m), sprintf('cor(M, y, method = "%s", use = "complete.obs")', m),
     sprintf('result = st.cor(M, y, method="%s", use="complete.obs")', m), list(M = Mna, y = rnorm(20)), jl = sprintf('result = st.cor(M, y; method = "%s", use = "complete.obs")', m))
  cs(sprintf("cov_%s", m), sprintf('cov(M, method = "%s")', m), sprintf('result = st.cov(M, method="%s")', m), list(M = M), jl = sprintf('result = st.cov(M; method = "%s")', m))
  cs(sprintf("cov_xy_%s", m), sprintf('cov(x, y, method = "%s")', m), sprintf('result = st.cov(x, y, method="%s")', m),
     list(x = x1, y = y1), jl = sprintf('result = st.cov(x, y; method = "%s")', m))
}
cs("cor_df", "cor(d)", "result = st.cor(d)", list(d = as.data.frame(M)), jl = "result = st.cor(d)")
cs("cor_sd0", "cor(x, rep(1, 37))", "result = st.cor(x, np.ones(37))", list(x = x1), jl = "result = st.cor(x, ones(37))")
cs("cor_sd0_mat", "cor(cbind(x, 1))", "result = st.cor(np.column_stack([x, np.ones(37)]))", list(x = x1), jl = "result = st.cor(hcat(x, ones(37)))")
cs("cor_err_use", 'cor(x, y, use = "foo")', 'result = st.cor(x, y, use="foo")', list(x = x1, y = y1), jl = "result = st.cor(x, y; use = \"foo\")")
cs("cor_err_dims", "cor(x, y)", "result = st.cor(x, y)", list(x = x1, y = y1[1:30]), jl = "result = st.cor(x, y)")
cs("cor_err_supply", "cor(x)", "result = st.cor(x)", list(x = x1), jl = "result = st.cor(x)")
cs("cor_err_allobs", 'cor(x, y, use = "all.obs")', 'result = st.cor(x, y, use="all.obs")', list(x = xna, y = xna + 1), jl = "result = st.cor(x, y; use = \"all.obs\")")
cs("cor_pair1col", 'cor(M[, 1, drop = FALSE], method = "kendall", use = "pairwise.complete.obs")',
   'result = st.cor(M.iloc[:, :1], method="kendall", use="pairwise.complete.obs")', list(M = M), jl = "result = st.cor(M.data[:, 1:1]; method = \"kendall\", use = \"pairwise.complete.obs\")")
cs("cov_err_pair", 'cov(M, method = "spearman", use = "pairwise.complete.obs")',
   'result = st.cov(M, method="spearman", use="pairwise.complete.obs")', list(M = M), jl = "result = st.cov(M; method = \"spearman\", use = \"pairwise.complete.obs\")")
cs("cov2cor_a", "cov2cor(cov(M))", "result = st.cov2cor(st.cov(M))", list(M = M), jl = "result = st.cov2cor(st.cov(M))")
cs("cov2cor_warn", "cov2cor(matrix(c(1, 0.5, 0.5, -1), 2))", "result = st.cov2cor(np.array([[1, 0.5], [0.5, -1.]]))", jl = "result = st.cov2cor([1 0.5; 0.5 -1.0])")
cs("wmean_a", "weighted.mean(x, w)", "result = st.weighted_mean(x, w)", list(x = x1, w = runif(37)), jl = "result = st.weighted_mean(x, w)")
cs("wmean_zero", "weighted.mean(x, w)", "result = st.weighted_mean(x, w)", list(x = c(1, NA, 3), w = c(1, 0, 2)), jl = "result = st.weighted_mean(x, w)")
cs("wmean_isnan", "r <- c(weighted.mean(c(1, 2), c(0, 0)), weighted.mean(c(NA, 2), c(1, 0)), weighted.mean(numeric(0))); c(is.na(r), is.nan(r))",
   "import simlev._r.fmt as fm\nr = [st.weighted_mean([1, 2], [0, 0]), st.weighted_mean([fm.NA_REAL, 2], [1, 0]), st.weighted_mean(np.zeros(0))]\nresult = np.array([x != x for x in r] + [fm._is_rnan(x) for x in r])", jl = "r = [st.weighted_mean([1.0, 2], [0.0, 0]), st.weighted_mean([SL.NA, 2], [1.0, 0]), st.weighted_mean(Float64[])]\nresult = vcat(isnan.(r), [isnan(v) && !SL.isna_strict(v) for v in r])")
cs("cov2cor_isnan", "r <- suppressWarnings(cov2cor(matrix(c(1, 0.5, 0.2, 0.5, -1, 0, 0.2, 0, 0), 3))); r[1, 1] <- NA; c(r, is.nan(r))",
   "import simlev._r.fmt as fm\nimport warnings\nwith warnings.catch_warnings():\n    warnings.simplefilter('ignore')\n    r = st.cov2cor(np.array([[1, 0.5, 0.2], [0.5, -1, 0], [0.2, 0, 0.]]))\nr[0, 0] = fm.NA_REAL\nresult = np.concatenate([r.ravel(order='F'), fm._nan_mask(r.ravel(order='F'))])", jl = "import Logging\nr = Logging.with_logger(Logging.NullLogger()) do\n    st.cov2cor([1 0.5 0.2; 0.5 -1 0; 0.2 0 0.0])\nend\nr[1, 1] = SL.NA\nresult = vcat(vec(r), [Float64(isnan(v) && !SL.isna_strict(v)) for v in vec(r)])")
cs("cov2cor_na", "r <- suppressWarnings(cov2cor(matrix(c(2, NA, 0.2, NA, -1, 0, 0.2, 0, NA), 3))); c(r, is.nan(r))",
   "import simlev._r.fmt as fm\nimport warnings\nwith warnings.catch_warnings():\n    warnings.simplefilter('ignore')\n    r = st.cov2cor(np.array([[2, fm.NA_REAL, 0.2], [fm.NA_REAL, -1, 0], [0.2, 0, fm.NA_REAL]]))\nresult = np.concatenate([r.ravel(order='F'), fm._nan_mask(r.ravel(order='F'))])", jl = "import Logging\nr = Logging.with_logger(Logging.NullLogger()) do\n    st.cov2cor([2 SL.NA 0.2; SL.NA -1 0; 0.2 0 SL.NA])\nend\nresult = vcat(vec(r), [Float64(isnan(v) && !SL.isna_strict(v)) for v in vec(r)])")
cs("wmean_narm", "weighted.mean(x, w, na.rm = TRUE)", "result = st.weighted_mean(x, w, na_rm=True)",
   list(x = xna, w = runif(21)), jl = "result = st.weighted_mean(x, w; na_rm = true)")
cs("wmean_now", "weighted.mean(x)", "result = st.weighted_mean(x)", list(x = x1), jl = "result = st.weighted_mean(x)")
cs("scale_default", "scale(M)", "result = st.scale(M)", list(M = unname(M)), jl = "result = st.scale(M)")
cs("scale_noc", "scale(M, center = FALSE)", "result = st.scale(M, center=False)", list(M = unname(Mna)), jl = "result = st.scale(M; center = false)")
cs("scale_num", "scale(M, center = c(1, 2, 3), scale = c(2, 2, 0.5))",
   "result = st.scale(M, center=[1, 2, 3], scale=[2, 2, 0.5])", list(M = unname(M)), jl = "result = st.scale(M; center = [1, 2, 3], scale = [2, 2, 0.5])")

## ── approx / approxfun / filter ──────────────────────────────────────────
ax <- c(1, 2, 2.5, 4, 7, 8.25); ay <- c(3, -1, 0.5, 2, 2.2, 10)
xo <- c(-1, 1, 1.7, 2.5, 3.99, 7.5, 8.25, 9, NA)
cs("approx_lin", "approx(x, y, xout = xo)", "result = st.approx(x, y, xout=xo)", list(x = ax, y = ay, xo = xo), jl = "result = st.approx(x, y; xout = xo)")
cs("approx_rule2", "approx(x, y, xout = xo, rule = 2)", "result = st.approx(x, y, xout=xo, rule=2)",
   list(x = ax, y = ay, xo = xo), jl = "result = st.approx(x, y; xout = xo, rule = 2)")
cs("approx_rule12", "approx(x, y, xout = xo, rule = c(1, 2))", "result = st.approx(x, y, xout=xo, rule=[1, 2])",
   list(x = ax, y = ay, xo = xo), jl = "result = st.approx(x, y; xout = xo, rule = [1, 2])")
cs("approx_const", 'approx(x, y, xout = xo, method = "constant", f = 0.25, rule = 2)',
   'result = st.approx(x, y, xout=xo, method="constant", f=0.25, rule=2)', list(x = ax, y = ay, xo = xo), jl = "result = st.approx(x, y; xout = xo, method = \"constant\", f = 0.25, rule = 2)")
cs("approx_n", "approx(x, y, n = 11)", "result = st.approx(x, y, n=11)", list(x = ax, y = ay), jl = "result = st.approx(x, y; n = 11)")
cs("approx_unsorted_ties", "approx(x, y, xout = c(0.5, 1.5, 3))", "result = st.approx(x, y, xout=[0.5, 1.5, 3])",
   list(x = c(3, 1, 2, 1, 3), y = c(1, 2, 3, 4, 5)), jl = "result = st.approx(x, y; xout = [0.5, 1.5, 3])")
cs("approx_ties_ordered", 'approx(x, y, xout = c(1.5, 2.5), ties = "ordered")',
   'result = st.approx(x, y, xout=[1.5, 2.5], ties="ordered")', list(x = c(1, 2, 3), y = c(5, 1, 4)), jl = "result = st.approx(x, y; xout = [1.5, 2.5], ties = \"ordered\")")
cs("approx_yleft", "approx(x, y, xout = xo, yleft = -5, yright = 99)", "result = st.approx(x, y, xout=xo, yleft=-5, yright=99)",
   list(x = ax, y = ay, xo = xo), jl = "result = st.approx(x, y; xout = xo, yleft = -5, yright = 99)")
cs("approx_na", "approx(x, y, xout = c(1.5, 3.5))", "result = st.approx(x, y, xout=[1.5, 3.5])",
   list(x = c(1, 2, NA, 4), y = c(1, NA, 3, 8)), jl = "result = st.approx(x, y; xout = [1.5, 3.5])")
cs("approx_err_one", "approx(1, 2, xout = 1)", "result = st.approx([1.0], [2.0], xout=1.0)", jl = "result = st.approx([1.0], [2.0]; xout = 1.0)")
cs("approx_err_f", 'approx(x, y, method = "constant", f = 2)', 'result = st.approx(x, y, method="constant", f=2)',
   list(x = ax, y = ay), jl = "result = st.approx(x, y; method = \"constant\", f = 2)")
cs("approxfun_a", "f <- approxfun(x, y, rule = 2); f(xo)", "f = st.approxfun(x, y, rule=2)\nresult = f(xo)",
   list(x = ax, y = ay, xo = xo), jl = "f = st.approxfun(x, y; rule = 2)\nresult = f(xo)")
fx <- c(1.5, NA, 3, 2, 5, 4, 4.5, 7, 6, 8, 9.5, 9)
cs("filter_conv2", "as.vector(filter(x, rep(1/3, 3)))", "result = st.filter(x, np.full(3, 1/3))", list(x = x1), jl = "result = st.r_filter(x, fill(1/3, 3))")
cs("filter_conv1", "as.vector(filter(x, c(0.5, 0.3, 0.2), sides = 1))", "result = st.filter(x, [0.5, 0.3, 0.2], sides=1)", list(x = x1), jl = "result = st.r_filter(x, [0.5, 0.3, 0.2]; sides = 1)")
cs("filter_conv_even", "as.vector(filter(x, c(0.25, 0.25, 0.25, 0.25)))", "result = st.filter(x, [0.25]*4)", list(x = fx), jl = "result = st.r_filter(x, fill(0.25, 4))")
cs("filter_circ", "as.vector(filter(x, c(1, -2, 1), circular = TRUE))", "result = st.filter(x, [1, -2, 1], circular=True)", list(x = x1), jl = "result = st.r_filter(x, [1, -2, 1]; circular = true)")
cs("filter_rec", 'as.vector(filter(x, 0.7, method = "recursive"))', 'result = st.filter(x, 0.7, method="recursive")', list(x = x1), jl = "result = st.r_filter(x, 0.7; method = \"recursive\")")
cs("filter_rec_init", 'as.vector(filter(x, c(0.5, -0.2), method = "recursive", init = c(1, 2)))',
   'result = st.filter(x, [0.5, -0.2], method="recursive", init=[1, 2])', list(x = x1), jl = "result = st.r_filter(x, [0.5, -0.2]; method = \"recursive\", init = [1, 2])")
cs("filter_rec_na", 'as.vector(filter(x, 0.9, method = "recursive", init = 3))', 'result = st.filter(x, 0.9, method="recursive", init=3)', list(x = fx), jl = "result = st.r_filter(x, 0.9; method = \"recursive\", init = 3)")
cs("filter_mat", "unclass(filter(M, c(0.5, 0.5), sides = 1))[, ]", "result = st.filter(M, [0.5, 0.5], sides=1)", list(M = unname(M)), jl = "result = st.r_filter(M, [0.5, 0.5]; sides = 1)")
cs("filter_err_long", "filter(1:3, rep(1, 4))", "result = st.filter(np.arange(1, 4), np.ones(4))", jl = "result = st.r_filter([1, 2, 3], ones(4))")
cs("filter_err_sides", "filter(x, 1, sides = 3)", "result = st.filter(x, 1, sides=3)", list(x = x1), jl = "result = st.r_filter(x, 1; sides = 3)")
cs("filter_err_init", 'filter(x, c(1, 2), method = "recursive", init = 1)', 'result = st.filter(x, [1, 2], method="recursive", init=1)', list(x = x1), jl = "result = st.r_filter(x, [1, 2]; method = \"recursive\", init = 1)")

## ── optimize / uniroot ──────────────────────────────────────────────────
cs("optimize_a", "optimize(function(x) (x - 0.37)^2 + sin(3 * x), c(-1, 2))",
   "result = st.optimize(lambda x: (x - 0.37)*(x - 0.37) + math.sin(3*x), (-1, 2))", jl = "result = st.optimize(x -> (x - 0.37)*(x - 0.37) + SL.RLibm.sin(3*x), [-1, 2])")
cs("optimize_tol", "optimize(function(x) abs(x - 1/3) + 0.1 * x^2, lower = -5, upper = 5, tol = 1e-10)",
   "result = st.optimize(lambda x: abs(x - 1/3) + 0.1*(x*x), lower=-5, upper=5, tol=1e-10)", jl = "result = st.optimize(x -> abs(x - 1/3) + 0.1*(x*x); lower = -5, upper = 5, tol = 1e-10)")
cs("optimize_max", "optimize(function(x) x * exp(-x), c(0, 4), maximum = TRUE)",
   "result = st.optimize(lambda x: x*math.exp(-x), (0, 4), maximum=True)", jl = "result = st.optimize(x -> x*SL.RLibm.exp(-x), [0, 4]; maximum = true)")
cs("optimize_na", "optimize(function(x) if (x < 0.5) NA else (x - 1)^2, c(0, 3))",
   "result = st.optimize(lambda x: float('nan') if x < 0.5 else (x - 1)*(x - 1), (0, 3))", jl = "result = st.optimize(x -> x < 0.5 ? SL.NA : (x - 1)*(x - 1), [0, 3])")
cs("optimize_err", "optimize(function(x) x^2, c(1, 1))", "result = st.optimize(lambda x: x*x, (1, 1))", jl = "result = st.optimize(x -> x*x, [1, 1])")
cs("uniroot_a", "uniroot(function(x) x^3 - x - 1, c(1, 2))",
   "result = st.uniroot(lambda x: math.pow(x, 3) - x - 1, (1, 2))", jl = "result = st.uniroot(x -> SL.RLibm.pow(x, 3) - x - 1, [1, 2])")
cs("uniroot_tol", "uniroot(function(x) cos(x) - x, c(-pi, pi), tol = 1e-12)",
   "result = st.uniroot(lambda x: math.cos(x) - x, (-math.pi, math.pi), tol=1e-12)", jl = "result = st.uniroot(x -> SL.RLibm.cos(x) - x, [-pi, pi]; tol = 1e-12)")
cs("uniroot_fl", "uniroot(function(x) exp(x) - 3, lower = 0, upper = 2, f.lower = -2, f.upper = exp(2) - 3)",
   "result = st.uniroot(lambda x: math.exp(x) - 3, lower=0, upper=2, f_lower=-2, f_upper=math.exp(2) - 3)", jl = "result = st.uniroot(x -> SL.RLibm.exp(x) - 3; lower = 0, upper = 2, f_lower = -2, f_upper = SL.RLibm.exp(2.0) - 3)")
cs("uniroot_ext_yes", 'uniroot(function(x) exp(x) - 50, c(0, 1), extendInt = "yes")',
   'result = st.uniroot(lambda x: math.exp(x) - 50, (0, 1), extendInt="yes")', jl = "result = st.uniroot(x -> SL.RLibm.exp(x) - 50, [0, 1]; extendInt = \"yes\")")
cs("uniroot_ext_up", 'uniroot(function(x) x - 10.5, c(0, 1), extendInt = "upX")',
   'result = st.uniroot(lambda x: x - 10.5, (0, 1), extendInt="upX")', jl = "result = st.uniroot(x -> x - 10.5, [0, 1]; extendInt = \"upX\")")
cs("uniroot_ext_down", 'uniroot(function(x) 3 - x, c(5, 6), extendInt = "downX")',
   'result = st.uniroot(lambda x: 3 - x, (5, 6), extendInt="downX")', jl = "result = st.uniroot(x -> 3 - x, [5, 6]; extendInt = \"downX\")")
cs("uniroot_maxit", "uniroot(function(x) x^3 - x - 1, c(1, 2), maxiter = 3)",
   "result = st.uniroot(lambda x: math.pow(x, 3) - x - 1, (1, 2), maxiter=3)", jl = "result = st.uniroot(x -> SL.RLibm.pow(x, 3) - x - 1, [1, 2]; maxiter = 3)")
cs("uniroot_endroot", "uniroot(function(x) x - 1, c(1, 2))", "result = st.uniroot(lambda x: x - 1, (1, 2))", jl = "result = st.uniroot(x -> x - 1, [1, 2])")
cs("uniroot_err_sign", "uniroot(function(x) x^2 + 1, c(-1, 2))", "result = st.uniroot(lambda x: x*x + 1, (-1, 2))", jl = "result = st.uniroot(x -> x*x + 1, [-1, 2])")
cs("uniroot_err_lu", "uniroot(function(x) x, lower = 2, upper = 1)", "result = st.uniroot(lambda x: x, lower=2, upper=1)", jl = "result = st.uniroot(x -> x; lower = 2, upper = 1)")
cs("uniroot_inf", "uniroot(function(x) if (x > 1.9) Inf else x - 1, c(0, 2))",
   "result = st.uniroot(lambda x: math.inf if x > 1.9 else x - 1, (0, 2))", jl = "result = st.uniroot(x -> x > 1.9 ? Inf : x - 1, [0, 2])")

## ── optim ────────────────────────────────────────────────────────────────
FR_R <- "fr <- function(x) 100 * (x[2] - x[1] * x[1])^2 + (1 - x[1])^2; grr <- function(x) c(-400 * x[1] * (x[2] - x[1] * x[1]) - 2 * (1 - x[1]), 200 * (x[2] - x[1] * x[1]));"
FR_P <- "def fr(x):\n    a = x[1] - x[0]*x[0]; b = 1 - x[0]\n    return 100*(a*a) + b*b\ndef grr(x):\n    return np.array([-400*x[0]*(x[1] - x[0]*x[0]) - 2*(1 - x[0]), 200*(x[1] - x[0]*x[0])])\n"
FQ_R <- "fq <- function(x) { s <- 0; for (i in seq_along(x)) s <- s + (i * (x[i] - i/3))^2 + exp(0.1 * x[i]); s };"
FR_J <- "fr(x) = (a = x[2] - x[1]*x[1]; b = 1 - x[1]; 100*(a*a) + b*b)\ngrr(x) = [-400*x[1]*(x[2] - x[1]*x[1]) - 2*(1 - x[1]), 200*(x[2] - x[1]*x[1])]\n"
FQ_J <- "function fq(x)\n    s = 0.0\n    for i in 1:length(x)\n        t = i*(x[i] - i/3)\n        s = s + t*t + SL.RLibm.exp(0.1*x[i])\n    end\n    s\nend\n"
FQ_P <- "def fq(x):\n    s = 0.0\n    for i in range(len(x)):\n        t = (i + 1)*(x[i] - (i + 1)/3)\n        s = s + t*t + math.exp(0.1*x[i])\n    return s\n"
OPT <- "o <- %s; o[c('par', 'value', 'counts', 'convergence', 'message')]"
for (meth in c("Nelder-Mead", "BFGS", "CG", "L-BFGS-B")) {
  mm <- gsub("-", "", meth)
  cs(paste0("optim_fr_", mm), paste0(FR_R, sprintf(OPT, sprintf('optim(c(-1.2, 1), fr, method = "%s")', meth))),
     paste0(FR_P, sprintf('result = st.optim(np.array([-1.2, 1]), fr, method="%s")', meth)),
     jl = paste0(FR_J, sprintf('result = st.optim([-1.2, 1.0], fr; method = "%s")', meth)))
  if (meth != "Nelder-Mead")
    cs(paste0("optim_frgr_", mm), paste0(FR_R, sprintf(OPT, sprintf('optim(c(-1.2, 1), fr, grr, method = "%s")', meth))),
       paste0(FR_P, sprintf('result = st.optim(np.array([-1.2, 1]), fr, grr, method="%s")', meth)),
       jl = paste0(FR_J, sprintf('result = st.optim([-1.2, 1.0], fr, grr; method = "%s")', meth)))
  cs(paste0("optim_fq_", mm), paste0(FQ_R, sprintf(OPT, sprintf('optim(c(0.5, -0.3, 1, 2), fq, method = "%s", control = list(maxit = 300, parscale = c(1, 2, 0.5, 1), fnscale = 2))', meth))),
     paste0(FQ_P, sprintf('result = st.optim(np.array([0.5, -0.3, 1, 2]), fq, method="%s", control={"maxit": 300, "parscale": [1, 2, 0.5, 1], "fnscale": 2})', meth)),
     jl = paste0(FQ_J, sprintf('result = st.optim([0.5, -0.3, 1, 2], fq; method = "%s", control = Dict("maxit" => 300, "parscale" => [1, 2, 0.5, 1], "fnscale" => 2))', meth)))
}
for (ty in 1:3)
  cs(sprintf("optim_cg_type%d", ty), paste0(FQ_R, sprintf(OPT, sprintf('optim(c(0.5, -0.3, 1), fq, method = "CG", control = list(type = %d, maxit = 500))', ty))),
     paste0(FQ_P, sprintf('result = st.optim(np.array([0.5, -0.3, 1]), fq, method="CG", control={"type": %d, "maxit": 500})', ty)),
     jl = paste0(FQ_J, sprintf('result = st.optim([0.5, -0.3, 1], fq; method = "CG", control = Dict("type" => %d, "maxit" => 500))', ty)))
cs("optim_lbfgsb_box", paste0(FQ_R, sprintf(OPT, 'optim(c(0.5, 0.5, 0.5), fq, method = "L-BFGS-B", lower = c(0.4, -1, 0.7), upper = c(2, 0.1, 0.8))')),
   paste0(FQ_P, 'result = st.optim(np.array([0.5, 0.5, 0.5]), fq, method="L-BFGS-B", lower=[0.4, -1, 0.7], upper=[2, 0.1, 0.8])'), jl = "function fq(x)\n    s = 0.0\n    for i in 1:length(x)\n        t = i*(x[i] - i/3)\n        s = s + t*t + SL.RLibm.exp(0.1*x[i])\n    end\n    s\nend\nresult = st.optim([0.5, 0.5, 0.5], fq; method = \"L-BFGS-B\", lower = [0.4, -1, 0.7], upper = [2, 0.1, 0.8])")
cs("optim_lbfgsb_ctl", paste0(FQ_R, sprintf(OPT, 'optim(c(2, 2, 2, 2, 2), fq, method = "L-BFGS-B", lower = 0, control = list(lmm = 3, factr = 1e3, pgtol = 1e-9, ndeps = rep(1e-4, 5)))')),
   paste0(FQ_P, 'result = st.optim(np.full(5, 2.0), fq, method="L-BFGS-B", lower=0, control={"lmm": 3, "factr": 1e3, "pgtol": 1e-9, "ndeps": np.full(5, 1e-4)})'), jl = "function fq(x)\n    s = 0.0\n    for i in 1:length(x)\n        t = i*(x[i] - i/3)\n        s = s + t*t + SL.RLibm.exp(0.1*x[i])\n    end\n    s\nend\nresult = st.optim(fill(2.0, 5), fq; method = \"L-BFGS-B\", lower = 0, control = Dict(\"lmm\" => 3, \"factr\" => 1e3, \"pgtol\" => 1e-9, \"ndeps\" => fill(1e-4, 5)))")
cs("optim_lbfgsb_maxit", paste0(FR_R, sprintf(OPT, 'optim(c(-1.2, 1), fr, method = "L-BFGS-B", control = list(maxit = 5))')),
   paste0(FR_P, 'result = st.optim(np.array([-1.2, 1]), fr, method="L-BFGS-B", control={"maxit": 5})'), jl = "fr(x) = (a = x[2] - x[1]*x[1]; b = 1 - x[1]; 100*(a*a) + b*b)\ngrr(x) = [-400*x[1]*(x[2] - x[1]*x[1]) - 2*(1 - x[1]), 200*(x[2] - x[1]*x[1])]\nresult = st.optim([-1.2, 1.0], fr; method = \"L-BFGS-B\", control = Dict(\"maxit\" => 5))")
cs("optim_nm_maxit", paste0(FR_R, sprintf(OPT, 'optim(c(-1.2, 1), fr, control = list(maxit = 40))')),
   paste0(FR_P, 'result = st.optim(np.array([-1.2, 1]), fr, control={"maxit": 40})'), jl = "fr(x) = (a = x[2] - x[1]*x[1]; b = 1 - x[1]; 100*(a*a) + b*b)\ngrr(x) = [-400*x[1]*(x[2] - x[1]*x[1]) - 2*(1 - x[1]), 200*(x[2] - x[1]*x[1])]\nresult = st.optim([-1.2, 1.0], fr; control = Dict(\"maxit\" => 40))")
cs("optim_nm_reltol", paste0(FQ_R, sprintf(OPT, 'optim(c(0.1, 0.2, 0.3), fq, control = list(maxit = 2000, reltol = 1e-12, alpha = 1.2, beta = 0.4, gamma = 2.2))')),
   paste0(FQ_P, 'result = st.optim(np.array([0.1, 0.2, 0.3]), fq, control={"maxit": 2000, "reltol": 1e-12, "alpha": 1.2, "beta": 0.4, "gamma": 2.2})'), jl = "function fq(x)\n    s = 0.0\n    for i in 1:length(x)\n        t = i*(x[i] - i/3)\n        s = s + t*t + SL.RLibm.exp(0.1*x[i])\n    end\n    s\nend\nresult = st.optim([0.1, 0.2, 0.3], fq; control = Dict(\"maxit\" => 2000, \"reltol\" => 1e-12, \"alpha\" => 1.2, \"beta\" => 0.4, \"gamma\" => 2.2))")
cs("optim_bfgs_maxit", paste0(FR_R, sprintf(OPT, 'optim(c(-1.2, 1), fr, method = "BFGS", control = list(maxit = 10, abstol = 1e-3))')),
   paste0(FR_P, 'result = st.optim(np.array([-1.2, 1]), fr, method="BFGS", control={"maxit": 10, "abstol": 1e-3})'), jl = "fr(x) = (a = x[2] - x[1]*x[1]; b = 1 - x[1]; 100*(a*a) + b*b)\ngrr(x) = [-400*x[1]*(x[2] - x[1]*x[1]) - 2*(1 - x[1]), 200*(x[2] - x[1]*x[1])]\nresult = st.optim([-1.2, 1.0], fr; method = \"BFGS\", control = Dict(\"maxit\" => 10, \"abstol\" => 1e-3))")
cs("optim_named_par", paste0(FR_R, sprintf(OPT, 'optim(c(a = -1.2, b = 1), fr, method = "BFGS")')),
   paste0(FR_P, 'result = st.optim(pd.Series([-1.2, 1.0], index=["a", "b"]), lambda x: fr(np.asarray(x)), method="BFGS")'), jl = "fr(x) = (a = x[2] - x[1]*x[1]; b = 1 - x[1]; 100*(a*a) + b*b)\ngrr(x) = [-400*x[1]*(x[2] - x[1]*x[1]) - 2*(1 - x[1]), 200*(x[2] - x[1]*x[1])]\nresult = st.optim(SL.named(\"a\" => -1.2, \"b\" => 1.0), fr; method = \"BFGS\")")
cs("optim_hessian", paste0(FQ_R, 'o <- optim(c(0.5, -0.3, 1), fq, method = "BFGS", hessian = TRUE); o[c("par", "value", "hessian")]'),
   paste0(FQ_P, 'result = st.optim(np.array([0.5, -0.3, 1]), fq, method="BFGS", hessian=True)'), jl = "function fq(x)\n    s = 0.0\n    for i in 1:length(x)\n        t = i*(x[i] - i/3)\n        s = s + t*t + SL.RLibm.exp(0.1*x[i])\n    end\n    s\nend\nresult = st.optim([0.5, -0.3, 1], fq; method = \"BFGS\", hessian = true)")
cs("optim_1d_warn", sprintf(OPT, "optim(1, function(x) (x - 2)^2)"), "result = st.optim(1.0, lambda x: (x[0] - 2)*(x[0] - 2))", jl = "result = st.optim(1.0, x -> (x[1] - 2)*(x[1] - 2))")
cs("optim_bounds_warn", paste0(FQ_R, sprintf(OPT, 'optim(c(1, 1), fq, lower = 0.5)')),
   paste0(FQ_P, 'result = st.optim(np.array([1.0, 1.0]), fq, lower=0.5)'), jl = "function fq(x)\n    s = 0.0\n    for i in 1:length(x)\n        t = i*(x[i] - i/3)\n        s = s + t*t + SL.RLibm.exp(0.1*x[i])\n    end\n    s\nend\nresult = st.optim([1.0, 1.0], fq; lower = 0.5)")
cs("optim_unknown_ctl", paste0(FQ_R, sprintf(OPT, 'optim(c(1, 1), fq, control = list(foo = 1))')),
   paste0(FQ_P, 'result = st.optim(np.array([1.0, 1.0]), fq, control={"foo": 1})'), jl = "function fq(x)\n    s = 0.0\n    for i in 1:length(x)\n        t = i*(x[i] - i/3)\n        s = s + t*t + SL.RLibm.exp(0.1*x[i])\n    end\n    s\nend\nresult = st.optim([1.0, 1.0], fq; control = Dict(\"foo\" => 1))")
cs("optim_brent", "o <- optim(1, function(x) (x - 2)^2 + 1, method = 'Brent', lower = -3, upper = 5); o[c('par', 'value', 'counts', 'convergence')]",
   "result = st.optim(1.0, lambda x: (x - 2)*(x - 2) + 1, method='Brent', lower=-3, upper=5)", jl = "result = st.optim(1.0, x -> (x - 2)*(x - 2) + 1; method = \"Brent\", lower = -3, upper = 5)")
cs("optim_err_init", "optim(c(1, 1), function(x) NA)", "result = st.optim(np.array([1.0, 1.0]), lambda x: float('nan'))", jl = "result = st.optim([1.0, 1.0], x -> SL.NA)")
cs("optimhess_a", paste0(FQ_R, "optimHess(c(0.3, 0.2), fq)"), paste0(FQ_P, "result = st.optimhess(np.array([0.3, 0.2]), fq)"), jl = "function fq(x)\n    s = 0.0\n    for i in 1:length(x)\n        t = i*(x[i] - i/3)\n        s = s + t*t + SL.RLibm.exp(0.1*x[i])\n    end\n    s\nend\nresult = st.optimhess([0.3, 0.2], fq)")

## ── lm.fit / lm / poly / glm ─────────────────────────────────────────────
lx <- seq(0, 3, length.out = 25); ly <- 1 + 2 * lx - 0.5 * lx^2 + rnorm(25, sd = 0.2)
X3 <- cbind(1, lx, lx^2); Xd <- cbind(1, lx, 2 * lx, lx^2)
cs("lmfit_a", "z <- lm.fit(X, y); z[c('coefficients', 'residuals', 'effects', 'rank', 'fitted.values', 'df.residual')]",
   "result = st.lm_fit(X, y)", list(X = X3, y = ly), jl = "result = st.lm_fit(X, y)")
cs("lmfit_qr", "z <- lm.fit(X, y); unclass(z$qr)[c('qr', 'qraux', 'pivot', 'tol', 'rank')]",
   "result = st.lm_fit(X, y)['qr']", list(X = X3, y = ly), jl = "result = st.lm_fit(X, y)[\"qr\"]")
cs("lmfit_rankdef", "z <- lm.fit(X, y); z[c('coefficients', 'effects', 'rank', 'fitted.values')]",
   "result = st.lm_fit(X, y)", list(X = Xd, y = ly), jl = "result = st.lm_fit(X, y)")
cs("lmfit_names", "coef(lm.fit(X, y))", "result = st.lm_fit(X, y)['coefficients']",
   list(X = `colnames<-`(X3, c("i", "x", "x2")), y = ly), jl = "result = st.lm_fit(X, y)[\"coefficients\"]")
cs("lmfit_multy", "lm.fit(X, unname(cbind(y, 2 * y + 1)))$coefficients",
   "result = st.lm_fit(X, np.column_stack([y, 2*y + 1]))['coefficients']", list(X = X3, y = ly), jl = "result = st.lm_fit(X, hcat(y, 2 .* y .+ 1))[\"coefficients\"]")
cs("lmfit_err_na", "lm.fit(X, y)", "result = st.lm_fit(X, y)", list(X = X3, y = c(NA, ly[-1])), jl = "result = st.lm_fit(X, y)")
cs("lm_xy", "m <- lm(y ~ x); list(coef = coef(m), fitted = fitted(m), resid = residuals(m))",
   "m = st.lm('y ~ x', env={'x': x, 'y': y})\nresult = {'coef': st.coef(m), 'fitted': st.fitted(m), 'resid': st.residuals(m)}",
   list(x = lx, y = ly), jl = "m = st.lm(\"y ~ x\"; env = Dict(\"x\" => x, \"y\" => y))\nresult = RList(\"coef\" => st.coef(m), \"fitted\" => st.fitted(m), \"resid\" => st.residuals(m))")
for (deg in 1:3)
  cs(sprintf("lm_poly%d", deg),
     sprintf("d <- data.frame(forward = y, signal = x); m <- stats::lm(forward ~ stats::poly(signal, %d), data = d); list(coef = coef(m), fitted = fitted(m), r2 = summary(m)$r.squared)", deg),
     sprintf("d = pd.DataFrame({'forward': y, 'signal': x})\nm = st.lm('forward ~ stats::poly(signal, %d)', data=d)\nresult = {'coef': st.coef(m), 'fitted': st.fitted(m), 'r2': st.summary_lm(m)['r.squared']}", deg),
     list(x = lx, y = ly),
     jl = sprintf("d = RFrame(\"forward\" => y, \"signal\" => x)\nm = st.lm(\"forward ~ stats::poly(signal, %d)\"; data = d)\nresult = RList(\"coef\" => st.coef(m), \"fitted\" => st.fitted(m), \"r2\" => st.summary_lm(m)[\"r.squared\"])", deg))
cs("lm_X", "coef(lm(y ~ X))", "result = st.coef(st.lm('y ~ X', env={'X': X, 'y': y}))", list(X = X3[, 2:3], y = ly), jl = "result = st.coef(st.lm(\"y ~ X\"; env = Dict(\"X\" => X, \"y\" => y)))")
cs("lm_Xnames", "coef(lm(y ~ X))", "result = st.coef(st.lm('y ~ X', env={'X': X, 'y': y}))",
   list(X = `colnames<-`(X3[, 2:3], c("u", "v")), y = ly), jl = "result = st.coef(st.lm(\"y ~ X\"; env = Dict(\"X\" => X, \"y\" => y)))")
cs("lm_X1col", "coef(lm(y ~ X))", "result = st.coef(st.lm('y ~ X', env={'X': X, 'y': y}))",
   list(X = `colnames<-`(X3[, 2, drop = FALSE], "u"), y = ly), jl = "result = st.coef(st.lm(\"y ~ X\"; env = Dict(\"X\" => X, \"y\" => y)))")
cs("lm_noint", "coef(lm(y ~ x - 1))", "result = st.coef(st.lm('y ~ x - 1', env={'x': x, 'y': y}))", list(x = lx, y = ly), jl = "result = st.coef(st.lm(\"y ~ x - 1\"; env = Dict(\"x\" => x, \"y\" => y)))")
cs("lm_na", "m <- lm(y ~ x); list(coef = coef(m), resid = residuals(m))",
   "m = st.lm('y ~ x', env={'x': x, 'y': y})\nresult = {'coef': st.coef(m), 'resid': st.residuals(m)}",
   list(x = lx, y = replace(ly, c(3, 9), NA)), jl = "m = st.lm(\"y ~ x\"; env = Dict(\"x\" => x, \"y\" => y))\nresult = RList(\"coef\" => st.coef(m), \"resid\" => st.residuals(m))")
cs("summary_lm", "s <- summary(lm(y ~ x + z)); s[c('coefficients', 'sigma', 'df', 'r.squared', 'adj.r.squared', 'fstatistic', 'cov.unscaled')]",
   "result = st.summary_lm(st.lm('y ~ x + z', env={'x': x, 'y': y, 'z': z}))", list(x = lx, y = ly, z = rnorm(25)), jl = "result = st.summary_lm(st.lm(\"y ~ x + z\"; env = Dict(\"x\" => x, \"y\" => y, \"z\" => z)))")
cs("poly_a", "unclass(poly(x, 3))[, ]", "result = np.asarray(st.poly(x, 3))", list(x = lx), jl = "result = st.poly(x, 3)")
cs("poly_coefs", "attr(poly(x, 3), 'coefs')", "result = st.poly(x, 3).coefs", list(x = lx), jl = "result = SL.attrs(st.poly(x, 3))[\"coefs\"]")
cs("poly_pred", "p <- poly(x, 2); unclass(poly(c(0.5, 1.7, 4), 2, coefs = attr(p, 'coefs')))[, ]",
   "p = st.poly(x, 2)\nresult = np.asarray(st.poly([0.5, 1.7, 4], 2, coefs=p.coefs))", list(x = lx), jl = "p = st.poly(x, 2)\nresult = st.poly([0.5, 1.7, 4], 2; coefs = SL.attrs(p)[\"coefs\"])")
cs("poly_raw", "unclass(poly(x, 3, raw = TRUE))[, ]", "result = np.asarray(st.poly(x, 3, raw=True))", list(x = lx), jl = "result = st.poly(x, 3; raw = true)")
cs("poly_err", "poly(c(1, 2, 2), 3)", "result = st.poly([1, 2, 2], 3)", jl = "result = st.poly([1.0, 2, 2], 3)")
gy <- as.integer(lx + rnorm(25) > 1.5)
cs("glm_binom", "g <- glm(y ~ x, family = binomial()); list(coef = coef(g), dev = g$deviance, nulldev = g$null.deviance, iter = g$iter, fitted = fitted(g), lp = g$linear.predictors, w = g$weights, conv = g$converged)",
   "g = st.glm('y ~ x', family=st.binomial(), env={'y': y, 'x': x})\nresult = {'coef': g['coefficients'], 'dev': g['deviance'], 'nulldev': g['null.deviance'], 'iter': g['iter'], 'fitted': g['fitted.values'], 'lp': g['linear.predictors'], 'w': g['weights'], 'conv': g['converged']}",
   list(y = gy, x = lx), jl = "g = st.glm(\"y ~ x\"; family = st.r_binomial(), env = Dict(\"y\" => y, \"x\" => x))\nresult = RList(\"coef\" => g[\"coefficients\"], \"dev\" => g[\"deviance\"], \"nulldev\" => g[\"null.deviance\"], \"iter\" => g[\"iter\"], \"fitted\" => g[\"fitted.values\"], \"lp\" => g[\"linear.predictors\"], \"w\" => g[\"weights\"], \"conv\" => g[\"converged\"])")
cs("glm_binom_logical", "coef(glm(as.integer(y == 1) ~ x, family = binomial()))",
   "result = st.coef(st.glm('y ~ x', family=st.binomial(), env={'y': (y == 1).astype(int), 'x': x}))", list(y = gy, x = rnorm(25)), jl = "result = st.coef(st.glm(\"y ~ x\"; family = st.r_binomial(), env = Dict(\"y\" => Int.(y .== 1), \"x\" => x)))")
cs("glm_separation", "coef(glm(y ~ x, family = binomial()))",
   "result = st.coef(st.glm('y ~ x', family=st.binomial(), env={'y': y, 'x': x}))", list(y = c(0, 0, 0, 1, 1, 1), x = 1:6), jl = "result = st.coef(st.glm(\"y ~ x\"; family = st.r_binomial(), env = Dict(\"y\" => y, \"x\" => x)))")

## ── smooth.spline / density / fft ───────────────────────────────────────
sx <- sort(runif(80, 0, 10)); sy <- sin(sx) + rnorm(80, sd = 0.3)
tx <- round(runif(60, 0, 5), 1); ty <- cos(tx) + rnorm(60, sd = 0.2)
SS <- c("x", "y", "w", "yin", "lev", "cv.crit", "pen.crit", "crit", "df", "spar", "ratio", "lambda")
ssr <- function(call) sprintf("s <- %s; c(unclass(s)[c(%s)], list(coef = s$fit$coef, knot = s$fit$knot))", call,
                             paste0("'", SS, "'", collapse = ", "))
ssp <- function(call) sprintf("s = %s\nresult = dict({k: s[k] for k in %s}, coef=s['fit']['coef'], knot=s['fit']['knot'])", call,
                             paste0("[", paste0("'", SS, "'", collapse = ", "), "]"))
cs("ss_gcv", ssr("smooth.spline(x, y, cv = FALSE)"), ssp("st.smooth_spline(x, y, cv=False)"), list(x = sx, y = sy), jl = "s = st.smooth_spline(x, y; cv = false)\nresult = copy(s)\nresult[\"coef\"] = s[\"fit\"][\"coef\"]\nresult[\"knot\"] = s[\"fit\"][\"knot\"]")
cs("ss_cv", ssr("smooth.spline(x, y, cv = TRUE)"), ssp("st.smooth_spline(x, y, cv=True)"), list(x = sx, y = sy), jl = "s = st.smooth_spline(x, y; cv = true)\nresult = copy(s)\nresult[\"coef\"] = s[\"fit\"][\"coef\"]\nresult[\"knot\"] = s[\"fit\"][\"knot\"]")
cs("ss_df", ssr("smooth.spline(x, y, df = 6)"), ssp("st.smooth_spline(x, y, df=6)"), list(x = sx, y = sy), jl = "s = st.smooth_spline(x, y; df = 6)\nresult = copy(s)\nresult[\"coef\"] = s[\"fit\"][\"coef\"]\nresult[\"knot\"] = s[\"fit\"][\"knot\"]")
cs("ss_spar", ssr("smooth.spline(x, y, spar = 0.35)"), ssp("st.smooth_spline(x, y, spar=0.35)"), list(x = sx, y = sy), jl = "s = st.smooth_spline(x, y; spar = 0.35)\nresult = copy(s)\nresult[\"coef\"] = s[\"fit\"][\"coef\"]\nresult[\"knot\"] = s[\"fit\"][\"knot\"]")
cs("ss_lambda", ssr("smooth.spline(x, y, lambda = 1e-4)"), ssp("st.smooth_spline(x, y, lambda_=1e-4)"), list(x = sx, y = sy), jl = "s = st.smooth_spline(x, y; lambda_ = 1e-4)\nresult = copy(s)\nresult[\"coef\"] = s[\"fit\"][\"coef\"]\nresult[\"knot\"] = s[\"fit\"][\"knot\"]")
cs("ss_ties", ssr("smooth.spline(x, y)"), ssp("st.smooth_spline(x, y)"), list(x = tx, y = ty), jl = "s = st.smooth_spline(x, y)\nresult = copy(s)\nresult[\"coef\"] = s[\"fit\"][\"coef\"]\nresult[\"knot\"] = s[\"fit\"][\"knot\"]")
cs("ss_w", ssr("smooth.spline(x, y, w = w)"), ssp("st.smooth_spline(x, y, w=w)"), list(x = sx, y = sy, w = runif(80)), jl = "s = st.smooth_spline(x, y; w = w)\nresult = copy(s)\nresult[\"coef\"] = s[\"fit\"][\"coef\"]\nresult[\"knot\"] = s[\"fit\"][\"knot\"]")
cs("ss_allknots", ssr("smooth.spline(x, y, all.knots = TRUE)"), ssp("st.smooth_spline(x, y, all_knots=True)"), list(x = sx[1:30], y = sy[1:30]), jl = "s = st.smooth_spline(x, y; all_knots = true)\nresult = copy(s)\nresult[\"coef\"] = s[\"fit\"][\"coef\"]\nresult[\"knot\"] = s[\"fit\"][\"knot\"]")
cs("ss_nknots", ssr("smooth.spline(x, y, nknots = 12)"), ssp("st.smooth_spline(x, y, nknots=12)"), list(x = sx, y = sy), jl = "s = st.smooth_spline(x, y; nknots = 12)\nresult = copy(s)\nresult[\"coef\"] = s[\"fit\"][\"coef\"]\nresult[\"knot\"] = s[\"fit\"][\"knot\"]")
cs("ss_unsorted", ssr("smooth.spline(x, y)"), ssp("st.smooth_spline(x, y)"), list(x = rev(sx), y = rev(sy)), jl = "s = st.smooth_spline(x, y)\nresult = copy(s)\nresult[\"coef\"] = s[\"fit\"][\"coef\"]\nresult[\"knot\"] = s[\"fit\"][\"knot\"]")
big <- seq(0, 20, length.out = 700); bigy <- sin(big) + rnorm(700, sd = 0.4)
cs("ss_big", ssr("smooth.spline(x, y, cv = FALSE)"), ssp("st.smooth_spline(x, y, cv=False)"), list(x = big, y = bigy), jl = "s = st.smooth_spline(x, y; cv = false)\nresult = copy(s)\nresult[\"coef\"] = s[\"fit\"][\"coef\"]\nresult[\"knot\"] = s[\"fit\"][\"knot\"]")
cs("ss_pred", "s <- smooth.spline(x, y); predict(s, c(-1, 0.3, 5, 9.99, 12))",
   "s = st.smooth_spline(x, y)\nresult = st.predict_smooth_spline(s, [-1, 0.3, 5, 9.99, 12])", list(x = sx, y = sy), jl = "s = st.smooth_spline(x, y)\nresult = st.predict_smooth_spline(s, [-1, 0.3, 5, 9.99, 12])")
for (dv in 1:3)
  cs(sprintf("ss_pred_d%d", dv), sprintf("s <- smooth.spline(x, y); predict(s, c(-1, 0.3, 5, 9.99, 12), deriv = %d)", dv),
     sprintf("s = st.smooth_spline(x, y)\nresult = st.predict_smooth_spline(s, [-1, 0.3, 5, 9.99, 12], deriv=%d)", dv), list(x = sx, y = sy),
     jl = sprintf("s = st.smooth_spline(x, y)\nresult = st.predict_smooth_spline(s, [-1, 0.3, 5, 9.99, 12]; deriv = %d)", dv))
cs("ss_pred_nox", "predict(smooth.spline(x, y))", "result = st.predict_smooth_spline(st.smooth_spline(x, y))", list(x = sx, y = sy), jl = "result = st.predict_smooth_spline(st.smooth_spline(x, y))")
cs("ss_err4", "smooth.spline(c(1, 2, 3, 2), 1:4)", "result = st.smooth_spline([1, 2, 3, 2], [1, 2, 3, 4])", jl = "result = st.smooth_spline([1.0, 2, 3, 2], [1.0, 2, 3, 4])")
dx <- c(rnorm(150), rnorm(50, 3, 0.5))
cs("density_a", "d <- density(x); d[c('x', 'y', 'bw', 'n')]", "result = st.density(x)", list(x = dx), jl = "result = st.density(x)")
cs("density_opts", "d <- density(x, adjust = 0.6, n = 100, cut = 1); d[c('x', 'y', 'bw', 'n')]",
   "result = st.density(x, adjust=0.6, n=100, cut=1)", list(x = dx), jl = "result = st.density(x; adjust = 0.6, n = 100, cut = 1)")
cs("density_big_n", "d <- density(x, n = 700, from = -2, to = 4); d[c('x', 'y', 'bw')]",
   "result = st.density(x, n=700, from_=-2, to=4)", list(x = dx), jl = "result = st.density(x; n = 700, from_ = -2, to = 4)")
cs("density_bw", "d <- density(x, bw = 0.3); d[c('x', 'y', 'bw')]", "result = st.density(x, bw=0.3)", list(x = dx), jl = "result = st.density(x; bw = 0.3)")
for (k in c("epanechnikov", "rectangular", "triangular", "biweight", "cosine", "optcosine"))
  cs(paste0("density_", k), sprintf("d <- density(x, kernel = '%s'); d[c('x', 'y', 'bw')]", k),
     sprintf("result = st.density(x, kernel='%s')", k), list(x = dx[1:60]),
     jl = sprintf("result = st.density(x; kernel = \"%s\")", k))
cs("density_w", "d <- density(x, weights = w / sum(w)); d[c('x', 'y', 'bw')]",
   "result = st.density(x, weights=w / w.sum())", list(x = dx[1:50], w = (1:50) / 1275), jl = "result = st.density(x; weights = w ./ SL.r_sum(w))")
cs("density_inf", "d <- density(x); d[c('x', 'y', 'bw', 'n')]", "result = st.density(x)", list(x = c(dx[1:40], Inf)), jl = "result = st.density(x)")
cs("density_err_na", "density(x)", "result = st.density(x)", list(x = c(1, NA, 3)), jl = "result = st.density(x)")
cs("bw_nrd0_a", "bw.nrd0(x)", "result = st.bw_nrd0(x)", list(x = dx), jl = "result = st.bw_nrd0(x)")
cs("bw_nrd0_iqr0", "bw.nrd0(c(1, 1, 1, 1, 5))", "result = st.bw_nrd0([1, 1, 1, 1, 5.0])", jl = "result = st.bw_nrd0([1, 1, 1, 1, 5.0])")
for (nn in c(1, 2, 7, 12, 30, 64, 97, 210, 343, 1000))
  cs(sprintf("fft_n%d", nn), "z <- fft(x); c(Re(z), Im(z))", "z = st.fft(x)\nresult = np.concatenate([np.atleast_1d(z.real), np.atleast_1d(z.imag)])",
     list(x = rnorm(nn)), jl = "z = st.fft(x)\nresult = vcat(real.(z), imag.(z))")
cs("fft_inv_cplx", "z <- fft(complex(real = a, imaginary = b), inverse = TRUE); c(Re(z), Im(z))",
   "z = st.fft(a + 1j*b, inverse=True)\nresult = np.concatenate([z.real, z.imag])", list(a = rnorm(45), b = rnorm(45)), jl = "z = st.fft(complex.(a, b); inverse = true)\nresult = vcat(real.(z), imag.(z))")
cs("fft_mat", "z <- fft(M); c(Re(z), Im(z))", "z = st.fft(M)\nresult = np.concatenate([z.real.ravel(order='F'), z.imag.ravel(order='F')])",
   list(M = matrix(rnorm(24), 6, 4)), jl = "z = st.fft(M)\nresult = vcat(vec(real.(z)), vec(imag.(z)))")

## ── dist / hclust ────────────────────────────────────────────────────────
D5 <- matrix(rnorm(40), 8, 5); D5r <- round(D5); D5na <- D5; D5na[2, 3] <- NA
for (m in c("euclidean", "maximum", "manhattan", "canberra", "binary", "minkowski")) {
  cs(paste0("dist_", m), sprintf("as.vector(dist(X, method = '%s', p = 3))", m),
     sprintf("result = np.asarray(st.dist(X, method='%s', p=3))", m), list(X = D5r),
     jl = sprintf("result = st.dist(X; method = \"%s\", p = 3)", m))
  cs(paste0("dist_na_", m), sprintf("as.vector(dist(X, method = '%s'))", m),
     sprintf("result = np.asarray(st.dist(X, method='%s'))", m), list(X = D5na),
     jl = sprintf("result = st.dist(X; method = \"%s\")", m))
}
cs("dist_matrix", "as.matrix(dist(X))", "result = st.dist_as_matrix(st.dist(X))", list(X = D5), jl = "result = st.dist_as_matrix(st.dist(X))")
cs("dist_labels", "as.matrix(dist(X))", "result = st.dist_as_matrix(st.dist(X))",
   list(X = `rownames<-`(D5, letters[1:8])), jl = "result = st.dist_as_matrix(st.dist(X))")
for (m in c("ward.D", "single", "complete", "average", "mcquitty", "median", "centroid", "ward.D2")) {
  cs(paste0("hclust_", m), sprintf("h <- hclust(dist(X), method = '%s'); h[c('merge', 'height', 'order', 'labels', 'method', 'dist.method')]", m),
     sprintf("result = st.hclust(st.dist(X), method='%s')", m), list(X = D5),
     jl = sprintf("result = st.hclust(st.dist(X), \"%s\")", m))
  cs(paste0("hclust_ties_", m), sprintf("h <- hclust(dist(X), method = '%s'); h[c('merge', 'height', 'order')]", m),
     sprintf("result = st.hclust(st.dist(X), method='%s')", m), list(X = D5r),
     jl = sprintf("result = st.hclust(st.dist(X), \"%s\")", m))
}
Cm <- cor(matrix(rnorm(300), 50, 6))
cs("hclust_asdist", "h <- hclust(as.dist(sqrt((1 - C) / 2)), method = 'single'); h[c('merge', 'height', 'order', 'labels')]",
   "result = st.hclust(st.as_dist(np.sqrt((1 - C) / 2)), method='single')", list(C = `dimnames<-`(Cm, list(LETTERS[1:6], LETTERS[1:6]))), jl = "D = NamedMat(sqrt.((1 .- C.data) ./ 2); rownames = C.rownames, colnames = C.colnames)\nresult = st.hclust(st.as_dist(D), \"single\")")
cs("hclust_members", "h <- hclust(dist(X), 'average', members = c(1, 2, 1, 3, 1, 1, 2, 1)); h[c('merge', 'height', 'order')]",
   "result = st.hclust(st.dist(X), 'average', members=[1, 2, 1, 3, 1, 1, 2, 1])", list(X = D5), jl = "result = st.hclust(st.dist(X), \"average\"; members = [1, 2, 1, 3, 1, 1, 2, 1])")
cs("hclust_n2", "h <- hclust(dist(X)); h[c('merge', 'height', 'order')]", "result = st.hclust(st.dist(X))", list(X = D5[1:2, ]), jl = "result = st.hclust(st.dist(X))")
cs("hclust_err_n1", "hclust(dist(X))", "result = st.hclust(st.dist(X))", list(X = D5[1, , drop = FALSE]), jl = "result = st.hclust(st.dist(X))")

## ── p.adjust / t.test ────────────────────────────────────────────────────
pv <- c(0.01, 0.04, 0.03, 0.005, 0.2, 0.5, 0.04, NA, 0.9, 0.0001)
for (m in c("holm", "hochberg", "hommel", "bonferroni", "BH", "BY", "fdr", "none")) {
  cs(paste0("padj_", m), sprintf("p.adjust(p, '%s')", m), sprintf("result = st.p_adjust(p, '%s')", m), list(p = pv),
     jl = sprintf("result = st.p_adjust(p, \"%s\")", m))
  cs(paste0("padj_n_", m), sprintf("p.adjust(p, '%s', n = 25)", m), sprintf("result = st.p_adjust(p, '%s', n=25)", m),
     list(p = pv[!is.na(pv)]), jl = sprintf("result = st.p_adjust(p, \"%s\"; n = 25)", m))
}
cs("padj_named", "p.adjust(p, 'BH')", "result = st.p_adjust(p, 'BH')", list(p = c(a = 0.01, b = 0.2, c = 0.03)), jl = "result = st.p_adjust(p, \"BH\")")
cs("padj_hommel2", "p.adjust(c(0.02, 0.03), 'hommel')", "result = st.p_adjust([0.02, 0.03], 'hommel')", jl = "result = st.p_adjust([0.02, 0.03], \"hommel\")")
ta <- rnorm(14, 0.3); tb <- rnorm(19); tp <- rnorm(14)
TT <- "t[c('statistic', 'parameter', 'p.value', 'conf.int', 'estimate', 'null.value', 'stderr', 'alternative', 'method')]"
cs("ttest_welch", paste0("t <- t.test(a, b); ", TT), "result = st.t_test(a, b)", list(a = ta, b = tb), jl = "result = st.t_test(a, b)")
cs("ttest_vareq", paste0("t <- t.test(a, b, var.equal = TRUE); ", TT), "result = st.t_test(a, b, var_equal=True)", list(a = ta, b = tb), jl = "result = st.t_test(a, b; var_equal = true)")
cs("ttest_less", paste0("t <- t.test(a, b, alternative = 'less', mu = 0.2, conf.level = 0.9); ", TT),
   "result = st.t_test(a, b, alternative='less', mu=0.2, conf_level=0.9)", list(a = ta, b = tb), jl = "result = st.t_test(a, b; alternative = \"less\", mu = 0.2, conf_level = 0.9)")
cs("ttest_greater", paste0("t <- t.test(a, b, alternative = 'greater'); ", TT), "result = st.t_test(a, b, alternative='greater')", list(a = ta, b = tb), jl = "result = st.t_test(a, b; alternative = \"greater\")")
cs("ttest_paired", paste0("t <- t.test(a, b, paired = TRUE); ", TT), "result = st.t_test(a, b, paired=True)", list(a = ta, b = tp), jl = "result = st.t_test(a, b; paired = true)")
cs("ttest_one", paste0("t <- t.test(a, mu = 0.1); ", TT), "result = st.t_test(a, mu=0.1)", list(a = ta), jl = "result = st.t_test(a; mu = 0.1)")
cs("ttest_na", paste0("t <- t.test(a, b); ", TT), "result = st.t_test(a, b)", list(a = c(ta, NA), b = tb), jl = "result = st.t_test(a, b)")
cs("ttest_err_const", "t.test(c(1, 1, 1), c(2, 2, 2))", "result = st.t_test([1, 1, 1.0], [2, 2, 2.0])", jl = "result = st.t_test([1, 1, 1.0], [2, 2, 2.0])")
cs("ttest_err_few", "t.test(1, c(2, 3))", "result = st.t_test([1.0], [2, 3.0])", jl = "result = st.t_test([1.0], [2, 3.0])")

## ── rank / order / sort / rle / cut / findInterval / tabulate ────────────
rv <- c(3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, NA, 8, 9, 7, 9)
for (tm in c("average", "first", "last", "min", "max"))
  cs(paste0("rank_", tm), sprintf("rank(x, ties.method = '%s')", tm), sprintf("result = st.rank(x, ties_method='%s')", tm), list(x = rv),
     jl = sprintf("result = st.r_rank(x; ties_method = \"%s\")", tm))
cs("rank_keep", "rank(x, na.last = 'keep')", "result = st.rank(x, na_last='keep')", list(x = rv), jl = "result = st.r_rank(x; na_last = \"keep\")")
cs("rank_nalastF", "rank(x, na.last = FALSE)", "result = st.rank(x, na_last=False)", list(x = rv), jl = "result = st.r_rank(x; na_last = false)")
cs("rank_naNA", "rank(x, na.last = NA)", "result = st.rank(x, na_last=None)", list(x = rv), jl = "result = st.r_rank(x; na_last = nothing)")
cs("rank_named", "rank(x)", "result = st.rank(x)", list(x = c(b = 2, a = 1, c = 2)), jl = "result = st.r_rank(x)")
cs("order_a", "order(x)", "result = st.order(x)", list(x = rv), jl = "result = st.order(x)")
cs("order_dec", "order(x, decreasing = TRUE)", "result = st.order(x, decreasing=True)", list(x = rv), jl = "result = st.order(x; decreasing = true)")
cs("order_nalast", "order(x, na.last = FALSE)", "result = st.order(x, na_last=False)", list(x = rv), jl = "result = st.order(x; na_last = false)")
cs("order_naNA", "order(x, na.last = NA)", "result = st.order(x, na_last=None)", list(x = rv), jl = "result = st.order(x; na_last = nothing)")
cs("order_two", "order(round(x / 3), -y)", "result = st.order(np.round(x / 3), -y)", list(x = rv[-12], y = 1:15), jl = "result = st.order(round.(x ./ 3), -y)")
cs("order_chr", "order(s)", "result = st.order(s)", list(s = c("b", "a", "ab", "aa", "a", "c")), jl = "result = st.order(s)")
cs("sort_a", "sort(x)", "result = st.sort(x)", list(x = rv), jl = "result = st.r_sort(x)")
cs("sort_dec", "sort(x, decreasing = TRUE)", "result = st.sort(x, decreasing=True)", list(x = rv), jl = "result = st.r_sort(x; decreasing = true)")
cs("sort_named", "sort(x)", "result = st.sort(x)", list(x = c(b = 2, a = 1, c = 0.5)), jl = "result = st.r_sort(x)")
## Zeichenketten: Kollation wie R (ICU "root" unter LC_ALL=C.UTF-8)
chs <- c("b", "A", "a", "B", "ä", "Ä", "Zebra", "zebra", "10", "2", "1", " a", "a b", "a-b", "a_b", "a.b",
         "a,b", "ß", "ss", "é", "e", "E", "x10", "x2", "Ö", "o", "Ü", "u", NA, "", "!", "St", "st", "b", "a")
chd <- c("b", "A", "a", "B", "a", "ä", "B", NA, "a", "Ab", "aB")
cs("chr_sort", "sort(s)", "result = st.sort(s)", list(s = chs), jl = "result = st.r_sort(s)")
cs("chr_sort_dec", "sort(s, decreasing = TRUE)", "result = st.sort(s, decreasing=True)", list(s = chs), jl = "result = st.r_sort(s; decreasing = true)")
cs("chr_sort_nalast", "sort(s, na.last = TRUE)", "result = st.sort(s, na_last=True)", list(s = chs), jl = "result = st.r_sort(s; na_last = true)")
cs("chr_sort_nafirst", "sort(s, decreasing = TRUE, na.last = FALSE)", "result = st.sort(s, decreasing=True, na_last=False)", list(s = chd), jl = "result = st.r_sort(s; decreasing = true, na_last = false)")
cs("chr_sort_named", "sort(s)", "result = st.sort(s)", list(s = c(x = "b", y = "A", z = "a", w = "B", v = "ä")), jl = "result = st.r_sort(s)")
cs("chr_sort_unique", "sort(unique(s))", "result = st.sort(pd.unique(np.asarray(s, dtype=object)))", list(s = chd), jl = "result = st.r_sort(unique(s))")
cs("chr_order", "order(s)", "result = st.order(s)", list(s = chs), jl = "result = st.order(s)")
cs("chr_order_dec", "order(s, decreasing = TRUE)", "result = st.order(s, decreasing=True)", list(s = chs), jl = "result = st.order(s; decreasing = true)")
cs("chr_order_nalastF", "order(s, na.last = FALSE)", "result = st.order(s, na_last=False)", list(s = chs), jl = "result = st.order(s; na_last = false)")
cs("chr_order_naNA", "order(s, na.last = NA)", "result = st.order(s, na_last=None)", list(s = chs), jl = "result = st.order(s; na_last = nothing)")
cs("chr_order_two", "order(s, x)", "result = st.order(s, x)", list(s = chd, x = c(3, 1, 2, 2, 1, 5, 1, 4, 0, 2, 2)), jl = "result = st.order(s, x)")
cs("chr_order_two_dec", "order(x, s, decreasing = TRUE)", "result = st.order(x, s, decreasing=True)", list(s = chd, x = c(3, 1, 2, 2, 1, 5, 1, 4, 0, 2, 2)), jl = "result = st.order(x, s; decreasing = true)")
for (tm in c("average", "min", "max", "first", "last"))
  cs(paste0("chr_rank_", tm), sprintf("rank(s, ties.method = '%s')", tm), sprintf("result = st.rank(s, ties_method='%s')", tm), list(s = chd),
     jl = sprintf("result = st.r_rank(s; ties_method = \"%s\")", tm))
cs("chr_rank_keep", "rank(s, na.last = 'keep')", "result = st.rank(s, na_last='keep')", list(s = chs), jl = "result = st.r_rank(s; na_last = \"keep\")")
cs("chr_factor_levels", "f <- factor(s); list(levels(f), as.integer(f))",
   "import simlev._r.fmt as fm\nlv = list(st.sort(pd.unique(np.asarray([v for v in s if v is not None], dtype=object))))\npos = {v: i + 1 for i, v in enumerate(lv)}\nresult = [lv, np.array([fm.NA_REAL if v is None else pos[v] for v in s])]",
   list(s = chs), jl = "f = SL.RFmt.r_factor(s)\nresult = [f.levels, [c == 0 ? missing : c for c in f.codes]]")
cs("chr_factor_print", "f <- factor(s); paste(capture.output(print(f)), collapse = '\\n')", "import simlev._r.fmt as fm\nresult = fm.print_factor(s)",
   list(s = chd), jl = "result = SL.RFmt.print_factor(s)")
cs("chr_table", "t <- table(s); list(names(t), as.vector(t))",
   "a = st.aggregate(np.ones(len([v for v in s if v is not None])), {'g': [v for v in s if v is not None]}, len)\nresult = [list(a['g']), a['x'].to_numpy(dtype=np.int64)]",
   list(s = chd), jl = "ss = [v for v in s if v !== missing]\na = st.aggregate(ones(length(ss)), [\"g\" => ss], length)\nresult = [a[\"g\"], Int.(a[\"x\"])]")
cs("chr_aggregate", "aggregate(x, list(g = s, h = t), sum)", "result = st.aggregate(x, {'g': s, 'h': t}, st._rsum)",
   list(x = c(1, 2, 3, 4, 5, 6, 7, 8), s = c("b", "A", "a", "B", "a", "ä", "B", "b"), t = c("y", "Y", "y", "Y", "Y", "y", "Y", "y")),
   jl = "result = st.aggregate(x, [\"g\" => s, \"h\" => t], v -> SL.r_sum(v))")
cs("chr_ave_order", "o <- character(0); r <- ave(x, s, FUN = function(v) { o <<- c(o, paste(v, collapse = ',')); v * 0 + length(o) }); list(r, o)",
   "o = []\ndef f(v):\n    o.append(','.join('%d' % t for t in v))\n    return v * 0 + len(o)\nr = st.ave(x, s, FUN=f)\nresult = [r, o]",
   list(x = c(1, 2, 3, 4, 5, 6), s = c("b", "A", "a", "B", "ä", "a")),
   jl = "o = String[]\nf(v) = (push!(o, join([string(Int(t)) for t in v], \",\")); v .* 0 .+ length(o))\nr = st.ave(x, s; FUN = f)\nresult = [r, o]")
chp <- c("a", "A", "b", "B", "ä", "Ä", "a b", "ab", "a-b", "10", "2", "", " ", "ß", "ss", "St", "st", "x10", "x2", "é", "e")
cs("chr_collate_pairs", "outer(s, s, function(a, b) ifelse(a < b, -1L, ifelse(a > b, 1L, 0L)))",
   "result = np.array([[st.str_collate(a, b) for b in s] for a in s], dtype=np.int64)",
   list(s = chp), jl = "result = [st.str_collate(a, b) for a in s, b in s]")
cs("chr_lt", "c(s < 'b', s > 'B', s <= 'a', s >= 'ä')",
   "result = np.array([st.str_collate(v, 'b') < 0 for v in s] + [st.str_collate(v, 'B') > 0 for v in s] + [st.str_collate(v, 'a') <= 0 for v in s] + [st.str_collate(v, 'ä') >= 0 for v in s])",
   list(s = chp), jl = "result = vcat([st.str_collate(v, \"b\") < 0 for v in s], [st.str_collate(v, \"B\") > 0 for v in s], [st.str_collate(v, \"a\") <= 0 for v in s], [st.str_collate(v, \"ä\") >= 0 for v in s])")
cs("rle_a", "unclass(rle(x))", "result = st.rle(x)", list(x = c(1, 1, 2, 2, 2, 3, 1, 1)), jl = "result = st.rle(x)")
cs("rle_lgl", "unclass(rle(x))", "result = st.rle(x)", list(x = c(TRUE, TRUE, FALSE, TRUE)), jl = "result = st.rle(x)")
cs("tabulate_a", "tabulate(x)", "result = st.tabulate(x)", list(x = c(2, 3, 3, 5, NA, 0)), jl = "result = st.tabulate(x)")
cs("tabulate_nb", "tabulate(x, nbins = 3)", "result = st.tabulate(x, nbins=3)", list(x = c(2, 3, 3, 5)), jl = "result = st.tabulate(x; nbins = 3)")
fv <- c(1, 2, 2, 3.5, 7); fq <- c(-1, 1, 2, 2.5, 3.5, 7, 8, NA)
cs("findint_a", "findInterval(x, v)", "result = st.findInterval(x, v)", list(x = fq, v = fv), jl = "result = st.findInterval(x, v)")
cs("findint_rc", "findInterval(x, v, rightmost.closed = TRUE)", "result = st.findInterval(x, v, rightmost_closed=True)", list(x = fq, v = fv), jl = "result = st.findInterval(x, v; rightmost_closed = true)")
cs("findint_ai", "findInterval(x, v, all.inside = TRUE)", "result = st.findInterval(x, v, all_inside=True)", list(x = fq, v = fv), jl = "result = st.findInterval(x, v; all_inside = true)")
cs("findint_lo", "findInterval(x, v, left.open = TRUE)", "result = st.findInterval(x, v, left_open=True)", list(x = fq, v = fv), jl = "result = st.findInterval(x, v; left_open = true)")
cs("findint_err", "findInterval(1, c(2, 1))", "result = st.findInterval(1, [2, 1])", jl = "result = st.findInterval(1, [2, 1])")
cs("cut_codes", "cut(x, 4, labels = FALSE)", "result = st.cut(x, 4, labels=False)", list(x = x1), jl = "result = st.cut(x, 4; labels = false)")
cs("cut_seq", "cut(seq_len(23), 5, labels = FALSE)", "result = st.cut(np.arange(1, 24), 5, labels=False)", jl = "result = st.cut(1:23, 5; labels = false)")
cs("cut_labels", "as.character(cut(x, c(-3, -1, 0, 1, 3)))", "result = np.asarray(st.cut(x, [-3, -1, 0, 1, 3]), dtype=object)", list(x = x1), jl = "result = collect(st.cut(x, [-3, -1, 0, 1, 3]))")
cs("cut_incl", "as.character(cut(x, c(-1, 0, 2, 5), include.lowest = TRUE, right = FALSE))",
   "result = np.asarray(st.cut(x, [-1, 0, 2, 5], include_lowest=True, right=False), dtype=object)", list(x = c(-1, 0, 1.5, 5, 6)), jl = "result = collect(st.cut(x, [-1, 0, 2, 5]; include_lowest = true, right = false))")
cs("cut_userlab", "as.character(cut(x, c(-5, 0, 5), labels = c('neg', 'pos'), right = FALSE))",
   "result = np.asarray(st.cut(x, [-5, 0, 5], labels=['neg', 'pos'], right=False), dtype=object)", list(x = x1), jl = "result = collect(st.cut(x, [-5, 0, 5]; labels = [\"neg\", \"pos\"], right = false))")
cs("cut_err_breaks", "cut(1:3, c(1, 1, 2))", "result = st.cut(np.arange(1, 4), [1, 1, 2])", jl = "result = st.cut(1:3, [1, 1, 2])")

## ── complete.cases / ecdf / ave / aggregate ─────────────────────────────
cs("cc_df", "complete.cases(d)", "result = st.complete_cases(d)",
   list(d = data.frame(a = c(1, NA, 3, 4), b = c("x", "y", NA, "z"), stringsAsFactors = FALSE)), jl = "result = st.complete_cases(d)")
cs("cc_mat_vec", "complete.cases(M, v)", "result = st.complete_cases(M, v)", list(M = unname(Mna), v = c(NA, rep(1, 19))), jl = "result = st.complete_cases(M, v)")
cs("ecdf_a", "F <- ecdf(x); F(c(-5, x[1:5], 0, 5))", "F = st.ecdf(x)\nresult = F(np.concatenate([[-5], x[:5], [0, 5]]))", list(x = x2), jl = "F = st.ecdf(x)\nresult = F(vcat(-5, x[1:5], 0, 5))")
cs("ave_mean", "ave(x, g)", "result = st.ave(x, g)", list(x = x1, g = rep(1:4, length.out = 37)), jl = "result = st.ave(x, g)")
cs("ave_sum2", "ave(x, g, h, FUN = sum)", "result = st.ave(x, g, h, FUN=lambda v: st._rsum(v))",
   list(x = x1, g = rep(1:3, length.out = 37), h = rep(c(0, 1), each = 19)[1:37]), jl = "result = st.ave(x, g, h; FUN = v -> SL.r_sum(v))")
cs("ave_nog", "ave(x)", "result = st.ave(x)", list(x = x1), jl = "result = st.ave(x)")
cs("aggregate_1", "aggregate(x, list(p = g), mean)", "result = st.aggregate(x, {'p': g}, st._rmean)", list(x = x1, g = rep(c(3, 1, 2), length.out = 37)), jl = "result = st.aggregate(x, [\"p\" => g], v -> SL.RStats._rmean(v))")
cs("aggregate_2", "aggregate(x, list(p1 = g, p2 = h), median)", "result = st.aggregate(x, {'p1': g, 'p2': h}, st.median)",
   list(x = x1, g = rep(1:3, length.out = 37), h = rep(c(0.5, 0.1), length.out = 37)), jl = "result = st.aggregate(x, [\"p1\" => g, \"p2\" => h], st.median)")

## ── base: colSums & Co. ─────────────────────────────────────────────────
cs("base_colSums", "colSums(M)", "result = rb.colSums(M)", list(M = M), jl = "result = rb.colSums(M)")
cs("base_colSums_na", "colSums(M, na.rm = TRUE)", "result = rb.colSums(M, na_rm=True)", list(M = Mna), jl = "result = rb.colSums(M; na_rm = true)")
cs("base_colMeans", "colMeans(M)", "result = rb.colMeans(M)", list(M = Mna), jl = "result = rb.colMeans(M)")
cs("base_colMeans_na", "colMeans(M, na.rm = TRUE)", "result = rb.colMeans(M, na_rm=True)", list(M = Mna), jl = "result = rb.colMeans(M; na_rm = true)")
cs("base_rowSums", "rowSums(M)", "result = rb.rowSums(M)", list(M = Mna), jl = "result = rb.rowSums(M)")
cs("base_rowSums_na", "rowSums(M, na.rm = TRUE)", "result = rb.rowSums(M, na_rm=True)", list(M = Mna), jl = "result = rb.rowSums(M; na_rm = true)")
cs("base_rowMeans", "rowMeans(M)", "result = rb.rowMeans(M)", list(M = M), jl = "result = rb.rowMeans(M)")
cs("base_rowMeans_na", "rowMeans(M, na.rm = TRUE)", "result = rb.rowMeans(M, na_rm=True)", list(M = Mna), jl = "result = rb.rowMeans(M; na_rm = true)")
cs("base_rowMeans_df", "rowMeans(d)", "result = rb.rowMeans(d)", list(d = as.data.frame(M)), jl = "result = rb.rowMeans(d)")
cs("base_cumprod", "cumprod(1 + x / 100)", "result = rb.cumprod(1 + x / 100)", list(x = x1), jl = "result = rb.r_cumprod(1 .+ x ./ 100)")
cs("base_cumprod_na", "cumprod(x)", "result = rb.cumprod(x)", list(x = c(1.1, 2, NA, 3)), jl = "result = rb.r_cumprod(x)")
cs("base_cummax", "cummax(x)", "result = rb.cummax(x)", list(x = xna), jl = "result = rb.r_cummax(x)")
cs("base_cummin", "cummin(x)", "result = rb.cummin(x)", list(x = x1), jl = "result = rb.r_cummin(x)")
cs("base_mean_mat", "mean(M)", "result = rb.mean(M)", list(M = M), jl = "result = rb.mean(M)")
cs("base_diff", "diff(x)", "result = rb.diff(x)", list(x = x1), jl = "result = rb.r_diff(x)")
cs("base_diff_lag", "diff(x, lag = 2, differences = 2)", "result = rb.diff(x, lag=2, differences=2)", list(x = x1), jl = "result = rb.r_diff(x; lag = 2, differences = 2)")
cs("base_diff_mat", "diff(M)", "result = rb.diff(M)", list(M = unname(M)), jl = "result = rb.r_diff(M)")
cs("base_pmax", "pmax(x, 0.2)", "result = rb.pmax(x, 0.2)", list(x = xna), jl = "result = rb.pmax(x, 0.2)")
cs("base_pmin_narm", "pmin(x, rev(x), na.rm = TRUE)", "result = rb.pmin(x, x[::-1], na_rm=True)", list(x = xna), jl = "result = rb.pmin(x, reverse(x); na_rm = true)")
cs("base_range", "range(x)", "result = rb.range(x)", list(x = x1), jl = "result = rb.r_range(x)")
cs("base_range_na", "range(x, na.rm = TRUE)", "result = rb.range(x, na_rm=True)", list(x = xna), jl = "result = rb.r_range(x; na_rm = true)")

ref_done()
