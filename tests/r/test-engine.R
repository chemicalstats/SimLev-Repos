# test-engine.R (T20)
# Engine mit Handrechnungen: Erweiterungen (Tarif, undefined_metrics, summary, Bausteine, open_lots), Restbefunde, Verlustvortrag und zuflussbereinigte Kennzahlen.
# Zusammengeführt aus test-engine-notes.R, test-engine-rest.R, test-flow-metrics.R (Inhalt wörtlich; Hilfsnamen je Teil eindeutig).
testthat::local_edition(3)   # T20: Edition 3 wie bisher (Config/testthat/edition in r/DESCRIPTION entfällt)

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# bis T20 test-engine-notes.R
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Engine-Erweiterungen: A Einkommensteuertarif (taxable_income), B undefined_metrics, C summary-Renditen,
# D Bausteine (ohne den alten Fondsmodus), E open_lots
.en_days <- function(a, b) seq.Date(as.Date(a), as.Date(b), by = "day")
.en_sim <- function(...) suppressWarnings(suppressMessages(simulation(...)))
# Unabhaengige Handrechnung § 32a Abs. 1 EStG (VZ 2026) fuer Erwartungswerte
.en_T <- function(x) {
  x <- floor(max(0, x))
  t <- if (x <= 12348) 0 else if (x <= 17799) { y <- (x - 12348) / 1e4; (914.51 * y + 1400) * y } else
    if (x <= 69878) { z <- (x - 17799) / 1e4; (173.10 * z + 2397) * z + 1034.87 } else
    if (x <= 277825) 0.42 * x - 11135.63 else 0.45 * x - 19470.38
  floor(t)
}
# Lieferbares ETC G (§ 23): 50 Stueck zu 100, am 1.7.2020 zu p2 alles nach H umgeschichtet (Gewinn 50 x (p2 - 100))
.en_p23 <- function(p2 = 150, end = "2021-03-31", tax = tax_profile(), ...) {
  d <- .en_days("2020-01-01", end)
  df <- data.frame(date = d, G = ifelse(d < as.Date("2020-06-01"), 100, p2), H = 50)
  df$ev <- d == as.Date("2020-07-01"); df$wG <- 0; df$wH <- 1
  st <- create_strategy(G = asset_config("etc", "bnh", share = 0.5, spread = 0, deliverable = TRUE),
                        H = asset_config("certificate", "bnh", share = 0.5, spread = 0))
  .en_sim(df, st, start_value = 1e4, rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(G = "wG", H = "wH")), tax = tax, ...)
}
# Zertifikat Z (§ 20): 200 Stueck zu 50, am 1.7.2020 zu 70 nach M umgeschichtet -> Gewinn 4000, nach SPB K = 3000
.en_gp <- function(end = "2021-03-31", pz = 70, tax = tax_profile(), ...) {
  d <- .en_days("2020-01-01", end)
  df <- data.frame(date = d, Z = ifelse(d < as.Date("2020-06-01"), 50, pz), M = 100)
  df$ev <- d == as.Date("2020-07-01"); df$wZ <- 0; df$wM <- 1
  st <- create_strategy(Z = asset_config("certificate", "bnh", share = 0.5, spread = 0),
                        M = asset_config("certificate", "bnh", share = 0.5, spread = 0))
  .en_sim(df, st, start_value = 2e4, rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(Z = "wZ", M = "wM")), tax = tax, ...)
}

# ---------------------------------------------------------------- A a) § 23 mit Tarif
test_that("A a) § 23-Steuer mit Tarif: ESt-Zuwachs, Soli-Zuwachs exakt, KiSt 9 %", {
  # zvE 74 000, Gewinn 2500: T(76 500) - T(74 000) = 20 994 - 19 944 = 1050; Soli S(20 994) - S(19 944)
  # = 0,119 x (20 994 - 20 350) = 76,636 -> 76,63 - 0; KiSt 9 % x 1050 = 94,50 -> 1221,13
  r <- .en_p23(tax = tax_profile(church_tax = 9, income = income_tariff(taxable_income = 74000)))
  ty <- r$tax_report$tariff_years
  # 2021: die am 1.1.2021 gezahlte KiSt 94,50 ist Sonderausgabe 2021 (Zahlungsjahr): zvE 73 905,50 ->
  # T(73 905) = 19 904 statt 19 944 -> Wirkung (19 904 - 19 944) x 1,09 = -43,60 (Erstattung am Ende)
  expect_equal(ty$church_tax_paid_deductible[2], 94.5); expect_equal(ty$deduction_effect[2], -43.6)
  expect_equal(ty$settlement, c(1221.13, -43.6))
  expect_equal(r$tax_report$total_taxes_paid, 1221.13 - 43.6)
  expect_equal(tail(r$worth, 1), 12500 - 1221.13 + 43.6)
  expect_equal(ty$year, c(2020L, 2021L))
  expect_equal(unlist(ty[1, c("gain_p23", "income_tax_p23", "soli_p23", "church_tax_p23", "tax_p23")]),
               c(gain_p23 = 2500, income_tax_p23 = 1050, soli_p23 = 76.63, church_tax_p23 = 94.5, tax_p23 = 1221.13))
  # zvE 50 000 ohne KiSt: T(52 500) - T(50 000) = 11 437 - 10 548 = 889, Soli 0 (ESt unter 20 350)
  expect_equal(.en_p23(tax = tax_profile(income = income_tariff(taxable_income = 50000)))$tax_report$total_taxes_paid, .en_T(52500) - .en_T(50000))
  expect_equal(.en_T(52500) - .en_T(50000), 889)
})

test_that("A a) Soli-Freigrenze knapp unter/\u00fcber (ESt 20 350 bzw. 20 351)", {
  # zvE 72 466 + 2500 = 74 966: ESt 20 350 (nicht ueber der Freigrenze) -> Soli 0; ESt-Zuwachs 20 350 - 19 300
  r0 <- .en_p23(tax = tax_profile(income = income_tariff(taxable_income = 72466)))
  expect_equal(r0$tax_report$total_taxes_paid, 1050)
  expect_equal(r0$tax_report$tariff_years$soli_p23[1], 0)
  # zvE 72 469 + 2500 = 74 969: ESt 20 351 -> Soli 0,119 x 1 = 0,119 -> 0,11; ESt-Zuwachs 20 351 - 19 301
  r1 <- .en_p23(tax = tax_profile(income = income_tariff(taxable_income = 72469)))
  expect_equal(r1$tax_report$total_taxes_paid, 1050.11)
})

test_that("A a) Freigrenze § 23 (1000 EUR) mit Tarif", {
  # Gewinn 50 x 19,98 = 999 < 1000: steuerfrei; 50 x 20 = 1000: steuerpflichtig T(51 000) - T(50 000)
  r <- .en_p23(p2 = 119.98, tax = tax_profile(income = income_tariff(taxable_income = 50000)))
  expect_equal(r$tax_report$total_taxes_paid, 0)
  expect_equal(r$tax_report$tariff_years$gain_p23[1], 0)
  r2 <- .en_p23(p2 = 120, tax = tax_profile(income = income_tariff(taxable_income = 50000)))
  expect_equal(r2$tax_report$total_taxes_paid, .en_T(51000) - .en_T(50000))
  expect_equal(r2$tax_report$tariff_years$gain_p23[1], 1000)
})

test_that("A a) Verlustjahr § 23: Vortrag mindert den Tarifgewinn des Folgejahres", {
  # 2020: G 100 -> 70 am 2.3. verkauft (Verlust 1500), am 1.6. wieder gekauft (4250 / 70 Stueck);
  # 2021: Verkauf zu 140 am 1.4. (Haltedauer < 1 Jahr): Gewinn 4250 - Vortrag 1500 = 2750
  d <- .en_days("2020-01-01", "2021-06-30")
  df <- data.frame(date = d, G = ifelse(d < as.Date("2020-03-01"), 100, ifelse(d < as.Date("2021-03-01"), 70, 140)), H = 50)
  ev <- as.Date(c("2020-03-02", "2020-06-01", "2021-04-01"))
  df$ev <- d %in% ev; df$wG <- ifelse(d == ev[2], 0.5, 0); df$wH <- 1 - df$wG
  st <- create_strategy(G = asset_config("etc", "bnh", share = 0.5, spread = 0, deliverable = TRUE),
                        H = asset_config("certificate", "bnh", share = 0.5, spread = 0))
  r <- .en_sim(df, st, start_value = 1e4, rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(G = "wG", H = "wH")), tax = tax_profile(income = income_tariff(taxable_income = 50000)))
  ty <- r$tax_report$tariff_years
  expect_equal(ty$tax_p23, c(0, .en_T(52750) - .en_T(50000)))
  expect_equal(ty$gain_p23, c(0, 2750))
  expect_equal(tail(r$worth, 1), 8500 + 4250 - (.en_T(52750) - .en_T(50000)), tolerance = 1e-9)
})

test_that("A Pruefungen: taxable_income-Formen, fehlendes Jahr, Warnungen", {
  d1 <- .en_p23(tax = tax_profile(income = income_tariff(taxable_income = 74000)))$tax_report$total_taxes_paid
  expect_equal(.en_p23(tax = tax_profile(income = income_tariff(taxable_income = c("2020" = 74000, "2021" = 1))))$tax_report$total_taxes_paid, d1)
  expect_equal(.en_p23(tax = tax_profile(income = income_tariff(taxable_income = data.frame(year = 2020:2021, taxable_income = 74000))))$tax_report$total_taxes_paid, d1)
  expect_error(.en_p23(tax = tax_profile(income = income_tariff(taxable_income = c("2020" = 74000)))), "taxable_income fehlt f\u00fcr Simulationsjahr 2021")
  expect_error(.en_p23(tax = tax_profile(income = income_tariff(taxable_income = c(1, 2)))), "muss nach Kalenderjahren benannt sein")
  expect_error(.en_p23(tax = tax_profile(income = income_tariff(taxable_income = c("2020" = 1, "x" = 2)))), "Name 'x' ist kein Kalenderjahr")
  expect_error(.en_p23(tax = tax_profile(income = income_tariff(taxable_income = NA_real_))), "ung\u00fcltigen Wert")
  expect_error(.en_p23(tax = tax_profile(income = income_tariff(taxable_income = "50000"))), "taxable_income muss eine Zahl")
  # income_rate() und income_tariff() schliessen sich aus (ein Baustein in tax_profile(income =))
  expect_error(tax_profile(income = list(income_rate(42), income_tariff(50000))), "schlie\u00dfen sich aus")
  expect_error(tax_profile(income = 42), "income muss NULL, ein Objekt aus income_rate\\(\\) oder aus income_tariff\\(\\)")
  expect_equal(.en_p23(tax = tax_profile(income = income_tariff(taxable_income = 74000)))$tax_report$total_taxes_paid, d1)
  expect_error(income_tariff(), "taxable_income .* fehlt")
  expect_error(income_tariff(50000, tariff = 42), "income_tariff: tariff muss NULL")
})

# ---------------------------------------------------------------- A b) Guenstigerpruefung
test_that("A b) G\u00fcnstigerpr\u00fcfung: Erstattung am Abrechnungstag im Endwert", {
  # K = 4000 - SPB 1000 = 3000, Abgeltungsteuer 3000 x 26,375 % = 791,25; Tarif T(13 000) - T(10 000) = 95
  # (y = 0,0652: 95,17 -> 95) -> Erstattung 696,25 am 1.1.2021 (Abrechnungstag)
  r <- .en_gp(tax = tax_profile(guenstigerpruefung = TRUE, income = income_tariff(taxable_income = 10000)))
  ty <- r$tax_report$tariff_years
  expect_equal(ty$capital_income[1], 3000)
  expect_equal(ty$abgeltung_burden[1], 791.25)
  expect_equal(ty$tariff_burden[1], 95)
  expect_true(ty$guenstiger[1]); expect_equal(ty$refund[1], 696.25)
  expect_equal(r$tax_report$total_taxes_paid, 95)
  i <- match(as.Date(c("2020-12-31", "2021-01-01")), r$dates)
  expect_equal(diff(r$worth[i]), 696.25)
  expect_equal(tail(r$worth, 1), 24000 - 95)
  # Jahr ohne Kapitalertraege (2021): K = 0, keine Erstattung
  expect_equal(unlist(ty[2, c("capital_income", "abgeltung_burden", "refund")]), c(capital_income = 0, abgeltung_burden = 0, refund = 0))
  # ohne Guenstigerpruefung: Abgeltungsteuer bleibt
  r0 <- .en_gp(tax = tax_profile(income = income_tariff(taxable_income = 10000)))
  expect_equal(r0$tax_report$total_taxes_paid, 791.25); expect_true(is.na(r0$tax_report$tariff_years$tariff_burden[1]))
  # hohes zvE: ESt 0,42 x 3000 = 1260 (32 124 - 30 864), Soli-Zuwachs (Milderungszone) 0,119 x 11 774 = 1401,10
  # minus 0,119 x 10 514 = 1251,16 -> 149,94; Tarif 1409,94 > 791,25 -> keine Erstattung
  rh <- .en_gp(tax = tax_profile(guenstigerpruefung = TRUE, income = income_tariff(taxable_income = 100000)))
  expect_false(rh$tax_report$tariff_years$guenstiger[1]); expect_equal(rh$tax_report$tariff_years$tariff_burden[1], 1409.94)
  expect_equal(rh$tax_report$total_taxes_paid, 791.25)
})

test_that("A b) G\u00fcnstigerpr\u00fcfung im finalen Jahresabschluss und mit KiSt 9 %", {
  # Datenende 2020-12-30: Erstattung am letzten Tag, im Endwert enthalten
  r <- .en_gp(end = "2020-12-30", tax = tax_profile(guenstigerpruefung = TRUE, income = income_tariff(taxable_income = 10000)))
  expect_equal(tail(r$worth, 1), 24000 - 95)
  # KiSt 9 %: Abgeltungsteuer 3000 x 25 % / 1,0225 x 1,145 = 839,85, darin KiSt 3000 x 25 % / 1,0225 x 9 % = 66,01;
  # mit Guenstigerpruefung ist diese KiSt 2020 Sonderausgabe: zvE 10 000 - 66,01 + K 3000 = 12 933 -> T = 85
  # (y = 0,0585), KiSt 7,65 -> Belastung 92,65 < 839,85 -> Erstattung 747,20; KiSt-Bescheid 7,65 - 66,01 = -58,36
  # (Erstattung 2021 -> Hinzurechnung 2021: zvE 10 058,36, T weiter 0)
  rk <- .en_gp(tax = tax_profile(church_tax = 9, guenstigerpruefung = TRUE, income = income_tariff(taxable_income = 10000)))
  abg <- 3000 * 0.25 / (1 + 0.25 * 0.09) * (1 + 0.055 + 0.09); kabg <- 3000 * 0.25 / (1 + 0.25 * 0.09) * 0.09
  ty <- rk$tax_report$tariff_years
  expect_equal(ty$abgeltung_burden[1], abg); expect_equal(ty$church_tax_withheld_k[1], kabg)
  expect_equal(ty$church_tax_paid_deductible[1], kabg); expect_equal(ty$taxable_income_net[1], 10000 - kabg)
  expect_equal(ty$burden_with_gp[1], 92.65); expect_equal(ty$tariff_burden[1], 92.65)
  expect_equal(ty$refund[1], abg - 92.65)
  expect_equal(ty$church_tax_settlement_next_year[1], 7.65 - kabg)
  expect_equal(ty$church_tax_refunded[2], kabg - 7.65); expect_equal(ty$church_tax_net_deduction[2], 7.65 - kabg)
  expect_equal(ty$taxable_income_net[2], 10000 + kabg - 7.65)
  # Verlustjahr (Kurs 50 -> 30): K = 0, keine Erstattung
  rl <- .en_gp(pz = 30, tax = tax_profile(guenstigerpruefung = TRUE, income = income_tariff(taxable_income = 10000)))
  expect_equal(rl$tax_report$tariff_years$capital_income[1], 0); expect_equal(rl$tax_report$tariff_years$refund[1], 0)
})

test_that("A b) Vorabpauschale nach dem letzten Jahresabschluss: G\u00fcnstigerpr\u00fcfung des Folgejahres", {
  # ETF 1 Mio. EUR, Kurs 100 -> 120, Basiszins 2,29 %: VP = 1e6 x 0,0229 x 0,7 = 16 030 (Zufluss 2021, Abrechnung am
  # letzten Tag mit Zwangsverkauf). K = per Saldo mit Abgeltungsteuer belastete Bemessungsgrundlage 2021 = VP nach TFS
  # und SPB 10 221 (A7-11: der Gewinn des Zwangsverkaufs am 31.12.2020 gehoert zu 2020, dort im SPB) = gezahlte
  # Abgeltungsteuer des Laufs ohne Tarif / 26,375 %;
  # Tarif T(10 000 + K) - T(10 000) (ESt unter der Soli-Freigrenze) -> Erstattung im Endwert
  d <- .en_days("2020-01-01", "2020-12-31")
  df <- data.frame(date = d, A = 100 + 20 * (seq_along(d) - 1) / (length(d) - 1))
  st <- create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0, partial_exemption = 30))
  r <- .en_sim(df, st, start_value = 1e6, tax = tax_profile(base_rate = 2.29, guenstigerpruefung = TRUE, income = income_tariff(taxable_income = 10000)))
  r0 <- .en_sim(df, st, start_value = 1e6, tax = tax_profile(base_rate = 2.29))
  ty <- r$tax_report$tariff_years
  expect_equal(ty$year, c(2020L, 2021L))
  abg <- r0$tax_report$total_taxes_paid; k <- abg / 0.26375
  expect_equal(k, 16030 * 0.7 - 1000, tolerance = 1e-9)
  expect_equal(ty$capital_income[2], k, tolerance = 1e-9)
  expect_equal(ty$abgeltung_burden[2], abg, tolerance = 1e-9)
  expect_equal(ty$tariff_burden[2], .en_T(10000 + k) - .en_T(10000))
  expect_equal(ty$refund[2], abg - (.en_T(10000 + k) - .en_T(10000)), tolerance = 1e-9)
  expect_equal(tail(r$worth, 1) - tail(r0$worth, 1), ty$refund[2], tolerance = 1e-6)
  expect_equal(r$tax_report$total_taxes_paid, abg - ty$refund[2], tolerance = 1e-9)
})

# ---------------------------------------------------------------- A c) KiSt als Sonderausgabe
test_that("A c) KiSt auf die § 23-ESt ist Sonderausgabe im Zahlungsjahr (Folgejahr), KiSt auf Abgeltungsteuer nicht", {
  # 2020: Gewinn 2500, zvE 50 000: ESt 889, KiSt 80,01, gezahlt am 1.1.2021 -> Sonderausgabe 2021;
  # 2021: G zu 150 gekauft (6250 EUR), am 1.1.2021 Steuer 969,01 aus G (Verkauf ohne Gewinn), Rest zu 200 verkauft:
  # Gewinn (6250 - 969,01) / 3; Veranlagung 2021: F(60 000 - 80,01 + G) - F(60 000), F = T x 1,09 (Soli 0)
  d <- .en_days("2020-01-01", "2021-12-31")
  df <- data.frame(date = d, G = ifelse(d < as.Date("2020-06-01"), 100, ifelse(d < as.Date("2021-06-01"), 150, 200)), H = 50)
  df$ev <- d %in% as.Date(c("2020-07-01", "2020-08-01", "2021-07-01"))
  df$wG <- ifelse(d == as.Date("2020-08-01"), 0.5, 0); df$wH <- 1 - df$wG
  st <- create_strategy(G = asset_config("etc", "bnh", share = 0.5, spread = 0, deliverable = TRUE),
                        H = asset_config("certificate", "bnh", share = 0.5, spread = 0))
  r <- .en_sim(df, st, start_value = 1e4, rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(G = "wG", H = "wH")), tax = tax_profile(church_tax = 9, income = income_tariff(taxable_income = c("2020" = 50000, "2021" = 60000))))
  ty <- r$tax_report$tariff_years
  t1 <- 889 * 1.09; k1 <- 889 * 0.09
  expect_equal(ty$tax_p23[1], t1)
  expect_equal(ty$church_tax_net_deduction, c(0, k1)); expect_equal(ty$church_tax_settlement_next_year[1], k1)
  g2 <- (6250 - t1) / 3; base <- 60000 - k1
  expect_equal(ty$gain_p23[2], g2, tolerance = 1e-9)
  expect_equal(ty$tax_p23[2], (.en_T(base + g2) - .en_T(base)) * 1.09)
  expect_equal(ty$deduction_effect[2], (.en_T(base) - .en_T(60000)) * 1.09)
  expect_equal(ty$settlement[2], (.en_T(base + g2) - .en_T(60000)) * 1.09)
  expect_equal(r$tax_report$total_taxes_paid, t1 + (.en_T(base + g2) - .en_T(60000)) * 1.09)
  # KiSt auf die Abgeltungsteuer ohne Guenstigerpruefung (§ 10 Abs. 1 Nr. 4, 2. Halbsatz EStG): kein Abzug
  rg <- .en_gp(tax = tax_profile(church_tax = 9, income = income_tariff(taxable_income = 10000)))
  expect_equal(rg$tax_report$tariff_years$church_tax_net_deduction, c(0, 0))
  expect_equal(rg$tax_report$tariff_years$settlement, c(0, 0))
})

test_that("A c) KiSt bei G\u00fcnstigerpr\u00fcfung \u00fcber drei Jahre: Abzug, Verrechnung der Erstattung, Hinzurechnung", {
  # Z: 200 Stueck zu 50; 2020 zu 70 verkauft (K 2020 = 4000 - SPB = 3000), 1.8.2020 wieder gekauft, 2021 zu 90 verkauft
  # (K 2021 laut Zeile), 2022 ohne Ertraege; zvE 14 000, KiSt 9 %, F(x) = T(x) x 1,09 (Soli 0)
  d <- .en_days("2020-01-01", "2022-12-31")
  df <- data.frame(date = d, Z = ifelse(d < as.Date("2020-06-01"), 50, ifelse(d < as.Date("2021-06-01"), 70, 90)), M = 100)
  ev <- as.Date(c("2020-07-01", "2020-08-01", "2021-07-01"))
  df$ev <- d %in% ev; df$wZ <- ifelse(d == ev[2], 1, 0); df$wM <- 1 - df$wZ
  st <- create_strategy(Z = asset_config("certificate", "bnh", share = 0.5, spread = 0),
                        M = asset_config("certificate", "bnh", share = 0.5, spread = 0))
  r <- .en_sim(df, st, start_value = 2e4, rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(Z = "wZ", M = "wM")), tax = tax_profile(church_tax = 9, guenstigerpruefung = TRUE, income = income_tariff(taxable_income = 14000)))
  ty <- r$tax_report$tariff_years
  q <- 0.25 / 1.0225; rate <- q * (1 + 0.055 + 0.09); F <- function(x) .en_T(x) * 1.09
  expect_equal(ty$year, 2020:2022)
  # 2020 (t): GP guenstiger; einbehaltene KiSt auf K 3000 x q x 9 % = 66,01 ist Sonderausgabe 2020 ->
  # T(13 933) = 244 (y = 0,1585), T(16 933) = 834, T(14 000) = 256: Belastung (834 - 256) x 1,09 = 630,02
  # < 839,85 -> Erstattung 209,83; KiSt-Bescheid 0,09 x 578 - 66,01 = -13,99 (Erstattung 2021)
  kabg1 <- 3000 * q * 0.09
  expect_equal(c(.en_T(13933), .en_T(16933), .en_T(14000)), c(244, 834, 256))
  expect_true(ty$guenstiger[1]); expect_equal(ty$church_tax_paid_deductible[1], kabg1)
  expect_equal(ty$burden_with_gp[1], 630.02); expect_equal(ty$burden_without_gp[1], 3000 * rate)
  expect_equal(ty$settlement[1], 630.02 - 3000 * rate)
  ks1 <- 0.09 * 578 - kabg1
  expect_equal(ty$church_tax_settlement_next_year[1], ks1)
  # 2021 (t+1): Erstattung 13,99 wird mit der 2021 einbehaltenen KiSt auf K (Sonderausgabe, GP guenstiger) verrechnet
  k2 <- ty$capital_income[2]; kabg2 <- k2 * q * 0.09
  expect_gt(k2, 0)
  expect_equal(ty$church_tax_refunded[2], -ks1); expect_equal(ty$church_tax_paid_deductible[2], kabg2)
  expect_equal(ty$church_tax_net_deduction[2], kabg2 + ks1)
  b2 <- 14000 - ks1 - kabg2
  expect_equal(ty$burden_with_gp[2], F(b2 + k2) - F(14000))
  expect_equal(ty$burden_without_gp[2], F(14000 - ks1) - F(14000) + k2 * rate)
  expect_equal(ty$settlement[2], F(b2 + k2) - F(14000) - k2 * rate)
  ks2 <- 0.09 * (.en_T(b2 + k2) - .en_T(14000)) - kabg2
  expect_lt(ks2, 0); expect_equal(ty$church_tax_settlement_next_year[2], ks2)
  # 2022 (t+2): Erstattung ohne andere KiSt-Zahlung -> Ueberhang dem Einkommen hinzugerechnet (§ 10 Abs. 4b Satz 3)
  expect_equal(ty$church_tax_paid_deductible[3], 0); expect_equal(ty$church_tax_refunded[3], -ks2)
  expect_equal(ty$taxable_income_net[3], 14000 - ks2)
  expect_equal(ty$settlement[3], F(14000 - ks2) - F(14000)); expect_gt(ty$settlement[3], 0)
  expect_equal(r$tax_report$total_taxes_paid, 3000 * rate + k2 * rate + sum(ty$settlement), tolerance = 1e-9)
})

test_that("A e) details = TRUE zeigt die Tarifrechnung", {
  out <- capture.output(.en_gp(tax = tax_profile(guenstigerpruefung = TRUE, income = income_tariff(taxable_income = 10000)), details = TRUE))
  expect_true(any(grepl("Tarif 2020: zvE 10000.00 EUR - KiSt-Sonderausgaben 0.00 EUR (gezahlt 0.00, erstattet 0.00) = 10000.00 EUR", out, fixed = TRUE)))
  expect_true(any(grepl("K 3000.00 EUR, Abgeltungsteuer 791.25 EUR .*Tarif auf K 95.00 EUR .*-> Tarif", out)))
  expect_true(any(grepl("Abrechnung: Erstattung 696.25 EUR", out, fixed = TRUE)))
  expect_true(any(grepl("Erstattung 696.25 EUR in den Geldbestand am 2021-01-01", out, fixed = TRUE)))
})

# ---------------------------------------------------------------- B undefined_metrics
.en_r405 <- function(tax = tax_profile(income = income_rate(marginal_rate = 42)), ...) {
  d <- .en_days("2020-01-01", "2021-06-30")
  df <- data.frame(date = d, G = ifelse(d < as.Date("2020-06-01"), 100, 150), H = ifelse(d < as.Date("2020-10-01"), 50, 1))
  df$ev <- d == as.Date("2020-07-01"); df$wG <- 0; df$wH <- 1
  st <- create_strategy(G = asset_config("etc", "bnh", share = 0.5, spread = 0, deliverable = TRUE),
                        H = asset_config("certificate", "bnh", share = 0.5, spread = 0))
  w <- character(0)
  r <- withCallingHandlers(suppressMessages(simulation(df, st, start_value = 1e4, rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(G = "wG", H = "wH")), tax = tax, ...)),
         warning = function(x) { w <<- c(w, conditionMessage(x)); invokeRestart("muffleWarning") })
  list(r = r, w = w)
}
.um <- function(r, m) r$undefined_metrics[r$undefined_metrics$metric == m, ]

test_that("B negative_end_value: Feld, open_tax_debt, print/summary-Text, Warnung (R4-05)", {
  x <- .en_r405(); r <- x$r
  expect_equal(tail(r$worth, 1), -800)                                  # Endwert unveraendert
  expect_true(is.na(r$cagr) && is.na(r$ttwror))
  expect_equal(r$tax_report$open_tax_debt, 800)
  expect_equal(.um(r, "cagr")$reason, "negative_end_value")
  expect_equal(.um(r, "cagr")$detail, "Endwert -800.00 EUR negativ: offene Steuerschuld 800.00 EUR")
  expect_equal(.um(r, "ttwror")$reason, "negative_end_value")
  expect_equal(.um(r, "calmar")$reason, "negative_end_value")          # vererbt von cagr
  expect_match(.um(r, "calmar")$detail, "^cagr nicht definiert: Endwert -800.00 EUR")
  expect_true(any(grepl("Endwert negativ (-800.00 EUR, offene Steuerschuld 800.00 EUR)", x$w, fixed = TRUE)))
  out <- capture.output(print(r))
  expect_true(any(grepl("CAGR:             nicht definiert (Endwert -800.00 EUR negativ: offene Steuerschuld 800.00 EUR)", out, fixed = TRUE)))
  expect_true(any(grepl("  Steuerschuld:     800.00 EUR (offen, nicht gedeckt)", out, fixed = TRUE)))   # Spalte wie die uebrigen Zeilen
  expect_false(any(grepl("NA", out)))
  out_s <- capture.output(summary(r))
  expect_true(any(grepl("TTWROR:           nicht definiert (Endwert -800.00 EUR negativ", out_s, fixed = TRUE)))
})

test_that("B nonpositive_twr_index und no_recovery: Steuerschuld, danach Einzahlungen", {
  x <- .en_r405(dca = dca_plan(value = 1000, span = 1, start = as.Date("2021-03-01"))); r <- x$r
  expect_gt(tail(r$worth, 1), 0)
  expect_true(is.na(r$ttwror))
  expect_equal(.um(r, "ttwror")$reason, "nonpositive_twr_index")
  expect_match(.um(r, "ttwror")$detail, "Wertindex am 2021-01-01 nicht positiv")
  expect_equal(.um(r, "avg_recovery_time")$reason, "no_recovery")
  expect_match(.um(r, "avg_recovery_time")$detail, "nicht aufgeholt")
})

test_that("B no_irr_solution: Einzahlung am letzten Tag gr\u00f6\u00dfer als der Endwert (Steuerschuld)", {
  # R4-05 mit einer Sparrate 1000 am letzten Tag (nicht mehr angelegt): Endwert -800 + 1000 = 200 > 0, aber
  # 10 000 (1 + r)^T + 1000 = 200 hat keine Loesung
  x <- .en_r405(dca = dca_plan(value = 1000, span = 1, days = 30, start = as.Date("2021-06-01"))); r <- x$r
  expect_equal(tail(r$worth, 1), 200)
  expect_true(is.na(r$cagr))
  expect_equal(.um(r, "cagr")$reason, "no_irr_solution")
  expect_equal(.um(r, "cagr")$detail, "kein interner Zinsfu\u00df: Startwert 10000.00 EUR, Einzahlungen 1000.00 EUR, Endwert 200.00 EUR")
  expect_true(any(grepl("kein interner Zinsfu\u00df gefunden", x$w)))
  expect_true(any(grepl("CAGR:             nicht definiert (kein interner Zinsfu\u00df", capture.output(print(r)), fixed = TRUE)))
})

test_that("B too_short: Einzeltag und zwei Tage", {
  df <- data.frame(date = as.Date("2020-01-01"), A = 100)
  st <- create_strategy(A = asset_config("etf", "bnh", share = 1))
  expect_warning(r <- simulation(df, st), "Zeitraum 1 Tag \\(Laufzeit 0 Jahre\\): cagr und ttwror sind nicht definiert")
  expect_equal(.um(r, "cagr")$reason, "too_short"); expect_equal(.um(r, "ttwror")$reason, "too_short")
  expect_equal(.um(r, "skewness")$detail, "keine Tagesrendite (Einzeltag)")
  # R5-04: buys/sells NA (vorher NaN) und in undefined_metrics; avg_recovery_time ebenfalls too_short
  expect_true(is.na(r$buys[["A"]]) && !is.nan(r$buys[["A"]])); expect_true(is.na(r$sells[["A"]]) && !is.nan(r$sells[["A"]]))
  expect_equal(.um(r, "buys")$reason, "too_short"); expect_equal(.um(r, "sells")$reason, "too_short")
  expect_equal(.um(r, "avg_recovery_time")$reason, "too_short")
  expect_identical(tail(r$undefined_metrics$metric, 2), c("buys", "sells"))
  out <- capture.output(print(r))
  expect_true(any(grepl("CAGR:             nicht definiert (Zeitraum 1 Tag, Laufzeit 0 Jahre (Einzeltag))", out, fixed = TRUE)))
  r2 <- simulation(data.frame(date = .en_days("2020-01-01", "2020-01-02"), A = c(100, 101)), st)
  expect_equal(.um(r2, "skewness")$detail, "nur 1 Tagesrendite, mindestens 3 n\u00f6tig")
  expect_equal(.um(r2, "kurtosis")$reason, "too_short"); expect_equal(.um(r2, "sharpe")$reason, "too_short")
  expect_false(any(c("cagr", "buys", "sells") %in% r2$undefined_metrics$metric))
})

test_that("B zero_volatility, zero_mean_return (konstanter Kurs)", {
  r <- simulation(data.frame(date = .en_days("2020-01-01", "2020-06-30"), A = 100),
                  create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0)))
  expect_equal(.um(r, "skewness")$reason, "zero_volatility")
  expect_equal(.um(r, "kurtosis")$reason, "zero_volatility")
  expect_equal(.um(r, "sharpe")$reason, "zero_volatility")
  expect_equal(.um(r, "cv")$reason, "zero_mean_return")
  expect_true(any(grepl("Schiefe:          nicht definiert (Standardabweichung der 181 Tagesrenditen ist 0", capture.output(print(r)), fixed = TRUE)))
})

test_that("B no_negative_returns, no_drawdown, no_recovery (stetig steigender Kurs)", {
  d <- .en_days("2020-01-01", "2020-12-31")
  r <- simulation(data.frame(date = d, A = 100 * 1.001^(seq_along(d) - 1)),
                  create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0)))
  for (m in c("sortino", "omega", "gain_to_pain")) expect_equal(.um(r, m)$reason, "no_negative_returns")
  for (m in c("calmar", "serenity", "martin_ratio")) expect_equal(.um(r, m)$reason, "no_drawdown")
  expect_equal(.um(r, "avg_recovery_time")$detail, "kein Drawdown im Zeitraum")
  expect_false(any(c("cagr", "ttwror", "sharpe") %in% r$undefined_metrics$metric))
})

test_that("B alles definiert: leeres data.frame mit gleichen Spalten, Ausgabe ohne Hinweise", {
  d <- .en_days("2020-01-01", "2020-12-31")
  p <- 100 + 10 * sin(seq_along(d) / 20) + seq_along(d) / 10
  r <- simulation(data.frame(date = d, A = p), create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0)))
  expect_identical(dim(r$undefined_metrics), c(0L, 3L))
  expect_identical(names(r$undefined_metrics), c("metric", "reason", "detail"))
  expect_equal(r$tax_report$open_tax_debt, 0)
  expect_false(any(grepl("nicht definiert", capture.output(print(r)))))
})

# ---------------------------------------------------------------- C summary
test_that("C summary: total_return_twr, return_on_invested, Alias total_return", {
  dd <- .en_days("2020-01-01", "2021-12-31")
  p <- ifelse(dd < as.Date("2020-06-01"), 100, ifelse(dd < as.Date("2021-07-01"), 80, 100)); p[length(p)] <- 150
  r <- .en_sim(data.frame(date = dd, A = p), create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0)), start_value = 1000, dca = dca_plan(value = 1000, span = 1, unit = "year", skip = TRUE))
  s <- summary(r); out <- capture.output(print(s))   # C7-06: summary() druckt nicht selbst
  expect_equal(s$total_return_twr, 0.5, tolerance = 1e-12)           # Kurs 100 -> 150
  expect_identical(s$total_return, s$total_return_twr)
  expect_equal(s$invested, 2000)
  end <- tail(r$worth, 1)
  expect_equal(s$return_on_invested, (end - 2000) / 2000)
  expect_true(any(grepl("Gesamtrendite (zeitgewichtet): +50.00 %", out, fixed = TRUE)))
  expect_true(any(grepl(sprintf("Gewinn je eingezahltem EUR:    %+.2f %% (Endwert %.2f EUR / Eingezahlt 2000.00 EUR - 1)",
                                100 * (end - 2000) / 2000, end), out, fixed = TRUE)))
  # ohne Einzahlungen: Ausgabe wie bisher, return_on_invested = total_return_twr
  r0 <- .en_sim(data.frame(date = dd, A = p), create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0)))
  s0 <- summary(r0); out0 <- capture.output(print(s0))
  expect_true(any(grepl("Gesamtrendite:    +50.00%", out0, fixed = TRUE)))
  expect_false(any(grepl("Gewinn je eingezahltem", out0)))
  expect_equal(s0$return_on_invested, s0$total_return_twr, tolerance = 1e-12)
})

# ---------------------------------------------------------------- D Bausteine und Steuern
test_that("D Bausteine pruefen ihre Klasse; simulation(funds = ) gibt es nicht mehr (Etappe 6.5c)", {
  df <- data.frame(date = .en_days("2020-01-01", "2020-03-01"), A = 100)
  st <- create_strategy(A = asset_config("etf", "bnh", share = 1))
  expect_no_warning(simulation(df, st, tax = tax_profile()))
  expect_error(simulation(df, st, tax = list(rate = 20)), "tax muss NULL oder ein Objekt aus tax_profile\\(\\)")
  # alter Fondsmodus: der uebliche Fehler fuer ein unbekanntes Argument, keine Sonderbehandlung
  expect_error(simulation(df, st, funds = funds_costs()), "(funds = funds_costs())", fixed = TRUE)
  expect_error(simulation(df, st, tax = tax_profile(rate = 25, church_tax = 9)), "rate und church_tax schlie\u00dfen sich aus")
})

# ---------------------------------------------------------------- E open_lots
test_that("E open_lots: Verkauf aller offenen Lots (liquidate) ergibt denselben Gewinn", {
  d <- .en_days("2020-01-01", "2021-11-30")
  n <- length(d)
  df <- data.frame(date = d, A = 100 * 1.0005^(seq_len(n) - 1), G = 50 * 1.002^(seq_len(n) - 1))
  st <- create_strategy(A = asset_config("etf", "bnh", share = 0.6, spread = 0.2, partial_exemption = 30),
                        G = asset_config("etc", "bnh", share = 0.4, spread = 0.2, deliverable = TRUE))
  args <- list(data = df, strategy = st, start_value = 1e4,
               tax = tax_profile(base_rate = 2, sparer_pauschbetrag = 0, income = income_rate(30)),
               dca = dca_plan(value = 5000, span = 3))
  r <- do.call(.en_sim, args)
  rl <- do.call(.en_sim, c(args, liquidate = TRUE))
  ol <- r$open_lots
  expect_identical(names(ol), c("A", "G"))
  expect_identical(ol$A$regime, "investment_fund"); expect_equal(ol$A$partial_exemption, 30)
  # Verkaufskosten fuer spaetere Rechnungen: Spread in Prozent wie asset_config, order_fee wie uebergeben
  expect_equal(ol$A$spread, 0.2); expect_equal(ol$G$spread, 0.2)
  expect_true("order_fee" %in% names(ol$A)); expect_null(ol$A$order_fee)
  fee <- list(fixed = 4.9, percent = 0.25, max = 59)
  rf <- .en_sim(df[1:60, ], st, start_value = 1e4, costs = sim_costs(order_fee = fee), tax = tax_profile())
  expect_identical(rf$open_lots$G$order_fee, fee)
  expect_gt(sum(ol$A$lots$vp), 0)
  expect_equal(sum(ol$A$lots$units), tail(r$report$A$worth, 1) / df$A[n], tolerance = 1e-12)
  P <- df$A[n] * (1 - 0.002 / 2)                                  # Geldkurs (halber Spread)
  # Fonds: Gewinn = sum(units x (P - price)); steuerpflichtig (Gewinn - VP) x (1 - TFS)
  gain_A <- sum(ol$A$lots$units * (P - ol$A$lots$price))
  tax_A <- (gain_A - sum(ol$A$lots$vp)) * (1 - 0.3) * 0.26375
  # § 23: je Lot steuerpflichtig nur bei Haltedauer bis 1 Jahr
  PG <- df$G[n] * (1 - 0.002 / 2)
  lg <- ol$G$lots; lot_g <- lg$units * (PG - lg$price)
  short <- as.Date(d[n]) <= as.Date(paste0(as.integer(format(lg$date, "%Y")) + 1, format(lg$date, "-%m-%d")))
  expect_gt(sum(lot_g[short]), 1000); expect_gt(sum(lot_g[!short]), 0)   # § 23 steuerpflichtig und steuerfreie Lots
  # Endwert-Differenz zum Lauf ohne Liquidation = Spread des Verkaufs + Steuer aus der Rechnung mit open_lots
  expect_equal(tail(r$worth, 1) - tail(rl$worth, 1),
               sum(ol$A$lots$units) * df$A[n] * 0.001 + sum(lg$units) * df$G[n] * 0.001 + tax_A +
                 (if (sum(lot_g[short]) >= 1000) sum(lot_g[short]) * 0.30 else 0), tolerance = 1e-6)
  expect_equal(rl$tax_report$total_taxes_paid - r$tax_report$total_taxes_paid,
               tax_A + (if (sum(lot_g[short]) >= 1000) sum(lot_g[short]) * 0.30 else 0), tolerance = 1e-6)
  expect_null(simulation(df[1:30, 1:2], create_strategy(A = asset_config("etf", "bnh", share = 1)))$open_lots)
})

test_that("R5-05: kein Fliesskommarest im Steuer-Saldo nach vollstaendiger Erstattung (T-2 + G\u00fcnstigerpr\u00fcfung)", {
  d <- .en_days("2019-01-01", "2021-02-28")
  df <- data.frame(date = d, Z = ifelse(d < as.Date("2020-02-15"), 50, 70), M = ifelse(d < as.Date("2020-08-15"), 100, 90))
  ev <- as.Date(c("2020-03-01", "2020-09-01"))
  df$ev <- d %in% ev; df$wZ <- ifelse(d == ev[2], 1, 0); df$wM <- 1 - df$wZ
  st <- create_strategy(Z = asset_config("certificate", "bnh", share = 0.5, spread = 0),
                        M = asset_config("certificate", "bnh", share = 0.5, spread = 0))
  r <- .en_sim(df, st, start_value = 2e4, rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(Z = "wZ", M = "wM")), tax = tax_profile(guenstigerpruefung = TRUE, income = income_tariff(taxable_income = 10000)))
  expect_identical(r$tax_report$total_taxes_paid, 0)                   # vorher 8.5e-14
  expect_gt(r$tax_report$tariff_years$refund[2], 0)
  expect_false(any(grepl("Gezahlte Steuern", capture.output(print(r)))))
})

test_that("tax_report$next_year: Steuerzustand des Jahres nach dem letzten Datentag", {
  # A (Fonds, TFS 30 %): 50 Stueck zu 100, Kurs ab 1.12.2020 120; Z (Zertifikat): 50 Stueck 50 -> 30, am 1.7.2020
  # nach M verkauft: § 20-Verlust 1000 -> Verlusttopf 2021 = 1000
  mk <- function(end) {
    d <- .en_days("2020-01-01", end)
    df <- data.frame(date = d, A = ifelse(d < as.Date("2020-12-01"), 100, 120), Z = ifelse(d < as.Date("2020-06-01"), 50, 30), M = 100)
    df$ev <- d == as.Date("2020-07-01"); df$wA <- 5000; df$wZ <- 0; df$wM <- 4000; df
  }
  st <- create_strategy(A = asset_config("etf", "bnh", share = 0.5, spread = 0, partial_exemption = 30),
                        Z = asset_config("certificate", "bnh", share = 0.25, spread = 0),
                        M = asset_config("certificate", "bnh", share = 0.25, spread = 0))
  run <- function(end, ...) .en_sim(mk(end), st, start_value = 1e4, rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(A = "wA", Z = "wZ", M = "wM")), tax = tax_profile(base_rate = 2.29), ...)
  # Ende 31.12.: VP 50 x 100 x 2,29 % x 0,7 = 80,15, nach TFS 56,105, im Jahr 2021 mit dem Verlusttopf verrechnet
  ny <- run("2020-12-31")$tax_report$next_year
  expect_identical(ny$year, 2021L)
  expect_equal(ny$loss_capital_start, 1000); expect_equal(ny$loss_capital_used, 56.105)
  expect_equal(ny$loss_carryforward_capital, 1000 - 56.105)
  expect_equal(ny$sparer_pauschbetrag_used, 0); expect_equal(ny$sparer_pauschbetrag_remaining, 1000)
  expect_equal(ny$capital_income_taxed, 0)
  # Ende unterjaehrig: im Folgejahr noch nichts gebucht
  ny2 <- run("2020-09-30")$tax_report$next_year
  expect_identical(ny2$year, 2021L)
  expect_equal(unlist(ny2[c("sparer_pauschbetrag_used", "loss_capital_used", "capital_income_taxed", "private_sale_net")]),
               c(sparer_pauschbetrag_used = 0, loss_capital_used = 0, capital_income_taxed = 0, private_sale_net = 0))
  expect_equal(ny2$loss_carryforward_capital, 1000); expect_equal(ny2$sparer_pauschbetrag_remaining, 1000)
  # nur Fonds, Ende 31.12.: VP 10 000 x 2,29 % x 0,7 = 160,30, nach TFS 112,21 aus dem Sparer-Pauschbetrag 2021
  d <- .en_days("2020-01-01", "2020-12-31")
  sa <- create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0, partial_exemption = 30))
  da <- data.frame(date = d, A = ifelse(d < as.Date("2020-12-01"), 100, 120))
  ny3 <- .en_sim(da, sa, tax = tax_profile(base_rate = 2.29))$tax_report$next_year
  expect_equal(ny3$sparer_pauschbetrag_used, 112.21); expect_equal(ny3$sparer_pauschbetrag_remaining, 1000 - 112.21)
  # ohne Pauschbetrag: VP 112,21 im Jahr 2021 versteuert; der Zwangsverkauf fuer die Steuer am 31.12.2020 gehoert
  # mit seinem Gewinn zu 2020 (A7-11) -> next_year enthaelt nur die VP, die Gesamtsteuer zusaetzlich die Verkaufssteuer
  r4 <- .en_sim(da, sa, tax = tax_profile(sparer_pauschbetrag = 0, base_rate = 2.29)); ny4 <- r4$tax_report$next_year
  expect_equal(ny4$sparer_pauschbetrag_used, 0); expect_equal(ny4$sparer_pauschbetrag_remaining, 0)
  expect_equal(ny4$capital_income_taxed, 112.21)
  expect_gt(r4$tax_report$total_taxes_paid, 112.21 * 0.26375)
  # Tarifweg: Kirchensteuer-Bescheid des letzten Jahres und ob das Folgejahr schon veranlagt ist
  ny5 <- .en_sim(da, sa, tax = tax_profile(base_rate = 2.29, income = income_tariff(taxable_income = 10000)))$tax_report$next_year
  expect_equal(ny5$church_tax_settlement, 0); expect_false(ny5$tariff_assessed)
  expect_null(.en_sim(da, sa)$tax_report$next_year)
})

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# bis T20 test-engine-rest.R
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Restbefunde der Engine (R3a-01 ... R3a-07, R3B-01 ... R3B-04, Beschriftung cagr).
# Je Befund ein Test mit Handrechnung; "vorher" = Ergebnis vor der Korrektur.

.er_days <- function(from, to) seq.Date(as.Date(from), as.Date(to), by = "day")
.er_lin <- function(dates, at, v) approx(as.numeric(as.Date(at)), v, xout = as.numeric(dates), rule = 2)$y
.er_sim <- function(...) suppressWarnings(suppressMessages(simulation(...)))
.er_out <- function(...) { out <- utils::capture.output(r <- .er_sim(..., details = TRUE)); list(r = r, out = out) }

# Lieferbares ETC (§ 23): Kauf 100 Stueck zu 100 am 1.1.2020, Verkauf zu 150 am 1.6.2020 -> Gewinn 5000
.er_p23 <- function(end = "2021-06-30", tax = tax_profile(income = income_rate(marginal_rate = 42)), ...) {
  d <- .er_days("2020-01-01", end)
  df <- data.frame(date = d, G = ifelse(d < as.Date("2020-06-01"), 100, 150))
  df$cb <- d == d[1]; df$cs <- d == as.Date("2020-06-01")
  st <- create_strategy(G = asset_config("etc", "signal", share = 1, spread = 0, deliverable = TRUE,
                                         signal_buy = "cb", signal_sell = "cs"))
  .er_sim(df, st, start_value = 1e4, tax = tax, ...)
}

# ---------------------------------------------------------------------------
# R3a-02: § 23-Steuer wird vom Depot abgezogen
# ---------------------------------------------------------------------------
test_that("R3a-02: § 23-Steuer am ersten Handelstag des Folgejahres aus dem Cash gezahlt", {
  # Handrechnung: 5000 x 42 % = 2100; Endwert 15000 - 2100 = 12900 (vorher 15000)
  r <- .er_p23()
  expect_equal(r$tax_report$total_taxes_paid, 2100)
  expect_equal(tail(r$worth, 1), 12900)
  i <- which(r$dates == as.Date("2021-01-01"))
  expect_equal(r$worth[i - 1], 15000)                 # 31.12.: noch nicht gezahlt
  expect_equal(r$worth[i], 12900)                     # Abrechnungstag = erster Handelstag 2021
  expect_equal(r$report$G$money[i], 12900)
  # Simulation endet am 31.12.: kein weiterer Tag -> Zahlung am letzten Tag
  r2 <- .er_p23(end = "2020-12-31")
  expect_equal(tail(r2$worth, 1), 12900)
  expect_equal(r2$tax_report$total_taxes_paid, 2100)
})

test_that("R3a-02: § 23-Steuer per Zwangsverkauf, wenn kein Cash da ist (Wiederanlage)", {
  # Zweites ETC H (bnh) wird mit dem Erloes nicht gefuellt; G kauft am 1.7. zu 150 wieder (Signal),
  # Cash 0 -> Zwangsverkauf von G am 4.1.2021 zu 150: 2100 / 150 = 14 Stueck; Haltedauer < 1 Jahr,
  # Verkaufspreis = Kaufpreis -> kein neuer § 23-Gewinn
  d <- .er_days("2020-01-01", "2021-06-30")
  df <- data.frame(date = d, G = ifelse(d < as.Date("2020-06-01"), 100, 150))
  df$cb <- d %in% as.Date(c("2020-01-01", "2020-07-01")); df$cs <- d == as.Date("2020-06-01")
  st <- create_strategy(G = asset_config("etc", "signal", share = 1, spread = 0, deliverable = TRUE,
                                         signal_buy = "cb", signal_sell = "cs"))
  r <- .er_sim(df, st, start_value = 1e4, tax = tax_profile(income = income_rate(marginal_rate = 42)))
  i <- which(r$dates == as.Date("2021-01-01"))
  expect_equal(r$report$G$worth[i - 1], 15000)
  expect_equal(r$report$G$worth[i], 15000 - 2100, tolerance = 1e-7)   # 14 Stueck x 150 verkauft
  expect_lt(abs(r$report$G$money[i]), 0.005)          # Rest der Bisektion (< 1/2 Cent)
  expect_equal(tail(r$worth, 1), 12900, tolerance = 1e-9)
  expect_equal(r$tax_report$total_taxes_paid, 2100)
})

# ---------------------------------------------------------------------------
# R3a-01: Folgejahr ohne Kurse -> VP am 1.1. des Folgejahres
# ---------------------------------------------------------------------------
test_that("R3a-01: VP 2020 wird bei kurslosem Jahr 2021 am 1.1.2021 mit den Toepfen 2021 abgerechnet", {
  # A: 500 Stueck, Kurs 100 -> 110 in 2020; VP = 500 x min(100 x 2,55 % x 0,7, 10) = 892,50,
  # SPB 2021 deckt sie (Steuer 0). C: Verlust 500 x (100 - 90) = 5000 in 2022 -> Verlusttopf 5000
  # (vorher: VP am 1.1.2022 mit dem Topf 2022 verrechnet -> Topf 4107,50)
  d <- .er_days("2020-01-01", "2022-06-30")
  df <- data.frame(date = d, A = .er_lin(d, c("2020-01-01", "2020-12-31"), c(100, 110)),
                   C = .er_lin(d, c("2020-01-01", "2022-02-01", "2022-02-02"), c(100, 100, 90)))
  gap <- d > as.Date("2020-12-31") & d <= as.Date("2021-12-31"); df$A[gap] <- NA; df$C[gap] <- NA
  df$cb <- d == d[1]; df$cs <- d == as.Date("2022-03-01")
  st <- create_strategy(A = asset_config("etf", "bnh", share = 0.5, spread = 0),
                        C = asset_config("certificate", "signal", share = 0.5, spread = 0,
                                         signal_buy = "cb", signal_sell = "cs"))
  x <- .er_out(df, st, start_value = 1e5, tax = tax_profile(base_rate = 2.55))
  vp <- grep("Vorabpauschale A \\(festgesetzt 2020", x$out, value = TRUE)
  expect_length(vp, 1L)
  expect_match(vp, "892.50 EUR.*SPB 892.50 EUR, Steuer 0.00 EUR am 2021-01-01")
  expect_equal(x$r$tax_report$loss_carryforward_capital, 5000)
})

# ---------------------------------------------------------------------------
# R3a-03: Zwangsverkauf mit fractions = FALSE rundet auf, kein stilles Kappen
# ---------------------------------------------------------------------------
test_that("R3a-03: VP-Zwangsverkauf ganzer Stuecke deckt die Steuer (aufgerundet)", {
  # 10000 Stueck zu 100; VP 2020 = 10000 x 1,785 = 17850; nach SPB 16850 x 26,375 % = 4444,1875.
  # Verkauf zu 110: steuerpflichtig je Stueck 10 - 1,785 (§ 19) = 8,215 -> Steuer 2,16670625,
  # netto 107,83329375 -> 41,21 Stueck -> aufgerundet 42 (vorher 41, Fehlbetrag 23,02 still gekappt)
  d <- .er_days("2020-01-01", "2021-01-31")
  df <- data.frame(date = d, A = .er_lin(d, c("2020-01-01", "2020-12-31", "2021-01-31"), c(100, 110, 110)))
  st <- create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0, partial_exemption = 0))
  x <- .er_out(df, st, start_value = 1e6, tax = tax_profile(base_rate = 2.55), fractions = FALSE)
  expect_true(any(grepl("Verkauf 42.00x A zu 110.00", x$out)))
  i <- which(x$r$dates == as.Date("2021-01-01"))
  tax_vp <- 16850 * 0.26375; tax_sale <- 42 * 8.215 * 0.26375
  expect_equal(x$r$tax_report$total_taxes_paid, tax_vp + tax_sale, tolerance = 1e-10)
  expect_equal(x$r$worth[i - 1] - x$r$worth[i], tax_vp + tax_sale, tolerance = 1e-9)
  expect_equal(x$r$report$A$money[i], 42 * 110 - tax_sale - tax_vp, tolerance = 1e-9)   # 84,81 Rest-Cash
})

test_that("R3a-02/03: hat das Asset weder Cash noch Bestand, zahlen die \u00fcbrigen Assets", {
  # G: 50 Stueck zu 100, Verkauf zu 150 am 1.6. (Gewinn 2500, Steuer 2500 x 42 % = 1050); am 1.7.
  # Event-Gewicht G = 0, H = 1: Cash von G (7500) kauft 150 H zu 50. Am 1.1.2021 hat G weder Cash
  # noch Bestand -> H verkauft 1050 / 50 = 21 Stueck (vorher: Steuer nie abgezogen)
  d <- .er_days("2020-01-01", "2021-03-31")
  df <- data.frame(date = d, G = ifelse(d < as.Date("2020-06-01"), 100, 150), H = 50)
  df$cb <- d == d[1]; df$cs <- d == as.Date("2020-06-01")
  df$ev <- d == as.Date("2020-07-01"); df$wG <- 0; df$wH <- 1
  st <- create_strategy(G = asset_config("etc", "signal", share = 0.5, spread = 0, deliverable = TRUE,
                                         signal_buy = "cb", signal_sell = "cs"),
                        H = asset_config("certificate", "bnh", share = 0.5, spread = 0))
  r <- .er_sim(df, st, start_value = 1e4, rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(G = "wG", H = "wH")), tax = tax_profile(income = income_rate(marginal_rate = 42)))
  i <- which(r$dates == as.Date("2021-01-01"))
  expect_equal(r$report$G$total[i - 1], 0)
  expect_equal(r$report$H$worth[i - 1], 250 * 50)
  expect_equal(r$report$H$worth[i], 229 * 50)
  expect_lt(abs(r$report$H$money[i]), 0.005)          # Rest der Bisektion (< 1/2 Cent), nicht gekappt
  expect_equal(tail(r$worth, 1), 12500 - 1050)
  expect_equal(r$tax_report$total_taxes_paid, 1050)
})

# ---------------------------------------------------------------------------
# R3a-04: Steuerschaetzung mit Pauschbetrag/Verlusttopf/§ 19 -> kein Rueckkauf am selben Tag
# ---------------------------------------------------------------------------
test_that("R3a-04: Aktivierung verkauft genau den Transferbetrag (Gewinn im Pauschbetrag)", {
  # A: 10000 / 100,1 = 99,9001 Stueck; am 1.7. Kurs 120, B startet -> Ziel 50 %:
  # Transfer 0,5 x 99,9001 x 120 = 5994,006, Geldkurs 119,88 -> genau 50 Stueck;
  # Gewinn 50 x 19,78 = 989 < 1000 SPB -> Steuer 0 (vorher 52,27 Stueck verkauft, 2,20 zurueckgekauft)
  d <- .er_days("2020-01-01", "2020-12-30")
  df <- data.frame(date = d, A = .er_lin(d, c("2020-01-01", "2020-07-01", "2020-12-30"), c(100, 120, 120)), B = 50)
  st <- create_strategy(A = asset_config("etf", "bnh", share = 0.5, spread = 0.2),
                        B = asset_config("etf", "bnh", share = 0.5, spread = 0.2, start = as.Date("2020-07-01")))
  x <- .er_out(df, st, start_value = 1e4, tax = tax_profile())
  day <- grep("2020-07-01", x$out, value = TRUE)
  expect_true(any(grepl("Verkauf 50.00x A zu 119.88", day)))
  expect_false(any(grepl("Kauf .* A zu", day)))
  expect_equal(x$r$tax_report$total_taxes_paid, 0)
  j <- which(x$r$dates == as.Date("2020-07-01"))
  expect_equal(x$r$report$A$worth[j], (10000 / 100.1 - 50) * 120, tolerance = 1e-5)
  expect_lt(abs(x$r$report$A$money[j]), 0.005)        # kein Ueberschuss -> nichts zurueckzukaufen
})

test_that("R3a-04: Rebalancing mit teilweise steuerpflichtigem Gewinn: kein Rueckkauf, Steuer exakt", {
  d <- .er_days("2020-01-01", "2020-12-30")
  df <- data.frame(date = d, A = .er_lin(d, c("2020-01-01", "2020-07-01", "2020-12-30"), c(100, 200, 200)), B = 50)
  st <- create_strategy(A = asset_config("etf", "bnh", share = 0.5, spread = 0.2),
                        B = asset_config("etf", "bnh", share = 0.5, spread = 0.2))
  x <- .er_out(df, st, start_value = 1e4, rebalance = rebalance_plan(span = 6, unit = "month"), tax = tax_profile())
  day <- grep("2020-07-01", x$out, value = TRUE)
  expect_false(any(grepl("\tKauf .* A zu", day)))            # vorher: Kauf 1.32x A
  m <- regmatches(day, regexec("Verkauf ([0-9.]+)x A", day)); n <- as.numeric(m[[which(lengths(m) > 0)[1]]][2])
  g <- grep("=> Gewinn: ", x$out, value = TRUE)[1]
  gain <- as.numeric(sub(".*=> Gewinn: ([0-9.]+) EUR.*", "\\1", g))
  # Steuer = (Gewinn - 1000 SPB) x 26,375 % (Handrechnung aus dem Gewinn des Verkaufs)
  expect_equal(x$r$tax_report$total_taxes_paid, (gain - 1000) * 0.26375, tolerance = 1e-3)
  j <- which(x$r$dates == as.Date("2020-07-01"))
  expect_lt(abs(x$r$report$A$money[j]), 0.005)
})

# ---------------------------------------------------------------------------
# R3a-05: start nach Datenende -> Fehler
# ---------------------------------------------------------------------------
test_that("R3a-05: start nach dem letzten Datentag ist ein Fehler", {
  d <- .er_days("2020-01-01", "2021-03-31")
  df <- data.frame(date = d, A = seq(100, 110, length.out = length(d)), B = 50)
  st <- create_strategy(A = asset_config("etf", "bnh", share = 0.5, spread = 0),
                        B = asset_config("etf", "bnh", share = 0.5, spread = 0, start = as.Date("2022-01-01")))
  expect_error(simulation(df, st, start_value = 1e4), "start von 'B' \\(2022-01-01\\) liegt nach dem letzten Datentag \\(2021-03-31\\)")
  expect_error(simulation(df, st, start_value = 1e4, rebalance = rebalance_plan(unit = "quarter")), "start von 'B'")
  st$B$start <- as.Date("2021-03-31")             # letzter Tag: zulaessig
  expect_s3_class(.er_sim(df, st, start_value = 1e4), "SimLevResult")
})

# ---------------------------------------------------------------------------
# R3a-06: Kirchensteuer auf die Einkommensteuer
# ---------------------------------------------------------------------------
test_that("R3a-06: Kirchensteuer auf § 23-Steuer und persoenlichen Satz, Abgeltungsteuer unver\u00e4ndert", {
  # § 23: 5000 x 42 % x (1 + 0,09) = 2289 (vorher 2100); Endwert 12711
  r <- .er_p23(tax = tax_profile(church_tax = 9, income = income_rate(marginal_rate = 42)))
  expect_equal(r$tax_report$total_taxes_paid, 2289)
  expect_equal(tail(r$worth, 1), 12711)
  r8 <- .er_p23(tax = tax_profile(church_tax = 8, income = income_rate(marginal_rate = 42, soli_rate = 5.5)))
  expect_equal(r8$tax_report$total_taxes_paid, 5000 * 0.42 * (1 + 0.055 + 0.08))
  # Zertifikat (§ 20): Gewinn 5000, SPB 1000 -> 4000 steuerpflichtig
  d <- .er_days("2020-01-01", "2020-12-31")
  df <- data.frame(date = d, Z = ifelse(d < as.Date("2020-06-01"), 100, 150))
  df$cb <- d == d[1]; df$cs <- d == as.Date("2020-06-01")
  st <- create_strategy(Z = asset_config("certificate", "signal", share = 1, spread = 0,
                                         signal_buy = "cb", signal_sell = "cs"))
  g <- .er_sim(df, st, start_value = 1e4, tax = tax_profile(church_tax = 9, guenstigerpruefung = TRUE, income = income_rate(marginal_rate = 20)))
  expect_equal(g$tax_report$total_taxes_paid, 4000 * 0.20 * 1.09)           # vorher 4000 x 20 %
  a <- .er_sim(df, st, start_value = 1e4, tax = tax_profile(church_tax = 9))
  expect_equal(a$tax_report$total_taxes_paid, 4000 * 0.25 / (1 + 0.25 * 0.09) * (1 + 0.055 + 0.09))  # § 32d
})

# ---------------------------------------------------------------------------
# R3a-07: NA im Basiszins = 0 unabhaengig von der Datenform
# ---------------------------------------------------------------------------
test_that("R3a-07: NA im Basiszins am ersten Handelstag ergibt in beiden Datenformen keine VP", {
  run <- function(d, na = TRUE) {
    df <- data.frame(date = d, A = .er_lin(d, c("2020-01-01", "2020-12-31", "2021-02-26"), c(100, 110, 110)), BR = 2)
    if (na) df$BR[df$date == as.Date("2020-01-02")] <- NA
    df <- df[df$date != as.Date("2020-01-01"), ]
    .er_sim(df, create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0)), start_value = 1e6, tax = tax_profile(base_rate = "BR"))
  }
  d <- .er_days("2020-01-01", "2021-02-26"); dt <- d[!format(d, "%u") %in% c("6", "7")]
  expect_equal(run(d)$tax_report$total_taxes_paid, 0)
  expect_equal(run(dt)$tax_report$total_taxes_paid, 0)       # vorher 3428,75 (LOCF-Rueckfuellung)
  expect_gt(run(dt, na = FALSE)$tax_report$total_taxes_paid, 0)   # Kontrolle: mit Basiszins VP
})

# ---------------------------------------------------------------------------
# R3B-01: XIRR bei Beinahe-Totalverlust
# ---------------------------------------------------------------------------
test_that("R3B-01: .xirr_rate findet Nullstellen unter u = -200", {
  # 30 Jahre, 1000 bei t = 0, 100 bei t = 29,9, Endwert so, dass log(1 + r) = -10 (u = -300)
  V <- 1000 * exp(-300) + 100 * exp(-10 * 0.1)
  r <- SimLev:::.xirr_rate(c(0, 29.9), c(1000, 100), V, 30)
  expect_equal(r, expm1(-10), tolerance = 1e-10)                 # vorher NA
  # Innerhalb des Rasters unveraendert
  expect_equal(SimLev:::.xirr_rate(0, 1000, 2000, 10), 2^(1 / 10) - 1, tolerance = 1e-12)
  # Keine Nullstelle (Einzahlung am Ende allein uebersteigt den Endwert): NA
  expect_true(is.na(SimLev:::.xirr_rate(c(0, 1), c(1000, 100), 50, 1)))
})

test_that("R3B-01: simulation() liefert cagr bei Knockout mit Sparplan", {
  dd <- .er_days("2020-01-01", "2023-12-31")
  p <- rep(100, length(dd)); p[dd >= as.Date("2023-12-20")] <- 1e-3
  expect_silent(r <- suppressMessages(simulation(data.frame(date = dd, A = p), create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0)), start_value = 1000, dca = dca_plan(value = 100, span = 1))))
  expect_true(is.finite(r$cagr))
  # Probe: S (1 + r)^T + sum F_i (1 + r)^(T - t_i) = V in L = log(1 + r) (unabhaengige Nullstelle)
  fl <- rowSums(sapply(r$report, function(x) x$flows)); fi <- which(seq_along(fl) > 1 & fl != 0)
  a <- c(1000 + fl[1], fl[fi]); tau <- as.numeric(tail(dd, 1) - c(dd[1], dd[fi])) / 365.25
  L <- uniroot(function(L) sum(a * exp(L * tau)) - tail(r$worth, 1), c(-1e5, 0), tol = 1e-12)$root
  expect_equal(r$cagr, expm1(L))
})

# ---------------------------------------------------------------------------
# R3B-02: Bewertung zum Zahlungszeitpunkt an Zuflusstagen
# ---------------------------------------------------------------------------
test_that("R3B-02: Tagesrendite an Zuflusstagen mit Bewertung zum Zahlungszeitpunkt, sonst unver\u00e4ndert", {
  set.seed(1); n <- 400
  d <- data.frame(date = .er_days("2015-01-01", as.Date("2015-01-01") + n - 1),
                  A = 100 * cumprod(1 + rnorm(n, 3e-4, 0.012)))
  st <- create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0.1))
  r <- .er_sim(d, st, start_value = 1, dca = dca_plan(value = 500, span = 1, days = 15))
  w <- r$worth; fl <- rowSums(sapply(r$report, function(x) x$flows)); g <- r$twr_index[-1] / r$twr_index[-n]
  f <- which(fl[-1] != 0); nf <- which(fl[-1] == 0)
  # Handrechnung: V_pre = Bestand_{t-1} * P_t / P_{t-1} + Cash_{t-1}; 1 + r = V_pre / W_{t-1} * W_t / (V_pre + F)
  rep_a <- r$report$A
  vpre <- rep_a$worth[f] * d$A[f + 1] / d$A[f] + rep_a$money[f]
  expect_equal(g[f], vpre / w[f] * w[f + 1] / (vpre + fl[f + 1]), tolerance = 1e-12)
  expect_gt(g[f[1]], 0.99)                                          # vorher 0,7675 (Tagesrendite -23 %)
  # Kaufkosten der Einzahlung belasten nur das Kapital nach der Zahlung: Teilfaktor 2 >= 1 - Spread
  expect_true(all(w[f + 1] / (vpre + fl[f + 1]) > 1 - 0.002))
  expect_equal(g[nf], 1 + (w[nf + 1] - w[nf]) / w[nf])              # ohne Zufluss bitgleich
  expect_equal(r$ttwror, prod(g)^(365.25 / (n - 1)) - 1, tolerance = 1e-12)
  # Ohne Zufluesse: TTWROR = (W_n / W_1)^(1/T) - 1 wie bisher
  r0 <- .er_sim(d, st, start_value = 1e4)
  expect_equal(r0$ttwror, prod(1 + diff(r0$worth) / head(r0$worth, -1))^(365.25 / (n - 1)) - 1)
})

# ---------------------------------------------------------------------------
# R3B-03: invested und XIRR-Startbetrag brutto
# ---------------------------------------------------------------------------
test_that("R3B-03: invested = Startwert + Einzahlungen (brutto), XIRR mit Brutto-Start", {
  set.seed(1); n <- 1500
  d <- data.frame(date = .er_days("2015-01-01", as.Date("2015-01-01") + n - 1),
                  A = 100 * cumprod(1 + rnorm(n, 3e-4, 0.012)))
  st <- create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 2))
  r <- .er_sim(d, st, start_value = 10000, costs = sim_costs(order_fee = 10), dca = dca_plan(value = 500, span = 1))
  fl <- rowSums(sapply(r$report, function(x) x$flows))
  expect_equal(r$invested[1], 10000 + 500)                         # vorher 10376,24 (netto)
  expect_equal(tail(r$invested, 1), 10000 + 50 * 500)              # 50 Raten
  fi <- which(seq_along(fl) > 1 & fl != 0); a <- c(10000 + fl[1], fl[fi]); dt <- c(d$date[1], d$date[fi])
  tau <- as.numeric(d$date[n] - dt) / 365.25
  x <- uniroot(function(x) sum(a * (1 + x)^tau) - tail(r$worth, 1), c(-0.99, 1), tol = 1e-14)$root
  expect_equal(r$cagr, x, tolerance = 1e-10)                       # vorher 0,03112 statt 0,02971
  # Ohne Einzahlungen: cagr unveraendert aus dem Depotwert am Starttag
  r0 <- .er_sim(d, st, start_value = 10000)
  expect_equal(r0$cagr, (tail(r0$worth, 1) / r0$worth[1])^(365.25 / (n - 1)) - 1)
  expect_equal(unique(r0$invested), 10000)
})

# ---------------------------------------------------------------------------
# R3B-04: aux_type = character(0) wie NULL
# ---------------------------------------------------------------------------
test_that("R3B-04: aux_type = character(0) gilt wie NULL", {
  c1 <- bootstrap_config(c(a = "a"), aux = c(cpi = "cpi"))
  c2 <- bootstrap_config(c(a = "a"), aux = c(cpi = "cpi"), aux_type = character(0))   # vorher Fehler
  expect_identical(c1, c2)
  set.seed(7); n <- 400
  d <- data.frame(date = .er_days("2010-01-01", as.Date("2010-01-01") + n - 1), a = exp(rnorm(n, 3e-4, 0.012)))
  d$cpi <- 100 * cumprod(exp(rnorm(n, 0.02 / 365, 0.001)))
  b <- bootstrap(d, c2, "raw", n = 3, path_length = 100, seed = 3, progress = FALSE)
  expect_equal(unname(sapply(b$paths, function(P) attr(P, "aux_level")[1, "cpi"])), rep(d$cpi[1], 3))
})

# ---------------------------------------------------------------------------
# Beschriftung: cagr bei Sparplaenen geldgewichtet
# ---------------------------------------------------------------------------
test_that("Beschriftung: Ausgaben kennzeichnen cagr als geldgewichtet (XIRR)", {
  set.seed(1)
  d <- data.frame(date = .er_days("2015-01-01", as.Date("2015-01-01") + 599))
  d$A <- 100 * cumprod(1 + rnorm(600, 3e-4, 0.01)); d$B <- 100 * cumprod(1 + rnorm(600, 1e-4, 0.004))
  st <- create_strategy(A = asset_config("etf", "bnh", 0.6), B = asset_config("etf", "bnh", 0.4))
  rs <- sensitivity_rebalancing(d, st, frequencies = list(yearly = c("year", 1)),
                                sim_args = list(dca = dca_plan(100, 1)))
  expect_true(any(grepl("cagr: mit Sparplan geldgewichtet \\(XIRR\\)", utils::capture.output(print(rs)))))
  sm <- structure(list(top = data.frame(id = 1L, n = 50, cagr = 0.05, sharpe = 0.4, plateau = 0.4),
                       best = data.frame(id = 1L, n = 50, sharpe = 0.4), best_plateau = data.frame(id = 1L, n = 50, sharpe = 0.4, plateau = 0.4),
                       n = 1L, n_failed = 0L, objective = "sharpe", method = "grid", params = "n", elapsed = 0),
                  class = "summary.SimLevParamSearch")
  expect_true(any(grepl("geldgewichtet \\(XIRR\\)", utils::capture.output(print(sm)))))
  bs <- structure(list(distribution = data.frame(strategy = "s", metric = "cagr", mean = 0.05, q05 = 0.01),
                       paired = NULL, n_paths = 2L, method = "raw", benchmark = NULL, path_length = 10L),
                  class = "summary.SimLevBootstrapStudy")
  expect_true(any(grepl("cagr \\(mit Sparplan geldgewichtet, XIRR\\)", utils::capture.output(print(bs)))))
})

test_that("R3B-02: ohne Kosten folgt der zeitgewichtete Index trotz Sparplan exakt dem Kurs", {
  set.seed(7); n <- 500
  d <- data.frame(date = .er_days("2016-01-01", as.Date("2016-01-01") + n - 1),
                  A = 100 * cumprod(1 + rnorm(n, 3e-4, 0.012)))
  st <- create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0))
  r <- .er_sim(d, st, start_value = 1, dca = dca_plan(value = 500, span = 1))
  expect_true(r$external_flows)
  expect_equal(r$twr_index, d$A / d$A[1], tolerance = 1e-12)
  expect_equal(r$statistics$max_drawdown, max(1 - d$A / cummax(d$A)), tolerance = 1e-12)
})

# ===========================================================================
# Runde red4 (R4-01 ... R4-07)
# ===========================================================================

# Zertifikat (§ 20): Gewinn 5000 am 1.6.2020, SPB 1000 -> 4000 steuerpflichtig
.er_cert <- function(tax = tax_profile(), ...) {
  d <- .er_days("2020-01-01", "2020-12-31")
  df <- data.frame(date = d, Z = ifelse(d < as.Date("2020-06-01"), 100, 150))
  df$cb <- d == d[1]; df$cs <- d == as.Date("2020-06-01")
  st <- create_strategy(Z = asset_config("certificate", "signal", share = 1, spread = 0,
                                         signal_buy = "cb", signal_sell = "cs"))
  .er_sim(df, st, start_value = 1e4, tax = tax, ...)
}

test_that("R4-01: G\u00fcnstigerpr\u00fcfung vergleicht die Belastung einschliesslich Zuschlagsteuern", {
  # 24,9 % x (1 + 5,5 % + 9 %) = 28,51 % > Abgeltung mit KiSt 25 % / 1,0225 x 1,145 = 27,995 %:
  # Abgeltungsteuer bleibt (vorher 4000 x 0,285105 = 1140,42, also MEHR als ohne Pruefung)
  abg <- 4000 * 0.25 / 1.0225 * 1.145
  r <- .er_cert(tax = tax_profile(church_tax = 9, guenstigerpruefung = TRUE, income = income_rate(marginal_rate = 24.9, soli_rate = 5.5)))
  expect_equal(r$tax_report$total_taxes_paid, abg)
  r0 <- .er_cert(tax = tax_profile(church_tax = 9, income = income_rate(marginal_rate = 24.9, soli_rate = 5.5)))
  expect_equal(r$tax_report$total_taxes_paid, r0$tax_report$total_taxes_paid)
  # 25,5 % ohne Soli/KiSt < 26,375 %: persoenlicher Satz (vorher starre 25-%-Schwelle: 1055)
  expect_equal(.er_cert(tax = tax_profile(guenstigerpruefung = TRUE, income = income_rate(marginal_rate = 25.5)))$tax_report$total_taxes_paid, 4000 * 0.255)
  expect_equal(.er_cert(tax = tax_profile(guenstigerpruefung = TRUE, income = income_rate(marginal_rate = 20)))$tax_report$total_taxes_paid, 4000 * 0.20)
  # gleicher Satz in der Verkaufsschaetzung: Umschichtung ohne Rueckkauf
  d <- .er_days("2020-01-01", "2020-12-30")
  df <- data.frame(date = d, A = .er_lin(d, c("2020-01-01", "2020-07-01", "2020-12-30"), c(100, 200, 200)), B = 50)
  st <- create_strategy(A = asset_config("etf", "bnh", share = 0.5, spread = 0.2),
                        B = asset_config("etf", "bnh", share = 0.5, spread = 0.2))
  x <- .er_out(df, st, start_value = 1e4, rebalance = rebalance_plan(span = 6, unit = "month"), tax = tax_profile(guenstigerpruefung = TRUE, income = income_rate(marginal_rate = 25.5)))
  day <- grep("2020-07-01", x$out, value = TRUE)
  expect_false(any(grepl("\tKauf .* A zu", day)))
  expect_lt(abs(x$r$report$A$money[which(x$r$dates == as.Date("2020-07-01"))]), 0.005)
})

test_that("R4-02: § 20-Erstattung aus dem finalen Jahresabschluss landet im Endwert", {
  # X: 50 Stueck 100 -> 150 (Gewinn 2500, nach SPB 1500 versteuert = 395,625), Y: 50 Stueck 100 -> 70
  # (Verlust 1500) -> Jahresabschluss erstattet 395,625. Endwert 50 x 150 + 50 x 70 + 50 x 100 = 16000
  # (vorher 15604,375 bei Ende 31.12. bzw. 30.11., 16000 erst mit einem weiteren Tag 1.1.)
  run <- function(end, g_up = FALSE) {
    d <- .er_days("2020-01-01", end)
    df <- data.frame(date = d, X = ifelse(d < as.Date("2020-03-01"), 100, 150), Y = ifelse(d < as.Date("2020-10-01"), 100, 70),
                     G = ifelse(d < as.Date("2020-06-01"), 100, if (g_up) 125 else 100))
    df$b <- d == d[1]; df$sx <- d == as.Date("2020-03-01"); df$sy <- d == as.Date("2020-10-01"); df$sg <- d == as.Date("2020-06-01")
    cf <- function(s, cls = "certificate") asset_config(cls, "signal", share = 1 / 3, spread = 0, deliverable = TRUE, signal_buy = "b", signal_sell = s)
    .er_sim(df, create_strategy(X = cf("sx"), Y = cf("sy"), G = cf("sg", "etc")), start_value = 15000, tax = tax_profile(income = income_rate(marginal_rate = 42)))
  }
  for (end in c("2020-12-31", "2020-11-30", "2021-01-01")) {
    r <- run(end)
    expect_equal(tail(r$worth, 1), 16000)
    expect_equal(r$tax_report$total_taxes_paid, 0, tolerance = 1e-9)
  }
  # mit § 23-Gewinn 1250 (Steuer 525): 16000 + 1250 - 525 = 16725 (war schon richtig)
  expect_equal(tail(run("2020-12-31", TRUE)$worth, 1), 16725)
})

test_that("R4-03: result_analysis mwrr = Engine-cagr auch in Extremfaellen", {
  st <- create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0))
  dd <- .er_days("2020-01-01", "2023-12-31"); p <- rep(100, length(dd)); p[dd >= as.Date("2023-12-20")] <- 1e-3
  r <- .er_sim(data.frame(date = dd, A = p), st, start_value = 1000, dca = dca_plan(value = 100, span = 1))
  expect_equal(unname(suppressMessages(result_analysis(r))$metrics["mwrr", 1]), r$cagr)            # vorher NA
  dd <- .er_days("2020-01-01", "2020-03-31"); p <- 100 * 3^(seq_along(dd) / length(dd))
  r2 <- .er_sim(data.frame(date = dd, A = p), st, start_value = 1000, dca = dca_plan(value = 100, span = 1))
  fl <- rowSums(sapply(r2$report, function(x) x$flows)); a <- c(1000 + fl[1], fl[-1]); tau <- as.numeric(dd[length(dd)] - dd) / 365.25
  ref <- uniroot(function(x) sum(a[a != 0] * (1 + x)^tau[a != 0]) - tail(r2$worth, 1), c(0, 1e4), tol = 1e-12)$root
  expect_equal(r2$cagr, ref, tolerance = 1e-9)
  expect_equal(unname(suppressMessages(result_analysis(r2))$metrics["mwrr", 1]), r2$cagr, tolerance = 1e-12)   # vorher NA (> 1000 %)
  # ohne Einzahlungen: CAGR wie die Engine
  r3 <- .er_sim(data.frame(date = dd, A = p), st, start_value = 1000)
  expect_equal(unname(suppressMessages(result_analysis(r3))$metrics["mwrr", 1]), r3$cagr, tolerance = 1e-12)
})

test_that("R4-04: cost_basis = 100, wenn das Ansparergebnis nur noch Cash haelt (liquidate)", {
  d <- .er_days("2015-01-01", "2024-12-31")
  df <- data.frame(date = d, A = 100 * 1.08^(as.numeric(d - d[1]) / 365.25))
  st <- create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0))
  x <- matrix(1.05, nrow = 20, ncol = 1)
  r <- .er_sim(df, st, start_value = 1e5, tax = tax_profile(base_rate = 1), liquidate = TRUE)
  expect_equal(tail(r$report$A$worth, 1), 0)
  w_auto <- withdrawal_simulation(x, withdrawal_rule("constant", rate = 4), start_value = r, tax = tax_profile())
  w_100 <- withdrawal_simulation(x, withdrawal_rule("constant", rate = 4), start_value = r, tax = tax_profile(), cost_basis = 100)
  expect_equal(w_auto$paths, w_100$paths)                      # vorher Steuern 25058,86 statt 15562,26
  # mit Bestand am Ende: seit open_lots exakte Basis (Anschaffungskosten der Reststuecke nach den Verkaeufen fuer die
  # VP-Steuer plus angerechnete Vorabpauschalen)
  # statt der Naeherung 100 x (Start brutto + Einzahlungen) / Endwert; seit FIFO die Lots selbst (ein Lot = Durchschnitt)
  # und die Teilfreistellung 0 % der Ansparphase (uebernommen)
  r2 <- .er_sim(df, st, start_value = 1e5, tax = tax_profile(base_rate = 1))
  w_a2 <- suppressMessages(withdrawal_simulation(x, withdrawal_rule("constant", rate = 4), start_value = r2, tax = tax_profile()))
  expect_equal(w_a2$adopted$partial_exemption, 0)
  w_n2 <- suppressMessages(withdrawal_simulation(x, withdrawal_rule("constant", rate = 4), start_value = r2, tax = tax_profile(), partial_exemption = 0,
                                cost_basis = 100 * with(r2$open_lots$A, sum(lots$units * lots$price) + sum(lots$vp) + cash) /
                                  tail(r2$worth, 1)))
  expect_equal(w_a2$paths, w_n2$paths)
})

test_that("R4-05: negativer Endwert -> cagr/ttwror NA mit Warnung, Drawdowns <= 100 %", {
  # G: 50 Stueck 100 -> 150, am 1.7. Gewicht 0 (Gewinn 2500, § 23-Steuer 1050); H: 250 Stueck, Knockout auf 1:
  # am 1.1.2021 reichen 250 EUR nicht, 800 EUR Steuerschuld bleiben -> Endwert -800 (vorher cagr/ttwror NaN, DD 106 %)
  d <- .er_days("2020-01-01", "2021-06-30")
  df <- data.frame(date = d, G = ifelse(d < as.Date("2020-06-01"), 100, 150), H = ifelse(d < as.Date("2020-10-01"), 50, 1))
  df$ev <- d == as.Date("2020-07-01"); df$wG <- 0; df$wH <- 1
  st <- create_strategy(G = asset_config("etc", "bnh", share = 0.5, spread = 0, deliverable = TRUE),
                        H = asset_config("certificate", "bnh", share = 0.5, spread = 0))
  w <- character(0)
  r <- withCallingHandlers(suppressMessages(simulation(df, st, start_value = 1e4, rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(G = "wG", H = "wH")), tax = tax_profile(income = income_rate(marginal_rate = 42)))),
         warning = function(x) { w <<- c(w, conditionMessage(x)); invokeRestart("muffleWarning") })
  expect_equal(tail(r$worth, 1), -800)
  expect_true(is.na(r$cagr) && !is.nan(r$cagr)); expect_true(is.na(r$ttwror) && !is.nan(r$ttwror))
  expect_true(all(r$drawdowns >= 0 & r$drawdowns <= 1))
  expect_equal(r$statistics$max_drawdown, 1)
  expect_true(any(grepl("Endwert negativ \\(-800.00 EUR", w)))
  expect_true(any(grepl("800.00 EUR bleiben als negativer Geldbestand", w)))
})

test_that("R4-06: Rebalancing verkauft nur Transfer minus vorhandenes Cash (kein Rueckkauf)", {
  d <- .er_days("2020-01-01", "2020-12-31")
  df <- data.frame(date = d, A = approx(as.numeric(range(d)), c(100, 130), xout = as.numeric(d))$y, B = 50)
  st <- create_strategy(A = asset_config("etf", "bnh", 0.5, spread = 0.2), B = asset_config("etf", "bnh", 0.5, spread = 0.2))
  x <- .er_out(df, st, start_value = 1e5, dca = dca_plan(value = 1000, span = 1), rebalance = rebalance_plan(span = 1, unit = "month"), tax = tax_profile())
  day <- grep("am 2020-03-01", x$out, value = TRUE)
  expect_false(any(grepl("\tKauf .* A zu", day)))                     # vorher Kauf 4.76x A
  n <- as.numeric(sub(".*Verkauf ([0-9.]+)x A.*", "\\1", grep("Verkauf .* A zu", day, value = TRUE)))
  expect_lt(n, 1)                                                      # vorher 5.72 Stueck
  i <- grep("^\t\t[0-9.]+ EUR von A in den Rebalancing-Topf", x$out)
  i <- i[i > grep("^Einzahlung:\t1000.00 EUR in das Depot am 2020-03-01", x$out)][1]
  dep <- as.numeric(sub("^\t\t([0-9.]+) EUR von A.*", "\\1", x$out[i]))
  # Pool = Sparrate von A (500) + Verkaufserloes; Rest-Cash bei A ~ 0
  expect_equal(dep, 500 + n * 104.83, tolerance = 0.01)
  expect_lt(abs(x$r$report$A$money[which(x$r$dates == as.Date("2020-03-01"))]), 0.005)
})

test_that("R4-07: dca_value/dca_span m\u00fcssen einzelne endliche Zahlen sein", {
  d <- data.frame(date = .er_days("2020-01-01", as.Date("2020-01-01") + 399), A = 100)
  st <- create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0))
  for (v in list(c(100, 200), NA_real_, "100", 0, -5, Inf, NULL))
    expect_error(dca_plan(value = v, span = 1), "dca_plan: 'value' muss eine einzelne endliche Zahl > 0 sein")
  for (v in list(c(1, 2), NA_real_, 1.5, 0, "1"))
    expect_error(dca_plan(value = 100, span = v), "dca_plan: 'span' muss eine einzelne ganze Zahl >= 1 sein")
  expect_error(dca_plan(100), "dca_plan: 'span' muss .* nicht NULL")
  expect_s3_class(.er_sim(d, st, dca = dca_plan(value = 100, span = 2)), "SimLevResult")
})

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# bis T20 test-flow-metrics.R
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Verlustvortrag bei spaeteren Verlusten (§ 20 EStG) und zuflussbereinigte Kennzahlen bei Sparplan.
# Je Punkt ein Test mit Handrechnung; "vorher" = Ergebnis vor der Korrektur.

.fm_days <- function(from, to) seq.Date(as.Date(from), as.Date(to), by = "day")
.fm_step <- function(dates, at, v) v[findInterval(as.numeric(dates), as.numeric(as.Date(at)))]
.fm_flag <- function(dates, at) dates %in% as.Date(at)
.fm_sim <- function(...) suppressWarnings(suppressMessages(simulation(...)))

# ---------------------------------------------------------------------------
# 1: Erstattung bei Verlustvortrag aus dem Vorjahr
# ---------------------------------------------------------------------------
# 2021: Y verliert 1000 (Vortrag 1000). 2022: X gewinnt 3000 (Topf 1000, Pauschbetrag 1000,
# versteuert 1000 = 263,75 EUR), danach verliert Z z_loss.
.fm_carry <- function(z_price, vp = FALSE) {
  dd <- .fm_days("2021-01-01", "2022-12-31")
  d <- data.frame(date = dd, X = .fm_step(dd, c("2021-01-01", "2022-03-01"), c(100, 160)),
                  Y = .fm_step(dd, c("2021-01-01", "2021-06-01"), c(100, 80)),
                  Z = .fm_step(dd, c("2021-01-01", "2022-06-01"), c(100, z_price)))
  d$b <- .fm_flag(dd, "2021-01-01"); d$sx <- .fm_flag(dd, "2022-03-01")
  d$sy <- .fm_flag(dd, "2021-06-01"); d$sz <- .fm_flag(dd, "2022-06-01")
  k <- if (vp) 4 else 3
  cf <- function(s) asset_config("certificate", "signal", share = 1 / k, spread = 0, signal_buy = "b", signal_sell = s)
  st <- list(X = cf("sx"), Y = cf("sy"), Z = cf("sz"))
  if (vp) {
    d$E <- .fm_step(dd, c("2021-01-01", "2021-12-31"), c(100, 120))
    st$E <- asset_config("etf", "bnh", share = 0.25, spread = 0, partial_exemption = 0)
  }
  .fm_sim(d, do.call(create_strategy, st), start_value = 5000 * k, tax = tax_profile(base_rate = if (vp) 2.5 else NULL))
}

test_that("Punkt 1: Verlust nach Nutzung eines Vortrags erstattet die Steuer, die Vortragsnutzung bleibt", {
  # Verlust 500: Jahressaldo 3000 - 500 - 1000 (Vortrag) - 1000 (Pauschbetrag) = 500 versteuert,
  # Erstattung der Steuer auf 500; Steuer 500 x 26,375 % = 131,875 EUR, Topf 0
  # (vorher: Erstattung 0, Steuer 263,75 EUR, Topf 500).
  r <- .fm_carry(90)
  expect_equal(r$tax_report$total_taxes_paid, 500 * 0.26375, tolerance = 1e-10)
  expect_equal(r$tax_report$loss_carryforward_capital, 0, tolerance = 1e-10)
  expect_equal(r$tax_report$sparer_pauschbetrag_used, 1000, tolerance = 1e-10)
  # Verlust 1500: Saldo 1500 = Vortrag 1000 + Pauschbetrag 500, versteuert 0, Topf 0
  # (vorher: Steuer auf 500 = 131,875 EUR, Pauschbetrag 500, Topf 500).
  r <- .fm_carry(70)
  expect_equal(r$tax_report$total_taxes_paid, 0, tolerance = 1e-10)
  expect_equal(r$tax_report$loss_carryforward_capital, 0, tolerance = 1e-10)
  expect_equal(r$tax_report$sparer_pauschbetrag_used, 500, tolerance = 1e-10)
  # Verlust 2500: Saldo 500 < Vortrag -> genutzter Vortrag 500, Pauschbetrag 0, versteuert 0, Topf 500
  # (unveraendert richtig).
  r <- .fm_carry(50)
  expect_equal(r$tax_report$total_taxes_paid, 0, tolerance = 1e-10)
  expect_equal(r$tax_report$loss_carryforward_capital, 500, tolerance = 1e-10)
  expect_equal(r$tax_report$sparer_pauschbetrag_used, 0, tolerance = 1e-10)
})

test_that("Punkt 1: Vorabpauschale ist Ertrag des Zuflussjahres und zaehlt zum Saldo", {
  # E (TFS 0): 50 Stueck, 2021 von 100 auf 120, Basiszins 2,5 %: VP = 50 x min(1,75; 20) = 87,5 EUR,
  # Zufluss 2022 (Topf 1000 -> 912,5). X-Gewinn 3000: Topf 912,5, Pauschbetrag 1000, versteuert
  # 1087,5. Z-Verlust 500. Saldo 3087,5 - 500 - 1000 - 1000 = 587,5 versteuert:
  # Steuer 587,5 x 26,375 % = 154,953125 EUR, Topf 0 (vorher: 1087,5 versteuert = 286,83 EUR, Topf 500).
  r <- .fm_carry(90, vp = TRUE)
  expect_equal(r$tax_report$total_taxes_paid, 587.5 * 0.26375, tolerance = 1e-10)
  expect_equal(r$tax_report$loss_carryforward_capital, 0, tolerance = 1e-10)
  expect_equal(r$tax_report$sparer_pauschbetrag_used, 1000, tolerance = 1e-10)
})

# ---------------------------------------------------------------------------
# 2: Zuflussbereinigte Kennzahlen bei Sparplan
# ---------------------------------------------------------------------------
# Kurs 100, ab 01.06.2020 80, ab 01.07.2021 100, am 31.12.2021 150. Start 1000 (10 Stueck),
# Sparrate 1000 am 01.01.2021 zu 80 (12,5 Stueck); Endwert 22,5 x 150 = 3375 EUR.
.fm_dca <- function() {
  dd <- .fm_days("2020-01-01", "2021-12-31")
  p <- ifelse(dd < as.Date("2020-06-01"), 100, ifelse(dd < as.Date("2021-07-01"), 80, 100)); p[length(p)] <- 150
  .fm_sim(data.frame(date = dd, A = p), create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0)), start_value = 1000, dca = dca_plan(value = 1000, span = 1, unit = "year", skip = TRUE))
}

test_that("Punkt 2: CAGR mit Sparplan ist der interne Zinsfu\u00df (Handrechnung, unabhaengige Referenz)", {
  r <- .fm_dca()
  expect_true(r$external_flows)
  expect_equal(tail(r$worth, 1), 3375)
  expect_equal(r$invested[c(1, length(r$invested))], c(1000, 2000))
  # 1000 (1 + r)^T + 1000 (1 + r)^(T - t1) = 3375 mit T = 730 / 365,25, t1 = 366 / 365,25
  # (Kalendertage / 365,25 wie die CAGR ohne Zufluesse). Referenz: Brent in r statt in log(1 + r).
  T <- 730 / 365.25; t1 <- 366 / 365.25
  f <- function(x) 1000 * (1 + x)^T + 1000 * (1 + x)^(T - t1) - 3375
  ref <- uniroot(f, c(-0.5, 2), tol = 1e-14)$root
  expect_equal(r$cagr, ref, tolerance = 1e-12)
  expect_lt(abs(f(r$cagr)), 1e-8)
  expect_equal(r$cagr, 0.4046127, tolerance = 1e-6)
  # vorher: (3375 / 1000)^(1 / T) - 1 = 83,7 % (Einzahlung als Rendite gezaehlt)
  expect_gt((3375 / 1000)^(1 / T) - 1 - r$cagr, 0.4)
  # TTWROR: Index 1 -> 0,8 -> 1 -> 1,5
  expect_equal(r$ttwror, 1.5^(1 / T) - 1, tolerance = 1e-12)
  # result_analysis (eigene MWRR) stimmt ueberein
  expect_equal(r$cagr, result_analysis(r)$metrics["mwrr", 1], tolerance = 1e-8)
})

test_that("Punkt 2: Drawdowns zeitgewichtet, Calmar/Martin mit TTWROR", {
  r <- .fm_dca()
  s <- r$statistics
  # Index faellt am 01.06.2020 auf 0,8 und erholt sich erst am 01.07.2021 (395 Tage unter dem Hoch);
  # die Einzahlung am 01.01.2021 verdeckt den Drawdown nicht mehr (vorher: Depotwert 1800 > 1000,
  # Drawdown endet am 01.01.2021 nach 214 Tagen).
  expect_equal(s$max_drawdown, 0.2, tolerance = 1e-12)
  expect_equal(s$longest_drawdown, 395L)
  expect_equal(s$avg_recovery_time, 395)
  expect_equal(range(which(r$drawdowns > 0)), match(as.Date(c("2020-06-01", "2021-06-30")), r$dates))
  expect_equal(r$twr_index[match(as.Date(c("2020-05-31", "2021-01-02", "2021-12-31")), r$dates)], c(1, 0.8, 1.5), tolerance = 1e-12)
  expect_equal(r$drawdowns, 1 - r$twr_index / cummax(r$twr_index), tolerance = 1e-12)
  expect_equal(s$calmar, r$ttwror / 0.2, tolerance = 1e-12)
  expect_equal(s$martin_ratio, r$ttwror / s$ulcer_index, tolerance = 1e-12)
  expect_equal(s$serenity, r$ttwror / (s$ulcer_index * s$max_drawdown), tolerance = 1e-12)
  expect_equal(s$ulcer_index, sqrt(mean(r$drawdowns^2)), tolerance = 1e-12)
})

test_that("Punkt 2: Red-Team-Fall R2-05 (CAGR 82 % bei TTWROR 4 %), Volatilit\u00e4t war schon bereinigt", {
  set.seed(12); n <- 4 * 365
  d <- data.frame(date = seq.Date(as.Date("2019-01-01"), by = "day", length.out = n), A = 100 * exp(cumsum(rnorm(n, 2e-4, 0.011))))
  r <- .fm_sim(d, create_strategy(A = asset_config("etf", share = 1, spread = 0)), dca = dca_plan(value = 2000, span = 1))
  w <- r$worth; fl <- r$report$A$flows; t <- as.numeric(r$dates - r$dates[1]) / 365.25
  # unabhaengige Referenz: Newton auf dem Kapitalwert (Diskontierung auf den Start)
  cf <- -fl; cf[1] <- -w[1]; cf[n] <- cf[n] + w[n]
  x <- 0.05; for (i in 1:50) x <- x - sum(cf * (1 + x)^(-t)) / sum(-t * cf * (1 + x)^(-t - 1))
  expect_equal(r$cagr, x, tolerance = 1e-12)
  expect_lt(r$cagr, 0.15)                                         # vorher 0,8206
  # Tagesrenditen: an Zuflusstagen Bewertung zum Zahlungszeitpunkt (R3B-02); ohne Kosten = Kursrendite
  rr <- d$A[-1] / d$A[-n] - 1
  expect_equal(r$statistics$max_drawdown, max(1 - d$A / cummax(d$A)), tolerance = 1e-10)   # vorher 0,158
  expect_equal(r$statistics$sd, sd(rr), tolerance = 1e-12)
  expect_equal(r$statistics$sharpe, mean(rr) / sd(rr) * sqrt(length(rr) / (as.numeric(r$dates[n] - r$dates[1]) / 365.25)), tolerance = 1e-10)
})

test_that("Punkt 2: ohne Zufluesse unver\u00e4ndert (alte Formeln bitgleich)", {
  set.seed(3); n <- 900
  d <- data.frame(date = seq.Date(as.Date("2018-01-01"), by = "day", length.out = n), A = 100 * exp(cumsum(rnorm(n, 3e-4, 0.012))))
  r <- .fm_sim(d, create_strategy(A = asset_config("etf", share = 1, spread = 0.1)), start_value = 10000)
  w <- r$worth; yrs <- as.numeric(r$dates[n] - r$dates[1]) / 365.25
  expect_false(r$external_flows)
  expect_identical(r$cagr, (w[n] / w[1])^(1 / yrs) - 1)
  rm <- cummax(w)
  expect_identical(r$drawdowns, ifelse(rm > 0, (rm - w) / rm, 0))
  expect_identical(r$statistics$calmar, r$cagr / max(r$drawdowns))
  expect_identical(r$invested, rep(10000, n))   # R3B-03: start_value brutto (vorher w[1] nach Kaufkosten)
  expect_equal(r$twr_index, w / w[1], tolerance = 1e-12)
  out <- capture.output(print(r))
  expect_false(any(grepl("geldgewichtet|zeitgewichtet|Eingezahlt", out)))
  expect_true(any(out == sprintf("  CAGR:             %+.2f%%", r$cagr * 100)))
  # XIRR ohne Einzahlungen = CAGR-Formel (gleiche Tageskonvention)
  expect_equal(SimLev:::.xirr_rate(0, w[1], w[n], yrs), (w[n] / w[1])^(1 / yrs) - 1, tolerance = 1e-13)
})

test_that("Punkt 2: XIRR ohne Loesung -> NA, Totalverlust -> -100 %", {
  # Einzahlung am letzten Tag (Gewicht 1) groesser als der Endwert: keine Nullstelle
  expect_true(is.na(SimLev:::.xirr_rate(c(0, 1), c(100, 100), 50, 1)))
  expect_identical(SimLev:::.xirr_rate(c(0, 0.5), c(100, 100), 0, 1), -1)
  # mehrere Einzahlungen: Kapitalwert an der Loesung 0
  t <- c(0, 0.25, 0.5, 0.75); a <- c(1000, 500, 500, 500); v <- 2700
  x <- SimLev:::.xirr_rate(t, a, v, 1)
  expect_lt(abs(sum(a * (1 + x)^(1 - t)) - v), 1e-9)
})

test_that("Punkt 2: print/summary und Grafiken beschriften CAGR geldgewichtet, Drawdown zeitgewichtet", {
  r <- .fm_dca()
  out <- capture.output(print(r))
  expect_true(any(grepl("CAGR: .*\\(geldgewichtet, XIRR\\)", out)))
  expect_true(any(grepl("Risiko (zeitgewichtet", out, fixed = TRUE)))
  expect_true(any(grepl("Eingezahlt:       2000.00 EUR", out, fixed = TRUE)))
  sm <- summary(r); out_s <- capture.output(print(sm))   # C7-06: summary() druckt nicht selbst
  expect_equal(sm$total_return, 0.5, tolerance = 1e-12)          # zeitgewichtet (vorher 3375 / 1000 - 1)
  expect_equal(sm$invested, 2000)
  expect_true(any(grepl("Gesamtrendite (zeitgewichtet): +50.00 %", out_s, fixed = TRUE)))   # C: neue Beschriftung (vorher "Gesamtrendite:    +50.00% (zeitgewichtet)")
  grDevices::pdf(NULL); on.exit(grDevices::dev.off())
  expect_silent(plot(r))
  expect_silent(plot(r, compare = r))
})
