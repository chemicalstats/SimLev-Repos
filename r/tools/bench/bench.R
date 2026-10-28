# Messbasis SimLev, R (Etappe 3, tools/bench). Aufgaben siehe README.md.
#
# Aufruf aus der Repo-Wurzel (SimLev installiert, z. B. R CMD INSTALL -l <lib> r):
#   LC_ALL=C.UTF-8 R_LIBS=<lib> Rscript tools/bench/bench.R [ausgabe.csv] [aufgaben]
# aufgaben: kommagetrennt (z. B. T1,T8), Voreinstellung alle außer P1. P1 (= P1c1, P1c2) misst
# bootstrap mit cores = 1 und 2 (Fork) und wird nur auf Anforderung gemessen (run.sh P1).
# Je Aufgabe 1 Aufwärmlauf (erster_lauf_s), dann 3 gemessene Läufe (Median, Min, Max).
# Ein Kern: cores = 1, wo die Funktion es kennt; BLAS-Threads setzt run.sh.

args <- commandArgs(trailingOnly = TRUE)
out <- if (length(args) >= 1) args[[1]] else "tools/bench/out/r.csv"
only <- if (length(args) >= 2) strsplit(args[[2]], ",")[[1]] else NULL
dir.create(dirname(out), showWarnings = FALSE, recursive = TRUE)
RUNS <- 3L

t_load <- system.time(suppressMessages(library(SimLev)))[["elapsed"]]

# ── Daten (fester Seed; Python und Julia erzeugen dieselben Zahlen mit dem R-RNG der Ports) ──
# S30: zwei Kursreihen, 30 Jahre täglich (wie scratchpad bench.R vom 20.10.2026)
set.seed(1); n <- 10958
d30 <- data.frame(date = seq(as.Date("1995-01-01"), by = "day", length.out = n),
                  A = 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)), B = 50 * cumprod(1 + rnorm(n, 1e-4, 0.003)))
# T1–T7: vier Kursreihen, 20 Jahre täglich, und 2.000 Pfade x 30 Jahre Wachstumsfaktoren (wie bench/gen.R)
set.seed(7); n <- 7305
d <- data.frame(date = seq(as.Date("2000-01-01"), by = "day", length.out = n),
                aktien = 100 * cumprod(1 + rnorm(n, 3e-4, 0.011)), bonds = 100 * cumprod(1 + rnorm(n, 1e-4, 0.003)),
                gold = 100 * cumprod(1 + rnorm(n, 2e-4, 0.009)), em = 100 * cumprod(1 + rnorm(n, 3e-4, 0.014)))
W <- matrix(1 + rnorm(30 * 2000, 0.05, 0.15), 30, 2000)
# T8: MS-GJR-GARCH(1,1), 2 Regime, n = 2.000 (Simulation wie golden/modules/gen_ms_garch.R, Datensatz gjr2)
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
y8 <- sim_msgjr(2000, c(2e-6, 2e-5), c(0.02, 0.05), c(0.04, 0.10), c(0.92, 0.85),
                matrix(c(0.99, 0.01, 0.03, 0.97), 2, byrow = TRUE), 7)
fp <- function(x) sprintf("%.17g", sum(x))
cat(sprintf("Daten: S30 %s, T %s, W %s, T8 %s\n", fp(d30$A), fp(d$em), fp(W), fp(y8)))

st30 <- create_strategy(A = asset_config("etf", "bnh", asset_share = 0.7), B = asset_config("etf", "bnh", asset_share = 0.3))
cfg <- bootstrap_config(c(akt = "aktien"), input = "prices")
st <- create_strategy(akt = asset_config("etf", "bnh"))
A4 <- c("aktien", "bonds", "gold", "em")

tasks <- list(
  S30 = function() simulation(d30, st30, start_value = 1e4, tax_mode = "person", dca_mode = TRUE, dca_value = 200,
                              dca_span = 1, balance_mode = TRUE, balance_unit = "quarter", base_rate = 2),
  T1 = function() bootstrap(d, cfg, "stationary", n = 200, seed = 1, progress = FALSE, path_length = 2520, cores = 1),
  T2 = function() bootstrap(d, cfg, "garch", n = 50, seed = 1, progress = FALSE, path_length = 2520, cores = 1),
  T3 = function() bootstrap_study(d, cfg, "stationary", n = 50, path_length = 2520, seed = 1, progress = FALSE,
                                  strategies = list(a = st), cores = 1),
  T4 = function() withdrawal_simulation(W, withdrawal_rule("constant", rate = 4), start_value = 1e6),
  T5 = function() dependence_analysis(d, A4, copulas = FALSE),
  T6 = function() portfolio_optimize(d, A4, method = "min_cvar"),
  T7 = function() portfolio_optimize(d, A4, method = "hrp"),
  T8 = function() SimLev:::.ms_garch_fit(y8, 2, "gjrGARCH"),
  P1c1 = function() bootstrap(d, cfg, "stationary", n = 400, seed = 1, progress = FALSE, path_length = 2520, cores = 1),
  P1c2 = function() bootstrap(d, cfg, "stationary", n = 400, seed = 1, progress = FALSE, path_length = 2520, cores = 2)
)
if (!is.null(only)) only <- unlist(lapply(only, function(a) if (a == "P1") c("P1c1", "P1c2") else a))
tasks <- if (is.null(only)) tasks[!startsWith(names(tasks), "P")] else tasks[intersect(names(tasks), only)]

el <- function(f) {
  t0 <- proc.time()[["elapsed"]]
  invisible(suppressWarnings(suppressMessages(f())))
  proc.time()[["elapsed"]] - t0
}
rows <- data.frame(aufgabe = "Laden", sprache = "R", median_s = t_load, min_s = t_load, max_s = t_load,
                   erster_lauf_s = t_load)
for (k in names(tasks)) {
  first <- el(tasks[[k]])
  ts <- vapply(seq_len(RUNS), function(i) el(tasks[[k]]), 0)
  rows <- rbind(rows, data.frame(aufgabe = k, sprache = "R", median_s = stats::median(ts), min_s = min(ts),
                                 max_s = max(ts), erster_lauf_s = first))
  cat(sprintf("%-4s median %.3f s (min %.3f, max %.3f; erster Lauf %.3f)\n", k, stats::median(ts), min(ts), max(ts), first))
}
rows$median_s <- sprintf("%.4f", rows$median_s); rows$min_s <- sprintf("%.4f", rows$min_s)
rows$max_s <- sprintf("%.4f", rows$max_s); rows$erster_lauf_s <- sprintf("%.4f", rows$erster_lauf_s)
utils::write.csv(rows, out, row.names = FALSE, quote = FALSE)
cat("->", out, "\n")
