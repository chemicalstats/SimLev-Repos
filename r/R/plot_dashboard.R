# plot_dashboard.R
# Comprehensive Dashboard-Style Plotting for SimLev Results

#' Create a Comprehensive Dashboard Plot for Simulation Results
#'
#' @param x A SimLevResult object
#' @param style Character: "full" (all panels), "compact" (key metrics only), or "custom"
#' @param panels Character vector: Which panels to include (if style = "custom")
#'   Options: "performance", "drawdown", "distribution", "rolling", "correlation", "monthly"
#' @param compare Optional: Another SimLevResult object to compare against
#' @param colors List: Custom color scheme
#' @param ... Additional arguments (ignored)
#'
#' @return Invisible NULL (creates plot as side effect)
#' @export
#'
#' @examples
#' result <- simulation(data, strategy, start_value = 10000)
#' 
#' # Full dashboard
#' plot(result)
#' 
#' # Compact version
#' plot(result, style = "compact")
#' 
#' # Custom panels
#' plot(result, style = "custom", panels = c("performance", "drawdown", "distribution"))
#' 
#' # Compare two strategies
#' result2 <- simulation(data, strategy2, start_value = 10000)
#' plot(result, compare = result2)
plot.SimLevResult <- function(
    x, 
    style = c("full", "compact", "custom"),
    panels = c("performance", "drawdown", "distribution", "rolling", "monthly", "stats"),
    compare = NULL,
    colors = NULL,
    ...
) {
  style <- match.arg(style)
  
  # Default color scheme
  if (is.null(colors)) {
    colors <- list(
      primary = "#2E86AB",      # Blue
      secondary = "#A23B72",    # Purple
      positive = "#06A77D",     # Green
      negative = "#D62246",     # Red
      neutral = "#6C757D",      # Gray
      background = "#F8F9FA",   # Light gray
      grid = "#E9ECEF"          # Grid lines
    )
  }
  
  # Determine layout based on style
  if (style == "full") {
    if (!is.null(compare)) {
      layout_matrix <- matrix(c(
        1, 1, 2, 2,
        3, 3, 4, 4,
        5, 5, 6, 6,
        7, 7, 8, 8
      ), nrow = 4, byrow = TRUE)
      selected_panels <- c("performance", "drawdown", "distribution", "rolling", 
                          "monthly", "correlation", "stats", "comparison")
    } else {
      layout_matrix <- matrix(c(
        1, 1, 2, 2,
        3, 3, 4, 4,
        5, 5, 6, 6
      ), nrow = 3, byrow = TRUE)
      selected_panels <- c("performance", "drawdown", "distribution", 
                          "rolling", "monthly", "stats")
    }
  } else if (style == "compact") {
    layout_matrix <- matrix(c(1, 2, 3, 4), nrow = 2, byrow = TRUE)
    selected_panels <- c("performance", "drawdown", "distribution", "stats")
  } else {
    # Custom - user specified panels
    n_panels <- length(panels)
    if (n_panels <= 2) {
      layout_matrix <- matrix(1:n_panels, nrow = 1)
    } else if (n_panels <= 4) {
      layout_matrix <- matrix(1:n_panels, nrow = 2, byrow = TRUE)
    } else if (n_panels <= 6) {
      layout_matrix <- matrix(1:n_panels, nrow = 3, byrow = TRUE)
    } else {
      layout_matrix <- matrix(1:n_panels, nrow = 4, byrow = TRUE)
    }
    selected_panels <- panels
  }
  
  # Set up layout
  old_par <- par(no.readonly = TRUE)
  on.exit(par(old_par))
  
  layout(layout_matrix)
  par(mar = c(4, 4, 3, 2), bg = colors$background)
  
  # Helper function for nice axis formatting
  format_currency <- function(x) {
    ifelse(abs(x) >= 1e6, 
           sprintf("$%.1fM", x/1e6),
           ifelse(abs(x) >= 1e3,
                  sprintf("$%.0fK", x/1e3),
                  sprintf("$%.0f", x)))
  }
  
  format_percent <- function(x) {
    sprintf("%.1f%%", x * 100)
  }
  
  # Extract data
  dates <- if (!is.null(x$dates)) x$dates else seq_along(x$worth)
  n_days <- length(x$worth)
  
  # ===========================================================================
  # PANEL 1: PORTFOLIO PERFORMANCE
  # ===========================================================================
  if ("performance" %in% selected_panels) {
    plot(dates, x$worth, 
         type = "n",
         xlab = "", 
         ylab = "Portfolio Value",
         main = "Portfolio Performance",
         col.main = colors$primary,
         cex.main = 1.3,
         font.main = 2,
         las = 1,
         yaxt = "n")
    
    # Add grid
    grid(col = colors$grid, lty = 1, lwd = 0.5)
    
    # Add shaded area under curve
    polygon(c(dates, rev(dates)), 
            c(x$worth, rep(min(x$worth), length(dates))),
            col = paste0(colors$primary, "30"),
            border = NA)
    
    # Add line
    lines(dates, x$worth, col = colors$primary, lwd = 2.5)
    
    # Add comparison if provided
    if (!is.null(compare) && "performance" %in% selected_panels) {
      lines(dates, compare$worth, col = colors$secondary, lwd = 2.5, lty = 2)
      legend("topleft", 
             legend = c("Strategy 1", "Strategy 2"),
             col = c(colors$primary, colors$secondary),
             lty = c(1, 2),
             lwd = 2,
             bg = "white",
             box.col = colors$grid)
    }
    
    # Custom y-axis with currency formatting
    y_ticks <- pretty(x$worth)
    axis(2, at = y_ticks, labels = format_currency(y_ticks), las = 1)
    
    # Add final value annotation
    final_val <- tail(x$worth, 1)
    text(tail(dates, 1), final_val, 
         labels = format_currency(final_val),
         pos = 4, col = colors$primary, font = 2, cex = 0.9)
  }
  
  # ===========================================================================
  # PANEL 2: DRAWDOWN CHART
  # ===========================================================================
  if ("drawdown" %in% selected_panels) {
    drawdowns_pct <- x$drawdowns * 100
    
    plot(dates, -drawdowns_pct,
         type = "n",
         xlab = "",
         ylab = "Drawdown (%)",
         main = "Drawdown Analysis",
         col.main = colors$primary,
         cex.main = 1.3,
         font.main = 2,
         las = 1,
         ylim = c(min(-drawdowns_pct) * 1.1, 0))
    
    # Add grid
    grid(col = colors$grid, lty = 1, lwd = 0.5)
    
    # Add shaded area
    polygon(c(dates, rev(dates)),
            c(-drawdowns_pct, rep(0, length(dates))),
            col = paste0(colors$negative, "40"),
            border = NA)
    
    # Add line
    lines(dates, -drawdowns_pct, col = colors$negative, lwd = 2)
    
    # Add max drawdown line
    max_dd <- max(drawdowns_pct)
    abline(h = -max_dd, col = colors$negative, lty = 2, lwd = 1.5)
    text(dates[1], -max_dd, 
         labels = sprintf("Max: %.1f%%", max_dd),
         pos = 3, col = colors$negative, font = 2)
  }
  
  # ===========================================================================
  # PANEL 3: RETURNS DISTRIBUTION
  # ===========================================================================
  if ("distribution" %in% selected_panels) {
    # Calculate daily returns
    returns <- diff(log(x$worth)) * 100
    
    hist(returns,
         breaks = 50,
         col = paste0(colors$primary, "80"),
         border = colors$primary,
         main = "Daily Returns Distribution",
         xlab = "Daily Return (%)",
         ylab = "Frequency",
         col.main = colors$primary,
         cex.main = 1.3,
         font.main = 2,
         las = 1)
    
    # Add normal distribution overlay
    x_seq <- seq(min(returns), max(returns), length.out = 100)
    y_norm <- dnorm(x_seq, mean = mean(returns), sd = sd(returns))
    y_norm_scaled <- y_norm * length(returns) * diff(range(returns)) / 50
    lines(x_seq, y_norm_scaled, col = colors$secondary, lwd = 2, lty = 2)
    
    # Add vertical line at mean
    abline(v = mean(returns), col = colors$positive, lwd = 2, lty = 2)
    
    # Add statistics
    legend("topright",
           legend = c(
             sprintf("Mean: %.2f%%", mean(returns)),
             sprintf("SD: %.2f%%", sd(returns)),
             sprintf("Skew: %.2f", x$statistics$skewness),
             sprintf("Kurt: %.2f", x$statistics$kurtosis)
           ),
           bty = "n",
           text.col = colors$primary,
           cex = 0.9)
  }
  
  # ===========================================================================
  # PANEL 4: ROLLING RETURNS
  # ===========================================================================
  if ("rolling" %in% selected_panels) {
    # Calculate 30-day rolling returns (annualized)
    window <- min(30, floor(n_days / 10))
    if (n_days > window) {
      rolling_returns <- sapply(window:n_days, function(i) {
        start_val <- x$worth[i - window + 1]
        end_val <- x$worth[i]
        ((end_val / start_val)^(252/window) - 1) * 100
      })
      
      rolling_dates <- dates[window:n_days]
      
      plot(rolling_dates, rolling_returns,
           type = "n",
           xlab = "",
           ylab = "Annualized Return (%)",
           main = sprintf("%d-Day Rolling Returns (Annualized)", window),
           col.main = colors$primary,
           cex.main = 1.3,
           font.main = 2,
           las = 1)
      
      # Add grid
      grid(col = colors$grid, lty = 1, lwd = 0.5)
      
      # Add zero line
      abline(h = 0, col = colors$neutral, lty = 2)
      
      # Color code positive/negative
      positive_idx <- rolling_returns >= 0
      
      # Plot positive returns
      if (any(positive_idx)) {
        lines(rolling_dates[positive_idx], rolling_returns[positive_idx],
              col = colors$positive, lwd = 1.5)
      }
      
      # Plot negative returns
      if (any(!positive_idx)) {
        lines(rolling_dates[!positive_idx], rolling_returns[!positive_idx],
              col = colors$negative, lwd = 1.5)
      }
      
      # Add CAGR line
      cagr_pct <- x$cagr * 100
      abline(h = cagr_pct, col = colors$primary, lty = 2, lwd = 1.5)
      text(dates[1], cagr_pct,
           labels = sprintf("CAGR: %.1f%%", cagr_pct),
           pos = 3, col = colors$primary, font = 2, cex = 0.9)
    }
  }
  
  # ===========================================================================
  # PANEL 5: MONTHLY RETURNS HEATMAP
  # ===========================================================================
  if ("monthly" %in% selected_panels && !is.null(dates)) {
    # Calculate monthly returns
    dates_date <- as.Date(dates)
    year_month <- format(dates_date, "%Y-%m")
    
    monthly_data <- tapply(x$worth, year_month, function(vals) {
      if (length(vals) > 1) {
        return((tail(vals, 1) / head(vals, 1) - 1) * 100)
      } else {
        return(NA)
      }
    })
    
    # Parse year and month
    ym_split <- strsplit(names(monthly_data), "-")
    years <- sapply(ym_split, `[`, 1)
    months <- as.integer(sapply(ym_split, `[`, 2))
    
    # Create matrix
    unique_years <- unique(years)
    monthly_matrix <- matrix(NA, nrow = length(unique_years), ncol = 12)
    rownames(monthly_matrix) <- unique_years
    colnames(monthly_matrix) <- month.abb
    
    for (i in seq_along(monthly_data)) {
      year_idx <- which(unique_years == years[i])
      month_idx <- months[i]
      monthly_matrix[year_idx, month_idx] <- monthly_data[i]
    }
    
    # Plot heatmap
    par(mar = c(5, 5, 3, 3))
    
    # Define color palette
    breaks <- seq(-10, 10, length.out = 21)
    cols <- colorRampPalette(c(colors$negative, "white", colors$positive))(20)
    
    image(1:12, 1:nrow(monthly_matrix), t(monthly_matrix),
          col = cols,
          breaks = breaks,
          xlab = "Month",
          ylab = "Year",
          main = "Monthly Returns Heatmap",
          col.main = colors$primary,
          cex.main = 1.3,
          font.main = 2,
          axes = FALSE)
    
    axis(1, at = 1:12, labels = month.abb, las = 2)
    axis(2, at = 1:nrow(monthly_matrix), labels = rownames(monthly_matrix), las = 1)
    
    # Add values as text
    for (i in 1:nrow(monthly_matrix)) {
      for (j in 1:12) {
        if (!is.na(monthly_matrix[i, j])) {
          text(j, i, sprintf("%.1f", monthly_matrix[i, j]),
               col = if(abs(monthly_matrix[i, j]) > 5) "white" else "black",
               cex = 0.7)
        }
      }
    }
    
    par(mar = c(4, 4, 3, 2))
  }
  
  # ===========================================================================
  # PANEL 6: KEY STATISTICS TABLE
  # ===========================================================================
  if ("stats" %in% selected_panels) {
    plot.new()
    plot.window(xlim = c(0, 1), ylim = c(0, 1))
    
    title("Performance Statistics", 
          col.main = colors$primary,
          cex.main = 1.3,
          font.main = 2)
    
    # Prepare statistics
    stats <- list(
      "Performance Metrics" = c(
        sprintf("CAGR: %+.2f%%", x$cagr * 100),
        sprintf("TTWROR: %+.2f%%", x$ttwror * 100),
        sprintf("Total Return: %+.2f%%", (tail(x$worth, 1) / head(x$worth, 1) - 1) * 100)
      ),
      "Risk Metrics" = c(
        sprintf("Max Drawdown: %.2f%%", max(x$drawdowns) * 100),
        sprintf("Daily Volatility: %.2f%%", x$statistics$sd * 100),
        sprintf("Ann. Volatility: %.2f%%", x$statistics$sd * sqrt(252) * 100)
      ),
      "Return Profile" = c(
        sprintf("Sharpe Ratio: %.2f", (x$cagr - 0.02) / (x$statistics$sd * sqrt(252))),
        sprintf("Skewness: %.2f", x$statistics$skewness),
        sprintf("Kurtosis: %.2f", x$statistics$kurtosis)
      ),
      "Portfolio Info" = c(
        sprintf("Start Value: %s", format_currency(head(x$worth, 1))),
        sprintf("End Value: %s", format_currency(tail(x$worth, 1))),
        sprintf("Duration: %d days", n_days)
      )
    )
    
    if (!is.null(compare)) {
      stats[["Comparison"]] <- c(
        sprintf("CAGR Diff: %+.2f%%", (x$cagr - compare$cagr) * 100),
        sprintf("Return Diff: %+.2f%%", 
                (tail(x$worth, 1) / head(x$worth, 1) - tail(compare$worth, 1) / head(compare$worth, 1)) * 100),
        sprintf("Vol Diff: %+.2f%%", (x$statistics$sd - compare$statistics$sd) * sqrt(252) * 100)
      )
    }
    
    # Display statistics in columns
    n_sections <- length(stats)
    y_start <- 0.95
    y_step <- 0.85 / n_sections
    
    for (i in seq_along(stats)) {
      section_name <- names(stats)[i]
      section_stats <- stats[[i]]
      
      y_pos <- y_start - (i - 1) * y_step
      
      # Section header
      text(0.05, y_pos, section_name,
           font = 2, cex = 1.0, col = colors$primary, adj = 0)
      
      # Section stats
      for (j in seq_along(section_stats)) {
        text(0.08, y_pos - j * 0.04, section_stats[j],
             font = 1, cex = 0.85, col = colors$neutral, adj = 0)
      }
    }
    
    # Add border
    rect(0.02, 0.02, 0.98, 0.98, border = colors$grid, lwd = 2)
  }
  
  # ===========================================================================
  # PANEL 7: CORRELATION MATRIX (if multiple assets in report)
  # ===========================================================================
  if ("correlation" %in% selected_panels && !is.null(x$report) && length(x$report) > 1) {
    # Extract asset returns
    asset_names <- names(x$report)
    n_assets <- length(asset_names)
    
    # Calculate correlation matrix
    cor_matrix <- diag(n_assets)
    rownames(cor_matrix) <- asset_names
    colnames(cor_matrix) <- asset_names
    
    # Note: This would require asset-level price data
    # For now, show placeholder
    plot.new()
    plot.window(xlim = c(0, 1), ylim = c(0, 1))
    title("Asset Correlation Matrix",
          col.main = colors$primary,
          cex.main = 1.3,
          font.main = 2)
    text(0.5, 0.5, "Requires asset-level price data",
         cex = 1.2, col = colors$neutral)
  }
  
  # ===========================================================================
  # PANEL 8: COMPARISON METRICS (if compare provided)
  # ===========================================================================
  if ("comparison" %in% selected_panels && !is.null(compare)) {
    plot.new()
    plot.window(xlim = c(0, 1), ylim = c(0, 1))
    
    title("Strategy Comparison",
          col.main = colors$primary,
          cex.main = 1.3,
          font.main = 2)
    
    # Comparison bar chart
    metrics <- c("CAGR", "Max DD", "Volatility", "Sharpe")
    strat1_vals <- c(
      x$cagr * 100,
      max(x$drawdowns) * 100,
      x$statistics$sd * sqrt(252) * 100,
      (x$cagr - 0.02) / (x$statistics$sd * sqrt(252))
    )
    strat2_vals <- c(
      compare$cagr * 100,
      max(compare$drawdowns) * 100,
      compare$statistics$sd * sqrt(252) * 100,
      (compare$cagr - 0.02) / (compare$statistics$sd * sqrt(252))
    )
    
    y_positions <- seq(0.8, 0.2, length.out = length(metrics))
    
    for (i in seq_along(metrics)) {
      # Metric name
      text(0.05, y_positions[i], metrics[i],
           font = 2, cex = 1.0, adj = 0)
      
      # Strategy 1 value
      text(0.35, y_positions[i], sprintf("%.2f", strat1_vals[i]),
           col = colors$primary, cex = 0.9, adj = 1)
      
      # Strategy 2 value
      text(0.65, y_positions[i], sprintf("%.2f", strat2_vals[i]),
           col = colors$secondary, cex = 0.9, adj = 1)
      
      # Difference
      diff <- strat1_vals[i] - strat2_vals[i]
      diff_col <- if(diff > 0) colors$positive else colors$negative
      text(0.95, y_positions[i], sprintf("%+.2f", diff),
           col = diff_col, font = 2, cex = 0.9, adj = 1)
    }
    
    # Column headers
    text(0.35, 0.95, "Strategy 1", col = colors$primary, font = 2, adj = 1)
    text(0.65, 0.95, "Strategy 2", col = colors$secondary, font = 2, adj = 1)
    text(0.95, 0.95, "Diff", col = colors$neutral, font = 2, adj = 1)
    
    # Border
    rect(0.02, 0.02, 0.98, 0.98, border = colors$grid, lwd = 2)
  }
  
  invisible(NULL)
}


#' Export Dashboard to PDF
#'
#' @param x A SimLevResult object
#' @param filename Character: Path for output PDF file
#' @param width Numeric: Width in inches
#' @param height Numeric: Height in inches
#' @param ... Additional arguments passed to plot.SimLevResult
#'
#' @export
#'
#' @examples
#' result <- simulation(data, strategy)
#' export_dashboard(result, "portfolio_dashboard.pdf")
export_dashboard <- function(x, filename = "dashboard.pdf", 
                             width = 14, height = 10, ...) {
  pdf(filename, width = width, height = height)
  plot(x, ...)
  dev.off()
  message(sprintf("Dashboard exported to: %s", filename))
}


#' Create Interactive HTML Dashboard (requires plotly)
#'
#' @param x A SimLevResult object
#' @param filename Character: Path for output HTML file
#'
#' @export
#'
#' @examples
#' \dontrun{
#' result <- simulation(data, strategy)
#' export_html_dashboard(result, "portfolio_dashboard.html")
#' }
export_html_dashboard <- function(x, filename = "dashboard.html") {
  if (!requireNamespace("plotly", quietly = TRUE)) {
    stop("Package 'plotly' is required for HTML dashboards. Install with: install.packages('plotly')")
  }
  
  # This would create an interactive plotly dashboard
  # Implementation would use plotly for interactive charts
  message("Interactive HTML dashboard export - To be implemented")
}
