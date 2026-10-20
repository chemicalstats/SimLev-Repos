# Entwicklernotiz: Python-Fassung von SimLev

Diese Notiz gilt für alle Änderungen an `python/simlev/`. Sie beschreibt die
Konventionen der bitgleichen Portierung des R-Pakets SimLev 0.5.0, das
Referenzwerkzeug und die Zuordnung der R-Dateien zu den Python-Modulen.
Was speziell die Engine (`simulation()`) betrifft, steht in
[PORTING_ENGINE.md](PORTING_ENGINE.md).

## Voraussetzungen

- Maßgeblich sind die Quellen des R-Pakets: `r/R/*.R`, `r/src/*.cpp`,
  `r/man/*.Rd`, `r/tests/testthat/` und `r/NEWS.md`. Für die nachgebauten
  R-Interna in `simlev/_r/` sind es die Quellen von R 4.3.3
  (`src/main`, `src/nmath`, `src/appl`, `src/library/stats`,
  `src/library/base`, `src/modules/lapack`, `src/extra/blas`).
- Referenzfälle erzeugt R 4.3.3 mit dem installierten R-Paket SimLev 0.5.0
  und `jsonlite`. Die Generatoren `gen_evd.R` und `gen_rugarch.R` brauchen
  zusätzlich evd 2.3-7.1 bzw. rugarch 1.5-6 (mit Rsolnp 1.16, numDeriv,
  truncnorm 1.0-9), `gen_imputets.R` imputeTS 3.4 und stinepack 1.5, jeweils in
  einer eigenen R-Bibliothek (`SIMLEV_R_SUGGESTS_LIB`); alle anderen laufen
  **ohne** die optionalen Pakete. Jeder Fall vermerkt im Feld `suggests`,
  welche davon R hatte, und die Harnesses setzen `SIMLEV_R_SUGGESTS` je
  Fall. MSGARCH, plotly und TTR sind nie installiert; Funktionen,
  die in R ein fehlendes Paket verlangen, werfen dieselbe Meldung.
- Bitgleichheit setzt Linux x86-64 (80-Bit-`long double`), glibc-libm und
  für Eigenvektoren die Referenz-LAPACK des Systems voraus.
- Immer mit `LC_ALL=C.UTF-8` arbeiten; unter dem C-Locale schlagen die
  Vergleiche der Druckausgabe wegen der Umlaute fehl.

## Ziel

Jede exportierte R-Funktion hat ein Python-Gegenstück mit gleichem Namen
(Punkte im R-Namen werden zu `_`), gleichen Argumentnamen und gleichen
Voreinstellungen. Ergebnisse sind **bitgleich** (IEEE-754-Doubles
identisch), Druckausgaben (`print`) zeichengleich, Fehlermeldungen und
Warnungen wortgleich (deutsch). Argumente, die in Python Schlüsselwörter
sind, heißen `yield_`, `raise_` und `from_`.

## Datenstrukturen (R ↔ Python)

- R-Listen-Ergebnisse mit Klasse → Python-Klasse, die von
  `simlev._r.rlist.RList` erbt (dict-artig: `x["name"]` und `x.name`,
  Reihenfolge der Elemente wie in R; `format()`, `__str__` und `__repr__`
  liefern exakt die Ausgabe von R's `print`-Methode). `summary()` ist eine
  Methode `x.summary()`, deren Ergebnis wieder wie in R druckt; das
  generische `simlev.summary(x)` bzw. `simlev.plot(x)` ruft die Methode auf.
- `data.frame` → `pandas.DataFrame` (Spaltennamen wie in R; Datumsspalten
  `datetime64[ns]` oder `[D]`, beim Vergleich gleichwertig).
- Benannter Vektor → `pandas.Series` (Index = Namen); unbenannter Vektor →
  `numpy.ndarray`; Länge-1-Werte dürfen Python-Skalare sein.
- Matrix → 2-D-`numpy.ndarray`, mit dimnames → `pandas.DataFrame`.
- `NULL` → `None`, numerisches `NA` → `simlev.NA` (= `simlev._rnum.NA_REAL`,
  `simlev._r.fmt.NA_REAL`; NaN mit R's Nutzlast 1954), sonst `None`. R's
  `NaN` ist ein gewöhnliches `nan`. Wo R `NA_real_` setzt, `NA_REAL`
  setzen; Arithmetik erhält die Nutzlast wie in R. Erkennen mit
  `_rnum.r_isna`/`r_isna_arr` (wie `R_IsNA`). numpy-Funktionen, die NaN neu
  erzeugen (`np.full(n, np.nan)`, `reindex`, `shift`, `np.nanmean`), nicht
  für R-NA verwenden. `NA_REAL` ist signalisierend; öffentliche
  Funktionen eines Moduls laufen deshalb unter `quiet_fp`
  (`simlev/_r/base.py`), das numpys „invalid value“-Warnungen unterdrückt.
- Funktionsargumente akzeptieren dieselben Formen (`Series`, `dict`,
  Array, `DataFrame`).
- Bedingungen, die R als Ausdruck erhält (`tactical_rules()`,
  `bootstrap_probability()`, `regime_subset()`, `view_prob()`), sind in
  Python Text in R-Syntax und werden wie in Julia mit `simlev._r.rexpr`
  ausgewertet (R-Vorrang, NA-Logik, `%in%`, `!`, Indizierung, if/else;
  freie Variablen aus `env`, sonst aus dem Namensraum des Aufrufers).
  Python-Funktionen sind als Bedingung ebenfalls erlaubt.
- Meldungen: `stop()` → `ValueError`, `warning()` → `warnings.warn`
  (`UserWarning`), `message()` → `sys.stderr`; `cat()` und `print()` gehen
  nach `stdout`.

## Regeln für Bitgleichheit

1. Rechenreihenfolge 1:1 aus R/C++ übernehmen; keine Umformungen, auch
   keine mathematisch gleichwertigen.
2. R akkumuliert `sum`, `mean`, `cumsum`, `prod`, `rowSums`, `colSums`,
   `var`/`cov` in 80-Bit-`long double` (`numpy.longdouble`). Dafür gibt es
   `simlev._rnum` bzw. `simlev._r.base` (`r_sum`, `r_mean`, …); `np.sum`
   und `np.cumsum` ergeben andere Bits. `cumprod` nutzt in R `LDOUBLE`,
   `cummax`/`cummin` nicht.
3. **Keine numpy-Transzendentalfunktionen** (`np.exp`, `np.log`,
   `np.log1p`, `np.expm1`, `np.power`, `np.tanh`, `np.arctanh`, …). Auf
   Rechnern mit AVX-512 weichen sie von glibc-libm ab; R nutzt libm.
   Stattdessen `simlev._r.libm` (`exp`, `log`, `log1p`, `expm1`, `pow`,
   `tanh`, … elementweise über `math`). `+ - * / sqrt abs floor` von numpy
   sind exakt gerundet. `x^2` ist in R `x*x`, `x^y` sonst libm-`pow` (siehe
   `_rnum.r_pow`).
4. Zufallszahlen ausschließlich über `simlev._r.rng` (Mersenne-Twister wie
   R, `set_seed`, `runif`, `rnorm`, `rchisq`, `rgeom`, `sample_int`,
   L'Ecuyer-Streams). Der Zustand ist global wie `.Random.seed`; die
   Reihenfolge der Zufallszüge muss exakt der in R entsprechen.
5. Statistik- und Numerik-Interna (`quantile`, `median`, `cor`, `optim`,
   `optimize`, `uniroot`, `lm.fit`, `glm`, `smooth.spline`, `density`,
   `hclust`, `approx`, `filter`, …) kommen aus `simlev._r.stats`,
   Verteilungen (`qnorm`, `pt`, `qt`, `lgamma`, …) aus `simlev._r.nmath`,
   lineare Algebra (`%*%`, `crossprod`, `solve`, `chol`, `eigen`, `qr`,
   `backsolve`, `determinant`) aus `simlev._r.linalg`, Formatierung
   (`format`, `formatC`, `round`, `signif`, `prettyNum`, `print` von
   Vektoren, Matrizen und data.frames) aus `simlev._r.fmt`. Fehlt dort
   etwas, wird es dort ergänzt (mit eigenen Referenzfällen), nicht im
   aufrufenden Modul nachgebaut.
6. Eigenvektoren (`dsyevr` mit `jobz = "V"`) kommen über ctypes aus der
   System-Referenz-LAPACK (`SIMLEV_LAPACK` wählt die Bibliothek); alles
   andere aus LAPACK, BLAS und LINPACK ist rein portiert.
7. Nichts erfinden: Maßgeblich sind R-Code und R-Ergebnis. Bei Unklarheit
   in R nachrechnen.
8. Grafiken (matplotlib) müssen nicht bitgleich sein, aber dasselbe zeigen;
   die berechneten Daten dahinter sind bitgleich.
9. Zeichenketten sortieren und vergleichen nur über `simlev._r.stats`
   (`order`, `sort`, `rank`, `str_collate`; ICU-Kollation wie R), nie über
   `sorted`, `np.sort`, `np.unique` oder `pd.Categorical` mit Standardordnung.
10. Bedingungen als Text nur über `simlev._r.rexpr.eval_r` (R-Syntax).
11. `requireNamespace("evd"/"rugarch"/"imputeTS", quietly = TRUE)` → bei jedem Aufruf
    `simlev._r.suggests.has(...)` (Schalter `SIMLEV_R_SUGGESTS`).
    `Sys.time()` → `simlev._r.base.sys_time()` (Prüfschalter
    `SIMLEV_R_SYS_TIME`).

## Gemeinsam genutzte Helfer

Die internen R-Helfer (`.name`) heißen in Python `_name` und stehen im
Modul der R-Datei, aus der sie stammen, mit derselben Signatur:

| Helfer | Modul |
|---|---|
| `_to_date`, `_add_months`, `align_series`, `_num_text_cols`, `_num_text_stop`, `_cpi_level` | `data_prep.py` |
| `_fill_na`, `_resolve_series` | `backcast.py` |
| `_roll_mean`, `_roll_var`, `_roll_cov` | `signals.py` |
| `_with_rng_restore`, `_par_lapply`, `_extract_returns`, `_pw_block`, `_fit_garch11`, `_wquantile` | `bootstrap.py` |
| `result_index`, `_wd_ppy`, `_anniv_ends` | `withdrawal.py` |
| `_dep_sort_dates`, `_dep_check_prices`, `_dep_returns`, `_kendall` | `dependence.py` |
| `_as_weights`, `_period_last`, `_hold_rows` | `tactical.py` |
| `_of_returns`, `_as_spec`, `_ps_neighbours`, `plateau` | `overfitting.py`, `param_search.py` |
| `_da_series`, `_da_deflate` | `deep_analysis.py` |
| `simulation`, `_xirr_rate`, `calculate_skewness`, `calculate_kurtosis`, `calculate_dates_flags` | `engine.py` |

`.with_rng_restore(expr, seed)` wird zu `_with_rng_restore(fn,
seed=_MISSING)`: ruft `fn()` auf; `seed=None` heißt, nichts sichern und
nichts setzen. `.par_lapply(X, FUN, cores)` wird zu `_par_lapply(X, FUN,
cores)`: rechnet in Python sequenziell, bildet aber die Fork-Semantik von
`mclapply(mc.set.seed = FALSE)` nach (bei `cores > 1` und mehr als einem
Element startet jedes Element mit dem RNG-Zustand des Aufrufers, der danach
unverändert bleibt).

## Zuordnung R-Datei → Python-Modul

| R-Quelle | Python |
|---|---|
| `simulation.R`, `sim_prepare.R`, `sim_validate.R`, `sim_loop.R`, `sim_actions.R`, `sim_evaluate.R`, `utils.R` | `engine.py`, `_rnum.py`, `_dates.py` |
| `simulation_core.cpp`, `fifo_core_RCpp.cpp`, `tax_core_RCpp.cpp` | `_core.py` |
| `asset_config.R`, `strategy.R` | `config.py` |
| `compute_rebal_trigger.R` | `trigger.py` |
| `tax_tariff.R`, `inst/extdata/steuertarif.csv` | `tax_tariff.py`, `data/steuertarif.csv` |
| `print`/`summary` von `SimLevResult` | `result.py` |
| `plot_dashboard.R` | `dashboard.py` (R-Farbnamen in `data/r_colors.csv`) |
| `plot_interactive.R` | `interactive.py` |
| `data_prep.R` | `data_prep.py` |
| `backcast.R` | `backcast.py` |
| `bonds.R` | `bonds.py` |
| `signals.R`; `.roll_mean_core`, `.roll_cov_core` aus `research_core.cpp` | `signals.py`, `_signals_core.py` |
| `bootstrap.R`, `bootstrap_core.cpp`; `.garch_filter` aus `research_core.cpp` | `bootstrap.py`, `_bootstrap_core.py` |
| `withdrawal.R`, `withdrawal_core.cpp` | `withdrawal.py`, `_withdrawal_core.py` |
| `dependence.R`, `dependence_core.cpp`; `.kendall_tau_core`, `.quantile_reg_core`, `.hmm_forward_backward` aus `research_core.cpp` | `dependence.py`, `_dependence_core.py` |
| `regimes.R` | `regimes.py` |
| `scenarios.R` | `scenarios.py` |
| `optimize.R`; `.proj_box_simplex`, `.qp_box_simplex`, `.min_cvar_core`, `.min_cdar_core` aus `research_core.cpp` | `optimize.py`, `_optimize_core.py` |
| `tactical.R` | `tactical.py` |
| `deep_analysis.R` | `deep_analysis.py` |
| `planning.R` | `planning.py` |
| `analysis_tests.R` | `analysis_tests.py` |
| `overfitting.R` | `overfitting.py` |
| `param_search.R` | `param_search.py` |
| `sensitivity.R` | `sensitivity.py` |
| R-Interna (R 4.3.3) | `_r/`: `rng.py` (RNG.c, `nmath/r*.c`), `nmath.py`, `_toms708.py`, `_cmath.py` (nmath), `stats.py`, `_optim.py`, `_lbfgsb.py`, `_sbart.py`, `_fft.py` (stats, appl), `linalg.py`, `_blas.py`, `_linpack.py`, `_lapack.py` (BLAS, LINPACK, LAPACK), `base.py`, `libm.py`, `fmt.py`, `rlist.py`, `reftree.py`; `_port.py` (stats `port.c`, `portsrc.f`: `nlminb`) |
| optionale R-Pakete | `_r/`: `suggests.py` (Schalter), `imputets.py` (imputeTS 3.4 `na_interpolation` stine/linear, `na_locf` mit `src/locf.cpp`), `stinepack.py` (stinepack 1.5 `stinterp`, `stinemanSlopes`, `parabolaSlopes`), `evd.py` (evd 2.3-7.1 `fpot`, `src/pot.c`), `solnp.py` (Rsolnp 1.16 `solnp`, `gosolnp`), `truncnorm.py` (truncnorm 1.0-9 `rtruncnorm`), `rugarch.py` (rugarch 1.5-6 `ugarchfit` sGARCH/gjrGARCH, `src/filters.c`, `garchmodels.c`, numDeriv) |

`RcppExports.R` und `RcppExports.cpp` haben kein Gegenstück. Ein
Python-Modul je R-Datei; C++-Kerne stehen in `simlev/_<name>_core.py`.
Öffentliche Funktionen stehen in `__all__` des Moduls und werden in
`simlev/__init__.py` exportiert. `bootstrap`, `backcast`, `deep_analysis`
und `param_search` sind dort zugleich Modul und aufrufbare Funktion
(`_callable_module`).

## Referenzfälle und Prüfung

Die Engine prüfen die Golden-Fälle in `golden/cases/` und `golden/extra/`
(`tools/compare_golden.py`, `tests/test_golden_master.py`; siehe
[PORTING_ENGINE.md](PORTING_ENGINE.md)). Alle übrigen Funktionen und die
R-Interna prüfen Referenzfälle unter `golden/modules/<modul>/`.

- Je Modul gibt es einen Generator `golden/modules/gen_<modul>.R`, der
  `golden/modules/ref_tools.R` lädt. Aufruf aus der Repo-Wurzel:

  ``` bash
  LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev 0.5.0> Rscript golden/modules/gen_<modul>.R
  ```

  `ref_init()` leert den Zielordner, jeder `ref_case()` schreibt
  `golden/modules/<modul>/<id>.json.gz` mit Eingaben, R-Code, Python-Code,
  Julia-Code (Feld `jl`, für die Julia-Fassung), Ergebnis,
  Konsolenausgabe, Druckausgabe, Warnungen bzw. Fehlermeldung (Format in
  `golden/README.md`). Beispiel:

  ``` r
  source("golden/modules/ref_tools.R"); ref_init("signals")
  set.seed(1); px <- 100 * cumprod(1 + rnorm(300, 0, 0.01))
  ref_case("sma1", r = "signal_sma(px, 20)",
           py = "result = simlev.signal_sma(px, 20)",
           jl = "result = signal_sma(px, 20)", inputs = list(px = px))
  ref_done()
  ```

- Fälle decken typische Aufrufe, alle Argumentvarianten und die Randfälle
  aus `r/tests/testthat` ab, auch Fehler- und Warnpfade. Zufallsabhängige
  Fälle setzen den Startwert in allen Codes (`set.seed(5)` ↔
  `simlev.set_seed(5)` ↔ `set_seed(5)` in Julia).
- Dateien klein halten (Eingaben höchstens etwa 2.000 Zeilen, nur so viele
  Pfade wie nötig).
- Prüfen:

  ``` bash
  python python/tools/compare_reference.py [modul ...] [-k id] [-v]
  pytest python/tests/test_module_reference.py -k <modul>
  ```

  `simlev._r.reftree` lädt einen Fall, führt den Python-Code aus und
  vergleicht Ergebnis, Ausgaben, Warnungen und Fehlermeldung bitgenau.

Nach jeder Änderung an der Rechenlogik laufen `compare_golden.py`,
`compare_reference.py` und die ganze Test-Suite; alle Fälle müssen
bitgleich bleiben. Neue oder geänderte Fälle prüft zusätzlich die
Julia-Fassung (`julia/tools/compare_reference.jl`, siehe
[`julia/DEVELOPING.md`](../julia/DEVELOPING.md)).

## Codestil

- Deutsch in Docstrings und Meldungen wie im R-Paket; Docstrings mit
  kurzer Beschreibung und Argumentliste (aus `r/man/*.Rd` übernommen).
- Keine neuen Pflichtabhängigkeiten außer numpy und pandas; matplotlib und
  plotly bleiben optional, scipy dient nur als Ersatzweg für
  Eigenvektoren ohne System-LAPACK.
