<p align="center">
  <img src="man/figures/logo.png" alt="SimLev-Logo" width="220" />
</p>

<h1 align="center">SimLev für R</h1>

<p align="center">
  <strong>Simulation und Backtesting für Basis-, Hebel- und Multi-Asset-Strategien für Exchange Traded Products</strong>
</p>

---

Dies ist das R-Paket **SimLev**, die Referenzimplementierung. Die
Python- und die Julia-Fassung im selben Repository rechnen bitgleich zu ihm.

**Die vollständige Dokumentation mit Schnellstart, Grundkonzepten und
Beispielen für alle drei Sprachen steht in der
[Haupt-README](../README.md).** Hier finden Sie nur, was speziell das
R-Paket betrifft.

## Installation

SimLev enthält C++-Code (Marktupdates, FIFO-Lotverwaltung, Steuerkern über
[Rcpp](https://www.rcpp.org/)) und wird aus dem Quellcode kompiliert. Neben
**R ≥ 4.0** brauchen Sie einen funktionierenden Compiler:

| Betriebssystem | Was Sie benötigen |
|---|---|
| Windows | [Rtools](https://cran.r-project.org/bin/windows/Rtools/) in der zu Ihrer R-Version passenden Ausgabe |
| macOS | Xcode Command Line Tools (`xcode-select --install` im Terminal) |
| Linux | `build-essential` bzw. `gcc`/`g++` und die R-Entwicklungspakete (z. B. `r-base-dev`) |

Ob alles bereit ist, prüft `pkgbuild::check_build_tools()`.

``` r
# install.packages("remotes")
remotes::install_github("chemicalstats/SimLev-Repos", subdir = "r")

# oder aus einem lokalen Quellarchiv
install.packages("SimLev_0.1.0.tar.gz", repos = NULL, type = "source")
```

**Optionale Pakete:**

| Paket | Wofür |
|---|---|
| `plotly` | Interaktives HTML-Dashboard über plotly (ohne plotly schreibt SimLev ein eigenes, abhängigkeitsfreies HTML) |
| `TTR` | Bequeme Berechnung technischer Indikatoren (z. B. gleitende Durchschnitte) für Signalstrategien |
| `testthat` | Ausführen der Test-Suite |
| `knitr`, `rmarkdown` | Bauen der Vignette |

## Kurzbeispiel

``` r
library(SimLev)

set.seed(42)
n <- 365 * 10
data <- data.frame(
  date  = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n),
  WORLD = 100 * cumprod(1 + rnorm(n, 4e-4, 0.010)),
  BONDS =  50 * cumprod(1 + rnorm(n, 1e-4, 0.003))
)

strategy <- create_strategy(
  WORLD = asset_config("etf", action_type = "bnh", asset_share = 0.7, asset_spread = 0.1, asset_bonus = 30),
  BONDS = asset_config("etf", action_type = "bnh", asset_share = 0.3, asset_spread = 0.1, asset_bonus = 0)
)

result <- simulation(data, strategy,
                     start_value = 10000,
                     balance_mode = TRUE, balance_span = 1, balance_unit = "year",
                     tax_mode = "person", tax_rate = 26.375,
                     liquidate = TRUE, risk_free = 2)

print(result)   # CAGR +5.93 %, Endwert 17.772,63 EUR
plot(result)
```

## Weiterführende Dokumentation im Paket

- `?simulation` – alle Argumente der Hauptfunktion im Detail, inklusive
  Terminverschiebung, signalbewusstem Rebalancing und Event-Rebalancing
- `?asset_config`, `?create_strategy` – Assets und Strategien
- `?compute_rebal_trigger` – ereignisbasierte Trigger
- `?plot.SimLevResult`, `?plot_interactive` – Visualisierung und Export
- `vignette("getting-started", package = "SimLev")` – Einführung Schritt
  für Schritt
- [`R/rebal_trigger_cookbook.R`](R/rebal_trigger_cookbook.R) – kommentierte
  Vorlagen für eigene Trigger-Regeln
- [`inst/examples/`](inst/examples/) – ausführliche Beispielsammlungen zu
  Strategie-Objekten und Dashboards

## Tests

``` r
devtools::test()            # im Ordner r/
rcmdcheck::rcmdcheck()      # vollständiger Paket-Check
```

Die Golden-Master-Fälle in [`../golden/`](../golden/) werden mit diesem
Paket erzeugt. Wer die Rechenlogik ändert, muss die Fälle neu erzeugen und
die Python- und Julia-Fassung entsprechend nachziehen.

## Paketaufbau

```
R/
  simulation.R               simulation(), Ablaufsteuerung
  asset_config.R, strategy.R asset_config(), create_strategy() & Co.
  compute_rebal_trigger.R    ereignisbasierte Trigger
  rebal_trigger_cookbook.R   Vorlagen für eigene Trigger
  plot_dashboard.R           statisches Dashboard (Base-Grafik)
  plot_interactive.R         interaktives HTML-Dashboard
  RcppExports.R, utils.R
src/                         C++-Kerne (FIFO, Steuern, Markt-Updates)
man/                         Hilfeseiten
tests/testthat/              Test-Suite
vignettes/                   Einführung
inst/examples/               Beispielsammlungen
```

## Lizenz

GPL-3. Siehe [LICENSE.md](../LICENSE.md) im Hauptverzeichnis.
