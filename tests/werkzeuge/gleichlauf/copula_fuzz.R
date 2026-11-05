# tests/werkzeuge/gleichlauf/copula_fuzz.R – Fuzz der t-Copula und von optimize (seit 1.6.0 im Kern: Profil-Likelihood
# core/slc_tcop.cpp, Brent fmin core/slc_opt_fmin.cpp, qt/pt auf mehreren Threads core/slc_special.cpp).
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/copula_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul copula_fuzz:
#   35 % copula_fit (n 20 bis 800, positive und negative Abhängigkeit, schwere Ränder, Bindungen),
#   15 % scenario_copula (2 bis 5 Anlagen, t und gaussian, Tages- und Wochendaten),
#   10 % dependence_analysis mit Copulas (2 bis 3 Anlagen),
#   25 % optimize (stats::optimize in R; Python/Julia: Brent im Kern) mit Polynomen, Beträgen, NaN- und Inf-Bereichen,
#        verschiedenen tol,
#   15 % qt/pt der C-Bibliothek (bis 5.000 Werte, damit mehrere Threads rechnen; NA, NaN, Ränder).
# Warnungen und Fehler mit ihren Aufrufen (r_calls) wie sim_fuzz.R.
#
# Prüfung (tests/werkzeuge/gleichlauf/run.py, Schritt 5): abgelegte Referenz (seit 1.6.2 aus R 1.6.2, run.py --ref-erzeugen 162), R neu mit
# tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261115)
ref_bereich("copula_fuzz", alle = TRUE); ref_init("copula_fuzz")
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
pyn <- function(v) if (is.infinite(v)) (if (v > 0) "float('inf')" else "float('-inf')") else num(v)
qr <- function(x) sprintf("c(%s)", paste0("'", x, "'", collapse = ", "))
qp <- function(x) sprintf("[%s]", paste0("'", x, "'", collapse = ", "))
qj <- function(x) sprintf("[%s]", paste0("\"", x, "\"", collapse = ", "))
prices <- function(nm, n, start, week) {
  d <- data.frame(date = seq.Date(start, by = "day", length.out = n))
  if (week) d <- d[as.POSIXlt(d$date)$wday %in% 1:5, , drop = FALSE]
  f <- rnorm(nrow(d)); df <- pick(c(3, 5, 100))
  for (j in seq_along(nm)) {
    rho <- runif(1, -0.6, 0.9)
    e <- rho * f + sqrt(1 - rho^2) * rt(nrow(d), df) / sqrt(df / (df - 2))
    d[[nm[j]]] <- round(100 * cumprod(1 + 0.01 * e), 4)
  }
  rownames(d) <- NULL
  d
}

for (kk in seq_len(N)) {
  set.seed(seed0 + kk)
  art <- c("fit", "fit", "fit", "fit", "fit", "fit", "fit", "scen", "scen", "scen", "dep", "dep",
           "opt", "opt", "opt", "opt", "opt", "qt", "qt", "qt")[kk %% 20 + 1]
  if (art == "fit") {
    n <- pick(c(20, 60, 250, 800)); rho <- runif(1, -0.9, 0.95); df <- pick(c(2.5, 4, 10, Inf))
    a <- rnorm(n); b <- rho * a + sqrt(1 - rho^2) * rnorm(n)
    if (is.finite(df)) { w <- sqrt(df / rchisq(n, df)); a <- a * w; b <- b * w }
    if (coin(0.2)) { a <- round(a, 1); b <- round(b, 1) }
    fuzz_case(sprintf("f%05d", kk), r = "copula_fit(x, y)", py = "result = simlev.copula_fit(x, y)",
              jl = "result = SL.copula_fit(x, y)", inputs = list(x = a, y = b))
  } else if (art == "scen") {
    nm <- c("a", "b", "c", "d", "e")[seq_len(pick(c(2, 3, 5)))]
    d <- prices(nm, pick(c(500, 1200)), as.Date("2001-01-01") + sample(0:5000, 1), coin(0.5))
    fam <- pick(c("t", "t", "gaussian")); fr <- pick(c("week", "day")); sd0 <- sample.int(1e5, 1)
    fuzz_case(sprintf("s%05d", kk),
      r = sprintf("scenario_copula(d, %s, n = 300, family = '%s', frequency = '%s', seed = %d)", qr(nm), fam, fr, sd0),
      py = sprintf("result = simlev.scenario_copula(d, %s, n=300, family='%s', frequency='%s', seed=%d)", qp(nm), fam, fr, sd0),
      jl = sprintf("result = SL.scenario_copula(d, %s; n = 300, family = \"%s\", frequency = \"%s\", seed = %d)", qj(nm), fam, fr, sd0),
      inputs = list(d = d))
  } else if (art == "dep") {
    nm <- c("a", "b", "c")[seq_len(pick(c(2, 3)))]
    d <- prices(nm, pick(c(600, 1500)), as.Date("2003-01-01") + sample(0:4000, 1), TRUE); sd0 <- sample.int(1e5, 1)
    fuzz_case(sprintf("d%05d", kk),
      r = sprintf("dependence_analysis(d, %s, copulas = TRUE, dcc = FALSE, B = 19, seed = %d)", qr(nm), sd0),
      py = sprintf("result = simlev.dependence_analysis(d, %s, copulas=True, dcc=False, B=19, seed=%d)", qp(nm), sd0),
      jl = sprintf("result = SL.dependence_analysis(d, %s; copulas = true, dcc = false, B = 19, seed = %d)", qj(nm), sd0),
      inputs = list(d = d))
  } else if (art == "opt") {
    a <- round(runif(1, -5, 5), 3); b <- round(runif(1, -2, 2), 3); c0 <- round(runif(1, 0, 3), 3); e <- round(runif(1, -6, 6), 3)
    lo <- round(runif(1, -10, 0), 2); hi <- lo + pick(c(1e-3, 0.5, 4, 20, 1e3)); tol <- pick(c(1e-10, 1e-6, 1e-4, 0.1, NA))
    form <- pick(1:4)
    f <- switch(form,
      list(r = sprintf("(x - %s) * (x - %s) * (x + %s) + %s * abs(x - %s)", a, a, b, c0, e),
           py = sprintf("(x - %s) * (x - %s) * (x + %s) + %s * abs(x - %s)", a, a, b, c0, e),
           jl = sprintf("(x - %s) * (x - %s) * (x + %s) + %s * abs(x - %s)", a, a, b, c0, e)),
      list(r = sprintf("abs(x - %s) + %s * x", a, b / 10), py = sprintf("abs(x - %s) + %s * x", a, b / 10),
           jl = sprintf("abs(x - %s) + %s * x", a, b / 10)),
      list(r = sprintf("if (x < %s) NaN else (x - %s) * (x - %s)", e, a, a),
           py = sprintf("float('nan') if x < %s else (x - %s) * (x - %s)", e, a, a),
           jl = sprintf("x < %s ? NaN : (x - %s) * (x - %s)", e, a, a)),
      list(r = sprintf("if (x > %s) Inf else 1 / (1 + (x - %s) * (x - %s))", e, a, a),
           py = sprintf("math.inf if x > %s else 1 / (1 + (x - %s) * (x - %s))", e, a, a),
           jl = sprintf("x > %s ? Inf : 1 / (1 + (x - %s) * (x - %s))", e, a, a)))
    tr <- if (is.na(tol)) "" else sprintf(", tol = %s", num(tol)); tp <- if (is.na(tol)) "" else sprintf(", tol=%s", num(tol))
    fuzz_case(sprintf("o%05d", kk),
      r = sprintf("stats::optimize(function(x) %s, c(%s, %s)%s)", f$r, num(lo), num(hi), tr),
      py = sprintf("import math\nfrom simlev._r.stats import optimize as O\nresult = O(lambda x: %s, (%s, %s)%s)", f$py, num(lo), num(hi), tp),
      jl = sprintf("result = SL.RStats.optimize(x -> %s, [%s, %s]%s)", f$jl, num(lo), num(hi), if (is.na(tol)) "" else sprintf("; tol = %s", num(tol))),
      inputs = list())
  } else {
    n <- pick(c(10, 700, 1500, 5000)); df <- pick(c(0.7, 1, 2, 2.5, 7, 40, 1e6, Inf, -1))
    p <- runif(n); p[sample.int(n, max(1, n %/% 50))] <- pick(list(NA, NaN, 0, 1, 1e-300, 1 - 1e-16, 2))
    q <- rnorm(n) * pick(c(1, 30)); q[sample.int(n, max(1, n %/% 50))] <- pick(list(NA, NaN, Inf, -Inf, 0))
    lw <- coin(0.5)
    fuzz_case(sprintf("q%05d", kk),
      r = sprintf("list(SimLev:::.sl_qt(p, %s, lower.tail = %s), SimLev:::.sl_pt(q, %s, lower.tail = %s))", num(df), lw, num(df), !lw),
      py = sprintf("L = simlev._lib\nresult = [L.qt(p, %s, lower_tail=%s), L.pt(q, %s, lower_tail=%s)]", pyn(df), if (lw) "True" else "False", pyn(df), if (lw) "False" else "True"),
      jl = sprintf("result = [SL.SLib.qt(p, %s; lower_tail = %s), SL.SLib.pt(q, %s; lower_tail = %s)]", num(df), tolower(lw), num(df), tolower(!lw)),
      inputs = list(p = p, q = q))
  }
}
ref_done(); ref_schreiben()
