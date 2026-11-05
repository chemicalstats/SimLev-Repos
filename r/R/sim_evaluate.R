# =============================================================================
# simulation(), Phase 6: Auswertung und Ergebnisobjekt
# =============================================================================
# rechnet der C++-Kern core/evaluate_core_impl.h die Auswertung: Depotwert und Zufluesse je
# Tag, CAGR (mit Einzahlungen geldgewichtet ueber XIRR), TTWROR, zeitgewichteter Wertindex, Drawdowns,
# Tagesrenditen, Performance- und Risikokennzahlen, Kaeufe/Verkaeufe je Jahr und die Ursachen nicht definierter
# Kennzahlen (bis R 1.3.0 .sim_compact_trades, .sim_returns, .sim_risk_stats, .sim_undefined_metrics). Warnungen,
# Abbrueche und Ursachen meldet der Kern als Codes mit Werten; die Texte setzt .sim_evaluate wortgleich zu
# R 1.3.0. In R bleiben die Spalte bzw. Zahl risk_free (Typen von data, Meldungen), die Texte und das
# Ergebnisobjekt (.sim_result). Gegenstuecke: python/simlev/_sim_evaluate.py, julia/src/sim_evaluate.jl.

#' Ausdruck auswerten, Warnungen und einen Fehler festhalten statt sie zu melden
#'
#' Zweck: risk_free rechnet R wie bis 1.3.0 erst nach den Meldungen von .sim_returns; der Kern braucht die
#' Reihe aber vorher. .sim_capture rechnet sie vorab und haelt die Bedingungen fest, .sim_evaluate meldet sie
#' an der Stelle von R 1.3.0 (warning(cond) bzw. stop(cond); Aufruf und Text unveraendert).
#' Eingabe: expr (unausgewertet). Ausgabe: list(value, conds, failed).
#' @keywords internal
#' @noRd
.sim_capture <- function(expr) {
  conds <- list()
  value <- withCallingHandlers(
    tryCatch(expr, error = function(e) {
      conds[[length(conds) + 1L]] <<- e
      NULL
    }),
    warning = function(w) {
      conds[[length(conds) + 1L]] <<- w
      invokeRestart("muffleWarning")
    })
  list(value = value, conds = conds,
       failed = length(conds) > 0L && inherits(conds[[length(conds)]], "error"))
}

#' Reihe risk_free (wie bis R 1.3.0 in .sim_risk_stats)
#'
#' Zweck: risk_free als Zahl (Prozent p. a., NULL wie 0) auf alle Tage verteilen bzw. als Spalte von data lesen.
#' Eingabe: risk_free (Argument von simulation()), data, n_days_sim. Ausgabe: Zahlenvektor (Prozent).
#' @keywords internal
#' @noRd
.sim_risk_free <- function(risk_free, data, n_days_sim) {
  if (is.null(risk_free)) risk_free <- 0          # NULL explizit wie 0 behandeln
  if (is.character(risk_free)) {
    if (!risk_free %in% names(data)) stop(sprintf("risk_free: Spalte '%s' fehlt im Datensatz.", risk_free))
    as.numeric(data[[risk_free]])
  } else rep(as.numeric(risk_free), n_days_sim)
}

# Namen der Kennzahlen und Ursachen (enum Stat, Metric, Reason in core/evaluate_core_impl.h)
.SIM_EVAL_STATS <- c("mean", "sd", "cv", "risk_free", "skewness", "kurtosis", "lpm", "hpm", "sharpe", "sortino",
                     "calmar", "omega", "gain_to_pain", "serenity", "martin_ratio", "max_drawdown",
                     "average_drawdown", "ulcer_index", "longest_drawdown", "avg_recovery_time")
.SIM_EVAL_METRICS <- c("cagr", "ttwror", .SIM_EVAL_STATS, "buys", "sells")
.SIM_EVAL_REASONS <- c("too_short", "negative_end_value", "no_irr_solution", "zero_start_value",
                       "nonpositive_twr_index", "not_finite", "zero_mean_return", "zero_volatility",
                       "no_negative_returns", "no_drawdown", "no_recovery")

#' Klartext einer Ursache (enum Detail in core/evaluate_core_impl.h); Texte aus .MELD_EVAL_DETAIL (R/meldungen.R)
#' @keywords internal
#' @noRd
.sim_eval_detail <- function(d, v, why_text) {
  m <- .MELD_EVAL_DETAIL
  dstr <- function(z) format(structure(z, class = "Date"))
  switch(as.character(d),
    "0" = sprintf(m[["0"]], .n_tage(v[1])),
    "1" = sprintf(m[["1"]], v[1]),
    "2" = sprintf(m[["2"]], v[1], v[2]),
    "3" = sprintf(m[["3"]], v[1], v[2], v[3]),
    "4" = sprintf(m[["4"]], v[1]),
    "5" = sprintf(m[["5"]], dstr(v[1]), v[2]),
    "6" = m[["6"]],
    "7" = m[["7"]],
    "8" = sprintf(m[["8"]], as.integer(v[1]), if (v[1] == 1) m[["8.eins"]] else m[["8.mehr"]], as.integer(v[2])),
    "9" = m[["9"]],
    "10" = sprintf(m[["10"]], as.integer(v[1])),
    "11" = m[["11"]],
    "12" = sprintf(m[["12"]], as.integer(v[1])),
    "13" = m[["13"]],
    "14" = m[["14"]],
    "15" = m[["15"]],
    "16" = m[["16"]],
    "17" = sprintf(m[["17"]], .n_tage(v[1])),
    "18" = sprintf(m[["18"]], .n_tage(v[1])),
    "19" = sprintf(m[["19"]], .SIM_EVAL_METRICS[v[1] + 1], why_text[v[1] + 1]))
}

#' Warnungen der Auswertung (Codes des Kerns) mit den Texten von R 1.3.0 (.MELD_EVAL_WARN, R/meldungen.R);
#' call: Aufruf der Bedingung (aus .sim_evaluate dessen Aufruf, den .sim_restore_call durch den von simulation()
#' ersetzt; sonst ohne Aufruf)
#' @keywords internal
#' @noRd
.sim_eval_warn <- function(code, v, call = NULL) {
  m <- .MELD_EVAL_WARN
  dstr <- function(z) format(structure(z, class = "Date"))
  w <- switch(as.character(code),
    "1" = simpleWarning(m[["1"]], call),
    "2" = simpleWarning(m[["2"]], call),
    "3" = simpleWarning(m[["3"]], call),
    "10" = simpleWarning(sprintf(m[["10"]], v[1], v[2], v[3])),
    "11" = simpleWarning(sprintf(m[["11"]], v[1], if (v[2] > 0) sprintf(m[["11.offen"]], v[2]) else m[["11.ungedeckt"]])),
    "12" = simpleWarning(m[["12"]]),
    "13" = simpleWarning(sprintf(m[["13"]], .n_tage(v[1]))),
    "14" = simpleWarning(sprintf(m[["14"]], v[1])),
    "15" = simpleWarning(sprintf(m[["15"]], dstr(v[1]), v[2], v[3], v[4])),
    "16" = simpleWarning(sprintf(m[["16"]], dstr(v[1]), v[2])),
    "17" = simpleWarning(m[["17"]], call),
    stop(sprintf(m[["unbekannt"]], code)))
  warning(w)
}

#' Phase 6 von simulation(): Auswertung im Kern
#'
#' Zweck: Wertreihen, Renditen, Drawdowns, Kennzahlen und Ursachen nicht definierter Kennzahlen ueber
#' core/evaluate_core_impl.h; Meldungen in der Reihenfolge von R 1.3.0 (Warnungen von .sim_returns, dann die von
#' risk_free, dann ein Abbruch in .sim_risk_stats).
#' Eingabe: sim_mem (nach dem Lauf), fl (Flags), cfg (risk_free, start_value), data (Spalte fuer risk_free),
#' prep (start_date, stopp_date), tax_unpaid (nicht gedeckte Steuerzahlungen in EUR).
#' Ausgabe: Liste total_worth, twr_index, invested, has_ext_flows, cagr, ttwror, open_tax_debt, drawdowns,
#' statistics, buys, sells, undefined_metrics.
#' @keywords internal
#' @noRd
.sim_evaluate <- function(sim_mem, fl, cfg, data, prep, tax_unpaid) {
  nm <- fl$flag_assets
  n <- length(fl$flag_date)
  rp <- sim_mem[["report"]]
  rf <- .sim_capture(.sim_risk_free(cfg$risk_free, data, n))
  rfv <- if (rf$failed) NULL else rf$value
  inp <- list(
    n = n, total = lapply(nm, function(a) rp[[a]][["total"]]), flows = lapply(nm, function(a) rp[[a]][["flows"]]),
    worth = lapply(nm, function(a) rp[[a]][["worth"]]), money = lapply(nm, function(a) rp[[a]][["money"]]),
    price = lapply(nm, function(a) as.numeric(sim_mem[["market"]][[a]][["asset_price"]])),
    day = as.numeric(fl$flag_date), filled = if (any(fl$flag_filled)) as.integer(fl$flag_filled),
    sc = c(as.numeric(prep$start_date), as.numeric(prep$stopp_date), as.numeric(cfg$start_value), as.numeric(tax_unpaid)),
    status_money = vapply(nm, function(a) as.numeric(sim_mem[["status"]][[a]][["money"]]), 0, USE.NAMES = FALSE),
    n_buys = vapply(nm, function(a) as.numeric(length(sim_mem[["trades"]][[a]][["buys"]])), 0, USE.NAMES = FALSE),
    n_sells = vapply(nm, function(a) as.numeric(length(sim_mem[["trades"]][[a]][["sells"]])), 0, USE.NAMES = FALSE),
    rf = if (is.double(rfv)) rfv else if (!is.null(rfv)) as.double(rfv), rf_ok = as.integer(!rf$failed))
  ev <- .Call(C_sim_evaluate, inp)
  # Meldungen: Warnungen von .sim_returns, Abbruch dort, Meldungen von risk_free, Abbruch in .sim_risk_stats
  cl <- sys.call()   # Aufruf der Phase; .sim_restore_call setzt den Aufruf von simulation()
  for (i in seq_along(ev$msg_code)) .sim_eval_warn(ev$msg_code[i], ev$msg_v[4L * (i - 1L) + 1:4], cl)
  na_stop <- function() stop(simpleError("missing value where TRUE/FALSE needed", cl))
  if (ev$err[2] == 1L) na_stop()
  for (cond in rf$conds) if (inherits(cond, "error")) stop(cond) else warning(cond)
  if (ev$err[2] == 2L) na_stop()
  # Ergebnis
  st <- as.list(ev$stats)
  names(st) <- .SIM_EVAL_STATS
  if (ev$ints[1]) st$skewness <- NA      # calculate_skewness/_kurtosis: logisches NA
  if (ev$ints[2]) st$kurtosis <- NA
  st$longest_drawdown <- ev$ints[3]
  why_text <- vapply(1:2, function(k) {
    j <- 3L * (k - 1L)
    if (ev$why_i[j + 1L]) .sim_eval_detail(ev$why_i[j + 3L], ev$why_v[j + 1:3], NULL) else NA_character_
  }, "")
  k <- length(ev$um_i) %/% 3L
  ui <- matrix(ev$um_i, nrow = 3L); uv <- matrix(ev$um_v, nrow = 3L)
  um <- data.frame(metric = .SIM_EVAL_METRICS[ui[1L, ] + 1L], reason = .SIM_EVAL_REASONS[ui[2L, ] + 1L],
                   detail = vapply(seq_len(k), function(i) .sim_eval_detail(ui[3L, i], uv[, i], why_text), ""),
                   stringsAsFactors = FALSE, row.names = NULL)
  list(total_worth = ev$total_worth, twr_index = ev$twr_index, invested = ev$invested, has_ext_flows = ev$has_ext,
       cagr = ev$scal[1], ttwror = ev$scal[2], open_tax_debt = ev$scal[3], drawdowns = ev$drawdowns,
       statistics = st, buys = stats::setNames(ev$buys, nm), sells = stats::setNames(ev$sells, nm),
       undefined_metrics = um)
}

#' Phase 6e von simulation(): Ergebnisobjekt
#'
#' Zweck: offene Lots am letzten Tag, Steuerreport (mit Tarifjahren und Steuerzustand des Folgejahres)
#' und das Ergebnisobjekt der Klasse SimLevResult zusammenstellen.
#' Eingabe: sim_mem, fl, cfg, ev (aus .sim_evaluate).
#' Ausgabe: Objekt der Klasse SimLevResult (siehe simulation()).
#' @keywords internal
#' @noRd
.sim_result <- function(sim_mem, fl, cfg, ev) {
  flag_date <- fl$flag_date; flag_filled <- fl$flag_filled; flag_assets <- fl$flag_assets
  flag_harvest <- fl$flag_harvest; tax_regimes <- fl$tax_regimes
  tax_mode <- cfg$tax_mode; strategy <- cfg$strategy; order_fee <- cfg$order_fee
  effective_tax_rate <- cfg$effective_tax_rate; use_sparer_pauschbetrag <- cfg$use_sparer_pauschbetrag
  tariff_env <- cfg$tariff_env; fees_on <- cfg$fees_on; harvest_mode <- cfg$harvest_mode
  total_worth <- ev$total_worth; twr_index <- ev$twr_index; invested <- ev$invested
  has_ext_flows <- ev$has_ext_flows; cagr <- ev$cagr; ttwror <- ev$ttwror; drawdowns <- ev$drawdowns
  open_tax_debt <- ev$open_tax_debt; statistics <- ev$statistics
  buys <- ev$buys; sells <- ev$sells; undefined_metrics <- ev$undefined_metrics

  #--------> E: offene Lots am letzten Tag (Grundlage fuer Steuerrechnungen nach dem Ende; nur tax_mode = "person")
  open_lots <- if (tax_mode == "person") stats::setNames(lapply(flag_assets, function(nm) {
    lots <- Filter(function(b) length(b) && b[["remaining"]] > 0, sim_mem[["trades"]][[nm]][["buys"]])
    list(lots = data.frame(date = as.Date(vapply(lots, function(b) as.numeric(b[["date"]]), numeric(1)), origin = "1970-01-01"),
                           units = vapply(lots, function(b) b[["remaining"]], numeric(1)),
                           price = vapply(lots, function(b) b[["price"]], numeric(1)),
                           vp = vapply(lots, function(b) b[["vp"]] %||% 0, numeric(1))),
         regime = tax_regimes[[nm]],
         partial_exemption = 100 * sim_mem[["assets"]][[nm]][["bonus"]],
         cash = sim_mem[["status"]][[nm]][["money"]],
         spread = strategy[[nm]][["spread"]] %||% 0,   # voller Spread in Prozent (wie asset_config)
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
  if (length(cfg$wrappers)) results$wrappers <- cfg$wrappers   # nur mit details = TRUE und Wrapper-Assets
  class(results) <- "SimLevResult"
  results
}
