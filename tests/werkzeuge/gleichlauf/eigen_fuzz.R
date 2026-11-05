# tests/werkzeuge/gleichlauf/eigen_fuzz.R – Fuzz der symmetrischen Eigenzerlegung (seit 1.6.0 schneller bei gleicher
# Drehfolge, core/slc_linalg.cpp sl_eigen_sym: nur Spalten drehen, Zeilen blockweise nachtragen).
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/eigen_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul eigen_fuzz:
#   75 % Eigenzerlegung direkt (n 1 bis 140, Werte und Vektoren bzw. nur Werte; Kovarianzen, ganzzahlige und
#        dünn besetzte Matrizen, mehrfache Eigenwerte, Diagonalmatrizen, fast diagonale, stark skalierte, Nullmatrix),
#   25 % portfolio_optimize (min_variance, max_diversification, risk_parity) mit 3 bis 60 Anlagen.
# Warnungen und Fehler mit ihren Aufrufen (r_calls) wie sim_fuzz.R.
#
# Prüfung (tests/werkzeuge/gleichlauf/run.py, Schritt 5): Referenz aus R 1.5.2 (R_LIBS=/home/claude/rlib152), R neu mit
# tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261117)
ref_bereich("eigen_fuzz", alle = TRUE); ref_init("eigen_fuzz")
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
q_r <- function(x) sprintf("c(%s)", paste0("'", x, "'", collapse = ", "))
q_p <- function(x) sprintf("[%s]", paste0("'", x, "'", collapse = ", "))
q_j <- function(x) sprintf("[%s]", paste0("\"", x, "\"", collapse = ", "))

for (kk in seq_len(N)) {
  set.seed(seed0 + kk)
  if (kk %% 4 != 0) {
    n <- pick(c(1, 2, 3, 5, 8, 17, 33, 40, 64, 65, 100, 140))
    M <- switch(pick(1:7),
      { B <- matrix(rnorm(n * (n + 3)), n); tcrossprod(B) / n },                   # Kovarianz
      { A <- matrix(sample(-3:3, n * n, TRUE), n); A + t(A) },                      # ganzzahlig
      { A <- matrix(rnorm(n * n) * (runif(n * n) < 0.1), n); A + t(A) },          # dünn
      { Q <- qr.Q(qr(matrix(rnorm(n * n), n))); Q %*% diag(rep(c(1, 2), length.out = n)) %*% t(Q) },  # mehrfach
      diag(sample(c(0, 1, -2, 5), n, TRUE), n),                                    # diagonal
      { A <- diag(seq_len(n), n); A[upper.tri(A)] <- rnorm(sum(upper.tri(A))) * 1e-9; A[lower.tri(A)] <- t(A)[lower.tri(A)]; A },
      { B <- matrix(rnorm(n * n), n); S <- crossprod(B); D <- diag(exp(runif(n, -8, 8)), n); D %*% S %*% D })
    if (coin(0.03)) M[] <- 0
    M <- (M + t(M)) / 2
    ov <- coin(0.3)
    fuzz_case(sprintf("e%05d", kk),
      r = sprintf("SimLev:::.sl_eigen_sym(M, only.values = %s)", ov),
      py = sprintf("result = simlev._lib.eigen_sym(M, only_values=%s)", if (ov) "True" else "False"),
      jl = sprintf("result = SL.SLib.eigen_sym(M; only_values = %s)", tolower(ov)),
      inputs = list(M = M))
  } else {
    k <- pick(c(3, 10, 25, 60)); nm <- sprintf("a%02d", seq_len(k))
    d <- data.frame(date = seq.Date(as.Date("2005-01-03") + sample(0:3000, 1), by = "day", length.out = pick(c(700, 1500))))
    f <- rnorm(nrow(d))
    for (j in seq_len(k)) { rho <- runif(1, 0, 0.9); d[[nm[j]]] <- round(100 * cumprod(1 + 0.01 * (rho * f + sqrt(1 - rho^2) * rnorm(nrow(d)))), 4) }
    me <- pick(c("min_variance", "min_variance", "max_diversification", "risk_parity"))
    fuzz_case(sprintf("p%05d", kk),
      r = sprintf("portfolio_optimize(d, %s, method = '%s')", q_r(nm), me),
      py = sprintf("result = simlev.portfolio_optimize(d, assets=%s, method='%s')", q_p(nm), me),
      jl = sprintf("result = SL.portfolio_optimize(d; assets = %s, method = \"%s\")", q_j(nm), me),
      inputs = list(d = d))
  }
}
ref_done(); ref_schreiben()
