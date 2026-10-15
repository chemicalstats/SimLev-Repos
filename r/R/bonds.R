# =============================================================================
#  bonds.R  —  Synthetische Anleihe-, Geldmarkt- und gesicherte Reihen
# -----------------------------------------------------------------------------
#  bond_index_from_yields()  Total-Return-Index einer Anleihe konstanter
#                            Laufzeit aus einer Renditereihe (Swinkels 2019):
#                            Kupon-Ertrag plus Kursaenderung durch
#                            Neubewertung (exakt) oder Duration/Konvexitaet
#  money_market_index()      Geldmarkt-Index aus einem Tageszins (Act/360)
#  currency_hedged_index()   waehrungsgesicherte Reihe: lokale Rendite plus
#                            Zinsdifferenz (gedeckte Zinsparitaet), minus Kosten
#
#  Alle Zinsen in Prozent p. a.; Eingaben als Spaltenname, Vektor, Skalar oder
#  data.frame(date, value) (Stufenfunktion), wie im restlichen Paket.
# =============================================================================

#' Kurs einer Anleihe je 1 Nominal
#' @keywords internal
.bond_price <- function(y, coupon, maturity, m) {
  i <- y / m; n <- maturity * m
  ann <- ifelse(abs(i) < 1e-10, n, (1 - (1 + i)^(-n)) / i)
  coupon / m * ann + (1 + i)^(-n)
}

#' Anleihe-Index aus Renditen (konstante Laufzeit)
#'
#' Bildet einen Total-Return-Index einer Staatsanleihe mit konstanter
#' Restlaufzeit aus einer Renditereihe. An jedem Tag wird eine neue
#' Par-Anleihe (Kupon = Rendite des Vortags) gekauft und am Folgetag zur neuen
#' Rendite bewertet:
#' \deqn{r_t = P(y_t; c = y_{t-1}, M) - 1 + y_{t-1}\,\Delta t}
#' Mit \code{method = "duration"} wird die Kursaenderung ueber modifizierte
#' Duration und Konvexitaet angenaehert,
#' \eqn{-D\,\Delta y + \tfrac12 C\,\Delta y^2} (wie bei Swinkels 2019).
#' Roll-down-Effekte entlang der Zinskurve und Kosten sind nicht enthalten.
#'
#' @param data data.frame mit Spalte \code{date}.
#' @param yield Rendite in Prozent: Spaltenname, Vektor oder
#'   \code{data.frame(date, value)} (z. B. Monatswerte, Stufenfunktion).
#' @param maturity Laufzeit in Jahren.
#' @param coupon_frequency Kupons je Jahr (2 = halbjaehrlich wie US-Treasuries,
#'   1 = jaehrlich wie Bundesanleihen).
#' @param method \code{"exact"} oder \code{"duration"}.
#' @param start Startwert.
#' @return Numerischer Indexvektor (Laenge \code{nrow(data)}) mit Attribut
#'   \code{duration} (modifizierte Duration je Tag).
#' @references Swinkels, L. (2019), Treasury Bond Return Data Starting in
#'   1962, Data 4(3), 91.
#' @examples
#' d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 400))
#' d$y10 <- 2 + cumsum(rnorm(400, 0, 0.03))
#' b <- bond_index_from_yields(d, "y10", maturity = 10, coupon_frequency = 1)
#' tail(b, 1)
#' @export
bond_index_from_yields <- function(data, yield, maturity = 10, coupon_frequency = 1, method = c("exact", "duration"),
                                   start = 100) {
  method <- match.arg(method)
  y <- .resolve_series(yield, data, "yield") / 100
  d <- as.Date(data$date); n <- length(y)
  dt <- c(0, diff(as.numeric(d))) / 365.25
  m <- coupon_frequency
  y0 <- c(y[1], y[-n]); c0 <- y0
  if (method == "exact") {
    price <- .bond_price(y, c0, maturity, m)
  } else {
    h <- 1e-4
    p0 <- .bond_price(y0, c0, maturity, m)
    dur <- -(.bond_price(y0 + h, c0, maturity, m) - .bond_price(y0 - h, c0, maturity, m)) / (2 * h) / p0
    cvx <- (.bond_price(y0 + h, c0, maturity, m) - 2 * p0 + .bond_price(y0 - h, c0, maturity, m)) / h^2 / p0
    dy <- y - y0
    price <- 1 - dur * dy + 0.5 * cvx * dy^2
  }
  r <- price - 1 + c0 * dt
  r[1] <- 0
  out <- start * cumprod(1 + r)
  h <- 1e-4
  attr(out, "duration") <- -(.bond_price(y + h, y, maturity, m) - .bond_price(y - h, y, maturity, m)) / (2 * h)
  out
}

#' Geldmarkt-Index aus einem Tageszins
#'
#' \deqn{I_t = I_{t-1}\left(1 + \frac{i_{t-1} - s}{100}\cdot\frac{\Delta t}{B}\right)}
#' mit Zins \eqn{i} des Vortags, Abschlag \eqn{s} (z. B. Fondskosten) und
#' Tagesbasis \eqn{B} (Act/360).
#'
#' @param data data.frame mit \code{date}.
#' @param rate Zins in Prozent p. a. (Spaltenname, Vektor, Skalar oder
#'   \code{data.frame(date, value)}).
#' @param spread Abschlag in Prozent p. a.
#' @param basis Tagesbasis (360 oder 365).
#' @param start Startwert.
#' @return Numerischer Indexvektor.
#' @export
money_market_index <- function(data, rate, spread = 0, basis = 360, start = 100) {
  i <- .resolve_series(rate, data, "rate")
  d <- as.Date(data$date); n <- length(i)
  days <- c(0, diff(as.numeric(d)))
  r <- c(0, (i[-n] - spread) / 100 * days[-1] / basis)
  start * cumprod(1 + r)
}

#' Waehrungsgesicherte Reihe
#'
#' Naeherung einer rollierend per Devisentermingeschaeft gesicherten Anlage:
#' Die Rendite in Lokalwaehrung plus die Zinsdifferenz zwischen Heimat- und
#' Fremdwaehrung (gedeckte Zinsparitaet), abzueglich Sicherungskosten:
#' \deqn{r^{h}_t = r^{lokal}_t + \frac{i^{heim}_{t-1} - i^{fremd}_{t-1}}{100}\cdot\frac{\Delta t}{B} - \frac{k}{100}\cdot\frac{\Delta t}{365}}
#' Effekte aus der Absicherung nur des Anfangswerts einer Rollperiode
#' (Restrisiko auf Kursgewinne) sind nicht enthalten.
#'
#' @param data data.frame mit \code{date}.
#' @param local Kursreihe in Lokalwaehrung (Spaltenname oder Vektor).
#' @param domestic_rate,foreign_rate Zinsen in Prozent p. a.
#' @param cost Sicherungskosten in Prozent p. a.
#' @param basis Tagesbasis der Zinsen.
#' @param start Startwert (Standard: erster Wert der lokalen Reihe).
#' @return Numerischer Indexvektor.
#' @export
currency_hedged_index <- function(data, local, domestic_rate, foreign_rate, cost = 0, basis = 360, start = NULL) {
  x <- if (is.character(local)) as.numeric(data[[local]]) else as.numeric(local)
  x <- .fill_na(x, "locf")
  id <- .resolve_series(domestic_rate, data, "domestic_rate"); ifr <- .resolve_series(foreign_rate, data, "foreign_rate")
  d <- as.Date(data$date); n <- length(x); days <- c(0, diff(as.numeric(d)))
  r <- c(0, x[-1] / x[-n] - 1 + (id[-n] - ifr[-n]) / 100 * days[-1] / basis - cost / 100 * days[-1] / 365)
  (start %||% x[1]) * cumprod(1 + r)
}
