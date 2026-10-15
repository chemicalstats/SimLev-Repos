# Blue Team Runde 2 (Engine): Befunde R2-01 bis R2-07 und kleinere Beobachtungen

mk_day <- function(n, f) data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n), A = f(n))

test_that("R2-01: Startkapital am ersten Tag mit order_fee, Sparrate mit dca_fee", {
  set.seed(1); d <- mk_day(400, function(n) 100 * cumprod(1 + rnorm(n, 4e-4, 0.01)))
  st <- create_strategy(A = asset_config("etf", asset_share = 1, asset_spread = 0))
  fee <- list(percent = 0.25); exp_fee <- 0.0025 * 50000 / 1.0025
  a <- simulation(d, st, start_value = 50000, order_fee = fee, dca_fee = 0, dca_mode = TRUE, dca_value = 100, dca_span = 1)
  b <- simulation(d, st, start_value = 50000, order_fee = fee, dca_fee = 0, dca_mode = TRUE, dca_value = 100, dca_span = 1, dca_days = 2)
  expect_equal(a$fees_paid, exp_fee, tolerance = 1e-9)        # vorher ~0 (Startkapital mit dca_fee)
  expect_equal(b$fees_paid, exp_fee, tolerance = 1e-9)
  # Rebalancing-Pfad am ersten Tag (balance_mode): ebenso
  d$B <- 50 * cumprod(1 + rnorm(nrow(d), 1e-4, 0.005))
  st2 <- create_strategy(A = asset_config("etf", asset_share = .6, asset_spread = 0), B = asset_config("etf", asset_share = .4, asset_spread = 0))
  c2 <- simulation(d, st2, start_value = 50000, order_fee = fee, dca_fee = 0, balance_mode = TRUE, balance_span = 12,
                   dca_mode = TRUE, dca_value = 100, dca_span = 1)
  expect_gte(c2$fees_paid, exp_fee - 1e-6)
  # Sparrate selbst mit dca_fee: Kosten der Sparraten nur bei dca_fee > 0
  e <- simulation(d, st, start_value = 50000, order_fee = fee, dca_fee = 1, dca_mode = TRUE, dca_value = 100, dca_span = 1)
  expect_equal(e$fees_paid, exp_fee + sum(e$report$A$flows > 0), tolerance = 1e-9)
})

test_that("R2-02: split_thresh ohne 100 dazwischen -> Warnung, kein Fehler", {
  set.seed(5); d <- mk_day(400, function(n) 40 * exp(cumsum(rnorm(n, 8e-4, 0.01))))
  st <- create_strategy(A = asset_config("etf", asset_share = 1, asset_spread = 0))
  expect_warning(simulation(d, st, split_mode = TRUE, split_thresh = c(10, 60)), "schlie\u00dft den Zielkurs 100 nicht ein")
  expect_warning(simulation(d, st, split_mode = TRUE, split_thresh = c(150, 400)), "untere < 100 < obere")
  expect_no_warning(simulation(d, st, split_mode = TRUE, split_thresh = c(50, 200)))
  expect_no_warning(simulation(d, st, split_mode = FALSE, split_thresh = c(10, 60)))
  expect_error(suppressWarnings(simulation(d, st, split_mode = TRUE, split_thresh = c(10, 60, 200))), "L\u00e4nge 2")
})

test_that("R2-03: Attribut 'filled' mit falscher Zeilenzahl -> Warnung", {
  set.seed(7)
  cal <- seq.Date(as.Date("2019-01-01"), as.Date("2020-12-31"), by = "day"); wd <- cal[!format(cal, "%u") %in% c("6", "7")]
  us <- data.frame(date = wd, A = 100 * exp(cumsum(rnorm(length(wd), 4e-4, 0.011))))
  st <- create_strategy(A = asset_config("etf", asset_share = 1))
  al <- align_series(A = us)
  al2 <- al[al$date >= as.Date("2020-01-01"), ]
  expect_warning(r <- simulation(al2, st), "Attribut 'filled'.*ignoriert")
  expect_equal(sum(r$filled), 0)
  expect_no_warning(r0 <- simulation(al, st))
  expect_gt(sum(r0$filled), 0)
})

test_that("R2-04: funds_fee/bonus_fee 0 bis 100, sonst Fehler", {
  d <- mk_day(400, function(n) rep(100, n))
  st <- create_strategy(A = asset_config("etf", asset_share = 1, asset_spread = 0))
  for (v in list(-1, NA, 150, NULL, "1"))
    expect_error(simulation(d, st, tax_mode = "funds", funds_fee = v), "funds_fee muss eine Zahl in Prozent")
  for (v in list(-20, 150, NA))
    expect_error(simulation(d, st, tax_mode = "funds", bonus_fee = v), "bonus_fee muss eine Zahl in Prozent")
  expect_no_error(simulation(d, st, tax_mode = "funds", funds_fee = 0.95, bonus_fee = 0))
  expect_no_error(simulation(d, st, tax_mode = "funds", funds_fee = 100, bonus_fee = 100))
  expect_no_error(simulation(d, st, tax_mode = "none", funds_fee = NA))   # ohne Fondsmodus ohne Wirkung
})

test_that("R2-06: Fondsmodus, Ende auf aufgefuelltem Tag: Kosten vor Steuer", {
  cal <- seq.Date(as.Date("2021-01-01"), as.Date("2022-01-31"), by = "day")
  d <- data.frame(date = cal, A = 100 * 1.0015^(seq_along(cal) - 1))
  wd <- d[!format(d$date, "%u") %in% c("6", "7"), ]
  al <- align_series(A = wd, end = "2021-12-25")                     # endet Sa 25.12.
  st <- create_strategy(A = asset_config("etf", asset_share = 1, asset_spread = 0))
  o <- capture.output(r <- suppressMessages(simulation(al, st, tax_mode = "funds", liquidate = TRUE, details = TRUE)))
  expect_true(any(grepl("^Fondskosten:\tFondsgeb\u00fchren .* am 2021-12-24", o)))
  expect_false(any(grepl("Fondsgeb\u00fchren .* am 2021-12-25", o)))
  E <- tail(r$worth, 1); T <- r$tax_report$total_taxes_paid
  expect_equal(T, 0.26375 * (E + T - 1e4), tolerance = 1e-9)
})

test_that("R2-07: Warnung zu marginal_tax_rate nur bei tax_mode = 'person'", {
  d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 400), A = 100, G = 50)
  st <- create_strategy(A = asset_config("etf", asset_share = .8), G = asset_config("etc", asset_share = .2, deliverable = TRUE))
  expect_no_warning(simulation(d, st, tax_mode = "none"))
  expect_no_warning(simulation(d, st, tax_mode = "funds"))
  expect_warning(simulation(d, st, tax_mode = "person"), "marginal_tax_rate")
})

test_that("doppelte dca_days -> Warnung, eine Rate; doppelte Spaltennamen -> Fehler", {
  d <- mk_day(400, function(n) 100 * 1.0005^(0:(n - 1)))
  st <- create_strategy(A = asset_config("etf", asset_share = 1))
  r1 <- simulation(d, st, dca_mode = TRUE, dca_value = 100, dca_span = 1, dca_days = 15)
  expect_warning(r2 <- simulation(d, st, dca_mode = TRUE, dca_value = 100, dca_span = 1, dca_days = c(15, 15)), "doppelte Tage")
  expect_identical(r1$worth, r2$worth)
  expect_warning(simulation(d, st, balance_mode = TRUE, balance_days = c(1, 1)), "balance_days enth\u00e4lt doppelte")
  d2 <- cbind(d, d["A"])
  expect_error(simulation(d2, st), "Spaltenname 'A' kommt in 'data' mehrfach vor")
})
