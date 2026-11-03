# Entwicklung der Julia-Fassung

Die Julia-Fassung rechnet dieselben IEEE-754-Zahlen wie die R- und die
Python-Fassung: Die Rechenkerne liegen als gemeinsamer C/C++-Code in `core/`
(über `ccall`), Julia bildet die Schnittstelle darum (Eingabeprüfung,
Datenaufbereitung, Ablauf, Ergebnisobjekte, Druck, Grafik). Für diese Teile
sind die Gegenstücke in `r/R/` und `python/simlev/` der Vergleich; die
Python-Fassung bildet dieselbe Rechenreihenfolge in einer ähnlichen Sprache
nach und eignet sich daher als Vorlage für Änderungen. Die Zuordnung aller öffentlichen
Funktionen zu Dateien in R, Python und Julia steht in [`STRUKTUR.md`](../STRUKTUR.md).

> **Stand:** Zufall und Numerik rechnet die eigene C-Bibliothek slc, die Engine von
> `simulation()` und die übrigen geteilten Kerne die C++-Kerne aus `core/` (Abschnitte
> [C-Bibliothek](#c-bibliothek-pflicht), [Zufall](#zufall) und [Tests](#tests)). `src/r/` bildet nur noch Grundfunktionen von R nach
> (Liste und Herkunft in [`COPYRIGHTS.md`](COPYRIGHTS.md)); `RRng`, `RNmath`, die
> BLAS/LAPACK/LINPACK-Ports, `optim`/`nlminb` und die früher übernommenen Pakete gibt es nicht
> mehr.

## Bauen, Vorkompilieren, Abgleich und Tests

Aus der Repo-Wurzel, immer mit `LC_ALL=C.UTF-8`:

``` bash
python3 core/sync.py --check          # Kopien der C-Quellen (auch julia/deps/core) prüfen
python3 core/sync.py --write          # nach einer Änderung in core/ verteilen
julia --project=julia -e 'using Pkg; Pkg.build()'   # deps/build.jl: libslc mit C- und C++-Compiler
julia --project=julia -e 'using SimLev'             # Vorkompilieren (einige Minuten, siehe unten)
julia --project=julia tests/run.jl                  # Tests (Gruppen gleichlauf, fehler, ausgabe, schnittstelle)
tests/werkzeuge/gleichlauf/run.sh --quick           # Gleichlauf mit R und Python
tests/werkzeuge/doku/beispiele.sh julia             # Beispiele der READMEs und des Tutorials
```

Nach jeder Änderung an `src/` kompiliert das erste `using SimLev` das Paket neu vor; bei der
Entwicklung schalten `SIMLEV_SKIP_PRECOMPILE_EXT=1` (ohne Erweiterungen) bzw.
`SIMLEV_SKIP_PRECOMPILE=1` (ganz) die Arbeitslast ab (Einzelheiten unter
[Referenzfälle und Prüfung](#referenzfälle-und-prüfung)). Die C-Quellen werden nur in `core/`
geändert (Regeln in [`core/README.md`](../core/README.md)). Die Tests liegen im Ordner `tests/`
des Repositorys, nach Zweck gegliedert, und gehören nicht zum Paket; Katalog und Befehle stehen
in [`tests/README.md`](../tests/README.md). Sie sollen künftig nur lokal liegen (dort Abschnitt
„Lokal aufbewahren“); `Pkg.build` und `using SimLev` laufen ohne sie.

## Aufbau

Alles liegt im Modul `SimLev`; die Bausteine sind Untermodule. Die Tabelle
folgt der Reihenfolge der `include`s in `src/SimLev.jl`: erst die R-Interna
(`src/r/`), dann die Engine, das Grafikmodul `svg.jl` und das Dashboard,
dann die Module (C++-Kerne jeweils vor ihrem Modul), zuletzt `exports.jl`
und `precompile.jl`.

| Datei | Untermodul | Inhalt (Gegenstück in R → in Python) |
|---|---|---|
| `src/r/env.jl` | `REnv` | Umgebungsschalter `SIMLEV_*`: einzige Stelle, die sie liest oder setzt (siehe [Schalter](#schalter-simlev_)) → `_r/env.py` |
| `src/slib.jl` (+ `slib_linalg.jl`, `slib_opt.jl`, `slib_models.jl`) | `SLib` | Hüllen der C-Bibliothek slc per `ccall` (Zufall, Verteilungen, lineare Algebra, Optimierer, Modelle, Bootstrap-Kerne); Bibliothek aus `deps/build.jl` (siehe [C-Bibliothek](#c-bibliothek-pflicht)) → `simlev/_lib*.py` |
| `src/cabi.jl` | `CAbi` | Rückgabecodes, Fehlertexte und Feldlagen der C-ABI-Hülle `core/simlev_cabi.cpp` der geteilten C++-Kerne (in `libslc`) → `python/src/_ext_common.h` |
| `src/r/types.jl` | – | R-Datenstrukturen (`RList`, `RFrame`, `RVector`, `NamedMat`), Druck-/summary-/plot-Registrierung |
| `src/r/rnum.jl` | – | `NA`, `isna_strict`, Summen/Mittel/Varianz in `long double` (`r_sum`, `r_mean`, …), `r_pow` (`R_POW`), zentrale Auswahl der C-Bibliotheken (`_LIBM`, `_LIBC`, `_SNPRINTF`) → `_r/rnum.py` |
| `src/r/rformat.jl` | – | Textausgabe der Engine: `r_sprintf` (NA/NaN/Inf wie R), `r_format`, `r_as_character`, `r_deparse`, `r_round`, `r_signif` → `_r/rformat.py` |
| `src/r/libm.jl` | `RLibm` | glibc-libm (`exp`, `log`, `log1p`, `expm1`, `pow`, `tanh`, …) → `_r/libm.py` |
| `src/r/base.jl` | `RBase` | Summen, Mittel, `cumsum`, `cumprod`, `rowSums`, … mit `long double` → `_r/base.py` |
| `src/r/parallel.jl` | `RParallel` | `.par_lapply` mit `Threads.@spawn` (`par_lapply`), Meldungen und Ausgaben je Aufgabe (`r_stderr`, `r_stdout`, `suppress_messages`), siehe [Parallelität](#parallelität-cores) → `_r/parallel.py` |
| `src/r/fmt.jl` | `RFmt` | `format`, `formatC`, `sprintf`, `round`, `signif`, `print` von Vektoren/Matrizen/data.frames → `_r/fmt.py` |
| `src/r/stats.jl` | `RStats` | Modulkopf mit Exporten; bindet die Themen ein (gleiche Namen wie in Python): `stats_sort.jl` (Hilfen, `order`, `r_sort`, `r_rank`, `cut`, `quantile`, `median`, …), `stats_cor.jl` (`cor`, `cov`, `var`, `scale`), `stats_smooth.jl` (`approx`, `r_filter`), `stats_optim.jl` (`optimize`, `uniroot`), `stats_models.jl` (`coef`, `fitted`, `p_adjust`, `ecdf`, `ave`, `aggregate`), `stats_cluster.jl` (`dist`, `hclust`) → `_r/stats.py` (Sammelmodul) und `_r/stats_*.py` |
| `src/r/linalg.jl` | `RLinalg` | `outer`, `diag`, `is_symmetric`, `all_equal_numeric` (seit 1.0.0 ohne `matprod`, `solve`, `chol`, `qr`, `eigen` und die BLAS/LAPACK/LINPACK-Ports) → `_r/linalg.py` |
| `src/r/rexpr.jl` | `RExpr` | Ausdrücke in R-Syntax als Text (`eval(parse(text = …), data, env)`): ein gemeinsamer Auswerter für Bedingungen in `bootstrap_probability`, `regime_subset`, `view_prob`/`scenario_entropy_pooling` und `tactical_rules` (R-Vorrang inkl. schwach bindendem `!`, NA-Logik, `%in%`, `%%`, Funktionen über `RLibm`/`RFmt`) |
| `src/engine.jl` u. a. | – | `simulation()` und Strategie/Config: `engine.jl` (Hilfen, Handels- und Steuerfunktionen; r/R/sim_base.R → `_sim_base.py`), `sim_phases.jl` (r/R/sim_validate.R, sim_prepare.R → `_sim_phases.py`), `sim_engine.jl` (Phasen 4 und 5 über den C++-Kern `core/engine_core_impl.h`; r/R/sim_engine.R → `_sim_engine.py`), `sim_evaluate.jl` (r/R/sim_evaluate.R → `_sim_evaluate.py`; dazu `simulation()` und `_simulation_flat()` aus r/R/simulation.R → `engine.py`), `sim_blocks.jl` (Bausteine, r/R/sim_blocks.R → `_sim_blocks.py`), `wrapper.jl` (Fonds-Wrapper `wrapper_config`, `wrapper_nav`, Anteilswert `_wrapper_nav_calc`, r/R/wrapper.R → `wrapper.py`; Hilfen der Strategie `_strategy_columns`, `_strategy_wrappers` in `config.jl`) |
| `src/svg.jl` | – | Grafikmodul: `SimLevPlot`, `_plot_method` & Co., alle SVG-Zeichenbausteine (siehe [Grafik](#grafik)) → `simlev/svg.py` |
| `src/dashboard.jl` | – | Dashboard-Daten und Panels, `plot_dashboard`, `export_dashboard` (r/R/plot_dashboard.R) → `dashboard.py` |
| `src/<modul>.jl` | `DataPrep`, `Backcast`, `Bonds`, `Signals`, `Bootstrap`, `Withdrawal`, `Dependence`, `Regimes`, `MsGarch`, `Scenarios`, `Optimize`, `Tactical`, `DeepAnalysis`, `Planning`, `AnalysisTests`, `Overfitting`, `ParamSearch`, `Sensitivity` | je eine R-Datei `r/R/<modul>.R` → `python/simlev/<modul>.py` |
| `src/<name>_core.jl` | `SignalsCore`, `WithdrawalCore`, `DependenceCore`, `OptimizeCore` | Hüllen der geteilten C++-Kerne aus `core/` über `ccall` (seit 1.2.0, `src/cabi.jl`; vorher eigene Ports) → `python/simlev/_<name>_core.py`; `BootstrapCore` und der Port des DCC-Filters sind mit 1.0.0 entfallen |
| `src/exports.jl` | – | sammelt die öffentlichen Funktionen der Untermodule für `using SimLev` |

Funktionen anderer Untermodule werden **im Funktionsrumpf qualifiziert**
aufgerufen (`SimLev.DataPrep._to_date(x)`, `SimLev.RStats.quantile(x, p)`),
damit die Reihenfolge der `include`s keine Rolle spielt. Typen und
Konstanten, die andere brauchen, stehen in früher eingebundenen Dateien.

Namen folgen R bzw. der Python-Fassung (snake_case, `.` → `_`, interne Helfer
mit führendem `_`). Kollidiert ein Name in einem `R*`-Untermodul mit einer
Funktion aus `Base` (`sort`, `filter`, `diff`, `round`, `range`, `cumprod`,
`cummax`, `cummin`, `rank`, `rem`, …), bekommt er das Präfix `r_`
(`RStats.r_sort`, `RFmt.r_round`). Pflichtargumente sind Positionsargumente,
alle anderen Schlüsselwortargumente mit den Voreinstellungen von R.
Julia-Schlüsselwörter als Argumentnamen werden mit `_` ergänzt (`from_`,
`end_`, `function_`, …).

## Datenstrukturen

Siehe Kopf von `src/r/types.jl`. Kurz: NULL → `nothing`; numerisches NA →
`SimLev.NA` (NaN mit R's Nutzlast 1954, von NaN unterscheidbar über
`isna_strict`), andere NA → `missing`; Vektor der Länge 1 → Skalar;
benannter Vektor → `RVector`; data.frame → `RFrame`; Matrix mit dimnames →
`NamedMat`; Liste mit Namen → `RList` (S3-Klasse im Feld `class`).
Attribute von data.frames und Vektoren stehen in `attrs(x)`.
Objekte mit Klasse drucken über `register_print!(klasse, (io, x) -> …)`
exakt wie die R-Methode; `r_summary` und `r_plot` verteilen ebenso.

Eingaben nehmen zusätzlich die natürlichen Julia-Formen an (NamedTuple oder
`Dict` statt data.frame, `Pair`-Listen/`Dict` statt benannter Vektoren).

## Regeln für Bitgleichheit

1. Rechenreihenfolge 1:1 aus R/C++ (bzw. der Python-Fassung) übernehmen.
2. **Nie `sum`, `prod`, `mean` aus Base auf Gleitkommavektoren**: Julia
   summiert paarweise. R summiert sequenziell in `long double` – dafür
   `RBase.r_sum`, `r_mean`, `r_cumsum`, `r_prod`, `r_var` usw., im Fachcode
   `SimLev._ld_colsums`/`_ld_rowsums` (alle über die C-Kerne `core/slc_rbase*.c`).
   Wo C++ mit `double` sequenziell summiert, eine einfache Schleife.
3. **Nie `exp`, `log`, `log1p`, `expm1`, `^`, `tanh`, `sin`, … aus Base** auf
   Float64: Julia rechnet sie selbst, R nutzt glibc-libm. Immer `RLibm.*`
   (auch beim Broadcasting: `RLibm.exp.(x)`); `x^2` ist in R `x*x`, sonst
   `RLibm.pow` (R's `R_POW`-Regeln, siehe `src/r/rnum.jl`). `sqrt`, `abs`, `floor`,
   `ceil`, `+ - * /` sind exakt. Kein `muladd`/`fma`, kein `@fastmath`.
4. **Keine Matrixprodukte mit `*`** (OpenBLAS): Matrixprodukte, Cholesky, Löser, Eigenwerte und
   QR kommen wie in R aus der C-Bibliothek (`SLib.matmul`, `crossprod`, `chol`, `eigen_sym`, …;
   seit 1.0.0, keine System-LAPACK mehr).
5. Sortieren, Runden und Formatieren immer über `RStats`/`RFmt` (R's
   Sortierverfahren bei Gleichständen und ±0, R's `round`-Algorithmus,
   C-`printf` für Zahlen).
6. Zufall nur über `SLib` (Zustand von SimLev bzw. ein `SLib.Stream`, siehe
   [Zufall](#zufall)); `RRng` ist mit 1.0.0 entfallen.
7. NA und NaN wie in R auseinanderhalten: Arithmetik mit NA ergibt auf x86
   wie in R wieder NA; wo R `NA_real_` setzt, `SimLev.NA` setzen.
8. R-`warning(text)` → `@warn text` (nur die Meldung, keine weiteren
   Felder); R-`stop(text)` → `error(text)`; R-`message(text)` → Zeile auf
   `SimLev.RParallel.r_stderr()` (sonst `stderr`), `suppressMessages` →
   `RParallel.suppress_messages`, `withCallingHandlers(message = )` →
   `RParallel.with_message_stream` (Fonds-Wrapper: Präfix der inneren Rechnung),
   nie `redirect_stderr`. Texte wortgleich.
9. Grafiken (SVG, ohne externe Pakete) müssen nicht bitgleich sein, aber
   dasselbe zeigen; berechnete Daten schon.

10. C-Bibliotheken nur über die zentrale Auswahl in `src/r/rnum.jl` (`_LIBM`,
    `_LIBC`, `_SNPRINTF`); nie Bibliotheksnamen fest eintragen.
11. Zeichenketten sortieren/vergleichen nur über `RStats.order`, `r_sort`,
    `r_rank`, `str_collate` (ICU-Kollation wie R, siehe `src/r/_collate.jl`).
12. Bedingungen als Text immer über `RExpr.eval_r` (R-Syntax), nie über
    Julia-`Meta.parse`.
13. data.frame-artige Eingaben am Funktionseingang mit `as_rframe`
    vereinheitlichen; plot-Methoden über `_plot_method` registrieren. Die
    Zeichenfunktion liefert `(svg, data)` (`data`: `RList` mit einem `RFrame`
    je Panel, dargestellte Werte nicht ausgedünnt und unskaliert); daraus wird
    `SimLevPlot(svg, data, x, klasse)`. Geschrieben wird nur mit
    `file = "….svg"`, unbekannte Schlüsselwörter ergeben eine Warnung.
    Zeichenbausteine nur aus `src/svg.jl` (siehe [Grafik](#grafik)).
14. long-double-Summen rechnen seit 1.2.0 die C-Kerne `core/slc_rbase*.c` (x87 wie R, kein Nachbau in
    Julia). In den geteilten Engine-Kernen gilt seit 1.2.0 die Regel „NA vor NaN“ (`core/simlev_core.h`).
    Zur Geschichte: treffen in `a + b` oder `a * b` zwei NaN
    aufeinander (NA und NaN), behält x86 den ersten Operanden der Anweisung,
    und LLVM darf die Operanden tauschen. Die Ports der nativen Kerne
    (Engine `core.jl`, `DependenceCore`, `OptimizeCore.quantile7`; bis 0.10.0 auch
    `BootstrapCore` und `RTruncnorm`) schreiben solche Stellen mit `nan_add`,
    `nan_mul` usw. (`src/r/rnum.jl`) in der Operandenfolge des R-Baus
    (objdump von `SimLev.so`; seit 0.10.0, gleich wie Python), längere
    Kerne rechnen bei einem NaN im Ergebnis Schritt für Schritt nach
    (`_hmm_nan`; bis 0.10.0 `_dcc_nan`, `_ms_garch_filter_nan`). `std::min`/`std::max`
    als `cpp_min`/`cpp_max` (NaN ergibt den ersten bzw. konstanten Operanden),
    nie Julias `min`/`max` (die NaN weitergeben); `x - y` statt `x += -y`
    (NaN-Vorzeichen). Wo die C++-Kerne
    `std::sort`/`std::nth_element` nutzen, bilden die Ports deren Verhalten aus libstdc++ (GCC 13)
    nach (`_std_sort!` in `dependence_core.jl`, `optimize_core.jl`; Herkunft in `COPYRIGHTS.md`).
15. Optionale R-Pakete gibt es nicht mehr: Seit 1.0.0 sind auch die Übernahmen (evd,
    imputeTS, stinepack, rugarch, Rsolnp, truncnorm) entfallen; ihre Aufgaben rechnet slc.
    `RBase.sys_time()` und `SIMLEV_R_SYS_TIME` (gosolnp) gibt es nicht mehr.

Keine externen Pakete; erlaubt ist nur die Standardbibliothek (`Dates`, `Printf`, `Logging`,
`Libdl`). Zum Bau (`Pkg.build`) braucht SimLev einen C-Compiler.

## Parallelität (`cores`)

`RParallel.par_lapply` (`src/r/parallel.jl`) ist die einzige Stelle, die
parallel rechnet (Aufrufer: `bootstrap`, `bootstrap_study`, `param_search`,
`sensitivity_grid`, `sensitivity_rebalancing`, `planning_lumpsum_vs_dca`,
`sensitivity_leverage`; `Bootstrap._par_lapply` und `ParamSearch._par_lapply`
leiten weiter). Semantik wie `parallel::mclapply(mc.preschedule = FALSE,
mc.set.seed = FALSE)` (Verhalten in R 4.3.3): unter
zwei Kernen oder mit höchstens einem Element `lapply`; sonst rechnet jede
Einheit mit dem Strom, den ihr der Aufrufer mitgibt (seit 1.0.0, Regeln unter [Zufall](#zufall); der globale Zustand
ist in einer Einheit gesperrt);
Ergebnisse in Eingangsreihenfolge; Warnungen gehen verloren; Meldungen und
Ausgaben erscheinen in Einheitenreihenfolge; beim ersten Fehler (in
Einheitenreihenfolge) erscheinen die Ausgaben davor, dann der Fehler. R
bündelt die Einheiten seit dem 26.10.2026 in höchstens `4 × cores` Pakete (ein
Fork je Paket) mit denselben Ergebnissen, demselben Zufallszustand und
denselben Fehlern.

Mit `Threads.nthreads() > 1` (`julia -t auto`, `julia -t 2`,
`JULIA_NUM_THREADS`) startet `par_lapply` `min(cores, nthreads)` Aufgaben
(`Threads.@spawn`), die sich die Einheiten der Reihe nach holen; mit einem
Thread rechnet `_sequential` nacheinander. Jede Einheit setzt den Merker `SLib.in_unit` und
bekommt einen eigenen Ausgabepuffer im task-lokalen Speicher (die frühere Kopie des
R-Zufallszustands über `RRng.with_state` ist mit 1.0.0 entfallen); Warnungen verwirft ein `NullLogger` je
Aufgabe. Referenzfälle zusätzlich mit `julia -t 2` prüfen.

**Regeln für neue Module (Thread-Sicherheit):**

1. Parallel nur über `par_lapply`, nie eigene Tasks oder Threads.
2. Keine veränderlichen globalen Zustände. Was eine Rechnung sich merken muss,
   gehört in lokale Variablen oder Argumente; Zustände, die für einen Aufruf gelten (Handler,
   Schalter), in den task-lokalen Speicher (`task_local_storage(f, key,
   wert)`, wie `_with_bounds_handler` in `src/optimize.jl`); einmalige
   Einrichtung (Bibliotheken laden, Tabellen) unter einer `ReentrantLock`
   und erst am Ende als fertig markieren (wie `_collate_init!`); Caches mit Sperre (wie `RFmt`/`rformat`, `RExpr`).
3. Zufall nur über `SLib` mit einem `Stream` als Argument (in einer Einheit nie der globale
   Zustand, siehe [Zufall](#zufall)).
4. Meldungen über `RParallel.r_stderr()`, Ausgaben einer Einheit über
   `RParallel.r_stdout()`; nie `redirect_stdout`/`redirect_stderr` in
   Paketcode (wirkt prozessweit). Direkte Schreibzugriffe auf `stdout`
   erscheinen in einer Aufgabe sofort statt in Einheitenreihenfolge.
5. Eingaben (data.frames, Strategien, `setup`) nicht verändern; Einheiten
   teilen sie. Ergebnisse gehören in den Rückgabewert, nicht in erfasste
   Variablen.
6. Eine neue Funktion mit `cores` braucht Referenzfälle mit `cores = 1` und
   `cores = 2`.

## Grafik

Alle Grafiken entstehen ohne externe Pakete als SVG. Alle Zeichenbausteine
stehen im Grafikmodul `src/svg.jl` (im Modul `SimLev`, eingebunden vor
`dashboard.jl` und den Untermodulen), dem Gegenstück zu
`python/simlev/svg.py`: gleiche Gliederung, gleiche Namen (Julias `name!`
heißt in Python `name`). Die Untermodule enthalten nur ihre
Zeichenfunktionen (`_plot_*`, `plot_SimLev*`) mit der Datenaufbereitung und
holen die Bausteine mit `using ..SimLev: …`; `dashboard.jl` hat die
Dashboard-Daten und die Panels. Abschnitte von `svg.jl`:

1. Grafikobjekt `SimLevPlot`.
2. Einheitliche Grafik-API: `_plot_method`, `_check_svg_file`,
   `_write_svg`, `_warn_unknown_kw`.
3. Gemeinsame Hilfen: `_esc` (Textschutz aller Stile), `r_pretty`,
   Farben (`_col2rgba`, `_svgcol`, `_alpha` …), Datumshilfen
   (`_MONATE_KURZ`, `_fmt_day`; `from_days`, `to_days`, `days_from_civil`
   aus `dates.jl`).
4. bis 9. je ein Grafikstil; ein Präfix je Stil, damit gleichnamige
   Bausteine mit anderem Aussehen nicht verwechselt werden:

| Abschnitt | Präfix | Bausteine (Auswahl) | Grafiken |
|---|---|---|---|
| 4. Stil Dashboard | – | `_Canvas`, `_Panel`, `_text!`, `_line!`, `_rect!`, `_polyline!`, `_area!`, `_frame!`, `_date_ticks`, `_yaxis` | `plot_dashboard`, `r_plot(<SimLevResult>)` |
| 5. Stil Analysegrafiken | `_ana_` | `_AnaSvg`, `_AnaPanel`, `_ana_panel`, `_ana_lines`, `_ana_hline`, `_ana_rect`, `_ana_text`, `_ana_points`, `_ana_legend`, `_ana_ramp`, `_ana_svg_done`, `_ana_year_ticks` | DeepAnalysis, AnalysisTests (Signal, Heatmap), Planning |
| 6. Stil Rastergrafiken | `_grid_` | `_GridBox`, `_grid_svg`, `_grid_axes!`, `_grid_lines!`, `_grid_bars!`, `_grid_scatter!`, `_grid_hline!`, `_grid_legend!`, `_grid_ticks` | Dependence (Abhängigkeit, Tail-Regression, CoVaR), Regimes |
| 7. Stil Ergebnisgrafiken | `_res_` | `_ResFig`, `_ResPanel`, `_res_fig`, `_res_panel`, `_res_line!`, `_res_points!`, `_res_rect!`, `_res_vline!`, `_res_hline!`, `_res_abline!`, `_res_legend!`, `_res_ramp`, `_res_finish` | Overfitting (PBO, Walk-Forward), ParamSearch, Sensitivity |
| 8. Stil Rückrechnung | `_bc_` | `_bc_doc`, `_bc_panel`, `_bc_esc` (ohne `"`) | Backcast |
| 9. Stil Allokationsgrafiken | `_alloc_` | `_alloc_ticks`, `_alloc_c`, `_alloc_ramp` | Optimize (Gewichte, Effizienzgrenze), Tactical (Zielgewichte) |

10. Zahlen wie in Julia: nur in Python nötig (Nachbildung von `string`,
    `round`, `@sprintf`, `10.0^k`, `log10` …); hier nur ein Verweis.

Die Grafiken von Withdrawal und Bootstrap entstehen direkt in der
Zeichenfunktion.
Ein neuer Baustein kommt in den Abschnitt seines Stils (mit dessen Präfix)
und zugleich nach `python/simlev/svg.py`.

## Referenzfälle und Prüfung

Die Referenzfälle liegen seit 1.4.1 im Ordner `tests/` des Repositorys (Katalog
[`tests/README.md`](../tests/README.md)); frische Fälle erzeugt und vergleicht die
Gleichlaufprüfung `tests/werkzeuge/gleichlauf/run.sh`, die nach jeder Änderung an der Rechenlogik
läuft.

Die Referenzfälle unter `tests/<gruppe>/faelle/<bereich>.jsonl.gz` erzeugen die Generatoren
`tests/gleichlauf/erzeugen/<bereich>.R`. Jeder Aufruf `ref_case(id, r = …, py = …,
jl = …)` trägt R-, Python- und Julia-Code; der Julia-Code setzt `result`
und sieht die Eingaben als Variablen (siehe `tests/lib/faelle.jl`, `decode`).

``` bash
julia --project=julia tests/werkzeuge/gleichlauf/vergleich.jl [datei.jsonl.gz …] [-k id] [-v]
julia --project=julia -t 2 tests/werkzeuge/gleichlauf/vergleich.jl          # dasselbe mit zwei Threads (cores = 2 echt parallel)
julia --project=julia tests/werkzeuge/gleichlauf/vergleich.jl [ordner …] [-k fall]   # ohne Pfad: der Katalog tests/<gruppe>/faelle
julia --project=julia tests/run.jl         # alle Fälle des Katalogs, Schnittstelle, Grafik
```

Verglichen wird ohne Toleranz: NA ≠ NaN, Vorzeichen der Null, Druck- und
Konsolenausgabe, Warnungen und Fehlermeldungen. Bei der Entwicklung spart
`SIMLEV_SKIP_PRECOMPILE=1` die Vorkompilier-Arbeitslast.

Die Arbeitslast in `src/precompile.jl` deckt die Engine (`simulation()` über
den C++-Kern mit und ohne `details`, Ausgabe, Dashboard, Fonds-Wrapper,
`calculate_dates_flags`, `xirr_rate`) und je Erweiterungsmodul die
öffentlichen Hauptfunktionen mit kleinen Daten ab, Daten wie beim Aufrufer
(NamedTuple mit `date` und Kursen). Methoden, die die Arbeitslast nur über
Laufzeit-Dispatch erreicht und deren Signatur nur Typen aus Base, Core,
Dates oder Printf enthält, übernimmt Julia nicht in den Cache;
`src/precompile_statements.jl` nennt sie ausdrücklich (aus
`--trace-compile` der ersten Aufrufe, ohne die Typen der Daten des
Aufrufers, ohne Closures). Bis 1.3.0 deckte die Arbeitslast nur Engine,
`bootstrap`, `bootstrap_study`, `_ms_garch_fit`, Entnahme ohne Steuer,
Optimierung auf Renditematrizen und `result_analysis` ab.
Gemessen auf zwei Kernen, Julia 1.13.2, eigenes Depot; erster Aufruf je
Aufgabe in einem frischen Prozess (die Bench-Aufgaben aus `tests/werkzeuge/bench`
und je Modul eine weitere Hauptfunktion, 30 Aufgaben):

| | vorher (Arbeitslast wie bis 1.3.0) | 1.4.0 |
|---|---|---|
| Vorkompilieren (`Base.compilecache`) | 145 s | 240 s |
| Cache (`.so` / `.ji`) | 78,0 / 1,6 MB | 118,1 / 1,6 MB |
| `using SimLev` | 0,41 s | 0,60 s |
| erster Aufruf S30 / T3 / T5 / T4s (`tests/werkzeuge/bench`) | 0,8 / 1,7 / 5,0 / 3,0 s | 0,24 / 0,82 / 0,47 / 0,18 s |
| erster Aufruf, höchster Übersetzungsanteil | 5,7 s (`regime_hmm`) | 0,7 s (`bootstrap_study`) |
| Summe der ersten Aufrufe (30 Aufgaben) | 84 s | 12 s |

Jede Hauptfunktion braucht beim ersten Aufruf damit höchstens etwa 1 s; was
bleibt, übersetzt Julia für die Typen des Aufrufers (die Eingangsfunktion
für eine NamedTuple mit anderen Spaltennamen, die Schlüsselwörter jenseits
der ersten 32 Argumente des Rumpfs von `_simulation_flat`, die
`@nospecialize` nicht mehr erfasst) und für Closures. Der Preis: rund 95 s
mehr Vorkompilieren nach jeder Änderung am Paket und 40 MB mehr Cache; bei
der Entwicklung spart `SIMLEV_SKIP_PRECOMPILE_EXT=1` den Teil der
Erweiterungen. Neue Hauptfunktionen gehören in die Arbeitslast; fehlen nach
einer Änderung Methoden im Cache, zeigt `julia --trace-compile=stderr
--trace-compile-timing` beim ersten Aufruf, welche.

Was ein Referenzfall bitgleich prüft, steht nicht noch einmal als eigener Test.

## Eingefrorene Schnittstelle

Die öffentliche Schnittstelle ist in `tests/schnittstelle/frozen/jl.json`
festgehalten (seit 0.9.0): je Export aus `names(SimLev)` und je registrierter
`show`/`r_summary`/`r_plot`-Methode die Argumente der Hauptmethode in
Reihenfolge mit Art (`positional`, `keyword`, `varargs`, `kwargs_rest`) und
Standardwert aus dem Quelltext, dazu die Namen der exportierten Typen; ohne
Datei, Zeile, Modul und Datum. `tests/schnittstelle/api.jl` (in `tests/run.jl`)
lädt dafür den Auszug `tests/schnittstelle/api_jl.jl` in ein eigenes Modul,
ruft `frozen_check` im Testprozess auf und nennt bei Abweichung jede Änderung
(Funktion neu oder weg, Argument neu, weg oder umsortiert, Art oder
Standardwert geändert).

Eine gewollte Änderung der Schnittstelle wird bewusst neu festgeschrieben:
Eintrag oben in `tests/schnittstelle/CHANGES.md` (Datum, was sich ändert,
warum), dann aus der Repo-Wurzel `tests/schnittstelle/run.sh --freeze`; das
schreibt `frozen/` für alle drei Sprachen neu und bricht ohne neuen Eintrag
ab. Einzelheiten in [`tests/schnittstelle/README.md`](../tests/schnittstelle/README.md).

## Schalter `SIMLEV_*`

Alle Umgebungsschalter liest (und setzt) nur `src/r/env.jl` (`SimLev.REnv`);
Paket, Vorkompilierung, Tests und Werkzeuge holen sie von dort
Wann gelesen wird, bestimmt die
aufrufende Stelle: `tests/lib/faelle.jl` beim Laden, die Kollation beim ersten
Vergleich (neu nach `RStats.collate_reset()`), `precompile.jl` beim
Vorkompilieren.

| Schalter | Zweck | Art |
|---|---|---|
| `SIMLEV_COLLATE` | Sortierung: `icu:<Locale>` (`icu:root` wie R unter C.UTF-8) oder `C` (Bytes); ohne Angabe nach `LC_ALL`/`LC_COLLATE`/`LANG` | Nutzer |
| `SIMLEV_ICU` | Pfad zur ICU-Bibliothek (`libicui18n`) | Nutzer |
| `SIMLEV_LAX_NA` | `1`: NA = NaN im Vergleich (`tests/lib/faelle.jl`) | Prüfung |
| `SIMLEV_STRICT_ZERO` | `0`: −0 = +0 im Vergleich (`tests/lib/faelle.jl`) | Prüfung |
| `SIMLEV_FAELLE_DIR` | anderer Ordner der Bereichsdateien für `tests/run.jl` (seit 1.4.1; `SIMLEV_FULL_TESTS`, `SIMLEV_GOLDEN_DIR` und `SIMLEV_MODULE_DIR` entfallen seit 1.4.2) | Prüfung |
| `SIMLEV_SKIP_PRECOMPILE` | `1`: keine Arbeitslast beim Vorkompilieren | Entwicklung |
| `SIMLEV_SKIP_PRECOMPILE_EXT` | `1`: Arbeitslast ohne die Analysemodule | Entwicklung |
| `SIMLEV_CC` | C-Compiler für `Pkg.build` (gelesen in `deps/build.jl`) | Bau |

Seit 1.0.0 entfallen `SIMLEV_LAPACK` und `SIMLEV_R_SYS_TIME`.

`tests/lib/faelle.jl` setzt `SIMLEV_COLLATE=icu:root`, falls nicht gesetzt (die
Referenzen entstanden unter C.UTF-8). Die Generatoren in `tests/gleichlauf/erzeugen/`
lesen eigene Schalter (`SIMLEV_R_NMATH_SRC`, `SIMLEV_ALLOW_PARTIAL`, siehe
`tests/README.md`).

## C-Bibliothek (Pflicht)

Zufall, Verteilungen, lineare Algebra, Optimierer, GARCH/GJR, GPD, DCC, MS-GARCH, die
Bootstrap-Kerne, Stineman, Glättungsspline und Kerndichte rechnet die C-Bibliothek slc (seit
1.0.0). `deps/build.jl` (läuft bei `Pkg.build`/`Pkg.add`) übersetzt `deps/core/*.c` mit
`-std=c99 -O2 -fPIC -ffp-contract=off -fno-fast-math` zu `deps/usr/lib/libslc` und schreibt
`deps/deps.jl`; der C-Compiler kommt aus `SIMLEV_CC`, sonst `cc`, `gcc` oder `clang`, der
C++-Compiler aus `SIMLEV_CXX`, sonst `c++`, `g++` oder `clang++`. Ohne Bibliothek
bricht `using SimLev` mit einer Meldung ab, die `Pkg.build("SimLev")` mit C-Compiler verlangt. Die
Hüllen stehen in `src/slib*.jl` (`SimLev.SLib`, `ccall`, Fehler über den Kontext `sl_ctx`).

**Ort der Quellen (`core/`):** kanonisch in `core/` (nur dort ändern); Kopien
der slc-Dateien liegen in `julia/deps/core/`, `r/src/` und `python/src/core/`. Die geteilten
C++-Kerne (`core/simlev_core.h`, `core/*_core_impl.h`: Engine, FIFO, Steuer, Research, Entnahme)
liegen seit 1.0.0 ebenfalls in `core/` und werden seit 1.2.0 auch nach `julia/deps/core/` kopiert, dazu
ihre C-ABI-Hülle `core/simlev_cabi.cpp` (nur Julia). `deps/build.jl` übersetzt sie mit dem
C++-Compiler (Schalter wie Python: `-O2 -std=gnu++17 -ffp-contract=off -fno-fast-math`,
`SIMLEV_FP_CONTRACT_BY_FLAG`) in `libslc`; `src/cabi.jl` (Modul `CAbi`) wertet die Rückgabecodes aus,
die Aufrufe stehen in `core.jl`, `signals_core.jl`, `withdrawal_core.jl`, `dependence_core.jl` und
`optimize_core.jl` (die früheren eigenen Ports sind entfallen).
`core/sync.py --write` kopiert, `--check` vergleicht alle Kopien per SHA-256 (Ende 1 bei
Abweichung) und läuft in jeder Gleichlaufprüfung.

## Zufall

Den globalen Zustand hält `SLib` prozessweit mit `ReentrantLock`; alle Ziehungen rechnet die
C-Bibliothek (xoshiro256**, SplitMix64, Ströme über Sprünge um 2^128). Regeln wie in R und Python: `simlev_seed(seed)` setzt den Zustand (ganze Zahl, |seed| < 2^53; ohne Argument aus
Uhrzeit, Prozessnummer und Zähler); `seed = nothing` an einer zufälligen Funktion zieht genau
einmal k aus dem Zustand und rechnet wie mit `seed = k`; `seed = s` lässt ihn unberührt
(Hauptstrom `SLib.main_stream(s)`); Einheiten von `par_lapply` bekommen ihre Ströme
`SLib.streams` vor der Verteilung, das Ergebnis hängt nicht von `cores` oder `julia -t` ab. Die
Nachbildung von R's Zufall (`RRng`, Exporte `set_seed`/`rng_kind`) ist mit 1.0.0 entfallen.

## Tests

Die Tests stehen in `tests/` (siehe [Bauen, Vorkompilieren, Abgleich und
Tests](#bauen-vorkompilieren-abgleich-und-tests)): `julia --project=julia tests/run.jl [gleichlauf
fehler ausgabe schnittstelle]` prüft gegen die Referenzfälle aus R. Dazu kommt die
Gleichlaufprüfung `tests/werkzeuge/gleichlauf/run.sh` (siehe
[`python/DEVELOPING.md`](../python/DEVELOPING.md#tests)).

## Schichten

Die Dateien in `src/` gehören zu fünf Schichten: 0 R-Interna (`src/r/`), 1 Daten und Strategie
(`dates.jl`, `config.jl`, `trigger.jl`, `data.jl`, `tax_tariff.jl`,
`data_prep.jl`, `backcast.jl`, `bonds.jl`, `signals*.jl`), 2 Engine
(`core.jl`, `result.jl`, `engine.jl`, `sim_*.jl`, `wrapper.jl`), 3 Analysen (je eine Datei
mit ihrem Kern), 4 Ausgabe (`svg.jl`, `dashboard.jl`); `SimLev.jl`,
`exports.jl` und `precompile.jl` sind die Paketebene. Keine Datei greift
auf eine höhere Schicht zu; Ausnahmen sind vor allem die plot-Methoden der
Analysen, die die Grafikbausteine aus `svg.jl` holen.
