# =============================================================================
#  sensitivity.R  —  Parameterstudien um simulation()
# -----------------------------------------------------------------------------
#  sensitivity_grid()         beliebige simulation()-Argumente im Raster
#  rebalancing_sensitivity()  Rebalancing-Frequenz, Versatz und Baender
#  lumpsum_vs_dca()           Einmalanlage gegen gestreckten Einstieg
#  leveraged_series()         Hebelreihe aus einem Index (MSCI-Formel)
#  leverage_sensitivity()     Kennzahlen ueber den Hebel, optimaler Hebel
# =============================================================================

#' simulation() ueber ein Parameterraster
#'
#' Ruft [simulation()] fuer jede Kombination von \code{grid} auf und sammelt
#' die Kennzahlen. Grundlage der speziellen Studien in diesem Abschnitt.
#'
#' @param data,strategy Wie in [simulation()].
#' @param grid Benannte Liste von Argumentwerten, z. B.
#'   \code{list(balance_unit = c("month", "year"), balance_thresh = c(5, 10))}.
#'   Alternativ ein data.frame mit einer Zeile je Lauf. Listen-Spalten
#'   (z. B. \code{split_thresh}) sind erlaubt. \code{NA} laesst das Argument
#'   weg (Standardwert von [simulation()]).
#' @param sim_args Gemeinsame Argumente fuer alle Laeufe.
#' @param metrics Funktion \code{SimLevResult -> benannter Vektor}
#'   (Standard [study_metrics()]).
#' @param cores Prozesse (Fork auf Unix, PSOCK auf Windows).
#' @param keep_results Ergebnisse der Laeufe zusaetzlich zurueckgeben.
#' @return data.frame: Rasterspalten plus Kennzahlen (Attribut \code{results}
#'   bei \code{keep_results = TRUE}).
#' @examples
#' set.seed(1)
#' d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = 1500))
#' d$A <- 100 * cumprod(1 + rnorm(1500, 3e-4, 0.01)); d$B <- 100 * cumprod(1 + rnorm(1500, 1e-4, 0.004))
#' st <- create_strategy(A = asset_config("etf", "bnh", 0.6), B = asset_config("etf", "bnh", 0.4))
#' sensitivity_grid(d, st, list(balance_unit = c("month", "year")),
#'                  sim_args = list(balance_mode = TRUE, balance_span = 1))[, c("balance_unit", "cagr", "trades")]
#' @export
sensitivity_grid <- function(data, strategy, grid, sim_args = list(), metrics = study_metrics,
                             cores = 1L, keep_results = FALSE) {
  design <- if (is.data.frame(grid)) grid else expand.grid(grid, stringsAsFactors = FALSE, KEEP.OUT.ATTRS = FALSE)
  if (!nrow(design)) stop("Leeres Raster.")
  run <- function(i) {
    a <- lapply(design[i, , drop = FALSE], function(v) if (is.list(v)) v[[1]] else v)
    a <- a[!vapply(a, function(v) length(v) == 1L && is.atomic(v) && is.na(v), TRUE)]   # NA = Argument weglassen
    args <- utils::modifyList(sim_args, a)
    res <- tryCatch(suppressWarnings(suppressMessages(do.call(simulation, c(list(data = data, strategy = strategy), args)))),
                    error = function(e) e)
    if (inherits(res, "error")) return(list(m = NULL, err = conditionMessage(res), res = NULL))
    list(m = metrics(res), err = NA_character_, res = if (keep_results) res else NULL)
  }
  out <- .par_lapply(seq_len(nrow(design)), run, cores)
  mnames <- names(Filter(Negate(is.null), lapply(out, `[[`, "m"))[[1]] %||% character(0))
  M <- t(vapply(out, function(o) if (is.null(o$m)) rep(NA_real_, length(mnames)) else o$m[mnames], numeric(length(mnames))))
  if (length(mnames) == 1) M <- t(M)
  colnames(M) <- mnames
  disp <- design
  for (k in names(disp)) if (is.list(disp[[k]])) disp[[k]] <- vapply(disp[[k]], function(v) paste(v, collapse = "/"), "")
  tab <- data.frame(disp, M, error = vapply(out, `[[`, "", "err"), check.names = FALSE, stringsAsFactors = FALSE)
  if (all(is.na(tab$error))) tab$error <- NULL
  if (keep_results) attr(tab, "results") <- lapply(out, `[[`, "res")
  tab
}

#' Rebalancing-Sensitivitaet
#'
#' Vergleicht Rebalancing-Frequenzen, Versatz vor dem Periodenende und
#' Toleranzbaender (absolut oder relativ) fuer eine Strategie, wie die
#' Rebalancing-Sensitivity von testfol.io. Baender werden an den
#' Kalenderterminen der jeweiligen Frequenz geprueft.
#'
#' @inheritParams sensitivity_grid
#' @param frequencies Benannte Liste von \code{c(unit, span)}; Standard:
#'   monatlich, zweimonatlich, quartalsweise, viermonatlich, halbjaehrlich,
#'   jaehrlich.
#' @param offsets Kalendertage vor dem Periodenende (0 = letzter Tag).
#'   \code{NULL} rebalanciert am Periodenanfang.
#' @param bands Toleranzbaender in Prozent (\code{NA} = immer rebalancieren).
#' @param band_type "absolute" (Prozentpunkte) oder "relative" (Prozent des
#'   Zielgewichts), siehe \code{balance_thresh_type} in [simulation()].
#' @param include_none Zusaetzlich einen Lauf ohne Rebalancing.
#' @return data.frame mit frequency, offset, band, band_type und Kennzahlen.
#' @export
rebalancing_sensitivity <- function(data, strategy,
                                    frequencies = list(monthly = c("month", 1), bimonthly = c("month", 2),
                                                       quarterly = c("quarter", 1), four_monthly = c("month", 4),
                                                       semiannual = c("month", 6), yearly = c("year", 1)),
                                    offsets = NULL, bands = NA, band_type = c("absolute", "relative"),
                                    include_none = TRUE, sim_args = list(), metrics = study_metrics, cores = 1L) {
  band_type <- match.arg(band_type)
  rows <- list()
  for (fn in names(frequencies)) {
    f <- frequencies[[fn]]
    for (off in (if (is.null(offsets)) NA else offsets)) for (b in bands) {
      a <- list(balance_mode = TRUE, balance_unit = f[[1]], balance_span = as.numeric(f[[2]]),
                balance_thresh_type = band_type)
      if (!is.na(off)) { a$balance_anchor <- "end"; a$balance_days <- off + 1 }
      if (!is.na(b)) a$balance_thresh <- b
      rows[[length(rows) + 1L]] <- list(label = data.frame(frequency = fn, offset = off, band = b, band_type = band_type),
                                         args = a)
    }
  }
  if (include_none) rows[[length(rows) + 1L]] <- list(label = data.frame(frequency = "none", offset = NA, band = NA, band_type = NA),
                                                      args = list(balance_mode = FALSE))
  run <- function(i) {
    args <- utils::modifyList(sim_args, rows[[i]]$args)
    res <- tryCatch(suppressWarnings(suppressMessages(do.call(simulation, c(list(data = data, strategy = strategy), args)))),
                    error = function(e) NULL)
    if (is.null(res)) return(NULL)
    metrics(res)
  }
  out <- .par_lapply(seq_along(rows), run, cores)
  ok <- !vapply(out, is.null, TRUE)
  if (!any(ok)) stop("Alle Laeufe fehlgeschlagen.")
  M <- do.call(rbind, out[ok])
  tab <- data.frame(do.call(rbind, lapply(rows[ok], `[[`, "label")), M, check.names = FALSE, stringsAsFactors = FALSE)
  rownames(tab) <- NULL
  class(tab) <- c("SimLevSensitivity", "data.frame")
  attr(tab, "kind") <- "rebalancing"
  tab
}

#' Einmalanlage gegen gestreckten Einstieg (Lump Sum vs. DCA)
#'
#' Vergleicht fuer rollierende Starttermine (jeweils am Monatsersten) die
#' sofortige Anlage eines Betrags mit einem Einstieg in \code{months} gleichen
#' Monatsraten. Verglichen wird das Vermoegen nach \code{horizon} Jahren.
#' Nach der Einstiegsphase wird das DCA-Depot mit der Wertentwicklung der
#' Einmalanlage fortgeschrieben (exakt ohne Steuern; mit
#' \code{tax_mode = "person"} eine Naeherung).
#'
#' @inheritParams sensitivity_grid
#' @param amount Anlagebetrag.
#' @param months Anzahl Monatsraten des gestreckten Einstiegs.
#' @param horizon Vergleichshorizont in Jahren ab Start.
#' @param step Abstand der Starttermine in Monaten.
#' @return \code{SimLevLumpSum}: data.frame je Start (start, lump_sum, dca,
#'   advantage = Lump Sum / DCA - 1) und Zusammenfassung mit Gewinnquote der
#'   Einmalanlage, mittlerem Vorsprung bei Gewinn (MLSA) und mittlerem
#'   Rueckstand bei Verlust (MLSD).
#' @export
lumpsum_vs_dca <- function(data, strategy, amount = 10000, months = 12, horizon = 10, step = 1,
                           sim_args = list(), cores = 1L) {
  data <- data[order(as.Date(data$date)), , drop = FALSE]
  d <- as.Date(data$date)
  if (isTRUE(sim_args$tax_mode == "person")) warning("Mit Steuern ist die Fortschreibung nach der Einstiegsphase eine Naeherung.")
  firsts <- d[format(d, "%d") == "01"]
  last_ok <- seq.Date(max(d), by = paste0("-", horizon, " years"), length.out = 2)[2]
  starts <- firsts[firsts <= last_ok]
  starts <- starts[seq(1, length(starts), by = step)]
  if (!length(starts)) stop("Historie zu kurz fuer den Horizont.")
  run <- function(s) {
    e <- seq.Date(s, by = paste(horizon, "years"), length.out = 2)[2] - 1
    e_dca <- seq.Date(s, by = paste(months, "months"), length.out = 2)[2] - 1
    w <- data[d >= s & d <= e, , drop = FALSE]
    ls <- suppressWarnings(suppressMessages(do.call(simulation, c(list(data = w, strategy = strategy, start_value = amount), sim_args))))
    wd <- data[d >= s & d <= e_dca, , drop = FALSE]
    dca <- suppressWarnings(suppressMessages(do.call(simulation, c(list(data = wd, strategy = strategy,
              start_value = amount / months, dca_mode = TRUE, dca_value = amount / months, dca_span = 1,
              dca_unit = "month", dca_skip = TRUE), sim_args))))
    ix <- result_index(ls)
    k <- match(max(wd$date), ix$date)
    dca_end <- utils::tail(dca$worth, 1) * ix$value[nrow(ix)] / ix$value[k]
    c(lump_sum = utils::tail(ls$worth, 1), dca = dca_end)
  }
  res <- .par_lapply(as.list(starts), run, cores)
  tab <- data.frame(start = starts, do.call(rbind, res))
  tab$advantage <- tab$lump_sum / tab$dca - 1
  win <- tab$advantage > 0
  structure(tab, class = c("SimLevLumpSum", "data.frame"),
            summary = c(win_rate = mean(win), mean_advantage = mean(tab$advantage), median_advantage = stats::median(tab$advantage),
                        mlsa = if (any(win)) mean(tab$advantage[win]) else NA_real_,
                        mlsd = if (any(!win)) mean(tab$advantage[!win]) else NA_real_),
            settings = list(amount = amount, months = months, horizon = horizon))
}

#' @rdname SimLevAnalysis-methods
#' @export
print.SimLevLumpSum <- function(x, ...) {
  s <- attr(x, "summary"); st <- attr(x, "settings")
  cat(sprintf("Lump Sum vs. DCA: %d Starttermine, %s in %d Monatsraten, Horizont %g Jahre\n",
              nrow(x), formatC(st$amount, format = "f", digits = 0, big.mark = ".", decimal.mark = ","), st$months, st$horizon))
  cat(sprintf("  Einmalanlage vorn:          %.1f %% der Starttermine\n", 100 * s["win_rate"]))
  cat(sprintf("  Vorsprung Mittel / Median:  %+.2f %% / %+.2f %%\n", 100 * s["mean_advantage"], 100 * s["median_advantage"]))
  cat(sprintf("  MLSA (wenn vorn):           %+.2f %%\n", 100 * s["mlsa"]))
  cat(sprintf("  MLSD (wenn hinten):         %+.2f %%\n", 100 * s["mlsd"]))
  invisible(x)
}

#' Gehebelte Reihe aus einem Index erzeugen
#'
#' Bildet eine taeglich zurueckgesetzte Hebelreihe nach der MSCI-Formel plus
#' Fondskosten (wie die Ticker-Parameter L, E, SP und FR bei testfol.io):
#' \deqn{r = L x + (1 - L) i T/360 - TER\cdot T/365 - s\cdot m(L) T/360}
#'
#' @param data data.frame mit \code{date} und der Indexspalte.
#' @param index Spaltenname des Index (Niveau).
#' @param leverage Hebel L.
#' @param rate Finanzierungszins in Prozent p. a. (Skalar oder Spaltenname).
#' @param expense TER in Prozent p. a.
#' @param spread Spread auf den finanzierten Anteil in Prozent p. a.
#' @param start Startwert der Reihe.
#' @return Numerischer Vektor (Niveau); bei Totalverlust bleibt die Reihe bei 0.
#' @export
leveraged_series <- function(data, index, leverage = 2, rate = 0, expense = 0, spread = 0, start = 100) {
  idx <- .fill_na(as.numeric(data[[index]]), "locf")
  dd <- c(1, as.numeric(diff(as.Date(data$date))))
  x <- c(0, idx[-1] / idx[-length(idx)] - 1)
  rt <- .resolve_series(rate, data, "rate")
  m <- max(leverage - 1, 0) + max(-leverage, 0)
  r <- leverage * x + (1 - leverage) * rt / 100 * dd / 360 - expense / 100 * dd / 365 - spread / 100 * m * dd / 360
  r[1] <- 0
  ko <- which(r <= -1)
  if (length(ko)) r[ko[1]:length(r)] <- -1
  v <- start * cumprod(1 + r)
  v[v < 0] <- 0
  v
}

#' Kennzahlen ueber den Hebel
#'
#' Erzeugt fuer jeden Hebel eine Reihe mit [leveraged_series()], simuliert
#' sie als Buy-and-Hold (oder mit einer eigenen Strategie fuer das Asset
#' \code{"LEV"}) und bestimmt den Hebel mit der hoechsten CAGR bzw. Sharpe
#' Ratio, wie die LETF-Analyse von testfol.io.
#'
#' @inheritParams leveraged_series
#' @param leverages Zu pruefende Hebel.
#' @param strategy Optional Strategie mit dem Asset \code{"LEV"}; Standard
#'   Buy-and-Hold-ETF mit 30 \% Teilfreistellung.
#' @inheritParams sensitivity_grid
#' @return \code{SimLevSensitivity}-data.frame mit leverage und Kennzahlen;
#'   Attribut \code{optimal} (Hebel mit maximaler CAGR und Sharpe).
#' @export
leverage_sensitivity <- function(data, index, leverages = seq(0.5, 4, by = 0.25), rate = 0, expense = 0,
                                 spread = 0, strategy = NULL, sim_args = list(), metrics = study_metrics, cores = 1L) {
  strategy <- strategy %||% create_strategy(LEV = asset_config("etf", "bnh", asset_bonus = 30))
  run <- function(L) {
    df <- data.frame(date = as.Date(data$date), LEV = leveraged_series(data, index, L, rate, expense, spread))
    if (any(df$LEV <= 0)) df$LEV[df$LEV <= 0] <- 1e-8
    res <- tryCatch(suppressWarnings(suppressMessages(do.call(simulation, c(list(data = df, strategy = strategy), sim_args)))),
                    error = function(e) NULL)
    if (is.null(res)) return(NULL)
    metrics(res)
  }
  out <- .par_lapply(as.list(leverages), run, cores)
  ok <- !vapply(out, is.null, TRUE)
  tab <- data.frame(leverage = leverages[ok], do.call(rbind, out[ok]), check.names = FALSE)
  class(tab) <- c("SimLevSensitivity", "data.frame")
  attr(tab, "kind") <- "leverage"
  attr(tab, "optimal") <- c(cagr = tab$leverage[which.max(tab$cagr)],
                            sharpe = if ("sharpe" %in% names(tab)) tab$leverage[which.max(tab$sharpe)] else NA)
  tab
}

#' @rdname SimLevAnalysis-methods
#' @export
plot.SimLevSensitivity <- function(x, metric = "cagr", ...) {
  old <- graphics::par(no.readonly = TRUE); on.exit(graphics::par(old))
  graphics::par(mar = c(4, 4.6, 2.5, 1), mgp = c(2.9, 0.7, 0), las = 1)
  kind <- attr(x, "kind") %||% "grid"
  y <- x[[metric]] * (if (metric %in% c("cagr", "ttwror", "max_drawdown", "avg_drawdown")) 100 else 1)
  if (kind == "leverage") {
    plot(x$leverage, y, type = "b", pch = 19, col = "#2C6E9B", xlab = "Hebel", ylab = metric,
         main = sprintf("%s nach Hebel", metric), ...)
    graphics::abline(v = x$leverage[which.max(x[[metric]])], lty = 3, col = "#B5562B")
  } else {
    lab <- paste(x$frequency, ifelse(is.na(x$band), "", paste0("\u00B1", x$band)),
                 ifelse(is.na(x$offset), "", paste0("-", x$offset, "d")))
    graphics::par(mar = c(4, 9, 2.5, 1))
    graphics::barplot(rev(y), names.arg = rev(lab), horiz = TRUE, col = "#2C6E9B", border = NA,
                      xlab = metric, main = sprintf("Rebalancing-Varianten: %s", metric), cex.names = 0.7, ...)
  }
  invisible(x)
}

#' @rdname SimLevAnalysis-methods
#' @export
print.SimLevSensitivity <- function(x, ...) {
  keep <- intersect(c("frequency", "offset", "band", "band_type", "leverage", "cagr", "ttwror", "max_drawdown",
                      "sharpe", "ulcer_index", "taxes", "trades"), names(x))
  y <- as.data.frame(unclass(x))[, keep, drop = FALSE]
  # Platz sparen: TTWROR nur zeigen, wenn sie von der CAGR abweicht; konstanten Bandtyp weglassen
  if (all(c("cagr", "ttwror") %in% names(y)) && isTRUE(all.equal(y$cagr, y$ttwror))) y$ttwror <- NULL
  bt <- if ("band_type" %in% names(y)) unique(y$band_type[!is.na(y$band)]) else character(0)
  if ("band_type" %in% names(y) && length(bt) <= 1) {
    y$band_type <- NULL
    if (length(bt) == 1) cat(sprintf("Toleranzbaender: %s\n", if (bt == "relative") "relativ (% des Zielgewichts)" else "absolut (Prozentpunkte)"))
  }
  if ("band" %in% names(y)) y$band <- ifelse(is.na(y$band), "-", format(y$band))
  for (k in intersect(c("cagr", "ttwror", "max_drawdown"), names(y))) y[[k]] <- sprintf("%.2f %%", 100 * y[[k]])
  for (k in intersect(c("sharpe", "ulcer_index"), names(y))) y[[k]] <- sprintf("%.3f", y[[k]])
  for (k in intersect(c("taxes", "trades"), names(y))) y[[k]] <- sprintf("%.1f", y[[k]])
  print(y, row.names = FALSE)
  if (!is.null(attr(x, "optimal"))) cat(sprintf("Optimaler Hebel: CAGR %.2f, Sharpe %.2f\n", attr(x, "optimal")[1], attr(x, "optimal")[2]))
  invisible(x)
}
