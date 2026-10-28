# simlev (Python) – Änderungen je Version

## simlev (Python) 0.10.0

Minor-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Wrapper: wrapper_config() und asset_config(wrapper = ) bilden einen Zertifikat- bzw. Fonds-Wrapper als eigene Kursreihe ab (wrapper_nav()); innere Assets mit eigenem Umschichten und Orderkosten, tägliche Verwaltungs- und Performancegebühr mit High-Water-Mark; außen gelten Spread, Gebühren und Steuern wie bei jedem Asset.
- Geändert: asset_config() hat den Standard-Spread 0; der alte Fondsmodus simulation(funds = ) entfällt.
- Strategien: strategy_from_weights() und portfolio_template() nehmen Wrapper je Asset.
- Qualität: NaN-Randfälle der reinen Python- und Julia-Kerne an R angeglichen; Messskript überschreibt keine Ergebnisse.

## simlev (Python) 0.9.1

Patch-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Python: C-Erweiterung mit denselben Kernen wie R (Engine, FIFO, Steuer, Research, Entnahme, Abhängigkeit, Bootstrap, MS-GARCH-Filter), Zufallszahlen bitgleich zu R; reines Python bleibt als Rückfall.
- R: Parallelität gebündelt (wenige Forks statt einer je Einheit), z. B. bootstrap mit 2 Kernen 2,2 s -> 0,2 s.
- Ergebnisse in allen drei Sprachen unverändert.

## simlev (Python) 0.9.0

Minor-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Namen: einheitliche Benennung der Funktionen und Argumente in allen drei Sprachen (Tabelle alt -> neu im Abschnitt 0.5.0).
- Simulation: simulation() mit Bausteinen sim_costs, dca_plan, rebalance_plan, split_rule, tax_profile und funds_costs; Pfadnotation wie "dca.value" für Raster und Suchräume.
- Aufrufer: Bootstrap-Studien, Parametersuche, Sensitivitäten und Planung gehen über simulation(); Optionen nur noch als Schlüsselwort.
- Schnittstelle: Stand der drei Sprachen eingefroren und automatisch abgeglichen.

## simlev (Python) 0.8.0

Minor-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Prüfwerkzeuge: Abgleich der Schnittstelle der drei Sprachen (tools/api_snapshot), Referenzfälle in kompaktem Format mit gemeinsamen Eingaben, Laufzeitmessung (tools/bench).
- Verschlankung: entfernt sind interaktive Grafiken, create_config, migrate_strategy, as_list sowie scipy und TTR; Engine in Teilmodule aufgeteilt, Schichtentest, Schalter SIMLEV_* an einer Stelle.
- Parallelität: cores in Python (Fork-Prozesse) und Julia (Threads) mit denselben Ergebnissen wie R.

## simlev (Python) 0.7.0

Minor-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- MS-GARCH: Maximum-Likelihood-Schätzung nach Haas, Mittnik und Paolella (2004) für 2–3 Regime mit sGARCH/gjrGARCH; Startwerte aus HMM-EM und Rangeinteilung, Raster und BFGS.
- Bootstrap: Verfahren ms_garch nutzt die eigene Schätzung; das Paket MSGARCH wird nicht mehr gebraucht.
- Prüfung: im Vergleich mit MSGARCH 20 von 20 Fällen gleichwertig; R, Python und Julia bitgleich.

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

### Reine Python-Kerne in NaN-Randfällen (Etappe 8.0)

- **Bitgleich zu R auch ohne C-Erweiterung:** Die reinen Python-Kerne (`SIMLEV_NO_EXT=1` bzw. ohne Compiler) liefern jetzt auch bei NA/NaN-gemischten Eingaben, Division durch 0 und NaN-Vorzeichen dieselben Bits wie R: `min_cvar_core`/`min_cdar_core` (Division durch 0 wie C, `quantile7` mit Nachbildung von `std::nth_element`), `hmm_forward_backward`, `dcc_filter`, `garch_filter`, die Engine-Kerne in `_core.py`, `boot_wild`, `boot_garch`, `boot_ms_garch` und `rtruncnorm` (Operandenfolge des R-Baus über `simlev._r.rnum.n_add` usw., weil CPython je nach spezialisiertem Bytecode bei zwei NaN verschieden wählt); `_qnorm_std` hat den Zweig r > 27 aus R 4.3.3 (Zufallsvergleiche: vorher 2.868/3.000, 377/400, 4.478/4.500, 4.443/4.500, 6.954/7.000, 13.808/14.000 Fälle bitgleich, jetzt alle; neu `tests/test_reine_kerne_nan.py`).

### Restpunkte Fonds-Wrapper (Etappe 8.0)

- **Auswahl aus `wrapper_nav()`:** Jede Auswahl (`iloc`, `loc`, Spalten, `head()`, `tail()`, `query()`, `copy()`) ist ein gewöhnlicher `pandas.DataFrame` ohne `attrs` (bisher wurden `attrs["inner"]` und `attrs["wrapper"]` mitkopiert, tief bei jeder Spaltenauswahl); wie R `[.SimLevWrapperNav`. Umgesetzt über `_NavAttrs` (die `attrs` des ganzen Objekts geben bei der Weitergabe durch pandas ein leeres `dict`).
- **`withdrawal_simulation()`:** Ein `DataFrame` mit Spalte `date` als `x` ergibt den Fehler wie in R (bisher wurde er ohne Fehler als Renditematrix gelesen).
- **`strategy_from_weights()`/`portfolio_template()` mit `wrapper`:** ein `SimLevWrapperConfig` für alle Assets, ein `dict` Asset → `SimLevWrapperConfig` je Asset, Fehler wie in R (bisher wurde ein einzelnes `SimLevWrapperConfig` stillschweigend weggelassen).

### Fonds-Wrapper (Etappe 6.5c, Teil C und D)

Port des Fonds-Wrappers aus R (Begründung und Rechenregeln in [`r/NEWS.md`](../r/NEWS.md) und im Kopf von `simlev/wrapper.py`); bitgleich zu R in allen 72 Fällen des neuen Referenzmoduls `golden/modules/wrapper`, mit und ohne C-Erweiterung. Die Schnittstelle ist neu eingefroren (`tools/api_snapshot/CHANGES.md`).

- **Neu:** `wrapper_config(strategy, *, rebalance=None, costs=funds_costs(), order_fee=None, volume=None)` → `SimLevWrapperConfig`, `wrapper_nav(data, wrapper, *, splits=None)` → `SimLevWrapperNav` (`DataFrame` mit `date`, `nav`, `gross`, `fee`, `perf_fee`, `perf_paid`, `hwm`; `attrs["inner"]` und `attrs["wrapper"]`; Teilmengen sind gewöhnliche `DataFrame`) und `asset_config(..., wrapper=None)`. Beide Klassen drucken wie die R-Methoden (`print(x)`, `x.format()`).
- **Engine:** `simulation()` rechnet je Wrapper-Asset den Anteilswert aus den inneren Spalten (`_sim_phases._sim_check_inputs`) und hängt ihn als Kursspalte an; der Anteilswert splittet nicht (`cfg["no_split"]`), mit `details=True` kommt `result.wrappers` dazu. Die normalisierten Daten gehen als `_Frame` an die innere Rechnung (`simulation()` nimmt intern auch ein `_Frame`).
- **Paketzustand:** Der Zustand der Ordergebühren (`_sim_base._FEE`, R `.fee_env`) wird vor der inneren Rechnung gesichert und danach, auch nach einem Fehler, wiederhergestellt.
- **Meldungen:** Hinweise der inneren Rechnung erscheinen auf `sys.stderr` als „Hinweis: Wrapper '<Name>' (innere Rechnung): …“ (in `wrapper_nav()` „wrapper_nav (innere Rechnung)“), Warnungen und Fehler als „simulation: Wrapper '<Name>' (innere Rechnung): …“. Bei Handelstagsdaten steht der Auffüll-Hinweis daher wie in R zweimal.
- **Aufrufer:** `strategy_validate()` (Spaltenkollision, innere Spalten und Signale), `strategy_update_asset(..., wrapper=…)` (auch `None` zum Entfernen), `planning_lumpsum_vs_dca()` (Kurs des Wrappers = Anteilswert im Fenster) und `withdrawal_simulation(wrapper_nav(...))`; `bootstrap_study`, `param_search`, `sensitivity_*` und `overfit_*` gehen unverändert über `simulation()`. Kursspalten einer Strategie liefert `config._strategy_columns` (R `.strategy_columns`).
- **Tests:** `tests/test_wrapper.py` (Port von `test-wrapper.R`: Plausibilität, Handbeispiel, Startkosten, NA-Tage, Fehler, Hinweise, Gebührenzustand, Splits, Aufrufer, Druck).

### Standard-Spread 0 und alter Fondsmodus entfernt (Etappe 6.5c, Teil A und B)

Entscheidung des Nutzers vom 26.10.2026 (Begründung in [`r/NEWS.md`](../r/NEWS.md)); die Schnittstelle ist neu eingefroren (`tools/api_snapshot/CHANGES.md`).

- **Standard-Spread jetzt 0:** `asset_config(spread = 0)` statt `0.1`; wer Spreads abbilden will, gibt sie an. Ausdrücklich gesetzte Werte bleiben. Ohne Angabe rechnen damit `asset_config()`, Listen an `create_strategy()`, `strategy_from_weights()`, `portfolio_template()`, die `asset_args` von `tactical_simulation()` und die Standardstrategie von `sensitivity_leverage()` ohne Spread (bisher 0,1 %). Die Referenzfälle bleiben gleich: Ihre Generatoren schreiben `spread = 0.1` jetzt aus.
- **Alter Fondsmodus entfernt:** `simulation()` hat kein Argument `funds` mehr; `simulation(..., funds=funds_costs())` ergibt den üblichen Fehler für ein unbekanntes Argument (`TypeError: simulation() got an unexpected keyword argument 'funds'`), ohne Sonderbehandlung. Entfallen sind der Engine-Weg `tax_mode = "funds"` (Fondskosten am 31.12. und anteilig am letzten Tag mit Teilverkauf, Performancegebühr gegen den Höchststand des Depots, Steuer auf den Gesamtgewinn bei Liquidation) sowie der Baustein `funds` in `sim_args`, Rastern und Suchräumen (Pfade `"funds.*"`); die flachen Namen `funds_fee` und `bonus_fee` sind jetzt unbekannte Argumente. Die geteilten C/C++-Kerne enthielten keinen Fondscode. `result.trades` hat keinen Eintrag `fees` mehr (er enthielt nur die Fondskosten); entfernt sind auch die Hilfen dafür (`_calculate_fund_fees`, `_Actions.raise_cash`, `flag_fund_fee`, `totals["total_value"]`).
- **Umstellung:** Nachfolger ist der Fonds-Wrapper `wrapper_config()` (siehe oben, Etappe 6.5c Teil C/D) mit `funds_costs()` als Kostenbaustein: Der Wrapper wird als eigene Kursreihe (Anteilswert) gerechnet und außen wie ein Einzelpapier gehandelt und besteuert. Unterschiede zum alten Modus: Die Fondskosten werden täglich vom Anteilswert abgezogen (bisher am 31.12. aus der Summe der Tageswerte bzw. anteilig am letzten Tag), und die Performancegebühr bemisst sich am Höchststand je Anteil (bisher am Höchststand des Depots, der mit jeder Einzahlung stieg). `funds_costs()` bleibt mit Prüfung und Druckausgabe exportiert; `simulation()` nimmt es nicht an.
- **Referenzfälle:** Entfernt sind die 39 Referenzfälle des Fondsmodus: 13 in `golden/cases` (`f07_funds_liq`, `f08_funds_1231`, `f28_details_split_funds`, `r018`, `r035`, `r052`, `r086`, `r171`, `r222`, `r358`, `r443`, `r460`, `r477`), 2 in `golden/extra` (`x02_30y_funds_split_int`, `x16_funds_fee_high`) und 24 im Modul `engine` (`bk01`, `bk18`, `bk19`, `ch12`, `fee05`, `fu01`–`fu11`, `fu14`, `fu16`, `gp05`, `hv15`, `zz02`, `zz08`, `zz13`, `zz20`); Engine-Fälle jetzt 90 (55 + 35), Modul-Fälle 4.659. Alle übrigen Fälle rechnen unverändert (Nachweis und Liste in [`golden/README.md`](../golden/README.md)); acht Fehlerfälle in `bootstrap`, `param_search` und `sensitivity` nennen `funds` nicht mehr in der Liste der Bausteine.

### Geschwindigkeit (Etappe 7.1 bis 7.3b)

Schneller bei gleichen Ergebnissen (alle Referenz- und Golden-Fälle bitgleich, Schnittstelle unverändert):

- **Reines Python (7.1):** `libm.exp`/`log` auf Feldern ohne Python-Hülle je Element, `r_pow_vec` und `_pow_vec` mit schnellem Weg für endliche Basen, `sell_count` mit fortlaufenden long-double-Summen über `np.cumsum`, Probelauf der Vorabpauschale kopiert nur `totals` und `status`, Datumsspalten auf dem ganzen Feld, `dgemm` mit langem k als fortlaufende Summe, MS-GARCH-Filter und stationäre Verteilung für zwei Regime mit lokalen Variablen, Entnahme-Kern ohne Neudefinition je Periode. Rechenfolge und libm-Aufrufe sind dieselben.
- **Optionale C-Erweiterung (7.2):** `simlev._ext_msgarch` nutzt denselben MS-GARCH-Filterkern wie das R-Paket (`r/src/ms_garch_core.c`, Kopie in `python/src/`). `pip install` baut sie, wenn ein C-Compiler vorhanden ist; sonst rechnet wie bisher der reine Python-Kern. `SIMLEV_NO_EXT=1` erzwingt den Python-Kern. Eine MS-GARCH-Schätzung (2 Regime, n = 2.000) braucht damit etwa 0,4 s statt 4,5 s.
- **Gemeinsame Kerne (7.3a):** Die Erweiterung heißt jetzt `simlev._ext` und enthält alle nativen Kerne des R-Pakets ohne Zufallszahlen, aus denselben Quellen wie R (`r/src/*_impl.h`, `ms_garch_impl.c`; Kopien in `python/src/`): MS-GARCH-Filter, die Forschungskerne (`proj_box_simplex`, `qp_box_simplex`, `min_cvar_core`, `min_cdar_core`, `roll_mean_core`, `roll_cov_core`, `kendall_tau_core`, `quantile_reg_core`, `hmm_forward_backward`, `garch_filter`), den Entnahme-Kern, den DCC-Filter, die rugarch-Filter, `nlgpd` (evd), `locf` (imputeTS) und die Engine-Kerne (`_core.py`: Report, Kauf, Markt-Update, FIFO, Steuer). Der R-Bau ist dabei unverändert (gleicher Maschinencode). Ohne Compiler oder mit `SIMLEV_NO_EXT=1` rechnen die reinen Python-Kerne wie bisher. Ob die Erweiterung aktiv ist, zeigt `simlev._r.env.ext() is not None`. Der reine MS-GARCH-Filter liefert jetzt auch bei NA/NaN in den Daten dieselben NaN-Bits wie R. Messbasis (`tools/bench/ergebnis_2026-10-26_kerne.csv`, Median, mit gegen ohne Erweiterung): `portfolio_optimize` `min_cvar` 0,17 s statt 0,87 s, `dependence_analysis` mit DCC 0,50 s statt 1,01 s, `withdrawal_simulation` 0,12 s statt 0,30 s, `bootstrap` GARCH 0,51 s statt 0,62 s, Simulation 30 Jahre 0,083 s statt 0,094 s.
- **Kerne mit Zufallszahlen (7.3b):** Auch die Bootstrap-Kerne (`_bootstrap_core`: Index-Ziehungen IID, Block, stationär, Regime, Tails, dazu Wild, Reset, EVT, GARCH, MS-GARCH sowie `rolling_vol`, `assign_regimes`, `estimate_trans_mat`) und `rtruncnorm` (truncnorm, Startwerte von gosolnp) rechnen in `simlev._ext` mit denselben Quellen wie R (`r/src/bootstrap_core_impl.h`, `r/src/vendor_truncnorm_impl.h`). Die Zufallszahlen zieht dort eine C-Nachbildung von R's Generatoren (`src/_rng_r.c`, aus R 4.3.3: Mersenne-Twister und L'Ecuyer-CMRG, Normalverteilung per Inversion, `exp_rand`, `rgeom`/`rpois`, `dnorm`) auf dem Zustand von `simlev._r.rng`; danach ist der Zustand derselbe wie nach dem reinen Python-Kern, `set_seed`, `.Random.seed` und L'Ecuyer-Streams (`cores`) wirken unverändert. Andere Zufallsarten und Eingaben außerhalb des gültigen Bereichs rechnet still der reine Python-Kern. Der R-Bau ist unverändert (gleicher Maschinencode). Messbasis (`tools/bench/ergebnis_2026-10-26_rng.csv`, Median, mit gegen ohne Erweiterung): `bootstrap` stationär 200 Pfade 0,048 s statt 0,35 s, `bootstrap_study` 0,50 s statt 0,59 s, `bootstrap` 400 Pfade mit `cores = 1` 0,11 s statt 0,81 s, mit `cores = 2` 0,29 s statt 0,59 s.

### Eingefrorene Schnittstelle (Etappe 6.6)

Die Schnittstelle 0.5.0 ist in `tools/api_snapshot/frozen/py.json` festgehalten und wird von `tests/test_api_frozen.py` und `tools/api_snapshot/run.sh --check` geprüft; Änderungen nur über `run.sh --freeze` mit Eintrag in `tools/api_snapshot/CHANGES.md`.

### Umbenennungen (Etappe 6)

Mechanisch umbenannt mit `tools/rename.py` nach `tools/rename_map.tsv`; die Rechnung ist unverändert (Nachweis über die Referenzfälle). Die alten Namen gibt es nicht mehr.

| Art | gilt für | alt | neu |
|---|---|---|---|
| Funktion | – | `align_series` | `series_align` |
| Funktion | – | `align_macro` | `series_align_macro` |
| Funktion | – | `check_series` | `series_check` |
| Funktion | – | `splice_series` | `series_splice` |
| Funktion | – | `leveraged_series` | `series_leverage` |
| Funktion | – | `convert_currency` | `series_convert_currency` |
| Funktion | – | `deflate` | `series_deflate` |
| Funktion | – | `set_expected_return` | `series_shift_return` |
| Funktion | – | `total_return_index` | `index_total_return` |
| Funktion | – | `money_market_index` | `index_money_market` |
| Funktion | – | `currency_hedged_index` | `index_currency_hedged` |
| Funktion | – | `bond_index_from_yields` | `index_bond` |
| Funktion | – | `add_asset` | `strategy_add_asset` |
| Funktion | – | `remove_asset` | `strategy_remove_asset` |
| Funktion | – | `update_asset` | `strategy_update_asset` |
| Funktion | – | `validate_strategy` | `strategy_validate` |
| Funktion | – | `compute_rebal_trigger` | `rebalance_trigger` |
| Funktion | – | `block_length` | `bootstrap_block_length` |
| Funktion | – | `pooled_bootstrap` | `bootstrap_pooled` |
| Funktion | – | `validate_bootstrap` | `bootstrap_validate` |
| Funktion | – | `study_metrics` | `bootstrap_study_metrics` |
| Funktion | – | `validate_dependence` | `dependence_validate` |
| Funktion | – | `dcc_fit` | `dependence_dcc` |
| Funktion | – | `fit_copula` | `copula_fit` |
| Funktion | – | `covar_analysis` | `tail_covar` |
| Funktion | – | `quantile_reg` | `quantile_regression` |
| Funktion | – | `copula_scenarios` | `scenario_copula` |
| Funktion | – | `crisis_replay` | `scenario_crisis` |
| Funktion | – | `entropy_pooling` | `scenario_entropy_pooling` |
| Funktion | – | `efficient_frontier` | `portfolio_frontier` |
| Funktion | – | `risk_contributions` | `portfolio_risk_contributions` |
| Funktion | – | `rolling_optimization` | `portfolio_rolling` |
| Funktion | – | `cpcv_portfolio` | `portfolio_cpcv` |
| Funktion | – | `probabilistic_sharpe` | `sharpe_probabilistic` |
| Funktion | – | `deflated_sharpe` | `sharpe_deflated` |
| Funktion | – | `min_track_record` | `sharpe_min_track_record` |
| Funktion | – | `pbo` | `overfit_pbo` |
| Funktion | – | `reality_check` | `overfit_reality_check` |
| Funktion | – | `walk_forward` | `overfit_walk_forward` |
| Funktion | – | `plateau` | `param_plateau` |
| Funktion | – | `target_volatility` | `tactical_target_volatility` |
| Funktion | – | `conditional_volatility` | `tactical_conditional_volatility` |
| Funktion | – | `glidepath` | `tactical_glidepath` |
| Funktion | – | `blend_weights` | `tactical_blend` |
| Funktion | – | `leverage_sensitivity` | `sensitivity_leverage` |
| Funktion | – | `rebalancing_sensitivity` | `sensitivity_rebalancing` |
| Funktion | – | `horizon_model` | `withdrawal_horizon` |
| Funktion | – | `perfect_withdrawal_rate` | `withdrawal_perfect_rate` |
| Funktion | – | `goal_optimize` | `planning_goal` |
| Funktion | – | `lumpsum_vs_dca` | `planning_lumpsum_vs_dca` |
| Funktion | – | `return_heatmap` | `result_heatmap` |
| Funktion | – | `deep_analysis` | `result_analysis` |
| Funktion | – | `read_tax_tariff` | `tax_tariff` |
| Argument | `asset_config` | `action_type` | `trading` |
| Argument | `asset_config`, `withdrawal_simulation` | `asset_bonus` | `partial_exemption` |
| Argument | `asset_config` | `asset_share` | `share` |
| Argument | `asset_config` | `asset_spread` | `spread` |
| Argument | `asset_config` | `asset_start` | `start` |
| Argument | `bootstrap_data`, `bootstrap_study`, `withdrawal_paths` | `start_date` | `start` |
| Argument | `portfolio_rolling` | `x` | `data` |
| Argumente | `withdrawal_simulation` | `tax_mode`, `tax_rate`, `sparer_pauschbetrag` | `tax = tax_profile(rate, sparer_pauschbetrag)` |

Interne Helfer der Engine (nicht exportiert) folgen dem Namensschema: in R mit Punkt, in Python und Julia mit `_`: `apply_spread`, `calculate_buy_signal`, `calculate_fifo_price`, `calculate_fifo_vorabpauschale`, `calculate_flat_rate`, `calculate_fund_fees`, `calculate_paragraph_20_tax`, `calculate_private_sale_tax`, `calculate_sell_count`, `calculate_sell_signal`, `calculate_split_flags`, `calculate_vorabpauschale_tax`, `forward_asset_split`, `handle_year_change`, `perform_asset_split`, `perform_gain_harvest`, `perform_trade_buy`, `perform_trade_sell`, `reverse_asset_split`, `update_fifo_front`.

### Aufrufer von `simulation()`, Argumentordnung (Etappe 6.4, 6.5)

- **Fondsmodus mit eigenen Steuern** (Korrektur zu 6.3; seit 6.5c samt Fondsmodus entfernt, siehe oben): `simulation(funds = funds_costs(...), tax = tax_profile(...))` ist wieder erlaubt; der Fondsmodus steht für einen eigenen Wrapper (etwa ein Zertifikat) mit eigenen Kosten und eigener Steuer. Aus `tax_profile()` wirken dort wie früher mit `tax_mode = "funds"` der Satz `rate` bzw. die Kirchensteuer `church_tax` (Satz nach § 32d Abs. 1 EStG) für die Steuer auf den Gesamtgewinn bei Liquidation; `harvest` und `income_tariff()` wirken nicht (Warnung), die übrigen Angaben still nicht. Ohne `tax` gilt wie bisher 26,375 %. Referenzfall `ch12` rechnet wieder wie vor 6.3.
- **`sim_args` mit Bausteinen** in `bootstrap_study()`, `param_search()`, `param_bootstrap()`, `sensitivity_grid()`, `sensitivity_leverage()`, `sensitivity_rebalancing()`, `planning_lumpsum_vs_dca()` und den Zusatzargumenten von `tactical_simulation()`: Argumente von `simulation()`, z. B. `sim_args = list(start_value = 1000, tax = tax_profile(), dca = dca_plan(100, 1))`. Die Aufrufer gehen über `simulation()`. Alte flache Namen sind ein Fehler, der den Baustein nennt: `sensitivity_grid: dca_value gibt es nicht mehr; bitte dca = dca_plan(value = …) (Pfad "dca.value").`; unbekannte Namen ebenso (`unbekanntes Argument … für simulation()`).
- **Pfade zu Bausteinparametern** (F1) in Rastern (`sensitivity_grid(grid = )`), Suchräumen (`param_space()` ohne `builder`), den `args` einer Spezifikation und in `sim_args`: `"dca.value"`, `"rebalance.thresh"`, `"tax.rate"`, `"tax.church_tax"`, für Teilbausteine `"tax.income.marginal_rate"`, `"tax.harvest.day"`. Ein Pfad baut den Baustein für jeden Lauf neu, Grundwerte aus dem Baustein in `sim_args` (ohne ihn die Standardwerte des Konstruktors). Ergebnisspalten heißen wie der Pfad (bisher wie das flache Argument, z. B. `balance_unit` → `rebalance.unit`). Unbekannte Pfade nennen die möglichen Bausteine und Parameter. `sensitivity_rebalancing()` setzt Frequenz, Versatz und Band über diese Pfade, die übrigen Angaben eines `rebalance_plan()` aus `sim_args` bleiben erhalten.
- **`withdrawal_simulation(tax = tax_profile())`** (F2) statt `tax_mode`, `tax_rate`, `sparer_pauschbetrag`: ausgewertet werden `rate` und `sparer_pauschbetrag`; was die Entnahmephase nicht abbildet (`church_tax`, `private_sale_threshold`, `base_rate`, `guenstigerpruefung`, `income`, `harvest`), ist ein Fehler. `partial_exemption`, `vorabpauschale`, `cost_basis`, `loss_carryforward`, `sale_cost` und der Basiszins `base_rate` (auch als Matrix) bleiben eigene Argumente; das Ergebniselement `tax_mode` bleibt (`"person"`/`"none"`).
- **`seed`, `cores`, `progress` am Ende** (Reihenfolge `…, max_tries, chunk_size, seed, cores, progress`): `bootstrap()`, `bootstrap_study()`, `param_search()` (`keep_returns` vor `seed`, `cores`), `sensitivity_grid()` (`keep_results` vor `cores`), `sharpe_test()` (`ppy` vor `seed`).
- **`portfolio_rolling(data, …)`** statt `x` (F4: das erste Argument ist nur eine Tabelle mit Datumsspalte).
- **Python: Nicht-Pflichtargumente nur als Schlüsselwort** (`*` in der Signatur, Anhang A Regel 5) in allen öffentlichen Funktionen mit R-Gegenstück, z. B. `asset_config(asset_class='etf', trading='bnh', share=0.6)`, `withdrawal_simulation(R, rule=withdrawal_rule(type='vanguard'))`, `bootstrap(d, cfg, method='stationary', n=100)`. Pflichtargumente bleiben positionell, auch wenn sie in R nach optionalen stehen (`bootstrap_study(data, config, method, n, strategies, *, …)`, `param_search(data, builder, space, *, …)`, `tactical_glidepath(data, from_, to, *, …)`). Nicht betroffen: die Nachbildungen von R-Basisfunktionen `set_seed`, `rng_kind`, `isna_strict`.

### Bausteine für `simulation()` (Etappe 6.3)

`simulation()` nimmt die Einstellungen jetzt als Bausteine (Anhang C):

`simulation(data, strategy, start_value=10000, costs=sim_costs(), dca=None, rebalance=None, splits=None, tax=None, risk_free=0, fractions=True, liquidate=False, details=False)`

`None` heißt aus. Die flachen Argumente bis 6.2 gibt es nicht mehr (keine Aliasse); die Engine rechnet unverändert, alle Referenzfälle sind nach der Übersetzung bitgleich (Nachweis mit `golden/tools/blocks_from_flat.py`). Jeder Baustein prüft seine Argumente selbst und hat eine Druckausgabe.

| bisher (flach) | jetzt |
|---|---|
| `order_fee`, `dca_fee` | `costs = sim_costs(order_fee, dca_fee)` |
| `dca_mode = True`, `dca_value`, `dca_span`, `dca_days`, `dca_unit`, `dca_anchor`, `dca_start`, `dca_skip`, `balance_dca` | `dca = dca_plan(value, span, days, unit, anchor, start, skip, fill_deficits)` |
| `balance_mode = True`, `balance_span`, `balance_days`, `balance_unit`, `balance_anchor`, `balance_start`, `balance_skip`, `balance_thresh`, `balance_thresh_type`, `event_col`, `event_mode`, `event_weight` | `rebalance = rebalance_plan(span, days, unit, anchor, start, skip, thresh, thresh_type, event_col, event_mode, event_weight)` |
| nur Ereignisse (`balance_mode = False` mit `event_col`, `event_mode = "replace"`) | `rebalance_plan(event_col = , event_mode = "replace", skip = True)` |
| `split_mode = True`, `split_thresh` | `splits = split_rule(thresh)` |
| `tax_mode = "person"`, `tax_rate`, `church_tax`, `sparer_pauschbetrag`, `use_sparer_pauschbetrag = False`, `private_sale_threshold`, `base_rate`, `base_rate_flex` mit `base_rate_data`, `use_guenstigerpruefung` | `tax = tax_profile(rate, church_tax, sparer_pauschbetrag, private_sale_threshold, base_rate, guenstigerpruefung, income, harvest)`; `sparer_pauschbetrag = 0` heißt ohne Pauschbetrag, `base_rate` ist eine Zahl oder ein Spaltenname |
| `marginal_tax_rate`, `include_soli_on_income_tax`, `soli_rate_income_tax` | `income = income_rate(marginal_rate, soli_rate)` (`soli_rate = 0` heißt ohne Soli) |
| `taxable_income`, `tax_tariff` | `income = income_tariff(taxable_income, tariff)` |
| `harvest_mode = True`, `harvest_day`, `harvest_loss_pot` | `harvest = harvest_rule(day, loss_pot)` |
| `tax_mode = "funds"`, `funds_fee`, `bonus_fee` | `funds = funds_costs(fee, performance_fee)`, seit 6.5c entfernt (siehe oben) |
| `spread` (ohne Wirkung, nur Warnung) | entfällt; der Spread gilt je Asset (`asset_config(spread = )`) |

Neue Regeln: `tax_profile()` mit `rate` und `church_tax` > 0 ist ein Fehler (mit Kirchensteuer gilt der Satz nach § 32d Abs. 1 EStG); `income` nimmt entweder `income_rate()` oder `income_tariff()`. Freibetrag-Ausschöpfung ohne persönliche Besteuerung lässt sich nicht mehr angeben (bisher wirkungslos); die Warnungen zu wirkungslosen flachen Argumenten entfallen. Fehlermeldungen der Prüfungen nennen den Baustein (z. B. `dca_plan: 'value' muss …`, `tax_profile: church_tax …`). Mit `sparer_pauschbetrag = 0` steht in `tax_report$sparer_pauschbetrag_annual` 0 (bisher der angegebene Betrag neben `use_sparer_pauschbetrag = False`).

Weitere Änderungen: `plot(<SimLevWeights>, main = "Zielgewichte")` hat den Titel als Argument (R wie die Ports); das Modul `simlev.tax_tariff` heißt `simlev._tax_tariff` (die Funktion `simlev.tax_tariff()` bleibt öffentlich).


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
* MS-GARCH ohne MSGARCH, eigene Schätzung wie R: Die Verfahren
  `"ms_garch"`, `"ms_ar_garch_m"` und `"tvtp_ms_garch"` von `bootstrap()`
  und `bootstrap_study()` laufen jetzt auch in Python, bitgleich zu R.
  `simlev.ms_garch` (Port von `r/R/ms_garch.R`) schätzt das Modell nach
  Haas, Mittnik und Paolella (2004) per Maximum Likelihood (`optim` mit
  BFGS aus deterministischen Startwerten: Baum-Welch-EM und
  Rangeinteilung der Volatilität, je mit kleinem Raster); den
  Hamilton-Filter rechnet `_bootstrap_core.ms_garch_filter` (Port von
  `r/src/ms_garch.c`). Das EM von `regime_hmm()` ist wie in R in
  `regimes._hmm_em`, `_hmm_init_rank` und `_hmm_init_cl` herausgelöst
  (Ergebnis unverändert). Die Meldung „Paket fehlt“ entfällt.

Die C++-Kerne des R-Pakets stehen in `_bootstrap_core.py` (dort auch der
C-Kern `ms_garch.c`), `_withdrawal_core.py`, `_dependence_core.py`,
`_optimize_core.py` und `_signals_core.py`. Die `plot()`-Methoden der Ergebnisobjekte zeichnen wie
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

* `tools/compare_golden.py` prüft ohne Pfadangabe `golden/cases` (55 Fälle)
  und `golden/extra` (35 Fälle, seit Etappe 6.5c) und nimmt mehrere Ordner oder Dateien sowie
  die Optionen `-k`, `-v` und `-q`. Alle 90 Fälle sind bitgleich
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
  Feld `suggests` mehr.
* Neu: `NA` und `NaN` werden wie in R unterschieden. `simlev.NA` ist R's
  `NA_real_` (NaN mit Nutzlast 1954), ein gewöhnliches `nan` ist R's `NaN`;
  `simlev.isna_strict(x)` erkennt nur `NA`. Druckausgabe, `format()`,
  `sprintf()`, Summen und Kumulationen folgen R's Regeln für beide.
* Die Test-Suite umfasst 5.755 Tests; die Tests der R-Engine aus
  `r/tests/testthat` sind übertragen.
* Tests, die nur wiederholen, was ein Referenzfall bitgleich prüft, sind
  entfallen: Die Fälle `r_fmt`, `r_linalg` und `r_stats` liefen in
  `test_r_fmt.py`, `test_r_linalg.py` und `test_r_stats.py` ein zweites Mal
  (sie laufen weiter in `test_module_reference.py`), drei Tests in
  `test_engine_notes.py` rechneten dasselbe wie die Fälle
  `engine/um01`–`um04`.
* Neu: `tests/test_layers.py` prüft die Schichten der Module (0 R-Interna,
  1 Daten und Strategie, 2 Engine, 3 Analysen, 4 Ausgabe; kein Import in
  eine höhere Schicht, bekannte Ausnahmen begründet), dass die Schalter
  `SIMLEV_*` nur in `simlev._r.env` gelesen werden, und das verzögerte
  Laden der Analysemodule.
* Alle Umgebungsschalter `SIMLEV_*` liest jetzt `simlev._r.env` (Tabelle in
  `DEVELOPING.md`); Wirkung, Standardwerte und Meldungen sind unverändert.

### Laden

* `import simlev` lädt die Analysemodule (Bootstrap, Entnahme,
  Abhängigkeiten, Regime, Szenarien, Optimierung, Taktik, Tiefenanalyse,
  Planung, Analyse-Tests, Überanpassung, Parametersuche, Sensitivität) erst
  beim ersten Zugriff auf einen ihrer Namen (PEP 562). `from simlev import
  X`, `simlev.X`, `dir(simlev)` und `__all__` wirken wie zuvor.

### Bekannte Grenzen

* Bitgleichheit gilt unter Linux x86-64 (80-Bit-`long double`) mit
  glibc-libm und, für Eigenvektoren, mit der Referenz-LAPACK des Systems.
* Die Referenzen entstanden mit R 4.3.3. evd, rugarch und imputeTS sind
  nachgebildet und gelten immer, wie das R-Paket mit seinen übernommenen
  Fassungen. gosolnp setzt wie in R den Zufallszustand aus der
  Uhrzeit; reproduzierbar mit `SIMLEV_R_SYS_TIME`. MSGARCH wird nicht
  gebraucht; die MS-GARCH-Verfahren schätzen wie R selbst.
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
* `cores > 1` rechnet wie R parallel mit Fork-Prozessen
  (`simlev._r.parallel.par_lapply`, Nachbildung von `.par_lapply`; nur
  Standardbibliothek) und derselben Zufallssemantik wie
  `mclapply(mc.set.seed = FALSE)`: jede Einheit startet mit dem
  Zufallszustand des Aufrufers, der danach unverändert ist; Ergebnisse in
  Eingangsreihenfolge, bitgleich zu R bei gleichem `cores`. Ausgaben und
  Meldungen der Einheiten erscheinen in deren Reihenfolge (R: in der
  Reihenfolge der Fertigstellung), Warnungen gehen wie in R verloren. Ein
  Fehler in einer Einheit bricht wie bei `cores = 1` ab (R liefert dort ein
  `try-error`-Element mit Warnung). Ohne Fork (Windows, macOS) rechnet
  Python nacheinander mit denselben Ergebnissen. `cores` zwischen 1 und 2
  rechnet wie in R als `lapply`.
* Nichtzentrale Verteilungen (`ncp`) und einige selten genutzte
  stats-Optionen sind nicht portiert, weil das Paket sie nicht nutzt.
