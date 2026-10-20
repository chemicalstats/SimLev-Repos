# Referenzfälle für optimize.R und die Optimierungskerne aus research_core.cpp
# (.proj_box_simplex, .qp_box_simplex, .min_cvar_core, .min_cdar_core).
# Aufruf aus der Repo-Wurzel:
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript golden/modules/gen_optimize.R
source("golden/modules/ref_tools.R"); ref_init("optimize")

P <- "from simlev import optimize as O\nfrom simlev import _optimize_core as C\nfrom simlev._r import rng as RNG\n"
J <- "O = SL.Optimize; C = SL.OptimizeCore\n"   # Kopf des Julia-Codes (jl)
cs <- function(id, r, py, inputs = I, jl = NULL, ...) {
  used <- names(inputs)[vapply(names(inputs), function(k) grepl(sprintf("(^|[^A-Za-z0-9_.])%s([^A-Za-z0-9_.]|$)", k), r), TRUE)]
  ref_case(id, r, paste0(P, py), inputs = inputs[used], jl = if (is.null(jl)) NULL else paste0(J, jl), ...)
}

# ── Daten ────────────────────────────────────────────────────────────────────
set.seed(1)
R <- matrix(rnorm(260 * 3, c(0.002, 0.001, 0.0005), c(0.03, 0.02, 0.01)), 260, byrow = TRUE)
colnames(R) <- c("aktien", "reits", "anleihen")
set.seed(3)
S0 <- matrix(c(0.04, 0.012, 0.006, 0.002, 0.012, 0.0225, 0.004, 0.001, 0.006, 0.004, 0.01, 0.0005,
               0.002, 0.001, 0.0005, 0.0025), 4) / 52
R4 <- matrix(rnorm(156 * 4), 156) %*% chol(S0) + matrix(c(0.08, 0.06, 0.04, 0.02) / 52, 156, 4, byrow = TRUE)
colnames(R4) <- c("A", "B", "C", "D")
Rc <- cbind(R, cash = 0.0005)
R1 <- R[, 1, drop = FALSE]
Rna <- R; Rna[c(5, 77), 2] <- NA
Rinf <- R; Rinf[c(9, 12), 2] <- Inf; Rinf[4, 3] <- -Inf
Rnn <- unname(R[1:120, ])
set.seed(2); n <- 3 * 365
d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
d$anleihen <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.003))
d$gold <- 100 * cumprod(1 + rnorm(n, 2e-4, 0.008))
dna <- d; dna$aktien[100:106] <- NA
d0 <- d; d0$aktien[100:106] <- 0
dsh <- d[c(500:1, 501:n), ]
ddup <- rbind(d, d[5, ])
I <- list(R = R, R4 = R4, Rc = Rc, R1 = R1, Rna = Rna, Rinf = Rinf, Rnn = Rnn, d = d)

# ── Kerne ────────────────────────────────────────────────────────────────────
set.seed(11)
pv <- list(); plo <- list(); phi <- list()
for (k in 1:25) {
  m <- sample(2:12, 1); v <- rnorm(m, 0, 2); lo <- runif(m, 0, 0.05); hi <- pmax(lo + 0.05, runif(m, 0.1, 0.8))
  if (sum(hi) < 1) hi <- hi / sum(hi) * 1.2
  pv[[k]] <- v; plo[[k]] <- lo; phi[[k]] <- hi
}
pv[[26]] <- c(0.2, 0.2, 0.2); plo[[26]] <- c(0, 0, 0); phi[[26]] <- c(0.3, 0.3, 0.3)   # sum(hi) <= 1
pv[[27]] <- c(0.2, 0.2); plo[[27]] <- c(0.6, 0.5); phi[[27]] <- c(1, 1)               # sum(lo) >= 1
pv[[28]] <- c(0, 0, 0, 0); plo[[28]] <- c(0, 0, 0, 0); phi[[28]] <- c(1, 1, 1, 1)     # Gleichstaende
pv[[29]] <- c(-0, 0, 1, -0, 0.5, 0, 0, -0, 0, 0); plo[[29]] <- rep(0, 10); phi[[29]] <- c(rep(0.5, 9), 0)  # +0/-0
Ip <- list(pv = pv, plo = plo, phi = phi)
cs("core_proj", "lapply(seq_along(pv), function(k) SimLev:::.proj_box_simplex(pv[[k]], plo[[k]], phi[[k]]))",
   "result = [C.proj_box_simplex(pv[k], plo[k], phi[k]) for k in range(len(pv))]", inputs = Ip,
   jl = 'result = [C.proj_box_simplex(pv[k], plo[k], phi[k]) for k in eachindex(pv)]')
set.seed(2); A <- matrix(rnorm(400), 100); Sq <- crossprod(A) / 100
Iq <- list(Sq = Sq, cq = c(-0.1, 0.05, 0, 0.2), lq = c(0, 0.1, 0, 0), hq = c(1, 0.5, 0.3, 1))
cs("core_qp", "list(SimLev:::.qp_box_simplex(Sq, rep(0, 4), rep(0, 4), rep(1, 4), rep(0.25, 4), 2.5, 20000L, 1e-12),
                    SimLev:::.qp_box_simplex(Sq, cq, lq, hq, c(1, 0, 0, 0), 3, 20000L, 1e-12),
                    SimLev:::.qp_box_simplex(Sq, cq, lq, hq, c(1, 0, 0, 0), 3, 7L, 1e-12))",
   "result = [C.qp_box_simplex(Sq, [0.0] * 4, [0.0] * 4, [1.0] * 4, [0.25] * 4, 2.5, 20000, 1e-12),
          C.qp_box_simplex(Sq, cq, lq, hq, [1.0, 0, 0, 0], 3, 20000, 1e-12),
          C.qp_box_simplex(Sq, cq, lq, hq, [1.0, 0, 0, 0], 3, 7, 1e-12)]", inputs = Iq,
   jl = 'result = [C.qp_box_simplex(Sq, zeros(4), zeros(4), ones(4), fill(0.25, 4), 2.5, 20000, 1e-12),
          C.qp_box_simplex(Sq, cq, lq, hq, [1.0, 0, 0, 0], 3, 20000, 1e-12),
          C.qp_box_simplex(Sq, cq, lq, hq, [1.0, 0, 0, 0], 3, 7, 1e-12)]')
Ic <- list(Rs = R[1:120, ])
cs("core_cvar", "list(SimLev:::.min_cvar_core(Rs, 0.05, rep(0, 3), rep(1, 3), rep(1/3, 3), 0.02, c(0.002, 0.0002), 2000L),
                      SimLev:::.min_cvar_core(Rs, 0.2, c(0.1, 0, 0), c(0.5, 1, 0.6), c(0.4, 0.3, 0.3), 0.01, 0.001, 50L))",
   "result = [C.min_cvar_core(Rs, 0.05, [0.0] * 3, [1.0] * 3, [1/3] * 3, 0.02, [0.002, 0.0002], 2000),
          C.min_cvar_core(Rs, 0.2, [0.1, 0, 0], [0.5, 1, 0.6], [0.4, 0.3, 0.3], 0.01, [0.001], 50)]", inputs = Ic,
   jl = 'result = [C.min_cvar_core(Rs, 0.05, zeros(3), ones(3), fill(1 / 3, 3), 0.02, [0.002, 0.0002], 2000),
          C.min_cvar_core(Rs, 0.2, [0.1, 0, 0], [0.5, 1, 0.6], [0.4, 0.3, 0.3], 0.01, 0.001, 50)]')
cs("core_cdar", "list(SimLev:::.min_cdar_core(Rs, 0.05, rep(0, 3), rep(1, 3), 300L),
                      SimLev:::.min_cdar_core(Rs, 0.1, c(0.1, 0, 0), c(0.5, 1, 0.6), 100L))",
   "result = [C.min_cdar_core(Rs, 0.05, [0.0] * 3, [1.0] * 3, 300), C.min_cdar_core(Rs, 0.1, [0.1, 0, 0], [0.5, 1, 0.6], 100)]",
   inputs = Ic,
   jl = 'result = [C.min_cdar_core(Rs, 0.05, zeros(3), ones(3), 300), C.min_cdar_core(Rs, 0.1, [0.1, 0, 0], [0.5, 1, 0.6], 100)]')

# ── Interne Helfer ───────────────────────────────────────────────────────────
for (ct in c("sample", "ledoit_wolf", "ewma", "denoise", "gerber"))
  cs(paste0("cov_", ct), sprintf("list(SimLev:::.opt_cov(R, '%s'), SimLev:::.opt_cov(R4, '%s'), SimLev:::.opt_cov(R1, '%s'))", ct, ct, ct),
     sprintf("result = [O._opt_cov(R, '%s'), O._opt_cov(R4, '%s'), O._opt_cov(R1, '%s')]", ct, ct, ct),
   jl = sprintf('result = [O._opt_cov(R, "%s"), O._opt_cov(R4, "%s"), O._opt_cov(R1, "%s")]', ct, ct, ct))
cs("cov_denoise_flat", "SimLev:::.opt_cov(Rc, 'denoise')", "result = O._opt_cov(Rc, 'denoise')",
   jl = 'result = O._opt_cov(Rc, "denoise")')
cs("cov_gerber_flat", "SimLev:::.opt_cov(Rc, 'gerber')", "result = O._opt_cov(Rc, 'gerber')",
   jl = 'result = O._opt_cov(Rc, "gerber")')
cs("helpers_hist", "list(SimLev:::.cvar_hist(R %*% c(0.5, 0.2, 0.3), 0.05), SimLev:::.cdar_hist(drop(R %*% c(0.5, 0.2, 0.3)), 0.1),
                        SimLev:::.hrp(cov(R4)), SimLev:::.risk_parity(cov(R4), c(0.4, 0.3, 0.2, 0.1)),
                        SimLev:::.qp_simplex(cov(R4) * 52, -colMeans(R4) * 52, rep(0, 4), rep(1, 4)))",
   "import numpy as np\nrs = np.asarray(R) @ np.array([0.5, 0.2, 0.3])\nresult = [O._cvar_hist(O._mat_vec(R, [0.5, 0.2, 0.3]), 0.05), O._cdar_hist(O._mat_vec(R, [0.5, 0.2, 0.3]), 0.1),
          O._hrp(O._cov(R4)), O._risk_parity(O._cov(R4), [0.4, 0.3, 0.2, 0.1]),
          O._qp_simplex(O._cov(R4) * 52, -O._col_means(R4) * 52, [0.0] * 4, [1.0] * 4)]",
   jl = 'w = [0.5, 0.2, 0.3]
result = [O._cvar_hist(O._mat_vec(R, w), 0.05), O._cdar_hist(O._mat_vec(R, w), 0.1),
          O._hrp(O._cov(R4)), O._risk_parity(O._cov(R4), [0.4, 0.3, 0.2, 0.1]),
          O._qp_simplex(O._cov(R4) .* 52, .-O._col_means(R4) .* 52, zeros(4), ones(4))]')

# ── portfolio_optimize: Verfahren ────────────────────────────────────────────
meths <- c("min_variance", "max_sharpe", "mean_variance", "max_diversification", "risk_parity", "hrp",
           "min_cvar", "min_cdar", "inverse_vol", "equal")
for (m in meths) {
  cs(paste0("po_", m), sprintf("portfolio_optimize(R, method = '%s')", m), sprintf("result = O.portfolio_optimize(R, method='%s')", m),
   jl = sprintf('result = O.portfolio_optimize(R; method = "%s")', m))
  cs(paste0("po4_", m), sprintf("portfolio_optimize(R4, method = '%s')", m), sprintf("result = O.portfolio_optimize(R4, method='%s')", m),
   jl = sprintf('result = O.portfolio_optimize(R4; method = "%s")', m))
}
cs("po_default", "portfolio_optimize(R)", "result = O.portfolio_optimize(R)",
   jl = 'result = O.portfolio_optimize(R)')
for (ct in c("ledoit_wolf", "ewma", "denoise", "gerber")) {
  cs(paste0("po_cov_", ct), sprintf("portfolio_optimize(R4, cov = '%s')", ct), sprintf("result = O.portfolio_optimize(R4, cov='%s')", ct),
   jl = sprintf('result = O.portfolio_optimize(R4; cov = "%s")', ct))
  cs(paste0("po_cov_rp_", ct), sprintf("portfolio_optimize(R4, method = 'risk_parity', cov = '%s')", ct),
     sprintf("result = O.portfolio_optimize(R4, method='risk_parity', cov='%s')", ct),
   jl = sprintf('result = O.portfolio_optimize(R4; method = "risk_parity", cov = "%s")', ct))
  cs(paste0("po_cov_ms_", ct), sprintf("portfolio_optimize(R, method = 'max_sharpe', cov = '%s')", ct),
     sprintf("result = O.portfolio_optimize(R, method='max_sharpe', cov='%s')", ct),
   jl = sprintf('result = O.portfolio_optimize(R; method = "max_sharpe", cov = "%s")', ct))
}
cs("po_cov_hrp_gerber", "portfolio_optimize(R4, method = 'hrp', cov = 'gerber')", "result = O.portfolio_optimize(R4, method='hrp', cov='gerber')",
   jl = 'result = O.portfolio_optimize(R4; method = "hrp", cov = "gerber")')

# ── Optionen ─────────────────────────────────────────────────────────────────
cs("po_upper", "portfolio_optimize(R, upper = 0.6)", "result = O.portfolio_optimize(R, upper=0.6)",
   jl = 'result = O.portfolio_optimize(R; upper = 0.6)')
cs("po_upper_named", "portfolio_optimize(R, method = 'max_sharpe', upper = c(anleihen = 0.3))",
   "import pandas as pd\nresult = O.portfolio_optimize(R, method='max_sharpe', upper=pd.Series({'anleihen': 0.3}))",
   jl = 'result = O.portfolio_optimize(R; method = "max_sharpe", upper = SL.named("anleihen" => 0.3))')
cs("po_upper_pos", "portfolio_optimize(R, upper = c(0.2, 0.2, 0.6))", "result = O.portfolio_optimize(R, upper=[0.2, 0.2, 0.6])",
   jl = 'result = O.portfolio_optimize(R; upper = [0.2, 0.2, 0.6])')
cs("po_lower", "portfolio_optimize(R4, method = 'mean_variance', lower = c(D = 0.1, A = 0.2), upper = 0.5)",
   "import pandas as pd\nresult = O.portfolio_optimize(R4, method='mean_variance', lower=pd.Series({'D': 0.1, 'A': 0.2}), upper=0.5)",
   jl = 'result = O.portfolio_optimize(R4; method = "mean_variance", lower = SL.named("D" => 0.1, "A" => 0.2), upper = 0.5)')
cs("po_upper_inf", "portfolio_optimize(R, upper = c(aktien = 0.3, reits = Inf))",
   "import pandas as pd, math\nresult = O.portfolio_optimize(R, upper=pd.Series({'aktien': 0.3, 'reits': math.inf}))",
   jl = 'result = O.portfolio_optimize(R; upper = SL.named("aktien" => 0.3, "reits" => Inf))')
cs("po_upper26", "portfolio_optimize(R4, upper = 26)", "result = O.portfolio_optimize(R4, upper=26)",
   jl = 'result = O.portfolio_optimize(R4; upper = 26)')
cs("po_upper_big2", "portfolio_optimize(R4, upper = c(A = 26, C = 1.5))", "import pandas as pd\nresult = O.portfolio_optimize(R4, upper=pd.Series({'A': 26, 'C': 1.5}))",
   jl = 'result = O.portfolio_optimize(R4; upper = SL.named("A" => 26, "C" => 1.5))')
cs("po_cvar_bounds", "portfolio_optimize(R4, method = 'min_cvar', alpha = 0.1, lower = 0.1, upper = 0.4)",
   "result = O.portfolio_optimize(R4, method='min_cvar', alpha=0.1, lower=0.1, upper=0.4)",
   jl = 'result = O.portfolio_optimize(R4; method = "min_cvar", alpha = 0.1, lower = 0.1, upper = 0.4)')
cs("po_cdar_bounds", "portfolio_optimize(R4, method = 'min_cdar', alpha = 0.2, upper = c(D = 0.3))",
   "import pandas as pd\nresult = O.portfolio_optimize(R4, method='min_cdar', alpha=0.2, upper=pd.Series({'D': 0.3}))",
   jl = 'result = O.portfolio_optimize(R4; method = "min_cdar", alpha = 0.2, upper = SL.named("D" => 0.3))')
cs("po_cvar_a05", "portfolio_optimize(R4, method = 'min_cvar', alpha = 0.5)", "result = O.portfolio_optimize(R4, method='min_cvar', alpha=0.5)",
   jl = 'result = O.portfolio_optimize(R4; method = "min_cvar", alpha = 0.5)')
cs("po_mu_named", "portfolio_optimize(R4, method = 'max_sharpe', mu = c(D = 8, C = 7, B = 6, A = 5))",
   "import pandas as pd\nresult = O.portfolio_optimize(R4, method='max_sharpe', mu=pd.Series({'D': 8, 'C': 7, 'B': 6, 'A': 5}))",
   jl = 'result = O.portfolio_optimize(R4; method = "max_sharpe", mu = SL.named("D" => 8, "C" => 7, "B" => 6, "A" => 5))')
cs("po_mu_pos", "portfolio_optimize(R4, method = 'mean_variance', mu = c(5, 6, 7, 8), risk_aversion = 10)",
   "result = O.portfolio_optimize(R4, method='mean_variance', mu=[5, 6, 7, 8], risk_aversion=10)",
   jl = 'result = O.portfolio_optimize(R4; method = "mean_variance", mu = [5, 6, 7, 8], risk_aversion = 10)')
cs("po_mu_scalar", "portfolio_optimize(R4, method = 'max_sharpe', mu = 5, risk_free = 1)",
   "result = O.portfolio_optimize(R4, method='max_sharpe', mu=5, risk_free=1)",
   jl = 'result = O.portfolio_optimize(R4; method = "max_sharpe", mu = 5, risk_free = 1)')
cs("po_mu_ignored", "portfolio_optimize(R4, mu = c(A = 3))", "import pandas as pd\nresult = O.portfolio_optimize(R4, mu=pd.Series({'A': 3}))",
   jl = 'result = O.portfolio_optimize(R4; mu = SL.named("A" => 3))')
cs("po_rf", "portfolio_optimize(R, method = 'max_sharpe', risk_free = 2)", "result = O.portfolio_optimize(R, method='max_sharpe', risk_free=2)",
   jl = 'result = O.portfolio_optimize(R; method = "max_sharpe", risk_free = 2)')
cs("po_ra", "portfolio_optimize(R, method = 'mean_variance', risk_aversion = 1)", "result = O.portfolio_optimize(R, method='mean_variance', risk_aversion=1)",
   jl = 'result = O.portfolio_optimize(R; method = "mean_variance", risk_aversion = 1)')
cs("po_budget_named", "portfolio_optimize(R, method = 'risk_parity', budget = c(aktien = 0.5, reits = 0.3, anleihen = 0.2))",
   "import pandas as pd\nresult = O.portfolio_optimize(R, method='risk_parity', budget=pd.Series({'aktien': 0.5, 'reits': 0.3, 'anleihen': 0.2}))",
   jl = 'result = O.portfolio_optimize(R; method = "risk_parity", budget = SL.named("aktien" => 0.5, "reits" => 0.3, "anleihen" => 0.2))')
cs("po_budget_pos", "portfolio_optimize(R, method = 'risk_parity', budget = c(5, 3, 2))", "result = O.portfolio_optimize(R, method='risk_parity', budget=[5, 3, 2])",
   jl = 'result = O.portfolio_optimize(R; method = "risk_parity", budget = [5, 3, 2])')
cs("po_budget_part", "portfolio_optimize(R4, method = 'risk_parity', budget = c(A = 1, C = 2))",
   "import pandas as pd\nresult = O.portfolio_optimize(R4, method='risk_parity', budget=pd.Series({'A': 1, 'C': 2}))",
   jl = 'result = O.portfolio_optimize(R4; method = "risk_parity", budget = SL.named("A" => 1, "C" => 2))')
cs("po_budget_scalar", "portfolio_optimize(R4, method = 'risk_parity', budget = 2)", "result = O.portfolio_optimize(R4, method='risk_parity', budget=2)",
   jl = 'result = O.portfolio_optimize(R4; method = "risk_parity", budget = 2)')
for (m in c("equal", "inverse_vol", "risk_parity", "hrp"))
  cs(paste0("po_ignored_", m), sprintf("portfolio_optimize(R, method = '%s', upper = 0.5)", m), sprintf("result = O.portfolio_optimize(R, method='%s', upper=0.5)", m),
   jl = sprintf('result = O.portfolio_optimize(R; method = "%s", upper = 0.5)', m))
for (fq in c("day", "month"))
  cs(paste0("po_freq_", fq), sprintf("portfolio_optimize(R, method = 'max_sharpe', frequency = '%s')", fq),
     sprintf("result = O.portfolio_optimize(R, method='max_sharpe', frequency='%s')", fq),
   jl = sprintf('result = O.portfolio_optimize(R; method = "max_sharpe", frequency = "%s")', fq))
cs("po_assets", "portfolio_optimize(R4, assets = c('D', 'B'), method = 'risk_parity')", "result = O.portfolio_optimize(R4, assets=['D', 'B'], method='risk_parity')",
   jl = 'result = O.portfolio_optimize(R4; assets = ["D", "B"], method = "risk_parity")')
cs("po_na_rows", "portfolio_optimize(Rna)", "result = O.portfolio_optimize(Rna)",
   jl = 'result = O.portfolio_optimize(Rna)')
cs("po_noname", "portfolio_optimize(Rnn, method = 'hrp')", "result = O.portfolio_optimize(Rnn, method='hrp')",
   jl = 'result = O.portfolio_optimize(Rnn; method = "hrp")')
cs("po_resample", "portfolio_optimize(R, resample = 6, seed = 1)", "result = O.portfolio_optimize(R, resample=6, seed=1)",
   jl = 'result = O.portfolio_optimize(R; resample = 6, seed = 1)')
cs("po_resample_ms", "portfolio_optimize(R4, method = 'max_sharpe', resample = 3, block = 5, seed = 7)",
   "result = O.portfolio_optimize(R4, method='max_sharpe', resample=3, block=5, seed=7)",
   jl = 'result = O.portfolio_optimize(R4; method = "max_sharpe", resample = 3, block = 5, seed = 7)')
cs("po_resample_null", "set.seed(3); x <- portfolio_optimize(R, method = 'risk_parity', resample = 4); list(x, runif(2))",
   "RNG.set_seed(3); x = O.portfolio_optimize(R, method='risk_parity', resample=4); result = [x, RNG.runif(2)]",
   jl = 'SL.RRng.set_seed(3); x = O.portfolio_optimize(R; method = "risk_parity", resample = 4); result = [x, SL.RRng.runif(2)]')
cs("po_resample_restore", "set.seed(4); x <- portfolio_optimize(R, method = 'hrp', resample = 3, seed = 9); list(x$weights, x$resampled, runif(2))",
   "RNG.set_seed(4); x = O.portfolio_optimize(R, method='hrp', resample=3, seed=9); result = [x.weights, x.resampled, RNG.runif(2)]",
   jl = 'SL.RRng.set_seed(4); x = O.portfolio_optimize(R; method = "hrp", resample = 3, seed = 9); result = [x["weights"], x["resampled"], SL.RRng.runif(2)]')
cs("po_resample_n1", "portfolio_optimize(R1, resample = 5, seed = 1)", "result = O.portfolio_optimize(R1, resample=5, seed=1)",
   jl = 'result = O.portfolio_optimize(R1; resample = 5, seed = 1)')
cs("po_n1", "portfolio_optimize(R1, method = 'hrp')", "result = O.portfolio_optimize(R1, method='hrp')",
   jl = 'result = O.portfolio_optimize(R1; method = "hrp")')
cs("po_flat_mv", "portfolio_optimize(Rc)", "result = O.portfolio_optimize(Rc)",
   jl = 'result = O.portfolio_optimize(Rc)')
cs("po_flat_denoise", "portfolio_optimize(Rc, cov = 'denoise')", "result = O.portfolio_optimize(Rc, cov='denoise')",
   jl = 'result = O.portfolio_optimize(Rc; cov = "denoise")')
cs("po_flat_ms", "portfolio_optimize(Rc, method = 'max_sharpe')", "result = O.portfolio_optimize(Rc, method='max_sharpe')",
   jl = 'result = O.portfolio_optimize(Rc; method = "max_sharpe")')
cs("po_flat_only", "portfolio_optimize(cbind(a = rep(0.001, 20), b = rep(0.002, 20)), method = 'equal')",
   "import numpy as np, pandas as pd\nresult = O.portfolio_optimize(pd.DataFrame({'a': np.repeat(0.001, 20), 'b': np.repeat(0.002, 20)}), method='equal')",
   jl = 'result = O.portfolio_optimize(SL.NamedMat(hcat(fill(0.001, 20), fill(0.002, 20)); colnames = ["a", "b"]); method = "equal")')
for (m in c("risk_parity", "hrp", "inverse_vol"))
  cs(paste0("po_flat_err_", m), sprintf("portfolio_optimize(Rc, method = '%s')", m), sprintf("result = O.portfolio_optimize(Rc, method='%s')", m),
   jl = sprintf('result = O.portfolio_optimize(Rc; method = "%s")', m))

# ── Kursdaten ────────────────────────────────────────────────────────────────
cs("po_df_week", "portfolio_optimize(d)", "result = O.portfolio_optimize(d)",
   jl = 'result = O.portfolio_optimize(d)')
cs("po_df_month", "portfolio_optimize(d, method = 'max_sharpe', frequency = 'month')", "result = O.portfolio_optimize(d, method='max_sharpe', frequency='month')",
   jl = 'result = O.portfolio_optimize(d; method = "max_sharpe", frequency = "month")')
cs("po_df_day", "portfolio_optimize(d, assets = c('gold', 'aktien'), method = 'min_cvar', frequency = 'day')",
   "result = O.portfolio_optimize(d, assets=['gold', 'aktien'], method='min_cvar', frequency='day')",
   jl = 'result = O.portfolio_optimize(d; assets = ["gold", "aktien"], method = "min_cvar", frequency = "day")')
cs("po_df_posixct", "dp <- d; dp$date <- as.POSIXct(format(d$date), tz = 'Europe/Berlin'); portfolio_optimize(dp, method = 'risk_parity', frequency = 'month')",
   "import pandas as pd\ndp = d.copy(); dp['date'] = pd.to_datetime(d['date']).dt.tz_localize('Europe/Berlin'); result = O.portfolio_optimize(dp, method='risk_parity', frequency='month')",
   jl = 'dp = copy(d); dp["date"] = DateTime.(d.date); result = O.portfolio_optimize(dp; method = "risk_parity", frequency = "month")')
cs("po_df_na", "portfolio_optimize(dna, method = 'risk_parity')", "result = O.portfolio_optimize(dna, method='risk_parity')", inputs = list(dna = dna),
   jl = 'result = O.portfolio_optimize(dna; method = "risk_parity")')
cs("po_df_unsorted", "portfolio_optimize(dsh, method = 'hrp')", "result = O.portfolio_optimize(dsh, method='hrp')", inputs = list(dsh = dsh),
   jl = 'result = O.portfolio_optimize(dsh; method = "hrp")')
cs("po_df_dup", "portfolio_optimize(ddup)", "result = O.portfolio_optimize(ddup)", inputs = list(ddup = ddup),
   jl = 'result = O.portfolio_optimize(ddup)')
cs("po_df_zero", "portfolio_optimize(d0)", "result = O.portfolio_optimize(d0)", inputs = list(d0 = d0),
   jl = 'result = O.portfolio_optimize(d0)')
cs("po_df_char", "portfolio_optimize(data.frame(date = d$date[1:50], a = as.character(1:50)))",
   "import pandas as pd\nresult = O.portfolio_optimize(pd.DataFrame({'date': d['date'][:50], 'a': [str(i) for i in range(1, 51)]}))",
   jl = 'result = O.portfolio_optimize(SL.RFrame("date" => d.date[1:50], "a" => string.(1:50)))')

# ── Fehler ───────────────────────────────────────────────────────────────────
cs("err_few", "portfolio_optimize(R[1:7, ])", "result = O.portfolio_optimize(R.iloc[:7])",
   jl = 'result = O.portfolio_optimize(SL.NamedMat(R.data[1:7, :]; colnames = R.colnames))')
cs("err_bounds", "portfolio_optimize(R, upper = 0.2)", "result = O.portfolio_optimize(R, upper=0.2)",
   jl = 'result = O.portfolio_optimize(R; upper = 0.2)')
cs("err_bounds_lo", "portfolio_optimize(R, lower = 0.5)", "result = O.portfolio_optimize(R, lower=0.5)",
   jl = 'result = O.portfolio_optimize(R; lower = 0.5)')
cs("err_bounds_lohi", "portfolio_optimize(R, lower = c(aktien = 0.5), upper = c(aktien = 0.4))",
   "import pandas as pd\nresult = O.portfolio_optimize(R, lower=pd.Series({'aktien': 0.5}), upper=pd.Series({'aktien': 0.4}))",
   jl = 'result = O.portfolio_optimize(R; lower = SL.named("aktien" => 0.5), upper = SL.named("aktien" => 0.4))')
cs("err_unknown", "portfolio_optimize(R, upper = c(anleihe = 0.5, gold = 0.1))", "import pandas as pd\nresult = O.portfolio_optimize(R, upper=pd.Series({'anleihe': 0.5, 'gold': 0.1}))",
   jl = 'result = O.portfolio_optimize(R; upper = SL.named("anleihe" => 0.5, "gold" => 0.1))')
cs("err_len", "portfolio_optimize(R, upper = c(0.5, 0.5))", "result = O.portfolio_optimize(R, upper=[0.5, 0.5])",
   jl = 'result = O.portfolio_optimize(R; upper = [0.5, 0.5])')
cs("err_na", "portfolio_optimize(R, upper = c(aktien = NA))", "import pandas as pd, math\nresult = O.portfolio_optimize(R, upper=pd.Series({'aktien': simlev._r.fmt.NA_REAL}))",
   jl = 'result = O.portfolio_optimize(R; upper = SL.named("aktien" => SL.NA))')
cs("err_chr", "portfolio_optimize(R, lower = 'a')", "result = O.portfolio_optimize(R, lower='a')",
   jl = 'result = O.portfolio_optimize(R; lower = "a")')
cs("err_neg", "portfolio_optimize(R, method = 'mean_variance', lower = -0.5)", "result = O.portfolio_optimize(R, method='mean_variance', lower=-0.5)",
   jl = 'result = O.portfolio_optimize(R; method = "mean_variance", lower = -0.5)')
cs("err_neg2", "portfolio_optimize(R, lower = c(-0.5, 0, -0.25))", "result = O.portfolio_optimize(R, lower=[-0.5, 0, -0.25])",
   jl = 'result = O.portfolio_optimize(R; lower = [-0.5, 0, -0.25])')
cs("err_alpha5", "portfolio_optimize(R, method = 'min_cvar', alpha = 5)", "result = O.portfolio_optimize(R, method='min_cvar', alpha=5)",
   jl = 'result = O.portfolio_optimize(R; method = "min_cvar", alpha = 5)')
cs("err_alpha95", "portfolio_optimize(R, method = 'min_cvar', alpha = 0.95)", "result = O.portfolio_optimize(R, method='min_cvar', alpha=0.95)",
   jl = 'result = O.portfolio_optimize(R; method = "min_cvar", alpha = 0.95)')
cs("err_alpha0", "portfolio_optimize(R, alpha = 0)", "result = O.portfolio_optimize(R, alpha=0)",
   jl = 'result = O.portfolio_optimize(R; alpha = 0)')
cs("err_alpha_vec", "portfolio_optimize(R, alpha = c(0.1, 0.2))", "result = O.portfolio_optimize(R, alpha=[0.1, 0.2])",
   jl = 'result = O.portfolio_optimize(R; alpha = [0.1, 0.2])')
cs("err_mu_unknown", "portfolio_optimize(R4, method = 'max_sharpe', mu = c(A = 5, B = 6, C = 7, X = 8))",
   "import pandas as pd\nresult = O.portfolio_optimize(R4, method='max_sharpe', mu=pd.Series({'A': 5, 'B': 6, 'C': 7, 'X': 8}))",
   jl = 'result = O.portfolio_optimize(R4; method = "max_sharpe", mu = SL.named("A" => 5, "B" => 6, "C" => 7, "X" => 8))')
cs("err_mu_missing", "portfolio_optimize(R4, method = 'max_sharpe', mu = c(A = 5, B = 6))",
   "import pandas as pd\nresult = O.portfolio_optimize(R4, method='max_sharpe', mu=pd.Series({'A': 5, 'B': 6}))",
   jl = 'result = O.portfolio_optimize(R4; method = "max_sharpe", mu = SL.named("A" => 5, "B" => 6))')
cs("err_mu_missing_mv", "portfolio_optimize(R4, method = 'mean_variance', mu = c(C = 5))",
   "import pandas as pd\nresult = O.portfolio_optimize(R4, method='mean_variance', mu=pd.Series({'C': 5}))",
   jl = 'result = O.portfolio_optimize(R4; method = "mean_variance", mu = SL.named("C" => 5))')
cs("err_mu_len", "portfolio_optimize(R4, method = 'max_sharpe', mu = c(5, 6))", "result = O.portfolio_optimize(R4, method='max_sharpe', mu=[5, 6])",
   jl = 'result = O.portfolio_optimize(R4; method = "max_sharpe", mu = [5, 6])')
cs("err_mu_inf", "portfolio_optimize(R4, method = 'max_sharpe', mu = c(5, 6, Inf, 8))",
   "import math\nresult = O.portfolio_optimize(R4, method='max_sharpe', mu=[5, 6, math.inf, 8])",
   jl = 'result = O.portfolio_optimize(R4; method = "max_sharpe", mu = [5, 6, Inf, 8])')
cs("err_budget", "portfolio_optimize(R, method = 'risk_parity', budget = c(1, -1, 0.5))", "result = O.portfolio_optimize(R, method='risk_parity', budget=[1, -1, 0.5])",
   jl = 'result = O.portfolio_optimize(R; method = "risk_parity", budget = [1, -1, 0.5])')
cs("err_budget0", "portfolio_optimize(R, method = 'risk_parity', budget = c(reits = 0))",
   "import pandas as pd\nresult = O.portfolio_optimize(R, method='risk_parity', budget=pd.Series({'reits': 0}))",
   jl = 'result = O.portfolio_optimize(R; method = "risk_parity", budget = SL.named("reits" => 0))')
cs("err_method", "portfolio_optimize(R, method = 'foo')", "result = O.portfolio_optimize(R, method='foo')",
   jl = 'result = O.portfolio_optimize(R; method = "foo")')
cs("err_cov", "portfolio_optimize(R, cov = 'foo')", "result = O.portfolio_optimize(R, cov='foo')",
   jl = 'result = O.portfolio_optimize(R; cov = "foo")')
cs("err_inf", "portfolio_optimize(Rinf)", "result = O.portfolio_optimize(Rinf)",
   jl = 'result = O.portfolio_optimize(Rinf)')
cs("err_assets", "portfolio_optimize(R, assets = c('aktien', 'gold'))", "result = O.portfolio_optimize(R, assets=['aktien', 'gold'])",
   jl = 'result = O.portfolio_optimize(R; assets = ["aktien", "gold"])')
cs("err_nonnum", "portfolio_optimize(matrix(letters[1:20], 10))", "import numpy as np\nresult = O.portfolio_optimize(np.array([[chr(97 + i + 10 * j) for j in range(2)] for i in range(10)], dtype=object))",
   jl = 'result = O.portfolio_optimize(reshape([string(c) for c in "abcdefghijklmnopqrst"], 10, 2))')

# ── efficient_frontier ───────────────────────────────────────────────────────
cs("ef_default", "efficient_frontier(R)", "result = O.efficient_frontier(R)",
   jl = 'result = O.efficient_frontier(R)')
cs("ef_upper", "efficient_frontier(R4, n = 12, upper = 0.5, risk_free = 1)", "result = O.efficient_frontier(R4, n=12, upper=0.5, risk_free=1)",
   jl = 'result = O.efficient_frontier(R4; n = 12, upper = 0.5, risk_free = 1)')
for (ct in c("ledoit_wolf", "ewma", "denoise", "gerber"))
  cs(paste0("ef_cov_", ct), sprintf("efficient_frontier(R4, n = 8, cov = '%s')", ct), sprintf("result = O.efficient_frontier(R4, n=8, cov='%s')", ct),
   jl = sprintf('result = O.efficient_frontier(R4; n = 8, cov = "%s")', ct))
cs("ef_df", "efficient_frontier(d, n = 10, frequency = 'month', lower = c(gold = 0.1))",
   "import pandas as pd\nresult = O.efficient_frontier(d, n=10, frequency='month', lower=pd.Series({'gold': 0.1}))",
   jl = 'result = O.efficient_frontier(d; n = 10, frequency = "month", lower = SL.named("gold" => 0.1))')
cs("ef_n1", "efficient_frontier(R1, n = 5)", "result = O.efficient_frontier(R1, n=5)",
   jl = 'result = O.efficient_frontier(R1; n = 5)')
cs("ef_flat", "efficient_frontier(Rc, n = 6)", "result = O.efficient_frontier(Rc, n=6)",
   jl = 'result = O.efficient_frontier(Rc; n = 6)')
cs("ef_n1pt", "efficient_frontier(R, n = 1)", "result = O.efficient_frontier(R, n=1)",
   jl = 'result = O.efficient_frontier(R; n = 1)')
cs("ef_err", "efficient_frontier(R, upper = 0.2, n = 5)", "result = O.efficient_frontier(R, upper=0.2, n=5)",
   jl = 'result = O.efficient_frontier(R; upper = 0.2, n = 5)')
cs("ef_err_lo", "efficient_frontier(R, lower = 0.5, n = 5)", "result = O.efficient_frontier(R, lower=0.5, n=5)",
   jl = 'result = O.efficient_frontier(R; lower = 0.5, n = 5)')
cs("ef_warn26", "efficient_frontier(R, upper = 26, n = 4)", "result = O.efficient_frontier(R, upper=26, n=4)",
   jl = 'result = O.efficient_frontier(R; upper = 26, n = 4)')

# ── risk_contributions ───────────────────────────────────────────────────────
cs("rc_vol", "risk_contributions(R, c(aktien = 0.5, reits = 0.2, anleihen = 0.3))",
   "import pandas as pd\nresult = O.risk_contributions(R, pd.Series({'aktien': 0.5, 'reits': 0.2, 'anleihen': 0.3}))",
   jl = 'result = O.risk_contributions(R, SL.named("aktien" => 0.5, "reits" => 0.2, "anleihen" => 0.3))')
cs("rc_cvar", "risk_contributions(R, c(aktien = 0.5, reits = 0, anleihen = 0.5), measure = 'cvar')",
   "import pandas as pd\nresult = O.risk_contributions(R, pd.Series({'aktien': 0.5, 'reits': 0, 'anleihen': 0.5}), measure='cvar')",
   jl = 'result = O.risk_contributions(R, SL.named("aktien" => 0.5, "reits" => 0, "anleihen" => 0.5); measure = "cvar")')
cs("rc_cvar_a", "risk_contributions(R4, c(D = 0.4, A = 0.6), measure = 'cvar', alpha = 0.2)",
   "import pandas as pd\nresult = O.risk_contributions(R4, pd.Series({'D': 0.4, 'A': 0.6}), measure='cvar', alpha=0.2)",
   jl = 'result = O.risk_contributions(R4, SL.named("D" => 0.4, "A" => 0.6); measure = "cvar", alpha = 0.2)')
cs("rc_opt", "risk_contributions(R4, portfolio_optimize(R4, method = 'hrp'), cov = 'ledoit_wolf')",
   "result = O.risk_contributions(R4, O.portfolio_optimize(R4, method='hrp'), cov='ledoit_wolf')",
   jl = 'result = O.risk_contributions(R4, O.portfolio_optimize(R4; method = "hrp"); cov = "ledoit_wolf")')
for (ct in c("ewma", "denoise", "gerber"))
  cs(paste0("rc_cov_", ct), sprintf("risk_contributions(R4, c(A = 0.25, B = 0.25, C = 0.25, D = 0.25), cov = '%s', frequency = 'month')", ct),
     sprintf("import pandas as pd\nresult = O.risk_contributions(R4, pd.Series({'A': 0.25, 'B': 0.25, 'C': 0.25, 'D': 0.25}), cov='%s', frequency='month')", ct),
   jl = sprintf('result = O.risk_contributions(R4, SL.named("A" => 0.25, "B" => 0.25, "C" => 0.25, "D" => 0.25); cov = "%s", frequency = "month")', ct))
cs("rc_df", "risk_contributions(d, c(gold = 0.3, aktien = 0.7), frequency = 'day')",
   "import pandas as pd\nresult = O.risk_contributions(d, pd.Series({'gold': 0.3, 'aktien': 0.7}), frequency='day')",
   jl = 'result = O.risk_contributions(d, SL.named("gold" => 0.3, "aktien" => 0.7); frequency = "day")')
cs("rc_noname_mat", "risk_contributions(Rnn, c(A2 = 0.5, A3 = 0.5))", "import pandas as pd\nresult = O.risk_contributions(Rnn, pd.Series({'A2': 0.5, 'A3': 0.5}))",
   jl = 'result = O.risk_contributions(Rnn, SL.named("A2" => 0.5, "A3" => 0.5))')
cs("rc_err_unnamed", "risk_contributions(R, c(0.5, 0.2, 0.3))", "result = O.risk_contributions(R, [0.5, 0.2, 0.3])",
   jl = 'result = O.risk_contributions(R, [0.5, 0.2, 0.3])')
cs("rc_err_unknown", "risk_contributions(R, c(aktien = 0.5, gold = 0.5))", "import pandas as pd\nresult = O.risk_contributions(R, pd.Series({'aktien': 0.5, 'gold': 0.5}))",
   jl = 'result = O.risk_contributions(R, SL.named("aktien" => 0.5, "gold" => 0.5))')
cs("rc_err_unknown_df", "risk_contributions(d, c(aktien = 0.5, bar = 0.5))", "import pandas as pd\nresult = O.risk_contributions(d, pd.Series({'aktien': 0.5, 'bar': 0.5}))",
   jl = 'result = O.risk_contributions(d, SL.named("aktien" => 0.5, "bar" => 0.5))')
cs("rc_err_alpha", "risk_contributions(R4, c(A = 0.5, B = 0.5), measure = 'cvar', alpha = 0.95)",
   "import pandas as pd\nresult = O.risk_contributions(R4, pd.Series({'A': 0.5, 'B': 0.5}), measure='cvar', alpha=0.95)",
   jl = 'result = O.risk_contributions(R4, SL.named("A" => 0.5, "B" => 0.5); measure = "cvar", alpha = 0.95)')
cs("rc_err_na", "risk_contributions(R4, c(A = 0.5, B = NA))", "import pandas as pd, math\nresult = O.risk_contributions(R4, pd.Series({'A': 0.5, 'B': simlev._r.fmt.NA_REAL}))",
   jl = 'result = O.risk_contributions(R4, SL.named("A" => 0.5, "B" => SL.NA))')

# ── rolling_optimization ─────────────────────────────────────────────────────
set.seed(1); n2 <- 4 * 365
d2 <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n2))
d2$a <- 100 * cumprod(1 + rnorm(n2, 3e-4, 0.01)); d2$b <- 100 * cumprod(1 + rnorm(n2, 1e-4, 0.003))
d2$c <- 100 * cumprod(1 + rnorm(n2, 2e-4, 0.007))
d2s <- d2[c(n2:1001, 1:1000), ]
I2 <- list(d2 = d2)
cs("ro_default", "rolling_optimization(d2, c('a', 'b'), window = 2, every = 'quarter')",
   "result = O.rolling_optimization(d2, ['a', 'b'], window=2, every='quarter')", inputs = I2,
   jl = 'result = O.rolling_optimization(d2, ["a", "b"]; window = 2, every = "quarter")')
cs("ro_attrs", "w <- rolling_optimization(d2, c('a', 'b', 'c'), 'inverse_vol', window = 2); list(attr(w, 'decision_rows'), attr(w, 'failed_dates'), attr(w, 'source'))",
   "w = O.rolling_optimization(d2, ['a', 'b', 'c'], 'inverse_vol', window=2); result = [w.attrs['decision_rows'], w.attrs['failed_dates'], w.attrs['source']]", inputs = I2,
   jl = 'w = O.rolling_optimization(d2, ["a", "b", "c"]; method = "inverse_vol", window = 2)
result = [SL.attrs(w)["decision_rows"], SL.attrs(w)["failed_dates"], SL.attrs(w)["source"]]')
cs("ro_rp_year", "rolling_optimization(d2, c('c', 'a', 'b'), 'risk_parity', window = 1.5, every = 'year', frequency = 'month')",
   "result = O.rolling_optimization(d2, ['c', 'a', 'b'], 'risk_parity', window=1.5, every='year', frequency='month')", inputs = I2,
   jl = 'result = O.rolling_optimization(d2, ["c", "a", "b"]; method = "risk_parity", window = 1.5, every = "year", frequency = "month")')
cs("ro_upper", "rolling_optimization(d2, c('a', 'b', 'c'), window = 2, every = 'quarter', upper = 70)",
   "result = O.rolling_optimization(d2, ['a', 'b', 'c'], window=2, every='quarter', upper=70)", inputs = I2,
   jl = 'result = O.rolling_optimization(d2, ["a", "b", "c"]; window = 2, every = "quarter", upper = 70)')
cs("ro_bounds", "rolling_optimization(d2, c('a', 'b', 'c'), 'max_sharpe', window = 2, every = 'quarter', upper = c(b = 0.5), mu = c(a = 6, b = 2, c = 4))",
   "import pandas as pd\nresult = O.rolling_optimization(d2, ['a', 'b', 'c'], 'max_sharpe', window=2, every='quarter', upper=pd.Series({'b': 0.5}), mu=pd.Series({'a': 6, 'b': 2, 'c': 4}))", inputs = I2,
   jl = 'result = O.rolling_optimization(d2, ["a", "b", "c"]; method = "max_sharpe", window = 2, every = "quarter", upper = SL.named("b" => 0.5), mu = SL.named("a" => 6, "b" => 2, "c" => 4))')
cs("ro_fail", "w <- rolling_optimization(d2, c('a', 'b'), window = 0.5, frequency = 'month'); list(w, attr(w, 'failed_dates'))",
   "w = O.rolling_optimization(d2, ['a', 'b'], window=0.5, frequency='month'); result = [w, w.attrs['failed_dates']]", inputs = I2,
   jl = 'w = O.rolling_optimization(d2, ["a", "b"]; window = 0.5, frequency = "month"); result = [w, SL.attrs(w)["failed_dates"]]')
cs("ro_unsorted", "rolling_optimization(d2s, c('a', 'b'), window = 2, every = 'year')",
   "result = O.rolling_optimization(d2s, ['a', 'b'], window=2, every='year')", inputs = list(d2s = d2s),
   jl = 'result = O.rolling_optimization(d2s, ["a", "b"]; window = 2, every = "year")')
cs("ro_n1", "rolling_optimization(d2, 'a', window = 2)", "result = O.rolling_optimization(d2, 'a', window=2)", inputs = I2,
   jl = 'result = O.rolling_optimization(d2, "a"; window = 2)')
cs("ro_err_method", "rolling_optimization(d2, c('a', 'b'), method = 'min_varianze', window = 2)",
   "result = O.rolling_optimization(d2, ['a', 'b'], method='min_varianze', window=2)", inputs = I2,
   jl = 'result = O.rolling_optimization(d2, ["a", "b"]; method = "min_varianze", window = 2)')
cs("ro_err_bounds", "rolling_optimization(d2, c('a', 'b'), window = 2, upper = 0.2)", "result = O.rolling_optimization(d2, ['a', 'b'], window=2, upper=0.2)", inputs = I2,
   jl = 'result = O.rolling_optimization(d2, ["a", "b"]; window = 2, upper = 0.2)')
cs("ro_err_arg", "rolling_optimization(d2, c('a', 'b'), window = 2, uper = 0.5)", "result = O.rolling_optimization(d2, ['a', 'b'], window=2, uper=0.5)", inputs = I2,
   jl = 'result = O.rolling_optimization(d2, ["a", "b"]; window = 2, uper = 0.5)')
cs("ro_err_alpha", "rolling_optimization(d2, c('a', 'b'), window = 2, alpha = 0.95)", "result = O.rolling_optimization(d2, ['a', 'b'], window=2, alpha=0.95)", inputs = I2,
   jl = 'result = O.rolling_optimization(d2, ["a", "b"]; window = 2, alpha = 0.95)')
cs("ro_err_mu", "rolling_optimization(d2, c('a', 'b'), window = 2, mu = c(x = 1))",
   "import pandas as pd\nresult = O.rolling_optimization(d2, ['a', 'b'], window=2, mu=pd.Series({'x': 1}))", inputs = I2,
   jl = 'result = O.rolling_optimization(d2, ["a", "b"]; window = 2, mu = SL.named("x" => 1))')
cs("ro_err_df", "rolling_optimization(R, c('aktien'), window = 2)", "result = O.rolling_optimization(R, ['aktien'], window=2)",
   jl = 'result = O.rolling_optimization(R, ["aktien"]; window = 2)')
cs("ro_err_cols", "rolling_optimization(d2, c('a', 'z'), window = 2)", "result = O.rolling_optimization(d2, ['a', 'z'], window=2)", inputs = I2,
   jl = 'result = O.rolling_optimization(d2, ["a", "z"]; window = 2)')
cs("ro_err_short", "rolling_optimization(d2, c('a', 'b'), window = 5)", "result = O.rolling_optimization(d2, ['a', 'b'], window=5)", inputs = I2,
   jl = 'result = O.rolling_optimization(d2, ["a", "b"]; window = 5)')

# ── cpcv_portfolio ───────────────────────────────────────────────────────────
cs("cp_basic", "cpcv_portfolio(R, methods = c('equal', 'inverse_vol', 'min_variance'), n_groups = 5, test_groups = 2)",
   "result = O.cpcv_portfolio(R, methods=['equal', 'inverse_vol', 'min_variance'], n_groups=5, test_groups=2)",
   jl = 'result = O.cpcv_portfolio(R; methods = ["equal", "inverse_vol", "min_variance"], n_groups = 5, test_groups = 2)')
cs("cp_default", "cpcv_portfolio(R4[1:120, ], n_groups = 4)", "result = O.cpcv_portfolio(R4.iloc[:120], n_groups=4)",
   jl = 'result = O.cpcv_portfolio(SL.NamedMat(R4.data[1:120, :]; colnames = R4.colnames); n_groups = 4)')
cs("cp_list", "cpcv_portfolio(R4, methods = list(mv = list(method = 'min_variance', cov = 'ledoit_wolf'), rp = list(method = 'risk_parity'), eq = list()),
                              n_groups = 4, test_groups = 1, purge = 0, embargo = 3)",
   "result = O.cpcv_portfolio(R4, methods={'mv': {'method': 'min_variance', 'cov': 'ledoit_wolf'}, 'rp': {'method': 'risk_parity'}, 'eq': {}},
                          n_groups=4, test_groups=1, purge=0, embargo=3)",
   jl = 'result = O.cpcv_portfolio(R4; methods = SL.RList("mv" => SL.RList("method" => "min_variance", "cov" => "ledoit_wolf"), "rp" => SL.RList("method" => "risk_parity"), "eq" => SL.RList()),
                         n_groups = 4, test_groups = 1, purge = 0, embargo = 3)')
cs("cp_df_day", "cpcv_portfolio(d, methods = 'min_variance', frequency = 'day', n_groups = 4, test_groups = 1, purge = 5, embargo = 0)",
   "result = O.cpcv_portfolio(d, methods='min_variance', frequency='day', n_groups=4, test_groups=1, purge=5, embargo=0)",
   jl = 'result = O.cpcv_portfolio(d; methods = "min_variance", frequency = "day", n_groups = 4, test_groups = 1, purge = 5, embargo = 0)')
cs("cp_partial", "cpcv_portfolio(R, methods = list(eq = list(method = 'equal'), bad = list(method = 'min_variance', upper = 0.2)), n_groups = 3, test_groups = 1)",
   "result = O.cpcv_portfolio(R, methods={'eq': {'method': 'equal'}, 'bad': {'method': 'min_variance', 'upper': 0.2}}, n_groups=3, test_groups=1)",
   jl = 'result = O.cpcv_portfolio(R; methods = SL.RList("eq" => SL.RList("method" => "equal"), "bad" => SL.RList("method" => "min_variance", "upper" => 0.2)), n_groups = 3, test_groups = 1)')
cs("cp_warn26", "cpcv_portfolio(R, methods = list(a = list(upper = 26), b = list(method = 'equal')), n_groups = 3, test_groups = 1)",
   "result = O.cpcv_portfolio(R, methods={'a': {'upper': 26}, 'b': {'method': 'equal'}}, n_groups=3, test_groups=1)",
   jl = 'result = O.cpcv_portfolio(R; methods = SL.RList("a" => SL.RList("upper" => 26), "b" => SL.RList("method" => "equal")), n_groups = 3, test_groups = 1)')
cs("cp_err_allfail", "cpcv_portfolio(R, methods = list(a = list(method = 'min_variance', upper = 0.2)))",
   "result = O.cpcv_portfolio(R, methods={'a': {'method': 'min_variance', 'upper': 0.2}})",
   jl = 'result = O.cpcv_portfolio(R; methods = SL.RList("a" => SL.RList("method" => "min_variance", "upper" => 0.2)))')
cs("cp_err_method", "cpcv_portfolio(R, methods = c('equal', 'min_varianze'))", "result = O.cpcv_portfolio(R, methods=['equal', 'min_varianze'])",
   jl = 'result = O.cpcv_portfolio(R; methods = ["equal", "min_varianze"])')
cs("cp_err_groups", "cpcv_portfolio(R, n_groups = 3, test_groups = 3)", "result = O.cpcv_portfolio(R, n_groups=3, test_groups=3)",
   jl = 'result = O.cpcv_portfolio(R; n_groups = 3, test_groups = 3)')
cs("cp_err_purge", "cpcv_portfolio(R, methods = 'equal', purge = -1)", "result = O.cpcv_portfolio(R, methods='equal', purge=-1)",
   jl = 'result = O.cpcv_portfolio(R; methods = "equal", purge = -1)')
cs("cp_err_ng", "cpcv_portfolio(R, n_groups = 2.5)", "result = O.cpcv_portfolio(R, n_groups=2.5)",
   jl = 'result = O.cpcv_portfolio(R; n_groups = 2.5)')
cs("cp_err_arg", "cpcv_portfolio(R, methods = list(a = list(method = 'equal', foo = 1)))", "result = O.cpcv_portfolio(R, methods={'a': {'method': 'equal', 'foo': 1}})",
   jl = 'result = O.cpcv_portfolio(R; methods = SL.RList("a" => SL.RList("method" => "equal", "foo" => 1)))')
cs("cp_err_list", "cpcv_portfolio(R, methods = list(list(method = 'equal')))", "result = O.cpcv_portfolio(R, methods=[{'method': 'equal'}])",
   jl = 'result = O.cpcv_portfolio(R; methods = [SL.RList("method" => "equal")])')
cs("cp_err_entry", "cpcv_portfolio(R, methods = list(a = 'equal'))", "result = O.cpcv_portfolio(R, methods={'a': 'equal'})",
   jl = 'result = O.cpcv_portfolio(R; methods = SL.RList("a" => "equal"))')
ref_done()
