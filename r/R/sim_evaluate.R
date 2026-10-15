# =============================================================================
# simulation(), Phase 6: Auswertung und Ergebnisobjekt
# =============================================================================

#' Phase 6a von simulation(): Handelslisten kuerzen
#'
#' Zweck: die vorab angelegten Listen buys, sells, taxes und fees je Asset auf die Zahl der Eintraege
#' kuerzen und die internen Zaehler und fifo_front entfernen.
#' Eingabe: sim_mem, flag_assets.
#' Ausgabe: sim_mem.
#' @keywords internal
#' @noRd
.sim_compact_trades <- function(sim_mem, flag_assets) {
  #--------> Bereinigung der Zentralstruktur:
  for(name in flag_assets){
    # #15 FIX: Sichere Subsetting bei count=0 (1:0 → c(1,0) in R)
    n_buys  <- sim_mem[["trades"]][[name]][["buy_count"]]
    n_sells <- sim_mem[["trades"]][[name]][["sell_count"]]
    n_taxes <- sim_mem[["trades"]][[name]][["tax_count"]]
    n_fees  <- sim_mem[["trades"]][[name]][["fee_count"]]
    
    sim_mem[["trades"]][[name]][["buys"]]  <- if (n_buys  > 0) sim_mem[["trades"]][[name]][["buys"]][1:n_buys]   else list()
    sim_mem[["trades"]][[name]][["sells"]] <- if (n_sells > 0) sim_mem[["trades"]][[name]][["sells"]][1:n_sells] else list()
    sim_mem[["trades"]][[name]][["taxes"]] <- if (n_taxes > 0) sim_mem[["trades"]][[name]][["taxes"]][1:n_taxes] else list()
    sim_mem[["trades"]][[name]][["fees"]]  <- if (n_fees  > 0) sim_mem[["trades"]][[name]][["fees"]][1:n_fees]   else list()
    
    sim_mem[["trades"]][[name]][["buy_count"]] <- NULL
    sim_mem[["trades"]][[name]][["sell_count"]] <- NULL
    sim_mem[["trades"]][[name]][["tax_count"]] <- NULL
    sim_mem[["trades"]][[name]][["fee_count"]] <- NULL
    sim_mem[["trades"]][[name]][["fifo_front"]] <- NULL
  }

  sim_mem
}

#' Phase 6b von simulation(): Wertreihen, Renditen und Drawdowns
#'
#' Zweck: Depotwert und Zufluesse je Tag, CAGR (mit Einzahlungen geldgewichtet), TTWROR,
#' zeitgewichteter Wertindex, Drawdowns und die Tagesrenditen fuer die Risikokennzahlen; Warnungen
#' zu nicht definierten Jahresrenditen und negativen Werten.
#' Eingabe: sim_mem, flag_date, flag_assets, flag_filled, start_date, stopp_date, start_value,
#' tax_unpaid_total (nicht gedeckte Steuerzahlungen in EUR).
#' Ausgabe: Liste mit total_worth, twr_index, invested, has_ext_flows, cagr, ttwror, why_ret,
#' open_tax_debt, ret_dd, dd_series, running_max, drawdowns, max_drawdown, risk_returns,
#' returns_filled_mask, ann_factor, ann_periods und n_days_sim.
#' @keywords internal
#' @noRd
.sim_returns <- function(sim_mem, flag_date, flag_assets, flag_filled, start_date, stopp_date, start_value,
                         tax_unpaid_total) {
  # ═══════════════════════════════════════════════════════════════════════════
  # ERGEBNIS-BERECHNUNG
  # ═══════════════════════════════════════════════════════════════════════════

  #--------> Portfolio-Zeitreihen aggregieren:
  # #16 FIX: total_worth nur einmal berechnen, für TTWROR wiederverwenden
  .col_sum <- function(field) {
    m <- sapply(sim_mem[["report"]], function(x) x[[field]])
    if (is.null(dim(m))) m <- matrix(m, nrow = length(flag_date))
    rowSums(m, na.rm = TRUE)
  }
  total_worth <- .col_sum("total")
  total_flows <- .col_sum("flows")
  start_worth <- total_worth[1]
  stopp_worth <- total_worth[length(flag_date)]
  n_days_sim  <- length(total_worth)

  #--------> CAGR:
  ann_factor <- as.numeric(difftime(stopp_date, start_date, units = "days")) / 365.25
  cagr <- if (start_worth > 0 && ann_factor > 0) {
    (stopp_worth / start_worth)^(1 / ann_factor) - 1
  } else {
    NA_real_
  }

  #--------> TTWROR:
  # #18 FIX: Division durch 0 abfangen
  n <- n_days_sim
  if (n >= 2) {
    period_change <- c(NA_real_, total_worth[2:n] - total_worth[1:(n-1)] - total_flows[2:n])
    prev_total <- c(NA_real_, total_worth[1:(n-1)])
    period_return <- ifelse(!is.na(prev_total) & prev_total > 0, period_change / prev_total, 0)
    # R3B-02: an Zuflusstagen Bewertung zum Zeitpunkt der Zahlung (echte zeitgewichtete Rendite):
    # Die Engine legt Zahlungen zum Schlusskurs an. Teilperiode 1 = Vortagesbestand zum heutigen
    # Schlusskurs vor der Zahlung (V_pre = Bestand_{t-1} * P_t / P_{t-1} + Cash_{t-1}), Teilperiode 2 =
    # Zahlung und alles, was am Tag danach geschieht (Kaufkosten, Umschichten, Steuern):
    # 1 + r_t = V_pre / V_{t-1} * V_t / (V_pre + F_t). Ohne Kosten ist r_t = Kursrendite (keine
    # Verduennung), Kaufkosten der Einzahlung belasten das Kapital nach der Zahlung. Tage ohne
    # Zahlung unveraendert.
    fday <- which(c(FALSE, !is.na(total_flows[2:n]) & total_flows[2:n] != 0))
    if (length(fday)) {
      v_pre <- numeric(length(fday))
      for (nm in flag_assets) {
        rep_a <- sim_mem[["report"]][[nm]]
        px <- as.numeric(sim_mem[["market"]][[nm]][["asset_price"]])
        w_prev <- rep_a[["worth"]][fday - 1L]
        gr <- px[fday] / px[fday - 1L]
        v_pre <- v_pre + ifelse(w_prev != 0 & is.finite(gr), w_prev * gr, 0) + rep_a[["money"]][fday - 1L]
      }
      g1 <- ifelse(!is.na(prev_total[fday]) & prev_total[fday] > 0, v_pre / prev_total[fday], 1)
      den <- v_pre + total_flows[fday]
      g2 <- ifelse(is.finite(den) & den > 0, total_worth[fday] / den, 1)
      period_return[fday] <- g1 * g2 - 1
    }
    period_return[1] <- NA_real_
  } else {
    period_return <- NA_real_       # Einzeltag (n=1): keine Periodenrendite berechenbar
  }
  ttwror <- if (ann_factor > 0) {
    prod(1 + period_return, na.rm = TRUE)^(1 / ann_factor) - 1
  } else {
    NA_real_
  }

  #--------> Externe Zufluesse (Sparplan, report$flows ab Tag 2; ein Zufluss am Starttag steckt im Startwert):
  # Ohne Zufluesse bleiben alle Kennzahlen unveraendert (Depotwert = Wertentwicklung). Mit Zufluessen
  # waere der Depotwert durch die Einzahlungen verzerrt (CAGR 82 % bei TTWROR 4 %), deshalb:
  #  - cagr = geldgewichtete Rendite (XIRR aus Startwert, datierten Einzahlungen und Endwert)
  #  - Drawdowns auf dem zeitgewichteten Wertindex (zuflussbereinigte Tagesrenditen, wie ttwror)
  #  - Calmar, Serenity, Martin mit der zeitgewichteten Jahresrendite (ttwror) im Zaehler
  has_ext_flows <- n_days_sim >= 2 && any(total_flows[-1] != 0, na.rm = TRUE)
  # R3B-03: eingezahlt = Startwert + Einzahlungen (auch am Starttag), brutto vor Kaufkosten
  fl0 <- total_flows; fl0[is.na(fl0)] <- 0
  invested <- start_value + cumsum(fl0)
  twr_growth <- if (n_days_sim >= 2) 1 + period_return[-1] else numeric(0)
  twr_growth[!is.finite(twr_growth)] <- 1
  twr_index <- cumprod(c(1, twr_growth))     # zeitgewichteter Wertindex, Start = 1
  if (has_ext_flows) {
    fi <- which(seq_len(n_days_sim) > 1L & !is.na(total_flows) & total_flows != 0)
    t_fl <- as.numeric(difftime(flag_date[fi], start_date, units = "days")) / 365.25
    start_gross <- start_value + fl0[1]          # R3B-03: Startbetrag brutto (vor Kaufkosten des Starttags)
    cagr <- if (ann_factor > 0) .xirr_rate(c(0, t_fl), c(start_gross, total_flows[fi]), stopp_worth, ann_factor) else NA_real_
    if (is.na(cagr) && ann_factor > 0 && !(is.finite(stopp_worth) && stopp_worth < 0))   # negativer Endwert: Warnung unten
      warning(sprintf("simulation: geldgewichtete Rendite (cagr) mit Einzahlungen nicht bestimmbar (Startwert %.2f EUR, Einzahlungen %.2f EUR, Endwert %.2f EUR): kein interner Zinsfu\u00df gefunden; cagr = NA.",
                      start_gross, sum(total_flows[fi]), stopp_worth), call. = FALSE)
  }
  # R4-05: negativer Endwert (nicht gedeckte Steuerschuld): Verlust > 100 %, eine Jahresrendite gibt
  # es nicht (-1 wuerde den Verlust untertreiben) -> cagr/ttwror NA mit Warnung statt NaN
  # Offene Steuerschuld am Ende: negative Geldbestaende nach einer nicht gedeckten Steuerzahlung (.pay_tax)
  open_tax_debt <- if (tax_unpaid_total > 0)
    sum(vapply(flag_assets, function(nm) max(0, -sim_mem[["status"]][[nm]][["money"]]), numeric(1))) else 0
  neg_detail <- if (open_tax_debt > 0) sprintf("Endwert %.2f EUR negativ: offene Steuerschuld %.2f EUR", stopp_worth, open_tax_debt) else
    sprintf("Endwert %.2f EUR negativ", stopp_worth)
  if (is.finite(stopp_worth) && stopp_worth < 0) {
    if (!has_ext_flows) cagr <- NA_real_
    if (is.nan(ttwror)) ttwror <- NA_real_
    warning(sprintf("simulation: Endwert negativ (%.2f EUR, %s); Verlust \u00fcber 100 %%: cagr und ttwror sind nicht definiert (NA), Drawdowns auf 100 %% begrenzt.",
                    stopp_worth, if (open_tax_debt > 0) sprintf("offene Steuerschuld %.2f EUR", open_tax_debt) else "nicht gedeckte Steuerschuld"), call. = FALSE)
  } else if (is.nan(ttwror)) {
    ttwror <- NA_real_
    if (!(has_ext_flows && any(twr_index <= 0)))   # sonst warnt der Index-Hinweis unten
      warning("simulation: zeitgewichteter Wertindex wird negativ (Tagesrendite unter -100 %); ttwror ist nicht definiert (NA).", call. = FALSE)
  }
  # B: Ursache nicht definierter Jahresrenditen (undefined_metrics, print/summary)
  .why_na <- function(metric) {
    if (ann_factor <= 0)
      return(c("too_short", sprintf("Zeitraum %s, Laufzeit 0 Jahre (Einzeltag)", .n_tage(n_days_sim))))
    if (is.finite(stopp_worth) && stopp_worth < 0) return(c("negative_end_value", neg_detail))
    if (metric == "cagr" && has_ext_flows)
      return(c("no_irr_solution", sprintf("kein interner Zinsfu\u00df: Startwert %.2f EUR, Einzahlungen %.2f EUR, Endwert %.2f EUR",
                                          start_gross, sum(total_flows[fi]), stopp_worth)))
    if (metric == "cagr" && !(start_worth > 0)) return(c("zero_start_value", sprintf("Depotwert am Starttag %.2f EUR", start_worth)))
    i0 <- which(twr_index <= 0)[1]
    if (!is.na(i0)) return(c("nonpositive_twr_index", sprintf("zeitgewichteter Wertindex am %s nicht positiv (Tagesrendite %.2f %%)",
                                                              format(flag_date[i0]), 100 * period_return[i0])))
    c("not_finite", "Rechnung ergibt keinen endlichen Wert")
  }
  why_ret <- list(cagr = if (is.na(cagr)) .why_na("cagr"), ttwror = if (is.na(ttwror)) .why_na("ttwror"))
  if (ann_factor <= 0)
    warning(sprintf("simulation: Zeitraum %s (Laufzeit 0 Jahre): cagr und ttwror sind nicht definiert (NA).", .n_tage(n_days_sim)), call. = FALSE)
  else if (!has_ext_flows && is.na(cagr) && identical(why_ret$cagr[1], "zero_start_value"))
    warning(sprintf("simulation: Depotwert am Starttag %.2f EUR: cagr ist nicht definiert (NA).", start_worth), call. = FALSE)
  ret_dd <- if (has_ext_flows) ttwror else cagr   # Jahresrendite fuer Calmar/Serenity/Martin
  dd_series <- if (has_ext_flows) twr_index else total_worth

  #--------> Drawdowns (mit NaN-Schutz):
  # #17 FIX: Division durch 0 abfangen
  running_max <- cummax(dd_series)
  drawdowns <- ifelse(running_max > 0, (running_max - dd_series) / running_max, 0)
  if (has_ext_flows && any(twr_index <= 0)) {
    # Tagesrendite <= -100 % (z. B. Kaufkosten einer grossen Einzahlung auf ein fast leeres Depot):
    # Index und TTWROR sind dann nicht aussagekraeftig; Drawdowns auf 100 % begrenzen
    i0 <- which(twr_index <= 0)[1]
    warning(sprintf("simulation: zeitgewichteter Wertindex am %s nicht positiv (Tagesrendite %.2f %% bei Depotwert %.2f EUR am Vortag und Einzahlung %.2f EUR); TTWROR und die zeitgewichteten Drawdowns sind nicht aussagekr\u00e4ftig (Drawdowns auf 100 %% begrenzt).",
                    format(flag_date[i0]), 100 * period_return[i0], total_worth[i0 - 1], total_flows[i0]), call. = FALSE)
    drawdowns <- pmin(drawdowns, 1)
  }
  if (any(drawdowns > 1, na.rm = TRUE)) {
    # R4-05: Wert unter 0 (Steuerschuld): Drawdowns allgemein auf [0, 1] begrenzen
    i0 <- which(drawdowns > 1)[1]
    if (!(is.finite(stopp_worth) && stopp_worth < 0))
      warning(sprintf("simulation: Depotwert am %s negativ (%.2f EUR, Steuerschuld); Drawdowns auf 100 %% begrenzt.",
                      format(flag_date[i0]), total_worth[i0]), call. = FALSE)
    drawdowns <- pmin(drawdowns, 1)
  }
  max_drawdown <- max(drawdowns, na.rm = TRUE)
  if (!is.finite(max_drawdown)) max_drawdown <- 0   # Einzeltag/leer: robust

  #--------> Portfolio-Returns:
  # Einfache tägliche Returns (für Abwärtskompatibilität und Vergleichbarkeit)
  portfolio_returns <- diff(total_worth) / head(total_worth, -1)
  portfolio_returns[!is.finite(portfolio_returns)] <- 0

  # TTWROR-adjustierte Returns (Cashflow-bereinigt, für Risiko-Metriken)
  # Bei DCA/Rebalancing isolieren diese die Anlageperformance von Timing-Effekten
  ttwror_returns <- period_return[-1]  # Erstes Element ist NA
  ttwror_returns[!is.finite(ttwror_returns)] <- 0

  # Basis für Risiko-Metriken: TTWROR-Returns wenn Cashflows vorhanden, sonst simple
  has_flows <- any(total_flows != 0, na.rm = TRUE)
  risk_returns <- if (has_flows) ttwror_returns else portfolio_returns

  # A-2: aufgefuellte (LOCF) Tage ausschliessen. Eine Tagesrendite gehoert zu
  # ihrem END-Tag (Tag i+1); flag_filled ist tagesweise (Laenge n).
  returns_filled_mask <- if (exists("flag_filled") && length(flag_filled) == length(risk_returns) + 1L) flag_filled[-1] else logical(length(risk_returns))
  if (length(returns_filled_mask) == length(risk_returns) && any(returns_filled_mask)) {
    risk_returns <- risk_returns[!returns_filled_mask]
  }
  # Annualisierungsfrequenz aus den tatsaechlich genutzten Beobachtungen
  ann_periods <- if (ann_factor > 0 && length(risk_returns) > 0) length(risk_returns) / ann_factor else 365.25

  list(total_worth = total_worth, twr_index = twr_index, invested = invested, has_ext_flows = has_ext_flows,
       cagr = cagr, ttwror = ttwror, why_ret = why_ret, open_tax_debt = open_tax_debt, ret_dd = ret_dd,
       dd_series = dd_series, running_max = running_max, drawdowns = drawdowns, max_drawdown = max_drawdown,
       risk_returns = risk_returns, returns_filled_mask = returns_filled_mask, ann_factor = ann_factor,
       ann_periods = ann_periods, n_days_sim = n_days_sim)
}

#' Phase 6c von simulation(): Performance- und Risikokennzahlen
#'
#' Zweck: Basisstatistik, Sharpe und Sortino auf Ueberschussrenditen (risk_free), Calmar, Ulcer,
#' Martin, Serenity, Omega, Gain-to-Pain und Drawdown-Dauern.
#' Eingabe: r (aus .sim_returns), risk_free (Argument von simulation()), data (Spalte fuer risk_free).
#' Ausgabe: list(statistics, longest_dd = laengster Drawdown in Tagen).
#' @keywords internal
#' @noRd
.sim_risk_stats <- function(r, risk_free, data) {
  risk_returns <- r$risk_returns; returns_filled_mask <- r$returns_filled_mask
  ann_periods <- r$ann_periods; n_days_sim <- r$n_days_sim; drawdowns <- r$drawdowns
  dd_series <- r$dd_series; running_max <- r$running_max; max_drawdown <- r$max_drawdown
  ret_dd <- r$ret_dd

  # ═══════════════════════════════════════════════════════════════════════════
  # PERFORMANCE- UND RISIKO-METRIKEN
  # ═══════════════════════════════════════════════════════════════════════════

  # --- Basis-Statistiken ---
  daily_mean <- mean(risk_returns, na.rm = TRUE)
  daily_sd   <- sd(risk_returns, na.rm = TRUE)
  if (!is.finite(daily_mean)) daily_mean <- 0   # Einzeltag/leer: robust
  if (!is.finite(daily_sd))   daily_sd   <- 0
  daily_cv   <- if (daily_mean != 0) abs(daily_sd / daily_mean) else NA_real_

  # A-2: Annualisierung mit der tatsaechlichen Beobachtungsfrequenz (ohne LOCF-Tage)
  days_per_year <- ann_periods

  # A-4: Risk-Free als annualisierte Rate in Prozent (Jahresrate je Tag), unten /100 in dezimal.
  # Option A: je Tag tagesaequivalent abziehen -> Sharpe/Sortino auf Ueberschuss.
  if (is.null(risk_free)) risk_free <- 0          # NULL explizit wie 0 behandeln
  rf_series_full <- if (is.character(risk_free)) {
    if (!risk_free %in% names(data)) stop(sprintf("risk_free: Spalte '%s' fehlt im Datensatz.", risk_free))
    as.numeric(data[[risk_free]])
  } else rep(as.numeric(risk_free), n_days_sim)
  rf_series_full[!is.finite(rf_series_full)] <- 0
  rf_series_full <- rf_series_full / 100   # PROZENT-KONVENTION: Prozent -> dezimal
  rf_returns <- if (length(rf_series_full) >= 2) rf_series_full[-1] else numeric(0)
  if (length(returns_filled_mask) == length(rf_returns) && any(returns_filled_mask)) {
    rf_returns <- rf_returns[!returns_filled_mask]      # gleiche LOCF-Ausschlussmaske
  }
  if (length(rf_returns) != length(risk_returns)) {     # Sicherheitsnetz
    rf_returns <- rep(if (length(rf_returns)) mean(rf_returns) else 0, length(risk_returns))
  }
  rf_daily       <- (1 + rf_returns)^(1 / days_per_year) - 1   # tagesaequivalent
  excess_returns <- risk_returns - rf_daily
  rf_effective   <- if (length(rf_returns)) mean(rf_returns) * 100 else 0   # Ausweis in Prozent (Nutzereinheit)

  mean_excess <- mean(excess_returns, na.rm = TRUE)
  sd_excess   <- sd(excess_returns, na.rm = TRUE)
  if (!is.finite(mean_excess)) mean_excess <- 0
  if (!is.finite(sd_excess))   sd_excess   <- 0
  downside_excess    <- excess_returns[excess_returns < 0]
  # A7-08: Downside-Abweichung ueber ALLE Beobachtungen (Sortino/Price, wie deep_analysis):
  # sqrt(mean(pmin(Ueberschussrendite, 0)^2)); vorher nur ueber die negativen Tage
  downside_sd_excess <- if (length(downside_excess) > 0) sqrt(mean(pmin(excess_returns, 0)^2, na.rm = TRUE)) else 0

  # --- Sharpe Ratio (annualisiert, auf Ueberschussrenditen) ---
  sharpe <- if (sd_excess > 0) {
    (mean_excess * days_per_year) / (sd_excess * sqrt(days_per_year))
  } else {
    NA_real_
  }

  # --- Sortino Ratio (annualisiert, auf Ueberschussrenditen) ---
  sortino <- if (downside_sd_excess > 0) {
    (mean_excess * days_per_year) / (downside_sd_excess * sqrt(days_per_year))
  } else {
    NA_real_
  }

  # --- Calmar Ratio ---
  calmar <- if (max_drawdown > 0 && !is.na(ret_dd)) {
    ret_dd / max_drawdown
  } else {
    NA_real_
  }

  # --- Ulcer Index ---
  ulcer_index <- sqrt(mean(drawdowns^2, na.rm = TRUE))
  if (!is.finite(ulcer_index)) ulcer_index <- 0   # Einzeltag/leer: robust

  # --- Martin Ratio (= Ulcer Performance Index) ---
  martin_ratio <- if (ulcer_index > 0 && !is.na(ret_dd)) {
    ret_dd / ulcer_index
  } else {
    NA_real_
  }

  # --- Serenity Ratio ---
  serenity <- if (ulcer_index > 0 && max_drawdown > 0 && !is.na(ret_dd)) {
    ret_dd / (ulcer_index * max_drawdown)
  } else {
    NA_real_
  }

  # --- Omega Ratio (Threshold = 0) ---
  gains <- sum(risk_returns[risk_returns > 0], na.rm = TRUE)
  losses <- abs(sum(risk_returns[risk_returns < 0], na.rm = TRUE))
  omega <- if (losses > 0) (gains / losses) else NA_real_

  # --- Gain-to-Pain Ratio ---
  gain_to_pain <- if (losses > 0) {
    sum(risk_returns, na.rm = TRUE) / losses
  } else {
    NA_real_
  }

  # --- Average Drawdown ---
  dd_active <- drawdowns[drawdowns > 0]
  average_drawdown <- if (length(dd_active) > 0) mean(dd_active) else 0

  # --- Longest Drawdown Duration (Tage) ---
  longest_dd <- 0L
  current_dd <- 0L
  for (i in seq_along(dd_series)) {
    if (dd_series[i] < running_max[i]) {
      current_dd <- current_dd + 1L
      if (current_dd > longest_dd) longest_dd <- current_dd
    } else {
      current_dd <- 0L
    }
  }

  # --- Average Recovery Time (Tage) ---
  recovery_times <- integer(0)
  in_dd <- FALSE
  dd_start <- 0L
  for (i in seq_along(dd_series)) {
    if (dd_series[i] < running_max[i]) {
      if (!in_dd) { dd_start <- i; in_dd <- TRUE }
    } else {
      if (in_dd) {
        recovery_times <- c(recovery_times, i - dd_start)
        in_dd <- FALSE
      }
    }
  }
  avg_recovery_time <- if (length(recovery_times) > 0) mean(recovery_times) else NA_real_

  # --- Zusammenfassung ---
  statistics <- list(
    # Basis
    mean     = daily_mean,
    sd       = daily_sd,
    cv       = daily_cv,
    risk_free = rf_effective,
    skewness = calculate_skewness(risk_returns, na.rm = TRUE),
    kurtosis = calculate_kurtosis(risk_returns, na.rm = TRUE),
    lpm      = calculate_partials(risk_returns, type = "lower"),
    hpm      = calculate_partials(risk_returns, type = "higher"),
    # Performance-Ratios
    sharpe        = sharpe,
    sortino       = sortino,
    calmar        = calmar,
    omega         = omega,
    gain_to_pain  = gain_to_pain,
    serenity      = serenity,
    martin_ratio  = martin_ratio,
    # Drawdown-Metriken
    max_drawdown      = max_drawdown,
    average_drawdown  = average_drawdown,
    ulcer_index       = ulcer_index,
    longest_drawdown  = longest_dd,
    avg_recovery_time = avg_recovery_time
  )

  list(statistics = statistics, longest_dd = longest_dd)
}

#' Phase 6d von simulation(): Ursachen nicht definierter Kennzahlen
#'
#' Zweck: mittlere Kaeufe und Verkaeufe je Jahr und je NA-Kennzahl (cagr, ttwror, statistics, buys,
#' sells) Ursache als Code und Klartext.
#' Eingabe: r (aus .sim_returns), rs (aus .sim_risk_stats), sim_mem, flag_assets.
#' Ausgabe: list(undefined_metrics = data.frame(metric, reason, detail), buys, sells).
#' @keywords internal
#' @noRd
.sim_undefined_metrics <- function(r, rs, sim_mem, flag_assets) {
  risk_returns <- r$risk_returns; has_ext_flows <- r$has_ext_flows; why_ret <- r$why_ret
  ret_dd <- r$ret_dd; ann_factor <- r$ann_factor; n_days_sim <- r$n_days_sim
  statistics <- rs$statistics; longest_dd <- rs$longest_dd

  #--------> B: Ursachen nicht definierter Kennzahlen (eine Zeile je NA-Kennzahl)
  n_r <- length(risk_returns)
  few <- function(k) c("too_short", if (n_r == 0) "keine Tagesrendite (Einzeltag)" else
                         sprintf("nur %d %s, mindestens %d n\u00f6tig", n_r, if (n_r == 1) "Tagesrendite" else "Tagesrenditen", k))
  ret_name <- if (has_ext_flows) "ttwror" else "cagr"
  inherit <- function() { w <- why_ret[[ret_name]]; c(w[1], sprintf("%s nicht definiert: %s", ret_name, w[2])) }
  no_dd <- c("no_drawdown", "kein Drawdown im Zeitraum (max_drawdown 0)")
  zero_vol <- c("zero_volatility", sprintf("Standardabweichung der %d Tagesrenditen ist 0 (konstanter Verlauf)", n_r))
  why_stat <- list(
    cv = if (n_r == 0) few(1) else c("zero_mean_return", "mittlere Tagesrendite ist 0"),
    skewness = if (n_r < 3) few(3) else zero_vol,
    kurtosis = if (n_r < 4) few(4) else zero_vol,
    lpm = few(1), hpm = few(1),
    sharpe = if (n_r < 2) few(2) else c("zero_volatility", sprintf("Standardabweichung der %d \u00dcberschussrenditen ist 0", n_r)),
    sortino = if (n_r < 1) few(1) else c("no_negative_returns", "keine negativen \u00dcberschussrenditen (Downside-Abweichung 0)"),
    calmar = if (is.na(ret_dd)) inherit() else no_dd,
    omega = if (n_r < 1) few(1) else c("no_negative_returns", "keine negativen Tagesrenditen"),
    gain_to_pain = if (n_r < 1) few(1) else c("no_negative_returns", "keine negativen Tagesrenditen"),
    serenity = if (is.na(ret_dd)) inherit() else no_dd,
    martin_ratio = if (is.na(ret_dd)) inherit() else c("no_drawdown", "kein Drawdown im Zeitraum (Ulcer Index 0)"),
    avg_recovery_time = if (ann_factor <= 0) c("too_short", sprintf("Zeitraum %s, Laufzeit 0 Jahre (Einzeltag)", .n_tage(n_days_sim))) else
      c("no_recovery", if (longest_dd == 0) "kein Drawdown im Zeitraum" else
                            sprintf("Drawdown bis zum Ende nicht aufgeholt (l\u00e4ngster Drawdown %s)", .n_tage(longest_dd))))
  # mittlere Anzahl Kaeufe/Verkaeufe je Jahr; R5-04: Einzeltag (Laufzeit 0 Jahre) NA statt NaN/Inf
  buys <- sapply(flag_assets, function(x) if (ann_factor > 0) length(sim_mem[["trades"]][[x]][["buys"]]) / ann_factor else NA_real_)
  sells <- sapply(flag_assets, function(x) if (ann_factor > 0) length(sim_mem[["trades"]][[x]][["sells"]]) / ann_factor else NA_real_)
  um <- list()
  for (m in c("cagr", "ttwror")) if (is.na(r[[m]])) um[[m]] <- why_ret[[m]]

  for (m in names(statistics)) if (length(statistics[[m]]) == 1L && is.na(statistics[[m]]))
    um[[m]] <- why_stat[[m]] %||% c("not_finite", "Rechnung ergibt keinen endlichen Wert")
  for (m in c("buys", "sells")) if (anyNA(get(m)))
    um[[m]] <- c("too_short", sprintf("Zeitraum %s, Laufzeit 0 Jahre: keine Anzahl je Jahr (Einzeltag)", .n_tage(n_days_sim)))
  undefined_metrics <- data.frame(metric = as.character(names(um)), reason = vapply(um, `[`, "", 1), detail = vapply(um, `[`, "", 2),
                                  stringsAsFactors = FALSE, row.names = NULL)

  list(undefined_metrics = undefined_metrics, buys = buys, sells = sells)
}

#' Phase 6e von simulation(): Ergebnisobjekt
#'
#' Zweck: offene Lots am letzten Tag, Steuerreport (mit Tarifjahren und Steuerzustand des Folgejahres)
#' und das Ergebnisobjekt der Klasse SimLevResult zusammenstellen.
#' Eingabe: sim_mem, fl, cfg, r (aus .sim_returns), rs (aus .sim_risk_stats), um (aus
#' .sim_undefined_metrics).
#' Ausgabe: Objekt der Klasse SimLevResult (siehe simulation()).
#' @keywords internal
#' @noRd
.sim_result <- function(sim_mem, fl, cfg, r, rs, um) {
  flag_date <- fl$flag_date; flag_filled <- fl$flag_filled; flag_assets <- fl$flag_assets
  flag_harvest <- fl$flag_harvest; tax_regimes <- fl$tax_regimes
  tax_mode <- cfg$tax_mode; strategy <- cfg$strategy; order_fee <- cfg$order_fee
  effective_tax_rate <- cfg$effective_tax_rate; use_sparer_pauschbetrag <- cfg$use_sparer_pauschbetrag
  tariff_env <- cfg$tariff_env; fees_on <- cfg$fees_on; harvest_mode <- cfg$harvest_mode
  total_worth <- r$total_worth; twr_index <- r$twr_index; invested <- r$invested
  has_ext_flows <- r$has_ext_flows; cagr <- r$cagr; ttwror <- r$ttwror; drawdowns <- r$drawdowns
  open_tax_debt <- r$open_tax_debt; statistics <- rs$statistics
  buys <- um$buys; sells <- um$sells; undefined_metrics <- um$undefined_metrics

  #--------> E: offene Lots am letzten Tag (Grundlage fuer Steuerrechnungen nach dem Ende; nur tax_mode = "person")
  open_lots <- if (tax_mode == "person") stats::setNames(lapply(flag_assets, function(nm) {
    lots <- Filter(function(b) length(b) && b[["remaining"]] > 0, sim_mem[["trades"]][[nm]][["buys"]])
    list(lots = data.frame(date = as.Date(vapply(lots, function(b) as.numeric(b[["date"]]), numeric(1)), origin = "1970-01-01"),
                           units = vapply(lots, function(b) b[["remaining"]], numeric(1)),
                           price = vapply(lots, function(b) b[["price"]], numeric(1)),
                           vp = vapply(lots, function(b) b[["vp"]] %||% 0, numeric(1))),
         regime = tax_regimes[[nm]],
         asset_bonus = 100 * sim_mem[["assets"]][[nm]][["bonus"]],
         cash = sim_mem[["status"]][[nm]][["money"]],
         asset_spread = strategy[[nm]][["asset_spread"]] %||% 0,   # voller Spread in Prozent (wie asset_config)
         order_fee = order_fee)                                    # wie uebergeben (NULL = keine Ordergebuehr)
  }), flag_assets) else NULL

  #--------> Berechnung der Handelsaktionen:

  results <- list(
    dates = flag_date,                 # ABGLEICH: von plot_dashboard.R (x$dates) benoetigt
    filled = flag_filled,              # A-2: TRUE = LOCF-Tag (aus Risikometriken ausgeschlossen)
    worth = total_worth,
    twr_index = twr_index,             # zeitgewichteter Wertindex (Start = 1)
    invested = invested,               # Startwert + kumulierte Einzahlungen in EUR
    external_flows = has_ext_flows,    # TRUE = Sparplan-Zufluesse: cagr geldgewichtet, Drawdowns zeitgewichtet
    cagr = cagr,
    ttwror = ttwror,
    drawdowns = drawdowns,
    statistics = statistics,
    buys = buys,
    sells = sells,
    report = sim_mem[["report"]],
    # Steuer-Report
    tax_report = list(
      total_taxes_paid = sim_mem[["totals"]][["total_taxes"]],
      loss_carryforward_capital = sim_mem[["totals"]][["loss_capital_gains"]],
      loss_carryforward_private = sim_mem[["totals"]][["loss_private_sales"]],
      sparer_pauschbetrag_annual = sim_mem[["totals"]][["sparer_pauschbetrag_annual"]],
      sparer_pauschbetrag_used = sim_mem[["totals"]][["sparer_pauschbetrag_used_total"]],
      # #21 FIX: effective_tax_rate statt tax_rate
      sparer_pauschbetrag_tax_saved = sim_mem[["totals"]][["sparer_pauschbetrag_used_total"]] * effective_tax_rate,
      open_tax_debt = open_tax_debt      # am Ende offene, nicht gedeckte Steuerschuld in EUR (0 im Normalfall)
    ),
    undefined_metrics = undefined_metrics,   # je NA-Kennzahl: metric, reason (Code), detail (Klartext)
    open_lots = open_lots                    # je Asset die am letzten Tag gehaltenen Lots (tax_mode = "person")
  )
  if (!is.null(tariff_env))   # Tarifweg: Jahreswerte in EUR (§ 23, Guenstigerpruefung, KiSt-Sonderausgabe)
    results$tax_report$tariff_years <- if (length(tariff_env$rows)) do.call(rbind, tariff_env$rows) else NULL
  # Steuerzustand des Jahres nach dem letzten Datentag (Fortsetzung z. B. in withdrawal_simulation): der finale
  # Jahresabschluss hat das Jahr des letzten Datentags geschlossen; gebucht ist darin nur, was ihm schon
  # zugerechnet wurde (Vorabpauschale bei Ende am 31.12.: Verlusttopf und Sparer-Pauschbetrag dieses Jahres)
  if (tax_mode == "person") {
    tt <- sim_mem[["totals"]]
    ny <- as.integer(tt[["current_year"]])
    results$tax_report$next_year <- list(
      year = ny,
      sparer_pauschbetrag_used = if (use_sparer_pauschbetrag) max(0, tt[["sparer_pauschbetrag_annual"]] - tt[["sparer_pauschbetrag_remaining"]]) else 0,
      sparer_pauschbetrag_remaining = if (use_sparer_pauschbetrag) tt[["sparer_pauschbetrag_remaining"]] else 0,
      loss_carryforward_capital = tt[["loss_capital_gains"]],
      loss_carryforward_private = tt[["loss_private_sales"]],
      capital_income_taxed = tt[["cgt_base_taxed_ytd"]] %||% 0,     # mit Abgeltungsteuer belastete Bemessungsgrundlage
      loss_capital_added = tt[["cgt_loss_added_ytd"]] %||% 0,       # im Jahr neu entstandene § 20-Verluste
      loss_capital_used = tt[["cgt_loss_used_ytd"]] %||% 0,         # im Jahr genutzter § 20-Verlusttopf
      loss_capital_start = tt[["cgt_pool_start_ytd"]] %||% 0,       # § 20-Verlusttopf zu Beginn des Jahres
      private_sale_net = (tt[["private_sale_gains_ytd"]] %||% 0) - (tt[["private_sale_losses_ytd"]] %||% 0))
    if (!is.null(tariff_env)) {
      ks <- unname(tariff_env$ks[as.character(ny)])
      results$tax_report$next_year$church_tax_settlement <- if (length(ks) && !is.na(ks)) ks else 0   # am letzten Tag gezahlt (> 0) bzw. erstattet (< 0)
      results$tax_report$next_year$tariff_assessed <- any(vapply(tariff_env$rows, function(rw) rw$year == ny, logical(1)))
    }
  }

  if (fees_on) results$fees_paid <- .fee_env$paid
  if (isTRUE(harvest_mode)) results$harvest_days <- flag_date[flag_harvest]
  class(results) <- "SimLevResult"
  results
}
