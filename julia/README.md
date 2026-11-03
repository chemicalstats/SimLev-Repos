<p align="center">
  <img src="../r/man/figures/logo.png" alt="SimLev-Logo" width="220" />
</p>

<h1 align="center">SimLev für Julia</h1>

<p align="center">
  <strong>Simulation und Backtesting für Basis-, Hebel- und Multi-Asset-Strategien für Exchange Traded Products</strong>
</p>

---

Dies ist die Julia-Fassung von SimLev, eine von drei gleichwertigen
Fassungen: Die Rechenkerne liegen als gemeinsamer C/C++-Code in
[`core/`](../core/) (`Pkg.build()` übersetzt ihn); Julia bildet die
Schnittstelle darum (Eingabeprüfung, Datenaufbereitung, Ablauf,
Ergebnisobjekte, Druck, Grafik). Die Engine `simulation()` und alle
Erweiterungen haben in R, Python und Julia gleiche Namen, Argumente und
Voreinstellungen und rechnen **bitgleich** (Ergebnisse, Druckausgabe,
Warnungen und Fehlermeldungen). Sie läuft ohne R und braucht keine
externen Julia-Pakete, nur die Standardbibliothek.

**Einstieg:** das [Tutorial](examples/tutorial.md) mit Daten, Strategie,
`simulation()` mit allen Bausteinen, Auswertung, Bootstrap, Entnahme,
Optimierung und Grafik. Beschreibung, Argumente, Rückgabe und ein Beispiel
je Funktion stehen in den Docstrings (`?simulation`). Übersicht,
Bitgleichheit und Lizenz stehen in der [Haupt-README](../README.md), die
Quellen der Verfahren in [`LITERATUR.md`](../LITERATUR.md).

## Installation

Julia ≥ 1.10 und ein C- und C++-Compiler: `Pkg.add` bzw. `Pkg.build`
führt `deps/build.jl` aus, das die Bibliothek von SimLev (Quellen in
`deps/core/`) übersetzt; andere Compiler wählen `ENV["SIMLEV_CC"]` und
`ENV["SIMLEV_CXX"]`. Ohne die Bibliothek bricht `using SimLev` mit einem
Hinweis auf `Pkg.build` ab.

<!-- beispiele: nicht ausführen -->
``` julia
using Pkg
Pkg.add(url = "https://github.com/chemicalstats/SimLev-Repos", subdir = "julia")
# oder aus einem lokalen Klon:
# Pkg.develop(path = "pfad/zu/SimLev-Repos/julia")
```

Beim ersten `using SimLev` kompiliert Julia das Paket einmalig vor (einige
Minuten); danach lädt es in unter einer Sekunde, und der erste Aufruf einer
Hauptfunktion in einer Sitzung braucht höchstens etwa eine Sekunde.

## Kurzbeispiel

Das vollständige Skript mit Dashboard liegt unter
[`examples/schnellstart.jl`](examples/schnellstart.jl)
(`julia --project=. examples/schnellstart.jl` im Ordner `julia/`).

``` julia
using SimLev, Dates, Random

rng = MersenneTwister(42)
n = 365 * 10
data = (date  = collect(Date(2015, 1, 1):Day(1):Date(2015, 1, 1) + Day(n - 1)),
        WORLD = 100 .* cumprod(1 .+ 4e-4 .+ 0.010 .* randn(rng, n)),
        BONDS =  50 .* cumprod(1 .+ 1e-4 .+ 0.003 .* randn(rng, n)))
strategy = create_strategy(
    WORLD = asset_config("etf", "bnh"; share = 0.7, spread = 0.1, partial_exemption = 30),
    BONDS = asset_config("etf", "bnh"; share = 0.3, spread = 0.1, partial_exemption = 0),
)
result = simulation(data, strategy; start_value = 10000,
                    rebalance = rebalance_plan(1; unit = "year"),
                    tax = tax_profile(26.375), liquidate = true, risk_free = 2)
println(round(result.worth[end]; digits = 2))
```

``` text
15581.6
```

## Von R zu Julia

Pflichtargumente stehen vor dem Semikolon, die übrigen werden als
Schlüsselwörter übergeben. Einige Funktionen nehmen wie in R weitere
Argumente auch positionell, etwa `asset_config("etf", "bnh", 0.6, 0.1, 30)`,
`bootstrap_study(df, cfg, "stationary"; …)` oder die Bausteine
(`dca_plan(100, 1; days = 15)`, `split_rule([50, 200])`).

| R | Julia |
|---|---|
| `NULL` | `nothing` |
| `TRUE` / `FALSE` | `true` / `false` |
| `NA` | `SimLev.NA` (numerisch, von `NaN` unterscheidbar über `isna_strict`), sonst `missing` |
| `c(20, 400)` | `[20, 400]` |
| `c(us = "us_ret")`, `list(A = "w1")` | `(us = "us_ret",)`, `(A = "w1",)`; als Objekt `named("us" => "us_ret")` bzw. `RList("A" => "w1")` |
| `list(list(base = "eu", leverage = 2))` | `[(base = "eu", leverage = 2)]` |
| `data.frame(...)` | `RFrame("date" => …, "WORLD" => …)` oder `RFrame(pairs(nt)...)` aus einem NamedTuple `nt` |
| Matrix mit Zeilen- und Spaltennamen | `NamedMat` |
| `result$worth` | `result.worth` oder `result["worth"]` |
| `result$statistics$sharpe` | `result.statistics.sharpe` |
| `result$report$WORLD$total` | `result.report["WORLD"].total` |
| `print(x)` | `display(x)` |
| `summary(result)` | `summary(result)`; für alle Objekte `r_summary(x)` |
| `plot(result)` | `plot_dashboard(result)`; für alle Objekte `r_plot(x)` |
| `bootstrap_probability(st, cagr > 0.05)` | `bootstrap_probability(st, "cagr > 0.05")` |
| `function(df) signal_sma(df$INDEX, 200)` | `df -> signal_sma(df["INDEX"]; n = 200)` |
| `saveRDS(res, "lauf.rds")`, `readRDS(...)` | `using Serialization; serialize("lauf.jls", res)`, `deserialize(...)` |

Besonderheiten:

- `simulation()` nimmt als Daten ein `RFrame`, ein NamedTuple von
  Vektoren, ein `Dict` oder jede Tabelle mit `propertynames`/`getproperty`
  (etwa einen `DataFrame`); `missing` wirkt wie `NA`. Die Erweiterungen
  erwarten Tabellen als `RFrame` (Spalten mit Namen, Zeilen gleicher Länge).
- Ergebnisobjekte sind `RList` bzw. `RFrame` mit gesetzter Klasse; die
  Elemente stehen in derselben Reihenfolge wie in R. `display(x)` liefert die
  Ausgabe der R-`print`-Methode, `println(x)` nur eine Kurzform.
- Bedingungen als Text werden in **R-Syntax** ausgewertet (derselbe
  Auswerter wie in Python).
- `result.trades` enthält alle Buchungen je Asset; in R gibt es kein
  Gegenstück. Mit `details = true` schreibt `simulation()` das
  Ereignisprotokoll nach `io` (Standard `stdout`).
- Hinweise erscheinen auf `stderr`, Warnungen als `@warn`, Fehler als
  `ErrorException`, mit demselben deutschen Wortlaut wie in R und Python.
- `cores > 1` rechnet mit Threads, wenn Julia mit mehreren Threads gestartet
  ist (`julia -t auto`), sonst nacheinander, stets mit denselben
  Ergebnissen. `bootstrap_study(chunk_dir = …)` speichert Zwischenergebnisse
  in einem eigenen Textformat (nicht mit R lesbar).
- Grafiken entstehen als SVG ohne externe Pakete (`SimLevPlot` mit `svg`,
  `data`, `source`, `kind`); geschrieben wird mit `file = "….svg"`.
- Zeichenketten werden wie in R über die System-ICU sortiert (`SIMLEV_ICU`,
  `SIMLEV_COLLATE=C`).

## Entwicklung

Bauen, Vorkompilieren, Abgleich der C-Quellen (`core/sync.py`), Tests und
Regeln für die Bitgleichheit stehen in [`DEVELOPING.md`](DEVELOPING.md), die
Zuordnung der Dateien zu den R-Dateien in [`STRUKTUR.md`](../STRUKTUR.md),
die Änderungen in [`NEWS.md`](NEWS.md).

## Lizenz

GPL-3, wie das R-Paket. Siehe [LICENSE.md](LICENSE.md).
