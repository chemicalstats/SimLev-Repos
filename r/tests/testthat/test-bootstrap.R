# Tests fuer bootstrap_config(), bootstrap(), bootstrap_study(), block_length()

make_boot_data <- function(n = 1500, seed = 5) {
  set.seed(seed)
  us <- 1 + rnorm(n, 3e-4, 0.011)
  data.frame(us = us, eu = us * (1 + rnorm(n, 0, 0.004)), rate = 2 + cumsum(rnorm(n, 0, 0.005)))
}
make_cfg <- function() {
  bootstrap_config(c(us = "us", eu = "eu"), regime_index = "us", aux = c(rate = "rate"),
                   letfs = list(list(base = "eu", leverage = 2, finance = "rate", expense = 0.5),
                                list(base = "us", leverage = -1, finance = "rate", expense = 0.6)))
}

test_that("bootstrap_config validates and names products", {
  cfg <- make_cfg()
  expect_s3_class(cfg, "bootstrap_config")
  expect_equal(cfg$letf_names, c("eu_l2", "us_inv1"))
  expect_error(bootstrap_config(c("a")), "benannt")
  expect_error(bootstrap_config(c(a = "a"), letfs = list(list(base = "x"))), "nicht in indices")
  expect_error(bootstrap_config(c(a = "a"), letfs = list(list(base = "a", leverage = 0))), "nicht 0")
  expect_error(bootstrap_config(c(a = "a"), letfs = list(list(base = "a", finance = "rate"))), "nicht in aux")
})

test_that("all non-MS-GARCH methods produce valid paths with aux and products", {
  d <- make_boot_data(); cfg <- make_cfg()
  for (m in c("raw", "block", "circular", "stationary", "wild", "regime", "evt", "tails", "reset", "garch", "gjr_garch")) {
    b <- suppressWarnings(suppressMessages(bootstrap(d, cfg, m, n = 3, params = list(L = 20, block_length = 20),
                                                     seed = 1, progress = FALSE)))
    expect_s3_class(b, "bootstrap_result")
    P <- b$paths[[1]]
    expect_equal(dim(P), c(nrow(d) + 1L, 5L), info = m)
    expect_equal(colnames(P), c("us", "eu", "eu_l2", "us_inv1", "rate"), info = m)
    expect_true(all(P[1, 1:4] == 100), info = m)
    expect_true(all(is.finite(P)), info = m)
  }
})

test_that("row-resampling methods keep cross-sectional rows and carry aux by the same index", {
  d <- make_boot_data(); cfg <- make_cfg()
  b <- bootstrap(d, cfg, "stationary", n = 2, params = list(L = 30), seed = 3, progress = FALSE)
  P <- b$paths[[1]]
  r_us <- P[-1, "us"] / P[-nrow(P), "us"]; r_eu <- P[-1, "eu"] / P[-nrow(P), "eu"]
  rows <- match(round(r_us, 10), round(d$us, 10))
  expect_false(anyNA(rows))
  expect_equal(r_eu, d$eu[rows], tolerance = 1e-12)
  expect_equal(P[-1, "rate"], d$rate[rows])
})

test_that("leveraged products follow the MSCI formula including short interest", {
  d <- make_boot_data(); cfg <- make_cfg()
  P <- bootstrap(d, cfg, "raw", n = 1, seed = 2, progress = FALSE)$paths[[1]]
  re <- P[-1, "eu"] / P[-nrow(P), "eu"]; ru <- P[-1, "us"] / P[-nrow(P), "us"]; rt <- P[-1, "rate"]
  l2 <- 100 * cumprod(c(1, 1 + 2 * (re - 1) - rt / 100 / 360 - 0.5 / 100 / 365))
  s1 <- 100 * cumprod(c(1, 1 - (ru - 1) + 2 * rt / 100 / 360 - 0.6 / 100 / 365))
  expect_equal(P[, "eu_l2"], l2, tolerance = 1e-12)
  expect_equal(P[, "us_inv1"], s1, tolerance = 1e-12)
})

test_that("seeds give reproducible paths independent of cores and leave the global RNG alone", {
  d <- make_boot_data(); cfg <- make_cfg()
  b1 <- bootstrap(d, cfg, "block", n = 4, params = list(block_length = 50), seed = 11, progress = FALSE)
  b2 <- bootstrap(d, cfg, "block", n = 4, params = list(block_length = 50), seed = 11, progress = FALSE,
                  cores = if (.Platform$OS.type == "unix") 2L else 1L)
  expect_identical(b1$paths, b2$paths)
  set.seed(99); a <- runif(1)
  set.seed(99); invisible(bootstrap(d, cfg, "raw", n = 1, seed = 1, progress = FALSE)); b <- runif(1)
  expect_identical(a, b)
})

test_that("path_length allows paths longer than the history", {
  d <- make_boot_data(); cfg <- make_cfg()
  b <- bootstrap(d, cfg, "circular", n = 1, params = list(block_length = 100), path_length = 4000,
                 seed = 1, progress = FALSE)
  expect_equal(nrow(b$paths[[1]]), 4001L)
  expect_error(bootstrap(d, cfg, "wild", n = 1, path_length = 10, progress = FALSE), "Chronologie")
})

test_that("ESS design allocates budget and normalises weights", {
  d <- make_boot_data(); cfg <- make_cfg()
  b <- bootstrap(d, cfg, "stationary", n = 30, ess = TRUE, ess_grid = list(L = c(10, 100)),
                 seed = 1, progress = FALSE)
  expect_equal(sum(b$ess_design$n_sims), length(b$paths))
  expect_equal(mean(b$weights), 1)
  expect_gt(b$ess_design$n_sims[2], b$ess_design$n_sims[1])
})

test_that("block_length implements Politis-White and detects dependence", {
  set.seed(1)
  x_iid <- rnorm(3000)
  x_ar <- as.numeric(arima.sim(list(ar = 0.7), 3000))
  b_iid <- block_length(x_iid); b_ar <- block_length(x_ar)
  expect_equal(colnames(b_ar), c("stationary", "circular"))
  expect_lt(b_iid[1, "stationary"], 5)
  expect_gt(b_ar[1, "stationary"], 5)
  expect_equal(b_ar[1, "circular"] / b_ar[1, "stationary"], (3 / 2)^(1 / 3), tolerance = 1e-8)
})

test_that("GARCH bootstrap reproduces volatility and correlation of GARCH data", {
  set.seed(3); n <- 4000; om <- 2e-6; al <- 0.08; be <- 0.9; s2 <- om / (1 - al - be); e <- numeric(n)
  for (t in 1:n) { e[t] <- sqrt(s2) * rnorm(1); s2 <- om + al * e[t]^2 + be * s2 }
  d <- data.frame(us = 1 + 3e-4 + e); d$eu <- d$us * (1 + rnorm(n, 0, 0.004))
  b <- suppressMessages(bootstrap(d, bootstrap_config(c(us = "us", eu = "eu")), "garch", n = 20,
                                  seed = 1, progress = FALSE))
  sds <- vapply(b$paths, function(P) sd(diff(log(P[, "us"]))), 0)
  cors <- vapply(b$paths, function(P) cor(diff(log(P[, "us"])), diff(log(P[, "eu"]))), 0)
  expect_equal(median(sds), sd(log(d$us)), tolerance = 0.1)
  expect_equal(median(cors), cor(log(d$us), log(d$eu)), tolerance = 0.05)
})

test_that("bootstrap_study evaluates strategies on identical paths", {
  d <- make_boot_data(); cfg <- make_cfg()
  sig <- function(df, k = 50) { s <- stats::filter(df$eu, rep(1 / k, k), sides = 1); list(buy = df$eu >= s, sell = df$eu < s) }
  strats <- list(
    bnh = create_strategy(eu_l2 = asset_config("etf", "bnh", asset_bonus = 30)),
    sma = list(strategy = create_strategy(letf = asset_config("etf", "signal", asset_bonus = 30,
                                                              signal_buy = "buy", signal_sell = "sell")),
               signal = sig, map = c(letf = "eu_l2")))
  st <- bootstrap_study(d, cfg, "stationary", n = 4, strategies = strats, params = list(L = 50),
                        path_length = 700, burn_in = 60, sim_args = list(start_value = 1000),
                        benchmark = "bnh", seed = 5, chunk_size = 2, progress = FALSE)
  expect_s3_class(st, "SimLevBootstrapStudy")
  expect_equal(nrow(st$results), 8L)
  s <- summary(st)
  expect_true(all(c("distribution", "paired") %in% names(s)))
  pr <- bootstrap_probability(st, cagr > -1, joint = cagr > 0 & max_drawdown < 1)
  expect_equal(pr$probability[pr$condition == "cagr > -1"], c(1, 1))
  # gleicher Pfad wie bootstrap() mit gleichem Seed -> identisches Ergebnis
  b <- bootstrap(d, cfg, "stationary", n = 4, params = list(L = 50), path_length = 700, seed = 5, progress = FALSE)
  df <- bootstrap_data(b, 2); df <- df[61:nrow(df), ]
  r <- simulation(df, strats$bnh, start_value = 1000)
  expect_equal(st$results$cagr[st$results$strategy == "bnh" & st$results$path == 2], r$cagr)
})

test_that("bootstrap_study resumes from chunk files", {
  d <- make_boot_data(); cfg <- make_cfg()
  strats <- list(bnh = create_strategy(us = asset_config("etf", "bnh")))
  td <- tempfile()
  a <- bootstrap_study(d, cfg, "raw", n = 4, strategies = strats, path_length = 300, seed = 2,
                       chunk_size = 2, chunk_dir = td, progress = FALSE)
  expect_length(list.files(td), 2L)
  b <- bootstrap_study(d, cfg, "raw", n = 4, strategies = strats, path_length = 300, seed = 2,
                       chunk_size = 2, chunk_dir = td, progress = FALSE)
  expect_equal(a$results, b$results)
})

test_that("evt: GPD-Fit ueber die aus evd uebernommene Fassung (ohne evd)", {
  set.seed(5); us <- 1 + rnorm(400, 3e-4, 0.011)
  # 40 Ueberschreitungen: Maximum-Likelihood ueber .evd_fpot
  f <- SimLev:::.fit_tail(us, 0.1, "left")
  expect_equal(f$method, "MLE")
  exc <- f$thresh - us[f$pool]
  g <- SimLev:::.evd_fpot(exc, threshold = 0, std.err = FALSE)
  expect_s3_class(g, "pot")
  expect_identical(c(f$scale, f$shape), unname(g$estimate[c("scale", "shape")]))
  # 20 Ueberschreitungen: Momenten-Schaetzer wie bisher
  expect_equal(SimLev:::.fit_tail(us, 0.05, "left")$method, "Momente")
  # nicht uebernommene Wege von evd::fpot
  expect_error(SimLev:::.evd_fpot(exc, 0, model = "pp"), "nicht uebernommen")
  expect_error(SimLev:::.evd_fpot(exc, 0, cmax = TRUE), "nicht uebernommen")
  expect_error(SimLev:::.evd_fpot(exc, 0, mper = 10), "nicht uebernommen")
  expect_error(SimLev:::.evd_fpot(c(exc, Inf), 0, std.err = FALSE), "NA/NaN/Inf in foreign function call \\(arg 1\\)")
})
