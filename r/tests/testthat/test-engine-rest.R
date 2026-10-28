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
