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
  WORLD = asset_config("etf", trading = "bnh", share = 0.7, spread = 0.1, partial_exemption = 30),
  BONDS = asset_config("etf", trading = "bnh", share = 0.3, spread = 0.1, partial_exemption = 0)
)

result <- simulation(data, strategy,
                     start_value = 10000,
                     rebalance = rebalance_plan(span = 1, unit = "year"),
                     tax = tax_profile(rate = 26.375),
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
- `?tax_tariff` – Einkommensteuertarif (§ 32a EStG, Soli) aus einer
  austauschbaren Datei für `simulation(tax = tax_profile(income = income_tariff(taxable_income)))`
- `?rebalance_trigger` – ereignisbasierte Trigger
- `?plot.SimLevResult` – Visualisierung und Export
- `vignette("getting-started", package = "SimLev")` – Einführung Schritt
  für Schritt
- [`inst/examples/rebal_trigger_cookbook.R`](inst/examples/rebal_trigger_cookbook.R) –
  kommentierte Vorlagen für eigene Trigger-Regeln
- `?backcast_fit`, `?bootstrap_study`, `?withdrawal_simulation` – Backcast
  von Produkten, Bootstrap-Studien und Entnahmephase
- `?result_analysis`, `?sensitivity_rebalancing`, `?planning_lumpsum_vs_dca` –
  vertiefte Auswertung und Parameterstudien
- `?param_search`, `?overfit_pbo`, `?sharpe_deflated`, `?overfit_walk_forward`, `?signals` –
  Parametersuche mit Prüfung auf Überanpassung
- `?series_align`, `?series_check`, `?series_align_macro`, `?portfolio_template` –
  Daten- und Portfolio-Aufbereitung
- `?dependence_analysis`, `?copula_fit`, `?tail_regression`,
  `?tail_covar` – Abhängigkeiten, Tail-Risiko und Drittvariablen
- `?tactical_simulation`, `?tactical_rules`, `?tactical_rotation`,
  `?tactical_target_volatility`, `?tactical_conditional_volatility` – taktische Allokation
- `?portfolio_optimize`, `?portfolio_frontier`, `?portfolio_risk_contributions` –
  Optimierung und Risikozerlegung
- `?index_bond`, `?index_money_market` – synthetische Reihen
- `?scenario_entropy_pooling`, `?scenario_copula`, `?scenario_crisis` – Szenarien
- `?bootstrap_pooled`, `?withdrawal_horizon`, `?planning_goal` – Planung
- `?sharpe_test`, `?overfit_reality_check`, `?signal_analysis`, `?regime_hmm` –
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

### Eingefrorene Schnittstelle

Die öffentliche Schnittstelle 0.5.0 (Exporte und S3-Methoden aus `NAMESPACE`,
Argumente in Reihenfolge mit Standardwerten) ist in
[`../tools/api_snapshot/frozen/r.json`](../tools/api_snapshot/frozen/r.json)
festgehalten. `tests/testthat/test-api-frozen.R` vergleicht die Quellen damit
und nennt jede Abweichung; beim Prüfen des gebauten Pakets (`R CMD check`)
ist die Datei nicht erreichbar, der Test wird dann übersprungen. Eine gewollte
Änderung: Eintrag oben in `tools/api_snapshot/CHANGES.md` (Datum, was,
warum), dann aus der Repo-Wurzel `tools/api_snapshot/run.sh --freeze`
(siehe [`tools/api_snapshot/README.md`](../tools/api_snapshot/README.md)).

## Paketaufbau

```
R/
  simulation.R               simulation(), Ablaufsteuerung, print/summary
  sim_base.R                 Steuer-, Termin-, Handels-, Split- und Gebührenfunktionen,
                             Tarifweg, Jahreswechsel, Kennzahlen
  sim_validate.R, sim_prepare.R, sim_actions.R, sim_loop.R, sim_evaluate.R
                             Phasen von simulation(): Eingabeprüfung, Vorbereitung,
                             Zahlungshelfer, Tagesschleife, Auswertung
  tax_tariff.R               tax_tariff(): Einkommensteuertarif aus
                             inst/extdata/steuertarif.csv
  asset_config.R, strategy.R asset_config(), create_strategy() & Co.
  compute_rebal_trigger.R    ereignisbasierte Trigger
  plot_dashboard.R           statisches Dashboard (Base-Grafik)
  backcast.R                 backcast_fit(), backcast()
  bootstrap.R                bootstrap_config(), bootstrap(), bootstrap_study(), bootstrap_block_length()
  withdrawal.R               withdrawal_rule(), withdrawal_simulation() & Co.
  deep_analysis.R            result_analysis(): vertiefte Auswertung
  sensitivity.R              sensitivity_grid(), sensitivity_rebalancing(),
                             planning_lumpsum_vs_dca(), sensitivity_leverage()
  signals.R                  signal_sma() & Co.: parametrisierbare Signale
  param_search.R             param_space(), param_search(), param_plateau()
  overfitting.R              overfit_pbo(), sharpe_deflated(), overfit_walk_forward(),
                             param_bootstrap()
  data_prep.R                series_align(), series_check(), series_align_macro(),
                             series_splice(), portfolio_template() & Co.
  dependence.R               dependence_analysis(), copula_fit(), dependence_dcc(),
                             quantile_regression(), tail_regression(), tail_covar()
  tactical.R                 tactical_rules(), tactical_rotation(),
                             tactical_target_volatility(), tactical_conditional_volatility(),
                             tactical_glidepath(), tactical_simulation()
  optimize.R                 portfolio_optimize(), portfolio_frontier(),
                             portfolio_rolling(), portfolio_risk_contributions()
  bonds.R                    index_bond(), index_money_market(),
                             index_currency_hedged()
  scenarios.R                scenario_entropy_pooling(), scenario_copula(),
                             scenario_risk(), scenario_crisis()
  planning.R                 series_shift_return(), bootstrap_pooled(),
                             portfolio_returns(), planning_goal()
  analysis_tests.R           signal_analysis(), sharpe_test(), overfit_reality_check(),
                             sharpe_min_track_record(), result_heatmap()
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
