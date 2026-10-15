# =============================================================================
#  tax_tariff.R  —  Einkommensteuertarif und Solidaritaetszuschlag als Datei
# =============================================================================
#  read_tax_tariff()     liest und prueft eine Tarifdatei (Standard: mitgelieferte
#                        inst/extdata/steuertarif.csv, ab VZ 2026)
#  .tariff_income_tax()  tarifliche Einkommensteuer (§ 32a Abs. 1 EStG, Rundung)
#  .tariff_soli()        Solidaritaetszuschlag auf die ESt (§§ 3, 4 SolZG)
#  Verwendet von simulation(taxable_income =, tax_tariff =).
# =============================================================================

#' Einkommensteuertarif aus einer Datei lesen
#'
#' Liest den Einkommensteuertarif (§ 32a Abs. 1 EStG) und den Solidaritaetszuschlag
#' (§§ 3, 4 SolZG) aus einer CSV-Datei, prueft sie und liefert ein Objekt fuer
#' \code{simulation(..., taxable_income =, tax_tariff =)}. Mitgeliefert wird die
#' Rechtslage ab VZ 2026 (Einzelveranlagung, Grundtarif; kein Splitting). Fuer eine
#' kuenftige Rechtslage genuegt es, die Datei auszutauschen bzw. eine eigene Datei
#' anzugeben; der Code bleibt unveraendert.
#'
#' @param file Zeichenkette oder NULL. Pfad der Tarifdatei; NULL = mitgelieferte Datei
#'   \code{system.file("extdata", "steuertarif.csv", package = "SimLev")}.
#'
#' @details
#' Dateiformat (Basis-R lesbar mit \code{read.csv(file, comment.char = "#")}; Komma als
#' Trennzeichen, Punkt als Dezimalzeichen; Zeilen mit \code{#} sind Kommentare, eine
#' Kommentarzeile \code{# Geltung: ...} wird als Geltung angezeigt). Spalten
#' \code{art, ab, bezug, teiler, a, b, c}:
#' \describe{
#'   \item{art = "zone"}{Tarifzone: gilt fuer \eqn{x \ge} \code{ab} (x = zu versteuerndes
#'     Einkommen, auf volle Euro abgerundet); Steuer \eqn{(a u + b) u + c} mit
#'     \eqn{u = (x - bezug) / teiler}, danach auf volle Euro abgerundet. Lineare Zonen:
#'     \code{a = 0, bezug = 0, teiler = 1}, \code{b} = Satz als Anteil, \code{c} = Abzugsbetrag.}
#'   \item{art = "soli"}{genau eine Zeile: \code{ab} = Freigrenze in EUR Einkommensteuer,
#'     \code{a} = Zuschlagsatz in Prozent, \code{b} = Milderungssatz in Prozent.}
#' }
#' Einheiten: \code{ab}, \code{bezug}, \code{teiler} und \code{c} in EUR; bei
#' Progressionszonen (\code{teiler = 10000}, u dimensionslos) auch \code{a}, \code{b} in EUR;
#' bei linearen Zonen (\code{a = 0, bezug = 0, teiler = 1}) ist \code{b} der Grenzsteuersatz
#' als Anteil (\code{0.42} fuer 42 %, nicht 42); die Soli-Saetze dagegen in Prozent
#' (\code{5.5} fuer 5,5 %).
#'
#' Geprueft wird: Komma als Trennzeichen (wird nur eine Spalte gelesen, z. B. Semikolon-CSV,
#' bzw. hat eine Zeile mehr Felder als die Kopfzeile, z. B. Dezimalkomma: Fehler mit Hinweis),
#' Pflichtspalten vorhanden, \code{art} nur "zone" oder "soli", alle benoetigten Werte
#' numerisch und endlich, \code{teiler > 0}, Zonen streng aufsteigend mit erster Zone ab 0,
#' genau eine soli-Zeile mit Saetzen von 0 bis 100. Plausibilitaet: Der Grenzsteuersatz jeder
#' Zone (Ableitung \eqn{(2 a u + b) / teiler}) muss an beiden Raendern (Zonenbeginn und
#' letzter Euro der Zone; letzte Zone: bei 10 Mio. EUR) zwischen 0 und 1 liegen, und die
#' Steuer darf an diesen Stellen das Einkommen nicht uebersteigen (\eqn{T(x) \le x});
#' sonst Fehler mit Zeile, Wert und Hinweis auf die Einheiten. Springt der Tarif an einer
#' Zonengrenze um mehr als 1 EUR (Formel der vorigen und der neuen Zone an der Grenze), wird
#' gewarnt.
#'
#' Rechenregeln (intern): tarifliche ESt \eqn{T(x)}: x auf volle Euro abrunden (negativ:
#' 0), Formel der Zone mit dem groessten \code{ab <= x}, Ergebnis auf volle Euro abrunden.
#' Soli \eqn{S(E)} auf die ESt E: 0, wenn E die Freigrenze nicht uebersteigt, sonst
#' \eqn{\min(a / 100 \cdot E, b / 100 \cdot (E - Freigrenze))} (Milderungszone), Bruchteile
#' eines Cents bleiben ausser Ansatz.
#'
#' Mitgelieferter Tarif (ab VZ 2026): bis 12 348 EUR 0; 12 349 bis 17 799:
#' (914,51 y + 1 400) y; 17 800 bis 69 878: (173,10 z + 2 397) z + 1 034,87;
#' 69 879 bis 277 825: 0,42 x - 11 135,63; ab 277 826: 0,45 x - 19 470,38 mit
#' y = (x - 12 348) / 10 000, z = (x - 17 799) / 10 000. Soli 5,5 % ueber der
#' Freigrenze 20 350 EUR, hoechstens 11,9 % des Mehrbetrags.
#'
#' @return Objekt der Klasse "SimLevTaxTariff" (Liste) mit \code{zones} (data.frame
#'   ab, bezug, teiler, a, b, c), \code{soli} (Liste freigrenze, satz, milderung; Saetze in
#'   Prozent), \code{geltung} (Text aus der Datei) und \code{file} (Pfad). print() zeigt
#'   Geltung, Zonen und Soli.
#'
#' @examples
#' tt <- read_tax_tariff()
#' tt
#' # eigene Datei mit geaendertem Tarif
#' f <- tempfile(fileext = ".csv")
#' writeLines(c("# Geltung: Beispiel", "art,ab,bezug,teiler,a,b,c",
#'              "zone,0,0,1,0,0,0", "zone,10001,10000,1,0,0.2,0",
#'              "soli,1e9,,,5.5,11.9,"), f)
#' read_tax_tariff(f)
#'
#' @encoding UTF-8
#' @seealso \code{\link{simulation}} (Argumente taxable_income, tax_tariff)
#' @export
read_tax_tariff <- function(file = NULL) {
  if (is.null(file)) {
    file <- system.file("extdata", "steuertarif.csv", package = "SimLev")
    if (!nzchar(file)) stop("read_tax_tariff: Die mitgelieferte Datei extdata/steuertarif.csv wurde nicht gefunden (Paket unvollst\u00e4ndig installiert?).", call. = FALSE)
  }
  if (!is.character(file) || length(file) != 1L || is.na(file))
    stop("read_tax_tariff: 'file' muss ein einzelner Dateipfad (Zeichenkette) oder NULL sein.", call. = FALSE)
  if (!file.exists(file)) stop(sprintf("read_tax_tariff: Datei '%s' nicht gefunden.", file), call. = FALSE)
  raw <- readLines(file, warn = FALSE, encoding = "UTF-8")
  gl <- grep("^#\\s*Geltung\\s*:", raw, value = TRUE)
  geltung <- if (length(gl)) trimws(sub("^#\\s*Geltung\\s*:", "", gl[1])) else NA_character_
  # Trennzeichen pruefen: Semikolon-CSV (deutsches Excel) bzw. Dezimalkomma verschieben die Spalten
  body <- trimws(sub("#.*$", "", raw)); body <- body[nzchar(body)]
  if (length(body)) {
    nf <- nchar(gsub("[^,]", "", body)) + 1L
    if (nf[1] == 1L)
      stop(sprintf("read_tax_tariff: In '%s' wurde nur eine Spalte gelesen (Kopfzeile '%s'). Erwartet wird Komma als Trennzeichen%s und Punkt als Dezimalzeichen, z. B. 'zone,69879,0,1,0,0.42,-11135.63'.",
                   file, body[1], if (grepl(";", body[1])) " (die Datei verwendet offenbar Semikolon, z. B. aus deutschem Excel)" else ""), call. = FALSE)
    if (any(nf[-1] != nf[1])) {
      i <- which(nf != nf[1])[1]
      stop(sprintf("read_tax_tariff: In '%s' hat die Zeile '%s' %d Felder, die Kopfzeile %d. Dezimalzeichen ist der Punkt (0.42, nicht 0,42); Komma nur als Trennzeichen.",
                   file, body[i], nf[i], nf[1]), call. = FALSE)
    }
  }
  d <- tryCatch(utils::read.csv(file, comment.char = "#", stringsAsFactors = FALSE, strip.white = TRUE,
                                colClasses = "character", encoding = "UTF-8"),
                error = function(e) stop(sprintf("read_tax_tariff: Datei '%s' ist keine lesbare CSV-Datei (%s).", file, conditionMessage(e)), call. = FALSE))
  need <- c("art", "ab", "bezug", "teiler", "a", "b", "c")
  miss <- setdiff(need, names(d))
  if (length(miss))
    stop(sprintf("read_tax_tariff: In '%s' fehlen die Spalten %s (erwartet: %s).", file,
                 paste(miss, collapse = ", "), paste(need, collapse = ",")), call. = FALSE)
  art <- tolower(d$art)
  bad <- which(!art %in% c("zone", "soli"))
  if (length(bad))
    stop(sprintf("read_tax_tariff: Datenzeile %d hat art = '%s'; erlaubt sind \"zone\" und \"soli\".", bad[1], d$art[bad[1]]), call. = FALSE)
  num <- function(col, rows) {
    v <- suppressWarnings(as.numeric(d[[col]][rows]))
    nb <- which(!is.finite(v))
    if (length(nb))
      stop(sprintf("read_tax_tariff: Spalte '%s' in Datenzeile %d (art = %s) ist nicht numerisch bzw. nicht endlich ('%s').",
                   col, rows[nb[1]], art[rows[nb[1]]], d[[col]][rows[nb[1]]]), call. = FALSE)
    v
  }
  zr <- which(art == "zone"); sr <- which(art == "soli")
  if (!length(zr)) stop("read_tax_tariff: Die Datei enth\u00e4lt keine Tarifzone (art = \"zone\").", call. = FALSE)
  if (length(sr) != 1L)
    stop(sprintf("read_tax_tariff: Es muss genau eine soli-Zeile geben (gefunden: %d).", length(sr)), call. = FALSE)
  z <- data.frame(ab = num("ab", zr), bezug = num("bezug", zr), teiler = num("teiler", zr),
                  a = num("a", zr), b = num("b", zr), c = num("c", zr))
  if (z$ab[1] != 0) stop(sprintf("read_tax_tariff: Die erste Zone muss bei ab = 0 beginnen (ist %s).", format(z$ab[1])), call. = FALSE)
  if (any(diff(z$ab) <= 0)) {
    k <- which(diff(z$ab) <= 0)[1]
    stop(sprintf("read_tax_tariff: Die Zonen m\u00fcssen streng aufsteigend sein (Zone %d ab %s folgt auf ab %s).",
                 k + 1L, format(z$ab[k + 1L]), format(z$ab[k])), call. = FALSE)
  }
  if (any(z$teiler <= 0)) stop(sprintf("read_tax_tariff: teiler muss > 0 sein (Zone ab %s).", format(z$ab[which(z$teiler <= 0)[1]])), call. = FALSE)
  soli <- list(freigrenze = num("ab", sr), satz = num("a", sr), milderung = num("b", sr))
  if (soli$freigrenze < 0) stop("read_tax_tariff: Die Soli-Freigrenze (ab) darf nicht negativ sein.", call. = FALSE)
  for (s in c("satz", "milderung")) if (soli[[s]] < 0 || soli[[s]] > 100)
    stop(sprintf("read_tax_tariff: Soli-%s muss zwischen 0 und 100 Prozent liegen (ist %s).",
                 if (s == "satz") "Zuschlagsatz (a)" else "Milderungssatz (b)", format(soli[[s]])), call. = FALSE)
  out <- structure(list(zones = z, soli = soli, geltung = geltung, file = normalizePath(file)), class = "SimLevTaxTariff")
  f <- function(j, x) { u <- (x - z$bezug[j]) / z$teiler[j]; (z$a[j] * u + z$b[j]) * u + z$c[j] }
  # Plausibilitaet je Zone an beiden Raendern: Grenzsteuersatz (2 a u + b) / teiler in [0, 1], T(x) <= x
  unit_hint <- "Einheiten pr\u00fcfen: bei linearen Zonen (a = 0, bezug = 0, teiler = 1) ist b der Grenzsteuersatz als Anteil (0.42 f\u00fcr 42 %, nicht 42), die Soli-S\u00e4tze dagegen in Prozent (5.5); ab, bezug, c in EUR"
  for (k in seq_len(nrow(z))) {
    x_hi <- if (k < nrow(z)) z$ab[k + 1L] - 1 else max(z$ab[k], 1e7)
    for (x in unique(c(z$ab[k], max(z$ab[k], x_hi)))) {
      u <- (x - z$bezug[k]) / z$teiler[k]
      m <- (2 * z$a[k] * u + z$b[k]) / z$teiler[k]
      if (!is.finite(m) || m < -1e-12 || m > 1 + 1e-12)
        stop(sprintf("read_tax_tariff: Zone ab %s EUR (Datenzeile %d): Grenzsteuersatz %s bei x = %s EUR liegt nicht zwischen 0 und 1 (0 bis 100 %%). %s.",
                     format(z$ab[k], scientific = FALSE), zr[k], format(signif(m, 6)),
                     format(x, scientific = FALSE), unit_hint), call. = FALSE)
      if (f(k, x) > x + 1e-9)
        stop(sprintf("read_tax_tariff: Zone ab %s EUR (Datenzeile %d): Steuer %.2f EUR bei x = %s EUR \u00fcbersteigt das Einkommen. %s.",
                     format(z$ab[k], scientific = FALSE), zr[k], f(k, x),
                     format(x, scientific = FALSE), unit_hint), call. = FALSE)
    }
  }
  # Stetigkeit: Formel der vorigen und der neuen Zone an der Zonengrenze vergleichen
  for (k in seq_len(nrow(z))[-1]) {
    jump <- f(k, z$ab[k]) - f(k - 1L, z$ab[k])
    if (abs(jump) > 1)
      warning(sprintf("read_tax_tariff: Der Tarif springt an der Zonengrenze %s EUR um %.2f EUR (vorige Zone %.2f, neue Zone %.2f EUR); Tarifdatei pr\u00fcfen.",
                      format(z$ab[k], scientific = FALSE), jump, f(k - 1L, z$ab[k]), f(k, z$ab[k])), call. = FALSE)
  }
  out
}

#' @export
#' @noRd
print.SimLevTaxTariff <- function(x, ...) {
  cat("Einkommensteuertarif (SimLev)\n")
  cat(sprintf("  Geltung: %s\n", if (is.na(x$geltung)) "(keine Angabe in der Datei)" else x$geltung))
  cat(sprintf("  Datei:   %s\n", x$file))
  z <- x$zones; hi <- c(z$ab[-1] - 1, Inf)
  cat("  Zonen (x = zvE in EUR, auf volle Euro abgerundet; Steuer (a*u + b)*u + c, u = (x - bezug)/teiler):\n")
  for (k in seq_len(nrow(z)))
    cat(sprintf("    %10s - %-10s  bezug %9s  teiler %6s  a %8s  b %8s  c %10s\n",
                format(z$ab[k], big.mark = " "), if (is.finite(hi[k])) format(hi[k], big.mark = " ") else "",
                format(z$bezug[k]), format(z$teiler[k]), format(z$a[k]), format(z$b[k]), format(z$c[k])))
  cat(sprintf("  Soli: %s %% der ESt, wenn die ESt %s EUR \u00fcbersteigt (Freigrenze); h\u00f6chstens %s %% des Mehrbetrags\n",
              format(x$soli$satz), format(x$soli$freigrenze, big.mark = " ", scientific = FALSE), format(x$soli$milderung)))
  invisible(x)
}

#' Tarifliche Einkommensteuer T(x) (§ 32a Abs. 1 EStG)
#' @param tariff Objekt aus read_tax_tariff()
#' @param zve Zahl. Zu versteuerndes Einkommen in EUR
#' @return ESt in vollen EUR
#' @keywords internal
#' @noRd
.tariff_income_tax <- function(tariff, zve) {
  z <- tariff$zones
  x <- max(0, floor(zve + 1e-9))                       # auf volle Euro abrunden
  k <- max(which(z$ab <= x))
  u <- (x - z$bezug[k]) / z$teiler[k]
  max(0, floor(round((z$a[k] * u + z$b[k]) * u + z$c[k], 6)))   # Steuerbetrag auf volle Euro abrunden
}

#' Solidaritaetszuschlag S(E) auf die Einkommensteuer (§§ 3 Abs. 3, 4 SolZG)
#' @param tariff Objekt aus read_tax_tariff()
#' @param est Zahl. Einkommensteuer in EUR
#' @return Soli in EUR (Bruchteile eines Cents bleiben ausser Ansatz)
#' @keywords internal
#' @noRd
.tariff_soli <- function(tariff, est) {
  s <- tariff$soli
  if (!(est > s$freigrenze)) return(0)
  v <- min(s$satz / 100 * est, s$milderung / 100 * (est - s$freigrenze))
  floor(round(v * 100, 6)) / 100
}
