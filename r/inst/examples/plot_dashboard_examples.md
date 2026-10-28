# Dashboard Plot - Verwendungsbeispiele

## Überblick

Die neue `plot()` Funktion erstellt umfassende Dashboard-Style Visualisierungen mit mehreren Panels:

### Verfügbare Panels:

1. **Performance** - Portfolio-Wert über Zeit mit Shading
2. **Drawdown** - Drawdown-Analyse mit Maximum
3. **Distribution** - Verteilung der täglichen Returns mit Normalverteilung
4. **Rolling** - Rollierendes 30-Tage Returns (annualisiert)
5. **Monthly** - Heatmap der monatlichen Returns
6. **Stats** - Übersicht aller wichtigen Kennzahlen
7. **Correlation** - Korrelationsmatrix der Assets (wenn verfügbar)
8. **Comparison** - Vergleich zweier Strategien

## Verwendung

### 1. Vollständiges Dashboard (Standard)

```r
result <- simulation(
  data = data,
  strategy = strategy,
  start_value = 10000
)

# Zeigt alle verfügbaren Panels
plot(result)
```

**Ausgabe:** 6-Panel Dashboard mit:
- Wertentwicklung des Depots
- Drawdown-Analyse
- Verteilung der Tagesrenditen
- Rollierende Renditen (annualisiert)
- Monatsrenditen (Heatmap)
- Kennzahlen

---

### 2. Kompaktes Dashboard

```r
# Nur die wichtigsten 4 Panels
plot(result, style = "compact")
```

**Ausgabe:** 4-Panel Dashboard (2x2 Grid):
- Performance
- Drawdown
- Distribution
- Stats

---

### 3. Benutzerdefinierte Panels

```r
# Wähle spezifische Panels
plot(result, 
     style = "custom",
     panels = c("performance", "drawdown", "monthly"))
```

Verfügbare Panel-Namen:
- `"performance"` - Portfolio-Wert
- `"drawdown"` - Drawdown-Chart
- `"distribution"` - Returns-Verteilung
- `"rolling"` - Rolling Returns
- `"monthly"` - Monatliche Heatmap
- `"stats"` - Statistik-Tabelle
- `"correlation"` - Asset-Korrelation
- `"comparison"` - Strategie-Vergleich

---

### 4. Strategien vergleichen

```r
# Zwei Strategien simulieren
result1 <- simulation(data, strategy1, start_value = 10000)
result2 <- simulation(data, strategy2, start_value = 10000)

# Vergleichen
plot(result1, compare = result2)
```

**Ausgabe:** 8-Panel Dashboard mit zusätzlichen Vergleichspanels:
- Alle Standard-Panels
- Performance-Overlay (beide Strategien in einem Chart)
- Comparison-Panel (Side-by-Side Metriken)

---

### 5. Benutzerdefinierte Farben

```r
# Eigenes Farbschema
custom_colors <- list(
  primary = "#FF6B6B",      # Rot
  secondary = "#4ECDC4",    # Türkis
  positive = "#95E1D3",     # Hellgrün
  negative = "#F38181",     # Rosa
  neutral = "#6C5B7B",      # Lila
  background = "#FFFFFF",   # Weiß
  grid = "#E8E8E8"          # Hellgrau
)

plot(result, colors = custom_colors)
```

---

## Export-Funktionen

### Als PDF speichern

```r
# Export als PDF (14x10 Inch)
export_dashboard(result, "portfolio_analysis.pdf")

# Benutzerdefinierte Größe
export_dashboard(result, "analysis.pdf", width = 16, height = 12)

# Mit Optionen
export_dashboard(result, "compact.pdf", style = "compact")
```

---

## Beispiele für verschiedene Szenarien

### Beispiel 1: Einfacher Backtest

```r
# Simulation
result <- simulation(
  data = historical_data,
  strategy = strategy,
  start_value = 50000
)

# Standard-Dashboard
plot(result)

# Export
export_dashboard(result, "backtest_results.pdf")
```

---

### Beispiel 2: Strategie-Vergleich

```r
# Buy-and-Hold
bnh_strategy <- create_strategy(
  SPY = asset_config(
    asset_class = "etf",
    action_type = "bnh",
    asset_share = 1.0,
    asset_spread = 0.1,
    asset_bonus = 30
  )
)

# DCA Strategy
dca_strategy <- bnh_strategy  # Gleiche Assets

result_bnh <- simulation(
  data = data,
  strategy = bnh_strategy,
  start_value = 10000
)

result_dca <- simulation(
  data = data,
  strategy = dca_strategy,
  start_value = 1000,
  dca_mode = TRUE,
  dca_value = 500,
  dca_span = 1,
  dca_unit = "month"
)

# Vergleich visualisieren
plot(result_bnh, compare = result_dca)
```

Mit Sparplan ist die CAGR geldgewichtet (XIRR), Drawdowns werden
zeitgewichtet gemessen. Das Vergleichspanel beschriftet die Kennzahlen dann
als „CAGR (MWR)“ und „Max. DD (TWR)“. Für einen fairen Vergleich der
Strategien eignet sich die TTWROR.

---

### Beispiel 3: Monatliche Analyse

```r
# Fokus auf monatliche Performance
plot(result,
     style = "custom",
     panels = c("performance", "monthly", "stats"))
```

---

### Beispiel 4: Risiko-Analyse

```r
# Fokus auf Risiko-Metriken
plot(result,
     style = "custom",
     panels = c("drawdown", "distribution", "rolling", "stats"))
```

---

## Dashboard-Komponenten im Detail

### 1. Performance Chart

**Features:**
- Shaded area unter der Kurve
- Finale Portfolio-Wert Annotation
- Vergleichslinie bei Compare-Modus
- Mit Sparplan: Summe der Einzahlungen (Startwert + Sparraten) als
  gepunktete Treppenlinie („Einzahlungen“)
- Currency-formatierte Y-Achse
- Grid für bessere Lesbarkeit

**Interpretation:**
- Stetige Aufwärtsbewegung = Gutes Wachstum
- Volatile Bewegungen = Höheres Risiko
- Plateaus = Seitwärtsphasen

---

### 2. Drawdown Chart

**Features:**
- Shaded negative area
- Maximum Drawdown Linie
- Prozentuale Y-Achse
- Farbkodierung (rot = negativ)
- Mit Sparplan auf dem zeitgewichteten Wertindex gemessen (Titel
  „Drawdown-Analyse (zeitgewichtet)“), Einzahlungen täuschen also keine
  Erholung vor

**Interpretation:**
- Tiefe Täler = Große Verlustphasen
- Häufige Täler = Hohe Volatilität
- Schnelle Erholung = Gute Resilienz
- Max DD = Worst-Case Szenario

**Benchmark:** 
- < 10% = Sehr gut
- 10-20% = Gut
- 20-30% = Akzeptabel
- > 30% = Riskant

---

### 3. Distribution Chart

**Features:**
- Histogramm der täglichen Returns
- Normal-Verteilungs-Overlay (gestrichelt)
- Mittelwert-Linie (grün)
- Statistiken in der Legende

**Interpretation:**
- Symmetrisch um Null = Ausgewogen
- Rechtsschief = Positive Bias
- Linksschief = Negative Bias
- Fat Tails = Extremereignisse
- Hohe Kurtosis = Häufige Extremwerte

---

### 4. Rolling Returns

**Features:**
- 30-Tage annualisierte Returns (bei kurzen Reihen ein Zehntel der Tage)
- Farbkodierung (grün = positiv, rot = negativ)
- CAGR-Referenzlinie (mit Sparplan TTWROR, passend zu den zeitgewichteten
  Renditen)
- Null-Linie

**Interpretation:**
- Über CAGR-Linie = Outperformance
- Unter Null = Verlustphasen
- Hohe Volatilität = Inconsistent
- Stabile Linie = Konsistente Returns

---

### 5. Monthly Heatmap

**Features:**
- Jahr × Monat Matrix
- Farbkodierung (rot = negativ, grün = positiv)
- Prozent-Werte in Zellen
- Schnelle Mustererkennung

**Interpretation:**
- Rote Cluster = Problematische Perioden
- Grüne Cluster = Starke Perioden
- Saisonale Muster erkennbar
- Jahres-Performance auf einen Blick

**Typische Muster:**
- "Januar-Effekt" sichtbar
- Sommer-Schwäche erkennbar
- End-of-Year Rally sichtbar

---

### 6. Statistics Panel

**Kategorien:**

**Rendite:**
- CAGR: Compound Annual Growth Rate (mit Sparplan „CAGR (geldgew.)“, XIRR)
- TTWROR: True Time-Weighted Rate of Return
- Gesamtrendite (mit Sparplan „Gesamtrendite (TWR)“, zeitgewichtet)

**Risiko:**
- Max. Drawdown: Größter Verlust von Peak (mit Sparplan „Max. Drawdown (TWR)“)
- Volatilität je Tag: Tägliche Schwankung
- Volatilität p. a.: Annualisierte Volatilität

**Renditeprofil:**
- Sharpe Ratio: Risk-adjusted Return, identisch mit
  `result$statistics$sharpe`
- Schiefe: Schiefe der Verteilung
- Wölbung (Kurtosis): "Dicke" der Verteilungsenden

**Depot:**
- Startwert/Endwert: Anfangs-/Endwert
- Eingezahlt: Summe der Einzahlungen (nur mit Sparplan)
- Dauer: Simulationsdauer in Tagen

---

## Praktische Workflows

### Workflow 1: Schnelle Analyse

```r
# 1. Simulation
result <- simulation(data, strategy, start_value = 10000)

# 2. Kompakte Übersicht
plot(result, style = "compact")

# 3. Bei Interesse: Vollständiges Dashboard
plot(result, style = "full")
```

---

### Workflow 2: Präsentation vorbereiten

```r
# 1. Simulation
result <- simulation(data, strategy, start_value = 100000)

# 2. Custom Farben (Corporate Design)
brand_colors <- list(
  primary = "#003366",
  secondary = "#FFB81C",
  positive = "#00A651",
  negative = "#ED1C24",
  neutral = "#666666",
  background = "#FFFFFF",
  grid = "#CCCCCC"
)

# 3. Export für Präsentation
export_dashboard(
  result, 
  "investor_presentation.pdf",
  width = 16,
  height = 10,
  colors = brand_colors
)
```

---

### Workflow 3: A/B Testing

```r
# Verschiedene Strategien testen
strategies <- list(
  conservative = conservative_strategy,
  balanced = balanced_strategy,
  aggressive = aggressive_strategy
)

results <- lapply(strategies, function(s) {
  simulation(data, s, start_value = 10000)
})

# Pairwise Vergleiche
plot(results$conservative, compare = results$aggressive)
plot(results$balanced, compare = results$aggressive)

# Exportieren
for (name in names(results)) {
  export_dashboard(
    results[[name]], 
    sprintf("%s_strategy.pdf", name)
  )
}
```

---

### Workflow 4: Sensitivitäts-Analyse

```r
# Parameter variieren
start_values <- c(10000, 50000, 100000)
results <- lapply(start_values, function(sv) {
  simulation(data, strategy, start_value = sv)
})

# Vergleichen
par(mfrow = c(1, 3))
for (i in seq_along(results)) {
  plot(results[[i]], style = "compact")
  title(sprintf("Start: $%s", format(start_values[i], big.mark = ",")), 
        outer = TRUE, line = -2)
}
```

---

## Tipps & Best Practices

### 1. Dashboard-Größe
- **Bildschirm:** Standard (plot direkt)
- **PDF:** 14x10 oder 16x12 inches
- **Präsentation:** 16x9 (widescreen)
- **Druck:** A4 landscape (11.7x8.3 inches)

### 2. Panel-Auswahl
- **Investor-Präsentation:** performance, stats, drawdown
- **Risiko-Report:** drawdown, distribution, rolling
- **Trading-Review:** performance, monthly, stats
- **Research:** Alle panels (full)

### 3. Farben
- **Heller Hintergrund** (Standard `background = "#FFFFFF"`): für Druck
  und PDF; dunkle Flächen verbrauchen Tinte und geben im Druck schlecht
  wieder
- **Dunkler Hintergrund:** allenfalls für Bildschirm und Projektion; dann
  `background`, `grid` und die Linienfarben über `colors` aufeinander
  abstimmen
- **Brand Colors:** Bei offiziellen Dokumenten
- **Default:** Für schnelle Analyse

### 4. Export-Formate
- **PDF:** `export_dashboard(result, "datei.pdf")` (schreibt immer PDF,
  auch bei anderer Dateiendung); beste Qualität, für Archivierung
- **PNG/SVG:** keine eigene Exportfunktion; mit einem Grafikgerät von R
  selbst schreiben, z. B.
  `png("dashboard.png", width = 1600, height = 1000, res = 110); plot(result); dev.off()`
  bzw. `svg("dashboard.svg", width = 14, height = 10); plot(result); dev.off()`

---

## Troubleshooting

### Problem: Leere Panels

```r
# Prüfen ob Daten vorhanden
length(result$worth)
!is.null(result$dates)
!is.null(result$report)
```

### Problem: Unleserliche Achsenbeschriftungen

```r
# Größere Fonts
par(cex.axis = 1.2, cex.lab = 1.2)
plot(result)
```

### Problem: Zu kleine Darstellung

```r
# Größeres Ausgabefenster
options(repr.plot.width = 16, repr.plot.height = 12)
plot(result)

# Oder PDF mit größeren Dimensionen
export_dashboard(result, "large.pdf", width = 20, height = 14)
```

---

## Zukünftige Erweiterungen

Mögliche Ergänzungen:
- Shiny app integration
- Custom metric definitions
- Benchmark comparison
- Multiple strategy overlay
- Risk-adjusted metrics panel
- Transaction log visualization
- Tax impact visualization
