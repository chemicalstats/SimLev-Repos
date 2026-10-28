# Entwicklung der Julia-Fassung

Die Julia-Fassung ist ein bitgleicher Port des R-Pakets SimLev 0.5.0 (Ordner
`r/`) und rechnet dieselben IEEE-754-Zahlen wie R und die Python-Fassung
(`python/`). Maßgeblich ist der R-Code; die Python-Fassung ist ein bereits
bitgleich geprüfter Zwischenschritt, der die Rechenreihenfolge von R
nachbildet und sich als Vorlage für die Übersetzung eignet.

> **Stand Etappe 9:** Zufall und Numerik rechnet die eigene C-Bibliothek slc (Abschnitte
> [C-Bibliothek](#c-bibliothek-pflicht), [Zufall](#zufall-etappe-9) und
> [Tests in Etappe 9](#tests-in-etappe-9)). `src/r/` bildet nur noch Grundfunktionen von R nach
> (Liste und Herkunft in [`COPYRIGHTS.md`](COPYRIGHTS.md)); `RRng`, `RNmath`, die
> BLAS/LAPACK/LINPACK-Ports, `optim`/`nlminb` und die früher übernommenen Pakete gibt es nicht
> mehr.

## Aufbau

Alles liegt im Modul `SimLev`; die Bausteine sind Untermodule. Die Tabelle
folgt der Reihenfolge der `include`s in `src/SimLev.jl`: erst die R-Interna
(`src/r/`), dann die Engine, das Grafikmodul `svg.jl` und das Dashboard,
dann die Module (C++-Kerne jeweils vor ihrem Modul), zuletzt `exports.jl`
und `precompile.jl`.

| Datei | Untermodul | Inhalt (R-Vorlage → Python-Vorlage) |
|---|---|---|
| `src/r/env.jl` | `REnv` | Umgebungsschalter `SIMLEV_*`: einzige Stelle, die sie liest oder setzt (siehe [Schalter](#schalter-simlev_)) → `_r/env.py` |
| `src/slib.jl` (+ `slib_linalg.jl`, `slib_opt.jl`, `slib_models.jl`) | `SLib` | Hüllen der C-Bibliothek slc per `ccall` (Zufall, Verteilungen, lineare Algebra, Optimierer, Modelle, Bootstrap-Kerne); Bibliothek aus `deps/build.jl` (siehe [C-Bibliothek](#c-bibliothek-pflicht)) → `simlev/_lib*.py` |
| `src/r/types.jl` | – | R-Datenstrukturen (`RList`, `RFrame`, `RVector`, `NamedMat`), Druck-/summary-/plot-Registrierung |
| `src/r/ld80.jl` | – | `F80`: 80-Bit-`long double` (x86-64: x87-Hardware über `llvmcall`, sonst Software-Nachbau `F80Soft`) |
| `src/r/rnum.jl` | – | `NA`, `isna_strict`, Summen/Mittel/Varianz in `long double` (`r_sum`, `r_mean`, …), `r_pow` (`R_POW`), `r_uniroot`, zentrale Auswahl der C-Bibliotheken (`_LIBM`, `_LIBC`, `_SNPRINTF`) → `_r/rnum.py` |
| `src/r/rformat.jl` | – | Textausgabe der Engine: `r_sprintf` (NA/NaN/Inf wie R), `r_format`, `r_as_character`, `r_deparse`, `r_round`, `r_signif` → `_r/rformat.py` |
| `src/r/libm.jl` | `RLibm` | glibc-libm (`exp`, `log`, `log1p`, `expm1`, `pow`, `tanh`, …) → `_r/libm.py` |
| `src/r/base.jl` | `RBase` | Summen, Mittel, `cumsum`, `cumprod`, `rowSums`, … mit `long double` → `_r/base.py` |
| `src/r/parallel.jl` | `RParallel` | `.par_lapply` mit `Threads.@spawn` (`par_lapply`), Meldungen und Ausgaben je Aufgabe (`r_stderr`, `r_stdout`, `suppress_messages`), siehe [Parallelität](#parallelität-cores) → `_r/parallel.py` |
| `src/r/fmt.jl` | `RFmt` | `format`, `formatC`, `sprintf`, `round`, `signif`, `print` von Vektoren/Matrizen/data.frames → `_r/fmt.py` |
| `src/r/stats.jl` | `RStats` | Modulkopf mit Exporten; bindet die Themen ein (gleiche Namen wie in Python): `stats_sort.jl` (Hilfen, `order`, `r_sort`, `r_rank`, `cut`, `quantile`, `median`, …), `stats_cor.jl` (`cor`, `cov`, `var`, `scale`), `stats_smooth.jl` (`approx`, `r_filter`), `stats_optim.jl` (`optimize`, `uniroot`), `stats_models.jl` (`coef`, `fitted`, `p_adjust`, `ecdf`, `ave`, `aggregate`), `stats_cluster.jl` (`dist`, `hclust`) → `_r/stats.py` (Sammelmodul) und `_r/stats_*.py` |
| `src/r/linalg.jl` | `RLinalg` | `outer`, `diag`, `is_symmetric`, `all_equal_numeric` (seit 9.6c ohne `matprod`, `solve`, `chol`, `qr`, `eigen` und die BLAS/LAPACK/LINPACK-Ports) → `_r/linalg.py` |
| `src/r/rexpr.jl` | `RExpr` | Ausdrücke in R-Syntax als Text (`eval(parse(text = …), data, env)`): ein gemeinsamer Auswerter für Bedingungen in `bootstrap_probability`, `regime_subset`, `view_prob`/`scenario_entropy_pooling` und `tactical_rules` (R-Vorrang inkl. schwach bindendem `!`, NA-Logik, `%in%`, `%%`, Funktionen über `RLibm`/`RFmt`) |
| `src/engine.jl` u. a. | – | `simulation()` und Strategie/Config: `engine.jl` (Hilfen, Handels- und Steuerfunktionen; r/R/sim_base.R → `_sim_base.py`), `sim_phases.jl` (r/R/sim_validate.R, sim_prepare.R → `_sim_phases.py`), `sim_loop.jl` (r/R/sim_actions.R, sim_loop.R → `_sim_loop.py`), `sim_evaluate.jl` (r/R/sim_evaluate.R → `_sim_evaluate.py`; dazu `simulation()` und `_simulation_flat()` aus r/R/simulation.R → `engine.py`), `sim_blocks.jl` (Bausteine, r/R/sim_blocks.R → `_sim_blocks.py`), `wrapper.jl` (Fonds-Wrapper `wrapper_config`, `wrapper_nav`, Anteilswert `_wrapper_nav_calc`, r/R/wrapper.R → `wrapper.py`; Hilfen der Strategie `_strategy_columns`, `_strategy_wrappers` in `config.jl`) |
| `src/svg.jl` | – | Grafikmodul: `SimLevPlot`, `_plot_method` & Co., alle SVG-Zeichenbausteine (siehe [Grafik](#grafik)) → `simlev/svg.py` |
| `src/dashboard.jl` | – | Dashboard-Daten und Panels, `plot_dashboard`, `export_dashboard` (r/R/plot_dashboard.R) → `dashboard.py` |
| `src/<modul>.jl` | `DataPrep`, `Backcast`, `Bonds`, `Signals`, `Bootstrap`, `Withdrawal`, `Dependence`, `Regimes`, `MsGarch`, `Scenarios`, `Optimize`, `Tactical`, `DeepAnalysis`, `Planning`, `AnalysisTests`, `Overfitting`, `ParamSearch`, `Sensitivity` | je eine R-Datei `r/R/<modul>.R` → `python/simlev/<modul>.py` |
| `src/<name>_core.jl` | `SignalsCore`, `WithdrawalCore`, `DependenceCore`, `OptimizeCore` | eigene Ports der geteilten C++-Kerne aus `core/` (F2; Python ruft sie als C-Erweiterung) → `python/simlev/_<name>_core.py`; `BootstrapCore` und der Port des DCC-Filters sind mit 9.6c entfallen |
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
   `RBase.r_sum`, `r_mean`, `r_cumsum`, `r_prod`, `r_var` usw. (über `F80`).
   Wo C++ mit `double` sequenziell summiert, eine einfache Schleife.
3. **Nie `exp`, `log`, `log1p`, `expm1`, `^`, `tanh`, `sin`, … aus Base** auf
   Float64: Julia rechnet sie selbst, R nutzt glibc-libm. Immer `RLibm.*`
   (auch beim Broadcasting: `RLibm.exp.(x)`); `x^2` ist in R `x*x`, sonst
   `RLibm.pow` (R's `R_POW`-Regeln, siehe `src/r/rnum.jl`). `sqrt`, `abs`, `floor`,
   `ceil`, `+ - * /` sind exakt. Kein `muladd`/`fma`, kein `@fastmath`.
4. **Keine Matrixprodukte mit `*`** (OpenBLAS): Matrixprodukte, Cholesky, Löser, Eigenwerte und
   QR kommen wie in R aus der C-Bibliothek (`SLib.matmul`, `crossprod`, `chol`, `eigen_sym`, …;
   seit 9.6b/9.6c, keine System-LAPACK mehr).
5. Sortieren, Runden und Formatieren immer über `RStats`/`RFmt` (R's
   Sortierverfahren bei Gleichständen und ±0, R's `round`-Algorithmus,
   C-`printf` für Zahlen).
6. Zufall nur über `SLib` (Zustand von SimLev bzw. ein `SLib.Stream`, siehe
   [Zufall](#zufall-etappe-9)); `RRng` ist mit 9.6c entfallen.
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
14. long-double-Summen laufen auf x86-64 über die x87-Hardware; ist das
    Ergebnis NaN, rechnen `r_sum` & Co. mit `F80Soft` nach, weil R's
    NA/NaN-Vorrang sonst vom erzeugten Maschinencode abhinge.
    Dasselbe gilt für double: treffen in `a + b` oder `a * b` zwei NaN
    aufeinander (NA und NaN), behält x86 den ersten Operanden der Anweisung,
    und LLVM darf die Operanden tauschen. Die Ports der nativen Kerne
    (Engine `core.jl`, `DependenceCore`, `OptimizeCore.quantile7`; bis 9.6c auch
    `BootstrapCore` und `RTruncnorm`) schreiben solche Stellen mit `nan_add`,
    `nan_mul` usw. (`src/r/rnum.jl`) in der Operandenfolge des R-Baus
    (objdump von `SimLev.so`; seit Etappe 8.0, gleich wie Python), längere
    Kerne rechnen bei einem NaN im Ergebnis Schritt für Schritt nach
    (`_hmm_nan`; bis 9.6c `_dcc_nan`, `_ms_garch_filter_nan`). `std::min`/`std::max`
    als `cpp_min`/`cpp_max` (NaN ergibt den ersten bzw. konstanten Operanden),
    nie Julias `min`/`max` (die NaN weitergeben); `x - y` statt `x += -y`
    (NaN-Vorzeichen). Feste Randfälle in `test/nan_kerne_tests.jl`. Wo die C++-Kerne
    `std::sort`/`std::nth_element` nutzen, bilden die Ports deren Verhalten aus libstdc++ (GCC 13)
    nach (`_std_sort!` in `dependence_core.jl`, `optimize_core.jl`; Herkunft in `COPYRIGHTS.md`).
15. Optionale R-Pakete gibt es nicht mehr: Seit Etappe 9.6c sind auch die Übernahmen (evd,
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
mc.set.seed = FALSE)` (Verhalten in R 4.3.3 ermittelt in Etappe 5): unter
zwei Kernen oder mit höchstens einem Element `lapply`; sonst rechnet jede
Einheit mit dem Strom, den ihr der Aufrufer mitgibt (seit 9.6a, Regeln C.5; der globale Zustand
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
R-Zufallszustands über `RRng.with_state` ist mit 9.6a/9.6c entfallen); Warnungen verwirft ein `NullLogger` je
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
   Zustand, siehe [Zufall](#zufall-etappe-9)).
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

> Seit Etappe 9 ausgesetzt (siehe [Tests in Etappe 9](#tests-in-etappe-9)): Die gespeicherten
> Fälle beschreiben den Stand vor dem eigenen Zufall und den eigenen Kernen. Generatoren und
> Vergleicher unten gelten weiter; frische Fälle erzeugt und vergleicht die Gleichlaufprüfung
> `tools/gleichlauf/run.sh`, die nach jeder Änderung an der Rechenlogik läuft.

Die Referenzfälle unter `golden/modules/<modul>/` erzeugen die Generatoren
`golden/modules/gen_<modul>.R`. Jeder Aufruf `ref_case(id, r = …, py = …,
jl = …)` trägt R-, Python- und Julia-Code; der Julia-Code setzt `result`
und sieht die Eingaben als Variablen (siehe `test/reftree.jl`, `decode`).

``` bash
julia --project=julia julia/tools/compare_reference.jl [modul …] [-k id] [-v]
julia --project=julia -t 2 julia/tools/compare_reference.jl          # dasselbe mit zwei Threads (cores = 2 echt parallel)
julia --project=julia julia/tools/compare_golden.jl [ordner …] [-k fall …]   # ohne Pfad: golden/cases und golden/extra
julia --project=julia -e 'using Pkg; Pkg.test()'      # Referenzfälle: Auswahl; alle mit SIMLEV_FULL_TESTS=1
```

Verglichen wird ohne Toleranz: NA ≠ NaN, Vorzeichen der Null, Druck- und
Konsolenausgabe, Warnungen und Fehlermeldungen. Bei der Entwicklung spart
`SIMLEV_SKIP_PRECOMPILE=1` die Vorkompilier-Arbeitslast.

Die Arbeitslast in `src/precompile.jl` deckt nur häufige Wege ab: Engine,
`bootstrap` (stationär und `"garch"`, seit 9.6b über die ML-Schätzung in slc),
`bootstrap_study`, `_ms_garch_fit`, Entnahme, Optimierung und
`result_analysis` (Etappe 4.8; gemessen auf zwei Kernen, Julia 1.13.2):

| | vorher | nachher |
|---|---|---|
| `using SimLev` nach einer Codeänderung (mit Vorkompilieren) | 316 s | 279 s |
| ohne Arbeitslast (`SIMLEV_SKIP_PRECOMPILE=1`) | 21 s | 21 s |
| Cache (`.so`) | 130,0 MB | 107,9 MB |
| erster Lauf S30 / T2 / T8 (`tools/bench`) | 1,6 / 10,6 / 6,0 s | 1,5 / 0,4 / 0,4 s |
| erster Lauf T5 (`dependence_analysis` mit DCC) | 2,1 s | 7,9 s |
| Summe Vorkompilieren + erste Läufe aller Aufgaben | 340 s | 292 s |

Seltene Wege (Parametersuche, Abhängigkeiten, Szenarien, Sensitivitäten,
Taktik, Planung, `series_align`) übersetzt ihr erster Aufruf; deshalb
braucht der Testteil von `Pkg.test()`, der alle Module berührt, rund 50 s
mehr (315 statt 265 s), sodass Vorkompilieren plus `Pkg.test()` nach einer
Änderung etwa gleich lang bleibt (594 statt 581 s). Ein neuer
Baustein lohnt sich nur, wenn sein Weg häufig ist: Jeder kostet bei jeder
Änderung am Paket Vorkompilierzeit.

Was ein Referenzfall bitgleich prüft, steht nicht noch einmal als Test in
`test/` (Etappe 4.1); so stehen die konstanten Ausdrücke, die
`golden/modules/rexpr` wörtlich prüft, nicht mehr in `rexpr_tests.jl`.

## Eingefrorene Schnittstelle

Die öffentliche Schnittstelle 0.5.0 ist in `tools/api_snapshot/frozen/jl.json`
festgehalten (Etappe 6.6): je Export aus `names(SimLev)` und je registrierter
`show`/`r_summary`/`r_plot`-Methode die Argumente der Hauptmethode in
Reihenfolge mit Art (`positional`, `keyword`, `varargs`, `kwargs_rest`) und
Standardwert aus dem Quelltext, dazu die Namen der exportierten Typen; ohne
Datei, Zeile, Modul und Datum. `test/api_frozen_tests.jl` (in `runtests.jl`)
lädt dafür den Auszug `tools/api_snapshot/api_jl.jl` in ein eigenes Modul,
ruft `frozen_check` im Testprozess auf und nennt bei Abweichung jede Änderung
(Funktion neu oder weg, Argument neu, weg oder umsortiert, Art oder
Standardwert geändert).

Eine gewollte Änderung der Schnittstelle wird bewusst neu festgeschrieben:
Eintrag oben in `tools/api_snapshot/CHANGES.md` (Datum, was sich ändert,
warum), dann aus der Repo-Wurzel `tools/api_snapshot/run.sh --freeze`; das
schreibt `frozen/` für alle drei Sprachen neu und bricht ohne neuen Eintrag
ab. Einzelheiten in [`tools/api_snapshot/README.md`](../tools/api_snapshot/README.md).

## Schalter `SIMLEV_*`

Alle Umgebungsschalter liest (und setzt) nur `src/r/env.jl` (`SimLev.REnv`);
Paket, Vorkompilierung, Tests und Werkzeuge holen sie von dort
(`test/layers_tests.jl` prüft das). Wann gelesen wird, bestimmt die
aufrufende Stelle: `test/reftree.jl` beim Laden, die Kollation beim ersten
Vergleich (neu nach `RStats.collate_reset()`), `precompile.jl` beim
Vorkompilieren.

| Schalter | Zweck | Art |
|---|---|---|
| `SIMLEV_COLLATE` | Sortierung: `icu:<Locale>` (`icu:root` wie R unter C.UTF-8) oder `C` (Bytes); ohne Angabe nach `LC_ALL`/`LC_COLLATE`/`LANG` | Nutzer |
| `SIMLEV_ICU` | Pfad zur ICU-Bibliothek (`libicui18n`) | Nutzer |
| `SIMLEV_LAX_NA` | `1`: NA = NaN im Vergleich (`reftree.jl`) | Prüfung |
| `SIMLEV_STRICT_ZERO` | `0`: −0 = +0 im Vergleich (`reftree.jl`) | Prüfung |
| `SIMLEV_FULL_TESTS` | `1`: `Pkg.test()` prüft alle Modul-Fälle statt bis zu vier je Modul | Prüfung |
| `SIMLEV_GOLDEN_DIR` | anderer Wurzelordner der Engine-Fälle (`cases/`, `extra/`) für `Pkg.test()` | Prüfung |
| `SIMLEV_SKIP_PRECOMPILE` | `1`: keine Arbeitslast beim Vorkompilieren | Entwicklung |
| `SIMLEV_SKIP_PRECOMPILE_EXT` | `1`: Arbeitslast ohne die Analysemodule | Entwicklung |
| `SIMLEV_LEGACY_TESTS` | `1`: alte Tests und Referenzvergleiche laufen (Etappe 9: sonst ausgesetzt, siehe [Tests in Etappe 9](#tests-in-etappe-9)) | Prüfung |
| `SIMLEV_MODULE_DIR` | anderer Ordner der Modul-Fälle (`compare_reference.jl`, Gleichlauf) | Prüfung |
| `SIMLEV_CC` | C-Compiler für `Pkg.build` (gelesen in `deps/build.jl`) | Bau |

Seit Etappe 9.6c (Entwurf C.6 Nr. 10) entfallen `SIMLEV_LAPACK` und `SIMLEV_R_SYS_TIME`.

`reftree.jl` setzt `SIMLEV_COLLATE=icu:root`, falls nicht gesetzt (die
Referenzen entstanden unter C.UTF-8). Die Generatoren in `golden/modules/`
lesen eigene Schalter (`SIMLEV_R_NMATH_SRC`, `SIMLEV_ALLOW_PARTIAL`, siehe
`golden/README.md`).

## C-Bibliothek (Pflicht)

Zufall, Verteilungen, lineare Algebra, Optimierer, GARCH/GJR, GPD, DCC, MS-GARCH, die
Bootstrap-Kerne, Stineman, Glättungsspline und Kerndichte rechnet die C-Bibliothek slc (Etappe
9.1–9.6c). `deps/build.jl` (läuft bei `Pkg.build`/`Pkg.add`) übersetzt `deps/core/*.c` mit
`-std=c99 -O2 -fPIC -ffp-contract=off -fno-fast-math` zu `deps/usr/lib/libslc` und schreibt
`deps/deps.jl`; der Compiler kommt aus `SIMLEV_CC`, sonst `cc`, `gcc` oder `clang`. Ohne Bibliothek
bricht `using SimLev` mit einer Meldung ab, die `Pkg.build("SimLev")` mit C-Compiler verlangt. Die
Hüllen stehen in `src/slib*.jl` (`SimLev.SLib`, `ccall`, Fehler über den Kontext `sl_ctx`).

**Ort der Quellen (`core/`, Entwurf C.1, F16):** kanonisch in `core/` (nur dort ändern); Kopien
der slc-Dateien liegen in `julia/deps/core/`, `r/src/` und `python/src/core/`. Die geteilten
C++-Kerne von R und Python (`core/simlev_core.h`, `core/*_core_impl.h`: Engine, FIFO, Steuer,
Research, Entnahme) liegen seit 9.6c ebenfalls in `core/`, werden aber nur nach `r/src/` und
`python/src/core/` kopiert: Julia behält seine eigenen Ports dieser Kerne (F2; `core.jl`,
`signals_core.jl`, `withdrawal_core.jl`, `dependence_core.jl`, `optimize_core.jl`).
`tools/core_sync.py --write` kopiert, `--check` vergleicht alle Kopien per SHA-256 (Ende 1 bei
Abweichung) und läuft in jeder Gleichlaufprüfung.

## Zufall (Etappe 9)

Den globalen Zustand hält `SLib` prozessweit mit `ReentrantLock` (F3); alle Ziehungen rechnet die
C-Bibliothek (xoshiro256**, SplitMix64, Ströme über Sprünge um 2^128). Regeln wie in R und Python
(Entwurf C.5): `simlev_seed(seed)` setzt den Zustand (ganze Zahl, |seed| < 2^53; ohne Argument aus
Uhrzeit, Prozessnummer und Zähler); `seed = nothing` an einer zufälligen Funktion zieht genau
einmal k aus dem Zustand und rechnet wie mit `seed = k`; `seed = s` lässt ihn unberührt
(Hauptstrom `SLib.main_stream(s)`); Einheiten von `par_lapply` bekommen ihre Ströme
`SLib.streams` vor der Verteilung, das Ergebnis hängt nicht von `cores` oder `julia -t` ab. Die
Nachbildung von R's Zufall (`RRng`, Exporte `set_seed`/`rng_kind`) ist mit 9.6c entfallen.

## Tests in Etappe 9

Die alten Tests sind bis zum Neuaufbau ausgesetzt (Entwurf C.7); keine Datei wird gelöscht.
`test/runtests.jl` führt ohne `SIMLEV_LEGACY_TESTS=1` nur den Testsatz „Etappe 9“ aus (die
Rauchproben `test/etappe9*.jl`) und lädt die übrigen Dateien nicht. Mit dem Schalter laufen alle
alten Tests; Dateien, die entfallene Module nutzen (`RRng`, `RNmath`, `RLinalg`-Teile,
`BootstrapCore` …, etwa `ms_garch_tests.jl`, `nan_kerne_tests.jl`, `parallel_tests.jl`), scheitern
dann erwartungsgemäß. `tools/compare_reference.jl` und `compare_golden.jl` enden ohne Schalter mit
Hinweis, außer `SIMLEV_MODULE_DIR` bzw. `SIMLEV_GOLDEN_DIR` zeigt auf einen Gleichlauf-Ordner.
Ersatz ist die Gleichlaufprüfung `tools/gleichlauf/run.sh` (siehe
[`python/DEVELOPING.md`](../python/DEVELOPING.md#tests-in-etappe-9)).

## Schichten

Die Dateien in `src/` gehören zu fünf Schichten (Anhang F des
Entwicklungsdokuments): 0 R-Interna (`src/r/`), 1 Daten und Strategie
(`dates.jl`, `config.jl`, `trigger.jl`, `data.jl`, `tax_tariff.jl`,
`data_prep.jl`, `backcast.jl`, `bonds.jl`, `signals*.jl`), 2 Engine
(`core.jl`, `result.jl`, `engine.jl`, `sim_*.jl`, `wrapper.jl`), 3 Analysen (je eine Datei
mit ihrem Kern), 4 Ausgabe (`svg.jl`, `dashboard.jl`); `SimLev.jl`,
`exports.jl` und `precompile.jl` sind die Paketebene. `test/layers_tests.jl`
liest die `using`/`import`-Zeilen, die qualifizierten Zugriffe
(`Modul.f`, `SimLev.f`) und in Dateien der Paketebene die Aufrufe von
Namen anderer Dateien und prüft, dass keine Datei auf eine höhere Schicht
zugreift. Die Zuordnung und die bekannten Ausnahmen (vor allem die
plot-Methoden der Analysen, die die Grafikbausteine aus `svg.jl` holen)
stehen mit Begründung im Test.
