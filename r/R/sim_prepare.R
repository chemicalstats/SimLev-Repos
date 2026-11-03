# =============================================================================
# simulation(), Phase 2: Datenvorbereitung, Zentralstruktur sim_mem, Termine und Flags
# =============================================================================

# C7-11: Feldfolge der obersten Ebene von sim_mem. Bis E17 Stufe 1c lasen die Engine-Kerne
# (simulation_core.cpp, fifo_core.cpp) diese Ebene ueber die Position; seit der Tagesengine im Kern
# (sim_engine.R) liest .sim_engine_run die Felder ueber Namen. Die Reihenfolge wird weiter hier
# festgelegt und geprueft (Aufbau des Ergebnisses).
.SIM_MEM_LAYOUT <- c("assets", "status", "market", "trades", "report", "totals")

#' Feldfolge von sim_mem pruefen (C7-11)
#'
#' Zweck: sicherstellen, dass die oberste Ebene von sim_mem genau die Felder aus .SIM_MEM_LAYOUT in
#' dieser Reihenfolge hat, bevor C++-Funktionen ueber die Position darauf zugreifen.
#' Eingabe: sim_mem (Liste).
#' Ausgabe: sim_mem unsichtbar; sonst Fehler (interner Fehler, keine Fehlbedienung).
#' @keywords internal
#' @noRd
.sim_check_layout <- function(sim_mem) {
  if (!is.list(sim_mem) || !identical(names(sim_mem), .SIM_MEM_LAYOUT))
    stop(sprintf(paste0("simulation: interner Fehler: sim_mem hat die Felder (%s), die C++-Kerne erwarten ",
                        "genau (%s) in dieser Reihenfolge (Zugriff \u00fcber die Position)."),
                 paste(names(sim_mem), collapse = ", "), paste(.SIM_MEM_LAYOUT, collapse = ", ")),
         call. = FALSE)
  invisible(sim_mem)
}

#' Phase 2a von simulation(): Daten auf das Kalenderraster bringen
#'
#' Zweck: Start- und Enddatum bestimmen, NA im Basiszins durch 0 ersetzen, fehlende Kalendertage
#' auffuellen (LOCF, Signale FALSE) und aufgefuellte Tage in der Spalte .filled markieren.
#' Eingabe: data (aus .sim_check_inputs), pre_filled (Tage ohne echten Kurs), base_rate_flex,
#' base_rate_data (Argumente von .simulation_flat(); Meldungen nennen tax_profile(base_rate)).
#' Ausgabe: list(data, start_date, stopp_date).
#' @keywords internal
#' @noRd
.sim_prepare_data <- function(data, pre_filled, base_rate_flex, base_rate_data) {
  #----------------------------> Vorbereitung und Strukturierung von Datenobjekten:
  start_date <- head(data[, "date"], 1)
  stopp_date <- tail(data[, "date"], 1)
  
  # R9-06: Prozent-Konvention auch fuer die Basiszins-Spalte (Median, gleiche Schwelle wie base_rate)
  if (isTRUE(base_rate_flex) && is.character(base_rate_data) && length(base_rate_data) == 1L &&
      !is.na(base_rate_data) && base_rate_data %in% names(data))
    .frac_warn_col(data[[base_rate_data]], "base_rate", base_rate_data, hi = 0.05)
  # R3a-07: NA in der Basiszins-Spalte = 0 (keine VP), unabhaengig von der Datenform: vor dem
  # LOCF-Auffuellen ersetzen (sonst fuellte LOCF ein NA an Handelstagsdaten mit dem Vortageswert)
  if (isTRUE(base_rate_flex) && is.character(base_rate_data) && length(base_rate_data) == 1L &&
      base_rate_data %in% names(data) && anyNA(data[[base_rate_data]]) &&
      (is.numeric(data[[base_rate_data]]) || all(is.na(data[[base_rate_data]])))) {
    br0 <- as.numeric(data[[base_rate_data]]); br0[is.na(br0)] <- 0; data[[base_rate_data]] <- br0
  }

  # P-3: Lueckenhafte Handelstag-Daten automatisch auf Kalenderraster auffuellen
  # (LOCF fuer numerische Spalten; logische Signal-Spalten -> FALSE).
  expected_days <- as.numeric(difftime(stopp_date, start_date, units = "days")) + 1
  if (nrow(data) != expected_days) {
    message(sprintf(
      "Hinweis: %d Zeilen, erwartet %d Kalendertage. Fehlende Tage werden aufgef\u00fcllt (LOCF; Signale = FALSE).",
      nrow(data), expected_days))
    .locf_fill <- function(v) {
      non_na <- which(!is.na(v))
      if (length(non_na) == 0L) return(v)
      idx <- integer(length(v)); idx[non_na] <- non_na
      idx <- cummax(idx)
      idx[idx == 0L] <- non_na[1]          # fuehrende NAs rueckwaerts fuellen
      v[idx]
    }
    all_dates <- seq.Date(as.Date(start_date), as.Date(stopp_date), by = "day")
    data$.filled <- pre_filled      # R1-17: Tage ohne echten Kurs (align_series/NA) bleiben markiert
    data <- merge(data.frame(date = all_dates), data, by = "date", all.x = TRUE)
    data$.filled[is.na(data$.filled)] <- TRUE   # A-2: aufgefuellte Tage markieren
    num_cols <- setdiff(names(data)[vapply(data, is.numeric, logical(1))], "date")
    for (cc in num_cols) data[[cc]] <- .locf_fill(data[[cc]])
    lgl_cols <- names(data)[vapply(data, is.logical, logical(1))]
    for (cc in lgl_cols) data[[cc]][is.na(data[[cc]])] <- FALSE
  } else if (any(pre_filled)) {
    data$.filled <- pre_filled      # R1-17: aufgefuellte Tage aus series_align() wie eigene behandeln
  }

  list(data = data, start_date = start_date, stopp_date = stopp_date)
}

#' Phase 2b von simulation(): Zentralstruktur sim_mem anlegen
#'
#' Zweck: sim_mem mit den Feldern aus .SIM_MEM_LAYOUT (assets, status, market, trades, report,
#' totals) je Asset vorbelegen (status und report setzt seit E17 Stufe 2 der Kern: Startgewichte und
#' Anfangszustand in core/prepare_core_impl.h); prueft die Signal- und Basiszinsspalten.
#' Eingabe: data und strategy (vorbereitet), start_value, start_date, stopp_date, sparer_pauschbetrag,
#' use_sparer_pauschbetrag, base_rate, base_rate_flex, base_rate_data (Meldungen nennen die Bausteine).
#' Ausgabe: sim_mem.
#' @keywords internal
#' @noRd
.sim_build_state <- function(data, strategy, start_value, start_date, stopp_date, sparer_pauschbetrag,
                             use_sparer_pauschbetrag, base_rate, base_rate_flex, base_rate_data) {
  #--------> Initialisierung der Speicher-Objekte:
  sim_mem <- list(
    assets = setNames(vector("list", length = length(strategy)), names(strategy)),
    status = setNames(vector("list", length = length(strategy)), names(strategy)),
    market = setNames(vector("list", length = length(strategy)), names(strategy)),
    trades = setNames(vector("list", length = length(strategy)), names(strategy)),
    report = setNames(vector("list", length = length(strategy)), names(strategy)),
    # === NEU: Erweiterte Totals-Struktur ===
    totals = list(
      total_taxes = 0,
      # § 20 EStG Verlusttopf (ETF, ETN standard, Zertifikate)
      loss_capital_gains = 0,
      # § 23 EStG Verlusttopf (ETN deliverable < 1 Jahr, Verlustvortrag)
      loss_private_sales = 0,
      # § 23 Jahres-Tracker
      private_sale_gains_ytd = 0,
      private_sale_losses_ytd = 0,
      # Sparerpauschbetrag
      sparer_pauschbetrag_annual = sparer_pauschbetrag,
      sparer_pauschbetrag_remaining = if (use_sparer_pauschbetrag) sparer_pauschbetrag else 0,
      sparer_pauschbetrag_used_total = 0,
      # Jahr-Tracking
      current_year = as.integer(format(start_date, "%Y")),
      # T-2: § 20 unterjaehrige Verlustverrechnungs-Tracker
      cgt_base_taxed_ytd = 0,
      cgt_loss_added_ytd = 0,
      cgt_loss_used_ytd = 0,
      cgt_pool_start_ytd = 0   # § 20-Verlusttopf zu Jahresbeginn (Vortrag aus dem Vorjahr)
    )
    # === Ende neu ===
  )

  for(name in names(strategy)){
    #---> Initialisierung des Assets-Objekts:
    sim_mem[["assets"]][[name]] <- list(
      class = strategy[[name]][["asset_class"]],
      style = strategy[[name]][["trading"]],
      start = as.Date(strategy[[name]][["start"]] %||% start_date),
      tax_regime = strategy[[name]][["tax_regime"]] %||% switch(strategy[[name]][["asset_class"]],
        "etf" = "investment_fund",
        "etn" = if (isTRUE(strategy[[name]][["deliverable"]])) "private_sale" else "capital_gains",
        "etc" = if (isTRUE(strategy[[name]][["deliverable"]])) "private_sale" else "capital_gains",
        "certificate" = "capital_gains",
        "etn_standard" = "capital_gains",
        "etn_deliverable" = "private_sale",
        "capital_gains"),
      bonus = (strategy[[name]][["partial_exemption"]] %||% 0) / 100,   # PROZENT-KONVENTION
      deliverable = strategy[[name]][["deliverable"]] %||% FALSE
    )

    # P-2: Signal-Spalten validieren (nur fuer trading = "signal")
    if (identical(strategy[[name]][["trading"]], "signal")) {
      sb <- strategy[[name]][["signal_buy"]]
      ss <- strategy[[name]][["signal_sell"]]
      if (is.null(sb) || !sb %in% names(data))
        stop(sprintf("simulation: signal_buy-Spalte '%s' fehlt im Datensatz (Asset '%s').", sb %||% "NULL", name))
      if (is.null(ss) || !ss %in% names(data))
        stop(sprintf("simulation: signal_sell-Spalte '%s' fehlt im Datensatz (Asset '%s').", ss %||% "NULL", name))
    }

    #---> Initialisierung des Market-Objekts:
    sim_mem[["market"]][[name]] <- list(
      asset_day = seq.Date(
        from = as.Date(start_date),
        to = as.Date(stopp_date),
        by = "days"),
      base_rates = if (base_rate_flex) {
  if (is.null(base_rate_data) || !base_rate_data %in% names(data)) {
    stop(if (is.null(base_rate_data)) "simulation: base_rate_flex = TRUE braucht base_rate_data (Name der Basiszins-Spalte in data, Prozent p. a.); base_rate_data fehlt."
         else sprintf("simulation: base_rate-Spalte '%s' fehlt in data (tax_profile(base_rate = \"%s\") braucht eine Basiszins-Spalte in Prozent p. a.; vorhanden: %s).",
                      paste(base_rate_data, collapse = ", "), paste(base_rate_data, collapse = ", "), paste(names(data), collapse = ", ")))
  }
  br <- data[[base_rate_data]]
  br[is.na(br)] <- 0  # NA durch 0 ersetzen
  br
} else {
  # BUG-1 FIX: Vektor statt Skalar, damit Index-Zugriff in .calculate_flat_rate() funktioniert
  rep(base_rate %||% 0, nrow(data))
},
      asset_price = data[[name]],
      signal_buy = if (is.null(strategy[[name]][["signal_buy"]])) rep(FALSE, nrow(data)) else data[[strategy[[name]][["signal_buy"]]]],
      signal_sell = if (is.null(strategy[[name]][["signal_sell"]])) rep(FALSE, nrow(data)) else data[[strategy[[name]][["signal_sell"]]]],
      spread_rate = (strategy[[name]][["spread"]] %||% 0) / 100   # PROZENT-KONVENTION
    )

    #---> Trade-Objekt (Listen setzt die Tagesengine, E17)
    sim_mem[["trades"]][[name]] <- list(buys = list(), sells = list(), taxes = list())
  }

  sim_mem
}

#' Phase 2c von simulation(): Angaben fuer Termine und Tages-Flags
#'
#' Zweck: Kalender (flag_date, aufgefuellte Tage), Angaben der Termine fuer Sparplan und Rebalancing
#' (.sched_spec), Ereignis-Rebalancing (event_col, event_weight); prueft dca_start, balance_start, event_col,
#' event_weight und start sowie, dass ein Asset am ersten Tag handelbar ist. Termine, Splits, das Verschieben
#' von Terminen auf aufgefuellten Tagen, Aktivierung, Freibetrag, Jahreswechsel und Startgewichte rechnet seit
#' E17 Stufe 2 der Kern (core/prepare_core_impl.h, ueber .sim_engine_run); bis dahin .sim_build_calendar,
#' .sim_init_weights und .sim_build_schedule.
#' Eingabe: data, sim_mem, strategy, start_date, stopp_date und die Termin-Argumente von .simulation_flat()
#' (dca_days und balance_days aus .sim_check_inputs); Meldungen nennen die Bausteine.
#' Ausgabe: list(data = data ohne Spalte .filled, flags = list(flag_date, flag_filled, flag_assets, dca, balance
#' (Angaben aus .sched_spec), flag_event (event_col als TRUE/FALSE bzw. NULL), event_replace), event_weight =
#' geprueftes event_weight bzw. NULL ohne event_col).
#' @keywords internal
#' @noRd
.sim_build_calendar <- function(data, sim_mem, strategy, start_date, stopp_date, liquidate,
                                dca_mode, dca_span, dca_unit, dca_days, dca_value, dca_anchor, dca_start,
                                dca_skip, balance_mode, balance_span, balance_unit, balance_days,
                                balance_anchor, balance_start, balance_skip, event_col,
                                event_mode = c("additional", "replace"), event_weight) {
  flag_date <- seq.Date(from = as.Date(start_date), to = as.Date(stopp_date), by = "days")
  # A-2: Markierung aufgefuellter (LOCF) Tage, aligned zu flag_date
  flag_filled <- if (".filled" %in% names(data)) {
    .f <- as.logical(data[[".filled"]]); .f[is.na(.f)] <- TRUE; .f
  } else rep(FALSE, length(flag_date))
  data[[".filled"]] <- NULL
  flag_assets <- names(strategy)
  for (a in c("dca", "balance")) {   # R1-22: Bezugsdatum pruefen (sonst kryptischer seq()-Fehler)
    sd0 <- get(paste0(a, "_start"))
    if (!isTRUE(get(paste0(a, "_mode"))) || is.null(sd0)) next
    sd1 <- tryCatch(as.Date(sd0), error = function(e) NA)
    if (length(sd1) != 1L || is.na(sd1)) stop(sprintf("simulation: %s_start = '%s' ist kein Datum (erwartet Date oder \"JJJJ-MM-TT\").", a, format(sd0)))
    if (sd1 > stopp_date) stop(sprintf("simulation: %s (%s) liegt nach dem letzten Datentag (%s); es g\u00e4be keine Termine.",
                                       sprintf("start von %s", if (a == "dca") "dca_plan()" else "rebalance_plan()"),
                                       format(sd1), format(stopp_date)))
  }
  balance <- .sched_spec(balance_mode, balance_span, balance_unit, balance_days, flag_date, NULL, balance_anchor,
                        balance_start, balance_skip)
  dca <- .sched_spec(dca_mode, dca_span, dca_unit, dca_days, flag_date, dca_value, dca_anchor, dca_start, dca_skip)
  # Ereignisbasiertes Rebalancing aus vorberechneter Spalte (Event-Tage werden im Kern Rebalancing-Tage, mit
  # denselben Schutzregeln wie der Kalender: nicht am Einstiegs- und Liquidationstag)
  event_mode <- match.arg(event_mode)
  flag_event <- NULL
  if (!is.null(event_col)) {
    if (is.null(data[[event_col]]))
      stop(sprintf("simulation: event_col '%s' nicht im Datensatz gefunden.", event_col))
    flag_event <- as.logical(data[[event_col]])
    flag_event[is.na(flag_event)] <- FALSE
    if (!is.null(event_weight)) {   # R1-22/R1-23: Gewichtsspalten pruefen
      if (is.null(names(event_weight)) || any(names(event_weight) == ""))
        stop("simulation: event_weight muss benannt sein (Asset = Spaltenname), z. B. c(A = \"wA\", B = \"wB\").")
      event_weight <- as.list(event_weight)
      unk <- setdiff(names(event_weight), names(strategy))
      if (length(unk)) stop(sprintf("simulation: event_weight nennt unbekannte Assets: %s.", paste(unk, collapse = ", ")))
      for (nm in names(event_weight)) {
        col <- event_weight[[nm]]
        if (!is.character(col) || length(col) != 1L || !col %in% names(data))
          stop(sprintf("simulation: event_weight-Spalte '%s' (Asset '%s') fehlt in 'data'.", paste(col, collapse = ","), nm))
        wv <- data[[col]][flag_event]
        if (!is.numeric(data[[col]]) || any(wv < 0, na.rm = TRUE))
          stop(sprintf("simulation: event_weight-Spalte '%s' muss nicht negative Zahlen enthalten.", col))
      }
      fehlt <- setdiff(names(strategy), names(event_weight))
      if (length(fehlt))
        warning(sprintf("simulation: event_weight nennt nicht alle Assets (es fehlt: %s); an Event-Tagen gelten dann die Strategie-Gewichte.",
                        paste(fehlt, collapse = ", ")), call. = FALSE)
    }
  }

  # R3a-05: start nach dem letzten Datentag waere nie handelbar (frueher still auf Tag 1 gesetzt)
  starts <- lapply(flag_assets, function(name) sim_mem[["assets"]][[name]][["start"]])
  for (k in seq_along(flag_assets)) {
    st_a <- starts[[k]]
    if (length(st_a) == 1L && !is.na(st_a) && st_a > stopp_date)
      stop(sprintf("simulation: start von '%s' (%s) liegt nach dem letzten Datentag (%s); das Asset w\u00e4re nie handelbar. start auf ein Datum im Datenzeitraum setzen oder das Asset aus der Strategie entfernen.",
                   flag_assets[k], format(st_a), format(stopp_date)))
  }
  # bis E17 Stufe 1c .sim_init_weights: mindestens ein Asset ab dem ersten Tag handelbar
  if (!length(flag_assets[vapply(starts, function(st) (st %||% flag_date[1]) <= flag_date[1], NA)]))   # R1-22
    stop(sprintf("simulation: Kein Asset ist am ersten Datentag (%s) handelbar (start bzw. erste Kurse sp\u00e4ter); mindestens ein Asset muss ab Beginn handelbar sein.",
                 format(flag_date[1])))

  list(data = data,
       flags = list(flag_date = flag_date, flag_filled = flag_filled, flag_assets = flag_assets, dca = dca,
                    balance = balance, flag_event = flag_event, event_replace = event_mode == "replace"),
       event_weight = if (!is.null(event_col)) event_weight)
}
