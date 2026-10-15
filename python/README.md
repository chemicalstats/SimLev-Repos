<p align="center">
  <img src="https://raw.githubusercontent.com/chemicalstats/SimLev-Repos/main/docs/figures/logo.png" alt="SimLev-Logo" width="220" />
</p>

<h1 align="center">SimLev für Python</h1>

<p align="center">
  <strong>Simulation und Backtesting für Basis-, Hebel- und Multi-Asset-Strategien für Exchange Traded Products</strong>
</p>

---

Dieses Paket ist die Python-Fassung des R-Pakets SimLev. Es läuft
**eigenständig ohne R**, benötigt nur `numpy` und `pandas` und rechnet
**bitgleich** zu einem früheren Stand des R-Pakets, dem Stand vor den
Korrekturen (Commit 54b5b4f, damals ebenfalls als 0.5.0 bezeichnet): Jeder
Tageswert, jede Kennzahl, jeder Steuerbetrag und auch die Textausgabe
stimmen mit diesem Stand exakt überein. Zur aktuellen R-Fassung 0.5.0 ist
die Python-Fassung **nicht** bitgleich: Deren Engine-Korrekturen,
steuerrechtliche Anpassungen und deutsche Ausgaben sind hier noch nicht
nachgezogen; alle 68 Golden-Fälle weichen deshalb ab (2 davon nur in der
Druckausgabe), die
zugehörigen Bitgleichheits-Tests schlagen fehl (siehe Haupt-README, Abschnitt „Bitgleichheit“).

**Die vollständige Dokumentation mit Grundkonzepten, Steuerlogik und
Beispielen für alle drei Sprachen steht in der
[Haupt-README](https://github.com/chemicalstats/SimLev-Repos#readme).** Hier
finden Sie nur, was speziell die Python-Fassung betrifft.

## Installation

SimLev ist reines Python ab Version 3.9 (getestet mit 3.13). Ein Compiler
wird nicht benötigt.

``` bash
pip install "simlev @ git+https://github.com/chemicalstats/SimLev-Repos#subdirectory=python"
pip install "simlev[plot] @ git+https://github.com/chemicalstats/SimLev-Repos#subdirectory=python"   # mit matplotlib
```

Aus einem lokalen Klon (im Ordner `python/`):

``` bash
pip install .                 # nur die Engine (numpy, pandas)
pip install ".[plot]"         # zusätzlich matplotlib für das Dashboard
pip install ".[all]"          # zusätzlich plotly für interaktive plotly-Figuren
```

| Paket | Wofür | Pflicht? |
|---|---|---|
| `numpy`, `pandas` | Rechenkern und Datenaufnahme | ja |
| `matplotlib` | Statisches Dashboard (`result.plot()`, `export_dashboard`) | optional |
| `plotly` | Interaktives Dashboard als plotly-Figur (ohne plotly schreibt SimLev ein eigenes, abhängigkeitsfreies HTML) | optional |
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

print(result)   # CAGR +6.75 %, Endwert 19.195,90 EUR
result.plot()
```

## Von R zu Python

Funktionsnamen und Argumente sind identisch mit dem R-Paket:

| R | Python |
|---|---|
| `NULL` | `None` |
| `TRUE` / `FALSE` | `True` / `False` |
| `c(20, 400)` | `(20, 400)` oder `[20, 400]` |
| `list(A = "w1")` | `{"A": "w1"}` |
| `data.frame(...)` | `pandas.DataFrame(...)` |
| `result$worth` | `result.worth` |
| `result$statistics$sharpe` | `result.statistics["sharpe"]` |
| `result$report$WORLD$total` | `result.report["WORLD"]["total"]` |
| `print(result)`, `summary(result)` | `print(result)`, `result.summary()` |
| `plot(result)` | `result.plot()` |
| `plot_interactive(result)` | `simlev.plot_interactive(result)` oder `result.plot_interactive()` |

Besonderheiten der Python-Fassung:

- `result.trades` enthält zusätzlich alle Buchungen (Lots, Verkäufe,
  Vorabpauschalen, Gebühren je Asset).
- `plot_interactive(..., engine="plotly")` liefert eine plotly-Figur, zum
  Beispiel für Jupyter.
- Hinweise wie die Meldung über aufgefüllte Kalendertage erscheinen, wie
  R's `message()`, auf `stderr`.
- Die Währungsachse des Dashboards ist wie in R mit `$` beschriftet. Mit
  `currency="€"` stellen Sie das um.

## Bitgleichheit und Plattformen

R summiert intern mit 80-Bit-`long double`; die Python-Fassung nutzt dafür
`numpy.longdouble` in derselben Reihenfolge. Die Bitgleichheit gilt deshalb
für **Linux auf x86-64**. Auf Plattformen mit 64-Bit-`long double` (z. B.
macOS auf Apple Silicon) rechnet auch R anders; dort können die letzten
Bits abweichen, und die Tests prüfen mit einer Toleranz von 1e-9.

Geprüft wurden 658 Szenarien (38 gezielte Fälle für jeden Steuer- und
Sonderpfad und 620 zufällige Parameterkombinationen), alle bitgleich (Stand
54b5b4f).

## Tests

``` bash
pip install ".[test]"
pytest                       # 124 Tests, davon 68 Bitgleichheits-Tests gegen R
```

Die Referenzfälle liegen im gemeinsamen Ordner `golden/cases/` im
Hauptverzeichnis des Repositorys. Die Tests finden ihn automatisch, solange
Sie im Repository arbeiten; sonst setzen Sie `SIMLEV_GOLDEN_DIR`.
Einzelne Fälle mit ausführlicher Ausgabe vergleicht
`python tools/compare_golden.py <ordner> [fall-id ...]`.

## Projektstruktur

```
simlev/
  engine.py        simulation(), Ablaufsteuerung (Port von simulation.R)
  _core.py         Rechenkerne (Port der C++-Dateien des R-Pakets)
  _rnum.py         R-kompatible Numerik (long double, pow, Rundung)
  config.py        asset_config(), create_strategy() & Co.
  trigger.py       compute_rebal_trigger()
  result.py        SimLevResult mit print/summary/plot
  dashboard.py     Dashboard (matplotlib)
  interactive.py   Interaktives HTML-Dashboard
tests/             pytest-Suite
tools/             Abgleich mit den Referenzfällen aus R
examples/          Lauffähige Beispiele
```

## Lizenz

GPL-3, wie das R-Paket. Siehe [LICENSE.md](LICENSE.md).
