# Rauchprobe der Etappe 9.2 der C-Bibliothek slc (lineare Algebra, Matrixprodukt, kleinste Quadrate,
# Stineman, Glaettungsspline, Kerndichte): laeuft immer, auch ohne SIMLEV_LEGACY_TESTS. Gegenstueck
# zu python/tests/test_etappe9_linalg.py und julia/test/etappe92_smoke.jl. Die Gleichheit mit
# Python und Julia prueft tools/gleichlauf/ (Modul slc_linalg), die Genauigkeit scratchpad/e92/.
library(SimLev)
sl <- asNamespace("SimLev")
err <- function(expr) tryCatch({ expr; NA_character_ }, error = conditionMessage)
near <- function(a, b, tol = 1e-12) isTRUE(all(abs(a - b) <= tol * max(1, abs(b))))

A <- matrix(c(4, 2, 2, 3), 2)
R <- sl$.sl_chol(A)
stopifnot(identical(R, matrix(c(2, 0, 1, sqrt(2)), 2)), near(crossprod(R), A))
stopifnot(near(sl$.sl_solve_spd(A, c(1, 2)), c(-0.125, 0.75)), near(sl$.sl_solve_spd(A) %*% A, diag(2)))
stopifnot(near(sl$.sl_logdet_spd(A), log(8)), near(sl$.sl_backsolve(R, c(2, 1)), c(1 - 1 / (2 * sqrt(2)), 1 / sqrt(2))))
stopifnot(identical(err(sl$.sl_chol(matrix(c(1, 2, 2, 1), 2))), "chol: Matrix nicht positiv definit (führende Minore der Ordnung 2)"),
          identical(err(sl$.sl_chol(matrix(c(1, NA, NA, 1), 2))), "chol: NA/NaN/Inf in der Matrix"),
          identical(err(sl$.sl_solve_spd(diag(c(1e20, 1)), 1:2)), "solve: Matrix numerisch singulär"))
e <- sl$.sl_eigen_sym(A)
stopifnot(near(e$values, c(7 + sqrt(17), 7 - sqrt(17)) / 2), near(abs(e$vectors), abs(eigen(A)$vectors)), all(e$vectors[1, ] > 0 | e$vectors[2, ] > 0))
X <- matrix(as.double(1:6), 2)
stopifnot(identical(sl$.sl_matmul(X, t(X)), X %*% t(X)), identical(sl$.sl_crossprod(X), crossprod(X)),
          identical(sl$.sl_tcrossprod(X), tcrossprod(X)), identical(sl$.sl_matmul(1:3, 1:3), matrix(14, 1)),
          identical(err(sl$.sl_matmul(X, X)), "%m%: nicht passende Argumente"))
f <- sl$.sl_lsfit(cbind(1, 1:5, 2 * (1:5)), c(1, 3, 2, 5, 4))
stopifnot(f$rank == 2L, identical(f$pivot, c(1L, 2L, 3L)), is.na(f$coefficients[3]), near(f$coefficients[1:2], c(0.6, 0.8)))
stopifnot(identical(err(sl$.sl_lsfit(cbind(1, 1:3), c(1, NA, 3))), "lm: NA/NaN/Inf in y"))
g <- sl$.sl_logit_irls(cbind(1, 1:6), c(0, 0, 1, 0, 1, 1))
stopifnot(g$converged, near(g$coefficients, coef(glm(c(0, 0, 1, 0, 1, 1) ~ I(1:6), family = binomial())), 1e-7))
s <- sl$.sl_stineman(c(1, 2, 4), c(1, 3, 2), c(1, 1.5, 4, 5))
stopifnot(identical(s[c(1, 3)], c(1, 2)), is.na(s[4]), s[2] > 1 && s[2] < 3)
sp <- sl$.sl_smspline_fit(1:10, sin(1:10))
stopifnot(length(sp$x) == 10L, sp$df > 2, sp$df < 10, identical(sp$gam[c(1, 10)], c(0, 0)),
          near(sl$.sl_smspline_predict(sp, c(1, 10)), sp$y[c(1, 10)], 1e-12),
          identical(err(sl$.sl_smspline_fit(c(1, 2, 3, 3), 1:4)), "smooth.spline: mindestens 4 verschiedene x-Werte"))
k <- sl$.sl_kde(c(-1, 0, 2, 3, 3.5))
stopifnot(length(k$x) == 512L, identical(k$bw, bw.nrd0(c(-1, 0, 2, 3, 3.5))), abs(sum(k$y) * diff(k$x[1:2]) - 1) < 1e-3)
cat("etappe92-smoke: ok\n")
