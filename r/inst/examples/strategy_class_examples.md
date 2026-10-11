# Strategy-Klasse: Verwendungsbeispiele

## Grundlegende Verwendung

### 1. Einfache Strategy erstellen

```r
library(SimLev)

# Methode 1: Direkt mit create_strategy()
strategy <- create_strategy(
  SPY = asset_config(
    asset_class = "etf",
    action_type = "bnh",
    asset_share = 1.0,
    asset_spread = 0.1,
    asset_bonus = 30
  )
)

print(strategy)
```

### 2. Multi-Asset Strategy

```r
strategy <- create_strategy(
  SPY = asset_config(
    asset_class = "etf",
    action_type = "bnh",
    asset_share = 0.60,
    asset_spread = 0.10,
    asset_bonus = 30
  ),
  BND = asset_config(
    asset_class = "etf",
    action_type = "bnh",
    asset_share = 0.40,
    asset_spread = 0.05,
    asset_bonus = 0
  )
)

print(strategy)
summary(strategy)
```

### 3. Signal-basierte Strategy (SMA)

```r
# Erst Signals in Daten erstellen
data$sma_short <- TTR::SMA(data$SPY, n = 50)
data$sma_long <- TTR::SMA(data$SPY, n = 200)
data$spy_buy <- data$sma_short > data$sma_long
data$spy_sell <- data$sma_short < data$sma_long

# Dann Strategy mit Signals
strategy <- create_strategy(
  SPY = asset_config(
    asset_class = "etf",
    action_type = "signal",       # Signal-based!
    asset_share = 1.0,
    asset_spread = 0.10,
    asset_bonus = 30,
    signal_buy = "spy_buy",       # Spaltenname in data
    signal_sell = "spy_sell"      # Spaltenname in data
  )
)
```

## Vorteile

### ✅ Sofortige Validierung

```r
# FEHLER wird SOFORT erkannt:
strategy <- create_strategy(
  SPY = asset_config(
    asset_class = "etf",
    action_type = "FALSCH",  # ❌ Error: must be 'bnh' or 'signal'
    asset_share = 0.6
  )
)

# Fehlende Pflichtfelder werden erkannt:
strategy <- create_strategy(
  SPY = asset_config(
    asset_class = "etf"
    # ❌ Error: action_type is required
    # ❌ Error: asset_share is required
    # etc.
  )
)

# Ungültige Werte werden erkannt:
strategy <- create_strategy(
  SPY = asset_config(
    asset_class = "etf",
    action_type = "bnh",
    asset_share = -0.5,      # ❌ Error: must be positive
    asset_spread = 0.1,
    asset_bonus = 150        # ❌ Error: must be between 0 and 100
  )
)
```

### ✅ Intelligente Warnungen

```r
# Warnung bei unnötigen Parametern:
strategy <- create_strategy(
  SPY = asset_config(
    asset_class = "etf",
    action_type = "bnh",
    asset_share = 1.0,
    asset_spread = 0.1,
    asset_bonus = 30,
    signal_buy = "buy",      # ⚠️  Warning: ignored for 'bnh'
    signal_sell = "sell"     # ⚠️  Warning: ignored for 'bnh'
  )
)
# Warning: signal_buy and signal_sell are ignored for action_type = 'bnh'
# (Parameter werden automatisch auf NULL gesetzt)
```

### ✅ Validierung gegen Daten

```r
# Prüfe ob Strategy zu Daten passt
validate_strategy(strategy, data = data)

# Fehler wenn Asset fehlt:
# Error: Assets not found in data: AAPL

# Fehler wenn Signal-Spalten fehlen:
# Error: Signal column 'spy_buy' not found in data (required by asset 'SPY')
```

## Hilfsfunktionen

### Asset hinzufügen

```r
strategy <- add_asset(
  strategy,
  name = "QQQ",
  asset = asset_config(
    asset_class = "etf",
    action_type = "bnh",
    asset_share = 0.20,
    asset_spread = 0.10,
    asset_bonus = 30
  )
)
```

### Asset aktualisieren

```r
# Einzelne Parameter ändern
strategy <- update_asset(
  strategy,
  name = "SPY",
  asset_share = 0.70,
  asset_spread = 0.15
)
```

### Asset entfernen

```r
strategy <- remove_asset(strategy, "BND")
```

## Ausgabe

### print()

```r
print(strategy)
```

Ausgabe:
```
═══════════════════════════════════════════════════════════
                    SimLev Strategy                         
═══════════════════════════════════════════════════════════

  Number of Assets: 2
  Asset Names: SPY, BND

  SPY
  ──────────────────────────────────────────────────────
    Class:           etf
    Action:          bnh
    Target Weight:   60.0% (normalized: 60.0%)
    Spread:          0.10%
    Tax Exemption:   30%

  BND
  ──────────────────────────────────────────────────────
    Class:           etf
    Action:          bnh
    Target Weight:   40.0% (normalized: 40.0%)
    Spread:          0.05%
    Tax Exemption:   0%

═══════════════════════════════════════════════════════════
```

### summary()

```r
summary(strategy)
```

Ausgabe:
```
Strategy Summary
════════════════

Total Assets:        2
  - Buy-and-Hold:    2
  - Signal-based:    0

Total Weight:        1.00 (will be normalized to 1.0)
Average Spread:      0.08%
Average Tax Exempt:  15.0%
```

## Backward Compatibility

Falls die alte `simulation()` Funktion noch Listen erwartet:

```r
# Konvertiere zu alter Liste
old_format <- as_list(strategy)

# Dann verwenden
result <- simulation(data = data, strategy = old_format)
```

## Vollständiges Beispiel

```r
library(SimLev)

# 1. Daten vorbereiten
data <- data.frame(
  date = seq.Date(as.Date("2020-01-01"), as.Date("2023-12-31"), by = "day"),
  SPY = 300 * cumprod(1 + rnorm(1461, 0.0004, 0.012)),
  BND = 80 * cumprod(1 + rnorm(1461, 0.0001, 0.004))
)

# 2. Strategy erstellen
strategy <- create_strategy(
  SPY = asset_config(
    asset_class = "etf",
    action_type = "bnh",
    asset_share = 0.60,
    asset_spread = 0.10,
    asset_bonus = 30
  ),
  BND = asset_config(
    asset_class = "etf",
    action_type = "bnh",
    asset_share = 0.40,
    asset_spread = 0.05,
    asset_bonus = 0
  )
)

# 3. Validieren
validate_strategy(strategy, data = data)

# 4. Ausgeben
print(strategy)
summary(strategy)

# 5. Simulation (wenn Funktion implementiert ist)
result <- simulation(
  data = data,
  strategy = strategy,  # Kann direkt verwendet werden
  start_value = 10000
)
```

## Migration von alter Liste zu neuer Klasse

### Alt (Liste):
```r
strategy <- list(
  SPY = list(
    asset_class = "etf",
    action_type = "bnh",
    asset_share = 0.6,
    asset_spread = 0.1,
    asset_bonus = 30,
    signal_buy = NULL,
    signal_sell = NULL
  )
)
```

### Neu (S3-Klasse):
```r
strategy <- create_strategy(
  SPY = asset_config(
    asset_class = "etf",
    action_type = "bnh",
    asset_share = 0.6,
    asset_spread = 0.1,
    asset_bonus = 30
  )
)
# signal_buy/sell nicht nötig bei bnh!
```

## Automatische Migration

```r
# Falls Sie alte Listen haben:
old_strategy <- list(SPY = list(...), BND = list(...))

# Konvertieren:
new_strategy <- create_strategy(assets = old_strategy)
# Validiert automatisch und erstellt Strategy-Objekt
```
