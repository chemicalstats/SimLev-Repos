# Strategy-Klasse: Verwendungsbeispiele

## Grundlegende Verwendung

### 1. Einfache Strategy erstellen

```r
library(SimLev)

# Methode 1: Direkt mit create_strategy()
strategy <- create_strategy(
  SPY = asset_config(
    asset_class = "etf",
    trading = "bnh",
    share = 1.0,
    spread = 0.1,
    partial_exemption = 30
  )
)

print(strategy)
```

### 2. Multi-Asset Strategy

```r
strategy <- create_strategy(
  SPY = asset_config(
    asset_class = "etf",
    trading = "bnh",
    share = 0.60,
    spread = 0.10,
    partial_exemption = 30
  ),
  BND = asset_config(
    asset_class = "etf",
    trading = "bnh",
    share = 0.40,
    spread = 0.05,
    partial_exemption = 0
  )
)

print(strategy)
summary(strategy)
```

### 3. Signal-basierte Strategy (SMA)

Die gleitenden Durchschnitte berechnet hier das Paket `TTR`. Es ist keine
Abhängigkeit von SimLev und wird bei Bedarf separat installiert
(`install.packages("TTR")`); jede andere Berechnung der Signale geht ebenso.

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
    trading = "signal",       # Signal-based!
    share = 1.0,
    spread = 0.10,
    partial_exemption = 30,
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
    trading = "FALSCH",  # ❌ Error: 'arg' should be one of "bnh", "signal"
    share = 0.6
  )
)

# Ohne weitere Angaben gelten die Standardwerte von asset_config():
strategy <- create_strategy(
  SPY = asset_config(
    asset_class = "etf"
    # kein Fehler: trading = "bnh", share = 1,
    # spread = 0.1, partial_exemption = 0
  )
)

# Ungültige Werte werden erkannt (die erste Verletzung bricht ab):
strategy <- create_strategy(
  SPY = asset_config(
    asset_class = "etf",
    trading = "bnh",
    share = -0.5,      # ❌ Fehler: asset_config: share muss ein Anteil groesser 0 und hoechstens 1 sein (z. B. 0.6 fuer 60 %), nicht -0.5.
    spread = 0.1,
    partial_exemption = 150        # ❌ Fehler: asset_config: partial_exemption muss zwischen 0 und 100 liegen (Teilfreistellung in Prozent, z. B. 30 fuer 30 %), nicht 150.
  )
)
```

### Signalspalten bei Buy-and-Hold

```r
# Signalspalten bei trading = "bnh":
strategy <- create_strategy(
  SPY = asset_config(
    asset_class = "etf",
    trading = "bnh",
    share = 1.0,
    spread = 0.1,
    partial_exemption = 30,
    signal_buy = "buy",
    signal_sell = "sell"
  )
)
# Keine Warnung: signal_buy/signal_sell werden gespeichert, aber nur bei
# trading = "signal" ausgewertet (simulation() und strategy_validate()).
```

### ✅ Validierung gegen Daten

```r
# Prüfe ob Strategy zu Daten passt
strategy_validate(strategy, data = data)

# Fehler wenn Asset fehlt:
# Fehler: strategy_validate: Kursspalte(n) 'AAPL' fehlen in data (je Asset eine Spalte gleichen Namens; vorhanden: ...).

# Fehler wenn Signal-Spalten fehlen:
# Fehler: strategy_validate: signal_buy-Spalte 'spy_buy' fehlt in data (Asset 'SPY').
```

## Hilfsfunktionen

Die folgenden Schritte bauen nacheinander auf der Multi-Asset-Strategie aus
Abschnitt 2 auf (SPY 0,60, BND 0,40). Weil `strategy` in den Abschnitten
dazwischen überschrieben wurde, wird sie hier neu angelegt; sonst bricht
`strategy_remove_asset(strategy, "BND")` unten mit „Asset 'BND' ist nicht in der
Strategie“ ab.

```r
strategy <- create_strategy(
  SPY = asset_config(asset_class = "etf", trading = "bnh",
                     share = 0.60, spread = 0.10, partial_exemption = 30),
  BND = asset_config(asset_class = "etf", trading = "bnh",
                     share = 0.40, spread = 0.05, partial_exemption = 0)
)
```

### Asset hinzufügen

```r
strategy <- strategy_add_asset(
  strategy,
  name = "QQQ",
  asset = asset_config(
    asset_class = "etf",
    trading = "bnh",
    share = 0.20,
    spread = 0.10,
    partial_exemption = 30
  )
)
```

### Asset aktualisieren

Die Gewichte (`share`) aller Assets müssen zusammen 1 ergeben, sonst
bricht `simulation()` mit einer Fehlermeldung ab. Nach dem Hinzufügen von
QQQ (0,20) liegt die Summe bei 1,20; deshalb wird SPY hier auf 0,40
gesenkt (SPY 0,40 + BND 0,40 + QQQ 0,20 = 1).

```r
# Einzelne Parameter ändern
strategy <- strategy_update_asset(
  strategy,
  name = "SPY",
  share = 0.40,
  spread = 0.15
)
```

### Asset entfernen

Nach dem Entfernen von BND fehlen dessen 0,40; SPY übernimmt sie, damit die
Summe wieder 1 ist (SPY 0,80 + QQQ 0,20).

```r
strategy <- strategy_remove_asset(strategy, "BND")
strategy <- strategy_update_asset(strategy, name = "SPY", share = 0.80)
```

## Ausgabe

### print()

```r
print(strategy)
```

Ausgabe (Multi-Asset-Strategie aus Abschnitt 2):
```
Anlagestrategie (2 Assets)
================================

SPY:
  Klasse: etf | Anteil: 60% | Steuer: investment_fund
BND:
  Klasse: etf | Anteil: 40% | Steuer: investment_fund
```

### summary()

```r
summary(strategy)
```

Ausgabe:
```
Strategie-Übersicht: 2 Assets

Gesamtgewicht: 100.0%

Nach Steuerregime:
  investment_fund: 2 Assets
```

## Backward Compatibility

`simulation()` akzeptiert Strategie-Objekte und einfache Listen. Eine
Strategie lässt sich bei Bedarf in eine Liste umwandeln:

```r
# Konvertiere zu alter Liste (Klasse entfernen)
old_format <- unclass(strategy)

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
    trading = "bnh",
    share = 0.60,
    spread = 0.10,
    partial_exemption = 30
  ),
  BND = asset_config(
    asset_class = "etf",
    trading = "bnh",
    share = 0.40,
    spread = 0.05,
    partial_exemption = 0
  )
)

# 3. Validieren
strategy_validate(strategy, data = data)

# 4. Ausgeben
print(strategy)
summary(strategy)

# 5. Simulation
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
    trading = "bnh",
    share = 0.6,
    spread = 0.1,
    partial_exemption = 30,
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
    trading = "bnh",
    share = 0.6,
    spread = 0.1,
    partial_exemption = 30
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
