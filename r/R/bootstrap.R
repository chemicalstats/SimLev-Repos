# =============================================================================
#  bootstrap.R  —  Bootstrap-Pfade fuer Indizes, Hebelprodukte und Signale
# -----------------------------------------------------------------------------
#  Portierung und Verallgemeinerung von '00 Bootstraps' (boot_helper.R und
#  C++-Kerne) sowie der Studienlogik aus '06 Bootstraps':
#
#    bootstrap_config()   Spezifikation: Indizes, Hebelprodukte, Zusatzreihen
#    bootstrap()          erzeugt Preis-Pfade (im Speicher)
#    bootstrap_study()    erzeugt Pfade, berechnet Signale, simuliert
#                         Strategien mit simulation() und behaelt nur Kennzahlen
#                         (streamend, parallel, fortsetzbar)
#    bootstrap_block_length()       automatische Blocklaenge (Politis & White 2004,
#                         Korrektur Patton, Politis & White 2009)
#
#  Verfahren: raw, block, circular, stationary, wild, regime, evt, tails,
#  reset, garch, gjr_garch, ms_garch, ms_ar_garch_m, tvtp_ms_garch.
#
#  Neu gegenueber dem Original:
#    * beliebig viele Indizes (nicht nur USD/EUR), Zusatzreihen (Zins,
#      Inflation, Kalendertage) werden ueber denselben Zeilenindex mitgezogen
#    * Filtered Historical Simulation: ein gemeinsames historisches Datum je
#      Tag fuer alle Residuen (Korrelation Index/FX bleibt erhalten)
#    * Pfadlaenge frei waehlbar (length), zirkulaerer Block-Bootstrap
#    * Hebelprodukte nach MSCI-Formel mit Zinsreihe statt konstantem Satz
#    * reproduzierbare Zufallsstroeme je Pfad (unabhaengig von der Kernzahl)
# =============================================================================


# ─────────────────────────────────────────────────────────────────────────────
# Konfiguration
# ─────────────────────────────────────────────────────────────────────────────

#' Bootstrap-Konfiguration erstellen
#'
#' Beschreibt, welche Spalten eines Datensatzes gebootstrappt werden, welche
#' Hebelprodukte (LETFs) daraus je Pfad abgeleitet werden und welche
#' Zusatzreihen (Zinsen, Inflation, Kalendertage, ...) jeweils aus derselben
#' historischen Zeile mitgezogen werden. Das Ergebnis ist die Eingabe
#' \code{config} von [bootstrap()] und [bootstrap_study()].
#'
#' Eingabedaten (\code{data} in [bootstrap()]): ein data.frame oder eine
#' Matrix mit einer Zeile je Beobachtung (z. B. Kalendertage oder Handelstage)
#' und den hier genannten Spalten. Mit \code{input = "returns"} enthalten die
#' Index-Spalten Brutto-Renditen je Zeile (z. B. 1.002 fuer +0,2 Prozent), mit
#' \code{input = "prices"} Kursniveaus. Eine Datumsspalte wird nicht benoetigt
#' und nicht ausgewertet; Zeilen mit fehlenden Werten in den verwendeten
#' Spalten werden entfernt.
#'
#' @param indices Benannter Zeichenvektor oder benannte Liste: Pfadname ->
#'   Spaltenname in \code{data}, z. B.
#'   \code{c(us = "us_index_l1_return", eu = "eu_index_l1_return")}. Die
#'   Pfadnamen werden zu Spaltennamen der erzeugten Pfade.
#' @param letfs Liste von Hebelprodukten (Standard: keine). Jedes Element ist
#'   eine Liste mit
#'   \describe{
#'     \item{base}{Name des Basisindex (Pfadname aus \code{indices}), Pflicht.}
#'     \item{leverage}{Hebel L als Zahl ungleich 0 (Standard 2; negativ fuer
#'       Short-Produkte).}
#'     \item{finance}{Finanzierungszins in Prozent p. a. (3.5 = 3,5 Prozent) als
#'       Skalar oder Name einer Zusatzreihe aus \code{aux}, deren Werte
#'       ebenfalls in Prozent p. a. vorliegen (Standard 3.5).}
#'     \item{expense}{TER in Prozent p. a. (Standard 0.5; muss >= 0 sein).}
#'     \item{spread}{Spread auf den finanzierten bzw. leerverkauften Anteil
#'       \eqn{m(L)} in Prozent p. a. (Standard 0).}
#'     \item{days}{Kalendertage je Zeile: Skalar (Standard 1, passend fuer
#'       Kalendertagsdaten) oder Name einer Zusatzreihe (z. B. Datumsabstand
#'       bei Handelstagsdaten).}
#'     \item{rate_basis, ter_basis}{Tagesbasis fuer Zins und Spread bzw. TER
#'       (Standard 360 bzw. 365).}
#'     \item{name}{Spaltenname im Pfad (Standard \code{<base>_l<L>}, z. B.
#'       "eu_l2", bei negativem Hebel \code{<base>_inv<|L|>}, z. B. "us_inv1").}
#'   }
#'   Zahlen sind einzelne endliche Zahlen, \code{base} und \code{name} ein
#'   einzelner Text, \code{finance} und \code{days} eine Zahl oder ein Name aus
#'   \code{aux}; andere Werte (Vektoren, logisch, Faktor, NA) ergeben einen
#'   Fehler (seit 1.6.3).
#'   Tagesrendite (MSCI Daily Leveraged/Short, plus Fondskosten):
#'   \deqn{r = 1 + L (R - 1) + (1 - L) i \cdot d / 360 - TER \cdot d / 365
#'         - s \cdot m(L) \cdot d / 360}
#'   mit Brutto-Indexrendite \eqn{R}, Tagen je Zeile \eqn{d}, \eqn{i},
#'   \eqn{TER} und \eqn{s} als Anteil (Prozentangabe / 100) und
#'   \eqn{m(L) = \max(L-1,0) + \max(-L,0)}; 360 und 365 stehen fuer
#'   \code{rate_basis} und \code{ter_basis}. Faellt \eqn{r} auf 0 oder
#'   darunter, bleibt das Produkt ab diesem Tag bei 0 (Totalverlust). Fuer
#'   L = 2 und konstantem Zins entspricht das dem Original (Finanzierung auf
#'   L - 1); fuer Short-Produkte wird - anders als im Original - der
#'   Zinsertrag auf Kapital und Leerverkaufserloes gutgeschrieben
#'   (MSCI-Methodik: \eqn{-R + 2i}).
#' @param regime_index Pfadname des Referenzindex fuer die Verfahren
#'   "regime", "evt", "tails" und die GARCH-Familie (Standard \code{NULL} =
#'   erster Index).
#' @param aux Optional (Standard \code{NULL} = keine) benannter Zeichenvektor
#'   Zusatzreihen: Pfadname -> Spaltenname, z. B.
#'   \code{c(rate = "eu_rate", cpi = "eu_cpi")}. Zusatzreihen werden nicht
#'   simuliert, sondern aus denselben historischen Zeilen gezogen wie die
#'   Renditen; wie sie in den Pfad und in die Weiterverarbeitung eingehen,
#'   legt \code{aux_type} fest.
#' @param aux_type Optional (Standard \code{NULL} = keine Angabe) benannter
#'   Zeichenvektor: Art je Zusatzreihe, Name aus \code{aux} -> \code{"level"}
#'   oder \code{"rate"}. Ein leerer Vektor (\code{character(0)}) gilt wie
#'   \code{NULL}. Nicht genannte Reihen stehen wie \code{"rate"} mit ihren
#'   Originalwerten im Pfad, behalten aber in der Weiterverarbeitung das
#'   bisherige Verhalten (siehe unten).
#'   \describe{
#'     \item{"level"}{Niveau, z. B. ein Preisindex (CPI). Die Reihe wird in
#'       Zeilenverhaeltnisse zerlegt (Wert je Zeile / Wert der Vorzeile); der
#'       Pfad enthaelt das Niveau, das sich durch Kumulieren der Verhaeltnisse
#'       der gezogenen Zeilen ergibt. Startwert (Pfadzeile 1) ist der Wert der
#'       ersten verwendeten Historienzeile, bei \code{input = "prices"} der
#'       Wert der Zeile davor (Startzeile der Kurse). So entstehen keine
#'       Spruenge an Blockgrenzen. Bei \code{input = "returns"} hat die erste
#'       Historienzeile mangels Vorzeile das Verhaeltnis 1. Die Werte muessen
#'       positiv und endlich sein.}
#'     \item{"rate"}{Rate in Prozent pro Jahr (2 = 2 % p. a.; nicht je
#'       Datenperiode, kein Anteil wie 0.02), z. B. ein Zins oder eine
#'       Inflationsrate: Werte der gezogenen Zeilen unveraendert (keine
#'       Normierung auf 100; Pfadzeile 1 wiederholt den Wert der ersten
#'       gezogenen Zeile). Als Inflation wird die Rate je Pfadzeile ueber die
#'       Kalendertage seit der Vorzeile aufgezinst,
#'       \eqn{\prod (1 + r/100)^{Tage/365.25}}; eine konstante Rate 2 ergibt
#'       damit je Jahr \eqn{1.02^{Tage/365.25}} (1,02 bei 365,25 Tagen), bei
#'       Kalender- wie Handelstagsdaten.}
#'   }
#'   Eine ausdrueckliche Angabe gilt einheitlich in allen Funktionen, die die
#'   Reihe weiterverarbeiten: \code{keep_aux} in [bootstrap_study()],
#'   \code{inflation} in [withdrawal_paths()] und [withdrawal_simulation()]
#'   (\code{"level"} = Preisindex, \code{"rate"} = Inflationsrate in Prozent
#'   p. a.; \code{inflation_type} muss nicht erneut angegeben werden) und
#'   [withdrawal_cohorts()] mit einer Tabelle aus [bootstrap_data()].
#'   Widersprechende Angaben dort (z. B. \code{inflation_type = "level"} bei
#'   \code{"rate"}) sind ein Fehler. Ohne Angabe gilt das bisherige
#'   Verhalten: Originalwerte im Pfad; als Inflation (\code{keep_aux},
#'   [withdrawal_paths()] mit \code{inflation_type = "level"}) dient die
#'   Niveau-Variante (Attribut \code{aux_level}, siehe [bootstrap()]), also
#'   die kumulierten Zeilenverhaeltnisse, als waere die Reihe ein Preisindex;
#'   eine Rate in Prozent p. a. muss dann mit \code{inflation_type =
#'   "rate_pa"} in [withdrawal_paths()] angegeben werden. Der
#'   Finanzierungszins von Hebelprodukten (\code{finance}) ist ebenfalls in
#'   Prozent p. a. (einfache Verzinsung je Zeile ueber \code{rate_basis}) und
#'   darf nicht \code{"level"} sein; ebenso die Tage je Zeile (\code{days},
#'   Werte unveraendert verwendet, am besten ohne Angabe).
#' @param cross Kopplung der Nicht-Referenzindizes bei den Verfahren
#'   "garch", "gjr_garch", "ms_garch", "ms_ar_garch_m" und "tvtp_ms_garch":
#'   \code{"ratio"} (Standard, wie Original: GARCH(1,1) auf das Verhaeltnis zur
#'   Referenz, z. B. EUR-Index = USD-Index x Wechselkurs) oder \code{"joint"}
#'   (eigene GARCH(1,1)-Dynamik je Reihe, Kopplung nur ueber das gemeinsame
#'   Residuendatum). Bei den uebrigen Verfahren ohne Wirkung.
#' @param input \code{"returns"} (Standard; Brutto-Renditen > 0 je Zeile, wie
#'   im Original) oder \code{"prices"} (Kursniveaus; Renditen werden intern als
#'   Verhaeltnis aufeinanderfolgender Zeilen gebildet, die erste Zeile entfaellt).
#'
#' @return Objekt der Klasse \code{bootstrap_config} (Liste mit
#'   \code{indices}, \code{letfs} (mit allen Standardwerten ergaenzt),
#'   \code{regime_index}, \code{aux}, \code{aux_type} (Art je Zusatzreihe,
#'   vollstaendig), \code{aux_type_set} (Namen der ausdruecklich angegebenen
#'   Arten), \code{cross}, \code{input}, \code{n_indices}, \code{n_letfs},
#'   \code{n_aux}, \code{index_names}, \code{letf_names}, \code{aux_names}).
#' @examples
#' # Spalten mit Brutto-Tagesrenditen (us_ret, eu_ret) und einem Zins in
#' # Prozent p. a. (eu_rate):
#' cfg <- bootstrap_config(
#'   indices = c(us = "us_ret", eu = "eu_ret"), regime_index = "us",
#'   letfs = list(list(base = "eu", leverage = 2, finance = "rate", expense = 0.5)),
#'   aux = c(rate = "eu_rate"))
#' cfg
#' # Kursniveaus als Eingabe, Short-Produkt mit festem Zins:
#' cfg2 <- bootstrap_config(c(akt = "aktien"), input = "prices",
#'   letfs = list(list(base = "akt", leverage = -1, finance = 2, expense = 0.6)))
#' cfg2$letf_names
#' # Preisindex als Niveau (Pfad enthaelt den kumulierten CPI), Zins als Rate:
#' cfg3 <- bootstrap_config(c(us = "us_ret"), aux = c(cpi = "us_cpi", zins = "us_rate"),
#'   aux_type = c(cpi = "level", zins = "rate"))
#' cfg3$aux_type
#' @seealso [bootstrap()], [bootstrap_study()], [bootstrap_block_length()]
#' @export
bootstrap_config <- function(indices, letfs = list(), regime_index = NULL, aux = NULL, aux_type = NULL,
                             cross = c("ratio", "joint"), input = c("returns", "prices")) {
  .e5_choice(cross, c("ratio", "joint"), "bootstrap_config", "cross")   # seit 1.6.4 (K43 T2-N4) Pruefung vor match.arg (Meldung auswahl)
  .e5_choice(input, c("returns", "prices"), "bootstrap_config", "input")
  cross <- match.arg(cross); input <- match.arg(input)
  if (is.null(names(indices)) || any(names(indices) == ""))
    chk_stop("ut2.indices", "bootstrap_config")
  index_names <- names(indices)
  if (anyDuplicated(index_names)) chk_stop("rs.index_doppelt", "bootstrap_config", paste(index_names[duplicated(index_names)], collapse = ", "))
  if (!is.null(aux) && (is.null(names(aux)) || any(names(aux) == ""))) chk_stop("ut2.aux", "bootstrap_config")
  # seit 1.6.4: Spaltenangaben je ein Name (Text); bis 1.6.3 waehlte R bei Faktor bzw. Zahl still die Spalte ueber
  # den Code bzw. die Position (FW2-1)
  for (i in seq_along(indices)) chk_name1(indices[[i]], "bootstrap_config", sprintf("indices['%s']", index_names[i]))
  for (i in seq_along(aux)) chk_name1(aux[[i]], "bootstrap_config", sprintf("aux['%s']", names(aux)[i]))
  if (!is.null(letfs) && !is.list(letfs)) chk_stop("liste", "bootstrap_config", "letfs")
  for (i in seq_along(letfs)) if (!is.list(letfs[[i]])) chk_stop("liste", "bootstrap_config", sprintf("letfs[[%d]]", i))
  chk_name1(regime_index, "bootstrap_config", "regime_index", null_ok = TRUE)
  aux_names <- names(aux) %||% character(0)
  if (!is.null(aux_type) && !length(aux_type)) aux_type <- NULL   # character(0) wie NULL (keine Angabe)
  if (!is.null(aux_type)) {
    if (!is.character(aux_type) || is.null(names(aux_type)) || any(names(aux_type) == "") || anyNA(aux_type))
      chk_stop("ut2.aux_type", "bootstrap_config")
    bad <- setdiff(names(aux_type), aux_names)
    if (length(bad)) stop(sprintf("aux_type: '%s' ist keine Zusatzreihe aus aux (verf\u00fcgbar: %s).", paste(bad, collapse = "', '"),
                                  if (length(aux_names)) paste(aux_names, collapse = ", ") else "keine"))
    if (anyDuplicated(names(aux_type))) stop(sprintf("aux_type: Name '%s' doppelt angegeben.", names(aux_type)[duplicated(names(aux_type))][1]))
    bad <- which(!aux_type %in% c("level", "rate"))
    if (length(bad)) chk_stop("rs.aux_type_wert", "bootstrap_config", names(aux_type)[bad[1]])   # seit 1.6.4 ohne Eingabewert
  }
  aux_type_full <- stats::setNames(rep("rate", length(aux_names)), aux_names)
  aux_type_full[names(aux_type)] <- unname(aux_type)
  is_level <- function(nm) is.character(nm) && isTRUE(aux_type_full[nm] == "level")

  # LETF-Felder (seit 1.6.3 mit Typ und Laenge, in Python und Julia gleich): Zahlen einzeln und endlich, base und name
  # einzelner Text, finance und days Zahl oder Name einer Zusatzreihe; bis 1.6.2 liefen andere Werte (Vektoren, Text,
  # logisch, Faktor, NA) still durch einen Rueckfall in R, base als Faktor mit der falschen Spalte
  txt1 <- function(v) is.character(v) && length(v) == 1L && !is.na(v)
  num1 <- function(v) is.numeric(v) && length(v) == 1L && is.finite(v)
  chk_num <- function(i, v, nm) if (!num1(v)) chk_stop("zahl", "bootstrap_config", sprintf("letfs[[%d]]$%s", i, nm))
  chk_col <- function(i, v, nm) if (!num1(v) && !txt1(v))
    chk_stop("ut2.zahl_oder_aux", "bootstrap_config", sprintf("letfs[[%d]]$%s", i, nm))
  letf_list <- lapply(seq_along(letfs), function(i) {
    l <- letfs[[i]]
    if (is.null(l$base)) chk_stop("fehlt", "bootstrap_config", sprintf("letfs[[%d]]$base", i))
    if (!txt1(l$base)) chk_stop("text", "bootstrap_config", sprintf("letfs[[%d]]$base", i))
    if (!l$base %in% index_names)
      chk_stop("rs.letf_base", "bootstrap_config", sprintf("letfs[[%d]]$base", i), l$base, paste(index_names, collapse = ", "))
    lev <- l$leverage %||% 2
    chk_num(i, lev, "leverage")
    if (lev == 0) chk_stop("rs.letf_null", "bootstrap_config", sprintf("letfs[[%d]]$leverage", i))
    fin <- l$finance %||% 3.5
    chk_col(i, fin, "finance")
    if (is.character(fin) && !fin %in% aux_names) chk_stop("rs.letf_aux", "bootstrap_config", sprintf("letfs[[%d]]$finance", i), fin)
    if (is_level(fin)) chk_stop("ut2.finance_level", "bootstrap_config", sprintf("letfs[[%d]]$finance", i), fin)
    if (is.numeric(fin) && fin < 0) warning(sprintf("LETF %d: negativer Finanzierungszins.", i))
    exp_ <- l$expense %||% 0.5
    chk_num(i, exp_, "expense")
    if (exp_ < 0) chk_stop("ut2.expense", "bootstrap_config", sprintf("letfs[[%d]]$expense", i))
    days <- l$days %||% 1
    chk_col(i, days, "days")
    if (is.character(days) && !days %in% aux_names) chk_stop("rs.letf_aux", "bootstrap_config", sprintf("letfs[[%d]]$days", i), days)
    if (is_level(days)) chk_stop("rs.letf_days_level", "bootstrap_config", sprintf("letfs[[%d]]$days", i), days)
    spread <- l$spread %||% 0; rate_basis <- l$rate_basis %||% 360; ter_basis <- l$ter_basis %||% 365
    chk_num(i, spread, "spread"); chk_num(i, rate_basis, "rate_basis"); chk_num(i, ter_basis, "ter_basis")
    # seit 1.6.4 Tagesbasis > 0, Tage je Zeile > 0, Spread >= 0 (bis 1.6.3: Basis 0 brach mit falscher Ursache ab,
    # negative Werte kehrten die Kosten still in Ertraege um)
    lw <- sprintf("LETF %d", i)
    chk_num1(rate_basis, lw, "rate_basis", lo = 0, lo_open = TRUE); chk_num1(ter_basis, lw, "ter_basis", lo = 0, lo_open = TRUE)
    if (is.numeric(days)) chk_num1(days, lw, "days", lo = 0, lo_open = TRUE)
    chk_num1(spread, lw, "spread", lo = 0)
    if (!is.null(l$name) && !txt1(l$name)) chk_stop("text", "bootstrap_config", sprintf("letfs[[%d]]$name", i))
    name <- l$name %||% (if (lev > 0) paste0(l$base, "_l", lev) else paste0(l$base, "_inv", abs(lev)))
    list(name = name, base = l$base, leverage = lev, finance = fin, expense = exp_,
         spread = spread, days = days, rate_basis = rate_basis, ter_basis = ter_basis)
  })
  letf_names <- vapply(letf_list, function(x) x$name, "")
  if (anyDuplicated(c(index_names, letf_names, aux_names))) chk_stop("rs.namen_eindeutig", "bootstrap_config")

  if (is.null(regime_index)) regime_index <- index_names[1]
  else if (!regime_index %in% index_names) chk_stop("rs.regime_index", "bootstrap_config", regime_index)

  structure(list(
    indices = lapply(index_names, function(nm) list(name = nm, col = indices[[nm]])),
    letfs = letf_list, regime_index = regime_index, aux = aux, aux_type = aux_type_full,
    aux_type_set = names(aux_type) %||% character(0), cross = cross, input = input,
    n_indices = length(index_names), n_letfs = length(letf_list), n_aux = length(aux_names),
    index_names = index_names, letf_names = letf_names, aux_names = aux_names
  ), class = "bootstrap_config")
}

#' @rdname SimLevBootstrap-methods
#' @export
print.bootstrap_config <- function(x, ...) {
  cat("SimLev Bootstrap-Konfiguration\n------------------------------\n")
  cat(sprintf("  Indizes:      %s\n", paste(sprintf("%s=%s", x$index_names, vapply(x$indices, `[[`, "", "col")), collapse = ", ")))
  cat(sprintf("  Referenz:     %s (Kopplung: %s, Eingabe: %s)\n", x$regime_index, x$cross, x$input))
  if (x$n_aux) {
    typ <- ifelse(x$aux_names %in% (x$aux_type_set %||% character(0)), sprintf(" (%s)", x$aux_type[x$aux_names]), "")
    cat(sprintf("  Zusatzreihen: %s\n", paste(sprintf("%s=%s%s", x$aux_names, x$aux, typ), collapse = ", ")))
  }
  for (l in x$letfs) cat(sprintf("  Produkt %-8s Basis %s, L = %g, Zins = %s, TER = %g %%, Spread = %g %%\n",
                                 l$name, l$base, l$leverage, format(l$finance), l$expense, l$spread))
  invisible(x)
}


# ─────────────────────────────────────────────────────────────────────────────
# Interne Daten- und Parameterhelfer
# ─────────────────────────────────────────────────────────────────────────────

.boot_methods <- c("raw", "block", "circular", "stationary", "wild", "regime", "evt",
                   "tails", "reset", "garch", "gjr_garch", "ms_garch",
                   "ms_ar_garch_m", "tvtp_ms_garch")

#' Renditematrix und Zusatzreihen extrahieren
#' @keywords internal
#' @noRd
.boot_data_check <- function(data, who = "bootstrap") {
  if (!is.data.frame(data) && !is.matrix(data)) chk_stop("ut2.boot_data", who)   # seit 1.6.4 mit Funktionsnamen (K43 T2-B6)
  if (nrow(data) == 0) chk_stop("rs.data_leer", who)
  invisible(NULL)
}
# Spalten der Konfiguration (Indizes und Zusatzreihen) nur als Zahlen (seit 1.6.4, Entscheidung 39 wie Entscheidung 2;
# bis 1.6.3 rechneten R und Python mit Zahlen als Text, Julia brach ab): Faktor -> spalte_faktor, sonst nicht numerisch
# -> spalte_typ; eine Spalte nur aus NA zaehlt als Zahlenspalte (Entscheidung 14). Fehlende Spalten meldet
# .extract_returns. Nur bootstrap() und bootstrap_study() (E4 nutzt .extract_returns ohne diese Pruefung).
.boot_numcols <- function(data, config, who) {
  nms <- if (is.data.frame(data)) names(data) else colnames(data)
  cols <- c(vapply(config$indices, function(ix) ix$col, ""), unlist(unname(config$aux)))
  for (col in intersect(cols, nms)) {
    v <- if (is.data.frame(data)) data[[col]] else data[, col]
    if (is.factor(v)) chk_stop("spalte_faktor", who, col)
    if (!(is.numeric(v) || (is.logical(v) && all(is.na(v))))) chk_stop("spalte_typ", who, col, chk_msg("typ.numerisch"))
  }
  invisible(NULL)
}
.extract_returns <- function(data, config, who = "bootstrap") {
  .boot_data_check(data, who)
  get_col <- function(col) {
    nms <- if (is.data.frame(data)) names(data) else colnames(data)
    if (!col %in% nms) chk_stop("rs.spalte_fehlt", who, col, paste(nms, collapse = ", "))
    # seit 1.6.4 (Entscheidung 15): keine Faktorspalte (vorher rechnete R mit den Codes)
    if (is.data.frame(data) && is.factor(data[[col]])) chk_stop("spalte_faktor", who, col)
    as.numeric(if (is.data.frame(data)) data[[col]] else data[, col])
  }
  ret <- vapply(config$indices, function(ix) get_col(ix$col), numeric(nrow(data)))
  if (!is.matrix(ret)) ret <- matrix(ret, nrow = nrow(data))
  colnames(ret) <- config$index_names
  aux <- aux0 <- aux_ratio <- aux_start <- NULL
  if (config$n_aux) {
    aux <- vapply(unname(config$aux), get_col, numeric(nrow(data)))
    if (!is.matrix(aux)) aux <- matrix(aux, nrow = nrow(data))
    colnames(aux) <- config$aux_names
    aux0 <- aux
  }
  if (config$input == "prices") {
    ret <- ret[-1, , drop = FALSE] / ret[-nrow(ret), , drop = FALSE]
    if (!is.null(aux)) aux <- aux[-1, , drop = FALSE]
  }
  ok <- stats::complete.cases(ret) & (if (is.null(aux)) TRUE else stats::complete.cases(aux))
  if (!all(ok)) {
    message(sprintf("Hinweis: %d unvollst\u00e4ndige Zeilen entfernt.", sum(!ok)))
    ret <- ret[ok, , drop = FALSE]; if (!is.null(aux)) aux <- aux[ok, , drop = FALSE]
  }
  if (!nrow(ret)) chk_stop("rs.keine_zeile", who)
  bad <- which(!is.finite(ret), arr.ind = TRUE)
  if (nrow(bad)) chk_stop("rs.nicht_endlich", who, colnames(ret)[bad[1, 2]], bad[1, 1])
  if (!is.null(aux)) {
    # Zeilenverhaeltnisse der Zusatzreihen (fuer Niveau-Reihen wie einen CPI): Wert je Zeile
    # geteilt durch den Wert vor diesem Schritt (bei "prices" die Vorzeile der Kurse, bei
    # "returns" die vorige verwendete Zeile; die erste Zeile erhaelt dann das Verhaeltnis 1)
    prev1 <- if (config$input == "prices") aux0[which(ok)[1], ] else aux[1, ]
    # Niveau-Reihen (aux_type "level") muessen positiv und endlich sein (Zeilenverhaeltnisse)
    rows <- if (config$input == "prices") c(which(ok)[1], which(ok) + 1L) else c(which(ok)[1], which(ok))
    for (a in names(which((config$aux_type %||% character(0)) == "level"))) {
      v <- c(prev1[[a]], aux[, a]); b <- which(!is.finite(v) | v <= 0)
      if (length(b)) stop(sprintf("aux_type: Zusatzreihe '%s' (Spalte '%s') ist als 'level' gekennzeichnet und muss positiv und endlich sein; Zeile %d von data hat den Wert %s.",
                                  a, config$aux[[a]], rows[b[1]], format(v[b[1]])))
    }
    prev1[!is.finite(prev1)] <- aux[1, !is.finite(prev1)]   # fehlende Startzeile (nur "rate"-Reihen): Verhaeltnis 1
    aux_ratio <- aux / rbind(prev1, aux[-nrow(aux), , drop = FALSE])
    rownames(aux_ratio) <- NULL
    aux_start <- prev1                       # Startwert der Niveau-Variante (erste Historienzeile bzw. Startzeile der Kurse)
  }
  if (any(ret <= 0)) chk_stop("rs.rendite_null", who)
  if (stats::median(abs(ret - 1)) > 0.5)
    warning("Renditen sehen nicht wie Brutto-Tagesrenditen aus (Median |R - 1| > 0.5). input = 'prices' vergessen?")
  list(ret = ret, aux = aux, aux_ratio = aux_ratio, aux_start = aux_start)
}

#' Standardparameter je Verfahren
#' @keywords internal
#' @noRd
.get_base_params <- function(params) {
  defaults <- list(
    L = 20, block_length = 20, wild_type = 0, n_regimes = 2, vol_window = 20,
    tail_prob = 0.05, both_tails = TRUE, p_break = 0.02, garch_order = c(1, 1),
    ms_n_regimes = 2, ms_garch_model = "gjrGARCH", ms_ar_n_regimes = 2,
    ms_ar_garch_model = "gjrGARCH", tvtp_n_regimes = 2, tvtp_garch_model = "gjrGARCH")
  for (nm in names(defaults)) if (is.null(params[[nm]])) params[[nm]] <- defaults[[nm]]
  params
}

#' Standard-ESS-Gitter je Verfahren
#' @keywords internal
#' @noRd
.get_ess_grid <- function(method, n) {
  grids <- list(
    raw = NULL, stationary = list(L = c(5, 10, 20, 30, 50, 75, 100)),
    block = list(block_length = c(5, 10, 20, 30, 50, 75, 100)),
    circular = list(block_length = c(5, 10, 20, 30, 50, 75, 100)),
    wild = list(wild_type = c(0, 1, 2)), regime = list(n_regimes = c(2, 3, 4)),
    evt = list(tail_prob = c(0.01, 0.025, 0.05, 0.10)),
    tails = list(tail_prob = c(0.01, 0.025, 0.05, 0.10)),
    reset = list(p_break = c(0.01, 0.02, 0.05, 0.10)), garch = NULL, gjr_garch = NULL,
    ms_garch = list(ms_n_regimes = c(2, 3)), ms_ar_garch_m = list(ms_ar_n_regimes = c(2, 3)),
    tvtp_ms_garch = list(tvtp_n_regimes = c(2, 3)))
  g <- grids[[method]]
  for (nm in c("L", "block_length")) if (!is.null(g[[nm]])) {
    g[[nm]] <- g[[nm]][g[[nm]] <= n / 2]
    if (!length(g[[nm]])) g[[nm]] <- min(5, floor(n / 4))
  }
  g
}

#' Effektive Stichprobengroesse je Konfiguration
#' @keywords internal
#' @noRd
.calculate_ess <- function(n, method, params, info = NULL) {
  ess <- switch(method,
    raw = n, wild = n, reset = n, garch = n, gjr_garch = n,
    stationary = n / (params$L %||% 20),
    block = n / (params$block_length %||% 20), circular = n / (params$block_length %||% 20),
    regime = {
      K <- params$n_regimes %||% 2; ms <- 1
      if (!is.null(info$trans)) ms <- mean(1 / pmax(1e-6, 1 - diag(info$trans)))
      n / (K * ms)
    },
    evt = n * (1 - 2 * (params$tail_prob %||% 0.05)),
    tails = n * (1 - 2 * (params$tail_prob %||% 0.05)),
    ms_garch = n / ((params$ms_n_regimes %||% 2) * 2),
    ms_ar_garch_m = n / ((params$ms_ar_n_regimes %||% 2) * 2),
    tvtp_ms_garch = n / ((params$tvtp_n_regimes %||% 2) * 2), n)
  max(1, ess)
}


# ─────────────────────────────────────────────────────────────────────────────
# Automatische Blocklaenge
# ─────────────────────────────────────────────────────────────────────────────

#' Optimale Blocklaenge nach Politis & White (2004)
#'
#' Schaetzt die optimale (erwartete) Blocklaenge fuer den stationaeren und den
#' zirkulaeren Block-Bootstrap nach Politis & White (2004) mit der Korrektur von
#' Patton, Politis & White (2009) (Flat-Top-Lagfenster, \eqn{c = 2},
#' \eqn{K_N = \max(5, \sqrt{\log_{10} n})}).
#'
#' Hinweis: Das Verfahren optimiert die Varianzschaetzung des Mittelwerts.
#' Fuer taegliche Aktienrenditen ergeben sich oft sehr kurze Bloecke, weil die
#' Renditen kaum autokorreliert sind. Fuer Pfad-Simulationen mit
#' Trendfolge-Signalen ist daher \code{transform = "abs"} (Volatilitaets-
#' Clustering) und eine Sensitivitaetsanalyse ueber mehrere Blocklaengen zu
#' empfehlen; die Blocklaenge sollte die Signal-Lookback-Laenge nicht weit
#' unterschreiten.
#'
#' Mit \code{params = list(L = "auto")} bzw. \code{list(block_length = "auto")}
#' verwenden [bootstrap()] und [bootstrap_study()] diese Schaetzung (Maximum
#' ueber alle Indizes, jeweils fuer Log-Renditen und deren Betraege).
#'
#' @param x Numerischer Vektor oder Matrix (Spalten = Reihen), z. B.
#'   (Log-)Renditen je Zeile. Nicht-endliche Werte werden je Spalte entfernt.
#' @param transform Transformation vor der Schaetzung: \code{"none"}
#'   (Standard, Reihe selbst), \code{"abs"} (\eqn{|x - \bar x|}) oder
#'   \code{"squared"} (\eqn{(x - \bar x)^2}).
#' @return Matrix mit Spalten \code{stationary} (erwartete Blocklaenge fuer den
#'   stationaeren Bootstrap, Parameter \code{L}) und \code{circular} (feste
#'   Blocklaenge fuer den zirkulaeren Block-Bootstrap, Parameter
#'   \code{block_length}), eine Zeile je Reihe (Zeilennamen = Spaltennamen von
#'   \code{x} bzw. V1, V2, ...). Einheit: Zeilen (Beobachtungen) von \code{x};
#'   Werte sind nicht gerundet, mindestens 1 und hoechstens
#'   \eqn{\lceil\min(3\sqrt{n}, n/3)\rceil}; bei weniger als 20 Beobachtungen 1.
#' @references Politis, D.N. & White, H. (2004), Econometric Reviews 23(1);
#'   Patton, A., Politis, D.N. & White, H. (2009), Econometric Reviews 28(4).
#' @examples
#' set.seed(1); x <- arima.sim(list(ar = 0.5), 2000)
#' bootstrap_block_length(x)
#' bootstrap_block_length(x, transform = "abs")
#' @seealso [bootstrap()], [bootstrap_study()]
#' @export
bootstrap_block_length <- function(x, transform = c("none", "abs", "squared")) {
  .e5_choice(transform, c("none", "abs", "squared"), "bootstrap_block_length", "transform")   # seit 1.6.4 (K43 T2-N4) Pruefung vor match.arg (Meldung auswahl)
  transform <- match.arg(transform)
  # seit 1.6.4: nur Zahlen (vorher Text still 1; Python rechnete Text wie Zahlen und Kategorien als Codes)
  # Entscheidung 15: Faktor bzw. Faktorspalte mit eigener Meldung
  chk_nofactor(x, "bootstrap_block_length", "x")
  if (is.data.frame(x)) for (k in names(x)) chk_col_nofactor(x, k, "bootstrap_block_length")
  ok <- if (is.data.frame(x)) ncol(x) >= 1L && all(vapply(x, function(v) is.numeric(v) && !is.factor(v), NA))
        else is.numeric(x) && !is.factor(x)
  if (!ok) chk_stop("e2.zahlen_matrix", "bootstrap_block_length", "x")
  x <- as.matrix(x)
  res <- t(apply(x, 2, function(v) {
    v <- v[is.finite(v)]
    v <- switch(transform, none = v, abs = abs(v - mean(v)), squared = (v - mean(v))^2)
    .pw_block(v)
  }))
  rownames(res) <- colnames(x) %||% paste0("V", seq_len(ncol(x)))
  res
}

#' @keywords internal
.pw_block <- function(x) {
  n <- length(x)
  if (n < 20) return(c(stationary = 1, circular = 1))
  KN <- max(5, sqrt(log10(n)))
  mmax <- ceiling(sqrt(n)) + KN
  bmax <- ceiling(min(3 * sqrt(n), n / 3))
  crit <- 2 * sqrt(log10(n) / n)
  xc <- x - mean(x)
  acov <- function(k) sum(xc[1:(n - k)] * xc[(1 + k):n]) / n
  r0 <- acov(0)
  if (r0 <= 0) return(c(stationary = 1, circular = 1))
  lags <- seq_len(floor(mmax))
  A <- vapply(lags, acov, 0)   # seit 1.6.4 (A-089) einmal fuer rho und Rk (M <= floor(mmax))
  rho <- A / r0
  insig <- abs(rho) < crit
  KNi <- ceiling(KN)
  mhat <- NA
  for (k in seq_len(max(0, length(insig) - KNi + 1))) if (all(insig[k:(k + KNi - 1)])) { mhat <- k; break }
  if (is.na(mhat)) {
    sig <- which(!insig)
    mhat <- if (length(sig)) max(sig) else 1
  }
  M <- min(2 * mhat, floor(mmax))
  kk <- seq_len(M)
  lam <- function(t) ifelse(abs(t) <= 0.5, 1, ifelse(abs(t) <= 1, 2 * (1 - abs(t)), 0))
  Rk <- A[kk]
  G <- 2 * sum(lam(kk / M) * kk * Rk)
  g0 <- r0 + 2 * sum(lam(kk / M) * Rk)
  if (g0 <= 0) return(c(stationary = 1, circular = 1))
  b_sb <- (2 * G^2 / (2 * g0^2))^(1 / 3) * n^(1 / 3)
  b_cb <- (2 * G^2 / ((4 / 3) * g0^2))^(1 / 3) * n^(1 / 3)
  c(stationary = min(max(1, b_sb), bmax), circular = min(max(1, b_cb), bmax))
}

#' "auto"-Parameter aufloesen (L, block_length)
#' @keywords internal
#' @noRd
.resolve_auto <- function(params, returns) {
  for (nm in c("L", "block_length")) if (identical(params[[nm]], "auto")) {
    lr <- log(returns)
    b <- rbind(bootstrap_block_length(lr), bootstrap_block_length(lr, "abs"))
    col <- if (nm == "L") "stationary" else "circular"
    params[[nm]] <- max(1, round(max(b[, col])))
    message(sprintf("Automatische Blockl\u00e4nge (%s, Politis-White, max. \u00fcber Reihen und |r|): %d", nm, params[[nm]]))
  }
  params
}


# ─────────────────────────────────────────────────────────────────────────────
# Modellanpassung (GARCH-Familie, Regime, EVT)
# ─────────────────────────────────────────────────────────────────────────────

#' GARCH(1,1) / GJR-GARCH(1,1) schaetzen (ML -> Momente)
#'
#' Seit 1.0.0 mit der C-Bibliothek slc (.sl_fit_garch11, R/slc_models.R):
#' ML-Punktschaetzer unter Normalverteilung (Raster-Starts,
#' BFGS, Umparametrisierung wie MS-GARCH; GJR mit alpha + gamma >= 0, also
#' auch gamma < 0, und BFGS von allen sieben Rasterpunkten), bei Fehlschlag die
#' Momente mit Warnung; Methodenlabel "konstant", "ml" oder "momente". Der
#' fruehere Weg ueber rugarch (mit Rsolnp/gosolnp und dessen Uhrzeit-Seed) und
#' die Nelder-Mead-Stufe entfallen.
#' @keywords internal
#' @noRd
.fit_garch11 <- function(e, gjr = FALSE, quiet = FALSE) .sl_fit_garch11(e, gjr = gjr, quiet = quiet)

#' Nicht-Referenzreihen als GARCH(1,1) modellieren (ratio oder joint)
#' @keywords internal
#' @noRd
.fit_cross <- function(returns, config, base) {
  k <- ncol(returns); others <- setdiff(seq_len(k), base); n <- nrow(returns)
  if (!length(others))
    return(list(cols = integer(0), mu = numeric(0), om = numeric(0), al = numeric(0), be = numeric(0),
                ratio = logical(0), s2 = numeric(0), z = matrix(0, n, 0)))
  ratio <- config$cross == "ratio"
  fits <- lapply(others, function(j) {
    e <- if (ratio) returns[, j] / returns[, base] - 1 else returns[, j] - 1
    f <- .fit_garch11(e, gjr = FALSE, quiet = TRUE)
    message(sprintf("  Kopplung %s (%s): mu=%.2e, omega=%.2e, alpha=%.4f, beta=%.4f [%s]",
                    colnames(returns)[j], config$cross, f$mu, f$omega, f$alpha, f$beta, f$method))
    f
  })
  list(cols = as.integer(others - 1L),
       mu = vapply(fits, `[[`, 0, "mu"), om = vapply(fits, `[[`, 0, "omega"),
       al = vapply(fits, `[[`, 0, "alpha"), be = vapply(fits, `[[`, 0, "beta"),
       ratio = rep(ratio, length(others)), s2 = vapply(fits, `[[`, 0, "s2_init"),
       z = do.call(cbind, lapply(fits, `[[`, "z")))
}

#' Tail-Schaetzung (GPD-ML -> Momente -> empirisch -> Default)
#'
#' Der GPD-Fit nutzt seit 1.0.0 die C-Bibliothek slc (.sl_gpd_fit,
#' ML in (log sigma, xi) mit Startwerten nach Hosking/Wallis 1987).
#' @keywords internal
#' @noRd
.fit_tail <- function(base_ret, prob, side) {
  thr <- as.numeric(stats::quantile(base_ret, if (side == "left") prob else 1 - prob))
  mask <- if (side == "left") base_ret < thr else base_ret > thr
  exc <- if (side == "left") thr - base_ret[mask] else base_ret[mask] - thr
  ne <- length(exc); scale <- shape <- NULL; method <- "none"
  if (ne >= 30) tryCatch({
    f <- .sl_gpd_fit(exc)
    if (is.finite(f$scale) && f$scale > 0 && is.finite(f$shape)) { scale <- f$scale; shape <- f$shape; method <- "MLE" }
  }, error = function(e) NULL)
  if (is.null(scale) && ne >= 20) {
    m <- mean(exc); v <- .sl_var(exc)
    if (v > 0 && m > 0) { ratio <- m^2 / v; shape <- max(-0.5, min(1, 0.5 * (1 - ratio)))
      scale <- max(1e-3, 0.5 * m * (1 + ratio)); method <- "Momente" }
  }
  if (is.null(scale) && ne >= 5) { scale <- max(1e-3, .sl_sd(exc)); shape <- 0.1; method <- "empirisch" }
  if (is.null(scale)) { scale <- max(0.005, 2 * .sl_sd(base_ret - 1)); shape <- 0.1; method <- "Default"
    warning(sprintf("Tail-Fit: Default-Parameter (nur %d Tail-Beobachtungen)", ne)) }
  if (shape >= 0.5) warning(sprintf("GPD shape = %.3f (%s): unendliche Varianz", shape, side))
  list(prob = prob, thresh = thr, scale = scale, shape = shape, pool = which(mask), method = method)
}

#' Regime aus rollierender Volatilitaet
#' @keywords internal
#' @noRd
.prepare_regime_info <- function(base_ret, vol_window, n_regimes) {
  vol <- .sl_rolling_vol(base_ret, as.integer(vol_window))
  th <- stats::quantile(vol, probs = seq(0, 1, length.out = n_regimes + 1))
  th[length(th)] <- th[length(th)] + 1e-10
  reg <- .sl_assign_regimes(vol, th)
  list(regimes = reg, trans = .sl_estimate_trans_mat(reg, as.integer(n_regimes)), vol = vol)
}

#' MS-GARCH-Familie vorbereiten (eigene ML-Schaetzung, .ms_garch_fit in R/ms_garch.R)
#' @keywords internal
#' @noRd
.prepare_ms_info <- function(returns, config, base, K, garch_model, ar_gm, tvtp, cores = 1L) {
  .ms_garch_check(K, garch_model)
  ex <- returns[, base] - 1; n <- length(ex)
  fit <- tryCatch(.ms_garch_fit(ex, K, garch_model, cores),   # cores Threads fuer die Starts
                  error = function(e) stop(sprintf("MS-GARCH(%d, %s) Fit fehlgeschlagen: %s", K, garch_model, e$message)))
  om <- fit$omega; al <- fit$alpha; be <- fit$beta; ga <- fit$gamma
  P <- fit$P
  reg <- fit$regimes
  mu <- vapply(seq_len(K), function(r) { i <- which(reg == r); if (length(i) >= 10) mean(ex[i]) else mean(ex) }, 0)
  s2 <- fit$s2
  sig <- sqrt(pmax(s2, 1e-14))
  phi <- lam <- rep(0, K)
  lag_ex <- c(0, ex[-n])
  if (ar_gm) for (r in seq_len(K)) {
    i <- which(reg == r); if (length(i) < 30) next
    b <- tryCatch(.sl_lsfit(cbind(1, lag_ex[i]), ex[i])$coefficients[2], error = function(e) NA)
    if (is.finite(b)) phi[r] <- max(-0.5, min(0.5, b))
    l <- tryCatch(.sl_lsfit(cbind(sig[i]), ex[i] - mu[r] - phi[r] * lag_ex[i])$coefficients[1], error = function(e) NA)
    if (is.finite(l)) lam[r] <- max(-5, min(5, l))
  }
  unc <- vapply(seq_len(K), function(r) {
    p <- al[r] + be[r] + ga[r] / 2
    if (p < 0.9999 && om[r] > 0) om[r] / (1 - p) else { i <- which(reg == r); if (length(i) >= 10) .sl_var(ex[i]) else .sl_var(ex) }
  }, 0)
  delta <- matrix(0, K, K)
  if (tvtp) for (i in seq_len(K)) {
    from <- which(reg[-n] == i); if (length(from) < 50) next
    x <- s2[from] / unc[i] - 1; to <- reg[from + 1]
    for (j in seq_len(K)) if (j != i && sum(to == j) >= 5) {
      d <- tryCatch(.sl_logit_irls(cbind(1, x), as.integer(to == j))$coefficients[2], error = function(e) NA)   # Logit-IRLS
      if (is.finite(d)) delta[i, j] <- max(-3, min(3, d))
    }
  }
  cm <- mu[reg] + phi[reg] * lag_ex + lam[reg] * sig
  z <- (ex - cm) / sig; z[!is.finite(z)] <- 0
  pools <- lapply(seq_len(K), function(r) { i <- which(reg == r); if (length(i) < 10) seq_len(n) else i })
  for (r in seq_len(K)) { i <- pools[[r]]; s <- .sl_sd(z[i]); if (is.finite(s) && s > 0) z[i] <- (z[i] - mean(z[i])) / s }
  pi_ <- rep(1 / K, K); for (it in 1:1000) { p2 <- as.numeric(pi_ %m% P); if (max(abs(p2 - pi_)) < 1e-12) break; pi_ <- p2 }
  message(sprintf("MS-GARCH(%d, %s%s%s): P(stay) = %s", K, garch_model, if (ar_gm) ", AR-M" else "",
                  if (tvtp) ", TVTP" else "", paste(sprintf("%.3f", diag(P)), collapse = "/")))
  list(K = K, mu = mu, omega = om, alpha = al, beta = be, gamma = ga, phi = phi, lambda = lam,
       trans = P, delta = delta, unc = unc, stat = pi_ / sum(pi_), pools = lapply(pools, as.integer),
       z = z, regimes = reg, cross = .fit_cross(returns, config, base))
}

#' Verfahrensspezifische Vorberechnung
#' @keywords internal
#' @noRd
.prepare_method_info <- function(returns, config, method, params, cores = 1L) {
  p <- .get_base_params(params)
  base <- which(config$index_names == config$regime_index)
  br <- returns[, base]
  info <- list(base = base)
  if (method == "regime") info <- c(info, .prepare_regime_info(br, p$vol_window, p$n_regimes))
  if (method == "evt") {
    info$left <- .fit_tail(br, p$tail_prob, "left")
    info$right <- if (isTRUE(p$both_tails)) .fit_tail(br, p$tail_prob, "right") else NULL
    bulk <- br >= info$left$thresh
    if (!is.null(info$right)) bulk <- bulk & br <= info$right$thresh
    info$bulk <- which(bulk); if (!length(info$bulk)) info$bulk <- seq_along(br)
  }
  if (method == "tails") {
    lt <- stats::quantile(br, p$tail_prob); rt <- stats::quantile(br, 1 - p$tail_prob)
    info$left <- which(br < lt); info$right <- which(br > rt)
    info$bulk <- which(br >= lt & br <= rt); if (!length(info$bulk)) info$bulk <- seq_along(br)
    info$p <- p$tail_prob
  }
  if (method %in% c("garch", "gjr_garch")) {
    f <- .fit_garch11(br - 1, gjr = method == "gjr_garch")
    message(sprintf("%s(1,1) [%s]: mu=%.2e, omega=%.2e, alpha=%.4f, beta=%.4f, gamma=%.4f, Persistenz=%.4f",
                    toupper(method), f$method, f$mu, f$omega, f$alpha, f$beta, f$gamma, f$persistence))
    if (f$persistence >= 0.999) warning(sprintf("GARCH: Persistenz %.4f (nahe IGARCH)", f$persistence))
    info$garch <- f
    info$cross <- .fit_cross(returns, config, base)
  }
  if (method == "ms_garch") info$ms <- .prepare_ms_info(returns, config, base, p$ms_n_regimes, p$ms_garch_model, FALSE, FALSE, cores)
  if (method == "ms_ar_garch_m") info$ms <- .prepare_ms_info(returns, config, base, p$ms_ar_n_regimes, p$ms_ar_garch_model, TRUE, FALSE, cores)
  if (method == "tvtp_ms_garch") info$ms <- .prepare_ms_info(returns, config, base, p$tvtp_n_regimes, p$tvtp_garch_model, TRUE, TRUE, cores)
  info
}


# ─────────────────────────────────────────────────────────────────────────────
# Pfaderzeugung
# ─────────────────────────────────────────────────────────────────────────────

#' Eine Renditematrix samt Quellzeilen erzeugen
#' @keywords internal
#' @noRd
.generate_returns <- function(returns, method, p, info, n_out, stream) {
  n <- nrow(returns); k <- ncol(returns)
  from_idx <- function(idx) list(ret = returns[idx, , drop = FALSE], idx = idx)
  # Ziehungen aus dem Strom des Pfads (Kerne slc_boot)
  g <- switch(method,
    raw        = from_idx(.sl_boot_idx_iid(n, n_out, stream = stream)),
    block      = from_idx(.sl_boot_idx_block(n, n_out, as.integer(p$block_length), FALSE, stream = stream)),
    circular   = from_idx(.sl_boot_idx_block(n, n_out, as.integer(p$block_length), TRUE, stream = stream)),
    stationary = from_idx(.sl_boot_idx_stationary(n, n_out, as.numeric(p$L), stream = stream)),
    regime     = from_idx(.sl_boot_idx_regime(info$regimes, info$trans, n_out, stream = stream)),
    tails      = from_idx(.sl_boot_idx_tails(n_out, info$p, info$p, info$bulk, info$left, info$right, stream = stream)),
    wild       = list(ret = .sl_boot_wild(returns, as.integer(p$wild_type), stream = stream), idx = seq_len(n)),
    reset      = list(ret = .sl_boot_reset(returns, p$p_break, stream = stream), idx = seq_len(n)),
    evt = {
      l <- info$left; r <- info$right
      .sl_boot_evt(returns, info$base - 1L, n_out, l$prob, l$thresh, l$scale, l$shape, as.integer(l$pool),
                   if (is.null(r)) 0 else r$prob, if (is.null(r)) Inf else r$thresh,
                   if (is.null(r)) 0 else r$scale, if (is.null(r)) 0 else r$shape,
                   if (is.null(r)) integer(0) else as.integer(r$pool), as.integer(info$bulk), stream = stream)
    },
    garch = , gjr_garch = {
      f <- info$garch; cr <- info$cross
      .sl_boot_garch(n_out, info$base - 1L, k, f$mu, f$omega, f$alpha, f$beta, f$gamma, f$s2_init,
                     f$z, seq_len(n), cr$cols, cr$mu, cr$om, cr$al, cr$be, cr$ratio, cr$s2, cr$z, stream = stream)
    },
    ms_garch = , ms_ar_garch_m = , tvtp_ms_garch = {
      m <- info$ms; cr <- m$cross
      .sl_boot_ms_garch(n_out, info$base - 1L, k, as.integer(m$K), m$mu, m$omega, m$alpha, m$beta, m$gamma,
                        m$phi, m$lambda, m$trans, m$delta, m$unc, m$stat, m$pools, m$z,
                        cr$cols, cr$mu, cr$om, cr$al, cr$be, cr$ratio, cr$s2, cr$z, stream = stream)
    },
    stop(sprintf("Unbekannte Methode: %s", method)))
  colnames(g$ret) <- colnames(returns)
  g
}

#' Angaben fuer den Kern sl_boot_path (seit 1.6.0) oder NULL (seit 1.6.3 ein interner Fehler in .build_path)
#' @keywords internal
#' @noRd
.boot_path_spec <- function(ret, idx, aux, config, start, aux_ratio, aux_start) {
  dbl1 <- function(v) is.double(v) && length(v) == 1L
  num1 <- function(v) is.numeric(v) && length(v) == 1L
  n_out <- nrow(ret)
  if (!is.double(ret) || n_out < 1L || ncol(ret) < 1L || !is.null(rownames(ret)) || !dbl1(start) ||
      !is.numeric(idx) || length(idx) != n_out || anyNA(idx)) return(NULL)
  cn <- colnames(ret)
  if (length(config$index_names) != ncol(ret)) return(NULL)
  anames <- character(0); level <- logical(0)
  if (!is.null(aux)) {
    if (!is.matrix(aux) || !is.double(aux) || !is.null(rownames(aux)) || is.null(colnames(aux)) ||
        any(idx < 1 | idx > nrow(aux) | idx != trunc(idx))) return(NULL)
    if (!is.null(aux_ratio) && (!is.matrix(aux_ratio) || !is.double(aux_ratio) || !identical(dim(aux_ratio), dim(aux)) ||
                                !is.null(rownames(aux_ratio)) || !identical(colnames(aux_ratio), colnames(aux)) ||
                                (!is.null(aux_start) && (!is.double(aux_start) || length(aux_start) != ncol(aux)))))
      return(NULL)
    anames <- colnames(aux)
    level <- (config$aux_type %||% character(0))[anames] %in% "level"
  }
  lnames <- if (config$n_letfs) config$letf_names else character(0)
  nms <- c(config$index_names, lnames, anames)
  if (anyDuplicated(nms) || anyNA(nms) || anyDuplicated(cn) || is.null(cn)) return(NULL)
  letf <- matrix(0, length(lnames), 10L)
  for (i in seq_along(lnames)) {
    l <- config$letfs[[i]]
    b <- match(l$base, cn)
    col_or_val <- function(v) {
      if (is.character(v) && length(v) == 1L) { j <- match(v, anames); if (is.na(j)) NA else c(j - 1, 0) }
      else if (num1(v)) c(-1, v) else NA
    }
    fi <- col_or_val(l$finance); dd <- col_or_val(l$days)
    if (!is.character(l$base) || length(l$base) != 1L || is.na(b) || anyNA(fi) || anyNA(dd) ||
        !all(vapply(list(l$leverage, l$rate_basis, l$ter_basis, l$expense, l$spread), num1, NA))) return(NULL)
    letf[i, ] <- c(b - 1, l$leverage, fi, dd, l$rate_basis, l$ter_basis, l$expense, l$spread)
  }
  list(idx = as.integer(idx), level = level, letf = letf, names = nms)
}

#' Preis-Pfad aus Renditen bauen (Index-Knockout = ungueltig, LETF-Knockout = Totalverlust)
#'
#' Zusatzreihen mit \code{aux_type} "rate" stehen als Originalwerte der
#' gezogenen Zeilen im Pfad, solche mit "level" als Niveau-Variante. Das
#' Attribut \code{aux_level} enthaelt die Niveau-Variante fuer alle
#' Zusatzreihen: \code{aux_start} (erste Historienzeile bzw. Startzeile der
#' Kurse), danach mit den Zeilenverhaeltnissen \code{aux_ratio} der gezogenen
#' Zeilen kumuliert (nur sinnvoll fuer Niveau-Reihen wie einen CPI); fuer
#' "level"-Reihen ist sie identisch mit der Pfadspalte.
#' @keywords internal
#' @noRd
.build_path <- function(g, aux, config, start = 100, aux_ratio = NULL, aux_start = NULL) {
  ret <- g$ret; idx <- g$idx
  # seit 1.6.4 (A-058) ohne die Vorpruefung any(!is.finite(ret)) || any(ret <= 0): der Kern (sl_boot_path) prueft
  # dieselbe Bedingung und liefert dann NULL (gleiches Ergebnis, ein Durchlauf statt drei)
  if (!is.matrix(ret)) return(NULL)
  # seit 1.6.0 im Kern (sl_boot_path: Kurspfade, Hebelprodukte, Zusatzreihen und Niveau-Variante in einem Aufruf)
  sp <- .boot_path_spec(ret, idx, aux, config, start, aux_ratio, aux_start)
  # bis 1.6.2 rechnete hier ein Rueckfall in R; seit 1.6.3 unerreichbar (bootstrap_config prueft die LETF-Felder,
  # .generate_returns liefert double-Matrizen ohne Zeilennamen und ganzzahlige Zeilen)
  if (is.null(sp)) stop("bootstrap: interner Fehler: Angaben f\u00fcr den Pfadkern unvollst\u00e4ndig (.boot_path_spec)")
  r <- .Call(C_sl_boot_path, ret, sp$idx, aux, if (is.null(aux)) NULL else aux_ratio,
             if (is.null(aux)) NULL else aux_start, sp$level, sp$letf, start)
  if (is.null(r)) return(NULL)
  P <- r[[1L]]
  # eine Zeile: die Hebelrenditen tragen den Namen der Indexspalte (ret[, base] ohne Dimension), daher wie bisher
  # Zeilennamen c("", base) aus vapply
  dimnames(P) <- list(if (nrow(ret) == 1L && nrow(sp$letf)) c("", config$letfs[[1L]]$base), sp$names)
  if (!is.null(r[[2L]])) { lv <- r[[2L]]; dimnames(lv) <- list(NULL, colnames(aux)); attr(P, "aux_level") <- lv }
  P
}

#' ESS-Design: Simulationsbudget auf Hyperparameter-Kombinationen verteilen
#' @keywords internal
#' @noRd
.ess_design <- function(method, grid, budget, n_obs) {
  if (is.null(grid)) grid <- .get_ess_grid(method, n_obs)
  if (is.null(grid) || !length(grid)) return(NULL)
  ess_params <- c("L", "block_length", "n_regimes", "tail_prob", "ms_n_regimes", "ms_ar_n_regimes", "tvtp_n_regimes")
  non_ess <- c("vol_window", "wild_type", "both_tails", "p_break", "garch_order")   # seit 1.6.4 ohne Textparameter (Entscheidung 31)
  nm <- names(grid)
  design <- expand.grid(grid, stringsAsFactors = FALSE, KEEP.OUT.ATTRS = FALSE)
  design$ess_per_boot <- apply(design[, nm, drop = FALSE], 1, function(row)
    .calculate_ess(n_obs, method, as.list(row)))
  if (any(nm %in% non_ess)) {
    ec <- nm[nm %in% ess_params]
    design$ess_group <- if (length(ec)) apply(design[, ec, drop = FALSE], 1, paste, collapse = "_") else "all"
    design$n_variants <- as.numeric(table(design$ess_group)[design$ess_group])
    design$weight_alloc <- (1 / design$ess_per_boot) / design$n_variants
  } else {
    design$n_variants <- 1; design$weight_alloc <- 1 / design$ess_per_boot
  }
  design$n_sims <- pmax(1, round(budget * design$weight_alloc / sum(design$weight_alloc)))
  while (sum(design$n_sims) > budget) { i <- which.max(design$n_sims); design$n_sims[i] <- design$n_sims[i] - 1 }
  design$total_ESS <- design$ess_per_boot * design$n_sims
  target <- stats::median(design$total_ESS[design$total_ESS > 0])
  design$weight <- ifelse(design$total_ESS > 0, target / design$total_ESS, 0)
  attr(design, "param_names") <- nm
  design
}

#' Verfahrensparameter vor dem Ziehen pruefen (klare Meldung statt verworfener Pfade)
#'
#' Seit 1.6.4 vor der Vorberechnung (vorher danach) und ohne Eingabewert in den Meldungen; dazu n_regimes,
#' vol_window (regime), tail_prob (evt, tails), both_tails (evt) und die Obergrenze 64 der MS-GARCH-Regime
#' (der Kern rechnet hoechstens 64; Python/Julia legten vorher K x K-Felder an).
#' @keywords internal
#' @noRd
.check_boot_params <- function(method, p, n_obs, who = "bootstrap") {
  num1 <- function(v) is.numeric(v) && length(v) == 1L && is.finite(v)
  if (method == "stationary" && (!num1(p$L) || p$L < 1))
    chk_stop("ut2.param_L", who)
  if (method %in% c("block", "circular")) {
    b <- p$block_length; hi <- if (method == "block") n_obs - 1L else n_obs
    if (!num1(b) || b != round(b) || b < 1 || b > hi)
      chk_stop("ut2.param_block", who, as.integer(hi), as.integer(n_obs),
               if (method == "block") ", sonst g\u00e4be es nur einen Blockstart" else "")
  }
  if (method == "wild" && (!num1(p$wild_type) || !p$wild_type %in% 0:2))
    chk_stop("ut2.param_wild", who)
  if (method == "reset" && (!num1(p$p_break) || p$p_break < 0 || p$p_break > 1))
    chk_stop("ut2.param_p_break", who)
  if (method == "regime") {
    chk_int1(p$n_regimes, who, "params$n_regimes", lo = 1)
    chk_int1(p$vol_window, who, "params$vol_window", lo = 2)
  }
  if (method %in% c("evt", "tails"))
    chk_num1(p$tail_prob, who, "params$tail_prob", lo = 0, hi = 0.5, lo_open = TRUE, hi_open = TRUE)
  if (method == "evt") chk_bool1(p$both_tails, who, "params$both_tails")
  kn <- switch(method, ms_garch = "ms_n_regimes", ms_ar_garch_m = "ms_ar_n_regimes", tvtp_ms_garch = "tvtp_n_regimes", NULL)
  # K < 2, nicht ganz usw. meldet .ms_garch_check (Vorberechnung); hier nur die Obergrenze des Kerns
  if (!is.null(kn) && num1(p[[kn]]) && p[[kn]] > 64) chk_stop("ganz_bis", who, paste0("params$", kn), "2", "64")
  invisible(TRUE)
}

#' ESS-Gitter pruefen: NULL oder benannte Liste nicht leerer atomarer Vektoren (seit 1.6.4)
#' @keywords internal
#' @noRd
.check_ess_grid <- function(g, who) {
  if (is.null(g)) return(invisible(NULL))
  if (is.list(g) && any(vapply(g, is.factor, NA))) chk_stop("faktor", who, "ess_grid")   # Entscheidung 15
  if (!is.list(g) || is.data.frame(g) || !length(g) || is.null(names(g)) || anyNA(names(g)) || any(names(g) == "") ||
      !all(vapply(g, function(v) is.atomic(v) && length(v) > 0L && !is.factor(v), NA)))
    chk_stop("e2.gitter", who)
  if (anyDuplicated(names(g))) chk_stop("e2.doppelt", who, "ess_grid")
  # seit 1.6.4 nur Zahlen (Entscheidung 31; bis 1.6.3 scheiterten Textparameter wie ms_garch_model technisch);
  # Wahrheitswerte (z. B. both_tails) bleiben erlaubt (Entscheidung 45)
  if (!all(vapply(g, function(v) is.numeric(v) || is.logical(v), NA))) chk_stop("gitter_zahlen", who)
  invisible(NULL)
}

#' Gemeinsame Vorbereitung fuer bootstrap() und bootstrap_study()
#' @keywords internal
#' @noRd
.boot_setup <- function(data, config, method, n, params, ess, ess_grid, path_length, cores = 1L,
                        max_tries = 10L, progress = TRUE, who = "bootstrap") {
  if (!inherits(config, "bootstrap_config")) chk_stop("klasse", who, "config", "bootstrap_config()")
  # seit 1.6.4: Methode als einzelner Text, n auch NA, Meldungen ohne Eingabewert (Entscheidung 8)
  if (!is.character(method) || length(method) != 1L || is.na(method) || !method %in% .boot_methods)
    chk_stop("auswahl", who, "method", paste0('"', .boot_methods, '"', collapse = ", "))
  if (!is.numeric(n) || length(n) != 1 || is.na(n) || n < 1) chk_stop("ut2.n_positiv", who)
  if (!is.null(path_length) && (!is.numeric(path_length) || length(path_length) != 1 || !is.finite(path_length) ||
                                path_length < 1 || path_length != round(path_length)))
    chk_stop("ganz", who, "path_length", "1")
  # einheitliche Eingabepruefung (seit 1.6.4): data wie .extract_returns, dann die uebrigen Argumente vor der Vorberechnung
  .boot_data_check(data, who)
  chk_int1(n, who, "n")
  # seit 1.6.4 Obergrenzen (Entscheidungen 16, 36 und 46): n <= 10^8, path_length <= 36 600 Tage (100 Jahre)
  chk_max(n, SL_MAX_N, who, "n")
  if (!is.null(path_length)) chk_max(path_length, SL_MAX_TAGE, who, "path_length")
  if (!is.null(params) && !is.list(params)) chk_stop("liste", who, "params")
  chk_bool1(ess, who, "ess")
  .check_ess_grid(ess_grid, who)
  chk_int1(max_tries, who, "max_tries")
  cores <- chk_cores(cores, who)   # seit 1.6.4 hoechstens Zahl der Prozessoren, mit Hinweis (Entscheidung 41b)
  chk_bool1(progress, who, "progress")
  .boot_numcols(data, config, who)   # seit 1.6.4 nur Zahlenspalten (Entscheidung 39)
  ex <- .extract_returns(data, config, who)
  n_obs <- nrow(ex$ret)
  # seit 1.6.4 (Entscheidung 38): ess = TRUE mit dem Standardgitter braucht fuer Blocklaengen mindestens 4 Renditen
  # (bis 1.6.3 R-Rohfehler "missing value where TRUE/FALSE needed", Python ZeroDivisionError)
  if (isTRUE(ess) && is.null(ess_grid) && method %in% c("stationary", "block", "circular") && n_obs < 4L)
    chk_stop("ess_kurz", who, 4L)
  n_out <- as.integer(path_length %||% n_obs)
  if (method %in% c("wild", "reset") && n_out != n_obs)
    chk_stop("ut2.chronologie", who, method, as.integer(n_obs))
  params <- .resolve_auto(params, ex$ret)
  design <- if (ess) .ess_design(method, ess_grid, as.integer(n), n_obs) else NULL
  if (ess && is.null(design)) message("Keine Hyperparameter f\u00fcr ESS - nutze Standard-Bootstrap")
  combos <- if (is.null(design)) list(params) else lapply(seq_len(nrow(design)), function(i) {
    gp <- as.list(design[i, attr(design, "param_names"), drop = FALSE])
    utils::modifyList(params, gp)
  })
  combo_of_path <- if (is.null(design)) rep(1L, n) else rep(seq_len(nrow(design)), design$n_sims)
  n_paths <- length(combo_of_path)
  base_p <- lapply(combos, .get_base_params)
  for (bp in base_p) .check_boot_params(method, bp, n_obs, who)   # seit 1.6.4 vor der Vorberechnung
  infos <- lapply(combos, function(cp) tryCatch(.prepare_method_info(ex$ret, config, method, cp, cores),
                                               error = function(e) stop(sprintf("Vorberechnung fehlgeschlagen: %s", e$message))))
  weights <- if (is.null(design)) rep(1, n_paths) else design$weight[combo_of_path]
  weights <- weights / sum(weights) * length(weights)
  list(ex = ex, n_obs = n_obs, n_out = n_out, design = design, combos = combos, base_p = base_p,
       infos = infos, combo_of_path = combo_of_path, n_paths = n_paths, weights = weights, cores = cores)
}

#' Einen gueltigen Pfad mit eigenem Zufallsstrom erzeugen (mit Wiederholungen)
#'
#' \code{stream} ist der SimLev-Strom des Pfads; Wiederholungen ziehen
#' daraus weiter.
#' @keywords internal
#' @noRd
.draw_path <- function(setup, i, stream, config, method, max_tries) {
  c_id <- setup$combo_of_path[i]
  err <- "Pfad ung\u00fcltig (Indexrendite <= 0 oder nicht endlich)"
  for (try in seq_len(max_tries)) {
    g <- tryCatch(.generate_returns(setup$ex$ret, method, setup$base_p[[c_id]], setup$infos[[c_id]], setup$n_out, stream),
                  error = function(e) { err <<- conditionMessage(e); NULL })
    if (!is.null(g)) {
      P <- .build_path(g, setup$ex$aux, config, aux_ratio = setup$ex$aux_ratio, aux_start = setup$ex$aux_start)
      if (!is.null(P)) return(list(path = P, tries = try))
    }
  }
  list(path = NULL, tries = max_tries, err = err)
}

#' Parallele Ausfuehrung (fork auf Unix, PSOCK auf Windows)
#'
#' Jede Einheit laeuft als parallele Einheit (Merker \code{.sl_state$in_unit}): der globale
#' Zufallszustand von SimLev ist darin gesperrt, auch bei \code{cores = 1}. Zufaellige Einheiten
#' bekommen ihren Strom als Argument (Stroeme je Einheit, R/slc.R); damit
#' haengt das Ergebnis nicht von \code{cores} ab. R's Zufallszustand (\code{.Random.seed})
#' wird weder gelesen noch gesetzt.
#' \itemize{
#'   \item \code{cores = "auto"}: [.par_lapply_auto()].
#'   \item Feste Zahl >= 2 auf Unix (seit 1.6.4, Entscheidung 133): derselbe Weg wie \code{"auto"}, nur ohne
#'     Messung: [.par_auto_fork()] ueber alle Einheiten mit min(cores, Einheiten) Forks, Kern-Threads je Kind
#'     Prozessoren / Forks. Ergebnis, Ausgaben, Meldungen, Warnungen und Fehler wie \code{cores = 1}; endet ein Kind
#'     ohne Ergebnis: Fehler. Bis dahin \code{mclapply} ueber hoechstens 4 cores Pakete
#'     (\code{.par_lapply_fork}): Ausgaben und Warnungen der Einheiten gingen verloren, Fehler kamen als
#'     \code{try-error}-Elemente mit Warnung "k function calls resulted in an error" zurueck (Folgefehler oder still
#'     fehlende Zeilen in den Aufrufern), ein abgestuerztes Kind lieferte \code{NULL}.
#'   \item Windows: feste Zahl ueber einen PSOCK-Cluster (\code{parLapplyLB}) wie bis 1.6.3.
#' }
#' @keywords internal
#' @noRd
.par_lapply <- function(X, FUN, cores) {
  if (identical(cores, "auto")) return(.par_lapply_auto(X, FUN))   # seit 1.6.4: Planer
  if (cores <= 1 || length(X) <= 1) return(.sl_in_unit(lapply(X, FUN)))
  if (.Platform$OS.type == "unix") return(.par_lapply_fixed(X, FUN, cores))
  .sl_nthreads()                                               # Hinweis zu SIMLEV_THREADS hoechstens einmal, hier
  cl <- parallel::makePSOCKcluster(cores)
  on.exit(parallel::stopCluster(cl))
  parallel::clusterEvalQ(cl, { suppressPackageStartupMessages(library(SimLev))
    assign("in_unit", TRUE, envir = SimLev:::.sl_state) })      # Merker "in Einheit": globaler Zustand gesperrt
  # Kern-Threads je Prozess (seit 1.6.4, Entscheidung 41c): Prozessoren / Prozesse, mindestens 1
  parallel::clusterCall(cl, function(k) assign("thread_cap", k, envir = get(".sl_state", envir = asNamespace("SimLev"))),
                        .sl_unit_threads(min(as.integer(cores), length(X))))
  parallel::parLapplyLB(cl, X, FUN)
}

# Feste Zahl cores >= 2 auf Unix (seit 1.6.4, Entscheidung 133): alle Einheiten ueber .par_auto_fork mit
# c = min(cores, Einheiten) Forks (ganzzahlig abgeschnitten wie mclapply; unter 2 nacheinander wie lapply)
.par_lapply_fixed <- function(X, FUN, cores) {
  if (!is.vector(X) || is.object(X)) X <- as.list(X)              # wie lapply
  FUN <- match.fun(FUN)
  n <- length(X)
  c <- min(as.integer(cores), n)
  if (c < 2L) return(.sl_in_unit(lapply(X, FUN)))
  res <- .par_auto_fork(X, seq_len(n), FUN, c, .sl_unit_threads(c))
  names(res) <- names(X)
  res
}


#' Parallele Ausfuehrung mit cores = "auto" (seit 1.6.4, Entscheidungen 41b/41c)
#'
#' Ergebnis, Ausgaben, Meldungen, Warnungen und Fehler wie \code{cores = 1} (\code{lapply} als parallele Einheit):
#' \itemize{
#'   \item Messen: die ersten Einheiten laufen nacheinander im Elternprozess, bis die Startzeit eines weiteren
#'     Laufs (\code{.sl_par_probe}) vergangen ist (mindestens zwei Einheiten); Rechenzeit je Einheit = Mittel ohne
#'     die erste (sie enthaelt Anlaufkosten), bei nur einer Einheit deren Zeit; Ergebnisgroesse je Einheit aus
#'     \code{object.size}.
#'   \item Planen: \code{.sl_par_plan} (Kern sl_par_plan) waehlt Laeufe c und Kern-Threads je Lauf aus der Zahl der
#'     Prozessoren, dem freien Speicher, den restlichen Einheiten und den Kosten; c = 1: der Rest nacheinander.
#'   \item Verteilen (c > 1, nur Unix): Rest in hoechstens 2 c Pakete aufeinanderfolgender Einheiten, je Paket ein
#'     Fork (\code{mcparallel}), hoechstens c gleichzeitig, dynamisch zugeteilt. Im Kind schneidet
#'     \code{.par_rec_unit} Ausgaben, Meldungen und Warnungen jeder Einheit mit (nach dem ersten Fehler eines
#'     Pakets keine weiteren Einheiten); der Elternprozess gibt sie in Einheitenreihenfolge wieder, sobald alle
#'     Einheiten davor fertig sind, und loest den ersten Fehler in Einheitenreihenfolge erneut aus (laufende
#'     Kinder werden beendet). Endet ein Kind ohne Ergebnis: Fehler.
#'   \item Windows (PSOCK, Startkosten hier nicht gemessen) und ein Prozessor: nacheinander.
#'   \item Den Verteilweg (\code{.par_auto_fork}) nutzt seit 1.6.4 auch eine feste Zahl (\code{.par_lapply_fixed}).
#' }
#' @keywords internal
#' @noRd
.par_lapply_auto <- function(X, FUN) {
  if (!is.vector(X) || is.object(X)) X <- as.list(X)              # wie lapply
  FUN <- match.fun(FUN)
  n <- length(X)
  .sl_state$par_last <- c(probed = n, runs = 1L, threads = NA_integer_)   # letzter Plan (intern, fuer Proben)
  if (n <= 1L || .Platform$OS.type != "unix" || .sl_nprocs() < 2L) return(.sl_in_unit(lapply(X, FUN)))
  res <- vector("list", n)
  one <- function(i, ...) FUN(X[[i]], ...)                        # Aufruf wie in lapply: FUN(X[[i]], ...)
  probe <- .sl_par_probe(0L)
  k <- 0L; t_first <- 0; t_rest <- 0
  .sl_in_unit(repeat {
    k <- k + 1L
    t0 <- as.numeric(Sys.time())
    res[k] <- list(one(k))
    dt <- as.numeric(Sys.time()) - t0
    if (k == 1L) t_first <- dt else t_rest <- t_rest + dt
    if (k >= n || (k >= 2L && t_first + t_rest >= probe)) break
  })
  if (k < n) {
    u <- if (k >= 2L) t_rest / (k - 1L) else t_first
    pl <- .sl_par_plan(n - k, u, as.numeric(utils::object.size(res[seq_len(k)])) / k, 0L)
    .sl_state$par_last <- c(probed = k, runs = pl[1L], threads = pl[2L])
    idx <- (k + 1L):n
    res[idx] <- if (pl[1L] >= 2L) .par_auto_fork(X, idx, FUN, pl[1L], pl[2L])
                else .sl_in_unit(lapply(idx, one))
  }
  names(res) <- names(X)
  res
}

# Eine Einheit im Kind mitschneiden: list(ok, value, ev); ev = Ereignisse in Reihenfolge, je list(art, wert) mit art
# "o" (Ausgabe als Bytes), "m" (Meldung), "w" (Warnung); bei Fehler ok = FALSE und value = Bedingung
.par_rec_unit <- function(X, i, FUN) {
  ev <- list(); pos <- 0L
  rc <- rawConnection(raw(0), open = "w")
  sink(rc)
  flush_out <- function() {
    b <- rawConnectionValue(rc)
    if (length(b) > pos) { ev[[length(ev) + 1L]] <<- list("o", b[(pos + 1L):length(b)]); pos <<- length(b) }
  }
  r <- tryCatch(withCallingHandlers(list(ok = TRUE, value = FUN(X[[i]])),
                                    message = function(m) { flush_out(); ev[[length(ev) + 1L]] <<- list("m", m)
                                                            invokeRestart("muffleMessage") },
                                    warning = function(w) { flush_out(); ev[[length(ev) + 1L]] <<- list("w", w)
                                                            invokeRestart("muffleWarning") }),
                error = function(e) list(ok = FALSE, value = e))
  flush_out()
  sink()
  close(rc)
  r$ev <- ev
  r
}

# Ereignisse einer Einheit im Elternprozess wiedergeben (Meldungen und Warnungen als dieselben Bedingungen; der
# Hinweis zu SIMLEV_THREADS hoechstens einmal je Sitzung wie nacheinander)
.par_replay <- function(ev) {
  hint <- NULL
  for (e in ev) {
    if (e[[1L]] == "o") cat(rawToChar(e[[2L]]))
    else if (e[[1L]] == "m") {
      if (is.null(hint)) hint <- paste0(chk_msg("hinweis.prozessoren", "SIMLEV_THREADS", .sl_nprocs()), "\n")
      if (identical(conditionMessage(e[[2L]]), hint)) {
        if (isTRUE(.sl_state$threads_hint)) next
        assign("threads_hint", TRUE, envir = .sl_state)
      }
      message(e[[2L]])
    } else warning(e[[2L]])
  }
  invisible(NULL)
}

# Rest idx in Paketen auf c Forks (mcparallel), Kern-Threads je Kind cap; Wiedergabe in Einheitenreihenfolge
.par_auto_fork <- function(X, idx, FUN, c, cap) {
  m <- length(idx)
  n_pk <- min(m, 2L * c)                                          # 2 Pakete je Lauf (Kern: packs)
  packs <- unname(split(idx, ((seq_len(m) - 1) * n_pk) %/% m))
  parent <- Sys.getpid()
  run_pack <- function(ii) {
    .Call(C_sl_child_guard, parent)                               # seit 1.6.4 (K43 T2-B4): endet mit dem Elternprozess
    .sl_state$in_unit <- TRUE                                     # nur im Kind
    .sl_state$thread_cap <- cap
    out <- vector("list", length(ii))
    for (j in seq_along(ii)) {
      out[[j]] <- .par_rec_unit(X, ii[[j]], FUN)
      if (!out[[j]]$ok) { length(out) <- j; break }
    }
    out
  }
  res <- vector("list", m)
  got <- vector("list", n_pk); have <- logical(n_pk)
  running <- list(); nxt <- 1L; done <- 0L
  # Aufraeumen und Einsammeln ohne die Warnung "k parallel job(s) did not deliver a result" von mccollect (seit 1.6.4,
  # K43 T2-R5): ob ein Kind kein Ergebnis lieferte, prueft die Wiedergabe unten (Fehler)
  on.exit(for (r in running) {
    tools::pskill(r$job$pid); suppressWarnings(parallel::mccollect(r$job, wait = TRUE))
  }, add = TRUE)
  while (done < n_pk) {
    while (length(running) < c && nxt <= n_pk) {
      pk <- packs[[nxt]]
      job <- parallel::mcparallel(run_pack(pk), silent = FALSE)
      running[[as.character(job$pid)]] <- list(job = job, p = nxt)
      nxt <- nxt + 1L
    }
    r <- if (length(running))
      suppressWarnings(parallel::mccollect(lapply(running, `[[`, "job"), wait = FALSE, timeout = 0.02))
    for (pid in names(r)) {
      p <- running[[pid]]$p
      got[p] <- list(r[[pid]]); have[p] <- TRUE
      running[[pid]] <- NULL
    }
    while (done < n_pk && have[done + 1L]) {
      p <- done + 1L; out <- got[[p]]
      # Kind ohne Ergebnis: seit 1.6.4 (K43 T2-R4) Baustein ohne Nummer, in R und Python gleich (bis dahin
      # "par_lapply: Prozess endete ohne Ergebnis (Element k)" mit dem ersten Element des Pakets)
      if (!is.list(out) || inherits(out, "try-error")) chk_stop("ut2.prozess", "par_lapply")
      for (j in seq_along(out)) {
        .par_replay(out[[j]]$ev)
        if (!out[[j]]$ok) stop(out[[j]]$value)
        res[match(packs[[p]][j], idx)] <- list(out[[j]]$value)
      }
      got[p] <- list(NULL)
      done <- p
    }
  }
  res
}

# ─────────────────────────────────────────────────────────────────────────────
# Oeffentliche Funktionen
# ─────────────────────────────────────────────────────────────────────────────

#' Bootstrap-Pfade erzeugen
#'
#' Erzeugt \code{n} simulierte Preis-Pfade fuer alle Indizes der Konfiguration,
#' leitet daraus die Hebelprodukte ab und zieht Zusatzreihen mit. Eingabe ist
#' ein Datensatz mit historischen Renditen oder Kursen (Format siehe
#' [bootstrap_config()]); Ergebnis sind Pfadmatrizen im Speicher. Einen
#' einzelnen Pfad macht [bootstrap_data()] zum data.frame fuer [simulation()];
#' [withdrawal_paths()] wandelt alle Pfade in Periodenrenditen fuer
#' [withdrawal_simulation()] um. Fuer Strategievergleiche ueber viele Pfade
#' ohne Speicherung der Pfade dient [bootstrap_study()].
#'
#' @param data data.frame oder Matrix mit den in \code{config} genannten
#'   Spalten (Index-Spalten als Brutto-Renditen je Zeile oder, bei
#'   \code{input = "prices"}, als Kursniveaus; Zusatzreihen beliebig). Jede
#'   Zeile ist ein Simulationsschritt ("Tag"); eine Datumsspalte wird nicht
#'   ausgewertet.
#'   Seit 1.6.4 muessen die Spalten aus config Zahlen enthalten (Text, auch Zahlen als Text, ist ein Fehler).
#' @param config Objekt aus [bootstrap_config()].
#' @param method Verfahren (Standard in \code{bootstrap()}: \code{"raw"}, in
#'   \code{\link[=bootstrap_study]{bootstrap_study()}}: \code{"stationary"}). In Klammern die Eintraege von
#'   \code{params}, die das Verfahren verwendet:
#'   \describe{
#'   \item{"raw"}{IID-Zeilen-Bootstrap (Efron 1979); zerstoert Zeitabhaengigkeit (Nullmodell). Keine Parameter.}
#'   \item{"block"}{Moving Block Bootstrap (Kuensch 1989) (\code{block_length})}
#'   \item{"circular"}{Circular Block Bootstrap (Politis & Romano 1992) (\code{block_length})}
#'   \item{"stationary"}{Stationaerer Bootstrap (Politis & Romano 1994), geometrisch verteilte Bloecke (\code{L})}
#'   \item{"wild"}{Wild Bootstrap mit gemeinsamem Gewicht je Zeile fuer alle Reihen (\code{wild_type}); erhaelt die Chronologie}
#'   \item{"regime"}{Volatilitaetsregime-Markov-Bootstrap: Regime aus Quantilen der rollierenden Volatilitaet des Referenzindex (\code{n_regimes}, \code{vol_window})}
#'   \item{"evt"}{GPD-Tails des Referenzindex plus empirischer Bulk (\code{tail_prob}, \code{both_tails}); uebrige Indizes ueber das historische Verhaeltnis zum Referenzindex gekoppelt}
#'   \item{"tails"}{Empirische Tail-Schichtung des Referenzindex (\code{tail_prob})}
#'   \item{"reset"}{Chronologie mit zufaellig gespiegelten Segmenten (\code{p_break}); erhaelt die Chronologie}
#'   \item{"garch", "gjr_garch"}{(GJR-)GARCH(1,1) mit Filtered Historical Simulation (keine Parameter; Kopplung ueber \code{cross} in \code{\link[=bootstrap_config]{bootstrap_config()}}). Geschaetzt per Maximum Likelihood unter Normalverteilung mit der C-Bibliothek von SimLev (GJR mit \eqn{\alpha + \gamma \ge 0}, also auch \eqn{\gamma < 0}; bis Version 1.0.0 \eqn{\gamma \ge 0}; BFGS von sieben Rasterpunkten), notfalls mit Momentschaetzern; die Meldungen nennen den Weg "ml" bzw. "momente" (bis 0.10.0 "rugarch"/"optim")}
#'   \item{"ms_garch", "ms_ar_garch_m", "tvtp_ms_garch"}{Markov-Switching-GARCH-Familie: eigene ML-Schaetzung des MS-GARCH-Modells nach Haas, Mittnik und Paolella (2004), Normalverteilung, Varianzmodell "sGARCH" oder "gjrGARCH" je Regime (GJR mit \eqn{\alpha + \gamma \ge 0}, also auch \eqn{\gamma < 0}; BFGS mit analytischem Gradienten von 12 bzw. bei "gjrGARCH" 20 Startpunkten); "ms_ar_garch_m" zusaetzlich mit AR- und GARCH-in-Mean-Termen je Regime, "tvtp_ms_garch" mit zeitvariablen Uebergangswahrscheinlichkeiten (\code{ms_n_regimes}/\code{ms_garch_model}, \code{ms_ar_n_regimes}/\code{ms_ar_garch_model} bzw. \code{tvtp_n_regimes}/\code{tvtp_garch_model})}
#'   }
#'   Bei "wild" und "reset" muss \code{path_length} der Laenge der Historie
#'   entsprechen.
#' @param n Anzahl Pfade (Standard 1000); bei \code{ess = TRUE} das
#'   Gesamtbudget, das auf die Parameterkombinationen verteilt wird.
#'   Pfade, die nach \code{max_tries} Versuchen ungueltig bleiben, fehlen im
#'   Ergebnis.
#'   Seit 1.6.4 hoechstens 10^8.
#' @param params Benannte Liste von Verfahrensparametern; nicht angegebene
#'   Eintraege erhalten den Standardwert (Standard \code{list()} = alle
#'   Standardwerte). Je Verfahren werden nur die oben genannten Eintraege
#'   verwendet:
#'   \describe{
#'     \item{L}{Erwartete Blocklaenge in Zeilen fuer "stationary" (Zahl >= 1,
#'       Standard 20) oder \code{"auto"} ([bootstrap_block_length()], Spalte
#'       \code{stationary}).}
#'     \item{block_length}{Feste Blocklaenge in Zeilen fuer "block" und
#'       "circular" (ganze Zahl, Standard 20; bei "block" hoechstens Zeilen der
#'       Historie minus 1, bei "circular" hoechstens Zeilen der Historie) oder
#'       \code{"auto"} ([bootstrap_block_length()], Spalte \code{circular}).}
#'     \item{wild_type}{Gewichte beim Wild Bootstrap: 0 = Rademacher
#'       (Standard), 1 = Mammen, 2 = Standardnormal; andere Werte sind ein
#'       Fehler.}
#'     \item{n_regimes}{Anzahl Volatilitaetsregime fuer "regime" (Standard 2).}
#'     \item{vol_window}{Fensterlaenge der rollierenden Volatilitaet in Zeilen
#'       fuer "regime" (Standard 20).}
#'     \item{tail_prob}{Tail-Wahrscheinlichkeit je Seite als Anteil fuer "evt"
#'       und "tails" (Standard 0.05 = 5 Prozent).}
#'     \item{both_tails}{Logisch, nur "evt": auch den rechten Tail mit einer
#'       GPD modellieren (Standard \code{TRUE}).}
#'     \item{p_break}{Wahrscheinlichkeit je Zeile als Anteil (0 bis 1), dass
#'       bei "reset" ein neues Segment beginnt (Standard 0.02).}
#'     \item{ms_n_regimes, ms_ar_n_regimes, tvtp_n_regimes}{Anzahl Regime fuer
#'       "ms_garch", "ms_ar_garch_m" bzw. "tvtp_ms_garch" (Standard je 2). Hat die
#'       Reihe weniger deutlich getrennte Regime als angefordert (z. B. drei Regime
#'       auf einer Reihe mit nur einem oder zwei Volatilitaetszustaenden), kann ein
#'       Regime entarten: Verweilwahrscheinlichkeit nahe 0 (Meldung "P(stay)"),
#'       kaum oder keine Tage im Regimepfad, mitunter Persistenz nahe 1 mit
#'       unplausibel hoher unbedingter Varianz; die Log-Likelihood liegt dann kaum
#'       ueber der mit einem Regime weniger. In diesem Fall die Anzahl Regime
#'       verkleinern.}
#'     \item{ms_garch_model, ms_ar_garch_model, tvtp_garch_model}{Varianzmodell
#'       je Regime: "sGARCH" (GARCH(1,1)) oder "gjrGARCH" (GJR-GARCH(1,1),
#'       Standard je "gjrGARCH"); andere Werte sind ein Fehler.}
#'   }
#'   Der Eintrag \code{garch_order} (Standard \code{c(1, 1)}) ist vorhanden,
#'   aendert aber nichts: die GARCH-Verfahren schaetzen immer GARCH(1,1).
#' @param ess Logisch (Standard \code{FALSE}): ESS-gewichtete Gittersuche
#'   ueber Hyperparameter (wie im Original). Das Budget \code{n} wird invers
#'   zur effektiven Stichprobengroesse (ESS) je Kombination verteilt; die
#'   Pfade erhalten Gewichte (Mittel 1), mit denen [bootstrap_probability()]
#'   und \code{summary()} rechnen. Fuer "raw", "garch" und "gjr_garch" gibt es
#'   kein Standardgitter (dann normaler Bootstrap).
#'   Seit 1.6.4 braucht ess = TRUE mit dem Standardgitter bei stationary, block und circular mindestens 4 Renditen
#'   (sonst Fehler).
#' @param ess_grid Benannte Liste von Wertevektoren je Hyperparameter (z. B.
#'   \code{list(L = c(20, 50, 100))}); \code{NULL} (Standard) = Standardgitter
#'   des Verfahrens (z. B. \code{L} bzw. \code{block_length} 5, 10, 20, 30,
#'   50, 75, 100 Zeilen, begrenzt auf die halbe Historienlaenge). Nur bei
#'   \code{ess = TRUE} verwendet.
#'   Seit 1.6.4 nur Zahlen (und Wahrheitswerte); Text wie ms_garch_model ist ein Fehler.
#' @param progress Logisch: Fortschritts- und Abschlussmeldung per
#'   \code{message()} ausgeben (Standard \code{TRUE}).
#' @param path_length Pfadlaenge in Zeilen (simulierte Schritte, ganze Zahl,
#'   mindestens 1); \code{NULL} (Standard) = Anzahl verwendbarer Zeilen der Historie. Damit lassen sich
#'   z. B. 50-jaehrige Pfade aus 30 Jahren Historie erzeugen. Jeder Pfad hat
#'   \code{path_length + 1} Zeilen (Startzeile plus Schritte).
#'   Seit 1.6.4 hoechstens 36600 (100 Jahre in Tagen).
#' @param seed Ganzzahliger Startwert (\eqn{|seed| < 2^{53}}); \code{NULL} (Standard) = genau
#'   einmal aus dem Zufallszustand von SimLev gezogen (siehe [simlev_seed()]; ganze Zahl von 0
#'   bis \eqn{2^{31} - 1}, im Ergebnis unter \code{seed} gespeichert, damit reproduzierbar).
#'   Jeder Pfad i erhaelt einen eigenen Strom (Sprung um \eqn{2^{128}} Schritte je Pfad), so
#'   dass Pfad i unabhaengig von \code{cores} (und bei [bootstrap_study()] von
#'   \code{chunk_size}) ist und [bootstrap()] und [bootstrap_study()] mit gleichem Seed (und
#'   gleichen Daten, Verfahren, \code{params}, \code{ess} und \code{path_length})
#'   dieselben Pfade erzeugen. Mit angegebenem Seed bleibt der Zufallszustand von SimLev
#'   unveraendert; mit \code{seed = NULL} liefern wiederholte Aufrufe verschiedene Pfade.
#'   \code{set.seed()} wirkt nicht.
#' @param cores Anzahl Prozesse (Fork auf Unix, PSOCK-Cluster auf Windows):
#'   \code{"auto"} (Standard seit 1.6.4; bis 1.6.3 1) oder eine ganze Zahl >= 1.
#'   Mit \code{"auto"} rechnet SimLev die ersten Einheiten nacheinander, misst ihre Rechenzeit und waehlt
#'   dann die Zahl der Prozesse und der Kern-Threads je Prozess selbst (Planer, gleiche Regel in R,
#'   Python und Julia): hoechstens Zahl der freien Prozessoren (Prozessoren minus andere laufende Prozesse gleicher oder hoeherer Prioritaet), so
#'   viele, wie der freie Speicher traegt, und
#'   nur, wenn die Startkosten der Prozesse kleiner sind als der Gewinn (kleine Rechnungen bleiben bei
#'   einem Prozess; unter Windows immer einer). Ausgaben, Meldungen, Warnungen und Fehler der Einheiten
#'   erscheinen dabei wie mit \code{cores = 1}, in Einheitenreihenfolge.
#'   Eine feste Zahl rechnet wie bis 1.6.3; hoechstens Zahl der Prozessoren: mehr wird mit einem Hinweis
#'   begrenzt.
#'   Das Ergebnis haengt nicht von cores ab.
#'   Je paralleler Einheit rechnen die Kerne mit hoechstens Zahl der Prozessoren / Prozesse Threads (mindestens 1).
#'   Bei den MS-GARCH-Verfahren (\code{ms_garch}, \code{ms_ar_garch_m},
#'   \code{tvtp_ms_garch}) rechnet der Fit seine Startpunkte zudem auf so vielen Threads (mit
#'   \code{"auto"} auf den Kern-Threads: Zahl der Prozessoren bzw. SIMLEV_THREADS); das Ergebnis haengt davon nicht ab.
#' @param max_tries Versuche je Pfad (Standard 10), falls ein Pfad ungueltig
#'   ist (Indexrendite <= 0 oder nicht endlich). Ein Totalverlust eines
#'   Hebelprodukts macht den Pfad nicht ungueltig.
#'
#' @return Objekt der Klasse \code{bootstrap_result}, eine Liste mit
#'   \describe{
#'     \item{paths}{Liste von Matrizen, eine je gueltigem Pfad, mit
#'       \code{path_length + 1} Zeilen: Zeile 1 = Startwert 100 fuer Indizes
#'       und Hebelprodukte, danach je Simulationsschritt. Spalten: Indizes,
#'       Hebelprodukte, Zusatzreihen in dieser Reihenfolge. Keine Datumsspalte.
#'       Zusatzreihen mit \code{aux_type = "rate"} (Prozent p. a.) und ohne
#'       Angabe in \code{aux_type} enthalten die
#'       Originalwerte der gezogenen Zeilen, solche mit \code{"level"} das
#'       kumulierte Niveau (Startwert = erste verwendete Historienzeile bzw.
#'       Startzeile der Kurse, danach die historischen Zeilenverhaeltnisse der
#'       gezogenen Zeilen kumuliert; keine Spruenge an Blockgrenzen). Bei
#'       Zusatzreihen traegt jede Matrix zusaetzlich das Attribut
#'       \code{aux_level}: diese Niveau-Variante fuer alle Zusatzreihen (fuer
#'       \code{"level"}-Reihen identisch mit der Pfadspalte). Ihr Startwert
#'       (Zeile 1) ist die erste Historienzeile (bzw. Startzeile der Kurse) und
#'       damit fuer alle Pfade gleich; frueher war es der Wert der
#'       Historienzeile vor dem ersten gezogenen Schritt (je Pfad verschieden).
#'       Die Zeilenverhaeltnisse sind unveraendert die historischen
#'       Verhaeltnisse der gezogenen Zeilen, koennen aber durch die andere
#'       Startskalierung um 1 ulp von frueheren Laeufen abweichen (beabsichtigt;
#'       betrifft z. B. [withdrawal_paths()] mit \code{inflation_type = "level"}
#'       und \code{keep_aux}). Es dient als Inflation fuer Reihen ohne Angabe
#'       in \code{aux_type} ([withdrawal_paths()] mit \code{inflation_type =
#'       "level"}, \code{keep_aux} in [bootstrap_study()]); fuer Reihen mit
#'       \code{aux_type = "rate"} wird es dort nicht verwendet.}
#'     \item{weights}{Pfadgewichte (Mittel 1; ohne ESS alle 1).}
#'     \item{method, config, seed}{Verfahren, Konfiguration und verwendeter Seed.}
#'     \item{params}{Vollstaendige Parameterliste (bei ESS: der ersten Kombination).}
#'     \item{ess, ess_design}{Logisch, ob ESS verwendet wurde, und das ESS-Design
#'       (data.frame je Kombination mit Parametern, \code{ess_per_boot},
#'       \code{n_sims}, \code{weight} u. a.) bzw. \code{NULL}.}
#'     \item{param_values}{Bei ESS: Parameterliste je Pfad, sonst \code{NULL}.}
#'     \item{knockout_rate}{Anteil der ungueltigen Versuche an allen
#'       Versuchen in Prozent (\code{100 * stats$knockout_rate}).}
#'     \item{stats}{Liste mit \code{attempts} (Versuche gesamt),
#'       \code{success} (gueltige Pfade), \code{null} (Versuche ohne gueltigen
#'       Pfad) und \code{knockout_rate} (\code{null / attempts}, als Anteil).}
#'   }
#' @examples
#' # Brutto-Tagesrenditen zweier Indizes und ein Zins in Prozent p. a.
#' set.seed(2)
#' d <- data.frame(us = 1 + rnorm(1500, 3e-4, 0.01))
#' d$eu <- d$us * (1 + rnorm(1500, 0, 0.004))
#' d$rate <- 2
#' cfg <- bootstrap_config(c(us = "us", eu = "eu"), aux = c(rate = "rate"),
#'   letfs = list(list(base = "eu", leverage = 2, finance = "rate")))
#' b <- bootstrap(d, cfg, "stationary", n = 5, params = list(L = 50), seed = 1)
#' b
#' dim(b$paths[[1]])
#' head(b$paths[[1]], 3)
#'
#' # Kursniveaus, feste Blocklaenge, kuerzere Pfade; Pfad 1 in simulation()
#' set.seed(1); n <- 3 * 365
#' p <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
#' p$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
#' cfg2 <- bootstrap_config(c(akt = "aktien"), input = "prices",
#'   letfs = list(list(base = "akt", leverage = 2, finance = 3, expense = 0.6)))
#' b2 <- bootstrap(p, cfg2, "block", n = 3, params = list(block_length = 30),
#'   path_length = 500, seed = 7, progress = FALSE)
#' x <- bootstrap_data(b2, 1, start = "2030-01-01")
#' res <- simulation(x, create_strategy(akt_l2 = asset_config("etf", "bnh", partial_exemption = 30)))
#' res$cagr
#'
#' # CPI als Niveau, Zins als Rate: der Pfad enthaelt den kumulierten CPI
#' set.seed(3)
#' h <- data.frame(us = 100 * cumprod(1 + rnorm(1501, 3e-4, 0.01)),
#'                 cpi = 100 * 1.02^((0:1500) / 365), zins = 2)
#' cfg3 <- bootstrap_config(c(us = "us"), aux = c(cpi = "cpi", zins = "zins"), input = "prices",
#'   aux_type = c(cpi = "level", zins = "rate"))
#' b3 <- bootstrap(h, cfg3, "stationary", n = 2, params = list(L = 50), seed = 1, progress = FALSE)
#' range(diff(log(b3$paths[[1]][, "cpi"])) * 365)   # stets log(1.02): keine Spruenge
#' @references Haas, M., Mittnik, S. & Paolella, M.S. (2004), A New Approach
#'   to Markov-Switching GARCH Models, Journal of Financial Econometrics 2(4)
#'   (Verfahren "ms_garch", "ms_ar_garch_m", "tvtp_ms_garch"); Hamilton, J.D.
#'   (1989), Econometrica 57(2) (Filter).
#' @seealso [bootstrap_config()], [bootstrap_data()], [bootstrap_study()],
#'   [withdrawal_paths()]
#' @export
bootstrap <- function(data, config, method = "raw", n = 1000, params = list(), ess = FALSE,
                      ess_grid = NULL, path_length = NULL, max_tries = 10L, seed = NULL,
                      cores = "auto", progress = TRUE) {
  t0 <- Sys.time()
  setup <- .boot_setup(data, config, method, n, params, ess, ess_grid, path_length, cores, max_tries, progress, "bootstrap")
  cores <- setup$cores   # begrenzt (Entscheidung 41)
  if (is.null(seed)) seed <- .sl_next_seed() else .sl_check_seed(seed, "bootstrap")   # NULL -> einmal k aus G
  streams <- .sl_streams(seed, setup$n_paths)                 # U_i = J^i(S_0) je Pfad
  res <- .par_lapply(seq_len(setup$n_paths), function(i)
    .draw_path(setup, i, streams[[i]], config, method, max_tries), cores)
  ok <- !vapply(res, function(r) is.null(r$path), TRUE)
  tries <- vapply(res, `[[`, 0, "tries")
  if (!any(ok)) stop(sprintf("Keine g\u00fcltigen Pfade erzeugt (%d Versuche; letzte Ursache: %s).",
                             sum(tries), res[[length(res)]]$err %||% "unbekannt"))
  ko <- (sum(tries) - sum(ok)) / sum(tries)                 # Anteil ungueltiger Versuche
  w <- setup$weights[ok]; w <- w / sum(w) * length(w)
  if (progress) message(sprintf("Bootstrap '%s': %d Pfade x %d Tage in %.1f s (Knockout-Rate %.2f %%).",
                                method, sum(ok), setup$n_out, as.numeric(difftime(Sys.time(), t0, units = "secs")),
                                100 * ko))
  structure(list(
    paths = lapply(res[ok], `[[`, "path"), weights = w, method = method, config = config,
    params = setup$base_p[[1]], ess = !is.null(setup$design), ess_design = setup$design,
    param_values = if (!is.null(setup$design)) setup$combos[setup$combo_of_path[ok]] else NULL,
    seed = seed, knockout_rate = 100 * ko,
    stats = list(attempts = sum(tries), success = sum(ok), null = sum(tries) - sum(ok), knockout_rate = ko)
  ), class = "bootstrap_result")
}

#' @rdname SimLevBootstrap-methods
#' @export
print.bootstrap_result <- function(x, ...) {
  cat(sprintf("SimLev Bootstrap '%s': %d Pfade, je %d Zeilen x %d Spalten (%s)%s\n",
              x$method, length(x$paths), nrow(x$paths[[1]]), ncol(x$paths[[1]]),
              paste(colnames(x$paths[[1]]), collapse = ", "),
              if (isTRUE(x$ess)) sprintf(", ESS-gewichtet (%d Kombinationen)", nrow(x$ess_design)) else ""))
  invisible(x)
}

#' Bootstrap-Ergebnis validieren und bereinigen
#'
#' Entfernt leere, unvollstaendige (\code{NA}) oder nicht endliche Pfade sowie
#' Pfade, deren Zeilenzahl von der haeufigsten Zeilenzahl abweicht, und
#' normiert die Gewichte neu auf Mittel 1 (wie im Original). Nuetzlich vor der
#' Weiterverarbeitung von [bootstrap()]-Ergebnissen, die z. B. von Hand
#' veraendert oder aus mehreren Laeufen zusammengesetzt wurden.
#'
#' @param result Objekt der Klasse \code{bootstrap_result} aus [bootstrap()].
#' @param min_rows Mindestzeilenzahl je Pfad; \code{NULL} (Standard) = keine
#'   Mindestlaenge.
#' @param verbose Logisch: Anzahl entfernter und gueltiger Pfade ausgeben
#'   (Standard \code{TRUE}).
#' @return Das bereinigte \code{bootstrap_result} (\code{paths},
#'   \code{weights} und \code{param_values} gekuerzt). Bleibt kein Pfad
#'   uebrig, bricht die Funktion mit einem Fehler ab.
#' @examples
#' set.seed(1)
#' d <- data.frame(r = 1 + rnorm(500, 3e-4, 0.01))
#' b <- bootstrap(d, bootstrap_config(c(idx = "r")), "stationary", n = 3,
#'   params = list(L = 20), seed = 1, progress = FALSE)
#' b$paths[[2]][10, 1] <- NA      # einen Pfad beschaedigen
#' b <- bootstrap_validate(b)
#' length(b$paths)
#' @seealso [bootstrap()], [bootstrap_data()]
#' @export
bootstrap_validate <- function(result, min_rows = NULL, verbose = TRUE) {
  if (!inherits(result, "bootstrap_result")) chk_stop("klasse", "bootstrap_validate", "result", "bootstrap()")
  if (!length(result$paths)) chk_stop("rs.keine_pfade", "bootstrap_validate")
  if (!is.null(min_rows)) chk_int1(min_rows, "bootstrap_validate", "min_rows", lo = 0)   # seit 1.6.4
  chk_bool1(verbose, "bootstrap_validate", "verbose")
  P <- result$paths
  ok <- vapply(P, function(p) !is.null(p) && (is.matrix(p) || is.data.frame(p)) && nrow(p) > 0 &&
                 !anyNA(p) && all(is.finite(as.matrix(p))), TRUE)
  if (any(ok)) {
    len <- vapply(P, function(p) if (is.null(p)) NA_integer_ else nrow(p), 0L)
    mode_len <- as.numeric(names(sort(table(len[ok]), decreasing = TRUE))[1])
    ok <- ok & len == mode_len
    if (!is.null(min_rows)) ok <- ok & len >= min_rows
  }
  if (!any(ok)) stop("Keine g\u00fcltigen Pfade nach Validierung \u00fcbrig")
  if (verbose && any(!ok)) cat(sprintf("%d von %d Pfaden entfernt\n", sum(!ok), length(ok)))
  result$paths <- P[ok]
  if (!is.null(result$weights)) { w <- result$weights[ok]; result$weights <- w / sum(w) * length(w) }
  if (!is.null(result$param_values)) result$param_values <- result$param_values[ok]
  if (verbose) cat(sprintf("%d valide Pfade, je %d Zeilen\n", length(result$paths), nrow(result$paths[[1]])))
  result
}

#' Bootstrap-Pfad als data.frame fuer simulation()
#'
#' Wandelt einen Pfad aus [bootstrap()] in einen data.frame mit Datumsspalte
#' um, der direkt an [simulation()] uebergeben werden kann. Die Spaltennamen
#' sind die Pfadnamen aus [bootstrap_config()] (Indizes, Hebelprodukte,
#' Zusatzreihen); die Strategie muss Assets mit diesen Namen verwenden.
#'
#' @param result \code{bootstrap_result} aus [bootstrap()] oder eine einzelne
#'   Pfadmatrix (z. B. \code{result$paths[[i]]}).
#'   Seit 1.6.4 auch wie beschrieben ein einzelner Pfad: Zahlenmatrix (Spalten ohne Namen heissen V1, V2, ...) oder
#'   Tabelle aus Zahlenspalten.
#' @param i Pfadnummer (Standard 1); nur bei \code{bootstrap_result} verwendet.
#' @param dates Datumsvektor mit genau so vielen Elementen wie der Pfad Zeilen
#'   hat (\code{path_length + 1}), z. B. ein Handelstagskalender;
#'   \code{NULL} (Standard) = aufeinanderfolgende Kalendertage ab
#'   \code{start}.
#' @param start Startdatum fuer \code{dates = NULL} (Zeichenkette oder
#'   Date, Standard "2000-01-01").
#' @return data.frame mit Spalte \code{date} (Klasse Date) und allen
#'   Pfadspalten (Kursniveaus mit Startwert 100; Zusatzreihen mit
#'   \code{aux_type = "rate"} (Prozent p. a.) und ohne Angabe als
#'   Originalwerte der gezogenen Zeilen, mit \code{"level"} als kumuliertes
#'   Niveau, z. B. ein durchgehender CPI ohne Spruenge an Blockgrenzen; siehe
#'   [bootstrap_config()]). Bei einem \code{bootstrap_result}, dessen
#'   Konfiguration Reihen ausdruecklich als \code{aux_type = "rate"}
#'   kennzeichnet, traegt der data.frame das Attribut \code{aux_type} mit
#'   diesen Reihen (z. B. \code{c(infl = "rate")}); [withdrawal_cohorts()]
#'   behandelt sie als Inflationsrate in Prozent p. a. Ohne solche Angabe
#'   entfaellt das Attribut (Ergebnis wie bisher). Umformungen wie
#'   \code{transform()}, \code{merge()}, \code{cbind()} oder CSV-Export
#'   entfernen das Attribut; dann in [withdrawal_cohorts()]
#'   \code{inflation_type = "rate_pa"} angeben.
#' @examples
#' set.seed(1)
#' d <- data.frame(r = 1 + rnorm(800, 3e-4, 0.01))
#' cfg <- bootstrap_config(c(idx = "r"), letfs = list(list(base = "idx", leverage = 2)))
#' b <- bootstrap(d, cfg, "stationary", n = 2, params = list(L = 20),
#'   path_length = 400, seed = 1, progress = FALSE)
#' x <- bootstrap_data(b, i = 2, start = "2030-01-01")
#' head(x, 3)
#' res <- simulation(x, create_strategy(idx_l2 = asset_config("etf", "bnh")))
#' res$cagr
#' @seealso [bootstrap()], [simulation()], [bootstrap_study()]
#' @export
bootstrap_data <- function(result, i = 1L, dates = NULL, start = "2000-01-01") {
  # seit 1.6.4: Pfadnummer als ganze Zahl von 1 bis zur Pfadzahl (vorher z. B. i = 2.5 abgeschnitten), start als Datum
  is_res <- inherits(result, "bootstrap_result")
  if (is_res) chk_int1(i, "bootstrap_data", "i", lo = 1, hi = length(result$paths))
  # seit 1.6.4 (Entscheidung 30) wie dokumentiert auch ein einzelner Pfad: Zahlenmatrix oder Tabelle aus Zahlenspalten
  # (bis 1.6.3 "$ operator is invalid for atomic vectors" bei einer Matrix)
  else if (!((is.matrix(result) && is.numeric(result) && ncol(result) >= 1L) ||
             (is.data.frame(result) && ncol(result) >= 1L && all(vapply(result, is.numeric, NA)))))
    chk_stop("pfad", "bootstrap_data")
  chk_date1(start, "bootstrap_data", "start")
  P <- if (is_res) result$paths[[i]] else result
  chk_nofactor(dates, "bootstrap_data", "dates")   # seit 1.6.4 (Entscheidung 15; bis 1.6.3 still in Text umgewandelt)
  if (is.null(dates)) dates <- seq.Date(.to_date(start, "start"), by = "day", length.out = nrow(P))
  if (length(dates) != nrow(P)) chk_stop("rs.dates_pfad", "bootstrap_data", length(dates), nrow(P))
  out <- data.frame(date = .to_date(dates, "dates"), as.data.frame(P), check.names = FALSE)
  # ausdruecklich als "rate" gekennzeichnete Reihen mitgeben (fuer withdrawal_cohorts); sonst kein Attribut
  set <- if (is_res) result$config$aux_type_set else NULL
  if (length(set)) set <- set[result$config$aux_type[set] %in% "rate"]
  if (length(set)) attr(out, "aux_type") <- result$config$aux_type[set]
  out
}

# Kennzahlen, bei denen ein kleinerer Wert guenstiger ist (Drawdowns); verwendet von
# summary() einer bootstrap_study() (p_better) und param_plateau() (unguenstigster Nachbar)
.lower_better <- c("max_drawdown", "avg_drawdown", "dd_q50", "dd_q90", "ulcer_index", "longest_drawdown")

#' Standard-Kennzahlen fuer bootstrap_study()
#'
#' Fasst ein Ergebnis von [simulation()] zu einem benannten Kennzahlenvektor
#' zusammen. Standardwert des Arguments \code{metrics} von
#' [bootstrap_study()], [sensitivity_grid()], [sensitivity_rebalancing()] und
#' [sensitivity_leverage()]; eigene Kennzahlfunktionen muessen ebenfalls ein
#' \code{SimLevResult} entgegennehmen und einen benannten numerischen Vektor
#' liefern.
#'
#' @param res \code{SimLevResult} aus [simulation()].
#' @return Benannter numerischer Vektor mit
#'   \describe{
#'     \item{cagr, ttwror}{CAGR und annualisierte TTWROR als Anteil (0.05 = 5 Prozent).
#'       Mit Sparplan (Einzahlungen nach dem Starttag, \code{res$external_flows}) ist
#'       \code{cagr} die geldgewichtete Jahresrendite (XIRR, siehe [simulation()]),
#'       \code{ttwror} die zeitgewichtete.}
#'     \item{final_value}{Endwert des Depots (Waehrungseinheiten).}
#'     \item{max_drawdown, avg_drawdown}{Maximaler und mittlerer Drawdown
#'       (Mittel ueber Zeilen mit Drawdown > 0), als positiver Anteil.}
#'     \item{dd_q50, dd_q90}{Median und 90-Prozent-Quantil der Drawdowns ueber alle
#'       Zeilen, als Anteil.}
#'     \item{ulcer_index}{Ulcer Index (Drawdowns als Anteil).}
#'     \item{longest_drawdown}{Laengste Drawdown-Phase in Zeilen der Daten.}
#'     \item{sharpe, sortino, calmar, omega}{Kennzahlen aus
#'       \code{res$statistics}, wie in [simulation()] berechnet.}
#'     \item{mean, sd, skewness, kurtosis, lpm, hpm}{Momente und partielle
#'       Momente der Renditen je Zeile aus \code{res$statistics}.}
#'     \item{taxes}{Gezahlte Steuern gesamt (Waehrungseinheiten; 0 ohne
#'       Steuerbericht).}
#'     \item{trades}{Kaeufe plus Verkaeufe je Jahr, summiert ueber alle Assets.}
#'   }
#' @examples
#' set.seed(1); n <- 3 * 365
#' d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
#' d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
#' res <- simulation(d, create_strategy(aktien = asset_config("etf", "bnh")))
#' round(bootstrap_study_metrics(res), 4)
#' @seealso [bootstrap_study()], [sensitivity_grid()], [simulation()]
#' @export
bootstrap_study_metrics <- function(res) {
  if (!inherits(res, "SimLevResult")) chk_stop("klasse", "bootstrap_study_metrics", "res", "simulation()")   # seit 1.6.4
  s <- res$statistics
  dq <- stats::quantile(res$drawdowns, c(0.5, 0.9), names = FALSE)
  c(cagr = res$cagr, ttwror = res$ttwror, final_value = utils::tail(res$worth, 1),
    max_drawdown = s$max_drawdown, avg_drawdown = s$average_drawdown, dd_q50 = dq[1], dd_q90 = dq[2],
    ulcer_index = s$ulcer_index, longest_drawdown = s$longest_drawdown,
    sharpe = s$sharpe, sortino = s$sortino, calmar = s$calmar, omega = s$omega,
    mean = s$mean, sd = s$sd, skewness = s$skewness, kurtosis = s$kurtosis, lpm = s$lpm, hpm = s$hpm,
    taxes = res$tax_report$total_taxes_paid %||% 0,
    trades = sum(res$buys) + sum(res$sells))
}

#' Strategien auf Bootstrap-Pfaden auswerten
#'
#' Erzeugt Bootstrap-Pfade wie [bootstrap()], berechnet je Pfad die Signale,
#' simuliert alle Strategien mit [simulation()] auf DEMSELBEN Pfad (Common
#' Random Numbers, gepaarter Vergleich) und speichert nur Kennzahlen. Pfade
#' werden nach der Auswertung verworfen; der Speicherbedarf ist daher
#' unabhaengig von \code{n}. Entspricht der Pipeline aus '06 Bootstraps'
#' (Chunks, Parallelisierung), ohne die Pfade zwischenzuspeichern.
#'
#' Ablauf je Pfad: Pfadmatrix erzeugen, mit \code{dates} zu einem data.frame
#' wie in [bootstrap_data()] machen (Spalte \code{date} plus Pfadspalten aus
#' [bootstrap_config()]), je Strategie optional \code{signal} und \code{map}
#' anwenden, die ersten \code{burn_in} Zeilen verwerfen, [simulation()] mit
#' \code{sim_args} aufrufen und \code{metrics} auswerten. Weiterverarbeitung:
#' \code{summary()} und \code{plot()} (siehe [SimLevBootstrap-methods]),
#' [bootstrap_probability()]; mit \code{keep_returns} zusaetzlich
#' [withdrawal_paths()] bzw. [withdrawal_simulation()] (Entnahmephase auf den
#' simulierten Strategiepfaden).
#'
#' @inheritParams bootstrap
#' @param strategies Benannte, nicht leere Liste. Jedes Element ist entweder
#'   direkt eine Strategie ([create_strategy()]) oder eine Liste mit
#'   \describe{
#'     \item{strategy}{Strategie (Pflicht).}
#'     \item{signal}{Optional Funktion, die den Pfad-data.frame (alle Zeilen
#'       einschliesslich \code{burn_in}) erhaelt und entweder einen data.frame
#'       (ersetzt den Pfad-data.frame) oder eine benannte Liste von Spalten
#'       gleicher Laenge zurueckgibt, z. B. \code{list(buy = ..., sell = ...)};
#'       \code{NA} in logischen Spalten wird zu \code{FALSE}.}
#'     \item{args}{Liste von Argumenten fuer [simulation()], die
#'       \code{sim_args} fuer diese Strategie ueberschreiben.}
#'     \item{map}{Spalten-Aliase als benannter Zeichenvektor Alias ->
#'       Pfadspalte, z. B. \code{c(letf = "eu_l2")}.}
#'   }
#'   Die Asset-Namen der Strategien muessen Spaltennamen des Pfads (bzw.
#'   Aliase aus \code{map}) sein. Schlaegt Signal, Simulation oder
#'   Kennzahlberechnung fuer einen Pfad fehl, fehlt diese Zeile im Ergebnis;
#'   die Funktion warnt mit der Anzahl und der haeufigsten Fehlermeldung
#'   (alle in \code{errors}). Schlagen alle Kombinationen fehl, bricht sie
#'   mit dieser Meldung ab. Warnungen aus Signal, Simulation und Kennzahlen
#'   werden je Pfad gesammelt, dedupliziert und am Ende als eine Warnung
#'   ausgegeben (mit Anzahl der betroffenen Pfade; alle in \code{warnings});
#'   bei \code{cores > 1} ebenso.
#' @param sim_args Benannte Liste gemeinsamer Argumente fuer \code{\link[=simulation]{simulation()}}
#'   (Standard \code{list()}), z. B. \code{list(start_value = 1000,
#'     tax = tax_profile())}: Argumente von \code{\link[=simulation]{simulation()}} ausser \code{data} und \code{strategy},
#'   also auch Bausteine (z. B. \code{dca = dca_plan(100, 1)}, \code{tax = tax_profile()}) und
#'   Pfade zu Parametern der Bausteine (\code{"dca.value"}, siehe
#'   \code{\link{sensitivity_grid}}). Alte Einzelargumente (bis 0.8.0, vor den Bausteinen, z. B.
#'   \code{dca_value}) ergeben einen Fehler, der den Baustein nennt.
#' @param dates,start Kalender der Pfade: \code{dates} ist ein
#'   Datumsvektor der Laenge \code{path_length + 1}; \code{NULL} (Standard) =
#'   aufeinanderfolgende Kalendertage ab \code{start} (Standard
#'   "2000-01-01"), siehe [bootstrap_data()].
#' @param burn_in Anzahl Anfangszeilen des Pfads, die nach der
#'   Signalberechnung verworfen werden (Signal-Vorlauf, z. B. 730 Tage fuer
#'   eine 430-Tage-SMA; Standard 0). Muss kleiner als \code{path_length} sein.
#' @param metrics Funktion \code{SimLevResult -> benannter numerischer Vektor}
#'   (Standard [bootstrap_study_metrics()]); die Namen werden zu Spalten von
#'   \code{results}.
#'   Seit 1.6.4 muessen die Namen der Kennzahlen eindeutig und nicht leer sein und duerfen nicht path, weight, combo,
#'   tries oder strategy heissen (sonst Fehler nach dem Rechnen).
#' @param benchmark Name einer Strategie aus \code{strategies} als Vergleich
#'   fuer die gepaarte Auswertung in \code{summary()}; \code{NULL} (Standard)
#'   = keine.
#' @param chunk_size Pfade je Arbeitspaket (Standard 25); Einheit der
#'   Parallelisierung und der Zwischenspeicherung.
#' @param chunk_dir Optional (Standard \code{NULL}) Verzeichnis fuer
#'   Zwischenergebnisse je Chunk (Dateien \code{chunk_<Nr>_seed<Seed>_r.rds},
#'   bei \code{keep_returns} mit Frequenz-Suffix, bei \code{keep_paths} > 0 mit
#'   Suffix \code{_keep<k>}, jeweils vor \code{_r.rds}; Python schreibt
#'   \code{_py.pkl}, Julia \code{_jl.bin}). Liegt zu einem Chunk nur eine Datei
#'   einer anderen Sprache oder der Form bis 1.6.2 (\code{chunk_<Nr>_seed<Seed>.rds}),
#'   bricht die Studie mit einer Meldung ab. Vorhandene Dateien werden
#'   gelesen statt neu gerechnet; so wird ein abgebrochener Lauf mit
#'   gleichem Seed fortgesetzt. Die Dateien werden nur ueber Chunk-Nummer,
#'   Seed, \code{keep_returns} und \code{keep_paths} zugeordnet: bei geaenderten
#'   Strategien, Daten oder Parametern ein neues Verzeichnis verwenden.
#'   Seit 1.6.4 werden die Dateien atomar geschrieben (temporaerer Name, dann umbenannt); eine unvollstaendige oder
#'   beschaedigte Datei bricht bei jedem cores mit derselben Meldung ab.
#' @param keep_paths Pfadmatrizen zusaetzlich zurueckgeben (Diagnose):
#'   \code{TRUE} = alle Pfade, \code{FALSE} oder 0 (Standard) = keine, ganze
#'   Zahl k >= 1 = die ersten k Pfade (k groesser als die Pfadzahl: alle);
#'   \code{NA}, Text, Vektoren, negative oder nicht ganze Zahlen ergeben einen
#'   Fehler. Speicherbedarf: Alle behaltenen Pfadmatrizen bleiben im Ergebnis
#'   und gehen bei \code{cores > 1} auch durch die Prozessgrenze, ungefaehr
#'   Pfade x (Pfadlaenge + 1) x Reihen x 8 Byte (z. B. 10 000 Pfade x 7 300
#'   Tage x 3 Reihen x 8 Byte = 1,75 GB).
#' @param keep_returns \code{"none"} (Standard) oder \code{"year"},
#'   \code{"quarter"}, \code{"month"}: speichert je Strategie und Pfad die
#'   zeitgewichteten Brutto-Periodenrenditen (aus [result_index()], Perioden
#'   ab dem ersten Tag nach \code{burn_in}). Die Studie kann dann direkt an
#'   [withdrawal_simulation()] bzw. [withdrawal_paths()] uebergeben werden.
#' @param keep_aux Zeichenvektor mit Namen von Zusatzreihen aus \code{config},
#'   deren Brutto-Inflation je Periode ebenfalls gespeichert wird (Inflation
#'   fuer die Entnahmephase, Argument \code{inflation} von
#'   [withdrawal_paths()]); nur zusammen mit \code{keep_returns} wirksam. Die
#'   Behandlung folgt \code{aux_type} in [bootstrap_config()]:
#'   \code{"level"} (Preisindex) = Periodenverhaeltnisse des kumulierten
#'   Niveaus in der Pfadspalte; ausdruecklich \code{"rate"} = Inflationsrate
#'   in Prozent pro Jahr (2 = 2 % p. a.; nicht je Datenperiode, kein Anteil),
#'   je Pfadzeile ueber die Kalendertage aus \code{dates} aufgezinst,
#'   \eqn{\prod (1 + r/100)^{Tage/365.25}} ueber die Zeilen der Periode
#'   (wie \code{inflation_type = "rate_pa"} in [withdrawal_paths()], das
#'   dann nicht erneut angegeben werden muss). Ohne Angabe in
#'   \code{aux_type} gilt die Reihe wie bisher als Niveau (Niveau-Variante
#'   des Pfads, Attribut \code{aux_level}, siehe [bootstrap()]: Verhaeltnis
#'   der kumulierten Zeilenverhaeltnisse an den Periodenenden), so dass jede
#'   Periode die Inflation der gezogenen Zeilen eines Preisindex enthaelt;
#'   eine Ratenspalte ergibt so keine Inflation in Prozent p. a. Sind gespeicherte Faktoren nicht
#'   endlich oder <= 0 (z. B. eine nicht gekennzeichnete Zinsreihe mit
#'   Vorzeichenwechsel), warnt die Funktion, und [withdrawal_paths()] bricht
#'   mit dieser Reihe als Inflation ab. Standard \code{NULL}.
#' @param cores Anzahl Prozesse; parallelisiert wird ueber Chunks:
#'   \code{"auto"} (Standard seit 1.6.4; bis 1.6.3 1) oder eine ganze Zahl >= 1.
#'   Mit \code{"auto"} rechnet SimLev die ersten Einheiten nacheinander, misst ihre Rechenzeit und waehlt
#'   dann die Zahl der Prozesse und der Kern-Threads je Prozess selbst (Planer, gleiche Regel in R,
#'   Python und Julia): hoechstens Zahl der freien Prozessoren (Prozessoren minus andere laufende Prozesse gleicher oder hoeherer Prioritaet), so
#'   viele, wie der freie Speicher traegt, und
#'   nur, wenn die Startkosten der Prozesse kleiner sind als der Gewinn (kleine Rechnungen bleiben bei
#'   einem Prozess; unter Windows immer einer). Ausgaben, Meldungen, Warnungen und Fehler der Einheiten
#'   erscheinen dabei wie mit \code{cores = 1}, in Einheitenreihenfolge.
#'   Eine feste Zahl rechnet wie bis 1.6.3; hoechstens Zahl der Prozessoren: mehr wird mit einem Hinweis
#'   begrenzt.
#'   Das Ergebnis haengt nicht von cores ab.
#'   Je paralleler Einheit rechnen die Kerne mit hoechstens Zahl der Prozessoren / Prozesse Threads (mindestens 1).
#'   Der MS-GARCH-Fit der Vorberechnung nutzt ebenso viele Threads (mit \code{"auto"} die Kern-Threads;
#'   Ergebnis unabhaengig davon).
#' @param progress Logisch: Fortschrittsmeldungen per \code{message()}
#'   (Standard \code{TRUE}; Meldung je Chunk nur bei \code{cores = 1} und \code{cores = "auto"}).
#'
#' @return Objekt der Klasse \code{SimLevBootstrapStudy}, eine Liste mit
#'   \describe{
#'     \item{results}{data.frame mit einer Zeile je Pfad und Strategie:
#'       \code{strategy}, \code{path} (Pfadnummer), \code{weight}
#'       (Pfadgewicht), \code{combo} (ESS-Kombination), \code{tries}
#'       (Versuche) und den Kennzahlen aus \code{metrics} (bei
#'       [bootstrap_study_metrics()] z. B. \code{cagr} und \code{max_drawdown} als Anteil).}
#'     \item{method, n_paths, strategies, benchmark, config, params, seed,
#'       burn_in, path_length, elapsed}{Metadaten (\code{elapsed} in Sekunden).}
#'     \item{ess_design, path_weights}{ESS-Design (oder \code{NULL}) und
#'       Gewichte aller Pfade.}
#'     \item{paths}{Liste der mit \code{keep_paths} behaltenen Pfadmatrizen.}
#'     \item{returns, aux_returns}{Bei \code{keep_returns}: je Strategie bzw.
#'       Zusatzreihe eine Matrix (Perioden x Pfade) von Brutto-Periodenrenditen
#'       bzw. Brutto-Inflation (z. B. 1.05 bzw. 1.02), sonst \code{NULL}.}
#'     \item{returns_frequency, returns_dates}{Frequenz und Periodenenden
#'       (Datum) der gespeicherten Renditen.}
#'     \item{errors}{data.frame der Fehler der Einzelsimulationen
#'       (\code{strategy}, \code{stage} = "Signal", "Simulation" oder
#'       "Kennzahlen", \code{message}, \code{n} = Anzahl Pfade,
#'       \code{first_path}), nach Haeufigkeit sortiert; \code{NULL}, wenn
#'       keine.}
#'     \item{warnings}{data.frame der deduplizierten Warnungen
#'       (\code{strategy}, \code{message}, \code{n} = Anzahl Pfade mit
#'       dieser Warnung, \code{first_path}); \code{NULL}, wenn keine.}
#'   }
#' @examples
#' # Kleine Studie: 4 Pfade, 2 Jahre (plus 100 Tage Vorlauf), 2 Strategien
#' set.seed(1); n <- 3 * 365
#' d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
#' d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
#' d$zins <- 2                                   # Prozent p. a.
#' cfg <- bootstrap_config(c(akt = "aktien"), aux = c(zins = "zins"), input = "prices",
#'   letfs = list(list(base = "akt", leverage = 2, finance = "zins", expense = 0.6)))
#' sma <- function(df, k = 100) {
#'   s <- stats::filter(df$akt_l2, rep(1 / k, k), sides = 1)
#'   list(buy = df$akt_l2 >= s, sell = df$akt_l2 < s)
#' }
#' st <- bootstrap_study(d, cfg, "stationary", n = 4, params = list(L = 30),
#'   path_length = 2 * 365 + 100, burn_in = 100, cores = 1, seed = 1,
#'   progress = FALSE, benchmark = "bnh", keep_returns = "year",
#'   strategies = list(
#'     bnh = create_strategy(akt_l2 = asset_config("etf", "bnh", partial_exemption = 30)),
#'     sma = list(strategy = create_strategy(akt_l2 = asset_config("etf", "signal",
#'                  partial_exemption = 30, signal_buy = "buy", signal_sell = "sell")),
#'                signal = sma)))
#' st$results[, c("strategy", "path", "cagr", "max_drawdown")]
#' bootstrap_probability(st, cagr > 0, joint = cagr > 0 & max_drawdown <= 0.5)
#' wp <- withdrawal_paths(st, strategy = "sma", inflation = 2)
#' dim(wp$returns)                               # Jahre x Pfade
#' \dontrun{
#' # Typische Groessenordnung mit echten Daten (hist: Renditespalten us_ret,
#' # eu_ret und Zins eu_rate in Prozent p. a.)
#' cfg <- bootstrap_config(c(us = "us_ret", eu = "eu_ret"), regime_index = "us",
#'   letfs = list(list(base = "eu", leverage = 2, finance = "rate", expense = 0.5)),
#'   aux = c(rate = "eu_rate"))
#' sma_signal <- function(df, n = 310) {
#'   s <- stats::filter(df$eu, rep(1 / n, n), sides = 1)
#'   list(buy = df$eu >= s, sell = df$eu < s)
#' }
#' st <- bootstrap_study(hist, cfg, "stationary", n = 1000, params = list(L = 250),
#'   strategies = list(
#'     bnh = create_strategy(eu_l2 = asset_config("etf", "bnh", partial_exemption = 30)),
#'     sma = list(strategy = create_strategy(eu_l2 = asset_config("etf", "signal",
#'                  partial_exemption = 30, signal_buy = "buy", signal_sell = "sell")),
#'                signal = sma_signal)),
#'   sim_args = list(start_value = 1000, tax = tax_profile()),
#'   burn_in = 730, benchmark = "bnh", cores = 8, seed = 42)
#' summary(st)
#' bootstrap_probability(st, ttwror >= 0.10 & max_drawdown <= 0.6)
#' }
#' @references Haas, M., Mittnik, S. & Paolella, M.S. (2004), A New Approach
#'   to Markov-Switching GARCH Models, Journal of Financial Econometrics 2(4)
#'   (Verfahren "ms_garch", "ms_ar_garch_m", "tvtp_ms_garch"); Hamilton, J.D.
#'   (1989), Econometrica 57(2) (Filter).
#' @seealso [bootstrap()], [bootstrap_probability()], [simulation()],
#'   [withdrawal_paths()]
#' @export
bootstrap_study <- function(data, config, method = "stationary", n = 1000, strategies,
                            params = list(), ess = FALSE, ess_grid = NULL, path_length = NULL,
                            dates = NULL, start = "2000-01-01", burn_in = 0L,
                            sim_args = list(), metrics = bootstrap_study_metrics, benchmark = NULL,
                            chunk_dir = NULL, keep_paths = 0L,
                            keep_returns = c("none", "year", "quarter", "month"), keep_aux = NULL,
                            max_tries = 10L, chunk_size = 25L, seed = NULL, cores = "auto", progress = TRUE) {
  own_cache <- .sim_study(); on.exit(.sim_study_end(own_cache), add = TRUE)   # Pruef-Cache je Studie (seit 1.5.1)
  .e5_choice(keep_returns, c("none", "year", "quarter", "month"), "bootstrap_study", "keep_returns")   # seit 1.6.4 (K43 T2-N4) Pruefung vor match.arg (Meldung auswahl)
  keep_returns <- match.arg(keep_returns)
  fn <- "bootstrap_study"
  # seit 1.6.4: config vor keep_aux (vorher "$ operator is invalid"), keep_aux nur Text ohne Doppel
  if (!inherits(config, "bootstrap_config")) chk_stop("klasse", "bootstrap_study", "config", "bootstrap_config()")
  if (!is.null(keep_aux) && (!is.character(keep_aux) || !all(keep_aux %in% config$aux_names)))
    chk_stop("ut2.keep_aux", "bootstrap_study")
  if (anyDuplicated(keep_aux)) chk_stop("e2.doppelt", fn, "keep_aux")
  t0 <- Sys.time()
  if (missing(strategies) || !is.list(strategies) || inherits(strategies, "strategy") || !length(strategies) ||
      is.null(names(strategies)) || anyNA(names(strategies)) || any(names(strategies) == ""))
    chk_stop("ut2.strategies", "bootstrap_study")
  if (anyDuplicated(names(strategies))) chk_stop("e2.doppelt", fn, "strategies")   # vorher: R erste, Julia letzte
  specs <- lapply(strategies, function(s) {
    if (is.list(s) && !is.null(s$strategy) && !inherits(s, "strategy")) s else list(strategy = s)
  })
  for (sp in specs) .e2_check_strategy(sp$strategy)   # wie simulation(), vor dem Ziehen (seit 1.6.4)
  if (!is.null(benchmark) && (!is.character(benchmark) || length(benchmark) != 1L || !benchmark %in% names(specs)))
    chk_stop("ut2.benchmark_name", "bootstrap_study")
  if (!is.null(sim_args) && !is.list(sim_args)) chk_stop("liste", fn, "sim_args")
  if (!is.function(metrics)) chk_stop("e2.funktion", fn, "metrics")
  if (!is.null(chunk_dir)) {
    chk_name1(chunk_dir, fn, "chunk_dir")
    if (file.exists(chunk_dir) && !dir.exists(chunk_dir)) chk_stop("e2.verzeichnis", fn, "chunk_dir")
  }
  chk_int1(burn_in, fn, "burn_in", lo = 0)
  chk_int1(chunk_size, fn, "chunk_size")
  chk_date1(start, fn, "start")
  # Argumente fuer simulation() je Strategie einmal aufloesen (Bausteine, Pfade; alte flache Namen: Fehler)
  sim_args <- .sim_args_set(list(), sim_args, "bootstrap_study")
  for (nm in names(specs)) specs[[nm]]$sim <- .sim_args_set(sim_args, specs[[nm]]$args, "bootstrap_study")
  setup <- .boot_setup(data, config, method, n, params, ess, ess_grid, path_length, cores, max_tries, progress, fn)
  cores <- setup$cores   # begrenzt (Entscheidung 41)
  keep_paths <- .keep_count(keep_paths, setup$n_paths, "bootstrap_study")   # TRUE = alle Pfade
  chk_nofactor(dates, "bootstrap_study", "dates")   # seit 1.6.4 (Entscheidung 15; bis 1.6.3 still in Text umgewandelt)
  if (is.null(dates)) dates <- seq.Date(.to_date(start, "start"), by = "day", length.out = setup$n_out + 1L)
  if (length(dates) != setup$n_out + 1L) chk_stop("rs.dates_studie", fn, setup$n_out + 1L)
  dates <- .to_date(dates, "dates")
  if (burn_in >= setup$n_out) chk_stop("rs.burn_in", fn)
  if (is.null(seed)) seed <- .sl_next_seed() else .sl_check_seed(seed, "bootstrap_study")   # NULL -> einmal k aus G
  streams <- .sl_streams(seed, setup$n_paths)                 # U_i = J^i(S_0) je Pfad
  chunks <- split(seq_len(setup$n_paths), ceiling(seq_len(setup$n_paths) / chunk_size))
  chunk_file <- function(ci) NULL
  cached <- vector("list", length(chunks))
  if (!is.null(chunk_dir)) {
    dir.create(chunk_dir, showWarnings = FALSE, recursive = TRUE)
    chunk_file <- function(ci) file.path(chunk_dir, paste0(.chunk_stem(ci, seed, keep_returns, keep_paths), "_r.rds"))
    .chunk_pruefen(chunk_dir, length(chunks), seed, keep_returns, keep_paths, "_r.rds")
    # seit 1.6.4 (Entscheidung 29): vorhandene Zwischendateien vor dem Rechnen lesen; eine unvollstaendige oder
    # beschaedigte Datei bricht bei jedem cores mit derselben Meldung ab (bis 1.6.3 bei cores > 1 nur Warnung und
    # fehlende Pfade)
    for (ci in seq_along(chunks)) {
      f <- chunk_file(ci)
      if (!file.exists(f)) next
      x <- tryCatch(readRDS(f), error = function(e) NULL)
      if (!is.list(x) || length(x) != length(chunks[[ci]])) chk_stop("chunk_kaputt", fn, ci)
      cached[ci] <- list(x)
    }
  }
  sim_rows <- (burn_in + 1L):(setup$n_out + 1L)
  ret_ends <- if (keep_returns != "none") .anniv_ends(dates[sim_rows], keep_returns) else NULL
  if (!is.null(ret_ends) && length(ret_ends) < 2) chk_stop("rs.burn_in_kurz", fn)
  per_ret <- function(v) { v <- v[ret_ends]; v[-1] / v[-length(v)] }
  # keep_aux: Inflationsniveau je Pfadzeile. aux_type "rate" (ausdruecklich): Rate in Prozent p. a.
  # ueber die Kalendertage aufgezinst; "level": Pfadspalte (kumuliertes Niveau); ohne Angabe wie
  # bisher die Niveau-Variante (Attribut aux_level), da Originalwerte an Blockgrenzen springen
  rate_aux <- intersect(keep_aux, names(which((config$aux_type %||% character(0))[config$aux_type_set %||% character(0)] == "rate")))
  dt_sim <- as.numeric(diff(dates[sim_rows])) / 365.25
  aux_level_of <- function(P, a) {
    if (a %in% rate_aux) return(cumprod(c(1, (1 + P[sim_rows[-1], a] / 100)^dt_sim)))
    if (isTRUE(config$aux_type[[a]] == "level")) P[sim_rows, a] else attr(P, "aux_level")[sim_rows, a]
  }

  eval_path <- function(i) {
    dp <- .draw_path(setup, i, streams[[i]], config, method, max_tries)
    if (is.null(dp$path)) return(NULL)
    df0 <- data.frame(date = dates, as.data.frame(dp$path), check.names = FALSE)
    df_cut <- NULL   # Ausschnitt nach burn_in fuer Strategien ohne signal und map: seit 1.6.3 einmal je Pfad
    rows <- lapply(names(specs), function(nm) {
      sp <- specs[[nm]]; df <- df0; wr <- character()
      # Warnungen je Pfad sammeln (statt verschlucken), Fehler mit Stufe und Meldung zurueckgeben
      catch_w <- function(expr) withCallingHandlers(expr, warning = function(w) { wr <<- c(wr, conditionMessage(w)); invokeRestart("muffleWarning") })
      fail <- function(stage, msg) list(row = NULL, ret = NULL, err = c(stage = stage, message = msg), warn = unique(wr))
      if (!is.null(sp$signal)) {
        sg <- tryCatch(catch_w(sp$signal(df)), error = function(e) e)
        if (inherits(sg, "error")) return(fail("Signal", conditionMessage(sg)))
        if (is.null(sg)) return(fail("Signal", "Signal-Funktion lieferte NULL"))
        if (is.data.frame(sg)) df <- sg else for (k in names(sg)) {
          v <- sg[[k]]; if (is.logical(v)) v[is.na(v)] <- FALSE; df[[k]] <- v }
      }
      if (!is.null(sp$map)) for (a in names(sp$map)) df[[a]] <- df[[sp$map[[a]]]]
      if (burn_in > 0) {
        if (is.null(sp$signal) && is.null(sp$map)) {
          if (is.null(df_cut)) df_cut <<- df0[(burn_in + 1L):nrow(df0), , drop = FALSE]
          df <- df_cut
        } else df <- df[(burn_in + 1L):nrow(df), , drop = FALSE]
      }
      res <- tryCatch(suppressMessages(catch_w(.sim_call(df, sp$strategy, sp$sim))), error = function(e) e)
      if (inherits(res, "error")) return(fail("Simulation", conditionMessage(res)))
      m <- tryCatch(catch_w(metrics(res)), error = function(e) e)
      if (inherits(m, "error")) return(fail("Kennzahlen", conditionMessage(m)))
      if (is.null(m)) return(fail("Kennzahlen", "metrics() lieferte NULL"))
      list(row = c(path = i, weight = setup$weights[i], combo = setup$combo_of_path[i], tries = dp$tries, m),
           ret = if (!is.null(ret_ends)) per_ret(result_index(res)$value) else NULL, warn = unique(wr))
    })
    names(rows) <- names(specs)
    aux_ret <- if (!is.null(ret_ends) && length(keep_aux))
      lapply(stats::setNames(keep_aux, keep_aux), function(a) per_ret(aux_level_of(dp$path, a))) else NULL
    list(id = i, rows = rows, aux = aux_ret, path = if (i <= keep_paths) dp$path else NULL)
  }
  run_chunk <- function(ci) {
    if (!is.null(cached[[ci]])) return(cached[[ci]])
    f <- chunk_file(ci)
    out <- lapply(chunks[[ci]], eval_path)
    if (!is.null(f)) {   # seit 1.6.4 atomar: erst unter einem temporaeren Namen, dann umbenennen (Entscheidung 29)
      tmp <- paste0(f, ".tmp", Sys.getpid())
      saveRDS(out, tmp)
      if (!file.rename(tmp, f)) { unlink(tmp); saveRDS(out, f) }
    }
    # seit 1.6.4 bei jedem cores (Entscheidung 135; bis dahin nur bei cores = 1 und "auto")
    if (progress) message(sprintf("  Chunk %d/%d fertig (%.0f s)", ci, length(chunks),
                                  as.numeric(difftime(Sys.time(), t0, units = "secs"))))
    out
  }
  if (progress) message(sprintf("Bootstrap-Studie '%s': %d Pfade x %d Strategien, %d Chunks, %s Kern(e)",
                                method, setup$n_paths, length(specs), length(chunks), format(cores)))
  res <- .par_lapply(seq_along(chunks), run_chunk, cores)
  # seit 1.6.4 (K43 KR/UT2) ohne die Behandlung von try-error-Chunks ("k Chunks mit Fehler"): seit Entscheidung 133
  # loest jeder Weg von .par_lapply den ersten Fehler aus (Unix wie cores = 1, Windows parLapplyLB selbst)
  res <- unlist(res, recursive = FALSE)
  # seit 1.6.4 (Entscheidung 28): Namen der Kennzahlen eindeutig, nicht leer und keine feste Spalte (bis 1.6.3 je
  # Sprache verschiedene falsche Tabellen); geprueft nach dem Rechnen, bei jedem cores gleich
  for (r in res) for (nm in names(specs)) {
    rw <- r$rows[[nm]]$row
    if (is.null(rw)) next
    mn <- names(rw)[-(1:4)]
    if (anyNA(mn) || any(mn == "") || anyDuplicated(mn) ||
        any(mn %in% c("path", "weight", "combo", "tries", "strategy")))
      chk_stop("kennzahl_namen", fn)
  }
  tab <- do.call(rbind, lapply(names(specs), function(nm) {
    m <- do.call(rbind, lapply(res, function(r) r$rows[[nm]]$row))
    if (is.null(m)) return(NULL)
    data.frame(strategy = nm, m, check.names = FALSE, stringsAsFactors = FALSE)
  }))
  # Fehler und Warnungen der Einzelsimulationen je Strategie zusammenfassen (Anzahl = Pfade)
  # seit 1.6.4 (A-059) die Teile je Pfad und Strategie in vorab angelegten Listen, am Ende einmal unlist (bis 1.6.3 c()
  # je Eintrag, quadratisch in der Zahl der Eintraege); gleiche Vektoren in gleicher Reihenfolge
  cond_tab <- function(field) {
    m <- length(res) * length(specs)
    stl <- vector("list", m); sgl <- vector("list", m); msl <- vector("list", m); pal <- vector("list", m); j <- 0L
    for (r in res) for (nm in names(specs)) { v <- r$rows[[nm]][[field]]
      if (!length(v)) next
      j <- j + 1L
      if (field == "err") { sgl[j] <- list(v[["stage"]]); v <- v[["message"]] } else sgl[[j]] <- rep(NA_character_, length(v))
      stl[[j]] <- rep(nm, length(v)); msl[j] <- list(v); pal[[j]] <- rep(as.integer(r$id), length(v)) }
    st <- c(character(), unlist(stl)); sg <- c(character(), unlist(sgl)); ms <- c(character(), unlist(msl))
    pa <- c(integer(), unlist(pal))
    if (!length(st)) return(NULL)
    key <- paste(st, sg, ms, sep = "\r"); first <- !duplicated(key)
    out <- data.frame(strategy = st[first], stage = sg[first], message = ms[first], n = as.integer(table(key)[key[first]]),
                      first_path = pa[first], stringsAsFactors = FALSE)
    if (field == "warn") out$stage <- NULL
    out <- out[order(-out$n), , drop = FALSE]; rownames(out) <- NULL; out
  }
  errs <- cond_tab("err"); warns <- cond_tab("warn")
  first_err <- if (!is.null(errs)) sprintf("Strategie '%s', %s, %d-mal: %s", errs$strategy[1], errs$stage[1], errs$n[1], errs$message[1]) else NULL
  if (is.null(tab)) stop(if (is.null(first_err)) "Keine Strategie-Ergebnisse - Strategie, Signale und sim_args pr\u00fcfen."
                         else sprintf("Keine Strategie-Ergebnisse: alle %d Pfad-Strategie-Kombinationen fehlgeschlagen (%d verschiedene Fehlermeldung(en)). H\u00e4ufigster Fehler (%s) - Strategie, Signale und sim_args pr\u00fcfen.",
                                      setup$n_paths * length(specs), nrow(errs), first_err))
  rownames(tab) <- NULL
  n_fail <- setup$n_paths * length(specs) - nrow(tab)
  if (n_fail > 0) warning(sprintf("%d Pfad-Strategie-Kombinationen ohne Ergebnis (Simulation/Signal fehlgeschlagen)%s.", n_fail,
                                  if (is.null(first_err)) "" else sprintf("; h\u00e4ufigster Fehler (%s); alle Fehler in $errors", first_err)))
  if (!is.null(warns)) {
    k <- min(3L, nrow(warns))
    warning(sprintf("Warnungen der Einzelsimulationen (%d verschiedene, zusammengefasst; alle in $warnings): %s%s", nrow(warns),
                    paste(sprintf("[Strategie '%s', %d von %d Pfaden] %s", warns$strategy[1:k], warns$n[1:k], setup$n_paths, warns$message[1:k]), collapse = "; "),
                    if (nrow(warns) > k) sprintf("; ... und %d weitere", nrow(warns) - k) else ""), call. = FALSE)
  }
  returns <- aux_returns <- NULL
  if (!is.null(ret_ends)) {
    n_per <- length(ret_ends) - 1L
    ids <- vapply(res, function(r) if (is.null(r)) NA_integer_ else as.integer(r$id), 0L)
    fill_mat <- function(get) {
      M <- matrix(NA_real_, n_per, setup$n_paths)
      for (j in seq_along(res)) if (!is.na(ids[j])) { v <- get(res[[j]]); if (!is.null(v)) M[, ids[j]] <- v }
      M
    }
    returns <- lapply(stats::setNames(names(specs), names(specs)), function(nm) fill_mat(function(r) r$rows[[nm]]$ret))
    if (length(keep_aux)) aux_returns <- lapply(stats::setNames(keep_aux, keep_aux), function(a) fill_mat(function(r) r$aux[[a]]))
    for (a in keep_aux) { r <- aux_returns[[a]]; r <- r[!is.na(r)]       # Raten statt Niveaus ergeben unsinnige Faktoren
      if (any(!is.finite(r) | r <= 0))
        warning(sprintf(if (a %in% rate_aux) "keep_aux: Zusatzreihe '%s' (aux_type 'rate') ergibt nicht endliche oder nicht positive Periodenfaktoren (z. B. %s; Rate <= -100 %%?); als Inflation in withdrawal_paths()/withdrawal_simulation() nicht verwendbar."
                        else "keep_aux: Zusatzreihe '%s' ist kein positives Niveau (Periodenverh\u00e4ltnisse nicht endlich oder <= 0, z. B. %s); als Inflation in withdrawal_paths()/withdrawal_simulation() nicht verwendbar. F\u00fcr eine Rate aux_type = c(<Name> = 'rate') in bootstrap_config() angeben.",
                        a, format(r[!is.finite(r) | r <= 0][1], digits = 4))) }
  }
  elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  if (progress) message(sprintf("Fertig: %d Ergebniszeilen in %.1f s.", nrow(tab), elapsed))
  structure(list(
    results = tab, method = method, n_paths = setup$n_paths, strategies = names(specs),
    benchmark = benchmark, config = config, params = setup$base_p[[1]], ess_design = setup$design,
    seed = seed, burn_in = burn_in, path_length = setup$n_out, elapsed = elapsed,
    paths = Filter(Negate(is.null), lapply(res, `[[`, "path")),
    returns = returns, aux_returns = aux_returns, returns_frequency = if (keep_returns != "none") keep_returns else NULL,
    returns_dates = if (!is.null(ret_ends)) dates[sim_rows][ret_ends] else NULL,
    path_weights = setup$weights, errors = errs, warnings = warns
  ), class = "SimLevBootstrapStudy")
}

#' Chunk-Dateien von bootstrap_study(chunk_dir) (seit 1.6.3 je Sprache)
#'
#' Name: <Stamm><Kennung>, Stamm chunk_<Nr>_seed<Seed>[_<keep_returns>][_keep<k>], Kennung je Sprache: R "_r.rds"
#' (saveRDS), Python "_py.pkl" (pickle), Julia "_jl.bin" (eigenes Binaerformat); bis 1.6.2 in allen Sprachen
#' "<Stamm>.rds" mit drei Formaten. .chunk_pruefen bricht ab, wenn zu einem Chunk ohne eigene Datei eine Datei
#' einer anderen Sprache oder der alten Form vorliegt (gleiche Meldung in R, Python und Julia).
#' @keywords internal
#' @noRd
.chunk_stem <- function(ci, seed, keep_returns, keep_paths)
  sprintf("chunk_%05d_seed%.0f%s%s", ci, seed, if (keep_returns != "none") paste0("_", keep_returns) else "",
          if (keep_paths > 0) sprintf("_keep%.0f", keep_paths) else "")
.CHUNK_KENNUNG <- c(".rds", "_r.rds", "_py.pkl", "_jl.bin")
.chunk_meldung <- function(datei)
  sprintf("chunk_dir: '%s' stammt von einer anderen Sprache oder einer \u00e4lteren Fassung von SimLev (bis 1.6.2) und wird nicht gelesen; je Sprache ein eigenes Verzeichnis verwenden.", datei)
.chunk_pruefen <- function(dir, n_chunks, seed, keep_returns, keep_paths, eigen) {
  for (ci in seq_len(n_chunks)) {
    st <- .chunk_stem(ci, seed, keep_returns, keep_paths)
    if (file.exists(file.path(dir, paste0(st, eigen)))) next
    for (k in setdiff(.CHUNK_KENNUNG, eigen))
      if (file.exists(file.path(dir, paste0(st, k)))) stop(.chunk_meldung(paste0(st, k)))
  }
  invisible(NULL)
}

#' Anzahl behaltener Pfade aus keep_paths
#'
#' Zweck: gemeinsame Pruefung von keep_paths in bootstrap_study() und withdrawal_simulation(): TRUE = alle
#' Pfade, FALSE oder 0 = keine, ganze Zahl k >= 1 = die ersten k Pfade; k > n still alle.
#' Eingabe: x (keep_paths), n (Anzahl Pfade; Inf, wenn noch unbekannt), who (Aufrufer fuer die Meldung).
#' Ausgabe: Anzahl in 0..n (Zahl). Fehler bei NA, Text, Vektor, negativen oder nicht ganzen Zahlen (seit 1.6.4 ohne
#' den Eingabewert in der Meldung).
#' @keywords internal
#' @noRd
.keep_count <- function(x, n, who) {
  if (is.logical(x) && length(x) == 1L && !is.na(x)) return(if (x) n else 0)
  if (!is.numeric(x) || length(x) != 1L || !is.finite(x) || x < 0 || x != round(x))
    chk_stop("ut2.keep_paths", who)   # seit 1.6.4 aus der Tabelle (K43 T2-B6)
  min(as.numeric(x), n)
}

#' Gewichtete Quantile (gewichteter Typ 7)
#'
#' Gewichtete Version von Typ 7 nach Hyndman & Fan (1996) in der Form von
#' Akinshin (2023): Jeder sortierte Wert \eqn{x_{(i)}} belegt auf (0, 1) das
#' Intervall \eqn{[S_{i-1}, S_i]} der normierten kumulierten Gewichte; das
#' Quantil ist \eqn{\sum_i x_{(i)} (F(S_i) - F(S_{i-1}))} mit \eqn{F} der
#' Verteilungsfunktion der Gleichverteilung auf
#' \eqn{[(h - 1) / n^*, h / n^*]}, \eqn{h = (n^* - 1) p + 1} und der
#' Kish-Stichprobengroesse \eqn{n^* = (\sum w)^2 / \sum w^2}. Bei gleichen
#' Gewichten ist \eqn{n^* = n}, das Fenster deckt genau die Werte
#' \eqn{\lfloor h \rfloor} und \eqn{\lfloor h \rfloor + 1} mit den
#' Anteilen von Typ 7 ab - das Verfahren ist dann Typ 7 und haengt stetig von
#' den Gewichten ab (kein Wechsel des Verfahrens bei fast gleichen
#' Gewichten). Exakt gleiche Gewichte rechnen ueber
#' [stats::quantile()] (Typ 7, bitgleich). Das Ergebnis ist ein gewichtetes
#' Mittel benachbarter Werte und liegt immer zwischen Minimum und Maximum.
#' Nicht endliche Werte bzw. Gewichte entfallen; Gewichte 0 tragen nicht bei.
#' @references Hyndman, R. J. & Fan, Y. (1996), Sample quantiles in
#'   statistical packages, The American Statistician 50(4); Akinshin, A.
#'   (2023), Weighted quantile estimators, arXiv:2304.07265.
#' @keywords internal
#' @noRd
.wquantile <- function(x, w, probs) {
  ok <- is.finite(x) & is.finite(w); x <- x[ok]; w <- w[ok]
  if (!length(x)) return(rep(NA_real_, length(probs)))
  if (length(unique(w)) == 1L) return(stats::quantile(x, probs, names = FALSE, type = 7))
  sw <- sum(w); if (!(sw > 0)) return(rep(NA_real_, length(probs)))
  o <- order(x); x <- x[o]; w <- w[o] / sw
  r <- cumsum(w); r[length(r)] <- 1; l <- c(0, r[-length(r)])  # Intervall je Wert auf (0, 1)
  ne <- 1 / sum(w^2)                                            # Kish-Stichprobengroesse
  vapply(probs, function(p) {
    a <- (ne - 1) * p / ne                                      # Fenster [(h - 1) / n*, h / n*], h = (n* - 1) p + 1
    Fu <- function(u) pmin(pmax((u - a) * ne, 0), 1)
    sum((Fu(r) - Fu(l)) * x)
  }, 0)
}

#' Wahrscheinlichkeiten aus einer Bootstrap-Studie
#'
#' Wertet beliebige logische Bedingungen je Strategie ueber alle Pfade einer
#' [bootstrap_study()] aus (mit den Pfadgewichten, also ESS-gewichtet), z. B.
#' die gemeinsame Wahrscheinlichkeit, eine Mindestrendite zu erreichen und
#' einen maximalen Drawdown nicht zu ueberschreiten (wie \code{calc_metrics} in
#' '06 Bootstraps').
#'
#' Die Bedingungen werden zeilenweise in \code{study$results} ausgewertet;
#' verwendbar sind dort alle Spalten, also die Kennzahlen aus \code{metrics}
#' (bei [bootstrap_study_metrics()] z. B. \code{cagr}, \code{ttwror},
#' \code{max_drawdown} als Anteil) sowie \code{path}, \code{weight},
#' \code{combo} und \code{tries}. Zeilen mit \code{NA}-Ergebnis zaehlen nicht.
#' Freie Variablen in den Bedingungen (z. B. eine Schwelle \code{thr}) werden
#' in der Umgebung des Aufrufs gesucht (auch lokale Variablen einer
#' aufrufenden Funktion), Spalten von \code{study$results} haben Vorrang.
#'
#' @param study Objekt der Klasse \code{SimLevBootstrapStudy} aus
#'   [bootstrap_study()].
#' @param ... Benannte oder unbenannte Bedingungen in Kennzahlnamen, z. B.
#'   \code{ttwror >= 0.13}, \code{joint = ttwror >= 0.13 & max_drawdown <= 0.95}.
#'   Unbenannte Bedingungen werden nach ihrem Ausdruck benannt.
#' @param thresholds Optional (Standard \code{NULL}) benannte Liste je
#'   Strategiename mit einer benannten Liste von Ausdruecken (\code{quote()}),
#'   z. B. \code{list(sma = list(ziel = quote(cagr >= 0.08)))}. Fuer eine hier
#'   genannte Strategie ersetzen diese Bedingungen die Bedingungen aus
#'   \code{...} (strategiespezifische Schwellen).
#' @return data.frame mit einer Zeile je Strategie und Bedingung:
#'   \code{strategy}, \code{condition} (Name), \code{probability}
#'   (gewichtete Wahrscheinlichkeit als Anteil), \code{se}
#'   (Monte-Carlo-Standardfehler \eqn{\sqrt{p(1-p)/n_{eff}}} mit effektiver
#'   Pfadzahl \eqn{n_{eff} = (\sum w)^2 / \sum w^2}) und \code{n} (Anzahl
#'   ausgewerteter Pfade).
#' @examples
#' set.seed(1); n <- 3 * 365
#' d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
#' d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
#' cfg <- bootstrap_config(c(akt = "aktien"), input = "prices",
#'   letfs = list(list(base = "akt", leverage = 2, finance = 2)))
#' st <- bootstrap_study(d, cfg, "stationary", n = 5, params = list(L = 30),
#'   path_length = 500, seed = 1, progress = FALSE,
#'   strategies = list(etf = create_strategy(akt = asset_config("etf", "bnh")),
#'                     letf = create_strategy(akt_l2 = asset_config("etf", "bnh"))))
#' bootstrap_probability(st, cagr > 0, joint = cagr > 0.05 & max_drawdown <= 0.3)
#' bootstrap_probability(st, cagr > 0,
#'   thresholds = list(letf = list(ziel = quote(cagr > 0.10))))
#' @seealso [bootstrap_study()], [bootstrap_study_metrics()]
#' @export
bootstrap_probability <- function(study, ..., thresholds = NULL) {
  if (!inherits(study, "SimLevBootstrapStudy")) chk_stop("klasse", "bootstrap_probability", "study", "bootstrap_study()")
  # seit 1.6.4: thresholds als benannte Liste (je Strategie eine benannte Liste von Ausdruecken)
  if (!is.null(thresholds) && (!is.list(thresholds) || is.null(names(thresholds)) || anyNA(names(thresholds)) ||
                               any(names(thresholds) == "") ||
                               !all(vapply(thresholds, function(t) is.list(t) && length(t) > 0L && !is.null(names(t)) &&
                                                           !anyNA(names(t)) && all(names(t) != ""), NA))))
    chk_stop("e2.benannt", "bootstrap_probability", "thresholds")
  env <- parent.frame()                                   # freie Variablen im Aufrufer suchen
  conds <- as.list(substitute(list(...)))[-1]
  if (!length(conds) && is.null(thresholds)) chk_stop("e2.bedingung", "bootstrap_probability")   # seit 1.6.4 (vorher NULL)
  if (is.null(names(conds))) names(conds) <- vapply(conds, function(e) paste(deparse(e), collapse = ""), "")
  names(conds)[names(conds) == ""] <- vapply(conds[names(conds) == ""], function(e) paste(deparse(e), collapse = ""), "")
  tab <- study$results
  out <- do.call(rbind, lapply(unique(tab$strategy), function(s) {
    d <- tab[tab$strategy == s, , drop = FALSE]
    cl <- if (!is.null(thresholds[[s]])) thresholds[[s]] else conds
    do.call(rbind, lapply(names(cl), function(cn) {
      v <- as.logical(eval(cl[[cn]], d, env))
      w <- d$weight; ok <- !is.na(v)
      p <- sum(w[ok] * v[ok]) / sum(w[ok])
      neff <- sum(w[ok])^2 / sum(w[ok]^2)
      data.frame(strategy = s, condition = cn, probability = p, se = sqrt(p * (1 - p) / neff), n = sum(ok))
    }))
  }))
  rownames(out) <- NULL
  out
}

#' Methoden fuer Bootstrap-Objekte
#'
#' Ausgabe-, Zusammenfassungs- und Grafikmethoden fuer Objekte aus
#' [bootstrap_config()], [bootstrap()] und [bootstrap_study()].
#' \code{summary()} einer Studie liefert je Strategie und Kennzahl den
#' gewichteten Mittelwert und gewichtete Quantile; mit \code{benchmark} in
#' der Studie zusaetzlich einen gepaarten Vergleich auf denselben Pfaden.
#' Die gewichteten Quantile (auch in \code{summary()} und den Faechern von
#' \code{plot()} eines Ergebnisses von [withdrawal_simulation()]) sind die gewichtete Version von Typ 7
#' nach Hyndman & Fan (1996) in der Form von Akinshin (2023) mit der
#' Kish-Stichprobengroesse \eqn{(\sum w)^2 / \sum w^2}: bei gleichen Gewichten
#' (ohne ESS) genau [stats::quantile()] mit \code{type = 7}, sonst eine
#' stetig von den Gewichten abhaengende Interpolation benachbarter Werte.
#' \code{print()} einer Studie gibt eine Kurzinfo und die Zusammenfassung aus.
#' \code{plot()} zeichnet (ungewichtete) Dichten einer Kennzahl je Strategie
#' (Gauss-Kerndichte der C-Bibliothek von SimLev mit Bandbreite nach Silverman,
#' direkt summiert; die Kurven weichen minimal von \code{density()} ab).
#'
#' @param x Ein \code{bootstrap_config}-, \code{bootstrap_result}-,
#'   \code{SimLevBootstrapStudy}- oder \code{summary.SimLevBootstrapStudy}-Objekt.
#' @param object Ein \code{SimLevBootstrapStudy}-Objekt.
#' @param metrics Zeichenvektor der Kennzahlen (Spalten von
#'   \code{object$results}) fuer die Zusammenfassung; nicht vorhandene werden
#'   uebergangen. Standard: "cagr", "ttwror", "max_drawdown", "sharpe",
#'   "ulcer_index", "final_value".
#' @param probs Quantil-Wahrscheinlichkeiten als Anteil (Standard 0.05, 0.25,
#'   0.5, 0.75, 0.95); Spaltennamen q05, q25, ...
#' @param metric Name der Kennzahl (Spalte von \code{x$results}) fuer die
#'   Dichtegrafik (Standard "cagr").
#' @param ... Bei \code{plot()} an \code{plot()} weitergereicht, sonst ohne
#'   Wirkung.
#' @return \code{print()} und \code{plot()}: das Objekt (unsichtbar).
#'   \code{summary()}: Objekt der Klasse \code{summary.SimLevBootstrapStudy}
#'   mit \code{distribution} (data.frame: strategy, metric, mean und
#'   Quantilspalten), \code{paired} (data.frame: strategy, metric,
#'   \code{p_better} = gewichteter Anteil der Pfade, auf denen die Strategie
#'   besser als der Benchmark ist (groesserer Wert; bei \code{max_drawdown},
#'   \code{avg_drawdown}, \code{dd_q50}, \code{dd_q90},
#'   \code{longest_drawdown} und \code{ulcer_index} kleinerer Wert), \code{se}, \code{diff_q05}, \code{diff_median}, \code{diff_q95}
#'   der Differenz Strategie minus Benchmark; \code{NULL} ohne Benchmark),
#'   \code{n_paths}, \code{method}, \code{benchmark} und \code{path_length}.
#'   Kennzahlen behalten die Einheit aus \code{metrics} (bei
#'   [bootstrap_study_metrics()] z. B. CAGR als Anteil; die Ausgabe zeigt Prozent).
#'   Mit Sparplan ist \code{cagr} geldgewichtet (XIRR); die Ausgabe
#'   kennzeichnet das in der Ueberschrift der Kennzahl.
#' @name SimLevBootstrap-methods
#' @keywords internal
NULL

#' @rdname SimLevBootstrap-methods
#' @export
summary.SimLevBootstrapStudy <- function(object, metrics = c("cagr", "ttwror", "max_drawdown", "sharpe", "ulcer_index", "final_value"),
                                         probs = c(0.05, 0.25, 0.5, 0.75, 0.95), ...) {
  tab <- object$results
  metrics <- intersect(metrics, names(tab))
  dist <- do.call(rbind, lapply(object$strategies, function(s) {
    d <- tab[tab$strategy == s, , drop = FALSE]
    do.call(rbind, lapply(metrics, function(m) {
      q <- .wquantile(d[[m]], d$weight, probs)
      data.frame(strategy = s, metric = m, mean = stats::weighted.mean(d[[m]], d$weight, na.rm = TRUE),
                 t(setNames(q, sprintf("q%02d", round(100 * probs)))), check.names = FALSE)
    }))
  }))
  paired <- NULL
  if (!is.null(object$benchmark)) {
    b <- tab[tab$strategy == object$benchmark, , drop = FALSE]
    paired <- do.call(rbind, lapply(setdiff(object$strategies, object$benchmark), function(s) {
      d <- tab[tab$strategy == s, , drop = FALSE]
      mm <- merge(d, b, by = "path", suffixes = c("", ".bench"))
      do.call(rbind, lapply(metrics, function(m) {
        dif <- mm[[m]] - mm[[paste0(m, ".bench")]]
        better <- if (m %in% .lower_better) dif < 0 else dif > 0
        w <- mm$weight; ok <- is.finite(dif)
        p <- sum(w[ok] * better[ok]) / sum(w[ok])
        q <- .wquantile(dif, w, c(0.05, 0.5, 0.95))
        data.frame(strategy = s, metric = m, p_better = p,
                   se = sqrt(p * (1 - p) / (sum(w[ok])^2 / sum(w[ok]^2))),
                   diff_q05 = q[1], diff_median = q[2], diff_q95 = q[3])
      }))
    }))
  }
  out <- list(distribution = dist, paired = paired, n_paths = object$n_paths, method = object$method,
              benchmark = object$benchmark, path_length = object$path_length)
  class(out) <- "summary.SimLevBootstrapStudy"
  out
}

#' @rdname SimLevBootstrap-methods
#' @export
print.summary.SimLevBootstrapStudy <- function(x, ...) {
  fmt <- function(v, m) {
    pct <- m %in% c("cagr", "ttwror", "max_drawdown", "avg_drawdown", "dd_q50", "dd_q90", "p_better")
    if (pct) sprintf("%8.2f%%", 100 * v) else if (m %in% c("final_value", "taxes")) sprintf("%10.0f", v) else sprintf("%9.3f", v)
  }
  cat("\n\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  cat("                 SimLev Bootstrap-Studie                       \n")
  cat("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  cat(sprintf("  Verfahren: %s | Pfade: %d | Pfadl\u00e4nge: %d Tage\n", x$method, x$n_paths, x$path_length))
  d <- x$distribution
  qc <- grep("^q[0-9]", names(d), value = TRUE)
  for (m in unique(d$metric)) {
    dm <- d[d$metric == m, , drop = FALSE]
    lab <- if (m == "cagr") "cagr (mit Sparplan geldgewichtet, XIRR)" else m
    cat(sprintf("\n  %s\n  %-14s %10s %s\n", lab, "Strategie", "Mittel", paste(sprintf("%10s", qc), collapse = "")))
    for (i in seq_len(nrow(dm)))
      cat(sprintf("  %-14s %10s %s\n", dm$strategy[i], fmt(dm$mean[i], m),
                  paste(vapply(qc, function(q) sprintf("%10s", fmt(dm[[q]][i], m)), ""), collapse = "")))
  }
  if (!is.null(x$paired)) {
    cat(sprintf("\n  Gepaarter Vergleich gegen '%s' (gleiche Pfade)\n", x$benchmark))
    cat(sprintf("  %-14s %-14s %10s %8s %11s %11s %11s\n", "Strategie", "Kennzahl", "P(besser)", "SE", "Diff q05", "Diff Median", "Diff q95"))
    p <- x$paired
    for (i in seq_len(nrow(p)))
      cat(sprintf("  %-14s %-14s %9.1f%% %7.1f%% %11s %11s %11s\n", p$strategy[i], p$metric[i], 100 * p$p_better[i], 100 * p$se[i],
                  fmt(p$diff_q05[i], p$metric[i]), fmt(p$diff_median[i], p$metric[i]), fmt(p$diff_q95[i], p$metric[i])))
  }
  cat("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  invisible(x)
}

#' @rdname SimLevBootstrap-methods
#' @export
print.SimLevBootstrapStudy <- function(x, ...) {
  cat(sprintf("SimLev Bootstrap-Studie '%s': %d Pfade, Strategien: %s, %d Ergebniszeilen, %.1f s\n",
              x$method, x$n_paths, paste(x$strategies, collapse = ", "), nrow(x$results), x$elapsed))
  print(summary(x))
  invisible(x)
}

#' @rdname SimLevBootstrap-methods
#' @export
plot.SimLevBootstrapStudy <- function(x, metric = "cagr", ...) {
  tab <- x$results
  dl <- lapply(x$strategies, function(s) tab[[metric]][tab$strategy == s])
  rng <- range(unlist(dl), finite = TRUE)
  cols <- grDevices::hcl.colors(length(dl), "Dark 3")
  dens <- lapply(dl, function(v) .sl_kde(v[is.finite(v)]))   # Gauss-Kerndichte (slc; nur Grafik)
  plot(NULL, xlim = rng, ylim = c(0, max(vapply(dens, function(d) max(d$y), 0))),
       xlab = metric, ylab = "Dichte", main = sprintf("Verteilung %s (%s, %d Pfade)", metric, x$method, x$n_paths), ...)
  for (i in seq_along(dens)) graphics::lines(dens[[i]], col = cols[i], lwd = 1.5)
  graphics::legend("topright", legend = x$strategies, col = cols, lwd = 1.5, bty = "n")
  invisible(x)
}
