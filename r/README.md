<p align="center">
  <img src="man/figures/logo.png" alt="SimLev-Logo" width="220" />
</p>

<h1 align="center">SimLev für R</h1>

<p align="center">
  <strong>Simulation und Backtesting für Basis-, Hebel- und Multi-Asset-Strategien für Exchange Traded Products</strong>
</p>

---

Dies ist das R-Paket **SimLev**, die Referenzimplementierung. Die
Python-Fassung 0.5.0 und die Julia-Fassung 0.5.0 im selben Repository sind
vollständige Ports dieser Fassung und rechnen bitgleich zu ihr (siehe
[`NEWS.md`](NEWS.md)).

**Die vollständige Dokumentation mit Schnellstart, Grundkonzepten und
Beispielen für alle drei Sprachen steht in der
[Haupt-README](../README.md).** Hier finden Sie nur, was speziell das
R-Paket betrifft.

## Installation

SimLev enthält C++- und C-Code (Marktupdates, FIFO-Lotverwaltung, Steuerkern,
Bootstrap- und Entnahme-Kerne; angebunden über R's eigene C-Schnittstelle,
ohne Rcpp) und wird aus dem Quellcode kompiliert. Zum Installieren braucht es
außer Basis-R keine weiteren Pakete. Neben **R ≥ 4.0** brauchen Sie einen
funktionierenden Compiler:

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
install.packages("SimLev_0.5.0.tar.gz", repos = NULL, type = "source")
```

**Optionale Pakete:**

| Paket | Wofür |
|---|---|
| `testthat` | Ausführen der Test-Suite |
| `knitr`, `rmarkdown` | Bauen der Vignette |

Technische Indikatoren für Signalstrategien (z. B. gleitende Durchschnitte)
lassen sich bequem mit dem Paket `TTR` berechnen (`TTR::SMA()` u. a.). `TTR`
ist keine Abhängigkeit von SimLev und wird bei Bedarf separat installiert
(`install.packages("TTR")`).

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

print(result)   # CAGR +5.93 %, Endwert 17.765,20 EUR
plot(result)
```

## Weiterführende Dokumentation im Paket

- `?SimLev` – Arbeitsweise (eigene Daten einlesen oder erzeugen,
  simulieren, fertige Simulationen weiterverarbeiten) und Glossar der
  Einheiten und Argumentnamen
- [`NEWS.md`](NEWS.md) – Änderungen je Version
- `?simulation` – alle Argumente der Hauptfunktion im Detail, inklusive
  Terminverschiebung, signalbewusstem Rebalancing und Event-Rebalancing
- `?asset_config`, `?create_strategy` – Assets und Strategien
- `?read_tax_tariff` – Einkommensteuertarif (§ 32a EStG, Soli) aus einer
  austauschbaren Datei für `simulation(..., taxable_income =)`
- `?compute_rebal_trigger` – ereignisbasierte Trigger
- `?plot.SimLevResult` – Visualisierung und Export
- `vignette("getting-started", package = "SimLev")` – Einführung Schritt
  für Schritt
- [`inst/examples/rebal_trigger_cookbook.R`](inst/examples/rebal_trigger_cookbook.R) –
  kommentierte Vorlagen für eigene Trigger-Regeln
- `?backcast_fit`, `?bootstrap_study`, `?withdrawal_simulation` – Backcast
  von Produkten, Bootstrap-Studien und Entnahmephase
- `?deep_analysis`, `?rebalancing_sensitivity`, `?lumpsum_vs_dca` –
  vertiefte Auswertung und Parameterstudien
- `?param_search`, `?pbo`, `?deflated_sharpe`, `?walk_forward`, `?signals` –
  Parametersuche mit Prüfung auf Überanpassung
- `?align_series`, `?check_series`, `?align_macro`, `?portfolio_template` –
  Daten- und Portfolio-Aufbereitung
- `?dependence_analysis`, `?fit_copula`, `?tail_regression`,
  `?covar_analysis` – Abhängigkeiten, Tail-Risiko und Drittvariablen
- `?tactical_simulation`, `?tactical_rules`, `?tactical_rotation`,
  `?target_volatility`, `?conditional_volatility` – taktische Allokation
- `?portfolio_optimize`, `?efficient_frontier`, `?risk_contributions` –
  Optimierung und Risikozerlegung
- `?bond_index_from_yields`, `?money_market_index` – synthetische Reihen
- `?entropy_pooling`, `?copula_scenarios`, `?crisis_replay` – Szenarien
- `?pooled_bootstrap`, `?horizon_model`, `?goal_optimize` – Planung
- `?sharpe_test`, `?reality_check`, `?signal_analysis`, `?regime_hmm` –
  Prüfungen und Regime
- [`inst/tutorial/`](inst/tutorial/) – Tutorial (R Markdown, Ausgabe als
  HTML)
- [`inst/examples/`](inst/examples/) – ausführliche Beispielsammlungen zu
  Strategie-Objekten, Dashboards sowie Backcast, Bootstrap und Entnahmen
  ([`backcast_bootstrap_withdrawal_examples.md`](inst/examples/backcast_bootstrap_withdrawal_examples.md))

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
  simulation.R               simulation(), Ablaufsteuerung, print/summary
  sim_base.R                 Steuer-, Termin-, Handels-, Split- und Gebührenfunktionen,
                             Tarifweg, Jahreswechsel, Kennzahlen
  sim_validate.R, sim_prepare.R, sim_actions.R, sim_loop.R, sim_evaluate.R
                             Phasen von simulation(): Eingabeprüfung, Vorbereitung,
                             Zahlungshelfer, Tagesschleife, Auswertung
  tax_tariff.R               read_tax_tariff(): Einkommensteuertarif aus
                             inst/extdata/steuertarif.csv
  asset_config.R, strategy.R asset_config(), create_strategy() & Co.
  compute_rebal_trigger.R    ereignisbasierte Trigger
  plot_dashboard.R           statisches Dashboard (Base-Grafik)
  backcast.R                 backcast_fit(), backcast()
  bootstrap.R                bootstrap_config(), bootstrap(), bootstrap_study(), block_length()
  withdrawal.R               withdrawal_rule(), withdrawal_simulation() & Co.
  deep_analysis.R            deep_analysis(): vertiefte Auswertung
  sensitivity.R              sensitivity_grid(), rebalancing_sensitivity(),
                             lumpsum_vs_dca(), leverage_sensitivity()
  signals.R                  signal_sma() & Co.: parametrisierbare Signale
  param_search.R             param_space(), param_search(), plateau()
  overfitting.R              pbo(), deflated_sharpe(), walk_forward(),
                             param_bootstrap()
  data_prep.R                align_series(), check_series(), align_macro(),
                             splice_series(), portfolio_template() & Co.
  dependence.R               dependence_analysis(), fit_copula(), dcc_fit(),
                             quantile_reg(), tail_regression(), covar_analysis()
  tactical.R                 tactical_rules(), tactical_rotation(),
                             target_volatility(), conditional_volatility(),
                             glidepath(), tactical_simulation()
  optimize.R                 portfolio_optimize(), efficient_frontier(),
                             rolling_optimization(), risk_contributions()
  bonds.R                    bond_index_from_yields(), money_market_index(),
                             currency_hedged_index()
  scenarios.R                entropy_pooling(), copula_scenarios(),
                             scenario_risk(), crisis_replay()
  planning.R                 set_expected_return(), pooled_bootstrap(),
                             portfolio_returns(), goal_optimize()
  analysis_tests.R           signal_analysis(), sharpe_test(), reality_check(),
                             min_track_record(), return_heatmap()
  regimes.R                  regime_hmm(), regime_states()
  cores.R                    .Call-Hüllen der C++-Kerne
  utils.R
src/                         C++-Kerne (FIFO, Steuern, Markt-Updates,
                             Bootstrap-Verfahren, Entnahmeregeln, DCC),
                             init.c (Registrierung), simlev_capi.h
                             (Anbindung an R's C-Schnittstelle)
man/                         Hilfeseiten
tests/testthat/              Test-Suite
vignettes/                   Einführung
inst/examples/               Beispielsammlungen
```

## Lizenz

GPL-3. Siehe [LICENSE.md](../LICENSE.md) im Hauptverzeichnis.
