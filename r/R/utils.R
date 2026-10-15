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
