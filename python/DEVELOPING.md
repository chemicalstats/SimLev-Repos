# Entwicklernotiz: Python-Fassung von SimLev

Diese Notiz gilt für alle Änderungen an `python/simlev/`. Sie beschreibt die
Konventionen der bitgleichen Portierung des R-Pakets SimLev 0.5.0, das
Referenzwerkzeug und die Zuordnung der R-Dateien zu den Python-Modulen.
Was speziell die Engine (`simulation()`) betrifft, steht im Abschnitt
[Engine](#engine-simulation).

## Voraussetzungen

- Maßgeblich sind die Quellen des R-Pakets: `r/R/*.R`, `r/src/*.cpp`,
  `r/man/*.Rd`, `r/tests/testthat/` und `r/NEWS.md`. Für die nachgebauten
  R-Interna in `simlev/_r/` sind es die Quellen von R 4.3.3
  (`src/main`, `src/nmath`, `src/appl`, `src/library/stats`,
  `src/library/base`, `src/modules/lapack`, `src/extra/blas`).
- Referenzfälle erzeugt R 4.3.3 mit dem installierten R-Paket SimLev 0.5.0
  und `jsonlite`; alle Generatoren laufen **ohne** die optionalen Pakete. evd,
  imputeTS, stinepack, rugarch, Rsolnp, numDeriv und truncnorm braucht kein
  Generator mehr: R hat `fpot` (`.evd_fpot`),
  `na_interpolation`/`na_locf`/`stinterp` (`.imputets_na_interpolation`,
  `.stinepack_stinterp`) bzw. `ugarchfit` mit `solnp`/`gosolnp`,
  `rtruncnorm` (`.rugarch_ugarchfit`, `.rsolnp_solnp`, `.rsolnp_gosolnp`,
  `.truncnorm_rtruncnorm`) übernommen und `hessian`/`jacobian` eigenständig
  geschrieben (`.sl_richardson_hessian`, `.sl_richardson_jacobian`), `gen_evd.R`, `gen_imputets.R` und
  `gen_rugarch.R` prüfen diese Fassungen. MSGARCH braucht SimLev nicht mehr:
  Das MS-GARCH-Modell schätzt R selbst (`r/R/ms_garch.R`, Kern
  `r/src/ms_garch_impl.c` mit `.Call`-Hülle `r/src/ms_garch.c`), Python bildet
  das in `simlev/ms_garch.py` und `_bootstrap_core.ms_garch_filter` nach; den
  Filterkern nutzt Python wie alle nativen Kerne ohne Zufallszahlen als
  C-Erweiterung mit (siehe [C-Erweiterung](#c-erweiterung)).
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
sind, heißen `yield_`, `raise_` und `from_`. Nicht-Pflichtargumente öffentlicher Funktionen
gehen nur als Schlüsselwort (`*` in der Signatur, Anhang A Regel 5, Etappe
6.5); Pflichtargumente bleiben positionell, auch wenn sie in R nach
optionalen Argumenten stehen (`bootstrap_study(data, config, method, n,
strategies, *, …)`, `param_search(data, builder, space, *, …)`,
`tactical_glidepath(data, from_, to, *, …)`). Ausgenommen sind die
Nachbildungen von R-Basisfunktionen ohne R-Export (`set_seed`, `rng_kind`).

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
   `var`/`cov` in 80-Bit-`long double` (`numpy.longdouble`). Dafür gibt es
   `simlev._r.rnum` bzw. `simlev._r.base` (`r_sum`, `r_mean`, …); `np.sum`
   und `np.cumsum` ergeben andere Bits. `cumprod` nutzt in R `LDOUBLE`,
   `cummax`/`cummin` nicht.
3. **Keine numpy-Transzendentalfunktionen** (`np.exp`, `np.log`,
   `np.log1p`, `np.expm1`, `np.power`, `np.tanh`, `np.arctanh`, …). Auf
   Rechnern mit AVX-512 weichen sie von glibc-libm ab; R nutzt libm.
   Stattdessen `simlev._r.libm` (`exp`, `log`, `log1p`, `expm1`, `pow`,
   `tanh`, … elementweise über `math`). `+ - * / sqrt abs floor` von numpy
   sind exakt gerundet. `x^2` ist in R `x*x`, `x^y` sonst libm-`pow` (siehe
   `_r.rnum.r_pow`, vektoriell `r_pow_vec`, `r_exp_vec`).
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
8. Grafiken (SVG über `simlev/svg.py`, wie in Julia) müssen nicht bitgleich
   sein, aber dasselbe zeigen; die berechneten Daten dahinter und
   `SimLevPlot.data` sind bitgleich.
9. Zeichenketten sortieren und vergleichen nur über `simlev._r.stats`
   (`order`, `sort`, `rank`, `str_collate`; ICU-Kollation wie R), nie über
   `sorted`, `np.sort`, `np.unique` oder `pd.Categorical` mit Standardordnung.
10. Bedingungen als Text nur über `simlev._r.rexpr.eval_r` (R-Syntax).
11. Optionale R-Pakete fragt R nicht mehr ab (kein `requireNamespace`):
    evd, imputeTS und rugarch sind übernommen, ihr Weg gilt immer; MSGARCH
    ist durch die eigene Schätzung (`r/R/ms_garch.R`) ersetzt. Einen
    Schalter für optionale Pakete gibt es nicht. `Sys.time()` →
    `simlev._r.base.sys_time()` (Prüfschalter `SIMLEV_R_SYS_TIME`).

## Gemeinsam genutzte Helfer

Die internen R-Helfer (`.name`) heißen in Python `_name` und stehen im
Modul der R-Datei, aus der sie stammen, mit derselben Signatur:

| Helfer | Modul |
|---|---|
| `_to_date`, `_add_months`, `series_align`, `_num_text_cols`, `_num_text_stop`, `_cpi_level` | `data_prep.py` |
| `_fill_na`, `_resolve_series` | `backcast.py` |
| `_roll_mean`, `_roll_var`, `_roll_cov` | `signals.py` |
| `_with_rng_restore`, `_extract_returns`, `_pw_block`, `_fit_garch11`, `_wquantile` | `bootstrap.py` |
| `_par_lapply` (= `par_lapply`; `bootstrap._par_lapply` leitet weiter) | `_r/parallel.py` |
| `_hmm_em`, `_hmm_init_rank`, `_hmm_init_cl`, `_hmm_viterbi` | `regimes.py` |
| `_ms_garch_fit`, `_ms_garch_check`, `_ms_garch_stat` | `ms_garch.py` |
| `result_index`, `_wd_ppy`, `_anniv_ends` | `withdrawal.py` |
| `_dep_sort_dates`, `_dep_check_prices`, `_dep_returns`, `_kendall` | `dependence.py` |
| `_as_weights`, `_period_last`, `_hold_rows` | `tactical.py` |
| `_of_returns`, `_as_spec`, `_ps_neighbours`, `param_plateau` | `overfitting.py`, `param_search.py` |
| `_da_series`, `_da_deflate` | `deep_analysis.py` |
| `simulation`, `_xirr_rate`, `calculate_skewness`, `calculate_kurtosis`, `calculate_dates_flags` | `engine.py` (`simulation`; die übrigen stehen in `_sim_base.py` und sind über `engine` erreichbar) |

`.with_rng_restore(expr, seed)` wird zu `_with_rng_restore(fn,
seed=_MISSING)`: ruft `fn()` auf; `seed=None` heißt, nichts sichern und
nichts setzen. `.par_lapply(X, FUN, cores)` wird zu
`simlev._r.parallel.par_lapply(X, FUN, cores)` und rechnet wie R mit Fork
(siehe [Parallelität](#parallelität-cores)).

## Parallelität (`cores`)

`par_lapply` in `simlev/_r/parallel.py` ist die einzige Stelle, die parallel
rechnet; `bootstrap`, `bootstrap_study`, `param_search` (auch über
`overfit_walk_forward`/`param_bootstrap`), `sensitivity_grid`,
`sensitivity_rebalancing`, `planning_lumpsum_vs_dca` und `sensitivity_leverage` rufen
sie auf. Sie bildet `parallel::mclapply(mc.preschedule = FALSE, mc.set.seed =
FALSE)` nach (Verhalten in R 4.3.3 ermittelt in Etappe 5). R bündelt die
Einheiten seit dem 26.10.2026 in höchstens `4 × cores` Pakete (ein Fork je Paket)
mit denselben Ergebnissen, demselben Zufallszustand und denselben Fehlern;
innerhalb eines Pakets erscheinen Ausgaben dort in Einheitenreihenfolge.

- `cores` wird wie in `mclapply` ganzzahlig abgeschnitten; unter zwei Kernen
  oder mit höchstens einem Element ist es `lapply` (fortlaufender
  Zufallsstrom).
- Sonst startet jede Einheit mit dem Zufallszustand des Aufrufers
  (`rng_snapshot`/`rng_reset`), der danach unverändert ist. Ergebnisse in
  Eingangsreihenfolge, gleiche Ergebnisse für jedes `cores ≥ 2`.
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
5. Zufall nur über `simlev._r.rng`; der Zustand ist je Prozess global, eine
   Einheit setzt ihn selbst (`.Random.seed`) oder erbt den des Aufrufers.
6. Eine neue Funktion mit `cores` braucht Referenzfälle mit `cores = 1` und
   `cores = 2` (wie `sg_cores1_rng`/`sg_cores2_rng` in `golden/modules/sensitivity`).

## Zuordnung R-Datei → Python-Modul

| R-Quelle | Python |
|---|---|
| `simulation.R`, `utils.R` | `engine.py` (Einstieg `simulation()`, Engine `_simulation_flat()`), `_dates.py` (Numerik aus `_r/rnum.py`) |
| `sim_blocks.R` | `_sim_blocks.py` (Bausteine, Übersetzer `_sim_from_blocks`, `sim_args` und Pfade der Aufrufer: `_sim_args_set`, `_sim_check_names`, `_sim_call`) |
| `sim_base.R` | `_sim_base.py` |
| `sim_validate.R`, `sim_prepare.R` | `_sim_phases.py` |
| `sim_actions.R`, `sim_loop.R` | `_sim_loop.py` |
| `sim_evaluate.R` | `_sim_evaluate.py` |
| `simulation_core.cpp`, `fifo_core.cpp`, `tax_core.cpp` (Kerne in `*_core_impl.h`) | `_core.py` (mit gebauter Erweiterung die gemeinsamen Kerne, siehe [C-Erweiterung](#c-erweiterung)) |
| `asset_config.R`, `strategy.R` | `config.py` |
| `compute_rebal_trigger.R` | `trigger.py` |
| `tax_tariff.R`, `inst/extdata/steuertarif.csv` | `_tax_tariff.py`, `data/steuertarif.csv` |
| `print`/`summary` von `SimLevResult` | `result.py` |
| `plot_dashboard.R` | `dashboard.py` (Daten und Panels; R-Farbnamen in `data/r_colors.csv`) |
| Grafik (ohne R-Datei; R zeichnet mit Basisgrafik) | `svg.py` (`SimLevPlot`, plot-API, alle SVG-Zeichenbausteine) |
| `data_prep.R` | `data_prep.py` |
| `backcast.R` | `backcast.py` |
| `bonds.R` | `bonds.py` |
| `signals.R`; `.roll_mean_core`, `.roll_cov_core` aus `research_core.cpp` | `signals.py`, `_signals_core.py` |
| `bootstrap.R`, `bootstrap_core.cpp`; `.garch_filter` aus `research_core.cpp` | `bootstrap.py`, `_bootstrap_core.py` |
| `ms_garch.R`, `ms_garch.c`, `ms_garch_impl.c` | `ms_garch.py`, `_bootstrap_core.py` (`ms_garch_filter`; mit gebauter Erweiterung über `simlev._ext`, siehe [C-Erweiterung](#c-erweiterung)) |
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
| R-Interna (R 4.3.3) | `_r/`: `rnum.py` (unterste Schicht: `NA_REAL`, long-double-Summen, `R_pow`, `R_zeroin2`), `rformat.py` (`fround.c`, `fprec.c`, `formatReal`, `sprintf` für die Engine), `rng.py` (RNG.c, `nmath/r*.c`), `parallel.py` (`.par_lapply`, siehe [Parallelität](#parallelität-cores)), `nmath.py`, `_toms708.py`, `_cmath.py` (nmath), `stats.py` (Sammelmodul der Themen `stats_sort.py`, `stats_cor.py`, `stats_smooth.py`, `stats_optim.py`, `stats_models.py`, `stats_cluster.py`), `_optim.py`, `_lbfgsb.py`, `_sbart.py`, `_fft.py` (stats, appl), `linalg.py`, `_blas.py`, `_linpack.py`, `_lapack.py` (BLAS, LINPACK, LAPACK), `base.py`, `libm.py`, `fmt.py`, `rlist.py`, `reftree.py`; `port.py` (stats `port.c`, `portsrc.f`: `nlminb`) |
| übernommene R-Pakete | `_r/`: `imputets.py` (imputeTS 3.4 `na_interpolation` stine und linear, `na_locf` mit `src/locf.cpp`; in R übernommen als `.imputets_na_interpolation`, immer aktiv), `stinepack.py` (stinepack 1.5 `stinterp`, `stinemanSlopes`, `parabolaSlopes`; in R übernommen als `.stinepack_stinterp`), `evd.py` (evd 2.3-7.1 `fpot`, `src/pot.c`; in R übernommen als `.evd_fpot`, immer aktiv), `solnp.py` (Rsolnp 1.16 `solnp`, `gosolnp`; in R übernommen als `.rsolnp_solnp`, `.rsolnp_gosolnp`), `truncnorm.py` (truncnorm 1.0-9 `rtruncnorm`; in R übernommen als `.truncnorm_rtruncnorm`), `rugarch.py` (rugarch 1.5-6 `ugarchfit` sGARCH/gjrGARCH, `src/filters.c`, `garchmodels.c`, eigene Richardson-Ableitungen `_richardson_hessian`/`_richardson_jacobian`; in R übernommen als `.rugarch_ugarchfit`, Ableitungen `.sl_richardson_hessian` in `r/R/richardson.R`, immer aktiv) |

Die `.Call`-Hüllen (`r/R/cores.R`, `r/src/init.c`, `r/src/simlev_capi.h`)
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
| `stats_sort.py` | `stats_sort.jl` | Hilfen (long double), `order`, `sort`, `rank`, `rle`, `tabulate`, `findInterval`, `cut`, `complete_cases`, partielle Sortierung, `quantile`, `median`, `weighted_mean` |
| `stats_cor.py` | `stats_cor.jl` | `cor`, `cov`, `var`, `sd`, `cov2cor`, `scale` (cov.c) |
| `stats_smooth.py` | `stats_smooth.jl` | `approx`, `approxfun`, `filter`, `fft`, `bw_nrd0`, `density`, `smooth_spline`, `predict_smooth_spline` |
| `stats_optim.py` | `stats_optim.jl` | `optimize`, `uniroot`, `optim`, `optimhess`, `nlminb` (Anbindung an `port.py`/`port.jl`) |
| `stats_models.py` | `stats_models.jl` | `lm_fit`, `lm`, `poly`, `summary_lm`, `glm`, `binomial`, `coef`, `fitted`, `residuals`, `predict`, `p_adjust`, `ecdf`, `ave`, `aggregate`, `t_test` |
| `stats_cluster.py` | `stats_cluster.jl` | `dist`, `as_dist`, `dist_as_matrix`, `hclust` |

Importrichtung (ohne Kreise): `stats_sort` ← `stats_cor` ← `stats_smooth` ←
`stats_models`; `stats_optim` und `stats_cluster` brauchen nur `stats_sort`.

## Engine (`simulation()`)

Dieser Abschnitt gilt für `simulation()` und alles, was daran hängt
(`engine.py`, `_sim_base.py`, `_sim_phases.py`, `_sim_loop.py`,
`_sim_evaluate.py`, `_core.py`, `_dates.py`, `config.py`, `trigger.py`,
`result.py`, `_tax_tariff.py`, `_sim_blocks.py`, `dashboard.py`), und für Module, die die
Engine aufrufen oder ihre Helfer verwenden.

### Aufbau der Engine

Die Engine ist wie in R und Julia nach Phasen auf Dateien verteilt:

| Python | R | Julia | Inhalt |
|---|---|---|---|
| `_sim_blocks.py` | `sim_blocks.R` | `sim_blocks.jl` | Bausteine `sim_costs()`, `dca_plan()`, `rebalance_plan()`, `split_rule()`, `tax_profile()`, `income_rate()`, `income_tariff()`, `harvest_rule()`, `funds_costs()` mit Prüfung und Druck; `_sim_from_blocks` übersetzt sie in die flachen Engine-Argumente; `_sim_args_set` setzt `sim_args` und Pfade wie `"dca.value"` der Aufrufer (Etappe 6.4) |
| `engine.py` | `simulation.R` | `engine.jl` (Kopf, `include`s), `sim_evaluate.jl` (`simulation`, `_simulation_flat`) | Einstieg `simulation()` (Bausteine) und Engine `_simulation_flat()` (flache Argumente); bietet die öffentlichen Helfer und `_as_date`, `_r_class_name` weiter an |
| `_sim_base.py` | `sim_base.R` | `engine.jl` | Ausgabe- und Datumshilfen, Spaltendaten (`_Frame`), Gebühren, Termine und Flags, Handels- und Steuerfunktionen, Tarifweg, Jahreswechsel, Kennzahlen (`_xirr_rate`, Schiefe, Wölbung) |
| `_sim_phases.py` | `sim_validate.R`, `sim_prepare.R` | `sim_phases.jl` | Phase 1 `_sim_check_inputs`, Phase 2 `_sim_prepare_data`, `_sim_build_state`, `_sim_build_calendar`, `_sim_init_weights`, `_sim_build_schedule` |
| `_sim_loop.py` | `sim_actions.R`, `sim_loop.R` | `sim_loop.jl` | Phase 3 `_Actions`, Phase 4 `_sim_run_days` mit `_sim_day_*`, Phase 5 `_sim_close_years` |
| `_sim_evaluate.py` | `sim_evaluate.R` | `sim_evaluate.jl` | Phase 6 `_sim_compact_trades`, `_sim_returns`, `_sim_risk_stats`, `_sim_undefined_metrics`, `_sim_result` |

`simulation()` steht in Python in `engine.py` (in Julia in `sim_evaluate.jl`),
weil `engine.py` alle Phasenmodule einbindet und diese ihrerseits
`_sim_base.py` nutzen; so gibt es keine Kreisimporte. Bestehende Importe
`from .engine import …` bleiben gültig.

### Stand

- `golden/cases` 68/68 und `golden/extra` 37/37 sind bitgleich,
  einschließlich Druckausgabe und `details = TRUE`
  (`python tools/compare_golden.py [Pfade] [-k ids] [-v] [-q]`).
- Zusätzlich frisch erzeugte Fälle (300 Zufallsfälle, Seed 777 bzw. 999,
  jeweils mit den festen Fällen des Generators): `golden_cases.R` und
  `stress_cases.R` ergeben 669/669. Die neuen Argumente (order_fee, dca_fee,
  church_tax, harvest_*, taxable_income, tax_tariff) wurden zusätzlich in
  750 Fällen voll verglichen.
- Die R-Tests der Engine sind nach `tests/test_*engine*.py`, `test_tax*.py`,
  `test_simulation.py`, `test_config.py` und `test_dashboard.py` portiert.

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
`r_rowsums`, `r_colsums`; `LD = np.longdouble`), `r_pow`, `r_mod1` und die
Nullstellensuche, in `rformat.py` Runden und Textausgabe:

- Runden: `r_round` (fround.c, R ≥ 4), `r_signif` (fprec.c).
- Formatieren: `r_format(x, digits, nsmall, big_mark, scientific, width)`
  (formatReal, gibt eine Liste zurück), `r_format1`, `r_as_character`
  (15 Stellen, Drop0), `r_deparse`, `r_sprintf(fmt, *args)`. Die letzte
  Funktion unterstützt `%*.*f`; NA, Inf und -Inf werden wie in R als `%s`
  mit `"NA"`, `"Inf"` bzw. `"-Inf"` ausgegeben.
- Nullstellen (`rnum.py`): `r_uniroot(f, interval, f_lower, f_upper, tol, maxiter)`,
  gestützt auf `r_zeroin2` (Brent wie in R, Inf und NA werden wie in fcn2
  ersetzt).

`_dates.py` enthält Tageszahlen ab 1970 und R-`strptime` für `"%Y-%m-%d"`
(Semantik von get_number).

### Öffentliche Engine-Helfer für andere Module

`simulation`, `xirr_rate` / `_xirr_rate`, `calculate_skewness`,
`calculate_kurtosis`, `calculate_partials`, `calculate_dates_flags`,
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

Die Engine prüfen die Golden-Fälle in `golden/cases/` und `golden/extra/`
(`tools/compare_golden.py`, `tests/test_golden_master.py`; siehe
[Engine](#engine-simulation)). Alle übrigen Funktionen und die
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
- Engine: `tools/compare_golden.py` vergleicht Golden-Fälle (`.json`/`.json.gz`)
  in einem oder mehreren Ordnern. Frische Fälle erzeugen
  `Rscript golden/golden_cases.R <ziel> N SEED` bzw. `stress_cases.R`; das
  Ziel liegt **außerhalb des Repos** (z. B. in einem temporären Ordner),
  danach `compare_golden.py <ziel>` aufrufen.

Nach jeder Änderung an der Rechenlogik laufen `compare_golden.py`,
`compare_reference.py` und die ganze Test-Suite; alle Fälle müssen
bitgleich bleiben. Neue oder geänderte Fälle prüft zusätzlich die
Julia-Fassung (`julia/tools/compare_reference.jl`, siehe
[`julia/DEVELOPING.md`](../julia/DEVELOPING.md)).

Was ein Referenzfall bitgleich prüft, steht nicht noch einmal als Test in
`tests/` (Etappe 4.1): Die Fälle `golden/modules/r_fmt`, `r_linalg` und
`r_stats` laufen nur in `test_module_reference.py`, die Fälle
`engine/um01`–`um04` ersetzen drei Tests aus `test_engine_notes.py`. Die
Tests in `tests/` prüfen, was kein Fall abdeckt: Eigenschaften und
Handrechnungen auf eigenen Daten, Fehlerklassen, Warnungen, Dateien,
Grafiken und Schalter.

## Eingefrorene Schnittstelle

Die öffentliche Schnittstelle 0.5.0 ist in `tools/api_snapshot/frozen/py.json`
festgehalten (Etappe 6.6): je Funktion aus `simlev.__all__` und je Methode
`print`/`summary`/`plot` der Klassen mit `r_class` die Argumente in
Reihenfolge mit Art (`positional_or_keyword`, `keyword_only`, …) und
Standardwert als Text (`repr`), dazu die Namen der exportierten Klassen;
ohne Modul, Datei, Zeile und Datum. `tests/test_api_frozen.py` ruft dafür den
Auszug `tools/api_snapshot/api_py.py --frozen-check` in einem eigenen Prozess
auf und nennt bei Abweichung jede Änderung (Funktion neu oder weg, Argument
neu, weg oder umsortiert, Art oder Standardwert geändert).

Eine gewollte Änderung der Schnittstelle wird bewusst neu festgeschrieben:
Eintrag oben in `tools/api_snapshot/CHANGES.md` (Datum, was sich ändert,
warum), dann aus der Repo-Wurzel `tools/api_snapshot/run.sh --freeze`; das
schreibt `frozen/` für alle drei Sprachen neu und bricht ohne neuen Eintrag
ab. Einzelheiten in [`tools/api_snapshot/README.md`](../tools/api_snapshot/README.md).

## Schalter `SIMLEV_*`

Alle Umgebungsschalter liest (und setzt) nur `simlev/_r/env.py`; Paket,
Tests und Werkzeuge holen sie von dort (`tests/test_layers.py` prüft das).
Wann gelesen wird, bestimmt die aufrufende Stelle: `reftree` und
`tools/compare_golden.py` beim Laden, `_collate` beim ersten Vergleich (neu
nach `collate_reset()`), `_lapack` beim ersten Laden der Bibliothek,
`sys_time()` bei jedem Aufruf.

| Schalter | Zweck | Art |
|---|---|---|
| `SIMLEV_COLLATE` | Sortierung: `icu:<Locale>` (`icu:root` wie R unter C.UTF-8) oder `C` (Bytes); ohne Angabe nach `LC_ALL`/`LC_COLLATE`/`LANG` | Nutzer |
| `SIMLEV_ICU` | Pfad zur ICU-Bibliothek (`libicui18n`) | Nutzer |
| `SIMLEV_LAPACK` | Pfad zur Referenz-LAPACK (`dsyevr_`) | Nutzer |
| `SIMLEV_R_SYS_TIME` | feste Uhr für `sys_time()` (gosolnp), Sekunden seit 1970; `run_case()` setzt sie aus dem Feld `sys_time` eines Falls | Prüfung |
| `SIMLEV_LAX_NA` | `1`: NA = NaN im Vergleich (`reftree`, `compare_golden.py`) | Prüfung |
| `SIMLEV_STRICT_ZERO` | `0`: −0 = +0 im Vergleich (`reftree`) | Prüfung |
| `SIMLEV_GOLDEN_DIR` | andere Ordner der Engine-Fälle für `test_golden_master.py` (mit `os.pathsep` getrennt) | Prüfung |
| `SIMLEV_MODULE_DIR` | anderer Ordner der Modul-Fälle für `test_module_reference.py` und die Grafiktests | Prüfung |
| `SIMLEV_NO_EXT` | `1`: C-Erweiterung `simlev._ext` nicht nutzen, reine Python-Kerne (Rückfall prüfen); gelesen bei jedem Aufruf von `env.ext()`, in Tests über `env.use_ext(flag)` | Prüfung |

`reftree` setzt `SIMLEV_COLLATE=icu:root`, falls nicht gesetzt (die
Referenzen entstanden unter C.UTF-8). Die Generatoren in `golden/modules/`
lesen eigene Schalter (`SIMLEV_R_NMATH_SRC`, `SIMLEV_ALLOW_PARTIAL`, siehe
`golden/README.md`).

## C-Erweiterung

R und Python teilen sich alle nativen Kerne des R-Pakets (Etappe 7.2 Pilot
MS-GARCH, Etappe 7.3a die Kerne ohne Zufallszahlen, Etappe 7.3b die Kerne mit
Zufallszahlen: Bootstrap und truncnorm). Das ist eine reine Beschleunigung:
Schnittstelle und Ergebnisse ändern sich nicht, die reinen Python-Kerne
bleiben der Rückfall (`SIMLEV_NO_EXT=1` oder ohne Compiler). Julia behält
seine eigenen Ports.

**Geteilte Kerne** (kanonische Datei in `r/src/` → R-Hülle → Python):

| Kerndatei (`r/src/`) | R-Hülle (`.Call`) | Python-Hülle (`python/src/`) | Python-Aufrufer |
|---|---|---|---|
| `ms_garch_impl.c`, `ms_garch_impl.h` | `ms_garch.c` | `_ext_ms_garch.cpp` | `_bootstrap_core.ms_garch_filter` |
| `research_core_impl.h` | `research_core.cpp` | `_ext_research.cpp` | `_optimize_core` (`proj_box_simplex`, `qp_box_simplex`, `min_cvar_core`, `min_cdar_core`), `_signals_core` (`roll_mean_core`, `roll_cov_core`), `_dependence_core` (`kendall_tau_core`, `quantile_reg_core`, `hmm_forward_backward`), `_bootstrap_core.garch_filter` |
| `withdrawal_core_impl.h` | `withdrawal_core.cpp` | `_ext_withdrawal.cpp` | `_withdrawal_core.wd_simulate` |
| `dependence_core_impl.h` | `dependence_core.cpp` | `_ext_dependence.cpp` | `_dependence_core.dcc_filter` |
| `vendor_rugarch_impl.h` | `vendor_rugarch.c` | `_ext_rugarch.cpp`, `_ext_rugarch_c.c` | `_r/rugarch.py` (`_LLH`) |
| `vendor_evd_impl.h` | `vendor_evd.c` | `_ext_evd.cpp`, `_ext_evd_c.c` | `_r/evd.py` (`nlgpd`) |
| `vendor_imputets_impl.h` | `vendor_imputets.cpp` | `_ext_imputets.cpp` | `_r/imputets.py` (`_locf_core`) |
| `simulation_core_impl.h`, `fifo_core_impl.h`, `tax_core_impl.h` | `simulation_core.cpp`, `fifo_core.cpp`, `tax_core.cpp` | `_ext_engine.cpp` | `_core.py` (alle Funktionen außer `_update_fifo_front`) |
| `bootstrap_core_impl.h` (mit Zufallszahlen) | `bootstrap_core.cpp` | `_ext_bootstrap.cpp` | `_bootstrap_core` (`boot_idx_iid`, `boot_idx_block`, `boot_idx_stationary`, `boot_idx_regime`, `boot_idx_tails`, `boot_wild`, `boot_reset`, `boot_evt`, `boot_garch`, `boot_ms_garch`, `rolling_vol`, `assign_regimes`, `estimate_trans_mat`) |
| `vendor_truncnorm_impl.h` (mit Zufallszahlen) | `vendor_truncnorm.c` | `_ext_truncnorm.cpp`, `_ext_truncnorm_c.c` | `_r/truncnorm.py` (`rtruncnorm`) |

Dazu `simlev_core.h` (Aufbau, Host-Schnittstelle, `simlev_na_real()`) und nur
auf der Python-Seite `_rng_r.c`/`_rng_r.h` (C-Nachbildung von R's
Zufallszahlen) mit dem Prüfzugang `_ext_rng.cpp` (`rng_draw`, `rng_qnorm`,
`rng_dnorm`, für Tests).

- **Aufbau:** Die Rechnung steht in `r/src/<datei>_impl.h` (C++-Kerne: nur
  Header, `static`-Funktionen im Namensraum `simlev`; C-Kerne: `static`
  C-Funktionen, `ms_garch_impl.c` als eigene Übersetzungseinheit) und
  enthält keine R- oder Python-Header. Die Kerne sprechen ihren Host nur über
  die Typen `simlev_host::NumVec`, `IntVec`, `NumMat` (Engine: `Obj` und die
  Zugriffe `as_list`, `at`, `get`, `set`, `put`, `has`, `as_double`,
  `as_int`, `num_vec`, `named_list`, `new_num`, `new_int`, `Date`) und die
  Makros `SIMLEV_*` an. Den Host stellt die einbindende Hülle: R in
  `r/src/simlev_capi.h` (Abschnitt „R als Host der gemeinsamen Kerne“),
  Python in `python/src/_ext_common.h` bzw. für die Engine in
  `_ext_engine.cpp`. Für R stehen hinter den Namen genau die Aufrufe, die
  vor der Teilung im Kern standen; der R-Bau erzeugt daher **denselben
  Maschinencode** wie zuvor (geprüft mit `objdump` Funktion für Funktion für
  alle Objektdateien, dazu Byte-Gleichheit aller Generatoren und der
  Engine-Fälle). Die R-Datei `<datei>.cpp/.c` ist nur noch die
  `.Call`-Hülle (Umwandlung der Argumente wie bisher).
- **Python-Modul:** eine Erweiterung `simlev._ext` (`_ext.cpp` fügt die
  Methodentabellen der Hüllen `_ext_<kern>.cpp` zusammen). Die Hüllen
  nehmen Felder über das Buffer-Protokoll (numpy-Arrays `float64` bzw.
  `int32`, zusammenhängend; keine numpy-Header), prüfen Typ, Länge und
  Beschreibbarkeit der Puffer und geben Ergebnisse als `bytearray`/`float`
  bzw. für die Engine als dict/list zurück. Fachliche Prüfungen und
  Umwandlungen wie in R macht die aufrufende Python-Funktion vorher, mit
  denselben Meldungen wie der reine Python-Kern. Geladen wird das Modul über
  `simlev._r.env.ext()` (beim ersten Aufruf; `None`, wenn nicht gebaut oder
  `SIMLEV_NO_EXT=1`).
- **Rückmeldeschnittstelle** (`simlev_core.h`): `SIMLEV_FAIL(fmt, ...)`
  (Fehler mit Text, kehrt nicht zurück; R: `stop()` mit genau diesem Text,
  Python: `ValueError` mit dem Text, den die Python-Seite in die
  Fehlerklasse des reinen Python-Kerns umsetzt, etwa `WdError`,
  `QuantileRegError`), `SIMLEV_WARN(msg)` (R: `Rf_warning`, Python:
  `warnings.warn`; derzeit ungenutzt), `SIMLEV_CHECK_INTERRUPT()`
  (Benutzerabbruch), `SIMLEV_NA` (R's `NA_real_`), Ergebnisfelder
  `SIMLEV_NUM`, `SIMLEV_MATRIX`, `SIMLEV_COPY`, `SIMLEV_LIST`,
  `SIMLEV_SET_FLAG`. Python legt Ergebnisfelder in einem Speicher je Thread
  an (`ext::Alloc`) und kopiert sie nach dem Kern in Python-Objekte.
  Fehler der Engine-Zugriffe sind die Python-Ausnahmen des reinen Kerns
  (`KeyError`, `IndexError`, `TypeError`).
- **Benutzerabbruch:** wie in R. Von den geteilten Kernen prüfen
  `vendor_imputets` (`locf`, alle 1024 Werte) und `vendor_truncnorm` (je
  Wert): R über `R_CheckUserInterrupt`, Python über `PyErr_CheckSignals()`
  (`KeyboardInterrupt`; der Kern läuft dazu mit gehaltener GIL). `locf`
  bricht sofort ab; `rtruncnorm` rechnet nach einem Signal die Schleife zu
  Ende und meldet dann `KeyboardInterrupt` (kein `longjmp` aus dem Kern). Die
  übrigen Kerne prüfen in beiden Sprachen nicht; Python gibt bei den Kernen
  ohne Zufallszahlen die GIL während der Rechnung frei (Strg-C wirkt nach dem
  Kern), die Engine-Kerne und die Kerne mit Zufallszahlen laufen mit
  gehaltener GIL (Python-Objekte bzw. der Zustand von `simlev._r.rng`).
- **Zufallszahlen in geteilten Kernen** (Etappe 7.3b): Ein Kern zieht nur
  über den Host, `simlev_host::runif`, `rnorm` und `rgeom` (C++), bzw. über
  die Namen aus R's `Rmath.h` (`runif`, `rnorm`, `rexp`, `dnorm` im C-Kern
  von truncnorm). R stellt dafür genau R's Funktionen (`Rf_runif`, …;
  `GetRNGstate`/`PutRNGstate` setzt die `.Call`-Hülle), der Maschinencode
  ist derselbe wie vor der Teilung. Python stellt eine **C-Nachbildung von
  R's Zufallszahlen** (`python/src/_rng_r.c`, Funktionsrümpfe aus R 4.3.3
  `src/main/RNG.c`, `src/nmath/snorm.c`, `qnorm.c`, `sexp.c`, `runif.c`,
  `rnorm.c`, `rexp.c`, `rgeom.c`, `rpois.c`, `dnorm.c`). Sie arbeitet auf dem
  Zustand der Python-Nachbildung `simlev._r.rng`: Die Python-Seite ruft wie
  der reine Kern erst `_get_state()`, dann `rng.c_state(rpois)` und übergibt
  drei Puffer (`ist` int32[12]: Art, Normalverteilung, `mti`, Merker für neu
  erzeugte Wörter, L'Ecuyer-Zustand, `rpois` `l`/`m`; `mt`: Sicht auf die 624
  Wörter des Mersenne-Twisters, an Ort und Stelle geändert; `pst`: der
  statische Zustand von `rpois`, nur für Kerne, die `rgeom` ziehen). Der
  Kern zieht, `rng.c_state_put()` schreibt den Zustand zurück (auch nach
  einem Fehler des Kerns, wie R's `PutRNGstate`; der Ausgabepuffer des
  Mersenne-Twisters wird nach neu erzeugten Wörtern verworfen). Danach ist
  der Zustand derselbe, als hätte der reine Python-Kern gezogen
  (`tests/test_shared_c.py`).
  - **Unterstützte Arten:** genau die von `simlev._r.rng`: Generator
    „Mersenne-Twister“ (Voreinstellung) und „L'Ecuyer-CMRG“ (Parallelität),
    Normalverteilung „Inversion“ (mit `qnorm5`, auch dem Zweig `r > 27` aus
    R 4.3). Die Stichprobenart spielt für diese Kerne keine Rolle.
  - **Rückfall:** Liefert `c_state()` `None` (andere Art, ungewöhnlicher
    Zustand), rechnet still der reine Python-Kern (bitgleich). Ebenso bei
    Eingaben, die der C-Kern in R nicht sicher rechnet (Indizes außerhalb
    der Felder, zu kurze Felder, keine Beobachtung in den Regimen, negative
    Längen, Werte außerhalb von int32, `L` nicht endlich oder über 1e7 im
    stationären Bootstrap): Die Python-Seite prüft das vorher und lässt dann
    den reinen Kern rechnen.
  - **Parallelität:** Der Zustand liegt nur in Python-Objekten, die
    Erweiterung hat keinen eigenen. Die Kinder von `par_lapply` (Fork)
    ziehen daher mit ihren eigenen Zuständen; Referenzfälle mit `cores = 2`
    (`bs_cores2_*`, `sg_cores2_rng`, …) und
    `test_rng_kerne_in_kindprozessen`.
  - **NaN-Nutzlast:** Welche Nutzlast bei zwei NaN-Operanden bleibt, hängt
    von der Registerwahl des Compilers ab. Damit der Kern in der
    Python-Hülle so übersetzt wird wie in der R-Hülle, markieren die Hüllen
    ihre Prüfungen als unwahrscheinlich (`EXT_FAIL_IF`; sonst gilt der Kern
    als selten und wird auf Größe optimiert), und `_ext_truncnorm_c.c` stellt
    `NA_REAL`, `R_PosInf`, `R_NegInf`, `R_FINITE` wie R als Variablen bzw.
    Aufruf aus einer anderen Übersetzungseinheit. Im Zufallsvergleich gegen
    R (Etappe 7.3b) ist die Erweiterung auch mit NA/NaN in den Daten
    bitgleich; die reinen Python-Kerne `boot_wild`, `boot_garch`,
    `boot_ms_garch` und `rtruncnorm` liefern in solchen Fällen teils NaN
    statt NA bzw. umgekehrt (Wert in beiden Fällen fehlend).
- **Gemeinsame Quelle:** Das Python-Quellpaket braucht die Dateien in
  seinem eigenen Baum, deshalb liegen **Byte-für-Byte-Kopien** in
  `python/src/`; `tests/test_shared_c.py` prüft Gleichheit und
  Vollständigkeit der Liste (übersprungen, wenn `r/` nicht daneben liegt).
  Geändert wird nur `r/src/`, danach
  `cp r/src/simlev_core.h r/src/*_impl.[ch] python/src/`. Nur in
  `python/src/` (keine Kopie) liegen die Hüllen `_ext*` und die
  C-Nachbildung von R's Zufallszahlen `_rng_r.c`/`_rng_r.h` (`PY_ONLY` im
  Test).
- **Bau:** `setup.py` (setuptools `Extension`, `optional=True`; übrige
  Angaben in `pyproject.toml`, `MANIFEST.in` nimmt `src/` ins Quellpaket).
  `pip install .` baut mit, wenn ein C/C++-Compiler da ist; im Klon ohne
  Installation `python setup.py build_ext --inplace` (legt
  `simlev/_ext*.so` ab, von `.gitignore` ausgenommen). Scheitert der Bau,
  warnt setuptools und installiert ohne Erweiterung.
- **Gleitkomma:** dieselben Einstellungen wie R (`R CMD config CXXFLAGS`:
  `-O2`, kein `-ffast-math`, kein `-march`). `setup.py` setzt `-O2
  -fno-fast-math -ffp-contract=off` (MSVC `/O2 /fp:precise`), C++ mit
  `-std=gnu++17`, und `-fstrict-overflow`, sofern der Compiler es kennt
  (Python übersetzt sonst mit `-fwrapv`, R nicht; das ändert die Schleifen
  der Engine-Kerne). Jede Kerndatei bricht bei `-ffast-math` ab (`#error`)
  und schaltet das Zusammenziehen zu fma per Pragma ab, unter GCC aber nur,
  wo fma überhaupt erzeugt werden kann (`__FP_FAST_FMA`): auf x86-64 ist
  `-ffp-contract=off` wirkungslos, das Pragma `GCC optimize` verändert dort
  aber die Codeerzeugung der ganzen Datei. Python setzt
  `SIMLEV_FP_CONTRACT_BY_FLAG` und lässt das Pragma weg. `long double` hat
  wie in R 80 Bit (x86-64); `exp`, `log`, `pow`, `sqrt` kommen aus der
  glibc-libm.
- **NaN-Nutzlast:** Treffen in einer Operation zwei NaN mit verschiedener
  Nutzlast aufeinander (`NA` und `NaN`), behält x86-64 die des ersten
  Operanden; welcher das ist, wählt der Compiler. Für die Array-Kerne rechnet
  die Erweiterung wie R (Zufallsvergleich ohne Abweichung). Die Engine-Kerne
  arbeiten in Python auf anderen Objekten als in R; `_ext_engine.cpp` ist
  wie der R-Host aufgebaut, damit der Compiler den Kern gleich übersetzt,
  in seltenen Fällen mit NA und NaN in derselben Operation (etwa `NA` als
  Kontostand und `NaN` als Zufluss) kann Python aber `NaN` statt `NA`
  liefern (Wert in beiden Fällen fehlend; wie beim reinen Python-Kern). Der
  reine MS-GARCH-Filter rechnet seit 7.3a in diesem Fall eigens wie R
  (`_ms_garch_filter_nan`: Operandenfolge aus dem R-Maschinencode, NaN der
  glibc für `log`/`sqrt` negativer Zahlen); er wird nur genutzt, wenn ein
  Ergebnis NaN ist.
- **Prüfen** in beiden Fällen:

  ``` bash
  python python/tools/compare_reference.py && SIMLEV_NO_EXT=1 python python/tools/compare_reference.py
  python python/tools/compare_golden.py && SIMLEV_NO_EXT=1 python python/tools/compare_golden.py
  cd python && python -m pytest -q tests && SIMLEV_NO_EXT=1 python -m pytest -q tests
  ```

- **Neuen Kern hinzufügen:** (1) Rechnung aus der R-Datei nach
  `r/src/<datei>_impl.h` verschieben, `sl::`/R-Typen durch
  `simlev_host::`/`SIMLEV_*` ersetzen (fehlende Namen in beiden Hosts
  ergänzen: R in `simlev_capi.h` als genau den bisherigen Aufruf, Python in
  `_ext_common.h`), Kopf mit Gleitkomma-Block und Host-Prüfung wie in den
  vorhandenen Kerndateien; (2) R-Datei auf `#include "simlev_capi.h"`,
  `#include "<datei>_impl.h"` und die `.Call`-Hüllen kürzen; (3) prüfen,
  dass der R-Maschinencode gleich bleibt (`objdump -d` der alten und neuen
  Objektdatei, Funktion für Funktion), sonst an der Stelle anhalten;
  (4) Kopie nach `python/src/`, Datei in `SHARED` (`tests/test_shared_c.py`)
  und `SHARED_HEADERS`/`CORES` (`setup.py`); (5) Hülle
  `python/src/_ext_<kern>.cpp` mit Methodentabelle
  `simlev_ext_<kern>_methods` (in `_ext_common.h` deklarieren, in
  `_ext.cpp` eintragen, in `WRAPPERS` aufnehmen); (6) im Python-Kern
  `ext = _env.ext()` und bei `ext is not None` die Hülle rufen, sonst wie
  bisher; (7) Referenzfälle mit und ohne Erweiterung, Zufallsvergleich
  gegen R mit NA, NaN, Inf, −0 und leeren Eingaben. Zieht der Kern
  Zufallszahlen: nur über `simlev_host::` (fehlende Funktionen in beiden
  Hosts ergänzen, in Python in `_rng_r.c` nur für die Arten von
  `simlev._r.rng`); die Hülle bindet den Zustand mit `ext::Rng` und läuft
  mit GIL, die Python-Seite ruft nach `_get_state()` `rng.c_state()` und
  danach immer `rng.c_state_put()` (`_bootstrap_core._call`); Prüfungen der
  Hülle mit `EXT_FAIL_IF`; Zufallsvergleich zusätzlich mit beiden Arten,
  verschiedenen Positionen im Strom und `.Random.seed` danach.
- **Schichten:** `_ext` gehört zu Schicht 0 (geladen von `_r.env`) und
  steht in `tests/test_layers.py` unter `EXTENSIONS`.

## Schichten und Laden

Die Module gehören zu fünf Schichten (Anhang F des Entwicklungsdokuments):
0 R-Interna (`simlev/_r/`), 1 Daten und Strategie (`config`, `data_prep`,
`backcast`, `bonds`, `signals`, `trigger`, `_tax_tariff`, `_dates`),
2 Engine (`engine`, `_sim_*` einschließlich `_sim_blocks`, `_core`, `result`), 3 Analysen (je ein Modul
mit seinem Kern), 4 Ausgabe (`svg`, `dashboard`). `tests/test_layers.py`
liest alle Importe (auch in Funktionen und über `_ext("modul", …)`) und
prüft, dass kein Modul eine höhere Schicht importiert; die Zuordnung und
die bekannten Ausnahmen (vor allem die plot-Methoden der Analysen, die die
Grafikbausteine aus `svg` holen) stehen mit Begründung im Test.

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
- Keine Abhängigkeiten außer numpy und pandas (auch nicht für Grafiken);
  ohne System-LAPACK rechnet numpy die Eigenvektoren
  (mit Warnung, nicht bitgleich). Die C-Erweiterung ist optional und braucht
  zum Bau nur einen C/C++-Compiler (C++17) und die Python-Header (keine numpy-Header).
