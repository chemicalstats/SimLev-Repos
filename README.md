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
der aktuellen R-Fassung 0.5.0 mit allen Erweiterungen. Alle drei rechnen
Zufall und Numerik mit derselben eigenen C-Bibliothek und liefern
**bitgleiche** Ergebnisse: Jeder Tageswert, jede Kennzahl, jeder
Steuerbetrag und auch die (deutsche) Textausgabe stimmen exakt überein
(siehe [Gleichlauf](#gleichlauf-der-drei-sprachen)). SimLev enthält keinen
Code aus fremden Paketen; die Verfahren und ihre Quellen stehen im
Abschnitt [Literatur](#literatur). Frühere Fassungen der Ports
(0.1.0) enthielten nur die Engine und entsprachen einem früheren Stand des
R-Pakets vor den Korrekturen (Commit 54b5b4f, damals ebenfalls als 0.5.0
bezeichnet; im Folgenden „Stand 54b5b4f“).

| Fassung | Ordner | Benötigt | Besonderheit |
|---|---|---|---|
| **R** | [`r/`](r/) | R ≥ 4.0, C- und C++-Compiler, keine externen Pakete | Referenzimplementierung |
| **Python** | [`python/`](python/) | Python ≥ 3.10, `numpy`, `pandas`, C- und C++-Compiler | vollständiger Port von R 0.5.0 einschließlich aller Erweiterungen, bitgleich unter Linux x86-64; dieselben C-Kerne wie R |
| **Julia** | [`julia/`](julia/) | Julia ≥ 1.10, C-Compiler, keine externen Pakete | vollständiger Port von R 0.5.0 einschließlich aller Erweiterungen, bitgleich unter Linux x86-64; nur Standardbibliothek, Engine etwa 5- bis 30-mal so schnell wie R |

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
- [Gleichlauf der drei Sprachen](#gleichlauf-der-drei-sprachen)
- [Geschwindigkeit](#geschwindigkeit)
- [Wie die Engine arbeitet](#wie-die-engine-arbeitet)
- [Grenzen und wichtige Hinweise](#grenzen-und-wichtige-hinweise)
- [Aufbau des Repositorys und Entwicklung](#aufbau-des-repositorys-und-entwicklung)
- [Hilfe und Mitwirken](#hilfe-und-mitwirken)
- [Literatur](#literatur)
- [Lizenz](#lizenz)

## Auf einen Blick

| Bereich | Was SimLev kann |
|---|---|
| **Handelslogik** | Buy-and-Hold, signalgesteuerte Ein- und Ausstiege, gestaffelte Asset-Starts, Bruchstücke oder ganze Anteile |
| **Kapitalflüsse** | Einmalanlage, Sparpläne (monatlich, quartalsweise, jährlich), wahlweise mit Mini-Rebalancing über die Sparrate |
| **Rebalancing** | Kalenderbasiert, mit Toleranzschwelle oder ereignisbasiert (Hebel- und Volatilitäts-Trigger) |
| **Kosten** | Bid-Ask-Spread je Asset (Standard 0), Order- und Sparplangebühren |
| **Steuern** | InvStG-Fondsbesteuerung, Abgeltungsteuer nach § 20 EStG, private Veräußerungsgeschäfte nach § 23 EStG |
| **Kennzahlen** | CAGR, TTWROR, Volatilität, Sharpe, Sortino, Calmar, Omega, Ulcer Index, Drawdown-Dauer u. v. m. |
| **Visualisierung** | Statisches Dashboard (R: Base-Grafik, Python und Julia: SVG ohne Zusatzpaket, mit den dargestellten Daten für eigene Grafiken) |
| **Backcast** | Rückrechnung von ETF/ETP-Historien aus Basisindex, TER-Reihe, Hebel und Tagesgeld; Fit der Abweichung mit Out-of-Sample-Test |
| **Bootstrap** | 14 Verfahren (Block, stationär, Regime, EVT, (GJR-)GARCH, MS-GARCH …), Hebelprodukte, Strategie-Studien über Hunderttausende Pfade |
| **Entnahmephase** | 14 Entnahmeregeln (4-%-Regel, Vanguard, Guyton-Klinger …) auf Kohorten, Bootstrap-Pfaden oder gespeicherten Simulationsergebnissen, mit vereinfachter deutscher Steuer |
| **Analyse** | `result_analysis()`: Alpha, Beta, Capture, Tracking Error, Information Ratio, M², VaR/CVaR, MWRR, Rendite- und Monatstabellen, Drawdown-Tabelle, rollierende Kennzahlen; Sensitivitäten für Rebalancing, Lump Sum vs. DCA und Hebel |
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

SimLev läuft ab Python 3.10 (geprüft ab Python 3.10, zuletzt mit Python
3.13). Zum Installieren brauchen Sie einen C- und C++-Compiler (C99, C++17)
und die Python-Header: `pip` übersetzt dabei die C-Erweiterung
`simlev._ext` mit der C-Bibliothek und den Rechenkernen von SimLev (unter
Linux `gcc`/`g++` bzw. `build-essential` und z. B. `python3-dev`, unter
macOS die Xcode Command Line Tools, unter Windows die Build Tools für
Visual Studio). Ohne Compiler bricht die Installation ab.

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
| `numpy`, `pandas` | Datenhaltung und Datenaufnahme | ja |
| C- und C++-Compiler | Bau der C-Erweiterung `simlev._ext` | ja |
| `pytest` | Rauchproben (`tests/`) | optional |

</details>

<details>
<summary><b>Julia</b></summary>

Benötigt wird **Julia ab Version 1.10** (geprüft ab Julia 1.10, zuletzt mit
Julia 1.13.2). Weitere
Pakete sind nicht nötig, nur die Standardbibliothek. Beim Installieren
(`Pkg.add`, `Pkg.build`) übersetzt `deps/build.jl` die C-Bibliothek von
SimLev; dafür muss ein C-Compiler vorhanden sein (`cc`, `gcc` oder `clang`,
ein anderer über `ENV["SIMLEV_CC"]`).

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
  WORLD = asset_config("etf", trading = "bnh",
                       share = 0.7, spread = 0.1, partial_exemption = 30),
  BONDS = asset_config("etf", trading = "bnh",
                       share = 0.3, spread = 0.1, partial_exemption = 0)
)

# 3. Simulation
result <- simulation(
  data, strategy,
  start_value = 10000,
  rebalance   = rebalance_plan(1, unit = "year"),
  tax         = tax_profile(26.375),
  liquidate   = TRUE,
  risk_free   = 2
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
17.765,20 EUR, also 5,93 % pro Jahr. Ohne Steuern (`tax = NULL`) wären
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
    WORLD=simlev.asset_config(asset_class="etf", trading="bnh", share=0.7, spread=0.1, partial_exemption=30),
    BONDS=simlev.asset_config(asset_class="etf", trading="bnh", share=0.3, spread=0.1, partial_exemption=0),
)

# 3. Simulation
result = simlev.simulation(
    data, strategy,
    start_value=10000,
    rebalance=simlev.rebalance_plan(span=1, unit="year"),
    tax=simlev.tax_profile(rate=26.375),
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
(`tax=None`) wären es 21.015,24 EUR (7,72 % p. a.) gewesen.

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
    WORLD = asset_config("etf", "bnh"; share = 0.7, spread = 0.1, partial_exemption = 30),
    BONDS = asset_config("etf", "bnh"; share = 0.3, spread = 0.1, partial_exemption = 0),
)

# 3. Simulation
result = simulation(data, strategy;
    start_value = 10000,
    rebalance = rebalance_plan(1; unit = "year"),
    tax = tax_profile(26.375),
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
(`tax = nothing`) wären es 16.339,67 EUR (5,04 % p. a.) gewesen.

<p align="center">
  <img src="docs/figures/dashboard-julia.png" alt="SimLev-Dashboard aus Julia" width="100%" />
</p>

</details>

**Warum unterscheiden sich die Zahlen?** Jede Sprache erzeugt die
synthetischen Kurse hier mit ihrem eigenen Zufallsgenerator (R `rnorm()`,
numpy, Julias `MersenneTwister`), die Preisreihen sind also verschieden.
Mit identischen Eingabedaten liefern alle drei Fassungen exakt dasselbe
Ergebnis: Mit den Kursen des R-Beispiels zeigen auch Python und Julia
17.765,20 EUR Endwert und 1.368,47 EUR Steuern, ebenso liefern R und Julia
mit den Kursen des Python-Beispiels 19.193,75 EUR und R und Python mit den
Kursen des Julia-Beispiels 15.581,60 EUR (Kurse jeweils als CSV mit voller
Genauigkeit übergeben).

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
gefüllt, führende fehlende Kurse wirken wie ein späterer `start`, und
doppelte Datumswerte oder Kurse ≤ 0 führen zu einer Fehlermeldung.

### Die Prozent-Konvention

Alle Raten und Schwellen werden **in Prozent** angegeben, nicht als
Dezimalzahl. Das ist die häufigste Fehlerquelle beim Einstieg:

| Argument | Beispiel | Bedeutung |
|---|---|---|
| `tax_profile(rate)` | `26.375` | 25 % Abgeltungsteuer + 5,5 % Solidaritätszuschlag darauf |
| `spread` | `0.1` | 0,1 % voller Bid-Ask-Spread (je Kauf/Verkauf die Hälfte) |
| `partial_exemption` | `30` | 30 % Teilfreistellung |
| `rebalance_plan(thresh)` | `5` | Rebalancing erst ab 5 % Gewichtsabweichung |
| `tax_profile(base_rate)` | `2.55` | 2,55 % Basiszins für die Vorabpauschale |
| `risk_free` | `2` | 2 % risikoloser Zins p. a. |
| `income_rate(marginal_rate)` | `42` | 42 % persönlicher Grenzsteuersatz |

Einzige Ausnahme sind die Zielgewichte `share`. Jedes liegt zwischen
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
  WORLD = asset_config("etf", trading = "bnh", share = 0.6,
                       spread = 0.10, partial_exemption = 30),
  EM    = asset_config("etf", trading = "bnh", share = 0.2,
                       spread = 0.20, partial_exemption = 30),
  GOLD  = asset_config("etc", trading = "bnh", share = 0.2,
                       deliverable = TRUE)
)

strategy_validate(strategy, data)   # prüft zusätzlich, ob alle Spalten in data existieren
```

</details>

<details>
<summary><b>Python</b></summary>

``` python
strategy = simlev.create_strategy(
    WORLD=simlev.asset_config(asset_class="etf", trading="bnh", share=0.6, spread=0.10, partial_exemption=30),
    EM=simlev.asset_config(asset_class="etf", trading="bnh", share=0.2, spread=0.20, partial_exemption=30),
    GOLD=simlev.asset_config(asset_class="etc", trading="bnh", share=0.2, deliverable=True),
)

simlev.strategy_validate(strategy, data=data)   # prüft zusätzlich, ob alle Spalten in data existieren
```

</details>

<details>
<summary><b>Julia</b></summary>

Die ersten fünf Argumente von `asset_config` (`asset_class`, `trading`,
`share`, `spread`, `partial_exemption`) dürfen wie in R positionell
oder als Schlüsselwort übergeben werden.

``` julia
strategy = create_strategy(
    WORLD = asset_config("etf", "bnh", 0.6, 0.10, 30),
    EM    = asset_config("etf", "bnh", 0.2, 0.20, 30),
    GOLD  = asset_config("etc"; share = 0.2, deliverable = true),
)

strategy_validate(strategy, data)   # prüft zusätzlich, ob alle Spalten in data existieren
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

Bestehende Strategien verändern Sie mit `strategy_add_asset()`, `strategy_update_asset()` und
`strategy_remove_asset()`, die jeweils eine neue Strategie zurückgeben. Ältere,
als einfache Listen definierte Strategien akzeptiert `simulation()` direkt;
die veralteten Klassen `"etn_standard"` und `"etn_deliverable"` setzt
`asset_config()` mit einer Warnung in `"etn"` mit `deliverable` um.

### Buy-and-Hold und Signalstrategien

Mit `trading = "bnh"` wird ein Asset am ersten Tag gekauft und
gehalten. Käufe und Verkäufe entstehen danach nur noch durch Sparraten,
Rebalancing oder Liquidation.

**Gestaffelte Starts:** Mit `start` in `asset_config()` wird ein Asset
erst ab einem Datum handelbar. Bis dahin liegt das Kapital in den bereits
handelbaren Assets. Am Starttag wird auch ohne `rebalance` auf
die Zielgewichte umgeschichtet, damit das neue Asset Mittel erhält; beginnt
eine Kursreihe mit fehlenden Werten, gilt ihr erster Kurs als `start`,
und ein `start` nach dem letzten Datentag ist ein Fehler.

Mit `trading = "signal"` steigt das Asset ein und aus, wann immer Ihre
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
  WORLD = asset_config("etf", trading = "signal",
                       share = 1, spread = 0.1, partial_exemption = 30,
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
    WORLD=simlev.asset_config(asset_class="etf", trading="signal", share=1, spread=0.1, partial_exemption=30,
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
  dca = dca_plan(250, 1, unit = "month",
                 fill_deficits = TRUE),   # Sparrate füllt zuerst untergewichtete Assets auf
  rebalance = rebalance_plan(1, unit = "year"),
  tax = tax_profile(26.375),
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
    dca=simlev.dca_plan(250, 1, unit="month",
                        fill_deficits=True),   # Sparrate füllt zuerst untergewichtete Assets auf
    rebalance=simlev.rebalance_plan(span=1, unit="year"),
    tax=simlev.tax_profile(rate=26.375),
    liquidate=True,
)
```

</details>

<details>
<summary><b>Julia</b></summary>

``` julia
result_dca = simulation(data, strategy;
    start_value = 10000,
    dca = dca_plan(250, 1; unit = "month",
                   fill_deficits = true),     # Sparrate füllt zuerst untergewichtete Assets auf
    rebalance = rebalance_plan(1; unit = "year"),
    tax = tax_profile(26.375),
    liquidate = true)
```

</details>

Ohne `fill_deficits` (Standard) wird jede Rate fest nach den Zielgewichten
aufgeteilt. Mit `fill_deficits` wirkt sie wie ein kleines Rebalancing: Sie
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
simulation(data, strategy, rebalance = rebalance_plan(1, unit = "quarter"))

# mit Toleranzschwelle: nur handeln, wenn ein Gewicht > 5 % abweicht
simulation(data, strategy, rebalance = rebalance_plan(1, unit = "year", thresh = 5))

# relatives Band: Ziel 40 % darf zwischen 30 % und 50 % liegen
simulation(data, strategy, rebalance = rebalance_plan(1, unit = "month", thresh = 25,
                                                      thresh_type = "relative"))

# ereignisbasiert; data$sigma_ewma enthält eine selbst berechnete Volatilitätsschätzung
data <- rebalance_trigger(data, type = "vol_band", threshold = 20, vol_col = "sigma_ewma")
simulation(data, strategy, rebalance = rebalance_plan(event_col = "rebal_trigger",
                                                      event_mode = "replace",   # oder "additional" zum Kalender
                                                      skip = TRUE))             # nur an Ereignistagen
```

Kommentierte Vorlagen für eigene Trigger-Regeln finden Sie in
[`r/inst/examples/rebal_trigger_cookbook.R`](r/inst/examples/rebal_trigger_cookbook.R)
(im installierten Paket: `system.file("examples", "rebal_trigger_cookbook.R", package = "SimLev")`).

</details>

<details>
<summary><b>Python</b></summary>

``` python
# kalenderbasiert
simlev.simulation(data, strategy, rebalance=simlev.rebalance_plan(span=1, unit="quarter"))

# mit Toleranzschwelle: nur handeln, wenn ein Gewicht > 5 % abweicht
simlev.simulation(data, strategy, rebalance=simlev.rebalance_plan(span=1, unit="year", thresh=5))

# relatives Band: Ziel 40 % darf zwischen 30 % und 50 % liegen
simlev.simulation(data, strategy, rebalance=simlev.rebalance_plan(span=1, unit="month", thresh=25,
                                                                  thresh_type="relative"))

# ereignisbasiert; data["sigma_ewma"] enthält eine selbst berechnete Volatilitätsschätzung
data = simlev.rebalance_trigger(data, type="vol_band", threshold=20, vol_col="sigma_ewma")
simlev.simulation(data, strategy, rebalance=simlev.rebalance_plan(event_col="rebal_trigger",
                                                                  event_mode="replace",   # oder "additional" zum Kalender
                                                                  skip=True))             # nur an Ereignistagen
```

</details>

<details>
<summary><b>Julia</b></summary>

``` julia
# kalenderbasiert
simulation(data, strategy; rebalance = rebalance_plan(1; unit = "quarter"))

# mit Toleranzschwelle: nur handeln, wenn ein Gewicht > 5 % abweicht
simulation(data, strategy; rebalance = rebalance_plan(1; unit = "year", thresh = 5))

# relatives Band: Ziel 40 % darf zwischen 30 % und 50 % liegen
simulation(data, strategy; rebalance = rebalance_plan(1; unit = "month", thresh = 25,
                                                      thresh_type = "relative"))

# ereignisbasiert; data.sigma_ewma enthält eine selbst berechnete Volatilitätsschätzung
data = rebalance_trigger(data, "vol_band"; threshold = 20, vol_col = "sigma_ewma")
simulation(data, strategy; rebalance = rebalance_plan(; event_col = "rebal_trigger",
                                                      event_mode = "replace",   # oder "additional" zum Kalender
                                                      skip = true))             # nur an Ereignistagen
```

</details>

`rebalance_trigger()` erzeugt eine logische Spalte, die Sie über
`rebalance_plan(event_col = )` an die Simulation übergeben. Gerade bei gehebelten Strategien
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
aus, die sich aufsummieren. Optional legt `rebalance_plan(event_weight = )` die Zielgewichte
an Event-Tagen aus Datenspalten fest.

### Besteuerung

Über den Baustein `tax` wählen Sie eines von zwei Modellen:

| Angabe | Bedeutung |
|---|---|
| keine (`tax = NULL`) | Keine Steuern, also die reine Brutto-Performance |
| `tax = tax_profile()` | Besteuerung eines deutschen Privatanlegers mit vollständiger FIFO-Lotverwaltung |

Den früheren Fondsmodus (`simulation(funds = funds_costs())`) gibt es nicht
mehr; sein Nachfolger ist der Fonds-Wrapper (nächster Abschnitt).

### Fonds-Wrapper (Zertifikat oder Fonds über eine innere Strategie)

Ein Wrapper ist **ein** Asset der Strategie. Innen handelt eine eigene
Strategie mit Umschichten und optional Ordergebühren; es fallen
Verwaltungsgebühr und Performancegebühr an. Außen kauft und verkauft der
Anleger Anteile mit eigenem Spread und eigenen Gebühren und zahlt Steuern wie
auf ein Einzelpapier:

```r
inner <- wrapper_config(
  create_strategy(Welt = asset_config("etf", share = 0.7), Gold = asset_config("etc", share = 0.3)),
  rebalance = rebalance_plan(unit = "quarter"),
  costs     = funds_costs(fee = 0.95, performance_fee = 5))
strategy <- create_strategy(
  Zertifikat = asset_config("certificate", share = 0.8, spread = 0.5, wrapper = inner),
  Cash_ETF   = asset_config("etf", share = 0.2, partial_exemption = 30))   # optional daneben
```

`simulation()` rechnet
vor der Engine den Anteilswert aus den Spalten `Welt` und `Gold`
(`wrapper_nav()`): Verwaltungsgebühr täglich je Kalendertag,
Performancegebühr täglich gegen die High-Water-Mark abgegrenzt und am letzten
Datentag jedes Jahres festgeschrieben. Der Name `Zertifikat` ist dabei keine
Kursspalte. Ob der Wrapper steuerlich eine Kapitalforderung
(`asset_class = "certificate"`) oder ein Investmentfonds
(`tax_regime = "investment_fund"` mit Teilfreistellung und Vorabpauschale)
ist, legen Sie selbst fest. Bootstrap-Studien und Parametersuchen ziehen bzw.
variieren die inneren Spalten und rechnen den Anteilswert je Lauf neu.
Einzelheiten: `?wrapper_config`, `?wrapper_nav` und Abschnitt „Fonds-Wrapper“
in `?simulation`. Python und Julia haben dieselbe Schnittstelle
(`wrapper_config`, `wrapper_nav`, `asset_config(wrapper = …)`) und rechnen
bitgleich.

Die folgende Beschreibung gibt den Stand der aktuellen R-Engine 0.5.0
wieder; Python 0.5.0 und Julia 0.5.0 rechnen bitgleich genauso. Was sich
gegenüber dem Stand 54b5b4f geändert hat, steht in
[`r/NEWS.md`](r/NEWS.md).

Mit `tax_profile()` bildet SimLev unter anderem folgende Regeln ab:

- **Teilfreistellung** (§ 20 InvStG): Bei Aktien-ETFs bleiben 30 %, bei
  Mischfonds 15 % der Erträge steuerfrei. Den Satz geben Sie je Asset über
  `partial_exemption` an.
- **Vorabpauschale** (§ 18 InvStG): Für thesaurierende Fonds wird jährlich
  ein fiktiver Mindestertrag besteuert. Je am 31.12. gehaltenem Lot beträgt
  er 70 % des Basiszinses auf den Kurs zu Jahresbeginn, höchstens aber den
  Wertzuwachs im Kalenderjahr (Kurs am 31.12. minus Kurs zu Jahresbeginn).
  Beides gilt auch für Anteile, die erst im Lauf des Jahres gekauft wurden;
  sie tragen danach nur (13 − Erwerbsmonat) / 12 dieses Betrags. Der
  Basiszins kommt aus `tax_profile(base_rate = )`: fest als Zahl oder als
  Name einer Datenspalte; maßgeblich ist der Wert vom ersten
  Handelstag des Jahres. Die Vorabpauschale gilt am ersten Handelstag des
  Folgejahres als zugeflossen und wird dort vor den Trades des Tages mit dem
  Sparer-Pauschbetrag und dem Verlusttopf *des Folgejahres* abgerechnet;
  endet die Simulation vorher, am letzten Tag. Reicht das Cash nicht,
  werden Anteile verkauft (bei `fractions = FALSE` auf ganze Stück
  aufgerundet). Bereits versteuerte Vorabpauschalen mindern später den
  Veräußerungsgewinn (§ 19 InvStG).
- **Sparer-Pauschbetrag**: Jährlich bleiben 1.000 EUR Kapitalerträge
  steuerfrei, einstellbar über `tax_profile(sparer_pauschbetrag = )` (für
  Ehepaare z. B. `2000`, `0` = ohne Pauschbetrag).
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
  entweder als fester Satz (`income = income_rate(marginal_rate)`) oder, mit
  `income = income_tariff(taxable_income)`, exakt nach dem
  Einkommensteuertarif (siehe unten), und eine Freigrenze von 1.000 EUR
  (`private_sale_threshold`). Sie wird auf den Jahressaldo *vor* dem
  Verlustvortrag angewendet: Erreicht der Saldo die Grenze (genau 1.000 EUR
  eingeschlossen), ist der *gesamte* Saldo abzüglich Verlustvortrag
  steuerpflichtig, darunter ist er steuerfrei und der Vortrag bleibt
  unverändert. Die Steuer wird vom Depot bezahlt, am Abrechnungstag der
  Vorabpauschale (erster Handelstag des Folgejahres), sonst am letzten Tag,
  aus dem Cash oder per Zwangsverkauf.
- **Günstigerprüfung** (§ 32d Abs. 6 EStG): Mit
  `tax_profile(guenstigerpruefung = TRUE)` wird der persönliche Steuersatz angewendet, wenn die Belastung
  einschließlich Zuschlagsteuern niedriger ist als die Abgeltungsteuer.
  Mit `income_rate(marginal_rate, soli_rate)` wird der Grenzsteuersatz ×
  (1 + Soli-Satz + Kirchensteuersatz) mit dem effektiven
  Abgeltungsteuersatz verglichen (Soli auf die Einkommensteuer nur mit
  `soli_rate` > 0) und der günstigere Satz durchgehend verwendet. Mit
  `income_tariff(taxable_income)` wird unterjährig die Abgeltungsteuer einbehalten und im
  Jahresabschluss mit der Tarifbelastung verglichen; die Differenz wird
  erstattet (siehe unten).
- **Umschichtungen**: Beim Rebalancing schätzt SimLev die Steuer auf den
  Verkauf mit freiem Sparer-Pauschbetrag, Verlusttopf, Anrechnung der
  Vorabpauschale und dem Satz der Günstigerprüfung und berücksichtigt das
  beim Asset liegende Cash. So wird nicht zu viel verkauft und am selben
  Tag zurückgekauft.

Zur Kirchensteuer (`tax_profile(church_tax = )`) siehe
[Gebühren, Kirchensteuer und Freibetrag](#gebühren-kirchensteuer-und-freibetrag).

**Einkommensteuertarif.** Mit `income_tariff(taxable_income)`, dem zu
versteuernden Einkommen *ohne* die Kapitalerträge und § 23-Gewinne der
Simulation in EUR je Kalenderjahr (eine Zahl für alle Jahre, ein nach
Jahren benannter Vektor oder `data.frame(year, taxable_income)`), rechnet
`simulation()` mit `tax_profile(income = income_tariff(...))` mit dem Einkommensteuertarif nach
§ 32a Abs. 1 EStG und dem Solidaritätszuschlag nach §§ 3, 4 SolZG
(Freigrenze 20.350 EUR, Milderungszone 11,9 %). Mitgeliefert ist die
Rechtslage ab VZ 2026 für die Einzelveranlagung (Grundtarif, kein
Splitting) in der Datei `inst/extdata/steuertarif.csv` (Python:
`simlev/data/steuertarif.csv`, Julia: `julia/data/steuertarif.csv`); ein anderer Tarif
wird über `income_tariff(taxable_income, tariff = "<Datei>")` bzw. `tax_tariff()` eingelesen.
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
- Ein fester Grenzsteuersatz entfällt dann: `income_rate()` und
  `income_tariff()` schließen sich aus (`income` nimmt genau einen der beiden).
  `tax_report$tariff_years` zeigt die Veranlagung je Jahr.

Vereinfachungen: Der Tarif gilt für alle Simulationsjahre, die
Kirchensteuer wird nicht gerundet und ohne Kinderfreibeträge (§ 51a EStG)
berechnet, ein Verlustrücktrag kommt nicht vor (Einzelheiten in
`?simulation`, Abschnitt „Einkommensteuertarif“). Mit `income_rate()`
rechnet die Engine wie oben mit dem festen Grenzsteuersatz.

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
  WORLD = asset_config("etf", trading = "bnh", share = 0.6, spread = 0.1, partial_exemption = 30),
  GOLD  = asset_config("etc", trading = "bnh", share = 0.4, spread = 0.2, deliverable = TRUE)
)
res <- simulation(data, strategy, start_value = 100000,
  rebalance = rebalance_plan(1, unit = "month", thresh = 3),
  tax = tax_profile(base_rate = 2.55, church_tax = 9, guenstigerpruefung = TRUE,
                    income = income_tariff(14000)),
  liquidate = TRUE)

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

**Modellphilosophie:** SimLev projiziert die *heutige* Rechtslage in die
Vergangenheit, also aktuellen Pauschbetrag, aktuelle
Teilfreistellungssätze und aktuelle Freigrenzen. Ein Backtest beantwortet
damit die Frage *„Wie hätte meine Strategie abgeschnitten, wenn ich damals
zu den heutigen Konditionen investiert hätte?“*. Er berechnet nicht, welche
Steuer damals tatsächlich angefallen wäre. So bleiben Zeiträume vor und
nach Steuerreformen direkt vergleichbar.

### Splits bei gehebelten Produkten

Manche Hebelprodukte führen Splits oder Zusammenlegungen durch, wenn ihr
Kurs eine bestimmte Grenze über- oder unterschreitet. Mit
`splits = split_rule(thresh)` (untere und obere Grenze, in R als `c(20, 400)`, in Python
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
parallel rechnet, rechnen auch die Ports parallel, mit derselben
Zufallssemantik und damit denselben Ergebnissen: Python mit Fork-Prozessen
(Linux und andere Unix-Systeme; unter Windows und macOS nacheinander), Julia
mit Threads, wenn es mit mehreren Threads gestartet ist (`julia -t auto` bzw.
`JULIA_NUM_THREADS`), sonst nacheinander.

Fast alle Funktionen rechnen um die Engine herum; die wenigen neuen
Optionen von `simulation()` (relative Rebalancing-Bänder, Ordergebühren,
Kirchensteuer, `harvest_rule()`) sind standardmäßig aus. Die
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
| **Eigene Daten einlesen** (z. B. `read.csv()` + `as.Date()`) | `series_check()`, `series_align()`, `series_align_macro()`, `series_convert_currency()`, `index_total_return()`, `series_deflate()`, `series_splice()`, `backcast_fit()`/`backcast()` |
| **Daten erzeugen** | `series_leverage()`, `index_bond()`, `index_money_market()`, `index_currency_hedged()`, `series_shift_return()`, `bootstrap()` + `bootstrap_data()`, `bootstrap_pooled()`, `scenario_copula()` |
| **Simulieren** | `simulation()` mit `asset_config()`/`create_strategy()` oder `strategy_from_weights()` (Einkommensteuertarif: `tax_tariff()`); `tactical_simulation()`, `bootstrap_study()`, `param_search()`, `sensitivity_grid()` |
| **Fertige Simulationen weiterverarbeiten** (auch mit `saveRDS()` gespeichert und später geladen, in Julia mit `Serialization`) | `result_analysis()`, `result_heatmap()`, `sharpe_test()`, `sharpe_min_track_record()`, `result_index()`, `withdrawal_paths()`/`withdrawal_simulation()`; Studien und Suchen: `bootstrap_probability()`, `overfit_pbo()`, `sharpe_deflated()`, `overfit_reality_check()`, `sharpe_haircut()` |

Die Argumentnamen sind über die Versionen gewachsen und nicht überall
einheitlich. Für das ganze Paket gilt:

- **Prozent** (`5` = 5 %): Steuersätze, Spreads, Gebühren, TER, Zinsen,
  Inflation, Entnahmeraten, Zielvolatilitäten und Toleranzbänder.
- **Anteile** (`0.05` = 5 %): Gewichte (`share`, `weights`,
  `lower`/`upper` der Optimierung, `base`, `min_exposure`/`max_exposure`)
  und Wahrscheinlichkeiten bzw. Quantile (`alpha`, `q`, `quantiles`,
  `prob`, `success`). Ausnahme: `stock_share` in `withdrawal_rule()` ist in
  Prozent.
- **Ergebnisse**: CAGR, Volatilität und Drawdown aus `simulation()`,
  `result_analysis()` und `bootstrap_study_metrics()` sind Anteile; die Renditen in
  `tail_regression()`, `tail_covar()` und den Szenario-Funktionen sind
  Prozent je Periode.
- **Wiederholungen** heißen `B` (Bootstrap in Tests und Abhängigkeiten),
  `n` (Pfade oder Szenarien) oder `n_sim` (`planning_goal()`);
  **Blocklängen** `block` (in Perioden) oder `L`/`block_length` (in Zeilen
  bzw. bei `bootstrap_pooled()` in Perioden).
- **`frequency`** ist die Periodenlänge der Renditen, **`every`** der
  Rhythmus der Gewichts-Erzeuger, **`rebalance`** in
  `tactical_simulation()` der Handelsrhythmus (Text) und in
  `scenario_crisis()` ein Schalter. In `simulation()` ist `rebalance` der
  Baustein `rebalance_plan()`.
- Das **Toleranzband** heißt `thresh` (`rebalance_plan()`), `tolerance`
  (`tactical_simulation()`) und `bands` (`sensitivity_rebalancing()`);
  `band` bei den Signalen ist dagegen eine Hysterese.
- **`horizon`** zählt in `planning_goal()` Perioden, in `signal_analysis()`
  Zeilen, in `planning_lumpsum_vs_dca()` Jahre, in `backcast_fit()`
  Produktbeobachtungen (Renditehorizont); in `withdrawal_simulation()` ist es
  ein Objekt aus `withdrawal_horizon()` oder eine Zahl in Jahren.
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
- **`partial_exemption`** ist die Teilfreistellung in Prozent.
- **`taxable_income`** (`income_tariff()`) ist das zu versteuernde Einkommen
  ohne die Erträge der Simulation in **EUR je Kalenderjahr**. In der
  Tarifdatei von `tax_tariff()` sind Zonengrenzen, Bezugswerte,
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
`tvtp_ms_garch` (GARCH, GJR-GARCH und die MS-Verfahren schätzen ihr
Modell selbst per Maximum Likelihood in der C-Bibliothek von SimLev, die
MS-Verfahren nach Haas, Mittnik und Paolella (2004); Quellen im Abschnitt
[Literatur](#literatur)), optional
mit ESS-gewichteter Gittersuche über Hyperparameter. `bootstrap_block_length()`
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
                            tax = tax_profile())
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
die Ansparphase mit `tax = tax_profile()` gerechnet (Element `open_lots`)
und rechnet auch die Entnahmephase mit `tax = tax_profile()`, übernimmt
SimLev 0.5.0 ohne eigenes `cost_basis` die einzelnen Lots und verkauft bei jeder
Entnahme je Asset die ältesten Lots zuerst (FIFO, mit Anrechnung der
Vorabpauschale wie in der Engine). Nicht ausdrücklich angegebene Werte
werden aus dem Ergebnis übernommen: `partial_exemption` (gemeinsame
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
bei `tax = tax_profile()` mit Warnung.

### Vertiefte Analyse und Sensitivitäten

`result_analysis()` wertet gespeicherte Ergebnisse von `simulation()` (einzeln
oder als benannte Liste) oder beliebige Kursreihen nachträglich aus, im
Umfang von Portfolio-Backtestern wie testfol.io. Grundlage ist der
zeitgewichtete Wertindex, Sparpläne verzerren die Renditen also nicht. Die
CAGR (TWR) von `result_analysis()` entspricht der TTWROR von `simulation()`,
die MWRR mit Sparplan der `cagr` von `simulation()` (dieselbe XIRR-Rechnung).

``` r
da <- result_analysis(list(Aktien = res_a, Mischung = res_b), benchmark = "Aktien", risk_free = 2)
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
`simulation()`-Argumente im Raster), `sensitivity_rebalancing()` (Frequenz,
Versatz, absolute oder relative Bänder), `planning_lumpsum_vs_dca()` (Einmalanlage
gegen gestreckten Einstieg über rollierende Starts, mit Gewinnquote, MLSA und
MLSD) und `sensitivity_leverage()` (Kennzahlen über den Hebel, optimaler
Hebel) die Engine wiederholt auf, wahlweise parallel. `series_leverage()`
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
overfit_pbo(ps)               # Probability of Backtest Overfitting (CSCV)
sharpe_deflated(ps)   # Sharpe Ratio nach Mehrfachtest-Korrektur
overfit_walk_forward(ps, train = 5, test = 1)
param_bootstrap(ps, hist, cfg, top = 5, method = "stationary", n = 500)
```

Eine einzelne Spitze im Raster ist oft Zufall. `param_plateau()` bewertet jeden
Punkt mit seinen Nachbarn; `overfit_pbo()` misst über alle Aufteilungen der Historie
in zwei Hälften, wie oft der In-Sample-beste Punkt Out-of-Sample unter dem
Median landet (Bailey, Borwein, López de Prado & Zhu 2017);
`sharpe_deflated()` vergleicht die beste Sharpe Ratio mit dem Maximum, das
man aus gleich vielen wertlosen Versuchen erwarten würde, mit einer
effektiven Versuchsanzahl aus der mittleren Korrelation der Punkte (Bailey &
López de Prado 2014); `overfit_walk_forward()` wählt in rollierenden
Trainingsfenstern und verkettet die folgenden Testfenster.

### Daten und Portfolios aufbereiten

``` r
dat <- series_align(us = msci_usd, fx = eurusd, fund = etf_kurse)    # Kalendertage, LOCF
series_check(dat)                                                    # Lücken, Spikes, Splits, stehende Kurse
dat <- series_convert_currency(dat, "us", "fx")                             # USD-Index in EUR
dat <- series_align_macro(dat, hvpi, "inflation", lag = 45, transform = "yoy")   # erst ab Veröffentlichung
dat <- series_align_macro(dat, zinskurve, "spread", lag = 1)
lang <- series_splice(fund = etf_kurse, backcast = bc_df, proxy = msci_usd)
portfolio_template("permanent", map = c(stocks = "world", long_bonds = "bund_lang",
                                        cash = "geldmarkt", gold = "gold_eur"))
```

`series_align()` legt Quellen mit unterschiedlichen Börsenkalendern auf
einen gemeinsamen Kalender, `series_check()` meldet Auffälligkeiten,
`series_align_macro()` ordnet Monats- oder Quartalswerte erst ab dem Tag ihrer
Veröffentlichung zu (sonst stecken Zukunftsinformationen in Signalen und
bedingten Analysen), `index_total_return()` und `series_deflate()` rechnen Kurs- in
Total-Return- bzw. reale Reihen um, `series_splice()` verkettet Reihen
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
tail_covar(dat, system = "portfolio", assets = c("aktien", "anleihen"), state = "spread")
dependence_validate(bootstrap(hist, cfg, "stationary", n = 200), hist)
stress <- regime_subset(hist, "inflation >= 4", min_run = 60)   # Stress-Bootstrap
```

| Baustein | Inhalt |
|---|---|
| `tail_dependence()` | empirische Koeffizienten λ unten/oben je Quantil, Exceedance-Korrelationen (Longin & Solnik 2001) |
| `copula_fit()` | Gauß, t, Clayton, Gumbel, Frank, rotierte Varianten für negative Abhängigkeit; Pseudo-ML, AIC, implizite Tail-Abhängigkeit |
| `dependence_dcc()` | DCC(1,1) nach Engle (2002); GARCH-Stufe, Filter und Schätzung in der C-Bibliothek von SimLev |
| bedingte Analyse | Kennzahlen je Regime, Differenz oberstes minus unterstes Regime mit stationärem Block-Bootstrap (Intervall, p-Wert) |
| `quantile_regression()`, `tail_regression()` | lineare Quantilsregression (MM-Algorithmus), Effekt der Drittvariablen je Quantil mit Block-Bootstrap-Fehlern |
| `tail_covar()` | CoVaR und ΔCoVaR nach Adrian & Brunnermeier (2016), optional zeitvariabel über Zustandsvariablen |
| `dependence_validate()` | erhalten Bootstrap-Pfade Korrelation und Tail-Abhängigkeit der Historie? |
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
w3 <- tactical_target_volatility(dat, c(aktien = 0.7, anleihen = 0.3), safe = "geldmarkt", target = 10)
# Bedingt: nur im obersten/untersten Volatilitätsfünftel vom Grundanteil 80 % abweichen
w3b <- tactical_conditional_volatility(dat, c(aktien = 1), safe = "geldmarkt", base = 0.8, upper = 0.8, lower = 0.2)
w4 <- tactical_glidepath(dat, from = c(aktien = 0.9, anleihen = 0.1), to = c(aktien = 0.4, anleihen = 0.6))
w5 <- tactical_blend(kern = w4, satellit = w2, shares = c(0.8, 0.2))
res <- tactical_simulation(dat, w5, rebalance = "month", tolerance = 5, lag = 1,
                           asset_args = list(partial_exemption = c(usa = 30, europa = 30, em = 30)),
                           tax = tax_profile(), dca = dca_plan(500, 1))
```

`lag = 1` handelt ein Signal vom Schlusskurs eines Tages am nächsten Tag;
`lag = 0` entspricht der Konvention vieler Online-Backtester.

`tactical_conditional_volatility()` steuert nur in extremen Phasen (Bongaerts, Kang &
van Dijk 2020): Liegt die geschätzte Volatilität über ihrem bisherigen
80-%-Quantil, sinkt der Risikoanteil auf `base × Vergleichsvola / Vola`;
unter dem 20-%-Quantil steigt er entsprechend, höchstens auf 100 %.
Dazwischen bleibt der Grundanteil. Quantile und Vergleichswert (Standard:
bisheriges Mittel) werden nur aus der Vergangenheit berechnet. Gegenüber
`tactical_target_volatility()` fallen deutlich weniger Umschichtungen an. Weil die
Engine keinen Kredit kennt, ist Hochskalieren nur bei `base < 1` möglich;
mit `scaling = "fixed"` gelten feste Anteile je Phase.

### Optimierung und Risikozerlegung

``` r
portfolio_optimize(dat, c("aktien", "anleihen", "gold"), method = "risk_parity")
portfolio_optimize(dat, assets, method = "max_sharpe", upper = 0.6, cov = "ledoit_wolf", resample = 200)
plot(portfolio_frontier(dat, assets))
portfolio_risk_contributions(dat, c(aktien = 0.6, anleihen = 0.3, gold = 0.1), measure = "cvar")
w <- portfolio_rolling(dat, assets, "min_variance", window = 3, every = "quarter")
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
`portfolio_risk_contributions()` zerlegt Volatilität oder CVaR additiv auf die
Anlagen.

### Anleihen, Geldmarkt und Währungssicherung

``` r
dat$bund10 <- index_bond(dat, "rendite_10j", maturity = 10, coupon_frequency = 1)
dat$geldmarkt <- index_money_market(dat, "ester", spread = 0.1)
dat$sp500_eur_h <- index_currency_hedged(dat, "sp500_usd", domestic_rate = "ester", foreign_rate = "sofr")
```

`index_bond()` bildet einen Total-Return-Index konstanter
Laufzeit aus einer Renditereihe (Kupon plus Neubewertung, wahlweise über
Duration und Konvexität; Swinkels 2019). `index_money_market()` verzinst
Act/360, `index_currency_hedged()` addiert die Zinsdifferenz einer
rollierenden Devisentermin-Absicherung.

### Gebühren, Kirchensteuer und Freibetrag

Drei optionale Angaben in den Bausteinen von `simulation()` bilden die
deutsche Praxis genauer ab; ohne sie rechnet die Engine wie ohne diese Optionen.

``` r
simulation(dat, strategie,
           costs = sim_costs(order_fee = list(fixed = 1),   # z. B. 1 EUR je Order beim Neobroker
                             dca_fee = 0),                  # Sparplan gebührenfrei
           tax = tax_profile(church_tax = 9,                # 9 % Kirchensteuer
                             harvest = harvest_rule("12-15")))   # Freibetrag jährlich ausschöpfen
```

Mit `church_tax` wird der Abgeltungsteuersatz nach § 32d Abs. 1 EStG
angepasst (bei 9 % rund 27,995 % statt 26,375 %; `rate` und `church_tax`
zusammen sind ein Fehler). Dabei wirkt die
Kirchensteuer auch auf die Einkommensteuer, also auf die § 23-Steuer und
den persönlichen Satz der Günstigerprüfung. Mit festem Grenzsteuersatz (`income_rate()`)
ist der Sonderausgabenabzug der Kirchensteuer dabei nicht abgebildet, mit
`income_tariff()` schon: Die Kirchensteuer ist Sonderausgabe im Jahr ihrer
Zahlung, Erstattungen werden verrechnet bzw. hinzugerechnet (siehe
[Besteuerung](#besteuerung)).

Gebühren erhöhen beim Kauf den Einstandskurs und mindern beim Verkauf den
Erlös, wirken also auch steuerlich; möglich sind feste und prozentuale
Gebühren mit Mindest- und Höchstbetrag. `harvest_rule()` realisiert einmal im
Jahr Gewinne bis zum noch freien Sparer-Pauschbetrag (und wahlweise bis zur
Höhe des Verlusttopfs) und kauft sofort zurück; das hebt den Einstandskurs
steuerfrei an. Spread und Gebühren für beide Orders fallen dabei an.

### Szenarien und Stresstests

``` r
# Wie sieht die Welt aus, wenn die Inflation im Mittel 4 % beträgt?
ep <- scenario_entropy_pooling(dat, c("aktien", "anleihen"), list(view_mean("inflation", 4)), states = "inflation")
scenario_risk(ep, c(aktien = 0.6, anleihen = 0.4))
# Was erwartet die Abhängigkeitsstruktur für Anleihen in den schlechtesten 5 % der Aktienwochen?
cs <- scenario_copula(dat, c("aktien", "anleihen"), stress = list(aktien = c(0, 0.05)))
scenario_crisis(dat, c(aktien = 0.6, anleihen = 0.4))   # 1973/74, 1987, 2000-02, 2008, 2011, 2020, 2022
```

`scenario_entropy_pooling()` gewichtet historische Szenarien so um, dass eigene
Annahmen (Mittelwerte, Wahrscheinlichkeiten, Volatilitäten) erfüllt sind, bei
minimaler Abweichung von der Historie (Meucci 2008). `scenario_copula()`
simuliert aus einer t-Copula mit empirischen Rändern, auf Wunsch bedingt auf
ein Quantilband einzelner Anlagen.

### Planung über lange Horizonte

``` r
hist_adj <- series_shift_return(hist, c("us", "eu"), target = 5)   # Renditeannahme statt Historie
pb <- bootstrap_pooled(list(usa = usa, de = de, jp = jp), c("aktien", "anleihen"),
                       weights = c(aktien = 0.6, anleihen = 0.4), inflation = "cpi", years = 40)
h  <- withdrawal_horizon("discrete", years = c(25, 30, 35, 40), prob = c(0.3, 0.4, 0.2, 0.1))
withdrawal_simulation(pb, withdrawal_rule("guyton_klinger", rate = 4), horizon = h)
planning_goal(portfolio_returns(usa, kandidaten), start_value = 1e5, goal = 3e5,
              horizon = 20, contributions = 6000)
```

Die Laufzeit der Entnahmephase kann fest sein oder einer eigenen Verteilung
folgen (gleichverteilt, diskret, normal, dreiecksförmig oder eine eigene
Stichprobe); es gibt bewusst keine eingebauten Sterbetafeln.
`planning_goal()` bestimmt per dynamischer Programmierung für jeden
Zeitpunkt und jedes Vermögen das Portfolio mit der höchsten Wahrscheinlichkeit,
ein Ziel zu erreichen (Das et al. 2020), auch für Entnahmen (Ziel 0 =
Geld reicht bis zum Horizont).

### Statistische Prüfungen und Regime

| Funktion | Frage |
|---|---|
| `sharpe_test(x, y)` | Unterscheiden sich zwei Sharpe Ratios wirklich? (Ledoit & Wolf 2008) |
| `overfit_reality_check(search)` | Schlägt die beste von vielen Strategien die Benchmark mehr als zufällig? (White 2000, Hansen 2005) |
| `sharpe_haircut(search)` | Wie viel der Sharpe Ratio erklärt die Zahl der Versuche? (Harvey & Liu 2015) |
| `sharpe_min_track_record(x)` | Wie lang muss eine Historie sein, damit die Sharpe Ratio belastbar ist? |
| `portfolio_cpcv(x, assets, methods)` | Wie verteilt sich die Out-of-Sample-Güte von Optimierern? (kombinatorische Kreuzvalidierung) |
| `signal_analysis(dat, signal, target)` | Was folgt typischerweise auf ein Signalniveau? |
| `regime_hmm(dat, columns)`, `regime_states()` | In welcher Marktphase sind wir (ohne Zukunftsdaten)? |
| `result_heatmap(x, inflation)` | Wie hängt die reale Rendite von Startjahr und Haltedauer ab? |

`result_analysis(..., inflation = 2)` rechnet alle Kennzahlen real.
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
| `tax_report` | Gezahlte Steuern, Verlustvorträge, genutzter Pauschbetrag und dessen Steuerersparnis; `open_tax_debt` (am Ende offene, nicht gedeckte Steuerschuld in EUR, sonst 0) und mit `income_tariff()` `tariff_years` (Veranlagung je Jahr); mit `tax_profile()` `next_year` (Steuerzustand des Jahres nach dem letzten Datentag: verbrauchter Sparer-Pauschbetrag, Verlusttöpfe, mit `income_tariff()` der letzte Kirchensteuer-Bescheid) für eine Fortsetzung, z. B. in der Entnahmephase |
| `undefined_metrics` | `data.frame(metric, reason, detail)` mit einer Zeile je Kennzahl, die `NA` ist (z. B. negativer Endwert, Einzeltag, Volatilität 0); `print()` und `summary()` zeigen sie als „nicht definiert (Ursache)“. Der Endwert bleibt unverändert, auch wenn er negativ ist |
| `open_lots` | *Nur mit `tax = tax_profile()` gefüllt, sonst `NULL`:* je Asset die am letzten Tag gehaltenen Lots (Kaufdatum, Stück, Anschaffungskurs, anzurechnende Vorabpauschale) mit Steuerregime, Teilfreistellung, Cash, `spread` und `order_fee`; `withdrawal_simulation(start_value = <Ergebnis>)` verkauft daraus per FIFO |
| `buys`, `sells` | Durchschnittliche Anzahl Käufe und Verkäufe pro Jahr je Asset (bei einem Einzeltag `NA`) |
| `fees_paid`, `harvest_days` | Summe der Ordergebühren (mit `sim_costs()`) und Termine der Gewinnrealisierung (mit `harvest_rule()`) |
| `trades` | *Nur Python und Julia:* alle Lots, Verkäufe und Steuerbuchungen (z. B. Vorabpauschalen) je Asset |

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

simlev.export_dashboard(result, filename="backtest.svg", width=16, height=10)
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
| `dca_plan(100, 1, days = 15)` | `simlev.dca_plan(100, 1, days=15)` | `dca_plan(100, 1; days = 15)` |
| `result$worth` | `result.worth` | `result.worth` |
| `result$statistics$sharpe` | `result.statistics["sharpe"]` | `result.statistics.sharpe` |
| `result$report$WORLD$total` | `result.report["WORLD"]["total"]` | `result.report["WORLD"].total` |
| `print(x)` | `print(x)` | `display(x)` |
| `summary(x)` | `simlev.summary(x)` oder `x.summary()` | `summary(result)`, allgemein `r_summary(x)` |
| `plot(x)` | `x.plot()` oder `simlev.plot(x)` | `plot_dashboard(result)`, allgemein `r_plot(x)` |
| `simlev_seed(42)` | `simlev.simlev_seed(42)` | `simlev_seed(42)` |
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
- **Zufall:** SimLev zieht in allen drei Sprachen aus seinem eigenen
  Generator; `simlev_seed()` setzt ihn, zufällige Funktionen nehmen
  `seed`. `set.seed()` in R und die Zufallszahlen von numpy oder Julia
  wirken auf SimLev nicht (siehe [Gleichlauf](#gleichlauf-der-drei-sprachen)).
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
- `simulation()` hat kein Argument `spread` (bis 6.2 war es wirkungslos und
  ergab nur eine Warnung). Spreads werden je Asset über
  `asset_config(spread = )` gesetzt; Standard ist 0 (ohne Spread).

Weitere sprachspezifische Hinweise stehen in den READMEs der Unterordner
[`r/`](r/README.md), [`python/`](python/README.md) und
[`julia/`](julia/README.md).

## Gleichlauf der drei Sprachen

„Gleichlauf“ heißt: Für dieselben Eingaben liefern R, Python und Julia
dieselben IEEE-754-Gleitkommazahlen, ohne jede Toleranz. Das gilt für
`simulation()` (alle Tageswerte, Kennzahlen, Steuerwerte, die Ausgabe von
`print(result)` und die Detailprotokolle von `details = TRUE`) und für alle
übrigen Funktionen (Ergebnisse, Druck- und Konsolenausgaben, Warnungen und
Fehlermeldungen). Geprüft wird streng: `NA` und `NaN` werden unterschieden
(in Python ist `simlev.NA` R's `NA`, ein gewöhnliches `nan` R's `NaN`), und
auch das Vorzeichen der Null muss stimmen.

Dafür sorgen zwei Dinge:

- **Eine gemeinsame C-Bibliothek.** Zufall, Verteilungen (Normal-, t-,
  Beta-, logistische Verteilung, `lgamma`), lineare Algebra
  (Matrixprodukt, Cholesky, Löser, symmetrische Eigenwerte, QR und kleinste
  Quadrate, Logit-IRLS), die Optimierer (BFGS, projizierter BFGS,
  Nelder-Mead), die Modelle (GARCH/GJR, GPD, DCC, MS-GARCH), die
  Bootstrap-Ziehungen, die Stineman-Interpolation, der Glättungsspline und
  die Kerndichte stehen einmal in [`core/`](core/) als eigener C-Code. R,
  Python und Julia übersetzen dieselben Quellen mit denselben
  Gleitkomma-Einstellungen (`-O2 -ffp-contract=off -fno-fast-math`) und
  rufen sie auf. Die Kerne der Engine (FIFO, Steuer, Markt-Updates) und die
  Rechenkerne von Entnahme, Abhängigkeiten, Optimierung und Signalen liegen
  ebenfalls in `core/`; R und Python nutzen sie direkt, Julia hat eigene
  Ports, die Zeile für Zeile übertragen sind. Die Quellen jedes Kerns
  stehen im Dateikopf und im Abschnitt [Literatur](#literatur).
- **R-Grundfunktionen in den Ports.** Wo SimLev Grundfunktionen von R
  nutzt, bilden Python (`simlev/_r/`) und Julia (`julia/src/r/`) sie nach:
  Summen und Mittel in 80-Bit-`long double` wie R (Python
  `numpy.longdouble`, Julia der eigene Typ `F80`, auf x86-64 über die
  x87-Hardware, sonst als Software-Nachbau), Potenzen mit R's Sonderregeln,
  mathematische Funktionen aus glibc-libm, Sortieren, Ränge, Quantile,
  `cor`, `approx`, `filter`, `optimize`, `uniroot`, `hclust`, `p.adjust`,
  Kalender, `round()`, `format()`, `sprintf()` und die Druckausgabe, dazu
  in beiden Ports ein Auswerter für Bedingungen in R-Syntax. Welche Teile
  das sind und woher sie stammen, steht in
  [`python/COPYRIGHTS.md`](python/COPYRIGHTS.md) und
  [`julia/COPYRIGHTS.md`](julia/COPYRIGHTS.md).

**Zufall.** SimLev hat einen eigenen Zufallsgenerator (xoshiro256** mit
SplitMix64-Seeding) in der C-Bibliothek, in allen drei Sprachen derselbe.
`simlev_seed(42)` (Python `simlev.simlev_seed(42)`) setzt seinen Zustand;
zufällige Funktionen nehmen außerdem ein Argument `seed`. Mit `seed = NULL`
zieht ein Aufruf genau einmal einen Startwert aus dem Zustand von SimLev,
mit `seed = 42` bleibt der Zustand unberührt. Jeder Pfad einer parallelen
Rechnung hat einen eigenen Strom; das Ergebnis hängt nicht von `cores`
ab. `set.seed()` in R und die Zufallszahlen von numpy oder Julia wirken
auf SimLev nicht; sie eignen sich weiter, um eigene Eingabedaten zu
erzeugen (wie im Schnellstart). Die Regeln stehen in `?simlev_seed`.

**So wird es geprüft:** Die Gleichlaufprüfung
[`tools/gleichlauf/run.sh`](tools/gleichlauf/run.sh) baut R, Python und
Julia, prüft, dass die Kopien der C-Quellen gleich sind
(`tools/core_sync.py --check`), erzeugt die Referenzfälle mit den
Generatoren in [`golden/modules/`](golden/modules/) und den
Engine-Generatoren [`golden/golden_cases.R`](golden/golden_cases.R) und
[`golden/stress_cases.R`](golden/stress_cases.R) mit dem aktuellen R-Paket
neu und vergleicht Python und Julia Bit für Bit dagegen. Der letzte
vollständige Lauf (`--full`, 27.10.2026) ergab in beiden Ports
4.260 von 4.260 Modul-Fällen und 1.182 von 1.182 Engine-Fällen gleich.
Die früheren Testsuiten und die gespeicherten Fälle in `golden/` stammen aus
der Zeit vor dem eigenen Zufall und den eigenen Kernen; sie sind bis zu
ihrem Neuaufbau ausgesetzt (siehe
[Aufbau des Repositorys und Entwicklung](#aufbau-des-repositorys-und-entwicklung)).

**Plattformen:** Geprüft ist Linux auf x86-64 mit glibc (R 4.3.3,
Python 3.13, Julia 1.13.2). Der Gleichlauf setzt dort 80-Bit-`long double`,
glibc-libm und denselben Compiler mit denselben Einstellungen für die
C-Bibliothek voraus. Unter macOS und Windows lassen sich die Pakete mit
einem C-Compiler bauen; dort ist der Gleichlauf nicht geprüft und nicht
zugesagt. Grafiken sind in den Ports nicht bitgleich, die berechneten
Daten schon.

**Zeichenketten-Reihenfolge.** R sortiert und vergleicht Zeichenketten
(`sort`, `order`, `rank`, `factor`-Stufen, `table`, `split`, `<`/`>`)
nicht nach Codepunkten, sondern mit der ICU-Kollation des Locales; unter
`LC_ALL=C.UTF-8` ist das der Collator „root“ (`a A ä b B`), unter
`LC_ALL=C` die Byte-Reihenfolge. Python (ctypes) und Julia (ccall) bilden
das mit der System-ICU nach (`libicui18n.so.<N>`, Debian/Ubuntu: Paket
`libicu<N>`; Pfad über `SIMLEV_ICU`) und richten sich wie R nach den
Locale-Variablen. `SIMLEV_COLLATE=C` erzwingt die Byte-Reihenfolge,
`SIMLEV_COLLATE=icu:root` die Reihenfolge von R unter `C.UTF-8`. Ohne ICU
wird nach Codepunkten verglichen, mit einer Warnung; Ergebnisse mit
Zeichen-Sortierung sind dann nicht gleich.

## Geschwindigkeit

Gemessen mit R 0.5.0, Python 0.5.0 und Julia 0.5.0 auf derselben Maschine
(Linux x86-64, zwei Kerne; R 4.3.3, Python 3.13, Julia 1.13.2), Mittel aus
fünf Läufen nach einem ersten Aufruf, Julia nach dem Vorkompilieren:

| Szenario | R | Python | Julia |
|---|---|---|---|
| 30 Jahre, 3 Assets (Aktien-ETF, Renten-ETF, ETC mit Lieferanspruch), Sparplan, jährliches Rebalancing, Steuern | 0,17 s | 0,12 s | **0,033 s** |
| 30 Jahre, Hebelzertifikat und Renten-ETF, Splits, ganze Anteile, Schwellen-Rebalancing (gemessen mit dem inzwischen entfernten Fondsmodus) | 0,17 s | 0,09 s | **0,012 s** |
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
  Block fort: in R und Python mit einem einzigen Aufruf des gemeinsamen
  C++-Kerns, in Julia in einer einfachen Schleife.

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
├── core/              C-Bibliothek von SimLev (Zufall, Verteilungen, lineare Algebra,
│                      Optimierer, Modelle, Bootstrap-Kerne) und die gemeinsamen
│                      C++-Kerne der Engine; Kopien in r/src, python/src/core, julia/deps/core
├── r/                 R-Paket (DESCRIPTION, R/, src/, man/, tests/, vignettes/)
├── python/            Python-Paket (pyproject.toml, simlev/ mit _r/, src/, tests/, tools/, examples/)
├── julia/             Julia-Paket (Project.toml, src/ mit r/, deps/, data/, test/, tools/, examples/)
├── golden/            Referenzfälle aus R und ihre Generatoren
│   ├── cases/, extra/ gespeicherte Engine-Fälle (Stand vor Etappe 9, ausgesetzt)
│   ├── modules/       Generatoren gen_<modul>.R und ref_tools.R (je Fall R-, Python-
│   │                  und Julia-Code); gespeicherte Fälle (Stand vor Etappe 9)
│   ├── golden_cases.R
│   └── stress_cases.R
├── tools/             Gleichlaufprüfung (gleichlauf/), core_sync.py, api_snapshot/, bench/
└── docs/              Logo, Hex-Sticker, Dashboard-Abbildungen, STRUKTUR.md
```

Jede Fassung ist ein eigenständiges Paket mit eigener Versionsnummer
(R: `r/DESCRIPTION`, Python: `python/pyproject.toml`, Julia:
`julia/Project.toml`). Die Änderungen je Version stehen in
[`r/NEWS.md`](r/NEWS.md), [`python/NEWS.md`](python/NEWS.md) und
[`julia/NEWS.md`](julia/NEWS.md); Hinweise für die Weiterentwicklung der
Ports in [`python/DEVELOPING.md`](python/DEVELOPING.md) und
[`julia/DEVELOPING.md`](julia/DEVELOPING.md), die Regeln für die
C-Bibliothek in [`core/README.md`](core/README.md). Die C-Quellen werden
nur in `core/` geändert; `python3 tools/core_sync.py --write` verteilt sie,
`--check` prüft die Kopien.

**Prüfen:** Die früheren Testsuiten und die gespeicherten Referenzfälle
beschreiben den Stand vor dem eigenen Zufall und den eigenen Kernen. Sie
sind bis zu ihrem Neuaufbau ausgesetzt; keine Testdatei ist gelöscht, mit
`SIMLEV_LEGACY_TESTS=1` laufen sie (und scheitern dort, wo sie entfallene
Teile nutzen). Ohne den Schalter laufen nur Rauchproben:

``` bash
Rscript r/tests/etappe9-smoke.R                              # R: Rauchproben (r/tests/etappe9*.R)
(cd python && python -m pytest tests)                        # Python: Rauchproben der C-Bibliothek
(cd julia && julia --project -e 'using Pkg; Pkg.test()')     # Julia: Testsatz „Etappe 9“
```

Maßgeblich ist bis dahin die **Gleichlaufprüfung** (siehe
[Gleichlauf](#gleichlauf-der-drei-sprachen)):

``` bash
LC_ALL=C.UTF-8 tools/gleichlauf/run.sh --quick     # jede 20. Fall-Kennung, kleine Engine-Läufe
LC_ALL=C.UTF-8 tools/gleichlauf/run.sh --full      # alle Fälle
LC_ALL=C.UTF-8 tools/gleichlauf/run.sh bootstrap   # nur ein Modul
```

Sie braucht R mit `jsonlite`, Python mit `numpy` und `pandas`, Julia und
einen C/C++-Compiler; das Ergebnis steht in `tools/gleichlauf/out/bericht.txt`.
`tools/api_snapshot/run.sh --check` prüft zusätzlich, dass die öffentliche
Schnittstelle der drei Sprachen unverändert ist.

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

Wenn Sie Code beitragen, führen Sie vor einem Pull Request bitte die
Rauchproben der betroffenen Sprache und die Gleichlaufprüfung aus.
Änderungen an der Rechenlogik gehören in alle drei Fassungen und müssen die
Gleichlaufprüfung bitgleich bestehen.

## Literatur

SimLev setzt die folgenden Verfahren selbst um. Zu jedem Eintrag steht, in
welcher Funktion SimLev das Verfahren nutzt. Alle Angaben sind geprüft:
beim Verlag, über Crossref bzw. die DOI-Auflösung, bei arXiv, auf den
Seiten der Autoren oder in Bibliothekskatalogen. Wo eine Quelle keinen DOI
hat, fehlt er auch hier.

### Bootstrap und Resampling

- Efron, B. (1979). Bootstrap methods: Another look at the jackknife.
  *The Annals of Statistics* 7(1), 1–26.
  [doi:10.1214/aos/1176344552](https://doi.org/10.1214/aos/1176344552)
  – `bootstrap()`, Verfahren `"raw"` (Ziehen einzelner Zeilen mit
  Zurücklegen).
- Künsch, H. R. (1989). The jackknife and the bootstrap for general
  stationary observations. *The Annals of Statistics* 17(3), 1217–1241.
  [doi:10.1214/aos/1176347265](https://doi.org/10.1214/aos/1176347265)
  – Verfahren `"block"` (Blöcke fester Länge).
- Politis, D. N., Romano, J. P. (1992). A circular block-resampling
  procedure for stationary data. In: R. LePage, L. Billard (Hrsg.),
  *Exploring the Limits of Bootstrap*. Wiley, 263–270. – Verfahren
  `"circular"`.
- Politis, D. N., Romano, J. P. (1994). The stationary bootstrap. *Journal
  of the American Statistical Association* 89(428), 1303–1313.
  [doi:10.1080/01621459.1994.10476870](https://doi.org/10.1080/01621459.1994.10476870)
  – Verfahren `"stationary"`, `bootstrap_pooled()`, die
  Block-Bootstraps in `sharpe_test(method = "bootstrap")`,
  `dependence_analysis()` und `tail_regression()`.
- Politis, D. N., White, H. (2004). Automatic block-length selection for
  the dependent bootstrap. *Econometric Reviews* 23(1), 53–70.
  [doi:10.1081/ETC-120028836](https://doi.org/10.1081/ETC-120028836)
  – `bootstrap_block_length()`.
- Patton, A., Politis, D. N., White, H. (2009). Correction to "Automatic
  block-length selection for the dependent bootstrap" by D. Politis and
  H. White. *Econometric Reviews* 28(4), 372–375.
  [doi:10.1080/07474930802459016](https://doi.org/10.1080/07474930802459016)
  – Korrektur in `bootstrap_block_length()`.
- Wu, C. F. J. (1986). Jackknife, bootstrap and other resampling methods
  in regression analysis. *The Annals of Statistics* 14(4), 1261–1295.
  [doi:10.1214/aos/1176350142](https://doi.org/10.1214/aos/1176350142)
  – Verfahren `"wild"`.
- Liu, R. Y. (1988). Bootstrap procedures under some non-i.i.d. models.
  *The Annals of Statistics* 16(4), 1696–1708.
  [doi:10.1214/aos/1176351062](https://doi.org/10.1214/aos/1176351062)
  – `"wild"` mit Rademacher-Gewichten (`wild_type = 0`).
- Mammen, E. (1993). Bootstrap and wild bootstrap for high dimensional
  linear models. *The Annals of Statistics* 21(1), 255–285.
  [doi:10.1214/aos/1176349025](https://doi.org/10.1214/aos/1176349025)
  – `"wild"` mit der Zweipunktverteilung nach Mammen (`wild_type = 1`).
- Barone-Adesi, G., Giannopoulos, K., Vosper, L. (1999). VaR without
  correlations for portfolios of derivative securities. *Journal of Futures
  Markets* 19(5), 583–602.
  [doi:10.1002/(SICI)1096-9934(199908)19:5<583::AID-FUT5>3.0.CO;2-S](https://doi.org/10.1002/%28SICI%291096-9934%28199908%2919:5%3C583::AID-FUT5%3E3.0.CO;2-S)
  – gefilterte historische Simulation in den Verfahren `"garch"` und
  `"gjr_garch"`.
- Anarkulova, A., Cederburg, S., O'Doherty, M. S. (2022). Stocks for the
  long run? Evidence from a broad sample of developed markets. *Journal of
  Financial Economics* 143(1), 409–433.
  [doi:10.1016/j.jfineco.2021.06.040](https://doi.org/10.1016/j.jfineco.2021.06.040)
  – Länder-Bootstrap `bootstrap_pooled()`.
- Hyndman, R. J., Fan, Y. (1996). Sample quantiles in statistical
  packages. *The American Statistician* 50(4), 361–365.
  [doi:10.1080/00031305.1996.10473566](https://doi.org/10.1080/00031305.1996.10473566)
  – Quantile Typ 7: gewichtete Quantile in `summary()` von
  `bootstrap_study()` und `withdrawal_simulation()`, Quartile der
  Bandbreite der Kerndichte, Rangeinteilung der MS-GARCH-Startwerte.
- Akinshin, A. (2023). Weighted quantile estimators. arXiv:2304.07265.
  [arxiv.org/abs/2304.07265](https://arxiv.org/abs/2304.07265) –
  gewichtete Quantile (Typ 7) bei ESS-gewichteten Studien.
- Kish, L. (1965). *Survey Sampling*. John Wiley, New York. – effektive
  Stichprobengröße (Σw)²/Σw² der gewichteten Quantile.

Ohne Literaturquelle, eigene Verfahren von SimLev: die Bootstrap-Verfahren
`"regime"` (Volatilitätsregime als Markov-Kette), `"tails"` (empirische
Ränder) und `"reset"` sowie die ESS-gewichtete Gittersuche über
Hyperparameter.

### Volatilitäts- und Regimemodelle

- Bollerslev, T. (1986). Generalized autoregressive conditional
  heteroskedasticity. *Journal of Econometrics* 31(3), 307–327.
  [doi:10.1016/0304-4076(86)90063-1](https://doi.org/10.1016/0304-4076%2886%2990063-1)
  – GARCH(1,1) per Maximum Likelihood: Verfahren `"garch"`, erste Stufe von
  `dependence_dcc()`, Regime der MS-GARCH-Verfahren.
- Glosten, L. R., Jagannathan, R., Runkle, D. E. (1993). On the relation
  between the expected value and the volatility of the nominal excess
  return on stocks. *The Journal of Finance* 48(5), 1779–1801.
  [doi:10.1111/j.1540-6261.1993.tb05128.x](https://doi.org/10.1111/j.1540-6261.1993.tb05128.x)
  – GJR-GARCH(1,1): Verfahren `"gjr_garch"`, Varianzmodell `"gjrGARCH"`
  der MS-GARCH-Verfahren.
- Engle, R. F., Lilien, D. M., Robins, R. P. (1987). Estimating time
  varying risk premia in the term structure: The ARCH-M model.
  *Econometrica* 55(2), 391–407.
  [doi:10.2307/1913242](https://doi.org/10.2307/1913242) –
  GARCH-in-Mean-Term im Verfahren `"ms_ar_garch_m"`.
- Haas, M., Mittnik, S., Paolella, M. S. (2004). A new approach to
  Markov-switching GARCH models. *Journal of Financial Econometrics* 2(4),
  493–530. [doi:10.1093/jjfinec/nbh020](https://doi.org/10.1093/jjfinec/nbh020)
  – eigene MS-GARCH-Schätzung der Verfahren `"ms_garch"`,
  `"ms_ar_garch_m"` und `"tvtp_ms_garch"`.
- Hamilton, J. D. (1989). A new approach to the economic analysis of
  nonstationary time series and the business cycle. *Econometrica* 57(2),
  357–384. [doi:10.2307/1912559](https://doi.org/10.2307/1912559) –
  Filter der MS-GARCH-Likelihood, `regime_hmm()`, `regime_states()`.
- Diebold, F. X., Lee, J.-H., Weinbach, G. C. (1994). Regime switching
  with time-varying transition probabilities. In: C. P. Hargreaves (Hrsg.),
  *Nonstationary Time Series Analysis and Cointegration*. Oxford University
  Press, 283–302.
  [doi:10.1093/oso/9780198773917.003.0010](https://doi.org/10.1093/oso/9780198773917.003.0010)
  – Verfahren `"tvtp_ms_garch"` (zeitvariable Übergänge).
- Baum, L. E., Petrie, T., Soules, G., Weiss, N. (1970). A maximization
  technique occurring in the statistical analysis of probabilistic
  functions of Markov chains. *The Annals of Mathematical Statistics*
  41(1), 164–171.
  [doi:10.1214/aoms/1177697196](https://doi.org/10.1214/aoms/1177697196)
  – EM-Schätzung in `regime_hmm()`, Startwerte der MS-GARCH-Schätzung.
- Viterbi, A. J. (1967). Error bounds for convolutional codes and an
  asymptotically optimum decoding algorithm. *IEEE Transactions on
  Information Theory* 13(2), 260–269.
  [doi:10.1109/TIT.1967.1054010](https://doi.org/10.1109/TIT.1967.1054010)
  – wahrscheinlichste Regimefolge in `regime_hmm()` und den
  MS-GARCH-Verfahren.

### Extremwerte

- Pickands, J. (1975). Statistical inference using extreme order
  statistics. *The Annals of Statistics* 3(1), 119–131.
  [doi:10.1214/aos/1176343003](https://doi.org/10.1214/aos/1176343003)
  – verallgemeinerte Pareto-Verteilung (GPD) der Überschreitungen im
  Verfahren `"evt"`.
- Davison, A. C., Smith, R. L. (1990). Models for exceedances over high
  thresholds. *Journal of the Royal Statistical Society, Series B* 52(3),
  393–425.
  [doi:10.1111/j.2517-6161.1990.tb01796.x](https://doi.org/10.1111/j.2517-6161.1990.tb01796.x)
  – GPD-Schätzung per Maximum Likelihood in `"evt"`.
- Hosking, J. R. M., Wallis, J. R. (1987). Parameter and quantile
  estimation for the generalized Pareto distribution. *Technometrics*
  29(3), 339–349.
  [doi:10.1080/00401706.1987.10488243](https://doi.org/10.1080/00401706.1987.10488243)
  – Startwerte der GPD-Schätzung (wahrscheinlichkeitsgewichtete Momente).
- McNeil, A. J., Frey, R. (2000). Estimation of tail-related risk measures
  for heteroscedastic financial time series: An extreme value approach.
  *Journal of Empirical Finance* 7(3–4), 271–300.
  [doi:10.1016/S0927-5398(00)00012-8](https://doi.org/10.1016/S0927-5398%2800%2900012-8)
  – GPD-Ränder mit empirischer Mitte im Verfahren `"evt"`.

### Abhängigkeit, Copulas, Regression

- Engle, R. (2002). Dynamic conditional correlation: A simple class of
  multivariate generalized autoregressive conditional heteroskedasticity
  models. *Journal of Business & Economic Statistics* 20(3), 339–350.
  [doi:10.1198/073500102288618487](https://doi.org/10.1198/073500102288618487)
  – `dependence_dcc()`, DCC in `dependence_analysis()`.
- Genest, C., Ghoudi, K., Rivest, L.-P. (1995). A semiparametric
  estimation procedure of dependence parameters in multivariate families
  of distributions. *Biometrika* 82(3), 543–552.
  [doi:10.1093/biomet/82.3.543](https://doi.org/10.1093/biomet/82.3.543)
  – Pseudo-Maximum-Likelihood auf Rängen in `copula_fit()`.
- Joe, H. (2014). *Dependence Modeling with Copulas*. Chapman & Hall/CRC,
  Boca Raton (Monographs on Statistics and Applied Probability 134). –
  Copula-Familien und implizite Tail-Abhängigkeit in `copula_fit()`.
- Longin, F., Solnik, B. (2001). Extreme correlation of international
  equity markets. *The Journal of Finance* 56(2), 649–676.
  [doi:10.1111/0022-1082.00340](https://doi.org/10.1111/0022-1082.00340)
  – Exceedance-Korrelationen in `tail_dependence()`.
- Knight, W. R. (1966). A computer method for calculating Kendall's tau
  with ungrouped data. *Journal of the American Statistical Association*
  61(314), 436–439.
  [doi:10.1080/01621459.1966.10480879](https://doi.org/10.1080/01621459.1966.10480879)
  – Kendalls τ in O(n log n) (`tail_dependence()`, `copula_fit()`,
  `dependence_analysis()`, `scenario_copula()`).
- Koenker, R., Bassett, G. (1978). Regression quantiles. *Econometrica*
  46(1), 33–50. [doi:10.2307/1913643](https://doi.org/10.2307/1913643) –
  `quantile_regression()`, `tail_regression()`, `tail_covar()`.
- Hunter, D. R., Lange, K. (2000). Quantile regression via an MM
  algorithm. *Journal of Computational and Graphical Statistics* 9(1),
  60–77.
  [doi:10.1080/10618600.2000.10474866](https://doi.org/10.1080/10618600.2000.10474866)
  – Lösungsverfahren in `quantile_regression()`.
- Barrodale, I., Roberts, F. D. K. (1974). Algorithm 478: Solution of an
  overdetermined system of equations in the l1 norm. *Communications of the
  ACM* 17(6), 319–320.
  [doi:10.1145/355616.361024](https://doi.org/10.1145/355616.361024) –
  Nachschärfen der Lösung auf eine Ecke in `quantile_regression()` (nach
  dem Verfahren, ohne Code des Algorithmus).
- Adrian, T., Brunnermeier, M. K. (2016). CoVaR. *American Economic
  Review* 106(7), 1705–1741.
  [doi:10.1257/aer.20120555](https://doi.org/10.1257/aer.20120555) –
  `tail_covar()`.

### Portfolio, Szenarien, Risiko

- Ledoit, O., Wolf, M. (2004). A well-conditioned estimator for
  large-dimensional covariance matrices. *Journal of Multivariate Analysis*
  88(2), 365–411.
  [doi:10.1016/S0047-259X(03)00096-4](https://doi.org/10.1016/S0047-259X%2803%2900096-4)
  – `portfolio_optimize(cov = "ledoit_wolf")`.
- Laloux, L., Cizeau, P., Bouchaud, J.-P., Potters, M. (1999). Noise
  dressing of financial correlation matrices. *Physical Review Letters*
  83(7), 1467–1470.
  [doi:10.1103/PhysRevLett.83.1467](https://doi.org/10.1103/PhysRevLett.83.1467)
  – Rauschfilter `cov = "denoise"`.
- López de Prado, M. (2020). *Machine Learning for Asset Managers*.
  Cambridge University Press (Elements in Quantitative Finance).
  [doi:10.1017/9781108883658](https://doi.org/10.1017/9781108883658) –
  `cov = "denoise"`.
- Gerber, S., Markowitz, H. M., Ernst, P. A., Miao, Y., Javid, B.,
  Sargen, P. (2022). The Gerber statistic: A robust co-movement measure for
  portfolio optimization. *The Journal of Portfolio Management* 48(3),
  87–102. [doi:10.3905/jpm.2021.1.316](https://doi.org/10.3905/jpm.2021.1.316)
  – `cov = "gerber"`.
- Choueifaty, Y., Coignard, Y. (2008). Toward maximum diversification.
  *The Journal of Portfolio Management* 35(1), 40–51.
  [doi:10.3905/jpm.2008.35.1.40](https://doi.org/10.3905/jpm.2008.35.1.40)
  – `method = "max_diversification"`.
- Spinu, F. (2013). An algorithm for computing risk parity weights. SSRN
  2297383. [doi:10.2139/ssrn.2297383](https://doi.org/10.2139/ssrn.2297383)
  – `method = "risk_parity"` mit Risikobudgets.
- López de Prado, M. (2016). Building diversified portfolios that
  outperform out of sample. *The Journal of Portfolio Management* 42(4),
  59–69. [doi:10.3905/jpm.2016.42.4.059](https://doi.org/10.3905/jpm.2016.42.4.059)
  – `method = "hrp"`.
- Rockafellar, R. T., Uryasev, S. (2000). Optimization of conditional
  value-at-risk. *Journal of Risk* 2(3), 21–41.
  [doi:10.21314/JOR.2000.038](https://doi.org/10.21314/JOR.2000.038) –
  `method = "min_cvar"`.
- Rockafellar, R. T., Uryasev, S. (2002). Conditional value-at-risk for
  general loss distributions. *Journal of Banking & Finance* 26(7),
  1443–1471.
  [doi:10.1016/S0378-4266(02)00271-6](https://doi.org/10.1016/S0378-4266%2802%2900271-6)
  – CVaR mit anteiligem Grenzszenario in `scenario_risk()`.
- Chekhlov, A., Uryasev, S., Zabarankin, M. (2005). Drawdown measure in
  portfolio optimization. *International Journal of Theoretical and Applied
  Finance* 8(1), 13–58.
  [doi:10.1142/S0219024905002767](https://doi.org/10.1142/S0219024905002767)
  – `method = "min_cdar"`.
- Michaud, R. O. (1998). *Efficient Asset Management: A Practical Guide to
  Stock Portfolio Optimization and Asset Allocation*. Harvard Business
  School Press, Boston. – Resampling `portfolio_optimize(resample = …)`.
- Meucci, A. (2008). Fully flexible views: Theory and practice. *Risk*
  21(10), 97–102. – `scenario_entropy_pooling()`.

### Überanpassung und Tests

- Bailey, D. H., Borwein, J., López de Prado, M., Zhu, Q. J. (2017). The
  probability of backtest overfitting. *Journal of Computational Finance*
  20(4), 39–69.
  [doi:10.21314/JCF.2016.322](https://doi.org/10.21314/JCF.2016.322) –
  `overfit_pbo()`.
- Bailey, D. H., López de Prado, M. (2012). The Sharpe ratio efficient
  frontier. *Journal of Risk* 15(2), 3–44.
  [doi:10.21314/JOR.2012.255](https://doi.org/10.21314/JOR.2012.255) –
  `sharpe_probabilistic()`, `sharpe_min_track_record()`.
- Bailey, D. H., López de Prado, M. (2014). The deflated Sharpe ratio:
  Correcting for selection bias, backtest overfitting, and non-normality.
  *The Journal of Portfolio Management* 40(5), 94–107.
  [doi:10.3905/jpm.2014.40.5.094](https://doi.org/10.3905/jpm.2014.40.5.094)
  – `sharpe_deflated()`.
- Harvey, C. R., Liu, Y. (2015). Backtesting. *The Journal of Portfolio
  Management* 42(1), 13–28.
  [doi:10.3905/jpm.2015.42.1.013](https://doi.org/10.3905/jpm.2015.42.1.013)
  – `sharpe_haircut()`.
- Holm, S. (1979). A simple sequentially rejective multiple test
  procedure. *Scandinavian Journal of Statistics* 6(2), 65–70. –
  Korrektur `holm` in `sharpe_haircut()`.
- Benjamini, Y., Yekutieli, D. (2001). The control of the false discovery
  rate in multiple testing under dependency. *The Annals of Statistics*
  29(4), 1165–1188.
  [doi:10.1214/aos/1013699998](https://doi.org/10.1214/aos/1013699998) –
  Korrektur `bhy` in `sharpe_haircut()`.
- White, H. (2000). A reality check for data snooping. *Econometrica*
  68(5), 1097–1126.
  [doi:10.1111/1468-0262.00152](https://doi.org/10.1111/1468-0262.00152)
  – `overfit_reality_check()`.
- Hansen, P. R. (2005). A test for superior predictive ability. *Journal
  of Business & Economic Statistics* 23(4), 365–380.
  [doi:10.1198/073500105000000063](https://doi.org/10.1198/073500105000000063)
  – SPA-Test in `overfit_reality_check()`.
- Ledoit, O., Wolf, M. (2008). Robust performance hypothesis testing with
  the Sharpe ratio. *Journal of Empirical Finance* 15(5), 850–859.
  [doi:10.1016/j.jempfin.2008.03.002](https://doi.org/10.1016/j.jempfin.2008.03.002)
  – `sharpe_test()`.
- Newey, W. K., West, K. D. (1987). A simple, positive semi-definite,
  heteroskedasticity and autocorrelation consistent covariance matrix.
  *Econometrica* 55(3), 703–708. – Kovarianz in
  `sharpe_test(method = "hac")`.
- Welch, B. L. (1947). The generalization of "Student's" problem when
  several different population variances are involved. *Biometrika*
  34(1–2), 28–35.
  [doi:10.1093/biomet/34.1-2.28](https://doi.org/10.1093/biomet/34.1-2.28)
  – Welch-Test in `signal_analysis()`.
- Satterthwaite, F. E. (1946). An approximate distribution of estimates
  of variance components. *Biometrics Bulletin* 2(6), 110–114.
  [doi:10.2307/3002019](https://doi.org/10.2307/3002019) – Freiheitsgrade
  des Welch-Tests in `signal_analysis()`.
- López de Prado, M. (2018). *Advances in Financial Machine Learning*.
  John Wiley & Sons, Kap. 7 und 12. – `portfolio_cpcv()`.

### Entnahme, Planung, Taktik, Anleihen, Backcast

- Bengen, W. P. (1994). Determining withdrawal rates using historical
  data. *Journal of Financial Planning* 7(4), 171–180. –
  `withdrawal_rule("constant")`.
- Cooley, P. L., Hubbard, C. M., Walz, D. T. (1998). Retirement savings:
  Choosing a withdrawal rate that is sustainable. *AAII Journal* 20(2),
  16–21. – `withdrawal_rule("constant")` (Trinity-Studie).
- Bengen, W. P. (2001). Conserving client portfolios during retirement,
  part IV. *Journal of Financial Planning*, Mai 2001. –
  `withdrawal_rule("floor_ceiling")`.
- Guyton, J. T., Klinger, W. J. (2006). Decision rules and maximum initial
  withdrawal rates. *Journal of Financial Planning* 19(3), 49–59. –
  `withdrawal_rule("guyton_klinger")`.
- Daga, A., Clarke, A. S., Pakula, D., Bupp, J. (2021). *Sustainable
  spending rates in turbulent markets*. Vanguard Research Note, März 2021. –
  `withdrawal_rule("vanguard")`.
- Bogleheads Wiki: Variable percentage withdrawal.
  [bogleheads.org/wiki/Variable_percentage_withdrawal](https://www.bogleheads.org/wiki/Variable_percentage_withdrawal)
  – `withdrawal_rule("vpw")`.
- Kitces, M. (2015). The ratcheting safe withdrawal rate – a more dominant
  version of the 4% rule? *Nerd's Eye View*, kitces.com, 3. Juni 2015.
  [kitces.com](https://www.kitces.com/blog/the-ratcheting-safe-withdrawal-rate-a-more-dominant-version-of-the-4-rule/)
  – `withdrawal_rule("ratchet")`.
- Suarez, E. D., Suarez, A., Walz, D. T. (2015). The perfect withdrawal
  amount: A methodology for creating retirement account distribution
  strategies. *Financial Services Review* 24(4), 331–357. –
  `withdrawal_perfect_rate()`.
- Das, S. R., Ostrov, D., Radhakrishnan, A., Srivastav, D. (2020). Dynamic
  portfolio allocation in goals-based wealth management. *Computational
  Management Science* 17(4), 613–640.
  [doi:10.1007/s10287-019-00351-7](https://doi.org/10.1007/s10287-019-00351-7)
  – `planning_goal()`.
- Antonacci, G. (2014). *Dual Momentum Investing: An Innovative Strategy
  for Higher Returns with Lower Risk*. McGraw-Hill. – Dual Momentum in
  `tactical_rotation()`.
- Keller, W. J., Keuning, J. W. (2018). Breadth momentum and the canary
  universe: Defensive asset allocation (DAA). SSRN 3212862.
  [doi:10.2139/ssrn.3212862](https://doi.org/10.2139/ssrn.3212862) –
  Canary-Schutz und Gewichtung `"13612w"` in `tactical_rotation()`.
- Moreira, A., Muir, T. (2017). Volatility-managed portfolios. *The
  Journal of Finance* 72(4), 1611–1644.
  [doi:10.1111/jofi.12513](https://doi.org/10.1111/jofi.12513) –
  `tactical_target_volatility()`.
- Bongaerts, D., Kang, X., van Dijk, M. (2020). Conditional volatility
  targeting. *Financial Analysts Journal* 76(4), 54–71.
  [doi:10.1080/0015198X.2020.1790853](https://doi.org/10.1080/0015198X.2020.1790853)
  – `tactical_conditional_volatility()`.
- Swinkels, L. (2019). Treasury bond return data starting in 1962. *Data*
  4(3), 91. [doi:10.3390/data4030091](https://doi.org/10.3390/data4030091)
  – `index_bond()`.
- MSCI (2021). *MSCI Short and Leveraged Daily Indexes Methodology*,
  August 2021.
  [msci.com](https://www.msci.com/eqb/methodology/meth_docs/MSCI_Short_and_Leveraged_Daily_Indexes_Methodology_Aug2021.pdf)
  – Hebelformel im Strukturmodell von `backcast_fit()`, in
  `series_leverage()` und für die Hebelprodukte in `bootstrap_config()`.
- Stambaugh, R. F. (1997). Analyzing investments whose histories differ in
  length. *Journal of Financial Economics* 45(3), 285–331.
  [doi:10.1016/S0304-405X(97)00020-2](https://doi.org/10.1016/S0304-405X%2897%2900020-2)
  – Regressions-Rückrechnung `backcast_fit(model = "linear")`.

### Numerische Grundlagen der eigenen Kerne

Die C-Bibliothek in [`core/`](core/) ist nach diesen Quellen geschrieben;
der Kopf jeder Datei nennt, welche Abschnitte sie nutzt.

**Zufall** (`simlev_seed()` und alle zufälligen Funktionen):

- Blackman, D., Vigna, S. (2021). Scrambled linear pseudorandom number
  generators. *ACM Transactions on Mathematical Software* 47(4), Art. 36.
  [doi:10.1145/3460772](https://doi.org/10.1145/3460772); frei als
  [arXiv:1805.01407](https://arxiv.org/abs/1805.01407) – Generator
  xoshiro256** und Sprünge um 2^128 für unabhängige Ströme.
- Steele, G. L., Lea, D., Flood, C. H. (2014). Fast splittable
  pseudorandom number generators. In: *Proceedings of the 2014 ACM
  International Conference on Object Oriented Programming Systems Languages
  & Applications (OOPSLA)*, 453–472.
  [doi:10.1145/2660193.2660195](https://doi.org/10.1145/2660193.2660195)
  – SplitMix64 zum Setzen des Zustands.
- Stafford, D. (2011). Better bit mixing – improving on MurmurHash3's
  64-bit finalizer. Blog, September 2011.
  [zimbry.blogspot.com](https://zimbry.blogspot.com/2011/09/better-bit-mixing-improving-on.html)
  – Mischfunktion von SplitMix64 (Variante 13).
- Lemire, D. (2019). Fast random integer generation in an interval. *ACM
  Transactions on Modeling and Computer Simulation* 29(1), 1–12.
  [doi:10.1145/3230636](https://doi.org/10.1145/3230636); frei als
  [arXiv:1805.10941](https://arxiv.org/abs/1805.10941) – ganze Zahlen in
  [0, n) für Stichproben und Bootstrap-Indizes.
- Knuth, D. E. (1997). *The Art of Computer Programming*, Bd. 2:
  *Seminumerical Algorithms*, 3. Aufl. Addison-Wesley, §3.4.2. – Stichproben
  ohne Zurücklegen (Fisher-Yates).
- Devroye, L. (1986). *Non-Uniform Random Variate Generation*.
  Springer, New York; frei auf der
  [Seite des Autors](https://luc.devroye.org/rnbookindex.html) –
  Inversion, diskrete Verteilungen, geometrische und Chi-Quadrat-Ziehungen.
- Marsaglia, G., Tsang, W. W. (2000). A simple method for generating gamma
  variables. *ACM Transactions on Mathematical Software* 26(3), 363–372.
  [doi:10.1145/358407.358414](https://doi.org/10.1145/358407.358414) –
  Gamma- und Chi-Quadrat-Ziehungen (`scenario_copula()`).

**Verteilungen** (Normal-, t-, Beta-, logistische Verteilung, `lgamma`):

- Olver, F. W. J., Olde Daalhuis, A. B., Lozier, D. W., Schneider, B. I.,
  Boisvert, R. F., Clark, C. W., Miller, B. R., Saunders, B. V., Cohl,
  H. S., McClain, M. A. (Hrsg.). *NIST Digital Library of Mathematical
  Functions*. [dlmf.nist.gov](https://dlmf.nist.gov/) – Reihen,
  Kettenbrüche und Asymptotik (Kap. 3, 4, 5, 7, 8, 24; Gleichungsnummern in
  den Dateiköpfen).
- Abramowitz, M., Stegun, I. A. (Hrsg.) (1964). *Handbook of Mathematical
  Functions with Formulas, Graphs, and Mathematical Tables*. National Bureau
  of Standards, Washington, DC (Applied Mathematics Series 55),
  Gl. 26.5.27, 26.7.1, 26.7.5. – t-Verteilung.
- Lentz, W. J. (1976). Generating Bessel functions in Mie scattering
  calculations using continued fractions. *Applied Optics* 15(3), 668–671.
  [doi:10.1364/AO.15.000668](https://doi.org/10.1364/AO.15.000668) –
  Auswertung der Kettenbrüche.
- Thompson, I. J., Barnett, A. R. (1986). Coulomb and Bessel functions of
  complex arguments and order. *Journal of Computational Physics* 64(2),
  490–509.
  [doi:10.1016/0021-9991(86)90046-X](https://doi.org/10.1016/0021-9991%2886%2990046-X)
  – modifiziertes Lentz-Verfahren.
- Dekker, T. J. (1971). A floating-point technique for extending the
  available precision. *Numerische Mathematik* 18(3), 224–242.
  [doi:10.1007/BF01397083](https://doi.org/10.1007/BF01397083) – exakte
  Produkte (Teilung nach Veltkamp).
- Householder, A. S. (1970). *The Numerical Treatment of a Single
  Nonlinear Equation*. McGraw-Hill, New York. – Halley-Schritte der
  Quantilfunktionen.

**Lineare Algebra und kleinste Quadrate** (Cholesky, Löser, Eigenwerte,
QR, Logit-IRLS, Matrixprodukt):

- Golub, G. H., Van Loan, C. F. (2013). *Matrix Computations*, 4. Aufl.
  Johns Hopkins University Press, Baltimore.
- Jacobi, C. G. J. (1846). Über ein leichtes Verfahren, die in der Theorie
  der Säcularstörungen vorkommenden Gleichungen numerisch aufzulösen.
  *Journal für die reine und angewandte Mathematik* 30, 51–94.
  [doi:10.1515/crll.1846.30.51](https://doi.org/10.1515/crll.1846.30.51)
  – Eigenwerte symmetrischer Matrizen.
- Demmel, J., Veselić, K. (1992). Jacobi's method is more accurate than
  QR. *SIAM Journal on Matrix Analysis and Applications* 13(4), 1204–1245.
  [doi:10.1137/0613074](https://doi.org/10.1137/0613074) – Begründung der
  Wahl des Jacobi-Verfahrens.
- Businger, P., Golub, G. H. (1965). Linear least squares solutions by
  Householder transformations. *Numerische Mathematik* 7(3), 269–276.
  [doi:10.1007/BF01436084](https://doi.org/10.1007/BF01436084) – QR mit
  Spaltenpivotisierung.
- Higham, N. J. (2002). *Accuracy and Stability of Numerical Algorithms*,
  2. Aufl. SIAM.
  [doi:10.1137/1.9780898718027](https://doi.org/10.1137/1.9780898718027)
- Neumaier, A. (1974). Rundungsfehleranalyse einiger Verfahren zur
  Summation endlicher Summen. *ZAMM* 54(1), 39–51.
  [doi:10.1002/zamm.19740540106](https://doi.org/10.1002/zamm.19740540106)
  – kompensierte Summen.
- McCullagh, P., Nelder, J. A. (1989). *Generalized Linear Models*,
  2. Aufl. Chapman and Hall, London. – Logit-IRLS in den MS-GARCH-Verfahren
  mit zeitvariablen Übergängen.

**Optimierer** (BFGS, projizierter BFGS, Nelder-Mead, numerischer
Gradient; u. a. in `backcast_fit()`, `copula_fit()`,
`scenario_entropy_pooling()` und den GARCH-, GPD-, DCC- und
MS-GARCH-Schätzungen):

- Nocedal, J., Wright, S. J. (2006). *Numerical Optimization*, 2. Aufl.
  Springer, New York.
  [doi:10.1007/978-0-387-40065-5](https://doi.org/10.1007/978-0-387-40065-5)
- Bertsekas, D. P. (1982). Projected Newton methods for optimization
  problems with simple constraints. *SIAM Journal on Control and
  Optimization* 20(2), 221–246.
  [doi:10.1137/0320018](https://doi.org/10.1137/0320018)
- Kelley, C. T. (1999). *Iterative Methods for Optimization*. SIAM.
  [doi:10.1137/1.9781611970920](https://doi.org/10.1137/1.9781611970920)
- Nelder, J. A., Mead, R. (1965). A simplex method for function
  minimization. *The Computer Journal* 7(4), 308–313.
  [doi:10.1093/comjnl/7.4.308](https://doi.org/10.1093/comjnl/7.4.308)
- Lagarias, J. C., Reeds, J. A., Wright, M. H., Wright, P. E. (1998).
  Convergence properties of the Nelder–Mead simplex method in low
  dimensions. *SIAM Journal on Optimization* 9(1), 112–147.
  [doi:10.1137/S1052623496303470](https://doi.org/10.1137/S1052623496303470)
- Gill, P. E., Murray, W., Wright, M. H. (1981). *Practical Optimization*.
  Academic Press, London. – Schrittweiten des numerischen Gradienten.

**Glättungsspline, Interpolation, Kerndichte** (`backcast_fit()`,
`backcast()`, Dichten in `plot()` von Bootstrap-Studien):

- Stineman, R. W. (1980). A consistently well-behaved method of
  interpolation. *Creative Computing* 6(7), 54–57. – Lücken füllen mit
  `fill = "stine"` bzw. `index_fill = "stine"`.
- Reinsch, C. H. (1967). Smoothing by spline functions. *Numerische
  Mathematik* 10(3), 177–183.
  [doi:10.1007/BF02162161](https://doi.org/10.1007/BF02162161) –
  `backcast_fit(model = "spline")`.
- Green, P. J., Silverman, B. W. (1994). *Nonparametric Regression and
  Generalized Linear Models: A Roughness Penalty Approach*. Chapman & Hall
  (Monographs on Statistics and Applied Probability 58).
- Craven, P., Wahba, G. (1979). Smoothing noisy data with spline
  functions: Estimating the correct degree of smoothing by the method of
  generalized cross-validation. *Numerische Mathematik* 31(4), 377–403.
  [doi:10.1007/BF01404567](https://doi.org/10.1007/BF01404567) – Wahl der
  Glättung (GCV).
- Hutchinson, M. F., de Hoog, F. R. (1985). Smoothing noisy data with
  spline functions. *Numerische Mathematik* 47(1), 99–106.
  [doi:10.1007/BF01389878](https://doi.org/10.1007/BF01389878) – Spur der
  Glättungsmatrix.
- Kiefer, J. (1953). Sequential minimax search for a maximum. *Proceedings
  of the American Mathematical Society* 4(3), 502–506.
  [doi:10.1090/S0002-9939-1953-0055639-3](https://doi.org/10.1090/S0002-9939-1953-0055639-3)
  – Goldener Schnitt bei der Suche des Glättungsparameters.
- Knuth, D. E. (1998). *The Art of Computer Programming*, Bd. 3: *Sorting
  and Searching*, 2. Aufl. Addison-Wesley, §5.2.4. – Sortieren der Knoten.
- Silverman, B. W. (1986). *Density Estimation for Statistics and Data
  Analysis*. Chapman & Hall, London (Monographs on Statistics and Applied
  Probability 26). – Gauß-Kerndichte und Bandbreite.
- Scott, D. W. (1992). *Multivariate Density Estimation: Theory, Practice,
  and Visualization*. John Wiley & Sons, New York. – Gauß-Kern.
- Wand, M. P., Jones, M. C. (1995). *Kernel Smoothing*. Chapman & Hall,
  London (Monographs on Statistics and Applied Probability 60). –
  lineares Binning bei großen Stichproben.

### Pakete als Vorbild bzw. Prüforakel

**SimLev enthält keinen Code aus diesen Paketen.** Bis Etappe 9 waren Teile
von evd, imputeTS, stinepack, rugarch, Rsolnp und truncnorm ins R-Paket
übernommen und in Python und Julia nachgebildet; seit Etappe 9 rechnet
SimLev diese Aufgaben mit eigenen Kernen (siehe [`r/NEWS.md`](r/NEWS.md)).
Die Pakete dienten bei der Entwicklung nur als Vorbild für das Verhalten
und als Prüforakel (Vergleich von Ein- und Ausgaben); keines ist eine
Abhängigkeit. Angaben aus den DESCRIPTION-Dateien der genannten Fassungen:

| Paket | Fassung | Autorinnen und Autoren | Lizenz | Rolle |
|---|---|---|---|---|
| evd | 2.3-7.1 (2024-09-21) | Alec Stephenson; Funktion `fbvpot` von Chris Ferro | GPL-3 | Prüforakel der GPD-Schätzung (`fpot`) |
| imputeTS | 3.4 (2025-08-25) | Steffen Moritz, Sebastian Gatscha, Earo Wang, Ron Hause | GPL-3 | Vorbild und Prüforakel der Stineman-Interpolation (`na_interpolation`) |
| stinepack | 1.5 (2024-03-07) | Tomas Johannesson, Halldor Bjornsson (Icelandic Met. Office), Gabor Grothendieck | GPL (≥ 2) | Vorbild und Prüforakel der Stineman-Interpolation (`stinterp`) |
| rugarch | 1.5-6 (2026-07-18) | Alexios Galanos, Tobias Kley | GPL-3 | Prüforakel der GARCH- und GJR-Schätzung (`ugarchfit`) |
| MSGARCH | 2.51 (2022-12-05) | David Ardia, Keven Bluteau, Kris Boudt, Leopoldo Catania, Alexios Ghalanos, Brian Peterson, Denis-Alexandre Trottier | GPL (≥ 2) | Prüforakel der MS-GARCH-Schätzung |
| Rsolnp | 1.16 (2015-12-28) | Alexios Ghalanos, Stefan Theussl | GPL | früher über den rugarch-Weg genutzt, heute ohne Rolle |
| truncnorm | 1.0-9 (2023-03-20) | Olaf Mersmann, Heike Trautmann, Detlef Steuer, Björn Bornkamp | GPL (≥ 2) | früher über den rugarch-Weg genutzt, heute ohne Rolle |
| numDeriv | 2016.8-1.1 (2019-06-06) | Paul Gilbert, Ravi Varadhan | GPL-2 | früher Prüforakel der numerischen Ableitungen, heute ohne Rolle |

R selbst: R Core Team (2024). *R: A Language and Environment for
Statistical Computing*. R Foundation for Statistical Computing, Wien.
[www.R-project.org](https://www.R-project.org/) (Fassung 4.3.3). R ist
Prüforakel der eigenen Kerne. Die Python- und die Julia-Fassung bilden
außerdem einige Grundfunktionen von R nach (Sortierung, Quantile,
Formatierung und Druck u. a.), damit sie zeichengleich zu R rechnen und
ausgeben; welche das sind und unter welcher Lizenz, steht in
[`python/COPYRIGHTS.md`](python/COPYRIGHTS.md) und
[`julia/COPYRIGHTS.md`](julia/COPYRIGHTS.md).

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
