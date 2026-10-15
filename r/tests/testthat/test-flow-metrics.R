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
  cf <- function(s) asset_config("certificate", "signal", asset_share = 1 / k, asset_spread = 0, signal_buy = "b", signal_sell = s)
  st <- list(X = cf("sx"), Y = cf("sy"), Z = cf("sz"))
  if (vp) {
    d$E <- .fm_step(dd, c("2021-01-01", "2021-12-31"), c(100, 120))
    st$E <- asset_config("etf", "bnh", asset_share = 0.25, asset_spread = 0, asset_bonus = 0)
  }
  .fm_sim(d, do.call(create_strategy, st), start_value = 5000 * k, tax_mode = "person",
          base_rate = if (vp) 2.5 else NULL)
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
  .fm_sim(data.frame(date = dd, A = p), create_strategy(A = asset_config("etf", "bnh", asset_share = 1, asset_spread = 0)),
          start_value = 1000, dca_mode = TRUE, dca_value = 1000, dca_unit = "year", dca_span = 1, dca_skip = TRUE)
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
  # deep_analysis (eigene MWRR) stimmt ueberein
  expect_equal(r$cagr, deep_analysis(r)$metrics["mwrr", 1], tolerance = 1e-8)
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
  r <- .fm_sim(d, create_strategy(A = asset_config("etf", asset_share = 1, asset_spread = 0)),
               dca_mode = TRUE, dca_value = 2000, dca_span = 1)
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
  r <- .fm_sim(d, create_strategy(A = asset_config("etf", asset_share = 1, asset_spread = 0.1)), start_value = 10000)
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
  f <- tempfile(fileext = ".html")
  plot_interactive(r, file = f, engine = "html", open = FALSE)
  h <- paste(readLines(f, warn = FALSE), collapse = "")
  expect_true(grepl("CAGR (geldgewichtet) 40.46%", h, fixed = TRUE))
  expect_true(grepl("Max. Drawdown (zeitgewichtet) 20.0%", h, fixed = TRUE))
  grDevices::pdf(NULL); on.exit(grDevices::dev.off())
  expect_silent(plot(r))
  expect_silent(plot(r, compare = r))
})
