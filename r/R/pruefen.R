# pruefen.R  --  einheitliche Eingabepruefung (seit 1.6.4, Entscheidung 05.11.2026)
#
# Pruefhilfen fuer die oeffentlichen Funktionen: vorhanden, richtiger Typ, plausibler Wertebereich. Bei einem
# Verstoss bricht die Hilfe mit dem Text aus der Tabelle eingabe ab (core/meldungen.tsv, .MELD_EINGABE in
# R/meldungen.R): deutsch, "<funktion>: <argument> muss ...", in R, Python und Julia zeichengleich (der
# Eingabewert steht nicht im Text). Gegenstuecke mit gleichen Namen und gleicher Semantik:
# python/simlev/_pruefen.py, julia/src/pruefen.jl.
#
# Regeln (wie R, auch wo R selbst still annimmt; Entscheidungen des Nutzers vom 05.11.2026):
# - Zahl: numerisch (kein Text, kein logischer Wert, kein Faktor), Laenge 1, nicht NA/NaN, endlich;
#   ganze Zahl: zusaetzlich x == trunc(x) (2 ist ganz, 2.5 nicht).
# - Wahrheitswert: nur logisch (TRUE/FALSE), Laenge 1, nicht NA; keine Zahl, kein Text "FALSE", nie NULL (wer den
#   Standard will, laesst das Argument weg).
# - Text: character der Laenge 1, nicht NA (kein Faktor); Leerraum wird nicht abgeschnitten.
# - Datum: Date (Laenge 1, endlich) oder Text "JJJJ-MM-TT" (wie as.Date); keine Zahl, kein Faktor.
# - Tabelle: nur data.frame (Python nur pandas.DataFrame, Julia nur RFrame); die Meldung sagt, wie man umwandelt.
# - Signalspalte: logisch oder Zahlen 0/1, NA erlaubt; andere Zahlen (2, 0.5) nicht.
# - Laenge 1: in R ist c(x) dasselbe wie x; Python und Julia nehmen Vektoren der Laenge 1 wie Einzelwerte
#   (chk_scalar dort).
# - NULL nur, wo null_ok = TRUE (nie bei Wahrheitswerten).
# - Faktor: weder als Argument noch als Spalte (chk_nofactor, chk_col_nofactor; Entscheidungen 15 und 22).
# - Ganze Zahl: nie abschneiden, 2.5 ist ein Fehler (Entscheidung 19); Obergrenzen mit chk_max (16, 36) und den
#   gemeinsamen Werten SL_MAX_* (Laufzeiten 100 Jahre, Entscheidung 46); Jahre mit chk_jahre (47).
# - Namen eigener Kennzahlen eindeutig, nicht leer, keine feste Spalte (chk_kennzahlen; Entscheidungen 28 und 43).
# - NA in Basiszins- und CAPE-Reihen ist ein Fehler (chk_col_nona, chk_nona; Entscheidung 17).
# - Zahl aus Text nur mit ASCII-Zeichen (chk_as_num; Entscheidung 27).
# - Unbekannte und doppelte Argumente in ... vor dem Aufruf melden (chk_dots; Entscheidung 21).
# - Meldungen nennen den Eingabewert nicht (nur Funktion, Argument, Spalten- bzw. Asset-Namen und Grenzen).
# Jede Hilfe gibt x unsichtbar zurueck (chk_date1: das Datum als Date).

# Text der Tabelle eingabe
chk_msg <- function(key, ...) sprintf(.MELD_EINGABE[[key]], ...)

# Abbruch mit einem Text der Tabelle eingabe (ohne Aufruf: der Text beginnt mit dem Funktionsnamen)
chk_stop <- function(key, ...) stop(chk_msg(key, ...), call. = FALSE)

# Zahl in einer Meldung (Bereichsgrenzen, Mindestwerte): format(x, digits = 15)
chk_fmt <- function(x) format(x, digits = 15)

# Bereichstext, z. B. "> 0", ">= 0 und <= 1" (mit den Zeichen der Tabelle eingabe)
chk_range_text <- function(lo = NULL, hi = NULL, lo_open = FALSE, hi_open = FALSE) {
  p <- character(0)
  if (!is.null(lo)) p <- c(p, chk_msg(if (lo_open) "bereich.gt" else "bereich.ge", chk_fmt(lo)))
  if (!is.null(hi)) p <- c(p, chk_msg(if (hi_open) "bereich.lt" else "bereich.le", chk_fmt(hi)))
  if (length(p) == 2L) chk_msg("bereich.und", p[1L], p[2L]) else p
}

# einzelne endliche Zahl, optional im Bereich [lo, hi] (lo_open/hi_open: Grenze ausgeschlossen)
chk_num1 <- function(x, fn, arg, lo = NULL, hi = NULL, lo_open = FALSE, hi_open = FALSE, null_ok = FALSE) {
  if (is.null(x) && null_ok) return(invisible(x))
  ok <- is.numeric(x) && length(x) == 1L && is.finite(x)
  rng <- !is.null(lo) || !is.null(hi)
  if (ok && rng)
    ok <- (is.null(lo) || (if (lo_open) x > lo else x >= lo)) && (is.null(hi) || (if (hi_open) x < hi else x <= hi))
  if (!ok) {
    if (rng) chk_stop("zahl_bereich", fn, arg, chk_range_text(lo, hi, lo_open, hi_open))
    chk_stop("zahl", fn, arg)
  }
  invisible(x)
}

# Wahrscheinlichkeit bzw. Anteil in [0, 1]
chk_prob <- function(x, fn, arg, null_ok = FALSE) chk_num1(x, fn, arg, lo = 0, hi = 1, null_ok = null_ok)

# einzelne ganze Zahl >= lo (numerisch; 2 und 2L sind ganz, 2.5 nicht; nie abgeschnitten); mit hi: von lo bis hi
# (Meldung ganz_bis)
chk_int1 <- function(x, fn, arg, lo = 1, null_ok = FALSE, hi = NULL) {
  if (is.null(x) && null_ok) return(invisible(x))
  ok <- is.numeric(x) && length(x) == 1L && is.finite(x) && x == trunc(x) && x >= lo
  if (!is.null(hi)) {
    if (!(ok && x <= hi)) chk_stop("ganz_bis", fn, arg, chk_fmt(lo), chk_fmt(hi))
  } else if (!ok) chk_stop("ganz", fn, arg, chk_fmt(lo))
  invisible(x)
}

# Vektor ganzer Zahlen >= lo (ohne NA; nie abgeschnitten)
chk_intvec <- function(x, fn, arg, lo = 1) {
  if (!(is.numeric(x) && length(x) >= 1L && all(is.finite(x)) && all(x == trunc(x)) && all(x >= lo)))
    chk_stop("ganz_vektor", fn, arg, chk_range_text(lo = lo))
  invisible(x)
}

# Zahl der Prozesse (seit 1.6.4, Entscheidung 41b): "auto" (Standard seit 1.6.4: Planer in .par_lapply) oder ganze Zahl
# >= 1 (sonst Fehler mit Meldung par.cores, Entscheidung 113); mehr als die Zahl der Prozessoren (.sl_nprocs) wird mit einem Hinweis
# begrenzt. Ergebnis: "auto" bzw. die Zahl.
chk_cores <- function(cores, fn, arg = "cores") {
  if (is.character(cores) && !is.object(cores) && length(cores) == 1L && !is.na(cores) && cores == "auto") return("auto")
  if (!(is.numeric(cores) && length(cores) == 1L && is.finite(cores) && cores == trunc(cores) && cores >= 1))
    chk_stop("par.cores", fn, arg)   # seit 1.6.4 (Entscheidung 113; vorher Meldung ganz)
  mx <- .sl_nprocs()
  if (cores > mx) {
    message(chk_msg("hinweis.prozessoren", paste0(fn, ": ", arg), mx))
    cores <- mx
  }
  cores
}

# Obergrenze (seit 1.6.4, Entscheidungen 16 und 36): Zahl bzw. alle Werte <= hi; NULL, Text und NA prueft der
# Aufrufer vorher. Die Grenze steht als ganze Zahl ohne Exponent in der Meldung (z. B. 100000000).
chk_max <- function(x, hi, fn, arg) {
  if (is.numeric(x) && length(x) && any(x > hi, na.rm = TRUE)) chk_stop("obergrenze", fn, arg, sprintf("%.0f", hi))
  invisible(x)
}

# Gemeinsame Obergrenzen (seit 1.6.4; Entscheidung 46 ersetzt die 1 000 Jahre aus 16 und 36 durch 100 Jahre; gleiche
# Namen und Werte in python/simlev/_pruefen.py und julia/src/pruefen.jl, fuer alle Bereiche)
SL_MAX_JAHRE <- 100        # Laufzeiten in Jahren (years, max_years, horizon in Jahren)
SL_MAX_TAGE <- 36600       # Laufzeiten in Tagen bzw. Tagesperioden (path_length, planning_goal(horizon)): 100 Jahre
SL_MAX_MONATE <- 1200      # Laufzeiten in Monaten (planning_lumpsum_vs_dca(months)): 100 Jahre
SL_MAX_N <- 1e8            # Anzahlen (n, n_sim, B)
SL_MAX_GITTER <- 1e6       # Gitterpunkte (n_grid)

# Laufzeit in ganzen Jahren (seit 1.6.4, Entscheidungen 19, 46 und 47): ganze Zahl >= 1 (Meldung ganz) und
# hoechstens SL_MAX_JAHRE (Meldung obergrenze); auch bei unterjaehriger frequency nur ganze Jahre
chk_jahre <- function(x, fn, arg, null_ok = FALSE) {
  if (is.null(x) && null_ok) return(invisible(x))
  chk_int1(x, fn, arg)
  chk_max(x, SL_MAX_JAHRE, fn, arg)
}

# Aufzaehlung "a, b oder c" (Namen in Meldungen)
chk_oder <- function(x) {
  x <- as.character(x)
  if (length(x) <= 1L) return(paste(x, collapse = ""))
  paste0(paste(x[-length(x)], collapse = ", "), " oder ", x[length(x)])
}

# Namen eigener Kennzahlen (seit 1.6.4, Entscheidungen 28 und 43): nm = names() des Ergebnisses von metrics(), n =
# seine Laenge; bei n > 0 Fehler, wenn unbenannt, ein Name NA oder leer, doppelt oder gleich einer festen Spalte der
# Ergebnistabelle (fixed)
chk_kennzahlen <- function(nm, n, fixed, fn) {
  if (n > 0L && (is.null(nm) || length(nm) != n || anyNA(nm) || any(nm == "") || anyDuplicated(nm) || any(nm %in% fixed)))
    chk_stop("n2.kennzahl_namen", fn, chk_oder(fixed))
  invisible(nm)
}

# einzelner Wahrheitswert TRUE oder FALSE (nur logisch; NULL ist ein Fehler, seit E0b ohne null_ok)
chk_bool1 <- function(x, fn, arg) {
  if (!(is.logical(x) && length(x) == 1L && !is.na(x))) chk_stop("wahr", fn, arg)
  invisible(x)
}

# einzelner Text (character, nicht NA; leer erlaubt)
chk_text1 <- function(x, fn, arg, null_ok = FALSE) {
  if (is.null(x) && null_ok) return(invisible(x))
  if (!(is.character(x) && length(x) == 1L && !is.na(x))) chk_stop("text", fn, arg)
  invisible(x)
}

# einzelner, nicht leerer Name (z. B. Spalten- oder Asset-Name)
chk_name1 <- function(x, fn, arg, null_ok = FALSE) {
  if (is.null(x) && null_ok) return(invisible(x))
  if (!(is.character(x) && length(x) == 1L && !is.na(x) && nzchar(x))) chk_stop("name", fn, arg)
  invisible(x)
}

# einer von mehreren Texten (ohne Teiluebereinstimmung; match.arg bleibt, wo R es heute nutzt)
chk_choice <- function(x, fn, arg, choices, null_ok = FALSE) {
  if (is.null(x) && null_ok) return(invisible(x))
  if (!(is.character(x) && length(x) == 1L && !is.na(x) && x %in% choices))
    chk_stop("auswahl", fn, arg, paste0("\"", choices, "\"", collapse = ", "))
  invisible(x)
}

# einzelnes Datum: Date (endlich) oder Text, den as.Date liest; Ergebnis als Date
chk_date1 <- function(x, fn, arg, null_ok = FALSE) {
  if (is.null(x) && null_ok) return(invisible(x))
  d <- if (inherits(x, "Date") && length(x) == 1L) x
       else if (is.character(x) && length(x) == 1L && !is.na(x)) tryCatch(as.Date(x), error = function(e) NA)
       else NA
  if (length(d) != 1L || !is.finite(unclass(d))) chk_stop("datum", fn, arg)
  invisible(d)
}

# numerischer Vektor (Laenge >= 1; NA-Werte prueft der Aufrufer, wo sie fachlich verboten sind)
chk_numvec <- function(x, fn, arg, null_ok = FALSE) {
  if (is.null(x) && null_ok) return(invisible(x))
  if (!(is.numeric(x) && length(x) >= 1L)) chk_stop("zahlen", fn, arg)
  invisible(x)
}

# Laenge
chk_len <- function(x, n, fn, arg) {
  if (length(x) != n) chk_stop("laenge", fn, arg, chk_fmt(n))
  invisible(x)
}

# nur Tabelle (data.frame; Python nur pandas.DataFrame, Julia nur RFrame); die Meldung nennt die Umwandlung
chk_df <- function(x, fn, arg, null_ok = FALSE) {
  if (is.null(x) && null_ok) return(invisible(x))
  if (!is.data.frame(x)) chk_stop("tabelle", fn, arg, chk_msg("tabelle.formen"))
  invisible(x)
}

# Spalten vorhanden (cols: Namen; Meldung nennt die fehlenden in der gegebenen Reihenfolge)
chk_cols <- function(data, cols, fn) {
  miss <- setdiff(cols, names(data))
  if (length(miss)) chk_stop("spalten", fn, paste0("'", miss, "'", collapse = ", "))
  invisible(data)
}

# Spaltentyp: "numerisch" (double/integer, kein Faktor), "logisch" (logical) oder "logisch_oder_numerisch"
chk_col_type <- function(data, col, fn, type = c("numerisch", "logisch", "logisch_oder_numerisch")) {
  type <- match.arg(type)
  v <- data[[col]]
  ok <- switch(type, logisch = is.logical(v), numerisch = is.numeric(v), is.logical(v) || is.numeric(v))
  if (!ok) chk_stop("spalte_typ", fn, col, chk_msg(paste0("typ.", type)))
  invisible(data)
}

# kein Faktor als Argument (Entscheidungen 15 und 22; R rechnete sonst mit den Codes bzw. wandelte still in Text)
chk_nofactor <- function(x, fn, arg) {
  if (is.factor(x)) chk_stop("faktor", fn, arg)
  invisible(x)
}

# Spalte kein Faktor (R rechnete sonst mit den Codes)
chk_col_nofactor <- function(data, col, fn) {
  if (is.factor(data[[col]])) chk_stop("spalte_faktor", fn, col)
  invisible(data)
}

# Signalspalte: logisch (TRUE/FALSE/NA) oder Zahlen 0/1 (NA/NaN erlaubt); andere Zahlen (2, 0.5), Text, Faktor,
# Datum und Listen nicht
chk_col_signal <- function(data, col, fn) {
  v <- data[[col]]
  ok <- is.logical(v) || (is.numeric(v) && !is.factor(v) && all(is.na(v) | v == 0 | v == 1))
  if (!ok) chk_stop("spalte_signal", fn, col)
  invisible(data)
}

# Spalte ohne NA (seit 1.6.4, Entscheidung 17: Basiszins- und CAPE-Reihen); hint: Zusatz aus der Tabelle eingabe
# (z. B. chk_msg("hinweis.basiszins")) oder ""
chk_col_nona <- function(data, col, fn, hint = "") {
  if (anyNA(data[[col]])) chk_stop("spalte_na", fn, col, hint)
  invisible(data)
}

# Werte ohne NA (Vektor oder Matrix; Entscheidung 17)
chk_nona <- function(x, fn, arg, hint = "") {
  if (anyNA(x)) chk_stop("na", fn, arg, hint)
  invisible(x)
}

# Zahl aus Text (seit 1.6.4, Entscheidung 27): wie as.numeric(), aber nur ASCII-Zeichen (Ziffern, Vorzeichen,
# Punkt, Exponent, ASCII-Leerraum); ein Text mit anderen Zeichen (z. B. geschuetztes Leerzeichen U+00A0, fremde
# Ziffern) ergibt NA, unabhaengig von der Spracheinstellung. Ohne Warnung.
chk_as_num <- function(x) {
  x <- as.character(x)
  v <- suppressWarnings(as.numeric(x))
  v[!is.na(x) & grepl("[^\x01-\x7f]", x, useBytes = TRUE)] <- NA_real_
  v
}

# Argumente aus ... (seit 1.6.4, Entscheidung 21): Namen nm muessen in allowed stehen (sonst "unbekanntes Argument")
# und duerfen weder doppelt noch in taken (vom Aufrufer selbst gesetzt) vorkommen (sonst "doppeltes Argument");
# vor dem Aufruf, damit R, Python und Julia gleich melden. Unbenannte Eintraege prueft der Aufrufer.
chk_dots <- function(nm, allowed, fn, taken = character(0)) {
  nm <- nm[nzchar(nm)]
  for (k in nm) if (!k %in% c(allowed, taken)) chk_stop("argument_unbekannt", fn, k)
  d <- nm[duplicated(nm) | nm %in% taken]
  if (length(d)) chk_stop("argument_doppelt", fn, d[1])
  invisible(nm)
}
