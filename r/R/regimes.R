# =============================================================================
#  regimes.R  —  Regime-Erkennung mit einem Gauss'schen Hidden-Markov-Modell
# -----------------------------------------------------------------------------
#  regime_hmm()     schaetzt K Marktphasen (z. B. ruhig / turbulent) aus den
#                   Periodenrenditen einer oder mehrerer Reihen (Baum-Welch,
#                   mehrere Startwerte); liefert gefilterte (nur Vergangenheit)
#                   und geglaettete Wahrscheinlichkeiten sowie den Viterbi-Pfad
#  regime_states()  legt die Regime auf einen Tageskalender - standardmaessig
#                   die gefilterten Zustaende mit Verzoegerung, also ohne
#                   Zukunftsinformation (fuer Signale, dependence_analysis(),
#                   regime_subset())
# =============================================================================

#' Viterbi-Pfad aus Log-Emissionen (Perioden x Zustand), Log-Uebergangsmatrix und
#' Log-Startverteilung; je Schritt erstes Maximum je Spalte wie which.max
#' (max.col mit ties.method = "first" vergleicht exakt), bei NA/NaN wie bisher ueber apply
#' @keywords internal
#' @noRd
.hmm_viterbi <- function(lB, lA, lp0) {
  # seit 1.6.5 (CR2-X7-2) ohne NA/NaN ueber den Kern (sl_hmm_viterbi, erstes Maximum wie max.col "first" und
  # which.max; gleicher Pfad), sonst wie bisher (gleiche Meldung)
  if (!anyNA(lB) && !anyNA(lA) && !anyNA(lp0)) return(.sl_hmm_viterbi(lB, lA, lp0))
  Tn <- nrow(lB); k <- ncol(lB); jj <- seq_len(k)
  dl <- lp0 + lB[1, ]; bp <- matrix(0L, Tn, k)
  for (t in seq_len(Tn)[-1]) {
    cand <- dl + lA; im <- max.col(t(cand), ties.method = "first")
    if (anyNA(im)) { im <- apply(cand, 2, which.max); mx <- apply(cand, 2, max) } else mx <- cand[cbind(im, jj)]
    bp[t, ] <- im; dl <- mx + lB[t, ]
  }
  path <- integer(Tn); path[Tn] <- which.max(dl); for (t in rev(seq_len(Tn))[-Tn]) path[t - 1] <- bp[t, path[t]]
  path
}

#' Baum-Welch-EM des Gauss'schen HMM aus einem Startwert
#'
#' @param X Matrix Perioden x Spalten.
#' @param k Anzahl Zustaende.
#' @param init list(mu = Matrix k x Spalten, S = Liste k Kovarianzmatrizen,
#'   A = Uebergangsmatrix k x k); Startverteilung gleichverteilt.
#' @param max_iter,tol Hoechstzahl Iterationen und relative Abbruchschranke
#'   (Abbruch, wenn sich die Log-Likelihood um weniger als tol * (1 + |logL|)
#'   aendert).
#' @param ridge Matrix, die jeder Kovarianzmatrix im M-Schritt zugeschlagen wird.
#' @return list(mu, S, A, p0, ll, filtered, smoothed, lB, iter); ll,
#'   filtered, smoothed und lB zu den gelieferten (zuletzt geschaetzten)
#'   Parametern.
#' @keywords internal
#' @noRd
.hmm_em <- function(X, k, init, max_iter, tol, ridge) {
  # E- und M-Schritte im Kern (core/research_core_impl.h, hmm_em; bis 1.4.3 hier in R); ein Fehler dort (Matrix nicht
  # positiv definit, NA im Abbruchtest) verwirft wie bisher den Startwert (tryCatch in regime_hmm)
  ni <- length(seq_len(max_iter))                                   # max_iter = 0: nur der E-Schritt zum Startwert
  r <- .hmm_em_core(X, k, init$mu, unlist(init$S), init$A, ni, tol, ridge)
  if (is.null(r)) stop("regime_hmm: EM-Schritt fehlgeschlagen")
  d <- ncol(X); dn <- if (!is.null(colnames(X))) list(colnames(X), colnames(X))   # wie .sl_crossprod
  S <- lapply(seq_len(k), function(j) { s <- matrix(r$S[(j - 1L) * d * d + seq_len(d * d)], d, d); dimnames(s) <- dn; s })
  list(mu = r$mu, S = S, A = r$A, p0 = r$p0, ll = r$ll, filtered = r$filtered, smoothed = r$smoothed, lB = r$lB, iter = r$iter)
}

#' HMM-Startwert aus einer Einteilung der Perioden in k Gruppen: Mittelwert
#' und Kovarianz (plus ridge) je Gruppe, Uebergangsmatrix 0.9 auf der
#' Diagonale, Rest gleich verteilt
#' @keywords internal
#' @noRd
.hmm_init_cl <- function(X, cl, k, ridge) {
  d <- ncol(X)
  list(mu = matrix(vapply(seq_len(k), function(j) colMeans(X[cl == j, , drop = FALSE]), numeric(d)), k, d, byrow = TRUE),
       S = lapply(seq_len(k), function(j) .sl_cov(X[cl == j, , drop = FALSE]) + ridge),
       A = matrix(0.1 / max(1, k - 1), k, k) + diag(0.9 - 0.1 / max(1, k - 1), k))
}

#' Deterministischer HMM-Startwert: Rangeinteilung einer rollierenden
#' Volatilitaet sqrt(gleitender Mittelwert von rowSums(X^2) ueber win
#' Perioden; fehlende Anfangswerte = Median) in k gleich grosse Gruppen
#' (cut(rank(vol), k)), daraus .hmm_init_cl
#' @keywords internal
#' @noRd
.hmm_init_rank <- function(X, k, win, ridge) {
  vol <- sqrt(.roll_mean(rowSums(X^2), win))
  vol[is.na(vol)] <- stats::median(vol, na.rm = TRUE)
  .hmm_init_cl(X, cut(rank(vol), k, labels = FALSE), k, ridge)
}

#' Hidden-Markov-Modell fuer Marktregime
#'
#' Gauss'sches HMM mit \code{k} Zustaenden (eigener Mittelwert und eigene
#' Kovarianzmatrix je Zustand) auf den Periodenrenditen der Spalten,
#' geschaetzt mit dem Baum-Welch-Algorithmus aus mehreren Startwerten. Die
#' Zustaende werden nach Volatilitaet sortiert (Zustand 1 = ruhigster).
#' Fuer Handelsregeln und bedingte Analysen sind die \strong{gefilterten}
#' Wahrscheinlichkeiten massgeblich - sie nutzen nur Daten bis zum jeweiligen
#' Zeitpunkt; geglaettete Wahrscheinlichkeiten und der Viterbi-Pfad
#' verwenden die ganze Historie und dienen nur der Beschreibung.
#'
#' Eingabe ist ein data.frame mit Kursniveaus; geschaetzt wird auf den
#' Log-Renditen von Periodenende zu Periodenende. Die Zustaende werden
#' danach mit [regime_states()] auf einen Tageskalender gelegt, z. B. als
#' Signal oder als Bedingung fuer [regime_subset()] und
#' [dependence_analysis()].
#'
#' @param data data.frame mit Spalte \code{date} (Date oder umwandelbar) und
#'   den Kursspalten (Niveaus, keine Renditen); fehlende Kurse werden
#'   fortgeschrieben. Das Argument \code{data} von \code{plot()} wird nicht
#'   verwendet.
#' @param columns Zeichenvektor der Kursspalten (eine oder mehrere; bei
#'   mehreren ein multivariates Modell mit Kovarianzmatrix je Zustand).
#' @param k Anzahl Zustaende (ganze Zahl >= 2, Standard 2); es werden
#'   mindestens \code{50 * k} Perioden benoetigt. Spalten ohne Schwankung
#'   (z. B. konstante Kurse) sind ein Fehler.
#'   Seit 1.6.4 hoechstens 10^8.
#' @param frequency Periodenlaenge der Renditen: \code{"week"} (Standard,
#'   ISO-Wochen), \code{"day"} oder \code{"month"}. Bei \code{"day"} entfallen
#'   Tage, an denen alle Renditen 0 sind (z. B. fortgeschriebene
#'   Wochenenden).
#' @param n_start Anzahl Startwerte (ganze Zahl, Standard 5): der erste aus
#'   Quantilen einer rollierenden Volatilitaet, die uebrigen zufaellig; es
#'   zaehlt das Ergebnis mit der hoechsten Log-Likelihood.
#'   Seit 1.6.4 hoechstens 10^8.
#' @param max_iter,tol Hoechstzahl Baum-Welch-Iterationen je Start (Standard
#'   300) und relative Abbruchschranke: Abbruch, wenn sich die
#'   Log-Likelihood um weniger als \code{tol * (1 + |logL|)} aendert
#'   (Standard 1e-7).
#'   Seit 1.6.4 max_iter eine ganze Zahl von 0 bis 10^8, tol eine Zahl >= 0.
#' @param seed Startwert (Standard 1) fuer die zufaelligen Startzuordnungen (nur bei
#'   \code{n_start > 1}). Mit Startwert (ganze Zahl, \eqn{|seed| < 2^{53}}) ist das Ergebnis reproduzierbar und der
#'   Zufallszustand von SimLev bleibt unveraendert; mit \code{NULL} wird genau einmal ein
#'   Startwert aus dem Zufallszustand von SimLev gezogen (siehe [simlev_seed()]), wiederholte
#'   Aufrufe liefern dann verschiedene Ergebnisse. \code{set.seed()} wirkt nicht.
#' @return Objekt der Klasse \code{SimLevHMM}, eine Liste mit
#'   \describe{
#'     \item{\code{transition}}{Uebergangsmatrix k x k (Zeile = von, Spalte =
#'       nach; Namen \code{Z1}, ..., \code{Zk}).}
#'     \item{\code{means}}{Matrix Zustand x Spalte: mittlere Log-Rendite,
#'       annualisiert (mal \code{ppy}), in Prozent p. a.}
#'     \item{\code{volatility}}{Matrix Zustand x Spalte: Volatilitaet,
#'       annualisiert (mal \eqn{\sqrt{ppy}}), in Prozent p. a.}
#'     \item{\code{correlation}}{Liste der Korrelationsmatrizen je Zustand.}
#'     \item{\code{filtered}, \code{smoothed}}{Matrizen Perioden x Zustand
#'       der gefilterten bzw. geglaetteten Wahrscheinlichkeiten (Anteil).}
#'     \item{\code{viterbi}}{wahrscheinlichster Zustandspfad (ganze Zahlen 1
#'       bis k).}
#'     \item{\code{dates}}{Perioden-Enddaten (eine je Zeile von
#'       \code{filtered}).}
#'     \item{\code{columns}, \code{k}, \code{frequency}}{Einstellungen.}
#'     \item{\code{loglik}, \code{bic}}{Log-Likelihood und BIC zu den
#'       gelieferten Parametern (nach dem letzten M-Schritt neu berechnet,
#'       ebenso \code{filtered} und \code{smoothed}).}
#'     \item{\code{initial}}{Startverteilung der Zustaende (Anteile).}
#'     \item{\code{duration}}{erwartete Dauer je Zustand in Perioden,
#'       \eqn{1 / (1 - p_{jj})}.}
#'     \item{\code{ppy}}{Perioden je Jahr, geschaetzt als (Anzahl Perioden -
#'       1) / (Zeitspanne in Tagen / 365.25).}
#'     \item{\code{share}}{mittlere geglaettete Wahrscheinlichkeit je Zustand
#'       (Anteil).}
#'   }
#'   \code{print()} fasst die Zustaende zusammen, \code{plot()} zeichnet die
#'   gefilterte Wahrscheinlichkeit des unruhigsten Zustands.
#' @seealso [regime_states()], [regime_subset()], [dependence_analysis()]
#' @examples
#' set.seed(1); n <- 8 * 365
#' d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n))
#' vol <- rep(rep(c(0.006, 0.02), c(500, 200)), length.out = n)  # ruhig / turbulent
#' d$aktien <- 100 * exp(cumsum(rnorm(n, 2e-4, vol)))
#' hmm <- regime_hmm(d, "aktien", k = 2)
#' hmm
#' hmm$volatility          # Prozent p. a. je Zustand
#' plot(hmm)
#' @section Quellen und Abweichungen:
#' Angelehnt an Hamilton (1989): gefilterte Wahrscheinlichkeiten wie im
#' Hamilton-Filter; abweichend: Gauss'sches HMM ohne autoregressiven Teil
#' (eigener Mittelwert und eigene Kovarianzmatrix je Zustand), geschaetzt
#' mit dem EM-Verfahren nach Baum u. a. (1970) statt durch numerische
#' Maximierung der Likelihood. Vorwaerts-Rueckwaerts-Rekursion mit
#' Skalierung, Neuschaetzung der Startverteilung und Viterbi-Pfad nach
#' Rabiner (1989) bzw. Viterbi (1967); BIC nach Schwarz (1978) mit
#' \eqn{k - 1 + k(k - 1) + kd + kd(d + 1)/2} Parametern. Eigene Festlegungen
#' von SimLev: Ridge-Zuschlag auf die Kovarianzmatrizen, Startwerte aus einer
#' Rangeinteilung der rollierenden Volatilitaet und zufaelligen Zuordnungen,
#' Sortierung der Zustaende nach Volatilitaet. Anwendung auf
#' Regime-Allokation wie bei Nystrup u. a. (2015); abweichend werden die
#' Parameter einmal auf der ganzen Historie geschaetzt (dort adaptiv), die
#' gefilterten Wahrscheinlichkeiten sind also nur bei gegebenen Parametern
#' frei von Zukunftsinformation.
#' @references Hamilton, J. D. (1989), A new approach to the economic analysis
#'   of nonstationary time series and the business cycle, Econometrica 57(2),
#'   357-384, \doi{10.2307/1912559}; Baum, L. E., Petrie, T., Soules, G. &
#'   Weiss, N. (1970), Annals of Mathematical Statistics 41(1), 164-171,
#'   \doi{10.1214/aoms/1177697196}; Rabiner, L. R. (1989), A tutorial on
#'   hidden Markov models and selected applications in speech recognition,
#'   Proceedings of the IEEE 77(2), 257-286, \doi{10.1109/5.18626}; Viterbi,
#'   A. J. (1967), IEEE Transactions on Information Theory 13(2), 260-269,
#'   \doi{10.1109/TIT.1967.1054010}; Schwarz, G. (1978), Estimating the
#'   dimension of a model, Annals of Statistics 6(2), 461-464,
#'   \doi{10.1214/aos/1176344136}; Nystrup, P., Hansen, B. W., Madsen, H. &
#'   Lindstroem, E. (2015), Regime-based versus static asset allocation:
#'   Letting the data speak, Journal of Portfolio Management 42(1), 103-109,
#'   \doi{10.3905/jpm.2015.42.1.103}.
#' @export
regime_hmm <- function(data, columns, k = 2L, frequency = c("week", "day", "month"), n_start = 5L,
                       max_iter = 300L, tol = 1e-7, seed = 1L) {
  frequency <- match.arg(frequency)
  fn <- "regime_hmm"                                              # seit 1.6.4 vor der Rechnung (K42 E4)
  if (is.factor(k) || !is.numeric(k) || length(k) != 1 || !is.finite(k) || k != round(k) || k < 2)   # seit 1.6.4 ohne Wert
    stop(chk_msg("c.m_regime_hmm"))
  chk_max(k, SL_MAX_N, fn, "k")                   # B-054 (bis 1.6.3 R: sprintf-Fehler bei k = 1e9)
  .e4_names(columns, fn, "columns")
  .e4_data(data, columns, fn)                                     # B-015
  .e4_count(n_start, fn, "n_start")                               # B-032
  .e4_count(max_iter, fn, "max_iter", lo = 0)
  chk_num1(tol, fn, "tol", lo = 0)
  k <- as.integer(k)
  rd <- .dep_returns(data, columns, NULL, frequency)
  X <- as.matrix(rd[, columns, drop = FALSE]); Tn <- nrow(X); d <- ncol(X)
  if (Tn < 50 * k) stop(sprintf("regime_hmm: zu wenige Perioden f\u00fcr die Zustandszahl (%d Perioden, mindestens %d).", Tn, 50 * k))
  flat <- columns[apply(X, 2, .sl_sd) == 0]
  if (length(flat)) stop(chk_msg("c.m_regime_hmm_2", paste0("'", flat, "'", collapse = ", ")))
  ppy <- (Tn - 1) / (as.numeric(rd$date[Tn] - rd$date[1]) / 365.25)
  ridge <- diag(1e-10 + 1e-6 * mean(apply(X, 2, .sl_var)), d)
  rs <- if (isTRUE(n_start >= 2)) .sl_main_stream(seed, "regime_hmm") else NULL   # Hauptstrom, nur bei Zufallsstarts
  inits <- lapply(seq_len(n_start), function(s) {
    if (s == 1) .hmm_init_rank(X, k, max(4, round(ppy / 12)), ridge)
    else .hmm_init_cl(X, .sl_sample(k, Tn, replace = TRUE, stream = rs), k, ridge)
  })
  fits <- lapply(inits, function(i) tryCatch(.hmm_em(X, k, i, max_iter, tol, ridge), error = function(e) NULL))
  n_failed <- sum(vapply(fits, is.null, TRUE))                    # seit 1.6.5 (K34, CR2-E-11)
  fits <- Filter(Negate(is.null), fits)
  if (!length(fits)) stop(chk_msg("c.m_regime_hmm_3"))
  f <- fits[[which.max(vapply(fits, `[[`, 0, "ll"))]]
  converged <- f$iter < max_iter
  if (!converged) warning(chk_msg("c.hmm_grenze", fn, max_iter), call. = FALSE)
  vol <- vapply(f$S, function(s) sqrt(mean(diag(s))), 0); o <- order(vol)
  A <- f$A[o, o, drop = FALSE]; mu <- f$mu[o, , drop = FALSE]; S <- f$S[o]
  lB <- f$lB[, o, drop = FALSE]
  path <- .hmm_viterbi(lB, log(A), log(f$p0[o]))
  np <- k - 1 + k * (k - 1) + k * d + k * d * (d + 1) / 2
  dimnames(A) <- list(paste0("Z", seq_len(k)), paste0("Z", seq_len(k)))
  structure(list(transition = A, means = `dimnames<-`(mu * ppy * 100, list(paste0("Z", seq_len(k)), columns)),
                 volatility = `dimnames<-`(matrix(vapply(S, function(s) sqrt(diag(s) * ppy) * 100, numeric(d)), k, d, byrow = TRUE), list(paste0("Z", seq_len(k)), columns)),
                 correlation = lapply(S, stats::cov2cor),
                 filtered = f$filtered[, o, drop = FALSE], smoothed = f$smoothed[, o, drop = FALSE], viterbi = path,
                 dates = rd$date, columns = columns, k = k, loglik = f$ll, bic = -2 * f$ll + np * log(Tn), initial = stats::setNames(f$p0[o], paste0("Z", seq_len(k))),
                 duration = 1 / (1 - diag(A)), frequency = frequency, ppy = ppy, share = colMeans(f$smoothed[, o, drop = FALSE]),
                 iterations = as.integer(f$iter), converged = converged, n_failed = as.integer(n_failed)),   # seit 1.6.5 (K34)
            class = "SimLevHMM")
}

#' @rdname regime_hmm
#' @param x Objekt der Klasse \code{SimLevHMM}.
#' @param ... Bei \code{print()} ungenutzt; bei \code{plot()} an
#'   [graphics::plot()] weitergereicht.
#' @export
print.SimLevHMM <- function(x, ...) {
  cat(sprintf("Hidden-Markov-Modell: %d Zust\u00e4nde auf %s (%s), %d Perioden, logL %.1f, BIC %.1f\n\n", x$k,
              paste(x$columns, collapse = ", "), x$frequency, length(x$dates), x$loglik, x$bic))
  for (j in seq_len(x$k)) cat(sprintf("  Z%d: Anteil %.0f %%, erwartete Dauer %.1f Perioden, Rendite %s %% p. a., Vola %s %%\n",
                                      j, 100 * x$share[j], x$duration[j], paste(sprintf("%.1f", x$means[j, ]), collapse = "/"),
                                      paste(sprintf("%.1f", x$volatility[j, ]), collapse = "/")))
  # seit 1.6.5 (K34): Schritte der Schaetzung (aeltere Objekte ohne das Feld: keine Zeile)
  if (!is.null(x$iterations)) cat(sprintf("  Schritte: %d%s%s\n", x$iterations, if (isTRUE(x$converged)) "" else " (Grenze erreicht)",
                                          if (isTRUE(x$n_failed > 0)) sprintf(", %d Startwert(e) verworfen", x$n_failed) else ""))
  cat("\n\u00dcbergangsmatrix\n"); print(round(x$transition, 3))
  cat(sprintf("\nAktueller Zustand (gefiltert): Z%d mit %.0f %%\n", which.max(x$filtered[nrow(x$filtered), ]), 100 * max(x$filtered[nrow(x$filtered), ])))
  invisible(x)
}

#' @rdname regime_hmm
#' @export
plot.SimLevHMM <- function(x, data = NULL, ...) {
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  graphics::par(mar = c(3.4, 4.4, 2.6, 1), mgp = c(2.4, 0.6, 0), las = 1, cex.axis = 0.8)
  P <- x$filtered; top <- P[, x$k]
  graphics::plot(x$dates, top, type = "l", col = "#B5562B", ylim = c(0, 1), xlab = "",
                 ylab = sprintf("P(Z%d | bis t)", x$k), main = sprintf("Gefilterte Wahrscheinlichkeit des unruhigsten Zustands (Z%d)", x$k), ...)
  graphics::polygon(c(x$dates, rev(x$dates)), c(top, rep(0, length(top))), col = grDevices::adjustcolor("#B5562B", 0.25), border = NA)
  graphics::abline(h = 0.5, lty = 3, col = "grey40")
  invisible(x)
}

#' Regime auf einen Tageskalender legen
#'
#' Ordnet jedem Tag den Zustand bzw. die Wahrscheinlichkeit zu, die zum Ende
#' der letzten abgeschlossenen Periode (plus \code{lag} Tage) bekannt war.
#' Mit \code{type = "filtered"} (Standard) enthaelt das Ergebnis keine
#' Zukunftsinformation und kann als Signal oder Bedingung dienen.
#'
#' @param x Objekt der Klasse \code{SimLevHMM} aus [regime_hmm()].
#' @param dates Zieldaten: Date-Vektor (oder umwandelbar) oder data.frame mit
#'   Spalte \code{date}, z. B. derselbe Datensatz wie in [regime_hmm()].
#' @param type \code{"filtered"} (Standard), \code{"smoothed"} oder
#'   \code{"viterbi"} (die beiden letzten nutzen die ganze Historie - nur zur
#'   Beschreibung; es erscheint eine Warnung).
#' @param output \code{"state"} (Standard: Nummer 1 bis k des
#'   wahrscheinlichsten Zustands bzw. Viterbi-Zustand) oder
#'   \code{"probability"} (Wahrscheinlichkeit von \code{state_prob} als
#'   Anteil; nicht mit \code{type = "viterbi"}).
#' @param state_prob Zustandsnummer (1 bis k) fuer \code{output =
#'   "probability"}; Standard \code{x$k}, der unruhigste Zustand.
#'   Seit 1.6.4 eine ganze Zahl von 1 bis k.
#' @param lag Verzoegerung in Kalendertagen (Standard 1): Der Wert einer
#'   Periode gilt ab Periodenende + \code{lag} Tage; 0 = schon am
#'   Periodenende.
#'   Seit 1.6.4 eine ganze Zahl >= 0.
#' @return Vektor mit einem Wert je Datum in \code{dates}: ganze Zahlen
#'   (Zustand) bzw. Wahrscheinlichkeiten als Anteil; \code{NA} vor dem ersten
#'   Periodenende + \code{lag}.
#' @seealso [regime_hmm()], [regime_subset()], [dependence_analysis()],
#'   [simulation()]
#' @examples
#' set.seed(1); n <- 8 * 365
#' d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n))
#' vol <- rep(rep(c(0.006, 0.02), c(500, 200)), length.out = n)
#' d$aktien <- 100 * exp(cumsum(rnorm(n, 2e-4, vol)))
#' hmm <- regime_hmm(d, "aktien", k = 2)
#' d$regime <- regime_states(hmm, d)             # 1 = ruhig, 2 = turbulent
#' table(d$regime, useNA = "ifany")
#' d$p_turbulent <- regime_states(hmm, d$date, output = "probability")
#' summary(d$p_turbulent)
#' @export
regime_states <- function(x, dates, type = c("filtered", "smoothed", "viterbi"), output = c("state", "probability"),
                          state_prob = x$k, lag = 1L) {
  type <- match.arg(type); output <- match.arg(output)
  fn <- "regime_states"                                           # seit 1.6.4 vor der Rechnung (K42 E4)
  if (!inherits(x, "SimLevHMM")) chk_stop("klasse", fn, "x", "regime_hmm()")
  if (is.data.frame(dates)) { chk_cols(dates, "date", fn); dv <- dates$date } else dv <- dates   # B-054
  if (is.factor(dv) || is.list(dv) || !is.null(dim(dv)) || !(inherits(dv, c("Date", "POSIXt")) || is.character(dv)) || !length(dv))
    chk_stop("e4.daten", fn)                                      # Entscheidung 7 und 15 (keine Zahl, kein Faktor)
  chk_int1(state_prob, fn, "state_prob", lo = 1, hi = x$k)        # B-007
  chk_int1(lag, fn, "lag", lo = 0)                                # B-012
  if (type != "filtered") warning(chk_msg("c.m_regime_states"))
  d <- .to_date(dv, "regime_states: dates")
  P <- switch(type, filtered = x$filtered, smoothed = x$smoothed, viterbi = NULL)
  v <- if (output == "probability") { if (is.null(P)) stop(chk_msg("c.m_regime_states_2")) ; P[, state_prob] }
       else if (is.null(P)) x$viterbi else max.col(P, ties.method = "first")
  k <- findInterval(as.numeric(d), as.numeric(x$dates) + lag)
  ifelse(k > 0, v[pmax(k, 1L)], NA)
}
