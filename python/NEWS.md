# simlev (Python) – Änderungen je Version

## simlev (Python) 0.6.0

Minor-Update (Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Grafik: Python zeichnet wie Julia eigenes SVG statt matplotlib; Dashboard, Analyse-, Abhängigkeits- und Überanpassungsgrafiken in einem Grafikmodul je Sprache.
- Datenobjekt: Grafiken liefern SimLevPlot mit svg, data, source und kind, damit eigene Darstellungen aus den Daten möglich sind.
- Optionen der Grafikfunktionen nur noch als Schlüsselwort.

## simlev (Python) 0.5.1

Patch-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Abhängigkeiten: evd (GPD-Anpassung), imputeTS/stinepack (Interpolation), rugarch mit Rsolnp und truncnorm (GARCH-Schätzung) als interne Teile eingebaut; R braucht zur Laufzeit nur Basis-R.
- Ableitungen: eigene Richardson-Extrapolation für Hesse- und Jacobi-Matrix statt numDeriv.
- C/C++-Kerne: Anbindung über R's C-Schnittstelle statt Rcpp, Fehlertexte unverändert.
- Ports: Python und Julia bilden die eingebauten Teile bitgleich nach; kleinere Korrekturen in Simulation und linearer Algebra.

## simlev (Python) 0.5.0

Die Python-Fassung ist jetzt ein vollständiger Port des R-Pakets SimLev
0.5.0: alle 104 Exporte aus `r/NAMESPACE`, bitgleich zu R. Die Vorversion
0.1.0 enthielt nur die Engine und entsprach dem früheren Stand des
R-Pakets vor den Korrekturen (Commit 54b5b4f). Zwischenversionen 0.2 bis
0.4 der Python-Fassung gibt es nicht; alle Änderungen sind in 0.5.0
zusammengefasst. Die Begründungen der fachlichen Änderungen stehen in
[`r/NEWS.md`](../r/NEWS.md), Abschnitt „SimLev 0.5.0“.

### Engine (`simulation()`)

* Alle Korrekturen der R-Engine nach dem Stand 54b5b4f sind übernommen,
  u. a. Fondsmodus (Fondskosten je Kalendertag, High-Watermark), Splits mit
  ganzen Anteilen, später startende Assets, Sparplantermine, unsortierte,
  doppelte oder fehlende Daten, Rebalancing zum Tageskurs und die Sortino
  Ratio.
* Steuerrecht wie in R 0.5.0: Vorabpauschale (u. a. Basiszins vom ersten
  Handelstag, Abrechnung im Folgejahr), Verlustverrechnung mit Erstattung
  zum Jahreswechsel, § 23 EStG (Freigrenze, Zahlung aus dem Depot),
  Günstigerprüfung, Steuerschätzung bei Umschichtungen und Zwangsverkäufe.
* Kennzahlen mit Sparplan wie in R: `cagr` ist die geldgewichtete Rendite
  (XIRR), Drawdowns, Ulcer Index und Drawdown-Dauern werden auf dem
  zeitgewichteten Wertindex gemessen.
* Neue Argumente: `balance_thresh_type` (relative Rebalancing-Bänder),
  `order_fee`, `dca_fee`, `church_tax`, `harvest_mode`, `harvest_day`,
  `harvest_loss_pot`, `taxable_income` und `tax_tariff`; neue Funktion
  `read_tax_tariff()` mit der mitgelieferten Tarifdatei
  `simlev/data/steuertarif.csv` (ab VZ 2026).
* Neue Ergebniselemente: `twr_index`, `invested`, `external_flows`,
  `undefined_metrics`, `open_lots`, `fees_paid`, `harvest_days`,
  `tax_report["open_tax_debt"]`, `tax_report["tariff_years"]` und
  `tax_report["next_year"]`.
* Prüfungen, Warnungen und Fehlermeldungen wie in R, z. B. bei doppelten
  Datumswerten, Kursen ≤ 0, wirkungslosen Argumenten (`spread`,
  `funds_fee`/`bonus_fee` bei anderem `tax_mode`) und Raten, die
  vermutlich als Anteil statt in Prozent angegeben sind.
* Alle Ausgaben sind deutsch und zeichengleich zu R: `print()`,
  `summary()`, Meldungen, Warnungen, Fehlermeldungen und die
  Beschriftungen des Dashboards.
* Dashboard wie in R: Kennzahlen-Panel, Volatilität, rollierende und
  monatliche Renditen stimmen mit `statistics` überein (mit Sparplan
  zuflussbereinigt); die vereinfachte „Sharpe Ratio“ `(CAGR − 2 %) /
  (σ · √252)` entfällt. Das HTML von `plot_interactive()` ist
  byte-identisch zu R.

### Erweiterungen (neu)

Alle Erweiterungsmodule des R-Pakets sind portiert, je R-Datei ein
Python-Modul:

* Datenaufbereitung (`data_prep`): `align_series()`, `check_series()`,
  `align_macro()`, `convert_currency()`, `total_return_index()`,
  `deflate()`, `splice_series()`, `strategy_from_weights()`,
  `portfolio_template()` (ohne `name` die Liste der Vorlagen).
* Backcast (`backcast`): `backcast_fit()`, `backcast()`.
* Anleihen und Geldmarkt (`bonds`): `bond_index_from_yields()`,
  `money_market_index()`, `currency_hedged_index()`.
* Signale (`signals`): `signal_sma()`, `signal_ema()`, `signal_crossover()`,
  `signal_momentum()`, `signal_drawdown()`, `signal_volatility()`,
  `signal_combine()`.
* Bootstrap (`bootstrap`): `bootstrap_config()`,
  `block_length()`, `bootstrap()`, `validate_bootstrap()`,
  `bootstrap_data()`, `study_metrics()`, `bootstrap_study()`,
  `bootstrap_probability()` mit allen Verfahren.
* Entnahmephase (`withdrawal`): `withdrawal_rule()`, `withdrawal_cohorts()`,
  `result_index()`, `withdrawal_paths()`, `perfect_withdrawal_rate()`,
  `withdrawal_simulation()`, `withdrawal_max_rate()`, `horizon_model()`.
* Analyse und Sensitivitäten (`deep_analysis`, `sensitivity`):
  `deep_analysis()`, `sensitivity_grid()`, `rebalancing_sensitivity()`,
  `lumpsum_vs_dca()`, `leveraged_series()`, `leverage_sensitivity()`.
* Parametersuche und Überanpassung (`param_search`, `overfitting`):
  `param_space()`, `param_range()`, `param_search()`, `plateau()`, `pbo()`,
  `probabilistic_sharpe()`, `deflated_sharpe()`, `walk_forward()`,
  `param_bootstrap()`, `sharpe_haircut()`.
* Abhängigkeiten (`dependence`): `fit_copula()`, `tail_dependence()`,
  `dcc_fit()`, `dependence_analysis()`, `quantile_reg()`,
  `tail_regression()`, `covar_analysis()`, `validate_dependence()`,
  `regime_subset()`.
* Regime (`regimes`): `regime_hmm()`, `regime_states()`.
* Szenarien (`scenarios`): `view_mean()`, `view_prob()`, `view_vol()`,
  `entropy_pooling()`, `copula_scenarios()`, `scenario_risk()`,
  `crisis_replay()`.
* Taktik (`tactical`): `signal_state()`, `momentum_score()`,
  `tactical_rules()`, `tactical_rotation()`, `target_volatility()`,
  `conditional_volatility()`, `glidepath()`, `blend_weights()`,
  `tactical_simulation()`.
* Optimierung (`optimize`): `portfolio_optimize()`, `efficient_frontier()`,
  `rolling_optimization()`, `risk_contributions()`, `cpcv_portfolio()`.
* Planung (`planning`): `set_expected_return()`, `pooled_bootstrap()`,
  `portfolio_returns()`, `goal_optimize()`.
* Prüfungen (`analysis_tests`): `signal_analysis()`, `sharpe_test()`,
  `reality_check()`, `min_track_record()`, `return_heatmap()`.

Die C++-Kerne des R-Pakets stehen in `_bootstrap_core.py`,
`_withdrawal_core.py`, `_dependence_core.py`, `_optimize_core.py` und
`_signals_core.py`. Die `plot()`-Methoden der Ergebnisobjekte zeichnen wie
die Julia-Fassung als SVG (siehe unten, „Grafiken ohne matplotlib“).

### R-Kompatibilitätsschicht `simlev._r` (neu)

Für die Bitgleichheit der Erweiterungen sind die benötigten R-Interna
nachgebaut: Zufallszahlen (Mersenne-Twister, L'Ecuyer-CMRG-Streams,
`sample.int`, `rnorm`, `rt`, `rchisq`, `rgeom` …), Verteilungsfunktionen
aus nmath (`qnorm`, `pt`, `qt`, `pbeta` mit TOMS 708, `lgamma` …),
stats-Funktionen (`quantile`, `cor` mit Kendall und Spearman, `optim` mit
Nelder-Mead, BFGS, CG und L-BFGS-B, `optimize`, `uniroot`, `lm`, `glm`,
`poly`, `smooth.spline`, `density`, `fft`, `hclust`, `p.adjust`,
`t.test` …), lineare Algebra (Matrixprodukte wie die Referenz-BLAS,
`solve`, `chol`, `qr` nach LINPACK, `determinant`, `eigen`) sowie
Formatierung und Druck (`format`, `formatC`, `sprintf`, `round`, `print`
von Vektoren, Matrizen und data.frames). Eigenvektoren von `eigen()`
kommen über ctypes aus der Referenz-LAPACK des Systems (Pfad über
`SIMLEV_LAPACK` wählbar); fehlt sie, rechnet numpy ohne
Bitgleichheitsgarantie und mit einer Warnung.
Zeichenketten sortiert und vergleicht SimLev wie R mit der ICU-Kollation
(System-ICU, `SIMLEV_ICU`, `SIMLEV_COLLATE`).

Innerer Aufbau (ohne Änderung der öffentlichen Namen und Ergebnisse):

* Die R-Numerik der Engine liegt unter `simlev/_r/`: `rnum.py` (früher
  `simlev/_rnum.py`; `NA_REAL`, long-double-Summen, `r_pow`, `r_uniroot`)
  und `rformat.py` (`r_round`, `r_signif`, `r_format`, `r_sprintf` …),
  wie `rnum.jl` und `rformat.jl` der Julia-Fassung. `NA_REAL` ist nur noch
  in `rnum.py` definiert, alle anderen Module importieren es; das
  gleichbedeutende Alias `fmt.R_NAN` für R's NaN entfällt (`math.nan`).
  Die PORT-Bibliothek für `nlminb` heißt `simlev/_r/port.py` (wie
  `port.jl`).
* `quiet_fp` (`simlev/_r/base.py`) hüllt jetzt alle öffentlichen
  Funktionen, auch `tactical_rules()`, `regime_subset()`,
  `entropy_pooling()` und `bootstrap_probability()`: Für diese setzt es
  bei fehlendem `env` den Namensraum des Aufrufers ein (`env_from_caller`),
  statt dass die Funktionen selbst den Aufrufer-Frame lesen.
* Die Engine-Notiz `PORTING_ENGINE.md` ist in `DEVELOPING.md`
  aufgegangen.
* Alle SVG-Zeichenbausteine stehen im Grafikmodul `simlev/svg.py`
  (Abschnitte und Namen wie `julia/src/svg.jl`, ein Präfix je Grafikstil).

### Änderungen der Schnittstelle

* Ergebnisobjekte mit R-Klasse erben von `simlev._r.rlist.RList`, einem
  geordneten `dict` mit Attributzugriff (`res["worth"]` und `res.worth`,
  Elemente in R-Reihenfolge). `SimLevResult` ist keine dataclass mehr;
  `buys` und `sells` sind `pandas.Series` statt `dict`. `trades` bleibt als
  Attribut erhalten (nur Python).
* `result.summary()` druckt nicht mehr selbst und liefert statt eines
  `dict` ein `SimLevSummary`, das wie in R druckt (`verbose=True` druckt
  zusätzlich). Neu sind die generischen Funktionen `simlev.summary(x)` und
  `simlev.plot(x)`, die die Methode des Objekts aufrufen.
* Entfernt wie in R: `plot_interactive()` (Funktion und Methode
  `result.plot_interactive()`, eigenes HTML und plotly-Figur; Modul
  `simlev.interactive`), `export_html_dashboard()`, `create_config()`,
  `migrate_strategy()`, `as_list()` und `portfolio_templates()` (jetzt
  `portfolio_template()` ohne `name`). Das statische Dashboard
  (`result.plot()`, `export_dashboard()`) bleibt. In `pyproject.toml`
  entfällt das Extra `plotly`.
* scipy entfällt: Der Ersatzweg für Eigenvektoren ohne System-LAPACK
  rechnet jetzt immer mit numpy (wie die Julia-Fassung mit LinearAlgebra,
  mit Warnung, nicht bitgleich); das Extra `scipy` entfällt.
* Grafiken ohne matplotlib: Dashboard und alle `plot()`-Methoden zeichnen
  wie die Julia-Fassung ohne Zusatzpaket als SVG (`simlev/svg.py`) und
  liefern ein `simlev.SimLevPlot` statt einer matplotlib-Figure. Es hat
  die Felder `svg`, `data` (die dargestellten Werte je Panel als
  pandas-Tabellen, unskaliert und nicht ausgedünnt; für eigene Grafiken),
  `source` (das Eingabeobjekt) und `kind` (dessen Klasse), wird in
  Jupyter direkt angezeigt und mit `save("….svg")` gespeichert. Die
  Argumente `ax`, `fig`, `figsize` und `show` entfallen; die Größe
  steuern `width` und `height` in Pixeln wie in Julia, geschrieben wird
  nur mit `file="….svg"` (andere Endungen ergeben einen Fehler).
  Optionen gibt es wie in Julia nur als Schlüsselwort: Positionsargumente
  nach dem Objekt und unbekannte Schlüsselwörter ergeben eine Warnung und
  werden ignoriert. `export_dashboard()`
  schreibt nur noch SVG (Standard `"dashboard.svg"`). Die Extras `plot`
  und `all` entfallen, `test` braucht nur noch pytest.
  Die Grafik einer Bootstrap-Studie mit weniger als zwei Werten bricht
  jetzt wie R und Julia mit „need at least 2 points to select a bandwidth
  automatically“ ab (früher numpy-Ersatz). Die rollierende Korrelation des
  Dashboards setzt für ungültige Fenster NA statt NaN (wie R).
* Benötigt wird Python ab 3.10 (`requires-python = ">=3.10"`, vorher 3.9).
* Das Argument `currency` des Dashboards entfällt; die Achse ist wie in R
  in EUR beschriftet.
* Neu: `simlev.set_seed()` (wie `set.seed()`) und `simlev.rng_kind()`.
* `simlev.bootstrap`, `simlev.backcast`, `simlev.deep_analysis` und
  `simlev.param_search` sind zugleich Modul und aufrufbare Funktion.
* Argumente, die in Python Schlüsselwörter sind, heißen `yield_`,
  `raise_` und `from_`.
* Das Paket enthält Daten (`simlev/data/steuertarif.csv`,
  `simlev/data/r_colors.csv`) und das Unterpaket `simlev._r`.

### Prüfwerkzeuge

* `tools/compare_golden.py` prüft ohne Pfadangabe `golden/cases` (68 Fälle)
  und `golden/extra` (37 Fälle) und nimmt mehrere Ordner oder Dateien sowie
  die Optionen `-k`, `-v` und `-q`. Alle 105 Fälle sind bitgleich
  einschließlich Druckausgabe und `details = TRUE`, ebenso 669 frisch
  erzeugte Zufalls- und Stressfälle und 750 Fälle mit den neuen Argumenten.
  Die Test-Suite prüft jetzt auch `golden/extra`.
* Neu: `tools/compare_reference.py` und `tests/test_module_reference.py`
  vergleichen alle Funktionen und die R-Interna mit 4.536 Referenzfällen
  aus `golden/modules/` (erzeugt mit den R-Generatoren
  `golden/modules/gen_<modul>.R`), darunter das Modul `engine` mit 249
  Fällen zu den Argumenten und Ergebniselementen von 0.5.0; alle sind
  bitgleich.
* Beide Werkzeuge prüfen strikt: `NA` ≠ `NaN` und das Vorzeichen der Null
  (`SIMLEV_LAX_NA=1` bzw. `SIMLEV_STRICT_ZERO=0` lockern das).
* Neu: Nachbildung von imputeTS 3.4 (`na_interpolation(option = "stine")`
  mit stinepack 1.5 `stinterp`) in `simlev._r.imputets` und
  `simlev._r.stinepack`; `fill = "stine"` bzw. `index_fill = "stine"` im
  Backcast interpolieren standardmäßig wie R mit imputeTS nach Stineman.
  Neues Referenzmodul `imputets` (203 Fälle).
* `simulation()` bricht nicht mehr mit „subscript out of bounds“ ab, wenn
  `funds_fee` oder `bonus_fee` außerhalb des Fondsmodus zusammen mit
  `church_tax`/`tax_rate` oder `taxable_income` angegeben ist (Korrektur in
  R 0.5.0, siehe `r/NEWS.md`, Nachtrag); bisher bildete Python den Fehler
  nach.
* Neu: Nachbildung der optionalen R-Pakete evd (2.3-7.1, `fpot`) und
  rugarch (1.5-6, `ugarchfit` für sGARCH/gjrGARCH(1,1) mit Normalverteilung
  und Solver „hybrid“: Rsolnp 1.16 `solnp`, dann `nlminb`, dann zweimal
  `gosolnp` mit `truncnorm::rtruncnorm` 1.0-9) in `simlev._r.evd`,
  `simlev._r.rugarch`, `simlev._r.solnp`, `simlev._r.truncnorm`, dazu
  `simlev._r.stats.nlminb` (PORT, alle sechs Varianten). Standardmäßig wie
  R mit beiden Paketen: `.fit_tail` schätzt den Tail ab 30 Überschreitungen
  per ML (`method = "MLE"`), `.fit_garch11` per rugarch (`method =
  "rugarch"`) mit dessen Warnungen. Neue Referenzmodule `evd` (129 Fälle),
  `r_nlminb` (104) und `rugarch` (173).
* evd ist kein Schalter mehr: Das R-Paket hat `evd::fpot` übernommen
  (`.evd_fpot`, siehe `r/NEWS.md`, „Optionale Pakete eingebaut“) und
  schätzt den Tail ab 30 Überschreitungen immer per ML; `_fit_tail` ebenso.
  Herkunft und Lizenz der Nachbildung in `COPYRIGHTS.md`.
* imputeTS ist kein Schalter mehr: Das R-Paket hat
  `imputeTS::na_interpolation(option = "stine")` mit `na_locf` und
  stinepack `stinterp` übernommen (`.imputets_na_interpolation`, siehe
  `r/NEWS.md`, „Optionale Pakete eingebaut“) und interpoliert mit
  `fill`/`index_fill = "stine"` immer nach Stineman; `_fill_na` ebenso
  (kein Rückfall auf linear mit Hinweis). `simlev._r.imputets.na_interpolation`
  mit `option = "linear"` interpoliert wie imputeTS (auch in R übernommen);
  wie die Übernahme brechen `option = "spline"` und `na_locf` mit
  `na_remaining = "rm"`/`"mean"` mit deren Meldung ab (bisher eigene
  Meldung).
  Herkunft und Lizenz der Nachbildung in `COPYRIGHTS.md`.
* rugarch ist kein Schalter mehr: Das R-Paket hat `rugarch::ugarchfit`
  mit Rsolnp `solnp`/`gosolnp` und truncnorm `rtruncnorm` übernommen
  (`.rugarch_ugarchfit`, siehe
  `r/NEWS.md`, „Optionale Pakete eingebaut“) und schätzt GARCH in
  Bootstrap (`garch`/`gjr_garch`, Kopplung), `dcc_fit()` und
  `dependence_analysis()` immer per rugarch; `_fit_garch11` ebenso (`optim`
  und die Momente nur noch als Rückfall bei einem Fehler). Herkunft und Lizenz der
  Nachbildungen (rugarch, Rsolnp, truncnorm) in `COPYRIGHTS.md`.
* Numerische Ableitungen (Richardson-Extrapolation) eigenständig
  implementiert: Hesse-Matrix und Scores der GARCH-Schätzung rechnen
  `simlev._r.rugarch._richardson_hessian` und `_richardson_jacobian` wie
  `.sl_richardson_hessian`/`.sl_richardson_jacobian` im R-Paket statt einer
  Nachbildung von numDeriv; Ergebnisse gegen numDeriv geprüft und bitgleich.
* Kein Schalter für optionale R-Pakete: Da R evd, imputeTS und rugarch
  übernommen hat, entfallen `simlev._r.suggests` (`has`, `EMULATED`) und
  die Umgebungsvariable `SIMLEV_R_SUGGESTS`; die Referenzfälle haben kein
  Feld `suggests` mehr. Die MS-GARCH-Verfahren melden weiterhin wie R
  ohne MSGARCH, dass das Paket fehlt.
* Neu: `NA` und `NaN` werden wie in R unterschieden. `simlev.NA` ist R's
  `NA_real_` (NaN mit Nutzlast 1954), ein gewöhnliches `nan` ist R's `NaN`;
  `simlev.isna_strict(x)` erkennt nur `NA`. Druckausgabe, `format()`,
  `sprintf()`, Summen und Kumulationen folgen R's Regeln für beide.
* Die Test-Suite umfasst 5.755 Tests; die Tests der R-Engine aus
  `r/tests/testthat` sind übertragen.

### Bekannte Grenzen

* Bitgleichheit gilt unter Linux x86-64 (80-Bit-`long double`) mit
  glibc-libm und, für Eigenvektoren, mit der Referenz-LAPACK des Systems.
* Die Referenzen entstanden mit R 4.3.3. evd, rugarch und imputeTS sind
  nachgebildet und gelten immer, wie das R-Paket mit seinen übernommenen
  Fassungen. gosolnp setzt wie in R den Zufallszustand aus der
  Uhrzeit; reproduzierbar mit `SIMLEV_R_SYS_TIME`. MSGARCH gilt als nicht
  installiert; die MS-GARCH-Verfahren melden wie R ohne MSGARCH, dass das
  Paket fehlt.
* `nlminb`: An drei Stellen liest die PORT-Bibliothek nicht gesetzte
  Variablen (in R Stapelreste); Python setzt 0. Das kann nur in
  Sonderfällen die Meldung (Code 3 statt 5, `convergence` 0) oder Läufe mit
  Inf/NaN in Gradient bzw. Hesse-Matrix ändern.
* Grafiken zeigen dasselbe wie in R, sind aber nicht bitgleich.
* Bedingungen als Text (`tactical_rules()`, `bootstrap_probability()`,
  `regime_subset()`, `view_prob()`) werden in R-Syntax ausgewertet
  (`simlev._r.rexpr`, wie in der Julia-Fassung); Funktionsdefinitionen,
  Schleifen und benannte Vektoren unterstützt der Auswerter nicht.
* `bootstrap_study()` schreibt Zwischenstände als Pickle statt RDS.
* `cores > 1` rechnet sequenziell, mit derselben Zufallssemantik wie
  `mclapply(mc.set.seed = FALSE)`.
* Nichtzentrale Verteilungen (`ncp`) und einige selten genutzte
  stats-Optionen sind nicht portiert, weil das Paket sie nicht nutzt.
