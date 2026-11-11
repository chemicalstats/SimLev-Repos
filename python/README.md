<p align="center">
  <img src="https://raw.githubusercontent.com/chemicalstats/SimLev-Repos/main/r/man/figures/logo.png" alt="SimLev-Logo" width="220" />
</p>

<h1 align="center">SimLev für Python</h1>

<p align="center">
  <strong>Simulation und Backtesting für Basis-, Hebel- und Multi-Asset-Strategien für Exchange Traded Products</strong>
</p>

---

Dies ist die Python-Fassung von SimLev, eine von drei gleichwertigen
Fassungen: Die Rechenkerne liegen als gemeinsamer C/C++-Code in `core/` und
werden als C-Erweiterung gebaut; Python bildet die Schnittstelle darum
(Eingabeprüfung, Datenaufbereitung, Ablauf, Ergebnisobjekte, Druck, Grafik).
Alle Funktionen haben in R, Python und Julia gleiche Namen, Argumente und
Voreinstellungen und rechnen **bitgleich** (Ergebnisse, Druckausgabe,
Warnungen und Fehlermeldungen). Das Paket läuft ohne R und braucht nur
`numpy` und `pandas`.

**Einstieg:** das [Tutorial](examples/tutorial.md) mit Daten, Strategie,
`simulation()` mit allen Bausteinen, Auswertung, Bootstrap, Entnahme,
Optimierung und Grafik. Beschreibung, Argumente, Rückgabe und ein Beispiel
je Funktion stehen in den Docstrings (`help(simlev.simulation)`).
Übersicht, Bitgleichheit und Lizenz stehen in der
[Haupt-README](https://github.com/chemicalstats/SimLev-Repos#readme), die
Quellen der Verfahren in
[`LITERATUR.md`](https://github.com/chemicalstats/SimLev-Repos/blob/main/LITERATUR.md).

## Installation

Python ≥ 3.10, dazu ein C- und C++-Compiler (C99, C++17) und die
Python-Header: unter Linux `gcc`/`g++` bzw. `build-essential` und z. B.
`python3-dev`, unter macOS die Xcode Command Line Tools, unter Windows die
Build Tools für Visual Studio. Ohne Compiler bricht die Installation ab.

``` bash
pip install "simlev @ git+https://github.com/chemicalstats/SimLev-Repos#subdirectory=python"

# aus einem lokalen Klon, im Ordner python/
pip install .                              # Paket mit C-Erweiterung
python setup.py build_ext --inplace        # nur bauen, für die Arbeit im Klon
```

## Kurzbeispiel

Das vollständige Skript mit Dashboard liegt unter
[`examples/schnellstart.py`](examples/schnellstart.py).

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
result = simlev.simulation(data, strategy, start_value=10000,
                           rebalance=simlev.rebalance_plan(span=1, unit="year"),
                           tax=simlev.tax_profile(rate=26.375), liquidate=True, risk_free=2)
print(round(result.worth[-1], 2))
```

``` text
19193.75
```

## Von R zu Python

| R | Python |
|---|---|
| `NULL` | `None` |
| `TRUE` / `FALSE` | `True` / `False` |
| `NA` | `simlev.NA` (numerisch; ein gewöhnliches `nan` ist R's `NaN`) bzw. `None` |
| `c(20, 400)` | `(20, 400)` oder `[20, 400]` |
| `c(us = "us_ret")`, `list(A = "w1")` | `{"us": "us_ret"}`, `{"A": "w1"}` |
| `data.frame(...)` | `pandas.DataFrame(...)` |
| benannter Vektor | `pandas.Series` (Index = Namen) oder `dict` |
| Matrix | `numpy.ndarray`, mit Zeilen- und Spaltennamen `pandas.DataFrame` |
| `simulation(data, s, start_value = 1e4)` | `simlev.simulation(data, s, start_value=1e4)` |
| `result$worth` | `result.worth` oder `result["worth"]` |
| `result$statistics$sharpe` | `result.statistics["sharpe"]` |
| `result$report$WORLD$total` | `result.report["WORLD"]["total"]` |
| `summary(x)` | `simlev.summary(x)` oder `x.summary()` |
| `plot(x)` | `simlev.plot(x)` oder `x.plot()` |
| `bootstrap_probability(st, cagr > 0.05)` | `simlev.bootstrap_probability(st, "cagr > 0.05")` |
| `function(df) signal_sma(df$INDEX, 200)` | `lambda df: simlev.signal_sma(df["INDEX"], n=200)` |
| Argumente `yield`, `raise`, `from` | `yield_`, `raise_`, `from_` |

Besonderheiten:

- Ergebnisobjekte (`SimLevResult`, `SimLevBootstrapStudy` …) erben von
  `simlev._r.rlist.RList`, einem geordneten `dict` mit Attributzugriff; die
  Elemente stehen in derselben Reihenfolge wie in R, `print(x)` liefert die
  Ausgabe der R-`print`-Methode.
- Bedingungen als Text (`tactical_rules()`, `bootstrap_probability()`,
  `regime_subset()`, `view_prob()`) werden in **R-Syntax** ausgewertet
  (`"cagr > 0 & max_drawdown <= 0.3"`, `"x %in% c(1, 2)"`); eine
  Python-Funktion geht ebenfalls.
- `result.trades` enthält je Asset die Käufe, Verkäufe und Steuerbuchungen
  (`buys`, `sells`, `taxes`); in R gibt es kein Gegenstück.
- `simlev.bootstrap`, `simlev.backcast` und `simlev.param_search` sind
  zugleich Modul und aufrufbare Funktion.
- `cores > 1` rechnet mit Fork-Prozessen, wo es keinen Fork gibt (Windows,
  macOS mit `spawn`) nacheinander, stets mit denselben Ergebnissen.
  `bootstrap_study(chunk_dir=...)` speichert Zwischenergebnisse als Pickle.
- Hinweise erscheinen wie R's `message()` auf `stderr`, Warnungen sind
  `UserWarning`, Fehler `ValueError`, mit demselben deutschen Wortlaut wie
  in R und Julia.
- `simlev.NA` trägt R's Bitmuster (NaN mit Nutzlast 1954);
  `simlev.isna_strict(x)` erkennt nur `NA`. Fehlende Werte aus pandas
  zählen wie in R's `is.na()` als fehlend.
- Grafiken entstehen als SVG ohne Zusatzpaket (`SimLevPlot` mit `svg`,
  `data`, `source`, `kind`); für PDF oder PNG die SVG-Datei umwandeln.
- Zeichenketten werden wie in R über die System-ICU sortiert (`libicui18n`,
  Pfad über `SIMLEV_ICU`; `SIMLEV_COLLATE=C` erzwingt die
  Byte-Reihenfolge).

## Entwicklung

Bauen, Abgleich der C-Quellen (`core/sync.py`), Tests und Regeln für die
Bitgleichheit stehen in [DEVELOPING.md](DEVELOPING.md), die Zuordnung der
Module zu den R-Dateien in
[`STRUKTUR.md`](https://github.com/chemicalstats/SimLev-Repos/blob/main/STRUKTUR.md),
die Änderungen in [NEWS.md](NEWS.md).

## Lizenz

GPL-3, wie das R-Paket. Siehe [LICENSE.md](LICENSE.md).
