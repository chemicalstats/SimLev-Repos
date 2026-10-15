# =============================================================================
#  tactical.R  —  Taktische Allokation ueber zeitvariable Zielgewichte
# -----------------------------------------------------------------------------
#  Gewichts-Erzeuger (liefern ein SimLevWeights: data.frame(date, Asset...)
#  mit dem Zielgewicht, das nach Schlusskurs des Tages bekannt ist):
#    tactical_rules()     geordnete Bedingungen -> Zielportfolio, Rueckfall
#    tactical_rotation()  Momentum-Rotation: Top-N, Dual Momentum (absoluter
#                         Filter), Canary-/Breitenschutz (Keller & Keuning)
#    target_volatility()  Zielvolatilitaet: Risikoanteil skalieren, Rest in
#                         eine sichere Anlage (Moreira & Muir 2017)
#    glidepath()          Gewichte zeitlich zwischen zwei Allokationen
#    blend_weights()      Kern-Satellit: Mischung mehrerer Gewichtsreihen
#    signal_state()       Kauf-/Verkaufssignale -> dauerhafter Zustand
#    momentum_score()     Momentum-Score je Anlage
#  Ausfuehrung:
#    tactical_simulation() uebersetzt die Gewichte in event_col/event_weight
#                         von simulation() (Engine unveraendert): Handel an
#                         Wechsel- und Pflegeterminen mit Verzoegerung 'lag',
#                         optionalem Toleranzband, Steuern und Kosten wie immer.
# =============================================================================

#' Gewichts-Frame bauen und pruefen
#' @keywords internal
.as_weights <- function(dates, W, source = "") {
  W <- as.matrix(W); W[!is.finite(W)] <- 0; W[W < 0] <- 0
  s <- rowSums(W); bad <- s <= 0
  if (any(bad)) stop(sprintf("Gewichte: %d Zeilen ohne positive Gewichte.", sum(bad)))
  W <- W / s
  out <- data.frame(date = as.Date(dates), W, check.names = FALSE)
  structure(out, class = c("SimLevWeights", "data.frame"), source = source)
}

#' Zeilen am Ende jeder Periode (letzte vorhandene Zeile)
#' @keywords internal
.period_last <- function(dates, every) {
  key <- switch(every, day = seq_along(dates), week = format(dates, "%G-%V"), month = format(dates, "%Y-%m"),
                quarter = paste(format(dates, "%Y"), (as.integer(format(dates, "%m")) - 1L) %/% 3L),
                year = format(dates, "%Y"), stop("every: 'day', 'week', 'month', 'quarter' oder 'year'."))
  if (every == "day") return(seq_along(dates))
  which(c(key[-1] != key[-length(key)], TRUE))
}

#' Werte an Entscheidungszeilen bis zur naechsten Entscheidung halten
#' @keywords internal
.hold_rows <- function(n, rows, M) {
  idx <- findInterval(seq_len(n), rows)
  out <- matrix(NA_real_, n, ncol(M), dimnames = list(NULL, colnames(M)))
  ok <- idx > 0
  out[ok, ] <- M[idx[ok], , drop = FALSE]
  out
}

#' Signale in einen dauerhaften Zustand uebersetzen
#'
#' \code{TRUE} ab einem Kaufsignal bis zum naechsten Verkaufssignal (wie die
#' Ein-/Ausstiegslogik von \code{simulation()}).
#'
#' @param signal \code{list(buy, sell)} (z. B. aus [signal_sma()]).
#' @param initial Zustand vor dem ersten Signal.
#' @return Logischer Vektor.
#' @export
signal_state <- function(signal, initial = FALSE) {
  b <- signal$buy; s <- signal$sell; n <- length(b)
  ev <- ifelse(b & !s, 1L, ifelse(s & !b, -1L, 0L))
  idx <- which(ev != 0L)
  st <- rep(initial, n)
  if (length(idx)) {
    k <- findInterval(seq_len(n), idx)
    st[k > 0] <- ev[idx[k[k > 0]]] == 1L
  }
  st
}

#' Momentum-Score
#'
#' Mittlere Rendite ueber mehrere Rueckblicke (Monate, kalenderbasiert) je
#' Anlage, z. B. der "13612"-Score (1, 3, 6, 12 Monate). Mit
#' \code{type = "13612w"} gewichtet wie bei Keller & Keuning:
#' \eqn{(12 r_1 + 4 r_3 + 2 r_6 + r_{12}) / 4}.
#'
#' @param data data.frame mit \code{date} und Kursspalten.
#' @param assets Kursspalten.
#' @param lookbacks Rueckblicke in Monaten.
#' @param type \code{"average"} (Mittel der Renditen) oder \code{"13612w"}.
#' @return Matrix Zeilen x Anlagen (NA, solange die Historie zu kurz ist).
#' @export
momentum_score <- function(data, assets, lookbacks = c(1, 3, 6, 12), type = c("average", "13612w")) {
  type <- match.arg(type)
  d <- as.Date(data$date); n <- length(d)
  if (type == "13612w") lookbacks <- c(1, 3, 6, 12)
  back <- lapply(lookbacks, function(m) {
    past <- do.call(c, lapply(d, function(x) seq.Date(x, by = sprintf("-%d months", m), length.out = 2)[2]))
    findInterval(as.numeric(past), as.numeric(d))
  })
  S <- vapply(assets, function(a) {
    x <- .fill_na(as.numeric(data[[a]]), "locf", keep_leading = TRUE)
    R <- vapply(back, function(k) ifelse(k > 0, x / x[pmax(k, 1L)] - 1, NA_real_), numeric(n))
    if (!is.matrix(R)) R <- matrix(R, ncol = length(back))
    if (type == "13612w") (12 * R[, 1] + 4 * R[, 2] + 2 * R[, 3] + R[, 4]) / 4 else rowMeans(R)
  }, numeric(n))
  if (!is.matrix(S)) S <- matrix(S, ncol = length(assets), dimnames = list(NULL, assets))
  S
}

#' Regelbasierte taktische Allokation
#'
#' Geordnete Bedingungen waehlen je Tag ein Zielportfolio; die erste
#' zutreffende Regel gewinnt, sonst gilt \code{default}. Bedingungen sind
#' logische Vektoren, Ausdruecke als Zeichenkette (ausgewertet in
#' \code{data}, z. B. \code{"inflation > 3"}) oder Signale aus den
#' Signal-Bausteinen (\code{list(buy, sell)}, als Zustand mit Hysterese).
#'
#' @param data data.frame mit \code{date} (und den in Bedingungen verwendeten
#'   Spalten).
#' @param rules Liste von \code{list(when = ..., weights = c(A = 0.6, B = 0.4))}.
#' @param default Zielportfolio, wenn keine Regel zutrifft.
#' @return \code{SimLevWeights} mit Attribut \code{regime} (Nummer der aktiven
#'   Regel, 0 = default).
#' @examples
#' d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 500))
#' d$A <- 100 * cumprod(1 + rnorm(500, 3e-4, 0.01)); d$B <- 100 * cumprod(1 + rnorm(500, 1e-4, 0.003))
#' w <- tactical_rules(d, list(list(when = signal_sma(d$A, 200), weights = c(A = 1))),
#'                     default = c(B = 1))
#' table(attr(w, "regime"))
#' @export
tactical_rules <- function(data, rules, default) {
  n <- nrow(data); env <- parent.frame()
  assets <- unique(c(unlist(lapply(rules, function(r) names(r$weights))), names(default)))
  cond <- vapply(rules, function(r) {
    w <- r$when
    v <- if (is.character(w)) eval(parse(text = w), data, env)
         else if (is.list(w) && !is.null(w$buy)) signal_state(w) else w
    v <- as.logical(v); v[is.na(v)] <- FALSE
    if (length(v) != n) stop("Bedingung hat nicht die Laenge nrow(data).")
    v
  }, logical(n))
  if (!is.matrix(cond)) cond <- matrix(cond, nrow = n)
  regime <- apply(cond, 1, function(z) { k <- which(z); if (length(k)) k[1] else 0L })
  vec <- function(w) { v <- stats::setNames(rep(0, length(assets)), assets); v[names(w)] <- w; v }
  P <- rbind(vec(default), do.call(rbind, lapply(rules, function(r) vec(r$weights))))
  W <- P[regime + 1L, , drop = FALSE]
  out <- .as_weights(data$date, W, "rules")
  attr(out, "regime") <- regime
  out
}

#' Momentum-Rotation, Dual Momentum und Canary-Schutz
#'
#' An jedem Entscheidungstermin (Periodenende) werden die Anlagen nach ihrem
#' Momentum-Score sortiert und die besten \code{top} gehalten.
#' \itemize{
#'   \item \strong{Absolutes Momentum} (\code{absolute = TRUE}, Dual Momentum
#'     nach Antonacci): Ein gewaehlter Platz mit negativem Score geht an die
#'     beste sichere Anlage aus \code{safe}.
#'   \item \strong{Canary/Breite} (\code{canary}, Keller & Keuning): Bei
#'     \eqn{b} Canary-Anlagen mit negativem Score geht der Anteil
#'     \eqn{\min(1, b / B)} an die sichere Anlage (\eqn{B} = \code{breadth}).
#' }
#'
#' @param data data.frame mit \code{date} und Kursspalten.
#' @param assets Risikoanlagen fuer die Rotation.
#' @param top Anzahl gehaltener Anlagen.
#' @param safe Sichere Anlage(n); bei mehreren wird die mit dem besten Score
#'   gewaehlt.
#' @param absolute Absoluten Momentum-Filter anwenden.
#' @param canary Optional Canary-Anlagen.
#' @param breadth Schutzschwelle B (Standard: Anzahl Canary-Anlagen).
#' @param lookbacks,type Siehe [momentum_score()].
#' @param every Entscheidungsrhythmus (\code{"month"}, \code{"week"},
#'   \code{"quarter"}).
#' @param weighting \code{"equal"} oder \code{"inverse_vol"} (63 Zeilen).
#' @return \code{SimLevWeights} mit Attribut \code{scores}.
#' @references Antonacci, G. (2014), Dual Momentum Investing; Keller, W. J. &
#'   Keuning, J. W. (2018), Breadth Momentum and the Canary Universe: Defensive
#'   Asset Allocation (DAA), SSRN 3212862.
#' @export
tactical_rotation <- function(data, assets, top = 1L, safe = NULL, absolute = TRUE, canary = NULL, breadth = NULL,
                              lookbacks = c(1, 3, 6, 12), type = c("average", "13612w"),
                              every = c("month", "week", "quarter"), weighting = c("equal", "inverse_vol")) {
  type <- match.arg(type); every <- match.arg(every); weighting <- match.arg(weighting)
  if ((absolute || length(canary)) && !length(safe)) stop("absolute bzw. canary brauchen eine sichere Anlage 'safe'.")
  allc <- unique(c(assets, safe, canary))
  S <- momentum_score(data, allc, lookbacks, type)
  d <- as.Date(data$date); n <- length(d)
  rows <- .period_last(d, every)
  rows <- rows[apply(S[rows, assets, drop = FALSE], 1, function(z) sum(is.finite(z)) >= top)]
  if (!length(rows)) stop("Zu kurze Historie fuer den Rueckblick.")
  out_assets <- unique(c(assets, safe))
  vol <- if (weighting == "inverse_vol") vapply(assets, function(a) {
    r <- c(NA, diff(log(.fill_na(as.numeric(data[[a]]), "locf", keep_leading = TRUE))))
    sqrt(pmax(.roll_mean(ifelse(is.na(r), 0, r)^2, 63), 1e-12))
  }, numeric(n)) else NULL
  M <- t(vapply(rows, function(i) {
    w <- stats::setNames(rep(0, length(out_assets)), out_assets)
    sc <- S[i, assets]; ok <- which(is.finite(sc))
    pick <- assets[ok][order(sc[ok], decreasing = TRUE)][seq_len(min(top, length(ok)))]
    best_safe <- if (length(safe)) { ss <- S[i, safe]; if (all(!is.finite(ss))) safe[1] else safe[which.max(ss)] } else NULL
    pw <- if (weighting == "equal") rep(1 / length(pick), length(pick)) else { iv <- 1 / vol[i, pick]; iv / sum(iv) }
    cash <- 0
    if (length(canary)) {
      b <- sum(S[i, canary] < 0, na.rm = TRUE); B <- breadth %||% length(canary)
      cash <- min(1, b / B)
    }
    for (k in seq_along(pick)) {
      share <- pw[k] * (1 - cash)
      if (absolute && is.finite(S[i, pick[k]]) && S[i, pick[k]] < 0) w[best_safe] <- w[best_safe] + share
      else w[pick[k]] <- w[pick[k]] + share
    }
    if (cash > 0) w[best_safe] <- w[best_safe] + cash
    w
  }, numeric(length(out_assets))))
  if (!is.matrix(M)) M <- matrix(M, ncol = length(out_assets))
  colnames(M) <- out_assets
  H <- .hold_rows(n, rows, M)
  first <- rows[1]; H[seq_len(first - 1L), ] <- 0
  if (first > 1L) H[seq_len(first - 1L), if (length(safe)) safe[1] else assets[1]] <- 1
  out <- .as_weights(d, H, "rotation")
  attr(out, "scores") <- S; attr(out, "decision_rows") <- rows
  out
}

#' Zielvolatilitaet
#'
#' Skaliert den Risikoteil einer Gewichtsreihe so, dass die geschaetzte
#' Volatilitaet des Risikoportfolios dem Ziel entspricht; der Rest geht in
#' die sichere Anlage. Die Volatilitaet wird aus den Tagesrenditen der
#' Risikoanlagen mit den aktuellen Gewichten ueber \code{window} Zeilen mit
#' Kursbewegung geschaetzt (Tage ohne Bewegung, etwa Wochenenden, zaehlen
#' nicht).
#'
#' @param data data.frame mit \code{date} und Kursspalten.
#' @param weights \code{SimLevWeights} (Risikoportfolio) oder benannter
#'   Gewichtsvektor.
#' @param safe Sichere Anlage (Spalte).
#' @param target Zielvolatilitaet in Prozent p. a.
#' @param window Fenster in Handelstagen.
#' @param max_exposure Hoechster Risikoanteil (1 = ohne Hebel).
#' @param every Anpassungsrhythmus.
#' @param ppy Tage mit Kursbewegung je Jahr fuer die Annualisierung
#'   (Standard: aus den Daten geschaetzt, z. B. rund 252 bei Boersentagen,
#'   365 bei einem Index, der auch am Wochenende notiert).
#' @return \code{SimLevWeights} mit Attribut \code{exposure}.
#' @references Moreira, A. & Muir, T. (2017), Volatility-Managed Portfolios,
#'   Journal of Finance 72(4).
#' @export
target_volatility <- function(data, weights, safe, target = 10, window = 63L, max_exposure = 1,
                              every = c("month", "week", "day", "quarter"), ppy = NULL) {
  every <- match.arg(every)
  if (max_exposure > 1) stop("max_exposure > 1 waere Kredit; die Engine kennt keine Kreditaufnahme (Hebel ueber Hebelprodukte abbilden).")
  d <- as.Date(data$date); n <- length(d)
  if (!inherits(weights, "SimLevWeights")) weights <- .as_weights(d, matrix(weights, n, length(weights), byrow = TRUE,
                                                                             dimnames = list(NULL, names(weights))), "static")
  risky <- setdiff(names(weights)[-1], safe)
  Wr <- as.matrix(weights[, risky, drop = FALSE])
  R <- vapply(risky, function(a) { x <- .fill_na(as.numeric(data[[a]]), "locf", keep_leading = TRUE); c(0, x[-1] / x[-n] - 1) }, numeric(n))
  if (!is.matrix(R)) R <- matrix(R, ncol = length(risky))
  R[!is.finite(R)] <- 0
  rs <- rowSums(Wr); Wn <- Wr / ifelse(rs > 0, rs, 1)
  pr <- c(0, rowSums(Wn[-n, , drop = FALSE] * R[-1, , drop = FALSE]))    # Gewichte vom Vortag
  move <- abs(pr) > 0
  if (is.null(ppy)) ppy <- sum(move) / max(as.numeric(d[n] - d[1]) / 365.25, 1e-9)
  vol <- rep(NA_real_, n); idx <- which(move)
  if (length(idx) > window) {
    v <- .roll_mean(pr[idx]^2, window) - .roll_mean(pr[idx], window)^2
    vol[idx] <- sqrt(pmax(v, 0) * ppy)
  }
  vol <- .fill_na(vol, "locf", keep_leading = TRUE)
  rows <- .period_last(d, every); rows <- rows[is.finite(vol[rows])]
  if (!length(rows)) stop("Zu kurze Historie fuer das Volatilitaetsfenster.")
  expo_r <- pmin(max_exposure, target / 100 / pmax(vol[rows], 1e-6))
  expo <- rep(NA_real_, n); expo[rows] <- expo_r
  k <- findInterval(seq_len(n), rows); expo <- ifelse(k > 0, expo_r[pmax(k, 1L)], 0)
  W <- cbind(Wr * expo, 1 - expo * rs)
  colnames(W) <- c(risky, safe)
  W[W < 0] <- 0
  out <- .as_weights(d, W, "target_volatility")
  attr(out, "exposure") <- expo; attr(out, "volatility") <- vol
  out
}

#' Glidepath zwischen zwei Allokationen
#'
#' @param data data.frame mit \code{date} oder Datumsvektor.
#' @param from,to Benannte Gewichtsvektoren am Anfang und Ende.
#' @param start,end Beginn und Ende des Uebergangs (Standard: erstes und
#'   letztes Datum).
#' @param every Anpassungsrhythmus der Stufen (\code{"year"}, \code{"quarter"},
#'   \code{"month"}).
#' @return \code{SimLevWeights}.
#' @examples
#' gp <- glidepath(seq.Date(as.Date("2025-01-01"), as.Date("2045-12-31"), by = "day"),
#'                 from = c(aktien = 0.9, anleihen = 0.1), to = c(aktien = 0.4, anleihen = 0.6))
#' gp[c(1, 3653, 7670), ]
#' @export
glidepath <- function(data, from, to, start = NULL, end = NULL, every = c("year", "quarter", "month")) {
  every <- match.arg(every)
  d <- if (is.data.frame(data)) as.Date(data$date) else as.Date(data)
  a <- unique(c(names(from), names(to)))
  f <- stats::setNames(rep(0, length(a)), a); f[names(from)] <- from
  t <- stats::setNames(rep(0, length(a)), a); t[names(to)] <- to
  s <- as.Date(start %||% d[1]); e <- as.Date(end %||% d[length(d)])
  rows <- unique(c(1L, .period_last(d, every)))
  frac <- pmin(1, pmax(0, as.numeric(d[rows] - s) / as.numeric(e - s)))
  M <- t(vapply(frac, function(p) (1 - p) * f + p * t, numeric(length(a)))); colnames(M) <- a
  H <- .hold_rows(length(d), rows, M)
  .as_weights(d, H, "glidepath")
}

#' Gewichtsreihen mischen (Kern-Satellit)
#'
#' @param ... Benannte \code{SimLevWeights} (gleiche Daten).
#' @param shares Anteile je Reihe (Standard: gleich).
#' @return \code{SimLevWeights}.
#' @export
blend_weights <- function(..., shares = NULL) {
  ws <- list(...)
  shares <- shares %||% rep(1 / length(ws), length(ws))
  d <- ws[[1]]$date
  if (!all(vapply(ws, function(w) identical(as.numeric(w$date), as.numeric(d)), TRUE))) stop("blend_weights: unterschiedliche Daten.")
  a <- unique(unlist(lapply(ws, function(w) names(w)[-1])))
  W <- matrix(0, length(d), length(a), dimnames = list(NULL, a))
  for (k in seq_along(ws)) for (nm in names(ws[[k]])[-1]) W[, nm] <- W[, nm] + shares[k] * ws[[k]][[nm]]
  .as_weights(d, W, "blend")
}

#' @export
print.SimLevWeights <- function(x, ...) {
  W <- as.matrix(x[, -1, drop = FALSE])
  ch <- rowSums(abs(W[-1, , drop = FALSE] - W[-nrow(W), , drop = FALSE])) > 1e-9
  cat(sprintf("SimLev-Zielgewichte (%s): %d Tage, %s bis %s, %d Wechsel\n", attr(x, "source") %||% "",
              nrow(x), format(x$date[1]), format(x$date[nrow(x)]), sum(ch)))
  m <- rbind(Mittel = colMeans(W), Min = apply(W, 2, min), Max = apply(W, 2, max), Zuletzt = W[nrow(W), ])
  print(round(100 * m, 1))
  invisible(x)
}

#' @export
plot.SimLevWeights <- function(x, ...) {
  W <- as.matrix(x[, -1, drop = FALSE]); d <- x$date
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  graphics::par(mar = c(3.6, 4.2, 2.6, 7), mgp = c(2.4, 0.6, 0), las = 1, cex.axis = 0.85, xpd = FALSE)
  cols <- grDevices::colorRampPalette(c("#2C6E9B", "#3E8E5A", "#C49A2C", "#B5562B", "#8A5BA8", "#4A4A4A"))(ncol(W))
  graphics::plot(range(d), c(0, 1), type = "n", xlab = "", ylab = "Gewicht", main = "Zielgewichte", ...)
  cum <- cbind(0, t(apply(W, 1, cumsum)))
  for (j in seq_len(ncol(W)))
    graphics::polygon(c(d, rev(d)), c(cum[, j + 1], rev(cum[, j])), col = cols[j], border = NA)
  graphics::par(xpd = TRUE)
  graphics::legend(graphics::par("usr")[2], 1, colnames(W), fill = cols, bty = "n", cex = 0.8, border = NA)
  invisible(x)
}

#' Taktische Allokation simulieren
#'
#' Uebersetzt eine Zielgewichtsreihe in Ereignis-Rebalancing von
#' [simulation()]: An Wechselterminen (Zielgewicht aendert sich) und an
#' optionalen Pflegeterminen wird auf die Zielgewichte umgeschichtet, mit
#' Steuern, Spreads und allen weiteren Einstellungen der Engine. Die Engine
#' selbst bleibt unveraendert (\code{event_col}, \code{event_mode =
#' "replace"}, \code{event_weight}).
#'
#' \itemize{
#'   \item \code{lag}: Ein Zielgewicht, das nach Schluss von Tag t bekannt
#'     ist, wird nach \code{lag} Zeilen gehandelt (Standard 1 = naechster
#'     Handelstag; 0 = am selben Schlusskurs, wie bei vielen Online-Backtestern).
#'   \item \code{rebalance}: \code{"switch"} (nur bei Wechseln) oder ein
#'     Rhythmus (\code{"month"}, \code{"quarter"}, \code{"year"}), zu dem
#'     zusaetzlich auf die aktuellen Zielgewichte zurueckgefuehrt wird.
#'   \item \code{tolerance}: Toleranzband (wie \code{balance_thresh}); an
#'     Terminen innerhalb des Bands wird nicht gehandelt.
#'   \item Umschichtungen nutzen die Rebalancing-Logik der Engine, die mit den
#'     Ist-Gewichten des letzten Bewertungsstands (Vortag) rechnet; nach einem
#'     Wechsel koennen daher Reste in der Groessenordnung der Tagesbewegung
#'     (meist unter einem Prozent) in der verlassenen Anlage bleiben. Ein Pflegerhythmus (\code{rebalance =
#'     "month"}) gleicht sie aus.
#'   \item Sparplaene (\code{dca_mode}) zahlen nach den Startgewichten ein; der
#'     Sparplantag wird zum Rebalancing-Termin, so dass die Rate sofort auf die
#'     aktuellen Zielgewichte verteilt wird.
#' }
#'
#' @param data data.frame mit \code{date} und Kursspalten aller Anlagen der
#'   Gewichte (z. B. mit [align_series()] vorbereitet).
#' @param weights \code{SimLevWeights} (aus [tactical_rules()],
#'   [tactical_rotation()], [target_volatility()], [glidepath()],
#'   [blend_weights()] oder [rolling_optimization()]).
#' @param rebalance \code{"switch"}, \code{"month"}, \code{"quarter"} oder
#'   \code{"year"}.
#' @param tolerance Toleranzband in Prozent (\code{NULL} = immer handeln).
#' @param tolerance_type \code{"absolute"} oder \code{"relative"}.
#' @param lag Verzoegerung in Zeilen.
#' @param asset_args Liste von Argumenten fuer [asset_config()] (benannte
#'   Vektoren je Anlage moeglich), z. B.
#'   \code{list(asset_spread = 0.1, asset_bonus = c(aktien = 30))}.
#' @param ... Weitere Argumente fuer [simulation()].
#' @return \code{SimLevResult} mit zusaetzlichem Element \code{tactical}
#'   (gehandelte Zielgewichte, Ereignistage, Zahl der Wechsel).
#' @export
tactical_simulation <- function(data, weights, rebalance = c("switch", "month", "quarter", "year"),
                                tolerance = NULL, tolerance_type = c("absolute", "relative"), lag = 1L,
                                asset_args = list(), ...) {
  rebalance <- match.arg(rebalance); tolerance_type <- match.arg(tolerance_type)
  if (!inherits(weights, "SimLevWeights")) stop("weights muss ein SimLevWeights sein.")
  sim_args <- list(...)
  bad <- intersect(names(sim_args), c("event_col", "event_mode", "event_weight", "balance_mode", "balance_thresh"))
  if (length(bad)) stop(sprintf("tactical_simulation steuert %s selbst.", paste(bad, collapse = ", ")))
  assets <- names(weights)[-1]
  miss <- setdiff(assets, names(data)); if (length(miss)) stop(sprintf("Kursspalten fehlen: %s", paste(miss, collapse = ", ")))
  d <- as.Date(data$date)
  k <- match(as.numeric(d), as.numeric(weights$date))
  W <- as.matrix(weights[, assets, drop = FALSE])[k, , drop = FALSE]
  W <- apply(W, 2, function(v) .fill_na(v, "locf", keep_leading = FALSE))
  if (!is.matrix(W)) W <- matrix(W, nrow = length(d), dimnames = list(NULL, assets))
  lag <- as.integer(lag)
  if (lag > 0) W <- rbind(W[rep(1L, lag), , drop = FALSE], W[seq_len(nrow(W) - lag), , drop = FALSE])
  n <- nrow(W)
  change <- c(FALSE, rowSums(abs(W[-1, , drop = FALSE] - W[-n, , drop = FALSE])) > 1e-10)
  ev <- change
  if (rebalance != "switch") ev[.period_last(d, rebalance)] <- TRUE
  if (isTRUE(sim_args$dca_mode)) {
    cal <- seq.Date(d[1], d[n], by = "day")
    fl <- calculate_dates_flags(mode = TRUE, span = sim_args$dca_span %||% 1, unit = sim_args$dca_unit %||% "month",
                                days = sim_args$dca_days, dates = cal, value = sim_args$dca_value %||% 1,
                                anchor = sim_args$dca_anchor %||% "start", start_date = sim_args$dca_start,
                                skip_start = sim_args$dca_skip %||% FALSE, liquidate = sim_args$liquidate %||% FALSE)
    j <- findInterval(as.numeric(cal[fl]) - 1e-9, as.numeric(d)) + 1L
    ev[j[j <= n]] <- TRUE
  }
  ev[1] <- FALSE
  df <- data
  wcols <- paste0(".tw_", assets)
  for (j in seq_along(assets)) df[[wcols[j]]] <- W[, j]
  df$.tev <- ev
  w0 <- pmax(W[1, ], 1e-9); w0 <- w0 / sum(w0)
  st <- do.call(strategy_from_weights, c(list(weights = stats::setNames(w0, assets)), asset_args))
  args <- c(list(data = df, strategy = st, event_col = ".tev", event_mode = "replace",
                 event_weight = stats::setNames(as.list(wcols), assets),
                 balance_thresh = tolerance, balance_thresh_type = tolerance_type), sim_args)
  res <- do.call(simulation, args)
  res$tactical <- list(weights = .as_weights(d, W, attr(weights, "source")), events = d[ev], switches = sum(change), lag = lag,
                       rebalance = rebalance)
  res
}
