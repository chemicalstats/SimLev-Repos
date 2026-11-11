# =============================================================================
# Studienkern: vorbereiteter Kernlauf je Pfad bzw. Punkt (seit 1.6.5, Paket E, Entscheidung 176; FB-12)
# =============================================================================
#
# Studien (bootstrap_study, param_search, sensitivity_*, planning_lumpsum_vs_dca) rufen simulation() ueber .sim_call
# vielfach mit derselben Strategie und denselben Argumenten auf; je Pfad bzw. Punkt aendern sich oft nur Kurse (Pfade
# des Bootstraps, Hebelreihen) oder Signale (Signalparameter einer Suche). Innerhalb einer Studie (.sim_study)
# merkt sich .sim_call_study ab dem zweiten Aufruf mit derselben Strategie und Argumentliste einen vollstaendigen
# Lauf von simulation() als Vorlage:
# die Eingabe der Tagesengine, den Zustand vor der Engine, Kalender, Bausteine und die Teile der Auswertung, die nicht
# vom Lauf abhaengen (.sim_prep_capture). Spaeter tauscht .sim_prep_run nur die Kurs- und Signalspalten (aufgefuellt
# wie in .sim_prepare_data) und rechnet Engine und Auswertung in einem Kernaufruf (C_sim_run_prepared,
# core/evaluate_core_impl.h simlev_run::run_prepared); Meldungen der Engine und der Auswertung, Ergebnisobjekt und
# Fehler entstehen mit denselben Funktionen wie in simulation().
#
# Bitgleich zu simulation(): dieselben Kernaufrufe in derselben Reihenfolge. Die Vorlage gilt nur, wenn ihre Phasen 1
# und 2 (Pruefung, Daten, Zustand, Kalender) ohne Meldung und Warnung blieben, ohne details, ohne Fonds-Wrapper, mit
# einer schlichten Tabelle (data.frame ohne Attribut filled) und ohne LOCF ueber merge(). Ein Lauf nutzt sie nur, wenn
# Tabelle, Spaltennamen, Datumsspalte und alle uebrigen gelesenen Spalten (risk_free, Basiszins, Ereignis- und
# Gewichtsspalten) gleich sind und die neuen Kurse und Signale die Pruefungen von simulation() still bestehen
# (Kurse: Zahlen ohne NA in [1e-100, 1e100]; Signale: logisch oder 0/1); sonst rechnet simulation() vollstaendig (mit
# allen Meldungen). Gegenstuecke: python/simlev/_sim_prepared.py, julia/src/sim_prepared.jl.

.SIM_PREP_MAX <- 16L   # gemerkte Vorlagen je Studie (Strategien einer bootstrap_study; aelteste faellt heraus)

# Merker "naechster Lauf von simulation() wird Vorlage" lesen und loeschen (von .simulation_flat am Anfang gerufen)
.sim_prep_cap_take <- function() {
  if (!isTRUE(.sim_study_env$cap)) return(FALSE)
  .sim_study_env$cap <- NULL
  TRUE
}

#' simulation() in einer Studie: Vorlage nutzen, sonst vollstaendig rechnen (ab dem zweiten Aufruf mit derselben
#' Strategie und Argumentliste als Vorlage merken; aendern sich Spalten, Datum oder die uebrigen gelesenen Spalten bei
#' gleicher Strategie, z. B. Zeitfenster, merkt sich die Studie fuer sie keine Vorlage mehr)
#' @keywords internal
#' @noRd
.sim_call_study <- function(data, strategy, args) {
  E <- .sim_study_env
  same <- function(e) identical(e$strategy, strategy) && identical(e$args, args)
  push <- function(l, e) { l[[length(l) + 1L]] <- e; if (length(l) > .SIM_PREP_MAX) l[-1L] else l }
  for (i in seq_along(E$prep)) {
    P <- E$prep[[i]]
    if (!same(P)) next
    res <- .sim_prep_run(P, data)
    if (is.list(res)) return(res)
    if (identical(res, "anders")) {
      E$prep <- E$prep[-i]
      E$never <- push(E$never, list(strategy = strategy, args = args))
    }
    return(do.call(simulation, c(list(data = data, strategy = strategy), args)))
  }
  if (any(vapply(E$never, same, NA))) return(do.call(simulation, c(list(data = data, strategy = strategy), args)))
  j <- which(vapply(E$seen, same, NA))
  if (!length(j)) {
    E$seen <- push(E$seen, list(strategy = strategy, args = args))
    return(do.call(simulation, c(list(data = data, strategy = strategy), args)))
  }
  E$seen <- E$seen[-j[1L]]
  E$cap <- TRUE; E$cap_out <- NULL
  on.exit({ E$cap <- NULL; E$cap_out <- NULL })
  res <- do.call(simulation, c(list(data = data, strategy = strategy), args))
  P <- E$cap_out
  if (!is.null(P) && isTRUE(E$on)) {
    P$strategy <- strategy; P$args <- args
    E$prep <- push(E$prep, P)
  }
  res
}

#' Vorlage aus einem Lauf von simulation() (vor der Tagesengine); setzt .sim_study_env$cap_out oder nichts; Rueckgabe
#' .sim_eval_static() fuer die Auswertung dieses Laufs bzw. NULL
#' @keywords internal
#' @noRd
.sim_prep_capture <- function(sim_call, cfg, prep, sim_mem, fl, data, ei, details, base_rate_flex, base_rate_data,
                              event_weight) {
  d0 <- cfg$data
  if (isTRUE(details) || length(cfg$no_split) || !identical(class(d0), "data.frame") || !is.null(attr(d0, "filled")) ||
      identical(prep$fill, "merge"))
    return(invisible(NULL))
  nm <- fl$flag_assets
  st <- cfg$strategy
  col1 <- function(x) if (is.character(x) && length(x) == 1L && !is.na(x)) x else NA_character_
  sb <- vapply(nm, function(a) if (is.null(st[[a]][["signal_buy"]])) NA_character_ else col1(st[[a]][["signal_buy"]]), "",
               USE.NAMES = FALSE)
  ss <- vapply(nm, function(a) if (is.null(st[[a]][["signal_sell"]])) NA_character_ else col1(st[[a]][["signal_sell"]]), "",
               USE.NAMES = FALSE)
  for (a in nm) for (f in c("signal_buy", "signal_sell"))
    if (!is.null(st[[a]][[f]]) && is.na(col1(st[[a]][[f]]))) return(invisible(NULL))
  sig <- unique(c(sb[!is.na(sb)], ss[!is.na(ss)]))
  if (!all(sig %in% names(d0))) return(invisible(NULL))
  swap <- unique(c(nm, sig))
  ew <- if (!is.null(cfg$event_col) && !is.null(event_weight)) unlist(event_weight, use.names = FALSE)
  fixed <- intersect(c(if (is.character(cfg$risk_free)) cfg$risk_free,
                       if (isTRUE(base_rate_flex) && is.character(base_rate_data)) base_rate_data,
                       cfg$event_col, if (is.character(ew)) ew), names(d0))
  if (length(intersect(fixed, swap))) return(invisible(NULL))
  for (a in nm) if (!is.double(d0[[a]]) || !is.null(attributes(d0[[a]]))) return(invisible(NULL))
  for (cc in sig) if (!is.null(attributes(d0[[cc]]))) return(invisible(NULL))
  es <- .sim_eval_static(fl, cfg, data, prep)
  if (length(es$rf$conds)) return(es)
  .sim_study_env$cap_out <- list(
    call = sim_call, names = names(d0), date = d0$date, fixed = fixed,
    fixed_val = lapply(fixed, function(cc) d0[[cc]]), price = nm, sig = sig, swap = swap, sb = sb, ss = ss,
    fill = if (identical(prep$fill, "kern"))
      list(dd = as.double(unclass(d0$date)), d0 = as.double(unclass(fl$flag_date)[1L]), m = as.double(length(fl$flag_date))),
    inp = ei$inp, ei = ei[c("nm", "person", "tax_regimes")],
    env0 = if (!is.null(ei$env)) as.list(ei$env, all.names = TRUE),
    sim_mem = sim_mem, fl = fl, cfg = cfg, prep = prep, rf = es$rf, evs = es$s)
  es
}

#' Lauf mit einer Vorlage: nur Kurse und Signale aus data; sonst NULL (Kurse oder Signale bestehen die Pruefungen nicht
#' still) bzw. "anders" (Tabelle, Spalten, Datum oder uebrige gelesene Spalten anders); dann rechnet simulation()
#' @keywords internal
#' @noRd
.sim_prep_run <- function(P, data) {
  if (!identical(class(data), "data.frame") || !is.null(attr(data, "filled")) || !identical(names(data), P$names) ||
      !identical(data$date, P$date))
    return("anders")
  for (k in seq_along(P$fixed)) if (!identical(data[[P$fixed[k]]], P$fixed_val[[k]])) return("anders")
  # Kurse und Signale, die die Pruefungen von simulation() still bestehen (.sim_check_inputs, chk_col_signal)
  for (a in P$price) {
    v <- data[[a]]
    if (!is.double(v) || !is.null(attributes(v)) || anyNA(v)) return(NULL)
    lo <- min(v); hi <- max(v)
    if (!(is.finite(lo) && is.finite(hi) && lo >= 1e-100 && hi <= 1e100)) return(NULL)
  }
  for (cc in P$sig) {
    v <- data[[cc]]
    if (!is.null(attributes(v)) || !(is.logical(v) || (is.numeric(v) && all(is.na(v) | v == 0 | v == 1))))
      return(NULL)
  }
  sw <- lapply(P$swap, function(cc) data[[cc]])
  if (!is.null(P$fill)) {   # wie .sim_prepare_data: Kalenderauffuellung im Kern, nur wenn simulation() sie ebenso waehlte
    ok <- vapply(data[names(data) != "date"], function(v)
      is.null(attributes(v)) && typeof(v) %in% c("double", "integer", "logical", "character"), NA)
    if (!all(ok)) return(NULL)
    sw <- .Call(C_sl_cal_fill, sw, P$fill$dd, P$fill$d0, P$fill$m, 0L)
  }
  names(sw) <- P$swap
  inp <- P$inp
  inp$price <- lapply(P$price, function(a) sw[[a]])
  for (k in seq_along(P$price)) {
    if (!is.na(P$sb[k])) inp$sig_buy[k] <- list(sw[[P$sb[k]]])
    if (!is.na(P$ss[k])) inp$sig_sell[k] <- list(sw[[P$ss[k]]])
  }
  sim_call <- P$call
  withCallingHandlers({
    cfg <- P$cfg
    env <- if (!is.null(P$env0)) list2env(P$env0, envir = new.env(parent = emptyenv()))
    if (!is.null(env)) cfg$tariff_env <- env
    .fee_env$paid <- 0   # wie .sim_check_inputs vor der Engine
    r <- .Call(C_sim_run_prepared, inp, P$evs)
    eng <- .sim_engine_finish(r$engine, P$sim_mem, P$ei, env, P$fl)
    fl <- P$fl
    fl$flag_harvest <- eng$flag_harvest
    fl$tax_regimes <- eng$tax_regimes
    ev <- .sim_evaluate(eng$sim_mem, fl, cfg, NULL, P$prep, eng$tax_unpaid, core = r$eval, rf = P$rf)
    .sim_result(eng$sim_mem, fl, cfg, ev)
  },
  warning = function(w) .sim_restore_call(w, sim_call),
  error = function(e) .sim_restore_call(e, sim_call))
}
