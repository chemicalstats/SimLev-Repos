#' =============================================================================
#' SimLev - Portfolio Simulation Package
#' =============================================================================
#' 
#' @author ChemicalStats von der Mauerstrasse
#' @version 2.3.0
#' @license GPL-3
#' 
#' @description
#' Simulates portfolio performance with German tax rules including:
#' - Abgeltungsteuer (flat tax on capital gains, § 20 EStG)
#' - Vorabpauschale (advance lump sum tax for funds, § 18 InvStG)
#' - Teilfreistellung (partial tax exemption for ETFs, § 20 InvStG)
#' - § 23 EStG (private sale taxation for ETN deliverable)
#' - Sparerpauschbetrag (tax-free allowance, § 20 Abs. 9 EStG)
#' - Günstigerprüfung (§ 32d Abs. 6 EStG) - optional
#' 
#' @section Tax Regimes:
#' The package supports three distinct tax regimes:
#' 
#' \describe{
#'   \item{investment_fund}{
#'     ETFs and investment funds under InvStG.
#'     - Teilfreistellung: 30% for equity funds, 15% for mixed funds
#'     - Vorabpauschale: Annual prepayment tax based on base rate
#'     - FIFO-based cost tracking
#'   }
#'   \item{capital_gains}{
#'     Standard capital gains taxation under § 20 EStG.
#'     - No Teilfreistellung
#'     - No Vorabpauschale
#'     - FIFO-based cost tracking
#'     - Used for: ETN standard, certificates
#'   }
#'   \item{private_sale}{
#'     Private sale taxation under § 23 EStG.
#'     - Holding period: Tax-free after 1 year
#'     - Freigrenze: EUR 1,000 annual exemption (since 2024)
#'     - Personal income tax rate applies (not flat tax)
#'     - Separate loss pool (only offsettable with § 23 gains)
#'     - Used for: ETN deliverable (physical delivery)
#'   }
#' }
#' 
#' @section Günstigerprüfung (I3):
#' If \code{use_guenstigerpruefung = TRUE} and \code{marginal_tax_rate < 0.25},
#' the personal tax rate is applied instead of the flat 25% Abgeltungsteuer.
#' This benefits taxpayers in lower tax brackets.
#' 
#' Formula: \code{effective_rate = marginal_tax_rate * (1 + soli_rate_income_tax)} (if Soli enabled)
#' 
#' @section Vorabpauschale Calculation (M1, M3, M4):
#' The advance lump sum tax is calculated as:
#' \deqn{VP = min(Basisertrag, Wertzuwachs)}
#' where:
#' \itemize{
#'   \item Basisertrag = Referenzwert × Basiszins × 0.70 × (Haltedauer / 365)
#'   \item Wertzuwachs = max(0, Jahresendwert - Referenzwert)
#' }
#' 
#' Special handling:
#' \itemize{
#'   \item M1: Negative base rates result in VP = 0 (not negative)
#'   \item M3: VP cannot be offset against losses (uses separate function)
#'   \item M4: Only lots held at year-end are considered
#' }
#' 
#' @section § 23 EStG Loss Handling (M2):
#' Losses from private sales (< 1 year holding) are tracked separately:
#' \itemize{
#'   \item Losses are NOT offset immediately at each sale
#'   \item Year-end reconciliation in \code{handle_year_change()}
#'   \item Loss carryforward only usable against future § 23 gains
#'   \item Annual gains below EUR 1,000 (Freigrenze) are tax-free
#'   \item If exceeded, ENTIRE gain is taxable (not just excess)
#' }
#' 
#' @changelog
#' 2.1.0 (2025-02-05):
#'   - I3: Added Günstigerprüfung (§ 32d Abs. 6 EStG) support
#'   - M1: Fixed negative base rate handling for Vorabpauschale
#'   - M2: Corrected § 23 loss offset timing (year-end, not per-sale)
#'   - M3: Separate calculate_vorabpauschale_tax() without loss offset
#'   - M4: Vorabpauschale only for lots held at year-end
#'   - Added effective_tax_rate throughout for Günstigerprüfung
#'   - Added comprehensive documentation
#' 
#' 2.0.0 (2025-01-26):
#'   - Added ETN/certificate support (tax_regime parameter)
#'   - Added Sparerpauschbetrag integration
#'   - Added separate loss pools for § 20 and § 23 EStG
#'   - Added marginal_tax_rate for personal income tax
#' 
#' 1.x.x (previous):
#'   - Initial release with ETF support
#' =============================================================================

#' @title Portfolio Simulation
#'
#' @description
#' Performs a comprehensive portfolio simulation with support for multiple
#' trading strategies, Dollar-Cost Averaging (DCA), rebalancing, and German
#' tax calculation including Günstigerprüfung.
#'
#' @param data A data.frame containing market data with columns:
#'   \describe{
#'     \item{date}{Date column (Date or character in "YYYY-MM-DD" format)}
#'     \item{[asset_names]}{Price columns for each asset in the strategy}
#'     \item{[signal_columns]}{Optional buy/sell signal columns (logical)}
#'     \item{[base_rate_column]}{Optional: Dynamic base rate if base_rate_flex = TRUE}
#'   }
#'
#' @param strategy A named list of asset configurations. Each asset should have:
#'   \describe{
#'     \item{asset_class}{Character: "etf", "etn", "etc", "etn_deliverable", "certificate"}
#'     \item{action_type}{Character: "bnh" (Buy-and-Hold) or "signal" (Signal-based)}
#'     \item{asset_share}{Numeric: Target weight (0-1), will be normalized}
#'     \item{asset_spread}{Numeric: Bid-ask spread as decimal (e.g., 0.001 for 0.1%)}
#'     \item{asset_bonus}{Numeric: Partial exemption rate (0.30 for equity ETFs, 0.15 for mixed, 0 for others)}
#'     \item{asset_start}{Date: When asset becomes tradeable (optional)}
#'     \item{tax_regime}{Character: "investment_fund", "capital_gains", or "private_sale" (optional, auto-detected from asset_class)}
#'     \item{signal_buy}{Character: Column name for buy signals (required if action_type = "signal")}
#'     \item{signal_sell}{Character: Column name for sell signals (required if action_type = "signal")}
#'   }
#'
#' @param start_value Numeric. Initial portfolio value in EUR. Default: 10000.
#'
#' @param tax_mode Character. Tax calculation mode:
#'   \describe{
#'     \item{"none"}{No tax calculation}
#'     \item{"person"}{German personal tax (Abgeltungsteuer/§ 23) with FIFO tracking}
#'     \item{"funds"}{Fund-level taxation simulation}
#'   }
#'
#' @param tax_rate Numeric. Capital gains tax rate including Soli.
#'   Default: 0.26375 (25% + 5.5% Solidaritätszuschlag).
#'   Automatically adjusted if \code{use_guenstigerpruefung = TRUE}.
#'
#' @param marginal_tax_rate Numeric or NULL. Personal marginal income tax rate (0.14-0.45).
#'   Required for:
#'   \itemize{
#'     \item § 23 EStG (private_sale) taxation
#'     \item Günstigerprüfung (if use_guenstigerpruefung = TRUE)
#'   }
#'   Example values: 0.14 (minimum), 0.24 (common), 0.42 (high income), 0.45 (top rate)
#'
#' @param use_guenstigerpruefung Logical. Apply Günstigerprüfung (§ 32d Abs. 6 EStG)?
#'   If TRUE and marginal_tax_rate < 0.25, the personal tax rate is used instead
#'   of the flat 25% Abgeltungsteuer. Default: FALSE.
#'
#' @param sparer_pauschbetrag Numeric. Annual tax-free allowance for capital gains.
#'   Default: 1000 (single person since 2023). Use 2000 for married filing jointly.
#'
#' @param use_sparer_pauschbetrag Logical. Apply Sparerpauschbetrag? Default: TRUE.
#'
#' @param private_sale_threshold Numeric. Annual Freigrenze for § 23 EStG.
#'   Default: 1000 (since 2024). Gains below this threshold are tax-free.
#'   NOTE: This is a Freigrenze (not Freibetrag) - if exceeded, ENTIRE gain is taxable.
#'
#' @param include_soli_on_income_tax Logical. Include Solidaritätszuschlag on
#'   personal income tax calculations (§ 23 EStG, Günstigerprüfung)?
#'   Default: FALSE. Since 2021, the Soli exemption threshold means most taxpayers
#'   do NOT pay Soli on income tax. Set TRUE for high-income scenarios.
#'
#' @param soli_rate_income_tax Numeric. Solidaritätszuschlag rate as decimal
#'   (default: 0.055 = 5.5%). Only applied when include_soli_on_income_tax = TRUE.
#'   Note: The Abgeltungsteuer rate (tax_rate = 0.26375) already includes Soli.
#'
#' @param base_rate Numeric or NULL. Fixed annual base rate for Vorabpauschale.
#'   Example: 2.29 for 2.29% (2024 value). Use NULL if base_rate_flex = TRUE.
#'
#' @param base_rate_flex Logical. Use dynamic base rate from data column? Default: FALSE.
#'
#' @param base_rate_data Character. Column name in data containing base rates (in percent).
#'   Required if base_rate_flex = TRUE.
#'
#' @return A list containing:
#'   \describe{
#'     \item{worth}{Numeric vector of daily portfolio values}
#'     \item{cagr}{Compound Annual Growth Rate}
#'     \item{ttwror}{Time-Weighted Rate of Return}
#'     \item{drawdowns}{Vector of drawdown percentages}
#'     \item{statistics}{List of portfolio statistics (mean, sd, skewness, kurtosis, etc.)}
#'     \item{buys}{Named vector of average annual buy transactions per asset}
#'     \item{sells}{Named vector of average annual sell transactions per asset}
#'     \item{report}{Detailed daily report per asset}
#'     \item{tax_report}{Tax summary including:
#'       \itemize{
#'         \item total_taxes_paid: Total taxes paid during simulation
#'         \item loss_carryforward_capital: Remaining § 20 EStG loss carryforward
#'         \item loss_carryforward_private: Remaining § 23 EStG loss carryforward
#'         \item sparer_pauschbetrag_used: Total Sparerpauschbetrag utilized
#'         \item sparer_pauschbetrag_tax_saved: Estimated tax savings from SPB
#'       }
#'     }
#'   }
#'
#' @examples
#' \dontrun{
#' # Basic ETF simulation with German tax rules
#' result <- simulation(
#'   data = market_data,
#'   strategy = list(
#'     MSCI_World = list(
#'       asset_class = "etf",
#'       action_type = "bnh",
#'       asset_share = 0.7,
#'       asset_spread = 0.001,
#'       asset_bonus = 0.30  # 30% Teilfreistellung for equity ETF
#'     ),
#'     Bonds = list(
#'       asset_class = "etf",
#'       action_type = "bnh",
#'       asset_share = 0.3,
#'       asset_spread = 0.001,
#'       asset_bonus = 0.0   # No Teilfreistellung for bond ETF
#'     )
#'   ),
#'   start_value = 50000,
#'   tax_mode = "person",
#'   sparer_pauschbetrag = 2000,  # Married filing jointly
#'   base_rate = 2.29            # 2024 base rate
#' )
#' 
#' # With Günstigerprüfung for low-income investor
#' result <- simulation(
#'   data = market_data,
#'   strategy = my_strategy,
#'   tax_mode = "person",
#'   marginal_tax_rate = 0.20,       # 20% personal rate
#'   use_guenstigerpruefung = TRUE   # Will use personal rate if lower than 25%
#' )
#' 
#' # With ETN deliverable (§ 23 EStG)
#' result <- simulation(
#'   data = market_data,
#'   strategy = list(
#'     Gold_ETC = list(
#'       asset_class = "etn_deliverable",
#'       action_type = "bnh",
#'       asset_share = 1.0,
#'       asset_spread = 0.002,
#'       asset_bonus = 0
#'     )
#'   ),
#'   tax_mode = "person",
#'   marginal_tax_rate = 0.35,     # Required for § 23
#'   private_sale_threshold = 1000
#' )
#' }
#'
#' @seealso
#' \itemize{
#'   \item \code{\link{calculate_paragraph_20_tax}} for § 20 EStG calculation
#'   \item \code{\link{calculate_vorabpauschale_tax}} for Vorabpauschale calculation
#'   \item \code{\link{calculate_private_sale_tax}} for § 23 EStG calculation
#'   \item \code{\link{handle_year_change}} for annual tax reconciliation
#' }
#'
#' @export


# ═══════════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS AND MAIN SIMULATION
# ═══════════════════════════════════════════════════════════════════════════════
# Asset configuration and strategy functions are in separate files:
# - asset_config.R
# - strategy.R
# ═══════════════════════════════════════════════════════════════════════════════

#' Get Tax Regime with Fallback for Legacy Assets
#' @keywords internal
get_tax_regime <- function(input, name) {
  tax_regime <- input[["assets"]][[name]][["tax_regime"]]
  
  if (is.null(tax_regime)) {
    asset_class <- input[["assets"]][[name]][["class"]]
    deliverable <- input[["assets"]][[name]][["deliverable"]] %||% FALSE
    
    tax_regime <- switch(asset_class,
      "etf" = "investment_fund",
      "etn" = if (isTRUE(deliverable)) "private_sale" else "capital_gains",
      "etc" = if (isTRUE(deliverable)) "private_sale" else "capital_gains",
      "certificate" = "capital_gains",
      # Backward compatibility
      "etn_standard" = "capital_gains",
      "etn_deliverable" = "private_sale",
      "capital_gains"  # Default
    )
  }
  
  return(tax_regime)
}

  
#' Berechnet § 20 EStG Kapitalertragsteuer
#' @keywords internal
calculate_paragraph_20_tax <- function(trade_gain, bonus, totals, tax_rate, use_spb) {
  # RCpp-Port (tax_core_RCpp.cpp); totals wird IN PLACE mutiert
  res <- p20_tax_rcpp(trade_gain, bonus, totals, tax_rate, use_spb)
  return(list(tax = res$tax, totals = totals, spb_used = res$spb_used))
}


#' Berechnet die Steuer auf Vorabpauschale (M3)
#' 
#' Im Gegensatz zu calculate_paragraph_20_tax() wird hier KEINE Verlustverrechnung
#' durchgeführt, da die Vorabpauschale ein fiktiver Ertrag ist.
#' 
#' Die Vorabpauschale mindert später beim Verkauf die Steuerlast (§ 19 InvStG),
#' aber sie kann nicht mit realisierten Verlusten verrechnet werden.
#'
#' @param flat_rate Numeric. Brutto-Vorabpauschale vor Teilfreistellung
#' @param bonus Numeric. Teilfreistellung (z.B. 0.30 für Aktien-ETFs)
#' @param totals List. Die totals-Struktur aus sim_mem[["totals"]]
#' @param tax_rate Numeric. Effektiver Steuersatz (nach Günstigerprüfung)
#' @param use_spb Logical. Sparerpauschbetrag anwenden?
#'
#' @return List mit tax, totals, spb_used, taxable_amount
#' @keywords internal
calculate_vorabpauschale_tax <- function(flat_rate, bonus, totals, tax_rate, use_spb) {
  # RCpp-Port (tax_core_RCpp.cpp, R-2: Verlusttopf vor SPB); totals in place
  res <- vp_tax_rcpp(flat_rate, bonus, totals, tax_rate, use_spb)
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
          month_end - (days - 1)
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
#' Berechnet Split-Flags für alle Assets (vektorisiert)
#'
#' @param input sim_mem Struktur
#' @param base Numeric. Basis-Preis für Split-Ratio Berechnung (default: 100)
#' @param mode Logical. Split-Modus aktiv?
#' @param dates Date-Vektor. Simulationsdaten
#'
#' @return Logical-Vektor: TRUE wenn an diesem Tag ein Split stattfindet
#' @keywords internal
calculate_split_flags <- function(input, base, mode, dates, split_thresh = NULL) {
  if (!mode || is.null(split_thresh)) {
    return(rep(FALSE, length(dates)))
  }
  
  n_days <- length(dates)
  n_assets <- length(input[["market"]])
  asset_names <- names(input[["market"]])
  
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
  #' Evaluate Buy Signal for Asset
#' 
#' @param input sim_mem structure
#' @param name Character. Asset name
#' @param index Integer. Current time index
#' 
#' @return Logical. TRUE if buy signal is active, FALSE otherwise
#' 
#' @details
#' Returns TRUE if:
#' - action_type = "signal" AND signal_buy column is TRUE AND money > 0 AND count = 0
#' - action_type = "bnh" AND money > 0
#' 
#' @keywords internal
calculate_buy_signal <- function(input, name, index){
  signal_buy <- FALSE

  if(input[["assets"]][[name]][["style"]] == "signal" && input[["market"]][[name]][["signal_buy"]][index] && input[["status"]][[name]][["money"]] > 0 && input[["status"]][[name]][["count"]] == 0){
      signal_buy <- TRUE
  }

  if(input[["assets"]][[name]][["style"]] == "bnh" && input[["status"]][[name]][["money"]] > 0){
    signal_buy <- TRUE
  }

  return(signal_buy)
}

#--------> Hilfsfunktion zur Evaluation von Verkaufssignalen:
calculate_sell_signal <- function(input, name, index){
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
calculate_fifo_price <- function(trades, units, front_index = 1){
  # RCpp-Port (fifo_core_RCpp.cpp)
  calculate_fifo_price_rcpp(trades, units, as.integer(front_index))
}


#--------> Hilfsfunktion zur Berechnung der anrechenbaren Vorabpauschale (§ 19 InvStG):
#' Berechnet die anteilige Vorabpauschale für verkaufte Anteile
#'
#' @param trades Liste der Kauf-Transaktionen
#' @param units Anzahl zu verkaufender Anteile
#' @param front_index FIFO-Startindex
#'
#' @return Anteilige Vorabpauschale in EUR
#' @keywords internal
calculate_fifo_vorabpauschale <- function(trades, units, front_index = 1) {
  # RCpp-Port (fifo_core_RCpp.cpp)
  calculate_fifo_vp_rcpp(trades, units, as.integer(front_index))
}
  
#--------> Hilfsfunktion zur lot-weisen Steuerberechnung für § 23 EStG:
calculate_private_sale_tax <- function(input, name, trade_count, sell_price, current_date) {
  # RCpp-Port (fifo_core_RCpp.cpp), Par.-23-Jahresfrist kalendergenau in C++
  calculate_private_sale_tax_rcpp(
    input[["trades"]][[name]][["buys"]],
    as.integer(input[["trades"]][[name]][["fifo_front"]]),
    trade_count, sell_price, as.integer(current_date))
}
  
#--------> Hilfsfunktion zur Prüfung und Verarbeitung des Jahreswechsels:
#' Prüft und verarbeitet den Jahreswechsel für § 23 EStG und Sparerpauschbetrag
#'
#' Diese Funktion wird am Anfang jedes Simulationstages aufgerufen und prüft,
#' ob ein Jahreswechsel stattgefunden hat. Falls ja, werden folgende Aktionen
#' durchgeführt:
#' 
#' 1. § 23 EStG Freigrenze prüfen und ggf. Steuer berechnen
#' 2. Verluste unter der Freigrenze ins nächste Jahr vortragen
#' 3. Sparerpauschbetrag für das neue Jahr zurücksetzen
#'
#' @param input Liste. Die sim_mem Struktur mit allen Simulationsdaten
#' @param current_date Date. Das aktuelle Datum der Simulation
#' @param marginal_tax_rate Numeric oder NULL. Persönlicher Grenzsteuersatz (0.14-0.45)
#' @param private_sale_threshold Numeric. Freigrenze für § 23 EStG (default: 1000)
#' @param sparer_pauschbetrag Numeric. Jährlicher Sparerpauschbetrag (default: 1000)
#' @param use_sparer_pauschbetrag Logical. Soll der SPB angewendet werden?
#' @param details Logical. Sollen Details ausgegeben werden?
#'
#' @return Liste. Die aktualisierte sim_mem Struktur
#'
#' @details
#' § 23 EStG Freigrenze:
#' - Wenn Jahresgewinn > Freigrenze: GESAMTER Gewinn wird besteuert (nicht nur Überschuss!)
#' - Wenn Jahresgewinn <= Freigrenze: Steuerfrei
#' - Wenn Jahresverlust: Vortrag ins nächste Jahr (nur mit anderen § 23 Gewinnen verrechenbar)
#'
#' @keywords internal
handle_year_change <- function(input, current_date, marginal_tax_rate, 
                               private_sale_threshold, sparer_pauschbetrag,
                               use_sparer_pauschbetrag, soli_factor_income = 1.0,
                               effective_tax_rate = NULL,
                               details) {
  
  current_year <- as.integer(format(current_date, "%Y"))
  stored_year <- input[["totals"]][["current_year"]]
  
 # Kein Jahreswechsel -> nichts zu tun
  if (current_year == stored_year) {
    return(input)
  }
  
  # === JAHRESWECHSEL ERKANNT ===
  
  if (details) {
    cat(sprintf("\n══════════════════════════════════════════════════════════════\n"))
    cat(sprintf("  JAHRESWECHSEL: %d -> %d\n", stored_year, current_year))
    cat(sprintf("══════════════════════════════════════════════════════════════\n"))
  }
  
  # ------------------------------------------------------------------
  # 1. § 23 EStG Jahresabrechnung
  # ------------------------------------------------------------------
  
  ytd_gains <- input[["totals"]][["private_sale_gains_ytd"]]
  ytd_losses <- input[["totals"]][["private_sale_losses_ytd"]]
  
  # ══════════════════════════════════════════════════════════════════════
  # M2 KORREKTUR: Verlustvortrag JETZT anwenden (am Jahresende)
  # ══════════════════════════════════════════════════════════════════════
  
  # Schritt 1: Verluste des aktuellen Jahres mit Gewinnen verrechnen
  internal_offset <- min(ytd_gains, ytd_losses)
  net_ytd_gains <- ytd_gains - internal_offset
  net_ytd_losses <- ytd_losses - internal_offset
  
  # Schritt 2: Verlustvortrag aus Vorjahren mit verbleibendem Gewinn verrechnen
  carryforward_offset <- 0
  if (net_ytd_gains > 0 && input[["totals"]][["loss_private_sales"]] > 0) {
    carryforward_offset <- min(net_ytd_gains, input[["totals"]][["loss_private_sales"]])
    input[["totals"]][["loss_private_sales"]] <- input[["totals"]][["loss_private_sales"]] - carryforward_offset
    net_ytd_gains <- net_ytd_gains - carryforward_offset
    
    if (details && carryforward_offset > 0) {
      cat(sprintf("  § 23 EStG: Verlustvortrag verwendet: %.2f EUR\n", carryforward_offset))
      cat(sprintf("             Verbleibender Vortrag: %.2f EUR\n", 
                  input[["totals"]][["loss_private_sales"]]))
    }
  }
  
  # Netto-Ergebnis nach allen Verrechnungen
  net_gain <- net_ytd_gains  # Kann nur >= 0 sein nach obiger Logik
  
  # ══════════════════════════════════════════════════════════════════════
  
  if (details) {
    cat(sprintf("  § 23 EStG Jahresübersicht %d:\n", stored_year))
    cat(sprintf("    Bruttogewinne (< 1 Jahr):    %10.2f EUR\n", ytd_gains))
    cat(sprintf("    Bruttoverluste (< 1 Jahr):   %10.2f EUR\n", ytd_losses))
    cat(sprintf("    Interne Verrechnung:         %10.2f EUR\n", internal_offset))
    cat(sprintf("    Verlustvortrag-Verrechnung:  %10.2f EUR\n", carryforward_offset))
    cat(sprintf("    ─────────────────────────────────────────\n"))
    cat(sprintf("    Netto-Ergebnis:              %10.2f EUR\n", net_gain - net_ytd_losses))
  }
  
  if (net_gain > private_sale_threshold) {
    # ------------------------------------------------------------------
    # FALL A: Freigrenze ÜBERSCHRITTEN -> Gesamter Gewinn steuerpflichtig
    # ------------------------------------------------------------------
    
    if (is.null(marginal_tax_rate)) {
      warning(
        "§ 23 EStG: Gewinne (", format(round(net_gain, 2), big.mark = ","), 
        " EUR) über Freigrenze (", format(private_sale_threshold, big.mark = ","), 
        " EUR), aber 'marginal_tax_rate' nicht gesetzt.\n",
        "Verwende 42% (Spitzensteuersatz).",
        call. = FALSE
      )
      marginal_tax_rate <- 0.42
    }
    
    # Steuerberechnung
    tax_due <- net_gain * marginal_tax_rate * soli_factor_income
    input[["totals"]][["total_taxes"]] <- input[["totals"]][["total_taxes"]] + tax_due
    
    if (details) {
      cat(sprintf("\n  ⚠ FREIGRENZE ÜBERSCHRITTEN!\n"))
      cat(sprintf("    Netto-Gewinn %.2f EUR > Freigrenze %.2f EUR\n", 
                  net_gain, private_sale_threshold))
      cat(sprintf("    → GESAMTER Gewinn steuerpflichtig (Freigrenze, kein Freibetrag!)\n"))
      cat(sprintf("    → Steuersatz: %.1f%%%s\n", marginal_tax_rate * 100, if (soli_factor_income > 1) sprintf(" + %.1f%%%% Soli", (soli_factor_income - 1) * 100) else ""))
      cat(sprintf("    → Steuerlast: %.2f EUR\n", tax_due))
    }
    
  } else if (net_ytd_losses > 0) {
    # ------------------------------------------------------------------
    # FALL B: Netto-VERLUST -> Vortrag ins nächste Jahr
    # ------------------------------------------------------------------
    
    input[["totals"]][["loss_private_sales"]] <- 
      input[["totals"]][["loss_private_sales"]] + net_ytd_losses
    
    if (details) {
      cat(sprintf("\n  Nettoverlust %.2f EUR → Vortrag ins nächste Jahr\n", net_ytd_losses))
      cat(sprintf("  Gesamter Verlustvortrag: %.2f EUR\n", 
                  input[["totals"]][["loss_private_sales"]]))
    }
    
  } else if (net_gain > 0) {
    # ------------------------------------------------------------------
    # FALL C: Gewinn UNTER der Freigrenze -> Steuerfrei
    # ------------------------------------------------------------------
    
    if (details) {
      cat(sprintf("\n  ✓ Netto-Gewinn %.2f EUR ≤ Freigrenze %.2f EUR → STEUERFREI\n", 
                  net_gain, private_sale_threshold))
    }
    
  } else {
    if (details) {
      cat(sprintf("\n  Keine steuerpflichtigen § 23 Vorgänge in %d\n", stored_year))
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
  unused_loss <- max(0, cgt_loss_added - cgt_loss_used)
  unused_loss <- min(unused_loss, input[["totals"]][["loss_capital_gains"]])
  refund_base <- min(unused_loss, cgt_base_taxed)
  if (refund_base > 0 && !is.null(effective_tax_rate) && effective_tax_rate > 0) {
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
      cat(sprintf("  § 20 EStG: Unterjaehrige Verlustverrechnung -> Erstattung %.2f EUR in den Geldbestand\n", refund))
    }
  }

  # ------------------------------------------------------------------
  # 3. Reset für neues Jahr
  # ------------------------------------------------------------------
  
  input[["totals"]][["private_sale_gains_ytd"]] <- 0
  input[["totals"]][["private_sale_losses_ytd"]] <- 0
  input[["totals"]][["cgt_base_taxed_ytd"]] <- 0
  input[["totals"]][["cgt_loss_added_ytd"]] <- 0
  input[["totals"]][["cgt_loss_used_ytd"]] <- 0
  
  if (use_sparer_pauschbetrag) {
    input[["totals"]][["sparer_pauschbetrag_remaining"]] <- sparer_pauschbetrag
  }
  
  input[["totals"]][["current_year"]] <- current_year
  
  if (details) {
    cat(sprintf("\n  Tracker zurückgesetzt für Jahr %d\n", current_year))
    cat(sprintf("══════════════════════════════════════════════════════════════\n\n"))
  }
  
  return(input)
}



#--------> Hilfsfunktion zur Berechnung des FIFO-Grenzindex:
update_fifo_front <- function(trades, front_index){
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

#--------> Hilfsfunktion zur Berechnung von Bisection-Searches:
calculate_bisection_search <- function(f, lower, upper, f_lower, f_upper, tol = 1e-6, max_iter = 30){
  if (abs(f_lower) < tol) return(lower)
  if (abs(f_upper) < tol) return(upper)
  if (f_lower * f_upper > 0) {
    return(if (abs(f_lower) < abs(f_upper)) lower else upper)
  }

  for (i in seq_len(max_iter)){
    mid <- (lower + upper) * 0.5
    f_mid <- f(mid)

    if(abs(f_mid) < tol || (upper - lower) < tol){
      return(mid)
    }

    if(f_mid * f_lower < 0){
      upper <- mid
      f_upper <- f_mid
    } else {
      lower <- mid
      f_lower <- f_mid
    }
  }

  return((lower + upper) * 0.5)
}

#--------> Hilfsfunktion zur Berechnung der Vorabpauschale:
#' Berechnet die Vorabpauschale nach § 18 InvStG
#' 
#' @details
#' Bei negativem Basiszins ist die Vorabpauschale = 0.
#' Der Basiszins wird vom BMF jährlich veröffentlicht und kann negativ sein
#' (wie z.B. 2021: -0.45%, 2022: -0.05%).
calculate_flat_rate <- function(input, name, index, dates, tax_regime = NULL) {
  # P6: tax_regime wird vom Aufrufer übergeben (Lookup-Vektor)
  # Vorabpauschale nur für investment_fund
  if (is.null(tax_regime)) tax_regime <- input[["assets"]][[name]][["tax_regime"]]
  
  # Einheitliches Rückgabeformat für alle Early-Returns
  empty_result <- list(total_vp = 0, lot_indices = integer(0), lot_vps = numeric(0))
  
  if (tax_regime != "investment_fund") {
    return(empty_result)
  }
  
  bonus <- input[["assets"]][[name]][["bonus"]]
  date_index <- dates[index]
  
  # P5: format()-Guard entfernt – Aufrufer garantiert 31.12. via flag_taxes
  
  start_of_year <- as.Date(paste0(format(date_index, "%Y"), "-01-01"))
  end_of_year <- as.Date(paste0(format(date_index, "%Y"), "-12-31"))
  
  # Schaltjahr-Berechnung
  year_num <- as.numeric(format(date_index, "%Y"))
  is_leap <- (year_num %% 4 == 0 & (year_num %% 100 != 0 | year_num %% 400 == 0))
  days_in_year <- if (is_leap) 366 else 365
  
  # ══════════════════════════════════════════════════════════════════════
  # M1 KORREKTUR: Basiszins auf mindestens 0 begrenzen
  # ══════════════════════════════════════════════════════════════════════
  raw_base_rate <- input[["market"]][[name]][["base_rates"]][index] / 100
  base_rate <- max(0, raw_base_rate)
  
  if (base_rate <= 0) {
    return(empty_result)
  }
  # ══════════════════════════════════════════════════════════════════════
  
  market_price <- input[["market"]][[name]][["asset_price"]][index]
  
  # P2: Arithmetischer Index statt which()-Scan (O(1) statt O(n))
  year_start_index <- max(1L, as.integer(start_of_year - dates[1]) + 1L)
  year_start_price <- input[["market"]][[name]][["asset_price"]][year_start_index]
  
  # ══════════════════════════════════════════════════════════════════════
  # M4: Nur Lots die am Jahresende noch gehalten werden
  # ══════════════════════════════════════════════════════════════════════
  # RCpp-Port des Lot-Loops (tax_core_RCpp.cpp): M4/T-1/Growth-Cap,
  # Datumsvergleiche als Integer (frueher geplante Option A inklusive)
  res <- flat_rate_rcpp(
    input[["trades"]][[name]][["buys"]],
    as.integer(input[["trades"]][[name]][["fifo_front"]]),
    base_rate, year_start_price, market_price,
    as.integer(start_of_year), as.integer(end_of_year))
  return(res)
}



#--------> Hilfsfunktion zur Berechnung der Fongsgebühren:
calculate_fund_fees <- function(input, index, dates, assets, funds_fee, bonus_fee, details){
  event_date <- as.Date(paste0(format(dates[index], "%Y"), "-01-01"))
  dates_index <- which(dates >= event_date & dates <= dates[index])

  if(length(dates_index) == 0){
    return(c(total_fees = 0, total_value = input[["totals"]][["total_value"]]))
  }

  asset_totals <- sapply(assets, function(x) input[["report"]][[x]][["total"]][dates_index], simplify = "array")

  daily_rate <- (funds_fee / 100 + 1)^(1 / length(dates_index)) - 1
  basic_value <- sum(asset_totals * daily_rate, na.rm = TRUE)

  total_value <- input[["totals"]][["total_value"]]
  market_value <- sum(sapply(input[["status"]], function(x) x[["total"]]), na.rm = TRUE)

  if(market_value > total_value){
    bonus_value <- (market_value - total_value) * (bonus_fee / 100)
    total_value <- market_value
  } else {
    bonus_value <- 0
  }

  total_fees <- basic_value + bonus_value

  if(details){
    cat(sprintf("Funds Event:\tPaying funds fees of %.2f EUR on %s\n\t\t=> Basis fee: %.2f EUR; Bonus fee: %.2f EUR\n", total_fees, dates[index], basic_value, bonus_value))
  }

  return(c(total_fees = total_fees, total_value = total_value))
}


#--------> Hilfsfunktion zur Berechnung zu verkaufender Anteile:
#' Berechnet die optimale Anzahl zu verkaufender Anteile (optimiert)
#'
#' Verwendet vorberechnete kumulative FIFO-Daten und Bisection-Search
#' für schnelle Konvergenz.
#'
#' @param input Liste. Die sim_mem Struktur
#' @param name Character. Asset-Name
#' @param target Numeric. Ziel-Nettowert nach Steuern
#' @param index Integer. Aktueller Zeitindex
#' @param spread Numeric. Bid-Ask-Spread in Prozent
#' @param fractions Logical. Bruchteile erlaubt?
#' @param tax_mode Character. Steuermodus
#' @param tax_rate Numeric. Steuersatz
#' @param marginal_tax_rate Numeric. Persönlicher Grenzsteuersatz (für § 23)
#'
#' @return Liste mit sell_count und fifo_price
#' @keywords internal
calculate_sell_count <- function(input, name, target, index, spread, fractions, 
                                            tax_mode, tax_rate, marginal_tax_rate = NULL,
                                            tax_regime = NULL) {
  
  # KORREKTUR K1: market_price aus input auslesen
  market_price <- input[["market"]][[name]][["asset_price"]][index]
  trade_price <- apply_spread(market_price, spread, "sell")
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
  
  # RCpp-Port (tax_core_RCpp.cpp): Extraktion + kum. FIFO + Bisektion in C++
  if (is.null(tax_regime)) tax_regime <- input[["assets"]][[name]][["tax_regime"]]
  tax_regime <- if (tax_mode == "person") tax_regime else "none"
  bonus <- if (tax_regime == "investment_fund") input[["assets"]][[name]][["bonus"]] else 0
  loss_pool <- input[["totals"]][["loss_capital_gains"]]
  regime_code <- switch(tax_regime, none = 0L, investment_fund = 1L,
                        capital_gains = 2L, private_sale = 3L, 0L)
  res <- sell_count_rcpp(trades, as.integer(front_index), target, trade_price,
                         total_shares, isTRUE(fractions), regime_code,
                         bonus, loss_pool, tax_rate)
  return(res)
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
#' Führt einen Forward-Split durch, bei dem die Anzahl der Anteile erhöht
#' und der Preis pro Anteil entsprechend reduziert wird.
#'
#' @param input Liste. Die sim_mem Struktur
#' @param name Character. Name des Assets
#' @param ratio Numeric. Split-Verhältnis (z.B. 4 für 1:4 Split)
#' @param index Integer. Aktueller Zeitindex
#' @param fractions Logical. Sind Bruchteile von Anteilen erlaubt?
#'
#' @return Liste. Die aktualisierte sim_mem Struktur
#'
#' @details
#' Bei einem 1:4 Split wird:
#' - Anzahl Anteile × 4
#' - Preis pro Anteil ÷ 4
#' - Gesamtwert bleibt gleich
#'
#' Wenn fractions = FALSE und durch den Split Bruchteile entstehen,
#' werden diese als Cash gutgeschrieben.
#'
#' @examples
#' # 1:4 Split von Asset "AAPL"
#' sim_mem <- forward_asset_split(sim_mem, "AAPL", ratio = 4, index = 100, fractions = TRUE)
#'
#' @keywords internal
forward_asset_split <- function(input, name, ratio, index, fractions) {
  

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
  
  # Bruchteile behandeln wenn fractions = FALSE
  if (!fractions && split_count %% 1 != 0) {
    split_fract <- split_count %% 1
    split_count <- floor(split_count)
    # Bruchteile werden als Cash gutgeschrieben
    fractional_value <- split_fract * split_price
    input[["status"]][[name]][["money"]] <- input[["status"]][[name]][["money"]] + fractional_value
  }
  
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
      
      # Bruchteile in Lots behandeln
      if (!fractions && new_original_count %% 1 != 0) {
        fract <- new_original_count %% 1
        new_original_count <- floor(new_original_count)
        new_remaining <- floor(new_remaining)
        new_original <- floor(new_original)
        fractional_value <- fract * new_buy_price
        input[["status"]][[name]][["money"]] <<- input[["status"]][[name]][["money"]] + fractional_value
      }
      
      buy[["count"]] <- new_original_count
      buy[["price"]] <- new_buy_price
      buy[["remaining"]] <- new_remaining
      buy[["original"]] <- new_original
      
      return(buy)
    })
  }
  
  # FIFO-Front aktualisieren (erstes Lot mit remaining > 0 finden)
  input[["trades"]][[name]][["fifo_front"]] <- update_fifo_front(
    trades = input[["trades"]][[name]][["buys"]], 
    front_index = 1
  )
  
  # Status aktualisieren
  input[["status"]][[name]][["count"]] <- split_count
  input[["status"]][[name]][["price"]] <- split_price
  input[["status"]][[name]][["worth"]] <- split_worth
  
  # Preishistorie anpassen (alle Preise ab dem Split-Datum)
  # Damit historische Berechnungen konsistent bleiben
  price_vector <- input[["market"]][[name]][["asset_price"]]
  n_prices <- length(price_vector)
  if (index <= n_prices) {
    input[["market"]][[name]][["asset_price"]][index:n_prices] <- price_vector[index:n_prices] / ratio
  }
  
  return(input)
}

  
  
#' @title Apply Bid-Ask Spread
#'
#' @description
#' Adjusts a price for the bid-ask spread based on trade direction.
#'
#' @param price Numeric. The mid-price.
#' @param spread Numeric. Half-spread as a decimal (e.g., 0.001 for 0.1%).
#' @param direction Character. "buy" or "sell".
#'
#' @return Numeric. The adjusted price.
#'
#' @keywords internal
apply_spread <- function(price, spread, direction = c("buy", "sell")) {
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
#' Führt einen Reverse-Split durch, bei dem die Anzahl der Anteile reduziert
#' und der Preis pro Anteil entsprechend erhöht wird.
#'
#' @param input Liste. Die sim_mem Struktur
#' @param name Character. Name des Assets
#' @param ratio Numeric. Split-Verhältnis (z.B. 10 für 10:1 Reverse-Split)
#' @param index Integer. Aktueller Zeitindex
#' @param fractions Logical. Sind Bruchteile von Anteilen erlaubt?
#'
#' @return Liste. Die aktualisierte sim_mem Struktur
#'
#' @details
#' Bei einem 10:1 Reverse-Split wird:
#' - Anzahl Anteile ÷ 10
#' - Preis pro Anteil × 10
#' - Gesamtwert bleibt gleich
#'
#' Wenn fractions = FALSE und durch den Split Bruchteile entstehen,
#' werden diese als Cash gutgeschrieben (Spitzenausgleich).
#'
#' @examples
#' # 10:1 Reverse-Split von Asset "XYZ"
#' sim_mem <- reverse_asset_split(sim_mem, "XYZ", ratio = 10, index = 100, fractions = FALSE)
#'
#' @keywords internal
reverse_asset_split <- function(input, name, ratio, index, fractions) {
  
  # Aktuelle Werte auslesen
  current_count <- input[["status"]][[name]][["count"]]
  current_price <- input[["status"]][[name]][["price"]]
  current_worth <- input[["status"]][[name]][["worth"]]
  
  # Neue Werte nach Reverse-Split berechnen
  split_count <- current_count / ratio
  split_price <- current_price * ratio
  split_worth <- current_worth  # Gesamtwert ändert sich nicht!
  
  # Bruchteile behandeln wenn fractions = FALSE
  if (!fractions && split_count %% 1 != 0) {
    split_fract <- split_count %% 1
    split_count <- floor(split_count)
    # Bruchteile werden als Cash gutgeschrieben (Spitzenausgleich)
    fractional_value <- split_fract * split_price
    input[["status"]][[name]][["money"]] <- input[["status"]][[name]][["money"]] + fractional_value
  }
  
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
      
      if (!fractions && new_original_count %% 1 != 0) {
        fract <- new_original_count %% 1
        new_original_count <- floor(new_original_count)
        new_remaining <- floor(new_remaining)
        new_original <- floor(new_original)
        fractional_value <- fract * new_buy_price
        input[["status"]][[name]][["money"]] <<- input[["status"]][[name]][["money"]] + fractional_value
      }
      
      buy[["count"]] <- new_original_count
      buy[["price"]] <- new_buy_price
      buy[["remaining"]] <- new_remaining
      buy[["original"]] <- new_original
      
      return(buy)
    })
  }
  
  # FIFO-Front aktualisieren
  input[["trades"]][[name]][["fifo_front"]] <- update_fifo_front(
    trades = input[["trades"]][[name]][["buys"]], 
    front_index = 1
  )
  
  # Status aktualisieren
  input[["status"]][[name]][["count"]] <- split_count
  input[["status"]][[name]][["price"]] <- split_price
  input[["status"]][[name]][["worth"]] <- split_worth
  
  # Preishistorie anpassen
  price_vector <- input[["market"]][[name]][["asset_price"]]
  n_prices <- length(price_vector)
  if (index <= n_prices) {
    input[["market"]][[name]][["asset_price"]][index:n_prices] <- price_vector[index:n_prices] * ratio
  }
  
  return(input)
}


#--------> Hilfsfunktion zur Verwaltung von Asset-Splits:
#' Führt einen Asset-Split durch
#'
#' Wrapper-Funktion, die je nach Typ einen Forward- oder Reverse-Split durchführt.
#'
#' @param input Liste. Die sim_mem Struktur
#' @param name Character. Name des Assets
#' @param ratio Numeric. Split-Verhältnis
#' @param index Integer. Aktueller Zeitindex
#' @param type Character. "forward" oder "reverse"
#' @param fractions Logical. Sind Bruchteile von Anteilen erlaubt?
#' @param details Logical. Sollen Details ausgegeben werden?
#' @param current_date Date. Aktuelles Datum (für Ausgabe)
#'
#' @return Liste. Die aktualisierte sim_mem Struktur
#'
#' @details
#' Forward-Split (z.B. 1:4): Mehr Anteile, niedrigerer Preis
#' Reverse-Split (z.B. 10:1): Weniger Anteile, höherer Preis
#'
#' @examples
#' # Forward-Split 1:4
#' sim_mem <- perform_asset_split(
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
#' @export
perform_asset_split <- function(input, name, ratio, index, type,
                                 fractions = TRUE,
                                 details = FALSE,
                                 current_date = NULL) {
  
  # Validierung

  if (!type %in% c("forward", "reverse")) {
    stop("'type' must be either 'forward' or 'reverse'")
  }
  
  if (ratio <= 0) {
    stop("'ratio' must be positive")
  }
  
  # Split durchführen
  if (type == "forward") {
    input <- forward_asset_split(
      input = input,
      name = name,
      ratio = ratio,
      index = index,
      fractions = fractions
    )
  } else {
    input <- reverse_asset_split(
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
    
    action_word <- if (type == "forward") "Splitting" else "Reverse splitting"
    
    date_str <- if (!is.null(current_date)) {
      format(current_date, "%Y-%m-%d")
    } else {
      "(date not provided)"
    }
    
    cat(sprintf("Split Event:\t%s %s via %s on %s\n",
                action_word, name, split_description, date_str))
  }
  
  return(input)
}

#--------> Hilfsfunktion zur Realisierung von Käufen:
#' P7: Kernlogik (Report-Update + Lot-Erstellung) in C++ perform_trade_buy_cpp.
#' R-Wrapper berechnet trade_count (Spread, Fractions-Logik) und gibt Details aus.
perform_trade_buy <- function(input, count = NULL, name, index, reason = "", spread, fractions, details, current_date = NULL){

  market_price <- input[["market"]][[name]][["asset_price"]][index]
  if (is.na(market_price) || market_price <= 0) {
    warning(sprintf("Invalid market price (%.4f) for %s on %s - skipping trade",
                    market_price, name, input[["market"]][[name]][["asset_day"]][index]))
    return(input)
  }

  trade_price <- apply_spread(market_price, spread, "buy")

  trade_count <- if(is.null(count)){
    if(fractions){
      input[["status"]][[name]][["money"]] / trade_price
    } else {
      floor(input[["status"]][[name]][["money"]] / trade_price)
    }
  } else {
    count
  }

  if (trade_count <= 0) return(input)

  # C++ by-reference: Report-Update + Status-Update + Lot-Erstellung
  perform_trade_buy_cpp(input = input, name = name, index = index,
                        trade_count = trade_count, trade_price = trade_price,
                        market_price = market_price)

  if(details){
    cat(sprintf("%s\tBuying %.2fx %s at %.2f EUR per share on %s\n", reason, trade_count, name, trade_price, input[["market"]][[name]][["asset_day"]][index]))
  }

  return(input)
}

#--------> Hilfsfunktion zur Realisierung von Verkäufen:
perform_trade_sell <- function(input, count = NULL, price = NULL, name, index, 
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
  trade_price <- apply_spread(market_price, spread, "sell")
  current_date <- input[["market"]][[name]][["asset_day"]][index]
  
  # EC2: Überverkauf-Schutz
available <- input[["status"]][[name]][["count"]]
trade_count <- if (is.null(count)) {
  available
} else {
  if (count > available) {
    warning(sprintf("Requested sell count (%.4f) exceeds available (%.4f) for %s. Selling all.",
                    count, available, name))
  }
  min(count, available)
}

if (trade_count <= 0) {
  return(input)
}
  
  fifo_price <- if (is.null(price) && tax_mode == "person") {
    calculate_fifo_price(
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
      vorabpauschale_paid <- calculate_fifo_vorabpauschale(
        trades = input[["trades"]][[name]][["buys"]],
        units = trade_count,
        front_index = input[["trades"]][[name]][["fifo_front"]]
      )
      
      # Angepasster Gewinn = Bruttogewinn - bereits versteuerte Vorabpauschalen
      adjusted_trade_gain <- trade_gain - vorabpauschale_paid
      
      result <- calculate_paragraph_20_tax(
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
          cat(sprintf("\t\t=> Vorabpauschale-Anrechnung (§ 19 InvStG): %.2f EUR\n",
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
      result <- calculate_paragraph_20_tax(
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
    # sondern erst am Jahresende in handle_year_change().
    # 
    # Hier werden nur die YTD-Tracker aktualisiert:
    # - private_sale_gains_ytd: Gewinne aus Verkäufen < 1 Jahr Haltedauer
    # - private_sale_losses_ytd: Verluste aus Verkäufen < 1 Jahr Haltedauer
    # 
    # Der Verlustvortrag (loss_private_sales) wird NICHT angetastet!
    # ============================================================
    else if (tax_regime == "private_sale") {
      lot_result <- calculate_private_sale_tax(
        input = input,
        name = name,
        trade_count = trade_count,
        sell_price = trade_price,
        current_date = current_date
      )
      
      if (details) {
        if (lot_result$exempt_gain > 0) {
          cat(sprintf("\t\t=> Tax-exempt gain (held > 1 year): %.2f EUR\n", 
                      lot_result$exempt_gain))
        }
        if (lot_result$exempt_loss > 0) {
          cat(sprintf("\t\t=> Non-deductible loss (held > 1 year): %.2f EUR\n", 
                      lot_result$exempt_loss))
        }
      }
      
      # ══════════════════════════════════════════════════════════════════
      # M2 KORREKTUR: NUR YTD-Tracking, KEINE Verlustverrechnung hier!
      # ══════════════════════════════════════════════════════════════════
      
      # Steuerpflichtige Gewinne (< 1 Jahr Haltedauer)
      if (lot_result$taxable_gain > 0) {
        # KEINE Verrechnung mit loss_private_sales hier!
        # Das passiert erst am Jahresende.
        input[["totals"]][["private_sale_gains_ytd"]] <- 
          input[["totals"]][["private_sale_gains_ytd"]] + lot_result$taxable_gain
        
        if (details) {
          cat(sprintf("\t\t=> Taxable gain (held < 1 year): %.2f EUR (YTD total: %.2f EUR)\n",
                      lot_result$taxable_gain, 
                      input[["totals"]][["private_sale_gains_ytd"]]))
        }
      }
      
      # Verluste (< 1 Jahr Haltedauer)
      if (lot_result$taxable_loss > 0) {
        input[["totals"]][["private_sale_losses_ytd"]] <- 
          input[["totals"]][["private_sale_losses_ytd"]] + lot_result$taxable_loss
        
        if (details) {
          cat(sprintf("\t\t=> Deductible loss (held < 1 year): %.2f EUR (YTD total: %.2f EUR)\n", 
                      lot_result$taxable_loss,
                      input[["totals"]][["private_sale_losses_ytd"]]))
        }
      }
      
      # ══════════════════════════════════════════════════════════════════
      
      # WICHTIG: Keine sofortige Steuer bei § 23!
      # Die Steuer wird am Jahresende in handle_year_change() berechnet.
      capital_gains_tax <- 0
    }
  }
  
  # Report aktualisieren
  calculate_sell_report(
    input = input, name = name, index = index,
    trade_count = trade_count, trade_price = trade_price,
    market_price = market_price, capital_gains_tax = capital_gains_tax
  )
  
  # FIFO-Lots aktualisieren
  if (tax_mode == "person") {
    # RCpp-Port: FIFO-Verbrauch (VP proportional VOR remaining, F9) und
    # fifo_front-Update in place (fifo_core_RCpp.cpp)
    fifo_consume_rcpp(input, name, trade_count)
  }

  # Details ausgeben
  if (details) {
    cat(sprintf("%s\tSelling %.2fx %s at %.2f EUR per share on %s\n",
                reason, trade_count, name, trade_price, current_date))
    # KORREKTUR: Prüfen ob tax_regime != "none" UND != "private_sale"
    if (tax_mode == "person" && !tax_regime %in% c("none", "private_sale")) {
      cat(sprintf("\t\t=> Trade %s: %.2f EUR; Tax: %.2f EUR\n",
                  ifelse(trade_gain < 0, "loss", "gain"), trade_gain, capital_gains_tax))
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
# C++ FUNKTIONEN (Rcpp PFLICHT)
# ═══════════════════════════════════════════════════════════════════════════════
# Die folgenden Funktionen sind ausschließlich in simulation_core.cpp
# implementiert und werden über Rcpp exportiert:
#
#   - dca_flows_allocation(input, name, flows, index)
#   - calculate_buy_report(input, name, index, trade_count, trade_price, market_price)
#   - calculate_sell_report(input, name, index, trade_count, trade_price,
#                           market_price, capital_gains_tax)
#   - calculate_total_report(input, assets, index)
#   - perform_market_update(input, assets, index)
#   - batch_market_update(input, assets, start_idx, end_idx)
#   - perform_trade_buy_cpp(input, name, index, trade_count, trade_price, market_price)
#
# Alle Funktionen modifizieren sim_mem per Referenz (C++ pass-by-reference).
# Kein Rückgabewert nötig – Aufrufe OHNE Zuweisung: func(sim_mem, ...)
#
# Bei Fehler "could not find function ..." → Paket mit Rcpp neu kompilieren:
#   R CMD INSTALL --preclean SimLev
# ═══════════════════════════════════════════════════════════════════════════════


# ============================================================
# HAUPT-SIMULATION
# ============================================================
#' @param start_value Numeric. Initial portfolio value in currency units.
#'   Default: 10000.
#'
#' @param spread Numeric. Default spread for all assets if not specified
#'   per-asset. Default: NULL (use per-asset spreads).
#'
#' @param details Logical. Print detailed transaction log during simulation.
#'   Default: FALSE.
#'
#' @param liquidate Logical. Sell all positions on the last day.
#'   Default: FALSE.
#'
#' @section DCA Parameters:
#' @param dca_mode Logical. Enable Dollar-Cost Averaging. Default: FALSE.
#' @param dca_value Numeric. Amount to invest per DCA event.
#' @param dca_span Integer. Number of periods between DCA events.
#' @param dca_days Integer. Day of month/quarter/year for DCA (1-31).
#' @param dca_unit Character. Period unit: "month", "quarter", or "year".
#' @param dca_anchor Character. Count from "start" or "end" of period.
#' @param dca_start Date. First DCA date (optional).
#' @param dca_skip Logical. Skip DCA on the first simulation day.
#' @param balance_dca Logical. Invest DCA only in underweight assets.
#'
#' @section Rebalancing Parameters:
#' @param balance_mode Logical. Enable periodic rebalancing. Default: FALSE.
#' @param balance_span Integer. Number of periods between rebalancing.
#' @param balance_days Integer. Day of month/quarter/year for rebalancing.
#' @param balance_unit Character. Period unit: "month", "quarter", or "year".
#' @param balance_anchor Character. Count from "start" or "end" of period.
#' @param balance_start Date. First rebalancing date (optional).
#' @param balance_skip Logical. Skip rebalancing on the first simulation day.
#' @param balance_thresh Numeric. Threshold for triggering rebalancing (e.g., 0.05
#'   means rebalance only if any asset deviates by more than 5% from target).
#'
#' @section Tax Parameters:
#' @param tax_mode Character. Tax calculation mode:
#'   \describe{
#'     \item{"none"}{No tax calculation}
#'     \item{"person"}{German personal tax (Abgeltungsteuer) with FIFO tracking}
#'     \item{"funds"}{Fund-level taxation (Fondsbesteuerung)}
#'   }
#' @param tax_rate Numeric. Tax rate (default: 0.26375 = 25% + 5.5% Soli).
#' @param base_rate Numeric. Base interest rate for Vorabpauschale calculation.
#' @param base_rate_flex Logical. Use time-varying base rate from data.
#' @param base_rate_data Character. Column name for base rate data.
#' @param funds_fee Numeric. Annual fund fee in percent (for tax_mode = "funds").
#' @param bonus_fee Numeric. Performance fee in percent (for tax_mode = "funds").
#'
#' @section Other Parameters:
#' @param risk_free Numeric or character. Annualized risk-free rate as a
#'   decimal (e.g. 0.03 = 3 percent p.a.), consistent with the rest of the
#'   package. Either a single number OR the name of a column in \code{data}
#'   holding a per-day annualized rate (e.g. SOFR). Each day the rate is
#'   converted to its daily equivalent and subtracted from that day's return;
#'   Sharpe and Sortino are computed on the resulting excess returns. LOCF-
#'   filled days are excluded consistently. Default: 0.
#' @param fractions Logical. Allow fractional shares. Default: TRUE.
#' @param split_mode Logical. Enable automatic split handling. Default: FALSE
#' @param split_thresh Numeric vector of length 2: c(lower, upper) price
#'   thresholds for triggering reverse/forward splits.
#'
#' @param marginal_tax_rate Numeric. Personal marginal income tax rate for 
#'   § 23 EStG taxation. Required when using deliverable ETN/ETC assets.
#'   Common values: 0.14 (minimum), 0.42 (top rate),
#'   0.45 (wealth tax). Default: NULL (will use 0.42 with warning if needed).
#'   Note: Soli is controlled via include_soli_on_income_tax / soli_rate_income_tax.
#'
#' @param private_sale_threshold Numeric. Annual tax-free threshold (Freigrenze) 
#'   for § 23 EStG gains. If total private sale gains EXCEED this amount, the 
#'   ENTIRE gain becomes taxable. Default: 1000 (since 2024, was 600 before).
#'
#' @param sparer_pauschbetrag Numeric. Annual tax-free allowance (Freibetrag) 
#'   for § 20 EStG capital gains. Unlike Freigrenze, only the amount ABOVE this 
#'   is taxed. Default: 1000 (single), use 2000 for married filing jointly.
#'
#' @param use_sparer_pauschbetrag Logical. Whether to apply the Sparerpauschbetrag.
#'   Set FALSE to simulate without tax allowance (e.g., for comparison).
#'   Default: TRUE.
#' @return An object of class "SimLevResult" containing:
#'   \describe
#'     \item{worth}{Numeric vector of daily portfolio values}
#'     \item{cagr}{Compound Annual Growth Rate}
#'     \item{ttwror}{Time-Weighted Rate of Return (annualized)}
#'     \item{drawdowns}{Numeric vector of daily drawdowns}
#'     \item{statistics}{List with mean, sd, cv, skewness, kurtosis, lpm, hpm}
#'     \item{buys}{Named vector of buy transactions per year per asset}
#'     \item{sells}{Named vector of sell transactions per year per asset}
#'     \item{report}{List of per-asset report data frames}
#'   }
#'
#' @examples
#' # Simple Buy-and-Hold simulation
#' data <- data.frame(
#'   date = seq.Date(as.Date("2020-01-01"), as.Date("2022-12-31"), by = "day"),
#'   ETF = 100 * exp(cumsum(rnorm(1096, 0.0003, 0.015)))
#' )
#'
#' strategy <- list(
#'   ETF = list(
#'     asset_class = "etf",
#'     action_type = "bnh",
#'     asset_share = 1.0,
#'     asset_spread = 0.1,
#'     asset_bonus = 0
#'   )
#' )
#'
#' result <- simulation(
#'   data = data,
#'   strategy = strategy,
#'   start_value = 10000
#' )
#'
#' print(result$cagr)
#'
#' @seealso
#' \code{\link{create_sequences}} for generating date sequences,
#' \code{\link{print.SimLevResult}} for printing results,
#' \code{\link{plot.SimLevResult}} for plotting results
#'
#' @export

simulation <- function(
    data,
    strategy,
    start_value = 10000,
    spread = NULL,
    details = FALSE,
    liquidate = FALSE,
    # DCA
    dca_mode = FALSE,
    dca_value = NULL,
    dca_span = NULL,
    dca_days = NULL,
    dca_unit = c("month", "quarter", "year"),
    dca_anchor = c("start", "end"),
    dca_start = NULL,
    dca_skip = FALSE,
    # Rebalancing
    balance_mode = FALSE,
    balance_span = NULL,
    balance_days = NULL,
    balance_unit = c("month", "quarter", "year"),
    balance_anchor = c("start", "end"),
    balance_start = NULL,
    balance_skip = FALSE,
    balance_dca = FALSE,
    balance_thresh = NULL,
    balance_thresh_type = c("absolute", "relative"),
    # =========================================
    # STEUERN (mit I3: Günstigerprüfung)
    # =========================================
    tax_mode = c("none", "person", "funds"),
    tax_rate = 26.375,
    marginal_tax_rate = NULL,
    use_guenstigerpruefung = FALSE,  # <-- NEU: I3
    private_sale_threshold = 1000,
    sparer_pauschbetrag = 1000,
    use_sparer_pauschbetrag = TRUE,
    include_soli_on_income_tax = FALSE,  # F4: Default FALSE (Soli-Freigrenze greift bei den meisten Steuerpflichtigen)
    soli_rate_income_tax = 5.5,          # F4: Soli-Satz in Prozent (5.5 = 5,5 %), nur relevant wenn include_soli_on_income_tax = TRUE
    # Basiszins
    base_rate = NULL,
    base_rate_flex = FALSE,
    base_rate_data = NULL,
    # Fonds
    funds_fee = 0.95,
    bonus_fee = 5,
    # Sonstiges
    fractions = TRUE,
    risk_free = 0,                # A-4: Risk-Free-Jahresrate (dezimal) ODER Spaltenname in data
    split_mode = FALSE,
    split_thresh = NULL,
    # === Ereignisbasiertes Rebalancing (vorberechnete Trigger-Spalte) ===
    event_col = NULL,                       # Name der TRUE/FALSE-Spalte in 'data'; NULL => rein datumsgetrieben
    event_mode = c("additional", "replace"), # 'additional' = zusaetzlich (OR) zum Kalender; 'replace' = ersetzt ihn
    event_weight = NULL                     # benannter Vektor Asset->Spaltenname mit Ziel-Gewicht je Event-Tag (optional)
) {
    # === PARAMETER-VALIDIERUNG ===
  tax_mode <- match.arg(tax_mode)
  
  # Pflichtparameter
  if (missing(data) || !is.data.frame(data)) {
    stop("'data' must be a data.frame")
  }
  if (missing(strategy) || length(strategy) == 0) {
    stop("'strategy' must be a non-empty list")
  }
  
  # start_value
  if (is.null(start_value) || is.na(start_value)) {
    start_value <- 10000
    message("Note: Using default start_value = 10000")
  }
  if (!is.numeric(start_value) || start_value <= 0) {
    stop("'start_value' must be a positive number")
  }
  
  # tax_rate
  if (!is.numeric(tax_rate) || tax_rate < 0 || tax_rate > 100) {
    stop("'tax_rate' must be between 0 and 100 percent (e.g., 26.375 for 26.375%)")
  }
  
  # marginal_tax_rate (wenn private_sale vorhanden)
  has_private_sale <- any(sapply(strategy, function(a) {
    isTRUE(a$tax_regime == "private_sale") || 
    isTRUE(a$asset_class == "etn_deliverable") ||
    (isTRUE(a$asset_class %in% c("etn", "etc")) && isTRUE(a$deliverable))
  }))
  if (has_private_sale && is.null(marginal_tax_rate)) {
    warning("'marginal_tax_rate' not set but private_sale assets present. ",
            "§ 23 EStG gains may not be taxed correctly.")
  }
  if (!is.null(marginal_tax_rate) && (marginal_tax_rate < 0 || marginal_tax_rate > 50)) {
    stop("'marginal_tax_rate' must be between 0 and 50 percent (e.g., 42 for 42%)")
  }

  # PROZENT-KONVENTION: prozentuale Nutzerangaben -> intern dezimal (/100)
  tax_rate <- tax_rate / 100
  if (!is.null(marginal_tax_rate)) marginal_tax_rate <- marginal_tax_rate / 100
  soli_rate_income_tax <- soli_rate_income_tax / 100
  if (!is.null(balance_thresh)) balance_thresh <- balance_thresh / 100  # Prozent
  # Toleranzband: "absolute" = Prozentpunkte des Gewichts (Standard, wie bisher),
  # "relative" = Prozent des Zielgewichts (z. B. 25 -> Ziel 40 % darf 30-50 % sein)
  balance_thresh_type <- match.arg(balance_thresh_type)
  # base_rate: KEINE Division hier — calculate_flat_rate teilt an der Verbrauchsstelle /100
  
  # DCA-Parameter
  if (dca_mode) {
    if (is.null(dca_value) || dca_value <= 0) {
      stop("'dca_value' must be positive when dca_mode = TRUE")
    }
    if (is.null(dca_span) || dca_span < 1) {
      stop("'dca_span' must be >= 1 when dca_mode = TRUE")
    }
  }

  # Gewichtssumme validieren
  total_weight <- sum(sapply(strategy, function(a) a$asset_share), na.rm = TRUE)
  if (abs(total_weight - 1.0) > 1e-6) {
    stop(sprintf(
      "Asset-Gewichte (asset_share) summieren sich auf %.4f, müssen aber exakt 1.0 ergeben.\n  Aktuelle Gewichte: %s",
      total_weight,
      paste(sprintf("%s=%.3f", names(strategy), sapply(strategy, function(a) a$asset_share)), collapse = ", ")
    ))
  }

  # ══════════════════════════════════════════════════════════════════════════
  # I3: GÜNSTIGERPRÜFUNG - Effektiven Steuersatz berechnen
  # ══════════════════════════════════════════════════════════════════════════
  # 
  # Die Günstigerprüfung (§ 32d Abs. 6 EStG) erlaubt es Steuerpflichtigen mit
  # niedrigem Einkommen, ihre Kapitalerträge zum persönlichen Steuersatz zu
  # versteuern statt zur Abgeltungsteuer (25%).
  #
  # Voraussetzung: Der persönliche Grenzsteuersatz muss UNTER 25% liegen.
  # 
  # Berechnung des effektiven Steuersatzes:
  # - Bei Günstigerprüfung: marginal_tax_rate * (1 + Soli-Faktor)
  # - Ohne Günstigerprüfung: 0.26375 (25% + 5.5% Soli)
  # ══════════════════════════════════════════════════════════════════════════

  effective_tax_rate <- tax_rate  # Default: 26.375%

  if (use_guenstigerpruefung) {
    if (is.null(marginal_tax_rate)) {
      warning(
        "Günstigerprüfung aktiviert, aber 'marginal_tax_rate' nicht gesetzt.\n",
        "Verwende Standard-Abgeltungsteuer (", round(tax_rate * 100, 2), "%).\n",
        "Setze 'marginal_tax_rate' für korrekte Günstigerprüfung.",
        call. = FALSE
      )
    } else if (marginal_tax_rate < 0.25) {
      # Günstigerprüfung greift: Persönlicher Steuersatz ist niedriger
      soli_factor <- if (include_soli_on_income_tax) (1 + soli_rate_income_tax) else 1.0
      effective_tax_rate <- marginal_tax_rate * soli_factor
      
      if (details) {
        cat(sprintf(
          "═══ Günstigerprüfung aktiv ═══\n  Persönlicher Steuersatz: %.2f%%\n  Effektiver Steuersatz: %.2f%% (statt %.2f%% Abgeltungsteuer)\n  Ersparnis: %.2f Prozentpunkte\n\n",
          marginal_tax_rate * 100, effective_tax_rate * 100, tax_rate * 100,
          (tax_rate - effective_tax_rate) * 100
        ))
      }
    } else {
      # Persönlicher Steuersatz >= 25%, Abgeltungsteuer bleibt günstiger
      if (details) {
        cat(sprintf(
          "═══ Günstigerprüfung geprüft ═══\n  Persönlicher Steuersatz: %.2f%%\n  Abgeltungsteuer: %.2f%% → bleibt günstiger\n\n",
          marginal_tax_rate * 100, tax_rate * 100
        ))
      }
    }
  }
  # ══════════════════════════════════════════════════════════════════════════

  # F4: Soli-Faktor für ESt-Berechnungen (§ 23, Günstigerprüfung)
  soli_factor_income <- if (include_soli_on_income_tax) (1 + soli_rate_income_tax) else 1.0

  #----------------------------> Vorbereitung und Strukturierung von Datenobjekten:
  start_date <- head(data[, "date"], 1)
  stopp_date <- tail(data[, "date"], 1)
  
  # P-3: Lueckenhafte Handelstag-Daten automatisch auf Kalenderraster auffuellen
  # (LOCF fuer numerische Spalten; logische Signal-Spalten -> FALSE).
  expected_days <- as.numeric(difftime(stopp_date, start_date, units = "days")) + 1
  if (nrow(data) != expected_days) {
    message(sprintf(
      "Hinweis: %d Zeilen, erwartet %d Kalendertage. Fehlende Tage werden aufgefuellt (LOCF; Signale = FALSE).",
      nrow(data), expected_days))
    .locf_fill <- function(v) {
      non_na <- which(!is.na(v))
      if (length(non_na) == 0L) return(v)
      idx <- integer(length(v)); idx[non_na] <- non_na
      idx <- cummax(idx)
      idx[idx == 0L] <- non_na[1]          # fuehrende NAs rueckwaerts fuellen
      v[idx]
    }
    all_dates <- seq.Date(as.Date(start_date), as.Date(stopp_date), by = "day")
    data$.filled <- FALSE
    data <- merge(data.frame(date = all_dates), data, by = "date", all.x = TRUE)
    data$.filled[is.na(data$.filled)] <- TRUE   # A-2: aufgefuellte Tage markieren
    num_cols <- setdiff(names(data)[vapply(data, is.numeric, logical(1))], "date")
    for (cc in num_cols) data[[cc]] <- .locf_fill(data[[cc]])
    lgl_cols <- names(data)[vapply(data, is.logical, logical(1))]
    for (cc in lgl_cols) data[[cc]][is.na(data[[cc]])] <- FALSE
  }

  #--------> Initialisierung der Speicher-Objekte:
  sim_mem <- list(
    assets = setNames(vector("list", length = length(strategy)), names(strategy)),
    status = setNames(vector("list", length = length(strategy)), names(strategy)),
    market = setNames(vector("list", length = length(strategy)), names(strategy)),
    trades = setNames(vector("list", length = length(strategy)), names(strategy)),
    report = setNames(vector("list", length = length(strategy)), names(strategy)),
    # === NEU: Erweiterte Totals-Struktur ===
    totals = list(
      total_value = start_value,
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
      cgt_loss_used_ytd = 0
    )
    # === Ende neu ===
  )

  for(name in names(strategy)){
    #---> Initialisierung des Assets-Objekts:
    sim_mem[["assets"]][[name]] <- list(
      class = strategy[[name]][["asset_class"]],
      style = strategy[[name]][["action_type"]],
      start = as.Date(strategy[[name]][["asset_start"]] %||% start_date),
      tax_regime = strategy[[name]][["tax_regime"]] %||% switch(strategy[[name]][["asset_class"]],
        "etf" = "investment_fund",
        "etn" = if (isTRUE(strategy[[name]][["deliverable"]])) "private_sale" else "capital_gains",
        "etc" = if (isTRUE(strategy[[name]][["deliverable"]])) "private_sale" else "capital_gains",
        "certificate" = "capital_gains",
        "etn_standard" = "capital_gains",
        "etn_deliverable" = "private_sale",
        "capital_gains"),
      bonus = (strategy[[name]][["asset_bonus"]] %||% 0) / 100,   # PROZENT-KONVENTION
      deliverable = strategy[[name]][["deliverable"]] %||% FALSE
    )

    # P-2: Signal-Spalten validieren (nur fuer action_type = "signal")
    if (identical(strategy[[name]][["action_type"]], "signal")) {
      sb <- strategy[[name]][["signal_buy"]]
      ss <- strategy[[name]][["signal_sell"]]
      if (is.null(sb) || !sb %in% names(data))
        stop(sprintf("simulation: signal_buy-Spalte '%s' fehlt im Datensatz (Asset '%s').", sb %||% "NULL", name))
      if (is.null(ss) || !ss %in% names(data))
        stop(sprintf("simulation: signal_sell-Spalte '%s' fehlt im Datensatz (Asset '%s').", ss %||% "NULL", name))
    }

    #---> Initialisierung des Status-Objekts: (Das war mal ein Vektor!!!!)
    sim_mem[["status"]][[name]] <- list(
      count = 0,
      price = 0,
      worth = 0,
      money = strategy[[name]][["asset_share"]] * start_value,
      total = strategy[[name]][["asset_share"]] * start_value,
      target = strategy[[name]][["asset_share"]],
      actual = strategy[[name]][["asset_share"]],
      differ = 0
    )

    #---> Initialisierung des Market-Objekts:
    sim_mem[["market"]][[name]] <- list(
      asset_day = seq.Date(
        from = as.Date(start_date),
        to = as.Date(stopp_date),
        by = "days"),
      base_rates = if (base_rate_flex) {
  if (is.null(base_rate_data) || !base_rate_data %in% names(data)) {
    stop("base_rate_data column '", base_rate_data, "' not found in data")
  }
  br <- data[[base_rate_data]]
  br[is.na(br)] <- 0  # NA durch 0 ersetzen
  br
} else {
  # BUG-1 FIX: Vektor statt Skalar, damit Index-Zugriff in calculate_flat_rate() funktioniert
  rep(base_rate %||% 0, nrow(data))
},
      asset_price = data[[name]],
      signal_buy = if (is.null(strategy[[name]][["signal_buy"]])) rep(FALSE, nrow(data)) else data[[strategy[[name]][["signal_buy"]]]],
      signal_sell = if (is.null(strategy[[name]][["signal_sell"]])) rep(FALSE, nrow(data)) else data[[strategy[[name]][["signal_sell"]]]],
      spread_rate = (strategy[[name]][["asset_spread"]] %||% 0) / 100   # PROZENT-KONVENTION
    )

    #---> Initialisierung des Trade-Objekts:
    max_trades <- nrow(data)
    sim_mem[["trades"]][[name]] <- list(
      buys = vector("list", max_trades),
      buy_count = 0,
      sells = vector("list", max_trades),
      sell_count = 0,
      taxes = vector("list", max_trades),
      tax_count = 0,
      fees = vector("list", max_trades),
      fee_count = 0,
      fifo_front = 1
    )

    #---> Initialisierung des Report-Objekts:
    sim_mem[["report"]][[name]] <- list(
      worth = c(sim_mem[["status"]][[name]][["worth"]], numeric(nrow(data)-1)),
      money = c(sim_mem[["status"]][[name]][["money"]], numeric(nrow(data)-1)),
      flows = numeric(nrow(data)),
      total = c(sim_mem[["status"]][[name]][["total"]], numeric(nrow(data)-1)),
      share = numeric(nrow(data))  # Wird durch calculate_total_report am Tag 1 korrekt gesetzt
    )
  }

  #--------> Initialisierung der Flag-Objekte:
  flag_date <- seq.Date(from = as.Date(start_date), to = as.Date(stopp_date), by = "days")
  # A-2: Markierung aufgefuellter (LOCF) Tage, aligned zu flag_date
  flag_filled <- if (".filled" %in% names(data)) {
    .f <- as.logical(data[[".filled"]]); .f[is.na(.f)] <- TRUE; .f
  } else rep(FALSE, length(flag_date))
  data[[".filled"]] <- NULL
  flag_assets <- names(strategy)
  flag_liquidate <- liquidate & (flag_date == stopp_date)
  flag_rebalance <- calculate_dates_flags(mode = balance_mode, span = balance_span, unit = balance_unit, days = balance_days, dates = flag_date, anchor = balance_anchor, start_date = balance_start, skip_start = balance_skip, liquidate = liquidate)
  flag_dca <- calculate_dates_flags(mode = dca_mode, span = dca_span, unit = dca_unit, days = dca_days, dates = flag_date, value = dca_value, anchor = dca_anchor, start_date = dca_start, skip_start = dca_skip, liquidate = liquidate)
  flag_taxes <- (format(flag_date, "%m-%d") == "12-31")
  # === NEU: Ereignisbasiertes Rebalancing-Flag aus vorberechneter Spalte ===
  # Default (event_col = NULL): Verhalten unveraendert datumsgetrieben.
  # Da flag_rebalance in flag_definite -> flag_slow_path einfliesst, werden
  # Event-Tage automatisch zu Slow-Path-Tagen (volle Event-Verarbeitung).
  event_mode <- match.arg(event_mode)
  flag_event <- rep(FALSE, length(flag_date))
  if (!is.null(event_col)) {
    if (is.null(data[[event_col]]))
      stop(sprintf("simulation: event_col '%s' nicht im Datensatz gefunden.", event_col))
    flag_event <- as.logical(data[[event_col]])
    flag_event[is.na(flag_event)] <- FALSE
    # gleiche Schutzregeln wie der Kalender-Trigger: kein Rebalancing am
    # Einstiegstag und (bei liquidate) nicht am Liquidationstag.
    guard <- (flag_date != flag_date[1]) & (!liquidate | flag_date != stopp_date)
    flag_event <- flag_event & guard
    if (event_mode == "additional") {
      flag_rebalance <- flag_rebalance | flag_event   # zusaetzlich (OR)
    } else {
      flag_rebalance <- flag_event                    # anstelle
    }
  }

  flag_trade <- !flag_rebalance & (flag_date != stopp_date) & !flag_filled
  flag_split <- calculate_split_flags(input = sim_mem, base = 100, mode = split_mode, dates = flag_date, split_thresh = split_thresh)

  # V-1b: Verschiebe-Helfer (naechster Handelstag; am Monatsende vorziehen)
  .shift_off_filled <- function(flags, filled, dates){
    hit <- which(flags & filled)
    if(!length(hit)) return(flags)
    n <- length(flags); mon <- format(dates, "%Y-%m")
    for(i in hit){
      j <- i + 1L
      while(j <= n && filled[j]) j <- j + 1L
      if(j > n || mon[j] != mon[i]){          # Monatsende: vorziehen
        j <- i - 1L
        while(j >= 1L && filled[j]) j <- j - 1L
      }
      flags[i] <- FALSE
      if(j >= 1L && j <= n) flags[j] <- TRUE
    }
    flags
  }
  if(any(flag_filled)){
    flag_rebalance <- .shift_off_filled(flag_rebalance, flag_filled, flag_date)
    flag_dca       <- .shift_off_filled(flag_dca,       flag_filled, flag_date)
    flag_split     <- .shift_off_filled(flag_split,     flag_filled, flag_date)
    flag_liquidate <- .shift_off_filled(flag_liquidate, flag_filled, flag_date)
    flag_trade     <- !flag_rebalance & (flag_date != stopp_date) & !flag_filled   # neu ableiten
  }

  #--------> Initialisierung der Startgewichte bei Non-Tradeble Assets:
  initial_assets <- flag_assets[sapply(flag_assets, function(name){
    trade_start <- sim_mem[["assets"]][[name]][["start"]] 
    (trade_start %||% flag_date[1]) <= flag_date[1]
  })]

  initial_weights_sum <- sum(sapply(initial_assets, function(name) sim_mem[["status"]][[name]][["actual"]]))

  for(name in flag_assets){
    if(name %in% initial_assets){
      normalized_weight <- sim_mem[["status"]][[name]][["actual"]] / initial_weights_sum
      sim_mem[["status"]][[name]][["actual"]] <- normalized_weight
      sim_mem[["status"]][[name]][["money"]]  <- start_value * normalized_weight
      sim_mem[["status"]][[name]][["total"]]  <- start_value * normalized_weight
    } else {
      sim_mem[["status"]][[name]][["differ"]] <- 0
      sim_mem[["status"]][[name]][["money"]]  <- 0
      sim_mem[["status"]][[name]][["total"]]  <- 0
    }
  }

  asset_starts <- as.Date(vapply(flag_assets, function(name) as.numeric(sim_mem[["assets"]][[name]][["start"]] %||% flag_date[1]), numeric(1)), origin = "1970-01-01")
  if(any(flag_filled)){
    asset_starts <- as.Date(vapply(asset_starts, function(d){
      i <- match(d, flag_date)
      if(is.na(i) || !flag_filled[i]) return(as.numeric(d))
      n <- length(flag_date); mon <- format(flag_date, "%Y-%m")
      j <- i + 1L
      while(j <= n && flag_filled[j]) j <- j + 1L
      if(j > n || mon[j] != mon[i]){
        j <- i - 1L
        while(j >= 1L && flag_filled[j]) j <- j - 1L
      }
      as.numeric(flag_date[max(min(j, n), 1L)])
    }, numeric(1)), origin = "1970-01-01")
  }
  flag_active <- flag_date %in% asset_starts

  # P1: Statt 1826 identische Kopien vorallokieren, Startindizes speichern
  # und active_assets im Slow-Path inline berechnen
  asset_start_indices <- match(asset_starts, flag_date)
  asset_start_indices[is.na(asset_start_indices)] <- 1L






  # 1. Definitive Events (kalenderbasiert, unabhängig von Strategie)
  flag_definite <- flag_active | flag_split | flag_dca | flag_rebalance | flag_taxes | flag_liquidate

  # 2. Strategie-Typen identifizieren
  strategy_types <- sapply(flag_assets, function(name) sim_mem[["assets"]][[name]][["style"]])
  has_bnh <- any(strategy_types == "bnh")
  has_signal <- any(strategy_types == "signal")

  # P6: Tax-Regime einmal pro Asset vorberechnen (statisch, ändert sich nie)
  tax_regimes <- sapply(flag_assets, function(name) sim_mem[["assets"]][[name]][["tax_regime"]])
  # O-2: Spread-Raten einmalig vorberechnen (statt wiederholter Lookups)
  spread_rates <- sapply(flag_assets, function(name) sim_mem[["market"]][[name]][["spread_rate"]])

  # § 18 Abs. 3 InvStG: begleicht eine festgesetzte Vorabpauschale (Fall A: Cash,
  # Fall B: Zwangsverkauf) zu den Kursen von flag_date[time] und verbucht den Entry.
  .pay_vp <- function(sim_mem, name, tax_debt, time, meta) {
    tax_regime <- tax_regimes[[name]]
    if (sim_mem[["status"]][[name]][["money"]] >= tax_debt) {
      sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] - tax_debt
      sim_mem[["totals"]][["total_taxes"]] <- sim_mem[["totals"]][["total_taxes"]] + tax_debt
      if (details) {
        cat(sprintf("Tax Event:\tPaying Vorabpauschale of %.2f EUR for %s from cash on %s\n",
                    tax_debt, name, flag_date[time]))
      }
    } else {
      remaining_tax <- tax_debt
      if (sim_mem[["status"]][[name]][["money"]] > 0) {
        cash_used <- sim_mem[["status"]][[name]][["money"]]
        remaining_tax <- tax_debt - cash_used
        sim_mem[["status"]][[name]][["money"]] <- 0
        if (details) {
          cat(sprintf("Tax Event:\tUsing %.2f EUR cash for partial Vorabpauschale payment on %s\n",
                      cash_used, flag_date[time]))
        }
      }
      if (remaining_tax > 0) {
        sell_result <- calculate_sell_count(
          input = sim_mem, name = name, target = remaining_tax, index = time,
          spread = spread_rates[[name]], fractions = fractions,
          tax_mode = tax_mode, tax_rate = tax_rate,
          marginal_tax_rate = marginal_tax_rate, tax_regime = tax_regime)
        sim_mem <- perform_trade_sell(
          input = sim_mem, count = sell_result[["sell_count"]],
          price = sell_result[["fifo_price"]], name = name, index = time,
          tax_mode = tax_mode, tax_rate = tax_rate,
          effective_tax_rate = effective_tax_rate,
          marginal_tax_rate = marginal_tax_rate,
          private_sale_threshold = private_sale_threshold,
          use_sparer_pauschbetrag = use_sparer_pauschbetrag,
          tax_regime = tax_regime, reason = "Tax Event:",
          spread = spread_rates[[name]], details = details)
        sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] - remaining_tax
        if (details) {
          cat(sprintf("\t\t=> Sold shares to pay remaining %.2f EUR Vorabpauschale\n", remaining_tax))
        }
      }
      sim_mem[["totals"]][["total_taxes"]] <- sim_mem[["totals"]][["total_taxes"]] + tax_debt
      if (sim_mem[["status"]][[name]][["money"]] < 0) sim_mem[["status"]][[name]][["money"]] <- 0
    }
    trades_entry <- list(
      event_date = flag_date[time],
      assessment_date = meta[["assessment_date"]],
      event_type = "Vorabpauschale",
      flat_rate_gross = meta[["flat_rate"]],
      bonus_applied = meta[["bonus"]],
      flat_rate_taxable = meta[["flat_rate"]] * (1 - meta[["bonus"]]),
      spb_used = meta[["spb_used"]],
      taxes_paid = tax_debt
    )
    sim_mem[["trades"]][[name]][["tax_count"]] <- sim_mem[["trades"]][[name]][["tax_count"]] + 1
    sim_mem[["trades"]][[name]][["taxes"]][[sim_mem[["trades"]][[name]][["tax_count"]]]] <- trades_entry
    sim_mem
  }

  # 3. Signale aus Daten extrahieren (statisch, vorberechnet)
  flag_signal <- rep(FALSE, length(flag_date))

  if(has_signal){
    for(name in flag_assets){
      if(sim_mem[["assets"]][[name]][["style"]] == "signal"){
        # Asset-spezifische Signale
        buy_signal <- sim_mem[["market"]][[name]][["signal_buy"]]
        sell_signal <- sim_mem[["market"]][[name]][["signal_sell"]]
      
        # Kombinieren (TRUE wenn eines der Signale TRUE)
        flag_signal <- flag_signal | buy_signal | sell_signal
      }
    }
  }

  # 4. BnH-Potenzial (nur Tag 1, danach übernimmt DCA)
  #    Bei BnH OHNE DCA: Nur Tag 1 ist relevant (danach immer investiert)
  #    Bei BnH MIT DCA: Tag 1 + DCA-Tage (in flag_definite bereits enthalten)
  flag_bnh_potential <- rep(FALSE, length(flag_date))

  if(has_bnh){
    flag_bnh_potential[1] <- TRUE
  # Weitere Tage nicht nötig! DCA-Tage sind bereits in flag_definite
  }

  # 5. Kombiniertes Slow-Path Flag
  flag_slow_path <- flag_definite | flag_signal | flag_bnh_potential
  

  # ═══════════════════════════════════════════════════════════════════════════════
  # 7. PERFORMANCE-OPTIMIERUNG: Vorberechnung der Individual-Processing-Tage
  # ═══════════════════════════════════════════════════════════════════════════════
  # Statt jeden Tag einzeln zu durchlaufen, identifizieren wir Tage die 
  # individuelle Verarbeitung brauchen (Slow-Path, Jahreswechsel).
  # Zusammenhängende Blöcke dazwischen werden per batch_market_update() in C++
  # vektorisiert verarbeitet (~10-50x schneller als einzelne R-Aufrufe).
  
  # Jahreswechsel-Flag vorberechnen (statt format() auf jedem Tag)
  flag_year_change <- rep(FALSE, length(flag_date))
  flag_vp_settle   <- rep(FALSE, length(flag_date))   # erster Handelstag je neuen Jahres
  if (tax_mode == "person") {
    date_years <- as.integer(format(flag_date, "%Y"))
    flag_year_change <- c(FALSE, diff(date_years) > 0L)
    for (ys in which(flag_year_change)) {
      j <- ys
      while (j <= length(flag_date) && flag_filled[j]) j <- j + 1L
      if (j <= length(flag_date)) flag_vp_settle[j] <- TRUE
    }
  }
  
  # Kombiniertes Flag: Alle Tage die individuelle Verarbeitung brauchen
  flag_slow_path  <- flag_slow_path | flag_vp_settle   # Faelligkeitstage voll verarbeiten (kein Fast-Path-next)
  flag_individual <- flag_slow_path | flag_year_change
  individual_days <- which(flag_individual)
  n_total_days <- nrow(data)
  
  # ═══════════════════════════════════════════════════════════════════════════════
  # BLOCK-BASIERTE HAUPTSCHLEIFE
  # ═══════════════════════════════════════════════════════════════════════════════
  
  prev_end <- 0L
  active_assets <- character(0)   # O-3: nur an Aktivierungstagen neu berechnet
  
  for (sd_pos in seq_along(individual_days)) {
    time <- individual_days[sd_pos]
    
    # ─────────────────────────────────────────────────────────────────────────
    # BATCH: Zusammenhängende Fast-Path-Tage vor diesem Individual-Tag
    # → Ein einzelner C++ Aufruf statt hunderte R-Iterationen
    # ─────────────────────────────────────────────────────────────────────────
    if (time > prev_end + 1L) {
      batch_market_update(sim_mem, flag_assets, prev_end + 1L, time - 1L)
    }
    
    # ─────────────────────────────────────────────────────────────────────────
    # INDIVIDUAL-TAG: Jahreswechsel, dann ggf. Slow-Path
    # ─────────────────────────────────────────────────────────────────────────
    
    # === Jahreswechsel prüfen (nur an Tagen wo das Jahr wechselt) ===
    if (flag_year_change[time]) {
      sim_mem <- handle_year_change(
        input = sim_mem,
        current_date = flag_date[time],
        marginal_tax_rate = marginal_tax_rate,
        private_sale_threshold = private_sale_threshold,
        sparer_pauschbetrag = sparer_pauschbetrag,
        use_sparer_pauschbetrag = use_sparer_pauschbetrag,
        soli_factor_income = soli_factor_income,
        effective_tax_rate = effective_tax_rate,
        details = details
      )
    }
    
    # === Wenn kein Slow-Path → nur Market-Update (C++) ===
    if (!flag_slow_path[time]) {
      perform_market_update(sim_mem, flag_assets, time)
      prev_end <- time
      next
    }
    
    # ─────────────────────────────────────────────────────────────────────────
    # SLOW-PATH: Volle Event-Verarbeitung
    # ─────────────────────────────────────────────────────────────────────────
    if (flag_active[time] || length(active_assets) == 0L) {
      active_assets <- flag_assets[asset_start_indices <= time]   # O-3: Cache-Update
    }
    flag_fast_report <- TRUE

    #--------> Implementierung von Asset-Aktivierung:
    if(flag_active[time]){
      for(name in setdiff(flag_assets, active_assets)){
        sim_mem[["market"]][[name]][["signal_buy"]][time] <- FALSE
        sim_mem[["market"]][[name]][["signal_sell"]][time] <- FALSE
      }

      if(balance_mode){
        current_weights_sum <- sum(sapply(active_assets, function(name) sim_mem[["status"]][[name]][["actual"]]))

        for(name in active_assets){sim_mem[["status"]][[name]][["differ"]] <- sim_mem[["status"]][[name]][["actual"]] / current_weights_sum}

        if(details){
          new_assets <- flag_assets[asset_starts == flag_date[time]]
          if(length(new_assets)) cat(sprintf("Market Event:\tActive trading of %s now enabled.\n", paste(new_assets, collapse = ", ")))
        }

        flag_rebalance[time] <- TRUE
      }

      calculate_total_report(input = sim_mem, assets = flag_assets, index = time)
      flag_fast_report <- FALSE
    }

    #--------> Implementierung von Splits und Reverse Splits:
    if(flag_split[time]){
      for(name in active_assets){
        if(sim_mem[["status"]][[name]][["count"]] > 0){
          split_price <- sim_mem[["market"]][[name]][["asset_price"]][time]

          if(split_price > split_thresh[[2]]){
            sim_mem <- perform_asset_split(input = sim_mem, name = name, ratio = split_price / 100,
                                           type = "forward", index = time,                                        
   fractions = fractions,
   details = details,
  current_date = flag_date[time]
            )
          }

          if(split_price < split_thresh[[1]]){
            sim_mem <- perform_asset_split(input = sim_mem, name = name, ratio = 100 / split_price,
                                           type = "reverse", index = time,                                        
   fractions = fractions,
   details = details,
  current_date = flag_date[time]
            )
          }
        }
      }

      calculate_total_report(input = sim_mem, assets = flag_assets, index = time)
      flag_fast_report <- FALSE
    }

    #--------> Implementierung von Dollar-Cost-Averaging:
    if(flag_dca[time]){
      # R-1: DCA-Verteilung nach STRATEGIE-Gewichten (asset_share), renormiert
      # ueber die derzeit aktiven Assets (inkl. Cash-Reserven signalbedingt
      # wartender (aktivierter!) Signal-Assets — Gleichbehandlung nach Zielgewicht). Ohne balance_dca:
      # fixer Split (70:30 bleibt 70:30, egal wie das Depot driftet).
      strat_w <- sapply(active_assets, function(name) strategy[[name]][["asset_share"]])
      strat_w <- strat_w / sum(strat_w, na.rm = TRUE)

      if(balance_dca && length(active_assets) > 1){
        # R-1 (balance_dca): Rate schliesst zuerst die WERT-Defizite zu den
        # Strategie-Zielen (Rebalancing-Wirkung); ein etwaiger Rest wird nach
        # Strategie-Gewichten verteilt.
        totals_now <- sapply(active_assets, function(name) sim_mem[["status"]][[name]][["total"]])
        desired    <- strat_w * (sum(totals_now, na.rm = TRUE) + dca_value)
        deficit    <- pmax(0, desired - totals_now)
        alloc <- if (sum(deficit) > dca_value) {
          dca_value * deficit / sum(deficit)
        } else {
          deficit + (dca_value - sum(deficit)) * strat_w
        }
        alloc <- setNames(as.numeric(alloc), active_assets)
        for(name in active_assets){
          dca_flows_allocation(input = sim_mem, name = name, flows = alloc[[name]], index = time)
        }
      } else {
        for(name in active_assets){
          dca_flows_allocation(input = sim_mem, name = name, flows = strat_w[[name]] * dca_value, index = time)
        }
      }
      if(details){
        flow_values <- sapply(active_assets, function(name) sim_mem[["report"]][[name]][["flows"]][time])
        placeholder <- paste(sprintf("%s %%.2f EUR", names(flow_values)), collapse = "; ")
        format_text <- sprintf("Transferring:\tDepositing %%.2f EUR to brokerage account on %%s\n\t\t=> %s\n", placeholder)
        cat(do.call(sprintf, c(list(format_text, dca_value), list(flag_date[time]), as.list(flow_values))))
      }

      calculate_total_report(input = sim_mem, assets = flag_assets, index = time)
      flag_fast_report <- FALSE
    }

    #--------> Implementierung von Trading-Aktionen:
    if(flag_trade[time]){
      trade_event <- FALSE

      for(name in active_assets){   # P-1/O-1: nur aktive Assets handeln
        flag_buy <- calculate_buy_signal(input = sim_mem, name = name, index = time)
        flag_sell <- calculate_sell_signal(input = sim_mem, name = name, index = time)

        if(flag_buy){
          sim_mem <- perform_trade_buy(input = sim_mem, name = name, index = time, reason = "Trade Event:", spread = spread_rates[[name]], fractions = fractions, details = details)
          trade_event <- TRUE
        }

        if(flag_sell){
          sim_mem <- perform_trade_sell(input = sim_mem, name = name, index = time, tax_mode = tax_mode, tax_rate = tax_rate,
            effective_tax_rate = effective_tax_rate,
            marginal_tax_rate = marginal_tax_rate,
            private_sale_threshold = private_sale_threshold,
            use_sparer_pauschbetrag = use_sparer_pauschbetrag,
            tax_regime = tax_regimes[[name]],
            reason = "Trade Event:", spread = spread_rates[[name]], details = details)
          trade_event <- TRUE
        }
      }

      if(trade_event){
        calculate_total_report(input = sim_mem, assets = flag_assets, index = time)
        flag_fast_report <- FALSE
      }
    }

    #--------> Implementierung von Rebalancing-Aktionen:
    if(flag_rebalance[time]){
      active_targets <- sapply(active_assets, function(name){sim_mem[["status"]][[name]][["actual"]]})
      active_targets <- active_targets / sum(active_targets, na.rm = TRUE)

      # === NEU: ereignisgetriebene Ziel-Gewichte ueberschreiben (nur an Event-Tagen) ===
      # Greift nur, wenn event_weight gesetzt ist UND dieser Tag ein Event-Tag ist.
      # Veraendert ausschliesslich das lokale Ziel-Gewicht dieses Rebalancing-Laufs,
      # nicht die status-Buchhaltung. Die Band-/Gewichts-Logik bleibt im Datensatz.
      if (!is.null(event_weight) && isTRUE(flag_event[time])) {
        ow <- sapply(active_assets, function(nm){
          col <- event_weight[[nm]]
          if (is.null(col)) NA_real_ else as.numeric(data[[col]][time])
        })
        if (all(is.finite(ow)) && sum(ow) > 0) {
          active_targets <- ow / sum(ow)
          names(active_targets) <- active_assets
        }
      }

      # V-2/Fix 3: Signal-Gate (Cash-Reserve-Design, siehe Notiz im Patcher)
      signal_cash_only <- character(0)
      for(name in active_assets){
        if(sim_mem[["assets"]][[name]][["style"]] == "signal"){
          .has_pos  <- sim_mem[["status"]][[name]][["count"]] > 0
          .sig_buy  <- isTRUE(sim_mem[["market"]][[name]][["signal_buy"]][time])
          .sig_sell <- isTRUE(sim_mem[["market"]][[name]][["signal_sell"]][time])
          if(.has_pos && .sig_sell){
            sim_mem <- perform_trade_sell(input = sim_mem, name = name, index = time,
              tax_mode = tax_mode, tax_rate = tax_rate,
              effective_tax_rate = effective_tax_rate,
              marginal_tax_rate = marginal_tax_rate,
              private_sale_threshold = private_sale_threshold,
              use_sparer_pauschbetrag = use_sparer_pauschbetrag,
              tax_regime = tax_regimes[[name]],
              reason = "Rebalancing/Signal-Exit:",
              spread = spread_rates[[name]], details = details)
            signal_cash_only <- c(signal_cash_only, name)
          } else if(!.has_pos && .sig_buy){
            # Signal-Entry aus der eigenen Cash-Reserve; danach normale Teilnahme
            sim_mem <- perform_trade_buy(input = sim_mem, name = name, index = time,
              reason = "Rebalancing/Signal-Entry:",
              spread = spread_rates[[name]], fractions = fractions, details = details)
          } else if(!.has_pos && !.sig_buy){
            signal_cash_only <- c(signal_cash_only, name)
          }
        }
      }

      # Gleichbehandlung: Ist-Gewichte total-basiert (worth+money) fuer ALLE
      actual_weights <- sapply(active_assets, function(name){sim_mem[["status"]][[name]][["differ"]]})

      new_asset <- any(asset_starts == flag_date[time])
      force_rebalance <- new_asset

      if(force_rebalance && details){
        new_assets <- flag_assets[asset_starts == flag_date[time]]
        cat(sprintf("Rebalancing:\tForcing rebalance on %s due to new asset activation: %s\n",
            flag_date[time], paste(new_assets, collapse = ", ")))
      }

      event_rebalance <- FALSE

      if(force_rebalance){
        event_rebalance <- TRUE
      } else if(is.null(balance_thresh)){
        event_rebalance <- TRUE
      } else {
        deviations <- if (balance_thresh_type == "relative") {
          abs(actual_weights / active_targets - 1)
        } else {
          abs(active_targets - actual_weights)
        }
        max_deviation <- max(deviations, na.rm = TRUE)
        event_rebalance <- (max_deviation > balance_thresh)

        if(details){
          if(event_rebalance){
            cat(sprintf("Rebalancing:\tExecuting rebalancing on %s (max deviation: %.2f%% > threshold: %.2f%%)\n",
                flag_date[time], max_deviation * 100, balance_thresh * 100))

            for(i in seq_along(active_assets)){
              name <- active_assets[i]
              dev <- deviations[i]
              
              if(dev > balance_thresh){
                cat(sprintf("\t\t=> %s: target=%.1f%%, actual=%.1f%%, deviation=%.2f%%\n",
                    name, active_targets[i]*100, actual_weights[i]*100, dev*100))
              }
            }
          } else {
            cat(sprintf("Rebalancing:\tSkipping rebalancing on %s (max deviation: %.2f%% < threshold: %.2f%%)\n",
                flag_date[time], max_deviation * 100, balance_thresh * 100))
            }
          }
        }

        if(event_rebalance){
          differ_weights <- active_targets - actual_weights
          total_strategy <- sum(sapply(sim_mem[["status"]][active_assets], function(x) x[["total"]]), na.rm = TRUE)

          transfer_pool <- 0
          transfer_value <- abs(differ_weights * total_strategy)

          # ════════════════════════════════════════════════════════════════
          # BUG-4/5 FIX: Rebalancing ohne Signal-Abhängigkeit,
          # korrekte Richtung: differ < 0 = übergewichtet → verkaufen,
          #                    differ > 0 = untergewichtet → kaufen
          # ════════════════════════════════════════════════════════════════
          
          # PHASE 1: Übergewichtete Assets verkaufen → Pool aufbauen
          for(name in names(differ_weights[differ_weights < 0])){
            if(sim_mem[["status"]][[name]][["count"]] > 0){
              sell_result <- calculate_sell_count(
                input = sim_mem, name = name, target = transfer_value[name], 
                index = time, spread = spread_rates[[name]], 
                fractions = fractions, tax_mode = tax_mode, tax_rate = tax_rate,
                marginal_tax_rate = marginal_tax_rate,
                tax_regime = tax_regimes[[name]])
              
              sim_mem <- perform_trade_sell(
                input = sim_mem, name = name, 
                count = sell_result[["sell_count"]], 
                price = sell_result[["fifo_price"]], 
                index = time, tax_mode = tax_mode, tax_rate = tax_rate,
                effective_tax_rate = effective_tax_rate,
                marginal_tax_rate = marginal_tax_rate,
                private_sale_threshold = private_sale_threshold,
                use_sparer_pauschbetrag = use_sparer_pauschbetrag,
                tax_regime = tax_regimes[[name]],
                reason = "Rebalancing:", 
                spread = spread_rates[[name]], details = details)
            }
            
            # Cash aus diesem Asset in den Transfer-Pool
            available_cash <- min(sim_mem[["status"]][[name]][["money"]], transfer_value[name])
            transfer_pool <- transfer_pool + available_cash
            sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] - available_cash
            
            if(details){
              cat(sprintf("\t\tDepositing %.2f EUR from %s to rebalancing pool\n", 
                          available_cash, name))
            }
          }
          
          # PHASE 2: Untergewichtete Assets kaufen → Pool verbrauchen
          for(name in names(differ_weights[differ_weights > 0])){
            allocation <- min(transfer_value[name], transfer_pool)
            if(allocation > 0){
              sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] + allocation
              transfer_pool <- transfer_pool - allocation
              
              if(details){
                cat(sprintf("Rebalancing:\tWithdrawing %.2f EUR from pool to %s\n", 
                            allocation, name))
              }
              
              if (name %in% signal_cash_only) {
                # Fix 3: signalbedingt wartendes Signal-Asset — Zielgewicht als CASH-Reserve
                # auffuellen, KEIN Aktienkauf (Pool wurde damit um den Betrag
                # des inaktiven Assets reduziert).
                if(details){
                  cat(sprintf("\t\t=> %s haelt %.2f EUR als Cash-Reserve (Signal inaktiv)\n",
                              name, sim_mem[["status"]][[name]][["money"]]))
                }
              } else {
                sim_mem <- perform_trade_buy(
                  input = sim_mem, name = name, index = time,
                  reason = "Rebalancing:",
                  spread = spread_rates[[name]],
                  fractions = fractions, details = details)
              }
            }
          }

          # Restliches Cash im Pool proportional verteilen
          if(transfer_pool > 0.01){
            if(details){
              cat(sprintf("\t\tRedistributing remaining %.2f EUR from rebalancing pool\n", transfer_pool))
            }

            for(name in active_assets){
              redistribution <- active_targets[[name]] * transfer_pool
              sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] + redistribution

              if(details){
                cat(sprintf("\t\t=> Transferring %.2f EUR to %s\n", redistribution, name))
              }
            }
          }
        }

      # Fix 5: Restcash (DCA-Zufluss, Redistribution) noch am Rebalance-Tag
      # reinvestieren — ausser den Cash-Reserven signalbedingt wartender Signal-Assets.
      for (name in active_assets) {
        if (!(name %in% signal_cash_only) &&
            sim_mem[["status"]][[name]][["money"]] > 0.005 &&
            (sim_mem[["assets"]][[name]][["style"]] != "signal" ||
             sim_mem[["status"]][[name]][["count"]] > 0)) {
          sim_mem <- perform_trade_buy(input = sim_mem, name = name, index = time,
            reason = "Rebalancing:", spread = spread_rates[[name]],
            fractions = fractions, details = details)
        }
      }

      calculate_total_report(input = sim_mem, assets = flag_assets, index = time)
      flag_fast_report <- FALSE
    }

    #--------> Implementierung von Steuer- und Gebührenkalkulation:
    # § 18 Abs. 3 InvStG: Faelligkeit der Vorabpauschale des Vorjahres
    if (tax_mode == "person" && flag_vp_settle[time]) {
      pend <- sim_mem[["totals"]][["vp_pending"]]
      vp_paid_any <- !is.null(pend) && length(pend) > 0
      if (vp_paid_any) {
        for (p in pend) {
          sim_mem <- .pay_vp(sim_mem, p[["name"]], p[["tax_debt"]], time,
                             list(flat_rate = p[["flat_rate"]],
                                  bonus = p[["bonus"]],
                                  spb_used = p[["spb_used"]],
                                  assessment_date = p[["assessment_date"]]))
        }
        sim_mem[["totals"]][["vp_pending"]] <- NULL
      }
      if (vp_paid_any) {
        calculate_total_report(input = sim_mem, assets = flag_assets, index = time)
        flag_fast_report <- FALSE
      }
    }

    if (flag_taxes[time]) {
      
      # ================================================================
      # TEIL 1: Vorabpauschale für natürliche Personen (tax_mode = "person")
      # ================================================================
      if (tax_mode == "person" && !(liquidate && flag_liquidate[time])) {
        for (name in flag_assets) {
          
          # Vorabpauschale nur für ETFs (investment_fund) mit Bestand > 0
          tax_regime <- tax_regimes[[name]]
          
          if (tax_regime == "investment_fund" && sim_mem[["status"]][[name]][["count"]] > 0) {
            
            # Vorabpauschale berechnen (reine Lesefunktion, keine Seiteneffekte)
            vp_result <- calculate_flat_rate(
              input = sim_mem, 
              name = name, 
              index = time, 
              dates = flag_date,
              tax_regime = tax_regime
            )
            flat_rate <- vp_result$total_vp
            
            # VP pro Lot in sim_mem speichern (direkt by-reference, kein Copy-on-Modify)
            # Dies ist der Fix für den kritischen VP-Bug: Die Schreiboperation erfolgt
            # im Aufrufer auf sim_mem, nicht in calculate_flat_rate auf einer lokalen Kopie.
            for (vp_k in seq_along(vp_result$lot_indices)) {
              vp_i <- vp_result$lot_indices[vp_k]
              current_vp <- sim_mem[["trades"]][[name]][["buys"]][[vp_i]][["vp"]] %||% 0
              sim_mem[["trades"]][[name]][["buys"]][[vp_i]][["vp"]] <- current_vp + vp_result$lot_vps[vp_k]
            }
            
            if (flat_rate > 0) {
              
              # Bereits gezahlte Vorabpauschalen dieses Jahr ermitteln
              prior_flat_rates <- 0
              n_tax_entries <- sim_mem[["trades"]][[name]][["tax_count"]]
              if (n_tax_entries > 0) {
                current_year_str <- format(flag_date[time], "%Y")
                prior_flat_rates <- sum(vapply(
                  sim_mem[["trades"]][[name]][["taxes"]][1:n_tax_entries],
                  function(x) {
                    if (!is.null(x) && identical(format((x[["assessment_date"]] %||% x[["event_date"]]), "%Y"), current_year_str)) {
                      x[["taxes_paid"]]
                    } else {
                      0
                    }
                  }, numeric(1)), na.rm = TRUE)
              }
              
              bonus <- sim_mem[["assets"]][[name]][["bonus"]]
              
              result <- calculate_vorabpauschale_tax(
                flat_rate = flat_rate,
                bonus = bonus,
                totals = sim_mem[["totals"]],
                tax_rate = effective_tax_rate,
                use_spb = use_sparer_pauschbetrag
              )
              
              sim_mem[["totals"]] <- result$totals
              tax_debt <- max(result$tax - prior_flat_rates, 0)
              
              if (details && result$spb_used > 0) {
                cat(sprintf("Tax Event:\tVorabpauschale %s: %.2f EUR (nach TFS: %.2f EUR, SPB: %.2f EUR)\n",
                            name, flat_rate, flat_rate * (1 - bonus), result$spb_used))
              }
              
              if (tax_debt > 0) {
                vp_meta <- list(flat_rate = flat_rate, bonus = bonus,
                                spb_used = result$spb_used,
                                assessment_date = flag_date[time])
                # § 18 Abs. 3 InvStG: Zufluss am ersten Werktag des Folgejahres.
                # Festsetzung hier (31.12., letzter realer Jahreskurs via LOCF);
                # Zahlung/Zwangsverkauf am ersten Handelstag des neuen Jahres.
                has_future_settle <- time < length(flag_date) &&
                  any(flag_vp_settle[(time + 1):length(flag_date)])
                if (has_future_settle) {
                  # Ablage in totals (status wird vom C++-Market-Update mit festem
                  # Feldsatz neu aufgebaut und wuerde ad-hoc-Felder verwerfen)
                  pend <- sim_mem[["totals"]][["vp_pending"]]
                  if (is.null(pend)) pend <- list()
                  pend[[length(pend) + 1L]] <- c(vp_meta, list(name = name, tax_debt = tax_debt))
                  sim_mem[["totals"]][["vp_pending"]] <- pend
                  if (details) {
                    cat(sprintf("Tax Event:\tVorabpauschale %s: %.2f EUR festgesetzt am %s (faellig am ersten Handelstag des Folgejahres)\n",
                                name, tax_debt, flag_date[time]))
                  }
                } else {
                  if (details) {
                    cat(sprintf("Tax Event:	Vorabpauschale %s: %.2f EUR festgesetzt am %s (sofort faellig: kein weiterer Handelstag)
",
                                name, tax_debt, flag_date[time]))
                  }
                  sim_mem <- .pay_vp(sim_mem, name, tax_debt, time, vp_meta)
                }
              }
            }
          }
        }
      }
      
      # ================================================================
      # TEIL 2: Fondsbesteuerung (tax_mode = "funds")
      # ================================================================
      if (tax_mode == "funds") {
        result_fees <- calculate_fund_fees(
          input = sim_mem, 
          index = time, 
          dates = flag_date, 
          assets = flag_assets, 
          funds_fee = funds_fee, 
          bonus_fee = bonus_fee, 
          details = details
        )
        sim_mem[["totals"]][["total_value"]] <- result_fees[["total_value"]]
        
        annual_fees <- result_fees[["total_fees"]]
        asset_share <- annual_fees * sapply(sim_mem[["status"]], function(x) x[["actual"]])
        asset_money <- sapply(sim_mem[["status"]], function(x) x[["money"]])
        
        for (name in flag_assets) {
          if (asset_money[[name]] > asset_share[[name]]) {
            if (sim_mem[["status"]][[name]][["money"]] < asset_share[[name]]) {
              asset_share[[name]] <- max(0, sim_mem[["status"]][[name]][["money"]])
            }
            
            sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] - asset_share[[name]]
            
            if (details) {
              cat(sprintf("\t\t=> Deducting %.2f EUR from %s's cash reserve for fees\n", 
                          asset_share[[name]], name))
            }
          }
        }
      }
      
      calculate_total_report(input = sim_mem, assets = flag_assets, index = time)
      flag_fast_report <- FALSE
    }

    #--------> Implementierung von Liquidierung:
    if(flag_liquidate[time]){
      for(name in flag_assets){
        if(sim_mem[["status"]][[name]][["count"]] > 0){
          tax_type <- ifelse(tax_mode == "person", "person", "none")
          sim_mem <- perform_trade_sell(input = sim_mem, name = name, index = time, 
            tax_mode = tax_type, tax_rate = tax_rate, 
            effective_tax_rate = effective_tax_rate,
            marginal_tax_rate = marginal_tax_rate,
            private_sale_threshold = private_sale_threshold,
            use_sparer_pauschbetrag = use_sparer_pauschbetrag,
            tax_regime = tax_regimes[[name]],
            reason = "Liquidating:", spread = spread_rates[[name]], details = details)
        }
      }
      
      if(format(flag_date[time], "%m-%d") != "12-31" && tax_mode == "funds"){
        result_fees <- calculate_fund_fees(input = sim_mem, index = time, dates = flag_date, assets = flag_assets, funds_fee = funds_fee, bonus_fee = bonus_fee, details = details)
        sim_mem[["totals"]][["total_value"]] <- result_fees[["total_value"]]
        
        annual_fees <- result_fees[["total_fees"]]
        asset_share <- annual_fees * sapply(sim_mem[["status"]], function(x) x[["differ"]])
        asset_money <- sapply(sim_mem[["status"]], function(x) x[["money"]])
        
        for(name in flag_assets){
          sim_mem <- perform_trade_sell(input = sim_mem, name = name, index = time, tax_mode = tax_mode, tax_rate = tax_rate, effective_tax_rate = effective_tax_rate, 
          marginal_tax_rate = marginal_tax_rate,
  private_sale_threshold = private_sale_threshold,
  use_sparer_pauschbetrag = use_sparer_pauschbetrag,
  tax_regime = tax_regimes[[name]],
          spread = spread_rates[[name]], details = details)
          
          if(sim_mem[["status"]][[name]][["money"]] < asset_share[[name]]){
            asset_share[[name]] <- max(0, sim_mem[["status"]][[name]][["money"]])
          }

          sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] - asset_share[[name]]
        }
        
        tax_weights <- sapply(sim_mem[["status"]], function(x) x[["differ"]])
        final_value <- sum(sapply(sim_mem[["status"]], function(x) x[["total"]]), na.rm = TRUE)
        total_gains <- final_value - start_value
        
        if(total_gains > 0){
          total_taxes <- total_gains * tax_rate
          
          for(name in flag_assets){
            tax_per_asset <- total_taxes * tax_weights[[name]]
            
            if(sim_mem[["status"]][[name]][["money"]] < tax_per_asset){
              tax_per_asset <- max(0, sim_mem[["status"]][[name]][["money"]])
            }
            
            sim_mem[["status"]][[name]][["money"]] <- sim_mem[["status"]][[name]][["money"]] - tax_per_asset
          }
          
          if(details){
            cat(sprintf("Liquidating:\tPaying taxes of %.2f EUR on %.2f EUR total gain on %s\n", total_taxes, total_gains, flag_date[time]))
          }
        }
        
        for(name in flag_assets){
          trades_entry <- list(
            event_date = flag_date[time],
            event_type = "Fees",
            fees_paid = annual_fees
          )

          sim_mem[["trades"]][[name]][["fee_count"]] <- sim_mem[["trades"]][[name]][["fee_count"]] + 1
          sim_mem[["trades"]][[name]][["fees"]][[sim_mem[["trades"]][[name]][["fee_count"]]]] <- trades_entry
        }
      }

      calculate_total_report(input = sim_mem, assets = flag_assets, index = time)
      flag_fast_report <- FALSE
    }

    # Fallback: Wenn kein Slow-Path-Event den Report aktualisiert hat
    if(flag_fast_report){
      perform_market_update(sim_mem, flag_assets, time)
    }

    prev_end <- time
  }

  # ─────────────────────────────────────────────────────────────────────────
  # TRAILING BATCH: Fast-Path-Tage nach dem letzten Individual-Tag
  # ─────────────────────────────────────────────────────────────────────────
  if (prev_end < n_total_days) {
    batch_market_update(sim_mem, flag_assets, prev_end + 1L, n_total_days)
  }

  # === NEU: Finales Jahr abschließen ===
  if (tax_mode == "person") {
    sim_mem <- handle_year_change(
      input = sim_mem,
      current_date = as.Date(paste0(as.integer(format(stopp_date, "%Y")) + 1, "-01-01")),
      marginal_tax_rate = marginal_tax_rate,
      private_sale_threshold = private_sale_threshold,
      sparer_pauschbetrag = sparer_pauschbetrag,
      use_sparer_pauschbetrag = use_sparer_pauschbetrag,
      soli_factor_income = soli_factor_income,
      effective_tax_rate = effective_tax_rate,
      details = details
    )
  }
  # === Ende neu ===

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

  #--------> Drawdowns (mit NaN-Schutz):
  # #17 FIX: Division durch 0 abfangen
  running_max <- cummax(total_worth)
  drawdowns <- ifelse(running_max > 0, (running_max - total_worth) / running_max, 0)
  max_drawdown <- max(drawdowns, na.rm = TRUE)
  if (!is.finite(max_drawdown)) max_drawdown <- 0   # Einzeltag/leer: robust

  #--------> TTWROR:
  # #18 FIX: Division durch 0 abfangen
  n <- n_days_sim
  if (n >= 2) {
    period_change <- c(NA_real_, total_worth[2:n] - total_worth[1:(n-1)] - total_flows[2:n])
    prev_total <- c(NA_real_, total_worth[1:(n-1)])
    period_return <- ifelse(!is.na(prev_total) & prev_total > 0, period_change / prev_total, 0)
    period_return[1] <- NA_real_
  } else {
    period_return <- NA_real_       # Einzeltag (n=1): keine Periodenrendite berechenbar
  }
  ttwror <- if (ann_factor > 0) {
    prod(1 + period_return, na.rm = TRUE)^(1 / ann_factor) - 1
  } else {
    NA_real_
  }

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

  # ═══════════════════════════════════════════════════════════════════════════
  # PERFORMANCE- UND RISIKO-METRIKEN
  # ═══════════════════════════════════════════════════════════════════════════

  # --- Basis-Statistiken ---
  daily_mean <- mean(risk_returns, na.rm = TRUE)
  daily_sd   <- sd(risk_returns, na.rm = TRUE)
  if (!is.finite(daily_mean)) daily_mean <- 0   # Einzeltag/leer: robust
  if (!is.finite(daily_sd))   daily_sd   <- 0
  daily_cv   <- if (daily_mean != 0) abs(daily_sd / daily_mean) else NA_real_

  # --- Downside-Metriken ---
  downside_returns <- risk_returns[risk_returns < 0]
  downside_sd <- if (length(downside_returns) > 0) {
    sqrt(mean(downside_returns^2, na.rm = TRUE))
  } else {
    0
  }

  # A-2: Annualisierung mit der tatsaechlichen Beobachtungsfrequenz (ohne LOCF-Tage)
  days_per_year <- ann_periods

  # A-4: Risk-Free als annualisierte Dezimalrate (Jahresrate je Tag).
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
  downside_sd_excess <- if (length(downside_excess) > 0) sqrt(mean(downside_excess^2, na.rm = TRUE)) else 0

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
  calmar <- if (max_drawdown > 0 && !is.na(cagr)) {
    cagr / max_drawdown
  } else {
    NA_real_
  }

  # --- Ulcer Index ---
  ulcer_index <- sqrt(mean(drawdowns^2, na.rm = TRUE))
  if (!is.finite(ulcer_index)) ulcer_index <- 0   # Einzeltag/leer: robust

  # --- Martin Ratio (= Ulcer Performance Index) ---
  martin_ratio <- if (ulcer_index > 0 && !is.na(cagr)) {
    cagr / ulcer_index
  } else {
    NA_real_
  }

  # --- Serenity Ratio ---
  serenity <- if (ulcer_index > 0 && max_drawdown > 0 && !is.na(cagr)) {
    cagr / (ulcer_index * max_drawdown)
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
  for (i in seq_along(total_worth)) {
    if (total_worth[i] < running_max[i]) {
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
  for (i in seq_along(total_worth)) {
    if (total_worth[i] < running_max[i]) {
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

  #--------> Berechnung der Handelsaktionen:
  buys <- sapply(flag_assets, function(x) length(sim_mem[["trades"]][[x]][["buys"]]) / ann_factor)
  sells <- sapply(flag_assets, function(x) length(sim_mem[["trades"]][[x]][["sells"]]) / ann_factor)

  results <- list(
    dates = flag_date,                 # ABGLEICH: von plot_dashboard.R (x$dates) benoetigt
    filled = flag_filled,              # A-2: TRUE = LOCF-Tag (aus Risikometriken ausgeschlossen)
    worth = total_worth,
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
      sparer_pauschbetrag_tax_saved = sim_mem[["totals"]][["sparer_pauschbetrag_used_total"]] * effective_tax_rate
    )
  )

  class(results) <- "SimLevResult"
  return(results)
}



#' Print SimLev Results
#'
#' @param x A SimLevResult object
#' @param ... Additional arguments (ignored)
#'
#' @return Invisible x
#' @export
print.SimLevResult <- function(x, ...) {
  s <- x$statistics
  cat("\n")
  cat("══════════════════════════════════════════════════════════════\n")
  cat("                    SimLev Simulation Results                  \n")
  cat("══════════════════════════════════════════════════════════════\n\n")
  
  cat("  Performance\n")
  cat("  ─────────────────────\n")
  cat(sprintf("  CAGR:             %+.2f%%\n", x$cagr * 100))
  cat(sprintf("  TTWROR:           %+.2f%%\n", x$ttwror * 100))
  cat(sprintf("  Final Value:      %.2f EUR\n", tail(x$worth, 1)))
  cat("\n")

  cat("  Risk\n")
  cat("  ─────────────────────\n")
  cat(sprintf("  Max Drawdown:     %.2f%%\n", s$max_drawdown * 100))
  cat(sprintf("  Avg Drawdown:     %.2f%%\n", s$average_drawdown * 100))
  cat(sprintf("  Ulcer Index:      %.4f\n", s$ulcer_index))
  cat(sprintf("  Longest DD:       %d Tage\n", s$longest_drawdown))
  cat(sprintf("  Avg Recovery:     %s Tage\n", 
              if (is.na(s$avg_recovery_time)) "–" else sprintf("%.0f", s$avg_recovery_time)))
  cat("\n")

  cat("  Ratios\n")
  cat("  ─────────────────────\n")
  fmt_ratio <- function(val) if (is.na(val)) "–" else sprintf("%+.3f", val)
  cat(sprintf("  Sharpe:           %s\n", fmt_ratio(s$sharpe)))
  cat(sprintf("  Sortino:          %s\n", fmt_ratio(s$sortino)))
  cat(sprintf("  Calmar:           %s\n", fmt_ratio(s$calmar)))
  cat(sprintf("  Omega:            %s\n", fmt_ratio(s$omega)))
  cat(sprintf("  Gain/Pain:        %s\n", fmt_ratio(s$gain_to_pain)))
  cat(sprintf("  Serenity:         %s\n", fmt_ratio(s$serenity)))
  cat(sprintf("  Martin Ratio:              %s\n", fmt_ratio(s$martin_ratio)))
  cat("\n")

  cat("  Distribution\n")
  cat("  ─────────────────────\n")
  cat(sprintf("  Daily Mean:       %+.4f%%\n", s$mean * 100))
  cat(sprintf("  Daily Std Dev:    %.4f%%\n", s$sd * 100))
  cat(sprintf("  Skewness:         %.3f\n", s$skewness))
  cat(sprintf("  Kurtosis:         %.3f\n", s$kurtosis))
  cat("\n")
  
  if (!is.null(x$tax_report) && x$tax_report$total_taxes_paid > 0) {
    cat("  Steuern\n")
    cat("  ─────────────────────\n")
    cat(sprintf("  Gezahlte Steuern: %.2f EUR\n", x$tax_report$total_taxes_paid))
    cat(sprintf("  Verlustvortrag:   %.2f EUR (§ 20) / %.2f EUR (§ 23)\n", 
                x$tax_report$loss_carryforward_capital,
                x$tax_report$loss_carryforward_private))
    
    if (x$tax_report$sparer_pauschbetrag_annual > 0) {
      cat(sprintf("  SPB genutzt:      %.2f EUR (Ersparnis: %.2f EUR)\n",
                  x$tax_report$sparer_pauschbetrag_used,
                  x$tax_report$sparer_pauschbetrag_tax_saved))
    }
    cat("\n")
  }

  cat("══════════════════════════════════════════════════════════════\n")
  
  invisible(x)
}


#' Summary of SimLev Results
#'
#' @param object A SimLevResult object
#' @param ... Additional arguments (ignored)
#'
#' @return A list with summary statistics (invisibly)
#' @export
summary.SimLevResult <- function(object, ...) {
  n_days <- length(object$worth)
  s <- object$statistics
  
  summary_list <- list(
    n_days = n_days,
    n_years = round(n_days / 365.25, 2),
    start_value = object$worth[1],
    end_value = tail(object$worth, 1),
    total_return = (tail(object$worth, 1) / object$worth[1]) - 1,
    cagr = object$cagr,
    ttwror = object$ttwror,
    # Alle Metriken direkt aus statistics übernehmen (nicht neu berechnen)
    sharpe = s$sharpe,
    sortino = s$sortino,
    calmar = s$calmar,
    omega = s$omega,
    gain_to_pain = s$gain_to_pain,
    serenity = s$serenity,
    martin_ratio = s$martin_ratio,
    max_drawdown = s$max_drawdown,
    average_drawdown = s$average_drawdown,
    ulcer_index = s$ulcer_index,
    longest_drawdown = s$longest_drawdown,
    avg_recovery_time = s$avg_recovery_time,
    statistics = s,
    tax_report = object$tax_report
  )
  
  class(summary_list) <- "summary.SimLevResult"
  
  # Eigene kompakte Ausgabe
  cat("\n")
  cat("══════════════════════════════════════════════════════════════\n")
  cat("                    SimLev Summary                             \n")
  cat("══════════════════════════════════════════════════════════════\n\n")
  
  cat(sprintf("  Zeitraum:         %d Tage (%.1f Jahre)\n", n_days, summary_list$n_years))
  cat(sprintf("  Start:            %.2f EUR\n", summary_list$start_value))
  cat(sprintf("  Ende:             %.2f EUR\n", summary_list$end_value))
  cat(sprintf("  Gesamtrendite:    %+.2f%%\n", summary_list$total_return * 100))
  cat(sprintf("  CAGR:             %+.2f%%\n", summary_list$cagr * 100))
  cat(sprintf("  TTWROR:           %+.2f%%\n", summary_list$ttwror * 100))
  cat("\n")
  
  fmt <- function(val, pct = FALSE) {
    if (is.na(val)) return("–")
    if (pct) sprintf("%.2f%%", val * 100) else sprintf("%.3f", val)
  }
  
  metrics <- data.frame(
    Metrik = c("Sharpe", "Sortino", "Calmar", "Omega", "Gain/Pain", 
               "Serenity", "Martin", "Max DD", "Avg DD", "Ulcer", 
               "Longest DD", "Avg Recovery"),
    Wert = c(
      fmt(s$sharpe), fmt(s$sortino), fmt(s$calmar), fmt(s$omega),
      fmt(s$gain_to_pain), fmt(s$serenity), fmt(s$martin_ratio),
      fmt(s$max_drawdown, TRUE), fmt(s$average_drawdown, TRUE), fmt(s$ulcer_index),
      sprintf("%d d", s$longest_drawdown),
      if (is.na(s$avg_recovery_time)) "–" else sprintf("%.0f d", s$avg_recovery_time)
    ),
    stringsAsFactors = FALSE
  )
  
  for (i in seq_len(nrow(metrics))) {
    cat(sprintf("  %-16s %s\n", metrics$Metrik[i], metrics$Wert[i]))
  }
  
  cat("\n══════════════════════════════════════════════════════════════\n")
  
  invisible(summary_list)
}


