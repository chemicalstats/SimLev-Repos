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

#' Log-Dichte der multivariaten Normalverteilung je Zeile
#' @keywords internal
#' @noRd
.ldmvn <- function(X, mu, S) {
  L <- chol(S); Z <- t(backsolve(L, t(sweep(X, 2, mu)), transpose = TRUE))
  -0.5 * rowSums(Z^2) - sum(log(diag(L))) - 0.5 * ncol(X) * log(2 * pi)
}

#' Viterbi-Pfad aus Log-Emissionen (Perioden x Zustand), Log-Uebergangsmatrix und
#' Log-Startverteilung; je Schritt erstes Maximum je Spalte wie which.max
#' (max.col mit ties.method = "first" vergleicht exakt), bei NA/NaN wie bisher ueber apply
#' @keywords internal
#' @noRd
.hmm_viterbi <- function(lB, lA, lp0) {
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
  Tn <- nrow(X)
  mu <- init$mu; S <- init$S; A <- init$A; p0 <- rep(1 / k, k); ll_old <- -Inf
  estep <- function() {                                           # E-Schritt mit den aktuellen Parametern
    lB <- vapply(seq_len(k), function(j) .ldmvn(X, mu[j, ], S[[j]]), numeric(Tn))
    if (!is.matrix(lB)) lB <- matrix(lB, ncol = k)
    m <- lB[, 1]; for (j in seq_len(k)[-1]) m <- pmax(m, lB[, j])   # Zeilenmaximum (wie apply(lB, 1, max), aber vektorisiert)
    fb <- .hmm_forward_backward(exp(lB - m), A, p0)               # Kern in C++
    list(lB = lB, fb = fb, ll = sum(log(fb$scale)) + sum(m))
  }
  for (it in seq_len(max_iter)) {
    es <- estep(); ga <- es$fb$smoothed; xi <- es$fb$xi; ll <- es$ll
    p0 <- ga[1, ]; A <- xi / rowSums(xi)
    for (j in seq_len(k)) { w <- ga[, j]; sw <- sum(w); mu[j, ] <- colSums(X * w) / sw
      Xc <- sweep(X, 2, mu[j, ]); S[[j]] <- crossprod(Xc * sqrt(w)) / sw + ridge }
    if (abs(ll - ll_old) < tol * (1 + abs(ll))) break
    ll_old <- ll
  }
  es <- estep()       # Log-Likelihood und Wahrscheinlichkeiten zu den gelieferten (zuletzt geschaetzten) Parametern
  list(mu = mu, S = S, A = A, p0 = p0, ll = es$ll, filtered = es$fb$filtered, smoothed = es$fb$smoothed, lB = es$lB, iter = it)
}

#' HMM-Startwert aus einer Einteilung der Perioden in k Gruppen: Mittelwert
#' und Kovarianz (plus ridge) je Gruppe, Uebergangsmatrix 0.9 auf der
#' Diagonale, Rest gleich verteilt
#' @keywords internal
#' @noRd
.hmm_init_cl <- function(X, cl, k, ridge) {
  d <- ncol(X)
  list(mu = matrix(vapply(seq_len(k), function(j) colMeans(X[cl == j, , drop = FALSE]), numeric(d)), k, d, byrow = TRUE),
       S = lapply(seq_len(k), function(j) stats::cov(X[cl == j, , drop = FALSE]) + ridge),
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
#' @param frequency Periodenlaenge der Renditen: \code{"week"} (Standard,
#'   ISO-Wochen), \code{"day"} oder \code{"month"}. Bei \code{"day"} entfallen
#'   Tage, an denen alle Renditen 0 sind (z. B. fortgeschriebene
#'   Wochenenden).
#' @param n_start Anzahl Startwerte (ganze Zahl, Standard 5): der erste aus
#'   Quantilen einer rollierenden Volatilitaet, die uebrigen zufaellig; es
#'   zaehlt das Ergebnis mit der hoechsten Log-Likelihood.
#' @param max_iter,tol Hoechstzahl Baum-Welch-Iterationen je Start (Standard
#'   300) und relative Abbruchschranke: Abbruch, wenn sich die
#'   Log-Likelihood um weniger als \code{tol * (1 + |logL|)} aendert
#'   (Standard 1e-7).
#' @param seed Startwert (ganze Zahl, Standard 1) fuer die zufaelligen
#'   Startwerte. Mit Startwert ist das Ergebnis reproduzierbar und der
#'   Zufallszustand der Sitzung bleibt unveraendert; mit `NULL` wird der
#'   Zufallsstrom der Sitzung normal weitergezogen.
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
#' @references Hamilton, J. D. (1989), Econometrica 57(2); Nystrup, P.,
#'   Madsen, H. & Lindstroem, E. (2015), Regime-based asset allocation: Do
#'   profitable strategies exist?, Journal of Portfolio Management 42(1).
#' @export
regime_hmm <- function(data, columns, k = 2L, frequency = c("week", "day", "month"), n_start = 5L,
                       max_iter = 300L, tol = 1e-7, seed = 1L) {
  frequency <- match.arg(frequency)
  if (!is.numeric(k) || length(k) != 1 || !is.finite(k) || k != round(k) || k < 2)
    stop(sprintf("regime_hmm: k muss eine ganze Zahl >= 2 sein (erhalten: %s); ein Zustand w\u00e4re eine einzige Normalverteilung ohne Regime.",
                 paste(format(k), collapse = ", ")))
  k <- as.integer(k)
  rd <- .dep_returns(data, columns, NULL, frequency)
  X <- as.matrix(rd[, columns, drop = FALSE]); Tn <- nrow(X); d <- ncol(X)
  if (Tn < 50 * k) stop(sprintf("regime_hmm: zu wenige Perioden f\u00fcr die Zustandszahl (%d Perioden, mindestens %d f\u00fcr k = %d).", Tn, 50 * k, k))
  flat <- columns[apply(X, 2, stats::sd) == 0]
  if (length(flat)) stop(sprintf("regime_hmm: Spalte(n) %s ohne Schwankung (alle Periodenrenditen gleich, z. B. konstante Kurse); kein Modell sch\u00e4tzbar.",
                                 paste0("'", flat, "'", collapse = ", ")))
  ppy <- (Tn - 1) / (as.numeric(rd$date[Tn] - rd$date[1]) / 365.25)
  ridge <- diag(1e-10 + 1e-6 * mean(apply(X, 2, stats::var)), d)
  inits <- .with_rng_restore(seed = seed, {
    lapply(seq_len(n_start), function(s) {
      if (s == 1) .hmm_init_rank(X, k, max(4, round(ppy / 12)), ridge)
      else .hmm_init_cl(X, sample.int(k, Tn, replace = TRUE), k, ridge)
    })
  })
  fits <- lapply(inits, function(i) tryCatch(.hmm_em(X, k, i, max_iter, tol, ridge), error = function(e) NULL))
  fits <- Filter(Negate(is.null), fits)
  if (!length(fits)) stop("regime_hmm: Sch\u00e4tzung fehlgeschlagen.")
  f <- fits[[which.max(vapply(fits, `[[`, 0, "ll"))]]
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
                 duration = 1 / (1 - diag(A)), frequency = frequency, ppy = ppy, share = colMeans(f$smoothed[, o, drop = FALSE])),
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
#' @param lag Verzoegerung in Kalendertagen (Standard 1): Der Wert einer
#'   Periode gilt ab Periodenende + \code{lag} Tage; 0 = schon am
#'   Periodenende.
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
  if (type != "filtered") warning("Gegl\u00e4ttete bzw. Viterbi-Zust\u00e4nde nutzen Zukunftsdaten - nur zur Beschreibung verwenden.")
  d <- .to_date(if (is.data.frame(dates)) dates$date else dates, "regime_states: dates")
  P <- switch(type, filtered = x$filtered, smoothed = x$smoothed, viterbi = NULL)
  v <- if (output == "probability") { if (is.null(P)) stop("Wahrscheinlichkeit nicht f\u00fcr Viterbi.") ; P[, state_prob] }
       else if (is.null(P)) x$viterbi else max.col(P, ties.method = "first")
  k <- findInterval(as.numeric(d), as.numeric(x$dates) + lag)
  ifelse(k > 0, v[pmax(k, 1L)], NA)
}
