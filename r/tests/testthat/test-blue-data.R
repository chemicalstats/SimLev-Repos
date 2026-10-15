# Tests zu den Befunden von Red Team 2 (Daten, Auswertung, Taktik) und R1-17, R1-27, R3-01, R3-08, R3-24

mk_day <- function(from, n, mu = 3e-4, sd = 0.01) {
  dt <- seq.Date(as.Date(from), by = "day", length.out = n)
  data.frame(date = dt, value = 100 * cumprod(1 + rnorm(n, mu, sd)))
}
trading_days <- function(from, n_cal) {
  cal <- seq.Date(as.Date(from), by = "day", length.out = n_cal)
  cal[!format(cal, "%u") %in% c("6", "7")]
}

test_that("R2-01: SimLevResult ohne Element filled wird ausgewertet", {
  set.seed(1)
  d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = 1000))
  d$A <- 100 * cumprod(1 + rnorm(1000, 3e-4, 0.01))
  a <- simulation(d, create_strategy(A = asset_config("etf", "bnh")))
  ref <- deep_analysis(a)$metrics
  a$filled <- NULL
  expect_equal(deep_analysis(a)$metrics, ref)
})

test_that("R2-02: annual ordnet Jahre per Datum zu", {
  set.seed(1)
  A <- mk_day("2010-01-01", 365 * 3); B <- mk_day("2015-01-01", 365 * 3); C <- mk_day("2011-06-01", 365 * 6)
  da <- deep_analysis(list(A = A, B = B))
  expect_equal(rownames(da$annual), as.character(c(2010:2012, 2015:2017)))
  expect_equal(da$annual["2015", "B"], da$monthly$B["2015", "Year"])
  expect_true(all(is.na(da$annual[as.character(2015:2017), "A"])))
  da2 <- deep_analysis(list(A = A, C = C))
  expect_equal(unname(da2$annual[as.character(2011:2017), "C"]), unname(da2$monthly$C[, "Year"]))
  expect_true(is.na(da2$annual["2013", "A"]))
})

test_that("R2-03: risk_free je Zeile aus dem Kalenderabstand", {
  set.seed(1)
  td <- trading_days("2010-01-01", 10 * 365); rf <- 4
  v <- 100 * (1 + rf / 100)^(as.numeric(td - td[1]) / 365.25) * exp(rnorm(length(td), 0, 1e-4))
  x <- data.frame(date = td, value = v)
  r <- v[-1] / v[-length(v)] - 1
  ex <- r - ((1 + rf / 100)^(as.numeric(diff(td)) / 365.25) - 1)
  ppy <- length(r) / (as.numeric(td[length(td)] - td[1]) / 365.25)
  sh <- deep_analysis(x, risk_free = rf)$metrics["sharpe", 1]
  expect_equal(unname(sh), mean(ex) * ppy / (sd(ex) * sqrt(ppy)))     # vorher 3.87
  expect_lt(abs(sh), 0.1)
  xc <- align_series(value = x)                                       # Kalendertage, Wochenenden gefuellt
  expect_equal(unname(deep_analysis(xc, risk_free = rf)$metrics["sharpe", 1]), unname(sh))
  res <- suppressMessages(simulation(data.frame(date = td, MM = v), create_strategy(MM = asset_config("etf", "bnh", asset_spread = 0))))
  expect_lt(abs(deep_analysis(res, risk_free = rf)$metrics["sharpe", 1]), 0.1)
})

test_that("R2-04: data.frame-Eingaben werden sortiert, doppelte Daten entfernt", {
  set.seed(1); n <- 1500
  x <- mk_day("2010-01-01", n)
  k <- c("years", "cagr", "volatility", "max_drawdown", "sharpe")
  ref <- deep_analysis(x)$metrics[k, ]
  expect_equal(deep_analysis(x[n:1, ])$metrics[k, ], ref)
  xd <- rbind(transform(x[c(100, 500, 900), ], value = value * 1.05), x)     # doppelte Daten, der letzte Wert ist richtig
  expect_message(m <- deep_analysis(xd)$metrics[k, ], "3 doppelte Daten")
  expect_equal(m, ref)
  expect_equal(return_heatmap(x[n:1, ])$matrix, return_heatmap(x)$matrix)
  set.seed(2); d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = 1000))
  d$p <- 100 * cumprod(1 + rnorm(1000, 3e-4, 0.01)); d$s <- c(NA, diff(log(d$p)))
  sa <- signal_analysis(d, "s", "p"); sr <- signal_analysis(d[1000:1, ], "s", "p")
  expect_equal(sr$bins, sa$bins)
})

test_that("R2-05: benchmark-Objekt \u00fcberschreibt keine Reihe 'Benchmark'", {
  set.seed(1); x <- mk_day("2010-01-01", 800); y <- mk_day("2010-01-01", 800)
  expect_error(deep_analysis(list(Strategie = x, Benchmark = y), benchmark = x), "bereits eine Reihe 'Benchmark'")
  expect_equal(deep_analysis(list(Strategie = x, Benchmark = y), benchmark = "Benchmark")$benchmark, "Benchmark")
})

test_that("R2-06: return_heatmap laesst ein Rumpfjahr am Ende weg", {
  dt <- seq.Date(as.Date("2010-01-01"), as.Date("2015-01-31"), by = "day")
  hm <- return_heatmap(data.frame(date = dt, value = 100 * 1.10^(as.numeric(dt - dt[1]) / 365.25)))
  expect_equal(rownames(hm$matrix), as.character(2010:2014))
  expect_true(all(abs(hm$matrix[!is.na(hm$matrix)] - 0.10) < 0.001))     # vorher 0.0081 fuer 2015
  # Handelstage, letzter Handelstag 30.12. (31.12. ist Samstag): Jahr bleibt
  cal <- seq.Date(as.Date("2012-01-01"), as.Date("2016-12-30"), by = "day")
  td <- cal[!format(cal, "%u") %in% c("6", "7")]
  hm2 <- return_heatmap(data.frame(date = td, value = 100 * 1.1^(as.numeric(td - td[1]) / 365.25)))
  expect_true("2016" %in% rownames(hm2$matrix))
})

test_that("R2-08: glidepath mit start = end bzw. end < start", {
  d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = 1460))
  gp <- glidepath(d, from = c(aktien = 0.9, geld = 0.1), to = c(aktien = 0.4, geld = 0.6), start = "2016-06-15", end = "2016-06-15")
  expect_equal(gp$aktien[1], 0.9); expect_equal(gp$aktien[1460], 0.4)
  expect_error(glidepath(d, from = c(aktien = 0.9, geld = 0.1), to = c(aktien = 0.4, geld = 0.6), start = "2017-01-01", end = "2016-01-01"),
               "liegt vor start")
})

test_that("R2-09: backcast mit Verkettungsdatum nach dem Datenende bricht ab", {
  set.seed(1); n <- 1000
  d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
  d$idx <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
  d$etf <- leveraged_series(d, "idx", leverage = 2, rate = 2, expense = 0.6); d$etf[1:600] <- NA
  expect_error(backcast(data = d, product = "etf", index = "idx", leverage = 2, rate = 2, ter = 0.6, splice = "2030-01-01"),
               "Kein Produktkurs ab dem Verkettungsdatum")
  bc <- backcast(data = d, product = "etf", index = "idx", leverage = 2, rate = 2, ter = 0.6, splice = "2017-01-01")
  expect_equal(attr(bc, "splice_date"), as.Date("2017-01-01"))
})

test_that("R2-10: unvollst\u00e4ndige bounds werden aus der Standardliste ergaenzt", {
  set.seed(1); n <- 1000
  d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
  d$idx <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
  d$etf <- leveraged_series(d, "idx", leverage = 2, rate = 2, expense = 0.6); d$etf[1:600] <- NA
  f <- backcast_fit(d, "etf", "idx", leverage = 2, rate = 2, ter = 0.6, fit = c("drag", "spread"), bounds = list(drag = c(-5, 5)),
                    validate = FALSE)
  expect_true(all(is.finite(unlist(f$params))))
  f2 <- backcast_fit(d, "etf", "idx", leverage = 2, rate = 2, ter = 0.6, fit = "spread", bounds = list(drag = c(-5, 5)), validate = FALSE)
  expect_true(is.finite(f2$params$spread))
  expect_error(backcast_fit(d, "etf", "idx", leverage = 2, rate = 2, ter = 0.6, bounds = list(drag = c(5, -5))), "unten < oben")
})

test_that("R2-11: sensitivity_grid und lumpsum_vs_dca melden die Ursache", {
  set.seed(1)
  d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = 1500))
  d$A <- 100 * cumprod(1 + rnorm(1500, 3e-4, 0.01)); d$B <- 100 * cumprod(1 + rnorm(1500, 1e-4, 0.004))
  st <- create_strategy(A = asset_config("etf", "bnh", 0.6), B = asset_config("etf", "bnh", 0.4))
  expect_error(sensitivity_grid(d, st, list(balance_thresh = c(5, 10)), sim_args = list(balance_mode = TRUE, balance_unit = "monat")),
               "Alle 2 L\u00e4ufe fehlgeschlagen: .*month")
  st1 <- create_strategy(A = asset_config("etf", "bnh"))
  expect_error(lumpsum_vs_dca(d, st1, horizon = 2, step = 6, sim_args = list(start_value = 5000)), "setzt start_value selbst")
  expect_error(lumpsum_vs_dca(d, st1, horizon = 2, step = 6, sim_args = list(dca_skip = FALSE)), "setzt dca_skip selbst")
})

test_that("R2-13: rollierendes Beta bei sp\u00e4ter beginnendem Benchmark richtig zugeordnet", {
  set.seed(1); n <- 365 * 8
  dt <- seq.Date(as.Date("2010-01-01"), by = "day", length.out = n)
  b <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)); s <- b * cumprod(1 + rnorm(n, 0, 0.001))
  S <- data.frame(date = dt, value = s); B <- data.frame(date = dt, value = b)[dt >= as.Date("2013-01-01"), ]
  ro <- deep_analysis(S, benchmark = B, rolling_years = 1)$rolling$Strategie
  ref <- deep_analysis(S[dt >= as.Date("2013-01-01"), ], benchmark = B, rolling_years = 1)$rolling$Strategie
  k <- match(ref$date, ro$date); k <- k[!is.na(k)]
  expect_true(all(abs(ro$beta[is.finite(ro$beta)] - 1) < 0.15))           # vorher Beta um 0.1 bis 0.3
  expect_equal(ro$beta[k][-1], ref$beta[match(ro$date[k], ref$date)][-1])
})

test_that("R2-14: fuehrende NA werden abgeschnitten, nicht rueckwaerts gef\u00fcllt", {
  set.seed(1)
  a <- mk_day("2010-01-01", 3650)
  b <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = 1825)); b$value <- 100 * 1.05^(0:1824 / 365.25)
  al <- align_series(A = a, B = b, range = "all")
  m <- deep_analysis(list(A = al[, c("date", "A")], B = al[, c("date", "B")]))$metrics
  expect_equal(m[c("years", "cagr"), "B"], deep_analysis(b)$metrics[c("years", "cagr"), 1], tolerance = 1e-10)
  expect_equal(unname(m["cagr", "B"]), 0.05, tolerance = 1e-6)
})

test_that("R2-15: mit inflation wird auch risk_free deflationiert", {
  set.seed(1)
  dt <- seq.Date(as.Date("2010-01-01"), by = "day", length.out = 3650)
  x <- data.frame(date = dt, value = 100 * 1.03^(as.numeric(dt - dt[1]) / 365.25) * exp(rnorm(3650, 0, 1e-4)))
  nom <- deep_analysis(x, risk_free = 3)$metrics["sharpe", 1]
  real <- deep_analysis(x, risk_free = 3, inflation = 3)$metrics["sharpe", 1]
  expect_lt(abs(nom), 0.05); expect_lt(abs(real - nom), 0.01)             # vorher real -10.7
})

test_that("R2-16/R2-17: Zahlen als Text oder Faktor werden erkannt", {
  set.seed(1); n <- 300
  dt <- seq.Date(as.Date("2020-01-01"), by = "day", length.out = n); v <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
  txt <- sub(".", ",", format(round(v, 2), nsmall = 2), fixed = TRUE)
  expect_error(deep_analysis(data.frame(date = dt, value = factor(txt))), "Zahlen als Text bzw. Faktor")
  expect_error(deep_analysis(data.frame(date = dt, value = txt)), "Dezimalkomma")
  expect_error(deep_analysis(data.frame(date = dt, Kurs = txt, Volumen = rpois(n, 1e5))), "'Kurs'")
  expect_error(align_series(a = data.frame(date = dt, Kurs = txt, Volumen = rpois(n, 1e5))), "'Kurs'")
  expect_message(deep_analysis(data.frame(date = dt, Kurs = v, Volumen = rpois(n, 1e5))), "Wertspalte 'Kurs' verwendet")
})

test_that("R2-18: POSIXct-Datum zaehlt mit dem Kalendertag seiner Zeitzone", {
  set.seed(1); n <- 400
  dt <- seq.Date(as.Date("2020-01-01"), by = "day", length.out = n)
  x <- data.frame(date = as.POSIXct(format(dt), tz = "Europe/Berlin"), value = 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)))
  expect_equal(deep_analysis(x)$series$Strategie$date[1], as.Date("2020-01-01"))
  expect_equal(align_series(a = x)$date[1], as.Date("2020-01-01"))
  expect_equal(check_series(x)$summary$start, as.Date("2020-01-01"))
  expect_equal(rownames(deep_analysis(x)$annual)[1], "2020")
  x2 <- data.frame(date = x$date, A = x$value)
  expect_equal(momentum_score(x2, "A", lookbacks = 1), momentum_score(transform(x2, date = dt), "A", lookbacks = 1))
})

test_that("R2-19: align_series bevorzugt die Date-Spalte und lehnt numerische Datumsspalten ab", {
  set.seed(1); tage <- seq.Date(as.Date("2022-01-03"), by = "day", length.out = 100)
  roh <- data.frame(X = 1:100, Datum = tage, Kurs = 100 * cumprod(1 + rnorm(100, 3e-4, 0.01)))
  expect_message(d <- align_series(etf = roh), "Zeilennummern")
  expect_equal(names(d), c("date", "etf")); expect_equal(d$date[1], as.Date("2022-01-03"))
  expect_error(align_series(etf = data.frame(X = 1:100, Kurs = roh$Kurs)), "numerisch")
})

test_that("R2-20: Datum als Text in falschem Format wird abgewiesen", {
  set.seed(1); dt <- seq.Date(as.Date("2020-01-01"), by = "day", length.out = 100)
  x <- data.frame(date = format(dt, "%d-%m-%Y"), value = 100 * cumprod(1 + rnorm(100, 3e-4, 0.01)))
  expect_error(align_series(a = x), "nicht als 'JJJJ-MM-TT' lesbar")
  expect_error(deep_analysis(x), "format = ")
  expect_error(deep_analysis(transform(x, date = format(dt, "%d.%m.%Y"))), "nicht als 'JJJJ-MM-TT' lesbar")
})

test_that("R2-21: splice_series fuellt L\u00fccken der ersten Reihe mit Renditen der naechsten", {
  proxy <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = 400))
  proxy$value <- 100 * cumprod(1 + c(0, rep(0.001, 399)))
  fonds <- proxy[proxy$date >= as.Date("2010-03-01"), ]; fonds$value <- fonds$value / 2
  fonds <- fonds[!(fonds$date > as.Date("2010-06-01") & fonds$date < as.Date("2010-07-01")), ]
  sp <- splice_series(fonds = fonds, proxy = proxy)
  g <- sp[sp$date >= as.Date("2010-06-02") & sp$date <= as.Date("2010-07-01"), ]
  expect_equal(g$value[-1] / g$value[-nrow(g)] - 1, rep(0.001, nrow(g) - 1))
  expect_true(all(g$source[-nrow(g)] == "proxy")); expect_equal(g$source[nrow(g)], "fonds")
  # Wochenenden zweier Handelstagsreihen bleiben beim letzten Wert der ersten Reihe
  td <- trading_days("2020-01-01", 200)
  p2 <- data.frame(date = td, value = 100 * 1.001^seq_along(td)); f2 <- p2[p2$date >= as.Date("2020-03-01"), ]
  s2 <- splice_series(f = f2, p = p2)
  expect_true(all(s2$source[s2$date >= as.Date("2020-03-02")] == "f"))
})

test_that("R2-22: align_macro yoy/mom per Datum", {
  cpi <- data.frame(date = seq.Date(as.Date("2018-01-01"), by = "month", length.out = 48), value = 100 * 1.002^(0:47))
  dts <- as.Date(c("2021-03-15", "2021-06-15"))
  full <- align_macro(dts, cpi, transform = "yoy")
  gap <- align_macro(dts, cpi[-30, ], transform = "yoy")                  # Juni 2020 fehlt
  expect_equal(gap[1], full[1]); expect_true(is.na(gap[2]))               # vorher 2.63 (13 Monate)
  expect_true(is.na(align_macro(as.Date("2020-07-15"), cpi[-30, ], transform = "mom")))
})

test_that("R2-23: momentum_score-R\u00fcckblick auf das Monatsende begrenzt", {
  d <- data.frame(date = seq.Date(as.Date("2019-01-01"), as.Date("2021-12-31"), by = "day"))
  d$A <- as.numeric(d$date - d$date[1]) + 100
  ref_day <- function(ms, s) { i <- which(d$date == as.Date(s)); d$date[1] + unname(round(d$A[i] / (1 + ms[i, 1]) - 100)) }
  ms1 <- momentum_score(d, "A", lookbacks = 1)
  expect_equal(ref_day(ms1, "2020-03-31"), as.Date("2020-02-29"))        # vorher 2020-03-02
  expect_equal(ref_day(ms1, "2021-03-31"), as.Date("2021-02-28"))
  expect_equal(ref_day(ms1, "2020-05-31"), as.Date("2020-04-30"))
  expect_equal(ref_day(ms1, "2020-05-15"), as.Date("2020-04-15"))        # Monatsmitte unveraendert
  expect_equal(ref_day(momentum_score(d, "A", lookbacks = 12), "2020-02-29"), as.Date("2019-02-28"))
})

test_that("R2-24: deep_analysis beachtet attr(, 'filled') aus align_series", {
  set.seed(3)
  td <- trading_days("2012-01-02", 4 * 365)
  x <- data.frame(date = td, value = 100 * cumprod(1 + rnorm(length(td), 3e-4, 0.01)))
  al <- align_series(value = x)
  k <- c("volatility", "sharpe", "skewness", "excess_kurtosis", "var_daily_5", "cvar_daily_5", "cagr")
  expect_equal(deep_analysis(al)$metrics[k, ], deep_analysis(x)$metrics[k, ])
})

test_that("R2-25/R2-26: signal_analysis mit 0/1-Signal und klaren Fehlern", {
  set.seed(1); n <- 3 * 365
  d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
  d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
  d$investiert <- as.numeric(signal_state(signal_sma(d$aktien, 100)))
  sa <- signal_analysis(d, "investiert", "aktien")
  expect_equal(nrow(sa$bins), 2L); expect_equal(sa$bins$from, c(0, 1)); expect_equal(sa$bins$to, c(0, 1))
  d$mom <- c(rep(NA, 60), d$aktien[-(1:60)] / d$aktien[1:(n - 60)] - 1); d$const <- 1
  expect_error(signal_analysis(d, "const", "aktien"), "an allen Stichtagen gleich")
  expect_error(signal_analysis(d, "mom", "aktien", breaks = 0), "breaks braucht mindestens 3")
  expect_error(signal_analysis(d, "mom", "aktien", horizon = 5000), "horizon muss zwischen 1 und")
  expect_error(signal_analysis(d, "Mom", "aktien"), "Spalte 'Mom' fehlt")
  expect_error(signal_analysis(d, d$mom[-1], "aktien"), "L\u00e4nge")
})

test_that("R2-27: deep_analysis meldet unbrauchbare Eingaben klar", {
  set.seed(1); a <- mk_day("2010-01-01", 1500)
  z <- a; z$value[100] <- 0
  expect_error(deep_analysis(z), "positive Niveaus")
  expect_error(deep_analysis(a[1:2, ]), "zu kurz")
  b2 <- a; b2$date <- b2$date + 3000
  expect_error(deep_analysis(a, benchmark = b2), "zu wenige gemeinsame Daten")
  expect_error(deep_analysis(a, rolling_years = 0), "rolling_years")
  da <- deep_analysis(a)
  pdf(NULL); on.exit(grDevices::dev.off(), add = TRUE)
  expect_error(plot(da, type = "monthly", series = "gibtsnicht"), "series")
  expect_error(plot(da, type = "monthly", series = 3), "series")
})

test_that("R2-28: check_series meldet fehlende Daten statt abzubrechen", {
  set.seed(1)
  x <- data.frame(date = c(format(seq.Date(as.Date("2020-01-01"), by = "day", length.out = 50)), ""), A = c(100 + cumsum(rnorm(50)), NA))
  ck <- check_series(x)
  expect_true(any(grepl("Datum fehlt", ck$issues$type)))
  expect_equal(ck$summary$n, 50L)
})

test_that("R2-29: convert_currency prueft Spalten und Wechselkurs", {
  dd <- data.frame(date = as.Date("2024-01-01") + 0:4, usd = 1:5, fx = 1.1)
  expect_error(convert_currency(dd, "USD", fx = "fx"), "'USD' fehlen")
  expect_error(convert_currency(dd, "usd", fx = 0), "positiv")
  expect_equal(convert_currency(dd, "usd", fx = "fx")$usd, (1:5) / 1.1)
})

test_that("R2-30: portfolio_template prueft map", {
  expect_error(portfolio_template("60_40", map = c(stock = "A", bonds = "B")), "unbekannte Rolle")
  expect_error(portfolio_template("60_40", map = c(stocks = "A", bonds = "A")), "dieselbe Spalte 'A'")
  expect_equal(names(portfolio_template("60_40", map = c(stocks = "A", bonds = "B"))), c("A", "B"))
})

test_that("R2-31: Gewichts-Erzeuger pr\u00fcfen ihre Argumente", {
  set.seed(1); n <- 4 * 365
  d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
  d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)); d$anleihen <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.003))
  d$geld <- 100 * cumprod(rep(1 + 0.01 / 365, n))
  kern <- glidepath(d, from = c(aktien = 0.8, anleihen = 0.2), to = c(aktien = 0.5, anleihen = 0.5))
  sat <- tactical_rotation(d, c("aktien", "anleihen"), safe = "geld")
  expect_error(blend_weights(kern, sat, shares = 0.7), "shares braucht 2")
  expect_error(tactical_rotation(d, c("aktien", "anleihen"), safe = "geld", top = 3), "top muss zwischen 1 und")
  expect_error(tactical_rotation(d, c("aktien", "anleihen"), safe = "geld", canary = "aktien", breadth = 0), "breadth")
  expect_error(target_volatility(d, c(aktien = 1, gold = 0.5), safe = "geld"), "fehlen in data: gold")
  expect_warning(target_volatility(d, c(aktien = 1), safe = "geld", target = 0.1), "Prozent")
  expect_warning(conditional_volatility(d, c(aktien = 1), safe = "geld", base = 0.8, min_history = 10), "min_history")
})

test_that("R2-32: Signal- und Aufbereitungsfunktionen pr\u00fcfen Vorbedingungen", {
  set.seed(1); x <- 100 * cumprod(1 + rnorm(1000, 2e-4, 0.01))
  expect_error(signal_combine(signal_sma(x, 200), signal_sma(x[1:500], 50)), "unterschiedliche L\u00e4ngen")
  y <- x; y[10] <- NA
  s <- signal_drawdown(y); s0 <- signal_drawdown(x)
  expect_false(s$buy[10]); expect_equal(s$buy[-10], s0$buy[-10])
  dts <- seq.Date(as.Date("2024-01-01"), by = "day", length.out = 6)
  expect_error(total_return_index(rep(100, 6), yield = 2, dates = dts[c(1, 2, 3, 6, 5, 4)]), "aufsteigend")
  cpi <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "month", length.out = 24), value = 100 * 1.01^(0:23))
  d <- data.frame(date = seq.Date(as.Date("2019-11-01"), by = "day", length.out = 200), depot = 100)
  d1 <- align_macro(d, cpi, "cpi")
  expect_message(r1 <- deflate(d1, "depot", cpi = "cpi"), "61 Zeilen davor")
  expect_true(all(is.na(r1$depot_real[1:61]))); expect_equal(r1$depot_real[62], 100)
  expect_message(r2 <- deflate(d, "depot", cpi = cpi), "61 Zeilen davor")
  expect_equal(r2$depot_real, r1$depot_real)
  expect_error(suppressMessages(deflate(d1, "depot", cpi = "cpi", base_date = "2019-12-01")), "kein Preisindex")
})

test_that("R1-17: tactical_simulation zaehlt lag in Zeilen mit echten Kursen", {
  set.seed(11)
  cal <- seq.Date(as.Date("2021-01-04"), as.Date("2021-03-31"), by = "day"); wd <- cal[!format(cal, "%u") %in% c("6", "7")]
  us <- data.frame(date = wd, aktien = 100 * cumprod(1 + rnorm(length(wd), 0, 0.01)), geld = 100)
  al <- align_series(us = us); fri <- as.Date("2021-02-05")
  w <- tactical_rules(al, list(list(when = al$date >= fri, weights = c(aktien = 1))), default = c(geld = 1))
  res <- suppressMessages(tactical_simulation(al, w, lag = 1, asset_args = list(asset_spread = 0)))
  expect_equal(res$tactical$events, as.Date("2021-02-08"))               # Montag statt Samstag
  # ohne Attribut wie bisher: naechste Zeile
  al0 <- al; attr(al0, "filled") <- NULL
  res0 <- suppressMessages(tactical_simulation(al0, w, lag = 1, asset_args = list(asset_spread = 0)))
  expect_equal(res0$tactical$events, as.Date("2021-02-06"))
})

test_that("R1-27: strategy_from_weights prueft frueh", {
  expect_error(strategy_from_weights(c(a = 0.3, b = 0.3)), "summieren sich zu 0.6000")
  s <- strategy_from_weights(c(aktien = 0.7, gold = 0.3), asset_bonus = c(aktien = 30))
  expect_equal(s$aktien$asset_bonus, 30); expect_false(isTRUE(s$gold$asset_bonus == 30))
  expect_equal(strategy_from_weights(c(a = 0.5, b = 0.5), asset_spread = 0.2)$b$asset_spread, 0.2)
  expect_error(strategy_from_weights(c(a = 0.5, a = 0.5)), "doppelte Namen")
})

test_that("R3-01: reality_check mit einem Kandidaten", {
  set.seed(1); r <- matrix(rnorm(500, 0.0004, 0.01), ncol = 1)
  rc <- reality_check(r, B = 999, frequency = "day", seed = 1)
  rc2 <- reality_check(cbind(r, r), B = 999, frequency = "day", seed = 1)
  expect_equal(rc[c("p_rc", "p_spa", "p_spa_lower", "p_spa_upper")], rc2[c("p_rc", "p_spa", "p_spa_lower", "p_spa_upper")])
  expect_lt(rc$p_rc, 1)
})

test_that("R3-08/R3-24: sharpe_test lehnt gemischte, ungleich lange und entartete Eingaben ab", {
  set.seed(1); n <- 3 * 365
  d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n)); d$a <- 100 * cumprod(1 + rnorm(n, 4e-4, 0.01))
  ra <- diff(d$a) / d$a[-n]
  expect_error(sharpe_test(ra, d[, c("date", "a")]), "dieselbe Art")
  expect_error(sharpe_test(ra[1:1000], ra[1:500]), "gleich lang")
  a <- rnorm(500, 0.001, 0.01)
  t0 <- sharpe_test(a, a)
  expect_equal(unname(t0[c("difference", "se", "z", "p_value")]), c(0, 0, 0, 1))
  expect_error(sharpe_test(a, rep(0.001, 500)), "Varianz 0")
  expect_error(sharpe_test(a[1:3], a[3:1] + 0.01), "zu wenige")
})
