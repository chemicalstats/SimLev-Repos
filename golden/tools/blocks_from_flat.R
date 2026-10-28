# Flache simulation()-Argumente (bis 6.2) nach Anhang C in Bausteine übersetzen (Etappe 6.3).
#
# R-Gegenstück zu golden/tools/blocks_from_flat.py (gleiche Regeln, siehe dort) für die Generatoren
# golden/golden_cases.R, golden/stress_cases.R und golden/modules/gen_engine.R: Die Fälle sind dort als
# flache Argumentlisten beschrieben; simulation() wird mit den übersetzten Bausteinen aufgerufen.
#
#   blocks_from_flat(a)   a: benannte Liste flacher Argumente -> benannte Liste, Bausteine als
#                         Objekte der Klasse "flatblock" (list(ctor, args))
#   flatblock_build(b)    Baustein wirklich anlegen (Konstruktor aus SimLev aufrufen)
#   flatblock_json(b)     Form für die Fälle: list(block = <Konstruktor>, args = <Argumente>)

.FB_FLAT <- c("spread", "dca_mode", "dca_value", "dca_span", "dca_days", "dca_unit", "dca_anchor", "dca_start", "dca_skip",
              "balance_mode", "balance_span", "balance_days", "balance_unit", "balance_anchor", "balance_start",
              "balance_skip", "balance_dca", "balance_thresh", "balance_thresh_type", "tax_mode", "tax_rate",
              "marginal_tax_rate", "use_guenstigerpruefung", "private_sale_threshold", "sparer_pauschbetrag",
              "use_sparer_pauschbetrag", "include_soli_on_income_tax", "soli_rate_income_tax", "base_rate",
              "base_rate_flex", "base_rate_data", "funds_fee", "bonus_fee", "split_mode", "split_thresh", "event_col",
              "event_mode", "event_weight", "church_tax", "order_fee", "dca_fee", "harvest_mode", "harvest_day",
              "harvest_loss_pot", "taxable_income", "tax_tariff")
.FB_KEEP <- c("data", "strategy", "start_value", "risk_free", "fractions", "liquidate", "details")

flatblock <- function(ctor, args = list()) structure(list(ctor = ctor, args = args), class = "flatblock")

blocks_from_flat <- function(a) {
  unk <- setdiff(names(a), c(.FB_FLAT, .FB_KEEP))
  if (length(unk)) stop("blocks_from_flat: unbekannte Argumente: ", paste(unk, collapse = ", "))
  has <- function(k) k %in% names(a)
  truth <- function(k) has(k) && isTRUE(a[[k]])
  pick <- function(map) { out <- list(); for (k in names(map)) if (has(k)) out[map[[k]]] <- list(a[[k]]); out }
  keep <- a[intersect(names(a), .FB_KEEP)]
  b <- list()
  if (has("order_fee") || has("dca_fee")) b$costs <- flatblock("sim_costs", pick(c(order_fee = "order_fee", dca_fee = "dca_fee")))
  if (truth("dca_mode"))
    b$dca <- flatblock("dca_plan", pick(c(dca_value = "value", dca_span = "span", dca_days = "days", dca_unit = "unit",
                                          dca_anchor = "anchor", dca_start = "start", dca_skip = "skip",
                                          balance_dca = "fill_deficits")))
  bm <- truth("balance_mode"); ev <- has("event_col") && !is.null(a$event_col)
  if (bm || ev) {
    em <- if (has("event_mode")) a$event_mode[1] else "additional"
    cal <- c(balance_span = "span", balance_days = "days", balance_unit = "unit", balance_anchor = "anchor",
             balance_start = "start", balance_skip = "skip")
    rest <- c(balance_thresh = "thresh", balance_thresh_type = "thresh_type")
    if (!bm) {
      args <- c(pick(rest), list(event_col = a$event_col, event_mode = "replace", skip = TRUE))
      if (has("event_weight")) args["event_weight"] <- list(a$event_weight)
    } else {
      if (ev && em == "replace") cal <- cal[names(cal) != "balance_skip"]
      args <- c(pick(cal), pick(rest))
      if (ev) {
        args["event_col"] <- list(a$event_col)
        if (has("event_mode")) args["event_mode"] <- list(a$event_mode)
        if (has("event_weight")) args["event_weight"] <- list(a$event_weight)
      }
    }
    b$rebalance <- flatblock("rebalance_plan", args)
  }
  if (truth("split_mode")) b$splits <- flatblock("split_rule", pick(c(split_thresh = "thresh")))
  tm <- if (has("tax_mode")) a$tax_mode[1] else "none"
  if (identical(tm, "person")) {
    args <- pick(c(tax_rate = "rate", church_tax = "church_tax"))
    if (has("use_sparer_pauschbetrag") && !isTRUE(a$use_sparer_pauschbetrag)) args$sparer_pauschbetrag <- 0
    else if (has("sparer_pauschbetrag")) args["sparer_pauschbetrag"] <- list(a$sparer_pauschbetrag)
    if (has("private_sale_threshold")) args["private_sale_threshold"] <- list(a$private_sale_threshold)
    if (truth("base_rate_flex")) {
      if (!has("base_rate_data")) stop("blocks_from_flat: base_rate_flex = TRUE ohne base_rate_data")
      args["base_rate"] <- list(a$base_rate_data)
    } else if (has("base_rate")) args["base_rate"] <- list(a$base_rate)
    if (has("use_guenstigerpruefung")) args["guenstigerpruefung"] <- list(a$use_guenstigerpruefung)
    if (has("taxable_income") && !is.null(a$taxable_income)) {
      ia <- list(taxable_income = a$taxable_income)
      if (has("tax_tariff") && !is.null(a$tax_tariff)) ia["tariff"] <- list(a$tax_tariff)
      args$income <- flatblock("income_tariff", ia)
    } else if (has("marginal_tax_rate") && !is.null(a$marginal_tax_rate)) {
      ia <- list(marginal_rate = a$marginal_tax_rate)
      if (truth("include_soli_on_income_tax")) ia["soli_rate"] <- list(if (has("soli_rate_income_tax")) a$soli_rate_income_tax else 5.5)
      args$income <- flatblock("income_rate", ia)
    }
    if (truth("harvest_mode")) args$harvest <- flatblock("harvest_rule", pick(c(harvest_day = "day", harvest_loss_pot = "loss_pot")))
    b$tax <- flatblock("tax_profile", args)
  } else if (!identical(tm, "none")) stop("blocks_from_flat: tax_mode = ", deparse(tm), " (den Fondsmodus gibt es seit Etappe 6.5c nicht mehr)")
  out <- list()
  for (k in names(a)) if (k %in% names(keep)) out[k] <- list(a[[k]])
  for (k in c("costs", "dca", "rebalance", "splits", "tax")) if (!is.null(b[[k]])) out[[k]] <- b[[k]]
  out
}

flatblock_build <- function(b) {
  if (!inherits(b, "flatblock")) return(b)
  do.call(get(b$ctor, envir = asNamespace("SimLev")), lapply(b$args, flatblock_build))
}

flatblock_json <- function(b) {
  if (inherits(b, "Date")) return(format(b))
  if (!inherits(b, "flatblock")) return(b)
  list(block = b$ctor, args = if (length(b$args)) lapply(b$args, flatblock_json) else structure(list(), names = character(0)))
}
