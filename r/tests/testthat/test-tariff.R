# Einkommensteuertarif als Datei (read_tax_tariff, § 32a Abs. 1 EStG, §§ 3, 4 SolZG ab VZ 2026)
.tt <- function() read_tax_tariff()
.T <- function(x, tt = .tt()) SimLev:::.tariff_income_tax(tt, x)
.S <- function(e, tt = .tt()) SimLev:::.tariff_soli(tt, e)
.tt_file <- function(lines) { f <- tempfile(fileext = ".csv"); writeLines(lines, f); f }
.tt_ok <- c("# Geltung: Testtarif", "art,ab,bezug,teiler,a,b,c", "zone,0,0,1,0,0,0",
            "zone,10001,10000,1,0,0.2,0", "soli,20350,,,5.5,11.9,")

test_that("Tarif: mitgelieferte Datei, Geltung und print", {
  tt <- .tt()
  expect_s3_class(tt, "SimLevTaxTariff")
  expect_identical(tt$geltung, "ab VZ 2026")
  expect_equal(tt$zones$ab, c(0, 12349, 17800, 69879, 277826))
  expect_equal(unlist(tt$soli), c(freigrenze = 20350, satz = 5.5, milderung = 11.9))
  out <- capture.output(print(tt))
  expect_true(any(grepl("Geltung: ab VZ 2026", out, fixed = TRUE)))
  expect_true(any(grepl("69 879 - 277 825", out, fixed = TRUE)))
  expect_true(any(grepl("Soli: 5.5 % der ESt, wenn die ESt 20 350 EUR \u00fcbersteigt", out, fixed = TRUE)))
  # Datei ist mit Basis-R lesbar
  d <- read.csv(system.file("extdata", "steuertarif.csv", package = "SimLev"), comment.char = "#")
  expect_equal(names(d), c("art", "ab", "bezug", "teiler", "a", "b", "c"))
})

test_that("Tarif: Werte an allen Zonengrenzen und Stichproben (Handrechnung)", {
  tt <- .tt()
  # Zone 1 bis 12 348: 0; Zone 2 ab 12 349: y = 0,0001 -> 0,14 -> 0
  expect_equal(.T(12348, tt), 0); expect_equal(.T(12349, tt), 0)
  # 17 799: y = 0,5451 -> (914,51 y + 1400) y = 1034,872 -> 1034; 17 800: z = 0,0001 -> 1035,1097 -> 1035
  expect_equal(.T(17799, tt), 1034); expect_equal(.T(17800, tt), 1035)
  # 69 878: z = 5,2079 -> 18 213,063 -> 18 213; 69 879: 0,42 x - 11 135,63 = 18 213,55 -> 18 213
  expect_equal(.T(69878, tt), 18213); expect_equal(.T(69879, tt), 18213)
  # 277 825: 116 686,50 - 11 135,63 = 105 550,87; 277 826: 125 021,70 - 19 470,38 = 105 551,32
  expect_equal(.T(277825, tt), 105550); expect_equal(.T(277826, tt), 105551)
  # Stichproben: 15 000 (y = 0,2652) 435,598; 50 000 (z = 3,2201) 10 548,33; 100 000: 42 000 - 11 135,63
  expect_equal(.T(15000, tt), 435); expect_equal(.T(50000, tt), 10548); expect_equal(.T(100000, tt), 30864)
  expect_equal(.T(300000, tt), 115529)                       # 135 000 - 19 470,38
  # zvE auf volle Euro abrunden; negatives zvE: 0
  expect_equal(.T(17799.99, tt), 1034); expect_equal(.T(-5000, tt), 0)
})

test_that("Soli: Freigrenze, Milderungszone, voller Satz, Cent abrunden", {
  tt <- .tt()
  expect_equal(.S(20350, tt), 0)                    # Freigrenze nicht ueberschritten
  expect_equal(.S(20351, tt), 0.11)                 # min(1119,305; 0,119 x 1) = 0,119 -> 0,11
  expect_equal(.S(20994, tt), 76.63)                # 0,119 x 644 = 76,636 -> 76,63
  expect_equal(.S(30000, tt), 1148.35)              # Milderungszone 0,119 x 9650
  expect_equal(.S(37838, tt), 2081.07)              # 0,119 x 17 488 = 2081,072 < 0,055 x 37 838 = 2081,09
  expect_equal(.S(37839, tt), 2081.14)              # voller Satz: 0,055 x 37 839 = 2081,145 -> 2081,14
  expect_equal(.S(40000, tt), 2200)
})

test_that("Tarifdatei: Fehlermeldungen bei kaputter Datei, Warnung bei Sprung", {
  expect_error(read_tax_tariff(file.path(tempdir(), "gibt_es_nicht.csv")), "nicht gefunden")
  expect_error(read_tax_tariff(.tt_file(sub(",c$", ",x", .tt_ok))), "fehlen die Spalten c")
  expect_error(read_tax_tariff(.tt_file(sub("^zone,10001", "zonen,10001", .tt_ok))), "art = 'zonen'")
  expect_error(read_tax_tariff(.tt_file(sub("0.2,0$", "zwei,0", .tt_ok))), "Spalte 'b' in Datenzeile 2 .*nicht numerisch")
  expect_error(read_tax_tariff(.tt_file(sub("^zone,0,", "zone,5,", .tt_ok))), "erste Zone muss bei ab = 0")
  expect_error(read_tax_tariff(.tt_file(c(.tt_ok[1:3], "zone,0,0,1,0,0,0", .tt_ok[5]))), "streng aufsteigend")
  expect_error(read_tax_tariff(.tt_file(c(.tt_ok, "soli,1,,,1,1,"))), "genau eine soli-Zeile geben \\(gefunden: 2\\)")
  expect_error(read_tax_tariff(.tt_file(.tt_ok[-5])), "genau eine soli-Zeile geben \\(gefunden: 0\\)")
  expect_error(read_tax_tariff(.tt_file(sub("10000,1,0,0.2", "10000,0,0,0.2", .tt_ok))), "teiler muss > 0")
  expect_error(read_tax_tariff(.tt_file(sub("5.5,11.9", "155,11.9", .tt_ok))), "Zuschlagsatz \\(a\\) muss zwischen 0 und 100")
  # Sprung: 0,2 x 10001 = 2000,20 statt 0 an der Grenze
  expect_warning(read_tax_tariff(.tt_file(sub("10001,10000,1", "10001,0,1", .tt_ok))),
                 "springt an der Zonengrenze 10001 EUR um 2000.20 EUR")
  expect_no_warning(read_tax_tariff(.tt_file(.tt_ok)))
})

test_that("Eigene Tarifdatei wirkt in simulation() (Datei und Objekt)", {
  # flacher Testtarif: 20 % ueber 10 000 EUR; § 23-Gewinn 2500 bei zvE 50 000 -> 500 EUR ESt, kein Soli
  f <- .tt_file(.tt_ok)
  expect_equal(.T(50000, read_tax_tariff(f)), 8000)
  d <- seq.Date(as.Date("2020-01-01"), as.Date("2021-03-31"), by = "day")
  df <- data.frame(date = d, G = ifelse(d < as.Date("2020-06-01"), 100, 150), H = 50)
  df$ev <- d == as.Date("2020-07-01"); df$wG <- 0; df$wH <- 1
  st <- create_strategy(G = asset_config("etc", "bnh", asset_share = 0.5, asset_spread = 0, deliverable = TRUE),
                        H = asset_config("certificate", "bnh", asset_share = 0.5, asset_spread = 0))
  run <- function(...) suppressMessages(simulation(df, st, start_value = 1e4, tax_mode = "person", taxable_income = 50000,
                                                   event_col = "ev", event_mode = "replace", event_weight = c(G = "wG", H = "wH"), ...))
  expect_equal(run(tax_tariff = f)$tax_report$total_taxes_paid, 500)
  expect_equal(run(tax_tariff = read_tax_tariff(f))$tax_report$total_taxes_paid, 500)
  expect_equal(run()$tax_report$total_taxes_paid, 11437 - 10548)        # mitgelieferter Tarif: T(52 500) - T(50 000)
  expect_error(run(tax_tariff = 42), "tax_tariff muss NULL")
})

test_that("R5-02: Plausibilitaet der Zonen (Grenzsteuersatz, T(x) <= x) und Trennzeichen", {
  base <- c("art,ab,bezug,teiler,a,b,c", "zone,0,0,1,0,0,0")
  soli <- "soli,20350,,,5.5,11.9,"
  # b = 42 statt 0.42 (Prozent statt Anteil): Fehler mit Zeile, Wert und Einheitenhinweis
  expect_error(read_tax_tariff(.tt_file(c(base, "zone,10001,0,1,0,42,-420042", soli))),
               "Zone ab 10001 EUR \\(Datenzeile 2\\): Grenzsteuersatz 42 bei x = 10001 EUR liegt nicht zwischen 0 und 1.*0.42 f\u00fcr 42 %, nicht 42.*Soli-S\u00e4tze dagegen in Prozent")
  # negativer Grenzsteuersatz
  expect_error(read_tax_tariff(.tt_file(c(base, "zone,10001,0,1,0,-0.1,1000.1", soli))), "Grenzsteuersatz -0.1 bei x = 10001")
  # quadratische letzte Zone: Grenzsteuersatz am oberen Rand (10 Mio. EUR) ueber 1
  expect_error(read_tax_tariff(.tt_file(c(base, "zone,10001,10000,10000,500,1000,0", soli))),
               "Grenzsteuersatz 100 bei x = 10000000 EUR")
  # Steuer groesser als das Einkommen (Konstante c zu gross)
  expect_error(read_tax_tariff(.tt_file(c(base, "zone,10001,0,1,0,0.2,50000", soli))),
               "Steuer 52000.20 EUR bei x = 10001 EUR \u00fcbersteigt das Einkommen")
  # Semikolon-CSV (deutsches Excel) und Dezimalkomma
  expect_error(read_tax_tariff(.tt_file(gsub(",", ";", .tt_ok))), "nur eine Spalte gelesen.*Semikolon")
  expect_error(read_tax_tariff(.tt_file(sub("0.2,0$", "0,2,0", .tt_ok))),
               "hat die Zeile 'zone,10001,10000,1,0,0,2,0' 8 Felder, die Kopfzeile 7.*Punkt \\(0.42, nicht 0,42\\)")
  # mitgelieferte Datei besteht alle Pruefungen ohne Warnung; Kopf nennt die Einheiten
  expect_no_warning(read_tax_tariff())
  hd <- readLines(system.file("extdata", "steuertarif.csv", package = "SimLev"))
  expect_true(any(grepl("Grenzsteuersatz als ANTEIL, 0.42 fuer 42 % (NICHT 42)", hd, fixed = TRUE)))   # Kopf der Tarifdatei (inst/extdata)
  expect_true(any(grepl("soli: PROZENT", hd, fixed = TRUE)))
})
