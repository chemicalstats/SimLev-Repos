# Meldung von asset_config() fuer wrapper mit trading = "signal" (strategy_from_weights() erkennt sie und nennt das Asset)
.ac_msg_wrapper_signal <- "asset_config: mit wrapper ist nur trading = \"bnh\" m\u00f6glich (keine Signale auf den Anteilswert; Signale gehen in der inneren Strategie)."

#' Asset-Konfiguration erstellen
#'
#' Erstellt eine validierte Asset-Konfiguration fuer Simulationsstrategien.
#' Jedes Asset eines Portfolios braucht eine Konfiguration, die seine
#' steuerliche Behandlung, sein Handelsverhalten und weitere Eigenschaften
#' festlegt. Massgebliche Beschreibung: Hilfeseite \code{?asset_config}.
#'
#' @param asset_class Zeichenkette. Art des Assets:
#'   \describe{
#'     \item{"etf"}{Exchange-Traded Fund (InvStG, Teilfreistellung)}
#'     \item{"etn"}{Exchange-Traded Note}
#'     \item{"etc"}{Exchange-Traded Commodity}
#'     \item{"certificate"}{Zertifikat}
#'   }
#'   Veraltet (mit Warnung umgesetzt): "etn_standard" (= "etn", deliverable = FALSE),
#'   "etn_deliverable" (= "etn", deliverable = TRUE).
#' @param trading Zeichenkette. Handelsstrategie:
#'   \describe{
#'     \item{"bnh"}{Buy-and-Hold: am ersten Tag kaufen, bis zum Ende halten}
#'     \item{"signal"}{Signalgesteuert: Ein-/Ausstieg nach Signalspalten in den Daten; bei offener
#'       Position wird neues Geld sofort angelegt wie bei Buy-and-Hold (A7-09)}
#'   }
#' @param share Zahl. Zielgewicht im Portfolio als Anteil, groesser 0 und hoechstens 1.
#'   Wird fuer Rebalancing und DCA-Aufteilung genutzt; die Summe ueber alle Assets
#'   muss in simulation() 1 ergeben. Standard: 1.0.
#' @param spread Zahl. Voller Bid-Ask-Spread in Prozent (z. B. 0.1 fuer 0,1 %).
#'   Wird auf Kauf- und Verkaufskurse angewandt (je Seite der halbe Spread). Standard: 0 (ohne
#'   Spread; wer Spreads abbilden will, gibt sie an).
#' @param partial_exemption Zahl. Teilfreistellung in Prozent (0 bis 100) fuer ETFs:
#'   \describe{
#'     \item{30}{Aktien-ETFs (Aktienfonds, >51\% Aktien)}
#'     \item{15}{Mischfonds-ETFs (Mischfonds, >25\% Aktien)}
#'     \item{0}{Renten-/sonstige ETFs oder Nicht-ETF-Assets}
#'   }
#'   Standard: 0.
#' @param deliverable Logisch. Fuer ETN/ETC: Bietet das Produkt physische
#'   Lieferung? Bei TRUE werden Gewinne nach § 23 EStG besteuert (steuerfrei nach 1 Jahr).
#'   Bei FALSE nach § 20 EStG (Abgeltungsteuer, Standard 26.375\%). Standard: FALSE.
#' @param start Date oder NULL. Ab wann das Asset handelbar ist.
#'   Fuer verzoegerten Einstieg in Multi-Asset-Portfolios. Standard: NULL (sofort).
#' @param tax_regime Zeichenkette oder NULL. Uebersteuert die automatische Ableitung des Steuerregimes:
#'   \describe{
#'     \item{"investment_fund"}{InvStG (ETFs)}
#'     \item{"capital_gains"}{§ 20 EStG (Standard)}
#'     \item{"private_sale"}{§ 23 EStG (Haltefrist 1 Jahr)}
#'   }
#' @param signal_buy Zeichenkette oder NULL. Spaltenname der Kaufsignale in den Daten.
#'   Pflicht bei trading = "signal".
#' @param signal_sell Zeichenkette oder NULL. Spaltenname der Verkaufssignale in den Daten.
#'   Pflicht bei trading = "signal".
#' @param wrapper NULL oder ein Objekt aus wrapper_config(): Das Asset ist dann ein Fonds-Wrapper; sein Name
#'   ist keine Kursspalte, die Kurse sind der Anteilswert aus der inneren Strategie (wrapper_nav()). Nur mit
#'   trading = "bnh".
#'
#' @return Objekt der Klasse "asset_config" mit der validierten Konfiguration.
#'
#' @examples
#' # Aktien-ETF mit 30 Prozent Teilfreistellung
#' etf_config <- asset_config(
#'   asset_class = "etf",
#'   share = 0.7,
#'   partial_exemption = 30
#' )
#'
#' # Gold-ETC mit physischer Lieferung (§ 23 EStG)
#' gold_config <- asset_config(
#'   asset_class = "etc",
#'   share = 0.2,
#'   deliverable = TRUE
#' )
#'
#' # Zertifikat (§ 20 EStG)
#' cert_config <- asset_config(
#'   asset_class = "certificate",
#'   share = 0.1
#' )
#'
#' @seealso [create_strategy()], [simulation()]
#' @export
#' @noRd
asset_config <- function(
    asset_class = c("etf", "etn", "etc", "certificate",
                    "etn_standard", "etn_deliverable"),
    trading = c("bnh", "signal"),
    share = 1.0,
    spread = 0,
    partial_exemption = 0.0,
    deliverable = FALSE,
    start = NULL,
    tax_regime = NULL,
    signal_buy = NULL,
    signal_sell = NULL,
    wrapper = NULL
) {
  
  asset_class <- match.arg(asset_class)
  trading <- match.arg(trading)
  
  # Abwaertskompatibilitaet
  if (asset_class == "etn_standard") {
    warning("asset_config: asset_class = \"etn_standard\" ist veraltet; stattdessen asset_class = \"etn\" mit deliverable = FALSE verwenden.")
    asset_class <- "etn"
    deliverable <- FALSE
  } else if (asset_class == "etn_deliverable") {
    warning("asset_config: asset_class = \"etn_deliverable\" ist veraltet; stattdessen asset_class = \"etn\" mit deliverable = TRUE verwenden.")
    asset_class <- "etn"
    deliverable <- TRUE
  }
  
  # Pruefungen

  # R1-23: Zahlen muessen Zahlen sein (kein Text wie "0.5"), Prozentangaben plausibel
  .num1 <- function(x, arg) {
    if (!is.numeric(x) || length(x) != 1L || is.na(x))
      stop(sprintf("asset_config: %s muss eine einzelne Zahl sein, nicht %s.", arg, paste(deparse(x), collapse = "")))
  }
  .num1(share, "share"); .num1(spread, "spread"); .num1(partial_exemption, "partial_exemption")

  if (share <= 0 || share > 1) {   # C7-04: Wert und Hinweis auf die Anteil-Konvention nennen
    stop(sprintf("asset_config: share muss ein Anteil gr\u00f6\u00dfer 0 und h\u00f6chstens 1 sein (z. B. 0.6 f\u00fcr 60 %%), nicht %s%s.",
                 format(share), if (share > 1 && share <= 100)
                   sprintf("; f\u00fcr %s %% share = %s angeben", format(share), format(share / 100)) else ""))
  }
  
  if (spread < 0) {
    stop(sprintf("asset_config: spread muss >= 0 sein (voller Spread in Prozent, z. B. 0.1 f\u00fcr 0,1 %%), nicht %s.", format(spread)))
  }
  
  if (partial_exemption < 0 || partial_exemption > 100) {
    stop(sprintf("asset_config: partial_exemption muss zwischen 0 und 100 liegen (Teilfreistellung in Prozent, z. B. 30 f\u00fcr 30 %%), nicht %s.", format(partial_exemption)))
  }
  if (partial_exemption > 0 && partial_exemption < 1)
    warning(sprintf("asset_config: partial_exemption = %s wird als %s %% Teilfreistellung gelesen (Prozent-Konvention); gemeint war vermutlich %s.",
                    format(partial_exemption), format(partial_exemption), format(partial_exemption * 100)), call. = FALSE)

  if (!is.null(start)) {
    st <- if (length(start) == 1L) tryCatch(as.Date(start), error = function(e) NA) else NA
    if (length(st) != 1L || is.na(st))
      stop(sprintf("asset_config: start = %s ist kein Datum (erwartet Date oder \"JJJJ-MM-TT\").",
                   paste(deparse(start), collapse = "")))
    start <- st
  }
  
  if (trading == "signal" && (is.null(signal_buy) || is.null(signal_sell))) {
    stop("asset_config: bei trading = \"signal\" m\u00fcssen signal_buy und signal_sell angegeben werden (Namen der Signalspalten in data).")
  }
  
  # Fonds-Wrapper (Etappe 6.5c): keine Signale auf den Anteilswert (E5)
  if (!is.null(wrapper)) {
    if (!inherits(wrapper, "SimLevWrapperConfig"))
      stop(sprintf("asset_config: wrapper muss NULL oder ein Objekt aus wrapper_config() sein, nicht %s.",
                   paste(class(wrapper), collapse = "/")))
    if (trading == "signal") stop(.ac_msg_wrapper_signal)
  }

  # Steuerregime ableiten
  if (is.null(tax_regime)) {
    tax_regime <- switch(asset_class,
      "etf" = "investment_fund",
      "etn" = if (deliverable) "private_sale" else "capital_gains",
      "etc" = if (deliverable) "private_sale" else "capital_gains",
      "certificate" = "capital_gains"
    )
  } else {
    valid_regimes <- c("investment_fund", "capital_gains", "private_sale")
    if (!tax_regime %in% valid_regimes) {
      stop(sprintf("asset_config: tax_regime = %s ist ung\u00fcltig; erlaubt sind %s (oder NULL: aus asset_class abgeleitet).",
                   paste(deparse(tax_regime), collapse = ""), paste(valid_regimes, collapse = ", ")))
    }
  }
  
  config <- list(
    asset_class = asset_class,
    trading = trading,
    share = share,
    spread = spread,
    partial_exemption = partial_exemption,
    deliverable = deliverable,
    start = start,
    tax_regime = tax_regime,
    signal_buy = signal_buy,
    signal_sell = signal_sell
  )
  if (!is.null(wrapper)) config$wrapper <- wrapper   # nur mit Wrapper ein Feld (sonst Objekt wie bisher)
  
  class(config) <- c("asset_config", "list")
  return(config)
}


#' Asset-Konfiguration ausgeben
#' @param x Ein asset_config-Objekt
#' @param ... Weitere Argumente (ignoriert)
#' @return x, unsichtbar
#' @export
#' @noRd
print.asset_config <- function(x, ...) {
  cat("Asset-Konfiguration\n")
  cat("-------------------\n")
  cat(sprintf("  Klasse:       %s\n", x$asset_class))
  cat(sprintf("  Aktion:       %s\n", x$trading))
  cat(sprintf("  Anteil:       %.1f%%\n", x$share * 100))
  cat(sprintf("  Steuerregime: %s\n", x$tax_regime))
  if (x$asset_class == "etf") {
    cat(sprintf("  Teilfrei.:    %.0f%%\n", x$partial_exemption))
  }
  if (x$asset_class %in% c("etn", "etc")) {
    cat(sprintf("  Lieferbar:    %s\n", x$deliverable))
  }
  if (inherits(x$wrapper, "SimLevWrapperConfig")) {
    w <- x$wrapper
    cat(sprintf("  Wrapper:      %s; Fondskosten %s %% p. a., Performancegeb\u00fchr %s %%\n",
                .wrapper_assets_text(w$strategy), .blk_fmt(w$costs$fee), .blk_fmt(w$costs$performance_fee)))
  }
  invisible(x)
}


#' Zusammenfassung einer Asset-Konfiguration (wie print)
#' @param object Ein asset_config-Objekt
#' @param ... Weitere Argumente (ignoriert)
#' @export
#' @noRd
summary.asset_config <- function(object, ...) {
  print(object)
}
