# =============================================================================
#  tactical.R  —  Taktische Allokation ueber zeitvariable Zielgewichte
# -----------------------------------------------------------------------------
#  Gewichts-Erzeuger (liefern ein SimLevWeights: data.frame(date, Asset...)
#  mit dem Zielgewicht, das nach Schlusskurs des Tages bekannt ist):
#    tactical_rules()     geordnete Bedingungen -> Zielportfolio, Rueckfall
#    tactical_rotation()  Momentum-Rotation: Top-N, Dual Momentum (absoluter
#                         Filter), Canary-/Breitenschutz (Keller & Keuning)
#    tactical_target_volatility()  Zielvolatilitaet: Risikoanteil skalieren, Rest in
#                         eine sichere Anlage (Moreira & Muir 2017)
#    tactical_conditional_volatility() nur in extremen Volatilitaetsphasen skalieren
#                         (Bongaerts, Kang & van Dijk 2020)
#    tactical_glidepath()          Gewichte zeitlich zwischen zwei Allokationen
#    tactical_blend()      Kern-Satellit: Mischung mehrerer Gewichtsreihen
#    signal_state()       Kauf-/Verkaufssignale -> dauerhafter Zustand
#    momentum_score()     Momentum-Score je Anlage
#  Ausfuehrung:
#    tactical_simulation() uebersetzt die Gewichte in event_col/event_weight
#                         von simulation() (Engine unveraendert): Handel an
#                         Wechsel- und Pflegeterminen mit Verzoegerung 'lag',
#                         optionalem Toleranzband, Steuern und Kosten wie immer.
# =============================================================================

#' Gewichts-Frame bauen und pruefen
#' @keywords internal
#' @noRd
.as_weights <- function(dates, W, source = "") {
  W <- as.matrix(W); W[!is.finite(W)] <- 0; W[W < 0] <- 0
  s <- rowSums(W); bad <- s <= 0
  if (any(bad)) stop(sprintf("Gewichte: %d Zeilen ohne positive Gewichte.", sum(bad)))
  W <- W / s
  out <- data.frame(date = .to_date(dates, "date"), W, check.names = FALSE)
  structure(out, class = c("SimLevWeights", "data.frame"), source = source)
}

# Signal list(buy, sell): Liste mit buy und sell, je logisch oder 0/1 (NA erlaubt), gleich lang (seit 1.6.4,
# Entscheidung 1; bis 1.6.3 recycelte R ungleiche Laengen, initial als Vektor verdoppelte das Ergebnis)
.e5_signal <- function(signal, fn, i = NULL) {
  ok1 <- function(v) (is.logical(v) || (is.numeric(v) && !is.factor(v) && all(is.na(v) | v == 0 | v == 1))) &&
    is.null(dim(v))
  ok <- is.list(signal) && !is.data.frame(signal) && all(c("buy", "sell") %in% names(signal)) &&
    ok1(signal$buy) && ok1(signal$sell) && length(signal$buy) == length(signal$sell)
  if (!ok) {
    if (is.null(i)) chk_stop("e5.signal", fn) else chk_stop("e5.when", fn, i)
  }
  invisible(signal)
}

#' Zeilen am Ende jeder Periode (letzte vorhandene Zeile)
#' @keywords internal
#' @noRd
.period_last <- function(dates, every) {
  key <- if (is.character(every) && length(every) == 1L && every %in% c("week", "month", "quarter", "year"))
    .date_key(dates, every)                                     # seit 1.5.1 ganzzahlig statt format() je Tag
  if (is.null(key)) key <- switch(every, day = seq_along(dates), week = format(dates, "%G-%V"), month = format(dates, "%Y-%m"),
                quarter = paste(format(dates, "%Y"), (as.integer(format(dates, "%m")) - 1L) %/% 3L),
                year = format(dates, "%Y"), stop("every: 'day', 'week', 'month', 'quarter' oder 'year'."))
  if (every == "day") return(seq_along(dates))
  which(c(key[-1] != key[-length(key)], TRUE))
}

#' Werte an Entscheidungszeilen bis zur naechsten Entscheidung halten
#' @keywords internal
#' @noRd
.hold_rows <- function(n, rows, M) {
  idx <- findInterval(seq_len(n), rows)
  out <- matrix(NA_real_, n, ncol(M), dimnames = list(NULL, colnames(M)))
  ok <- idx > 0
  out[ok, ] <- M[idx[ok], , drop = FALSE]
  out
}

#' Signale in einen dauerhaften Zustand uebersetzen
#'
#' \code{TRUE} ab einem Kaufsignal bis zum naechsten Verkaufssignal (wie die
#' Ein-/Ausstiegslogik von \code{simulation()}). Zeilen, in denen beide
#' Signale \code{FALSE} sind (z. B. innerhalb eines Hysterese-Bands) oder
#' beide \code{TRUE}, aendern den Zustand nicht. So lassen sich Signale als
#' "investiert ja/nein" auswerten oder als Bedingung in [tactical_rules()]
#' verwenden (dort geschieht die Umwandlung automatisch).
#'
#' @param signal \code{list(buy, sell)} mit logischen Vektoren gleicher
#'   Laenge (z. B. aus [signal_sma()]); NA vorher durch \code{FALSE}
#'   ersetzen (die Signal-Bausteine liefern keine NA).
#'   Seit 1.6.4 nur TRUE/FALSE oder 0/1 (NA erlaubt) und gleiche Laenge, sonst Fehler.
#' @param initial Logischer Zustand vor dem ersten Signal (Standard
#'   \code{FALSE} = nicht investiert).
#' @return Logischer Vektor gleicher Laenge (\code{TRUE} = investiert).
#' @seealso [signals], [tactical_rules()]
#' @examples
#' x <- c(100, 102, 105, 103, 99, 97, 100, 104)
#' signal_state(list(buy = x > 101, sell = x < 98))
#' set.seed(1)
#' p <- 100 * cumprod(1 + rnorm(1000, 2e-4, 0.01))
#' table(signal_state(signal_sma(p, 200, band = 2)))
#' @export
signal_state <- function(signal, initial = FALSE) {
  .e5_signal(signal, "signal_state")                     # seit 1.6.4 (Entscheidung 1; B-024)
  chk_bool1(initial, "signal_state", "initial")
  b <- signal$buy; s <- signal$sell; n <- length(b)
  ev <- ifelse(b & !s, 1L, ifelse(s & !b, -1L, 0L))
  idx <- which(ev != 0L)
  st <- rep(initial, n)
  if (length(idx)) {
    k <- findInterval(seq_len(n), idx)
    st[k > 0] <- ev[idx[k[k > 0]]] == 1L
  }
  st
}

#' Momentum-Score
#'
#' Mittlere Rendite ueber mehrere Rueckblicke (Monate, kalenderbasiert) je
#' Anlage, z. B. der "13612"-Score (1, 3, 6, 12 Monate). Mit
#' \code{type = "13612w"} gewichtet wie bei Keller & Keuning:
#' \eqn{(12 r_1 + 4 r_3 + 2 r_6 + r_{12}) / 4}.
#'
#' Die Rendite \eqn{r_m} je Zeile ist der aktuelle Kurs geteilt durch den
#' Kurs der letzten Zeile mit Datum am oder vor dem Tag \eqn{m} Monate
#' zuvor, minus 1 (als Anteil, 0.05 = 5 %). Hat der Zielmonat weniger Tage,
#' gilt sein letzter Tag (31.03. minus 1 Monat = 28.02. bzw. 29.02.;
#' in 0.5.0 (Vorfassung vor den Korrekturen) lief der Rueckblick wie bei [seq.Date()] in den Folgemonat
#' ueber, z. B. auf den 02.03.). Luecken in den Kursen werden
#' per LOCF gefuellt; Handels- und Kalendertagsdaten funktionieren
#' gleichermassen. Grundlage fuer [tactical_rotation()].
#'
#' @param data data.frame mit Spalte \code{date} (Klasse Date) und
#'   Kursspalten (Niveaus).
#'   Seit 1.6.4 Datum aufsteigend ohne NA, Kursspalten numerisch (kein Faktor).
#' @param assets Zeichenvektor der Kursspalten.
#' @param lookbacks Rueckblicke in Kalendermonaten (Standard
#'   \code{c(1, 3, 6, 12)}); bei \code{type = "13612w"} ignoriert.
#'   Seit 1.6.4 ganze Zahlen von 1 bis 1200 (kein Blick in die Zukunft).
#' @param type \code{"average"} (Standard; ungewichtetes Mittel der
#'   Renditen) oder \code{"13612w"} (gewichtet, Rueckblicke fest 1, 3, 6, 12).
#' @return Numerische Matrix Zeilen von \code{data} x \code{assets} mit dem
#'   Score als Anteil (NA, solange die Historie fuer den laengsten
#'   Rueckblick zu kurz ist).
#' @seealso [tactical_rotation()], [signal_momentum()]
#' @examples
#' set.seed(1); n <- 2 * 365
#' d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n),
#'                 aktien = 100 * cumprod(1 + rnorm(n, 3e-4, 0.01)),
#'                 anleihen = 100 * cumprod(1 + rnorm(n, 1e-4, 0.003)))
#' ms <- momentum_score(d, c("aktien", "anleihen"))
#' tail(ms, 3)
#' tail(momentum_score(d, c("aktien", "anleihen"), type = "13612w"), 3)
#' @export
momentum_score <- function(data, assets, lookbacks = c(1, 3, 6, 12), type = c("average", "13612w")) {
  fn <- "momentum_score"
  .e5_choice(type, c("average", "13612w"), fn, "type")   # Pruefung (Meldung auswahl)
  type <- match.arg(type)
  d <- .e5_data_dates(data, fn, "momentum_score: data$date"); n <- length(d)   # seit 1.6.4 (K42 E5)
  .e5_names(assets, fn, "assets")
  .e5_lookbacks(lookbacks, fn)                            # seit 1.6.4 ganze Zahlen 1 bis 1200 (B-025)
  miss <- setdiff(assets, names(data)); if (length(miss)) stop(sprintf("momentum_score: Kursspalte(n) fehlen: %s", paste(miss, collapse = ", ")))
  .e5_numcols(data, assets, fn)                           # Entscheidung 15, B-009
  if (type == "13612w") lookbacks <- c(1, 3, 6, 12)
  # seit 1.6.0 im Kern (sl_mom_score: Rueckblickzeilen ganzzahlig, LOCF, Renditen, Scores), wenn die Daten den
  # ueblichen Fall bilden (sortiert, endlich, Jahre 1000-9000, Rueckblicke bis 1000 Jahre); sonst wie bisher
  dn <- unclass(d)
  if (n >= 1L && is.data.frame(data) && length(assets) >= 1L && is.character(assets) && is.null(names(assets)) &&
      !anyNA(assets) && length(lookbacks) >= 1L && is.numeric(lookbacks) && !anyNA(lookbacks) &&
      all(abs(lookbacks) <= 12000) && is.numeric(dn) && !anyNA(dn) && all(dn >= -354285 & dn <= 2568019) &&
      !is.unsorted(dn)) {
    X <- vapply(assets, function(a) as.numeric(data[[a]]), numeric(n))
    S <- .Call(C_sl_mom_score, as.double(dn), as.integer(lookbacks), as.double(X), if (type == "13612w") 1L else 0L)
    dimnames(S) <- list(NULL, assets)
    return(S)
  }
  lt <- as.POSIXlt(d); y <- lt$year + 1900L; mday <- lt$mday
  back <- lapply(lookbacks, function(m) {
    mo <- lt$mon - as.integer(m); y2 <- y + mo %/% 12L; mo2 <- mo %% 12L
    first <- as.Date(sprintf("%04d-%02d-01", y2, mo2 + 1L))
    nxt <- as.Date(sprintf("%04d-%02d-01", y2 + (mo2 + 1L) %/% 12L, (mo2 + 1L) %% 12L + 1L))
    target <- first + pmin(mday, as.integer(nxt - first)) - 1L      # auf das Monatsende begrenzt (31.03. - 1 Monat = 29.02.)
    findInterval(as.numeric(target), as.numeric(d))
  })
  S <- vapply(assets, function(a) {
    x <- .fill_na(as.numeric(data[[a]]), "locf", keep_leading = TRUE)
    R <- vapply(back, function(k) ifelse(k > 0, x / x[pmax(k, 1L)] - 1, NA_real_), numeric(n))
    if (!is.matrix(R)) R <- matrix(R, ncol = length(back))
    if (type == "13612w") (12 * R[, 1] + 4 * R[, 2] + 2 * R[, 3] + R[, 4]) / 4 else rowMeans(R)
  }, numeric(n))
  if (!is.matrix(S)) S <- matrix(S, ncol = length(assets), dimnames = list(NULL, assets))
  S
}

# Regeltexte im gemeinsamen RExpr-Umfang (seit 1.6.4, Entscheidung 59): Auswertung in einer Umgebung, die nur
# die Operatoren und Funktionen von RExpr (python/simlev/_r/rexpr.py, julia/src/r/rexpr.jl: _FUNS) sowie Variablen
# und Funktionen der aufrufenden Umgebung bis zur globalen kennt (nicht die Paketfunktionen des Suchpfads, wie
# Python/Julia die Funktionen der Sprache nicht kennen); nicht unterstuetzte Sprachmittel
# melden wie RExpr. Ergebnisse im Umfang unveraendert (dieselben R-Funktionen).
.e5_rexpr_ops <- c("(", "{", "if", "<-", "=", "!", "-", "+", "&&", "||", "&", "|", "==", "!=", "<", ">", "<=",
                   ">=", "*", "/", "^", "%%", "%/%", "%in%", ":", "[", "[[")
.e5_rexpr_funs <- c("logical", "integer", "numeric", "double", "character", "rep", "abs", "sqrt", "exp", "expm1",
                    "log1p", "log2", "log10", "sin", "cos", "tan", "tanh", "atan", "floor", "ceiling", "trunc",
                    "sign", "log", "round", "signif", "is.na", "is.nan", "is.finite", "is.infinite", "ifelse",
                    "pmin", "pmax", "min", "max", "sum", "mean", "median", "var", "sd", "quantile", "any", "all",
                    "length", "c", "nchar", "xor", "isTRUE", "isFALSE", "as.numeric", "as.double", "as.integer",
                    "as.logical", "as.character", "as.Date", "cumsum", "identity")
.e5_rexpr_unsup <- c("function", "for", "while", "repeat", "next", "break", "~", "?", "::", ":::", "<<-")
# Aufruf mit einem Ausdruck statt eines Namens als Funktion (z. B. (function(x) x)(1), stats::sd(x)): wie RExpr
# "attempt to apply non-function" beim Auswerten
.e5_rexpr_cplx <- function(e) is.complex(e) || (is.call(e) && any(vapply(as.list(e), function(z) {
  if (missing(z)) FALSE else .e5_rexpr_cplx(z) }, TRUE)))
.e5_rexpr_rw <- function(e) {
  if (!is.call(e)) return(e)
  if (!is.symbol(e[[1L]])) return(quote(.e5_callx()))
  for (i in seq_along(e)[-1L]) if (is.call(e[[i]])) e[[i]] <- .e5_rexpr_rw(e[[i]])
  e
}
# Tiefe des Aufrufbaums (seit 1.6.4, Entscheidung 75): Aufruf 1 + Tiefe des tiefsten Elements (auch der Funktion),
# Namen und Konstanten 0, Paarlisten (Formale) ohne eigene Ebene; bricht ueber 200 ab (gleiche Zaehlung wie RExpr)
.sp_rexpr_depth <- function(e, d = 0L) {
  if (is.call(e)) d <- d + 1L
  else if (!(is.pairlist(e) && !is.null(e))) return(d)
  if (d > 200L) return(d)
  max(d, vapply(as.list(e), function(z) if (missing(z)) 0L else .sp_rexpr_depth(z, d), 0L))
}
.e5_rexpr_parse <- function(w) {
  # seit 1.6.4 (C-006, Entscheidung 75): hoechstens 200 Ebenen wie RExpr; der Parser von R meldet sehr tiefe Ketten
  # (ab einigen tausend Ebenen) als "out of memory while parsing", RExpr schon ab 201 die Tiefe
  ex <- tryCatch(parse(text = w, keep.source = FALSE), error = function(e) {
    if (grepl("out of memory while parsing", conditionMessage(e), fixed = TRUE)) chk_stop("sp.rexpr_tiefe", 200L)
    stop(e)
  })
  if (any(vapply(as.list(ex), function(z) .sp_rexpr_depth(z) > 200L, TRUE))) chk_stop("sp.rexpr_tiefe", 200L)
  # komplexe Zahlen (1i, NA_complex_) wie RExpr schon beim Zerlegen abgelehnt (seit 1.6.4, Entscheidung 64)
  if (any(vapply(as.list(ex), .e5_rexpr_cplx, TRUE)))
    stop("RExpr: komplexe Zahlen werden nicht unterst\u00fctzt", call. = FALSE)
  for (i in seq_along(ex)) ex[[i]] <- .e5_rexpr_rw(ex[[i]])
  ex
}
# Spalten von data fuer Regeltexte (seit 1.6.4, C-007): bei gleichem Namen die erste (wie eval mit einem data.frame);
# Listen- und komplexe Spalten kann RExpr nicht darstellen, ihr Zugriff ist in allen drei Sprachen ein Fehler
.sp_rexpr_data <- function(data, rx) {
  data <- data[!duplicated(names(data))]
  bad <- vapply(data, function(v) is.list(v) || is.complex(v), TRUE)
  if (!any(bad)) return(data)
  e <- list2env(as.list(data)[!bad], parent = rx)
  for (nm in names(data)[bad])
    makeActiveBinding(nm, local({ k <- nm; function() chk_stop("sp.rexpr_spalte", k) }), e)
  e
}
# Vektorlängen in Regeltexten höchstens 1e8 wie RExpr (seit 1.6.4, C-006, Entscheidung 79): ":", rep() und
# logical()/integer()/numeric()/double()/character() prüfen die Ergebnislänge vor dem Aufruf der Basisfunktion; Fälle,
# die R selbst ablehnt (NA, Inf, negative Werte, falsche Längen), gehen unverändert an R
.sp_rexpr_maxlen <- 1e8
.sp_rexpr_len_stop <- function() chk_stop("sp.rexpr_laenge", "100000000")
.sp_rexpr_num1 <- function(v) if ((is.numeric(v) || is.logical(v) || is.character(v)) && length(v) >= 1L && !is.object(v))
  suppressWarnings(as.numeric(v[[1L]])) else NA_real_
.sp_rexpr_colon <- function(e1, e2) {
  a <- .sp_rexpr_num1(e1); b <- .sp_rexpr_num1(e2)
  if (is.finite(a) && is.finite(b) && abs(b - a) < 4.503599627370496e15 &&
      floor(abs(b - a) + 1 + 1.1920928955078125e-07) > .sp_rexpr_maxlen) .sp_rexpr_len_stop()
  .Primitive(":")(e1, e2)
}
.sp_rexpr_rep_len <- function(lx, times = 1, length.out = NA, each = 1) {
  num <- function(v) if ((is.numeric(v) || is.logical(v) || is.character(v)) && length(v) && !is.object(v))
                       suppressWarnings(as.numeric(v)) else NA_real_
  lo <- num(length.out)[1L]
  if (is.finite(lo)) return(max(trunc(lo), 0))
  e <- num(each)[1L]
  e <- if (is.finite(e)) trunc(e) else 1
  if (e < 0) return(0)
  t <- num(times)
  if (!length(t) || anyNA(t) || !all(t > -1 & t < 4503599627370497)) return(0)
  if (length(t) == 1L) lx * e * trunc(t) else if (length(t) == lx * e) sum(trunc(t)) else 0
}
.sp_rexpr_rep <- function(x, ...) {
  n <- tryCatch(.sp_rexpr_rep_len(length(x), ...), error = function(e) 0)
  if (n > .sp_rexpr_maxlen) .sp_rexpr_len_stop()
  .Primitive("rep")(x, ...)
}
.sp_rexpr_vec <- function(f) {
  force(f)
  function(length = 0L) {
    n <- .sp_rexpr_num1(length)
    if (base::length(length) == 1L && is.finite(n) && n >= 0 && trunc(n) > .sp_rexpr_maxlen) .sp_rexpr_len_stop()
    f(length)
  }
}
.e5_rexpr_env <- function(env) {
  ev <- new.env(parent = emptyenv())
  e <- env
  repeat {                                   # aufrufende Umgebung bis einschliesslich der globalen
    if (identical(e, emptyenv()) || isNamespace(e) || identical(e, baseenv())) break
    for (nm in ls(e, all.names = TRUE)) if (!exists(nm, envir = ev, inherits = FALSE)) {
      v <- tryCatch(get(nm, envir = e), error = function(err) NULL)   # auch selbst zugewiesene Funktionen
      if (!is.null(v)) assign(nm, v, envir = ev)
    }
    if (identical(e, globalenv())) break
    e <- parent.env(e)
  }
  for (nm in c("T", "F", "pi", "letters", "LETTERS", "month.name", "month.abb"))
    if (!exists(nm, envir = ev, inherits = FALSE)) assign(nm, get(nm, envir = baseenv()), envir = ev)
  for (nm in c(.e5_rexpr_ops, .e5_rexpr_funs))
    assign(nm, if (nm %in% c("median", "var", "sd", "quantile")) getExportedValue("stats", nm) else get(nm, envir = baseenv()),
           envir = ev)
  assign(":", .sp_rexpr_colon, envir = ev)   # seit 1.6.4 mit Längengrenze (Entscheidung 79)
  assign("rep", .sp_rexpr_rep, envir = ev)
  for (nm in c("logical", "integer", "numeric", "double", "character"))
    assign(nm, .sp_rexpr_vec(get(nm, envir = baseenv())), envir = ev)
  for (nm in .e5_rexpr_unsup)
    assign(nm, local({ f <- nm; function(...) stop(sprintf("RExpr: '%s' wird in Ausdr\u00fccken nicht unterst\u00fctzt", f), call. = FALSE) }),
           envir = ev)
  assign(".e5_callx", function() stop("attempt to apply non-function", call. = FALSE), envir = ev)
  assign("$", function(x, name) {   # seit 1.6.4 wie R und RExpr: NULL$x ist NULL (C-025)
    if (is.null(x)) return(NULL)
    stop("$ operator is invalid for atomic vectors", call. = FALSE) }, envir = ev)
  assign("@", function(object, name) stop(sprintf("no applicable method for `@` applied to an object of class \"%s\"",
                                                  class(object)[1]), call. = FALSE), envir = ev)
  ev
}

#' Regelbasierte taktische Allokation
#'
#' Geordnete Bedingungen waehlen je Tag ein Zielportfolio; die erste
#' zutreffende Regel gewinnt, sonst gilt \code{default}. Bedingungen sind
#' logische Vektoren, Ausdruecke als Zeichenkette (ausgewertet in
#' \code{data}, z. B. \code{"inflation > 3"}) oder Signale aus den
#' Signal-Bausteinen (\code{list(buy, sell)}, als Zustand mit Hysterese).
#'
#' Entschieden wird in jeder Zeile (kein Rhythmus); das Zielgewicht gilt als
#' nach Schluss des Tages bekannt. Gehandelt wird erst in
#' [tactical_simulation()], dort mit Verzoegerung \code{lag} und optionalem
#' Pflegerhythmus \code{rebalance}. Gewichte werden je Zeile auf die Summe 1
#' normiert (negative Werte als 0); Anlagen, die nur in anderen Regeln
#' vorkommen, erhalten 0.
#'
#' @param data data.frame mit Spalte \code{date} (und den in Bedingungen
#'   verwendeten Spalten, z. B. aus [series_align_macro()]).
#' @param rules Liste von Regeln \code{list(when = ..., weights = c(A = 0.6,
#'   B = 0.4))}, in Prioritaetsreihenfolge. \code{when}: logischer Vektor
#'   der Laenge \code{nrow(data)}, Zeichenkette mit einem R-Ausdruck
#'   (ausgewertet in \code{data}, dann in der aufrufenden Umgebung) oder
#'   \code{list(buy, sell)} (wird mit [signal_state()] in einen Zustand
#'   uebersetzt); NA gilt als \code{FALSE}. \code{weights}: benannter
#'   Vektor Kursspalte -> Gewicht als Anteil.
#'   Seit 1.6.4 je Regel nur die Felder when und weights; Gewichte endlich und >= 0.
#'   Seit 1.6.4 ist \code{when} auch eine Funktion von \code{data} (Ergebnis logischer Vektor
#'   der Laenge \code{nrow(data)}), und Regeltexte gelten in R, Python und Julia gleich im
#'   gemeinsamen Umfang: Spalten von \code{data}, Variablen und eigene Funktionen der aufrufenden
#'   Umgebung (bis zur globalen, nicht die Funktionen geladener Pakete), Operatoren, \code{if} und
#'   die Funktionen abs, all, any, as.character, as.Date, as.double, as.integer, as.logical,
#'   as.numeric, atan, c, ceiling, character, cos, cumsum, double, exp, expm1, floor, identity,
#'   ifelse, integer, is.finite, is.infinite, is.na, is.nan, isFALSE, isTRUE, length, log, log10,
#'   log1p, log2, logical, max, mean, median, min, nchar, numeric, pmax, pmin, quantile, rep, round,
#'   sd, sign, signif, sin, sqrt, sum, tan, tanh, trunc, var, xor; anderes (z. B. \code{function},
#'   \code{::}, Paketfunktionen) ist ein Fehler.
#' @param default Benannter Gewichtsvektor (Anteile) fuer Zeilen, in denen
#'   keine Regel zutrifft.
#' @return \code{SimLevWeights}: data.frame mit \code{date} und je Anlage
#'   einer Spalte Zielgewicht (Anteil, Zeilensumme 1), mit Attributen
#'   \code{regime} (Nummer der aktiven Regel je Zeile, 0 = \code{default})
#'   und \code{source}. \code{print()} zeigt Mittel, Minimum, Maximum und
#'   letztes Gewicht in Prozent sowie die Zahl der Wechsel, \code{plot()}
#'   die Gewichte als gestapelte Flaechen.
#' @seealso [tactical_simulation()], [signals], [series_align_macro()],
#'   [tactical_blend()]
#' @examples
#' set.seed(1)
#' d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 500))
#' d$A <- 100 * cumprod(1 + rnorm(500, 3e-4, 0.01)); d$B <- 100 * cumprod(1 + rnorm(500, 1e-4, 0.003))
#' w <- tactical_rules(d, list(list(when = signal_sma(d$A, 200), weights = c(A = 1))),
#'                     default = c(B = 1))
#' table(attr(w, "regime"))
#' @export
tactical_rules <- function(data, rules, default) {
  fn <- "tactical_rules"
  .e5_data_dates(data, fn, "date")                        # seit 1.6.4 (K42 E5)
  n <- nrow(data); env <- parent.frame()
  if (!is.list(rules) || is.data.frame(rules)) chk_stop("liste", fn, "rules")   # leere Liste: nur default
  for (i in seq_along(rules)) {
    r <- rules[[i]]
    if (!is.list(r) || is.data.frame(r) || is.null(names(r)) || !all(c("when", "weights") %in% names(r))) chk_stop("e5.regel", fn, i)
    bad <- setdiff(names(r), c("when", "weights"))       # Entscheidung 11 sinngemaess
    if (length(bad)) chk_stop("e5.regel_feld", fn, bad[1], i)
    .e5_weights(r$weights, fn, sprintf("rules[[%d]]$weights", i))
    w <- r$when
    if (is.list(w)) .e5_signal(w, fn, i)
    else if (!(is.function(w) ||                          # Funktion von data (seit 1.6.4, Entscheidung 59)
               (is.character(w) && length(w) >= 1L) ||   # Text: je Element ein Ausdruck (seit 1.6.3)
               ((is.logical(w) || (is.numeric(w) && !is.factor(w) && all(is.na(w) | w == 0 | w == 1))) && is.null(dim(w)))))
      chk_stop("e5.when", fn, i)
  }
  .e5_weights(default, fn, "default")
  assets <- unique(c(unlist(lapply(rules, function(r) names(r$weights))), names(default)))
  rx <- if (any(vapply(rules, function(r) is.character(r$when), TRUE))) .e5_rexpr_env(env)
  cond <- vapply(rules, function(r) {
    w <- r$when
    v <- if (is.character(w)) eval(.e5_rexpr_parse(w), .sp_rexpr_data(data, rx), rx)   # RExpr-Umfang (seit 1.6.4)
         else if (is.function(w)) w(data)
         else if (is.list(w) && !is.null(w$buy)) signal_state(w) else w
    v <- as.logical(v); v[is.na(v)] <- FALSE
    if (length(v) != n) stop("Bedingung hat nicht die L\u00e4nge nrow(data).")
    v
  }, logical(n))
  if (!is.matrix(cond)) cond <- matrix(cond, nrow = n)
  # erste Regel mit TRUE je Zeile, sonst 0; seit 1.6.4 spaltenweise von hinten (B-080, bis 1.6.3 apply je Zeile)
  regime <- integer(n); for (j in rev(seq_len(ncol(cond)))) regime[cond[, j]] <- j
  vec <- function(w) { v <- stats::setNames(rep(0, length(assets)), assets); v[names(w)] <- w; v }
  P <- rbind(vec(default), do.call(rbind, lapply(rules, function(r) vec(r$weights))))
  W <- P[regime + 1L, , drop = FALSE]
  out <- .as_weights(data$date, W, "rules")
  attr(out, "regime") <- regime
  out
}

#' Momentum-Rotation, Dual Momentum und Canary-Schutz
#'
#' An jedem Entscheidungstermin (Periodenende) werden die Anlagen nach ihrem
#' Momentum-Score sortiert und die besten \code{top} gehalten.
#' \itemize{
#'   \item \strong{Absolutes Momentum} (\code{absolute = TRUE}, Dual Momentum
#'     nach Antonacci): Ein gewaehlter Platz mit negativem Score geht an die
#'     beste sichere Anlage aus \code{safe}.
#'   \item \strong{Canary/Breite} (\code{canary}, Keller & Keuning): Bei
#'     \eqn{b} Canary-Anlagen mit negativem Score geht der Anteil
#'     \eqn{\min(1, b / B)} an die sichere Anlage (\eqn{B} = \code{breadth}).
#' }
#'
#' Entscheidungstermine sind die letzten vorhandenen Zeilen jeder Periode
#' von \code{every}, ab dem ersten Termin, an dem mindestens \code{top}
#' Anlagen einen Score haben. Das Zielgewicht gilt ab dem Termin bis zum
#' naechsten; davor liegt alles in \code{safe[1]} (ohne \code{safe} in
#' \code{assets[1]}). \code{every} legt nur den Entscheidungsrhythmus fest;
#' gehandelt wird in [tactical_simulation()] (Verzoegerung \code{lag},
#' Pflegerhythmus \code{rebalance}).
#'
#' @param data data.frame mit Spalte \code{date} (Klasse Date) und
#'   Kursspalten (Niveaus) aller Anlagen aus \code{assets}, \code{safe} und
#'   \code{canary}.
#' @param assets Zeichenvektor der Risikoanlagen fuer die Rotation.
#' @param top Anzahl gehaltener Anlagen (Standard 1; 1 bis Anzahl
#'   \code{assets}).
#'   Seit 1.6.4 ganze Zahl ohne Abschneiden.
#' @param safe Zeichenvektor der sicheren Anlage(n); bei mehreren wird die
#'   mit dem besten Score gewaehlt. Pflicht, wenn \code{absolute = TRUE}
#'   (Standard) oder \code{canary} gesetzt ist (sonst Fehler).
#' @param absolute Logisch: absoluten Momentum-Filter anwenden (Standard
#'   \code{TRUE}; Score < 0 => sichere Anlage).
#' @param canary Optional Zeichenvektor der Canary-Anlagen (Standard
#'   \code{NULL} = kein Canary-Schutz).
#' @param breadth Schutzschwelle \eqn{B} als Anzahl Anlagen (mindestens 1;
#'   Standard \code{NULL} = Anzahl Canary-Anlagen).
#'   Seit 1.6.4 ganze Zahl.
#' @param lookbacks,type Siehe [momentum_score()] (Rueckblicke in Monaten;
#'   \code{"average"} oder \code{"13612w"}).
#' @param every Entscheidungsrhythmus: \code{"month"} (Standard),
#'   \code{"week"} (ISO-Woche) oder \code{"quarter"}.
#' @param weighting Gewichtung der gewaehlten Anlagen: \code{"equal"}
#'   (Standard) oder \code{"inverse_vol"} (umgekehrt proportional zur
#'   Wurzel der mittleren quadrierten Log-Renditen der letzten 63 Zeilen).
#'   Seit 1.6.4 liegen die Termine dann erst ab Zeile 63 (volles Fenster; bis
#'   1.6.3 brach jeder fruehere Termin ab, mit Wochen- und Monatskursen auch mit den
#'   Standardrueckblicken).
#' @return \code{SimLevWeights} (data.frame mit \code{date} und
#'   Zielgewichten je Anlage aus \code{assets} und \code{safe}, Anteile) mit
#'   Attributen \code{scores} (Matrix der Momentum-Scores aller Anlagen je
#'   Zeile) und \code{decision_rows} (Zeilennummern der
#'   Entscheidungstermine).
#' @seealso [momentum_score()], [tactical_simulation()], [tactical_blend()]
#' @examples
#' set.seed(1); n <- 4 * 365
#' d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
#' d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
#' d$anleihen <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.003))
#' d$geld <- 100 * cumprod(rep(1 + 0.01 / 365, n))
#' w <- tactical_rotation(d, assets = c("aktien", "anleihen"), safe = "geld")
#' w
#' head(attr(w, "scores")[attr(w, "decision_rows"), ], 3)
#' @references Antonacci, G. (2014), Dual Momentum Investing; Keller, W. J. &
#'   Keuning, J. W. (2018), Breadth Momentum and the Canary Universe: Defensive
#'   Asset Allocation (DAA), SSRN 3212862.
#' @export
tactical_rotation <- function(data, assets, top = 1L, safe = NULL, absolute = TRUE, canary = NULL, breadth = NULL,
                              lookbacks = c(1, 3, 6, 12), type = c("average", "13612w"),
                              every = c("month", "week", "quarter"), weighting = c("equal", "inverse_vol")) {
  fn <- "tactical_rotation"
  .e5_choice(type, c("average", "13612w"), fn, "type")   # Pruefung (Meldung auswahl)
  type <- match.arg(type)
  .e5_choice(every, c("month", "week", "quarter"), fn, "every")   # Pruefung (Meldung auswahl)
  every <- match.arg(every)
  .e5_choice(weighting, c("equal", "inverse_vol"), fn, "weighting")   # Pruefung (Meldung auswahl)
  weighting <- match.arg(weighting)
  # seit 1.6.4 (K42 E5): Datum, Namen, Wahrheitswert, ganze Zahlen; Meldungen ohne Eingabewert (Entscheidung 8)
  .e5_data_dates(data, fn, "momentum_score: data$date")
  .e5_names(assets, fn, "assets")
  .e5_names(safe, fn, "safe", null_ok = TRUE)
  .e5_names(canary, fn, "canary", null_ok = TRUE)
  chk_bool1(absolute, fn, "absolute")
  .e5_lookbacks(lookbacks, fn)
  if ((absolute || length(canary)) && !length(safe)) stop("absolute bzw. canary brauchen eine sichere Anlage 'safe'.")
  chk_int1(top, fn, "top", lo = 1)
  top <- as.integer(top)
  if (length(top) != 1L || is.na(top) || top < 1L || top > length(assets))
    stop(sprintf("top muss zwischen 1 und der Anzahl der Anlagen in assets (%d) liegen.", length(assets)))
  if (!is.null(breadth)) chk_int1(breadth, fn, "breadth", lo = 1)
  if (length(canary) && !is.null(breadth) && (length(breadth) != 1L || is.na(breadth) || breadth < 1))
    stop("breadth muss mindestens 1 sein (Anzahl Canary-Anlagen mit negativem Score f\u00fcr vollen Schutz).")
  allc <- unique(c(assets, safe, canary))
  S <- momentum_score(data, allc, lookbacks, type)
  d <- .to_date(data$date, "data$date"); n <- length(d)
  rows <- .period_last(d, every)
  rows <- rows[apply(S[rows, assets, drop = FALSE], 1, function(z) sum(is.finite(z)) >= top)]
  # inverse_vol: Termine erst ab Zeile 63, wenn das Fenster der Schwankung voll ist (seit 1.6.4, Entscheidung 144;
  # bis 1.6.3 Abbruch "Zeilen ohne positive Gewichte" bei jedem frueheren Termin)
  if (weighting == "inverse_vol") rows <- rows[rows >= 63L]
  if (!length(rows)) stop("Zu kurze Historie f\u00fcr den R\u00fcckblick.")
  out_assets <- unique(c(assets, safe))
  vol <- if (weighting == "inverse_vol") vapply(assets, function(a) {
    r <- c(NA, diff(log(.fill_na(as.numeric(data[[a]]), "locf", keep_leading = TRUE))))
    sqrt(pmax(.roll_mean(ifelse(is.na(r), 0, r)^2, 63), 1e-12))
  }, numeric(n)) else NULL
  M <- t(vapply(rows, function(i) {
    w <- stats::setNames(rep(0, length(out_assets)), out_assets)
    sc <- S[i, assets]; ok <- which(is.finite(sc))
    pick <- assets[ok][order(sc[ok], decreasing = TRUE)][seq_len(min(top, length(ok)))]
    best_safe <- if (length(safe)) { ss <- S[i, safe]; if (all(!is.finite(ss))) safe[1] else safe[which.max(ss)] } else NULL
    pw <- if (weighting == "equal") rep(1 / length(pick), length(pick)) else { iv <- 1 / vol[i, pick]; iv / sum(iv) }
    cash <- 0
    if (length(canary)) {
      b <- sum(S[i, canary] < 0, na.rm = TRUE); B <- breadth %||% length(canary)
      cash <- min(1, b / B)
    }
    for (k in seq_along(pick)) {
      share <- pw[k] * (1 - cash)
      if (absolute && is.finite(S[i, pick[k]]) && S[i, pick[k]] < 0) w[best_safe] <- w[best_safe] + share
      else w[pick[k]] <- w[pick[k]] + share
    }
    if (cash > 0) w[best_safe] <- w[best_safe] + cash
    w
  }, numeric(length(out_assets))))
  if (!is.matrix(M)) M <- matrix(M, ncol = length(out_assets))
  colnames(M) <- out_assets
  H <- .hold_rows(n, rows, M)
  first <- rows[1]; H[seq_len(first - 1L), ] <- 0
  if (first > 1L) H[seq_len(first - 1L), if (length(safe)) safe[1] else assets[1]] <- 1
  out <- .as_weights(d, H, "rotation")
  attr(out, "scores") <- S; attr(out, "decision_rows") <- rows
  out
}

#' Zielvolatilitaet
#'
#' Skaliert den Risikoteil einer Gewichtsreihe so, dass die geschaetzte
#' Volatilitaet des Risikoportfolios dem Ziel entspricht; der Rest geht in
#' die sichere Anlage. Die Volatilitaet wird aus den Tagesrenditen der
#' Risikoanlagen mit den aktuellen Gewichten ueber \code{window} Zeilen mit
#' Kursbewegung geschaetzt (Tage ohne Bewegung, etwa Wochenenden, zaehlen
#' nicht).
#'
#' Der Risikoanteil (Exposure) ist \code{min(max_exposure, (target / 100) /
#' vol)} mit der geschaetzten Volatilitaet \code{vol} als Anteil p. a.; er
#' wird an den Terminen von \code{every} (letzte vorhandene Zeile je
#' Periode) neu gesetzt und bis zum naechsten Termin gehalten. Vor dem
#' ersten Termin mit vollem Fenster ist der Risikoanteil 0 (alles in
#' \code{safe}); anders als bei [tactical_conditional_volatility()], wo vorher der
#' Grundanteil \code{base} gilt (hier gibt es keinen Grundanteil). \code{every} legt nur den Anpassungsrhythmus der
#' Zielgewichte fest; gehandelt wird in [tactical_simulation()].
#'
#' @param data data.frame mit Spalte \code{date} (Klasse Date) und
#'   Kursspalten (Niveaus) der Risikoanlagen und der sicheren Anlage.
#' @param weights Gewichte des Risikoportfolios: \code{SimLevWeights} (z. B.
#'   aus [tactical_rotation()]) oder benannter Gewichtsvektor (Anteile,
#'   statisch). Eine darin enthaltene sichere Anlage zaehlt nicht zum
#'   Risikoteil.
#' @param safe Name der Kursspalte der sicheren Anlage (Zeichenkette).
#' @param target Zielvolatilitaet in Prozent p. a. (10 = 10 %; Standard 10).
#'   Werte unter 1 ergeben eine Warnung (vermutlich als Anteil angegeben).
#' @param window Fensterlaenge der Volatilitaetsschaetzung in Zeilen mit
#'   Kursbewegung (Standard 63).
#'   Seit 1.6.4 ganze Zahl >= 2.
#' @param max_exposure Hoechster Risikoanteil als Anteil (Standard 1 = ohne
#'   Hebel; Werte > 1 sind nicht erlaubt, da die Engine keinen Kredit
#'   kennt).
#' @param every Anpassungsrhythmus des Risikoanteils: \code{"month"}
#'   (Standard), \code{"week"}, \code{"day"} oder \code{"quarter"}.
#' @param ppy Tage mit Kursbewegung je Jahr fuer die Annualisierung.
#'   Standard \code{NULL} = aus den Daten ermittelt (Zahl der Tage mit
#'   Bewegung geteilt durch die Laenge des Zeitraums in Jahren, z. B. rund
#'   252 bei Boersentagen, 365 bei
#'   einem Index, der auch am Wochenende notiert).
#' @return \code{SimLevWeights} (data.frame mit \code{date} und
#'   Zielgewichten der Risikoanlagen und von \code{safe}, Anteile) mit
#'   Attributen \code{exposure} (Risikoanteil je Zeile, Anteil) und
#'   \code{volatility} (geschaetzte Volatilitaet des Risikoportfolios je
#'   Zeile, Anteil p. a., 0.15 = 15 %).
#' @seealso [tactical_conditional_volatility()], [tactical_simulation()],
#'   [tactical_blend()]
#' @examples
#' set.seed(1); n <- 4 * 365
#' d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
#' d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
#' d$anleihen <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.003))
#' d$geld <- 100 * cumprod(rep(1 + 0.01 / 365, n))
#' tv <- tactical_target_volatility(d, c(aktien = 0.8, anleihen = 0.2), safe = "geld", target = 8)
#' tv
#' summary(attr(tv, "exposure"))
#' @references Moreira, A. & Muir, T. (2017), Volatility-Managed Portfolios,
#'   Journal of Finance 72(4).
#' @export
tactical_target_volatility <- function(data, weights, safe, target = 10, window = 63L, max_exposure = 1,
                              every = c("month", "week", "day", "quarter"), ppy = NULL) {
  fn <- "tactical_target_volatility"
  .e5_choice(every, c("month", "week", "day", "quarter"), fn, "every")   # Pruefung (Meldung auswahl)
  every <- match.arg(every)
  .e5_risk_check(fn, data, weights, safe, window, ppy)    # seit 1.6.4 (K42 E5)
  chk_num1(target, fn, "target", lo = 0, lo_open = TRUE)
  chk_num1(max_exposure, fn, "max_exposure", lo = 0)
  if (max_exposure > 1) stop("max_exposure > 1 w\u00e4re Kredit; die Engine kennt keine Kreditaufnahme (Hebel \u00fcber Hebelprodukte abbilden).")
  if (target < 1) warning(sprintf("target = %g ist sehr klein; target ist in Prozent p. a. (10 = 10 %%), nicht als Anteil.", target))
  rv <- .risk_vol(data, weights, safe, window, ppy)
  n <- rv$n; vol <- rv$vol
  rows <- .period_last(rv$d, every); rows <- rows[is.finite(vol[rows])]
  if (!length(rows)) stop("Zu kurze Historie f\u00fcr das Volatilit\u00e4tsfenster.")
  expo_r <- pmin(max_exposure, target / 100 / pmax(vol[rows], 1e-6))
  k <- findInterval(seq_len(n), rows); expo <- ifelse(k > 0, expo_r[pmax(k, 1L)], 0)
  out <- .risk_weights(rv, expo, safe, "target_volatility")
  attr(out, "exposure") <- expo; attr(out, "volatility") <- vol
  out
}

# Gemeinsame Pruefung der Volatilitaetssteuerung (seit 1.6.4, K42 E5): data mit Datum, weights (SimLevWeights oder
# benannte Gewichte), safe (eine Kursspalte), window ganze Zahl >= 2, ppy NULL oder Zahl > 0, Kursspalten numerisch
.e5_risk_check <- function(fn, data, weights, safe, window, ppy) {
  .e5_data_dates(data, fn, "data$date")
  if (!inherits(weights, "SimLevWeights")) {
    if (!is.numeric(weights) || is.null(names(weights))) stop("weights: SimLevWeights oder benannter Gewichtsvektor erwartet.")
    .e5_weights(weights, fn, "weights")
  }
  chk_name1(safe, fn, "safe")
  chk_int1(window, fn, "window", lo = 2)
  chk_num1(ppy, fn, "ppy", lo = 0, lo_open = TRUE, null_ok = TRUE)
  .e5_numcols(data, intersect(c(setdiff(names(weights), "date"), safe), names(data)), fn)
  invisible(NULL)
}

#' Volatilitaet des Risikoportfolios (gemeinsam fuer Zielvolatilitaet und
#' bedingte Volatilitaetssteuerung)
#' @keywords internal
#' @noRd
.risk_vol <- function(data, weights, safe, window, ppy) {
  d <- .to_date(data$date, "data$date"); n <- length(d)
  if (!inherits(weights, "SimLevWeights")) {
    if (!is.numeric(weights) || is.null(names(weights))) stop("weights: SimLevWeights oder benannter Gewichtsvektor erwartet.")
    weights <- .as_weights(d, matrix(weights, n, length(weights), byrow = TRUE, dimnames = list(NULL, names(weights))), "static")
  }
  if (!safe %in% names(data)) stop(sprintf("Sichere Anlage '%s' fehlt in data.", safe))
  risky <- setdiff(names(weights)[-1], safe)
  miss <- setdiff(risky, names(data))
  if (length(miss)) stop(sprintf("Kursspalte(n) aus weights fehlen in data: %s", paste(miss, collapse = ", ")))
  if (nrow(weights) != n || !identical(as.numeric(weights$date), as.numeric(d)))
    stop("weights passt nicht zu data (andere Daten); Gewichte aus demselben Datensatz erzeugen.")
  Wr <- as.matrix(weights[, risky, drop = FALSE])
  R <- vapply(risky, function(a) { x <- .fill_na(as.numeric(data[[a]]), "locf", keep_leading = TRUE); c(0, x[-1] / x[-n] - 1) }, numeric(n))
  if (!is.matrix(R)) R <- matrix(R, ncol = length(risky))
  R[!is.finite(R)] <- 0
  rs <- rowSums(Wr); Wn <- Wr / ifelse(rs > 0, rs, 1)
  pr <- c(0, rowSums(Wn[-n, , drop = FALSE] * R[-1, , drop = FALSE]))    # Gewichte vom Vortag
  move <- abs(pr) > 0
  if (is.null(ppy)) ppy <- sum(move) / max(as.numeric(d[n] - d[1]) / 365.25, 1e-9)
  vol <- rep(NA_real_, n); idx <- which(move)
  if (length(idx) > window) {
    v <- .roll_var(pr[idx], window)
    vol[idx] <- sqrt(pmax(v, 0) * ppy)
  }
  list(d = d, n = n, risky = risky, Wr = Wr, rs = rs, move = move, ppy = ppy,
       vol_move = vol, vol = .fill_na(vol, "locf", keep_leading = TRUE))
}

#' Risikoteil mit Exposure skalieren, Rest in die sichere Anlage
#' @keywords internal
#' @noRd
.risk_weights <- function(rv, expo, safe, source) {
  W <- cbind(rv$Wr * expo, 1 - expo * rv$rs)
  colnames(W) <- c(rv$risky, safe)
  W[W < 0] <- 0
  .as_weights(rv$d, W, source)
}

#' Bedingte Volatilitaetssteuerung
#'
#' Wie [tactical_target_volatility()], aber nur in extremen Volatilitaetsphasen: Liegt
#' die geschaetzte Volatilitaet des Risikoportfolios ueber ihrem
#' \code{upper}-Quantil, wird der Risikoanteil gesenkt, liegt sie unter dem
#' \code{lower}-Quantil, wird er erhoeht; dazwischen bleibt er beim
#' Grundanteil \code{base}. Das spart die meisten Umschichtungen (und damit
#' Steuern und Kosten) der staendigen Steuerung (Bongaerts, Kang & van Dijk
#' 2020).
#'
#' Die Quantile und der langfristige Vergleichswert werden nur aus der
#' Volatilitaet bis zum jeweiligen Tag berechnet (expandierendes Fenster,
#' monatlich aktualisiert) – ohne Blick in die Zukunft. Vor
#' \code{min_history} Jahren Historie gilt der Grundanteil.
#'
#' In einer extremen Phase ist der Risikoanteil
#' \code{base * target / vol}, oben hoechstens \code{base}, unten mindestens
#' \code{base}, begrenzt auf \code{[min_exposure, max_exposure]}. Weil die
#' Engine keinen Kredit kennt, ist \code{max_exposure} hoechstens 1;
#' Hochskalieren setzt daher \code{base < max_exposure} voraus.
#'
#' Einheiten: \code{base}, \code{min_exposure}, \code{max_exposure},
#' \code{high_exposure} und \code{low_exposure} sind Anteile des Depots
#' (0.8 = 80 %), \code{upper} und \code{lower} Quantil-Wahrscheinlichkeiten
#' (0 bis 1), \code{target} Prozent p. a. (10 = 10 %). Die geschaetzte
#' Volatilitaet und die Schwellen in \code{thresholds} sind Anteile p. a.
#' (0.15 = 15 %). Vor dem ersten Termin von \code{every} gilt der
#' Grundanteil \code{base}.
#'
#' @inheritParams tactical_target_volatility
#' @param base Grundanteil des Risikoportfolios in normalen Phasen als
#'   Anteil (0 bis \code{max_exposure}; Standard 1).
#' @param upper Quantil-Wahrscheinlichkeit (zwischen 0 und 1), ab der die
#'   Volatilitaet als hoch gilt (Standard 0.8 = oberstes Fuenftel der
#'   bisherigen Werte).
#' @param lower Quantil-Wahrscheinlichkeit (zwischen 0 und \code{upper}),
#'   unter der sie als niedrig gilt (Standard 0.2); \code{NULL} schaltet das
#'   Hochskalieren ab.
#' @param target Vergleichsvolatilitaet in Prozent p. a. (10 = 10 %);
#'   Standard \code{NULL} = Mittel der bisherigen Volatilitaet
#'   (expandierend, monatlich aktualisiert).
#' @param min_exposure,max_exposure Untere und obere Grenze des
#'   Risikoanteils als Anteil (Standard 0 und 1; \code{min_exposure} hoechstens
#'   \code{base}, \code{max_exposure} hoechstens 1).
#' @param min_history Mindesthistorie der Volatilitaetsschaetzung in Jahren
#'   (Standard 3), bevor gesteuert wird. Ist sie laenger als die vorhandene
#'   Historie, wird nie gesteuert (mit Warnung).
#'   Seit 1.6.4 hoechstens 100 Jahre.
#' @param scaling \code{"inverse"} (Standard): Anteil
#'   \code{base * target / vol}; \code{"fixed"}: feste Anteile
#'   \code{high_exposure} und \code{low_exposure}.
#' @param high_exposure,low_exposure Feste Risikoanteile (Anteile) fuer
#'   \code{scaling = "fixed"} in hohen bzw. niedrigen Phasen;
#'   \code{high_exposure} hoechstens \code{base}, \code{low_exposure}
#'   zwischen \code{base} und \code{max_exposure} (Pflicht, wenn
#'   \code{lower} gesetzt ist).
#' @return \code{SimLevWeights} (data.frame mit \code{date} und
#'   Zielgewichten, Anteile) mit Attributen \code{exposure} (Risikoanteil je
#'   Zeile, Anteil), \code{volatility} (geschaetzte Volatilitaet, Anteil
#'   p. a.), \code{state} (Phase am letzten Anpassungstermin, je Zeile
#'   fortgeschrieben: -1 niedrig, 0 normal, 1 hoch) und \code{thresholds}
#'   (data.frame mit \code{date}, \code{lower}, \code{upper} und
#'   \code{target} als Anteile p. a., wie sie zum jeweiligen Monatsende
#'   bekannt waren; NA vor \code{min_history}).
#' @seealso [tactical_target_volatility()], [tactical_simulation()]
#' @references Bongaerts, D., Kang, X. & van Dijk, M. (2020), Conditional
#'   Volatility Targeting, Financial Analysts Journal 76(4), 54-71.
#' @examples
#' set.seed(1); n <- 365 * 12
#' d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = n),
#'                 aktien = 100 * exp(cumsum(rnorm(n, 0.0002, 0.01 * exp(sin(seq_len(n) / 300))))),
#'                 geld = 100 * cumprod(rep(1 + 0.01 / 365, n)))
#' cv <- tactical_conditional_volatility(d, c(aktien = 1), safe = "geld", base = 0.8)
#' cv
#' table(attr(cv, "state"))
#' @export
tactical_conditional_volatility <- function(data, weights, safe, base = 1, upper = 0.8, lower = 0.2, target = NULL,
                                   window = 63L, min_exposure = 0, max_exposure = 1, min_history = 3,
                                   scaling = c("inverse", "fixed"), high_exposure = NULL, low_exposure = NULL,
                                   every = c("month", "week", "day", "quarter"), ppy = NULL) {
  fn <- "tactical_conditional_volatility"
  .e5_choice(every, c("month", "week", "day", "quarter"), fn, "every")   # Pruefung (Meldung auswahl)
  every <- match.arg(every)
  .e5_choice(scaling, c("inverse", "fixed"), fn, "scaling")   # Pruefung (Meldung auswahl)
  scaling <- match.arg(scaling)
  # seit 1.6.4 (K42 E5): einzelne endliche Zahlen vor den Bereichspruefungen (B-012: NA lief in Python/Julia still)
  .e5_risk_check(fn, data, weights, safe, window, ppy)
  for (a in c("base", "upper", "min_exposure", "max_exposure")) chk_num1(get(a), fn, a)
  for (a in c("lower", "target", "high_exposure", "low_exposure")) chk_num1(get(a), fn, a, null_ok = TRUE)
  if (!is.null(target)) chk_num1(target, fn, "target", lo = 0, lo_open = TRUE)
  chk_num1(min_history, fn, "min_history", lo = 0)
  chk_max(min_history, 100, fn, "min_history")             # Entscheidung 46
  if (max_exposure > 1) stop("max_exposure > 1 w\u00e4re Kredit; die Engine kennt keine Kreditaufnahme (Hebel \u00fcber Hebelprodukte abbilden).")
  if (base < 0 || base > max_exposure) stop("base muss zwischen 0 und max_exposure liegen.")
  if (min_exposure < 0 || min_exposure > base) stop("min_exposure muss zwischen 0 und base liegen.")
  if (!(upper > 0 && upper < 1)) stop("upper muss zwischen 0 und 1 liegen.")
  if (!is.null(lower) && !(lower > 0 && lower < upper)) stop("lower muss zwischen 0 und upper liegen.")
  if (scaling == "fixed") {
    if (is.null(high_exposure) || (!is.null(lower) && is.null(low_exposure)))
      stop("scaling = 'fixed' braucht high_exposure (und low_exposure, wenn lower gesetzt ist).")
    if (high_exposure > base) stop("high_exposure darf nicht \u00fcber base liegen.")
    if (!is.null(lower) && (low_exposure < base || low_exposure > max_exposure)) stop("low_exposure muss zwischen base und max_exposure liegen.")
  }
  if (!is.null(target) && target < 1) warning(sprintf("target = %g ist sehr klein; target ist in Prozent p. a. (10 = 10 %%), nicht als Anteil.", target))
  if (!is.null(lower) && base >= max_exposure)
    message("Hinweis: base = max_exposure; in ruhigen Phasen kann nicht hochskaliert werden (ohne Kredit). base < max_exposure w\u00e4hlen oder lower = NULL setzen.")
  rv <- .risk_vol(data, weights, safe, window, ppy)
  d <- rv$d; n <- rv$n; vol <- rv$vol
  # Schwellen und Vergleichswert je Monatsende, nur aus bisherigen Werten
  grid <- .period_last(d, "month")
  ok <- which(is.finite(rv$vol_move))
  first_ok <- if (length(ok)) d[ok[1]] else d[n] + 1
  cs <- cumsum(ifelse(is.finite(rv$vol_move), rv$vol_move, 0)); cn <- cumsum(is.finite(rv$vol_move))
  # seit 1.6.3 beide Quantile in einem Aufruf (eine Teilsortierung, dieselben Ordnungsstatistiken und dieselbe Formel
  # je Wahrscheinlichkeit) und die bisherigen Werte als Anfang von ok (ok ist aufsteigend)
  kg_ok <- findInterval(grid, ok)
  th <- t(vapply(seq_along(grid), function(k) {
    g <- grid[k]
    if (!length(ok) || as.numeric(d[g] - first_ok) / 365.25 < min_history) return(c(NA_real_, NA_real_, NA_real_))
    v <- rv$vol_move[ok[seq_len(kg_ok[k])]]
    q <- if (is.null(lower)) c(NA_real_, stats::quantile(v, upper, names = FALSE, type = 7))
         else stats::quantile(v, c(lower, upper), names = FALSE, type = 7)
    c(q, if (is.null(target)) cs[g] / cn[g] else target / 100)
  }, numeric(3)))
  thresholds <- data.frame(date = d[grid], lower = th[, 1], upper = th[, 2], target = th[, 3])
  if (all(is.na(th[, 2])))
    warning(sprintf("min_history = %g Jahre ist l\u00e4nger als die verf\u00fcgbare Volatilit\u00e4tshistorie (%.1f Jahre); es wird nie gesteuert (Risikoanteil = base).",
                    min_history, if (length(ok)) as.numeric(d[n] - first_ok) / 365.25 else 0))
  kg <- findInterval(seq_len(n), grid)                        # letzte bekannte Schwelle (Monatsende <= Tag)
  cur <- function(j) ifelse(kg > 0, th[pmax(kg, 1L), j], NA_real_)
  lo_t <- cur(1); up_t <- cur(2); tg <- cur(3)
  state <- integer(n)
  state[is.finite(up_t) & is.finite(vol) & vol > up_t] <- 1L
  if (!is.null(lower)) state[is.finite(lo_t) & is.finite(vol) & vol < lo_t] <- -1L
  rows <- .period_last(d, every); rows <- rows[is.finite(vol[rows])]
  if (!length(rows)) stop("Zu kurze Historie f\u00fcr das Volatilit\u00e4tsfenster.")
  e_r <- rep(base, length(rows)); s_r <- state[rows]
  if (scaling == "inverse") {
    ratio <- tg[rows] / pmax(vol[rows], 1e-6)
    e_r[s_r == 1L] <- base * pmin(1, ratio[s_r == 1L])
    e_r[s_r == -1L] <- base * pmax(1, ratio[s_r == -1L])
  } else {
    e_r[s_r == 1L] <- high_exposure
    if (!is.null(lower)) e_r[s_r == -1L] <- low_exposure
  }
  e_r <- pmin(max_exposure, pmax(min_exposure, e_r))
  k <- findInterval(seq_len(n), rows); expo <- ifelse(k > 0, e_r[pmax(k, 1L)], base)
  out <- .risk_weights(rv, expo, safe, "conditional_volatility")
  attr(out, "exposure") <- expo; attr(out, "volatility") <- vol
  attr(out, "state") <- ifelse(k > 0, s_r[pmax(k, 1L)], 0L)
  attr(out, "thresholds") <- thresholds
  out
}

#' Glidepath zwischen zwei Allokationen
#'
#' Erzeugt Zielgewichte, die sich stufenweise linear von \code{from} nach
#' \code{to} bewegen, z. B. von aktienlastig zu anleihenlastig bis zum
#' Rentenbeginn. Eine Stufe beginnt in der ersten Zeile und an der letzten
#' vorhandenen Zeile jeder Periode von \code{every}; ihr Gewicht ist
#' \eqn{(1 - p) \cdot from + p \cdot to} mit dem Zeitanteil \eqn{p} des
#' Datums zwischen \code{start} (0) und \code{end} (1), begrenzt auf 0 bis 1.
#' Vor \code{start} gilt \code{from}, nach \code{end} gilt \code{to}; bei
#' \code{start = end} wechselt die erste Stufe an oder nach diesem Datum
#' direkt auf \code{to}, \code{end} vor \code{start} ist ein Fehler. Das
#' Ergebnis geht in [tactical_simulation()] oder als Kern in
#' [tactical_blend()].
#'
#' @param data data.frame mit Spalte \code{date} (z. B. der Datensatz fuer
#'   [simulation()]) oder Datumsvektor.
#' @param from,to Benannte Gewichtsvektoren (Anteile) am Anfang und Ende;
#'   Anlagen, die nur in einem vorkommen, erhalten im anderen 0. Je Zeile auf
#'   Summe 1 normiert.
#' @param start,end Beginn und Ende des Uebergangs (Date oder
#'   \code{"JJJJ-MM-TT"}; Standard \code{NULL} = erstes bzw. letztes Datum).
#'   Seit 1.6.4 keine Zahl.
#' @param every Rhythmus der Stufen: \code{"year"} (Standard),
#'   \code{"quarter"} oder \code{"month"}.
#' @return \code{SimLevWeights} (data.frame mit \code{date} und
#'   Zielgewichten je Anlage, Anteile).
#' @seealso [tactical_blend()], [tactical_simulation()]
#' @examples
#' gp <- tactical_glidepath(seq.Date(as.Date("2025-01-01"), as.Date("2045-12-31"), by = "day"),
#'                 from = c(aktien = 0.9, anleihen = 0.1), to = c(aktien = 0.4, anleihen = 0.6))
#' gp[c(1, 3653, 7670), ]
#' @export
tactical_glidepath <- function(data, from, to, start = NULL, end = NULL, every = c("year", "quarter", "month")) {
  fn <- "tactical_glidepath"
  .e5_choice(every, c("year", "quarter", "month"), fn, "every")   # Pruefung (Meldung auswahl)
  every <- match.arg(every)
  # seit 1.6.4 (K42 E5): Datum ohne NA und aufsteigend, Gewichte benannt endlich >= 0, start/end Datum
  if (is.data.frame(data)) d <- .e5_data_dates(data, fn, "tactical_glidepath: Datum")
  else {
    chk_nofactor(data, fn, "data")
    if (!length(data)) chk_stop("zeilen_keine", fn, "data")
    d <- .to_date(data, "tactical_glidepath: Datum")
    if (anyNA(d) || is.unsorted(d)) chk_stop("e5.datum_vektor", fn, "data")
  }
  .e5_weights(from, fn, "from"); .e5_weights(to, fn, "to")
  start <- chk_date1(start, fn, "start", null_ok = TRUE); end <- chk_date1(end, fn, "end", null_ok = TRUE)
  a <- unique(c(names(from), names(to)))
  f <- stats::setNames(rep(0, length(a)), a); f[names(from)] <- from
  t <- stats::setNames(rep(0, length(a)), a); t[names(to)] <- to
  s <- .to_date(start %||% d[1], "start"); e <- .to_date(end %||% d[length(d)], "end")
  if (e < s) stop("tactical_glidepath: end liegt vor start; f\u00fcr den umgekehrten Weg from und to tauschen.")
  rows <- unique(c(1L, .period_last(d, every)))
  frac <- if (e > s) pmin(1, pmax(0, as.numeric(d[rows] - s) / as.numeric(e - s)))
          else as.numeric(d[rows] >= s)                       # start = end: Sprung von from auf to
  M <- t(vapply(frac, function(p) (1 - p) * f + p * t, numeric(length(a)))); colnames(M) <- a
  H <- .hold_rows(length(d), rows, M)
  .as_weights(d, H, "glidepath")
}

#' Gewichtsreihen mischen (Kern-Satellit)
#'
#' Mischt mehrere Zielgewichtsreihen zu einer, z. B. einen statischen Kern
#' oder [tactical_glidepath()] mit einem taktischen Satelliten aus
#' [tactical_rotation()]: Je Zeile und Anlage ist das Gewicht
#' \eqn{\sum_k shares_k \cdot w_k}, anschliessend auf Summe 1 normiert.
#' Anlagen, die in einer Reihe fehlen, zaehlen dort mit 0. Alle Reihen
#' muessen dieselben Daten haben (z. B. aus demselben Datensatz erzeugt).
#'
#' @param ... \code{SimLevWeights} (in der Regel zwei oder mehr) mit identischer Spalte
#'   \code{date} (Namen werden nicht verwendet).
#' @param shares Numerischer Vektor der Anteile je Reihe in der Reihenfolge
#'   von \code{...} (z. B. \code{c(0.7, 0.3)}; genau ein nichtnegativer Wert
#'   je Reihe); Standard \code{NULL} = gleiche Anteile.
#' @return \code{SimLevWeights} (data.frame mit \code{date} und
#'   Zielgewichten aller Anlagen, Anteile) fuer [tactical_simulation()].
#' @seealso [tactical_glidepath()], [tactical_rotation()], [tactical_target_volatility()],
#'   [tactical_simulation()]
#' @examples
#' set.seed(1); n <- 4 * 365
#' d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
#' d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
#' d$anleihen <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.003))
#' d$geld <- 100 * cumprod(rep(1 + 0.01 / 365, n))
#' kern <- tactical_glidepath(d, from = c(aktien = 0.8, anleihen = 0.2), to = c(aktien = 0.5, anleihen = 0.5))
#' satellit <- tactical_rotation(d, c("aktien", "anleihen"), safe = "geld")
#' tactical_blend(kern, satellit, shares = c(0.7, 0.3))
#' @export
tactical_blend <- function(..., shares = NULL) {
  ws <- list(...)
  if (!length(ws) || !all(vapply(ws, inherits, TRUE, "SimLevWeights"))) stop("tactical_blend: ... muss aus SimLevWeights bestehen.")
  shares <- shares %||% rep(1 / length(ws), length(ws))
  if (!is.numeric(shares) || is.factor(shares) || length(shares) != length(ws) || !all(is.finite(shares)) ||
      any(shares < 0) || sum(shares) <= 0)                 # seit 1.6.4 ohne Eingabewert, endlich (Entscheidung 8)
    stop(sprintf("tactical_blend: shares braucht %d nichtnegative Anteile (einen je Gewichtsreihe, z. B. c(0.7, 0.3)).",
                 length(ws)))
  d <- ws[[1]]$date
  if (!all(vapply(ws, function(w) identical(as.numeric(w$date), as.numeric(d)), TRUE))) stop("tactical_blend: unterschiedliche Daten.")
  a <- unique(unlist(lapply(ws, function(w) names(w)[-1])))
  W <- matrix(0, length(d), length(a), dimnames = list(NULL, a))
  for (k in seq_along(ws)) for (nm in names(ws[[k]])[-1]) W[, nm] <- W[, nm] + shares[k] * ws[[k]][[nm]]
  .as_weights(d, W, "blend")
}

#' @export
print.SimLevWeights <- function(x, ...) {
  W <- as.matrix(x[, -1, drop = FALSE])
  ch <- rowSums(abs(W[-1, , drop = FALSE] - W[-nrow(W), , drop = FALSE])) > 1e-9
  cat(sprintf("SimLev-Zielgewichte (%s): %d Tage, %s bis %s, %d Wechsel\n", attr(x, "source") %||% "",
              nrow(x), format(x$date[1]), format(x$date[nrow(x)]), sum(ch)))
  m <- rbind(Mittel = colMeans(W), Min = apply(W, 2, min), Max = apply(W, 2, max), Zuletzt = W[nrow(W), ])
  print(round(100 * m, 1))
  st <- attr(x, "state")
  if (!is.null(st)) cat(sprintf("\nVolatilit\u00e4tsphasen (Anteil der Tage): niedrig %.0f %%, normal %.0f %%, hoch %.0f %%\n",
                                100 * mean(st == -1L), 100 * mean(st == 0L), 100 * mean(st == 1L)))
  invisible(x)
}

#' @export
plot.SimLevWeights <- function(x, main = "Zielgewichte", ...) {
  W <- as.matrix(x[, -1, drop = FALSE]); d <- x$date
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  graphics::par(mar = c(3.6, 4.2, 2.6, 7), mgp = c(2.4, 0.6, 0), las = 1, cex.axis = 0.85, xpd = FALSE)
  cols <- grDevices::colorRampPalette(c("#2C6E9B", "#3E8E5A", "#C49A2C", "#B5562B", "#8A5BA8", "#4A4A4A"))(ncol(W))
  graphics::plot(range(d), c(0, 1), type = "n", xlab = "", ylab = "Gewicht", main = main, ...)
  cum <- cbind(0, t(apply(W, 1, cumsum)))
  for (j in seq_len(ncol(W)))
    graphics::polygon(c(d, rev(d)), c(cum[, j + 1], rev(cum[, j])), col = cols[j], border = NA)
  graphics::par(xpd = TRUE)
  graphics::legend(graphics::par("usr")[2], 1, colnames(W), fill = cols, bty = "n", cex = 0.8, border = NA)
  invisible(x)
}

#' Taktische Allokation simulieren
#'
#' Uebersetzt eine Zielgewichtsreihe in Ereignis-Rebalancing von
#' [simulation()]: An Wechselterminen (Zielgewicht aendert sich) und an
#' optionalen Pflegeterminen wird auf die Zielgewichte umgeschichtet, mit
#' Steuern, Spreads und allen weiteren Einstellungen der Engine. Die Engine
#' selbst bleibt unveraendert (\code{event_col}, \code{event_mode =
#' "replace"}, \code{event_weight}).
#'
#' \itemize{
#'   \item \code{every} vs. \code{rebalance}: Das Argument \code{every} der
#'     Gewichts-Erzeuger ([tactical_rotation()], [tactical_target_volatility()],
#'     [tactical_glidepath()] usw.) bestimmt, wann sich das Zielgewicht aendern kann.
#'     \code{rebalance} hier bestimmt, wann zusaetzlich ohne Zielwechsel auf
#'     die aktuellen Zielgewichte zurueckgefuehrt wird. Gehandelt wird an
#'     jedem Wechsel (nach \code{lag}) und an den Pflegeterminen.
#'   \item \code{lag}: Ein Zielgewicht, das nach Schluss von Tag t bekannt
#'     ist, wird nach \code{lag} Zeilen von \code{data} gehandelt (Standard
#'     1 = naechste Zeile, bei Kalendertagsdaten also der naechste
#'     Kalendertag; 0 = am selben Schlusskurs, wie bei vielen
#'     Online-Backtestern). Traegt \code{data} das Attribut \code{filled}
#'     aus [series_align()], zaehlen nur Zeilen, in denen alle Anlagen der
#'     Gewichte echte (nicht gefuellte) Kurse haben: Ein Signal vom Freitag
#'     wird mit \code{lag = 1} am Montag gehandelt, nicht am Samstag zum
#'     Freitagskurs. Das Attribut wird an [simulation()] weitergereicht.
#'   \item \code{rebalance}: \code{"switch"} (Standard; nur bei Wechseln)
#'     oder ein Rhythmus (\code{"month"}, \code{"quarter"}, \code{"year"};
#'     jeweils letzte vorhandene Zeile der Periode), zu dem zusaetzlich auf
#'     die aktuellen Zielgewichte zurueckgefuehrt wird.
#'   \item \code{tolerance}: Toleranzband in Prozent (wird als
#'     \code{rebalance_plan(thresh = tolerance)} an [simulation()] uebergeben); an Terminen, an
#'     denen keine Anlage staerker als das Band vom Ziel abweicht, wird nicht
#'     gehandelt. Gilt auch fuer Wechseltermine.
#'   \item Umschichtungen nutzen die Rebalancing-Logik der Engine, die mit den
#'     Ist-Gewichten des letzten Bewertungsstands (Vortag) rechnet; nach einem
#'     Wechsel koennen daher Reste in der Groessenordnung der Tagesbewegung
#'     (meist unter einem Prozent) in der verlassenen Anlage bleiben. Ein Pflegerhythmus (\code{rebalance =
#'     "month"}) gleicht sie aus.
#'   \item Sparplaene (\code{dca = dca_plan(...)}) zahlen nach den Startgewichten ein; der
#'     Sparplantag wird zum Rebalancing-Termin, so dass die Rate sofort auf die
#'     aktuellen Zielgewichte verteilt wird.
#' }
#'
#' @param data data.frame mit Spalte \code{date} (Klasse Date) und
#'   Kursspalten (Niveaus) aller Anlagen der Gewichte (z. B. mit
#'   [series_align()] vorbereitet). Fehlende Kalendertage fuellt
#'   [simulation()] selbst.
#' @param weights \code{SimLevWeights} (aus [tactical_rules()],
#'   [tactical_rotation()], [tactical_target_volatility()], [tactical_conditional_volatility()], [tactical_glidepath()],
#'   [tactical_blend()] oder [portfolio_rolling()]). Daten von
#'   \code{data}, die in \code{weights} fehlen, uebernehmen das letzte
#'   bekannte Zielgewicht.
#' @param rebalance Pflegerhythmus: \code{"switch"} (Standard; nur bei
#'   Wechseln), \code{"month"}, \code{"quarter"} oder \code{"year"}.
#' @param tolerance Toleranzband in Prozent (5 = 5 %; Standard \code{NULL} =
#'   an jedem Termin handeln).
#' @param tolerance_type Messung der Abweichung fuer \code{tolerance}:
#'   \code{"absolute"} (Standard; Prozentpunkte des Gewichts: bei 5 und
#'   Ziel 40 % wird gehandelt, wenn eine Anlage unter 35 % oder ueber 45 %
#'   liegt) oder \code{"relative"} (Prozent des Zielgewichts).
#' @param lag Verzoegerung in Zeilen von \code{data} (ganze Zahl >= 0,
#'   Standard 1); mit Attribut \code{filled} in Zeilen mit echten Kursen.
#'   Seit 1.6.4 ohne Abschneiden (1.5 und Text sind ein Fehler).
#' @param asset_args Liste von Argumenten fuer [asset_config()] (ueber
#'   [strategy_from_weights()]), z. B.
#'   \code{list(spread = 0.1, partial_exemption = c(aktien = 30, geld = 0))}.
#'   Ein unbenannter einzelner Wert gilt fuer alle Anlagen; benannte Vektoren
#'   werden je Anlage zugeordnet (auch mit einem Element, siehe
#'   [strategy_from_weights()]).
#' @param ... Weitere Argumente fuer \code{\link[=simulation]{simulation()}} (z. B.
#'   \code{tax = tax_profile()}, \code{start_value}, \code{dca = dca_plan(...)}). Das
#'   Rebalancing (\code{rebalance_plan(event_col, event_mode = "replace", skip = TRUE,
#' event_weight, thresh = tolerance, thresh_type = tolerance_type)}) steuert die Funktion
#'   selbst; Pfade \code{"rebalance.*"} und die alten \code{event_col}, \code{event_mode},
#'   \code{event_weight}, \code{balance_mode}, \code{balance_thresh} sind ein Fehler.
#' @return \code{SimLevResult} wie von [simulation()] mit zusaetzlichem
#'   Element \code{tactical}, einer Liste mit \code{weights} (gehandelte,
#'   um \code{lag} verschobene Zielgewichte als \code{SimLevWeights}),
#'   \code{events} (Daten der Umschichtungstermine aus Wechseln, Pflege und
#'   Sparplan, vor Anwendung von \code{tolerance}), \code{switches} (Zahl der
#'   Zielwechsel), \code{lag} und \code{rebalance}. Das Ergebnis laesst sich
#'   mit [result_analysis()] oder [result_index()] weiterverarbeiten.
#' @seealso [simulation()], [result_analysis()], [tactical_rules()],
#'   [tactical_rotation()]
#' @examples
#' set.seed(1); n <- 4 * 365
#' d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
#' d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
#' d$geld <- 100 * cumprod(rep(1 + 0.01 / 365, n))
#' w <- tactical_rules(d, list(list(when = signal_sma(d$aktien, 200, band = 1),
#'                                  weights = c(aktien = 1))), default = c(geld = 1))
#' res <- tactical_simulation(d, w, rebalance = "switch", lag = 1,
#'                            asset_args = list(partial_exemption = c(aktien = 30, geld = 0)))
#' res$tactical$switches
#' # Zielvolatilitaet, vierteljaehrliche Pflege mit 5-Prozentpunkte-Band
#' res2 <- tactical_simulation(d, tactical_target_volatility(d, c(aktien = 1), safe = "geld", target = 10),
#'                             rebalance = "quarter", tolerance = 5)
#' result_analysis(list(Regel = res, Zielvola = res2))$metrics[c("cagr", "max_drawdown"), ]
#' @export
tactical_simulation <- function(data, weights, rebalance = c("switch", "month", "quarter", "year"),
                                tolerance = NULL, tolerance_type = c("absolute", "relative"), lag = 1L,
                                asset_args = list(), ...) {
  fn <- "tactical_simulation"
  .e5_choice(rebalance, c("switch", "month", "quarter", "year"), fn, "rebalance")   # Pruefung (Meldung auswahl)
  rebalance <- match.arg(rebalance)
  .e5_choice(tolerance_type, c("absolute", "relative"), fn, "tolerance_type")   # Pruefung (Meldung auswahl)
  tolerance_type <- match.arg(tolerance_type)
  .e5_data_dates(data, fn, "data$date")                   # seit 1.6.4 (K42 E5)
  if (!inherits(weights, "SimLevWeights")) stop("weights muss ein SimLevWeights sein.")
  chk_int1(lag, fn, "lag", lo = 0)                       # seit 1.6.4 ohne Abschneiden (Entscheidung 19)
  if (!is.list(asset_args) || is.data.frame(asset_args)) chk_stop("liste", fn, "asset_args")
  sim_args <- list(...)
  nm <- names(sim_args) %||% character(0)
  bad <- nm[nm %in% c("event_col", "event_mode", "event_weight", "balance_mode", "balance_thresh") | startsWith(nm, "rebalance.")]
  if (length(bad)) stop(sprintf("tactical_simulation steuert %s selbst.", paste(bad, collapse = ", ")))
  sim_args <- .sim_args_set(list(), sim_args, "tactical_simulation")
  assets <- names(weights)[-1]
  miss <- setdiff(assets, names(data)); if (length(miss)) stop(sprintf("Kursspalten fehlen: %s", paste(miss, collapse = ", ")))
  d <- .to_date(data$date, "data$date")
  k <- match(as.numeric(d), as.numeric(weights$date))
  W <- as.matrix(weights[, assets, drop = FALSE])[k, , drop = FALSE]
  W <- apply(W, 2, function(v) .fill_na(v, "locf", keep_leading = FALSE))
  if (!is.matrix(W)) W <- matrix(W, nrow = length(d), dimnames = list(NULL, assets))
  lag <- as.integer(lag)
  n <- nrow(W)
  if (lag > 0) {
    # Verzoegerung in Zeilen mit echten Kursen: Mit Attribut 'filled' (series_align) zaehlen per LOCF
    # gefuellte Zeilen (Wochenenden, Feiertage) einer der Anlagen nicht (sonst Handel zum alten Kurs).
    fl <- attr(data, "filled"); real <- rep(TRUE, n)
    if (is.matrix(fl) && nrow(fl) == n && length(fa <- intersect(assets, colnames(fl)))) real <- rowSums(fl[, fa, drop = FALSE]) == 0
    tr <- which(real); if (!length(tr)) tr <- seq_len(n)
    eff <- tr[findInterval(seq_len(n), tr) + lag]               # Handelszeile des nach Schluss von t bekannten Ziels
    eff[is.na(eff)] <- n + 1L
    W <- W[pmax(findInterval(seq_len(n), eff), 1L), , drop = FALSE]
  }
  change <- c(FALSE, rowSums(abs(W[-1, , drop = FALSE] - W[-n, , drop = FALSE])) > 1e-10)
  ev <- change
  if (rebalance != "switch") ev[.period_last(d, rebalance)] <- TRUE
  if (!is.null(dp <- sim_args$dca)) {
    cal <- seq.Date(d[1], d[n], by = "day")
    fl <- calculate_dates_flags(mode = TRUE, span = dp$span, unit = dp$unit, days = dp$days, dates = cal,
                                value = dp$value, anchor = dp$anchor, start_date = dp$start,
                                skip_start = dp$skip, liquidate = sim_args$liquidate %||% FALSE)
    j <- findInterval(as.numeric(cal[fl]) - 1e-9, as.numeric(d)) + 1L
    ev[j[j <= n]] <- TRUE
  }
  ev[1] <- FALSE
  df <- data
  attr(df, "filled") <- attr(data, "filled")                   # fuer simulation(): gefuellte Tage kennzeichnen
  wcols <- paste0(".tw_", assets)
  for (j in seq_along(assets)) df[[wcols[j]]] <- W[, j]
  df$.tev <- ev
  w0 <- pmax(W[1, ], 1e-9); w0 <- w0 / sum(w0)
  st <- do.call(strategy_from_weights, c(list(weights = stats::setNames(w0, assets)), asset_args))
  # Ereignis-Rebalancing nur an den Terminen, ohne Umschichten am ersten Tag (skip = TRUE)
  rb <- rebalance_plan(event_col = ".tev", event_mode = "replace", skip = TRUE,
                       event_weight = stats::setNames(as.list(wcols), assets), thresh = tolerance,
                       thresh_type = tolerance_type)
  res <- .sim_call(df, st, c(list(rebalance = rb), sim_args))
  res$tactical <- list(weights = .as_weights(d, W, attr(weights, "source")), events = d[ev], switches = sum(change), lag = lag,
                       rebalance = rebalance)
  res
}
