# tests/werkzeuge/gleichlauf/goal_fuzz.R – Fuzz von planning_goal (seit 1.5.0: Rückwärtsrekursion im Kern goal_dp,
# core/research_core_impl.h)
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/goal_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul goal_fuzz:
# planning_goal() mit 1 bis 300 Szenarien, 1 bis 5 Kandidaten (mit und ohne Namen, auch Tabelle), Totalverlust,
# gleicher Streuung (Rang bei Gleichstand), Ziel 0, unter, nahe und weit über dem Startwert, Beiträgen (Zahl,
# Vektor, negativ bis zum Ruin), Horizont 1 bis 12, n_grid 2 bis 121 (auch nicht ganzzahlig), n_sim 1 bis 2000,
# Ziel 1 ulp neben einem Rasterpunkt (gleiche log(grid)-Werte: approx fasst zusammen, Warnung je Aufruf), Warnung
# DP gegen Simulation, Eingabefehler. Warnungen und Fehler mit ihren Aufrufen (r_calls) wie sim_fuzz.R.
#
# Prüfung (tests/werkzeuge/gleichlauf/run.sh, Schritt 5): Referenz aus R 1.4.2 (R_LIBS=/home/claude/rlib142), R neu mit
# tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261107)
ref_bereich("goal_fuzz", alle = TRUE); ref_init("goal_fuzz")
pick <- function(x) x[[sample.int(length(x), 1L)]]
coin <- function(p) runif(1) < p

fuzz_case <- function(id, r, py, jl, inputs) {
  ref_case(id, r = r, py = py, jl = jl, inputs = inputs)
  if (!.ref_in_subset(id)) return(invisible(NULL))
  env <- new.env(parent = globalenv())
  for (k in names(inputs)) assign(k, inputs[[k]], envir = env)
  dp <- function(x) if (is.null(x)) "NULL" else paste(deparse(x), collapse = " ")
  wc <- character(0); ec <- NULL
  invisible(capture.output(tryCatch(withCallingHandlers(eval(parse(text = r), envir = env),
    warning = function(w) { wc <<- c(wc, dp(conditionCall(w))); invokeRestart("muffleWarning") },
    message = function(m) invokeRestart("muffleMessage")),
    error = function(e) ec <<- dp(conditionCall(e)))))
  ref_case_extra(list(r_calls = list(warnings = as.list(wc), error = ec)))
}
num <- function(v) sprintf("%.17g", v)
vr <- function(v) if (length(v) == 1) num(v) else sprintf("c(%s)", paste(num(v), collapse = ", "))
vp <- function(v) sprintf("[%s]", paste(num(v), collapse = ", "))

for (kk in seq_len(N)) {
  set.seed(seed0 + kk)
  S <- pick(c(1, 3, 10, 40, 120, 300)); K <- pick(c(1, 2, 3, 3, 4, 5))
  R <- matrix(NA_real_, S, K)
  for (j in seq_len(K)) R[, j] <- exp(rnorm(S, pick(c(0, 0.01, 0.04, 0.08)), pick(c(0, 0.02, 0.1, 0.25, 0.5))))
  if (K > 1 && coin(0.15)) R[, 2] <- R[, 1] * pick(c(1, 1.01))                    # gleiche Streuung
  if (coin(0.1)) R[sample.int(S * K, max(1, S * K %/% 20))] <- 0                    # Totalverlust
  if (coin(0.3)) R <- round(R, 3)
  df <- coin(0.1)
  if (df || coin(0.4)) colnames(R) <- c("a", "b", "c", "d", "e")[seq_len(K)]   # Tabelle immer mit Namen
  if (coin(0.02)) R[1] <- pick(c(NA, -0.5, Inf))
  sv <- pick(c(1e5, 1e5, 1, 5e4, 1e6, 2.5e3))
  goal <- sv * pick(c(0, 0.3, 1, 1.0000001, 1.2, 1.5, 2, 5, 40))
  h <- pick(c(1, 2, 3, 5, 8, 12)); ng <- pick(c(2, 3, 5, 11, 21, 41, 81, 121, 10.5)); ns <- pick(c(1, 20, 300, 2000))
  cf <- pick(list(0, 0, 1000, -2000, sv * pick(c(-0.6, 0.1)), round(runif(pick(c(2, 3)), -3000, 3000))))
  if (coin(0.05)) {                                       # Ziel 1 ulp neben einem Rasterpunkt unter 1e-3 (wmin = 1e-6)
    ngi <- max(3, ceiling(ng)); g <- exp(seq(log(1e-6), log(20 * sv), length.out = ngi))
    goal <- g[2] * (1 + 2^-52); if (goal >= 1e-3) goal <- 0
  }
  if (coin(0.04)) { h <- pick(c(0, 2.5, NA)) }
  if (coin(0.02)) ng <- 1
  if (coin(0.02)) cf <- pick(list(NA, numeric(0)))
  hs <- if (is.na(h)) "NA" else num(h)
  cfr <- if (!length(cf)) "numeric(0)" else if (anyNA(cf)) "NA" else vr(cf)
  cfp <- if (!length(cf)) "[]" else if (anyNA(cf)) "simlev._r.fmt.NA_REAL" else vp(cf)
  cfj <- if (!length(cf)) "Float64[]" else if (anyNA(cf)) "SL.NA" else vp(cf)
  xr <- xp <- xj <- "R"
  fuzz_case(sprintf("g%05d", kk),
    r = sprintf("planning_goal(%s, start_value = %s, goal = %s, horizon = %s, contributions = %s, n_grid = %s, n_sim = %s, seed = %d)",
                xr, num(sv), num(goal), hs, cfr, num(ng), num(ns), kk),
    py = sprintf("import simlev, simlev._r.fmt\nimport numpy as np, pandas as pd\nfrom simlev import planning as PL\nresult = PL.planning_goal(%s, start_value=%s, goal=%s, horizon=%s, contributions=%s, n_grid=%s, n_sim=%s, seed=%d)",
                 xp, num(sv), num(goal), if (is.na(h)) "simlev._r.fmt.NA_REAL" else num(h), cfp, num(ng), num(ns), kk),
    jl = sprintf("PL = SL.Planning\nresult = PL.planning_goal(%s, %s, %s, %s; contributions = %s, n_grid = %s, n_sim = %s, seed = %d)",
                 xj, num(sv), num(goal), if (is.na(h)) "SL.NA" else num(h), cfj, num(ng), num(ns), kk),
    inputs = list(R = if (df) as.data.frame(R) else R))
}
ref_done(); ref_schreiben()
