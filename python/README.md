<p align="center">
  <img src="https://raw.githubusercontent.com/chemicalstats/SimLev-Repos/main/docs/figures/logo.png" alt="SimLev-Logo" width="220" />
</p>

<h1 align="center">SimLev für Python</h1>

<p align="center">
  <strong>Simulation und Backtesting für Basis-, Hebel- und Multi-Asset-Strategien für Exchange Traded Products</strong>
</p>

---

Dieses Paket ist die Python-Fassung des R-Pakets SimLev. Version 0.5.0 ist
ein vollständiger Port der aktuellen R-Fassung 0.5.0: Alle 116 Exporte des
R-Pakets gibt es hier mit gleichem Namen, gleichen Argumenten und gleichen
Voreinstellungen. Das Paket läuft **eigenständig ohne R** und benötigt nur
`numpy` und `pandas`; zum Installieren braucht es einen C- und
C++-Compiler, weil die Rechenkerne als C-Erweiterung gebaut werden.

Die Ergebnisse sind **bitgleich** zu R 0.5.0: Jeder Tageswert, jede
Kennzahl, jeder Steuerbetrag, die (deutsche) Druckausgabe sowie Warnungen
und Fehlermeldungen stimmen mit dem R-Paket exakt überein. Das gilt für die
Engine `simulation()` und für alle Erweiterungen (Backcast, Bootstrap,
Entnahmephase, Analyse, Parametersuche, Abhängigkeiten, Taktik, Optimierung,
Szenarien, Planung, Prüfungen). Wie das geprüft wurde und unter welchen
Voraussetzungen es gilt, steht unten unter
[Gleichlauf und Plattformen](#gleichlauf-und-plattformen). Was sich
gegenüber der Vorversion 0.1.0 geändert hat, steht in
[NEWS.md](NEWS.md).

**Die vollständige Dokumentation mit Grundkonzepten, Steuerlogik und
Beispielen für alle drei Sprachen steht in der
[Haupt-README](https://github.com/chemicalstats/SimLev-Repos#readme).** Maßgeblich
für Argumente und Ergebnisse sind die Hilfeseiten des R-Pakets
(`r/man/*.Rd`); die Docstrings (`help(simlev.bootstrap_study)`) fassen sie
kurz zusammen. Die Quellen der Verfahren (Bootstrap, Volatilitätsmodelle, Abhängigkeiten, Portfolio, Tests, Entnahme und die Numerik der eigenen C-Bibliothek) stehen im Abschnitt [Literatur](https://github.com/chemicalstats/SimLev-Repos#literatur) der Haupt-README. Hier finden Sie nur, was speziell die Python-Fassung
betrifft.

## Installation

SimLev läuft ab Python 3.10 (geprüft ab Python 3.10, zuletzt mit Python
3.13, numpy 2.5, pandas 3.0). Zum Installieren braucht es einen C- und
C++-Compiler (C99, C++17) und die Python-Header: `pip` baut dabei die
C-Erweiterung `simlev._ext` aus `src/`. Sie enthält die C-Bibliothek von
SimLev (Zufall, Verteilungen, lineare Algebra, Optimierer, GARCH/GJR, GPD,
DCC, MS-GARCH, Bootstrap-Kerne, Stineman, Glättungsspline, Kerndichte) und
die mit R geteilten Kerne von Engine, FIFO, Steuer, Research und Entnahme,
aus denselben Quellen wie das R-Paket (`core/` im Repository). Ohne
Compiler bricht die Installation mit der Meldung von setuptools ab; einen
Rückfall auf reine Python-Kerne gibt es nicht mehr.

``` bash
pip install "simlev @ git+https://github.com/chemicalstats/SimLev-Repos#subdirectory=python"
```

Aus einem lokalen Klon (im Ordner `python/`):

``` bash
pip install .                              # Paket mit C-Erweiterung
python setup.py build_ext --inplace        # nur bauen, für die Arbeit direkt im Klon
```

Compiler: unter Linux `gcc`/`g++` bzw. `build-essential` und die
Python-Header (z. B. `python3-dev`), unter macOS die Xcode Command Line
Tools, unter Windows die Build Tools für Visual Studio. Geprüft ist nur
Linux auf x86-64.

| Paket | Wofür | Pflicht? |
|---|---|---|
| `numpy`, `pandas` | Datenhaltung und Datenaufnahme | ja |
| C- und C++-Compiler (C99, C++17), Python-Header | Bau der C-Erweiterung `simlev._ext` | ja |
| `pytest` | Rauchproben (`tests/`) | optional |

## Kurzbeispiel

Das vollständige Skript liegt unter
[`examples/schnellstart.py`](https://github.com/chemicalstats/SimLev-Repos/blob/main/python/examples/schnellstart.py).

``` python
import numpy as np
import pandas as pd
import simlev

rng = np.random.default_rng(42)
n = 365 * 10
data = pd.DataFrame({
    "date":  pd.date_range("2015-01-01", periods=n, freq="D"),
    "WORLD": 100 * np.cumprod(1 + rng.normal(4e-4, 0.010, n)),
    "BONDS":  50 * np.cumprod(1 + rng.normal(1e-4, 0.003, n)),
})

strategy = simlev.create_strategy(
    WORLD=simlev.asset_config(asset_class="etf", trading="bnh", share=0.7, spread=0.1, partial_exemption=30),
    BONDS=simlev.asset_config(asset_class="etf", trading="bnh", share=0.3, spread=0.1, partial_exemption=0),
)

result = simlev.simulation(
    data, strategy,
    start_value=10000,
    rebalance=simlev.rebalance_plan(span=1, unit="year"),
    tax=simlev.tax_profile(rate=26.375),
    liquidate=True, risk_free=2,
)

print(result)
result.plot()
```

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

Das ist dieselbe Ausgabe, die das R-Paket 0.5.0 für diese Kursdaten liefert.
Ohne Steuern (`tax=None`) wären es 21.015,24 EUR (7,72 % p. a.).

## Erweiterungen

Alle Erweiterungsfunktionen des R-Pakets stehen direkt unter `simlev.`
bereit. Zwei kurze Beispiele mit den Daten und der Strategie von oben:

``` python
# Bootstrap-Studie: 200 stationäre Bootstrap-Pfade, auf jedem die Strategie simuliert
cfg = simlev.bootstrap_config({"WORLD": "WORLD", "BONDS": "BONDS"}, input="prices")
study = simlev.bootstrap_study(data, cfg, "stationary", n=200, params={"L": 250},
                               strategies={"mix": strategy}, seed=42, progress=False)
print(simlev.summary(study))                               # Verteilungen der Kennzahlen
simlev.bootstrap_probability(study, "cagr > 0.05")         # Wahrscheinlichkeit: 0.625
```

```
  cagr (mit Sparplan geldgewichtet, XIRR)
  Strategie          Mittel        q05       q25       q50       q75       q95
  mix                 7.37%     -1.77%     3.30%     6.95%    10.62%    17.72%
  ...
  max_drawdown
  Strategie          Mittel        q05       q25       q50       q75       q95
  mix                32.69%     20.73%    24.93%    31.65%    38.83%    50.32%
```

``` python
# Risikoparität aus Wochenrenditen
opt = simlev.portfolio_optimize(data, assets=["WORLD", "BONDS"], method="risk_parity")
print(opt)
```

```
SimLev-Optimierung: risk_parity (521 Perioden, week, Kovarianz sample)

 Anlage Gewicht Risikoanteil
  WORLD  22.4 %       50.0 %
  BONDS  77.6 %       50.0 %

Erwartete Rendite 5.67 % p. a. (historisch), Volatilität 6.24 %, Sharpe 0.909
CVaR(0.05) 1.65 % je Periode, CDaR(0.05) 8.64 % (kumuliert)
Diversifikationsverhältnis 1.39, effektive Anzahl: Gewichte 1.5, Risiko 2.0
```

Die Bootstrap-Studie zieht ihre Zufallszahlen aus dem eigenen Generator
von SimLev, in R, Python und Julia derselbe: Mit denselben Kursdaten (hier
als CSV mit voller Genauigkeit an R übergeben) und `seed = 42` liefert
`bootstrap_study()` in R dieselben Kennzahlen bis auf das letzte Bit, ebenso
`portfolio_optimize()` dieselben Gewichte.

**Fonds-Wrapper** (Zertifikat oder Fonds über eine innere Strategie, Etappe 6.5c): ein Asset der
Strategie, dessen Kurs der Anteilswert der inneren Strategie ist (Verwaltungsgebühr täglich je
Kalendertag, Performancegebühr täglich gegen die High-Water-Mark abgegrenzt und am letzten Datentag
des Jahres festgeschrieben); außen wird er wie ein Einzelpapier gehandelt und besteuert.

``` python
w = simlev.wrapper_config(strategy, rebalance=simlev.rebalance_plan(unit="quarter"),
                          costs=simlev.funds_costs(fee=0.95, performance_fee=5))
nav = simlev.wrapper_nav(data, w)          # SimLevWrapperNav: date, nav, gross, fee, perf_fee, perf_paid, hwm
res = simlev.simulation(data, simlev.create_strategy(
    Zertifikat=simlev.asset_config(asset_class="certificate", spread=0.5, wrapper=w)))
```

## Von R zu Python

Funktionsnamen, Argumente und Voreinstellungen sind identisch mit dem
R-Paket:

| R | Python |
|---|---|
| `NULL` | `None` |
| `TRUE` / `FALSE` | `True` / `False` |
| `NA` | `simlev.NA` (numerisch; ein gewöhnliches `nan` ist R's `NaN`) bzw. `None` |
| `c(20, 400)` | `(20, 400)` oder `[20, 400]` |
| `c(us = "us_ret", eu = "eu_ret")`, `list(A = "w1")` | `{"us": "us_ret", "eu": "eu_ret"}`, `{"A": "w1"}` |
| `data.frame(...)` | `pandas.DataFrame(...)` |
| benannter Vektor | `pandas.Series` (Index = Namen) oder `dict` |
| Matrix | `numpy.ndarray`, mit Zeilen- und Spaltennamen `pandas.DataFrame` |
| `result$worth` | `result.worth` oder `result["worth"]` |
| `result$statistics$sharpe` | `result.statistics["sharpe"]` |
| `result$report$WORLD$total` | `result.report["WORLD"]["total"]` |
| `print(x)` | `print(x)` |
| `summary(x)` | `simlev.summary(x)` oder `x.summary()` |
| `plot(x)` | `simlev.plot(x)` oder `x.plot()` |
| `simlev_seed(42)` | `simlev.simlev_seed(42)` |
| `bootstrap_probability(st, cagr > 0.05)` | `simlev.bootstrap_probability(st, "cagr > 0.05")` |
| `function(df) signal_sma(df$INDEX, 200)` | `lambda df: simlev.signal_sma(df["INDEX"], 200)` |
| Argumente `yield`, `raise`, `from` | `yield_`, `raise_`, `from_` |

Ergebnisobjekte mit R-Klasse (`SimLevResult`, `SimLevBootstrapStudy`,
`SimLevOptimization` …) erben von `simlev._r.rlist.RList`, einem geordneten
`dict` mit Attributzugriff; die Elemente stehen in derselben Reihenfolge wie
in R, und `print(x)` liefert genau die Ausgabe der R-`print`-Methode.

Besonderheiten der Python-Fassung:

- `simlev.bootstrap`, `simlev.backcast` und `simlev.param_search` sind
  zugleich Modul und aufrufbare Funktion:
  `simlev.bootstrap(...)` wirkt wie in R, `import simlev.bootstrap`
  erreicht das Modul.
- Zufallszahlen zieht SimLev aus seinem eigenen Generator in der
  C-Bibliothek (xoshiro256**, in R und Julia derselbe).
  `simlev.simlev_seed(42)` setzt seinen Zustand wie `simlev_seed(42)` in R;
  zufällige Funktionen nehmen außerdem `seed`. numpy-Zufallszahlen (wie im
  Kurzbeispiel) beeinflussen ihn nicht.
- Bedingungen als Text (`tactical_rules()`, `bootstrap_probability()`,
  `regime_subset()`, `view_prob()`) werden wie in R in **R-Syntax**
  ausgewertet (`"inflation >= 4"`, `"cagr > 0 & max_drawdown <= 0.3"`,
  `"!eq > 90"`, `"x %in% c(1, 2)"`), mit R's Vorrangregeln und NA-Logik
  (`simlev._r.rexpr`); freie Variablen kommen aus `env` bzw. dem
  Namensraum des Aufrufers. Eine Python-Funktion geht ebenfalls.
- `result.trades` enthält zusätzlich alle Buchungen (Lots, Verkäufe,
  Steuerbuchungen wie Vorabpauschalen je Asset); in R gibt es kein Gegenstück.
- `bootstrap_study(chunk_dir=...)` schreibt die Zwischenstände als Pickle
  statt als RDS.
- `cores > 1` rechnet wie R mit Fork-Prozessen (`multiprocessing`, Kontext
  `"fork"`). Jeder Pfad bzw. jede Einheit hat einen eigenen Zufallsstrom;
  die Ergebnisse hängen nicht von `cores` ab und stimmen mit R überein. Wo es
  keinen Fork gibt (Windows, macOS mit dem Standard `spawn`), rechnet Python
  nacheinander, mit denselben Ergebnissen. Ausgaben und Meldungen der Einheiten erscheinen in
  deren Reihenfolge (R: in der Reihenfolge der Fertigstellung).
- Hinweise wie die Meldung über aufgefüllte Kalendertage erscheinen, wie
  R's `message()`, auf `stderr`; Warnungen sind `UserWarning`, Fehler
  `ValueError`, jeweils mit dem deutschen Wortlaut des R-Pakets.

## Gleichlauf und Plattformen

Python, R und Julia rechnen Zufall und Numerik mit derselben C-Bibliothek
(Quellen in `core/` des Repositorys, in Python als `simlev._ext` gebaut).
Darüber hinaus bildet die Python-Fassung die Grundfunktionen von R nach,
die SimLev nutzt (Modul `simlev/_r/`): Summen in 80-Bit-`long double`,
Sortieren, Ränge, Quantile, `cor`, `approx`, `filter`, `optimize`,
`uniroot`, `hclust`, `p.adjust`, Kalender, `round`, `format`, `formatC`,
`sprintf` und die `print`-Ausgabe von Vektoren, Matrizen und data.frames,
dazu den Auswerter für Bedingungen in R-Syntax. Welche R-Quellen das sind,
steht in [`COPYRIGHTS.md`](COPYRIGHTS.md).

Voraussetzungen des Gleichlaufs:

- **Linux auf x86-64.** R summiert intern mit 80-Bit-`long double`; die
  Python-Fassung nutzt dafür `numpy.longdouble` in derselben Reihenfolge.
  Auf Plattformen mit 64-Bit-`long double` (z. B. macOS auf Apple Silicon)
  rechnet auch R anders; dort können die letzten Bits abweichen.
- **glibc-libm.** Exponential-, Logarithmus- und Potenzfunktionen kommen
  wie in R aus der C-Bibliothek. numpy-Transzendentalfunktionen werden
  bewusst nicht verwendet, weil sie auf Rechnern mit AVX-512 in den letzten
  Bits abweichen.
- **Gleicher Compiler, gleiche Einstellungen.** Die C-Bibliothek wird wie
  in R mit `-O2 -ffp-contract=off -fno-fast-math` übersetzt; jede
  Kerndatei bricht bei `-ffast-math` ab.
- **Zeichenketten-Reihenfolge wie R.** Sortieren und Vergleichen von
  Zeichenketten folgt R's ICU-Kollation (unter `C.UTF-8` „root“: `a A ä b
  B`) über die System-ICU (`libicui18n`, Pfad über `SIMLEV_ICU`);
  `SIMLEV_COLLATE=C` erzwingt die Byte-Reihenfolge wie R unter `LC_ALL=C`,
  `SIMLEV_COLLATE=icu:root` die von R unter `C.UTF-8`. Ohne ICU: Codepunkte
  mit Warnung, nicht gleich zu R.
- **Grafiken** entstehen wie in der Julia-Fassung ohne Zusatzpaket als
  SVG. `result.plot()` und alle `plot()`-Methoden liefern ein
  `simlev.SimLevPlot` (in Jupyter direkt sichtbar; `p.save("x.svg")`
  bzw. `file="x.svg"` speichert). Es enthält neben `svg` die
  dargestellten Werte je Panel als pandas-Tabellen (`p.data`), das
  Eingabeobjekt (`p.source`) und dessen Klasse (`p.kind`); daraus lassen
  sich eigene Grafiken bauen, z. B. mit matplotlib:
  `p.data["performance"].plot(x="date", y="strategy")`. Die Grafiken
  zeigen dasselbe wie in R, sind aber nicht bitgleich; die Werte in
  `p.data` schon. Gespeichert wird nur als SVG; für PDF oder PNG die
  Datei z. B. mit `rsvg-convert` oder CairoSVG umwandeln.

Geprüft wird mit der Gleichlaufprüfung `tools/gleichlauf/run.sh` im
Repository: Sie erzeugt die Referenzfälle mit dem aktuellen R-Paket neu und
vergleicht Python bitgenau dagegen (Ergebnis, Konsolen- und Druckausgabe,
Warnungen, Fehlermeldungen; NA ≠ NaN, Vorzeichen der Null). Der letzte
vollständige Lauf (27.10.2026) ergab 4.260 von 4.260 Modul-Fällen und
1.182 von 1.182 Engine-Fällen gleich (siehe
[Gleichlauf](../README.md#gleichlauf-der-drei-sprachen) in der
Haupt-README).

Bekannte Grenzen:

- `NA` und `NaN` werden wie in R unterschieden: `simlev.NA` trägt R's
  Bitmuster (NaN mit Nutzlast 1954), jedes andere `nan` ist R's `NaN`;
  `simlev.isna_strict(x)` erkennt nur `NA`. Fehlende Werte aus pandas
  (`NaN`, `None`, `NaT`) zählen wie in R's `is.na()` als fehlend. Weil
  `simlev.NA` ein signalisierendes NaN ist, meldet numpy bei Rechnungen
  damit „invalid value“; SimLev unterdrückt diese Warnungen in seinen
  Funktionen.
- Verteilungen, Optimierer und lineare Algebra der C-Bibliothek decken ab,
  was SimLev braucht (etwa keine nichtzentralen Verteilungen); auch von den
  nachgebildeten R-Grundfunktionen gibt es nur die Optionen, die das Paket
  verwendet.

## Tests

``` bash
pip install ".[test]"
pytest                                        # Rauchproben der C-Bibliothek (tests/test_etappe9_*.py)
python ../tools/core_sync.py --check          # Kopien der C-Quellen gleich core/ (aus python/)
```

Die frühere Test-Suite (Engine, R-Interna, Referenzfälle in `golden/`)
beschreibt den Stand vor dem eigenen Zufall und den eigenen Kernen und ist
bis zu ihrem Neuaufbau ausgesetzt; `SIMLEV_LEGACY_TESTS=1` lädt sie (Dateien,
die entfallene Module nutzen, scheitern dann). `tools/compare_golden.py` und
`tools/compare_reference.py` vergleichen mit gespeicherten Fällen; ohne den
Schalter enden sie mit einem Hinweis, außer `SIMLEV_GOLDEN_DIR` bzw.
`SIMLEV_MODULE_DIR` zeigt auf frisch erzeugte Fälle. Maßgeblich ist bis
dahin die Gleichlaufprüfung aus der Repo-Wurzel:

``` bash
LC_ALL=C.UTF-8 tools/gleichlauf/run.sh --quick    # baut R, Python und Julia, erzeugt und vergleicht
```

Wie die Fälle aufgebaut sind und erzeugt werden, steht in
[`golden/README.md`](../golden/README.md); Hinweise für die
Weiterentwicklung in [DEVELOPING.md](DEVELOPING.md).

## Projektstruktur

```
simlev/
  __init__.py        öffentliche Funktionen (alle 116 Exporte des R-Pakets)
  engine.py          simulation(), Ablaufsteuerung (simulation.R, utils.R)
  _sim_blocks.py     Bausteine sim_costs(), dca_plan(), rebalance_plan(), split_rule(), tax_profile(),
                     income_rate(), income_tariff(), harvest_rule(), funds_costs() (sim_blocks.R)
  _sim_base.py       Hilfen, Gebühren, Termine, Handels- und Steuerfunktionen, Tarifweg,
                     Jahreswechsel, Kennzahlen (sim_base.R)
  _sim_phases.py     Phasen 1–2: Eingabeprüfung, Datenvorbereitung (sim_validate.R, sim_prepare.R)
  _sim_loop.py       Phasen 3–5: Zahlungshelfer, Tagesschleife, Jahresabschluss (sim_actions.R, sim_loop.R)
  _sim_evaluate.py   Phase 6: Renditen, Kennzahlen, Ergebnisobjekt (sim_evaluate.R)
  _core.py           Hüllen der Engine-Kerne (simulation_core, fifo_core, tax_core in simlev._ext)
  _dates.py          Datumshelfer (Tage seit 1970, strptime wie R)
  config.py          asset_config(), create_strategy() & Co. (asset_config.R, strategy.R)
  wrapper.py         Fonds-Wrapper: wrapper_config(), wrapper_nav() (wrapper.R)
  trigger.py         rebalance_trigger()
  _tax_tariff.py     tax_tariff(), Einkommensteuertarif
  result.py          SimLevResult mit print/summary/plot
  svg.py             Grafikmodul: SimLevPlot, plot-API und alle SVG-Zeichenbausteine
  dashboard.py       Dashboard: Daten und Panels (SVG)
  data_prep.py       Datenaufbereitung, Portfolio-Vorlagen
  backcast.py        backcast_fit(), backcast()
  bonds.py           Anleihe-, Geldmarkt- und gesicherte Reihen
  signals.py         Signal-Bausteine (signal_sma() …); Kerne in _signals_core.py
  bootstrap.py       Bootstrap, Bootstrap-Studien (Kerne in der C-Bibliothek)
  ms_garch.py        eigene MS-GARCH-Schätzung (ms_garch.R; Kern in der C-Bibliothek)
  withdrawal.py      Entnahmephase; Kern in _withdrawal_core.py
  deep_analysis.py   result_analysis()
  sensitivity.py     Sensitivitäten, Lump Sum vs. DCA, Hebelreihen
  param_search.py    Parametersuche, Plateau
  overfitting.py     PBO, Deflated Sharpe, Walk-Forward, Harvey-Liu
  dependence.py      Abhängigkeiten, Copulas, DCC, Quantilsregression, CoVaR; Kerne in _dependence_core.py
  regimes.py         Hidden-Markov-Regime
  scenarios.py       Entropy Pooling, Copula-Szenarien, Krisen-Replay
  tactical.py        taktische Allokation
  optimize.py        Portfolio-Optimierung, Risikobeiträge; Kerne in _optimize_core.py
  planning.py        Länder-Bootstrap, Renditeannahmen, planning_goal()
  analysis_tests.py  statistische Prüfungen
  data/              steuertarif.csv (Tarif ab VZ 2026), r_colors.csv (R-Farbnamen)
  _lib.py, _lib_*.py Hüllen der C-Bibliothek (Zufall, simlev_seed, Verteilungen, lineare
                     Algebra, Optimierer, Modelle, Bootstrap-Kerne)
  _r/                Nachbildungen von R-Grundfunktionen
    rnum.py          NA, Summen mit long double, pow, uniroot (unterste Schicht)
    rformat.py       Rundung und Textausgabe der Engine (round, signif, format, sprintf)
    stats.py         sammelt die Themenmodule stats_sort.py (Sortieren, Quantile),
                     stats_cor.py (cor, cov, scale), stats_smooth.py (approx, filter),
                     stats_optim.py (optimize, uniroot; mit _optim.py),
                     stats_models.py (coef, p.adjust, ecdf, aggregate …), stats_cluster.py (dist, hclust)
    linalg.py        outer, diag, isSymmetric, all.equal
    base.py, libm.py base-Funktionen mit long double, libm-Funktionen
    fmt.py           format, sprintf, print wie R
    _collate.py      Zeichenketten-Kollation über ICU
    rexpr.py         Bedingungen in R-Syntax
    parallel.py      par_lapply (Fork)
    rlist.py         Basisklasse RList der Ergebnisobjekte
    reftree.py       Laden und Vergleichen der Referenzfälle
src/                 C-Erweiterung simlev._ext: _ext*.cpp/.c (Hüllen) und core/ (Kopien der
                     C-Bibliothek und der gemeinsamen Kerne aus core/ im Repository)
setup.py             Bau der Erweiterung (Pflicht, setuptools Extension)
tests/               Rauchproben; frühere Suite ausgesetzt (SIMLEV_LEGACY_TESTS=1)
tools/               compare_golden.py, compare_reference.py
examples/            lauffähige Beispiele
```

## Lizenz

GPL-3, wie das R-Paket. Siehe [LICENSE.md](LICENSE.md).
