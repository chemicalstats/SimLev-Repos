# Tests zu den Befunden R1-01 bis R1-28 (Blue Team 1, Engine)

.bt_cal <- function(from, to, ...) {
  dd <- seq.Date(as.Date(from), as.Date(to), by = "day"); data.frame(date = dd, ...)
}
.bt_st1 <- function(...) create_strategy(A = asset_config("etf", asset_share = 1, asset_spread = 0, ...))

test_that("R1-01: funds_fee wird auch bei voll investiertem Depot belastet (Teilverkauf)", {
  d <- .bt_cal("2020-01-01", "2022-12-30", A = 100)
  r <- simulation(d, .bt_st1(), tax_mode = "funds", funds_fee = 10, bonus_fee = 0)
  # Handrechnung: linearer Tagessatz 0,1 / Tage des Jahres auf konstanten Wert (volles Jahr
  # genau 10 %), 2022 nur 364 Tage (angepasst an Punkt B7, vorher Tagessatz 1,1^(1/Tage) - 1)
  v <- 10000; v <- v - 366 * (0.1 / 366) * v; v <- v - 365 * (0.1 / 365) * v
  v <- v - 364 * (0.1 / 365) * v
  expect_equal(tail(r$worth, 1), v, tolerance = 1e-9)
  expect_lt(tail(r$worth, 1), 7500)
})

test_that("R1-02: Fondssteuer bei Liquidation unabhaengig davon, ob der Endtag der 31.12. ist", {
  mk <- function(end) { d <- .bt_cal("2020-01-01", end); d$A <- 100 * 1.0005^(seq_len(nrow(d)) - 1); d }
  run <- function(end) simulation(mk(end), .bt_st1(), tax_mode = "funds", funds_fee = 0, bonus_fee = 0, liquidate = TRUE)
  a <- run("2022-12-30"); b <- run("2022-12-31")
  g <- function(n) { v <- 10000 * 1.0005^(n - 1); v - 0.26375 * (v - 10000) }
  expect_equal(tail(a$worth, 1), g(1095), tolerance = 1e-9)
  expect_equal(tail(b$worth, 1), g(1096), tolerance = 1e-9)
  expect_equal(b$tax_report$total_taxes_paid, 0.26375 * (10000 * 1.0005^1095 - 10000), tolerance = 1e-9)
  # Jahresgebuehr am 31.12. nicht doppelt: mit funds_fee nur eine Belastung im Endjahr
  c1 <- simulation(mk("2021-12-31"), .bt_st1(), tax_mode = "funds", funds_fee = 1, bonus_fee = 0)
  c2 <- simulation(mk("2021-12-31"), .bt_st1(), tax_mode = "funds", funds_fee = 1, bonus_fee = 0, liquidate = TRUE)
  expect_equal(tail(c2$worth, 1) + c2$tax_report$total_taxes_paid, tail(c1$worth, 1), tolerance = 1e-9)
})

test_that("R1-03: Einzahlungen sind kein Gewinn (Steuer und Performancegebuehr)", {
  d <- .bt_cal("2020-01-01", "2022-12-30", A = 100)
  r <- simulation(d, .bt_st1(), tax_mode = "funds", funds_fee = 0, bonus_fee = 0, liquidate = TRUE,
                  dca_mode = TRUE, dca_value = 1000, dca_span = 1)
  expect_equal(tail(r$worth, 1), 10000 + sum(r$report$A$flows))
  expect_equal(r$tax_report$total_taxes_paid, 0)
  d2 <- .bt_cal("2020-01-01", "2021-06-30", A = 100, b = FALSE, s = FALSE)
  st2 <- create_strategy(A = asset_config("etf", "signal", asset_share = 1, asset_spread = 0, signal_buy = "b", signal_sell = "s"))
  r2 <- simulation(d2, st2, tax_mode = "funds", funds_fee = 0, bonus_fee = 5, dca_mode = TRUE, dca_value = 1000, dca_span = 1)
  expect_equal(tail(r2$worth, 1), 10000 + sum(r2$report$A$flows))
})

test_that("R1-04: dca_fee nur f\u00fcr Sparplankaeufe, Rebalancing am selben Tag mit order_fee", {
  set.seed(2); n <- 3 * 365
  d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n),
                  A = 100 * cumprod(1 + rnorm(n, 5e-4, 0.015)), B = 100 * cumprod(1 + rnorm(n, 0, 0.003)))
  st <- create_strategy(A = asset_config("etf", asset_share = .5, asset_spread = 0), B = asset_config("etf", asset_share = .5, asset_spread = 0))
  r1 <- simulation(d, st, balance_mode = TRUE, dca_mode = TRUE, dca_value = 100, dca_span = 1, order_fee = 10, dca_fee = 0)
  r2 <- simulation(d, st, balance_mode = TRUE, dca_mode = TRUE, dca_value = 100, dca_span = 1, dca_days = 2, order_fee = 10, dca_fee = 0)
  expect_gt(r1$fees_paid, 0)
  expect_equal(r1$fees_paid, r2$fees_paid, tolerance = 0.1)
  # reiner Sparplan ohne Rebalancing bleibt gebuehrenfrei
  r3 <- simulation(d, st, dca_mode = TRUE, dca_value = 100, dca_span = 1, dca_days = 2, order_fee = 10, dca_fee = 0)
  expect_equal(r3$fees_paid, 20)   # nur die beiden Erstkaeufe am Starttag (kein Sparplantag)
})

test_that("R1-05: Split mit fractions = FALSE erh\u00e4lt den Depotwert (Spitzenausgleich zum Tageskurs)", {
  set.seed(3); n <- 3 * 365
  d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n), A = 100 * cumprod(1 + rnorm(n, 2e-3, 0.01)))
  i <- which(d$A > 250)[1]
  a <- simulation(d, .bt_st1(), fractions = FALSE)
  b <- simulation(d, .bt_st1(), fractions = FALSE, split_mode = TRUE, split_thresh = c(20, 250))
  expect_equal(b$worth[i], a$worth[i], tolerance = 1e-12)
  cnt <- b$report$A$worth[i] / 100                          # Kurs nach dem Split = 100
  expect_equal(cnt, round(cnt), tolerance = 1e-9)            # ganze Stuecke
  bt <- simulation(d, .bt_st1(), fractions = FALSE, split_mode = TRUE, split_thresh = c(20, 250), tax_mode = "person")
  expect_equal(bt$worth[i - 1], simulation(d, .bt_st1(), fractions = FALSE, tax_mode = "person")$worth[i - 1])
})

test_that("R1-06: Split im laufenden Jahr laesst die Vorabpauschale unver\u00e4ndert", {
  set.seed(3); n <- 3 * 365
  d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n), A = 100 * cumprod(1 + rnorm(n, 2e-3, 0.01)))
  args <- list(tax_mode = "person", start_value = 1e5, base_rate = 2, use_sparer_pauschbetrag = FALSE)
  a <- do.call(simulation, c(list(d, .bt_st1()), args))
  b <- do.call(simulation, c(list(d, .bt_st1()), args, list(split_mode = TRUE, split_thresh = c(20, 250))))
  expect_equal(b$tax_report$total_taxes_paid, a$tax_report$total_taxes_paid, tolerance = 1e-4)
})

test_that("R1-12: sp\u00e4ter startendes Asset erh\u00e4lt sein Zielgewicht (mit und ohne balance_mode)", {
  d <- .bt_cal("2020-01-01", "2022-03-10", A = 100, B = 100)
  st <- create_strategy(A = asset_config("etf", asset_share = .5, asset_spread = 0),
                        B = asset_config("etf", asset_share = .5, asset_spread = 0, asset_start = as.Date("2020-06-01")))
  r <- simulation(d, st, balance_mode = TRUE, balance_unit = "year")
  for (dt in c("2020-06-01", "2021-01-01", "2022-01-01"))
    expect_equal(r$report$B$share[r$dates == as.Date(dt)], 0.5, tolerance = 1e-6)
  # Punkt C10: auch ohne balance_mode Umschichtung am Aktivierungstag, keine Warnung mehr
  expect_no_warning(r2 <- simulation(d, st))
  expect_equal(r2$report$B$share[r2$dates == as.Date("2020-06-01")], 0.5, tolerance = 1e-6)
})

test_that("R1-13/R1-14: unsortierte Daten werden sortiert, doppelte Daten abgewiesen", {
  set.seed(4); n <- 400
  d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n), A = 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)))
  ref <- simulation(d, .bt_st1())
  set.seed(5)
  expect_message(r <- simulation(d[sample(n), ], .bt_st1()), "sortiert")
  expect_identical(r$worth, ref$worth); expect_identical(r$dates, ref$dates)
  expect_identical(suppressMessages(simulation(d[n:1, ], .bt_st1()))$worth, ref$worth)
  dd <- rbind(d, d[200, ]); dd <- dd[order(dd$date), ]
  expect_error(simulation(dd, .bt_st1()), "mehrfach")
})

test_that("R1-15: NA- und ung\u00fcltige Kurse", {
  set.seed(4); n <- 400
  d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n), A = 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)))
  dn <- d; dn$A[100] <- NA
  expect_message(r <- simulation(dn, .bt_st1()), "LOCF")
  dl <- d; dl$A[100] <- dl$A[99]
  expect_equal(r$worth[100], simulation(dl, .bt_st1())$worth[100])
  expect_true(r$filled[100]); expect_lt(r$statistics$max_drawdown, 0.5)
  d0 <- d; d0$A[50] <- 0
  expect_error(simulation(d0, .bt_st1()), "ung\u00fcltige Kurse")
  d1 <- d; d1$A[1] <- NA
  expect_error(simulation(d1, .bt_st1()), "ersten Zeile")
  # juengeres Asset aus align_series(range = "all"): wie asset_start, kein Cash-Verlust
  set.seed(15)
  a1 <- .bt_cal("2020-01-01", "2022-12-31"); a1$world <- 100 * cumprod(1 + rnorm(nrow(a1), 3e-4, 0.01))
  a2 <- .bt_cal("2021-01-01", "2022-12-31"); a2$gold <- 100 * cumprod(1 + rnorm(nrow(a2), 2e-4, 0.008))
  al <- align_series(world = a1, gold = a2, range = "all")
  st <- create_strategy(world = asset_config("etf", asset_share = .7, asset_spread = 0),
                        gold = asset_config("etc", asset_share = .3, asset_spread = 0))
  r <- suppressMessages(simulation(al, st, balance_mode = TRUE, balance_unit = "year"))
  expect_equal(r$worth[1], 10000)
  expect_equal(r$report$gold$share[r$dates == as.Date("2021-01-01")], 0.3, tolerance = 1e-6)
})

test_that("R1-16: zwei Sparplantermine am selben Handelstag z\u00e4hlen doppelt", {
  set.seed(7)
  cal <- seq.Date(as.Date("2020-01-01"), as.Date("2022-12-31"), by = "day"); wd <- cal[!format(cal, "%u") %in% c("6", "7")]
  d <- data.frame(date = wd, A = 100 * cumprod(1 + rnorm(length(wd), 4e-4, 0.01)))
  r <- suppressMessages(simulation(d, .bt_st1(), dca_mode = TRUE, dca_value = 100, dca_span = 1, dca_days = c(1, 2)))
  expect_equal(sum(r$report$A$flows), 36 * 2 * 100)
})

test_that("R1-17: Attribut 'filled' aus align_series wirkt wie selbst aufgef\u00fcllte Tage", {
  set.seed(11)
  cal <- seq.Date(as.Date("2021-01-04"), as.Date("2021-06-30"), by = "day"); wd <- cal[!format(cal, "%u") %in% c("6", "7")]
  us <- data.frame(date = wd, A = 100 * cumprod(1 + rnorm(length(wd), 0, 0.01)))
  al <- align_series(us = us)
  names(al)[2] <- "A"; colnames(attr(al, "filled")) <- "A"
  args <- list(dca_mode = TRUE, dca_value = 100, dca_span = 1, balance_mode = TRUE)
  ra <- do.call(simulation, c(list(al, .bt_st1()), args))
  rb <- suppressMessages(do.call(simulation, c(list(us, .bt_st1()), args)))
  expect_identical(ra$filled, rb$filled); expect_true(any(ra$filled))
  expect_equal(ra$worth, rb$worth); expect_equal(ra$statistics$sd, rb$statistics$sd)
})

test_that("R1-18: Zwangsverkauf f\u00fcr die Vorabpauschale deckt auch die Ordergeb\u00fchr", {
  d <- .bt_cal("2020-01-01", "2021-01-31"); d$A <- seq(100, 110, length.out = nrow(d))
  a <- simulation(d, .bt_st1(), tax_mode = "person", base_rate = 2, use_sparer_pauschbetrag = FALSE)
  b <- simulation(d, .bt_st1(), tax_mode = "person", base_rate = 2, use_sparer_pauschbetrag = FALSE, order_fee = 10)
  i <- which(d$date == as.Date("2021-01-01"))
  expect_lt(b$report$A$worth[i] + b$report$A$money[i] - (b$report$A$worth[i - 1] + b$report$A$money[i - 1]),
            a$report$A$worth[i] + a$report$A$money[i] - (a$report$A$worth[i - 1] + a$report$A$money[i - 1]) - 7)
  expect_gte(b$report$A$money[i], 0)
  expect_equal(b$fees_paid, 20)   # Erstkauf + Zwangsverkauf
})

test_that("R1-19/R1-22: Dashboard-Kennzahlen wie statistics, kurze Reihen und PDF-Export robust", {
  set.seed(12); n <- 3 * 365
  d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n), A = 100 * cumprod(1 + rnorm(n, 4e-4, 0.01)))
  r <- simulation(d, .bt_st1(), dca_mode = TRUE, dca_value = 5000, dca_span = 1)
  dr <- SimLev:::.dashboard_returns(r)
  expect_equal(sd(dr$returns), r$statistics$sd, tolerance = 1e-12)
  expect_lt(max(dr$returns), 0.1)                         # Einzahlungen sind keine Renditen
  expect_equal(dr$ppy, (n - 1) / ((n - 1) / 365.25))
  pdf(NULL); on.exit(dev.off(), add = TRUE)
  expect_silent(plot(r))
  expect_silent(plot(simulation(d[1:3, ], .bt_st1())))
  f <- tempfile(fileext = ".pdf"); nd <- length(dev.list())
  bad <- r; bad$worth <- NULL
  expect_error(suppressMessages(export_dashboard(bad, f)))
  expect_equal(length(dev.list()), nd)
})

test_that("R1-20: plot_interactive zeigt CAGR und Sharpe", {
  set.seed(12); n <- 400
  d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n), A = 100 * cumprod(1 + rnorm(n, 4e-4, 0.01)))
  r <- simulation(d, .bt_st1())
  h <- readLines(plot_interactive(r, file = tempfile(fileext = ".html"), engine = "html", open = FALSE))
  expect_true(any(grepl(sprintf("CAGR %.2f%%", 100 * r$cagr), h, fixed = TRUE)))
  expect_true(any(grepl(sprintf("Sharpe %.2f", r$statistics$sharpe), h, fixed = TRUE)))
})

test_that("R1-21: compute_rebal_trigger mit fuehrendem NA", {
  df <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 6),
                   target_leverage = c(NA, 2, 2.3, 2.3, 1.9, 2), sigma_ewma = c(NA, NA, .1, .2, .1, .1))
  expect_equal(compute_rebal_trigger(df, "abs_leverage")$rebal_trigger, c(FALSE, FALSE, TRUE, FALSE, TRUE, TRUE))
  expect_equal(compute_rebal_trigger(df, "vol_band")$rebal_trigger, c(FALSE, FALSE, FALSE, TRUE, TRUE, FALSE))
  expect_false(any(compute_rebal_trigger(transform(df, sigma_ewma = NA_real_), "vol_band")$rebal_trigger))
})

test_that("R1-22: verstaendliche Fehler und Umwandlungen", {
  set.seed(4); n <- 400
  d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n), A = 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)))
  ref <- simulation(d, .bt_st1())
  dc <- d; dc$date <- as.character(dc$date)
  expect_message(r <- simulation(dc, .bt_st1()), "Text"); expect_identical(r$worth, ref$worth)
  df <- d; df$date <- factor(df$date); expect_identical(suppressMessages(simulation(df, .bt_st1()))$worth, ref$worth)
  dx <- d; dx$date <- format(dx$date, "%d.%m.%Y"); expect_error(simulation(dx, .bt_st1()), "JJJJ-MM-TT")
  if (requireNamespace("tibble", quietly = TRUE)) expect_identical(simulation(tibble::as_tibble(d), .bt_st1())$worth, ref$worth)
  expect_error(simulation(d, create_strategy(Z = asset_config("etf"))), "Kursspalte 'Z' fehlt")
  expect_error(simulation(d, .bt_st1(), dca_mode = TRUE, dca_value = 1, dca_span = 1, dca_start = "2025-01-01"), "nach dem letzten Datentag")
  expect_error(create_strategy(A = asset_config("etf", asset_share = .5), A = asset_config("etf", asset_share = .5)), "mehrfach")
  expect_error(simulation(d, list(A = list(asset_class = "etf", action_type = "bnh", asset_share = .5),
                                  A = list(asset_class = "etf", action_type = "bnh", asset_share = .5))), "mehrfach")
  expect_error(simulation(d, .bt_st1(asset_start = as.Date("2020-06-01"))), "Kein Asset")
  d$B <- 100; d$ev <- FALSE; d$ev[100] <- TRUE; d$wA <- .5; d$wN <- -1
  st2 <- create_strategy(A = asset_config("etf", asset_share = .5), B = asset_config("etf", asset_share = .5))
  expect_warning(simulation(d, st2, event_col = "ev", event_weight = c(A = "wA")), "nicht alle Assets")
  expect_error(simulation(d, st2, event_col = "ev", event_weight = c(A = "wA", B = "xx")), "'xx'")
  expect_error(simulation(d, st2, event_col = "ev", event_weight = c("wA", "wA")), "benannt")
})

test_that("R1-23: Plausibilitaetspruefungen", {
  d <- .bt_cal("2020-01-01", "2021-02-03"); d$A <- seq(100, 200, length.out = nrow(d))
  st <- create_strategy(A = asset_config("certificate", asset_share = 1, asset_spread = 0))
  expect_warning(simulation(d, st, church_tax = 0.09), "Prozent")
  expect_error(simulation(d, st, church_tax = -9), "church_tax")
  expect_error(simulation(d, st, church_tax = "9"), "church_tax")
  expect_warning(simulation(d, st, church_tax = 100), "ungew\u00f6hnlich")
  expect_warning(simulation(d, st, tax_rate = 0.26375), "Prozent")
  expect_warning(asset_config("etf", asset_bonus = 0.3), "Prozent")
  expect_error(asset_config("etf", asset_share = "0.5"), "asset_share")
  expect_error(asset_config("etf", asset_start = "kein Datum"), "kein Datum")
  expect_s3_class(asset_config("etf", asset_start = "2020-01-01")$asset_start, "Date")
  expect_error(simulation(d, st, dca_mode = TRUE, dca_value = 100, dca_span = 1, dca_days = 40), "dca_days")
  expect_error(simulation(d, st, dca_mode = TRUE, dca_value = 100, dca_span = 1, dca_days = 0), "dca_days")
  expect_error(simulation(d, st, order_fee = list(fix = 5)), "fix")
  d0 <- d; d0$A <- 100
  expect_warning(simulation(d0, st, start_value = 100, order_fee = 60, liquidate = TRUE), "nicht verkauft")
  expect_warning(simulation(d, st, harvest_mode = TRUE), "harvest_mode")
  d$ev <- FALSE; d$ev[100] <- TRUE; d$wN <- -1; d$B <- 100
  st2 <- create_strategy(A = asset_config("etf", asset_share = .5), B = asset_config("etf", asset_share = .5))
  expect_error(simulation(d, st2, event_col = "ev", event_weight = c(A = "wN", B = "wN")), "nicht negative")
})

test_that("R1-24: dca_anchor = 'end' laesst nicht existierende Tage entfallen", {
  d <- .bt_cal("2020-01-01", "2020-12-31", A = 100)
  r <- simulation(d, .bt_st1(), dca_mode = TRUE, dca_value = 100, dca_span = 1, dca_days = 31, dca_anchor = "end")
  dts <- r$dates[r$report$A$flows > 0]
  expect_equal(format(dts, "%m-%d"), c("01-01", "03-01", "05-01", "07-01", "08-01", "10-01", "12-01"))
  r29 <- simulation(d, .bt_st1(), dca_mode = TRUE, dca_value = 100, dca_span = 1, dca_days = 29, dca_anchor = "end")
  expect_equal(sum(r29$report$A$flows > 0), 12)   # 2020: Februar hat 29 Tage
})

test_that("R1-25: update_asset leitet tax_regime neu ab, wenn es abgeleitet war", {
  s <- update_asset(create_strategy(X = asset_config("certificate")), "X", asset_class = "etf", asset_bonus = 30)
  expect_equal(s$X$tax_regime, "investment_fund")
  s <- update_asset(create_strategy(G = asset_config("etc")), "G", deliverable = TRUE)
  expect_equal(s$G$tax_regime, "private_sale")
  s <- update_asset(create_strategy(E = asset_config("etf", tax_regime = "capital_gains")), "E", deliverable = TRUE)
  expect_equal(s$E$tax_regime, "capital_gains")   # explizit gesetzt: bleibt
})

test_that("R1-26: simulation(spread = ) warnt", {
  d <- .bt_cal("2020-01-01", "2020-03-01", A = 100)
  expect_warning(simulation(d, .bt_st1(), spread = 5), "spread")
})

test_that("R1-28: Kochbuch-Code liegt nicht mehr im Namensraum", {
  expect_false(any(c("df", "trigger_abs_leverage", "trigger_rel_leverage", "trigger_vol_band") %in% ls(asNamespace("SimLev"))))
  f <- system.file("examples", "rebal_trigger_cookbook.R", package = "SimLev")
  expect_true(nzchar(f))
  e <- new.env(); invisible(capture.output(sys.source(f, envir = e)))
  expect_true(is.function(e$trigger_vol_band))
})
