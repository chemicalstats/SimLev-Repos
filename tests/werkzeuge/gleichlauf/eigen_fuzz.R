# tests/werkzeuge/gleichlauf/eigen_fuzz.R – Fuzz der symmetrischen Eigenzerlegung (core/slc_linalg.cpp sl_eigen_sym; seit 1.6.2
# Householder-Tridiagonalisierung und implizites QL/QR, bis 1.6.1 zyklisches Jacobi).
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/eigen_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul eigen_fuzz:
#   75 % Eigenzerlegung direkt (n 1 bis 140, Werte und Vektoren bzw. nur Werte; Kovarianzen, ganzzahlige und
#        dünn besetzte Matrizen, mehrfache Eigenwerte, Diagonalmatrizen, fast diagonale, stark skalierte, Nullmatrix),
#   25 % portfolio_optimize (min_variance, max_diversification, risk_parity) mit 3 bis 60 Anlagen.
# Warnungen und Fehler mit ihren Aufrufen (r_calls) wie sim_fuzz.R.
#
# Genauigkeit (seit 1.6.2, nur R): je direkter Zerlegung mit Vektoren gegen eine hochgenaue Rechnung mit Rmpfr (128 Bit)
# (n <= 40: Spalten 1 und n; größere n: jeder zehnte Fall, Spalte 1): Residuum ||A v - lambda v|| / ||A||, Orthogonalität max |v_j' v_k - delta_jk|
# (gegen alle Spalten k) und Fehler des Eigenwerts gegen den Rayleigh-Quotienten v'Av / v'v in 128 Bit, bezogen auf
# ||A|| (= max |lambda|). Zeilen "Genauigkeit eigen ..." mit Median und Maximum; Ende 1, wenn ein Wert 10 n 2^-52
# übersteigt (übliche Schranke n u der Householder-Verfahren mit Sicherheitsfaktor). Seit 1.6.3 nur ab 1000 Fällen
# (run.py --full) oder mit SIMLEV_FUZZ_GENAU=1 (ref_tools.R fuzz_genau); geprüft wird die Zerlegung des Falls.
#
# Prüfung (tests/werkzeuge/gleichlauf/run.py, Schritt 5): abgelegte Referenz (seit 1.6.2 aus R 1.6.2, run.py --ref-erzeugen 162),
# R neu mit tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261117)
ref_bereich("eigen_fuzz", alle = TRUE); ref_init("eigen_fuzz")
GENAU <- fuzz_genau(N)
if (GENAU) suppressMessages(library(Rmpfr))
ACC <- list()
eig_acc <- function(M, e, cols) {                    # Spalten cols gegen 128 Bit (Rmpfr)
  n <- nrow(M); nA <- max(abs(e$values)); if (nA == 0) nA <- 1
  Am <- mpfr(M, 128L); Vm <- mpfr(e$vectors, 128L)
  for (j in unique(cols)) {
    v <- Vm[, j]
    Av <- colSums(Am * v)                            # (A v)_i = sum_k A_ki v_k (A symmetrisch)
    res <- asNumeric(sqrt(sum((Av - e$values[j] * v)^2))) / nA
    lam <- asNumeric(abs(sum(v * Av) / sum(v * v) - e$values[j])) / nA
    G <- asNumeric(colSums(Vm * v)); G[j] <- G[j] - 1
    ACC[[length(ACC) + 1L]] <<- c(n = n, res = res, orth = max(abs(G)), lam = lam)
  }
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
    e <- fuzz_case(sprintf("e%05d", kk),
      r = sprintf("SimLev:::.sl_eigen_sym(M, only.values = %s)", ov),
      py = sprintf("result = simlev._lib.eigen_sym(M, only_values=%s)", if (ov) "True" else "False"),
      jl = sprintf("result = SL.SLib.eigen_sym(M; only_values = %s)", tolower(ov)),
      inputs = list(M = M))
    if (GENAU && !ov && !is.null(e) && (n <= 40 || kk %% 10 == 1))    # Genauigkeit (ohne Zufall)
      eig_acc(M, e, if (n <= 40) c(1, n) else 1)
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
if (length(ACC)) {
  a <- do.call(rbind, ACC); lim <- 10 * a[, "n"] * 2^-52
  for (k in c("res", "orth", "lam"))
    cat(sprintf("Genauigkeit eigen %-4s %5d Spalten: Median %.2e, max %.2e, max / (n u) %.2f%s\n", k, nrow(a), stats::median(a[, k]),
                max(a[, k]), max(a[, k] / (a[, "n"] * 2^-52)), if (any(a[, k] > lim)) sprintf("  ÜBER 10 n u: %d", sum(a[, k] > lim)) else ""))
  if (any(a[, c("res", "orth", "lam")] > lim)) quit(status = 1)
}
