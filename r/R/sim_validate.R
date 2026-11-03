# =============================================================================
# simulation(), Phase 1: Eingabepruefung
# =============================================================================
#
# simulation() (simulation.R) ruft nacheinander interne Phasenfunktionen auf:
#   sim_validate.R  .sim_check_inputs()            Eingabepruefung, Steuer- und Gebuehreneinstellungen
#   sim_prepare.R   .sim_prepare_data()            Kalenderraster, LOCF
#                   .sim_build_state()             Zentralstruktur sim_mem (Feldfolge .SIM_MEM_LAYOUT)
#                   .sim_build_calendar()          Angaben der Termine, Ereignis-Spalte, Pruefungen
#   sim_engine.R    .sim_engine_run()              Termine, Tages-Flags und Startgewichte (core/prepare_core_impl.h;
#                                                  bis 1.3.0 .sim_build_calendar(), .sim_init_weights(),
#                                                  .sim_build_schedule()), Tagesschleife und Abschluss des letzten
#                                                  Jahres im C++-Kern (core/engine_core_impl.h; bis 1.3.0
#                                                  .sim_make_actions(), .sim_run_days() mit .sim_day_*() und
#                                                  .sim_close_years())
#   sim_evaluate.R  .sim_evaluate() (Kern core/evaluate_core_impl.h), .sim_risk_free(),
#                   .sim_result()   Auswertung und Ergebnisobjekt
# Die Phasen geben ihre Ergebnisse als Werte zurueck; Argumente von simulation() werden unausgewertet
# durchgereicht und erst beim ersten Gebrauch ausgewertet (wie vorher in einem Funktionskoerper).

# Namen der Phasenfunktionen: Bedingungen, die direkt in einer Phase entstehen (stop()/warning() ohne
# call. = FALSE, R-Fehler im Phasencode), tragen den Aufruf von simulation() (.sim_restore_call)
.SIM_PHASES <- c(".sim_check_inputs", ".sim_prepare_data", ".sim_build_state", ".sim_check_layout",
                 ".sim_build_calendar", ".sim_engine_signal", ".sim_evaluate", ".sim_risk_free", ".sim_result",
                 ".tax_rates")

#' Aufruf von simulation() in Bedingungen aus den Phasen wiederherstellen
#'
#' Zweck: Fehler und Warnungen, deren Aufruf eine Phasenfunktion ist, mit dem Aufruf von simulation()
#' neu signalisieren (Text, Reihenfolge und Aufruf wie vor der Aufteilung). Andere Bedingungen bleiben
#' unberuehrt.
#' Eingabe: cond (Bedingung aus withCallingHandlers()), call (sys.call() von simulation()).
#' Ausgabe: keine; Fehler werden mit neuem Aufruf ausgeloest, Warnungen neu ausgegeben und das
#' Original unterdrueckt.
#' @keywords internal
#' @noRd
.sim_restore_call <- function(cond, call) {
  cc <- conditionCall(cond)
  if (!(is.call(cc) && is.name(cc[[1L]]) && as.character(cc[[1L]]) %in% .SIM_PHASES))
    return(invisible(NULL))
  cond$call <- call
  if (inherits(cond, "error")) stop(cond)
  warning(cond)
  invokeRestart("muffleWarning")
}

#' Prozent-Konvention fuer Spalten pruefen
#'
#' Zweck: wie die Warnung fuer Skalare, aber fuer eine Zinsspalte (risk_free als Spaltenname,
#' base_rate_data): Warnung, wenn der Median der Werte ohne NA und ohne 0 zwischen 0 und hi liegt.
#' Eingabe: v (Spalte), arg (Argumentname), col (Spaltenname), hi (Schwelle wie beim Skalar).
#' Ausgabe: keine (ggf. Warnung).
#' @keywords internal
#' @noRd
.frac_warn_col <- function(v, arg, col, hi) {
  if (!is.numeric(v)) return(invisible(NULL))
  v <- v[!is.na(v) & v != 0]
  if (!length(v)) return(invisible(NULL))
  m <- stats::median(v)
  if (is.finite(m) && m > 0 && m < hi)
    warning(sprintf("simulation: %s-Spalte '%s' hat den Median %s und wird als %s %% gelesen (Prozent-Konvention); gemeint waren vermutlich Werte x 100 (Median %s).",
                    arg, col, format(m), format(m), format(m * 100)), call. = FALSE)
  invisible(NULL)
}

#' Steuersaetze aus Abgeltungsteuer, Kirchensteuer und Guenstigerpruefung
#'
#' Zweck: gemeinsamer Helfer von simulation() (.sim_check_inputs) und withdrawal_simulation(): Satz der
#' Abgeltungsteuer mit Kirchensteuer (§ 32d Abs. 1 EStG), Umrechnung der Prozentangaben in Anteile und
#' effektiver Satz der Guenstigerpruefung (§ 32d Abs. 6 EStG, einmal je Lauf mit dem Grenzsteuersatz aus
#' income_rate()). Rechenfolge, Warnungen und Druck (details) wie bis 1.0.0 in .sim_check_inputs; Meldungen
#' beginnen mit who.
#' Eingabe: rate (Abgeltungsteuer in Prozent), church_tax (Prozent oder NULL), guenstigerpruefung (logisch),
#' marginal_rate (Grenzsteuersatz in Prozent oder NULL), include_soli (logisch), soli_rate (Prozent), who
#' (Name des Aufrufers), details (Druck der Guenstigerpruefung), tariff_on (Tarifweg: die Guenstigerpruefung
#' folgt im Jahresabschluss, hier nicht). Meldungen nennen die Bausteine (der flache Weg entfaellt).
#' Ausgabe: Liste tax_rate, marginal_tax_rate, soli_rate_income_tax (Anteile), effective_tax_rate,
#' church_k, soli_factor_income.
#' @keywords internal
#' @noRd
.tax_rates <- function(rate, church_tax, guenstigerpruefung, marginal_rate, include_soli, soli_rate, who,
                       details = FALSE, tariff_on = FALSE) {
  tax_rate <- rate; marginal_tax_rate <- marginal_rate; soli_rate_income_tax <- soli_rate
  use_guenstigerpruefung <- guenstigerpruefung; include_soli_on_income_tax <- include_soli
  # Kirchensteuer (§ 32d Abs. 1 EStG): ESt = 25 % / (1 + 0,25 k), dazu Soli 5,5 % und KiSt k
  if (!is.null(church_tax) && church_tax > 0) {
    k <- church_tax / 100
    tax_rate <- 100 * 0.25 / (1 + 0.25 * k) * (1 + 0.055 + k)
  }
  # Kirchensteuer auf die Einkommensteuer (§ 23 mit marginal_tax_rate, persoenlicher Satz der
  # Guenstigerpruefung): church_tax Prozent der ESt; der Sonderausgabenabzug der KiSt (§ 10 Abs. 1
  # Nr. 4 EStG) wird bei der ESt nicht abgebildet. Die Abgeltungsteuer-Formel oben bleibt unveraendert.
  church_k <- if (!is.null(church_tax) && church_tax > 0) church_tax / 100 else 0
  # PROZENT-KONVENTION: prozentuale Nutzerangaben -> intern dezimal (/100)
  tax_rate <- tax_rate / 100
  if (!is.null(marginal_tax_rate)) marginal_tax_rate <- marginal_tax_rate / 100
  soli_rate_income_tax <- soli_rate_income_tax / 100
  # ══════════════════════════════════════════════════════════════════════════
  # I3: GÜNSTIGERPRÜFUNG - Effektiven Steuersatz berechnen
  # ══════════════════════════════════════════════════════════════════════════
  # 
  # Die Günstigerprüfung (§ 32d Abs. 6 EStG) erlaubt es Steuerpflichtigen mit
  # niedrigem Einkommen, ihre Kapitalerträge zum persönlichen Steuersatz zu
  # versteuern statt zur Abgeltungsteuer (25%).
  #
  # Voraussetzung: Die Belastung mit dem persoenlichen Satz einschliesslich Soli und KiSt
  # muss niedriger sein als die Abgeltungsteuer einschliesslich Zuschlagsteuern.
  # 
  # Berechnung des effektiven Steuersatzes:
  # - Bei Günstigerprüfung: marginal_tax_rate * (1 + Soli-Satz + KiSt-Satz), wenn kleiner als tax_rate
  # - Ohne Günstigerprüfung: tax_rate / 100, Standard 0.26375 (25% + 5.5% Soli)
  # ══════════════════════════════════════════════════════════════════════════

  effective_tax_rate <- tax_rate  # Default: 26.375%

  # Tarifweg: unterjaehrig Abgeltungsteuer wie bei einer Bank (auch in der Verkaufsschaetzung),
  # Guenstigerpruefung im Jahresabschluss (Tagesengine, Tarifkern core/tariff_core_impl.h)
  if (use_guenstigerpruefung && !tariff_on) {
    if (is.null(marginal_tax_rate)) {
      warning(
        sprintf("%s: G\u00fcnstigerpr\u00fcfung aktiviert (tax_profile(guenstigerpruefung = TRUE)), aber der Grenzsteuersatz (income_rate(marginal_rate)) ist nicht gesetzt.\n", who),
        "Verwendet wird die Abgeltungsteuer (", round(tax_rate * 100, 2), " %).\n",
        "F\u00fcr eine korrekte G\u00fcnstigerpr\u00fcfung tax_profile(income = income_rate(marginal_rate)) in Prozent angeben (z. B. 42).",
        call. = FALSE
      )
    } else if ((personal_rate <- marginal_tax_rate *
                ((if (include_soli_on_income_tax) (1 + soli_rate_income_tax) else 1.0) + church_k)) < tax_rate) {
      # § 32d Abs. 6 Satz 1 EStG: Tarif nur, wenn die Einkommensteuer EINSCHLIESSLICH
      # Zuschlagsteuern niedriger ist -> Gesamtbelastung persoenlicher Satz x (1 + Soli + KiSt)
      # gegen den effektiven Abgeltungsteuersatz (tax_rate, bei church_tax nach § 32d Abs. 1)
      effective_tax_rate <- personal_rate   # ESt + Soli + KiSt
      
      if (details) {
        cat(sprintf(
          "\u2550\u2550\u2550 G\u00fcnstigerpr\u00fcfung aktiv \u2550\u2550\u2550\n  Pers\u00f6nlicher Steuersatz: %.2f%%\n  Effektiver Steuersatz: %.2f%% (statt %.2f%% Abgeltungsteuer)\n  Ersparnis: %.2f Prozentpunkte\n\n",
          marginal_tax_rate * 100, effective_tax_rate * 100, tax_rate * 100,
          (tax_rate - effective_tax_rate) * 100
        ))
      }
    } else {
      # Belastung mit persoenlichem Satz nicht niedriger: Abgeltungsteuer bleibt
      if (details) {
        cat(sprintf(
          "\u2550\u2550\u2550 G\u00fcnstigerpr\u00fcfung gepr\u00fcft \u2550\u2550\u2550\n  Pers\u00f6nlicher Steuersatz: %.2f%%\n  Abgeltungsteuer: %.2f%% \u2192 bleibt g\u00fcnstiger\n\n",
          personal_rate * 100, tax_rate * 100
        ))
      }
    }
  }
  # ══════════════════════════════════════════════════════════════════════════

  # Soli-Faktor für ESt-Berechnungen (§ 23, Günstigerprüfung)
  soli_factor_income <- if (include_soli_on_income_tax) (1 + soli_rate_income_tax) else 1.0

  list(tax_rate = tax_rate, marginal_tax_rate = marginal_tax_rate, soli_rate_income_tax = soli_rate_income_tax,
       effective_tax_rate = effective_tax_rate, church_k = church_k, soli_factor_income = soli_factor_income)
}

#' Phase 1 von simulation(): Eingabepruefung
#'
#' Zweck: Argumente von simulation() pruefen (Fehler und Warnungen wie dokumentiert), Prozentangaben
#' in Anteile umrechnen, Ordergebuehren, Einkommensteuertarif und effektiven Steuersatz
#' (Guenstigerpruefung) bestimmen.
#' Eingabe: die gleichnamigen Argumente von .simulation_flat() (tariff = tax_tariff), aus den Bausteinen von
#' simulation() uebersetzt. Die Bausteine haben ihre Argumente schon geprueft (die Pruefungen hier entfallen,
#' Warnungen kommen nicht doppelt), Meldungen nennen die Bausteine (der flache Weg ohne Bausteine
#' mit eigenen Pruefungen und Meldungen ist entfallen).
#' Ausgabe: Liste cfg mit data und strategy (geprueft, ggf. sortiert bzw. mit start), den
#' Steuerwerten als Anteil (tax_rate, marginal_tax_rate, effective_tax_rate, soli_factor_income,
#' church_k), tariff_env, den Gebuehren (fee_order, fee_dca, fees_on), pre_filled und den hier
#' ausgewerteten Einstellungen.
#' @keywords internal
#' @noRd
.sim_check_inputs <- function(data, strategy, start_value, spread, details, dca_mode, dca_value, dca_days,
                              balance_mode, balance_days, balance_thresh,
                              balance_thresh_type = c("absolute", "relative"),
                              tax_mode = c("none", "person"), tax_rate, marginal_tax_rate,
                              use_guenstigerpruefung, private_sale_threshold, sparer_pauschbetrag,
                              use_sparer_pauschbetrag, include_soli_on_income_tax, soli_rate_income_tax,
                              base_rate, fractions, risk_free, split_mode, split_thresh,
                              event_col, church_tax, order_fee, dca_fee, harvest_mode,
                              taxable_income, tariff) {
    # === PARAMETER-VALIDIERUNG ===
  tax_mode <- match.arg(tax_mode)
  
  # Pflichtparameter
  if (missing(data) || !is.data.frame(data)) {
    stop(sprintf("simulation: data muss ein data.frame mit Spalte 'date' und je Asset einer Kursspalte sein, nicht %s.",
                 if (missing(data)) "fehlend" else paste(class(data), collapse = "/")))
  }
  if (missing(strategy) || length(strategy) == 0) {
    stop(sprintf("simulation: strategy muss eine nicht leere, benannte Liste von Asset-Konfigurationen sein (z. B. aus create_strategy()), nicht %s.",
                 if (missing(strategy)) "fehlend" else "leer (L\u00e4nge 0)"))
  }
  if (!is.null(spread))   # Argument bleibt fuer die Signatur (Python/Julia) erhalten
    warning("simulation: Das Argument 'spread' wird nicht ausgewertet; ma\u00dfgeblich ist spread je Asset (asset_config()).", call. = FALSE)

  # --- Eingabepruefung der Daten ---
  filled_attr <- attr(data, "filled")                 # series_align(): gefuellte Werte (Matrix)
  if (!identical(class(data), "data.frame")) data <- as.data.frame(data, stringsAsFactors = FALSE)  # z. B. tibble
  if (is.null(names(strategy)) || any(names(strategy) == ""))
    stop("simulation: Alle Assets in 'strategy' m\u00fcssen benannt sein (Name = Kursspalte in 'data').")
  if (anyDuplicated(names(strategy)))
    stop(sprintf("simulation: Asset-Name '%s' kommt in 'strategy' mehrfach vor; jeder Name darf nur einmal vorkommen.",
                 names(strategy)[anyDuplicated(names(strategy))]))
  if (anyDuplicated(names(data)))   # R2: sonst wuerde still die erste gleichnamige Spalte verwendet
    stop(sprintf("simulation: Spaltenname '%s' kommt in 'data' mehrfach vor; jede Spalte muss eindeutig benannt sein.",
                 names(data)[anyDuplicated(names(data))]))
  # C7-01: Listen-Strategien (ohne create_strategy()/asset_config()) wie asset_config() pruefen; ein
  # ungueltiges Steuerregime (z. B. "none") fuehrte sonst still zu einer Rechnung ohne Steuern
  for (nm in names(strategy)) {
    a <- strategy[[nm]]
    if (!is.list(a))
      stop(sprintf("simulation: Asset '%s' in 'strategy' muss eine Liste bzw. asset_config() sein.", nm), call. = FALSE)
    cls_ok <- c("etf", "etn", "etc", "certificate", "etn_standard", "etn_deliverable")
    if (!is.character(a$asset_class) || length(a$asset_class) != 1L || !a$asset_class %in% cls_ok)
      stop(sprintf("simulation: asset_class %s von Asset '%s' ist ung\u00fcltig; erlaubt sind %s (veraltet: etn_standard, etn_deliverable). Strategie am besten mit create_strategy()/asset_config() bauen.",
                   .show_arg_s(a$asset_class), nm, paste(cls_ok[1:4], collapse = ", ")), call. = FALSE)
    if (!is.null(a$tax_regime) && (!is.character(a$tax_regime) || length(a$tax_regime) != 1L ||
                                   !a$tax_regime %in% c("investment_fund", "capital_gains", "private_sale")))
      stop(sprintf("simulation: tax_regime %s von Asset '%s' ist ung\u00fcltig; erlaubt sind investment_fund, capital_gains, private_sale (oder weglassen: aus asset_class abgeleitet). Ohne Steuern %s verwenden.",
                   .show_arg_s(a$tax_regime), nm, "tax = NULL"), call. = FALSE)
    if (!is.character(a$trading) || length(a$trading) != 1L || !a$trading %in% c("bnh", "signal"))
      stop(sprintf("simulation: trading %s von Asset '%s' ist ung\u00fcltig; erlaubt sind \"bnh\" und \"signal\".",
                   .show_arg_s(a$trading), nm), call. = FALSE)
    if (!is.null(a[["wrapper"]])) {   # Fonds-Wrapper (wrapper.R)
      if (!inherits(a[["wrapper"]], "SimLevWrapperConfig"))
        stop(sprintf("simulation: wrapper von Asset '%s' muss ein Objekt aus wrapper_config() sein, nicht %s.",
                     nm, paste(class(a[["wrapper"]]), collapse = "/")), call. = FALSE)
      if (a$trading != "bnh")
        stop(sprintf("simulation: Asset '%s' ist ein Fonds-Wrapper; daf\u00fcr ist nur trading = \"bnh\" m\u00f6glich (keine Signale auf den Anteilswert).",
                     nm), call. = FALSE)
    }
  }
  if (!"date" %in% names(data)) stop("simulation: Spalte 'date' fehlt in 'data'.")
  # Fonds-Wrapper: Asset-Name ist keine Kursspalte; gebraucht werden die inneren Spalten (.strategy_columns)
  wraps <- .strategy_wrappers(strategy)
  if (length(coll <- intersect(wraps, names(data))))
    stop(sprintf("simulation: Asset '%s' ist ein Fonds-Wrapper (asset_config(wrapper = )); 'data' darf keine Spalte gleichen Namens enthalten (der Anteilswert wird aus den inneren Spalten gerechnet). Spalte umbenennen oder entfernen.",
                 coll[1]), call. = FALSE)
  miss <- setdiff(.strategy_columns(strategy), names(data))
  if (length(miss))
    stop(sprintf("simulation: %s %s in 'data'; je Asset der Strategie wird eine Spalte gleichen Namens erwartet (vorhanden: %s).",
                 if (length(miss) == 1L) "Kursspalte" else "Kursspalten", paste(paste0("'", miss, "'", collapse = ", "),
                 if (length(miss) == 1L) "fehlt" else "fehlen"), paste(setdiff(names(data), "date"), collapse = ", ")))
  if (nrow(data) < 1L) stop("simulation: 'data' enth\u00e4lt keine Zeilen.")
  if (is.factor(data$date)) data$date <- as.character(data$date)
  if (is.character(data$date)) {
    dd <- as.Date(data$date, format = "%Y-%m-%d")
    bad <- which(is.na(dd) & !is.na(data$date))
    if (length(bad)) stop(sprintf("simulation: Spalte 'date' ist Text und '%s' (Zeile %d) ist kein Datum im Format JJJJ-MM-TT; vorher mit as.Date(..., format = ...) umwandeln.",
                                  data$date[bad[1]], bad[1]))
    data$date <- dd
    message("Hinweis: Spalte 'date' wurde von Text in Date umgewandelt.")
  } else if (inherits(data$date, "POSIXt")) {
    data$date <- as.Date(format(data$date, "%Y-%m-%d"))
    message("Hinweis: Spalte 'date' wurde von Datum-Uhrzeit in Date umgewandelt.")
  }
  if (!inherits(data$date, "Date"))
    stop(sprintf("simulation: Spalte 'date' muss die Klasse Date haben (ist: %s).", class(data$date)[1]))
  if (anyNA(data$date)) stop(sprintf("simulation: Spalte 'date' enth\u00e4lt NA (erstmals in Zeile %d).", which(is.na(data$date))[1]))
  if (is.unsorted(data$date)) {
    o <- order(data$date)
    data <- data[o, , drop = FALSE]; rownames(data) <- NULL
    if (is.matrix(filled_attr) && nrow(filled_attr) == length(o)) filled_attr <- filled_attr[o, , drop = FALSE]
    message("Hinweis: 'data' war nicht aufsteigend nach Datum sortiert und wurde sortiert.")
  }
  if (anyDuplicated(data$date))
    stop(sprintf("simulation: Datum %s kommt in 'data' mehrfach vor (%d doppelte Zeilen); je Tag genau eine Zeile.",
                 format(data$date[anyDuplicated(data$date)]), sum(duplicated(data$date))))
  # Fonds-Wrapper: Anteilswert je Wrapper-Asset aus den inneren Spalten (wrapper.R) als Kursspalte mit dem
  # Asset-Namen anhaengen (NA vor dem Beginn und an Tagen ohne inneren Kurs); danach ist das Asset ein
  # gewoehnliches asset_config ohne wrapper. splits gelten fuer die inneren Spalten, nicht fuer den Anteilswert.
  wrapper_navs <- NULL
  if (length(wraps)) {
    d_in <- data
    if (is.matrix(filled_attr) && nrow(filled_attr) == nrow(data)) attr(d_in, "filled") <- filled_attr
    sp <- if (isTRUE(split_mode) && !is.null(split_thresh)) structure(list(thresh = unlist(split_thresh)), class = "SimLevSplitRule")
    wrapper_navs <- lapply(stats::setNames(wraps, wraps), function(nm)
      .wrapper_nav_calc(d_in, strategy[[nm]][["wrapper"]], sp, tag = sprintf("Wrapper '%s'", nm),
                        who = sprintf("simulation: Wrapper '%s'", nm)))
    for (nm in wraps) {
      v <- rep(NA_real_, nrow(data))
      v[match(wrapper_navs[[nm]]$date, data$date)] <- wrapper_navs[[nm]]$nav
      data[[nm]] <- v
      strategy[[nm]][["wrapper"]] <- NULL
    }
  }
  # Tage ohne echten Kurs: aus series_align() (Attribut 'filled') bzw. Zeilen, in denen alle Kurse NA sind
  # Attribut mit anderer Zeilenzahl (z. B. nach Zeilenauswahl) ist nicht zuordenbar (traegt keine Daten)
  if (!is.null(filled_attr) && (n_fa <- if (is.matrix(filled_attr)) nrow(filled_attr) else length(filled_attr)) != nrow(data)) {
    warning(sprintf(paste0("simulation: Attribut 'filled' von 'data' hat %d Zeilen, 'data' aber %d (z. B. nach Zeilenauswahl einer ",
                           "series_align()-Ausgabe); es wird ignoriert, aufgef\u00fcllte Tage gelten dann als Handelstage. ",
                           "Zeitraum besser mit series_align(..., start =, end =) w\u00e4hlen."), n_fa, nrow(data)), call. = FALSE)
    filled_attr <- NULL
  }
  pre_filled <- rep(FALSE, nrow(data))
  if (is.matrix(filled_attr) && nrow(filled_attr) == nrow(data) && length(fc <- intersect(names(strategy), colnames(filled_attr)))) {
    real <- !filled_attr[, fc, drop = FALSE] & !is.na(as.matrix(data[fc]))
    pre_filled <- rowSums(real) == 0
  }
  all_na <- Reduce(`&`, lapply(names(strategy), function(nm) is.na(data[[nm]])))
  if (all_na[1]) stop("simulation: In der ersten Zeile von 'data' fehlen alle Kurse (NA); mindestens ein Asset muss am ersten Tag notieren. Daten erst ab dem ersten Kurs \u00fcbergeben.")
  pre_filled <- pre_filled | all_na
  for (nm in names(strategy)) {
    v <- data[[nm]]
    if (!is.numeric(v)) stop(sprintf("simulation: Kursspalte '%s' muss numerisch sein (ist: %s).", nm, class(v)[1]))
    bad <- which(!is.na(v) & !(is.finite(v) & v > 0))
    if (length(bad)) stop(sprintf("simulation: Kursspalte '%s' enth\u00e4lt ung\u00fcltige Kurse (<= 0 oder unendlich), erstmals am %s (Wert %s); erwartet werden positive Kursniveaus.",
                                  nm, format(data$date[bad[1]]), format(v[bad[1]])))
    ok <- which(!is.na(v))
    if (!length(ok)) stop(sprintf("simulation: Kursspalte '%s' enth\u00e4lt nur NA.", nm))
    if (length(ok) < length(v)) {
      if (ok[1] > 1L) {                               # spaeter startendes Asset: wie start
        st0 <- strategy[[nm]][["start"]]
        st_new <- max(data$date[ok[1]], if (is.null(st0)) data$date[1] else as.Date(st0))
        strategy[[nm]][["start"]] <- st_new
        message(sprintf("Hinweis: '%s' hat erst ab %s Kurse; das Asset wird wie mit start = %s behandelt.",
                        nm, format(data$date[ok[1]]), format(st_new)))
      }
      n_gap <- sum(is.na(v)) - (ok[1] - 1L)
      if (n_gap > 0) message(sprintf("Hinweis: '%s': %d fehlende Kurse (NA) per LOCF gef\u00fcllt.", nm, n_gap))
      idx <- integer(length(v)); idx[ok] <- ok; idx <- cummax(idx); idx[idx == 0L] <- ok[1]
      data[[nm]] <- v[idx]
    }
  }

  # start_value
  if (is.null(start_value) || is.na(start_value)) {
    start_value <- 10000
    message("Hinweis: start_value ist NULL oder NA; verwendet wird der Standardwert 10000 EUR.")
  }
  if (!is.numeric(start_value) || start_value <= 0) {
    stop(sprintf("simulation: start_value muss eine positive Zahl sein (Anfangskapital in EUR, z. B. 10000), nicht %s.",
                 paste(deparse(start_value), collapse = "")))
  }
  
  # Steuer-, Kosten-, Termin- und Split-Angaben haben die Bausteine geprueft (tax_profile(), sim_costs(),
  # dca_plan(), rebalance_plan(), split_rule(); die Pruefungen des flachen Wegs sind entfallen).
  # fractions (TRUE/FALSE) und risk_free (Prozent-Konvention) prueft simulation() selbst
  .show_arg <- function(x) if (is.null(x)) "NULL" else paste(deparse(x), collapse = "")
  .frac_warn <- function(x, arg, hi = 1) {
    if (is.numeric(x) && length(x) == 1L && is.finite(x) && x > 0 && x < hi)
      warning(sprintf("simulation: %s = %s wird als %s %% gelesen (Prozent-Konvention); gemeint war vermutlich %s.",
                      arg, format(x), format(x), format(x * 100)), call. = FALSE)
  }
  if (!is.logical(fractions) || length(fractions) != 1L || is.na(fractions))
    stop(sprintf("simulation: '%s' muss TRUE oder FALSE sein, nicht %s.", "fractions", .show_arg(fractions)), call. = FALSE)
  .frac_warn(risk_free, "risk_free", hi = 0.05)
  # dieselbe Schwelle fuer risk_free als Spaltenname (Median der Spalte; base_rate_data: .sim_prepare_data)
  if (is.character(risk_free) && length(risk_free) == 1L && !is.na(risk_free) && risk_free %in% names(data))
    .frac_warn_col(data[[risk_free]], "risk_free", risk_free, hi = 0.05)

  # Einkommensteuertarif (taxable_income, tax_tariff): zvE je Kalenderjahr pruefen, Tarif lesen
  # (taxable_income und tax_tariff nur aus income_tariff() in tax_profile(), also nur mit tax_mode = "person")
  tariff_on <- !is.null(taxable_income) && tax_mode == "person"
  tariff_env <- NULL
  if (tariff_on) {
    sim_years <- seq(as.integer(format(min(data$date), "%Y")), as.integer(format(max(data$date), "%Y")))
    zv <- .check_taxable_income(taxable_income, sim_years)
    tt <- if (is.null(tariff)) tax_tariff()
          else if (inherits(tariff, "SimLevTaxTariff")) tariff
          else if (is.character(tariff) && length(tariff) == 1L && !is.na(tariff)) tax_tariff(tariff)
          else stop("simulation: tax_tariff muss NULL (mitgelieferte Tarifdatei), ein Dateipfad oder ein Objekt aus tax_tariff() sein.", call. = FALSE)
    tariff_env <- new.env(parent = emptyenv())
    tariff_env$tariff <- tt
    tariff_env$zve_all <- zv$all; tariff_env$zve <- zv$by_year
    tariff_env$ks <- stats::setNames(numeric(0), character(0))   # KiSt-Bescheid-Saldo je Zahlungsjahr
    tariff_env$church_k <- if (!is.null(church_tax) && church_tax > 0) church_tax / 100 else 0
    tariff_env$kapest_rate <- 0.25 / (1 + 0.25 * tariff_env$church_k)   # KapESt-Satz nach § 32d Abs. 1 EStG
    tariff_env$use_gp <- isTRUE(use_guenstigerpruefung)
    tariff_env$rows <- list(); tariff_env$refund_due <- 0
  }

  # marginal_tax_rate (wenn private_sale vorhanden)
  has_private_sale <- any(sapply(strategy, function(a) {
    isTRUE(a$tax_regime == "private_sale") || 
    isTRUE(a$asset_class == "etn_deliverable") ||
    (isTRUE(a$asset_class %in% c("etn", "etc")) && isTRUE(a$deliverable))
  }))
  if (has_private_sale && is.null(marginal_tax_rate) && tax_mode == "person" && !tariff_on) {   # nur wenn § 23 besteuert wird
    warning("simulation: Der Grenzsteuersatz ist nicht gesetzt (tax_profile(income = income_rate(marginal_rate))), die Strategie enth\u00e4lt aber Assets mit tax_regime = \"private_sale\"; ",
            "Gewinne nach Paragraf 23 EStG werden dann m\u00f6glicherweise nicht korrekt besteuert. income_rate(marginal_rate) in Prozent angeben (z. B. 42).")
  }

  # Kirchensteuer, Prozent-Konvention und Guenstigerpruefung: .tax_rates() (unten, nach der Gewichtssumme)
  if (!is.null(balance_thresh)) balance_thresh <- balance_thresh / 100  # Prozent
  # Toleranzband: "absolute" = Prozentpunkte des Gewichts (Standard, wie bisher),
  # "relative" = Prozent des Zielgewichts (z. B. 25 -> Ziel 40 % darf 30-50 % sein)
  balance_thresh_type <- match.arg(balance_thresh_type)
  # Ordergebuehren: Angaben fuer die Tagesengine (sim_engine.R); .fee_env$paid summiert die gezahlten Gebuehren
  fee_order <- .fee_spec(order_fee); fee_dca <- if (is.null(dca_fee)) fee_order else .fee_spec(dca_fee)
  fees_on <- !is.null(fee_order) || !is.null(fee_dca)
  .fee_env$paid <- 0
  # base_rate: KEINE Division hier — .calculate_flat_rate teilt an der Verbrauchsstelle /100

  # Gewichtssumme validieren
  total_weight <- sum(sapply(strategy, function(a) a$share), na.rm = TRUE)
  if (abs(total_weight - 1.0) > 1e-6) {
    stop(sprintf(
      "simulation: Asset-Gewichte (share) summieren sich auf %.4f, m\u00fcssen aber exakt 1.0 ergeben (Anteile, z. B. 0.6 und 0.4).\n  Aktuelle Gewichte: %s",
      total_weight,
      paste(sprintf("%s=%.3f", names(strategy), sapply(strategy, function(a) a$share)), collapse = ", ")
    ))
  }

  # Steuersaetze (Kirchensteuer, Prozent -> Anteil, Guenstigerpruefung) im gemeinsamen Helfer (seit 1.1.0
  # auch fuer withdrawal_simulation()); Rechenfolge, Warnungen und Druck wie bisher an dieser Stelle
  tr <- .tax_rates(tax_rate, church_tax, use_guenstigerpruefung, marginal_tax_rate, include_soli_on_income_tax,
                   soli_rate_income_tax, who = "simulation", details = details, tariff_on = tariff_on)
  tax_rate <- tr$tax_rate; marginal_tax_rate <- tr$marginal_tax_rate; effective_tax_rate <- tr$effective_tax_rate
  soli_factor_income <- tr$soli_factor_income; church_k <- tr$church_k

  list(data = data, strategy = strategy, tax_mode = tax_mode, start_value = start_value,
       tax_rate = tax_rate, marginal_tax_rate = marginal_tax_rate, effective_tax_rate = effective_tax_rate,
       soli_factor_income = soli_factor_income, church_k = church_k, tariff_env = tariff_env,
       private_sale_threshold = private_sale_threshold, sparer_pauschbetrag = sparer_pauschbetrag,
       use_sparer_pauschbetrag = use_sparer_pauschbetrag, fractions = fractions,
       fee_order = fee_order, fee_dca = fee_dca, fees_on = fees_on, order_fee = order_fee,
       dca_mode = dca_mode, dca_value = dca_value, dca_days = dca_days,
       balance_mode = balance_mode, balance_days = balance_days,
       balance_thresh = balance_thresh, balance_thresh_type = balance_thresh_type,
       base_rate = base_rate, risk_free = risk_free, harvest_mode = harvest_mode,
       split_mode = split_mode, event_col = event_col, pre_filled = pre_filled,
       no_split = wraps, wrappers = if (isTRUE(details)) wrapper_navs)
}
