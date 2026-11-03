# test-pruefungen.R
# Prüfungen und Wege des R-Pakets, die die Referenzfälle tests/<gruppe>/faelle nicht erreichen (Zeilenabdeckung mit
# covr gegen alle Generatoren): Eingabeprüfungen von create_strategy/strategy_*/asset_config/tax_profile,
# Umwandlungen und Aufruf (conditionCall) der Meldungen von simulation(), risk_free als Spalte, rebalance_trigger mit führendem NA, summary einer Strategie,
# scenario_copula unter Stress, dependence_validate, Prozent-Warnungen. Die Blöcke stammen wörtlich aus den
# Testdateien bis 1.4.0 (je Quelle mit ihren Hilfsdefinitionen in local()).
testthat::local_edition(3)   # Edition 3 wie bisher (Config/testthat/edition in r/DESCRIPTION entfällt)

# ── aus test-blue-engine.R (3 Blöcke) ──
local({
.bt_cal <- function(from, to, ...) {
  dd <- seq.Date(as.Date(from), as.Date(to), by = "day"); data.frame(date = dd, ...)
}
.bt_st1 <- function(...) create_strategy(A = asset_config("etf", share = 1, spread = 0, ...))

test_that("rebalance_trigger mit fuehrendem NA", {
  df <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 6),
                   target_leverage = c(NA, 2, 2.3, 2.3, 1.9, 2), sigma_ewma = c(NA, NA, .1, .2, .1, .1))
  expect_equal(rebalance_trigger(df, "abs_leverage")$rebal_trigger, c(FALSE, FALSE, TRUE, FALSE, TRUE, TRUE))
  expect_equal(rebalance_trigger(df, "vol_band")$rebal_trigger, c(FALSE, FALSE, FALSE, TRUE, TRUE, FALSE))
  expect_false(any(rebalance_trigger(transform(df, sigma_ewma = NA_real_), "vol_band")$rebal_trigger))
})

test_that("verstaendliche Fehler und Umwandlungen", {
  set.seed(4); n <- 400
  d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n), A = 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)))
  ref <- simulation(d, .bt_st1())
  dc <- d; dc$date <- as.character(dc$date)
  expect_message(r <- simulation(dc, .bt_st1()), "Text"); expect_identical(r$worth, ref$worth)
  df <- d; df$date <- factor(df$date); expect_identical(suppressMessages(simulation(df, .bt_st1()))$worth, ref$worth)
  dx <- d; dx$date <- format(dx$date, "%d.%m.%Y"); expect_error(simulation(dx, .bt_st1()), "JJJJ-MM-TT")
  if (requireNamespace("tibble", quietly = TRUE)) expect_identical(simulation(tibble::as_tibble(d), .bt_st1())$worth, ref$worth)
  expect_error(simulation(d, create_strategy(Z = asset_config("etf"))), "Kursspalte 'Z' fehlt")
  expect_error(simulation(d, .bt_st1(), dca = dca_plan(value = 1, span = 1, start = "2025-01-01")), "nach dem letzten Datentag")
  expect_error(create_strategy(A = asset_config("etf", share = .5), A = asset_config("etf", share = .5)), "mehrfach")
  expect_error(simulation(d, list(A = list(asset_class = "etf", trading = "bnh", share = .5),
                                  A = list(asset_class = "etf", trading = "bnh", share = .5))), "mehrfach")
  expect_error(simulation(d, .bt_st1(start = as.Date("2020-06-01"))), "Kein Asset")
  d$B <- 100; d$ev <- FALSE; d$ev[100] <- TRUE; d$wA <- .5; d$wN <- -1
  st2 <- create_strategy(A = asset_config("etf", share = .5), B = asset_config("etf", share = .5))
  expect_warning(simulation(d, st2, rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(A = "wA"))), "nicht alle Assets")
  expect_error(simulation(d, st2, rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(A = "wA", B = "xx"))), "'xx'")
  expect_error(simulation(d, st2, rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c("wA", "wA"))), "benannt")
})

test_that("Plausibilitaetspruefungen", {
  d <- .bt_cal("2020-01-01", "2021-02-03"); d$A <- seq(100, 200, length.out = nrow(d))
  st <- create_strategy(A = asset_config("certificate", share = 1, spread = 0))
  expect_warning(tax_profile(church_tax = 0.09), "Prozent")
  expect_error(tax_profile(church_tax = -9), "church_tax")
  expect_error(tax_profile(church_tax = "9"), "church_tax")
  expect_warning(tax_profile(church_tax = 100), "ungew\u00f6hnlich")
  expect_warning(tax_profile(rate = 0.26375), "Prozent")
  expect_warning(asset_config("etf", partial_exemption = 0.3), "Prozent")
  expect_error(asset_config("etf", share = "0.5"), "share")
  expect_error(asset_config("etf", start = "kein Datum"), "kein Datum")
  expect_s3_class(asset_config("etf", start = "2020-01-01")$start, "Date")
  expect_error(dca_plan(value = 100, span = 1, days = 40), "dca_plan: days")
  expect_error(dca_plan(value = 100, span = 1, days = 0), "dca_plan: days")
  expect_error(sim_costs(order_fee = list(fix = 5)), "fix")
  d0 <- d; d0$A <- 100
  expect_warning(simulation(d0, st, start_value = 100, costs = sim_costs(order_fee = 60), liquidate = TRUE), "nicht verkauft")
  expect_error(harvest_rule(day = "1231"), "MM-TT")
  d$ev <- FALSE; d$ev[100] <- TRUE; d$wN <- -1; d$B <- 100
  st2 <- create_strategy(A = asset_config("etf", share = .5), B = asset_config("etf", share = .5))
  expect_error(simulation(d, st2, rebalance = rebalance_plan(event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(A = "wN", B = "wN"))), "nicht negative")
})
})

# ── aus test-strategy.R (7 Blöcke) ──
local({

test_that("create_strategy rejects empty input", {
  expect_error(create_strategy(), "mindestens eine Asset-Konfiguration")
})

test_that("create_strategy rejects unnamed assets", {
  expect_error(
    create_strategy(asset_config()),
    "alle Assets m\u00fcssen benannt sein"
  )
})

test_that("strategy_validate checks data columns", {
  strat <- create_strategy(
    ETF = asset_config(asset_class = "etf")
  )
  
  good_data <- data.frame(
    date = as.Date("2024-01-01"),
    ETF = 100
  )
  
  expect_true(strategy_validate(strat, good_data))
  
  bad_data <- data.frame(
    date = as.Date("2024-01-01"),
    Other = 100
  )
  
  expect_error(
    strategy_validate(strat, bad_data),
    "Kursspalte\\(n\\) 'ETF' fehlen in data"
  )
})

test_that("strategy_validate checks signal columns", {
  strat <- create_strategy(
    ETF = asset_config(
      trading = "signal",
      signal_buy = "buy_signal",
      signal_sell = "sell_signal"
    )
  )
  
  good_data <- data.frame(
    date = as.Date("2024-01-01"),
    ETF = 100,
    buy_signal = TRUE,
    sell_signal = FALSE
  )
  
  expect_true(strategy_validate(strat, good_data))
  
  bad_data <- data.frame(
    date = as.Date("2024-01-01"),
    ETF = 100
  )
  
  expect_error(
    strategy_validate(strat, bad_data),
    "signal_buy-Spalte 'buy_signal' fehlt in data"
  )
})

test_that("strategy_remove_asset warns on empty strategy", {
  strat <- create_strategy(ETF = asset_config())
  
  expect_warning(
    strategy_remove_asset(strat, "ETF"),
    "keine Assets mehr"
  )
})

test_that("strategy_update_asset rejects unknown asset", {
  strat <- create_strategy(ETF = asset_config())
  
  expect_error(
    strategy_update_asset(strat, "Unknown", share = 0.5),
    "Asset 'Unknown' ist nicht in der Strategie"
  )
})

test_that("summary.strategy shows allocation", {
  strat <- create_strategy(
    ETF = asset_config(share = 0.7),
    Gold = asset_config(share = 0.3, asset_class = "etc")
  )
  
  expect_output(summary(strat), "Gesamtgewicht: 100")
})
})

# ── aus test-asset_config.R (4 Blöcke) ──
local({

test_that("backward compatibility for etn_deliverable", {
  expect_warning({
    cfg <- asset_config(asset_class = "etn_deliverable")
  }, "asset_class = \"etn_deliverable\" ist veraltet")
  
  expect_equal(cfg$asset_class, "etn")
  expect_true(cfg$deliverable)
  expect_equal(cfg$tax_regime, "private_sale")
})

test_that("backward compatibility for etn_standard", {
  expect_warning({
    cfg <- asset_config(asset_class = "etn_standard")
  }, "asset_class = \"etn_standard\" ist veraltet")
  
  expect_equal(cfg$asset_class, "etn")
  expect_false(cfg$deliverable)
  expect_equal(cfg$tax_regime, "capital_gains")
})

test_that("share validation", {
  expect_error(
    asset_config(share = 0),
    "share muss ein Anteil gr\u00f6\u00dfer 0 und h\u00f6chstens 1 sein .*nicht 0\\."
  )
  
  expect_error(
    asset_config(share = 1.5),
    "share muss ein Anteil gr\u00f6\u00dfer 0 und h\u00f6chstens 1 sein .*nicht 1.5; f\u00fcr 1.5 % share = 0.015 angeben"
  )
  
  expect_error(
    asset_config(share = -0.1),
    "share muss ein Anteil gr\u00f6\u00dfer 0 und h\u00f6chstens 1 sein .*nicht -0.1\\."
  )
})

test_that("invalid tax_regime is rejected", {
  expect_error(
    asset_config(tax_regime = "invalid"),
    "tax_regime = \"invalid\" ist ung\u00fcltig"
  )
})
})

# ── aus test-simulation.R (2 Blöcke) ──
local({
library(testthat)
library(SimLev)
create_test_data <- function(n_days = 100, seed = 42) {
  set.seed(seed)
  data.frame(
    date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n_days),
    ETF = 100 * cumprod(1 + rnorm(n_days, 0.001, 0.02))
  )
}
create_test_strategy <- function() {
  list(
    ETF = list(
      asset_class = "etf",
      trading = "bnh",
      share = 1.0,
      spread = 0.1,
      partial_exemption = 0,
      signal_buy = NULL,
      signal_sell = NULL
    )
  )
}
create_gapped_data <- function(seed = 99) {
  set.seed(seed)
  # Nur Handelstage (Mo-Fr) -> Wochenenden fehlen -> werden per LOCF aufgefuellt
  all <- seq.Date(as.Date("2021-01-04"), as.Date("2021-12-31"), by = "day")
  wd  <- all[as.integer(format(all, "%u")) <= 5]
  data.frame(
    date = wd,
    ETF  = 100 * cumprod(1 + rnorm(length(wd), 4e-4, 0.011))
  )
}
create_rf_data <- function(seed = 77) {
  set.seed(seed)
  all <- seq.Date(as.Date("2022-01-01"), as.Date("2022-12-31"), by = "day")
  wd  <- all[as.integer(format(all, "%u")) <= 5]
  data.frame(
    date = wd,
    ETF  = 100 * cumprod(1 + rnorm(length(wd), 3e-4, 0.011)),
    sofr = seq(1, 4, length.out = length(wd))   # Prozent (wie SOFR 5.31), nicht Anteil
  )
}
create_pulse_data <- function(buy_on, sell_on = NULL, seed = 2, n = 120) {
  set.seed(seed)
  d <- data.frame(date = seq.Date(as.Date("2022-01-03"), by = "day", length.out = n),
                  SIG  = 100 * cumprod(1 + rnorm(n, 4e-4, 0.01)))
  d$buy_sig  <- d$date %in% as.Date(buy_on)
  d$sell_sig <- if (is.null(sell_on)) FALSE else d$date %in% as.Date(sell_on)
  d
}
signal_strategy <- function() create_strategy(
  SIG = asset_config("etf", trading = "signal", share = 1,
                     spread = 0, partial_exemption = 30,
                     signal_buy = "buy_sig", signal_sell = "sell_sig"))
create_vp_data <- function() {
  all <- seq.Date(as.Date("2022-01-01"), as.Date("2023-01-31"), by = "day")
  wd  <- all[as.integer(format(all, "%u")) <= 5]      # 31.12.2022 = Samstag!
  set.seed(9)
  d <- data.frame(date = wd, ETF = 100 * cumprod(1 + rnorm(length(wd), 8e-4, 0.008)))
  d$base_rate <- 2.55                                  # Prozent (2,55 %)
  d
}
vp_strategy <- function() create_strategy(
  ETF = asset_config("etf", trading = "bnh", share = 1,
                     spread = 0, partial_exemption = 30))
r1_data <- function() {
  set.seed(1); n <- 200
  data.frame(date = seq.Date(as.Date("2022-01-03"), by = "day", length.out = n),
             A = 100 * cumprod(1 + rnorm(n, 15e-4, 0.01)),
             B = 100 * cumprod(1 + rnorm(n, -2e-4, 0.004)))
}
r1_strategy <- function() create_strategy(
  A = asset_config("etf", "bnh", share = 0.7, spread = 0, partial_exemption = 30),
  B = asset_config("etf", "bnh", share = 0.3, spread = 0, partial_exemption = 30))

test_that("risk_free = NULL and risk_free = 0 are identical", {
  data     <- create_rf_data()
  strategy <- create_test_strategy()
  r_null <- simulation(data, strategy, start_value = 10000, risk_free = NULL)
  r_zero <- simulation(data, strategy, start_value = 10000, risk_free = 0)

  expect_equal(r_null$statistics$sharpe,  r_zero$statistics$sharpe)
  expect_equal(r_null$statistics$sortino, r_zero$statistics$sortino)
})

test_that("risk_free column missing from data raises error", {
  data     <- create_rf_data()
  strategy <- create_test_strategy()
  expect_error(
    simulation(data, strategy, start_value = 10000, risk_free = "nonexistent"),
    "Spalte 'nonexistent' fehlt"
  )
})
})

# ── aus test-refactor.R (1 Blöcke) ──
local({
library(testthat)
library(SimLev)
.rf_data <- function(n = 400) {
  cal <- seq(as.Date("2020-01-01"), by = "day", length.out = n)
  data.frame(date = cal, A = 100 + seq_len(n) / 10, B = 50 + sin(seq_len(n) / 20))
}
.rf_strategy <- function() {
  list(A = list(asset_class = "etf", trading = "bnh", share = 0.5, spread = 0.1),
       B = list(asset_class = "etc", trading = "bnh", share = 0.5, spread = 0.1, deliverable = TRUE))
}
.rf_warnings <- function(expr) {
  w <- list()
  withCallingHandlers(expr, warning = function(x) { w[[length(w) + 1L]] <<- x; invokeRestart("muffleWarning") })
  w
}

test_that("Fehler und Warnungen aus den Phasen tragen den Aufruf von simulation()", {
  d <- .rf_data(); s <- .rf_strategy()
  e <- tryCatch(simulation(d, s, start_value = -1), error = identity)              # .sim_check_inputs
  expect_identical(conditionCall(e), quote(simulation(d, s, start_value = -1)))
  e <- tryCatch(simulation(d, s, risk_free = "fehlt"), error = identity)           # .sim_risk_stats
  expect_identical(conditionCall(e), quote(simulation(d, s, risk_free = "fehlt")))
  expect_identical(conditionMessage(e), "risk_free: Spalte 'fehlt' fehlt im Datensatz.")
  e <- tryCatch(rebalance_plan(thresh_type = "Prozent"), error = identity)        # match.arg im Baustein
  expect_identical(conditionCall(e), quote(match.arg(thresh_type)))

  sp <- create_strategy(A = asset_config("etc", "bnh", share = 1, deliverable = TRUE))
  w <- .rf_warnings(simulation(d, sp, tax = tax_profile()))
  expect_length(w, 1L)
  expect_match(conditionMessage(w[[1]]), "Grenzsteuersatz ist nicht gesetzt", fixed = TRUE)
  expect_identical(conditionCall(w[[1]]), quote(simulation(d, sp, tax = tax_profile())))
  w <- .rf_warnings(simulation(d, s, risk_free = 0.01))                          # call. = FALSE: ohne Aufruf
  expect_length(w, 1L)
  expect_null(conditionCall(w[[1]]))
  # Abbrueche und Warnungen aus dem Kern (seit 1.4.1) tragen den Aufruf von simulation() (bis 1.3.0 den der Phase)
  dz <- data.frame(date = as.Date(c("2020-01-01", "2020-01-02")), A = c(1e300, 1e-30))
  sz <- create_strategy(A = asset_config("etf", "bnh", 1))
  e <- tryCatch(suppressWarnings(simulation(dz, sz, splits = split_rule(thresh = c(-50, -10)))), error = identity)
  expect_identical(conditionMessage(e), "perform_asset_split: ratio muss > 0 sein (Split-Verhältnis), nicht 0.")
  expect_identical(conditionCall(e), quote(simulation(dz, sz, splits = split_rule(thresh = c(-50, -10)))))
})
})

# ── aus test-review7-engine.R (1 Blöcke) ──
local({
.r7_days <- function(a, b) seq.Date(as.Date(a), as.Date(b), by = "day")
.r7_sim <- function(...) suppressWarnings(suppressMessages(simulation(...)))
.r7_out <- function(...) { out <- utils::capture.output(r <- .r7_sim(..., details = TRUE)); list(r = r, out = out) }

test_that("C7-01: Listen-Strategien mit ungueltigem Regime/Klasse/Handelsart -> Fehler; Cookbook gueltig", {
  d <- data.frame(date = .r7_days("2020-01-01", "2020-03-31"), A = 100)
  mk <- function(...) list(A = modifyList(list(asset_class = "etf", trading = "bnh", share = 1, spread = 0), list(...)))
  expect_error(simulation(d, mk(tax_regime = "none"), tax = tax_profile()), "tax_regime \"none\" von Asset 'A' ist ung\u00fcltig")
  expect_error(simulation(d, mk(tax_regime = "fund")), "tax_regime \"fund\"")
  expect_error(simulation(d, mk(asset_class = "eft")), "asset_class \"eft\" von Asset 'A' ist ung\u00fcltig")
  expect_error(simulation(d, mk(trading = "hold")), "trading \"hold\"")
  expect_s3_class(simulation(d, mk(tax_regime = "capital_gains"), tax = tax_profile()), "SimLevResult")
  cb <- readLines(system.file("examples", "rebal_trigger_cookbook.R", package = "SimLev"))
  expect_false(any(grepl("tax_regime = \"none\"", cb, fixed = TRUE)))
  expect_true(any(grepl("create_strategy(", cb, fixed = TRUE)))
})
})

# ── aus test-wrapper.R (1 Blöcke) ──
local({
.wr_data <- function(n = 500, seed = 7) {
  set.seed(seed)
  d <- data.frame(date = seq.Date(as.Date("2019-11-01"), by = "day", length.out = n))
  d$A <- 100 * cumprod(1 + rnorm(n, 4e-4, 0.011)); d$B <- 50 * cumprod(1 + rnorm(n, 1e-4, 0.004))
  d$C <- 80 * cumprod(1 + rnorm(n, 2e-4, 0.006))
  d
}
.wr_inner <- function() create_strategy(A = asset_config("etf", "bnh", 0.6), B = asset_config("etf", "bnh", 0.4))

test_that("strategy_from_weights und portfolio_template mit wrapper je Asset", {
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
})

# ── aus test-blue-stats.R (1 Blöcke) ──
local({
.bs_prices <- function(n = 3 * 365, seed = 1, start = "2015-01-01") {
  set.seed(seed)
  d <- data.frame(date = seq.Date(as.Date(start), by = "day", length.out = n))
  d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)); d$anleihen <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.003))
  d
}
.bs_R <- function() {
  set.seed(1); R <- matrix(rnorm(520 * 3, c(0.002, 0.001, 0.0005), c(0.03, 0.02, 0.01)), 520, byrow = TRUE)
  colnames(R) <- c("aktien", "reits", "anleihen"); R
}

test_that("scenario_copula: Stress-Pruefung und gemeinsame bedingte Ziehung", {
  set.seed(1); z <- matrix(rnorm(3000), ncol = 3) %*% chol(matrix(c(1, .9, .5, .9, 1, .5, .5, .5, 1), 3))
  X <- data.frame(a = z[, 1], b = z[, 2], c = z[, 3])
  expect_error(scenario_copula(X, c("a", "b", "c"), n = 100, stress = list(c(0, 0.05))), "benannte Liste")
  expect_error(scenario_copula(X, c("a", "b", "c"), n = 100, stress = list(a = c(0.05, 0))), "0 <= von < bis <= 1")
  expect_error(scenario_copula(X, c("a", "b", "c"), n = 100, stress = list(a = c(0, 5))), "keine Prozent")
  cs <- scenario_copula(X, c("a", "b", "c"), n = 20000, family = "gaussian", stress = list(a = c(0, 0.1), b = c(0, 0.1)), seed = 1)
  # Referenz: Verwerfung aus derselben Gauss-Copula
  Rm <- cs$copula$correlation; set.seed(2); U <- pnorm(matrix(rnorm(3e6), ncol = 3) %*% chol(Rm))
  U <- U[U[, 1] <= 0.1 & U[, 2] <= 0.1, ]
  qm <- function(j, u) approx((seq_len(1000) - 0.5) / 1000, sort(X[[j]]), u, rule = 2)$y   # empirische Raender wie im Paket
  expect_equal(cor(cs$scenarios$a, cs$scenarios$b), cor(qm("a", U[, 1]), qm("b", U[, 2])), tolerance = 0.06)
  expect_equal(mean(cs$scenarios$c), mean(qm("c", U[, 3])), tolerance = 0.03)
  expect_gt(cor(cs$scenarios$a, cs$scenarios$b), 0.4)              # vorher ~0 (unabhaengig gezogen)
  expect_true(all(cs$scenarios$a <= quantile(X$a, 0.1) + 1e-12))
})
})

# ── aus test-review9-engine.R (1 Blöcke) ──
local({
library(testthat)
library(SimLev)
.r9_warn <- function(expr) {
  w <- character()
  val <- withCallingHandlers(expr, warning = function(x) { w <<- c(w, conditionMessage(x)); invokeRestart("muffleWarning") })
  list(value = val, warnings = w)
}

test_that("Prozent-Warnung auch f\u00fcr risk_free- und Basiszins-Spalten (Median)", {
  set.seed(9); n <- 900
  d <- data.frame(date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = n), A = 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)))
  d$rf_anteil <- 0.025; d$br_anteil <- 0.0255; d$rf_proz <- 2.5; d$br_proz <- c(0.07, rep(2.55, n - 1)); d$rf_null <- 0
  s <- create_strategy(A = asset_config("etf", partial_exemption = 30))
  w <- .r9_warn(simulation(d, s, risk_free = "rf_anteil"))$warnings
  expect_length(w, 1L)
  expect_match(w, "risk_free-Spalte 'rf_anteil' hat den Median 0.025 und wird als 0.025 % gelesen", fixed = TRUE)
  w <- .r9_warn(simulation(d, s, start_value = 2e5, tax = tax_profile(base_rate = "br_anteil")))$warnings
  expect_length(w, 1L)
  expect_match(w, "base_rate-Spalte 'br_anteil' hat den Median 0.0255", fixed = TRUE)
  expect_length(.r9_warn(simulation(d, s, risk_free = "rf_proz"))$warnings, 0L)
  expect_length(.r9_warn(simulation(d, s, risk_free = "rf_null"))$warnings, 0L)
  expect_length(.r9_warn(simulation(d, s, start_value = 2e5, tax = tax_profile(base_rate = "br_proz")))$warnings, 0L)
})
})

# ── aus test-research.R (1 Blöcke) ──
local({
make_px <- function(n = 365 * 10, seed = 1, mu = 3e-4, sd = 0.011) {
  set.seed(seed)
  d <- data.frame(date = seq.Date(as.Date("2008-01-01"), by = "day", length.out = n))
  d$A <- 100 * cumprod(1 + rnorm(n, mu, sd))
  d
}

test_that("dependence_validate and regime_subset", {
  set.seed(4); n <- 2000
  e <- matrix(rnorm(2 * n), ncol = 2) %*% chol(matrix(c(1, .5, .5, 1), 2))
  h <- data.frame(us = exp(0.01 * e[, 1]), eu = exp(0.01 * e[, 2]), infl = rep(c(1, 5, 1), c(700, 600, 700)))
  cfg <- bootstrap_config(c(us = "us", eu = "eu"))
  b <- bootstrap(h, cfg, "stationary", n = 10, params = list(L = 20), seed = 1, progress = FALSE)
  vd <- dependence_validate(b, h, agg = 5, max_paths = 10)
  expect_equal(nrow(vd), 5L); expect_true(all(vd$percentile >= 0 & vd$percentile <= 1))
  s <- regime_subset(h, "infl >= 4", min_run = 50)
  expect_equal(nrow(s), 600L); expect_equal(attr(s, "episodes")$start, 701L)
  bs <- bootstrap(s, cfg, "stationary", n = 2, params = list(L = 20), seed = 1, progress = FALSE)
  expect_equal(nrow(bs$paths[[1]]), 601L)
  expect_error(regime_subset(h, "infl > 10"), "keine Episode")
})
})
