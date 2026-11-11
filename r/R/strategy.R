# strategy.R  —  Anlagestrategie: erstellen, pruefen, Assets hinzufuegen, aendern und entfernen,
#                 Druck und Zusammenfassung (Klasse strategy)

#' Anlagestrategie erstellen
#'
#' Erstellt ein Strategie-Objekt aus einer oder mehreren Asset-Konfigurationen.
#' Eine Strategie legt fest, welche Assets in eine Portfolio-Simulation eingehen
#' und wie sie jeweils konfiguriert sind. Einfache Listen werden mit
#' asset_config() umgewandelt und dabei geprueft. Die Gewichte werden nicht
#' normiert; simulation() verlangt eine Summe der share von 1.
#'
#' @param ... Benannte asset_config-Objekte (oder Listen von asset_config-Argumenten).
#'   Die Namen werden zu Asset-Bezeichnern und muessen Spaltennamen der Daten entsprechen.
#' @param assets Optional: benannte Liste von Asset-Konfigurationen als
#'   Alternative zu den ...-Argumenten (nicht beides zugleich).
#'
#' @return Objekt der Klasse "strategy" mit validierten Asset-Konfigurationen.
#'
#' @examples
#' strategy <- create_strategy(
#'   MSCI_World = asset_config(asset_class = "etf", share = 0.8, partial_exemption = 30),
#'   Gold = asset_config(asset_class = "etc", share = 0.2, deliverable = TRUE)
#' )
#'
#' @seealso [asset_config()], [strategy_validate()], [simulation()]
#' @export
#' @noRd
create_strategy <- function(..., assets = NULL) {
  dots <- list(...)
  
  if (!is.null(assets) && length(dots) > 0) {
    stop("create_strategy: Assets entweder \u00fcber ... oder \u00fcber assets angeben, nicht beides.")
  }
  
  if (!is.null(assets)) {
    if (!is.list(assets) || is.null(names(assets))) {
      stop("create_strategy: assets muss eine benannte Liste sein (Name = Kursspalte in data).")   # seit 1.6.4 ohne Klasse
    }
    dots <- assets
  }
  
  if (length(dots) == 0) {
    stop("create_strategy: mindestens eine Asset-Konfiguration angeben, z. B. create_strategy(ETF = asset_config(\"etf\")).")
  }
  
  if (is.null(names(dots)) || any(is.na(names(dots)) | names(dots) == "")) {   # seit 1.6.4 auch NA (bis 1.6.3 Rohfehler)
    stop("create_strategy: alle Assets m\u00fcssen benannt sein (Name = Kursspalte in data), z. B. create_strategy(ETF = asset_config(\"etf\")).")
  }
  if (anyDuplicated(names(dots))) {
    stop(sprintf("create_strategy: Asset-Name '%s' kommt mehrfach vor; jeder Name darf nur einmal vorkommen.",
                 names(dots)[anyDuplicated(names(dots))]))
  }
  
  # Einfache Listen in asset_config umwandeln
  for (name in names(dots)) {
    if (!inherits(dots[[name]], "asset_config")) {
      if (is.list(dots[[name]])) {
        .asset_list_fields(dots[[name]], name, "create_strategy")   # seit 1.6.4 (K43 T1-N1, Entscheidung 11)
        dots[[name]] <- do.call(asset_config, dots[[name]])
      } else {
        stop(sprintf("create_strategy: Asset '%s' muss ein asset_config()-Objekt oder eine Liste sein.", name))
      }
    }
  }
  
  class(dots) <- c("strategy", "list")
  return(dots)
}


#' Feldnamen eines Listen-Assets pruefen (seit 1.6.4, K43 T1-N1; Entscheidungen 8, 11, 21)
#'
#' Unbenannte, unbekannte und doppelte Felder sind ein Fehler mit Meldung aus der Tabelle (ohne Eingabewert); bis
#' dahin gab create_strategy() R's Rohmeldung "unused argument (foo = 1)" bzw. nahm unbenannte Felder nach Position
#' und doppelte als Fehler von do.call, simulation() uebersprang unbekannte Felder still (erstes Feld galt).
#' @keywords internal
#' @noRd
.ASSET_FIELDS <- c("asset_class", "trading", "share", "spread", "partial_exemption", "deliverable", "start",
                   "tax_regime", "signal_buy", "signal_sell", "wrapper")
.asset_list_fields <- function(a, nm, fn) {
  k <- names(a)
  if (length(a) && (is.null(k) || any(is.na(k) | !nzchar(k)))) chk_stop("ut1.asset_unbenannt", fn, nm)
  bad <- setdiff(k, .ASSET_FIELDS)
  if (length(bad)) chk_stop("ut1.asset_feld", fn, bad[1L], nm)
  if (anyDuplicated(k)) chk_stop("ut1.asset_feld_doppelt", fn, k[anyDuplicated(k)], nm)
  invisible(NULL)
}

#' Strategie gegen Daten pruefen
#'
#' Prueft, ob das Objekt eine Strategie aus asset_config-Objekten ist und
#' (falls data angegeben) ob alle Assets eine passende Spalte in den Daten haben
#' und die benoetigten Signalspalten existieren.
#'
#' @param strategy Ein strategy-Objekt
#' @param data data.frame zum Abgleich oder NULL (dann nur Pruefung der Objektstruktur).
#'   Muss je Asset eine Spalte enthalten.
#'
#' @return TRUE, wenn gueltig; sonst Abbruch mit Fehler.
#'
#' @examples
#' \dontrun{
#' strategy_validate(strategy, market_data)
#' }
#'
#' @export
#' @noRd
strategy_validate <- function(strategy, data = NULL) {
  if (!inherits(strategy, "strategy")) {
    stop("strategy_validate: strategy muss ein Objekt der Klasse \"strategy\" sein (aus create_strategy()).")
  }
  
  for (i in seq_along(strategy)) {
    if (!inherits(strategy[[i]], "asset_config")) {
      stop(sprintf("strategy_validate: Asset '%s' ist kein asset_config()-Objekt.", names(strategy)[i]))
    }
  }
  
  chk_df(data, "strategy_validate", "data", null_ok = TRUE)   # seit 1.6.4 (bis 1.6.3: Liste/Matrix je Sprache anders)
  if (!is.null(data)) {
    data_cols <- colnames(data)
    # Fonds-Wrapper: der Asset-Name ist keine Kursspalte (Verwechslung ausschliessen), geprueft werden die
    # Spalten der inneren Strategie (.strategy_columns); ohne Wrapper sind das die Asset-Namen
    wraps <- .strategy_wrappers(strategy)
    coll <- intersect(wraps, data_cols)
    if (length(coll))
      stop(sprintf("strategy_validate: Asset '%s' ist ein Fonds-Wrapper (asset_config(wrapper = )); data darf keine Spalte gleichen Namens enthalten (der Anteilswert wird aus den inneren Spalten gerechnet).",
                   coll[1]))
    asset_names <- .strategy_columns(strategy)
    
    missing_assets <- setdiff(asset_names, data_cols)
    if (length(missing_assets) > 0) {
      stop(sprintf("strategy_validate: Kursspalte(n) %s fehlen in data (je Asset eine Spalte gleichen Namens; vorhanden: %s).",
                   paste0("'", missing_assets, "'", collapse = ", "), paste(data_cols, collapse = ", ")))
    }
    
    for (name in names(strategy)) {
      asset <- strategy[[name]]
      if (inherits(asset$wrapper, "SimLevWrapperConfig")) {   # innere Signale
        strategy_validate(asset$wrapper$strategy, data)
        next
      }
      if (asset$trading == "signal") {
        if (!asset$signal_buy %in% data_cols) {
          stop(sprintf("strategy_validate: signal_buy-Spalte '%s' fehlt in data (Asset '%s').",
                       asset$signal_buy, name))
        }
        if (!asset$signal_sell %in% data_cols) {
          stop(sprintf("strategy_validate: signal_sell-Spalte '%s' fehlt in data (Asset '%s').",
                       asset$signal_sell, name))
        }
      }
    }
  }
  
  return(TRUE)
}


#' Asset zur Strategie hinzufuegen
#'
#' @param strategy Ein strategy-Objekt
#' @param name Zeichenkette. Name des neuen Assets
#' @param asset Ein asset_config-Objekt
#'
#' @return Aktualisiertes strategy-Objekt
#' @export
#' @noRd
strategy_add_asset <- function(strategy, name, asset) {
  if (!inherits(strategy, "strategy")) {
    stop("strategy_add_asset: strategy muss ein Objekt der Klasse \"strategy\" sein (aus create_strategy()).")
  }
  if (!inherits(asset, "asset_config")) {
    stop("strategy_add_asset: asset muss ein asset_config()-Objekt sein.")
  }
  chk_name1(name, "strategy_add_asset", "name")   # seit 1.6.4 (bis 1.6.3: Zahl, NA, Vektor still oder Rohfehler)
  # seit 1.6.4 kein stilles Ueberschreiben (Entscheidung 5): Aendern geht ueber strategy_update_asset()
  if (name %in% names(strategy))
    stop("strategy_add_asset: Ein Asset mit diesem Namen ist schon in der Strategie; zum \u00c4ndern strategy_update_asset() verwenden.")

  strategy[[name]] <- asset
  return(strategy)
}


#' Asset in der Strategie aendern
#'
#' @param strategy Ein strategy-Objekt
#' @param name Zeichenkette. Name des zu aendernden Assets
#' @param ... Zu aendernde Felder (z. B. share = 0.5); unbekannte Felder werden
#'   mit Warnung ignoriert. Das Asset wird danach mit asset_config() neu geprueft.
#'   Aendert sich asset_class oder deliverable und wird tax_regime nicht mit
#'   angegeben, wird ein bisher automatisch abgeleitetes tax_regime neu abgeleitet;
#'   ein abweichend gesetztes (explizites) tax_regime bleibt erhalten.
#'
#' @return Aktualisiertes strategy-Objekt
#' @export
#' @noRd
strategy_update_asset <- function(strategy, name, ...) {
  if (!inherits(strategy, "strategy")) {
    stop("strategy_update_asset: strategy muss ein Objekt der Klasse \"strategy\" sein (aus create_strategy()).")
  }
  chk_name1(name, "strategy_update_asset", "name")   # seit 1.6.4 (bis 1.6.3: Vektor Rohfehler, NA als 'NA')
  
  if (!name %in% names(strategy)) {
    stop(sprintf("strategy_update_asset: Asset '%s' ist nicht in der Strategie (vorhanden: %s).", name, paste(names(strategy), collapse = ", ")))
  }
  
  updates <- list(...)
  asset <- strategy[[name]]
  # seit 1.6.4 (K43 T1-R14, Entscheidung 21): unbekannte, doppelte und unbenannte Angaben in ... sind ein Fehler (bis
  # dahin unbekannte nur eine Warnung, doppelte und unbenannte still: das erste galt bzw. die Angabe fiel weg)
  nm <- names(updates)
  if (length(updates) && (is.null(nm) || any(!nzchar(nm)))) chk_stop("ut1.unbenannt", "strategy_update_asset")
  chk_dots(nm, c(names(asset), "wrapper"), "strategy_update_asset")   # wrapper: Feld nur bei Wrapper-Assets vorhanden
  
  # Wurde tax_regime bisher automatisch abgeleitet, wird es nach einer
  # Aenderung von asset_class/deliverable neu abgeleitet (explizite Werte bleiben)
  if (any(c("asset_class", "deliverable") %in% names(updates)) && !"tax_regime" %in% names(updates)) {
    derived <- tryCatch(suppressWarnings(do.call(asset_config, modifyList(unclass(asset), list(tax_regime = NULL), keep.null = TRUE)))$tax_regime,
                        error = function(e) NULL)
    if (identical(derived, asset$tax_regime)) asset["tax_regime"] <- list(NULL)
  }
  
  for (param in names(updates)) asset[param] <- list(updates[[param]])
  
  strategy[[name]] <- do.call(asset_config, unclass(asset))
  return(strategy)
}


#' Asset aus der Strategie entfernen
#'
#' @param strategy Ein strategy-Objekt
#' @param name Zeichenkette. Name des zu entfernenden Assets
#'
#' @return Aktualisiertes strategy-Objekt (Warnung, wenn es danach leer ist)
#' @export
#' @noRd
strategy_remove_asset <- function(strategy, name) {
  if (!inherits(strategy, "strategy")) {
    stop("strategy_remove_asset: strategy muss ein Objekt der Klasse \"strategy\" sein (aus create_strategy()).")
  }
  chk_name1(name, "strategy_remove_asset", "name")   # seit 1.6.4 (bis 1.6.3: Vektor Rohfehler, NA als 'NA')
  
  if (!name %in% names(strategy)) {
    stop(sprintf("strategy_remove_asset: Asset '%s' ist nicht in der Strategie (vorhanden: %s).", name, paste(names(strategy), collapse = ", ")))
  }
  
  strategy[[name]] <- NULL
  
  if (length(strategy) == 0) {
    warning(sprintf("strategy_remove_asset: Nach dem Entfernen von '%s' enth\u00e4lt die Strategie keine Assets mehr.", name))
  }
  
  return(strategy)
}


#' Strategie ausgeben
#' @param x Ein strategy-Objekt
#' @param ... Weitere Argumente (ignoriert)
#' @return x, unsichtbar
#' @export
#' @noRd
print.strategy <- function(x, ...) {
  cat(sprintf("Anlagestrategie (%d %s)\n", length(x), if (length(x) == 1L) "Asset" else "Assets"))
  cat("================================\n\n")
  
  for (name in names(x)) {
    asset <- x[[name]]
    cat(sprintf("%s:\n", name))
    cat(sprintf("  Klasse: %s | Anteil: %.0f%% | Steuer: %s%s\n",
                asset$asset_class, asset$share * 100, asset$tax_regime,
                if (inherits(asset$wrapper, "SimLevWrapperConfig"))
                  sprintf(" | Wrapper: %s", paste(names(asset$wrapper$strategy), collapse = ", ")) else ""))
  }
  
  invisible(x)
}


#' Zusammenfassung einer Strategie
#' @param object Ein strategy-Objekt
#' @param ... Weitere Argumente (ignoriert)
#' @return object, unsichtbar
#' @export
#' @noRd
summary.strategy <- function(object, ...) {
  cat(sprintf("Strategie-\u00dcbersicht: %d %s\n\n", length(object), if (length(object) == 1L) "Asset" else "Assets"))
  
  # seit 1.6.4 unlist(lapply()) statt sapply(): leere Strategie ergibt 0 wie in Python/Julia (bis 1.6.3 Rohfehler
  # "invalid 'type' (list)"); sonst derselbe Zahlenvektor
  total_share <- sum(unlist(lapply(object, function(a) a$share)))
  cat(sprintf("Gesamtgewicht: %.1f%%\n", total_share * 100))
  
  if (abs(total_share - 1) > 0.001) {
    cat("  (Hinweis: Summe ist nicht 100%)\n")
  }
  
  cat("\nNach Steuerregime:\n")
  regimes <- sapply(object, function(a) a$tax_regime)
  for (regime in unique(regimes)) {
    n <- sum(regimes == regime)
    cat(sprintf("  %s: %d %s\n", regime, n, if (n == 1L) "Asset" else "Assets"))
  }
  
  invisible(object)
}
