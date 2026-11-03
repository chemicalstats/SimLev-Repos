<p align="center">
  <img src="r/man/figures/logo.png" alt="SimLev-Logo" width="340" />
</p>

<h1 align="center">SimLev</h1>

<p align="center">
  <strong>Simulation und Backtesting für Basis-, Hebel- und Multi-Asset-Strategien für Exchange Traded Products</strong><br>
  für <a href="r/">R</a> · <a href="python/">Python</a> · <a href="julia/">Julia</a>
</p>

---

**SimLev** rechnet Anlagestrategien auf täglichen Kursreihen durch, von der
einfachen Mischung aus Aktien- und Anleihe-ETF über Sparpläne und
Rebalancing bis zu signalgesteuerten Strategien mit gehebelten Produkten.
Der Unterschied zu gängigen Backtest-Werkzeugen ist die **detaillierte
Abbildung des deutschen Steuerrechts**: Vorabpauschale, Teilfreistellung,
Sparer-Pauschbetrag, getrennte Verlusttöpfe nach § 20 und § 23 EStG,
Kirchensteuer, Einkommensteuertarif und Günstigerprüfung werden Tag für Tag
mitgeführt. Um die Engine `simulation()` herum stehen Datenaufbereitung,
Auswertung, Bootstrap-Studien, Abhängigkeiten, Optimierung, Parametersuche
mit Prüfung auf Überanpassung, Planung, Entnahmephase und taktische
Allokation.

SimLev gibt es für R, Python und Julia mit denselben Funktionen, Argumenten
und Ergebnissen. Keine der drei Sprachen ist die „eigentliche“ Fassung: Die
Rechenkerne – die Engine von `simulation()`, Zufall, Verteilungen, lineare
Algebra, Optimierer, Modelle, Bootstrap und Steuertarif – liegen als
**gemeinsamer C/C++-Code** in [`core/`](core/), und alle drei Pakete rufen
denselben Code auf. Die Sprachpakete bilden die Schnittstelle darum:
Eingabeprüfung, Datenaufbereitung, Ablauf der Auswertungen, Ergebnisobjekte,
Druck und Grafik. Deshalb rechnen alle drei **bitgleich** (siehe
[Bitgleichheit](#bitgleichheit)). SimLev enthält
keinen Code aus fremden Paketen; die Verfahren und ihre Quellen stehen in
[`LITERATUR.md`](LITERATUR.md).

| Fassung | Ordner | Benötigt |
|---|---|---|
| **R** | [`r/`](r/) | R ≥ 4.0, C- und C++-Compiler, keine externen Pakete |
| **Python** | [`python/`](python/) | Python ≥ 3.10, `numpy`, `pandas`, C- und C++-Compiler |
| **Julia** | [`julia/`](julia/) | Julia ≥ 1.10, C- und C++-Compiler, nur die Standardbibliothek |

## Installation

SimLev wird nur über GitHub verteilt und bei der Installation aus dem
Quellcode übersetzt.

**R** (unter Windows mit [Rtools](https://cran.r-project.org/bin/windows/Rtools/),
unter macOS mit den Xcode Command Line Tools):

<!-- beispiele: nicht ausführen -->
``` r
# install.packages("remotes")
remotes::install_github("chemicalstats/SimLev-Repos", subdir = "r")
```

**Python** (baut die C-Erweiterung `simlev._ext`; unter Linux z. B. mit
`build-essential` und `python3-dev`):

``` bash
pip install "simlev @ git+https://github.com/chemicalstats/SimLev-Repos#subdirectory=python"
```

**Julia** (`Pkg.add` übersetzt die C-Bibliothek mit `deps/build.jl`; andere
Compiler über `ENV["SIMLEV_CC"]` und `ENV["SIMLEV_CXX"]`):

<!-- beispiele: nicht ausführen -->
``` julia
using Pkg
Pkg.add(url = "https://github.com/chemicalstats/SimLev-Repos", subdir = "julia")
```

Beim ersten `using SimLev` kompiliert Julia das Paket einmalig vor; das
dauert einige Minuten. Einzelheiten stehen in den READMEs der Sprachordner.

> [!CAUTION]
> **Haftungsausschluss.** SimLev ist ein privates Hobbyprojekt. Nichts in
> diesem Repository ist eine Anlage-, Steuer- oder Rechtsberatung, eine
> Empfehlung oder ein Angebot zum Kauf oder Verkauf von Finanzprodukten.
> Der Code kann Fehler enthalten; Ergebnisse, Steuerberechnungen und
> Beispiele sind ohne Gewähr und können unvollständig oder falsch sein.
> Die abgebildete Rechtslage kann veraltet sein oder auf den Einzelfall
> nicht zutreffen. Simulationen und Backtests beruhen auf Annahmen und
> vergangenen bzw. synthetischen Daten und sind keine Prognose. Prüfe jedes
> Ergebnis selbst, recherchiere eigenständig und ziehe für Entscheidungen
> eine Fachperson hinzu (z. B. Steuerberatung). Die Nutzung erfolgt auf
> eigenes Risiko; es gilt der Gewährleistungs- und Haftungsausschluss der
> Lizenz (GPL-3.0, Abschnitte 15 und 16).

## Fallstudie: vier Anlageklassen von der Ansparphase bis zur Entnahme

Ein deutscher Privatanleger legt 10.000 EUR an und spart 20 Jahre lang
300 EUR im Monat. Danach will er 15 Jahre lang Geld aus dem Depot entnehmen. Er
fragt sich, ob er neben **Aktien** und **Anleihen** auch **Rohstoffe** und
**Managed Futures** (Trendfolgefonds) beimischen soll. Die Fallstudie geht
dieser Frage mit SimLev nach und vergleicht dazu eine breite Mischung aus
allen vier Anlageklassen mit der klassischen Mischung 60/40 aus Aktien und
Anleihen.

Aus der Ausgangsfrage ergeben sich mehrere Teilfragen. Am Anfang steht das
Fundament: Was steckt in den Daten, und stimmen sie mit ihrer Quelle
überein? Welche Produkte stehen für die vier Anlageklassen, und wie werden
sie besteuert? Danach geht es um die Ansparphase selbst – wie sich beide
Mischungen über 20 Jahre mit Sparplan, Kosten, Rebalancing und Steuer
entwickeln, wie viel die Steuer dabei nimmt, warum die breite Mischung mehr
zahlt als die klassische, und worin sich beide im Detail unterscheiden.

Ein einzelner Backtest beweist wenig. Deshalb wird das Ergebnis anschließend
auf die Probe gestellt: Hängt es an der einen Kursgeschichte, oder trägt es
auch über viele neu gezogene Pfade und verschiedene Marktregime? Halten die
Diversifikationseffekte, wenn die Aktien stark fallen? Welche Gewichte
schlagen gängige Optimierer vor, hilft ein Trendfilter auf den Aktienanteil,
und wie stark hängt das Ergebnis an der Art des Rebalancings – ohne dabei
einer Überanpassung aufzusitzen?

Zum Schluss richtet sich der Blick nach vorn: Mit welcher Wahrscheinlichkeit
wachsen 10.000 EUR und 3.600 EUR im Jahr in 20 Jahren auf 250.000 EUR, und
welche Mischung führt am ehesten dorthin? Und trägt das so angesparte Depot
eine Entnahme von 4 % im Jahr über 15 Jahre, und was kostet sie an Steuern?
Jeder der folgenden Abschnitte zeigt dazu den Code, das Ergebnis und eine
Einordnung.

> **Synthetische Daten.** Die Kurse sind keine Marktdaten. Rendite,
> Volatilität und Korrelation der vier Reihen stammen aus der Literatur
> (Abschnitt „Die Daten“), der Rest ist Zufall: Die Reihen haben keine
> Krisen, keine Regime und keine dicken Ränder. Alle Zahlen hier zeigen,
> *wie* SimLev rechnet, nicht, was ein Anleger erwarten kann.

<!-- beispiele: gleiche Ausgaben -->
Der Code steht in R, Python und Julia, jeweils aufklappbar. Alle Blöcke
einer Sprache laufen nacheinander in einer Sitzung. Die Ausgaben sind
echte Ausgaben und in allen drei Sprachen gleich;
`tests/werkzeuge/doku/beispiele.sh` prüft beides.

- [Die Daten](#die-daten)
- [Anlageklassen und ihre Besteuerung](#anlageklassen-und-ihre-besteuerung)
- [Ansparphase mit `simulation()`](#ansparphase-mit-simulation)
- [Was die Steuer kostet](#was-die-steuer-kostet)
- [Auswertung und Dashboard](#auswertung-und-dashboard)
- [Robustheit: Bootstrap-Studie und Regime](#robustheit-bootstrap-studie-und-regime)
- [Abhängigkeiten in der Krise](#abhängigkeiten-in-der-krise)
- [Optimierung](#optimierung)
- [Parametersuche, Überanpassung und Sensitivität](#parametersuche-überanpassung-und-sensitivität)
- [Planung: Wird das Ziel erreicht?](#planung-wird-das-ziel-erreicht)
- [Entnahmephase mit Steuer](#entnahmephase-mit-steuer)
- [Ausblick](#ausblick)

### Die Daten

Die Datei `anlageklassen.csv` liegt jedem Paket bei (R:
`inst/extdata/`, Python: `simlev/data/`, Julia: `data/`). Sie enthält
Kurse an allen Werktagen vom 3. Januar 2005 bis 31. Dezember 2024, je
Reihe mit Startwert 100. Erzeugt hat sie das Skript
[`r/inst/extdata/anlageklassen.R`](r/inst/extdata/anlageklassen.R): tägliche
Logrenditen aus einer Normalverteilung, deren Mittelwert,
Standardabweichung und Korrelation über die 20 Jahre genau den Kennzahlen
von Abrams, Bhaduri und Flores (2012, Exhibit 4 und 7; siehe
[`LITERATUR.md`](LITERATUR.md#beispieldaten)) entsprechen. Dort
sind es US-Indizes in USD bis Dezember 2011; hier gelten die Kurse
vereinfachend als EUR-Kurse.

| Spalte | Anlageklasse | Index der Quelle | Rendite p. a. | Volatilität p. a. |
|---|---|---|---:|---:|
| `AKTIEN` | Aktien | S&P 500 Total Return | 11,06 % | 15,62 % |
| `ANLEIHEN` | Anleihen | Barclays Capital Bond Composite US | 6,41 % | 3,45 % |
| `ROHSTOFFE` | Rohstoffe | S&P GSCI Total Return | 6,32 % | 19,56 % |
| `MFUTURES` | Managed Futures | Barclay BTOP 50 | 8,99 % | 10,47 % |

Korrelationen laut Quelle: Aktien–Anleihen −0,10, Aktien–Rohstoffe 0,17,
Aktien–Managed Futures −0,04, Anleihen–Rohstoffe −0,03,
Anleihen–Managed Futures 0,20, Rohstoffe–Managed Futures 0,12.

SimLev erwartet eine Tabelle mit einer Spalte `date` und je Asset einer
Spalte mit dem Kursniveau. `series_check()` prüft sie auf Lücken, Sprünge
und mögliche Splits; `result_analysis()` wertet Kursreihen wie
Simulationsergebnisse aus. `zeige()` ist eine kleine Hilfsfunktion, die
Zahlen in allen drei Sprachen gleich druckt.

<details>
<summary><b>R</b></summary>

```r
library(SimLev)

datei  <- system.file("extdata", "anlageklassen.csv", package = "SimLev")
data   <- read.csv(datei)
data$date <- as.Date(data$date)
assets <- c("AKTIEN", "ANLEIHEN", "ROHSTOFFE", "MFUTURES")
zeige  <- function(...) { x <- c(...); cat(sprintf("%-30s %12.2f\n", names(x), x), sep = "") }

series_check(data)
reihen <- lapply(setNames(assets, assets), function(a) data.frame(date = data$date, value = data[[a]]))
result_analysis(reihen)
```

```text
SimLev-Datenprüfung

    column      start        end    n missing jumps spikes splits stale_max
    AKTIEN 2005-01-03 2024-12-31 5217       0     0      0      0         1
  ANLEIHEN 2005-01-03 2024-12-31 5217       0     0      0      0         1
 ROHSTOFFE 2005-01-03 2024-12-31 5217       0     0      0      0         1
  MFUTURES 2005-01-03 2024-12-31 5217       0     0      0      0         1
 nonpositive
           0
           0
           0
           0

Keine Auffälligkeiten.

══════════════════════════════════════════════════════════════
                    SimLev Detailanalyse
══════════════════════════════════════════════════════════════
  Zeitraum: 2005-01-03 bis 2024-12-31 (20.0 Jahre)

                                  AKTIEN    ANLEIHEN   ROHSTOFFE    MFUTURES
  Gesamtrendite                 714.99 %    246.46 %    240.64 %    459.41 %
  CAGR (TWR)                     11.06 %      6.41 %      6.32 %      8.99 %
  MWRR (geldgewichtet)                 –           –           –           –
  Volatilität p. a.              15.63 %      3.45 %     19.57 %     10.48 %
  Sharpe                           0.750       1.818       0.411       0.875
  Sortino                          1.102       2.832       0.598       1.299
  Calmar                           0.377       1.420       0.173       0.369
  Max. Drawdown                  29.33 %      4.52 %     36.48 %     24.36 %
...
```

</details>

<details>
<summary><b>Python</b></summary>

```python
import os
import struct
import numpy as np
import pandas as pd
import simlev

datei = os.path.join(os.path.dirname(simlev.__file__), "data", "anlageklassen.csv")
data = pd.read_csv(datei, parse_dates=["date"])
assets = ["AKTIEN", "ANLEIHEN", "ROHSTOFFE", "MFUTURES"]
def zeige(**x):
    for k, v in x.items():
        print(f"{k:<30s} {v:12.2f}")

print(simlev.series_check(data))
reihen = {a: pd.DataFrame({"date": data["date"], "value": data[a]}) for a in assets}
print(simlev.result_analysis(reihen))
```

```text
SimLev-Datenprüfung

    column      start        end    n missing jumps spikes splits stale_max
    AKTIEN 2005-01-03 2024-12-31 5217       0     0      0      0         1
  ANLEIHEN 2005-01-03 2024-12-31 5217       0     0      0      0         1
 ROHSTOFFE 2005-01-03 2024-12-31 5217       0     0      0      0         1
  MFUTURES 2005-01-03 2024-12-31 5217       0     0      0      0         1
 nonpositive
           0
           0
           0
           0

Keine Auffälligkeiten.

══════════════════════════════════════════════════════════════
                    SimLev Detailanalyse
══════════════════════════════════════════════════════════════
  Zeitraum: 2005-01-03 bis 2024-12-31 (20.0 Jahre)

                                  AKTIEN    ANLEIHEN   ROHSTOFFE    MFUTURES
  Gesamtrendite                 714.99 %    246.46 %    240.64 %    459.41 %
  CAGR (TWR)                     11.06 %      6.41 %      6.32 %      8.99 %
  MWRR (geldgewichtet)                 –           –           –           –
  Volatilität p. a.              15.63 %      3.45 %     19.57 %     10.48 %
  Sharpe                           0.750       1.818       0.411       0.875
  Sortino                          1.102       2.832       0.598       1.299
  Calmar                           0.377       1.420       0.173       0.369
  Max. Drawdown                  29.33 %      4.52 %     36.48 %     24.36 %
...
```

</details>

<details>
<summary><b>Julia</b></summary>

```julia
using SimLev, Dates, Printf

datei  = joinpath(pkgdir(SimLev), "data", "anlageklassen.csv")
zeilen = split.(readlines(datei)[2:end], ',')
assets = ["AKTIEN", "ANLEIHEN", "ROHSTOFFE", "MFUTURES"]
data   = RFrame("date" => Date.(first.(zeilen)),
                (a => parse.(Float64, getindex.(zeilen, j + 1)) for (j, a) in enumerate(assets))...)
zeige(; x...) = foreach(((k, v),) -> @printf("%-30s %12.2f\n", k, v), pairs(x))

display(series_check(data))
reihen = RList((a => RFrame("date" => data["date"], "value" => data[a]) for a in assets)...)
display(result_analysis(reihen))
```

```text
SimLev-Datenprüfung

    column      start        end    n missing jumps spikes splits stale_max
    AKTIEN 2005-01-03 2024-12-31 5217       0     0      0      0         1
  ANLEIHEN 2005-01-03 2024-12-31 5217       0     0      0      0         1
 ROHSTOFFE 2005-01-03 2024-12-31 5217       0     0      0      0         1
  MFUTURES 2005-01-03 2024-12-31 5217       0     0      0      0         1
 nonpositive
           0
           0
           0
           0

Keine Auffälligkeiten.

══════════════════════════════════════════════════════════════
                    SimLev Detailanalyse
══════════════════════════════════════════════════════════════
  Zeitraum: 2005-01-03 bis 2024-12-31 (20.0 Jahre)

                                  AKTIEN    ANLEIHEN   ROHSTOFFE    MFUTURES
  Gesamtrendite                 714.99 %    246.46 %    240.64 %    459.41 %
  CAGR (TWR)                     11.06 %      6.41 %      6.32 %      8.99 %
  MWRR (geldgewichtet)                 –           –           –           –
  Volatilität p. a.              15.63 %      3.45 %     19.57 %     10.48 %
  Sharpe                           0.750       1.818       0.411       0.875
  Sortino                          1.102       2.832       0.598       1.299
  Calmar                           0.377       1.420       0.173       0.369
  Max. Drawdown                  29.33 %      4.52 %     36.48 %     24.36 %
...
```

</details>

**Einordnung:** Die Daten sind lückenlos, und CAGR sowie
Volatilität treffen die Quelle bis auf die zweite Nachkommastelle. Ohne
risikolosen Zins hat der Anleihe-Index mit 1,82 die mit Abstand höchste
Sharpe Ratio und den kleinsten Drawdown (4,52 %); die Rohstoffe haben bei
kleinerer Rendite als die Aktien den tiefsten Drawdown (36,48 %) und die
längste Durststrecke (2.153 Tage).

### Anlageklassen und ihre Besteuerung

`asset_config()` beschreibt ein Asset, `create_strategy()` fasst die
Assets zusammen. Die Assetklasse bestimmt das Steuerregime:

| Asset | Produkt | `asset_class` | Steuerregime | Teilfreistellung |
|---|---|---|---|---:|
| `AKTIEN` | Aktien-ETF | `"etf"` | Investmentfonds (InvStG): Vorabpauschale | 30 % |
| `ANLEIHEN` | Anleihe-ETF | `"etf"` | Investmentfonds (InvStG): Vorabpauschale | 0 % |
| `ROHSTOFFE` | Rohstoff-ETC ohne Lieferanspruch | `"etc"` | § 20 EStG: Steuer nur auf realisierte Gewinne | – |
| `MFUTURES` | Managed-Futures-Fonds | `"etf"` | Investmentfonds (InvStG): Vorabpauschale | 0 % |

Die Mischung legt 40 % in Aktien, 30 % in Anleihen und je 15 % in
Rohstoffe und Managed Futures; zum Vergleich dient die klassische
Mischung 60/40 aus Aktien und Anleihen. Die Gewichte sind eine Annahme für
die Fallstudie, ebenso die Spreads (`spread`, voller Geld-Brief-Abstand in
Prozent).

<details>
<summary><b>R</b></summary>

```r
mix <- create_strategy(
  AKTIEN    = asset_config("etf", share = 0.40, spread = 0.10, partial_exemption = 30),
  ANLEIHEN  = asset_config("etf", share = 0.30, spread = 0.10),
  ROHSTOFFE = asset_config("etc", share = 0.15, spread = 0.20),
  MFUTURES  = asset_config("etf", share = 0.15, spread = 0.30)
)
klassisch <- create_strategy(
  AKTIEN   = asset_config("etf", share = 0.60, spread = 0.10, partial_exemption = 30),
  ANLEIHEN = asset_config("etf", share = 0.40, spread = 0.10)
)
mix
```

```text
Anlagestrategie (4 Assets)
================================

AKTIEN:
  Klasse: etf | Anteil: 40% | Steuer: investment_fund
ANLEIHEN:
  Klasse: etf | Anteil: 30% | Steuer: investment_fund
ROHSTOFFE:
  Klasse: etc | Anteil: 15% | Steuer: capital_gains
MFUTURES:
  Klasse: etf | Anteil: 15% | Steuer: investment_fund
```

</details>

<details>
<summary><b>Python</b></summary>

```python
mix = simlev.create_strategy(
    AKTIEN=simlev.asset_config(asset_class="etf", share=0.40, spread=0.10, partial_exemption=30),
    ANLEIHEN=simlev.asset_config(asset_class="etf", share=0.30, spread=0.10),
    ROHSTOFFE=simlev.asset_config(asset_class="etc", share=0.15, spread=0.20),
    MFUTURES=simlev.asset_config(asset_class="etf", share=0.15, spread=0.30),
)
klassisch = simlev.create_strategy(
    AKTIEN=simlev.asset_config(asset_class="etf", share=0.60, spread=0.10, partial_exemption=30),
    ANLEIHEN=simlev.asset_config(asset_class="etf", share=0.40, spread=0.10),
)
print(mix)
```

```text
Anlagestrategie (4 Assets)
================================

AKTIEN:
  Klasse: etf | Anteil: 40% | Steuer: investment_fund
ANLEIHEN:
  Klasse: etf | Anteil: 30% | Steuer: investment_fund
ROHSTOFFE:
  Klasse: etc | Anteil: 15% | Steuer: capital_gains
MFUTURES:
  Klasse: etf | Anteil: 15% | Steuer: investment_fund
```

</details>

<details>
<summary><b>Julia</b></summary>

```julia
mix = create_strategy(
    AKTIEN    = asset_config("etf"; share = 0.40, spread = 0.10, partial_exemption = 30),
    ANLEIHEN  = asset_config("etf"; share = 0.30, spread = 0.10),
    ROHSTOFFE = asset_config("etc"; share = 0.15, spread = 0.20),
    MFUTURES  = asset_config("etf"; share = 0.15, spread = 0.30),
)
klassisch = create_strategy(
    AKTIEN   = asset_config("etf"; share = 0.60, spread = 0.10, partial_exemption = 30),
    ANLEIHEN = asset_config("etf"; share = 0.40, spread = 0.10),
)
display(mix)
```

```text
Anlagestrategie (4 Assets)
================================

AKTIEN:
  Klasse: etf | Anteil: 40% | Steuer: investment_fund
ANLEIHEN:
  Klasse: etf | Anteil: 30% | Steuer: investment_fund
ROHSTOFFE:
  Klasse: etc | Anteil: 15% | Steuer: capital_gains
MFUTURES:
  Klasse: etf | Anteil: 15% | Steuer: investment_fund
```

</details>

**Einordnung:** SimLev leitet das Steuerregime aus der
Assetklasse ab: Die drei Fonds laufen unter `investment_fund`, der
Rohstoff-ETC unter `capital_gains`. Ein ETC mit Lieferanspruch auf
physisches Gold (`deliverable = TRUE`) fiele unter § 23 EStG und wäre nach
einem Jahr steuerfrei; zu einem breiten Rohstoffindex passt das nicht.

### Ansparphase mit `simulation()`

`simulation()` nimmt die Bausteine als eigene Objekte: `sim_costs()` für
Ordergebühren (hier 1 EUR je Order, Sparplanraten ohne Gebühr),
`dca_plan()` für den Sparplan (300 EUR im Monat), `rebalance_plan()` für das
Umschichten (einmal im Jahr, aber nur bei mehr als 5 Prozentpunkten
Abweichung) und `tax_profile()` für die Steuer: Abgeltungsteuer mit
Solidaritätszuschlag (26,375 %), Sparer-Pauschbetrag 1.000 EUR und
Vorabpauschale mit dem Basiszins 2024 von 2,29 % (BMF-Schreiben vom
5. Januar 2024) für alle Jahre.

<details>
<summary><b>R</b></summary>

```r
steuer <- tax_profile(base_rate = 2.29)
anspar <- function(strategie, tax = steuer, rebalance = rebalance_plan(1, unit = "year", thresh = 5)) {
  simulation(data, strategie, start_value = 10000,
             costs     = sim_costs(order_fee = 1, dca_fee = 0),
             dca       = dca_plan(300, 1, unit = "month"),
             rebalance = rebalance,
             tax       = tax)
}
res_mix <- anspar(mix)
res_kl  <- anspar(klassisch)
res_mix
```

```text
══════════════════════════════════════════════════════════════
                 SimLev Simulationsergebnisse
══════════════════════════════════════════════════════════════

  Wertentwicklung
  ─────────────────────
  CAGR:             +8.89% (geldgewichtet, XIRR)
  TTWROR:           +8.94% (zeitgewichtet)
  Endwert:          243709.48 EUR
  Eingezahlt:       81700.00 EUR (Start + Sparraten)

  Risiko (zeitgewichtet, ohne Einzahlungseffekte)
  ─────────────────────
  Max. Drawdown:    12.81%
  Mittl. Drawdown:  3.33%
  Ulcer Index:      0.0411
  Längster DD:      679 Tage
  Mittl. Erholung:  27 Tage

  Kennzahlen
  ─────────────────────
  Sharpe:           +1.158
  Sortino:          +1.744
  Calmar:           +0.698
  Omega:            +1.198
  Gain/Pain:        +0.198
  Serenity:         +17.009
  Martin Ratio:     +2.179
  (Calmar, Serenity, Martin mit TTWROR)

  Verteilung
  ─────────────────────
  Mittel je Tag:    +0.0340%
  Std.-Abw. je Tag: 0.4737%
  Schiefe:          0.024
  Wölbung:          0.003

  Steuern
  ─────────────────────
  Gezahlte Steuern: 8956.40 EUR
  Verlustvortrag:   0.00 EUR (§ 20) / 0.00 EUR (§ 23)
  SPB genutzt:      14098.91 EUR (Ersparnis: 3718.59 EUR)

══════════════════════════════════════════════════════════════
```

</details>

<details>
<summary><b>Python</b></summary>

```python
steuer = simlev.tax_profile(base_rate=2.29)
def anspar(strategie, tax=steuer, rebalance=simlev.rebalance_plan(span=1, unit="year", thresh=5)):
    return simlev.simulation(data, strategie, start_value=10000,
                             costs=simlev.sim_costs(order_fee=1, dca_fee=0),
                             dca=simlev.dca_plan(300, 1, unit="month"),
                             rebalance=rebalance,
                             tax=tax)
res_mix = anspar(mix)
res_kl = anspar(klassisch)
print(res_mix)
```

```text
══════════════════════════════════════════════════════════════
                 SimLev Simulationsergebnisse
══════════════════════════════════════════════════════════════

  Wertentwicklung
  ─────────────────────
  CAGR:             +8.89% (geldgewichtet, XIRR)
  TTWROR:           +8.94% (zeitgewichtet)
  Endwert:          243709.48 EUR
  Eingezahlt:       81700.00 EUR (Start + Sparraten)

  Risiko (zeitgewichtet, ohne Einzahlungseffekte)
  ─────────────────────
  Max. Drawdown:    12.81%
  Mittl. Drawdown:  3.33%
  Ulcer Index:      0.0411
  Längster DD:      679 Tage
  Mittl. Erholung:  27 Tage

  Kennzahlen
  ─────────────────────
  Sharpe:           +1.158
  Sortino:          +1.744
  Calmar:           +0.698
  Omega:            +1.198
  Gain/Pain:        +0.198
  Serenity:         +17.009
  Martin Ratio:     +2.179
  (Calmar, Serenity, Martin mit TTWROR)

  Verteilung
  ─────────────────────
  Mittel je Tag:    +0.0340%
  Std.-Abw. je Tag: 0.4737%
  Schiefe:          0.024
  Wölbung:          0.003

  Steuern
  ─────────────────────
  Gezahlte Steuern: 8956.40 EUR
  Verlustvortrag:   0.00 EUR (§ 20) / 0.00 EUR (§ 23)
  SPB genutzt:      14098.91 EUR (Ersparnis: 3718.59 EUR)

══════════════════════════════════════════════════════════════
```

</details>

<details>
<summary><b>Julia</b></summary>

```julia
steuer = tax_profile(; base_rate = 2.29)
anspar(strategie; tax = steuer, rebalance = rebalance_plan(1; unit = "year", thresh = 5)) =
    simulation(data, strategie; start_value = 10000,
               costs     = sim_costs(; order_fee = 1, dca_fee = 0),
               dca       = dca_plan(300, 1; unit = "month"),
               rebalance = rebalance,
               tax       = tax)
res_mix = anspar(mix)
res_kl  = anspar(klassisch)
display(res_mix)
```

```text
══════════════════════════════════════════════════════════════
                 SimLev Simulationsergebnisse
══════════════════════════════════════════════════════════════

  Wertentwicklung
  ─────────────────────
  CAGR:             +8.89% (geldgewichtet, XIRR)
  TTWROR:           +8.94% (zeitgewichtet)
  Endwert:          243709.48 EUR
  Eingezahlt:       81700.00 EUR (Start + Sparraten)

  Risiko (zeitgewichtet, ohne Einzahlungseffekte)
  ─────────────────────
  Max. Drawdown:    12.81%
  Mittl. Drawdown:  3.33%
  Ulcer Index:      0.0411
  Längster DD:      679 Tage
  Mittl. Erholung:  27 Tage

  Kennzahlen
  ─────────────────────
  Sharpe:           +1.158
  Sortino:          +1.744
  Calmar:           +0.698
  Omega:            +1.198
  Gain/Pain:        +0.198
  Serenity:         +17.009
  Martin Ratio:     +2.179
  (Calmar, Serenity, Martin mit TTWROR)

  Verteilung
  ─────────────────────
  Mittel je Tag:    +0.0340%
  Std.-Abw. je Tag: 0.4737%
  Schiefe:          0.024
  Wölbung:          0.003

  Steuern
  ─────────────────────
  Gezahlte Steuern: 8956.40 EUR
  Verlustvortrag:   0.00 EUR (§ 20) / 0.00 EUR (§ 23)
  SPB genutzt:      14098.91 EUR (Ersparnis: 3718.59 EUR)

══════════════════════════════════════════════════════════════
```

</details>

**Einordnung:** Aus 81.700 EUR Einzahlungen werden 243.709 EUR,
eine geldgewichtete Rendite (XIRR) von 8,89 % p. a. Der größte Rückgang
des zeitgewichteten Wertindex beträgt 12,81 %. Bis zum Ende der
Ansparphase hat die Mischung 8.956 EUR Steuern gezahlt; der
Sparer-Pauschbetrag hat 14.099 EUR Erträge freigestellt und 3.719 EUR
Steuer gespart. Die Gewinne, die noch im Depot stecken, sind dabei noch
nicht versteuert.

### Was die Steuer kostet

Ein Lauf ohne Steuer (`tax = NULL`) zeigt den Unterschied, zwei Läufe
ohne Rebalancing (`rebalance = NULL`) die Rolle des Umschichtens. Mit
`liquidate = TRUE` würde SimLev am letzten Tag alles verkaufen und
versteuern; hier bleibt das Depot stehen, denn es geht in die
Entnahmephase (Abschnitt „Entnahmephase mit Steuer“) über, und zwar mit seinen offenen Lots.

<details>
<summary><b>R</b></summary>

```r
ohne <- anspar(mix, tax = NULL)
zeige(Endwert_ohne_Steuer      = tail(ohne$worth, 1),
      Endwert_mit_Steuer       = tail(res_mix$worth, 1),
      Steuern_Mischung         = res_mix$tax_report$total_taxes_paid,
      Steuern_60_40            = res_kl$tax_report$total_taxes_paid,
      Steuern_Mischung_ohne_Reb = anspar(mix, rebalance = NULL)$tax_report$total_taxes_paid,
      Steuern_60_40_ohne_Reb   = anspar(klassisch, rebalance = NULL)$tax_report$total_taxes_paid)
```

```text
Endwert_ohne_Steuer               251714.49
Endwert_mit_Steuer                243709.48
Steuern_Mischung                    8956.40
Steuern_60_40                       4104.75
Steuern_Mischung_ohne_Reb           1828.71
Steuern_60_40_ohne_Reb              2436.70
```

</details>

<details>
<summary><b>Python</b></summary>

```python
ohne = anspar(mix, tax=None)
zeige(Endwert_ohne_Steuer=ohne.worth[-1],
      Endwert_mit_Steuer=res_mix.worth[-1],
      Steuern_Mischung=res_mix.tax_report["total_taxes_paid"],
      Steuern_60_40=res_kl.tax_report["total_taxes_paid"],
      Steuern_Mischung_ohne_Reb=anspar(mix, rebalance=None).tax_report["total_taxes_paid"],
      Steuern_60_40_ohne_Reb=anspar(klassisch, rebalance=None).tax_report["total_taxes_paid"])
```

```text
Endwert_ohne_Steuer               251714.49
Endwert_mit_Steuer                243709.48
Steuern_Mischung                    8956.40
Steuern_60_40                       4104.75
Steuern_Mischung_ohne_Reb           1828.71
Steuern_60_40_ohne_Reb              2436.70
```

</details>

<details>
<summary><b>Julia</b></summary>

```julia
ohne = anspar(mix; tax = nothing)
zeige(Endwert_ohne_Steuer  = ohne.worth[end],
      Endwert_mit_Steuer   = res_mix.worth[end],
      Steuern_Mischung     = res_mix.tax_report.total_taxes_paid,
      Steuern_60_40        = res_kl.tax_report.total_taxes_paid,
      Steuern_Mischung_ohne_Reb = anspar(mix; rebalance = nothing).tax_report.total_taxes_paid,
      Steuern_60_40_ohne_Reb    = anspar(klassisch; rebalance = nothing).tax_report.total_taxes_paid)
```

```text
Endwert_ohne_Steuer               251714.49
Endwert_mit_Steuer                243709.48
Steuern_Mischung                    8956.40
Steuern_60_40                       4104.75
Steuern_Mischung_ohne_Reb           1828.71
Steuern_60_40_ohne_Reb              2436.70
```

</details>

**Einordnung:** Ohne Steuer stünden am Ende 251.714 EUR im
Depot, 8.005 EUR mehr. Die Mischung zahlt mehr als doppelt so viel Steuer
wie 60/40 (8.956 gegen 4.105 EUR). Das liegt am Rebalancing: Ohne
Umschichten zahlt die Mischung sogar weniger als 60/40 (1.829 gegen
2.437 EUR). Rebalancing verkauft, was gestiegen ist, und realisiert damit
Gewinne; die des Rohstoff-ETC sind ohne Teilfreistellung voll
steuerpflichtig. Mit
`income = income_tariff()` und `guenstigerpruefung = TRUE` rechnet
`simulation()` die Veranlagung mit dem Einkommensteuertarif je Jahr
(`tax_report$tariff_years`); Abschnitt „Entnahmephase mit Steuer“ nutzt das für die
Entnahmephase.

### Auswertung und Dashboard

`result_analysis()` stellt Ergebnisse nebeneinander, mit einer Benchmark
auch Alpha, Beta und Capture-Werte; das Dashboard zeichnet `plot(res_mix)` (R),
`res_mix.plot()` (Python) bzw. `plot_dashboard(res_mix)` (Julia).

<details>
<summary><b>R</b></summary>

```r
da <- result_analysis(list(klassisch = res_kl, mix = res_mix), benchmark = "klassisch")
da
plot(res_mix)
```

```text
══════════════════════════════════════════════════════════════
                    SimLev Detailanalyse
══════════════════════════════════════════════════════════════
  Zeitraum: 2005-01-03 bis 2024-12-31 (20.0 Jahre)

                               klassisch         mix
  Gesamtrendite                 484.35 %    454.31 %
  CAGR (TWR)                      9.23 %      8.94 %
  MWRR (geldgewichtet)            8.60 %      8.89 %
  Volatilität p. a.               9.36 %      7.65 %
  Sharpe                           0.990       1.158
  Sortino                          1.475       1.744
  Calmar                           0.552       0.698
  Max. Drawdown                  16.73 %     12.81 %
...
  Steuern                          4 105       8 956

  Gegen Benchmark 'klassisch'
                                     mix
  Alpha p. a.                     2.01 %
  Beta                             0.739
  Korrelation                      0.904
  R²                               0.817
  Up-Capture                       0.810
  Down-Capture                     0.649
  Capture Spread                   0.161
  Aktive Rendite p. a.           -0.29 %
  Tracking Error                  4.09 %
  Information Ratio               -0.100
  M² (Modigliani)                10.84 %
══════════════════════════════════════════════════════════════
```

</details>

<details>
<summary><b>Python</b></summary>

```python
da = simlev.result_analysis({"klassisch": res_kl, "mix": res_mix}, benchmark="klassisch")
print(da)
res_mix.plot()
```

```text
══════════════════════════════════════════════════════════════
                    SimLev Detailanalyse
══════════════════════════════════════════════════════════════
  Zeitraum: 2005-01-03 bis 2024-12-31 (20.0 Jahre)

                               klassisch         mix
  Gesamtrendite                 484.35 %    454.31 %
  CAGR (TWR)                      9.23 %      8.94 %
  MWRR (geldgewichtet)            8.60 %      8.89 %
  Volatilität p. a.               9.36 %      7.65 %
  Sharpe                           0.990       1.158
  Sortino                          1.475       1.744
  Calmar                           0.552       0.698
  Max. Drawdown                  16.73 %     12.81 %
...
  Steuern                          4 105       8 956

  Gegen Benchmark 'klassisch'
                                     mix
  Alpha p. a.                     2.01 %
  Beta                             0.739
  Korrelation                      0.904
  R²                               0.817
  Up-Capture                       0.810
  Down-Capture                     0.649
  Capture Spread                   0.161
  Aktive Rendite p. a.           -0.29 %
  Tracking Error                  4.09 %
  Information Ratio               -0.100
  M² (Modigliani)                10.84 %
══════════════════════════════════════════════════════════════
```

</details>

<details>
<summary><b>Julia</b></summary>

```julia
da = result_analysis(RList("klassisch" => res_kl, "mix" => res_mix); benchmark = "klassisch")
display(da)
plot_dashboard(res_mix)
```

```text
══════════════════════════════════════════════════════════════
                    SimLev Detailanalyse
══════════════════════════════════════════════════════════════
  Zeitraum: 2005-01-03 bis 2024-12-31 (20.0 Jahre)

                               klassisch         mix
  Gesamtrendite                 484.35 %    454.31 %
  CAGR (TWR)                      9.23 %      8.94 %
  MWRR (geldgewichtet)            8.60 %      8.89 %
  Volatilität p. a.               9.36 %      7.65 %
  Sharpe                           0.990       1.158
  Sortino                          1.475       1.744
  Calmar                           0.552       0.698
  Max. Drawdown                  16.73 %     12.81 %
...
  Steuern                          4 105       8 956

  Gegen Benchmark 'klassisch'
                                     mix
  Alpha p. a.                     2.01 %
  Beta                             0.739
  Korrelation                      0.904
  R²                               0.817
  Up-Capture                       0.810
  Down-Capture                     0.649
  Capture Spread                   0.161
  Aktive Rendite p. a.           -0.29 %
  Tracking Error                  4.09 %
  Information Ratio               -0.100
  M² (Modigliani)                10.84 %
══════════════════════════════════════════════════════════════
```

</details>

<p align="center">
  <img src="r/man/figures/README-ansparphase.png" alt="Dashboard der Ansparphase mit vier Anlageklassen" width="100%" />
</p>

**Einordnung:** Die Mischung schwankt weniger als 60/40
(Volatilität 7,65 % gegen 9,36 %, größter Rückgang 12,81 % gegen 16,73 %)
und hat die höhere Sharpe Ratio (1,158 gegen 0,990). Die zeitgewichtete
Rendite ist etwas niedriger (8,94 % gegen 9,23 % p. a.), die
geldgewichtete etwas höher (8,89 % gegen 8,60 %). Gegenüber 60/40 fängt sie
65 % der Verluste, aber 81 % der Gewinne ein (Down- und Up-Capture); das
Beta liegt bei 0,74. Das Dashboard zeigt Depotwert und Einzahlungen,
Drawdowns, die Verteilung der Tagesrenditen, rollierende Renditen,
Monatsrenditen und die wichtigsten Kennzahlen.

### Robustheit: Bootstrap-Studie und Regime

`bootstrap_study()` zieht neue Pfade aus den Tagesrenditen (hier
stationärer Bootstrap mit mittlerer Blocklänge 250 Tage, 100 Pfade) und
rechnet beide Mischungen mit denselben Bausteinen auf denselben Pfaden.
`dates = data$date` gibt den Pfaden den Werktagskalender der Daten; ohne
ihn wären es aufeinanderfolgende Kalendertage, und die Jahresrenditen wären
zu hoch. `keep_returns = "year"` behält die Jahresrenditen für die
Entnahmephase. `bootstrap_probability()` zählt Pfade, die eine Bedingung
erfüllen.

<details>
<summary><b>R</b></summary>

```r
cfg <- bootstrap_config(setNames(assets, assets), input = "prices")
study <- bootstrap_study(data, cfg, "stationary", n = 100, params = list(L = 250),
  dates = data$date, strategies = list(klassisch = klassisch, mix = mix),
  sim_args = list(start_value = 10000, costs = sim_costs(order_fee = 1, dca_fee = 0),
                  dca = dca_plan(300, 1, unit = "month"),
                  rebalance = rebalance_plan(1, unit = "year", thresh = 5), tax = steuer),
  seed = 1, keep_returns = "year", progress = FALSE)
summary(study)
p <- bootstrap_probability(study, max_drawdown > 0.2)
zeige(P_Drawdown_ueber_20_klassisch = p$probability[1], P_Drawdown_ueber_20_mix = p$probability[2])
```

```text
══════════════════════════════════════════════════════════════
                 SimLev Bootstrap-Studie
══════════════════════════════════════════════════════════════
  Verfahren: stationary | Pfade: 100 | Pfadlänge: 5216 Tage

  cagr (mit Sparplan geldgewichtet, XIRR)
  Strategie          Mittel        q05       q25       q50       q75       q95
  klassisch           9.05%      6.24%     8.05%     8.73%     9.99%    12.40%
  mix                 8.75%      6.43%     7.83%     8.58%     9.64%    11.34%

  ttwror
  Strategie          Mittel        q05       q25       q50       q75       q95
  klassisch           9.07%      6.39%     7.95%     8.98%     9.92%    12.66%
  mix                 8.80%      6.26%     7.90%     8.77%     9.71%    11.79%

  max_drawdown
  Strategie          Mittel        q05       q25       q50       q75       q95
  klassisch          18.32%     12.98%    16.21%    17.34%    20.10%    25.45%
  mix                13.39%     10.27%    11.76%    12.81%    14.80%    17.72%

  sharpe
  Strategie          Mittel        q05       q25       q50       q75       q95
  klassisch           0.961      0.704     0.851     0.961     1.050     1.285
  mix                 1.139      0.859     1.035     1.139     1.237     1.503

...
  final_value
  Strategie          Mittel        q05       q25       q50       q75       q95
  klassisch          258496     172917    218253    238583    282136    389925
  mix                244625     177141    212170    234067    269334    337908
══════════════════════════════════════════════════════════════
P_Drawdown_ueber_20_klassisch          0.27
P_Drawdown_ueber_20_mix                0.03
```

</details>

<details>
<summary><b>Python</b></summary>

```python
cfg = simlev.bootstrap_config({a: a for a in assets}, input="prices")
study = simlev.bootstrap_study(data, cfg, "stationary", n=100, params={"L": 250},
    dates=data["date"], strategies={"klassisch": klassisch, "mix": mix},
    sim_args={"start_value": 10000, "costs": simlev.sim_costs(order_fee=1, dca_fee=0),
              "dca": simlev.dca_plan(300, 1, unit="month"),
              "rebalance": simlev.rebalance_plan(span=1, unit="year", thresh=5), "tax": steuer},
    seed=1, keep_returns="year", progress=False)
print(simlev.summary(study))
p = simlev.bootstrap_probability(study, "max_drawdown > 0.2")
zeige(P_Drawdown_ueber_20_klassisch=p["probability"][0], P_Drawdown_ueber_20_mix=p["probability"][1])
```

```text
══════════════════════════════════════════════════════════════
                 SimLev Bootstrap-Studie
══════════════════════════════════════════════════════════════
  Verfahren: stationary | Pfade: 100 | Pfadlänge: 5216 Tage

  cagr (mit Sparplan geldgewichtet, XIRR)
  Strategie          Mittel        q05       q25       q50       q75       q95
  klassisch           9.05%      6.24%     8.05%     8.73%     9.99%    12.40%
  mix                 8.75%      6.43%     7.83%     8.58%     9.64%    11.34%

  ttwror
  Strategie          Mittel        q05       q25       q50       q75       q95
  klassisch           9.07%      6.39%     7.95%     8.98%     9.92%    12.66%
  mix                 8.80%      6.26%     7.90%     8.77%     9.71%    11.79%

  max_drawdown
  Strategie          Mittel        q05       q25       q50       q75       q95
  klassisch          18.32%     12.98%    16.21%    17.34%    20.10%    25.45%
  mix                13.39%     10.27%    11.76%    12.81%    14.80%    17.72%

  sharpe
  Strategie          Mittel        q05       q25       q50       q75       q95
  klassisch           0.961      0.704     0.851     0.961     1.050     1.285
  mix                 1.139      0.859     1.035     1.139     1.237     1.503

...
  final_value
  Strategie          Mittel        q05       q25       q50       q75       q95
  klassisch          258496     172917    218253    238583    282136    389925
  mix                244625     177141    212170    234067    269334    337908
══════════════════════════════════════════════════════════════
P_Drawdown_ueber_20_klassisch          0.27
P_Drawdown_ueber_20_mix                0.03
```

</details>

<details>
<summary><b>Julia</b></summary>

```julia
cfg = bootstrap_config(RList((a => a for a in assets)...); input = "prices")
study = bootstrap_study(data, cfg, "stationary"; n = 100, params = (L = 250,),
    dates = data["date"], strategies = (klassisch = klassisch, mix = mix),
    sim_args = (start_value = 10000, costs = sim_costs(; order_fee = 1, dca_fee = 0),
                dca = dca_plan(300, 1; unit = "month"),
                rebalance = rebalance_plan(1; unit = "year", thresh = 5), tax = steuer),
    seed = 1, keep_returns = "year", progress = false)
display(r_summary(study))
p = bootstrap_probability(study, "max_drawdown > 0.2")
zeige(P_Drawdown_ueber_20_klassisch = p["probability"][1], P_Drawdown_ueber_20_mix = p["probability"][2])
```

```text
══════════════════════════════════════════════════════════════
                 SimLev Bootstrap-Studie
══════════════════════════════════════════════════════════════
  Verfahren: stationary | Pfade: 100 | Pfadlänge: 5216 Tage

  cagr (mit Sparplan geldgewichtet, XIRR)
  Strategie          Mittel        q05       q25       q50       q75       q95
  klassisch           9.05%      6.24%     8.05%     8.73%     9.99%    12.40%
  mix                 8.75%      6.43%     7.83%     8.58%     9.64%    11.34%

  ttwror
  Strategie          Mittel        q05       q25       q50       q75       q95
  klassisch           9.07%      6.39%     7.95%     8.98%     9.92%    12.66%
  mix                 8.80%      6.26%     7.90%     8.77%     9.71%    11.79%

  max_drawdown
  Strategie          Mittel        q05       q25       q50       q75       q95
  klassisch          18.32%     12.98%    16.21%    17.34%    20.10%    25.45%
  mix                13.39%     10.27%    11.76%    12.81%    14.80%    17.72%

  sharpe
  Strategie          Mittel        q05       q25       q50       q75       q95
  klassisch           0.961      0.704     0.851     0.961     1.050     1.285
  mix                 1.139      0.859     1.035     1.139     1.237     1.503

...
  final_value
  Strategie          Mittel        q05       q25       q50       q75       q95
  klassisch          258496     172917    218253    238583    282136    389925
  mix                244625     177141    212170    234067    269334    337908
══════════════════════════════════════════════════════════════
P_Drawdown_ueber_20_klassisch          0.27
P_Drawdown_ueber_20_mix                0.03
```

</details>

Über 100 Pfade bleibt das Bild aus Abschnitt „Ansparphase mit `simulation()`“
bestehen: Die Mischung hat in allen gezeigten Quantilen die höhere Sharpe
Ratio und den kleineren größten Rückgang (im 95-%-Quantil 17,72 % gegen
25,45 %). Einen Rückgang von mehr als 20 % erleben 27 % der Pfade von
60/40, aber nur 3 % der Pfade der Mischung. Bei der Rendite liegt 60/40
leicht vorn (Median der XIRR 8,73 % gegen 8,58 %). Der echte Lauf der
Mischung (8,89 %) liegt zwischen Median und 75-%-Quantil.

Der Bootstrap setzt Blöcke der einen Geschichte neu zusammen; Zustände, die
in den Daten fehlen, erzeugt er nicht. Ob die Daten Regime enthalten, also
Phasen mit eigener Rendite und Volatilität, prüft `regime_hmm()` mit einem
Hidden-Markov-Modell auf den Wochenrenditen:

<details>
<summary><b>R</b></summary>

```r
regime_hmm(data, "AKTIEN")
```

```text
Hidden-Markov-Modell: 2 Zustände auf AKTIEN (week), 1043 Perioden, logL 2510.7, BIC -4972.7

  Z1: Anteil 3 %, erwartete Dauer 7.3 Perioden, Rendite -72.9 % p. a., Vola 9.4 %
  Z2: Anteil 97 %, erwartete Dauer 277.4 Perioden, Rendite 13.1 % p. a., Vola 15.8 %

Übergangsmatrix
      Z1    Z2
Z1 0.863 0.137
Z2 0.004 0.996

Aktueller Zustand (gefiltert): Z2 mit 98 %
```

</details>

<details>
<summary><b>Python</b></summary>

```python
print(simlev.regime_hmm(data, "AKTIEN"))
```

```text
Hidden-Markov-Modell: 2 Zustände auf AKTIEN (week), 1043 Perioden, logL 2510.7, BIC -4972.7

  Z1: Anteil 3 %, erwartete Dauer 7.3 Perioden, Rendite -72.9 % p. a., Vola 9.4 %
  Z2: Anteil 97 %, erwartete Dauer 277.4 Perioden, Rendite 13.1 % p. a., Vola 15.8 %

Übergangsmatrix
      Z1    Z2
Z1 0.863 0.137
Z2 0.004 0.996

Aktueller Zustand (gefiltert): Z2 mit 98 %
```

</details>

<details>
<summary><b>Julia</b></summary>

```julia
display(regime_hmm(data, "AKTIEN"))
```

```text
Hidden-Markov-Modell: 2 Zustände auf AKTIEN (week), 1043 Perioden, logL 2510.7, BIC -4972.7

  Z1: Anteil 3 %, erwartete Dauer 7.3 Perioden, Rendite -72.9 % p. a., Vola 9.4 %
  Z2: Anteil 97 %, erwartete Dauer 277.4 Perioden, Rendite 13.1 % p. a., Vola 15.8 %

Übergangsmatrix
      Z1    Z2
Z1 0.863 0.137
Z2 0.004 0.996

Aktueller Zustand (gefiltert): Z2 mit 98 %
```

</details>

**Einordnung:** Das Modell findet einen Zustand Z1 mit 3 % der
Wochen und einer Rendite von −72,9 % p. a. Die Daten haben aber nach
ihrer Konstruktion kein Regime: Z1 fasst nur rund 30 schwache Wochen
zusammen. Ein Modell mit zwei Zuständen liefert immer zwei Zustände; ob sie
mehr als Rauschen sind, ist eine eigene Frage, etwa nach ihrer Stabilität
über Teilperioden. Für Daten mit echten Regimen hat `bootstrap_study()`
die Verfahren `regime` und `ms_garch`.

### Abhängigkeiten in der Krise

`dependence_analysis()` misst auf Wochenrenditen die Korrelation, die
Tail-Abhängigkeit je Paar (empirisch und über angepasste Copulas) und eine
zeitvariable Korrelation (DCC).

<details>
<summary><b>R</b></summary>

```r
dependence_analysis(data, assets, B = 99, seed = 1)
```

```text
SimLev Abhängigkeitsanalyse: 1043 Perioden (week), 2005-01-14 bis 2024-12-31

Korrelation (Pearson unten links, Kendall oben rechts)
          AKTIEN ANLEIHEN ROHSTOFFE MFUTURES
AKTIEN     1.000   -0.071     0.139   -0.040
ANLEIHEN  -0.114    1.000    -0.012    0.117
ROHSTOFFE  0.215   -0.028     1.000    0.060
MFUTURES  -0.065    0.186     0.092    1.000

Tail-Abhängigkeit je Paar
                 Paar Kendall lamL 0.05 lamU 0.05 lamL 0.1 lamU 0.1      Copula
    AKTIEN ~ ANLEIHEN  -0.071      0.06      0.04     0.07     0.04 clayton_270
   AKTIEN ~ ROHSTOFFE   0.139      0.13      0.10     0.24     0.14     clayton
    AKTIEN ~ MFUTURES  -0.040      0.08      0.02     0.09     0.10    gaussian
 ANLEIHEN ~ ROHSTOFFE  -0.012      0.02      0.06     0.11     0.08  clayton_90
  ANLEIHEN ~ MFUTURES   0.117      0.10      0.10     0.15     0.20    gaussian
 ROHSTOFFE ~ MFUTURES   0.060      0.10      0.10     0.16     0.14    gaussian
 Cop. lamL Cop. lamU     t: rho/nu
      0.00      0.00 -0.12 / 500.0
      0.08      0.00  0.22 / 500.0
      0.00      0.00 -0.06 / 500.0
      0.00      0.00 -0.03 / 165.3
      0.00      0.00  0.18 / 500.0
      0.00      0.00  0.09 / 500.0
  (Unabhängigkeit: lam(q) ~ q; Gauß-Abhängigkeit: lam -> 0 für kleine q)

DCC(1,1): a = 0.0017, b = 0.9754 (Persistenz 0.9771); Korrelation zuletzt: AKTIEN ~ ANLEIHEN -0.11, AKTIEN ~ ROHSTOFFE 0.23, AKTIEN ~ MFUTURES -0.06, ANLEIHEN ~ ROHSTOFFE -0.04, ANLEIHEN ~ MFUTURES 0.20, ROHSTOFFE ~ MFUTURES 0.08
```

</details>

<details>
<summary><b>Python</b></summary>

```python
print(simlev.dependence_analysis(data, assets, B=99, seed=1))
```

```text
SimLev Abhängigkeitsanalyse: 1043 Perioden (week), 2005-01-14 bis 2024-12-31

Korrelation (Pearson unten links, Kendall oben rechts)
          AKTIEN ANLEIHEN ROHSTOFFE MFUTURES
AKTIEN     1.000   -0.071     0.139   -0.040
ANLEIHEN  -0.114    1.000    -0.012    0.117
ROHSTOFFE  0.215   -0.028     1.000    0.060
MFUTURES  -0.065    0.186     0.092    1.000

Tail-Abhängigkeit je Paar
                 Paar Kendall lamL 0.05 lamU 0.05 lamL 0.1 lamU 0.1      Copula
    AKTIEN ~ ANLEIHEN  -0.071      0.06      0.04     0.07     0.04 clayton_270
   AKTIEN ~ ROHSTOFFE   0.139      0.13      0.10     0.24     0.14     clayton
    AKTIEN ~ MFUTURES  -0.040      0.08      0.02     0.09     0.10    gaussian
 ANLEIHEN ~ ROHSTOFFE  -0.012      0.02      0.06     0.11     0.08  clayton_90
  ANLEIHEN ~ MFUTURES   0.117      0.10      0.10     0.15     0.20    gaussian
 ROHSTOFFE ~ MFUTURES   0.060      0.10      0.10     0.16     0.14    gaussian
 Cop. lamL Cop. lamU     t: rho/nu
      0.00      0.00 -0.12 / 500.0
      0.08      0.00  0.22 / 500.0
      0.00      0.00 -0.06 / 500.0
      0.00      0.00 -0.03 / 165.3
      0.00      0.00  0.18 / 500.0
      0.00      0.00  0.09 / 500.0
  (Unabhängigkeit: lam(q) ~ q; Gauß-Abhängigkeit: lam -> 0 für kleine q)

DCC(1,1): a = 0.0017, b = 0.9754 (Persistenz 0.9771); Korrelation zuletzt: AKTIEN ~ ANLEIHEN -0.11, AKTIEN ~ ROHSTOFFE 0.23, AKTIEN ~ MFUTURES -0.06, ANLEIHEN ~ ROHSTOFFE -0.04, ANLEIHEN ~ MFUTURES 0.20, ROHSTOFFE ~ MFUTURES 0.08
```

</details>

<details>
<summary><b>Julia</b></summary>

```julia
display(dependence_analysis(data, assets; B = 99, seed = 1))
```

```text
SimLev Abhängigkeitsanalyse: 1043 Perioden (week), 2005-01-14 bis 2024-12-31

Korrelation (Pearson unten links, Kendall oben rechts)
          AKTIEN ANLEIHEN ROHSTOFFE MFUTURES
AKTIEN     1.000   -0.071     0.139   -0.040
ANLEIHEN  -0.114    1.000    -0.012    0.117
ROHSTOFFE  0.215   -0.028     1.000    0.060
MFUTURES  -0.065    0.186     0.092    1.000

Tail-Abhängigkeit je Paar
                 Paar Kendall lamL 0.05 lamU 0.05 lamL 0.1 lamU 0.1      Copula
    AKTIEN ~ ANLEIHEN  -0.071      0.06      0.04     0.07     0.04 clayton_270
   AKTIEN ~ ROHSTOFFE   0.139      0.13      0.10     0.24     0.14     clayton
    AKTIEN ~ MFUTURES  -0.040      0.08      0.02     0.09     0.10    gaussian
 ANLEIHEN ~ ROHSTOFFE  -0.012      0.02      0.06     0.11     0.08  clayton_90
  ANLEIHEN ~ MFUTURES   0.117      0.10      0.10     0.15     0.20    gaussian
 ROHSTOFFE ~ MFUTURES   0.060      0.10      0.10     0.16     0.14    gaussian
 Cop. lamL Cop. lamU     t: rho/nu
      0.00      0.00 -0.12 / 500.0
      0.08      0.00  0.22 / 500.0
      0.00      0.00 -0.06 / 500.0
      0.00      0.00 -0.03 / 165.3
      0.00      0.00  0.18 / 500.0
      0.00      0.00  0.09 / 500.0
  (Unabhängigkeit: lam(q) ~ q; Gauß-Abhängigkeit: lam -> 0 für kleine q)

DCC(1,1): a = 0.0017, b = 0.9754 (Persistenz 0.9771); Korrelation zuletzt: AKTIEN ~ ANLEIHEN -0.11, AKTIEN ~ ROHSTOFFE 0.23, AKTIEN ~ MFUTURES -0.06, ANLEIHEN ~ ROHSTOFFE -0.04, ANLEIHEN ~ MFUTURES 0.20, ROHSTOFFE ~ MFUTURES 0.08
```

</details>

**Einordnung:** Die Korrelationen der Wochenrenditen liegen nahe
an den Vorgaben der Quelle. Für die Krise zählen die Ränder: Die
geschätzte Tail-Abhängigkeit der Copulas ist fast überall 0, die
t-Copula landet bei ν = 500 und ist damit praktisch die Gauß-Copula, und
die DCC-Korrelation ist mit a = 0,0017 nahezu konstant. Das entspricht der
Konstruktion der Daten: Eine gemeinsame Normalverteilung hat keine
Randabhängigkeit, und die Korrelation ist fest. Die Diversifikation hält
hier also auch in schlechten Wochen; das ist eine Eigenschaft der
synthetischen Daten, keine Aussage über Märkte. Mit echten Kursen ist
genau diese Analyse der Prüfstein, ob eine Beimischung in der Krise hilft.

### Optimierung

`portfolio_optimize()` schätzt Gewichte aus Wochenrenditen. Zuerst die
Mischung mit der höchsten Sharpe Ratio:

<details>
<summary><b>R</b></summary>

```r
portfolio_optimize(data, assets = assets, method = "max_sharpe")
```

```text
SimLev-Optimierung: max_sharpe (1043 Perioden, week, Kovarianz sample)

    Anlage Gewicht Risikoanteil
    AKTIEN   9.1 %       15.0 %
  ANLEIHEN  81.4 %       72.8 %
 ROHSTOFFE   1.6 %        1.9 %
  MFUTURES   7.9 %       10.3 %

Erwartete Rendite 7.00 % p. a. (historisch), Volatilität 3.29 %, Sharpe 2.126
CVaR(0.05) 0.83 % je Periode, CDaR(0.05) 2.18 % (kumuliert)
Diversifikationsverhältnis 1.65, effektive Anzahl: Gewichte 1.5, Risiko 1.8
```

</details>

<details>
<summary><b>Python</b></summary>

```python
print(simlev.portfolio_optimize(data, assets=assets, method="max_sharpe"))
```

```text
SimLev-Optimierung: max_sharpe (1043 Perioden, week, Kovarianz sample)

    Anlage Gewicht Risikoanteil
    AKTIEN   9.1 %       15.0 %
  ANLEIHEN  81.4 %       72.8 %
 ROHSTOFFE   1.6 %        1.9 %
  MFUTURES   7.9 %       10.3 %

Erwartete Rendite 7.00 % p. a. (historisch), Volatilität 3.29 %, Sharpe 2.126
CVaR(0.05) 0.83 % je Periode, CDaR(0.05) 2.18 % (kumuliert)
Diversifikationsverhältnis 1.65, effektive Anzahl: Gewichte 1.5, Risiko 1.8
```

</details>

<details>
<summary><b>Julia</b></summary>

```julia
display(portfolio_optimize(data; assets = assets, method = "max_sharpe"))
```

```text
SimLev-Optimierung: max_sharpe (1043 Perioden, week, Kovarianz sample)

    Anlage Gewicht Risikoanteil
    AKTIEN   9.1 %       15.0 %
  ANLEIHEN  81.4 %       72.8 %
 ROHSTOFFE   1.6 %        1.9 %
  MFUTURES   7.9 %       10.3 %

Erwartete Rendite 7.00 % p. a. (historisch), Volatilität 3.29 %, Sharpe 2.126
CVaR(0.05) 0.83 % je Periode, CDaR(0.05) 2.18 % (kumuliert)
Diversifikationsverhältnis 1.65, effektive Anzahl: Gewichte 1.5, Risiko 1.8
```

</details>

Der Optimierer legt 81,4 % in Anleihen. Er
übernimmt die Kennzahlen der Daten als Erwartung, und dort haben die
Anleihen die mit Abstand beste Sharpe Ratio (Abschnitt „Die Daten“). Die
Risikoparität dagegen verlangt von jeder Anlageklasse denselben Beitrag
zum Risiko und braucht keine Renditeschätzung:

<details>
<summary><b>R</b></summary>

```r
portfolio_optimize(data, assets = assets, method = "risk_parity")
```

```text
SimLev-Optimierung: risk_parity (1043 Perioden, week, Kovarianz sample)

    Anlage Gewicht Risikoanteil
    AKTIEN  13.2 %       25.0 %
  ANLEIHEN  59.9 %       25.0 %
 ROHSTOFFE   9.2 %       25.0 %
  MFUTURES  17.7 %       25.0 %

Erwartete Rendite 7.65 % p. a. (historisch), Volatilität 4.21 %, Sharpe 1.816
CVaR(0.05) 1.05 % je Periode, CDaR(0.05) 3.28 % (kumuliert)
Diversifikationsverhältnis 1.88, effektive Anzahl: Gewichte 2.4, Risiko 4.0
```

</details>

<details>
<summary><b>Python</b></summary>

```python
print(simlev.portfolio_optimize(data, assets=assets, method="risk_parity"))
```

```text
SimLev-Optimierung: risk_parity (1043 Perioden, week, Kovarianz sample)

    Anlage Gewicht Risikoanteil
    AKTIEN  13.2 %       25.0 %
  ANLEIHEN  59.9 %       25.0 %
 ROHSTOFFE   9.2 %       25.0 %
  MFUTURES  17.7 %       25.0 %

Erwartete Rendite 7.65 % p. a. (historisch), Volatilität 4.21 %, Sharpe 1.816
CVaR(0.05) 1.05 % je Periode, CDaR(0.05) 3.28 % (kumuliert)
Diversifikationsverhältnis 1.88, effektive Anzahl: Gewichte 2.4, Risiko 4.0
```

</details>

<details>
<summary><b>Julia</b></summary>

```julia
display(portfolio_optimize(data; assets = assets, method = "risk_parity"))
```

```text
SimLev-Optimierung: risk_parity (1043 Perioden, week, Kovarianz sample)

    Anlage Gewicht Risikoanteil
    AKTIEN  13.2 %       25.0 %
  ANLEIHEN  59.9 %       25.0 %
 ROHSTOFFE   9.2 %       25.0 %
  MFUTURES  17.7 %       25.0 %

Erwartete Rendite 7.65 % p. a. (historisch), Volatilität 4.21 %, Sharpe 1.816
CVaR(0.05) 1.05 % je Periode, CDaR(0.05) 3.28 % (kumuliert)
Diversifikationsverhältnis 1.88, effektive Anzahl: Gewichte 2.4, Risiko 4.0
```

</details>

**Einordnung:** Auch die Risikoparität legt den größten Teil in
Anleihen (59,9 %), weil sie am wenigsten schwanken; jede Anlageklasse
trägt 25 % zum Risiko bei. Rohstoffe erhalten mit 9,2 % das kleinste
Gewicht. Wer die Anleihenrenditen der Quelle (1997 bis 2011) nicht für
die Zukunft erwartet, gibt eigene Erwartungen vor (`mu` in
`portfolio_optimize()`) oder nutzt Szenarien
(`scenario_entropy_pooling()`); `portfolio_frontier()` zeigt die ganze
Effizienzkurve.

### Parametersuche, Überanpassung und Sensitivität

`param_search()` rechnet eine Strategie für jeden Punkt eines
Parameterraums, hier einen Aktien-ETF, der über dem gleitenden
Durchschnitt von `n` Tagen gehalten und darunter verkauft wird
(`signal_sma()`). `sharpe_deflated()` korrigiert die beste Sharpe Ratio um
die Zahl der Versuche, `overfit_pbo()` schätzt die Wahrscheinlichkeit, dass
die Auswahl des besten Punkts überangepasst ist.

<details>
<summary><b>R</b></summary>

```r
trend <- create_strategy(AKTIEN = asset_config("etf", trading = "signal", spread = 0.10,
  partial_exemption = 30, signal_buy = "buy", signal_sell = "sell"))
ps <- param_search(data,
  builder = function(p) list(strategy = trend, signal = function(df) signal_sma(df$AKTIEN, p$n)),
  space = param_space(n = c(20, 50, 100, 150, 200, 250, 300)),
  sim_args = list(tax = steuer), objective = "sharpe")
ps
sharpe_deflated(ps)
overfit_pbo(ps)
halten <- simulation(data, create_strategy(AKTIEN = asset_config("etf", spread = 0.10, partial_exemption = 30)),
                     tax = steuer)
zeige(Sharpe_Halten = halten$statistics$sharpe, CAGR_Halten_Prozent = 100 * halten$cagr)
```

```text
...
Zielgröße: sharpe

 id   n   cagr max_drawdown sharpe ulcer_index trades plateau
  2  50 7.84 %      25.64 %  0.676       0.099 18.608   0.547
  3 100 6.10 %      25.85 %  0.529       0.111 13.406   0.543
  6 250 5.72 %      26.41 %  0.487       0.131  7.803   0.467
  7 300 5.61 %      26.41 %  0.473       0.142  7.003   0.480
  5 200 5.01 %      27.77 %  0.442       0.136  9.604   0.450
  1  20 4.64 %      26.64 %  0.436       0.122 32.863   0.556
  4 150 4.74 %      27.04 %  0.423       0.143 11.455   0.464
cagr: mit Sparplan geldgewichtet (XIRR), sonst CAGR des Depotwerts

Bester Punkt:   #2 (n = 50), sharpe = 0.676
Bestes Plateau: #1 (n = 20), sharpe = 0.436, Nachbarschaft = 0.556
Deflated Sharpe Ratio
  Punkt #2, 1044 Beobachtungen (week)
  Sharpe Ratio (p. a.):                 0.671
  Versuche: 7 nominal, 2.1 effektiv (mittlere Korrelation 0.82), verwendet 2.1
  Erwartetes Maximum ohne Können (p. a.):  0.048
  PSR (SR > 0):                         99.9 %
  DSR (SR > erwartetes Maximum):        99.8 %
  Lesart: DSR über 95 % = Ergebnis hält der Mehrfachtest-Korrektur stand.
Probability of Backtest Overfitting (PBO, CSCV)
  7 Punkte, 1040 Beobachtungen (week), S = 16 Blöcke, 12870 Aufteilungen, Kennzahl sharpe
  PBO:                              14.2 %
  Median-Logit lambda:              1.95
  Leistungsabfall (Steigung OOS~IS): -1.01
  OOS-Verlustwahrscheinlichkeit:    1.1 %
  Gewählter Punkt OOS vor Median:   85.8 %
  Lesart: PBO nahe 0 = Auswahl trägt, um 57 % = Zufall (ungerade Punktezahl: (N + 1) / (2N)), darüber = Auswahl schadet.
Sharpe_Halten                          0.75
CAGR_Halten_Prozent                   11.06
```

</details>

<details>
<summary><b>Python</b></summary>

```python
trend = simlev.create_strategy(AKTIEN=simlev.asset_config(asset_class="etf", trading="signal", spread=0.10,
    partial_exemption=30, signal_buy="buy", signal_sell="sell"))
ps = simlev.param_search(data,
    builder=lambda p: {"strategy": trend, "signal": lambda df: simlev.signal_sma(df["AKTIEN"], n=p["n"])},
    space=simlev.param_space(n=[20, 50, 100, 150, 200, 250, 300]),
    sim_args={"tax": steuer}, objective="sharpe")
print(ps)
print(simlev.sharpe_deflated(ps))
print(simlev.overfit_pbo(ps))
halten = simlev.simulation(data, simlev.create_strategy(AKTIEN=simlev.asset_config(asset_class="etf", spread=0.10,
                           partial_exemption=30)), tax=steuer)
zeige(Sharpe_Halten=halten.statistics["sharpe"], CAGR_Halten_Prozent=100 * halten.cagr)
```

```text
...
Zielgröße: sharpe

 id   n   cagr max_drawdown sharpe ulcer_index trades plateau
  2  50 7.84 %      25.64 %  0.676       0.099 18.608   0.547
  3 100 6.10 %      25.85 %  0.529       0.111 13.406   0.543
  6 250 5.72 %      26.41 %  0.487       0.131  7.803   0.467
  7 300 5.61 %      26.41 %  0.473       0.142  7.003   0.480
  5 200 5.01 %      27.77 %  0.442       0.136  9.604   0.450
  1  20 4.64 %      26.64 %  0.436       0.122 32.863   0.556
  4 150 4.74 %      27.04 %  0.423       0.143 11.455   0.464
cagr: mit Sparplan geldgewichtet (XIRR), sonst CAGR des Depotwerts

Bester Punkt:   #2 (n = 50), sharpe = 0.676
Bestes Plateau: #1 (n = 20), sharpe = 0.436, Nachbarschaft = 0.556
Deflated Sharpe Ratio
  Punkt #2, 1044 Beobachtungen (week)
  Sharpe Ratio (p. a.):                 0.671
  Versuche: 7 nominal, 2.1 effektiv (mittlere Korrelation 0.82), verwendet 2.1
  Erwartetes Maximum ohne Können (p. a.):  0.048
  PSR (SR > 0):                         99.9 %
  DSR (SR > erwartetes Maximum):        99.8 %
  Lesart: DSR über 95 % = Ergebnis hält der Mehrfachtest-Korrektur stand.
Probability of Backtest Overfitting (PBO, CSCV)
  7 Punkte, 1040 Beobachtungen (week), S = 16 Blöcke, 12870 Aufteilungen, Kennzahl sharpe
  PBO:                              14.2 %
  Median-Logit lambda:              1.95
  Leistungsabfall (Steigung OOS~IS): -1.01
  OOS-Verlustwahrscheinlichkeit:    1.1 %
  Gewählter Punkt OOS vor Median:   85.8 %
  Lesart: PBO nahe 0 = Auswahl trägt, um 57 % = Zufall (ungerade Punktezahl: (N + 1) / (2N)), darüber = Auswahl schadet.
Sharpe_Halten                          0.75
CAGR_Halten_Prozent                   11.06
```

</details>

<details>
<summary><b>Julia</b></summary>

```julia
trend = create_strategy(AKTIEN = asset_config("etf", "signal"; spread = 0.10,
    partial_exemption = 30, signal_buy = "buy", signal_sell = "sell"))
ps = param_search(data;
    builder = p -> (strategy = trend, signal = df -> signal_sma(df["AKTIEN"], p["n"])),
    space = param_space(n = [20, 50, 100, 150, 200, 250, 300]),
    sim_args = (tax = steuer,), objective = "sharpe")
display(ps)
display(sharpe_deflated(ps))
display(overfit_pbo(ps))
halten = simulation(data, create_strategy(AKTIEN = asset_config("etf"; spread = 0.10, partial_exemption = 30));
                    tax = steuer)
zeige(Sharpe_Halten = halten.statistics["sharpe"], CAGR_Halten_Prozent = 100 * halten.cagr)
```

```text
...
Zielgröße: sharpe

 id   n   cagr max_drawdown sharpe ulcer_index trades plateau
  2  50 7.84 %      25.64 %  0.676       0.099 18.608   0.547
  3 100 6.10 %      25.85 %  0.529       0.111 13.406   0.543
  6 250 5.72 %      26.41 %  0.487       0.131  7.803   0.467
  7 300 5.61 %      26.41 %  0.473       0.142  7.003   0.480
  5 200 5.01 %      27.77 %  0.442       0.136  9.604   0.450
  1  20 4.64 %      26.64 %  0.436       0.122 32.863   0.556
  4 150 4.74 %      27.04 %  0.423       0.143 11.455   0.464
cagr: mit Sparplan geldgewichtet (XIRR), sonst CAGR des Depotwerts

Bester Punkt:   #2 (n = 50), sharpe = 0.676
Bestes Plateau: #1 (n = 20), sharpe = 0.436, Nachbarschaft = 0.556

Deflated Sharpe Ratio
  Punkt #2, 1044 Beobachtungen (week)
  Sharpe Ratio (p. a.):                 0.671
  Versuche: 7 nominal, 2.1 effektiv (mittlere Korrelation 0.82), verwendet 2.1
  Erwartetes Maximum ohne Können (p. a.):  0.048
  PSR (SR > 0):                         99.9 %
  DSR (SR > erwartetes Maximum):        99.8 %
  Lesart: DSR über 95 % = Ergebnis hält der Mehrfachtest-Korrektur stand.

Probability of Backtest Overfitting (PBO, CSCV)
  7 Punkte, 1040 Beobachtungen (week), S = 16 Blöcke, 12870 Aufteilungen, Kennzahl sharpe
  PBO:                              14.2 %
  Median-Logit lambda:              1.95
  Leistungsabfall (Steigung OOS~IS): -1.01
  OOS-Verlustwahrscheinlichkeit:    1.1 %
  Gewählter Punkt OOS vor Median:   85.8 %
  Lesart: PBO nahe 0 = Auswahl trägt, um 57 % = Zufall (ungerade Punktezahl: (N + 1) / (2N)), darüber = Auswahl schadet.

Sharpe_Halten                          0.75
CAGR_Halten_Prozent                   11.06
```

</details>

Der beste Filter (n = 50) erreicht eine Sharpe
Ratio von 0,676, das reine Halten des Aktien-ETF unter denselben
Bedingungen 0,75 und eine CAGR von 11,06 % statt 7,84 %. Keine Variante
schlägt also das Halten. Das passt zu den Daten: Sie enthalten keinen
Trend, den ein Filter ausnutzen könnte. Die beiden Prüfungen auf
Überanpassung schlagen trotzdem nicht an, und das ist kein Widerspruch.
Die Deflated Sharpe Ratio prüft, ob die beste Sharpe Ratio über dem
Wert liegt, den sieben Versuche ohne jedes Können erwarten ließen (0,048
p. a.); mit 0,671 tut sie das klar (DSR 99,8 %). Die PBO von 14,2 % sagt,
dass die im Ausschnitt beste Variante meist auch außerhalb davon vorn
liegt. Beide Prüfungen vergleichen gegen null bzw. die geprüften Varianten
untereinander; den Vergleich mit dem Halten muss man selbst anstellen.

Die zweite Stellschraube ist das Rebalancing. `sensitivity_rebalancing()`
rechnet die Mischung (hier nur mit 10.000 EUR Einmalanlage) für mehrere
Rhythmen mit und ohne Toleranzband von 5 Prozentpunkten:

<details>
<summary><b>R</b></summary>

```r
sensitivity_rebalancing(data, mix,
  frequencies = list(monat = c("month", 1), quartal = c("quarter", 1), jahr = c("year", 1)),
  bands = c(NA, 5), sim_args = list(start_value = 10000, tax = steuer))
```

```text
Toleranzbänder: absolut (Prozentpunkte)
 frequency offset band   cagr max_drawdown sharpe ulcer_index  taxes trades
     monat     NA    - 8.68 %      13.18 %  1.139       0.042 3751.3   49.0
     monat     NA    5 8.98 %      11.86 %  1.187       0.040 1247.8    2.9
   quartal     NA    - 8.93 %      12.98 %  1.167       0.042 3165.3   16.7
   quartal     NA    5 8.96 %      12.74 %  1.173       0.041  909.7    2.3
      jahr     NA    - 9.05 %      12.16 %  1.181       0.041  981.8    5.0
      jahr     NA    5 9.05 %      12.29 %  1.175       0.040  354.4    1.3
      none     NA    - 9.05 %      18.07 %  0.996       0.057    0.0    0.3
cagr: mit Sparplan geldgewichtet (XIRR), sonst CAGR des Depotwerts
```

</details>

<details>
<summary><b>Python</b></summary>

```python
print(simlev.sensitivity_rebalancing(data, mix,
    frequencies={"monat": ["month", 1], "quartal": ["quarter", 1], "jahr": ["year", 1]},
    bands=[np.nan, 5], sim_args={"start_value": 10000, "tax": steuer}))
```

```text
Toleranzbänder: absolut (Prozentpunkte)
 frequency offset band   cagr max_drawdown sharpe ulcer_index  taxes trades
     monat     NA    - 8.68 %      13.18 %  1.139       0.042 3751.3   49.0
     monat     NA    5 8.98 %      11.86 %  1.187       0.040 1247.8    2.9
   quartal     NA    - 8.93 %      12.98 %  1.167       0.042 3165.3   16.7
   quartal     NA    5 8.96 %      12.74 %  1.173       0.041  909.7    2.3
      jahr     NA    - 9.05 %      12.16 %  1.181       0.041  981.8    5.0
      jahr     NA    5 9.05 %      12.29 %  1.175       0.040  354.4    1.3
      none     NA    - 9.05 %      18.07 %  0.996       0.057    0.0    0.3
cagr: mit Sparplan geldgewichtet (XIRR), sonst CAGR des Depotwerts
```

</details>

<details>
<summary><b>Julia</b></summary>

```julia
display(sensitivity_rebalancing(data, mix;
    frequencies = RList("monat" => ("month", 1), "quartal" => ("quarter", 1), "jahr" => ("year", 1)),
    bands = [missing, 5], sim_args = (start_value = 10000, tax = steuer)))
```

```text
Toleranzbänder: absolut (Prozentpunkte)
 frequency offset band   cagr max_drawdown sharpe ulcer_index  taxes trades
     monat     NA    - 8.68 %      13.18 %  1.139       0.042 3751.3   49.0
     monat     NA    5 8.98 %      11.86 %  1.187       0.040 1247.8    2.9
   quartal     NA    - 8.93 %      12.98 %  1.167       0.042 3165.3   16.7
   quartal     NA    5 8.96 %      12.74 %  1.173       0.041  909.7    2.3
      jahr     NA    - 9.05 %      12.16 %  1.181       0.041  981.8    5.0
      jahr     NA    5 9.05 %      12.29 %  1.175       0.040  354.4    1.3
      none     NA    - 9.05 %      18.07 %  0.996       0.057    0.0    0.3
cagr: mit Sparplan geldgewichtet (XIRR), sonst CAGR des Depotwerts
```

</details>

**Einordnung:** Ohne Rebalancing (`none`) fällt die Sharpe Ratio auf
0,996, und der größte Rückgang steigt auf 18,07 %. Häufiges Umschichten
hält das Risiko klein, kostet aber Steuern: monatlich ohne Band
3.751 EUR, jährlich mit Band 354 EUR. Die
Sharpe Ratio liegt bei allen Rhythmen mit Rebalancing zwischen 1,139 und
1,187; das Toleranzband senkt die Zahl der Umschichtungen und die Steuer
deutlich, bei kaum veränderten Kennzahlen. Das ist die Begründung
für das jährliche Rebalancing mit Band in Abschnitt „Ansparphase mit `simulation()`“.

### Planung: Wird das Ziel erreicht?

`portfolio_returns()` bildet die Jahresrenditen fester Mischungen aus den
Daten, `planning_goal()` sucht darauf die beste Mischung für das Ziel, auch
mit Wechsel von Jahr zu Jahr (dynamische Programmierung nach Das u. a.
2020). Die Rechnung ist vor Steuern und Kosten.

<details>
<summary><b>R</b></summary>

```r
kandidaten <- list(klassisch = c(AKTIEN = 0.6, ANLEIHEN = 0.4),
                   mix       = c(AKTIEN = 0.4, ANLEIHEN = 0.3, ROHSTOFFE = 0.15, MFUTURES = 0.15),
                   aktien    = c(AKTIEN = 1))
planning_goal(portfolio_returns(data, kandidaten), start_value = 10000, goal = 250000,
              horizon = 20, contributions = 3600, seed = 1)
```

```text
Zielplanung: Ziel 250 000 in 20 Perioden, Start 10 000, Zahlungen 3 600 je Periode
Zielwahrscheinlichkeit dynamisch: 80.8 % (Vorwärtssimulation, SE 0.6 Prozentpunkte; DP-Wert 81.1 %)
Bester fester Kandidat: aktien mit 76.0 %

klassisch       mix    aktien
     62.0      63.6      76.0

Wahl im ersten Schritt: aktien
```

</details>

<details>
<summary><b>Python</b></summary>

```python
kandidaten = {"klassisch": {"AKTIEN": 0.6, "ANLEIHEN": 0.4},
              "mix": {"AKTIEN": 0.4, "ANLEIHEN": 0.3, "ROHSTOFFE": 0.15, "MFUTURES": 0.15},
              "aktien": {"AKTIEN": 1}}
print(simlev.planning_goal(simlev.portfolio_returns(data, kandidaten), start_value=10000, goal=250000,
                           horizon=20, contributions=3600, seed=1))
```

```text
Zielplanung: Ziel 250 000 in 20 Perioden, Start 10 000, Zahlungen 3 600 je Periode
Zielwahrscheinlichkeit dynamisch: 80.8 % (Vorwärtssimulation, SE 0.6 Prozentpunkte; DP-Wert 81.1 %)
Bester fester Kandidat: aktien mit 76.0 %

klassisch       mix    aktien
     62.0      63.6      76.0

Wahl im ersten Schritt: aktien
```

</details>

<details>
<summary><b>Julia</b></summary>

```julia
kandidaten = RList("klassisch" => (AKTIEN = 0.6, ANLEIHEN = 0.4),
                   "mix"       => (AKTIEN = 0.4, ANLEIHEN = 0.3, ROHSTOFFE = 0.15, MFUTURES = 0.15),
                   "aktien"    => (AKTIEN = 1,))
display(planning_goal(portfolio_returns(data, kandidaten), 10000, 250000, 20;
                      contributions = 3600, seed = 1))
```

```text
Zielplanung: Ziel 250 000 in 20 Perioden, Start 10 000, Zahlungen 3 600 je Periode
Zielwahrscheinlichkeit dynamisch: 80.8 % (Vorwärtssimulation, SE 0.6 Prozentpunkte; DP-Wert 81.1 %)
Bester fester Kandidat: aktien mit 76.0 %

klassisch       mix    aktien
     62.0      63.6      76.0

Wahl im ersten Schritt: aktien
```

</details>

**Einordnung:** Mit fester Mischung erreichen 60/40 und die
Mischung das Ziel in 62,0 % bzw. 63,6 % der Fälle, reine Aktien in
76,0 %. Für ein hohes Ziel zählt die Rendite mehr als die Schwankung. Wer
die Mischung jedes Jahr nach dem erreichten Vermögen neu wählt, kommt auf
80,8 % und beginnt mit Aktien. Die Rechnung kennt nur die Jahresrenditen
der Daten, keine Steuern und keine Kosten; der echte Lauf der Mischung
endete in Abschnitt „Ansparphase mit `simulation()`“ nach Steuern bei 243.709 EUR.

### Entnahmephase mit Steuer

`withdrawal_simulation()` rechnet auf den Jahresrenditen der
Bootstrap-Pfade aus Abschnitt „Robustheit: Bootstrap-Studie und Regime“ (Strategie `mix`). Als Startvermögen dient
das Ergebnis der Ansparphase: SimLev übernimmt Depotwert und
Anschaffungskosten der offenen Lots und verkauft nach FIFO. Die
Entnahmephase führt das Depot vereinfacht als einen Bestand:
Teilfreistellung (hier das Mittel 0,4 × 30 % = 12 %), Vorabpauschale und
Verkaufskosten gelten für alles, Ordergebühren entfallen; SimLev weist
darauf mit Warnungen hin. Die Regel `"constant"` entnimmt im ersten
Jahr 4 % und danach denselben realen Betrag (Inflation hier 2 % p. a.).
Der Vergleich mit Günstigerprüfung nimmt ein zu versteuerndes Einkommen
von 15.000 EUR im Jahr an, etwa aus einer Rente.

<details>
<summary><b>R</b></summary>

```r
entnahme <- function(tax) {
  withdrawal_simulation(study, withdrawal_rule("constant", rate = 4), strategy = "mix",
                        years = 15, inflation = 2, start_value = res_mix,
                        partial_exemption = 12, sale_cost = 0.15, base_rate = 2.29, tax = tax)
}
wd <- entnahme(tax_profile())
wd
wd_gp <- entnahme(tax_profile(guenstigerpruefung = TRUE, income = income_tariff(15000)))
wd_gp
```

```text
══════════════════════════════════════════════════════════════
                 SimLev Entnahme-Simulation
══════════════════════════════════════════════════════════════

  Regel:            Konstante reale Entnahme (Bengen/Trinity)
  Pfade:            100 Pfade über 15 Jahre, Startvermögen 243709
  Steuern:          deutsche Privatperson (vereinfacht)

  Erfolgsquote:     100.0 % (Depot reicht für alle geplanten Entnahmen)
  Kapitalerhalt:    22.0 % (reales Endvermögen >= Start)
  SWR (5-%-Quantil PWR): 7.30 % der Startsumme

  real, in Startkaufkraft            q05       q25       q50       q75       q95
  Endvermögen                     114275    160528    195045    235051    328456
  Entnahme Jahr 1                   9748      9748      9748      9748      9748
  Konsum Jahr 1                     9748      9748      9748      9748      9748
  Konsum Jahr 10                    9748      9748      9748      9748      9748
  Konsum Jahr 20                     –       –       –       –       –
  Konsum Jahr 30                     –       –       –       –       –
  Konsum Durchschnitt               9748      9748      9748      9748      9748
  Konsum Minimum                    9748      9748      9748      9748      9748
  Sicherheitsäquiv. (g=2)           9748      9748      9748      9748      9748
  Max. Konsumrückgang              0.00%     0.00%     0.00%     0.00%     0.00%
  PWR                              7.30%     8.15%     8.78%     9.53%    10.59%
  Steuern gesamt                   27487     31451     33665     36481     41947

══════════════════════════════════════════════════════════════
...
  Kapitalerhalt:    24.0 % (reales Endvermögen >= Start)
...
  Steuern gesamt                   24458     28267     30436     33267     38870
...
```

</details>

<details>
<summary><b>Python</b></summary>

```python
def entnahme(tax):
    return simlev.withdrawal_simulation(study, rule=simlev.withdrawal_rule(type="constant", rate=4), strategy="mix",
                                        years=15, inflation=2, start_value=res_mix,
                                        partial_exemption=12, sale_cost=0.15, base_rate=2.29, tax=tax)
wd = entnahme(simlev.tax_profile())
print(wd)
wd_gp = entnahme(simlev.tax_profile(guenstigerpruefung=True, income=simlev.income_tariff(15000)))
print(wd_gp)
```

```text
══════════════════════════════════════════════════════════════
                 SimLev Entnahme-Simulation
══════════════════════════════════════════════════════════════

  Regel:            Konstante reale Entnahme (Bengen/Trinity)
  Pfade:            100 Pfade über 15 Jahre, Startvermögen 243709
  Steuern:          deutsche Privatperson (vereinfacht)

  Erfolgsquote:     100.0 % (Depot reicht für alle geplanten Entnahmen)
  Kapitalerhalt:    22.0 % (reales Endvermögen >= Start)
  SWR (5-%-Quantil PWR): 7.30 % der Startsumme

  real, in Startkaufkraft            q05       q25       q50       q75       q95
  Endvermögen                     114275    160528    195045    235051    328456
  Entnahme Jahr 1                   9748      9748      9748      9748      9748
  Konsum Jahr 1                     9748      9748      9748      9748      9748
  Konsum Jahr 10                    9748      9748      9748      9748      9748
  Konsum Jahr 20                     –       –       –       –       –
  Konsum Jahr 30                     –       –       –       –       –
  Konsum Durchschnitt               9748      9748      9748      9748      9748
  Konsum Minimum                    9748      9748      9748      9748      9748
  Sicherheitsäquiv. (g=2)           9748      9748      9748      9748      9748
  Max. Konsumrückgang              0.00%     0.00%     0.00%     0.00%     0.00%
  PWR                              7.30%     8.15%     8.78%     9.53%    10.59%
  Steuern gesamt                   27487     31451     33665     36481     41947

══════════════════════════════════════════════════════════════
...
  Kapitalerhalt:    24.0 % (reales Endvermögen >= Start)
...
  Steuern gesamt                   24458     28267     30436     33267     38870
...
```

</details>

<details>
<summary><b>Julia</b></summary>

```julia
entnahme(tax) = withdrawal_simulation(study, withdrawal_rule("constant"; rate = 4); strategy = "mix",
    years = 15, inflation = 2, start_value = res_mix,
    partial_exemption = 12, sale_cost = 0.15, base_rate = 2.29, tax = tax)
wd = entnahme(tax_profile())
display(wd)
wd_gp = entnahme(tax_profile(; guenstigerpruefung = true, income = income_tariff(15000)))
display(wd_gp)
```

```text
══════════════════════════════════════════════════════════════
                 SimLev Entnahme-Simulation
══════════════════════════════════════════════════════════════

  Regel:            Konstante reale Entnahme (Bengen/Trinity)
  Pfade:            100 Pfade über 15 Jahre, Startvermögen 243709
  Steuern:          deutsche Privatperson (vereinfacht)

  Erfolgsquote:     100.0 % (Depot reicht für alle geplanten Entnahmen)
  Kapitalerhalt:    22.0 % (reales Endvermögen >= Start)
  SWR (5-%-Quantil PWR): 7.30 % der Startsumme

  real, in Startkaufkraft            q05       q25       q50       q75       q95
  Endvermögen                     114275    160528    195045    235051    328456
  Entnahme Jahr 1                   9748      9748      9748      9748      9748
  Konsum Jahr 1                     9748      9748      9748      9748      9748
  Konsum Jahr 10                    9748      9748      9748      9748      9748
  Konsum Jahr 20                     –       –       –       –       –
  Konsum Jahr 30                     –       –       –       –       –
  Konsum Durchschnitt               9748      9748      9748      9748      9748
  Konsum Minimum                    9748      9748      9748      9748      9748
  Sicherheitsäquiv. (g=2)           9748      9748      9748      9748      9748
  Max. Konsumrückgang              0.00%     0.00%     0.00%     0.00%     0.00%
  PWR                              7.30%     8.15%     8.78%     9.53%    10.59%
  Steuern gesamt                   27487     31451     33665     36481     41947

══════════════════════════════════════════════════════════════
...
  Kapitalerhalt:    24.0 % (reales Endvermögen >= Start)
...
  Steuern gesamt                   24458     28267     30436     33267     38870
...
```

</details>

**Einordnung:** Die Entnahme von 9.748 EUR im Jahr (4 % von
243.709 EUR) gelingt auf allen 100 Pfaden; nach 15 Jahren liegt das reale
Vermögen im Median bei 195.045 EUR, und 22 % der Pfade haben ihr
Startvermögen real erhalten. Die höchste Anfangsrate, die auf 95 % der
Pfade bis zum vollständigen Verzehr getragen hätte (SWR), liegt bei
7,30 %. An Steuern fallen im Median
33.665 EUR an (real). Mit Günstigerprüfung und 15.000 EUR übrigem zu
versteuernden Einkommen sind es 30.436 EUR, weil der persönliche Tarif
dann unter der Abgeltungsteuer liegt. `withdrawal_rule()` kennt 14 Regeln, `withdrawal_max_rate()` sucht die
höchste Anfangsrate für eine Ziel-Erfolgsquote.

### Ausblick

Einige Teile von SimLev passen nicht in diesen Strang
und stehen in den Tutorials
([R](r/vignettes/getting-started.Rmd), [Python](python/examples/tutorial.md),
[Julia](julia/examples/tutorial.md)) und den Hilfeseiten:

- **Taktische Allokation** (`tactical_rotation()`,
  `tactical_target_volatility()`, `tactical_simulation()`): Die
  synthetischen Reihen haben weder Trend noch wechselnde Volatilität;
  taktische Regeln hätten hier nichts zu finden.
- **Fonds-Wrapper** (`wrapper_config()`, `wrapper_nav()`): eine innere
  Strategie mit Verwaltungs- und Performancegebühr als ein Asset, etwa ein
  Mischfonds statt der vier Einzelpositionen.
- **Hebelprodukte**: `series_leverage()`, `split_rule()`,
  `sensitivity_leverage()` und die Rückrechnung von Produkten mit
  `backcast_fit()` und `backcast()`.
- **Steuerdetails**: Kirchensteuer, Verlustvortrag, § 23 EStG mit
  Haltefrist (z. B. Gold-ETC mit Lieferanspruch) und `harvest_rule()`.
- **Datenaufbereitung**: `series_align()`, `series_splice()`,
  `series_convert_currency()`, `series_deflate()` und Indizes wie
  `index_bond()` und `index_total_return()`.
- **Szenarien und Tail-Risiko**: `scenario_entropy_pooling()`,
  `scenario_crisis()`, `scenario_copula()`, `copula_fit()`, `tail_covar()`.
- **Statistische Prüfungen**: `sharpe_test()`, `sharpe_haircut()`,
  `overfit_reality_check()`, `overfit_walk_forward()`,
  `portfolio_cpcv()`.
- **Sparplan oder Einmalanlage**: `planning_lumpsum_vs_dca()`.

## Bitgleichheit

Für dieselben Eingaben liefern R, Python und Julia dieselben
IEEE-754-Gleitkommazahlen ohne Toleranz, dazu dieselben Druckausgaben,
Warnungen und Fehlermeldungen; `NA` und `NaN` werden unterschieden, ebenso
das Vorzeichen der Null. Die Fallstudie zeigt das an ihren Ausgaben; der
folgende Block druckt zusätzlich das Bitmuster einiger Ergebnisse, das in
allen drei Sprachen gleich ist:

<details>
<summary><b>R</b></summary>

```r
bits <- function(x) paste(rev(as.character(writeBin(x, raw(), endian = "little"))), collapse = "")
cat(bits(tail(res_mix$worth, 1)), bits(res_mix$tax_report$total_taxes_paid),
    bits(wd$paths$taxes[1]), sep = "\n")
```

```text
410dbfebd8c896dd
40c17e32ea2a1522
40e0e0e2524773cc
```

</details>

<details>
<summary><b>Python</b></summary>

```python
bits = lambda x: struct.pack(">d", x).hex()
print(bits(res_mix.worth[-1]), bits(res_mix.tax_report["total_taxes_paid"]),
      bits(wd.paths["taxes"][0]), sep="\n")
```

```text
410dbfebd8c896dd
40c17e32ea2a1522
40e0e0e2524773cc
```

</details>

<details>
<summary><b>Julia</b></summary>

```julia
bits(x) = string(reinterpret(UInt64, Float64(x)); base = 16, pad = 16)
println(bits(res_mix.worth[end]), "\n", bits(res_mix.tax_report.total_taxes_paid), "\n",
        bits(wd.paths["taxes"][1]))
```

```text
410dbfebd8c896dd
40c17e32ea2a1522
40e0e0e2524773cc
```

</details>

Dafür sorgen:

- **Eine gemeinsame C/C++-Bibliothek** in [`core/`](core/) (Zufall,
  Verteilungen, lineare Algebra, Optimierer, Modelle, Bootstrap-Kerne und
  die Engine von `simulation()`), in allen Sprachen mit denselben
  Gleitkomma-Einstellungen übersetzt.
- **R-Grundfunktionen in Python und Julia** (Summen, Sortierung, Quantile,
  Datumsformate, Formatierung, Druck), nachgebildet bzw. gemeinsam in C
  (`core/slc_rbase*`); Herkunft in den `COPYRIGHTS`-Dateien der Pakete.
- **Ein eigener Zufallsgenerator** (xoshiro256**): `simlev_seed()` und
  `seed` steuern ihn in allen Sprachen, `set.seed()`, numpy oder Julias
  Zufall wirken nicht; Ergebnisse hängen nicht von `cores` ab.

Geprüft ist Linux auf x86-64 mit glibc (80-Bit-`long double`, glibc-libm,
System-ICU für die Sortierung von Zeichenketten); unter macOS und Windows
ist der Gleichlauf nicht zugesagt. Grafiken sind nicht bitgleich, die
dargestellten Daten schon. Die Gleichlaufprüfung
`tests/werkzeuge/gleichlauf/run.sh` vergleicht die drei Sprachen Bit für Bit
anhand gemeinsamer Referenzfälle ([`tests/README.md`](tests/README.md)).

## Dokumentation

| Was | Wo |
|---|---|
| Tutorial R (Daten, Strategie, `simulation()` mit Kosten, Sparplan, Rebalancing, Splits, Steuer und Wrapper, Auswertung, Bootstrap, Entnahme, Optimierung und Forschung, Grafik) | Vignette [`r/vignettes/getting-started.Rmd`](r/vignettes/getting-started.Rmd), im Paket `vignette("getting-started", package = "SimLev")` |
| Tutorial Python, dieselben Kapitel | [`python/examples/tutorial.md`](python/examples/tutorial.md) |
| Tutorial Julia, dieselben Kapitel | [`julia/examples/tutorial.md`](julia/examples/tutorial.md) |
| Funktionsreferenz | R: Hilfeseiten (`?simulation`, Übersicht und Glossar in `?SimLev`); Python: Docstrings (`help(simlev.simulation)`); Julia: Docstrings (`?simulation`) |
| Schreibweisen je Sprache | [`r/README.md`](r/README.md), [`python/README.md`](python/README.md), [`julia/README.md`](julia/README.md) |
| Zuordnung der Funktionen und Dateien R / Python / Julia | [`STRUKTUR.md`](STRUKTUR.md) |
| Quellen der Verfahren und der Beispieldaten | [`LITERATUR.md`](LITERATUR.md) |
| Änderungen je Version | [`r/NEWS.md`](r/NEWS.md), [`python/NEWS.md`](python/NEWS.md), [`julia/NEWS.md`](julia/NEWS.md) |
| Weiterentwicklung | [`r/DEVELOPING.md`](r/DEVELOPING.md), [`python/DEVELOPING.md`](python/DEVELOPING.md), [`julia/DEVELOPING.md`](julia/DEVELOPING.md), [`core/README.md`](core/README.md) |

Alle Beispiele der Tutorials und READMEs führt
`tests/werkzeuge/doku/beispiele.sh` in den drei Sprachen aus und vergleicht
die gezeigten Ausgaben.

## Grenzen und Hinweise

- **Keine Steuer- oder Anlageberatung.** Nicht jeder Einzelfall ist
  abgebildet (z. B. ausländische Quellensteuer). SimLev wendet die *heutige*
  Rechtslage auf die Vergangenheit an.
- **Hebel, Dividenden und Finanzierungskosten** müssen in den Kursreihen
  enthalten sein; SimLev berechnet sie nicht.
- **Ein Backtest ist keine Prognose.** Gegen Überanpassung helfen
  `overfit_pbo()`, `sharpe_deflated()` und `overfit_walk_forward()`.

## Aufbau des Repositorys

```
SimLev-Repos/
├── README.md, LICENSE.md
├── STRUKTUR.md     Zuordnung R / Python / Julia (erzeugt aus tests/schnittstelle)
├── LITERATUR.md    Quellen der Verfahren und der Beispieldaten
├── core/           C-Bibliothek und gemeinsame C++-Kerne; Kopien in r/src,
│                   python/src/core und julia/deps/core (core/sync.py)
├── r/              R-Paket mit Vignette (r/vignettes), Beispieldaten (r/inst/extdata)
│                   und Abbildungen (r/man/figures)
├── python/         Python-Paket, Tutorial und Beispiele (python/examples)
├── julia/          Julia-Paket, Tutorial und Beispiele (julia/examples)
└── tests/          Tests nach Zweck (Katalog tests/README.md); die Pakete brauchen sie nicht
```

Jede Fassung ist ein eigenständiges Paket mit eigener Versionsnummer
(`r/DESCRIPTION`, `python/pyproject.toml`, `julia/Project.toml`).

## Hilfe und Mitwirken

Fragen, Fehlerberichte und Vorschläge sind als
[Issue](https://github.com/chemicalstats/SimLev-Repos/issues) willkommen,
mit Sprachfassung und kleinem reproduzierbarem Beispiel. Änderungen an der
Rechenlogik gehören in alle drei Fassungen und müssen die
Gleichlaufprüfung bitgleich bestehen.

## Lizenz

SimLev steht unter der **GNU General Public License, Version 3** (GPL-3).
Den vollständigen Lizenztext finden Sie in [LICENSE.md](LICENSE.md).

Sie dürfen SimLev frei nutzen, studieren, anpassen und weitergeben; wer es
weitergibt, auch verändert, muss das unter derselben Lizenz und mit dem
Quellcode tun (*Copyleft*). Die Software wird ohne jede Gewährleistung
bereitgestellt. Rechtlich maßgeblich ist allein der englische Lizenztext.

© 2026 ChemicalStats von der Mauerstrasse
