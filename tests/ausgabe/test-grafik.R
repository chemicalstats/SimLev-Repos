# test-grafik.R
# Grafiken des R-Pakets (Basisgrafik: Dashboard plot.SimLevResult/export_dashboard und die plot-Methoden der
# Analyseobjekte). Die Referenzfälle tests/<gruppe>/faelle vergleichen keine R-Grafiken; Python und Julia zeichnen
# eigenes SVG und prüfen es in ihren eigenen Tests. Die Blöcke stammen wörtlich aus den Testdateien bis 1.4.0
# (je Quelle mit ihren Hilfsdefinitionen in local()); ausgewählt sind die Blöcke, die Grafikcode erreichen, den
# keine anderen Tests oder Referenzfälle erreichen (Zeilenabdeckung mit covr), dazu die Dashboard-Prüfungen.
testthat::local_edition(3)   # Edition 3 wie bisher (Config/testthat/edition in r/DESCRIPTION entfällt)

# ── aus test-review7-stats.R (9 Blöcke) ──
local({

test_that("C7-08: plot.SimLevResult prueft panels, warnt ohne style = 'custom' und ergaenzt Teilfarben", {
  set.seed(7); n <- 500
  data <- data.frame(date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = n), ETF = 100 * cumprod(1 + rnorm(n, 4e-4, 0.012)))
  r <- suppressWarnings(simulation(data, create_strategy(ETF = asset_config("etf", share = 1))))
  grDevices::pdf(NULL); on.exit(grDevices::dev.off(), add = TRUE)
  # vorher: kein Fehler, leeres Layout
  expect_error(plot(r, style = "custom", panels = c("perfromance", "drawdwon")), "unbekannte\\(s\\) Panel\\(s\\) \"perfromance\", \"drawdwon\"")
  expect_error(plot(r, style = "custom", panels = c("performance", "xyz")), "\"xyz\"")
  expect_silent(plot(r, style = "custom", panels = c("perf", "draw", "performance")))
  # vorher: still ignoriert
  expect_warning(plot(r, panels = "performance"), "panels wirkt nur mit style = \"custom\"")
  expect_silent(plot(r, style = "compact"))
  # vorher: graphical parameter "bg" has the wrong length
  expect_silent(plot(r, colors = list(primary = "#003366")))
  expect_silent(plot(r, colors = c(primary = "#003366", negative = "#AA0000")))
  expect_error(plot(r, colors = list(primry = "#003366")), "unbekannte Farbe\\(n\\) 'primry'")
  expect_error(plot(r, colors = "#003366"), "colors muss eine benannte Liste")
})

test_that("plot(colors =) akzeptiert R-Farbnamen, prueft Farbwerte, Transparenz per adjustcolor()", {
  set.seed(7); n <- 500
  data <- data.frame(date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = n), ETF = 100 * cumprod(1 + rnorm(n, 4e-4, 0.012)))
  r <- suppressWarnings(simulation(data, create_strategy(ETF = asset_config("etf", share = 1))))
  grDevices::pdf(NULL); on.exit(grDevices::dev.off(), add = TRUE)
  # vorher: invalid color name 'navy30' bzw. 'darkred40'
  expect_silent(plot(r, colors = list(primary = "navy")))
  expect_silent(plot(r, colors = list(negative = "darkred", positive = "forestgreen")))
  expect_silent(plot(r, colors = list(primary = "#00336680")))            # eigene Transparenz wird multipliziert
  # vorher: invalid RGB specification (bzw. kryptisch je nach Farbe)
  expect_error(plot(r, colors = list(primary = "navyy")), "ung\u00fcltige Farbe\\(n\\) in colors: 'primary'")   # seit 1.6.4 ohne Wert (Entscheidung 8)
  expect_error(plot(r, colors = list(primary = "#12345")), "in colors: 'primary'")   # seit 1.6.4 ohne Wert
  expect_error(plot(r, colors = list(grid = NA)), "in colors: 'grid'")   # seit 1.6.4 ohne Wert
  expect_error(plot(r, colors = list(primary = c("red", "blue"))), "ung\u00fcltige Farbe")
  # Standardfarben: adjustcolor() ergibt dieselben RGBA-Werte wie das fruehere Hex-Suffix
  for (cl in c("#2E86AB", "#D62246")) for (a in c("30", "40", "80"))
    expect_identical(grDevices::adjustcolor(cl, alpha.f = strtoi(a, 16L) / 255), paste0(cl, a))
})

test_that("Layout style = 'custom': 3/5/7 Panels ohne Warnung, jedes Panel genau einmal (freie Felder leer)", {
  lay <- SimLev:::.dash_custom_layout
  for (k in 1:8) {
    m <- lay(k)
    expect_identical(sort(as.vector(m[m > 0])), seq_len(k))                 # jedes Panel genau einmal
    expect_identical(sum(m == 0), if (k %% 2 && k > 1) 1L else 0L)          # hoechstens ein leeres Feld
  }
  # gerade Anzahl und 1 Panel: wie bisher matrix(1:k, nrow = ..., byrow = TRUE)
  expect_identical(lay(1), matrix(1L, 1)); expect_identical(lay(2), matrix(1:2, nrow = 1))
  expect_identical(lay(4), matrix(1:4, nrow = 2, byrow = TRUE)); expect_identical(lay(6), matrix(1:6, nrow = 3, byrow = TRUE))
  expect_identical(lay(8), matrix(1:8, nrow = 4, byrow = TRUE))
  expect_identical(lay(3), matrix(c(1L, 2L, 3L, 0L), nrow = 2, byrow = TRUE))   # vorher matrix(1:3, nrow = 2): Panel 1 doppelt, Warnung
  set.seed(7); n <- 500
  data <- data.frame(date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = n), ETF = 100 * cumprod(1 + rnorm(n, 4e-4, 0.012)))
  r <- suppressWarnings(simulation(data, create_strategy(ETF = asset_config("etf", share = 1))))
  grDevices::pdf(NULL); on.exit(grDevices::dev.off(), add = TRUE)
  # Beispiel aus der Hilfeseite: vorher "data length [3] is not a sub-multiple or multiple of the number of rows [2]"
  expect_silent(plot(r, style = "custom", panels = c("performance", "drawdown", "distribution")))
  expect_silent(plot(r, style = "custom", panels = c("performance", "drawdown", "distribution", "rolling", "monthly")))
  expect_silent(plot(r, style = "custom", panels = c("performance", "drawdown", "distribution", "rolling", "monthly", "stats", "correlation"),
                     compare = r))   # "correlation" braucht compare
})

test_that("Panel performance: y-Achse \u00fcber alle Kurven (Vergleich, Einzahlungen), ohne compare unver\u00e4ndert", {
  set.seed(7); n <- 500
  d <- data.frame(date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = n), ETF = 100 * cumprod(1 + rnorm(n, 4e-4, 0.012)),
                  B = 100 * cumprod(1 + rnorm(n, -6e-4, 0.008)), C = 100 * cumprod(1 + rnorm(n, -1e-3, 0.01)))
  S <- function(...) suppressWarnings(suppressMessages(simulation(...)))
  r <- S(d, create_strategy(ETF = asset_config("etf", share = 1)))
  r2 <- S(d, create_strategy(B = asset_config("etf", share = 1)))       # liegt unter r
  rl <- S(d, create_strategy(C = asset_config("etf", share = 1)), dca = dca_plan(value = 500, span = 1))
  inv <- SimLev:::.dashboard_returns(rl)$invested
  expect_gt(max(inv), max(rl$worth))                                           # Einzahlungen ueber dem Depotwert
  grDevices::pdf(NULL); on.exit(grDevices::dev.off(), add = TRUE)
  ylims <- function(...) {                                                      # ylim des Panels mitschneiden
    e <- new.env(); e$u <- list()
    suppressMessages(trace("plot.window", exit = bquote(assign("u", c(get("u", envir = .(e)), list(ylim)), envir = .(e))), where = graphics::plot.default, print = FALSE))
    on.exit(suppressMessages(untrace("plot.window", where = graphics::plot.default)))
    plot(..., style = "custom", panels = "performance"); e$u[[1]]
  }
  # vorher range(r$worth): Vergleichskurve unten bzw. oben abgeschnitten
  expect_equal(ylims(r, compare = r2), range(c(r$worth, r2$worth)))
  expect_equal(ylims(r2, compare = r), range(c(r$worth, r2$worth)))
  expect_lt(ylims(r, compare = r2)[1], min(r$worth))
  # vorher: Einzahlungslinie oben abgeschnitten
  expect_equal(ylims(rl), range(c(rl$worth, inv)))
  # ohne compare und Sparplan: wie bisher
  expect_equal(ylims(r), range(r$worth))
})

test_that("Dashboard: Raender passen zu den Beschriftungen (nichts abgeschnitten), alle Stile ohne Warnung", {
  set.seed(7); n <- 3 * 365
  d <- data.frame(date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = n), ETF = 100 * cumprod(1 + rnorm(n, 4e-4, 0.012)),
                  B = 100 * cumprod(1 + rnorm(n, 1e-4, 0.008)))
  S <- function(...) suppressWarnings(suppressMessages(simulation(...)))
  r <- S(d, create_strategy(ETF = asset_config("etf", share = 0.6), B = asset_config("etf", share = 0.4)), start_value = 250000)
  r2 <- S(d, create_strategy(B = asset_config("etf", share = 1)), start_value = 250000)
  # y-Achsen (Depotwert, Monats-Heatmap): linker Rand >= Breite der Tick-Labels + Abstand + Achsentitel
  # (vorher 4 bzw. 5 Zeilen fest: "250 Tsd. EUR" abgeschnitten, "Depotwert" ueberlappte die Labels)
  e <- new.env(); e$ax <- list(); e$tx <- list()
  grab_ax <- bquote(if (side == 2 && is.character(labels)) assign("ax", c(get("ax", envir = .(e)), list(c(
    mar = par("mar")[2], need = max(strwidth(labels, units = "inches", cex = par("cex.axis"))) / par("csi")))), envir = .(e)))
  grab_tx <- bquote(if (isTRUE(is.na(list(...)$xpd))) assign("tx", c(get("tx", envir = .(e)), list(c(
    mar = par("mar")[4], need = max(strwidth(labels, units = "inches", cex = cex, font = font)) / par("csi")))), envir = .(e)))
  suppressMessages({ trace("axis", exit = grab_ax, where = graphics::plot.default, print = FALSE)
                     trace("text.default", exit = grab_tx, where = graphics::plot.default, print = FALSE) })
  on.exit(suppressMessages({ untrace("axis", where = graphics::plot.default); untrace("text.default", where = graphics::plot.default) }), add = TRUE)
  for (sz in list(c(480, 480), c(1400, 1000))) {
    grDevices::png(tf <- tempfile(fileext = ".png"), sz[1], sz[2])
    expect_silent(plot(r, compare = r2)); expect_silent(plot(r, style = "compact"))
    expect_silent(plot(r, style = "custom", panels = c("performance", "rolling", "monthly")))
    grDevices::dev.off(); unlink(tf)
  }
  ax <- do.call(rbind, e$ax); tx <- do.call(rbind, e$tx)
  expect_gt(nrow(ax), 5)
  expect_true(all(ax[, "mar"] >= ax[, "need"] + 2))     # Labels (Abstand 1 Zeile) plus Achsentitel
  expect_gt(nrow(tx), 3)
  expect_true(all(tx[, "mar"] >= tx[, "need"] + 0.5))   # Endwert-Label im rechten Rand
  # export_dashboard() (PDF, 14 x 10 Zoll) mit compare laeuft durch
  tf <- tempfile(fileext = ".pdf"); invisible(utils::capture.output(export_dashboard(r, tf, compare = r2)))
  expect_true(file.exists(tf)); unlink(tf)
})

test_that("Strategievergleich: Gruen = Strategie 1 besser, bei Max. DD und Volatilit\u00e4t also kleiner", {
  set.seed(7); n <- 3 * 365
  d <- data.frame(date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = n), ETF = 100 * cumprod(1 + rnorm(n, 4e-4, 0.012)),
                  B = 100 * cumprod(1 + rnorm(n, 1e-4, 0.008)))
  S <- function(...) suppressWarnings(suppressMessages(simulation(...)))
  r <- S(d, create_strategy(ETF = asset_config("etf", share = 0.6), B = asset_config("etf", share = 0.4)))
  r2 <- S(d, create_strategy(B = asset_config("etf", share = 1)))
  pos <- "#06A77D"; neg <- "#D62246"; neu <- "#6C757D"
  diff_cols <- function(a, b) {                            # Farben der Differenzspalte (x = 0.95) mitschneiden
    e <- new.env(); e$v <- list()
    suppressMessages(trace("text.default", exit = bquote(if (identical(x$x, 0.95) && grepl("^[+-][0-9]", labels))
      assign("v", c(get("v", envir = .(e)), list(c(labels, col))), envir = .(e))), where = graphics::plot.default, print = FALSE))
    on.exit(suppressMessages(untrace("text.default", where = graphics::plot.default)))
    grDevices::pdf(NULL); plot(a, style = "custom", panels = "comparison", compare = b); grDevices::dev.off()
    m <- do.call(rbind, e$v); stats::setNames(m[, 2], c("cagr", "maxdd", "vol", "sharpe"))
  }
  dd <- c(max(r$drawdowns), max(r2$drawdowns)); expect_true(dd[1] > dd[2])   # r hat den groesseren Drawdown
  cl <- diff_cols(r, r2)
  expect_identical(unname(cl["maxdd"]), neg)                    # vorher gruen (positive Differenz)
  expect_identical(unname(cl[c("cagr", "sharpe")]), unname(ifelse(c(r$cagr > r2$cagr, r$statistics$sharpe > r2$statistics$sharpe), pos, neg)))
  cl2 <- diff_cols(r2, r)                                       # vertauscht: kleinerer Drawdown = gruen
  expect_identical(unname(cl2["maxdd"]), pos)
  expect_identical(unname(diff_cols(r, r)), rep(neu, 4))         # Gleichstand neutral (vorher rot)
})

test_that("Dashboard-Betr\u00e4ge: Kennzahlen mit vollen Betraegen, Endwert-Label mit 3 Stellen, Achsenwerte exakt", {
  set.seed(42); n <- 365 * 4
  d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n), A = 100 * cumprod(1 + rnorm(n, 4e-4, 0.010)))
  r <- suppressWarnings(suppressMessages(simulation(d, create_strategy(A = asset_config("etf", share = 1)), start_value = 10000)))
  e <- new.env(); e$tx <- character(); e$ax <- list()
  suppressMessages({
    trace("text.default", exit = bquote(assign("tx", c(get("tx", envir = .(e)), as.character(labels)), envir = .(e))),
          where = graphics::plot.default, print = FALSE)
    trace("axis", exit = bquote(if (side == 2 && is.character(labels)) assign("ax", c(get("ax", envir = .(e)), list(list(at = at, lab = labels))), envir = .(e))),
          where = graphics::plot.default, print = FALSE) })
  on.exit(suppressMessages({ untrace("text.default", where = graphics::plot.default); untrace("axis", where = graphics::plot.default) }), add = TRUE)
  grDevices::pdf(NULL); plot(r, style = "custom", panels = c("performance", "stats")); grDevices::dev.off()
  fin <- tail(r$worth, 1); u <- if (fin >= 1e6) 1e6 else 1e3
  # vorher: "Endwert: 18 Tsd. EUR" bzw. Endwert-Label "18 Tsd."
  expect_true(sprintf("Endwert: %.2f EUR", fin) %in% e$tx)
  expect_true(sprintf("Startkapital: %.2f EUR", r$invested[1]) %in% e$tx)   # brutto, vor Kaufkosten
  expect_identical(r$invested[1], 10000)
  expect_true(sprintf("%.*f %s", 2L - as.integer(floor(log10(fin / u))), fin / u, if (u == 1e6) "Mio." else "Tsd.") %in% e$tx)
  # aelteres Ergebnis ohne invested: Depotwert am Starttag mit eigener Beschriftung
  r_old <- r; r_old$invested <- NULL; e$tx <- character()
  grDevices::pdf(NULL); plot(r_old, style = "custom", panels = "stats"); grDevices::dev.off()
  expect_true(sprintf("Depotwert Starttag: %.2f EUR", r$worth[1]) %in% e$tx)
  # Achsenwerte der Wertachse: Beschriftung entspricht exakt dem Tick (z. B. 12.5 Tsd. statt 12 Tsd.)
  a <- e$ax[[1]]; mult <- ifelse(grepl("Mio", a$lab), 1e6, ifelse(grepl("Tsd", a$lab), 1e3, 1))
  expect_equal(as.numeric(sub(" .*", "", a$lab)) * mult, a$at)
})

test_that("Startkapital ohne die Sparrate des Starttags (start_value)", {
  set.seed(42); n <- 365 * 2
  d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n),
                  W = 100 * cumprod(1 + rnorm(n, 4e-4, 0.010)), B = 50 * cumprod(1 + rnorm(n, 1e-4, 0.003)))
  r <- suppressWarnings(suppressMessages(simulation(d, create_strategy(W = asset_config("etf", share = 0.7), B = asset_config("etf", share = 0.3)), start_value = 10000, dca = dca_plan(value = 250, span = 1, unit = "month"))))
  expect_identical(r$invested[1], 10250)                       # Startkapital + erste Sparrate am Starttag
  e <- new.env(); e$tx <- character()
  suppressMessages(trace("text.default", exit = bquote(assign("tx", c(get("tx", envir = .(e)), as.character(labels)), envir = .(e))),
                         where = graphics::plot.default, print = FALSE))
  on.exit(suppressMessages(untrace("text.default", where = graphics::plot.default)), add = TRUE)
  grDevices::pdf(NULL); plot(r, style = "custom", panels = "stats"); grDevices::dev.off()
  expect_true("Startkapital: 10000.00 EUR" %in% e$tx)            # vorher 10250.00 EUR
  expect_true(sprintf("Eingezahlt: %.2f EUR", tail(r$invested, 1)) %in% e$tx)   # Summe inkl. aller Sparraten
})

test_that("Korrelation = rollierende Korrelation Strategie/Vergleich; ohne compare Warnung statt Leerfeld", {
  set.seed(42); n <- 365 * 3
  d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n),
                  W = 100 * cumprod(1 + rnorm(n, 4e-4, 0.010)), B = 50 * cumprod(1 + rnorm(n, 1e-4, 0.003)))
  S <- function(...) suppressWarnings(suppressMessages(simulation(...)))
  r1 <- S(d, create_strategy(W = asset_config("etf", share = 0.7), B = asset_config("etf", share = 0.3)))
  r2 <- S(d, create_strategy(B = asset_config("etf", share = 1)))
  e <- new.env(); e$tx <- character()
  suppressMessages(trace("text.default", exit = bquote(assign("tx", c(get("tx", envir = .(e)), as.character(labels)), envir = .(e))),
                         where = graphics::plot.default, print = FALSE))
  on.exit(suppressMessages(untrace("text.default", where = graphics::plot.default)), add = TRUE)
  grDevices::pdf(NULL); on.exit(grDevices::dev.off(), add = TRUE)
  # full mit compare: Korrelationspanel mit Gesamtkorrelation (vorher Platzhalter "Benoetigt Kursdaten je Asset")
  expect_silent(plot(r1, compare = r2))
  rho <- stats::cor(SimLev:::.dashboard_returns(r1)$all_returns, SimLev:::.dashboard_returns(r2)$all_returns)
  expect_true(sprintf("Gesamt: %.2f", rho) %in% e$tx)
  expect_false(any(grepl("Kursdaten je Asset", e$tx)))
  # custom ohne compare: Warnung mit Grund (vorher still leer); nichts zeichenbar -> Hinweisfeld
  expect_warning(plot(r1, style = "custom", panels = c("performance", "correlation", "comparison")),
                 "Panel\\(s\\) \"correlation\", \"comparison\" nicht gezeichnet: ben\u00f6tigen ein Vergleichsergebnis \\(compare\\)")
  e$tx <- character()
  expect_warning(plot(r1, style = "custom", panels = "comparison"), "\"comparison\" nicht gezeichnet")
  expect_true(any(grepl("^Keine zeichenbaren Panels", e$tx)))
  # full ohne compare: kein Korrelationspanel, keine Warnung
  expect_silent(plot(r1))
  # compare ueber andere Tage: klare Meldung (vorher Absturz in lines())
  expect_error(plot(r1, compare = S(d[1:400, ], create_strategy(B = asset_config("etf")))), "compare muss ein SimLevResult \u00fcber dieselben Tage")
})
})

# ── aus test-blue-engine.R (1 Blöcke) ──
local({
.bt_cal <- function(from, to, ...) {
  dd <- seq.Date(as.Date(from), as.Date(to), by = "day"); data.frame(date = dd, ...)
}
.bt_st1 <- function(...) create_strategy(A = asset_config("etf", share = 1, spread = 0, ...))

test_that("Dashboard-Kennzahlen wie statistics, kurze Reihen und PDF-Export robust", {
  set.seed(12); n <- 3 * 365
  d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n), A = 100 * cumprod(1 + rnorm(n, 4e-4, 0.01)))
  r <- simulation(d, .bt_st1(), dca = dca_plan(value = 5000, span = 1))
  dr <- SimLev:::.dashboard_returns(r)
  expect_equal(sd(dr$returns), r$statistics$sd, tolerance = 1e-12)
  expect_lt(max(dr$returns), 0.1)                         # Einzahlungen sind keine Renditen
  expect_equal(dr$ppy, (n - 1) / ((n - 1) / 365.25))
  pdf(NULL); on.exit(dev.off(), add = TRUE)
  expect_silent(plot(r))
  expect_silent(plot(simulation(d[1:3, ], .bt_st1())))
  f <- tempfile(fileext = ".pdf"); nd <- length(dev.list())
  bad <- r; bad$worth <- NULL
  # Absichtlich zerstoertes Objekt (ohne worth): Geprueft wird nur, dass das Geraet nach dem Abbruch geschlossen ist.
  # Auf dem Weg zum Fehler meldet range() in plot.SimLevResult fuer das leere worth zwei Warnungen (min/max ohne
  # Werte); erwartet und hier gezielt unterdrueckt, jede andere Warnung bleibt sichtbar.
  expect_error(withCallingHandlers(suppressMessages(export_dashboard(bad, f)), warning = function(w)
    if (grepl("^no non-missing arguments to (min|max)", conditionMessage(w))) invokeRestart("muffleWarning")))
  expect_equal(length(dev.list()), nd)
})
})

# ── aus test-research.R (2 Blöcke) ──
local({
make_px <- function(n = 365 * 10, seed = 1, mu = 3e-4, sd = 0.011) {
  set.seed(seed)
  d <- data.frame(date = seq.Date(as.Date("2008-01-01"), by = "day", length.out = n))
  d$A <- 100 * cumprod(1 + rnorm(n, mu, sd))
  d
}

test_that("param_search reproduces simulation(), keeps returns and supports overfitting checks", {
  d <- make_px(365 * 12)
  st <- create_strategy(A = asset_config("etf", "signal", signal_buy = "buy", signal_sell = "sell", spread = 0))
  b <- function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, p$band))
  ps <- param_search(d, b, param_space(n = c(50, 100, 200), band = c(0, 2)), burn_in = 250)
  expect_s3_class(ps, "SimLevParamSearch")
  expect_equal(nrow(ps$results), 6L)
  expect_equal(dim(ps$returns), c(nrow(d) - 251L, 6L))
  # Punkt 4 (n = 100, band = 2) direkt nachrechnen
  dd <- d; sg <- signal_sma(dd$A, 100, 2); dd$buy <- sg$buy; dd$sell <- sg$sell
  r <- suppressMessages(simulation(dd[251:nrow(dd), ], st))
  row <- ps$results[ps$results$n == 100 & ps$results$band == 2, ]
  expect_equal(row$cagr, r$cagr, tolerance = 1e-12)
  ix <- result_index(r)$value
  expect_equal(ps$returns[, row$id], ix[-1] / ix[-length(ix)] - 1, tolerance = 1e-12)
  # ohne builder: simulation()-Argumente
  st2 <- create_strategy(A = asset_config("etf", "bnh", 0.5), B = asset_config("etf", "bnh", 0.5))
  d$B <- 100 * cumprod(1 + rnorm(nrow(d), 1e-4, 0.004))
  ps2 <- param_search(d, space = param_space(rebalance.thresh = c(2, 5, 10)), strategy = st2,
                      sim_args = list(rebalance = rebalance_plan(span = 1, unit = "month")))
  expect_identical(ps2$params, "rebalance.thresh"); expect_true("rebalance.thresh" %in% names(ps2$results))
  expect_error(param_search(d, space = param_space(balance_thresh = 2), strategy = st2),
               "param_search: balance_thresh gibt es nicht mehr; bitte rebalance = rebalance_plan\\(thresh = ")
  r2 <- simulation(d, st2, rebalance = rebalance_plan(span = 1, unit = "month", thresh = 5))
  expect_equal(ps2$results$cagr[2], r2$cagr)
  # Fehler werden je Punkt protokolliert
  bad <- param_search(d, function(p) if (p$n > 60) stop("kaputt") else b(p), param_space(n = c(50, 100), band = 0), burn_in = 250)
  expect_true(is.na(bad$results$error[1]) && grepl("kaputt", bad$results$error[2]))
  # Plateau
  pl <- param_plateau(ps)
  expect_equal(pl$neighbours, c(4, 6, 4, 4, 6, 4))
  expect_equal(pl$plateau_mean[1], mean(ps$results$sharpe[c(1, 2, 4, 5)]))
  expect_output(print(ps), "Bestes Plateau")
  pdf(NULL); on.exit(dev.off(), add = TRUE)
  expect_silent(plot(ps)); expect_silent(plot(ps, params = "n"))
  # Ueberanpassung
  pb <- overfit_pbo(ps, S = 8)
  expect_s3_class(pb, "SimLevPBO"); expect_equal(pb$n_combos, choose(8, 4))
  expect_true(pb$pbo >= 0 && pb$pbo <= 1)
  ds <- sharpe_deflated(ps)
  expect_true(ds$n_eff >= 1 && ds$n_eff <= 6)
  expect_true(ds$dsr <= ds$psr + 1e-12)
  wf <- overfit_walk_forward(ps, train = 4, test = 2)
  expect_s3_class(wf, "SimLevWalkForward")
  W <- wf$windows
  expect_true(all(W$test_start[-1] > W$test_end[-nrow(W)]))
  rows <- which(ps$dates >= W$test_start[1] & ps$dates <= W$test_end[1])
  expect_equal(wf$series$walk_forward[length(rows)], prod(1 + ps$returns[rows, W$id[1]]), tolerance = 1e-10)
  expect_output(print(wf), "Walk-Forward")
  expect_silent(plot(pb)); expect_silent(plot(wf))
  expect_output(print(ds), "Deflated")
})

test_that("quantile regression, DCC and dependence analysis with third variables", {
  set.seed(2); x <- rnorm(600); y <- 1 + 2 * x + rnorm(600) * (1 + abs(x))
  qr0 <- quantile_regression(y, NULL, 0.3)
  ys <- sort(y); chk <- function(b) sum((y - b) * (0.3 - (y < b)))
  expect_true(qr0 >= ys[180] - 1e-6 && qr0 <= ys[181] + 1e-6)          # Loesungsmenge [y(180), y(181)]
  expect_equal(chk(qr0), chk(ys[180]), tolerance = 1e-8)
  # exakte Loesung: Die LP-Loesung interpoliert zwei Beobachtungen -> alle Paare pruefen
  xs <- x[1:40]; ysm <- y[1:40]; loss <- function(b) sum((ysm - b[1] - b[2] * xs) * (0.9 - (ysm < b[1] + b[2] * xs)))
  pr <- combn(40, 2); best <- Inf
  for (j in seq_len(ncol(pr))) { i1 <- pr[1, j]; i2 <- pr[2, j]
    b2 <- (ysm[i2] - ysm[i1]) / (xs[i2] - xs[i1]); best <- min(best, loss(c(ysm[i1] - b2 * xs[i1], b2))) }
  expect_equal(loss(quantile_regression(ysm, xs, 0.9)), best, tolerance = 1e-7)
  n <- 365 * 16
  d <- data.frame(date = seq.Date(as.Date("2000-01-01"), by = "day", length.out = n))
  infl <- rep(rep(c(1, 5), each = 365), length.out = n)
  e1 <- rnorm(n); e2 <- rnorm(n); rho <- ifelse(infl > 3, 0.6, -0.4)
  d$stocks <- 100 * exp(cumsum(0.01 * e1)); d$bonds <- 100 * exp(cumsum(0.005 * (rho * e1 + sqrt(1 - rho^2) * e2)))
  d$inflation <- infl
  da <- dependence_analysis(d, c("stocks", "bonds"), conditions = "inflation", breaks = list(inflation = c(-Inf, 3, Inf)),
                            B = 99, seed = 1)
  expect_s3_class(da, "SimLevDependence")
  ct <- da$conditional$inflation
  expect_lt(ct$pearson[1], -0.2); expect_gt(ct$pearson[2], 0.4)
  expect_lt(da$differences$p_pearson, 0.05)
  expect_true(da$dcc$a > 0 && da$dcc$b > 0 && da$dcc$a + da$dcc$b < 1)
  expect_equal(nrow(da$dcc$correlation), nrow(da$returns))
  expect_output(print(da), "Bedingt auf")
  pdf(NULL); on.exit(dev.off(), add = TRUE)
  expect_silent(plot(da)); expect_silent(plot(da, "scatter"))
  # verzoegerter Zustand: Rendite der Periode t gehoert zum Zustand am Ende von t-1
  rr <- SimLev:::.dep_returns(d, "stocks", "inflation", "week")
  key <- format(d$date, "%G-%V"); ends <- which(c(key[-1] != key[-length(key)], TRUE))
  expect_equal(rr$inflation[10], d$inflation[ends[10]])
  tr <- tail_regression(d, "bonds", "inflation", quantiles = c(0.1, 0.5, 0.9), B = 19, seed = 1)
  expect_equal(nrow(tr$coefficients), 6L); expect_output(print(tr), "Quantilsregression")
  d$port <- 0.6 * d$stocks / d$stocks[1] + 0.4 * d$bonds / d$bonds[1]
  cv <- tail_covar(d, "port", c("stocks", "bonds"))
  expect_true(all(cv$summary$delta_covar < 0)); expect_output(print(cv), "CoVaR")
  expect_silent(plot(tr)); expect_silent(plot(cv))
})
})

# ── aus test-planning.R (2 Blöcke) ──
local({
mk_px <- function(n = 365 * 12, seed = 1, mu = 3.5e-4, sd = 0.01) {
  set.seed(seed)
  d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n))
  d$A <- 100 * cumprod(1 + rnorm(n, mu, sd))
  d
}

test_that("expected-return shift, pooled bootstrap, random horizon and goal planning", {
  d <- mk_px(3650)
  d$r <- c(1, d$A[-1] / d$A[-nrow(d)])
  d2 <- series_shift_return(d, "r", 4)
  yrs <- as.numeric(max(d$date) - min(d$date)) / 365.25
  # seit 1.6.5 (CR2-E-7): ppy = (n - 1) / Spanne; n Renditen decken n Perioden zu je 1 / ppy Jahren
  expect_equal(prod(d2$r)^((nrow(d) - 1) / (nrow(d) * yrs)) - 1, 0.04, tolerance = 1e-10)
  expect_equal(sd(log(d2$r)), sd(log(d$r)))
  mk <- function(mu, seed) { set.seed(seed); n <- 60
    data.frame(date = seq.Date(as.Date("1960-12-31"), by = "year", length.out = n),
               s = 100 * cumprod(c(1, exp(rnorm(n - 1, mu, 0.18)))), cpi = 100 * cumprod(c(1, rep(1.02, n - 1)))) }
  ds <- list(x = mk(0.07, 1), y = mk(0.01, 2))
  pb <- bootstrap_pooled(ds, "s", inflation = "cpi", n = 300, years = 30, seed = 1)
  expect_s3_class(pb, "withdrawal_paths"); expect_equal(dim(pb$returns), c(30L, 300L))
  expect_true(all(abs(pb$inflation - 1.02) < 1e-12))
  expect_lt(abs(mean(pb$countries == "x") - 0.5), 0.1)
  pt <- bootstrap_pooled(ds, "s", n = 300, years = 30, seed = 1, target = c(s = 5))
  expect_lt(abs(exp(mean(log(pt$assets$s))) - 1.05), 0.01)                  # Ziehungsrauschen um 5 %
  h <- withdrawal_horizon("discrete", years = c(20, 30), prob = c(0.5, 0.5))
  hh <- SimLev:::.draw_horizon(h, 1000); expect_setequal(unique(hh), c(20, 30))
  expect_identical(hh, SimLev:::.draw_horizon(h, 1000))
  w30 <- withdrawal_simulation(pb, withdrawal_rule("constant", rate = 4), years = 30)
  wf <- withdrawal_simulation(pb, withdrawal_rule("constant", rate = 4), horizon = 30)
  expect_equal(wf$paths$success, w30$paths$success)
  w20 <- withdrawal_simulation(pb, withdrawal_rule("constant", rate = 4), years = 20)
  wr <- withdrawal_simulation(pb, withdrawal_rule("constant", rate = 4), horizon = h)
  H <- wr$paths$horizon
  expect_equal(wr$paths$success, ifelse(H == 20, w20$paths$success, w30$paths$success))
  expect_equal(wr$paths$terminal_real[H == 20], w20$paths$terminal_real[H == 20], tolerance = 1e-8)
  expect_error(withdrawal_horizon("uniform", min = 30), "max")
  cand <- lapply(c(0, 0.5, 1), function(a) c(s = a, cpi = 1 - a)); names(cand) <- c("A0", "A50", "A100")
  Rc <- do.call(rbind, lapply(ds, function(x) portfolio_returns(x, cand, "year")))
  # Erwartete Warnung: Bei 118 diskreten Jahresrenditen und dem Standardraster (n_grid = 301) liegt der DP-Wert
  # (79,0 %) deutlich ueber der Vorwaertssimulation (67,1 %); die Kontrolle in planning_goal() meldet das, probability
  # ist der simulierte Wert. Mit feinerem Raster schliesst sich die Luecke (n_grid = 1001: 76,8 % gegen 73,8 %, ohne
  # Warnung), es ist also die vorgesehene Rastermeldung, kein Fehler.
  expect_warning(gp <- planning_goal(Rc, start_value = 100, goal = 200, horizon = 15, n_sim = 4000, seed = 1),
                 "planning_goal: DP-Wert 79.0 % weicht von der Vorw\u00e4rtssimulation 67.1 % ab", fixed = TRUE)
  expect_gte(gp$probability, max(gp$static) - 1e-9)
  expect_equal(mean(gp$simulation$success), gp$probability, tolerance = 0.03)
  expect_output(print(gp), "Zielplanung")
  pdf(NULL); on.exit(dev.off(), add = TRUE); expect_silent(plot(gp))
})

test_that("signal analysis, Sharpe tests, reality check, MinTRL, heatmap, HMM and real deep analysis", {
  set.seed(3); n <- 365 * 16
  d <- data.frame(date = seq.Date(as.Date("2000-01-01"), by = "day", length.out = n))
  st <- rep(rep(1:2, c(700, 300)), length.out = n)
  d$A <- 100 * exp(cumsum(ifelse(st == 1, rnorm(n, 4e-4, 0.006), rnorm(n, -3e-4, 0.02))))
  d$B <- 100 * exp(cumsum(rnorm(n, 1e-4, 0.004)))
  d$sig <- c(NA, diff(log(d$A)))
  sa <- signal_analysis(d, "sig", "A", horizon = 10, bins = 4, splits = 2)
  expect_equal(sum(sa$bins$n), nrow(sa$data)); expect_equal(dim(sa$splits), c(4L, 2L))
  t0 <- sharpe_test(d$A[-1] / d$A[-n] - 1, d$A[-1] / d$A[-n] - 1, ppy = 365)
  expect_equal(unname(t0["difference"]), 0)
  tt <- sharpe_test(data.frame(date = d$date, value = d$A), data.frame(date = d$date, value = d$B))
  expect_true(tt["p_value"] > 0 && tt["p_value"] <= 1)
  set.seed(4); R <- matrix(rnorm(800 * 10, 0, 0.01), 800); R[, 2] <- R[, 2] + 0.003
  rc <- overfit_reality_check(R, B = 200, frequency = "day", seed = 1)
  expect_lt(rc$p_spa, 0.05); expect_equal(rc$best, "p2")
  r <- d$B[-1] / d$B[-n] - 1; mt <- sharpe_min_track_record(r, ppy = 365)
  sr <- mean(r) / sd(r); zz <- (r - mean(r)) / sd(r)
  expect_equal(unname(mt["needed_periods"]), 1 + (1 - mean(zz^3) * sr + (mean(zz^4) - 1) / 4 * sr^2) * (qnorm(0.95) / sr)^2)
  hm <- result_heatmap(data.frame(date = d$date, value = d$A), max_years = 5)
  ye <- tapply(d$A, format(d$date, "%Y"), function(v) tail(v, 1))
  expect_equal(unname(hm$matrix["2001", "1"]), unname(ye["2001"] / ye["2000"] - 1))
  expect_equal(unname(hm$matrix["2001", "3"]), unname((ye["2003"] / ye["2000"])^(1 / 3) - 1))
  hmm <- regime_hmm(d, "A", k = 2)
  expect_gt(hmm$volatility[2, 1], 2 * hmm$volatility[1, 1])
  s_day <- regime_states(hmm, d$date)
  expect_gt(mean(s_day == st, na.rm = TRUE), 0.85)
  e <- hmm$dates[100]; expect_true(is.na(regime_states(hmm, e)) || regime_states(hmm, e) == max.col(hmm$filtered)[99])
  da <- result_analysis(data.frame(date = d$date, value = d$B), inflation = 2)
  dn <- result_analysis(data.frame(date = d$date, value = d$B))
  expect_equal((1 + da$metrics["cagr", 1]) * 1.02, 1 + dn$metrics["cagr", 1], tolerance = 1e-6)
  pdf(NULL); on.exit(dev.off(), add = TRUE)
  expect_silent(plot(sa)); expect_silent(plot(hm)); expect_silent(plot(hmm))
})
})

# ── aus test-analysis.R (1 Blöcke) ──
local({
make_two <- function(n = 365 * 8, seed = 1) {
  set.seed(seed)
  d <- data.frame(date = seq.Date(as.Date("2012-01-01"), by = "day", length.out = n))
  d$A <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.010))
  d$B <- 100 * cumprod(1 + rnorm(n, 1.5e-4, 0.004))
  d
}

test_that("result_analysis reproduces engine metrics and core identities", {
  d <- make_two()
  a <- simulation(d, create_strategy(A = asset_config("etf", "bnh", spread = 0)))
  b <- simulation(d, create_strategy(A = asset_config("etf", "bnh", 0.6), B = asset_config("etf", "bnh", 0.4)), dca = dca_plan(value = 300, span = 1), rebalance = rebalance_plan(span = 1, unit = "year"))
  da <- result_analysis(list(A = a, Mix = b), benchmark = "A")
  expect_s3_class(da, "SimLevAnalysis")
  expect_equal(unname(da$metrics["cagr", "A"]), a$ttwror, tolerance = 1e-10)
  expect_equal(unname(da$metrics["cagr", "Mix"]), b$ttwror, tolerance = 1e-10)
  expect_equal(unname(da$metrics["max_drawdown", "A"]), a$statistics$max_drawdown, tolerance = 1e-10)
  expect_equal(unname(da$metrics["mwrr", "A"]), unname(da$metrics["cagr", "A"]), tolerance = 1e-6)  # ohne Flows
  expect_false(isTRUE(all.equal(unname(da$metrics["mwrr", "Mix"]), unname(da$metrics["cagr", "Mix"]))))
  # Benchmark gegen sich selbst
  self <- result_analysis(list(A = a, A2 = a), benchmark = "A")
  bm <- self$benchmark_metrics[, "A2"]
  expect_equal(unname(bm[c("beta", "correlation", "up_capture", "down_capture")]), c(1, 1, 1, 1), tolerance = 1e-10)
  expect_equal(unname(bm[c("alpha", "tracking_error", "active_return")]), c(0, 0, 0), tolerance = 1e-10)
  # Jahresrenditen verketten sich zur Gesamtrendite
  expect_equal(prod(1 + da$annual[, "A"]) - 1, unname(da$metrics["total_return", "A"]), tolerance = 1e-10)
  expect_equal(dim(da$monthly$A)[2], 13L)
  expect_true(all(da$drawdowns$A$depth <= 0))
  expect_equal(-min(da$drawdowns$A$depth), unname(da$metrics["max_drawdown", "A"]), tolerance = 1e-10)
  expect_false(is.null(da$rolling$Mix))
  expect_output(print(da), "SimLev Detailanalyse")
  pdf(NULL); on.exit(dev.off(), add = TRUE)
  for (t in c("overview", "growth", "drawdown", "rolling", "annual", "monthly")) expect_silent(plot(da, t))
})
})

# ── aus test-tactical.R (2 Blöcke) ──
local({
make_mkt <- function(n = 365 * 8, seed = 1) {
  set.seed(seed)
  d <- data.frame(date = seq.Date(as.Date("2012-01-01"), by = "day", length.out = n))
  d$A <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.012)); d$B <- 100 * cumprod(1 + rnorm(n, 2e-4, 0.009))
  d$C <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.004)); d$CASH <- 100 * cumprod(rep(1 + 0.02 / 365, n))
  d
}

test_that("signal_state, momentum_score and weight builders", {
  st <- signal_state(list(buy = c(F, T, F, F, F, T), sell = c(F, F, F, T, F, F)))
  expect_equal(st, c(FALSE, TRUE, TRUE, FALSE, FALSE, TRUE))
  d <- make_mkt()
  S <- momentum_score(d, c("A", "B"), lookbacks = c(1, 12))
  i <- which(d$date == as.Date("2016-06-15"))
  j1 <- which(d$date == as.Date("2016-05-15")); j12 <- which(d$date == as.Date("2015-06-15"))
  expect_equal(unname(S[i, "A"]), mean(c(d$A[i] / d$A[j1] - 1, d$A[i] / d$A[j12] - 1)))
  expect_true(all(is.na(S[1:300, "A"])))
  w <- tactical_rules(d, list(list(when = "A > B", weights = c(A = 1)),
                              list(when = rep(TRUE, nrow(d)), weights = c(B = 0.5, C = 0.5))), default = c(C = 1))
  expect_s3_class(w, "SimLevWeights")
  expect_equal(unname(rowSums(as.matrix(w[, -1]))), rep(1, nrow(d)))
  expect_equal(attr(w, "regime"), ifelse(d$A > d$B, 1L, 2L))
  ro <- tactical_rotation(d, c("A", "B"), top = 1, safe = c("C", "CASH"))
  dr <- attr(ro, "decision_rows"); sc <- attr(ro, "scores")
  k <- dr[10]; best <- c("A", "B")[which.max(sc[k, c("A", "B")])]
  if (sc[k, best] >= 0) expect_equal(ro[[best]][k], 1) else expect_equal(sum(ro[k, c("C", "CASH")]), 1)
  expect_true(all(ro$A[(k + 1):(dr[11])] == ro$A[k]))                         # gehalten bis zur naechsten Entscheidung
  can <- tactical_rotation(d, c("A", "B"), top = 2, safe = "CASH", canary = c("A", "B"), absolute = FALSE)
  sc2 <- attr(can, "scores"); k2 <- attr(can, "decision_rows")[20]
  expect_equal(can$CASH[k2], min(1, sum(sc2[k2, c("A", "B")] < 0) / 2))
  gp <- tactical_glidepath(d, from = c(A = 0.9, C = 0.1), to = c(A = 0.3, C = 0.7))
  expect_equal(gp$A[1], 0.9); expect_equal(gp$A[nrow(d)], 0.3, tolerance = 1e-12)
  expect_true(all(diff(gp$A) <= 1e-12))
  bl <- tactical_blend(x = gp, y = ro, shares = c(0.5, 0.5))
  expect_equal(bl$A, 0.5 * gp$A + 0.5 * ro$A)
  tv <- tactical_target_volatility(d, c(A = 1), safe = "CASH", target = 5)
  ex <- attr(tv, "exposure"); expect_true(all(ex >= 0 & ex <= 1))
  expect_equal(tv$A + tv$CASH, rep(1, nrow(d)))
  expect_error(tactical_target_volatility(d, c(A = 1), safe = "CASH", max_exposure = 2), "Kredit")
  cv <- tactical_conditional_volatility(d, c(A = 1), safe = "CASH", base = 0.8, min_history = 1)
  st <- attr(cv, "state"); ex <- attr(cv, "exposure")
  expect_equal(cv$A + cv$CASH, rep(1, nrow(d)))
  expect_true(all(ex[st == 0L] == 0.8)); expect_true(all(ex[st == 1L] <= 0.8)); expect_true(all(ex[st == -1L] >= 0.8 & ex[st == -1L] <= 1))
  expect_true(all(st[seq_len(365)] == 0L))                                   # vor min_history
  d2 <- d; cut <- 365 * 3; d2$A[(cut + 1):nrow(d)] <- d2$A[(cut + 1):nrow(d)] * 1.5^(seq_len(nrow(d) - cut) %% 2)
  cv2 <- tactical_conditional_volatility(d2, c(A = 1), safe = "CASH", base = 0.8, min_history = 1)
  expect_identical(cv$A[seq_len(cut)], cv2$A[seq_len(cut)])                  # kein Blick in die Zukunft
  fx <- tactical_conditional_volatility(d, c(A = 1), safe = "CASH", base = 0.7, min_history = 1,
                               scaling = "fixed", high_exposure = 0.3, low_exposure = 0.9)
  expect_true(all(round(fx$A, 10) %in% c(0.3, 0.7, 0.9)))
  expect_message(tactical_conditional_volatility(d, c(A = 1), safe = "CASH", min_history = 1), "hochskaliert")
  expect_silent(tactical_conditional_volatility(d, c(A = 1), safe = "CASH", lower = NULL, min_history = 1))
  expect_error(tactical_conditional_volatility(d, c(A = 1), safe = "CASH", max_exposure = 1.5), "Kredit")
  expect_output(print(cv), "Volatilit\u00e4tsphasen")
  expect_output(print(ro), "Zielgewichte")
  pdf(NULL); on.exit(dev.off(), add = TRUE); expect_silent(plot(bl))
})

test_that("portfolio_optimize matches closed forms and brute force", {
  set.seed(1)
  S0 <- matrix(c(0.04, 0.006, 0.002, 0.006, 0.0225, 0.001, 0.002, 0.001, 0.0025), 3) / 52
  R <- matrix(rnorm(780 * 3), 780) %*% chol(S0) + matrix(c(0.08, 0.06, 0.02) / 52, 780, 3, byrow = TRUE)
  colnames(R) <- c("a", "b", "c")
  S <- cov(R)
  w <- solve(S, rep(1, 3)); w <- w / sum(w)
  expect_equal(unname(portfolio_optimize(R, method = "min_variance")$weights), unname(w), tolerance = 1e-6)
  ws <- solve(S, colMeans(R)); ws <- ws / sum(ws)
  expect_equal(unname(portfolio_optimize(R, method = "max_sharpe")$weights), unname(ws), tolerance = 1e-4)
  rp <- portfolio_optimize(R, method = "risk_parity")
  expect_equal(rp$risk$risk_share, rep(1 / 3, 3), tolerance = 1e-8)
  rpb <- portfolio_optimize(R, method = "risk_parity", budget = c(a = 0.5, b = 0.25, c = 0.25))
  expect_equal(rpb$risk$risk_share, c(0.5, 0.25, 0.25), tolerance = 1e-8)
  ub <- portfolio_optimize(R, method = "min_variance", upper = c(c = 0.5))
  expect_equal(unname(ub$weights["c"]), 0.5, tolerance = 1e-8); expect_equal(sum(ub$weights), 1)
  R2 <- R[, 1:2]; g <- seq(0, 1, by = 0.001)
  cv <- sapply(g, function(a) SimLev:::.cvar_hist(R2 %*% c(a, 1 - a), 0.05))
  oc <- portfolio_optimize(R2, method = "min_cvar")
  expect_lt(oc$stats[["cvar"]], min(cv) + 1e-5)
  h <- portfolio_optimize(R, method = "hrp"); expect_equal(sum(h$weights), 1); expect_true(all(h$weights > 0))
  iv <- portfolio_optimize(R, method = "inverse_vol")$weights
  expect_equal(unname(iv), unname((1 / sqrt(diag(S))) / sum(1 / sqrt(diag(S)))))
  lw <- SimLev:::.opt_cov(R, "ledoit_wolf"); expect_true(all(eigen(lw)$values > 0))
  expect_true(isSymmetric(lw))
  rs <- portfolio_optimize(R, method = "min_variance", resample = 10, seed = 1)
  expect_equal(dim(rs$resampled), c(10L, 3L)); expect_equal(sum(rs$weights), 1)
  expect_error(portfolio_optimize(R, upper = 0.2), "Grenzen")
  ef <- portfolio_frontier(R, n = 20)
  expect_true(all(diff(ef$frontier$volatility) >= -1e-10))
  expect_output(print(rp), "risk_parity"); expect_output(print(ef), "Effizienzgrenze")
  pdf(NULL); on.exit(dev.off(), add = TRUE); expect_silent(plot(rp)); expect_silent(plot(ef))
})
})
