# test-refactor.R
# Strukturumbau von simulation() (Review C7-11, C7-12): Phasenfunktionen, Feldfolge von sim_mem,
# Aufruf in Fehlern und Warnungen, Auswertung der Argumente erst bei Gebrauch, entfernter toter Code.
# Der Bitgleich-Nachweis gegen den Stand vor dem Umbau liegt ausserhalb der Testsuite (Vergleichsskript).

library(testthat)
library(SimLev)

.rf_data <- function(n = 400) {
  cal <- seq(as.Date("2020-01-01"), by = "day", length.out = n)
  data.frame(date = cal, A = 100 + seq_len(n) / 10, B = 50 + sin(seq_len(n) / 20))
}
.rf_strategy <- function() {
  list(A = list(asset_class = "etf", action_type = "bnh", asset_share = 0.5, asset_spread = 0.1),
       B = list(asset_class = "etc", action_type = "bnh", asset_share = 0.5, asset_spread = 0.1, deliverable = TRUE))
}
.rf_warnings <- function(expr) {
  w <- list()
  withCallingHandlers(expr, warning = function(x) { w[[length(w) + 1L]] <<- x; invokeRestart("muffleWarning") })
  w
}

test_that("simulation() behaelt Signatur und Standardwerte", {
  f <- formals(simulation)
  expect_identical(names(f), c(
    "data", "strategy", "start_value", "spread", "details", "liquidate", "dca_mode", "dca_value", "dca_span",
    "dca_days", "dca_unit", "dca_anchor", "dca_start", "dca_skip", "balance_mode", "balance_span", "balance_days",
    "balance_unit", "balance_anchor", "balance_start", "balance_skip", "balance_dca", "balance_thresh",
    "balance_thresh_type", "tax_mode", "tax_rate", "marginal_tax_rate", "use_guenstigerpruefung",
    "private_sale_threshold", "sparer_pauschbetrag", "use_sparer_pauschbetrag", "include_soli_on_income_tax",
    "soli_rate_income_tax", "base_rate", "base_rate_flex", "base_rate_data", "funds_fee", "bonus_fee", "fractions",
    "risk_free", "split_mode", "split_thresh", "event_col", "event_mode", "event_weight", "church_tax", "order_fee",
    "dca_fee", "harvest_mode", "harvest_day", "harvest_loss_pot", "taxable_income", "tax_tariff"))
  expect_identical(f$tax_mode, quote(c("none", "person", "funds")))
  expect_identical(f$balance_thresh_type, quote(c("absolute", "relative")))
  expect_identical(f$event_mode, quote(c("additional", "replace")))
  expect_identical(f$tax_rate, 26.375)
  expect_identical(f$harvest_day, "12-15")
})

test_that("C7-11: Feldfolge von sim_mem ist zentral festgelegt und wird geprueft", {
  lay <- .SIM_MEM_LAYOUT
  expect_identical(lay, c("assets", "status", "market", "trades", "report", "totals"))
  d <- .rf_data()
  p <- .sim_prepare_data(d, rep(FALSE, nrow(d)), FALSE, NULL)
  sm <- .sim_build_state(p$data, .rf_strategy(), 10000, p$start_date, p$stopp_date, 1000, TRUE, NULL, FALSE, NULL)
  expect_identical(names(sm), lay)
  expect_invisible(.sim_check_layout(sm))
  expect_error(.sim_check_layout(sm[c(1, 3, 2, 4, 5, 6)]),
               "interner Fehler: sim_mem hat die Felder (assets, market, status, trades, report, totals)", fixed = TRUE)
  expect_error(.sim_check_layout(sm[-6]), "interner Fehler", fixed = TRUE)
  expect_error(.sim_check_layout(unname(sm)), "interner Fehler", fixed = TRUE)
})

test_that("Phasenliste ist vollst\u00e4ndig", {
  ns <- asNamespace("SimLev")
  ph <- .SIM_PHASES
  expect_true(all(vapply(ph, function(f) is.function(get0(f, envir = ns, inherits = FALSE)), NA)))
  defined <- grep("^\\.sim_", ls(ns, all.names = TRUE), value = TRUE)
  expect_setequal(setdiff(defined, ".sim_restore_call"), ph)
})

test_that("Fehler und Warnungen aus den Phasen tragen den Aufruf von simulation()", {
  d <- .rf_data(); s <- .rf_strategy()
  e <- tryCatch(simulation(d, s, start_value = -1), error = identity)              # .sim_check_inputs
  expect_identical(conditionCall(e), quote(simulation(d, s, start_value = -1)))
  e <- tryCatch(simulation(d, s, risk_free = "fehlt"), error = identity)           # .sim_risk_stats
  expect_identical(conditionCall(e), quote(simulation(d, s, risk_free = "fehlt")))
  expect_identical(conditionMessage(e), "risk_free: Spalte 'fehlt' fehlt im Datensatz.")
  e <- tryCatch(simulation(d, s, tax_mode = "Person"), error = identity)           # match.arg wie bisher
  expect_identical(conditionCall(e), quote(match.arg(tax_mode)))

  w <- .rf_warnings(simulation(d, s, church_tax = 9, tax_rate = 25))
  expect_length(w, 1L)
  expect_identical(conditionMessage(w[[1]]), "church_tax \u00fcberschreibt das angegebene tax_rate.")
  expect_identical(conditionCall(w[[1]]), quote(simulation(d, s, church_tax = 9, tax_rate = 25)))
  w <- .rf_warnings(simulation(d, s, spread = 1))                                  # call. = FALSE: ohne Aufruf
  expect_length(w, 1L)
  expect_null(conditionCall(w[[1]]))
})

test_that("Rueckgabe sichtbar; Gebuehrenzustand nach Lauf und nach Abbruch in der Tagesschleife zurueckgesetzt", {
  d <- .rf_data(); s <- .rf_strategy()
  v <- withVisible(simulation(d, s, order_fee = 1))
  expect_true(v$visible)
  expect_s3_class(v$value, "SimLevResult")
  expect_null(.fee_env$current)
  expect_error(simulation(d, s, order_fee = 1, tax_mode = "person", marginal_tax_rate = 42, harvest_mode = TRUE,
                          harvest_loss_pot = stop("Abbruch in der Tagesschleife")),
               "Abbruch in der Tagesschleife", fixed = TRUE)
  expect_null(.fee_env$current)
})

test_that("Argumente werden erst bei Gebrauch ausgewertet", {
  d <- .rf_data(); s <- .rf_strategy()
  expect_silent(r <- simulation(d, s, split_thresh = stop("nicht auswerten")))      # ohne split_mode
  expect_s3_class(r, "SimLevResult")
  w <- .rf_warnings(r <- simulation(d, s, funds_fee = stop("nicht auswerten")))
  expect_length(w, 1L)
  expect_match(conditionMessage(w[[1]]), "funds_fee wirkt nur bei tax_mode = \"funds\"", fixed = TRUE)
  expect_s3_class(r, "SimLevResult")
})

test_that("C7-12: toter Code entfernt", {
  ns <- asNamespace("SimLev")
  for (f in c("get_tax_regime", "calculate_bisection_search"))
    expect_false(exists(f, envir = ns, inherits = FALSE), info = f)
})

test_that("Tarifweg mit details: Paragraf-23-Gewinn \u00fcber der Freigrenze ohne Absturz, Steuer aus der Veranlagung", {
  # Repro aus dem Zufallsvergleich (z0003): details = TRUE, taxable_income, ETC mit Lieferanspruch,
  # Verkauf mit Gewinn innerhalb eines Jahres -> frueher "object 'tax_due' not found"
  cal <- seq(as.Date("2020-01-01"), as.Date("2021-06-30"), by = "day"); n <- length(cal)
  d <- data.frame(date = cal, A = 100 + 100 * pmin(seq_len(n), 366) / 366, B = 50,
                  buy = seq_len(n) == 1L, sell = cal == as.Date("2020-10-01"))
  s <- list(A = list(asset_class = "etc", action_type = "signal", deliverable = TRUE, asset_share = 0.5,
                     asset_spread = 0, signal_buy = "buy", signal_sell = "sell"),
            B = list(asset_class = "etf", action_type = "bnh", asset_share = 0.5, asset_spread = 0))
  out <- capture.output(r <- simulation(d, s, start_value = 1e5, tax_mode = "person", taxable_income = 10000,
                                        church_tax = 9, details = TRUE))
  ty <- r$tax_report$tariff_years
  row <- ty[ty$year == 2020L, ]
  expect_gt(row$gain_p23, 1000)
  expect_gt(row$tax_p23, 0)
  expect_equal(row$tax_p23, row$income_tax_p23 + row$soli_p23 + row$church_tax_p23)
  expect_true(any(grepl("FREIGRENZE ERREICHT", out, fixed = TRUE)))
  expect_true(any(grepl("ESt + Soli + KiSt des § 23-Zuwachses): siehe Jahresveranlagung unten", out, fixed = TRUE)))
  line <- grep("§ 23: Gewinn", out, fixed = TRUE, value = TRUE)
  expect_length(line, 1L)
  expect_identical(line, sprintf("    § 23: Gewinn %.2f EUR -> Steuerlast ESt %.2f + Soli %.2f + KiSt %.2f = %.2f EUR",
                                 row$gain_p23, row$income_tax_p23, row$soli_p23, row$church_tax_p23, row$tax_p23))
  # ohne details dieselben Zahlen
  r0 <- simulation(d, s, start_value = 1e5, tax_mode = "person", taxable_income = 10000, church_tax = 9)
  expect_identical(r0$tax_report, r$tax_report)
  expect_identical(r0$worth, r$worth)
})
