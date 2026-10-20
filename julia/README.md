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
`simulation()` und alle Erweiterungen, insgesamt alle 110 Exporte aus
`r/NAMESPACE`. Sie läuft **eigenständig ohne R** und braucht **keine
externen Julia-Pakete**, nur die Standardbibliothek (`Dates`, `Printf`,
`Logging`; `LinearAlgebra` nur als Ersatzweg für Eigenvektoren).

Die Julia-Fassung rechnet **bitgleich** zum R-Paket 0.5.0: Jeder
Tageswert, jede Kennzahl, jeder Steuerbetrag, die (deutsche) Druck- und
Konsolenausgabe, Warnungen und Fehlermeldungen stimmen exakt überein,
geprüft an allen 2.645 gemeinsamen Referenzfällen in [`../golden/`](../golden/)
und an 469 frisch erzeugten Zufalls- und Stressfällen der Engine (siehe
[Bitgleichheit](#bitgleichheit-und-plattformen)). Die Engine ist je nach
Szenario etwa 5- bis 30-mal so schnell wie das R-Paket (siehe
[Geschwindigkeit](../README.md#geschwindigkeit) in der Haupt-README).

Die Vorversion 0.1.0 enthielt nur die Engine und entsprach einem früheren
Stand des R-Pakets; was sich geändert hat, steht in [`NEWS.md`](NEWS.md).
Hinweise für die Weiterentwicklung stehen in [`DEVELOPING.md`](DEVELOPING.md).

**Die vollständige Dokumentation mit Grundkonzepten, Steuerlogik und
Beispielen für alle drei Sprachen steht in der
[Haupt-README](../README.md).** Hier finden Sie nur, was speziell die
Julia-Fassung betrifft.

## Installation

Benötigt wird **Julia ab Version 1.10** (laut `Project.toml`; geprüft ist
die Fassung mit Julia 1.13.2).

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
    WORLD = asset_config("etf", "bnh"; asset_share = 0.7, asset_spread = 0.1, asset_bonus = 30),
    BONDS = asset_config("etf", "bnh"; asset_share = 0.3, asset_spread = 0.1, asset_bonus = 0),
)

result = simulation(data, strategy;
    start_value = 10000,
    balance_mode = true, balance_span = 1, balance_unit = "year",
    tax_mode = "person", tax_rate = 26.375,
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
(`tax_mode = "none"`) wären es 16.339,67 EUR (5,04 % p. a.) gewesen.

Die Kurse erzeugt hier Julias eigener Zufallsgenerator; sie unterscheiden
sich deshalb von denen der R- und Python-Beispiele. Mit denselben Kursdaten
liefern alle drei Fassungen dasselbe Ergebnis: R 0.5.0 und Python 0.5.0
kommen mit diesen Kursen (als CSV mit voller Genauigkeit übergeben) auf
denselben Endwert, dieselbe CAGR und dieselben Steuern bis auf das letzte
Bit. Umgekehrt erzeugt Julia mit `set_seed(42)`,
`SimLev.RRng.rnorm(n, 4e-4, 0.010)` und `SimLev.RBase.r_cumprod()` die
Kurse des R-Beispiels und zeigt dann wie R 17.765,20 EUR Endwert und
1.368,47 EUR Steuern, mit zeichengleicher Ausgabe von `display(result)`.

## Von R zu Julia

Funktionsnamen, Argumente und Voreinstellungen sind identisch mit dem
R-Paket. Pflichtargumente stehen vor dem Semikolon, die übrigen werden als
Schlüsselwörter übergeben (`simulation(data, strategy; start_value = 1e4)`,
`portfolio_optimize(df; assets = ["WORLD", "BONDS"], method = "risk_parity")`).
Einige Funktionen nehmen wie in R weitere Argumente auch positionell, etwa
`asset_config("etf", "bnh", 0.6, 0.1, 30)` oder
`bootstrap_study(df, cfg, "stationary"; …)`.

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
| `plot_interactive(result)` | `plot_interactive(result)` |
| `set.seed(42)` | `set_seed(42)` |
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
- Zufallszahlen erzeugt SimLev mit einem Nachbau von R's Generatoren
  (Mersenne-Twister, L'Ecuyer-CMRG-Streams, `sample.int`, `rnorm` u. a.)
  im Untermodul `SimLev.RRng`. Der Zustand ist global wie `.Random.seed`;
  `set_seed()` entspricht `set.seed()`. Julias eigene Zufallszahlen (wie
  im Kurzbeispiel) beeinflussen ihn nicht.
- **Bedingungen als Text** (`tactical_rules()`, `bootstrap_probability()`,
  `regime_subset()`, `view_prob()`) werden wie in R in **R-Syntax**
  ausgewertet: `"inflation >= 4"`, `"cagr > 0.05 & max_drawdown <= 0.3"`,
  mit R's Vorrangregeln, NA-Logik, `%in%` und `%%` (derselbe Auswerter
  wie in der Python-Fassung).
- `result.trades` enthält zusätzlich alle Buchungen (Lots, Verkäufe,
  Vorabpauschalen, Gebühren je Asset); in R gibt es kein Gegenstück.
- Mit `details = true` schreibt `simulation()` das Ereignisprotokoll des
  R-Pakets nach `io` (Standard: `stdout`). Hinweise, die R mit `message()`
  ausgibt, erscheinen auf `stderr`; R-Warnungen sind `@warn`-Meldungen,
  R-Fehler `ErrorException`, jeweils mit dem deutschen Wortlaut des
  R-Pakets.
- `cores > 1` rechnet sequenziell, aber mit derselben Zufallssemantik wie
  `mclapply(mc.set.seed = FALSE)` in R; bei gleichem `cores` stimmen die
  Ergebnisse also mit R überein. `bootstrap_study(chunk_dir = …)` schreibt
  die Zwischenstände in einem eigenen Textformat (Dateinamen wie in R auf
  `.rds`, aber nicht mit R lesbar).
- **Grafiken** zeichnet die Julia-Fassung als SVG ohne externe Pakete
  (`SimLevDashboard`, in Jupyter, Pluto und VS Code direkt sichtbar).
  `plot_dashboard(result)` zeigt dieselben Panels, deutschen
  Beschriftungen und Kennzahlen wie R; die Grafik ist nicht bitgleich, die
  dargestellten Daten schon. Die `plot`-Methoden der übrigen
  Ergebnisobjekte (`r_plot(x)`) zeichnen ebenfalls SVG; je nach Klasse
  geben sie ein `SimLevDashboard` oder den SVG-Text zurück, mit
  `file = "…"` schreiben sie in eine Datei (`r_plot` eines
  `deep_analysis()`-Ergebnisses schreibt ohne `file` wie R's
  Standardgerät nach `Rplots.svg`). `export_dashboard(result,
  "backtest.svg"; width = 14, height = 10)` speichert das Dashboard als
  SVG-Datei (Größe in Zoll wie in R, 100 Pixel je Zoll), unabhängig von
  der Dateiendung; für PDF oder PNG wandeln Sie die SVG-Datei mit einem
  Werkzeug wie `rsvg-convert` oder CairoSVG um.
- `plot_interactive(result; file = "backtest.html")` schreibt dasselbe
  eigenständige HTML-Dashboard wie R ohne plotly (byte-identisch);
  `engine = "plotly"` fällt wie in R ohne plotly mit einer Warnung auf
  diesen Weg zurück.
- `export_html_dashboard()` ist wie in R nur ein Platzhalter: Die Funktion
  bricht mit der Fehlermeldung ab, die R ohne plotly ausgibt. Das
  interaktive Dashboard schreibt `plot_interactive()`.
- Eigenvektoren (`eigen()`, u. a. in `portfolio_optimize()`) holt SimLev
  wie R aus der Referenz-LAPACK des Systems (Pfad über die
  Umgebungsvariable `SIMLEV_LAPACK` wählbar). Fehlt sie, rechnet SimLev mit
  einer Warnung über `LinearAlgebra.eigen` weiter, ohne
  Bitgleichheitsgarantie.
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
  mix                 5.34%      0.14%     2.51%     5.17%     7.77%    11.98%
  ...
  max_drawdown
  Strategie          Mittel        q05       q25       q50       q75       q95
  mix                31.25%     21.36%    25.85%    30.02%    36.04%    42.67%
  ...
  strategy                         condition probability         se   n
1      mix cagr > 0.05 & max_drawdown <= 0.3        0.33 0.03324906 200
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

## Bitgleichheit und Plattformen

SimLev.jl bildet nicht nur die Logik, sondern auch die Rechenweise von R
exakt nach (Einzelheiten in [`DEVELOPING.md`](DEVELOPING.md)):

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
- **Lineare Algebra** wie die Referenz-BLAS/LAPACK und LINPACK von R
  (Matrixprodukte in derselben Summationsreihenfolge, Eigenvektoren aus der
  System-LAPACK, siehe oben).
- **R-Interna** im Ordner `src/r/`: Zufallszahlen, Verteilungsfunktionen
  aus nmath, die benötigten stats-Funktionen (`quantile`, `cor`, `optim`,
  `optimize`, `uniroot`, `lm`, `glm`, `smooth.spline`, `density`, `fft`,
  `hclust` …), Formatierung und Druckausgabe (`format`, `formatC`,
  `sprintf`, `round`, `print` von Vektoren, Matrizen und data.frames) und
  ein Auswerter für Bedingungen in R-Syntax.
- Die **C++-Kerne** des R-Pakets (FIFO, Steuern, Markt-Updates, Bootstrap,
  Entnahme, Abhängigkeiten, Optimierung, Signale) sind Zeile für Zeile
  übertragen.

Geprüft wird ohne Toleranz und so streng wie in der Python-Fassung: `NA`
und `NaN` werden unterschieden, ebenso das Vorzeichen der Null; verglichen
werden außerdem Druck- und Konsolenausgabe, Warnungen und Fehlermeldungen.

| Satz | Fälle | Ergebnis |
|---|---|---|
| Engine: gezielte Fälle für jeden Steuer- und Sonderpfad plus Zufallsfälle (`golden/cases/`) | 68 | alle bitgleich, einschließlich `print` und `details = true` |
| Engine: Stressfälle (`golden/extra/`) | 37 | alle bitgleich, einschließlich `print` und `details = true` |
| Engine: frisch erzeugte Zufalls- und Stressfälle beider Generatoren | 469 | alle bitgleich |
| Alle Funktionen, die Engine mit den Argumenten und Ergebniselementen von 0.5.0 (Modul `engine`), die Nachbildung von evd, rugarch und imputeTS und die R-Interna (29 Module in `golden/modules/`) | 4.536 | alle bitgleich |

**Plattformen:** Die Referenz ist R unter Linux x86-64 (die Modul-Fälle
entstanden mit R 4.3.3); dort ist die Julia-Fassung geprüft. Die
mathematischen Funktionen der R-Interna lädt sie aus `libm.so.6`, also aus
glibc; unter macOS und Windows ist die Fassung nicht geprüft.

**Optionale R-Pakete:** evd (2.3-7.1, `fpot`) und rugarch (1.5-6,
`ugarchfit` mit Rsolnp 1.16 `solnp`, numDeriv-Hesse-Matrix und `nlminb`)
sind nachgebildet; standardmäßig verhält sich Julia wie R mit beiden
Paketen (Tail-Modell per GPD-ML, GARCH per rugarch in Bootstrap,
`dcc_fit` und `dependence_analysis`). `ENV["SIMLEV_R_SUGGESTS"] = "none"`
bildet R ohne die Pakete nach, `"evd"` oder `"rugarch"` nur eines davon.
Auch rugarchs letzter Ausweichweg gosolnp (mit `truncnorm::rtruncnorm`)
ist nachgebildet; ihn erreicht die Solver-Kette in R bei etwa 1 %
zufälliger Reihen. Wie in R setzt er den globalen Zufallszustand aus der
Uhrzeit, das Ergebnis hängt dann von der Sekunde des Aufrufs ab;
`ENV["SIMLEV_R_SYS_TIME"]` (Sekunden seit 1970) stellt die Uhr fest.
imputeTS 3.4 (`na_interpolation(option = "stine")` mit stinepack 1.5) ist
ebenfalls nachgebildet (`RImputeTS`, `RStinepack`): `fill = "stine"` im
Backcast interpoliert nach Stineman. MSGARCH, plotly und TTR
gelten als nicht installiert. `nlminb` (PORT) liest an drei Stellen nicht
gesetzte Variablen (in R Stapelreste); Julia setzt 0, was nur in
Sonderfällen die Meldung (Code 3 statt 5) oder Läufe mit Inf/NaN in
Gradient bzw. Hesse-Matrix ändern kann.

## Tests

``` bash
julia --project -e 'using Pkg; Pkg.test()'               # 946 Tests: Engine, R-Interna, Referenzfälle (Auswahl)
SIMLEV_FULL_TESTS=1 julia --project -e 'using Pkg; Pkg.test()'   # dazu alle 4.536 Modul-Referenzfälle
julia --project tools/compare_golden.jl ../golden/cases   # Engine-Fälle eines Ordners (auch ../golden/extra)
julia --project tools/compare_reference.jl [modul …] [-k muster] [-v]   # Modul-Referenzfälle
```

Die Testsuite prüft die 68 Golden-Master-Fälle aus `golden/cases/` und die
37 Stressfälle aus `golden/extra/` vollständig, von den Modul-Fällen in
`golden/modules/` ohne `SIMLEV_FULL_TESTS=1` bis zu vier je Modul; dazu
kommen eigene Tests für `F80`, Engine, Ausgabe und den Auswerter für
Bedingungen. Auf der Prüfmaschine lief `Pkg.test()` in rund 3,5 Minuten.
Liegen die Engine-Fälle woanders, setzen Sie `SIMLEV_GOLDEN_DIR` auf den
Ordner, der `cases/` und `extra/` enthält; `compare_reference.jl` nimmt
den Ordner der Modul-Fälle über `--dir`. Für die Fehlersuche lockern
`SIMLEV_LAX_NA=1` (NA = NaN) und `SIMLEV_STRICT_ZERO=0` (−0 = +0) den
Vergleich der Modul-Fälle.

## Projektstruktur

```
Project.toml        Paketbeschreibung (Version, nur Standardbibliothek)
src/
  SimLev.jl         Modul, Exporte, Reihenfolge der Dateien
  r/                R-Interna: Datenstrukturen (types.jl), libm, long-double-Summen (base.jl),
                    Zufallszahlen (rng.jl), Verteilungen (nmath.jl), stats, lineare Algebra
                    (linalg.jl, _blas.jl, _lapack.jl, _linpack.jl), Formatierung (fmt.jl),
                    Bedingungen in R-Syntax (rexpr.jl)
  ld80.jl           F80: x87-long double (Hardware über llvmcall, sonst F80Soft)
  rnum.jl           R-kompatible Numerik der Engine (Summen, pow, …)
  rformat.jl        R-kompatible Textausgabe der Engine (sprintf, format, round)
  dates.jl          Datumslogik
  config.jl         asset_config, Strategien
  trigger.jl        compute_rebal_trigger
  data.jl           Eingabetabellen, Kalender-Auffüllung (LOCF)
  core.jl           Zustand, FIFO, Steuer- und Marktkerne (Port der C++-Dateien)
  engine.jl         simulation() mit sim_phases.jl, sim_loop.jl, sim_evaluate.jl
  tax_tariff.jl     Einkommensteuertarif, read_tax_tariff
  result.jl         SimLevResult, print/summary
  interactive.jl    interaktives HTML-Dashboard (mit html_templates.jl)
  dashboard.jl      statisches SVG-Dashboard
  <modul>.jl        Erweiterungen, je eine R-Datei (data_prep, backcast, bonds, signals,
                    bootstrap, withdrawal, dependence, regimes, scenarios, optimize,
                    tactical, deep_analysis, planning, analysis_tests, overfitting,
                    param_search, sensitivity)
  <name>_core.jl    C++-Kerne der Erweiterungen (bootstrap, signals, withdrawal,
                    dependence, optimize)
  exports.jl        öffentliche Funktionen der Untermodule für `using SimLev`
  precompile.jl     Arbeitslast für die Vorkompilierung
data/               Tarifdatei steuertarif.csv, R-Farbnamen r_colors.csv
test/               Testsuite; reftree.jl und golden_tools.jl lesen die Referenzfälle
tools/              compare_golden.jl (Engine), compare_reference.jl (Module)
examples/           Lauffähige Beispiele
```

## Lizenz

GPL-3, wie das R-Paket. Siehe [LICENSE.md](LICENSE.md).
