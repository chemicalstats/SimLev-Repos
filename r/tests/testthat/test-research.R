# Tests fuer Signale, Parametersuche, Ueberanpassung, Datenaufbereitung
# und Abhaengigkeitsanalyse

make_px <- function(n = 365 * 10, seed = 1, mu = 3e-4, sd = 0.011) {
  set.seed(seed)
  d <- data.frame(date = seq.Date(as.Date("2008-01-01"), by = "day", length.out = n))
  d$A <- 100 * cumprod(1 + rnorm(n, mu, sd))
  d
}

test_that("signal building blocks", {
  x <- c(10, 11, 12, 13, 12, 11, 10, 9, 10, 11)
  s <- signal_sma(x, 3)
  sma <- c(NA, NA, 11, 12, 12.333333, 12, 11, 10, 9.666667, 10)
  expect_equal(s$buy, c(FALSE, FALSE, x[3:10] >= sma[3:10]))
  expect_equal(s$sell, c(FALSE, FALSE, x[3:10] < sma[3:10]))
  sb <- signal_sma(x, 3, band = 5)
  expect_true(all(!(sb$buy & sb$sell)))
  expect_true(sum(sb$buy | sb$sell) < sum(s$buy | s$sell))
  sl <- signal_sma(x, 3, lag = 1)
  expect_equal(sl$buy, c(FALSE, s$buy[-10]))
  m <- signal_momentum(x, 2)
  expect_equal(m$buy[3], x[3] / x[1] - 1 >= 0)
  dd <- signal_drawdown(c(100, 89, 79, 85, 95), sell_dd = 20, buy_dd = 10)
  expect_equal(dd$sell, c(FALSE, FALSE, TRUE, FALSE, FALSE))
  expect_equal(dd$buy, c(TRUE, FALSE, FALSE, FALSE, TRUE))
  cb <- signal_combine(list(buy = c(TRUE, TRUE), sell = c(FALSE, FALSE)), list(buy = c(TRUE, FALSE), sell = c(FALSE, TRUE)))
  expect_equal(cb, list(buy = c(TRUE, FALSE), sell = c(FALSE, TRUE)))
  e <- signal_ema(cumsum(rep(1, 50)), 10)
  expect_true(all(e$buy[10:50]))
  v <- signal_volatility(100 * cumprod(1 + rnorm(300, 0, 0.01)), 20, threshold = 1000)
  expect_true(all(v$buy[25:300]))
})

test_that("param_space designs: grid, constraint, random and LHS", {
  sp <- param_space(a = param_range(1, 5, n = 5, integer = TRUE), b = c("x", "y"))
  D <- SimLev:::.ps_design(sp, "grid", 0, NULL)
  expect_equal(nrow(D), 10L)
  D2 <- SimLev:::.ps_design(sp, "grid", 0, function(p) p$a + (p$b == "y") <= 4)
  expect_true(all(D2$a + (D2$b == "y") <= 4))
  sp2 <- param_space(w = param_range(0, 1), n = param_range(10, 1000, log = TRUE, integer = TRUE))
  set.seed(3); L <- SimLev:::.ps_design(sp2, "lhs", 20, NULL)
  expect_equal(nrow(L), 20L)
  expect_equal(sort(floor(L$w * 20)), 0:19)          # eine Ziehung je Schicht
  expect_true(all(L$n >= 10 & L$n <= 1000 & L$n == round(L$n)))
  ps <- param_range(50, 400, n = 4, log = TRUE)
  expect_equal(SimLev:::.ps_levels(ps), exp(seq(log(50), log(400), length.out = 4)))
  expect_output(print(sp), "Parameterraum")
})

test_that("param_search reproduces simulation(), keeps returns and supports overfitting checks", {
  d <- make_px(365 * 12)
  st <- create_strategy(A = asset_config("etf", "signal", signal_buy = "buy", signal_sell = "sell", asset_spread = 0))
  b <- function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, p$band))
  ps <- param_search(d, b, param_space(n = c(50, 100, 200), band = c(0, 2)), burn_in = 250)
  expect_s3_class(ps, "SimLevParamSearch")
  expect_equal(nrow(ps$results), 6L)
  expect_equal(dim(ps$returns), c(nrow(d) - 251L, 6L))
  # Punkt 4 (n = 100, band = 2) direkt nachrechnen
  dd <- d; sg <- signal_sma(dd$A, 100, 2); dd$buy <- sg$buy; dd$sell <- sg$sell
  r <- suppressMessages(simulation(dd[251:nrow(dd), ], st))
  row <- ps$results[ps$results$n == 100 & ps$results$band == 2, ]
  expect_equal(row$cagr, r$cagr, tolerance = 1e-12)
  ix <- result_index(r)$value
  expect_equal(ps$returns[, row$id], ix[-1] / ix[-length(ix)] - 1, tolerance = 1e-12)
  # ohne builder: simulation()-Argumente
  st2 <- create_strategy(A = asset_config("etf", "bnh", 0.5), B = asset_config("etf", "bnh", 0.5))
  d$B <- 100 * cumprod(1 + rnorm(nrow(d), 1e-4, 0.004))
  ps2 <- param_search(d, space = param_space(balance_thresh = c(2, 5, 10)), strategy = st2,
                      sim_args = list(balance_mode = TRUE, balance_span = 1, balance_unit = "month"))
  r2 <- simulation(d, st2, balance_mode = TRUE, balance_span = 1, balance_unit = "month", balance_thresh = 5)
  expect_equal(ps2$results$cagr[2], r2$cagr)
  # Fehler werden je Punkt protokolliert
  bad <- param_search(d, function(p) if (p$n > 60) stop("kaputt") else b(p), param_space(n = c(50, 100), band = 0), burn_in = 250)
  expect_true(is.na(bad$results$error[1]) && grepl("kaputt", bad$results$error[2]))
  # Plateau
  pl <- plateau(ps)
  expect_equal(pl$neighbours, c(4, 6, 4, 4, 6, 4))
  expect_equal(pl$plateau_mean[1], mean(ps$results$sharpe[c(1, 2, 4, 5)]))
  expect_output(print(ps), "Bestes Plateau")
  pdf(NULL); on.exit(dev.off(), add = TRUE)
  expect_silent(plot(ps)); expect_silent(plot(ps, params = "n"))
  # Ueberanpassung
  pb <- pbo(ps, S = 8)
  expect_s3_class(pb, "SimLevPBO"); expect_equal(pb$n_combos, choose(8, 4))
  expect_true(pb$pbo >= 0 && pb$pbo <= 1)
  ds <- deflated_sharpe(ps)
  expect_true(ds$n_eff >= 1 && ds$n_eff <= 6)
  expect_true(ds$dsr <= ds$psr + 1e-12)
  wf <- walk_forward(ps, train = 4, test = 2)
  expect_s3_class(wf, "SimLevWalkForward")
  W <- wf$windows
  expect_true(all(W$test_start[-1] > W$test_end[-nrow(W)]))
  rows <- which(ps$dates >= W$test_start[1] & ps$dates <= W$test_end[1])
  expect_equal(wf$series$walk_forward[length(rows)], prod(1 + ps$returns[rows, W$id[1]]), tolerance = 1e-10)
  expect_output(print(wf), "Walk-Forward")
  expect_silent(plot(pb)); expect_silent(plot(wf))
  expect_output(print(ds), "Deflated")
})

test_that("pbo matches brute force; DSR and PSR behave", {
  set.seed(5); R <- matrix(rnorm(400 * 7, 1e-4, 0.01), 400)
  S <- 6; bl <- 400 %/% S; R2 <- R[(400 - bl * S + 1):400, ]; blk <- rep(1:S, each = bl)
  cb <- combn(S, S / 2); lam <- numeric(ncol(cb))
  sh <- function(M) apply(M, 2, function(r) mean(r) / sd(r))
  for (c in seq_len(ncol(cb))) { is <- blk %in% cb[, c]; a <- sh(R2[is, ]); b <- sh(R2[!is, ])
    w <- rank(b)[which.max(a)] / (ncol(R) + 1); lam[c] <- log(w / (1 - w)) }
  expect_equal(pbo(R, S = S, frequency = "day")$lambda, lam)
  R[, 1] <- R[, 1] + 0.003
  expect_lt(pbo(R, S = S, frequency = "day")$pbo, 0.05)
  expect_gt(deflated_sharpe(R, frequency = "day")$dsr, 0.95)
  expect_gt(probabilistic_sharpe(rnorm(1000, 0.01, 0.02), 0, 52), 0.99)
  expect_lt(probabilistic_sharpe(rnorm(1000, 0, 0.02), 1, 52), 0.05)
})

test_that("param_bootstrap evaluates the best points on bootstrap paths", {
  set.seed(2); n <- 1500
  h <- data.frame(us = 1 + rnorm(n, 3e-4, 0.01))
  cfg <- bootstrap_config(c(us = "us"))
  d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n + 1), us = 100 * cumprod(c(1, h$us)))
  st <- create_strategy(us = asset_config("etf", "signal", signal_buy = "buy", signal_sell = "sell"))
  ps <- param_search(d, function(p) list(strategy = st, signal = function(df) signal_sma(df$us, p$n)),
                     param_space(n = c(20, 50, 100)), burn_in = 100)
  bs <- param_bootstrap(ps, h, cfg, top = 2, method = "stationary", n = 3, params = list(L = 50), seed = 1, progress = FALSE)
  expect_s3_class(bs, "SimLevBootstrapStudy")
  expect_equal(length(attr(bs, "param_ids")), 2L)
  expect_true(all(names(attr(bs, "param_ids")) %in% bs$results$strategy))
})

test_that("align_series, check_series and align_macro", {
  a <- data.frame(date = as.Date("2024-01-01") + c(0, 1, 2, 5, 30), value = c(100, 101, 102, 103, 110))
  b <- data.frame(date = as.Date("2024-01-02") + 0:40, close = 50 + 0:40)
  x <- align_series(us = a, eu = b)
  expect_equal(x$date[1], as.Date("2024-01-02")); expect_equal(x$date[nrow(x)], as.Date("2024-01-31"))
  expect_equal(x$us[1:6], c(101, 102, 102, 102, 103, 103))
  expect_equal(unname(attr(x, "filled")[1:4, "us"]), c(FALSE, FALSE, TRUE, TRUE))
  expect_true(all(is.na(suppressMessages(align_series(us = a, eu = b, max_gap = 10))$us[6:29])))
  xi <- align_series(us = a, eu = b, calendar = "intersect", range = "all")
  expect_equal(xi$date, as.Date(c("2024-01-02", "2024-01-03", "2024-01-06", "2024-01-31")))
  expect_error(align_series(a, b), "benennen")
  set.seed(1); n <- 600
  p <- 100 * cumprod(1 + rnorm(n, 0, 0.01)); p[300:n] <- p[300:n] / 2; p[400] <- p[400] * 1.6; p[500:515] <- p[500]
  ck <- check_series(data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n), A = p))
  expect_equal(ck$summary$splits, 1L); expect_equal(ck$summary$spikes, 1L); expect_equal(ck$summary$stale_max, 16L)
  expect_equal(ck$summary$jumps, 2L)
  expect_output(print(ck), "Datenpruefung")
  cpi <- data.frame(date = seq.Date(as.Date("2019-01-01"), by = "month", length.out = 36), value = 100 * 1.003^(0:35))
  d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 120))
  y <- align_macro(d, cpi, "infl", lag = 45, transform = "yoy")$infl
  expect_true(all(is.na(y[d$date < as.Date("2020-02-15")])))
  expect_equal(y[d$date == as.Date("2020-02-15")], 100 * (1.003^12 - 1))
  m <- align_macro(d$date, cpi, lag = 1, lag_unit = "month")
  expect_equal(m[1], 100 * 1.003^11); expect_equal(m[d$date == as.Date("2020-02-01")], 100 * 1.003^12)
  expect_equal(align_macro(d$date, cpi, transform = "diff")[40], 100 * (1.003^13 - 1.003^12))
})

test_that("currency, total return, deflation, splicing and portfolios", {
  d <- data.frame(date = as.Date("2024-01-01") + 0:3, A = c(110, 121, 132, 143), fx = c(1.1, 1.1, 1.2, 1.3))
  expect_equal(convert_currency(d, "A", "fx")$A, c(100, 110, 110, 110))
  expect_equal(convert_currency(d, "A", 2, "multiply", "_x")$A_x, 2 * d$A)
  expect_equal(total_return_index(c(100, 100, 98, 99), dividends = c(0, 0, 2, 0), withholding = 15),
               100 * cumprod(c(1, 1, 99.7 / 100, 99 / 98)))
  tri <- total_return_index(rep(100, 366), yield = 2, dates = seq.Date(as.Date("2021-01-01"), by = "day", length.out = 366))
  expect_equal(tri[366], 100 * (1 + 0.02 / 365.25)^365, tolerance = 1e-10)
  dd <- deflate(data.frame(date = d$date, A = d$A, cpi = c(100, 110, 121, 130)), "A", "cpi")
  expect_equal(dd$A_real, d$A / c(100, 110, 121, 130) * 100)
  f1 <- data.frame(date = as.Date("2024-03-01") + 0:5, value = c(10, 11, 12, 12.5, 13, 14))
  f2 <- data.frame(date = as.Date("2024-02-20") + 0:20, value = 200 + 0:20)
  sp <- splice_series(fund = f1, proxy = f2)
  expect_equal(sp$value[sp$source %in% "fund"], f1$value)
  pre <- sp$date < as.Date("2024-03-01")
  expect_equal(sp$value[pre] / 10, (200 + 0:9) / 210)
  expect_equal(sp$value[nrow(sp)] / 14, 220 / 215)
  st <- strategy_from_weights(c(w = 0.6, b = 0.4), asset_spread = c(w = 0.1, b = 0.05), asset_class = "etf")
  expect_equal(c(st$w$asset_share, st$b$asset_share, st$b$asset_spread), c(0.6, 0.4, 0.05))
  expect_error(strategy_from_weights(c(a = 0.7, b = 0.5)), "summieren")
  pt <- portfolio_template("permanent", map = c(stocks = "W"))
  expect_equal(names(pt), c("W", "long_bonds", "cash", "gold"))
  expect_true(all(abs(tapply(portfolio_templates()$weight, portfolio_templates()$template, sum) - 1) < 1e-12))
})

test_that("copula densities, fits and tail dependence", {
  g <- (1:120 - 0.5) / 120; U <- expand.grid(u = g, v = g)
  for (f in list(list("gaussian", c(.5, NA)), list("t", c(-.4, 5)), list("clayton", 2), list("gumbel", 1.8),
                 list("frank", -4), list("clayton_270", 1.5), list("gumbel_180", 2)))
    expect_equal(mean(exp(vapply(seq_len(nrow(U)), function(i) SimLev:::.cop_ll(f[[1]], f[[2]], U$u[i], U$v[i]), 0))),
                 1, tolerance = 0.01)
  set.seed(1); n <- 3000
  z <- matrix(rnorm(2 * n), ncol = 2) %*% chol(matrix(c(1, .6, .6, 1), 2)); w <- sqrt(rchisq(n, 4) / 4)
  fc <- fit_copula(z[, 1] / w, z[, 2] / w)
  expect_equal(fc$family[1], "t"); expect_equal(fc$par1[1], 0.6, tolerance = 0.05); expect_equal(fc$par2[1], 4, tolerance = 0.3)
  th <- 3; u <- runif(n); t <- runif(n); v <- ((t^(-th / (1 + th)) - 1) * u^(-th) + 1)^(-1 / th)
  fcl <- fit_copula(qnorm(u), qnorm(v))
  expect_equal(fcl$family[1], "clayton"); expect_equal(fcl$par1[1], 3, tolerance = 0.1)
  expect_equal(fcl$lambda_lower[1], 2^(-1 / fcl$par1[1]))
  fn <- fit_copula(z[, 1], -z[, 2])
  expect_true(all(c("clayton_90", "gumbel_270") %in% fn$family)); expect_lt(fn$par1[fn$family == "gaussian"], 0)
  ind <- tail_dependence(rnorm(20000), rnorm(20000), c(0.05, 0.2))
  expect_equal(ind$lower, c(0.05, 0.2), tolerance = 0.15)
})

test_that("quantile regression, DCC and dependence analysis with third variables", {
  set.seed(2); x <- rnorm(600); y <- 1 + 2 * x + rnorm(600) * (1 + abs(x))
  qr0 <- quantile_reg(y, NULL, 0.3)
  ys <- sort(y); chk <- function(b) sum((y - b) * (0.3 - (y < b)))
  expect_true(qr0 >= ys[180] - 1e-6 && qr0 <= ys[181] + 1e-6)          # Loesungsmenge [y(180), y(181)]
  expect_equal(chk(qr0), chk(ys[180]), tolerance = 1e-8)
  # exakte Loesung: Die LP-Loesung interpoliert zwei Beobachtungen -> alle Paare pruefen
  xs <- x[1:40]; ysm <- y[1:40]; loss <- function(b) sum((ysm - b[1] - b[2] * xs) * (0.9 - (ysm < b[1] + b[2] * xs)))
  pr <- combn(40, 2); best <- Inf
  for (j in seq_len(ncol(pr))) { i1 <- pr[1, j]; i2 <- pr[2, j]
    b2 <- (ysm[i2] - ysm[i1]) / (xs[i2] - xs[i1]); best <- min(best, loss(c(ysm[i1] - b2 * xs[i1], b2))) }
  expect_equal(loss(quantile_reg(ysm, xs, 0.9)), best, tolerance = 1e-7)
  n <- 365 * 16
  d <- data.frame(date = seq.Date(as.Date("2000-01-01"), by = "day", length.out = n))
  infl <- rep(rep(c(1, 5), each = 365), length.out = n)
  e1 <- rnorm(n); e2 <- rnorm(n); rho <- ifelse(infl > 3, 0.6, -0.4)
  d$stocks <- 100 * exp(cumsum(0.01 * e1)); d$bonds <- 100 * exp(cumsum(0.005 * (rho * e1 + sqrt(1 - rho^2) * e2)))
  d$inflation <- infl
  da <- dependence_analysis(d, c("stocks", "bonds"), conditions = "inflation", breaks = list(inflation = c(-Inf, 3, Inf)),
                            B = 99, seed = 1)
  expect_s3_class(da, "SimLevDependence")
  ct <- da$conditional$inflation
  expect_lt(ct$pearson[1], -0.2); expect_gt(ct$pearson[2], 0.4)
  expect_lt(da$differences$p_pearson, 0.05)
  expect_true(da$dcc$a > 0 && da$dcc$b > 0 && da$dcc$a + da$dcc$b < 1)
  expect_equal(nrow(da$dcc$correlation), nrow(da$returns))
  expect_output(print(da), "Bedingt auf")
  pdf(NULL); on.exit(dev.off(), add = TRUE)
  expect_silent(plot(da)); expect_silent(plot(da, "scatter"))
  # verzoegerter Zustand: Rendite der Periode t gehoert zum Zustand am Ende von t-1
  rr <- SimLev:::.dep_returns(d, "stocks", "inflation", "week")
  key <- format(d$date, "%G-%V"); ends <- which(c(key[-1] != key[-length(key)], TRUE))
  expect_equal(rr$inflation[10], d$inflation[ends[10]])
  tr <- tail_regression(d, "bonds", "inflation", quantiles = c(0.1, 0.5, 0.9), B = 19, seed = 1)
  expect_equal(nrow(tr$coefficients), 6L); expect_output(print(tr), "Quantilsregression")
  d$port <- 0.6 * d$stocks / d$stocks[1] + 0.4 * d$bonds / d$bonds[1]
  cv <- covar_analysis(d, "port", c("stocks", "bonds"))
  expect_true(all(cv$summary$delta_covar < 0)); expect_output(print(cv), "CoVaR")
  expect_silent(plot(tr)); expect_silent(plot(cv))
})

test_that("validate_dependence and regime_subset", {
  set.seed(4); n <- 2000
  e <- matrix(rnorm(2 * n), ncol = 2) %*% chol(matrix(c(1, .5, .5, 1), 2))
  h <- data.frame(us = exp(0.01 * e[, 1]), eu = exp(0.01 * e[, 2]), infl = rep(c(1, 5, 1), c(700, 600, 700)))
  cfg <- bootstrap_config(c(us = "us", eu = "eu"))
  b <- bootstrap(h, cfg, "stationary", n = 10, params = list(L = 20), seed = 1, progress = FALSE)
  vd <- validate_dependence(b, h, agg = 5, max_paths = 10)
  expect_equal(nrow(vd), 5L); expect_true(all(vd$percentile >= 0 & vd$percentile <= 1))
  s <- regime_subset(h, "infl >= 4", min_run = 50)
  expect_equal(nrow(s), 600L); expect_equal(attr(s, "episodes")$start, 701L)
  bs <- bootstrap(s, cfg, "stationary", n = 2, params = list(L = 20), seed = 1, progress = FALSE)
  expect_equal(nrow(bs$paths[[1]]), 601L)
  expect_error(regime_subset(h, "infl > 10"), "keine Episode")
})
