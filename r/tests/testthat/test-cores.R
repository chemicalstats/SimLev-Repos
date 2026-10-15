# Rechenkerne in C++ (src/research_core.cpp) gegen einfache R-Referenzen

test_that("projection onto the capped simplex is exact", {
  proj <- SimLev:::.proj_box_simplex
  bisect <- function(v, lo, hi) {
    f <- function(t) sum(pmin(hi, pmax(lo, v - t))) - 1
    a <- min(v - hi) - 1; b <- max(v - lo) + 1
    for (i in 1:200) { m <- (a + b) / 2; if (f(m) > 0) a <- m else b <- m }
    pmin(hi, pmax(lo, v - (a + b) / 2))
  }
  set.seed(1)
  for (k in 1:50) {
    n <- sample(2:12, 1); v <- rnorm(n, 0, 2); lo <- runif(n, 0, 0.05); hi <- pmax(lo + 0.05, runif(n, 0.1, 0.8))
    if (sum(hi) < 1) hi <- hi / sum(hi) * 1.2
    w <- proj(v, lo, hi)
    expect_equal(sum(w), 1, tolerance = 1e-14)
    expect_true(all(w >= lo - 1e-15 & w <= hi + 1e-15))
    expect_equal(w, bisect(v, lo, hi), tolerance = 1e-12)
  }
})

test_that("box-simplex QP matches the closed-form minimum variance solution", {
  set.seed(2); A <- matrix(rnorm(400), 100); S <- crossprod(A) / 100
  w <- SimLev:::.qp_simplex(S, rep(0, 4), rep(0, 4), rep(1, 4))
  iv <- solve(S, rep(1, 4)); ref <- iv / sum(iv)
  if (all(ref > 0)) expect_equal(w, ref, tolerance = 1e-9)
  expect_equal(sum(w), 1, tolerance = 1e-14)
})

test_that("Kendall tau equals stats::cor, also with ties", {
  set.seed(3)
  for (n in c(5, 50, 800)) {
    x <- rnorm(n); y <- x + rnorm(n)
    expect_equal(SimLev:::.kendall(x, y), cor(x, y, method = "kendall"), tolerance = 1e-14)
    xt <- round(x); yt <- round(y)
    expect_equal(SimLev:::.kendall(xt, yt), cor(xt, yt, method = "kendall"), tolerance = 1e-14)
  }
  M <- matrix(rnorm(300), ncol = 3)
  expect_equal(SimLev:::.kendall(M), cor(M, method = "kendall"), tolerance = 1e-14, ignore_attr = TRUE)
})

test_that("rolling mean and variance match direct window computations", {
  set.seed(4); x <- 1e4 + cumsum(rnorm(3000)); w <- 50
  ref_m <- c(rep(NA, w - 1), vapply(w:3000, function(i) mean(x[(i - w + 1):i]), 0))
  ref_v <- c(rep(NA, w - 1), vapply(w:3000, function(i) { v <- x[(i - w + 1):i]; mean((v - mean(v))^2) }, 0))
  expect_equal(SimLev:::.roll_mean(x, w), ref_m, tolerance = 1e-13)
  expect_equal(SimLev:::.roll_var(x, w), ref_v, tolerance = 1e-11)
  y <- x; y[100] <- NA
  m <- SimLev:::.roll_mean(y, w)
  expect_true(all(is.na(m[100:(100 + w - 1)]))); expect_false(is.na(m[100 + w]))
})

test_that("quantile regression reaches the exact optimum (vertex search)", {
  set.seed(5); n <- 300; x <- rnorm(n); y <- 0.4 * x + rt(n, 3); X <- cbind(1, x)
  rho <- function(b, tau) { r <- y - X %*% b; sum(r * (tau - (r < 0))) }
  for (tau in c(0.1, 0.5, 0.9)) {
    b <- quantile_reg(y, cbind(x = x), tau)
    best <- Inf
    for (i in 1:(n - 1)) for (j in (i + 1):n) if (abs(x[i] - x[j]) > 1e-9) {
      bb <- solve(X[c(i, j), ], y[c(i, j)]); v <- rho(bb, tau); if (v < best) best <- v
    }
    expect_equal(rho(b, tau), best, tolerance = 1e-12)
  }
})

test_that("HMM forward-backward and GARCH filter match R loops", {
  set.seed(6); Tn <- 200; K <- 3
  B <- matrix(runif(Tn * K, 0.1, 1), Tn); A <- matrix(runif(K * K), K); A <- A / rowSums(A); p0 <- rep(1 / K, K)
  al <- matrix(0, Tn, K); cs <- numeric(Tn); a <- p0 * B[1, ]; cs[1] <- sum(a); al[1, ] <- a / cs[1]
  for (t in 2:Tn) { a <- drop(al[t - 1, ] %*% A) * B[t, ]; cs[t] <- sum(a); al[t, ] <- a / cs[t] }
  be <- matrix(1, Tn, K); for (t in (Tn - 1):1) be[t, ] <- drop(A %*% (B[t + 1, ] * be[t + 1, ])) / cs[t + 1]
  xi <- matrix(0, K, K); for (t in 1:(Tn - 1)) xi <- xi + (al[t, ] %o% (B[t + 1, ] * be[t + 1, ])) * A / cs[t + 1]
  fb <- SimLev:::.hmm_forward_backward(B, A, p0)
  expect_equal(fb$filtered, al, tolerance = 1e-13); expect_equal(fb$scale, cs, tolerance = 1e-13)
  expect_equal(fb$xi, xi, tolerance = 1e-12)
  ep <- rnorm(500, 0, 0.01); s2 <- numeric(500); v <- 1e-4
  for (t in 1:500) { s2[t] <- v; v <- max(1e-14, 1e-6 + (0.05 + 0.1 * (ep[t] < 0)) * ep[t]^2 + 0.9 * v) }
  expect_identical(SimLev:::.garch_filter(ep, 1e-6, 0.05, 0.9, 0.1, 1e-4), s2)
})
