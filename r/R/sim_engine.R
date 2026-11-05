# =============================================================================
# simulation(), Phasen 4 und 5 ueber den gemeinsamen C++-Kern: Tagesengine core/engine_core_impl.h
# =============================================================================
# rechnet der Kern auch die Vorbereitung (core/prepare_core_impl.h): Termine, Splits,
# Tages-Flags, Aktivierung, Freibetrag, Jahreswechsel und Startgewichte aus den Angaben von .sim_build_calendar.
# Der Kern rechnet die Tagesschleife (Batch- und Marktupdate, Aktivierung, Splits, Sparplan, Handel,
# Rebalancing, Freibetrag, Vorabpauschale, Liquidation, Jahreswechsel und Abrechnungen mit Steuer) und den
# Abschluss des letzten Jahres; bis R 1.3.0 waren das die Phasen .sim_run_days (mit den Tagesschritten
# .sim_day_*), .sim_make_actions und .sim_close_years, entfallen.
# Warnungen, details-Ausgaben und Abbrueche meldet der Kern als Codes mit Werten in einem Protokoll; die
# Texte setzt .sim_engine_signal wortgleich zu R 1.3.0, in derselben Reihenfolge (cat() und warning()
# verzahnt). Warnungen und Abbrueche, die bis R 1.3.0 den Aufruf einer Phasenfunktion trugen (.perform_trade_*,
# .perform_asset_split, if-Ausdruecke, max()), tragen den Aufruf von simulation() (.sim_restore_call).
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
#' ausloesen (in der Reihenfolge des Protokolls: cat() und warning() verzahnt); Texte aus .MELD_ENGINE_SIGNAL
#' (R/meldungen.R, erzeugt aus core/meldungen.tsv)
#' @keywords internal
#' @noRd
.sim_engine_signal <- function(ev, ev_ints, ev_vals, err, nm, flag_date) {
  cl <- sys.call()   # Phase in .SIM_PHASES, .sim_restore_call setzt den Aufruf von simulation()
  m <- .MELD_ENGINE_SIGNAL
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
      "1" = simpleWarning(sprintf(m[["1"]], ev$d0[i], a, dstr(ev$day[i])), cl),
      "2" = simpleWarning(sprintf(m[["2"]], ev$d0[i], ev$d1[i], a), cl),
      "3" = simpleWarning(sprintf(m[["3"]], a, ev$d0[i])),
      "4" = simpleWarning(m[["4"]], cl),
      "5" = {
        simpleWarning(sprintf(m[["5"]], .sim_engine_label(ev$aux[i], ev_ints[ev$y_off[i] + seq_len(ev$ny[i])]), ev$d0[i],
                              dstr(ev$day[i]), ev$d1[i], a))
      },
      "6" = simpleWarning(paste0(sprintf(m[["6"]], ev$d0[i], ev$d1[i]), m[["6.rest"]])),
      stop(sprintf(m[["unbekannt"]], code)))
    warning(w)
  }
  if (!is.null(err)) {
    if (err$code == 101L)
      stop(simpleError(sprintf(m[["101"]], format(err$d0)), cl))
    stop(simpleError(m[["na"]], cl))
  }
  invisible(NULL)
}

# Bezeichnung einer Steuerzahlung (.pay_tax label): 0 Vorabpauschale, 1 Paragraf-23-Steuer, 2 Veranlagung der Jahre
.sim_engine_label <- function(aux, years) {
  m <- .MELD_ENGINE_LABEL
  switch(as.character(aux), "0" = m[["0"]], "1" = m[["1"]], sprintf(m[["2"]], paste(years, collapse = "/")))
}

#' details-Ausgabe eines Ereignisses (DT_* in engine_core_impl.h) wortgleich zu den bisherigen cat()-Aufrufen
#' der Phasen (.perform_trade_buy/.perform_trade_sell, .sim_day_*, .pay_one, .settle_*, .handle_year_change,
#' .tariff_close, .perform_asset_split, .perform_gain_harvest); Texte aus .MELD_ENGINE_DETAIL, Anlass der Kaeufe
#' und Verkaeufe (enum Reason in engine_core_impl.h) aus .MELD_ENGINE_REASON (R/meldungen.R)
#' @keywords internal
#' @noRd
.sim_engine_detail <- function(code, name, aux, v, ints, nm, day, flag_date) {
  m <- .MELD_ENGINE_DETAIL
  date <- structure(as.numeric(flag_date[day]), class = "Date")
  ds <- as.character(date)
  switch(as.character(code),
    "201" = cat(sprintf(m[["201"]], .MELD_ENGINE_REASON[aux + 1L], v[1], name, v[2], ds)),
    "202" = cat(sprintf(m[["202"]], v[1])),
    "203" = cat(sprintf(m[["203"]], v[1], v[2])),
    "204" = cat(sprintf(m[["204"]], v[1])),
    "205" = cat(sprintf(m[["205"]], v[1])),
    "206" = cat(sprintf(m[["206"]], v[1], v[2])),
    "207" = cat(sprintf(m[["207"]], v[1], v[2])),
    "208" = cat(sprintf(m[["208"]], .MELD_ENGINE_REASON[aux + 1L], v[1], name, v[2], ds)),
    "209" = cat(sprintf(m[["209"]], ifelse(v[1] < 0, m[["209.verlust"]], m[["209.gewinn"]]), v[1], v[2])),
    "210" = cat(sprintf(m[["210"]], v[1], v[2], name, v[3])),
    "211" = cat(sprintf(m[["211"]], if (aux == 1L) m[["211.split"]] else m[["211.reverse"]], name,
                        sprintf(if (aux == 1L) m[["211.v1"]] else m[["211.v2"]], format(v[1], digits = 5)),
                        format(date, "%Y-%m-%d"))),
    "212" = cat(sprintf(m[["212"]], name, if (aux == 1L) m[["212.v1"]] else m[["212.v2"]], format(v[1], digits = 5), date)),
    "213" = cat(sprintf(m[["213"]], paste(nm[ints + 1L], collapse = ", "))),
    "214" = {
      # Vorlage mit den Namen im Format (wie bis 1.5.2: Kopf, je Asset "<Name> %.2f EUR", Zeilenende)
      flow_values <- stats::setNames(v[-1L], nm[ints + 1L])
      placeholder <- paste(sprintf(sub("%.2f", "%%.2f", m[["214.teil"]], fixed = TRUE), names(flow_values)), collapse = "; ")
      format_text <- paste0(m[["214"]], placeholder, "\n")
      cat(do.call(sprintf, c(list(format_text, v[1L]), list(date), as.list(flow_values))))
    },
    "215" = cat(sprintf(m[["215"]], date, paste(nm[ints + 1L], collapse = ", "))),
    "216" = cat(sprintf(m[["216"]], date, v[1], v[2])),
    "217" = cat(sprintf(m[["217"]], name, v[1], v[2], v[3])),
    "218" = cat(sprintf(m[["218"]], date, v[1], v[2])),
    "219" = cat(sprintf(m[["219"]], v[1], name)),
    "220" = cat(sprintf(m[["220"]], v[1], name)),
    "221" = cat(sprintf(m[["221"]], name, v[1])),
    "222" = cat(sprintf(m[["222"]], v[1])),
    "223" = cat(sprintf(m[["223"]], v[1], name)),
    "224" = cat(sprintf(m[["224"]], name, v[1], date)),
    "225" = cat(sprintf(m[["225"]], .sim_engine_label(aux, ints), v[1], name, date)),
    "226" = cat(sprintf(m[["226"]], .sim_engine_label(aux, ints), v[1], date)),
    "227" = cat(sprintf(m[["227"]], v[1], .sim_engine_label(aux, ints))),
    "228" = cat(sprintf(m[["228"]], as.integer(v[1]), v[2], v[3], v[4], if (bitwAnd(aux, 1L)) sprintf(m[["228.guenstiger"]], v[5]) else "",
                        date, if (bitwAnd(aux, 2L)) m[["228.asset"]] else m[["228.gleich"]])),
    "229" = cat(sprintf(m[["229"]], name, v[1])),
    "230" = cat(sprintf(m[["230"]], v[1], name, date)),
    "231" = cat(sprintf(m[["231"]], v[1], date)),
    "232" = cat(sprintf(m[["232"]], name, format(structure(v[1], class = "Date")), v[2], v[3], v[4], v[5], date)),
    "240" = {
      cat(sprintf(m[["240.1"]]))
      cat(sprintf(m[["240.2"]], as.integer(v[1]), as.integer(v[2])))
      cat(sprintf(m[["240.3"]]))
    },
    "241" = {
      cat(sprintf(m[["241.1"]], v[1]))
      cat(sprintf(m[["241.2"]], v[2]))
    },
    "242" = {
      cat(sprintf(m[["242.1"]], as.integer(v[1])))
      cat(sprintf(m[["242.2"]], v[2]))
      cat(sprintf(m[["242.3"]], v[3]))
      cat(sprintf(m[["242.4"]], v[4]))
      cat(sprintf(m[["242.5"]], v[5]))
      cat(sprintf(m[["242.6"]]))
      cat(sprintf(m[["242.7"]], v[6]))
    },
    "243" = {
      marginal_tax_rate <- v[4]; soli_factor_income <- v[5]; church_factor <- v[6]
      cat(sprintf(m[["243.1"]]))
      cat(sprintf(m[["243.2"]], v[1], v[2]))
      cat(sprintf(m[["243.3"]], v[3]))
      if (aux == 1L) {
        cat(m[["243.tarif"]])
      } else {
        cat(sprintf(m[["243.satz"]], marginal_tax_rate * 100, if (soli_factor_income > 1) sprintf(m[["243.soli"]], (soli_factor_income - 1) * 100) else "",
                    if (church_factor > 0) sprintf(m[["243.kist"]], church_factor * 100) else ""))
        cat(sprintf(m[["243.last"]], v[7]))
      }
    },
    "244" = {
      cat(sprintf(m[["244.1"]], v[1]))
      cat(sprintf(m[["244.2"]], v[2]))
    },
    "245" = cat(sprintf(m[["245"]], v[1], v[2])),
    "246" = cat(sprintf(m[["246"]], as.integer(v[1]))),
    "247" = {
      cat(sprintf(m[["247.1"]], as.integer(v[1])))
      cat(sprintf(m[["247.2"]], v[2]))
      cat(sprintf(m[["247.3"]], v[3]))
      cat(sprintf(m[["247.4"]], v[4]))
    },
    "248" = cat(sprintf(m[["248"]], v[1])),
    "249" = cat(sprintf(m[["249"]], v[1], as.integer(v[2]), v[3], v[4])),
    "250" = {   # Jahreszeile in der Reihenfolge TR_* (tariff_core_impl.h)
      year <- as.integer(v[1]); X1 <- v[21]; fav <- v[22] != 0; D <- v[23]
      cat(sprintf(m[["250.1"]], year, v[2], v[5], v[3], v[4], v[6], v[7]))
      if (bitwAnd(aux, 2L)) cat(sprintf(m[["250.p23"]], v[8], v[9], v[10], v[11], v[12]))
      if (bitwAnd(aux, 1L)) cat(sprintf(m[["250.guenstiger"]],
                                        v[13], v[14], v[15], v[19], v[16], v[17], v[18], v[20], if (is.na(X1)) "-" else sprintf(m[["250.x1"]], X1),
                                        if (fav) m[["250.tarif"]] else m[["250.bleibt"]]))
      cat(sprintf(m[["250.abrechnung"]], if (D >= 0) m[["250.nach"]] else m[["250.erst"]], abs(D), v[25], year + 1L))
    },
    "251" = {
      cat(sprintf(m[["251.1"]], as.integer(v[1])))
      cat(sprintf(m[["251.2"]]))
    },
    stop(sprintf(.MELD_ENGINE_SIGNAL[["unbekannt"]], code)))
  invisible(NULL)
}
