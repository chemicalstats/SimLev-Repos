# =============================================================================
# simulation(), Phasen 4 und 5 ueber den gemeinsamen C++-Kern (E17): Tagesengine core/engine_core_impl.h
# =============================================================================
# Seit E17 Stufe 2 rechnet der Kern auch die Vorbereitung (core/prepare_core_impl.h): Termine, Splits,
# Tages-Flags, Aktivierung, Freibetrag, Jahreswechsel und Startgewichte aus den Angaben von .sim_build_calendar.
# Der Kern rechnet die Tagesschleife (Batch- und Marktupdate, Aktivierung, Splits, Sparplan, Handel,
# Rebalancing, Freibetrag, Vorabpauschale, Liquidation, Jahreswechsel und Abrechnungen mit Steuer) und den
# Abschluss des letzten Jahres; bis R 1.3.0 waren das die Phasen .sim_run_days (mit den Tagesschritten
# .sim_day_*), .sim_make_actions und .sim_close_years, seit E17 Stufe 1c entfallen.
# Warnungen, details-Ausgaben und Abbrueche meldet der Kern als Codes mit Werten in einem Protokoll; die
# Texte setzt .sim_engine_signal wortgleich zu R 1.3.0, in derselben Reihenfolge (cat() und warning()
# verzahnt). Warnungen und Abbrueche, die bis R 1.3.0 den Aufruf einer Phasenfunktion trugen (.perform_trade_*,
# .perform_asset_split, if-Ausdruecke, max()), tragen seit C19 den Aufruf von simulation() (.sim_restore_call).
# Gegenstuecke: python/simlev/_sim_engine.py, julia/src/sim_engine.jl.

#' Vorbereitung, Phasen 4 und 5 ueber den C++-Kern: Termine, Tages-Flags, Startgewichte, Tagesschleife und
#' Abschluss des letzten Jahres
#'
#' Eingabe: sim_mem, fl (aus .sim_build_calendar), cfg (aus .sim_check_inputs), data (Spalten fuer event_weight),
#' event_weight, split_thresh, balance_dca, harvest_loss_pot, liquidate, stopp_date, details, harvest_day.
#' Ausgabe: list(sim_mem = sim_mem nach dem Abschluss (Status, Report, Lots, Verkaeufe, Steuerbuchungen,
#' Toepfe, durch Splits geaenderte Kursreihen), tax_unpaid = nicht gedeckte Steuerzahlungen in EUR,
#' flag_harvest = Freibetragstage, tax_regimes = Steuerregime je Asset); .fee_env$paid und cfg$tariff_env
#' (Jahreszeilen, KiSt-Salden) fortgeschrieben; Warnungen des Laufs in der Reihenfolge ihres Auftretens, mit
#' details die Ausgaben dazwischen.
#' @keywords internal
#' @noRd
.sim_engine_run <- function(sim_mem, fl, cfg, data, event_weight, split_thresh, balance_dca, harvest_loss_pot,
                            liquidate, stopp_date, details, harvest_day) {
  nm <- fl$flag_assets
  n <- length(fl$flag_date)
  mk <- sim_mem[["market"]]
  as_ <- sim_mem[["assets"]]
  person <- identical(cfg$tax_mode, "person")
  fee <- function(f) if (is.null(f)) c(0, 0, 0, 0, 0) else c(1, f$fixed, f$percent, f$min, f$max)
  tax_regimes <- vapply(nm, function(a) as_[[a]][["tax_regime"]], "")
  regime <- match(tax_regimes, c("investment_fund", "capital_gains", "private_sale"), nomatch = 0L)
  # je Asset (enum AssetInt): style, start_idx, start_day, initial (setzt die Vorbereitung), regime, no_split,
  # Signal logisch (setzt C++)
  ai <- as.integer(rbind(as.integer(vapply(nm, function(a) as_[[a]][["style"]], "") == "signal"), 0L, 0L, 0L,
                         regime, as.integer(nm %in% cfg$no_split), 0L, 0L))
  ad <- as.numeric(rbind(vapply(nm, function(a) as.numeric(mk[[a]][["spread_rate"]]), numeric(1), USE.NAMES = FALSE),
                         vapply(nm, function(a) as.numeric(cfg$strategy[[a]][["share"]]), numeric(1), USE.NAMES = FALSE),
                         vapply(nm, function(a) as.numeric(as_[[a]][["bonus"]] %||% 0), numeric(1), USE.NAMES = FALSE)))
  # Freibetrag (harvest_day "MM-TT"): erster Monat * 100 + Tag, den der Zeichenvergleich wie bis 1.3.0 zulaesst
  harvest_on <- isTRUE(cfg$harvest_mode) && person
  hmd <- if (!harvest_on) 0L
         else if (is.character(harvest_day) && length(harvest_day) == 1L && grepl("^[0-9]{2}-[0-9]{2}$", harvest_day))
           as.integer(substr(harvest_day, 1L, 2L)) * 100L + as.integer(substr(harvest_day, 4L, 5L))
         else {
           md <- rep(1:12, each = 31L) * 100L + rep(1:31, 12L)
           ok <- which(sprintf("%02d-%02d", md %/% 100L, md %% 100L) >= harvest_day)
           if (length(ok)) min(md[ok]) else 9999L
         }
  split_on <- isTRUE(cfg$split_mode) && !is.null(split_thresh)
  # Vorbereitung (enum PrepInt, PrepDbl in core/prepare_core_impl.h)
  pint <- c(isTRUE(liquidate), isTRUE(fl$event_replace), split_on, person, harvest_on, hmd, fl$dca$si, fl$balance$si)
  pdbl <- c(as.numeric(stopp_date), if (split_on) as.numeric(split_thresh[[1]]) else 0,
          if (split_on) as.numeric(split_thresh[[2]]) else 0, as.numeric(cfg$start_value), fl$dca$start,
          fl$balance$start)
  tt <- sim_mem[["totals"]]
  tot0 <- c(tt$total_taxes, tt$loss_capital_gains, tt$loss_private_sales, tt$private_sale_gains_ytd,
            tt$private_sale_losses_ytd, tt$sparer_pauschbetrag_annual, tt$sparer_pauschbetrag_remaining,
            tt$sparer_pauschbetrag_used_total, tt$current_year, tt$cgt_base_taxed_ytd, tt$cgt_loss_added_ytd,
            tt$cgt_loss_used_ytd, tt$cgt_pool_start_ytd)
  env <- cfg$tariff_env
  tariff_par <- if (person && !is.null(env)) .wd_tariff_par(env$tariff, env$church_k, env$use_gp) else numeric(0)
  zve <- if (!is.null(env) && is.null(env$zve_all) && length(env$zve))
    as.numeric(rbind(as.numeric(names(env$zve)), unname(env$zve))) else numeric(0)
  # Konfiguration (enum CfgInt, CfgDbl)
  ci <- c(isTRUE(cfg$fractions), isTRUE(cfg$fees_on), isTRUE(cfg$balance_mode), isTRUE(balance_dca),
          !is.null(cfg$balance_thresh), identical(cfg$balance_thresh_type, "relative"), person,
          isTRUE(cfg$use_sparer_pauschbetrag), isTRUE(as.logical(harvest_loss_pot)), isTRUE(liquidate),
          !is.null(cfg$marginal_tax_rate), as.integer(format(stopp_date, "%Y")), !is.null(env) && !is.null(env$zve_all),
          isTRUE(details))
  cd <- c(as.numeric(cfg$balance_thresh %||% 0), as.numeric(cfg$dca_value %||% 0), as.numeric(.fee_env$paid %||% 0),
          as.numeric(cfg$effective_tax_rate %||% 0), as.numeric(cfg$marginal_tax_rate %||% 0),
          as.numeric(cfg$private_sale_threshold %||% 0), as.numeric(cfg$sparer_pauschbetrag %||% 0),
          as.numeric(cfg$soli_factor_income %||% 1), as.numeric(cfg$church_k %||% 0),
          pdbl[2L], pdbl[3L],
          if (!is.null(env) && !is.null(env$zve_all)) as.numeric(env$zve_all) else 0)
  inp <- list(
    n = as.integer(n), day = as.numeric(fl$flag_date),
    price = lapply(nm, function(a) as.numeric(mk[[a]][["asset_price"]])),
    sig_buy = lapply(nm, function(a) mk[[a]][["signal_buy"]]),
    sig_sell = lapply(nm, function(a) mk[[a]][["signal_sell"]]),
    event_w = if (!is.null(event_weight)) lapply(nm, function(a) {
      col <- event_weight[[a]]
      if (is.null(col)) NULL else as.numeric(data[[col]])
    }),
    base_rates = if (person) lapply(nm, function(a) as.numeric(mk[[a]][["base_rates"]])),
    ai = ai, ad = ad, ci = as.integer(ci), cd = as.numeric(cd),
    fees = c(fee(cfg$fee_order), fee(cfg$fee_dca)), tot0 = as.numeric(tot0),
    tariff_par = as.numeric(tariff_par), zve = as.numeric(zve),
    pi = as.integer(pint), pd = as.numeric(pdbl),
    start = vapply(nm, function(a) as.numeric(as_[[a]][["start"]]), numeric(1), USE.NAMES = FALSE),
    filled = if (any(fl$flag_filled)) as.integer(fl$flag_filled),
    event = if (!is.null(fl$flag_event)) as.integer(fl$flag_event),
    d_days = fl$dca$days, d_dcode = fl$dca$dcode, b_days = fl$balance$days, b_dcode = fl$balance$dcode)
  out <- .Call(C_sim_engine_run, inp)
  fields <- c("count", "price", "worth", "money", "total", "target", "actual", "differ")
  for (k in seq_along(nm)) {
    a <- nm[k]
    s <- out$status[(8L * (k - 1L) + 1L):(8L * k)]
    sim_mem[["status"]][[a]] <- stats::setNames(as.list(s), fields)
    sim_mem[["report"]][[a]] <- out$report[[k]]
    tr <- sim_mem[["trades"]][[a]]
    tr[["buys"]] <- out$buys[[k]]
    tr[["sells"]] <- out$sells[[k]]
    tr[["taxes"]] <- out$taxes[[k]]
    sim_mem[["trades"]][[a]] <- tr
    if (!is.null(out$prices[[k]])) sim_mem[["market"]][[a]][["asset_price"]] <- out$prices[[k]]
  }
  tv <- out$totals
  tf <- c("total_taxes", "loss_capital_gains", "loss_private_sales", "private_sale_gains_ytd", "private_sale_losses_ytd",
          "sparer_pauschbetrag_annual", "sparer_pauschbetrag_remaining", "sparer_pauschbetrag_used_total",
          "current_year", "cgt_base_taxed_ytd", "cgt_loss_added_ytd", "cgt_loss_used_ytd", "cgt_pool_start_ytd")
  for (j in seq_along(tf)) sim_mem[["totals"]][[tf[j]]] <- if (tf[j] == "current_year") as.integer(tv[j]) else tv[j]
  if (!is.null(env) && person) {   # Tarifweg: Jahreszeilen (wie .tariff_close), KiSt-Salden, Erstattung
    rw <- matrix(out$rows, nrow = 25L)
    for (i in seq_len(ncol(rw))) {
      r <- rw[, i]
      env$rows[[length(env$rows) + 1L]] <- data.frame(
        year = as.integer(r[1]), taxable_income = r[2],
        church_tax_paid_deductible = r[3], church_tax_refunded = r[4], church_tax_net_deduction = r[5],
        taxable_income_net = r[6], deduction_effect = r[7],
        gain_p23 = r[8], income_tax_p23 = r[9], soli_p23 = r[10], church_tax_p23 = r[11], tax_p23 = r[12],
        capital_income = r[13], abgeltung_burden = r[14], church_tax_withheld_k = r[15],
        tariff_income_tax_k = r[16], tariff_soli_k = r[17], tariff_church_tax_k = r[18], tariff_burden = r[19],
        burden_without_gp = r[20], burden_with_gp = r[21], guenstiger = r[22] != 0,
        settlement = r[23], refund = r[24], church_tax_settlement_next_year = r[25])
    }
    ks <- matrix(out$ks, nrow = 2L)
    for (i in seq_len(ncol(ks))) env$ks[as.character(as.integer(ks[1, i]))] <- ks[2, i]
    env$refund_due <- out$refund_due
    env$due_info <- NULL
  }
  .fee_env$paid <- out$fee_paid
  .sim_engine_signal(out$events, out$ev_ints, out$ev_vals, out$error, nm, fl$flag_date)
  list(sim_mem = sim_mem, tax_unpaid = out$tax_unpaid, flag_harvest = bitwAnd(out$flags, 128L) != 0L,
       tax_regimes = tax_regimes)
}

#' Warnungen, details-Ausgaben und Abbruch des Kerns mit den Texten und Aufrufen der bisherigen Phasen
#' ausloesen (in der Reihenfolge des Protokolls: cat() und warning() verzahnt)
#' @keywords internal
#' @noRd
.sim_engine_signal <- function(ev, ev_ints, ev_vals, err, nm, flag_date) {
  cl <- sys.call()   # C19: Phase in .SIM_PHASES, .sim_restore_call setzt den Aufruf von simulation()
  dstr <- function(d) as.character(structure(as.numeric(flag_date[d]), class = "Date"))
  for (i in seq_along(ev$code)) {
    code <- ev$code[i]
    a <- if (ev$asset[i] > 0L) nm[ev$asset[i]] else NA_character_
    if (code >= 200L) {
      .sim_engine_detail(code, a, ev$aux[i], ev_vals[ev$v_off[i] + seq_len(ev$nv[i])],
                         ev_ints[ev$y_off[i] + seq_len(ev$ny[i])], nm, ev$day[i], flag_date)
      next
    }
    w <- switch(as.character(code),
      "1" = simpleWarning(sprintf("perform_trade_buy: ung\u00fcltiger Kurs (%.4f) f\u00fcr %s am %s; der Kauf wird \u00fcbersprungen.",
                                  ev$d0[i], a, dstr(ev$day[i])), cl),
      "2" = simpleWarning(sprintf("perform_trade_sell: angeforderte Verkaufsmenge %.4f \u00fcbersteigt den Bestand %.4f von %s; verkauft wird der gesamte Bestand.",
                                  ev$d0[i], ev$d1[i], a), cl),
      "3" = simpleWarning(sprintf("simulation: liquidate = TRUE: Position '%s' (Wert %.2f EUR) wurde nicht verkauft, weil die Ordergeb\u00fchr den Erl\u00f6s \u00fcbersteigt.",
                                  a, ev$d0[i])),
      "4" = simpleWarning("no non-missing arguments to max; returning -Inf", cl),
      "5" = {
        simpleWarning(sprintf("simulation: %s von %.2f EUR am %s: das Depot reicht nicht aus; %.2f EUR bleiben als negativer Geldbestand (Steuerschuld) bei '%s'.",
                              .sim_engine_label(ev$aux[i], ev_ints[ev$y_off[i] + seq_len(ev$ny[i])]), ev$d0[i],
                              dstr(ev$day[i]), ev$d1[i], a))
      },
      "6" = simpleWarning(paste0(sprintf("simulation: Paragraf 23 EStG: Gewinne (%.2f EUR) erreichen die Freigrenze (%.2f EUR), ",
                                         ev$d0[i], ev$d1[i]),
                                 "aber 'marginal_tax_rate' ist nicht gesetzt.\n",
                                 "Verwendet wird 42 % (Spitzensteuersatz); marginal_tax_rate in Prozent angeben (z. B. 42).")),
      stop(sprintf("simulation: interner Fehler: unbekannter Ereigniscode %d der Tagesengine.", code)))
    warning(w)
  }
  if (!is.null(err)) {
    if (err$code == 101L)
      stop(simpleError(sprintf("perform_asset_split: ratio muss > 0 sein (Split-Verh\u00e4ltnis), nicht %s.", format(err$d0)),
                       cl))
    stop(simpleError("missing value where TRUE/FALSE needed", cl))
  }
  invisible(NULL)
}

# Bezeichnung einer Steuerzahlung (.pay_tax label): 0 Vorabpauschale, 1 Paragraf-23-Steuer, 2 Veranlagung der Jahre
.sim_engine_label <- function(aux, years) {
  switch(as.character(aux), "0" = "Vorabpauschale", "1" = "\u00a7 23-Steuer",
         sprintf("Steuer aus der Veranlagung %s", paste(years, collapse = "/")))
}

# Anlass der Kaeufe und Verkaeufe (enum Reason in engine_core_impl.h)
.SIM_ENGINE_REASONS <- c("Handelssignal:", "Rebalancing:", "Rebalancing/Signal-Einstieg:", "Rebalancing/Signal-Ausstieg:",
                         "Liquidation:", "Steuerereignis:", "Split:", "Freibetrag:")

#' details-Ausgabe eines Ereignisses (DT_* in engine_core_impl.h) wortgleich zu den bisherigen cat()-Aufrufen
#' der Phasen (.perform_trade_buy/.perform_trade_sell, .sim_day_*, .pay_one, .settle_*, .handle_year_change,
#' .tariff_close, .perform_asset_split, .perform_gain_harvest)
#' @keywords internal
#' @noRd
.sim_engine_detail <- function(code, name, aux, v, ints, nm, day, flag_date) {
  date <- structure(as.numeric(flag_date[day]), class = "Date")
  ds <- as.character(date)
  switch(as.character(code),
    "201" = cat(sprintf("%s\tKauf %.2fx %s zu %.2f EUR je Anteil am %s\n", .SIM_ENGINE_REASONS[aux + 1L], v[1], name, v[2], ds)),
    "202" = cat(sprintf("\t\t=> Vorabpauschale-Anrechnung (\u00a7 19 InvStG): %.2f EUR\n", v[1])),
    "203" = cat(sprintf("\t\t=> Sparerpauschbetrag: %.2f EUR (verbleibend: %.2f EUR)\n", v[1], v[2])),
    "204" = cat(sprintf("\t\t=> Steuerfreier Gewinn (Haltedauer > 1 Jahr): %.2f EUR\n", v[1])),
    "205" = cat(sprintf("\t\t=> Nicht verrechenbarer Verlust (Haltedauer > 1 Jahr): %.2f EUR\n", v[1])),
    "206" = cat(sprintf("\t\t=> Steuerpflichtiger Gewinn (Haltedauer < 1 Jahr): %.2f EUR (seit Jahresbeginn: %.2f EUR)\n", v[1], v[2])),
    "207" = cat(sprintf("\t\t=> Verrechenbarer Verlust (Haltedauer < 1 Jahr): %.2f EUR (seit Jahresbeginn: %.2f EUR)\n", v[1], v[2])),
    "208" = cat(sprintf("%s\tVerkauf %.2fx %s zu %.2f EUR je Anteil am %s\n", .SIM_ENGINE_REASONS[aux + 1L], v[1], name, v[2], ds)),
    "209" = cat(sprintf("\t\t=> %s: %.2f EUR; Steuer: %.2f EUR\n", ifelse(v[1] < 0, "Verlust", "Gewinn"), v[1], v[2])),
    "210" = cat(sprintf("Freibetrag:\tRealisierung von Gewinnen %.2f EUR mit %.4fx %s (freier Sparer-Pauschbetrag/Verlusttopf %.2f EUR)\n",
                        v[1], v[2], name, v[3])),
    "211" = cat(sprintf("Split-Ereignis:\t%s %s im Verh\u00e4ltnis %s am %s\n", if (aux == 1L) "Split" else "Reverse-Split", name,
                        if (aux == 1L) paste("1 :", format(v[1], digits = 5)) else paste(format(v[1], digits = 5), ": 1"),
                        format(date, "%Y-%m-%d"))),
    "212" = cat(sprintf("Split-Ereignis:\t%s ohne Bestand: Kursreihe %s %s am %s\n", name, if (aux == 1L) "1 :" else ": 1",
                        format(v[1], digits = 5), date)),
    "213" = cat(sprintf("Marktereignis:\tHandel mit %s ab jetzt m\u00f6glich.\n", paste(nm[ints + 1L], collapse = ", "))),
    "214" = {
      flow_values <- stats::setNames(v[-1L], nm[ints + 1L])
      placeholder <- paste(sprintf("%s %%.2f EUR", names(flow_values)), collapse = "; ")
      format_text <- sprintf("Einzahlung:\t%%.2f EUR in das Depot am %%s\n\t\t=> %s\n", placeholder)
      cat(do.call(sprintf, c(list(format_text, v[1L]), list(date), as.list(flow_values))))
    },
    "215" = cat(sprintf("Rebalancing:\tErzwungenes Rebalancing am %s wegen neu handelbarer Assets: %s\n",
                        date, paste(nm[ints + 1L], collapse = ", "))),
    "216" = cat(sprintf("Rebalancing:\tRebalancing am %s (max. Abweichung: %.2f%% > Schwelle: %.2f%%)\n", date, v[1], v[2])),
    "217" = cat(sprintf("\t\t=> %s: Ziel=%.1f%%, Ist=%.1f%%, Abweichung=%.2f%%\n", name, v[1], v[2], v[3])),
    "218" = cat(sprintf("Rebalancing:\tKein Rebalancing am %s (max. Abweichung: %.2f%% < Schwelle: %.2f%%)\n", date, v[1], v[2])),
    "219" = cat(sprintf("\t\t%.2f EUR von %s in den Rebalancing-Topf\n", v[1], name)),
    "220" = cat(sprintf("Rebalancing:\t%.2f EUR aus dem Rebalancing-Topf an %s\n", v[1], name)),
    "221" = cat(sprintf("\t\t=> %s h\u00e4lt %.2f EUR als Cash-Reserve (Signal inaktiv)\n", name, v[1])),
    "222" = cat(sprintf("\t\tRestverteilung von %.2f EUR aus dem Rebalancing-Topf\n", v[1])),
    "223" = cat(sprintf("\t\t=> %.2f EUR an %s\n", v[1], name)),
    "224" = cat(sprintf("Steuerereignis:\tVorabpauschale %s: %.2f EUR festgesetzt am %s (Zufluss und Steuer am ersten Handelstag des Folgejahres)\n",
                        name, v[1], date)),
    "225" = cat(sprintf("Steuerereignis:\tZahlung %s %.2f EUR f\u00fcr %s aus dem Geldbestand am %s\n",
                        .sim_engine_label(aux, ints), v[1], name, date)),
    "226" = cat(sprintf("Steuerereignis:\tTeilzahlung %s %.2f EUR aus dem Geldbestand am %s\n", .sim_engine_label(aux, ints), v[1], date)),
    "227" = cat(sprintf("\t\t=> Anteile verkauft f\u00fcr den Rest von %.2f EUR (%s)\n", v[1], .sim_engine_label(aux, ints))),
    "228" = cat(sprintf("Steuerereignis:\tVeranlagung %d: Nachzahlung %.2f EUR (davon \u00a7 23 %.2f EUR, Kirchensteuer-Sonderausgaben %.2f EUR%s) am %s, aufgeteilt %s\n",
                        as.integer(v[1]), v[2], v[3], v[4], if (bitwAnd(aux, 1L)) sprintf(", G\u00fcnstigerpr\u00fcfung %.2f EUR", v[5]) else "",
                        date, if (bitwAnd(aux, 2L)) "nach dem \u00a7 23-Jahressaldo je Asset" else "zu gleichen Teilen auf die Assets")),
    "229" = cat(sprintf("\t\t=> Anteil %s: %.2f EUR\n", name, v[1])),
    "230" = cat(sprintf("Steuerereignis:\t\u00a7 23 EStG: Steuer %.2f EUR (%s) am %s\n", v[1], name, date)),
    "231" = cat(sprintf("Steuerereignis:\tG\u00fcnstigerpr\u00fcfung: Erstattung %.2f EUR in den Geldbestand am %s\n", v[1], date)),
    "232" = cat(sprintf("Steuerereignis:\tVorabpauschale %s (festgesetzt %s): %.2f EUR, nach TFS %.2f EUR, SPB %.2f EUR, Steuer %.2f EUR am %s\n",
                        name, format(structure(v[1], class = "Date")), v[2], v[3], v[4], v[5], date)),
    "240" = {
      cat(sprintf("\n\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n"))
      cat(sprintf("  JAHRESWECHSEL: %d -> %d\n", as.integer(v[1]), as.integer(v[2])))
      cat(sprintf("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n"))
    },
    "241" = {
      cat(sprintf("  \u00a7 23 EStG: Verlustvortrag verwendet: %.2f EUR\n", v[1]))
      cat(sprintf("             Verbleibender Vortrag: %.2f EUR\n", v[2]))
    },
    "242" = {
      cat(sprintf("  \u00a7 23 EStG Jahres\u00fcbersicht %d:\n", as.integer(v[1])))
      cat(sprintf("    Bruttogewinne (< 1 Jahr):    %10.2f EUR\n", v[2]))
      cat(sprintf("    Bruttoverluste (< 1 Jahr):   %10.2f EUR\n", v[3]))
      cat(sprintf("    Interne Verrechnung:         %10.2f EUR\n", v[4]))
      cat(sprintf("    Verlustvortrag-Verrechnung:  %10.2f EUR\n", v[5]))
      cat(sprintf("    \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n"))
      cat(sprintf("    Netto-Ergebnis:              %10.2f EUR\n", v[6]))
    },
    "243" = {
      marginal_tax_rate <- v[4]; soli_factor_income <- v[5]; church_factor <- v[6]
      cat(sprintf("\n  \u26a0 FREIGRENZE ERREICHT!\n"))
      cat(sprintf("    Jahressaldo %.2f EUR >= Freigrenze %.2f EUR\n", v[1], v[2]))
      cat(sprintf("    \u2192 GESAMTER Gewinn nach Verlustvortrag steuerpflichtig: %.2f EUR (Freigrenze, kein Freibetrag!)\n", v[3]))
      if (aux == 1L) {
        cat("    \u2192 Steuer nach dem Einkommensteuertarif (ESt + Soli + KiSt des \u00a7 23-Zuwachses): siehe Jahresveranlagung unten (Zeile \u00a7 23)\n")
      } else {
        cat(sprintf("    \u2192 Steuersatz: %.1f%%%s%s\n", marginal_tax_rate * 100, if (soli_factor_income > 1) sprintf(" + %.1f%%%% Soli", (soli_factor_income - 1) * 100) else "",
                    if (church_factor > 0) sprintf(" + %.1f%% KiSt", church_factor * 100) else ""))
        cat(sprintf("    \u2192 Steuerlast: %.2f EUR\n", v[7]))
      }
    },
    "244" = {
      cat(sprintf("\n  Nettoverlust %.2f EUR \u2192 Vortrag ins n\u00e4chste Jahr\n", v[1]))
      cat(sprintf("  Gesamter Verlustvortrag: %.2f EUR\n", v[2]))
    },
    "245" = cat(sprintf("\n  \u2713 Jahressaldo %.2f EUR < Freigrenze %.2f EUR \u2192 STEUERFREI (Verlustvortrag unver\u00e4ndert)\n", v[1], v[2])),
    "246" = cat(sprintf("\n  Keine steuerpflichtigen \u00a7 23 Vorg\u00e4nge in %d\n", as.integer(v[1]))),
    "247" = {
      cat(sprintf("\n  Sparerpauschbetrag %d:\n", as.integer(v[1])))
      cat(sprintf("    Jahresbetrag:    %10.2f EUR\n", v[2]))
      cat(sprintf("    Verwendet:       %10.2f EUR\n", v[3]))
      cat(sprintf("    Verfallen:       %10.2f EUR\n", v[4]))
    },
    "248" = cat(sprintf("  \u00a7 20 EStG: Unterj\u00e4hrige Verlustverrechnung -> Erstattung %.2f EUR in den Geldbestand\n", v[1])),
    "249" = cat(sprintf("  \u00a7 20 EStG: Verlust gibt Sparer-Pauschbetrag frei: %.2f EUR (genutzt %d: %.2f EUR, Verlusttopf %.2f EUR)\n",
                        v[1], as.integer(v[2]), v[3], v[4])),
    "250" = {   # Jahreszeile in der Reihenfolge TR_* (tariff_core_impl.h)
      year <- as.integer(v[1]); X1 <- v[21]; fav <- v[22] != 0; D <- v[23]
      cat(sprintf("  Tarif %d: zvE %.2f EUR - KiSt-Sonderausgaben %.2f EUR (gezahlt %.2f, erstattet %.2f) = %.2f EUR (Wirkung %.2f EUR)\n",
                  year, v[2], v[5], v[3], v[4], v[6], v[7]))
      if (bitwAnd(aux, 2L)) cat(sprintf("    \u00a7 23: Gewinn %.2f EUR -> Steuerlast ESt %.2f + Soli %.2f + KiSt %.2f = %.2f EUR\n",
                                        v[8], v[9], v[10], v[11], v[12]))
      if (bitwAnd(aux, 1L)) cat(sprintf("    G\u00fcnstigerpr\u00fcfung: K %.2f EUR, Abgeltungsteuer %.2f EUR (KiSt %.2f), Tarif auf K %.2f EUR (ESt %.2f + Soli %.2f + KiSt %.2f); Belastung ohne %.2f / mit %s EUR -> %s\n",
                                        v[13], v[14], v[15], v[19], v[16], v[17], v[18], v[20], if (is.na(X1)) "-" else sprintf("%.2f", X1),
                                        if (fav) "Tarif" else "Abgeltungsteuer bleibt"))
      cat(sprintf("    Abrechnung: %s %.2f EUR; KiSt-Bescheid %+.2f EUR (Sonderausgabe %d)\n",
                  if (D >= 0) "Nachzahlung" else "Erstattung", abs(D), v[25], year + 1L))
    },
    "251" = {
      cat(sprintf("\n  Tracker zur\u00fcckgesetzt f\u00fcr Jahr %d\n", as.integer(v[1])))
      cat(sprintf("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n\n"))
    },
    stop(sprintf("simulation: interner Fehler: unbekannter Ereigniscode %d der Tagesengine.", code)))
  invisible(NULL)
}
