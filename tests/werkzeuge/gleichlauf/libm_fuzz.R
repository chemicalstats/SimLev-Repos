# tests/werkzeuge/gleichlauf/libm_fuzz.R – Fuzz der Teile, die 1.5.2 in Python schneller rechnet (seit 1.5.2):
# libm elementweise (exp, log, log1p, expm1, log2, log10, ^ mit Recycling; Python seit 1.5.2 in einer C-Schleife,
# core/slc_rbase.cpp sl_r_math1/sl_r_pow_rec), Ränge (Pseudo-Beobachtungen der Copula, Kern sl_r_rank),
# rebalance_trigger (Python ohne float()/np.isnan je Tag), doppelte Tage in series_align und simulation() (Python
# ohne Schleife) und scenario_entropy_pooling (Python: min/max ohne Schleife, eine Auswertung je Punkt).
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/libm_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul libm_fuzz. Werte mit
# NA, NaN, ±Inf, ±0, subnormalen Zahlen, Werten um -1 und an den Grenzen von exp(). Warnungen und Fehler mit ihren
# Aufrufen (r_calls) wie sim_fuzz.R; seit 1.6.4 ohne suppressWarnings() (die libm-Hüllen der Ports warnen wie R:
# "NaNs produced" nach Entscheidung 80, "probable complete loss of accuracy in modulus" bei (-Inf)^y mit y > 2^64, T4-R2).
#
# Prüfung (tests/werkzeuge/gleichlauf/run.py, Schritt 5): abgelegte Referenz (seit 1.6.2 aus R 1.6.2, run.py --ref-erzeugen 162), R neu mit
# tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261112)
ref_bereich("libm_fuzz", alle = TRUE); ref_init("libm_fuzz")

SPEZ <- c(0, -0, Inf, -Inf, NaN, NA, -1, -1 - 2^-52, -1 + 2^-53, 1, 5e-324, -5e-324, 1e-310, 709.78, 709.79,
          -745.2, -746, 1e308, -1e308, 2, 0.5, -0.5, 1e-300, 2^-1074 * 3)
werte <- function(n) {
  x <- switch(pick(1:6),
              rnorm(n), rnorm(n, 0, 30), exp(runif(n, -700, 700)), -exp(runif(n, -50, 50)), runif(n, -1.2, 1),
              rnorm(n, 0, 1e-8))
  k <- sample.int(n, max(1L, n %/% 6L)); x[k] <- sample(SPEZ, length(k), TRUE)
  x
}

for (kk in seq_len(N)) {
  set.seed(seed0 + kk)
  art <- if (kk %% 10 < 6) "libm" else c("rang", "trigger", "dubletten", "sim_dup", "ep")[kk %% 10 - 5]
  if (art == "libm") {
    n <- pick(c(1, 2, 3, 17, 200, 1000))
    x <- werte(n); y <- if (coin(0.5)) werte(pick(c(1, n))) else round(werte(pick(c(1, n))))
    b <- pick(c(3, 10, 2, 0.5, exp(1)))
    fuzz_case(sprintf("l%05d", kk),
      r = sprintf("list(exp(x), log(x), log1p(x), expm1(x), log2(x), log10(x), x^y, abs(x)^y, log(x, %.17g))", b),
      py = sprintf("L = simlev._r.libm\nresult = [L.exp(x), L.log(x), L.log1p(x), L.expm1(x), L.log2(x), L.log10(x), L.pow(x, y), L.pow(np.abs(x), y), L.log(x, %.17g)]", b),
      jl = sprintf("L = SL.RLibm\nresult = [L.exp(x), L.log(x), L.log1p(x), L.expm1(x), L.log2(x), L.log10(x), L.pow(x, y), L.pow(abs.(x), y), L.log(x, %.17g)]", b),
      inputs = list(x = x, y = y))
  } else if (art == "rang") {
    n <- pick(c(12, 40, 250)); x <- round(rnorm(n), pick(0:2)); y <- round(rnorm(n) + 0.5 * x, pick(0:2))
    fuzz_case(sprintf("r%05d", kk), r = "list(SimLev:::.pobs(x), SimLev:::.pobs(y))",
              py = "D = simlev.dependence\nresult = [D._pobs(x), D._pobs(y)]",
              jl = "D = SL.Dependence\nresult = [D._pobs(x), D._pobs(y)]", inputs = list(x = x, y = y))
  } else if (art == "trigger") {
    n <- pick(c(1, 5, 60, 400)); d <- data.frame(date = as.Date("2001-01-01") + seq_len(n) - 1)
    d$lev <- 2 + cumsum(rnorm(n, 0, 0.05)); d$vol <- abs(0.01 + cumsum(rnorm(n, 0, 0.001)))
    if (coin(0.4)) d$lev[sample.int(n, max(1, n %/% 5))] <- NA
    if (coin(0.3)) d$vol[sample.int(n, max(1, n %/% 5))] <- pick(list(NA, 0, NaN))
    if (coin(0.1)) d$lev[1:max(1, n %/% 2)] <- NA
    ty <- pick(c("abs_leverage", "rel_leverage", "vol_band")); th <- pick(c(0, 1, 5, 10, 25))
    fuzz_case(sprintf("t%05d", kk),
      r = sprintf("rebalance_trigger(d, '%s', threshold = %g, lev_col = 'lev', vol_col = 'vol')", ty, th),
      py = sprintf("result = simlev.rebalance_trigger(d, '%s', threshold=%g, lev_col='lev', vol_col='vol')", ty, th),
      jl = sprintf("result = SL.rebalance_trigger(d, \"%s\"; threshold = %g, lev_col = \"lev\", vol_col = \"vol\")", ty, th),
      inputs = list(d = d))
  } else if (art == "dubletten") {
    n <- pick(c(3, 20, 200)); dd <- as.Date("2010-01-01") + sort(sample.int(n + 5, n, TRUE))
    a <- data.frame(date = dd, A = round(100 * cumprod(1 + rnorm(n, 0, 0.01)), 3))
    if (coin(0.3)) a$A[sample.int(n, 1)] <- NA
    b <- data.frame(date = as.Date("2010-01-01") + seq_len(n + 5) - 1, B = round(50 + cumsum(rnorm(n + 5)), 3))
    if (coin(0.5)) b <- b[sample.int(nrow(b)), , drop = FALSE]
    rownames(b) <- NULL
    fuzz_case(sprintf("d%05d", kk), r = "series_align(list(a = a, b = b))",
              py = "result = simlev.series_align({'a': a, 'b': b})",
              jl = "result = SL.series_align(SL.RList(\"a\" => a, \"b\" => b))", inputs = list(a = a, b = b))
  } else if (art == "sim_dup") {
    n <- pick(c(5, 40, 300)); d <- data.frame(date = as.Date("2015-03-01") + seq_len(n) - 1)
    d$A <- round(100 * cumprod(1 + rnorm(n, 0, 0.01)), 4)
    k <- if (coin(0.8)) sample.int(n, pick(c(1, 2, 5)), TRUE) else integer(0)
    if (length(k)) d <- d[sort(c(seq_len(n), k)), , drop = FALSE]
    if (coin(0.3)) d <- d[sample.int(nrow(d)), , drop = FALSE]
    rownames(d) <- NULL
    fuzz_case(sprintf("s%05d", kk),
      r = "simulation(d, create_strategy(A = asset_config('etf', 'bnh', 1)), start_value = 1000)",
      py = "result = simlev.simulation(d, simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=1)), start_value=1000)",
      jl = "result = SL.simulation(d, SL.create_strategy(\"A\" => SL.asset_config(\"etf\", \"bnh\", 1)); start_value = 1000)",
      inputs = list(d = d))
  } else {
    n <- pick(c(30, 120)); X <- data.frame(a = round(rnorm(n, 0.01, 0.05), 4), b = round(rnorm(n, 0, 0.02), 4))
    v <- pick(c("a > 0.02", "a < 0", "b > a", "a > 0.5"))
    p <- pick(c(0.1, 0.3, 0.5, 0.9))
    fuzz_case(sprintf("e%05d", kk),
      r = sprintf("scenario_entropy_pooling(X, c('a', 'b'), list(view_prob('%s', %g), view_mean('b', 0.001)))", v, p),
      py = sprintf("from simlev import scenarios as SC\nresult = SC.scenario_entropy_pooling(X, ['a', 'b'], [SC.view_prob('%s', %g), SC.view_mean('b', 0.001)])", v, p),
      jl = sprintf("result = SL.scenario_entropy_pooling(X, [\"a\", \"b\"], [SL.view_prob(\"%s\", %g), SL.view_mean(\"b\", 0.001)])", v, p),
      inputs = list(X = X))
  }
}
ref_done(); ref_schreiben()
