# =============================================================================
#  analysis_tests.R  —  Signal-Analyse, statistische Tests, Heatmaps
# -----------------------------------------------------------------------------
#  signal_analysis()    Vorwaertsrenditen je Signalbereich (Regressogramm),
#                       optional fuer zwei Signale und je Zeitabschnitt
#  sharpe_test()        Unterschied zweier Sharpe Ratios (Ledoit & Wolf 2008:
#                       HAC-Delta-Methode oder Block-Bootstrap)
#  reality_check()      White (2000) Reality Check und Hansen (2005) SPA:
#                       schlaegt die beste von vielen Strategien die
#                       Benchmark mehr als zufaellig?
#  min_track_record()   Mindestlaenge einer Historie fuer eine Sharpe-Aussage
#                       (Bailey & Lopez de Prado 2012)
#  return_heatmap()     annualisierte (reale) Renditen je Startjahr und
#                       Haltedauer
# =============================================================================

#' Periodenrenditen aus Ergebnis, data.frame oder Vektor
#' @keywords internal
#' @noRd
.ret_from <- function(x, frequency, inflation = NULL) {
  if (is.numeric(x) && is.null(dim(x))) return(list(r = x, date = NULL))
  s <- .da_series(x, "x")
  if (!is.null(inflation)) s <- .da_deflate(s, inflation)
  if (frequency == "day") { keep <- c(TRUE, !s$filled[-1]); d <- s$date[keep]; v <- s$value[keep] }
  else { key <- if (frequency == "week") format(s$date, "%G-%V") else format(s$date, "%Y-%m")
         e <- which(c(key[-1] != key[-length(key)], TRUE)); d <- s$date[e]; v <- s$value[e] }
  list(r = v[-1] / v[-length(v)] - 1, date = d[-1])
}

#' Signal-Analyse: Vorwaertsrenditen je Signalbereich
#'
#' Beantwortet die Frage "Wenn das Signal auf diesem Niveau steht, was
#' passiert danach typischerweise?" - unabhaengig von einer konkreten
#' Handelsregel. Fuer jeden Stichtag (Zeile 1, dann alle \code{step} Zeilen)
#' wird die Rendite der Zielreihe ueber die folgenden \code{horizon} Zeilen
#' gemessen (\eqn{P_{t+h} / P_t - 1}, als Anteil) und nach dem Signalwert
#' am Stichtag in Bereiche eingeteilt (Regressogramm). Splits
#' pruefen, ob der Zusammenhang ueber die Zeit stabil ist. Das ist eine
#' Beschreibung vergangener Muster, kein Nachweis einer handelbaren
#' Ueberrendite.
#'
#' Eingabe ist ein data.frame mit Datum, Kursspalte und Signal (Spalte oder
#' Vektor). Stichtage mit fehlendem Signal (bzw. fehlendem zweiten Signal)
#' oder fehlender Vorwaertsrendite entfallen; es muessen mindestens 20
#' Stichtage bleiben.
#'
#' @param data data.frame mit Spalte \code{date} (Klasse Date oder
#'   umwandelbar) und der Kursspalte \code{target}; optional Signalspalten.
#'   Die Zeilen werden nach Datum sortiert (Signalvektoren mit), bei
#'   doppeltem Datum gilt die letzte Zeile (mit Hinweis).
#' @param signal Spaltenname in \code{data} oder numerischer Vektor der
#'   Laenge \code{nrow(data)}. Der Wert in Zeile t muss nur mit Daten bis
#'   einschliesslich Zeile t berechnet sein (sonst Zukunftsinformation).
#' @param target Name der Kursspalte (Niveaus, keine Renditen). Fehlende
#'   Kurse werden mit dem letzten bekannten Wert fortgeschrieben.
#' @param horizon Vorwaertshorizont in Zeilen der Daten (ganze Zahl von 1
#'   bis \code{nrow(data) - 1}, Standard 21), z. B. 21 Handelstage oder 30
#'   Kalendertage.
#' @param step Abstand der Stichtage in Zeilen. \code{NULL} (Standard) =
#'   \code{horizon}, die Vorwaertsrenditen ueberlappen dann nicht.
#' @param bins Anzahl Bereiche nach Quantilen des Signals (ganze Zahl >= 2,
#'   Standard 5). Gleiche Quantilsgrenzen werden zusammengefasst (dann
#'   weniger Bereiche). Hat das Signal hoechstens \code{bins} verschiedene
#'   Werte (z. B. 0/1), erhaelt jeder Wert einen eigenen Bereich. Wird
#'   ignoriert, wenn \code{breaks} angegeben ist.
#' @param breaks Numerischer Vektor (mindestens 3) streng aufsteigender
#'   Bereichsgrenzen in der Einheit des Signals; \code{NULL} (Standard) =
#'   Quantile (\code{bins}).
#'   Die erste und letzte Grenze werden durch \code{-Inf} und \code{Inf}
#'   ersetzt; Bereiche sind links geschlossen, \code{[a, b)}.
#' @param signal2,bins2 Optional zweites Signal (Spaltenname oder Vektor wie
#'   \code{signal}) und die Anzahl seiner Quantilsbereiche (Standard 3) fuer
#'   eine 2D-Tabelle. \code{NULL} (Standard) = keine 2D-Tabelle.
#' @param splits Anzahl gleich grosser Gruppen aufeinanderfolgender
#'   Stichtage fuer die Stabilitaetspruefung (ganze Zahl, Standard 1 = keine
#'   Aufteilung).
#' @param degree Grad der Polynom-Regression \code{forward ~ poly(signal,
#'   degree)} (ganze Zahl, Standard 2; 0 = keine). Wird nur geschaetzt, wenn
#'   es mehr als \code{degree + 1} verschiedene Signalwerte gibt.
#' @return Objekt der Klasse \code{SimLevSignalAnalysis}, eine Liste mit
#'   \describe{
#'     \item{\code{bins}}{data.frame je (nicht leerem) Bereich: \code{bin}
#'       (Intervall als Text), \code{from}, \code{to} (kleinster und groesster
#'       Signalwert im Bereich), \code{n}, \code{mean}, \code{median}
#'       (Vorwaertsrendite als Anteil), \code{win_rate} (Anteil positiver
#'       Renditen), \code{sd}, \code{t} (\code{mean / (sd / sqrt(n))}) und
#'       \code{annualized} (\eqn{(1 + mean)^{ppy / horizon} - 1}, Anteil p. a.;
#'       \code{ppy} = Zeilen je Jahr, geschaetzt als
#'       \code{(nrow(data) - 1)} / Zeitspanne in Jahren zu 365.25 Tagen).}
#'     \item{\code{overall}}{benannter Vektor \code{n}, \code{mean},
#'       \code{median}, \code{win_rate}, \code{sd}, \code{t} ueber alle
#'       Stichtage.}
#'     \item{\code{spread}}{benannter Vektor \code{difference} (Mittel
#'       oberster minus unterster Bereich, Anteil), \code{t} und \code{p}
#'       (Welch-t-Test; \code{NA}, wenn einer der beiden Bereiche hoechstens
#'       2 Werte hat).}
#'     \item{\code{splits}}{Matrix Bereiche x Zeitabschnitte mit der
#'       mittleren Vorwaertsrendite (Anteil), Spaltennamen "Jahr-Jahr";
#'       \code{NULL} bei \code{splits = 1}.}
#'     \item{\code{table2d}}{Liste mit \code{mean} (Matrix Bereich
#'       \code{signal} x Bereich \code{signal2}, mittlere Vorwaertsrendite
#'       als Anteil) und \code{n} (Haeufigkeiten); \code{NULL} ohne
#'       \code{signal2}.}
#'     \item{\code{fit}}{Liste mit \code{model} (\code{lm}-Objekt) und
#'       \code{r_squared} (\eqn{R^2}); \code{NULL} ohne Polynom-Glaettung.}
#'     \item{\code{data}}{data.frame der Stichtage mit \code{date},
#'       \code{signal}, \code{forward} (Anteil), ggf. \code{signal2},
#'       \code{bin}, ggf. \code{bin2}.}
#'     \item{\code{horizon}, \code{step}, \code{target},
#'       \code{signal_name}}{Einstellungen.}
#'   }
#'   \code{print()} zeigt die Bereichstabelle in Prozent, \code{plot()}
#'   Balken je Bereich (mit +/- 2 Standardfehlern) und ein Streudiagramm
#'   Signal gegen Vorwaertsrendite.
#' @seealso [momentum_score()] und [regime_states()] (numerische Signale),
#'   [sharpe_test()], [simulation()] (Handelsregel pruefen)
#' @examples
#' set.seed(1); n <- 3 * 365
#' d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
#' d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
#' # Signal: 60-Tage-Rendite, nur mit Daten bis zum Stichtag berechnet
#' d$mom <- c(rep(NA, 60), d$aktien[-(1:60)] / d$aktien[1:(n - 60)] - 1)
#' sa <- signal_analysis(d, "mom", "aktien", horizon = 21, bins = 4, splits = 2)
#' sa
#' sa$bins[, c("bin", "n", "mean", "annualized")]
#' plot(sa)
#' @export
signal_analysis <- function(data, signal, target, horizon = 21L, step = NULL, bins = 5L, breaks = NULL,
                            signal2 = NULL, bins2 = 3L, splits = 1L, degree = 2L) {
  if (!is.data.frame(data) || !"date" %in% names(data)) stop("signal_analysis: data muss ein data.frame mit Spalte 'date' sein.")
  n <- nrow(data); d <- .to_date(data$date, "signal_analysis: data$date")
  getcol <- function(v, what) {
    if (is.character(v)) {
      if (length(v) != 1L || !v %in% names(data))
        stop(sprintf("signal_analysis: %s: Spalte '%s' fehlt in data (vorhanden: %s).", what, v[1], paste(names(data), collapse = ", ")))
      return(as.numeric(data[[v]]))
    }
    if (length(v) != n) stop(sprintf("signal_analysis: %s hat L\u00e4nge %d, data hat %d Zeilen.", what, length(v), n))
    as.numeric(v)
  }
  sig <- getcol(signal, "signal")
  if (!is.character(target) || length(target) != 1L) stop("signal_analysis: target muss ein Spaltenname sein.")
  px <- getcol(target, "target")
  s2all <- if (!is.null(signal2)) getcol(signal2, "signal2") else NULL
  # zeitlich sortieren, doppelte Daten (letzter Wert) entfernen
  o <- order(d); o <- o[!is.na(d[o])]; dup <- duplicated(d[o], fromLast = TRUE)
  if (any(dup)) message(sprintf("Hinweis: signal_analysis: %d doppelte Daten; der letzte Wert je Datum wird verwendet.", sum(dup)))
  o <- o[!dup]; d <- d[o]; sig <- sig[o]; px <- px[o]; if (!is.null(s2all)) s2all <- s2all[o]; n <- length(o)
  px <- .fill_na(px, "locf", keep_leading = TRUE)
  horizon <- as.integer(horizon); step <- as.integer(step %||% horizon)
  if (length(horizon) != 1L || is.na(horizon) || horizon < 1L || horizon >= n)
    stop(sprintf("signal_analysis: horizon muss zwischen 1 und %d (Zeilen - 1) liegen (ist: %s).", n - 1L, format(horizon)))
  if (length(step) != 1L || is.na(step) || step < 1L) stop("signal_analysis: step muss eine ganze Zahl >= 1 sein.")
  if (!is.null(breaks) && (!is.numeric(breaks) || length(breaks) < 3L || anyNA(breaks) || is.unsorted(breaks, strictly = TRUE)))
    stop("signal_analysis: breaks braucht mindestens 3 streng aufsteigende Grenzen (erste und letzte werden zu -Inf und Inf), z. B. c(-Inf, 0, Inf).")
  if (is.null(breaks) && (length(bins) != 1L || is.na(bins) || bins < 2)) stop("signal_analysis: bins muss eine ganze Zahl >= 2 sein.")
  t0 <- seq(1L, n - horizon, by = step)
  fwd <- px[t0 + horizon] / px[t0] - 1
  s2 <- if (!is.null(s2all)) s2all[t0] else NULL
  df <- data.frame(date = d[t0], signal = sig[t0], forward = fwd)
  if (!is.null(s2)) df$signal2 <- s2
  df <- df[stats::complete.cases(df), , drop = FALSE]
  if (nrow(df) < 20) stop(sprintf("signal_analysis: zu wenige Stichtage (%d, mindestens 20) mit Signal und Vorw\u00e4rtsrendite.", nrow(df)))
  if (length(unique(df$signal)) < 2L)
    stop(sprintf("signal_analysis: Signal ist an allen Stichtagen gleich (%g); keine Bereiche m\u00f6glich.", df$signal[1]))
  ppy <- (n - 1) / (as.numeric(d[n] - d[1]) / 365.25)
  ann <- function(m) (1 + m)^(ppy / horizon) - 1
  cutb <- function(v, k, br) {
    u <- sort(unique(v))
    br <- br %||% (if (length(u) <= k) c(-Inf, u[-1], Inf)       # wenige Werte (z. B. 0/1): ein Bereich je Wert
                   else unique(stats::quantile(v, seq(0, 1, length.out = k + 1), names = FALSE)))
    br[1] <- -Inf; br[length(br)] <- Inf
    cut(v, br, include.lowest = TRUE, right = FALSE)
  }
  df$bin <- cutb(df$signal, bins, breaks)
  st <- function(z) c(n = length(z), mean = mean(z), median = stats::median(z), win_rate = mean(z > 0),
                      sd = stats::sd(z), t = mean(z) / (stats::sd(z) / sqrt(length(z))))
  tab <- do.call(rbind, lapply(split(df, df$bin), function(z) if (nrow(z)) data.frame(
    bin = as.character(z$bin[1]), from = min(z$signal), to = max(z$signal), t(st(z$forward)), annualized = ann(mean(z$forward)),
    check.names = FALSE) else NULL))
  rownames(tab) <- NULL
  lv <- levels(df$bin); lo <- df$forward[df$bin == lv[1]]; hi <- df$forward[df$bin == lv[length(lv)]]
  wt <- if (length(lo) > 2 && length(hi) > 2) stats::t.test(hi, lo) else NULL
  spread <- c(difference = mean(hi) - mean(lo), t = if (!is.null(wt)) unname(wt$statistic) else NA,
              p = if (!is.null(wt)) wt$p.value else NA)
  fit <- NULL
  if (degree > 0 && length(unique(df$signal)) > degree + 1) {
    m <- stats::lm(forward ~ stats::poly(signal, degree), data = df)
    fit <- list(model = m, r_squared = summary(m)$r.squared)
  }
  spl <- NULL
  if (splits > 1) {
    seg <- cut(seq_len(nrow(df)), splits, labels = FALSE)
    spl <- vapply(seq_len(splits), function(k) vapply(lv, function(b) { z <- df$forward[seg == k & df$bin == b]
      if (length(z)) mean(z) else NA_real_ }, 0), numeric(length(lv)))
    if (!is.matrix(spl)) spl <- matrix(spl, nrow = length(lv))
    dimnames(spl) <- list(lv, vapply(seq_len(splits), function(k) paste(format(range(df$date[seg == k]), "%Y"), collapse = "-"), ""))
  }
  t2 <- NULL
  if (!is.null(s2)) {
    df$bin2 <- cutb(df$signal2, bins2, NULL)
    t2 <- list(mean = tapply(df$forward, list(df$bin, df$bin2), mean), n = table(df$bin, df$bin2))
  }
  structure(list(bins = tab, overall = st(df$forward), spread = spread, splits = spl, table2d = t2, fit = fit,
                 data = df, horizon = horizon, step = step, target = target,
                 signal_name = if (is.character(signal)) signal else "signal"), class = "SimLevSignalAnalysis")
}

#' @rdname signal_analysis
#' @param x Objekt der Klasse \code{SimLevSignalAnalysis}.
#' @param ... ungenutzt.
#' @export
print.SimLevSignalAnalysis <- function(x, ...) {
  cat(sprintf("Signal-Analyse: %s -> Rendite von '%s' \u00fcber %d Zeilen (%d Stichtage, Abstand %d)\n\n",
              x$signal_name, x$target, x$horizon, nrow(x$data), x$step))
  b <- x$bins
  print(data.frame(Bereich = b$bin, n = b$n, Mittel = sprintf("%.2f %%", 100 * b$mean), Median = sprintf("%.2f %%", 100 * b$median),
                   Treffer = sprintf("%.0f %%", 100 * b$win_rate), t = sprintf("%.2f", b$t),
                   `p. a.` = sprintf("%.1f %%", 100 * b$annualized), check.names = FALSE), row.names = FALSE)
  o <- x$overall
  cat(sprintf("\nAlle Stichtage: Mittel %.2f %%, Trefferquote %.0f %%\n", 100 * o["mean"], 100 * o["win_rate"]))
  cat(sprintf("Oberster minus unterster Bereich: %+.2f %% (Welch-t %.2f, p = %.3f)\n", 100 * x$spread["difference"],
              x$spread["t"], x$spread["p"]))
  if (!is.null(x$fit)) cat(sprintf("Polynom-Gl\u00e4ttung: R^2 = %.3f\n", x$fit$r_squared))
  if (!is.null(x$splits)) { cat("\nMittelwerte je Zeitabschnitt (Stabilit\u00e4t)\n"); print(round(100 * x$splits, 2)) }
  if (!is.null(x$table2d)) { cat("\nMittelwerte je Bereich beider Signale\n"); print(round(100 * x$table2d$mean, 2)) }
  invisible(x)
}

#' @rdname signal_analysis
#' @export
plot.SimLevSignalAnalysis <- function(x, ...) {
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  graphics::par(mfrow = c(1, 2), mar = c(4.4, 4.4, 2.6, 1), mgp = c(2.5, 0.6, 0), las = 1, cex.axis = 0.75)
  b <- x$bins; se <- b$sd / sqrt(b$n)
  yl <- range(100 * c(b$mean - 2 * se, b$mean + 2 * se, 0))
  mids <- graphics::barplot(100 * b$mean, names.arg = seq_len(nrow(b)), col = "#2C6E9B", border = NA, ylim = yl,
                            xlab = "Signalbereich (niedrig -> hoch)", ylab = "Mittlere Vorw\u00e4rtsrendite (%)", main = "Je Signalbereich")
  graphics::arrows(mids, 100 * (b$mean - 2 * se), mids, 100 * (b$mean + 2 * se), angle = 90, code = 3, length = 0.03)
  graphics::abline(h = 100 * x$overall["mean"], lty = 2, col = "#B5562B")
  graphics::plot(x$data$signal, 100 * x$data$forward, pch = 16, cex = 0.4, col = grDevices::adjustcolor("#2C6E9B", 0.4),
                 xlab = x$signal_name, ylab = "Vorw\u00e4rtsrendite (%)", main = "Streudiagramm")
  if (!is.null(x$fit)) { o <- order(x$data$signal); graphics::lines(x$data$signal[o], 100 * stats::fitted(x$fit$model)[o], col = "#B5562B", lwd = 2) }
  graphics::abline(h = 0, col = "grey50", lty = 3)
  invisible(x)
}

#' Newey-West-Kovarianz (Bartlett-Kern)
#' @keywords internal
#' @noRd
.hac_cov <- function(Y, lag = NULL) {
  Tn <- nrow(Y); lag <- lag %||% floor(4 * (Tn / 100)^(2 / 9))
  Yc <- sweep(Y, 2, colMeans(Y)); S <- crossprod(Yc) / Tn
  for (l in seq_len(lag)) { G <- crossprod(Yc[(l + 1):Tn, , drop = FALSE], Yc[1:(Tn - l), , drop = FALSE]) / Tn
    S <- S + (1 - l / (lag + 1)) * (G + t(G)) }
  S
}

#' Test auf gleiche Sharpe Ratios
#'
#' Prueft, ob sich die Sharpe Ratios zweier Strategien unterscheiden, robust
#' gegen Autokorrelation, Heteroskedastie und dicke Raender (Ledoit & Wolf
#' 2008): mit der Delta-Methode und Newey-West-Kovarianz (\code{"hac"}) oder
#' einem stationaeren Block-Bootstrap der Renditepaare (\code{"bootstrap"}).
#' Der klassische Jobson-Korkie-Test unterstellt Normalverteilung und
#' unabhaengige Renditen und ist fuer Finanzdaten zu optimistisch.
#'
#' Fertige Simulationen lassen sich direkt vergleichen: \code{x} und
#' \code{y} duerfen Ergebnisse von [simulation()] sein. Die Sharpe Ratio ist
#' hier Mittelwert / Standardabweichung der Periodenrenditen, ohne Abzug
#' eines risikolosen Zinses, annualisiert mit \eqn{\sqrt{ppy}}.
#'
#' Mindestens 10 gemeinsame Renditepaare sind noetig, und keine der beiden
#' Reihen darf die Varianz 0 haben (sonst Fehler). Identische Reihen ergeben
#' \code{difference = 0}, \code{se = 0}, \code{z = 0} und \code{p_value = 1}.
#'
#' @param x,y Zwei Renditequellen derselben Art (nicht mischen, sonst
#'   Fehler):
#'   \itemize{
#'     \item numerische Vektoren einfacher Periodenrenditen als Anteil
#'       (0.01 = 1 %), gleich lang und zeitgleich; Paare mit einem nicht
#'       endlichen Wert werden entfernt;
#'     \item \code{SimLevResult} aus [simulation()] (verwendet wird der um
#'       Ein- und Auszahlungen bereinigte Wertindex aus [result_index()];
#'       bei \code{"day"} ohne aufgefuellte Tage) oder \code{data.frame} mit
#'       Spalte \code{date} und einer Wertspalte (\code{value}, sonst die
#'       erste numerische Spalte; Niveaus, keine Renditen). Daraus werden
#'       Renditen von Periodenende zu Periodenende der \code{frequency}
#'       gebildet und nur gemeinsame Perioden-Enddaten verwendet.
#'   }
#' @param frequency Periodenlaenge: \code{"week"} (Standard, ISO-Wochen),
#'   \code{"day"} oder \code{"month"}. Bei Vektor-Eingabe bestimmt sie nur
#'   den Standardwert von \code{ppy}.
#' @param method \code{"hac"} (Standard): Delta-Methode mit
#'   Newey-West-Kovarianz (Bartlett-Kern, Lag
#'   \eqn{\lfloor 4 (T/100)^{2/9} \rfloor}); \code{"bootstrap"}:
#'   stationaerer Block-Bootstrap der Renditepaare (Standardfehler =
#'   Standardabweichung der Bootstrap-Differenzen, p-Wert = Anteil der
#'   Wiederholungen mit \eqn{|d^* - d| \ge |d|}, Intervall = 2.5- und
#'   97.5-%-Quantil der Bootstrap-Differenzen).
#' @param B Anzahl Bootstrap-Wiederholungen (ganze Zahl, Standard 2000); nur
#'   bei \code{method = "bootstrap"}.
#' @param block Mittlere Blocklaenge des stationaeren Bootstraps in Perioden
#'   (geometrisch verteilte Blocklaengen, Bloecke laufen zyklisch ueber das
#'   Ende); \code{NULL} (Standard) = \code{max(2, round(T^(1/3)))} mit
#'   \eqn{T} = Anzahl Renditepaare. Nur bei \code{method = "bootstrap"}.
#' @param seed Startwert (ganze Zahl) fuer den Bootstrap; \code{NULL}
#'   (Standard) = kein fester Startwert. Mit Startwert ist das Ergebnis reproduzierbar und der
#'   Zufallszustand der Sitzung bleibt unveraendert; mit `NULL` wird der
#'   Zufallsstrom der Sitzung normal weitergezogen.
#' @param ppy Perioden je Jahr fuer die Annualisierung. \code{NULL}
#'   (Standard) = bei Vektoren 252 (\code{"day"}), 52 (\code{"week"}) bzw. 12
#'   (\code{"month"}); bei Ergebnissen und data.frames aus den gemeinsamen
#'   Daten geschaetzt: (Anzahl Perioden - 1) / (Zeitspanne in Tagen /
#'   365.25).
#' @return Benannter numerischer Vektor: \code{sharpe_x}, \code{sharpe_y}
#'   (Sharpe Ratios p. a.), \code{difference} (\code{sharpe_x - sharpe_y},
#'   p. a.), \code{se} (Standardfehler der Differenz, p. a.), \code{z}
#'   (\code{difference / se}), \code{p_value} (zweiseitig, Anteil),
#'   \code{ci_low}, \code{ci_high} (95-%-Intervall der Differenz, p. a.) und
#'   \code{n} (Anzahl verwendeter Renditepaare).
#' @seealso [min_track_record()], [probabilistic_sharpe()],
#'   [reality_check()] (viele Strategien gegen eine Benchmark),
#'   [deep_analysis()]
#' @examples
#' set.seed(1); n <- 3 * 365
#' d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
#' d$a <- 100 * cumprod(1 + rnorm(n, 4e-4, 0.01))
#' d$b <- 100 * cumprod(1 + rnorm(n, 2e-4, 0.01))
#' # Kursreihen als data.frame(date, Wert): Wochenrenditen, ppy geschaetzt
#' sharpe_test(d[, c("date", "a")], d[, c("date", "b")])
#' sharpe_test(d[, c("date", "a")], d[, c("date", "b")], method = "bootstrap",
#'             B = 500, seed = 1)
#' # Ergebnisse von simulation()
#' r1 <- simulation(d, create_strategy(a = asset_config("etf", "bnh")))
#' r2 <- simulation(d, create_strategy(b = asset_config("etf", "bnh")))
#' sharpe_test(r1, r2, frequency = "month")
#' # Renditevektoren (Kalendertage, daher ppy = 365)
#' sharpe_test(diff(d$a) / d$a[-n], diff(d$b) / d$b[-n], ppy = 365)
#' @references Ledoit, O. & Wolf, M. (2008), Robust performance hypothesis
#'   testing with the Sharpe ratio, Journal of Empirical Finance 15(5),
#'   850-859.
#' @export
sharpe_test <- function(x, y, frequency = c("week", "day", "month"), method = c("hac", "bootstrap"),
                        B = 2000L, block = NULL, seed = NULL, ppy = NULL) {
  frequency <- match.arg(frequency); method <- match.arg(method)
  a <- .ret_from(x, frequency); b <- .ret_from(y, frequency)
  if (is.null(a$date) != is.null(b$date))
    stop("sharpe_test: x und y m\u00fcssen dieselbe Art sein: beide Renditevektoren oder beide Kursreihen/Ergebnisse (data.frame bzw. SimLevResult).")
  if (!is.null(a$date) && !is.null(b$date)) {
    common <- intersect(as.numeric(a$date), as.numeric(b$date))
    ra <- a$r[match(common, as.numeric(a$date))]; rb <- b$r[match(common, as.numeric(b$date))]
    ppy <- ppy %||% ((length(common) - 1) / (diff(range(common)) / 365.25))
  } else {
    if (length(a$r) != length(b$r)) stop(sprintf("sharpe_test: Renditevektoren x und y m\u00fcssen gleich lang und zeitgleich sein (L\u00e4ngen %d und %d).",
                                                 length(a$r), length(b$r)))
    ra <- a$r; rb <- b$r; ppy <- ppy %||% switch(frequency, day = 252, week = 52, month = 12)
  }
  ok <- is.finite(ra) & is.finite(rb); ra <- ra[ok]; rb <- rb[ok]; Tn <- length(ra)
  if (Tn < 10) stop(sprintf("sharpe_test: zu wenige gemeinsame Renditepaare (%d, mindestens 10).", Tn))
  for (k in c("x", "y")) if (stats::sd(if (k == "x") ra else rb) == 0)
    stop(sprintf("sharpe_test: Renditen von %s haben die Varianz 0; die Sharpe Ratio ist nicht definiert.", k))
  sr <- function(r) mean(r) / stats::sd(r)
  d0 <- sr(ra) - sr(rb)
  if (identical(ra, rb))                                      # identische Reihen: kein Unterschied, kein Test noetig
    return(c(sharpe_x = sr(ra) * sqrt(ppy), sharpe_y = sr(rb) * sqrt(ppy), difference = 0, se = 0, z = 0, p_value = 1,
             ci_low = 0, ci_high = 0, n = Tn))
  if (method == "hac") {
    mu <- c(mean(ra), mean(rb)); g <- c(mean(ra^2), mean(rb^2))
    grad <- c(g[1] / (g[1] - mu[1]^2)^1.5, -g[2] / (g[2] - mu[2]^2)^1.5,
              -0.5 * mu[1] / (g[1] - mu[1]^2)^1.5, 0.5 * mu[2] / (g[2] - mu[2]^2)^1.5)
    Psi <- .hac_cov(cbind(ra, rb, ra^2, rb^2))
    se <- sqrt(drop(t(grad) %*% Psi %*% grad) / Tn)
    z <- d0 / se; p <- 2 * stats::pnorm(-abs(z)); ci <- d0 + c(-1, 1) * stats::qnorm(0.975) * se
  } else {
    block <- block %||% max(2, round(Tn^(1 / 3)))
    db <- .with_rng_restore(seed = seed, {
      vapply(seq_len(B), function(i) { k <- .boot_idx_stationary(Tn, Tn, block); sr(ra[k]) - sr(rb[k]) }, 0) })
    se <- stats::sd(db); z <- d0 / se; p <- mean(abs(db - d0) >= abs(d0))
    ci <- stats::quantile(db, c(0.025, 0.975), names = FALSE)
  }
  k <- sqrt(ppy)
  c(sharpe_x = sr(ra) * k, sharpe_y = sr(rb) * k, difference = d0 * k, se = se * k, z = z, p_value = p,
    ci_low = ci[1] * k, ci_high = ci[2] * k, n = Tn)
}

#' White Reality Check und Hansen-SPA-Test
#'
#' Prueft, ob die beste von K Strategien (z. B. alle Punkte einer
#' Parametersuche) eine Benchmark mehr als zufaellig schlaegt, unter
#' Beruecksichtigung, dass die beste aus vielen gewaehlt wurde. Der
#' SPA-Test (Hansen 2005) ist weniger empfindlich gegen schlechte, irrelevante
#' Strategien als der Reality Check (White 2000). Beide mit stationaerem
#' Block-Bootstrap der Ueberrenditen \eqn{d_{t,k} = r_{t,k} - b_t}.
#'
#' Eingabe ist eine Parametersuche oder eine Renditematrix mit einer Spalte
#' je Strategie. Mehrere fertige Simulationen (Liste von \code{SimLevResult})
#' werden vorher zu einer Matrix zusammengefasst, z. B. mit
#' \code{sapply(liste, function(r) { v <- result_index(r)$value; v[-1] / v[-length(v)] - 1 })}
#' (gleicher Kalender aller Laeufe vorausgesetzt; Datum dazu
#' \code{result_index(liste[[1]])$date[-1]}), siehe Beispiel.
#'
#' @param x Renditequelle:
#'   \itemize{
#'     \item \code{SimLevParamSearch} aus [param_search()] mit gespeicherten
#'       Renditen (\code{keep_returns = TRUE}); verwendet werden
#'       \code{x$returns} (taegliche Renditen je Punkt, Spalten \code{p<id>})
#'       und \code{x$dates};
#'     \item numerische Matrix oder data.frame nur aus numerischen Spalten
#'       (ohne Datumsspalte): Zeilen = Perioden, Spalten = Strategien,
#'       einfache Renditen als Anteil (0.01 = 1 %); ohne Spaltennamen
#'       heissen die Spalten \code{p1}, \code{p2}, ...
#'   }
#'   Spalten ohne endlichen Wert werden verworfen, danach alle Zeilen mit
#'   einem fehlenden Wert. Bei \code{print()}: Objekt der Klasse
#'   \code{SimLevRealityCheck}.
#' @param benchmark Vergleich: \code{NULL} (Standard) = Rendite 0; eine
#'   einzelne Zahl oder Zeichenkette = Spaltennummer bzw. -name in \code{x}
#'   (nach dem Verwerfen leerer Spalten), diese Spalte wird aus den
#'   Kandidaten entfernt; ein numerischer Vektor (Laenge > 1) =
#'   Benchmark-Renditen als Anteil mit genau einem Wert je Periode nach
#'   Aggregation und Entfernen unvollstaendiger Zeilen.
#' @param B Anzahl Bootstrap-Wiederholungen (ganze Zahl, Standard 999).
#' @param block Mittlere Blocklaenge des stationaeren Bootstraps in Perioden
#'   (geometrisch verteilte Blocklaengen, zyklisch); \code{NULL} (Standard) =
#'   \code{max(2, round(T^(1/3)))} mit \eqn{T} = Anzahl Perioden.
#' @param frequency Periodenlaenge: \code{"week"} (Standard), \code{"day"}
#'   oder \code{"month"}. Mit Datum (bei \code{SimLevParamSearch} immer, bei
#'   Matrizen ueber \code{dates}) werden die Renditen geometrisch zu
#'   ISO-Wochen bzw. Kalendermonaten verkettet; ohne Datum wird nicht
#'   aggregiert, die Zeilen gelten dann als Perioden.
#' @param dates Datum je Zeile von \code{x} (Date oder umwandelbar), nur bei
#'   Matrix-Eingabe fuer die Aggregation; \code{NULL} (Standard) = keine
#'   Aggregation. Bei \code{SimLevParamSearch} wird \code{x$dates} verwendet.
#' @param seed Startwert (ganze Zahl); \code{NULL} (Standard) = kein fester
#'   Startwert. Mit Startwert ist das Ergebnis reproduzierbar und der
#'   Zufallszustand der Sitzung bleibt unveraendert; mit `NULL` wird der
#'   Zufallsstrom der Sitzung normal weitergezogen.
#' @return Objekt der Klasse \code{SimLevRealityCheck}, eine Liste mit
#'   \code{p_rc} (p-Wert Reality Check), \code{p_spa} (p-Wert SPA,
#'   konsistente Variante), \code{p_spa_lower}, \code{p_spa_upper} (untere
#'   und obere SPA-Variante), \code{best} (Name der Spalte mit der hoechsten
#'   mittleren Ueberrendite), \code{mean_excess} (benannter Vektor:
#'   mittlere Ueberrendite je Periode gegenueber \code{benchmark}, Anteil,
#'   nicht annualisiert), \code{n} (Anzahl Perioden), \code{k} (Anzahl
#'   Kandidaten) und \code{B}. Kleiner p-Wert = die beste Strategie schlaegt
#'   die Benchmark auch nach Beruecksichtigung der Auswahl.
#' @seealso [param_search()], [pbo()], [deflated_sharpe()],
#'   [sharpe_test()] (Vergleich zweier Strategien)
#' @examples
#' set.seed(4)
#' R <- matrix(rnorm(800 * 10, 0, 0.01), 800)  # 10 Strategien, Tagesrenditen
#' R[, 2] <- R[, 2] + 0.003                     # eine mit echter Ueberrendite
#' reality_check(R, B = 200, frequency = "day", seed = 1)
#'
#' # Fertige Simulationen: Liste von SimLevResult -> Renditematrix
#' set.seed(1); n <- 3 * 365
#' d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
#' for (k in c("a", "b", "c")) d[[k]] <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
#' res <- list(a = simulation(d, create_strategy(a = asset_config("etf", "bnh"))),
#'             b = simulation(d, create_strategy(b = asset_config("etf", "bnh"))),
#'             c = simulation(d, create_strategy(c = asset_config("etf", "bnh"))))
#' Rr <- sapply(res, function(r) { v <- result_index(r)$value; v[-1] / v[-length(v)] - 1 })
#' reality_check(Rr, benchmark = "c", dates = result_index(res$a)$date[-1],
#'               B = 200, seed = 1)
#' @references White, H. (2000), A reality check for data snooping,
#'   Econometrica 68(5); Hansen, P. R. (2005), A test for superior
#'   predictive ability, Journal of Business & Economic Statistics 23(4).
#' @export
reality_check <- function(x, benchmark = NULL, B = 999L, block = NULL, frequency = c("week", "day", "month"),
                          dates = NULL, seed = NULL) {
  frequency <- match.arg(frequency)
  rr <- .of_returns(x, frequency, dates); R <- rr$R
  if (is.null(benchmark)) b <- rep(0, nrow(R))
  else if (length(benchmark) == 1L) {
    j <- if (is.character(benchmark)) match(benchmark, colnames(R)) else as.integer(benchmark)
    if (is.na(j) || j < 1 || j > ncol(R)) stop("benchmark: unbekannte Spalte.")
    b <- R[, j]; R <- R[, -j, drop = FALSE]
  } else b <- as.numeric(benchmark)
  if (length(b) != nrow(R)) stop("benchmark passt nicht zur L\u00e4nge der Renditen.")
  D <- R - b; Tn <- nrow(D); K <- ncol(D)
  fbar <- colMeans(D)
  block <- block %||% max(2, round(Tn^(1 / 3)))
  Fb <- .with_rng_restore(seed = seed, {
    vapply(seq_len(B), function(i) colMeans(D[.boot_idx_stationary(Tn, Tn, block), , drop = FALSE]), numeric(K)) })
  Fb <- matrix(Fb, nrow = B, ncol = K, byrow = TRUE)          # B x K, auch bei einem Kandidaten (vapply liefert dann einen Vektor)
  om <- pmax(apply(Fb, 2, stats::sd), 1e-12) * sqrt(Tn)
  V <- max(sqrt(Tn) * fbar)
  Vb <- apply(sqrt(Tn) * sweep(Fb, 2, fbar), 1, max)
  p_rc <- mean(Vb >= V)
  Tspa <- max(max(sqrt(Tn) * fbar / om), 0)
  thr <- -sqrt(om^2 / Tn * 2 * log(log(Tn)))
  spa_p <- function(g) { Z <- sweep(Fb, 2, g); Ts <- apply(sweep(sqrt(Tn) * Z, 2, om, "/"), 1, function(z) max(max(z), 0)); mean(Ts >= Tspa) }
  structure(list(p_rc = p_rc, p_spa = spa_p(fbar * (fbar >= thr)), p_spa_lower = spa_p(pmax(fbar, 0)), p_spa_upper = spa_p(fbar),
                 best = colnames(D)[which.max(fbar)] %||% which.max(fbar), mean_excess = fbar, n = Tn, k = K, B = B),
            class = "SimLevRealityCheck")
}

#' @rdname reality_check
#' @param ... ungenutzt.
#' @export
print.SimLevRealityCheck <- function(x, ...) {
  cat(sprintf("Reality Check und SPA: %d Strategien, %d Perioden, B = %d\n", x$k, x$n, x$B))
  cat(sprintf("  Beste Strategie: %s (mittlere \u00dcberrendite %.4f je Periode)\n", x$best, max(x$mean_excess)))
  cat(sprintf("  p-Wert Reality Check (White):   %.3f\n  p-Wert SPA (Hansen, konsistent): %.3f  [untere %.3f, obere %.3f]\n",
              x$p_rc, x$p_spa, x$p_spa_lower, x$p_spa_upper))
  cat("  Lesart: kleiner p-Wert = die beste Strategie schl\u00e4gt die Benchmark auch nach Ber\u00fccksichtigung der Auswahl.\n")
  invisible(x)
}

#' Mindestlaenge einer Historie (Minimum Track Record Length)
#'
#' Wie viele Perioden braucht es, um mit Wahrscheinlichkeit \code{prob}
#' sagen zu koennen, dass die wahre Sharpe Ratio ueber \code{target} liegt?
#' \deqn{MinTRL = 1 + \left(1 - \gamma_3 \widehat{SR} + \frac{\gamma_4 - 1}{4}\widehat{SR}^2\right)
#'       \left(\frac{z_{prob}}{\widehat{SR} - SR^*}\right)^2}
#' Dabei sind \eqn{\widehat{SR}} und \eqn{SR^*} Sharpe Ratios je Periode
#' (Mittelwert / Standardabweichung, ohne Abzug eines risikolosen Zinses),
#' \eqn{\gamma_3} die Schiefe und \eqn{\gamma_4} die Woelbung (nicht
#' Exzess) der Renditen. Eingabe ist ein Renditevektor oder eine fertige
#' Simulation bzw. Kursreihe.
#'
#' @param x Renditequelle: numerischer Vektor einfacher Periodenrenditen als
#'   Anteil (0.01 = 1 %; nicht endliche Werte werden entfernt),
#'   \code{SimLevResult} aus [simulation()] (bereinigter Wertindex aus
#'   [result_index()]) oder \code{data.frame} mit \code{date} und einer
#'   Wertspalte (\code{value}, sonst erste numerische Spalte; Niveaus). Die
#'   beiden letzten werden in Renditen der \code{frequency} umgerechnet.
#' @param target Vergleichs-Sharpe-Ratio \eqn{SR^*} p. a. (Standard 0);
#'   intern durch \eqn{\sqrt{ppy}} geteilt.
#' @param prob Geforderte Sicherheit als Anteil (Standard 0.95 = 95 %).
#' @param frequency Periodenlaenge \code{"week"} (Standard, ISO-Wochen),
#'   \code{"day"} oder \code{"month"}: bei \code{SimLevResult} und
#'   data.frame die Aggregation (Wert am Periodenende); bei Vektoren nur fuer
#'   den Standardwert von \code{ppy}.
#' @param ppy Perioden je Jahr. \code{NULL} (Standard) = bei Vektoren 252
#'   (\code{"day"}), 52 (\code{"week"}) bzw. 12 (\code{"month"}); sonst
#'   geschaetzt als (Anzahl Renditen - 1) / (Zeitspanne in Tagen / 365.25).
#' @return Benannter numerischer Vektor: \code{sharpe} (Sharpe Ratio p. a.),
#'   \code{periods} (vorhandene Perioden), \code{needed_periods} (MinTRL in
#'   Perioden; \code{Inf}, wenn die Sharpe Ratio nicht ueber \code{target}
#'   liegt), \code{needed_years} (\code{needed_periods / ppy}),
#'   \code{available_years} (\code{periods / ppy}) und \code{sufficient}
#'   (1 = \code{periods >= needed_periods}, sonst 0).
#' @seealso [probabilistic_sharpe()], [sharpe_test()], [deflated_sharpe()]
#' @examples
#' set.seed(1)
#' r <- rnorm(520, 0.002, 0.02)          # 10 Jahre Wochenrenditen
#' min_track_record(r, target = 0, ppy = 52)
#' min_track_record(r, target = 0.5, prob = 0.9, ppy = 52)
#' # Kursreihe als data.frame(date, value), Monatsrenditen
#' n <- 10 * 365
#' d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n),
#'                 value = 100 * cumprod(1 + rnorm(n, 4e-4, 0.01)))
#' min_track_record(d, frequency = "month")
#' @references Bailey, D. H. & Lopez de Prado, M. (2012), The Sharpe ratio
#'   efficient frontier, Journal of Risk 15(2).
#' @export
min_track_record <- function(x, target = 0, prob = 0.95, frequency = c("week", "day", "month"), ppy = NULL) {
  frequency <- match.arg(frequency)
  a <- .ret_from(x, frequency); r <- a$r[is.finite(a$r)]
  ppy <- ppy %||% (if (!is.null(a$date)) (length(r) - 1) / (as.numeric(diff(range(a$date))) / 365.25) else switch(frequency, day = 252, week = 52, month = 12))
  sr <- mean(r) / stats::sd(r); sr0 <- target / sqrt(ppy)
  z <- (r - mean(r)) / stats::sd(r); g3 <- mean(z^3); g4 <- mean(z^4)
  need <- if (sr <= sr0) Inf else 1 + (1 - g3 * sr + (g4 - 1) / 4 * sr^2) * (stats::qnorm(prob) / (sr - sr0))^2
  c(sharpe = sr * sqrt(ppy), periods = length(r), needed_periods = need, needed_years = need / ppy,
    available_years = length(r) / ppy, sufficient = as.numeric(length(r) >= need))
}

#' Renditen je Startjahr und Haltedauer
#'
#' Annualisierte Renditen fuer jede Kombination aus Startjahr und
#' Haltedauer (wie die Heatmaps von Portfolio Charts), wahlweise real. Zeigt
#' auf einen Blick, wie stark das Ergebnis vom Einstiegszeitpunkt abhaengt.
#'
#' Grundlage sind die Werte am letzten verfuegbaren Tag jedes Kalenderjahrs.
#' Beginnt die Reihe am 1. Januar, ist der erste Wert der Startwert des
#' ersten Jahres; sonst beginnt die Tabelle mit dem ersten vollen Jahr (bei
#' Handelstagsdaten ohne Wert vom 01.01. also mit dem zweiten). Ein
#' unvollstaendiges letztes Kalenderjahr entfaellt (frueher wurde es wie ein
#' volles Jahr annualisiert); als vollstaendig gilt es, wenn das Datenende
#' hoechstens um die groesste Zeilenluecke der Reihe (hoechstens 7 Tage)
#' vor dem 31.12. liegt, bei Handelstagen also z. B. der 30.12.
#' Die Daten werden nach Datum sortiert, doppelte Daten wie in
#' [deep_analysis()] behandelt.
#'
#' @param x Eine Reihe: \code{SimLevResult} aus [simulation()] (verwendet
#'   wird der um Ein- und Auszahlungen bereinigte Wertindex aus
#'   [result_index()]) oder \code{data.frame} mit Spalte \code{date} und
#'   einer Wertspalte (\code{value}, sonst die erste numerische Spalte;
#'   Niveaus, keine Renditen; fehlende Werte werden fortgeschrieben). Eine
#'   Liste mehrerer Reihen wird nicht angenommen; dafuer die Funktion je
#'   Element aufrufen, z. B. \code{lapply(liste, return_heatmap)}. Bei
#'   \code{print()}/\code{plot()}: Objekt der Klasse \code{SimLevHeatmap}.
#' @param inflation Optional fuer reale Renditen: \code{NULL} (Standard) =
#'   nominal; eine Zahl = Inflationsrate in Prozent p. a. (2 = 2 %), tageweise
#'   aufgezinst mit \eqn{(1 + i/100)^{Tage/365.25}}; oder ein Preisindex als
#'   \code{data.frame(date, Wert)} (Niveaus, z. B. VPI; jeder Wert gilt ab
#'   seinem Datum) bzw. benannter numerischer Vektor mit Datumsnamen. Die
#'   Werte werden durch den Index relativ zum Startdatum geteilt.
#' @param max_years Laengste Haltedauer in Jahren (ganze Zahl, Standard 30);
#'   hoechstens die Zahl der verfuegbaren Jahre.
#' @return Objekt der Klasse \code{SimLevHeatmap}, eine Liste mit
#'   \code{matrix} (Zeilen = Startjahr, Spalten = Haltedauer 1, 2, ... Jahre;
#'   annualisierte Rendite als Anteil, \code{NA} wenn der Zeitraum ueber das
#'   Datenende hinausgeht), \code{summary} (data.frame je Haltedauer:
#'   \code{years}, \code{min}, \code{median}, \code{max} (Anteil p. a.),
#'   \code{share_negative} (Anteil negativer Zeitraeume), \code{n} (Anzahl
#'   Zeitraeume)) und \code{real} (logisch, \code{TRUE} mit
#'   \code{inflation}). \code{print()} zeigt die Zusammenfassung fuer 1, 3,
#'   5, 10, 15, 20, 25 und 30 Jahre in Prozent; \code{plot()} zeichnet die
#'   Heatmap (Farbskala bei +/- 25 % begrenzt).
#' @seealso [deep_analysis()], [result_index()], [simulation()], [deflate()]
#' @examples
#' set.seed(1); n <- 12 * 365
#' d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n))
#' d$value <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
#' hm <- return_heatmap(d, inflation = 2, max_years = 10)   # real, 2 Prozent p. a.
#' hm
#' round(100 * hm$matrix[1:3, 1:3], 1)                        # in Prozent p. a.
#' plot(hm)
#' @export
return_heatmap <- function(x, inflation = NULL, max_years = 30L) {
  s <- .da_series(x, "x")
  if (!is.null(inflation)) s <- .da_deflate(s, inflation)
  yr <- as.integer(format(s$date, "%Y")); m <- length(yr)
  e <- which(c(yr[-1] != yr[-length(yr)], TRUE))
  # Rumpfjahr am Ende weglassen: vollstaendig, wenn das Datenende hoechstens um die groesste
  # Zeilenluecke der Reihe (hoechstens 7 Tage, z. B. Feiertage bei Handelstagen) vor dem 31.12. liegt
  tol <- min(7, max(as.numeric(diff(s$date[c(TRUE, !s$filled[-1])]))))   # nur Zeilen mit echten Werten
  if (as.numeric(as.Date(sprintf("%d-12-31", yr[m])) - s$date[m]) >= tol) e <- e[-length(e)]
  base <- c(s$value[1], s$value[e]); years <- c(yr[1] - 1L, yr[e])
  if (format(s$date[1], "%m-%d") != "01-01") { base <- s$value[e]; years <- yr[e] }   # erstes volles Jahr
  ny <- length(base) - 1L
  if (ny < 1L) stop("return_heatmap: Die Reihe umfasst kein vollst\u00e4ndiges Kalenderjahr.")
  H <- min(max_years, ny)
  M <- matrix(NA_real_, ny, H, dimnames = list(years[-1], seq_len(H)))
  for (i in seq_len(ny)) for (h in seq_len(min(H, ny - i + 1L))) M[i, h] <- (base[i + h] / base[i])^(1 / h) - 1
  summ <- data.frame(years = seq_len(H), min = apply(M, 2, min, na.rm = TRUE), median = apply(M, 2, stats::median, na.rm = TRUE),
                     max = apply(M, 2, max, na.rm = TRUE), share_negative = apply(M, 2, function(v) mean(v < 0, na.rm = TRUE)),
                     n = colSums(!is.na(M)))
  structure(list(matrix = M, summary = summ, real = !is.null(inflation)), class = "SimLevHeatmap")
}

#' @rdname return_heatmap
#' @param ... Bei \code{print()} ungenutzt; bei \code{plot()} an
#'   [graphics::image()] weitergereicht.
#' @export
print.SimLevHeatmap <- function(x, ...) {
  cat(sprintf("Renditen je Startjahr und Haltedauer (%s, annualisiert)\n\n", if (x$real) "real" else "nominal"))
  s <- x$summary; k <- unique(c(1, 3, 5, 10, 15, 20, 25, 30)); s <- s[s$years %in% k, ]
  print(data.frame(Jahre = s$years, Minimum = sprintf("%.1f %%", 100 * s$min), Median = sprintf("%.1f %%", 100 * s$median),
                   Maximum = sprintf("%.1f %%", 100 * s$max), `negativ` = sprintf("%.0f %%", 100 * s$share_negative),
                   Zeitraeume = s$n, check.names = FALSE), row.names = FALSE)
  invisible(x)
}

#' @rdname return_heatmap
#' @export
plot.SimLevHeatmap <- function(x, ...) {
  M <- 100 * x$matrix
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  graphics::par(mar = c(4, 4.4, 2.6, 5.5), mgp = c(2.5, 0.6, 0), las = 1, cex.axis = 0.75)
  lim <- max(abs(M), na.rm = TRUE); lim <- min(lim, 25)
  pal <- grDevices::colorRampPalette(c("#B5562B", "#F2E9DC", "#2C6E9B"))(51)
  yrs <- as.integer(rownames(M))
  Mc <- M; Mc[Mc > lim] <- lim; Mc[Mc < -lim] <- -lim
  graphics::image(yrs, seq_len(ncol(M)), Mc, col = pal, zlim = c(-lim, lim),
                  xlab = "Startjahr", ylab = "Haltedauer (Jahre)",
                  main = sprintf("Annualisierte %s Rendite", if (x$real) "reale" else "nominale"), ...)
  graphics::box()
  graphics::par(xpd = TRUE)
  usr <- graphics::par("usr"); yy <- seq(usr[3], usr[4], length.out = 52)
  graphics::rect(usr[2] + 0.02 * diff(usr[1:2]), yy[-52], usr[2] + 0.05 * diff(usr[1:2]), yy[-1], col = pal, border = NA)
  graphics::text(usr[2] + 0.06 * diff(usr[1:2]), c(usr[3], mean(usr[3:4]), usr[4]), sprintf("%+.0f %%", c(-lim, 0, lim)), adj = 0, cex = 0.7)
  invisible(x)
}
