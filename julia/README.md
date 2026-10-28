<p align="center">
  <img src="../docs/figures/logo.png" alt="SimLev-Logo" width="220" />
</p>

<h1 align="center">SimLev für Julia</h1>

<p align="center">
  <strong>Simulation und Backtesting für Basis-, Hebel- und Multi-Asset-Strategien für Exchange Traded Products</strong>
</p>

---

Dieses Paket ist die Julia-Fassung 0.5.0 des R-Pakets SimLev. Sie ist ein
**vollständiger Port** der aktuellen R-Fassung 0.5.0: die Engine
`simulation()` und alle Erweiterungen, insgesamt alle 116 Exporte aus
`r/NAMESPACE`. Sie läuft **eigenständig ohne R** und braucht **keine
externen Julia-Pakete**, nur die Standardbibliothek (`Dates`, `Printf`,
`Logging`, `Libdl`) und zum Bau einen C-Compiler für die C-Bibliothek von
SimLev.

Die Julia-Fassung rechnet **bitgleich** zum R-Paket 0.5.0: Jeder
Tageswert, jede Kennzahl, jeder Steuerbetrag, die (deutsche) Druck- und
Konsolenausgabe, Warnungen und Fehlermeldungen stimmen exakt überein. Zufall
und Numerik kommen in beiden aus derselben C-Bibliothek; geprüft wird mit
der Gleichlaufprüfung des Repositorys (siehe
[Gleichlauf](#gleichlauf-und-plattformen)). Die Engine ist je nach
Szenario etwa 5- bis 30-mal so schnell wie das R-Paket (siehe
[Geschwindigkeit](../README.md#geschwindigkeit) in der Haupt-README).

Die Vorversion 0.1.0 enthielt nur die Engine und entsprach einem früheren
Stand des R-Pakets; was sich geändert hat, steht in [`NEWS.md`](NEWS.md).
Hinweise für die Weiterentwicklung stehen in [`DEVELOPING.md`](DEVELOPING.md).

**Die vollständige Dokumentation mit Grundkonzepten, Steuerlogik und
Beispielen für alle drei Sprachen steht in der
[Haupt-README](../README.md).** Die Quellen der Verfahren (Bootstrap, Volatilitätsmodelle, Abhängigkeiten, Portfolio, Tests, Entnahme und die Numerik der eigenen C-Bibliothek) stehen im Abschnitt [Literatur](../README.md#literatur) der Haupt-README. Hier finden Sie nur, was speziell die
Julia-Fassung betrifft.

## Installation

Benötigt wird **Julia ab Version 1.10** (laut `Project.toml`; geprüft ist
die Fassung ab Julia 1.10, zuletzt mit Julia 1.13.2) und ein **C-Compiler**:
`Pkg.add` bzw. `Pkg.build("SimLev")` führt `deps/build.jl` aus, das die
C-Bibliothek von SimLev (Quellen in `deps/core/`, Kopien aus `core/` im
Repository) mit `cc`, `gcc` oder `clang` zu `deps/usr/lib/libslc`
übersetzt; einen anderen Compiler wählt `ENV["SIMLEV_CC"]`. Ohne die
Bibliothek bricht `using SimLev` mit einem Hinweis auf `Pkg.build` ab.
Geprüft ist nur Linux auf x86-64.

``` julia
using Pkg
Pkg.add(url = "https://github.com/chemicalstats/SimLev-Repos", subdir = "julia")
# oder aus einem lokalen Klon:
# Pkg.develop(path = "pfad/zu/SimLev-Repos/julia")
```

Beim ersten `using SimLev` kompiliert Julia das Paket einmalig vor. Das
dauert einige Minuten (auf der Prüfmaschine rund vier); dabei läuft eine
Arbeitslast für Engine und Erweiterungen, die bei der Entwicklung
`SIMLEV_SKIP_PRECOMPILE_EXT=1` (ohne Erweiterungen) bzw.
`SIMLEV_SKIP_PRECOMPILE=1` (ganz) abschaltet. Danach lädt das Paket in
unter einer Sekunde. Der
erste Aufruf einer Funktion in einer Sitzung kompiliert noch nach: Auf der
Prüfmaschine dauerte der erste `simulation()`-Aufruf etwa 2 Sekunden, das
erste Dashboard etwa 5 Sekunden und die erste Bootstrap-Studie einige
Sekunden; jeder weitere Aufruf läuft ohne diese Verzögerung.

## Kurzbeispiel

Das vollständige Skript liegt unter
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

result = simulation(data, strategy;
    start_value = 10000,
    rebalance = rebalance_plan(1; unit = "year"),
    tax = tax_profile(26.375),
    liquidate = true, risk_free = 2)

display(result)
plot_dashboard(result)          # SVG, in Jupyter, Pluto und VS Code direkt sichtbar
```

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

Die Kurse erzeugt hier Julias eigener Zufallsgenerator; sie unterscheiden
sich deshalb von denen der R- und Python-Beispiele. Mit denselben Kursdaten
liefern alle drei Fassungen dasselbe Ergebnis: R 0.5.0 und Python 0.5.0
kommen mit diesen Kursen (als CSV mit voller Genauigkeit übergeben) auf
denselben Endwert, dieselbe CAGR und dieselben Steuern bis auf das letzte
Bit. Umgekehrt zeigt Julia mit den Kursen des R-Beispiels (ebenfalls als
CSV übergeben) wie R 17.765,20 EUR Endwert und 1.368,47 EUR Steuern, mit
zeichengleicher Ausgabe von `display(result)`.

## Von R zu Julia

Funktionsnamen, Argumente und Voreinstellungen sind identisch mit dem
R-Paket. Pflichtargumente stehen vor dem Semikolon, die übrigen werden als
Schlüsselwörter übergeben (`simulation(data, strategy; start_value = 1e4)`,
`portfolio_optimize(df; assets = ["WORLD", "BONDS"], method = "risk_parity")`).
Einige Funktionen nehmen wie in R weitere Argumente auch positionell, etwa
`asset_config("etf", "bnh", 0.6, 0.1, 30)`,
`bootstrap_study(df, cfg, "stationary"; …)` oder die Bausteine von
`simulation()` (`dca_plan(100, 1; days = 15)`, `split_rule([50, 200])`,
`tax_profile(; income = income_rate(42))`).

| R | Julia |
|---|---|
| `NULL` | `nothing` |
| `TRUE` / `FALSE` | `true` / `false` |
| `NA` | `SimLev.NA` (numerisch, von `NaN` unterscheidbar über `isna_strict`), sonst `missing` |
| `c(20, 400)` | `[20, 400]` |
| `c(us = "us_ret", eu = "eu_ret")`, `list(A = "w1")` | `(us = "us_ret", eu = "eu_ret")`, `(A = "w1",)`; als Objekt `named("us" => "us_ret")` (`RVector`) bzw. `RList("A" => "w1")` |
| `list(list(base = "eu", leverage = 2))` | `[(base = "eu", leverage = 2)]` |
| `data.frame(...)` | `RFrame("date" => …, "WORLD" => …)` oder `RFrame(pairs(nt)...)` aus einem NamedTuple `nt` |
| Matrix mit Zeilen- und Spaltennamen | `NamedMat` |
| `result$worth` | `result.worth` oder `result["worth"]` |
| `result$statistics$sharpe` | `result.statistics.sharpe` |
| `result$report$WORLD$total` | `result.report["WORLD"].total` oder `result.report.WORLD.total` |
| `print(x)` | `display(x)` |
| `summary(result)` | `summary(result)`; für alle Objekte `r_summary(x)` |
| `plot(result)` | `plot_dashboard(result)`; für alle Objekte `r_plot(x)` |
| `simlev_seed(42)` | `simlev_seed(42)` |
| `bootstrap_probability(st, cagr > 0.05)` | `bootstrap_probability(st, "cagr > 0.05")` |
| `function(df) signal_sma(df$INDEX, 200)` | `df -> signal_sma(df["INDEX"], 200)` |
| `saveRDS(res, "lauf.rds")`, `readRDS(...)` | `using Serialization; serialize("lauf.jls", res)`, `deserialize(...)` |

**Ergebnisobjekte.** Objekte mit R-Klasse sind `RList` (benannte Liste)
bzw. `RFrame` (data.frame) mit gesetzter Klasse; `SimLevResult` verhält
sich ebenso. Die Elemente stehen in derselben Reihenfolge wie in R und
sind über `x.name` oder `x["name"]` erreichbar, `r_class(x)` und
`inherits(x, "…")` fragen die Klasse ab, `attrs(x)` die übrigen Attribute.
Benannte Vektoren sind `RVector`, Matrizen mit `dimnames` `NamedMat`, ein
Vektor der Länge 1 ist ein Skalar. Für Objekte mit eigener `print`-Methode
im R-Paket und für data.frames liefert `display(x)` bzw. die Ausgabe in der
REPL genau die Ausgabe von R; `println(x)` zeigt nur eine Kurzform wie
`RFrame(1 × 5: strategy, condition, …)`.

Besonderheiten der Julia-Fassung:

- `simulation()` nimmt als Daten ein `RFrame`, ein NamedTuple von
  Vektoren, ein `Dict` (Spaltenname ⇒ Vektor) oder jede Tabelle, die ihre
  Spalten über `propertynames` und `getproperty` bereitstellt, etwa einen
  `DataFrame` aus DataFrames.jl; `missing` wird wie `NA` in R behandelt.
  Die Erweiterungsfunktionen sind dagegen auf den data.frame von R
  ausgelegt: Einige nehmen auch ein NamedTuple, andere (etwa
  `bootstrap_study()` und `portfolio_optimize()`) nur ein `RFrame`.
  Übergeben Sie ihnen deshalb ein `RFrame`; ein NamedTuple `nt` wandelt
  `RFrame(pairs(nt)...)` um.
- Zufallszahlen zieht SimLev aus seinem eigenen Generator in der
  C-Bibliothek (xoshiro256**, in R und Python derselbe; Hüllen in
  `SimLev.SLib`). `simlev_seed(42)` setzt seinen Zustand wie in R;
  zufällige Funktionen nehmen außerdem `seed`. Julias eigene Zufallszahlen
  (wie im Kurzbeispiel) beeinflussen ihn nicht.
- **Bedingungen als Text** (`tactical_rules()`, `bootstrap_probability()`,
  `regime_subset()`, `view_prob()`) werden wie in R in **R-Syntax**
  ausgewertet: `"inflation >= 4"`, `"cagr > 0.05 & max_drawdown <= 0.3"`,
  mit R's Vorrangregeln, NA-Logik, `%in%` und `%%` (derselbe Auswerter
  wie in der Python-Fassung).
- `result.trades` enthält zusätzlich alle Buchungen (Lots, Verkäufe,
  Steuerbuchungen wie Vorabpauschalen je Asset); in R gibt es kein Gegenstück.
- Mit `details = true` schreibt `simulation()` das Ereignisprotokoll des
  R-Pakets nach `io` (Standard: `stdout`). Hinweise, die R mit `message()`
  ausgibt, erscheinen auf `stderr`; R-Warnungen sind `@warn`-Meldungen,
  R-Fehler `ErrorException`, jeweils mit dem deutschen Wortlaut des
  R-Pakets.
- `cores > 1` rechnet mit Threads (`Threads.@spawn`), wenn Julia mit mehreren
  Threads gestartet ist (`julia -t auto`, `julia -t 2` oder
  `JULIA_NUM_THREADS`), sonst nacheinander. Jeder Pfad bzw. jede Einheit
  hat einen eigenen Zufallsstrom; die Ergebnisse hängen weder von `cores`
  noch von der Zahl der Threads ab und stimmen mit R überein. Meldungen der Einheiten
  erscheinen in deren Reihenfolge. `bootstrap_study(chunk_dir = …)` schreibt
  die Zwischenstände in einem eigenen Textformat (Dateinamen wie in R auf
  `.rds`, aber nicht mit R lesbar).
- **Grafiken** zeichnet die Julia-Fassung als SVG ohne externe Pakete.
  `plot_dashboard(result)` und alle `plot`-Methoden der Ergebnisobjekte
  (`r_plot(x)`) liefern ein `SimLevPlot` (in Jupyter, Pluto und VS Code
  direkt sichtbar) mit den Feldern `svg` (die Grafik), `data` (die
  dargestellten Werte je Panel als `RFrame` in einer `RList`, nicht
  ausgedünnt und unskaliert), `source` (das Eingabeobjekt) und `kind`
  (dessen Klasse). `plot_dashboard(result)` zeigt dieselben Panels,
  deutschen Beschriftungen und Kennzahlen wie R; die Grafik ist nicht
  bitgleich, die dargestellten Daten schon. Geschrieben wird nur mit
  `file = "….svg"` (andere Endungen brechen mit einer Meldung ab),
  unbekannte Schlüsselwörter ergeben eine Warnung. `export_dashboard(result,
  "backtest.svg"; width = 14, height = 10)` speichert das Dashboard als
  SVG-Datei (Größe in Zoll wie in R, 100 Pixel je Zoll); für PDF oder PNG
  wandeln Sie die SVG-Datei mit einem Werkzeug wie `rsvg-convert` oder
  CairoSVG um. Eigene Grafiken (etwa mit Plots.jl oder Makie) bauen Sie aus
  `data`, z. B. `p = r_plot(result); df = p.data["performance"]` mit den
  Spalten `date` und `strategy`.
- **Zeichenketten-Reihenfolge wie R.** Sortieren und Vergleichen von
  Zeichenketten folgt R's ICU-Kollation (unter `C.UTF-8` „root“: `a A ä b
  B`) über die System-ICU (`libicui18n` per `ccall`, Pfad über `SIMLEV_ICU`);
  `SIMLEV_COLLATE=C` erzwingt die Byte-Reihenfolge wie R unter `LC_ALL=C`,
  `SIMLEV_COLLATE=icu:root` die von R unter `C.UTF-8`. Ohne ICU: Codepunkte
  mit Warnung, nicht bitgleich.

## Erweiterungen

Alle Erweiterungsfunktionen des R-Pakets stehen nach `using SimLev` direkt
bereit (Backcast, Bootstrap, Entnahmephase, vertiefte Analyse,
Parametersuche, Datenaufbereitung, Abhängigkeiten, taktische Allokation,
Optimierung, Szenarien, Planung und statistische Prüfungen; Übersicht in
der [Haupt-README](../README.md#erweiterungen-in-r-python-und-julia)). Zwei
kurze Beispiele mit den Daten und der Strategie von oben:

``` julia
df = RFrame(pairs(data)...)          # data.frame für die Erweiterungen

# Bootstrap-Studie: 200 stationäre Bootstrap-Pfade, auf jedem die Strategie simuliert
cfg = bootstrap_config((WORLD = "WORLD", BONDS = "BONDS"); input = "prices")
study = bootstrap_study(df, cfg, "stationary"; n = 200, params = (L = 250,),
                        strategies = (mix = strategy,), seed = 42, progress = false)
display(r_summary(study))                                            # Verteilungen der Kennzahlen
display(bootstrap_probability(study, "cagr > 0.05 & max_drawdown <= 0.3"))
```

```
  cagr (mit Sparplan geldgewichtet, XIRR)
  Strategie          Mittel        q05       q25       q50       q75       q95
  mix                 5.03%     -0.88%     2.58%     4.77%     7.10%    11.32%
  ...
  max_drawdown
  Strategie          Mittel        q05       q25       q50       q75       q95
  mix                31.64%     21.49%    25.81%    31.06%    36.21%    45.33%
  ...
  strategy                         condition probability         se   n
1      mix cagr > 0.05 & max_drawdown <= 0.3       0.275 0.03157333 200
```

``` julia
# Risikoparität aus Wochenrenditen
opt = portfolio_optimize(df; assets = ["WORLD", "BONDS"], method = "risk_parity")
display(opt)
```

```
SimLev-Optimierung: risk_parity (521 Perioden, week, Kovarianz sample)

 Anlage Gewicht Risikoanteil
  WORLD  22.5 %       50.0 %
  BONDS  77.5 %       50.0 %

Erwartete Rendite 4.30 % p. a. (historisch), Volatilität 5.97 %, Sharpe 0.720
CVaR(0.05) 1.59 % je Periode, CDaR(0.05) 9.34 % (kumuliert)
Diversifikationsverhältnis 1.47, effektive Anzahl: Gewichte 1.5, Risiko 2.0
```

Mit denselben Kursdaten liefert das R-Paket für beide Aufrufe dieselbe
Ausgabe, Zeichen für Zeichen. Auf der Prüfmaschine dauerten beide Aufrufe
zusammen im ersten Durchlauf einer Sitzung rund 15 Sekunden (überwiegend
Kompilierung), danach rund 1,5 Sekunden.

**Fonds-Wrapper** (Zertifikat oder Fonds über eine innere Strategie, Etappe 6.5c): ein Asset der
Strategie, dessen Kurs der Anteilswert der inneren Strategie ist (Verwaltungsgebühr täglich je
Kalendertag, Performancegebühr täglich gegen die High-Water-Mark abgegrenzt und am letzten Datentag
des Jahres festgeschrieben); außen wird er wie ein Einzelpapier gehandelt und besteuert.

``` julia
w = wrapper_config(strategy; rebalance = rebalance_plan(; unit = "quarter"), costs = funds_costs(0.95, 5))
nav = wrapper_nav(df, w)          # RFrame der Klasse SimLevWrapperNav: date, nav, gross, fee, perf_fee, perf_paid, hwm
res = simulation(df, create_strategy(Zertifikat = asset_config("certificate"; spread = 0.5, wrapper = w)))
```

## Gleichlauf und Plattformen

SimLev.jl rechnet Zufall und Numerik mit derselben C-Bibliothek wie R und
Python (Hüllen per `ccall` in `src/slib*.jl`) und bildet darüber hinaus die
Rechenweise von R nach, wo SimLev Grundfunktionen von R nutzt (Einzelheiten
in [`DEVELOPING.md`](DEVELOPING.md), Herkunft in
[`COPYRIGHTS.md`](COPYRIGHTS.md)):

- **80-Bit-`long double`.** R summiert bei `sum()`, `mean()`, `var()`,
  `cumsum()`, `prod()` und `rowSums()` intern mit dem 80-Bit-Format der
  x87-FPU. Julia kennt diesen Typ nicht. SimLev.jl enthält deshalb den Typ
  `F80`: Auf x86-64 rechnet er direkt mit dem x87-Format der Hardware (über
  `llvmcall`), auf anderen Prozessoren mit dem Software-Nachbau `F80Soft`,
  der Rundung, Über- und Unterlauf und die NaN-Regeln der x87-FPU bitgenau
  nachbildet.
- **Mathematische Funktionen** (`exp`, `log`, `log1p`, `pow`, `tanh` …)
  ruft SimLev wie R aus glibc-libm auf (per `ccall`); Julias eigene
  Funktionen weichen in den letzten Bits ab. Potenzen folgen R's
  Sonderregeln (`x^2` als `x*x`, sonst `pow()`).
- **R-Grundfunktionen** im Ordner `src/r/`: Sortieren, Ränge, Quantile,
  `cor`, `approx`, `filter`, `optimize`, `uniroot`, `hclust`, `p.adjust`,
  Formatierung und Druckausgabe (`format`, `formatC`, `sprintf`, `round`,
  `print` von Vektoren, Matrizen und data.frames) und ein Auswerter für
  Bedingungen in R-Syntax.
- Die **C++-Kerne** des R-Pakets (FIFO, Steuern, Markt-Updates, Entnahme,
  Abhängigkeiten, Optimierung, Signale) sind Zeile für Zeile übertragen.

Geprüft wird ohne Toleranz und so streng wie in der Python-Fassung: `NA`
und `NaN` werden unterschieden, ebenso das Vorzeichen der Null; verglichen
werden außerdem Druck- und Konsolenausgabe, Warnungen und Fehlermeldungen.
Die Gleichlaufprüfung `tools/gleichlauf/run.sh` im Repository erzeugt die
Referenzfälle mit dem aktuellen R-Paket neu und vergleicht Julia (und
Python) damit. Der letzte vollständige Lauf (27.10.2026) ergab 4.260 von
4.260 Modul-Fällen und 1.182 von 1.182 Engine-Fällen gleich.

**Plattformen:** Die Referenz ist R unter Linux x86-64 (R 4.3.3); dort ist
die Julia-Fassung geprüft. Die mathematischen Funktionen lädt sie aus
`libm.so.6`, also aus glibc; unter macOS und Windows ist die Fassung nicht
geprüft und der Gleichlauf nicht zugesagt.

## Tests

``` bash
julia --project -e 'using Pkg; Pkg.test()'      # Testsatz „Etappe 9“: Rauchproben der C-Bibliothek
```

Die frühere Testsuite (Engine, R-Interna, Referenzfälle in `golden/`)
beschreibt den Stand vor dem eigenen Zufall und den eigenen Kernen und ist
bis zu ihrem Neuaufbau ausgesetzt; `SIMLEV_LEGACY_TESTS=1` lädt sie
(Dateien, die entfallene Module nutzen, scheitern dann).
`tools/compare_golden.jl` und `tools/compare_reference.jl` vergleichen mit
gespeicherten Fällen; ohne den Schalter enden sie mit einem Hinweis, außer
`SIMLEV_GOLDEN_DIR` bzw. `SIMLEV_MODULE_DIR` zeigt auf frisch erzeugte
Fälle. Maßgeblich ist bis dahin die Gleichlaufprüfung aus der Repo-Wurzel
(`LC_ALL=C.UTF-8 tools/gleichlauf/run.sh --quick`). Für die Fehlersuche
lockern `SIMLEV_LAX_NA=1` (NA = NaN) und `SIMLEV_STRICT_ZERO=0` (−0 = +0)
den Vergleich der Modul-Fälle.

## Projektstruktur

```
Project.toml        Paketbeschreibung (Version, nur Standardbibliothek)
deps/               build.jl (baut die C-Bibliothek libslc), core/ (Kopien der C-Quellen aus core/)
src/
  SimLev.jl         Modul, Exporte, Reihenfolge der Dateien
  slib*.jl          Hüllen der C-Bibliothek per ccall (Zufall, simlev_seed, Verteilungen,
                    lineare Algebra, Optimierer, Modelle, Bootstrap-Kerne)
  r/                R-Grundfunktionen: Datenstrukturen (types.jl), F80: x87-long double (ld80.jl),
                    R-kompatible Numerik und Textausgabe der Engine (rnum.jl, rformat.jl),
                    libm, long-double-Summen (base.jl), stats (stats.jl mit den Themen
                    stats_sort.jl, stats_cor.jl, stats_smooth.jl, stats_optim.jl,
                    stats_models.jl, stats_cluster.jl), outer/diag (linalg.jl),
                    Formatierung (fmt.jl), Kollation (_collate.jl), Bedingungen in
                    R-Syntax (rexpr.jl), parallel.jl
  dates.jl          Datumslogik
  config.jl         asset_config, Strategien
  trigger.jl        rebalance_trigger
  data.jl           Eingabetabellen, Kalender-Auffüllung (LOCF)
  core.jl           Zustand, FIFO, Steuer- und Marktkerne (Port der C++-Dateien)
  engine.jl         simulation() mit sim_phases.jl, sim_loop.jl, sim_evaluate.jl, sim_blocks.jl,
                    wrapper.jl (Fonds-Wrapper: wrapper_config, wrapper_nav)
  tax_tariff.jl     Einkommensteuertarif, tax_tariff
  result.jl         SimLevResult, print/summary
  svg.jl            Grafikmodul: SimLevPlot, plot-API und alle SVG-Zeichenbausteine
  dashboard.jl      statisches SVG-Dashboard (Daten und Panels)
  <modul>.jl        Erweiterungen, je eine R-Datei (data_prep, backcast, bonds, signals,
                    bootstrap, withdrawal, dependence, regimes, ms_garch, scenarios, optimize,
                    tactical, deep_analysis, planning, analysis_tests, overfitting,
                    param_search, sensitivity)
  <name>_core.jl    Ports der C++-Kerne der Erweiterungen (signals, withdrawal, dependence, optimize)
  exports.jl        öffentliche Funktionen der Untermodule für `using SimLev`
  precompile.jl     Arbeitslast für die Vorkompilierung
data/               Tarifdatei steuertarif.csv, R-Farbnamen r_colors.csv
test/               Rauchproben „Etappe 9“; frühere Suite ausgesetzt; reftree.jl liest Referenzfälle
tools/              compare_golden.jl (Engine), compare_reference.jl (Module)
examples/           Lauffähige Beispiele
```

## Lizenz

GPL-3, wie das R-Paket. Siehe [LICENSE.md](LICENSE.md).
