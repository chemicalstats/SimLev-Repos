# test-review9-engine.R
# Befunde des Abschlusspruefers (Review 9) zur Engine: R9-02 (details-Ausgabe der Jahresveranlagung im
# Tarifweg), R9-03 (Zahlenformat, Singular/Plural), R9-04 (summary: Startkapital und Depotwert am
# Starttag), R9-06 (Prozent-Warnung auch fuer Zinsspalten).

library(testthat)
library(SimLev)

.r9_warn <- function(expr) {
  w <- character()
  val <- withCallingHandlers(expr, warning = function(x) { w <<- c(w, conditionMessage(x)); invokeRestart("muffleWarning") })
  list(value = val, warnings = w)
}

test_that("R9-02: Nachzahlung der Veranlagung ohne Paragraf-23-Gewinn heisst nicht Paragraf-23-Steuer", {
  set.seed(42); n <- 365 * 10
  data <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n),
                     WORLD = 100 * cumprod(1 + rnorm(n, 4e-4, 0.010)), GOLD = 50 * cumprod(1 + rnorm(n, 3e-4, 0.012)))
  st <- create_strategy(
    WORLD = asset_config("etf", action_type = "bnh", asset_share = 0.6, asset_spread = 0.1, asset_bonus = 30),
    GOLD  = asset_config("etc", action_type = "bnh", asset_share = 0.4, asset_spread = 0.2, deliverable = TRUE))
  args <- list(data, st, start_value = 100000, balance_mode = TRUE, balance_span = 1, balance_unit = "month",
               balance_thresh = 3, tax_mode = "person", base_rate = 2.55, liquidate = TRUE, church_tax = 9,
               use_guenstigerpruefung = TRUE, taxable_income = 14000)
  out <- capture.output(r <- do.call(simulation, c(args, details = TRUE)))
  r0 <- do.call(simulation, args)
  expect_identical(r0$tax_report, r$tax_report)          # nur Text: Zahlen unveraendert
  expect_identical(r0$worth, r$worth)
  expect_false(any(grepl("§ 23 EStG: Steuer", out, fixed = TRUE)))
  ty <- r$tax_report$tariff_years
  y20 <- ty[ty$year == 2020L, ]; y24 <- ty[ty$year == 2024L, ]
  expect_equal(y20$tax_p23, 0)
  l20 <- grep("Veranlagung 2020: Nachzahlung", out, fixed = TRUE, value = TRUE)
  expect_length(l20, 1L)
  expect_match(l20, sprintf("Nachzahlung %.2f EUR (davon § 23 0.00 EUR, Kirchensteuer-Sonderausgaben %.2f EUR)",
                            y20$settlement, y20$deduction_effect), fixed = TRUE)
  expect_match(l20, "aufgeteilt zu gleichen Teilen auf die Assets", fixed = TRUE)
  l24 <- grep("Veranlagung 2024: Nachzahlung", out, fixed = TRUE, value = TRUE)
  expect_length(l24, 1L)
  expect_match(l24, sprintf("davon § 23 %.2f EUR", y24$tax_p23), fixed = TRUE)
  expect_match(l24, "nach dem § 23-Jahressaldo je Asset", fixed = TRUE)
  expect_true(any(grepl("=> Anteil WORLD: ", out, fixed = TRUE)))
})

test_that("R9-03: Betr\u00e4ge ohne englisches Tausenderkomma, 1 Tag / n Tage, ohne Wert nur Strich", {
  dd <- seq.Date(as.Date("2024-01-01"), as.Date("2024-12-31"), by = "day"); n <- length(dd)
  d <- data.frame(date = dd, G = seq(100, 130, length.out = n)); d$b <- seq_len(n) == 1; d$s <- dd == as.Date("2024-09-02")
  s <- create_strategy(G = asset_config("etc", "signal", deliverable = TRUE, asset_spread = 0, signal_buy = "b", signal_sell = "s"))
  w <- .r9_warn(simulation(d, s, start_value = 10000, tax_mode = "person"))
  msg <- grep("erreichen die Freigrenze", w$warnings, value = TRUE)
  expect_length(msg, 1L)
  expect_match(msg, "Gewinne (2013.70 EUR) erreichen die Freigrenze (1000.00 EUR)", fixed = TRUE)
  out <- capture.output(print(w$value))
  expect_true(any(grepl("ngster DD:      1 Tag$", out)))
  expect_true(any(grepl("Mittl. Erholung:  –$", out)))
  expect_false(any(grepl("– Tage", out, fixed = TRUE)))
  # Einzeltag: "1 Tag" statt "1 Tag(e)"
  d1 <- data.frame(date = as.Date("2024-01-02"), A = 100)
  w1 <- .r9_warn(simulation(d1, list(A = list(asset_class = "etf", action_type = "bnh", asset_share = 1))))
  expect_true(any(grepl("Zeitraum 1 Tag (Laufzeit 0 Jahre)", w1$warnings, fixed = TRUE)))
  expect_false(any(grepl("Tag(e)", w1$value$undefined_metrics$detail, fixed = TRUE)))
  expect_true(any(grepl("Zeitraum:         1 Tag (", capture.output(summary(w1$value)), fixed = TRUE)))
})

test_that("R9-04: summary trennt Startkapital und Depotwert am Starttag", {
  set.seed(42); n <- 365 * 3
  data <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n),
                     WORLD = 100 * cumprod(1 + rnorm(n, 4e-4, 0.010)), BONDS = 50 * cumprod(1 + rnorm(n, 1e-4, 0.003)))
  st <- create_strategy(WORLD = asset_config("etf", asset_share = 0.7), BONDS = asset_config("etf", asset_share = 0.3))
  r <- simulation(data, st, start_value = 10000, dca_mode = TRUE, dca_value = 250, dca_span = 1, dca_unit = "month")
  sm <- summary(r)
  expect_equal(sm$start_capital, 10000)
  expect_identical(sm$start_value, r$worth[1])            # Feld unveraendert: Depotwert am Starttag
  out <- capture.output(print(sm))
  expect_true(any(grepl("Startkapital:     10000.00 EUR", out, fixed = TRUE)))
  expect_true(any(grepl(sprintf("Depotwert Starttag: %.2f EUR", r$worth[1]), out, fixed = TRUE)))
  r2 <- simulation(data, st, start_value = 5000)
  expect_equal(summary(r2)$start_capital, 5000)
})

test_that("R9-06: Prozent-Warnung auch f\u00fcr risk_free- und Basiszins-Spalten (Median)", {
  set.seed(9); n <- 900
  d <- data.frame(date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = n), A = 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)))
  d$rf_anteil <- 0.025; d$br_anteil <- 0.0255; d$rf_proz <- 2.5; d$br_proz <- c(0.07, rep(2.55, n - 1)); d$rf_null <- 0
  s <- create_strategy(A = asset_config("etf", asset_bonus = 30))
  w <- .r9_warn(simulation(d, s, risk_free = "rf_anteil"))$warnings
  expect_length(w, 1L)
  expect_match(w, "risk_free-Spalte 'rf_anteil' hat den Median 0.025 und wird als 0.025 % gelesen", fixed = TRUE)
  w <- .r9_warn(simulation(d, s, start_value = 2e5, tax_mode = "person", base_rate_flex = TRUE, base_rate_data = "br_anteil"))$warnings
  expect_length(w, 1L)
  expect_match(w, "base_rate_data-Spalte 'br_anteil' hat den Median 0.0255", fixed = TRUE)
  expect_length(.r9_warn(simulation(d, s, risk_free = "rf_proz"))$warnings, 0L)
  expect_length(.r9_warn(simulation(d, s, risk_free = "rf_null"))$warnings, 0L)
  expect_length(.r9_warn(simulation(d, s, start_value = 2e5, tax_mode = "person", base_rate_flex = TRUE,
                                    base_rate_data = "br_proz"))$warnings, 0L)
})
