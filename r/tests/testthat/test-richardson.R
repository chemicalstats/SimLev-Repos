# Eigenstaendige Richardson-Extrapolation (R/richardson.R). Die Bitgleichheit mit
# numDeriv prueft golden/modules/check_richardson.R (numDeriv als Orakel) und das
# Referenzmodul rugarch; hier Genauigkeit, Symmetrie und Auswertungsfolge.

test_that("Hesse-Matrix nach Richardson trifft analytische Werte", {
  f <- function(x) sin(x[1]) * exp(x[2]) + x[1]^2 * x[3] + log(x[3])
  x <- c(0.7, -0.3, 2)
  H <- SimLev:::.sl_richardson_hessian(f, x)
  exact <- matrix(c(-sin(x[1]) * exp(x[2]) + 2 * x[3], cos(x[1]) * exp(x[2]), 2 * x[1],
                    cos(x[1]) * exp(x[2]), sin(x[1]) * exp(x[2]), 0,
                    2 * x[1], 0, -1 / x[3]^2), 3, 3)
  expect_equal(H, exact, tolerance = 1e-7)
  expect_identical(H, t(H))
  expect_null(dimnames(H))
  expect_error(SimLev:::.sl_richardson_hessian(function(x) x, c(1, 2)), "skalare")
})

test_that("Jacobi-Matrix nach Richardson trifft analytische Werte", {
  g <- function(x) c(x[1] * x[2], exp(x[1]), sin(x[2]) + x[1]^3, 0 * x[1])
  x <- c(0.4, 1e-6)          # zweite Koordinate unter zero.tol: absoluter Schritt eps
  J <- SimLev:::.sl_richardson_jacobian(g, x)
  exact <- rbind(c(x[2], x[1]), c(exp(x[1]), 0), c(3 * x[1]^2, cos(x[2])), c(0, 0))
  expect_equal(J, exact, tolerance = 1e-8)
  expect_identical(dim(J), c(4L, 2L))
})

test_that("Auswertungsfolge wie im veroeffentlichten Verfahren", {
  log_h <- list(); log_j <- list()
  f <- function(x) { log_h[[length(log_h) + 1L]] <<- x; sum(x^2) }
  g <- function(x) { log_j[[length(log_j) + 1L]] <<- x; x^2 }
  x <- c(1, 2, 3); r <- 4
  SimLev:::.sl_richardson_hessian(f, x, r = r)
  # zweimal im Punkt, je Achse r Paare, je Paar a > b r Paare
  expect_length(log_h, 2 + 2 * r * 3 + 2 * r * 3)
  expect_identical(log_h[[1]], x); expect_identical(log_h[[2]], x)
  h <- abs(0.1 * x)
  expect_identical(log_h[[3]], x + c(h[1], 0, 0))
  expect_identical(log_h[[4]], x - c(h[1], 0, 0))
  expect_identical(log_h[[5]], x + c(h[1] / 2, 0, 0))
  expect_identical(log_h[[2 + 2 * r * 3 + 1]], x + c(h[1], h[2], 0))   # erstes Paar (2, 1)
  SimLev:::.sl_richardson_jacobian(g, x, r = r)
  # einmal im Punkt, dann Stufe fuer Stufe alle Achsen
  expect_length(log_j, 1 + 2 * r * 3)
  hj <- abs(1e-4 * x)
  expect_identical(log_j[[2]], x + c(hj[1], 0, 0))
  expect_identical(log_j[[4]], x + c(0, hj[2], 0))
  expect_identical(log_j[[8]], x + c(hj[1] / 2, 0, 0))
})
