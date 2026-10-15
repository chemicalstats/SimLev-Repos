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

#' Rollierender Mittelwert (Fenster n, inklusive aktueller Zeile; NA nur fuer
#' Fenster, die einen fehlenden Wert enthalten)
#' @keywords internal
#' @noRd
.roll_mean <- function(x, n) .roll_mean_core(as.numeric(x), as.integer(n))   # Kern in C++ (kompensierte Summe)

#' Rollierende Varianz/Kovarianz (Populationsform, Zwei-Pass in C++)
#' @keywords internal
#' @noRd
.roll_var <- function(x, n) { x <- as.numeric(x); .roll_cov_core(x, x, as.integer(n)) }
#' Rollierende Kovarianz (Populationsform, Zwei-Pass in C++)
#' @keywords internal
#' @noRd
.roll_cov <- function(x, y, n) .roll_cov_core(as.numeric(x), as.numeric(y), as.integer(n))

#' Exponentieller gleitender Durchschnitt (Start mit SMA der ersten n Werte)
#' @keywords internal
#' @noRd
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
#' @noRd
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
#' erwarten: Die Elemente \code{buy} und \code{sell} werden dort als
#' gleichnamige Spalten an den Datensatz angehaengt. Fuer [simulation()]
#' haengt man sie selbst an und nennt sie in [asset_config()]
#' (\code{action_type = "signal"}, \code{signal_buy}, \code{signal_sell});
#' fuer [tactical_rules()] lassen sie sich direkt als Bedingung verwenden.
#'
#' Eingabe ist ein numerischer Vektor mit Kursniveaus (keine Renditen), z. B.
#' eine Spalte aus [align_series()]. Alle Fenster (\code{n}, \code{fast},
#' \code{slow}, \code{window}, \code{lag}) zaehlen in Zeilen der Daten,
#' bei Kalendertagsdaten (Wochenenden per LOCF) also in Kalendertagen, bei
#' Handelstagsdaten in Handelstagen. Solange ein Fenster noch nicht gefuellt
#' ist, sind beide Signale \code{FALSE} (ausser bei \code{signal_drawdown},
#' das anfangs das Hoch der bisherigen Zeilen verwendet). \code{x} sollte
#' keine NA enthalten: Bei Durchschnitten liefern Fenster mit NA kein
#' Signal, beim exponentiellen Durchschnitt auch alle folgenden Zeilen; bei
#' \code{signal_drawdown} nur die Zeile mit NA (das Hoch wird ohne sie
#' fortgefuehrt).
#'
#' \code{band} wirkt als Hysterese: Zwischen Kauf- und Verkaufsschwelle sind
#' beide Signale \code{FALSE}, der Zustand in [simulation()] bzw.
#' [signal_state()] bleibt dann unveraendert. Bei Durchschnitten
#' (\code{signal_sma}, \code{signal_ema}, \code{signal_crossover}) ist
#' \code{band} relativ zum Durchschnitt in Prozent, bei
#' \code{signal_momentum} und \code{signal_volatility} ein Abstand in
#' Prozentpunkten zu \code{threshold}.
#'
#' \describe{
#'   \item{signal_sma}{Kurs ueber/unter dem einfachen gleitenden Durchschnitt
#'     der letzten \code{n} Zeilen (einschliesslich der aktuellen): Kauf ab
#'     \code{SMA * (1 + band/100)}, Verkauf unter \code{SMA * (1 - band/100)},
#'     dazwischen bleibt der Zustand.}
#'   \item{signal_ema}{Wie \code{signal_sma} mit exponentiellem Durchschnitt
#'     (Glaettung \eqn{2 / (n + 1)}, Start mit dem einfachen Mittel der ersten
#'     \code{n} Werte).}
#'   \item{signal_crossover}{Schneller ueber langsamem Durchschnitt: Kauf,
#'     wenn der schnelle mindestens das \code{(1 + band/100)}-fache des
#'     langsamen erreicht, Verkauf unter dem \code{(1 - band/100)}-fachen.}
#'   \item{signal_momentum}{Rendite ueber \code{n} Zeilen in Prozent: Kauf ab
#'     \code{threshold + band}, Verkauf unter \code{threshold - band}.}
#'   \item{signal_drawdown}{Verkauf ab \code{sell_dd} Prozent unter dem
#'     (rollierenden) Hoch, Kauf (Wiedereinstieg), solange der Abstand unter
#'     \code{buy_dd} Prozent liegt; dazwischen bleibt der Zustand.}
#'   \item{signal_volatility}{Realisierte Volatilitaet der Log-Renditen ueber
#'     \code{n} Zeilen, annualisiert mit \code{ppy}, in Prozent p. a.: Kauf bis
#'     \code{threshold - band}, Verkauf ueber \code{threshold + band}.}
#'   \item{signal_combine}{Verknuepft Signale: \code{"and"} kauft nur, wenn alle
#'     kaufen, und verkauft, sobald eines verkauft; \code{"or"} kauft, sobald
#'     eines kauft, und verkauft nur, wenn alle verkaufen.}
#' }
#'
#' @param x Numerischer Vektor mit Kursniveaus (z. B. \code{df$eu}).
#' @param n Fensterlaenge in Zeilen (Standard: 200 bei \code{signal_sma}
#'   und \code{signal_ema}, 250 bei \code{signal_momentum}, 20 bei
#'   \code{signal_volatility}).
#' @param fast,slow Fensterlaengen in Zeilen fuer den schnellen und den
#'   langsamen Durchschnitt (Standard 50 und 200; \code{fast < slow}).
#' @param band Hysterese-Band (Standard 0 = keins): bei Durchschnitten in
#'   Prozent des Durchschnitts (1 = 1 %), bei \code{signal_momentum} und
#'   \code{signal_volatility} in Prozentpunkten um \code{threshold}.
#' @param threshold Schwelle in Prozent: bei \code{signal_momentum} fuer die
#'   Rendite ueber \code{n} Zeilen (Standard 0), bei
#'   \code{signal_volatility} fuer die Volatilitaet in Prozent p. a.
#'   (Standard 25).
#' @param sell_dd,buy_dd Abstand zum Hoch in Prozent (positiv, 20 = 20 %
#'   unter dem Hoch); \code{buy_dd} darf nicht groesser als \code{sell_dd}
#'   sein (Standard 20 und 10).
#' @param window Fenster in Zeilen fuer das rollierende Hoch (Standard
#'   \code{NULL} = laufendes Hoch seit Beginn).
#' @param type Art der Durchschnitte bei \code{signal_crossover}:
#'   \code{"sma"} (Standard) oder \code{"ema"}.
#' @param ppy Zeilen je Jahr fuer die Annualisierung der Volatilitaet
#'   (Standard 365.25 fuer Kalendertagsdaten; bei Handelstagsdaten z. B.
#'   252). Wird nicht aus den Daten ermittelt.
#' @param lag Verzoegerung der Signale in Zeilen (Standard 0; z. B. 1, um
#'   erst in der Folgezeile zu handeln). Die ersten \code{lag} Zeilen sind
#'   \code{FALSE}.
#' @param ... Bei \code{signal_combine}: Signal-Listen \code{list(buy, sell)}
#'   gleicher Laenge (sonst Fehler).
#' @param op Verknuepfung bei \code{signal_combine}: \code{"and"} (Standard)
#'   oder \code{"or"}.
#' @return \code{list(buy, sell)} mit logischen Vektoren der Laenge von
#'   \code{x} (NA als \code{FALSE}).
#' @seealso [signal_state()], [tactical_rules()], [signal_analysis()],
#'   [param_search()]
#' @examples
#' set.seed(1)
#' x <- 100 * cumprod(1 + rnorm(1000, 2e-4, 0.01))
#' s <- signal_sma(x, 200, band = 1)
#' table(s$buy)
#' both <- signal_combine(signal_sma(x, 200), signal_volatility(x, 20, threshold = 25))
#' # Direkt in simulation(): Signale als Spalten anhaengen
#' d <- data.frame(date = seq.Date(as.Date("2018-01-01"), by = "day", length.out = 1000), A = x)
#' s <- signal_sma(d$A, 200, band = 1, lag = 1)
#' d$buy <- s$buy; d$sell <- s$sell
#' res <- simulation(d, create_strategy(A = asset_config("etf", "signal",
#'                     signal_buy = "buy", signal_sell = "sell")))
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
  if (buy_dd > sell_dd) stop("buy_dd darf nicht gr\u00f6\u00dfer als sell_dd sein.")
  xp <- ifelse(is.na(x), -Inf, x)                              # NA unterbricht das Hoch nicht (nur die eigene Zeile ohne Signal)
  peak <- if (is.null(window)) cummax(xp) else {
    w <- as.integer(window); m <- length(x)
    vapply(seq_len(m), function(i) max(xp[max(1L, i - w + 1L):i]), 0)
  }
  dd <- 100 * (1 - x / peak)
  .sig_out(dd < buy_dd, dd >= sell_dd, lag)
}

#' @rdname signals
#' @export
signal_volatility <- function(x, n = 20, threshold = 25, band = 0, ppy = 365.25, lag = 0) {
  x <- as.numeric(x); r <- c(NA, diff(log(x)))
  r0 <- r; r0[is.na(r0)] <- 0
  v <- 100 * sqrt(pmax(.roll_var(r0, n), 0) * n / max(n - 1, 1) * ppy)
  v[seq_len(min(n, length(v)))] <- NA
  .sig_out(v <= threshold - band, v > threshold + band, lag)
}

#' @rdname signals
#' @export
signal_combine <- function(..., op = c("and", "or")) {
  op <- match.arg(op)
  s <- list(...)
  if (!length(s)) stop("Keine Signale \u00fcbergeben.")
  len <- vapply(s, function(z) length(z$buy), 1L)
  if (any(len != len[1]) || any(vapply(s, function(z) length(z$sell), 1L) != len))
    stop(sprintf("signal_combine: Signale haben unterschiedliche L\u00e4ngen (%s); alle aus derselben Kursreihe erzeugen.",
                 paste(len, collapse = ", ")))
  B <- do.call(cbind, lapply(s, `[[`, "buy")); S <- do.call(cbind, lapply(s, `[[`, "sell"))
  if (op == "and") list(buy = apply(B, 1, all), sell = apply(S, 1, any))
  else list(buy = apply(B, 1, any), sell = apply(S, 1, all))
}
