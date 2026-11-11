# =============================================================================
# simulation(), Phase 1: Eingabepruefung
# =============================================================================
#
# simulation() (simulation.R) ruft nacheinander interne Phasenfunktionen auf:
#   sim_validate.R  .sim_check_inputs()            Eingabepruefung, Steuer- und Gebuehreneinstellungen
#   sim_prepare.R   .sim_prepare_data()            Kalenderraster, LOCF
#                   .sim_build_state()             Zentralstruktur sim_mem
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
.SIM_PHASES <- c(".sim_check_inputs", ".sim_prepare_data", ".sim_build_state", ".sim_build_calendar",
                 ".sim_engine_signal", ".sim_evaluate", ".sim_risk_free", ".sim_result",
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

#' Pruef-Cache je Studie (seit 1.5.1)
#'
#' Zweck: Studien (bootstrap_study, param_search, sensitivity_*, planning_lumpsum_vs_dca) rufen simulation() vielfach
#' mit derselben Strategie bzw. denselben Daten auf. Zwischen .sim_study() und .sim_study_end() merkt sich
#' simulation() Pruefungen und Kalenderangaben, die ohne Meldung durchgingen, je Art mit dem zuletzt gesehenen
#' Schluessel (identical()); Meldungen und Warnungen entstehen weiter je Lauf (ihre Pruefungen werden nie
#' uebersprungen), Fehler brechen vor dem Merken ab. Ausserhalb einer Studie wirkungslos.
#' Eingabe: what (Art: "strategy", "wraps", "columns", "private_sale", "share", "dates", "days"), key, val.
#' Ausgabe: .sim_study() TRUE, wenn die Studie den Cache eroeffnet hat (fuer .sim_study_end); .sim_memo_get()
#' der Eintrag list(key, val) oder NULL.
#' @keywords internal
#' @noRd
.sim_study_env <- new.env(parent = emptyenv())
.sim_study <- function() {
  if (isTRUE(.sim_study_env$on)) return(FALSE)
  .sim_study_env$on <- TRUE; .sim_study_env$m <- list()
  .sim_study_env$prep <- .sim_study_env$seen <- .sim_study_env$never <- list()   # Studienkern (seit 1.6.5)
  TRUE
}
.sim_study_end <- function(own) if (isTRUE(own)) {
  .sim_study_env$on <- FALSE; .sim_study_env$m <- NULL
  .sim_study_env$prep <- .sim_study_env$seen <- .sim_study_env$never <- NULL
}
.sim_memo_get <- function(what, key) {
  if (!isTRUE(.sim_study_env$on)) return(NULL)
  e <- .sim_study_env$m[[what]]
  if (!is.null(e) && identical(e$key, key)) e else NULL
}
.sim_memo_set <- function(what, key, val = TRUE) {
  if (isTRUE(.sim_study_env$on)) .sim_study_env$m[[what]] <- list(key = key, val = val)
  invisible(val)
}
# Wert fn() je Schluessel, in einer Studie einmal (Fehler von fn brechen wie bisher ab, ohne zu merken)
.sim_memo_val <- function(what, key, fn) {
  e <- .sim_memo_get(what, key)
  if (!is.null(e)) return(e$val)
  .sim_memo_set(what, key, fn())
}
# Wert fn() je Schluessel, in einer Studie einmal, aber nur gemerkt, wenn fn() ohne Meldung und Warnung blieb (seit
# 1.6.3; Meldungen entstehen so weiter je Lauf, sie erreichen den Aufrufer unveraendert)
.sim_memo_quiet <- function(what, key, fn) {
  if (!isTRUE(.sim_study_env$on)) return(fn())
  e <- .sim_memo_get(what, key)
  if (!is.null(e)) return(e$val)
  quiet <- TRUE
  val <- withCallingHandlers(fn(), message = function(m) quiet <<- FALSE, warning = function(w) quiet <<- FALSE)
  if (quiet) .sim_memo_set(what, key, val)
  val
}
# Kalendertage start..stopp (seq.Date), in einer Studie einmal je Zeitraum
.sim_days <- function(start_date, stopp_date) {
  k <- c(start_date, stopp_date)
  e <- .sim_memo_get("days", k)
  if (!is.null(e)) return(e$val)
  .sim_memo_set("days", k, seq.Date(from = as.Date(start_date), to = as.Date(stopp_date), by = "days"))
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
    warning(chk_msg("e.prozent_spalte", arg, col, format(m), format(m), format(m * 100)), call. = FALSE)
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

#' Felder eines Assets der Strategie pruefen (seit 1.6.4)
#'
#' Zweck: Listen-Assets (ohne asset_config()) gehen durch dieselben Regeln wie asset_config(): share in (0, 1],
#' spread >= 0 und endlich, partial_exemption in [0, 100], deliverable TRUE/FALSE, start als Datum, Signalspalten
#' als Name (bis 1.6.3 liefen negative Spreads, Teilfreistellung ueber 100 % oder start = NA still durch; FW1-1).
#' Meldungen aus der Tabelle eingabe mit "simulation: Asset '<name>'" als Funktion.
#' @keywords internal
#' @noRd
.sim_check_asset_fields <- function(a, nm) {
  w <- sprintf("simulation: Asset '%s'", nm)
  if (is.null(a[["share"]])) chk_stop("fehlt", w, "share")
  s <- a[["share"]]   # bei 1 < share <= 100 wertfreier Hinweis (Entscheidung 12; seit 1.6.4, K43 KE)
  if (is.numeric(s) && length(s) == 1L && is.finite(s) && s > 1 && s <= 100)
    chk_stop("ke.zahl_bereich_prozent", w, "share", chk_range_text(0, 1, lo_open = TRUE))
  chk_num1(a[["share"]], w, "share", lo = 0, hi = 1, lo_open = TRUE)
  chk_num1(a[["spread"]], w, "spread", lo = 0, null_ok = TRUE)
  chk_num1(a[["partial_exemption"]], w, "partial_exemption", lo = 0, hi = 100, null_ok = TRUE)
  if (!is.null(a[["deliverable"]])) chk_bool1(a[["deliverable"]], w, "deliverable")   # Feld fehlt: Standard FALSE
  st <- a[["start"]]
  if (!is.null(st)) {
    d <- if (length(st) == 1L && (inherits(st, c("Date", "POSIXt")) || is.character(st)))
           tryCatch(as.Date(st), error = function(e) NA) else NA
    if (length(d) != 1L || !is.finite(unclass(d))) chk_stop("datum", w, "start")
  }
  chk_name1(a[["signal_buy"]], w, "signal_buy", null_ok = TRUE)
  chk_name1(a[["signal_sell"]], w, "signal_sell", null_ok = TRUE)
  invisible(NULL)
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
.sim_check_inputs <- function(data, strategy, start_value, details, dca_mode, dca_value, dca_days,
                              balance_mode, balance_days, balance_thresh,
                              balance_thresh_type = c("absolute", "relative"),
                              tax_mode = c("none", "person"), tax_rate, marginal_tax_rate,
                              use_guenstigerpruefung, private_sale_threshold, sparer_pauschbetrag,
                              use_sparer_pauschbetrag, include_soli_on_income_tax, soli_rate_income_tax,
                              base_rate, fractions, risk_free, split_mode, split_thresh,
                              event_col, church_tax, order_fee, dca_fee, harvest_mode,
                              taxable_income, tariff, liquidate = FALSE) {
    # === PARAMETER-VALIDIERUNG ===
  tax_mode <- match.arg(tax_mode)
  
  # Pflichtparameter
  # seit 1.6.4 ohne Eingabewert bzw. Klasse; die Meldung zu data nennt die Tabellenform je Sprache und die Umwandlung
  if (missing(data) || !is.data.frame(data)) {
    stop(chk_msg("a.m_sim_check_inputs", chk_msg("tabelle.formen")))
  }
  if (missing(strategy) || length(strategy) == 0) {
    stop(chk_msg("a.m_sim_check_inputs_2"))
  }

  # --- Eingabepruefung der Daten ---
  filled_attr <- attr(data, "filled")                 # series_align(): gefuellte Werte (Matrix)
  if (!identical(class(data), "data.frame")) data <- as.data.frame(data, stringsAsFactors = FALSE)  # z. B. tibble
  if (is.null(names(strategy)) || any(is.na(names(strategy)) | names(strategy) == ""))   # seit 1.6.4 auch NA
    stop(chk_msg("a.m_sim_check_inputs_3"))
  if (anyDuplicated(names(strategy)))
    stop(chk_msg("a.m_sim_check_inputs_4", names(strategy)[anyDuplicated(names(strategy))]))
  if (anyDuplicated(names(data)))   # R2: sonst wuerde still die erste gleichnamige Spalte verwendet
    stop(chk_msg("a.m_sim_check_inputs_5", names(data)[anyDuplicated(names(data))]))
  # seit 1.6.4: .filled ist der interne Name der aufgefuellten Tage (bis 1.6.3 schaltete eine solche Spalte den
  # Handel still ab)
  if (".filled" %in% names(data)) chk_stop("spalte_intern", "simulation", ".filled")
  # C7-01: Listen-Strategien (ohne create_strategy()/asset_config()) wie asset_config() pruefen; ein
  # ungueltiges Steuerregime (z. B. "none") fuehrte sonst still zu einer Rechnung ohne Steuern.
  # In einer Studie (seit 1.5.1, .sim_study) nur einmal je Strategie: die Pruefung meldet nur Fehler
  strat_ok <- !is.null(.sim_memo_get("strategy", strategy))
  if (!strat_ok) for (nm in names(strategy)) {
    a <- strategy[[nm]]
    if (!is.list(a))
      chk_stop("a.m_sim_check_inputs_6", nm)
    if (!inherits(a, "asset_config")) .asset_list_fields(a, nm, "simulation")   # seit 1.6.4 (K43 T1-N1, Entscheidung 11)
    cls_ok <- c("etf", "etn", "etc", "certificate", "etn_standard", "etn_deliverable")
    if (!is.character(a$asset_class) || length(a$asset_class) != 1L || !a$asset_class %in% cls_ok)
      chk_stop("a.m_sim_check_inputs_7", nm, paste(cls_ok[1:4], collapse = ", "))
    if (!is.null(a$tax_regime) && (!is.character(a$tax_regime) || length(a$tax_regime) != 1L ||
                                   !a$tax_regime %in% c("investment_fund", "capital_gains", "private_sale")))
      chk_stop("a.m_sim_check_inputs_8", nm, "tax = NULL")
    if (!is.character(a$trading) || length(a$trading) != 1L || !a$trading %in% c("bnh", "signal"))
      chk_stop("a.m_sim_check_inputs_9", nm)
    if (!is.null(a[["wrapper"]])) {   # Fonds-Wrapper (wrapper.R)
      if (!inherits(a[["wrapper"]], "SimLevWrapperConfig"))
        chk_stop("a.m_sim_check_inputs_10", nm)
      if (a$trading != "bnh")
        chk_stop("a.m_sim_check_inputs_11", nm)
    }
    .sim_check_asset_fields(a, nm)
  }
  if (!strat_ok) .sim_memo_set("strategy", strategy)
  if (!"date" %in% names(data)) chk_stop("a.date_fehlt", "simulation")   # seit 1.6.5 (FB-4) mit Hinweis
  # Fonds-Wrapper: Asset-Name ist keine Kursspalte; gebraucht werden die inneren Spalten (.strategy_columns)
  wraps <- .sim_memo_val("wraps", strategy, function() .strategy_wrappers(strategy))
  if (length(coll <- intersect(wraps, names(data))))
    chk_stop("a.m_sim_check_inputs_12", coll[1])
  miss <- setdiff(.sim_memo_val("columns", strategy, function() .strategy_columns(strategy)), names(data))
  if (length(miss))
    stop(chk_msg("a.m_sim_check_inputs_13", if (length(miss) == 1L) "Kursspalte" else "Kursspalten", paste(paste0("'", miss, "'", collapse = ", "),
                 if (length(miss) == 1L) "fehlt" else "fehlen"), paste(setdiff(names(data), "date"), collapse = ", ")))
  if (nrow(data) < 1L) stop(chk_msg("a.m_sim_check_inputs_14"))
  # seit 1.6.4 kein Faktor als Datumsspalte (Entscheidung 15; bis 1.6.3 still in Text umgewandelt)
  chk_col_nofactor(data, "date", "simulation")
  if (is.character(data$date)) {
    dd <- as.Date(data$date, format = "%Y-%m-%d")
    bad <- which(is.na(dd) & !is.na(data$date))
    if (length(bad)) stop(sprintf("simulation: Spalte 'date' ist Text und Zeile %d ist kein Datum im Format JJJJ-MM-TT; vorher mit as.Date(..., format = ...) umwandeln.",
                                  bad[1]))   # seit 1.6.4 ohne den Text der Zelle
    data$date <- dd
    message("Hinweis: Spalte 'date' wurde von Text in Date umgewandelt.")
  } else if (inherits(data$date, "POSIXt")) {
    data$date <- as.Date(format(data$date, "%Y-%m-%d"))
    message("Hinweis: Spalte 'date' wurde von Datum-Uhrzeit in Date umgewandelt.")
  }
  if (!inherits(data$date, "Date"))
    stop(chk_msg("a.m_sim_check_inputs_15"))
  # In einer Studie (seit 1.5.1) nur einmal je Datumsspalte, wenn sie ohne Meldung durchging (kein NA, sortiert,
  # eindeutig); sonst je Lauf wie bisher mit Meldung bzw. Fehler
  dates_ok <- !is.null(.sim_memo_get("dates", data$date))
  if (!dates_ok && anyNA(data$date)) stop(sprintf("simulation: Spalte 'date' enth\u00e4lt NA (erstmals in Zeile %d).", which(is.na(data$date))[1]))
  if (!dates_ok && is.unsorted(data$date)) {
    o <- order(data$date)
    data <- data[o, , drop = FALSE]; rownames(data) <- NULL
    if (is.matrix(filled_attr) && nrow(filled_attr) == length(o)) filled_attr <- filled_attr[o, , drop = FALSE]
    message("Hinweis: 'data' war nicht aufsteigend nach Datum sortiert und wurde sortiert.")
  }
  if (!dates_ok && anyDuplicated(data$date))
    stop(sprintf("simulation: Datum %s kommt in 'data' mehrfach vor (%d doppelte Zeilen); je Tag genau eine Zeile.",
                 format(data$date[anyDuplicated(data$date)]), sum(duplicated(data$date))))
  if (!dates_ok) .sim_memo_set("dates", data$date)
  # Fonds-Wrapper: Anteilswert je Wrapper-Asset aus den inneren Spalten (wrapper.R) als Kursspalte mit dem
  # Asset-Namen anhaengen (NA vor dem Beginn und an Tagen ohne inneren Kurs); danach ist das Asset ein
  # gewoehnliches asset_config ohne wrapper. splits gelten fuer die inneren Spalten, nicht fuer den Anteilswert.
  wrapper_navs <- NULL
  if (length(wraps)) {
    d_in <- data
    if (is.matrix(filled_attr) && nrow(filled_attr) == nrow(data)) attr(d_in, "filled") <- filled_attr
    sp <- if (isTRUE(split_mode) && !is.null(split_thresh)) structure(list(thresh = unlist(split_thresh)), class = "SimLevSplitRule")
    # In einer Studie (seit 1.6.3) einmal je Daten, Wrapper und Splits, wenn die innere Rechnung ohne Meldung blieb
    # (sensitivity_*, param_search: gleiche Daten je Lauf); sonst je Lauf wie bisher
    wrapper_navs <- lapply(stats::setNames(wraps, wraps), function(nm)
      .sim_memo_quiet(paste0("wrapper_nav:", nm), list(d_in, strategy[[nm]][["wrapper"]], sp), function()
        .wrapper_nav_calc(d_in, strategy[[nm]][["wrapper"]], sp, tag = sprintf("Wrapper '%s'", nm),
                          who = sprintf("simulation: Wrapper '%s'", nm))))
    for (nm in wraps) {
      v <- rep(NA_real_, nrow(data))
      v[.date_match(wrapper_navs[[nm]]$date, data$date)] <- wrapper_navs[[nm]]$nav   # seit 1.6.3 ueber die Tageszahl
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
  if (all_na[1]) stop(chk_msg("a.m_sim_check_inputs_16"))
  pre_filled <- pre_filled | all_na
  for (nm in names(strategy)) {
    v <- data[[nm]]
    if (!is.numeric(v)) stop(chk_msg("a.m_sim_check_inputs_17", nm))
    # seit 1.6.4 (A-086) Schnellweg ohne NA: Bereich ueber min/max statt der Indexvektoren; nur bei einem Fehler wie
    # bisher ueber which() (gleiche Meldung, gleiche Reihenfolge der Pruefungen)
    if (length(v) && !is.object(v) && !anyNA(v)) {
      lo <- min(v); hi <- max(v)
      if (is.finite(lo) && is.finite(hi) && lo >= 1e-100 && hi <= 1e100) next
    }
    bad <- which(!is.na(v) & !(is.finite(v) & v > 0))
    if (length(bad)) stop(chk_msg("a.m_sim_check_inputs_18", nm, format(data$date[bad[1]])))
    # seit 1.6.4 (A-005, Entscheidung 103): Kurse von 1e-100 bis 1e100 (sonst laeuft die Stueckzahl Geld / Kurs ueber)
    bad <- which(!is.na(v) & (v < 1e-100 | v > 1e100))
    if (length(bad)) chk_stop("fa.kurs_bereich", "simulation", nm, format(data$date[bad[1]]))
    ok <- which(!is.na(v))
    if (!length(ok)) stop(chk_msg("a.m_sim_check_inputs_19", nm))
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
      data[[nm]] <- .fill_na(v, "locf")
    }
  }

  # start_value (seit 1.6.4 Laenge 1 und endlich; bis 1.6.3 Rohfehler bei Laenge 0/2, Inf ergab still ein Depot von 0)
  if (is.null(start_value) || (length(start_value) == 1L && is.na(start_value))) {
    start_value <- 10000
    message("Hinweis: start_value ist NULL oder NA; verwendet wird der Standardwert 10000 EUR.")
  }
  if (!is.numeric(start_value) || length(start_value) != 1L || start_value <= 0) {
    stop(chk_msg("a.m_sim_check_inputs_20"))
  }
  if (start_value == Inf) chk_stop("zahl", "simulation", "start_value")
  
  # Steuer-, Kosten-, Termin- und Split-Angaben haben die Bausteine geprueft (tax_profile(), sim_costs(),
  # dca_plan(), rebalance_plan(), split_rule(); die Pruefungen des flachen Wegs sind entfallen).
  # fractions (TRUE/FALSE) und risk_free (Prozent-Konvention) prueft simulation() selbst
  .frac_warn <- function(x, arg, hi = 1) {
    if (is.numeric(x) && length(x) == 1L && is.finite(x) && x > 0 && x < hi)
      warning(chk_msg("e.prozent_anteil", "simulation", arg, format(x), format(x), format(x * 100)), call. = FALSE)
  }
  # seit 1.6.4 liquidate und details wie fractions (bis 1.6.3 je Sprache eigene Wahrheitsregel: R isTRUE, Python
  # bool(), Julia == true)
  for (lg in c("fractions", "liquidate", "details")) {
    v <- switch(lg, fractions = fractions, liquidate = liquidate, details = details)
    if (!is.logical(v) || length(v) != 1L || is.na(v))
      chk_stop("a.m_frac_warn", lg)
  }
  # seit 1.6.4 risk_free: NULL, eine endliche Zahl oder ein Spaltenname mit Zahlen (bis 1.6.3 in R Vektoren je Tag
  # reihum, Faktoren als Codes; in Python/Julia Rohfehler)
  if (!is.null(risk_free)) {
    if (!((is.numeric(risk_free) && length(risk_free) == 1L && is.finite(risk_free)) ||
          (is.character(risk_free) && length(risk_free) == 1L && !is.na(risk_free) && nzchar(risk_free))))
      chk_stop("zahl_oder_spalte", "simulation", "risk_free")
    # Spalte: nur Zahlen (Entscheidung 2; bis 1.6.3 Text und Wahrheitswerte ueber as.numeric, Faktoren als Codes)
    if (is.character(risk_free) && risk_free %in% names(data)) {
      chk_col_type(data, risk_free, "simulation", "numerisch")
      # seit 1.6.5 (MA2-5, Entscheidung 186 M8): keine Luecken und Zinsen > -100 % (bis 1.6.4 je nach Daten LOCF oder
      # still 0, Werte <= -100 fielen still aus Mittel und Streuung)
      chk_col_nona(data, risk_free, "simulation")
      bad <- which(data[[risk_free]] <= -100)
      if (length(bad)) chk_stop("a.rf_spalte", "simulation", risk_free, bad[1])
    }
    if (is.numeric(risk_free) && risk_free <= -100) chk_stop("a.rf_zahl", "simulation")   # seit 1.6.5 (M8)
  }
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
          else chk_stop("a.m_frac_warn_2")
    tariff_env <- new.env(parent = emptyenv())
    tariff_env$tariff <- tt
    tariff_env$zve_all <- zv$all; tariff_env$zve <- zv$by_year
    tariff_env$ks <- stats::setNames(numeric(0), character(0))   # KiSt-Bescheid-Saldo je Zahlungsjahr
    tariff_env$church_k <- if (!is.null(church_tax) && church_tax > 0) church_tax / 100 else 0
    tariff_env$kapest_rate <- 0.25 / (1 + 0.25 * tariff_env$church_k)   # KapESt-Satz nach § 32d Abs. 1 EStG
    tariff_env$use_gp <- isTRUE(use_guenstigerpruefung)
    tariff_env$rows <- NULL   # Jahreszeilen (data.frame), setzt .sim_engine_run
  }

  # marginal_tax_rate (wenn private_sale vorhanden)
  has_private_sale <- .sim_memo_val("private_sale", strategy, function() any(sapply(strategy, function(a) {
    isTRUE(a$tax_regime == "private_sale") || 
    isTRUE(a$asset_class == "etn_deliverable") ||
    (isTRUE(a$asset_class %in% c("etn", "etc")) && isTRUE(a$deliverable))
  })))
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
  fee_order <- .fee_spec(order_fee, "simulation", "order_fee")
  fee_dca <- if (is.null(dca_fee)) fee_order else .fee_spec(dca_fee, "simulation", "dca_fee")
  fees_on <- !is.null(fee_order) || !is.null(fee_dca)
  .fee_env$paid <- 0
  # base_rate: KEINE Division hier; die Tagesengine teilt bei der Vorabpauschale durch 100 (core/engine_core_impl.h)

  # Gewichtssumme validieren
  total_weight <- .sim_memo_val("share", strategy, function() sum(sapply(strategy, function(a) a$share), na.rm = TRUE))
  if (abs(total_weight - 1.0) > 1e-6) {
    # seit 1.6.4 ohne die Eingabewerte (bis 1.6.3 "Aktuelle Gewichte: A=0.300, ..."); die Summe bleibt
    stop(sprintf(
      "simulation: Asset-Gewichte (share) summieren sich auf %.4f, m\u00fcssen aber exakt 1.0 ergeben (Anteile, z. B. 0.6 und 0.4).",
      total_weight))
  }

  # Steuersaetze (Kirchensteuer, Prozent -> Anteil, Guenstigerpruefung) im gemeinsamen Helfer (seit 1.1.0
  # auch fuer withdrawal_simulation()); Rechenfolge, Warnungen und Druck wie bisher an dieser Stelle
  tr <- .tax_rates(tax_rate, church_tax, use_guenstigerpruefung, marginal_tax_rate, include_soli_on_income_tax,
                   soli_rate_income_tax, who = "simulation", details = details, tariff_on = tariff_on)
  tax_rate <- tr$tax_rate; marginal_tax_rate <- tr$marginal_tax_rate; effective_tax_rate <- tr$effective_tax_rate
  soli_factor_income <- tr$soli_factor_income; church_k <- tr$church_k

  list(data = data, strategy = strategy, tax_mode = tax_mode, start_value = start_value,
       marginal_tax_rate = marginal_tax_rate, effective_tax_rate = effective_tax_rate,
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
