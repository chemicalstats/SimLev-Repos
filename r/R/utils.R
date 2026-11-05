# utils.R  —  interne Hilfen (Operator %||% fuer NULL-Ersatzwerte)

#' Operator fuer NULL-Ersatzwerte
#'
#' Gibt \code{a} zurueck, ausser es ist \code{NULL}; dann wird \code{b} zurueckgegeben.
#' Bereitgestellt fuer die Kompatibilitaet mit R < 4.4 (dort ist \code{%||%} nicht in base).
#' @param a,b Werte; \code{a} wird zurueckgegeben, sofern es nicht \code{NULL} ist.
#' @return \code{a}, wenn nicht \code{NULL}, sonst \code{b}.
#' @keywords internal
#' @noRd
`%||%` <- function(a, b) if (is.null(a)) b else a

# Genauere Renditeformeln (seit 1.6.2; gleicher Ausdruck in Python _util und Julia util.jl, im Kern evaluate_core_impl.h
# und slc_tcop.cpp). Ausserhalb der Bereiche, in denen die genaue Fassung dasselbe bedeutet, die bisherige Formel.
#   .cagr_q(q, yrs)   q^(1/yrs) - 1 als expm1(log(q) / yrs) (q >= 0, yrs endlich und != 0)        (P3)
#   .pow1m(x, e)      (1 + x)^e - 1 als expm1(log1p(x) * e) (x >= -1, e endlich und != 0)         (P3)
#   .pow1m_v(x, e)    dasselbe elementweise (TER geometrisch im Backcast)                          (P1)
#   .geo_ret(x)       prod(1 + x) - 1 als expm1(sum(log1p(x))) (kein NA, alle x >= -1)            (P2)
#   .geo_ann(x, yrs)  prod(1 + x)^(1/yrs) - 1 als expm1(sum(log1p(x)) / yrs) (wie beide oben)     (P3)
#   .log1mr2(r)       log(1 - r^2): log1p(-r^2) fuer r^2 < 1/2, sonst log((1 - r)(1 + r)); Fehler <= 1,4 ulp (P4)
#' @keywords internal
#' @noRd
.cagr_q <- function(q, yrs)
  if (isTRUE(q >= 0) && isTRUE(is.finite(yrs) && yrs != 0)) expm1(log(q) / yrs) else q^(1 / yrs) - 1
#' @keywords internal
#' @noRd
.pow1m <- function(x, e)
  if (isTRUE(x >= -1) && isTRUE(is.finite(e) && e != 0)) expm1(log1p(x) * e) else (1 + x)^e - 1
#' @keywords internal
#' @noRd
.pow1m_v <- function(x, e) {                                   # elementweise .pow1m (Recycling wie (1 + x)^e)
  out <- (1 + x)^e - 1
  n <- length(out)
  if (!n) return(out)
  x <- rep_len(as.double(x), n); e <- rep_len(as.double(e), n)
  ok <- !is.na(x) & !is.na(e) & x >= -1 & is.finite(e) & e != 0
  out[ok] <- expm1(log1p(x[ok]) * e[ok])
  out
}
#' @keywords internal
#' @noRd
.geo_ret <- function(x) if (!anyNA(x) && all(x >= -1)) expm1(sum(log1p(x))) else prod(1 + x) - 1
#' @keywords internal
#' @noRd
.geo_ann <- function(x, yrs)
  if (!anyNA(x) && all(x >= -1) && isTRUE(is.finite(yrs) && yrs != 0)) expm1(sum(log1p(x)) / yrs) else prod(1 + x)^(1 / yrs) - 1
#' @keywords internal
#' @noRd
.log1mr2 <- function(r) if (isTRUE(r * r < 0.5)) log1p(-(r * r)) else log((1 - r) * (1 + r))

# Deutsche Monatsabkuerzungen fuer Grafikachsen (month.abb ist englisch)
.monate_kurz <- c("Jan", "Feb", "M\u00e4r", "Apr", "Mai", "Jun", "Jul", "Aug", "Sep", "Okt", "Nov", "Dez")

#' Jahr und Monat ganzzahlig aus der Tageszahl (seit 1.5.1)
#'
#' Statt \code{format(x, "\%Y")} bzw. \code{"\%Y-\%m"} je Tag (as.POSIXlt): Kalender aus der abgerundeten Tageszahl
#' wie as.POSIXlt.Date, Verfahren nach H. Hinnant, chrono-Compatible Low-Level Date Algorithms (civil_from_days;
#' wie bis 1.3.0 .sim_civil, heute core/slc_rbase_date.cpp), ganzzahlig (bei Tagen jenseits von +-2 Mrd. in
#' Gleitkomma mit ganzzahligen Werten).
#' Gleiche Jahre und Monate wie format(); \code{NULL} bei nicht endlichen Tagen (NA, NaN, Inf) und ohne Klasse Date, dann bleibt der
#' Aufrufer bei format().
#' @keywords internal
#' @noRd
.date_ym <- function(x) {
  if (!inherits(x, "Date") || !is.numeric(unclass(x))) return(NULL)
  z <- floor(unclass(x))
  if (!all(is.finite(z))) return(NULL)
  # ganzzahlig, solange der Bereich reicht (Tage bis +-2 Mrd.; %/% auf Ganzzahlen ist viel schneller), sonst
  # dieselbe Rechnung in Gleitkomma mit ganzzahligen Werten
  z <- if (all(abs(z) < 2e9)) as.integer(z) + 719468L else z + 719468
  era <- z %/% 146097L
  doe <- z - era * 146097L
  yoe <- (doe - doe %/% 1460L + doe %/% 36524L - doe %/% 146096L) %/% 365L
  doy <- doe - (365L * yoe + yoe %/% 4L - yoe %/% 100L)
  mp <- (5L * doy + 2L) %/% 153L
  m <- mp + 3L - 12L * (mp >= 10L)
  list(y = as.vector(yoe + era * 400L + (m <= 2L)), m = as.vector(m))
}

#' Gruppenschluessel je Tag fuer Wochen, Monate, Quartale oder Jahre (seit 1.5.1)
#'
#' Ganzzahlig statt \code{format(x, "\%G-\%V")}, \code{"\%Y-\%m"} usw. je Tag: zwei Tage haben genau dann denselben
#' Schluessel wie dort denselben Text. ISO-Woche: Montag der Woche (1970-01-01 war ein Donnerstag); Monat
#' Jahr * 12 + Monat, Quartal Jahr * 4 + (Monat - 1) \%/\% 3, Jahr (ueber \code{.date_ym}). \code{NULL} bei nicht
#' endlichen Tagen und ohne Klasse Date; dann bleibt der Aufrufer bei format().
#' @keywords internal
#' @noRd
.date_key <- function(x, unit) {
  if (unit == "week") {
    if (!inherits(x, "Date") || !is.numeric(unclass(x))) return(NULL)
    z <- floor(unclass(x))
    if (!all(is.finite(z))) return(NULL)
    if (all(abs(z) < 2e9)) z <- as.integer(z)
    return(as.vector(z - (z + 3L) %% 7L))
  }
  ym <- .date_ym(x)
  if (is.null(ym)) return(NULL)
  switch(unit, month = ym$y * 12 + ym$m, quarter = ym$y * 4 + (ym$m - 1) %/% 3, year = ym$y)
}

#' match() fuer zwei Date-Vektoren ueber die abgerundete Tageszahl (seit 1.5.1)
#'
#' match() auf Date vergleicht ueber mtfrm() die Texte as.character(as.POSIXlt()) je Tag; gleich ist der Vergleich
#' der abgerundeten Tageszahlen (wie bis 1.3.0 .sim_date_match). Sonst (nicht beide Date, nicht endliche Tage)
#' unveraendert match().
#' @keywords internal
#' @noRd
.date_match <- function(x, table) {
  if (inherits(x, "Date") && inherits(table, "Date") && is.numeric(unclass(x)) && is.numeric(unclass(table))) {
    zx <- floor(unclass(x)); zt <- floor(unclass(table))
    if (all(is.finite(zx)) && all(is.finite(zt))) return(match(as.vector(zx), as.vector(zt)))
  }
  match(x, table)
}
