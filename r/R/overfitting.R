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
  if (!is.null(dates) && frequency != "day") {
    dates <- as.Date(dates)
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

#' Kennzahl aus Summen-Statistiken (spaltenweise, auch Matrizen)
#' @keywords internal
.of_metric <- function(n, s1, s2, sdn, sl, metric) {
  m <- s1 / n
  switch(metric,
    sharpe = m / sqrt(pmax((s2 - s1^2 / n) / (n - 1), 1e-300)),
    sortino = m / sqrt(pmax(sdn / n, 1e-300)),
    geometric = exp(sl / n) - 1,
    mean = m,
    stop("metric: 'sharpe', 'sortino', 'geometric' oder 'mean'."))
}

#' Kennzahl je Spalte einer Renditematrix
#' @keywords internal
.of_col_metric <- function(R, metric) {
  .of_metric(nrow(R), colSums(R), colSums(R^2), colSums(pmin(R, 0)^2), colSums(log1p(R)), metric)
}

#' Probability of Backtest Overfitting (CSCV)
#'
#' Teilt die Renditehistorie aller Punkte einer Parametersuche in \code{S}
#' gleich lange Bloecke und bildet alle \eqn{\binom{S}{S/2}} Aufteilungen in
#' In-Sample- und Out-of-Sample-Haelften. Je Aufteilung wird der In-Sample-
#' beste Punkt bestimmt und sein Rang Out-of-Sample gemessen
#' (Logit \eqn{\lambda}). Die PBO ist der Anteil der Aufteilungen, in denen der
#' gewaehlte Punkt Out-of-Sample unter dem Median landet
#' (\eqn{\lambda \le 0}). Werte nahe 0 sprechen fuer echte Ueberlegenheit,
#' Werte um 0.5 und darueber fuer eine Auswahl nach Zufall.
#'
#' @param x \code{SimLevParamSearch} oder Renditematrix (Zeilen = Zeit,
#'   Spalten = Punkte).
#' @param S Anzahl Bloecke (gerade; 16 ergibt 12870 Aufteilungen).
#' @param metric \code{"sharpe"}, \code{"sortino"}, \code{"geometric"}
#'   (geometrische Periodenrendite) oder \code{"mean"}.
#' @param frequency Aggregation vor der Auswertung: \code{"week"} (Standard),
#'   \code{"day"} oder \code{"month"}.
#' @param dates Datum zur Matrix (nur fuer Aggregation bei Matrix-Eingabe).
#' @param risk_free Risikoloser Zins in Prozent p. a. (wird abgezogen).
#' @return Objekt der Klasse \code{SimLevPBO}: \code{pbo}, \code{lambda},
#'   \code{is_best}, \code{oos_best}, \code{oos_median}, \code{slope}
#'   (Regression OOS auf IS; negativ = Leistungsabfall), \code{prob_loss}.
#' @references Bailey, D. H., Borwein, J., Lopez de Prado, M. & Zhu, Q. J.
#'   (2017). The probability of backtest overfitting. Journal of Computational
#'   Finance 20(4), 39-69.
#' @examples
#' set.seed(1)
#' R <- matrix(rnorm(2000 * 30, 2e-4, 0.01), 2000)  # 30 Zufallsstrategien
#' pbo(R, S = 10, frequency = "day")$pbo           # ~ 0.5: reine Zufallsauswahl
#' @export
pbo <- function(x, S = 16L, metric = c("sharpe", "sortino", "geometric", "mean"),
                frequency = c("week", "day", "month"), dates = NULL, risk_free = 0) {
  metric <- match.arg(metric); frequency <- match.arg(frequency)
  S <- as.integer(S)
  if (S < 2L || S %% 2L) stop("S muss gerade und >= 2 sein.")
  rr <- .of_returns(x, frequency, dates, risk_free); R <- rr$R
  N <- ncol(R); Tn <- nrow(R)
  if (N < 2L) stop("Mindestens zwei Punkte noetig.")
  bl <- Tn %/% S
  if (bl < 4L) stop(sprintf("Zu wenige Beobachtungen (%d) fuer S = %d Bloecke.", Tn, S))
  R <- R[(Tn - bl * S + 1L):Tn, , drop = FALSE]
  blk <- rep(seq_len(S), each = bl)
  B1 <- rowsum(R, blk); B2 <- rowsum(R^2, blk); Bd <- rowsum(pmin(R, 0)^2, blk); Bl <- rowsum(log1p(R), blk)
  T1 <- colSums(B1); T2 <- colSums(B2); Td <- colSums(Bd); Tl <- colSums(Bl)
  combos <- utils::combn(S, S / 2L)
  C <- ncol(combos); half <- bl * S / 2
  lam <- isb <- oosb <- oosm <- numeric(C)
  for (st in seq(1L, C, by = 2000L)) {
    idx <- st:min(C, st + 1999L); k <- length(idx)
    Ind <- matrix(0, k, S); Ind[cbind(rep(seq_len(k), each = S / 2L), as.vector(combos[, idx]))] <- 1
    I1 <- Ind %*% B1; I2 <- Ind %*% B2; Id <- Ind %*% Bd; Il <- Ind %*% Bl
    rep_t <- function(v) matrix(v, k, N, byrow = TRUE)
    IS <- .of_metric(half, I1, I2, Id, Il, metric)
    OOS <- .of_metric(half, rep_t(T1) - I1, rep_t(T2) - I2, rep_t(Td) - Id, rep_t(Tl) - Il, metric)
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

#' @export
print.SimLevPBO <- function(x, ...) {
  cat("Probability of Backtest Overfitting (CSCV)\n")
  cat(sprintf("  %d Punkte, %d Beobachtungen (%s), S = %d Bloecke, %d Aufteilungen, Kennzahl %s\n",
              x$n_points, x$n_obs, x$frequency, x$S, x$n_combos, x$metric))
  cat(sprintf("  PBO:                              %.1f %%\n", 100 * x$pbo))
  cat(sprintf("  Median-Logit lambda:              %.2f\n", stats::median(x$lambda)))
  cat(sprintf("  Leistungsabfall (Steigung OOS~IS): %.2f\n", x$slope))
  cat(sprintf("  OOS-Verlustwahrscheinlichkeit:    %.1f %%\n", 100 * x$prob_loss))
  cat(sprintf("  Gewaehlter Punkt OOS vor Median:  %.1f %%\n", 100 * mean(x$oos_best > x$oos_median)))
  cat("  Lesart: PBO nahe 0 = Auswahl traegt, um 50 % = Zufall, darueber = Auswahl schadet.\n")
  invisible(x)
}

#' @export
plot.SimLevPBO <- function(x, ...) {
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  graphics::par(mfrow = c(1, 2), mar = c(4.2, 4.2, 2.6, 1), mgp = c(2.5, 0.6, 0), las = 1, cex.axis = 0.85)
  graphics::hist(x$lambda, breaks = 40, col = "#2C6E9B", border = "white", main = sprintf("Logits (PBO %.0f %%)", 100 * x$pbo),
                 xlab = expression(lambda), ylab = "Haeufigkeit")
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
#'
#' @param r Periodenrenditen.
#' @param benchmark Vergleichs-Sharpe-Ratio, annualisiert.
#' @param ppy Perioden je Jahr (fuer die Umrechnung von \code{benchmark}).
#' @return Wahrscheinlichkeit.
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
#' Korrelation verwendet.
#'
#' @param x \code{SimLevParamSearch} oder Renditematrix.
#' @param id Zu pruefender Punkt (Standard: hoechste Sharpe Ratio).
#' @param n_trials Versuchsanzahl (ueberschreibt die Schaetzung), z. B. wenn
#'   vorher schon andere Suchen gelaufen sind.
#' @param effective Effektive statt nominaler Versuchsanzahl.
#' @inheritParams pbo
#' @return Objekt der Klasse \code{SimLevDSR} mit \code{sharpe} (annualisiert),
#'   \code{sr0} (annualisiert), \code{psr} (gegen 0), \code{dsr},
#'   \code{n_trials}, \code{n_eff}, \code{rho}.
#' @references Bailey, D. H. & Lopez de Prado, M. (2014). The deflated Sharpe
#'   ratio. Journal of Portfolio Management 40(5), 94-107.
#' @export
deflated_sharpe <- function(x, id = NULL, n_trials = NULL, effective = TRUE,
                            frequency = c("week", "day", "month"), dates = NULL, risk_free = 0) {
  frequency <- match.arg(frequency)
  rr <- .of_returns(x, frequency, dates, risk_free); R <- rr$R
  N <- ncol(R)
  sr <- .of_col_metric(R, "sharpe")
  j <- if (is.null(id)) which.max(sr) else {
    jj <- match(id, rr$cols); if (is.na(jj)) stop("id nicht unter den gueltigen Punkten.") ; jj }
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

#' @export
print.SimLevDSR <- function(x, ...) {
  cat("Deflated Sharpe Ratio\n")
  cat(sprintf("  Punkt #%d, %d Beobachtungen (%s)\n", x$id, x$n_obs, x$frequency))
  cat(sprintf("  Sharpe Ratio (p. a.):                 %.3f\n", x$sharpe))
  cat(sprintf("  Versuche: %d nominal, %.1f effektiv (mittlere Korrelation %.2f), verwendet %.1f\n",
              x$n_points, x$n_eff, x$rho, x$n_trials))
  cat(sprintf("  Erwartetes Maximum ohne Koennen (p. a.): %.3f\n", x$sr0))
  cat(sprintf("  PSR (SR > 0):                         %.1f %%\n", 100 * x$psr))
  cat(sprintf("  DSR (SR > erwartetes Maximum):        %.1f %%\n", 100 * x$dsr))
  cat("  Lesart: DSR ueber 95 % = Ergebnis haelt der Mehrfachtest-Korrektur stand.\n")
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
#' @param x \code{SimLevParamSearch} (mit gespeicherten Renditen).
#' @param train,test,step Fensterlaengen in Jahren.
#' @param anchored Trainingsfenster am Anfang verankern (expandierend).
#' @param metric Auswahlkennzahl (siehe [pbo()]).
#' @param select \code{"best"} oder \code{"plateau"} (Nachbarschaftsmittel,
#'   siehe [plateau()]).
#' @param risk_free Prozent p. a.
#' @return Objekt der Klasse \code{SimLevWalkForward}: \code{windows}
#'   (Fenster, gewaehlter Punkt, IS/OOS-Kennzahl, OOS-Rang), \code{series}
#'   (Datum, Walk-Forward-, Rueckschau- und Durchschnittsindex) und
#'   \code{summary}.
#' @export
walk_forward <- function(x, train = 5, test = 1, step = test, anchored = FALSE,
                         metric = c("sharpe", "sortino", "geometric", "mean"),
                         select = c("best", "plateau"), risk_free = 0) {
  metric <- match.arg(metric); select <- match.arg(select)
  if (!inherits(x, "SimLevParamSearch") || is.null(x$returns)) stop("x muss ein SimLevParamSearch mit Renditen sein.")
  rr <- .of_returns(x, "day", risk_free = risk_free); R <- rr$R; d <- rr$dates
  if (select == "plateau") nb <- .ps_neighbours(x)
  add_m <- function(date, months) seq.Date(date, by = sprintf("%d months", as.integer(round(months))), length.out = 2)[2]
  t0 <- d[1]; last <- d[length(d)]
  win <- list(); k <- 0L
  repeat {
    ts <- add_m(t0, 12 * (train + k * step))
    if (ts >= last) break
    tr <- if (anchored) t0 else add_m(t0, 12 * k * step)
    te <- add_m(ts, 12 * test)
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
  if (!length(win)) stop("Historie zu kurz fuer ein Trainings- und Testfenster.")
  W <- do.call(rbind, win)
  W <- cbind(W[, 1:4], x$results[W$id, x$params, drop = FALSE], W[, -(1:4)])
  rows <- unlist(lapply(seq_len(nrow(W)), function(i) which(d >= W$test_start[i] & d <= W$test_end[i])))
  chosen <- unlist(lapply(seq_len(nrow(W)), function(i) rep(match(W$id[i], rr$cols), sum(d >= W$test_start[i] & d <= W$test_end[i]))))
  wf <- R[cbind(rows, chosen)]
  span <- R[rows, , drop = FALSE]
  hind <- which.max(apply(1 + span, 2, prod))
  yrs <- as.numeric(d[rows[length(rows)]] - d[rows[1]]) / 365.25
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
  cat(sprintf("\nCAGR Walk-Forward %.2f %%, Rueckschau-Bester (#%d) %.2f %%, Durchschnitt aller Punkte %.2f %%\n",
              100 * s["cagr_walk_forward"], x$hindsight_id, 100 * s["cagr_hindsight"], 100 * s["cagr_average"]))
  cat(sprintf("Mittlerer OOS-Rang %.0f %% (50 %% = Zufall), Effizienz OOS/IS %.2f, %d Wechsel\n",
              100 * s["mean_oos_rank"], s["efficiency"], s["switches"]))
  invisible(x)
}

#' @export
plot.SimLevWalkForward <- function(x, ...) {
  s <- x$series
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  graphics::par(mar = c(3.6, 4.4, 2.6, 1), mgp = c(2.5, 0.6, 0), las = 1, cex.axis = 0.85)
  graphics::matplot(s$date, cbind(s$walk_forward, s$hindsight, s$average), type = "l", lty = 1, lwd = c(2, 1.3, 1.3),
                    col = c("#2C6E9B", "#B5562B", "grey45"), log = "y", xaxt = "n", xlab = "", ylab = "Wachstum (log)",
                    main = "Walk-Forward Out-of-Sample")
  graphics::axis.Date(1, s$date)
  graphics::legend("topleft", c("Walk-Forward", "Rueckschau-Bester", "Durchschnitt"), col = c("#2C6E9B", "#B5562B", "grey45"),
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
#' @param x \code{SimLevParamSearch}.
#' @param data,config Historie und Konfiguration fuer [bootstrap_study()].
#' @param ids Punkte (ueberschreibt \code{top}).
#' @param top Anzahl bester Punkte.
#' @param by \code{"objective"} oder \code{"plateau"}.
#' @param map Spalten-Aliase, die jeder Spezifikation hinzugefuegt werden,
#'   z. B. \code{c(letf = "eu_l2")}, wenn die Strategie in der Suche auf die
#'   Spalte \code{letf} zugreift und im Pfad das Hebelprodukt \code{eu_l2}
#'   heisst.
#' @param include Weitere Strategien (benannte Liste), z. B. ein Buy-and-Hold.
#' @param ... Weitere Argumente fuer [bootstrap_study()] (\code{method},
#'   \code{n}, \code{params}, \code{seed}, \code{cores}, ...).
#' @return \code{SimLevBootstrapStudy}; Strategienamen \code{p<id>}.
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
