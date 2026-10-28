# =============================================================================
# simulation(), Phase 1: Eingabepruefung
# =============================================================================
#
# simulation() (simulation.R) ruft nacheinander interne Phasenfunktionen auf:
#   sim_validate.R  .sim_check_inputs()            Eingabepruefung, Steuer- und Gebuehreneinstellungen
#   sim_prepare.R   .sim_prepare_data()            Kalenderraster, LOCF
#                   .sim_build_state()             Zentralstruktur sim_mem (Feldfolge .SIM_MEM_LAYOUT)
#                   .sim_build_calendar()          Termine und Tages-Flags
#                   .sim_init_weights()            Startgewichte
#                   .sim_build_schedule()          Ereignis- und Verarbeitungstage
#   sim_actions.R   .sim_make_actions()            Zahlungs- und Abrechnungshelfer (Steuern, Gebuehren)
#   sim_loop.R      .sim_run_days()                Tagesschleife mit den Tagesschritten .sim_day_*()
#                   .sim_close_years()             Abschluss des letzten Jahres
#   sim_evaluate.R  .sim_compact_trades(), .sim_returns(), .sim_risk_stats(),
#                   .sim_undefined_metrics(), .sim_result()   Auswertung und Ergebnisobjekt
# Die Phasen geben ihre Ergebnisse als Werte zurueck; Argumente von simulation() werden unausgewertet
# durchgereicht und erst beim ersten Gebrauch ausgewertet (wie vorher in einem Funktionskoerper).

# Namen der Phasenfunktionen: Bedingungen, die direkt in einer Phase entstehen (stop()/warning() ohne
# call. = FALSE, R-Fehler im Phasencode), tragen den Aufruf von simulation() (.sim_restore_call)
.SIM_PHASES <- c(".sim_check_inputs", ".sim_prepare_data", ".sim_build_state", ".sim_check_layout",
                 ".sim_build_calendar", ".sim_init_weights", ".sim_build_schedule", ".sim_make_actions",
                 ".sim_run_days", ".sim_day_activate", ".sim_day_split", ".sim_day_dca", ".sim_day_trade",
                 ".sim_day_rebalance", ".sim_day_harvest", ".sim_day_assess_vp", ".sim_day_liquidate", ".sim_close_years", ".sim_compact_trades", ".sim_returns",
                 ".sim_risk_stats", ".sim_undefined_metrics", ".sim_result")

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

#' Prozent-Konvention fuer Spalten pruefen (R9-06)
#'
#' Zweck: wie die Warnung fuer Skalare (R8-04), aber fuer eine Zinsspalte (risk_free als Spaltenname,
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

#' Phase 1 von simulation(): Eingabepruefung
#'
#' Zweck: Argumente von simulation() pruefen (Fehler und Warnungen wie dokumentiert), Prozentangaben
#' in Anteile umrechnen, Ordergebuehren, Einkommensteuertarif und effektiven Steuersatz
#' (Guenstigerpruefung) bestimmen.
#' Eingabe: die gleichnamigen Argumente von .simulation_flat() (tariff = tax_tariff); given = benannter
#' logischer Vektor, TRUE = Argument im Aufruf angegeben (statt missing() bei Argumenten mit Standardwert);
#' blocks = TRUE: Aufruf aus simulation() mit Bausteinen. Dann haben die Bausteine ihre Argumente schon
#' geprueft (die Pruefungen hier entfallen, Warnungen kommen nicht doppelt), und Meldungen nennen die
#' Bausteine statt der flachen Argumente.
#' Ausgabe: Liste cfg mit data und strategy (geprueft, ggf. sortiert bzw. mit start), den
#' Steuerwerten als Anteil (tax_rate, marginal_tax_rate, effective_tax_rate, soli_factor_income,
#' church_k), tariff_env, den Gebuehren (fee_order, fee_dca, fees_on), pre_filled und den hier
#' ausgewerteten Einstellungen.
#' @keywords internal
#' @noRd
.sim_check_inputs <- function(data, strategy, start_value, spread, details, dca_mode, dca_value, dca_span,
                              dca_days, balance_mode, balance_days, balance_thresh,
                              balance_thresh_type = c("absolute", "relative"),
                              tax_mode = c("none", "person"), tax_rate, marginal_tax_rate,
                              use_guenstigerpruefung, private_sale_threshold, sparer_pauschbetrag,
                              use_sparer_pauschbetrag, include_soli_on_income_tax, soli_rate_income_tax,
                              base_rate, fractions, risk_free, split_mode, split_thresh,
                              event_col, church_tax, order_fee, dca_fee, harvest_mode, harvest_day,
                              taxable_income, tariff, given, blocks = FALSE) {
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
  if (!is.null(spread))   # R1-26: Argument bleibt fuer die Signatur (Python/Julia) erhalten
    warning("simulation: Das Argument 'spread' wird nicht ausgewertet; ma\u00dfgeblich ist spread je Asset (asset_config()).", call. = FALSE)

  # --- Eingabepruefung der Daten (R1-13/14/15/17/22) ---
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
                   .show_arg_s(a$tax_regime), nm, if (blocks) "tax = NULL" else "tax_mode = \"none\""), call. = FALSE)
    if (!is.character(a$trading) || length(a$trading) != 1L || !a$trading %in% c("bnh", "signal"))
      stop(sprintf("simulation: trading %s von Asset '%s' ist ung\u00fcltig; erlaubt sind \"bnh\" und \"signal\".",
                   .show_arg_s(a$trading), nm), call. = FALSE)
    if (!is.null(a[["wrapper"]])) {   # Fonds-Wrapper (Etappe 6.5c, wrapper.R)
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
  # R2-03: Attribut mit anderer Zeilenzahl (z. B. nach Zeilenauswahl) ist nicht zuordenbar (traegt keine Daten)
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
  
  # tax_rate (mit Bausteinen: tax_profile() hat rate und church_tax geprueft)
  if (!blocks) {
  if (!is.numeric(tax_rate) || length(tax_rate) != 1L || is.na(tax_rate) || tax_rate < 0 || tax_rate > 100) {
    stop(sprintf("simulation: tax_rate muss eine einzelne Zahl in Prozent zwischen 0 und 100 sein (z. B. 26.375 f\u00fcr 26,375 %%), nicht %s.",
                 paste(deparse(tax_rate), collapse = "")))
  }
  if (tax_rate > 0 && tax_rate < 1)   # R1-23: vermutlich Anteil statt Prozent
    warning(sprintf("simulation: tax_rate = %s wird als %s %% gelesen (Prozent-Konvention); gemeint war vermutlich %s.",
                    format(tax_rate), format(tax_rate), format(tax_rate * 100)), call. = FALSE)
  if (!is.null(church_tax)) {
    if (!is.numeric(church_tax) || length(church_tax) != 1L || is.na(church_tax) || church_tax < 0 || church_tax > 100)
      stop(sprintf("simulation: church_tax muss eine Zahl in Prozent zwischen 0 und 100 sein (in Deutschland 8 oder 9), nicht %s.",
                   paste(format(church_tax), collapse = ", ")))
    if (church_tax > 0 && church_tax < 1)
      warning(sprintf("simulation: church_tax = %s wird als %s %% gelesen (Prozent-Konvention); gemeint war vermutlich %s.",
                      format(church_tax), format(church_tax), format(church_tax * 100)), call. = FALSE)
    else if (church_tax > 9)
      warning(sprintf("simulation: church_tax = %s %% ist ungew\u00f6hnlich hoch (Kirchensteuer in Deutschland: 8 oder 9 %%).", format(church_tax)), call. = FALSE)
  }
  if (isTRUE(harvest_mode) && tax_mode != "person")
    warning("simulation: harvest_mode wirkt nur mit tax_mode = \"person\" und wird hier ignoriert.", call. = FALSE)
  }
  # A7-10: Steuer- und Schalterargumente pruefen (einzelne endliche Zahl bzw. TRUE/FALSE); sonst kryptische
  # R-Fehler bzw. stille Fehldeutung (z. B. private_sale_threshold = "1000": Textvergleich)
  .show_arg <- function(x) if (is.null(x)) "NULL" else paste(deparse(x), collapse = "")
  .chk_num <- function(x, arg, what, min = 0, null_ok = FALSE) {
    if (is.null(x) && null_ok) return(invisible(NULL))
    if (!is.numeric(x) || length(x) != 1L || !is.finite(x) || (!is.null(min) && x < min))
      stop(sprintf("simulation: '%s' muss %s sein, nicht %s.", arg, what, .show_arg(x)), call. = FALSE)
  }
  .frac_warn <- function(x, arg, hi = 1) {
    if (is.numeric(x) && length(x) == 1L && is.finite(x) && x > 0 && x < hi)
      warning(sprintf("simulation: %s = %s wird als %s %% gelesen (Prozent-Konvention); gemeint war vermutlich %s.",
                      arg, format(x), format(x), format(x * 100)), call. = FALSE)
  }
  if (!blocks) {
  .chk_num(sparer_pauschbetrag, "sparer_pauschbetrag", "eine einzelne endliche Zahl >= 0 (EUR je Jahr, z. B. 1000)")
  .chk_num(private_sale_threshold, "private_sale_threshold", "eine einzelne endliche Zahl >= 0 (Freigrenze in EUR, z. B. 1000)")
  .chk_num(base_rate, "base_rate", "NULL oder eine einzelne endliche Zahl (Basiszins in Prozent, z. B. 2.29; negativ erlaubt)",
           min = NULL, null_ok = TRUE)
  .chk_num(marginal_tax_rate, "marginal_tax_rate", "NULL oder eine einzelne Zahl in Prozent von 0 bis 50 (z. B. 42)", null_ok = TRUE)
  .chk_num(balance_thresh, "balance_thresh", "NULL oder eine einzelne endliche Zahl >= 0 in Prozent (z. B. 5)", null_ok = TRUE)
  for (a in c("use_guenstigerpruefung", "include_soli_on_income_tax", "fractions", "use_sparer_pauschbetrag")) {
    x <- get(a)
    if (!is.logical(x) || length(x) != 1L || is.na(x))
      stop(sprintf("simulation: '%s' muss TRUE oder FALSE sein, nicht %s.", a, .show_arg(x)), call. = FALSE)
  }
  # Anteil statt Prozent (wie bei tax_rate). R8-04: Schwellen so, dass realistische kleine Prozentwerte nicht
  # warnen: base_rate < 0.05 (Basiszinsen 0.52 fuer 2019, 0.07 fuer 2020), risk_free < 0.05 (Geldmarkt
  # 2016-2019 um 0.25 % p. a.; als Anteil gemeinte Zinsen liegen meist bei 0.01-0.05), balance_thresh < 0.2
  # (Band von 0.5 Prozentpunkten ist ueblich; als Anteil gemeinte Baender 0.01-0.15); marginal_tax_rate < 1
  # (Grenzsteuersaetze unter 1 % gibt es nicht, der Eingangssatz ist 14 %)
  .frac_warn(base_rate, "base_rate", hi = 0.05); .frac_warn(marginal_tax_rate, "marginal_tax_rate")
  .frac_warn(balance_thresh, "balance_thresh", hi = 0.2)
  }
  if (blocks && (!is.logical(fractions) || length(fractions) != 1L || is.na(fractions)))
    stop(sprintf("simulation: '%s' muss TRUE oder FALSE sein, nicht %s.", "fractions", .show_arg(fractions)), call. = FALSE)
  .frac_warn(risk_free, "risk_free", hi = 0.05)
  # R9-06: dieselbe Schwelle fuer risk_free als Spaltenname (Median der Spalte; base_rate_data: .sim_prepare_data)
  if (is.character(risk_free) && length(risk_free) == 1L && !is.na(risk_free) && risk_free %in% names(data))
    .frac_warn_col(data[[risk_free]], "risk_free", risk_free, hi = 0.05)
  # C7-04: wirkungslose Argumente nicht still ignorieren (mit Bausteinen: in den Bausteinen geprueft)
  if (!blocks) {
  if (!isTRUE(dca_mode) && !is.null(dca_value))
    warning("simulation: dca_value wirkt nur mit dca_mode = TRUE und wird ignoriert.", call. = FALSE)
  if (!isTRUE(balance_mode) && is.null(event_col) && !is.null(balance_thresh))
    warning("simulation: balance_thresh wirkt nur mit balance_mode = TRUE oder event_col (Rebalancing) und wird ignoriert.", call. = FALSE)
  if (is.null(event_col) && given[["event_mode"]])
    warning("simulation: event_mode wirkt nur zusammen mit event_col und wird ignoriert.", call. = FALSE)
  .check_days <- function(x, arg) {
    if (!is.null(x) && (!is.numeric(x) || anyNA(x) || any(x < 1 | x > 31 | x != round(x))))
      stop(sprintf("simulation: %s muss ganze Zahlen von 1 bis 31 enthalten, nicht %s.", arg, paste(format(x), collapse = ", ")))
  }
  .check_days(dca_days, "dca_days"); .check_days(balance_days, "balance_days")
  for (a in c("dca_days", "balance_days")) {   # doppelte Tage ergeben nur einen Termin
    x <- get(a)
    if (!is.null(x) && anyDuplicated(x)) {
      warning(sprintf("simulation: %s enth\u00e4lt doppelte Tage (%s); jeder Tag ergibt nur einen Termin, verwendet wird %s = %s.",
                      a, paste(format(x), collapse = ", "), a, paste(deparse(unique(x)), collapse = "")), call. = FALSE)
      assign(a, unique(x))
    }
  }
  # R2-02: Splits setzen den Kurs auf 100; liegt 100 nicht zwischen den Schwellen, loest
  # der neue Kurs sofort den naechsten Split aus (taegliche Splits)
  if (isTRUE(split_mode) && !is.null(split_thresh)) {
    st_v <- unlist(split_thresh)
    if (!is.numeric(st_v) || length(st_v) != 2L || anyNA(st_v))
      stop(sprintf("simulation: split_thresh muss ein Zahlenvektor c(untere, obere) der L\u00e4nge 2 sein, nicht %s.",
                   paste(format(st_v), collapse = ", ")))
    if (!(st_v[1] < 100 && 100 < st_v[2]))
      warning(sprintf(paste0("simulation: split_thresh = c(%s, %s) schlie\u00dft den Zielkurs 100 nicht ein (erwartet untere < 100 < obere). ",
                             "Ein Split setzt den Kurs auf 100; liegt 100 au\u00dferhalb der Schwellen, folgt danach an jedem Tag ein weiterer Split ",
                             "(mit fractions = FALSE jeweils mit Spitzenausgleich)."), format(st_v[1]), format(st_v[2])), call. = FALSE)
  }
  }

  # Einkommensteuertarif (taxable_income, tax_tariff): zvE je Kalenderjahr pruefen, Tarif lesen
  tariff_on <- !is.null(taxable_income) && tax_mode == "person"
  if (!is.null(taxable_income) && tax_mode != "person")   # nur ohne Bausteine moeglich (income_tariff() steht in tax_profile())
    warning(sprintf("simulation: taxable_income wirkt nur bei tax_mode = \"person\" (hier \"%s\") und wird ignoriert.", tax_mode), call. = FALSE)
  if (is.null(taxable_income) && !is.null(tariff))
    warning("simulation: tax_tariff wirkt nur zusammen mit taxable_income (zu versteuerndes Einkommen je Jahr) und wird ignoriert.", call. = FALSE)
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
    ign <- c("marginal_tax_rate", "include_soli_on_income_tax", "soli_rate_income_tax")[
      c(given[["marginal_tax_rate"]] && !is.null(marginal_tax_rate), given[["include_soli_on_income_tax"]], given[["soli_rate_income_tax"]])]
    if (length(ign))
      warning(sprintf("simulation: Mit taxable_income gilt der Einkommensteuertarif der Tarifdatei (ESt und Soli); %s wirkt dann nicht.",
                      paste(ign, collapse = ", ")), call. = FALSE)
  }

  # marginal_tax_rate (wenn private_sale vorhanden)
  has_private_sale <- any(sapply(strategy, function(a) {
    isTRUE(a$tax_regime == "private_sale") || 
    isTRUE(a$asset_class == "etn_deliverable") ||
    (isTRUE(a$asset_class %in% c("etn", "etc")) && isTRUE(a$deliverable))
  }))
  if (has_private_sale && is.null(marginal_tax_rate) && tax_mode == "person" && !tariff_on) {   # R2-07: nur wenn § 23 besteuert wird
    if (blocks)
      warning("simulation: Der Grenzsteuersatz ist nicht gesetzt (tax_profile(income = income_rate(marginal_rate))), die Strategie enth\u00e4lt aber Assets mit tax_regime = \"private_sale\"; ",
              "Gewinne nach Paragraf 23 EStG werden dann m\u00f6glicherweise nicht korrekt besteuert. income_rate(marginal_rate) in Prozent angeben (z. B. 42).")
    else
    warning("simulation: marginal_tax_rate ist nicht gesetzt, die Strategie enth\u00e4lt aber Assets mit tax_regime = \"private_sale\"; ",
            "Gewinne nach Paragraf 23 EStG werden dann m\u00f6glicherweise nicht korrekt besteuert. marginal_tax_rate in Prozent angeben (z. B. 42).")
  }
  if (!blocks && !is.null(marginal_tax_rate) && (marginal_tax_rate < 0 || marginal_tax_rate > 50)) {
    stop(sprintf("simulation: marginal_tax_rate muss ein Grenzsteuersatz in Prozent zwischen 0 und 50 sein (z. B. 42 f\u00fcr 42 %%), nicht %s.",
                 paste(deparse(marginal_tax_rate), collapse = "")))
  }

  # Kirchensteuer (§ 32d Abs. 1 EStG): ESt = 25 % / (1 + 0,25 k), dazu Soli 5,5 % und KiSt k
  if (!is.null(church_tax) && church_tax > 0) {
    if (given[["tax_rate"]] && abs(tax_rate - 26.375) > 1e-9)
      warning("church_tax \u00fcberschreibt das angegebene tax_rate.")
    k <- church_tax / 100
    tax_rate <- 100 * 0.25 / (1 + 0.25 * k) * (1 + 0.055 + k)
  }
  # R3a-06: Kirchensteuer auf die Einkommensteuer (§ 23 mit marginal_tax_rate, persoenlicher Satz der
  # Guenstigerpruefung): church_tax Prozent der ESt; der Sonderausgabenabzug der KiSt (§ 10 Abs. 1
  # Nr. 4 EStG) wird bei der ESt nicht abgebildet. Die Abgeltungsteuer-Formel oben bleibt unveraendert.
  church_k <- if (!is.null(church_tax) && church_tax > 0) church_tax / 100 else 0
  # PROZENT-KONVENTION: prozentuale Nutzerangaben -> intern dezimal (/100)
  tax_rate <- tax_rate / 100
  if (!is.null(marginal_tax_rate)) marginal_tax_rate <- marginal_tax_rate / 100
  soli_rate_income_tax <- soli_rate_income_tax / 100
  if (!is.null(balance_thresh)) balance_thresh <- balance_thresh / 100  # Prozent
  # Toleranzband: "absolute" = Prozentpunkte des Gewichts (Standard, wie bisher),
  # "relative" = Prozent des Zielgewichts (z. B. 25 -> Ziel 40 % darf 30-50 % sein)
  balance_thresh_type <- match.arg(balance_thresh_type)
  # Ordergebuehren: ueber eine Paket-Umgebung an perform_trade_buy/sell (ohne Aufrufaenderungen)
  fee_order <- .fee_spec(order_fee); fee_dca <- if (is.null(dca_fee)) fee_order else .fee_spec(dca_fee)
  fees_on <- !is.null(fee_order) || !is.null(fee_dca)
  .fee_env$current <- NULL; .fee_env$paid <- 0
  # (simulation() setzt .fee_env$current beim Verlassen zurueck, wenn fees_on)
  if (isTRUE(harvest_mode) && !blocks) {
    if (!grepl("^\\d{2}-\\d{2}$", harvest_day) || harvest_day >= "12-31")
      stop("harvest_day im Format 'MM-TT' und vor dem 31.12. angeben (z. B. '12-15').")
  }
  # base_rate: KEINE Division hier — .calculate_flat_rate teilt an der Verbrauchsstelle /100
  
  # DCA-Parameter
  # R4-07: einzelne endliche Zahlen pruefen (sonst kryptische R-Fehler bei Vektor, NA oder Text)
  if (dca_mode && !blocks) {
    .one_num <- function(x) is.numeric(x) && length(x) == 1L && is.finite(x)
    .show <- function(x) if (is.null(x)) "NULL" else paste(deparse(x), collapse = "")
    if (!.one_num(dca_value) || dca_value <= 0)
      stop(sprintf("simulation: 'dca_value' muss bei dca_mode = TRUE eine einzelne endliche Zahl > 0 sein (Betrag je Sparplan-Termin in EUR), nicht %s.",
                   .show(dca_value)), call. = FALSE)
    if (!.one_num(dca_span) || dca_span < 1 || dca_span != round(dca_span))
      stop(sprintf("simulation: 'dca_span' muss bei dca_mode = TRUE eine einzelne ganze Zahl >= 1 sein (Perioden zwischen zwei Terminen), nicht %s.",
                   .show(dca_span)), call. = FALSE)
  }

  # Gewichtssumme validieren
  total_weight <- sum(sapply(strategy, function(a) a$share), na.rm = TRUE)
  if (abs(total_weight - 1.0) > 1e-6) {
    stop(sprintf(
      "simulation: Asset-Gewichte (share) summieren sich auf %.4f, m\u00fcssen aber exakt 1.0 ergeben (Anteile, z. B. 0.6 und 0.4).\n  Aktuelle Gewichte: %s",
      total_weight,
      paste(sprintf("%s=%.3f", names(strategy), sapply(strategy, function(a) a$share)), collapse = ", ")
    ))
  }

  # ══════════════════════════════════════════════════════════════════════════
  # I3: GÜNSTIGERPRÜFUNG - Effektiven Steuersatz berechnen
  # ══════════════════════════════════════════════════════════════════════════
  # 
  # Die Günstigerprüfung (§ 32d Abs. 6 EStG) erlaubt es Steuerpflichtigen mit
  # niedrigem Einkommen, ihre Kapitalerträge zum persönlichen Steuersatz zu
  # versteuern statt zur Abgeltungsteuer (25%).
  #
  # Voraussetzung (R4-01): Die Belastung mit dem persoenlichen Satz einschliesslich Soli und KiSt
  # muss niedriger sein als die Abgeltungsteuer einschliesslich Zuschlagsteuern.
  # 
  # Berechnung des effektiven Steuersatzes:
  # - Bei Günstigerprüfung: marginal_tax_rate * (1 + Soli-Satz + KiSt-Satz), wenn kleiner als tax_rate (R4-01)
  # - Ohne Günstigerprüfung: tax_rate / 100, Standard 0.26375 (25% + 5.5% Soli)
  # ══════════════════════════════════════════════════════════════════════════

  effective_tax_rate <- tax_rate  # Default: 26.375%

  # Tarifweg: unterjaehrig Abgeltungsteuer wie bei einer Bank (auch in der Verkaufsschaetzung),
  # Guenstigerpruefung im Jahresabschluss (.handle_year_change -> .tariff_close)
  if (use_guenstigerpruefung && !tariff_on) {
    if (is.null(marginal_tax_rate)) {
      if (blocks)
      warning(
        "simulation: G\u00fcnstigerpr\u00fcfung aktiviert (tax_profile(guenstigerpruefung = TRUE)), aber der Grenzsteuersatz (income_rate(marginal_rate)) ist nicht gesetzt.\n",
        "Verwendet wird die Abgeltungsteuer (", round(tax_rate * 100, 2), " %).\n",
        "F\u00fcr eine korrekte G\u00fcnstigerpr\u00fcfung tax_profile(income = income_rate(marginal_rate)) in Prozent angeben (z. B. 42).",
        call. = FALSE
      )
      else
      warning(
        "simulation: G\u00fcnstigerpr\u00fcfung aktiviert (use_guenstigerpruefung = TRUE), aber 'marginal_tax_rate' ist nicht gesetzt.\n",
        "Verwendet wird die Abgeltungsteuer (", round(tax_rate * 100, 2), " %).\n",
        "F\u00fcr eine korrekte G\u00fcnstigerpr\u00fcfung marginal_tax_rate in Prozent angeben (z. B. 42).",
        call. = FALSE
      )
    } else if ((personal_rate <- marginal_tax_rate *
                ((if (include_soli_on_income_tax) (1 + soli_rate_income_tax) else 1.0) + church_k)) < tax_rate) {
      # R4-01: § 32d Abs. 6 Satz 1 EStG: Tarif nur, wenn die Einkommensteuer EINSCHLIESSLICH
      # Zuschlagsteuern niedriger ist -> Gesamtbelastung persoenlicher Satz x (1 + Soli + KiSt)
      # gegen den effektiven Abgeltungsteuersatz (tax_rate, bei church_tax nach § 32d Abs. 1)
      effective_tax_rate <- personal_rate   # ESt + Soli + KiSt (R3a-06)
      
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

  # F4: Soli-Faktor für ESt-Berechnungen (§ 23, Günstigerprüfung)
  soli_factor_income <- if (include_soli_on_income_tax) (1 + soli_rate_income_tax) else 1.0

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
