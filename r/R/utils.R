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
