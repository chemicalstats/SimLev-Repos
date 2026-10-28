# =============================================================================
# Bausteine fuer simulation() (Etappe 6.3, Anhang C)
# =============================================================================
#
# Jeder Baustein ist ein Konstruktor mit Pruefung der Argumente (deutsche Meldungen), einer Klasse und
# einer kurzen print-Methode. simulation() nimmt die Bausteine an und uebersetzt sie am Anfang mit
# .sim_from_blocks() in die internen Werte der Engine (dca_mode, balance_*, tax_mode ...); die Rechnung
# selbst ist unveraendert.
#
#   sim_costs(order_fee, dca_fee)                                   -> costs
#   dca_plan(value, span, days, unit, anchor, start, skip, fill_deficits)          -> dca
#   rebalance_plan(span, days, unit, anchor, start, skip, thresh, thresh_type,
#                  event_col, event_mode, event_weight)              -> rebalance
#   split_rule(thresh)                                              -> splits
#   tax_profile(rate, church_tax, sparer_pauschbetrag, private_sale_threshold, base_rate,
#               guenstigerpruefung, income, harvest)                -> tax
#     income_rate(marginal_rate, soli_rate), income_tariff(taxable_income, tariff), harvest_rule(day, loss_pot)
#   funds_costs(fee, performance_fee)                               -> funds
#
# NULL heisst aus (kein Sparplan, kein Rebalancing, keine Splits, keine Steuern, kein Fondsmodus).

# ── Pruefhilfen ───────────────────────────────────────────────────────────────

.blk_show <- function(x) if (is.null(x)) "NULL" else paste(deparse(x), collapse = "")

.blk_num <- function(who, x, arg, what, min = 0, null_ok = FALSE) {
  if (is.null(x) && null_ok) return(invisible(NULL))
  if (!is.numeric(x) || length(x) != 1L || !is.finite(x) || (!is.null(min) && x < min))
    stop(sprintf("%s: '%s' muss %s sein, nicht %s.", who, arg, what, .blk_show(x)), call. = FALSE)
  invisible(NULL)
}

.blk_lgl <- function(who, x, arg) {
  if (!is.logical(x) || length(x) != 1L || is.na(x))
    stop(sprintf("%s: '%s' muss TRUE oder FALSE sein, nicht %s.", who, arg, .blk_show(x)), call. = FALSE)
  invisible(NULL)
}

# Anteil statt Prozent (R1-23, R8-04): Warnung wie in simulation()
.blk_frac_warn <- function(who, x, arg, hi = 1) {
  if (is.numeric(x) && length(x) == 1L && is.finite(x) && x > 0 && x < hi)
    warning(sprintf("%s: %s = %s wird als %s %% gelesen (Prozent-Konvention); gemeint war vermutlich %s.",
                    who, arg, format(x), format(x), format(x * 100)), call. = FALSE)
  invisible(NULL)
}

# Tage 1-31; doppelte Tage ergeben nur einen Termin (Warnung, Rueckgabe ohne Doppelte)
.blk_days <- function(who, x) {
  if (is.null(x)) return(NULL)
  if (!is.numeric(x) || anyNA(x) || any(x < 1 | x > 31 | x != round(x)))
    stop(sprintf("%s: days muss ganze Zahlen von 1 bis 31 enthalten, nicht %s.", who, paste(format(x), collapse = ", ")),
         call. = FALSE)
  if (anyDuplicated(x)) {
    warning(sprintf("%s: days enth\u00e4lt doppelte Tage (%s); jeder Tag ergibt nur einen Termin, verwendet wird days = %s.",
                    who, paste(format(x), collapse = ", "), paste(deparse(unique(x)), collapse = "")), call. = FALSE)
    x <- unique(x)
  }
  x
}

# Bezugsdatum: Date oder "JJJJ-MM-TT" (R1-22)
.blk_start <- function(who, x) {
  if (is.null(x)) return(invisible(NULL))
  d <- tryCatch(as.Date(x), error = function(e) NA)
  if (length(d) != 1L || is.na(d))
    stop(sprintf("%s: start = '%s' ist kein Datum (erwartet Date oder \"JJJJ-MM-TT\").", who, format(x)), call. = FALSE)
  invisible(NULL)
}

.blk_check <- function(x, cls, arg, ctor) {
  if (!is.null(x) && !inherits(x, cls))
    stop(sprintf("simulation: %s muss NULL oder ein Objekt aus %s() sein, nicht %s.", arg, ctor,
                 paste(class(x), collapse = "/")), call. = FALSE)
  invisible(NULL)
}

# ── Druckhilfen ───────────────────────────────────────────────────────────────

.blk_print <- function(title, rows) {
  cat(title, "\n", sep = "")
  w <- max(nchar(names(rows))) + 1L
  for (k in names(rows)) cat("  ", format(paste0(k, ":"), width = w), " ", rows[[k]], "\n", sep = "")
}

.blk_fmt <- function(x) format(x, digits = 15)

.blk_fee_text <- function(x) {
  if (is.null(x)) return("keine")
  if (is.numeric(x)) return(sprintf("%s EUR je Order", .blk_fmt(x)))
  p <- character(0)
  if (!is.null(x$fixed)) p <- c(p, sprintf("%s EUR", .blk_fmt(x$fixed)))
  if (!is.null(x$percent)) p <- c(p, sprintf("%s %%", .blk_fmt(x$percent)))
  s <- if (length(p)) paste(p, collapse = " + ") else "0 EUR"
  g <- character(0)
  if (!is.null(x$min)) g <- c(g, sprintf("mindestens %s EUR", .blk_fmt(x$min)))
  if (!is.null(x$max)) g <- c(g, sprintf("h\u00f6chstens %s EUR", .blk_fmt(x$max)))
  if (length(g)) s <- sprintf("%s (%s)", s, paste(g, collapse = ", "))
  s
}

.blk_sched_text <- function(span, unit, days, anchor) {
  span <- span %||% 1
  per <- switch(unit, month = c("jeden Monat", "Monate"), quarter = c("jedes Quartal", "Quartale"),
                year = c("jedes Jahr", "Jahre"))
  s <- if (span == 1) per[1] else sprintf("alle %s %s", .blk_fmt(span), per[2])
  d <- if (is.null(days)) "am ersten Tag der Periode"
       else sprintf("%s %s %s", if (length(days) == 1L) "an Tag" else "an den Tagen",
                    paste(vapply(days, .blk_fmt, ""), collapse = ", "),
                    if (anchor == "end") "vom Periodenende gez\u00e4hlt" else "der Periode")
  paste(s, d, sep = ", ")
}

.blk_start_text <- function(x) if (is.null(x)) "erster Datentag" else format(as.Date(x))

# ── sim_costs ─────────────────────────────────────────────────────────────────

#' Kosten fuer simulation()
#' @export
#' @noRd
sim_costs <- function(order_fee = NULL, dca_fee = NULL) {
  .fee_spec(order_fee); .fee_spec(dca_fee)
  structure(list(order_fee = order_fee, dca_fee = dca_fee), class = "SimLevSimCosts")
}

#' @export
#' @noRd
print.SimLevSimCosts <- function(x, ...) {
  .blk_print("Kosten (sim_costs)",
             list("Ordergeb\u00fchr" = .blk_fee_text(x$order_fee),
                  "Sparplan-Geb\u00fchr" = if (is.null(x$dca_fee)) "wie Ordergeb\u00fchr" else .blk_fee_text(x$dca_fee)))
  invisible(x)
}

# ── dca_plan ──────────────────────────────────────────────────────────────────

#' Sparplan fuer simulation()
#' @export
#' @noRd
dca_plan <- function(value, span, days = NULL, unit = c("month", "quarter", "year"), anchor = c("start", "end"),
                     start = NULL, skip = FALSE, fill_deficits = FALSE) {
  who <- "dca_plan"
  if (missing(value)) value <- NULL
  if (missing(span)) span <- NULL
  .one <- function(x) is.numeric(x) && length(x) == 1L && is.finite(x)
  if (!.one(value) || value <= 0)
    stop(sprintf("%s: 'value' muss eine einzelne endliche Zahl > 0 sein (Betrag je Sparplan-Termin in EUR), nicht %s.",
                 who, .blk_show(value)), call. = FALSE)
  if (!.one(span) || span < 1 || span != round(span))
    stop(sprintf("%s: 'span' muss eine einzelne ganze Zahl >= 1 sein (Perioden zwischen zwei Terminen), nicht %s.",
                 who, .blk_show(span)), call. = FALSE)
  days <- .blk_days(who, days)
  unit <- match.arg(unit); anchor <- match.arg(anchor)
  .blk_start(who, start)
  .blk_lgl(who, skip, "skip"); .blk_lgl(who, fill_deficits, "fill_deficits")
  structure(list(value = value, span = span, days = days, unit = unit, anchor = anchor, start = start, skip = skip,
                 fill_deficits = fill_deficits), class = "SimLevDcaPlan")
}

#' @export
#' @noRd
print.SimLevDcaPlan <- function(x, ...) {
  .blk_print("Sparplan (dca_plan)",
             list("Betrag" = sprintf("%s EUR je Termin", .blk_fmt(x$value)),
                  "Termine" = .blk_sched_text(x$span, x$unit, x$days, x$anchor),
                  "Bezugsdatum" = .blk_start_text(x$start),
                  "Erster Simulationstag" = if (isTRUE(x$skip)) "ausgelassen" else "mit Termin",
                  "Verteilung" = if (isTRUE(x$fill_deficits)) "zuerst Wert-Defizite auff\u00fcllen, Rest nach Strategie-Gewichten"
                                 else "nach Strategie-Gewichten"))
  invisible(x)
}

# ── rebalance_plan ────────────────────────────────────────────────────────────

#' Rebalancing fuer simulation()
#' @export
#' @noRd
rebalance_plan <- function(span = NULL, days = NULL, unit = c("month", "quarter", "year"), anchor = c("start", "end"),
                           start = NULL, skip = FALSE, thresh = NULL, thresh_type = c("absolute", "relative"),
                           event_col = NULL, event_mode = c("additional", "replace"), event_weight = NULL) {
  who <- "rebalance_plan"
  days <- .blk_days(who, days)
  unit <- match.arg(unit); anchor <- match.arg(anchor)
  .blk_start(who, start)
  .blk_lgl(who, skip, "skip")
  .blk_num(who, thresh, "thresh", "NULL oder eine einzelne endliche Zahl >= 0 in Prozent (z. B. 5)", null_ok = TRUE)
  .blk_frac_warn(who, thresh, "thresh", hi = 0.2)
  thresh_type <- match.arg(thresh_type)
  if (is.null(event_col) && !missing(event_mode))
    warning("rebalance_plan: event_mode wirkt nur zusammen mit event_col und wird ignoriert.", call. = FALSE)
  event_mode <- match.arg(event_mode)
  if (!is.null(event_col) && (!is.character(event_col) || length(event_col) != 1L || is.na(event_col)))
    stop(sprintf("rebalance_plan: event_col muss NULL oder der Name einer logischen Spalte in data sein, nicht %s.",
                 .blk_show(event_col)), call. = FALSE)
  if (is.null(event_col) && !is.null(event_weight))
    warning("rebalance_plan: event_weight wirkt nur zusammen mit event_col und wird ignoriert.", call. = FALSE)
  structure(list(span = span, days = days, unit = unit, anchor = anchor, start = start, skip = skip, thresh = thresh,
                 thresh_type = thresh_type, event_col = event_col, event_mode = event_mode, event_weight = event_weight),
            class = "SimLevRebalancePlan")
}

#' @export
#' @noRd
print.SimLevRebalancePlan <- function(x, ...) {
  ev <- !is.null(x$event_col)
  repl <- ev && identical(x$event_mode, "replace")
  rows <- list("Termine" = if (repl) "keine (nur Ereignisse)" else .blk_sched_text(x$span, x$unit, x$days, x$anchor),
               "Ereignisse" = if (!ev) "keine"
                              else sprintf("Spalte '%s' (%s)", x$event_col,
                                           if (repl) "statt der Termine" else "zus\u00e4tzlich zu den Terminen"))
  if (ev && !is.null(x$event_weight)) {
    w <- x$event_weight
    rows[["Gewichte"]] <- paste(sprintf("%s = %s", names(w), vapply(w, as.character, "")), collapse = ", ")
  }
  rows[["Toleranzband"]] <- if (is.null(x$thresh)) "keines (an jedem Termin)"
                            else sprintf("%s %s", .blk_fmt(x$thresh),
                                         if (identical(x$thresh_type, "relative")) "% des Zielgewichts" else "Prozentpunkte")
  if (!repl) rows[["Bezugsdatum"]] <- .blk_start_text(x$start)
  rows[["Erster Simulationstag"]] <- if (isTRUE(x$skip)) "ausgelassen" else "mit Termin"
  .blk_print("Rebalancing (rebalance_plan)", rows)
  invisible(x)
}

# ── split_rule ────────────────────────────────────────────────────────────────

#' Splits fuer simulation()
#' @export
#' @noRd
split_rule <- function(thresh) {
  if (missing(thresh)) thresh <- NULL
  st <- unlist(thresh)
  if (!is.numeric(st) || length(st) != 2L || anyNA(st))
    stop(sprintf("split_rule: thresh muss ein Zahlenvektor c(untere, obere) der L\u00e4nge 2 sein, nicht %s.",
                 if (is.null(st)) "NULL" else paste(format(st), collapse = ", ")), call. = FALSE)
  if (!(st[1] < 100 && 100 < st[2]))
    warning(sprintf(paste0("split_rule: thresh = c(%s, %s) schlie\u00dft den Zielkurs 100 nicht ein (erwartet untere < 100 < obere). ",
                           "Ein Split setzt den Kurs auf 100; liegt 100 au\u00dferhalb der Schwellen, folgt danach an jedem Tag ein weiterer Split ",
                           "(mit fractions = FALSE jeweils mit Spitzenausgleich)."), format(st[1]), format(st[2])), call. = FALSE)
  structure(list(thresh = st), class = "SimLevSplitRule")
}

#' @export
#' @noRd
print.SimLevSplitRule <- function(x, ...) {
  .blk_print("Splits (split_rule)",
             list("Split" = sprintf("\u00fcber %s auf Kurs 100", .blk_fmt(x$thresh[2])),
                  "Zusammenlegung" = sprintf("unter %s auf Kurs 100", .blk_fmt(x$thresh[1]))))
  invisible(x)
}

# ── tax_profile und Teile ─────────────────────────────────────────────────────

#' Einkommen mit festem Grenzsteuersatz (fuer tax_profile(income =))
#' @export
#' @noRd
income_rate <- function(marginal_rate, soli_rate = 0) {
  who <- "income_rate"
  if (missing(marginal_rate)) marginal_rate <- NULL
  .blk_num(who, marginal_rate, "marginal_rate", "eine einzelne Zahl in Prozent von 0 bis 50 (z. B. 42)")
  .blk_frac_warn(who, marginal_rate, "marginal_rate")
  if (marginal_rate > 50)
    stop(sprintf("income_rate: marginal_rate muss ein Grenzsteuersatz in Prozent zwischen 0 und 50 sein (z. B. 42 f\u00fcr 42 %%), nicht %s.",
                 .blk_show(marginal_rate)), call. = FALSE)
  .blk_num(who, soli_rate, "soli_rate", "eine einzelne endliche Zahl >= 0 in Prozent (z. B. 5.5; 0 = ohne Soli)")
  structure(list(marginal_rate = marginal_rate, soli_rate = soli_rate), class = "SimLevIncomeRate")
}

#' Einkommen mit Einkommensteuertarif (fuer tax_profile(income =))
#' @export
#' @noRd
income_tariff <- function(taxable_income, tariff = NULL) {
  if (missing(taxable_income) || is.null(taxable_income))
    stop("income_tariff: taxable_income (zu versteuerndes Einkommen in EUR je Kalenderjahr ohne die Ertr\u00e4ge der Simulation) fehlt.",
         call. = FALSE)
  .check_taxable_income(taxable_income, integer(0), who = "income_tariff")
  if (!is.null(tariff) && !inherits(tariff, "SimLevTaxTariff")) {
    if (is.character(tariff) && length(tariff) == 1L && !is.na(tariff)) tariff <- tax_tariff(tariff)
    else stop("income_tariff: tariff muss NULL (mitgelieferte Tarifdatei), ein Dateipfad oder ein Objekt aus tax_tariff() sein.",
              call. = FALSE)
  }
  structure(list(taxable_income = taxable_income, tariff = tariff), class = "SimLevIncomeTariff")
}

#' Freibetrag jaehrlich ausschoepfen (fuer tax_profile(harvest =))
#' @export
#' @noRd
harvest_rule <- function(day = "12-15", loss_pot = TRUE) {
  if (!is.character(day) || length(day) != 1L || is.na(day) || !grepl("^\\d{2}-\\d{2}$", day) || day >= "12-31")
    stop("harvest_rule: day im Format 'MM-TT' und vor dem 31.12. angeben (z. B. '12-15').", call. = FALSE)
  .blk_lgl("harvest_rule", loss_pot, "loss_pot")
  structure(list(day = day, loss_pot = loss_pot), class = "SimLevHarvestRule")
}

.blk_income_text <- function(x) {
  if (is.null(x)) return("nicht angegeben")
  if (inherits(x, "SimLevIncomeRate"))
    return(sprintf("Grenzsteuersatz %s %%%s", .blk_fmt(x$marginal_rate),
                   if (x$soli_rate != 0) sprintf(" mit Soli %s %%", .blk_fmt(x$soli_rate)) else ""))
  ti <- x$taxable_income
  sprintf("Tarif (%s, zvE %s)", if (is.null(x$tariff)) "mitgelieferte Tarifdatei" else "eigener Tarif",
          if (is.numeric(ti) && length(ti) == 1L && is.null(names(ti))) sprintf("%s EUR je Jahr", .blk_fmt(ti))
          else "je Kalenderjahr")
}

.blk_harvest_text <- function(x) {
  if (is.null(x)) return("nein")
  sprintf("j\u00e4hrlich ab %s, Verlusttopf %s", x$day, if (isTRUE(x$loss_pot)) "mitgenutzt" else "nicht genutzt")
}

#' @export
#' @noRd
print.SimLevIncomeRate <- function(x, ...) {
  .blk_print("Einkommen (income_rate)",
             list("Grenzsteuersatz" = sprintf("%s %%", .blk_fmt(x$marginal_rate)),
                  "Soli" = if (x$soli_rate != 0) sprintf("%s %%", .blk_fmt(x$soli_rate)) else "ohne"))
  invisible(x)
}

#' @export
#' @noRd
print.SimLevIncomeTariff <- function(x, ...) {
  ti <- x$taxable_income
  .blk_print("Einkommen (income_tariff)",
             list("zvE" = if (is.numeric(ti) && length(ti) == 1L && is.null(names(ti))) sprintf("%s EUR je Jahr", .blk_fmt(ti))
                          else "je Kalenderjahr",
                  "Tarif" = if (is.null(x$tariff)) "mitgelieferte Tarifdatei" else "eigener Tarif"))
  invisible(x)
}

#' @export
#' @noRd
print.SimLevHarvestRule <- function(x, ...) {
  .blk_print("Freibetrag nutzen (harvest_rule)",
             list("Termin" = sprintf("j\u00e4hrlich ab %s (MM-TT, n\u00e4chster Handelstag)", x$day),
                  "Verlusttopf" = if (isTRUE(x$loss_pot)) "mitgenutzt" else "nicht genutzt"))
  invisible(x)
}

#' Persoenliche Besteuerung fuer simulation()
#' @export
#' @noRd
tax_profile <- function(rate = 26.375, church_tax = 0, sparer_pauschbetrag = 1000, private_sale_threshold = 1000,
                        base_rate = NULL, guenstigerpruefung = FALSE, income = NULL, harvest = NULL) {
  who <- "tax_profile"
  if (!is.numeric(rate) || length(rate) != 1L || is.na(rate) || rate < 0 || rate > 100)
    stop(sprintf("tax_profile: rate muss eine einzelne Zahl in Prozent zwischen 0 und 100 sein (z. B. 26.375 f\u00fcr 26,375 %%), nicht %s.",
                 .blk_show(rate)), call. = FALSE)
  .blk_frac_warn(who, rate, "rate")
  if (!is.null(church_tax)) {
    if (!is.numeric(church_tax) || length(church_tax) != 1L || is.na(church_tax) || church_tax < 0 || church_tax > 100)
      stop(sprintf("tax_profile: church_tax muss eine Zahl in Prozent zwischen 0 und 100 sein (in Deutschland 8 oder 9), nicht %s.",
                   paste(format(church_tax), collapse = ", ")), call. = FALSE)
    if (church_tax > 0 && church_tax < 1)
      warning(sprintf("tax_profile: church_tax = %s wird als %s %% gelesen (Prozent-Konvention); gemeint war vermutlich %s.",
                      format(church_tax), format(church_tax), format(church_tax * 100)), call. = FALSE)
    else if (church_tax > 9)
      warning(sprintf("tax_profile: church_tax = %s %% ist ungew\u00f6hnlich hoch (Kirchensteuer in Deutschland: 8 oder 9 %%).",
                      format(church_tax)), call. = FALSE)
    if (church_tax > 0 && !missing(rate))
      stop("tax_profile: rate und church_tax schlie\u00dfen sich aus; rate gilt nur ohne Kirchensteuer (mit church_tax gilt der Satz nach \u00a7 32d Abs. 1 EStG).",
           call. = FALSE)
  }
  .blk_num(who, sparer_pauschbetrag, "sparer_pauschbetrag", "eine einzelne endliche Zahl >= 0 (EUR je Jahr, z. B. 1000; 0 = ohne)")
  .blk_num(who, private_sale_threshold, "private_sale_threshold", "eine einzelne endliche Zahl >= 0 (Freigrenze in EUR, z. B. 1000)")
  if (is.character(base_rate)) {
    if (length(base_rate) != 1L || is.na(base_rate) || !nzchar(base_rate))
      stop(sprintf("tax_profile: 'base_rate' muss NULL, eine einzelne endliche Zahl (Basiszins in Prozent, z. B. 2.29; negativ erlaubt) oder der Name einer Spalte in data sein, nicht %s.",
                   .blk_show(base_rate)), call. = FALSE)
  } else {
    if (!is.null(base_rate) && (!is.numeric(base_rate) || length(base_rate) != 1L || !is.finite(base_rate)))
      stop(sprintf("tax_profile: 'base_rate' muss NULL, eine einzelne endliche Zahl (Basiszins in Prozent, z. B. 2.29; negativ erlaubt) oder der Name einer Spalte in data sein, nicht %s.",
                   .blk_show(base_rate)), call. = FALSE)
    .blk_frac_warn(who, base_rate, "base_rate", hi = 0.05)
  }
  .blk_lgl(who, guenstigerpruefung, "guenstigerpruefung")
  if (!is.null(income) && !inherits(income, c("SimLevIncomeRate", "SimLevIncomeTariff")))
    stop(sprintf("tax_profile: income muss NULL, ein Objekt aus income_rate() oder aus income_tariff() sein (beide schlie\u00dfen sich aus), nicht %s.",
                 paste(class(income), collapse = "/")), call. = FALSE)
  if (!is.null(harvest) && !inherits(harvest, "SimLevHarvestRule"))
    stop(sprintf("tax_profile: harvest muss NULL oder ein Objekt aus harvest_rule() sein, nicht %s.",
                 paste(class(harvest), collapse = "/")), call. = FALSE)
  structure(list(rate = rate, church_tax = church_tax, sparer_pauschbetrag = sparer_pauschbetrag,
                 private_sale_threshold = private_sale_threshold, base_rate = base_rate,
                 guenstigerpruefung = guenstigerpruefung, income = income, harvest = harvest),
            class = "SimLevTaxProfile")
}

#' @export
#' @noRd
print.SimLevTaxProfile <- function(x, ...) {
  ct <- x$church_tax %||% 0
  br <- x$base_rate
  .blk_print("Steuern (tax_profile)",
             list("Abgeltungsteuer" = if (ct > 0) sprintf("mit Kirchensteuer %s %% (Satz nach \u00a7 32d Abs. 1 EStG)", .blk_fmt(ct))
                                      else sprintf("%s %%", .blk_fmt(x$rate)),
                  "Sparer-Pauschbetrag" = if (x$sparer_pauschbetrag == 0) "keiner"
                                          else sprintf("%s EUR je Jahr", .blk_fmt(x$sparer_pauschbetrag)),
                  "Freigrenze \u00a7 23" = sprintf("%s EUR", .blk_fmt(x$private_sale_threshold)),
                  "Basiszins" = if (is.null(br)) "keiner (keine Vorabpauschale)"
                                else if (is.character(br)) sprintf("Spalte '%s'", br) else sprintf("%s %%", .blk_fmt(br)),
                  "G\u00fcnstigerpr\u00fcfung" = if (isTRUE(x$guenstigerpruefung)) "ja" else "nein",
                  "Einkommen" = .blk_income_text(x$income),
                  "Freibetrag nutzen" = .blk_harvest_text(x$harvest)))
  invisible(x)
}

# ── funds_costs ───────────────────────────────────────────────────────────────

#' Fondsmodus fuer simulation()
#' @export
#' @noRd
funds_costs <- function(fee = 0.95, performance_fee = 5) {
  for (a in c("fee", "performance_fee")) {
    x <- get(a)
    if (!is.numeric(x) || length(x) != 1L || is.na(x) || x < 0 || x > 100)
      stop(sprintf("funds_costs: %s muss eine Zahl in Prozent zwischen 0 und 100 sein (z. B. %s), nicht %s.",
                   a, if (a == "fee") "0.95 f\u00fcr 0,95 % p. a." else "5 f\u00fcr 5 %",
                   if (is.null(x)) "NULL" else paste(format(x), collapse = ", ")), call. = FALSE)
  }
  structure(list(fee = fee, performance_fee = performance_fee), class = "SimLevFundsCosts")
}

#' @export
#' @noRd
print.SimLevFundsCosts <- function(x, ...) {
  .blk_print("Fondsmodus (funds_costs)",
             list("Fondskosten" = sprintf("%s %% p. a.", .blk_fmt(x$fee)),
                  "Performancegeb\u00fchr" = sprintf("%s %% des Wertzuwachses \u00fcber dem H\u00f6chststand", .blk_fmt(x$performance_fee))))
  invisible(x)
}

# ── Uebersetzer ───────────────────────────────────────────────────────────────

#' Bausteine in die internen Werte der Engine uebersetzen
#'
#' Zweck: simulation() prueft die Klassen der Bausteine und uebersetzt sie in die Argumente der Engine
#' (.simulation_flat), die unveraendert rechnet.
#' Fondsmodus (funds): tax_mode = "funds"; mit tax = tax_profile() gelten dessen Angaben wie bis 6.2 die flachen
#' Steuerargumente im Fondsmodus (wirksam rate und church_tax fuer die Steuer auf den Gesamtgewinn bei
#' Liquidation; harvest und income_tariff mit Warnung, die uebrigen still ohne Wirkung). Ohne tax gilt der
#' Standardsatz 26,375 %.
#' Eingabe: costs, dca, rebalance, splits, tax, funds (Bausteine oder NULL).
#' Ausgabe: benannte Liste der Engine-Argumente.
#' Rebalancing: rebalance_plan() heisst balance_mode = TRUE; nur mit event_col, event_mode = "replace"
#' und skip = TRUE wird balance_mode = FALSE (kein Umschichten am ersten Tag, nur an Ereignistagen).
#' Sparer-Pauschbetrag: sparer_pauschbetrag = 0 heisst ohne Freibetrag (use_sparer_pauschbetrag = FALSE).
#' @keywords internal
#' @noRd
.sim_from_blocks <- function(costs, dca, rebalance, splits, tax, funds) {
  .blk_check(costs, "SimLevSimCosts", "costs", "sim_costs")
  .blk_check(dca, "SimLevDcaPlan", "dca", "dca_plan")
  .blk_check(rebalance, "SimLevRebalancePlan", "rebalance", "rebalance_plan")
  .blk_check(splits, "SimLevSplitRule", "splits", "split_rule")
  .blk_check(tax, "SimLevTaxProfile", "tax", "tax_profile")
  .blk_check(funds, "SimLevFundsCosts", "funds", "funds_costs")
  a <- list(order_fee = costs$order_fee, dca_fee = costs$dca_fee)
  if (!is.null(dca))
    a <- c(a, list(dca_mode = TRUE, dca_value = dca$value, dca_span = dca$span, dca_days = dca$days,
                   dca_unit = dca$unit, dca_anchor = dca$anchor, dca_start = dca$start, dca_skip = dca$skip,
                   balance_dca = dca$fill_deficits))
  if (!is.null(rebalance)) {
    events_only <- !is.null(rebalance$event_col) && identical(rebalance$event_mode, "replace")
    a <- c(a, list(balance_mode = !(events_only && isTRUE(rebalance$skip)), balance_span = rebalance$span,
                   balance_days = rebalance$days, balance_unit = rebalance$unit, balance_anchor = rebalance$anchor,
                   balance_start = rebalance$start, balance_skip = rebalance$skip, balance_thresh = rebalance$thresh,
                   balance_thresh_type = rebalance$thresh_type, event_col = rebalance$event_col,
                   event_mode = rebalance$event_mode, event_weight = rebalance$event_weight))
  }
  if (!is.null(splits)) a <- c(a, list(split_mode = TRUE, split_thresh = splits$thresh))
  if (!is.null(tax)) {
    br <- tax$base_rate
    a <- c(a, list(tax_mode = if (is.null(funds)) "person" else "funds", tax_rate = tax$rate, church_tax = tax$church_tax,
                   sparer_pauschbetrag = tax$sparer_pauschbetrag, use_sparer_pauschbetrag = tax$sparer_pauschbetrag > 0,
                   private_sale_threshold = tax$private_sale_threshold,
                   base_rate = if (is.character(br)) NULL else br, base_rate_flex = is.character(br),
                   base_rate_data = if (is.character(br)) br,
                   use_guenstigerpruefung = tax$guenstigerpruefung))
    inc <- tax$income
    if (inherits(inc, "SimLevIncomeRate"))
      a <- c(a, list(marginal_tax_rate = inc$marginal_rate, include_soli_on_income_tax = inc$soli_rate != 0,
                     soli_rate_income_tax = inc$soli_rate))
    else if (inherits(inc, "SimLevIncomeTariff"))
      a <- c(a, list(taxable_income = inc$taxable_income, tax_tariff = inc$tariff))
    if (!is.null(tax$harvest))
      a <- c(a, list(harvest_mode = TRUE, harvest_day = tax$harvest$day, harvest_loss_pot = tax$harvest$loss_pot))
  }
  if (!is.null(funds)) {
    if (is.null(tax)) a$tax_mode <- "funds"
    a <- c(a, list(funds_fee = funds$fee, bonus_fee = funds$performance_fee))
  }
  a
}

# ── Aufrufer von simulation(): sim_args und Pfade (Etappe 6.4) ────────────────
#
# sim_args der Aufrufer (bootstrap_study, param_search, param_bootstrap, sensitivity_grid,
# sensitivity_leverage, sensitivity_rebalancing, planning_lumpsum_vs_dca, Zusatzargumente von
# tactical_simulation) sind Argumente von simulation(), also auch Bausteine (dca = dca_plan(...)).
# Raster und Suchraeume (F1) sprechen Parameter der Bausteine mit Pfad an: "dca.value",
# "rebalance.thresh", "tax.rate", "tax.income.marginal_rate", "tax.harvest.day". Ein Pfad baut den
# Baustein neu: Grundwerte aus dem vorhandenen Baustein (z. B. aus sim_args), sonst die Standardwerte des
# Konstruktors. Alte flache Namen (bis 6.3) ergeben einen Fehler mit dem neuen Baustein (E1: keine Aliasse).

.SIM_TOP <- c("start_value", "costs", "dca", "rebalance", "splits", "tax", "funds", "risk_free", "fractions",
              "liquidate", "details")
.SIM_BLOCKS <- c(costs = "sim_costs", dca = "dca_plan", rebalance = "rebalance_plan", splits = "split_rule",
                 tax = "tax_profile", funds = "funds_costs")
.SIM_BLOCK_PARAMS <- list(
  sim_costs = c("order_fee", "dca_fee"),
  dca_plan = c("value", "span", "days", "unit", "anchor", "start", "skip", "fill_deficits"),
  rebalance_plan = c("span", "days", "unit", "anchor", "start", "skip", "thresh", "thresh_type", "event_col",
                     "event_mode", "event_weight"),
  split_rule = "thresh",
  tax_profile = c("rate", "church_tax", "sparer_pauschbetrag", "private_sale_threshold", "base_rate",
                  "guenstigerpruefung", "income", "harvest"),
  funds_costs = c("fee", "performance_fee"),
  income_rate = c("marginal_rate", "soli_rate"),
  income_tariff = c("taxable_income", "tariff"),
  harvest_rule = c("day", "loss_pot"))
.SIM_SUB <- list(income = c("income_rate", "income_tariff"), harvest = "harvest_rule")
.SIM_CLASS_CTOR <- c(SimLevIncomeRate = "income_rate", SimLevIncomeTariff = "income_tariff",
                     SimLevHarvestRule = "harvest_rule")
# alte flache Argumente: Pfad (leer = keiner) und Hinweis (leer = aus dem Pfad gebildet)
.SIM_FLAT <- matrix(c(
  "spread", "", "den Spread je Asset (asset_config(spread = \u2026))",
  "dca_mode", "", "dca = dca_plan(\u2026) (NULL = ohne Sparplan)",
  "dca_value", "dca.value", "", "dca_span", "dca.span", "", "dca_days", "dca.days", "",
  "dca_unit", "dca.unit", "", "dca_anchor", "dca.anchor", "", "dca_start", "dca.start", "",
  "dca_skip", "dca.skip", "", "balance_dca", "dca.fill_deficits", "",
  "balance_mode", "", "rebalance = rebalance_plan(\u2026) (NULL = ohne Rebalancing)",
  "balance_span", "rebalance.span", "", "balance_days", "rebalance.days", "",
  "balance_unit", "rebalance.unit", "", "balance_anchor", "rebalance.anchor", "",
  "balance_start", "rebalance.start", "", "balance_skip", "rebalance.skip", "",
  "balance_thresh", "rebalance.thresh", "", "balance_thresh_type", "rebalance.thresh_type", "",
  "event_col", "rebalance.event_col", "", "event_mode", "rebalance.event_mode", "",
  "event_weight", "rebalance.event_weight", "",
  "split_mode", "", "splits = split_rule(\u2026) (NULL = ohne Splits)",
  "split_thresh", "splits.thresh", "",
  "tax_mode", "", "tax = tax_profile(\u2026) bzw. funds = funds_costs(\u2026) (NULL = ohne)",
  "tax_rate", "tax.rate", "", "church_tax", "tax.church_tax", "",
  "sparer_pauschbetrag", "tax.sparer_pauschbetrag", "",
  "use_sparer_pauschbetrag", "", "tax = tax_profile(sparer_pauschbetrag = 0) (0 = ohne Pauschbetrag)",
  "private_sale_threshold", "tax.private_sale_threshold", "", "base_rate", "tax.base_rate", "",
  "base_rate_flex", "", "tax = tax_profile(base_rate = \"<Spalte>\")",
  "base_rate_data", "tax.base_rate", "tax = tax_profile(base_rate = \"<Spalte>\")",
  "use_guenstigerpruefung", "tax.guenstigerpruefung", "",
  "marginal_tax_rate", "tax.income.marginal_rate", "",
  "include_soli_on_income_tax", "", "tax = tax_profile(income = income_rate(marginal_rate, soli_rate = \u2026))",
  "soli_rate_income_tax", "tax.income.soli_rate", "",
  "taxable_income", "tax.income.taxable_income", "", "tax_tariff", "tax.income.tariff", "",
  "harvest_mode", "", "tax = tax_profile(harvest = harvest_rule(\u2026))",
  "harvest_day", "tax.harvest.day", "", "harvest_loss_pot", "tax.harvest.loss_pot", "",
  "funds_fee", "funds.fee", "", "bonus_fee", "funds.performance_fee", "",
  "order_fee", "costs.order_fee", "", "dca_fee", "costs.dca_fee", ""),
  ncol = 3, byrow = TRUE, dimnames = list(NULL, c("flat", "path", "hint")))

# Baustein-Aufruf zu einem Pfad, z. B. "dca = dca_plan(value = ...)"
.sim_path_hint <- function(path) {
  s <- strsplit(path, ".", fixed = TRUE)[[1]]
  ctor <- .SIM_BLOCKS[[s[1]]]
  if (length(s) == 2L) return(sprintf("%s = %s(%s = \u2026)", s[1], ctor, s[2]))
  sub <- Filter(function(cn) s[3] %in% .SIM_BLOCK_PARAMS[[cn]], .SIM_SUB[[s[2]]])[[1]]
  sprintf("%s = %s(%s = %s(%s = \u2026))", s[1], ctor, s[2], sub, s[3])
}

# Liste der Bausteine und Parameter fuer Meldungen
.sim_path_text <- function() {
  paste(vapply(names(.SIM_BLOCKS), function(b) {
    p <- .SIM_BLOCK_PARAMS[[.SIM_BLOCKS[[b]]]]
    sub <- unlist(lapply(intersect(p, names(.SIM_SUB)), function(s)
      paste0(s, ".", unique(unlist(.SIM_BLOCK_PARAMS[.SIM_SUB[[s]]])))))
    sprintf("%s (%s)", b, paste(c(p, sub), collapse = ", "))
  }, ""), collapse = "; ")
}

.sim_path_ok <- function(p) {
  s <- strsplit(p, ".", fixed = TRUE)[[1]]
  if (length(s) < 2L || length(s) > 3L || any(!nzchar(s)) || endsWith(p, ".") || !s[1] %in% names(.SIM_BLOCKS))
    return(FALSE)
  if (!s[2] %in% .SIM_BLOCK_PARAMS[[.SIM_BLOCKS[[s[1]]]]]) return(FALSE)
  length(s) == 2L || (!is.null(.SIM_SUB[[s[2]]]) && s[3] %in% unlist(.SIM_BLOCK_PARAMS[.SIM_SUB[[s[2]]]]))
}

#' Namen von sim_args, Raster oder Suchraum pruefen
#'
#' Zweck: erlaubt sind die Argumente von simulation() ausser data und strategy sowie Pfade zu Parametern der
#' Bausteine; alte flache Namen und unbekannte Namen ergeben einen Fehler mit dem Aufrufer who.
#' @keywords internal
#' @noRd
.sim_check_names <- function(nms, who) {
  for (k in nms) {
    if (k %in% .SIM_TOP) next
    i <- match(k, .SIM_FLAT[, "flat"])
    if (!is.na(i)) {
      path <- .SIM_FLAT[i, "path"]; hint <- .SIM_FLAT[i, "hint"]
      if (!nzchar(hint)) hint <- .sim_path_hint(path)
      stop(sprintf("%s: %s gibt es nicht mehr; bitte %s%s.", who, k, hint,
                   if (nzchar(path)) sprintf(" (Pfad \"%s\")", path) else ""), call. = FALSE)
    }
    if (grepl(".", k, fixed = TRUE)) {
      if (!.sim_path_ok(k))
        stop(sprintf("%s: unbekannter Pfad \"%s\"; m\u00f6glich sind die Bausteine mit ihren Parametern: %s.",
                     who, k, .sim_path_text()), call. = FALSE)
      next
    }
    stop(sprintf("%s: unbekanntes Argument %s f\u00fcr simulation(); m\u00f6glich sind %s sowie Pfade zu Parametern der Bausteine (z. B. \"dca.value\").",
                 who, if (nzchar(k)) k else "ohne Namen", paste(.SIM_TOP, collapse = ", ")), call. = FALSE)
  }
  invisible(NULL)
}

# Felder eines Bausteins als einfache Liste (NULL: keine)
.sim_fields <- function(obj) if (is.null(obj)) list() else stats::setNames(lapply(names(obj), function(k) obj[[k]]), names(obj))

# Baustein aus Feldern neu bauen; set = vom Pfad gesetzte Felder. Nicht gesetzte Felder, die der Konstruktor nur
# ohne ausdrueckliche Angabe annimmt (rate neben church_tax, event_mode ohne event_col), entfallen.
.sim_build <- function(ctor, f, set) {
  if (ctor == "tax_profile" && !"rate" %in% set && isTRUE(f$church_tax > 0)) f$rate <- NULL
  if (ctor == "rebalance_plan" && !"event_mode" %in% set && is.null(f$event_col)) f$event_mode <- NULL
  do.call(get(ctor, mode = "function"), f)
}

#' Argumente fuer simulation() setzen (Etappe 6.4)
#'
#' Zweck: over (benannte Liste: Argumente von simulation() und Pfade) auf args anwenden, wie bisher
#' utils::modifyList auf der obersten Ebene (NULL entfernt das Argument, also Standardwert). Pfade bauen den
#' Baustein mit den Feldern des vorhandenen Bausteins neu; mehrere Pfade eines Bausteins gelten zusammen.
#' Eingabe: args (geprueft), over, who (Name fuer Meldungen).
#' Ausgabe: benannte Liste der Argumente von simulation().
#' @keywords internal
#' @noRd
.sim_args_set <- function(args, over, who) {
  if (!length(over)) return(args)
  nm <- names(over)
  if (is.null(nm)) nm <- rep("", length(over))
  .sim_check_names(nm, who)
  is_path <- grepl(".", nm, fixed = TRUE)
  for (k in nm[!is_path]) args[[k]] <- over[[k]]
  paths <- nm[is_path]
  if (!length(paths)) return(args)
  parts <- strsplit(paths, ".", fixed = TRUE)
  blk <- vapply(parts, `[`, "", 1L)
  for (b in unique(blk)) {
    ctor <- .SIM_BLOCKS[[b]]
    f <- .sim_fields(args[[b]]); set <- character(0)
    idx <- which(blk == b)
    for (j in idx[lengths(parts[idx]) == 2L]) { k <- parts[[j]][2]; f[k] <- list(over[[paths[j]]]); set <- c(set, k) }
    j3 <- idx[lengths(parts[idx]) == 3L]
    for (s in unique(vapply(parts[j3], `[`, "", 2L))) {
      jj <- j3[vapply(parts[j3], `[`, "", 2L) == s]
      keys <- vapply(parts[jj], `[`, "", 3L)
      base <- f[[s]]
      bctor <- if (is.null(base)) NA_character_ else unname(.SIM_CLASS_CTOR[class(base)[1]])
      sctor <- if (!is.na(bctor) && all(keys %in% .SIM_BLOCK_PARAMS[[bctor]])) bctor
               else Filter(function(cn) all(keys %in% .SIM_BLOCK_PARAMS[[cn]]), .SIM_SUB[[s]])
      if (!length(sctor))
        stop(sprintf("%s: die Pfade %s passen zu keinem Baustein f\u00fcr %s (%s).", who,
                     paste0("\"", paths[jj], "\"", collapse = ", "), s, paste0(.SIM_SUB[[s]], "()", collapse = ", ")),
             call. = FALSE)
      sctor <- sctor[[1]]
      sf <- if (identical(sctor, bctor)) .sim_fields(base) else list()
      for (j in jj) sf[parts[[j]][3]] <- list(over[[paths[j]]])
      f[s] <- list(do.call(get(sctor, mode = "function"), sf)); set <- c(set, s)
    }
    args[[b]] <- .sim_build(ctor, f, set)
  }
  args
}

#' simulation() mit sim_args aufrufen
#' @keywords internal
#' @noRd
.sim_call <- function(data, strategy, args) do.call(simulation, c(list(data = data, strategy = strategy), args))
