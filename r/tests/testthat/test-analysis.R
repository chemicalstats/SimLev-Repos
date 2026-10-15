# Tests fuer deep_analysis(), Sensitivitaeten und relative Rebalancing-Baender

make_two <- function(n = 365 * 8, seed = 1) {
  set.seed(seed)
  d <- data.frame(date = seq.Date(as.Date("2012-01-01"), by = "day", length.out = n))
  d$A <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.010))
  d$B <- 100 * cumprod(1 + rnorm(n, 1.5e-4, 0.004))
  d
}

test_that("deep_analysis reproduces engine metrics and core identities", {
  d <- make_two()
  a <- simulation(d, create_strategy(A = asset_config("etf", "bnh", asset_spread = 0)))
  b <- simulation(d, create_strategy(A = asset_config("etf", "bnh", 0.6), B = asset_config("etf", "bnh", 0.4)),
                  balance_mode = TRUE, balance_span = 1, balance_unit = "year",
                  dca_mode = TRUE, dca_value = 300, dca_span = 1)
  da <- deep_analysis(list(A = a, Mix = b), benchmark = "A")
  expect_s3_class(da, "SimLevAnalysis")
  expect_equal(unname(da$metrics["cagr", "A"]), a$ttwror, tolerance = 1e-10)
  expect_equal(unname(da$metrics["cagr", "Mix"]), b$ttwror, tolerance = 1e-10)
  expect_equal(unname(da$metrics["max_drawdown", "A"]), a$statistics$max_drawdown, tolerance = 1e-10)
  expect_equal(unname(da$metrics["mwrr", "A"]), unname(da$metrics["cagr", "A"]), tolerance = 1e-6)  # ohne Flows
  expect_false(isTRUE(all.equal(unname(da$metrics["mwrr", "Mix"]), unname(da$metrics["cagr", "Mix"]))))
  # Benchmark gegen sich selbst
  self <- deep_analysis(list(A = a, A2 = a), benchmark = "A")
  bm <- self$benchmark_metrics[, "A2"]
  expect_equal(unname(bm[c("beta", "correlation", "up_capture", "down_capture")]), c(1, 1, 1, 1), tolerance = 1e-10)
  expect_equal(unname(bm[c("alpha", "tracking_error", "active_return")]), c(0, 0, 0), tolerance = 1e-10)
  # Jahresrenditen verketten sich zur Gesamtrendite
  expect_equal(prod(1 + da$annual[, "A"]) - 1, unname(da$metrics["total_return", "A"]), tolerance = 1e-10)
  expect_equal(dim(da$monthly$A)[2], 13L)
  expect_true(all(da$drawdowns$A$depth <= 0))
  expect_equal(-min(da$drawdowns$A$depth), unname(da$metrics["max_drawdown", "A"]), tolerance = 1e-10)
  expect_false(is.null(da$rolling$Mix))
  expect_output(print(da), "SimLev Detailanalyse")
  pdf(NULL); on.exit(dev.off(), add = TRUE)
  for (t in c("overview", "growth", "drawdown", "rolling", "annual", "monthly")) expect_silent(plot(da, t))
})

test_that("deep_analysis accepts data.frames and external benchmarks; VaR/CVaR are ordered", {
  d <- make_two()
  a <- simulation(d, create_strategy(A = asset_config("etf", "bnh")))
  da <- deep_analysis(a, benchmark = data.frame(date = d$date, value = d$B), risk_free = 2)
  expect_true("Benchmark" %in% colnames(da$metrics))
  m <- da$metrics[, "Strategie"]
  expect_true(m["cvar_daily_5"] >= m["var_daily_5"])
  expect_true(m["var_daily_1"] >= m["var_daily_5"])
  expect_error(deep_analysis(list(1)), "SimLevResult")
})

test_that("relative rebalancing bands work and default stays absolute", {
  d <- make_two()
  st <- create_strategy(A = asset_config("etf", "bnh", 0.6), B = asset_config("etf", "bnh", 0.4))
  base <- simulation(d, st, balance_mode = TRUE, balance_span = 1, balance_unit = "month", balance_thresh = 5)
  abs_ <- simulation(d, st, balance_mode = TRUE, balance_span = 1, balance_unit = "month", balance_thresh = 5,
                     balance_thresh_type = "absolute")
  expect_identical(base$worth, abs_$worth)
  # relativ 5 % von 40 % = 2 Prozentpunkte -> haeufiger als absolut 5 Punkte
  rel <- simulation(d, st, balance_mode = TRUE, balance_span = 1, balance_unit = "month", balance_thresh = 5,
                    balance_thresh_type = "relative")
  expect_gt(sum(rel$sells), sum(abs_$sells))
  # relativ 12.5 % bei Zielen 40/60 entspricht absolut 5 Punkten fuer B (40 %) - B ist bindend
  rel2 <- simulation(d, st, balance_mode = TRUE, balance_span = 1, balance_unit = "month", balance_thresh = 12.5,
                     balance_thresh_type = "relative")
  expect_identical(rel2$worth, abs_$worth)
})

test_that("sensitivity_grid, rebalancing_sensitivity, leverage and lump sum studies", {
  d <- make_two(n = 365 * 6)
  st <- create_strategy(A = asset_config("etf", "bnh", 0.6), B = asset_config("etf", "bnh", 0.4))
  g <- sensitivity_grid(d, st, list(balance_unit = c("month", "year"), balance_thresh = c(NA, 5)),
                        sim_args = list(balance_mode = TRUE, balance_span = 1))
  expect_equal(nrow(g), 4L); expect_false(anyNA(g$cagr))
  r1 <- simulation(d, st, balance_mode = TRUE, balance_span = 1, balance_unit = "year", balance_thresh = 5)
  expect_equal(g$cagr[g$balance_unit == "year" & g$balance_thresh %in% 5], r1$cagr)
  rs <- rebalancing_sensitivity(d, st, frequencies = list(q = c("quarter", 1), y = c("year", 1)),
                                offsets = c(0, 5), bands = c(NA, 10), band_type = "relative")
  expect_s3_class(rs, "SimLevSensitivity")
  expect_equal(nrow(rs), 2 * 2 * 2 + 1)
  lv <- leverage_sensitivity(d, "A", leverages = c(1, 2), rate = 2, expense = 0.5)
  expect_equal(nrow(lv), 2L)
  ser <- leveraged_series(d, "A", leverage = 1)
  expect_equal(ser / ser[1], d$A / d$A[1], tolerance = 1e-12)
  s2 <- leveraged_series(d, "A", leverage = 2, rate = 3, expense = 0.5)
  x <- d$A[2] / d$A[1] - 1
  expect_equal(s2[2] / s2[1] - 1, 2 * x - 3 / 100 / 360 - 0.5 / 100 / 365, tolerance = 1e-12)
  ls <- lumpsum_vs_dca(d, create_strategy(A = asset_config("etf", "bnh", asset_spread = 0)),
                       months = 6, horizon = 3, step = 6)
  expect_s3_class(ls, "SimLevLumpSum")
  expect_true(all(ls$lump_sum > 0 & ls$dca > 0))
  expect_true(attr(ls, "summary")["win_rate"] >= 0 && attr(ls, "summary")["win_rate"] <= 1)
  # ohne Kosten: DCA-Rate in einem Schritt (months = 1) == Einmalanlage
  ls1 <- lumpsum_vs_dca(d, create_strategy(A = asset_config("etf", "bnh", asset_spread = 0)),
                        months = 1, horizon = 2, step = 12)
  expect_equal(ls1$lump_sum, ls1$dca, tolerance = 1e-8)
})
