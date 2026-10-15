<p align="center">
  <img src="../docs/figures/logo.png" alt="SimLev-Logo" width="220" />
</p>

<h1 align="center">SimLev für Julia</h1>

<p align="center">
  <strong>Simulation und Backtesting für Basis-, Hebel- und Multi-Asset-Strategien für Exchange Traded Products</strong>
</p>

---

Dieses Paket ist die Julia-Fassung des R-Pakets SimLev. Es läuft
**eigenständig ohne R** und braucht **keine externen Julia-Pakete**, nur die
Standardbibliothek. Die Engine rechnet **bitgleich** zu einem früheren
Stand des R-Pakets, dem Stand vor den Korrekturen (Commit 54b5b4f, damals
ebenfalls als 0.5.0 bezeichnet), geprüft an 2.337 Szenarien. Zur aktuellen
R-Fassung 0.5.0 ist sie **nicht** bitgleich: Deren Engine-Korrekturen,
steuerrechtliche Anpassungen und deutsche Ausgaben sind noch nicht
nachgezogen; alle 105 Golden-Fälle wurden mit der aktuellen R-Fassung neu
erzeugt, siehe Haupt-README. Die Julia-Fassung ist 10- bis 35-mal so schnell
wie das R-Paket.

**Die vollständige Dokumentation mit Grundkonzepten, Steuerlogik und
Beispielen für alle drei Sprachen steht in der
[Haupt-README](../README.md).** Hier finden Sie nur, was speziell die
Julia-Fassung betrifft.

## Installation

Benötigt wird **Julia ab Version 1.10**.

``` julia
using Pkg
Pkg.add(url = "https://github.com/chemicalstats/SimLev-Repos", subdir = "julia")
# oder aus einem lokalen Klon:
# Pkg.develop(path = "pfad/zu/SimLev/julia")
```

Beim ersten `using SimLev` kompiliert Julia das Paket einmalig vor (etwa
20–30 Sekunden). Danach lädt es in Sekundenbruchteilen, und schon der erste
Aufruf von `simulation()` ist schnell.

## Kurzbeispiel

Das vollständige Skript liegt unter
[`examples/schnellstart.jl`](examples/schnellstart.jl).

``` julia
using SimLev, Dates, Random

rng = MersenneTwister(42)
n = 365 * 10
data = (date  = collect(Date(2015, 1, 1):Day(1):Date(2015, 1, 1) + Day(n - 1)),
        WORLD = 100 .* cumprod(1 .+ 4e-4 .+ 0.010 .* randn(rng, n)),
        BONDS =  50 .* cumprod(1 .+ 1e-4 .+ 0.003 .* randn(rng, n)))

strategy = create_strategy(
    WORLD = asset_config("etf", "bnh"; asset_share = 0.7, asset_spread = 0.1, asset_bonus = 30),
    BONDS = asset_config("etf", "bnh"; asset_share = 0.3, asset_spread = 0.1, asset_bonus = 0),
)

result = simulation(data, strategy;
    start_value = 10000,
    balance_mode = true, balance_span = 1, balance_unit = "year",
    tax_mode = "person", tax_rate = 26.375,
    liquidate = true, risk_free = 2)    # CAGR +4.53 %, Endwert 15.558,32 EUR

plot_dashboard(result)
```

## Von R zu Julia

Funktionsnamen und Argumente sind identisch mit dem R-Paket. Argumente von
`simulation()` werden als Schlüsselwörter (nach dem Semikolon) übergeben.

| R | Julia |
|---|---|
| `NULL` | `nothing` |
| `TRUE` / `FALSE` | `true` / `false` |
| `NA` | `missing` (in Daten) bzw. `NA` |
| `c(20, 400)` | `[20, 400]` |
| `list(A = "w1")` | `(A = "w1",)` |
| `data.frame(...)` | NamedTuple oder `DataFrame(...)` |
| `result$worth` | `result.worth` |
| `result$statistics$sharpe` | `result.statistics.sharpe` |
| `result$report$WORLD$total` | `result.report["WORLD"].total` |
| `print(result)`, `summary(result)` | `display(result)`, `summary(result)` |
| `plot(result)` | `plot_dashboard(result)` |
| `plot_interactive(result)` | `plot_interactive(result)` |

Besonderheiten der Julia-Fassung:

- Als Eingabe dienen ein NamedTuple von Vektoren, ein `Dict` (Spaltenname ⇒
  Vektor) oder jede Tabelle, die ihre Spalten über `propertynames` und
  `getproperty` bereitstellt, insbesondere ein `DataFrame` aus
  DataFrames.jl. `missing` wird wie `NA` in R behandelt.
- `simulation()` akzeptiert einfache Strategien im Stil einer R-Liste, etwa
  `["ETF" => (asset_class = "etf", action_type = "bnh", asset_share = 1.0)]`.
- `NA` wird wie in R als besonderes NaN geführt; `isna_strict(x)`
  unterscheidet es von `NaN`. Mit `details = true` schreibt `simulation()`
  das Ereignisprotokoll des R-Pakets nach `io` (Standard: `stdout`).
- `result.trades` enthält alle Lots, Verkäufe, Vorabpauschalen und Gebühren
  je Asset.
- **Doppelte Datumswerte** in `data` führen zu einer Fehlermeldung. R rechnet
  hier stillschweigend mit einem verschobenen Kalender weiter.
- Das **statische Dashboard** wird als SVG gezeichnet (in Jupyter, Pluto und
  VS Code direkt sichtbar). Die Normalverteilungskurve ist auf die
  tatsächliche Klassenbreite skaliert, und Monatswerte außerhalb von ±10 %
  werden in der Randfarbe statt gar nicht eingefärbt. `export_dashboard`
  schreibt `.svg` und `.html`; `.pdf` und `.png` entstehen über
  `rsvg-convert`.

## Bitgleichheit und Plattformen

SimLev.jl bildet nicht nur die Logik, sondern auch die Rechenweise von R
exakt nach:

- **80-Bit-`long double` in Software.** R summiert bei `sum()`, `mean()`,
  `var()`, `cumsum()`, `prod()` und `rowSums()` intern mit dem 80-Bit-Format
  der x87-FPU. Julia kennt diesen Typ nicht. SimLev.jl enthält deshalb einen
  eigenen Typ `F80`, der Addition, Subtraktion, Multiplikation, Division,
  Rundung, Über- und Unterlauf und sogar die NaN-Auswahlregeln der x87-FPU
  bitgenau nachbildet (geprüft gegen echtes C-`long double` an über 800.000
  verketteten Operationen).
- **Potenzen** folgen R's Sonderregeln (`x^2` als `x*x`, sonst `pow()` der
  C-Bibliothek). Kalender, `round()`, `format()`, `sprintf()` und Modulo
  verhalten sich wie in R.
- Die **C++-Kerne** des R-Pakets sind Zeile für Zeile übertragen.

Stand 54b5b4f (früherer Stand des R-Pakets):

| Satz | Szenarien | Ergebnis |
|---|---|---|
| Golden Master (gezielte Steuer- und Sonderpfade + Zufallsfälle) | 68 | alle bitgleich |
| Zufallsszenarien aus `golden_cases.R`, neuer Startwert | 638 | alle bitgleich |
| Stressfälle aus `stress_cases.R` | 1.031 | 1.030 bitgleich, 1 bewusste Abweichung (doppelte Datumswerte) |
| Weitere Stressfälle, neuer Startwert, erst nach Fertigstellung erzeugt | 600 | alle bitgleich |

**Plattformen:** Weil `F80` in Software rechnet, ist die Bitgleichheit nicht
an ein 80-Bit-`long double` der Plattform gebunden. Die einzige verbleibende
Plattformabhängigkeit ist `pow()` aus der C-Bibliothek (glibc unter Linux).
Unter macOS und Windows können davon abhängige Werte – Fondsgebühren, CAGR
und einige Kennzahlen – im letzten Bit abweichen; die Tests markieren das
dort als bekannte Abweichung.

## Tests

``` bash
julia --project -e 'using Pkg; Pkg.test()'                  # Bitgleichheits-Tests gegen ../golden
julia --project tools/compare_golden.jl ../golden/cases     # Golden-Master-Abgleich mit Ausgabe
```

Die Tests lesen die 68 gemeinsamen Fälle aus `golden/cases/` und die 37
Stressfälle aus `golden/extra/` im Hauptverzeichnis des Repositorys. Liegen
sie woanders, setzen Sie `SIMLEV_GOLDEN_DIR` auf den Ordner, der `cases/`
und `extra/` enthält.

## Paketaufbau

```
src/
  SimLev.jl         Modul, Exporte
  ld80.jl           F80: Software-Nachbildung von x87-long double
  rnum.jl           R-kompatible Numerik (sum, mean, var, pow, …)
  rformat.jl        R-kompatible Textausgabe (sprintf, format, round)
  dates.jl          Datumslogik
  config.jl         asset_config, Strategien
  trigger.jl        compute_rebal_trigger
  data.jl           Eingabetabellen, Kalender-Auffüllung (LOCF)
  core.jl           Zustand, FIFO, Steuer- und Marktkerne (Port der C++-Dateien)
  engine.jl         simulation()
  result.jl         SimLevResult, print/summary
  interactive.jl    interaktives HTML-Dashboard
  html_templates.jl HTML-Vorlagen für das interaktive Dashboard
  dashboard.jl      statisches SVG-Dashboard
  precompile.jl     Arbeitslast für die Vorkompilierung
test/               Testsuite und Golden-Master-Hilfsfunktionen
tools/              Abgleich mit den Referenzfällen aus R
examples/           Lauffähige Beispiele
```

## Lizenz

GPL-3, wie das R-Paket. Siehe [LICENSE.md](LICENSE.md).
