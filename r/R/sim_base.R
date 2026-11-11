# =============================================================================
# SimLev - Grundfunktionen der Engine (aus simulation.R ausgelagert)
# =============================================================================
# Terminangaben (Termine rechnet core/prepare_core_impl.h), Tarifweg (Jahresrechnung in R, Referenz des Tarifkerns
# core/tariff_core_impl.h), Kennzahlen und Gebuehrenangaben, die simulation()
# (simulation.R) und die Phasen in sim_*.R nutzen. Die Handels- und Steuerfunktionen
# der Tagesschleife rechnet der C++-Kern (sim_engine.R).
# Gegenstuecke: python/simlev/_sim_base.py und julia/src/engine.jl.
# =============================================================================

# ═══════════════════════════════════════════════════════════════════════════════
# HILFSFUNKTIONEN UND HAUPTSIMULATION
# ═══════════════════════════════════════════════════════════════════════════════
# Funktionen fuer Asset-Konfiguration und Strategie stehen in eigenen Dateien:
# - asset_config.R
# - strategy.R
# ═══════════════════════════════════════════════════════════════════════════════

#--------> Hilfsfunktion zur Erstellung von Rebalance- und DCA-Flags:
# die Termine rechnet der Kern core/prepare_core_impl.h (dates_flags, Monatsarithmetik wie seq.Date);
# R prueft und wandelt die Angaben (.sched_spec) wie bisher calculate_dates_flags.
calculate_dates_flags <- function(mode, span, unit, days, dates, value = NULL, anchor, start_date, skip_start, liquidate){
  sc <- .sched_spec(mode, span, unit, days, dates, value, anchor, start_date, skip_start)
  .Call(C_sim_dates_flags, list(dates = as.numeric(dates), si = sc$si, start = sc$start, days = sc$days,
                                dcode = sc$dcode, liquidate = if (sc$si[1L] && liquidate) 1L else 0L))
}

#' Angaben eines Terminplans fuer den Kern
#'
#' Zweck: die Pruefungen und Umwandlungen von calculate_dates_flags (bis 1.3.0 in R gerechnet): ohne
#' Termine (mode, unit, value), span-Vorgabe, match.arg, Startdatum; den Schritt liest R aus
#' "<span> months" bzw. "<span> years" wie seq.Date, und was seq() dort ablehnt (span ohne ganze Zahl >= 1,
#' Start nach dem letzten Tag), meldet seq() selbst. Den Tag von days fuer anchor = "start" liest
#' as.Date("2000-1-<days>", "%Y-%m-%d") (gleiche Regeln wie as.Date(paste(Jahr, Monat, days)); 0 = NA).
#' Ausgabe: list(si = c(on, years, quarter, end, skip, has_days, step), start, days, dcode).
#' @keywords internal
#' @noRd
.sched_spec <- function(mode, span, unit, days, dates, value, anchor, start_date, skip_start) {
  if(!mode || is.null(unit) || (!is.null(value) && value <= 0)){
    return(list(si = integer(7), start = 0, days = NULL, dcode = NULL))
  }
  if (is.null(span)) span <- 1   # V-1: sinnvoller Default statt stillem No-Op
  unit   <- match.arg(unit,   c("month", "quarter", "year"))
  anchor <- match.arg(anchor, c("start", "end"))
  start_date <- if(is.null(start_date)) min(dates) else as.Date(start_date)
  first <- as.Date(format(start_date, if (unit == "year") "%Y-01-01" else "%Y-%m-01"))
  by <- if (unit == "year") paste(span, "years") else paste(if (unit == "month") span else span * 3, "months")
  step <- if (length(by) == 1L) suppressWarnings(as.integer(strsplit(by, " ", fixed = TRUE)[[1L]][1L])) else NA
  on <- 1L
  if (is.na(step) || step < 1L || first > max(dates)) {   # seq() meldet den Fehler (Aufruf wie bis 1.3.0) bzw. liefert hoechstens first
    base_seq <- if (unit == "year") seq(from = as.Date(format(start_date, "%Y-01-01")), to = max(dates), by = paste(span, "years"))
                else seq(from = as.Date(format(start_date, "%Y-%m-01")), to = max(dates),
                         by = paste(if (unit == "month") span else span * 3, "months"))
    on <- as.integer(length(base_seq) > 0L)
    step <- 1L
  }
  dcode <- if (!is.null(days)) {
    z <- as.integer(unclass(as.Date(paste0("2000-1-", days), format = "%Y-%m-%d")) - 10956)
    z[is.na(z)] <- 0L
    z
  }
  list(si = c(on, unit == "year", unit == "quarter", anchor == "end", if (skip_start) 1L else 0L, !is.null(days), step),
       start = as.numeric(start_date), days = if (!is.null(days)) as.numeric(days), dcode = dcode)
}

#--------> Tarifweg (income_tariff()): Hilfsfunktionen zur Jahresrechnung
# rechnet die Tagesengine den Jahresabschluss im Kern (tariff_core_impl.h); .tariff_close mit
# .tariff_base/.tariff_full/.tariff_diff bleibt als R-Referenz des Tarifkerns (Gleichlauf: tariff_fuzz.R und
# die R-Tests zum Tarif).
#' taxable_income pruefen: eine Zahl (alle Jahre), nach Jahr benannter Vektor oder data.frame (Jahr, Betrag)
#' @param x Eingabe taxable_income
#' @param years Ganzzahlen. Kalenderjahre der Simulation (jedes muss vorkommen)
#' @param plan_ok Logisch. ein Vektor ohne Namen (ein Wert je Planjahr von withdrawal_simulation()) ist
#'   zulaessig (income_tariff()); simulation() prueft ohne (Fehler: nach Kalenderjahren benennen)
#' @return Liste all (Zahl fuer alle Jahre oder NULL) und by_year (benannter Vektor oder NULL); mit plan_ok
#'   und einem Vektor ohne Namen beide NULL
#' @keywords internal
#' @noRd
.check_taxable_income <- function(x, years, who = "simulation", plan_ok = FALSE) {
  form <- "eine Zahl (zvE in EUR f\u00fcr alle Jahre), ein nach Kalenderjahren benannter Zahlenvektor (z. B. c(\"2024\" = 50000, \"2025\" = 52000)) oder ein data.frame mit den Spalten year und taxable_income"
  if (is.data.frame(x)) {
    nm <- tolower(names(x))
    yc <- match(c("year", "jahr"), nm); yc <- yc[!is.na(yc)][1]
    vc <- match(c("taxable_income", "betrag", "amount", "zve"), nm); vc <- vc[!is.na(vc)][1]
    if (is.na(yc) || is.na(vc)) {
      if (ncol(x) != 2L) chk_stop("a.m_check_taxable_income", who, paste(names(x), collapse = ", "))
      yc <- 1L; vc <- 2L
    }
    for (j in c(yc, vc)) if (is.factor(x[[j]])) chk_stop("spalte_faktor", who, names(x)[j])   # Entscheidung 15 (bis 1.6.3 Jahr still als Text)
    if (!is.numeric(x[[vc]])) chk_stop("a.m_check_taxable_income_2", who, names(x)[vc])
    # seit 1.6.5 (CR2-C-2, CR2-D-15): fehlendes Jahr mit eigener Meldung, in allen drei Sprachen gleich
    if (anyNA(x[[yc]])) chk_stop("a.zve_jahr_na", who, which(is.na(x[[yc]]))[1], names(x)[yc])
    x <- stats::setNames(as.numeric(x[[vc]]), as.character(x[[yc]]))
  }
  if (!is.numeric(x) || !length(x) || is.matrix(x))
    chk_stop("a.m_check_taxable_income_3", who, form)   # seit 1.6.4 ohne Eingabewert
  if (any(!is.finite(x))) {
    i <- which(!is.finite(x))[1]
    chk_stop("a.m_check_taxable_income_4", who, if (!is.null(names(x))) sprintf(" (f\u00fcr %s)", names(x)[i]) else "")   # seit 1.6.4 ohne den Wert
  }
  if (length(x) == 1L && is.null(names(x))) return(list(all = unname(as.numeric(x)), by_year = NULL))
  if (plan_ok && is.null(names(x))) return(list(all = NULL, by_year = NULL))
  if (is.null(names(x)) || any(is.na(names(x)) | names(x) == ""))
    stop(sprintf("%s: taxable_income mit %d Werten muss nach Kalenderjahren benannt sein; erwartet wird %s%s.", who, length(x), form,
                 if (is.null(names(x))) " (ein Vektor ohne Namen, ein Wert je Planjahr, gilt nur in withdrawal_simulation())" else ""),
         call. = FALSE)
  yy <- suppressWarnings(as.integer(trimws(names(x))))
  if (anyNA(yy) || any(as.character(yy) != trimws(names(x))))
    chk_stop("a.m_check_taxable_income_5", who, names(x)[which(is.na(yy) | as.character(yy) != trimws(names(x)))[1]])
  if (anyDuplicated(yy)) stop(sprintf("%s: taxable_income: Jahr %d kommt mehrfach vor.", who, yy[anyDuplicated(yy)]), call. = FALSE)
  miss <- setdiff(years, yy)
  if (length(miss))
    stop(sprintf("%s: taxable_income fehlt f\u00fcr %s %s (angegeben: %s); je Kalenderjahr der Simulation (%d bis %d) wird ein Betrag ben\u00f6tigt.", who,
                 if (length(miss) == 1L) "Simulationsjahr" else "Simulationsjahre", paste(miss, collapse = ", "),
                 paste(sort(yy), collapse = ", "), min(years), max(years)), call. = FALSE)
  list(all = NULL, by_year = stats::setNames(unname(as.numeric(x)), as.character(yy)))
}

# Spalten einer Jahreszeile des Tarifwegs (Folge TR_* in core/tariff_core_impl.h): tax_report$tariff_years von
# simulation(), tariff_years von withdrawal_simulation() (dort mit Spalte path davor), .tariff_close
.TARIFF_YEAR_COLS <- c("year", "taxable_income", "church_tax_paid_deductible", "church_tax_refunded",
                       "church_tax_net_deduction", "taxable_income_net", "deduction_effect", "gain_p23",
                       "income_tax_p23", "soli_p23", "church_tax_p23", "tax_p23", "capital_income", "abgeltung_burden",
                       "church_tax_withheld_k", "tariff_income_tax_k", "tariff_soli_k", "tariff_church_tax_k",
                       "tariff_burden", "burden_without_gp", "burden_with_gp", "guenstiger", "settlement", "refund",
                       "church_tax_settlement_next_year")

#' Jahreszeilen des Tarifwegs als data.frame (seit 1.6.3 Spalte fuer Spalte statt data.frame() je Jahr und rbind;
#' gleiches Objekt: year ganzzahlig, guenstiger logisch, sonst Zahlen, Zeilennamen 1..k)
#' @param rw Matrix mit einer Spalte je Jahr und den Zeilen in der Folge .TARIFF_YEAR_COLS (Ausgabe des Kerns)
#' @return data.frame, NULL ohne Jahr
#' @keywords internal
#' @noRd
.tariff_years_frame <- function(rw) {
  if (!ncol(rw)) return(NULL)
  d <- lapply(seq_len(nrow(rw)), function(j) rw[j, ])
  names(d) <- .TARIFF_YEAR_COLS
  d$year <- as.integer(d$year); d$guenstiger <- d$guenstiger != 0
  structure(d, row.names = .set_row_names(ncol(rw)), class = "data.frame")
}

#' zvE eines Jahres und Saldo des Kirchensteuer-Bescheids aus dem Vorjahr (Zahlung > 0, Erstattung < 0)
#' @param env Umgebung der Tarifrechnung (simulation()): tariff, zve_all bzw. zve (benannt nach
#'   Jahr), ks (KiSt-Saldo je Zahlungsjahr, benannt), church_k, kapest_rate, use_gp, rows
#' @param year Ganzzahl. Kalenderjahr
#' @return Liste zve (vorgegeben, NA ohne Angabe) und ks_prev (im Jahr gezahlte (> 0) bzw. erstattete
#'   (< 0) Kirchensteuer aus dem Bescheid des Vorjahres)
#' @keywords internal
#' @noRd
.tariff_base <- function(env, year) {
  zv <- if (!is.null(env$zve_all)) env$zve_all else unname(env$zve[as.character(year)])
  ks <- unname(env$ks[as.character(year)]); if (!length(ks) || is.na(ks)) ks <- 0
  list(zve = zv, ks_prev = ks)
}

#' Tarifliche Belastung F(x) = T(x) + S(T(x)) + KiSt (church_k x T(x), nicht gerundet)
#' @keywords internal
#' @noRd
.tariff_full <- function(env, x) {
  e <- .tariff_income_tax(env$tariff, x); so <- .tariff_soli(env$tariff, e); ki <- env$church_k * e
  list(est = e, soli = so, kist = ki, total = e + so + ki)
}

#' Unterschied der tariflichen Belastung F(x1) - F(x0) je Bestandteil (ESt, Soli, KiSt, Summe)
#' @keywords internal
#' @noRd
.tariff_diff <- function(env, x1, x0) {
  if (is.na(x1) || is.na(x0)) return(list(est = 0, soli = 0, kist = 0, total = 0))
  a <- .tariff_full(env, x1); b <- .tariff_full(env, x0)
  list(est = a$est - b$est, soli = a$soli - b$soli, kist = a$kist - b$kist, total = a$total - b$total)
}

#' Jahresabschluss im Tarifweg: Veranlagung des Jahres (§ 23, Guenstigerpruefung, Kirchensteuer als
#' Sonderausgabe nach dem Zahlungsjahr), Jahreszeile
#'
#' Belastung durch die Simulation gegenueber der Basis F(zvE) (zvE ohne die Simulation):
#' ohne Guenstigerpruefung X0 = F(zvE - ks_prev + G23) - F(zvE) + Abgeltung(K);
#' mit Guenstigerpruefung X1 = F(zvE - ks_prev - KiSt_abg(K) + G23 + K) - F(zvE).
#' ks_prev = Saldo des KiSt-Bescheids des Vorjahres, im Jahr gezahlt (> 0, Sonderausgabe) bzw. erstattet
#' (< 0, Verrechnung bzw. Hinzurechnung, § 10 Abs. 4b Satz 2/3 EStG); KiSt_abg(K) = als Zuschlag zur
#' Abgeltungsteuer auf K einbehaltene KiSt, im Jahr gezahlt und nur bei tariflicher Besteuerung von K
#' abziehbar (§ 10 Abs. 1 Nr. 4, § 11 EStG). Guenstiger, wenn X1 < X0. Abrechnung am Abrechnungstag
#' des Folgejahres: Saldo D = X - Abgeltung(K) (D > 0 Nachzahlung, D < 0 Erstattung); der KiSt-Saldo
#' dieses Bescheids (tarifliche KiSt-Aenderung minus angerechnete KiSt_abg) ist Zahlung bzw. Erstattung
#' des Folgejahres (env$ks).
#' @param g23 Zahl. Steuerpflichtiger § 23-Gewinn des Jahres (nach Freigrenze und Verlustvortrag)
#' @param k_base Zahl. Kapitaleinkuenfte K nach § 20 (Bemessungsgrundlage der Abgeltungsteuer per Saldo)
#' @param abg_rate Zahl. Abgeltungsteuersatz inkl. Soli/KiSt als Anteil
#' @return Saldo D in EUR (> 0 Nachzahlung, < 0 Erstattung); NA ohne zvE fuer das Jahr (keine Veranlagung)
#' @keywords internal
#' @noRd
.tariff_close <- function(env, year, g23, k_base, abg_rate, details = FALSE) {
  b <- .tariff_base(env, year)
  if (is.na(b$zve)) return(NA_real_)
  k <- max(0, k_base); abg <- k * abg_rate
  kabg <- k * env$kapest_rate * env$church_k            # KiSt-Anteil der einbehaltenen Abgeltungsteuer auf K
  gp_on <- isTRUE(env$use_gp) && k > 0
  B0 <- b$zve - b$ks_prev                               # Sonderausgaben-Saldo aus dem Vorjahresbescheid
  B1 <- B0 - kabg                                       # mit Guenstigerpruefung: einbehaltene KiSt auf K abziehbar
  X0 <- .tariff_diff(env, B0 + g23, b$zve)$total + abg
  X1 <- if (gp_on) .tariff_diff(env, B1 + g23 + k, b$zve)$total else NA_real_
  fav <- gp_on && X1 < X0
  Bx <- if (fav) B1 else B0
  ded <- .tariff_diff(env, Bx, b$zve)                   # Wirkung des Sonderausgaben-Saldos auf das uebrige Einkommen
  p23 <- .tariff_diff(env, Bx + g23, Bx)
  tk <- if (isTRUE(env$use_gp)) .tariff_diff(env, B1 + g23 + k, B1 + g23) else list(est = NA_real_, soli = NA_real_, kist = NA_real_, total = NA_real_)
  tot <- .tariff_diff(env, Bx + g23 + if (fav) k else 0, b$zve)
  D <- (if (fav) X1 else X0) - abg
  ks <- tot$kist - if (fav) kabg else 0                 # KiSt-Bescheid: > 0 Nachzahlung, < 0 Erstattung im Folgejahr
  env$ks[as.character(year + 1L)] <- ks
  paid <- max(0, b$ks_prev) + if (fav) kabg else 0; refunded <- max(0, -b$ks_prev)
  env$rows[[length(env$rows) + 1L]] <- data.frame(
    year = as.integer(year), taxable_income = b$zve,
    church_tax_paid_deductible = paid, church_tax_refunded = refunded, church_tax_net_deduction = paid - refunded,
    taxable_income_net = Bx, deduction_effect = ded$total,
    gain_p23 = g23, income_tax_p23 = p23$est, soli_p23 = p23$soli, church_tax_p23 = p23$kist, tax_p23 = p23$total,
    capital_income = k, abgeltung_burden = abg, church_tax_withheld_k = kabg,
    tariff_income_tax_k = tk$est, tariff_soli_k = tk$soli, tariff_church_tax_k = tk$kist, tariff_burden = tk$total,
    burden_without_gp = X0, burden_with_gp = X1, guenstiger = fav,
    settlement = D, refund = max(0, -D), church_tax_settlement_next_year = ks)
  if (details) {
    cat(sprintf("  Tarif %d: zvE %.2f EUR - KiSt-Sonderausgaben %.2f EUR (gezahlt %.2f, erstattet %.2f) = %.2f EUR (Wirkung %.2f EUR)\n",
                year, b$zve, paid - refunded, paid, refunded, Bx, ded$total))
    if (g23 > 0) cat(sprintf("    \u00a7 23: Gewinn %.2f EUR -> Steuerlast ESt %.2f + Soli %.2f + KiSt %.2f = %.2f EUR\n",
                             g23, p23$est, p23$soli, p23$kist, p23$total))
    if (isTRUE(env$use_gp)) cat(sprintf("    G\u00fcnstigerpr\u00fcfung: K %.2f EUR, Abgeltungsteuer %.2f EUR (KiSt %.2f), Tarif auf K %.2f EUR (ESt %.2f + Soli %.2f + KiSt %.2f); Belastung ohne %.2f / mit %s EUR -> %s\n",
                           k, abg, kabg, tk$total, tk$est, tk$soli, tk$kist, X0, if (is.na(X1)) "-" else sprintf("%.2f", X1),
                           if (fav) "Tarif" else "Abgeltungsteuer bleibt"))
    cat(sprintf("    Abrechnung: %s %.2f EUR; KiSt-Bescheid %+.2f EUR (Sonderausgabe %d)\n",
                if (D >= 0) "Nachzahlung" else "Erstattung", abs(D), ks, year + 1L))
  }
  D
}

#--------> Hilfsfunktion: geldgewichtete Jahresrendite (interner Zinsfuss, XIRR):
#' Interner Zinsfuss p. a. aus datierten Einzahlungen und Endwert
#'
#' Loest \eqn{\sum_j a_j (1 + r)^{T - t_j} = V} (Einzahlungen \eqn{a_j} zu den Zeitpunkten
#' \eqn{t_j} in Jahren ab Start, Kalendertage / 365.25 wie die CAGR, Endwert \eqn{V} bei \eqn{T}).
#' Nur mit dem Startwert bei \eqn{t = 0} ist die Loesung \eqn{(V / a_1)^{1/T} - 1}, die CAGR.
#' Brent-Verfahren (wie stats::uniroot, im Kern core/evaluate_core_impl.h) in \eqn{u = T \log(1 + r)}; die Klammer wird auf einem Raster
#' \eqn{u \in [-200, 200]} gesucht (erste Vorzeichenwende; bei reinen Einzahlungen ist die
#' Funktion monoton und die Nullstelle eindeutig). Liegt die Nullstelle unter -200
#' (Beinahe-Totalverlust), wird die untere Grenze verdoppelt, bis ein Vorzeichenwechsel
#' vorliegt oder \eqn{\exp(u e)} fuer alle Restlaufzeitanteile \eqn{e > 0} unterlaeuft.
#' @param t Zahlenvektor. Zeitpunkte der Einzahlungen in Jahren ab Start (0 = Startwert)
#' @param amount Zahlenvektor. Einzahlungen in EUR (positiv)
#' @param end_value Zahl. Endwert in EUR
#' @param horizon Zahl. Laufzeit T in Jahren
#' @return Rendite p. a. als Anteil; -1 bei Endwert 0, NA ohne Loesung
#' @keywords internal
#' @noRd
.xirr_rate <- function(t, amount, end_value, horizon) {
  # Rechnung im Kern (core/evaluate_core_impl.h, xirr; Brent ueber sl_r_zeroin2 wie
  # stats::uniroot); Warnungen von uniroot mit Text wie bis R 1.3.0, ohne Aufruf
  r <- .Call(C_sim_xirr, as.double(t), as.double(amount),
             if (length(end_value) == 1L) as.double(end_value) else NA_real_,
             if (length(horizon) == 1L) as.double(horizon) else NA_real_)
  for (code in r[[2L]]) .sim_eval_warn(code, numeric(4))
  r[[1L]]
}

#--------> Hilfsfunktion zur Berechnung der Skewness:
calculate_skewness <- function(x, na.rm = TRUE){
  if(na.rm){
    x <- x[!is.na(x)]
  }

  n <- length(x)
  if(n < 3){
    return(NA)
  }

  mean_x <- mean(x)
  sd_x <- .sl_sd(x)

  # seit 1.6.5 (CR2-X20-2): nicht endliche Streuung (NA mit na.rm = FALSE, Inf im Vektor) ergibt NA wie in Python und
  # Julia (bis 1.6.4 Rohfehler "missing value where TRUE/FALSE needed")
  if(!is.finite(sd_x) || sd_x == 0){
    return(NA)
  }

  # seit 1.6.4 (K43 T1-R11) Summanden (d * d) * d statt (x - mean_x)^3, wie der Kern (simlev_eval::moments)
  d <- x - mean_x
  skew <- (n / ((n - 1) * (n - 2))) * sum(d * d * d) / (sd_x^3)

  return(skew)
}

#--------> Hilfsfunktion zur Berechnung der Kurtosis:
calculate_kurtosis <- function(x, na.rm = TRUE, excess = TRUE){
  if(na.rm){
    x <- x[!is.na(x)]
  }

  n <- length(x)
  if(n < 4){
    return(NA)
  }

  mean_x <- mean(x)
  sd_x <- .sl_sd(x)

  # seit 1.6.5 (CR2-X20-2): nicht endliche Streuung (NA mit na.rm = FALSE, Inf im Vektor) ergibt NA wie in Python und
  # Julia (bis 1.6.4 Rohfehler "missing value where TRUE/FALSE needed")
  if(!is.finite(sd_x) || sd_x == 0){
    return(NA)
  }

  # seit 1.6.4 (K43 T1-R11) Summanden (d * d) * (d * d) statt (x - mean_x)^4, wie der Kern (simlev_eval::moments)
  d <- x - mean_x
  q <- d * d
  kurt <- (n * (n + 1)) / ((n - 1) * (n - 2) * (n - 3)) * 
          sum(q * q) / (sd_x^4)

  if(excess){
    kurt <- kurt - (3 * (n - 1)^2) / ((n - 2) * (n - 3))
  }

  return(kurt)
}

#--------> Ordergebuehren (Paket-Umgebung; NULL = keine Gebuehr, Engine unveraendert)
.fee_env <- new.env(parent = emptyenv())

#' Gebuehrenangabe normalisieren
#' @param fn,arg Funktion und Argument fuer Meldungen (seit 1.6.4, K43 T1-R5; bis dahin "order_fee/dca_fee" bzw.
#'   ganz ohne Funktionsnamen)
#' @keywords internal
#' @noRd
.fee_spec <- function(x, fn, arg) {
  if (is.null(x)) return(NULL)
  if (is.numeric(x) && length(x) == 1L) x <- list(fixed = x)
  if (!is.list(x)) chk_stop("ut1.gebuehr", fn, arg)
  nm <- names(x)
  # Tippfehler nicht still ignorieren; seit K43 T1-R5 je Fall eine Meldung aus der Tabelle (bis dahin eine Sammelmeldung)
  if (length(x) && (is.null(nm) || any(nm == ""))) chk_stop("e2.benannt", fn, arg)
  unk <- setdiff(nm, c("fixed", "percent", "min", "max"))
  if (length(unk)) chk_stop("ut1.gebuehr_feld", fn, unk[1L], arg)
  if (anyDuplicated(nm)) chk_stop("e2.doppelt", fn, arg)   # seit K43 T1-R7 (bis dahin galt still das erste Feld)
  # seit 1.6.4 (A-046): je Feld eine einzelne Zahl, nicht NA, endlich (max auch Inf); bis 1.6.3 liefen NA, Text
  # und TRUE je Sprache verschieden durch. Negative Werte und min > max meldet die Pruefung danach.
  for (k in nm) {
    v <- x[[k]]
    if (is.null(v)) next
    if (!(is.numeric(v) && length(v) == 1L && !is.na(v) && (is.finite(v) || (k == "max" && v == Inf))))
      chk_stop(if (k == "max") "e1.zahl_inf" else "zahl", fn, paste0(arg, "$", k))
  }
  s <- list(fixed = x$fixed %||% 0, percent = (x$percent %||% 0) / 100, min = x$min %||% 0, max = x$max %||% Inf)
  if (s$fixed < 0 || s$percent < 0 || s$min < 0 || s$max < s$min) chk_stop("ut1.gebuehr_negativ", fn, arg)
  if (s$fixed == 0 && s$percent == 0 && s$min == 0) return(NULL)
  s
}

