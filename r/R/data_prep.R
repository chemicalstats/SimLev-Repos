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

#' Datumsangaben in Date umwandeln
#'
#' POSIXct/POSIXlt ergeben den Kalendertag in ihrer eigenen Zeitzone (nicht
#' UTC wie [as.Date()]), Text und Faktoren nur die Formate "JJJJ-MM-TT" und
#' "JJJJ/MM/TT" mit vierstelliger Jahreszahl am Anfang (jedes Jahr zulaessig;
#' so wird z. B. "31-12-2024" nicht als Jahr 31 gelesen); numerische Werte
#' werden abgelehnt. Mit \code{strict = TRUE} Fehler fuer nicht lesbare Werte,
#' sonst NA. Leere Eintraege ergeben NA.
#' @keywords internal
#' @noRd
.to_date <- function(x, what = "date", strict = TRUE) {
  if (inherits(x, "Date")) return(x)
  if (inherits(x, "POSIXt")) return(as.Date(format(x, "%Y-%m-%d")))
  if (is.factor(x)) x <- as.character(x)
  if (is.numeric(x)) stop(sprintf("%s: Datum ist numerisch (z. B. %s); erwartet Date, POSIXct oder Text 'JJJJ-MM-TT'.", what, format(x[1])))
  s <- trimws(as.character(x)); s[!is.na(s) & s == ""] <- NA
  d <- as.Date(s, format = "%Y-%m-%d"); i <- is.na(d) & !is.na(s)
  if (any(i)) d[i] <- as.Date(s[i], format = "%Y/%m/%d")
  bad <- which((is.na(d) | !grepl("^[0-9]{4}[-/]", s)) & !is.na(s))   # vierstellige Jahreszahl vorn (kein "TT-MM-JJJJ")
  if (length(bad) && strict)
    stop(sprintf("%s: %d Datumswerte nicht als 'JJJJ-MM-TT' lesbar (z. B. '%s'). Andere Formate vorher umwandeln, z. B. as.Date(x, format = \"%%d.%%m.%%Y\") f\u00fcr '31.12.2024' oder format = \"%%d-%%m-%%Y\".",
                 what, length(bad), s[bad[1]]))
  d[bad] <- NA
  d
}

#' Datum plus k Kalendermonate, auf das Monatsende begrenzt
#'
#' Wie in [momentum_score()]: Tag des Monats bleibt, wird aber auf den letzten
#' Tag des Zielmonats begrenzt (31.01. + 1 Monat = 28.02. bzw. 29.02.,
#' 29.02. + 12 Monate = 28.02.). \code{seq.Date(by = "k months")} laeuft
#' dagegen in den Folgemonat ueber (31.01. + 1 Monat = 02.03.). Vektorisiert
#' ueber \code{x} und \code{k} (ganze Zahlen, auch negativ).
#' @keywords internal
#' @noRd
.add_months <- function(x, k) {
  lt <- as.POSIXlt(as.Date(x)); m <- lt$mon + as.integer(k)
  y2 <- lt$year + 1900L + m %/% 12L; mo2 <- m %% 12L
  first <- as.Date(sprintf("%04d-%02d-01", y2, mo2 + 1L))
  nxt <- as.Date(sprintf("%04d-%02d-01", y2 + (mo2 + 1L) %/% 12L, (mo2 + 1L) %% 12L + 1L))
  first + pmin(lt$mday, as.integer(nxt - first)) - 1L
}

#' Text- oder Faktorspalten, die wie Zahlen aussehen (z. B. Kurse mit Dezimalkomma)
#' @keywords internal
#' @noRd
.num_text_cols <- function(x, exclude = character(0)) {
  cand <- setdiff(names(x)[vapply(x, function(v) is.character(v) || is.factor(v), TRUE)], exclude)
  cand[vapply(cand, function(k) {
    s <- trimws(as.character(x[[k]])); s <- s[!is.na(s) & s != ""]
    length(s) > 0 && mean(grepl("^[-+]?[0-9][0-9.,' ]*([eE][-+]?[0-9]+)?$", s) &
                            !grepl("^[0-9]{1,2}[.][0-9]{1,2}[.][0-9]{2,4}$", s)) >= 0.9
  }, TRUE)]
}

#' Fehlermeldung fuer Zahlen als Text
#' @keywords internal
#' @noRd
.num_text_stop <- function(x, cols, name) {
  ex <- trimws(as.character(x[[cols[1]]])); ex <- ex[!is.na(ex) & ex != ""]
  ex <- c(ex[grepl(",", ex)], ex)[1]                          # Beispiel moeglichst mit Komma
  stop(sprintf("'%s': Spalte %s enth\u00e4lt Zahlen als Text bzw. Faktor (z. B. '%s'), vermutlich mit Dezimalkomma. Vorher umwandeln, z. B. mit read.csv2() oder as.numeric(sub(\",\", \".\", x, fixed = TRUE)).",
               name, paste0("'", cols, "'", collapse = ", "), ex), call. = FALSE)
}

#' Eine Quelle in data.frame(date, ...) mit numerischen Spalten wandeln
#' @keywords internal
#' @noRd
.dp_frame <- function(x, name) {
  if (is.numeric(x) && !is.null(names(x))) x <- data.frame(date = .to_date(names(x), sprintf("'%s' (Namen)", name)), value = unname(x))
  if (!is.data.frame(x)) stop(sprintf("'%s' muss ein data.frame mit Spalte 'date' sein.", name))
  dcol <- if ("date" %in% names(x)) "date" else {
    dc <- names(x)[vapply(x, function(v) inherits(v, c("Date", "POSIXt")), TRUE)]   # Datumsspalte bevorzugt
    if (length(dc)) dc[1] else names(x)[1]
  }
  if (is.numeric(x[[dcol]]))
    stop(sprintf("'%s': keine Datumsspalte; Spalte '%s' ist numerisch (z. B. Zeilennummern aus write.csv). Spalte 'date' (Date oder 'JJJJ-MM-TT') angeben.", name, dcol))
  num <- setdiff(names(x)[vapply(x, is.numeric, TRUE)], dcol)
  rn <- num[num == "X" & vapply(num, function(k) isTRUE(all(x[[k]] == seq_len(nrow(x)))), TRUE)]
  if (length(rn) && length(num) > 1L) {
    message(sprintf("Hinweis: '%s': Spalte 'X' (Zeilennummern, z. B. aus write.csv) wird ignoriert.", name))
    num <- setdiff(num, rn)
  }
  txt <- .num_text_cols(x, dcol)
  if (length(txt)) .num_text_stop(x, txt, name)
  if (!length(num)) stop(sprintf("'%s': keine numerische Spalte.", name))
  out <- data.frame(date = .to_date(x[[dcol]], sprintf("'%s': Spalte '%s'", name, dcol)), x[num], check.names = FALSE)
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
#' Einstieg fuer eigene Daten: Fuehrt Kursreihen aus verschiedenen Quellen
#' (z. B. mit [utils::read.csv()] eingelesene Dateien) auf einen gemeinsamen
#' Kalender zusammen und liefert einen data.frame mit Spalte `date` (Klasse
#' Date) und je einer numerischen Spalte pro Reihe. Erwartet werden
#' Niveaus (Kurse, Indexstaende), keine Renditen: Luecken werden mit dem
#' letzten Kurs (LOCF) oder linear gefuellt, was nur fuer Niveaus sinnvoll
#' ist. Renditereihen vorher in einen Index umrechnen, z. B.
#' `100 * cumprod(1 + r)`.
#'
#' Mit `calendar = "day"` (Standard) entsteht ein lueckenloser
#' Kalendertags-Kalender: Wochenenden und Feiertage werden gefuellt, und
#' unterschiedliche Boersenkalender (z. B. US- und EU-Feiertage) werden ohne
#' Zeilenverlust vereinheitlicht. Das Ergebnis passt direkt in
#' [simulation()], [check_series()], [deep_analysis()] (je Reihe als
#' `data.frame(date, value)`) und die Gewichts-Erzeuger wie
#' [tactical_rules()]. [simulation()], [tactical_simulation()] und
#' [deep_analysis()] werten das Attribut `filled` aus: Ein Tag, an dem keine
#' Anlage der Strategie einen echten Kurs hat, gilt als aufgefuellt (kein
#' Handel, nicht in den Risikokennzahlen) - genau wie Kalendertage, die
#' [simulation()] bei Handelstagsdaten selbst per LOCF auffuellt.
#'
#' Je Quelle gilt: Fehlt eine Spalte `date`, wird die erste Spalte der Klasse
#' Date bzw. POSIXct als Datum verwendet, sonst die erste Spalte (eine
#' numerische erste Spalte, etwa Zeilennummern `X` aus [utils::write.csv()],
#' wird als Datum abgelehnt; eine Spalte `X` mit den Zeilennummern 1, 2, ...
#' wird neben weiteren Wertspalten mit Hinweis ignoriert). Zeichenketten
#' muessen das Format `"JJJJ-MM-TT"` haben; andere Formate wie
#' `"31.12.2024"` vorher mit dem Argument `format` von [as.Date()]
#' umwandeln, siehe Beispiel (nicht lesbare Daten und Texte ohne
#' vierstellige Jahreszahl am Anfang sind ein Fehler). POSIXct-Zeitstempel zaehlen mit dem Kalendertag in ihrer
#' eigenen Zeitzone. Uebernommen werden nur numerische Spalten; andere
#' Text-Spalten fallen weg, Text- oder Faktorspalten, die wie Zahlen
#' aussehen (etwa Kurse mit Dezimalkomma, als Text eingelesen), sind ein
#' Fehler. Zeilen ohne Datum werden entfernt, die Zeilen nach Datum
#' sortiert, bei doppeltem Datum gilt der letzte Wert (mit Hinweis).
#'
#' @param ... Benannte Quellen (Name = Spaltenname im Ergebnis):
#'   \code{data.frame(date, value)} mit genau einer numerischen Spalte (sie
#'   wird nach dem Argument benannt), \code{data.frame(date, A, B, ...)} mit
#'   mehreren numerischen Spalten (Spaltennamen bleiben erhalten und muessen
#'   ueber alle Quellen eindeutig sein) oder benannte numerische Vektoren mit
#'   Datumsnamen (\code{c("2024-01-02" = 100, ...)}).
#' @param calendar Zeilen des Ergebnisses: \code{"day"} (Standard; alle
#'   Kalendertage), \code{"union"} (alle Daten, an denen mindestens eine
#'   Quelle notiert) oder \code{"intersect"} (nur Daten, an denen alle
#'   Quellen notieren).
#' @param range Zeitraum: \code{"common"} (Standard; vom spaetesten Start bis
#'   zum fruehesten Ende aller Quellen) oder \code{"all"} (gesamter Zeitraum;
#'   ausserhalb der Laufzeit einer Reihe NA).
#' @param fill Fuellung fehlender Werte: \code{"locf"} (Standard; letzter
#'   Wert), \code{"linear"} (lineare Interpolation) oder \code{"none"}.
#'   Gefuellt wird nur innerhalb der Laufzeit einer Reihe (erstes bis letztes
#'   vorhandenes Datum).
#' @param max_gap Hoechste Luecke in Kalendertagen zwischen zwei vorhandenen
#'   Werten, die noch gefuellt wird; laengere Luecken bleiben NA (mit
#'   Hinweis). Standard \code{Inf} = alle Luecken fuellen.
#' @param start,end Optional Beginn und Ende des Zeitraums (Date oder
#'   \code{"JJJJ-MM-TT"}); \code{NULL} = durch \code{range} bestimmt.
#' @return data.frame mit Spalte \code{date} (Klasse Date) und je einer
#'   numerischen Spalte pro Reihe, mit Attribut \code{filled} (logische
#'   Matrix Zeilen x Reihen, TRUE = gefuellter Wert).
#' @seealso [check_series()] zur Pruefung, [splice_series()],
#'   [convert_currency()], [simulation()]
#' @examples
#' a <- data.frame(date = as.Date("2024-01-01") + c(0, 1, 2, 5), value = c(100, 101, 102, 103))
#' b <- data.frame(date = as.Date("2024-01-02") + 0:5, value = 50 + 0:5)
#' align_series(us = a, eu = b)
#'
#' # Eigene Daten: CSV mit Handelstagen (ohne Wochenenden), Datum als TT.MM.JJJJ
#' set.seed(1)
#' tage <- seq.Date(as.Date("2022-01-03"), by = "day", length.out = 730)
#' tage <- tage[!format(tage, "%u") %in% c("6", "7")]
#' csv <- file.path(tempdir(), "etf.csv")
#' write.csv(data.frame(Datum = format(tage, "%d.%m.%Y"),
#'                      Kurs = 100 * cumprod(1 + rnorm(length(tage), 3e-4, 0.01))),
#'           csv, row.names = FALSE)
#' roh <- read.csv(csv)
#' roh$Datum <- as.Date(roh$Datum, format = "%d.%m.%Y")
#' d <- align_series(etf = roh)    # erste Spalte = Datum, Wertspalte heisst "etf"
#' head(d, 4)
#' colSums(attr(d, "filled"))      # gefuellte Wochenendtage
#' res <- simulation(d, create_strategy(etf = asset_config("etf", "bnh")))
#' @export
align_series <- function(..., calendar = c("day", "union", "intersect"), range = c("common", "all"),
                         fill = c("locf", "linear", "none"), max_gap = Inf, start = NULL, end = NULL) {
  calendar <- match.arg(calendar); range <- match.arg(range); fill <- match.arg(fill)
  src <- list(...)
  if (!length(src) || is.null(names(src)) || any(names(src) == "")) stop("align_series: Quellen benennen, z. B. align_series(us = df1, eu = df2).")
  fr <- Map(.dp_frame, src, names(src))
  first <- do.call(c, lapply(fr, function(f) f$date[1])); last <- do.call(c, lapply(fr, function(f) f$date[nrow(f)]))
  lo <- if (range == "common") max(first) else min(first); hi <- if (range == "common") min(last) else max(last)
  if (!is.null(start)) lo <- max(lo, .to_date(start, "align_series: start")); if (!is.null(end)) hi <- min(hi, .to_date(end, "align_series: end"))
  if (lo > hi) stop("align_series: Die Quellen \u00fcberlappen sich nicht.")
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
        if (length(long)) message(sprintf("Hinweis: '%s': %d L\u00fccken > %g Tage bleiben NA.", k, length(long), max_gap))
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
#' Erstellt einen Pruefbericht fuer eigene Kursreihen, bevor sie in
#' [simulation()] oder die Analysefunktionen gehen. Erwartet wird ein
#' data.frame mit Spalte `date` und Kursspalten (Niveaus, keine Renditen),
#' z. B. aus [align_series()]. Gemeldet werden: fehlende oder nicht lesbare
#' Daten (z. B. Leerzeile am Dateiende), doppelte oder unsortierte
#' Daten, Kalenderluecken ueber 5 Tage, fehlende Werte innerhalb der
#' Laufzeit, Spruenge, wahrscheinliche Splits (Sprung nahe einem
#' ganzzahligen Verhaeltnis 2:1 bis 10:1 bzw. 1:2 bis 1:10, ohne Ruecklauf),
#' Spikes (Sprung mit sofortigem Ruecklauf, typischer Datenfehler), Werte
#' <= 0 und stehende Kurse. Die Funktion aendert die Daten nicht.
#'
#' Spruenge werden zwischen aufeinanderfolgenden vorhandenen Werten (NA
#' uebersprungen) gemessen, also je Zeile, nicht je Kalendertag, und nur
#' zwischen zwei positiven Werten; Werte <= 0 (z. B. eine Zinsreihe mit
#' negativen Saetzen) erscheinen nur als "Wert <= 0".
#'
#' @param data data.frame mit Spalte \code{date} (Date oder
#'   \code{"JJJJ-MM-TT"}) und Kursspalten.
#' @param columns Zeichenvektor der zu pruefenden Spalten (Standard
#'   \code{NULL} = alle numerischen Spalten ausser \code{date}).
#' @param jump Sprungschwelle in Prozent (20 = 20 %): Veraenderung zum
#'   vorigen vorhandenen Wert, ab der ein Sprung gemeldet wird.
#' @param stale Mindestlaenge in Zeilen einer Folge unveraenderter Werte, die
#'   als stehender Kurs gemeldet wird (bei Kalendertagsdaten sind 2-4 Zeilen
#'   ueber Wochenenden und Feiertage normal).
#' @param revert Ruecklauf am Folgetag als Anteil des Sprungs (0.8 = 80 %,
#'   gemessen in Log-Renditen), ab dem ein Sprung als Spike gilt.
#' @return Objekt der Klasse \code{SimLevDataCheck}, eine Liste mit
#'   \describe{
#'     \item{summary}{data.frame je Spalte: \code{column}, \code{start},
#'       \code{end} (erstes/letztes Datum mit Wert), \code{n} (Werte),
#'       \code{missing} (NA innerhalb der Laufzeit), \code{jumps} (alle
#'       Spruenge ueber \code{jump}, einschliesslich Spikes und Splits),
#'       \code{spikes}, \code{splits}, \code{stale_max} (laengste Folge
#'       gleicher Werte in Zeilen), \code{nonpositive} (Anzahl Werte <= 0).}
#'     \item{issues}{data.frame je Fund: \code{column}, \code{date},
#'       \code{type} (Art des Funds), \code{value} (Kurs) und \code{info}
#'       (bei Spruengen die Veraenderung in Prozent, bei Kalenderluecken die
#'       Tage, bei stehenden Kursen die Zeilen).}
#'     \item{settings}{benannter Vektor \code{jump}, \code{stale},
#'       \code{revert}.}
#'   }
#'   \code{print()} zeigt die Zusammenfassung und die ersten
#'   \code{max_issues} (Standard 25) Funde.
#' @seealso [align_series()], [splice_series()]
#' @examples
#' set.seed(1); n <- 400
#' d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n),
#'                 A = 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)))
#' d$A[100] <- d$A[100] * 1.5            # Ausreisser mit Ruecklauf (Spike)
#' d$A[300:n] <- d$A[300:n] / 2          # Split 2:1
#' d$A[200:215] <- d$A[200]              # stehender Kurs
#' chk <- check_series(d)
#' chk
#' chk$summary
#' @export
check_series <- function(data, columns = NULL, jump = 20, stale = 10, revert = 0.8) {
  if (!is.data.frame(data) || !"date" %in% names(data)) stop("check_series: data.frame mit Spalte 'date' erwartet.")
  d <- .to_date(data$date, "check_series: date", strict = FALSE)
  columns <- columns %||% setdiff(names(data)[vapply(data, is.numeric, TRUE)], "date")
  issues <- list()
  add <- function(col, i, type, value, info = NA_real_)
    issues[[length(issues) + 1L]] <<- data.frame(column = col, date = d[i], type = type, value = value, info = info,
                                                 stringsAsFactors = FALSE)
  for (i in utils::head(which(is.na(d)), 20)) add("date", i, sprintf("Datum fehlt oder nicht lesbar (Zeile %d)", i), NA)
  okd <- which(!is.na(d)); dd <- d[okd]                      # Datumspruefungen nur auf vorhandenen Daten
  if (any(duplicated(dd))) for (i in okd[duplicated(dd)]) add("date", i, "doppeltes Datum", NA)
  if (is.unsorted(dd)) add("date", okd[which(diff(as.numeric(dd)) < 0)[1] + 1L], "Datum nicht sortiert", NA)
  dg <- diff(as.numeric(dd)); big <- which(dg > 5)
  for (i in big) add("date", okd[i + 1L], "Kalenderl\u00fccke (Tage)", dg[i])
  summ <- lapply(columns, function(k) {
    v <- as.numeric(data[[k]]); ok <- which(!is.na(v))
    if (!length(ok)) return(data.frame(column = k, start = NA, end = NA, n = 0L, missing = length(v), jumps = 0L,
                                       spikes = 0L, splits = 0L, stale_max = 0L, nonpositive = 0L))
    inner <- ok[1]:ok[length(ok)]
    miss <- sum(is.na(v[inner]))
    np <- which(v <= 0); for (i in utils::head(np, 20)) add(k, i, "Wert <= 0", v[i])
    x <- v[ok]; r <- x[-1] / x[-length(x)] - 1; ri <- ok[-1]
    r[!(x[-1] > 0 & x[-length(x)] > 0)] <- NA                # Spruenge nur zwischen positiven Werten (Rest: "Wert <= 0")
    J <- which(is.finite(r) & abs(r) > jump / 100)
    n_spike <- n_split <- 0L; skip <- integer(0)
    for (j in J) {
      if (j %in% skip) next
      nxt <- if (j < length(r)) r[j + 1] else NA
      ratio <- x[j] / x[j + 1]; cand <- c(2:10, 1 / (2:10))
      near <- cand[which.min(abs(log(ratio / cand)))]
      if (!is.na(nxt) && sign(nxt) != sign(r[j]) && abs(log1p(nxt)) >= revert * abs(log1p(r[j]))) {
        n_spike <- n_spike + 1L; skip <- c(skip, j + 1L); add(k, ri[j], "Spike (R\u00fccklauf am Folgetag)", v[ri[j]], 100 * r[j])
      } else if (abs(log(ratio / near)) < 0.02) {
        n_split <- n_split + 1L; add(k, ri[j], sprintf("m\u00f6glicher Split (Verh\u00e4ltnis %s)", if (near >= 1) sprintf("%g:1", near) else sprintf("1:%g", 1 / near)),
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
  cat("SimLev-Datenpr\u00fcfung\n\n")
  print(x$summary, row.names = FALSE)
  n <- nrow(x$issues)
  if (!n) { cat("\nKeine Auff\u00e4lligkeiten.\n"); return(invisible(x)) }
  cat(sprintf("\n%d Auff\u00e4lligkeiten%s:\n", n, if (n > max_issues) sprintf(" (erste %d)", max_issues) else ""))
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
#' Ein Wert gilt ab \code{Referenzdatum + lag} bis zum naechsten verfuegbaren
#' Wert (Stufenfunktion); davor ist das Ergebnis NA. Die Umrechnung
#' (\code{transform}) erfolgt auf der Makroreihe selbst, vor der Zuordnung.
#' Das Ergebnis eignet sich z. B. fuer Bedingungen in [tactical_rules()]
#' (\code{"inflation > 3"}) oder als Preisindex fuer [deflate()].
#'
#' @param data Datumsvektor oder data.frame mit Spalte \code{date} (z. B. aus
#'   [align_series()]).
#' @param macro \code{data.frame(date, value)} (es zaehlt die erste
#'   numerische Spalte; fehlt \code{date}, gilt die erste Spalte als Datum)
#'   oder benannter numerischer Vektor mit Datumsnamen. \code{date} ist der
#'   Referenzzeitpunkt (z. B. Monatsanfang des Referenzmonats).
#' @param name Name der neuen Spalte, wenn \code{data} ein data.frame ist
#'   (Standard \code{"macro"}).
#' @param lag Veroeffentlichungsverzug als Zahl in Einheiten von
#'   \code{lag_unit} (Standard 0 = ab dem Referenzdatum bekannt).
#' @param lag_unit Einheit von \code{lag}: \code{"day"} (Standard;
#'   Kalendertage) oder \code{"month"} (Kalendermonate; der Tag wird auf das
#'   Monatsende begrenzt, z. B. 31.01. + 1 Monat = 29.02. bzw. 28.02.).
#' @param transform \code{"level"} (Standard; Wert unveraendert),
#'   \code{"yoy"} (Veraenderung gegen Vorjahr in Prozent, 2 = 2 %),
#'   \code{"mom"} (gegen Vorperiode in Prozent), \code{"diff"} (absolute
#'   Differenz zur Vorperiode, z. B. Zinsaenderung in Prozentpunkten) oder
#'   \code{"yoy_diff"} (absolute Differenz zum Vorjahr).
#' @param periods Perioden je Jahr der Makroreihe, bestimmt den Abstand fuer
#'   \code{"yoy"} und \code{"yoy_diff"}. Standard \code{NULL} = aus dem
#'   mittleren Datumsabstand geschaetzt (1, 4, 12, 52 oder 252, z. B. 12 fuer
#'   Monatsdaten). Bei 1, 4 und 12 wird der Bezugswert per Datum gesucht
#'   (Vorjahr bzw. Vormonat/-quartal desselben Kalenders; fehlt er, etwa bei
#'   einem fehlenden Monat, ist das Ergebnis NA), sonst per Zeile
#'   (\code{periods} bzw. eine Zeile zurueck).
#' @return Bei Datumsvektor ein numerischer Vektor gleicher Laenge, sonst
#'   \code{data} mit neuer Spalte \code{name} (NA vor dem ersten
#'   bekannten Wert).
#' @seealso [align_series()], [deflate()], [tactical_rules()]
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
  # Vorperiode und Vorjahr per Datum (nicht per Zeile): fehlt der Bezugswert, ist das Ergebnis NA
  lt <- as.POSIXlt(md); yy <- lt$year + 1900L
  key <- switch(as.character(p), "1" = yy, "4" = 4L * yy + lt$mon %/% 3L, "12" = 12L * yy + lt$mon, NULL)
  if (!is.null(key)) { prev <- match(key - 1L, key); prev_y <- match(key - p, key) }
  else { prev <- c(NA_integer_, seq_len(k - 1L)); prev_y <- ifelse(seq_len(k) > p, seq_len(k) - p, NA_integer_) }   # Wochen-/Tagesdaten: Zeilen
  shift <- function(ix) v[ix]
  v <- switch(transform, level = v, yoy = 100 * (v / shift(prev_y) - 1), mom = 100 * (v / shift(prev) - 1),
              diff = v - shift(prev), yoy_diff = v - shift(prev_y))
  avail <- if (lag_unit == "day" || lag == 0) md + if (lag_unit == "day") lag else 0 else
    .add_months(md, lag)                     # + lag Kalendermonate, auf das Monatsende begrenzt (31.01. + 1 = 29.02.)
  dates <- .to_date(if (is.data.frame(data)) data$date else data, "align_macro: data")
  o <- order(avail); avail <- avail[o]; v <- v[o]
  j <- findInterval(as.numeric(dates), as.numeric(avail))
  out <- ifelse(j > 0, v[pmax(j, 1L)], NA_real_)
  if (is.data.frame(data)) { data[[name]] <- out; return(data) }
  out
}

#' Waehrung umrechnen
#'
#' Rechnet Kursspalten eines data.frames tageweise mit einem Wechselkurs in
#' eine andere Waehrung um, z. B. einen US-Index in USD nach EUR, bevor er in
#' [simulation()] geht. Erwartet wird ein data.frame mit Spalte `date` und
#' Kursniveaus (z. B. aus [align_series()]). Je Zeile wird der Kurs durch
#' den Wechselkurs geteilt (\code{"divide"}) oder mit ihm multipliziert
#' (\code{"multiply"}); eine Kurssicherung wird nicht abgebildet.
#'
#' @param data data.frame mit Spalte \code{date} und den Kursspalten.
#' @param columns Zeichenvektor der umzurechnenden Spalten.
#' @param fx Wechselkurs als Niveau: Spaltenname in \code{data} (NA per
#'   LOCF gefuellt), \code{data.frame(date, value)} (Stufenfunktion: Wert gilt
#'   ab seinem Datum bis zum naechsten; vor dem ersten Datum gilt der erste
#'   Wert), benannter Vektor mit Datumsnamen, Vektor der Laenge
#'   \code{nrow(data)} oder Skalar (fester Kurs). Alle Werte muessen positiv
#'   sein.
#' @param method \code{"divide"} (Standard; Wechselkurs als Fremdwaehrung je
#'   Zielwaehrung, z. B. USD-Index mit EURUSD = USD je EUR in EUR umrechnen)
#'   oder \code{"multiply"} (Wechselkurs als Zielwaehrung je Fremdwaehrung).
#' @param suffix Endung fuer neue Spalten (z. B. \code{"_eur"}); Standard
#'   \code{NULL} = die Spalten in \code{columns} werden ueberschrieben.
#' @return \code{data} mit umgerechneten (bzw. zusaetzlichen) Spalten.
#' @seealso [align_series()], [deflate()]
#' @examples
#' d <- data.frame(date = seq.Date(as.Date("2024-01-01"), by = "day", length.out = 5),
#'                 sp500_usd = c(4700, 4710, 4690, 4720, 4730),
#'                 eurusd = c(1.10, 1.11, 1.10, 1.09, 1.10))
#' convert_currency(d, "sp500_usd", fx = "eurusd", suffix = "_eur")
#' # Wechselkurs als Stufenfunktion (gilt ab dem jeweiligen Datum)
#' fx <- data.frame(date = as.Date(c("2024-01-01", "2024-01-03")), value = c(1.10, 1.05))
#' convert_currency(d, "sp500_usd", fx = fx)
#' @export
convert_currency <- function(data, columns, fx, method = c("divide", "multiply"), suffix = NULL) {
  method <- match.arg(method)
  miss <- setdiff(columns, names(data))
  if (length(miss)) stop(sprintf("convert_currency: Spalte(n) %s fehlen in data (vorhanden: %s).",
                                 paste0("'", miss, "'", collapse = ", "), paste(names(data), collapse = ", ")))
  f <- .resolve_series(fx, data, "fx")
  bad <- which(!is.finite(f) | f <= 0)
  if (length(bad)) stop(sprintf("convert_currency: Wechselkurs fx muss positiv sein; %d Zeilen ung\u00fcltig (z. B. Zeile %d: %s).",
                                length(bad), bad[1], format(f[bad[1]])))
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
#' \eqn{\Delta t} ist der Abstand zur Vorzeile in Kalendertagen.
#'
#' Wandelt einen Kursindex (Preisindex ohne Ausschuettungen) in einen
#' Total-Return-Index um (Ausschuettungen nach Quellensteuer reinvestiert).
#' Arbeitet auf Vektoren; das Ergebnis kann direkt als neue Kursspalte in
#' den data.frame fuer [simulation()] geschrieben werden. Werden \code{dividends} und
#' \code{yield} zugleich angegeben, wirken beide.
#'
#' @param price Kursreihe als numerischer Vektor (Niveaus); NA werden per
#'   LOCF gefuellt.
#' @param dividends Ausschuettung je Anteil in Waehrungseinheiten am Ex-Tag
#'   (numerischer Vektor gleicher Laenge, 0 oder NA an Tagen ohne
#'   Ausschuettung). Standard \code{NULL} = keine.
#' @param yield Dividendenrendite in Prozent p. a. (2 = 2 %; Skalar oder
#'   Vektor gleicher Laenge), anteilig je Zeile aufgezinst. Standard
#'   \code{NULL} = keine.
#' @param withholding Quellensteuer in Prozent (15 = 15 %), mindert
#'   \code{dividends} und \code{yield}. Standard 0.
#' @param dates Datumsvektor gleicher Laenge fuer \eqn{\Delta t},
#'   aufsteigend sortiert wie \code{price} (sonst Fehler); Standard
#'   \code{NULL} = 1 Tag je Zeile (nur fuer \code{yield} von Bedeutung).
#' @param start Startwert des Index (Standard \code{NULL} = erster Kurs).
#' @return Numerischer Indexvektor gleicher Laenge wie \code{price}.
#' @seealso [splice_series()], [convert_currency()], [align_series()]
#' @examples
#' p <- c(100, 101, 99, 100, 102, 103)
#' div <- c(0, 0, 0, 2, 0, 0)              # 2 je Anteil am Ex-Tag (Zeile 4)
#' total_return_index(p, dividends = div, withholding = 15)
#' # Laufende Dividendenrendite 2 % p. a. mit Kalenderdaten
#' dts <- seq.Date(as.Date("2024-01-01"), by = "day", length.out = 6)
#' total_return_index(p, yield = 2, dates = dts)
#' @export
total_return_index <- function(price, dividends = NULL, yield = NULL, withholding = 0, dates = NULL, start = NULL) {
  p <- as.numeric(price); n <- length(p); w <- withholding / 100
  if (anyNA(p)) p <- .fill_na(p, "locf")
  D <- if (is.null(dividends)) rep(0, n) else { x <- as.numeric(dividends); x[is.na(x)] <- 0; x }
  y <- if (is.null(yield)) rep(0, n) else rep_len(as.numeric(yield), n)
  if (!is.null(dates)) {
    dates <- .to_date(dates, "total_return_index: dates")
    if (length(dates) != n) stop(sprintf("total_return_index: dates hat L\u00e4nge %d, price %d.", length(dates), n))
    if (anyNA(dates) || is.unsorted(dates)) stop("total_return_index: dates m\u00fcssen vollst\u00e4ndig und aufsteigend sortiert sein (wie price).")
  }
  dt <- if (is.null(dates)) rep(1, n) else c(0, diff(as.numeric(dates)))
  r <- c(0, (p[-1] + D[-1] * (1 - w)) / p[-n] - 1 + y[-1] / 100 * (1 - w) * dt[-1] / 365.25)
  (start %||% p[1]) * cumprod(1 + r)
}

#' Reale Werte ueber einen Preisindex
#'
#' Rechnet nominale Kurs- oder Wertspalten in reale Werte (Kaufkraft des
#' Bezugsdatums) um: \eqn{real_t = nominal_t \cdot cpi_b / cpi_t} mit der
#' Bezugszeile \eqn{b}.
#' Erwartet wird ein data.frame mit Spalte `date` und einem Preisindex als
#' Niveau (z. B. Verbraucherpreisindex), keine Inflationsrate. Die realen
#' Spalten kommen als neue Spalten hinzu und koennen wie Kursspalten in
#' [simulation()] oder [deep_analysis()] verwendet werden; fuer die reale
#' Auswertung fertiger Ergebnisse hat [deep_analysis()] ein eigenes
#' Argument \code{inflation}.
#'
#' @param data data.frame mit Spalte \code{date} und den Spalten aus
#'   \code{columns}.
#' @param columns Zeichenvektor der Spalten, die deflationiert werden.
#' @param cpi Preisindex-Niveau: Spaltenname in \code{data} (NA per LOCF
#'   gefuellt; z. B. mit [align_macro()] und Veroeffentlichungsverzug
#'   vorbereitet), \code{data.frame(date, value)} (Stufenfunktion: Wert gilt
#'   ab seinem Datum), benannter Vektor mit Datumsnamen oder Vektor der
#'   Laenge \code{nrow(data)}. Vor dem ersten bekannten Wert wird nicht
#'   zurueckgefuellt: Die realen Werte dieser Zeilen sind NA (mit Hinweis).
#' @param base_date Bezugsdatum, an dem real = nominal (Date oder
#'   \code{"JJJJ-MM-TT"}; verwendet wird die Zeile mit dem naechstgelegenen
#'   Datum; dort muss der Preisindex bekannt sein). Standard \code{NULL} =
#'   erste Zeile mit bekanntem Preisindex.
#' @param suffix Endung fuer die neuen Spalten (Standard \code{"_real"}).
#' @return \code{data} mit zusaetzlichen realen Spalten
#'   \code{paste0(columns, suffix)}.
#' @seealso [align_macro()], [convert_currency()], [deep_analysis()]
#' @examples
#' cpi <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "month", length.out = 36),
#'                   value = 100 * 1.003^(0:35))
#' d <- data.frame(date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = 400),
#'                 depot = 10000 * 1.0002^(0:399))
#' # CPI mit einem Monat Veroeffentlichungsverzug auf den Tageskalender legen
#' d <- align_macro(d, cpi, "cpi", lag = 1, lag_unit = "month")
#' d <- deflate(d, "depot", cpi = "cpi")
#' tail(d, 3)
#' @export
deflate <- function(data, columns, cpi, base_date = NULL, suffix = "_real") {
  dts <- .to_date(data$date, "deflate: data$date")
  c0 <- .cpi_level(cpi, data, dts, "cpi")
  known <- which(!is.na(c0))
  if (!length(known)) stop("deflate: Preisindex cpi hat keinen Wert im Zeitraum von data.")
  if (known[1] > 1L) message(sprintf("Hinweis: deflate: Preisindex erst ab %s bekannt; %d Zeilen davor bleiben NA.",
                                     format(dts[known[1]]), known[1] - 1L))
  b <- if (is.null(base_date)) known[1] else which.min(abs(as.numeric(dts - .to_date(base_date, "base_date"))))
  if (is.na(c0[b])) stop(sprintf("deflate: am Bezugsdatum %s ist kein Preisindex bekannt (erster Wert am %s); base_date sp\u00e4ter w\u00e4hlen.",
                                 format(dts[b]), format(dts[known[1]])))
  for (k in columns) data[[paste0(k, suffix)]] <- as.numeric(data[[k]]) / c0 * c0[b]
  data
}

#' Preisindex-Niveau je Zeile; vor dem ersten bekannten Wert NA (kein Rueckwaertsfuellen)
#' @keywords internal
#' @noRd
.cpi_level <- function(cpi, data, dts, what) {
  if (is.character(cpi) && length(cpi) == 1L) {
    if (!cpi %in% names(data)) stop(sprintf("%s: Spalte '%s' fehlt im Datensatz.", what, cpi))
    return(.fill_na(as.numeric(data[[cpi]]), "locf", keep_leading = TRUE))
  }
  first <- if (is.data.frame(cpi)) {
    dcol <- if ("date" %in% names(cpi)) "date" else names(cpi)[1]
    min(.to_date(cpi[[dcol]], sprintf("%s: Datum", what)), na.rm = TRUE)
  } else if (is.numeric(cpi) && !is.null(names(cpi)) &&
             all(!is.na(suppressWarnings(as.Date(names(cpi), optional = TRUE))))) min(as.Date(names(cpi))) else NULL
  v <- .resolve_series(cpi, data.frame(date = dts), what)
  if (!is.null(first)) v[dts < first] <- NA_real_
  v
}

#' Reihen verketten (Proxy -> Index -> Fonds)
#'
#' Verbindet mehrere Reihen renditebasiert zu einer langen Historie. Die erste
#' Reihe hat Vorrang: Wo sie vorliegt, wird sie unveraendert uebernommen. Davor
#' (und in ihren Luecken) werden die Tagesrenditen der naechsten verfuegbaren
#' Reihe verkettet, usw. Typisch: Fonds, dann zurueckgerechneter Fonds aus
#' [backcast()], dann ein Proxy-Index.
#'
#' Alle Reihen muessen Niveaus (Kurse, Indexstaende) sein, keine Renditen;
#' das Niveau der Kette richtet sich nach der ersten Reihe. Vor dem Start
#' der ersten Reihe wird rueckwaerts verkettet, solange Renditen vorliegen.
#' Das Ergebnis laesst sich als Kursspalte in [simulation()] oder als
#' \code{data.frame(date, value)} in [deep_analysis()] verwenden.
#'
#' @param ... Mindestens zwei benannte Reihen in Prioritaetsreihenfolge,
#'   entweder alle als numerische Vektoren gleicher Laenge (z. B. Spalten
#'   eines gemeinsamen data.frames; dann \code{dates} angeben) oder alle als
#'   \code{data.frame(date, value)} (sie werden mit [align_series()] und
#'   \code{range = "all"} auf Kalendertage gelegt und per LOCF gefuellt).
#'   Bei data.frames gelten Folgen von mehr als 4 Kalendertagen (laenger als
#'   ein langes Wochenende), an denen die erste Reihe nur gefuellt ist,
#'   waehrend eine andere Reihe echte Kurse hat, als Luecken der ersten Reihe
#'   und werden mit den Renditen der naechsten Reihe verkettet. Kuerzere
#'   Folgen (Wochenenden und Feiertage einer Handelstagsreihe, auch wenn die
#'   naechste Reihe Kalendertagswerte hat) und Tage ohne echte Kurse aller
#'   Reihen behalten den letzten Wert der ersten Reihe (LOCF); deren
#'   Bewegung in der naechsten Reihe geht am folgenden Handelstag der ersten
#'   Reihe ein.
#' @param dates Datumsvektor, wenn Vektoren uebergeben werden (sonst
#'   ignoriert).
#' @return data.frame mit \code{date}, \code{value} (verkettete Reihe) und
#'   \code{source}: Name der Reihe, deren Wert (erste Reihe) bzw. Rendite vom
#'   Vortag auf diesen Tag verwendet wurde (NA, wo keine Rendite vorliegt,
#'   z. B. in der ersten Zeile).
#' @seealso [align_series()], [backcast()], [total_return_index()],
#'   [check_series()]
#' @examples
#' set.seed(1)
#' proxy <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = 1500))
#' proxy$value <- 100 * cumprod(1 + rnorm(1500, 3e-4, 0.01))
#' fonds <- proxy[proxy$date >= as.Date("2012-01-01"), ]
#' fonds$value <- 0.5 * fonds$value      # anderes Kursniveau
#' lang <- splice_series(fonds = fonds, proxy = proxy)
#' head(lang, 3)
#' table(lang$source)
#' @export
splice_series <- function(..., dates = NULL) {
  src <- list(...)
  if (length(src) < 2 || is.null(names(src)) || any(names(src) == "")) stop("splice_series: mindestens zwei benannte Reihen.")
  Fl <- NULL
  if (all(vapply(src, is.data.frame, TRUE))) {
    al <- do.call(align_series, c(src, list(range = "all")))
    dates <- al$date; V <- as.matrix(al[, names(src)])
    Fl <- attr(al, "filled")[, names(src), drop = FALSE]       # per LOCF gefuellte Tage (keine echten Werte)
  } else {
    if (is.null(dates)) stop("splice_series: 'dates' angeben, wenn Vektoren \u00fcbergeben werden.")
    V <- do.call(cbind, lapply(src, as.numeric)); colnames(V) <- names(src)
  }
  n <- nrow(V)
  Rm <- rbind(NA, V[-1, , drop = FALSE] / V[-n, , drop = FALSE] - 1)
  p <- V[, 1]
  if (!is.null(Fl)) {                                         # Luecken der ersten Reihe mit Renditen der naechsten fuellen
    # Luecke = Folge von mehr als 4 gefuellten Kalendertagen der ersten Reihe, in der eine andere Reihe
    # echte Werte hat; kuerzere Folgen (Wochenenden, lange Wochenenden, Feiertage) bleiben LOCF der ersten Reihe
    other <- rowSums(!is.na(V[, -1, drop = FALSE]) & !Fl[, -1, drop = FALSE]) > 0
    run <- cumsum(!Fl[, 1])
    gap <- Fl[, 1] & stats::ave(as.numeric(other & Fl[, 1]), run, FUN = max) > 0 &
           stats::ave(as.numeric(Fl[, 1]), run, FUN = sum) > 4
    p[gap] <- NA; Rm[gap, 1] <- NA
  }
  pick <- apply(Rm, 1, function(r) { j <- which(is.finite(r)); if (length(j)) j[1] else NA_integer_ })
  r <- Rm[cbind(seq_len(n), ifelse(is.na(pick), 1L, pick))]; r[is.na(pick)] <- NA
  a <- which(!is.na(p))[1]
  if (is.na(a)) stop("splice_series: Die erste Reihe hat keine Werte.")
  lv <- rep(NA_real_, n); lv[a] <- p[a]
  if (a < n) for (t in (a + 1L):n) lv[t] <- if (!is.na(p[t])) p[t] else if (!is.na(r[t])) lv[t - 1L] * (1 + r[t]) else lv[t - 1L]
  if (a > 1L) for (t in a:2L) { if (is.na(r[t])) break; lv[t - 1L] <- lv[t] / (1 + r[t]) }
  srcname <- ifelse(!is.na(p), names(src)[1], ifelse(is.na(pick), NA, names(src)[pmax(pick, 1L)]))
  srcname[is.na(lv)] <- NA
  data.frame(date = .to_date(dates, "splice_series: dates"), value = lv, source = srcname, stringsAsFactors = FALSE)
}

#' Strategie aus Gewichten
#'
#' Baut aus einem benannten Gewichtsvektor eine statische Strategie fuer
#' [simulation()], ohne jedes Asset einzeln mit [asset_config()] anlegen zu
#' muessen. Die Namen muessen den Kursspalten des Datensatzes entsprechen
#' (z. B. aus [align_series()]). Jedes Asset erhaelt
#' \code{asset_share = Gewicht}; alle weiteren Einstellungen kommen aus
#' \code{...} oder den Standardwerten von [asset_config()] (ETF, Buy and
#' Hold).
#'
#' @param weights Benannter numerischer Vektor Spaltenname -> Gewicht als
#'   Anteil (0.6 = 60 %), z. B. \code{c(world = 0.6, bonds = 0.4)}. Alle
#'   Gewichte muessen positiv sein (Assets mit Gewicht 0 weglassen), die
#'   Namen eindeutig, und die Summe muss 1 sein (wie in [simulation()];
#'   sonst Fehler schon hier).
#' @param ... Weitere Argumente fuer [asset_config()] (z. B.
#'   \code{asset_class}, \code{asset_spread} in Prozent, \code{asset_bonus}
#'   in Prozent). Ein unbenannter einzelner Wert gilt fuer alle Assets;
#'   benannte Vektoren werden je Asset zugeordnet, auch mit einem einzigen
#'   Element wie \code{asset_bonus = c(aktien = 30)} (fehlende Assets
#'   behalten den Standardwert, Namen ohne passendes Asset werden
#'   ignoriert). Nur ein einzelner benannter Wert, dessen Name kein Asset
#'   ist, gilt fuer alle Assets.
#' @return Objekt der Klasse \code{strategy} (wie [create_strategy()]).
#' @seealso [portfolio_template()], [create_strategy()], [simulation()],
#'   [tactical_simulation()]
#' @examples
#' strategy_from_weights(c(world = 0.6, bonds = 0.4), asset_spread = c(world = 0.1, bonds = 0.05))
#' st <- strategy_from_weights(c(aktien = 0.7, gold = 0.3),
#'                             asset_class = c(aktien = "etf", gold = "etc"),
#'                             asset_bonus = c(aktien = 30, gold = 0))
#' sapply(st, `[[`, "asset_class")
#' @export
strategy_from_weights <- function(weights, ...) {
  if (is.null(names(weights)) || any(is.na(names(weights)) | names(weights) == "")) stop("weights muss benannt sein.")
  if (anyDuplicated(names(weights)))
    stop(sprintf("weights: doppelte Namen %s; jedes Asset nur einmal angeben.",
                 paste0("'", unique(names(weights)[duplicated(names(weights))]), "'", collapse = ", ")))
  if (anyNA(weights) || any(weights <= 0)) stop("Gewichte m\u00fcssen positiv sein (Assets mit Gewicht 0 weglassen).")
  if (abs(sum(weights) - 1) > 1e-6)
    stop(sprintf("Gewichte summieren sich zu %.4f; simulation() verlangt die Summe 1 (Anteile, 0.6 = 60 %%).", sum(weights)))
  extra <- list(...)
  # Benannt und Name eines Assets -> je Asset (auch bei einem Element); sonst ein Wert fuer alle
  per_asset <- function(v) !is.null(names(v)) && (length(v) > 1 || names(v) %in% names(weights))
  assets <- lapply(names(weights), function(nm) {
    a <- lapply(extra, function(v) if (per_asset(v)) unname(v[nm]) else v)
    a <- a[!vapply(a, function(v) length(v) == 1 && is.na(v), TRUE)]
    do.call(asset_config, c(list(asset_share = unname(weights[nm])), a))
  })
  names(assets) <- names(weights)
  create_strategy(assets = assets)
}

#' Bekannte Portfolio-Vorlagen
#' @keywords internal
#' @noRd
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
#' Gewichte in der Tabelle in Prozent; in der Strategie als Anteile.
#'
#' @param name Name der Vorlage als Zeichenkette (siehe Tabelle);
#'   \code{portfolio_templates()} listet alle.
#' @param map Benannter Zeichenvektor Rolle -> Spaltenname im Datensatz,
#'   z. B. \code{c(stocks = "msci_world")}. Standard \code{NULL}; Rollen ohne
#'   Eintrag behalten ihren Namen und muessen dann als Spalte vorliegen.
#'   Unbekannte Rollen und mehrere Rollen auf derselben Spalte sind ein
#'   Fehler.
#' @param ... Weitere Argumente fuer [strategy_from_weights()] bzw.
#'   [asset_config()] (z. B. \code{asset_spread}, \code{asset_bonus}).
#' @return \code{portfolio_template()}: Objekt der Klasse \code{strategy}
#'   fuer [simulation()]; \code{portfolio_templates()}: data.frame mit
#'   \code{template}, \code{role} und \code{weight} (Anteil, 0.6 = 60 %).
#' @seealso [strategy_from_weights()], [simulation()]
#' @examples
#' portfolio_template("permanent", map = c(stocks = "msci_world", long_bonds = "bund_10y",
#'                                         cash = "geldmarkt", gold = "gold_eur"))
#' head(portfolio_templates())
#' @export
portfolio_template <- function(name, map = NULL, ...) {
  w <- .portfolio_templates[[name]]
  if (is.null(w)) stop(sprintf("Unbekannte Vorlage '%s'. Verf\u00fcgbar: %s", name, paste(names(.portfolio_templates), collapse = ", ")))
  if (!is.null(map)) {
    if (is.null(names(map)) || any(names(map) == "")) stop("map muss benannt sein: Rolle -> Spaltenname, z. B. c(stocks = \"msci_world\").")
    unk <- setdiff(names(map), names(w))
    if (length(unk)) stop(sprintf("map: unbekannte Rolle(n) %s f\u00fcr Vorlage '%s'; Rollen: %s.",
                                  paste0("'", unk, "'", collapse = ", "), name, paste(names(w), collapse = ", ")))
    names(w) <- ifelse(names(w) %in% names(map), map[names(w)], names(w))
    if (anyDuplicated(names(w))) {
      dup <- unique(names(w)[duplicated(names(w))])
      stop(sprintf("map: mehrere Rollen zeigen auf dieselbe Spalte %s; je Spalte nur eine Rolle (Gewichte sonst selbst zusammenfassen und strategy_from_weights() verwenden).",
                   paste0("'", dup, "'", collapse = ", ")))
    }
  }
  strategy_from_weights(w, ...)
}

#' @rdname portfolio_template
#' @export
portfolio_templates <- function() {
  do.call(rbind, lapply(names(.portfolio_templates), function(n)
    data.frame(template = n, role = names(.portfolio_templates[[n]]), weight = unname(.portfolio_templates[[n]]))))
}
