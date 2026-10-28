<p align="center">
  <img src="docs/figures/logo.png" alt="SimLev-Logo" width="340" />
</p>

<h1 align="center">SimLev</h1>

<p align="center">
  <strong>Simulation und Backtesting für Basis-, Hebel- und Multi-Asset-Strategien für Exchange Traded Products</strong><br>
  für <a href="r/">R</a> · <a href="python/">Python</a> · <a href="julia/">Julia</a>
</p>

---

**SimLev** rechnet Anlagestrategien auf täglichen Preisreihen durch: von der
einfachen 70/30-Mischung aus Aktien- und Anleihe-ETF über Sparpläne und
Rebalancing bis zu signalgesteuerten Strategien mit gehebelten Produkten.
Der Unterschied zu gängigen Backtest-Werkzeugen ist die **detaillierte
Abbildung des deutschen Steuerrechts**. Vorabpauschale, Teilfreistellung,
Sparer-Pauschbetrag, getrennte Verlusttöpfe nach § 20 und § 23 EStG und die
Günstigerprüfung werden Tag für Tag mitgeführt. Ein Backtest zeigt so nicht
nur das Ergebnis *vor* Steuern, sondern auch, was einem deutschen
Privatanleger am Ende tatsächlich geblieben wäre.

SimLev gibt es in drei Sprachen. Das R-Paket ist die Referenz. Die
Python-Fassung 0.5.0 und die Julia-Fassung 0.5.0 sind vollständige Ports
der aktuellen R-Fassung 0.5.0 mit allen Erweiterungen und rechnen
**bitgleich** zu ihr: Jeder Tageswert, jede Kennzahl, jeder Steuerbetrag
und auch die (deutsche) Textausgabe stimmen exakt überein (siehe
[Bitgleichheit](#bitgleichheit-zum-r-paket)). Frühere Fassungen der Ports
(0.1.0) enthielten nur die Engine und entsprachen einem früheren Stand des
R-Pakets vor den Korrekturen (Commit 54b5b4f, damals ebenfalls als 0.5.0
bezeichnet; im Folgenden „Stand 54b5b4f“).

| Fassung | Ordner | Benötigt | Besonderheit |
|---|---|---|---|
| **R** | [`r/`](r/) | R ≥ 4.0, C- und C++-Compiler, keine externen Pakete | Referenzimplementierung |
| **Python** | [`python/`](python/) | Python ≥ 3.10, `numpy`, `pandas` | vollständiger Port von R 0.5.0 einschließlich aller Erweiterungen, bitgleich unter Linux x86-64; reines Python, kein Compiler nötig |
| **Julia** | [`julia/`](julia/) | Julia ≥ 1.10, keine externen Pakete | vollständiger Port von R 0.5.0 einschließlich aller Erweiterungen, bitgleich unter Linux x86-64; nur Standardbibliothek, Engine etwa 5- bis 30-mal so schnell wie R |

> **Sprachspezifische Beispiele sind aufklappbar.** Klicken Sie in den
> Abschnitten unten auf **R**, **Python** oder **Julia**, um den Code für
> Ihre Sprache zu sehen. Alles andere gilt für alle drei Fassungen.

## Inhalt

- [Auf einen Blick](#auf-einen-blick)
- [Installation](#installation)
- [Schnellstart](#schnellstart)
- [Grundkonzepte](#grundkonzepte)
  - [Eingabedaten](#eingabedaten)
  - [Die Prozent-Konvention](#die-prozent-konvention)
  - [Assets und Strategien](#assets-und-strategien)
  - [Buy-and-Hold und Signalstrategien](#buy-and-hold-und-signalstrategien)
  - [Sparpläne (DCA)](#sparpläne-dca)
  - [Rebalancing](#rebalancing)
  - [Besteuerung](#besteuerung)
  - [Splits bei gehebelten Produkten](#splits-bei-gehebelten-produkten)
- [Erweiterungen in R, Python und Julia](#erweiterungen-in-r-python-und-julia)
  - [Arbeitsweise und Glossar](#arbeitsweise-und-glossar)
  - [Backcast von Produkten](#backcast-von-produkten)
  - [Bootstrap-Studien](#bootstrap-studien)
  - [Entnahmephase](#entnahmephase)
  - [Vertiefte Analyse und Sensitivitäten](#vertiefte-analyse-und-sensitivitäten)
  - [Parametersuche und Überanpassung](#parametersuche-und-überanpassung)
  - [Daten und Portfolios aufbereiten](#daten-und-portfolios-aufbereiten)
  - [Abhängigkeiten, Tail-Risiko und Drittvariablen](#abhängigkeiten-tail-risiko-und-drittvariablen)
  - [Taktische Allokation](#taktische-allokation)
  - [Optimierung und Risikozerlegung](#optimierung-und-risikozerlegung)
  - [Anleihen, Geldmarkt und Währungssicherung](#anleihen-geldmarkt-und-währungssicherung)
  - [Gebühren, Kirchensteuer und Freibetrag](#gebühren-kirchensteuer-und-freibetrag)
  - [Szenarien und Stresstests](#szenarien-und-stresstests)
  - [Planung über lange Horizonte](#planung-über-lange-horizonte)
  - [Statistische Prüfungen und Regime](#statistische-prüfungen-und-regime)
- [Ergebnisse auswerten](#ergebnisse-auswerten)
- [Unterschiede zwischen den Sprachen](#unterschiede-zwischen-den-sprachen)
- [Bitgleichheit zum R-Paket](#bitgleichheit-zum-r-paket)
- [Geschwindigkeit](#geschwindigkeit)
- [Wie die Engine arbeitet](#wie-die-engine-arbeitet)
- [Grenzen und wichtige Hinweise](#grenzen-und-wichtige-hinweise)
- [Aufbau des Repositorys und Entwicklung](#aufbau-des-repositorys-und-entwicklung)
- [Hilfe und Mitwirken](#hilfe-und-mitwirken)
- [Lizenz](#lizenz)

## Auf einen Blick

| Bereich | Was SimLev kann |
|---|---|
| **Handelslogik** | Buy-and-Hold, signalgesteuerte Ein- und Ausstiege, gestaffelte Asset-Starts, Bruchstücke oder ganze Anteile |
| **Kapitalflüsse** | Einmalanlage, Sparpläne (monatlich, quartalsweise, jährlich), wahlweise mit Mini-Rebalancing über die Sparrate |
| **Rebalancing** | Kalenderbasiert, mit Toleranzschwelle oder ereignisbasiert (Hebel- und Volatilitäts-Trigger) |
| **Kosten** | Bid-Ask-Spread je Asset, optional laufende Fondskosten und Performancegebühr |
| **Steuern** | InvStG-Fondsbesteuerung, Abgeltungsteuer nach § 20 EStG, private Veräußerungsgeschäfte nach § 23 EStG |
| **Kennzahlen** | CAGR, TTWROR, Volatilität, Sharpe, Sortino, Calmar, Omega, Ulcer Index, Drawdown-Dauer u. v. m. |
| **Visualisierung** | Statisches Dashboard (R: Base-Grafik, Python und Julia: SVG ohne Zusatzpaket, mit den dargestellten Daten für eigene Grafiken) |
| **Backcast** | Rückrechnung von ETF/ETP-Historien aus Basisindex, TER-Reihe, Hebel und Tagesgeld; Fit der Abweichung mit Out-of-Sample-Test |
| **Bootstrap** | 14 Verfahren (Block, stationär, Regime, EVT, (GJR-)GARCH, MS-GARCH …), Hebelprodukte, Strategie-Studien über Hunderttausende Pfade |
| **Entnahmephase** | 14 Entnahmeregeln (4-%-Regel, Vanguard, Guyton-Klinger …) auf Kohorten, Bootstrap-Pfaden oder gespeicherten Simulationsergebnissen, mit vereinfachter deutscher Steuer |
| **Analyse** | `deep_analysis()`: Alpha, Beta, Capture, Tracking Error, Information Ratio, M², VaR/CVaR, MWRR, Rendite- und Monatstabellen, Drawdown-Tabelle, rollierende Kennzahlen; Sensitivitäten für Rebalancing, Lump Sum vs. DCA und Hebel |
| **Parametersuche** | Raster, Zufallssuche und Latin Hypercube über Strategie-, Signal- und Simulationsparameter; Plateau-Auswahl, Probability of Backtest Overfitting, Deflated Sharpe Ratio, Walk-Forward, Prüfung der besten Punkte auf Bootstrap-Pfaden |
| **Datenaufbereitung** | Quellen zusammenführen, Prüfbericht (Lücken, Spikes, Splits), Makroreihen mit Veröffentlichungsverzug, Währung, Total Return, reale Werte, Verkettung, Portfolio-Vorlagen |
| **Abhängigkeiten** | Rang- und Tail-Abhängigkeit, Copulas (Gauß, t, Clayton, Gumbel, Frank), DCC, Korrelation je Regime von Inflation, Zinsen oder Spreads mit Block-Bootstrap, Quantilsregression, CoVaR |
| **Taktische Allokation** | Regeln mit Rückfall-Portfolio, Momentum-Rotation, Dual Momentum, Canary-Schutz, Zielvolatilität (auch bedingt, nur in extremen Phasen), Glidepath, Kern-Satellit; Ausführung mit Steuern und Kosten über die Engine |
| **Optimierung** | Minimum-Varianz, maximale Sharpe Ratio, maximale Diversifikation, Risikoparität mit Budgets, HRP, minimaler CVaR; Grenzen, Ledoit-Wolf, Resampling, Effizienzgrenze, rollierende Optimierung, Risikobeiträge |
| **Synthetische Reihen** | Anleihe-Index aus Renditen (konstante Laufzeit), Geldmarkt-Index aus Tagesgeld, währungsgesicherte Reihen |
| **Deutsche Praxis** | Ordergebühren (fix, prozentual, Mindest-/Höchstbetrag, eigene Sparplan-Gebühr), Kirchensteuer, jährliches Ausschöpfen des Sparer-Pauschbetrags |
| **Szenarien** | Entropy Pooling mit eigenen Annahmen, Copula-Szenarien unter Stress, Krisen-Replay |
| **Planung** | Länder-Bootstrap, eigene Renditeannahmen, zufällige Ruhestandsdauer nach eigenen Vorgaben, zielbasierte Allokation per dynamischer Programmierung |
| **Prüfungen** | Sharpe-Differenztest (Ledoit-Wolf), Reality Check und SPA, Mindest-Historie, Harvey-Liu-Abschläge, CPCV, Signal-Analyse, Hidden-Markov-Regime, reale Kennzahlen, Rendite-Heatmaps |
| **Geschwindigkeit** | 30 Jahre Tagesdaten mit drei Assets, Sparplan, Rebalancing und Steuern in rund 0,03 s (Julia) bis 0,2 s (R) |

## Installation

<details>
<summary><b>R</b></summary>

SimLev enthält C++-Code und wird aus dem Quellcode kompiliert. Neben
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
```

Aus einem lokalen Quellarchiv:

``` r
install.packages("SimLev_0.5.0.tar.gz", repos = NULL, type = "source")
```

Optionale Pakete: `testthat` (Tests), `knitr` und `rmarkdown` (Vignette).
Technische Indikatoren für Signalstrategien lassen sich bequem mit dem
Paket `TTR` berechnen (z. B. `TTR::SMA()`); es ist keine Abhängigkeit von
SimLev und wird bei Bedarf separat installiert.

</details>

<details>
<summary><b>Python</b></summary>

SimLev ist reines Python ab Version 3.10 (geprüft ab Python 3.10). Ein
Compiler wird nicht benötigt.

``` bash
pip install "simlev @ git+https://github.com/chemicalstats/SimLev-Repos#subdirectory=python"
```

Aus einem lokalen Klon:

``` bash
cd python
pip install .                 # Engine und alle Erweiterungen (numpy, pandas)
```

| Paket | Wofür | Pflicht? |
|---|---|---|
| `numpy`, `pandas` | Rechenkern und Datenaufnahme | ja |
| `pytest` | Test-Suite | optional |

</details>

<details>
<summary><b>Julia</b></summary>

Benötigt wird **Julia ab Version 1.10** (geprüft ab Julia 1.10, zuletzt mit
Julia 1.13.2). Weitere
Pakete sind nicht nötig, nur die Standardbibliothek.

``` julia
using Pkg
Pkg.add(url = "https://github.com/chemicalstats/SimLev-Repos", subdir = "julia")
# oder aus einem lokalen Klon:
# Pkg.develop(path = "pfad/zu/SimLev-Repos/julia")
```

Beim ersten `using SimLev` kompiliert Julia das Paket einmalig vor; das
dauert einige Minuten. Danach lädt es in unter einer Sekunde. Der erste
Aufruf einer Funktion in einer Sitzung kompiliert noch nach (auf der
Prüfmaschine etwa 2 Sekunden für `simulation()`, etwa 5 Sekunden für das
erste Dashboard); jeder weitere Aufruf ist schnell (siehe
[`julia/README.md`](julia/README.md#installation)).

</details>

## Schnellstart

Das Beispiel simuliert zehn Jahre einer 70/30-Mischung aus einem Aktien-ETF
(`WORLD`) und einem Anleihe-ETF (`BONDS`): 10.000 EUR Einmalanlage,
jährliches Rebalancing, deutsche Privatbesteuerung und Verkauf aller
Positionen am Ende. Die Preise sind synthetisch, damit das Beispiel ohne
externe Daten läuft. In der Praxis setzen Sie hier Ihre eigenen Kursreihen
ein.

<details>
<summary><b>R</b></summary>

``` r
library(SimLev)

# 1. Preisdaten: eine Datumsspalte plus eine Preisspalte je Asset
set.seed(42)
n <- 365 * 10
data <- data.frame(
  date  = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n),
  WORLD = 100 * cumprod(1 + rnorm(n, 4e-4, 0.010)),
  BONDS =  50 * cumprod(1 + rnorm(n, 1e-4, 0.003))
)

# 2. Strategie: Gewichte, Kosten und Teilfreistellung
#    (30 % für Aktien-ETFs, 0 % für Renten-ETFs)
strategy <- create_strategy(
  WORLD = asset_config("etf", action_type = "bnh",
                       asset_share = 0.7, asset_spread = 0.1, asset_bonus = 30),
  BONDS = asset_config("etf", action_type = "bnh",
                       asset_share = 0.3, asset_spread = 0.1, asset_bonus = 0)
)

# 3. Simulation
result <- simulation(
  data, strategy,
  start_value  = 10000,
  balance_mode = TRUE, balance_span = 1, balance_unit = "year",
  tax_mode     = "person", tax_rate = 26.375,
  liquidate    = TRUE,
  risk_free    = 2
)

print(result)
plot(result)
```

```
  Wertentwicklung
  ─────────────────────
  CAGR:             +5.93%
  TTWROR:           +5.93%
  Endwert:          17765.20 EUR

  Risiko
  ─────────────────────
  Max. Drawdown:    20.88%
  ...
  Längster DD:      826 Tage
  ...
  Steuern
  ─────────────────────
  Gezahlte Steuern: 1368.47 EUR
  Verlustvortrag:   0.00 EUR (§ 20) / 0.00 EUR (§ 23)
  SPB genutzt:      1650.24 EUR (Ersparnis: 435.25 EUR)
```

Aus 10.000 EUR wurden nach zehn Jahren, allen Spreads und allen Steuern
17.765,20 EUR, also 5,93 % pro Jahr. Ohne Steuern (`tax_mode = "none"`) wären
es 19.133,67 EUR (6,72 % p. a.) gewesen.

<p align="center">
  <img src="docs/figures/dashboard-r.png" alt="SimLev-Dashboard aus R" width="100%" />
</p>

</details>

<details>
<summary><b>Python</b></summary>

Das vollständige Skript liegt unter
[`python/examples/schnellstart.py`](python/examples/schnellstart.py).

``` python
import numpy as np
import pandas as pd
import simlev

# 1. Preisdaten: eine Datumsspalte plus eine Preisspalte je Asset
rng = np.random.default_rng(42)
n = 365 * 10
data = pd.DataFrame({
    "date":  pd.date_range("2015-01-01", periods=n, freq="D"),
    "WORLD": 100 * np.cumprod(1 + rng.normal(4e-4, 0.010, n)),
    "BONDS":  50 * np.cumprod(1 + rng.normal(1e-4, 0.003, n)),
})

# 2. Strategie: Gewichte, Kosten und Teilfreistellung
strategy = simlev.create_strategy(
    WORLD=simlev.asset_config("etf", action_type="bnh", asset_share=0.7, asset_spread=0.1, asset_bonus=30),
    BONDS=simlev.asset_config("etf", action_type="bnh", asset_share=0.3, asset_spread=0.1, asset_bonus=0),
)

# 3. Simulation
result = simlev.simulation(
    data, strategy,
    start_value=10000,
    balance_mode=True, balance_span=1, balance_unit="year",
    tax_mode="person", tax_rate=26.375,
    liquidate=True,
    risk_free=2,
)

print(result)
result.plot()
```

Ausgabe (dieselbe liefert das R-Paket 0.5.0 für diese Kursdaten):

```
  Wertentwicklung
  ─────────────────────
  CAGR:             +6.75%
  TTWROR:           +6.75%
  Endwert:          19193.75 EUR

  Risiko
  ─────────────────────
  Max. Drawdown:    35.74%
  ...
  Längster DD:      1317 Tage
  ...
  Steuern
  ─────────────────────
  Gezahlte Steuern: 1821.49 EUR
  Verlustvortrag:   0.00 EUR (§ 20) / 0.00 EUR (§ 23)
  SPB genutzt:      1313.17 EUR (Ersparnis: 346.35 EUR)
```

Aus 10.000 EUR wurden 19.193,75 EUR, also 6,75 % pro Jahr. Ohne Steuern
(`tax_mode="none"`) wären es 21.015,24 EUR (7,72 % p. a.) gewesen.

<p align="center">
  <img src="docs/figures/dashboard-python.png" alt="SimLev-Dashboard aus Python" width="100%" />
</p>

</details>

<details>
<summary><b>Julia</b></summary>

Das vollständige Skript liegt unter
[`julia/examples/schnellstart.jl`](julia/examples/schnellstart.jl).

``` julia
using SimLev, Dates, Random

# 1. Preisdaten: eine Datumsspalte plus eine Preisspalte je Asset
rng = MersenneTwister(42)
n = 365 * 10
data = (date  = collect(Date(2015, 1, 1):Day(1):Date(2015, 1, 1) + Day(n - 1)),
        WORLD = 100 .* cumprod(1 .+ 4e-4 .+ 0.010 .* randn(rng, n)),
        BONDS =  50 .* cumprod(1 .+ 1e-4 .+ 0.003 .* randn(rng, n)))

# 2. Strategie: Gewichte, Kosten und Teilfreistellung
strategy = create_strategy(
    WORLD = asset_config("etf", "bnh"; asset_share = 0.7, asset_spread = 0.1, asset_bonus = 30),
    BONDS = asset_config("etf", "bnh"; asset_share = 0.3, asset_spread = 0.1, asset_bonus = 0),
)

# 3. Simulation
result = simulation(data, strategy;
    start_value = 10000,
    balance_mode = true, balance_span = 1, balance_unit = "year",
    tax_mode = "person", tax_rate = 26.375,
    liquidate = true,
    risk_free = 2)

display(result)
plot_dashboard(result)
```

Ausgabe von `display(result)` (dieselben Zahlen liefern R 0.5.0 und
Python 0.5.0 für diese Kursdaten):

```
  Wertentwicklung
  ─────────────────────
  CAGR:             +4.54%
  TTWROR:           +4.54%
  Endwert:          15581.60 EUR

  Risiko
  ─────────────────────
  Max. Drawdown:    36.59%
  ...
  Längster DD:      666 Tage
  ...
  Steuern
  ─────────────────────
  Gezahlte Steuern: 758.08 EUR
  Verlustvortrag:   0.00 EUR (§ 20) / 0.00 EUR (§ 23)
  SPB genutzt:      2017.67 EUR (Ersparnis: 532.16 EUR)
```

Aus 10.000 EUR wurden 15.581,60 EUR, also 4,54 % pro Jahr. Ohne Steuern
(`tax_mode = "none"`) wären es 16.339,67 EUR (5,04 % p. a.) gewesen.

<p align="center">
  <img src="docs/figures/dashboard-julia.png" alt="SimLev-Dashboard aus Julia" width="100%" />
</p>

</details>

**Warum unterscheiden sich die Zahlen?** Jede Sprache erzeugt die
synthetischen Kurse mit ihrem eigenen Zufallsgenerator, die Preisreihen sind
also verschieden. Mit identischen Eingabedaten liefern alle drei Fassungen
exakt dasselbe Ergebnis: Mit den Kursen des R-Beispiels (in Python erzeugt
mit `simlev.set_seed(42)`, `simlev._r.rng.rnorm()` und
`simlev._r.rnum.r_cumprod()`, in Julia mit `set_seed(42)`,
`SimLev.RRng.rnorm()` und `SimLev.RBase.r_cumprod()`) zeigen auch Python und
Julia 17.765,20 EUR Endwert und 1.368,47 EUR Steuern. Ebenso liefern R und
Julia mit den Kursen des Python-Beispiels 19.193,75 EUR und R und Python mit
den Kursen des Julia-Beispiels 15.581,60 EUR (Kurse jeweils als CSV mit
voller Genauigkeit übergeben).

**So lesen Sie das Ergebnis:** *Endwert* ist der
Depotwert nach allen Spreads und Steuern, *CAGR* die jährliche
Wachstumsrate (mit Sparplan die geldgewichtete Rendite, siehe
[Sparpläne](#sparpläne-dca)). *Max. Drawdown* ist der schlimmste
zwischenzeitliche Verlust vom letzten Höchststand, *Längster DD* die
längste Durststrecke bis zum nächsten Höchststand. *SPB genutzt*
zeigt, wie viel Sparer-Pauschbetrag angerechnet wurde und wie viel Steuer
das gespart hat.

Der Knick am letzten Tag im Dashboard ist kein Kurseinbruch. Es ist die
Steuer, die mit `liquidate` beim Verkauf aller Positionen fällig wird. Die
Option ist sinnvoll, wenn Sie wissen wollen, was nach Auflösung des Depots
*netto* übrig bleibt. Ohne sie zeigt der Endwert den Depotwert inklusive
noch nicht versteuerter Gewinne.

## Grundkonzepte

### Eingabedaten

SimLev ist eine reine Backtest-Engine. Sie verarbeitet jede Preisreihe genau
so, wie sie übergeben wird. **Hebel, Dividenden und Finanzierungskosten
werden nicht intern berechnet**, sondern müssen in der Preisreihe bereits
enthalten sein. Für einen gehebelten ETF übergeben Sie also die tatsächliche
(oder selbst nachgebildete) Kursreihe des gehebelten Produkts, für
thesaurierende ETFs einfach den Kurs.

Erwartet wird eine Tabelle mit

- einer Spalte **`date`**,
- **je einer Preisspalte pro Asset**, deren Name exakt dem Asset-Namen in
  der Strategie entspricht,
- optional weiteren Spalten: Kauf- und Verkaufssignale (logisch), ein
  täglicher Basiszins für die Vorabpauschale, ein risikoloser Zins oder eine
  Trigger-Spalte für ereignisbasiertes Rebalancing.

| | R | Python | Julia |
|---|---|---|---|
| Tabelle | `data.frame` | `pandas.DataFrame` oder `dict` aus Spalten | NamedTuple von Vektoren, `Dict`, `DataFrame` oder jede Tabelle mit `propertynames`/`getproperty` |
| `date` | `Date` oder Text `"JJJJ-MM-TT"` | `datetime64`, `datetime.date` oder Text | `Date`, `DateTime`, Text oder Tage seit 1970-01-01 |
| Fehlende Werte | `NA` | `NaN` (oder `simlev.NA`) | `missing` (oder `SimLev.NA`) |

**Fehlende Kalendertage** wie Wochenenden und Feiertage füllt SimLev
automatisch mit dem letzten bekannten Kurs auf (*Last Observation Carried
Forward*, LOCF). Diese Tage werden im Ergebnis unter `filled` markiert und
aus allen renditebasierten Kennzahlen (Volatilität, Sharpe, Sortino,
Schiefe, Kurtosis) herausgerechnet. Künstliche Null-Rendite-Tage verzerren
die Statistik so nicht. Fällt ein geplantes Ereignis (Sparrate,
Rebalancing, Liquidation) auf einen aufgefüllten Tag, wird es auf den
nächsten echten Handelstag verschoben. Würde es dadurch in den Folgemonat
rutschen, wird es auf den vorherigen Handelstag vorgezogen.

Zusätzlich prüft SimLev die Daten: Unsortierte
Daten werden mit Hinweis sortiert, einzelne fehlende Kurse (`NA`) innerhalb einer Reihe per LOCF
gefüllt, führende fehlende Kurse wirken wie ein späterer `asset_start`, und
doppelte Datumswerte oder Kurse ≤ 0 führen zu einer Fehlermeldung.

### Die Prozent-Konvention

Alle Raten und Schwellen werden **in Prozent** angegeben, nicht als
Dezimalzahl. Das ist die häufigste Fehlerquelle beim Einstieg:

| Argument | Beispiel | Bedeutung |
|---|---|---|
| `tax_rate` | `26.375` | 25 % Abgeltungsteuer + 5,5 % Solidaritätszuschlag darauf |
| `asset_spread` | `0.1` | 0,1 % voller Bid-Ask-Spread (je Kauf/Verkauf die Hälfte) |
| `asset_bonus` | `30` | 30 % Teilfreistellung |
| `balance_thresh` | `5` | Rebalancing erst ab 5 % Gewichtsabweichung |
| `base_rate` | `2.55` | 2,55 % Basiszins für die Vorabpauschale |
| `risk_free` | `2` | 2 % risikoloser Zins p. a. |
| `marginal_tax_rate` | `42` | 42 % persönlicher Grenzsteuersatz |

Einzige Ausnahme sind die Zielgewichte `asset_share`. Jedes liegt zwischen
0 (ausschließlich) und 1, und zusammen müssen sie sich auf 1 summieren.
Sonst bricht `simulation()` mit einer Fehlermeldung ab.

### Assets und Strategien

Jedes Asset wird mit `asset_config()` beschrieben. Mehrere Assets fasst
`create_strategy()` zu einer Strategie zusammen. Beide Funktionen prüfen
ihre Eingaben sofort. Tippfehler oder unzulässige Werte fallen so auf,
bevor eine Simulation startet.

<details>
<summary><b>R</b></summary>

``` r
strategy <- create_strategy(
  WORLD = asset_config("etf", action_type = "bnh", asset_share = 0.6,
                       asset_spread = 0.10, asset_bonus = 30),
  EM    = asset_config("etf", action_type = "bnh", asset_share = 0.2,
                       asset_spread = 0.20, asset_bonus = 30),
  GOLD  = asset_config("etc", action_type = "bnh", asset_share = 0.2,
                       deliverable = TRUE)
)

validate_strategy(strategy, data)   # prüft zusätzlich, ob alle Spalten in data existieren
```

</details>

<details>
<summary><b>Python</b></summary>

``` python
strategy = simlev.create_strategy(
    WORLD=simlev.asset_config("etf", action_type="bnh", asset_share=0.6, asset_spread=0.10, asset_bonus=30),
    EM=simlev.asset_config("etf", action_type="bnh", asset_share=0.2, asset_spread=0.20, asset_bonus=30),
    GOLD=simlev.asset_config("etc", action_type="bnh", asset_share=0.2, deliverable=True),
)

simlev.validate_strategy(strategy, data)   # prüft zusätzlich, ob alle Spalten in data existieren
```

</details>

<details>
<summary><b>Julia</b></summary>

Die ersten fünf Argumente von `asset_config` (`asset_class`, `action_type`,
`asset_share`, `asset_spread`, `asset_bonus`) dürfen wie in R positionell
oder als Schlüsselwort übergeben werden.

``` julia
strategy = create_strategy(
    WORLD = asset_config("etf", "bnh", 0.6, 0.10, 30),
    EM    = asset_config("etf", "bnh", 0.2, 0.20, 30),
    GOLD  = asset_config("etc"; asset_share = 0.2, deliverable = true),
)

validate_strategy(strategy, data)   # prüft zusätzlich, ob alle Spalten in data existieren
```

</details>

Die **Assetklasse** bestimmt automatisch, nach welchen Regeln ein Asset
besteuert wird. Wollen Sie davon abweichen, setzen Sie `tax_regime`
explizit.

| `asset_class` | `deliverable` | Abgeleitetes Steuerregime | Typisches Beispiel |
|---|---|---|---|
| `"etf"` | – | `investment_fund` (InvStG: Teilfreistellung, Vorabpauschale) | Aktien- oder Renten-ETF |
| `"etn"`, `"etc"` | nein | `capital_gains` (§ 20 EStG, Abgeltungsteuer) | ETC ohne Lieferanspruch |
| `"etn"`, `"etc"` | ja | `private_sale` (§ 23 EStG, steuerfrei nach einem Jahr) | Physisch hinterlegtes Gold mit Lieferanspruch |
| `"certificate"` | – | `capital_gains` | Zertifikat, Hebelprodukt als Schuldverschreibung |

Bestehende Strategien verändern Sie mit `add_asset()`, `update_asset()` und
`remove_asset()`, die jeweils eine neue Strategie zurückgeben. Ältere,
als einfache Listen definierte Strategien akzeptiert `simulation()` direkt;
die veralteten Klassen `"etn_standard"` und `"etn_deliverable"` setzt
`asset_config()` mit einer Warnung in `"etn"` mit `deliverable` um.

### Buy-and-Hold und Signalstrategien

Mit `action_type = "bnh"` wird ein Asset am ersten Tag gekauft und
gehalten. Käufe und Verkäufe entstehen danach nur noch durch Sparraten,
Rebalancing oder Liquidation.

**Gestaffelte Starts:** Mit `asset_start` in `asset_config()` wird ein Asset
erst ab einem Datum handelbar. Bis dahin liegt das Kapital in den bereits
handelbaren Assets. Am Starttag wird auch ohne `balance_mode` auf
die Zielgewichte umgeschichtet, damit das neue Asset Mittel erhält; beginnt
eine Kursreihe mit fehlenden Werten, gilt ihr erster Kurs als `asset_start`,
und ein `asset_start` nach dem letzten Datentag ist ein Fehler.

Mit `action_type = "signal"` steigt das Asset ein und aus, wann immer Ihre
Signalspalten es vorgeben. Die Signale berechnen Sie vorab selbst; SimLev
macht keine Annahmen über Ihre Handelsregel. Ein klassisches Beispiel ist
der Kreuzungspunkt zweier gleitender Durchschnitte. In R berechnet sie hier
bequem das Paket `TTR` (`TTR::SMA()`); es ist keine Abhängigkeit von
SimLev und wird bei Bedarf separat installiert (`install.packages("TTR")`):

<details>
<summary><b>R</b></summary>

``` r
data$sma50  <- TTR::SMA(data$WORLD, n = 50)
data$sma200 <- TTR::SMA(data$WORLD, n = 200)
data$buy    <- data$sma50 > data$sma200
data$sell   <- data$sma50 < data$sma200

strategy <- create_strategy(
  WORLD = asset_config("etf", action_type = "signal",
                       asset_share = 1, asset_spread = 0.1, asset_bonus = 30,
                       signal_buy = "buy", signal_sell = "sell")
)
```

</details>

<details>
<summary><b>Python</b></summary>

``` python
sma50 = data["WORLD"].rolling(50).mean()
sma200 = data["WORLD"].rolling(200).mean()
data["buy"] = (sma50 > sma200).fillna(False)
data["sell"] = (sma50 < sma200).fillna(False)

strategy = simlev.create_strategy(
    WORLD=simlev.asset_config("etf", action_type="signal", asset_share=1, asset_spread=0.1, asset_bonus=30,
                              signal_buy="buy", signal_sell="sell"),
)
```

</details>

<details>
<summary><b>Julia</b></summary>

``` julia
sma(x, k) = [i < k ? NaN : sum(@view x[i-k+1:i]) / k for i in eachindex(x)]
s50, s200 = sma(data.WORLD, 50), sma(data.WORLD, 200)
data = merge(data, (buy = s50 .> s200, sell = s50 .< s200))     # NaN-Vergleiche ergeben false

strategy = create_strategy(
    WORLD = asset_config("etf", "signal", 1, 0.1, 30; signal_buy = "buy", signal_sell = "sell"))
```

</details>

Solange ein Signal-Asset nicht investiert ist, hält es sein Zielgewicht als
eigene Cash-Reserve. Beim Rebalancing wird diese Reserve wie eine Position
behandelt. Das Portfolio bleibt also auch dann im gewünschten Verhältnis,
wenn ein Teil gerade „an der Seitenlinie“ steht.

### Sparpläne (DCA)

Ein Sparplan (*Dollar-Cost Averaging*) investiert regelmäßig einen festen
Betrag zusätzlich zum Startkapital. Im Beispiel sind es 250 EUR pro Monat:

<details>
<summary><b>R</b></summary>

``` r
result_dca <- simulation(
  data, strategy,
  start_value = 10000,
  dca_mode = TRUE, dca_value = 250, dca_span = 1, dca_unit = "month",
  balance_dca = TRUE,       # Sparrate füllt zuerst untergewichtete Assets auf
  balance_mode = TRUE, balance_span = 1, balance_unit = "year",
  tax_mode = "person", tax_rate = 26.375,
  liquidate = TRUE
)
```

</details>

<details>
<summary><b>Python</b></summary>

``` python
result_dca = simlev.simulation(
    data, strategy,
    start_value=10000,
    dca_mode=True, dca_value=250, dca_span=1, dca_unit="month",
    balance_dca=True,       # Sparrate füllt zuerst untergewichtete Assets auf
    balance_mode=True, balance_span=1, balance_unit="year",
    tax_mode="person", tax_rate=26.375,
    liquidate=True,
)
```

</details>

<details>
<summary><b>Julia</b></summary>

``` julia
result_dca = simulation(data, strategy;
    start_value = 10000,
    dca_mode = true, dca_value = 250, dca_span = 1, dca_unit = "month",
    balance_dca = true,                       # Sparrate füllt zuerst untergewichtete Assets auf
    balance_mode = true, balance_span = 1, balance_unit = "year",
    tax_mode = "person", tax_rate = 26.375,
    liquidate = true)
```

</details>

Ohne `balance_dca` (Standard) wird jede Rate fest nach den Zielgewichten
aufgeteilt. Mit `balance_dca` wirkt sie wie ein kleines Rebalancing: Sie
fließt zuerst in die Assets, die gerade unter ihrem Zielgewicht liegen. Das
spart Verkäufe und damit Steuern, weil das Depot über frisches Geld statt
über Umschichtungen ins Gleichgewicht kommt.

**Wichtig bei Sparplänen: CAGR und TTWROR unterscheiden sich.** Mit
Einzahlungen ist die CAGR die **geldgewichtete** Rendite: der interne
Zinsfuß (XIRR) aus Startbetrag, datierten Sparraten und Endwert, gerechnet
mit Kalendertagen / 365,25. Sie beantwortet, wie sich *Ihr* eingezahltes
Geld verzinst hat, und hängt davon ab, wann wie viel eingezahlt wurde. Die
TTWROR (*True Time-Weighted Rate of Return*) rechnet die Einzahlungen heraus
und misst nur, wie gut die Strategie gearbeitet hat; sie ist die Zahl, die
Sie mit anderen Strategien oder mit einem Index vergleichen sollten. Auch
Drawdowns, Ulcer Index und Drawdown-Dauern misst SimLev mit Sparplan auf dem
zeitgewichteten Wertindex `twr_index`, und Calmar, Serenity und Martin Ratio
verwenden dann die TTWROR; `print()` kennzeichnet das („geldgewichtet,
XIRR“, „zeitgewichtet“) und zeigt zusätzlich die Summe der Einzahlungen.

Mit den Daten und der 70/30-Strategie aus dem R-Schnellstart und dem
Sparplan oben zahlen Sie in zehn Jahren 40.000 EUR ein (10.000 EUR Start
plus 120 Raten zu 250 EUR). Der Endwert nach Steuern beträgt 59.480,25 EUR,
die CAGR (geldgewichtet) 6,20 % und die TTWROR 6,09 %; der maximale
Drawdown (zeitgewichtet) liegt bei 20,92 %.

Python und Julia rechnen genauso: Mit denselben Kursen liefern sie
dieselben Werte, und mit den Daten des Python-Schnellstarts liefern alle
drei Fassungen für diesen Sparplan 70.424,36 EUR, eine CAGR
(geldgewichtet) von 8,79 % und eine TTWROR von 6,57 %.

### Rebalancing

Durch unterschiedliche Kursentwicklungen driften die Gewichte im Lauf der
Zeit auseinander. SimLev bietet drei Wege, sie wieder anzugleichen:
**kalenderbasiert** in festen Abständen, **mit Toleranzschwelle** an den
Kalenderterminen, aber nur wenn sich der Aufwand lohnt, und
**ereignisbasiert**, wenn eine von Ihnen definierte Bedingung eintritt.

<details>
<summary><b>R</b></summary>

``` r
# kalenderbasiert
simulation(data, strategy, balance_mode = TRUE, balance_span = 1, balance_unit = "quarter")

# mit Toleranzschwelle: nur handeln, wenn ein Gewicht > 5 % abweicht
simulation(data, strategy, balance_mode = TRUE, balance_span = 1, balance_unit = "year",
           balance_thresh = 5)

# relatives Band: Ziel 40 % darf zwischen 30 % und 50 % liegen
simulation(data, strategy, balance_mode = TRUE, balance_span = 1, balance_unit = "month",
           balance_thresh = 25, balance_thresh_type = "relative")

# ereignisbasiert; data$sigma_ewma enthält eine selbst berechnete Volatilitätsschätzung
data <- compute_rebal_trigger(data, type = "vol_band", threshold = 20, vol_col = "sigma_ewma")
simulation(data, strategy, event_col = "rebal_trigger",
           event_mode = "replace")   # oder "additional" zum Kalender
```

Kommentierte Vorlagen für eigene Trigger-Regeln finden Sie in
[`r/inst/examples/rebal_trigger_cookbook.R`](r/inst/examples/rebal_trigger_cookbook.R)
(im installierten Paket: `system.file("examples", "rebal_trigger_cookbook.R", package = "SimLev")`).

</details>

<details>
<summary><b>Python</b></summary>

``` python
# kalenderbasiert
simlev.simulation(data, strategy, balance_mode=True, balance_span=1, balance_unit="quarter")

# mit Toleranzschwelle: nur handeln, wenn ein Gewicht > 5 % abweicht
simlev.simulation(data, strategy, balance_mode=True, balance_span=1, balance_unit="year",
                  balance_thresh=5)

# relatives Band: Ziel 40 % darf zwischen 30 % und 50 % liegen
simlev.simulation(data, strategy, balance_mode=True, balance_span=1, balance_unit="month",
                  balance_thresh=25, balance_thresh_type="relative")

# ereignisbasiert; data["sigma_ewma"] enthält eine selbst berechnete Volatilitätsschätzung
data = simlev.compute_rebal_trigger(data, type="vol_band", threshold=20, vol_col="sigma_ewma")
simlev.simulation(data, strategy, event_col="rebal_trigger",
                  event_mode="replace")   # oder "additional" zum Kalender
```

</details>

<details>
<summary><b>Julia</b></summary>

``` julia
# kalenderbasiert
simulation(data, strategy; balance_mode = true, balance_span = 1, balance_unit = "quarter")

# mit Toleranzschwelle: nur handeln, wenn ein Gewicht > 5 % abweicht
simulation(data, strategy; balance_mode = true, balance_span = 1, balance_unit = "year",
           balance_thresh = 5)

# relatives Band: Ziel 40 % darf zwischen 30 % und 50 % liegen
simulation(data, strategy; balance_mode = true, balance_span = 1, balance_unit = "month",
           balance_thresh = 25, balance_thresh_type = "relative")

# ereignisbasiert; data.sigma_ewma enthält eine selbst berechnete Volatilitätsschätzung
data = compute_rebal_trigger(data, "vol_band"; threshold = 20, vol_col = "sigma_ewma")
simulation(data, strategy; event_col = "rebal_trigger",
           event_mode = "replace")   # oder "additional" zum Kalender
```

</details>

`compute_rebal_trigger()` erzeugt eine logische Spalte, die Sie über
`event_col` an die Simulation übergeben. Gerade bei gehebelten Strategien
ist das oft sinnvoller als ein fester Kalender, etwa wenn sich der
gewünschte Hebel oder die Marktvolatilität spürbar verändert hat.

| Trigger-Typ | Löst aus, wenn ... |
|---|---|
| `"abs_leverage"` | der Ziel-Hebel absolut um mehr als die Schwelle vom zuletzt umgesetzten Hebel abweicht (`threshold = 10` ⇒ 0,10 Hebelpunkte) |
| `"rel_leverage"` | der Ziel-Hebel relativ um mehr als die Schwelle abweicht (`10` ⇒ 10 %) |
| `"vol_band"` | die Volatilität relativ zum Wert beim letzten Rebalancing um mehr als die Schwelle abweicht |
| `"combined"` | mindestens einer von mehreren Sub-Triggern auslöst (ODER-Verknüpfung) |

Verglichen wird immer mit dem Stand beim *letzten tatsächlichen*
Rebalancing, nicht mit dem Vortag. So lösen auch viele kleine Bewegungen
aus, die sich aufsummieren. Optional legt `event_weight` die Zielgewichte
an Event-Tagen aus Datenspalten fest.

### Besteuerung

Über `tax_mode` wählen Sie eines von drei Modellen:

| `tax_mode` | Bedeutung |
|---|---|
| `"none"` | Keine Steuern, also die reine Brutto-Performance |
| `"person"` | Besteuerung eines deutschen Privatanlegers mit vollständiger FIFO-Lotverwaltung |
| `"funds"` | Vereinfachte Fondshülle: laufende Kosten (`funds_fee`, wie eine TER) und eine Performancegebühr mit High-Watermark (`bonus_fee`); bei Liquidation Steuer auf den Gesamtgewinn |

Die folgende Beschreibung gibt den Stand der aktuellen R-Engine 0.5.0
wieder; Python 0.5.0 und Julia 0.5.0 rechnen bitgleich genauso. Was sich
gegenüber dem Stand 54b5b4f geändert hat, steht in
[`r/NEWS.md`](r/NEWS.md).

Im Modus `"person"` bildet SimLev unter anderem folgende Regeln ab:

- **Teilfreistellung** (§ 20 InvStG): Bei Aktien-ETFs bleiben 30 %, bei
  Mischfonds 15 % der Erträge steuerfrei. Den Satz geben Sie je Asset über
  `asset_bonus` an.
- **Vorabpauschale** (§ 18 InvStG): Für thesaurierende Fonds wird jährlich
  ein fiktiver Mindestertrag besteuert. Je am 31.12. gehaltenem Lot beträgt
  er 70 % des Basiszinses auf den Kurs zu Jahresbeginn, höchstens aber den
  Wertzuwachs im Kalenderjahr (Kurs am 31.12. minus Kurs zu Jahresbeginn).
  Beides gilt auch für Anteile, die erst im Lauf des Jahres gekauft wurden;
  sie tragen danach nur (13 − Erwerbsmonat) / 12 dieses Betrags. Der
  Basiszins kommt fest aus `base_rate` oder, mit `base_rate_flex`, aus einer
  Datenspalte (`base_rate_data`); maßgeblich ist der Wert vom ersten
  Handelstag des Jahres. Die Vorabpauschale gilt am ersten Handelstag des
  Folgejahres als zugeflossen und wird dort vor den Trades des Tages mit dem
  Sparer-Pauschbetrag und dem Verlusttopf *des Folgejahres* abgerechnet;
  endet die Simulation vorher, am letzten Tag. Reicht das Cash nicht,
  werden Anteile verkauft (bei `fractions = FALSE` auf ganze Stück
  aufgerundet). Bereits versteuerte Vorabpauschalen mindern später den
  Veräußerungsgewinn (§ 19 InvStG).
- **Sparer-Pauschbetrag**: Jährlich bleiben 1.000 EUR Kapitalerträge
  steuerfrei, einstellbar über `sparer_pauschbetrag` (für Ehepaare z. B.
  `2000`).
- **Verlustverrechnung**: Verluste werden mit Gewinnen desselben Topfes
  verrechnet und bei Bedarf vorgetragen; der Verlusttopf wird vor dem
  Sparer-Pauschbetrag verrechnet. Der allgemeine Topf nach § 20 EStG und der
  Topf für private Veräußerungsgeschäfte nach § 23 EStG bleiben strikt
  getrennt. Entsteht nach Nutzung des Pauschbetrags ein Verlust, wird zum
  Jahreswechsel wie bei der unterjährigen Verlustverrechnung einer Bank
  zuerst bereits gezahlte Steuer erstattet, dann der genutzte
  Pauschbetrag wieder freigegeben; erst der Rest geht in den Verlusttopf.
  Die Erstattung des letzten Jahresabschlusses ist im Endwert enthalten.
- **Private Veräußerungsgeschäfte** (§ 23 EStG): Für Assets mit
  Lieferanspruch (z. B. physisches Gold) sind Gewinne nach einem Jahr
  Haltedauer steuerfrei (bei Kauf am 29.02. endet die Frist am 28.02. des
  Folgejahres). Innerhalb der Frist gilt der persönliche Steuersatz,
  entweder als fester Satz `marginal_tax_rate` oder, mit `taxable_income`,
  exakt nach dem Einkommensteuertarif (siehe unten), und eine Freigrenze
  von 1.000 EUR (`private_sale_threshold`). Sie wird auf den Jahressaldo *vor* dem
  Verlustvortrag angewendet: Erreicht der Saldo die Grenze (genau 1.000 EUR
  eingeschlossen), ist der *gesamte* Saldo abzüglich Verlustvortrag
  steuerpflichtig, darunter ist er steuerfrei und der Vortrag bleibt
  unverändert. Die Steuer wird vom Depot bezahlt, am Abrechnungstag der
  Vorabpauschale (erster Handelstag des Folgejahres), sonst am letzten Tag,
  aus dem Cash oder per Zwangsverkauf.
- **Günstigerprüfung** (§ 32d Abs. 6 EStG): Mit `use_guenstigerpruefung`
  wird der persönliche Steuersatz angewendet, wenn die Belastung
  einschließlich Zuschlagsteuern niedriger ist als die Abgeltungsteuer.
  Ohne `taxable_income` wird `marginal_tax_rate` × (1 + Soli-Satz +
  Kirchensteuersatz) mit dem effektiven Abgeltungsteuersatz verglichen
  (Soli auf die Einkommensteuer nur mit `include_soli_on_income_tax =
  TRUE`) und der günstigere Satz durchgehend verwendet. Mit
  `taxable_income` wird unterjährig die Abgeltungsteuer einbehalten und im
  Jahresabschluss mit der Tarifbelastung verglichen; die Differenz wird
  erstattet (siehe unten).
- **Umschichtungen**: Beim Rebalancing schätzt SimLev die Steuer auf den
  Verkauf mit freiem Sparer-Pauschbetrag, Verlusttopf, Anrechnung der
  Vorabpauschale und dem Satz der Günstigerprüfung und berücksichtigt das
  beim Asset liegende Cash. So wird nicht zu viel verkauft und am selben
  Tag zurückgekauft.

Zur Kirchensteuer (`church_tax`) siehe
[Gebühren, Kirchensteuer und Freibetrag](#gebühren-kirchensteuer-und-freibetrag).

**Einkommensteuertarif.** Mit `taxable_income`, dem zu
versteuernden Einkommen *ohne* die Kapitalerträge und § 23-Gewinne der
Simulation in EUR je Kalenderjahr (eine Zahl für alle Jahre, ein nach
Jahren benannter Vektor oder `data.frame(year, taxable_income)`), rechnet
`simulation()` bei `tax_mode = "person"` mit dem Einkommensteuertarif nach
§ 32a Abs. 1 EStG und dem Solidaritätszuschlag nach §§ 3, 4 SolZG
(Freigrenze 20.350 EUR, Milderungszone 11,9 %). Mitgeliefert ist die
Rechtslage ab VZ 2026 für die Einzelveranlagung (Grundtarif, kein
Splitting) in der Datei `inst/extdata/steuertarif.csv` (Python:
`simlev/data/steuertarif.csv`, Julia: `julia/data/steuertarif.csv`); ein anderer Tarif
wird über `tax_tariff = "<Datei>"` bzw. `read_tax_tariff()` eingelesen.
Dann gilt:

- Die § 23-Steuer ist der Zuwachs von Einkommensteuer, Soli und
  Kirchensteuer durch den steuerpflichtigen § 23-Gewinn.
- Die Günstigerprüfung vergleicht im Jahresabschluss die
  Gesamtbelastung durch die Simulation mit und ohne tarifliche Besteuerung
  der per Saldo besteuerten Kapitalerträge (einschließlich
  Zuschlagsteuern und der Wirkung der Kirchensteuer-Sonderausgaben); die
  Abrechnung (`settlement`) wird am Abrechnungstag im Folgejahr
  nachgezahlt oder erstattet.
- Die Kirchensteuer ist Sonderausgabe im Jahr ihrer Zahlung (§ 10 Abs. 1
  Nr. 4, § 11 EStG): Je Jahr gibt es einen saldierten
  Kirchensteuer-Bescheid, der im Folgejahr gezahlt bzw. erstattet wird;
  Erstattungen werden mit den im selben Jahr gezahlten Kirchensteuern
  verrechnet, ein Überhang wird dem Einkommen hinzugerechnet (§ 10 Abs. 4b
  Satz 2 und 3 EStG). Die Kirchensteuer auf die Abgeltungsteuer ist nicht
  abziehbar; ist die Günstigerprüfung günstiger, mindert die auf die
  Kapitalerträge einbehaltene Kirchensteuer das zu versteuernde Einkommen
  des Zuflussjahres (nach der Darstellung der Rechtslage in der
  Fachliteratur, nicht nach einem Urteil). Die Kirchensteuer auf die
  § 23-Steuer wirkt erst im Zahlungsjahr.
- `marginal_tax_rate`, `include_soli_on_income_tax` und
  `soli_rate_income_tax` wirken dann nicht (Warnung, wenn angegeben).
  `tax_report$tariff_years` zeigt die Veranlagung je Jahr.

Vereinfachungen: Der Tarif gilt für alle Simulationsjahre, die
Kirchensteuer wird nicht gerundet und ohne Kinderfreibeträge (§ 51a EStG)
berechnet, ein Verlustrücktrag kommt nicht vor (Einzelheiten in
`?simulation`, Abschnitt „Einkommensteuertarif“). Ohne `taxable_income`
rechnet die Engine wie oben mit `marginal_tax_rate`.

<details>
<summary><b>R</b>: Beispiel mit Einkommensteuertarif</summary>

``` r
set.seed(42)
n <- 365 * 10
data <- data.frame(
  date  = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n),
  WORLD = 100 * cumprod(1 + rnorm(n, 4e-4, 0.010)),
  GOLD  =  50 * cumprod(1 + rnorm(n, 3e-4, 0.012))
)
strategy <- create_strategy(
  WORLD = asset_config("etf", action_type = "bnh", asset_share = 0.6, asset_spread = 0.1, asset_bonus = 30),
  GOLD  = asset_config("etc", action_type = "bnh", asset_share = 0.4, asset_spread = 0.2, deliverable = TRUE)
)
res <- simulation(data, strategy, start_value = 100000,
  balance_mode = TRUE, balance_span = 1, balance_unit = "month", balance_thresh = 3,
  tax_mode = "person", base_rate = 2.55, liquidate = TRUE, church_tax = 9,
  use_guenstigerpruefung = TRUE, taxable_income = 14000)

ty <- res$tax_report$tariff_years
round(ty[ty$year %in% c(2019, 2020, 2024),
         c("year", "capital_income", "abgeltung_burden", "burden_with_gp",
               "church_tax_net_deduction", "gain_p23", "tax_p23", "settlement")], 2)
res$tax_report$total_taxes_paid
```

```
   year capital_income abgeltung_burden burden_with_gp church_tax_net_deduction
5  2019        2216.13           620.41         449.08                    48.77
6  2020           0.00             0.00             NA                   -11.69
10 2024       35793.85         10020.53       11581.25                   -14.59
   gain_p23 tax_p23 settlement
5      0.00    0.00    -171.33
6      0.00    0.00       2.18
10  1922.33  394.58     396.76
[1] 12833.82
```

Bei 14.000 EUR übrigem Einkommen ist der Tarif in den Jahren mit
kleineren Kapitalerträgen günstiger als die Abgeltungsteuer mit
Kirchensteuer: 2019 beträgt die Gesamtbelastung mit Günstigerprüfung
449,08 EUR statt 620,41 EUR, die Differenz wird im Folgejahr erstattet
(`settlement` −171,33 EUR). Die im Jahr 2019 auf die Kapitalerträge
einbehaltene Kirchensteuer (48,77 EUR) ist dabei Sonderausgabe des Jahres
2019; die Erstattung von Kirchensteuer aus dem Bescheid 2019 (11,69 EUR)
wird 2020 dem Einkommen hinzugerechnet, was 2,18 EUR nachkostet. Im
Liquidationsjahr 2024 mit 35.793,85 EUR Kapitalerträgen ist die
Abgeltungsteuer günstiger; der § 23-Gewinn des Goldes (1.922,33 EUR)
kostet 394,58 EUR. Insgesamt zahlt das Depot 12.833,82 EUR Steuern; ohne
Günstigerprüfung (sonst gleicher Aufruf) wären es 13.616,07 EUR. Python
und Julia liefern mit denselben Kursdaten (erzeugt wie unter „Warum
unterscheiden sich die Zahlen?“ beschrieben) dieselbe Tabelle und dieselben
12.833,82 EUR; in Julia steht sie unter `res.tax_report.tariff_years`.

</details>

Im Modus `"funds"` belastet SimLev die Fondskosten `funds_fee` linear je
Kalendertag (ein volles Kalenderjahr kostet genau `funds_fee` Prozent), am
31.12. und anteilig am letzten Tag; fehlendes Cash wird per Teilverkauf
ohne Ordergebühr und Spread beschafft. Die High-Watermark der
Performancegebühr `bonus_fee` wird um Einzahlungen erhöht und nach Abzug der
Gebühren fortgeschrieben. Bei Liquidation wird der Gesamtgewinn (Endwert
minus Startkapital minus Einzahlungen) versteuert. Werden `funds_fee` oder
`bonus_fee` bei einem anderen `tax_mode` angegeben, wirken sie nicht;
SimLev warnt dann. (Bis zum Stand 54b5b4f wurden die Fondskosten bei voll
investiertem Depot nicht belastet: zwei Jahre ohne Kursänderung und ohne
Spread mit `funds_fee = 1` ergeben jetzt 9.801 EUR, damals 10.000 EUR aus
10.000 EUR.)

**Modellphilosophie:** SimLev projiziert die *heutige* Rechtslage in die
Vergangenheit, also aktuellen Pauschbetrag, aktuelle
Teilfreistellungssätze und aktuelle Freigrenzen. Ein Backtest beantwortet
damit die Frage *„Wie hätte meine Strategie abgeschnitten, wenn ich damals
zu den heutigen Konditionen investiert hätte?“*. Er berechnet nicht, welche
Steuer damals tatsächlich angefallen wäre. So bleiben Zeiträume vor und
nach Steuerreformen direkt vergleichbar.

### Splits bei gehebelten Produkten

Manche Hebelprodukte führen Splits oder Zusammenlegungen durch, wenn ihr
Kurs eine bestimmte Grenze über- oder unterschreitet. Mit `split_mode` und
`split_thresh` (untere und obere Grenze, in R als `c(20, 400)`, in Python
als `(20, 400)`, in Julia als `[20, 400]`) bildet SimLev das nach: Über der
oberen Grenze wird gesplittet, unter der unteren zusammengelegt. Übergeben
Sie dafür die Kursreihe *ohne* Split-Bereinigung. Für die Besteuerung
ändert sich nichts. Die Anschaffungskosten aller FIFO-Lots werden im
Split-Verhältnis angepasst, Kaufdaten und damit Haltedauern bleiben
erhalten.

## Erweiterungen in R, Python und Julia

Die folgenden Funktionen gibt es im R-Paket und mit gleichen Namen,
Argumenten und Ergebnissen in der Python- und der Julia-Fassung. Die
Beispiele sind in R geschrieben. In Python und Julia gelten die
Schreibweisen aus
[Unterschiede zwischen den Sprachen](#unterschiede-zwischen-den-sprachen):
in Python `simlev.bootstrap_study(...)` und `{"us": "us_ret"}` statt
`c(us = "us_ret")`, in Julia `bootstrap_study(df, cfg, "stationary"; n = …)`
mit Schlüsselwörtern nach dem Semikolon, `(us = "us_ret",)` und ein
`RFrame` als Datentabelle; Bedingungen stehen in beiden Ports als Text.
Je zwei ausgeführte Beispiele stehen in
[`python/README.md`](python/README.md#erweiterungen) und
[`julia/README.md`](julia/README.md#erweiterungen). Wo R mit `cores > 1`
parallel rechnet, rechnen Python und Julia sequenziell, aber mit derselben
Zufallssemantik und damit denselben Ergebnissen.

Fast alle Funktionen rechnen um die Engine herum; die wenigen neuen
Optionen von `simulation()` (relative Rebalancing-Bänder, Ordergebühren,
Kirchensteuer, `harvest_mode`) sind standardmäßig aus. Die
Golden-Master-Fälle blieben dadurch bitgleich; erst die Fehlerkorrekturen
und steuerrechtlichen Anpassungen nach dem Stand 54b5b4f haben alle 105
Fälle verändert, mindestens in der Druckausgabe (siehe
[`r/NEWS.md`](r/NEWS.md)). Ausführliche Beispiele, die die Projektskripte
nachbilden, stehen in
[`r/inst/examples/backcast_bootstrap_withdrawal_examples.md`](r/inst/examples/backcast_bootstrap_withdrawal_examples.md).
Was sich in welcher Version geändert hat, steht in [`r/NEWS.md`](r/NEWS.md).

### Arbeitsweise und Glossar

Alle Funktionen arbeiten mit demselben Datenformat: einem `data.frame`
(Python: `pandas.DataFrame`, Julia: `RFrame`) mit der Spalte `date` (Klasse `Date`) und je
Anlage einer Spalte mit dem
**Kursniveau** (keine Renditen). Daraus ergeben sich vier Wege durch das
Paket:

| Schritt | Funktionen |
|---|---|
| **Eigene Daten einlesen** (z. B. `read.csv()` + `as.Date()`) | `check_series()`, `align_series()`, `align_macro()`, `convert_currency()`, `total_return_index()`, `deflate()`, `splice_series()`, `backcast_fit()`/`backcast()` |
| **Daten erzeugen** | `leveraged_series()`, `bond_index_from_yields()`, `money_market_index()`, `currency_hedged_index()`, `set_expected_return()`, `bootstrap()` + `bootstrap_data()`, `pooled_bootstrap()`, `copula_scenarios()` |
| **Simulieren** | `simulation()` mit `asset_config()`/`create_strategy()` oder `strategy_from_weights()` (Einkommensteuertarif: `read_tax_tariff()`); `tactical_simulation()`, `bootstrap_study()`, `param_search()`, `sensitivity_grid()` |
| **Fertige Simulationen weiterverarbeiten** (auch mit `saveRDS()` gespeichert und später geladen, in Julia mit `Serialization`) | `deep_analysis()`, `return_heatmap()`, `sharpe_test()`, `min_track_record()`, `result_index()`, `withdrawal_paths()`/`withdrawal_simulation()`; Studien und Suchen: `bootstrap_probability()`, `pbo()`, `deflated_sharpe()`, `reality_check()`, `sharpe_haircut()` |

Die Argumentnamen sind über die Versionen gewachsen und nicht überall
einheitlich. Für das ganze Paket gilt:

- **Prozent** (`5` = 5 %): Steuersätze, Spreads, Gebühren, TER, Zinsen,
  Inflation, Entnahmeraten, Zielvolatilitäten und Toleranzbänder.
- **Anteile** (`0.05` = 5 %): Gewichte (`asset_share`, `weights`,
  `lower`/`upper` der Optimierung, `base`, `min_exposure`/`max_exposure`)
  und Wahrscheinlichkeiten bzw. Quantile (`alpha`, `q`, `quantiles`,
  `prob`, `success`). Ausnahme: `stock_share` in `withdrawal_rule()` ist in
  Prozent.
- **Ergebnisse**: CAGR, Volatilität und Drawdown aus `simulation()`,
  `deep_analysis()` und `study_metrics()` sind Anteile; die Renditen in
  `tail_regression()`, `covar_analysis()` und den Szenario-Funktionen sind
  Prozent je Periode.
- **Wiederholungen** heißen `B` (Bootstrap in Tests und Abhängigkeiten),
  `n` (Pfade oder Szenarien) oder `n_sim` (`goal_optimize()`);
  **Blocklängen** `block` (in Perioden) oder `L`/`block_length` (in Zeilen
  bzw. bei `pooled_bootstrap()` in Perioden).
- **`frequency`** ist die Periodenlänge der Renditen, **`every`** der
  Rhythmus der Gewichts-Erzeuger, **`rebalance`** in
  `tactical_simulation()` der Handelsrhythmus (Text) und in
  `crisis_replay()` ein Schalter. In `simulation()` heißen die
  Rebalancing-Argumente `balance_*`.
- Das **Toleranzband** heißt `balance_thresh` (`simulation()`), `tolerance`
  (`tactical_simulation()`) und `bands` (`rebalancing_sensitivity()`);
  `band` bei den Signalen ist dagegen eine Hysterese.
- **`horizon`** zählt in `goal_optimize()` Perioden, in `signal_analysis()`
  Zeilen, in `lumpsum_vs_dca()` Jahre, in `backcast_fit()`
  Produktbeobachtungen (Renditehorizont); in `withdrawal_simulation()` ist es
  ein Objekt aus `horizon_model()` oder eine Zahl in Jahren.
  `withdrawal_rule()` hat kein `horizon`: Die Restjahre der Regeln ergeben
  sich aus der Zahl der Planjahre der Simulation.
- **`inflation`** ist je nach Funktion ein Spaltenname, eine Rate in
  Prozent p. a. oder ein Preisindex; bei Zusatzreihen eines Bootstraps legt
  **`aux_type`** in `bootstrap_config()` fest, ob die Reihe ein Niveau
  (`"level"`) oder eine Rate in Prozent p. a. (`"rate"`) ist, und damit,
  wie `keep_aux`, `withdrawal_paths()`, `withdrawal_simulation()` und
  `withdrawal_cohorts()` sie als Inflation lesen (`inflation_type` kann
  dann entfallen, widersprechende Angaben sind ein Fehler). Ohne Angabe
  gilt das bisherige Verhalten (als Inflation die Niveau-Variante). **`ppy`** (Perioden je Jahr) wird
  ohne Angabe meist aus den Daten geschätzt.
- **`asset_bonus`** ist die Teilfreistellung in Prozent.
- **`taxable_income`** (`simulation()`) ist das zu versteuernde Einkommen
  ohne die Erträge der Simulation in **EUR je Kalenderjahr**. In der
  Tarifdatei von `read_tax_tariff()` sind Zonengrenzen, Bezugswerte,
  Teiler und Konstanten in EUR; bei den linearen Zonen ist `b` der
  Grenzsteuersatz als **Anteil** (`0.42`), die Soli-Sätze stehen dagegen in
  **Prozent** (`5.5`, `11.9`).

Die Hilfeseite jeder Funktion nennt Einheit und Standard jedes Arguments;
die Übersicht steht in `?SimLev`.

### Backcast von Produkten

`backcast_fit()` passt ein Rückrechnungsmodell auf dem Zeitraum an, in dem
Produkt und Basisindex beide vorliegen; `backcast()` verlängert das Produkt
damit in die Vergangenheit und verkettet renditebasiert mit den echten
Kursen. Das Strukturmodell folgt der Methodik der MSCI Daily Leveraged/Short
Indizes plus Fondskosten:

```
r_t = beta·L·x_t + (1 − L)·Zins_t·T/360 − TER_t·T/365 − Spread·m(L)·T/360 − Drag·T/365
```

Gefittet werden wahlweise `drag` (Restabweichung p. a.), `spread` und
`beta`. Das Ziel ist die kumulierte Pfadabweichung (`"level"`), die tägliche
bzw. mehrtägige Renditeabweichung (`"return"`) oder beides (`"hybrid"`).
Die TER kann sich zu Stichtagen ändern, der Zins ist eine Datenspalte.
Ausgegeben werden Tracking Error, Tracking Difference, Korrelation und ein
Out-of-Sample-Test in Backcast-Richtung.

``` r
fit <- backcast_fit(data, product = "etf", index = "index_nr_eur",
                    ter = c("2010-02-24" = 0.35, "2023-10-10" = 0.50),
                    leverage = 2, rate = "estr")
bc  <- backcast(fit)          # date, value, return, model, product, source
```

### Bootstrap-Studien

`bootstrap_config()` beschreibt Indizes, daraus abgeleitete Hebelprodukte
und Zusatzreihen (Zins, Inflation), die aus derselben historischen Zeile
mitgezogen werden. `bootstrap()` erzeugt Pfade; `bootstrap_study()` erzeugt
Pfade, berechnet Signale, simuliert alle Strategien mit `simulation()` auf
denselben Pfaden und behält nur die Kennzahlen. Das läuft parallel und lässt
sich nach einem Abbruch fortsetzen; jeder Pfad hat einen eigenen
Zufallsstrom und ist unabhängig von der Kernzahl reproduzierbar.
`summary()` zeigt Verteilungen und den gepaarten Vergleich mit einem
Benchmark, `bootstrap_probability()` beliebige (gemeinsame)
Wahrscheinlichkeiten.

Das Argument `aux_type` sagt je Zusatzreihe, ob sie eine
Rate in Prozent pro Jahr ist (`"rate"`: Werte der gezogenen Zeilen
unverändert, z. B. ein Zins; als Inflation über die Kalendertage
aufgezinst) oder ein Niveau (`"level"`, z. B. ein Preisindex: wird über die
Verhältnisse der gezogenen Zeilen fortgeschrieben und springt so nicht an
Blockgrenzen). Eine ausdrückliche Angabe gilt in allen weiterverarbeitenden
Funktionen (`keep_aux` in `bootstrap_study()`, `withdrawal_paths()`,
`withdrawal_simulation()`, `withdrawal_cohorts()` mit Daten aus
`bootstrap_data()`); ohne Angabe bleibt die Reihe im Pfad unverändert und
gilt als Inflation wie bisher als Niveau. Für Strategien mit Sparplan weist die Studie `cagr`
geldgewichtet (XIRR) und `max_drawdown` zeitgewichtet aus, wie
`simulation()`.

``` r
cfg <- bootstrap_config(c(us = "us_ret", eu = "eu_ret"), regime_index = "us",
                        aux = c(rate = "eu_rate", cpi = "eu_cpi"),
                        aux_type = c(rate = "rate", cpi = "level"),
                        letfs = list(list(base = "eu", leverage = 2, finance = "rate", expense = 0.5)))
study <- bootstrap_study(hist, cfg, "stationary", n = 10000, params = list(L = 250),
                         strategies = list(bnh = strategy_bnh, sma = list(strategy = strategy_sma, signal = sma_signal)),
                         benchmark = "bnh", burn_in = 730, cores = 8, seed = 42,
                         keep_returns = "year")
summary(study)
```

Verfahren: `raw`, `block`, `circular`, `stationary`, `wild`, `regime`, `evt`,
`tails`, `reset`, `garch`, `gjr_garch`, `ms_garch`, `ms_ar_garch_m`,
`tvtp_ms_garch` (die MS-Verfahren benötigen das R-Paket `MSGARCH`; in
Python und Julia melden sie wie R ohne `MSGARCH`, dass das Paket fehlt), optional
mit ESS-gewichteter Gittersuche über Hyperparameter. `block_length()`
schätzt Blocklängen nach Politis & White (2004).

### Entnahmephase

Die Entnahmephase ist bewusst von `simulation()` getrennt. Sie rechnet auf
Periodenrenditen aus historischen Kohorten (`withdrawal_cohorts()`),
Bootstrap-Pfaden (`withdrawal_paths()`), einer Bootstrap-Studie mit
`keep_returns` oder einem **gespeicherten Ergebnis von `simulation()`**:

``` r
res <- simulation(data, strategy, start_value = 1e5)
saveRDS(res, "lauf.rds")

wd <- withdrawal_simulation(readRDS("lauf.rds"),
                            withdrawal_rule("guyton_klinger", rate = 5),
                            years = 30, inflation = 2, start_value = 1e6,
                            tax_mode = "person")
wd                       # Erfolgsquote, SWR/PWR, Konsum- und Vermögensquantile
plot(wd)
```

| Regel | Beschreibung |
|---|---|
| `constant` | 4-%-Regel (Bengen, Trinity): Anfangsrate, danach inflationsangepasst |
| `percent` | Fester Prozentsatz des aktuellen Depots |
| `vanguard` | Vanguard Dynamic Spending: Rate × Depot, real begrenzt auf +5 % / −2,5 % |
| `guyton_klinger` | Guyton-Klinger-Regeln: Inflationsstopp nach Verlustjahr, Kürzung/Erhöhung um 10 % an ±20-%-Leitplanken |
| `floor_ceiling` | Bengen 2001: Rate × Depot im Korridor −15 % / +20 % um die reale Erstentnahme |
| `clyatt` | 95-%-Regel: höchstens 5 % weniger als im Vorjahr |
| `ratchet` | Kitces: +10 %, wenn das reale Depot 150 % des Starts übersteigt |
| `endowment` | Yale/Tobin: Glättung zwischen Vorjahresentnahme und Rate × Depot |
| `one_over_n`, `vpw`, `abw` | Restlaufzeit-, Variable-Percentage- und Annuitäten-Entnahme |
| `cape` | Rate = a + b / CAPE |
| `sensible`, `hebeler` | Sensible Withdrawals, Hebeler Autopilot II |

Kennzahlen sind Erfolgs- und Kapitalerhaltquote, Perfect Withdrawal Rate
und sichere Entnahmerate, Konsumquantile, Sicherheitsäquivalent (CRRA) und
Steuern. `withdrawal_max_rate()` sucht die höchste Anfangsrate für eine
Ziel-Erfolgsquote. Die Besteuerung im schnellen Kern ist vereinfacht: ein
thesaurierender Fondsbestand mit Teilfreistellung, Verlusttopf,
Sparer-Pauschbetrag und Vorabpauschale.

Wird als `start_value` ein Ergebnis von `simulation()` übergeben, ist
dessen Endwert das Startvermögen (ein Endwert ≤ 0 ist ein Fehler). Wurde
die Ansparphase mit `tax_mode = "person"` gerechnet (Element `open_lots`)
und rechnet auch die Entnahmephase mit `tax_mode = "person"`, übernimmt
SimLev 0.5.0 ohne eigenes `cost_basis` die einzelnen Lots und verkauft bei jeder
Entnahme je Asset die ältesten Lots zuerst (FIFO, mit Anrechnung der
Vorabpauschale wie in der Engine). Nicht ausdrücklich angegebene Werte
werden aus dem Ergebnis übernommen: `asset_bonus` (gemeinsame
Teilfreistellung der gehaltenen Assets), `loss_carryforward` (allgemeiner
Verlusttopf), `sale_cost` (halber Spread), der im ersten Planjahr schon
verbrauchte Sparer-Pauschbetrag (`tax_report$next_year`) und
`vorabpauschale = FALSE`, wenn keine Fonds gehalten werden. Ein Hinweis
nennt die übernommenen Werte, das Ergebnis führt sie unter `adopted`.
Gewarnt wird bei Ordergebühren, uneinheitlicher Teilfreistellung oder
uneinheitlichem Spread und bei § 23-Assets, die die Entnahmephase nicht
getrennt besteuert. Kirchensteuer und Einkommensteuertarif der Ansparphase
werden nicht übernommen; die Entnahmephase rechnet mit dem festen Satz
`tax_rate` (weitere Grenzen in `?withdrawal_simulation`). Ohne Lots gilt
wie bisher: 100 %, wenn das Ergebnis nur noch Cash hält, sonst die
Näherung (Startwert + Einzahlungen) / Endwert mit Durchschnittskosten,
bei `tax_mode = "person"` mit Warnung.

### Vertiefte Analyse und Sensitivitäten

`deep_analysis()` wertet gespeicherte Ergebnisse von `simulation()` (einzeln
oder als benannte Liste) oder beliebige Kursreihen nachträglich aus, im
Umfang von Portfolio-Backtestern wie testfol.io. Grundlage ist der
zeitgewichtete Wertindex, Sparpläne verzerren die Renditen also nicht. Die
CAGR (TWR) von `deep_analysis()` entspricht der TTWROR von `simulation()`,
die MWRR mit Sparplan der `cagr` von `simulation()` (dieselbe XIRR-Rechnung).

``` r
da <- deep_analysis(list(Aktien = res_a, Mischung = res_b), benchmark = "Aktien", risk_free = 2)
da                    # Kennzahlen und Benchmark-Block
summary(da)           # zusätzlich Jahresrenditen und größte Drawdowns
plot(da)              # Wachstum, Drawdowns, rollierende CAGR, Jahresrenditen
plot(da, "monthly")   # Monatsrenditen als Heatmap
```

| Bereich | Kennzahlen |
|---|---|
| Rendite | Gesamtrendite, CAGR (TWR), MWRR (interner Zinsfuß), beste/schlechteste Tage, Monate, Jahre, positive Monate |
| Risiko | Volatilität, Sharpe, Sortino, Calmar, max./mittlerer Drawdown, Ulcer Index, UPI, längster Drawdown, Recovery Factor, VaR und CVaR (Tag und Monat, 1/5/10 %) |
| Benchmark | Alpha, Beta, Korrelation (gesamt, auf, ab), R², Up-/Down-Capture, Capture Spread, aktive Rendite, Tracking Error, Information Ratio, M², Treynor |
| Tabellen | Jahres- und Monatsrenditen, Saisonalität, größte Drawdowns mit Dauer und Erholung, rollierende CAGR, Volatilität, Sharpe, Drawdown und Beta, Korrelationsmatrizen |

Für Parameterstudien rufen `sensitivity_grid()` (beliebige
`simulation()`-Argumente im Raster), `rebalancing_sensitivity()` (Frequenz,
Versatz, absolute oder relative Bänder), `lumpsum_vs_dca()` (Einmalanlage
gegen gestreckten Einstieg über rollierende Starts, mit Gewinnquote, MLSA und
MLSD) und `leverage_sensitivity()` (Kennzahlen über den Hebel, optimaler
Hebel) die Engine wiederholt auf, wahlweise parallel. `leveraged_series()`
erzeugt eine täglich zurückgesetzte Hebelreihe aus einem Index (Hebel, TER,
Zins, Spread).

### Parametersuche und Überanpassung

`param_search()` wertet eine Strategie über einen Parameterraum aus: volles
Raster, Zufallssuche oder Latin Hypercube. Die Strategie beschreibt eine
`builder`-Funktion, die aus einem Parametersatz dieselbe Spezifikation
liefert wie ein Element von `bootstrap_study()`. Signal-Bausteine
(`signal_sma()`, `signal_ema()`, `signal_crossover()`, `signal_momentum()`,
`signal_drawdown()`, `signal_volatility()`, `signal_combine()`) erzeugen
Kauf- und Verkaufsspalten mit Parametern und optionaler Hysterese.

``` r
st <- create_strategy(LETF = asset_config("etf", "signal", signal_buy = "buy", signal_sell = "sell"))
ps <- param_search(data,
  builder = function(p) list(strategy = st, signal = function(df) signal_sma(df$INDEX, p$n, p$band)),
  space = param_space(n = param_range(50, 400, n = 8, integer = TRUE, log = TRUE), band = c(0, 1, 2, 3)),
  burn_in = 400, objective = "sharpe", cores = 4)
summary(ps)           # beste Punkte und bestes Plateau
plot(ps)              # Heatmap der Zielgröße
pbo(ps)               # Probability of Backtest Overfitting (CSCV)
deflated_sharpe(ps)   # Sharpe Ratio nach Mehrfachtest-Korrektur
walk_forward(ps, train = 5, test = 1)
param_bootstrap(ps, hist, cfg, top = 5, method = "stationary", n = 500)
```

Eine einzelne Spitze im Raster ist oft Zufall. `plateau()` bewertet jeden
Punkt mit seinen Nachbarn; `pbo()` misst über alle Aufteilungen der Historie
in zwei Hälften, wie oft der In-Sample-beste Punkt Out-of-Sample unter dem
Median landet (Bailey, Borwein, López de Prado & Zhu 2017);
`deflated_sharpe()` vergleicht die beste Sharpe Ratio mit dem Maximum, das
man aus gleich vielen wertlosen Versuchen erwarten würde, mit einer
effektiven Versuchsanzahl aus der mittleren Korrelation der Punkte (Bailey &
López de Prado 2014); `walk_forward()` wählt in rollierenden
Trainingsfenstern und verkettet die folgenden Testfenster.

### Daten und Portfolios aufbereiten

``` r
dat <- align_series(us = msci_usd, fx = eurusd, fund = etf_kurse)    # Kalendertage, LOCF
check_series(dat)                                                    # Lücken, Spikes, Splits, stehende Kurse
dat <- convert_currency(dat, "us", "fx")                             # USD-Index in EUR
dat <- align_macro(dat, hvpi, "inflation", lag = 45, transform = "yoy")   # erst ab Veröffentlichung
dat <- align_macro(dat, zinskurve, "spread", lag = 1)
lang <- splice_series(fund = etf_kurse, backcast = bc_df, proxy = msci_usd)
portfolio_template("permanent", map = c(stocks = "world", long_bonds = "bund_lang",
                                        cash = "geldmarkt", gold = "gold_eur"))
```

`align_series()` legt Quellen mit unterschiedlichen Börsenkalendern auf
einen gemeinsamen Kalender, `check_series()` meldet Auffälligkeiten,
`align_macro()` ordnet Monats- oder Quartalswerte erst ab dem Tag ihrer
Veröffentlichung zu (sonst stecken Zukunftsinformationen in Signalen und
bedingten Analysen), `total_return_index()` und `deflate()` rechnen Kurs- in
Total-Return- bzw. reale Reihen um, `splice_series()` verkettet Reihen
renditebasiert mit Vorrang der ersten, `strategy_from_weights()` und
`portfolio_template()` bauen Strategien aus Gewichten bzw. bekannten
Allokationen (60/40, Permanent, All Weather, Golden Butterfly, Three Fund,
HFEA, Aktien/Gold); ohne Vorlagennamen listet `portfolio_template()` alle
Vorlagen mit ihren Gewichten.

### Abhängigkeiten, Tail-Risiko und Drittvariablen

`dependence_analysis()` untersucht die Abhängigkeit zwischen Anlagen über die
Korrelation hinaus und fragt mit `conditions`, wie sie vom Zustand einer
Drittvariable abhängt, die der Nutzer übergibt, etwa Inflation, Leitzins oder
Zinsspread. Der Zustand geht verzögert ein: Die Rendite einer Woche gehört
zum Zustand, der am Ende der Vorwoche bekannt war.

``` r
dep <- dependence_analysis(dat, c("aktien", "anleihen", "gold"),
                           conditions = c("inflation", "spread"),
                           breaks = list(inflation = c(-Inf, 2, 4, Inf)), B = 999)
dep                  # Korrelationen, Tail-Koeffizienten, beste Copula, DCC, Regime-Vergleich
plot(dep, "conditional", pair = "aktien ~ anleihen", condition = "inflation")
tail_regression(dat, "aktien", c("inflation", "spread"))   # Quantile der Rendite
covar_analysis(dat, system = "portfolio", assets = c("aktien", "anleihen"), state = "spread")
validate_dependence(bootstrap(hist, cfg, "stationary", n = 200), hist)
stress <- regime_subset(hist, "inflation >= 4", min_run = 60)   # Stress-Bootstrap
```

| Baustein | Inhalt |
|---|---|
| `tail_dependence()` | empirische Koeffizienten λ unten/oben je Quantil, Exceedance-Korrelationen (Longin & Solnik 2001) |
| `fit_copula()` | Gauß, t, Clayton, Gumbel, Frank, rotierte Varianten für negative Abhängigkeit; Pseudo-ML, AIC, implizite Tail-Abhängigkeit |
| `dcc_fit()` | DCC(1,1) nach Engle (2002), Filter in C++ |
| bedingte Analyse | Kennzahlen je Regime, Differenz oberstes minus unterstes Regime mit stationärem Block-Bootstrap (Intervall, p-Wert) |
| `quantile_reg()`, `tail_regression()` | lineare Quantilsregression (MM-Algorithmus), Effekt der Drittvariablen je Quantil mit Block-Bootstrap-Fehlern |
| `covar_analysis()` | CoVaR und ΔCoVaR nach Adrian & Brunnermeier (2016), optional zeitvariabel über Zustandsvariablen |
| `validate_dependence()` | erhalten Bootstrap-Pfade Korrelation und Tail-Abhängigkeit der Historie? |
| `regime_subset()` | Zeilen eines Regimes als Grundlage für Stress-Bootstraps |

Alle Verfahren sind ohne Zusatzpakete umgesetzt.

### Taktische Allokation

Taktische Strategien wechseln zwischen Zielportfolios. Gewichts-Erzeuger
liefern dafür eine Reihe von Zielgewichten (`SimLevWeights`), die
`tactical_simulation()` mit der normalen Engine ausführt, also mit Steuern,
Spreads, Sparplänen und Toleranzbändern. Intern nutzt sie das
Ereignis-Rebalancing von `simulation()` (`event_col`, `event_weight`); die
Engine selbst bleibt unverändert.

``` r
# Regeln: erste zutreffende gewinnt, sonst Rückfall
w1 <- tactical_rules(dat, list(
  list(when = signal_sma(dat$aktien, 200, band = 2), weights = c(aktien = 1)),
  list(when = "inflation < 3", weights = c(anleihen = 1))), default = c(geldmarkt = 1))
# Momentum-Rotation mit absolutem Filter und Canary-Schutz
w2 <- tactical_rotation(dat, c("usa", "europa", "em"), top = 2, safe = c("anleihen", "geldmarkt"),
                        canary = c("em", "anleihen"), type = "13612w")
# Zielvolatilität, Glidepath und Kern-Satellit
w3 <- target_volatility(dat, c(aktien = 0.7, anleihen = 0.3), safe = "geldmarkt", target = 10)
# Bedingt: nur im obersten/untersten Volatilitätsfünftel vom Grundanteil 80 % abweichen
w3b <- conditional_volatility(dat, c(aktien = 1), safe = "geldmarkt", base = 0.8, upper = 0.8, lower = 0.2)
w4 <- glidepath(dat, from = c(aktien = 0.9, anleihen = 0.1), to = c(aktien = 0.4, anleihen = 0.6))
w5 <- blend_weights(kern = w4, satellit = w2, shares = c(0.8, 0.2))
res <- tactical_simulation(dat, w5, rebalance = "month", tolerance = 5, lag = 1,
                           asset_args = list(asset_bonus = c(usa = 30, europa = 30, em = 30)),
                           tax_mode = "person", dca_mode = TRUE, dca_value = 500, dca_span = 1)
```

`lag = 1` handelt ein Signal vom Schlusskurs eines Tages am nächsten Tag;
`lag = 0` entspricht der Konvention vieler Online-Backtester.

`conditional_volatility()` steuert nur in extremen Phasen (Bongaerts, Kang &
van Dijk 2020): Liegt die geschätzte Volatilität über ihrem bisherigen
80-%-Quantil, sinkt der Risikoanteil auf `base × Vergleichsvola / Vola`;
unter dem 20-%-Quantil steigt er entsprechend, höchstens auf 100 %.
Dazwischen bleibt der Grundanteil. Quantile und Vergleichswert (Standard:
bisheriges Mittel) werden nur aus der Vergangenheit berechnet. Gegenüber
`target_volatility()` fallen deutlich weniger Umschichtungen an. Weil die
Engine keinen Kredit kennt, ist Hochskalieren nur bei `base < 1` möglich;
mit `scaling = "fixed"` gelten feste Anteile je Phase.

### Optimierung und Risikozerlegung

``` r
portfolio_optimize(dat, c("aktien", "anleihen", "gold"), method = "risk_parity")
portfolio_optimize(dat, assets, method = "max_sharpe", upper = 0.6, cov = "ledoit_wolf", resample = 200)
plot(efficient_frontier(dat, assets))
risk_contributions(dat, c(aktien = 0.6, anleihen = 0.3, gold = 0.1), measure = "cvar")
w <- rolling_optimization(dat, assets, "min_variance", window = 3, every = "quarter")
tactical_simulation(dat, w, rebalance = "quarter")      # Optimierung ausserhalb der Stichprobe
```

Verfahren: Minimum-Varianz, Mean-Variance, maximale Sharpe Ratio, maximale
Diversifikation (Choueifaty & Coignard 2008), Risikoparität mit
Risikobudgets (Spinu 2013), Hierarchical Risk Parity (López de Prado 2016),
minimaler CVaR (Rockafellar & Uryasev 2000), inverse Volatilität und
Gleichgewichtung; Grenzen je Anlage, Ledoit-Wolf-Schrumpfung und
Michaud-Resampling über Block-Bootstrap-Stichproben. Die Löser sind ohne
Zusatzpakete geschrieben (projizierter Gradient mit Beschleunigung,
gedämpftes Newton-Verfahren) und gegen geschlossene Lösungen getestet.
`risk_contributions()` zerlegt Volatilität oder CVaR additiv auf die
Anlagen.

### Anleihen, Geldmarkt und Währungssicherung

``` r
dat$bund10 <- bond_index_from_yields(dat, "rendite_10j", maturity = 10, coupon_frequency = 1)
dat$geldmarkt <- money_market_index(dat, "ester", spread = 0.1)
dat$sp500_eur_h <- currency_hedged_index(dat, "sp500_usd", domestic_rate = "ester", foreign_rate = "sofr")
```

`bond_index_from_yields()` bildet einen Total-Return-Index konstanter
Laufzeit aus einer Renditereihe (Kupon plus Neubewertung, wahlweise über
Duration und Konvexität; Swinkels 2019). `money_market_index()` verzinst
Act/360, `currency_hedged_index()` addiert die Zinsdifferenz einer
rollierenden Devisentermin-Absicherung.

### Gebühren, Kirchensteuer und Freibetrag

Drei optionale Argumente von `simulation()` bilden die deutsche Praxis
genauer ab; ohne sie rechnet die Engine wie ohne diese Optionen.

``` r
simulation(dat, strategie, tax_mode = "person",
           order_fee = list(fixed = 1),        # z. B. 1 EUR je Order beim Neobroker
           dca_fee = 0,                        # Sparplan gebührenfrei
           church_tax = 9,                     # 9 % Kirchensteuer
           harvest_mode = TRUE, harvest_day = "12-15")   # Freibetrag jährlich ausschöpfen
```

Mit `church_tax` wird der Abgeltungsteuersatz nach § 32d Abs. 1 EStG
angepasst (bei 9 % rund 27,995 % statt 26,375 %; ein abweichend angegebenes
`tax_rate` wird dabei mit Warnung überschrieben). Dabei wirkt die
Kirchensteuer auch auf die Einkommensteuer, also auf die § 23-Steuer und
den persönlichen Satz der Günstigerprüfung. Mit festem `marginal_tax_rate`
ist der Sonderausgabenabzug der Kirchensteuer dabei nicht abgebildet, mit
`taxable_income` schon: Die Kirchensteuer ist Sonderausgabe im Jahr ihrer
Zahlung, Erstattungen werden verrechnet bzw. hinzugerechnet (siehe
[Besteuerung](#besteuerung)).

Gebühren erhöhen beim Kauf den Einstandskurs und mindern beim Verkauf den
Erlös, wirken also auch steuerlich; möglich sind feste und prozentuale
Gebühren mit Mindest- und Höchstbetrag. `harvest_mode` realisiert einmal im
Jahr Gewinne bis zum noch freien Sparer-Pauschbetrag (und wahlweise bis zur
Höhe des Verlusttopfs) und kauft sofort zurück; das hebt den Einstandskurs
steuerfrei an. Spread und Gebühren für beide Orders fallen dabei an.

### Szenarien und Stresstests

``` r
# Wie sieht die Welt aus, wenn die Inflation im Mittel 4 % beträgt?
ep <- entropy_pooling(dat, c("aktien", "anleihen"), list(view_mean("inflation", 4)), states = "inflation")
scenario_risk(ep, c(aktien = 0.6, anleihen = 0.4))
# Was erwartet die Abhängigkeitsstruktur für Anleihen in den schlechtesten 5 % der Aktienwochen?
cs <- copula_scenarios(dat, c("aktien", "anleihen"), stress = list(aktien = c(0, 0.05)))
crisis_replay(dat, c(aktien = 0.6, anleihen = 0.4))   # 1973/74, 1987, 2000-02, 2008, 2011, 2020, 2022
```

`entropy_pooling()` gewichtet historische Szenarien so um, dass eigene
Annahmen (Mittelwerte, Wahrscheinlichkeiten, Volatilitäten) erfüllt sind, bei
minimaler Abweichung von der Historie (Meucci 2008). `copula_scenarios()`
simuliert aus einer t-Copula mit empirischen Rändern, auf Wunsch bedingt auf
ein Quantilband einzelner Anlagen.

### Planung über lange Horizonte

``` r
hist_adj <- set_expected_return(hist, c("us", "eu"), target = 5)   # Renditeannahme statt Historie
pb <- pooled_bootstrap(list(usa = usa, de = de, jp = jp), c("aktien", "anleihen"),
                       weights = c(aktien = 0.6, anleihen = 0.4), inflation = "cpi", years = 40)
h  <- horizon_model("discrete", years = c(25, 30, 35, 40), prob = c(0.3, 0.4, 0.2, 0.1))
withdrawal_simulation(pb, withdrawal_rule("guyton_klinger", rate = 4), horizon = h)
goal_optimize(portfolio_returns(usa, kandidaten), start_value = 1e5, goal = 3e5,
              horizon = 20, contributions = 6000)
```

Die Laufzeit der Entnahmephase kann fest sein oder einer eigenen Verteilung
folgen (gleichverteilt, diskret, normal, dreiecksförmig oder eine eigene
Stichprobe); es gibt bewusst keine eingebauten Sterbetafeln.
`goal_optimize()` bestimmt per dynamischer Programmierung für jeden
Zeitpunkt und jedes Vermögen das Portfolio mit der höchsten Wahrscheinlichkeit,
ein Ziel zu erreichen (Das et al. 2020), auch für Entnahmen (Ziel 0 =
Geld reicht bis zum Horizont).

### Statistische Prüfungen und Regime

| Funktion | Frage |
|---|---|
| `sharpe_test(x, y)` | Unterscheiden sich zwei Sharpe Ratios wirklich? (Ledoit & Wolf 2008) |
| `reality_check(search)` | Schlägt die beste von vielen Strategien die Benchmark mehr als zufällig? (White 2000, Hansen 2005) |
| `sharpe_haircut(search)` | Wie viel der Sharpe Ratio erklärt die Zahl der Versuche? (Harvey & Liu 2015) |
| `min_track_record(x)` | Wie lang muss eine Historie sein, damit die Sharpe Ratio belastbar ist? |
| `cpcv_portfolio(x, assets, methods)` | Wie verteilt sich die Out-of-Sample-Güte von Optimierern? (kombinatorische Kreuzvalidierung) |
| `signal_analysis(dat, signal, target)` | Was folgt typischerweise auf ein Signalniveau? |
| `regime_hmm(dat, columns)`, `regime_states()` | In welcher Marktphase sind wir (ohne Zukunftsdaten)? |
| `return_heatmap(x, inflation)` | Wie hängt die reale Rendite von Startjahr und Haltedauer ab? |

`deep_analysis(..., inflation = 2)` rechnet alle Kennzahlen real.
`portfolio_optimize()` kennt zusätzlich den minimalen Conditional Drawdown
at Risk (`method = "min_cdar"`) und die Kovarianzschätzer `"ewma"`,
`"denoise"` und `"gerber"`.

## Ergebnisse auswerten

`simulation()` liefert ein `SimLevResult`. Die Bestandteile heißen in allen
drei Sprachen gleich:

| Bestandteil | Inhalt |
|---|---|
| `dates`, `filled` | Simulationstage und Markierung der per LOCF aufgefüllten Tage |
| `worth` | Täglicher Gesamtwert des Depots in EUR (einschließlich Einzahlungen) |
| `twr_index` | Zeitgewichteter Wertindex (Start = 1), um Einzahlungen bereinigt; Grundlage der TTWROR und, mit Sparplan, der Drawdowns |
| `invested` | Je Tag Startwert plus kumulierte Einzahlungen in EUR, brutto vor Kaufkosten |
| `external_flows` | Logisch, `TRUE` bei Einzahlungen nach dem Starttag (Sparplan) |
| `drawdowns` | Täglicher Abstand zum bisherigen Höchststand als Anteil; mit Sparplan auf `twr_index` |
| `cagr`, `ttwror` | Jährliche Wachstumsrate und zeitgewichtete Rendite (TTWROR) als Anteil; mit Sparplan ist `cagr` die geldgewichtete Rendite (XIRR) |
| `statistics` | Alle Risiko- und Renditekennzahlen |
| `report` | Je Asset tägliche Werte: `worth`, `money`, `flows`, `total`, `share` |
| `tax_report` | Gezahlte Steuern, Verlustvorträge, genutzter Pauschbetrag und dessen Steuerersparnis; `open_tax_debt` (am Ende offene, nicht gedeckte Steuerschuld in EUR, sonst 0) und mit `taxable_income` `tariff_years` (Veranlagung je Jahr); bei `tax_mode = "person"` `next_year` (Steuerzustand des Jahres nach dem letzten Datentag: verbrauchter Sparer-Pauschbetrag, Verlusttöpfe, mit `taxable_income` der letzte Kirchensteuer-Bescheid) für eine Fortsetzung, z. B. in der Entnahmephase |
| `undefined_metrics` | `data.frame(metric, reason, detail)` mit einer Zeile je Kennzahl, die `NA` ist (z. B. negativer Endwert, Einzeltag, Volatilität 0); `print()` und `summary()` zeigen sie als „nicht definiert (Ursache)“. Der Endwert bleibt unverändert, auch wenn er negativ ist |
| `open_lots` | *Nur mit `tax_mode = "person"` gefüllt, sonst `NULL`:* je Asset die am letzten Tag gehaltenen Lots (Kaufdatum, Stück, Anschaffungskurs, anzurechnende Vorabpauschale) mit Steuerregime, Teilfreistellung, Cash, `asset_spread` und `order_fee`; `withdrawal_simulation(start_value = <Ergebnis>)` verkauft daraus per FIFO |
| `buys`, `sells` | Durchschnittliche Anzahl Käufe und Verkäufe pro Jahr je Asset (bei einem Einzeltag `NA`) |
| `fees_paid`, `harvest_days` | Summe der Ordergebühren (mit `order_fee`/`dca_fee`) und Termine der Gewinnrealisierung (mit `harvest_mode`) |
| `trades` | *Nur Python und Julia:* alle Lots, Verkäufe, Vorabpauschalen und Gebühren je Asset |

`summary(result)` liefert unter anderem `total_return_twr`
(zeitgewichtete Gesamtrendite), `return_on_invested` ((Endwert −
Eingezahlt) / Eingezahlt) und `total_return` als Alias für
`total_return_twr`; mit Sparplan zeigt die Ausgabe beide Renditen.

<details>
<summary><b>R</b></summary>

``` r
result$worth
result$statistics$sharpe
result$report$WORLD$total

plot(result)                                   # alle Standard-Panels
plot(result, style = "compact")                # 2×2: Performance, Drawdown, Verteilung, Kennzahlen
plot(result, style = "custom", panels = c("performance", "drawdown", "monthly"))
plot(result, compare = result_ohne_steuer)     # zwei Strategien nebeneinander

export_dashboard(result, "backtest.pdf", width = 16, height = 10)
```

</details>

<details>
<summary><b>Python</b></summary>

``` python
result.worth                         # numpy-Array
result.statistics["sharpe"]
result.report["WORLD"]["total"]

# Tagesverlauf als Tabelle
df = pd.DataFrame({"worth": result.worth, "drawdown": result.drawdowns}, index=result.dates)

p = result.plot()                                      # alle Standard-Panels (SimLevPlot, SVG)
p.data["drawdown"]                                     # dargestellte Werte als Tabelle
result.plot(style="compact")
result.plot(style="custom", panels=["performance", "drawdown", "monthly"])
result.plot(compare=result_ohne_steuer)

simlev.export_dashboard(result, "backtest.svg", width=16, height=10)
```

</details>

<details>
<summary><b>Julia</b></summary>

``` julia
result.worth
result.statistics.sharpe
result.report["WORLD"].total

plot_dashboard(result)                                    # SVG, in Jupyter, Pluto und VS Code direkt sichtbar
plot_dashboard(result; style = "compact")
plot_dashboard(result; style = "custom", panels = ["performance", "drawdown", "monthly"])
plot_dashboard(result; compare = result_ohne_steuer)

export_dashboard(result, "backtest.svg"; width = 16, height = 10)   # immer SVG; PDF/PNG z. B. mit rsvg-convert
```

</details>

Verfügbare Panels sind `"performance"`, `"drawdown"`, `"distribution"`,
`"rolling"`, `"monthly"`, `"stats"`, `"correlation"` und `"comparison"`.
Über `colors` passen Sie das Farbschema an ein Corporate Design an.

## Unterschiede zwischen den Sprachen

Funktionsnamen und Argumente sind in allen drei Fassungen identisch. Wer
SimLev aus R kennt, muss nur wenige Schreibweisen umstellen:

| R | Python | Julia |
|---|---|---|
| `NULL` | `None` | `nothing` |
| `TRUE` / `FALSE` | `True` / `False` | `true` / `false` |
| `NA` | `simlev.NA` (numerisch) bzw. `None` | `SimLev.NA` (numerisch) bzw. `missing` |
| `c(20, 400)` | `(20, 400)` oder `[20, 400]` | `[20, 400]` |
| `c(us = "us_ret")`, `list(A = "w1")` | `{"us": "us_ret"}`, `{"A": "w1"}` | `(us = "us_ret",)`, `(A = "w1",)` |
| `data.frame(...)` | `pandas.DataFrame(...)` | `RFrame(...)`; für `simulation()` auch NamedTuple oder `DataFrame(...)` |
| `simulation(data, s, start_value = 1e4)` | `simlev.simulation(data, s, start_value=1e4)` | `simulation(data, s; start_value = 1e4)` |
| `result$worth` | `result.worth` | `result.worth` |
| `result$statistics$sharpe` | `result.statistics["sharpe"]` | `result.statistics.sharpe` |
| `result$report$WORLD$total` | `result.report["WORLD"]["total"]` | `result.report["WORLD"].total` |
| `print(x)` | `print(x)` | `display(x)` |
| `summary(x)` | `simlev.summary(x)` oder `x.summary()` | `summary(result)`, allgemein `r_summary(x)` |
| `plot(x)` | `x.plot()` oder `simlev.plot(x)` | `plot_dashboard(result)`, allgemein `r_plot(x)` |
| `set.seed(42)` | `simlev.set_seed(42)` | `set_seed(42)` |
| `bootstrap_probability(st, cagr > 0.05)` | `simlev.bootstrap_probability(st, "cagr > 0.05")` | `bootstrap_probability(st, "cagr > 0.05")` |
| `function(df) signal_sma(df$INDEX, 200)` | `lambda df: simlev.signal_sma(df["INDEX"], 200)` | `df -> signal_sma(df["INDEX"], 200)` |

Python 0.5.0 und Julia 0.5.0 rechnen in allen Funktionen wie die aktuelle
R-Fassung; die Unterschiede betreffen nur Schreibweisen und Komfort (siehe
[`python/README.md`](python/README.md) und
[`julia/README.md`](julia/README.md)). Daneben gilt:

- **Bedingungen als Text** (`tactical_rules()`, `bootstrap_probability()`,
  `regime_subset()`, `view_prob()`): R nimmt Ausdrücke, Python und Julia
  nehmen Text und werten ihn mit demselben Auswerter in **R-Syntax** aus
  (`"cagr > 0.05 & max_drawdown <= 0.3"`, `"!eq > 90"`, `"x %in% c(1, 2)"`,
  mit R's Vorrangregeln, NA-Logik, Indizierung und `if`/`else`; geprüft an
  über 1.000 Ausdrücken gegen R). Funktionsdefinitionen, Schleifen und
  benannte Vektoren unterstützt der Auswerter nicht; statt Text geht
  jeweils auch eine Funktion der Zielsprache.
- **Argumentnamen**, die in der Zielsprache Schlüsselwörter sind, bekommen
  einen Unterstrich: in Python `yield_`, `raise_` und `from_`, in Julia
  z. B. `end_`.
- **Zwischenstände** von `bootstrap_study(chunk_dir = …)` speichert Python
  als Pickle, Julia in einem eigenen Textformat statt RDS.
- **Doppelte Datumswerte** führen in allen drei Fassungen zu einer
  Fehlermeldung (in R erst nach dem Stand 54b5b4f; vorher rechnete R
  stillschweigend mit einem verschobenen Kalender weiter).
- Das **statische Dashboard** zeichnet jede Sprache mit eigenen Mitteln
  (R: Base-Grafik, Python und Julia: SVG). Python und Julia zeigen
  dieselben Panels, deutschen Beschriftungen und Kennzahlen wie R (die
  Grafik selbst ist nicht bitgleich, die dargestellten Daten schon). Die
  `plot()`-Methoden der übrigen Ergebnisobjekte zeichnen ebenfalls als
  SVG. In Python und Julia liefern alle Grafiken ein `SimLevPlot` mit
  `svg`, `data` (dargestellte Werte je Panel als Tabelle), `source`
  (Eingabeobjekt) und `kind`, damit sich eigene Grafiken bauen lassen.
- **Sprache der Ausgaben:** Alle drei Fassungen geben alle Meldungen,
  `print()`, `summary()` und das Dashboard auf Deutsch aus („SimLev
  Simulationsergebnisse“, „Wertentwicklung“, „Endwert“, „Risiko“ …).
- `result.trades` (alle Buchungen je Asset) gibt es nur in Python und
  Julia.
- Das Argument `spread` von `simulation()` hat in allen Fassungen keine
  Wirkung. Spreads werden je Asset über `asset_spread` gesetzt; SimLev
  warnt, wenn `spread` angegeben wird.

Weitere sprachspezifische Hinweise stehen in den READMEs der Unterordner
[`r/`](r/README.md), [`python/`](python/README.md) und
[`julia/`](julia/README.md).

## Bitgleichheit zum R-Paket

„Bitgleich“ heißt: Für dieselben Eingaben liefert ein Port dieselben
IEEE-754-Gleitkommazahlen wie das R-Paket, ohne jede Toleranz. Python 0.5.0
und Julia 0.5.0 sind bitgleich zur aktuellen R-Fassung 0.5.0, und zwar für
`simulation()` (alle Tageswerte, Kennzahlen, Steuerwerte, die Ausgabe von
`print(result)` und die Detailprotokolle von `details = TRUE`) und für alle
übrigen Funktionen (Ergebnisse, Druck- und Konsolenausgaben, Warnungen und
Fehlermeldungen). Beide Ports werden streng geprüft: Sie unterscheiden wie
R `NA` und `NaN` (in Python ist `simlev.NA` R's `NA`, ein gewöhnliches
`nan` R's `NaN`) und müssen auch das Vorzeichen der Null treffen.

Dafür bilden die Ports nicht nur die Logik, sondern auch die
**Rechenweise** von R exakt nach:

- **80-Bit-`long double`.** R summiert bei `sum()`, `mean()`, `var()`,
  `cumsum()`, `prod()` und `rowSums()` intern mit dem 80-Bit-Format der
  x87-FPU. Python nutzt dafür `numpy.longdouble` in derselben Reihenfolge.
  Julia kennt diesen Typ nicht; SimLev.jl rechnet mit einem eigenen Typ
  `F80`, auf x86-64 direkt mit dem x87-Format der Hardware (über
  `llvmcall`), auf anderen Prozessoren mit einem Software-Nachbau, der
  Rundung, Über- und Unterlauf und NaN-Regeln bitgenau nachbildet.
- **Mathematische Funktionen** (`exp`, `log`, `log1p`, `pow` …) kommen wie
  in R aus glibc-libm (Python über das Modul `math`, Julia per `ccall`),
  weil die Funktionen von numpy und Julia in den letzten Bits abweichen.
- **Potenzen** folgen R's Sonderregeln (`x^2` als `x*x`, sonst `pow()` der
  C-Bibliothek). Kalender, `round()`, `format()`, `sprintf()` und Modulo
  verhalten sich wie in R.
- Die **C++-Kerne** des R-Pakets (FIFO, Steuern, Markt-Updates, Bootstrap,
  Entnahme, Abhängigkeiten, Optimierung und Signale) sind Zeile für Zeile
  übertragen.
- **R-Interna.** Für die Erweiterungen bilden Python in `simlev/_r/` und
  Julia in `julia/src/r/` nach, was R selbst beisteuert: Zufallszahlen
  (Mersenne-Twister, L'Ecuyer-CMRG-Streams, `sample.int`, `rnorm` …),
  Verteilungsfunktionen aus nmath, die benötigten stats-Funktionen
  (`quantile`, `cor`, `optim`, `optimize`, `uniroot`, `lm`, `glm`,
  `smooth.spline`, `density`, `fft`, `hclust` …), lineare Algebra wie die
  Referenz-BLAS/LAPACK und LINPACK sowie Formatierung und Druckausgabe;
  Julia zusätzlich einen Auswerter für Bedingungen in R-Syntax.

**So wurde es geprüft:** [`golden/golden_cases.R`](golden/golden_cases.R)
und [`golden/stress_cases.R`](golden/stress_cases.R) erzeugen Szenarien für
die Engine, die Generatoren in [`golden/modules/`](golden/modules/) Fälle
für alle übrigen Funktionen; sie rechnen mit dem R-Paket und speichern
Eingaben und Ergebnisse binär exakt. Die Vergleichswerkzeuge der Ports
rechnen dieselben Fälle nach und vergleichen jeden Wert Bit für Bit.

| Satz | Python 0.5.0 | Julia 0.5.0 |
|---|---|---|
| Engine: gezielte Fälle für jeden Steuer- und Sonderpfad (Vorabpauschale mit Zwangsverkauf, 29.-Februar-Lots nach § 23, Splits, LOCF-Lücken, Event-Rebalancing, Günstigerprüfung u. a.) plus Zufallsfälle | 68 in `golden/cases/`, alle bitgleich (strikt, NA ≠ NaN) | 68, alle bitgleich (strikt, NA ≠ NaN) |
| Engine: Stressfälle (30 Jahre, Totalverlust-Hebel, mehrere Signal-Assets, konstante Preise, Schalttage, Extremwerte, Fehlerpfade) | 37 in `golden/extra/`, alle bitgleich (strikt) | 37, alle bitgleich (strikt) |
| Engine: frisch erzeugte Zufalls- und Stressfälle beider Generatoren | 669, alle bitgleich | 469, alle bitgleich |
| Engine: Fälle mit den neuen Argumenten (`order_fee`, `dca_fee`, `church_tax`, `harvest_*`, `taxable_income`, `tax_tariff`) | 750, alle bitgleich | 92 eigene Fälle, alle bitgleich (strikt) |
| Alle Funktionen, die Engine mit den Argumenten und Ergebniselementen von 0.5.0 (Modul `engine`), die Nachbildung von evd, rugarch und imputeTS (Module `evd`, `rugarch`, `imputets`) und die R-Interna (29 Module in `golden/modules/`) | 4.536, alle bitgleich (strikt, NA ≠ NaN, mit Vorzeichen der Null) | 4.536, alle bitgleich (strikt, NA ≠ NaN, mit Vorzeichen der Null) |

Die Fälle in [`golden/`](golden/) prüfen beide Suiten: die 105
Engine-Fälle in `golden/cases/` und `golden/extra/` vollständig und die
4.536 Modul-Fälle in Python vollständig, in Julia standardmäßig in einer
Auswahl und mit `SIMLEV_FULL_TESTS=1` vollständig.

**Optionale R-Pakete.** `.fit_tail` (Tail-Modell im Bootstrap, Verfahren
`"evt"`) schätzt die GPD ab 30 Überschreitungen immer per `fpot` aus evd
2.3-7.1, das ins R-Paket übernommen ist (`.evd_fpot`, `r/R/vendor_evd.R`,
`r/src/vendor_evd.c`, Lizenz und Autoren in `r/inst/COPYRIGHTS`); evd muss
dafür nicht installiert sein. `.fill_na` (Backcast mit `fill = "stine"`
bzw. `index_fill = "stine"`) interpoliert immer nach Stineman per
`na_interpolation(option = "stine")` aus imputeTS 3.4 mit `stinterp` aus
stinepack 1.5, beide ins R-Paket übernommen (`.imputets_na_interpolation`,
`r/R/vendor_imputets.R`, `r/src/vendor_imputets.cpp`,
`r/R/vendor_stinepack.R`); imputeTS muss dafür nicht installiert sein.
`.fit_garch11` (Bootstrap-Verfahren `garch` und `gjr_garch`, Kopplung
weiterer Reihen, `dcc_fit()`, `dependence_analysis()`) schätzt immer per
`ugarchfit` aus rugarch 1.5-6 mit Rsolnp 1.16 `solnp`/`gosolnp` und
truncnorm 1.0-9 `rtruncnorm`, alle ins R-Paket übernommen
(`.rugarch_ugarchfit`, `r/R/vendor_rugarch.R`, `r/src/vendor_rugarch.c`,
`r/R/vendor_rsolnp.R`, `r/R/vendor_truncnorm.R`,
`r/src/vendor_truncnorm.c`); die Hesse-Matrix rechnet eine eigenständige
Richardson-Extrapolation (`r/R/richardson.R`, gegen numDeriv geprüft);
rugarch muss dafür
nicht installiert sein, `optim` und die Momente bleiben nur der Rückfall,
wenn der Fit mit einem Fehler scheitert. Python und Julia bilden die
Pakete bitgleich nach – evd 2.3-7.1 `fpot`; rugarch 1.5-6 `ugarchfit` mit
Rsolnp 1.16 `solnp`, Richardson-Hesse-Matrix, `stats::nlminb` und `gosolnp`
(mit truncnorm 1.0-9) als Ausweichwegen; imputeTS 3.4 mit stinepack 1.5 –
und nehmen wie R immer den Paket-Weg. gosolnp (zufällige Neustarts) erreicht die
Solver-Kette in R bei etwa 1 % zufälliger Reihen; wie R setzt er dabei den
globalen Zufallszustand aus der Uhrzeit (`set.seed` mit den
Unix-Sekunden), das Ergebnis hängt dann in R wie in den Ports von der
Sekunde des Aufrufs ab. `SIMLEV_R_SYS_TIME` (Sekunden seit 1970) stellt
die Uhr der Ports fest. MSGARCH gilt als nicht installiert; die
MS-GARCH-Verfahren melden wie R, dass das Paket fehlt.

**Aktuelle R-Fassung 0.5.0:** Nach dem Stand 54b5b4f korrigiert das
R-Paket Rechenfehler der Engine (Fondsmodus, Splits mit ganzen Anteilen,
später startende Assets, Sparplantermine, unsortierte, doppelte oder
fehlende Daten, Rebalancing zum Tageskurs, Sortino Ratio u. a.), setzt die
Besteuerung nach geltendem Recht um (Vorabpauschale, Verlustverrechnung,
§ 23 EStG, Kirchensteuer, Günstigerprüfung, Zwangsverkäufe), misst
Kennzahlen mit Sparplan geld- bzw. zeitgewichtet, kennzeichnet nicht
definierte Kennzahlen mit Ursache und gibt alle Meldungen und Ausgaben auf
Deutsch aus. Alle 105 Golden-Fälle sind mit der aktuellen R-Fassung neu
erzeugt. Python 0.5.0 und Julia 0.5.0 haben alle Änderungen übernommen und
treffen alle 105 Fälle bitgleich, einschließlich Druckausgabe. Was sich
geändert hat, steht in [`r/NEWS.md`](r/NEWS.md),
[`python/NEWS.md`](python/NEWS.md) und [`julia/NEWS.md`](julia/NEWS.md).

**Plattformen:** Die Referenz ist R unter Linux x86-64 (die Modul-Fälle
entstanden mit R 4.3.3). Python ist
dort bitgleich, wo `numpy.longdouble` 80 Bit hat (Linux x86-64) und die
mathematischen Funktionen aus glibc-libm kommen; numpy-Transzendental-
funktionen verwendet SimLev bewusst nicht, weil sie auf Rechnern mit
AVX-512 abweichen. Eigenvektoren (`eigen()`, u. a. in
`portfolio_optimize()`) holt Python wie R aus der Referenz-LAPACK des
Systems (Pfad über `SIMLEV_LAPACK` wählbar); fehlt sie, rechnet numpy ohne
Bitgleichheitsgarantie (mit einer Warnung). Auf Plattformen mit 64-Bit-`long
double` wie macOS auf Apple Silicon überspringt die Python-Suite die
Bitgleichheits-Tests. Grafiken sind in den
Ports nicht bitgleich, die berechneten Daten schon. Julia ist unter Linux
x86-64 mit glibc geprüft; Eigenvektoren holt es wie Python aus der
Referenz-LAPACK des Systems (`SIMLEV_LAPACK`, ohne sie mit Warnung über
`LinearAlgebra.eigen`, ohne Bitgleichheitsgarantie). Die libm-Aufrufe der
R-Interna gehen in Julia unter Linux an glibc (`libm.so.6`); unter macOS
und Windows lädt das Paket mit der dortigen C-Bibliothek, ist dort aber
nicht geprüft und nicht bitgleich zugesagt.

**Zeichenketten-Reihenfolge.** R sortiert und vergleicht Zeichenketten
(`sort`, `order`, `rank`, `factor`-Stufen, `table`, `split`, `<`/`>`)
nicht nach Codepunkten, sondern mit der ICU-Kollation des Locales; unter
`LC_ALL=C.UTF-8` ist das der Collator „root“ (`a A ä b B`), unter
`LC_ALL=C` die Byte-Reihenfolge. Python (ctypes) und Julia (ccall) bilden
das mit der System-ICU nach (`libicui18n.so.<N>`, Debian/Ubuntu: Paket
`libicu<N>`; Pfad über `SIMLEV_ICU`) und richten sich wie R nach den
Locale-Variablen. `SIMLEV_COLLATE=C` erzwingt die Byte-Reihenfolge,
`SIMLEV_COLLATE=icu:root` die Reihenfolge von R unter `C.UTF-8` (so prüfen
die Testsuiten, unabhängig vom Locale des Rechners). Ohne ICU wird nach
Codepunkten verglichen, mit einer Warnung; Ergebnisse mit Zeichen-Sortierung
sind dann nicht bitgleich.

## Geschwindigkeit

Gemessen mit R 0.5.0, Python 0.5.0 und Julia 0.5.0 auf derselben Maschine
(Linux x86-64, zwei Kerne; R 4.3.3, Python 3.13, Julia 1.13.2), Mittel aus
fünf Läufen nach einem ersten Aufruf, Julia nach dem Vorkompilieren:

| Szenario | R | Python | Julia |
|---|---|---|---|
| 30 Jahre, 3 Assets (Aktien-ETF, Renten-ETF, ETC mit Lieferanspruch), Sparplan, jährliches Rebalancing, Steuern | 0,17 s | 0,12 s | **0,033 s** |
| 30 Jahre, Hebelzertifikat und Renten-ETF, Fondsmodus, Splits, ganze Anteile, Schwellen-Rebalancing | 0,17 s | 0,09 s | **0,012 s** |
| 3,5 Jahre, 3 Assets, zwei Signal-Assets, § 23, Sparplan | 0,09 s | 0,026 s | **0,003 s** |

Alle drei Fassungen rechneten dieselben Kursdaten (synthetisch, in R
erzeugt und als CSV mit voller Genauigkeit eingelesen) und kamen in jedem
Szenario auf denselben Endwert. Die Messskripte liegen nicht im
Repository. Nicht enthalten ist die Kompilierung beim ersten Aufruf in
einer Julia-Sitzung (hier rund 2 Sekunden für das erste `simulation()`).
Die frühere Tabelle für den Stand 54b5b4f (Julia 0.1.0) beruhte auf
anderen Szenarien und ist mit diesen Werten nicht vergleichbar.

Parameterstudien mit Hunderten von Läufen sind damit in allen drei
Fassungen problemlos möglich.

## Wie die Engine arbeitet

An den meisten Tagen passiert in einem Buy-and-Hold-Depot nichts außer
Kursbewegungen. SimLev nutzt das und unterscheidet zwei Pfade:

- Der **Slow Path** läuft nur an Tagen, an denen tatsächlich etwas
  geschieht: Sparrate, Rebalancing, Signal, Jahreswechsel mit
  Steuerabrechnung, Split oder Liquidation. Hier wird jedes Ereignis
  vollständig mit Lotverwaltung und Steuerlogik verarbeitet.
- Alle Tage dazwischen schreibt der **Fast Path** als zusammenhängenden
  Block fort: in R mit einem einzigen C++-Aufruf, in Python mit einer
  vektorisierten numpy-Operation, in Julia in einer einfachen Schleife.

## Grenzen und wichtige Hinweise

- **Keine Steuer- oder Anlageberatung.** SimLev ist ein Analysewerkzeug.
  Die Steuerlogik ist sorgfältig umgesetzt, bildet aber nicht jeden
  Einzelfall ab (z. B. ausländische Quellensteuer, Ausschüttungen als
  eigene Zahlungsströme). Für verbindliche Aussagen
  wenden Sie sich an eine Steuerberaterin oder einen Steuerberater.
- **Die Qualität der Ergebnisse hängt von den Eingabedaten ab.** Achten Sie
  auf bereinigte Kursreihen (Ausschüttungen, Splits – außer Sie lassen
  Splits über `split_mode` simulieren) und darauf, dass Hebel- und
  Finanzierungskosten in der Reihe enthalten sind.
- **Ein Backtest ist keine Prognose.** Besonders bei vielen getesteten
  Parametervarianten besteht die Gefahr, eine Strategie an die
  Vergangenheit anzupassen (*Overfitting*).

## Aufbau des Repositorys und Entwicklung

```
SimLev-Repos/
├── README.md          diese Seite
├── LICENSE.md         GPL-3
├── r/                 R-Paket (DESCRIPTION, R/, src/, man/, tests/, vignettes/)
├── python/            Python-Paket (pyproject.toml, simlev/ mit _r/, tests/, tools/, examples/)
├── julia/             Julia-Paket (Project.toml, src/ mit r/, data/, test/, tools/, examples/)
├── golden/            gemeinsame Referenzfälle aus R und ihre Generatoren
│   ├── cases/         68 Golden-Master-Fälle der Engine (Python und Julia)
│   ├── extra/         37 Stressfälle der Engine (Python und Julia)
│   ├── modules/       4.536 Referenzfälle aller Funktionen in 29 Modulen
│   │                  (je Fall R-, Python- und Julia-Code), Generatoren
│   │                  gen_<modul>.R und ref_tools.R
│   ├── golden_cases.R
│   └── stress_cases.R
└── docs/              Logo, Hex-Sticker, Dashboard-Abbildungen
```

Jede Fassung ist ein eigenständiges Paket mit eigener Versionsnummer
(R: `r/DESCRIPTION`, Python: `python/pyproject.toml`, Julia:
`julia/Project.toml`). Die Änderungen je Version stehen in
[`r/NEWS.md`](r/NEWS.md), [`python/NEWS.md`](python/NEWS.md) und
[`julia/NEWS.md`](julia/NEWS.md); Hinweise für die Weiterentwicklung der
Ports in [`python/DEVELOPING.md`](python/DEVELOPING.md) und
[`julia/DEVELOPING.md`](julia/DEVELOPING.md). Wer `golden/` ändert, prüft
beide Ports mit den Testsuiten unten.

**Tests ausführen:**

<details>
<summary><b>R</b></summary>

``` r
devtools::test("r")
# oder vollständig:
rcmdcheck::rcmdcheck("r")
```

</details>

<details>
<summary><b>Python</b></summary>

``` bash
cd python
pip install ".[test]"
pytest                                  # 5.755 Tests, alle bestanden
python tools/compare_golden.py          # Engine: golden/cases und golden/extra (105 Fälle)
python tools/compare_reference.py       # alle Funktionen: golden/modules (4.536 Fälle)
```

Die Suite enthält 4.536 Modul-Referenzfälle und die 105 Golden-Master-Fälle
der Engine; die übrigen Tests prüfen Engine und R-Interna. Einzelne Module
oder Fälle prüft `python tools/compare_reference.py <modul> [-k id] [-v]`
bzw. `python tools/compare_golden.py [ordner …] [-k fall …] [-v]`. Auf
Plattformen ohne 80-Bit-`long double` werden die Bitgleichheits-Tests
übersprungen.

</details>

<details>
<summary><b>Julia</b></summary>

``` bash
cd julia
julia --project -e 'using Pkg; Pkg.test()'                     # 929 Tests, alle bestanden
SIMLEV_FULL_TESTS=1 julia --project -e 'using Pkg; Pkg.test()' # dazu alle 4.536 Modul-Referenzfälle
julia --project tools/compare_golden.jl ../golden/cases        # Engine: ein Ordner (auch ../golden/extra)
julia --project tools/compare_reference.jl                     # alle Funktionen: golden/modules (4.536 Fälle)
```

`Pkg.test()` prüft die 105 Golden-Master-Fälle der Engine vollständig
(strikt, NA ≠ NaN), von den Modul-Referenzfällen eine Auswahl von bis zu
vier je Modul, dazu `F80`, Engine, Ausgabe und den Auswerter für
Bedingungen. Einzelne Module oder Fälle prüft
`julia --project tools/compare_reference.jl <modul> [-k id] [-v]` bzw.
`julia --project tools/compare_golden.jl <ordner> [fall …]`.

</details>

Die Tests finden die Referenzfälle über den relativen Pfad `../golden`.
Liegen sie woanders, setzen Sie die Umgebungsvariable `SIMLEV_GOLDEN_DIR`
(Python zusätzlich `SIMLEV_MODULE_DIR` für `golden/modules`; in Julia
nimmt `tools/compare_reference.jl` den Ordner über `--dir`).

**Neue Referenzfälle** erzeugen Sie mit R, dem R-Paket SimLev und
`jsonlite` (`golden/golden_cases.R`, `golden/stress_cases.R` und
`golden/modules/gen_<modul>.R`); Details stehen in
[`golden/README.md`](golden/README.md).

## Hilfe und Mitwirken

Fragen, Fehlerberichte und Verbesserungsvorschläge sind willkommen, am
besten als [Issue](https://github.com/chemicalstats/SimLev-Repos/issues). Bitte
geben Sie an, welche Sprachfassung Sie nutzen. Ein Fehler in der
Steuerlogik betrifft meist alle drei. Damit ein Problem schnell
nachvollzogen werden kann, hilft ein **minimales reproduzierbares
Beispiel**: ein kleiner, synthetischer Datensatz (wie im Schnellstart), die
verwendete Strategie und der genaue `simulation()`-Aufruf.

Wenn Sie Code beitragen, führen Sie vor einem Pull Request bitte die Tests
der betroffenen Sprache aus. Änderungen an der Rechenlogik gehören in alle
drei Fassungen und müssen die Golden-Master-Fälle weiter bitgleich
bestehen.

## Lizenz

SimLev steht unter der **GNU General Public License, Version 3** (GPL-3).
Den vollständigen Lizenztext finden Sie in [LICENSE.md](LICENSE.md).

In der Praxis bedeutet das:

- Sie dürfen SimLev **frei nutzen**, privat, in der Forschung und
  kommerziell, den Quellcode studieren und an Ihre Bedürfnisse anpassen.
- Sie dürfen SimLev **weitergeben**, auch in veränderter Form.
- Wenn Sie SimLev oder eine veränderte Fassung **weitergeben**, muss das
  unter derselben Lizenz und zusammen mit dem Quellcode geschehen
  (*Copyleft*). Änderungen müssen als solche gekennzeichnet sein.
- Die Software wird **ohne jede Gewährleistung** bereitgestellt.

Rein interne Nutzung, etwa für eigene Analysen, löst keine Pflichten aus.
Diese Zusammenfassung dient der Orientierung. Rechtlich maßgeblich ist allein
der englische Lizenztext.

© 2026 ChemicalStats von der Mauerstrasse
