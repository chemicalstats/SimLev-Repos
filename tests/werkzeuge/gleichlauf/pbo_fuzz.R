# tests/werkzeuge/gleichlauf/pbo_fuzz.R – Fuzz von overfit_pbo (seit 1.5.0: Aufteilungen der CSCV im Kern pbo_cscv,
# core/research_core_impl.h)
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/pbo_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul pbo_fuzz:
# overfit_pbo() mit Renditematrizen (1 bis 25 Punkte, 4 bis 30 Beobachtungen je Block, mit und ohne Namen), S 1 bis 16 (auch
# ungerade), allen Kennzahlen (sharpe, sortino, geometric, mean), Gleichständen (gerundete und doppelte
# Spalten), Spalten ohne Schwankung, NA-Zeilen, risk_free, Tages-,
# Wochen- und Monatsfrequenz mit Datum; seit 1.5.1 auch +-Inf, -1 und Werte unter -1 in den Renditen (log1p-Warnung,
# NaN-Zweige des Kerns, leere Regression) sowie S = 18 und S >= 34 (choose(S, S/2) jenseits des Ganzzahlbereichs).
# Warnungen und Fehler mit ihren Aufrufen (r_calls) wie sim_fuzz.R.
#
# Prüfung (tests/werkzeuge/gleichlauf/run.py, Schritt 5): abgelegte Referenz (seit 1.6.2 aus R 1.6.2, run.py --ref-erzeugen 162), R neu mit
# tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261108)
ref_bereich("pbo_fuzz", alle = TRUE); ref_init("pbo_fuzz")
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

for (kk in seq_len(N)) {
  set.seed(seed0 + kk)
  Np <- if (coin(0.03)) 1 else pick(c(2, 3, 5, 10, 25))
  S <- pick(c(2, 4, 6, 8, 10, 12, 12, 16))
  freq <- pick(c("day", "day", "week", "month"))
  Tn <- S * pick(c(4, 5, 10, 30)) * switch(freq, day = 1, week = 4, month = 16) + sample.int(S, 1) - 1
  if (coin(0.05)) Tn <- S * 3                                                       # zu wenige Beobachtungen
  if (coin(0.03)) S <- pick(c(3, 1))
  R <- matrix(rnorm(Tn * Np, pick(c(0, 3e-4, 1e-3)), pick(c(0.005, 0.01, 0.03))), Tn, Np)
  R <- R + rep(rnorm(Np, 0, 5e-4), each = Tn)
  if (coin(0.3)) R <- round(R, pick(c(2, 3)))                                       # Gleichstände
  if (Np > 1 && coin(0.2)) R[, 2] <- R[, 1]
  if (Np > 1 && coin(0.1)) R[, Np] <- 0.001                                         # ohne Schwankung
  if (coin(0.1)) R[sample.int(Tn, max(1, Tn %/% 30)), sample.int(Np, 1)] <- NA
  if (coin(0.3)) colnames(R) <- paste0("k", seq_len(Np))
  metric <- pick(c("sharpe", "sharpe", "sortino", "geometric", "mean"))
  a <- c(sprintf("S = %d", S), if (metric != "sharpe") sprintf("metric = '%s'", metric), sprintf("frequency = '%s'", freq))
  ap <- c(sprintf("S=%d", S), if (metric != "sharpe") sprintf("metric='%s'", metric), sprintf("frequency='%s'", freq))
  aj <- c(sprintf("S = %d", S), if (metric != "sharpe") sprintf('metric = "%s"', metric), sprintf('frequency = "%s"', freq))
  inp <- list(R = R)
  if (freq != "day" || coin(0.2)) {
    inp$dt <- as.Date("2001-01-01") + cumsum(sample(1:3, Tn, replace = TRUE))
    a <- c(a, "dates = dt"); ap <- c(ap, "dates=dt"); aj <- c(aj, "dates = dt")
  }
  if (coin(0.2)) { rf <- num(pick(c(2, -1, 0.5))); a <- c(a, paste("risk_free =", rf)); ap <- c(ap, paste0("risk_free=", rf)); aj <- c(aj, paste("risk_free =", rf)) }
  if (coin(0.15)) {                                                                 # seit 1.5.1: +-Inf, -1, < -1
    k <- sample.int(Tn * Np, pick(c(1, 1, 2, 5, Tn)))
    inp$R[k] <- sample(c(Inf, -Inf, Inf, -Inf, -1, -1.5), length(k), replace = TRUE)
  }
  fuzz_case(sprintf("o%05d", kk),
    r = sprintf("overfit_pbo(R, %s)", paste(a, collapse = ", ")),
    py = sprintf("import simlev.overfitting as OF\nresult = OF.overfit_pbo(R, %s)", paste(ap, collapse = ", ")),
    jl = sprintf("OF = SL.Overfitting\nresult = OF.overfit_pbo(R; %s)", paste(aj, collapse = ", ")),
    inputs = inp)
  if (coin(0.02)) {                                                                 # seit 1.5.1: S >= 34 (choose > .Machine$integer.max)
    Sg <- pick(c(18, 34, 36, 40, 64)); Tg <- Sg * pick(c(4, 5)) + sample.int(Sg, 1) - 1
    Rg <- matrix(rnorm(Tg * 3, 0, pick(c(0.01, 0.6))), Tg, 3)
    fuzz_case(sprintf("s%05d", kk),
      r = sprintf("overfit_pbo(R, S = %d, frequency = 'day')", Sg),
      py = sprintf("import simlev.overfitting as OF\nresult = OF.overfit_pbo(R, S=%d, frequency='day')", Sg),
      jl = sprintf("OF = SL.Overfitting\nresult = OF.overfit_pbo(R; S = %d, frequency = \"day\")", Sg),
      inputs = list(R = Rg))
  }
}
ref_done(); ref_schreiben()
