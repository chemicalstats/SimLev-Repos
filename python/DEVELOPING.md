# Entwicklernotiz: Python-Fassung von SimLev

Diese Notiz gilt für alle Änderungen an `python/simlev/`. Die Rechenkerne
liegen als gemeinsamer C/C++-Code in `core/` und rechnen in R, Python und
Julia dieselben Zahlen; Python bildet die Schnittstelle darum (Eingabeprüfung,
Datenaufbereitung, Ablauf, Ergebnisobjekte, Druck, Grafik). Die Notiz
beschreibt die Konventionen, mit denen dieser Python-Teil bitgleich zu den
Gegenstücken in R und Julia bleibt, das Prüfwerkzeug und die Zuordnung der
R-Dateien zu den Python-Modulen. Die
Zuordnung aller öffentlichen Funktionen zu Dateien in R, Python und Julia
steht in [`STRUKTUR.md`](../STRUKTUR.md).
Was speziell die Engine (`simulation()`) betrifft, steht im Abschnitt
[Engine](#engine-simulation).

> **Stand:** Zufall und Numerik rechnet die eigene C-Bibliothek slc, die Engine von
> `simulation()` der gemeinsame C++-Kern (Abschnitte [C-Erweiterung](#c-erweiterung),
> [Zufall](#zufall) und [Tests](#tests)). `simlev/_r/` bildet nur noch Grundfunktionen von R
> nach (Liste und Herkunft in [`COPYRIGHTS.md`](COPYRIGHTS.md)); Nachbildungen von R's Zufall,
> nmath, BLAS/LAPACK/LINPACK, `optim`/`nlminb` und der früher übernommenen Pakete gibt es nicht
> mehr, ebenso keine reinen Python-Kerne.

## Bauen, Abgleich der C-Quellen und Tests

Aus der Repo-Wurzel, immer mit `LC_ALL=C.UTF-8`:

``` bash
python3 core/sync.py --check          # Kopien der C-Quellen in r/src, python/src/core, julia/deps/core prüfen
python3 core/sync.py --write          # nach einer Änderung in core/ verteilen
(cd python && python3 setup.py build_ext --inplace --force)   # C-Erweiterung im Klon bauen
PYTHONPATH=python python3 -m pytest tests                     # Tests (Gruppen gleichlauf, fehler, ausgabe, schnittstelle)
tests/werkzeuge/gleichlauf/run.py --quick                       # Gleichlauf mit R und Julia
tests/werkzeuge/doku/beispiele.py python                        # Beispiele der READMEs und des Tutorials
```

Die C-Quellen werden nur in `core/` geändert (Regeln in [`core/README.md`](../core/README.md)).
Die Tests liegen im Ordner `tests/` des Repositorys, nach Zweck gegliedert, und gehören nicht
zum Paket; Katalog und Befehle stehen in [`tests/README.md`](../tests/README.md). Sie sollen
künftig nur lokal liegen (dort Abschnitt „Lokal aufbewahren“); Bauen, `pip install` und
`pip wheel` laufen ohne sie.

## Voraussetzungen

- Für die Rechenkerne gilt `core/` (Regeln in `core/README.md`). Verhalten und Meldungen der
  Schnittstelle sind in allen drei Sprachen gleich; als Vergleich dienen die Gegenstücke in
  `r/R/*.R` und `julia/src/`, die Hilfe (`r/man/*.Rd`, Docstrings) und die Referenzfälle. Für die nachgebauten
  R-Grundfunktionen in `simlev/_r/` sind es die Quellen von R 4.3.3 (`src/main`, `src/nmath`
  nur `fround.c`/`fprec.c`, `src/library/stats`, `src/library/base`; Liste in
  [`COPYRIGHTS.md`](COPYRIGHTS.md)).
- Referenzfälle erzeugt R 4.3.3 mit dem installierten R-Paket SimLev
  und `jsonlite`; kein Generator braucht ein weiteres Paket. Die Module
  `gen_evd.R`, `gen_imputets.R`, `gen_rugarch.R`, `gen_r_nmath.R`, `gen_r_rng.R`,
  `gen_r_linalg.R` und `gen_r_nlminb.R` prüfen entfallene Nachbildungen und sind aus dem
  Gleichlauf ausgenommen. MS-GARCH, GARCH, GPD, DCC und die Bootstrap-Kerne
  rechnet die C-Bibliothek (`simlev._lib_models`).
- Bitgleichheit setzt Linux x86-64 (80-Bit-`long double`), glibc-libm und denselben Compiler
  mit denselben Flags für die C-Bibliothek voraus (seit 1.0.0 keine System-LAPACK mehr).
- Immer mit `LC_ALL=C.UTF-8` arbeiten; unter dem C-Locale schlagen die
  Vergleiche der Druckausgabe wegen der Umlaute fehl.

## Ziel

Jede exportierte R-Funktion hat ein Python-Gegenstück mit gleichem Namen
(Punkte im R-Namen werden zu `_`), gleichen Argumentnamen und gleichen
Voreinstellungen. Ergebnisse sind **bitgleich** (IEEE-754-Doubles
identisch), Druckausgaben (`print`) zeichengleich, Fehlermeldungen und
Warnungen wortgleich (deutsch). Argumente, die in Python Schlüsselwörter
sind, heißen `yield_`, `raise_` und `from_`. Nicht-Pflichtargumente öffentlicher Funktionen
gehen nur als Schlüsselwort (`*` in der Signatur, seit
0.9.0); Pflichtargumente bleiben positionell, auch wenn sie in R nach
optionalen Argumenten stehen (`bootstrap_study(data, config, method, n,
strategies, *, …)`, `param_search(data, builder, space, *, …)`,
`tactical_glidepath(data, from_, to, *, …)`).

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
- `NULL` → `None`, numerisches `NA` → `simlev.NA` (NaN mit R's Nutzlast
  1954), sonst `None`. Definiert ist es einmal als `simlev._r.rnum.NA_REAL`;
  `simlev._r.fmt.NA_REAL` und die übrigen Module importieren es von dort.
  R's `NaN` ist ein gewöhnliches `nan` (`math.nan`, `np.nan`). Wo R
  `NA_real_` setzt, `NA_REAL` setzen; Arithmetik erhält die Nutzlast wie in
  R. Erkennen mit `_r.rnum.r_isna`/`r_isna_arr` (wie `R_IsNA`).
  numpy-Funktionen, die NaN neu erzeugen (`np.full(n, np.nan)`, `reindex`,
  `shift`, `np.nanmean`), nicht für R-NA verwenden. `NA_REAL` ist
  signalisierend; öffentliche Funktionen eines Moduls laufen deshalb unter
  `quiet_fp` (`simlev/_r/base.py`, am Modulende `quiet_fp(globals(),
  __all__ + [...])`), das numpys „invalid value“-Warnungen unterdrückt.
- Funktionsargumente akzeptieren dieselben Formen (`Series`, `dict`,
  Array, `DataFrame`).
- Bedingungen, die R als Ausdruck erhält (`tactical_rules()`,
  `bootstrap_probability()`, `regime_subset()`, `view_prob()`), sind in
  Python Text in R-Syntax und werden wie in Julia mit `simlev._r.rexpr`
  ausgewertet (R-Vorrang, NA-Logik, `%in%`, `!`, Indizierung, if/else;
  freie Variablen aus `env`, sonst aus dem Namensraum des Aufrufers).
  Python-Funktionen sind als Bedingung ebenfalls erlaubt. Funktionen mit
  `env = parent.frame()` in R tragen den Dekorator `env_from_caller`
  (`simlev/_r/base.py`); `quiet_fp` setzt dann bei fehlendem `env` den
  Namensraum des Aufrufers ein, die Funktion selbst liest keinen Frame.
- Meldungen: `stop()` → `ValueError`, `warning()` → `warnings.warn`
  (`UserWarning`), `message()` → `sys.stderr`; `cat()` und `print()` gehen
  nach `stdout`.

## Regeln für Bitgleichheit

1. Rechenreihenfolge 1:1 aus R/C++ übernehmen; keine Umformungen, auch
   keine mathematisch gleichwertigen.
2. R akkumuliert `sum`, `mean`, `cumsum`, `prod`, `rowSums`, `colSums`,
   `var`/`cov` in 80-Bit-`long double`. Dafür gibt es die C-Kerne
   `core/slc_rbase*.cpp` hinter `simlev._r.rnum` bzw. `simlev._r.base` (`r_sum`,
   `r_mean`, `r_colmeans`, …; seit 1.3.0 kein `numpy.longdouble` mehr); `np.sum`
   und `np.cumsum` ergeben andere Bits. `cumprod` nutzt in R `LDOUBLE`,
   `cummax`/`cummin` nicht.
3. **Keine numpy-Transzendentalfunktionen** (`np.exp`, `np.log`,
   `np.log1p`, `np.expm1`, `np.power`, `np.tanh`, `np.arctanh`, …). Auf
   Rechnern mit AVX-512 weichen sie von glibc-libm ab; R nutzt libm.
   Stattdessen `simlev._r.libm` (`exp`, `log`, `log1p`, `expm1`, `pow`,
   `tanh`, … elementweise über `math`). `+ - * / sqrt abs floor` von numpy
   sind exakt gerundet. `x^2` ist in R `x*x`, `x^y` sonst libm-`pow` (siehe
   `_r.rnum.r_pow`, vektoriell `r_pow_vec`, `r_exp_vec`).
4. Zufallszahlen ausschließlich über `simlev._lib` (Zustand von SimLev bzw. ein `Stream`, siehe
   [Zufall](#zufall)); die Reihenfolge der Ziehungen muss exakt der in R entsprechen.
5. R-Grundfunktionen (`quantile`, `median`, `cor`, `optimize`, `hclust`, `approx`,
   `filter`, `p.adjust`, …) kommen aus `simlev._r.stats`, Formatierung (`format`, `formatC`,
   `round`, `signif`, `prettyNum`, `print` von Vektoren, Matrizen und data.frames) aus
   `simlev._r.fmt`. Fehlt dort etwas, wird es dort ergänzt (mit Gleichlauf-Fällen und einem
   Eintrag in `COPYRIGHTS.md`), nicht im aufrufenden Modul nachgebaut.
6. Lineare Algebra (`%*%`, `crossprod`, `solve`, `chol`, `eigen`, `qr`, kleinste Quadrate),
   Verteilungen (`qnorm`, `pt`, `qt`, `lgamma`, …), Optimierer und Modelle kommen aus der
   C-Bibliothek slc (`simlev._lib`, `_lib_linalg`, `_lib_opt`, `_lib_models`; in R `.sl_*`).
   Ein neues Verfahren gehört nach `core/` (nach Veröffentlichungen, Quellen im Dateikopf und im
   [`LITERATUR.md`](../LITERATUR.md)), nicht in ein Python-Modul.
7. Nichts erfinden: Maßgeblich sind R-Code und R-Ergebnis. Bei Unklarheit
   in R nachrechnen.
8. Grafiken (SVG über `simlev/svg.py`, wie in Julia) müssen nicht bitgleich
   sein, aber dasselbe zeigen; die berechneten Daten dahinter und
   `SimLevPlot.data` sind bitgleich.
9. Zeichenketten sortieren und vergleichen nur über `simlev._r.stats`
   (`order`, `sort`, `rank`, `str_collate`; ICU-Kollation wie R), nie über
   `sorted`, `np.sort`, `np.unique` oder `pd.Categorical` mit Standardordnung.
10. Bedingungen als Text nur über `simlev._r.rexpr.eval_r` (R-Syntax).
11. Keine Funktionen aus fremden Paketen: SimLev übernimmt keinen Code und ruft keine Pakete
    außer numpy und pandas; andere Pakete dienen höchstens als Prüforakel bei der Entwicklung.

## Gemeinsam genutzte Helfer

Die internen R-Helfer (`.name`) heißen in Python `_name` und stehen im
Modul der R-Datei, aus der sie stammen, mit derselben Signatur:

| Helfer | Modul |
|---|---|
| `_to_date`, `_add_months`, `series_align`, `_num_text_cols`, `_num_text_stop`, `_cpi_level` | `data_prep.py` |
| `_fill_na`, `_resolve_series` | `backcast.py` |
| `_roll_mean`, `_roll_var`, `_roll_cov` | `signals.py` |
| `_extract_returns`, `_pw_block`, `_fit_garch11`, `_wquantile` | `bootstrap.py` |
| `_par_lapply` (= `par_lapply`; `bootstrap._par_lapply` leitet weiter) | `_r/parallel.py` |
| `_hmm_em`, `_hmm_init_rank`, `_hmm_init_cl`, `_hmm_viterbi` | `regimes.py` |
| `_ms_garch_fit`, `_ms_garch_check`, `_ms_garch_stat` | `ms_garch.py` |
| `result_index`, `_wd_ppy`, `_anniv_ends` | `withdrawal.py` |
| `_dep_sort_dates`, `_dep_check_prices`, `_dep_returns`, `_kendall` | `dependence.py` |
| `_as_weights`, `_period_last`, `_hold_rows` | `tactical.py` |
| `_of_returns`, `_as_spec`, `_ps_neighbours`, `param_plateau` | `overfitting.py`, `param_search.py` |
| `_da_series`, `_da_deflate` | `deep_analysis.py` |
| `simulation`, `_xirr_rate`, `calculate_dates_flags` | `engine.py` (`simulation`; die übrigen stehen in `_sim_base.py` und sind über `engine` erreichbar) |
| `_strategy_columns`, `_strategy_wrappers`, `_wrapper_assets_text` (R `wrapper.R`) | `config.py` (Schicht 1, weil `strategy_validate` sie braucht; `wrapper.py` holt sie von dort) |
| `_wrapper_nav_calc` (R `.wrapper_nav_calc`), `_nav_raw` (Tage und Anteilswerte ohne Kopie der `attrs`) | `wrapper.py` |

`.par_lapply(X, FUN, cores)` wird zu
`simlev._r.parallel.par_lapply(X, FUN, cores)` und rechnet wie R mit Fork
(siehe [Parallelität](#parallelität-cores)).

## Parallelität (`cores`)

`par_lapply` in `simlev/_r/parallel.py` ist die einzige Stelle, die parallel
rechnet; `bootstrap`, `bootstrap_study`, `param_search` (auch über
`overfit_walk_forward`/`param_bootstrap`), `sensitivity_grid`,
`sensitivity_rebalancing`, `planning_lumpsum_vs_dca` und `sensitivity_leverage` rufen
sie auf. Sie bildet `parallel::mclapply(mc.preschedule = FALSE, mc.set.seed =
FALSE)` nach (Verhalten in R 4.3.3). R bündelt die
Einheiten seit 0.9.1 in höchstens `4 × cores` Pakete (ein Fork je Paket)
mit denselben Ergebnissen, demselben Zufallszustand und denselben Fehlern;
innerhalb eines Pakets erscheinen Ausgaben dort in Einheitenreihenfolge.

- `cores` wird wie in `mclapply` ganzzahlig abgeschnitten; unter zwei Kernen
  oder mit höchstens einem Element ist es `lapply`.
- Jede Einheit läuft als parallele Einheit (`simlev._lib.in_unit`): Der globale Zufallszustand ist
  darin gesperrt, auch bei `cores = 1`; zufällige Einheiten bekommen ihren Strom als Argument.
  Ergebnisse in Eingangsreihenfolge, gleich für jedes `cores`.
- Kinder über `multiprocessing` mit Kontext `"fork"`, je Kern ein Prozess mit
  dynamischer Zuteilung (wie `mc.preschedule = FALSE`); die Arbeitsfunktion
  liegt vor dem Fork in `_JOB`, an die Kinder gehen nur Indizes, zurück
  gepickelte Ergebnisse. Nicht pickelbare Ergebnisse (etwa mit Closures)
  rechnet der Elternprozess selbst nach, mit demselben Zufallszustand.
- `sys.stdout`/`sys.stderr` eines Kinds werden eingefangen und im
  Elternprozess in Einheitenreihenfolge ausgegeben; Warnungen gehen verloren
  (wie in R); beim ersten Fehler (in Einheitenreihenfolge) erscheinen die
  Ausgaben der Einheiten davor, dann wird der Fehler geworfen (wie bei
  `cores = 1`; R liefert ein `try-error`-Element).
- Ohne Fork (Windows, macOS) rechnet `_sequential` nacheinander mit
  derselben Semantik. Python ≥ 3.12 warnt bei `fork()` mit laufenden
  Threads (BLAS); `par_lapply` unterdrückt diese `DeprecationWarning`.

**Regeln für neue Module (Prozess-Sicherheit):**

1. Parallel nur über `par_lapply`, nie eigene Prozesse, Threads oder Pools.
2. Eine Einheit darf sich nicht auf Änderungen verlassen, die eine andere
   Einheit oder der Elternprozess während der Rechnung macht: Globale Zustände,
   Caches und Closures sind im Kind Kopien; was eine Einheit dort ändert, geht
   verloren (wie im Fork in R; dort sehen es seit dem Bündeln höchstens die
   folgenden Einheiten desselben Pakets). Ergebnisse gehören in den Rückgabewert.
3. Rückgabewerte müssen pickelbar sein, wenn es schnell gehen soll (sonst
   rechnet der Elternprozess die Einheit nach). numpy-, pandas- und
   `RList`-Objekte kommen bitgleich zurück (NA mit Nutzlast 1954, -0).
4. Ausgaben nur über `sys.stdout`/`sys.stderr` (zur Laufzeit nachschlagen,
   nicht beim Import binden), Meldungen über die `_message`-Helfer; direkte
   Schreibzugriffe auf die Dateideskriptoren 1/2 fängt `par_lapply` nicht ein.
5. Zufall in einer Einheit nur über den mitgegebenen `Stream` (`simlev._lib`), nie über den
   globalen Zustand (siehe [Zufall](#zufall)).
6. Eine neue Funktion mit `cores` braucht Referenzfälle mit `cores = 1` und
   `cores = 2` (wie `sg_cores1_rng`/`sg_cores2_rng` in `tests/gleichlauf/faelle/forschung.jsonl.gz`).

## Zuordnung R-Datei → Python-Modul

| R-Quelle | Python |
|---|---|
| `simulation.R`, `utils.R` | `engine.py` (Einstieg `simulation()`, Engine `_simulation_flat()`), `_dates.py` (Numerik aus `_r/rnum.py`) |
| `sim_blocks.R` | `_sim_blocks.py` (Bausteine, Übersetzer `_sim_from_blocks`, `sim_args` und Pfade der Aufrufer: `_sim_args_set`, `_sim_check_names`, `_sim_call`) |
| `sim_base.R` | `_sim_base.py` |
| `sim_validate.R`, `sim_prepare.R` | `_sim_phases.py` |
| `sim_engine.R` | `_sim_engine.py` (Phasen 4 und 5 über den C++-Kern `core/engine_core_impl.h`) |
| `sim_evaluate.R` | `_sim_evaluate.py` |
| `engine_core.cpp` (Kerne `core/engine_core_impl.h`, `prepare_core_impl.h`, `evaluate_core_impl.h`, `tariff_core_impl.h`) | Hülle `src/_ext_engine.cpp` in `simlev._ext`, aufgerufen aus `_sim_engine.py` (siehe [C-Erweiterung](#c-erweiterung)) |
| `asset_config.R`, `strategy.R` | `config.py` |
| `wrapper.R` (Fonds-Wrapper, seit 0.10.0) | `wrapper.py` (`wrapper_config`, `wrapper_nav`, `SimLevWrapperConfig`, `SimLevWrapperNav`; Engine-Schicht, rechnet mit `simulation()`) |
| `compute_rebal_trigger.R` | `trigger.py` |
| `tax_tariff.R`, `inst/extdata/steuertarif.csv` | `_tax_tariff.py`, `data/steuertarif.csv` |
| `print`/`summary` von `SimLevResult` | `result.py` |
| `plot_dashboard.R` | `dashboard.py` (Daten und Panels; R-Farbnamen in `data/r_colors.csv`) |
| Grafik (ohne R-Datei; R zeichnet mit Basisgrafik) | `svg.py` (`SimLevPlot`, plot-API, alle SVG-Zeichenbausteine) |
| `data_prep.R` | `data_prep.py` |
| `backcast.R` | `backcast.py` |
| `bonds.R` | `bonds.py` |
| `signals.R`; `.roll_mean_core`, `.roll_cov_core` aus `research_core.cpp` | `signals.py`, `_signals_core.py` |
| `bootstrap.R` (Kerne `.sl_boot_*` in der C-Bibliothek) | `bootstrap.py` (`simlev._lib_models.boot_*`) |
| `ms_garch.R` (Kern `.sl_ms_garch_fit` in der C-Bibliothek) | `ms_garch.py` (`simlev._lib_models`) |
| `withdrawal.R`, `withdrawal_core.cpp` | `withdrawal.py`, `_withdrawal_core.py` |
| `dependence.R`; `.kendall_tau_core`, `.quantile_reg_core`, `.hmm_forward_backward` aus `research_core.cpp`; DCC in der C-Bibliothek | `dependence.py`, `_dependence_core.py` (Hüllen um `simlev._ext`) |
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
| R-Grundfunktionen (R 4.3.3) | `_r/`: `rnum.py` (unterste Schicht: `NA_REAL`, long-double-Summen, `R_pow`), `rformat.py` (Hülle über `fmt.py` für Runden und `formatReal`; `sprintf` für die Engine), `parallel.py` (`.par_lapply`, siehe [Parallelität](#parallelität-cores)), `stats.py` (Sammelmodul der Themen `stats_sort.py`, `stats_cor.py`, `stats_smooth.py`, `stats_optim.py`, `stats_models.py`, `stats_cluster.py`), `linalg.py` (`outer`, `diag`, `isSymmetric`), `base.py`, `libm.py`, `fmt.py`, `_collate.py`, `rlist.py`, `rexpr.py`, `env.py`; Herkunft in [`COPYRIGHTS.md`](COPYRIGHTS.md) |
| C-Bibliothek slc (`core/slc*.cpp`) | `_lib.py` (Zufall, `simlev_seed`, Verteilungen), `_lib_linalg.py`, `_lib_opt.py`, `_lib_models.py` (Hüllen um `simlev._ext`) |

Die `.Call`-Hüllen (`r/R/cores.R`, `r/src/init.cpp`, `r/src/simlev_capi.h`)
haben kein Gegenstück. Ein
Python-Modul je R-Datei (Ausnahmen: die Engine-Phasen, siehe
[Aufbau der Engine](#aufbau-der-engine), und die stats-Interna, siehe
[stats-Interna](#stats-interna)); C++-Kerne stehen in `simlev/_<name>_core.py`.
Öffentliche Funktionen stehen in `__all__` des Moduls und werden in
`simlev/__init__.py` exportiert. `bootstrap`, `backcast` und
`param_search` sind dort zugleich Modul und aufrufbare Funktion
(`_callable_module`); `result_analysis` steht im Modul `deep_analysis`.

## stats-Interna

`simlev/_r/stats.py` ist das Sammelmodul: Es bietet alle Namen der
Themenmodule wieder an, damit `from simlev._r.stats import …` und
`simlev._r.stats.<name>` (auch `sort_partial`, `_rsum`, `_rmean`, `_warn`)
gültig bleiben. Neue Funktionen kommen in das passende Themenmodul (mit
`__all__` und `quiet_fp` am Modulende) und werden in `stats.py` ergänzt. Die
Julia-Dateien heißen gleich und gehören alle zum Untermodul `RStats`.

| Python (`simlev/_r/`) | Julia (`julia/src/r/`) | Inhalt |
|---|---|---|
| `stats.py` | `stats.jl` | Sammelmodul bzw. Modulkopf `RStats` mit Exporten und `include`s |
| `stats_sort.py` | `stats_sort.jl` | Hilfen, `order`, `sort`, `rank`, `rle`, `tabulate`, `findInterval`, `cut`, `complete_cases`, partielle Sortierung, `quantile`, `median`, `weighted_mean` |
| `stats_cor.py` | `stats_cor.jl` | `cor`, `cov`, `var`, `sd`, `cov2cor`, `scale` (cov.c) |
| `stats_smooth.py` | `stats_smooth.jl` | `approx`, `approxfun`, `filter` (seit 1.0.0 ohne `fft`, `bw_nrd0`, `density`, `smooth_spline`) |
| `stats_optim.py` | `stats_optim.jl` | `optimize` (seit 1.0.0 ohne `optim`, `optimhess`, `nlminb`; seit 1.5.2 ohne `uniroot`) |
| `stats_models.py` | `stats_models.jl` | `coef`, `fitted`, `residuals`, `p_adjust`, `ecdf`, `ave`, `aggregate` (seit 1.0.0 ohne `lm`, `glm`, `poly`, `summary_lm`, `predict`, `t_test`) |
| `stats_cluster.py` | `stats_cluster.jl` | `dist`, `as_dist`, `dist_as_matrix`, `hclust` |

Importrichtung (ohne Kreise): `stats_sort` ← `stats_cor`, `stats_sort` ← `stats_smooth` ←
`stats_models`; `stats_optim` und `stats_cluster` brauchen nur `stats_sort`.

## Engine (`simulation()`)

Dieser Abschnitt gilt für `simulation()` und alles, was daran hängt
(`engine.py`, `_sim_base.py`, `_sim_phases.py`, `_sim_engine.py`,
`_sim_evaluate.py`, `_dates.py`, `config.py`, `trigger.py`,
`result.py`, `_tax_tariff.py`, `_sim_blocks.py`, `wrapper.py`, `dashboard.py`), und für Module, die die
Engine aufrufen oder ihre Helfer verwenden.

**Fonds-Wrapper (`wrapper.py`, seit 0.10.0).** `_sim_check_inputs` rechnet nach der Prüfung der
Datumsspalte je Wrapper-Asset den Anteilswert mit `_wrapper_nav_calc` aus den normalisierten Daten
(ein `_Frame`; `simulation()` nimmt ihn über `_to_frame` als Kopie an) und hängt ihn als Kursspalte an;
`cfg["no_split"]` nimmt die Wrapper von den Splits aus, `cfg["wrappers"]` (nur mit `details`) wird
`result.wrappers`. Die innere Rechnung sichert `_sim_base._FEE` (R `.fee_env`) und stellt ihn auch
nach einem Fehler wieder her; ihre Meldungen gibt ein Strom an Stelle von `sys.stderr` mit Präfix
weiter (je Meldung bis zum Zeilenende), ihre Warnungen werden gesammelt und mit Präfix neu
ausgegeben, Fehler als `ValueError` mit Präfix. `SimLevWrapperNav` ist ein `DataFrame`; jede Auswahl daraus ist ein
gewöhnlicher `pandas.DataFrame` ohne `attrs` (`_constructor = pd.DataFrame`; die `attrs` `inner` und
`wrapper` stehen in einem `_NavAttrs`, das bei der Weitergabe durch pandas, `copy.deepcopy`, ein
leeres `dict` ergibt; R `[.SimLevWrapperNav`). Die Engine liest Tage und Werte über
`_nav_raw`.

### Aufbau der Engine

Die Engine ist wie in R und Julia nach Phasen auf Dateien verteilt:

| Python | R | Julia | Inhalt |
|---|---|---|---|
| `_sim_blocks.py` | `sim_blocks.R` | `sim_blocks.jl` | Bausteine `sim_costs()`, `dca_plan()`, `rebalance_plan()`, `split_rule()`, `tax_profile()`, `income_rate()`, `income_tariff()`, `harvest_rule()`, `funds_costs()` mit Prüfung und Druck; `_sim_from_blocks` übersetzt sie in die flachen Engine-Argumente; `_sim_args_set` setzt `sim_args` und Pfade wie `"dca.value"` der Aufrufer |
| `engine.py` | `simulation.R` | `engine.jl` (Kopf, `include`s), `sim_evaluate.jl` (`simulation`, `_simulation_flat`) | Einstieg `simulation()` (Bausteine) und Engine `_simulation_flat()` (flache Argumente); bietet die öffentlichen Helfer und `_as_date`, `_r_class_name` weiter an |
| `_sim_base.py` | `sim_base.R` | `engine.jl` | Ausgabe- und Datumshilfen, Spaltendaten (`_Frame`), Gebühren, Termine und Flags, Handels- und Steuerfunktionen, Tarifweg, Jahreswechsel, Kennzahlen (`_xirr_rate`, Schiefe, Wölbung) |
| `_sim_phases.py` | `sim_validate.R`, `sim_prepare.R` | `sim_phases.jl` | Phase 1 `_sim_check_inputs`, Phase 2 `_sim_prepare_data`, `_sim_build_state`, `_sim_build_calendar`, `_sim_init_weights`, `_sim_build_schedule` |
| `_sim_engine.py` | `sim_engine.R` | `sim_engine.jl` | Phasen 4 und 5 über den gemeinsamen C++-Kern (`core/engine_core_impl.h`, Vorbereitung `core/prepare_core_impl.h`): Tagesschleife und Abschluss des letzten Jahres in `_sim_engine_run`; die Texte der Warnungen, `details`-Ausgaben und Abbrüche setzt `_sim_engine_signal` |
| `_sim_evaluate.py` | `sim_evaluate.R` | `sim_evaluate.jl` | Phase 6 `_sim_compact_trades`, `_sim_returns`, `_sim_risk_stats`, `_sim_undefined_metrics`, `_sim_result` |

`simulation()` steht in Python in `engine.py` (in Julia in `sim_evaluate.jl`),
weil `engine.py` alle Phasenmodule einbindet und diese ihrerseits
`_sim_base.py` nutzen; so gibt es keine Kreisimporte. Bestehende Importe
`from .engine import …` bleiben gültig.

### Stand

- Die Engine-Fälle (bis 1.4.0 `cases` 55/55 und `extra` 35/35) sind bitgleich (seit 0.10.0 ohne die 15 Fälle des Fondsmodus),
  einschließlich Druckausgabe und `details = TRUE`
  (`python3 tests/werkzeuge/gleichlauf/vergleich.py [Pfade] [-k id] [-v]`).
- Zusätzlich frisch erzeugte Fälle (300 Zufallsfälle, Seed 777 bzw. 999,
  jeweils mit den festen Fällen des Generators): `engine_faelle.R` und
  `engine_stress.R` ergeben 669/669. Die neuen Argumente (order_fee, dca_fee,
  church_tax, harvest_*, taxable_income, tax_tariff) wurden zusätzlich in
  750 Fällen voll verglichen.
- Die R-Tests der Engine sind nach `tests/test_*engine*.py`, `test_tax*.py`,
  `test_simulation.py`, `test_config.py` und `test_dashboard.py` portiert.
- Diese Zahlen beschreiben den Stand vor 1.0.0. Der Gleichlauf
  (`tests/werkzeuge/gleichlauf/run.py --full`) ergab am 27.10.2026 Engine 1.182/1.182 und Module
  4.260/4.260. Seit 1.4.2 prüfen die Szenarien und Tabellen in `tests/` (siehe [Tests](#tests)).

### Abbildung der Engine-Objekte

| R | Python |
|---|---|
| `SimLevResult` (benannte Liste) | `simlev.SimLevResult(RList)`: `res["worth"]` und `res.worth`; Elemente in R-Reihenfolge |
| numerischer Vektor | `numpy.ndarray` (float64) |
| `Date`-Vektor | `numpy.ndarray` `datetime64[D]` |
| benannter Vektor (`buys`, `sells`) | `pandas.Series` mit Assetnamen als Index |
| Liste ohne Klasse (`statistics`, `tax_report`, `report$A`, `next_year`) | `dict` |
| `data.frame` (`undefined_metrics`, `tariff_years`, `open_lots$A$lots`) | `pandas.DataFrame` |
| `NULL` (z. B. `open_lots` ohne Steuern, `order_fee` nicht gesetzt) | `None`; ein Element, das R weglässt, fehlt auch im dict |
| `asset_config`, `strategy`, `SimLevTaxTariff`, `summary.SimLevResult` | `AssetConfig`, `Strategy`, `SimLevTaxTariff`, `SimLevSummary` (alle `RList`; `format()` liefert genau die R-Druckausgabe) |
| `attr(data, "filled")` | `data.attrs["filled"]`: bool-`DataFrame`, eine Spalte je Kursreihe (wie in `series_align`) |

- Python-`int` zählt als R-`double`. `_r_class_name()` in `_sim_base.py` (über `engine` erreichbar)
  liefert für Meldungen den Klassennamen wie `class(x)[1]`.
- `res.trades` gibt es nur in Python (Lots, Verkäufe, Steuer- und
  Gebührenbuchungen je Asset). In R gibt es kein Gegenstück, die
  Golden-Vergleiche lassen es aus.
- `match.arg` mit typografischen Anführungszeichen:
  `config._match_arg(value, choices, argname)`; `pmatch` liegt in
  `config._pmatch`.
- `summary(res)` druckt nicht, sondern gibt `SimLevSummary` zurück.
  `print(res)` bzw. `res.print()` druckt.

### Argumente: angegeben oder nicht

R prüft an mehreren Stellen `missing(arg)`. In der Engine haben solche
Argumente als Standardwert `_Default(wert)`. `_unwrap()` liefert den Wert,
und `given` hält fest, welche Argumente ausdrücklich angegeben wurden.

### R-Numerik der Engine: `simlev/_r/rnum.py`, `simlev/_r/rformat.py`

Die Engine nutzt bewusst `_r.rnum` und `_r.rformat` direkt (nicht die
R-Namen aus `_r.base` bzw. `_r.fmt`). In `rnum.py` stehen die Summen
(`r_sum`, `r_mean` mit Korrekturdurchlauf, `r_mean_int`, `r_cumsum`,
`r_prod`, `r_cumprod`, `r_cummax`, `r_var`, `r_sd`, `r_median`,
`r_rowsums`, `r_colsums`, `r_rowmeans`, `r_colmeans`; alle über die C-Kerne
`core/slc_rbase*.cpp`), `r_pow` und `r_mod1` (`core/slc_rbase_num.cpp`, seit 1.3.0), in
`rformat.py` Runden und Textausgabe (seit 1.5.2 rechnen Runden und `formatReal` die Funktionen
aus `fmt.py`; nur `r_sprintf` ist eine eigene, skalare Fassung):

- Runden: `r_round` (fround.c, R ≥ 4), `r_signif` (fprec.c).
- Formatieren: `r_format(x, digits, nsmall, big_mark, scientific, width)`
  (formatReal, gibt eine Liste zurück), `r_format1`, `r_as_character`
  (15 Stellen, Drop0), `r_deparse`, `r_sprintf(fmt, *args)`. Die letzte
  Funktion unterstützt `%*.*f`; NA, Inf und -Inf werden wie in R als `%s`
  mit `"NA"`, `"Inf"` bzw. `"-Inf"` ausgegeben.

`_dates.py` enthält Tageszahlen ab 1970; R-`strptime` für `"%Y-%m-%d"` (Semantik von get_number)
rechnet der Kern `core/slc_rbase_date.cpp` (`data_prep._strptime_ymd`).

### Öffentliche Engine-Helfer für andere Module

`simulation`, `xirr_rate` / `_xirr_rate`, `calculate_dates_flags`,
`_apply_spread`, `create_strategy`, `asset_config` (sowie `strategy_add_asset`,
`strategy_update_asset`, `strategy_remove_asset`, `strategy_validate`),
`rebalance_trigger` und `tax_tariff`. Dazu kommen die
Dashboard-Daten `dashboard._dashboard_returns(res)` (wie
`.dashboard_returns`).

### Grafik

`plot_dashboard` bzw. `res.plot()` zeichnet wie die Julia-Fassung ohne
Zusatzpaket als SVG und gibt ein `simlev.SimLevPlot` zurück (R: invisible
NULL): Felder `svg`, `data` (`dict[str, DataFrame]`, die dargestellten
Werte je Panel, nicht ausgedünnt und unskaliert), `source` (das
Eingabeobjekt) und `kind` (dessen Klasse). Python und Julia schreiben
dasselbe SVG und dieselben `data`. Gleich wie in R sind Prüfungen,
Meldungen, alle Beschriftungstexte, Monatsrenditen, rollierende Renditen und
Korrelationen sowie die Farben der Vergleichstabelle. Abgeglichen wurde das über einen
`trace()`-Mitschnitt in R. Schriftgrößen und Ränder sind dagegen nur
angenähert. R-Farbnamen stehen in `simlev/data/r_colors.csv`
(`grDevices::colors()`).

Alle Zeichenbausteine stehen im Grafikmodul `simlev/svg.py`, dem
Gegenstück zu `julia/src/svg.jl`: gleiche Gliederung, gleiche Namen
(Julias `name!` heißt in Python `name`). Die Module enthalten nur ihre
Zeichenfunktionen (`_plot_*`, `plot_SimLev*`) mit der Datenaufbereitung
und holen die Bausteine mit `from .svg import …`; `dashboard.py` hat die
Dashboard-Daten und die Panels. Abschnitte von `svg.py`:

1. Grafikobjekt `SimLevPlot`.
2. Einheitliche Grafik-API: `_plot_method`, `_check_svg_file`,
   `_write_svg`, `_warn_unknown_kw`.
3. Gemeinsame Hilfen: `_esc` (Textschutz aller Stile), `r_pretty`,
   Farben (`_col2rgba`, `_svgcol`, `_alpha` …), Datumshilfen
   (`_MONATE_KURZ`, `_ym`, `_days_from_civil`, `_to_days`, `_fmt_day`).
4. bis 9. je ein Grafikstil; ein Präfix je Stil, damit gleichnamige
   Bausteine mit anderem Aussehen nicht verwechselt werden:

| Abschnitt | Präfix | Bausteine (Auswahl) | Grafiken |
|---|---|---|---|
| 4. Stil Dashboard | – | `_Canvas`, `_Panel`, `_text`, `_line`, `_rect`, `_polyline`, `_area`, `_frame`, `_date_ticks`, `_yaxis` | `plot_dashboard`, `plot(<SimLevResult>)` |
| 5. Stil Analysegrafiken | `_ana_` | `_AnaSvg`, `_AnaPanel`, `_ana_panel`, `_ana_lines`, `_ana_hline`, `_ana_rect`, `_ana_text`, `_ana_points`, `_ana_legend`, `_ana_ramp`, `_ana_svg_done`, `_ana_year_ticks` | deep_analysis, analysis_tests (Signal, Heatmap), planning |
| 6. Stil Rastergrafiken | `_grid_` | `_GridBox`, `_grid_svg`, `_grid_axes`, `_grid_lines`, `_grid_bars`, `_grid_scatter`, `_grid_hline`, `_grid_legend`, `_grid_ticks` | dependence (Abhängigkeit, Tail-Regression, CoVaR), regimes |
| 7. Stil Ergebnisgrafiken | `_res_` | `_ResFig`, `_ResPanel`, `_res_fig`, `_res_panel`, `_res_line`, `_res_points`, `_res_rect`, `_res_vline`, `_res_hline`, `_res_abline`, `_res_legend`, `_res_ramp`, `_res_finish` | overfitting (PBO, Walk-Forward), param_search, sensitivity |
| 8. Stil Rückrechnung | `_bc_` | `_bc_doc`, `_bc_panel`, `_bc_esc` (ohne `"`) | backcast |
| 9. Stil Allokationsgrafiken | `_alloc_` | `_alloc_ticks`, `_alloc_c`, `_alloc_ramp` | optimize (Gewichte, Effizienzgrenze), tactical (Zielgewichte) |

10. Zahlen wie in Julia (nur Python): `_jl_str`, `_jl_round`,
    `_jl_round_sig`, `_jl_pow`, `_jl_log10`, `_jl_range`, `_jl_min`/
    `_jl_max`, `_jl_minimum`/`_jl_maximum`, `_jl_fmt`, `_jl_unique`,
    `_jl_sort_levels` …, die Julias Base-Funktionen beim Schreiben der
    Zahlen genau nachbilden.

Die Grafiken von withdrawal und bootstrap entstehen direkt in der
Zeichenfunktion.
Ein neuer Baustein kommt in den Abschnitt seines Stils (mit dessen Präfix)
und zugleich nach `julia/src/svg.jl`.

## Referenzfälle und Prüfung

Die Referenzfälle liegen seit 1.4.1 im Ordner `tests/` des Repositorys (Katalog
[`tests/README.md`](../tests/README.md)); frische Fälle erzeugt und vergleicht die
Gleichlaufprüfung.

Die Engine prüfen die Szenarien und Tabellen in `tests/<gruppe>/faelle/engine.jsonl.gz` (seit 1.4.2; die
Zufallsfälle im Engine-Format nur noch im Gleichlauf, `tests/werkzeuge/zufall`)
(`tests/werkzeuge/gleichlauf/vergleich.py`, `tests/gleichlauf/test_gleichlauf.py`; siehe
[Engine](#engine-simulation)). Alle übrigen Funktionen und die
R-Interna prüfen Referenzfälle unter `tests/<gruppe>/faelle/<bereich>.jsonl.gz`.

- Je Modul gibt es einen Generator `tests/gleichlauf/erzeugen/<bereich>.R`, der
  `tests/gleichlauf/erzeugen/ref_tools.R` lädt. Aufruf aus der Repo-Wurzel:

  ``` bash
  LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript tests/gleichlauf/erzeugen/<bereich>.R
  ```

  `ref_init()` leert den Zielordner, jeder `ref_case()` schreibt
  `tests/<gruppe>/faelle/<bereich>.jsonl.gz` (eine Zeile je Fall) mit Eingaben, R-Code, Python-Code,
  Julia-Code (Feld `jl`, für die Julia-Fassung), Ergebnis,
  Konsolenausgabe, Druckausgabe, Warnungen bzw. Fehlermeldung (Format in
  `tests/README.md`). Beispiel:

  ``` r
  source("tests/gleichlauf/erzeugen/ref_tools.R"); ref_init("signals")
  set.seed(1); px <- 100 * cumprod(1 + rnorm(300, 0, 0.01))
  ref_case("sma1", r = "signal_sma(px, 20)",
           py = "result = simlev.signal_sma(px, 20)",
           jl = "result = signal_sma(px, 20)", inputs = list(px = px))
  ref_done()
  ```

- Fälle decken typische Aufrufe, alle Argumentvarianten und die Randfälle
  aus `tests/run.R` ab, auch Fehler- und Warnpfade. Zufallsabhängige
  Fälle setzen den Startwert in allen Codes (seit 1.0.0 `simlev_seed(5)` ↔
  `simlev.simlev_seed(5)` ↔ `simlev_seed(5)` in Julia, oder `seed = 5` am Aufruf). R's
  `set.seed` dient nur noch zum Erzeugen gespeicherter Eingaben im R-Generator.
- Dateien klein halten (Eingaben höchstens etwa 2.000 Zeilen, nur so viele
  Pfade wie nötig).
- Prüfen:

  ``` bash
  python3 tests/werkzeuge/gleichlauf/vergleich.py [datei.jsonl.gz ...] [-k id] [-v]
  python3 -m pytest tests/gleichlauf/test_gleichlauf.py -k <modul>
  ```

  `tests/lib/reftree.py` lädt einen Fall, führt den Python-Code aus und
  vergleicht Ergebnis, Ausgaben, Warnungen und Fehlermeldung bitgenau.
- Engine: `tests/werkzeuge/gleichlauf/vergleich.py` vergleicht Golden-Fälle (`.json`/`.json.gz`)
  in einem oder mehreren Ordnern. Frische Fälle erzeugen
  `Rscript tests/werkzeuge/zufall/engine_faelle.R <ziel> N SEED` bzw. `engine_stress.R`; das
  Ziel liegt **außerhalb des Repos** (z. B. in einem temporären Ordner),
  danach `tests/werkzeuge/gleichlauf/vergleich.py` aufrufen.

Nach jeder Änderung an der Rechenlogik läuft die Gleichlaufprüfung
(`tests/werkzeuge/gleichlauf/run.py --quick`, vor einer neuen Version `--full`); alle Fälle müssen in Python
und Julia bitgleich zu R sein. Sie vergleicht alle Fälle der Generatoren, die Tests (`tests/` (pytest)) die Auswahl im Katalog.

Was ein Referenzfall bitgleich prüft, steht nicht noch einmal als Test in
`tests/`. Die
Tests in `tests/` prüfen, was kein Fall abdeckt: Eigenschaften und
Handrechnungen auf eigenen Daten, Fehlerklassen, Warnungen, Dateien,
Grafiken und Schalter.

## Eingefrorene Schnittstelle

Die öffentliche Schnittstelle ist in `tests/schnittstelle/frozen/py.json`
festgehalten (seit 0.9.0): je Funktion aus `simlev.__all__` und je Methode
`print`/`summary`/`plot` der Klassen mit `r_class` die Argumente in
Reihenfolge mit Art (`positional_or_keyword`, `keyword_only`, …) und
Standardwert als Text (`repr`), dazu die Namen der exportierten Klassen;
ohne Modul, Datei, Zeile und Datum. `tests/schnittstelle/test_api.py` ruft dafür den
Auszug `tests/schnittstelle/api_py.py --frozen-check` in einem eigenen Prozess
auf und nennt bei Abweichung jede Änderung (Funktion neu oder weg, Argument
neu, weg oder umsortiert, Art oder Standardwert geändert).

Eine gewollte Änderung der Schnittstelle wird bewusst neu festgeschrieben:
Eintrag oben in `tests/schnittstelle/CHANGES.md` (Datum, was sich ändert,
warum), dann aus der Repo-Wurzel `tests/schnittstelle/run.py --freeze`; das
schreibt `frozen/` für alle drei Sprachen neu und bricht ohne neuen Eintrag
ab. Einzelheiten in [`tests/schnittstelle/README.md`](../tests/schnittstelle/README.md).

## Schalter `SIMLEV_*`

Alle Umgebungsschalter liest (und setzt) nur `simlev/_r/env.py`; Paket,
Tests und Werkzeuge holen sie von dort.
Wann gelesen wird, bestimmt die aufrufende Stelle: `tests/lib/reftree.py` und
`tests/werkzeuge/gleichlauf/vergleich.py` beim Laden, `_collate` beim ersten Vergleich (neu
nach `collate_reset()`).

| Schalter | Zweck | Art |
|---|---|---|
| `SIMLEV_COLLATE` | Sortierung: `icu:<Locale>` (`icu:root` wie R unter C.UTF-8) oder `C` (Bytes); ohne Angabe nach `LC_ALL`/`LC_COLLATE`/`LANG` | Nutzer |
| `SIMLEV_ICU` | Pfad zur ICU-Bibliothek (`libicui18n`) | Nutzer |
| `SIMLEV_LAX_NA` | `1`: NA = NaN im Vergleich (`tests/lib/reftree.py`, `tests/lib/faelle.py`) | Prüfung |
| `SIMLEV_STRICT_ZERO` | `0`: −0 = +0 im Vergleich (`tests/lib/reftree.py`) | Prüfung |
| `SIMLEV_FAELLE_DIR` | anderer Ordner der Bereichsdateien für `tests/` (pytest) (seit 1.4.1; `SIMLEV_GOLDEN_DIR` und `SIMLEV_MODULE_DIR` entfallen seit 1.4.2) | Prüfung |

Seit 1.0.0 entfallen `SIMLEV_NO_EXT` (die C-Erweiterung ist Pflicht),
`SIMLEV_LAPACK` und `SIMLEV_R_SYS_TIME`.

`tests/lib/reftree.py` setzt `SIMLEV_COLLATE=icu:root`, falls nicht gesetzt (die
Referenzen entstanden unter C.UTF-8). Die Generatoren in `tests/gleichlauf/erzeugen/`
lesen eigene Schalter (`SIMLEV_R_NMATH_SRC`, `SIMLEV_ALLOW_PARTIAL`, siehe
`tests/README.md`).

## C-Erweiterung

**Pflicht seit 1.0.0.** `simlev._ext` enthält die C-Bibliothek slc (Zufall, Verteilungen,
lineare Algebra, Optimierer, Modelle, Bootstrap-Kerne) und die mit R geteilten Kerne der Engine,
FIFO, Steuer, Research und Entnahme. `setup.py` baut sie mit `optional=False`: Ohne C/C++-Compiler
scheitert die Installation mit der Meldung von setuptools. Reine Python-Kerne als Rückfall gibt es
nicht mehr (`SIMLEV_NO_EXT` entfällt); `_dependence_core.py`, `_optimize_core.py`,
`_signals_core.py` und `_withdrawal_core.py` sind dünne Hüllen, die die Argumente wie R umwandeln
und `simlev._ext` rufen. Julia ruft seit 1.2.0 dieselben Kerne über die C-ABI-Hülle `core/simlev_cabi.cpp` per `ccall` auf
(vorher eigene Ports).

**Ort der Quellen (`core/`):** Kanonisch sind alle C-Quellen in `core/` (nur dort
ändern):

| Dateien in `core/` | Kopien | Hüllen |
|---|---|---|
| `slc*.cpp`, `slc*.h` (C-Bibliothek slc) | `r/src/`, `python/src/core/`, `julia/deps/core/` | R `r/src/slc_r*.cpp` (`.Call`, `R/slc*.R`), Python `src/_ext_slc*.cpp` (`simlev._lib*`), Julia `src/slib*.jl` (`ccall`) |
| `simlev_core.h`, `research_core_impl.h`, `withdrawal_core_impl.h`, `engine_core_impl.h`, `prepare_core_impl.h`, `evaluate_core_impl.h`, `tariff_core_impl.h`, seit 1.5.1 `wrapper_core_impl.h` (geteilte Kerne) | `r/src/`, `python/src/core/`, `julia/deps/core/` (dort mit der C-ABI-Hülle `simlev_cabi.cpp`) | R `r/src/<kern>.cpp` (`.Call`, `R/cores.R`), Python `src/_ext_research.cpp`, `_ext_withdrawal.cpp`, `_ext_engine.cpp` |

`core/sync.py --write` kopiert (nur geänderte Dateien) und entfernt veraltete Kopien;
`--check` vergleicht alle Kopien per SHA-256 (Ende 1 bei Abweichung) und läuft in jeder
Gleichlaufprüfung.
Die Python-Hüllen binden die Kopien als `#include "core/<datei>"` ein. Beim Verschieben nach
`core/` (1.0.0) blieb der Maschinencode der R-Kerne gleich (Vergleich der Objektdateien Funktion
für Funktion). `garch_filter` (seit 1.0.0 ohne Aufrufer) ist aus `research_core_impl.h` und den
Hüllen entfernt; die Ergebnisse der übrigen Research-Kerne blieben bitgleich.

- **Aufbau der geteilten Kerne:** wie seit 0.9.1: Rechnung in `<datei>_impl.h` ohne R- und
  Python-Header, Host über `simlev_host::NumVec`, `IntVec`, `NumMat` (Engine: `Obj` und die
  Zugriffe) und die Makros `SIMLEV_*` (`simlev_core.h`); R-Host `r/src/simlev_capi.h`,
  Python-Host `src/_ext_common.h` bzw. `_ext_engine.cpp`. Fehler: `SIMLEV_FAIL` → R `stop()`,
  Python `ValueError` (die Hülle setzt es in `WdError`, `QuantileRegError` um).
- **Hüllen:** nehmen Felder über das Buffer-Protokoll (numpy `float64`/`int32`, zusammenhängend),
  prüfen Typ, Länge und Beschreibbarkeit und melden unpassende Eingaben als `ValueError`
  (früher rechnete dann der reine Python-Kern).
- **Bau:** im Klon `rm -rf build && python3 setup.py build_ext --inplace` (legt `simlev/_ext*.so`
  ab), sonst `pip install .`. Gleitkomma wie R: `-O2 -fno-fast-math -ffp-contract=off`, C++
  `-std=gnu++17`, slc `-std=c99`, dazu `-fstrict-overflow`, sofern der Compiler es kennt; MSVC
  `/O2 /fp:precise`. Jede Kerndatei bricht bei `-ffast-math` ab.
- **NaN-Nutzlast:** Treffen zwei NaN verschiedener Nutzlast aufeinander, wählt der Compiler die
  Operandenfolge; die Hüllen markieren ihre Prüfungen als unwahrscheinlich (`EXT_FAIL_IF`), damit
  der Kern wie in R übersetzt wird. Die früheren Nachbildungen der Operandenfolge in den reinen
  Python-Kernen (`n_add` usw.) sind mit ihnen entfallen.
- **Neuen Kern hinzufügen:** Rechnung in `core/` (slc: Regeln in `core/README.md`; geteilter
  C++-Kern: `core/<datei>_impl.h` mit Host-Namen), `core/sync.py --write`, R-Hülle und
  Registrierung in `r/src/init.cpp`, Python-Hülle `src/_ext_<kern>.c(pp)` mit Methodentabelle (in
  `_ext_common.h` deklarieren, in `_ext.cpp` eintragen, in `setup.py` aufnehmen), Julia-Hülle per
  `ccall` (slc) bzw. eigener Port; Referenzfälle in `tests/gleichlauf/erzeugen/slc.R`.
- **Schichten:** `_ext` gehört zu Schicht 0.

## Zufall

Alle Ziehungen rechnet die C-Bibliothek (xoshiro256**, SplitMix64-Seeding, Ströme über Sprünge um
2^128); `simlev._lib` hält den globalen Zustand G (prozessweit, mit Sperre). Die
Regeln sind in R, Python und Julia gleich, damit die Ergebnisse bitgleich sind:

1. `simlev_seed(seed)` setzt G reproduzierbar (ganze Zahl, |seed| < 2^53); `simlev_seed()` und das
   Laden des Pakets setzen G aus Uhrzeit, Prozessnummer und Zähler.
2. `seed=None` an einer zufälligen Funktion zieht **genau einmal** k = `next_seed()` aus G und
   rechnet dann wie mit `seed=k` (`bootstrap`/`bootstrap_study` legen k unter `seed` ab).
3. `seed=s` lässt G unberührt; der Hauptstrom ist `Stream(s)` (`main_stream`), alle Ziehungen im
   Hauptprozess folgen der Reihenfolge des R-Codes Zeile für Zeile.
4. Funktionen mit `cores` geben Einheit i den Strom U_i = J^i(S_0) (`streams`, vor der Verteilung);
   das Ergebnis hängt nicht von `cores` oder `chunk_size` ab. In einer Einheit ist G gesperrt
   (`in_unit`, Fehler „interner Fehler: globaler Zufallszustand in paralleler Einheit“).
5. R's `set.seed`/`.Random.seed` wirken nicht; die Nachbildung von R's Zufall (`simlev._r.rng`,
   Exporte `set_seed`/`rng_kind`) und ihre C-Fassung `src/_rng_r.c` sind mit 1.0.0 entfallen.

## Tests

Die Tests stehen in `tests/` (siehe [Bauen, Abgleich der C-Quellen und
Tests](#bauen-abgleich-der-c-quellen-und-tests)): Python prüft die Gruppen `gleichlauf`, `fehler`,
`ausgabe` und `schnittstelle` mit `python3 -m pytest tests` bzw. `tests/<gruppe>` gegen die
Referenzfälle aus R. Dazu kommt die **Gleichlaufprüfung** `tests/werkzeuge/gleichlauf/run.py
[--quick | --full]`: Sie baut R, Python und Julia, prüft `core/sync.py --check`, erzeugt die
Referenzfälle mit dem aktuellen R neu und vergleicht Python und Julia streng dagegen.
Ausgenommen sind die Module, die entfallene R-Nachbildungen prüfen (`r_nmath`, `r_rng`,
`r_linalg`, `r_nlminb`, `rugarch`, `evd`, `imputets`) und in `r_stats` die Fälle der entfallenen
Funktionen.

## Schichten und Laden

Die Module gehören zu fünf Schichten:
0 R-Interna (`simlev/_r/`), 1 Daten und Strategie (`config`, `data_prep`,
`backcast`, `bonds`, `signals`, `trigger`, `_tax_tariff`, `_dates`),
2 Engine (`engine`, `_sim_*` einschließlich `_sim_blocks`, `_core`, `result`), 3 Analysen (je ein Modul
mit seinem Kern), 4 Ausgabe (`svg`, `dashboard`). Kein Modul importiert eine höhere Schicht;
Ausnahmen sind vor allem die plot-Methoden der Analysen, die die
Grafikbausteine aus `svg` holen.

`import simlev` lädt die Analysemodule nicht: `__init__.py` nennt ihre
Namen in `_LAZY` und lädt ein Modul beim ersten Zugriff auf einen seiner
Namen (PEP 562, `__getattr__`/`__dir__`). `from simlev import X`,
`simlev.X`, `dir(simlev)` und `__all__` wirken wie zuvor. Ein neuer
öffentlicher Name eines Analysemoduls kommt in `_LAZY` und `__all__`;
`bootstrap` und `param_search` machen sich am Dateiende
selbst aufrufbar (`_make_callable`).

## Codestil

- Deutsch in Docstrings und Meldungen wie im R-Paket; Docstrings mit
  kurzer Beschreibung und Argumentliste (aus `r/man/*.Rd` übernommen).
- Keine Abhängigkeiten außer numpy und pandas (auch nicht für Grafiken). Die C-Erweiterung ist
  Pflicht und braucht zum Bau nur einen C/C++-Compiler (C99, C++17) und die Python-Header (keine
  numpy-Header).
