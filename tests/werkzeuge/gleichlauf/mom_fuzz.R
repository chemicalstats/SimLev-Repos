# tests/werkzeuge/gleichlauf/mom_fuzz.R – Fuzz der Momentum-Scores (seit 1.6.0 im Kern, core/slc_prep.cpp sl_mom_back,
# sl_mom_score; bis 1.5.2 je Sprache: Rückblick über Datumstext in R, Schleifen in Python und Julia).
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/mom_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul mom_fuzz:
#   70 % momentum_score (1 bis 4 Anlagen, 1 bis 1.500 Zeilen, Kalender-, Werktags- und lückenhafte Daten, Monatsenden,
#        Schaltjahre, Jahre 1901 bis 2090, NA/NaN-Kurse, führende NA, Kurse 0, Rückblicke 0 bis 36 und negativ,
#        "average" und "13612w", gelegentlich unsortiert oder doppelte Tage),
#   30 % tactical_rotation (Rangfolge aus den Scores, top, safe, absolute).
# Warnungen und Fehler mit ihren Aufrufen (r_calls) wie sim_fuzz.R.
#
# Prüfung (tests/werkzeuge/gleichlauf/run.py, Schritt 5): Referenz aus R 1.5.2 (R_LIBS=/home/claude/rlib152), R neu mit
# tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261116)
ref_bereich("mom_fuzz", alle = TRUE); ref_init("mom_fuzz")
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
qr <- function(x) sprintf("c(%s)", paste0("'", x, "'", collapse = ", "))
qp <- function(x) sprintf("[%s]", paste0("'", x, "'", collapse = ", "))
qj <- function(x) sprintf("[%s]", paste0("\"", x, "\"", collapse = ", "))
vr <- function(x) sprintf("c(%s)", paste(x, collapse = ", "))
vp <- function(x) sprintf("[%s]", paste(x, collapse = ", "))

for (kk in seq_len(N)) {
  set.seed(seed0 + kk)
  n <- pick(c(1, 2, 30, 300, 800, 1500))
  start <- pick(list(as.Date("1901-01-01") + sample(0:69000, 1), as.Date(sprintf("%d-%02d-%02d", sample(1990:2030, 1), sample(1:12, 1), pick(c(28, 29, 30, 31, 1))), format = "%Y-%m-%d")))
  if (is.na(start)) start <- as.Date("2000-02-29")
  step <- switch(pick(1:3), rep(1, n), sample(c(1, 1, 1, 1, 3), n, TRUE), sample(1:12, n, TRUE))
  d <- data.frame(date = start + cumsum(step) - step[1])
  na <- pick(1:4); nm <- c("a", "b", "c", "e")[seq_len(na)]
  for (a in nm) {
    p <- round(runif(1, 1, 300) * cumprod(1 + rnorm(n, 2e-4, 0.015)), 4)
    if (n > 3 && coin(0.3)) p[sample.int(n, max(1, n %/% 8))] <- NA
    if (n > 3 && coin(0.1)) p[sample.int(n, 1)] <- NaN
    if (n > 3 && coin(0.15)) p[seq_len(sample.int(n - 1, 1))] <- NA
    if (n > 3 && coin(0.05)) p[sample.int(n, 1)] <- 0
    if (coin(0.03)) p[] <- NA
    d[[a]] <- p
  }
  if (n > 3 && coin(0.03)) d <- d[sample.int(n), , drop = FALSE]
  if (n > 3 && coin(0.03)) d$date[2] <- d$date[1]
  rownames(d) <- NULL
  if (n < 300 || coin(0.7)) {
    lb <- pick(list(c(1, 3, 6, 12), 1, c(0, 1), c(12, 1, 3), c(24, 36), c(-1, 2), c(1.5, 2.7)))
    ty <- pick(c("average", "average", "13612w"))
    fuzz_case(sprintf("m%05d", kk),
      r = sprintf("momentum_score(d, %s, lookbacks = %s, type = '%s')", qr(nm), vr(lb), ty),
      py = sprintf("result = simlev.momentum_score(d, %s, lookbacks=%s, type='%s')", qp(nm), vp(lb), ty),
      jl = sprintf("result = SL.momentum_score(d, %s; lookbacks = %s, type = \"%s\")", qj(nm), vp(lb), ty),
      inputs = list(d = d))
  } else {
    d$GELD <- 100 * cumprod(rep(1 + 0.01 / 260, nrow(d)))
    top <- min(na, pick(c(1, 2, 3))); ab <- coin(0.7)
    fuzz_case(sprintf("t%05d", kk),
      r = sprintf("tactical_rotation(d, assets = %s, top = %d, safe = 'GELD', absolute = %s)", qr(nm), top, ab),
      py = sprintf("result = simlev.tactical_rotation(d, %s, top=%d, safe='GELD', absolute=%s)", qp(nm), top, if (ab) "True" else "False"),
      jl = sprintf("result = SL.tactical_rotation(d, %s; top = %d, safe = \"GELD\", absolute = %s)", qj(nm), top, tolower(ab)),
      inputs = list(d = d))
  }
}
ref_done(); ref_schreiben()
