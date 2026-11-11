# =============================================================================
# simulation(), Phase 2: Datenvorbereitung, Zentralstruktur sim_mem, Termine und Flags
# =============================================================================

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
  
  # Basiszins-Spalte (seit 1.6.4): kein Faktor (Entscheidung 15; bis 1.6.3 still mit Warnung umgewandelt), nur Zahlen
  # (wie risk_free, Entscheidungen 2 und F5: Text ist ein Fehler; eine Spalte nur aus NA zaehlt als Zahlenspalte,
  # Entscheidung 14) und kein NA (Entscheidung 17; bis 1.6.3 zaehlte NA als 0), auch nicht in einer Spalte nur aus NA
  # (Entscheidung 42)
  if (isTRUE(base_rate_flex) && is.character(base_rate_data) && length(base_rate_data) == 1L &&
      !is.na(base_rate_data) && base_rate_data %in% names(data)) {
    br0 <- data[[base_rate_data]]
    chk_col_nofactor(data, base_rate_data, "simulation")
    if (!(is.numeric(br0) || (is.logical(br0) && all(is.na(br0)))))
      chk_stop("spalte_typ", "simulation", base_rate_data, chk_msg("typ.numerisch"))
    chk_col_nona(data, base_rate_data, "simulation", chk_msg("hinweis.basiszins"))
  }
  # Prozent-Konvention auch fuer die Basiszins-Spalte (Median, gleiche Schwelle wie base_rate)
  if (isTRUE(base_rate_flex) && is.character(base_rate_data) && length(base_rate_data) == 1L &&
      !is.na(base_rate_data) && base_rate_data %in% names(data))
    .frac_warn_col(data[[base_rate_data]], "base_rate", base_rate_data, hi = 0.05)
  # (bis 1.6.3: NA in der Basiszins-Spalte = 0, keine VP; seit 1.6.4 abgelehnt, siehe oben)

  # P-3: Lueckenhafte Handelstag-Daten automatisch auf Kalenderraster auffuellen
  # (LOCF fuer numerische Spalten; logische Signal-Spalten -> FALSE).
  expected_days <- as.numeric(difftime(stopp_date, start_date, units = "days")) + 1
  fill_how <- "keine"
  if (nrow(data) != expected_days) {
    fill_how <- "merge"
    # seit 1.6.5 (Entscheidung 180, FB-3): Hinweis nur bei ungewoehnlichen Luecken, d. h. Abstand zweier Datenzeilen
    # ueber 5 Kalendertage (Wochenende mit Feiertagen, z. B. Ostern Do -> Di, ergibt hoechstens 5; gleiche Schwelle wie
    # series_check() bei Tagesdaten); Handelstagsdaten ohne solche Luecken werden still aufgefuellt (bis 1.6.4 immer
    # der Hinweis)
    dg <- diff(as.numeric(data$date)); big <- which(dg > 5)
    if (length(big)) {
      k <- big[which.max(dg[big])]
      ii <- function(x) as.character(as.integer(x))
      message(chk_msg("a.locf_luecken", ii(nrow(data)), ii(expected_days), ii(length(big)), ii(dg[k]),
                      format(as.Date(data$date[k]))))
    }
    all_dates <- seq.Date(as.Date(start_date), as.Date(stopp_date), by = "day")
    data$.filled <- pre_filled      # Tage ohne echten Kurs (align_series/NA) bleiben markiert
    dd <- unclass(data$date)
    cols <- data[names(data) != "date"]
    # seit 1.6.0 im Kern (sl_cal_fill: Zeile je Tag ueber die ganzzahlige Tagesnummer, LOCF, Signale FALSE,
    # .filled TRUE), wenn das Ergebnis dem von merge() gleicht: ganzzahlige Tage, einfache Spalten ohne Attribute
    if (is.double(all_dates) && identical(class(data), "data.frame") && all(dd == trunc(dd)) &&
        all(vapply(cols, function(v) is.null(attributes(v)) && typeof(v) %in% c("double", "integer", "logical", "character"), NA))) {
      fill <- .Call(C_sl_cal_fill, unclass(cols), as.double(dd), unclass(all_dates)[1L], as.double(length(all_dates)),
                    match(".filled", names(cols)))
      fill_how <- "kern"   # seit 1.6.5 (Paket E): der Studienkern fuellt getauschte Spalten ebenso
      names(fill) <- names(cols)
      data <- structure(c(list(date = all_dates), fill), row.names = c(NA_integer_, -length(all_dates)), class = "data.frame")
    } else {
      data <- merge(data.frame(date = all_dates), data, by = "date", all.x = TRUE)
      data$.filled[is.na(data$.filled)] <- TRUE   # A-2: aufgefuellte Tage markieren
      num_cols <- setdiff(names(data)[vapply(data, is.numeric, logical(1))], "date")
      for (cc in num_cols) data[[cc]] <- .fill_na(data[[cc]], "locf")   # fuehrende NAs rueckwaerts gefuellt
      lgl_cols <- names(data)[vapply(data, is.logical, logical(1))]
      for (cc in lgl_cols) data[[cc]][is.na(data[[cc]])] <- FALSE
    }
  } else if (any(pre_filled)) {
    data$.filled <- pre_filled      # aufgefuellte Tage aus series_align() wie eigene behandeln
  }

  list(data = data, start_date = start_date, stopp_date = stopp_date, fill = fill_how)
}

#' Phase 2b von simulation(): Zentralstruktur sim_mem anlegen
#'
#' Zweck: sim_mem mit den Feldern assets, status, market, trades, report und totals je Asset vorbelegen
#' (status und report setzt der Kern: Startgewichte und Anfangszustand in core/prepare_core_impl.h); prueft die
#' Signal- und Basiszinsspalten.
#' Eingabe: data und strategy (vorbereitet), start_date, stopp_date, sparer_pauschbetrag,
#' use_sparer_pauschbetrag, base_rate, base_rate_flex, base_rate_data (Meldungen nennen die Bausteine).
#' Ausgabe: sim_mem.
#' @keywords internal
#' @noRd
.sim_build_state <- function(data, strategy, start_date, stopp_date, sparer_pauschbetrag,
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
      bonus = (strategy[[name]][["partial_exemption"]] %||% 0) / 100   # PROZENT-KONVENTION
    )

    # P-2: Signal-Spalten validieren (nur fuer trading = "signal")
    if (identical(strategy[[name]][["trading"]], "signal")) {
      sb <- strategy[[name]][["signal_buy"]]
      ss <- strategy[[name]][["signal_sell"]]
      if (is.null(sb) || !sb %in% names(data))
        stop(chk_msg("a.m_sim_build_state", sb %||% "NULL", name))
      if (is.null(ss) || !ss %in% names(data))
        stop(chk_msg("a.m_sim_build_state_2", ss %||% "NULL", name))
      # seit 1.6.4 nur TRUE/FALSE oder 0/1 mit NA (Entscheidung 1; bis 1.6.3: Faktor-Codes in R, Text in Python als
      # wahr, jede Zahl ungleich 0 als TRUE)
      chk_col_signal(data, sb, "simulation"); chk_col_signal(data, ss, "simulation")
    }

    #---> Initialisierung des Market-Objekts:
    sim_mem[["market"]][[name]] <- list(
      base_rates = if (base_rate_flex) {
  if (is.null(base_rate_data) || !base_rate_data %in% names(data)) {
    stop(if (is.null(base_rate_data)) "simulation: base_rate_flex = TRUE braucht base_rate_data (Name der Basiszins-Spalte in data, Prozent p. a.); base_rate_data fehlt."
         else sprintf("simulation: base_rate-Spalte '%s' fehlt in data (tax_profile(base_rate = \"%s\") braucht eine Basiszins-Spalte in Prozent p. a.; vorhanden: %s).",
                      paste(base_rate_data, collapse = ", "), paste(base_rate_data, collapse = ", "), paste(names(data), collapse = ", ")))
  }
  br <- data[[base_rate_data]]
  br[is.na(br)] <- 0  # seit 1.6.4 ohne NA (.sim_prepare_data lehnt NA ab, Entscheidung 17); bleibt als Schutz
  br
} else {
  # Vektor je Tag (wie die Spalte), den die Tagesengine je Tag liest (Vorabpauschale im Kern, core/engine_core_impl.h)
  rep(base_rate %||% 0, nrow(data))
},
      asset_price = data[[name]],
      signal_buy = if (is.null(strategy[[name]][["signal_buy"]])) rep(FALSE, nrow(data)) else data[[strategy[[name]][["signal_buy"]]]],
      signal_sell = if (is.null(strategy[[name]][["signal_sell"]])) rep(FALSE, nrow(data)) else data[[strategy[[name]][["signal_sell"]]]],
      spread_rate = (strategy[[name]][["spread"]] %||% 0) / 100   # PROZENT-KONVENTION
    )

    # trades (Zahl der Kaeufe und Verkaeufe, offene Lots) setzt die Tagesengine (.sim_engine_run)
  }

  sim_mem
}

#' Phase 2c von simulation(): Angaben fuer Termine und Tages-Flags
#'
#' Zweck: Kalender (flag_date, aufgefuellte Tage), Angaben der Termine fuer Sparplan und Rebalancing
#' (.sched_spec), Ereignis-Rebalancing (event_col, event_weight); prueft dca_start, balance_start, event_col,
#' event_weight und start sowie, dass ein Asset am ersten Tag handelbar ist. Termine, Splits, das Verschieben
#' von Terminen auf aufgefuellten Tagen, Aktivierung, Freibetrag, Jahreswechsel und Startgewichte rechnet seit
#' 1.4.0 der Kern (core/prepare_core_impl.h, ueber .sim_engine_run); bis dahin .sim_build_calendar,
#' .sim_init_weights und .sim_build_schedule.
#' Eingabe: data, sim_mem, strategy, start_date, stopp_date und die Termin-Argumente von .simulation_flat()
#' (dca_days und balance_days aus .sim_check_inputs); Meldungen nennen die Bausteine.
#' Ausgabe: list(data = data ohne Spalte .filled, flags = list(flag_date, flag_filled, flag_assets, dca, balance
#' (Angaben aus .sched_spec), flag_event (event_col als TRUE/FALSE bzw. NULL), event_replace), event_weight =
#' geprueftes event_weight bzw. NULL ohne event_col).
#' @keywords internal
#' @noRd
.sim_build_calendar <- function(data, sim_mem, strategy, start_date, stopp_date,
                                dca_mode, dca_span, dca_unit, dca_days, dca_value, dca_anchor, dca_start,
                                dca_skip, balance_mode, balance_span, balance_unit, balance_days,
                                balance_anchor, balance_start, balance_skip, event_col,
                                event_mode = c("additional", "replace"), event_weight) {
  flag_date <- .sim_days(start_date, stopp_date)   # seq.Date(start_date, stopp_date, by = "days"); Studie: einmal
  # A-2: Markierung aufgefuellter (LOCF) Tage, aligned zu flag_date
  flag_filled <- if (".filled" %in% names(data)) {
    .f <- as.logical(data[[".filled"]]); .f[is.na(.f)] <- TRUE; .f
  } else rep(FALSE, length(flag_date))
  data[[".filled"]] <- NULL
  flag_assets <- names(strategy)
  for (a in c("dca", "balance")) {   # Bezugsdatum pruefen (sonst kryptischer seq()-Fehler)
    sd0 <- get(paste0(a, "_start"))
    if (!isTRUE(get(paste0(a, "_mode"))) || is.null(sd0)) next
    sd1 <- tryCatch(as.Date(sd0), error = function(e) NA)
    # seit 1.6.4 ohne Eingabewert (der letzte Datentag bleibt als Ort in den Daten)
    if (length(sd1) != 1L || is.na(sd1)) stop(chk_msg("a.m_sim_build_calendar", a))
    if (sd1 > stopp_date) stop(chk_msg("a.m_sim_build_calendar_2", sprintf("start von %s", if (a == "dca") "dca_plan()" else "rebalance_plan()"), format(stopp_date)))
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
      stop(chk_msg("a.m_sim_build_calendar_3", event_col))
    # seit 1.6.5 (CR2-G-6, Entscheidung 185 K36) wie Signalspalten: TRUE/FALSE oder 0/1, NA erlaubt (bis 1.6.4 ergab
    # Text wie "ja"/"nein" still kein Ereignis, eine 2 zaehlte als Ereignis)
    chk_col_signal(data, event_col, "simulation")
    flag_event <- as.logical(data[[event_col]])
    flag_event[is.na(flag_event)] <- FALSE
    if (!is.null(event_weight)) {   # Gewichtsspalten pruefen
      if (is.null(names(event_weight)) || any(names(event_weight) == ""))
        stop(chk_msg("a.m_sim_build_calendar_4"))
      event_weight <- as.list(event_weight)
      unk <- setdiff(names(event_weight), names(strategy))
      if (length(unk)) stop(sprintf("simulation: event_weight nennt unbekannte Assets: %s.", paste(unk, collapse = ", ")))
      for (nm in names(event_weight)) {
        col <- event_weight[[nm]]
        if (!is.character(col) || length(col) != 1L || !col %in% names(data))
          stop(chk_msg("a.m_sim_build_calendar_5", paste(col, collapse = ","), nm))
        wv <- data[[col]][flag_event]
        if (!is.numeric(data[[col]]) || any(wv < 0, na.rm = TRUE))
          stop(chk_msg("a.m_sim_build_calendar_6", col))
      }
      fehlt <- setdiff(names(strategy), names(event_weight))
      if (length(fehlt))
        warning(chk_msg("a.m_sim_build_calendar_7", paste(fehlt, collapse = ", ")), call. = FALSE)
    }
  }

  # start nach dem letzten Datentag waere nie handelbar (frueher still auf Tag 1 gesetzt)
  starts <- lapply(flag_assets, function(name) sim_mem[["assets"]][[name]][["start"]])
  for (k in seq_along(flag_assets)) {
    st_a <- starts[[k]]
    if (length(st_a) == 1L && !is.na(st_a) && st_a > stopp_date)
      stop(chk_msg("a.m_sim_build_calendar_8", flag_assets[k], format(stopp_date)))   # seit 1.6.4 ohne Eingabewert
  }
  # bis 1.3.0 .sim_init_weights: mindestens ein Asset ab dem ersten Tag handelbar
  if (!length(flag_assets[vapply(starts, function(st) (st %||% flag_date[1]) <= flag_date[1], NA)]))
    stop(chk_msg("a.m_sim_build_calendar_9", format(flag_date[1])))

  list(data = data,
       flags = list(flag_date = flag_date, flag_filled = flag_filled, flag_assets = flag_assets, dca = dca,
                    balance = balance, flag_event = flag_event, event_replace = event_mode == "replace"),
       event_weight = if (!is.null(event_col)) event_weight)
}
