# plot_dashboard.R
# Umfassende Dashboard-Grafiken fuer SimLev-Ergebnisse

#' Layout fuer style = "custom": 1-2 Panels in einer Zeile, sonst 2 Spalten mit bis zu 4 Zeilen;
#' freie Felder 0 (leer), damit kein Panel doppelt erscheint (bei 3, 5, 7 Panels)
#' @keywords internal
#' @noRd
.dash_custom_layout <- function(n) {
  nr <- c(1L, 1L, 2L, 2L, 3L, 3L, 4L, 4L)[n]; nc <- ceiling(n / nr)
  matrix(c(seq_len(n), rep(0L, nr * nc - n)), nrow = nr, byrow = TRUE)
}

#' Dashboard-Grafik fuer Simulationsergebnisse erstellen
#'
#' Zeichnet ein mehrteiliges Dashboard (Basisgrafik) fuer ein SimLevResult.
#' Massgebliche Beschreibung: Hilfeseite \code{?plot.SimLevResult}.
#'
#' @param x Ein SimLevResult-Objekt
#' @param style Zeichenkette: "full" (alle Panels, Standard), "compact" (4 Kern-Panels) oder "custom"
#' @param panels Zeichenvektor: Welche Panels gezeichnet werden (nur bei style = "custom";
#'   sonst Warnung). Moeglich: "performance", "drawdown", "distribution", "rolling", "monthly",
#'   "stats", "correlation", "comparison" (eindeutige Abkuerzungen erlaubt, unbekannte
#'   Namen sind ein Fehler)
#' @param compare Optional: zweites SimLevResult-Objekt zum Vergleich (gleicher Zeitraum)
#' @param colors Benannte Liste: eigenes Farbschema (primary, secondary, positive, negative,
#'   neutral, background, grid; R-Farbname oder Hex-Code, ungueltige Farben sind ein Fehler);
#'   nicht genannte Elemente aus dem Standard, unbekannte Namen sind ein Fehler;
#'   NULL = Standard-Farbschema
#' @param ... Weitere Argumente (ignoriert)
#'
#' @return NULL, unsichtbar (die Grafik entsteht als Nebeneffekt)
#' @export
#'
#' @examples
#' result <- simulation(data, strategy, start_value = 10000)
#' 
#' # Vollstaendiges Dashboard
#' plot(result)
#' 
#' # Kompakte Variante
#' plot(result, style = "compact")
#' 
#' # Eigene Panel-Auswahl
#' plot(result, style = "custom", panels = c("performance", "drawdown", "distribution"))
#' 
#' # Zwei Strategien vergleichen
#' result2 <- simulation(data, strategy2, start_value = 10000)
#' plot(result, compare = result2)
#' @noRd
plot.SimLevResult <- function(
    x, 
    style = c("full", "compact", "custom"),
    panels = c("performance", "drawdown", "distribution", "rolling", "monthly", "stats"),
    compare = NULL,
    colors = NULL,
    ...
) {
  style <- match.arg(style)
  panels_given <- !missing(panels)
  
  # panels pruefen: Tippfehler sind ein Fehler (match.arg(several.ok = TRUE) verwirft
  # nicht passende Werte still); Abkuerzungen wie bei match.arg erlaubt
  all_panels <- c("performance", "drawdown", "distribution", "rolling", "monthly", "stats", "correlation", "comparison")
  if (!is.character(panels) || !length(panels) || anyNA(panels))
    stop(sprintf("plot.SimLevResult: panels muss ein Zeichenvektor sein (erhalten: %s); m\u00f6glich: %s.",
                 paste(format(panels), collapse = ", "), paste0("\"", all_panels, "\"", collapse = ", ")))
  pm <- pmatch(panels, all_panels, duplicates.ok = TRUE)
  if (anyNA(pm))
    stop(sprintf("plot.SimLevResult: unbekannte(s) Panel(s) %s in panels; m\u00f6glich: %s.",
                 paste0("\"", panels[is.na(pm)], "\"", collapse = ", "), paste0("\"", all_panels, "\"", collapse = ", ")))
  panels <- unique(all_panels[pm])
  if (panels_given && style != "custom")
    warning(sprintf("plot.SimLevResult: panels wirkt nur mit style = \"custom\" und wird bei style = \"%s\" ignoriert.", style))
  
  # Standard-Farbschema; eigene Farben ergaenzen es (Teilangabe moeglich)
  default_colors <- list(
    primary = "#2E86AB",      # Blau
    secondary = "#A23B72",    # Violett
    positive = "#06A77D",     # Gruen
    negative = "#D62246",     # Rot
    neutral = "#6C757D",      # Grau
    background = "#F8F9FA",   # Hellgrau
    grid = "#E9ECEF"          # Gitterlinien
  )
  if (is.null(colors)) colors <- default_colors else {
    if (!(is.list(colors) || is.character(colors)) || is.null(names(colors)) || any(names(colors) == ""))
      stop(sprintf("plot.SimLevResult: colors muss eine benannte Liste (oder ein benannter Zeichenvektor) sein, z. B. list(primary = \"#003366\"); m\u00f6glich: %s.",
                   paste(names(default_colors), collapse = ", ")))
    unk <- setdiff(names(colors), names(default_colors))
    if (length(unk)) stop(sprintf("plot.SimLevResult: unbekannte Farbe(n) %s in colors; m\u00f6glich: %s.",
                                  paste0("'", unk, "'", collapse = ", "), paste(names(default_colors), collapse = ", ")))
    # Farbwerte pruefen: je Element ein Wert, den grDevices::col2rgb() versteht (Name oder Hex-Code)
    ok <- vapply(as.list(colors), function(v) length(v) == 1 && !is.na(v) && (is.character(v) || is.numeric(v)) &&
                   !inherits(tryCatch(grDevices::col2rgb(v), error = function(e) e), "error"), TRUE)
    if (!all(ok)) stop(sprintf("plot.SimLevResult: ung\u00fcltige Farbe(n) in colors: %s; erwartet je Element ein R-Farbname (z. B. \"navy\", siehe grDevices::colors()) oder ein Hex-Code \"#RRGGBB\" bzw. \"#RRGGBBAA\".",
                               paste(sprintf("%s = %s", names(colors)[!ok], vapply(as.list(colors)[!ok], function(v) paste(deparse(v), collapse = ""), "")), collapse = ", ")))
    colors <- utils::modifyList(default_colors, as.list(colors))
  }
  # Transparenz ueber adjustcolor() (gleiche RGBA-Werte wie das fruehere Hex-Suffix "30"/"40"/"80" bei
  # Standardfarben; funktioniert auch mit Farbnamen)
  alpha_col <- function(col, a) grDevices::adjustcolor(col, alpha.f = a / 255)
  
  # compare: Ergebnis ueber dieselben Tage (wird auf der Datumsachse von x gezeichnet)
  if (!is.null(compare) && (!inherits(compare, "SimLevResult") || length(compare$worth) != length(x$worth)))
    stop(sprintf("plot.SimLevResult: compare muss ein SimLevResult \u00fcber dieselben Tage wie x sein (%s); NULL = kein Vergleich.",
                 if (!inherits(compare, "SimLevResult")) sprintf("erhalten: Objekt der Klasse '%s'", class(compare)[1])
                 else sprintf("%d statt %d Tage", length(compare$worth), length(x$worth))))
  # style = "custom": Panels, die einen Vergleich brauchen, ohne compare nicht zeichnen (mit Warnung statt Leerfeld)
  if (style == "custom" && is.null(compare) && any(need <- panels %in% c("correlation", "comparison"))) {
    skipped <- panels[need]
    warning(sprintf("plot.SimLevResult: Panel(s) %s nicht gezeichnet: %s ein Vergleichsergebnis (compare).",
                    paste0("\"", skipped, "\"", collapse = ", "), if (length(skipped) > 1) "ben\u00f6tigen" else "ben\u00f6tigt"))
    panels <- panels[!need]
  }
  
  # Layout je nach Stil festlegen
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
    # Custom - vom Nutzer gewaehlte Panels
    layout_matrix <- if (length(panels)) .dash_custom_layout(length(panels)) else matrix(1L)   # nichts zeichenbar: Hinweisfeld
    selected_panels <- panels
  }
  
  # Layout einrichten
  old_par <- par(no.readonly = TRUE)
  on.exit(par(old_par))
  
  layout(layout_matrix)
  par(mar = c(4, 4, 3, 2), bg = colors$background)
  
  # Kurzform fuer Achsen und Endwert (Einheit EUR im Achsentitel): Tsd. bzw. Mio.; Achsenwerte mit so
  # vielen Nachkommastellen, dass sie exakt sind (12.5 Tsd. statt 12 Tsd.), Endwert mit 3 gueltigen Stellen
  format_amount <- function(x, signif3 = FALSE) {
    u <- ifelse(abs(x) >= 1e6, 1e6, ifelse(abs(x) >= 1e3, 1e3, 1)); v <- x / u
    d <- if (signif3) pmax(0, 2 - floor(log10(pmax(abs(v), 1)))) else
      vapply(v, function(z) { for (k in 0:2) if (abs(z - round(z, k)) < 1e-8 * max(1, abs(z))) return(k); 3L }, 0)
    paste0(sprintf("%.*f", as.integer(d), v), ifelse(u == 1e6, " Mio.", ifelse(u == 1e3, " Tsd.", "")))
  }
  
  # Beschriftung mit hinterlegtem Hintergrund (bleibt lesbar, wenn eine Kurve darunter verlaeuft)
  label_bg <- function(x, y, lab, adj, col, cex = 1, font = 2, xpd = FALSE) {
    x <- as.numeric(x); w <- strwidth(lab, cex = cex, font = font); h <- strheight(lab, cex = cex, font = font)
    x0 <- x - adj[1] * w; y0 <- y - adj[2] * h; px <- 0.3 * strwidth("m", cex = cex)
    rect(x0 - px, y0 - 0.2 * h, x0 + w + px, y0 + 1.2 * h, col = alpha_col(colors$background, 0xD9), border = NA, xpd = xpd)
    text(x, y, lab, adj = adj, col = col, cex = cex, font = font, xpd = xpd)
  }
  
  # Daten entnehmen
  dates <- if (!is.null(x$dates)) x$dates else seq_along(x$worth)
  n_days <- length(x$worth)

  # R1-19: Kennzahlen wie in x$statistics (simulation()): Tagesrenditen um
  # Einzahlungen bereinigt, aufgefuellte Tage (LOCF) ausgeschlossen, Annualisierung
  # mit der tatsaechlichen Beobachtungsfrequenz statt fest 252
  .dash <- .dashboard_returns(x)
  # Mit Sparplan: CAGR geldgewichtet (XIRR), Drawdowns und Gesamtrendite zeitgewichtet (twr_index)
  ext <- .dash$external_flows
  tot_ret <- function(r) { f <- .dashboard_returns(r)
    if (f$external_flows) tail(f$twr_index, 1) - 1 else tail(r$worth, 1) / head(r$worth, 1) - 1 }
  ann_vol <- function(r) r$statistics$sd * sqrt(.dashboard_returns(r)$ppy)
  empty_panel <- function(title) {
    plot.new(); plot.window(xlim = c(0, 1), ylim = c(0, 1))
    title(title, col.main = colors$primary, cex.main = 1.3, font.main = 2)
    text(0.5, 0.5, "Zu wenige Daten", cex = 1.1, col = colors$neutral)
  }
  if (!length(selected_panels)) {                    # style = "custom" ohne zeichenbare Panels
    plot.new(); plot.window(xlim = c(0, 1), ylim = c(0, 1))
    text(0.5, 0.5, sprintf("Keine zeichenbaren Panels:\n%s ohne Vergleichsergebnis (compare)", paste(skipped, collapse = ", ")),
         cex = 1.1, col = colors$neutral)
  }
  
  # ===========================================================================
  # PANEL 1: PORTFOLIO-ENTWICKLUNG
  # ===========================================================================
  if ("performance" %in% selected_panels) {
    # y-Bereich ueber alle gezeichneten Kurven (Depotwert, Vergleich, Einzahlungen), damit nichts
    # abgeschnitten wird; nur Depotwert: wie bisher range(x$worth)
    y_rng <- range(c(x$worth, if (!is.null(compare)) compare$worth, if (ext) .dash$invested), finite = TRUE)
    # Raender nach der Breite der Achsenbeschriftung (Einheit im Achsentitel) und des Endwert-Labels,
    # damit nichts abgeschnitten wird oder ueberlappt
    y_ticks <- pretty(y_rng); tick_lab <- format_amount(y_ticks)
    final_val <- tail(x$worth, 1); final_lab <- format_amount(final_val, signif3 = TRUE)
    csi <- par("csi")
    w_tick <- max(strwidth(tick_lab, units = "inches", cex = par("cex.axis"))) / csi
    w_end <- strwidth(final_lab, units = "inches", cex = 0.9, font = 2) / csi
    par(mar = c(4, w_tick + 2.6, 3, max(2, w_end + 1)))
    plot(dates, x$worth, 
         type = "n",
         ylim = y_rng,
         xlab = "", 
         ylab = "",
         main = "Wertentwicklung des Depots",
         col.main = colors$primary,
         cex.main = 1.3,
         font.main = 2,
         las = 1,
         yaxt = "n")
    
    # Gitter zeichnen
    grid(col = colors$grid, lty = 1, lwd = 0.5)
    
    # Flaeche unter der Kurve schattieren
    polygon(c(dates, rev(dates)), 
            c(x$worth, rep(min(x$worth), length(dates))),
            col = alpha_col(colors$primary, 0x30),
            border = NA)
    
    # Linie zeichnen
    lines(dates, x$worth, col = colors$primary, lwd = 2.5)
    # Mit Sparplan: Summe der Einzahlungen (Startwert + Sparraten) als Treppenlinie
    if (ext) lines(dates, .dash$invested, col = colors$neutral, lwd = 1.5, lty = 3, type = "s")
    
    # Vergleichsergebnis einzeichnen, falls angegeben
    if (!is.null(compare) && "performance" %in% selected_panels) {
      lines(dates, compare$worth, col = colors$secondary, lwd = 2.5, lty = 2)
      legend("topleft", 
             legend = c("Strategie 1", "Strategie 2", if (ext) "Einzahlungen"),
             col = c(colors$primary, colors$secondary, if (ext) colors$neutral),
             lty = c(1, 2, if (ext) 3),
             lwd = 2,
             bg = "white",
             box.col = colors$grid)
    } else if (ext) {
      legend("topleft", legend = c("Depotwert", "Einzahlungen"), col = c(colors$primary, colors$neutral),
             lty = c(1, 3), lwd = 2, bg = "white", box.col = colors$grid)
    }
    
    # Eigene y-Achse (Betraege ohne Einheit, Einheit im Achsentitel)
    axis(2, at = y_ticks, labels = tick_lab, las = 1)
    title(ylab = "Depotwert (EUR)", line = w_tick + 1.4)
    
    # Endwert beschriften (im rechten Rand, nicht abgeschnitten)
    label_bg(as.numeric(tail(dates, 1)) + strwidth("m", cex = 0.9), final_val, final_lab, adj = c(0, 0.5),
             col = colors$primary, cex = 0.9, xpd = NA)
    par(mar = c(4, 4, 3, 2))
  }
  
  # ===========================================================================
  # PANEL 2: DRAWDOWN-GRAFIK
  # ===========================================================================
  if ("drawdown" %in% selected_panels) {
    drawdowns_pct <- x$drawdowns * 100
    
    plot(dates, -drawdowns_pct,
         type = "n",
         xlab = "",
         ylab = "Drawdown (%)",
         main = if (ext) "Drawdown-Analyse (zeitgewichtet)" else "Drawdown-Analyse",
         col.main = colors$primary,
         cex.main = 1.3,
         font.main = 2,
         las = 1,
         ylim = c(min(-drawdowns_pct) * 1.1, 0))
    
    # Gitter zeichnen
    grid(col = colors$grid, lty = 1, lwd = 0.5)
    
    # Flaeche schattieren
    polygon(c(dates, rev(dates)),
            c(-drawdowns_pct, rep(0, length(dates))),
            col = alpha_col(colors$negative, 0x40),
            border = NA)
    
    # Linie zeichnen
    lines(dates, -drawdowns_pct, col = colors$negative, lwd = 2)
    
    # Linie fuer den maximalen Drawdown
    max_dd <- max(drawdowns_pct)
    abline(h = -max_dd, col = colors$negative, lty = 2, lwd = 1.5)
    label_bg(dates[1], -max_dd, sprintf("Max.: %.1f%%", max_dd), adj = c(0, -0.5), col = colors$negative)
  }
  
  # ===========================================================================
  # PANEL 3: RENDITEVERTEILUNG
  # ===========================================================================
  if ("distribution" %in% selected_panels && length(.dash$returns) < 3) {
    empty_panel("Verteilung der Tagesrenditen")
  } else if ("distribution" %in% selected_panels) {
    # Taegliche Renditen in Prozent (einzahlungsbereinigt, ohne aufgefuellte Tage)
    returns <- .dash$returns * 100
    
    hist(returns,
         breaks = 50,
         col = alpha_col(colors$primary, 0x80),
         border = colors$primary,
         main = "Verteilung der Tagesrenditen",
         xlab = "Tagesrendite (%)",
         ylab = "H\u00e4ufigkeit",
         col.main = colors$primary,
         cex.main = 1.3,
         font.main = 2,
         las = 1)
    
    # Normalverteilung ueberlagern
    x_seq <- seq(min(returns), max(returns), length.out = 100)
    y_norm <- dnorm(x_seq, mean = mean(returns), sd = sd(returns))
    y_norm_scaled <- y_norm * length(returns) * diff(range(returns)) / 50
    lines(x_seq, y_norm_scaled, col = colors$secondary, lwd = 2, lty = 2)
    
    # Senkrechte Linie beim Mittelwert
    abline(v = mean(returns), col = colors$positive, lwd = 2, lty = 2)
    
    # Kennzahlen einblenden
    legend("topright",
           legend = c(
             sprintf("Mittel: %.2f%%", mean(returns)),
             sprintf("Std.-Abw.: %.2f%%", sd(returns)),
             sprintf("Schiefe: %.2f", x$statistics$skewness),
             sprintf("W\u00f6lbung: %.2f", x$statistics$kurtosis)
           ),
           bty = "o", box.col = NA, bg = alpha_col(colors$background, 0xD9),   # lesbar auch ueber Balken
           text.col = colors$primary,
           cex = 0.9)
  }
  
  # ===========================================================================
  # PANEL 4: ROLLIERENDE RENDITEN
  # ===========================================================================
  if ("rolling" %in% selected_panels) {
    # Rollierende Renditen ueber bis zu 30 Tage (einzahlungsbereinigt), kalendergenau
    # annualisiert: Exponent 365.25 / Kalendertage des Fensters
    window <- max(2, min(30, floor(n_days / 10)))
    if (n_days > window) {
      growth <- cumprod(1 + c(0, .dash$all_returns))
      rolling_returns <- sapply(window:n_days, function(i) {
        days <- as.numeric(dates[i]) - as.numeric(dates[i - window + 1])
        ((growth[i] / growth[i - window + 1])^(365.25 / days) - 1) * 100
      })
      
      rolling_dates <- dates[window:n_days]
      
      plot(rolling_dates, rolling_returns,
           type = "n",
           xlab = "",
           ylab = "Rendite p. a. (%)",
           main = sprintf("Rollierende %d-Tage-Renditen (annualisiert)", window),
           col.main = colors$primary,
           cex.main = 1.3,
           font.main = 2,
           las = 1)
      
      # Gitter zeichnen
      grid(col = colors$grid, lty = 1, lwd = 0.5)
      
      # Nulllinie zeichnen
      abline(h = 0, col = colors$neutral, lty = 2)
      
      # Positive/negative Werte farblich unterscheiden
      positive_idx <- rolling_returns >= 0
      
      # Positive Renditen zeichnen
      if (any(positive_idx)) {
        lines(rolling_dates[positive_idx], rolling_returns[positive_idx],
              col = colors$positive, lwd = 1.5)
      }
      
      # Negative Renditen zeichnen
      if (any(!positive_idx)) {
        lines(rolling_dates[!positive_idx], rolling_returns[!positive_idx],
              col = colors$negative, lwd = 1.5)
      }
      
      # CAGR-Linie zeichnen (mit Sparplan TTWROR, passend zu den zeitgewichteten Renditen)
      cagr_pct <- (if (ext) x$ttwror else x$cagr) * 100
      abline(h = cagr_pct, col = colors$primary, lty = 2, lwd = 1.5)
      label_bg(dates[1], cagr_pct, sprintf(if (ext) "TTWROR: %.1f%%" else "CAGR: %.1f%%", cagr_pct),
               adj = c(0, -0.5), col = colors$primary, cex = 0.9)
    } else {
      empty_panel("Rollierende Renditen (annualisiert)")
    }
  }
  
  # ===========================================================================
  # PANEL 5: HEATMAP DER MONATSRENDITEN
  # ===========================================================================
  if ("monthly" %in% selected_panels && !is.null(dates)) {
    # Monatsrenditen berechnen
    dates_date <- as.Date(dates)
    year_month <- format(dates_date, "%Y-%m")
    
    # R1-19: Monatsende zu Monatsende (erster Monat ab Starttag), einzahlungsbereinigt:
    # verkettete Tagesrenditen des Monats
    month_ret <- c(0, .dash$all_returns)
    monthly_data <- tapply(month_ret, year_month, function(r) (prod(1 + r) - 1) * 100)
    
    # Jahr und Monat zerlegen
    ym_split <- strsplit(names(monthly_data), "-")
    years <- sapply(ym_split, `[`, 1)
    months <- as.integer(sapply(ym_split, `[`, 2))
    
    # Matrix anlegen
    unique_years <- unique(years)
    monthly_matrix <- matrix(NA, nrow = length(unique_years), ncol = 12)
    rownames(monthly_matrix) <- unique_years
    colnames(monthly_matrix) <- month.abb
    
    for (i in seq_along(monthly_data)) {
      year_idx <- which(unique_years == years[i])
      month_idx <- months[i]
      monthly_matrix[year_idx, month_idx] <- monthly_data[i]
    }
    
    # Heatmap zeichnen
    w_year <- max(strwidth(rownames(monthly_matrix), units = "inches", cex = par("cex.axis"))) / par("csi")
    par(mar = c(5, max(4, w_year + 2.6), 3, 3))
    
    # Farbpalette festlegen
    breaks <- seq(-10, 10, length.out = 21)
    cols <- colorRampPalette(c(colors$negative, "white", colors$positive))(20)
    
    image(1:12, 1:nrow(monthly_matrix), t(pmin(pmax(monthly_matrix, -10), 10)),
          col = cols,
          breaks = breaks,
          xlab = "Monat",
          ylab = "",
          main = "Monatsrenditen (%)",
          col.main = colors$primary,
          cex.main = 1.3,
          font.main = 2,
          axes = FALSE)
    
    axis(1, at = 1:12, labels = .monate_kurz, las = 2)
    axis(2, at = 1:nrow(monthly_matrix), labels = rownames(monthly_matrix), las = 1)
    title(ylab = "Jahr", line = w_year + 1.4)
    
    # Werte als Text eintragen
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
  # PANEL 6: TABELLE DER KENNZAHLEN
  # ===========================================================================
  if ("stats" %in% selected_panels) {
    plot.new()
    plot.window(xlim = c(0, 1), ylim = c(0, 1))
    
    title("Kennzahlen", 
          col.main = colors$primary,
          cex.main = 1.3,
          font.main = 2)
    
    # Kennzahlen aufbereiten
    stats <- list(
      "Rendite" = c(
        sprintf(if (ext) "CAGR (geldgew.): %+.2f%%" else "CAGR: %+.2f%%", x$cagr * 100),
        sprintf("TTWROR: %+.2f%%", x$ttwror * 100),
        sprintf(if (ext) "Gesamtrendite (TWR): %+.2f%%" else "Gesamtrendite: %+.2f%%", tot_ret(x) * 100)
      ),
      "Risiko" = c(
        sprintf(if (ext) "Max. Drawdown (TWR): %.2f%%" else "Max. Drawdown: %.2f%%", max(x$drawdowns) * 100),
        sprintf("Volatilit\u00e4t je Tag: %.2f%%", x$statistics$sd * 100),
        sprintf("Volatilit\u00e4t p. a.: %.2f%%", ann_vol(x) * 100)
      ),
      "Renditeprofil" = c(
        sprintf("Sharpe Ratio: %.2f", x$statistics$sharpe),
        sprintf("Schiefe: %.2f", x$statistics$skewness),
        sprintf("W\u00f6lbung: %.2f", x$statistics$kurtosis)
      ),
      "Depot" = c(
        # Startkapital brutto (vor Kaufkosten) = invested[1] ohne die Einzahlung des Starttags (Sparrate am
        # ersten Tag, Summe report$<asset>$flows[1]), also start_value; aeltere Ergebnisse ohne invested:
        # Depotwert am Starttag (volle Betraege wie in print())
        if (length(x$invested) == n_days) sprintf("Startkapital: %.2f EUR", x$invested[1] -
          sum(vapply(x$report, function(a) if (length(a$flows) == n_days) as.numeric(a$flows[1]) else 0, 0)))
        else sprintf("Depotwert Starttag: %.2f EUR", head(x$worth, 1)),
        sprintf("Endwert: %.2f EUR", tail(x$worth, 1)),
        if (ext) sprintf("Eingezahlt: %.2f EUR", tail(.dash$invested, 1)),
        sprintf("Dauer: %d Tage", n_days)
      )
    )
    
    if (!is.null(compare)) {
      stats[["Vergleich"]] <- c(
        sprintf("Diff. CAGR: %+.2f%%", (x$cagr - compare$cagr) * 100),
        sprintf("Diff. Gesamtrendite: %+.2f%%", (tot_ret(x) - tot_ret(compare)) * 100),
        sprintf("Diff. Volatilit\u00e4t: %+.2f%%", (ann_vol(x) - ann_vol(compare)) * 100)
      )
    }
    
    # Abschnitte untereinander, bei wenig Platz in zwei Spalten; die Schrift wird nur so weit
    # verkleinert, dass sich nichts ueberlappt und alles im Rahmen bleibt (Masse aus strheight/strwidth)
    lh <- strheight("Mg", cex = 1) * 1.45                         # Zeilenhoehe bei cex 1 (Nutzerkoordinaten)
    sec_h <- vapply(stats, function(v) 1 + 0.85 * length(v), 0)   # Abschnittshoehe in Zeilen
    sec_w <- vapply(seq_along(stats), function(i) max(strwidth(names(stats)[i], cex = 1, font = 2),
                                                      0.03 + strwidth(stats[[i]], cex = 0.85)), 0)
    col_fit <- function(grp, nc) {
      h <- vapply(seq_len(nc), function(k) { i <- which(grp == k); (sum(sec_h[i]) + 0.5 * (length(i) - 1)) * lh }, 0)
      w <- vapply(seq_len(nc), function(k) max(sec_w[grp == k]), 0)
      min(1, 0.88 / max(h), (0.92 / nc - 0.03) / max(w))
    }
    n_sec <- length(stats)
    best <- list(grp = rep(1L, n_sec), nc = 1L, sc = col_fit(rep(1L, n_sec), 1L))
    if (best$sc < 1 && n_sec > 1) for (k in seq_len(n_sec - 1)) {
      g <- rep(1:2, c(k, n_sec - k)); sc <- col_fit(g, 2L)
      if (sc > best$sc) best <- list(grp = g, nc = 2L, sc = sc)
    }
    sc <- best$sc
    for (k in seq_len(best$nc)) {
      x0 <- 0.05 + (k - 1) * 0.46; y <- 0.95
      for (i in which(best$grp == k)) {
        # Abschnittsueberschrift
        text(x0, y - 0.5 * lh * sc, names(stats)[i], font = 2, cex = sc, col = colors$primary, adj = c(0, 0.5))
        y <- y - lh * sc
        # Kennzahlen des Abschnitts
        for (v in stats[[i]]) {
          text(x0 + 0.03, y - 0.425 * lh * sc, v, font = 1, cex = 0.85 * sc, col = colors$neutral, adj = c(0, 0.5))
          y <- y - 0.85 * lh * sc
        }
        y <- y - 0.5 * lh * sc
      }
    }
    
    # Rahmen zeichnen
    rect(0.02, 0.02, 0.98, 0.98, border = colors$grid, lwd = 2)
  }
  
  # ===========================================================================
  # PANEL 7: ROLLIERENDE KORRELATION STRATEGIE / VERGLEICH (nur mit compare)
  # ===========================================================================
  if ("correlation" %in% selected_panels && !is.null(compare)) {
    # Bereinigte Tagesrenditen beider Ergebnisse (wie .dashboard_returns), aufgefuellte Tage (LOCF) in
    # einem der beiden ausgeschlossen; Fenster 252 Beobachtungen, bei kurzer Historie ein Viertel davon
    rc_x <- .dash$all_returns; rc_c <- .dashboard_returns(compare)$all_returns
    fill_of <- function(r) if (length(r$filled) == n_days) as.logical(r$filled)[-1] else logical(max(0, n_days - 1))
    ok <- !(fill_of(x) | fill_of(compare))
    rx <- rc_x[ok]; ry <- rc_c[ok]; m <- length(rx)
    k <- min(252L, as.integer(floor(m / 4)))
    if (m >= 40 && k >= 10) {
      csum <- function(v) c(0, cumsum(v)); win <- function(cs) cs[(k + 1):(m + 1)] - cs[1:(m - k + 1)]
      sx <- win(csum(rx)); sy <- win(csum(ry)); sxx <- win(csum(rx^2)); syy <- win(csum(ry^2)); sxy <- win(csum(rx * ry))
      vx <- k * sxx - sx^2; vy <- k * syy - sy^2
      rho <- ifelse(vx > 0 & vy > 0, (k * sxy - sx * sy) / sqrt(pmax(vx, 0) * pmax(vy, 0)), NA_real_)
      rho <- pmin(pmax(rho, -1), 1)
      rho_dates <- dates[-1][ok][k:m]
      rho_all <- if (stats::sd(rx) > 0 && stats::sd(ry) > 0) stats::cor(rx, ry) else NA_real_
      plot(rho_dates, rho, type = "n", xlim = range(dates), ylim = c(-1, 1), xlab = "", ylab = "Korrelation",
           main = sprintf("Rollierende Korrelation (%d Tage)", k),
           col.main = colors$primary, cex.main = 1.3, font.main = 2, las = 1)
      grid(col = colors$grid, lty = 1, lwd = 0.5)
      abline(h = 0, col = colors$neutral, lty = 2)
      lines(rho_dates, rho, col = colors$primary, lwd = 1.5)
      if (is.finite(rho_all)) {
        abline(h = rho_all, col = colors$secondary, lty = 2, lwd = 1.5)
        label_bg(dates[1], rho_all, sprintf("Gesamt: %.2f", rho_all), adj = c(0, if (rho_all > 0.8) 1.5 else -0.5),
                 col = colors$secondary, cex = 0.9)
      }
    } else {
      empty_panel("Rollierende Korrelation")
    }
  }
  
  # ===========================================================================
  # PANEL 8: VERGLEICHSKENNZAHLEN (wenn compare angegeben)
  # ===========================================================================
  if ("comparison" %in% selected_panels && !is.null(compare)) {
    plot.new()
    plot.window(xlim = c(0, 1), ylim = c(0, 1))
    
    title("Strategievergleich",
          col.main = colors$primary,
          cex.main = 1.3,
          font.main = 2)
    
    # Vergleichstabelle
    # Mit Sparplan (in einem der Ergebnisse) ist CAGR geldgewichtet und Max DD zeitgewichtet
    ext_any <- ext || .dashboard_returns(compare)$external_flows
    metrics <- c(if (ext_any) "CAGR (MWR)" else "CAGR", if (ext_any) "Max. DD (TWR)" else "Max. DD", "Volatilit\u00e4t", "Sharpe")
    lower_better <- c(FALSE, TRUE, TRUE, FALSE)        # Max. DD und Volatilitaet: kleiner ist besser
    strat1_vals <- c(
      x$cagr * 100,
      max(x$drawdowns) * 100,
      ann_vol(x) * 100,
      x$statistics$sharpe
    )
    strat2_vals <- c(
      compare$cagr * 100,
      max(compare$drawdowns) * 100,
      ann_vol(compare) * 100,
      compare$statistics$sharpe
    )
    
    # Zeilen und Kopfzeile innerhalb des Rahmens; Schrift bei wenig Platz verkleinert
    # (Zeilenhoehe und Spaltenbreite aus strheight/strwidth), damit sich nichts ueberlappt
    y_positions <- seq(0.70, 0.16, length.out = length(metrics))
    v1 <- sprintf("%.2f", strat1_vals); v2 <- sprintf("%.2f", strat2_vals)
    lh <- strheight("Mg", cex = 1, font = 2) * 1.3
    w_left <- max(strwidth(metrics, cex = 1, font = 2)) + max(strwidth(c(v1, "Strategie 1"), cex = 1, font = 2))
    sc <- min(1, 0.16 / lh, 0.27 / w_left, 0.27 / max(strwidth(c(v2, "Strategie 2"), cex = 1, font = 2)))
    
    for (i in seq_along(metrics)) {
      # Name der Kennzahl
      text(0.05, y_positions[i], metrics[i],
           font = 2, cex = sc, adj = 0)
      
      # Wert Strategie 1
      text(0.35, y_positions[i], v1[i],
           col = colors$primary, cex = 0.9 * sc, adj = 1)
      
      # Wert Strategie 2
      text(0.65, y_positions[i], v2[i],
           col = colors$secondary, cex = 0.9 * sc, adj = 1)
      
      # Differenz
      diff <- strat1_vals[i] - strat2_vals[i]
      # Gruen = Strategie 1 besser (bei "kleiner ist besser" also negative Differenz), 0/NA neutral
      better <- if (lower_better[i]) diff < 0 else diff > 0
      diff_col <- if (!is.finite(diff) || round(diff, 2) == 0) colors$neutral else if (better) colors$positive else colors$negative
      text(0.95, y_positions[i], sprintf("%+.2f", diff),
           col = diff_col, font = 2, cex = 0.9 * sc, adj = 1)
    }
    
    # Spaltenueberschriften
    text(0.35, 0.88, "Strategie 1", col = colors$primary, font = 2, cex = sc, adj = 1)
    text(0.65, 0.88, "Strategie 2", col = colors$secondary, font = 2, cex = sc, adj = 1)
    text(0.95, 0.88, "Differenz", col = colors$neutral, font = 2, cex = sc, adj = 1)
    
    # Rahmen
    rect(0.02, 0.02, 0.98, 0.98, border = colors$grid, lwd = 2)
  }
  
  invisible(NULL)
}


# Tagesrenditen fuer das Dashboard wie in simulation(): einzahlungsbereinigt
# (TTWROR-Tagesrenditen), aufgefuellte Tage (x$filled) ausgeschlossen, und
# Beobachtungen je Jahr fuer die Annualisierung; dazu Sparplan-Kennung,
# Einzahlungssumme und zeitgewichteter Index (aeltere Ergebnisse: aus report$flows)
.dashboard_returns <- function(x) {
  w <- as.numeric(x$worth); n <- length(w)
  flows <- if (length(x$report)) Reduce(`+`, lapply(x$report, function(a) as.numeric(a$flows))) else numeric(n)
  if (length(flows) != n) flows <- numeric(n)
  # Tagesrenditen wie in simulation() aus twr_index; aeltere Ergebnisse: Zahlung zum Tagesende
  all_r <- if (n < 2) numeric(0) else if (length(x$twr_index) == n) x$twr_index[-1] / x$twr_index[-n] - 1
           else (w[-1] - w[-n] - flows[-1]) / w[-n]
  all_r[!is.finite(all_r)] <- 0
  filled <- if (length(x$filled) == n) as.logical(x$filled) else logical(n)
  r <- all_r[!filled[-1]]
  years <- if (!is.null(x$dates) && n >= 2) as.numeric(x$dates[n] - x$dates[1]) / 365.25 else 0
  ext <- if (!is.null(x$external_flows)) isTRUE(x$external_flows) else n >= 2 && any(flows[-1] != 0, na.rm = TRUE)
  invested <- if (length(x$invested) == n) x$invested else if (n) w[1] + cumsum(c(0, flows[-1])) else numeric(0)
  twr <- if (length(x$twr_index) == n) x$twr_index else if (n) cumprod(c(1, 1 + all_r)) else numeric(0)
  list(all_returns = all_r, returns = r, ppy = if (years > 0 && length(r)) length(r) / years else 365.25,
       external_flows = ext, invested = invested, twr_index = twr)
}


#' Dashboard als PDF exportieren
#'
#' @param x Ein SimLevResult-Objekt
#' @param filename Zeichenkette: Pfad der PDF-Ausgabedatei
#' @param width Zahl: Breite in Zoll
#' @param height Zahl: Hoehe in Zoll
#' @param ... Weitere Argumente fuer plot.SimLevResult
#'
#' @export
#'
#' @examples
#' result <- simulation(data, strategy)
#' export_dashboard(result, "portfolio_dashboard.pdf")
#' @noRd
export_dashboard <- function(x, filename = "dashboard.pdf", 
                             width = 14, height = 10, ...) {
  pdf(filename, width = width, height = height)
  dev_pdf <- dev.cur()
  on.exit(dev.off(dev_pdf))   # R1-22: PDF-Geraet auch bei Fehler schliessen
  plot(x, ...)
  message(sprintf("export_dashboard: Dashboard gespeichert in %s", filename))
}


#' Interaktives HTML-Dashboard erstellen (benoetigt plotly; noch nicht umgesetzt)
#'
#' Derzeit nur ein Platzhalter: Ohne plotly bricht die Funktion mit Fehler ab,
#' mit plotly gibt sie nur eine Meldung aus und schreibt keine Datei. Fuer ein
#' interaktives Dashboard siehe \code{plot_interactive()}.
#'
#' @param x Ein SimLevResult-Objekt
#' @param filename Zeichenkette: Pfad der HTML-Ausgabedatei (derzeit ungenutzt)
#'
#' @export
#'
#' @examples
#' \dontrun{
#' result <- simulation(data, strategy)
#' export_html_dashboard(result, "portfolio_dashboard.html")
#' }
#' @noRd
export_html_dashboard <- function(x, filename = "dashboard.html") {
  if (!requireNamespace("plotly", quietly = TRUE)) {
    stop("export_html_dashboard: Das Paket 'plotly' wird f\u00fcr HTML-Dashboards ben\u00f6tigt; installieren mit install.packages(\"plotly\").")
  }
  
  # Hier wuerde ein interaktives plotly-Dashboard entstehen
  # (noch nicht umgesetzt; geplant mit plotly fuer interaktive Grafiken)
  message("export_html_dashboard: Der Export als interaktives HTML-Dashboard ist noch nicht umgesetzt; es wird keine Datei geschrieben (siehe plot_interactive()).")
}
