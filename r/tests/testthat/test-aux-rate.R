# Tests: aux_type = "rate" bedeutet ueberall Prozent pro Jahr (2 = 2 % p. a.), Aufzinsung ueber
# Kalendertage (1 + r/100)^(Tage/365.25); ohne Angabe bisheriges Verhalten (bitgleich)

# Kursniveaus (n + 1 Zeilen): infl = konstant 2 (% p. a.), zins = schwankende Rate um 2
.ar_data <- function(n = 1461) {
  set.seed(21)
  data.frame(us = 100 * cumprod(c(1, 1 + rnorm(n, 3e-4, 0.01))), infl = 2, zins = 2 + sin((0:n) / 40))
}
.ar_cal <- function(n = 1461) seq.Date(as.Date("2001-01-01"), by = "day", length.out = n + 1)   # bis 2005-01-01
.ar_td <- function(n = 1461) { x <- seq.Date(as.Date("2001-01-01"), by = "day", length.out = 2 * n)
  x[!format(x, "%u") %in% c("6", "7")][seq_len(n + 1)] }                                          # Handelstage Mo-Fr
.ar_bnh <- list(bnh = create_strategy(us = asset_config("etf", "bnh")))
.ar_cfg <- function(...) bootstrap_config(c(us = "us"), aux = c(infl = "infl", zins = "zins"), input = "prices", ...)

test_that("Handrechnung: konstante Rate 2 % p. a. ergibt je Jahr 1.02^(Tage/365.25) auf Kalenderdaten", {
  d <- .ar_data(); dts <- .ar_cal()
  # 2001: 365 Tage -> 1.02^(365/365.25) = 1.019986174850820; 2004: 366 Tage -> 1.020041476571890;
  # vier Jahre 2001-2004 = 1461 Tage = 4 x 365.25 -> 1.02^4 = 1.08243216 (exakt 1,02 je Jahr im Mittel)
  hand <- c(1.01998617485082, 1.01998617485082, 1.01998617485082, 1.02004147657189)
  cfg <- .ar_cfg(aux_type = c(infl = "rate"))
  b <- bootstrap(d, cfg, "stationary", n = 3, params = list(L = 60), seed = 4, progress = FALSE)
  wp <- withdrawal_paths(b, column = "us", inflation = "infl", dates = dts)   # ohne inflation_type
  expect_equal(dim(wp$inflation), c(4L, 3L))
  for (k in 1:3) expect_equal(wp$inflation[, k], hand, tolerance = 1e-13)
  expect_equal(apply(wp$inflation, 2, prod), rep(1.08243216, 3), tolerance = 1e-13)
  # gleich der Zahl 2 (Prozent p. a.) und gleich inflation_type = "rate_pa"
  expect_equal(wp$inflation, withdrawal_paths(b, column = "us", inflation = 2, dates = dts)$inflation, tolerance = 1e-13)
  expect_identical(wp$inflation, withdrawal_paths(b, column = "us", inflation = "infl", inflation_type = "rate_pa", dates = dts)$inflation)
  # Quartale und Monate: Produkt innerhalb eines Jahres = Jahresfaktor (Aggregation konsistent)
  wq <- withdrawal_paths(b, column = "us", inflation = "infl", dates = dts, frequency = "quarter")$inflation
  wm <- withdrawal_paths(b, column = "us", inflation = "infl", dates = dts, frequency = "month")$inflation
  expect_equal(wq[1, 1], 1.02^(90 / 365.25), tolerance = 1e-13)                # 01.01.-01.04.2001: 90 Tage
  expect_equal(wm[1, 1], 1.02^(31 / 365.25), tolerance = 1e-13)                # Januar: 31 Tage
  expect_equal(apply(matrix(wq[, 1], 4), 2, prod), hand, tolerance = 1e-13)
  expect_equal(apply(matrix(wm[, 1], 12), 2, prod), hand, tolerance = 1e-13)
  # bootstrap_study(keep_aux): dieselben Faktoren ohne weitere Angabe
  st <- bootstrap_study(d, cfg, "stationary", n = 3, params = list(L = 60), seed = 4, progress = FALSE, dates = dts,
                        keep_returns = "year", keep_aux = "infl", strategies = .ar_bnh)
  expect_equal(st$aux_returns$infl, matrix(hand, 4, 3), tolerance = 1e-13)
  expect_equal(withdrawal_paths(st, inflation = "infl")$inflation, matrix(hand, 4, 3), tolerance = 1e-13)
  stq <- bootstrap_study(d, cfg, "stationary", n = 2, params = list(L = 60), seed = 4, progress = FALSE, dates = dts,
                         keep_returns = "quarter", keep_aux = "infl", strategies = .ar_bnh)
  expect_equal(apply(matrix(stq$aux_returns$infl[, 1], 4), 2, prod), hand, tolerance = 1e-13)
  # withdrawal_simulation(Studie, inflation = Name) = withdrawal_simulation(Studie, inflation = 2)
  w1 <- withdrawal_simulation(st, withdrawal_rule("constant", rate = 4), inflation = "infl")
  w2 <- withdrawal_simulation(st, withdrawal_rule("constant", rate = 4), inflation = 2)
  expect_equal(w1$paths$terminal_real, w2$paths$terminal_real, tolerance = 1e-12)
  expect_equal(w1$paths$terminal_nominal / w1$paths$terminal_real, rep(1.08243216, 3), tolerance = 1e-12)
  # withdrawal_cohorts auf bootstrap_data(): Rate statt Preisindex (vorher Faktor 1)
  x <- bootstrap_data(b, 1, dates = dts)
  expect_identical(attr(x, "aux_type"), c(infl = "rate"))
  co <- withdrawal_cohorts(x, price = "us", inflation = "infl", years = 1, step = "year")
  expect_equal(co$inflation, withdrawal_cohorts(x, price = "us", inflation = 2, years = 1, step = "year")$inflation, tolerance = 1e-13)
  expect_equal(co$inflation[1, 1], 1.02^(365 / 365.25), tolerance = 1e-13)    # Monatsende 31.01.2001 -> 31.01.2002: 365 Tage
})

test_that("Handrechnung: konstante Rate 2 % p. a. auf Handelstagsdaten (Wochenenden als Kalendertage)", {
  d <- .ar_data(); dts <- .ar_td()
  cfg <- .ar_cfg(aux_type = c(infl = "rate"))
  b <- bootstrap(d, cfg, "block", n = 2, params = list(block_length = 30), seed = 5, progress = FALSE)
  ends <- SimLev:::.anniv_ends(dts, "year")
  tage <- as.numeric(diff(dts[ends]))           # letzter Handelstag bis zum Jahrestag
  expect_true(all(tage %in% 364:367))
  hand <- 1.02^(tage / 365.25)                  # z. B. 364 Tage -> 1.019931, 367 Tage -> 1.020097
  wp <- withdrawal_paths(b, column = "us", inflation = "infl", dates = dts)
  for (k in 1:2) expect_equal(wp$inflation[, k], hand, tolerance = 1e-13)
  expect_equal(prod(wp$inflation[, 1]), 1.02^(as.numeric(dts[ends[length(ends)]] - dts[1]) / 365.25), tolerance = 1e-13)
  st <- bootstrap_study(d, cfg, "block", n = 2, params = list(block_length = 30), seed = 5, progress = FALSE, dates = dts,
                        keep_returns = "year", keep_aux = "infl", strategies = .ar_bnh)
  expect_equal(st$aux_returns$infl, matrix(hand, length(hand), 2), tolerance = 1e-13)
  # Rate je Zeile gilt fuer die Kalendertage seit der Vorzeile: schwankende Rate, Handrechnung je Zeile
  cfg2 <- .ar_cfg(aux_type = c(zins = "rate"))
  b2 <- bootstrap(d, cfg2, "stationary", n = 1, params = list(L = 60), seed = 6, progress = FALSE)
  z <- b2$paths[[1]][, "zins"]
  lv <- cumprod(c(1, (1 + z[-1] / 100)^(as.numeric(diff(dts)) / 365.25)))
  expect_equal(withdrawal_paths(b2, column = "us", inflation = "zins", dates = dts)$inflation[, 1],
               lv[ends[-1]] / lv[ends[-length(ends)]], tolerance = 1e-13)
  co <- withdrawal_cohorts(bootstrap_data(b, 2, dates = dts), price = "us", inflation = "infl", years = 1, frequency = "month")
  mend <- dts[SimLev:::.period_ends(dts, "month")]
  expect_equal(co$inflation[, 1], 1.02^(as.numeric(diff(mend[1:13])) / 365.25), tolerance = 1e-13)
})

test_that("aux_type 'rate': widersprechende oder unbrauchbare Angaben sind ein Fehler", {
  d <- .ar_data(); dts <- .ar_cal()
  cfg <- .ar_cfg(aux_type = c(infl = "rate"))
  b <- bootstrap(d, cfg, "stationary", n = 2, params = list(L = 60), seed = 4, progress = FALSE)
  expect_error(withdrawal_paths(b, column = "us", inflation = "infl", inflation_type = "level", dates = dts),
               "inflation_type = 'level' passt nicht zu aux_type\\['infl'\\] = 'rate'")
  st <- bootstrap_study(d, cfg, "stationary", n = 2, params = list(L = 60), seed = 4, progress = FALSE, dates = dts,
                        keep_returns = "year", keep_aux = c("infl", "zins"), strategies = .ar_bnh)
  expect_error(withdrawal_paths(st, inflation = "infl", inflation_type = "level"), "passt nicht zu aux_type\\['infl'\\] = 'rate'")
  # Studie ohne aux_type fuer 'zins': gespeichert ist die Niveau-Variante; rate_pa vorher still ignoriert (Faktoren ~ Zinsverhaeltnisse)
  expect_error(withdrawal_paths(st, inflation = "zins", inflation_type = "rate_pa"),
               "inflation_type = 'rate_pa': die mit keep_aux gespeicherten Faktoren der Zusatzreihe 'zins' sind die Niveau-Variante.*aux_type = c\\(zins = 'rate'\\)")
  expect_silent(withdrawal_paths(st, inflation = "zins", inflation_type = "level"))
  # Rate <= -100 % p. a.: bootstrap_result vorher NaN ohne Meldung, jetzt Fehler (wie bei Studien)
  d$infl <- -150
  b2 <- bootstrap(d, cfg, "raw", n = 1, seed = 1, progress = FALSE)
  expect_error(withdrawal_paths(b2, column = "us", inflation = "infl", dates = dts),
               "Zusatzreihe 'infl' \\(Rate in Prozent p. a.\\) ergibt nicht endliche oder nicht positive Periodenfaktoren \\(z. B. NaN")
  expect_error(withdrawal_cohorts(bootstrap_data(b2, 1, dates = dts), price = "us", inflation = "infl", years = 1),
               "Spalte 'infl' \\(Rate in Prozent p. a.\\) ergibt nicht endliche oder nicht positive Monatsfaktoren")
})

test_that("ohne aux_type: Ergebnisse bitgleich zum Stand vor der Vereinheitlichung", {
  d <- .ar_data(); td <- .ar_td()
  cfg0 <- .ar_cfg()
  b0 <- bootstrap(d, cfg0, "stationary", n = 2, params = list(L = 60), seed = 9, progress = FALSE)
  st0 <- bootstrap_study(d, cfg0, "stationary", n = 2, params = list(L = 60), seed = 9, progress = FALSE, dates = td,
                         keep_returns = "year", keep_aux = "zins", strategies = .ar_bnh)
  h <- function(x) sprintf("%a", as.numeric(x))
  # Referenzwerte mit dem Paketstand vor der Aenderung erzeugt (Niveau-Variante der Ratenspalte usw.)
  lvl <- c("0x1.e9594c3474179p+0", "0x1.068f6ddc18bccp+0", "0x1.d32917817f672p-1", "0x1.581017e2f1e63p+0", "0x1.080c5234ab309p+1")
  expect_identical(h(withdrawal_paths(b0, column = "us", inflation = "zins", dates = td)$inflation[, 2]), lvl)
  expect_identical(h(st0$aux_returns$zins[, 2]), lvl)
  expect_identical(h(withdrawal_paths(st0, inflation = "zins")$inflation[, 2]), lvl)
  expect_identical(h(withdrawal_paths(b0, column = "us", inflation = "zins", inflation_type = "rate_pa", dates = td)$inflation[, 2]),
                   c("0x1.053bd1952b905p+0", "0x1.04fe7592d5816p+0", "0x1.05b2d6494fa05p+0", "0x1.055028bd97b2ap+0", "0x1.04fa8921f954cp+0"))
  x0 <- bootstrap_data(b0, 2, dates = td)
  expect_null(attr(x0, "aux_type"))
  expect_identical(x0, data.frame(date = td, as.data.frame(b0$paths[[2]]), check.names = FALSE))
  expect_identical(h(withdrawal_cohorts(x0, price = "us", inflation = "zins", years = 1)$inflation[1, 1:5]),
                   c("0x1.23d12949edd83p+1", "0x1.2f38861c9c291p-1", "0x1.0211147e43836p-1", "0x1.1efd8c99e28c9p-1", "0x1.62b81b55888d9p-1"))
  expect_identical(h(b0$paths[[2]][c(1, 2, 500, 1462), "zins"]),
                   c("0x1.9098ff1dac65dp+0", "0x1.9098ff1dac65dp+0", "0x1.2e856428e9ba4p+0", "0x1.7ece3557cbf66p+1"))
  # nur 'level' angegeben: bootstrap_data ohne Attribut, Ratenspalten unveraendert
  bl <- bootstrap(d, .ar_cfg(aux_type = c(infl = "level")), "stationary", n = 2, params = list(L = 60), seed = 9, progress = FALSE)
  expect_null(attr(bootstrap_data(bl, 1), "aux_type"))
  expect_identical(bl$paths[[2]][, "zins"], b0$paths[[2]][, "zins"])
  # Angabe 'rate' aendert Pfade, Indizes und Niveau-Attribut nicht (nur die Weiterverarbeitung)
  br <- bootstrap(d, .ar_cfg(aux_type = c(zins = "rate")), "stationary", n = 2, params = list(L = 60), seed = 9, progress = FALSE)
  expect_identical(br$paths, b0$paths)
})

test_that("R5-01: withdrawal_cohorts(inflation_type) f\u00fcr Ratenspalten ohne Attribut (transform/merge/cbind/CSV)", {
  set.seed(21); n <- 1461
  d <- data.frame(us = 100 * cumprod(c(1, 1 + rnorm(n, 3e-4, 0.01))), infl = 2 + 0.5 * sin((0:n) / 100), zins = 2)
  dts <- .ar_cal()
  b <- bootstrap(d, .ar_cfg(aux_type = c(infl = "rate")), "stationary", n = 1, params = list(L = 60), seed = 4, progress = FALSE)
  bd <- bootstrap_data(b, 1, dates = dts)
  ref <- withdrawal_cohorts(bd, price = "us", inflation = "infl", years = 1)$inflation      # Rate aus dem Attribut
  z <- bd$infl; lv <- cumprod(c(1, (1 + z[-1] / 100)^(as.numeric(diff(dts)) / 365.25)))  # Handrechnung je Zeile
  me <- SimLev:::.period_ends(dts, "month")
  expect_equal(ref[1, 1], lv[me[13]] / lv[me[1]], tolerance = 1e-13)
  f <- tempfile(fileext = ".csv"); write.csv(bd, f, row.names = FALSE); on.exit(unlink(f))
  v <- list(transform = transform(bd, us_eur = us * 0.9), merge = merge(bd, data.frame(date = dts, x = 1)),
            cbind = cbind(bd, x = 1), csv = read.csv(f))
  for (k in names(v)) {
    expect_null(attr(v[[k]], "aux_type"), info = k)
    # vorher still als Preisindex gelesen (z. B. 0,78); jetzt mit inflation_type = "rate_pa" wie mit Attribut
    expect_equal(withdrawal_cohorts(v[[k]], price = "us", inflation = "infl", years = 1, inflation_type = "rate_pa")$inflation,
                 ref, tolerance = 1e-12, info = k)
    # ohne Angabe bisheriges Verhalten (Niveau), bitgleich zu inflation_type = "level"
    expect_identical(withdrawal_cohorts(v[[k]], price = "us", inflation = "infl", years = 1)$inflation,
                     withdrawal_cohorts(v[[k]], price = "us", inflation = "infl", years = 1, inflation_type = "level")$inflation, info = k)
  }
  lvl <- withdrawal_cohorts(v$cbind, price = "us", inflation = "infl", years = 1)$inflation
  expect_equal(lvl[1, 1], prod(z[me[2:13]] / z[me[1:12]]), tolerance = 1e-13)                # Verhaeltnis der Monatsendwerte
  # Attribut und ausdrueckliche Angabe: passend ok, Widerspruch Fehler
  expect_identical(withdrawal_cohorts(bd, price = "us", inflation = "infl", years = 1, inflation_type = "rate_pa")$inflation, ref)
  expect_error(withdrawal_cohorts(bd, price = "us", inflation = "infl", years = 1, inflation_type = "level"),
               "inflation_type = 'level' passt nicht zu aux_type\\['infl'\\] = 'rate' \\(Attribut aus bootstrap_data\\(\\)\\)")
  # historische Daten mit Ratenspalte: konstante 2 % p. a. = Zahl 2; bei Zahl ohne Wirkung
  h <- data.frame(date = dts, p = d$us, r = 2)
  expect_equal(withdrawal_cohorts(h, price = "p", inflation = "r", years = 1, inflation_type = "rate_pa")$inflation,
               withdrawal_cohorts(h, price = "p", inflation = 2, years = 1)$inflation, tolerance = 1e-13)
  expect_identical(withdrawal_cohorts(h, price = "p", inflation = 2, years = 1, inflation_type = "rate_pa"),
                   withdrawal_cohorts(h, price = "p", inflation = 2, years = 1))
  expect_error(withdrawal_cohorts(h, price = "p", inflation = "r", years = 1, inflation_type = "niveau"), "should be one of|'arg' should be")
})
