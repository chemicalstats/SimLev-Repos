# test-wrapper.R
# Fonds-Wrapper (Etappe 6.5c): wrapper_config, asset_config(wrapper = ), wrapper_nav, Einbau in simulation().

.wr_data <- function(n = 500, seed = 7) {
  set.seed(seed)
  d <- data.frame(date = seq.Date(as.Date("2019-11-01"), by = "day", length.out = n))
  d$A <- 100 * cumprod(1 + rnorm(n, 4e-4, 0.011)); d$B <- 50 * cumprod(1 + rnorm(n, 1e-4, 0.004))
  d$C <- 80 * cumprod(1 + rnorm(n, 2e-4, 0.006))
  d
}
.wr_inner <- function() create_strategy(A = asset_config("etf", "bnh", 0.6), B = asset_config("etf", "bnh", 0.4))

test_that("Plausibilitaet: Wrapper ohne Kosten und Spreads, ohne Steuern = innere Strategie", {
  d <- .wr_data()
  inner <- .wr_inner()
  w <- wrapper_config(inner, costs = funds_costs(0, 0))
  r_w <- simulation(d, create_strategy(Z = asset_config("certificate", wrapper = w)))
  r_i <- simulation(d, inner)
  expect_equal(tail(r_w$worth, 1), tail(r_i$worth, 1), tolerance = 1e-10)
  expect_equal(r_w$worth, r_i$worth, tolerance = 1e-10)
  # auch mit innerem Umschichten (gleiche Termine innen wie direkt)
  rb <- rebalance_plan(unit = "quarter")
  # (volume = Startwert: Mindestbetraege des Umschichtens wirken innen wie direkt)
  r_w2 <- simulation(d, create_strategy(Z = asset_config("certificate", wrapper = wrapper_config(inner, rebalance = rb, costs = funds_costs(0, 0),
                                                                                              volume = 10000))))
  r_i2 <- simulation(d, inner, rebalance = rb)
  expect_equal(tail(r_w2$worth, 1), tail(r_i2$worth, 1), tolerance = 1e-10)
  r_w3 <- simulation(d, create_strategy(Z = asset_config("certificate", wrapper = wrapper_config(inner, rebalance = rb, costs = funds_costs(0, 0)))))
  expect_equal(tail(r_w3$worth, 1), tail(r_i2$worth, 1), tolerance = 1e-6)
})

test_that("Rechenregeln am Handbeispiel: Gebuehr je Kalendertag, Schaltjahr, Abgrenzung und Festschreibung", {
  dh <- data.frame(date = as.Date(c("2020-02-27", "2020-02-28", "2020-03-02", "2020-12-30", "2020-12-31",
                                    "2021-01-04", "2021-06-30", "2021-12-31", "2022-01-03")),
                   A = c(100, 101, 103, 110, 112, 111, 95, 120, 121))
  fee <- 1; pf <- 20
  w <- wrapper_config(create_strategy(A = asset_config("etf")), costs = funds_costs(fee, pf))
  x <- wrapper_nav(dh, w)
  expect_s3_class(x, "SimLevWrapperNav")
  expect_identical(names(x), c("date", "nav", "gross", "fee", "perf_fee", "perf_paid", "hwm"))
  # von Hand: G_t / G_{t-1} = A_t / A_{t-1} (ein Asset, ohne Kosten innen), Start U = H = 100
  U <- 100; H <- 100; Gp <- 100; dp <- as.numeric(dh$date[1]); n <- nrow(dh)
  nav <- fe <- acc <- paid <- hwm <- numeric(n)
  for (t in 1:n) {
    y <- as.integer(format(dh$date[t], "%Y")); D <- if (y %% 4 == 0) 366 else 365
    a <- U * (dh$A[t] / dh$A[1] * 100 / Gp)
    fe[t] <- a * (fee / 100 * (as.numeric(dh$date[t]) - dp) / D)
    U <- a - fe[t]
    acc[t] <- pf / 100 * max(0, U - H)
    nav[t] <- U - acc[t]
    if (t < n && format(dh$date[t + 1], "%Y") != format(dh$date[t], "%Y")) { paid[t] <- acc[t]; U <- nav[t]; H <- max(H, U) }
    hwm[t] <- H; Gp <- dh$A[t] / dh$A[1] * 100; dp <- as.numeric(dh$date[t])
  }
  expect_equal(x$nav, nav, tolerance = 1e-12)
  expect_equal(x$fee, fe, tolerance = 1e-12)
  expect_equal(x$perf_fee, acc, tolerance = 1e-12)
  expect_equal(x$perf_paid, paid, tolerance = 1e-12)
  expect_equal(x$hwm, hwm, tolerance = 1e-12)
  expect_equal(x$gross, dh$A / dh$A[1] * 100)
  # Schaltjahr: 2020-02-28 -> 2020-03-02 sind 3 Kalendertage mit D = 366
  a3 <- (x$nav[2] + x$perf_fee[2]) * dh$A[3] / dh$A[2]
  expect_equal(x$fee[3], a3 * 0.01 * 3 / 366, tolerance = 1e-12)
  # Festschreibung am letzten Datentag 2020 und 2021, nicht am letzten Tag insgesamt
  expect_identical(x$perf_paid > 0, c(FALSE, FALSE, FALSE, FALSE, TRUE, FALSE, FALSE, TRUE, FALSE))
  expect_equal(x$hwm[5], x$nav[5])
  expect_identical(x$perf_fee[6], 0)          # nach Festschreibung unter dem Hoechststand
  expect_gt(x$perf_fee[9], 0)                 # am letzten Tag nur abgegrenzt (im nav enthalten)
  expect_equal(x$nav[9], (x$nav[9] + x$perf_fee[9]) - x$perf_fee[9])
  expect_identical(x$fee[1], 0)
})

test_that("Startkosten: Ordergebuehr mit volume und innerer Spread senken den ersten Anteilswert", {
  d <- .wr_data(60)
  w <- wrapper_config(.wr_inner(), costs = funds_costs(0, 0), order_fee = list(fixed = 5, percent = 0.1), volume = 1e6)
  x <- wrapper_nav(d, w)
  expect_equal(x$nav[1], 100 * ((6e5 - 5) / 1.001 + (4e5 - 5) / 1.001) / 1e6, tolerance = 1e-12)   # Kauf samt Gebuehr = Mittel
  ws <- suppressMessages(wrapper_config(create_strategy(A = asset_config("etf", "bnh", 1, spread = 0.2)), costs = funds_costs(0, 0)))
  expect_lt(wrapper_nav(d, ws)$nav[1], 100)
})

test_that("NA-Tage, spaeterer Beginn und Wochenenden", {
  d <- .wr_data(200)
  w <- wrapper_config(.wr_inner(), costs = funds_costs(0.95, 10))
  dn <- d; dn[c(20, 21), c("A", "B")] <- NA
  x <- suppressMessages(wrapper_nav(dn, w))
  expect_false(any(x$date %in% dn$date[c(20, 21)]))
  i <- which(x$date == dn$date[19])        # danach zwei Tage ohne Kurs: Gebuehr ueber 3 Kalendertage
  expect_identical(x$date[i + 1], dn$date[22])
  expect_equal(x$fee[i + 1], (x$nav[i] + x$perf_fee[i]) * x$gross[i + 1] / x$gross[i] * (0.95 / 100 * 3 / 365), tolerance = 1e-12)
  dl <- d; dl[1:5, c("A", "B")] <- NA
  expect_identical(wrapper_nav(dl, w)$date[1], d$date[6])
  r <- suppressMessages(simulation(dl, create_strategy(Z = asset_config(share = 0.5, wrapper = w), C = asset_config(share = 0.5))))
  expect_identical(r$report$Z$worth[1:5], rep(0, 5))
  expect_error(suppressMessages(simulation(dl, create_strategy(Z = asset_config(wrapper = w)))), "In der ersten Zeile")
  dw <- d[!format(d$date, "%u") %in% c("6", "7"), ]
  xw <- suppressMessages(wrapper_nav(dw, w))
  mo <- which(format(xw$date, "%u") == "1")[2]   # Montag: Gebuehr ueber 3 Kalendertage seit Freitag
  expect_equal(xw$fee[mo], (xw$nav[mo - 1] + xw$perf_fee[mo - 1]) * xw$gross[mo] / xw$gross[mo - 1] * (0.95 / 100 * 3 / 365),
               tolerance = 1e-12)
})

test_that("Fehler, Hinweis und Paketzustand .fee_env", {
  d <- .wr_data(100)
  inner <- .wr_inner()
  w <- wrapper_config(inner)
  expect_error(wrapper_config(create_strategy(Z = asset_config(wrapper = w))), "verschachtelte Wrapper")
  expect_error(asset_config("etf", "signal", signal_buy = "b", signal_sell = "s", wrapper = w), "nur trading = \"bnh\"")
  expect_error(simulation(d, list(Z = list(asset_class = "etf", trading = "signal", share = 1, signal_buy = "b",
                                           signal_sell = "s", wrapper = w))), "nur trading = \"bnh\"")
  d2 <- d; d2$Z <- 1
  expect_error(simulation(d2, create_strategy(Z = asset_config(wrapper = w))), "keine Spalte gleichen Namens")
  expect_error(strategy_validate(create_strategy(Z = asset_config(wrapper = w)), d2), "keine Spalte gleichen Namens")
  expect_true(strategy_validate(create_strategy(Z = asset_config(wrapper = w)), d))
  expect_error(strategy_validate(create_strategy(Z = asset_config(wrapper = w)), d[c("date", "A")]), "'B' fehlen")
  for (of in list(1, list(percent = 0.1, min = 1), list(percent = 0.1, max = 5)))
    expect_error(wrapper_config(inner, order_fee = of), "Fondsvolumen 'volume'")
  expect_no_error(wrapper_config(inner, order_fee = list(percent = 0.1)))
  expect_error(wrapper_config(inner, volume = 0), "'volume' muss")
  expect_error(wrapper_config(inner, costs = sim_costs()), "funds_costs")
  expect_error(wrapper_config(inner, rebalance = 1), "rebalance_plan")
  expect_error(wrapper_config(1), "create_strategy")
  expect_error(wrapper_config(create_strategy(A = asset_config(share = 0.5))), "summieren sich")
  expect_error(asset_config(wrapper = 1), "wrapper_config")
  expect_error(wrapper_nav(d, inner), "wrapper_config")
  expect_error(wrapper_nav(d, w, splits = 1), "split_rule")
  expect_message(wrapper_config(create_strategy(A = asset_config(spread = 0.1))), "Hinweis: wrapper_config: innere Assets mit Spread > 0: 'A' \\(0.1 %\\)")
  expect_silent(wrapper_config(inner))
  # .fee_env: Zustand nach wrapper_nav (auch mit Ordergebuehr und nach Fehler) unveraendert
  fe <- SimLev:::.fee_env
  assign("current", list(fixed = 1, percent = 0, min = 0, max = Inf), envir = fe); assign("paid", 12.5, envir = fe)
  before <- as.list(fe, all.names = TRUE)
  invisible(wrapper_nav(d, wrapper_config(inner, rebalance = rebalance_plan(), order_fee = list(fixed = 2, percent = 0.1), volume = 1e5)))
  expect_identical(as.list(fe, all.names = TRUE)[names(before)], before)
  expect_error(suppressMessages(wrapper_nav(transform(d, A = -1), w)), "innere Rechnung")
  expect_identical(as.list(fe, all.names = TRUE)[names(before)], before)
  assign("current", NULL, envir = fe); assign("paid", 0, envir = fe)
})

test_that("simulation(): details, keine Splits auf den Anteilswert, gemischtes Depot", {
  d <- .wr_data(300)
  w <- wrapper_config(.wr_inner(), rebalance = rebalance_plan(unit = "quarter"), costs = funds_costs(0.95, 10))
  st <- create_strategy(Z = asset_config("certificate", share = 0.7, spread = 0.3, wrapper = w), C = asset_config(share = 0.3))
  r0 <- simulation(d, st, tax = tax_profile())
  expect_null(r0$wrappers)
  r1 <- NULL
  invisible(capture.output(r1 <- simulation(d, st, tax = tax_profile(), details = TRUE)))
  expect_s3_class(r1$wrappers$Z, "SimLevWrapperNav")
  expect_equal(r1$worth, r0$worth)
  expect_identical(names(r1), c(names(r0), "wrappers"))
  # NAV als Kurs: Wert des Wrapper-Assets = Stueck x Anteilswert (Geldkurs mit halbem Spread)
  nv <- wrapper_nav(d, w)
  u <- r0$report$Z$worth / nv$nav
  expect_true(all(abs(u - u[1]) < 1e-9 * u[1]))
  # Splits: innen ja, der Anteilswert selbst nicht
  dsp <- d; dsp$A <- 100 * cumprod(1 + rnorm(300, 3e-3, 0.005))
  nvs <- wrapper_nav(dsp, w, splits = split_rule(c(50, 115)))
  expect_gt(max(nvs$nav), 115)
  expect_equal(nvs$nav, wrapper_nav(dsp, w)$nav, tolerance = 1e-7)   # fractions = TRUE innen: Splits aendern den Wert nur in der Rundung
  log_w <- capture.output(rs <- simulation(dsp, create_strategy(Z = asset_config("certificate", wrapper = w)), splits = split_rule(c(50, 115)),
                                           fractions = FALSE, details = TRUE))
  expect_false(any(grepl("Split", log_w)))
  us <- rs$report$Z$worth / nvs$nav
  expect_true(all(abs(us - us[1]) < 1e-9 * us[1]))
  dN <- data.frame(date = nvs$date, N = nvs$nav)          # dieselbe Reihe als gewoehnliche Kursspalte splittet
  log_n <- capture.output(simulation(dN, create_strategy(N = asset_config()), splits = split_rule(c(50, 115)), fractions = FALSE, details = TRUE))
  expect_true(any(grepl("Split", log_n)))
})

test_that("strategy_update_asset und strategy_add_asset mit Wrapper", {
  w <- wrapper_config(.wr_inner())
  st <- create_strategy(Z = asset_config("etf", wrapper = w))
  st2 <- strategy_update_asset(st, "Z", asset_class = "certificate", spread = 0.5)
  expect_identical(st2$Z$tax_regime, "capital_gains")
  expect_s3_class(st2$Z$wrapper, "SimLevWrapperConfig")
  expect_error(strategy_update_asset(st, "Z", trading = "signal", signal_buy = "a", signal_sell = "b"), "nur trading")
  st3 <- strategy_update_asset(create_strategy(A = asset_config()), "A", wrapper = w)
  expect_s3_class(st3$A$wrapper, "SimLevWrapperConfig")
  expect_identical(names(strategy_update_asset(st3, "A", wrapper = NULL)$A), names(asset_config()))
  st4 <- strategy_add_asset(create_strategy(C = asset_config(share = 0.5)), "Z", asset_config(share = 0.5, wrapper = w))
  expect_identical(names(st4), c("C", "Z"))
  expect_identical(names(asset_config()), c("asset_class", "trading", "share", "spread", "partial_exemption", "deliverable",
                                            "start", "tax_regime", "signal_buy", "signal_sell"))
  expect_identical(SimLev:::.strategy_columns(st4), c("C", "A", "B"))
  expect_identical(SimLev:::.strategy_columns(.wr_inner()), c("A", "B"))
})

test_that("Aufrufer: planning_lumpsum_vs_dca und withdrawal_simulation mit Wrapper", {
  d <- .wr_data(900)
  w <- wrapper_config(.wr_inner(), costs = funds_costs(0.5, 0))
  pl <- planning_lumpsum_vs_dca(d, create_strategy(Z = asset_config(wrapper = w)), amount = 1200, months = 4, horizon = 1, step = 6)
  expect_true(all(pl$exact))
  ws <- withdrawal_simulation(wrapper_nav(d, w), withdrawal_rule("percent", rate = 4), years = 1, frequency = "quarter")
  expect_s3_class(ws, "SimLevWithdrawal")
  co <- withdrawal_cohorts(wrapper_nav(d, w), price = "nav", years = 1, frequency = "quarter")
  expect_equal(ws$paths, withdrawal_simulation(co, withdrawal_rule("percent", rate = 4))$paths)
})

test_that("print: wrapper_config, asset_config mit Wrapper, wrapper_nav, funds_costs", {
  w <- wrapper_config(.wr_inner(), costs = funds_costs(0.95, 10), order_fee = list(percent = 0.1), volume = 1e6)
  out <- capture.output(print(w))
  expect_identical(out[1], "Fonds-Wrapper (wrapper_config)")
  expect_true(any(grepl("Fondsvolumen: +1000000.00 EUR", out)))
  expect_true(any(grepl("^  Wrapper: +A 60 %, B 40 %", capture.output(print(asset_config(wrapper = w))))))
  expect_identical(capture.output(print(funds_costs()))[1], "Fondskosten (funds_costs)")
  out <- capture.output(print(wrapper_nav(.wr_data(30), w)))
  expect_identical(out[1], "Anteilswert (wrapper_nav)")
  expect_true(any(grepl("Zeitraum: +2019-11-01 bis 2019-11-30 \\(30 Datentage\\)", out)))
})

test_that("Auswahl aus SimLevWrapperNav: gewoehnlicher data.frame ohne Klasse und Attribute (Etappe 8.0)", {
  d <- .wr_data(400)
  w <- wrapper_config(.wr_inner(), costs = funds_costs(0.95, 10))
  x <- wrapper_nav(d, w)
  plain <- function(s) {
    expect_identical(class(s), "data.frame")
    expect_null(attr(s, "inner")); expect_null(attr(s, "wrapper"))
  }
  plain(x[1:5, ]); plain(x[c("date", "nav")]); plain(x[x$nav > 100, c("date", "nav")]); plain(x[])
  plain(head(x, 3)); plain(tail(x, 3)); plain(subset(x, nav > 100, select = c(date, nav)))
  expect_identical(x[3, "nav"], x$nav[3])
  expect_identical(x[["nav"]], x$nav)
  # Werte unveraendert, das ganze Objekt behaelt Klasse und Attribute
  s <- x[10:20, ]
  expect_identical(s$nav, x$nav[10:20]); expect_identical(s$date, x$date[10:20])
  expect_s3_class(x, "SimLevWrapperNav")
  expect_s3_class(attr(x, "inner"), "SimLevResult")
  expect_s3_class(attr(x, "wrapper"), "SimLevWrapperConfig")
  # Druck des Ausschnitts als data.frame
  expect_identical(capture.output(print(head(x, 2))), capture.output(print(as.data.frame(unclass(x))[1:2, ])))
  # withdrawal_simulation: das ganze Objekt geht, ein Ausschnitt ergibt einen klaren Fehler
  expect_s3_class(withdrawal_simulation(x, withdrawal_rule("percent", rate = 4), years = 1, frequency = "quarter"),
                  "SimLevWithdrawal")
  expect_error(withdrawal_simulation(x[30:400, ], withdrawal_rule("percent", rate = 4), years = 1, frequency = "quarter"),
               "x ist eine Tabelle mit Spalte 'date'", fixed = TRUE)
  ws1 <- withdrawal_simulation(withdrawal_cohorts(x[30:400, ], price = "nav", inflation = 2, years = 1, frequency = "quarter"),
                               withdrawal_rule("percent", rate = 4))
  expect_s3_class(ws1, "SimLevWithdrawal")
})

test_that("strategy_from_weights und portfolio_template mit wrapper je Asset (Etappe 8.0)", {
  w <- wrapper_config(.wr_inner(), costs = funds_costs(0.95, 10))
  w2 <- wrapper_config(create_strategy(C = asset_config("etf", "bnh", 1)))
  has <- function(st) vapply(st, function(a) inherits(a$wrapper, "SimLevWrapperConfig"), TRUE)
  # ein Objekt fuer alle Assets
  st <- strategy_from_weights(c(x = 0.5, y = 0.5), wrapper = w)
  expect_identical(has(st), c(x = TRUE, y = TRUE))
  expect_identical(st$x$wrapper, w)
  # benannte Liste je Asset, Assets ohne Eintrag ohne Wrapper (Objekt wie ohne wrapper)
  st <- strategy_from_weights(c(x = 0.5, y = 0.3, z = 0.2), spread = c(z = 0.1), wrapper = list(y = w2, x = w))
  expect_identical(has(st), c(x = TRUE, y = TRUE, z = FALSE))
  expect_identical(st$y$wrapper, w2)
  expect_identical(st$z, strategy_from_weights(c(x = 0.5, y = 0.3, z = 0.2), spread = c(z = 0.1))$z)
  expect_identical(strategy_from_weights(c(x = 0.5, y = 0.5), wrapper = NULL), strategy_from_weights(c(x = 0.5, y = 0.5)))
  expect_identical(strategy_from_weights(c(x = 0.5, y = 0.5), wrapper = list()), strategy_from_weights(c(x = 0.5, y = 0.5)))
  # simulation mit der so gebauten Strategie = mit create_strategy gebaut
  d <- .wr_data(300)
  st <- strategy_from_weights(c(Z = 0.7, C = 0.3), asset_class = c(Z = "certificate"), wrapper = list(Z = w))
  r1 <- simulation(d, st)
  r2 <- simulation(d, create_strategy(Z = asset_config("certificate", share = 0.7, wrapper = w), C = asset_config("etf", share = 0.3)))
  expect_identical(r1$worth, r2$worth)
  # portfolio_template: Namen nach map, Rollen ohne map-Eintrag unter ihrem Namen
  st <- portfolio_template("60_40", map = c(stocks = "aktien"), wrapper = list(aktien = w, bonds = w2))
  expect_identical(has(st), c(aktien = TRUE, bonds = TRUE))
  expect_identical(has(portfolio_template("60_40", wrapper = w)), c(stocks = TRUE, bonds = TRUE))
  # Fehler
  expect_error(portfolio_template("60_40", map = c(stocks = "aktien"), wrapper = list(stocks = w)),
               "wrapper: 'stocks' ist kein Asset der Strategie (Assets: aktien, bonds).", fixed = TRUE)
  expect_error(strategy_from_weights(c(x = 0.5, y = 0.5), wrapper = list(x = w, y = "w")),
               "wrapper: Eintrag 'y' muss ein Objekt aus wrapper_config() sein, nicht character.", fixed = TRUE)
  expect_error(strategy_from_weights(c(x = 0.5, y = 0.5), wrapper = list(w)), "braucht jedes Element einen Namen", fixed = TRUE)
  expect_error(strategy_from_weights(c(x = 0.5, y = 0.5), wrapper = 1), "nicht numeric.", fixed = TRUE)
  expect_error(strategy_from_weights(c(x = 0.5, y = 0.5), trading = c(y = "signal"), signal_buy = "b", signal_sell = "s",
                                     wrapper = list(y = w)),
               "wrapper: Asset 'y' hat trading = \"signal\"", fixed = TRUE)
  # andere Fehler von asset_config bleiben unveraendert
  expect_error(strategy_from_weights(c(x = 0.5, y = 0.5), trading = c(y = "signal"), wrapper = list(y = w)),
               "asset_config: bei trading = \"signal\" müssen signal_buy", fixed = TRUE)
})
