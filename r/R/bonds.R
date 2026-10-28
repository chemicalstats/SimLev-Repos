# =============================================================================
#  bonds.R  —  Synthetische Anleihe-, Geldmarkt- und gesicherte Reihen
# -----------------------------------------------------------------------------
#  index_bond()  Total-Return-Index einer Anleihe konstanter
#                            Laufzeit aus einer Renditereihe (Swinkels 2019):
#                            Kupon-Ertrag plus Kursaenderung durch
#                            Neubewertung (exakt) oder Duration/Konvexitaet
#  index_money_market()      Geldmarkt-Index aus einem Tageszins (Act/360)
#  index_currency_hedged()   waehrungsgesicherte Reihe: lokale Rendite plus
#                            Zinsdifferenz (gedeckte Zinsparitaet), minus Kosten
#
#  Alle Zinsen in Prozent p. a.; Eingaben als Spaltenname, Vektor, Skalar oder
#  data.frame(date, value) (Stufenfunktion), wie im restlichen Paket.
# =============================================================================

#' Kurs einer Anleihe je 1 Nominal
#' @keywords internal
#' @noRd
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
#' mit \eqn{\Delta t} = Kalendertage seit der Vorzeile / 365.25.
#' Mit \code{method = "duration"} wird die Kursaenderung ueber modifizierte
#' Duration und Konvexitaet angenaehert,
#' \eqn{-D\,\Delta y + \tfrac12 C\,\Delta y^2} (wie bei Swinkels 2019).
#' Roll-down-Effekte entlang der Zinskurve und Kosten sind nicht enthalten.
#' Das Ergebnis kann als Kursspalte (Niveau) in [simulation()] oder
#' [bootstrap_config()] verwendet werden.
#'
#' @param data data.frame mit Spalte \code{date} (Date oder umwandelbar, eine
#'   Zeile je Tag des gewuenschten Index).
#' @param yield Rendite in Prozent p. a. (2.5 = 2,5 Prozent): Spaltenname, Vektor
#'   der Laenge \code{nrow(data)}, Skalar, \code{data.frame(date, value)}
#'   (z. B. Monatswerte, Stufenfunktion ab Datum) oder benannter Vektor mit
#'   Datumsnamen.
#' @param maturity Konstante Restlaufzeit in Jahren (Standard 10).
#' @param coupon_frequency Kupons je Jahr (Standard 1 = jaehrlich wie
#'   Bundesanleihen; 2 = halbjaehrlich wie US-Treasuries).
#' @param method \code{"exact"} (Standard, Neubewertung) oder
#'   \code{"duration"} (Duration-/Konvexitaetsnaeherung).
#' @param start Startwert des Index in der ersten Zeile (Standard 100).
#' @return Numerischer Indexvektor (Niveau, Laenge \code{nrow(data)}) mit
#'   Attribut \code{duration} (modifizierte Duration der Par-Anleihe zur
#'   Rendite des jeweiligen Tages, in Jahren).
#' @references Swinkels, L. (2019), Treasury Bond Return Data Starting in
#'   1962, Data 4(3), 91.
#' @examples
#' set.seed(1)
#' d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 400))
#' d$y10 <- 2 + cumsum(rnorm(400, 0, 0.03))
#' b <- index_bond(d, "y10", maturity = 10, coupon_frequency = 1)
#' tail(b, 1)
#' head(attr(b, "duration"), 3)
#' b2 <- index_bond(d, "y10", method = "duration")
#' tail(b2, 1)
#' @seealso [index_money_market()], [index_currency_hedged()], [simulation()]
#' @export
index_bond <- function(data, yield, maturity = 10, coupon_frequency = 1, method = c("exact", "duration"),
                                   start = 100) {
  method <- match.arg(method)
  y <- .resolve_series(yield, data, "yield") / 100
  d <- .to_date(data$date, "data$date"); n <- length(y)
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
#' Bildet einen Geldmarkt- bzw. Tagesgeld-Index (Niveau) aus einem Zinssatz,
#' z. B. ESTR oder EFFR, als Kursspalte fuer [simulation()]:
#' \deqn{I_t = I_{t-1}\left(1 + \frac{i_{t-1} - s}{100}\cdot\frac{\Delta t}{B}\right)}
#' mit Zins \eqn{i} des Vortags, Abschlag \eqn{s} (z. B. Fondskosten),
#' Kalendertagen \eqn{\Delta t} seit der Vorzeile und Tagesbasis \eqn{B}
#' (Act/360).
#'
#' @param data data.frame mit Spalte \code{date} (eine Zeile je Indextag).
#' @param rate Zins in Prozent p. a. (3 = 3 Prozent): Spaltenname, Vektor der Laenge
#'   \code{nrow(data)}, Skalar, \code{data.frame(date, value)} (Stufenfunktion
#'   ab Datum) oder benannter Vektor mit Datumsnamen.
#' @param spread Abschlag in Prozent p. a. (Standard 0), auf derselben
#'   Tagesbasis wie der Zins.
#' @param basis Tagesbasis (Standard 360; ueblich 360 oder 365).
#' @param start Startwert des Index in der ersten Zeile (Standard 100).
#' @return Numerischer Indexvektor (Niveau, Laenge \code{nrow(data)}).
#' @examples
#' d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 730))
#' d$estr <- 3
#' mm <- index_money_market(d, "estr", spread = 0.1)
#' tail(mm, 1)
#' # Zinsstufen: 0 Prozent bis Ende 2020, danach 2 Prozent
#' mm2 <- index_money_market(d, c("2020-01-01" = 0, "2021-01-01" = 2))
#' mm2[c(366, 368, 730)]
#' @seealso [index_bond()], [index_currency_hedged()],
#'   [series_leverage()]
#' @export
index_money_market <- function(data, rate, spread = 0, basis = 360, start = 100) {
  i <- .resolve_series(rate, data, "rate")
  d <- .to_date(data$date, "data$date"); n <- length(i)
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
#' mit Zinsen des Vortags und Kalendertagen \eqn{\Delta t} seit der Vorzeile.
#' Effekte aus der Absicherung nur des Anfangswerts einer Rollperiode
#' (Restrisiko auf Kursgewinne) sind nicht enthalten.
#'
#' @param data data.frame mit Spalte \code{date}.
#' @param local Kursreihe in Lokalwaehrung (Niveau): Spaltenname in
#'   \code{data} oder numerischer Vektor der Laenge \code{nrow(data)};
#'   Luecken werden mit dem letzten Wert gefuellt.
#' @param domestic_rate,foreign_rate Zinsen der Heimat- bzw. Fremdwaehrung in
#'   Prozent p. a. (Spaltenname, Vektor, Skalar, \code{data.frame(date, value)}
#'   oder benannter Vektor mit Datumsnamen).
#' @param cost Sicherungskosten in Prozent p. a. (Standard 0; Tagesbasis 365).
#' @param basis Tagesbasis der Zinsdifferenz (Standard 360).
#' @param start Startwert; \code{NULL} (Standard) = erster Wert der lokalen
#'   Reihe.
#' @return Numerischer Indexvektor (Niveau, Laenge \code{nrow(data)}).
#' @examples
#' set.seed(1)
#' d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 730))
#' d$sp500 <- 100 * cumprod(1 + rnorm(730, 3e-4, 0.01))
#' # EUR-Anleger: Heimatzins 3, US-Zins 5, Kosten 0.1 (Prozent p. a.)
#' h <- index_currency_hedged(d, "sp500", domestic_rate = 3, foreign_rate = 5, cost = 0.1)
#' c(ungesichert = tail(d$sp500, 1), gesichert = tail(h, 1))
#' @seealso [index_money_market()], [series_convert_currency()], [simulation()]
#' @export
index_currency_hedged <- function(data, local, domestic_rate, foreign_rate, cost = 0, basis = 360, start = NULL) {
  x <- if (is.character(local)) as.numeric(data[[local]]) else as.numeric(local)
  x <- .fill_na(x, "locf")
  id <- .resolve_series(domestic_rate, data, "domestic_rate"); ifr <- .resolve_series(foreign_rate, data, "foreign_rate")
  d <- .to_date(data$date, "data$date"); n <- length(x); days <- c(0, diff(as.numeric(d)))
  r <- c(0, x[-1] / x[-n] - 1 + (id[-n] - ifr[-n]) / 100 * days[-1] / basis - cost / 100 * days[-1] / 365)
  (start %||% x[1]) * cumprod(1 + r)
}
