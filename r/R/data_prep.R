# =============================================================================
#  data_prep.R  —  Daten- und Portfolio-Aufbereitung
# -----------------------------------------------------------------------------
#  align_series()        Quellen nach Datum zusammenfuehren, Kalender, Fuellung
#  check_series()        Pruefbericht: Luecken, Ausreisser, Spikes, Splits,
#                        stehende Kurse, Datumsprobleme
#  align_macro()         Makroreihen (Inflation, Zinsen, Spreads) mit
#                        Veroeffentlichungsverzug auf den Tageskalender legen
#  convert_currency()    Waehrungsumrechnung ueber eine Kursreihe
#  total_return_index()  Kurs- zu Total-Return-Index (Dividenden, Quellensteuer)
#  deflate()             reale Werte ueber einen Preisindex
#  splice_series()       Ketten aus mehreren Reihen (Proxy -> Index -> Fonds)
#  strategy_from_weights(), portfolio_template()  Portfolios aus Gewichten
#                        bzw. bekannten Vorlagen
#
#  Ziel: die Aufbereitung aus den Projektskripten 01-03 in wiederverwendbare,
#  getestete Bausteine ueberfuehren, deren Ergebnis direkt in simulation(),
#  backcast_fit(), bootstrap() und dependence_analysis() passt.
# =============================================================================

#' Eine Quelle in data.frame(date, ...) mit numerischen Spalten wandeln
#' @keywords internal
.dp_frame <- function(x, name) {
  if (is.numeric(x) && !is.null(names(x))) x <- data.frame(date = as.Date(names(x)), value = unname(x))
  if (!is.data.frame(x)) stop(sprintf("'%s' muss ein data.frame mit Spalte 'date' sein.", name))
  dcol <- if ("date" %in% names(x)) "date" else names(x)[1]
  num <- setdiff(names(x)[vapply(x, is.numeric, TRUE)], dcol)
  if (!length(num)) stop(sprintf("'%s': keine numerische Spalte.", name))
  out <- data.frame(date = as.Date(x[[dcol]]), x[num], check.names = FALSE)
  if (length(num) == 1L) names(out)[2] <- name
  out <- out[!is.na(out$date), , drop = FALSE]
  out <- out[order(out$date), , drop = FALSE]
  dup <- duplicated(out$date, fromLast = TRUE)
  if (any(dup)) { message(sprintf("Hinweis: '%s' hat %d doppelte Daten; der letzte Wert je Datum wird verwendet.", name, sum(dup)))
                  out <- out[!dup, , drop = FALSE] }
  out
}

#' Datenquellen nach Datum zusammenfuehren
#'
#' Fuehrt Kursreihen aus verschiedenen Quellen auf einen gemeinsamen Kalender
#' zusammen. Fuer [simulation()] ist ein lueckenloser Kalendertags-Kalender
#' ueblich (Wochenenden und Feiertage per LOCF); unterschiedliche
#' Boersenkalender (z. B. US- und EU-Feiertage) werden so ohne Zeilenverlust
#' vereinheitlicht.
#'
#' @param ... Benannte Quellen: \code{data.frame(date, value)} (Wertspalte wird
#'   nach dem Argument benannt), \code{data.frame(date, A, B, ...)} (Spalten
#'   bleiben erhalten) oder benannte Vektoren mit Datumsnamen.
#' @param calendar \code{"day"} (alle Kalendertage), \code{"union"} (alle
#'   Daten, an denen mindestens eine Quelle notiert) oder \code{"intersect"}
#'   (nur gemeinsame Handelstage).
#' @param range \code{"common"} (vom spaetesten Start bis zum fruehesten Ende)
#'   oder \code{"all"} (gesamter Zeitraum; ausserhalb einer Reihe NA).
#' @param fill \code{"locf"}, \code{"linear"} oder \code{"none"}. Gefuellt
#'   wird nur innerhalb der Laufzeit einer Reihe.
#' @param max_gap Laengere Luecken (Kalendertage) bleiben NA (mit Hinweis).
#' @param start,end Optional Zeitraum begrenzen.
#' @return data.frame(date, ...) mit Attribut \code{filled} (logische Matrix,
#'   TRUE = gefuellter Wert).
#' @examples
#' a <- data.frame(date = as.Date("2024-01-01") + c(0, 1, 2, 5), value = c(100, 101, 102, 103))
#' b <- data.frame(date = as.Date("2024-01-02") + 0:5, value = 50 + 0:5)
#' align_series(us = a, eu = b)
#' @export
align_series <- function(..., calendar = c("day", "union", "intersect"), range = c("common", "all"),
                         fill = c("locf", "linear", "none"), max_gap = Inf, start = NULL, end = NULL) {
  calendar <- match.arg(calendar); range <- match.arg(range); fill <- match.arg(fill)
  src <- list(...)
  if (!length(src) || is.null(names(src)) || any(names(src) == "")) stop("align_series: Quellen benennen, z. B. align_series(us = df1, eu = df2).")
  fr <- Map(.dp_frame, src, names(src))
  first <- do.call(c, lapply(fr, function(f) f$date[1])); last <- do.call(c, lapply(fr, function(f) f$date[nrow(f)]))
  lo <- if (range == "common") max(first) else min(first); hi <- if (range == "common") min(last) else max(last)
  if (!is.null(start)) lo <- max(lo, as.Date(start)); if (!is.null(end)) hi <- min(hi, as.Date(end))
  if (lo > hi) stop("align_series: Die Quellen ueberlappen sich nicht.")
  dates <- switch(calendar,
    day = seq.Date(lo, hi, by = "day"),
    union = sort(unique(do.call(c, lapply(fr, `[[`, "date")))),
    intersect = Reduce(function(a, b) a[a %in% b], lapply(fr, `[[`, "date")))
  dates <- dates[dates >= lo & dates <= hi]
  out <- data.frame(date = dates)
  filled <- list()
  for (f in fr) for (k in setdiff(names(f), "date")) {
    if (k %in% names(out)) stop(sprintf("align_series: Spaltenname '%s' kommt mehrfach vor.", k))
    v <- f[[k]][match(as.numeric(dates), as.numeric(f$date))]
    obs <- !is.na(v)
    in_life <- dates >= f$date[1] & dates <= f$date[nrow(f)]
    if (fill != "none" && any(obs)) {
      w <- .fill_na(v, fill, keep_leading = TRUE)
      w[!in_life] <- NA
      if (is.finite(max_gap)) {
        oi <- which(obs); gd <- diff(as.numeric(dates[oi]))
        long <- which(gd > max_gap & diff(oi) > 1L)
        for (j in long) w[(oi[j] + 1L):(oi[j + 1L] - 1L)] <- NA
        if (length(long)) message(sprintf("Hinweis: '%s': %d Luecken > %g Tage bleiben NA.", k, length(long), max_gap))
      }
      v <- w
    }
    out[[k]] <- v
    filled[[k]] <- !obs & !is.na(v)
  }
  attr(out, "filled") <- do.call(cbind, filled)
  out
}

#' Kursreihen pruefen
#'
#' Erstellt einen Pruefbericht fuer Kursreihen: Laufzeit, fehlende Werte,
#' Datumsprobleme, Spruenge, wahrscheinliche Splits (Sprung nahe einem
#' ganzzahligen Verhaeltnis ohne Ruecklauf), Spikes (Sprung mit sofortigem
#' Ruecklauf, typischer Datenfehler), nicht positive Werte und stehende Kurse.
#'
#' @param data data.frame mit Spalte \code{date} und Kursspalten.
#' @param columns Zu pruefende Spalten (Standard: alle numerischen).
#' @param jump Sprungschwelle in Prozent (Tagesveraenderung).
#' @param stale Mindestlaenge (Zeilen) einer Folge unveraenderter Werte, die
#'   gemeldet wird (bei Kalendertagsdaten sind 2-4 Tage normal).
#' @param revert Anteil des Ruecklaufs am Folgetag, ab dem ein Sprung als
#'   Spike gilt.
#' @return Objekt der Klasse \code{SimLevDataCheck} mit \code{summary}
#'   (je Spalte) und \code{issues} (je Fund: Spalte, Datum, Art, Wert).
#' @export
check_series <- function(data, columns = NULL, jump = 20, stale = 10, revert = 0.8) {
  if (!is.data.frame(data) || !"date" %in% names(data)) stop("check_series: data.frame mit Spalte 'date' erwartet.")
  d <- as.Date(data$date)
  columns <- columns %||% setdiff(names(data)[vapply(data, is.numeric, TRUE)], "date")
  issues <- list()
  add <- function(col, i, type, value, info = NA_real_)
    issues[[length(issues) + 1L]] <<- data.frame(column = col, date = d[i], type = type, value = value, info = info,
                                                 stringsAsFactors = FALSE)
  if (any(duplicated(d))) for (i in which(duplicated(d))) add("date", i, "doppeltes Datum", NA)
  if (is.unsorted(d)) add("date", which(diff(as.numeric(d)) < 0)[1] + 1L, "Datum nicht sortiert", NA)
  dg <- diff(as.numeric(d)); big <- which(dg > 5)
  for (i in big) add("date", i + 1L, "Kalenderluecke (Tage)", dg[i])
  summ <- lapply(columns, function(k) {
    v <- as.numeric(data[[k]]); ok <- which(!is.na(v))
    if (!length(ok)) return(data.frame(column = k, start = NA, end = NA, n = 0L, missing = length(v), jumps = 0L,
                                       spikes = 0L, splits = 0L, stale_max = 0L, nonpositive = 0L))
    inner <- ok[1]:ok[length(ok)]
    miss <- sum(is.na(v[inner]))
    np <- which(v <= 0); for (i in utils::head(np, 20)) add(k, i, "Wert <= 0", v[i])
    x <- v[ok]; r <- x[-1] / x[-length(x)] - 1; ri <- ok[-1]
    J <- which(is.finite(r) & abs(r) > jump / 100)
    n_spike <- n_split <- 0L; skip <- integer(0)
    for (j in J) {
      if (j %in% skip) next
      nxt <- if (j < length(r)) r[j + 1] else NA
      ratio <- x[j] / x[j + 1]; cand <- c(2:10, 1 / (2:10))
      near <- cand[which.min(abs(log(ratio / cand)))]
      if (!is.na(nxt) && sign(nxt) != sign(r[j]) && abs(log1p(nxt)) >= revert * abs(log1p(r[j]))) {
        n_spike <- n_spike + 1L; skip <- c(skip, j + 1L); add(k, ri[j], "Spike (Ruecklauf am Folgetag)", v[ri[j]], 100 * r[j])
      } else if (abs(log(ratio / near)) < 0.02) {
        n_split <- n_split + 1L; add(k, ri[j], sprintf("moeglicher Split (Verhaeltnis %s)", if (near >= 1) sprintf("%g:1", near) else sprintf("1:%g", 1 / near)),
                                    v[ri[j]], 100 * r[j])
      } else add(k, ri[j], "Sprung", v[ri[j]], 100 * r[j])
    }
    rl <- rle(diff(x) == 0); runs <- rl$lengths[rl$values]
    smax <- if (length(runs)) max(runs) + 1L else 1L
    if (length(runs)) {
      ends <- cumsum(rl$lengths)[rl$values]; long <- which(runs + 1L >= stale)
      for (q in utils::head(long, 20)) add(k, ok[ends[q] - runs[q] + 1L], "stehender Kurs (Zeilen)", x[ends[q]], runs[q] + 1L)
    }
    data.frame(column = k, start = d[ok[1]], end = d[ok[length(ok)]], n = length(ok), missing = miss,
               jumps = length(setdiff(J, skip)), spikes = n_spike, splits = n_split, stale_max = smax, nonpositive = length(np))
  })
  S <- do.call(rbind, summ)
  I <- if (length(issues)) do.call(rbind, issues) else data.frame(column = character(0), date = as.Date(character(0)),
                                                                   type = character(0), value = numeric(0), info = numeric(0))
  structure(list(summary = S, issues = I, settings = c(jump = jump, stale = stale, revert = revert)), class = "SimLevDataCheck")
}

#' @export
print.SimLevDataCheck <- function(x, max_issues = 25L, ...) {
  cat("SimLev-Datenpruefung\n\n")
  print(x$summary, row.names = FALSE)
  n <- nrow(x$issues)
  if (!n) { cat("\nKeine Auffaelligkeiten.\n"); return(invisible(x)) }
  cat(sprintf("\n%d Auffaelligkeiten%s:\n", n, if (n > max_issues) sprintf(" (erste %d)", max_issues) else ""))
  y <- utils::head(x$issues, max_issues)
  y$info <- ifelse(is.na(y$info), "", formatC(y$info, digits = 2, format = "f"))
  print(y, row.names = FALSE)
  invisible(x)
}

#' Makroreihen mit Veroeffentlichungsverzug auf den Tageskalender legen
#'
#' Ordnet niederfrequente Reihen (Inflation, Leitzins, Zinsstruktur,
#' Arbeitslosigkeit, ...) einem Tageskalender zu, und zwar so, wie sie zum
#' jeweiligen Tag bekannt waren: Ein Wert fuer den Referenzmonat Januar, der
#' Mitte Februar veroeffentlicht wird, gilt erst ab Mitte Februar. Ohne diesen
#' Verzug enthalten bedingte Analysen und Signale Informationen aus der
#' Zukunft.
#'
#' @param data Datumsvektor oder data.frame mit Spalte \code{date}.
#' @param macro \code{data.frame(date, value)}; \code{date} ist der
#'   Referenzzeitpunkt (z. B. Monatsanfang).
#' @param name Spaltenname, wenn \code{data} ein data.frame ist.
#' @param lag Veroeffentlichungsverzug.
#' @param lag_unit \code{"day"} oder \code{"month"}.
#' @param transform \code{"level"}, \code{"yoy"} (Veraenderung gegen Vorjahr in
#'   Prozent), \code{"mom"} (gegen Vorperiode in Prozent), \code{"diff"}
#'   (absolute Differenz zur Vorperiode, z. B. Zinsaenderung) oder
#'   \code{"yoy_diff"} (absolute Differenz zum Vorjahr).
#' @param periods Perioden je Jahr der Makroreihe (Standard: aus dem
#'   Datumsabstand geschaetzt, z. B. 12 fuer Monatsdaten).
#' @return Bei Datumsvektor ein numerischer Vektor, sonst \code{data} mit
#'   neuer Spalte \code{name}.
#' @examples
#' cpi <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "month", length.out = 36),
#'                   value = 100 * 1.002^(0:35))
#' d <- data.frame(date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = 400))
#' d <- align_macro(d, cpi, "inflation", lag = 45, transform = "yoy")
#' head(d[!is.na(d$inflation), ], 3)
#' @export
align_macro <- function(data, macro, name = "macro", lag = 0, lag_unit = c("day", "month"),
                        transform = c("level", "yoy", "mom", "diff", "yoy_diff"), periods = NULL) {
  lag_unit <- match.arg(lag_unit); transform <- match.arg(transform)
  m <- .dp_frame(macro, "macro"); v <- m[[2]]; md <- m$date
  if (is.null(periods)) {
    sp <- stats::median(diff(as.numeric(md)))
    periods <- if (sp >= 300) 1 else if (sp >= 80) 4 else if (sp >= 25) 12 else if (sp >= 6) 52 else 252
  }
  p <- as.integer(periods); k <- length(v)
  shift <- function(h) c(rep(NA_real_, min(h, k)), v[seq_len(max(k - h, 0))])
  v <- switch(transform, level = v, yoy = 100 * (v / shift(p) - 1), mom = 100 * (v / shift(1) - 1),
              diff = v - shift(1), yoy_diff = v - shift(p))
  avail <- if (lag_unit == "day" || lag == 0) md + if (lag_unit == "day") lag else 0 else
    do.call(c, lapply(md, function(x) seq.Date(x, by = sprintf("%d months", as.integer(lag)), length.out = 2)[2]))
  dates <- if (is.data.frame(data)) as.Date(data$date) else as.Date(data)
  o <- order(avail); avail <- avail[o]; v <- v[o]
  j <- findInterval(as.numeric(dates), as.numeric(avail))
  out <- ifelse(j > 0, v[pmax(j, 1L)], NA_real_)
  if (is.data.frame(data)) { data[[name]] <- out; return(data) }
  out
}

#' Waehrung umrechnen
#'
#' @param data data.frame mit Spalte \code{date}.
#' @param columns Umzurechnende Spalten.
#' @param fx Wechselkurs: Spaltenname, \code{data.frame(date, value)}
#'   (Stufenfunktion, LOCF) oder Skalar.
#' @param method \code{"divide"} (Kurs als Fremdwaehrung je Zielwaehrung, z. B.
#'   USD-Index mit EURUSD = USD je EUR in EUR umrechnen) oder
#'   \code{"multiply"}.
#' @param suffix Optional Endung fuer neue Spalten (Standard: ueberschreiben).
#' @return \code{data} mit umgerechneten Spalten.
#' @export
convert_currency <- function(data, columns, fx, method = c("divide", "multiply"), suffix = NULL) {
  method <- match.arg(method)
  f <- .resolve_series(fx, data, "fx")
  for (k in columns) {
    nm <- if (is.null(suffix)) k else paste0(k, suffix)
    data[[nm]] <- if (method == "divide") as.numeric(data[[k]]) / f else as.numeric(data[[k]]) * f
  }
  data
}

#' Total-Return-Index aus Kursindex und Ausschuettungen
#'
#' \deqn{r_t = \frac{P_t + D_t (1 - w)}{P_{t-1}} - 1 + \frac{y_t}{100}(1-w)\frac{\Delta t}{365.25}}
#' mit Ausschuettung je Anteil \eqn{D_t} am Ex-Tag, Quellensteuer \eqn{w} und
#' alternativ laufend aufgezinster Dividendenrendite \eqn{y_t} (Prozent p. a.).
#'
#' @param price Kursreihe (numerisch).
#' @param dividends Ausschuettung je Anteil (gleiche Laenge, 0/NA an Tagen ohne).
#' @param yield Dividendenrendite in Prozent p. a. (Skalar oder Vektor), als
#'   Alternative zu \code{dividends}.
#' @param withholding Quellensteuer in Prozent (z. B. 15).
#' @param dates Datum (fuer \eqn{\Delta t}; Standard: 1 Tag je Zeile).
#' @param start Startwert (Standard: erster Kurs).
#' @return numerischer Indexvektor.
#' @export
total_return_index <- function(price, dividends = NULL, yield = NULL, withholding = 0, dates = NULL, start = NULL) {
  p <- as.numeric(price); n <- length(p); w <- withholding / 100
  if (anyNA(p)) p <- .fill_na(p, "locf")
  D <- if (is.null(dividends)) rep(0, n) else { x <- as.numeric(dividends); x[is.na(x)] <- 0; x }
  y <- if (is.null(yield)) rep(0, n) else rep_len(as.numeric(yield), n)
  dt <- if (is.null(dates)) rep(1, n) else c(0, diff(as.numeric(as.Date(dates))))
  r <- c(0, (p[-1] + D[-1] * (1 - w)) / p[-n] - 1 + y[-1] / 100 * (1 - w) * dt[-1] / 365.25)
  (start %||% p[1]) * cumprod(1 + r)
}

#' Reale Werte ueber einen Preisindex
#'
#' @param data data.frame mit Spalte \code{date}.
#' @param columns Spalten, die deflationiert werden.
#' @param cpi Preisindex-Niveau: Spaltenname oder \code{data.frame(date, value)}
#'   (z. B. mit [align_macro()] und Veroeffentlichungsverzug vorbereitet).
#' @param base_date Bezugsdatum (Standard: erstes Datum), an dem real = nominal.
#' @param suffix Endung fuer neue Spalten (Standard \code{"_real"}).
#' @return \code{data} mit realen Spalten.
#' @export
deflate <- function(data, columns, cpi, base_date = NULL, suffix = "_real") {
  c0 <- .resolve_series(cpi, data, "cpi")
  b <- if (is.null(base_date)) 1L else which.min(abs(as.numeric(as.Date(data$date) - as.Date(base_date))))
  for (k in columns) data[[paste0(k, suffix)]] <- as.numeric(data[[k]]) / c0 * c0[b]
  data
}

#' Reihen verketten (Proxy -> Index -> Fonds)
#'
#' Verbindet mehrere Reihen renditebasiert zu einer langen Historie. Die erste
#' Reihe hat Vorrang: Wo sie vorliegt, wird sie unveraendert uebernommen. Davor
#' (und in ihren Luecken) werden die Tagesrenditen der naechsten verfuegbaren
#' Reihe verkettet, usw. Typisch: Fonds, dann zurueckgerechneter Fonds aus
#' [backcast()], dann ein Proxy-Index.
#'
#' @param ... Benannte Reihen in Prioritaetsreihenfolge: Spalten eines
#'   gemeinsamen data.frames (als Vektoren, dann \code{dates} angeben) oder
#'   \code{data.frame(date, value)} (werden mit [align_series()] auf
#'   Kalendertage gelegt).
#' @param dates Datum, wenn Vektoren uebergeben werden.
#' @return data.frame(date, value, source); \code{source} nennt die Reihe,
#'   deren Rendite vom Vortag auf diesen Tag verwendet wurde.
#' @export
splice_series <- function(..., dates = NULL) {
  src <- list(...)
  if (length(src) < 2 || is.null(names(src)) || any(names(src) == "")) stop("splice_series: mindestens zwei benannte Reihen.")
  if (all(vapply(src, is.data.frame, TRUE))) {
    al <- do.call(align_series, c(src, list(range = "all")))
    dates <- al$date; V <- as.matrix(al[, names(src)])
  } else {
    if (is.null(dates)) stop("splice_series: 'dates' angeben, wenn Vektoren uebergeben werden.")
    V <- do.call(cbind, lapply(src, as.numeric)); colnames(V) <- names(src)
  }
  n <- nrow(V)
  Rm <- rbind(NA, V[-1, , drop = FALSE] / V[-n, , drop = FALSE] - 1)
  pick <- apply(Rm, 1, function(r) { j <- which(is.finite(r)); if (length(j)) j[1] else NA_integer_ })
  r <- Rm[cbind(seq_len(n), ifelse(is.na(pick), 1L, pick))]; r[is.na(pick)] <- NA
  p <- V[, 1]; a <- which(!is.na(p))[1]
  if (is.na(a)) stop("splice_series: Die erste Reihe hat keine Werte.")
  lv <- rep(NA_real_, n); lv[a] <- p[a]
  if (a < n) for (t in (a + 1L):n) lv[t] <- if (!is.na(p[t])) p[t] else if (!is.na(r[t])) lv[t - 1L] * (1 + r[t]) else lv[t - 1L]
  if (a > 1L) for (t in a:2L) { if (is.na(r[t])) break; lv[t - 1L] <- lv[t] / (1 + r[t]) }
  srcname <- ifelse(!is.na(p), names(src)[1], ifelse(is.na(pick), NA, names(src)[pmax(pick, 1L)]))
  srcname[is.na(lv)] <- NA
  data.frame(date = as.Date(dates), value = lv, source = srcname, stringsAsFactors = FALSE)
}

#' Strategie aus Gewichten
#'
#' @param weights Benannter Vektor Spaltenname -> Gewicht (Anteile, z. B.
#'   \code{c(world = 0.6, bonds = 0.4)}).
#' @param ... Weitere Argumente fuer [asset_config()], fuer alle Assets
#'   gleich (z. B. \code{asset_class}, \code{asset_spread}, \code{asset_bonus});
#'   Vektoren mit Namen werden je Asset zugeordnet.
#' @return Strategie (\code{create_strategy()}).
#' @examples
#' strategy_from_weights(c(world = 0.6, bonds = 0.4), asset_spread = c(world = 0.1, bonds = 0.05))
#' @export
strategy_from_weights <- function(weights, ...) {
  if (is.null(names(weights)) || any(names(weights) == "")) stop("weights muss benannt sein.")
  if (any(weights <= 0)) stop("Gewichte muessen positiv sein (Assets mit Gewicht 0 weglassen).")
  if (sum(weights) > 1 + 1e-9) stop(sprintf("Gewichte summieren sich zu %.4f > 1.", sum(weights)))
  extra <- list(...)
  assets <- lapply(names(weights), function(nm) {
    a <- lapply(extra, function(v) if (!is.null(names(v)) && length(v) > 1) unname(v[nm]) else v)
    a <- a[!vapply(a, function(v) length(v) == 1 && is.na(v), TRUE)]
    do.call(asset_config, c(list(asset_share = unname(weights[nm])), a))
  })
  names(assets) <- names(weights)
  create_strategy(assets = assets)
}

#' Bekannte Portfolio-Vorlagen
#' @keywords internal
.portfolio_templates <- list(
  "60_40"           = c(stocks = 0.60, bonds = 0.40),
  permanent         = c(stocks = 0.25, long_bonds = 0.25, cash = 0.25, gold = 0.25),
  all_weather       = c(stocks = 0.30, long_bonds = 0.40, inter_bonds = 0.15, gold = 0.075, commodities = 0.075),
  golden_butterfly  = c(stocks = 0.20, small_value = 0.20, long_bonds = 0.20, short_bonds = 0.20, gold = 0.20),
  three_fund        = c(stocks = 0.48, intl_stocks = 0.32, bonds = 0.20),
  hfea              = c(stocks_3x = 0.55, long_bonds_3x = 0.45),
  stocks_gold       = c(stocks = 0.80, gold = 0.20)
)

#' Portfolio-Vorlagen
#'
#' Bekannte statische Allokationen mit Rollen-Namen (z. B. \code{stocks},
#' \code{long_bonds}, \code{gold}). Ueber \code{map} werden die Rollen den
#' Spalten des Datensatzes zugeordnet. Die Vorlagen sind Ausgangspunkte zum
#' Vergleich, keine Empfehlungen.
#'
#' \tabular{ll}{
#'   \code{60_40} \tab Aktien 60, Anleihen 40 \cr
#'   \code{permanent} \tab Permanent Portfolio (H. Browne): je 25 Aktien, lange Anleihen, Geldmarkt, Gold \cr
#'   \code{all_weather} \tab vereinfachtes All Weather: 30/40/15/7.5/7.5 \cr
#'   \code{golden_butterfly} \tab je 20 Aktien, Small Value, lange und kurze Anleihen, Gold \cr
#'   \code{three_fund} \tab Aktien Heimat 48, international 32, Anleihen 20 \cr
#'   \code{hfea} \tab 55 3x-Aktien, 45 3x-lange Anleihen \cr
#'   \code{stocks_gold} \tab Aktien 80, Gold 20
#' }
#'
#' @param name Vorlage (siehe oben); \code{portfolio_templates()} listet alle.
#' @param map Benannter Vektor Rolle -> Spaltenname (fehlende Rollen behalten
#'   ihren Namen).
#' @param ... Weitere Argumente fuer [strategy_from_weights()].
#' @return \code{portfolio_template}: Strategie; \code{portfolio_templates}:
#'   data.frame (Vorlage, Rolle, Gewicht).
#' @examples
#' portfolio_template("permanent", map = c(stocks = "msci_world", long_bonds = "bund_10y",
#'                                         cash = "geldmarkt", gold = "gold_eur"))
#' @export
portfolio_template <- function(name, map = NULL, ...) {
  w <- .portfolio_templates[[name]]
  if (is.null(w)) stop(sprintf("Unbekannte Vorlage '%s'. Verfuegbar: %s", name, paste(names(.portfolio_templates), collapse = ", ")))
  if (!is.null(map)) names(w) <- ifelse(names(w) %in% names(map), map[names(w)], names(w))
  strategy_from_weights(w, ...)
}

#' @rdname portfolio_template
#' @export
portfolio_templates <- function() {
  do.call(rbind, lapply(names(.portfolio_templates), function(n)
    data.frame(template = n, role = names(.portfolio_templates[[n]]), weight = unname(.portfolio_templates[[n]]))))
}
