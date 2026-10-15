# Engine-Erweiterungen: A Einkommensteuertarif (taxable_income), B undefined_metrics, C summary-Renditen,
# D Warnung funds_fee/bonus_fee, E open_lots
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
.en_p23 <- function(p2 = 150, end = "2021-03-31", ...) {
  d <- .en_days("2020-01-01", end)
  df <- data.frame(date = d, G = ifelse(d < as.Date("2020-06-01"), 100, p2), H = 50)
  df$ev <- d == as.Date("2020-07-01"); df$wG <- 0; df$wH <- 1
  st <- create_strategy(G = asset_config("etc", "bnh", asset_share = 0.5, asset_spread = 0, deliverable = TRUE),
                        H = asset_config("certificate", "bnh", asset_share = 0.5, asset_spread = 0))
  .en_sim(df, st, start_value = 1e4, tax_mode = "person", event_col = "ev", event_mode = "replace",
          event_weight = c(G = "wG", H = "wH"), ...)
}
# Zertifikat Z (§ 20): 200 Stueck zu 50, am 1.7.2020 zu 70 nach M umgeschichtet -> Gewinn 4000, nach SPB K = 3000
.en_gp <- function(end = "2021-03-31", pz = 70, ...) {
  d <- .en_days("2020-01-01", end)
  df <- data.frame(date = d, Z = ifelse(d < as.Date("2020-06-01"), 50, pz), M = 100)
  df$ev <- d == as.Date("2020-07-01"); df$wZ <- 0; df$wM <- 1
  st <- create_strategy(Z = asset_config("certificate", "bnh", asset_share = 0.5, asset_spread = 0),
                        M = asset_config("certificate", "bnh", asset_share = 0.5, asset_spread = 0))
  .en_sim(df, st, start_value = 2e4, tax_mode = "person", event_col = "ev", event_mode = "replace",
          event_weight = c(Z = "wZ", M = "wM"), ...)
}

# ---------------------------------------------------------------- A a) § 23 mit Tarif
test_that("A a) § 23-Steuer mit Tarif: ESt-Zuwachs, Soli-Zuwachs exakt, KiSt 9 %", {
  # zvE 74 000, Gewinn 2500: T(76 500) - T(74 000) = 20 994 - 19 944 = 1050; Soli S(20 994) - S(19 944)
  # = 0,119 x (20 994 - 20 350) = 76,636 -> 76,63 - 0; KiSt 9 % x 1050 = 94,50 -> 1221,13
  r <- .en_p23(taxable_income = 74000, church_tax = 9)
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
  expect_equal(.en_p23(taxable_income = 50000)$tax_report$total_taxes_paid, .en_T(52500) - .en_T(50000))
  expect_equal(.en_T(52500) - .en_T(50000), 889)
})

test_that("A a) Soli-Freigrenze knapp unter/\u00fcber (ESt 20 350 bzw. 20 351)", {
  # zvE 72 466 + 2500 = 74 966: ESt 20 350 (nicht ueber der Freigrenze) -> Soli 0; ESt-Zuwachs 20 350 - 19 300
  r0 <- .en_p23(taxable_income = 72466)
  expect_equal(r0$tax_report$total_taxes_paid, 1050)
  expect_equal(r0$tax_report$tariff_years$soli_p23[1], 0)
  # zvE 72 469 + 2500 = 74 969: ESt 20 351 -> Soli 0,119 x 1 = 0,119 -> 0,11; ESt-Zuwachs 20 351 - 19 301
  r1 <- .en_p23(taxable_income = 72469)
  expect_equal(r1$tax_report$total_taxes_paid, 1050.11)
})

test_that("A a) Freigrenze § 23 (1000 EUR) mit Tarif", {
  # Gewinn 50 x 19,98 = 999 < 1000: steuerfrei; 50 x 20 = 1000: steuerpflichtig T(51 000) - T(50 000)
  r <- .en_p23(p2 = 119.98, taxable_income = 50000)
  expect_equal(r$tax_report$total_taxes_paid, 0)
  expect_equal(r$tax_report$tariff_years$gain_p23[1], 0)
  r2 <- .en_p23(p2 = 120, taxable_income = 50000)
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
  st <- create_strategy(G = asset_config("etc", "bnh", asset_share = 0.5, asset_spread = 0, deliverable = TRUE),
                        H = asset_config("certificate", "bnh", asset_share = 0.5, asset_spread = 0))
  r <- .en_sim(df, st, start_value = 1e4, tax_mode = "person", taxable_income = 50000, event_col = "ev",
               event_mode = "replace", event_weight = c(G = "wG", H = "wH"))
  ty <- r$tax_report$tariff_years
  expect_equal(ty$tax_p23, c(0, .en_T(52750) - .en_T(50000)))
  expect_equal(ty$gain_p23, c(0, 2750))
  expect_equal(tail(r$worth, 1), 8500 + 4250 - (.en_T(52750) - .en_T(50000)), tolerance = 1e-9)
})

test_that("A Pruefungen: taxable_income-Formen, fehlendes Jahr, Warnungen", {
  d1 <- .en_p23(taxable_income = 74000)$tax_report$total_taxes_paid
  expect_equal(.en_p23(taxable_income = c("2020" = 74000, "2021" = 1))$tax_report$total_taxes_paid, d1)
  expect_equal(.en_p23(taxable_income = data.frame(year = 2020:2021, taxable_income = 74000))$tax_report$total_taxes_paid, d1)
  expect_error(.en_p23(taxable_income = c("2020" = 74000)), "taxable_income fehlt f\u00fcr Simulationsjahr 2021")
  expect_error(.en_p23(taxable_income = c(1, 2)), "muss nach Kalenderjahren benannt sein")
  expect_error(.en_p23(taxable_income = c("2020" = 1, "x" = 2)), "Name 'x' ist kein Kalenderjahr")
  expect_error(.en_p23(taxable_income = NA_real_), "ung\u00fcltigen Wert")
  expect_error(.en_p23(taxable_income = "50000"), "taxable_income muss eine Zahl")
  # marginal_tax_rate / include_soli_on_income_tax wirken mit taxable_income nicht (Warnung)
  w <- tryCatch(suppressMessages(simulation(
    data.frame(date = .en_days("2020-01-01", "2020-03-01"), A = 100),
    create_strategy(A = asset_config("etf", "bnh", asset_share = 1)), tax_mode = "person",
    taxable_income = 50000, marginal_tax_rate = 42, include_soli_on_income_tax = TRUE)), warning = conditionMessage)
  expect_match(w, "marginal_tax_rate, include_soli_on_income_tax wirkt dann nicht")
  expect_equal(.en_p23(taxable_income = 74000, marginal_tax_rate = 20)$tax_report$total_taxes_paid, d1)
  expect_warning(suppressMessages(simulation(data.frame(date = .en_days("2020-01-01", "2020-03-01"), A = 100),
                                             create_strategy(A = asset_config("etf", "bnh", asset_share = 1)),
                                             taxable_income = 50000)), "taxable_income wirkt nur bei tax_mode = \"person\"")
  expect_warning(suppressMessages(simulation(data.frame(date = .en_days("2020-01-01", "2020-03-01"), A = 100),
                                             create_strategy(A = asset_config("etf", "bnh", asset_share = 1)), tax_mode = "person",
                                             tax_tariff = read_tax_tariff())), "tax_tariff wirkt nur zusammen mit taxable_income")
})

# ---------------------------------------------------------------- A b) Guenstigerpruefung
test_that("A b) G\u00fcnstigerpr\u00fcfung: Erstattung am Abrechnungstag im Endwert", {
  # K = 4000 - SPB 1000 = 3000, Abgeltungsteuer 3000 x 26,375 % = 791,25; Tarif T(13 000) - T(10 000) = 95
  # (y = 0,0652: 95,17 -> 95) -> Erstattung 696,25 am 1.1.2021 (Abrechnungstag)
  r <- .en_gp(taxable_income = 10000, use_guenstigerpruefung = TRUE)
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
  r0 <- .en_gp(taxable_income = 10000)
  expect_equal(r0$tax_report$total_taxes_paid, 791.25); expect_true(is.na(r0$tax_report$tariff_years$tariff_burden[1]))
  # hohes zvE: ESt 0,42 x 3000 = 1260 (32 124 - 30 864), Soli-Zuwachs (Milderungszone) 0,119 x 11 774 = 1401,10
  # minus 0,119 x 10 514 = 1251,16 -> 149,94; Tarif 1409,94 > 791,25 -> keine Erstattung
  rh <- .en_gp(taxable_income = 100000, use_guenstigerpruefung = TRUE)
  expect_false(rh$tax_report$tariff_years$guenstiger[1]); expect_equal(rh$tax_report$tariff_years$tariff_burden[1], 1409.94)
  expect_equal(rh$tax_report$total_taxes_paid, 791.25)
})

test_that("A b) G\u00fcnstigerpr\u00fcfung im finalen Jahresabschluss und mit KiSt 9 %", {
  # Datenende 2020-12-30: Erstattung am letzten Tag, im Endwert enthalten
  r <- .en_gp(end = "2020-12-30", taxable_income = 10000, use_guenstigerpruefung = TRUE)
  expect_equal(tail(r$worth, 1), 24000 - 95)
  # KiSt 9 %: Abgeltungsteuer 3000 x 25 % / 1,0225 x 1,145 = 839,85, darin KiSt 3000 x 25 % / 1,0225 x 9 % = 66,01;
  # mit Guenstigerpruefung ist diese KiSt 2020 Sonderausgabe: zvE 10 000 - 66,01 + K 3000 = 12 933 -> T = 85
  # (y = 0,0585), KiSt 7,65 -> Belastung 92,65 < 839,85 -> Erstattung 747,20; KiSt-Bescheid 7,65 - 66,01 = -58,36
  # (Erstattung 2021 -> Hinzurechnung 2021: zvE 10 058,36, T weiter 0)
  rk <- .en_gp(taxable_income = 10000, use_guenstigerpruefung = TRUE, church_tax = 9)
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
  rl <- .en_gp(pz = 30, taxable_income = 10000, use_guenstigerpruefung = TRUE)
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
  st <- create_strategy(A = asset_config("etf", "bnh", asset_share = 1, asset_spread = 0, asset_bonus = 30))
  r <- .en_sim(df, st, start_value = 1e6, tax_mode = "person", base_rate = 2.29, taxable_income = 10000, use_guenstigerpruefung = TRUE)
  r0 <- .en_sim(df, st, start_value = 1e6, tax_mode = "person", base_rate = 2.29)
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
  st <- create_strategy(G = asset_config("etc", "bnh", asset_share = 0.5, asset_spread = 0, deliverable = TRUE),
                        H = asset_config("certificate", "bnh", asset_share = 0.5, asset_spread = 0))
  r <- .en_sim(df, st, start_value = 1e4, tax_mode = "person", taxable_income = c("2020" = 50000, "2021" = 60000),
               church_tax = 9, event_col = "ev", event_mode = "replace", event_weight = c(G = "wG", H = "wH"))
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
  rg <- .en_gp(taxable_income = 10000, church_tax = 9)
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
  st <- create_strategy(Z = asset_config("certificate", "bnh", asset_share = 0.5, asset_spread = 0),
                        M = asset_config("certificate", "bnh", asset_share = 0.5, asset_spread = 0))
  r <- .en_sim(df, st, start_value = 2e4, tax_mode = "person", taxable_income = 14000, use_guenstigerpruefung = TRUE,
               church_tax = 9, event_col = "ev", event_mode = "replace", event_weight = c(Z = "wZ", M = "wM"))
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
  out <- capture.output(.en_gp(taxable_income = 10000, use_guenstigerpruefung = TRUE, details = TRUE))
  expect_true(any(grepl("Tarif 2020: zvE 10000.00 EUR - KiSt-Sonderausgaben 0.00 EUR (gezahlt 0.00, erstattet 0.00) = 10000.00 EUR", out, fixed = TRUE)))
  expect_true(any(grepl("K 3000.00 EUR, Abgeltungsteuer 791.25 EUR .*Tarif auf K 95.00 EUR .*-> Tarif", out)))
  expect_true(any(grepl("Abrechnung: Erstattung 696.25 EUR", out, fixed = TRUE)))
  expect_true(any(grepl("Erstattung 696.25 EUR in den Geldbestand am 2021-01-01", out, fixed = TRUE)))
})

# ---------------------------------------------------------------- B undefined_metrics
.en_r405 <- function(...) {
  d <- .en_days("2020-01-01", "2021-06-30")
  df <- data.frame(date = d, G = ifelse(d < as.Date("2020-06-01"), 100, 150), H = ifelse(d < as.Date("2020-10-01"), 50, 1))
  df$ev <- d == as.Date("2020-07-01"); df$wG <- 0; df$wH <- 1
  st <- create_strategy(G = asset_config("etc", "bnh", asset_share = 0.5, asset_spread = 0, deliverable = TRUE),
                        H = asset_config("certificate", "bnh", asset_share = 0.5, asset_spread = 0))
  w <- character(0)
  r <- withCallingHandlers(suppressMessages(simulation(df, st, start_value = 1e4, tax_mode = "person", marginal_tax_rate = 42,
         event_col = "ev", event_mode = "replace", event_weight = c(G = "wG", H = "wH"), ...)),
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
  x <- .en_r405(dca_mode = TRUE, dca_value = 1000, dca_span = 1, dca_start = as.Date("2021-03-01")); r <- x$r
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
  x <- .en_r405(dca_mode = TRUE, dca_value = 1000, dca_span = 1, dca_days = 30, dca_start = as.Date("2021-06-01")); r <- x$r
  expect_equal(tail(r$worth, 1), 200)
  expect_true(is.na(r$cagr))
  expect_equal(.um(r, "cagr")$reason, "no_irr_solution")
  expect_equal(.um(r, "cagr")$detail, "kein interner Zinsfu\u00df: Startwert 10000.00 EUR, Einzahlungen 1000.00 EUR, Endwert 200.00 EUR")
  expect_true(any(grepl("kein interner Zinsfu\u00df gefunden", x$w)))
  expect_true(any(grepl("CAGR:             nicht definiert (kein interner Zinsfu\u00df", capture.output(print(r)), fixed = TRUE)))
})

test_that("B too_short: Einzeltag und zwei Tage", {
  df <- data.frame(date = as.Date("2020-01-01"), A = 100)
  st <- create_strategy(A = asset_config("etf", "bnh", asset_share = 1))
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
                  create_strategy(A = asset_config("etf", "bnh", asset_share = 1, asset_spread = 0)))
  expect_equal(.um(r, "skewness")$reason, "zero_volatility")
  expect_equal(.um(r, "kurtosis")$reason, "zero_volatility")
  expect_equal(.um(r, "sharpe")$reason, "zero_volatility")
  expect_equal(.um(r, "cv")$reason, "zero_mean_return")
  expect_true(any(grepl("Schiefe:          nicht definiert (Standardabweichung der 181 Tagesrenditen ist 0", capture.output(print(r)), fixed = TRUE)))
})

test_that("B no_negative_returns, no_drawdown, no_recovery (stetig steigender Kurs)", {
  d <- .en_days("2020-01-01", "2020-12-31")
  r <- simulation(data.frame(date = d, A = 100 * 1.001^(seq_along(d) - 1)),
                  create_strategy(A = asset_config("etf", "bnh", asset_share = 1, asset_spread = 0)))
  for (m in c("sortino", "omega", "gain_to_pain")) expect_equal(.um(r, m)$reason, "no_negative_returns")
  for (m in c("calmar", "serenity", "martin_ratio")) expect_equal(.um(r, m)$reason, "no_drawdown")
  expect_equal(.um(r, "avg_recovery_time")$detail, "kein Drawdown im Zeitraum")
  expect_false(any(c("cagr", "ttwror", "sharpe") %in% r$undefined_metrics$metric))
})

test_that("B alles definiert: leeres data.frame mit gleichen Spalten, Ausgabe ohne Hinweise", {
  d <- .en_days("2020-01-01", "2020-12-31")
  p <- 100 + 10 * sin(seq_along(d) / 20) + seq_along(d) / 10
  r <- simulation(data.frame(date = d, A = p), create_strategy(A = asset_config("etf", "bnh", asset_share = 1, asset_spread = 0)))
  expect_identical(dim(r$undefined_metrics), c(0L, 3L))
  expect_identical(names(r$undefined_metrics), c("metric", "reason", "detail"))
  expect_equal(r$tax_report$open_tax_debt, 0)
  expect_false(any(grepl("nicht definiert", capture.output(print(r)))))
})

# ---------------------------------------------------------------- C summary
test_that("C summary: total_return_twr, return_on_invested, Alias total_return", {
  dd <- .en_days("2020-01-01", "2021-12-31")
  p <- ifelse(dd < as.Date("2020-06-01"), 100, ifelse(dd < as.Date("2021-07-01"), 80, 100)); p[length(p)] <- 150
  r <- .en_sim(data.frame(date = dd, A = p), create_strategy(A = asset_config("etf", "bnh", asset_share = 1, asset_spread = 0)),
               start_value = 1000, dca_mode = TRUE, dca_value = 1000, dca_unit = "year", dca_span = 1, dca_skip = TRUE)
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
  r0 <- .en_sim(data.frame(date = dd, A = p), create_strategy(A = asset_config("etf", "bnh", asset_share = 1, asset_spread = 0)))
  s0 <- summary(r0); out0 <- capture.output(print(s0))
  expect_true(any(grepl("Gesamtrendite:    +50.00%", out0, fixed = TRUE)))
  expect_false(any(grepl("Gewinn je eingezahltem", out0)))
  expect_equal(s0$return_on_invested, s0$total_return_twr, tolerance = 1e-12)
})

# ---------------------------------------------------------------- D funds_fee/bonus_fee
test_that("D funds_fee/bonus_fee ohne Fondsmodus: Warnung", {
  df <- data.frame(date = .en_days("2020-01-01", "2020-03-01"), A = 100)
  st <- create_strategy(A = asset_config("etf", "bnh", asset_share = 1))
  expect_warning(simulation(df, st, funds_fee = 0.5), "funds_fee wirkt nur bei tax_mode = \"funds\" \\(hier tax_mode = \"none\"\\)")
  expect_warning(simulation(df, st, tax_mode = "person", funds_fee = 1, bonus_fee = 0), "funds_fee und bonus_fee wirkt nur")
  expect_no_warning(simulation(df, st, tax_mode = "funds", funds_fee = 0.5))
  expect_no_warning(simulation(df, st, tax_mode = "person"))
})

# ---------------------------------------------------------------- E open_lots
test_that("E open_lots: Verkauf aller offenen Lots (liquidate) ergibt denselben Gewinn", {
  d <- .en_days("2020-01-01", "2021-11-30")
  n <- length(d)
  df <- data.frame(date = d, A = 100 * 1.0005^(seq_len(n) - 1), G = 50 * 1.002^(seq_len(n) - 1))
  st <- create_strategy(A = asset_config("etf", "bnh", asset_share = 0.6, asset_spread = 0.2, asset_bonus = 30),
                        G = asset_config("etc", "bnh", asset_share = 0.4, asset_spread = 0.2, deliverable = TRUE))
  args <- list(data = df, strategy = st, start_value = 1e4, tax_mode = "person", base_rate = 2, marginal_tax_rate = 30,
               dca_mode = TRUE, dca_value = 5000, dca_span = 3, use_sparer_pauschbetrag = FALSE)
  r <- do.call(.en_sim, args)
  rl <- do.call(.en_sim, c(args, liquidate = TRUE))
  ol <- r$open_lots
  expect_identical(names(ol), c("A", "G"))
  expect_identical(ol$A$regime, "investment_fund"); expect_equal(ol$A$asset_bonus, 30)
  # Verkaufskosten fuer spaetere Rechnungen: Spread in Prozent wie asset_config, order_fee wie uebergeben
  expect_equal(ol$A$asset_spread, 0.2); expect_equal(ol$G$asset_spread, 0.2)
  expect_true("order_fee" %in% names(ol$A)); expect_null(ol$A$order_fee)
  fee <- list(fixed = 4.9, percent = 0.25, max = 59)
  rf <- .en_sim(df[1:60, ], st, start_value = 1e4, tax_mode = "person", order_fee = fee)
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
  expect_null(simulation(df[1:30, 1:2], create_strategy(A = asset_config("etf", "bnh", asset_share = 1)))$open_lots)
})

test_that("R5-05: kein Fliesskommarest im Steuer-Saldo nach vollstaendiger Erstattung (T-2 + G\u00fcnstigerpr\u00fcfung)", {
  d <- .en_days("2019-01-01", "2021-02-28")
  df <- data.frame(date = d, Z = ifelse(d < as.Date("2020-02-15"), 50, 70), M = ifelse(d < as.Date("2020-08-15"), 100, 90))
  ev <- as.Date(c("2020-03-01", "2020-09-01"))
  df$ev <- d %in% ev; df$wZ <- ifelse(d == ev[2], 1, 0); df$wM <- 1 - df$wZ
  st <- create_strategy(Z = asset_config("certificate", "bnh", asset_share = 0.5, asset_spread = 0),
                        M = asset_config("certificate", "bnh", asset_share = 0.5, asset_spread = 0))
  r <- .en_sim(df, st, start_value = 2e4, tax_mode = "person", event_col = "ev", event_mode = "replace",
               event_weight = c(Z = "wZ", M = "wM"), taxable_income = 10000, use_guenstigerpruefung = TRUE)
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
  st <- create_strategy(A = asset_config("etf", "bnh", asset_share = 0.5, asset_spread = 0, asset_bonus = 30),
                        Z = asset_config("certificate", "bnh", asset_share = 0.25, asset_spread = 0),
                        M = asset_config("certificate", "bnh", asset_share = 0.25, asset_spread = 0))
  run <- function(end, ...) .en_sim(mk(end), st, start_value = 1e4, tax_mode = "person", base_rate = 2.29, event_col = "ev",
                                    event_mode = "replace", event_weight = c(A = "wA", Z = "wZ", M = "wM"), ...)
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
  sa <- create_strategy(A = asset_config("etf", "bnh", asset_share = 1, asset_spread = 0, asset_bonus = 30))
  da <- data.frame(date = d, A = ifelse(d < as.Date("2020-12-01"), 100, 120))
  ny3 <- .en_sim(da, sa, tax_mode = "person", base_rate = 2.29)$tax_report$next_year
  expect_equal(ny3$sparer_pauschbetrag_used, 112.21); expect_equal(ny3$sparer_pauschbetrag_remaining, 1000 - 112.21)
  # ohne Pauschbetrag: VP 112,21 im Jahr 2021 versteuert; der Zwangsverkauf fuer die Steuer am 31.12.2020 gehoert
  # mit seinem Gewinn zu 2020 (A7-11) -> next_year enthaelt nur die VP, die Gesamtsteuer zusaetzlich die Verkaufssteuer
  r4 <- .en_sim(da, sa, tax_mode = "person", base_rate = 2.29, use_sparer_pauschbetrag = FALSE); ny4 <- r4$tax_report$next_year
  expect_equal(ny4$sparer_pauschbetrag_used, 0); expect_equal(ny4$sparer_pauschbetrag_remaining, 0)
  expect_equal(ny4$capital_income_taxed, 112.21)
  expect_gt(r4$tax_report$total_taxes_paid, 112.21 * 0.26375)
  # Tarifweg: Kirchensteuer-Bescheid des letzten Jahres und ob das Folgejahr schon veranlagt ist
  ny5 <- .en_sim(da, sa, tax_mode = "person", base_rate = 2.29, taxable_income = 10000)$tax_report$next_year
  expect_equal(ny5$church_tax_settlement, 0); expect_false(ny5$tariff_assessed)
  expect_null(.en_sim(da, sa)$tax_report$next_year)
})
