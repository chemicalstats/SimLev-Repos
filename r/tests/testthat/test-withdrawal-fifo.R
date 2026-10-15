# Tests: Entnahmephase mit den Lots der Ansparphase (FIFO) und Uebernahme von asset_bonus,
# loss_carryforward und sale_cost aus einem SimLevResult

# Ansparphase 2015-2019: A schwankt (Lots zu verschiedenen Kursen), B anders, C = 100 konstant (Geldparkplatz).
# Ereignisse alle 3 Monate wechseln die Gewichte (Kaeufe/Verkaeufe nach FIFO); am 1.12.2019 Endgewichte.
# Ab 31.12.2019 sind alle Kurse flach; Verkaufs-Ereignisse in den ersten Januartagen 2020.
.ff_data <- function(end, wA_end = 1, wB_end = 0) {
  d <- data.frame(date = seq.Date(as.Date("2015-01-01"), as.Date(end), by = "day"))
  tt <- as.numeric(d$date - d$date[1]) / 365.25
  d$A <- 100 * 1.06^tt * (1 + 0.15 * sin(2 * tt - 2)); d$B <- 50 * 1.04^tt * (1 + 0.1 * cos(3 * tt)); d$C <- 100
  flat <- d$date >= as.Date("2019-12-31")
  d$A[flat] <- d$A[d$date == as.Date("2019-12-31")]; d$B[flat] <- d$B[d$date == as.Date("2019-12-31")]
  d$ev <- d$date %in% seq.Date(as.Date("2015-03-01"), as.Date("2019-12-01"), by = "3 months") | d$date == d$date[1]
  k <- cumsum(d$ev)
  d$wA <- ifelse(k %% 2 == 1, wA_end, 0.6 * wA_end); d$wB <- ifelse(k %% 2 == 1, wB_end, 0.6 * wB_end)
  d$wA[d$date >= as.Date("2019-12-01")] <- wA_end; d$wB[d$date >= as.Date("2019-12-01")] <- wB_end
  d$wC <- 1 - d$wA - d$wB
  d
}
.ff_run <- function(d, two = FALSE, spb = 0) {
  st <- if (two) create_strategy(A = asset_config("etf", "bnh", asset_share = 0.4, asset_spread = 0, asset_bonus = 30),
                                 B = asset_config("etf", "bnh", asset_share = 0.3, asset_spread = 0, asset_bonus = 30),
                                 C = asset_config("etf", "bnh", asset_share = 0.3, asset_spread = 0, asset_bonus = 30))
        else create_strategy(A = asset_config("etf", "bnh", asset_share = 0.5, asset_spread = 0, asset_bonus = 30),
                             C = asset_config("etf", "bnh", asset_share = 0.5, asset_spread = 0, asset_bonus = 30))
  ew <- if (two) c(A = "wA", B = "wB", C = "wC") else c(A = "wA", C = "wC")
  suppressWarnings(suppressMessages(simulation(d, st, start_value = 1e5, tax_mode = "person", base_rate = 2, sparer_pauschbetrag = spb,
                                               event_col = "ev", event_mode = "replace", event_weight = ew)))
}
# Verkaufs-Ereignisse am 2.1., 3.1., ... 2020 mit den Gewichten wA (und wB)
.ff_sales <- function(wA, wB = NULL) {
  d <- .ff_data("2020-01-06", 1 - 0.4 * !is.null(wB), if (is.null(wB)) 0 else 0.4)
  for (i in seq_along(wA)) {
    day <- d$date >= as.Date("2020-01-02") + i - 1
    d$ev[d$date == as.Date("2020-01-02") + i - 1] <- TRUE
    d$wA[day] <- wA[i]; if (!is.null(wB)) d$wB[day] <- wB[i]
    d$wC[day] <- 1 - d$wA[day] - d$wB[day]
  }
  d
}
.ff_units <- function(r, a = "A") sum(r$open_lots[[a]]$lots$units)

test_that("FIFO: Steuer jeder Teilentnahme = Steuer der Engine beim Verkauf derselben Stueckzahl", {
  r0 <- .ff_run(.ff_data("2019-12-31"))
  L <- r0$open_lots$A$lots
  expect_equal(nrow(L), 3L)                                   # drei Lots zu 117,38 / 139,36 / 153,12
  expect_gt(diff(range(L$price)), 30)
  expect_equal(.ff_units(r0, "C"), 0)
  # Engine: drei Verkaeufe (Zielgewicht A 80 %, 55 %, 30 %); Steuer und Stueckzahl je Verkauf aus Laeufen mit 0..3 Ereignissen
  wA <- c(0.8, 0.55, 0.3)
  runs <- lapply(0:3, function(k) .ff_run(if (k == 0) .ff_data("2020-01-06") else .ff_sales(wA[seq_len(k)])))
  tax_e <- diff(vapply(runs, function(r) r$tax_report$total_taxes_paid, 0))
  units <- -diff(vapply(runs, .ff_units, 0))
  expect_equal(.ff_units(runs[[1]]), .ff_units(r0))
  expect_true(all(units > 0) && all(tax_e > 0))
  expect_gt(units[1], L$units[1]); expect_lt(units[1], sum(L$units[1:2]))         # Verkauf 1 ueberschreitet Lot 1
  P <- r0$worth[length(r0$worth)] / .ff_units(r0)                                  # Kurs (flach), Wert = Stueck x Kurs
  net <- units * P - tax_e                                                         # Netto je Verkauf
  # Entnahmephase: Jahr k entnimmt netto net[k] (Regel "constant", Inflation net[k+1]/net[k]); Rendite 1, keine VP
  sv <- r0$worth[length(r0$worth)]
  wk <- function(k) {
    I <- matrix(c(net[-1] / net[-3], 1)[seq_len(k)], k, 1)
    suppressMessages(withdrawal_simulation(matrix(1, k, 1), withdrawal_rule("constant", rate = 100 * net[1] / sv), start_value = r0,
                                           inflation = I, tax_mode = "person", sparer_pauschbetrag = 0, base_rate = 2))
  }
  w <- lapply(1:3, wk)
  # Spread 0 -> sale_cost 0; Pauschbetrag 0 -> im ersten Planjahr nichts verbraucht; 3 Lots A plus Cash-Position
  expect_identical(w[[1]]$adopted, list(asset_bonus = 30, loss_carryforward = 0, sale_cost = 0, lots = 4L))
  cpi <- c(1, net[2:3] / net[1])
  tax_w <- diff(c(0, vapply(w, function(x) x$paths$taxes, 0))) * cpi                # nominal je Verkauf
  expect_equal(tax_w, tax_e, tolerance = 1e-9)
  # Handrechnung Verkauf 1 (Lot 1 ganz, Rest aus Lot 2): sum s_i (P - price_i) - sum vp_i s_i / units_i, x 0,7 x 26,375 %
  s <- c(L$units[1], units[1] - L$units[1], 0)
  expect_equal(tax_w[1], (sum(s * (P - L$price)) - sum(L$vp * s / L$units)) * 0.7 * 0.26375, tolerance = 1e-9)
  # Durchschnittskosten (bisher) liegen bei Verkauf 1 deutlich darunter
  B <- sum(L$units * L$price) + sum(L$vp) + sum(vapply(r0$open_lots, `[[`, 0, "cash"))
  wa <- suppressMessages(withdrawal_simulation(matrix(1, 1, 1), withdrawal_rule("constant", rate = 100 * net[1] / sv), start_value = r0,
                                               tax_mode = "person", sparer_pauschbetrag = 0, base_rate = 2, cost_basis = 100 * B / sv))
  expect_lt(wa$paths$taxes, 0.8 * tax_e[1])
  # ganzer Bestand: weiterhin wie mit Durchschnittskosten
  full <- function(...) suppressMessages(withdrawal_simulation(matrix(1, 1, 1), withdrawal_rule("constant", rate = 100), start_value = r0,
                                                               tax_mode = "person", sparer_pauschbetrag = 0, base_rate = 2, ...))
  expect_equal(full()$paths$taxes, full(cost_basis = 100 * B / sv)$paths$taxes, tolerance = 1e-10)
})

test_that("FIFO mit Sparer-Pauschbetrag: erstes Planjahr = Jahr nach dem Datenende (next_year), Steuer = Engine", {
  r0 <- .ff_run(.ff_data("2019-12-31"), spb = 1000)
  ny <- r0$tax_report$next_year
  expect_equal(ny$year, 2020L)
  expect_gt(ny$sparer_pauschbetrag_used, 0)                     # am 31.12.2019 festgesetzte VP, verrechnet 2020
  expect_equal(ny$sparer_pauschbetrag_used + ny$sparer_pauschbetrag_remaining, 1000)
  # Engine: ein Verkauf am 2.1.2020 auf Zielgewicht A 55 %
  r1n <- .ff_run(.ff_data("2020-01-06"), spb = 1000); r1 <- .ff_run(.ff_sales(0.55), spb = 1000)
  tax_e <- r1$tax_report$total_taxes_paid - r1n$tax_report$total_taxes_paid
  s <- .ff_units(r1n) - .ff_units(r1)
  sv <- r0$worth[length(r0$worth)]; P <- sv / .ff_units(r0)   # kein Cash ausser Rundung: Wert = Stueck x Kurs
  P <- r0$report$A$worth[length(r0$worth)] / .ff_units(r0)
  wfun <- function(...) suppressMessages(withdrawal_simulation(matrix(1, 1, 1), withdrawal_rule("constant", rate = 100 * (s * P - tax_e) / sv),
                                                               start_value = r0, tax_mode = "person", base_rate = 2, ...))
  w <- wfun()
  expect_equal(w$adopted$sparer_pauschbetrag_used_year1, ny$sparer_pauschbetrag_used)
  expect_equal(w$paths$taxes, tax_e, tolerance = 1e-9)          # vorher (voller Pauschbetrag) rund 146 EUR zu wenig
  # Handrechnung: Rest-Pauschbetrag im ersten Planjahr
  L <- r0$open_lots$A$lots; k <- pmin(L$units, pmax(0, s - c(0, cumsum(L$units)[-nrow(L)])))
  g <- sum(k * (P - L$price)) - sum(L$vp * k / L$units)
  expect_equal(w$paths$taxes, (0.7 * g - ny$sparer_pauschbetrag_remaining) * 0.26375, tolerance = 1e-9)
  # anderer Pauschbetrag in der Entnahmephase: im ersten Jahr dieser minus verbrauchter Betrag
  w2 <- wfun(sparer_pauschbetrag = 2000)
  gain <- function(G) { k <- pmin(L$units, pmax(0, G / P - c(0, cumsum(L$units)[-nrow(L)])))
    sum(k * (P - L$price)) - sum(L$vp * k / L$units) }
  tx <- function(G) 0.26375 * max(0, 0.7 * gain(G) - (2000 - ny$sparer_pauschbetrag_used))
  G2 <- uniroot(function(G) G - tx(G) - (s * P - tax_e), c(0.5, 1.5) * s * P, tol = 1e-12)$root
  expect_equal(w2$paths$taxes, tx(G2), tolerance = 1e-8)
})

test_that("FIFO mit zwei Assets: Verkauf anteilig je Asset nach der Steuerformel der Engine", {
  r0 <- .ff_run(.ff_data("2019-12-31", 0.6, 0.4), two = TRUE)
  LA <- r0$open_lots$A$lots; LB <- r0$open_lots$B$lots
  expect_gt(nrow(LA), 1); expect_gt(nrow(LB), 1)
  nE <- length(r0$worth); sv <- r0$worth[nE]
  P <- c(A = r0$report$A$worth[nE] / sum(LA$units), B = r0$report$B$worth[nE] / sum(LB$units))
  # Engine-Steuerformel (man/simulation.Rd, open_lots) je Asset fuer s Stueck nach FIFO
  fifo_gain <- function(L, s, P) { k <- pmin(L$units, pmax(0, s - c(0, cumsum(L$units)[-nrow(L)])))
    sum(k * (P - L$price)) - sum(L$vp * k / L$units) }
  # (1) die Formel trifft die Engine: Verkauf auf Zielgewichte A 30 %, B 20 % (Stueckzahlen der Engine)
  r1n <- .ff_run(.ff_data("2020-01-06", 0.6, 0.4), two = TRUE)
  r1 <- .ff_run(.ff_sales(0.3, 0.2), two = TRUE)
  sA <- .ff_units(r1n, "A") - .ff_units(r1, "A"); sB <- .ff_units(r1n, "B") - .ff_units(r1, "B")
  expect_equal(r1$tax_report$total_taxes_paid - r1n$tax_report$total_taxes_paid,
               (fifo_gain(LA, sA, P[["A"]]) + fifo_gain(LB, sB, P[["B"]])) * 0.7 * 0.26375, tolerance = 1e-9)
  # (2) die Entnahmephase verkauft je Asset denselben Wertanteil f und besteuert nach dieser Formel
  wA <- r0$report$A$worth[nE] / sv; wB <- r0$report$B$worth[nE] / sv; wC <- 1 - wA - wB
  cash <- sv - r0$report$A$worth[nE] - r0$report$B$worth[nE]
  net <- 0.45 * sv
  tax_of <- function(f) (fifo_gain(LA, f * sum(LA$units), P[["A"]]) + fifo_gain(LB, f * sum(LB$units), P[["B"]])) * 0.7 * 0.26375
  f <- uniroot(function(f) f * sv - tax_of(f) - net, c(0.3, 0.9), tol = 1e-14)$root
  w <- suppressMessages(withdrawal_simulation(matrix(1, 1, 1), withdrawal_rule("constant", rate = 45), start_value = r0,
                                              tax_mode = "person", sparer_pauschbetrag = 0, base_rate = 2))
  expect_equal(w$paths$taxes, tax_of(f), tolerance = 1e-9)
  expect_gt(abs(wC), 0)                                                 # Cash-Position (Gewinn 0 bei Rendite 1)
})

test_that("FIFO: neue Vorabpauschale je Anteil f\u00fcr alle Lots gleich (Handrechnung \u00fcber zwei Jahre)", {
  r0 <- .ff_run(.ff_data("2019-12-31"))
  L <- r0$open_lots$A$lots; sv <- r0$worth[length(r0$worth)]
  P <- sv / sum(L$units)
  # Referenz in R: Einheiten = Wert bei u = 1; Basis und VP je Einheit
  n <- L$units * P; bu <- L$price / P; vu <- L$vp / L$units / P
  sell <- function(X, u) {                       # FIFO-Verkauf fuer Netto X, SPB 0, Topf 0, Gewinne positiv
    gain_of <- function(G) { left <- G / u; g <- 0
      for (j in seq_along(n)) { k <- min(n[j], left); g <- g + k * u - k * (bu[j] + vu[j]); left <- left - k }
      g }
    G <- uniroot(function(G) G - 0.26375 * 0.7 * gain_of(G) - X, c(X, 2 * X), tol = 1e-12)$root
    tax <- 0.26375 * 0.7 * gain_of(G); left <- G / u
    for (j in seq_along(n)) { k <- min(n[j], left); n[j] <<- n[j] - k; left <- left - k }
    tax
  }
  W <- 0.3 * sv
  t1 <- sell(W, 1)                               # Jahr 1, Anteilswert 1
  vp <- sum(n) * min(0.7 * 0.02, 0.1)            # Jahr 1: +10 %, VP je Anteil 0,7 x 2 % = 0,014
  t_vp <- vp * 0.7 * 0.26375; vu <- vu + 0.014   # § 19: Anrechnung je Anteil fuer alle Lots
  t2 <- sell(W + t_vp, 1.1)                      # Jahr 2: Entnahme plus faellige VP-Steuer
  w <- suppressMessages(withdrawal_simulation(matrix(c(1.1, 1), 2, 1), withdrawal_rule("constant", rate = 30), start_value = r0,
                                              tax_mode = "person", sparer_pauschbetrag = 0, base_rate = 2))
  expect_equal(w$paths$taxes, t1 + t_vp + t2, tolerance = 1e-9)
})

test_that("Uebernahme von asset_bonus, loss_carryforward und sale_cost; ausdrueckliche Angaben haben Vorrang", {
  d <- data.frame(date = seq.Date(as.Date("2018-01-01"), as.Date("2019-12-31"), by = "day"))
  tt <- as.numeric(d$date - d$date[1]) / 365.25
  d$A <- 100 * (1 - 0.3 * sin(3 * tt)); d$N <- 100 * 1.03^tt
  d$ev <- d$date %in% as.Date(c("2018-01-01", "2018-07-01", "2019-03-01")); d$wA <- c(1, 0.2, 0.6)[pmax(1, cumsum(d$ev))]; d$wN <- 1 - d$wA
  st <- create_strategy(A = asset_config("etf", "bnh", asset_share = 0.5, asset_spread = 0.2, asset_bonus = 15),
                        N = asset_config("etf", "bnh", asset_share = 0.5, asset_spread = 0.2, asset_bonus = 15))
  r <- suppressWarnings(suppressMessages(simulation(d, st, start_value = 1e5, tax_mode = "person", base_rate = 1,
                                                    event_col = "ev", event_mode = "replace", event_weight = c(A = "wA", N = "wN"))))
  lc <- r$tax_report$next_year$loss_carryforward_capital         # Topf zu Beginn des ersten Planjahres
  expect_gt(lc, 0)                                                # Verkauf von A mit Verlust am 1.7.2018
  x <- matrix(1.02, 3, 1)
  expect_message(w <- withdrawal_simulation(x, start_value = r, tax_mode = "person"),
                 "Hinweis: aus der Ansparphase \u00fcbernommen: asset_bonus = 15, loss_carryforward = [0-9.]+, sale_cost = 0.1, [0-9]+ Lots \\(FIFO\\)\\.")
  expect_equal(w$adopted$asset_bonus, 15); expect_equal(w$adopted$loss_carryforward, lc)
  expect_equal(w$adopted$sale_cost, 0.1)                          # halber Spread 0,2 % (open_lots$asset_spread)
  ref <- suppressMessages(withdrawal_simulation(x, start_value = r, tax_mode = "person", asset_bonus = 15, loss_carryforward = lc,
                                                sale_cost = 0.1))
  expect_identical(w$paths, ref$paths)
  # aelteres Ergebnis ohne next_year: Topf am Ende der Ansparphase
  ro <- r; ro$tax_report$next_year <- NULL; ro$tax_report$loss_carryforward_capital <- 1234
  expect_equal(suppressMessages(withdrawal_simulation(x, start_value = ro, tax_mode = "person"))$adopted$loss_carryforward, 1234)
  # ausdrueckliche Angaben haben Vorrang und werden nicht als uebernommen gemeldet
  expect_warning(w2 <- suppressMessages(withdrawal_simulation(x, start_value = r, tax_mode = "person", asset_bonus = 30,
                                                              loss_carryforward = 0, sale_cost = 0)),
                 "asset_bonus = 30 %, aber .*A 15 %, N 15 %")
  expect_identical(names(w2$adopted), "lots")
  expect_false(identical(w2$paths, w$paths))
  # verschiedene Spreads: keine Uebernahme, Warnung; ohne Feld asset_spread (aeltere Ergebnisse): nichts
  rs <- r; rs$open_lots$N$asset_spread <- 0.5
  expect_warning(w4 <- suppressMessages(withdrawal_simulation(x, start_value = rs, tax_mode = "person")),
                 "sale_cost nicht \u00fcbernommen: .*verschiedene Spreads \\(A 0.2 %, N 0.5 %\\)")
  expect_null(w4$adopted$sale_cost)
  rn <- r; for (a in names(rn$open_lots)) rn$open_lots[[a]]$asset_spread <- NULL
  expect_warning(w5 <- suppressMessages(withdrawal_simulation(x, start_value = rn, tax_mode = "person")), NA)
  expect_null(w5$adopted$sale_cost)
  # Ordergebuehr in der Ansparphase (open_lots$order_fee): Warnung
  rf <- suppressWarnings(suppressMessages(simulation(d, st, start_value = 1e5, tax_mode = "person", base_rate = 1, order_fee = 1,
                                                     event_col = "ev", event_mode = "replace", event_weight = c(A = "wA", N = "wN"))))
  expect_equal(rf$open_lots$A$order_fee, 1)
  expect_warning(suppressMessages(withdrawal_simulation(x, start_value = rf, tax_mode = "person")), "Ordergeb\u00fchren der Ansparphase \\(A, N\\)")
  rf$open_lots$A$order_fee <- list(fixed = 0, percent = 0, min = 0, max = Inf); rf$open_lots$N$order_fee <- NULL
  expect_warning(suppressMessages(withdrawal_simulation(x, start_value = rf, tax_mode = "person")), NA)
  # ohne Steuern keine Uebernahme, kein Hinweis
  expect_silent(w0 <- withdrawal_simulation(x, start_value = r))
  expect_null(w0$adopted)
  # withdrawal_max_rate: Hinweis nur einmal statt je Suchschritt
  msg <- testthat::capture_messages(withdrawal_max_rate(matrix(1.03, 10, 5), success = 0.9, start_value = r, tax_mode = "person"))
  expect_length(msg, 1L)
})

test_that("ohne Lots unver\u00e4ndert: numerisches start_value bitgleich, ein Lot = Durchschnittskosten", {
  set.seed(3); R <- matrix(exp(rnorm(20 * 4, 0.04, 0.15)), 20)
  w <- withdrawal_simulation(R, withdrawal_rule("guyton_klinger", rate = 5), start_value = 5e5, inflation = 2, tax_mode = "person",
                             cost_basis = 60, loss_carryforward = 3000, sale_cost = 0.1, base_rate = 2.5)
  # Referenz: Paketstand vor FIFO (Commit 2c0a43b), seit B7-01 mit der Vorabpauschale im Folgejahr (Toepfe des
  # Folgejahres, letzte VP am Pfadende); ohne Vorabpauschale unveraendert bitgleich zum Stand vor B7-01
  expect_identical(sprintf("%a", c(w$paths$taxes, w$paths$terminal_real)),
                   c("0x1.ba7cc2e9114efp+14", "0x1.bd239668e40fp+14", "0x1.66462295e709ap+15", "0x1.75b999f2411dbp+16",
                     "0x1.c08bc897c3f1cp+14", "0x1.20a91a7d2f701p+17", "0x0p+0", "0x1.0401716570f6cp+19"))
  w0 <- withdrawal_simulation(R, withdrawal_rule("guyton_klinger", rate = 5), start_value = 5e5, inflation = 2, tax_mode = "person",
                              cost_basis = 60, loss_carryforward = 3000, sale_cost = 0.1, base_rate = 2.5, vorabpauschale = FALSE)
  expect_identical(sprintf("%a", c(w0$paths$taxes, w0$paths$terminal_real)),
                   c("0x1.a45e001312221p+14", "0x1.8565fe4910e9ep+14", "0x1.5c7ebd35e6955p+15", "0x1.2d0d0540ffabep+16",
                     "0x1.d18c6bb900edcp+14", "0x1.2dba7b65f39c7p+17", "0x0p+0", "0x1.13238847114e6p+19"))
  expect_null(w$adopted)
  # Einmalanlage (ein Lot, kein Cash): FIFO = Durchschnittskosten
  d <- data.frame(date = seq.Date(as.Date("2015-01-01"), as.Date("2019-12-31"), by = "day"))
  d$A <- 100 * 1.08^(as.numeric(d$date - d$date[1]) / 365.25)
  r <- simulation(d, create_strategy(A = asset_config("etf", "bnh", asset_spread = 0, asset_bonus = 30)),
                  start_value = 1e5, tax_mode = "person", base_rate = 1)
  B <- with(r$open_lots$A, sum(lots$units * lots$price) + sum(lots$vp) + cash)
  w1 <- suppressMessages(withdrawal_simulation(R, withdrawal_rule("percent", rate = 5), start_value = r, tax_mode = "person"))
  expect_equal(w1$adopted$lots, 1L)
  w2 <- suppressMessages(withdrawal_simulation(R, withdrawal_rule("percent", rate = 5), start_value = r, tax_mode = "person",
                                               cost_basis = 100 * B / tail(r$worth, 1)))
  expect_equal(w1$paths, w2$paths, tolerance = 1e-10)
})

test_that("R6-01: Stueckrest ohne Wert (kuenstlicher Staub-Lot) wird \u00fcbersprungen statt C++-Abbruch", {
  d <- data.frame(date = seq.Date(as.Date("2016-01-01"), as.Date("2019-12-31"), by = "day"))
  tt <- as.numeric(d$date - d$date[1]) / 365.25
  d$A <- 100 * ifelse(tt < 2, 1 + 0.6 * tt, 2.2 - 0.5 * (tt - 2)) * (1 + 0.04 * sin(7 * tt))
  d$A[tt >= 3] <- d$A[which.min(abs(tt - 3))] * (1 + 0.09 * (tt[tt >= 3] - 3))
  d$C <- 100
  evd <- c(seq.Date(as.Date("2016-01-01"), as.Date("2019-11-01"), by = "4 months"), as.Date("2019-12-01"))
  d$ev <- d$date %in% evd; d$wA <- seq(0.2, 1, length.out = length(evd))[cumsum(d$ev)]; d$wC <- 1 - d$wA
  st <- create_strategy(A = asset_config("etf", "bnh", asset_share = 0.5, asset_spread = 0.4, asset_bonus = 30),
                        C = asset_config("etf", "bnh", asset_share = 0.5, asset_spread = 0.4, asset_bonus = 30))
  r <- suppressWarnings(suppressMessages(simulation(d, st, start_value = 1e5, tax_mode = "person", base_rate = 2.5,
                                                    event_col = "ev", event_mode = "replace", event_weight = c(A = "wA", C = "wC"))))
  # Staub-Lot von C (wie vor A7-06 nach Rebalancing auf Gewicht 0: 5,3e-14 Stueck, Endwert 0) kuenstlich anlegen
  r$open_lots$C$lots <- data.frame(date = as.Date("2017-12-31"), units = 5.304251e-14, price = 100.2, vp = 0)
  r$report$C$worth[length(r$report$C$worth)] <- 0
  expect_gt(sum(r$open_lots$C$lots$units), 0); expect_lt(sum(r$open_lots$C$lots$units), 1e-10)
  x <- matrix(1.05, 5, 1)
  w <- suppressMessages(withdrawal_simulation(x, withdrawal_rule("constant", rate = 4), start_value = r, tax_mode = "person"))
  expect_equal(w$adopted$lots, nrow(r$open_lots$A$lots) + (abs(tail(r$worth, 1) - tail(r$report$A$worth, 1)) > 1e-12 * tail(r$worth, 1)))
  expect_equal(w$adopted$sale_cost, 0.2)                          # nur A zaehlt als gehalten
  # gleich wie ohne den Staub-Eintrag
  r2 <- r; r2$open_lots$C <- NULL
  expect_identical(w$paths, suppressMessages(withdrawal_simulation(x, withdrawal_rule("constant", rate = 4), start_value = r2,
                                                                   tax_mode = "person"))$paths)
  expect_identical(SimLev:::.wd_held(r$open_lots, r$report, tail(r$worth, 1)), "A")
})

test_that("R6-02: ohne gehaltene Investmentfonds keine Vorabpauschale in der Entnahmephase", {
  d <- data.frame(date = seq.Date(as.Date("2019-01-01"), as.Date("2020-12-31"), by = "day"))
  d$A <- 100 * 1.10^(as.numeric(d$date - d$date[1]) / 365.25)
  st <- create_strategy(A = asset_config("etn", "bnh", asset_share = 1, asset_spread = 0))
  r <- simulation(d, st, start_value = 1e5, tax_mode = "person", base_rate = 3, sparer_pauschbetrag = 0)
  expect_equal(r$open_lots$A$regime, "capital_gains")
  x <- matrix(1.10, 3, 1)
  wf <- function(...) withdrawal_simulation(x, withdrawal_rule("constant", rate = 1), start_value = r, tax_mode = "person",
                                            base_rate = 3, sparer_pauschbetrag = 0, ...)
  expect_message(w <- wf(), "vorabpauschale = FALSE")
  expect_identical(w$adopted$vorabpauschale, FALSE); expect_equal(w$adopted$asset_bonus, 0)
  w0 <- suppressMessages(wf(vorabpauschale = FALSE))
  expect_identical(w$paths, w0$paths)
  # Handrechnung: drei Verkaeufe zu Jahresbeginn (Kurs 1, 1,1, 1,21 je Anteil), Entnahme 1 % real = 1 % nominal,
  # Basis je Anteil = Anschaffungskosten / Startwert, Steuer 26,375 % auf den vollen Gewinn (TFS 0, keine VP)
  sv <- tail(r$worth, 1); b <- sum(r$open_lots$A$lots$units * r$open_lots$A$lots$price) / sv
  X <- 0.01 * sv; tax <- 0
  for (u in c(1, 1.1, 1.21)) { G <- X / (1 - 0.26375 * (1 - b / u)); tax <- tax + 0.26375 * G * (1 - b / u) }
  expect_equal(w$paths$taxes, tax, tolerance = 1e-10)            # 253,23 EUR (vorher 1714,11 mit VP)
  expect_lt(abs(w$paths$taxes - 253.23), 0.01)
  # ausdruecklich vorabpauschale = TRUE hat Vorrang
  w1 <- suppressMessages(wf(vorabpauschale = TRUE))
  expect_null(w1$adopted$vorabpauschale); expect_gt(w1$paths$taxes, 1000)
})
