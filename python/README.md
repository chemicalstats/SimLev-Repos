<p align="center">
  <img src="https://raw.githubusercontent.com/chemicalstats/SimLev-Repos/main/docs/figures/logo.png" alt="SimLev-Logo" width="220" />
</p>

<h1 align="center">SimLev für Python</h1>

<p align="center">
  <strong>Simulation und Backtesting für Basis-, Hebel- und Multi-Asset-Strategien für Exchange Traded Products</strong>
</p>

---

Dieses Paket ist die Python-Fassung des R-Pakets SimLev. Version 0.5.0 ist
ein vollständiger Port der aktuellen R-Fassung 0.5.0: Alle 104 Exporte des
R-Pakets gibt es hier mit gleichem Namen, gleichen Argumenten und gleichen
Voreinstellungen. Das Paket läuft **eigenständig ohne R** und benötigt nur
`numpy` und `pandas`.

Die Ergebnisse sind **bitgleich** zu R 0.5.0: Jeder Tageswert, jede
Kennzahl, jeder Steuerbetrag, die (deutsche) Druckausgabe sowie Warnungen
und Fehlermeldungen stimmen mit dem R-Paket exakt überein. Das gilt für die
Engine `simulation()` und für alle Erweiterungen (Backcast, Bootstrap,
Entnahmephase, Analyse, Parametersuche, Abhängigkeiten, Taktik, Optimierung,
Szenarien, Planung, Prüfungen). Wie das geprüft wurde und unter welchen
Voraussetzungen es gilt, steht unten unter
[Bitgleichheit und Plattformen](#bitgleichheit-und-plattformen). Was sich
gegenüber der Vorversion 0.1.0 geändert hat, steht in
[NEWS.md](NEWS.md).

**Die vollständige Dokumentation mit Grundkonzepten, Steuerlogik und
Beispielen für alle drei Sprachen steht in der
[Haupt-README](https://github.com/chemicalstats/SimLev-Repos#readme).** Maßgeblich
für Argumente und Ergebnisse sind die Hilfeseiten des R-Pakets
(`r/man/*.Rd`); die Docstrings (`help(simlev.bootstrap_study)`) fassen sie
kurz zusammen. Hier finden Sie nur, was speziell die Python-Fassung
betrifft.

## Installation

SimLev ist reines Python ab Version 3.10 (geprüft ab Python 3.10, zuletzt
mit Python 3.13, numpy 2.5, pandas 3.0). Ein Compiler wird nicht benötigt.

``` bash
pip install "simlev @ git+https://github.com/chemicalstats/SimLev-Repos#subdirectory=python"
```

Aus einem lokalen Klon (im Ordner `python/`):

``` bash
pip install .                 # Engine, alle Erweiterungen und Grafiken (numpy, pandas)
```

| Paket | Wofür | Pflicht? |
|---|---|---|
| `numpy`, `pandas` | Rechenkern und Datenaufnahme | ja |
| `pytest` | Ausführen der Test-Suite | optional |

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
    WORLD=simlev.asset_config("etf", action_type="bnh", asset_share=0.7, asset_spread=0.1, asset_bonus=30),
    BONDS=simlev.asset_config("etf", action_type="bnh", asset_share=0.3, asset_spread=0.1, asset_bonus=0),
)

result = simlev.simulation(
    data, strategy,
    start_value=10000,
    balance_mode=True, balance_span=1, balance_unit="year",
    tax_mode="person", tax_rate=26.375,
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
Ohne Steuern (`tax_mode="none"`) wären es 21.015,24 EUR (7,72 % p. a.).

## Erweiterungen

Alle Erweiterungsfunktionen des R-Pakets stehen direkt unter `simlev.`
bereit. Zwei kurze Beispiele mit den Daten und der Strategie von oben:

``` python
# Bootstrap-Studie: 200 stationäre Bootstrap-Pfade, auf jedem die Strategie simuliert
cfg = simlev.bootstrap_config({"WORLD": "WORLD", "BONDS": "BONDS"}, input="prices")
study = simlev.bootstrap_study(data, cfg, "stationary", n=200, params={"L": 250},
                               strategies={"mix": strategy}, seed=42, progress=False)
print(simlev.summary(study))                               # Verteilungen der Kennzahlen
simlev.bootstrap_probability(study, "cagr > 0.05")         # Wahrscheinlichkeit: 0.705
```

```
  cagr (mit Sparplan geldgewichtet, XIRR)
  Strategie          Mittel        q05       q25       q50       q75       q95
  mix                 8.71%      0.10%     4.10%     8.40%    12.83%    19.16%
  ...
  max_drawdown
  Strategie          Mittel        q05       q25       q50       q75       q95
  mix                30.55%     19.64%    24.52%    30.19%    35.76%    43.76%
```

``` python
# Risikoparität aus Wochenrenditen
opt = simlev.portfolio_optimize(data, ["WORLD", "BONDS"], method="risk_parity")
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

Die Bootstrap-Studie zieht ihre Zufallszahlen wie R: Mit denselben
Kursdaten und `seed = 42` liefert `bootstrap_study()` in R dieselben
Kennzahlen bis auf das letzte Bit, ebenso `portfolio_optimize()` dieselben
Gewichte.

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
| `set.seed(42)` | `simlev.set_seed(42)` |
| `bootstrap_probability(st, cagr > 0.05)` | `simlev.bootstrap_probability(st, "cagr > 0.05")` |
| `function(df) signal_sma(df$INDEX, 200)` | `lambda df: simlev.signal_sma(df["INDEX"], 200)` |
| Argumente `yield`, `raise`, `from` | `yield_`, `raise_`, `from_` |

Ergebnisobjekte mit R-Klasse (`SimLevResult`, `SimLevBootstrapStudy`,
`SimLevOptimization` …) erben von `simlev._r.rlist.RList`, einem geordneten
`dict` mit Attributzugriff; die Elemente stehen in derselben Reihenfolge wie
in R, und `print(x)` liefert genau die Ausgabe der R-`print`-Methode.

Besonderheiten der Python-Fassung:

- `simlev.bootstrap`, `simlev.backcast`, `simlev.deep_analysis` und
  `simlev.param_search` sind zugleich Modul und aufrufbare Funktion:
  `simlev.bootstrap(...)` wirkt wie in R, `import simlev.bootstrap`
  erreicht das Modul.
- Zufallszahlen erzeugt SimLev mit einem Nachbau von R's Generatoren
  (Mersenne-Twister, L'Ecuyer-CMRG-Streams, `sample.int`, `rnorm` u. a.).
  Der Zustand ist global wie `.Random.seed`; `simlev.set_seed()` entspricht
  `set.seed()`. numpy-Zufallszahlen (wie im Kurzbeispiel) beeinflussen ihn
  nicht.
- Bedingungen als Text (`tactical_rules()`, `bootstrap_probability()`,
  `regime_subset()`, `view_prob()`) werden wie in R in **R-Syntax**
  ausgewertet (`"inflation >= 4"`, `"cagr > 0 & max_drawdown <= 0.3"`,
  `"!eq > 90"`, `"x %in% c(1, 2)"`), mit R's Vorrangregeln und NA-Logik
  (`simlev._r.rexpr`); freie Variablen kommen aus `env` bzw. dem
  Namensraum des Aufrufers. Eine Python-Funktion geht ebenfalls.
- `result.trades` enthält zusätzlich alle Buchungen (Lots, Verkäufe,
  Vorabpauschalen, Gebühren je Asset); in R gibt es kein Gegenstück.
- `bootstrap_study(chunk_dir=...)` schreibt die Zwischenstände als Pickle
  statt als RDS.
- `cores > 1` rechnet sequenziell, aber mit derselben Zufallssemantik wie
  `mclapply(mc.set.seed = FALSE)` in R; bei gleichem `cores` stimmen die
  Ergebnisse also mit R überein.
- Hinweise wie die Meldung über aufgefüllte Kalendertage erscheinen, wie
  R's `message()`, auf `stderr`; Warnungen sind `UserWarning`, Fehler
  `ValueError`, jeweils mit dem deutschen Wortlaut des R-Pakets.

## Bitgleichheit und Plattformen

Die Python-Fassung bildet nicht nur die Logik, sondern auch die
Rechenweise von R nach. Die dafür nötigen R-Interna liegen in
`simlev/_r/`: Zufallszahlen, Verteilungsfunktionen aus R's nmath (`qnorm`,
`pt`, `qt`, `pbeta`, `lgamma` …), die benötigten Teile von `stats`
(`quantile`, `cor` einschließlich Kendall und Spearman, `optim` mit
Nelder-Mead, BFGS, CG und L-BFGS-B, `optimize`, `uniroot`, `lm`, `glm`,
`smooth.spline`, `density`, `fft`, `hclust`, `p.adjust`, `t.test` …),
lineare Algebra (Matrixprodukte wie die Referenz-BLAS, `solve`, `chol`,
`qr` nach LINPACK, `determinant`, `eigen`) sowie `format`, `formatC`,
`sprintf`, `round` und die `print`-Ausgabe von Vektoren, Matrizen und
data.frames.

Voraussetzungen der Bitgleichheit:

- **Linux auf x86-64.** R summiert intern mit 80-Bit-`long double`; die
  Python-Fassung nutzt dafür `numpy.longdouble` in derselben Reihenfolge.
  Auf Plattformen mit 64-Bit-`long double` (z. B. macOS auf Apple Silicon)
  rechnet auch R anders; dort können die letzten Bits abweichen, und die
  Bitgleichheits-Tests werden übersprungen.
- **glibc-libm.** Exponential-, Logarithmus- und Potenzfunktionen kommen
  wie in R aus der C-Bibliothek. numpy-Transzendentalfunktionen werden
  bewusst nicht verwendet, weil sie auf Rechnern mit AVX-512 in den letzten
  Bits abweichen.
- **Referenz-LAPACK für Eigenvektoren.** Eigenwerte sind rein in Python
  portiert. Eigenvektoren von `eigen()` (genutzt u. a. in
  `portfolio_optimize()`) holt SimLev wie R über ctypes aus der
  Referenz-LAPACK des Systems (unter Debian/Ubuntu
  `/usr/lib/x86_64-linux-gnu/lapack/liblapack.so.3`); ein anderer Pfad lässt
  sich über die Umgebungsvariable `SIMLEV_LAPACK` setzen. Fehlt sie,
  rechnet numpy, dann ohne Bitgleichheitsgarantie; SimLev warnt in diesem
  Fall einmal.
- **Zeichenketten-Reihenfolge wie R.** Sortieren und Vergleichen von
  Zeichenketten folgt R's ICU-Kollation (unter `C.UTF-8` „root“: `a A ä b
  B`) über die System-ICU (`libicui18n`, Pfad über `SIMLEV_ICU`);
  `SIMLEV_COLLATE=C` erzwingt die Byte-Reihenfolge wie R unter `LC_ALL=C`,
  `SIMLEV_COLLATE=icu:root` die von R unter `C.UTF-8`. Ohne ICU: Codepunkte
  mit Warnung, nicht bitgleich.
- **Optionale R-Pakete.** `evd` (2.3-7.1, `fpot`) und `rugarch` (1.5-6,
  `ugarchfit` mit Rsolnp 1.16 `solnp` und `stats::nlminb`) sind
  nachgebildet (`simlev._r.evd`, `simlev._r.rugarch`, `simlev._r.solnp`,
  `simlev._r.stats.nlminb`). Das Tail-Modell schätzt ab 30
  Überschreitungen immer per GPD-ML wie R, das `evd::fpot` übernommen hat
  (`.evd_fpot`; Herkunft in `COPYRIGHTS.md`). Die GARCH-Schätzung
  (Bootstrap `garch`/`gjr_garch`, Kopplung, `dcc_fit()`,
  `dependence_analysis()`) läuft immer per rugarch-Nachbildung,
  einschließlich der Warnungen von rugarch, wie R, das `ugarchfit` mit
  Rsolnp und truncnorm übernommen hat (`.rugarch_ugarchfit`;
  Herkunft in `COPYRIGHTS.md`); `optim` und die Momente bleiben nur der
  Rückfall, wenn der Fit mit einem Fehler scheitert. Auch rugarchs
  letzter Ausweichweg gosolnp (`simlev._r.solnp.gosolnp`, mit
  `simlev._r.truncnorm.rtruncnorm`) ist nachgebildet; ihn erreicht die
  Solver-Kette in R bei etwa 1 % zufälliger Reihen. Wie in R setzt er den
  globalen Zufallszustand aus der Uhrzeit (`set.seed` mit den
  Unix-Sekunden), das Ergebnis hängt dann von der Sekunde des Aufrufs ab;
  `SIMLEV_R_SYS_TIME` (Sekunden seit 1970) stellt die Uhr fest. `imputeTS`
  (3.4, `na_interpolation` mit `option = "stine"` und `"linear"`, stinepack 1.5 `stinterp`;
  `simlev._r.imputets`, `simlev._r.stinepack`) ist ebenfalls nachgebildet:
  `fill = "stine"`/`index_fill = "stine"` im Backcast interpolieren immer
  nach Stineman wie R, das beide Pakete übernommen hat
  (`.imputets_na_interpolation`; Herkunft in `COPYRIGHTS.md`). Die
  MS-GARCH-Verfahren schätzen ihr Modell wie R selbst, ohne `MSGARCH`
  (`simlev.ms_garch`, Port von `.ms_garch_fit` und dem Kern `src/ms_garch.c`).
  Einen Schalter für optionale R-Pakete gibt es nicht mehr.
- **nlminb:** Die PORT-Bibliothek liest an drei Stellen nicht gesetzte
  lokale Variablen (in R zufällige Stapelreste); Python setzt dort 0. Das
  kann nur in Sonderfällen abweichen: die Meldung „X-convergence (3)“
  statt „both X-convergence and relative convergence (5)“ (`convergence`
  ist in beiden Fällen 0) bzw. Läufe mit Hesse-Funktion und Inf/NaN in
  Gradient oder Hesse-Matrix.
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

Geprüft wurde:

- **Engine:** die 68 Golden-Fälle in `golden/cases/` und die 37 Stressfälle
  in `golden/extra/`, alle bitgleich einschließlich Druckausgabe und
  `details = TRUE`; zusätzlich 669 frisch erzeugte Zufalls- und Stressfälle
  und 750 Fälle mit den neuen Argumenten (`order_fee`, `dca_fee`,
  `church_tax`, `harvest_*`, `taxable_income`, `tax_tariff`).
- **Alle Funktionen:** 4.563 Referenzfälle in 30 Modulen unter
  `golden/modules/`, darunter die R-Interna (`r_fmt`, `r_linalg`,
  `r_nmath`, `r_rng`, `r_stats`); alle bitgleich in Ergebnis,
  Konsolen- und Druckausgabe, Warnungen und Fehlermeldungen.

Bekannte Grenzen:

- `NA` und `NaN` werden wie in R unterschieden: `simlev.NA` trägt R's
  Bitmuster (NaN mit Nutzlast 1954), jedes andere `nan` ist R's `NaN`;
  `simlev.isna_strict(x)` erkennt nur `NA`. Fehlende Werte aus pandas
  (`NaN`, `None`, `NaT`) zählen wie in R's `is.na()` als fehlend. Weil
  `simlev.NA` ein signalisierendes NaN ist, meldet numpy bei Rechnungen
  damit „invalid value“; SimLev unterdrückt diese Warnungen in seinen
  Funktionen.
- Nichtzentrale Verteilungen (`ncp`) und einige selten genutzte Optionen
  der stats-Funktionen sind nicht portiert, weil das Paket sie nicht
  verwendet.

## Tests

``` bash
pip install ".[test]"
pytest                                        # 5.840 Tests, Laufzeit rund 7 Minuten
python tools/compare_golden.py                # Engine: golden/cases und golden/extra
python tools/compare_reference.py             # Erweiterungen: alle Module unter golden/modules
python tools/compare_reference.py optimize -k cov_ -v      # ein Modul, ausgewählte Fälle, ausführlich
```

Die Test-Suite enthält 4.563 Modul-Referenzfälle
(`tests/test_module_reference.py`) und die 105 Golden-Master-Fälle der
Engine (`tests/test_golden_master.py`, dazu ein Test, dass die Fälle
gefunden werden). Die übrigen 1.120 Tests prüfen die Engine (überwiegend
aus den testthat-Tests des R-Pakets übertragen) und die R-Interna in
`simlev/_r/`. `compare_golden.py` nimmt
Ordner oder Dateien sowie `-k fall …`, `-v` und `-q`;
`compare_reference.py` nimmt Modulnamen sowie `-k muster` und `-v`.

Die Referenzfälle liegen im gemeinsamen Ordner `golden/` im Hauptverzeichnis
des Repositorys. Die Tests finden ihn automatisch, solange Sie im
Repository arbeiten; sonst setzen Sie `SIMLEV_GOLDEN_DIR` (Engine-Fälle,
mehrere Ordner durch `os.pathsep` getrennt) bzw. `SIMLEV_MODULE_DIR`
(Ordner `golden/modules`). Wie die Fälle aufgebaut sind und neu erzeugt
werden, steht in [`golden/README.md`](../golden/README.md); Hinweise für die
Weiterentwicklung in [DEVELOPING.md](DEVELOPING.md).

## Projektstruktur

```
simlev/
  __init__.py        öffentliche Funktionen (alle 104 Exporte des R-Pakets)
  engine.py          simulation(), Ablaufsteuerung (simulation.R, sim_*.R, utils.R)
  _core.py           Rechenkerne der Engine (simulation_core.cpp, fifo_core.cpp, tax_core.cpp)
  _dates.py          Datumshelfer (Tage seit 1970, strptime wie R)
  config.py          asset_config(), create_strategy() & Co. (asset_config.R, strategy.R)
  trigger.py         compute_rebal_trigger()
  tax_tariff.py      read_tax_tariff(), Einkommensteuertarif
  result.py          SimLevResult mit print/summary/plot
  svg.py             Grafikmodul: SimLevPlot, plot-API und alle SVG-Zeichenbausteine
  dashboard.py       Dashboard: Daten und Panels (SVG)
  data_prep.py       Datenaufbereitung, Portfolio-Vorlagen
  backcast.py        backcast_fit(), backcast()
  bonds.py           Anleihe-, Geldmarkt- und gesicherte Reihen
  signals.py         Signal-Bausteine (signal_sma() …); Kerne in _signals_core.py
  bootstrap.py       Bootstrap, Bootstrap-Studien; Kerne in _bootstrap_core.py
  ms_garch.py        eigene MS-GARCH-Schätzung (ms_garch.R; Filter in _bootstrap_core.py)
  withdrawal.py      Entnahmephase; Kern in _withdrawal_core.py
  deep_analysis.py   deep_analysis()
  sensitivity.py     Sensitivitäten, Lump Sum vs. DCA, Hebelreihen
  param_search.py    Parametersuche, Plateau
  overfitting.py     PBO, Deflated Sharpe, Walk-Forward, Harvey-Liu
  dependence.py      Abhängigkeiten, Copulas, DCC, Quantilsregression, CoVaR; Kerne in _dependence_core.py
  regimes.py         Hidden-Markov-Regime
  scenarios.py       Entropy Pooling, Copula-Szenarien, Krisen-Replay
  tactical.py        taktische Allokation
  optimize.py        Portfolio-Optimierung, Risikobeiträge; Kerne in _optimize_core.py
  planning.py        Länder-Bootstrap, Renditeannahmen, goal_optimize()
  analysis_tests.py  statistische Prüfungen
  data/              steuertarif.csv (Tarif ab VZ 2026), r_colors.csv (R-Farbnamen)
  _r/                R-Kompatibilitätsschicht
    rnum.py          NA, Summen mit long double, pow, uniroot (unterste Schicht)
    rformat.py       Rundung und Textausgabe der Engine (round, signif, format, sprintf)
    rng.py           Zufallszahlen wie R
    nmath.py         Verteilungsfunktionen (mit _toms708.py, _cmath.py)
    stats.py         stats-Interna (mit _optim.py, _lbfgsb.py, _sbart.py, _fft.py, port.py)
    linalg.py        lineare Algebra (mit _blas.py, _linpack.py, _lapack.py)
    base.py, libm.py base-Funktionen mit long double, libm-Funktionen
    fmt.py           format, sprintf, print wie R
    rlist.py         Basisklasse RList der Ergebnisobjekte
    reftree.py       Laden und Vergleichen der Referenzfälle
tests/               pytest-Suite
tools/               compare_golden.py, compare_reference.py
examples/            lauffähige Beispiele
```

## Lizenz

GPL-3, wie das R-Paket. Siehe [LICENSE.md](LICENSE.md).
