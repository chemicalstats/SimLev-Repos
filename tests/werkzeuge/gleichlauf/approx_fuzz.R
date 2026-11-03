# tests/werkzeuge/gleichlauf/approx_fuzz.R – Fuzz von approx (seit 1.5.0: Interpolation je Punkt in Python und Julia
# im C-Kern sl_r_approx, core/slc_rbase.c)
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/approx_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul approx_fuzz:
#   - a-Fälle (gut zwei Drittel): stats::approx bzw. approxfun(...)(v) (Python simlev._r.stats, Julia SL.RStats) mit
#     1 bis 300 Stützstellen, unsortiert, mit Bindungen (Mittel mit Warnung, "ordered", min, max), NA in x oder y
#     (na.rm TRUE/FALSE), ±Inf, -0, Ausgabepunkten innerhalb, außerhalb, auf Stützstellen, NA, NaN, ±Inf; linear und
#     konstant (f in [0, 1], auch 0 und 1, ungültig), rule 1/2/c(1, 2)/c(2, 1), yleft/yright, n statt xout; Fehler
#     (zu wenige Werte, ungültiges f, NA in x bei na.rm = FALSE).
#   - p-Fälle: planning_goal (Rückwärtsrekursion mit approx je Schritt) mit kleinen Gittern, 1 bis 4 Kandidaten,
#     Ziel 0 bis über dem Startwert, Beiträgen (auch negativ), Renditen mit Totalverlust; Eingabefehler.
# Warnungen und Fehler mit ihren Aufrufen (r_calls) wie sim_fuzz.R.
#
# Prüfung (tests/werkzeuge/gleichlauf/run.sh, Schritt 5): Referenz aus R 1.4.2 (R_LIBS=/home/claude/rlib142), R neu mit
# tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261104)
ref_bereich("approx_fuzz", alle = TRUE); ref_init("approx_fuzz")
pick <- function(x) x[[sample.int(length(x), 1L)]]
coin <- function(p) runif(1) < p

# Fall schreiben und die Aufrufe der Warnungen und des Fehlers (nur R) als r_calls nachtragen
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
fnum <- function(v) ifelse(v == 0 & 1 / v < 0, "-0.0", num(v))   # Python/Julia: -0 als Gleitkommazahl
PH <- "import simlev._r.fmt\nimport simlev._r.stats as st\n"
JH <- "st = SL.RStats\n"

na <- round(N * 0.7)
for (k in seq_len(na)) {   # a-Fälle: approx, approxfun
  set.seed(seed0 + k)
  n <- pick(c(1, 2, 2, 3, 4, 5, 8, 13, 30, 100, 300))
  x <- pick(list(sort(runif(n, -5, 5)), sort(round(runif(n, 0, 10))), runif(n, -3, 3), round(rnorm(n) * 2),
                 seq_len(n) * pick(c(1, 0.1, 1e-300, 1e300)), cumsum(rexp(n))))
  y <- pick(list(rnorm(n), round(rnorm(n) * 3), cumsum(rnorm(n)) * 1e6, rep(pick(c(0, -0, 1)), n), exp(rnorm(n, 0, 20))))
  if (coin(0.1) && n > 1) x[sample.int(n, 1)] <- pick(c(NA, NaN))
  if (coin(0.12) && n > 1) y[sample.int(n, 1)] <- pick(c(NA, NaN, Inf, -Inf))
  if (coin(0.05)) x[sample.int(n, 1)] <- pick(c(Inf, -Inf))
  rg <- range(x[is.finite(x)], finite = TRUE)
  if (!all(is.finite(rg))) rg <- c(-1, 1)
  nout <- pick(c(1, 2, 5, 20, 200))
  xo <- runif(nout, rg[1] - 0.2 * diff(rg) - 0.1, rg[2] + 0.2 * diff(rg) + 0.1)
  xf <- x[is.finite(x)]
  if (coin(0.4) && length(xf)) xo[sample.int(nout, max(1, nout %/% 3), replace = TRUE)] <- xf[sample.int(length(xf), max(1, nout %/% 3), replace = TRUE)]
  if (coin(0.25)) xo[sample.int(nout, 1)] <- pick(c(NA, NaN, Inf, -Inf, -0, rg[1], rg[2]))
  meth <- pick(c("linear", "linear", "constant"))
  f <- pick(c(0, 0.25, 0.5, 1, runif(1), 0.999999))
  if (coin(0.03)) f <- pick(c(-0.1, 2, NA))
  rule <- pick(list(1, 2, c(1, 2), c(2, 1)))
  yl <- if (coin(0.15)) pick(c(-5, 0, NA, Inf)) else NULL
  yr <- if (coin(0.15)) pick(c(99, -0, NA, -Inf)) else NULL
  hasna <- anyNA(y)
  ties <- pick(c("mean", "mean", "ordered", if (!hasna) c("min", "max")))
  narm <- coin(0.8)
  form <- pick(c("xout", "xout", "xout", "n", "fun"))
  ra <- c(if (meth != "linear") sprintf("method = \"%s\"", meth), if (meth != "linear" || coin(0.2)) sprintf("f = %s", num(f)),
          if (!identical(rule, 1)) sprintf("rule = c(%s)", paste(rule, collapse = ", ")),
          if (!is.null(yl)) sprintf("yleft = %s", num(yl)), if (!is.null(yr)) sprintf("yright = %s", num(yr)),
          if (ties != "mean") sprintf("ties = %s", if (ties == "ordered") "\"ordered\"" else ties),
          if (!narm) "na.rm = FALSE")
  pv <- function(v) if (is.na(v)) "simlev._r.fmt.NA_REAL" else if (is.infinite(v)) (if (v > 0) "math.inf" else "-math.inf") else fnum(v)
  jv <- function(v) if (is.na(v)) "SL.NA" else if (is.infinite(v)) (if (v > 0) "Inf" else "-Inf") else fnum(v)
  pa <- c(if (meth != "linear") sprintf("method='%s'", meth), if (meth != "linear" || any(grepl("^f = ", ra))) sprintf("f=%s", pv(f)),
          if (!identical(rule, 1)) sprintf("rule=[%s]", paste(rule, collapse = ", ")),
          if (!is.null(yl)) sprintf("yleft=%s", pv(yl)), if (!is.null(yr)) sprintf("yright=%s", pv(yr)),
          if (ties != "mean") sprintf("ties=%s", if (ties == "ordered") "'ordered'" else ties), if (!narm) "na_rm=False")
  ja <- c(if (meth != "linear") sprintf("method = \"%s\"", meth), if (meth != "linear" || any(grepl("^f = ", ra))) sprintf("f = %s", jv(f)),
          if (!identical(rule, 1)) sprintf("rule = [%s]", paste(rule, collapse = ", ")),
          if (!is.null(yl)) sprintf("yleft = %s", jv(yl)), if (!is.null(yr)) sprintf("yright = %s", jv(yr)),
          if (ties != "mean") sprintf("ties = %s", switch(ties, ordered = "\"ordered\"", min = "minimum", max = "maximum")),
          if (!narm) "na_rm = false")
  cm <- function(a, sep = ", ") if (length(a)) paste0(sep, paste(a, collapse = ", ")) else ""
  nn <- pick(c(1, 2, 7, 50))
  if (form == "xout") {
    r <- sprintf("approx(x, y, xout = xo%s)", cm(ra))
    py <- sprintf("%simport math, simlev\nresult = st.approx(x, y, xout=xo%s)", PH, cm(pa))
    jl <- sprintf("%sresult = st.approx(x, y; xout = xo%s)", JH, cm(ja))
  } else if (form == "n") {
    r <- sprintf("approx(x, y, n = %d%s)", nn, cm(ra))
    py <- sprintf("%simport math, simlev\nresult = st.approx(x, y, n=%d%s)", PH, nn, cm(pa))
    jl <- sprintf("%sresult = st.approx(x, y; n = %d%s)", JH, nn, cm(ja))
  } else {
    r <- sprintf("approxfun(x, y%s)(xo)", cm(ra))
    py <- sprintf("%simport math, simlev\nresult = st.approxfun(x, y%s)(xo)", PH, cm(pa))
    jl <- sprintf("%sresult = st.approxfun(x, y%s)(xo)", JH, cm(ja, "; "))
  }
  fuzz_case(sprintf("a%05d", k), r = r, py = py, jl = jl, inputs = list(x = x, y = y, xo = xo))
}

for (k in seq_len(N - na)) {   # p-Fälle: planning_goal
  set.seed(seed0 + 100000 + k)
  S <- pick(c(1, 3, 8, 20, 60)); K <- pick(c(1, 2, 3, 4))
  R <- sapply(seq_len(K), function(j) exp(rnorm(S, 0.01 + 0.03 * j, pick(c(0, 0.02, 0.1, 0.3)))))
  R <- matrix(R, S, K)
  if (coin(0.1)) R[sample.int(S * K, 1)] <- 0
  if (coin(0.4)) colnames(R) <- c("a", "b", "c", "d")[seq_len(K)]
  if (coin(0.03)) R[1] <- pick(c(NA, -1, Inf))
  sv <- pick(c(1e5, 1, 5e4, 1e6))
  goal <- sv * pick(c(0, 0.5, 1, 1.2, 1.5, 3, 20))
  h <- pick(c(1, 2, 3, 5))
  cf <- pick(list(0, 0, 2000, -1000, c(1000, -500), sv * 0.1))
  ng <- pick(c(2, 3, 5, 11, 21, 41)); ns <- pick(c(1, 20, 200))
  if (coin(0.03)) ng <- pick(c(1, NA)); if (coin(0.03)) h <- pick(c(0, 1.5))
  cfr <- paste0("c(", paste(num(cf), collapse = ", "), ")")
  cfp <- paste0("[", paste(num(cf), collapse = ", "), "]")
  ngr <- if (is.na(ng)) "NA" else num(ng)
  r <- sprintf("planning_goal(R, start_value = %s, goal = %s, horizon = %s, contributions = %s, n_grid = %s, n_sim = %s, seed = %d)",
               num(sv), num(goal), num(h), cfr, ngr, num(ns), k)
  py <- sprintf("import simlev._r.fmt\nfrom simlev import planning as PL\nresult = PL.planning_goal(R, start_value=%s, goal=%s, horizon=%s, contributions=%s, n_grid=%s, n_sim=%s, seed=%d)",
                num(sv), num(goal), num(h), cfp, if (is.na(ng)) "simlev._r.fmt.NA_REAL" else num(ng), num(ns), k)
  jl <- sprintf("PL = SL.Planning\nresult = PL.planning_goal(R, %s, %s, %s; contributions = %s, n_grid = %s, n_sim = %s, seed = %d)",
                num(sv), num(goal), num(h), cfp, if (is.na(ng)) "SL.NA" else num(ng), num(ns), k)
  fuzz_case(sprintf("p%05d", k), r = r, py = py, jl = jl, inputs = list(R = R))
}
ref_done(); ref_schreiben()
