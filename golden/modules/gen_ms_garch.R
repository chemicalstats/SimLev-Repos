# Referenzfälle für die eigene MS-GARCH-Schätzung r/R/ms_garch.R (.ms_garch_fit;
# Python: simlev/ms_garch.py, Julia: src/ms_garch.jl). Den C-Kern .ms_garch_filter
# prüft gen_bootstrap_core.R, die Verfahren "ms_garch", "ms_ar_garch_m" und
# "tvtp_ms_garch" von bootstrap() prüft gen_bootstrap.R.
# Aufruf aus der Repo-Wurzel:
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript golden/modules/gen_ms_garch.R
source("golden/modules/ref_tools.R"); ref_init("ms_garch")

P <- "from simlev import ms_garch as M\n"
J <- function(code) paste0("const M = SimLev.MsGarch\n", code)

# ── Daten (je n = 500 Tagesrenditen, Mittelwert ungefähr 0) ─────────────────
# Simulation eines MS-GJR-GARCH(1,1) mit parallelen Varianzpfaden je Regime
sim_msgjr <- function(n, om, al, ga, be, P, seed) {
  set.seed(seed); K <- length(om)
  hk <- om / (1 - al - ga / 2 - be); s <- 1L; y <- numeric(n)
  for (t in seq_len(n)) {
    if (t > 1) { s <- sample.int(K, 1, prob = P[s, ]); e <- y[t - 1]
      hk <- om + (al + ga * (e < 0)) * e^2 + be * hk }
    y[t] <- sqrt(hk[s]) * rnorm(1)
  }
  y
}
n <- 500
# garch1: ein Regime sGARCH(1,1) (wie die Testdaten in test-bootstrap.R)
set.seed(3); om <- 2e-6; al <- 0.08; be <- 0.9; s2 <- om / (1 - al - be); e <- numeric(n)
for (t in 1:n) { e[t] <- sqrt(s2) * rnorm(1); s2 <- om + al * e[t]^2 + be * s2 }
# sg3: drei Regime sGARCH; gjr2: zwei Regime GJR-GARCH
Y <- list(
  garch1 = 3e-4 + e,
  sg3 = sim_msgjr(n, c(1e-6, 4e-6, 2e-5), c(0.03, 0.05, 0.08), c(0, 0, 0), c(0.94, 0.90, 0.85),
                  matrix(c(0.99, 0.007, 0.003, 0.01, 0.98, 0.01, 0.005, 0.025, 0.97), 3, byrow = TRUE), 1),
  gjr2 = sim_msgjr(n, c(2e-6, 2e-5), c(0.02, 0.05), c(0.04, 0.10), c(0.92, 0.85),
                   matrix(c(0.99, 0.01, 0.03, 0.97), 2, byrow = TRUE), 7))

# ── .ms_garch_fit: K = 2/3 × sGARCH/gjrGARCH × 3 Datensätze ─────────────────
for (nm in names(Y)) for (K in 2:3) for (model in c("sGARCH", "gjrGARCH")) {
  ref_case(sprintf("fit_%s_K%d_%s", nm, K, model),
           sprintf("SimLev:::.ms_garch_fit(y, %d, '%s')", K, model),
           paste0(P, sprintf("result = M._ms_garch_fit(y, %d, '%s')", K, model)), inputs = list(y = Y[[nm]]),
           jl = J(sprintf('result = M._ms_garch_fit(y, %d, "%s")', K, model)))
}

# ── Fehlerwege der Prüfung (.ms_garch_check) ────────────────────────────────
I <- list(y = Y$gjr2[1:100])
errs <- list(
  err_egarch = c("2, 'eGARCH'", "2, 'eGARCH'", '2, "eGARCH"'),
  err_K1 = c("1, 'sGARCH'", "1, 'sGARCH'", '1, "sGARCH"'),
  err_K25 = c("2.5, 'sGARCH'", "2.5, 'sGARCH'", '2.5, "sGARCH"'),
  err_Kvec = c("c(2, 10), 'sGARCH'", "[2, 10], 'sGARCH'", '[2, 10], "sGARCH"'),
  err_modelNA = c("2, NA_character_", "2, None", "2, missing"))
for (k in names(errs)) {
  a <- errs[[k]]
  ref_case(paste0("fit_", k), sprintf("SimLev:::.ms_garch_fit(y, %s)", a[1]),
           paste0(P, sprintf("result = M._ms_garch_fit(y, %s)", a[2])), inputs = I,
           jl = J(sprintf("result = M._ms_garch_fit(y, %s)", a[3])))
}
ref_done()
