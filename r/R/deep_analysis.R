# =============================================================================
#  deep_analysis.R  —  Vertiefte Auswertung gespeicherter Ergebnisse
# -----------------------------------------------------------------------------
#  deep_analysis() analysiert ein oder mehrere Ergebnisse von simulation()
#  (oder beliebige Kursreihen) nachtraeglich, im Umfang von Portfolio-
#  Backtestern wie testfol.io: Benchmark-Kennzahlen (Alpha, Beta, Capture,
#  Tracking Error, Information Ratio, M2), VaR/CVaR, Rendite- und
#  Monatstabellen, Saisonalitaet, Drawdown-Tabelle, rollierende Kennzahlen und
#  geldgewichtete Rendite (MWRR). simulation() selbst bleibt unveraendert.
# =============================================================================

#' Eine Reihe fuer die Analyse aufbereiten
#' @keywords internal
.da_series <- function(x, name) {
  if (inherits(x, "SimLevResult")) {
    ix <- result_index(x)
    return(list(name = name, date = ix$date, value = ix$value, filled = as.logical(x$filled %||% FALSE),
                worth = ix$worth, flows = ix$flows, result = x))
  }
  if (is.data.frame(x)) {
    if (!"date" %in% names(x)) stop(sprintf("'%s': data.frame braucht eine Spalte 'date'.", name))
    vc <- if ("value" %in% names(x)) "value" else setdiff(names(x)[vapply(x, is.numeric, TRUE)], "date")[1]
    if (is.na(vc)) stop(sprintf("'%s': keine numerische Wertspalte gefunden.", name))
    v <- .fill_na(as.numeric(x[[vc]]), "locf")
    return(list(name = name, date = as.Date(x$date), value = v, filled = rep(FALSE, length(v)),
                worth = NULL, flows = NULL, result = NULL))
  }
  stop(sprintf("'%s' muss ein SimLevResult oder ein data.frame(date, value) sein.", name))
}

#' Wertreihe auf Perioden-Endwerte reduzieren (letzter verfuegbarer Tag)
#' @keywords internal
.da_period_values <- function(date, value, unit) {
  key <- switch(unit, month = format(date, "%Y-%m"), year = format(date, "%Y"))
  last <- which(c(key[-1] != key[-length(key)], TRUE))
  list(key = key[last], date = date[last], value = value[last],
       start_value = value[1], start_date = date[1])
}

#' Interne-Zinsfuss-Rendite (MWRR, p. a.) eines Ergebnisses
#' @keywords internal
.da_mwrr <- function(s) {
  if (is.null(s$worth)) return(NA_real_)
  t <- as.numeric(s$date - s$date[1]) / 365.25
  cf <- -s$flows; cf[1] <- -s$worth[1]                    # Einzahlungen negativ aus Anlegersicht
  n <- length(cf); cf[n] <- cf[n] + s$worth[n]
  f <- function(r) sum(cf / (1 + r)^t)
  out <- tryCatch(stats::uniroot(f, c(-0.99, 10), tol = 1e-10)$root, error = function(e) NA_real_)
  out
}

#' Drawdown-Episoden
#' @keywords internal
.da_drawdowns <- function(date, value, top = 10) {
  peak <- cummax(value); dd <- value / peak - 1
  n <- length(value); ep <- list(); i <- 1L
  while (i <= n) {
    if (dd[i] < 0) {
      s <- i - 1L; j <- i
      while (j <= n && dd[j] < 0) j <- j + 1L
      seg <- i:(j - 1L); tr <- seg[which.min(dd[seg])]
      ep[[length(ep) + 1L]] <- data.frame(
        start = date[max(1L, s)], trough = date[tr], end = if (j <= n) date[j] else as.Date(NA),
        depth = dd[tr], days_to_trough = as.numeric(date[tr] - date[max(1L, s)]),
        days_to_recover = if (j <= n) as.numeric(date[j] - date[tr]) else NA_real_,
        days_total = if (j <= n) as.numeric(date[j] - date[max(1L, s)]) else as.numeric(date[n] - date[max(1L, s)]))
      i <- j
    } else i <- i + 1L
  }
  if (!length(ep)) return(data.frame(start = as.Date(character(0)), trough = as.Date(character(0)),
                                     end = as.Date(character(0)), depth = numeric(0), days_to_trough = numeric(0),
                                     days_to_recover = numeric(0), days_total = numeric(0)))
  tab <- do.call(rbind, ep)
  tab <- tab[order(tab$depth), , drop = FALSE]
  rownames(tab) <- NULL
  utils::head(tab, top)
}

#' Kennzahlen einer Reihe
#' @keywords internal
.da_metrics <- function(s, rf_d, ppy, var_levels) {
  keep <- !s$filled[-1]
  r_all <- s$value[-1] / s$value[-length(s$value)] - 1
  r <- r_all[keep]; rf <- rf_d[-1][keep]
  yrs <- as.numeric(s$date[length(s$date)] - s$date[1]) / 365.25
  cagr <- (s$value[length(s$value)] / s$value[1])^(1 / yrs) - 1
  vol <- stats::sd(r) * sqrt(ppy)
  ex <- r - rf
  down <- ex[ex < 0]
  peak <- cummax(s$value); dd <- 1 - s$value / peak
  mdd <- max(dd)
  ulcer <- sqrt(mean(dd^2))
  m <- .da_period_values(s$date, s$value, "month")
  mr <- c(m$value[1] / m$start_value, m$value[-1] / m$value[-length(m$value)]) - 1
  y <- .da_period_values(s$date, s$value, "year")
  yr <- c(y$value[1] / y$start_value, y$value[-1] / y$value[-length(y$value)]) - 1
  var_d <- vapply(var_levels, function(a) -stats::quantile(r, a, names = FALSE), 0)
  cvar_d <- vapply(var_levels, function(a) { q <- stats::quantile(r, a, names = FALSE); -mean(r[r <= q]) }, 0)
  var_m <- vapply(var_levels, function(a) -stats::quantile(mr, a, names = FALSE), 0)
  cvar_m <- vapply(var_levels, function(a) { q <- stats::quantile(mr, a, names = FALSE); -mean(mr[mr <= q]) }, 0)
  ddt <- .da_drawdowns(s$date, s$value, top = 1e6)
  rf_ann <- mean(rf_d) * 365.25
  out <- c(
    start_value = s$value[1], end_value = s$value[length(s$value)],
    years = yrs, total_return = s$value[length(s$value)] / s$value[1] - 1,
    cagr = cagr, mwrr = .da_mwrr(s), volatility = vol,
    sharpe = if (stats::sd(ex) > 0) mean(ex) * ppy / (stats::sd(ex) * sqrt(ppy)) else NA_real_,
    sortino = if (length(down)) mean(ex) * ppy / (sqrt(mean(pmin(ex, 0)^2)) * sqrt(ppy)) else NA_real_,
    calmar = if (mdd > 0) cagr / mdd else NA_real_,
    max_drawdown = mdd, avg_drawdown = if (nrow(ddt)) mean(-ddt$depth) else 0,
    ulcer_index = ulcer, upi = if (ulcer > 0) (cagr - rf_ann) / ulcer else NA_real_,
    longest_drawdown_days = if (nrow(ddt)) max(ddt$days_total) else 0,
    recovery_factor = if (mdd > 0) (s$value[length(s$value)] / s$value[1] - 1) / mdd else NA_real_,
    required_to_recover = if (dd[length(dd)] > 0) 1 / (1 - dd[length(dd)]) - 1 else 0,
    skewness = calculate_skewness(r), excess_kurtosis = calculate_kurtosis(r),
    best_day = max(r), worst_day = min(r), best_month = max(mr), worst_month = min(mr),
    best_year = max(yr), worst_year = min(yr), positive_months = mean(mr > 0),
    avg_gain = mean(r[r > 0]), avg_loss = mean(r[r < 0]),
    gain_loss_ratio = if (any(r < 0)) mean(r[r > 0]) / abs(mean(r[r < 0])) else NA_real_,
    stats::setNames(var_d, sprintf("var_daily_%g", 100 * var_levels)),
    stats::setNames(cvar_d, sprintf("cvar_daily_%g", 100 * var_levels)),
    stats::setNames(var_m, sprintf("var_monthly_%g", 100 * var_levels)),
    stats::setNames(cvar_m, sprintf("cvar_monthly_%g", 100 * var_levels)))
  tr <- if (!is.null(s$result)) s$result$tax_report else NULL
  c(out, taxes = if (!is.null(s$result)) tr$total_taxes_paid %||% 0 else NA_real_,
    trades_per_year = if (!is.null(s$result)) sum(s$result$buys) + sum(s$result$sells) else NA_real_)
}

#' Benchmark-Kennzahlen (auf gemeinsamen Tagen)
#' @keywords internal
.da_benchmark <- function(s, b, rf_d, ppy, cagr_s, cagr_b) {
  common <- as.Date(intersect(as.numeric(s$date), as.numeric(b$date)), origin = "1970-01-01")
  is <- match(as.numeric(common), as.numeric(s$date)); ib <- match(as.numeric(common), as.numeric(b$date))
  vs <- s$value[is]; vb <- b$value[ib]
  rs <- vs[-1] / vs[-length(vs)] - 1; rb <- vb[-1] / vb[-length(vb)] - 1
  keep <- !(s$filled[is][-1] | b$filled[ib][-1])
  rs <- rs[keep]; rb <- rb[keep]
  rf <- rf_d[is][-1][keep]
  es <- rs - rf; eb <- rb - rf
  beta <- stats::cov(es, eb) / stats::var(eb)
  alpha <- (mean(es) - beta * mean(eb)) * ppy
  te <- stats::sd(rs - rb) * sqrt(ppy)
  ms <- .da_period_values(common, vs, "month"); mb <- .da_period_values(common, vb, "month")
  mrs <- c(ms$value[1] / ms$start_value, ms$value[-1] / ms$value[-length(ms$value)]) - 1
  mrb <- c(mb$value[1] / mb$start_value, mb$value[-1] / mb$value[-length(mb$value)]) - 1
  gm <- function(x) prod(1 + x)^(1 / length(x)) - 1
  up <- mrb > 0; dn <- mrb < 0
  upc <- if (any(up)) gm(mrs[up]) / gm(mrb[up]) else NA_real_
  dnc <- if (any(dn)) gm(mrs[dn]) / gm(mrb[dn]) else NA_real_
  sharpe_s <- mean(es) * ppy / (stats::sd(es) * sqrt(ppy))
  rf_ann <- mean(rf) * 365.25
  c(alpha = alpha, beta = beta, correlation = stats::cor(rs, rb), r_squared = stats::cor(rs, rb)^2,
    correlation_up = if (sum(rb > 0) > 2) stats::cor(rs[rb > 0], rb[rb > 0]) else NA_real_,
    correlation_down = if (sum(rb < 0) > 2) stats::cor(rs[rb < 0], rb[rb < 0]) else NA_real_,
    up_capture = upc, down_capture = dnc, capture_spread = upc - dnc,
    active_return = cagr_s - cagr_b, tracking_error = te,
    information_ratio = if (te > 0) mean(rs - rb) * ppy / te else NA_real_,
    m2 = sharpe_s * stats::sd(rb) * sqrt(ppy) + rf_ann,
    treynor = if (beta != 0) (mean(es) * ppy) / beta else NA_real_)
}

#' Monatsrenditen-Tabelle (Jahr x Monat, plus Jahr)
#' @keywords internal
.da_monthly_table <- function(s) {
  m <- .da_period_values(s$date, s$value, "month")
  mr <- c(m$value[1] / m$start_value, m$value[-1] / m$value[-length(m$value)]) - 1
  yy <- as.integer(substr(m$key, 1, 4)); mm <- as.integer(substr(m$key, 6, 7))
  years <- sort(unique(yy))
  M <- matrix(NA_real_, length(years), 12, dimnames = list(years, month.abb))
  M[cbind(match(yy, years), mm)] <- mr
  y <- .da_period_values(s$date, s$value, "year")
  yr <- c(y$value[1] / y$start_value, y$value[-1] / y$value[-length(y$value)]) - 1
  cbind(M, Year = yr[match(years, as.integer(y$key))])
}

#' Rollierende Kennzahlen auf Monatsbasis
#' @keywords internal
.da_rolling <- function(s, b, window_m, rf_ann) {
  m <- .da_period_values(s$date, s$value, "month")
  v <- c(m$start_value, m$value); d <- c(m$start_date, m$date)
  n <- length(v)
  if (n <= window_m) return(NULL)
  idx <- (window_m + 1):n
  vb <- if (!is.null(b)) {
    vv <- b$value[findInterval(as.numeric(d), as.numeric(b$date))]
    vv[!is.finite(vv) | vv <= 0] <- NA; vv
  } else NULL
  out <- t(vapply(idx, function(k) {
    seg <- v[(k - window_m):k]; r <- seg[-1] / seg[-length(seg)] - 1
    yrs <- as.numeric(d[k] - d[k - window_m]) / 365.25
    cg <- (seg[length(seg)] / seg[1])^(1 / yrs) - 1
    vo <- stats::sd(r) * sqrt(12)
    mdd <- max(1 - seg / cummax(seg))
    bt <- ex <- NA_real_
    if (!is.null(vb) && !anyNA(vb[(k - window_m):k])) {
      sb <- vb[(k - window_m):k]; rb <- sb[-1] / sb[-length(sb)] - 1
      bt <- stats::cov(r, rb) / stats::var(rb)
      ex <- cg - ((sb[length(sb)] / sb[1])^(1 / yrs) - 1)
    }
    c(cagr = cg, volatility = vo, sharpe = if (vo > 0) (cg - rf_ann) / vo else NA_real_,
      max_drawdown = mdd, beta = bt, excess_cagr = ex)
  }, numeric(6)))
  data.frame(date = d[idx], out)
}


#' Vertiefte Analyse von Simulationsergebnissen
#'
#' Wertet ein oder mehrere gespeicherte Ergebnisse von [simulation()] (oder
#' Kursreihen) aus, im Umfang gaengiger Portfolio-Backtester wie testfol.io.
#' Grundlage ist der zeitgewichtete Wertindex ([result_index()]); Sparplaene
#' und Entnahmen verzerren die Renditen daher nicht. Per LOCF aufgefuellte
#' Tage werden aus allen renditebasierten Kennzahlen ausgeschlossen.
#'
#' Kennzahlen je Reihe: Gesamtrendite, CAGR, geldgewichtete Rendite (MWRR,
#' interner Zinsfuss der Ein- und Auszahlungen), Volatilitaet, Sharpe,
#' Sortino, Calmar, maximaler und mittlerer Drawdown, Ulcer Index, UPI,
#' laengste Drawdown-Dauer, Recovery Factor, noetige Rendite zur Erholung,
#' Schiefe, Kurtosis, beste und schlechteste Tage, Monate und Jahre, Anteil
#' positiver Monate, Gewinn/Verlust-Verhaeltnis, historischer VaR und CVaR
#' (taeglich und monatlich), bei SimLev-Ergebnissen auch Steuern und
#' Transaktionen.
#'
#' Gegen einen Benchmark: Alpha (annualisiert, CAPM auf Ueberschussrenditen),
#' Beta, Korrelation gesamt sowie in Auf- und Abwaertsphasen, R²,
#' Up-/Down-Capture (Monatsbasis), Capture Spread, aktive Rendite, Tracking
#' Error, Information Ratio, M² (Modigliani) und Treynor.
#'
#' @param x Ein \code{SimLevResult}, ein \code{data.frame(date, value)} oder
#'   eine benannte Liste davon (z. B. mehrere gespeicherte Laeufe).
#' @param benchmark \code{NULL}, ein Name aus \code{x}, ein
#'   \code{SimLevResult} oder ein \code{data.frame(date, value)}.
#' @param risk_free Risikoloser Zins in Prozent p. a.: Skalar oder
#'   \code{data.frame(date, rate)} (Stufenfunktion).
#' @param rolling_years Fensterlaenge der rollierenden Kennzahlen in Jahren.
#' @param var_levels Wahrscheinlichkeiten fuer VaR und CVaR.
#' @param top_drawdowns Anzahl Eintraege der Drawdown-Tabelle.
#' @return Objekt der Klasse \code{SimLevAnalysis} mit \code{metrics}
#'   (Kennzahl x Reihe), \code{benchmark_metrics}, \code{annual},
#'   \code{monthly} (je Reihe Jahr x Monat), \code{seasonality},
#'   \code{drawdowns}, \code{rolling}, \code{correlation} (taeglich und
#'   monatlich) und den Wertreihen. Ausgabe mit \code{print}, \code{summary}
#'   und \code{plot} (\code{type} = "overview", "growth", "drawdown",
#'   "rolling", "annual", "monthly").
#' @examples
#' set.seed(1)
#' d <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = 3000))
#' d$A <- 100 * cumprod(1 + rnorm(3000, 3e-4, 0.010))
#' d$B <- 100 * cumprod(1 + rnorm(3000, 2e-4, 0.006))
#' a <- simulation(d, create_strategy(A = asset_config("etf", "bnh")))
#' b <- simulation(d, create_strategy(A = asset_config("etf", "bnh", 0.6), B = asset_config("etf", "bnh", 0.4)),
#'                 balance_mode = TRUE, balance_span = 1, balance_unit = "year")
#' da <- deep_analysis(list(Aktien = a, Mischung = b), benchmark = "Aktien", risk_free = 1)
#' da
#' @seealso [result_index()], [simulation()], [sensitivity_grid()]
#' @export
deep_analysis <- function(x, benchmark = NULL, risk_free = 0, rolling_years = 3,
                          var_levels = c(0.01, 0.05, 0.10), top_drawdowns = 10) {
  if (inherits(x, "SimLevResult") || is.data.frame(x)) x <- list(Strategie = x)
  if (!is.list(x) || !length(x)) stop("x muss ein SimLevResult, ein data.frame oder eine Liste davon sein.")
  if (is.null(names(x)) || any(names(x) == "")) names(x) <- paste0("S", seq_along(x))
  ser <- mapply(.da_series, x, names(x), SIMPLIFY = FALSE)
  bname <- NULL; bser <- NULL
  if (!is.null(benchmark)) {
    if (is.character(benchmark)) {
      if (!benchmark %in% names(ser)) stop("benchmark muss ein Name aus x sein.")
      bname <- benchmark; bser <- ser[[benchmark]]
    } else { bname <- "Benchmark"; bser <- .da_series(benchmark, bname); ser[[bname]] <- bser }
  }
  rf_of <- function(s) .resolve_series(risk_free, data.frame(date = s$date), "risk_free") / 100 / 365.25
  ppy_of <- function(s) { k <- sum(!s$filled[-1]); k / (as.numeric(s$date[length(s$date)] - s$date[1]) / 365.25) }
  met <- vapply(ser, function(s) .da_metrics(s, rf_of(s), ppy_of(s), var_levels),
                .da_metrics(ser[[1]], rf_of(ser[[1]]), ppy_of(ser[[1]]), var_levels))
  bm <- NULL
  if (!is.null(bser)) {
    others <- setdiff(names(ser), bname)
    bm <- vapply(others, function(nm) .da_benchmark(ser[[nm]], bser, rf_of(ser[[nm]]), ppy_of(ser[[nm]]),
                                                    met["cagr", nm], met["cagr", bname]), numeric(14))
    if (!is.matrix(bm)) bm <- matrix(bm, ncol = length(others), dimnames = list(NULL, others))
    rownames(bm) <- c("alpha", "beta", "correlation", "r_squared", "correlation_up", "correlation_down",
                      "up_capture", "down_capture", "capture_spread", "active_return", "tracking_error",
                      "information_ratio", "m2", "treynor")
  }
  monthly <- lapply(ser, .da_monthly_table)
  annual <- do.call(cbind, lapply(monthly, function(M) M[, "Year"]))
  if (!is.matrix(annual)) annual <- matrix(annual, ncol = length(ser), dimnames = list(rownames(monthly[[1]]), names(ser)))
  seasonality <- vapply(monthly, function(M) colMeans(M[, 1:12, drop = FALSE], na.rm = TRUE), numeric(12))
  dds <- lapply(ser, function(s) .da_drawdowns(s$date, s$value, top_drawdowns))
  rf_ann <- if (is.numeric(risk_free) && length(risk_free) == 1) risk_free / 100 else mean(rf_of(ser[[1]])) * 365.25
  rolling <- lapply(ser, function(s) .da_rolling(s, if (!is.null(bser) && !identical(s, bser)) bser else NULL,
                                                 round(12 * rolling_years), rf_ann))
  common <- Reduce(intersect, lapply(ser, function(s) as.numeric(s$date)))
  cor_d <- cor_m <- NULL
  if (length(ser) > 1 && length(common) > 30) {
    R <- vapply(ser, function(s) { v <- s$value[match(common, as.numeric(s$date))]; v[-1] / v[-length(v)] - 1 },
                numeric(length(common) - 1))
    cor_d <- stats::cor(R)
    dts <- as.Date(common, origin = "1970-01-01")
    Rm <- vapply(ser, function(s) { m <- .da_period_values(dts, s$value[match(common, as.numeric(s$date))], "month")
                                    m$value[-1] / m$value[-length(m$value)] - 1 },
                 numeric(length(unique(format(dts, "%Y-%m"))) - 1))
    cor_m <- stats::cor(Rm)
  }
  structure(list(metrics = met, benchmark_metrics = bm, benchmark = bname, annual = annual,
                 monthly = monthly, seasonality = seasonality, drawdowns = dds, rolling = rolling,
                 rolling_years = rolling_years, correlation = list(daily = cor_d, monthly = cor_m),
                 series = lapply(ser, function(s) data.frame(date = s$date, value = s$value)),
                 risk_free = risk_free, var_levels = var_levels),
            class = "SimLevAnalysis")
}

#' Methoden fuer SimLevAnalysis
#'
#' @param x,object Ein \code{SimLevAnalysis}-Objekt.
#' @param type Grafik: "overview" (2x2), "growth", "drawdown", "rolling",
#'   "annual" oder "monthly" (Heatmap der ersten Reihe bzw. \code{series}).
#' @param series Reihe fuer die Monats-Heatmap.
#' @param metric Kennzahl der rollierenden Grafik ("cagr", "volatility",
#'   "sharpe", "max_drawdown", "beta", "excess_cagr").
#' @param ... Weitere Argumente.
#' @return Das Objekt (unsichtbar) bzw. bei \code{summary} eine Liste der Tabellen.
#' @name SimLevAnalysis-methods
#' @keywords internal
NULL

.da_fmt <- function(k, v) {
  pct <- c("total_return", "cagr", "mwrr", "volatility", "max_drawdown", "avg_drawdown", "ulcer_index",
           "required_to_recover", "best_day", "worst_day", "best_month", "worst_month", "best_year", "worst_year",
           "positive_months", "avg_gain", "avg_loss", "alpha", "active_return", "tracking_error", "m2", "treynor")
  if (is.na(v)) return("\u2013")
  if (k %in% pct || grepl("^c?var_", k)) return(sprintf("%.2f %%", 100 * v))
  if (k %in% c("start_value", "end_value", "taxes")) return(formatC(v, format = "f", digits = 0, big.mark = ".", decimal.mark = ","))
  if (k %in% c("longest_drawdown_days")) return(sprintf("%.0f T.", v))
  sprintf("%.3f", v)
}

.da_labels <- c(
  total_return = "Gesamtrendite", cagr = "CAGR (TWR)", mwrr = "MWRR (geldgewichtet)", volatility = "Volatilitaet p. a.",
  sharpe = "Sharpe", sortino = "Sortino", calmar = "Calmar", max_drawdown = "Max. Drawdown",
  avg_drawdown = "Mittlerer Drawdown", ulcer_index = "Ulcer Index", upi = "Ulcer Performance Index",
  longest_drawdown_days = "Laengster Drawdown", recovery_factor = "Recovery Factor",
  best_year = "Bestes Jahr", worst_year = "Schlechtestes Jahr", worst_month = "Schlechtester Monat",
  positive_months = "Positive Monate", var_daily_5 = "VaR 5 % (Tag)", cvar_daily_5 = "CVaR 5 % (Tag)",
  var_monthly_5 = "VaR 5 % (Monat)", cvar_monthly_5 = "CVaR 5 % (Monat)", taxes = "Steuern",
  alpha = "Alpha p. a.", beta = "Beta", correlation = "Korrelation", r_squared = "R\u00B2",
  up_capture = "Up-Capture", down_capture = "Down-Capture", capture_spread = "Capture Spread",
  active_return = "Aktive Rendite p. a.", tracking_error = "Tracking Error", information_ratio = "Information Ratio",
  m2 = "M\u00B2 (Modigliani)", treynor = "Treynor")

#' @rdname SimLevAnalysis-methods
#' @export
print.SimLevAnalysis <- function(x, ...) {
  M <- x$metrics
  show <- intersect(c("total_return", "cagr", "mwrr", "volatility", "sharpe", "sortino", "calmar", "max_drawdown",
                      "avg_drawdown", "ulcer_index", "upi", "longest_drawdown_days", "best_year", "worst_year",
                      "worst_month", "positive_months", "var_daily_5", "cvar_daily_5", "var_monthly_5",
                      "cvar_monthly_5", "taxes"), rownames(M))
  w <- max(12, max(nchar(colnames(M))) + 1)
  cat("\n\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  cat("                    SimLev Deep Analysis                       \n")
  cat("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  s1 <- x$series[[1]]
  cat(sprintf("  Zeitraum: %s bis %s (%.1f Jahre)\n\n", format(min(s1$date)), format(max(s1$date)), M["years", 1]))
  cat(sprintf("  %-26s%s\n", "", paste(formatC(colnames(M), width = w), collapse = "")))
  for (k in show) cat(sprintf("  %-26s%s\n", .da_labels[[k]],
                              paste(formatC(vapply(M[k, ], function(v) .da_fmt(k, v), ""), width = w), collapse = "")))
  if (!is.null(x$benchmark_metrics)) {
    B <- x$benchmark_metrics
    cat(sprintf("\n  Gegen Benchmark '%s'\n", x$benchmark))
    cat(sprintf("  %-26s%s\n", "", paste(formatC(colnames(B), width = w), collapse = "")))
    for (k in c("alpha", "beta", "correlation", "r_squared", "up_capture", "down_capture", "capture_spread",
                "active_return", "tracking_error", "information_ratio", "m2"))
      cat(sprintf("  %-26s%s\n", .da_labels[[k]],
                  paste(formatC(vapply(B[k, ], function(v) .da_fmt(k, v), ""), width = w), collapse = "")))
  }
  cat("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n")
  invisible(x)
}

#' @rdname SimLevAnalysis-methods
#' @export
summary.SimLevAnalysis <- function(object, ...) {
  print(object)
  cat("\n  Jahresrenditen (%)\n")
  print(round(100 * object$annual, 2))
  for (nm in names(object$drawdowns)) {
    cat(sprintf("\n  Groesste Drawdowns: %s\n", nm))
    d <- object$drawdowns[[nm]]; d$depth <- sprintf("%.2f %%", 100 * d$depth)
    print(utils::head(d, 5), row.names = FALSE)
  }
  invisible(list(metrics = object$metrics, benchmark = object$benchmark_metrics, annual = object$annual,
                 drawdowns = object$drawdowns))
}

#' @rdname SimLevAnalysis-methods
#' @export
plot.SimLevAnalysis <- function(x, type = c("overview", "growth", "drawdown", "rolling", "annual", "monthly"),
                                series = 1, metric = "cagr", ...) {
  type <- match.arg(type)
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  cols <- c("#2C6E9B", "#B5562B", "#3E8E5A", "#8A5BA8", "#C49A2C", "#4A4A4A")[seq_along(x$series)]
  nms <- names(x$series)
  base_par <- function() graphics::par(mar = c(3.6, 4.4, 2.4, 1), mgp = c(2.5, 0.6, 0), las = 1, cex.axis = 0.85)
  p_growth <- function() {
    rng <- range(unlist(lapply(x$series, function(s) s$value / s$value[1])), finite = TRUE)
    plot(range(do.call(c, lapply(x$series, `[[`, "date"))), rng, type = "n", log = "y",
         xlab = "", ylab = "Wachstum (log)", main = "Wertentwicklung (TWR, Start = 1)")
    for (i in seq_along(x$series)) graphics::lines(x$series[[i]]$date, x$series[[i]]$value / x$series[[i]]$value[1], col = cols[i], lwd = 1.3)
    graphics::legend("topleft", legend = nms, col = cols, lwd = 1.5, bty = "n", cex = 0.85)
  }
  p_dd <- function() {
    dd <- lapply(x$series, function(s) 100 * (s$value / cummax(s$value) - 1))
    plot(range(do.call(c, lapply(x$series, `[[`, "date"))), c(min(unlist(dd)), 0), type = "n",
         xlab = "", ylab = "Drawdown (%)", main = "Drawdowns")
    for (i in seq_along(dd)) graphics::lines(x$series[[i]]$date, dd[[i]], col = cols[i], lwd = 1)
  }
  p_roll <- function() {
    rl <- Filter(Negate(is.null), x$rolling)
    if (!length(rl)) { plot.new(); graphics::title("Rollierend: Zeitraum zu kurz"); return(invisible()) }
    yl <- range(unlist(lapply(rl, function(r) r[[metric]])), na.rm = TRUE) * (if (metric %in% c("beta", "sharpe")) 1 else 100)
    plot(range(do.call(c, lapply(rl, `[[`, "date"))), yl, type = "n", xlab = "",
         ylab = if (metric %in% c("beta", "sharpe")) metric else paste(metric, "(%)"),
         main = sprintf("Rollierend %g J.: %s", x$rolling_years, metric))
    for (nm in names(rl)) graphics::lines(rl[[nm]]$date, rl[[nm]][[metric]] * (if (metric %in% c("beta", "sharpe")) 1 else 100),
                                           col = cols[match(nm, nms)], lwd = 1.2)
    graphics::abline(h = 0, col = "grey60", lty = 3)
  }
  p_annual <- function() {
    A <- t(100 * x$annual); A[is.na(A)] <- 0
    graphics::barplot(A, beside = TRUE, col = cols, border = NA, ylab = "Rendite (%)", main = "Jahresrenditen",
                      names.arg = colnames(A), cex.names = 0.7)
    graphics::abline(h = 0, col = "grey40")
  }
  p_monthly <- function() {
    M <- 100 * x$monthly[[series]][, 1:12, drop = FALSE]
    lim <- max(abs(M), na.rm = TRUE)
    pal <- grDevices::colorRampPalette(c("#B5562B", "#F7F3EE", "#2C6E9B"))(41)
    graphics::image(1:12, seq_len(nrow(M)), t(M), col = pal, zlim = c(-lim, lim), axes = FALSE,
                    xlab = "", ylab = "", main = sprintf("Monatsrenditen: %s", if (is.character(series)) series else names(x$monthly)[series]))
    graphics::axis(1, 1:12, month.abb, cex.axis = 0.75); graphics::axis(2, seq_len(nrow(M)), rownames(M), cex.axis = 0.6)
    if (nrow(M) <= 30) graphics::text(rep(1:12, each = nrow(M)), rep(seq_len(nrow(M)), 12),
                                      ifelse(is.na(M), "", sprintf("%.1f", M)), cex = 0.5)
  }
  if (type == "overview") {
    graphics::par(mfrow = c(2, 2)); base_par()
    p_growth(); p_dd(); p_roll(); p_annual()
  } else {
    base_par()
    switch(type, growth = p_growth(), drawdown = p_dd(), rolling = p_roll(), annual = p_annual(), monthly = p_monthly())
  }
  invisible(x)
}
