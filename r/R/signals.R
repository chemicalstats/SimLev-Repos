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
# seit 1.6.5 (CR2-V1-5, Entscheidung 189): fuehrende NA werden uebersprungen (Start mit dem SMA der ersten n
# vorhandenen Werte; bis 1.6.4 schaltete ein fehlender erster Kurs das Signal fuer die ganze Reihe ab)
.ema <- function(x, n) {
  m0 <- length(x); f <- which(!is.na(x))[1]
  if (!is.na(f) && f > 1L) { out <- rep(NA_real_, m0); out[f:m0] <- .ema(x[f:m0], n); return(out) }
  n <- as.integer(n); m <- length(x); out <- rep(NA_real_, m)
  if (n < 1L || n > m) return(out)
  a <- 2 / (n + 1)
  out[n] <- mean(x[1:n])
  if (n < m) out[(n + 1L):m] <- .sl_filter(a * x[(n + 1L):m], 1 - a, method = "recursive", init = out[n])
  out
}

# Hinweis bei fehlenden Kursen fuer den exponentiellen Durchschnitt (seit 1.6.5, CR2-V1-5): fuehrende NA werden
# uebersprungen, ein NA danach beendet den Durchschnitt (Warnung mit der ersten Zeile)
.sig_ema_na <- function(x, fn) {
  i <- which(is.na(x))
  if (length(i)) warning(chk_msg("b2.ema_na", fn, i[1]), call. = FALSE)
  invisible(NULL)
}

#' Eingaben der Signal-Bausteine pruefen (seit 1.6.4, B-009 bis B-012, B-016, B-024)
#'
#' x: numerischer Vektor (keine Matrix, keine Tabelle, kein Text, kein Faktor; leer erlaubt; ein Vektor nur aus NA
#' zaehlt als Zahlenvektor, Entscheidung 14). Fenster (n, fast, slow, window) eine einzelne endliche Zahl >= 1, lag
#' >= 0, jeweils hoechstens .Machine$integer.max; seit 1.6.4 ganze Zahlen (Entscheidungen 19 und 32; bis dahin wurden
#' gebrochene Werte abgeschnitten).
#' @keywords internal
#' @noRd
.sig_x <- function(x, fn) {
  chk_nofactor(x, fn, "x")   # Entscheidung 15
  ok <- is.null(dim(x)) && (is.numeric(x) || (is.logical(x) && all(is.na(x))))
  if (!ok) chk_stop("zahlen", fn, "x")
  invisible(x)
}
# seit 1.6.4 ganze Zahl (Entscheidungen 19, 32; bis 1.6.3 z. B. 20.7 auf 20 abgeschnitten)
.sig_win <- function(x, fn, arg, lo = 1, null_ok = FALSE) {
  chk_num1(x, fn, arg, lo = lo, hi = .Machine$integer.max, null_ok = null_ok)
  chk_int1(x, fn, arg, lo = lo, null_ok = null_ok)
}

#' Signale um k Zeilen verzoegern und NA bereinigen
#' @keywords internal
#' @noRd
.sig_out <- function(buy, sell, lag = 0L) {
  lag <- as.integer(lag)
  if (lag > 0L) {
    m <- length(buy)
    lag <- min(lag, m)   # seit 1.6.4 (B-024): lag >= Laenge ergibt nur FALSE (bis 1.6.3 R-Fehler, Python falsche Laenge)
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
#' (\code{trading = "signal"}, \code{signal_buy}, \code{signal_sell});
#' fuer [tactical_rules()] lassen sie sich direkt als Bedingung verwenden.
#'
#' Eingabe ist ein numerischer Vektor mit Kursniveaus (keine Renditen), z. B.
#' eine Spalte aus [series_align()]. Alle Fenster (\code{n}, \code{fast},
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
#' Eingaben (seit 1.6.4 geprueft): \code{x} ein numerischer Vektor (keine Matrix,
#' Tabelle, kein Text, Faktor oder Wahrheitswert; leer erlaubt); \code{n},
#' \code{fast}, \code{slow}, \code{window} je eine endliche Zahl \code{>= 1},
#' \code{lag >= 0} (seit 1.6.4 ganze Zahlen, gebrochene Werte sind ein Fehler; \code{lag} ab der
#' Laenge von \code{x} ergibt nur \code{FALSE}); \code{band >= 0};
#' \code{sell_dd}, \code{buy_dd} groesser 0 und hoechstens 100; bei
#' \code{signal_volatility} \code{threshold >= 0} und \code{ppy > 0}; bei
#' \code{signal_combine} \code{buy} und \code{sell} je TRUE/FALSE oder 0/1
#' (\code{NA} bleibt \code{NA}).
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
  fn <- "signal_sma"
  .sig_x(x, fn); .sig_win(n, fn, "n"); chk_num1(band, fn, "band", lo = 0); .sig_win(lag, fn, "lag", lo = 0)
  s <- .roll_mean(as.numeric(x), n)
  .sig_out(x >= s * (1 + band / 100), x < s * (1 - band / 100), lag)
}

#' @rdname signals
#' @export
signal_ema <- function(x, n = 200, band = 0, lag = 0) {
  fn <- "signal_ema"
  .sig_x(x, fn); .sig_win(n, fn, "n"); chk_num1(band, fn, "band", lo = 0); .sig_win(lag, fn, "lag", lo = 0)
  .sig_ema_na(x, fn)
  s <- .ema(as.numeric(x), n)
  .sig_out(x >= s * (1 + band / 100), x < s * (1 - band / 100), lag)
}

#' @rdname signals
#' @export
signal_crossover <- function(x, fast = 50, slow = 200, type = c("sma", "ema"), band = 0, lag = 0) {
  fn <- "signal_crossover"
  .sig_x(x, fn); .sig_win(fast, fn, "fast"); .sig_win(slow, fn, "slow")
  type <- match.arg(type)
  if (fast >= slow) stop(chk_msg("b2b.m_signal_crossover"))
  chk_num1(band, fn, "band", lo = 0); .sig_win(lag, fn, "lag", lo = 0)
  if (type == "ema") .sig_ema_na(x, fn)
  f <- if (type == "sma") .roll_mean(as.numeric(x), fast) else .ema(as.numeric(x), fast)
  s <- if (type == "sma") .roll_mean(as.numeric(x), slow) else .ema(as.numeric(x), slow)
  .sig_out(f >= s * (1 + band / 100), f < s * (1 - band / 100), lag)
}

#' @rdname signals
#' @export
signal_momentum <- function(x, n = 250, threshold = 0, band = 0, lag = 0) {
  fn <- "signal_momentum"
  .sig_x(x, fn); .sig_win(n, fn, "n"); chk_num1(threshold, fn, "threshold"); chk_num1(band, fn, "band", lo = 0)
  .sig_win(lag, fn, "lag", lo = 0)
  x <- as.numeric(x); m <- length(x); n <- as.integer(n)
  r <- rep(NA_real_, m)
  if (n < m) r[(n + 1L):m] <- 100 * (x[(n + 1L):m] / x[1:(m - n)] - 1)
  .sig_out(r >= threshold + band, r < threshold - band, lag)
}

#' @rdname signals
#' @export
signal_drawdown <- function(x, sell_dd = 20, buy_dd = 10, window = NULL, lag = 0) {
  fn <- "signal_drawdown"
  .sig_x(x, fn)
  chk_num1(sell_dd, fn, "sell_dd", lo = 0, lo_open = TRUE, hi = 100)
  chk_num1(buy_dd, fn, "buy_dd", lo = 0, lo_open = TRUE, hi = 100)
  .sig_win(window, fn, "window", null_ok = TRUE); .sig_win(lag, fn, "lag", lo = 0)
  x <- as.numeric(x)
  if (buy_dd > sell_dd) stop(chk_msg("b2b.m_signal_drawdown"))
  xp <- ifelse(is.na(x), -Inf, x)                              # NA unterbricht das Hoch nicht (nur die eigene Zeile ohne Signal)
  peak <- if (is.null(window)) cummax(xp) else {
    w <- as.integer(window); m <- length(x)
    # seit 1.6.3 gleitendes Maximum im Kern (roll_max_core, O(m); bei Gleichstand das erste Auftreten wie max());
    # Fenster < 1, NA oder mehrere Werte wie bisher
    if (length(w) == 1L && !is.na(w) && w >= 1L) .Call(C_roll_max_core, xp, w, 0L)
    else vapply(seq_len(m), function(i) max(xp[max(1L, i - w + 1L):i]), 0)
  }
  dd <- 100 * (1 - x / peak)
  .sig_out(dd < buy_dd, dd >= sell_dd, lag)
}

#' @rdname signals
#' @export
signal_volatility <- function(x, n = 20, threshold = 25, band = 0, ppy = 365.25, lag = 0) {
  fn <- "signal_volatility"
  # seit 1.6.5 (CR2-R-4): n >= 2 (Varianz eines Werts ist 0), Kurse > 0 (log)
  .sig_x(x, fn); .sig_win(n, fn, "n", lo = 2); chk_num1(threshold, fn, "threshold", lo = 0); chk_num1(band, fn, "band", lo = 0)
  chk_num1(ppy, fn, "ppy", lo = 0, lo_open = TRUE); .sig_win(lag, fn, "lag", lo = 0)
  x <- as.numeric(x)
  if (any(x <= 0, na.rm = TRUE)) chk_stop("b2.kurs_positiv", fn)
  if (!length(x)) return(list(buy = logical(0), sell = logical(0)))   # seit 1.6.4 (B-016): leer statt eines Phantomwerts
  r <- c(NA, diff(log(x)))
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
  if (!length(s)) stop(chk_msg("b2b.m_signal_combine"))
  # seit 1.6.4 (B-008, Entscheidung 1): je Signal eine Liste mit buy und sell, jeweils TRUE/FALSE oder 0/1 (NA
  # erlaubt, bleibt NA); 0/1 als Wahrheitswerte (bis 1.6.3 wandelte R Zahlen mit Warnung, Python las NaN und Text
  # als TRUE)
  sig_ok <- function(v) is.null(dim(v)) && (is.logical(v) || (is.numeric(v) && !is.factor(v) && all(is.na(v) | v == 0 | v == 1)))
  for (i in seq_along(s)) {
    z <- s[[i]]
    if (!is.list(z) || is.data.frame(z) || !all(c("buy", "sell") %in% names(z)) || !sig_ok(z$buy) || !sig_ok(z$sell))
      chk_stop("e1.signal", "signal_combine", i)
    if (is.numeric(z$buy)) s[[i]]$buy <- as.logical(z$buy)
    if (is.numeric(z$sell)) s[[i]]$sell <- as.logical(z$sell)
  }
  len <- vapply(s, function(z) length(z$buy), 1L)
  if (any(len != len[1]) || any(vapply(s, function(z) length(z$sell), 1L) != len))
    stop(chk_msg("b2b.m_sig_ok", paste(len, collapse = ", ")))
  bs <- lapply(s, `[[`, "buy"); ss <- lapply(s, `[[`, "sell")
  # seit 1.6.3 fuer reine logische Vektoren (wie aus den signal_*-Funktionen) elementweise mit & bzw. |: gleiche Werte
  # wie apply(, 1, all/any), auch mit NA; sonst (Zahlen, Attribute) wie bisher zeilenweise
  plain <- function(l) all(vapply(l, function(z) is.logical(z) && is.null(attributes(z)), TRUE))
  if (plain(bs) && plain(ss)) {
    if (op == "and") return(list(buy = Reduce(`&`, bs), sell = Reduce(`|`, ss)))
    return(list(buy = Reduce(`|`, bs), sell = Reduce(`&`, ss)))
  }
  B <- do.call(cbind, bs); S <- do.call(cbind, ss)
  if (op == "and") list(buy = apply(B, 1, all), sell = apply(S, 1, any))
  else list(buy = apply(B, 1, any), sell = apply(S, 1, all))
}
