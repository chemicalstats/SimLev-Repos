#' Null-coalescing operator
#'
#' Returns \code{a} unless it is \code{NULL}, in which case \code{b} is returned.
#' Provided for compatibility with R < 4.4 (where \code{\%||\%} is not in base).
#' @param a,b values; \code{a} is returned unless \code{NULL}.
#' @return \code{a} if not \code{NULL}, otherwise \code{b}.
#' @keywords internal
`%||%` <- function(a, b) if (is.null(a)) b else a
