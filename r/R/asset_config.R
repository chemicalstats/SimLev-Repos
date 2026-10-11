#' Create Asset Configuration
#'
#' Creates a validated asset configuration for use in simulation strategies.
#' Each asset in a portfolio requires a configuration that specifies its
#' tax treatment, trading behavior, and other properties.
#'
#' @param asset_class Character. The type of asset:
#'   \describe{
#'     \item{"etf"}{Exchange-Traded Fund (InvStG, Teilfreistellung)}
#'     \item{"etn"}{Exchange-Traded Note}
#'     \item{"etc"}{Exchange-Traded Commodity}
#'     \item{"certificate"}{Certificate (Zertifikat)}
#'   }
#' @param action_type Character. Trading strategy:
#'   \describe{
#'     \item{"bnh"}{Buy-and-Hold: Buy on first day, hold until end}
#'     \item{"signal"}{Signal-based: Buy/sell based on signal columns in data}
#'   }
#' @param asset_share Numeric. Target portfolio weight between 0 and 1.
#'   Used for rebalancing and DCA allocation. Default: 1.0.
#' @param asset_spread Numeric. Voller Bid-Ask-Spread in Prozent (z. B. 0.1 fuer 0,1 %).
#'   Applied to buy and sell prices. Default: 0.001.
#' @param asset_bonus Numeric. Teilfreistellung rate for ETFs:
#'   \describe{
#'     \item{30}{Equity ETFs (Aktienfonds, >51\% equities)}
#'     \item{15}{Mixed ETFs (Mischfonds, >25\% equities)}
#'     \item{0}{Bond/other ETFs, or non-ETF assets}
#'   }
#' @param deliverable Logical. For ETN/ETC: Does the product offer physical
#'   delivery? If TRUE, gains are taxed under § 23 EStG (tax-free after 1 year).
#'   If FALSE, taxed under § 20 EStG (26.375\% flat tax). Default: FALSE.
#' @param asset_start Date or NULL. When the asset becomes tradeable.
#'   Used for delayed entry in multi-asset portfolios. Default: NULL (start immediately).
#' @param tax_regime Character or NULL. Override automatic tax regime detection:
#'   \describe{
#'     \item{"investment_fund"}{InvStG (ETFs)}
#'     \item{"capital_gains"}{§ 20 EStG (standard)}
#'     \item{"private_sale"}{§ 23 EStG (1-year holding period)}
#'   }
#' @param signal_buy Character or NULL. Column name in data for buy signals.
#'   Required if action_type = "signal".
#' @param signal_sell Character or NULL. Column name in data for sell signals.
#'   Required if action_type = "signal".
#'
#' @return An object of class "asset_config" containing validated configuration.
#'
#' @examples
#' # Equity ETF with 30% Teilfreistellung
#' etf_config <- asset_config(
#'   asset_class = "etf",
#'   asset_share = 0.7,
#'   asset_bonus = 30
#' )
#'
#' # Gold ETC with physical delivery (§ 23 EStG)
#' gold_config <- asset_config(
#'   asset_class = "etc",
#'   asset_share = 0.2,
#'   deliverable = TRUE
#' )
#'
#' # Certificate (§ 20 EStG standard)
#' cert_config <- asset_config(
#'   asset_class = "certificate",
#'   asset_share = 0.1
#' )
#'
#' @seealso [create_strategy()], [simulation()]
#' @export
asset_config <- function(
    asset_class = c("etf", "etn", "etc", "certificate",
                    "etn_standard", "etn_deliverable"),
    action_type = c("bnh", "signal"),
    asset_share = 1.0,
    asset_spread = 0.1,
    asset_bonus = 0.0,
    deliverable = FALSE,
    asset_start = NULL,
    tax_regime = NULL,
    signal_buy = NULL,
    signal_sell = NULL
) {
  
  asset_class <- match.arg(asset_class)
  action_type <- match.arg(action_type)
  
  # Backward compatibility
  if (asset_class == "etn_standard") {
    warning("asset_class 'etn_standard' is deprecated. Use 'etn' with deliverable = FALSE.")
    asset_class <- "etn"
    deliverable <- FALSE
  } else if (asset_class == "etn_deliverable") {
    warning("asset_class 'etn_deliverable' is deprecated. Use 'etn' with deliverable = TRUE.")
    asset_class <- "etn"
    deliverable <- TRUE
  }
  
  # Validations

if (asset_share <= 0 || asset_share > 1) {
    stop("asset_share must be between 0 (exclusive) and 1 (inclusive)")
  }
  
  if (asset_spread < 0) {
    stop("asset_spread must be non-negative")
  }
  
  if (asset_bonus < 0 || asset_bonus > 100) {
    stop("asset_bonus must be between 0 and 100 percent (e.g., 30 for 30%)")
  }
  
  if (action_type == "signal" && (is.null(signal_buy) || is.null(signal_sell))) {
    stop("signal_buy and signal_sell must be specified when action_type = 'signal'")
  }
  
  # Tax regime inference
  if (is.null(tax_regime)) {
    tax_regime <- switch(asset_class,
      "etf" = "investment_fund",
      "etn" = if (deliverable) "private_sale" else "capital_gains",
      "etc" = if (deliverable) "private_sale" else "capital_gains",
      "certificate" = "capital_gains"
    )
  } else {
    valid_regimes <- c("investment_fund", "capital_gains", "private_sale")
    if (!tax_regime %in% valid_regimes) {
      stop(sprintf("Invalid tax_regime. Must be one of: %s",
                   paste(valid_regimes, collapse = ", ")))
    }
  }
  
  config <- list(
    asset_class = asset_class,
    action_type = action_type,
    asset_share = asset_share,
    asset_spread = asset_spread,
    asset_bonus = asset_bonus,
    deliverable = deliverable,
    asset_start = asset_start,
    tax_regime = tax_regime,
    signal_buy = signal_buy,
    signal_sell = signal_sell
  )
  
  class(config) <- c("asset_config", "list")
  return(config)
}


#' Print Asset Configuration
#' @param x An asset_config object
#' @param ... Additional arguments (ignored)
#' @export
print.asset_config <- function(x, ...) {
  cat("Asset Configuration\n")
  cat("-------------------\n")
  cat(sprintf("  Class:        %s\n", x$asset_class))
  cat(sprintf("  Action:       %s\n", x$action_type))
  cat(sprintf("  Share:        %.1f%%\n", x$asset_share * 100))
  cat(sprintf("  Tax Regime:   %s\n", x$tax_regime))
  if (x$asset_class == "etf") {
    cat(sprintf("  Teilfrei.:    %.0f%%\n", x$asset_bonus))
  }
  if (x$asset_class %in% c("etn", "etc")) {
    cat(sprintf("  Deliverable:  %s\n", x$deliverable))
  }
  invisible(x)
}


#' Summary of Asset Configuration
#' @param object An asset_config object
#' @param ... Additional arguments (ignored)
#' @export
summary.asset_config <- function(object, ...) {
  print(object)
}
