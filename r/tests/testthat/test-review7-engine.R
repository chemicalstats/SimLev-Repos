# Review 7: Engine-Befunde A7-01 ... A7-11, C7-01, C7-04, C7-06 (je Befund Reproduktion -> erwartetes Verhalten)
.r7_days <- function(a, b) seq.Date(as.Date(a), as.Date(b), by = "day")
.r7_sim <- function(...) suppressWarnings(suppressMessages(simulation(...)))
.r7_out <- function(...) { out <- utils::capture.output(r <- .r7_sim(..., details = TRUE)); list(r = r, out = out) }

test_that("A7-01: Bezugskurs der Vorabpauschale = erster im Jahr festgesetzter Kurs (aufgefuellter 1.1. zaehlt nicht)", {
  # Handelstage: 31.12.2024 Kurs 100, 1.1.2025 kein Handelstag, 2.1.2025 Kurs 110, 31.12.2025 Kurs 130
  # Basisertrag 110 x 50 % x 0,7 = 38,50, Deckel 130 - 110 = 20 -> VP 20 je Stueck (vorher mit 100: 30)
  dts <- as.Date(c("2024-12-30", "2024-12-31", "2025-01-02", "2025-06-02", "2025-12-31", "2026-01-02"))
  d <- data.frame(date = dts, A = c(100, 100, 110, 120, 130, 130))
  st <- create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0, partial_exemption = 0))
  r <- .r7_sim(d, st, start_value = 10000, tax = tax_profile(sparer_pauschbetrag = 0, base_rate = 50))
  lots <- r$open_lots$A$lots
  expect_equal(sum(lots$vp) / sum(lots$units), 20)
  # Kalenderdaten mit echtem Kurs am 1.1.: Bezug = Kurs am 1.1. (unveraendert)
  cal <- .r7_days("2024-12-30", "2026-01-02")
  dc <- data.frame(date = cal, A = ifelse(cal < as.Date("2025-01-01"), 100, ifelse(cal < as.Date("2025-12-31"), 110, 130)))
  rc <- .r7_sim(dc, st, start_value = 10000, tax = tax_profile(sparer_pauschbetrag = 0, base_rate = 50))
  lc <- rc$open_lots$A$lots
  expect_equal(sum(lc$vp) / sum(lc$units), 20)
})

test_that("A7-02: am Liquidationstag kein Rebalancing und keine Sparrate, auch nach Terminverschiebung", {
  set.seed(1)
  cal <- .r7_days("2024-01-01", "2024-12-02")                        # 2.12.2024 = Montag, 1.12. = Sonntag
  d <- data.frame(date = cal, A = 100 * cumprod(1 + rnorm(length(cal), 3e-4, 0.01)), B = 100 * cumprod(1 + rnorm(length(cal), 0, 0.002)))
  d <- d[!format(d$date, "%u") %in% c("6", "7"), ]
  st <- create_strategy(A = asset_config("etf", "bnh", share = .6, spread = 0.5),
                        B = asset_config("etf", "bnh", share = .4, spread = 0.5))
  x <- .r7_out(d, st, start_value = 1e5, liquidate = TRUE, costs = sim_costs(order_fee = 10), rebalance = rebalance_plan(unit = "month"))
  day <- grep("am 2024-12-02", x$out, value = TRUE)
  expect_false(any(grepl("^Rebalancing:", day)))                    # vorher Verkauf A / Kauf B
  expect_equal(sum(grepl("^Liquidation:", day)), 2)
  y <- .r7_sim(d, st, start_value = 1e5, liquidate = TRUE, dca = dca_plan(value = 5000, span = 1))
  expect_equal(sum(sapply(y$report, function(a) tail(a$flows, 1))), 0)   # vorher 5000 EUR
})

test_that("A7-03: Aktivierungstag ohne Doppelorders (nur die Umschichtung)", {
  cal <- .r7_days("2024-01-01", "2024-06-30")
  d <- data.frame(date = cal, A = seq(100, 130, length.out = length(cal)), B = 50)
  st <- create_strategy(A = asset_config("etf", "bnh", share = .5, spread = 0.5),
                        B = asset_config("etf", "bnh", share = .5, spread = 0.5, start = as.Date("2024-03-01")))
  x <- .r7_out(d, st, start_value = 10000, costs = sim_costs(order_fee = 5), dca = dca_plan(value = 1000, span = 1))
  day <- grep("am 2024-03-01", x$out, value = TRUE)
  expect_false(any(grepl("^Handelssignal:", day)))                  # vorher Kauf A und B aus der Sparrate
  expect_equal(sum(grepl("^Rebalancing:\t(Kauf|Verkauf)", day)), 2)
  # Gebuehren: Starttag 2 Orders (A: Startkapital und Sparrate), 1.2. 1 (A), Aktivierung 1.3. 2 (Verkauf A, Kauf B),
  # 1.4.-1.6. je 2 (A, B): 2 + 1 + 2 + 6 = 11 Orders x 5 EUR = 55 EUR (vorher zusaetzlich 2 Kaeufe am 1.3.: 65 EUR)
  expect_equal(x$r$fees_paid, 5 * (2 + 1 + 2 + 6))
})

test_that("A7-04: Vorabpauschale mehrerer Assets unabhaengig von der Reihenfolge in strategy", {
  cal <- .r7_days("2024-01-01", "2025-03-31"); t <- as.numeric(cal - cal[1]) / 365
  d <- data.frame(date = cal, A = 100 * (1 + 1.0 * pmin(t, 1)), B = 100 * (1 + 0.05 * pmin(t, 1)))
  mk <- function(ord) do.call(create_strategy, list(
    A = asset_config("etf", "bnh", share = .5, spread = 0, partial_exemption = 0),
    B = asset_config("etf", "bnh", share = .5, spread = 0, partial_exemption = 0))[ord])
  run <- function(ord) .r7_sim(d, mk(ord), start_value = 1e5, tax = tax_profile(base_rate = 2.29))
  r1 <- run(c("A", "B")); r2 <- run(c("B", "A"))
  expect_equal(tail(r1$worth, 1), tail(r2$worth, 1), tolerance = 1e-12)
  expect_equal(r1$tax_report$total_taxes_paid, r2$tax_report$total_taxes_paid, tolerance = 1e-12)
  expect_equal(sum(r1$open_lots$A$lots$units), sum(r2$open_lots$A$lots$units), tolerance = 1e-12)
  # Handrechnung: VP je Asset 500 x 100 x 0,7 x 2,29 % = 801,50; 1603 - SPB 1000 = 603 x 26,375 % = 159,04,
  # je Asset die Haelfte (79,52), dazu die Steuer der Zwangsverkaeufe (Gewinn ueber dem verbrauchten SPB)
  ex <- utils::capture.output(.r7_sim(d, mk(c("B", "A")), start_value = 1e5, tax = tax_profile(base_rate = 2.29), details = TRUE))
  vp <- grep("^Steuerereignis:\tVorabpauschale [AB] \\(festgesetzt", ex, value = TRUE)
  expect_equal(length(vp), 2)
  expect_true(all(grepl("801.50 EUR, nach TFS 801.50 EUR, SPB 500.00 EUR, Steuer 79.52 EUR", vp)))
  expect_gt(r1$tax_report$total_taxes_paid, 603 * 0.26375)
})

test_that("A7-05: mehr Kaeufe als Datentage (Lot-Liste waechst)", {
  set.seed(3); cal <- .r7_days("2024-01-01", "2024-12-31")
  d <- data.frame(date = cal, A = 100 * cumprod(1 + rnorm(length(cal), 5e-4, 0.01)))
  st <- create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0.1))
  r <- .r7_sim(d, st, start_value = 10000, costs = sim_costs(order_fee = 1, dca_fee = 0), dca = dca_plan(value = 10, span = 1, days = 1:31), tax = tax_profile(harvest = harvest_rule()))                          # vorher C++-Abbruch
  expect_true(is.finite(tail(r$worth, 1)))
  expect_gt(nrow(r$open_lots$A$lots), 0)
})

test_that("A7-06: Rebalancing mit Gewichten und Depotwert zum Tageskurs", {
  set.seed(5); cal <- .r7_days("2024-01-01", "2024-12-31")
  d <- data.frame(date = cal, A = 100 * cumprod(1 + rnorm(length(cal), 1e-3, 0.02)), B = 100 * cumprod(1 + rnorm(length(cal), 0, 0.003)))
  st <- create_strategy(A = asset_config("etf", "bnh", share = .6, spread = 0),
                        B = asset_config("etf", "bnh", share = .4, spread = 0))
  r <- .r7_sim(d, st, start_value = 10000, rebalance = rebalance_plan(unit = "month"))
  i <- which(format(cal, "%d") == "01")[-1]
  expect_equal(r$report$A$share[i], rep(0.6, length(i)), tolerance = 1e-8)    # vorher z. B. 0.594 am 1.3. (Rest: Bisektion)
  # Band: Entscheidung nach der Abweichung zum Tageskurs vor dem Handel (Bestand Vortag x Tageskurs)
  for (th in c(1, 2, 3)) {
    r5 <- .r7_sim(d, st, start_value = 10000, rebalance = rebalance_plan(unit = "month", thresh = th))
    pre <- sapply(i, function(k) { a <- r5$report$A$worth[k - 1] * d$A[k] / d$A[k - 1] + r5$report$A$money[k - 1]
                                   b <- r5$report$B$worth[k - 1] * d$B[k] / d$B[k - 1] + r5$report$B$money[k - 1]; a / (a + b) })
    done <- abs(r5$report$A$share[i] - pre) > 1e-9
    expect_identical(done, abs(pre - 0.6) > th / 100)
  }
})

test_that("A7-07: Split ohne Bestand rechnet die Kursreihe um; spaeterer Kauf innerhalb der Schwellen", {
  cal <- .r7_days("2024-01-01", "2024-12-31")
  B <- pmin(ifelse(cal < as.Date("2024-03-01"), 100, 100 * 1.02^as.numeric(cal - as.Date("2024-03-01"))), 30000)
  d <- data.frame(date = cal, A = 100, B = B, bB = cal == as.Date("2024-06-03"), sB = FALSE)
  st <- create_strategy(A = asset_config("etf", "bnh", share = .5, spread = 0),
                        B = asset_config("etf", "signal", share = .5, spread = 0, signal_buy = "bB", signal_sell = "sB"))
  r <- .r7_sim(d, st, start_value = 10000, splits = split_rule(thresh = c(50, 200)), fractions = FALSE)
  # Handrechnung: Split, sobald der Kurs 200 uebersteigt: 100 x 1,02^36 = 203,99 am 36. Tag nach dem 1.3. (6.4.)
  # und am 72. Tag (11.5.), danach je Kurs 100; am 3.6. (94. Tag) Kurs 100 x 1,02^22 = 154,60 ->
  # floor(5000 / 154,60) = 32 Stueck, Rest 52,87 EUR (vorher Kauf zu 643,30, 7 Stueck)
  k <- which(cal == as.Date("2024-06-03"))
  p <- 100 * 1.02^22; n <- floor(5000 / p)
  expect_equal(r$report$B$worth[k], n * p, tolerance = 1e-9)
  expect_equal(r$report$B$money[k], 5000 - n * p, tolerance = 1e-9)
})

test_that("A7-08: Sortino mit Downside-Abweichung \u00fcber alle Beobachtungen (wie result_analysis)", {
  set.seed(11); cal <- .r7_days("2020-01-01", "2024-12-31")
  d <- data.frame(date = cal, A = 100 * cumprod(1 + rnorm(length(cal), 3e-4, 0.01)))
  r <- .r7_sim(d, create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0)), start_value = 10000)
  rr <- diff(r$worth) / head(r$worth, -1); ppy <- length(rr) / (as.numeric(diff(range(cal))) / 365.25)
  expect_equal(r$statistics$sortino, mean(rr) * ppy / (sqrt(mean(pmin(rr, 0)^2)) * sqrt(ppy)), tolerance = 1e-12)
  expect_equal(r$statistics$sortino, unname(result_analysis(r)$metrics["sortino", 1]), tolerance = 1e-10)
})

test_that("A7-09: Signal-Asset mit offener Position legt Sparraten sofort an", {
  cal <- .r7_days("2024-01-01", "2025-12-31")
  d <- data.frame(date = cal, A = 100 * 1.0003^(seq_along(cal) - 1), buy = cal == as.Date("2024-01-02"), sell = FALSE)
  st <- create_strategy(A = asset_config("etf", "signal", share = 1, spread = 0, signal_buy = "buy", signal_sell = "sell"))
  r <- .r7_sim(d, st, start_value = 10000, dca = dca_plan(value = 500, span = 1))
  expect_equal(tail(r$report$A$money, 1), 0)                        # vorher 11 500 EUR Cash
  # am 1.1.2024 wartet das Startkapital und die erste Rate auf das Kaufsignal (2.1.)
  expect_equal(r$report$A$money[1], 10500)
  # Handrechnung: jede Rate wird am Termin zum Tageskurs angelegt -> Endwert = Stueck x Endkurs
  units <- 10500 / d$A[2] + sum(500 / d$A[which(format(cal, "%d") == "01")[-1]])
  expect_equal(tail(r$worth, 1), units * tail(d$A, 1), tolerance = 1e-9)
  # Verkaufssignal: kein Kauf am Ausstiegstag, danach wartet Geld wieder auf das Kaufsignal
  d2 <- d; d2$sell <- cal == as.Date("2025-06-01"); d2$buy <- d2$buy | cal == as.Date("2025-09-15")
  r2 <- .r7_sim(d2, st, start_value = 10000, dca = dca_plan(value = 500, span = 1))
  j <- which(cal == as.Date("2025-06-01")); m <- which(cal == as.Date("2025-09-01"))
  expect_equal(r2$report$A$worth[j], 0)
  expect_equal(r2$report$A$money[m], r2$report$A$money[j] + 3 * 500, tolerance = 1e-9)
})

test_that("A7-10: Steuer- und Schalterargumente werden geprueft (in den Bausteinen)", {
  d <- data.frame(date = .r7_days("2024-01-01", "2024-03-31"), A = 100)
  st <- create_strategy(A = asset_config("etf", "bnh", share = 1))
  f <- function(...) suppressMessages(simulation(d, st, tax = tax_profile(...)))
  expect_error(f(sparer_pauschbetrag = NA), "'sparer_pauschbetrag' muss eine einzelne endliche Zahl >= 0")
  expect_error(f(sparer_pauschbetrag = "1000"), "'sparer_pauschbetrag'")
  expect_error(f(sparer_pauschbetrag = -1000), "nicht -1000")
  expect_error(f(private_sale_threshold = "1000"), "'private_sale_threshold' muss .* nicht \"1000\"")
  expect_error(f(base_rate = c(2.29, 0)), "'base_rate' muss NULL, eine einzelne endliche Zahl")
  expect_error(f(base_rate = NA), "'base_rate'")
  expect_error(income_rate(c(20, 42)), "income_rate: 'marginal_rate'")
  expect_error(f(guenstigerpruefung = NA), "tax_profile: 'guenstigerpruefung' muss TRUE oder FALSE sein, nicht NA")
  expect_error(simulation(d, st, fractions = NA), "'fractions' muss TRUE oder FALSE sein, nicht NA")
  expect_error(dca_plan(100, 1, skip = NA), "dca_plan: 'skip' muss TRUE oder FALSE sein, nicht NA")
  expect_error(harvest_rule(loss_pot = NA), "harvest_rule: 'loss_pot' muss TRUE oder FALSE sein, nicht NA")
  expect_warning(f(base_rate = 0.0229), "base_rate = 0.0229 wird als 0.0229 % gelesen")
  expect_no_warning(f(base_rate = 0.07))                            # Basiszins 2020: 0,07 %
  expect_warning(income_rate(0.42), "income_rate: marginal_rate = 0.42 wird als 0.42 %")
  expect_warning(simulation(d, st, risk_free = 0.02), "risk_free = 0.02 wird als 0.02 %")
  expect_warning(rebalance_plan(thresh = 0.05), "rebalance_plan: thresh = 0.05 wird als 0.05 %")
  expect_no_warning(f(base_rate = -0.5))                           # negativer Basiszins erlaubt
})

test_that("A7-11: Ende 31.12.: Gewinn aus dem Zwangsverkauf f\u00fcr die VP-Steuer gehoert zum Jahr des Verkaufs", {
  cal <- .r7_days("2024-01-01", "2025-12-31")
  d <- data.frame(date = cal, A = 100 * 1.0005^(seq_along(cal) - 1))
  st <- create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0, partial_exemption = 30))
  x <- .r7_out(d, st, start_value = 1e5, tax = tax_profile(base_rate = 2.29))
  ny <- x$r$tax_report$next_year
  # VP 2025 (Zufluss 2026): Bestand am 31.12.2025 x min(P_1.1. x 0,7 x 2,29 %, P_31.12. - P_1.1.) = 1924,29 EUR,
  # nach TFS 30 % 1347,00, nach SPB 2026: 347,00 = next_year$capital_income_taxed (vorher 366,01: + Verkaufsgewinn)
  P0 <- d$A[cal == as.Date("2025-01-01")]; P1 <- tail(d$A, 1)
  vp_line <- grep("Vorabpauschale A \\(festgesetzt 2025-12-31\\)", x$out, value = TRUE)
  vp <- as.numeric(sub(".*\\): ([0-9.]+) EUR, nach TFS.*", "\\1", vp_line))
  expect_equal(vp / min(P0 * 0.7 * 0.0229, P1 - P0), 999.72, tolerance = 1e-5)      # Bestand vor dem Verkauf
  expect_lt(abs(ny$capital_income_taxed - (vp * 0.7 - 1000)), 0.005)               # vp aus der Ausgabe (2 Stellen)
  # der Zwangsverkauf vom 31.12.2025 (Gewinn nach § 19-Anrechnung 29,51 - 2,36, TFS 30 %) ist im Jahr 2025 versteuert
  # (SPB 2025 durch die VP 2024 verbraucht): Steuer 27,15 x 0,7 x 26,375 % = 5,01 EUR
  sale <- grep("=> Gewinn: 29.51 EUR; Steuer: 5.01 EUR", x$out, fixed = TRUE)
  expect_length(sale, 1L)
  expect_equal(ny$sparer_pauschbetrag_used, 1000)
})

test_that("C7-01: Listen-Strategien mit ungueltigem Regime/Klasse/Handelsart -> Fehler; Cookbook gueltig", {
  d <- data.frame(date = .r7_days("2020-01-01", "2020-03-31"), A = 100)
  mk <- function(...) list(A = modifyList(list(asset_class = "etf", trading = "bnh", share = 1, spread = 0), list(...)))
  expect_error(simulation(d, mk(tax_regime = "none"), tax = tax_profile()), "tax_regime \"none\" von Asset 'A' ist ung\u00fcltig")
  expect_error(simulation(d, mk(tax_regime = "fund")), "tax_regime \"fund\"")
  expect_error(simulation(d, mk(asset_class = "eft")), "asset_class \"eft\" von Asset 'A' ist ung\u00fcltig")
  expect_error(simulation(d, mk(trading = "hold")), "trading \"hold\"")
  expect_s3_class(simulation(d, mk(tax_regime = "capital_gains"), tax = tax_profile()), "SimLevResult")
  cb <- readLines(system.file("examples", "rebal_trigger_cookbook.R", package = "SimLev"))
  expect_false(any(grepl("tax_regime = \"none\"", cb, fixed = TRUE)))
  expect_true(any(grepl("create_strategy(", cb, fixed = TRUE)))
})

test_that("C7-04: Warnung bei wirkungslosen Argumenten; share als Prozent mit klarer Meldung", {
  d <- data.frame(date = .r7_days("2020-01-01", "2020-03-31"), A = 100)
  st <- create_strategy(A = asset_config("etf", "bnh", share = 1))
  expect_warning(rebalance_plan(event_mode = "replace"), "rebalance_plan: event_mode wirkt nur zusammen mit event_col")
  expect_warning(rebalance_plan(event_weight = c(A = "wA")), "rebalance_plan: event_weight wirkt nur zusammen mit event_col")
  expect_no_warning(simulation(d, st, rebalance = rebalance_plan(thresh = 5)))
  expect_error(asset_config("etf", share = 70), "nicht 70; f\u00fcr 70 % share = 0.7 angeben")
})

test_that("C7-06: summary() druckt nicht, print.summary.SimLevResult gibt die Zusammenfassung aus", {
  set.seed(7); d <- data.frame(date = .r7_days("2021-01-01", "2022-05-15"))
  d$ETF <- 100 * cumprod(1 + rnorm(nrow(d), 4e-4, 0.012))
  r <- simulation(d, create_strategy(ETF = asset_config("etf", share = 1, partial_exemption = 30)))
  expect_silent(s <- summary(r))
  expect_s3_class(s, "summary.SimLevResult")
  out <- capture.output(print(s))
  expect_true(any(grepl("SimLev Zusammenfassung", out))); expect_true(any(grepl("^  Sharpe ", out)))
  expect_identical(capture.output(summary(r)), out)                # Konsole: summary(x) zeigt wie bisher
  expect_identical(withVisible(summary(r))$visible, TRUE)
  expect_identical(withVisible(print(s))$visible, FALSE)
  expect_true(all(c("total_return_twr", "return_on_invested", "undefined_metrics", "tax_report") %in% names(s)))
})

test_that("R8-04: keine Anteil-Warnung bei realistischen kleinen Prozentwerten", {
  d <- data.frame(date = .r7_days("2016-01-01", "2016-06-30"), A = 100, B = 50)
  st <- create_strategy(A = asset_config("etf", "bnh", share = .6), B = asset_config("etf", "bnh", share = .4))
  expect_no_warning(simulation(d, st, risk_free = 0.25))                          # Geldmarkt 2016-2019: 0,25 % p. a.
  expect_no_warning(simulation(d, st, rebalance = rebalance_plan(thresh = 0.5))) # Band 0,5 Prozentpunkte
  expect_no_warning(suppressMessages(simulation(d, st, tax = tax_profile(base_rate = 0.07))))   # Basiszins 2020
  expect_warning(simulation(d, st, risk_free = 0.02), "risk_free = 0.02 wird als 0.02 % gelesen")
  expect_warning(rebalance_plan(thresh = 0.05), "thresh = 0.05 wird als 0.05 %")
  expect_warning(income_rate(marginal_rate = 0.42), "marginal_rate = 0.42")
})

test_that("R8-05: erster Tag mit balance_mode ohne Doppelorders", {
  set.seed(1); cal <- .r7_days("2024-01-15", "2024-03-31")
  d <- data.frame(date = cal, A = 100 * cumprod(1 + rnorm(length(cal), 0, 0.01)), B = 50, C = 80)
  st <- create_strategy(A = asset_config("etf", "bnh", share = .4, spread = 1),
                        B = asset_config("etf", "bnh", share = .3, spread = 0),
                        C = asset_config("etf", "bnh", share = .3, spread = 0))
  x <- .r7_out(d, st, start_value = 10000, costs = sim_costs(order_fee = 5), rebalance = rebalance_plan(unit = "month"))
  day1 <- grep("am 2024-01-15", x$out, value = TRUE)
  expect_equal(sum(grepl("\t(Kauf|Verkauf) [0-9]", day1)), 3)            # vorher 3 Kaeufe + 2 Verkaeufe
  # Gebuehren: Tag 1 3 Orders, Termine 1.2. und 1.3. Umschichtung (Kurs A schwankt): je 1 Verkauf + 2 Kaeufe bzw.
  # 2 Verkaeufe + 1 Kauf -> 3 + 3 + 3 = 9 Orders x 5 EUR (vorher 11 Orders = 55 EUR)
  expect_equal(x$r$fees_paid, 45)
  # ohne Kosten (kein Spread, keine Gebuehr) ist das Ergebnis dasselbe wie mit dem bisherigen Ablauf:
  # Erstkauf je Asset mit dem eigenen Startkapital (Ziel 40/30/30)
  st0 <- create_strategy(A = asset_config("etf", "bnh", share = .4, spread = 0),
                         B = asset_config("etf", "bnh", share = .3, spread = 0),
                         C = asset_config("etf", "bnh", share = .3, spread = 0))
  r0 <- .r7_sim(d, st0, start_value = 10000, rebalance = rebalance_plan(unit = "month"))
  r1 <- .r7_sim(d, st0, start_value = 10000)
  expect_equal(r0$report$A$worth[1:17], r1$report$A$worth[1:17], tolerance = 1e-12)   # bis vor dem ersten Termin (1.2.)
  expect_equal(r0$report$B$share[1], 0.3, tolerance = 1e-12)
})
