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
#' @param action_type Zeichenkette. Handelsstrategie:
#'   \describe{
#'     \item{"bnh"}{Buy-and-Hold: am ersten Tag kaufen, bis zum Ende halten}
#'     \item{"signal"}{Signalgesteuert: Ein-/Ausstieg nach Signalspalten in den Daten; bei offener
#'       Position wird neues Geld sofort angelegt wie bei Buy-and-Hold (A7-09)}
#'   }
#' @param asset_share Zahl. Zielgewicht im Portfolio als Anteil, groesser 0 und hoechstens 1.
#'   Wird fuer Rebalancing und DCA-Aufteilung genutzt; die Summe ueber alle Assets
#'   muss in simulation() 1 ergeben. Standard: 1.0.
#' @param asset_spread Zahl. Voller Bid-Ask-Spread in Prozent (z. B. 0.1 fuer 0,1 %).
#'   Wird auf Kauf- und Verkaufskurse angewandt (je Seite der halbe Spread). Standard: 0.1.
#' @param asset_bonus Zahl. Teilfreistellung in Prozent (0 bis 100) fuer ETFs:
#'   \describe{
#'     \item{30}{Aktien-ETFs (Aktienfonds, >51\% Aktien)}
#'     \item{15}{Mischfonds-ETFs (Mischfonds, >25\% Aktien)}
#'     \item{0}{Renten-/sonstige ETFs oder Nicht-ETF-Assets}
#'   }
#'   Standard: 0.
#' @param deliverable Logisch. Fuer ETN/ETC: Bietet das Produkt physische
#'   Lieferung? Bei TRUE werden Gewinne nach § 23 EStG besteuert (steuerfrei nach 1 Jahr).
#'   Bei FALSE nach § 20 EStG (Abgeltungsteuer, Standard 26.375\%). Standard: FALSE.
#' @param asset_start Date oder NULL. Ab wann das Asset handelbar ist.
#'   Fuer verzoegerten Einstieg in Multi-Asset-Portfolios. Standard: NULL (sofort).
#' @param tax_regime Zeichenkette oder NULL. Uebersteuert die automatische Ableitung des Steuerregimes:
#'   \describe{
#'     \item{"investment_fund"}{InvStG (ETFs)}
#'     \item{"capital_gains"}{§ 20 EStG (Standard)}
#'     \item{"private_sale"}{§ 23 EStG (Haltefrist 1 Jahr)}
#'   }
#' @param signal_buy Zeichenkette oder NULL. Spaltenname der Kaufsignale in den Daten.
#'   Pflicht bei action_type = "signal".
#' @param signal_sell Zeichenkette oder NULL. Spaltenname der Verkaufssignale in den Daten.
#'   Pflicht bei action_type = "signal".
#'
#' @return Objekt der Klasse "asset_config" mit der validierten Konfiguration.
#'
#' @examples
#' # Aktien-ETF mit 30 Prozent Teilfreistellung
#' etf_config <- asset_config(
#'   asset_class = "etf",
#'   asset_share = 0.7,
#'   asset_bonus = 30
#' )
#'
#' # Gold-ETC mit physischer Lieferung (§ 23 EStG)
#' gold_config <- asset_config(
#'   asset_class = "etc",
#'   asset_share = 0.2,
#'   deliverable = TRUE
#' )
#'
#' # Zertifikat (§ 20 EStG)
#' cert_config <- asset_config(
#'   asset_class = "certificate",
#'   asset_share = 0.1
#' )
#'
#' @seealso [create_strategy()], [simulation()]
#' @export
#' @noRd
asset_config <- function(
    asset_class = c("etf", "etn", "etc", "certificate",
                    "etn_standard", "etn_deliverable"),
    action_type = c("bnh", "signal"),
    asset_share = 1.0,
    asset_spread = 0.1,
    asset_bonus = 0.0,
    deliverable = FALSE,
    asset_start = NULL,
    tax_regime = NULL,
    signal_buy = NULL,
    signal_sell = NULL
) {
  
  asset_class <- match.arg(asset_class)
  action_type <- match.arg(action_type)
  
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
  .num1(asset_share, "asset_share"); .num1(asset_spread, "asset_spread"); .num1(asset_bonus, "asset_bonus")

  if (asset_share <= 0 || asset_share > 1) {   # C7-04: Wert und Hinweis auf die Anteil-Konvention nennen
    stop(sprintf("asset_config: asset_share muss ein Anteil gr\u00f6\u00dfer 0 und h\u00f6chstens 1 sein (z. B. 0.6 f\u00fcr 60 %%), nicht %s%s.",
                 format(asset_share), if (asset_share > 1 && asset_share <= 100)
                   sprintf("; f\u00fcr %s %% asset_share = %s angeben", format(asset_share), format(asset_share / 100)) else ""))
  }
  
  if (asset_spread < 0) {
    stop(sprintf("asset_config: asset_spread muss >= 0 sein (voller Spread in Prozent, z. B. 0.1 f\u00fcr 0,1 %%), nicht %s.", format(asset_spread)))
  }
  
  if (asset_bonus < 0 || asset_bonus > 100) {
    stop(sprintf("asset_config: asset_bonus muss zwischen 0 und 100 liegen (Teilfreistellung in Prozent, z. B. 30 f\u00fcr 30 %%), nicht %s.", format(asset_bonus)))
  }
  if (asset_bonus > 0 && asset_bonus < 1)
    warning(sprintf("asset_config: asset_bonus = %s wird als %s %% Teilfreistellung gelesen (Prozent-Konvention); gemeint war vermutlich %s.",
                    format(asset_bonus), format(asset_bonus), format(asset_bonus * 100)), call. = FALSE)

  if (!is.null(asset_start)) {
    st <- if (length(asset_start) == 1L) tryCatch(as.Date(asset_start), error = function(e) NA) else NA
    if (length(st) != 1L || is.na(st))
      stop(sprintf("asset_config: asset_start = %s ist kein Datum (erwartet Date oder \"JJJJ-MM-TT\").",
                   paste(deparse(asset_start), collapse = "")))
    asset_start <- st
  }
  
  if (action_type == "signal" && (is.null(signal_buy) || is.null(signal_sell))) {
    stop("asset_config: bei action_type = \"signal\" m\u00fcssen signal_buy und signal_sell angegeben werden (Namen der Signalspalten in data).")
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
    action_type = action_type,
    asset_share = asset_share,
    asset_spread = asset_spread,
    asset_bonus = asset_bonus,
    deliverable = deliverable,
    asset_start = asset_start,
    tax_regime = tax_regime,
    signal_buy = signal_buy,
    signal_sell = signal_sell
  )
  
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
  cat(sprintf("  Aktion:       %s\n", x$action_type))
  cat(sprintf("  Anteil:       %.1f%%\n", x$asset_share * 100))
  cat(sprintf("  Steuerregime: %s\n", x$tax_regime))
  if (x$asset_class == "etf") {
    cat(sprintf("  Teilfrei.:    %.0f%%\n", x$asset_bonus))
  }
  if (x$asset_class %in% c("etn", "etc")) {
    cat(sprintf("  Lieferbar:    %s\n", x$deliverable))
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
