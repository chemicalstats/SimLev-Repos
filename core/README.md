# core/ – Bibliothek slc (SimLev core)

Kanonische Quellen der Bibliothek slc und der geteilten Kerne, die R, Python und Julia gemeinsam nutzen.
**Nur hier ändern**, danach `python3 core/sync.py --write`; `--check` prüft die Kopien
(SHA-256), `core/slc_constants.h` gegen den Generator und die Meldungstabellen gegen `meldungen.tsv`.

**Sprache (seit 1.6.0):** Übersetzt wird nur C++ (`-std=gnu++17 -O2 -ffp-contract=off -fno-fast-math` in allen
drei Builds, `r/src/Makevars`, `python/setup.py`, `julia/deps/build.jl`); bis 1.5.2 war slc C99 (`slc_*.c`). Die
Dateien sind im gemeinsamen Teil von C und C++ geschrieben (keine Klassen, keine Templates, `<math.h>` mit
double-Aufrufen); die öffentliche Schnittstelle (`slc.h`, `slc_*.h`, `simlev_cabi.cpp`) hat C-Bindung
(`extern "C"`), die exportierten Symbole und die `ccall`s sind unverändert. Alle Deklarationen tragen `SL_NOTHROW`
(`__attribute__((nothrow))` unter GCC/Clang in C++, sonst leer): slc wirft nie; ohne die Angabe legt g++ an jedem
Aufruf über Dateigrenzen Ausnahmepfade an und ordnete die heiße Schleife des MS-GARCH-Gradienten anders (Julia-Fit
7 % langsamer). Mit ihr ist der Maschinencode jeder Kerndatei gleich dem mit `-fno-exceptions`. Belegt bitgleich gegen R 1.5.2
(Gleichlauf und Zufallsprüfungen gegen `rlib152`, Ergebnisse der Bench-Aufgaben Byte für Byte); seit 1.6.2 mit
genaueren Formeln (expm1/log1p, CAGR, Copula-Dichte) und Householder + QL statt Jacobi, Referenz R 1.6.2 (`rlib162`), seit 1.6.3 R 1.6.3 (`rlib163`, Zufallsreferenzen inhaltlich gleich 1.6.2), seit 1.6.4 R 1.6.4 (`rlib164`).

| Datei | Inhalt |
|---|---|
| `slc.h` | öffentliche Schnittstelle (C-ABI, `extern "C"`): Kontext `sl_ctx`, Generator `sl_rng`, Ziehungen, Verteilungen |
| `slc_internal.h` | interne Hilfen: Gleitkomma-Schutz, Abbruchprüfung; seit 1.6.3 Quantil Typ 7 (`slc_quantile7`, für Bandbreite und CDaR); seit 1.6.4 die NaN-Regeln `slc_quiet`/`slc_lnan` (für `slc_prep.cpp`, `slc_bootpath.cpp`, `slc_rbase.cpp`) |
| `slc_constants.h` | **erzeugt** von `gen_constants.py` (nicht von Hand ändern) |
| `slc_ctx.cpp` | Fehler, Warnungen, Benutzerabbruch ohne `longjmp` |
| `slc_rng.cpp` | xoshiro256**, SplitMix64-Seeding, Sprung um 2^128, Ströme, Gleichverteilung |
| `slc_sample.cpp` | ganze Zahlen (Lemire), Stichproben, normal (Inversion), exponentiell, geometrisch, Gamma (Marsaglia–Tsang), Chi-Quadrat |
| `slc_normal.cpp` | `erfc`, `pnorm`, `qnorm`, `dnorm` |
| `slc_special.cpp` | `lgamma`, unvollständige Beta, `pt`, `qt`, `plogis`, `qlogis` |
| `slc_linalg.h` | Schnittstelle von linearer Algebra, Matrixprodukt, kleinsten Quadraten, Stineman, Spline und Kerndichte (eingebunden von `slc.h`) |
| `slc_la_internal.h` | kompensierte Summen (Neumaier), Normen, NA, stabile Sortierung; seit 1.6.4 Mittel und Stichprobenvarianz `slc_mean`/`slc_var_m` (GARCH, MS-GARCH, GPD, Kerndichte) |
| `slc_linalg.cpp` | Cholesky, Band-Cholesky, Dreieckslöser, SPD-Löser, log det, symmetrische Eigenwerte (Householder-Tridiagonalisierung und implizites QL, seit 1.6.2; bis 1.6.1 zyklisches Jacobi) |
| `slc_matmul.cpp` | Matrixprodukt `A B`, `X'Y`, `X Y'` mit fester Summationsreihenfolge |
| `slc_lsq.cpp` | kleinste Quadrate (Householder-QR, begrenzte Spaltenpivotisierung), Logit-IRLS |
| `slc_stine.cpp` | Stineman-Interpolation |
| `slc_spline.cpp` | kubischer Glättungsspline (Reinsch, GCV, Spur nach Hutchinson/de Hoog), Vorhersage |
| `slc_kde.cpp` | Gauß-Kerndichte, Bandbreite nach Silverman |
| `slc_opt.h`, `slc_opt.cpp`, `slc_opt_test.cpp` | Optimierer BFGS (Wolfe-Liniensuche), projizierter BFGS, Nelder-Mead, numerischer Gradient; Rückfrage an den Host und `sl_minimize`; Prüffunktionen (Quellen: Nocedal/Wright, Bertsekas, Kelley, Nelder/Mead, Lagarias u. a., Gill/Murray/Wright, Moré/Garbow/Hillstrom) |
| `slc_models.h`, `slc_garch.cpp`, `slc_gpd.cpp`, `slc_dcc.cpp`, `slc_msgarch.cpp`, `slc_boot.cpp` | Modelle: GARCH/GJR(1,1) (ML, Umparametrisierung, Rückfall Momente), GPD (ML, Startwerte nach Hosking/Wallis), DCC(1,1) (Filter, BFGS, Rückfall Nelder-Mead), MS-GARCH (Filter, Starts aus HMM-EM und Rangeinteilung, BFGS, Viterbi; seit 1.6.3 Vorwärts-Rückwärts-Schritt `sl_hmm_fb` und gleitendes Mittel `sl_roll_mean` auch für `research_core_impl.h`), Bootstrap-Kerne mit Strom `sl_rng` (Quellen: Bollerslev, Glosten/Jagannathan/Runkle, Pickands, Davison/Smith, Hosking/Wallis, Engle, Haas/Mittnik/Paolella, Hamilton, Baum u. a., Viterbi, Efron, Künsch, Politis/Romano, Wu, Liu, Mammen, Barone-Adesi u. a.; eigener SimLev-Code) |
| `slc_rbase.h`, `slc_rbase.cpp`, `slc_rbase_sort.cpp`, `slc_rbase_cov.cpp` | Grundfunktionen mit R-Regeln **für Python und Julia** (R rechnet sie selbst; nicht in `slc.h`); nur `slc_rbase.cpp` und `slc_rbase.h` gehen auch nach `r/src/` (`sl_r_sum` für die Summen der Tagesengine `engine_core_impl.h`, die Grundfunktionen und `sl_r_zeroin2` der Auswertung `evaluate_core_impl.h`, die Auswertung je Pfad der Entnahme `withdrawal_core_impl.h`): `sum`, `prod`, `mean`, `var`, `cumsum`/`cumprod`/`cummax`/`cummin`, `rowSums`/`colSums` (long double wie R; seit 1.6.3 `colSums`/`colMeans` auch über ausgewählte Zeilen ohne Kopie, `sl_r_colsums_idx`), `^`, R's `log` (`sl_r_log1`, seit 1.6.3 auch für HMM-EM und Entnahme), Kalender (`sl_r_civil_from_days`/`sl_r_days_from_civil`, seit 1.6.3 hier, auch für `slc_prep.cpp`), `round`/`signif` (`sl_r_fround`/`sl_r_fprec`, seit 1.6.3 hier, auch für den Tarif), `approx` (Interpolation je Punkt wie `approx1` von `stats::approx`, seit 1.5.0; Prüfung `approx_fuzz.R`), `order`, `rank`, `sort(partial =)`, `quantile` Typ 1–9, `tabulate`, `findInterval`, `cov`/`cor` (pearson, kendall; alle `use`). Anders als die SimLev-eigenen Kerne (ohne long double) akkumulieren sie absichtlich in long double, damit sie auf derselben Plattform bitgleich zu R sind (Prüfung gegen R 4.3.3, ≥ 10.000 Zufallsfälle je Kern). Hüllen: `python/src/_ext_slc_rbase.cpp`, `julia/src/r/rbase_c.jl` |
| `slc_rbase_date.cpp`, `slc_rbase_num.cpp` | wie `slc_rbase*` nur für Python und Julia: Datumsformat und -lesen (`format.Date`/`strftime` in der C-Locale, `as.Date(x, "%Y-%m-%d")`, proleptisch gregorianisch; dokumentierte Umwandlungen aus `?strptime` textgleich zu R) und weitere long-double-Wege von R (`R_strtod`, `%%`, `%/%`, `scientific()` von `formatReal`), mit denen Julia die Nachbildung `ld80.jl` und Python `numpy.longdouble` ablöst. Schalter, Breiten und E/O im Datumsformat wie glibc unter Linux, `digits.secs` für `%OS`. Prüfung: Gleichlauf (`date_fuzz*`, `rbase_fuzz*`) |
| `slc_rbase2.h`, `slc_rbase_clust.cpp`, `slc_rbase_vec.cpp`, `slc_rbase_cor.cpp`, `slc_rbase_smooth.cpp`, `slc_rbase_models.cpp`, `slc_rbase_fmt.cpp` | seit 1.6.0, wie `slc_rbase*` nur für Python und Julia: die bis 1.5.2 je Sprache doppelten Nachbildungen `dist`/`hclust` (Lance-Williams nach `hclust.f`), `cut`/`.bincode`, `seq.int(length.out)`, `median`, `cor`/`cov` mit Rängen (kendall, spearman, alle `use`, paarweise), `cov2cor`, `scale`, `regularize.values`, `filter` (Faltung, rekursiv), `p.adjust`, `ecdf` und das Zahlformat: `formatReal`/`encodeReal`, `as.character` für Zahlen, `formatC` (`str_signif`) und `sprintf` mit R's Vektorsemantik über `snprintf` der C-Bibliothek (eine Fassung statt zwei je Sprache). Die Sprachen behalten dünne Hüllen (Argumente, NA-Kennung, Rückgabe); Funktionen als `ties` von `approx` rechnet der Host über die Gruppennummern des Kerns. Hüllen: `python/src/_ext_slc_rbase2.cpp`, `julia/src/r/rbase_c2.jl`. Prüfung: Gleichlauf `clust_fuzz.R`, `vec_fuzz.R`, `cor_fuzz.R`, `padj_fuzz.R`, `fmt_fuzz.R` (und `approx_fuzz.R` mit `filter`) gegen R 1.5.2. Seit 1.6.3 stehen die NA-Hilfen dieser Dateien einmal in `slc_rbase2.h` (`slr_bits_d`, `slr_is_na`, `SLR_NA`, `SLR_NAN`) |
| `gen_constants.py` | Konstanten, Bernoulli-Zahlen, zeta(k), Stützwerte und Taylor-Polynome, Sprungpolynom, selbst angepasste rationale Näherungen für `qnorm` (nur Standardbibliothek) |
| `meldungen.tsv`, `gen_meldungen.py` | seit 1.6.0: Code→Text-Tabellen der Tagesengine (Warnungen, Abbrüche, `details`-Ausgaben, Anlässe, Steuerbezeichnungen) und der Auswertung (Ursachen, Warnungen) aus einer Quelle; der Generator (nur Standardbibliothek) schreibt `r/R/meldungen.R`, `python/simlev/_meldungen.py` und `julia/src/meldungen.jl` (nicht von Hand ändern). Die Auswahl der Texte und ihre Argumente bleiben je Sprache in `.sim_engine_signal`/`.sim_engine_detail`, `.sim_eval_detail`/`.sim_eval_warn` und den Gegenstücken |
| `slc_prep.h`, `slc_prep.cpp` | seit 1.6.0: Kerne für Wirtsfunktionen großer Fälle (eigener SimLev-Code, Regeln von SimLev 1.5.2): Threads (`sl_par_threads`, `sl_par_run`; POSIX mit `SLC_THREADS`, Ergebnis unabhängig von der Zahl), Kalenderauffüllung von `simulation()` (`sl_cal_index`, `sl_cal_fill_real`, `sl_cal_fill_int`; bis 1.5.2 R `merge()`, Python und Julia je eine Schleife), Momentum-Scores (`sl_mom_back`, `sl_mom_score`; Rückblick ganzzahlig über den Kalender, LOCF, `rowMeans` in long double). Hüllen: `r/src/prep_r.cpp`, `python/src/_ext_slc_prep.cpp`, `julia/src/slib_prep.jl`. Prüfung: Gleichlauf `cal_fuzz.R`, `mom_fuzz.R` gegen R 1.5.2 |
| `slc_bootpath.cpp` | seit 1.6.0: Pfadaufbau im Bootstrap (`sl_boot_path`: Kurspfade, Hebelprodukte, Zusatzreihen und Niveau-Variante eines Pfads in einem Aufruf; bis 1.5.2 `.build_path` je Sprache; seit 1.6.3 `sl_boot_path_src`: die Renditen als Zeilen `idx` der Quellrenditen mit Schrittweiten, ohne die Kopie `returns[idx, ]` je Pfad, Bit für Bit wie `sl_boot_path` auf der Kopie; Hüllen nur Python `slc_boot_path_src` und Julia per `ccall`, in R ohne messbaren Gewinn). Prüfung: `boot_fuzz.R` |
| `slc_tcop.cpp`, `slc_opt_fmin.cpp` | seit 1.6.0: Profil-Likelihood der t-Copula ganz im Kern (`sl_tcop_fit` für `copula_fit`/`dependence_analysis`, `sl_tcop_nu` für `scenario_copula`; qt über `sl_qt_mt` auf mehreren Threads, im eigenen Abschnitt von `slc_special.cpp`) und Brent fmin wie `stats::optimize` als Frage/Antwort (`sl_fmin_init`/`_ask`/`_tell`, `sl_fmin`; Herkunftsblock, übersetzt über die bis 1.5.2 vorhandenen Ports). Fällt eine Auswertung nicht endlich aus oder warnt qt, rechnen die Sprachen wie bisher (gleiche Meldungen). Prüfung: `copula_fuzz.R` |

**Geteilte C++-Kerne von R, Python und Julia:** Auch die C++-Kerne liegen hier: `simlev_core.h` (Aufbau, Host-Schnittstelle, `NA`),
`engine_core_impl.h` (Tagesengine; bis 1.3.0 `simulation_core_impl.h`, `fifo_core_impl.h`,
`tax_core_impl.h`), `prepare_core_impl.h` (Vorbereitung von `simulation()`), `evaluate_core_impl.h`
(Auswertung von `simulation()` und XIRR), `tariff_core_impl.h` (Einkommensteuertarif), `research_core_impl.h`
(Optimierung, Quantilsregression, HMM, rollierende Kennzahlen, Kendalls Tau) und
`withdrawal_core_impl.h` (Entnahme), seit 1.5.1 `wrapper_core_impl.h` (NAV der Fonds-Wrapper). Sie folgen nicht den slc-Regeln unten (eigener SimLev-Code, C++17,
Host-Makros `SIMLEV_*`) und werden nach `r/src/`, `python/src/core/` und `julia/deps/core/`
kopiert: Julia ruft sie über die C-ABI-Hülle `simlev_cabi.cpp`
(nur `julia/deps/core/`; `extern "C"`, Zeiger, Längen, Skalare, Fehler als Rückgabecode mit Text) per `ccall`
aus `libslc` auf (bis 1.1.0 eigene Ports). Beim Verschieben nach `core/` blieb ihr Maschinencode in R gleich
(Vergleich der Objektdateien Funktion für Funktion). Die Engine-Kerne rechnen Operationen mit zwei
Eingabeoperanden über `simlev_add`/`_sub`/`_mul`/`_div` (Regel „NA vor NaN“ in `simlev_core.h`), damit R, Python
und Julia auch bei NA und NaN in einer Operation unabhängig vom Compiler dasselbe Bitmuster liefern (Prüfung:
Gleichlauf `sim_fuzz.R` mit NA-Daten über `simulation()`).

**Tagesengine:** `engine_core_impl.h` rechnet die Tagesschleife von `simulation()` als ein Kern mit eigenem
Zustand (C++-Strukturen statt Host-Objekten, wie `tariff_core_impl.h`), Ereignisprotokoll (Warnungen und Abbrüche
als Codes, Texte in den Hüllen) und den Phasen: Batch- und Marktupdate, Aktivierung, Sparplan, Handel,
Rebalancing, Liquidation, Steuerphasen, Splits, Freibetrag und Abschluss mit Probelauf, `details`-Ausgaben
als Ereignisse mit Werten (Texte wortgleich in den Hüllen, mit den Warnungen verzahnt). Seit 1.4.0 rechnet
der Kern alle Läufe; die bis 1.3.0 eigenen Engines der Sprachen und die Engine-Kerne `simulation_core_impl.h`,
`fifo_core_impl.h`, `tax_core_impl.h` mit ihren Hüllen sind entfallen. Hüllen: `r/src/engine_core.cpp`, `python/src/_ext_engine.cpp`
(`sim_engine_run`), `simlev_cabi.cpp` (`simlev_c_engine_*`). Seit 1.6.3 kompakte Lot-Ausgabe (`Engine::open_lots_n`/
`open_lots_out`: nur die offenen Lots spaltenweise; mit den Zählern statt der Einzelobjekte je Lot, Verkauf und
Steuerbuchung): R `inp$compact`; der Python-Zweig `compact` und die Julia-Exporte `simlev_c_engine_open_lots_n`/`_open_lots`
ohne Aufrufer entfallen seit 1.6.4. Summen wie R in long double über `sl_r_sum`
(`slc_rbase.cpp`, dafür auch in `r/src/`). Prüfung: Gleichlauf `sim_fuzz.R` gegen R 1.3.0.

**Vorbereitung:** `prepare_core_impl.h` rechnet vor der Tagesschleife die Termine (`calculate_dates_flags`
mit der Monatsarithmetik von `seq.Date`), Split-Termine, die Tagesflags samt Verschieben von Terminen auf
aufgefüllten Tagen, Aktivierung, Freibetragstage, Jahreswechsel und VP-Abrechnungstage, Startgewichte und
Anfangszustand; die Engine bindet sie ein (`Engine::setup_prepared`). Die Sprachen prüfen die Eingaben (Texte) und
wandeln die Angaben (`span`, `days`, `harvest_day`) wie R (`.sched_spec`). Hüllen wie die Tagesengine, dazu
`calculate_dates_flags` (`C_sim_dates_flags`, `sim_dates_flags`, `simlev_c_dates_flags`). Prüfung zusätzlich:
Gleichlauf `sched_fuzz.R` (Datums-Fuzz) gegen R 1.3.0.

**Auswertung:** `evaluate_core_impl.h` rechnet nach dem Lauf Depotwert und Zuflüsse je Tag, CAGR (mit
Einzahlungen geldgewichtet über XIRR: Brent wie `stats::uniroot` über `sl_r_zeroin2` in `slc_rbase.cpp`), TTWROR,
zeitgewichteten Wertindex, Drawdowns, Tagesrenditen ohne aufgefüllte Tage, Performance- und Risikokennzahlen
(Sharpe, Sortino, Calmar, Omega, Ulcer, Martin, Serenity, Schiefe, Kurtosis, Partialmomente, Drawdown-Dauern),
Käufe/Verkäufe je Jahr und die Ursachen nicht definierter Kennzahlen (`undefined_metrics`) als Codes. Warnungen
und Abbrüche (NA in einer Bedingung) meldet der Kern mit Werten bzw. Stelle; die Sprachen setzen die Texte und
rechnen `risk_free` aus `data` (Typen, Meldungen). Hüllen: `r/src/engine_core.cpp` (`C_sim_evaluate`,
`C_sim_xirr`), `python/src/_ext_engine.cpp` (`sim_evaluate`, `sim_xirr`), `simlev_cabi.cpp` (`simlev_c_eval_*`,
`simlev_c_xirr`). Summen, Mittel, Varianz, Kumulationen und Potenz wie R über `slc_rbase.cpp`. Prüfung zusätzlich:
Gleichlauf `metric_fuzz.R` (Fuzz der Kennzahlen) gegen R 1.3.0.

**Entnahme:** `withdrawal_core_impl.h` rechnet die Pfade von `withdrawal_simulation()` (`wd_simulate`, Regeln,
Steuer, Tarifweg) und seit 1.5.0 auch die Auswertung je Pfad, die bis 1.4.3 jede Sprache selbst rechnete:
`wd_metrics` (Mittel, Minimum, Drawdown `max(1 - c / cummax(c))`, Sicherheitsäquivalent und Summe der Entnahmen
über die vollen Planjahre bzw. bis zum Horizont), `wd_pwr` (Perfect Withdrawal Rate mit den Prüfungen von
`withdrawal_perfect_rate()` als Status; je Pfad bis zum Horizont), `wd_annual_prod` (reale Jahresrenditen aus
Perioden) und `wd_tariff_compact` (Jahreszeilen des Tarifwegs). Reine Funktionen auf Zeigern (reentrant); Summen,
Mittel, Produkte, Kumulationen und Potenz über `slc_rbase.cpp`, `min`/`max`/`pmax` mit R's NA-Regeln. Die Sprachen
setzen die Meldungen (Texte und Aufrufe wie bisher), Namen und Datenrahmen. Hüllen: `r/src/withdrawal_core.cpp`
(`C_wd_metrics`, `C_wd_pwr`, `C_wd_annual_prod`, `C_wd_tariff_compact`), `python/src/_ext_withdrawal.cpp`,
`simlev_cabi.cpp` (`simlev_c_wd_*`). Prüfung zusätzlich: Gleichlauf `wd_fuzz.R` gegen R 1.4.2.

**Forschung (seit 1.5.0):** `research_core_impl.h` rechnet außer Optimierung, Quantilsregression, Vorwärts-
Rückwärts-Schritt und rollierenden Kennzahlen (seit 1.6.3 auch das rollierende Maximum `roll_max_core` in O(n) für
`signal_drawdown(window)`; Hüllen `C_roll_max_core`, `roll_max_core`, `simlev_c_roll_max_core`) auch den Baum-Welch-EM von `regime_hmm()` (`hmm_em`: E-Schritt mit
Log-Dichten über `sl_chol`/`sl_trisolve`, M-Schritt mit `sl_crossprod`, Abbruchtest; ein Fehler verwirft wie bisher
den Startwert), die Rückwärtsrekursion von `planning_goal()` (`goal_dp`: Wertfunktion auf dem Gitter, Interpolation
über `sl_r_approx`, `sl_qnorm`/`sl_pnorm`, Politik je Periode; gleiche `log(grid)`-Werte fasst es wie `approx`
zusammen und meldet die Zahl der Aufrufe für die Warnungen der Sprachen) und die Aufteilungen der CSCV von
`overfit_pbo()` (`pbo_cscv`: Blocksummen über `sl_matmul`, Kennzahlen, bester Punkt, Rang, Logit, Median).
Startwerte und Zufall (`regime_hmm`), Gitter und Vorwärtssimulation (`planning_goal`), Blocksummen und Regression
(`overfit_pbo`) bleiben in den Sprachen. Hüllen: `r/src/research_core.cpp` (`C_hmm_em_core`, `C_goal_dp`,
`C_pbo_cscv`), `python/src/_ext_research.cpp`, `simlev_cabi.cpp` (`simlev_c_hmm_em`, `simlev_c_goal_dp`,
`simlev_c_pbo_cscv`). Prüfung zusätzlich: Gleichlauf `hmm_fuzz.R`, `goal_fuzz.R`, `pbo_fuzz.R` gegen R 1.4.2.

**Fonds-Wrapper (seit 1.5.1):** `wrapper_core_impl.h` rechnet die Tagesschleife des Anteilswerts von `wrapper_nav()`
(`wrapper_nav_core`: Verwaltungsgebühr je Kalendertag mit Schaltjahr, Performancegebühr über der High Water Mark,
Festschreibung am letzten NAV-Tag des Jahres; meldet den ersten Tag ohne Anteilswert). Innere Rechnung, Auswahl der
NAV-Tage, Jahr je Tag und Meldungen bleiben in den Sprachen. Hüllen: `r/src/research_core.cpp`
(`C_wrapper_nav_core`), `python/src/_ext_research.cpp`, `simlev_cabi.cpp` (`simlev_c_wrapper_nav`). Prüfung
zusätzlich: Gleichlauf `nav_fuzz.R` gegen R 1.5.0.

Kopien (Pakete bauen nur aus ihrem Teilbaum): `r/src/` (flach), `python/src/core/`,
`julia/deps/core/` (slc, die geteilten Kerne und `simlev_cabi.cpp`). Die Hüllen gibt es nur je Sprache: `r/src/slc_r.cpp` (+ `r/R/slc.R`),
`python/src/_ext_slc.cpp` (+ `python/simlev/_lib.py`), `julia/src/slib.jl` (`ccall`, gebaut von
`julia/deps/build.jl`).

## Nur für den Kern-Gleichlauf (seit 1.6.3 gekennzeichnet)

Diese Einsprünge ruft keine Paketfunktion; sie prüfen Kernbausteine im Gleichlauf (`tests/gleichlauf/erzeugen/slc.R`,
`tests/methodik/test-slc.R`). Sie sind keine Nachbildungen von R-Funktionen im Sinn der NEWS-Regel von 1.6.1 und
bleiben, solange der Baustein nicht über Paketfunktionen geprüft wird.

- **Ohne Aufrufer im Kern:** `sl_garch11_nll`, `sl_garch11_grad` (`slc_garch.cpp`), `sl_gpd_nll`, `sl_gpd_pwm`
  (`slc_gpd.cpp`), `sl_msgarch_nll`, `sl_msgarch_grad`, `sl_msgarch_fit`, `sl_hmm_em_univ` (`slc_msgarch.cpp`),
  `sl_backcast_obj` (`slc_backcast.cpp`), `sl_pbeta` (`slc_special.cpp`), `sl_rexp`, `sl_rgamma` (`slc_sample.cpp`)
  und die Prüffunktionen in `slc_opt_test.cpp`; dazu ihre Hüllen in `r/R/slc*.R`, `python/simlev/_lib*.py` und
  `julia/src/slib*.jl`.
- **Kern intern genutzt, Hülle nur für Prüfungen:** R `.sl_chol_band`, `.sl_stineman_*`, `.sl_garch11_filter`,
  `.sl_garch11_fit`, `.sl_ms_garch_starts`, `.sl_erfc`, `.sl_plogis`, `.sl_qlogis`, `.sl_hmm_viterbi` und die
  gleichnamigen Hüllen in Python und Julia; nur in R zusätzlich `.sl_backsolve`, `.sl_ms_garch_filter`,
  `.sl_state_hex`.
- **Wege einer Paketfunktion, die nur die Prüfungen nutzen (seit 1.6.4 gekennzeichnet):** der numerische Gradient
  `sl_numgrad` (`slc_opt.cpp`, Aufrufer nur `sl_opt_test_numgrad`), die Spaltenpivotisierung `pivot = 2` von `sl_lsfit`
  mit `swap_cols` (`slc_lsq.cpp`; die Pakete rufen nur `pivot = 1`, geprüft in `slc.R` Fall `voll_piv2` und
  `test-slc.R`) und die nicht glatten Verluste 3–5 von `bc_loss` in `sl_backcast_fit` (`slc_backcast.cpp`; die Hosts
  rufen den C-Fit nur für rmse/mse/hybrid, mae/median/max laufen über `.sl_optim`). Sie bleiben als Prüfzugang,
  weil Gleichlauffälle und das Argument `pivot` der drei `lsfit`-Hüllen sie nutzen.

## Regeln

- **Reinraum.** Kerne entstehen nur aus Veröffentlichungen und Mathematik (DLMF,
  Abramowitz/Stegun, Blackman/Vigna, Steele u. a., Lemire, Knuth, Devroye, Marsaglia/Tsang,
  Lentz, Dekker). Nicht gelesen werden dabei `r/R/vendor_*`, `r/src/vendor_*`, die Port-Module
  in `python/simlev/_r/` und `julia/src/r/` (`rng`, `nmath`, `_toms708` …), `python/src/_rng_r.c`
  sowie R- und Paketquellen. R und die alten Pakete dienen nur als Prüforakel (Zahlen vergleichen).
- **Reinraum lineare Algebra, Glättung, Kerndichte.** Zusätzliche Quellen: Golub/Van Loan, Jacobi, Bowdler/Martin/Reinsch/Wilkinson, Demmel/Veselić,
  Businger/Golub, Higham, Neumaier, McCullagh/Nelder, Stineman, Reinsch, Green/Silverman,
  Craven/Wahba, Hutchinson/de Hoog, Kiefer, Knuth, Silverman, Scott, Wand/Jones, Hyndman/Fan; nicht
  gelesen werden zusätzlich die Ports `_linpack`, `_lapack`, `_blas`, `linalg`, `stinepack`,
  `imputets`, `_sbart`, `stats_smooth`, `_fft` (und ihre Julia-Gegenstücke). stinepack, imputeTS
  und R dienen nur als Black-Box-Orakel.
- **Dateikopf.** Jede Kerndatei nennt Verfahren, Quellen (vollständige Angabe, bei DLMF die
  Gleichungsnummer), Herkunft der Konstanten, die Reinraum-Erklärung und das Prüforakel.
  Ausnahme: `slc_rbase*` sind keine Reinraum-Kerne, sondern über die Ports aus
  R-Quellen übersetzt; sie tragen statt der Reinraum-Erklärung den Herkunftsblock (Felder
  „Herkunft“, „Rechte“, „Lizenz der Vorlage“, „Änderungen“; Schema in den COPYRIGHTS-Dateien).
  Ebenso tragen übernommene gemeinfreie Teile (Kalender nach Hinnant) einen Herkunftsblock mit „Teil“.
- **Konstanten** werden in `gen_constants.py` hergeleitet (Herleitung im Kopf des Skripts);
  Verfahrensparameter aus einem Aufsatz stehen mit Fundstelle im Dateikopf.
- **Schnittstelle.** Kein `exit`, kein `longjmp`, keine Ausgabe; Status als Rückgabewert, Text im
  Kontext; Warnungen gesammelt (gleiche Texte einmal), vom Host nach dem Aufruf ausgegeben. Kein
  globaler Zustand.
- **Gleitkomma.** Nur `double`; Flags in allen drei Builds `-O2 -std=c99 -ffp-contract=off
  -fno-fast-math` (R: `r/src/Makevars`, Python: `python/setup.py`, Julia: `julia/deps/build.jl`);
  `slc_internal.h` bricht bei `__FAST_MATH__` ab. Bitgleichheit gilt auf derselben Maschine mit
  demselben Compiler und derselben libm.
- **NA/NaN.** Elementweise Funktionen geben bei NaN-Eingabe die Eingabe selbst zurück (NA bleibt
  NA); ein ungültiger Parameter ergibt NaN und genau eine Warnung „<funktion>: NaN erzeugt“.

- **Reinraum Modelle.** Zusätzlich nicht gelesen: `python/simlev/_r/{rugarch,solnp,evd,truncnorm}.py` und die
  Julia-Gegenstücke, Quellen von rugarch, Rsolnp, evd, MSGARCH. Überführt wurde nur eigener SimLev-Code
  (`ms_garch_impl.c`, `bootstrap_core_impl.h`, `dependence_core_impl.h`, `ms_garch.R`, `regimes.R`,
  `.fit_garch11`/`.fit_tail` bis zur Grenze der Übernahmen). rugarch, evd und MSGARCH dienen nur als Orakel.
## Schätzer der Modelle (Stand und Herkunft)

- **GJR mit γ < 0 (seit 1.0.0).** GJR in `slc_garch.cpp` und je Regime in `slc_msgarch.cpp` mit γ < 0, solange
  α + γ ≥ 0 (Umparametrisierung (α/2, (α + γ)/2, β); Glosten/Jagannathan/Runkle 1993); GJR-GARCH mit
  BFGS von sieben Rasterpunkten; MS-GARCH mit analytischem Gradienten (Vorwärtsmodus, Griewank/Walther
  2008; LU nach Golub/Van Loan 2013 für die Ableitung der stationären Verteilung), `sl_msgarch_grad`,
  GJR mit 20 Starts (`SL_MSGARCH_MAXSTART` 20). Reinraum wie bei den Modellen; rugarch und MSGARCH nur als Orakel.
- **Analytischer Gradient von GJR und sGARCH (seit 1.1.0).** `slc_garch.cpp`: Vorwärtsrekursion der Ableitungen der
  bedingten Varianz (Fiorentini/Calzolari/Panattoni 1996, Griewank/Walther 2008), f und g in einem
  Durchlauf, Logarithmen über ein laufendes Produkt, `sl_garch11_grad` (theta mit 5 Werten bei GJR, 4 bei sGARCH).
- **GPD, DCC, Backcast (seit 1.1.0).** GPD-Fit (`slc_gpd.cpp`) mit geschlossenem Gradienten (Grenzfall ξ → 0 über
  eine Reihe); DCC-Fit (`slc_dcc.cpp`) mit BFGS und analytischem Gradienten (Vorwärtsrekursion von ∂Q_t/∂(a, b)) vom
  bisherigen Start, Nelder-Mead nur als Rückfall (bis 1.0.0 allein Nelder-Mead); `slc_backcast.cpp`: Zielfunktion
  von `backcast_fit` mit analytischem Gradienten und Fit über `sl_minimize` (glatte Verluste rmse, mse, hybrid; mae,
  median, max bleiben bei `.sl_optim` des Hosts). Kein `long double` in den SimLev-eigenen Kernen: Summen in
  `engine_core_impl.h` kompensiert (Neumaier), Kendalls Tau in `research_core_impl.h` ganzzahlig und in double-double
  (gleiche Ergebnisse auf x86-64 und aarch64). Quellen: Griewank/Walther (2008), Magnus/Neudecker (2019),
  Neumaier (1974), Dekker (1971), Shewchuk (1997).
- **MS-GARCH in einem Durchlauf, Threads (seit 1.2.0).** `slc_msgarch.cpp`: f und g in einem Durchlauf mit Speicher
  wie beim GARCH-Fit, Ableitungen der Anteile vor der Zeitschleife, mitgeführte Ableitung der stationären
  Verteilung nur bei 1000 Schritten, eigene Übersetzung für K = 2, 3 (alles bitgleich);
  `sl_msgarch_fit_mt`/`sl_msgarch_estimate_mt`: Starts auf mehreren POSIX-Threads (Schalter `SLC_THREADS`,
  gesetzt in `r/src/Makevars`, `python/setup.py` und `julia/deps/build.jl`, nicht unter Windows), Auswahl
  in fester Reihenfolge, Ergebnis unabhängig von der Zahl der Threads; die Hüllen reichen `cores` durch.
- **sGARCH-Fit in einem Lauf (seit 1.2.0).** `slc_garch.cpp`: Trust-Region-Newton mit exakter Hesse-Matrix (`sg_fgh`:
  f, g und H in einem Durchlauf, Vorwärtsmodus) in den natürlichen Parametern mit den Schranken ω ≥ 0, α ≥ 0,
  β ≥ 0, α + β ≤ 1 − 2⁻⁵⁰ (aktive Menge; Teilproblem über die Eigenzerlegung, Moré/Sorensen 1983). Startpunkt:
  kleinste NLL unter 12 Punkten mit Varianz-Targeting (`nll_screen`) und 8 Momentenschätzern je β (kleinste
  Quadrate, `sg_ls`), nur ausgewertet. α und β können genau 0 sein, ω ebenso. Bis 1.1.0 BFGS in der
  Umparametrisierung. GJR unverändert.

Prüfung: Plausibilität gegen R und eine eigene decimal-Referenz (nicht im Repository),
Gleichlauf der Sprachen (`tests/werkzeuge/gleichlauf/run.py --quick`).
