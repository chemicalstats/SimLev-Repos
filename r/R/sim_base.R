# =============================================================================
# SimLev - Grundfunktionen der Engine (aus simulation.R ausgelagert)
# =============================================================================
# Steuer-, Termin-, Signal-, Handels-, Split- und Gebuehrenfunktionen, Tarifweg,
# Jahreswechsel und Kennzahlen, die simulation() (simulation.R) und die Phasen
# in sim_*.R nutzen. Gegenstuecke: python/simlev/_sim_base.py und
# julia/src/engine.jl.
# =============================================================================

# ═══════════════════════════════════════════════════════════════════════════════
# HILFSFUNKTIONEN UND HAUPTSIMULATION
# ═══════════════════════════════════════════════════════════════════════════════
# Funktionen fuer Asset-Konfiguration und Strategie stehen in eigenen Dateien:
# - asset_config.R
# - strategy.R
# ═══════════════════════════════════════════════════════════════════════════════

#' Berechnet § 20 EStG Kapitalertragsteuer
#' @keywords internal
#' @noRd
.calculate_paragraph_20_tax <- function(trade_gain, bonus, totals, tax_rate, use_spb) {
  # C++-Port (tax_core.cpp); totals wird IN PLACE mutiert
  res <- .sim_p20_tax_cpp(trade_gain, bonus, totals, tax_rate, use_spb)
  return(list(tax = res$tax, totals = totals, spb_used = res$spb_used))
}


#' Berechnet die Steuer auf die Vorabpauschale (M3, R-2)
#'
#' Die Vorabpauschale ist ein fiktiver Ertrag. Sie wird nach der Teilfreistellung
#' mit dem allgemeinen § 20-Verlusttopf verrechnet (vor dem Sparer-Pauschbetrag,
#' R-2), erzeugt aber selbst keinen Verlust; die Steuer ist nie negativ.
#'
#' Die Vorabpauschale mindert spaeter beim Verkauf die Steuerlast (§ 19 InvStG).
#'
#' @param flat_rate Zahl. Brutto-Vorabpauschale in EUR vor Teilfreistellung
#' @param bonus Zahl. Teilfreistellung als Anteil (intern, z. B. 0.30 fuer Aktien-ETFs)
#' @param totals Liste. Die totals-Struktur aus sim_mem[["totals"]] (wird direkt veraendert)
#' @param tax_rate Zahl. Effektiver Steuersatz als Anteil (nach Guenstigerpruefung)
#' @param use_spb Logisch. Sparer-Pauschbetrag anwenden?
#'
#' @return Liste mit tax, totals, spb_used, taxable_amount
#' @keywords internal
#' @noRd
.calculate_vorabpauschale_tax <- function(flat_rate, bonus, totals, tax_rate, use_spb) {
  # C++-Port (tax_core.cpp, R-2: Verlusttopf vor SPB); totals in place
  res <- .sim_vp_tax_cpp(flat_rate, bonus, totals, tax_rate, use_spb)
  return(list(tax = res$tax, totals = totals, spb_used = res$spb_used,
              taxable_amount = res$taxable_amount))
}

#--------> Hilfsfunktion zur Erstellung von Rebalance- und DCA-Flags:
calculate_dates_flags <- function(mode, span, unit, days, dates, value = NULL, anchor, start_date, skip_start, liquidate){
  if(!mode || is.null(unit) || (!is.null(value) && value <= 0)){
    return(rep(FALSE, length(dates)))
  }
  if (is.null(span)) span <- 1   # V-1: sinnvoller Default statt stillem No-Op

  unit   <- match.arg(unit,   c("month", "quarter", "year"))
  anchor <- match.arg(anchor, c("start", "end"))

  start_date <- if(is.null(start_date)) min(dates) else as.Date(start_date)
  schedule <- c()

  if(unit == "month"){
    base_seq <- seq(
      from = as.Date(format(start_date, "%Y-%m-01")),
      to   = max(dates),
      by   = paste(span, "months")
    )

    schedule <- if(is.null(days)){
      base_seq
    } else {
      as.Date(unlist(lapply(base_seq, function(m){
        yr  <- as.integer(format(m, "%Y"))
        mon <- as.integer(format(m, "%m"))

        if(anchor == "start"){
          as.Date(paste(yr, mon, days, sep = "-"), format = "%Y-%m-%d")
        } else {
          # #14 FIX: Monatsende korrekt über Folgemonat-Ersten berechnen
          if (mon == 12L) {
            month_end <- as.Date(paste0(yr + 1L, "-01-01")) - 1L
          } else {
            month_end <- as.Date(paste0(yr, "-", sprintf("%02d", mon + 1L), "-01")) - 1L
          }
          # R1-24: Tage, die es im Monat nicht gibt (z. B. 31 vom Ende im Februar), entfallen
          d_end <- month_end - (days - 1)
          d_end[d_end < m] <- NA
          d_end
        }
      })))
    }

  } else if(unit == "quarter"){
    base_seq <- seq(
      from = as.Date(format(start_date, "%Y-%m-01")),
      to   = max(dates),
      by   = paste(span * 3, "months")
    )

    schedule <- if(is.null(days)){
      base_seq
    } else {
      as.Date(unlist(lapply(base_seq, function(q){
        yr  <- as.integer(format(q, "%Y"))
        mon <- as.integer(format(q, "%m"))

        if(anchor == "start"){
          as.Date(paste(yr, mon, days, sep = "-"), format = "%Y-%m-%d")
        } else {
          # #14 FIX: Quartalsende korrekt über Folgequartal-Ersten berechnen
          end_mon <- mon + 3L
          end_yr <- yr
          if (end_mon > 12L) { end_mon <- end_mon - 12L; end_yr <- yr + 1L }
          quarter_end <- as.Date(paste0(end_yr, "-", sprintf("%02d", end_mon), "-01")) - 1L
          quarter_end - (days - 1)
        }
      })))
    }

  } else {
    # unit == "year"
    base_seq <- seq(
      from = as.Date(format(start_date, "%Y-01-01")),
      to   = max(dates),
      by   = paste(span, "years")
    )

    schedule <- if(is.null(days)){
      base_seq
    } else {
      as.Date(unlist(lapply(base_seq, function(y){
        yr <- as.integer(format(y, "%Y"))

        if(anchor == "start"){
          as.Date(paste(yr, 1, days, sep = "-"), format = "%Y-%m-%d")
        } else {
          year_end <- as.Date(paste0(yr, "-12-31"))
          year_end - (days - 1)
        }
      })))
    }
  }

  schedule <- schedule[schedule %in% dates]

  if(skip_start){
    schedule <- schedule[schedule != min(dates)]
  }

  if(liquidate){
    schedule <- schedule[schedule != max(dates)]
  }

  dates %in% schedule
}


#--------> Hilfsfunktion zur Erstellung der Split-Flags:
#' Berechnet Split-Flags fuer alle Assets (vektorisiert)
#'
#' @param input sim_mem-Struktur
#' @param base Zahl. Zielkurs nach dem Split, Basis des Split-Verhaeltnisses (Aufruf mit 100)
#' @param mode Logisch. Split-Modus aktiv?
#' @param dates Date-Vektor. Simulationstage
#' @param split_thresh Zahlenvektor c(untere, obere) Kursschwelle oder NULL (NULL = keine Splits)
#'
#' @return Logischer Vektor: TRUE, wenn an diesem Tag mindestens ein Asset splittet
#' @keywords internal
#' @noRd
.calculate_split_flags <- function(input, base, mode, dates, split_thresh = NULL) {
  if (!mode || is.null(split_thresh)) {
    return(rep(FALSE, length(dates)))
  }
  
  n_days <- length(dates)
  n_assets <- length(input[["market"]])
  
  # Preis-Matrix erstellen
  split_price <- matrix(
    unlist(lapply(input[["market"]], function(x) x[["asset_price"]])),
    nrow = n_days,
    ncol = n_assets
  )
  
  # Ergebnis-Matrix
  flag_split <- matrix(FALSE, nrow = n_days, ncol = n_assets)
  
  # Pro Asset verarbeiten (äußere Schleife bleibt, innere wird vektorisiert)
  for (j in seq_len(n_assets)) {
    prices <- split_price[, j]
    i <- 1
    
    while (i <= n_days) {
      current_price <- prices[i]
      
      # Forward Split (Preis zu hoch)
      if (current_price > split_thresh[[2]]) {
        flag_split[i, j] <- TRUE
        split_ratio <- current_price / base
        # Vektorisierte Anpassung aller folgenden Preise
        prices[i:n_days] <- prices[i:n_days] / split_ratio
        
      # Reverse Split (Preis zu niedrig)
      } else if (current_price < split_thresh[[1]]) {
        flag_split[i, j] <- TRUE
        split_ratio <- base / current_price
        prices[i:n_days] <- prices[i:n_days] * split_ratio
      }
      
      i <- i + 1
    }
  }
  
  # Rückgabe: TRUE wenn mindestens ein Asset an diesem Tag splittet
  return(rowSums(flag_split) > 0)
}

#--------> Hilfsfunktion zur Evaluation von Kaufsignalen:
  #' Kaufsignal eines Assets auswerten
#'
#' @param input sim_mem-Struktur
#' @param name Zeichenkette. Asset-Name
#' @param index Ganzzahl. Aktueller Zeitindex
#'
#' @return Logisch. TRUE, wenn ein Kaufsignal vorliegt, sonst FALSE
#'
#' @details
#' Liefert TRUE, wenn:
#' - trading = "signal" UND Kaufsignal-Spalte TRUE UND money > 0 UND count = 0 (Einstieg)
#' - trading = "signal" UND count > 0 UND money > 0 UND kein Verkaufssignal (A7-09: neues Geld
#'   einer offenen Position sofort anlegen)
#' - trading = "bnh" UND money > 0
#' 
#' @keywords internal
#' @noRd
.calculate_buy_signal <- function(input, name, index){
  signal_buy <- FALSE

  if(input[["assets"]][[name]][["style"]] == "signal" && input[["market"]][[name]][["signal_buy"]][index] && input[["status"]][[name]][["money"]] > 0 && input[["status"]][[name]][["count"]] == 0){
      signal_buy <- TRUE
  }

  # A7-09: Ein Signal-Asset mit offener Position legt neues Geld (Sparraten, Restcash, Umverteilungen)
  # sofort an wie Buy-and-Hold; das Signal steuert nur Ein- und Ausstieg (nicht am Tag eines Verkaufssignals)
  if(input[["assets"]][[name]][["style"]] == "signal" && input[["status"]][[name]][["count"]] > 0 &&
     input[["status"]][[name]][["money"]] > 0 && !isTRUE(input[["market"]][[name]][["signal_sell"]][index])){
    signal_buy <- TRUE
  }

  if(input[["assets"]][[name]][["style"]] == "bnh" && input[["status"]][[name]][["money"]] > 0){
    signal_buy <- TRUE
  }

  return(signal_buy)
}

#--------> Hilfsfunktion zur Evaluation von Verkaufssignalen:
.calculate_sell_signal <- function(input, name, index){
  signal_sell <- FALSE

  if(input[["assets"]][[name]][["style"]] == "signal" && input[["market"]][[name]][["signal_sell"]][index] && input[["status"]][[name]][["count"]] > 0){
    signal_sell <- TRUE
  }

  if(input[["assets"]][[name]][["style"]] == "bnh"){
    signal_sell <- FALSE
  }

  return(signal_sell)
}

#--------> Hilfsfunktion zur Berechnung des FIFO-Kaufpreises:
.calculate_fifo_price <- function(trades, units, front_index = 1){
  # C++-Port (fifo_core.cpp)
  .sim_fifo_price_cpp(trades, units, as.integer(front_index))
}


#--------> Hilfsfunktion zur Berechnung der anrechenbaren Vorabpauschale (§ 19 InvStG):
#' Berechnet die anteilige Vorabpauschale fuer verkaufte Anteile
#'
#' @param trades Liste der Kauf-Transaktionen
#' @param units Anzahl zu verkaufender Anteile
#' @param front_index FIFO-Startindex
#'
#' @return Anteilige Vorabpauschale in EUR
#' @keywords internal
#' @noRd
.calculate_fifo_vorabpauschale <- function(trades, units, front_index = 1) {
  # C++-Port (fifo_core.cpp)
  .sim_fifo_vp_cpp(trades, units, as.integer(front_index))
}
  
#--------> Hilfsfunktion zur lot-weisen Steuerberechnung für § 23 EStG:
.calculate_private_sale_tax <- function(input, name, trade_count, sell_price, current_date) {
  # C++-Port (fifo_core.cpp), Par.-23-Jahresfrist kalendergenau in C++
  .sim_private_sale_tax_cpp(
    input[["trades"]][[name]][["buys"]],
    as.integer(input[["trades"]][[name]][["fifo_front"]]),
    trade_count, sell_price, as.integer(current_date))
}
  
#' Argument fuer Fehlermeldungen darstellen (NULL, Text in Anfuehrungszeichen, Zahlen)
#' @keywords internal
#' @noRd
.show_arg_s <- function(x) if (is.null(x)) "NULL" else paste(deparse(x), collapse = "")

#--------> Tarifweg (income_tariff()): Hilfsfunktionen zur Jahresrechnung
#' taxable_income pruefen: eine Zahl (alle Jahre), nach Jahr benannter Vektor oder data.frame (Jahr, Betrag)
#' @param x Eingabe taxable_income
#' @param years Ganzzahlen. Kalenderjahre der Simulation (jedes muss vorkommen)
#' @return Liste all (Zahl fuer alle Jahre oder NULL) und by_year (benannter Vektor oder NULL)
#' @keywords internal
#' @noRd
.check_taxable_income <- function(x, years, who = "simulation") {
  form <- "eine Zahl (zvE in EUR f\u00fcr alle Jahre), ein nach Kalenderjahren benannter Zahlenvektor (z. B. c(\"2024\" = 50000, \"2025\" = 52000)) oder ein data.frame mit den Spalten year und taxable_income"
  if (is.data.frame(x)) {
    nm <- tolower(names(x))
    yc <- match(c("year", "jahr"), nm); yc <- yc[!is.na(yc)][1]
    vc <- match(c("taxable_income", "betrag", "amount", "zve"), nm); vc <- vc[!is.na(vc)][1]
    if (is.na(yc) || is.na(vc)) {
      if (ncol(x) != 2L) stop(sprintf("%s: taxable_income als data.frame braucht die Spalten year und taxable_income (oder genau zwei Spalten Jahr, Betrag); vorhanden: %s.", who,
                                      paste(names(x), collapse = ", ")), call. = FALSE)
      yc <- 1L; vc <- 2L
    }
    if (!is.numeric(x[[vc]])) stop(sprintf("%s: taxable_income: Spalte '%s' (Betrag) muss numerisch sein.", who, names(x)[vc]), call. = FALSE)
    x <- stats::setNames(as.numeric(x[[vc]]), as.character(x[[yc]]))
  }
  if (!is.numeric(x) || !length(x) || is.matrix(x))
    stop(sprintf("%s: taxable_income muss %s sein, nicht %s.", who, form, paste(utils::head(format(x), 3), collapse = ", ")), call. = FALSE)
  if (any(!is.finite(x))) {
    i <- which(!is.finite(x))[1]
    stop(sprintf("%s: taxable_income enth\u00e4lt einen ung\u00fcltigen Wert (%s%s); erwartet werden endliche Betr\u00e4ge in EUR.", who,
                 format(x[i]), if (!is.null(names(x))) sprintf(" f\u00fcr %s", names(x)[i]) else ""), call. = FALSE)
  }
  if (length(x) == 1L && is.null(names(x))) return(list(all = unname(as.numeric(x)), by_year = NULL))
  if (is.null(names(x)) || any(is.na(names(x)) | names(x) == ""))
    stop(sprintf("%s: taxable_income mit %d Werten muss nach Kalenderjahren benannt sein; erwartet wird %s.", who, length(x), form), call. = FALSE)
  yy <- suppressWarnings(as.integer(trimws(names(x))))
  if (anyNA(yy) || any(as.character(yy) != trimws(names(x))))
    stop(sprintf("%s: taxable_income: Name '%s' ist kein Kalenderjahr (erwartet z. B. \"2024\").", who,
                 names(x)[which(is.na(yy) | as.character(yy) != trimws(names(x)))[1]]), call. = FALSE)
  if (anyDuplicated(yy)) stop(sprintf("%s: taxable_income: Jahr %d kommt mehrfach vor.", who, yy[anyDuplicated(yy)]), call. = FALSE)
  miss <- setdiff(years, yy)
  if (length(miss))
    stop(sprintf("%s: taxable_income fehlt f\u00fcr %s %s (angegeben: %s); je Kalenderjahr der Simulation (%d bis %d) wird ein Betrag ben\u00f6tigt.", who,
                 if (length(miss) == 1L) "Simulationsjahr" else "Simulationsjahre", paste(miss, collapse = ", "),
                 paste(sort(yy), collapse = ", "), min(years), max(years)), call. = FALSE)
  list(all = NULL, by_year = stats::setNames(unname(as.numeric(x)), as.character(yy)))
}

#' zvE eines Jahres und Saldo des Kirchensteuer-Bescheids aus dem Vorjahr (Zahlung > 0, Erstattung < 0)
#' @param env Umgebung der Tarifrechnung (simulation()): tariff, zve_all bzw. zve (benannt nach
#'   Jahr), ks (KiSt-Saldo je Zahlungsjahr, benannt), church_k, kapest_rate, use_gp, rows, refund_due
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

#' Steuerzahlung aus dem Jahresabschluss vormerken (totals$p23_due, Zahlung am Abrechnungstag):
#' Aufteilung auf die Assets nach ihrem steuerpflichtigen § 23-Jahressaldo, sonst gleichmaessig
#' @keywords internal
#' @noRd
.book_tax_due <- function(input, tax_due) {
  by <- input[["totals"]][["private_sale_net_ytd_by"]]
  by <- if (length(by)) pmax(by[is.finite(by)], 0) else numeric(0)   # pmax(x, 0) behaelt die Namen
  if (!length(by) || sum(by) <= 0) by <- stats::setNames(rep(1, length(input[["status"]])), names(input[["status"]]))
  due <- tax_due * by / sum(by)
  old <- input[["totals"]][["p23_due"]]
  if (length(old)) { nm_all <- union(names(old), names(due)); s <- stats::setNames(numeric(length(nm_all)), nm_all)
    s[names(old)] <- old; s[names(due)] <- s[names(due)] + due; due <- s }
  input[["totals"]][["p23_due"]] <- due
  input
}

#' Saldo der Tarif-Veranlagung buchen: total_taxes, Nachzahlung (p23_due) bzw. Erstattung (env$refund_due);
#' Fliesskommarest |total_taxes| < 1e-9 nach einer Erstattung wird 0 (R5-05)
#' @keywords internal
#' @noRd
.tariff_book <- function(input, env, D) {
  if (is.na(D) || D == 0) return(input)
  input[["totals"]][["total_taxes"]] <- input[["totals"]][["total_taxes"]] + D
  if (D > 0) {
    # R9-02: Angaben fuer die details-Ausgabe der Zahlung (.settle_p23): Jahr, Bestandteile, Aufteilung
    rw <- env$rows[[length(env$rows)]]
    by <- input[["totals"]][["private_sale_net_ytd_by"]]
    by <- if (length(by)) pmax(by[is.finite(by)], 0) else numeric(0)
    env$due_info <- c(env$due_info, list(list(year = rw$year, D = D, p23 = rw$tax_p23, ded = rw$deduction_effect,
                                              by_p23 = length(by) > 0 && sum(by) > 0)))
    input <- .book_tax_due(input, D)
  } else {
    env$refund_due <- env$refund_due - D
    if (abs(input[["totals"]][["total_taxes"]]) < 1e-9) input[["totals"]][["total_taxes"]] <- 0
  }
  input
}

#--------> Hilfsfunktion zur Prüfung und Verarbeitung des Jahreswechsels:
#' Prueft und verarbeitet den Jahreswechsel fuer § 23 EStG und Sparer-Pauschbetrag
#'
#' Diese Funktion wird bei tax_mode = "person" an jedem Tag mit Jahreswechsel und
#' einmal nach dem letzten Simulationstag aufgerufen. Bei einem Jahreswechsel
#' werden folgende Schritte ausgefuehrt:
#'
#' 1. § 23 EStG: Freigrenze pruefen und ggf. Steuer berechnen
#' 2. § 23-Nettoverluste ins naechste Jahr vortragen
#' 3. § 20 EStG: Erstattung aus unterjaehriger Verlustverrechnung (T-2), danach
#'    Freigabe des genutzten Sparer-Pauschbetrags durch verbleibende Verluste
#' 4. Sparer-Pauschbetrag und Jahres-Tracker fuer das neue Jahr zuruecksetzen
#'
#' @param input Liste. Die sim_mem-Struktur mit allen Simulationsdaten
#' @param current_date Date. Das aktuelle Datum der Simulation
#' @param marginal_tax_rate Zahl oder NULL. Persoenlicher Grenzsteuersatz als Anteil
#'   (intern bereits durch 100 geteilt, z. B. 0.42); NULL = 0.42 mit Warnung
#' @param private_sale_threshold Zahl. Freigrenze nach § 23 EStG in EUR (Standard im Aufrufer: 1000)
#' @param sparer_pauschbetrag Zahl. Jaehrlicher Sparer-Pauschbetrag in EUR (Standard im Aufrufer: 1000)
#' @param use_sparer_pauschbetrag Logisch. Soll der Sparer-Pauschbetrag angewendet werden?
#' @param soli_factor_income Zahl. Faktor auf die Einkommensteuer: 1 + Soli-Satz (als Anteil) oder 1
#' @param effective_tax_rate Zahl oder NULL. Effektiver Steuersatz als Anteil fuer die § 20-Erstattung
#' @param details Logisch. Sollen Details ausgegeben werden?
#' @param church_factor Zahl. Kirchensteuersatz als Anteil der Einkommensteuer (church_tax / 100, sonst 0)
#' @param tariff_env Umgebung oder NULL. Tarifrechnung (income_tariff()): Tarif, zvE je
#'   Jahr, Kirchensteuer-Sonderausgaben, Jahreszeilen und faellige Erstattung (siehe .tariff_close());
#'   NULL = bisheriger Weg mit marginal_tax_rate
#'
#' @return Liste. Die aktualisierte sim_mem-Struktur. Eine § 23-Steuer wird in total_taxes gebucht
#'   und als totals$p23_due (je Asset) zur Zahlung aus dem Depot vorgemerkt (simulation(): am
#'   Abrechnungstag der Vorabpauschale, d. h. erster Handelstag des Folgejahres, sonst letzter Tag).
#'
#' @details
#' Freigrenze nach § 23 Abs. 3 EStG auf den Jahressaldo s (Gewinne - Verluste des Jahres):
#' - s >= Freigrenze: steuerpflichtig s - min(s, Verlustvortrag), Vortrag entsprechend
#'   mindern (auch wenn der Rest unter der Freigrenze liegt; BFH IX R 27/04)
#' - 0 <= s < Freigrenze: steuerfrei, Verlustvortrag unveraendert
#' - s < 0: Vortrag ins naechste Jahr (nur mit anderen § 23-Gewinnen verrechenbar)
#'
#' Sparer-Pauschbetrag (§ 20 Abs. 9 Satz 4, § 43a Abs. 3 EStG): Ein Verlust erstattet
#' zuerst die Steuer auf versteuerte Ertraege des Jahres, der Rest gibt genutzten
#' Pauschbetrag frei, erst danach bleibt er im Verlusttopf. Genutzt bleibt damit
#' min(Pauschbetrag, max(0, Jahressaldo nach Verlustverrechnung)).
#'
#' Invariante je Jahr (Verlusttopf vor Pauschbetrag wie bei Banken; Ertraege E einschliesslich
#' Vorabpauschale des Zuflussjahres, Verluste L des Jahres, Vortrag V zu Jahresbeginn):
#' genutzter Vortrag = min(V, max(0, E - L)), genutzter Pauschbetrag = min(Pauschbetrag, Rest),
#' versteuert = max(0, E - L - genutzter Vortrag - genutzter Pauschbetrag).
#'
#' @keywords internal
#' @noRd
.handle_year_change <- function(input, current_date, marginal_tax_rate, 
                               private_sale_threshold, sparer_pauschbetrag,
                               use_sparer_pauschbetrag, soli_factor_income = 1.0,
                               effective_tax_rate = NULL,
                               details, church_factor = 0, tariff_env = NULL) {
  
  current_year <- as.integer(format(current_date, "%Y"))
  stored_year <- input[["totals"]][["current_year"]]
  
 # Kein Jahreswechsel -> nichts zu tun
  if (current_year == stored_year) {
    return(input)
  }
  
  # === JAHRESWECHSEL ERKANNT ===
  
  if (details) {
    cat(sprintf("\n\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n"))
    cat(sprintf("  JAHRESWECHSEL: %d -> %d\n", stored_year, current_year))
    cat(sprintf("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n"))
  }
  
  # ------------------------------------------------------------------
  # 1. § 23 EStG Jahresabrechnung
  # ------------------------------------------------------------------
  
  ytd_gains <- input[["totals"]][["private_sale_gains_ytd"]]
  ytd_losses <- input[["totals"]][["private_sale_losses_ytd"]]
  
  # ══════════════════════════════════════════════════════════════════════
  # § 23 Abs. 3 Satz 5, 7-8 EStG: Freigrenze auf den Jahressaldo, Verlustvortrag
  # nur, wenn die Freigrenze erreicht ist (BFH IX R 27/04)
  # ══════════════════════════════════════════════════════════════════════
  # s < 0: Vortrag; 0 <= s < Freigrenze: steuerfrei, Vortrag unveraendert;
  # s >= Freigrenze: steuerpflichtig s - min(s, Vortrag) (auch wenn das Ergebnis
  # danach unter der Freigrenze liegt), Vortrag entsprechend mindern.
  net_saldo <- ytd_gains - ytd_losses
  internal_offset <- min(ytd_gains, ytd_losses)
  net_ytd_losses <- max(0, -net_saldo)
  carryforward_offset <- 0
  net_gain <- 0
  if (net_saldo >= private_sale_threshold && net_saldo > 0) {
    carryforward_offset <- min(net_saldo, input[["totals"]][["loss_private_sales"]])
    input[["totals"]][["loss_private_sales"]] <- input[["totals"]][["loss_private_sales"]] - carryforward_offset
    net_gain <- net_saldo - carryforward_offset
    if (details && carryforward_offset > 0) {
      cat(sprintf("  \u00a7 23 EStG: Verlustvortrag verwendet: %.2f EUR\n", carryforward_offset))
      cat(sprintf("             Verbleibender Vortrag: %.2f EUR\n", 
                  input[["totals"]][["loss_private_sales"]]))
    }
  }
  
  # ══════════════════════════════════════════════════════════════════════
  
  if (details) {
    cat(sprintf("  \u00a7 23 EStG Jahres\u00fcbersicht %d:\n", stored_year))
    cat(sprintf("    Bruttogewinne (< 1 Jahr):    %10.2f EUR\n", ytd_gains))
    cat(sprintf("    Bruttoverluste (< 1 Jahr):   %10.2f EUR\n", ytd_losses))
    cat(sprintf("    Interne Verrechnung:         %10.2f EUR\n", internal_offset))
    cat(sprintf("    Verlustvortrag-Verrechnung:  %10.2f EUR\n", carryforward_offset))
    cat(sprintf("    \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n"))
    cat(sprintf("    Netto-Ergebnis:              %10.2f EUR\n", net_saldo - carryforward_offset))
  }
  
  if (net_gain > 0) {
    # ------------------------------------------------------------------
    # FALL A: Freigrenze ERREICHT -> Gewinn (nach Verlustvortrag) steuerpflichtig
    # ------------------------------------------------------------------
    
    if (is.null(tariff_env)) {   # Tarifweg: Veranlagung des ganzen Jahres unten (2c, .tariff_close)
    if (is.null(marginal_tax_rate)) {
      warning(
        sprintf("simulation: Paragraf 23 EStG: Gewinne (%.2f EUR) erreichen die Freigrenze (%.2f EUR), ",
                net_saldo, private_sale_threshold),   # R9-03: Betraege wie im Engine-Druck (%.2f)
        "aber 'marginal_tax_rate' ist nicht gesetzt.\n",
        "Verwendet wird 42 % (Spitzensteuersatz); marginal_tax_rate in Prozent angeben (z. B. 42).",
        call. = FALSE
      )
      marginal_tax_rate <- 0.42
    }
    
    # Steuerberechnung: ESt x (1 + Soli-Satz + Kirchensteuersatz); KiSt = church_tax Prozent der ESt
    # (ohne Sonderausgabenabzug der KiSt bei der ESt)
    tax_due <- net_gain * marginal_tax_rate * (soli_factor_income + church_factor)
    input[["totals"]][["total_taxes"]] <- input[["totals"]][["total_taxes"]] + tax_due
    # R3a-02: Zahlung aus dem Depot am Abrechnungstag (erster Handelstag des Folgejahres wie die VP,
    # sonst 1.1. bzw. letzter Tag); Aufteilung auf die Assets nach ihrem steuerpflichtigen Jahressaldo
    input <- .book_tax_due(input, tax_due)
    }

    if (details) {
      cat(sprintf("\n  \u26a0 FREIGRENZE ERREICHT!\n"))
      cat(sprintf("    Jahressaldo %.2f EUR >= Freigrenze %.2f EUR\n",
                  net_saldo, private_sale_threshold))
      cat(sprintf("    \u2192 GESAMTER Gewinn nach Verlustvortrag steuerpflichtig: %.2f EUR (Freigrenze, kein Freibetrag!)\n", net_gain))
      if (!is.null(tariff_env)) {
        # Tarifweg: die Steuer (ESt + Soli + KiSt des Paragraf-23-Zuwachses) steht erst in der Veranlagung
        # des Jahres fest (2c, .tariff_close: Sonderausgaben, Guenstigerpruefung) und wird dort ausgegeben
        cat("    \u2192 Steuer nach dem Einkommensteuertarif (ESt + Soli + KiSt des \u00a7 23-Zuwachses): siehe Jahresveranlagung unten (Zeile \u00a7 23)\n")
      } else {
      cat(sprintf("    \u2192 Steuersatz: %.1f%%%s%s\n", marginal_tax_rate * 100, if (soli_factor_income > 1) sprintf(" + %.1f%%%% Soli", (soli_factor_income - 1) * 100) else "",
                  if (church_factor > 0) sprintf(" + %.1f%% KiSt", church_factor * 100) else ""))
      cat(sprintf("    \u2192 Steuerlast: %.2f EUR\n", tax_due))
      }
    }
    
  } else if (net_ytd_losses > 0) {
    # ------------------------------------------------------------------
    # FALL B: Netto-VERLUST -> Vortrag ins nächste Jahr
    # ------------------------------------------------------------------
    
    input[["totals"]][["loss_private_sales"]] <- 
      input[["totals"]][["loss_private_sales"]] + net_ytd_losses
    
    if (details) {
      cat(sprintf("\n  Nettoverlust %.2f EUR \u2192 Vortrag ins n\u00e4chste Jahr\n", net_ytd_losses))
      cat(sprintf("  Gesamter Verlustvortrag: %.2f EUR\n", 
                  input[["totals"]][["loss_private_sales"]]))
    }
    
  } else if (net_saldo > 0 && net_saldo < private_sale_threshold) {
    # ------------------------------------------------------------------
    # FALL C: Gewinn UNTER der Freigrenze -> Steuerfrei, Vortrag unveraendert
    # ------------------------------------------------------------------
    
    if (details) {
      cat(sprintf("\n  \u2713 Jahressaldo %.2f EUR < Freigrenze %.2f EUR \u2192 STEUERFREI (Verlustvortrag unver\u00e4ndert)\n", 
                  net_saldo, private_sale_threshold))
    }
    
  } else {
    if (details) {
      cat(sprintf("\n  Keine steuerpflichtigen \u00a7 23 Vorg\u00e4nge in %d\n", stored_year))
    }
  }
  
  # ------------------------------------------------------------------
  # 2. Sparerpauschbetrag-Zusammenfassung
  # ------------------------------------------------------------------
  
  if (details && use_sparer_pauschbetrag) {
    spb_annual <- input[["totals"]][["sparer_pauschbetrag_annual"]]
    spb_remaining <- input[["totals"]][["sparer_pauschbetrag_remaining"]]
    spb_used_this_year <- spb_annual - spb_remaining
    
    cat(sprintf("\n  Sparerpauschbetrag %d:\n", stored_year))
    cat(sprintf("    Jahresbetrag:    %10.2f EUR\n", spb_annual))
    cat(sprintf("    Verwendet:       %10.2f EUR\n", spb_used_this_year))
    cat(sprintf("    Verfallen:       %10.2f EUR\n", spb_remaining))
  }
  
  # ------------------------------------------------------------------
  # 2b. § 20 EStG: Unterjaehrige Verlustverrechnung (T-2)
  # ------------------------------------------------------------------
  # Trade-Besteuerung bleibt bestehen. Spaetere Verluste, die frueher im Jahr
  # versteuerte Gewinne uebersteigen, werden als Steuererstattung in den
  # Geldbestand zurueckgefuehrt (analog unterjaehriger Bank-Verlustverrechnung).
  cgt_loss_added <- input[["totals"]][["cgt_loss_added_ytd"]] %||% 0
  cgt_loss_used  <- input[["totals"]][["cgt_loss_used_ytd"]]  %||% 0
  cgt_base_taxed <- input[["totals"]][["cgt_base_taxed_ytd"]] %||% 0
  # Verlustvortrag aus dem Vorjahr (Topf zu Jahresbeginn): Seine Nutzung bleibt bestehen,
  # soweit der Jahressaldo reicht: genutzter Vortrag = min(Vortrag, max(0, Ertraege - Verluste)).
  # Nur die darueber hinausgehende Topfnutzung entfaellt auf Verluste des Jahres; vorher
  # minderte auch die Vortragsnutzung die Erstattung (Vortrag 1000, Gewinn 3000, Verlust 500:
  # Erstattung 0 statt Steuer auf 500). Ertraege des Jahres (auch VP) = Topf + SPB + versteuert.
  carry_start <- input[["totals"]][["cgt_pool_start_ytd"]] %||% 0
  carry_used <- 0
  if (carry_start > 0) {
    spb_used_ytd <- if (use_sparer_pauschbetrag) max(0, input[["totals"]][["sparer_pauschbetrag_annual"]] -
                                                        input[["totals"]][["sparer_pauschbetrag_remaining"]]) else 0
    carry_used <- min(carry_start, max(0, cgt_loss_used + spb_used_ytd + cgt_base_taxed - cgt_loss_added))
  }
  unused_loss <- max(0, cgt_loss_added - (cgt_loss_used - carry_used))
  unused_loss <- min(unused_loss, input[["totals"]][["loss_capital_gains"]])
  refund_base <- min(unused_loss, cgt_base_taxed)
  refund_done <- refund_base > 0 && !is.null(effective_tax_rate) && effective_tax_rate > 0
  if (refund_done) {
    refund <- refund_base * effective_tax_rate
    asset_names <- names(input[["status"]])
    w <- vapply(asset_names, function(nm) input[["status"]][[nm]][["actual"]] %||% 0, numeric(1))
    w <- if (sum(w) > 0) w / sum(w) else rep(1 / length(asset_names), length(asset_names))
    for (nm in asset_names) {
      input[["status"]][[nm]][["money"]] <- input[["status"]][[nm]][["money"]] + refund * w[[nm]]
    }
    input[["totals"]][["total_taxes"]] <- input[["totals"]][["total_taxes"]] - refund
    input[["totals"]][["loss_capital_gains"]] <- input[["totals"]][["loss_capital_gains"]] - refund_base
    if (details) {
      cat(sprintf("  \u00a7 20 EStG: Unterj\u00e4hrige Verlustverrechnung -> Erstattung %.2f EUR in den Geldbestand\n", refund))
    }
  }
  # § 20 Abs. 9 Satz 4, § 43a Abs. 3 EStG: Ein Verlust, der nach Erstattung der versteuerten
  # Ertraege des Jahres verbleibt, gibt den genutzten Sparer-Pauschbetrag frei, erst der Rest
  # geht in den Verlusttopf. Invariante: genutzter Pauschbetrag = min(Pauschbetrag,
  # max(0, Jahressaldo nach Verlustverrechnung)); Jahressaldo = versteuert + Pauschbetrag - Topf.
  if (use_sparer_pauschbetrag) {
    spb_used_year <- max(0, input[["totals"]][["sparer_pauschbetrag_annual"]] -
                            input[["totals"]][["sparer_pauschbetrag_remaining"]])
    taxed_left <- cgt_base_taxed - if (refund_done) refund_base else 0
    release <- max(0, min(spb_used_year, input[["totals"]][["loss_capital_gains"]] - taxed_left))
    if (release > 0) {
      input[["totals"]][["loss_capital_gains"]] <- input[["totals"]][["loss_capital_gains"]] - release
      input[["totals"]][["sparer_pauschbetrag_remaining"]] <- input[["totals"]][["sparer_pauschbetrag_remaining"]] + release
      input[["totals"]][["sparer_pauschbetrag_used_total"]] <- input[["totals"]][["sparer_pauschbetrag_used_total"]] - release
      if (details) {
        cat(sprintf("  \u00a7 20 EStG: Verlust gibt Sparer-Pauschbetrag frei: %.2f EUR (genutzt %d: %.2f EUR, Verlusttopf %.2f EUR)\n",
                    release, stored_year, spb_used_year - release, input[["totals"]][["loss_capital_gains"]]))
      }
    }
  }

  # ------------------------------------------------------------------
  # 2c. Tarifweg (taxable_income): Jahreszeile, Guenstigerpruefung (§ 32d Abs. 6 EStG)
  # ------------------------------------------------------------------
  # K = per Saldo mit Abgeltungsteuer belastete Bemessungsgrundlage des Jahres (nach TFS, VP,
  # Verlustverrechnung, Sparer-Pauschbetrag, Erstattung T-2); die Erstattung wird in
  # tariff_env$refund_due vorgemerkt und am Abrechnungstag dem Cash gutgeschrieben
  any_refund <- refund_done
  if (!is.null(tariff_env)) {
    k_base <- max(0, cgt_base_taxed - if (refund_done) refund_base else 0)
    D <- .tariff_close(tariff_env, stored_year, net_gain, k_base, effective_tax_rate %||% 0, details)
    input <- .tariff_book(input, tariff_env, D)
    if (isTRUE(D < 0)) any_refund <- TRUE
  }
  # R5-05: Fliesskommarest des Steuer-Saldos nach Erstattungen (T-2, Guenstigerpruefung), z. B. 8.5e-14
  # bei vollstaendiger Erstattung: |Saldo| < 1e-9 EUR wird 0
  if (any_refund && abs(input[["totals"]][["total_taxes"]]) < 1e-9) input[["totals"]][["total_taxes"]] <- 0

  # ------------------------------------------------------------------
  # 3. Reset für neues Jahr
  # ------------------------------------------------------------------
  
  input[["totals"]][["private_sale_gains_ytd"]] <- 0
  input[["totals"]][["private_sale_losses_ytd"]] <- 0
  if (length(input[["totals"]][["private_sale_net_ytd_by"]]))
    input[["totals"]][["private_sale_net_ytd_by"]][] <- 0
  input[["totals"]][["cgt_base_taxed_ytd"]] <- 0
  input[["totals"]][["cgt_loss_added_ytd"]] <- 0
  input[["totals"]][["cgt_loss_used_ytd"]] <- 0
  input[["totals"]][["cgt_pool_start_ytd"]] <- input[["totals"]][["loss_capital_gains"]]
  
  if (use_sparer_pauschbetrag) {
    input[["totals"]][["sparer_pauschbetrag_remaining"]] <- sparer_pauschbetrag
  }
  
  input[["totals"]][["current_year"]] <- current_year
  
  if (details) {
    cat(sprintf("\n  Tracker zur\u00fcckgesetzt f\u00fcr Jahr %d\n", current_year))
    cat(sprintf("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n\n"))
  }
  
  return(input)
}



#--------> Hilfsfunktion zur Berechnung des FIFO-Grenzindex:
.update_fifo_front <- function(trades, front_index){
  while(front_index <= length(trades)){
    buy <- trades[[front_index]]

    if(is.null(buy) || length(buy) == 0){
      break
    }

    if(buy[["remaining"]] > 0){
      return(front_index)
    }

    front_index <- front_index + 1
  }

  return(front_index)
}

#--------> Hilfsfunktion zur Berechnung der Vorabpauschale:
#' Berechnet die Vorabpauschale nach § 18 InvStG
#'
#' @details
#' Der Basiszins steht in Prozent in market$base_rates und wird hier durch 100 geteilt.
#' Massgeblich ist der Wert vom ersten Handelstag des Bewertungsjahres (§ 18 Abs. 4
#' InvStG; bei zeitvariabler Basiszins-Spalte relevant), nicht der vom 31.12.
#' Bei negativem Basiszins ist die Vorabpauschale = 0.
#' Der Basiszins wird vom BMF jaehrlich veroeffentlicht und kann negativ sein
#' (z. B. 2021: -0,45 %, 2022: -0,05 %).
#'
#' Je am 31.12. gehaltenem Lot (§ 18 Abs. 1-2 InvStG, keine Ausschuettungen im Modell):
#' VP = Bestand x max(0, min(P_Anfang x 0,7 x Basiszins, P_Ende - P_Anfang)) x f mit
#' P_Anfang = erster im Jahr festgesetzter Kurs (erster nicht aufgefuellter Tag des Jahres bzw. der
#' Simulation, § 18 Abs. 1 Satz 3 InvStG; A7-01), P_Ende = Kurs am 31.12.,
#' f = 1 bei Erwerb vor dem Jahr, sonst (13 - Erwerbsmonat) / 12.
#'
#' @param filled Logischer Vektor (wie dates) oder NULL: TRUE = aufgefuellter Tag (kein Handelstag)
#' @noRd
.calculate_flat_rate <- function(input, name, index, dates, tax_regime = NULL, filled = NULL) {
  # P6: tax_regime wird vom Aufrufer übergeben (Lookup-Vektor)
  # Vorabpauschale nur für investment_fund
  if (is.null(tax_regime)) tax_regime <- input[["assets"]][[name]][["tax_regime"]]
  
  # Einheitliches Rückgabeformat für alle Early-Returns
  empty_result <- list(total_vp = 0, lot_indices = integer(0), lot_vps = numeric(0))
  
  if (tax_regime != "investment_fund") {
    return(empty_result)
  }
  
  date_index <- dates[index]
  
  # P5: format()-Guard entfernt – Aufrufer garantiert 31.12. via flag_taxes
  
  start_of_year <- as.Date(paste0(format(date_index, "%Y"), "-01-01"))
  end_of_year <- as.Date(paste0(format(date_index, "%Y"), "-12-31"))
  
  # ══════════════════════════════════════════════════════════════════════
  # M1 KORREKTUR: Basiszins auf mindestens 0 begrenzen
  # ══════════════════════════════════════════════════════════════════════
  # P2: Arithmetischer Index statt which()-Scan (O(1) statt O(n))
  year_start_index <- max(1L, as.integer(start_of_year - dates[1]) + 1L)

  # § 18 Abs. 4 InvStG: Basiszins vom ersten Handelstag des Bewertungsjahres
  rate_index <- year_start_index
  if (!is.null(filled)) {
    while (rate_index < index && isTRUE(filled[rate_index])) rate_index <- rate_index + 1L
    if (isTRUE(filled[rate_index])) rate_index <- year_start_index   # kein Handelstag im Jahr
  }
  # A7-01: Bezugskurs = erster im Kalenderjahr festgesetzter Ruecknahmepreis (§ 18 Abs. 1 Satz 3 InvStG),
  # d. h. Kurs des ersten nicht aufgefuellten Tages des Jahres (bisher: aufgefuellter 1.1. = Vorjahresschluss);
  # gilt fuer Basisertrag und Deckel. Mit echtem Kurs am 1.1. unveraendert
  year_start_price <- input[["market"]][[name]][["asset_price"]][rate_index]
  raw_base_rate <- input[["market"]][[name]][["base_rates"]][rate_index] / 100
  base_rate <- max(0, raw_base_rate)
  
  if (base_rate <= 0) {
    return(empty_result)
  }
  # ══════════════════════════════════════════════════════════════════════
  
  market_price <- input[["market"]][[name]][["asset_price"]][index]
  
  # ══════════════════════════════════════════════════════════════════════
  # M4: Nur Lots die am Jahresende noch gehalten werden
  # ══════════════════════════════════════════════════════════════════════
  # C++-Port des Lot-Loops (tax_core.cpp): M4/T-1/Growth-Cap,
  # Datumsvergleiche als Integer (frueher geplante Option A inklusive)
  res <- .sim_flat_rate_cpp(
    input[["trades"]][[name]][["buys"]],
    as.integer(input[["trades"]][[name]][["fifo_front"]]),
    base_rate, year_start_price, market_price,
    as.integer(start_of_year), as.integer(end_of_year))
  return(res)
}



#--------> Hilfsfunktion zur Berechnung der Fongsgebühren:
.calculate_fund_fees <- function(input, index, dates, assets, funds_fee, bonus_fee, details){
  # Abrechnungszeitraum: 1.1. des laufenden Jahres (bzw. Simulationsbeginn) bis heute
  event_date <- as.Date(paste0(format(dates[index], "%Y"), "-01-01"))
  dates_index <- which(dates >= event_date & dates <= dates[index])
  zero <- setNames(numeric(length(assets)), assets)

  if(length(dates_index) == 0){
    return(list(total_fees = 0, total_value = input[["totals"]][["total_value"]], asset_fees = zero))
  }

  asset_totals <- matrix(sapply(assets, function(x) input[["report"]][[x]][["total"]][dates_index]),
                         nrow = length(dates_index), dimnames = list(NULL, assets))

  # Tagessatz linear bezogen auf die Kalendertage des JAHRES (nicht des Zeitraums):
  # ein volles Jahr kostet genau funds_fee Prozent, ein Rumpfjahr (Start/Ende
  # unterjaehrig) traegt nur anteilige Kosten
  yr <- as.integer(format(dates[index], "%Y"))
  days_in_year <- if (yr %% 4 == 0 && (yr %% 100 != 0 || yr %% 400 == 0)) 366 else 365
  daily_rate <- funds_fee / 100 / days_in_year
  basic_fees <- colSums(asset_totals * daily_rate, na.rm = TRUE)
  basic_value <- sum(basic_fees)

  # Hoechststand (High-Watermark) um Einzahlungen im Zeitraum erhoehen (R1-03):
  # Sparraten sind kein Wertzuwachs
  flows_period <- sum(vapply(assets, function(x) sum(input[["report"]][[x]][["flows"]][dates_index]), numeric(1)))
  total_value <- input[["totals"]][["total_value"]] + flows_period
  status_totals <- vapply(assets, function(x) input[["status"]][[x]][["total"]], numeric(1))
  market_value <- sum(status_totals, na.rm = TRUE)

  above_mark <- market_value > total_value
  bonus_value <- if (above_mark) (market_value - total_value) * (bonus_fee / 100) else 0

  # Verteilung: Grundkosten je Asset nach dessen abgegrenztem Wert, Performancegebuehr nach Ist-Gewicht
  asset_fees <- basic_fees + if (market_value > 0) bonus_value * status_totals / market_value else 0
  total_fees <- basic_value + bonus_value

  # Hoechststand als Wert NACH Abzug der Gebuehren (die Marke sinkt nie)
  if (above_mark) total_value <- max(total_value, market_value - total_fees)

  if(details){
    cat(sprintf("Fondskosten:\tFondsgeb\u00fchren %.2f EUR am %s\n\t\t=> Grundgeb\u00fchr: %.2f EUR; Performancegeb\u00fchr: %.2f EUR\n", total_fees, dates[index], basic_value, bonus_value))
  }

  return(list(total_fees = total_fees, total_value = total_value, asset_fees = asset_fees))
}


#--------> Hilfsfunktion zur Berechnung zu verkaufender Anteile:
#' Berechnet die Anzahl zu verkaufender Anteile fuer einen Ziel-Nettoerloes
#'
#' Verwendet vorberechnete kumulative FIFO-Daten und eine Bisektionssuche
#' fuer schnelle Konvergenz.
#'
#' @param input Liste. Die sim_mem-Struktur
#' @param name Zeichenkette. Asset-Name
#' @param target Zahl. Ziel-Nettoerloes nach Steuern in EUR
#' @param index Ganzzahl. Aktueller Zeitindex
#' @param spread Zahl. Voller Bid-Ask-Spread als Anteil (intern bereits durch 100 geteilt, z. B. 0.001 = 0,1 %)
#' @param fractions Logisch. Bruchteile erlaubt?
#' @param tax_mode Zeichenkette. Steuermodus
#' @param tax_rate Zahl. Steuersatz als Anteil (Aufrufer: effektiver Satz nach Guenstigerpruefung)
#' @param marginal_tax_rate Zahl. Persoenlicher Grenzsteuersatz als Anteil (fuer § 23)
#' @param tax_regime Zeichenkette oder NULL. Steuerregime des Assets (NULL = aus sim_mem)
#'
#' @details Die geschaetzte Steuer folgt dem Verkauf (.calculate_paragraph_20_tax): Gewinn nach
#'   § 19-Anrechnung der Lot-VP, Teilfreistellung, freier Verlusttopf, freier Sparer-Pauschbetrag.
#'   § 23-Gewinne werden erst am Jahresende besteuert (Schaetzung 0).
#' @return Liste mit sell_count und fifo_price
#' @keywords internal
#' @noRd
.calculate_sell_count <- function(input, name, target, index, spread, fractions, 
                                            tax_mode, tax_rate, marginal_tax_rate = NULL,
                                            tax_regime = NULL) {
  
  # KORREKTUR K1: market_price aus input auslesen
  market_price <- input[["market"]][[name]][["asset_price"]][index]
  trade_price <- .apply_spread(market_price, spread, "sell")
  total_shares <- input[["status"]][[name]][["count"]]

  # Early returns

  if (total_shares <= 0) {
    return(list(sell_count = 0, fifo_price = 0))
  }
  if (target <= 0) {
    return(list(sell_count = 0, fifo_price = 0))
  }
  
  # ═══════════════════════════════════════════════════════════════════
  # OPTIMIERUNG P4: FIFO-Daten einmal vorab extrahieren
  # ═══════════════════════════════════════════════════════════════════
  
  trades <- input[["trades"]][[name]][["buys"]]
  front_index <- input[["trades"]][[name]][["fifo_front"]]
  
  # C++-Port (tax_core.cpp): Extraktion + kum. FIFO + Bisektion in C++
  if (is.null(tax_regime)) tax_regime <- input[["assets"]][[name]][["tax_regime"]]
  tax_regime <- if (tax_mode == "person") tax_regime else "none"
  bonus <- if (tax_regime == "investment_fund") input[["assets"]][[name]][["bonus"]] else 0
  # R3a-04: wie .calculate_paragraph_20_tax erst Verlusttopf, dann freier Sparer-Pauschbetrag
  # (ohne Pauschbetrag ist der Rest 0); die § 19-Anrechnung der Lot-VP rechnet .sim_sell_count_cpp
  loss_pool <- input[["totals"]][["loss_capital_gains"]] +
    max(0, input[["totals"]][["sparer_pauschbetrag_remaining"]] %||% 0)
  regime_code <- switch(tax_regime, none = 0L, investment_fund = 1L,
                        capital_gains = 2L, private_sale = 3L, 0L)
  res <- .sim_sell_count_cpp(trades, as.integer(front_index), target, trade_price,
                         total_shares, isTRUE(fractions), regime_code,
                         bonus, loss_pool, tax_rate)
  return(res)
}


#--------> Hilfsfunktion: geldgewichtete Jahresrendite (interner Zinsfuss, XIRR):
#' Interner Zinsfuss p. a. aus datierten Einzahlungen und Endwert
#'
#' Loest \eqn{\sum_j a_j (1 + r)^{T - t_j} = V} (Einzahlungen \eqn{a_j} zu den Zeitpunkten
#' \eqn{t_j} in Jahren ab Start, Kalendertage / 365.25 wie die CAGR, Endwert \eqn{V} bei \eqn{T}).
#' Nur mit dem Startwert bei \eqn{t = 0} ist die Loesung \eqn{(V / a_1)^{1/T} - 1}, die CAGR.
#' Brent-Verfahren (stats::uniroot) in \eqn{u = T \log(1 + r)}; die Klammer wird auf einem Raster
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
  keep <- is.finite(amount) & amount != 0
  t <- t[keep]; amount <- amount[keep]
  if (!length(amount) || !isTRUE(horizon > 0) || !is.finite(end_value)) return(NA_real_)
  if (end_value == 0 && all(amount >= 0)) return(-1)
  e <- (horizon - t) / horizon                     # Restlaufzeit als Anteil an T (0..1)
  g <- function(u) sum(amount * exp(u * e)) - end_value
  grid <- seq(-200, 200, by = 5)
  gv <- vapply(grid, g, numeric(1))
  k <- which(gv[-1] * gv[-length(gv)] <= 0)[1]
  if (!is.na(k)) {
    br <- grid[k + 0:1]; fb <- gv[k + 0:1]
  } else {
    # R3B-01: Beinahe-Totalverlust: Nullstelle unter u = -200; untere Grenze verdoppeln, bis
    # g das Vorzeichen wechselt oder exp(u * e) fuer alle e > 0 unterlaeuft (dann keine Nullstelle)
    if (!(gv[1] > 0) || !any(e > 0)) return(NA_real_)
    lo_lim <- -800 / min(e[e > 0])
    hi <- grid[1]; ghi <- gv[1]; lo <- hi; glo <- ghi
    while (glo > 0 && lo > lo_lim) { hi <- lo; ghi <- glo; lo <- max(2 * lo, lo_lim); glo <- g(lo) }
    if (glo > 0) return(NA_real_)
    br <- c(lo, hi); fb <- c(glo, ghi)
  }
  u <- stats::uniroot(g, br, f.lower = fb[1], f.upper = fb[2],
                      tol = 1e-14, maxiter = 1000)$root
  expm1(u / horizon)
}

#--------> Hilfsfunktion zur Berechnung von Partial Moments:
calculate_partials <- function(returns, exp = 1, type = c("lower", "higher")){
  if(type == "lower"){
    mean(pmax(0, -returns)^exp, na.rm = TRUE)
  } else {
    mean(pmax(0, returns)^exp, na.rm = TRUE)
  }
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
  sd_x <- sd(x)

  if(sd_x == 0){
    return(NA)
  }

  skew <- (n / ((n - 1) * (n - 2))) * sum((x - mean_x)^3) / (sd_x^3)

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
  sd_x <- sd(x)

  if(sd_x == 0){
    return(NA)
  }

  kurt <- (n * (n + 1)) / ((n - 1) * (n - 2) * (n - 3)) * 
          sum((x - mean_x)^4) / (sd_x^4)

  if(excess){
    kurt <- kurt - (3 * (n - 1)^2) / ((n - 2) * (n - 3))
  }

  return(kurt)
}

#--------> Hilfsfunktion für Forward Asset-Splits:
#' Forward Asset Split (Aktiensplit)
#'
#' Fuehrt einen Forward-Split durch, bei dem die Anzahl der Anteile erhoeht
#' und der Preis pro Anteil entsprechend reduziert wird.
#'
#' @param input Liste. Die sim_mem Struktur
#' @param name Zeichenkette. Name des Assets
#' @param ratio Zahl. Split-Verhaeltnis (z.B. 4 fuer 1:4 Split)
#' @param index Ganzzahl. Aktueller Zeitindex
#' @param fractions Logisch. Ohne Wirkung (Bruchteile verkauft simulation() nach dem Split).
#'
#' @return Liste. Die aktualisierte sim_mem Struktur
#'
#' @details
#' Bei einem 1:4 Split wird:
#' - Anzahl Anteile x 4
#' - Preis pro Anteil / 4
#' - Gesamtwert bleibt gleich
#'
#' Bestand und Lots werden exakt umgerechnet. Bei fractions = FALSE verkauft
#' simulation() entstehende Bruchteile anschliessend zum Kurs des Split-Tages
#' (Spitzenausgleich, steuerlich ein Verkauf).
#'
#' @examples
#' # 1:4 Split von Asset "AAPL"
#' sim_mem <- .forward_asset_split(sim_mem, "AAPL", ratio = 4, index = 100, fractions = TRUE)
#'
#' @keywords internal
#' @noRd
.forward_asset_split <- function(input, name, ratio, index, fractions) {
  

  # Aktuelle Werte auslesen
  # input[["status"]][[name]][["count"]] = count (Anzahl Anteile)
  # input[["status"]][[name]][["price"]] = price (Durchschnittspreis)
  # input[["status"]][[name]][["worth"]] = worth (Gesamtwert)
  # input[["status"]][[name]][["money"]] = money (Cash)
  
  current_count <- input[["status"]][[name]][["count"]]
  current_price <- input[["status"]][[name]][["price"]]
  current_worth <- input[["status"]][[name]][["worth"]]
  
  # Neue Werte nach Split berechnen
  split_count <- current_count * ratio
  split_price <- current_price / ratio
  split_worth <- current_worth  # Gesamtwert ändert sich nicht!
  
  # R1-05: Bestand und Lots werden exakt umgerechnet; Bruchteile (fractions = FALSE)
  # verkauft simulation() danach als Spitzenausgleich zum Kurs des Split-Tages.
  
  # FIFO-Lots aktualisieren (nur populierte Lots, nicht vorallokierte)
  n_lots <- input[["trades"]][[name]][["buy_count"]]
  if (n_lots > 0) {
    input[["trades"]][[name]][["buys"]][1:n_lots] <- lapply(input[["trades"]][[name]][["buys"]][1:n_lots], function(buy) {
      if (is.null(buy) || length(buy) == 0 || buy[["remaining"]] <= 0) {
        return(buy)
      }
      
      new_original_count <- buy[["count"]] * ratio
      new_buy_price <- buy[["price"]] / ratio
      new_remaining <- buy[["remaining"]] * ratio
      new_original <- (buy[["original"]] %||% buy[["remaining"]]) * ratio
      
      buy[["count"]] <- new_original_count
      buy[["price"]] <- new_buy_price
      buy[["remaining"]] <- new_remaining
      buy[["original"]] <- new_original
      
      return(buy)
    })
  }
  
  # FIFO-Front aktualisieren (erstes Lot mit remaining > 0 finden)
  input[["trades"]][[name]][["fifo_front"]] <- .update_fifo_front(
    trades = input[["trades"]][[name]][["buys"]], 
    front_index = 1
  )
  
  # Status aktualisieren
  input[["status"]][[name]][["count"]] <- split_count
  input[["status"]][[name]][["price"]] <- split_price
  input[["status"]][[name]][["worth"]] <- split_worth
  
  # Preishistorie anpassen: ALLE Preise (auch vor dem Split), damit z. B. der
  # Jahresanfangskurs der Vorabpauschale in neuen Einheiten vorliegt (R1-06)
  input[["market"]][[name]][["asset_price"]] <- input[["market"]][[name]][["asset_price"]] / ratio
  
  return(input)
}

  
  
#' @title Bid-Ask-Spread anwenden
#'
#' @description
#' Passt einen Kurs je nach Handelsrichtung um den halben Bid-Ask-Spread an
#' (Kauf: Briefkurs, Verkauf: Geldkurs).
#'
#' @param price Zahl. Mittelkurs.
#' @param spread Zahl. Voller Bid-Ask-Spread als Anteil (z. B. 0.001 fuer 0,1 %); je Seite wird die Haelfte angewandt.
#' @param direction Zeichenkette. "buy" oder "sell".
#'
#' @return Zahl. Der angepasste Kurs.
#'
#' @keywords internal
#' @noRd
.apply_spread <- function(price, spread, direction = c("buy", "sell")) {
  direction <- match.arg(direction)
  
  # H-1: 'spread' = voller Bid-Ask-Spread; je Seite die Haelfte (Halb-Spread).
  if (direction == "buy") {
    price * (1 + spread / 2)  # Briefkurs (ask)
  } else {
    price * (1 - spread / 2)  # Geldkurs (bid)
  }
}

  
  
  
  
  
  
  
#--------> Hilfsfunktion für Reversen Asset-Splits:
#' Reverse Asset Split (Aktienzusammenlegung)
#'
#' Fuehrt einen Reverse-Split durch, bei dem die Anzahl der Anteile reduziert
#' und der Preis pro Anteil entsprechend erhoeht wird.
#'
#' @param input Liste. Die sim_mem Struktur
#' @param name Zeichenkette. Name des Assets
#' @param ratio Zahl. Split-Verhaeltnis (z.B. 10 fuer 10:1 Reverse-Split)
#' @param index Ganzzahl. Aktueller Zeitindex
#' @param fractions Logisch. Ohne Wirkung (Bruchteile verkauft simulation() nach dem Split).
#'
#' @return Liste. Die aktualisierte sim_mem Struktur
#'
#' @details
#' Bei einem 10:1 Reverse-Split wird:
#' - Anzahl Anteile / 10
#' - Preis pro Anteil x 10
#' - Gesamtwert bleibt gleich
#'
#' Bestand und Lots werden exakt umgerechnet. Bei fractions = FALSE verkauft
#' simulation() entstehende Bruchteile anschliessend zum Kurs des Split-Tages
#' (Spitzenausgleich, steuerlich ein Verkauf).
#'
#' @examples
#' # 10:1 Reverse-Split von Asset "XYZ"
#' sim_mem <- .reverse_asset_split(sim_mem, "XYZ", ratio = 10, index = 100, fractions = FALSE)
#'
#' @keywords internal
#' @noRd
.reverse_asset_split <- function(input, name, ratio, index, fractions) {
  
  # Aktuelle Werte auslesen
  current_count <- input[["status"]][[name]][["count"]]
  current_price <- input[["status"]][[name]][["price"]]
  current_worth <- input[["status"]][[name]][["worth"]]
  
  # Neue Werte nach Reverse-Split berechnen
  split_count <- current_count / ratio
  split_price <- current_price * ratio
  split_worth <- current_worth  # Gesamtwert ändert sich nicht!
  
  # R1-05: exakte Umrechnung; Bruchteile verkauft simulation() danach (Spitzenausgleich)
  
  # FIFO-Lots aktualisieren
  # FIFO-Lots aktualisieren (nur populierte Lots, nicht vorallokierte)
  n_lots <- input[["trades"]][[name]][["buy_count"]]
  if (n_lots > 0) {
    input[["trades"]][[name]][["buys"]][1:n_lots] <- lapply(input[["trades"]][[name]][["buys"]][1:n_lots], function(buy) {
      if (is.null(buy) || length(buy) == 0 || buy[["remaining"]] <= 0) {
        return(buy)
      }
      
      new_original_count <- buy[["count"]] / ratio
      new_buy_price <- buy[["price"]] * ratio
      new_remaining <- buy[["remaining"]] / ratio
      new_original <- (buy[["original"]] %||% buy[["remaining"]]) / ratio
      
      buy[["count"]] <- new_original_count
      buy[["price"]] <- new_buy_price
      buy[["remaining"]] <- new_remaining
      buy[["original"]] <- new_original
      
      return(buy)
    })
  }
  
  # FIFO-Front aktualisieren
  input[["trades"]][[name]][["fifo_front"]] <- .update_fifo_front(
    trades = input[["trades"]][[name]][["buys"]], 
    front_index = 1
  )
  
  # Status aktualisieren
  input[["status"]][[name]][["count"]] <- split_count
  input[["status"]][[name]][["price"]] <- split_price
  input[["status"]][[name]][["worth"]] <- split_worth
  
  # Preishistorie anpassen (alle Preise, vgl. .forward_asset_split, R1-06)
  input[["market"]][[name]][["asset_price"]] <- input[["market"]][[name]][["asset_price"]] * ratio
  
  return(input)
}


#--------> Hilfsfunktion zur Verwaltung von Asset-Splits:
#' Fuehrt einen Asset-Split durch
#'
#' Wrapper-Funktion, die je nach Typ einen Forward- oder Reverse-Split durchfuehrt.
#'
#' @param input Liste. Die sim_mem Struktur
#' @param name Zeichenkette. Name des Assets
#' @param ratio Zahl. Split-Verhaeltnis
#' @param index Ganzzahl. Aktueller Zeitindex
#' @param type Zeichenkette. "forward" oder "reverse"
#' @param fractions Logisch. Sind Bruchteile von Anteilen erlaubt?
#' @param details Logisch. Sollen Details ausgegeben werden?
#' @param current_date Date. Aktuelles Datum (fuer Ausgabe)
#'
#' @return Liste. Die aktualisierte sim_mem Struktur
#'
#' @details
#' Forward-Split (z.B. 1:4): Mehr Anteile, niedrigerer Preis
#' Reverse-Split (z.B. 10:1): Weniger Anteile, hoeherer Preis
#'
#' @examples
#' # Forward-Split 1:4
#' sim_mem <- .perform_asset_split(
#'   input = sim_mem,
#'   name = "AAPL",
#'   ratio = 4,
#'   index = 100,
#'   type = "forward",
#'   fractions = TRUE,
#'   details = TRUE,
#'   current_date = as.Date("2024-01-15")
#' )
#'
#' @keywords internal
#' @noRd
.perform_asset_split <- function(input, name, ratio, index, type,
                                 fractions = TRUE,
                                 details = FALSE,
                                 current_date = NULL) {
  
  # Validierung

  if (!type %in% c("forward", "reverse")) {
    stop(sprintf("perform_asset_split: type muss \"forward\" oder \"reverse\" sein, nicht %s.", paste(deparse(type), collapse = "")))
  }
  
  if (ratio <= 0) {
    stop(sprintf("perform_asset_split: ratio muss > 0 sein (Split-Verh\u00e4ltnis), nicht %s.", format(ratio)))
  }
  
  # Split durchführen
  if (type == "forward") {
    input <- .forward_asset_split(
      input = input,
      name = name,
      ratio = ratio,
      index = index,
      fractions = fractions
    )
  } else {
    input <- .reverse_asset_split(
      input = input,
      name = name,
      ratio = ratio,
      index = index,
      fractions = fractions
    )
  }
  
  # Details ausgeben (wenn gewünscht)
  if (details) {
    split_description <- if (type == "forward") {
      paste("1 :", format(ratio, digits = 5))
    } else {
      paste(format(ratio, digits = 5), ": 1")
    }
    
    action_word <- if (type == "forward") "Split" else "Reverse-Split"
    
    date_str <- if (!is.null(current_date)) {
      format(current_date, "%Y-%m-%d")
    } else {
      "(ohne Datum)"
    }
    
    cat(sprintf("Split-Ereignis:\t%s %s im Verh\u00e4ltnis %s am %s\n",
                action_word, name, split_description, date_str))
  }
  
  return(input)
}

#--------> Hilfsfunktion zur Realisierung von Käufen:
#' P7: Kernlogik (Report-Update + Lot-Erstellung) in C++ .sim_buy_cpp.
#' R-Wrapper berechnet trade_count (Spread, Fractions-Logik) und gibt Details aus.
#' @noRd
.perform_trade_buy <- function(input, count = NULL, name, index, reason = "", spread, fractions, details, current_date = NULL){

  market_price <- input[["market"]][[name]][["asset_price"]][index]
  if (is.na(market_price) || market_price <= 0) {
    warning(sprintf("perform_trade_buy: ung\u00fcltiger Kurs (%.4f) f\u00fcr %s am %s; der Kauf wird \u00fcbersprungen.",
                    market_price, name, input[["market"]][[name]][["asset_day"]][index]))
    return(input)
  }

  trade_price <- .apply_spread(market_price, spread, "buy")

  trade_count <- if(is.null(count)){
    if(fractions){
      input[["status"]][[name]][["money"]] / trade_price
    } else {
      floor(input[["status"]][[name]][["money"]] / trade_price)
    }
  } else {
    count
  }

  fee <- .fee_env$current
  if (!is.null(fee)) {
    money <- input[["status"]][[name]][["money"]]
    if (is.null(count) || trade_count * trade_price + .fee_amount(fee, trade_count * trade_price) > money + 1e-9) {
      vol <- .fee_volume(fee, money)
      trade_count <- if (fractions) vol / trade_price else floor(vol / trade_price)
    }
    if (trade_count <= 0) return(input)
    fee_paid <- .fee_amount(fee, trade_count * trade_price)
    trade_price <- trade_price + fee_paid / trade_count      # Gebuehr = Anschaffungsnebenkosten
    .fee_env$paid <- .fee_env$paid + fee_paid
  }

  if (trade_count <= 0) return(input)

  # A7-05: Lot-Liste bei Bedarf vergroessern (vorallokiert mit nrow(data) Plaetzen; mehr Kaeufe als
  # Datentage, z. B. taeglicher Sparplan plus Gewinnrealisierung, fuehrten sonst zum Absturz in C++)
  n_alloc <- length(input[["trades"]][[name]][["buys"]])
  if (input[["trades"]][[name]][["buy_count"]] >= n_alloc)
    input[["trades"]][[name]][["buys"]] <- c(input[["trades"]][[name]][["buys"]], vector("list", max(16L, n_alloc)))

  # C++ by-reference: Report-Update + Status-Update + Lot-Erstellung
  .sim_buy_cpp(input = input, name = name, index = index,
                        trade_count = trade_count, trade_price = trade_price,
                        market_price = market_price)

  if(details){
    cat(sprintf("%s\tKauf %.2fx %s zu %.2f EUR je Anteil am %s\n", reason, trade_count, name, trade_price, input[["market"]][[name]][["asset_day"]][index]))
  }

  return(input)
}

#--------> Hilfsfunktion zur Realisierung von Verkäufen:
.perform_trade_sell <- function(input, count = NULL, price = NULL, name, index, 
                                tax_mode, tax_rate,  # Original-Rate für Reporting
                                effective_tax_rate = NULL,
                                marginal_tax_rate = NULL,
                                private_sale_threshold = 1000,
                                use_sparer_pauschbetrag = TRUE,
                                tax_regime = NULL,  # P6: Optional, vom Aufrufer
                                reason = "", spread, details) {
  
  # Fallback wenn nicht übergeben
  if (is.null(effective_tax_rate)) {
    effective_tax_rate <- tax_rate
  }
  
  market_price <- input[["market"]][[name]][["asset_price"]][index]
  trade_price <- .apply_spread(market_price, spread, "sell")
  current_date <- input[["market"]][[name]][["asset_day"]][index]
  
  # EC2: Überverkauf-Schutz
available <- input[["status"]][[name]][["count"]]
trade_count <- if (is.null(count)) {
  available
} else {
  if (count > available) {
    warning(sprintf("perform_trade_sell: angeforderte Verkaufsmenge %.4f \u00fcbersteigt den Bestand %.4f von %s; verkauft wird der gesamte Bestand.",
                    count, available, name))
  }
  min(count, available)
}

if (trade_count <= 0) {
  return(input)
}
  fee <- .fee_env$current
  if (!is.null(fee)) {
    fee_paid <- .fee_amount(fee, trade_count * trade_price)
    if (trade_count * trade_price - fee_paid <= 0) return(input)
    trade_price <- trade_price - fee_paid / trade_count      # Gebuehr = Veraeusserungskosten
    .fee_env$paid <- .fee_env$paid + fee_paid
  }
  
  fifo_price <- if (is.null(price) && tax_mode == "person") {
    .calculate_fifo_price(
      trades = input[["trades"]][[name]][["buys"]], 
      units = trade_count, 
      front_index = input[["trades"]][[name]][["fifo_front"]]
    )
  } else {
    price %||% 0
  }
  
  trade_gain <- (trade_price - fifo_price) * trade_count
  capital_gains_tax <- 0
  
  # KORREKTUR: tax_regime mit Default initialisieren
  if (is.null(tax_regime)) tax_regime <- "none"
  lot_result <- NULL
  
  if (tax_mode == "person") {
    # P6: tax_regime vom Aufrufer oder direkt aus assets
    if (tax_regime == "none") tax_regime <- input[["assets"]][[name]][["tax_regime"]]
    
    # ============================================================
    # FALL 1: InvStG (ETF) - Teilfreistellung + Abgeltungsteuer
    # I3: effective_tax_rate für Günstigerprüfung
    # § 19 InvStG: Vorabpauschale-Anrechnung
    # ============================================================
    if (tax_regime == "investment_fund") {
      bonus <- input[["assets"]][[name]][["bonus"]]
      
      # § 19 InvStG: Bereits gezahlte Vorabpauschalen abziehen
      vorabpauschale_paid <- .calculate_fifo_vorabpauschale(
        trades = input[["trades"]][[name]][["buys"]],
        units = trade_count,
        front_index = input[["trades"]][[name]][["fifo_front"]]
      )
      
      # Angepasster Gewinn = Bruttogewinn - bereits versteuerte Vorabpauschalen
      adjusted_trade_gain <- trade_gain - vorabpauschale_paid
      
      result <- .calculate_paragraph_20_tax(
        trade_gain = adjusted_trade_gain,  # Nach VP-Anrechnung
        bonus = bonus, 
        totals = input[["totals"]], 
        tax_rate = effective_tax_rate,
        use_spb = use_sparer_pauschbetrag
      )
      input[["totals"]] <- result$totals
      capital_gains_tax <- result$tax
      
      if (details) {
        if (vorabpauschale_paid > 0) {
          cat(sprintf("\t\t=> Vorabpauschale-Anrechnung (\u00a7 19 InvStG): %.2f EUR\n",
                      vorabpauschale_paid))
        }
        if (result$spb_used > 0) {
          cat(sprintf("\t\t=> Sparerpauschbetrag: %.2f EUR (verbleibend: %.2f EUR)\n",
                      result$spb_used, input[["totals"]][["sparer_pauschbetrag_remaining"]]))
        }
      }
    }
    
    # ============================================================
    # FALL 2: § 20 EStG (ETN Standard, Zertifikate) - Abgeltungsteuer
    # I3: effective_tax_rate für Günstigerprüfung
    # ============================================================
    else if (tax_regime == "capital_gains") {
      result <- .calculate_paragraph_20_tax(
        trade_gain = trade_gain, 
        bonus = 0, 
        totals = input[["totals"]], 
        tax_rate = effective_tax_rate,  # I3: Günstigerprüfung!
        use_spb = use_sparer_pauschbetrag
      )
      input[["totals"]] <- result$totals
      capital_gains_tax <- result$tax
    }
    
    # ============================================================
    # FALL 3: § 23 EStG (ETN Deliverable) - Lot-weise Berechnung
    # ============================================================
    # 
    # M2 KORREKTUR: Verlustverrechnung erfolgt NICHT bei jedem Verkauf,
    # sondern erst am Jahresende in .handle_year_change().
    # 
    # Hier werden nur die YTD-Tracker aktualisiert:
    # - private_sale_gains_ytd: Gewinne aus Verkäufen < 1 Jahr Haltedauer
    # - private_sale_losses_ytd: Verluste aus Verkäufen < 1 Jahr Haltedauer
    # 
    # Der Verlustvortrag (loss_private_sales) wird NICHT angetastet!
    # ============================================================
    else if (tax_regime == "private_sale") {
      lot_result <- .calculate_private_sale_tax(
        input = input,
        name = name,
        trade_count = trade_count,
        sell_price = trade_price,
        current_date = current_date
      )
      
      if (details) {
        if (lot_result$exempt_gain > 0) {
          cat(sprintf("\t\t=> Steuerfreier Gewinn (Haltedauer > 1 Jahr): %.2f EUR\n", 
                      lot_result$exempt_gain))
        }
        if (lot_result$exempt_loss > 0) {
          cat(sprintf("\t\t=> Nicht verrechenbarer Verlust (Haltedauer > 1 Jahr): %.2f EUR\n", 
                      lot_result$exempt_loss))
        }
      }
      
      # ══════════════════════════════════════════════════════════════════
      # M2 KORREKTUR: NUR YTD-Tracking, KEINE Verlustverrechnung hier!
      # ══════════════════════════════════════════════════════════════════
      
      # R3a-02: steuerpflichtiger Saldo je Asset (Aufteilung der § 23-Steuerzahlung am Jahresende)
      net_by <- lot_result$taxable_gain - lot_result$taxable_loss
      if (net_by != 0) {
        by <- input[["totals"]][["private_sale_net_ytd_by"]]
        input[["totals"]][["private_sale_net_ytd_by"]][name] <- (if (name %in% names(by)) by[[name]] else 0) + net_by
      }

      # Steuerpflichtige Gewinne (< 1 Jahr Haltedauer)
      if (lot_result$taxable_gain > 0) {
        # KEINE Verrechnung mit loss_private_sales hier!
        # Das passiert erst am Jahresende.
        input[["totals"]][["private_sale_gains_ytd"]] <- 
          input[["totals"]][["private_sale_gains_ytd"]] + lot_result$taxable_gain
        
        if (details) {
          cat(sprintf("\t\t=> Steuerpflichtiger Gewinn (Haltedauer < 1 Jahr): %.2f EUR (seit Jahresbeginn: %.2f EUR)\n",
                      lot_result$taxable_gain, 
                      input[["totals"]][["private_sale_gains_ytd"]]))
        }
      }
      
      # Verluste (< 1 Jahr Haltedauer)
      if (lot_result$taxable_loss > 0) {
        input[["totals"]][["private_sale_losses_ytd"]] <- 
          input[["totals"]][["private_sale_losses_ytd"]] + lot_result$taxable_loss
        
        if (details) {
          cat(sprintf("\t\t=> Verrechenbarer Verlust (Haltedauer < 1 Jahr): %.2f EUR (seit Jahresbeginn: %.2f EUR)\n", 
                      lot_result$taxable_loss,
                      input[["totals"]][["private_sale_losses_ytd"]]))
        }
      }
      
      # ══════════════════════════════════════════════════════════════════
      
      # WICHTIG: Keine sofortige Steuer bei § 23!
      # Die Steuer wird am Jahresende in .handle_year_change() berechnet.
      capital_gains_tax <- 0
    }
  }
  
  # Report aktualisieren
  .sim_sell_report_cpp(
    input = input, name = name, index = index,
    trade_count = trade_count, trade_price = trade_price,
    market_price = market_price, capital_gains_tax = capital_gains_tax
  )
  
  # FIFO-Lots aktualisieren
  if (tax_mode == "person") {
    # C++-Port: FIFO-Verbrauch (VP proportional VOR remaining, F9) und
    # fifo_front-Update in place (fifo_core.cpp)
    .sim_fifo_consume_cpp(input, name, trade_count)
  }

  # Details ausgeben
  if (details) {
    cat(sprintf("%s\tVerkauf %.2fx %s zu %.2f EUR je Anteil am %s\n",
                reason, trade_count, name, trade_price, current_date))
    # KORREKTUR: Prüfen ob tax_regime != "none" UND != "private_sale"
    if (tax_mode == "person" && !tax_regime %in% c("none", "private_sale")) {
      cat(sprintf("\t\t=> %s: %.2f EUR; Steuer: %.2f EUR\n",
                  ifelse(trade_gain < 0, "Verlust", "Gewinn"), trade_gain, capital_gains_tax))
    }
  }
  
  # Trade-Entry speichern
  trades_entry <- list(
    event_date = current_date,
    event_type = "Sell",
    asset_count = trade_count,
    asset_price = trade_price,
    event_gain = ifelse(tax_mode == "person", trade_gain, NA),
    event_taxes = ifelse(tax_mode == "person", capital_gains_tax, NA),
    # KORREKTUR: Sichere Zugriffe
    tax_regime = if (tax_mode == "person") tax_regime else NA,
    tax_deferred = if (tax_mode == "person") (tax_regime == "private_sale") else FALSE,
    holding_exempt = if (tax_mode == "person" && tax_regime == "private_sale" && !is.null(lot_result)) {
      lot_result$exempt_gain
    } else NA
  )
  
  input[["trades"]][[name]][["sell_count"]] <- input[["trades"]][[name]][["sell_count"]] + 1
  input[["trades"]][[name]][["sells"]][[input[["trades"]][[name]][["sell_count"]]]] <- trades_entry
  
  return(input)
}


# ═══════════════════════════════════════════════════════════════════════════════
# C++ FUNKTIONEN (PFLICHT)
# ═══════════════════════════════════════════════════════════════════════════════
# Die folgenden Funktionen sind ausschließlich in simulation_core.cpp
# implementiert; die R-Hüllen (.Call über R's C-Schnittstelle) stehen in cores.R:
#
#   - .sim_dca_flows_cpp(input, name, flows, index)
#   - .sim_buy_report_cpp(input, name, index, trade_count, trade_price, market_price)
#   - .sim_sell_report_cpp(input, name, index, trade_count, trade_price,
#                          market_price, capital_gains_tax)
#   - .sim_total_report_cpp(input, assets, index)
#   - .sim_market_update_cpp(input, assets, index)
#   - .sim_market_update_batch_cpp(input, assets, start_idx, end_idx)
#   - .sim_buy_cpp(input, name, index, trade_count, trade_price, market_price)
#
# Alle Funktionen modifizieren sim_mem per Referenz (C++ pass-by-reference).
# Kein Rückgabewert nötig – Aufrufe OHNE Zuweisung: func(sim_mem, ...)
#
# Bei Fehler "could not find function ..." → Paket neu kompilieren:
#   R CMD INSTALL --preclean SimLev
# ═══════════════════════════════════════════════════════════════════════════════


# ============================================================
# HAUPT-SIMULATION
# ============================================================
#--------> Ordergebuehren (Paket-Umgebung; NULL = keine Gebuehr, Engine unveraendert)
.fee_env <- new.env(parent = emptyenv())

#' Gebuehrenangabe normalisieren
#' @keywords internal
#' @noRd
.fee_spec <- function(x) {
  if (is.null(x)) return(NULL)
  if (is.numeric(x) && length(x) == 1L) x <- list(fixed = x)
  if (!is.list(x)) stop("order_fee/dca_fee: Zahl (EUR je Order) oder list(fixed, percent, min, max).")
  unk <- setdiff(names(x), c("fixed", "percent", "min", "max"))
  if (length(x) && (is.null(names(x)) || any(names(x) == "") || length(unk)))   # R1-23: Tippfehler nicht still ignorieren
    stop(sprintf("order_fee/dca_fee: unbekannte oder unbenannte Felder (%s); erlaubt sind fixed, percent, min, max.",
                 paste(if (length(unk)) unk else "ohne Namen", collapse = ", ")))
  s <- list(fixed = x$fixed %||% 0, percent = (x$percent %||% 0) / 100, min = x$min %||% 0, max = x$max %||% Inf)
  if (s$fixed < 0 || s$percent < 0 || s$min < 0 || s$max < s$min) stop("Geb\u00fchren m\u00fcssen nicht negativ sein (min <= max).")
  if (s$fixed == 0 && s$percent == 0 && s$min == 0) return(NULL)
  s
}

#' Gebuehr fuer ein Ordervolumen
#' @keywords internal
#' @noRd
.fee_amount <- function(f, volume) min(max(f$fixed + f$percent * volume, f$min), f$max)

#' Groesstes Ordervolumen, dessen Kosten samt Gebuehr in 'money' passen
#' @keywords internal
#' @noRd
.fee_volume <- function(f, money) {
  v <- (money - f$fixed) / (1 + f$percent)
  fee <- f$fixed + f$percent * v
  if (fee < f$min) v <- money - f$min else if (fee > f$max) v <- money - f$max
  max(0, v)
}

#' Freibetrag ausschoepfen: Gewinne bis zum Rest von Sparer-Pauschbetrag (und
#' Verlusttopf) realisieren und den Erloes sofort wieder anlegen
#' @keywords internal
#' @noRd
.perform_gain_harvest <- function(input, name, index, tax_regime, spread, fractions, use_loss_pot, use_spb,
                                 tax_mode, tax_rate, effective_tax_rate, marginal_tax_rate,
                                 private_sale_threshold, details) {
  if (!tax_regime %in% c("investment_fund", "capital_gains")) return(input)
  total <- input[["status"]][[name]][["count"]]
  if (total <= 0) return(input)
  room <- (if (use_spb) input[["totals"]][["sparer_pauschbetrag_remaining"]] else 0) +
          (if (use_loss_pot) input[["totals"]][["loss_capital_gains"]] else 0)
  if (room <= 0.01) return(input)
  market_price <- input[["market"]][[name]][["asset_price"]][index]
  if (is.na(market_price) || market_price <= 0) return(input)
  sell_price <- .apply_spread(market_price, spread, "sell")
  trades <- input[["trades"]][[name]][["buys"]]; front <- input[["trades"]][[name]][["fifo_front"]]
  bonus <- if (tax_regime == "investment_fund") input[["assets"]][[name]][["bonus"]] else 0
  fee <- .fee_env$current
  taxable <- function(n, with_fee = TRUE) {
    if (n <= 0) return(0)
    px <- sell_price; if (with_fee && !is.null(fee)) px <- px - .fee_amount(fee, n * sell_price) / n
    g <- (px - .calculate_fifo_price(trades, n, front)) * n
    if (tax_regime == "investment_fund") g <- g - .calculate_fifo_vorabpauschale(trades, n, front)
    (1 - bonus) * g
  }
  first_lot <- min(total, max(1e-9, total * 1e-6))
  if (taxable(first_lot, FALSE) <= 0) return(input)   # vorderste Lots im Verlust: nichts zu holen
  n <- if (taxable(total) <= room) total else {
    lo <- 0; hi <- total
    for (i in 1:60) { mid <- (lo + hi) / 2; if (taxable(mid) > room) hi <- mid else lo <- mid; if (hi - lo < total * 1e-10) break }
    lo
  }
  if (!fractions) n <- floor(n)
  if (n <= 0 || taxable(n) <= 0) return(input)
  if (details) cat(sprintf("Freibetrag:\tRealisierung von Gewinnen %.2f EUR mit %.4fx %s (freier Sparer-Pauschbetrag/Verlusttopf %.2f EUR)\n",
                           taxable(n), n, name, room))
  input <- .perform_trade_sell(input = input, count = n, name = name, index = index, tax_mode = tax_mode,
                              tax_rate = tax_rate, effective_tax_rate = effective_tax_rate,
                              marginal_tax_rate = marginal_tax_rate, private_sale_threshold = private_sale_threshold,
                              use_sparer_pauschbetrag = use_spb, tax_regime = tax_regime,
                              reason = "Freibetrag:", spread = spread, details = details)
  input <- .perform_trade_buy(input = input, name = name, index = index, reason = "Freibetrag:", spread = spread,
                             fractions = fractions, details = details)
  input
}
