# core/ – C-Bibliothek slc (SimLev core)

Kanonische Quellen der C-Bibliothek, die R, Python und Julia gemeinsam nutzen.
**Nur hier ändern**, danach `python3 core/sync.py --write`; `--check` prüft die Kopien
(SHA-256) und `core/slc_constants.h` gegen den Generator.

| Datei | Inhalt |
|---|---|
| `slc.h` | öffentliche Schnittstelle (reines C99): Kontext `sl_ctx`, Generator `sl_rng`, Ziehungen, Verteilungen |
| `slc_internal.h` | interne Hilfen: Gleitkomma-Schutz, Abbruchprüfung |
| `slc_constants.h` | **erzeugt** von `gen_constants.py` (nicht von Hand ändern) |
| `slc_ctx.c` | Fehler, Warnungen, Benutzerabbruch ohne `longjmp` |
| `slc_rng.c` | xoshiro256**, SplitMix64-Seeding, Sprung um 2^128, Ströme, Gleichverteilung |
| `slc_sample.c` | ganze Zahlen (Lemire), Stichproben, normal (Inversion), exponentiell, geometrisch, Gamma (Marsaglia–Tsang), Chi-Quadrat |
| `slc_normal.c` | `erfc`, `pnorm`, `qnorm`, `dnorm` |
| `slc_special.c` | `lgamma`, unvollständige Beta, `pt`, `qt`, `plogis`, `qlogis` |
| `slc_linalg.h` | Schnittstelle von linearer Algebra, Matrixprodukt, kleinsten Quadraten, Stineman, Spline und Kerndichte (eingebunden von `slc.h`) |
| `slc_la_internal.h` | kompensierte Summen (Neumaier), Normen, NA, stabile Sortierung |
| `slc_linalg.c` | Cholesky, Band-Cholesky, Dreieckslöser, SPD-Löser, log det, symmetrische Eigenwerte (zyklisches Jacobi) |
| `slc_matmul.c` | Matrixprodukt `A B`, `X'Y`, `X Y'` mit fester Summationsreihenfolge |
| `slc_lsq.c` | kleinste Quadrate (Householder-QR, begrenzte Spaltenpivotisierung), Logit-IRLS |
| `slc_stine.c` | Stineman-Interpolation |
| `slc_spline.c` | kubischer Glättungsspline (Reinsch, GCV, Spur nach Hutchinson/de Hoog), Vorhersage |
| `slc_kde.c` | Gauß-Kerndichte, Bandbreite nach Silverman |
| `slc_opt.h`, `slc_opt.c`, `slc_opt_test.c` | Optimierer BFGS (Wolfe-Liniensuche), projizierter BFGS, Nelder-Mead, numerischer Gradient; Rückfrage an den Host und `sl_minimize`; Prüffunktionen (Quellen: Nocedal/Wright, Bertsekas, Kelley, Nelder/Mead, Lagarias u. a., Gill/Murray/Wright, Moré/Garbow/Hillstrom) |
| `slc_models.h`, `slc_garch.c`, `slc_gpd.c`, `slc_dcc.c`, `slc_msgarch.c`, `slc_boot.c` | Modelle: GARCH/GJR(1,1) (ML, Umparametrisierung, Rückfall Momente), GPD (ML, Startwerte nach Hosking/Wallis), DCC(1,1) (Filter, BFGS, Rückfall Nelder-Mead), MS-GARCH (Filter, Starts aus HMM-EM und Rangeinteilung, BFGS, Viterbi), Bootstrap-Kerne mit Strom `sl_rng` (Quellen: Bollerslev, Glosten/Jagannathan/Runkle, Pickands, Davison/Smith, Hosking/Wallis, Engle, Haas/Mittnik/Paolella, Hamilton, Baum u. a., Viterbi, Efron, Künsch, Politis/Romano, Wu, Liu, Mammen, Barone-Adesi u. a.; eigener SimLev-Code) |
| `slc_rbase.h`, `slc_rbase.c`, `slc_rbase_sort.c`, `slc_rbase_cov.c` | Grundfunktionen mit R-Regeln **für Python und Julia** (R rechnet sie selbst; nicht in `slc.h`); nur `slc_rbase.c` und `slc_rbase.h` gehen auch nach `r/src/` (`sl_r_sum` für die Summen der Tagesengine `engine_core_impl.h`, die Grundfunktionen und `sl_r_zeroin2` der Auswertung `evaluate_core_impl.h`, die Auswertung je Pfad der Entnahme `withdrawal_core_impl.h`): `sum`, `prod`, `mean`, `var`, `cumsum`/`cumprod`/`cummax`/`cummin`, `rowSums`/`colSums` (long double wie R), `^`, `approx` (Interpolation je Punkt wie `approx1` von `stats::approx`, seit 1.5.0; Prüfung `approx_fuzz.R`), `order`, `rank`, `sort(partial =)`, `quantile` Typ 1–9, `tabulate`, `findInterval`, `cov`/`cor` (pearson, kendall; alle `use`). Anders als die SimLev-eigenen Kerne (ohne long double) akkumulieren sie absichtlich in long double, damit sie auf derselben Plattform bitgleich zu R sind (Prüfung gegen R 4.3.3, ≥ 10.000 Zufallsfälle je Kern). Hüllen: `python/src/_ext_slc_rbase.c`, `julia/src/r/rbase_c.jl` |
| `slc_rbase_date.c`, `slc_rbase_num.c` | wie `slc_rbase*` nur für Python und Julia: Datumsformat und -lesen (`format.Date`/`strftime` in der C-Locale, `as.Date(x, "%Y-%m-%d")`, proleptisch gregorianisch; dokumentierte Umwandlungen aus `?strptime` textgleich zu R) und weitere long-double-Wege von R (`R_strtod`, `%%`, `%/%`, `scientific()` von `formatReal`), mit denen Julia die Nachbildung `ld80.jl` und Python `numpy.longdouble` ablöst. Schalter, Breiten und E/O im Datumsformat wie glibc unter Linux, `digits.secs` für `%OS`. Prüfung: Gleichlauf (`date_fuzz*`, `rbase_fuzz*`) |
| `gen_constants.py` | Konstanten, Bernoulli-Zahlen, zeta(k), Stützwerte und Taylor-Polynome, Sprungpolynom, selbst angepasste rationale Näherungen für `qnorm` (nur Standardbibliothek) |

**Geteilte C++-Kerne von R, Python und Julia:** Auch die C++-Kerne liegen hier: `simlev_core.h` (Aufbau, Host-Schnittstelle, `NA`),
`engine_core_impl.h` (Tagesengine; bis 1.3.0 `simulation_core_impl.h`, `fifo_core_impl.h`,
`tax_core_impl.h`), `prepare_core_impl.h` (Vorbereitung von `simulation()`), `evaluate_core_impl.h`
(Auswertung von `simulation()` und XIRR), `tariff_core_impl.h` (Einkommensteuertarif), `research_core_impl.h`
(Optimierung, Quantilsregression, HMM, rollierende Kennzahlen, Kendalls Tau) und
`withdrawal_core_impl.h` (Entnahme). Sie folgen nicht den slc-Regeln unten (eigener SimLev-Code, C++17,
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
(`sim_engine_run`), `simlev_cabi.cpp` (`simlev_c_engine_*`). Summen wie R in long double über `sl_r_sum`
(`slc_rbase.c`, dafür auch in `r/src/`). Prüfung: Gleichlauf `sim_fuzz.R` gegen R 1.3.0.

**Vorbereitung:** `prepare_core_impl.h` rechnet vor der Tagesschleife die Termine (`calculate_dates_flags`
mit der Monatsarithmetik von `seq.Date`), Split-Termine, die Tagesflags samt Verschieben von Terminen auf
aufgefüllten Tagen, Aktivierung, Freibetragstage, Jahreswechsel und VP-Abrechnungstage, Startgewichte und
Anfangszustand; die Engine bindet sie ein (`Engine::setup_prepared`). Die Sprachen prüfen die Eingaben (Texte) und
wandeln die Angaben (`span`, `days`, `harvest_day`) wie R (`.sched_spec`). Hüllen wie die Tagesengine, dazu
`calculate_dates_flags` (`C_sim_dates_flags`, `sim_dates_flags`, `simlev_c_dates_flags`). Prüfung zusätzlich:
Gleichlauf `sched_fuzz.R` (Datums-Fuzz) gegen R 1.3.0.

**Auswertung:** `evaluate_core_impl.h` rechnet nach dem Lauf Depotwert und Zuflüsse je Tag, CAGR (mit
Einzahlungen geldgewichtet über XIRR: Brent wie `stats::uniroot` über `sl_r_zeroin2` in `slc_rbase.c`), TTWROR,
zeitgewichteten Wertindex, Drawdowns, Tagesrenditen ohne aufgefüllte Tage, Performance- und Risikokennzahlen
(Sharpe, Sortino, Calmar, Omega, Ulcer, Martin, Serenity, Schiefe, Kurtosis, Partialmomente, Drawdown-Dauern),
Käufe/Verkäufe je Jahr und die Ursachen nicht definierter Kennzahlen (`undefined_metrics`) als Codes. Warnungen
und Abbrüche (NA in einer Bedingung) meldet der Kern mit Werten bzw. Stelle; die Sprachen setzen die Texte und
rechnen `risk_free` aus `data` (Typen, Meldungen). Hüllen: `r/src/engine_core.cpp` (`C_sim_evaluate`,
`C_sim_xirr`), `python/src/_ext_engine.cpp` (`sim_evaluate`, `sim_xirr`), `simlev_cabi.cpp` (`simlev_c_eval_*`,
`simlev_c_xirr`). Summen, Mittel, Varianz, Kumulationen und Potenz wie R über `slc_rbase.c`. Prüfung zusätzlich:
Gleichlauf `metric_fuzz.R` (Fuzz der Kennzahlen) gegen R 1.3.0.

**Entnahme:** `withdrawal_core_impl.h` rechnet die Pfade von `withdrawal_simulation()` (`wd_simulate`, Regeln,
Steuer, Tarifweg) und seit 1.5.0 auch die Auswertung je Pfad, die bis 1.4.3 jede Sprache selbst rechnete:
`wd_metrics` (Mittel, Minimum, Drawdown `max(1 - c / cummax(c))`, Sicherheitsäquivalent und Summe der Entnahmen
über die vollen Planjahre bzw. bis zum Horizont), `wd_pwr` (Perfect Withdrawal Rate mit den Prüfungen von
`withdrawal_perfect_rate()` als Status; je Pfad bis zum Horizont), `wd_annual_prod` (reale Jahresrenditen aus
Perioden) und `wd_tariff_compact` (Jahreszeilen des Tarifwegs). Reine Funktionen auf Zeigern (reentrant); Summen,
Mittel, Produkte, Kumulationen und Potenz über `slc_rbase.c`, `min`/`max`/`pmax` mit R's NA-Regeln. Die Sprachen
setzen die Meldungen (Texte und Aufrufe wie bisher), Namen und Datenrahmen. Hüllen: `r/src/withdrawal_core.cpp`
(`C_wd_metrics`, `C_wd_pwr`, `C_wd_annual_prod`, `C_wd_tariff_compact`), `python/src/_ext_withdrawal.cpp`,
`simlev_cabi.cpp` (`simlev_c_wd_*`). Prüfung zusätzlich: Gleichlauf `wd_fuzz.R` gegen R 1.4.2.

**Forschung (seit 1.5.0):** `research_core_impl.h` rechnet außer Optimierung, Quantilsregression, Vorwärts-
Rückwärts-Schritt und rollierenden Kennzahlen auch den Baum-Welch-EM von `regime_hmm()` (`hmm_em`: E-Schritt mit
Log-Dichten über `sl_chol`/`sl_trisolve`, M-Schritt mit `sl_crossprod`, Abbruchtest; ein Fehler verwirft wie bisher
den Startwert), die Rückwärtsrekursion von `planning_goal()` (`goal_dp`: Wertfunktion auf dem Gitter, Interpolation
über `sl_r_approx`, `sl_qnorm`/`sl_pnorm`, Politik je Periode; gleiche `log(grid)`-Werte fasst es wie `approx`
zusammen und meldet die Zahl der Aufrufe für die Warnungen der Sprachen) und die Aufteilungen der CSCV von
`overfit_pbo()` (`pbo_cscv`: Blocksummen über `sl_matmul`, Kennzahlen, bester Punkt, Rang, Logit, Median).
Startwerte und Zufall (`regime_hmm`), Gitter und Vorwärtssimulation (`planning_goal`), Blocksummen und Regression
(`overfit_pbo`) bleiben in den Sprachen. Hüllen: `r/src/research_core.cpp` (`C_hmm_em_core`, `C_goal_dp`,
`C_pbo_cscv`), `python/src/_ext_research.cpp`, `simlev_cabi.cpp` (`simlev_c_hmm_em`, `simlev_c_goal_dp`,
`simlev_c_pbo_cscv`). Prüfung zusätzlich: Gleichlauf `hmm_fuzz.R`, `goal_fuzz.R`, `pbo_fuzz.R` gegen R 1.4.2.

Kopien (Pakete bauen nur aus ihrem Teilbaum): `r/src/` (flach), `python/src/core/`,
`julia/deps/core/` (slc, die geteilten Kerne und `simlev_cabi.cpp`). Die Hüllen gibt es nur je Sprache: `r/src/slc_r.c` (+ `r/R/slc.R`),
`python/src/_ext_slc.c` (+ `python/simlev/_lib.py`), `julia/src/slib.jl` (`ccall`, gebaut von
`julia/deps/build.jl`).

## Regeln

- **Reinraum.** Kerne entstehen nur aus Veröffentlichungen und Mathematik (DLMF,
  Abramowitz/Stegun, Blackman/Vigna, Steele u. a., Lemire, Knuth, Devroye, Marsaglia/Tsang,
  Lentz, Dekker). Nicht gelesen werden dabei `r/R/vendor_*`, `r/src/vendor_*`, die Port-Module
  in `python/simlev/_r/` und `julia/src/r/` (`rng`, `nmath`, `_toms708` …), `python/src/_rng_r.c`
  sowie R- und Paketquellen. R und die alten Pakete dienen nur als Prüforakel (Zahlen vergleichen).
- **Reinraum lineare Algebra, Glättung, Kerndichte.** Zusätzliche Quellen: Golub/Van Loan, Jacobi, Demmel/Veselić,
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

- **GJR mit γ < 0 (seit 1.0.0).** GJR in `slc_garch.c` und je Regime in `slc_msgarch.c` mit γ < 0, solange
  α + γ ≥ 0 (Umparametrisierung (α/2, (α + γ)/2, β); Glosten/Jagannathan/Runkle 1993); GJR-GARCH mit
  BFGS von sieben Rasterpunkten; MS-GARCH mit analytischem Gradienten (Vorwärtsmodus, Griewank/Walther
  2008; LU nach Golub/Van Loan 2013 für die Ableitung der stationären Verteilung), `sl_msgarch_grad`,
  GJR mit 20 Starts (`SL_MSGARCH_MAXSTART` 20). Reinraum wie bei den Modellen; rugarch und MSGARCH nur als Orakel.
- **Analytischer Gradient von GJR und sGARCH (seit 1.1.0).** `slc_garch.c`: Vorwärtsrekursion der Ableitungen der
  bedingten Varianz (Fiorentini/Calzolari/Panattoni 1996, Griewank/Walther 2008), f und g in einem
  Durchlauf, Logarithmen über ein laufendes Produkt, `sl_garch11_grad` (theta mit 5 Werten bei GJR, 4 bei sGARCH).
- **GPD, DCC, Backcast (seit 1.1.0).** GPD-Fit (`slc_gpd.c`) mit geschlossenem Gradienten (Grenzfall ξ → 0 über
  eine Reihe); DCC-Fit (`slc_dcc.c`) mit BFGS und analytischem Gradienten (Vorwärtsrekursion von ∂Q_t/∂(a, b)) vom
  bisherigen Start, Nelder-Mead nur als Rückfall (bis 1.0.0 allein Nelder-Mead); `slc_backcast.c`: Zielfunktion
  von `backcast_fit` mit analytischem Gradienten und Fit über `sl_minimize` (glatte Verluste rmse, mse, hybrid; mae,
  median, max bleiben bei `.sl_optim` des Hosts). Kein `long double` in den SimLev-eigenen Kernen: Summen in
  `engine_core_impl.h` kompensiert (Neumaier), Kendalls Tau in `research_core_impl.h` ganzzahlig und in double-double
  (gleiche Ergebnisse auf x86-64 und aarch64). Quellen: Griewank/Walther (2008), Magnus/Neudecker (2019),
  Neumaier (1974), Dekker (1971), Shewchuk (1997).
- **MS-GARCH in einem Durchlauf, Threads (seit 1.2.0).** `slc_msgarch.c`: f und g in einem Durchlauf mit Speicher
  wie beim GARCH-Fit, Ableitungen der Anteile vor der Zeitschleife, mitgeführte Ableitung der stationären
  Verteilung nur bei 1000 Schritten, eigene Übersetzung für K = 2, 3 (alles bitgleich);
  `sl_msgarch_fit_mt`/`sl_msgarch_estimate_mt`: Starts auf mehreren POSIX-Threads (Schalter `SLC_THREADS`,
  gesetzt in `r/src/Makevars`, `python/setup.py` und `julia/deps/build.jl`, nicht unter Windows), Auswahl
  in fester Reihenfolge, Ergebnis unabhängig von der Zahl der Threads; die Hüllen reichen `cores` durch.
- **sGARCH-Fit in einem Lauf (seit 1.2.0).** `slc_garch.c`: Trust-Region-Newton mit exakter Hesse-Matrix (`sg_fgh`:
  f, g und H in einem Durchlauf, Vorwärtsmodus) in den natürlichen Parametern mit den Schranken ω ≥ 0, α ≥ 0,
  β ≥ 0, α + β ≤ 1 − 2⁻⁵⁰ (aktive Menge; Teilproblem über die Eigenzerlegung, Moré/Sorensen 1983). Startpunkt:
  kleinste NLL unter 12 Punkten mit Varianz-Targeting (`nll_screen`) und 8 Momentenschätzern je β (kleinste
  Quadrate, `sg_ls`), nur ausgewertet. α und β können genau 0 sein, ω ebenso. Bis 1.1.0 BFGS in der
  Umparametrisierung. GJR unverändert.

Prüfung: Plausibilität gegen R und eine eigene decimal-Referenz (nicht im Repository),
Gleichlauf der Sprachen (`tests/werkzeuge/gleichlauf/run.sh --quick`).
