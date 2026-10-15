# =============================================================================
#  signals.R  —  Parametrisierbare Signal-Bausteine
# -----------------------------------------------------------------------------
#  Jeder Baustein nimmt eine Kursreihe und liefert list(buy, sell) mit
#  logischen Vektoren gleicher Laenge (NA -> FALSE). Das ist genau das Format,
#  das bootstrap_study() und param_search() in einer Strategie-Spezifikation
#  ueber 'signal = function(df) ...' erwarten. Fenster zaehlen in Zeilen; bei
#  Kalendertagsdaten (Wochenenden per LOCF) also in Kalendertagen.
#
#  Semantik in simulation(): Kauf nur, wenn das Asset nicht gehalten wird und
#  'buy' TRUE ist; Verkauf, wenn es gehalten wird und 'sell' TRUE ist. Liegen
#  beide FALSE (Band/Hysterese), bleibt der Zustand unveraendert.
# =============================================================================

#' Rollierender Mittelwert (Fenster n, inklusive aktueller Zeile)
#' @keywords internal
.roll_mean <- function(x, n) {
  n <- as.integer(n); m <- length(x)
  out <- rep(NA_real_, m)
  if (n < 1L || n > m) return(out)
  cs <- cumsum(c(0, x))
  out[n:m] <- (cs[(n + 1L):(m + 1L)] - cs[1:(m - n + 1L)]) / n
  out
}

#' Exponentieller gleitender Durchschnitt (Start mit SMA der ersten n Werte)
#' @keywords internal
.ema <- function(x, n) {
  n <- as.integer(n); m <- length(x); out <- rep(NA_real_, m)
  if (n < 1L || n > m) return(out)
  a <- 2 / (n + 1)
  out[n] <- mean(x[1:n])
  if (n < m) out[(n + 1L):m] <- stats::filter(a * x[(n + 1L):m], 1 - a, method = "recursive", init = out[n])
  out
}

#' Signale um k Zeilen verzoegern und NA bereinigen
#' @keywords internal
.sig_out <- function(buy, sell, lag = 0L) {
  lag <- as.integer(lag)
  if (lag > 0L) {
    m <- length(buy)
    buy <- c(rep(FALSE, lag), buy[seq_len(m - lag)])
    sell <- c(rep(FALSE, lag), sell[seq_len(m - lag)])
  }
  buy[is.na(buy)] <- FALSE; sell[is.na(sell)] <- FALSE
  list(buy = as.logical(buy), sell = as.logical(sell))
}

#' Signal-Bausteine
#'
#' Erzeugen Kauf- und Verkaufssignale aus einer Kursreihe, im Format, das
#' [bootstrap_study()] und [param_search()] fuer \code{signal = function(df) ...}
#' erwarten. Alle Schwellen in Prozent.
#'
#' \describe{
#'   \item{signal_sma}{Kurs ueber/unter dem gleitenden Durchschnitt (n Zeilen),
#'     optional mit Band: Kauf ab \code{SMA * (1 + band/100)}, Verkauf unter
#'     \code{SMA * (1 - band/100)}, dazwischen bleibt der Zustand.}
#'   \item{signal_ema}{Wie \code{signal_sma} mit exponentiellem Durchschnitt.}
#'   \item{signal_crossover}{Schneller ueber langsamem Durchschnitt.}
#'   \item{signal_momentum}{Rendite ueber n Zeilen ueber/unter \code{threshold}.}
#'   \item{signal_drawdown}{Verkauf ab \code{sell_dd} Prozent unter dem
#'     (rollierenden) Hoch, Wiedereinstieg, sobald der Abstand unter
#'     \code{buy_dd} Prozent faellt.}
#'   \item{signal_volatility}{Realisierte Volatilitaet (annualisiert, Prozent)
#'     ueber n Zeilen: Kauf unter \code{threshold}, Verkauf darueber
#'     (optional mit Band).}
#'   \item{signal_combine}{Verknuepft Signale: \code{"and"} kauft nur, wenn alle
#'     kaufen, und verkauft, sobald eines verkauft; \code{"or"} umgekehrt.}
#' }
#'
#' @param x Numerische Kursreihe (z. B. \code{df$eu}).
#' @param n,fast,slow Fensterlaengen in Zeilen.
#' @param band Hysterese-Band in Prozent.
#' @param threshold Schwelle in Prozent.
#' @param sell_dd,buy_dd Drawdown-Schwellen in Prozent (positiv).
#' @param window Rollierendes Fenster fuer das Hoch (\code{NULL} = laufendes Hoch).
#' @param type \code{"sma"} oder \code{"ema"}.
#' @param ppy Zeilen je Jahr fuer die Annualisierung (365.25 bei Kalendertagen).
#' @param lag Verzoegerung in Zeilen (z. B. 1, um am Folgetag zu handeln).
#' @param ... Bei \code{signal_combine}: Signal-Listen.
#' @param op \code{"and"} oder \code{"or"}.
#' @return \code{list(buy, sell)} mit logischen Vektoren.
#' @examples
#' x <- 100 * cumprod(1 + rnorm(1000, 2e-4, 0.01))
#' s <- signal_sma(x, 200, band = 1)
#' table(s$buy)
#' both <- signal_combine(signal_sma(x, 200), signal_volatility(x, 20, threshold = 25))
#' # In einer Strategie-Spezifikation:
#' spec <- list(strategy = create_strategy(A = asset_config("etf", "signal",
#'                signal_buy = "buy", signal_sell = "sell")),
#'              signal = function(df) signal_sma(df$A, 200))
#' @name signals
NULL

#' @rdname signals
#' @export
signal_sma <- function(x, n = 200, band = 0, lag = 0) {
  s <- .roll_mean(as.numeric(x), n)
  .sig_out(x >= s * (1 + band / 100), x < s * (1 - band / 100), lag)
}

#' @rdname signals
#' @export
signal_ema <- function(x, n = 200, band = 0, lag = 0) {
  s <- .ema(as.numeric(x), n)
  .sig_out(x >= s * (1 + band / 100), x < s * (1 - band / 100), lag)
}

#' @rdname signals
#' @export
signal_crossover <- function(x, fast = 50, slow = 200, type = c("sma", "ema"), band = 0, lag = 0) {
  type <- match.arg(type)
  if (fast >= slow) stop("fast muss kleiner als slow sein.")
  f <- if (type == "sma") .roll_mean(as.numeric(x), fast) else .ema(as.numeric(x), fast)
  s <- if (type == "sma") .roll_mean(as.numeric(x), slow) else .ema(as.numeric(x), slow)
  .sig_out(f >= s * (1 + band / 100), f < s * (1 - band / 100), lag)
}

#' @rdname signals
#' @export
signal_momentum <- function(x, n = 250, threshold = 0, band = 0, lag = 0) {
  x <- as.numeric(x); m <- length(x); n <- as.integer(n)
  r <- rep(NA_real_, m)
  if (n < m) r[(n + 1L):m] <- 100 * (x[(n + 1L):m] / x[1:(m - n)] - 1)
  .sig_out(r >= threshold + band, r < threshold - band, lag)
}

#' @rdname signals
#' @export
signal_drawdown <- function(x, sell_dd = 20, buy_dd = 10, window = NULL, lag = 0) {
  x <- as.numeric(x)
  if (buy_dd > sell_dd) stop("buy_dd darf nicht groesser als sell_dd sein.")
  peak <- if (is.null(window)) cummax(x) else {
    w <- as.integer(window); m <- length(x)
    vapply(seq_len(m), function(i) max(x[max(1L, i - w + 1L):i]), 0)
  }
  dd <- 100 * (1 - x / peak)
  .sig_out(dd < buy_dd, dd >= sell_dd, lag)
}

#' @rdname signals
#' @export
signal_volatility <- function(x, n = 20, threshold = 25, band = 0, ppy = 365.25, lag = 0) {
  x <- as.numeric(x); r <- c(NA, diff(log(x)))
  r0 <- r; r0[is.na(r0)] <- 0
  m1 <- .roll_mean(r0, n); m2 <- .roll_mean(r0^2, n)
  v <- 100 * sqrt(pmax(m2 - m1^2, 0) * n / max(n - 1, 1) * ppy)
  v[seq_len(min(n, length(v)))] <- NA
  .sig_out(v <= threshold - band, v > threshold + band, lag)
}

#' @rdname signals
#' @export
signal_combine <- function(..., op = c("and", "or")) {
  op <- match.arg(op)
  s <- list(...)
  if (!length(s)) stop("Keine Signale uebergeben.")
  B <- do.call(cbind, lapply(s, `[[`, "buy")); S <- do.call(cbind, lapply(s, `[[`, "sell"))
  if (op == "and") list(buy = apply(B, 1, all), sell = apply(S, 1, any))
  else list(buy = apply(B, 1, any), sell = apply(S, 1, all))
}
