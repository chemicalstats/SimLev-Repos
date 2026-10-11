#' Create Investment Strategy
#'
#' Creates a strategy object from one or more asset configurations.
#' A strategy defines which assets to include in a portfolio simulation
#' and their respective configurations.
#'
#' @param ... Named asset_config objects. Names become asset identifiers
#'   and must match column names in the data.
#' @param assets Optional named list of asset configurations as an
#'   alternative to ... arguments.
#'
#' @return An object of class "strategy" containing validated asset configs.
#'
#' @examples
#' strategy <- create_strategy(
#'   MSCI_World = asset_config(asset_class = "etf", asset_bonus = 0.30),
#'   Gold = asset_config(asset_class = "etc", deliverable = TRUE)
#' )
#'
#' @seealso [asset_config()], [validate_strategy()], [simulation()]
#' @export
create_strategy <- function(..., assets = NULL) {
  dots <- list(...)
  
  if (!is.null(assets) && length(dots) > 0) {
    stop("Provide either ... arguments or 'assets', not both")
  }
  
  if (!is.null(assets)) {
    if (!is.list(assets) || is.null(names(assets))) {
      stop("'assets' must be a named list")
    }
    dots <- assets
  }
  
  if (length(dots) == 0) {
    stop("At least one asset configuration is required")
  }
  
  if (is.null(names(dots)) || any(names(dots) == "")) {
    stop("All assets must be named")
  }
  
  # Convert plain lists to asset_config
  for (name in names(dots)) {
    if (!inherits(dots[[name]], "asset_config")) {
      if (is.list(dots[[name]])) {
        dots[[name]] <- do.call(asset_config, dots[[name]])
      } else {
        stop(sprintf("Asset '%s' must be an asset_config object or list", name))
      }
    }
  }
  
  class(dots) <- c("strategy", "list")
  return(dots)
}


#' Validate Strategy Against Data
#'
#' Checks that all assets in the strategy have corresponding columns in the data
#' and that signal columns exist if required.
#'
#' @param strategy A strategy object
#' @param data Data frame to validate against. Must have a 'date' column
#'   and columns for each asset.
#'
#' @return TRUE if valid, otherwise throws an error.
#'
#' @examples
#' \dontrun{
#' validate_strategy(strategy, market_data)
#' }
#'
#' @export
validate_strategy <- function(strategy, data = NULL) {
  if (!inherits(strategy, "strategy")) {
    stop("Object is not a strategy")
  }
  
  for (i in seq_along(strategy)) {
    if (!inherits(strategy[[i]], "asset_config")) {
      stop(sprintf("Asset '%s' is not an asset_config object", names(strategy)[i]))
    }
  }
  
  if (!is.null(data)) {
    asset_names <- names(strategy)
    data_cols <- colnames(data)
    
    missing_assets <- setdiff(asset_names, data_cols)
    if (length(missing_assets) > 0) {
      stop(sprintf("Assets not found in data: %s", 
                   paste(missing_assets, collapse = ", ")))
    }
    
    for (name in asset_names) {
      asset <- strategy[[name]]
      if (asset$action_type == "signal") {
        if (!asset$signal_buy %in% data_cols) {
          stop(sprintf("Signal column '%s' not found (asset '%s')",
                       asset$signal_buy, name))
        }
        if (!asset$signal_sell %in% data_cols) {
          stop(sprintf("Signal column '%s' not found (asset '%s')",
                       asset$signal_sell, name))
        }
      }
    }
  }
  
  return(TRUE)
}


#' Add Asset to Strategy
#'
#' @param strategy A strategy object
#' @param name Character. Name for the new asset
#' @param asset An asset_config object
#'
#' @return Updated strategy object
#' @export
add_asset <- function(strategy, name, asset) {
  if (!inherits(strategy, "strategy")) {
    stop("First argument must be a strategy object")
  }
  if (!inherits(asset, "asset_config")) {
    stop("asset must be an asset_config object")
  }
  
  strategy[[name]] <- asset
  return(strategy)
}


#' Update Asset in Strategy
#'
#' @param strategy A strategy object
#' @param name Character. Name of the asset to update
#' @param ... Parameters to update (e.g., asset_share = 0.5)
#'
#' @return Updated strategy object
#' @export
update_asset <- function(strategy, name, ...) {
  if (!inherits(strategy, "strategy")) {
    stop("First argument must be a strategy object")
  }
  
  if (!name %in% names(strategy)) {
    stop(sprintf("Asset '%s' not found in strategy", name))
  }
  
  updates <- list(...)
  asset <- strategy[[name]]
  
  for (param in names(updates)) {
    if (!param %in% names(asset)) {
      warning(sprintf("Unknown parameter '%s' ignored", param))
      next
    }
    asset[[param]] <- updates[[param]]
  }
  
  strategy[[name]] <- do.call(asset_config, asset)
  return(strategy)
}


#' Remove Asset from Strategy
#'
#' @param strategy A strategy object
#' @param name Character. Name of the asset to remove
#'
#' @return Updated strategy object
#' @export
remove_asset <- function(strategy, name) {
  if (!inherits(strategy, "strategy")) {
    stop("First argument must be a strategy object")
  }
  
  if (!name %in% names(strategy)) {
    stop(sprintf("Asset '%s' not found in strategy", name))
  }
  
  strategy[[name]] <- NULL
  
  if (length(strategy) == 0) {
    warning("Strategy is now empty")
  }
  
  return(strategy)
}


#' Migrate Old Strategy Format
#'
#' Converts strategies using deprecated asset_class values to the new format.
#'
#' @param old_strategy A list with old-format asset configurations
#' @param verbose Logical. Print migration details. Default: TRUE
#'
#' @return A strategy object with updated format
#' @export
migrate_strategy <- function(old_strategy, verbose = TRUE) {
  new_strategy <- list()
  
  for (name in names(old_strategy)) {
    asset <- old_strategy[[name]]
    
    if (asset$asset_class == "etn_deliverable") {
      if (verbose) {
        message(sprintf("Migrating %s: etn_deliverable -> etn + deliverable=TRUE", name))
      }
      asset$asset_class <- "etn"
      asset$deliverable <- TRUE
    } else if (asset$asset_class == "etn_standard") {
      if (verbose) {
        message(sprintf("Migrating %s: etn_standard -> etn + deliverable=FALSE", name))
      }
      asset$asset_class <- "etn"
      asset$deliverable <- FALSE
    }
    
    new_strategy[[name]] <- do.call(asset_config, asset)
  }
  
  class(new_strategy) <- c("strategy", "list")
  return(new_strategy)
}


#' Print Strategy
#' @param x A strategy object
#' @param ... Additional arguments (ignored)
#' @export
print.strategy <- function(x, ...) {
  cat(sprintf("Investment Strategy (%d assets)\n", length(x)))
  cat("================================\n\n")
  
  for (name in names(x)) {
    asset <- x[[name]]
    cat(sprintf("%s:\n", name))
    cat(sprintf("  Class: %s | Share: %.0f%% | Tax: %s\n",
                asset$asset_class, asset$asset_share * 100, asset$tax_regime))
  }
  
  invisible(x)
}


#' Summary of Strategy
#' @param object A strategy object
#' @param ... Additional arguments (ignored)
#' @export
summary.strategy <- function(object, ...) {
  cat(sprintf("Strategy Summary: %d assets\n\n", length(object)))
  
  total_share <- sum(sapply(object, function(a) a$asset_share))
  cat(sprintf("Total allocation: %.1f%%\n", total_share * 100))
  
  if (abs(total_share - 1) > 0.001) {
    cat("  (Note: Does not sum to 100%)\n")
  }
  
  cat("\nBy Tax Regime:\n")
  regimes <- sapply(object, function(a) a$tax_regime)
  for (regime in unique(regimes)) {
    n <- sum(regimes == regime)
    cat(sprintf("  %s: %d asset(s)\n", regime, n))
  }
  
  invisible(object)
}


#' Convert a strategy object to a plain list
#'
#' @param x A \code{strategy} object (or other object).
#' @param ... Ignored.
#' @return A plain (unclassed) named list suitable for the legacy
#'   \code{simulation()} list interface.
#' @export
as_list <- function(x, ...) UseMethod("as_list")

#' @export
as_list.strategy <- function(x, ...) {
  attr(x, "class") <- NULL
  x
}

#' @export
as_list.default <- function(x, ...) as.list(x)
