# Blue Team Runde 2 (blue6): Datumsumwandlung, Datenpruefung, Studien-Inflation,
# Quantilsregression an entarteten Ecken, Verkettung, rollierende Sharpe Ratio

test_that("R2b-01: POSIXct in lokaler Zeitzone ergibt dieselben Kalendertage wie Date", {
  set.seed(1); n <- 3 * 365; dt <- seq.Date(as.Date("2015-01-01"), by = "day", length.out = n)
  d <- data.frame(date = dt, aktien = 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)), anleihen = 100 * cumprod(1 + rnorm(n, 1e-4, 0.003)))
  dp <- d; dp$date <- as.POSIXct(format(dt), tz = "Europe/Berlin")
  expect_equal(portfolio_optimize(dp, frequency = "month")$weights, portfolio_optimize(d, frequency = "month")$weights)
  kr <- data.frame(crisis = "K", start = as.Date("2016-01-01"), end = as.Date("2016-06-30"))
  w <- c(aktien = 0.6, anleihen = 0.4)
  expect_equal(scenario_crisis(dp, w, kr), scenario_crisis(d, w, kr))              # vorher -0.73 statt -0.59 %
  kp <- kr; kp$start <- as.POSIXct("2016-01-01", tz = "Europe/Berlin"); kp$end <- as.POSIXct("2016-06-30", tz = "Europe/Berlin")
  expect_equal(scenario_crisis(d, w, kp), scenario_crisis(d, w, kr))
  cand <- list(a = c(aktien = 1), m = c(aktien = 0.5, anleihen = 0.5))
  expect_equal(portfolio_returns(dp, cand, "month"), portfolio_returns(d, cand, "month"))
  expect_equal(attr(series_shift_return(dp, "aktien", 5, "prices"), "shift"), attr(series_shift_return(d, "aktien", 5, "prices"), "shift"))
  expect_equal(withdrawal_cohorts(dp, "aktien", years = 1, frequency = "month")$start_dates,
               withdrawal_cohorts(d, "aktien", years = 1, frequency = "month")$start_dates)
})

test_that("R2b-02: ISO-Daten vor 1800 als Text, falsche Formate weiter abgelehnt", {
  dt <- seq.Date(as.Date("1791-01-31"), by = "month", length.out = 120)
  set.seed(2); v <- 100 * cumprod(1 + rnorm(120, 0.004, 0.03))
  a <- result_analysis(data.frame(date = format(dt), value = v))$metrics             # vorher Fehler
  expect_equal(a, result_analysis(data.frame(date = dt, value = v))$metrics)
  expect_equal(SimLev:::.to_date(c("1650-03-01", "1799/12/31")), as.Date(c("1650-03-01", "1799-12-31")))
  expect_error(SimLev:::.to_date("31-12-2024"), "nicht als 'JJJJ-MM-TT' lesbar")   # sonst Jahr 31
  expect_error(SimLev:::.to_date("24-12-31"), "nicht als 'JJJJ-MM-TT' lesbar")
  expect_true(is.na(SimLev:::.to_date("31-12-2024", strict = FALSE)))
})

test_that("R2b-03: series_check mit negativen Werten", {
  set.seed(1)
  d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 300))
  d$kurs <- 100 * cumprod(1 + rnorm(300, 3e-4, 0.01))
  d$zins <- c(seq(1, -0.5, length.out = 150), seq(-0.5, 2, length.out = 150))
  ch <- expect_silent(series_check(d))                                             # vorher R-Fehler
  expect_equal(ch$summary$nonpositive[ch$summary$column == "zins"], sum(d$zins <= 0))
  d$zins <- NULL; d$kurs[50] <- -1
  ch <- expect_silent(series_check(d))
  expect_equal(ch$issues$type, "Wert <= 0"); expect_equal(ch$summary$jumps, 0L)
})

test_that("R2b-04: keep_aux mit Ratenspalte wird erkannt", {
  set.seed(1); N <- 2000
  d <- data.frame(date = seq.Date(as.Date("1990-01-01"), by = "day", length.out = N), us = 100 * cumprod(1 + rnorm(N, 3e-4, 0.01)),
                  rate = c(seq(2, -0.5, length.out = 1000), seq(-0.5, 3, length.out = 1000)))
  cfg <- bootstrap_config(c(us = "us"), aux = c(rate = "rate"), input = "prices")
  expect_warning(st <- bootstrap_study(d, cfg, "stationary", n = 3, params = list(L = 50), path_length = 1500, seed = 1,
                                       progress = FALSE, keep_returns = "year", keep_aux = "rate",
                                       strategies = list(x = create_strategy(us = asset_config("etf", "bnh")))),
                 "kein positives Niveau")
  expect_error(withdrawal_simulation(st, withdrawal_rule("constant"), strategy = "x", inflation = "rate"), "kein positives Niveau")
  expect_silent(withdrawal_simulation(st, withdrawal_rule("constant"), strategy = "x", inflation = 2))
})

test_that("R2b-05: quantile_regression weist entartete Ecken bei diskreten Daten nach", {
  set.seed(4)
  n <- 3000; X <- matrix(sample(0:2, n * 3, TRUE), n); y <- sample(0:3, n, TRUE) + 0
  t <- system.time(b <- expect_silent(quantile_regression(y, X, 0.05)))[3]                # vorher Warnung, ~1 s
  expect_lt(t, 1)
  obj <- function(b, y, X) { r <- y - cbind(1, X) %*% b; sum(r * (0.05 - (r < 0))) }
  expect_equal(obj(b, y, X), 227.1, tolerance = 1e-10)                            # quantreg (br): 227.1
  # kleiner Fall gegen alle Ecken (Brute Force)
  for (s in 1:5) {
    set.seed(s); n <- 14; X <- matrix(sample(0:1, n * 2, TRUE), n); y <- sample(0:2, n, TRUE) + 0
    Z <- cbind(1, X); if (qr(Z)$rank < 3) next
    for (tau in c(0.1, 0.5, 0.8)) {
      b <- expect_silent(quantile_regression(y, X, tau))
      f <- function(b) { r <- y - Z %*% b; sum(r * (tau - (r < 0))) }
      best <- min(apply(utils::combn(n, 3), 2, function(h) {
        A <- Z[h, , drop = FALSE]; if (abs(det(A)) < 1e-12) return(Inf); f(solve(A, y[h])) }))
      expect_equal(f(b), best, tolerance = 1e-10)
    }
  }
})

test_that("R2b-06: series_splice behandelt Wochenenden nicht als Luecke", {
  set.seed(1)
  cal <- seq.Date(as.Date("2020-01-01"), by = "day", length.out = 120)
  idx <- data.frame(date = cal, value = 100 * cumprod(1 + rnorm(120, 0, 0.01)))
  etf <- idx[!format(cal, "%u") %in% c("6", "7") & cal >= as.Date("2020-02-01"), ]; etf$value <- etf$value / 2
  sp <- series_splice(etf = etf, idx = idx)
  post <- sp$date >= as.Date("2020-02-03")
  expect_true(all(sp$source[post] == "etf"))                                       # vorher Wochenenden 'idx'
  expect_equal(sp$value[sp$date %in% as.Date(c("2020-02-08", "2020-02-09"))], rep(etf$value[etf$date == as.Date("2020-02-07")], 2))
  # Luecke ueber 4 Kalendertage wird weiter aus der naechsten Reihe verkettet
  e2 <- etf[!(etf$date > as.Date("2020-03-02") & etf$date < as.Date("2020-03-09")), ]
  s2 <- series_splice(etf = e2, idx = idx)
  g <- s2$date > as.Date("2020-03-02") & s2$date < as.Date("2020-03-09")
  expect_true(all(s2$source[g] == "idx"))
  expect_equal(s2$value[g], s2$value[s2$date == as.Date("2020-03-02")] * idx$value[match(s2$date[g], idx$date)] / idx$value[idx$date == as.Date("2020-03-02")])
})

test_that("R2b-07: rollierende Sharpe Ratio mit dem Zins des Fensters", {
  set.seed(2)
  dt <- seq.Date(as.Date("2010-01-01"), as.Date("2023-12-31"), by = "day"); n <- length(dt)
  x <- data.frame(date = dt, value = 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)))
  ro <- result_analysis(x, risk_free = data.frame(date = as.Date(c("2010-01-01", "2020-01-01")), rate = c(0, 8)))$rolling$Strategie
  i <- which(ro$date == as.Date("2013-12-31"))
  expect_equal(ro$sharpe[i], ro$cagr[i] / ro$volatility[i])                        # vorher 1.063 statt 1.168
  j <- which(ro$date == as.Date("2023-12-31"))
  expect_equal(ro$sharpe[j], (ro$cagr[j] - 0.08) / ro$volatility[j], tolerance = 1e-10)
  rc <- result_analysis(x, risk_free = 2)$rolling$Strategie                          # konstanter Zins unveraendert
  expect_equal(rc$sharpe, (rc$cagr - 0.02) / rc$volatility, tolerance = 1e-12)
})
