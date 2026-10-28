# Steuerrecht, Fondsmodus und spaeter startende Assets (Pruefbericht am Gesetzestext).
# Je Punkt ein Test mit Handrechnung; "vorher" = Ergebnis vor der Korrektur.

.tl_days <- function(from, to) seq.Date(as.Date(from), as.Date(to), by = "day")
# stueckweise konstanter Kurs: Wert v[i] ab Datum at[i]
.tl_step <- function(dates, at, v) v[findInterval(as.numeric(dates), as.numeric(as.Date(at)))]
.tl_flag <- function(dates, at) dates %in% as.Date(at)
.tl_sim <- function(...) suppressWarnings(suppressMessages(simulation(...)))

# ---------------------------------------------------------------------------
# A1: Vorabpauschale bei Kauf im laufenden Jahr (§ 18 Abs. 1-2 InvStG)
# ---------------------------------------------------------------------------
test_that("A1: VP bei Kauf im Jahr bezieht sich auf den Jahresanfangskurs, Zwoelftel nach dem Deckel", {
  dd <- .tl_days("2021-01-01", "2022-01-10")
  run <- function(p_end) {
    d <- data.frame(date = dd, A = .tl_step(dd, c("2021-01-01", "2021-04-15", "2021-12-31"), c(100, 120, p_end)))
    d$b <- .tl_flag(dd, "2021-04-15"); d$s <- FALSE
    st <- create_strategy(A = asset_config("etf", "signal", share = 1, spread = 0,
                                           signal_buy = "b", signal_sell = "s"))
    .tl_sim(d, st, tax = tax_profile(sparer_pauschbetrag = 0, base_rate = 2.5), fractions = FALSE)
  }
  # Kauf 15.04. zu 120: floor(10000 / 120) = 83 Stueck, 40 EUR Cash. P_Anfang = 100, f = (13 - 4) / 12 = 0,75.
  # P_Ende = 110: VP = 83 x min(100 x 0,7 x 0,025 = 1,75; 110 - 100 = 10) x 0,75 = 108,9375 EUR,
  #   Steuer 108,9375 x 26,375 % = 28,7323 EUR (vorher: Bezug Kaufkurs 120 -> Zuwachs 0 -> VP 0).
  r <- run(110)
  expect_equal(r$tax_report$total_taxes_paid, 83 * 1.75 * 0.75 * 0.26375, tolerance = 1e-10)
  i <- match(as.Date(c("2021-12-31", "2022-01-01")), r$dates)
  expect_equal(r$report$A$money[i], c(40, 40 - 83 * 1.75 * 0.75 * 0.26375), tolerance = 1e-10)   # Zahlung am 01.01. aus Cash
  # P_Ende = 101: Deckel 101 - 100 = 1 < 1,75 -> VP = 83 x 1 x 0,75 = 62,25 EUR, Steuer 16,4184 EUR
  #   (Zwoelftelung nach dem Deckel; vorher 0).
  expect_equal(run(101)$tax_report$total_taxes_paid, 83 * 1 * 0.75 * 0.26375, tolerance = 1e-10)
})

# ---------------------------------------------------------------------------
# A2: Basiszins vom ersten Handelstag des Bewertungsjahres (§ 18 Abs. 4 InvStG)
# ---------------------------------------------------------------------------
test_that("A2: zeitvariabler Basiszins: Wert vom ersten Handelstag des Jahres, nicht vom 31.12.", {
  dd <- .tl_days("2020-12-28", "2022-01-07")
  dd <- dd[!format(dd, "%u") %in% c("6", "7") & dd != as.Date("2021-01-01")]   # Werktage, 01.01.2021 Feiertag
  d <- data.frame(date = dd, A = ifelse(dd < as.Date("2021-01-04"), 100,
                                        100 + 20 * as.numeric(dd - as.Date("2021-01-04")) / as.numeric(as.Date("2021-12-31") - as.Date("2021-01-04"))))
  d$A[dd > as.Date("2021-12-31")] <- 120
  d$br <- ifelse(dd < as.Date("2021-01-01"), 9, ifelse(dd == as.Date("2021-12-31"), 0.5, ifelse(dd > as.Date("2021-12-31"), 1, 2.5)))
  st <- create_strategy(A = asset_config("etf", share = 1, spread = 0))
  r <- .tl_sim(d, st, start_value = 10050, tax = tax_profile(sparer_pauschbetrag = 0, base_rate = "br"), fractions = FALSE)
  # 100 Stueck seit 28.12.2020 (ganzjaehrig, f = 1), P_Anfang = 100 (01.01., LOCF), P_Ende = 120.
  # Erster Handelstag 2021 = 04.01. (Basiszins 2,5 %): VP = 100 x min(100 x 0,7 x 0,025 = 1,75; 20) = 175 EUR,
  # Steuer 175 x 26,375 % = 46,15625 EUR. Vorher Wert vom 31.12. (0,5 %): VP 35, Steuer 9,23125 EUR.
  # (Der aufgefuellte 01.01. traegt per LOCF 9 % aus 2020 und zaehlt nicht.)
  expect_equal(r$tax_report$total_taxes_paid, 175 * 0.26375, tolerance = 1e-10)
})

# ---------------------------------------------------------------------------
# A3: Zufluss der VP am ersten Werktag des Folgejahres (§ 18 Abs. 3 InvStG)
# ---------------------------------------------------------------------------
.tl_a3 <- function(to, use_spb = TRUE, base_rate = 2, details = FALSE) {
  dd <- .tl_days("2021-01-01", to)
  d <- data.frame(date = dd, E = 100 + 10 * pmin(1, as.numeric(dd - dd[1]) / 364),
                  C = .tl_step(dd, c("2021-01-01", "2021-06-01"), c(100, 130)))
  d$b <- .tl_flag(dd, c("2021-01-01", "2022-01-01")); d$s <- .tl_flag(dd, "2021-06-01")
  st <- create_strategy(E = asset_config("etf", share = 0.5, spread = 0),
                        C = asset_config("certificate", "signal", share = 0.5, spread = 0,
                                         signal_buy = "b", signal_sell = "s"))
  args <- list(d, st, start_value = 10100, tax = tax_profile(base_rate = base_rate, sparer_pauschbetrag = if (use_spb) 1000 else 0),
               fractions = FALSE, details = details)
  if (details) { out <- capture.output(r <- do.call(.tl_sim, args)); list(r = r, out = out) } else do.call(.tl_sim, args)
}
test_that("A3: VP-Steuer mit den Toepfen des Zuflussjahres, vor den Trades des Tages, Fallback am letzten Tag", {
  # E: 50 Stueck zu 100 (Cash 50), 31.12.2021 Kurs 110: VP = 50 x min(100 x 0,7 x 0,02 = 1,4; 10) = 70 EUR.
  # C: 50 Stueck, Verkauf 01.06.2021 zu 130: Gewinn 1500 -> Pauschbetrag 2021 voll (1000), 500 versteuert = 131,875 EUR.
  # Zufluss der VP am 01.01.2022 mit dem Pauschbetrag 2022 -> Steuer 0, genutzt 1000 + 70 = 1070.
  # Vorher: Steuer mit dem erschoepften Pauschbetrag 2021 = 70 x 26,375 % = 18,4625 EUR, genutzt 1000.
  r <- .tl_a3("2022-01-10")
  expect_equal(r$tax_report$total_taxes_paid, 500 * 0.26375, tolerance = 1e-10)
  expect_equal(r$tax_report$sparer_pauschbetrag_used, 1070, tolerance = 1e-10)
  # Reihenfolge am 01.01.2022: VP-Zufluss vor dem Kauf (Trade) desselben Tages
  o <- .tl_a3("2022-01-10", details = TRUE)$out
  i_vp <- grep("Vorabpauschale E (festgesetzt", o, fixed = TRUE)
  i_tr <- grep("Kauf .* C .* am 2022-01-01", o)
  expect_length(i_vp, 1L); expect_true(length(i_tr) == 1L && i_vp < i_tr)
  # Simulation endet am 31.12.2021 (kein weiterer Handelstag): gerechnet wie zu Beginn von 2022
  # (Pauschbetrag voll) -> Steuer 0, genutzt 1070; ohne Pauschbetrag 70 x 26,375 % = 18,4625 EUR,
  # am letzten Tag aus dem Cash belastet (vorher: sofort mit den Toepfen 2021).
  r2 <- .tl_a3("2021-12-31")
  expect_equal(r2$tax_report$total_taxes_paid, 500 * 0.26375, tolerance = 1e-10)
  expect_equal(r2$tax_report$sparer_pauschbetrag_used, 1070, tolerance = 1e-10)
  r3 <- .tl_a3("2021-12-31", use_spb = FALSE); r0 <- .tl_a3("2021-12-31", use_spb = FALSE, base_rate = NULL)
  expect_equal(r3$tax_report$total_taxes_paid, (1500 + 70) * 0.26375, tolerance = 1e-10)
  n <- length(r3$worth)
  expect_equal(r0$worth[n] - r3$worth[n], 70 * 0.26375, tolerance = 1e-10)
  expect_equal(r0$worth[n - 1], r3$worth[n - 1])
})

# ---------------------------------------------------------------------------
# A4: Sparer-Pauschbetrag bei spaeteren Verlusten (§ 20 Abs. 9 Satz 4, § 43a Abs. 3 EStG)
# ---------------------------------------------------------------------------
test_that("A4: Verlust nach Pauschbetragsnutzung: erst Erstattung, dann Freigabe des Pauschbetrags, Rest in den Topf", {
  dd <- .tl_days("2021-01-01", "2021-12-31")
  d <- data.frame(date = dd, X = .tl_step(dd, c("2021-01-01", "2021-03-01"), c(100, 140)),
                  Y = .tl_step(dd, c("2021-01-01", "2021-06-01"), c(100, 100 - 1467.03 / 50)))
  d$b <- .tl_flag(dd, "2021-01-01"); d$sx <- .tl_flag(dd, "2021-03-01"); d$sy <- .tl_flag(dd, "2021-06-01")
  st <- create_strategy(X = asset_config("certificate", "signal", share = 0.5, spread = 0, signal_buy = "b", signal_sell = "sx"),
                        Y = asset_config("certificate", "signal", share = 0.5, spread = 0, signal_buy = "b", signal_sell = "sy"))
  r <- .tl_sim(d, st, tax = tax_profile())
  # Gewinn 2000 (Pauschbetrag 1000, versteuert 1000 = 263,75 EUR), danach Verlust 1467,03:
  # Erstattung der Steuer auf 1000 (263,75), Rest 467,03 gibt Pauschbetrag frei -> genutzt 532,97,
  # Verlustvortrag 0 (vorher: genutzt 1000, Vortrag 467,03). Invariante: min(1000, 2000 - 1467,03) = 532,97.
  expect_equal(r$tax_report$total_taxes_paid, 0, tolerance = 1e-9)
  expect_equal(r$tax_report$sparer_pauschbetrag_used, 532.97, tolerance = 1e-9)
  expect_equal(r$tax_report$loss_carryforward_capital, 0, tolerance = 1e-9)

  # Mit Verlustvortrag aus dem Vorjahr: 2021 Verlust 300 (Topf 300). 2022: Gewinn 2000 (Topf 300,
  # Pauschbetrag 1000, versteuert 700 = 184,625 EUR), dann Verlust 1000: Erstattung auf 700, Rest 300 gibt
  # Pauschbetrag frei -> genutzt 700 = min(1000, 2000 - 1000 - 300), Topf 0 (vorher: genutzt 1000, Topf 300).
  dd <- .tl_days("2021-01-01", "2022-12-31")
  d <- data.frame(date = dd, X = .tl_step(dd, c("2021-01-01", "2022-03-01"), c(100, 140)),
                  Y = .tl_step(dd, c("2021-01-01", "2021-06-01"), c(100, 94)),
                  Z = .tl_step(dd, c("2021-01-01", "2022-06-01"), c(100, 80)))
  d$b <- .tl_flag(dd, "2021-01-01"); d$sx <- .tl_flag(dd, "2022-03-01"); d$sy <- .tl_flag(dd, "2021-06-01"); d$sz <- .tl_flag(dd, "2022-06-01")
  cf <- function(s) asset_config("certificate", "signal", share = 1/3, spread = 0, signal_buy = "b", signal_sell = s)
  r <- .tl_sim(d, create_strategy(X = cf("sx"), Y = cf("sy"), Z = cf("sz")), start_value = 15000, tax = tax_profile())
  expect_equal(r$tax_report$total_taxes_paid, 0, tolerance = 1e-9)
  expect_equal(r$tax_report$sparer_pauschbetrag_used, 700, tolerance = 1e-9)
  expect_equal(r$tax_report$loss_carryforward_capital, 0, tolerance = 1e-9)
})

# ---------------------------------------------------------------------------
# A5: § 23 EStG Freigrenze auf den Jahressaldo, Verlustvortrag erst ab Erreichen (BFH IX R 27/04)
# ---------------------------------------------------------------------------
test_that("A5: Freigrenze vor Verlustvortrag, genau 1000 EUR steuerpflichtig", {
  dd <- .tl_days("2021-01-01", "2022-12-31")
  run <- function(x_sell, z_sell) {
    d <- data.frame(date = dd, X = .tl_step(dd, c("2021-01-01", "2021-06-01"), c(100, x_sell)),
                    Z = .tl_step(dd, c("2021-01-01", "2022-06-01"), c(100, z_sell)))
    d$bx <- .tl_flag(dd, "2021-01-01"); d$bz <- .tl_flag(dd, "2022-02-01")
    d$sx <- .tl_flag(dd, "2021-06-01"); d$sz <- .tl_flag(dd, "2022-06-01")
    cf <- function(b, s) asset_config("etc", "signal", share = 0.5, spread = 0, deliverable = TRUE, signal_buy = b, signal_sell = s)
    .tl_sim(d, create_strategy(X = cf("bx", "sx"), Z = cf("bz", "sz")), tax = tax_profile(income = income_rate(marginal_rate = 40)))
  }
  # je 50 Stueck zu 100; X 2021 Verlust 50 x (100 - x_sell), Z 2022 Gewinn 50 x (z_sell - 100), Grenzsteuersatz 40 %
  r <- run(90, 116)    # Vortrag 500, Saldo 2022 = 800 < 1000: steuerfrei, Vortrag bleibt 500 (vorher: Vortrag 0)
  expect_equal(r$tax_report$total_taxes_paid, 0)
  expect_equal(r$tax_report$loss_carryforward_private, 500)
  r <- run(90, 124)    # Saldo 1200 >= 1000: steuerpflichtig 1200 - 500 = 700 -> 280 EUR, Vortrag 0 (vorher: 700 <= 1000 -> 0)
  expect_equal(r$tax_report$total_taxes_paid, 700 * 0.4, tolerance = 1e-10)
  expect_equal(r$tax_report$loss_carryforward_private, 0)
  r <- run(100, 120)   # Saldo genau 1000 ("weniger als 1000" steuerfrei): steuerpflichtig -> 400 EUR (vorher 0)
  expect_equal(r$tax_report$total_taxes_paid, 1000 * 0.4, tolerance = 1e-10)
  r <- run(100, 119.98) # Saldo 999 < 1000: steuerfrei
  expect_equal(r$tax_report$total_taxes_paid, 0)
})

# ---------------------------------------------------------------------------
# A6: Haltefrist bei Kauf am 29.02. (§ 188 Abs. 3 BGB)
# ---------------------------------------------------------------------------
test_that("A6: Kauf 29.02.: Fristende 28.02., Verkauf am 01.03. steuerfrei; Normalfall unver\u00e4ndert", {
  run <- function(buy, sell) {
    dd <- .tl_days(buy, as.Date(sell) + 5)
    d <- data.frame(date = dd, X = ifelse(dd == as.Date(buy), 100, 200))
    d$b <- .tl_flag(dd, buy); d$s <- .tl_flag(dd, sell)
    st <- create_strategy(X = asset_config("etc", "signal", share = 1, spread = 0, deliverable = TRUE,
                                           signal_buy = "b", signal_sell = "s"))
    .tl_sim(d, st, tax = tax_profile(income = income_rate(marginal_rate = 40)))$tax_report$total_taxes_paid
  }
  # 100 Stueck zu 100, Verkauf zu 200: Gewinn 10000 -> bei Steuerpflicht 4000 EUR
  expect_equal(run("2020-02-29", "2021-02-28"), 4000)   # innerhalb der Frist
  expect_equal(run("2020-02-29", "2021-03-01"), 0)      # vorher 4000 (Fristende 01.03. angenommen)
  expect_equal(run("2021-03-10", "2022-03-10"), 4000)
  expect_equal(run("2021-03-10", "2022-03-11"), 0)
})

# ---------------------------------------------------------------------------
# C10: Spaeter startende Assets
# ---------------------------------------------------------------------------
test_that("C10: Am Aktivierungstag wird auch ohne balance_mode auf die Zielgewichte umgeschichtet", {
  dd <- .tl_days("2021-01-01", "2021-12-31")
  d <- data.frame(date = dd, A = 100, B = 50)
  st <- create_strategy(A = asset_config("etf", share = 0.5, spread = 0),
                        B = asset_config("etf", share = 0.5, spread = 0, start = as.Date("2021-07-01")))
  expect_no_warning(r <- suppressMessages(simulation(d, st)))
  i <- match(as.Date(c("2021-06-30", "2021-07-01", "2021-12-31")), dd)
  # bis 30.06. alles in A (100 Stueck), am 01.07. 50 Stueck A verkauft, 100 Stueck B gekauft (vorher B leer, Warnung)
  expect_equal(r$report$A$worth[i], c(10000, 5000, 5000))
  expect_equal(r$report$B$worth[i], c(0, 5000, 5000))
  # fuehrende NA wirken wie start
  d2 <- d; d2$B[dd < as.Date("2021-07-01")] <- NA
  r2 <- suppressMessages(simulation(d2, create_strategy(A = asset_config("etf", share = 0.5, spread = 0),
                                                        B = asset_config("etf", share = 0.5, spread = 0))))
  expect_equal(r2$report$B$worth[i], c(0, 5000, 5000))
  expect_equal(r2$worth, r$worth)
  # mit balance_mode ebenso (danach normaler Rhythmus)
  r3 <- .tl_sim(d, st, rebalance = rebalance_plan(unit = "year"))
  expect_equal(r3$report$B$worth[i], c(0, 5000, 5000))
})
