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

#' Eingaben der index_*-Bausteine pruefen (seit 1.6.4, A-014, B-011, B-012, B-016)
#'
#' data nur als Tabelle mit Spalte date (Entscheidung 6); eine Zinsangabe als Spaltenname (numerische Spalte; eine
#' Spalte nur aus NA zaehlt als Zahlenspalte, Entscheidung 14) oder als einzelne Zahl endlich, NULL fehlt; die uebrigen Formen
#' (Vektor der Laenge nrow(data), data.frame(date, value), benannter Vektor mit Datumsnamen) prueft .resolve_series.
#' @keywords internal
#' @noRd
# Entscheidung 15: Tabellenangaben (z. B. data.frame(date, value)) ohne Faktorspalte
.no_factor_df <- function(x, fn) {
  if (is.data.frame(x)) for (k in names(x)) if (is.factor(x[[k]])) chk_stop("spalte_faktor", fn, k)
  invisible(x)
}
.idx_data <- function(data, fn) {
  chk_df(data, fn, "data")
  chk_cols(data, "date", fn)
  chk_col_nofactor(data, "date", fn)   # seit 1.6.4 (Entscheidung 15; bis 1.6.3 still in Text umgewandelt)
  if (!nrow(data)) chk_stop("zeilen_keine", fn, "data")   # seit 1.6.4 Fehler (Entscheidung 25; bis 1.6.3 R 100)
  invisible(data)
}
.idx_rate <- function(x, data, fn, arg) {
  if (is.null(x)) chk_stop("fehlt", fn, arg)   # bis 1.6.3: NULL still als 0
  .no_factor_df(x, fn)
  chk_nofactor(x, fn, arg)   # Entscheidung 15
  if (is.character(x) && length(x) == 1L) {
    chk_name1(x, fn, arg)
    if (x %in% names(data)) {
      v <- data[[x]]
      if (is.factor(v)) chk_stop("spalte_faktor", fn, x)   # Entscheidung 15
      if (!(is.numeric(v) || (is.logical(v) && all(is.na(v)))))
        chk_stop("spalte_typ", fn, x, chk_msg("typ.numerisch"))
    }
  } else if (is.numeric(x) && length(x) == 1L && is.null(names(x)) && !is.data.frame(x)) {
    chk_num1(x, fn, arg)
  }
  invisible(x)
}

#' Kurs einer Anleihe je 1 Nominal
#' @keywords internal
#' @noRd
.bond_price <- function(y, coupon, maturity, m) {
  i <- y / m; n <- maturity * m
  dis <- (1 + i)^(-n)   # seit 1.6.4 (A-057) einmal statt zweimal (gleicher Wert)
  ann <- ifelse(abs(i) < 1e-10, n, (1 - dis) / i)
  coupon / m * ann + dis
}

#' Modifizierte Duration und Konvexitaet der Par-Anleihe (Kupon = Rendite), geschlossen
#'
#' Seit 1.6.4 (K43 T1-R3, Entscheidung 136) statt zentraler Differenzen der Kurse (h = 1e-4; relativer Fehler bis 2e-6
#' bei 30 Jahren). Mit i = y / m, n = maturity * m, L = log1p(i): Duration D = -expm1(-n L) / (i m) (bei i = 0 die
#' Laufzeit); Konvexitaet C = 2 (a - n v^(n + 1)) / (i m^2) mit a = -expm1(-n L) / i, v^(n + 1) = exp(-(n + 1) L), fuer
#' |i| (n + 1) < 0.05 (Ausloeschung) ueber die Reihe 2 / m^2 * sum_k (-1)^(k + 1) n choose(n + k, k) k / (k + 1) i^(k - 1)
#' (16 Glieder). NA und NaN ergeben NA. Gleiche Rechenfolge in Python und Julia.
#' @keywords internal
#' @noRd
.bond_dur <- function(i, n, maturity, m) {
  du <- -expm1(-n * log1p(i)) / (i * m)
  du[!is.na(i) & i == 0] <- maturity
  du[is.na(i)] <- NA_real_   # NA und NaN: NA (immer double, auch wenn alle Renditen fehlen)
  du
}
.bond_cvx <- function(i, n, m) {
  L <- log1p(i)
  cv <- 2 * (-expm1(-n * L) / i - n * exp(-(n + 1) * L)) / (i * (m * m))
  sm <- !is.na(i) & abs(i) * (n + 1) < 0.05
  if (any(sm)) {
    is <- i[sm]
    t <- rep(n * (n + 1) / 2, length(is)); s <- t
    for (k in 1:15) {
      t <- t * (-is) * (n + k + 1) * (k + 1) / (k * (k + 2))
      s <- s + t
    }
    cv[sm] <- 2 * s / (m * m)
  }
  cv[is.na(i)] <- NA
  cv
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
#' @param maturity Konstante Restlaufzeit in Jahren (Standard 10; eine endliche Zahl > 0).
#' @param coupon_frequency Kupons je Jahr (eine endliche Zahl > 0; Standard 1 = jaehrlich wie
#'   Bundesanleihen; 2 = halbjaehrlich wie US-Treasuries).
#' @param method \code{"exact"} (Standard, Neubewertung) oder
#'   \code{"duration"} (Duration-/Konvexitaetsnaeherung).
#' @param start Startwert des Index in der ersten Zeile (Standard 100; > 0). Seit
#'   1.6.4 geprueft: \code{data} nur als data.frame mit Spalte \code{date} (mindestens eine
#'   Datenzeile; seit 1.6.4 ist 0 Zeilen ein Fehler), eine Spalte als Zinsangabe numerisch, eine Zahl endlich,
#'   \code{NULL} fehlt.
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
  fn <- "index_bond"
  .idx_data(data, fn)
  if (missing(yield)) chk_stop("fehlt", fn, "yield")
  .idx_rate(yield, data, fn, "yield")
  chk_num1(maturity, fn, "maturity", lo = 0, lo_open = TRUE)
  chk_num1(coupon_frequency, fn, "coupon_frequency", lo = 0, lo_open = TRUE)
  chk_num1(start, fn, "start", lo = 0, lo_open = TRUE)
  method <- match.arg(method)
  y <- .resolve_series(yield, data, "yield") / 100
  m <- coupon_frequency
  # seit 1.6.4 (K43 T1-R8): Renditen von -100 % je Kuponperiode oder weniger ergaben Inf/NaN bzw. Indexwerte mit
  # wechselndem Vorzeichen; Werte zwischen -100 % * coupon_frequency und 0 bleiben erlaubt
  if (any(y / m <= -1, na.rm = TRUE)) chk_stop("ut1.rendite", fn)
  d <- .to_date(data$date, "data$date"); n <- length(y)
  dt <- c(0, diff(as.numeric(d))) / 365.25
  y0 <- c(y[1], y[-n]); c0 <- y0
  nm <- maturity * m
  if (method == "exact") {
    price <- .bond_price(y, c0, maturity, m)
  } else {
    # seit 1.6.4 (K43 T1-R3, Entscheidung 136) Duration und Konvexitaet der Par-Anleihe geschlossen (bis dahin
    # zentrale Differenzen mit h = 1e-4, geteilt durch den Kurs)
    i0 <- y0 / m
    dur <- .bond_dur(i0, nm, maturity, m)
    cvx <- .bond_cvx(i0, nm, m)
    dy <- y - y0
    price <- 1 - dur * dy + 0.5 * cvx * dy^2
  }
  r <- price - 1 + c0 * dt
  r[1] <- 0
  out <- start * cumprod(1 + r)
  attr(out, "duration") <- .bond_dur(y / m, nm, maturity, m)   # seit 1.6.4 geschlossen (K43 T1-R3)
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
#' @param spread Abschlag in Prozent p. a. (Standard 0; endlich), auf derselben
#'   Tagesbasis wie der Zins.
#' @param basis Tagesbasis (Standard 360; ueblich 360 oder 365; > 0).
#' @param start Startwert des Index in der ersten Zeile (Standard 100; > 0). Seit
#'   1.6.4 geprueft: \code{data} nur als data.frame mit Spalte \code{date} (mindestens eine
#'   Datenzeile; seit 1.6.4 ist 0 Zeilen ein Fehler), eine Spalte als Zinsangabe numerisch, eine Zahl endlich,
#'   \code{NULL} fehlt.
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
  fn <- "index_money_market"
  .idx_data(data, fn)
  if (missing(rate)) chk_stop("fehlt", fn, "rate")
  .idx_rate(rate, data, fn, "rate")
  chk_num1(spread, fn, "spread")
  chk_num1(basis, fn, "basis", lo = 0, lo_open = TRUE)
  chk_num1(start, fn, "start", lo = 0, lo_open = TRUE)
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
#' @param cost Sicherungskosten in Prozent p. a. (Standard 0; Tagesbasis 365; endlich).
#' @param basis Tagesbasis der Zinsdifferenz (Standard 360; > 0).
#' @param start Startwert; \code{NULL} (Standard) = erster Wert der lokalen
#'   Reihe; sonst > 0. \code{local} als Vektor muss die Laenge \code{nrow(data)}
#'   haben (seit 1.6.4; vorher wiederholte R einen kuerzeren Vektor).
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
  fn <- "index_currency_hedged"
  .idx_data(data, fn)
  if (missing(local)) chk_stop("fehlt", fn, "local")
  if (missing(domestic_rate)) chk_stop("fehlt", fn, "domestic_rate")
  if (missing(foreign_rate)) chk_stop("fehlt", fn, "foreign_rate")
  # local: Spaltenname einer numerischen Spalte oder numerischer Vektor der Laenge nrow(data) (bis 1.6.3 wiederholte
  # R einen kuerzeren Vektor reihum)
  if (is.character(local)) {
    chk_name1(local, fn, "local")
    chk_cols(data, local, fn)
    .idx_rate(local, data, fn, "local")
  } else {
    chk_nofactor(local, fn, "local")   # Entscheidung 15
    if (!is.null(dim(local))) chk_stop("zahlen", fn, "local")
    chk_numvec(local, fn, "local")
    chk_len(local, nrow(data), fn, "local")
  }
  .idx_rate(domestic_rate, data, fn, "domestic_rate"); .idx_rate(foreign_rate, data, fn, "foreign_rate")
  chk_num1(cost, fn, "cost")
  chk_num1(basis, fn, "basis", lo = 0, lo_open = TRUE)
  chk_num1(start, fn, "start", lo = 0, lo_open = TRUE, null_ok = TRUE)
  x <- if (is.character(local)) as.numeric(data[[local]]) else as.numeric(local)
  x <- .fill_na(x, "locf")
  id <- .resolve_series(domestic_rate, data, "domestic_rate"); ifr <- .resolve_series(foreign_rate, data, "foreign_rate")
  d <- .to_date(data$date, "data$date"); n <- length(x); days <- c(0, diff(as.numeric(d)))
  r <- c(0, x[-1] / x[-n] - 1 + (id[-n] - ifr[-n]) / 100 * days[-1] / basis - cost / 100 * days[-1] / 365)
  (start %||% x[1]) * cumprod(1 + r)
}
