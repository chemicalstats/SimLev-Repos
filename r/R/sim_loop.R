# =============================================================================
# simulation(), Phase 4: Tagesschleife und Abschluss des letzten Jahres
# =============================================================================
#
# .sim_run_days() steuert die Tage: zusammenhaengende Tage ohne Ereignis in einem C++-Aufruf
# (.sim_market_update_batch_cpp), Jahreswechsel (handle_year_change) und Abrechnung der Vorabpauschale des
# Vorjahres direkt, die uebrigen Ereignisse in den Tagesschritten .sim_day_*() in fester
# Reihenfolge: Aktivierung, Split, Sparplan, Handel, Rebalancing, Gewinnrealisierung, Vorabpauschale
# (31.12.), Fondskosten, Liquidation. Jeder Schritt gibt sim_mem zurueck (C++-Funktionen aendern
# sim_mem zusaetzlich an Ort und Stelle).

#' Phase 4 von simulation(): Tagesschleife
#'
#' Zweck: alle Simulationstage verarbeiten (Marktupdate, Jahreswechsel, Abrechnungen und die
#' Tagesschritte .sim_day_*()), danach die Tage nach dem letzten Ereignistag fortschreiben.
#' Eingabe: sim_mem, fl (Flags aus .sim_build_schedule), cfg (aus .sim_check_inputs), act (Helfer aus
#' .sim_make_actions), data, strategy und die erst hier benoetigten Argumente von simulation()
#' (liquidate, event_weight, split_thresh, funds_fee, bonus_fee, balance_dca, harvest_loss_pot, details).
#' Ausgabe: sim_mem am Ende des letzten Tages.
#' @keywords internal
#' @noRd
.sim_run_days <- function(sim_mem, fl, cfg, act, data, strategy, liquidate, event_weight, split_thresh,
                          funds_fee, bonus_fee, balance_dca, harvest_loss_pot, details) {
  flag_date <- fl$flag_date; flag_assets <- fl$flag_assets; n_total_days <- fl$n_total_days
  individual_days <- fl$individual_days; flag_year_change <- fl$flag_year_change
  flag_slow_path <- fl$flag_slow_path; flag_vp_settle <- fl$flag_vp_settle
  flag_active <- fl$flag_active; asset_start_indices <- fl$asset_start_indices
  flag_split <- fl$flag_split; flag_dca <- fl$flag_dca; flag_trade <- fl$flag_trade
  flag_rebalance <- fl$flag_rebalance; flag_harvest <- fl$flag_harvest; flag_taxes <- fl$flag_taxes
  flag_fund_fee <- fl$flag_fund_fee; flag_liquidate <- fl$flag_liquidate
  tax_mode <- cfg$tax_mode; fees_on <- cfg$fees_on; fee_order <- cfg$fee_order
  marginal_tax_rate <- cfg$marginal_tax_rate; private_sale_threshold <- cfg$private_sale_threshold
  sparer_pauschbetrag <- cfg$sparer_pauschbetrag; use_sparer_pauschbetrag <- cfg$use_sparer_pauschbetrag
  soli_factor_income <- cfg$soli_factor_income; effective_tax_rate <- cfg$effective_tax_rate
  church_k <- cfg$church_k; tariff_env <- cfg$tariff_env
  .settle_vp <- act$.settle_vp; .settle_p23 <- act$.settle_p23
  .settle_gp <- act$.settle_gp; .gp_pending <- act$.gp_pending

  # ═══════════════════════════════════════════════════════════════════════════════
  # BLOCK-BASIERTE HAUPTSCHLEIFE
  # ═══════════════════════════════════════════════════════════════════════════════
  
  prev_end <- 0L
  active_assets <- character(0)   # O-3: nur an Aktivierungstagen neu berechnet
  
  for (sd_pos in seq_along(individual_days)) {
    time <- individual_days[sd_pos]
    
    # ─────────────────────────────────────────────────────────────────────────
    # BATCH: Zusammenhängende Fast-Path-Tage vor diesem Individual-Tag
    # → Ein einzelner C++ Aufruf statt hunderte R-Iterationen
    # ─────────────────────────────────────────────────────────────────────────
    if (time > prev_end + 1L) {
      .sim_market_update_batch_cpp(sim_mem, flag_assets, prev_end + 1L, time - 1L)
    }
    
    # ─────────────────────────────────────────────────────────────────────────
    # INDIVIDUAL-TAG: Jahreswechsel, dann ggf. Slow-Path
    # ─────────────────────────────────────────────────────────────────────────
    
    # === Jahreswechsel prüfen (nur an Tagen wo das Jahr wechselt) ===
    if (flag_year_change[time]) {
      sim_mem <- handle_year_change(
        input = sim_mem,
        current_date = flag_date[time],
        marginal_tax_rate = marginal_tax_rate,
        private_sale_threshold = private_sale_threshold,
        sparer_pauschbetrag = sparer_pauschbetrag,
        use_sparer_pauschbetrag = use_sparer_pauschbetrag,
        soli_factor_income = soli_factor_income,
        effective_tax_rate = effective_tax_rate,
        details = details, church_factor = church_k, tariff_env = tariff_env
      )
    }
    
    # === Wenn kein Slow-Path → nur Market-Update (C++) ===
    if (!flag_slow_path[time]) {
      .sim_market_update_cpp(sim_mem, flag_assets, time)
      prev_end <- time
      next
    }
    
    # ─────────────────────────────────────────────────────────────────────────
    # SLOW-PATH: Volle Event-Verarbeitung
    # ─────────────────────────────────────────────────────────────────────────
    if (flag_active[time] || length(active_assets) == 0L) {
      active_assets <- flag_assets[asset_start_indices <= time]   # O-3: Cache-Update
    }
    # R1-04: dca_fee nur fuer die Sparplankaeufe; Rebalancing, Signale, Steuer-
    # verkaeufe und Liquidation am selben Tag laufen mit order_fee
    if (fees_on) .fee_env$current <- fee_order
    flag_fast_report <- TRUE

    #--------> § 18 Abs. 3 InvStG: Zufluss der Vorabpauschale des Vorjahres (erster
    # Handelstag, nach handle_year_change, vor allen Trades des Tages)
    # R3a-02: am selben Tag (nach der VP) die § 23-Steuer des Vorjahres aus dem Depot zahlen
    if (tax_mode == "person" && flag_vp_settle[time] &&
        (length(sim_mem[["totals"]][["vp_pending"]]) || length(sim_mem[["totals"]][["p23_due"]]) || .gp_pending())) {
      if (length(sim_mem[["totals"]][["vp_pending"]])) sim_mem <- .settle_vp(sim_mem, time)
      if (length(sim_mem[["totals"]][["p23_due"]])) sim_mem <- .settle_p23(sim_mem, time)
      if (.gp_pending()) sim_mem <- .settle_gp(sim_mem, time)
      .sim_total_report_cpp(input = sim_mem, assets = flag_assets, index = time)
      flag_fast_report <- FALSE
    }

    #--------> Implementierung von Asset-Aktivierung (.sim_day_activate):
    if(flag_active[time]){
      step <- .sim_day_activate(sim_mem, time, active_assets, fl, cfg, details)
      sim_mem <- step$sim_mem
      if (step$rebalance_now) {
        flag_rebalance[time] <- TRUE
        # A7-03: Aktivierung eines spaeter startenden Assets: wie an jedem Rebalancing-Tag kein zusaetzlicher
        # Handelsblock (keine Doppelorders: Kauf aus Sparrate und danach Umschichtung)
        # R8-05: ebenso am ersten Tag mit balance_mode (Aktivierung der Start-Assets, Start nicht auf einem
        # Termin): sonst kaufte der Handelsblock und das Rebalancing schichtete danach Reste um (Zusatzorders)
        flag_trade[time] <- FALSE
      }
      flag_fast_report <- FALSE
    }

    #--------> Implementierung von Splits und Reverse Splits (.sim_day_split):
    if(flag_split[time]){
      sim_mem <- .sim_day_split(sim_mem, time, active_assets, fl, cfg, split_thresh, details)
      flag_fast_report <- FALSE
    }

    #--------> Implementierung von Dollar-Cost-Averaging (.sim_day_dca):
    if(flag_dca[time]){
      sim_mem <- .sim_day_dca(sim_mem, time, active_assets, fl, cfg, strategy, balance_dca, details)
      flag_fast_report <- FALSE
    }

    #--------> Implementierung von Trading-Aktionen (.sim_day_trade):
    if(flag_trade[time]){
      step <- .sim_day_trade(sim_mem, time, active_assets, fl, cfg, act, details)
      sim_mem <- step$sim_mem
      if (step$traded) flag_fast_report <- FALSE
    }

    #--------> Implementierung von Rebalancing-Aktionen (.sim_day_rebalance):
    if(flag_rebalance[time]){
      sim_mem <- .sim_day_rebalance(sim_mem, time, active_assets, fl, cfg, act, data, event_weight, details)
      flag_fast_report <- FALSE
    }

    #--------> Freibetrag ausschoepfen (Gewinne realisieren und sofort wieder kaufen; .sim_day_harvest):
    if (flag_harvest[time]) {
      sim_mem <- .sim_day_harvest(sim_mem, time, active_assets, fl, cfg, harvest_loss_pot, details)
      flag_fast_report <- FALSE
    }

    #--------> Implementierung von Steuer- und Gebührenkalkulation:
    # § 18 Abs. 3 InvStG: Am 31.12. wird die Vorabpauschale je Lot nur festgesetzt
    # (Lot-Werte fuer § 19 InvStG); Zufluss und Steuer am ersten Handelstag des
    # Folgejahres (.settle_vp, oben vor allen Trades des Tages).
    # Tagesschritt .sim_day_assess_vp()
    if (flag_taxes[time]) {
      sim_mem <- .sim_day_assess_vp(sim_mem, time, fl, cfg, liquidate, details)
      flag_fast_report <- FALSE
    }

    #--------> Fondskosten (tax_mode = "funds"): am 31.12. und anteilig am letzten Tag
    # R1-01: fehlendes Bargeld per Teilverkauf beschaffen (wie bei der Vorabpauschale)
    # Tagesschritt .sim_day_fund_fee()
    if (flag_fund_fee[time]) {
      sim_mem <- .sim_day_fund_fee(sim_mem, time, fl, act, funds_fee, bonus_fee, details)
      flag_fast_report <- FALSE
    }

    #--------> Implementierung von Liquidierung (.sim_day_liquidate):
    if(flag_liquidate[time]){
      sim_mem <- .sim_day_liquidate(sim_mem, time, fl, cfg, details)
      flag_fast_report <- FALSE
    }

    # Fallback: Wenn kein Slow-Path-Event den Report aktualisiert hat
    if(flag_fast_report){
      .sim_market_update_cpp(sim_mem, flag_assets, time)
    }

    prev_end <- time
  }

  # ─────────────────────────────────────────────────────────────────────────
  # TRAILING BATCH: Fast-Path-Tage nach dem letzten Individual-Tag
  # ─────────────────────────────────────────────────────────────────────────
  if (prev_end < n_total_days) {
    .sim_market_update_batch_cpp(sim_mem, flag_assets, prev_end + 1L, n_total_days)
  }

  sim_mem
}

#' Tagesschritt: Aktivierung spaeter startender Assets
#'
#' Zweck: Signale noch nicht aktiver Assets am Aktivierungstag loeschen; mit balance_mode bzw. bei
#' einem spaeter startenden Asset die Zielgewichte setzen und Rebalancing statt Handel anfordern.
#' Eingabe: sim_mem, time (Tagesindex), active_assets, fl, cfg, details.
#' Ausgabe: list(sim_mem, rebalance_now = TRUE, wenn an diesem Tag umgeschichtet und nicht gehandelt
#' wird).
#' @keywords internal
#' @noRd
.sim_day_activate <- function(sim_mem, time, active_assets, fl, cfg, details) {
  flag_assets <- fl$flag_assets; flag_date <- fl$flag_date; asset_starts <- fl$asset_starts
  initial_assets <- fl$initial_assets; balance_mode <- cfg$balance_mode
  rebalance_now <- FALSE
  for(name in setdiff(flag_assets, active_assets)){
    sim_mem[["market"]][[name]][["signal_buy"]][time] <- FALSE
    sim_mem[["market"]][[name]][["signal_sell"]][time] <- FALSE
  }

  # Spaeter startendes Asset: am Aktivierungstag immer auf die Zielgewichte
  # umschichten (auch ohne balance_mode), damit es Mittel erhaelt
  late_now <- any(asset_starts == flag_date[time] & !(flag_assets %in% initial_assets))
  if(balance_mode || late_now){
    current_weights_sum <- sum(sapply(active_assets, function(name) sim_mem[["status"]][[name]][["actual"]]))

    for(name in active_assets){sim_mem[["status"]][[name]][["differ"]] <- sim_mem[["status"]][[name]][["actual"]] / current_weights_sum}

    if(details){
      new_assets <- flag_assets[asset_starts == flag_date[time]]
      if(length(new_assets)) cat(sprintf("Marktereignis:\tHandel mit %s ab jetzt m\u00f6glich.\n", paste(new_assets, collapse = ", ")))
    }

    rebalance_now <- TRUE   # Aufrufer: flag_rebalance[time] <- TRUE, flag_trade[time] <- FALSE
  }

  .sim_total_report_cpp(input = sim_mem, assets = flag_assets, index = time)

  list(sim_mem = sim_mem, rebalance_now = rebalance_now)
}

#' Tagesschritt: Splits und Reverse Splits
#'
#' Zweck: Kursreihen von Assets ohne Bestand umrechnen, Splits gehaltener Assets buchen und
#' Bruchteile (fractions = FALSE) als Spitzenausgleich verkaufen.
#' Eingabe: sim_mem, time, active_assets, fl, cfg, split_thresh, details.
#' Ausgabe: sim_mem.
#' @keywords internal
#' @noRd
.sim_day_split <- function(sim_mem, time, active_assets, fl, cfg, split_thresh, details) {
  flag_assets <- fl$flag_assets; flag_date <- fl$flag_date; tax_regimes <- fl$tax_regimes
  fractions <- cfg$fractions; tax_mode <- cfg$tax_mode; tax_rate <- cfg$tax_rate
  effective_tax_rate <- cfg$effective_tax_rate; marginal_tax_rate <- cfg$marginal_tax_rate
  private_sale_threshold <- cfg$private_sale_threshold; use_sparer_pauschbetrag <- cfg$use_sparer_pauschbetrag
  # A7-07: Ein Asset ohne Bestand (spaeterer Start, Signal-Asset in Cash) splittet trotzdem: seine Kursreihe
  # wird wie in calculate_split_flags umgerechnet, sonst entfiele der Split endgueltig und spaetere Kaeufe
  # erfolgten zu Kursen ueber der oberen Schwelle (die vorab bestimmten Split-Termine passten nicht mehr)
  for(name in setdiff(flag_assets, active_assets[vapply(active_assets, function(nm) sim_mem[["status"]][[nm]][["count"]] > 0, logical(1))])){
    px0 <- sim_mem[["market"]][[name]][["asset_price"]][time]
    if (px0 > split_thresh[[2]] || px0 < split_thresh[[1]]) {
      sim_mem[["market"]][[name]][["asset_price"]] <- sim_mem[["market"]][[name]][["asset_price"]] / (px0 / 100)
      if (details) cat(sprintf("Split-Ereignis:\t%s ohne Bestand: Kursreihe %s %s am %s\n", name,
                               if (px0 > split_thresh[[2]]) "1 :" else ": 1",
                               format(if (px0 > split_thresh[[2]]) px0 / 100 else 100 / px0, digits = 5), flag_date[time]))
    }
  }
  for(name in active_assets){
    if(sim_mem[["status"]][[name]][["count"]] > 0){
      split_price <- sim_mem[["market"]][[name]][["asset_price"]][time]

      if(split_price > split_thresh[[2]]){
        sim_mem <- perform_asset_split(input = sim_mem, name = name, ratio = split_price / 100,
                                       type = "forward", index = time,                                        
fractions = fractions,
details = details,
current_date = flag_date[time]
        )
      }

      if(split_price < split_thresh[[1]]){
        sim_mem <- perform_asset_split(input = sim_mem, name = name, ratio = 100 / split_price,
                                       type = "reverse", index = time,                                        
fractions = fractions,
details = details,
current_date = flag_date[time]
        )
      }

      # R1-05: Bruchteile (fractions = FALSE) einmalig als Spitzenausgleich zum Kurs
      # des Split-Tages verkaufen (ohne Spread/Ordergebuehr; FIFO, ggf. steuerpflichtig)
      split_cnt <- sim_mem[["status"]][[name]][["count"]]
      split_frac <- split_cnt - floor(split_cnt + 1e-9)
      if (!fractions && split_frac > 1e-9) {
        fee_keep <- .fee_env$current; .fee_env$current <- NULL
        sim_mem <- perform_trade_sell(input = sim_mem, count = split_frac, name = name, index = time,
          tax_mode = tax_mode, tax_rate = tax_rate, effective_tax_rate = effective_tax_rate,
          marginal_tax_rate = marginal_tax_rate, private_sale_threshold = private_sale_threshold,
          use_sparer_pauschbetrag = use_sparer_pauschbetrag, tax_regime = tax_regimes[[name]],
          reason = "Split:", spread = 0, details = details)
        .fee_env$current <- fee_keep
      }
    }
  }

  .sim_total_report_cpp(input = sim_mem, assets = flag_assets, index = time)

  sim_mem
}

#' Tagesschritt: Sparplan (Dollar-Cost-Averaging)
#'
#' Zweck: die Sparrate des Tages nach Strategie-Gewichten (bzw. mit balance_dca zuerst nach
#' Wert-Defiziten) auf die aktiven Assets verteilen.
#' Eingabe: sim_mem, time, active_assets, fl, cfg, strategy, balance_dca, details.
#' Ausgabe: sim_mem.
#' @keywords internal
#' @noRd
.sim_day_dca <- function(sim_mem, time, active_assets, fl, cfg, strategy, balance_dca, details) {
  flag_assets <- fl$flag_assets; flag_date <- fl$flag_date; flag_dca_n <- fl$flag_dca_n
  dca_value <- cfg$dca_value
  dca_amount <- dca_value * flag_dca_n[time]   # R1-16: mehrere Termine am selben Handelstag
  # R-1: DCA-Verteilung nach STRATEGIE-Gewichten (asset_share), renormiert
  # ueber die derzeit aktiven Assets (inkl. Cash-Reserven signalbedingt
  # wartender (aktivierter!) Signal-Assets — Gleichbehandlung nach Zielgewicht). Ohne balance_dca:
  # fixer Split (70:30 bleibt 70:30, egal wie das Depot driftet).
  strat_w <- sapply(active_assets, function(name) strategy[[name]][["asset_share"]])
  strat_w <- strat_w / sum(strat_w, na.rm = TRUE)

  if(balance_dca && length(active_assets) > 1){
    # A7-06: Wert-Defizite zum Tageskurs (nicht mit den Vortageswerten) bestimmen
    .sim_total_report_cpp(input = sim_mem, assets = flag_assets, index = time)
    # R-1 (balance_dca): Rate schliesst zuerst die WERT-Defizite zu den
    # Strategie-Zielen (Rebalancing-Wirkung); ein etwaiger Rest wird nach
    # Strategie-Gewichten verteilt.
    totals_now <- sapply(active_assets, function(name) sim_mem[["status"]][[name]][["total"]])
    desired    <- strat_w * (sum(totals_now, na.rm = TRUE) + dca_amount)
    deficit    <- pmax(0, desired - totals_now)
    alloc <- if (sum(deficit) > dca_amount) {
      dca_amount * deficit / sum(deficit)
    } else {
      deficit + (dca_amount - sum(deficit)) * strat_w
    }
    alloc <- setNames(as.numeric(alloc), active_assets)
    for(name in active_assets){
      .sim_dca_flows_cpp(input = sim_mem, name = name, flows = alloc[[name]], index = time)
    }
  } else {
    for(name in active_assets){
      .sim_dca_flows_cpp(input = sim_mem, name = name, flows = strat_w[[name]] * dca_amount, index = time)
    }
  }
  if(details){
    flow_values <- sapply(active_assets, function(name) sim_mem[["report"]][[name]][["flows"]][time])
    placeholder <- paste(sprintf("%s %%.2f EUR", names(flow_values)), collapse = "; ")
    format_text <- sprintf("Einzahlung:\t%%.2f EUR in das Depot am %%s\n\t\t=> %s\n", placeholder)
    cat(do.call(sprintf, c(list(format_text, dca_amount), list(flag_date[time]), as.list(flow_values))))
  }

  .sim_total_report_cpp(input = sim_mem, assets = flag_assets, index = time)

  sim_mem
}

#' Tagesschritt: Handel nach Signalen
#'
#' Zweck: Kauf- und Verkaufssignale der aktiven Assets ausfuehren.
#' Eingabe: sim_mem, time, active_assets, fl, cfg, act, details.
#' Ausgabe: list(sim_mem, traded = TRUE, wenn gehandelt und der Tagesbericht neu berechnet wurde).
#' @keywords internal
#' @noRd
.sim_day_trade <- function(sim_mem, time, active_assets, fl, cfg, act, details) {
  flag_assets <- fl$flag_assets; tax_regimes <- fl$tax_regimes; spread_rates <- fl$spread_rates
  tax_mode <- cfg$tax_mode; tax_rate <- cfg$tax_rate; effective_tax_rate <- cfg$effective_tax_rate
  marginal_tax_rate <- cfg$marginal_tax_rate; private_sale_threshold <- cfg$private_sale_threshold
  use_sparer_pauschbetrag <- cfg$use_sparer_pauschbetrag
  .buy_with_fee <- act$.buy_with_fee
  trade_event <- FALSE

  for(name in active_assets){   # P-1/O-1: nur aktive Assets handeln
    flag_buy <- calculate_buy_signal(input = sim_mem, name = name, index = time)
    flag_sell <- calculate_sell_signal(input = sim_mem, name = name, index = time)

    if(flag_buy){
      # R1-04/R2-01: Sparplankauf (Buy-and-Hold am Sparplantag) mit dca_fee, sonst order_fee
      sim_mem <- .buy_with_fee(sim_mem, name, time, "Handelssignal:")
      trade_event <- TRUE
    }

    if(flag_sell){
      sim_mem <- perform_trade_sell(input = sim_mem, name = name, index = time, tax_mode = tax_mode, tax_rate = tax_rate,
        effective_tax_rate = effective_tax_rate,
        marginal_tax_rate = marginal_tax_rate,
        private_sale_threshold = private_sale_threshold,
        use_sparer_pauschbetrag = use_sparer_pauschbetrag,
        tax_regime = tax_regimes[[name]],
        reason = "Handelssignal:", spread = spread_rates[[name]], details = details)
      trade_event <- TRUE
    }
  }

  if(trade_event){
    .sim_total_report_cpp(input = sim_mem, assets = flag_assets, index = time)
  }

  list(sim_mem = sim_mem, traded = trade_event)
}

#' Tagesschritt: Rebalancing
#'
#' Zweck: Zielgewichte (ggf. aus event_weight) bestimmen, Signal-Assets ein- bzw. aussteigen lassen,
#' bei Ueberschreiten der Schwelle uebergewichtete Assets verkaufen und untergewichtete kaufen,
#' Restcash reinvestieren.
#' Eingabe: sim_mem, time, active_assets, fl, cfg, act, data (Spalten fuer event_weight), event_weight,
#' details.
#' Ausgabe: sim_mem.
#' @keywords internal
#' @noRd
.sim_day_rebalance <- function(sim_mem, time, active_assets, fl, cfg, act, data, event_weight, details) {
  flag_assets <- fl$flag_assets; flag_date <- fl$flag_date; flag_event <- fl$flag_event
  asset_starts <- fl$asset_starts; tax_regimes <- fl$tax_regimes; spread_rates <- fl$spread_rates
  balance_thresh <- cfg$balance_thresh; balance_thresh_type <- cfg$balance_thresh_type
  fractions <- cfg$fractions; tax_mode <- cfg$tax_mode; tax_rate <- cfg$tax_rate
  effective_tax_rate <- cfg$effective_tax_rate; marginal_tax_rate <- cfg$marginal_tax_rate
  private_sale_threshold <- cfg$private_sale_threshold; use_sparer_pauschbetrag <- cfg$use_sparer_pauschbetrag
  .buy_with_fee <- act$.buy_with_fee
  active_targets <- sapply(active_assets, function(name){sim_mem[["status"]][[name]][["actual"]]})
  active_targets <- active_targets / sum(active_targets, na.rm = TRUE)

  # === NEU: ereignisgetriebene Ziel-Gewichte ueberschreiben (nur an Event-Tagen) ===
  # Greift nur, wenn event_weight gesetzt ist UND dieser Tag ein Event-Tag ist.
  # Veraendert ausschliesslich das lokale Ziel-Gewicht dieses Rebalancing-Laufs,
  # nicht die status-Buchhaltung. Die Band-/Gewichts-Logik bleibt im Datensatz.
  if (!is.null(event_weight) && isTRUE(flag_event[time])) {
    ow <- sapply(active_assets, function(nm){
      col <- event_weight[[nm]]
      if (is.null(col)) NA_real_ else as.numeric(data[[col]][time])
    })
    if (all(is.finite(ow)) && sum(ow) > 0) {
      active_targets <- ow / sum(ow)
      names(active_targets) <- active_assets
    }
  }

  # V-2/Fix 3: Signal-Gate (Cash-Reserve-Design, siehe Notiz im Patcher)
  signal_cash_only <- character(0)
  for(name in active_assets){
    if(sim_mem[["assets"]][[name]][["style"]] == "signal"){
      .has_pos  <- sim_mem[["status"]][[name]][["count"]] > 0
      .sig_buy  <- isTRUE(sim_mem[["market"]][[name]][["signal_buy"]][time])
      .sig_sell <- isTRUE(sim_mem[["market"]][[name]][["signal_sell"]][time])
      if(.has_pos && .sig_sell){
        sim_mem <- perform_trade_sell(input = sim_mem, name = name, index = time,
          tax_mode = tax_mode, tax_rate = tax_rate,
          effective_tax_rate = effective_tax_rate,
          marginal_tax_rate = marginal_tax_rate,
          private_sale_threshold = private_sale_threshold,
          use_sparer_pauschbetrag = use_sparer_pauschbetrag,
          tax_regime = tax_regimes[[name]],
          reason = "Rebalancing/Signal-Ausstieg:",
          spread = spread_rates[[name]], details = details)
        signal_cash_only <- c(signal_cash_only, name)
      } else if(!.has_pos && .sig_buy){
        # Signal-Entry aus der eigenen Cash-Reserve; danach normale Teilnahme
        sim_mem <- perform_trade_buy(input = sim_mem, name = name, index = time,
          reason = "Rebalancing/Signal-Einstieg:",
          spread = spread_rates[[name]], fractions = fractions, details = details)
      } else if(!.has_pos && !.sig_buy){
        signal_cash_only <- c(signal_cash_only, name)
      }
    }
  }

  # Gleichbehandlung: Ist-Gewichte total-basiert (worth+money) fuer ALLE
  # A7-06: Ist-Gewichte, Abweichung und Depotwert zum Tageskurs vor dem Handel (nach Sparrate und
  # Signal-Ein-/Ausstieg des Tages); vorher galten die Werte des Vortags, gehandelt wurde zum Tageskurs
  .sim_total_report_cpp(input = sim_mem, assets = flag_assets, index = time)
  actual_weights <- sapply(active_assets, function(name){sim_mem[["status"]][[name]][["differ"]]})

  new_asset <- any(asset_starts == flag_date[time])
  force_rebalance <- new_asset

  if(force_rebalance && details){
    new_assets <- flag_assets[asset_starts == flag_date[time]]
    cat(sprintf("Rebalancing:\tErzwungenes Rebalancing am %s wegen neu handelbarer Assets: %s\n",
        flag_date[time], paste(new_assets, collapse = ", ")))
  }

  event_rebalance <- FALSE

  if(force_rebalance){
    event_rebalance <- TRUE
  } else if(is.null(balance_thresh)){
    event_rebalance <- TRUE
  } else {
    deviations <- if (balance_thresh_type == "relative") {
      abs(actual_weights / active_targets - 1)
    } else {
      abs(active_targets - actual_weights)
    }
    max_deviation <- max(deviations, na.rm = TRUE)
    event_rebalance <- (max_deviation > balance_thresh)

    if(details){
      if(event_rebalance){
        cat(sprintf("Rebalancing:\tRebalancing am %s (max. Abweichung: %.2f%% > Schwelle: %.2f%%)\n",
            flag_date[time], max_deviation * 100, balance_thresh * 100))

        for(i in seq_along(active_assets)){
          name <- active_assets[i]
          dev <- deviations[i]
          
          if(dev > balance_thresh){
            cat(sprintf("\t\t=> %s: Ziel=%.1f%%, Ist=%.1f%%, Abweichung=%.2f%%\n",
                name, active_targets[i]*100, actual_weights[i]*100, dev*100))
          }
        }
      } else {
        cat(sprintf("Rebalancing:\tKein Rebalancing am %s (max. Abweichung: %.2f%% < Schwelle: %.2f%%)\n",
            flag_date[time], max_deviation * 100, balance_thresh * 100))
        }
      }
    }

    if(event_rebalance){
      differ_weights <- active_targets - actual_weights
      total_strategy <- sum(sapply(sim_mem[["status"]][active_assets], function(x) x[["total"]]), na.rm = TRUE)

      transfer_pool <- 0
      transfer_value <- abs(differ_weights * total_strategy)

      # ════════════════════════════════════════════════════════════════
      # BUG-4/5 FIX: Rebalancing ohne Signal-Abhängigkeit,
      # korrekte Richtung: differ < 0 = übergewichtet → verkaufen,
      #                    differ > 0 = untergewichtet → kaufen
      # ════════════════════════════════════════════════════════════════
      
      # PHASE 1: Übergewichtete Assets verkaufen → Pool aufbauen
      for(name in names(differ_weights[differ_weights < 0])){
        # R4-06: Cash, das schon beim Asset liegt (z. B. Sparrate des Tages), deckt den Transfer
        # zuerst; verkauft wird nur der Rest (sonst Verkauf und Rueckkauf am selben Tag)
        sell_target <- transfer_value[name] - max(0, sim_mem[["status"]][[name]][["money"]])
        if(sim_mem[["status"]][[name]][["count"]] > 0 && sell_target > 0){
          # R3a-04: Steuerschaetzung wie beim Verkauf (effektiver Satz, Verlusttopf, Pauschbetrag,
          # § 19-Anrechnung), damit kein Ueberverkauf mit Rueckkauf am selben Tag entsteht
          sell_result <- calculate_sell_count(
            input = sim_mem, name = name, target = sell_target, 
            index = time, spread = spread_rates[[name]], 
            fractions = fractions, tax_mode = tax_mode, tax_rate = effective_tax_rate,
            marginal_tax_rate = marginal_tax_rate,
            tax_regime = tax_regimes[[name]])
          
          sim_mem <- perform_trade_sell(
            input = sim_mem, name = name, 
            count = sell_result[["sell_count"]], 
            price = sell_result[["fifo_price"]], 
            index = time, tax_mode = tax_mode, tax_rate = tax_rate,
            effective_tax_rate = effective_tax_rate,
            marginal_tax_rate = marginal_tax_rate,
            private_sale_threshold = private_sale_threshold,
            use_sparer_pauschbetrag = use_sparer_pauschbetrag,
            tax_regime = tax_regimes[[name]],
            reason = "Rebalancing:", 
            spread = spread_rates[[name]], details = details)
        }
        
        # Cash aus diesem Asset in den Transfer-Pool
        available_cash <- min(sim_mem[["status"]][[name]][["money"]], transfer_value[name])
        transfer_pool <- transfer_pool + available_cash
        sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] - available_cash
        
        if(details){
          cat(sprintf("\t\t%.2f EUR von %s in den Rebalancing-Topf\n", 
                      available_cash, name))
        }
      }
      
      # PHASE 2: Untergewichtete Assets kaufen → Pool verbrauchen
      for(name in names(differ_weights[differ_weights > 0])){
        allocation <- min(transfer_value[name], transfer_pool)
        if(allocation > 0){
          sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] + allocation
          transfer_pool <- transfer_pool - allocation
          
          if(details){
            cat(sprintf("Rebalancing:\t%.2f EUR aus dem Rebalancing-Topf an %s\n", 
                        allocation, name))
          }
          
          if (name %in% signal_cash_only) {
            # Fix 3: signalbedingt wartendes Signal-Asset — Zielgewicht als CASH-Reserve
            # auffuellen, KEIN Aktienkauf (Pool wurde damit um den Betrag
            # des inaktiven Assets reduziert).
            if(details){
              cat(sprintf("\t\t=> %s h\u00e4lt %.2f EUR als Cash-Reserve (Signal inaktiv)\n",
                          name, sim_mem[["status"]][[name]][["money"]]))
            }
          } else {
            sim_mem <- perform_trade_buy(
              input = sim_mem, name = name, index = time,
              reason = "Rebalancing:",
              spread = spread_rates[[name]],
              fractions = fractions, details = details)
          }
        }
      }

      # Restliches Cash im Pool proportional verteilen
      if(transfer_pool > 0.01){
        if(details){
          cat(sprintf("\t\tRestverteilung von %.2f EUR aus dem Rebalancing-Topf\n", transfer_pool))
        }

        for(name in active_assets){
          redistribution <- active_targets[[name]] * transfer_pool
          sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] + redistribution

          if(details){
            cat(sprintf("\t\t=> %.2f EUR an %s\n", redistribution, name))
          }
        }
      }
    }

  # Fix 5: Restcash (DCA-Zufluss, Redistribution) noch am Rebalance-Tag
  # reinvestieren — ausser den Cash-Reserven signalbedingt wartender Signal-Assets.
  for (name in active_assets) {
    if (!(name %in% signal_cash_only) &&
        sim_mem[["status"]][[name]][["money"]] > 0.005 &&
        (sim_mem[["assets"]][[name]][["style"]] != "signal" ||
         sim_mem[["status"]][[name]][["count"]] > 0)) {
      # R1-04: am Sparplantag ist der Restcash eines Buy-and-Hold-Assets die Sparrate -> dca_fee
      # (R2-01: am ersten Tag das Startkapital mit order_fee)
      sim_mem <- .buy_with_fee(sim_mem, name, time, "Rebalancing:")
    }
  }

  .sim_total_report_cpp(input = sim_mem, assets = flag_assets, index = time)

  sim_mem
}

#' Tagesschritt: Freibetrag ausschoepfen (harvest_mode)
#'
#' Zweck: je aktivem Asset Gewinne bis zum Freibetrag realisieren und sofort wieder kaufen.
#' Eingabe: sim_mem, time, active_assets, fl, cfg, harvest_loss_pot, details.
#' Ausgabe: sim_mem.
#' @keywords internal
#' @noRd
.sim_day_harvest <- function(sim_mem, time, active_assets, fl, cfg, harvest_loss_pot, details) {
  flag_assets <- fl$flag_assets; tax_regimes <- fl$tax_regimes; spread_rates <- fl$spread_rates
  fees_on <- cfg$fees_on; fee_order <- cfg$fee_order; fractions <- cfg$fractions
  use_sparer_pauschbetrag <- cfg$use_sparer_pauschbetrag; tax_mode <- cfg$tax_mode; tax_rate <- cfg$tax_rate
  effective_tax_rate <- cfg$effective_tax_rate; marginal_tax_rate <- cfg$marginal_tax_rate
  private_sale_threshold <- cfg$private_sale_threshold
  if (fees_on) .fee_env$current <- fee_order
  for (name in active_assets) {
    sim_mem <- perform_gain_harvest(sim_mem, name, time, tax_regimes[[name]], spread_rates[[name]],
                                    fractions, harvest_loss_pot, use_sparer_pauschbetrag,
                                    tax_mode, tax_rate, effective_tax_rate, marginal_tax_rate,
                                    private_sale_threshold, details)
  }
  .sim_total_report_cpp(input = sim_mem, assets = flag_assets, index = time)

  sim_mem
}

#' Tagesschritt: Vorabpauschale am 31.12. festsetzen
#'
#' Zweck: je Fonds-Asset mit Bestand die Vorabpauschale je Lot berechnen und speichern und die
#' Festsetzung in totals$vp_pending ablegen (Zufluss und Steuer am ersten Handelstag des Folgejahres).
#' Eingabe: sim_mem, time, fl, cfg, liquidate, details.
#' Ausgabe: sim_mem.
#' @keywords internal
#' @noRd
.sim_day_assess_vp <- function(sim_mem, time, fl, cfg, liquidate, details) {
  flag_assets <- fl$flag_assets; flag_date <- fl$flag_date; flag_filled <- fl$flag_filled
  flag_liquidate <- fl$flag_liquidate; tax_regimes <- fl$tax_regimes; tax_mode <- cfg$tax_mode
  if (tax_mode == "person" && !(liquidate && flag_liquidate[time])) {
    for (name in flag_assets) {
      
      # Vorabpauschale nur für ETFs (investment_fund) mit Bestand > 0
      tax_regime <- tax_regimes[[name]]
      
      if (tax_regime == "investment_fund" && sim_mem[["status"]][[name]][["count"]] > 0) {
        
        # Vorabpauschale berechnen (reine Lesefunktion, keine Seiteneffekte)
        vp_result <- calculate_flat_rate(
          input = sim_mem, 
          name = name, 
          index = time, 
          dates = flag_date,
          tax_regime = tax_regime,
          filled = flag_filled
        )
        flat_rate <- vp_result$total_vp
        
        # VP pro Lot in sim_mem speichern (direkt by-reference, kein Copy-on-Modify)
        # Dies ist der Fix für den kritischen VP-Bug: Die Schreiboperation erfolgt
        # im Aufrufer auf sim_mem, nicht in calculate_flat_rate auf einer lokalen Kopie.
        for (vp_k in seq_along(vp_result$lot_indices)) {
          vp_i <- vp_result$lot_indices[vp_k]
          current_vp <- sim_mem[["trades"]][[name]][["buys"]][[vp_i]][["vp"]] %||% 0
          sim_mem[["trades"]][[name]][["buys"]][[vp_i]][["vp"]] <- current_vp + vp_result$lot_vps[vp_k]
        }
        
        if (flat_rate > 0) {
          # Ablage in totals (status wird vom C++-Market-Update mit festem
          # Feldsatz neu aufgebaut und wuerde ad-hoc-Felder verwerfen)
          pend <- sim_mem[["totals"]][["vp_pending"]]
          if (is.null(pend)) pend <- list()
          pend[[length(pend) + 1L]] <- list(name = name, flat_rate = flat_rate,
                                            bonus = sim_mem[["assets"]][[name]][["bonus"]],
                                            assessment_date = flag_date[time])
          sim_mem[["totals"]][["vp_pending"]] <- pend
          if (details) {
            cat(sprintf("Steuerereignis:\tVorabpauschale %s: %.2f EUR festgesetzt am %s (Zufluss und Steuer am ersten Handelstag des Folgejahres)\n",
                        name, flat_rate, flag_date[time]))
          }
        }
      }
    }
  }
  
  .sim_total_report_cpp(input = sim_mem, assets = flag_assets, index = time)

  sim_mem
}

#' Tagesschritt: Fondskosten (tax_mode = "funds")
#'
#' Zweck: laufende Fondskosten und Bonusgebuehr berechnen und je Asset aus dem Bargeld (fehlender
#' Betrag per Teilverkauf) abziehen.
#' Eingabe: sim_mem, time, fl, act, funds_fee, bonus_fee, details.
#' Ausgabe: sim_mem.
#' @keywords internal
#' @noRd
.sim_day_fund_fee <- function(sim_mem, time, fl, act, funds_fee, bonus_fee, details) {
  flag_assets <- fl$flag_assets; flag_date <- fl$flag_date
  .raise_cash <- act$.raise_cash
  .sim_total_report_cpp(input = sim_mem, assets = flag_assets, index = time)   # Tageswerte
  result_fees <- calculate_fund_fees(
    input = sim_mem, index = time, dates = flag_date, assets = flag_assets,
    funds_fee = funds_fee, bonus_fee = bonus_fee, details = details)
  sim_mem[["totals"]][["total_value"]] <- result_fees[["total_value"]]
  for (name in flag_assets) {
    fee_i <- result_fees[["asset_fees"]][[name]]
    if (!is.finite(fee_i) || fee_i <= 0) next
    if (sim_mem[["status"]][[name]][["money"]] < fee_i)
      sim_mem <- .raise_cash(sim_mem, name, fee_i, time, "Fondskosten:")
    paid <- min(fee_i, max(0, sim_mem[["status"]][[name]][["money"]]))
    sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] - paid
    if (details) {
      cat(sprintf("\t\t=> %.2f EUR Geb\u00fchren von %s abgezogen\n", paid, name))
    }
    sim_mem[["trades"]][[name]][["fee_count"]] <- sim_mem[["trades"]][[name]][["fee_count"]] + 1
    sim_mem[["trades"]][[name]][["fees"]][[sim_mem[["trades"]][[name]][["fee_count"]]]] <-
      list(event_date = flag_date[time], event_type = "Fees", fees_paid = paid)
  }
  .sim_total_report_cpp(input = sim_mem, assets = flag_assets, index = time)

  sim_mem
}

#' Tagesschritt: Liquidation
#'
#' Zweck: alle Positionen verkaufen; bei tax_mode = "funds" die Steuer auf den Gesamtgewinn abziehen.
#' Eingabe: sim_mem, time, fl, cfg, details.
#' Ausgabe: sim_mem.
#' @keywords internal
#' @noRd
.sim_day_liquidate <- function(sim_mem, time, fl, cfg, details) {
  flag_assets <- fl$flag_assets; flag_date <- fl$flag_date; tax_regimes <- fl$tax_regimes
  spread_rates <- fl$spread_rates; start_value <- cfg$start_value
  tax_mode <- cfg$tax_mode; tax_rate <- cfg$tax_rate; effective_tax_rate <- cfg$effective_tax_rate
  marginal_tax_rate <- cfg$marginal_tax_rate; private_sale_threshold <- cfg$private_sale_threshold
  use_sparer_pauschbetrag <- cfg$use_sparer_pauschbetrag
  for(name in flag_assets){
    if(sim_mem[["status"]][[name]][["count"]] > 0){
      tax_type <- ifelse(tax_mode == "person", "person", "none")
      sim_mem <- perform_trade_sell(input = sim_mem, name = name, index = time, 
        tax_mode = tax_type, tax_rate = tax_rate, 
        effective_tax_rate = effective_tax_rate,
        marginal_tax_rate = marginal_tax_rate,
        private_sale_threshold = private_sale_threshold,
        use_sparer_pauschbetrag = use_sparer_pauschbetrag,
        tax_regime = tax_regimes[[name]],
        reason = "Liquidation:", spread = spread_rates[[name]], details = details)
      if (sim_mem[["status"]][[name]][["count"]] > 0)   # R1-23
        warning(sprintf("simulation: liquidate = TRUE: Position '%s' (Wert %.2f EUR) wurde nicht verkauft, weil die Ordergeb\u00fchr den Erl\u00f6s \u00fcbersteigt.",
                        name, sim_mem[["status"]][[name]][["worth"]]), call. = FALSE)
    }
  }
  
  if (tax_mode == "funds") {
    # R1-02/R1-03: Steuer auf den Gesamtgewinn an jedem Liquidationstag (auch am 31.12.;
    # die Fondskosten sind oben bereits belastet). Gewinn = Endwert - Startkapital - Einzahlungen
    .sim_total_report_cpp(input = sim_mem, assets = flag_assets, index = time)
    final_value <- sum(vapply(flag_assets, function(x) sim_mem[["status"]][[x]][["total"]], numeric(1)), na.rm = TRUE)
    deposits <- sum(vapply(flag_assets, function(x) sum(sim_mem[["report"]][[x]][["flows"]][seq_len(time)]), numeric(1)))
    total_gains <- final_value - start_value - deposits

    if(total_gains > 0){
      total_taxes <- total_gains * tax_rate
      cash <- vapply(flag_assets, function(x) max(0, sim_mem[["status"]][[x]][["money"]]), numeric(1))
      tax_weights <- if (sum(cash) > 0) cash / sum(cash) else rep(1 / length(flag_assets), length(flag_assets))
      names(tax_weights) <- flag_assets

      for(name in flag_assets){
        tax_per_asset <- min(total_taxes * tax_weights[[name]], cash[[name]])
        sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] - tax_per_asset
        sim_mem[["totals"]][["total_taxes"]] <- sim_mem[["totals"]][["total_taxes"]] + tax_per_asset
      }

      if(details){
        cat(sprintf("Liquidation:\tSteuern %.2f EUR auf den Gesamtgewinn von %.2f EUR am %s\n", total_taxes, total_gains, flag_date[time]))
      }
    }
  }

  .sim_total_report_cpp(input = sim_mem, assets = flag_assets, index = time)

  sim_mem
}

#' Phase 5 von simulation(): Abschluss des letzten Jahres
#'
#' Zweck: Jahresabschluss nach dem letzten Datentag (Vorabpauschale ohne weiteren Handelstag,
#' Tarifweg, offene Paragraf-23-Steuer, Erstattung aus der Guenstigerpruefung) und Tagesbericht des
#' letzten Tages; nur tax_mode = "person".
#' Eingabe: sim_mem, fl, cfg, act, stopp_date, details.
#' Ausgabe: sim_mem.
#' @keywords internal
#' @noRd
.sim_close_years <- function(sim_mem, fl, cfg, act, stopp_date, details) {
  flag_assets <- fl$flag_assets; n_total_days <- fl$n_total_days
  tax_mode <- cfg$tax_mode; marginal_tax_rate <- cfg$marginal_tax_rate
  private_sale_threshold <- cfg$private_sale_threshold; sparer_pauschbetrag <- cfg$sparer_pauschbetrag
  use_sparer_pauschbetrag <- cfg$use_sparer_pauschbetrag; soli_factor_income <- cfg$soli_factor_income
  effective_tax_rate <- cfg$effective_tax_rate; church_k <- cfg$church_k; tariff_env <- cfg$tariff_env
  .vp_taxes <- act$.vp_taxes; .pay_tax <- act$.pay_tax; .settle_vp <- act$.settle_vp
  .settle_p23 <- act$.settle_p23; .settle_gp <- act$.settle_gp; .gp_pending <- act$.gp_pending

  # === NEU: Finales Jahr abschließen ===
  # Vorabpauschale ohne weiteren Handelstag (Simulation endet am 31.12. oder nur mit
  # aufgefuellten Tagen danach): so rechnen, als begaenne das Folgejahr (Jahresabschluss
  # mit Verlusttopf und Erstattung, Pauschbetrag voll), und die Steuer am letzten
  # Simulationstag belasten. R4-02: Der finale Jahresabschluss wird vollstaendig uebernommen
  # (eine § 20-Erstattung wird dem Cash gutgeschrieben und landet im Endwert, wie bei jedem
  # Jahreswechsel); danach wird der Tagesbericht des letzten Tages immer neu berechnet.
  final_year_change <- function(sim_mem) handle_year_change(
      input = sim_mem,
      current_date = as.Date(paste0(as.integer(format(stopp_date, "%Y")) + 1, "-01-01")),
      marginal_tax_rate = marginal_tax_rate,
      private_sale_threshold = private_sale_threshold,
      sparer_pauschbetrag = sparer_pauschbetrag,
      use_sparer_pauschbetrag = use_sparer_pauschbetrag,
      soli_factor_income = soli_factor_income,
      effective_tax_rate = effective_tax_rate,
      details = details, church_factor = church_k, tariff_env = tariff_env
    )
  if (tax_mode == "person") {
    if (length(sim_mem[["totals"]][["vp_pending"]])) {
      vp_year <- as.integer(format(sim_mem[["totals"]][["vp_pending"]][[1]][["assessment_date"]], "%Y"))
      prepaid <- NULL
      if (sim_mem[["totals"]][["current_year"]] <= vp_year) {   # Jahr der Festsetzung noch offen
        # A7-11: Ende am 31.12.: die Steuer auf die VP (Toepfe des Zuflussjahres) wird am letzten Tag gezahlt;
        # ein Zwangsverkauf dafuer findet in diesem Jahr statt und gehoert mit Gewinn, Pauschbetrag und
        # Verlusttopf in dieses Jahr. Betrag vorab auf einer Kopie bestimmen (Jahresabschluss ohne den
        # Verkauf), im laufenden Jahr zahlen, danach das Jahr schliessen und die VP buchen (Differenz
        # zur endgueltigen Steuer, z. B. wenn der Verkaufsgewinn den Verlustvortrag mindert, wird ausgeglichen)
        dry <- unserialize(serialize(sim_mem, NULL))
        dry <- suppressWarnings(handle_year_change(
          input = dry, current_date = as.Date(paste0(as.integer(format(stopp_date, "%Y")) + 1, "-01-01")),
          marginal_tax_rate = marginal_tax_rate, private_sale_threshold = private_sale_threshold,
          sparer_pauschbetrag = sparer_pauschbetrag, use_sparer_pauschbetrag = use_sparer_pauschbetrag,
          soli_factor_income = soli_factor_income, effective_tax_rate = effective_tax_rate,
          details = FALSE, church_factor = church_k, tariff_env = NULL))
        pend <- sim_mem[["totals"]][["vp_pending"]]
        prepaid <- vapply(.vp_taxes(dry, pend)$res, function(x) x$tax, numeric(1))
        for (j in seq_along(pend)) if (prepaid[j] > 0)
          sim_mem <- .pay_tax(sim_mem, pend[[j]][["name"]], prepaid[j], n_total_days, "Vorabpauschale")
        sim_mem <- final_year_change(sim_mem)                 # R4-02: vollen sim_mem (Erstattung als Cash)
      }
      sim_mem <- .settle_vp(sim_mem, n_total_days, prepaid = prepaid)
    }
    sim_mem <- final_year_change(sim_mem)                     # ohne offene VP (sonst ohne Wirkung)
    # R3a-02: § 23-Steuer ohne weiteren Abrechnungstag (Jahr des letzten Simulationstags bzw.
    # Abrechnungstag nach dem Datenende) am letzten Tag aus dem Depot zahlen
    if (!is.null(tariff_env)) {
      # Vorabpauschale nach dem letzten Jahresabschluss (Zufluss im Folgejahr, ohne weiteren Tag): Veranlagung
      # dieses Jahres mit Guenstigerpruefung nur, wenn dafuer ein zvE vorliegt (Zahl fuer alle Jahre oder Jahr angegeben)
      y_last <- sim_mem[["totals"]][["current_year"]]
      if (isTRUE(tariff_env$use_gp) && y_last > as.integer(format(stopp_date, "%Y")) &&
          (sim_mem[["totals"]][["cgt_base_taxed_ytd"]] %||% 0) > 0) {
        D <- .tariff_close(tariff_env, y_last, 0, sim_mem[["totals"]][["cgt_base_taxed_ytd"]], effective_tax_rate, details)
        sim_mem <- .tariff_book(sim_mem, tariff_env, D)
      }
    }
    if (length(sim_mem[["totals"]][["p23_due"]])) sim_mem <- .settle_p23(sim_mem, n_total_days)
    if (!is.null(tariff_env) && .gp_pending()) sim_mem <- .settle_gp(sim_mem, n_total_days)
    .sim_total_report_cpp(input = sim_mem, assets = flag_assets, index = n_total_days)
  }
  # === Ende neu ===

  sim_mem
}
