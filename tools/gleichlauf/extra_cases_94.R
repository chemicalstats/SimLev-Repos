# Zusatzfaelle der Gleichlaufpruefung (Etappe 9.4, Entwurf C.8/C.9): Modelle der C-Bibliothek
# slc. Modul "slc_models": GARCH/GJR, GPD, DCC, MS-GARCH und HMM, Bootstrap-Kerne in R
# (.sl_*), Python (simlev._lib) und Julia (SimLev.SLib), jeweils mit denselben Eingaben; die
# Bootstrap-Kerne ziehen aus Stroemen bzw. dem globalen Zustand (Hex-Vergleich der Zustaende).
#
# Aufruf aus der Repo-Wurzel (tools/gleichlauf/run.sh setzt SIMLEV_MODULE_DIR):
#   SIMLEV_MODULE_DIR=<ordner> R_LIBS=<R-Bibliothek> Rscript tools/gleichlauf/extra_cases_94.R
# Die Faelle werden immer vollstaendig erzeugt (SIMLEV_GEN_SUBSET gilt hier nicht).
Sys.setenv(SIMLEV_GEN_SUBSET = "1")
source("golden/modules/ref_tools.R")
ref_init("slc_models")

P <- "import math\nimport numpy as np\nimport simlev\nimport simlev._lib as L\n"
J <- "const L = SL.SLib\n"
cs <- function(id, r, py, jl, inputs = list())
  ref_case(id, r = paste0("sl <- asNamespace('SimLev')\n", r), py = paste0(P, py), jl = paste0(J, jl), inputs = inputs)

# ── Daten ───────────────────────────────────────────────────────────────────
sim_garch <- function(n, mu, om, al, ga, be, seed) {
  set.seed(seed); s2 <- om / (1 - al - ga / 2 - be); e <- numeric(n); ep <- 0
  for (t in 1:n) { if (t > 1) s2 <- om + (al + ga * (ep < 0)) * ep^2 + be * s2; ep <- sqrt(s2) * rnorm(1); e[t] <- mu + ep }
  e
}
sim_ms <- function(n, om, al, ga, be, P, seed) {
  set.seed(seed); K <- length(om); hk <- om / (1 - al - ga / 2 - be); s <- 1L; y <- numeric(n)
  for (t in seq_len(n)) {
    if (t > 1) { s <- sample.int(K, 1, prob = P[s, ]); e <- y[t - 1]; hk <- om + (al + ga * (e < 0)) * e^2 + be * hk }
    y[t] <- sqrt(hk[s]) * rnorm(1)
  }
  y
}
I <- list(
  g1 = sim_garch(800, 3e-4, 2e-6, 0.08, 0, 0.9, 1),
  g2 = sim_garch(600, 1e-4, 3e-6, 0.03, 0.10, 0.88, 2),
  ms2 = sim_ms(500, c(2e-6, 2e-5), c(0.02, 0.05), c(0.04, 0.10), c(0.92, 0.85), matrix(c(0.99, 0.01, 0.03, 0.97), 2, byrow = TRUE), 7),
  ms3 = sim_ms(400, c(1e-6, 4e-6, 2e-5), c(0.03, 0.05, 0.08), c(0, 0, 0), c(0.94, 0.90, 0.85),
               matrix(c(0.99, 0.007, 0.003, 0.01, 0.98, 0.01, 0.005, 0.025, 0.97), 3, byrow = TRUE), 1))
set.seed(5)
I$xg <- 0.01 * ((1 - runif(250))^(-0.2) - 1) / 0.2
I$xn <- 0.02 * ((1 - runif(120))^(0.3) - 1) / (-0.3)
I$xe <- rexp(200, 80)
I$xs <- I$xg[1:15]
I$Z <- cbind(rnorm(300), rnorm(300), rnorm(300)); I$Z[, 2] <- 0.6 * I$Z[, 1] + 0.8 * I$Z[, 2]
I$Q <- cor(I$Z)
I$Qbad <- matrix(c(1, 0.99, 0.2, 0.99, 1, 0.9, 0.2, 0.9, 1), 3)
I$X <- cbind(1 + rnorm(300, 4e-4, 0.011), 1 + rnorm(300, 2e-4, 0.006), 1 + rnorm(300, 0, 0.02))
I$reg <- sample(1:3, 300, TRUE)
I$tr <- matrix(c(.9, .05, .05, .1, .8, .1, .2, .2, .6), 3, byrow = TRUE)
I$zb <- rnorm(300); I$Zc <- matrix(rnorm(600), 300)
I$delta <- matrix(c(0, 0.5, -0.3, 0), 2)
I$P2 <- matrix(c(.95, .05, .1, .9), 2, byrow = TRUE)

case3 <- function(id, r, py, jl, inp) cs(id, r = r, py = paste0("result = ", py), jl = paste0("result = ", jl), inputs = I[inp])

# ── GARCH ───────────────────────────────────────────────────────────────────
case3("garch_filter", "sl$.sl_garch11_filter(g1 - 3e-4, 2e-6, 0.08, 0.9, 0.04, 1e-4)",
      "L.garch11_filter(g1 - 3e-4, 2e-6, 0.08, 0.9, 0.04, 1e-4)", "L.garch11_filter(g1 .- 3e-4, 2e-6, 0.08, 0.9, 0.04, 1e-4)", "g1")
case3("garch_nll", "c(sl$.sl_garch11_nll(g1, c(3e-4, 2e-6, 0.08, 0.9)), sl$.sl_garch11_nll(g2, c(1e-4, 3e-6, 0.03, 0.88, 0.1), TRUE, 1e-4))",
      "[L.garch11_nll(g1, [3e-4, 2e-6, 0.08, 0.9]), L.garch11_nll(g2, [1e-4, 3e-6, 0.03, 0.88, 0.1], True, 1e-4)]",
      "[L.garch11_nll(g1, [3e-4, 2e-6, 0.08, 0.9]), L.garch11_nll(g2, [1e-4, 3e-6, 0.03, 0.88, 0.1]; gjr = true, s2_init = 1e-4)]", c("g1", "g2"))
for (nm in c("g1", "g2")) for (gj in c(FALSE, TRUE)) {
  case3(sprintf("garch_fit_%s_%s", nm, if (gj) "gjr" else "s"), sprintf("sl$.sl_garch11_fit(%s, %s)", nm, gj),
        sprintf("L.garch11_fit(%s, %s)", nm, if (gj) "True" else "False"), sprintf("L.garch11_fit(%s; gjr = %s)", nm, tolower(gj)), nm)
  case3(sprintf("fit_garch11_%s_%s", nm, if (gj) "gjr" else "s"), sprintf("sl$.sl_fit_garch11(%s, %s)", nm, gj),
        sprintf("L.fit_garch11(%s, %s)", nm, if (gj) "True" else "False"), sprintf("L.fit_garch11(%s; gjr = %s)", nm, tolower(gj)), nm)
}
case3("fit_garch11_konstant", "sl$.sl_fit_garch11(rep(0.001, 50))", "L.fit_garch11(np.full(50, 0.001))", "L.fit_garch11(fill(0.001, 50))", character(0))
case3("fit_garch11_kurz_momente", "sl$.sl_fit_garch11(g1[1:6])", "L.fit_garch11(g1[:6])", "L.fit_garch11(g1[1:6])", "g1")
case3("fit_garch11_kurz_leise", "sl$.sl_fit_garch11(g1[1:6], quiet = TRUE)", "L.fit_garch11(g1[:6], quiet=True)", "L.fit_garch11(g1[1:6]; quiet = true)", "g1")
case3("garch_fit_err_kurz", "sl$.sl_garch11_fit(g1[1:9])", "L.garch11_fit(g1[:9])", "L.garch11_fit(g1[1:9])", "g1")
case3("garch_fit_err_nan", "sl$.sl_garch11_fit(c(g1[1:20], NaN))", "L.garch11_fit(np.append(g1[:20], math.nan))", "L.garch11_fit(vcat(g1[1:20], NaN))", "g1")

# ── GPD ─────────────────────────────────────────────────────────────────────
for (nm in c("xg", "xn", "xe", "xs"))
  case3(paste0("gpd_", nm), sprintf("list(sl$.sl_gpd_fit(%s), sl$.sl_gpd_pwm(%s), sl$.sl_gpd_nll(%s, 0.01, 0.1), sl$.sl_gpd_nll(%s, 0.01, 0))", nm, nm, nm, nm),
        sprintf("[L.gpd_fit(%s), L.gpd_pwm(%s), L.gpd_nll(%s, 0.01, 0.1), L.gpd_nll(%s, 0.01, 0.0)]", nm, nm, nm, nm),
        sprintf("Any[L.gpd_fit(%s), L.gpd_pwm(%s), L.gpd_nll(%s, 0.01, 0.1), L.gpd_nll(%s, 0.01, 0.0)]", nm, nm, nm, nm), nm)
case3("gpd_nll_traeger", "c(sl$.sl_gpd_nll(xn, 0.001, -0.5), sl$.sl_gpd_nll(xn, 0.01, 1e-12))",
      "[L.gpd_nll(xn, 0.001, -0.5), L.gpd_nll(xn, 0.01, 1e-12)]", "[L.gpd_nll(xn, 0.001, -0.5), L.gpd_nll(xn, 0.01, 1e-12)]", "xn")
case3("gpd_err_wenige", "sl$.sl_gpd_fit(xg[1:5])", "L.gpd_fit(xg[:5])", "L.gpd_fit(xg[1:5])", "xg")
case3("gpd_err_negativ", "sl$.sl_gpd_fit(c(-1, xg[1:20]))", "L.gpd_fit(np.append(-1.0, xg[:20]))", "L.gpd_fit(vcat(-1.0, xg[1:20]))", "xg")
case3("gpd_err_konstant", "sl$.sl_gpd_fit(rep(0.01, 30))", "L.gpd_fit(np.full(30, 0.01))", "L.gpd_fit(fill(0.01, 30))", character(0))

# ── DCC ─────────────────────────────────────────────────────────────────────
case3("dcc_filter", "list(sl$.sl_dcc_filter(Z, 0.03, 0.95, Q, TRUE), sl$.sl_dcc_filter(Z, 0.03, 0.95, Q, FALSE))",
      "[L.dcc_filter(Z, 0.03, 0.95, Q, True), L.dcc_filter(Z, 0.03, 0.95, Q, False)]",
      "Any[L.dcc_filter(Z, 0.03, 0.95, Q, true), L.dcc_filter(Z, 0.03, 0.95, Q, false)]", c("Z", "Q"))
case3("dcc_filter_nicht_pd", "sl$.sl_dcc_filter(Z, 0.03, 0.95, Qbad, TRUE)", "L.dcc_filter(Z, 0.03, 0.95, Qbad, True)",
      "L.dcc_filter(Z, 0.03, 0.95, Qbad, true)", c("Z", "Qbad"))
case3("dcc_fit", "sl$.sl_dcc_fit(Z, Q)", "L.dcc_fit(Z, Q)", "L.dcc_fit(Z, Q)", c("Z", "Q"))
case3("dcc_fit_2", "sl$.sl_dcc_fit(Z[, 1:2], Q[1:2, 1:2])", "L.dcc_fit(Z[:, :2], Q[:2, :2])", "L.dcc_fit(Z[:, 1:2], Q[1:2, 1:2])", c("Z", "Q"))
case3("dcc_err_nan", "sl$.sl_dcc_fit(rbind(Z, NA), Q)", "L.dcc_fit(np.vstack([Z, np.full((1, 3), math.nan)]), Q)",
      "L.dcc_fit(vcat(Z, fill(NaN, 1, 3)), Q)", c("Z", "Q"))

# ── MS-GARCH und HMM ────────────────────────────────────────────────────────
case3("ms_filter", "sl$.sl_ms_garch_filter(ms2, c(1e-6, 5e-6), c(.05, .1), c(.9, .8), c(.02, .05), P2, c(2/3, 1/3), 1e-4)",
      "L.ms_garch_filter(ms2, [1e-6, 5e-6], [.05, .1], [.9, .8], [.02, .05], P2, [2/3, 1/3], 1e-4)",
      "L.ms_garch_filter(ms2, [1e-6, 5e-6], [.05, .1], [.9, .8], [.02, .05], P2, [2/3, 1/3], 1e-4)", c("ms2", "P2"))
# 9.6c: Randfälle des gestrichenen Moduls bootstrap_core (früherer Filter .ms_garch_filter), neu gefasst
# für den slc-Filter: K = 3 mit GJR und eine Beobachtung mit Dichte 0 in allen Regimen (loglik = -Inf)
set.seed(11); I$ym <- rnorm(60, 0, 0.01); I$ym0 <- I$ym; I$ym0[20] <- 1
I$P3 <- matrix(c(.9, .05, .05, .1, .8, .1, .02, .08, .9), 3, byrow = TRUE)
case3("ms_filter_K3_gjr", "sl$.sl_ms_garch_filter(ym, c(1e-6, 3e-6, 1e-5), c(.03, .06, .1), c(.95, .9, .8), c(0, .04, .1), P3, c(.5, .3, .2), 1e-4)",
      "L.ms_garch_filter(ym, [1e-6, 3e-6, 1e-5], [.03, .06, .1], [.95, .9, .8], [0, .04, .1], P3, [.5, .3, .2], 1e-4)",
      "L.ms_garch_filter(ym, [1e-6, 3e-6, 1e-5], [.03, .06, .1], [.95, .9, .8], [0, .04, .1], P3, [.5, .3, .2], 1e-4)", c("ym", "P3"))
case3("ms_filter_neginf", "sl$.sl_ms_garch_filter(ym0, c(1e-6, 5e-6), c(.05, .1), c(.9, .8), c(.02, .05), P2, c(.5, .5), 1e-4)",
      "L.ms_garch_filter(ym0, [1e-6, 5e-6], [.05, .1], [.9, .8], [.02, .05], P2, [.5, .5], 1e-4)",
      "L.ms_garch_filter(ym0, [1e-6, 5e-6], [.05, .1], [.9, .8], [.02, .05], P2, [.5, .5], 1e-4)", c("ym0", "P2"))
case3("ms_nll", "c(sl$.sl_ms_garch_nll(c(-12, -3, -4, 2, -11, -2, -3, 1.5, -4, -3), ms2, 2, 'gjrGARCH'), sl$.sl_ms_garch_nll(c(-12, -3, 2, -11, -2, 1.5, -4, -3), ms2, 2, 'sGARCH', 1e-4))",
      "[L.ms_garch_nll([-12, -3, -4, 2, -11, -2, -3, 1.5, -4, -3], ms2, 2, 'gjrGARCH'), L.ms_garch_nll([-12, -3, 2, -11, -2, 1.5, -4, -3], ms2, 2, 'sGARCH', 1e-4)]",
      "[L.ms_garch_nll([-12, -3, -4, 2, -11, -2, -3, 1.5, -4, -3], ms2, 2, \"gjrGARCH\"), L.ms_garch_nll([-12, -3, 2, -11, -2, 1.5, -4, -3], ms2, 2, \"sGARCH\"; h1 = 1e-4)]", "ms2")
for (cf in list(c("ms2", 2, "sGARCH"), c("ms2", 2, "gjrGARCH"), c("ms3", 3, "sGARCH"), c("ms3", 2, "gjrGARCH"))) {
  id <- sprintf("ms_%s_K%s_%s", cf[1], cf[2], cf[3])
  case3(paste0(id, "_starts"), sprintf("list(sl$.sl_ms_garch_starts(%s, %s, '%s'), sl$.sl_ms_garch_starts(%s, %s, '%s', all = TRUE))", cf[1], cf[2], cf[3], cf[1], cf[2], cf[3]),
        sprintf("[L.ms_garch_starts(%s, %s, '%s'), L.ms_garch_starts(%s, %s, '%s', all=True)]", cf[1], cf[2], cf[3], cf[1], cf[2], cf[3]),
        sprintf("Any[L.ms_garch_starts(%s, %s, \"%s\"), L.ms_garch_starts(%s, %s, \"%s\"; all = true)]", cf[1], cf[2], cf[3], cf[1], cf[2], cf[3]), cf[1])
  case3(paste0(id, "_fit"), sprintf("sl$.sl_ms_garch_fit(%s, %s, '%s')", cf[1], cf[2], cf[3]),
        sprintf("L.ms_garch_fit(%s, %s, '%s')", cf[1], cf[2], cf[3]), sprintf("L.ms_garch_fit(%s, %s, \"%s\")", cf[1], cf[2], cf[3]), cf[1])
}
case3("ms_fitstarts", "sl$.sl_ms_garch_fitstarts(ms2, 2, 'sGARCH', cbind(c(-12, -3, 2, -11, -2, 1.5, -4, -3), c(-13, -2, 3, -10, -2, 2, -5, -4)))",
      "L.ms_garch_fitstarts(ms2, 2, 'sGARCH', np.array([[-12, -3, 2, -11, -2, 1.5, -4, -3], [-13, -2, 3, -10, -2, 2, -5, -4]], dtype=float).T)",
      "L.ms_garch_fitstarts(ms2, 2, \"sGARCH\", [-12.0 -13; -3 -2; 2 3; -11 -10; -2 -2; 1.5 2; -4 -5; -3 -4])", "ms2")
case3("ms_fit_err_K1", "sl$.sl_ms_garch_fit(ms2, 1, 'sGARCH')", "L.ms_garch_fit(ms2, 1, 'sGARCH')", "L.ms_garch_fit(ms2, 1, \"sGARCH\")", "ms2")
case3("ms_fit_err_model", "sl$.sl_ms_garch_fit(ms2, 2, 'eGARCH')", "L.ms_garch_fit(ms2, 2, 'eGARCH')", "L.ms_garch_fit(ms2, 2, \"eGARCH\")", "ms2")
case3("hmm_em", "list(sl$.sl_hmm_em_univ(ms2, 2), sl$.sl_hmm_em_univ(ms3, 3, 10L, 50L, 1e-9))",
      "[L.hmm_em_univ(ms2, 2), L.hmm_em_univ(ms3, 3, 10, 50, 1e-9)]",
      "Any[L.hmm_em_univ(ms2, 2), L.hmm_em_univ(ms3, 3; win = 10, max_iter = 50, tol = 1e-9)]", c("ms2", "ms3"))
case3("hmm_viterbi", "f <- sl$.sl_ms_garch_filter(ms2, c(1e-6, 5e-6), c(.05, .1), c(.9, .8), c(.02, .05), P2, c(2/3, 1/3), 1e-4); sl$.sl_hmm_viterbi(f$lB, log(P2), log(c(2/3, 1/3)))",
      "L.hmm_viterbi(L.ms_garch_filter(ms2, [1e-6, 5e-6], [.05, .1], [.9, .8], [.02, .05], P2, [2/3, 1/3], 1e-4)['lB'], np.log(P2), np.log([2/3, 1/3]))",
      "L.hmm_viterbi(L.ms_garch_filter(ms2, [1e-6, 5e-6], [.05, .1], [.9, .8], [.02, .05], P2, [2/3, 1/3], 1e-4)[\"lB\"], log.(P2), log.([2/3, 1/3]))", c("ms2", "P2"))

# ── N1: GJR mit gamma < 0 (alpha + gamma >= 0) und analytischer MS-GARCH-Gradient ─────────────
I$gneg <- sim_garch(1000, 3e-4, 2e-6, 0.10, -0.06, 0.88, 3)
I$msneg <- sim_ms(600, c(2e-6, 2e-5), c(0.08, 0.12), c(-0.05, -0.06), c(0.90, 0.80), matrix(c(0.99, 0.01, 0.03, 0.97), 2, byrow = TRUE), 8)
case3("n1_garch_fit_gneg_gjr", "sl$.sl_garch11_fit(gneg, TRUE)", "L.garch11_fit(gneg, True)", "L.garch11_fit(gneg; gjr = true)", "gneg")
case3("n1_fit_garch11_gneg_gjr", "sl$.sl_fit_garch11(gneg, TRUE)", "L.fit_garch11(gneg, True)", "L.fit_garch11(gneg; gjr = true)", "gneg")
case3("n1_garch_fit_gneg_s", "sl$.sl_garch11_fit(gneg, FALSE)", "L.garch11_fit(gneg, False)", "L.garch11_fit(gneg; gjr = false)", "gneg")
case3("n1_garch_nll_gneg", "c(sl$.sl_garch11_nll(gneg, c(3e-4, 2e-6, 0.1, 0.88, -0.06), TRUE), sl$.sl_garch11_nll(gneg, c(3e-4, 2e-6, 0.1, 0.88, -0.1), TRUE, 1e-4))",
      "[L.garch11_nll(gneg, [3e-4, 2e-6, 0.1, 0.88, -0.06], True), L.garch11_nll(gneg, [3e-4, 2e-6, 0.1, 0.88, -0.1], True, 1e-4)]",
      "[L.garch11_nll(gneg, [3e-4, 2e-6, 0.1, 0.88, -0.06]; gjr = true), L.garch11_nll(gneg, [3e-4, 2e-6, 0.1, 0.88, -0.1]; gjr = true, s2_init = 1e-4)]", "gneg")
case3("n1_ms_grad", "list(sl$.sl_ms_garch_grad(c(-12, -3, -4, 2, -11, -2, -3, 1.5, -4, -3), ms2, 2, 'gjrGARCH'), sl$.sl_ms_garch_grad(c(-12, -3, 2, -11, -2, 1.5, -4, -3), ms2, 2, 'sGARCH', 1e-4), sl$.sl_ms_garch_grad(c(-13, -3, 2, -12, -2, 1.5, -10, -2, 1, -5, -6, -4, -5, -3, -4), ms3, 3, 'sGARCH'))",
      "[L.ms_garch_grad([-12, -3, -4, 2, -11, -2, -3, 1.5, -4, -3], ms2, 2, 'gjrGARCH'), L.ms_garch_grad([-12, -3, 2, -11, -2, 1.5, -4, -3], ms2, 2, 'sGARCH', 1e-4), L.ms_garch_grad([-13, -3, 2, -12, -2, 1.5, -10, -2, 1, -5, -6, -4, -5, -3, -4], ms3, 3, 'sGARCH')]",
      "Any[L.ms_garch_grad([-12, -3, -4, 2, -11, -2, -3, 1.5, -4, -3], ms2, 2, \"gjrGARCH\"), L.ms_garch_grad([-12, -3, 2, -11, -2, 1.5, -4, -3], ms2, 2, \"sGARCH\"; h1 = 1e-4), L.ms_garch_grad([-13, -3, 2, -12, -2, 1.5, -10, -2, 1, -5, -6, -4, -5, -3, -4], ms3, 3, \"sGARCH\")]", c("ms2", "ms3"))
case3("n1_ms_grad_symm_P", "sl$.sl_ms_garch_grad(c(-12, -3, -4, 2, -11, -2, -3, 1.5, -4.6, -4.6), msneg, 2, 'gjrGARCH')",
      "L.ms_garch_grad([-12, -3, -4, 2, -11, -2, -3, 1.5, -4.6, -4.6], msneg, 2, 'gjrGARCH')",
      "L.ms_garch_grad([-12, -3, -4, 2, -11, -2, -3, 1.5, -4.6, -4.6], msneg, 2, \"gjrGARCH\")", "msneg")
case3("n1_ms_grad_inf", "sl$.sl_ms_garch_grad(c(-12, -3, 2, -800, -2, 1.5, -4, -3), ms2, 2, 'sGARCH', 1e-300)",
      "L.ms_garch_grad([-12, -3, 2, -800, -2, 1.5, -4, -3], ms2, 2, 'sGARCH', 1e-300)",
      "L.ms_garch_grad([-12, -3, 2, -800, -2, 1.5, -4, -3], ms2, 2, \"sGARCH\"; h1 = 1e-300)", "ms2")
case3("n1_ms_msneg_K2_gjrGARCH_starts", "sl$.sl_ms_garch_starts(msneg, 2, 'gjrGARCH', all = TRUE)", "L.ms_garch_starts(msneg, 2, 'gjrGARCH', all=True)",
      "L.ms_garch_starts(msneg, 2, \"gjrGARCH\"; all = true)", "msneg")
case3("n1_ms_msneg_K2_gjrGARCH_fit", "sl$.sl_ms_garch_fit(msneg, 2, 'gjrGARCH')", "L.ms_garch_fit(msneg, 2, 'gjrGARCH')", "L.ms_garch_fit(msneg, 2, \"gjrGARCH\")", "msneg")
case3("n1_ms_msneg_K3_gjrGARCH_fit", "sl$.sl_ms_garch_fit(msneg, 3, 'gjrGARCH')", "L.ms_garch_fit(msneg, 3, 'gjrGARCH')", "L.ms_garch_fit(msneg, 3, \"gjrGARCH\")", "msneg")
case3("n1_ms_fitstarts_gjr", "sl$.sl_ms_garch_fitstarts(msneg, 2, 'gjrGARCH', cbind(c(-12, -3, -2.5, 2, -11, -2, -1.5, 1.5, -4, -3)))",
      "L.ms_garch_fitstarts(msneg, 2, 'gjrGARCH', np.array([[-12, -3, -2.5, 2, -11, -2, -1.5, 1.5, -4, -3]], dtype=float).T)",
      "L.ms_garch_fitstarts(msneg, 2, \"gjrGARCH\", reshape([-12.0, -3, -2.5, 2, -11, -2, -1.5, 1.5, -4, -3], :, 1))", "msneg")

# ── Bootstrap-Kerne (Strom aus Seed; danach Zustand als Hex) ──────────────────
bc <- function(id, seed, r, py, jl, inp = character(0))
  cs(id, r = sprintf("s <- sl$.sl_stream(%d); list(%s, sl$.sl_state_hex(s))", seed, r),
     py = sprintf("s = L.Stream(%d)\nresult = [%s, L.state_hex(s)]", seed, py),
     jl = sprintf("s = L.Stream(%d)\nresult = Any[%s, L.state_hex(s)]", seed, jl), inputs = I[inp])
bc("boot_iid", 1, "sl$.sl_boot_idx_iid(300, 500, stream = s)", "L.boot_idx_iid(300, 500, stream=s)", "L.boot_idx_iid(300, 500; stream = s)")
bc("boot_block", 2, "sl$.sl_boot_idx_block(300, 500, 20, FALSE, stream = s), sl$.sl_boot_idx_block(300, 77, 13, TRUE, stream = s)",
   "L.boot_idx_block(300, 500, 20, False, stream=s), L.boot_idx_block(300, 77, 13, True, stream=s)",
   "L.boot_idx_block(300, 500, 20, false; stream = s), L.boot_idx_block(300, 77, 13, true; stream = s)")
bc("boot_stationary", 3, "sl$.sl_boot_idx_stationary(300, 1000, 15.5, stream = s), sl$.sl_boot_idx_stationary(50, 30, 1, stream = s)",
   "L.boot_idx_stationary(300, 1000, 15.5, stream=s), L.boot_idx_stationary(50, 30, 1, stream=s)",
   "L.boot_idx_stationary(300, 1000, 15.5; stream = s), L.boot_idx_stationary(50, 30, 1; stream = s)")
bc("boot_regime", 4, "sl$.sl_boot_idx_regime(reg, tr, 400, stream = s)", "L.boot_idx_regime(reg, tr, 400, stream=s)",
   "L.boot_idx_regime(reg, tr, 400; stream = s)", c("reg", "tr"))
bc("boot_tails", 5, "sl$.sl_boot_idx_tails(500, 0.05, 0.07, 11:280, 1:10, 281:300, stream = s)",
   "L.boot_idx_tails(500, 0.05, 0.07, np.arange(11, 281), np.arange(1, 11), np.arange(281, 301), stream=s)",
   "L.boot_idx_tails(500, 0.05, 0.07, 11:280, 1:10, 281:300; stream = s)")
bc("boot_wild", 6, "sl$.sl_boot_wild(X, 0L, stream = s), sl$.sl_boot_wild(X, 1L, stream = s), sl$.sl_boot_wild(X, 2L, stream = s)",
   "L.boot_wild(X, 0, stream=s), L.boot_wild(X, 1, stream=s), L.boot_wild(X, 2, stream=s)",
   "L.boot_wild(X, 0; stream = s), L.boot_wild(X, 1; stream = s), L.boot_wild(X, 2; stream = s)", "X")
bc("boot_reset", 7, "sl$.sl_boot_reset(X, 0.02, stream = s)", "L.boot_reset(X, 0.02, stream=s)", "L.boot_reset(X, 0.02; stream = s)", "X")
bc("boot_evt", 8, "sl$.sl_boot_evt(X, 0L, 400L, 0.05, 0.98, 0.006, 0.2, 1:15, 0.05, 1.02, 0.005, 0, 286:300, 16:285, stream = s)",
   "L.boot_evt(X, 0, 400, 0.05, 0.98, 0.006, 0.2, np.arange(1, 16), 0.05, 1.02, 0.005, 0, np.arange(286, 301), np.arange(16, 286), stream=s)",
   "L.boot_evt(X, 0, 400, 0.05, 0.98, 0.006, 0.2, 1:15, 0.05, 1.02, 0.005, 0, 286:300, 16:285; stream = s)", "X")
bc("boot_garch", 9, "sl$.sl_boot_garch(500L, 0L, 3L, 3e-4, 2e-6, 0.08, 0.9, 0.05, 1e-4, zb, 1:300, c(1L, 2L), c(1e-4, 0), c(1e-6, 3e-6), c(.05, .1), c(.9, .85), c(TRUE, FALSE), c(5e-5, 2e-4), Zc, stream = s)",
   "L.boot_garch(500, 0, 3, 3e-4, 2e-6, 0.08, 0.9, 0.05, 1e-4, zb, np.arange(1, 301), [1, 2], [1e-4, 0], [1e-6, 3e-6], [.05, .1], [.9, .85], [True, False], [5e-5, 2e-4], Zc, stream=s)",
   "L.boot_garch(500, 0, 3, 3e-4, 2e-6, 0.08, 0.9, 0.05, 1e-4, zb, 1:300, [1, 2], [1e-4, 0], [1e-6, 3e-6], [.05, .1], [.9, .85], [true, false], [5e-5, 2e-4], Zc; stream = s)", c("zb", "Zc"))
bc("boot_garch_ohne_kopplung", 19, "sl$.sl_boot_garch(100L, 0L, 1L, 3e-4, 2e-6, 0.08, 0.9, 0, 1e-4, zb, 1:300, integer(0), numeric(0), numeric(0), numeric(0), numeric(0), logical(0), numeric(0), NULL, stream = s)",
   "L.boot_garch(100, 0, 1, 3e-4, 2e-6, 0.08, 0.9, 0, 1e-4, zb, np.arange(1, 301), [], [], [], [], [], [], [], None, stream=s)",
   "L.boot_garch(100, 0, 1, 3e-4, 2e-6, 0.08, 0.9, 0, 1e-4, zb, 1:300, Int[], Float64[], Float64[], Float64[], Float64[], Bool[], Float64[], nothing; stream = s)", "zb")
bc("boot_ms_garch", 10, "sl$.sl_boot_ms_garch(400L, 0L, 3L, 2L, c(5e-4, -1e-3), c(1e-6, 5e-6), c(.05, .1), c(.9, .85), c(0, .1), c(0, .05), c(0, .1), matrix(c(.97, .05, .03, .95), 2), delta, c(1e-4, 4e-4), c(.6, .4), list(1:200, 201:300), zb, c(1L, 2L), c(1e-4, 0), c(1e-6, 3e-6), c(.05, .1), c(.9, .85), c(TRUE, FALSE), c(5e-5, 2e-4), Zc, stream = s)",
   "L.boot_ms_garch(400, 0, 3, 2, [5e-4, -1e-3], [1e-6, 5e-6], [.05, .1], [.9, .85], [0, .1], [0, .05], [0, .1], np.array([[.97, .03], [.05, .95]]), delta, [1e-4, 4e-4], [.6, .4], [np.arange(1, 201), np.arange(201, 301)], zb, [1, 2], [1e-4, 0], [1e-6, 3e-6], [.05, .1], [.9, .85], [True, False], [5e-5, 2e-4], Zc, stream=s)",
   "L.boot_ms_garch(400, 0, 3, 2, [5e-4, -1e-3], [1e-6, 5e-6], [.05, .1], [.9, .85], [0, .1], [0, .05], [0, .1], [.97 .03; .05 .95], delta, [1e-4, 4e-4], [.6, .4], [1:200, 201:300], zb, [1, 2], [1e-4, 0], [1e-6, 3e-6], [.05, .1], [.9, .85], [true, false], [5e-5, 2e-4], Zc; stream = s)",
   c("delta", "zb", "Zc"))
cs("boot_global", r = "simlev_seed(11); list(sl$.sl_boot_idx_iid(50, 20), sl$.sl_boot_wild(X[1:10, ], 2L), sl$.sl_state_hex())",
   py = "simlev.simlev_seed(11)\nresult = [L.boot_idx_iid(50, 20), L.boot_wild(X[:10, :], 2), L.state_hex()]",
   jl = "simlev_seed(11)\nresult = Any[L.boot_idx_iid(50, 20), L.boot_wild(X[1:10, :], 2), L.state_hex()]", inputs = I["X"])
cs("boot_stroeme", r = "u <- sl$.sl_streams(sl$.sl_stream(12), 3); lapply(u, function(s) sl$.sl_boot_idx_stationary(100, 30, 5, stream = s))",
   py = "u = L.streams(L.Stream(12), 3)\nresult = [L.boot_idx_stationary(100, 30, 5, stream=s) for s in u]",
   jl = "u = L.streams(L.Stream(12), 3)\nresult = Any[L.boot_idx_stationary(100, 30, 5; stream = s) for s in u]")
bc("boot_err_block", 13, "sl$.sl_boot_idx_block(10, 5, 20, FALSE, stream = s)", "L.boot_idx_block(10, 5, 20, False, stream=s)",
   "L.boot_idx_block(10, 5, 20, false; stream = s)")
bc("boot_err_wild", 14, "sl$.sl_boot_wild(X, 3L, stream = s)", "L.boot_wild(X, 3, stream=s)", "L.boot_wild(X, 3; stream = s)", "X")
bc("boot_err_index", 15, "sl$.sl_boot_garch(10L, 0L, 1L, 0, 1e-6, 0.1, 0.8, 0, 1e-4, zb, c(1L, 400L), integer(0), numeric(0), numeric(0), numeric(0), numeric(0), logical(0), numeric(0), NULL, stream = s)",
   "L.boot_garch(10, 0, 1, 0, 1e-6, 0.1, 0.8, 0, 1e-4, zb, [1, 400], [], [], [], [], [], [], [], None, stream=s)",
   "L.boot_garch(10, 0, 1, 0, 1e-6, 0.1, 0.8, 0, 1e-4, zb, [1, 400], Int[], Float64[], Float64[], Float64[], Float64[], Bool[], Float64[], nothing; stream = s)", "zb")
case3("boot_helfer", "v <- sl$.sl_rolling_vol(X[, 1], 21L); list(v, sl$.sl_rolling_vol(X[1:5, 2], 10L), sl$.sl_assign_regimes(v, c(0, 0.009, 0.0115, Inf)), sl$.sl_estimate_trans_mat(reg, 3L, 0.1))",
      "[L.rolling_vol(X[:, 0], 21), L.rolling_vol(X[:5, 1], 10), L.assign_regimes(L.rolling_vol(X[:, 0], 21), [0.0, 0.009, 0.0115, math.inf]), L.estimate_trans_mat(reg, 3, 0.1)]",
      "Any[L.rolling_vol(X[:, 1], 21), L.rolling_vol(X[1:5, 2], 10), L.assign_regimes(L.rolling_vol(X[:, 1], 21), [0.0, 0.009, 0.0115, Inf]), L.estimate_trans_mat(reg, 3, 0.1)]",
      c("X", "reg"))

ref_done()
