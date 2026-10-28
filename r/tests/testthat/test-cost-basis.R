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
  expect_equal(vp, 4106.7134, tolerance = 1e-7)
  expect_equal(r$open_lots$A$lots$units, 1000)
  expect_equal(sum(r$open_lots$A$lots$vp), vp, tolerance = 1e-10)
  sv <- 1000 * 100 * 1.08^(1825 / 365.25)                       # Endwert 146894,08 (Stueck x Schlusskurs)
  expect_equal(tail(r$worth, 1), sv, tolerance = 1e-12)
  B <- 1e5 + vp                                                  # Anschaffungskosten + anzurechnende VP
  # Entnahmephase: ein Jahr ohne Rendite (keine neue VP), 4 % des Startwerts zu Jahresbeginn. Erstes Planjahr = 2020;
  # die am 31.12.2019 festgesetzte VP 952,34 hat dort schon 0,7 x 952,34 = 666,64 des Pauschbetrags verbraucht
  ws <- suppressMessages(withdrawal_simulation(matrix(1, 1, 1), withdrawal_rule("constant", rate = 4), start_value = r,
                                               tax = tax_profile(), partial_exemption = 30, base_rate = 1))
  spb1 <- 1000 - 0.7 * 1000 * 0.7 * 0.01 * 100 * 1.08^(1461 / 365.25)   # Rest 333,36
  expect_equal(r$tax_report$next_year$sparer_pauschbetrag_remaining, spb1, tolerance = 1e-10)
  X <- 0.04 * sv; g <- 1 - B / sv                                # Gewinnanteil je Euro Verkauf
  G <- (X - spb1 * 0.26375) / (1 - 0.7 * g * 0.26375)            # Bruttoverkauf fuer netto X
  tax <- (0.7 * g * G - spb1) * 0.26375
  expect_equal(ws$paths$taxes, tax, tolerance = 1e-10)           # 241,03 EUR (voller Pauschbetrag: 55,20 EUR)
  # Engine-Rechnung (man/simulation.Rd, open_lots) fuer den Verkauf derselben s = 1000 x G / sv Stueck:
  s <- 1000 * G / sv; P <- sv / 1000
  tax_engine <- ((s * (P - 100) - vp * s / 1000) * 0.7 - spb1) * 0.26375
  expect_equal(ws$paths$taxes, tax_engine, tolerance = 1e-10)
  # gleich der ausdruecklichen Angabe; die alte Naeherung (Basis 1e5 ohne VP) ergab mehr Steuer
  wx <- suppressMessages(withdrawal_simulation(matrix(1, 1, 1), withdrawal_rule("constant", rate = 4), start_value = r,
                              tax = tax_profile(), partial_exemption = 30, base_rate = 1, cost_basis = 100 * B / sv))
  expect_equal(ws$paths, wx$paths, tolerance = 1e-10)           # ein Lot: FIFO = Durchschnittskosten
  wo <- suppressMessages(withdrawal_simulation(matrix(1, 1, 1), withdrawal_rule("constant", rate = 4), start_value = r,
                              tax = tax_profile(), partial_exemption = 30, base_rate = 1, cost_basis = 100 * 1e5 / sv))
  expect_gt(wo$paths$taxes, ws$paths$taxes + 25)
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
  expect_true(all(r0$sells > 0))                                  # Umschichtungen mit FIFO-Verkaeufen
  expect_gt(nrow(r0$open_lots$A$lots), 50)
  expect_gt(sum(r0$open_lots$A$lots$vp), 0)
  tax_engine <- r1$tax_report$total_taxes_paid - r0$tax_report$total_taxes_paid   # Steuer des Schlussverkaufs
  # ganzer Bestand in einer Entnahme (Regel 100 % des Startwerts), gleiche Toepfe: SPB 0, Verlusttopf der Ansparphase,
  # Verkaufskosten = halber Spread (0,1 %)
  ws <- withdrawal_simulation(matrix(1, 1, 1), withdrawal_rule("constant", rate = 100), start_value = r0, tax = tax_profile(sparer_pauschbetrag = 0),
                              partial_exemption = 30, sale_cost = 0.1, base_rate = 2,
                              loss_carryforward = r0$tax_report$loss_carryforward_capital)
  expect_equal(ws$paths$taxes, tax_engine, tolerance = 1e-9)
  expect_equal(ws$paths$terminal_nominal, 0)
  # Handrechnung aus den Lots: (Endwert x (1 - 0,001) - Basis) x 0,7 x 26,375 %
  B <- sum(sapply(r0$open_lots, function(a) sum(a$lots$units * a$lots$price) + sum(a$lots$vp) + a$cash))
  expect_equal(ws$paths$taxes, (tail(r0$worth, 1) * 0.999 - B) * 0.7 * 0.26375, tolerance = 1e-9)
  # die alte Naeherung (Start + Einzahlungen) traf die Engine nicht
  inv <- r0$invested[1] + sum(pmax(result_index(r0)$flows[-1], 0))
  wo <- withdrawal_simulation(matrix(1, 1, 1), withdrawal_rule("constant", rate = 100), start_value = r0, tax = tax_profile(sparer_pauschbetrag = 0),
                              partial_exemption = 30, sale_cost = 0.1, base_rate = 2,
                              loss_carryforward = r0$tax_report$loss_carryforward_capital, cost_basis = 100 * inv / tail(r0$worth, 1))
  expect_gt(abs(wo$paths$taxes - tax_engine), 100)
})

test_that("ohne open_lots: bisherige N\u00e4herung (mit Warnung bei tax_mode = 'person'); Angabe gilt immer", {
  d <- data.frame(date = .cb_days("2015-01-01", "2019-12-31"))
  d$A <- 100 * 1.08^(as.numeric(d$date - d$date[1]) / 365.25)
  st <- create_strategy(A = asset_config("etf", "bnh", spread = 0, partial_exemption = 30))
  r <- simulation(d, st, start_value = 1e5, dca = dca_plan(value = 100, span = 1))     # tax_mode = "none"
  expect_null(r$open_lots)
  x <- matrix(1.03, 5, 2)
  inv <- r$invested[1] + sum(pmax(result_index(r)$flows[-1], 0))
  expect_warning(w <- withdrawal_simulation(x, start_value = r, tax = tax_profile()), "cost_basis: N\u00e4herung 100 x")
  expect_identical(w$paths, withdrawal_simulation(x, start_value = r, tax = tax_profile(), cost_basis = 100 * inv / tail(r$worth, 1))$paths)
  expect_silent(withdrawal_simulation(x, start_value = r))                    # ohne Steuern keine Warnung
  # aelteres Ergebnis mit tax_mode = "person", aber ohne open_lots: ebenso
  rp <- simulation(d, st, start_value = 1e5, tax = tax_profile(base_rate = 1)); rp$open_lots <- NULL
  expect_warning(withdrawal_simulation(x, start_value = rp, tax = tax_profile()), "keine offenen Lots")
  # ausdruecklich angegebenes cost_basis gilt immer (keine Naeherungswarnung)
  rp2 <- simulation(d[-nrow(d), ], st, start_value = 1e5, tax = tax_profile(base_rate = 1))   # Ende 30.12.: keine offene VP
  expect_warning(w1 <- suppressMessages(withdrawal_simulation(x, start_value = rp2, tax = tax_profile(), cost_basis = 55)), NA)
  expect_null(w1$adopted$lots)                                                # ohne FIFO-Lots
  w2 <- withdrawal_simulation(x, start_value = tail(rp2$worth, 1), tax = tax_profile(), cost_basis = 55)
  expect_identical(w1$paths, w2$paths)
})

test_that("abweichende Teilfreistellung und Regime der gehaltenen Assets: Warnung", {
  d <- data.frame(date = .cb_days("2018-01-01", "2019-12-31"))
  d$A <- 100 * 1.05^(as.numeric(d$date - d$date[1]) / 365.25); d$N <- d$A; d$C <- d$A
  run <- function(st, ...) suppressMessages(simulation(d, st, start_value = 1e4, tax = tax_profile(base_rate = 1, ...)))
  x <- matrix(1.02, 3, 1)
  # asset_config-Standard partial_exemption = 0 gegen Standard 30 der Entnahmephase
  r0 <- run(create_strategy(A = asset_config("etf", "bnh", spread = 0)))
  # nicht angegeben: einheitliche Teilfreistellung uebernommen; ausdruecklich 30: Warnung
  expect_equal(suppressMessages(withdrawal_simulation(x, start_value = r0, tax = tax_profile()))$adopted$partial_exemption, 0)
  expect_warning(suppressMessages(withdrawal_simulation(x, start_value = r0, tax = tax_profile(), partial_exemption = 30)),
                 "partial_exemption = 30 %, aber .*Teilfreistellung A 0 %")
  expect_warning(suppressMessages(withdrawal_simulation(x, start_value = r0, tax = tax_profile(), partial_exemption = 0)), NA)
  # gemischt: Fonds 30 % und ETN (capital_gains, zaehlt als 0 %)
  rm <- run(create_strategy(A = asset_config("etf", "bnh", share = 0.5, spread = 0, partial_exemption = 30),
                            N = asset_config("etn", "bnh", share = 0.5, spread = 0)))
  expect_equal(rm$open_lots$N$regime, "capital_gains")
  expect_warning(w <- suppressMessages(withdrawal_simulation(x, start_value = rm, tax = tax_profile())),
                 "verschiedenen Regimen \\(Investmentfonds: A; andere: N\\)")
  expect_null(w$adopted$partial_exemption); expect_null(w$adopted$vorabpauschale)  # gemischt: nicht uebernommen
  # § 23 (lieferbares ETC): nicht abbildbar
  rc <- run(create_strategy(C = asset_config("etc", "bnh", spread = 0, deliverable = TRUE)), income = income_rate(42))
  expect_equal(rc$open_lots$C$regime, "private_sale")
  expect_warning(suppressMessages(withdrawal_simulation(x, start_value = rc, tax = tax_profile())), "Regime 'private_sale' \\(Paragraf 23 EStG: C\\)")
  # Basis bleibt die exakte Lot-Basis
  w <- suppressMessages(suppressWarnings(withdrawal_simulation(x, start_value = rc, tax = tax_profile())))
  B <- with(rc$open_lots$C, sum(lots$units * lots$price) + sum(lots$vp) + cash)
  expect_equal(w$paths, suppressMessages(suppressWarnings(withdrawal_simulation(x, start_value = rc, tax = tax_profile(),
                                                          cost_basis = 100 * B / tail(rc$worth, 1))))$paths, tolerance = 1e-10)
  # ohne Steuern in der Entnahmephase keine Warnung
  expect_silent(withdrawal_simulation(x, start_value = rm))
})

test_that("R5-03: start_value <= 0 (Zahl oder Endwert eines SimLevResult) ist ein Fehler", {
  d <- .cb_days("2020-01-01", "2021-06-30")
  df <- data.frame(date = d, G = ifelse(d < as.Date("2020-06-01"), 100, 150), H = ifelse(d < as.Date("2020-10-01"), 50, 1))
  df$ev <- d == as.Date("2020-07-01"); df$wG <- 0; df$wH <- 1
  st <- create_strategy(G = asset_config("etc", "bnh", share = 0.5, spread = 0, deliverable = TRUE),
                        H = asset_config("certificate", "bnh", share = 0.5, spread = 0))
  r <- suppressWarnings(simulation(df, st, start_value = 1e4, rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(G = "wG", H = "wH")), tax = tax_profile(income = income_rate(marginal_rate = 42))))
  expect_equal(tail(r$worth, 1), -800)                       # § 23-Steuer 1050 aus 250 Restwert nicht gedeckt
  expect_equal(r$tax_report$open_tax_debt, 800)
  # vorher still gerechnet (Endvermoegen -927, "Schuld" mit Marktrendite verzinst)
  expect_error(withdrawal_simulation(matrix(1.03, 5, 1), start_value = r, tax = tax_profile(), partial_exemption = 0),
               "start_value: Endwert der Ansparphase \\(SimLevResult\\) ist -800.*offene, nicht gedeckte Steuerschuld der Ansparphase: 800")
  for (v in list(-800, 0, NA_real_, Inf, c(1, 2), "1e5"))
    expect_error(withdrawal_simulation(matrix(1.03, 5, 1), start_value = v), "start_value muss ein positiver Geldbetrag", info = format(v))
  expect_s3_class(withdrawal_simulation(matrix(1.03, 5, 1), start_value = 1), "SimLevWithdrawal")
})
