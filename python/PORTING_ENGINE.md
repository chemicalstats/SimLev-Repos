# Engine-Port (SimLev 0.5.0): Konventionen und Numerik-Helfer

Diese Notiz gilt für `simulation()` und alles, was daran hängt (`engine.py`, `_core.py`,
`_rnum.py`, `_dates.py`, `config.py`, `trigger.py`, `result.py`, `tax_tariff.py`,
`dashboard.py`, `interactive.py`). Allgemeine Regeln stehen in `DEVELOPING.md`.
Hier steht, was andere Module brauchen, wenn sie die Engine aufrufen oder ihre
Helfer verwenden.

## Stand

- `golden/cases` 68/68 und `golden/extra` 37/37 sind bitgleich, einschließlich Druckausgabe
  und `details = TRUE`. Das prüft `python tools/compare_golden.py [Pfade] [-k ids] [-v] [-q]`.
- Zusätzlich frisch erzeugte Fälle (300 Zufallsfälle, Seed 777 bzw. 999, jeweils mit den
  festen Fällen des Generators): `golden_cases.R` und `stress_cases.R` ergeben 669/669. Die neuen Argumente (order_fee, dca_fee, church_tax, harvest_*,
  taxable_income, tax_tariff) wurden zusätzlich in 750 Fällen voll verglichen.
- Die R-Tests der Engine sind nach `tests/test_*engine*.py`, `test_tax*.py`,
  `test_simulation.py`, `test_config.py` und `test_dashboard.py` portiert.

## Abbildung der R-Objekte

| R | Python |
|---|---|
| `SimLevResult` (benannte Liste) | `simlev.SimLevResult(RList)`: `res["worth"]` und `res.worth`; Elemente in R-Reihenfolge |
| numerischer Vektor | `numpy.ndarray` (float64) |
| `Date`-Vektor | `numpy.ndarray` `datetime64[D]` |
| benannter Vektor (`buys`, `sells`) | `pandas.Series` mit Assetnamen als Index |
| Liste ohne Klasse (`statistics`, `tax_report`, `report$A`, `next_year`) | `dict` |
| `data.frame` (`undefined_metrics`, `tariff_years`, `open_lots$A$lots`) | `pandas.DataFrame` |
| `NULL` (z. B. `open_lots` ohne Steuern, `order_fee` nicht gesetzt) | `None`; ein Element, das R weglässt, fehlt auch im dict |
| `NA` / `NaN` | `NA` = `simlev.NA` (NaN mit R's Nutzlast 1954), `NaN` = gewöhnliches `nan`; unterschieden wie in R |
| `asset_config`, `strategy`, `SimLevTaxTariff`, `summary.SimLevResult` | `AssetConfig`, `Strategy`, `SimLevTaxTariff`, `SimLevSummary` (alle `RList`; `format()` liefert genau die R-Druckausgabe) |
| `attr(data, "filled")` | `data.attrs["filled"]`: bool-`DataFrame`, eine Spalte je Kursreihe (wie in `align_series`) |

- Python-`int` zählt als R-`double`. `_r_class_name()` in `engine.py` liefert für Meldungen
  den Klassennamen wie `class(x)[1]`.
- `res.trades` gibt es nur in Python (Lots, Verkäufe, Steuer- und Gebührenbuchungen je
  Asset). In R gibt es kein Gegenstück, die Golden-Vergleiche lassen es aus.

## Meldungen

- `stop()` wird zu `ValueError(text)`, Wortlaut wie in R (deutsch).
- `warning()` wird zu `warnings.warn(text)` (`UserWarning`), Wortlaut wie in R.
- `message()` geht nach `sys.stderr` (mit Zeilenumbruch). `cat()` und `print()` gehen nach `stdout`.
- `match.arg` mit typografischen Anführungszeichen: `config._match_arg(value, choices, argname)`.
  Für `several.ok = TRUE` gibt es `interactive._match_arg_several`. `pmatch` liegt in `config._pmatch`.
- `summary(res)` druckt nicht, sondern gibt `SimLevSummary` zurück. `print(res)` bzw.
  `res.print()` druckt.

## Argumente: angegeben oder nicht

R prüft an mehreren Stellen `missing(arg)`. In der Engine haben solche Argumente als
Standardwert `_Default(wert)`. `_unwrap()` liefert den Wert, und `given` hält fest,
welche Argumente ausdrücklich angegeben wurden.

## R-Numerik: `simlev/_rnum.py`

Bitgleichheit braucht dieselbe Rechenreihenfolge und dieselbe Akkumulation. Regeln:

- **Keine numpy-Transzendentalfunktionen** (`np.exp`, `np.log`, `np.power` …), denn ihre
  SIMD-Varianten runden anders. Verwende stattdessen `math.*`, `r_pow` (x^2 = x*x, sonst
  `math.pow` wie `R_pow`) bzw. `r_pow_vec` und `r_exp_vec`. `np.sqrt`, `+`, `-`, `*`
  und `/` sind exakt gerundet und dürfen bleiben.
- Summen wie in R mit long double (`LD = np.longdouble`, 80 Bit unter Linux/x86-64):
  `r_sum`, `r_mean` (mit Korrekturdurchlauf), `r_mean_int`, `r_cumsum`, `r_prod`,
  `r_cumprod`, `r_cummax`, `r_var`, `r_sd`, `r_median`, `r_rowsums`, `r_colsums`.
  `np.sum` bzw. `np.cumsum` ergeben andere Bits.
- Runden: `r_round` (fround.c, R ≥ 4), `r_signif` (fprec.c), `r_mod1`.
- Formatieren: `r_format(x, digits, nsmall, big_mark, scientific, width)` (formatReal,
  gibt eine Liste zurück), `r_format1`, `r_as_character` (15 Stellen, Drop0),
  `r_deparse`, `r_sprintf(fmt, *args)`. Die letzte Funktion unterstützt `%*.*f`;
  NA, Inf und -Inf werden wie in R als `%s` mit `"NA"`, `"Inf"` bzw. `"-Inf"` ausgegeben.
- Nullstellen: `r_uniroot(f, interval, f_lower, f_upper, tol, maxiter)`, gestützt auf
  `r_zeroin2` (Brent wie in R, Inf und NA werden wie in fcn2 ersetzt).
- `_dates.py`: Tageszahlen ab 1970 und R-`strptime` für `"%Y-%m-%d"` (Semantik von get_number).
- Weitere Hilfen in `simlev/_r/` (fmt, stats, nmath …) sind für neue Module gedacht.
  Die Engine nutzt bewusst weiter `_rnum`.

## Öffentliche Engine-Helfer für andere Module

`simulation`, `xirr_rate` / `_xirr_rate`, `calculate_skewness`, `calculate_kurtosis`,
`calculate_partials`, `calculate_dates_flags`, `apply_spread`, `create_strategy`,
`asset_config` (sowie `add_asset`, `update_asset`, `remove_asset`, `validate_strategy`,
`migrate_strategy`), `compute_rebal_trigger` und `read_tax_tariff`. Dazu kommen die
Dashboard-Daten `dashboard._dashboard_returns(res)` (wie `.dashboard_returns`) und
`interactive._build_data(res, max_points)` (wie `.build_dashboard_data`).

## Grafik

- `plot_dashboard` bzw. `res.plot()` zeichnet mit matplotlib und gibt die Figure zurück
  (R: invisible NULL). Gleich wie in R sind Prüfungen, Meldungen, alle Beschriftungstexte,
  Monatsrenditen, rollierende Renditen und Korrelationen sowie die Farben der
  Vergleichstabelle. Abgeglichen wurde das über einen `trace()`-Mitschnitt in R.
  Schriftgrößen und Ränder sind dagegen nur angenähert. R-Farbnamen stehen in
  `simlev/data/r_colors.csv` (`grDevices::colors()`).
- Das HTML von `plot_interactive(engine="html")` ist byte-identisch zu R.
- `export_html_dashboard` ist wie in R nur ein Platzhalter: ohne plotly ein Fehler, sonst
  eine Meldung, und es wird keine Datei geschrieben.

## Werkzeuge

- `tools/compare_golden.py`: Golden-Fälle (`.json`/`.json.gz`) in einem oder mehreren Ordnern.
- Frische Fälle erzeugen: `Rscript golden/golden_cases.R <ziel> N SEED` bzw. `stress_cases.R`,
  das Ziel liegt **außerhalb des Repos** (z. B. in einem temporären Ordner). Danach
  `compare_golden.py <ziel>` aufrufen.
- Immer `LC_ALL=C.UTF-8`. Die Bitgleichheit setzt 80-Bit-long-double voraus (Linux/x86-64).
