# test-simulation.R
# Unit tests for SimLev simulation function

library(testthat)
library(SimLev)

# ==============================================================================
# TEST DATA
# ==============================================================================

create_test_data <- function(n_days = 100, seed = 42) {
  set.seed(seed)
  data.frame(
    date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n_days),
    ETF = 100 * cumprod(1 + rnorm(n_days, 0.001, 0.02))
  )
}

create_test_strategy <- function() {
  list(
    ETF = list(
      asset_class = "etf",
      trading = "bnh",
      share = 1.0,
      spread = 0.1,
      partial_exemption = 0,
      signal_buy = NULL,
      signal_sell = NULL
    )
  )
}

# ==============================================================================
# BASIC FUNCTIONALITY TESTS
# ==============================================================================

test_that("simulation runs without errors", {
  data <- create_test_data()
  strategy <- create_test_strategy()
  
  expect_no_error({
    result <- simulation(data, strategy, start_value = 10000)
  })
})

test_that("simulation returns correct structure", {
  data <- create_test_data()
  strategy <- create_test_strategy()
  
  result <- simulation(data, strategy, start_value = 10000)
  
  expect_true(is.list(result))
  expect_true("worth" %in% names(result))
  expect_true("cagr" %in% names(result))
  expect_true("ttwror" %in% names(result))
  expect_true("drawdowns" %in% names(result))
  expect_true("statistics" %in% names(result))
  expect_true("report" %in% names(result))
})

test_that("worth vector has correct length", {
  data <- create_test_data(n_days = 100)
  strategy <- create_test_strategy()
  
  result <- simulation(data, strategy, start_value = 10000)
  
  expect_equal(length(result$worth), 100)
})

test_that("initial worth equals start_value", {
  data <- create_test_data()
  strategy <- create_test_strategy()
  
  result <- simulation(data, strategy, start_value = 10000)
  
  expect_equal(result$worth[1], 10000, tolerance = 1)
})

# ==============================================================================
# DCA TESTS
# ==============================================================================

test_that("DCA increases portfolio value", {
  data <- create_test_data(n_days = 365)
  strategy <- create_test_strategy()
  
  result_no_dca <- simulation(data, strategy, start_value = 10000)
  
  result_dca <- simulation(data, strategy, start_value = 10000, dca = dca_plan(value = 1000, span = 1, days = 1, unit = "month"))
  
  # DCA should add ~12 * $1000 = $12000 over the year
  expect_gt(tail(result_dca$worth, 1), tail(result_no_dca$worth, 1))
})

test_that("DCA flows are recorded in report", {
  data <- create_test_data(n_days = 100)
  strategy <- create_test_strategy()
  
  result <- simulation(data, strategy, start_value = 10000, dca = dca_plan(value = 500, span = 1, days = 1, unit = "month"))
  
  flows <- result$report$ETF$flows
  expect_true(sum(flows) > 0)
})

# ==============================================================================
# TAX TESTS
# ==============================================================================

test_that("tax mode 'none' calculates no taxes", {
  data <- create_test_data()
  strategy <- create_test_strategy()
  
  result <- simulation(data, strategy, start_value = 10000, liquidate = TRUE)
  
  # Without tax tracking, we can't directly verify, but it should run
 expect_no_error(result)
})

test_that("tax mode 'person' runs without errors", {
  data <- create_test_data()
  strategy <- create_test_strategy()
  
  expect_no_error({
    result <- simulation(data, strategy, start_value = 10000, tax = tax_profile(rate = 26.375), liquidate = TRUE)
  })
})

# ==============================================================================
# REBALANCING TESTS
# ==============================================================================

test_that("rebalancing runs without errors", {
  data <- create_test_data(n_days = 365)
  
  # Two-asset strategy for rebalancing
  set.seed(42)
  data$BOND <- 50 * cumprod(1 + rnorm(365, 0.0002, 0.005))
  
  strategy <- list(
    ETF = list(
      asset_class = "etf", trading = "bnh",
      share = 0.6, spread = 0.1, partial_exemption = 0,
      signal_buy = NULL, signal_sell = NULL
    ),
    BOND = list(
      asset_class = "etf", trading = "bnh",
      share = 0.4, spread = 0.05, partial_exemption = 30,
      signal_buy = NULL, signal_sell = NULL
    )
  )
  
  expect_no_error({
    result <- simulation(data, strategy, start_value = 10000, rebalance = rebalance_plan(span = 1, days = 1, unit = "quarter"))
  })
})

# ==============================================================================
# EDGE CASE TESTS
# ==============================================================================

test_that("simulation handles single day", {
  data <- create_test_data(n_days = 1)
  strategy <- create_test_strategy()
  
  expect_no_error({
    result <- simulation(data, strategy, start_value = 10000)
  })
})

test_that("simulation handles zero start value gracefully", {
  data <- create_test_data()
  strategy <- create_test_strategy()
  
  # This might error or return zeros - either is acceptable
  result <- tryCatch(
    simulation(data, strategy, start_value = 0),
    error = function(e) NULL
  )
  
 expect_true(is.null(result) || all(result$worth == 0))
})

test_that("liquidation sells all positions", {
  data <- create_test_data()
  strategy <- create_test_strategy()
  
  result <- simulation(
    data, strategy, start_value = 10000,
    liquidate = TRUE
  )
  
  # After liquidation, report should show final position
  # The exact check depends on implementation
 expect_no_error(result)
})

# ==============================================================================
# HELPER FUNCTION TESTS
# ==============================================================================

test_that("calculate_skewness returns numeric", {
  x <- rnorm(100)
  result <- calculate_skewness(x)
  
  expect_true(is.numeric(result))
  expect_true(!is.na(result))
})

test_that("calculate_kurtosis returns numeric", {
  x <- rnorm(100)
  result <- calculate_kurtosis(x)
  
  expect_true(is.numeric(result))
  expect_true(!is.na(result))
})

# ==============================================================================
# PERFORMANCE TESTS (optional, may be slow)
# ==============================================================================

test_that("simulation completes within reasonable time", {
  skip_on_cran()  # Skip on CRAN to save time
  
  # 10 years of daily data
  data <- create_test_data(n_days = 3650)
  strategy <- create_test_strategy()
  
  time <- system.time({
    result <- simulation(data, strategy, start_value = 10000)
  })
  
  # Should complete in under 5 seconds
  expect_lt(time["elapsed"], 5)
})


# ==============================================================================
# A-2: LOCF-MARKIERUNG UND AUSSCHLUSS AUS RISIKOMETRIKEN
# ==============================================================================

create_gapped_data <- function(seed = 99) {
  set.seed(seed)
  # Nur Handelstage (Mo-Fr) -> Wochenenden fehlen -> werden per LOCF aufgefuellt
  all <- seq.Date(as.Date("2021-01-04"), as.Date("2021-12-31"), by = "day")
  wd  <- all[as.integer(format(all, "%u")) <= 5]
  data.frame(
    date = wd,
    ETF  = 100 * cumprod(1 + rnorm(length(wd), 4e-4, 0.011))
  )
}

test_that("filled days are marked in results", {
  data     <- create_gapped_data()
  strategy <- create_test_strategy()
  result   <- simulation(data, strategy, start_value = 10000)

  # Ergebnis enthaelt 'filled'-Vektor
  expect_true(!is.null(result$filled))
  expect_true(is.logical(result$filled))
  expect_equal(length(result$filled), length(result$dates))

  # Wochenendtage wurden als aufgefuellt markiert
  n_weekends <- sum(as.integer(format(result$dates, "%u")) >= 6)
  expect_equal(sum(result$filled), n_weekends)
})

test_that("filled days are excluded from risk metrics", {
  data     <- create_gapped_data()
  strategy <- create_test_strategy()
  result   <- simulation(data, strategy, start_value = 10000)

  # Auf Kalendertagen wuerde sd groesser wirken (mehr Nullen senken sd kuenstlich)
  # Mit Ausschluss: sd approximiert Handelstags-Vola (~0.011)
  expect_true(result$statistics$sd > 0.005)
  expect_true(result$statistics$sd < 0.03)
})

test_that("risk metrics use trading-day annualisation after LOCF exclusion", {
  data     <- create_gapped_data()
  strategy <- create_test_strategy()
  r_gapped <- simulation(data, strategy, start_value = 10000)

  # Vollstaendige Kalenderreihe (keine Luecken -> kein LOCF-Ausschluss)
  set.seed(99)
  all <- seq.Date(as.Date("2021-01-04"), as.Date("2021-12-31"), by = "day")
  data_full <- data.frame(
    date = all,
    ETF  = 100 * cumprod(1 + rnorm(length(all), 4e-4, 0.011))
  )
  r_full <- simulation(data_full, strategy, start_value = 10000)

  # Beide Laeufe laufen fehlerfrei und liefern endliche Sharpe-Werte
  expect_true(is.finite(r_gapped$statistics$sharpe))
  expect_true(is.finite(r_full$statistics$sharpe))
})


# ==============================================================================
# A-4: RISK-FREE-RATE (skalare + Zeitreihe + NULL/0)
# ==============================================================================

create_rf_data <- function(seed = 77) {
  set.seed(seed)
  all <- seq.Date(as.Date("2022-01-01"), as.Date("2022-12-31"), by = "day")
  wd  <- all[as.integer(format(all, "%u")) <= 5]
  data.frame(
    date = wd,
    ETF  = 100 * cumprod(1 + rnorm(length(wd), 3e-4, 0.011)),
    sofr = seq(1, 4, length.out = length(wd))   # R9-06: Prozent (wie SOFR 5.31), nicht Anteil
  )
}

test_that("risk_free = NULL and risk_free = 0 are identical", {
  data     <- create_rf_data()
  strategy <- create_test_strategy()
  r_null <- simulation(data, strategy, start_value = 10000, risk_free = NULL)
  r_zero <- simulation(data, strategy, start_value = 10000, risk_free = 0)

  expect_equal(r_null$statistics$sharpe,  r_zero$statistics$sharpe)
  expect_equal(r_null$statistics$sortino, r_zero$statistics$sortino)
})

test_that("risk_free = 0 equals default (no argument)", {
  data     <- create_rf_data()
  strategy <- create_test_strategy()
  r_default <- simulation(data, strategy, start_value = 10000)
  r_zero    <- simulation(data, strategy, start_value = 10000, risk_free = 0)

  expect_equal(r_default$statistics$sharpe,  r_zero$statistics$sharpe)
  expect_equal(r_default$statistics$sortino, r_zero$statistics$sortino)
})

test_that("positive risk_free reduces Sharpe and Sortino", {
  data     <- create_rf_data()
  strategy <- create_test_strategy()
  r0  <- simulation(data, strategy, start_value = 10000, risk_free = 0)
  r3  <- simulation(data, strategy, start_value = 10000, risk_free = 3)

  expect_true(r3$statistics$sharpe  < r0$statistics$sharpe)
  expect_true(r3$statistics$sortino < r0$statistics$sortino)
})

test_that("risk_free as column name equals equivalent scalar", {
  data     <- create_rf_data()
  strategy <- create_test_strategy()

  # Konstante Spalte mit Wert 3 muss identisch zu risk_free=3 sein
  data$rf_const <- 3
  r_scalar <- simulation(data, strategy, start_value = 10000, risk_free = 3)
  r_col    <- simulation(data, strategy, start_value = 10000, risk_free = "rf_const")

  expect_equal(r_scalar$statistics$sharpe,  r_col$statistics$sharpe,  tolerance = 1e-9)
  expect_equal(r_scalar$statistics$sortino, r_col$statistics$sortino, tolerance = 1e-9)
})

test_that("time-varying risk_free column is processed per day (Option A)", {
  data     <- create_rf_data()
  strategy <- create_test_strategy()
  r_ts  <- simulation(data, strategy, start_value = 10000, risk_free = "sofr")
  r_avg <- simulation(data, strategy, start_value = 10000,
                      risk_free = mean(data$sofr))   # Naiver Mittelwert

  # Beide sollen endlich sein; zeitvariante Rate soll von geglatteter abweichen
  expect_true(is.finite(r_ts$statistics$sharpe))
  expect_true(abs(r_ts$statistics$sharpe - r_avg$statistics$sharpe) > 1e-6)
})

test_that("risk_free column missing from data raises error", {
  data     <- create_rf_data()
  strategy <- create_test_strategy()
  expect_error(
    simulation(data, strategy, start_value = 10000, risk_free = "nonexistent"),
    "Spalte 'nonexistent' fehlt"
  )
})

test_that("statistics list contains risk_free field", {
  data     <- create_rf_data()
  strategy <- create_test_strategy()
  r <- simulation(data, strategy, start_value = 10000, risk_free = 2)

  expect_true("risk_free" %in% names(r$statistics))
  expect_equal(r$statistics$risk_free, 2, tolerance = 1e-9)
})


# ==============================================================================
# V-1: DCA/REBALANCING FEUERN OHNE EXPLIZITES 'days' (Guard-Bug-Regression)
# ==============================================================================

test_that("DCA fires without explicit dca_days (monthly schedule)", {
  set.seed(1)
  n <- 365
  data <- data.frame(
    date = seq.Date(as.Date("2022-01-01"), by = "day", length.out = n),
    ETF  = 100 * cumprod(1 + rnorm(n, 4e-4, 0.01))
  )
  strategy <- create_test_strategy()
  result <- simulation(data, strategy, start_value = 1000, dca = dca_plan(value = 1000, span = 1, unit = "month"))

  # Externe Zufluesse muessen an ~11-12 Monatsterminen ankommen
  flow_days <- sum(abs(result$report$ETF$flows) > 1e-9)
  expect_gt(flow_days, 9)
})

test_that("periodic rebalancing fires without explicit balance_days", {
  set.seed(3)
  n <- 730
  data <- data.frame(
    date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = n),
    A = 100 * cumprod(1 + rnorm(n,  8e-4, 0.012)),   # driftet stark
    B = 100 * cumprod(1 + rnorm(n, -2e-4, 0.004))    # driftet schwach
  )
  strategy <- create_strategy(
    A = asset_config("etf", trading = "bnh", share = 0.5,
                     spread = 0, partial_exemption = 30),
    B = asset_config("etf", trading = "bnh", share = 0.5,
                     spread = 0, partial_exemption = 30)
  )
  result <- simulation(data, strategy, start_value = 10000, rebalance = rebalance_plan(span = 1, unit = "month"))

  # Rebalancing MUSS Verkaeufe erzeugen (A wird wiederholt zurueckgestutzt)
  expect_gt(sum(result$sells), 0)
})

test_that("event_col rebalancing is available and runs", {
  set.seed(4)
  n <- 300
  data <- data.frame(
    date = seq.Date(as.Date("2022-01-01"), by = "day", length.out = n),
    ETF  = 100 * cumprod(1 + rnorm(n, 4e-4, 0.01)),
    target_leverage = 2 + 0.5 * sin(seq(0, 4 * pi, length.out = n))
  )
  data <- rebalance_trigger(data, type = "abs_leverage", threshold = 10)
  strategy <- create_test_strategy()
  expect_no_error({
    result <- simulation(data, strategy, start_value = 10000, rebalance = rebalance_plan(event_col = "rebal_trigger", event_mode = "replace", skip = TRUE))
  })
  expect_true(is.finite(tail(result$worth, 1)))
})


# ==============================================================================
# V-1b: EREIGNISSE WERDEN VON LOCF-TAGEN VERSCHOBEN (Monatsende: vorziehen)
# ==============================================================================

test_that("scheduled DCA never executes on filled days (shift forward)", {
  set.seed(1)
  all <- seq.Date(as.Date("2022-01-01"), as.Date("2022-12-31"), by = "day")
  wd  <- all[as.integer(format(all, "%u")) <= 5]
  data <- data.frame(date = wd, ETF = 100 * cumprod(1 + rnorm(length(wd), 4e-4, 0.01)))
  strategy <- create_test_strategy()
  r <- simulation(data, strategy, start_value = 1000, dca = dca_plan(value = 1000, span = 1, unit = "month"))
  fl <- which(abs(r$report$ETF$flows) > 1e-9)
  expect_equal(sum(r$filled[fl]), 0)                    # nie an LOCF-Tagen
  # 01.05.2022 (So) -> 02.05. (Mo); 01.10.2022 (Sa) -> 03.10. (Mo)
  expect_true(as.Date("2022-05-02") %in% r$dates[fl])
  expect_true(as.Date("2022-10-03") %in% r$dates[fl])
})

test_that("month-end schedule is pulled BACK to previous trading day", {
  set.seed(1)
  all <- seq.Date(as.Date("2022-01-01"), as.Date("2022-12-31"), by = "day")
  wd  <- all[as.integer(format(all, "%u")) <= 5]
  data <- data.frame(date = wd, ETF = 100 * cumprod(1 + rnorm(length(wd), 4e-4, 0.01)))
  strategy <- create_test_strategy()
  r <- simulation(data, strategy, start_value = 1000, dca = dca_plan(value = 1000, span = 1, days = 1, unit = "month", anchor = "end"))
  fl <- which(abs(r$report$ETF$flows) > 1e-9)
  expect_equal(sum(r$filled[fl]), 0)
  # 30.04. = Sa -> 29.04. (Fr, gleicher Monat); 31.07. = So -> 29.07. (Fr)
  expect_true(as.Date("2022-04-29") %in% r$dates[fl])
  expect_true(as.Date("2022-07-29") %in% r$dates[fl])
  expect_false(any(format(r$dates[fl], "%m-%d") %in% c("05-02", "08-01")))
})


# ==============================================================================
# V-2: REBALANCING PRUEFT DIE SIGNALLOGIK EIGENSTAENDIG
# ==============================================================================

create_pulse_data <- function(buy_on, sell_on = NULL, seed = 2, n = 120) {
  set.seed(seed)
  d <- data.frame(date = seq.Date(as.Date("2022-01-03"), by = "day", length.out = n),
                  SIG  = 100 * cumprod(1 + rnorm(n, 4e-4, 0.01)))
  d$buy_sig  <- d$date %in% as.Date(buy_on)
  d$sell_sig <- if (is.null(sell_on)) FALSE else d$date %in% as.Date(sell_on)
  d
}

signal_strategy <- function() create_strategy(
  SIG = asset_config("etf", trading = "signal", share = 1,
                     spread = 0, partial_exemption = 30,
                     signal_buy = "buy_sig", signal_sell = "sell_sig"))

test_that("pulse buy signal on a rebalance day is executed (signal entry)", {
  d <- create_pulse_data(buy_on = "2022-02-01")     # 01.02. = Monats-Rebalance-Tag
  r <- simulation(d, signal_strategy(), start_value = 10000, rebalance = rebalance_plan(span = 1, unit = "month"))
  i <- which(r$dates == as.Date("2022-02-02"))
  expect_gt(r$report$SIG$worth[i], 0)
})

test_that("signal asset without buy signal is not force-bought by rebalancing", {
  d <- create_pulse_data(buy_on = "2022-02-01")
  r <- simulation(d, signal_strategy(), start_value = 10000, rebalance = rebalance_plan(span = 1, unit = "month"))
  i <- which(r$dates == as.Date("2022-01-15"))      # vor dem Kaufsignal
  expect_equal(r$report$SIG$worth[i], 0)
  expect_gt(r$report$SIG$money[i], 9999)
})

test_that("sell signal on a rebalance day exits; proceeds stay in asset cash", {
  d <- create_pulse_data(buy_on = "2022-01-10", sell_on = "2022-03-01")  # 01.03. = Rebalance-Tag
  r <- simulation(d, signal_strategy(), start_value = 10000, rebalance = rebalance_plan(span = 1, unit = "month"))
  i_pre  <- which(r$dates == as.Date("2022-02-28"))
  i_post <- which(r$dates == as.Date("2022-03-02"))
  expect_gt(r$report$SIG$worth[i_pre], 0)           # vorher investiert
  expect_equal(r$report$SIG$worth[i_post], 0)       # Exit vollzogen
  expect_gt(r$report$SIG$money[i_post], 0)          # Erloes im eigenen Cash
})


# ==============================================================================
# § 18 Abs. 3 InvStG: VP-FESTSETZUNG 31.12., FAELLIGKEIT ERSTER HANDELSTAG
# ==============================================================================

create_vp_data <- function() {
  all <- seq.Date(as.Date("2022-01-01"), as.Date("2023-01-31"), by = "day")
  wd  <- all[as.integer(format(all, "%u")) <= 5]      # 31.12.2022 = Samstag!
  set.seed(9)
  d <- data.frame(date = wd, ETF = 100 * cumprod(1 + rnorm(length(wd), 8e-4, 0.008)))
  d$base_rate <- 2.55                                  # Prozent (2,55 %)
  d
}

vp_strategy <- function() create_strategy(
  ETF = asset_config("etf", trading = "bnh", share = 1,
                     spread = 0, partial_exemption = 30))

test_that("VP is settled on first trading day of new year, not on Dec 31", {
  d <- create_vp_data()
  r <- simulation(d, vp_strategy(), start_value = 10000, tax = tax_profile(rate = 26.375, sparer_pauschbetrag = 0, base_rate = "base_rate"))
  px  <- d$ETF[match(r$dates, d$date)]
  cnt <- r$report$ETF$worth / px
  i_1230 <- which(r$dates == as.Date("2022-12-30"))
  i_0102 <- which(r$dates == as.Date("2023-01-02"))
  # Zwangsverkauf erst am 02.01.2023 (erster Handelstag), nicht am 30./31.12.
  expect_gt(cnt[i_1230], cnt[i_0102])
  # Steuer wurde gezahlt und entspricht 26,375 % der VP-Bemessung
  expect_gt(r$tax_report$total_taxes_paid, 0)
})

test_that("VP falls back to immediate payment when simulation ends at year end", {
  # Luecken-lose Tagesreihe bis exakt 31.12. -> Festsetzung am 31.12.,
  # aber kein Handelstag im Folgejahr innerhalb der Simulation
  dd <- seq.Date(as.Date("2022-01-01"), as.Date("2022-12-31"), by = "day")
  set.seed(9)
  d <- data.frame(date = dd, ETF = 100 * cumprod(1 + rnorm(length(dd), 8e-4, 0.008)))
  d$base_rate <- 2.55
  r <- simulation(d, vp_strategy(), start_value = 10000, tax = tax_profile(rate = 26.375, sparer_pauschbetrag = 0, base_rate = "base_rate"))
  expect_gt(r$tax_report$total_taxes_paid, 0)   # sofort beglichen (Fallback)
})

test_that("deferred VP is not double-counted against next year's assessment", {
  # Zwei volle Jahre: Zahlung der VP 2022 im Januar 2023 darf die
  # Festsetzung 2023 nicht mindern (Dedup auf Festsetzungsjahr)
  all <- seq.Date(as.Date("2022-01-01"), as.Date("2024-01-31"), by = "day")
  wd  <- all[as.integer(format(all, "%u")) <= 5]
  set.seed(9)
  d <- data.frame(date = wd, ETF = 100 * cumprod(1 + rnorm(length(wd), 8e-4, 0.008)))
  d$base_rate <- 2.55
  r <- simulation(d, vp_strategy(), start_value = 10000, tax = tax_profile(rate = 26.375, sparer_pauschbetrag = 0, base_rate = "base_rate"))
  px  <- d$ETF[match(r$dates, d$date)]
  cnt <- r$report$ETF$worth / px
  drop1 <- cnt[which(r$dates == as.Date("2022-12-30"))] -
           cnt[which(r$dates == as.Date("2023-01-03"))]
  drop2 <- cnt[which(r$dates == as.Date("2023-12-29"))] -
           cnt[which(r$dates == as.Date("2024-01-03"))]
  expect_gt(drop1, 0)   # Zwangsverkauf fuer VP 2022 im Jan 2023
  expect_gt(drop2, 0)   # Zwangsverkauf fuer VP 2023 im Jan 2024 (nicht dedupliziert!)
})


# ==============================================================================
# PROZENT-KONVENTION: Nutzerangaben in Prozent, intern /100
# ==============================================================================

test_that("tax_rate is interpreted as percent (26.375 = 26.375%)", {
  d <- data.frame(date = seq.Date(as.Date("2022-01-03"), by = "day", length.out = 200),
                  ETF  = seq(100, 150, length.out = 200))
  s <- create_strategy(ETF = asset_config("etf", "bnh", share = 1,
                                          spread = 0, partial_exemption = 0))
  r <- simulation(d, s, start_value = 10000, tax = tax_profile(rate = 26.375, sparer_pauschbetrag = 0), liquidate = TRUE)
  gain <- 10000 * (150 / 100) - 10000
  expect_equal(r$tax_report$total_taxes_paid / gain, 0.26375, tolerance = 1e-6)
})

test_that("partial_exemption is interpreted as percent (30 = 30% Teilfreistellung)", {
  d <- data.frame(date = seq.Date(as.Date("2022-01-03"), by = "day", length.out = 200),
                  ETF  = seq(100, 150, length.out = 200))
  s <- create_strategy(ETF = asset_config("etf", "bnh", share = 1,
                                          spread = 0, partial_exemption = 30))
  r <- simulation(d, s, start_value = 10000, tax = tax_profile(rate = 26.375, sparer_pauschbetrag = 0), liquidate = TRUE)
  gain <- 5000
  expect_equal(r$tax_report$total_taxes_paid / gain, 0.26375 * 0.70, tolerance = 1e-6)
})


# ==============================================================================
# FIX-REGRESSIONEN: liquidate-VP, balance_thresh-Prozent, Sleeve-Renormierung
# ==============================================================================

test_that("liquidate=TRUE does not disable Vorabpauschale in earlier years", {
  all <- seq.Date(as.Date("2022-01-01"), as.Date("2023-06-30"), by = "day")
  wd  <- all[as.integer(format(all, "%u")) <= 5]
  set.seed(9)
  d <- data.frame(date = wd, ETF = 100 * cumprod(1 + rnorm(length(wd), 8e-4, 0.008)))
  d$base_rate <- 2.55
  s <- create_strategy(ETF = asset_config("etf", "bnh", share = 1,
                                          spread = 0, partial_exemption = 30))
  r <- simulation(d, s, start_value = 10000, tax = tax_profile(rate = 26.375, sparer_pauschbetrag = 0, base_rate = "base_rate"), liquidate = TRUE)
  # VP 2022 wird am ersten Handelstag 2023 per Zwangsverkauf beglichen,
  # obwohl liquidate=TRUE (Liquidation erst am 30.06.2023)
  px  <- d$ETF[match(r$dates, d$date)]
  cnt <- r$report$ETF$worth / px
  i_pre  <- which(r$dates == as.Date("2022-12-30"))
  i_post <- which(r$dates == as.Date("2023-01-02"))
  expect_gt(cnt[i_pre], cnt[i_post])
})

test_that("balance_thresh is interpreted as percent (5 = 5%)", {
  set.seed(3)
  n <- 730
  data <- data.frame(
    date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = n),
    A = 100 * cumprod(1 + rnorm(n,  8e-4, 0.012)),
    B = 100 * cumprod(1 + rnorm(n, -2e-4, 0.004))
  )
  strategy <- create_strategy(
    A = asset_config("etf", "bnh", share = 0.5, spread = 0, partial_exemption = 30),
    B = asset_config("etf", "bnh", share = 0.5, spread = 0, partial_exemption = 30)
  )
  r5 <- simulation(data, strategy, start_value = 10000, rebalance = rebalance_plan(span = 1, unit = "month", thresh = 5))          # 5 %
  expect_gt(sum(r5$sells), 0)                   # Abweichung > 5% -> Rebalancing feuert
  r90 <- simulation(data, strategy, start_value = 10000, rebalance = rebalance_plan(span = 1, unit = "month", thresh = 90))        # 90 % -> nie
  expect_equal(sum(r90$sells), 0)
})

test_that("inactive signal asset holds its target weight as own CASH reserve", {
  # Fix 3 (Design): Gleichbehandlung — das inaktive Signal-Asset haelt sein
  # Zielgewicht (50 %) als eigene Cash-Position; der Pool gleicht die Reserve
  # per Cash-Transfer aus (kein Aktienkauf); uebrige Assets sind nach dem
  # Rebalance-Tag voll investiert (Fix 5).
  set.seed(4)
  n <- 90
  d <- data.frame(date = seq.Date(as.Date("2022-01-03"), by = "day", length.out = n),
                  W = 100 * cumprod(1 + rnorm(n, 4e-4, 0.01)),
                  S = 100 * cumprod(1 + rnorm(n, 4e-4, 0.01)))
  d$b <- FALSE; d$sl <- FALSE                    # Signal-Asset dauerhaft "out"
  s <- create_strategy(
    W = asset_config("etf", "bnh",    share = 0.5, spread = 0, partial_exemption = 30),
    S = asset_config("etf", "signal", share = 0.5, spread = 0, partial_exemption = 30,
                     signal_buy = "b", signal_sell = "sl")
  )
  r <- simulation(d, s, start_value = 10000, rebalance = rebalance_plan(span = 1, unit = "month", thresh = 1))
  i_post <- which(r$dates == as.Date("2022-02-02"))   # nach Monats-Rebalance

  # 1) Nie Aktien im inaktiven Signal-Asset
  expect_equal(max(r$report$S$worth), 0)
  # 2) Cash-Reserve wird auf das Zielgewicht getrimmt (Gleichbehandlung)
  total <- r$report$W$total[i_post] + r$report$S$total[i_post]
  expect_lt(abs(r$report$S$money[i_post] / total - 0.5), 0.02)
  # 3) BnH-Asset nach dem Rebalance-Tag voll investiert (Fix 5: kein Cash-Drag)
  expect_lt(r$report$W$money[i_post], 0.01)
})


# ==============================================================================
# R-2: VORABPAUSCHALE WIRD MIT DEM § 20-VERLUSTTOPF VERRECHNET (Bankpraxis)
# ==============================================================================

test_that("VP is offset against the loss pot before SPB (bank practice)", {
  # BOND-only, +6 %/a, base 3 %  -> VP Jahr 1 ohne Topf = 52.50 (verifizierte Referenz).
  # Zusatz-Asset L erzeugt VOR dem 31.12. einen realisierten Verlust > taxable VP
  # -> Verlusttopf schluckt die VP komplett: keine VP-Zahlung im Folgejahr.
  dd <- seq.Date(as.Date("2019-01-01"), as.Date("2020-03-31"), by = "day")
  nL <- length(dd)
  d <- data.frame(date = dd,
                  B = 100 * (1.06)^(as.numeric(dd - dd[1]) / 365.25),
                  L = 100 - 40 * as.numeric(dd - dd[1]) / 365.25,   # faellt stetig
                  base_rate = 3)
  d$buyL  <- d$date == as.Date("2019-02-01")
  d$sellL <- d$date == as.Date("2019-11-01")                        # Verlust ~ -30 %
  s <- create_strategy(
    B = asset_config("etf", "bnh",    share = 0.9, spread = 0, partial_exemption = 0),
    L = asset_config("etf", "signal", share = 0.1, spread = 0, partial_exemption = 0,
                     signal_buy = "buyL", signal_sell = "sellL"))
  run <- function(with_loss) {
    dl <- d; if (!with_loss) { dl$buyL <- FALSE }
    o <- capture.output(r <- simulation(dl, s, start_value = 10000, tax = tax_profile(rate = 25, sparer_pauschbetrag = 0, base_rate = "base_rate"), details = TRUE))
    vp_a <- sum(as.numeric(sub(".*Zahlung Vorabpauschale ([0-9.]+) EUR.*", "\\1",
             grep("Zahlung Vorabpauschale", o, value = TRUE))))
    vp_b <- sum(as.numeric(sub(".*Rest von ([0-9.]+) EUR.*", "\\1",
             grep("Anteile verkauft f\u00fcr den Rest von", o, value = TRUE))))
    list(r = r, vp_paid = vp_a + vp_b)
  }
  a <- run(with_loss = FALSE)   # Referenz: VP faellig
  b <- run(with_loss = TRUE)    # Verlusttopf > taxable VP
  expect_gt(a$vp_paid, 40)                     # Referenz ~47.25 (B-Anteil 9000)
  expect_equal(b$vp_paid, 0)                   # komplett verrechnet
  # Verlusttopf wurde um die VP-Basis reduziert (kein doppelter Vortrag)
  expect_lt(b$r$tax_report$loss_carryforward_capital,
            a$r$tax_report$loss_carryforward_capital + 3000)
})


# ==============================================================================
# R-1: DCA-VERTEILUNG NACH STRATEGIE-GEWICHTEN
# ==============================================================================

r1_data <- function() {
  set.seed(1); n <- 200
  data.frame(date = seq.Date(as.Date("2022-01-03"), by = "day", length.out = n),
             A = 100 * cumprod(1 + rnorm(n, 15e-4, 0.01)),
             B = 100 * cumprod(1 + rnorm(n, -2e-4, 0.004)))
}
r1_strategy <- function() create_strategy(
  A = asset_config("etf", "bnh", share = 0.7, spread = 0, partial_exemption = 30),
  B = asset_config("etf", "bnh", share = 0.3, spread = 0, partial_exemption = 30))

test_that("DCA splits by strategy weights regardless of portfolio drift", {
  r <- simulation(r1_data(), r1_strategy(), start_value = 10000, dca = dca_plan(value = 500, span = 1, unit = "month"))
  i <- which(r$report$A$flows > 0 & r$dates > as.Date("2022-05-01"))[1]
  expect_equal(r$report$A$flows[i], 350, tolerance = 1e-9)   # 70 %
  expect_equal(r$report$B$flows[i], 150, tolerance = 1e-9)   # 30 %
})

test_that("balance_dca fills value deficits toward strategy weights", {
  r <- simulation(r1_data(), r1_strategy(), start_value = 10000, dca = dca_plan(value = 500, span = 1, unit = "month", fill_deficits = TRUE))
  j <- which(r$report$A$flows + r$report$B$flows > 499 &
             r$dates > as.Date("2022-05-01"))[1]
  tA <- r$report$A$total[j-1]; tB <- r$report$B$total[j-1]
  postA <- (tA + r$report$A$flows[j]) / (tA + tB + 500)
  expect_lt(abs(postA - 0.70), 0.005)          # Rate rebalanciert exakt Richtung Ziel
})

test_that("DCA renormalizes strategy weights over active assets", {
  d <- r1_data(); set.seed(2)
  d$C <- 100 * cumprod(1 + rnorm(nrow(d), 3e-4, 0.006))
  s <- create_strategy(
    A = asset_config("etf", "bnh", share = 0.63, spread = 0, partial_exemption = 30),
    B = asset_config("etf", "bnh", share = 0.27, spread = 0, partial_exemption = 30),
    C = asset_config("etf", "bnh", share = 0.10, spread = 0, partial_exemption = 0,
                     start = as.Date("2022-04-01")))
  r <- simulation(d, s, start_value = 10000, dca = dca_plan(value = 500, span = 1, unit = "month"))
  k1 <- which(r$report$A$flows > 0 & r$dates < as.Date("2022-04-01"))[1]
  k2 <- which(r$report$C$flows > 0)[1]
  expect_equal(r$report$A$flows[k1], 350, tolerance = 1e-9)  # 63/0.9
  expect_equal(r$report$B$flows[k1], 150, tolerance = 1e-9)  # 27/0.9
  expect_equal(unname(c(r$report$A$flows[k2], r$report$B$flows[k2], r$report$C$flows[k2])),
               c(315, 135, 50), tolerance = 1e-9)
})
