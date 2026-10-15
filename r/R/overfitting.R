# =============================================================================
#  overfitting.R  —  Schutz vor Ueberanpassung bei Parametersuchen
# -----------------------------------------------------------------------------
#  pbo()                    Probability of Backtest Overfitting mit
#                           Combinatorially Symmetric Cross-Validation
#                           (Bailey, Borwein, Lopez de Prado & Zhu 2017)
#  deflated_sharpe()        Deflated Sharpe Ratio (Bailey & Lopez de Prado
#                           2014) inkl. effektiver Versuchsanzahl
#  probabilistic_sharpe()   Probabilistic Sharpe Ratio (Bailey & Lopez de
#                           Prado 2012)
#  walk_forward()           rollierende Auswahl In-Sample, Bewertung
#                           Out-of-Sample
#  param_bootstrap()        beste Punkte einer Suche auf Bootstrap-Pfaden
#
#  Alle Verfahren arbeiten auf den taeglichen TWR-Renditen, die
#  param_search() je Punkt speichert. Pfadabhaengige Effekte (Steuern,
#  Signalzustand) stammen damit aus dem Lauf ueber die volle Historie; geprueft
#  wird der Auswahlprozess.
# =============================================================================

#' Renditematrix und Datum aus Suche oder Matrix holen, ggf. aggregieren
#' @keywords internal
#' @noRd
.of_returns <- function(x, frequency, dates = NULL, risk_free = 0) {
  if (inherits(x, "SimLevParamSearch")) {
    if (is.null(x$returns)) stop("Suche ohne gespeicherte Renditen (keep_returns = FALSE).")
    R <- x$returns; dates <- x$dates
  } else {
    R <- as.matrix(x)
    if (!is.numeric(R)) stop("x muss ein SimLevParamSearch oder eine numerische Renditematrix sein.")
    if (is.null(colnames(R))) colnames(R) <- paste0("p", seq_len(ncol(R)))
  }
  keep <- colSums(is.finite(R)) > 0
  R <- R[, keep, drop = FALSE]
  if (!is.null(dates)) dates <- .to_date(dates, "dates")
  if (!is.null(dates) && frequency != "day") {
    key <- if (frequency == "week") format(dates, "%G-%V") else format(dates, "%Y-%m")
    grp <- factor(key, levels = unique(key))
    R <- exp(rowsum(log1p(R), grp, reorder = FALSE)) - 1
    dates <- dates[c(key[-1] != key[-length(key)], TRUE)]
  }
  ok <- stats::complete.cases(R)
  R <- R[ok, , drop = FALSE]; if (!is.null(dates)) dates <- dates[ok]
  ppy <- if (!is.null(dates) && length(dates) > 1) (length(dates) - 1) / (as.numeric(dates[length(dates)] - dates[1]) / 365.25)
         else switch(frequency, day = 252, week = 52, month = 12)
  R <- R - risk_free / 100 / ppy
  list(R = R, dates = dates, ppy = ppy, cols = which(keep))
}

#' Kennzahl aus Summen-Statistiken (spaltenweise, auch Matrizen). s2 und c1
#' sind Quadratsumme und Summe der um einen festen Wert je Spalte verschobenen
#' Renditen (Varianz ist verschiebungsinvariant); mit dem Spaltenmittel als
#' Verschiebung entfaellt die Ausloeschung in s2 - c1^2 / n.
#' @keywords internal
#' @noRd
.of_metric <- function(n, s1, s2, sdn, sl, metric, c1 = s1) {
  m <- s1 / n
  switch(metric,
    sharpe = m / sqrt(pmax((s2 - c1^2 / n) / (n - 1), 1e-300)),
    sortino = m / sqrt(pmax(sdn / n, 1e-300)),
    geometric = expm1(sl / n),
    mean = m,
    stop("metric: 'sharpe', 'sortino', 'geometric' oder 'mean'."))
}

#' Kennzahl je Spalte einer Renditematrix
#' @keywords internal
#' @noRd
.of_col_metric <- function(R, metric) {
  Rc <- sweep(R, 2, colMeans(R))                                  # zentriert: keine Ausloeschung
  .of_metric(nrow(R), colSums(R), colSums(Rc^2), colSums(pmin(R, 0)^2), colSums(log1p(R)), metric, c1 = colSums(Rc))
}

#' Spalten ohne Schwankung (Sharpe Ratio nicht definiert) ausschliessen
#' @keywords internal
#' @noRd
.of_drop_flat <- function(rr, what) {
  sdv <- apply(rr$R, 2, stats::sd)
  flat <- which(!(sdv > 1e-10))
  if (!length(flat)) return(rr)
  if (length(flat) == ncol(rr$R)) stop(sprintf("%s: alle Spalten ohne Schwankung (Standardabweichung <= 1e-10); Sharpe Ratio nicht definiert.", what))
  warning(sprintf("%s: %d Spalte(n) ohne Schwankung (Standardabweichung <= 1e-10 je Periode, z. B. Geldmarkt mit festem Zins; Punkt(e) %s) ausgeschlossen - Sharpe Ratio dort nicht definiert.",
                  what, length(flat), paste(rr$cols[flat], collapse = ", ")))
  rr$R <- rr$R[, -flat, drop = FALSE]; rr$cols <- rr$cols[-flat]
  rr
}

#' Probability of Backtest Overfitting (CSCV)
#'
#' Teilt die Renditehistorie aller Punkte einer Parametersuche in \code{S}
#' gleich lange Bloecke und bildet alle \eqn{\binom{S}{S/2}} Aufteilungen in
#' In-Sample- und Out-of-Sample-Haelften. Je Aufteilung wird der In-Sample-
#' beste Punkt bestimmt und sein Rang Out-of-Sample gemessen
#' (Logit \eqn{\lambda}). Die PBO ist der Anteil der Aufteilungen, in denen der
#' gewaehlte Punkt Out-of-Sample nicht ueber dem Median landet
#' (\eqn{\lambda \le 0}, Schaetzer \eqn{\int_{-\infty}^0 f(\lambda)d\lambda}
#' nach Bailey et al.; \eqn{\lambda = 0}, also genau der Median-Rang, zaehlt
#' mit). Werte nahe 0 sprechen fuer echte Ueberlegenheit, Werte um 0.5 und
#' darueber fuer eine Auswahl nach Zufall. Bei reinem Zufall und ungerader
#' Punktezahl N landet der gewaehlte Punkt mit Wahrscheinlichkeit 1/N genau
#' auf dem Median; der Erwartungswert der PBO ist dann (N + 1) / (2N) statt
#' 0.5 (z. B. 0.67 bei N = 3, 0.6 bei N = 5). Gleichstaende (z. B. identische
#' Spalten) erhalten mittlere Raenge und koennen ebenfalls \eqn{\lambda = 0}
#' ergeben.
#'
#' Verwendet werden die letzten \eqn{S \lfloor T/S \rfloor} Perioden; jeder
#' Block braucht mindestens 4 Perioden. Eingabe ist eine Parametersuche oder
#' eine Renditematrix (eine Spalte je Variante). Mehrere fertige
#' Simulationen (Liste von \code{SimLevResult}) werden vorher zu einer
#' Matrix zusammengefasst, siehe Beispiel bei [reality_check()].
#'
#' @param x Renditequelle:
#'   \itemize{
#'     \item \code{SimLevParamSearch} aus [param_search()] mit gespeicherten
#'       Renditen (\code{keep_returns = TRUE}); verwendet werden
#'       \code{x$returns} (taegliche Renditen je Punkt) und \code{x$dates};
#'     \item numerische Matrix oder data.frame nur aus numerischen Spalten
#'       (ohne Datumsspalte): Zeilen = Perioden, Spalten = Punkte bzw.
#'       Strategien, einfache Renditen als Anteil (0.01 = 1 %); ohne
#'       Spaltennamen heissen die Spalten \code{p1}, \code{p2}, ...
#'   }
#'   Spalten ohne endlichen Wert werden verworfen, danach alle Zeilen mit
#'   einem fehlenden Wert; bei \code{metric = "sharpe"} ausserdem Spalten ohne
#'   Schwankung (Standardabweichung <= 1e-10 je Periode, mit Warnung), deren
#'   Sharpe Ratio nicht definiert ist. Mindestens zwei Spalten noetig. Bei
#'   \code{print()}/\code{plot()}: Objekt der Klasse \code{SimLevPBO}.
#' @param S Anzahl Bloecke (gerade ganze Zahl >= 2, Standard 16 ergibt
#'   \eqn{\binom{16}{8}} = 12870 Aufteilungen).
#' @param metric Kennzahl je Periode (nach Abzug von \code{risk_free}, nicht
#'   annualisiert): \code{"sharpe"} (Standard; Mittelwert /
#'   Standardabweichung), \code{"sortino"} (Mittelwert / Wurzel des mittleren
#'   quadrierten negativen Teils), \code{"geometric"} (geometrische
#'   Periodenrendite \eqn{\exp(\overline{\log(1 + r)}) - 1}, Anteil) oder
#'   \code{"mean"} (arithmetisches Mittel, Anteil). Hoeher = besser.
#' @param frequency Periodenlaenge der Auswertung: \code{"week"} (Standard),
#'   \code{"day"} oder \code{"month"}. Mit Datum (bei \code{SimLevParamSearch}
#'   immer, bei Matrizen ueber \code{dates}) werden die Tagesrenditen
#'   geometrisch zu ISO-Wochen bzw. Kalendermonaten verkettet. Ohne Datum
#'   wird nicht aggregiert; die Zeilen gelten dann als Perioden dieser
#'   Frequenz (wichtig fuer \code{ppy}). Achtung: Eine Matrix von
#'   Tagesrenditen ohne \code{dates} braucht \code{frequency = "day"}; mit
#'   dem Standard \code{"week"} wird mit 52 statt 252 Perioden je Jahr
#'   annualisiert (betrifft annualisierte Sharpe Ratios und
#'   \code{risk_free}).
#' @param dates Datum je Zeile von \code{x} (Date oder umwandelbar), nur bei
#'   Matrix-Eingabe; \code{NULL} (Standard) = keine Aggregation. Bei
#'   \code{SimLevParamSearch} wird \code{x$dates} verwendet.
#' @param risk_free Risikoloser Zins in Prozent p. a. (2 = 2 %, Standard 0);
#'   wird als \code{risk_free / 100 / ppy} von jeder Periodenrendite
#'   abgezogen. \code{ppy} (Perioden je Jahr) wird aus dem Datum geschaetzt:
#'   (Anzahl Perioden - 1) / (Zeitspanne in Tagen / 365.25); ohne Datum 252
#'   (\code{"day"}), 52 (\code{"week"}) bzw. 12 (\code{"month"}).
#' @return Objekt der Klasse \code{SimLevPBO}, eine Liste mit
#'   \code{pbo} (Anteil der Aufteilungen mit \eqn{\lambda \le 0}),
#'   \code{lambda} (Logit je Aufteilung), \code{is_best} (In-Sample-Kennzahl
#'   des gewaehlten Punkts je Aufteilung), \code{oos_best} (seine
#'   Out-of-Sample-Kennzahl), \code{oos_median} (Median der
#'   Out-of-Sample-Kennzahl aller Punkte), \code{slope}, \code{intercept}
#'   (Regression \code{oos_best ~ is_best}; negative Steigung =
#'   Leistungsabfall), \code{prob_loss} (Anteil der Aufteilungen mit
#'   \code{oos_best < 0}), \code{S}, \code{n_combos} (Anzahl Aufteilungen),
#'   \code{n_points} (Anzahl Spalten), \code{n_obs} (verwendete Perioden),
#'   \code{metric}, \code{frequency} und \code{ppy}. Die Kennzahlen sind je
#'   Periode angegeben, nicht annualisiert.
#' @seealso [param_search()], [deflated_sharpe()], [walk_forward()],
#'   [plateau()]
#' @references Bailey, D. H., Borwein, J., Lopez de Prado, M. & Zhu, Q. J.
#'   (2017). The probability of backtest overfitting. Journal of Computational
#'   Finance 20(4), 39-69.
#' @examples
#' set.seed(1)
#' R <- matrix(rnorm(2000 * 30, 2e-4, 0.01), 2000)  # 30 Zufallsstrategien
#' pbo(R, S = 10, frequency = "day")$pbo           # ~ 0.5: reine Zufallsauswahl
#' pb <- pbo(R, S = 10, frequency = "day", metric = "geometric")
#' pb
#' plot(pb)
#' @export
pbo <- function(x, S = 16L, metric = c("sharpe", "sortino", "geometric", "mean"),
                frequency = c("week", "day", "month"), dates = NULL, risk_free = 0) {
  metric <- match.arg(metric); frequency <- match.arg(frequency)
  S <- as.integer(S)
  if (S < 2L || S %% 2L) stop("S muss gerade und >= 2 sein.")
  rr <- .of_returns(x, frequency, dates, risk_free)
  if (metric == "sharpe") rr <- .of_drop_flat(rr, "pbo")
  R <- rr$R; N <- ncol(R); Tn <- nrow(R)
  if (N < 2L) stop("Mindestens zwei Punkte n\u00f6tig.")
  bl <- Tn %/% S
  if (bl < 4L) stop(sprintf("Zu wenige Beobachtungen (%d) f\u00fcr S = %d Bl\u00f6cke.", Tn, S))
  R <- R[(Tn - bl * S + 1L):Tn, , drop = FALSE]
  blk <- rep(seq_len(S), each = bl)
  Rc <- sweep(R, 2, colMeans(R))                                 # zentriert fuer die Varianz (keine Ausloeschung)
  B1 <- rowsum(R, blk); B2 <- rowsum(Rc^2, blk); Bd <- rowsum(pmin(R, 0)^2, blk); Bl <- rowsum(log1p(R), blk)
  Bc <- rowsum(Rc, blk)
  T1 <- colSums(B1); T2 <- colSums(B2); Td <- colSums(Bd); Tl <- colSums(Bl); Tc <- colSums(Bc)
  combos <- utils::combn(S, S / 2L)
  C <- ncol(combos); half <- bl * S / 2
  lam <- isb <- oosb <- oosm <- numeric(C)
  for (st in seq(1L, C, by = 2000L)) {
    idx <- st:min(C, st + 1999L); k <- length(idx)
    Ind <- matrix(0, k, S); Ind[cbind(rep(seq_len(k), each = S / 2L), as.vector(combos[, idx]))] <- 1
    I1 <- Ind %*% B1; I2 <- Ind %*% B2; Id <- Ind %*% Bd; Il <- Ind %*% Bl; Ic <- Ind %*% Bc
    rep_t <- function(v) matrix(v, k, N, byrow = TRUE)
    IS <- .of_metric(half, I1, I2, Id, Il, metric, c1 = Ic)
    OOS <- .of_metric(half, rep_t(T1) - I1, rep_t(T2) - I2, rep_t(Td) - Id, rep_t(Tl) - Il, metric, c1 = rep_t(Tc) - Ic)
    best <- max.col(IS, ties.method = "first")
    ob <- OOS[cbind(seq_len(k), best)]
    rk <- rowSums(OOS < ob) + (rowSums(OOS == ob) + 1) / 2
    w <- rk / (N + 1)
    lam[idx] <- log(w / (1 - w)); isb[idx] <- IS[cbind(seq_len(k), best)]; oosb[idx] <- ob
    oosm[idx] <- apply(OOS, 1, stats::median)
  }
  fit <- stats::lm(oosb ~ isb)
  structure(list(pbo = mean(lam <= 0), lambda = lam, is_best = isb, oos_best = oosb, oos_median = oosm,
                 slope = unname(stats::coef(fit)[2]), intercept = unname(stats::coef(fit)[1]),
                 prob_loss = mean(oosb < 0), S = S, n_combos = C, n_points = N, n_obs = bl * S,
                 metric = metric, frequency = frequency, ppy = rr$ppy), class = "SimLevPBO")
}

#' @rdname pbo
#' @param ... ungenutzt.
#' @export
print.SimLevPBO <- function(x, ...) {
  cat("Probability of Backtest Overfitting (PBO, CSCV)\n")
  cat(sprintf("  %d Punkte, %d Beobachtungen (%s), S = %d Bl\u00f6cke, %d Aufteilungen, Kennzahl %s\n",
              x$n_points, x$n_obs, x$frequency, x$S, x$n_combos, x$metric))
  cat(sprintf("  PBO:                              %.1f %%\n", 100 * x$pbo))
  cat(sprintf("  Median-Logit lambda:              %.2f\n", stats::median(x$lambda)))
  cat(sprintf("  Leistungsabfall (Steigung OOS~IS): %.2f\n", x$slope))
  cat(sprintf("  OOS-Verlustwahrscheinlichkeit:    %.1f %%\n", 100 * x$prob_loss))
  cat(sprintf("  Gew\u00e4hlter Punkt OOS vor Median:   %.1f %%\n", 100 * mean(x$oos_best > x$oos_median)))
  cat(sprintf("  Lesart: PBO nahe 0 = Auswahl tr\u00e4gt, um %.0f %% = Zufall%s, dar\u00fcber = Auswahl schadet.\n",
              100 * (x$n_points + x$n_points %% 2) / (2 * x$n_points), if (x$n_points %% 2) " (ungerade Punktezahl: (N + 1) / (2N))" else ""))
  invisible(x)
}

#' @rdname pbo
#' @export
plot.SimLevPBO <- function(x, ...) {
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  graphics::par(mfrow = c(1, 2), mar = c(4.2, 4.2, 2.6, 1), mgp = c(2.5, 0.6, 0), las = 1, cex.axis = 0.85)
  graphics::hist(x$lambda, breaks = 40, col = "#2C6E9B", border = "white", main = sprintf("Logits (PBO %.0f %%)", 100 * x$pbo),
                 xlab = expression(lambda), ylab = "H\u00e4ufigkeit")
  graphics::abline(v = 0, col = "#B5562B", lwd = 2)
  graphics::plot(x$is_best, x$oos_best, pch = 16, cex = 0.4, col = grDevices::adjustcolor("#2C6E9B", 0.4),
                 xlab = sprintf("%s In-Sample (bester Punkt)", x$metric), ylab = "Out-of-Sample", main = "Leistungsabfall")
  graphics::abline(x$intercept, x$slope, col = "#B5562B", lwd = 2)
  graphics::abline(h = 0, col = "grey50", lty = 3)
  invisible(x)
}

#' Probabilistic Sharpe Ratio
#'
#' Wahrscheinlichkeit, dass die wahre Sharpe Ratio ueber \code{benchmark}
#' liegt, unter Beruecksichtigung von Stichprobenlaenge, Schiefe und Woelbung:
#' \deqn{PSR = \Phi\left(\frac{(\widehat{SR} - SR^*)\sqrt{T-1}}
#'       {\sqrt{1 - \gamma_3 \widehat{SR} + \frac{\gamma_4 - 1}{4}\widehat{SR}^2}}\right)}
#' Dabei sind \eqn{\widehat{SR}} (Mittelwert / Standardabweichung) und
#' \eqn{SR^*} Sharpe Ratios je Periode, \eqn{T} die Anzahl Renditen,
#' \eqn{\gamma_3} die Schiefe und \eqn{\gamma_4} die Woelbung (nicht
#' Exzess). Eingabe ist ein Renditevektor; fuer ein Ergebnis von
#' [simulation()] z. B. \code{v <- result_index(res)$value; r <- v[-1] / v[-length(v)] - 1}.
#'
#' @param r Numerischer Vektor einfacher Periodenrenditen als Anteil
#'   (0.01 = 1 %); nicht endliche Werte werden entfernt. Ein risikoloser
#'   Zins wird nicht abgezogen.
#' @param benchmark Vergleichs-Sharpe-Ratio \eqn{SR^*} p. a. (Standard 0);
#'   intern durch \eqn{\sqrt{ppy}} geteilt.
#' @param ppy Perioden je Jahr der Renditen in \code{r} (Standard 52 =
#'   Wochenrenditen; z. B. 252 fuer Handelstage, 12 fuer Monate). Wird nicht
#'   geschaetzt und dient nur der Umrechnung von \code{benchmark}.
#' @return Eine Zahl: Wahrscheinlichkeit als Anteil (0 bis 1).
#' @seealso [deflated_sharpe()], [min_track_record()], [sharpe_test()]
#' @examples
#' set.seed(1)
#' r <- rnorm(520, 0.002, 0.02)                    # 10 Jahre Wochenrenditen
#' probabilistic_sharpe(r, benchmark = 0, ppy = 52)  # P(wahre SR > 0)
#' probabilistic_sharpe(r, benchmark = 1, ppy = 52)  # P(wahre SR > 1 p. a.)
#' @references Bailey, D. H. & Lopez de Prado, M. (2012). The Sharpe ratio
#'   efficient frontier. Journal of Risk 15(2), 3-44.
#' @export
probabilistic_sharpe <- function(r, benchmark = 0, ppy = 52) {
  r <- r[is.finite(r)]; n <- length(r)
  sr <- mean(r) / stats::sd(r); sr0 <- benchmark / sqrt(ppy)
  z <- (r - mean(r)) / stats::sd(r)
  g3 <- mean(z^3); g4 <- mean(z^4)
  stats::pnorm((sr - sr0) * sqrt(n - 1) / sqrt(max(1 - g3 * sr + (g4 - 1) / 4 * sr^2, 1e-12)))
}

#' Deflated Sharpe Ratio
#'
#' Korrigiert die Sharpe Ratio des besten Punkts einer Suche um die Zahl der
#' Versuche: Die Nullhypothese ist nicht SR = 0, sondern die Sharpe Ratio, die
#' man als Maximum aus \eqn{N} wertlosen Versuchen erwarten wuerde,
#' \deqn{SR_0 = \sqrt{V[\widehat{SR}_n]}\left((1-\gamma)\Phi^{-1}(1 - 1/N) +
#'       \gamma \Phi^{-1}(1 - 1/(N e))\right)}
#' (\eqn{\gamma} Euler-Mascheroni). Weil die Punkte einer Suche stark
#' korreliert sind, wird standardmaessig eine effektive Versuchsanzahl
#' \eqn{N_{eff} = \bar\rho + (1 - \bar\rho) N} aus der mittleren paarweisen
#' Korrelation verwendet (mindestens 1; bei negativer mittlerer Korrelation
#' \eqn{N}). \eqn{V[\widehat{SR}_n]} ist die Varianz der Sharpe Ratios je
#' Periode ueber alle Punkte. PSR und DSR werden mit
#' [probabilistic_sharpe()] berechnet. Spalten ohne Schwankung
#' (Standardabweichung <= 1e-10 je Periode, z. B. ein Punkt, der nur
#' Geldmarkt mit festem Zins haelt) haben keine definierte Sharpe Ratio und
#' werden mit Warnung ausgeschlossen.
#'
#' @param x Renditequelle wie bei [pbo()]: \code{SimLevParamSearch} aus
#'   [param_search()] mit gespeicherten Renditen oder numerische
#'   Renditematrix bzw. data.frame nur aus numerischen Spalten (Zeilen =
#'   Perioden, Spalten = Punkte, einfache Renditen als Anteil). Bei
#'   \code{print()}: Objekt der Klasse \code{SimLevDSR}.
#' @param id Zu pruefender Punkt: bei \code{SimLevParamSearch} die
#'   \code{id} aus \code{x$results}, bei einer Matrix die Spaltennummer der
#'   urspruenglichen Matrix. \code{NULL} (Standard) = Punkt mit der hoechsten
#'   Sharpe Ratio.
#' @param n_trials Versuchsanzahl \eqn{N} (positive Zahl, ueberschreibt die
#'   Schaetzung), z. B. wenn vorher schon andere Suchen gelaufen sind.
#'   \code{NULL} (Standard) = aus \code{x} geschaetzt (siehe
#'   \code{effective}).
#' @param effective Logisch. \code{TRUE} (Standard) = effektive
#'   Versuchsanzahl \eqn{N_{eff}}; \code{FALSE} = Anzahl gueltiger Spalten.
#' @inheritParams pbo
#' @return Objekt der Klasse \code{SimLevDSR}, eine Liste mit \code{id}
#'   (gepruefter Punkt), \code{sharpe} (seine Sharpe Ratio p. a.),
#'   \code{sr0} (erwartetes Maximum ohne Koennen, p. a.), \code{psr}
#'   (Wahrscheinlichkeit SR > 0, Anteil), \code{dsr} (Wahrscheinlichkeit SR >
#'   \code{sr0}, Anteil), \code{n_trials} (verwendete Versuchsanzahl),
#'   \code{n_points} (Anzahl Spalten), \code{n_eff}, \code{rho} (mittlere
#'   paarweise Korrelation), \code{var_sr} (Varianz der Sharpe Ratios,
#'   annualisiert: Varianz je Periode mal \code{ppy}), \code{n_obs} (Anzahl
#'   Perioden) und \code{frequency}. Annualisiert wird mit
#'   \eqn{\sqrt{ppy}}; \code{ppy} wird wie unter \code{risk_free}
#'   beschrieben bestimmt.
#' @seealso [param_search()], [pbo()], [probabilistic_sharpe()],
#'   [sharpe_haircut()]
#' @examples
#' set.seed(1)
#' R <- matrix(rnorm(2000 * 20, 2e-4, 0.01), 2000)   # 20 Zufallsstrategien
#' ds <- deflated_sharpe(R, frequency = "day")       # ohne Datum: ppy = 252
#' ds
#' deflated_sharpe(R, frequency = "day", n_trials = 100)$dsr
#'
#' # Parametersuche
#' set.seed(1)
#' d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = 3000))
#' d$A <- 100 * cumprod(1 + rnorm(3000, 3e-4, 0.011))
#' st <- create_strategy(A = asset_config("etf", "signal", signal_buy = "buy", signal_sell = "sell"))
#' ps <- param_search(d, function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, p$band)),
#'                    param_space(n = c(50, 100, 200), band = c(0, 2)), burn_in = 250)
#' deflated_sharpe(ps)
#' @references Bailey, D. H. & Lopez de Prado, M. (2014). The deflated Sharpe
#'   ratio. Journal of Portfolio Management 40(5), 94-107.
#' @export
deflated_sharpe <- function(x, id = NULL, n_trials = NULL, effective = TRUE,
                            frequency = c("week", "day", "month"), dates = NULL, risk_free = 0) {
  frequency <- match.arg(frequency)
  rr <- .of_drop_flat(.of_returns(x, frequency, dates, risk_free), "deflated_sharpe"); R <- rr$R
  N <- ncol(R)
  sr <- .of_col_metric(R, "sharpe")
  j <- if (is.null(id)) which.max(sr) else {
    jj <- match(id, rr$cols)
    if (is.na(jj)) stop("id nicht unter den g\u00fcltigen Punkten (Spalten ohne endliche Werte oder ohne Schwankung z\u00e4hlen nicht).")
    jj }
  rho <- if (N > 1) { Cm <- stats::cor(R); mean(Cm[upper.tri(Cm)], na.rm = TRUE) } else 1
  n_eff <- max(1, rho + (1 - max(rho, 0)) * N)
  if (rho < 0) n_eff <- N
  Nt <- n_trials %||% (if (effective) n_eff else N)
  v <- if (N > 1) stats::var(sr) else 0
  g <- 0.5772156649
  sr0 <- if (Nt > 1 && v > 0) sqrt(v) * ((1 - g) * stats::qnorm(1 - 1 / Nt) + g * stats::qnorm(1 - 1 / (Nt * exp(1)))) else 0
  r <- R[, j]
  structure(list(id = rr$cols[j], sharpe = sr[j] * sqrt(rr$ppy), sr0 = sr0 * sqrt(rr$ppy),
                 psr = probabilistic_sharpe(r, 0, rr$ppy), dsr = probabilistic_sharpe(r, sr0 * sqrt(rr$ppy), rr$ppy),
                 n_trials = Nt, n_points = N, n_eff = n_eff, rho = rho, var_sr = v * rr$ppy, n_obs = nrow(R),
                 frequency = frequency), class = "SimLevDSR")
}

#' @rdname deflated_sharpe
#' @param ... ungenutzt.
#' @export
print.SimLevDSR <- function(x, ...) {
  cat("Deflated Sharpe Ratio\n")
  cat(sprintf("  Punkt #%d, %d Beobachtungen (%s)\n", x$id, x$n_obs, x$frequency))
  cat(sprintf("  Sharpe Ratio (p. a.):                 %.3f\n", x$sharpe))
  cat(sprintf("  Versuche: %d nominal, %.1f effektiv (mittlere Korrelation %.2f), verwendet %.1f\n",
              x$n_points, x$n_eff, x$rho, x$n_trials))
  cat(sprintf("  Erwartetes Maximum ohne K\u00f6nnen (p. a.):  %.3f\n", x$sr0))
  cat(sprintf("  PSR (SR > 0):                         %.1f %%\n", 100 * x$psr))
  cat(sprintf("  DSR (SR > erwartetes Maximum):        %.1f %%\n", 100 * x$dsr))
  cat("  Lesart: DSR \u00fcber 95 % = Ergebnis h\u00e4lt der Mehrfachtest-Korrektur stand.\n")
  invisible(x)
}

#' Walk-Forward-Auswahl
#'
#' Waehlt in rollierenden Trainingsfenstern den besten Punkt einer
#' Parametersuche (oder das beste Plateau) und verkettet dessen Renditen im
#' jeweils folgenden Testfenster. So entsteht eine Out-of-Sample-Reihe, die
#' nur Informationen nutzt, die zum Entscheidungszeitpunkt vorlagen.
#' Verglichen wird mit dem nachtraeglich besten Punkt (Rueckschau) und mit dem
#' Durchschnitt aller Punkte (zufaellige Wahl).
#'
#' Gerechnet wird auf den taeglichen Renditen der Suche (keine
#' Aggregation). Das erste Trainingsfenster beginnt am ersten Tag der
#' gespeicherten Renditen; die Fenster ruecken um \code{step} vor, bis das
#' Testfenster am oder nach dem letzten Tag beginnen wuerde oder ein Fenster zu
#' kurz ist (weniger als 20 Trainings- oder 5 Testtage). Das letzte
#' Testfenster kann kuerzer als \code{test} sein.
#'
#' @param x \code{SimLevParamSearch} aus [param_search()] mit gespeicherten
#'   Renditen (\code{keep_returns = TRUE}). Renditematrizen oder Listen von
#'   Ergebnissen werden nicht angenommen, weil Parameterwerte (und bei
#'   \code{select = "plateau"} der Suchraum) gebraucht werden. Bei
#'   \code{print()}/\code{plot()}: Objekt der Klasse \code{SimLevWalkForward}.
#' @param train,test,step Laenge des Trainingsfensters, Laenge des
#'   Testfensters und Vorschub der Fenster, jeweils in Jahren (Standard 5, 1
#'   und \code{step = test}); intern in ganze Monate umgerechnet
#'   (\code{round(12 * Jahre)}; Fenstergrenzen = Startdatum plus Monate, auf
#'   das Monatsende begrenzt, z. B. 31.01. + 1 Monat = 29.02.). Mit \code{step < test} ueberlappen die
#'   Testfenster; in \code{series} und \code{summary} zaehlt jeder Tag dann
#'   nur einmal, fuer das juengste Fenster, dessen Test schon begonnen hat
#'   (die Kennzahlen in \code{windows} beziehen sich auf das ganze
#'   Testfenster). Mit \code{step > test} entstehen Luecken zwischen den
#'   Testfenstern; sie fehlen in \code{series} und zaehlen nicht als Zeit.
#' @param anchored Logisch. \code{FALSE} (Standard) = rollierendes
#'   Trainingsfenster der Laenge \code{train}; \code{TRUE} = Training beginnt
#'   immer am ersten Tag (expandierendes Fenster).
#' @param metric Auswahl- und Bewertungskennzahl, je Fenster aus den
#'   Tagesrenditen: \code{"sharpe"} (Standard), \code{"sortino"},
#'   \code{"geometric"} oder \code{"mean"} (Definitionen wie bei [pbo()], je
#'   Tag, nicht annualisiert; hoeher = besser).
#' @param select \code{"best"} (Standard): Punkt mit der hoechsten
#'   Trainings-Kennzahl; \code{"plateau"}: Punkt mit dem hoechsten Mittel der
#'   Trainings-Kennzahl ueber seine Nachbarschaft (Nachbarn wie in
#'   [plateau()] mit \code{radius = 1} bzw. \code{k = 5}).
#' @param risk_free Risikoloser Zins in Prozent p. a. (2 = 2 %, Standard 0);
#'   wird als \code{risk_free / 100 / ppy} von jeder Tagesrendite abgezogen,
#'   \code{ppy} = (Anzahl Tage - 1) / (Zeitspanne in Tagen / 365.25). Wirkt
#'   auch auf \code{series} und die CAGR in \code{summary} (dann
#'   Ueberrenditen).
#' @return Objekt der Klasse \code{SimLevWalkForward}, eine Liste mit
#'   \describe{
#'     \item{\code{windows}}{data.frame je Testfenster: \code{train_start},
#'       \code{test_start}, \code{test_end} (Date), \code{id} (gewaehlter
#'       Punkt), eine Spalte je Parameter, \code{is_metric} und
#'       \code{oos_metric} (Kennzahl im Trainings- bzw. Testfenster),
#'       \code{oos_rank} (Rang des gewaehlten Punkts im Testfenster als
#'       Anteil, (Rang - 0.5) / Anzahl Punkte; nahe 1 = bester, 0.5 =
#'       Zufall), \code{oos_return} (Rendite des gewaehlten Punkts im
#'       Testfenster, Anteil) und \code{oos_average} (mittlere Rendite aller
#'       Punkte im Testfenster, Anteil).}
#'     \item{\code{series}}{data.frame mit \code{date} und den
#'       Wachstumsindizes (Startwert 1 vor dem ersten Testtag)
#'       \code{walk_forward} (verkettete gewaehlte Punkte),
#'       \code{hindsight} (Punkt mit dem hoechsten Endwert ueber alle
#'       Testtage) und \code{average} (taeglich gleichgewichteter Durchschnitt
#'       aller Punkte).}
#'     \item{\code{summary}}{benannter Vektor \code{cagr_walk_forward},
#'       \code{cagr_hindsight}, \code{cagr_average} (CAGR ueber die
#'       Testtage, Anteil p. a.; annualisiert ueber die von den Testtagen
#'       ueberdeckte Zeit, d. h. die Summe der Abstaende jedes Testtags zum
#'       vorherigen Datentag ohne den ersten Testtag - bei luecklosen
#'       Testfenstern die Spanne vom ersten bis zum letzten Testtag), \code{mean_oos_rank}, \code{efficiency}
#'       (mittlere OOS- durch mittlere IS-Kennzahl) und \code{switches}
#'       (Anzahl Wechsel des gewaehlten Punkts).}
#'     \item{\code{hindsight_id}, \code{metric}, \code{select},
#'       \code{train}, \code{test}, \code{anchored}, \code{params}}{Rueckschau-Punkt
#'       und Einstellungen.}
#'   }
#' @seealso [param_search()], [plateau()], [pbo()], [param_bootstrap()]
#' @examples
#' set.seed(1)
#' d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = 3000))
#' d$A <- 100 * cumprod(1 + rnorm(3000, 3e-4, 0.011))
#' st <- create_strategy(A = asset_config("etf", "signal", signal_buy = "buy", signal_sell = "sell"))
#' ps <- param_search(d, function(p) list(strategy = st, signal = function(df) signal_sma(df$A, p$n, p$band)),
#'                    param_space(n = c(50, 100, 200), band = c(0, 2)), burn_in = 250)
#' wf <- walk_forward(ps, train = 3, test = 1)
#' wf
#' wf$summary
#' plot(wf)
#' walk_forward(ps, train = 3, test = 1, anchored = TRUE, select = "plateau")$summary
#' @export
walk_forward <- function(x, train = 5, test = 1, step = test, anchored = FALSE,
                         metric = c("sharpe", "sortino", "geometric", "mean"),
                         select = c("best", "plateau"), risk_free = 0) {
  metric <- match.arg(metric); select <- match.arg(select)
  if (!inherits(x, "SimLevParamSearch") || is.null(x$returns)) stop("x muss ein SimLevParamSearch mit Renditen sein.")
  rr <- .of_returns(x, "day", risk_free = risk_free); R <- rr$R; d <- rr$dates
  if (select == "plateau") nb <- .ps_neighbours(x)
  add_m <- function(date, months) .add_months(date, round(months))      # auf das Monatsende begrenzt
  t0 <- d[1]; last <- d[length(d)]
  win <- list(); k <- 0L
  repeat {
    ts <- add_m(t0, 12 * (train + k * step))
    if (ts >= last) break
    tr <- if (anchored) t0 else add_m(t0, 12 * k * step)
    te <- add_m(t0, 12 * (train + k * step + test))       # alle Grenzen von t0 aus (sonst Luecken nach Monatsende-Kuerzung)
    is_rows <- which(d >= tr & d < ts); oos_rows <- which(d >= ts & d < te)
    if (length(is_rows) < 20 || length(oos_rows) < 5) break
    m_is <- .of_col_metric(R[is_rows, , drop = FALSE], metric)
    score <- m_is
    if (select == "plateau") {
      full <- rep(NA_real_, nrow(x$results)); full[rr$cols] <- m_is
      score <- vapply(rr$cols, function(cid) mean(full[nb[[cid]]], na.rm = TRUE), 0)
    }
    j <- which.max(score)
    m_oos <- .of_col_metric(R[oos_rows, , drop = FALSE], metric)
    win[[length(win) + 1L]] <- data.frame(train_start = d[is_rows[1]], test_start = d[oos_rows[1]], test_end = d[oos_rows[length(oos_rows)]],
                                          id = rr$cols[j], is_metric = m_is[j], oos_metric = m_oos[j],
                                          oos_rank = (rank(m_oos)[j] - 0.5) / length(m_oos),
                                          oos_return = prod(1 + R[oos_rows, j]) - 1,
                                          oos_average = mean(apply(1 + R[oos_rows, , drop = FALSE], 2, prod) - 1))
    k <- k + 1L
  }
  if (!length(win)) stop("Historie zu kurz f\u00fcr ein Trainings- und Testfenster.")
  W <- do.call(rbind, win)
  W <- cbind(W[, 1:4], x$results[W$id, x$params, drop = FALSE], W[, -(1:4)])
  # Testtage ohne Ueberlappung: jeder Tag gehoert zum juengsten Fenster, dessen Test begonnen hat
  nW <- nrow(W)
  seg <- lapply(seq_len(nW), function(i) {
    r <- which(d >= W$test_start[i] & d <= W$test_end[i])
    if (i < nW) r[d[r] < W$test_start[i + 1]] else r })
  rows <- unlist(seg)
  chosen <- rep(match(W$id, rr$cols), lengths(seg))
  wf <- R[cbind(rows, chosen)]
  span <- R[rows, , drop = FALSE]
  hind <- which.max(apply(1 + span, 2, prod))
  # Zeit nur ueber die Testtage (Luecken zwischen Fenstern zaehlen nicht): Summe der
  # Abstaende jedes Testtags zum Vortag, ohne den ersten Testtag
  yrs <- sum(as.numeric(d[rows[-1]] - d[rows[-1] - 1L])) / 365.25
  ann <- function(r) prod(1 + r)^(1 / yrs) - 1
  series <- data.frame(date = d[rows], walk_forward = cumprod(1 + wf), hindsight = cumprod(1 + span[, hind]),
                       average = cumprod(1 + rowMeans(span)))
  smry <- c(cagr_walk_forward = ann(wf), cagr_hindsight = ann(span[, hind]), cagr_average = ann(rowMeans(span)),
            mean_oos_rank = mean(W$oos_rank), efficiency = mean(W$oos_metric) / mean(W$is_metric),
            switches = sum(W$id[-1] != W$id[-nrow(W)]))
  structure(list(windows = W, series = series, summary = smry, hindsight_id = rr$cols[hind], metric = metric,
                 select = select, train = train, test = test, anchored = anchored, params = x$params),
            class = "SimLevWalkForward")
}

#' @rdname walk_forward
#' @param ... ungenutzt.
#' @export
print.SimLevWalkForward <- function(x, ...) {
  cat(sprintf("Walk-Forward (%s, Training %g J., Test %g J., Auswahl %s nach %s)\n", if (x$anchored) "verankert" else "rollierend",
              x$train, x$test, x$select, x$metric))
  W <- x$windows
  y <- data.frame(Test = paste(format(W$test_start, "%Y-%m"), format(W$test_end, "%Y-%m"), sep = " bis "),
                  Punkt = W$id, W[, x$params, drop = FALSE],
                  IS = sprintf("%.3f", W$is_metric), OOS = sprintf("%.3f", W$oos_metric),
                  `OOS-Rang` = sprintf("%.0f %%", 100 * W$oos_rank), Rendite = sprintf("%.1f %%", 100 * W$oos_return),
                  Mittel = sprintf("%.1f %%", 100 * W$oos_average), check.names = FALSE)
  print(y, row.names = FALSE)
  s <- x$summary
  cat(sprintf("\nCAGR Walk-Forward %.2f %%, R\u00fcckschau-Bester (#%d) %.2f %%, Durchschnitt aller Punkte %.2f %%\n",
              100 * s["cagr_walk_forward"], x$hindsight_id, 100 * s["cagr_hindsight"], 100 * s["cagr_average"]))
  cat(sprintf("Mittlerer OOS-Rang %.0f %% (50 %% = Zufall), Effizienz OOS/IS %.2f, %d Wechsel\n",
              100 * s["mean_oos_rank"], s["efficiency"], s["switches"]))
  invisible(x)
}

#' @rdname walk_forward
#' @export
plot.SimLevWalkForward <- function(x, ...) {
  s <- x$series
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  graphics::par(mar = c(3.6, 4.4, 2.6, 1), mgp = c(2.5, 0.6, 0), las = 1, cex.axis = 0.85)
  graphics::matplot(s$date, cbind(s$walk_forward, s$hindsight, s$average), type = "l", lty = 1, lwd = c(2, 1.3, 1.3),
                    col = c("#2C6E9B", "#B5562B", "grey45"), log = "y", xaxt = "n", xlab = "", ylab = "Wachstum (log)",
                    main = "Walk-Forward Out-of-Sample")
  graphics::axis.Date(1, s$date)
  graphics::legend("topleft", c("Walk-Forward", "R\u00fcckschau-Bester", "Durchschnitt"), col = c("#2C6E9B", "#B5562B", "grey45"),
                   lwd = 2, bty = "n", cex = 0.8)
  invisible(x)
}

#' Beste Punkte einer Parametersuche auf Bootstrap-Pfaden pruefen
#'
#' Baut fuer die \code{top} besten Punkte (nach Zielgroesse oder Plateau) die
#' Strategie-Spezifikationen mit dem \code{builder} der Suche und wertet sie
#' gemeinsam mit [bootstrap_study()] auf denselben Pfaden aus. Der
#' \code{builder} muss mit den Spaltennamen der Pfade arbeiten (Indizes,
#' Hebelprodukte, Zusatzreihen aus \code{config}); abweichende Namen lassen
#' sich ueber \code{map} in der Spezifikation abbilden.
#'
#' Die Signalfunktion der Spezifikation wird je Pfad neu berechnet; ein
#' \code{data}-Element der Spezifikation (Funktion \code{df -> df}, siehe
#' [param_search()]) wertet [bootstrap_study()] nicht aus. \code{sim_args}
#' und \code{burn_in} werden aus der Suche uebernommen, lassen sich aber
#' ueber \code{...} ueberschreiben.
#'
#' @param x \code{SimLevParamSearch} aus [param_search()] (verwendet werden
#'   \code{results}, \code{builder}, \code{sim_args} und \code{burn_in};
#'   gespeicherte Renditen sind nicht noetig).
#' @param data Historie fuer die Pfaderzeugung: data.frame oder Matrix mit
#'   den Spalten aus \code{config}, Format wie bei [bootstrap()].
#' @param config Konfiguration aus [bootstrap_config()].
#' @param ids Ganzzahliger Vektor von \code{id}-Werten aus \code{x$results};
#'   \code{NULL} (Standard) = die \code{top} besten Punkte nach \code{by}.
#' @param top Anzahl bester Punkte (ganze Zahl, Standard 5); nur ohne
#'   \code{ids}.
#' @param by Rangfolge fuer \code{top}: \code{"objective"} (Standard,
#'   Zielgroesse der Suche) oder \code{"plateau"} (\code{plateau_mean} aus
#'   [plateau()]); Richtung nach \code{x$maximize}, Punkte mit \code{NA}
#'   entfallen.
#' @param map Benannter Zeichenvektor von Spalten-Aliasen, die jeder
#'   Spezifikation hinzugefuegt werden, z. B. \code{c(letf = "eu_l2")}, wenn
#'   die Strategie in der Suche auf die Spalte \code{letf} zugreift und im
#'   Pfad das Hebelprodukt \code{eu_l2} heisst. \code{NULL} (Standard) =
#'   keine.
#' @param include Weitere Strategien als benannte Liste im Format von
#'   \code{strategies} in [bootstrap_study()], z. B. ein Buy-and-Hold
#'   (Standard: keine).
#' @param ... Weitere Argumente fuer [bootstrap_study()], z. B.
#'   \code{method}, \code{n} (Anzahl Pfade), \code{params}, \code{seed},
#'   \code{cores}, \code{progress}, \code{sim_args}, \code{burn_in}.
#' @return Objekt der Klasse \code{SimLevBootstrapStudy} (siehe
#'   [bootstrap_study()]); die Strategien heissen \code{p<id>} (plus die
#'   Namen aus \code{include}). Attribut \code{param_ids}: benannter Vektor
#'   Strategiename -> \code{id}.
#' @seealso [param_search()], [bootstrap_study()], [bootstrap_probability()],
#'   [walk_forward()]
#' @examples
#' set.seed(2); n <- 1500
#' h <- data.frame(us = 1 + rnorm(n, 3e-4, 0.01))     # Historie: Brutto-Tagesrenditen
#' cfg <- bootstrap_config(c(us = "us"))
#' d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n + 1),
#'                 us = 100 * cumprod(c(1, h$us)))
#' st <- create_strategy(us = asset_config("etf", "signal", signal_buy = "buy", signal_sell = "sell"))
#' ps <- param_search(d, function(p) list(strategy = st, signal = function(df) signal_sma(df$us, p$n)),
#'                    param_space(n = c(20, 50, 100)), burn_in = 100)
#' bs <- param_bootstrap(ps, h, cfg, top = 2, method = "stationary", n = 3,
#'                       params = list(L = 50), seed = 1, progress = FALSE)
#' attr(bs, "param_ids")
#' bs$results[, c("strategy", "path", "cagr", "max_drawdown")]
#' @export
param_bootstrap <- function(x, data, config, ids = NULL, top = 5L, by = c("objective", "plateau"),
                            map = NULL, include = list(), ...) {
  by <- match.arg(by)
  if (!inherits(x, "SimLevParamSearch")) stop("x muss ein SimLevParamSearch sein.")
  if (is.null(ids)) {
    v <- if (by == "plateau") plateau(x)$plateau_mean else x$results[[x$objective]]
    ids <- x$results$id[utils::head(order(v, decreasing = isTRUE(x$maximize), na.last = NA), top)]
  }
  specs <- lapply(ids, function(i) {
    sp <- .as_spec(x$builder(as.list(x$results[i, x$params, drop = FALSE])))
    if (!is.null(map)) sp$map <- c(sp$map, map)
    sp
  })
  names(specs) <- paste0("p", ids)
  args <- utils::modifyList(list(data = data, config = config, strategies = c(specs, include),
                                 sim_args = x$sim_args, burn_in = x$burn_in), list(...))
  st <- do.call(bootstrap_study, args)
  attr(st, "param_ids") <- stats::setNames(ids, names(specs))
  st
}

#' Sharpe-Ratio-Abschlag fuer Mehrfachtests (Harvey & Liu 2015)
#'
#' Wandelt die Sharpe Ratio jedes Punkts einer Suche (oder gegebene Sharpe
#' Ratios) in einen t-Wert und p-Wert, korrigiert die p-Werte fuer die Zahl
#' der Versuche (Bonferroni, Holm, Benjamini-Hochberg-Yekutieli) und rechnet
#' sie in eine "abgeschlagene" Sharpe Ratio zurueck:
#' \deqn{SR^{adj} = \Phi^{-1}(1 - p^{adj}/2) / \sqrt{T}.}
#' Der Abschlag \eqn{1 - SR^{adj}/SR} zeigt, wie viel der gemessenen
#' Sharpe Ratio die Suche selbst erklaert.
#'
#' Der t-Wert ist \eqn{SR \sqrt{T}} mit der Sharpe Ratio je Periode und
#' \eqn{T} Perioden, der p-Wert zweiseitig (Normalverteilung). Die
#' abgeschlagene Sharpe Ratio je Periode wird mit \eqn{\sqrt{ppy}}
#' annualisiert und erhaelt das Vorzeichen von \eqn{SR}. Bei Renditen werden
#' Spalten ohne Schwankung (Standardabweichung <= 1e-10 je Periode) mit
#' Warnung ausgeschlossen (Sharpe Ratio nicht definiert).
#'
#' @param x Eingabe: \code{SimLevParamSearch} aus [param_search()] mit
#'   gespeicherten Renditen, numerische Renditematrix bzw. data.frame nur aus
#'   numerischen Spalten (Zeilen = Perioden, Spalten = Punkte, einfache
#'   Renditen als Anteil; wie bei [pbo()]) oder numerischer Vektor
#'   annualisierter Sharpe Ratios (dann \code{n_obs} und \code{ppy}
#'   angeben).
#' @param n_obs Anzahl Perioden \eqn{T}, auf denen die Sharpe Ratios
#'   beruhen (Perioden der Laenge, die \code{ppy} beschreibt); nur und
#'   zwingend bei Vektor-Eingabe. Sonst die Zeilenzahl nach Aggregation.
#' @param n_tests Gesamtzahl der Versuche \eqn{M} (ganze Zahl).
#'   \code{NULL} (Standard) = Anzahl Sharpe Ratios bzw. Punkte; bei
#'   frueheren Suchen entsprechend hoeher ansetzen (fehlende Versuche gehen
#'   mit p = 1 in die Korrektur ein).
#' @param frequency,dates,risk_free Aggregation, Datum und risikoloser Zins
#'   (Prozent p. a.) wie bei [pbo()]; nur bei Suche oder Matrix.
#' @param ppy Perioden je Jahr, nur bei Vektor-Eingabe (Standard 52 =
#'   Wochen). Bei Suche oder Matrix wird es wie bei [pbo()] bestimmt (aus
#'   dem Datum geschaetzt, sonst 252/52/12 je \code{frequency}).
#' @return data.frame je Punkt, absteigend nach \code{sharpe} sortiert, mit
#'   \code{id} (Punkt bzw. Spaltennummer; bei Vektoren die Position),
#'   \code{sharpe} (p. a.), \code{t}, \code{p} und fuer jedes Verfahren
#'   \code{bonferroni}, \code{holm} und \code{bhy}
#'   (Benjamini-Hochberg-Yekutieli) die Spalten \code{p_<verfahren>}
#'   (angepasster p-Wert), \code{sharpe_<verfahren>} (abgeschlagene Sharpe
#'   Ratio p. a.) und \code{haircut_<verfahren>} (Abschlag als Anteil;
#'   \code{NA} bei \code{sharpe = 0}). Attribute \code{n_tests} und
#'   \code{n_obs}.
#' @seealso [deflated_sharpe()], [pbo()], [reality_check()],
#'   [param_search()]
#' @examples
#' # Zwei Sharpe Ratios p. a. aus 10 Jahren Wochendaten, 50 Versuche insgesamt
#' sharpe_haircut(c(1, 0.5), n_obs = 520, n_tests = 50, ppy = 52)
#' # Renditematrix: 20 Zufallsstrategien, Tagesrenditen ohne Datum (ppy = 252)
#' set.seed(1)
#' R <- matrix(rnorm(2000 * 20, 2e-4, 0.01), 2000)
#' head(sharpe_haircut(R, frequency = "day"), 3)
#' @references Harvey, C. R. & Liu, Y. (2015), Backtesting, Journal of
#'   Portfolio Management 42(1), 13-28.
#' @export
sharpe_haircut <- function(x, n_obs = NULL, n_tests = NULL, frequency = c("week", "day", "month"), dates = NULL,
                           risk_free = 0, ppy = 52) {
  frequency <- match.arg(frequency)
  if (is.numeric(x) && is.null(dim(x))) {
    if (is.null(n_obs)) stop("n_obs angeben.")
    sr <- x / sqrt(ppy); Tn <- n_obs; ids <- seq_along(x)
  } else {
    rr <- .of_drop_flat(.of_returns(x, frequency, dates, risk_free), "sharpe_haircut")
    sr <- .of_col_metric(rr$R, "sharpe"); Tn <- nrow(rr$R)
    ppy <- rr$ppy; ids <- rr$cols
  }
  M <- n_tests %||% length(sr)
  tstat <- sr * sqrt(Tn); p <- 2 * stats::pnorm(-abs(tstat))
  padj <- function(method) {
    pp <- c(p, rep(1, max(0, M - length(p))))                       # unbekannte weitere Tests: p = 1
    stats::p.adjust(pp, method = method, n = max(M, length(p)))[seq_along(p)]
  }
  back <- function(pa) sign(sr) * stats::qnorm(1 - pmin(pa, 1) / 2) / sqrt(Tn) * sqrt(ppy)
  out <- data.frame(id = ids, sharpe = sr * sqrt(ppy), t = tstat, p = p)
  for (m in c(bonferroni = "bonferroni", holm = "holm", bhy = "BY")) {
    nm <- names(which(c(bonferroni = "bonferroni", holm = "holm", bhy = "BY") == m))
    pa <- padj(m); sa <- back(pa)
    out[[paste0("p_", nm)]] <- pa; out[[paste0("sharpe_", nm)]] <- sa
    out[[paste0("haircut_", nm)]] <- ifelse(out$sharpe != 0, 1 - sa / out$sharpe, NA)
  }
  attr(out, "n_tests") <- M; attr(out, "n_obs") <- Tn
  out[order(-out$sharpe), ]
}
