# Entwicklung der Julia-Fassung

Die Julia-Fassung ist ein bitgleicher Port des R-Pakets SimLev 0.5.0 (Ordner
`r/`) und rechnet dieselben IEEE-754-Zahlen wie R und die Python-Fassung
(`python/`). Maßgeblich ist der R-Code; die Python-Fassung ist ein bereits
bitgleich geprüfter Zwischenschritt, der die Rechenreihenfolge von R
nachbildet und sich als Vorlage für die Übersetzung eignet.

## Aufbau

Alles liegt im Modul `SimLev`; die Bausteine sind Untermodule. Die Tabelle
folgt der Reihenfolge der `include`s in `src/SimLev.jl`: erst die R-Interna
(`src/r/`), dann die Engine, das Grafikmodul `svg.jl` und das Dashboard,
dann die Module (C++-Kerne jeweils vor ihrem Modul), zuletzt `exports.jl`
und `precompile.jl`.

| Datei | Untermodul | Inhalt (R-Vorlage → Python-Vorlage) |
|---|---|---|
| `src/r/env.jl` | `REnv` | Umgebungsschalter `SIMLEV_*`: einzige Stelle, die sie liest oder setzt (siehe [Schalter](#schalter-simlev_)) → `_r/env.py` |
| `src/r/types.jl` | – | R-Datenstrukturen (`RList`, `RFrame`, `RVector`, `NamedMat`), Druck-/summary-/plot-Registrierung |
| `src/r/ld80.jl` | – | `F80`: 80-Bit-`long double` (x86-64: x87-Hardware über `llvmcall`, sonst Software-Nachbau `F80Soft`) |
| `src/r/rnum.jl` | – | `NA`, `isna_strict`, Summen/Mittel/Varianz in `long double` (`r_sum`, `r_mean`, …), `r_pow` (`R_POW`), `r_uniroot`, zentrale Auswahl der C-Bibliotheken (`_LIBM`, `_LIBC`, `_SNPRINTF`) → `_r/rnum.py` |
| `src/r/rformat.jl` | – | Textausgabe der Engine: `r_sprintf` (NA/NaN/Inf wie R), `r_format`, `r_as_character`, `r_deparse`, `r_round`, `r_signif` → `_r/rformat.py` |
| `src/r/libm.jl` | `RLibm` | glibc-libm (`exp`, `log`, `log1p`, `expm1`, `pow`, `tanh`, …) → `_r/libm.py` |
| `src/r/base.jl` | `RBase` | Summen, Mittel, `cumsum`, `cumprod`, `rowSums`, … mit `long double` → `_r/base.py` |
| `src/r/rng.jl` | `RRng` | Zufallszahlen (`set_seed`, `runif`, `rnorm`, `sample_int`, L'Ecuyer-Streams); Zustand je Aufgabe über `TaskState`/`with_state` → `_r/rng.py` |
| `src/r/parallel.jl` | `RParallel` | `.par_lapply` mit `Threads.@spawn` (`par_lapply`), Meldungen und Ausgaben je Aufgabe (`r_stderr`, `r_stdout`, `suppress_messages`), siehe [Parallelität](#parallelität-cores) → `_r/parallel.py` |
| `src/r/nmath.jl` | `RNmath` | Verteilungen (`qnorm`, `pt`, `qt`, `pbeta`/toms708, `lgamma` …) → `_r/nmath.py`, `_r/_toms708.py`, `_r/_cmath.py` |
| `src/r/fmt.jl` | `RFmt` | `format`, `formatC`, `sprintf`, `round`, `signif`, `print` von Vektoren/Matrizen/data.frames → `_r/fmt.py` |
| `src/r/stats.jl` | `RStats` | Modulkopf mit Exporten; bindet die Themen ein (gleiche Namen wie in Python): `stats_sort.jl` (Hilfen, `order`, `r_sort`, `r_rank`, `cut`, `quantile`, `median`, …), `stats_cor.jl` (`cor`, `cov`, `var`, `scale`), `stats_smooth.jl` (`approx`, `r_filter`, `fft`, `density`, `smooth_spline`), `stats_optim.jl` (`optimize`, `uniroot`, `optim`, `nlminb`), `stats_models.jl` (`lm`, `glm`, `poly`, `predict`, `p_adjust`, `ecdf`, `ave`, `aggregate`, `t_test`), `stats_cluster.jl` (`dist`, `hclust`) → `_r/stats.py` (Sammelmodul) und `_r/stats_*.py` |
| `src/r/linalg.jl` | `RLinalg` | `matprod`, `crossprod`, `solve`, `chol`, `qr` (LINPACK), `determinant`, `eigen` → `_r/linalg.py`, `_r/_blas.py`, `_r/_lapack.py`, `_r/_linpack.py` |
| `src/r/rexpr.jl` | `RExpr` | Ausdrücke in R-Syntax als Text (`eval(parse(text = …), data, env)`): ein gemeinsamer Auswerter für Bedingungen in `bootstrap_probability`, `regime_subset`, `view_prob`/`entropy_pooling` und `tactical_rules` (R-Vorrang inkl. schwach bindendem `!`, NA-Logik, `%in%`, `%%`, Funktionen über `RLibm`/`RFmt`) |
| `src/r/port.jl` | `RPort` | PORT-Bibliothek für `RStats.nlminb` (stats `port.c`, `portsrc.f`, `nlminb.R`) → `_r/port.py` |
| `src/r/evd.jl` | `REvd` | evd 2.3-7.1 `fpot`, `nlgpd` (`src/pot.c`; in R übernommen als `.evd_fpot`, immer aktiv) → `_r/evd.py` |
| `src/r/truncnorm.jl` | `RTruncnorm` | truncnorm 1.0-9 `rtruncnorm` (in R übernommen als `.truncnorm_rtruncnorm`) → `_r/truncnorm.py` |
| `src/r/solnp.jl` | `RSolnp` | Rsolnp 1.16 `solnp`, `gosolnp` (in R übernommen als `.rsolnp_solnp`, `.rsolnp_gosolnp`) → `_r/solnp.py` |
| `src/r/rugarch.jl` | `RRugarch` | rugarch 1.5-6 `ugarchfit`/`coef` für sGARCH/gjrGARCH(1,1), Solver „hybrid“ (solnp → nlminb → gosolnp), Filter aus `src/filters.c`, eigene Richardson-Hesse-Matrix `_richardson_hessian` (in R übernommen als `.rugarch_ugarchfit`, Ableitungen `.sl_richardson_hessian` in `r/R/richardson.R`, immer aktiv) → `_r/rugarch.py` |
| `src/r/stinepack.jl` | `RStinepack` | stinepack 1.5 `stinterp`, `stinemanSlopes`, `parabolaSlopes` (in R übernommen als `.stinepack_stinterp`) → `_r/stinepack.py` |
| `src/r/imputets.jl` | `RImputeTS` | imputeTS 3.4 `na_interpolation` (stine, linear), `na_locf` (`src/locf.cpp`; in R übernommen als `.imputets_na_interpolation`, immer aktiv) → `_r/imputets.py` |
| `src/engine.jl` u. a. | – | `simulation()` und Strategie/Config: `engine.jl` (Hilfen, Handels- und Steuerfunktionen; r/R/sim_base.R → `_sim_base.py`), `sim_phases.jl` (r/R/sim_validate.R, sim_prepare.R → `_sim_phases.py`), `sim_loop.jl` (r/R/sim_actions.R, sim_loop.R → `_sim_loop.py`), `sim_evaluate.jl` (r/R/sim_evaluate.R → `_sim_evaluate.py`; dazu `simulation()` aus r/R/simulation.R → `engine.py`) |
| `src/svg.jl` | – | Grafikmodul: `SimLevPlot`, `_plot_method` & Co., alle SVG-Zeichenbausteine (siehe [Grafik](#grafik)) → `simlev/svg.py` |
| `src/dashboard.jl` | – | Dashboard-Daten und Panels, `plot_dashboard`, `export_dashboard` (r/R/plot_dashboard.R) → `dashboard.py` |
| `src/<modul>.jl` | `DataPrep`, `Backcast`, `Bonds`, `Signals`, `Bootstrap`, `Withdrawal`, `Dependence`, `Regimes`, `MsGarch`, `Scenarios`, `Optimize`, `Tactical`, `DeepAnalysis`, `Planning`, `AnalysisTests`, `Overfitting`, `ParamSearch`, `Sensitivity` | je eine R-Datei `r/R/<modul>.R` → `python/simlev/<modul>.py` |
| `src/<name>_core.jl` | `BootstrapCore`, `SignalsCore`, `WithdrawalCore`, `DependenceCore`, `OptimizeCore` | C++-Kerne aus `r/src/` (`BootstrapCore` zusätzlich der C-Kern `ms_garch.c`) → `python/simlev/_<name>_core.py` |
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
4. **Keine Matrixprodukte mit `*`** (OpenBLAS): `RLinalg.matprod`,
   `crossprod` usw. bilden die Referenz-BLAS-Reihenfolge nach. Eigenvektoren
   kommen wie in R aus der Referenz-LAPACK des Systems (`ccall` auf
   `liblapack.so.3`, Pfad über `SIMLEV_LAPACK`); ohne sie warnt SimLev und
   rechnet mit `LinearAlgebra.eigen` (nicht bitgleich).
5. Sortieren, Runden und Formatieren immer über `RStats`/`RFmt` (R's
   Sortierverfahren bei Gleichständen und ±0, R's `round`-Algorithmus,
   C-`printf` für Zahlen).
6. Zufall nur über `RRng` (globaler Zustand wie `.Random.seed`, in einer
   `par_lapply`-Aufgabe deren eigene Kopie).
7. NA und NaN wie in R auseinanderhalten: Arithmetik mit NA ergibt auf x86
   wie in R wieder NA; wo R `NA_real_` setzt, `SimLev.NA` setzen.
8. R-`warning(text)` → `@warn text` (nur die Meldung, keine weiteren
   Felder); R-`stop(text)` → `error(text)`; R-`message(text)` → Zeile auf
   `SimLev.RParallel.r_stderr()` (sonst `stderr`), `suppressMessages` →
   `RParallel.suppress_messages`, nie `redirect_stderr`. Texte wortgleich.
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
15. Optionale R-Pakete fragt R nicht mehr ab (kein `requireNamespace`):
    evd, imputeTS und rugarch sind übernommen, ihr Weg gilt immer; MSGARCH
    ist durch die eigene Schätzung (`r/R/ms_garch.R`, Kern `r/src/ms_garch.c`;
    hier `src/ms_garch.jl` und `BootstrapCore.ms_garch_filter`) ersetzt.
    Einen Schalter für optionale Pakete gibt es nicht. `Sys.time()` →
    `RBase.sys_time()` (Prüfschalter `SIMLEV_R_SYS_TIME`).

Keine externen Pakete; erlaubt ist nur die Standardbibliothek (`Dates`,
`Printf`, `Logging`; `LinearAlgebra` nur als Ersatzweg für Eigenvektoren).

## Parallelität (`cores`)

`RParallel.par_lapply` (`src/r/parallel.jl`) ist die einzige Stelle, die
parallel rechnet (Aufrufer: `bootstrap`, `bootstrap_study`, `param_search`,
`sensitivity_grid`, `rebalancing_sensitivity`, `lumpsum_vs_dca`,
`leverage_sensitivity`; `Bootstrap._par_lapply` und `ParamSearch._par_lapply`
leiten weiter). Semantik wie `parallel::mclapply(mc.preschedule = FALSE,
mc.set.seed = FALSE)` (Verhalten in R 4.3.3 ermittelt in Etappe 5): unter
zwei Kernen oder mit höchstens einem Element `lapply`; sonst startet jede
Einheit mit dem Zufallszustand des Aufrufers, der danach unverändert ist;
Ergebnisse in Eingangsreihenfolge; Warnungen gehen verloren; Meldungen und
Ausgaben erscheinen in Einheitenreihenfolge; beim ersten Fehler (in
Einheitenreihenfolge) erscheinen die Ausgaben davor, dann der Fehler.

Mit `Threads.nthreads() > 1` (`julia -t auto`, `julia -t 2`,
`JULIA_NUM_THREADS`) startet `par_lapply` `min(cores, nthreads)` Aufgaben
(`Threads.@spawn`), die sich die Einheiten der Reihe nach holen; mit einem
Thread rechnet `_sequential` nacheinander. Jede Einheit bekommt eine eigene
Kopie des Zufallszustands (`RRng.TaskState`: Generator und die statischen
Werte von rgamma/rpois, `RRng.with_state`) und einen eigenen Ausgabepuffer,
beides im task-lokalen Speicher; Warnungen verwirft ein `NullLogger` je
Aufgabe. Referenzfälle zusätzlich mit `julia -t 2` prüfen.

**Regeln für neue Module (Thread-Sicherheit):**

1. Parallel nur über `par_lapply`, nie eigene Tasks oder Threads.
2. Keine veränderlichen globalen Zustände. Was eine Rechnung sich merken muss,
   gehört in lokale Variablen oder Argumente (wie `_Bsplvb` in
   `src/r/_sbart.jl`); Zustände, die für einen Aufruf gelten (Handler,
   Schalter), in den task-lokalen Speicher (`task_local_storage(f, key,
   wert)`, wie `_with_bounds_handler` in `src/optimize.jl`); einmalige
   Einrichtung (Bibliotheken laden, Tabellen) unter einer `ReentrantLock`
   und erst am Ende als fertig markieren (wie `_collate_init!`,
   `system_lapack`); Caches mit Sperre (wie `RFmt`/`rformat`, `RExpr`).
3. Zufall nur über `RRng`; dessen Funktionen holen den Zustand über `_st()`,
   `_rg()`, `_rp()`, nie direkt über `_S`, `_RG`, `_RP`.
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
`bootstrap` (stationär und `"garch"` über den rugarch-Weg),
`bootstrap_study`, `_ms_garch_fit`, Entnahme, Optimierung und
`deep_analysis` (Etappe 4.8; gemessen auf zwei Kernen, Julia 1.13.2):

| | vorher | nachher |
|---|---|---|
| `using SimLev` nach einer Codeänderung (mit Vorkompilieren) | 316 s | 279 s |
| ohne Arbeitslast (`SIMLEV_SKIP_PRECOMPILE=1`) | 21 s | 21 s |
| Cache (`.so`) | 130,0 MB | 107,9 MB |
| erster Lauf S30 / T2 / T8 (`tools/bench`) | 1,6 / 10,6 / 6,0 s | 1,5 / 0,4 / 0,4 s |
| erster Lauf T5 (`dependence_analysis` mit DCC) | 2,1 s | 7,9 s |
| Summe Vorkompilieren + erste Läufe aller Aufgaben | 340 s | 292 s |

Seltene Wege (Parametersuche, Abhängigkeiten, Szenarien, Sensitivitäten,
Taktik, Planung, `align_series`) übersetzt ihr erster Aufruf; deshalb
braucht der Testteil von `Pkg.test()`, der alle Module berührt, rund 50 s
mehr (315 statt 265 s), sodass Vorkompilieren plus `Pkg.test()` nach einer
Änderung etwa gleich lang bleibt (594 statt 581 s). Ein neuer
Baustein lohnt sich nur, wenn sein Weg häufig ist: Jeder kostet bei jeder
Änderung am Paket Vorkompilierzeit.

Was ein Referenzfall bitgleich prüft, steht nicht noch einmal als Test in
`test/` (Etappe 4.1); so stehen die konstanten Ausdrücke, die
`golden/modules/rexpr` wörtlich prüft, nicht mehr in `rexpr_tests.jl`.

## Schalter `SIMLEV_*`

Alle Umgebungsschalter liest (und setzt) nur `src/r/env.jl` (`SimLev.REnv`);
Paket, Vorkompilierung, Tests und Werkzeuge holen sie von dort
(`test/layers_tests.jl` prüft das). Wann gelesen wird, bestimmt die
aufrufende Stelle: `test/reftree.jl` beim Laden, die Kollation beim ersten
Vergleich (neu nach `RStats.collate_reset()`), LAPACK beim ersten Laden der
Bibliothek, `RBase.sys_time()` bei jedem Aufruf, `precompile.jl` beim
Vorkompilieren.

| Schalter | Zweck | Art |
|---|---|---|
| `SIMLEV_COLLATE` | Sortierung: `icu:<Locale>` (`icu:root` wie R unter C.UTF-8) oder `C` (Bytes); ohne Angabe nach `LC_ALL`/`LC_COLLATE`/`LANG` | Nutzer |
| `SIMLEV_ICU` | Pfad zur ICU-Bibliothek (`libicui18n`) | Nutzer |
| `SIMLEV_LAPACK` | Pfad zur Referenz-LAPACK (`dsyevr_`) | Nutzer |
| `SIMLEV_R_SYS_TIME` | feste Uhr für `RBase.sys_time()` (gosolnp), Sekunden seit 1970; `run_ref_case` setzt sie aus dem Feld `sys_time` eines Falls | Prüfung |
| `SIMLEV_LAX_NA` | `1`: NA = NaN im Vergleich (`reftree.jl`) | Prüfung |
| `SIMLEV_STRICT_ZERO` | `0`: −0 = +0 im Vergleich (`reftree.jl`) | Prüfung |
| `SIMLEV_FULL_TESTS` | `1`: `Pkg.test()` prüft alle Modul-Fälle statt bis zu vier je Modul | Prüfung |
| `SIMLEV_GOLDEN_DIR` | anderer Wurzelordner der Engine-Fälle (`cases/`, `extra/`) für `Pkg.test()` | Prüfung |
| `SIMLEV_SKIP_PRECOMPILE` | `1`: keine Arbeitslast beim Vorkompilieren | Entwicklung |
| `SIMLEV_SKIP_PRECOMPILE_EXT` | `1`: Arbeitslast ohne die Analysemodule | Entwicklung |

`reftree.jl` setzt `SIMLEV_COLLATE=icu:root`, falls nicht gesetzt (die
Referenzen entstanden unter C.UTF-8). Die Generatoren in `golden/modules/`
lesen eigene Schalter (`SIMLEV_R_NMATH_SRC`, `SIMLEV_ALLOW_PARTIAL`, siehe
`golden/README.md`).

## Schichten

Die Dateien in `src/` gehören zu fünf Schichten (Anhang F des
Entwicklungsdokuments): 0 R-Interna (`src/r/`), 1 Daten und Strategie
(`dates.jl`, `config.jl`, `trigger.jl`, `data.jl`, `tax_tariff.jl`,
`data_prep.jl`, `backcast.jl`, `bonds.jl`, `signals*.jl`), 2 Engine
(`core.jl`, `result.jl`, `engine.jl`, `sim_*.jl`), 3 Analysen (je eine Datei
mit ihrem Kern), 4 Ausgabe (`svg.jl`, `dashboard.jl`); `SimLev.jl`,
`exports.jl` und `precompile.jl` sind die Paketebene. `test/layers_tests.jl`
liest die `using`/`import`-Zeilen, die qualifizierten Zugriffe
(`Modul.f`, `SimLev.f`) und in Dateien der Paketebene die Aufrufe von
Namen anderer Dateien und prüft, dass keine Datei auf eine höhere Schicht
zugreift. Die Zuordnung und die bekannten Ausnahmen (vor allem die
plot-Methoden der Analysen, die die Grafikbausteine aus `svg.jl` holen)
stehen mit Begründung im Test.
