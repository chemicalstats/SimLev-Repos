# Tests fuer die eigene MS-GARCH-Schaetzung (.ms_garch_fit, R/ms_garch.R; Kern
# .ms_garch_filter, src/ms_garch.c) und die Verfahren "ms_garch",
# "ms_ar_garch_m" und "tvtp_ms_garch" von bootstrap()

# 2-Regime-MS-GJR-GARCH nach Haas, Mittnik und Paolella (2004) simulieren:
# Varianzpfade aller Regime laufen parallel, Start bei der unbedingten Varianz
sim_ms_gjr <- function(n, om, al, ga, be, P, seed) {
  set.seed(seed); K <- length(om)
  hk <- om / (1 - al - ga / 2 - be); s <- 1L; y <- numeric(n); st <- integer(n)
  for (t in seq_len(n)) {
    if (t > 1) {
      s <- sample.int(K, 1, prob = P[s, ]); e <- y[t - 1]
      hk <- om + (al + ga * (e < 0)) * e^2 + be * hk
    }
    st[t] <- s; y[t] <- sqrt(hk[s]) * stats::rnorm(1)
  }
  list(y = y, s = st)
}
ms_true <- list(om = c(2e-6, 2e-5), al = c(0.02, 0.05), ga = c(0.04, 0.10), be = c(0.92, 0.85),
                P = matrix(c(0.99, 0.01, 0.03, 0.97), 2, byrow = TRUE))
ms_sim <- local({
  p <- ms_true; sim_ms_gjr(3000, p$om, p$al, p$ga, p$be, p$P, 2)
})

test_that("ms_garch_filter follows the Hamilton recursion with parallel variance paths", {
  set.seed(1); y <- stats::rnorm(50, 0, 0.01)
  om <- c(1e-6, 5e-6); al <- c(0.05, 0.1); be <- c(0.9, 0.8); ga <- c(0.02, 0.05)
  P <- matrix(c(0.95, 0.05, 0.1, 0.9), 2, byrow = TRUE); xi0 <- c(2 / 3, 1 / 3); h1 <- stats::var(y)
  f <- SimLev:::.ms_garch_filter(y, om, al, be, ga, P, xi0, h1)
  n <- length(y); h <- matrix(0, n, 2); pred <- filt <- h; ll <- 0; xi <- xi0
  for (t in seq_len(n)) {
    h[t, ] <- if (t == 1) h1 else om + (al + ga * (y[t - 1] < 0)) * y[t - 1]^2 + be * h[t - 1, ]
    phi <- stats::dnorm(y[t], 0, sqrt(h[t, ])); pred[t, ] <- xi
    ft <- sum(xi * phi); filt[t, ] <- xi * phi / ft; ll <- ll + log(ft)
    xi <- as.numeric(t(P) %*% filt[t, ])
  }
  expect_equal(f$h, h, tolerance = 1e-14)
  expect_equal(f$pred, pred, tolerance = 1e-12)
  expect_equal(f$filt, filt, tolerance = 1e-12)
  expect_equal(f$loglik, ll, tolerance = 1e-12)
  expect_equal(f$lB, stats::dnorm(y, 0, sqrt(h), log = TRUE), tolerance = 1e-12)
  # Nicht endliche Dichte -> loglik = -Inf
  expect_identical(SimLev:::.ms_garch_filter(y, c(-1, -1), c(0, 0), c(0, 0), c(0, 0), P, xi0, -1)$loglik, -Inf)
})

test_that(".ms_garch_fit is deterministic and leaves the RNG state alone", {
  y <- ms_sim$y[1:1500]
  set.seed(123); s0 <- .Random.seed
  f1 <- SimLev:::.ms_garch_fit(y, 2, "gjrGARCH")
  expect_identical(.Random.seed, s0)
  f2 <- SimLev:::.ms_garch_fit(y, 2, "gjrGARCH")
  expect_identical(f1, f2)
  expect_identical(names(f1), c("omega", "alpha", "beta", "gamma", "P", "regimes", "s2", "loglik", "convergence"))
})

test_that(".ms_garch_fit recovers known parameters of a simulated 2-regime GJR-GARCH", {
  # Probelauf (seed 2, n = 3000): unbedingte Varianzen geschaetzt/wahr 1.074 bzw.
  # 1.146, Diagonale von P 0.9921 bzw. 0.9742 (wahr 0.99 und 0.97); ueber die
  # Seeds 1 bis 12 lagen die Verhaeltnisse bei 0.83-1.16 (ruhiges Regime) bzw.
  # 0.70-2.0 (seltenes, unruhiges Regime), p11 bei 0.983-0.994, p22 bei
  # 0.92-0.98. Grenzen daher: Regime 1 +-25 %, Regime 2 Faktor 0.6-1.7,
  # p11 +-0.01, p22 +-0.04, Regimepfad zu mindestens 80 % richtig.
  p <- ms_true
  f <- SimLev:::.ms_garch_fit(ms_sim$y, 2, "gjrGARCH")
  unc_true <- p$om / (1 - p$al - p$ga / 2 - p$be)
  unc <- f$omega / (1 - f$alpha - f$gamma / 2 - f$beta)
  ratio <- unc / unc_true
  expect_true(ratio[1] > 0.75 && ratio[1] < 1.25, info = paste(ratio, collapse = " "))
  expect_true(ratio[2] > 0.6 && ratio[2] < 1.7, info = paste(ratio, collapse = " "))
  expect_lt(abs(f$P[1, 1] - 0.99), 0.01)
  expect_lt(abs(f$P[2, 2] - 0.97), 0.04)
  expect_gt(mean(f$regimes == ms_sim$s), 0.8)
  expect_identical(f$convergence, 0L)
})

test_that(".ms_garch_fit returns a consistent fit for both variance models and K = 2, 3", {
  y <- ms_sim$y[1:1500]
  for (model in c("sGARCH", "gjrGARCH")) for (K in 2:3) {
    f <- SimLev:::.ms_garch_fit(y, K, model)
    lab <- paste(model, K)
    expect_length(f$s2, length(y)); expect_true(all(is.finite(f$s2) & f$s2 > 0), info = lab)
    expect_equal(dim(f$P), c(K, K)); expect_equal(rowSums(f$P), rep(1, K), tolerance = 1e-12, info = lab)
    expect_true(all(f$P >= 0), info = lab)
    unc <- f$omega / (1 - f$alpha - f$gamma / 2 - f$beta)
    expect_false(is.unsorted(unc), info = lab)
    expect_true(is.finite(f$loglik), info = lab)
    expect_type(f$regimes, "integer"); expect_length(f$regimes, length(y))
    expect_true(all(f$regimes %in% seq_len(K)), info = lab)
    expect_true(all(f$alpha + f$gamma / 2 + f$beta < 1), info = lab)
    if (model == "sGARCH") expect_identical(f$gamma, rep(0, K))
  }
})

test_that(".ms_garch_fit rejects other variance models and regime numbers in German", {
  y <- ms_sim$y[1:300]
  expect_error(SimLev:::.ms_garch_fit(y, 2, "eGARCH"), "muss \"sGARCH\" oder \"gjrGARCH\" sein \\(erhalten: eGARCH\\)")
  expect_error(SimLev:::.ms_garch_fit(y, 1, "sGARCH"), "ganze Zahl >= 2")
  expect_error(SimLev:::.ms_garch_fit(y, 2.5, "sGARCH"), "ganze Zahl >= 2")
})

test_that("MS-GARCH methods run end to end without further packages", {
  n <- 600
  d <- data.frame(us = 1 + 3e-4 + ms_sim$y[1:n])
  set.seed(4); d$eu <- d$us * (1 + stats::rnorm(n, 0, 0.004))
  cfg <- bootstrap_config(c(us = "us", eu = "eu"), regime_index = "us")
  for (m in c("ms_garch", "ms_ar_garch_m", "tvtp_ms_garch")) {
    b <- suppressWarnings(suppressMessages(bootstrap(d, cfg, m, n = 2, seed = 1, progress = FALSE)))
    expect_s3_class(b, "bootstrap_result")
    expect_length(b$paths, 2L)
    expect_true(all(is.finite(b$paths[[1]])), info = m)
    expect_equal(dim(b$paths[[1]]), c(n + 1L, 2L), info = m)
    b2 <- suppressWarnings(suppressMessages(bootstrap(d, cfg, m, n = 2, seed = 1, progress = FALSE)))
    expect_identical(b$paths, b2$paths)
  }
  msg <- capture_messages(bootstrap(d, cfg, "ms_garch", n = 1, seed = 1, progress = FALSE,
                                    params = list(ms_garch_model = "sGARCH")))
  expect_true(any(grepl("MS-GARCH(2, sGARCH): P(stay)", msg, fixed = TRUE)))
  expect_error(bootstrap(d, cfg, "ms_garch", n = 1, seed = 1, progress = FALSE, params = list(ms_garch_model = "eGARCH")),
               "Vorberechnung fehlgeschlagen: MS-GARCH: Varianzmodell")
  expect_error(bootstrap(d, cfg, "tvtp_ms_garch", n = 1, seed = 1, progress = FALSE, params = list(tvtp_n_regimes = 1)),
               "ganze Zahl >= 2")
})
