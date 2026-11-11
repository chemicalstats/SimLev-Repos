# test-entnahme.R
# Entnahmephase mit Handrechnungen: Lots der Ansparphase (FIFO), Planung und Entnahme.
# Zusammengeführt aus test-withdrawal-fifo.R, test-review7-planning.R (Inhalt wörtlich; Hilfsnamen je Teil eindeutig).
# Prüfungen je Paragraph bzw. Thema als Tabellen tabelle("<Thema>", wert(ist, soll, quelle =), ident(…), bed(…), pruef(…))
# (helper-tabelle.R); Quelle je Zeile aus dem Kommentar an der Prüfung, sonst "Handrechnung (Herleitung im Test)". Erwartete
# Werte unverändert (Liste der geprüften Werte vor und nach der Umstellung auf Tabellen in 1.4.2 je Datei verglichen).
testthat::local_edition(3)   # Edition 3 wie bisher (Config/testthat/edition in r/DESCRIPTION entfällt)

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# bis 1.4.0 test-withdrawal-fifo.R
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Tests: Entnahmephase mit den Lots der Ansparphase (FIFO) und Uebernahme von partial_exemption,
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
  st <- if (two) create_strategy(A = asset_config("etf", "bnh", share = 0.4, spread = 0, partial_exemption = 30),
                                 B = asset_config("etf", "bnh", share = 0.3, spread = 0, partial_exemption = 30),
                                 C = asset_config("etf", "bnh", share = 0.3, spread = 0, partial_exemption = 30))
        else create_strategy(A = asset_config("etf", "bnh", share = 0.5, spread = 0, partial_exemption = 30),
                             C = asset_config("etf", "bnh", share = 0.5, spread = 0, partial_exemption = 30))
  ew <- if (two) c(A = "wA", B = "wB", C = "wC") else c(A = "wA", C = "wC")
  suppressWarnings(suppressMessages(simulation(d, st, start_value = 1e5, rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = ew), tax = tax_profile(sparer_pauschbetrag = spb, base_rate = 2))))
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
  tabelle("FIFO: Steuer jeder Teilentnahme = Steuer der Engine beim Verkauf derselben Stueckzahl",
    wert(nrow(L),
         3L,
         quelle = "drei Lots zu 117,38 / 139,36 / 153,12"),
    pruef(expect_gt(diff(range(L$price)), 30),
          quelle = "Handrechnung (Herleitung im Test)"),
    wert(.ff_units(r0, "C"),
         0,
         quelle = "Handrechnung (Herleitung im Test)"))
  # Engine: drei Verkaeufe (Zielgewicht A 80 %, 55 %, 30 %); Steuer und Stueckzahl je Verkauf aus Laeufen mit 0..3 Ereignissen
  wA <- c(0.8, 0.55, 0.3)
  runs <- lapply(0:3, function(k) .ff_run(if (k == 0) .ff_data("2020-01-06") else .ff_sales(wA[seq_len(k)])))
  tax_e <- diff(vapply(runs, function(r) r$tax_report$total_taxes_paid, 0))
  units <- -diff(vapply(runs, .ff_units, 0))
  tabelle("FIFO: Steuer jeder Teilentnahme = Steuer der Engine beim Verkauf derselben Stueckzahl",
    wert(.ff_units(runs[[1]]),
         .ff_units(r0),
         quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_true(all(units > 0) && all(tax_e > 0)),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_gt(units[1], L$units[1]),
          quelle = "Verkauf 1 ueberschreitet Lot 1"),
    pruef(expect_lt(units[1], sum(L$units[1:2])),
          quelle = "Verkauf 1 ueberschreitet Lot 1"))
  P <- r0$worth[length(r0$worth)] / .ff_units(r0)                                  # Kurs (flach), Wert = Stueck x Kurs
  net <- units * P - tax_e                                                         # Netto je Verkauf
  # Entnahmephase: Jahr k entnimmt netto net[k] (Regel "constant", Inflation net[k+1]/net[k]); Rendite 1, keine VP
  sv <- r0$worth[length(r0$worth)]
  wk <- function(k) {
    I <- matrix(c(net[-1] / net[-3], 1)[seq_len(k)], k, 1)
    suppressMessages(withdrawal_simulation(matrix(1, k, 1), withdrawal_rule("constant", rate = 100 * net[1] / sv), start_value = r0,
                                           inflation = I, tax = tax_profile(sparer_pauschbetrag = 0), base_rate = 2))
  }
  w <- lapply(1:3, wk)
  tabelle("FIFO: Steuer jeder Teilentnahme = Steuer der Engine beim Verkauf derselben Stueckzahl",
    ident(w[[1]]$adopted,
          list(partial_exemption = 30, loss_carryforward = 0, sale_cost = 0, lots = 3L),
          quelle = "Spread 0 -> sale_cost 0; Pauschbetrag 0 -> im ersten Planjahr nichts verbraucht; 3 Lots A (der negative Rundungsrest im Geldbestand mindert seit 1.6.4 den aeltesten Lot, kein Cash-Lot)"))
  cpi <- c(1, net[2:3] / net[1])
  tax_w <- diff(c(0, vapply(w, function(x) x$paths$taxes, 0))) * cpi                # nominal je Verkauf
  tabelle("FIFO: Steuer jeder Teilentnahme = Steuer der Engine beim Verkauf derselben Stueckzahl",
    wert(tax_w,
         tax_e,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-9))
  # Handrechnung Verkauf 1 (Lot 1 ganz, Rest aus Lot 2): sum s_i (P - price_i) - sum vp_i s_i / units_i, x 0,7 x 26,375 %
  s <- c(L$units[1], units[1] - L$units[1], 0)
  tabelle("FIFO: Steuer jeder Teilentnahme = Steuer der Engine beim Verkauf derselben Stueckzahl",
    wert(tax_w[1],
         (sum(s * (P - L$price)) - sum(L$vp * s / L$units)) * 0.7 * 0.26375,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-9))
  # Durchschnittskosten (bisher) liegen bei Verkauf 1 deutlich darunter
  B <- sum(L$units * L$price) + sum(L$vp) + sum(vapply(r0$open_lots, `[[`, 0, "cash"))
  wa <- suppressMessages(withdrawal_simulation(matrix(1, 1, 1), withdrawal_rule("constant", rate = 100 * net[1] / sv), start_value = r0,
                                               tax = tax_profile(sparer_pauschbetrag = 0), base_rate = 2, cost_basis = 100 * B / sv))
  tabelle("FIFO: Steuer jeder Teilentnahme = Steuer der Engine beim Verkauf derselben Stueckzahl",
    pruef(expect_lt(wa$paths$taxes, 0.8 * tax_e[1]),
          quelle = "Handrechnung (Herleitung im Test)"))
  # ganzer Bestand: weiterhin wie mit Durchschnittskosten. Seit 1.6.4 (Entscheidungen 87, 104) mindert ein negativer
  # Geldbestand (hier Rundungsrest) den aeltesten Lot von A um seinen Wert, Basis und Vorabpauschale anteilig;
  # die Basis der Durchschnittskosten ist daher die der geminderten Lots
  rest <- -sum(vapply(r0$open_lots, `[[`, 0, "cash"))
  PA <- r0$report$A$worth[length(r0$worth)] / sum(L$units)                        # Kurs von A (ohne Geldbestand)
  B2 <- sum(L$units * L$price) + sum(L$vp) - rest / (L$units[1] * PA) * (L$units[1] * L$price[1] + L$vp[1])
  full <- function(...) suppressMessages(withdrawal_simulation(matrix(1, 1, 1), withdrawal_rule("constant", rate = 100), start_value = r0,
                                                               tax = tax_profile(sparer_pauschbetrag = 0), base_rate = 2, ...))
  tabelle("FIFO: Steuer jeder Teilentnahme = Steuer der Engine beim Verkauf derselben Stueckzahl",
    pruef(expect_gt(rest, 0),
          quelle = "negativer Rundungsrest der Ansparphase (Voraussetzung der Minderung)"),
    wert(full()$paths$taxes,
         full(cost_basis = 100 * B2 / sv)$paths$taxes,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10))
})

test_that("FIFO mit Sparer-Pauschbetrag: erstes Planjahr = Jahr nach dem Datenende (next_year), Steuer = Engine", {
  r0 <- .ff_run(.ff_data("2019-12-31"), spb = 1000)
  ny <- r0$tax_report$next_year
  tabelle("FIFO mit Sparer-Pauschbetrag: erstes Planjahr = Jahr nach dem Datenende (next_year), Steuer = Engine",
    wert(ny$year,
         2020L,
         quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_gt(ny$sparer_pauschbetrag_used, 0),
          quelle = "am 31.12.2019 festgesetzte VP, verrechnet 2020"),
    wert(ny$sparer_pauschbetrag_used + ny$sparer_pauschbetrag_remaining,
         1000,
         quelle = "Handrechnung (Herleitung im Test)"))
  # Engine: ein Verkauf am 2.1.2020 auf Zielgewicht A 55 %
  r1n <- .ff_run(.ff_data("2020-01-06"), spb = 1000); r1 <- .ff_run(.ff_sales(0.55), spb = 1000)
  tax_e <- r1$tax_report$total_taxes_paid - r1n$tax_report$total_taxes_paid
  s <- .ff_units(r1n) - .ff_units(r1)
  sv <- r0$worth[length(r0$worth)]; P <- sv / .ff_units(r0)   # kein Cash ausser Rundung: Wert = Stueck x Kurs
  P <- r0$report$A$worth[length(r0$worth)] / .ff_units(r0)
  wfun <- function(tax = tax_profile()) suppressMessages(withdrawal_simulation(matrix(1, 1, 1), withdrawal_rule("constant", rate = 100 * (s * P - tax_e) / sv),
                                                               start_value = r0, tax = tax, base_rate = 2))
  w <- wfun()
  tabelle("FIFO mit Sparer-Pauschbetrag: erstes Planjahr = Jahr nach dem Datenende (next_year), Steuer = Engine",
    wert(w$adopted$sparer_pauschbetrag_used_year1,
         ny$sparer_pauschbetrag_used,
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(w$paths$taxes,
         tax_e,
         quelle = "vorher (voller Pauschbetrag) rund 146 EUR zu wenig", tol = 1e-9))
  # Handrechnung: Rest-Pauschbetrag im ersten Planjahr
  L <- r0$open_lots$A$lots; k <- pmin(L$units, pmax(0, s - c(0, cumsum(L$units)[-nrow(L)])))
  g <- sum(k * (P - L$price)) - sum(L$vp * k / L$units)
  tabelle("FIFO mit Sparer-Pauschbetrag: erstes Planjahr = Jahr nach dem Datenende (next_year), Steuer = Engine",
    wert(w$paths$taxes,
         (0.7 * g - ny$sparer_pauschbetrag_remaining) * 0.26375,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-9))
  # anderer Pauschbetrag in der Entnahmephase: im ersten Jahr dieser minus verbrauchter Betrag
  w2 <- wfun(tax = tax_profile(sparer_pauschbetrag = 2000))
  gain <- function(G) { k <- pmin(L$units, pmax(0, G / P - c(0, cumsum(L$units)[-nrow(L)])))
    sum(k * (P - L$price)) - sum(L$vp * k / L$units) }
  tx <- function(G) 0.26375 * max(0, 0.7 * gain(G) - (2000 - ny$sparer_pauschbetrag_used))
  G2 <- uniroot(function(G) G - tx(G) - (s * P - tax_e), c(0.5, 1.5) * s * P, tol = 1e-12)$root
  tabelle("FIFO mit Sparer-Pauschbetrag: erstes Planjahr = Jahr nach dem Datenende (next_year), Steuer = Engine",
    wert(w2$paths$taxes,
         tx(G2),
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-8))
})

test_that("FIFO mit zwei Assets: Verkauf anteilig je Asset nach der Steuerformel der Engine", {
  r0 <- .ff_run(.ff_data("2019-12-31", 0.6, 0.4), two = TRUE)
  LA <- r0$open_lots$A$lots; LB <- r0$open_lots$B$lots
  tabelle("FIFO mit zwei Assets: Verkauf anteilig je Asset nach der Steuerformel der Engine",
    pruef(expect_gt(nrow(LA), 1),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_gt(nrow(LB), 1),
          quelle = "Handrechnung (Herleitung im Test)"))
  nE <- length(r0$worth); sv <- r0$worth[nE]
  P <- c(A = r0$report$A$worth[nE] / sum(LA$units), B = r0$report$B$worth[nE] / sum(LB$units))
  # Engine-Steuerformel (man/simulation.Rd, open_lots) je Asset fuer s Stueck nach FIFO
  fifo_gain <- function(L, s, P) { k <- pmin(L$units, pmax(0, s - c(0, cumsum(L$units)[-nrow(L)])))
    sum(k * (P - L$price)) - sum(L$vp * k / L$units) }
  # (1) die Formel trifft die Engine: Verkauf auf Zielgewichte A 30 %, B 20 % (Stueckzahlen der Engine)
  r1n <- .ff_run(.ff_data("2020-01-06", 0.6, 0.4), two = TRUE)
  r1 <- .ff_run(.ff_sales(0.3, 0.2), two = TRUE)
  sA <- .ff_units(r1n, "A") - .ff_units(r1, "A"); sB <- .ff_units(r1n, "B") - .ff_units(r1, "B")
  tabelle("FIFO mit zwei Assets: Verkauf anteilig je Asset nach der Steuerformel der Engine",
    wert(r1$tax_report$total_taxes_paid - r1n$tax_report$total_taxes_paid,
         (fifo_gain(LA, sA, P[["A"]]) + fifo_gain(LB, sB, P[["B"]])) * 0.7 * 0.26375,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-9))
  # (2) die Entnahmephase verkauft je Asset denselben Wertanteil f und besteuert nach dieser Formel
  wA <- r0$report$A$worth[nE] / sv; wB <- r0$report$B$worth[nE] / sv; wC <- 1 - wA - wB
  cash <- sv - r0$report$A$worth[nE] - r0$report$B$worth[nE]
  net <- 0.45 * sv
  # seit 1.6.4 (Entscheidungen 87, 104): der negative Geldbestand (Rundungsrest) mindert den aeltesten Lot des
  # wertgroessten Assets (A) um seinen Wert, Vorabpauschale anteilig; kein Cash-Lot
  LA2 <- LA; fa <- 1 + cash / (LA$units[1] * P[["A"]])
  LA2$units[1] <- LA$units[1] * fa; LA2$vp[1] <- LA$vp[1] * fa
  tax_of <- function(f) (fifo_gain(LA2, f * sum(LA2$units), P[["A"]]) + fifo_gain(LB, f * sum(LB$units), P[["B"]])) * 0.7 * 0.26375
  f <- uniroot(function(f) f * sv - tax_of(f) - net, c(0.3, 0.9), tol = 1e-14)$root
  w <- suppressMessages(withdrawal_simulation(matrix(1, 1, 1), withdrawal_rule("constant", rate = 45), start_value = r0,
                                              tax = tax_profile(sparer_pauschbetrag = 0), base_rate = 2))
  tabelle("FIFO mit zwei Assets: Verkauf anteilig je Asset nach der Steuerformel der Engine",
    wert(w$paths$taxes,
         tax_of(f),
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-9),
    pruef(expect_lt(wC, 0),
          quelle = "negativer Geldbestand (Rundungsrest), mindert den aeltesten Lot von A"))
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
                                              tax = tax_profile(sparer_pauschbetrag = 0), base_rate = 2))
  tabelle("FIFO: neue Vorabpauschale je Anteil für alle Lots gleich (Handrechnung über zwei Jahre)",
    wert(w$paths$taxes,
         t1 + t_vp + t2,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-9))
})

test_that("Uebernahme von partial_exemption, loss_carryforward und sale_cost; ausdrueckliche Angaben haben Vorrang", {
  d <- data.frame(date = seq.Date(as.Date("2018-01-01"), as.Date("2019-12-31"), by = "day"))
  tt <- as.numeric(d$date - d$date[1]) / 365.25
  d$A <- 100 * (1 - 0.3 * sin(3 * tt)); d$N <- 100 * 1.03^tt
  d$ev <- d$date %in% as.Date(c("2018-01-01", "2018-07-01", "2019-03-01")); d$wA <- c(1, 0.2, 0.6)[pmax(1, cumsum(d$ev))]; d$wN <- 1 - d$wA
  st <- create_strategy(A = asset_config("etf", "bnh", share = 0.5, spread = 0.2, partial_exemption = 15),
                        N = asset_config("etf", "bnh", share = 0.5, spread = 0.2, partial_exemption = 15))
  r <- suppressWarnings(suppressMessages(simulation(d, st, start_value = 1e5, rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(A = "wA", N = "wN")), tax = tax_profile(base_rate = 1))))
  lc <- r$tax_report$next_year$loss_carryforward_capital         # Topf zu Beginn des ersten Planjahres
  tabelle("Uebernahme von partial_exemption, loss_carryforward und sale_cost; ausdrueckliche Angaben haben Vorrang",
    pruef(expect_gt(lc, 0),
          quelle = "Verkauf von A mit Verlust am 1.7.2018"))
  x <- matrix(1.02, 3, 1)
  tabelle("Uebernahme von partial_exemption, loss_carryforward und sale_cost; ausdrueckliche Angaben haben Vorrang",
    pruef(expect_message(w <- withdrawal_simulation(x, start_value = r, tax = tax_profile()),
                     "Hinweis: aus der Ansparphase \u00fcbernommen: partial_exemption = 15, loss_carryforward = [0-9.]+, sale_cost = 0.1, [0-9]+ Lots \\(FIFO\\)\\."),
          quelle = "Handrechnung (Herleitung im Test)"),
    wert(w$adopted$partial_exemption,
         15,
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(w$adopted$loss_carryforward,
         lc,
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(w$adopted$sale_cost,
         0.1,
         quelle = "halber Spread 0,2 % (open_lots$spread)"))
  ref <- suppressMessages(withdrawal_simulation(x, start_value = r, tax = tax_profile(), partial_exemption = 15, loss_carryforward = lc,
                                                sale_cost = 0.1))
  tabelle("Uebernahme von partial_exemption, loss_carryforward und sale_cost; ausdrueckliche Angaben haben Vorrang",
    ident(w$paths,
          ref$paths,
          quelle = "Handrechnung (Herleitung im Test)"))
  # aelteres Ergebnis ohne next_year: Topf am Ende der Ansparphase
  ro <- r; ro$tax_report$next_year <- NULL; ro$tax_report$loss_carryforward_capital <- 1234
  tabelle("Uebernahme von partial_exemption, loss_carryforward und sale_cost; ausdrueckliche Angaben haben Vorrang",
    wert(suppressMessages(withdrawal_simulation(x, start_value = ro, tax = tax_profile()))$adopted$loss_carryforward,
         1234,
         quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_warning(w2 <- suppressMessages(withdrawal_simulation(x, start_value = r, tax = tax_profile(), partial_exemption = 30,
                                                                  loss_carryforward = 0, sale_cost = 0)),
                     "partial_exemption = 30 %, aber .*A 15 %, N 15 %"),
          quelle = "ausdrueckliche Angaben haben Vorrang und werden nicht als uebernommen gemeldet"),
    ident(names(w2$adopted),
          "lots",
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_false(identical(w2$paths, w$paths)),
          quelle = "Handrechnung (Herleitung im Test)"))
  # verschiedene Spreads: keine Uebernahme, Warnung; ohne Feld spread (aeltere Ergebnisse): nichts
  rs <- r; rs$open_lots$N$spread <- 0.5
  tabelle("Uebernahme von partial_exemption, loss_carryforward und sale_cost; ausdrueckliche Angaben haben Vorrang",
    pruef(expect_warning(w4 <- suppressMessages(withdrawal_simulation(x, start_value = rs, tax = tax_profile())),
                     "sale_cost nicht \u00fcbernommen: .*verschiedene Spreads \\(A 0.2 %, N 0.5 %\\)"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_null(w4$adopted$sale_cost),
          quelle = "Handrechnung (Herleitung im Test)"))
  rn <- r; for (a in names(rn$open_lots)) rn$open_lots[[a]]$spread <- NULL
  tabelle("Uebernahme von partial_exemption, loss_carryforward und sale_cost; ausdrueckliche Angaben haben Vorrang",
    pruef(expect_warning(w5 <- suppressMessages(withdrawal_simulation(x, start_value = rn, tax = tax_profile())), NA),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_null(w5$adopted$sale_cost),
          quelle = "Handrechnung (Herleitung im Test)"))
  # Ordergebuehr in der Ansparphase (open_lots$order_fee): Warnung
  rf <- suppressWarnings(suppressMessages(simulation(d, st, start_value = 1e5, costs = sim_costs(order_fee = 1), rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(A = "wA", N = "wN")), tax = tax_profile(base_rate = 1))))
  tabelle("Uebernahme von partial_exemption, loss_carryforward und sale_cost; ausdrueckliche Angaben haben Vorrang",
    wert(rf$open_lots$A$order_fee,
         1,
         quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_warning(suppressMessages(withdrawal_simulation(x, start_value = rf, tax = tax_profile())), "Ordergeb\u00fchren der Ansparphase \\(A, N\\)"),
          quelle = "Handrechnung (Herleitung im Test)"))
  rf$open_lots$A$order_fee <- list(fixed = 0, percent = 0, min = 0, max = Inf); rf$open_lots$N$order_fee <- NULL
  tabelle("Uebernahme von partial_exemption, loss_carryforward und sale_cost; ausdrueckliche Angaben haben Vorrang",
    pruef(expect_warning(suppressMessages(withdrawal_simulation(x, start_value = rf, tax = tax_profile())), NA),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_silent(w0 <- withdrawal_simulation(x, start_value = r)),
          quelle = "ohne Steuern keine Uebernahme, kein Hinweis"),
    pruef(expect_null(w0$adopted),
          quelle = "Handrechnung (Herleitung im Test)"))
  # withdrawal_max_rate: Hinweis nur einmal statt je Suchschritt
  msg <- testthat::capture_messages(withdrawal_max_rate(matrix(1.03, 10, 5), success = 0.9, start_value = r, tax = tax_profile()))
  tabelle("Uebernahme von partial_exemption, loss_carryforward und sale_cost; ausdrueckliche Angaben haben Vorrang",
    pruef(expect_length(msg, 1L),
          quelle = "Handrechnung (Herleitung im Test)"))
})

test_that("ohne Lots unver\u00e4ndert: numerisches start_value bitgleich, ein Lot = Durchschnittskosten", {
  set.seed(3); R <- matrix(exp(rnorm(20 * 4, 0.04, 0.15)), 20)
  w <- withdrawal_simulation(R, withdrawal_rule("guyton_klinger", rate = 5), start_value = 5e5, inflation = 2, tax = tax_profile(),
                             cost_basis = 60, loss_carryforward = 3000, sale_cost = 0.1, base_rate = 2.5)
  tabelle("ohne Lots unverändert: numerisches start_value bitgleich, ein Lot = Durchschnittskosten",
    ident(sprintf("%a", c(w$paths$taxes, w$paths$terminal_real)),
          c("0x1.ba7cc2e9114efp+14", "0x1.bd239668e40fp+14", "0x1.66462295e709ap+15", "0x1.75b999f2411dbp+16",
                         "0x1.c08bc897c3f1cp+14", "0x1.20a91a7d2f701p+17", "0x0p+0", "0x1.0401716570f6cp+19"),
          quelle = "Referenz: Entwicklungsstand von 0.5.0 vor der FIFO-Entnahme (NEWS 0.5.0, Abschnitt \"Kirchensteuer nach dem Zahlungsjahr, FIFO in der Entnahmephase\"), mit der Vorabpauschale im Folgejahr (Toepfe des Folgejahres, letzte VP am Pfadende); ohne Vorabpauschale unveraendert bitgleich zu diesem Stand"))
  w0 <- withdrawal_simulation(R, withdrawal_rule("guyton_klinger", rate = 5), start_value = 5e5, inflation = 2, tax = tax_profile(),
                              cost_basis = 60, loss_carryforward = 3000, sale_cost = 0.1, base_rate = 2.5, vorabpauschale = FALSE)
  tabelle("ohne Lots unverändert: numerisches start_value bitgleich, ein Lot = Durchschnittskosten",
    ident(sprintf("%a", c(w0$paths$taxes, w0$paths$terminal_real)),
          c("0x1.a45e001312221p+14", "0x1.8565fe4910e9ep+14", "0x1.5c7ebd35e6955p+15", "0x1.2d0d0540ffabep+16",
                         "0x1.d18c6bb900edcp+14", "0x1.2dba7b65f39c7p+17", "0x0p+0", "0x1.13238847114e6p+19"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_null(w$adopted),
          quelle = "Handrechnung (Herleitung im Test)"))
  # Einmalanlage (ein Lot, kein Cash): FIFO = Durchschnittskosten
  d <- data.frame(date = seq.Date(as.Date("2015-01-01"), as.Date("2019-12-31"), by = "day"))
  d$A <- 100 * 1.08^(as.numeric(d$date - d$date[1]) / 365.25)
  r <- simulation(d, create_strategy(A = asset_config("etf", "bnh", spread = 0, partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 1))
  B <- with(r$open_lots$A, sum(lots$units * lots$price) + sum(lots$vp) + cash)
  w1 <- suppressMessages(withdrawal_simulation(R, withdrawal_rule("percent", rate = 5), start_value = r, tax = tax_profile()))
  tabelle("ohne Lots unverändert: numerisches start_value bitgleich, ein Lot = Durchschnittskosten",
    wert(w1$adopted$lots,
         1L,
         quelle = "Handrechnung (Herleitung im Test)"))
  w2 <- suppressMessages(withdrawal_simulation(R, withdrawal_rule("percent", rate = 5), start_value = r, tax = tax_profile(),
                                               cost_basis = 100 * B / tail(r$worth, 1)))
  tabelle("ohne Lots unverändert: numerisches start_value bitgleich, ein Lot = Durchschnittskosten",
    wert(w1$paths,
         w2$paths,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10))
})

test_that("Stueckrest ohne Wert (kuenstlicher Staub-Lot) wird \u00fcbersprungen statt C++-Abbruch", {
  d <- data.frame(date = seq.Date(as.Date("2016-01-01"), as.Date("2019-12-31"), by = "day"))
  tt <- as.numeric(d$date - d$date[1]) / 365.25
  d$A <- 100 * ifelse(tt < 2, 1 + 0.6 * tt, 2.2 - 0.5 * (tt - 2)) * (1 + 0.04 * sin(7 * tt))
  d$A[tt >= 3] <- d$A[which.min(abs(tt - 3))] * (1 + 0.09 * (tt[tt >= 3] - 3))
  d$C <- 100
  evd <- c(seq.Date(as.Date("2016-01-01"), as.Date("2019-11-01"), by = "4 months"), as.Date("2019-12-01"))
  d$ev <- d$date %in% evd; d$wA <- seq(0.2, 1, length.out = length(evd))[cumsum(d$ev)]; d$wC <- 1 - d$wA
  st <- create_strategy(A = asset_config("etf", "bnh", share = 0.5, spread = 0.4, partial_exemption = 30),
                        C = asset_config("etf", "bnh", share = 0.5, spread = 0.4, partial_exemption = 30))
  r <- suppressWarnings(suppressMessages(simulation(d, st, start_value = 1e5, rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(A = "wA", C = "wC")), tax = tax_profile(base_rate = 2.5))))
  # Staub-Lot von C (nach Rebalancing auf Gewicht 0: 5,3e-14 Stueck, Endwert 0) kuenstlich anlegen
  r$open_lots$C$lots <- data.frame(date = as.Date("2017-12-31"), units = 5.304251e-14, price = 100.2, vp = 0)
  r$report$C$worth[length(r$report$C$worth)] <- 0
  tabelle("Stueckrest ohne Wert (kuenstlicher Staub-Lot) wird übersprungen statt C++-Abbruch",
    pruef(expect_gt(sum(r$open_lots$C$lots$units), 0),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_lt(sum(r$open_lots$C$lots$units), 1e-10),
          quelle = "Handrechnung (Herleitung im Test)"))
  x <- matrix(1.05, 5, 1)
  w <- suppressMessages(withdrawal_simulation(x, withdrawal_rule("constant", rate = 4), start_value = r, tax = tax_profile()))
  tabelle("Stueckrest ohne Wert (kuenstlicher Staub-Lot) wird übersprungen statt C++-Abbruch",
    wert(w$adopted$lots,
         nrow(r$open_lots$A$lots) + (tail(r$worth, 1) - tail(r$report$A$worth, 1) > 1e-12 * tail(r$worth, 1)),   # Cash-Lot nur bei positivem Geldbestand (seit 1.6.4, Entscheidung 87)
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(w$adopted$sale_cost,
         0.2,
         quelle = "nur A zaehlt als gehalten"))
  # gleich wie ohne den Staub-Eintrag
  r2 <- r; r2$open_lots$C <- NULL
  tabelle("Stueckrest ohne Wert (kuenstlicher Staub-Lot) wird übersprungen statt C++-Abbruch",
    ident(w$paths,
          suppressMessages(withdrawal_simulation(x, withdrawal_rule("constant", rate = 4), start_value = r2,
                                                                       tax = tax_profile()))$paths,
          quelle = "Handrechnung (Herleitung im Test)"),
    ident(SimLev:::.wd_held(r$open_lots, r$report, tail(r$worth, 1)),
          "A",
          quelle = "Handrechnung (Herleitung im Test)"))
})

test_that("ohne gehaltene Investmentfonds keine Vorabpauschale in der Entnahmephase", {
  d <- data.frame(date = seq.Date(as.Date("2019-01-01"), as.Date("2020-12-31"), by = "day"))
  d$A <- 100 * 1.10^(as.numeric(d$date - d$date[1]) / 365.25)
  st <- create_strategy(A = asset_config("etn", "bnh", share = 1, spread = 0))
  r <- simulation(d, st, start_value = 1e5, tax = tax_profile(sparer_pauschbetrag = 0, base_rate = 3))
  tabelle("ohne gehaltene Investmentfonds keine Vorabpauschale in der Entnahmephase",
    wert(r$open_lots$A$regime,
         "capital_gains",
         quelle = "Handrechnung (Herleitung im Test)"))
  x <- matrix(1.10, 3, 1)
  wf <- function(...) withdrawal_simulation(x, withdrawal_rule("constant", rate = 1), start_value = r, tax = tax_profile(sparer_pauschbetrag = 0),
                                            base_rate = 3, ...)
  tabelle("ohne gehaltene Investmentfonds keine Vorabpauschale in der Entnahmephase",
    pruef(expect_message(w <- wf(), "vorabpauschale = FALSE"),
          quelle = "Handrechnung (Herleitung im Test)"),
    ident(w$adopted$vorabpauschale,
          FALSE,
          quelle = "Handrechnung (Herleitung im Test)"),
    wert(w$adopted$partial_exemption,
         0,
         quelle = "Handrechnung (Herleitung im Test)"))
  w0 <- suppressMessages(wf(vorabpauschale = FALSE))
  tabelle("ohne gehaltene Investmentfonds keine Vorabpauschale in der Entnahmephase",
    ident(w$paths,
          w0$paths,
          quelle = "Handrechnung (Herleitung im Test)"))
  # Handrechnung: drei Verkaeufe zu Jahresbeginn (Kurs 1, 1,1, 1,21 je Anteil), Entnahme 1 % real = 1 % nominal,
  # Basis je Anteil = Anschaffungskosten / Startwert, Steuer 26,375 % auf den vollen Gewinn (TFS 0, keine VP)
  sv <- tail(r$worth, 1); b <- sum(r$open_lots$A$lots$units * r$open_lots$A$lots$price) / sv
  X <- 0.01 * sv; tax <- 0
  for (u in c(1, 1.1, 1.21)) { G <- X / (1 - 0.26375 * (1 - b / u)); tax <- tax + 0.26375 * G * (1 - b / u) }
  tabelle("ohne gehaltene Investmentfonds keine Vorabpauschale in der Entnahmephase",
    wert(w$paths$taxes,
         tax,
         quelle = "253,23 EUR (vorher 1714,11 mit VP)", tol = 1e-10),
    pruef(expect_lt(abs(w$paths$taxes - 253.23), 0.01),
          quelle = "Handrechnung (Herleitung im Test)"))
  # ausdruecklich vorabpauschale = TRUE hat Vorrang
  w1 <- suppressMessages(wf(vorabpauschale = TRUE))
  tabelle("ohne gehaltene Investmentfonds keine Vorabpauschale in der Entnahmephase",
    pruef(expect_null(w1$adopted$vorabpauschale),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_gt(w1$paths$taxes, 1000),
          quelle = "Handrechnung (Herleitung im Test)"))
})

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# bis 1.4.0 test-review7-planning.R
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Planung und Entnahme

# Referenz zur Entnahmephase (Durchschnittskosten, Entnahme zu Jahresbeginn, Steuer 26,375 %, TFS 30 %):
# Vorabpauschale des Jahres y gilt am ersten Werktag von y + 1 als zugeflossen und wird mit Verlusttopf und
# Pauschbetrag von y + 1 versteuert; die VP des letzten Jahres wird am Pfadende so abgerechnet (Verkauf aus dem Depot)
.r7_ref <- function(R, rate = 0.04, sv = 1e5, basis = sv, tfs = 0.3, tr = 0.26375, spb = 1000, spb1 = spb, br = 0.032) {
  n <- sv; u <- 1; W <- rate * sv; vp_prev <- 0; taxes <- 0; loss <- 0; pot <- 0
  tx <- function(g) { t <- g * (1 - tfs); if (t <= 0) { loss <<- loss - t; return(0) }
    a <- min(loss, t); loss <<- loss - a; t <- t - a; a <- min(pot, t); pot <<- pot - a; (t - a) * tr }
  sell <- function(target) {                  # Brutto G mit G - Steuer = target (Durchschnittskosten)
    V <- n * u; peek <- function(G) max(0, (G - basis * G / V) * (1 - tfs) - loss - pot) * tr
    G <- uniroot(function(G) G - peek(G) - target, c(0, V), tol = 1e-13)$root
    t <- tx(G - basis * G / V); basis <<- basis - basis * G / V; n <<- n - G / u; t
  }
  for (y in seq_along(R)) {
    pot <- if (y == 1) spb1 else spb
    vtax <- if (vp_prev > 0) tx(vp_prev) else 0
    taxes <- taxes + vtax + sell(W + vtax)
    u0 <- u; u <- u * R[y]
    vp_prev <- n * min(u0 * 0.7 * br, u - u0); basis <- basis + vp_prev
  }
  # Pfadende (wie simulation()): VP-Steuer mit den Toepfen des Folgejahres, Zwangsverkauf im ablaufenden Jahr
  pot_last <- pot; loss_last <- loss
  pot <- spb; vtax <- tx(vp_prev)
  pot <- pot_last; loss <- loss_last
  taxes <- taxes + vtax + sell(vtax)
  c(taxes = taxes, end = n * u)
}

test_that("Vorabpauschale mit den Toepfen des Folgejahres, letzte VP am Pfadende", {
  R <- matrix(1.10, 3, 1)
  ws <- withdrawal_simulation(R, withdrawal_rule("constant", rate = 4), start_value = 1e5, tax = tax_profile(),
                              base_rate = 3.2, cost_basis = 100)
  ref <- .r7_ref(R[, 1])
  tabelle("Vorabpauschale mit den Toepfen des Folgejahres, letzte VP am Pfadende",
    wert(ws$paths$taxes,
         ref[["taxes"]],
         quelle = "636,04 (vorher 342,98)", tol = 1e-10),
    wert(ws$paths$terminal_nominal,
         ref[["end"]],
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10),
    wert(ws$wealth[4, 1],
         ref[["end"]],
         quelle = "Endvermoegen nach der VP-Abrechnung", tol = 1e-10))
  # Anteil ohne die VP des letzten Jahres = Referenzwert des Befunds (449,43 statt 342,98)
  ws2 <- withdrawal_simulation(matrix(c(1.1, 1.1, 1.1, 1), 4, 1), withdrawal_rule("constant", rate = 4), start_value = 1e5,
                               tax = tax_profile(), base_rate = 3.2, cost_basis = 100, years = 3)
  tabelle("Vorabpauschale mit den Toepfen des Folgejahres, letzte VP am Pfadende",
    pruef(expect_gt(ws2$paths$taxes, 449.4),
          quelle = "Handrechnung (Herleitung im Test)"),
    wert(withdrawal_simulation(R, withdrawal_rule("constant", rate = 4), start_value = 1e5, tax = tax_profile(sparer_pauschbetrag = 0), base_rate = 3.2,
                                         cost_basis = 100)$paths$taxes,
         .r7_ref(R[, 1], spb = 0)[["taxes"]],
         quelle = "mit Verlusttopf und Pauschbetrag 0 im Folgejahr; ohne VP unveraendert", tol = 1e-10))
  # Zusammenspiel mit next_year: erstes Planjahr mit Rest-Pauschbetrag, die eigene VP des ersten Jahres mit vollem Pauschbetrag
  d <- data.frame(date = seq.Date(as.Date("2015-01-01"), as.Date("2019-12-31"), by = "day"))
  d$A <- 100 * 1.08^(as.numeric(d$date - d$date[1]) / 365.25)
  r <- simulation(d, create_strategy(A = asset_config("etf", "bnh", spread = 0, partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 3.2))
  ny <- r$tax_report$next_year; sv <- tail(r$worth, 1)
  tabelle("Vorabpauschale mit den Toepfen des Folgejahres, letzte VP am Pfadende",
    pruef(expect_gt(ny$sparer_pauschbetrag_used, 0),
          quelle = "Handrechnung (Herleitung im Test)"))
  B <- with(r$open_lots$A, sum(lots$units * lots$price) + sum(lots$vp) + cash)
  w <- suppressMessages(withdrawal_simulation(R, withdrawal_rule("constant", rate = 4), start_value = r, tax = tax_profile(), base_rate = 3.2))
  tabelle("Vorabpauschale mit den Toepfen des Folgejahres, letzte VP am Pfadende",
    wert(w$paths$taxes,
         .r7_ref(R[, 1], sv = sv, basis = B, spb1 = ny$sparer_pauschbetrag_remaining)[["taxes"]],
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-9))
})

test_that("planning_lumpsum_vs_dca schreibt das DCA-Depot \u00fcber Stueckzahlen fort (exakt ohne Steuern)", {
  d <- data.frame(date = seq.Date(as.Date("2010-01-01"), as.Date("2016-12-31"), by = "day"))
  t <- seq_len(nrow(d))
  d$A <- 100 * ifelse(t <= 365, exp(t / 365 * log(2)), 2)                      # A steigt im ersten Jahr, dann flach
  d$B <- 100 * ifelse(t <= 365, 1, exp((t - 365) / 365 * log(1.5)))           # B umgekehrt
  st <- create_strategy(A = asset_config("etf", "bnh", share = 0.5, spread = 0),
                        B = asset_config("etf", "bnh", share = 0.5, spread = 0))
  x <- suppressWarnings(planning_lumpsum_vs_dca(d, st, amount = 12000, months = 12, horizon = 5, step = 100))
  tabelle("planning_lumpsum_vs_dca schreibt das DCA-Depot über Stueckzahlen fort (exakt ohne Steuern)",
    pruef(expect_true(all(x$exact)),
          quelle = "Handrechnung (Herleitung im Test)"))
  # Handrechnung: 12 Raten zu 1000 am Monatsersten, je 500 in A und B, danach halten
  ref <- function(s, h, wA = 0.5) { e <- seq.Date(s, by = paste(h, "years"), length.out = 2)[2] - 1
    ia <- match(seq.Date(s, by = "month", length.out = 12), d$date); ie <- match(e, d$date)
    c(dca = sum(1000 * wA / d$A[ia]) * d$A[ie] + sum(1000 * (1 - wA) / d$B[ia]) * d$B[ie],
      ls = 12000 * wA / d$A[ia[1]] * d$A[ie] + 12000 * (1 - wA) / d$B[ia[1]] * d$B[ie]) }
  r1 <- ref(x$start[1], 5)
  tabelle("planning_lumpsum_vs_dca schreibt das DCA-Depot über Stueckzahlen fort (exakt ohne Steuern)",
    wert(x$dca[1],
         r1[["dca"]],
         quelle = "vorher 39294 statt 39314 (Index der Einmalanlage)", tol = 1e-10),
    wert(x$lump_sum[1],
         r1[["ls"]],
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10))
  # Zufallsdaten 60/40: jede Startzeile exakt
  set.seed(5)
  d <- data.frame(date = seq.Date(as.Date("2000-01-01"), as.Date("2009-12-31"), by = "day")); n <- nrow(d)
  d$A <- 100 * exp(cumsum(rnorm(n, 3e-4, 0.012))); d$B <- 100 * exp(cumsum(rnorm(n, 1e-4, 0.004)))
  st <- create_strategy(A = asset_config("etf", "bnh", share = 0.6, spread = 0),
                        B = asset_config("etf", "bnh", share = 0.4, spread = 0))
  x <- suppressWarnings(planning_lumpsum_vs_dca(d, st, amount = 12000, months = 12, horizon = 5, step = 12))
  tabelle("planning_lumpsum_vs_dca schreibt das DCA-Depot über Stueckzahlen fort (exakt ohne Steuern)",
    wert(x$dca,
         vapply(x$start, function(s) ref(s, 5, 0.6)[["dca"]], 0),
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10))
  # Strategie mit Rebalancing: Naeherung ueber den Index der Einmalanlage, gekennzeichnet
  xr <- suppressWarnings(planning_lumpsum_vs_dca(d, st, amount = 12000, months = 12, horizon = 5, step = 24,
                                        sim_args = list(rebalance = rebalance_plan(span = 12))))
  tabelle("planning_lumpsum_vs_dca schreibt das DCA-Depot über Stueckzahlen fort (exakt ohne Steuern)",
    pruef(expect_false(any(xr$exact)),
          quelle = "Handrechnung (Herleitung im Test)"),
    ident(names(x),
          c("start", "lump_sum", "dca", "advantage", "exact"),
          quelle = "Handrechnung (Herleitung im Test)"))
})

test_that("planning_goal meldet die erreichte Erfolgsquote der Politik, DP-Wert getrennt", {
  exact <- function(W, t, H, R, goal, cf) {
    if (t > H) return(as.numeric(W >= goal))
    b <- W + cf[t]; if (b <= 0) return(0)
    max(sapply(seq_len(ncol(R)), function(k) mean(sapply(R[, k], function(r) exact(b * r, t + 1, H, R, goal, cf)))))
  }
  set.seed(3)
  for (case in 1:3) {
    S <- 5; R <- cbind(safe = exp(rnorm(S, 0.02, 0.01)), mid = exp(rnorm(S, 0.04, 0.1)), risky = exp(rnorm(S, 0.06, 0.25)))
    goal <- runif(1, 105, 140)
    if (case == 3) {
      g <- suppressWarnings(planning_goal(R, 100, goal, 4, n_grid = 301, n_sim = 20000, seed = 1))
      ex <- exact(100, 1, 4, R, goal, rep(0, 4))
      expect_equal(g$probability, mean(g$simulation$success))
      expect_equal(g$probability_se, sqrt(g$probability * (1 - g$probability) / 20000))
      expect_gt(g$probability_dp, ex)                                          # DP 0,9015 > Optimum 0,8768 (Verzerrung)
      expect_lte(g$probability, ex + 2 * g$probability_se)                      # erreichte Quote 0,8571
    }
  }
  out <- capture.output(print(g))
  tabelle("planning_goal meldet die erreichte Erfolgsquote der Politik, DP-Wert getrennt",
    pruef(expect_true(any(grepl("Vorw\u00e4rtssimulation, SE .* DP-Wert 90.1 %", out))),
          quelle = "Handrechnung (Herleitung im Test)"))
})

test_that("+ k Monate auf das Monatsende begrenzt (series_align_macro, overfit_walk_forward, .anniv_ends)", {
  am <- SimLev:::.add_months
  tabelle("+ k Monate auf das Monatsende begrenzt (series_align_macro, overfit_walk_forward, .anniv_ends)",
    wert(am(as.Date("2024-01-31"), 1),
         as.Date("2024-02-29"),
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(am(as.Date("2023-01-31"), 1),
         as.Date("2023-02-28"),
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(am(as.Date("2024-02-29"), 12),
         as.Date("2025-02-28"),
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(am(as.Date("2024-03-31"), -1),
         as.Date("2024-02-29"),
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(am(as.Date(c("2024-01-15", "2024-12-31")), c(1, 2)),
         as.Date(c("2024-02-15", "2025-02-28")),
         quelle = "Handrechnung (Herleitung im Test)"))
  # series_align_macro: Monatswert ab Referenzdatum + 1 Monat (vorher 31.01. -> 02.03.)
  m <- data.frame(date = as.Date(c("2023-12-31", "2024-01-31", "2024-02-29", "2024-03-31", "2024-04-30")), cpi = 1:5)
  d <- data.frame(date = seq.Date(as.Date("2024-01-25"), as.Date("2024-06-05"), by = "day"))
  a <- series_align_macro(d, m, "cpi", lag = 1, lag_unit = "month")
  tabelle("+ k Monate auf das Monatsende begrenzt (series_align_macro, overfit_walk_forward, .anniv_ends)",
    wert(as.Date(vapply(1:5, function(k) min(a$date[a$cpi %in% k]), 0)),
         as.Date(c("2024-01-31", "2024-02-29", "2024-03-29", "2024-04-30", "2024-05-30")),
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(a$cpi[a$date == as.Date("2024-03-01")],
         2,
         quelle = "Handrechnung (Herleitung im Test)"))
  # Periodenenden ab dem 31.01.: 29.02., 31.03., 30.04. (vorher 02.03., 31.03., 01.05.)
  dts <- seq.Date(as.Date("2000-01-31"), by = "day", length.out = 401)
  tabelle("+ k Monate auf das Monatsende begrenzt (series_align_macro, overfit_walk_forward, .anniv_ends)",
    wert(dts[SimLev:::.anniv_ends(dts, "month")][1:5],
         as.Date(c("2000-01-31", "2000-02-29", "2000-03-31", "2000-04-30", "2000-05-31")),
         quelle = "Handrechnung (Herleitung im Test)"),
    wert(dts[SimLev:::.anniv_ends(dts, "quarter")][1:3],
         as.Date(c("2000-01-31", "2000-04-30", "2000-07-31")),
         quelle = "Handrechnung (Herleitung im Test)"))
  b <- structure(list(paths = list(matrix(100 * cumprod(c(1, rep(1.001, 400))), ncol = 1, dimnames = list(NULL, "x"))),
                      weights = 1, config = list(), method = "stationary"), class = "bootstrap_result")
  wp <- withdrawal_paths(b, column = "x", frequency = "month", start = "2000-01-31")
  tabelle("+ k Monate auf das Monatsende begrenzt (series_align_macro, overfit_walk_forward, .anniv_ends)",
    wert(round(log(wp$returns[1:4, 1]) / log(1.001)),
         c(29, 31, 30, 31),
         quelle = "Tage je Periode"))
  # unveraendert fuer Starttage <= 28
  d2 <- seq.Date(as.Date("2000-01-15"), by = "day", length.out = 800)
  tabelle("+ k Monate auf das Monatsende begrenzt (series_align_macro, overfit_walk_forward, .anniv_ends)",
    wert(SimLev:::.anniv_ends(d2, "month"),
         unique(findInterval(as.numeric(seq.Date(d2[1], d2[800], by = "1 month")), as.numeric(d2))),
         quelle = "Handrechnung (Herleitung im Test)"))
  # overfit_walk_forward: Fenstergrenzen vom 30.01. an
  set.seed(1); n <- 2 * 365
  dd <- data.frame(date = seq.Date(as.Date("2010-01-30"), by = "day", length.out = n)); dd$A <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
  st <- create_strategy(A = asset_config("etf", "signal", signal_buy = "buy", signal_sell = "sell"))
  ps <- param_search(dd, function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n)), param_space(n = c(10, 20)))
  wf <- overfit_walk_forward(ps, train = 1 / 12, test = 1 / 12)
  tabelle("+ k Monate auf das Monatsende begrenzt (series_align_macro, overfit_walk_forward, .anniv_ends)",
    wert(wf$windows$test_start[1],
         as.Date("2010-02-28"),
         quelle = "31.01. + 1 Monat (vorher 03.03.)"))
})

test_that("withdrawal_max_rate prueft success, lower/upper, tol und rechnet jede Rate einmal", {
  set.seed(1); R <- matrix(exp(rnorm(30 * 100, 0.05, 0.15)), 30)
  tabelle("withdrawal_max_rate prueft success, lower/upper, tol und rechnet jede Rate einmal",
    pruef(expect_error(withdrawal_max_rate(R, success = 95, inflation = 2), "success muss ein Anteil .*Prozentangaben durch 100 teilen"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(withdrawal_max_rate(R, success = 0, inflation = 2), "0 < success <= 1"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(withdrawal_max_rate(R, lower = 10, upper = 2, inflation = 2), "0 <= lower < upper <= 100"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(withdrawal_max_rate(R, upper = 150, inflation = 2), "0 <= lower < upper <= 100 sein\\."),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(withdrawal_max_rate(R, success = 0.9, inflation = 2, tol = 0), "tol muss eine Zahl > 0"),
          quelle = "Handrechnung (Herleitung im Test)"))
  calls <- 0L; orig <- SimLev::withdrawal_simulation
  local_mocked_bindings(withdrawal_simulation = function(...) { calls <<- calls + 1L; orig(...) }, .package = "SimLev")
  r <- withdrawal_max_rate(R, success = 0.9, inflation = 2, tol = 0.1)
  n_bis <- ceiling(log2((20 - 0.5) / 0.1))
  tabelle("withdrawal_max_rate prueft success, lower/upper, tol und rechnet jede Rate einmal",
    wert(calls,
         2L + n_bis,
         quelle = "lower, upper, je Halbierung einmal (vorher +3)"),
    pruef(expect_gte(attr(r, "success"), 0.9),
          quelle = "Handrechnung (Herleitung im Test)"))
})

test_that("withdrawal_rule prueft alle Parameter (Skalar, NA, Bereich) und warnt bei Anteilen", {
  tabelle("withdrawal_rule prueft alle Parameter (Skalar, NA, Bereich) und warnt bei Anteilen",
    pruef(expect_error(withdrawal_rule("constant", rate = c(4, 5)), "withdrawal_rule: rate muss zwischen 0 und 100 Prozent liegen"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(withdrawal_rule("constant", rate = NA), "rate muss zwischen"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(withdrawal_rule("endowment", smoothing = NA), "smoothing muss NULL oder eine Zahl von 0 bis 100"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(withdrawal_rule("vpw", age = 70, max_age = 65), "age muss kleiner als max_age sein"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_silent(withdrawal_rule("constant", age = 70, max_age = 65)),
          quelle = "ungenutzt bei anderen Regeln"),
    pruef(expect_error(withdrawal_rule("constant", min_real = 5e4, max_real = 1e4), "min_real darf nicht gr\u00f6\u00dfer als max_real"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(withdrawal_rule("clyatt", floor95 = 150), "floor95 muss eine Zahl von 0 bis 100"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(withdrawal_rule("guyton_klinger", cut = 150), "cut muss"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(withdrawal_rule("guyton_klinger", inflation_cap = -5), "inflation_cap muss eine Zahl >= 0 in Prozent oder Inf"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(withdrawal_rule("guyton_klinger", skip_inflation = "ja"), "skip_inflation muss TRUE oder FALSE"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(withdrawal_rule("ratchet", ratchet_gap = -1), "ratchet_gap muss"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(withdrawal_rule("vpw", max_rate = 0), "max_rate = 0 erlaubt keine Entnahme"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(withdrawal_rule("vanguard", floor = 120), "floor muss NULL oder eine Zahl von 0 bis 100"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_error(withdrawal_rule("abw", fv = -1), "fv muss"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_warning(withdrawal_rule("vanguard", ceiling = 0.05, floor = 0.025),
                     "ceiling = 0.050, floor = 0.025 wirkt wie ein Anteil.*ceiling = 5.0, floor = 2.5"),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_silent(withdrawal_rule("guyton_klinger", inflation_cap = Inf)),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_silent(withdrawal_rule("vanguard", rate = 5, ceiling = 5, floor = 2.5)),
          quelle = "Handrechnung (Herleitung im Test)"),
    ident(withdrawal_rule("guyton_klinger", rate = 5.2)$ceiling,
          20,
          quelle = "Handrechnung (Herleitung im Test)"))
})

test_that("overfit_walk_forward-Fenster von t0 aus, lueckenlos ohne Ueberlappung (Start 31.08.)", {
  set.seed(1); n <- 1500
  d <- data.frame(date = seq.Date(as.Date("2010-08-30"), by = "day", length.out = n))
  d$A <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.011))
  st <- create_strategy(A = asset_config("etf", "signal", signal_buy = "buy", signal_sell = "sell"))
  ps <- suppressMessages(suppressWarnings(param_search(d, function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, 0)),
                                                       param_space(n = c(20, 50)), burn_in = 0)))
  dd <- SimLev:::.of_returns(ps, "day")$dates
  tabelle("overfit_walk_forward-Fenster von t0 aus, lueckenlos ohne Ueberlappung (Start 31.08.)",
    wert(dd[1],
         as.Date("2010-08-31"),
         quelle = "Handrechnung (Herleitung im Test)"))
  wf <- overfit_walk_forward(ps, train = 0.5, test = 0.5)
  W <- wf$windows
  tabelle("overfit_walk_forward-Fenster von t0 aus, lueckenlos ohne Ueberlappung (Start 31.08.)",
    wert(W$test_start[1:4],
         as.Date(c("2011-02-28", "2011-08-31", "2012-02-29", "2012-08-31")),
         quelle = "Teststart k = t0 + 6 (k + 1) Monate, Testende = Tag vor t0 + 6 (k + 2) Monate (auf Monatsende begrenzt)"),
    wert(W$test_end[1:3],
         as.Date(c("2011-08-30", "2012-02-28", "2012-08-30")),
         quelle = "vorher 27.08. (3 Tage Luecke)"))
  nW <- nrow(W)
  tabelle("overfit_walk_forward-Fenster von t0 aus, lueckenlos ohne Ueberlappung (Start 31.08.)",
    pruef(expect_true(all(W$test_end[-nW] + 1 == W$test_start[-1])),
          quelle = "lueckenlos, keine Ueberlappung"))
  s <- wf$series$date
  tabelle("overfit_walk_forward-Fenster von t0 aus, lueckenlos ohne Ueberlappung (Start 31.08.)",
    pruef(expect_length(setdiff(dd[dd >= min(s) & dd <= max(s)], s), 0L),
          quelle = "Handrechnung (Herleitung im Test)"),
    pruef(expect_false(anyDuplicated(s) > 0),
          quelle = "Handrechnung (Herleitung im Test)"))
})

test_that("Horizont H auf laengeren Pfaden = Pfade mit H Jahren (Endvermoegen und Steuern mit VP-Abrechnung)", {
  set.seed(2); R <- matrix(exp(rnorm(20 * 3, 0.06, 0.12)), 20)
  f <- function(RR, ...) suppressWarnings(withdrawal_simulation(RR, withdrawal_rule("constant", rate = 4), start_value = 1e5,
                                                                tax = tax_profile(), base_rate = 2.5, cost_basis = 60, ...))
  a <- f(R[1:10, ]); b <- f(R, horizon = 10)
  tabelle("Horizont H auf laengeren Pfaden = Pfade mit H Jahren (Endvermoegen und Steuern mit VP-Abrechnung)",
    wert(b$paths$terminal_real,
         a$paths$terminal_real,
         quelle = "vorher 156328 statt 156078", tol = 1e-12),
    wert(b$paths$taxes,
         a$paths$taxes,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-12),
    wert(b$paths$success,
         a$paths$success,
         quelle = "Handrechnung (Herleitung im Test)"))
  # zufaellige Horizonte, monatliche Perioden und FIFO-Lots ebenso
  h <- withdrawal_horizon("discrete", years = c(5, 12), prob = c(1, 1))
  Hm <- SimLev:::.draw_horizon(h, 3)
  Rm <- matrix(exp(rnorm(240 * 3, 0.005, 0.03)), 240)
  bm <- suppressWarnings(withdrawal_simulation(Rm, withdrawal_rule("percent", rate = 5), frequency = "month", tax = tax_profile(),
                                               base_rate = 2.5, cost_basis = 60, horizon = h))
  for (i in 1:3) {
    am <- suppressWarnings(withdrawal_simulation(Rm[seq_len(12 * Hm[i]), i, drop = FALSE], withdrawal_rule("percent", rate = 5),
                                                 frequency = "month", tax = tax_profile(), base_rate = 2.5, cost_basis = 60))
    expect_equal(bm$paths$terminal_real[i], am$paths$terminal_real, tolerance = 1e-12)
    expect_equal(bm$paths$taxes[i], am$paths$taxes, tolerance = 1e-12)
  }
  tabelle("Horizont H auf laengeren Pfaden = Pfade mit H Jahren (Endvermoegen und Steuern mit VP-Abrechnung)",
    wert(f(R)$paths$terminal_real,
         f(R, horizon = 20)$paths$terminal_real,
         quelle = "ohne horizon unveraendert: volle Pfadlaenge", tol = 1e-12))
})

test_that("Pfadende-VP wie simulation() (Steuer mit Folgejahr-Toepfen, Zwangsverkauf im ablaufenden Jahr)", {
  Ry <- c(1.10, 0.8, 1.30); u <- cumprod(c(1, Ry)); cal <- seq(as.Date("2021-01-01"), as.Date("2023-12-31"), by = "day")
  yr <- as.integer(format(cal, "%Y")) - 2020; px <- 100 * u[yr]; l <- format(cal, "%m-%d") == "12-31"; px[l] <- 100 * u[yr[l] + 1]
  st <- create_strategy(A = asset_config("etf", "bnh", share = 1, spread = 0, partial_exemption = 30))
  r <- suppressMessages(simulation(data.frame(date = cal, A = px), st, start_value = 1e5, tax = tax_profile(base_rate = 3.2)))
  w <- withdrawal_simulation(matrix(Ry, ncol = 1), withdrawal_rule("constant", rate = 0), start_value = 1e5,
                             tax = tax_profile(), base_rate = 3.2, cost_basis = 100, partial_exemption = 30)
  tabelle("Pfadende-VP wie simulation() (Steuer mit Folgejahr-Toepfen, Zwangsverkauf im ablaufenden Jahr)",
    wert(w$paths$taxes,
         r$tax_report$total_taxes_paid,
         quelle = "251,47 (vorher 253,13)", tol = 1e-9),
    wert(w$paths$terminal_nominal,
         tail(r$worth, 1),
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-9))
})

test_that("planmaessige vollst\u00e4ndige Entnahme (one_over_n, abw, hebeler, vpw) mit Steuern kein Fehlschlag", {
  set.seed(1); R <- matrix(exp(rnorm(30 * 200, 0.05, 0.15)), 30)
  for (ty in c("one_over_n", "abw", "vpw")) {
    w <- withdrawal_simulation(R, withdrawal_rule(ty), tax = tax_profile(), cost_basis = 60)
    expect_true(all(w$paths$success), info = ty)                                # vorher one_over_n 5,5 %, abw 6 % Erfolg
    if (ty != "vpw") expect_true(all(w$paths$terminal_real == 0), info = ty)   # Depot planmaessig geleert (vpw: bis max_age 100)
  }
  # one_over_n ohne Steuern und mit Steuern: beide leeren das Depot; Konsum im letzten Jahr mit Steuern kleiner
  a <- withdrawal_simulation(R[, 1:5], withdrawal_rule("one_over_n"), tax = tax_profile(), cost_basis = 60)
  tabelle("planmaessige vollständige Entnahme (one_over_n, abw, hebeler, vpw) mit Steuern kein Fehlschlag",
    pruef(expect_true(all(a$paths$success) && all(is.na(a$paths$depletion_year))),
          quelle = "Handrechnung (Herleitung im Test)"))
  # echter Fehlschlag bleibt einer: konstante Entnahme, die das Depot vor dem Ende aufbraucht
  b <- withdrawal_simulation(matrix(0.9, 30, 1), withdrawal_rule("constant", rate = 10), tax = tax_profile(), cost_basis = 60)
  tabelle("planmaessige vollständige Entnahme (one_over_n, abw, hebeler, vpw) mit Steuern kein Fehlschlag",
    pruef(expect_false(b$paths$success),
          quelle = "Handrechnung (Herleitung im Test)"))
  # one_over_n monatlich: Leerung im letzten Jahr ebenfalls planmaessig
  Rm <- matrix(exp(rnorm(120 * 4, 0.004, 0.04)), 120)
  wm <- withdrawal_simulation(Rm, withdrawal_rule("one_over_n"), frequency = "month", tax = tax_profile(), cost_basis = 60)
  tabelle("planmaessige vollständige Entnahme (one_over_n, abw, hebeler, vpw) mit Steuern kein Fehlschlag",
    pruef(expect_true(all(wm$paths$success)),
          quelle = "Handrechnung (Herleitung im Test)"))
})

test_that("Pfadende-VP mit Verlusttopf nach dem Zwangsverkauf (Differenz wie simulation())", {
  t <- 0.26375
  # Gewinnverkauf: Verlusttopf 2000 deckt den Verkaufsgewinn im ablaufenden Jahr, die VP-Steuer steigt
  w <- withdrawal_simulation(matrix(1.10, 1, 1), withdrawal_rule("constant", rate = 0), start_value = 1e6, tax = tax_profile(),
                             base_rate = 2.5, partial_exemption = 30, cost_basis = 100, loss_carryforward = 2000)
  V <- 1.1e6; basis <- 1e6 + 17500; gq <- 1 - basis / V                       # Gewinnanteil je EUR Verkauf
  vtax0 <- (17500 * 0.7 - 2000 - 1000) * t                                   # 2439,69: Toepfe 2025 vor dem Verkauf
  loss1 <- 2000 - vtax0 * gq * 0.7                                            # Verkauf 2024: Gewinn n. TFS aus dem Topf
  vtax1 <- (17500 * 0.7 - loss1 - 1000) * t                                   # 2473,47 endgueltig
  G2 <- (vtax1 - vtax0) / (1 - gq * 0.7 * t)                                  # Nachzahlung: Verkauf 2025 (Topf und SPB leer)
  tabelle("Pfadende-VP mit Verlusttopf nach dem Zwangsverkauf (Differenz wie simulation())",
    wert(w$paths$taxes,
         vtax1 + G2 * gq * 0.7 * t,
         quelle = "vorher 2439,69", tol = 1e-10),
    wert(w$paths$terminal_nominal,
         V - vtax0 - G2,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10))
  # dasselbe Muster wie simulation(): Fonds A 990000 (+10 %), Verlusttopf 2000 aus einem Verlustverkauf, Ende 31.12.
  dd <- seq.Date(as.Date("2024-01-01"), as.Date("2024-12-31"), by = "day"); n <- length(dd)
  d <- data.frame(date = dd, A = seq(100, 110, length.out = n), B = ifelse(dd < as.Date("2024-06-01"), 100, 80))
  d$buy <- seq_len(n) == 1; d$sell <- dd == as.Date("2024-06-01")
  s <- create_strategy(A = asset_config("etf", share = 0.99, spread = 0, partial_exemption = 30),
                       B = asset_config("etf", "signal", share = 0.01, spread = 0, partial_exemption = 0, signal_buy = "buy", signal_sell = "sell"))
  r <- suppressMessages(simulation(d, s, start_value = 1e6, tax = tax_profile(base_rate = 2.5)))
  we <- withdrawal_simulation(matrix(1.10, 1, 1), withdrawal_rule("constant", rate = 0), start_value = 990000, tax = tax_profile(),
                              base_rate = 2.5, partial_exemption = 30, cost_basis = 100, loss_carryforward = 2000)
  tabelle("Pfadende-VP mit Verlusttopf nach dem Zwangsverkauf (Differenz wie simulation())",
    wert(we$paths$taxes,
         r$tax_report$total_taxes_paid,
         quelle = "2441,18 = VP 2440,71 + Nachverkauf 0,47", tol = 1e-9))
  # Verlustverkauf (Basis ueber dem Wert): Verkauf im ablaufenden Jahr erhoeht den Topf, Erstattung ins Depot
  wl <- withdrawal_simulation(matrix(1.10, 1, 1), withdrawal_rule("constant", rate = 0), start_value = 1e6, tax = tax_profile(),
                              base_rate = 2.5, partial_exemption = 30, cost_basis = 120)
  basis <- 1.2e6 + 17500; gl <- 1 - basis / V                                 # negativ
  vtax0 <- (17500 * 0.7 - 1000) * t
  loss1 <- -vtax0 * gl * 0.7
  vtax1 <- (17500 * 0.7 - loss1 - 1000) * t
  tabelle("Pfadende-VP mit Verlusttopf nach dem Zwangsverkauf (Differenz wie simulation())",
    pruef(expect_lt(vtax1, vtax0),
          quelle = "Handrechnung (Herleitung im Test)"),
    wert(wl$paths$taxes,
         vtax1,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10),
    wert(wl$paths$terminal_nominal,
         V - vtax0 + (vtax0 - vtax1),
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-10))
  # Horizont-Weg: Horizont 1 auf 3-Jahres-Pfaden = 1-Jahres-Pfad
  wh <- withdrawal_simulation(matrix(1.10, 3, 1), withdrawal_rule("constant", rate = 0), start_value = 1e6, tax = tax_profile(),
                              base_rate = 2.5, partial_exemption = 30, cost_basis = 100, loss_carryforward = 2000, horizon = 1)
  tabelle("Pfadende-VP mit Verlusttopf nach dem Zwangsverkauf (Differenz wie simulation())",
    wert(wh$paths$taxes,
         w$paths$taxes,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-12),
    wert(wh$paths$terminal_real,
         w$paths$terminal_real,
         quelle = "Handrechnung (Herleitung im Test)", tol = 1e-12))
})
