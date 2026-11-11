# test-steuer.R
# Steuerrecht mit Handrechnungen am Gesetzestext (§§ 20, 23, 32a EStG, InvStG, SolZG), Einkommensteuertarif als Datei, Anschaffungskosten aus den offenen Lots.
# Zusammengeführt aus test-tax-law.R, test-tariff.R, test-cost-basis.R (Inhalt wörtlich; Hilfsnamen je Teil eindeutig).
# Prüfungen je Paragraph bzw. Thema als Tabellen tabelle("<Thema>", wert(ist, soll, quelle =), ident(…), bed(…), pruef(…))
# (helper-tabelle.R); Quelle je Zeile aus dem Kommentar an der Prüfung, sonst "Handrechnung (Herleitung im Test)". Erwartete
# Werte unverändert (Liste der geprüften Werte vor und nach der Umstellung auf Tabellen in 1.4.2 je Datei verglichen).
testthat::local_edition(3)   # Edition 3 wie bisher (Config/testthat/edition in r/DESCRIPTION entfällt)

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# bis 1.4.0 test-tax-law.R
# ════════════════════════════════════════════════════════════════════════════════════════════════════
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
  tabelle("A1: Vorabpauschale bei Kauf im laufenden Jahr (§ 18 Abs. 1-2 InvStG)",
    wert(r$tax_report$total_taxes_paid,
         83 * 1.75 * 0.75 * 0.26375,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10))
  i <- match(as.Date(c("2021-12-31", "2022-01-01")), r$dates)
  tabelle("A1: Vorabpauschale bei Kauf im laufenden Jahr (§ 18 Abs. 1-2 InvStG)",
    wert(r$report$A$money[i],
         c(40, 40 - 83 * 1.75 * 0.75 * 0.26375),
         quelle = "Zahlung am 01.01. aus Cash", tol = 1e-10),
    wert(run(101)$tax_report$total_taxes_paid,
         83 * 1 * 0.75 * 0.26375,
         quelle = "P_Ende = 101: Deckel 101 - 100 = 1 < 1,75 -> VP = 83 x 1 x 0,75 = 62,25 EUR, Steuer 16,4184 EUR (Zwoelftelung nach dem Deckel; vorher 0).", tol = 1e-10))
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
  tabelle("A2: Basiszins vom ersten Handelstag des Bewertungsjahres (§ 18 Abs. 4 InvStG)",
    wert(r$tax_report$total_taxes_paid,
         175 * 0.26375,
         quelle = "100 Stueck seit 28.12.2020 (ganzjaehrig, f = 1), P_Anfang = 100 (01.01., LOCF), P_Ende = 120. Erster Handelstag 2021 = 04.01. (Basiszins 2,5 %): VP = 100 x min(100 x 0,7 x 0,025 = 1,75; 20) = 175 EUR, Steuer 175 x 26,375 % = 46,15625 EUR. Vorher Wert vom 31.12. (0,5 %): VP 35, Steuer 9,23125 EUR. (Der aufgefuellte 01.01. traegt per LOCF 9 % aus 2020 und zaehlt nicht.)", tol = 1e-10))
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
  tabelle("A3: VP-Steuer mit den Toepfen des Zuflussjahres, vor den Trades des Tages, Fallback am letzten Tag",
    wert(r$tax_report$total_taxes_paid,
         500 * 0.26375,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10),
    wert(r$tax_report$sparer_pauschbetrag_used,
         1070,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10))
  # Reihenfolge am 01.01.2022: VP-Zufluss vor dem Kauf (Trade) desselben Tages
  o <- .tl_a3("2022-01-10", details = TRUE)$out
  i_vp <- grep("Vorabpauschale E (festgesetzt", o, fixed = TRUE)
  i_tr <- grep("Kauf .* C .* am 2022-01-01", o)
  tabelle("A3: VP-Steuer mit den Toepfen des Zuflussjahres, vor den Trades des Tages, Fallback am letzten Tag",
    pruef(expect_length(i_vp, 1L),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_true(length(i_tr) == 1L && i_vp < i_tr),
          quelle = "Handrechnung (Herleitung im Test)"))
  # Simulation endet am 31.12.2021 (kein weiterer Handelstag): gerechnet wie zu Beginn von 2022
  # (Pauschbetrag voll) -> Steuer 0, genutzt 1070; ohne Pauschbetrag 70 x 26,375 % = 18,4625 EUR,
  # am letzten Tag aus dem Cash belastet (vorher: sofort mit den Toepfen 2021).
  r2 <- .tl_a3("2021-12-31")
  tabelle("A3: VP-Steuer mit den Toepfen des Zuflussjahres, vor den Trades des Tages, Fallback am letzten Tag",
    wert(r2$tax_report$total_taxes_paid,
         500 * 0.26375,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10),
    wert(r2$tax_report$sparer_pauschbetrag_used,
         1070,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10))
  r3 <- .tl_a3("2021-12-31", use_spb = FALSE); r0 <- .tl_a3("2021-12-31", use_spb = FALSE, base_rate = NULL)
  tabelle("A3: VP-Steuer mit den Toepfen des Zuflussjahres, vor den Trades des Tages, Fallback am letzten Tag",
    wert(r3$tax_report$total_taxes_paid,
         (1500 + 70) * 0.26375,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10))
  n <- length(r3$worth)
  tabelle("A3: VP-Steuer mit den Toepfen des Zuflussjahres, vor den Trades des Tages, Fallback am letzten Tag",
    wert(r0$worth[n] - r3$worth[n],
         70 * 0.26375,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10),
    wert(r0$worth[n - 1],
         r3$worth[n - 1],
         quelle = "Handrechnung (Herleitung im Test)"))
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
  tabelle("A4: Sparer-Pauschbetrag bei spaeteren Verlusten (§ 20 Abs. 9 Satz 4, § 43a Abs. 3 EStG)",
    wert(r$tax_report$total_taxes_paid,
         0,
         quelle = "Gewinn 2000 (Pauschbetrag 1000, versteuert 1000 = 263,75 EUR), danach Verlust 1467,03: Erstattung der Steuer auf 1000 (263,75), Rest 467,03 gibt Pauschbetrag frei -> genutzt 532,97, Verlustvortrag 0 (vorher: genutzt 1000, Vortrag 467,03). Invariante: min(1000, 2000 - 1467,03) = 532,97.", tol = 1e-9),
    wert(r$tax_report$sparer_pauschbetrag_used,
         532.97,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-9),
    wert(r$tax_report$loss_carryforward_capital,
         0,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-9))

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
  tabelle("A4: Sparer-Pauschbetrag bei spaeteren Verlusten (§ 20 Abs. 9 Satz 4, § 43a Abs. 3 EStG)",
    wert(r$tax_report$total_taxes_paid,
         0,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-9),
    wert(r$tax_report$sparer_pauschbetrag_used,
         700,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-9),
    wert(r$tax_report$loss_carryforward_capital,
         0,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-9))
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
  tabelle("A5: § 23 EStG Freigrenze auf den Jahressaldo, Verlustvortrag erst ab Erreichen (BFH IX R 27/04)",
    wert(r$tax_report$total_taxes_paid,
         0,
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(r$tax_report$loss_carryforward_private,
         500,
         quelle = "Handrechnung (Herleitung im Test)"))
  r <- run(90, 124)    # Saldo 1200 >= 1000: steuerpflichtig 1200 - 500 = 700 -> 280 EUR, Vortrag 0 (vorher: 700 <= 1000 -> 0)
  tabelle("A5: § 23 EStG Freigrenze auf den Jahressaldo, Verlustvortrag erst ab Erreichen (BFH IX R 27/04)",
    wert(r$tax_report$total_taxes_paid,
         700 * 0.4,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10),
    wert(r$tax_report$loss_carryforward_private,
         0,
         quelle = "Handrechnung (Herleitung im Test)"))
  r <- run(100, 120)   # Saldo genau 1000 ("weniger als 1000" steuerfrei): steuerpflichtig -> 400 EUR (vorher 0)
  tabelle("A5: § 23 EStG Freigrenze auf den Jahressaldo, Verlustvortrag erst ab Erreichen (BFH IX R 27/04)",
    wert(r$tax_report$total_taxes_paid,
         1000 * 0.4,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10))
  r <- run(100, 119.98) # Saldo 999 < 1000: steuerfrei
  tabelle("A5: § 23 EStG Freigrenze auf den Jahressaldo, Verlustvortrag erst ab Erreichen (BFH IX R 27/04)",
    wert(r$tax_report$total_taxes_paid,
         0,
         quelle = "Handrechnung (Herleitung im Test)"))
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
  tabelle("A6: Haltefrist bei Kauf am 29.02. (§ 188 Abs. 3 BGB)",
    wert(run("2020-02-29", "2021-02-28"),
         4000,
         quelle = "100 Stueck zu 100, Verkauf zu 200: Gewinn 10000 -> bei Steuerpflicht 4000 EUR innerhalb der Frist"),
    wert(run("2020-02-29", "2021-03-01"),
         0,
         quelle = "vorher 4000 (Fristende 01.03. angenommen)"),
    wert(run("2021-03-10", "2022-03-10"),
         4000,
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(run("2021-03-10", "2022-03-11"),
         0,
         quelle = "Handrechnung (Herleitung im Test)"))
})

# ---------------------------------------------------------------------------
# C10: Spaeter startende Assets
# ---------------------------------------------------------------------------
test_that("C10: Am Aktivierungstag wird auch ohne balance_mode auf die Zielgewichte umgeschichtet", {
  dd <- .tl_days("2021-01-01", "2021-12-31")
  d <- data.frame(date = dd, A = 100, B = 50)
  st <- create_strategy(A = asset_config("etf", share = 0.5, spread = 0),
                        B = asset_config("etf", share = 0.5, spread = 0, start = as.Date("2021-07-01")))
  tabelle("C10: Am Aktivierungstag wird auch ohne balance_mode auf die Zielgewichte umgeschichtet",
    pruef(expect_no_warning(r <- suppressMessages(simulation(d, st))),
          quelle = "Handrechnung (Herleitung im Test)"))
  i <- match(as.Date(c("2021-06-30", "2021-07-01", "2021-12-31")), dd)
  tabelle("C10: Am Aktivierungstag wird auch ohne balance_mode auf die Zielgewichte umgeschichtet",
    wert(r$report$A$worth[i],
         c(10000, 5000, 5000),
         quelle = "bis 30.06. alles in A (100 Stueck), am 01.07. 50 Stueck A verkauft, 100 Stueck B gekauft (vorher B leer, Warnung)"),
    wert(r$report$B$worth[i],
         c(0, 5000, 5000),
         quelle = "Handrechnung (Herleitung im Test)"))
  # fuehrende NA wirken wie start
  d2 <- d; d2$B[dd < as.Date("2021-07-01")] <- NA
  r2 <- suppressMessages(simulation(d2, create_strategy(A = asset_config("etf", share = 0.5, spread = 0),
                                                        B = asset_config("etf", share = 0.5, spread = 0))))
  tabelle("C10: Am Aktivierungstag wird auch ohne balance_mode auf die Zielgewichte umgeschichtet",
    wert(r2$report$B$worth[i],
         c(0, 5000, 5000),
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(r2$worth,
         r$worth,
         quelle = "Handrechnung (Herleitung im Test)"))
  # mit balance_mode ebenso (danach normaler Rhythmus)
  r3 <- .tl_sim(d, st, rebalance = rebalance_plan(unit = "year"))
  tabelle("C10: Am Aktivierungstag wird auch ohne balance_mode auf die Zielgewichte umgeschichtet",
    wert(r3$report$B$worth[i],
         c(0, 5000, 5000),
         quelle = "Handrechnung (Herleitung im Test)"))
})

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# bis 1.4.0 test-tariff.R
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Einkommensteuertarif als Datei (tax_tariff, § 32a Abs. 1 EStG, §§ 3, 4 SolZG ab VZ 2026)
.tt <- function() tax_tariff()
.T <- function(x, tt = .tt()) SimLev:::.tariff_income_tax(tt, x)
.S <- function(e, tt = .tt()) SimLev:::.tariff_soli(tt, e)
.tt_file <- function(lines) { f <- tempfile(fileext = ".csv"); writeLines(lines, f); f }
.tt_ok <- c("# Geltung: Testtarif", "art,ab,bezug,teiler,a,b,c", "zone,0,0,1,0,0,0",
            "zone,10001,10000,1,0,0.2,0", "soli,20350,,,5.5,11.9,")

test_that("Tarif: mitgelieferte Datei, Geltung und print", {
  tt <- .tt()
  tabelle("Tarif: mitgelieferte Datei, Geltung und print",
    pruef(expect_s3_class(tt, "SimLevTaxTariff"),
          quelle = "Handrechnung (Herleitung im Test)"),
    ident(tt$geltung,
          "ab VZ 2026",
          quelle = "Handrechnung (Herleitung im Test)"),
    wert(tt$zones$ab,
         c(0, 12349, 17800, 69879, 277826),
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(unlist(tt$soli),
         c(freigrenze = 20350, satz = 5.5, milderung = 11.9),
         quelle = "Handrechnung (Herleitung im Test)"))
  out <- capture.output(print(tt))
  tabelle("Tarif: mitgelieferte Datei, Geltung und print",
    pruef(expect_true(any(grepl("Geltung: ab VZ 2026", out, fixed = TRUE))),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_true(any(grepl("69 879 - 277 825", out, fixed = TRUE))),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_true(any(grepl("Soli: 5.5 % der ESt, wenn die ESt 20 350 EUR \u00fcbersteigt", out, fixed = TRUE))),
          quelle = "Handrechnung (Herleitung im Test)"))
  # Datei ist mit Basis-R lesbar
  d <- read.csv(system.file("extdata", "steuertarif.csv", package = "SimLev"), comment.char = "#")
  tabelle("Tarif: mitgelieferte Datei, Geltung und print",
    wert(names(d),
         c("art", "ab", "bezug", "teiler", "a", "b", "c"),
         quelle = "Handrechnung (Herleitung im Test)"))
})

test_that("Tarif: Werte an allen Zonengrenzen und Stichproben (Handrechnung)", {
  tt <- .tt()
  tabelle("Tarif: Werte an allen Zonengrenzen und Stichproben (Handrechnung)",
    wert(.T(12348, tt),
         0,
         quelle = "Zone 1 bis 12 348: 0; Zone 2 ab 12 349: y = 0,0001 -> 0,14 -> 0"),
    wert(.T(12349, tt),
         0,
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(.T(17799, tt),
         1034,
         quelle = "17 799: y = 0,5451 -> (914,51 y + 1400) y = 1034,872 -> 1034; 17 800: z = 0,0001 -> 1035,1097 -> 1035"),
    wert(.T(17800, tt),
         1035,
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(.T(69878, tt),
         18213,
         quelle = "69 878: z = 5,2079 -> 18 213,063 -> 18 213; 69 879: 0,42 x - 11 135,63 = 18 213,55 -> 18 213"),
    wert(.T(69879, tt),
         18213,
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(.T(277825, tt),
         105550,
         quelle = "277 825: 116 686,50 - 11 135,63 = 105 550,87; 277 826: 125 021,70 - 19 470,38 = 105 551,32"),
    wert(.T(277826, tt),
         105551,
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(.T(15000, tt),
         435,
         quelle = "Stichproben: 15 000 (y = 0,2652) 435,598; 50 000 (z = 3,2201) 10 548,33; 100 000: 42 000 - 11 135,63"),
    wert(.T(50000, tt),
         10548,
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(.T(100000, tt),
         30864,
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(.T(300000, tt),
         115529,
         quelle = "135 000 - 19 470,38"),
    wert(.T(17799.99, tt),
         1034,
         quelle = "zvE auf volle Euro abrunden; negatives zvE: 0"),
    wert(.T(-5000, tt),
         0,
         quelle = "Handrechnung (Herleitung im Test)"))
})

test_that("Soli: Freigrenze, Milderungszone, voller Satz, Cent abrunden", {
  tt <- .tt()
  tabelle("Soli: Freigrenze, Milderungszone, voller Satz, Cent abrunden",
    wert(.S(20350, tt),
         0,
         quelle = "Freigrenze nicht ueberschritten"),
    wert(.S(20351, tt),
         0.11,
         quelle = "min(1119,305; 0,119 x 1) = 0,119 -> 0,11"),
    wert(.S(20994, tt),
         76.63,
         quelle = "0,119 x 644 = 76,636 -> 76,63"),
    wert(.S(30000, tt),
         1148.35,
         quelle = "Milderungszone 0,119 x 9650"),
    wert(.S(37838, tt),
         2081.07,
         quelle = "0,119 x 17 488 = 2081,072 < 0,055 x 37 838 = 2081,09"),
    wert(.S(37839, tt),
         2081.14,
         quelle = "voller Satz: 0,055 x 37 839 = 2081,145 -> 2081,14"),
    wert(.S(40000, tt),
         2200,
         quelle = "Handrechnung (Herleitung im Test)"))
})

test_that("Tarifdatei: Fehlermeldungen bei kaputter Datei, Warnung bei Sprung", {
  tabelle("Tarifdatei: Fehlermeldungen bei kaputter Datei, Warnung bei Sprung",
    pruef(expect_error(tax_tariff(file.path(tempdir(), "gibt_es_nicht.csv")), "nicht gefunden"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(tax_tariff(.tt_file(sub(",c$", ",x", .tt_ok))), "fehlen die Spalten c"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(tax_tariff(.tt_file(sub("^zone,10001", "zonen,10001", .tt_ok))), "Datenzeile 2 hat ein ungültiges art"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(tax_tariff(.tt_file(sub("0.2,0$", "zwei,0", .tt_ok))), "Spalte 'b' in Datenzeile 2 .*nicht numerisch"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(tax_tariff(.tt_file(sub("^zone,0,", "zone,5,", .tt_ok))), "erste Zone muss bei ab = 0"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(tax_tariff(.tt_file(c(.tt_ok[1:3], "zone,0,0,1,0,0,0", .tt_ok[5]))), "streng aufsteigend"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(tax_tariff(.tt_file(c(.tt_ok, "soli,1,,,1,1,"))), "genau eine soli-Zeile geben \\(gefunden: 2\\)"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(tax_tariff(.tt_file(.tt_ok[-5])), "genau eine soli-Zeile geben \\(gefunden: 0\\)"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(tax_tariff(.tt_file(sub("10000,1,0,0.2", "10000,0,0,0.2", .tt_ok))), "teiler muss > 0"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(tax_tariff(.tt_file(sub("5.5,11.9", "155,11.9", .tt_ok))), "Zuschlagsatz \\(a\\) muss zwischen 0 und 100"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_warning(tax_tariff(.tt_file(sub("10001,10000,1", "10001,0,1", .tt_ok))),
                     "springt an der Zonengrenze 10001 EUR um 2000.20 EUR"),
          quelle = "Sprung: 0,2 x 10001 = 2000,20 statt 0 an der Grenze"),
    pruef(expect_no_warning(tax_tariff(.tt_file(.tt_ok))),
          quelle = "Handrechnung (Herleitung im Test)"))
})

test_that("Eigene Tarifdatei wirkt in simulation() (Datei und Objekt)", {
  # flacher Testtarif: 20 % ueber 10 000 EUR; § 23-Gewinn 2500 bei zvE 50 000 -> 500 EUR ESt, kein Soli
  f <- .tt_file(.tt_ok)
  tabelle("Eigene Tarifdatei wirkt in simulation() (Datei und Objekt)",
    wert(.T(50000, tax_tariff(f)),
         8000,
         quelle = "Handrechnung (Herleitung im Test)"))
  d <- seq.Date(as.Date("2020-01-01"), as.Date("2021-03-31"), by = "day")
  df <- data.frame(date = d, G = ifelse(d < as.Date("2020-06-01"), 100, 150), H = 50)
  df$ev <- d == as.Date("2020-07-01"); df$wG <- 0; df$wH <- 1
  st <- create_strategy(G = asset_config("etc", "bnh", share = 0.5, spread = 0, deliverable = TRUE),
                        H = asset_config("certificate", "bnh", share = 0.5, spread = 0))
  run <- function(...) suppressMessages(simulation(df, st, start_value = 1e4, rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(G = "wG", H = "wH")), tax = tax_profile(income = income_tariff(taxable_income = 50000, ...))))
  tabelle("Eigene Tarifdatei wirkt in simulation() (Datei und Objekt)",
    wert(run(tariff = f)$tax_report$total_taxes_paid,
         500,
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(run(tariff = tax_tariff(f))$tax_report$total_taxes_paid,
         500,
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(run()$tax_report$total_taxes_paid,
         11437 - 10548,
         quelle = "mitgelieferter Tarif: T(52 500) - T(50 000)"),
    pruef(expect_error(run(tariff = 42), "income_tariff: tariff muss NULL"),
          quelle = "Handrechnung (Herleitung im Test)"))
})

test_that("Plausibilitaet der Zonen (Grenzsteuersatz, T(x) <= x) und Trennzeichen", {
  base <- c("art,ab,bezug,teiler,a,b,c", "zone,0,0,1,0,0,0")
  soli <- "soli,20350,,,5.5,11.9,"
  tabelle("Plausibilitaet der Zonen (Grenzsteuersatz, T(x) <= x) und Trennzeichen",
    pruef(expect_error(tax_tariff(.tt_file(c(base, "zone,10001,0,1,0,42,-420042", soli))),
                   "Zone ab 10001 EUR \\(Datenzeile 2\\): Grenzsteuersatz 42 bei x = 10001 EUR liegt nicht zwischen 0 und 1.*0.42 f\u00fcr 42 %, nicht 42.*Soli-S\u00e4tze dagegen in Prozent"),
          quelle = "b = 42 statt 0.42 (Prozent statt Anteil): Fehler mit Zeile, Wert und Einheitenhinweis"),
    pruef(expect_error(tax_tariff(.tt_file(c(base, "zone,10001,0,1,0,-0.1,1000.1", soli))), "Grenzsteuersatz -0.1 bei x = 10001"),
          quelle = "negativer Grenzsteuersatz"),
    pruef(expect_error(tax_tariff(.tt_file(c(base, "zone,10001,10000,10000,500,1000,0", soli))),
                   "Grenzsteuersatz 100 bei x = 10000000 EUR"),
          quelle = "quadratische letzte Zone: Grenzsteuersatz am oberen Rand (10 Mio. EUR) ueber 1"),
    pruef(expect_error(tax_tariff(.tt_file(c(base, "zone,10001,0,1,0,0.2,50000", soli))),
                   "Steuer 52000.20 EUR bei x = 10001 EUR \u00fcbersteigt das Einkommen"),
          quelle = "Steuer groesser als das Einkommen (Konstante c zu gross)"),
    pruef(expect_error(tax_tariff(.tt_file(gsub(",", ";", .tt_ok))), "nur eine Spalte gelesen.*Semikolon"),
          quelle = "Semikolon-CSV (deutsches Excel) und Dezimalkomma"),
    pruef(expect_error(tax_tariff(.tt_file(sub("0.2,0$", "0,2,0", .tt_ok))),
                   "hat Datenzeile 2 insgesamt 8 Felder, die Kopfzeile 7.*Punkt \\(0.42, nicht 0,42\\)"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_no_warning(tax_tariff()),
          quelle = "mitgelieferte Datei besteht alle Pruefungen ohne Warnung; Kopf nennt die Einheiten"))
  hd <- readLines(system.file("extdata", "steuertarif.csv", package = "SimLev"))
  tabelle("Plausibilitaet der Zonen (Grenzsteuersatz, T(x) <= x) und Trennzeichen",
    pruef(expect_true(any(grepl("Grenzsteuersatz als ANTEIL, 0.42 fuer 42 % (NICHT 42)", hd, fixed = TRUE))),
          quelle = "Kopf der Tarifdatei (inst/extdata)"),
    pruef(expect_true(any(grepl("soli: PROZENT", hd, fixed = TRUE))),
          quelle = "Handrechnung (Herleitung im Test)"))
})

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# bis 1.4.0 test-cost-basis.R
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Tests: cost_basis aus den offenen Lots (open_lots) eines SimLevResult statt der Naeherung

.cb_days <- function(from, to) seq.Date(as.Date(from), as.Date(to), by = "day")

test_that("cost_basis exakt aus einem Lot mit Vorabpauschalen; Steuer der ersten Entnahme per Handrechnung", {
  d <- data.frame(date = .cb_days("2015-01-01", "2019-12-31"))
  d$A <- 100 * 1.08^(as.numeric(d$date - d$date[1]) / 365.25)
  st <- create_strategy(A = asset_config("etf", "bnh", spread = 0, partial_exemption = 30))
  r <- simulation(d, st, start_value = 1e5, tax = tax_profile(base_rate = 1))
  # Handrechnung Ansparphase: 1000 Stueck zu 100; VP je Jahr = 1000 x 0,7 x 1 % x Kurs am 1.1.
  # (Kurs um 8 % p. a. gestiegen, Basisertrag < Wertzuwachs): 700 + 755,96 + 816,57 + 881,84 + 952,34
  tage <- c(0, 365, 731, 1096, 1461)
  vp <- sum(1000 * 0.7 * 0.01 * 100 * 1.08^(tage / 365.25))
  tabelle("cost_basis exakt aus einem Lot mit Vorabpauschalen; Steuer der ersten Entnahme per Handrechnung",
    wert(vp,
         4106.7134,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-7),
    wert(r$open_lots$A$lots$units,
         1000,
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(sum(r$open_lots$A$lots$vp),
         vp,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10))
  sv <- 1000 * 100 * 1.08^(1825 / 365.25)                       # Endwert 146894,08 (Stueck x Schlusskurs)
  tabelle("cost_basis exakt aus einem Lot mit Vorabpauschalen; Steuer der ersten Entnahme per Handrechnung",
    wert(tail(r$worth, 1),
         sv,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-12))
  B <- 1e5 + vp                                                  # Anschaffungskosten + anzurechnende VP
  # Entnahmephase: ein Jahr ohne Rendite (keine neue VP), 4 % des Startwerts zu Jahresbeginn. Erstes Planjahr = 2020;
  # die am 31.12.2019 festgesetzte VP 952,34 hat dort schon 0,7 x 952,34 = 666,64 des Pauschbetrags verbraucht
  ws <- suppressMessages(withdrawal_simulation(matrix(1, 1, 1), withdrawal_rule("constant", rate = 4), start_value = r,
                                               tax = tax_profile(), partial_exemption = 30, base_rate = 1))
  spb1 <- 1000 - 0.7 * 1000 * 0.7 * 0.01 * 100 * 1.08^(1461 / 365.25)   # Rest 333,36
  tabelle("cost_basis exakt aus einem Lot mit Vorabpauschalen; Steuer der ersten Entnahme per Handrechnung",
    wert(r$tax_report$next_year$sparer_pauschbetrag_remaining,
         spb1,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10))
  X <- 0.04 * sv; g <- 1 - B / sv                                # Gewinnanteil je Euro Verkauf
  G <- (X - spb1 * 0.26375) / (1 - 0.7 * g * 0.26375)            # Bruttoverkauf fuer netto X
  tax <- (0.7 * g * G - spb1) * 0.26375
  tabelle("cost_basis exakt aus einem Lot mit Vorabpauschalen; Steuer der ersten Entnahme per Handrechnung",
    wert(ws$paths$taxes,
         tax,
         quelle = "241,03 EUR (voller Pauschbetrag: 55,20 EUR)", tol = 1e-10))
  # Engine-Rechnung (man/simulation.Rd, open_lots) fuer den Verkauf derselben s = 1000 x G / sv Stueck:
  s <- 1000 * G / sv; P <- sv / 1000
  tax_engine <- ((s * (P - 100) - vp * s / 1000) * 0.7 - spb1) * 0.26375
  tabelle("cost_basis exakt aus einem Lot mit Vorabpauschalen; Steuer der ersten Entnahme per Handrechnung",
    wert(ws$paths$taxes,
         tax_engine,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10))
  # gleich der ausdruecklichen Angabe; die alte Naeherung (Basis 1e5 ohne VP) ergab mehr Steuer
  wx <- suppressMessages(withdrawal_simulation(matrix(1, 1, 1), withdrawal_rule("constant", rate = 4), start_value = r,
                              tax = tax_profile(), partial_exemption = 30, base_rate = 1, cost_basis = 100 * B / sv))
  tabelle("cost_basis exakt aus einem Lot mit Vorabpauschalen; Steuer der ersten Entnahme per Handrechnung",
    wert(ws$paths,
         wx$paths,
         quelle = "ein Lot: FIFO = Durchschnittskosten", tol = 1e-10))
  wo <- suppressMessages(withdrawal_simulation(matrix(1, 1, 1), withdrawal_rule("constant", rate = 4), start_value = r,
                              tax = tax_profile(), partial_exemption = 30, base_rate = 1, cost_basis = 100 * 1e5 / sv))
  tabelle("cost_basis exakt aus einem Lot mit Vorabpauschalen; Steuer der ersten Entnahme per Handrechnung",
    pruef(expect_gt(wo$paths$taxes, ws$paths$taxes + 25),
          quelle = "Handrechnung (Herleitung im Test)"))
})

test_that("Umschichtungen, Sparplan, VP und Spread: Verkauf des ganzen Bestands = Steuer der Engine", {
  d <- data.frame(date = .cb_days("2015-01-01", "2020-12-31"))
  tt <- as.numeric(d$date - d$date[1]) / 365.25
  d$A <- 100 * 1.08^tt * (1 + 0.1 * sin(3 * tt)); d$B <- 50 * 1.03^tt * (1 + 0.05 * cos(5 * tt))
  st <- create_strategy(A = asset_config("etf", "bnh", share = 0.6, spread = 0.2, partial_exemption = 30),
                        B = asset_config("etf", "bnh", share = 0.4, spread = 0.2, partial_exemption = 30))
  args <- list(data = d, strategy = st, start_value = 1e5, tax = tax_profile(base_rate = 2, sparer_pauschbetrag = 0),
               dca = dca_plan(value = 500, span = 1), rebalance = rebalance_plan(span = 6))
  r0 <- suppressMessages(do.call(simulation, args))
  r1 <- suppressMessages(do.call(simulation, c(args, liquidate = TRUE)))
  tabelle("Umschichtungen, Sparplan, VP und Spread: Verkauf des ganzen Bestands = Steuer der Engine",
    pruef(expect_true(all(r0$sells > 0)),
          quelle = "Umschichtungen mit FIFO-Verkaeufen"),
    pruef(expect_gt(nrow(r0$open_lots$A$lots), 50),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_gt(sum(r0$open_lots$A$lots$vp), 0),
          quelle = "Handrechnung (Herleitung im Test)"))
  tax_engine <- r1$tax_report$total_taxes_paid - r0$tax_report$total_taxes_paid   # Steuer des Schlussverkaufs
  # ganzer Bestand in einer Entnahme (Regel 100 % des Startwerts), gleiche Toepfe: SPB 0, Verlusttopf der Ansparphase,
  # Verkaufskosten = halber Spread (0,1 %)
  ws <- withdrawal_simulation(matrix(1, 1, 1), withdrawal_rule("constant", rate = 100), start_value = r0, tax = tax_profile(sparer_pauschbetrag = 0),
                              partial_exemption = 30, sale_cost = 0.1, base_rate = 2,
                              loss_carryforward = r0$tax_report$loss_carryforward_capital)
  tabelle("Umschichtungen, Sparplan, VP und Spread: Verkauf des ganzen Bestands = Steuer der Engine",
    wert(ws$paths$taxes,
         tax_engine,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-9),
    wert(ws$paths$terminal_nominal,
         0,
         quelle = "Handrechnung (Herleitung im Test)"))
  # Handrechnung aus den Lots: (Endwert x (1 - 0,001) - Basis) x 0,7 x 26,375 %
  B <- sum(sapply(r0$open_lots, function(a) sum(a$lots$units * a$lots$price) + sum(a$lots$vp) + a$cash))
  tabelle("Umschichtungen, Sparplan, VP und Spread: Verkauf des ganzen Bestands = Steuer der Engine",
    wert(ws$paths$taxes,
         (tail(r0$worth, 1) * 0.999 - B) * 0.7 * 0.26375,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-9))
  # die alte Naeherung (Start + Einzahlungen) traf die Engine nicht
  inv <- r0$invested[1] + sum(pmax(result_index(r0)$flows[-1], 0))
  wo <- withdrawal_simulation(matrix(1, 1, 1), withdrawal_rule("constant", rate = 100), start_value = r0, tax = tax_profile(sparer_pauschbetrag = 0),
                              partial_exemption = 30, sale_cost = 0.1, base_rate = 2,
                              loss_carryforward = r0$tax_report$loss_carryforward_capital, cost_basis = 100 * inv / tail(r0$worth, 1))
  tabelle("Umschichtungen, Sparplan, VP und Spread: Verkauf des ganzen Bestands = Steuer der Engine",
    pruef(expect_gt(abs(wo$paths$taxes - tax_engine), 100),
          quelle = "Handrechnung (Herleitung im Test)"))
})

test_that("ohne open_lots: bisherige N\u00e4herung (mit Warnung bei tax_mode = 'person'); Angabe gilt immer", {
  d <- data.frame(date = .cb_days("2015-01-01", "2019-12-31"))
  d$A <- 100 * 1.08^(as.numeric(d$date - d$date[1]) / 365.25)
  st <- create_strategy(A = asset_config("etf", "bnh", spread = 0, partial_exemption = 30))
  r <- simulation(d, st, start_value = 1e5, dca = dca_plan(value = 100, span = 1))     # tax_mode = "none"
  tabelle("ohne open_lots: bisherige Näherung (mit Warnung bei tax_mode = 'person'); Angabe gilt immer",
    pruef(expect_null(r$open_lots),
          quelle = "Handrechnung (Herleitung im Test)"))
  x <- matrix(1.03, 5, 2)
  inv <- r$invested[1] + sum(pmax(result_index(r)$flows[-1], 0))
  tabelle("ohne open_lots: bisherige Näherung (mit Warnung bei tax_mode = 'person'); Angabe gilt immer",
    pruef(expect_warning(w <- withdrawal_simulation(x, start_value = r, tax = tax_profile()), "cost_basis: N\u00e4herung 100 x"),
          quelle = "Handrechnung (Herleitung im Test)"),
    ident(w$paths,
          withdrawal_simulation(x, start_value = r, tax = tax_profile(), cost_basis = 100 * inv / tail(r$worth, 1))$paths,
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_silent(withdrawal_simulation(x, start_value = r)),
          quelle = "ohne Steuern keine Warnung"))
  # aelteres Ergebnis mit tax_mode = "person", aber ohne open_lots: ebenso
  rp <- simulation(d, st, start_value = 1e5, tax = tax_profile(base_rate = 1)); rp$open_lots <- NULL
  tabelle("ohne open_lots: bisherige Näherung (mit Warnung bei tax_mode = 'person'); Angabe gilt immer",
    pruef(expect_warning(withdrawal_simulation(x, start_value = rp, tax = tax_profile()), "keine offenen Lots"),
          quelle = "Handrechnung (Herleitung im Test)"))
  # ausdruecklich angegebenes cost_basis gilt immer (keine Naeherungswarnung)
  rp2 <- simulation(d[-nrow(d), ], st, start_value = 1e5, tax = tax_profile(base_rate = 1))   # Ende 30.12.: keine offene VP
  tabelle("ohne open_lots: bisherige Näherung (mit Warnung bei tax_mode = 'person'); Angabe gilt immer",
    pruef(expect_warning(w1 <- suppressMessages(withdrawal_simulation(x, start_value = rp2, tax = tax_profile(), cost_basis = 55)), NA),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_null(w1$adopted$lots),
          quelle = "ohne FIFO-Lots"))
  w2 <- withdrawal_simulation(x, start_value = tail(rp2$worth, 1), tax = tax_profile(), cost_basis = 55)
  tabelle("ohne open_lots: bisherige Näherung (mit Warnung bei tax_mode = 'person'); Angabe gilt immer",
    ident(w1$paths,
          w2$paths,
          quelle = "Handrechnung (Herleitung im Test)"))
})

test_that("abweichende Teilfreistellung und Regime der gehaltenen Assets: Warnung", {
  d <- data.frame(date = .cb_days("2018-01-01", "2019-12-31"))
  d$A <- 100 * 1.05^(as.numeric(d$date - d$date[1]) / 365.25); d$N <- d$A; d$C <- d$A
  run <- function(st, ...) suppressMessages(simulation(d, st, start_value = 1e4, tax = tax_profile(base_rate = 1, ...)))
  x <- matrix(1.02, 3, 1)
  # asset_config-Standard partial_exemption = 0 gegen Standard 30 der Entnahmephase
  r0 <- run(create_strategy(A = asset_config("etf", "bnh", spread = 0)))
  tabelle("abweichende Teilfreistellung und Regime der gehaltenen Assets: Warnung",
    wert(suppressMessages(withdrawal_simulation(x, start_value = r0, tax = tax_profile()))$adopted$partial_exemption,
         0,
         quelle = "nicht angegeben: einheitliche Teilfreistellung uebernommen; ausdruecklich 30: Warnung"),
    pruef(expect_warning(suppressMessages(withdrawal_simulation(x, start_value = r0, tax = tax_profile(), partial_exemption = 30)),
                     "partial_exemption = 30 %, aber .*Teilfreistellung A 0 %"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_warning(suppressMessages(withdrawal_simulation(x, start_value = r0, tax = tax_profile(), partial_exemption = 0)), NA),
          quelle = "Handrechnung (Herleitung im Test)"))
  # gemischt: Fonds 30 % und ETN (capital_gains, zaehlt als 0 %)
  rm <- run(create_strategy(A = asset_config("etf", "bnh", share = 0.5, spread = 0, partial_exemption = 30),
                            N = asset_config("etn", "bnh", share = 0.5, spread = 0)))
  tabelle("abweichende Teilfreistellung und Regime der gehaltenen Assets: Warnung",
    wert(rm$open_lots$N$regime,
         "capital_gains",
         quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_warning(w <- suppressMessages(withdrawal_simulation(x, start_value = rm, tax = tax_profile())),
                     "verschiedenen Regimen \\(Investmentfonds: A; andere: N\\)"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_null(w$adopted$partial_exemption),
          quelle = "gemischt: nicht uebernommen"),
    pruef(expect_null(w$adopted$vorabpauschale),
          quelle = "gemischt: nicht uebernommen"))
  # § 23 (lieferbares ETC): nicht abbildbar
  rc <- run(create_strategy(C = asset_config("etc", "bnh", spread = 0, deliverable = TRUE)), income = income_rate(42))
  tabelle("abweichende Teilfreistellung und Regime der gehaltenen Assets: Warnung",
    wert(rc$open_lots$C$regime,
         "private_sale",
         quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_warning(suppressMessages(withdrawal_simulation(x, start_value = rc, tax = tax_profile())), "Regime 'private_sale' \\(Paragraf 23 EStG: C\\)"),
          quelle = "Handrechnung (Herleitung im Test)"))
  # Basis bleibt die exakte Lot-Basis
  w <- suppressMessages(suppressWarnings(withdrawal_simulation(x, start_value = rc, tax = tax_profile())))
  B <- with(rc$open_lots$C, sum(lots$units * lots$price) + sum(lots$vp) + cash)
  tabelle("abweichende Teilfreistellung und Regime der gehaltenen Assets: Warnung",
    wert(w$paths,
         suppressMessages(suppressWarnings(withdrawal_simulation(x, start_value = rc, tax = tax_profile(),
                                                              cost_basis = 100 * B / tail(rc$worth, 1))))$paths,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10),
    pruef(expect_silent(withdrawal_simulation(x, start_value = rm)),
          quelle = "ohne Steuern in der Entnahmephase keine Warnung"))
})

test_that("start_value <= 0 (Zahl oder Endwert eines SimLevResult) ist ein Fehler", {
  d <- .cb_days("2020-01-01", "2021-06-30")
  df <- data.frame(date = d, G = ifelse(d < as.Date("2020-06-01"), 100, 150), H = ifelse(d < as.Date("2020-10-01"), 50, 1))
  df$ev <- d == as.Date("2020-07-01"); df$wG <- 0; df$wH <- 1
  st <- create_strategy(G = asset_config("etc", "bnh", share = 0.5, spread = 0, deliverable = TRUE),
                        H = asset_config("certificate", "bnh", share = 0.5, spread = 0))
  r <- suppressWarnings(simulation(df, st, start_value = 1e4, rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(G = "wG", H = "wH")), tax = tax_profile(income = income_rate(marginal_rate = 42))))
  tabelle("start_value <= 0 (Zahl oder Endwert eines SimLevResult) ist ein Fehler",
    wert(tail(r$worth, 1),
         -800,
         quelle = "§ 23-Steuer 1050 aus 250 Restwert nicht gedeckt"),
    wert(r$tax_report$open_tax_debt,
         800,
         quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(withdrawal_simulation(matrix(1.03, 5, 1), start_value = r, tax = tax_profile(), partial_exemption = 0),
                   "start_value: Endwert der Ansparphase \\(SimLevResult\\) ist -800.*offene, nicht gedeckte Steuerschuld der Ansparphase: 800"),
          quelle = "vorher still gerechnet (Endvermoegen -927, \"Schuld\" mit Marktrendite verzinst)"))
  for (v in list(-800, 0, NA_real_, Inf, c(1, 2), "1e5"))
    expect_error(withdrawal_simulation(matrix(1.03, 5, 1), start_value = v), "start_value muss ein positiver Geldbetrag", info = format(v))
  tabelle("start_value <= 0 (Zahl oder Endwert eines SimLevResult) ist ein Fehler",
    pruef(expect_s3_class(withdrawal_simulation(matrix(1.03, 5, 1), start_value = 1), "SimLevWithdrawal"),
          quelle = "Handrechnung (Herleitung im Test)"))
})
