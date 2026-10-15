# Tests fuer backcast_fit() / backcast()

make_bc_data <- function(n = 4000, drag = 0.4, lev = 2, seed = 1, weekends = TRUE) {
  set.seed(seed)
  d <- seq.Date(as.Date("2005-01-01"), by = "day", length.out = n)
  idx <- 100 * cumprod(1 + c(0, rnorm(n - 1, 3e-4, 0.01)))
  rate <- 2 + sin(seq_len(n) / 400)
  ter <- ifelse(d >= as.Date("2012-01-01"), 0.6, 0.35)
  x <- c(0, diff(idx) / head(idx, -1))
  r <- lev * x + (1 - lev) * rate / 100 / 360 - ter / 100 / 365 - drag / 100 / 365
  r[1] <- 0
  truth <- 50 * cumprod(1 + r)
  etf <- truth
  etf[seq_len(n / 2)] <- NA
  if (weekends) etf[as.POSIXlt(d)$wday %in% c(0, 6)] <- NA
  list(df = data.frame(date = d, etf = etf, idx = idx, rate = rate), truth = truth,
       ter = c("2005-01-01" = 0.35, "2012-01-01" = 0.6))
}

test_that("backcast_fit recovers the drag of a leveraged product", {
  s <- make_bc_data()
  f <- backcast_fit(s$df, "etf", "idx", ter = s$ter, leverage = 2, rate = "rate")
  expect_s3_class(f, "SimLevBackcastFit")
  expect_equal(f$params$drag, 0.4, tolerance = 1e-4)
  expect_lt(f$diagnostics$rmse_level, 1e-6)
  expect_false(is.null(f$validation))
  expect_lt(abs(f$validation$test_tracking_difference), 1e-4)
})

test_that("backcast reproduces the true history before inception and keeps real prices", {
  s <- make_bc_data()
  f <- backcast_fit(s$df, "etf", "idx", ter = s$ter, leverage = 2, rate = "rate")
  bc <- backcast(f)
  k0 <- min(which(!is.na(s$df$etf)))
  truth <- s$truth / s$truth[k0] * s$df$etf[k0]
  pre <- seq_len(k0)
  expect_lt(max(abs(bc$value[pre] / truth[pre] - 1)), 1e-8)
  ob <- !is.na(s$df$etf)
  expect_equal(bc$value[ob], s$df$etf[ob], tolerance = 1e-12)
  expect_true(all(bc$source[pre[-k0]] == "backcast"))
  expect_equal(attr(bc, "splice_date"), s$df$date[k0])
})

test_that("grid search, hybrid objective and multi-parameter fits work", {
  s <- make_bc_data()
  fg <- backcast_fit(s$df, "etf", "idx", ter = s$ter, leverage = 2, rate = "rate",
                     method = "grid", grid = seq(-1, 1, by = 0.01))
  expect_equal(fg$params$drag, 0.4, tolerance = 1e-8)
  expect_true(all(abs(fg$grid_metrics - 0.4) < 1e-8))
  fb <- backcast_fit(s$df, "etf", "idx", ter = s$ter, leverage = 2, rate = "rate",
                     fit = c("drag", "beta"), objective = "hybrid")
  expect_equal(fb$params$beta, 1, tolerance = 1e-3)
  expect_equal(fb$params$drag, 0.4, tolerance = 0.05)
})

test_that("TER specifications are interpreted consistently", {
  d <- data.frame(date = as.Date("2020-01-01") + 0:9, ter = rep(0.5, 10))
  expect_equal(SimLev:::.resolve_series(0.3, d, "ter"), rep(0.3, 10))
  expect_equal(SimLev:::.resolve_series("ter", d, "ter"), rep(0.5, 10))
  step <- SimLev:::.resolve_series(c("2020-01-01" = 0.2, "2020-01-05" = 0.4), d, "ter")
  expect_equal(step, c(rep(0.2, 4), rep(0.4, 6)))
  step2 <- SimLev:::.resolve_series(data.frame(date = as.Date(c("2020-01-03")), ter = 0.7), d, "ter")
  expect_equal(step2, rep(0.7, 10))
  expect_error(SimLev:::.resolve_series("nope", d, "ter"), "fehlt")
})

test_that("unleveraged product with linear regression model", {
  s <- make_bc_data(lev = 1, drag = 0.1, weekends = FALSE)
  f <- backcast_fit(s$df, "etf", "idx", ter = 0.2, model = "linear")
  expect_equal(f$model, "linear")
  expect_gt(f$diagnostics$correlation, 0.999)
  bc <- backcast(f, rebase = 100)
  expect_equal(bc$value[1], 100)
})

test_that("backcast without fit uses fixed parameters and fill = 'model' keeps observed prices", {
  s <- make_bc_data()
  bc <- backcast(NULL, data = s$df, product = "etf", index = "idx", ter = s$ter,
                 leverage = 2, rate = "rate", params = list(drag = 0.4), fill = "model")
  ob <- !is.na(s$df$etf)
  expect_equal(bc$value[ob], s$df$etf[ob], tolerance = 1e-12)
  expect_true(any(bc$source == "filled"))
})

test_that("input validation", {
  s <- make_bc_data()
  expect_error(backcast_fit(s$df, "etf", "missing"), "fehlt")
  expect_error(backcast_fit(s$df, "etf", "idx", leverage = 0), "ungleich 0")
  df2 <- s$df; df2$etf <- NA
  expect_error(backcast_fit(df2, "etf", "idx"), "Zu wenige")
  expect_warning(backcast_fit(s$df, "etf", "idx", ter = 0.5, fit = c("drag", "spread")), "nicht identifizierbar")
})
