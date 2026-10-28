# Review 7: Statistik-/Grafik-Befunde B7-05, B7-09, B7-10, B7-11, C7-07, C7-08 (je Befund Reproduktion -> erwartetes Verhalten)

test_that("B7-05: regime_hmm() vektorisiert (E-Schritt, Viterbi) mit bitgleichen Ergebnissen", {
  # Referenzwerte aus der Fassung mit apply(lB, 1, max) und apply()-Viterbi (Stand vor Review 7)
  set.seed(11); n <- 4 * 365
  d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n))
  vol <- rep(rep(c(0.006, 0.02), c(300, 120)), length.out = n)
  d$a <- 100 * exp(cumsum(rnorm(n, 2e-4, vol))); d$b <- 100 * exp(cumsum(rnorm(n, 1e-4, vol / 2)))
  h <- regime_hmm(d, c("a", "b"), k = 3, frequency = "day", n_start = 2)
  expect_identical(sprintf("%a", h$loglik), "0x1.55e1b8946a283p+13")
  expect_identical(sprintf("%a", sum(h$filtered * seq_len(nrow(h$filtered)))), "0x1.0406ep+20")
  expect_identical(sprintf("%a", sum(h$smoothed[, 3])), "0x1.660933750ecbp+8")
  expect_identical(as.vector(table(h$viterbi)), c(45L, 1059L, 355L))
  expect_identical(sum(h$viterbi * seq_along(h$viterbi)), 2373443L)
  # Viterbi-Kern gegen die bisherige apply()-Fassung, auch mit Gleichstaenden und -Inf
  ref <- function(lB, lA, lp0) {
    Tn <- nrow(lB); k <- ncol(lB); dl <- lp0 + lB[1, ]; bp <- matrix(0L, Tn, k)
    for (t in 2:Tn) { cand <- dl + lA; bp[t, ] <- apply(cand, 2, which.max); dl <- apply(cand, 2, max) + lB[t, ] }
    path <- integer(Tn); path[Tn] <- which.max(dl); for (t in Tn:2) path[t - 1] <- bp[t, path[t]]; path
  }
  set.seed(3)
  for (k in 2:4) {
    lB <- matrix(round(rnorm(200 * k), 1), 200, k)                       # gerundet: viele Gleichstaende
    A <- matrix(runif(k * k), k); A[1, k] <- 0; A <- A / rowSums(A)      # log(0) = -Inf
    expect_identical(SimLev:::.hmm_viterbi(lB, log(A), log(rep(1 / k, k))), ref(lB, log(A), log(rep(1 / k, k))))
    expect_identical(SimLev:::.hmm_viterbi(lB, matrix(0, k, k), c(-Inf, rep(0, k - 1))), ref(lB, matrix(0, k, k), c(-Inf, rep(0, k - 1))))
  }
})

test_that("B7-09: portfolio_optimize() prueft alpha, mu wie lower/upper, warnt bei upper > 1, meldet Inf", {
  set.seed(8); R <- matrix(rnorm(300 * 4, 0.001, 0.02), 300); colnames(R) <- LETTERS[1:4]
  # alpha: vorher 'probs' outside [0,1] bzw. stilles Ergebnis mit alpha = 0.95
  expect_error(portfolio_optimize(R, method = "min_cvar", alpha = 5), "alpha .*\\(0, 0.5\\].*0.05 statt 5")
  expect_error(portfolio_optimize(R, method = "min_cvar", alpha = 0.95), "nicht das Konfidenzniveau \\(0.95 -> alpha = 0.05\\)")
  expect_error(portfolio_optimize(R, alpha = 0), "alpha")
  expect_error(portfolio_risk_contributions(R, c(A = 0.5, B = 0.5), measure = "cvar", alpha = 0.95), "portfolio_risk_contributions: alpha")
  expect_silent(portfolio_optimize(R, method = "min_cvar", alpha = 0.5))
  # mu: unbenannt in Spaltenreihenfolge (vorher "mu fuer alle Anlagen angeben."), unbekannte Namen genannt
  w_named <- portfolio_optimize(R, method = "max_sharpe", mu = c(A = 5, B = 6, C = 7, D = 8))$weights
  expect_identical(portfolio_optimize(R, method = "max_sharpe", mu = c(5, 6, 7, 8))$weights, w_named)
  expect_identical(portfolio_optimize(R, method = "max_sharpe", mu = c(D = 8, C = 7, B = 6, A = 5))$weights, w_named)
  expect_error(portfolio_optimize(R, method = "max_sharpe", mu = c(A = 5, B = 6, C = 7, X = 8)), "mu: unbekannte Anlage\\(n\\) 'X'")
  expect_error(portfolio_optimize(R, method = "max_sharpe", mu = c(A = 5, B = 6)), "es fehlt ein Wert f\u00fcr 'C', 'D'")
  expect_error(portfolio_optimize(R, method = "max_sharpe", mu = c(5, 6)), "mu: unbenannter Vektor der L\u00e4nge 2")
  expect_error(portfolio_optimize(R, method = "max_sharpe", mu = c(5, 6, Inf, 8)), "mu: endliche Werte")
  # upper > 1: Warnung (Prozent statt Anteil), Ergebnis wie upper = 1
  expect_warning(w26 <- portfolio_optimize(R, upper = 26), "upper: Obergrenze\\(n\\) > 1 \\(A = 26")
  expect_equal(w26$weights, portfolio_optimize(R, upper = 1)$weights)
  expect_silent(portfolio_optimize(R, upper = 0.26))
  # portfolio_rolling: die Warnung erscheint einmal (Vorabpruefung), nicht je Termin
  set.seed(1); n <- 4 * 365
  d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
  d$a <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)); d$b <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.003))
  msgs <- character()
  withCallingHandlers(portfolio_rolling(d, c("a", "b"), window = 2, every = "quarter", upper = 70),
                      warning = function(w) { msgs <<- c(msgs, conditionMessage(w)); invokeRestart("muffleWarning") })
  expect_length(grep("Obergrenze", msgs), 1)
  expect_error(portfolio_rolling(d, c("a", "b"), window = 2, alpha = 0.95), "portfolio_rolling: alpha")
  # Inf in Renditen: vorher "infinite or missing values in 'x'"
  R2 <- R; R2[5, 2] <- Inf
  expect_error(portfolio_optimize(R2), "unendliche Rendite\\(n\\).*Spalte\\(n\\) 'B'.*Zeile 5")
})

test_that("B7-10: .wquantile() ist gewichteter Typ 7 - bei gleichen Gewichten bitgleich zu Typ 7, stetig in den Gewichten", {
  wq <- SimLev:::.wquantile
  x <- c(1, 2, 3, 4)
  # vorher: Median 2.5 bei gleichen, 3 bei fast gleichen Gewichten; q05 1.15 bzw. 1
  expect_identical(wq(x, c(1, 1, 1, 1), c(0.5, 0.05)), stats::quantile(x, c(0.5, 0.05), names = FALSE, type = 7))
  expect_equal(wq(x, c(1, 1, 1, 1 + 1e-12), c(0.5, 0.05)), c(2.5, 1.15), tolerance = 1e-10)
  # Gewicht 3 auf dem groessten Wert = Wert dreimal: Typ-7-Median von (1, 2, 3, 4, 4, 4) = 3.5 (vorher 3)
  expect_equal(wq(x, c(1, 1, 1, 3), 0.5), 3.5)
  # Gewicht 0 = Wert faellt weg; Ergebnis bleibt im Wertebereich
  expect_equal(wq(x, c(1, 0, 1, 1), c(0, 0.5, 1)), stats::quantile(c(1, 3, 4), c(0, 0.5, 1), names = FALSE))
  set.seed(5); mx <- 0
  for (i in 1:200) { n <- sample(2:40, 1); v <- rnorm(n); p <- c(0, runif(3), 1)
    w <- rep(1, n) * (1 + 1e-9 * runif(n))
    mx <- max(mx, abs(wq(v, w, p) - stats::quantile(v, p, names = FALSE, type = 7)))
    q <- wq(v, runif(n), p); expect_true(all(q >= min(v) & q <= max(v))) }
  expect_lt(mx, 1e-7)
  # Wirkung: summary() einer Entnahme-Simulation springt nicht mehr bei fast gleichen Gewichten
  set.seed(1); R <- matrix(exp(rnorm(30 * 40, 0.05, 0.15)), 30)
  wp <- structure(list(returns = R, inflation = matrix(1.02, 30, 40), cape = NULL, base_rate = NULL, frequency = "year",
                       historical = FALSE, start_dates = NULL, weights = rep(1, 40), source = "x"), class = "withdrawal_paths")
  s1 <- summary(withdrawal_simulation(wp))$terminal_real
  wp$weights[40] <- 1 + 1e-12
  s2 <- summary(withdrawal_simulation(wp))$terminal_real
  expect_equal(s2, s1, tolerance = 1e-9)
})

test_that("B7-11: bootstrap() und bootstrap_study() erzeugen mit gleichem Seed dieselben Pfade (wie dokumentiert)", {
  set.seed(2); h <- data.frame(us = 1 + rnorm(1500, 3e-4, 0.01)); cfg <- bootstrap_config(c(us = "us"))
  st <- list(a = create_strategy(us = asset_config("etf", "bnh")))
  b <- bootstrap(h, cfg, "stationary", n = 3, params = list(L = 30), seed = 3, progress = FALSE, path_length = 200)
  s <- suppressWarnings(bootstrap_study(h, cfg, "stationary", n = 3, strategies = st, params = list(L = 30), seed = 3,
                                        path_length = 200, keep_paths = 3, progress = FALSE))
  expect_equal(b$paths, s$paths, ignore_attr = TRUE)
  b2 <- suppressMessages(bootstrap(h, cfg, "stationary", n = 6, ess = TRUE, seed = 4, progress = FALSE, path_length = 200))
  s2 <- suppressMessages(suppressWarnings(bootstrap_study(h, cfg, "stationary", n = 6, ess = TRUE, strategies = st, seed = 4,
                                                          path_length = 200, keep_paths = 100, progress = FALSE)))
  expect_equal(b2$paths, s2$paths, ignore_attr = TRUE)
  # Doku: Text im Quelltext (roxygen); das Rd wird separat erzeugt
  rox <- file.path(test_path(), "..", "..", "R", "bootstrap.R")
  skip_if_not(file.exists(rox))
  txt <- paste(readLines(rox, encoding = "UTF-8"), collapse = "\n")
  expect_false(grepl("identisch zu [bootstrap_study()] mit gleichem Seed", txt, fixed = TRUE))
  expect_true(grepl("[bootstrap()] und [bootstrap_study()] mit gleichem", txt, fixed = TRUE))
})

test_that("C7-07: bootstrap_study() nennt Fehler der Einzelsimulationen und fasst ihre Warnungen zusammen", {
  set.seed(1); n <- 3 * 365
  d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
  d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
  cfg <- bootstrap_config(c(akt = "aktien"), input = "prices")
  bnh <- create_strategy(akt = asset_config("etf", "bnh", partial_exemption = 30))
  run <- function(..., n = 10, cores = 1) bootstrap_study(d, cfg, "stationary", n = n, params = list(L = 30), path_length = 2 * 365,
                                                          cores = cores, chunk_size = 5, seed = 1, progress = FALSE, ...)
  # vorher nur "Keine Strategie-Ergebnisse - Strategie, Signale und sim_args pruefen."
  # Etappe 6.4: unbekannte und alte flache Namen in sim_args sofort mit Hinweis auf den Baustein
  expect_error(run(strategies = list(bnh = bnh), sim_args = list(taxmode = "person")),
               "bootstrap_study: unbekanntes Argument taxmode f\u00fcr simulation\\(\\)")
  expect_error(run(strategies = list(bnh = bnh), sim_args = list(tax_mode = "person")),
               "bootstrap_study: tax_mode gibt es nicht mehr; bitte tax = tax_profile")
  expect_error(run(strategies = list(bnh = bnh), sim_args = list(start_value = 1, dca.span = 1)),
               "dca_plan: 'value' muss")
  expect_error(run(strategies = list(sig = list(strategy = create_strategy(akt = asset_config("etf", "signal", signal_buy = "b", signal_sell = "s")),
                                                signal = function(df) stop("Spalte fehlt")))),
               "Strategie 'sig', Signal, 10-mal: Spalte fehlt")
  # eine Strategie scheitert: Warnung mit der Meldung, Einzelheiten in $errors
  expect_warning(st <- run(strategies = list(ok = bnh, kaputt = list(strategy = bnh, args = list(start_value = -1)))),
                 "10 Pfad-Strategie-Kombinationen ohne Ergebnis.*Strategie 'kaputt', Simulation, 10-mal: simulation: start_value muss")
  expect_identical(as.vector(table(st$results$strategy)), 10L)
  expect_identical(st$errors$strategy, "kaputt"); expect_identical(st$errors$n, 10L); expect_identical(st$errors$stage, "Simulation")
  # Warnungen der Einzelsimulationen: vorher 0 (verschluckt), jetzt eine zusammengefasste mit Anzahl
  msgs <- character()
  st <- withCallingHandlers(run(n = 20, strategies = list(bnh = bnh), sim_args = list(risk_free = 0.01)),
                            warning = function(w) { msgs <<- c(msgs, conditionMessage(w)); invokeRestart("muffleWarning") })
  expect_length(msgs, 1)
  expect_match(msgs, "Warnungen der Einzelsimulationen \\(1 verschiedene.*\\[Strategie 'bnh', 20 von 20 Pfaden\\] simulation: risk_free = 0.01")
  expect_identical(st$warnings$n, 20L); expect_null(st$errors)
  expect_identical(nrow(st$results), 20L)
  # ohne Warnungen/Fehler: Felder NULL, Ergebnisse unveraendert
  st0 <- run(strategies = list(bnh = bnh))
  expect_null(st0$warnings); expect_null(st0$errors)
  # parallel gleich behandelt
  skip_on_os("windows"); skip_on_cran()
  sp <- suppressWarnings(run(n = 20, cores = 2, strategies = list(ok = bnh, kaputt = list(strategy = bnh, args = list(start_value = -1))),
                             sim_args = list(risk_free = 0.01)))
  ss <- suppressWarnings(run(n = 20, cores = 1, strategies = list(ok = bnh, kaputt = list(strategy = bnh, args = list(start_value = -1))),
                             sim_args = list(risk_free = 0.01)))
  expect_identical(sp$errors, ss$errors); expect_identical(sp$warnings, ss$warnings); expect_identical(sp$results, ss$results)
})

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

test_that("R8-06: plot(colors =) akzeptiert R-Farbnamen, prueft Farbwerte, Transparenz per adjustcolor()", {
  set.seed(7); n <- 500
  data <- data.frame(date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = n), ETF = 100 * cumprod(1 + rnorm(n, 4e-4, 0.012)))
  r <- suppressWarnings(simulation(data, create_strategy(ETF = asset_config("etf", share = 1))))
  grDevices::pdf(NULL); on.exit(grDevices::dev.off(), add = TRUE)
  # vorher: invalid color name 'navy30' bzw. 'darkred40'
  expect_silent(plot(r, colors = list(primary = "navy")))
  expect_silent(plot(r, colors = list(negative = "darkred", positive = "forestgreen")))
  expect_silent(plot(r, colors = list(primary = "#00336680")))            # eigene Transparenz wird multipliziert
  # vorher: invalid RGB specification (bzw. kryptisch je nach Farbe)
  expect_error(plot(r, colors = list(primary = "navyy")), "ung\u00fcltige Farbe\\(n\\) in colors: primary = \"navyy\"")
  expect_error(plot(r, colors = list(primary = "#12345")), "primary = \"#12345\"")
  expect_error(plot(r, colors = list(grid = NA)), "grid = NA")
  expect_error(plot(r, colors = list(primary = c("red", "blue"))), "ung\u00fcltige Farbe")
  # Standardfarben: adjustcolor() ergibt dieselben RGBA-Werte wie das fruehere Hex-Suffix
  for (cl in c("#2E86AB", "#D62246")) for (a in c("30", "40", "80"))
    expect_identical(grDevices::adjustcolor(cl, alpha.f = strtoi(a, 16L) / 255), paste0(cl, a))
})

test_that("R8-07: portfolio_optimize(upper = Inf) = keine Obergrenze (wie 1, ohne Prozent-Warnung)", {
  set.seed(8); R <- matrix(rnorm(300 * 4, 0.001, 0.02), 300); colnames(R) <- LETTERS[1:4]
  # vorher: Warnung "Prozentangabe?" und Abbruch "missing value where TRUE/FALSE needed"
  expect_silent(a <- portfolio_optimize(R, upper = Inf))
  expect_identical(a, portfolio_optimize(R, upper = 1))
  expect_identical(portfolio_optimize(R, upper = c(A = 0.3, B = Inf)), portfolio_optimize(R, upper = c(A = 0.3)))
  expect_identical(unname(a$bounds["upper", ]), rep(1, 4))
  expect_silent(ef <- portfolio_frontier(R, n = 5, upper = Inf))
  expect_identical(ef, portfolio_frontier(R, n = 5))
  expect_warning(portfolio_optimize(R, upper = c(A = 26, B = Inf)), "Obergrenze\\(n\\) > 1 \\(A = 26\\)")
  expect_error(portfolio_optimize(R, lower = Inf), "Grenzen nicht erf\u00fcllbar")
  expect_error(portfolio_optimize(R, upper = -Inf), "Grenzen nicht erf\u00fcllbar")
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
                     compare = r))   # "correlation" braucht compare (R9-05)
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

test_that("R9-04: Startkapital ohne die Sparrate des Starttags (start_value)", {
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

test_that("R9-05: Korrelation = rollierende Korrelation Strategie/Vergleich; ohne compare Warnung statt Leerfeld", {
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
