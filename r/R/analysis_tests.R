# =============================================================================
#  analysis_tests.R  —  Signal-Analyse, statistische Tests, Heatmaps
# -----------------------------------------------------------------------------
#  signal_analysis()    Vorwaertsrenditen je Signalbereich (Regressogramm),
#                       optional fuer zwei Signale und je Zeitabschnitt
#  sharpe_test()        Unterschied zweier Sharpe Ratios (Ledoit & Wolf 2008:
#                       HAC-Delta-Methode oder Block-Bootstrap)
#  overfit_reality_check()      White (2000) Reality Check und Hansen (2005) SPA:
#                       schlaegt die beste von vielen Strategien die
#                       Benchmark mehr als zufaellig?
#  sharpe_min_track_record()   Mindestlaenge einer Historie fuer eine Sharpe-Aussage
#                       (Bailey & Lopez de Prado 2012)
#  result_heatmap()     annualisierte (reale) Renditen je Startjahr und
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
  list(r = v[-1] / v[-length(v)] - 1, date = d[-1], lvl = v, ldate = d)
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
#'       (Welch-t-Test mit Freiheitsgraden nach Welch-Satterthwaite; \code{NA},
#'       wenn einer der beiden Bereiche hoechstens 2 Werte hat oder beide konstant
#'       sind).}
#'     \item{\code{splits}}{Matrix Bereiche x Zeitabschnitte mit der
#'       mittleren Vorwaertsrendite (Anteil), Spaltennamen "Jahr-Jahr";
#'       \code{NULL} bei \code{splits = 1}.}
#'     \item{\code{table2d}}{Liste mit \code{mean} (Matrix Bereich
#'       \code{signal} x Bereich \code{signal2}, mittlere Vorwaertsrendite
#'       als Anteil) und \code{n} (Haeufigkeiten); \code{NULL} ohne
#'       \code{signal2}.}
#'     \item{\code{fit}}{Liste mit \code{model} und \code{r_squared}
#'       (\eqn{R^2 = 1 - RSS/TSS}); \code{NULL} ohne Polynom-Glaettung.
#'       \code{model} ist eine Liste mit \code{coefficients} (Basis 1, z, z^2, ...
#'       mit z = (signal - Mittel) / Standardabweichung), \code{fitted}
#'       (angepasste Werte), \code{degree} und \code{basis} (\code{center},
#'       \code{scale}); bis 0.10.0 war es ein \code{lm}-Objekt mit
#'       orthogonalen Polynomen (angepasste Werte und \eqn{R^2} sind gleich).}
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
  if (!is.data.frame(data) || !"date" %in% names(data)) stop(chk_msg("b2b.m_signal_analysis"))
  chk_col_nofactor(data, "date", "signal_analysis")   # seit 1.6.4 (Entscheidung 15; bis 1.6.3 still in Text umgewandelt)
  n <- nrow(data); d <- .to_date(data$date, "signal_analysis: data$date")
  # seit 1.6.4: Spalten logisch oder numerisch (target numerisch; vorher Faktor-Codes bzw. Text als NA), Vektoren
  # numerisch oder logisch (kein Faktor, keine Liste)
  getcol <- function(v, what, type = "logisch_oder_numerisch") {
    if (is.character(v)) {
      if (length(v) != 1L || !v %in% names(data))
        stop(chk_msg("b2b.m_getcol", what, v[1], paste(names(data), collapse = ", ")))
      chk_col_nofactor(data, v, "signal_analysis")   # Entscheidung 15
      chk_col_type(data, v, "signal_analysis", type)
      return(as.numeric(data[[v]]))
    }
    chk_nofactor(v, "signal_analysis", what)   # Entscheidung 15
    if (!(is.numeric(v) || is.logical(v)) || !is.null(dim(v)))
      chk_stop("e2.spalte_oder_vektor", "signal_analysis", what)
    if (length(v) != n) stop(sprintf("signal_analysis: %s hat L\u00e4nge %d, data hat %d Zeilen.", what, length(v), n))
    as.numeric(v)
  }
  sig <- getcol(signal, "signal")
  if (!is.character(target) || length(target) != 1L) stop(chk_msg("b2b.m_getcol_2"))
  px <- getcol(target, "target", "numerisch")
  s2all <- if (!is.null(signal2)) getcol(signal2, "signal2") else NULL
  # zeitlich sortieren, doppelte Daten (letzter Wert) entfernen
  o <- order(d); o <- o[!is.na(d[o])]; dup <- duplicated(d[o], fromLast = TRUE)
  if (any(dup)) message(sprintf("Hinweis: signal_analysis: %d doppelte Daten; der letzte Wert je Datum wird verwendet.", sum(dup)))
  o <- o[!dup]; d <- d[o]; sig <- sig[o]; px <- px[o]; if (!is.null(s2all)) s2all <- s2all[o]; n <- length(o)
  px <- .fill_na(px, "locf", keep_leading = TRUE)
  # seit 1.6.4: ganze Zahlen (vorher z. B. 2.5 und "21" still mit as.integer), Meldung ohne Eingabewert
  int1 <- function(v) is.numeric(v) && length(v) == 1L && is.finite(v) && v == trunc(v)
  if (!int1(horizon)) chk_stop("ganz", "signal_analysis", "horizon", "1")
  if (!is.null(step) && !(int1(step) && step >= 1)) stop(chk_msg("b2b.m_int1"))
  if (!(int1(bins) && bins >= 2)) stop(chk_msg("b2b.m_int1_2"))
  chk_int1(bins2, "signal_analysis", "bins2", lo = 2)
  chk_int1(splits, "signal_analysis", "splits")
  chk_int1(degree, "signal_analysis", "degree", lo = 0)
  horizon <- as.integer(horizon); step <- as.integer(step %||% horizon)
  if (length(horizon) != 1L || is.na(horizon) || horizon < 1L || horizon >= n)
    stop(sprintf("signal_analysis: horizon muss zwischen 1 und %d (Zeilen - 1) liegen.", n - 1L))
  if (length(step) != 1L || is.na(step) || step < 1L) stop(chk_msg("b2b.m_int1"))
  if (!is.null(breaks) && (!is.numeric(breaks) || length(breaks) < 3L || anyNA(breaks) || is.unsorted(breaks, strictly = TRUE)))
    stop(chk_msg("b2b.m_int1_3"))
  if (is.null(breaks) && (length(bins) != 1L || is.na(bins) || bins < 2)) stop(chk_msg("b2b.m_int1_2"))
  t0 <- seq(1L, n - horizon, by = step)
  fwd <- px[t0 + horizon] / px[t0] - 1
  s2 <- if (!is.null(s2all)) s2all[t0] else NULL
  df <- data.frame(date = d[t0], signal = sig[t0], forward = fwd)
  if (!is.null(s2)) df$signal2 <- s2
  df <- df[stats::complete.cases(df), , drop = FALSE]
  if (nrow(df) < 20) stop(sprintf("signal_analysis: zu wenige Stichtage (%d, mindestens 20) mit Signal und Vorw\u00e4rtsrendite.", nrow(df)))
  if (length(unique(df$signal)) < 2L)
    stop(chk_msg("b2b.m_int1_4"))
  ppy <- (n - 1) / (as.numeric(d[n] - d[1]) / 365.25)
  ann <- function(m) .pow1m(m, ppy / horizon)
  cutb <- function(v, k, br) {
    u <- sort(unique(v))
    br <- br %||% (if (length(u) <= k) c(-Inf, u[-1], Inf)       # wenige Werte (z. B. 0/1): ein Bereich je Wert
                   else unique(stats::quantile(v, seq(0, 1, length.out = k + 1), names = FALSE)))
    br[1] <- -Inf; br[length(br)] <- Inf
    cut(v, br, include.lowest = TRUE, right = FALSE)
  }
  df$bin <- cutb(df$signal, bins, breaks)
  st <- function(z) { m <- mean(z); s <- .sl_sd(z)
    c(n = length(z), mean = m, median = stats::median(z), win_rate = mean(z > 0), sd = s, t = m / (s / sqrt(length(z)))) }
  tab <- do.call(rbind, lapply(split(df, df$bin), function(z) if (nrow(z)) data.frame(
    bin = as.character(z$bin[1]), from = min(z$signal), to = max(z$signal), t(st(z$forward)), annualized = ann(mean(z$forward)),
    check.names = FALSE) else NULL))
  rownames(tab) <- NULL
  lv <- levels(df$bin); lo <- df$forward[df$bin == lv[1]]; hi <- df$forward[df$bin == lv[length(lv)]]
  wt <- if (length(lo) > 2 && length(hi) > 2) .sl_welch_test(hi, lo) else NULL   # Welch-Test
  spread <- c(difference = mean(hi) - mean(lo), t = if (!is.null(wt)) unname(wt$statistic) else NA,
              p = if (!is.null(wt)) wt$p.value else NA)
  ov <- st(df$forward)
  # seit 1.6.5 (CR2-5, Entscheidung 185 K3): bei step < horizon ueberlappen die Vorwaertsrenditen; t je Bereich, t
  # aller Stichtage und der Spread mit Newey-West-Standardfehlern (Bartlett, Lag ceiling(horizon / step) - 1; Mittel
  # je Bereich als Regression auf Bereichs-Dummys, Hansen & Hodrick 1980, Newey & West 1987), p-Wert des Spreads aus
  # der Normalverteilung (bis 1.6.4 wie bei unabhaengigen Stichtagen: viel zu optimistisch)
  if (step < horizon) {
    L <- ceiling(horizon / step) - 1L
    zb <- function(b) { z <- numeric(nrow(df)); i <- df$bin == b; z[i] <- df$forward[i] - mean(df$forward[i]); z }
    for (r in seq_len(nrow(tab))) {
      z <- zb(tab$bin[r]); tab$t[r] <- tab$mean[r] / sqrt(.sa_lrv(z, z, L) / tab$n[r]^2)
    }
    z0 <- df$forward - ov[["mean"]]; ov[["t"]] <- ov[["mean"]] / sqrt(.sa_lrv(z0, z0, L) / nrow(df)^2)
    if (length(lo) > 2 && length(hi) > 2) {
      zh <- zb(lv[length(lv)]); zl <- zb(lv[1])
      v <- .sa_lrv(zh, zh, L) / length(hi)^2 + .sa_lrv(zl, zl, L) / length(lo)^2 -
           2 * .sa_lrv(zh, zl, L) / (length(hi) * length(lo))
      tt <- spread[["difference"]] / sqrt(v)
      spread[["t"]] <- tt; spread[["p"]] <- 2 * .sl_pnorm(-abs(tt))
    }
  }
  fit <- NULL
  if (degree > 0 && length(unique(df$signal)) > degree + 1) {
    m <- .sl_poly_fit(df$signal, df$forward, degree)         # kleinste Quadrate, r^2 aus den Residuen
    fit <- list(model = m[c("coefficients", "fitted", "degree", "basis")], r_squared = m$r_squared)
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
  structure(list(bins = tab, overall = ov, spread = spread, splits = spl, table2d = t2, fit = fit,
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
  yl <- range(100 * c(b$mean - 2 * se, b$mean + 2 * se, 0), finite = TRUE)   # seit 1.6.5 (CR2-X55-1): n = 1 ohne sd
  mids <- graphics::barplot(100 * b$mean, names.arg = seq_len(nrow(b)), col = "#2C6E9B", border = NA, ylim = yl,
                            xlab = "Signalbereich (niedrig -> hoch)", ylab = "Mittlere Vorw\u00e4rtsrendite (%)", main = "Je Signalbereich")
  graphics::arrows(mids, 100 * (b$mean - 2 * se), mids, 100 * (b$mean + 2 * se), angle = 90, code = 3, length = 0.03)
  graphics::abline(h = 100 * x$overall["mean"], lty = 2, col = "#B5562B")
  graphics::plot(x$data$signal, 100 * x$data$forward, pch = 16, cex = 0.4, col = grDevices::adjustcolor("#2C6E9B", 0.4),
                 xlab = x$signal_name, ylab = "Vorw\u00e4rtsrendite (%)", main = "Streudiagramm")
  if (!is.null(x$fit)) { o <- order(x$data$signal); graphics::lines(x$data$signal[o], 100 * x$fit$model$fitted[o], col = "#B5562B", lwd = 2) }
  graphics::abline(h = 0, col = "grey50", lty = 3)
  invisible(x)
}

# Langfristige Kovarianz zweier Reihen mit Bartlett-Gewichten (seit 1.6.5, CR2-5):
# sum(a * b) + sum_l (1 - l / (L + 1)) * (sum(a_t b_{t-l}) + sum(b_t a_{t-l}))
.sa_lrv <- function(a, b, L) {
  n <- length(a); s <- sum(a * b)
  for (l in seq_len(L)) if (l < n) {
    s <- s + (1 - l / (L + 1)) * (sum(a[(l + 1):n] * b[1:(n - l)]) + sum(b[(l + 1):n] * a[1:(n - l)]))
  }
  s
}

# Langfristkovarianz fuer sharpe_test (seit 1.6.5, Entscheidung 177): Bartlett ohne Prewhitening wie bisher
# (.hac_cov, Newey-West); sonst Kern-Schaetzer nach Ledoit & Wolf (2008, Abschnitt 3.1) im Kern (research_vec op 8):
# QS mit Andrews-Bandbreite bzw. Bartlett mit festem Lag, wahlweise Prewhitening (Andrews & Monahan 1992), Faktor T/(T-4)
.st_hac <- function(Y, kernel, prewhiten) {
  if (kernel == "bartlett" && !prewhiten) return(.hac_cov(Y))
  k <- ncol(Y)
  o <- .research_vec(8L, as.numeric(Y), c(nrow(Y), k, if (kernel == "qs") 2 else 1, as.numeric(prewhiten)), k * k + 2L)
  if (o[k * k + 1L] == 1) chk_stop("b2b.st_prewhiten", "sharpe_test")
  if (o[k * k + 1L] == 2) chk_stop("b2b.st_bandbreite", "sharpe_test")
  matrix(o[seq_len(k * k)], k, k)
}

#' Newey-West-Kovarianz (Bartlett-Kern)
#' @keywords internal
#' @noRd
.hac_cov <- function(Y, lag = NULL) {
  Tn <- nrow(Y); lag <- lag %||% floor(4 * (Tn / 100)^(2 / 9))
  Yc <- sweep(Y, 2, colMeans(Y)); S <- .sl_crossprod(Yc) / Tn
  for (l in seq_len(lag)) { G <- .sl_crossprod(Yc[(l + 1):Tn, , drop = FALSE], Yc[1:(Tn - l), , drop = FALSE]) / Tn
    S <- S + (1 - l / (lag + 1)) * (G + t(G)) }
  S
}

#' Test auf gleiche Sharpe Ratios
#'
#' Prueft, ob sich die Sharpe Ratios zweier Strategien unterscheiden, robust
#' gegen Autokorrelation, Heteroskedastie und dicke Raender (Ledoit & Wolf
#' 2008): mit der Delta-Methode und Newey-West-Kovarianz (\code{"hac"}) oder
#' einem Block-Bootstrap der Renditepaare (\code{"bootstrap"}, seit 1.6.5 studentisiert und zirkulaer wie bei
#' Ledoit & Wolf).
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
#' Studentisierter Bootstrap (Standard bei \code{method = "bootstrap"} seit 1.6.5, Ledoit & Wolf 2008,
#' Abschnitt 3.2.2 und Bemerkung 3.2): \eqn{\Delta = \mu_x/\sigma_x - \mu_y/\sigma_y}; Standardfehler
#' \eqn{s(\hat\Delta) = \sqrt{\nabla f' \hat\Psi \nabla f / T}} (Gl. 5) mit der HAC-Kovarianz der Momente
#' \eqn{(r_x, r_y, r_x^2, r_y^2)}; Teststatistik \eqn{d = |\hat\Delta| / s(\hat\Delta)}. Je Wiederholung
#' \eqn{m} werden Bloecke der festen Laenge \eqn{b} mit gleichverteiltem Start zyklisch gezogen; der
#' Standardfehler der Stichprobe ist \eqn{s(\hat\Delta^*_m)} aus
#' \eqn{\hat\Psi^* = l^{-1} \sum_{j=1}^{l} \zeta_j \zeta_j'}, \eqn{\zeta_j = b^{-1/2} \sum_{t=1}^{b} y^*_{(j-1)b+t}},
#' \eqn{l = \lfloor T/b \rfloor} (Gl. 8), \eqn{d^*_m = |\hat\Delta^*_m - \hat\Delta| / s(\hat\Delta^*_m)}.
#' p-Wert \eqn{(\#\{d^*_m \ge d\} + 1)/(B + 1)} (Gl. 9), Intervall
#' \eqn{\hat\Delta \pm z^*_{0.95}\, s(\hat\Delta)} mit dem 95-%-Quantil der \eqn{d^*_m} (Gl. 7); \code{se} ist
#' \eqn{s(\hat\Delta)}, \code{z} = \code{difference / se}. Die Blocklaenge waehlt SimLev nicht
#' datenabhaengig (die Kalibrierung von Ledoit & Wolf, Algorithmus 3.1, ist nicht umgesetzt).
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
#'   HAC-Kovarianz (Standard Newey-West, Bartlett-Kern, Lag
#'   \eqn{\lfloor 4 (T/100)^{2/9} \rfloor}; siehe \code{kernel}, \code{prewhiten}); \code{"bootstrap"}:
#'   seit 1.6.5 studentisierter zirkulaerer Block-Bootstrap der Renditepaare nach Ledoit & Wolf (2008,
#'   Abschnitt 3.2.2, siehe \code{studentize} und Details); mit \code{studentize = FALSE}
#'   stationaerer Block-Bootstrap wie bis 1.6.4 (Standardfehler =
#'   Standardabweichung der Bootstrap-Differenzen, p-Wert = Anteil der
#'   Wiederholungen mit \eqn{|d^* - d| \ge |d|}, Intervall = 2.5- und
#'   97.5-%-Quantil der Bootstrap-Differenzen).
#' @param B Anzahl Bootstrap-Wiederholungen (ganze Zahl, Standard 2000); nur
#'   bei \code{method = "bootstrap"}.
#'   Seit 1.6.4 hoechstens 10^8.
#' @param block Blocklaenge in Perioden: mit \code{studentize = TRUE} die feste Laenge \eqn{b} der Bloecke des
#'   zirkulaeren Block-Bootstraps (ganze Zahl), sonst die mittlere Blocklaenge des stationaeren Bootstraps
#'   (geometrisch verteilte Blocklaengen, Bloecke laufen zyklisch ueber das
#'   Ende); \code{NULL} (Standard) = \code{max(2, round(T^(1/3)))} mit
#'   \eqn{T} = Anzahl Renditepaare. Nur bei \code{method = "bootstrap"}.
#'   Seit 1.6.4 eine Zahl >= 1. Mit \code{studentize = TRUE} seit 1.6.5 hoechstens
#'   \eqn{T/4}: die Block-Kovarianz \eqn{\hat\Psi^*} braucht mindestens 4 Bloecke
#'   (\eqn{l = \lfloor T/b \rfloor \ge 4}, sonst Fehler; bei weniger Bloecken ist sie
#'   singulaer und p-Wert und Intervall sind unbrauchbar). Die Guete des Tests sinkt schon
#'   vorher mit wachsender Blocklaenge; \eqn{T/4} ist nur die Mindestbedingung.
#' @param ppy Perioden je Jahr fuer die Annualisierung. \code{NULL}
#'   (Standard) = bei Vektoren 252 (\code{"day"}), 52 (\code{"week"}) bzw. 12
#'   (\code{"month"}); bei Ergebnissen und data.frames aus den gemeinsamen
#'   Daten geschaetzt: (Anzahl Perioden - 1) / (Zeitspanne in Tagen /
#'   365.25).
#'   Seit 1.6.4 eine Zahl > 0.
#' @param seed Startwert fuer den Bootstrap (Standard \code{NULL}). Mit Startwert (ganze Zahl, \eqn{|seed| < 2^{53}}) ist das Ergebnis reproduzierbar und der
#'   Zufallszustand von SimLev bleibt unveraendert; mit \code{NULL} wird genau einmal ein
#'   Startwert aus dem Zufallszustand von SimLev gezogen (siehe [simlev_seed()]), wiederholte
#'   Aufrufe liefern dann verschiedene Ergebnisse. \code{set.seed()} wirkt nicht.
#' @param studentize Logisch (seit 1.6.5, Standard \code{TRUE}): bei \code{method = "bootstrap"} der
#'   studentisierte zirkulaere Block-Bootstrap nach Ledoit & Wolf (2008); \code{FALSE} = der nicht studentisierte
#'   stationaere Block-Bootstrap bis 1.6.4 (bitgleich).
#' @param kernel Kern der HAC-Kovarianz (seit 1.6.5): \code{"bartlett"} (Lag
#'   \eqn{\lfloor 4 (T/100)^{2/9} \rfloor}) oder \code{"qs"} (Quadratic Spectral mit automatischer Bandbreite
#'   \eqn{S_T = 1.3221 (\hat\alpha(2) T)^{1/5}} nach Andrews 1991 aus AR(1)-Naeherungen je Moment).
#'   \code{NULL} (Standard) = \code{"bartlett"} bei \code{method = "hac"} (bitgleich zu 1.6.4 ausser 142),
#'   \code{"qs"} beim studentisierten Bootstrap (Standardfehler der Ausgangsstichprobe wie bei Ledoit & Wolf 2008).
#' @param prewhiten Logisch (seit 1.6.5): Prewhitening mit einem VAR(1) nach Andrews & Monahan (1992).
#'   \code{NULL} (Standard) = \code{FALSE} bei \code{method = "hac"}, \code{TRUE} beim studentisierten
#'   Bootstrap. Ausser bei Bartlett ohne Prewhitening (Newey-West wie bisher) rechnet SimLev den Schaetzer von
#'   Ledoit & Wolf (2008, Abschnitt 3.1) mit dem Faktor \eqn{T/(T-4)}.
#' @return Benannter numerischer Vektor: \code{sharpe_x}, \code{sharpe_y}
#'   (Sharpe Ratios p. a.), \code{difference} (\code{sharpe_x - sharpe_y},
#'   p. a.), \code{se} (Standardfehler der Differenz, p. a.), \code{z}
#'   (\code{difference / se}), \code{p_value} (zweiseitig, Anteil),
#'   \code{ci_low}, \code{ci_high} (95-%-Intervall der Differenz, p. a.) und
#'   \code{n} (Anzahl verwendeter Renditepaare).
#' @seealso [sharpe_min_track_record()], [sharpe_probabilistic()],
#'   [overfit_reality_check()] (viele Strategien gegen eine Benchmark),
#'   [result_analysis()]
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
#'
#'   Andrews, D. W. K. (1991), Heteroskedasticity and autocorrelation consistent covariance matrix estimation,
#'   Econometrica 59(3), 817-858.
#'
#'   Andrews, D. W. K. & Monahan, J. C. (1992), An improved heteroskedasticity and autocorrelation consistent
#'   covariance matrix estimator, Econometrica 60(4), 953-966.
#' @export
sharpe_test <- function(x, y, frequency = c("week", "day", "month"), method = c("hac", "bootstrap"),
                        B = 2000L, block = NULL, ppy = NULL, seed = NULL, studentize = TRUE, kernel = NULL,
                        prewhiten = NULL) {
  .e5_choice(frequency, c("week", "day", "month"), "sharpe_test", "frequency")   # seit 1.6.4 (K43 T2-N4) Pruefung vor match.arg (Meldung auswahl)
  .e5_choice(method, c("hac", "bootstrap"), "sharpe_test", "method")
  frequency <- match.arg(frequency); method <- match.arg(method)
  # seit 1.6.4: B, block, ppy und seed vor der Rechnung
  chk_int1(B, "sharpe_test", "B")
  chk_max(B, SL_MAX_N, "sharpe_test", "B")   # seit 1.6.4 (Entscheidung 16, wie n)
  chk_num1(block, "sharpe_test", "block", lo = 1, null_ok = TRUE)
  chk_num1(ppy, "sharpe_test", "ppy", lo = 0, lo_open = TRUE, null_ok = TRUE)
  if (!is.null(seed)) .sl_check_seed(seed, "sharpe_test")
  # seit 1.6.5 (Entscheidung 177): studentisierter zirkulaerer Block-Bootstrap (Standard), Kern und Prewhitening
  chk_bool1(studentize, "sharpe_test", "studentize")
  if (!is.null(kernel)) .e5_choice(kernel, c("bartlett", "qs"), "sharpe_test", "kernel")
  if (!is.null(prewhiten)) chk_bool1(prewhiten, "sharpe_test", "prewhiten")
  stud <- method == "bootstrap" && studentize
  kernel <- kernel %||% (if (stud) "qs" else "bartlett"); prewhiten <- prewhiten %||% stud
  if (stud && !is.null(block) && block != trunc(block)) chk_stop("b2b.st_block_ganz", "sharpe_test")
  a <- .ret_from(x, frequency); b <- .ret_from(y, frequency)
  if (is.null(a$date) != is.null(b$date))
    stop(chk_msg("b2b.m_sharpe_test"))
  if (!is.null(a$date)) {                                         # dann auch b$date (Pruefung oben)
    # seit 1.6.5 (CR2-H-2, Entscheidung 189): erst die gemeinsamen Perioden-Enddaten, dann die Renditen zwischen
    # ihnen (bis 1.6.4 Renditen je Reihe, nach einer Luecke in nur einer Reihe Mehr- neben Einperiodenrendite)
    la <- as.numeric(a$ldate); lb <- as.numeric(b$ldate)
    cl <- intersect(la, lb)
    nskip <- length(setdiff(la, cl)) + length(setdiff(lb, cl))
    if (nskip > 0L) message(chk_msg("b2.st_luecke", "sharpe_test", nskip))
    va <- a$lvl[match(cl, la)]; vb <- b$lvl[match(cl, lb)]; m <- length(cl)
    ra <- if (m > 1) va[-1] / va[-m] - 1 else numeric(0); rb <- if (m > 1) vb[-1] / vb[-m] - 1 else numeric(0)
    common <- cl[-1]
    ppy <- ppy %||% ((length(common) - 1) / (diff(range(common)) / 365.25))
  } else {
    if (length(a$r) != length(b$r)) stop(sprintf("sharpe_test: Renditevektoren x und y m\u00fcssen gleich lang und zeitgleich sein (L\u00e4ngen %d und %d).",
                                                 length(a$r), length(b$r)))
    ra <- a$r; rb <- b$r; ppy <- ppy %||% switch(frequency, day = 252, week = 52, month = 12)
  }
  ok <- is.finite(ra) & is.finite(rb); ra <- ra[ok]; rb <- rb[ok]; Tn <- length(ra)
  if (Tn < 10) stop(sprintf("sharpe_test: zu wenige gemeinsame Renditepaare (%d, mindestens 10).", Tn))
  for (k in c("x", "y")) if (.sl_sd(if (k == "x") ra else rb) == 0)
    stop(chk_msg("b2b.m_sharpe_test_2", k))
  sr <- function(r) mean(r) / .sl_sd(r)
  d0 <- sr(ra) - sr(rb)
  if (identical(ra, rb))                                      # identische Reihen: kein Unterschied, kein Test noetig
    return(c(sharpe_x = sr(ra) * sqrt(ppy), sharpe_y = sr(rb) * sqrt(ppy), difference = 0, se = 0, z = 0, p_value = 1,
             ci_low = 0, ci_high = 0, n = Tn))
  if (method == "hac" || stud) {
    # seit 1.6.5 (Entscheidung 142): Schwankung ueber die Abweichungen vom Mittel (bis 1.6.4 mean(r^2) - mean(r)^2,
    # Stellenverlust bei ruhigen Reihen)
    mu <- c(mean(ra), mean(rb)); g <- c(mean(ra^2), mean(rb^2))
    vv <- c(mean((ra - mu[1])^2), mean((rb - mu[2])^2))
    grad <- c(g[1] / vv[1]^1.5, -g[2] / vv[2]^1.5, -0.5 * mu[1] / vv[1]^1.5, 0.5 * mu[2] / vv[2]^1.5)
    Psi <- .st_hac(cbind(ra, rb, ra^2, rb^2), kernel, prewhiten)
    se <- sqrt(drop(t(grad) %m% Psi %m% grad) / Tn)
    z <- d0 / se; p <- 2 * .sl_pnorm(-abs(z)); ci <- d0 + c(-1, 1) * .sl_qnorm(0.975) * se
  }
  if (stud) {
    # seit 1.6.5 (Entscheidung 177): studentisierter zirkulaerer Block-Bootstrap nach Ledoit & Wolf (2008, Abschnitt
    # 3.2.2, Bemerkung 3.2): d = |Delta| / s(Delta) mit dem HAC-Standardfehler oben, je Stichprobe m
    # d*_m = |Delta*_m - Delta| / s(Delta*_m) (Gl. 8, Block-Kovarianz im Kern), p = (#{d*_m >= d} + 1) / (B + 1) (Gl. 9),
    # Intervall Delta +- q_0.95(d*) s(Delta) (Gl. 7)
    block <- block %||% max(2, round(Tn^(1 / 3)))
    if (block > Tn) chk_stop("b2.st_block", "sharpe_test", Tn)
    # seit 1.6.5 (PR2-1): mindestens 4 Bloecke (l = floor(T / b) >= 4), sonst ist die 4x4-Block-Kovarianz singulaer
    if (4 * block > Tn) chk_stop("pf2.st_bloecke", "sharpe_test", Tn %/% 4L, Tn)
    S <- .sl_main_stream(seed, "sharpe_test")                                  # Hauptstrom
    dk <- .research_vec(9L, c(ra, rb), c(Tn, block), 2L)[1]                    # Delta wie im Kern
    ds <- vapply(seq_len(B), function(i) { k <- .sl_boot_idx_block(Tn, Tn, block, TRUE, stream = S)
      o <- .research_vec(9L, c(ra[k], rb[k]), c(Tn, block), 2L)
      if (is.na(o[1]) || !(o[2] > 0)) NA_real_ else abs(o[1] - dk) / o[2] }, 0)
    if (anyNA(ds)) chk_stop("b2.st_var0", "sharpe_test", sum(is.na(ds)), B)
    p <- (sum(ds >= abs(dk) / se) + 1) / (B + 1)
    ci <- d0 + c(-1, 1) * stats::quantile(ds, 0.95, names = FALSE) * se
  } else if (method == "bootstrap") {
    block <- block %||% max(2, round(Tn^(1 / 3)))
    if (block > Tn) chk_stop("b2.st_block", "sharpe_test", Tn)          # seit 1.6.5 (CR2-H-1)
    S <- .sl_main_stream(seed, "sharpe_test")                                  # Hauptstrom
    # seit 1.6.5 (CR2-H-1): Stichproben mit Varianz 0 gezaehlt, dann klare Meldung (bis 1.6.4 Rohfehler)
    db <- vapply(seq_len(B), function(i) { k <- .sl_boot_idx_stationary(Tn, Tn, block, stream = S)
      if (.sl_sd(ra[k]) == 0 || .sl_sd(rb[k]) == 0) NA_real_ else sr(ra[k]) - sr(rb[k]) }, 0)
    if (anyNA(db)) chk_stop("b2.st_var0", "sharpe_test", sum(is.na(db)), B)
    se <- .sl_sd(db); z <- d0 / se; p <- mean(abs(db - d0) >= abs(d0))
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
#'       Renditen (\code{keep_returns = "day"}); verwendet werden
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
#'   Seit 1.6.4 hoechstens 10^8.
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
#' @param seed Startwert (Standard \code{NULL}). Mit Startwert (ganze Zahl, \eqn{|seed| < 2^{53}}) ist das Ergebnis reproduzierbar und der
#'   Zufallszustand von SimLev bleibt unveraendert; mit \code{NULL} wird genau einmal ein
#'   Startwert aus dem Zufallszustand von SimLev gezogen (siehe [simlev_seed()]), wiederholte
#'   Aufrufe liefern dann verschiedene Ergebnisse. \code{set.seed()} wirkt nicht.
#' @return Objekt der Klasse \code{SimLevRealityCheck}, eine Liste mit
#'   \code{p_rc} (p-Wert Reality Check), \code{p_spa} (p-Wert SPA,
#'   konsistente Variante), \code{p_spa_lower}, \code{p_spa_upper} (untere
#'   und obere SPA-Variante), \code{best} (Name der Spalte mit der hoechsten
#'   mittleren Ueberrendite), \code{mean_excess} (benannter Vektor:
#'   mittlere Ueberrendite je Periode gegenueber \code{benchmark}, Anteil,
#'   nicht annualisiert), \code{n} (Anzahl Perioden), \code{k} (Anzahl
#'   Kandidaten) und \code{B}. Kleiner p-Wert = die beste Strategie schlaegt
#'   die Benchmark auch nach Beruecksichtigung der Auswahl.
#' @seealso [param_search()], [overfit_pbo()], [sharpe_deflated()],
#'   [sharpe_test()] (Vergleich zweier Strategien)
#' @examples
#' set.seed(4)
#' R <- matrix(rnorm(800 * 10, 0, 0.01), 800)  # 10 Strategien, Tagesrenditen
#' R[, 2] <- R[, 2] + 0.003                     # eine mit echter Ueberrendite
#' overfit_reality_check(R, B = 200, frequency = "day", seed = 1)
#'
#' # Fertige Simulationen: Liste von SimLevResult -> Renditematrix
#' set.seed(1); n <- 3 * 365
#' d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
#' for (k in c("a", "b", "c")) d[[k]] <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
#' res <- list(a = simulation(d, create_strategy(a = asset_config("etf", "bnh"))),
#'             b = simulation(d, create_strategy(b = asset_config("etf", "bnh"))),
#'             c = simulation(d, create_strategy(c = asset_config("etf", "bnh"))))
#' Rr <- sapply(res, function(r) { v <- result_index(r)$value; v[-1] / v[-length(v)] - 1 })
#' overfit_reality_check(Rr, benchmark = "c", dates = result_index(res$a)$date[-1],
#'               B = 200, seed = 1)
#' @references White, H. (2000), A reality check for data snooping,
#'   Econometrica 68(5); Hansen, P. R. (2005), A test for superior
#'   predictive ability, Journal of Business & Economic Statistics 23(4).
#' @export
overfit_reality_check <- function(x, benchmark = NULL, B = 999L, block = NULL, frequency = c("week", "day", "month"),
                          dates = NULL, seed = NULL) {
  .e5_choice(frequency, c("week", "day", "month"), "overfit_reality_check", "frequency")   # seit 1.6.4 (K43 T2-N4) Pruefung vor match.arg (Meldung auswahl)
  frequency <- match.arg(frequency)
  # seit 1.6.4: benchmark nur Zahl(en) oder Name (vorher Faktor als Codes), Spaltennummer ganz; B, block, seed vorab
  chk_nofactor(benchmark, "overfit_reality_check", "benchmark")   # Entscheidung 15
  if (!is.null(benchmark) && (!length(benchmark) || !is.null(dim(benchmark)) ||
                              !(is.numeric(benchmark) || (is.character(benchmark) && length(benchmark) == 1L))))
    chk_stop("e2.benchmark", "overfit_reality_check")
  chk_int1(B, "overfit_reality_check", "B")
  chk_max(B, SL_MAX_N, "overfit_reality_check", "B")   # seit 1.6.4 (Entscheidung 16, wie n)
  chk_num1(block, "overfit_reality_check", "block", lo = 1, null_ok = TRUE)
  if (!is.null(seed)) .sl_check_seed(seed, "overfit_reality_check")
  fn <- "overfit_reality_check"
  rr <- .of_returns(x, frequency, dates); R <- rr$R
  if (is.null(benchmark)) b <- rep(0, nrow(R))
  else if (length(benchmark) == 1L) {
    # seit 1.6.5 (CR2-D-5, Entscheidung 185 K7): eine Nummer zaehlt die Spalten der Eingabe (bei einer Suche die id),
    # nicht die nach dem Verwerfen leerer Spalten verbliebenen; eine leere Spalte ist ein Fehler
    if (is.character(benchmark)) j <- match(benchmark, colnames(R))
    else {
      j0 <- if (is.finite(benchmark) && benchmark == trunc(benchmark)) benchmark else NA
      j <- if (is.na(j0)) NA_integer_ else match(j0, rr$cols)
      if (is.na(j) && !is.na(j0) && j0 >= 1 && j0 <= max(rr$cols)) chk_stop("b2.bench_leer", fn)
    }
    if (is.na(j)) chk_stop("b2.bench_spalte", fn)
    b <- R[, j]; R <- R[, -j, drop = FALSE]
  } else b <- as.numeric(benchmark)
  if (length(b) != nrow(R)) chk_stop("rs.benchmark_laenge", "overfit_reality_check")
  # seit 1.6.5 (CR2-X9-1, Entscheidung 189): Vergleichsreihe mit Inf ist ein Fehler; Perioden mit NA/NaN in der
  # Vergleichsreihe entfallen fuer alle Strategien (bis 1.6.4: R NA, Python p-Werte 0, Julia Rohfehler)
  if (any(is.infinite(b))) chk_stop("b2.bench_inf", fn)
  if (anyNA(b)) { ok <- !is.na(b); R <- R[ok, , drop = FALSE]; b <- b[ok] }
  # seit 1.6.5 (CR2-D-6): mindestens drei Perioden (bei zwei ist die SPA-Schwelle log(log(2)) < 0 nicht definiert)
  if (nrow(R) < 3L) chk_stop("b2.rc_perioden", fn)
  D <- R - b; Tn <- nrow(D); K <- ncol(D)
  fbar <- colMeans(D)
  block <- block %||% max(2, round(Tn^(1 / 3)))
  S <- .sl_main_stream(seed, "overfit_reality_check")                                    # Hauptstrom
  # colMeans(D[idx, , drop = FALSE]) ohne die Zeilenkopie (seit 1.6.3 Kern sl_r_colsums_idx, gleiche Summanden in
  # gleicher Folge wie colMeans; D ist eine double-Matrix (R - b); Ergebnis ohne Namen, die matrix() unten verwirft)
  Fb <- vapply(seq_len(B), function(i) .Call(C_sl_r_colsums_idx, D, .sl_boot_idx_stationary(Tn, Tn, block, stream = S),
                                             FALSE, TRUE), numeric(K))
  Fb <- matrix(Fb, nrow = B, ncol = K, byrow = TRUE)          # B x K, auch bei einem Kandidaten (vapply liefert dann einen Vektor)
  om <- pmax(apply(Fb, 2, .sl_sd), 1e-12) * sqrt(Tn)
  V <- max(sqrt(Tn) * fbar)
  # Zeilenmaxima seit 1.6.4 ueber pmax statt apply je Zeile (B-109); die Maxima gehen nur in Vergleiche ein (NA wie NaN)
  Vb <- do.call(pmax, unname(as.data.frame(sqrt(Tn) * sweep(Fb, 2, fbar))))
  p_rc <- mean(Vb >= V)
  Tspa <- max(max(sqrt(Tn) * fbar / om), 0)
  thr <- -sqrt(om^2 / Tn * 2 * log(log(Tn)))
  spa_p <- function(g) { Z <- sweep(Fb, 2, g)
    Ts <- do.call(pmax, c(unname(as.data.frame(sweep(sqrt(Tn) * Z, 2, om, "/"))), list(0))); mean(Ts >= Tspa) }
  structure(list(p_rc = p_rc, p_spa = spa_p(fbar * (fbar >= thr)), p_spa_lower = spa_p(pmax(fbar, 0)), p_spa_upper = spa_p(fbar),
                 best = colnames(D)[which.max(fbar)] %||% which.max(fbar), mean_excess = fbar, n = Tn, k = K, B = B),
            class = "SimLevRealityCheck")
}

#' @rdname overfit_reality_check
#' @param ... ungenutzt.
#' @export
print.SimLevRealityCheck <- function(x, ...) {
  # seit 1.6.5 (CR2-W3-3): "1 Strategie"
  cat(sprintf("Reality Check und SPA: %d %s, %d Perioden, B = %d\n", x$k, if (x$k == 1) "Strategie" else "Strategien", x$n, x$B))
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
#'   Seit 1.6.4 mindestens zwei endliche Renditen, die nicht alle gleich sind (sonst Fehler, in allen Sprachen wie
#'   bisher in R).
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
#' @seealso [sharpe_probabilistic()], [sharpe_test()], [sharpe_deflated()]
#' @examples
#' set.seed(1)
#' r <- rnorm(520, 0.002, 0.02)          # 10 Jahre Wochenrenditen
#' sharpe_min_track_record(r, target = 0, ppy = 52)
#' sharpe_min_track_record(r, target = 0.5, prob = 0.9, ppy = 52)
#' # Kursreihe als data.frame(date, value), Monatsrenditen
#' n <- 10 * 365
#' d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n),
#'                 value = 100 * cumprod(1 + rnorm(n, 4e-4, 0.01)))
#' sharpe_min_track_record(d, frequency = "month")
#' @references Bailey, D. H. & Lopez de Prado, M. (2012), The Sharpe ratio
#'   efficient frontier, Journal of Risk 15(2).
#' @export
sharpe_min_track_record <- function(x, target = 0, prob = 0.95, frequency = c("week", "day", "month"), ppy = NULL) {
  .e5_choice(frequency, c("week", "day", "month"), "sharpe_min_track_record", "frequency")   # seit 1.6.4 (K43 T2-N4) Pruefung vor match.arg (Meldung auswahl)
  frequency <- match.arg(frequency)
  # seit 1.6.4: target endlich, prob in (0, 1), ppy > 0
  chk_num1(target, "sharpe_min_track_record", "target")
  chk_num1(prob, "sharpe_min_track_record", "prob", lo = 0, hi = 1, lo_open = TRUE, hi_open = TRUE)
  chk_num1(ppy, "sharpe_min_track_record", "ppy", lo = 0, lo_open = TRUE, null_ok = TRUE)
  a <- .ret_from(x, frequency); r <- a$r[is.finite(a$r)]
  # seit 1.6.4 (Entscheidung 37): entartete Renditen (weniger als zwei, alle gleich) sind ein Fehler in allen Sprachen
  # (bis 1.6.3 R "missing value where TRUE/FALSE needed" bzw. NaN, Python und Julia "nicht ausreichend")
  if (length(r) < 2L || !(.sl_sd(r) > 0)) chk_stop("renditen_entartet", "sharpe_min_track_record")
  ppy <- ppy %||% (if (!is.null(a$date)) (length(r) - 1) / (as.numeric(diff(range(a$date))) / 365.25) else switch(frequency, day = 252, week = 52, month = 12))
  sr <- mean(r) / .sl_sd(r); sr0 <- target / sqrt(ppy)
  z <- (r - mean(r)) / .sl_sd(r); g3 <- mean(z^3); g4 <- mean(z^4)
  need <- if (sr <= sr0) Inf else 1 + (1 - g3 * sr + (g4 - 1) / 4 * sr^2) * (.sl_qnorm(prob) / (sr - sr0))^2
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
#' [result_analysis()] behandelt.
#' Seit 1.6.5 zaehlt die Haltedauer in Kalenderjahren: fehlt ein Kalenderjahr in den Daten, bleiben die Zellen,
#' die es als Start- oder Endjahr brauchen, leer (bis 1.6.4 zaehlten die Zeilen der Jahresend-Tabelle). Bei groben
#' Daten (mittlerer Zeilenabstand ueber 7 Tage, z. B. Monatsdaten am Monatsersten) ist das Jahresende der letzte Wert
#' im Dezember und das erste, unvollstaendige Jahr entfaellt; bei Jahresdaten (eine Zeile je Jahr) entfaellt das erste
#' Jahr. Fallen alle Zeilen auf den 1.1. (Jahresdaten zum Jahresanfang), gilt jeder Wert als Jahresende des Vorjahres:
#' die Rendite vom 1.1.2010 zum 1.1.2011 steht in der Zeile 2010 (bis 1.6.4 und bei anderen Daten das Jahr des Datums).
#'
#' @param x Eine Reihe: \code{SimLevResult} aus [simulation()] (verwendet
#'   wird der um Ein- und Auszahlungen bereinigte Wertindex aus
#'   [result_index()]) oder \code{data.frame} mit Spalte \code{date} und
#'   einer Wertspalte (\code{value}, sonst die erste numerische Spalte;
#'   Niveaus, keine Renditen; fehlende Werte werden fortgeschrieben). Eine
#'   Liste mehrerer Reihen wird nicht angenommen; dafuer die Funktion je
#'   Element aufrufen, z. B. \code{lapply(liste, result_heatmap)}. Bei
#'   \code{print()}/\code{plot()}: Objekt der Klasse \code{SimLevHeatmap}.
#' @param inflation Optional fuer reale Renditen: \code{NULL} (Standard) =
#'   nominal; eine Zahl = Inflationsrate in Prozent p. a. (2 = 2 %), tageweise
#'   aufgezinst mit \eqn{(1 + i/100)^{Tage/365.25}}; oder ein Preisindex als
#'   \code{data.frame(date, Wert)} (Niveaus, z. B. VPI; jeder Wert gilt ab
#'   seinem Datum) bzw. benannter numerischer Vektor mit Datumsnamen. Die
#'   Werte werden durch den Index relativ zum Startdatum geteilt.
#' @param max_years Laengste Haltedauer in Jahren (ganze Zahl, Standard 30);
#'   hoechstens die Zahl der verfuegbaren Jahre.
#'   Seit 1.6.4 hoechstens 100.
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
#' @seealso [result_analysis()], [result_index()], [simulation()], [series_deflate()]
#' @examples
#' set.seed(1); n <- 12 * 365
#' d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n))
#' d$value <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
#' hm <- result_heatmap(d, inflation = 2, max_years = 10)   # real, 2 Prozent p. a.
#' hm
#' round(100 * hm$matrix[1:3, 1:3], 1)                        # in Prozent p. a.
#' plot(hm)
#' @export
result_heatmap <- function(x, inflation = NULL, max_years = 30L) {
  chk_int1(max_years, "result_heatmap", "max_years")   # seit 1.6.4 (vorher z. B. 2.5 oder -2 je Sprache anders)
  chk_max(max_years, SL_MAX_JAHRE, "result_heatmap", "max_years")   # Entscheidungen 16 und 46
  s <- .da_series(x, "x")
  if (!is.null(inflation)) s <- .da_deflate(s, inflation)
  # seit 1.6.5 (CR2-N-1, Entscheidung 195 F2 Weg b): fallen alle Zeilen auf den 1.1. (Jahresdaten zum Jahresanfang),
  # gilt jeder Wert als Jahresende des Vorjahres (Zeile und Beschriftung); sonst zaehlt das Jahr des Datums
  jan1 <- length(s$date) > 1L && all(format(s$date, "%m-%d") == "01-01")
  dt <- if (jan1) s$date - 1 else s$date
  yr <- as.integer(format(dt, "%Y")); m <- length(yr)
  e <- which(c(yr[-1] != yr[-length(yr)], TRUE))
  # Rumpfjahr am Ende weglassen: vollstaendig, wenn das Datenende hoechstens um die groesste
  # Zeilenluecke der Reihe (hoechstens 7 Tage, z. B. Feiertage bei Handelstagen) vor dem 31.12. liegt
  gaps <- as.numeric(diff(s$date[c(TRUE, !s$filled[-1])]))       # nur Zeilen mit echten Werten
  tol <- min(7, max(gaps))
  # seit 1.6.5 (CR2-N-1, Entscheidung 189): Haltedauer nach Kalenderjahren (fehlendes Jahr = leere Zellen); grobe Daten
  # (mittlerer Zeilenabstand ueber 7 Tage, z. B. Monatsdaten am Monatsersten): Jahresende ist der Dezemberwert, das
  # erste Jahr entfaellt; Jahresdaten (eine Zeile je Jahr) wie bisher bis auf das erste Jahr
  coarse <- length(gaps) > 0L && stats::median(gaps) > 7
  annual <- !anyDuplicated(yr)
  last_ok <- as.numeric(as.Date(sprintf("%d-12-31", yr[m])) - dt[m]) < tol
  ok <- if (coarse && !annual) as.integer(format(s$date[e], "%m")) == 12L else c(rep(TRUE, length(e) - 1L), last_ok)
  ye <- yr[e][ok]; ve <- s$value[e][ok]
  if (!coarse && format(s$date[1], "%m-%d") == "01-01") { ye <- c(yr[1] - 1L, ye); ve <- c(s$value[1], ve) }   # erstes volles Jahr
  ny <- if (length(ye)) max(ye) - min(ye) else 0L
  if (ny < 1L) stop(chk_msg("b2b.m_result_heatmap"))
  yrs <- min(ye) + 0:ny; base <- rep(NA_real_, ny + 1L); base[match(ye, yrs)] <- ve
  years <- yrs
  H <- min(max_years, ny)
  M <- matrix(NA_real_, ny, H, dimnames = list(years[-1], seq_len(H)))
  for (i in seq_len(ny)) for (h in seq_len(min(H, ny - i + 1L)))
    if (!is.na(base[i]) && !is.na(base[i + h])) M[i, h] <- .cagr_q(base[i + h] / base[i], h)
  summ <- data.frame(years = seq_len(H), min = apply(M, 2, min, na.rm = TRUE), median = apply(M, 2, stats::median, na.rm = TRUE),
                     max = apply(M, 2, max, na.rm = TRUE), share_negative = apply(M, 2, function(v) mean(v < 0, na.rm = TRUE)),
                     n = colSums(!is.na(M)))
  structure(list(matrix = M, summary = summ, real = !is.null(inflation)), class = "SimLevHeatmap")
}

#' @rdname result_heatmap
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

#' @rdname result_heatmap
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
