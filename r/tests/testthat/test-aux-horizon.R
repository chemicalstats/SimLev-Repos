# Tests: withdrawal_rule() ohne horizon, Kennzeichen aux_type fuer Zusatzreihen in bootstrap_config()

test_that("withdrawal_rule: Argument horizon entfernt, Parametervektor passt zum C++-Kern", {
  expect_error(withdrawal_rule("one_over_n", horizon = 30), "unbenutzt|unused argument")
  expect_false("horizon" %in% names(formals(withdrawal_rule)))
  expect_null(withdrawal_rule("abw")$horizon)
  expect_length(SimLev:::.wd_param_vector(withdrawal_rule("constant")), 22L)
  # Restjahre aus der Zahl der Planjahre: 1/N leert das Depot planmaessig
  ws <- withdrawal_simulation(matrix(1, 10, 2), withdrawal_rule("one_over_n"), start_value = 1000)
  expect_equal(ws$planned[, 1], rep(100, 10))
  expect_equal(ws$paths$terminal_real, c(0, 0))
  # withdrawal_simulation(horizon =) bleibt unveraendert
  set.seed(1); R <- matrix(exp(rnorm(30 * 20, 0.04, 0.15)), 30)
  wh <- withdrawal_simulation(R, withdrawal_rule("hebeler"), horizon = 20)
  expect_equal(unique(wh$paths$horizon), 20L)
  expect_equal(wh$planned, withdrawal_simulation(R, withdrawal_rule("hebeler"))$planned)
})

# Monatsdaten als Kursniveaus: CPI +2 % p. a. (Niveau), zins = Zeilennummer (Rate), infl = 2 (Rate in Prozent p. a.)
.aux_data <- function(n = 600) {
  set.seed(11)
  data.frame(us = 100 * cumprod(c(1, 1 + rnorm(n, 0.005, 0.04))), cpi = 100 * 1.02^((0:n) / 12),
             zins = seq_len(n + 1), infl = 2)
}
.aux_dates <- function(n = 600) seq.Date(as.Date("2000-01-01"), by = "month", length.out = n + 1)

test_that("aux_type 'level': CPI +2 % p. a. ergibt auf allen Verfahren jede Jahresinflation 1,02", {
  d <- .aux_data(); dts <- .aux_dates()
  cfg <- bootstrap_config(c(us = "us"), aux = c(cpi = "cpi", zins = "zins", infl = "infl"), input = "prices",
                          aux_type = c(cpi = "level", zins = "rate", infl = "rate"))
  cfg0 <- bootstrap_config(c(us = "us"), aux = c(cpi = "cpi", zins = "zins", infl = "infl"), input = "prices")
  meth <- c("raw", "block", "circular", "stationary", "wild", "regime", "evt", "tails", "reset", "garch", "gjr_garch")
  for (m in meth) {
    b <- suppressWarnings(suppressMessages(bootstrap(d, cfg, m, n = 3, path_length = 600, seed = 2, progress = FALSE)))
    b0 <- suppressWarnings(suppressMessages(bootstrap(d, cfg0, m, n = 3, path_length = 600, seed = 2, progress = FALSE)))
    wp <- withdrawal_paths(b, column = "us", inflation = "cpi", frequency = "year", dates = dts)
    expect_equal(dim(wp$inflation), c(50L, 3L), info = m)
    expect_true(all(abs(wp$inflation - 1.02) < 1e-12), info = m)           # ohne inflation_type
    for (k in seq_along(b$paths)) {
      P <- b$paths[[k]]; P0 <- b0$paths[[k]]
      # Pfadspalte = kumuliertes Niveau ab dem Startwert der Historie, keine Spruenge
      expect_equal(unname(P[, "cpi"]), 100 * 1.02^((0:600) / 12), tolerance = 1e-12, info = m)
      expect_equal(unname(P[, "cpi"]), unname(attr(P, "aux_level")[, "cpi"]), info = m)
      # Rate-Spalten und Indizes unveraendert gegenueber der Konfiguration ohne aux_type
      expect_identical(P[, c("us", "zins", "infl")], P0[, c("us", "zins", "infl")], info = m)
    }
  }
  # chronologische Verfahren: Niveau = historische Reihe
  bw <- bootstrap(d, cfg, "wild", n = 1, seed = 1, progress = FALSE)
  expect_equal(unname(bw$paths[[1]][, "cpi"]), d$cpi, tolerance = 1e-12)
  expect_equal(unname(bw$paths[[1]][, "zins"]), c(2, 2:601))
})

test_that("aux_type 'rate': Werte der gezogenen Zeilen unver\u00e4ndert, Inflation als Rate p. a.", {
  d <- .aux_data(); dts <- .aux_dates()
  cfg <- bootstrap_config(c(us = "us"), aux = c(cpi = "cpi", zins = "zins", infl = "infl"), input = "prices",
                          aux_type = c(cpi = "level", zins = "rate", infl = "rate"))
  b <- bootstrap(d, cfg, "stationary", n = 4, params = list(L = 24), path_length = 600, seed = 3, progress = FALSE)
  for (P in b$paths) {
    z <- P[-1, "zins"]                                # Datenzeile der gezogenen Rendite
    expect_equal(unname(P[-1, "us"] / P[-nrow(P), "us"]), d$us[z] / d$us[z - 1], tolerance = 1e-12)
    expect_equal(unname(P[, "infl"]), rep(2, 601))
  }
  wr <- withdrawal_paths(b, column = "us", inflation = "infl", frequency = "year", dates = dts)
  ref <- withdrawal_paths(b, column = "us", inflation = "infl", inflation_type = "rate_pa", frequency = "year", dates = dts)
  expect_identical(wr$inflation, ref$inflation)
  expect_true(all(abs(wr$inflation - 1.02) < 1e-3))
  # inflation_type muss zu aux_type passen
  expect_error(withdrawal_paths(b, column = "us", inflation = "cpi", inflation_type = "rate_pa", dates = dts),
               "passt nicht zu aux_type\\['cpi'\\] = 'level'")
  expect_error(withdrawal_paths(b, column = "us", inflation = "infl", inflation_type = "level", dates = dts),
               "passt nicht zu aux_type\\['infl'\\] = 'rate'")
  expect_silent(withdrawal_paths(b, column = "us", inflation = "cpi", inflation_type = "level", dates = dts))
})

test_that("bootstrap_data liefert den kumulierten CPI, simulation() laeuft darauf", {
  d <- .aux_data()
  cfg <- bootstrap_config(c(us = "us"), aux = c(cpi = "cpi", zins = "zins"), input = "prices", aux_type = c(cpi = "level"))
  expect_equal(cfg$aux_type, c(cpi = "level", zins = "rate"))
  b <- bootstrap(d, cfg, "block", n = 2, params = list(block_length = 12), path_length = 240, seed = 5, progress = FALSE)
  x <- bootstrap_data(b, 2, dates = .aux_dates(240))
  expect_equal(x$cpi, 100 * 1.02^((0:240) / 12), tolerance = 1e-12)
  expect_true(all(x$zins %in% d$zins))
  # ohne aux_type: Originalwerte (springen an Blockgrenzen)
  b0 <- bootstrap(d, bootstrap_config(c(us = "us"), aux = c(cpi = "cpi", zins = "zins"), input = "prices"), "block", n = 2,
                  params = list(block_length = 12), path_length = 240, seed = 5, progress = FALSE)
  expect_true(all(bootstrap_data(b0, 2)$cpi %in% d$cpi))
  res <- suppressMessages(suppressWarnings(simulation(x, create_strategy(us = asset_config("etf", "bnh")))))
  expect_s3_class(res, "SimLevResult")
})

test_that("bootstrap_study(keep_aux) folgt aux_type", {
  d <- .aux_data(); dts <- .aux_dates()
  cfg <- bootstrap_config(c(us = "us"), aux = c(cpi = "cpi", zins = "zins", infl = "infl"), input = "prices",
                          aux_type = c(cpi = "level", infl = "rate"))
  st <- expect_silent(bootstrap_study(d, cfg, "stationary", n = 3, params = list(L = 24), path_length = 600, dates = dts,
    seed = 1, progress = FALSE, keep_returns = "year", keep_aux = c("cpi", "infl"),
    strategies = list(bnh = create_strategy(us = asset_config("etf", "bnh")))))
  expect_true(all(abs(st$aux_returns$cpi - 1.02) < 1e-12))
  # Rate: ueber die Kalendertage aufgezinst wie inflation_type = "rate_pa"
  expect_equal(st$aux_returns$infl, matrix((1.02)^(as.numeric(diff(st$returns_dates)) / 365.25), 50, 3), tolerance = 1e-12)
  expect_true(all(abs(withdrawal_paths(st, inflation = "infl")$inflation - 1.02) < 1e-3))
  expect_error(withdrawal_paths(st, inflation = "cpi", inflation_type = "rate_pa"), "passt nicht zu aux_type")
  ws <- withdrawal_simulation(st, withdrawal_rule("constant"), inflation = "cpi")
  expect_equal(nrow(ws$paths), 3L)
})

test_that("aux_type: Validierung", {
  expect_error(bootstrap_config(c(us = "us"), aux = c(cpi = "cpi"), aux_type = c(cp = "level")),
               "'cp' ist keine Zusatzreihe aus aux \\(verf\u00fcgbar: cpi\\)")
  expect_error(bootstrap_config(c(us = "us"), aux_type = c(cpi = "level")), "verf\u00fcgbar: keine")
  expect_error(bootstrap_config(c(us = "us"), aux = c(cpi = "cpi"), aux_type = c(cpi = "niveau")),
               "aux_type\\['cpi'\\] = 'niveau': erlaubt sind nur 'level'")
  expect_error(bootstrap_config(c(us = "us"), aux = c(cpi = "cpi"), aux_type = "level"), "benannter Zeichenvektor")
  expect_error(bootstrap_config(c(us = "us"), aux = c(cpi = "cpi"), aux_type = c(cpi = "level", cpi = "rate")), "doppelt")
  expect_error(bootstrap_config(c(us = "us"), aux = c(z = "z"), aux_type = c(z = "level"),
                                letfs = list(list(base = "us", finance = "z"))), "finance-Reihe 'z' ist in aux_type als 'level'")
  d <- .aux_data(100)
  d$cpi[40] <- -1
  cfg <- bootstrap_config(c(us = "us"), aux = c(cpi = "cpi"), input = "prices", aux_type = c(cpi = "level"))
  expect_error(bootstrap(d, cfg, "raw", n = 1, seed = 1, progress = FALSE),
               "'cpi' \\(Spalte 'cpi'\\) ist als 'level' gekennzeichnet und muss positiv und endlich sein; Zeile 40 von data hat den Wert -1")
  d$cpi[40] <- Inf
  expect_error(bootstrap(d, cfg, "raw", n = 1, seed = 1, progress = FALSE), "Zeile 40 von data hat den Wert Inf")
  d$cpi[40] <- 0
  expect_error(bootstrap_study(d, cfg, "raw", n = 1, seed = 1, progress = FALSE,
                               strategies = list(b = create_strategy(us = asset_config("etf", "bnh")))), "Zeile 40")
  # Rate-Spalten duerfen 0 und negativ sein
  d$cpi[40] <- 0
  expect_s3_class(bootstrap(d, bootstrap_config(c(us = "us"), aux = c(cpi = "cpi"), input = "prices", aux_type = c(cpi = "rate")),
                            "raw", n = 1, seed = 1, progress = FALSE), "bootstrap_result")
  expect_output(print(bootstrap_config(c(us = "us"), aux = c(cpi = "eu_cpi", z = "z"), aux_type = c(cpi = "level"))),
                "cpi=eu_cpi \\(level\\), z=z$")
})

test_that("aux_type: Konfigurationen ohne die neuen Felder verhalten sich wie bisher", {
  d <- .aux_data(300)
  cfg <- bootstrap_config(c(us = "us"), aux = c(cpi = "cpi"), input = "prices")
  old <- cfg; old$aux_type <- NULL; old$aux_type_set <- NULL
  b <- bootstrap(d, cfg, "stationary", n = 2, params = list(L = 20), seed = 4, progress = FALSE)
  bo <- bootstrap(d, old, "stationary", n = 2, params = list(L = 20), seed = 4, progress = FALSE)
  expect_identical(b$paths, bo$paths)
  expect_true(all(b$paths[[1]][, "cpi"] %in% d$cpi))                       # Originalwerte
  expect_equal(withdrawal_paths(b, column = "us", inflation = "cpi", dates = .aux_dates(300))$inflation,
               withdrawal_paths(bo, column = "us", inflation = "cpi", dates = .aux_dates(300))$inflation)
})
