# =============================================================================
# simulation(), Phase 2: Datenvorbereitung, Zentralstruktur sim_mem, Termine und Flags
# =============================================================================

# C7-11: Feldfolge der obersten Ebene von sim_mem. Die C++-Kerne (simulation_core.cpp,
# fifo_core_RCpp.cpp) lesen und schreiben diese Ebene ueber die Position (input[1] = status,
# input[2] = market, input[3] = trades, input[4] = report; C++ zaehlt ab 0), alles darunter ueber
# Namen. Die Reihenfolge wird hier festgelegt und vor dem ersten C++-Aufruf geprueft.
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
#' base_rate_data (Argumente von simulation()).
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
    .frac_warn_col(data[[base_rate_data]], "base_rate_data", base_rate_data, hi = 0.05)
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
    data$.filled <- pre_filled      # R1-17: aufgefuellte Tage aus align_series() wie eigene behandeln
  }

  list(data = data, start_date = start_date, stopp_date = stopp_date)
}

#' Phase 2b von simulation(): Zentralstruktur sim_mem anlegen
#'
#' Zweck: sim_mem mit den Feldern aus .SIM_MEM_LAYOUT (assets, status, market, trades, report,
#' totals) je Asset vorbelegen; prueft die Signal- und Basiszinsspalten.
#' Eingabe: data und strategy (vorbereitet), start_value, start_date, stopp_date, sparer_pauschbetrag,
#' use_sparer_pauschbetrag, base_rate, base_rate_flex, base_rate_data.
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
      total_value = start_value,
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
      style = strategy[[name]][["action_type"]],
      start = as.Date(strategy[[name]][["asset_start"]] %||% start_date),
      tax_regime = strategy[[name]][["tax_regime"]] %||% switch(strategy[[name]][["asset_class"]],
        "etf" = "investment_fund",
        "etn" = if (isTRUE(strategy[[name]][["deliverable"]])) "private_sale" else "capital_gains",
        "etc" = if (isTRUE(strategy[[name]][["deliverable"]])) "private_sale" else "capital_gains",
        "certificate" = "capital_gains",
        "etn_standard" = "capital_gains",
        "etn_deliverable" = "private_sale",
        "capital_gains"),
      bonus = (strategy[[name]][["asset_bonus"]] %||% 0) / 100,   # PROZENT-KONVENTION
      deliverable = strategy[[name]][["deliverable"]] %||% FALSE
    )

    # P-2: Signal-Spalten validieren (nur fuer action_type = "signal")
    if (identical(strategy[[name]][["action_type"]], "signal")) {
      sb <- strategy[[name]][["signal_buy"]]
      ss <- strategy[[name]][["signal_sell"]]
      if (is.null(sb) || !sb %in% names(data))
        stop(sprintf("simulation: signal_buy-Spalte '%s' fehlt im Datensatz (Asset '%s').", sb %||% "NULL", name))
      if (is.null(ss) || !ss %in% names(data))
        stop(sprintf("simulation: signal_sell-Spalte '%s' fehlt im Datensatz (Asset '%s').", ss %||% "NULL", name))
    }

    #---> Initialisierung des Status-Objekts: (Das war mal ein Vektor!!!!)
    sim_mem[["status"]][[name]] <- list(
      count = 0,
      price = 0,
      worth = 0,
      money = strategy[[name]][["asset_share"]] * start_value,
      total = strategy[[name]][["asset_share"]] * start_value,
      target = strategy[[name]][["asset_share"]],
      actual = strategy[[name]][["asset_share"]],
      differ = 0
    )

    #---> Initialisierung des Market-Objekts:
    sim_mem[["market"]][[name]] <- list(
      asset_day = seq.Date(
        from = as.Date(start_date),
        to = as.Date(stopp_date),
        by = "days"),
      base_rates = if (base_rate_flex) {
  if (is.null(base_rate_data) || !base_rate_data %in% names(data)) {
    stop(if (is.null(base_rate_data)) "simulation: base_rate_flex = TRUE braucht base_rate_data (Name der Basiszins-Spalte in data, Prozent p. a.); base_rate_data fehlt."
         else sprintf("simulation: base_rate_data-Spalte '%s' fehlt in data (base_rate_flex = TRUE braucht eine Basiszins-Spalte in Prozent p. a.; vorhanden: %s).",
                      paste(base_rate_data, collapse = ", "), paste(names(data), collapse = ", ")))
  }
  br <- data[[base_rate_data]]
  br[is.na(br)] <- 0  # NA durch 0 ersetzen
  br
} else {
  # BUG-1 FIX: Vektor statt Skalar, damit Index-Zugriff in calculate_flat_rate() funktioniert
  rep(base_rate %||% 0, nrow(data))
},
      asset_price = data[[name]],
      signal_buy = if (is.null(strategy[[name]][["signal_buy"]])) rep(FALSE, nrow(data)) else data[[strategy[[name]][["signal_buy"]]]],
      signal_sell = if (is.null(strategy[[name]][["signal_sell"]])) rep(FALSE, nrow(data)) else data[[strategy[[name]][["signal_sell"]]]],
      spread_rate = (strategy[[name]][["asset_spread"]] %||% 0) / 100   # PROZENT-KONVENTION
    )

    #---> Initialisierung des Trade-Objekts:
    max_trades <- nrow(data)
    sim_mem[["trades"]][[name]] <- list(
      buys = vector("list", max_trades),
      buy_count = 0,
      sells = vector("list", max_trades),
      sell_count = 0,
      taxes = vector("list", max_trades),
      tax_count = 0,
      fees = vector("list", max_trades),
      fee_count = 0,
      fifo_front = 1
    )

    #---> Initialisierung des Report-Objekts:
    sim_mem[["report"]][[name]] <- list(
      worth = c(sim_mem[["status"]][[name]][["worth"]], numeric(nrow(data)-1)),
      money = c(sim_mem[["status"]][[name]][["money"]], numeric(nrow(data)-1)),
      flows = numeric(nrow(data)),
      total = c(sim_mem[["status"]][[name]][["total"]], numeric(nrow(data)-1)),
      share = numeric(nrow(data))  # Wird durch calculate_total_report am Tag 1 korrekt gesetzt
    )
  }

  sim_mem
}

#' Phase 2c von simulation(): Termine und Tages-Flags
#'
#' Zweck: Kalender (flag_date, aufgefuellte Tage), Termine fuer Liquidation, Rebalancing, Sparplan
#' und Splits, Ereignis-Rebalancing (event_col, event_weight) und das Verschieben von Terminen auf
#' aufgefuellten Tagen; prueft dca_start, balance_start, event_col, event_weight und asset_start.
#' Eingabe: data, sim_mem, strategy, start_date, stopp_date und die Termin-Argumente von simulation()
#' (dca_days und balance_days aus .sim_check_inputs).
#' Ausgabe: list(data = data ohne Spalte .filled, flags = Liste der Flags, event_weight = geprueftes
#' event_weight bzw. NULL ohne event_col).
#' @keywords internal
#' @noRd
.sim_build_calendar <- function(data, sim_mem, strategy, start_date, stopp_date, liquidate,
                                dca_mode, dca_span, dca_unit, dca_days, dca_value, dca_anchor, dca_start,
                                dca_skip, balance_mode, balance_span, balance_unit, balance_days,
                                balance_anchor, balance_start, balance_skip, event_col,
                                event_mode = c("additional", "replace"), event_weight, split_mode,
                                split_thresh) {
  #--------> Initialisierung der Flag-Objekte:
  flag_date <- seq.Date(from = as.Date(start_date), to = as.Date(stopp_date), by = "days")
  # A-2: Markierung aufgefuellter (LOCF) Tage, aligned zu flag_date
  flag_filled <- if (".filled" %in% names(data)) {
    .f <- as.logical(data[[".filled"]]); .f[is.na(.f)] <- TRUE; .f
  } else rep(FALSE, length(flag_date))
  data[[".filled"]] <- NULL
  flag_assets <- names(strategy)
  flag_liquidate <- liquidate & (flag_date == stopp_date)
  for (a in c("dca", "balance")) {   # R1-22: Bezugsdatum pruefen (sonst kryptischer seq()-Fehler)
    sd0 <- get(paste0(a, "_start"))
    if (!isTRUE(get(paste0(a, "_mode"))) || is.null(sd0)) next
    sd1 <- tryCatch(as.Date(sd0), error = function(e) NA)
    if (length(sd1) != 1L || is.na(sd1)) stop(sprintf("simulation: %s_start = '%s' ist kein Datum (erwartet Date oder \"JJJJ-MM-TT\").", a, format(sd0)))
    if (sd1 > stopp_date) stop(sprintf("simulation: %s_start (%s) liegt nach dem letzten Datentag (%s); es g\u00e4be keine Termine.",
                                       a, format(sd1), format(stopp_date)))
  }
  flag_rebalance <- calculate_dates_flags(mode = balance_mode, span = balance_span, unit = balance_unit, days = balance_days, dates = flag_date, anchor = balance_anchor, start_date = balance_start, skip_start = balance_skip, liquidate = liquidate)
  flag_dca <- calculate_dates_flags(mode = dca_mode, span = dca_span, unit = dca_unit, days = dca_days, dates = flag_date, value = dca_value, anchor = dca_anchor, start_date = dca_start, skip_start = dca_skip, liquidate = liquidate)
  flag_taxes <- (format(flag_date, "%m-%d") == "12-31")
  # === NEU: Ereignisbasiertes Rebalancing-Flag aus vorberechneter Spalte ===
  # Default (event_col = NULL): Verhalten unveraendert datumsgetrieben.
  # Da flag_rebalance in flag_definite -> flag_slow_path einfliesst, werden
  # Event-Tage automatisch zu Slow-Path-Tagen (volle Event-Verarbeitung).
  event_mode <- match.arg(event_mode)
  flag_event <- rep(FALSE, length(flag_date))
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
    # gleiche Schutzregeln wie der Kalender-Trigger: kein Rebalancing am
    # Einstiegstag und (bei liquidate) nicht am Liquidationstag.
    guard <- (flag_date != flag_date[1]) & (!liquidate | flag_date != stopp_date)
    flag_event <- flag_event & guard
    if (event_mode == "additional") {
      flag_rebalance <- flag_rebalance | flag_event   # zusaetzlich (OR)
    } else {
      flag_rebalance <- flag_event                    # anstelle
    }
  }

  flag_trade <- !flag_rebalance & (flag_date != stopp_date) & !flag_filled
  flag_split <- calculate_split_flags(input = sim_mem, base = 100, mode = split_mode, dates = flag_date, split_thresh = split_thresh)

  # V-1b: Verschiebe-Helfer (naechster Handelstag; am Monatsende vorziehen)
  .shift_off_filled <- function(flags, filled, dates){
    hit <- which(flags & filled)
    if(!length(hit)) return(flags)
    n <- length(flags); mon <- format(dates, "%Y-%m")
    for(i in hit){
      j <- i + 1L
      while(j <= n && filled[j]) j <- j + 1L
      if(j > n || mon[j] != mon[i]){          # Monatsende: vorziehen
        j <- i - 1L
        while(j >= 1L && filled[j]) j <- j - 1L
      }
      if(is.logical(flags)){
        flags[i] <- FALSE
        if(j >= 1L && j <= n) flags[j] <- TRUE
      } else {                                 # R1-16: Anzahl (Sparplantermine) mitnehmen
        if(j >= 1L && j <= n) flags[j] <- flags[j] + flags[i]
        flags[i] <- 0
      }
    }
    flags
  }
  flag_dca_n <- as.numeric(flag_dca)           # Anzahl Sparplantermine je Tag
  if(any(flag_filled)){
    flag_rebalance <- .shift_off_filled(flag_rebalance, flag_filled, flag_date)
    flag_dca_n     <- .shift_off_filled(flag_dca_n,     flag_filled, flag_date)
    flag_dca       <- flag_dca_n > 0
    flag_split     <- .shift_off_filled(flag_split,     flag_filled, flag_date)
    flag_liquidate <- .shift_off_filled(flag_liquidate, flag_filled, flag_date)
    # A7-02: Liquidationsschutz auch nach dem Verschieben (verschobene Termine auf dem Liquidationstag
    # entfallen wie Termine am letzten Tag): kein Rebalancing, keine Sparrate
    if (any(flag_liquidate)) {
      flag_rebalance[flag_liquidate] <- FALSE
      flag_dca_n[flag_liquidate] <- 0
      flag_dca <- flag_dca_n > 0
    }
    flag_trade     <- !flag_rebalance & (flag_date != stopp_date) & !flag_filled   # neu ableiten
  }

  # R3a-05: asset_start nach dem letzten Datentag waere nie handelbar (frueher still auf Tag 1 gesetzt)
  for (name in flag_assets) {
    st_a <- sim_mem[["assets"]][[name]][["start"]]
    if (length(st_a) == 1L && !is.na(st_a) && st_a > stopp_date)
      stop(sprintf("simulation: asset_start von '%s' (%s) liegt nach dem letzten Datentag (%s); das Asset w\u00e4re nie handelbar. asset_start auf ein Datum im Datenzeitraum setzen oder das Asset aus der Strategie entfernen.",
                   name, format(st_a), format(stopp_date)))
  }

  list(data = data,
       flags = list(flag_date = flag_date, flag_filled = flag_filled, flag_assets = flag_assets,
                    flag_liquidate = flag_liquidate, flag_rebalance = flag_rebalance, flag_dca = flag_dca,
                    flag_dca_n = flag_dca_n, flag_taxes = flag_taxes, flag_event = flag_event,
                    flag_trade = flag_trade, flag_split = flag_split),
       event_weight = if (!is.null(event_col)) event_weight)
}

#' Phase 2d von simulation(): Startgewichte
#'
#' Zweck: Zielgewichte auf alle Assets beziehen und das Startkapital auf die am ersten Tag
#' handelbaren Assets verteilen.
#' Eingabe: sim_mem, flag_assets, flag_date, start_value.
#' Ausgabe: list(sim_mem, initial_assets = Namen der ab dem ersten Tag handelbaren Assets).
#' @keywords internal
#' @noRd
.sim_init_weights <- function(sim_mem, flag_assets, flag_date, start_value) {
  #--------> Initialisierung der Startgewichte bei Non-Tradeble Assets:
  initial_assets <- flag_assets[sapply(flag_assets, function(name){
    trade_start <- sim_mem[["assets"]][[name]][["start"]] 
    (trade_start %||% flag_date[1]) <= flag_date[1]
  })]

  if (!length(initial_assets))   # R1-22
    stop(sprintf("simulation: Kein Asset ist am ersten Datentag (%s) handelbar (asset_start bzw. erste Kurse sp\u00e4ter); mindestens ein Asset muss ab Beginn handelbar sein.",
                 format(flag_date[1])))

  initial_weights_sum <- sum(sapply(initial_assets, function(name) sim_mem[["status"]][[name]][["actual"]]))
  all_weights_sum <- sum(sapply(flag_assets, function(name) sim_mem[["status"]][[name]][["actual"]]))

  for(name in flag_assets){
    # R1-12: Zielgewicht ('actual') bezogen auf ALLE Assets (nicht nur die Start-Assets),
    # damit spaeter startende Assets ihr Strategie-Gewicht erhalten; das Startkapital
    # verteilt sich auf die Start-Assets.
    target_weight <- sim_mem[["status"]][[name]][["actual"]] / all_weights_sum
    if(name %in% initial_assets){
      normalized_weight <- sim_mem[["status"]][[name]][["actual"]] / initial_weights_sum
      sim_mem[["status"]][[name]][["actual"]] <- target_weight
      sim_mem[["status"]][[name]][["money"]]  <- start_value * normalized_weight
      sim_mem[["status"]][[name]][["total"]]  <- start_value * normalized_weight
    } else {
      sim_mem[["status"]][[name]][["actual"]] <- target_weight
      sim_mem[["status"]][[name]][["differ"]] <- 0
      sim_mem[["status"]][[name]][["money"]]  <- 0
      sim_mem[["status"]][[name]][["total"]]  <- 0
    }
  }

  list(sim_mem = sim_mem, initial_assets = initial_assets)
}

#' Phase 2e von simulation(): Ereignis- und Verarbeitungstage
#'
#' Zweck: Aktivierungstage spaeter startender Assets, Termine fuer Gewinnrealisierung und
#' Fondskosten, statische Asset-Eigenschaften (Stil, Steuerregime, Spread) sowie die Tage mit
#' voller Verarbeitung (Slow-Path), Jahreswechsel und Abrechnungstage der Vorabpauschale.
#' Eingabe: sim_mem, fl (Flags aus .sim_build_calendar mit initial_assets), data, stopp_date,
#' tax_mode, harvest_mode, harvest_day.
#' Ausgabe: fl, ergaenzt um asset_starts, flag_active, asset_start_indices, flag_harvest,
#' flag_fund_fee, strategy_types, tax_regimes, spread_rates, flag_slow_path, flag_year_change,
#' flag_vp_settle, individual_days und n_total_days.
#' @keywords internal
#' @noRd
.sim_build_schedule <- function(sim_mem, fl, data, stopp_date, tax_mode, harvest_mode, harvest_day) {
  flag_date <- fl$flag_date; flag_filled <- fl$flag_filled; flag_assets <- fl$flag_assets
  flag_split <- fl$flag_split; flag_dca <- fl$flag_dca; flag_rebalance <- fl$flag_rebalance
  flag_taxes <- fl$flag_taxes; flag_liquidate <- fl$flag_liquidate

  asset_starts <- as.Date(vapply(flag_assets, function(name) as.numeric(sim_mem[["assets"]][[name]][["start"]] %||% flag_date[1]), numeric(1)), origin = "1970-01-01")
  if(any(flag_filled)){
    asset_starts <- as.Date(vapply(asset_starts, function(d){
      i <- match(d, flag_date)
      if(is.na(i) || !flag_filled[i]) return(as.numeric(d))
      n <- length(flag_date); mon <- format(flag_date, "%Y-%m")
      j <- i + 1L
      while(j <= n && flag_filled[j]) j <- j + 1L
      if(j > n || mon[j] != mon[i]){
        j <- i - 1L
        while(j >= 1L && flag_filled[j]) j <- j - 1L
      }
      as.numeric(flag_date[max(min(j, n), 1L)])
    }, numeric(1)), origin = "1970-01-01")
  }
  flag_active <- flag_date %in% asset_starts

  # P1: Statt 1826 identische Kopien vorallokieren, Startindizes speichern
  # und active_assets im Slow-Path inline berechnen
  asset_start_indices <- match(asset_starts, flag_date)
  asset_start_indices[is.na(asset_start_indices)] <- 1L   # nur asset_start vor dem ersten Datentag (spaeter: Fehler oben)






  # 1. Definitive Events (kalenderbasiert, unabhängig von Strategie)
  flag_harvest <- rep(FALSE, length(flag_date))
  if (isTRUE(harvest_mode) && tax_mode == "person") {
    md <- format(flag_date, "%m-%d"); yr <- format(flag_date, "%Y")
    for (y in unique(yr)) {                              # erster Handelstag ab harvest_day im Jahr
      j <- which(yr == y & md >= harvest_day & md < "12-31" & !flag_filled)
      if (length(j)) flag_harvest[j[1]] <- TRUE
    }
  }
  # Fondskosten (tax_mode = "funds"): 31.12. und anteilig am letzten Simulationstag
  flag_fund_fee <- (tax_mode == "funds") & (flag_taxes | flag_date == stopp_date)
  # R2-06: endet 'data' auf einem aufgefuellten Tag, wurde die Liquidation auf den letzten Handelstag
  # verschoben; die anteiligen Fondskosten ziehen mit (Kosten vor der Steuer auf den Gesamtgewinn)
  n_fd <- length(flag_date)
  if (tax_mode == "funds" && any(flag_liquidate) && !flag_liquidate[n_fd]) {
    liq_i <- max(which(flag_liquidate))
    flag_fund_fee[seq_len(n_fd) > liq_i] <- FALSE   # auch ein aufgefuellter 31.12. danach
    flag_fund_fee[liq_i] <- TRUE
  }
  flag_definite <- flag_active | flag_split | flag_dca | flag_rebalance | flag_taxes | flag_liquidate | flag_harvest | flag_fund_fee

  # 2. Strategie-Typen identifizieren
  strategy_types <- sapply(flag_assets, function(name) sim_mem[["assets"]][[name]][["style"]])
  has_bnh <- any(strategy_types == "bnh")
  has_signal <- any(strategy_types == "signal")

  # P6: Tax-Regime einmal pro Asset vorberechnen (statisch, ändert sich nie)
  tax_regimes <- sapply(flag_assets, function(name) sim_mem[["assets"]][[name]][["tax_regime"]])
  # O-2: Spread-Raten einmalig vorberechnen (statt wiederholter Lookups)
  spread_rates <- sapply(flag_assets, function(name) sim_mem[["market"]][[name]][["spread_rate"]])

  # 3. Signale aus Daten extrahieren (statisch, vorberechnet)
  flag_signal <- rep(FALSE, length(flag_date))

  if(has_signal){
    for(name in flag_assets){
      if(sim_mem[["assets"]][[name]][["style"]] == "signal"){
        # Asset-spezifische Signale
        buy_signal <- sim_mem[["market"]][[name]][["signal_buy"]]
        sell_signal <- sim_mem[["market"]][[name]][["signal_sell"]]
      
        # Kombinieren (TRUE wenn eines der Signale TRUE)
        flag_signal <- flag_signal | buy_signal | sell_signal
      }
    }
  }

  # 4. BnH-Potenzial (nur Tag 1, danach übernimmt DCA)
  #    Bei BnH OHNE DCA: Nur Tag 1 ist relevant (danach immer investiert)
  #    Bei BnH MIT DCA: Tag 1 + DCA-Tage (in flag_definite bereits enthalten)
  flag_bnh_potential <- rep(FALSE, length(flag_date))

  if(has_bnh){
    flag_bnh_potential[1] <- TRUE
  # Weitere Tage nicht nötig! DCA-Tage sind bereits in flag_definite
  }

  # 5. Kombiniertes Slow-Path Flag
  flag_slow_path <- flag_definite | flag_signal | flag_bnh_potential
  

  # ═══════════════════════════════════════════════════════════════════════════════
  # 7. PERFORMANCE-OPTIMIERUNG: Vorberechnung der Individual-Processing-Tage
  # ═══════════════════════════════════════════════════════════════════════════════
  # Statt jeden Tag einzeln zu durchlaufen, identifizieren wir Tage die 
  # individuelle Verarbeitung brauchen (Slow-Path, Jahreswechsel).
  # Zusammenhängende Blöcke dazwischen werden per batch_market_update() in C++
  # vektorisiert verarbeitet (~10-50x schneller als einzelne R-Aufrufe).
  
  # Jahreswechsel-Flag vorberechnen (statt format() auf jedem Tag)
  flag_year_change <- rep(FALSE, length(flag_date))
  flag_vp_settle   <- rep(FALSE, length(flag_date))   # erster Handelstag je neuen Jahres
  if (tax_mode == "person") {
    date_years <- as.integer(format(flag_date, "%Y"))
    flag_year_change <- c(FALSE, diff(date_years) > 0L)
    for (ys in which(flag_year_change)) {
      j <- ys
      while (j <= length(flag_date) && flag_filled[j] && date_years[j] == date_years[ys]) j <- j + 1L
      # R3a-01: ohne Handelstag im Folgejahr (in den Daten) am 1.1. des Folgejahres abrechnen
      # (Toepfe des Folgejahres), nicht erst im uebernaechsten Jahr bzw. am letzten Tag
      if (j > length(flag_date) || date_years[j] != date_years[ys]) j <- ys
      flag_vp_settle[j] <- TRUE
    }
  }
  
  # Kombiniertes Flag: Alle Tage die individuelle Verarbeitung brauchen
  flag_slow_path  <- flag_slow_path | flag_vp_settle   # Faelligkeitstage voll verarbeiten (kein Fast-Path-next)
  flag_individual <- flag_slow_path | flag_year_change
  individual_days <- which(flag_individual)
  n_total_days <- nrow(data)

  c(fl, list(asset_starts = asset_starts, flag_active = flag_active, asset_start_indices = asset_start_indices,
             flag_harvest = flag_harvest, flag_fund_fee = flag_fund_fee, strategy_types = strategy_types,
             tax_regimes = tax_regimes, spread_rates = spread_rates, flag_slow_path = flag_slow_path,
             flag_year_change = flag_year_change, flag_vp_settle = flag_vp_settle,
             individual_days = individual_days, n_total_days = n_total_days))
}
