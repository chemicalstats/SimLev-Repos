# SimLev (R) – Änderungen je Version

Die Python- und die Julia-Fassung sind seit ihrer Version 0.5.0
vollständige Ports dieser R-Fassung 0.5.0 (alle Exporte, alle
Erweiterungen) und bitgleich zu ihr; ihre Änderungen stehen in
[`python/NEWS.md`](../python/NEWS.md) und
[`julia/NEWS.md`](../julia/NEWS.md). Ihre Vorversionen 0.1.0 enthielten nur
die Engine und entsprachen dem früheren Stand des R-Pakets vor den
Korrekturen (Commit 54b5b4f, damals ebenfalls als 0.5.0 bezeichnet; im
Folgenden „Stand 54b5b4f“). Bis zu diesem Stand blieben die 105
Golden-Master-Fälle der Engine bitgleich; die aktuelle Fassung 0.5.0
korrigiert Rechenfehler der Engine, setzt die Besteuerung nach geltendem
Recht um, gibt alle Ausgaben auf Deutsch aus und erzeugt alle 105 Fälle
neu (siehe unten). Python 0.5.0 und Julia 0.5.0 sind zu allen Fällen
bitgleich (seit Etappe 6.5c 90; die 15 Fälle des entfernten Fondsmodus entfielen).

## SimLev 0.10.0

Minor-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Wrapper: wrapper_config() und asset_config(wrapper = ) bilden einen Zertifikat- bzw. Fonds-Wrapper als eigene Kursreihe ab (wrapper_nav()); innere Assets mit eigenem Umschichten und Orderkosten, tägliche Verwaltungs- und Performancegebühr mit High-Water-Mark; außen gelten Spread, Gebühren und Steuern wie bei jedem Asset.
- Geändert: asset_config() hat den Standard-Spread 0; der alte Fondsmodus simulation(funds = ) entfällt.
- Strategien: strategy_from_weights() und portfolio_template() nehmen Wrapper je Asset.
- Qualität: NaN-Randfälle der reinen Python- und Julia-Kerne an R angeglichen; Messskript überschreibt keine Ergebnisse.

## SimLev 0.9.1

Patch-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Python: C-Erweiterung mit denselben Kernen wie R (Engine, FIFO, Steuer, Research, Entnahme, Abhängigkeit, Bootstrap, MS-GARCH-Filter), Zufallszahlen bitgleich zu R; reines Python bleibt als Rückfall.
- R: Parallelität gebündelt (wenige Forks statt einer je Einheit), z. B. bootstrap mit 2 Kernen 2,2 s -> 0,2 s.
- Ergebnisse in allen drei Sprachen unverändert.

## SimLev 0.9.0

Minor-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Namen: einheitliche Benennung der Funktionen und Argumente in allen drei Sprachen (Tabelle alt -> neu im Abschnitt 0.5.0).
- Simulation: simulation() mit Bausteinen sim_costs, dca_plan, rebalance_plan, split_rule, tax_profile und funds_costs; Pfadnotation wie "dca.value" für Raster und Suchräume.
- Aufrufer: Bootstrap-Studien, Parametersuche, Sensitivitäten und Planung gehen über simulation(); Optionen nur noch als Schlüsselwort.
- Schnittstelle: Stand der drei Sprachen eingefroren und automatisch abgeglichen.

## SimLev 0.8.0

Minor-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Prüfwerkzeuge: Abgleich der Schnittstelle der drei Sprachen (tools/api_snapshot), Referenzfälle in kompaktem Format mit gemeinsamen Eingaben, Laufzeitmessung (tools/bench).
- Verschlankung: entfernt sind interaktive Grafiken, create_config, migrate_strategy, as_list sowie scipy und TTR; Engine in Teilmodule aufgeteilt, Schichtentest, Schalter SIMLEV_* an einer Stelle.
- Parallelität: cores in Python (Fork-Prozesse) und Julia (Threads) mit denselben Ergebnissen wie R.

## SimLev 0.7.0

Minor-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- MS-GARCH: Maximum-Likelihood-Schätzung nach Haas, Mittnik und Paolella (2004) für 2–3 Regime mit sGARCH/gjrGARCH; Startwerte aus HMM-EM und Rangeinteilung, Raster und BFGS.
- Bootstrap: Verfahren ms_garch nutzt die eigene Schätzung; das Paket MSGARCH wird nicht mehr gebraucht.
- Prüfung: im Vergleich mit MSGARCH 20 von 20 Fällen gleichwertig; R, Python und Julia bitgleich.

## SimLev 0.6.0

Minor-Update (Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Grafik: Python zeichnet wie Julia eigenes SVG statt matplotlib; Dashboard, Analyse-, Abhängigkeits- und Überanpassungsgrafiken in einem Grafikmodul je Sprache.
- Datenobjekt: Grafiken liefern SimLevPlot mit svg, data, source und kind, damit eigene Darstellungen aus den Daten möglich sind.
- Optionen der Grafikfunktionen nur noch als Schlüsselwort.

## SimLev 0.5.1

Patch-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Abhängigkeiten: evd (GPD-Anpassung), imputeTS/stinepack (Interpolation), rugarch mit Rsolnp und truncnorm (GARCH-Schätzung) als interne Teile eingebaut; R braucht zur Laufzeit nur Basis-R.
- Ableitungen: eigene Richardson-Extrapolation für Hesse- und Jacobi-Matrix statt numDeriv.
- C/C++-Kerne: Anbindung über R's C-Schnittstelle statt Rcpp, Fehlertexte unverändert.
- Ports: Python und Julia bilden die eingebauten Teile bitgleich nach; kleinere Korrekturen in Simulation und linearer Algebra.

## SimLev 0.5.0

Diese Fassung fasst den zunächst als 0.5.0 veröffentlichten Stand (Commit
54b5b4f, Grundlage der Python- und Julia-Fassung 0.1.0) und alle danach
vorgenommenen Korrekturen und Erweiterungen zusammen; eine eigene
Zwischenversion dafür gibt es nicht. Neue Funktionen sind unten aufgeführt, darunter
`read_tax_tariff()` (Einkommensteuertarif aus einer austauschbaren Datei).
Neue Argumente: `order_fee`, `dca_fee`, `church_tax`, `harvest_mode`,
`harvest_day`, `harvest_loss_pot`, `taxable_income` und `tax_tariff` von
`simulation()`, `aux_type` von `bootstrap_config()` und `inflation_type` von
`withdrawal_cohorts()`. Entfernt wurde das Argument `horizon` von
`withdrawal_rule()` (es hatte keine Wirkung, siehe unten), ebenso die
interaktiven Grafiken und einige Aliasse (siehe „Bereinigung der
Schnittstelle“ unten). Neu sind einige
Ergebniselemente (z. B. `fees_paid`, `harvest_days`, `twr_index`,
`invested`, `external_flows`, `undefined_metrics`, `open_lots`,
`tax_report$open_tax_debt`, `tax_report$tariff_years` und
`tax_report$next_year` in `simulation()`, `adopted` in
`withdrawal_simulation()`, `failed_dates`, `B_failed`, `probability_dp`,
`full_years`, `initial`) sowie klare Fehlermeldungen und Warnungen bei
ungültigen Eingaben. Alle Meldungen und Ausgaben sind deutsch.

### Restpunkte Fonds-Wrapper (Etappe 8.0)

- **Auswahl aus `wrapper_nav()`:** Neue Methode `[.SimLevWrapperNav`: Jede Auswahl von Zeilen oder Spalten (`x[i, ]`, `x[j]`, `x[]`, über `[` auch `head()`, `tail()`, `subset()`) liefert einen gewöhnlichen `data.frame` ohne Klasse `SimLevWrapperNav` und ohne die Attribute `inner` und `wrapper` (bisher behielt eine Zeilenauswahl Klasse und Attribute, eine Spaltenauswahl die Klasse), weil das innere Ergebnis nicht mehr zum Ausschnitt passt. Python und Julia ebenso. Das ganze Objekt bleibt unverändert nutzbar, auch in `withdrawal_simulation(x = …)`.
- **`withdrawal_simulation()`:** Eine Tabelle mit Spalte `date` (z. B. ein Ausschnitt aus `wrapper_nav()`) als `x` ergibt jetzt einen klaren Fehler mit Hinweis auf `withdrawal_cohorts(x, price = …)` (bisher „x muss eine numerische Matrix …“, in Python ohne Fehler mit unsinnigen Zahlen).
- **`strategy_from_weights()`/`portfolio_template()` mit `wrapper`:** Ein `SimLevWrapperConfig` gilt für alle Assets, eine benannte Liste solcher Objekte je Asset (Assets ohne Eintrag ohne Wrapper; in `portfolio_template()` gelten die Namen nach `map`). Unbekannte Namen, andere Elemente, eine Liste ohne Namen und `wrapper` mit `trading = "signal"` (Meldung nennt das Asset) sind ein Fehler. Bisher wurde ein `SimLevWrapperConfig` als benannte Liste je Asset zerlegt (R: Fehler von `asset_config()`, Python und Julia: Wrapper stillschweigend weggelassen).
- Neue Referenzfälle: `wrapper` 9 (jetzt 81), `data_prep` 15 (jetzt 175); alle bisherigen Fälle byte-gleich.

### Fonds-Wrapper (Etappe 6.5c, Teil C)

Neu: `wrapper_config()`, `wrapper_nav()` und das Argument `asset_config(wrapper = )` (Entscheidungen E1–E9 vom 26.10.2026). Ein Fonds-Wrapper (Zertifikat oder Fonds über eine innere Strategie) ist **ein** Asset der Strategie; `simulation()` rechnet vor der Engine seinen Anteilswert aus den inneren Spalten von `data` und handelt und besteuert ihn wie ein Einzelpapier. Alle bisherigen Referenzfälle rechnen unverändert; neu ist das Modul `golden/modules/wrapper` (72 Fälle; Python und Julia bitgleich seit Teil D).

- **`wrapper_config(strategy, rebalance, costs = funds_costs(), order_fee, volume)`:** innere Strategie (Signale erlaubt, keine verschachtelten Wrapper), inneres Umschichten, Kosten, Ordergebühr der inneren Käufe und Verkäufe (Format wie `sim_costs()`) und Fondsvolumen in EUR (Pflicht bei festen Beträgen `fixed`, `min`, `max`; die innere Rechnung startet dann mit diesem Volumen, sonst mit 100). Innere Spreads gelten wie angegeben; Werte > 0 ergeben einen Hinweis.
- **Anteilswert (`wrapper_nav()`):** innere Bruttorechnung ohne Steuern mit `fractions = TRUE`; Verwaltungsgebühr täglich je Kalendertag (`fee / 100 · Δd / 365` bzw. `/ 366` im Schaltjahr); Performancegebühr täglich gegen die High-Water-Mark abgegrenzt und am letzten Datentag jedes Kalenderjahres festgeschrieben (ESMA-Leitlinien zu Performancegebühren für OGAW; bei Zertifikaten gelten die Emissionsbedingungen). Ergebnis `SimLevWrapperNav` mit `date`, `nav`, `gross`, `fee`, `perf_fee` (abgegrenzt), `perf_paid` (festgeschrieben) und `hwm`, inneres Ergebnis als Attribut `inner`; Druck mit Zeitraum, Kosten und Endwert. Auch als Renditequelle `withdrawal_simulation(x = wrapper_nav(...))`.
- **`asset_config(wrapper = )`:** Der Asset-Name ist dann keine Kursspalte (gleichnamige Spalte in `data`: Fehler), nur `trading = "bnh"` (keine Signale auf den Anteilswert). Steuer nach `asset_class`/`tax_regime` (Zertifikat = Kapitalforderung; `tax_regime = "investment_fund"` mit Teilfreistellung und Vorabpauschale), Spread, Order- und Sparplangebühren, Kirchensteuer, `harvest` und `open_lots` wie bei jedem Asset. `print()` zeigt eine Zeile zum Wrapper; `strategy_update_asset()` (auch `wrapper =` hinzufügen bzw. mit `NULL` entfernen), `strategy_add_asset()` und `strategy_validate()` (prüft die inneren Spalten) gehen damit.
- **`simulation()`:** `splits` gelten für die inneren Spalten, der Anteilswert splittet nicht. Beginnt der Anteilswert später, gilt der bestehende Weg für später startende Assets. Mit `details = TRUE` kommt `result$wrappers` (je Wrapper-Asset der `SimLevWrapperNav`) dazu; ohne `details` bleibt das Ergebnis unverändert. Meldungen, Warnungen und Fehler der inneren Rechnung tragen das Präfix „Wrapper '<Name>' (innere Rechnung)“.
- **Aufrufer:** `bootstrap_study()`, `param_search()` (der `builder` kann den Wrapper bauen), `param_bootstrap()`, `sensitivity_*()` und `overfit_*()` gehen über `simulation()` und rechnen den Anteilswert je Pfad bzw. Lauf neu; Bootstrap zieht die inneren Spalten. `planning_lumpsum_vs_dca()` nimmt als Kurs des Wrappers den Anteilswert im Fenster. `tactical_simulation()`, `strategy_from_weights()` und `portfolio_template()` bauen ihre Strategien selbst aus Spalten bzw. Gewichten (ohne Wrapper).
- **`print(funds_costs())`** zeigt die Überschrift „Fondskosten (funds_costs)“ statt „Fondsmodus“ (Referenzfälle `engine/pr18`, `pr19`; Python und Julia gleich angepasst).

### Standard-Spread 0 und alter Fondsmodus entfernt (Etappe 6.5c, Teil A und B)

Entscheidung des Nutzers vom 26.10.2026; die Schnittstelle ist neu eingefroren (`tools/api_snapshot/CHANGES.md`).

- **Standard-Spread jetzt 0:** `asset_config(spread = 0)` statt `0.1`; wer Spreads abbilden will, gibt sie an. Ausdrücklich gesetzte Werte bleiben. Ohne Angabe rechnen damit `asset_config()`, Listen an `create_strategy()`, `strategy_from_weights()`, `portfolio_template()`, die `asset_args` von `tactical_simulation()` und die Standardstrategie von `sensitivity_leverage()` ohne Spread (bisher 0,1 %). Die Referenzfälle bleiben gleich: Ihre Generatoren schreiben `spread = 0.1` jetzt aus.
- **Alter Fondsmodus entfernt:** `simulation()` hat kein Argument `funds` mehr; `simulation(..., funds = funds_costs())` ergibt den üblichen Fehler für ein unbekanntes Argument (`unused argument (funds = funds_costs())`), ohne Sonderbehandlung. Entfallen sind der Engine-Weg `tax_mode = "funds"` (Fondskosten am 31.12. und anteilig am letzten Tag mit Teilverkauf, Performancegebühr gegen den Höchststand des Depots, Steuer auf den Gesamtgewinn bei Liquidation) sowie der Baustein `funds` in `sim_args`, Rastern und Suchräumen (Pfade `"funds.*"`); die flachen Namen `funds_fee` und `bonus_fee` sind jetzt unbekannte Argumente. Die geteilten C/C++-Kerne enthielten keinen Fondscode.
- **Umstellung:** Nachfolger ist der Fonds-Wrapper `wrapper_config()` (siehe oben, Etappe 6.5c Teil C) mit `funds_costs()` als Kostenbaustein: Der Wrapper wird als eigene Kursreihe (Anteilswert) gerechnet und außen wie ein Einzelpapier gehandelt und besteuert. Unterschiede zum alten Modus: Die Fondskosten werden täglich vom Anteilswert abgezogen (bisher am 31.12. aus der Summe der Tageswerte bzw. anteilig am letzten Tag), und die Performancegebühr bemisst sich am Höchststand je Anteil (bisher am Höchststand des Depots, der mit jeder Einzahlung stieg). `funds_costs()` bleibt mit Prüfung und Druckausgabe exportiert; `simulation()` nimmt es nicht an.
- **Referenzfälle:** Entfernt sind die 39 Referenzfälle des Fondsmodus: 13 in `golden/cases` (`f07_funds_liq`, `f08_funds_1231`, `f28_details_split_funds`, `r018`, `r035`, `r052`, `r086`, `r171`, `r222`, `r358`, `r443`, `r460`, `r477`), 2 in `golden/extra` (`x02_30y_funds_split_int`, `x16_funds_fee_high`) und 24 im Modul `engine` (`bk01`, `bk18`, `bk19`, `ch12`, `fee05`, `fu01`–`fu11`, `fu14`, `fu16`, `gp05`, `hv15`, `zz02`, `zz08`, `zz13`, `zz20`); Engine-Fälle jetzt 90 (55 + 35), Modul-Fälle 4.659. Alle übrigen Fälle rechnen unverändert (Nachweis und Liste in [`golden/README.md`](../golden/README.md)); acht Fehlerfälle in `bootstrap`, `param_search` und `sensitivity` nennen `funds` nicht mehr in der Liste der Bausteine.

### Eingefrorene Schnittstelle (Etappe 6.6)

Die Schnittstelle 0.5.0 ist in `tools/api_snapshot/frozen/r.json` festgehalten und wird von `tests/testthat/test-api-frozen.R` und `tools/api_snapshot/run.sh --check` geprüft; Änderungen nur über `run.sh --freeze` mit Eintrag in `tools/api_snapshot/CHANGES.md`.

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

### Bausteine für `simulation()` (Etappe 6.3)

`simulation()` nimmt die Einstellungen jetzt als Bausteine (Anhang C):

`simulation(data, strategy, start_value = 10000, costs = sim_costs(), dca = NULL, rebalance = NULL, splits = NULL, tax = NULL, risk_free = 0, fractions = TRUE, liquidate = FALSE, details = FALSE)`

`NULL` heißt aus. Die flachen Argumente bis 6.2 gibt es nicht mehr (keine Aliasse); die Engine rechnet unverändert, alle Referenzfälle sind nach der Übersetzung bitgleich (Nachweis mit `golden/tools/blocks_from_flat.py`). Jeder Baustein prüft seine Argumente selbst und hat eine Druckausgabe.

| bisher (flach) | jetzt |
|---|---|
| `order_fee`, `dca_fee` | `costs = sim_costs(order_fee, dca_fee)` |
| `dca_mode = TRUE`, `dca_value`, `dca_span`, `dca_days`, `dca_unit`, `dca_anchor`, `dca_start`, `dca_skip`, `balance_dca` | `dca = dca_plan(value, span, days, unit, anchor, start, skip, fill_deficits)` |
| `balance_mode = TRUE`, `balance_span`, `balance_days`, `balance_unit`, `balance_anchor`, `balance_start`, `balance_skip`, `balance_thresh`, `balance_thresh_type`, `event_col`, `event_mode`, `event_weight` | `rebalance = rebalance_plan(span, days, unit, anchor, start, skip, thresh, thresh_type, event_col, event_mode, event_weight)` |
| nur Ereignisse (`balance_mode = FALSE` mit `event_col`, `event_mode = "replace"`) | `rebalance_plan(event_col = , event_mode = "replace", skip = TRUE)` |
| `split_mode = TRUE`, `split_thresh` | `splits = split_rule(thresh)` |
| `tax_mode = "person"`, `tax_rate`, `church_tax`, `sparer_pauschbetrag`, `use_sparer_pauschbetrag = FALSE`, `private_sale_threshold`, `base_rate`, `base_rate_flex` mit `base_rate_data`, `use_guenstigerpruefung` | `tax = tax_profile(rate, church_tax, sparer_pauschbetrag, private_sale_threshold, base_rate, guenstigerpruefung, income, harvest)`; `sparer_pauschbetrag = 0` heißt ohne Pauschbetrag, `base_rate` ist eine Zahl oder ein Spaltenname |
| `marginal_tax_rate`, `include_soli_on_income_tax`, `soli_rate_income_tax` | `income = income_rate(marginal_rate, soli_rate)` (`soli_rate = 0` heißt ohne Soli) |
| `taxable_income`, `tax_tariff` | `income = income_tariff(taxable_income, tariff)` |
| `harvest_mode = TRUE`, `harvest_day`, `harvest_loss_pot` | `harvest = harvest_rule(day, loss_pot)` |
| `tax_mode = "funds"`, `funds_fee`, `bonus_fee` | `funds = funds_costs(fee, performance_fee)`, seit 6.5c entfernt (siehe oben) |
| `spread` (ohne Wirkung, nur Warnung) | entfällt; der Spread gilt je Asset (`asset_config(spread = )`) |

Neue Regeln: `tax_profile()` mit `rate` und `church_tax` > 0 ist ein Fehler (mit Kirchensteuer gilt der Satz nach § 32d Abs. 1 EStG); `income` nimmt entweder `income_rate()` oder `income_tariff()`. Freibetrag-Ausschöpfung ohne persönliche Besteuerung lässt sich nicht mehr angeben (bisher wirkungslos); die Warnungen zu wirkungslosen flachen Argumenten entfallen. Fehlermeldungen der Prüfungen nennen den Baustein (z. B. `dca_plan: 'value' muss …`, `tax_profile: church_tax …`). Mit `sparer_pauschbetrag = 0` steht in `tax_report$sparer_pauschbetrag_annual` 0 (bisher der angegebene Betrag neben `use_sparer_pauschbetrag = FALSE`).

Weitere Änderungen: `plot(<SimLevWeights>, main = "Zielgewichte")` hat den Titel als Argument (R wie die Ports).


### Neue Funktionen

* Szenarien: `entropy_pooling()` mit `view_mean()`, `view_prob()`,
  `view_vol()`; `copula_scenarios()` (t- oder Gauß-Copula, bedingter
  Stress); `scenario_risk()`; `crisis_replay()`.
* Optimierung: Verfahren `"min_cdar"` in `portfolio_optimize()`;
  Kovarianzschätzer `"ewma"`, `"denoise"`, `"gerber"`; `cpcv_portfolio()`
  (kombinatorische Kreuzvalidierung mit Purge und Embargo).
* Überanpassung: `sharpe_haircut()` (Harvey & Liu 2015).
* Planung: `set_expected_return()`, `pooled_bootstrap()` (Länder-Bootstrap),
  `horizon_model()` (Laufzeit nur nach Nutzervorgaben),
  `withdrawal_simulation(horizon = )`, `portfolio_returns()`,
  `goal_optimize()` (dynamische Programmierung).
* Prüfungen: `signal_analysis()`, `sharpe_test()`, `reality_check()`
  (White, Hansen SPA), `min_track_record()`, `regime_hmm()`,
  `regime_states()`, `return_heatmap()`; `deep_analysis(inflation = )`.
* Taktik: `conditional_volatility()` (bedingte Volatilitätssteuerung nach
  Bongaerts, Kang & van Dijk 2020).
* Steuern: `read_tax_tariff()` liest den Einkommensteuertarif (§ 32a EStG)
  und den Solidaritätszuschlag aus einer austauschbaren Datei (siehe
  „Einkommensteuertarif …“ unten).

### Engine: neue Optionen (`simulation()`, alle standardmäßig aus)

* `order_fee`, `dca_fee`: Ordergebühren fest, prozentual, mit Mindest- und
  Höchstbetrag; eigene Gebühr für Sparplankäufe. Gebühren erhöhen die
  Anschaffungskosten bzw. mindern den Veräußerungserlös.
* `church_tax`: Kirchensteuer; Abgeltungsteuersatz nach § 32d Abs. 1 EStG.
* `harvest_mode`, `harvest_day`, `harvest_loss_pot`: Gewinne einmal im Jahr
  bis zum freien Sparer-Pauschbetrag (und Verlusttopf) realisieren und
  sofort wieder anlegen.
* Ergebnis enthält `fees_paid` und `harvest_days`.
* `taxable_income`, `tax_tariff`: § 23-Steuer und Günstigerprüfung nach dem
  Einkommensteuertarif (siehe unten).

### Geschwindigkeit

Rechenintensive Teile laufen jetzt in C++ (`src/research_core.cpp`); einige
R-Schleifen sind vektorisiert. Gemessen auf 30 Jahren synthetischer
Tagesdaten (Stand 54b5b4f → aktuelle Fassung):

| Funktion | Stand 54b5b4f | aktuell |
|---|---|---|
| `cpcv_portfolio()` (3 Verfahren, 15 Aufteilungen) | 39,2 s | 0,11 s |
| `tail_regression()` (5 Quantile, B = 100) | 14,9 s | 1,2 s |
| `portfolio_optimize(method = "max_sharpe")` | 2,56 s | 0,01 s |
| `portfolio_optimize(method = "max_diversification")` | 2,00 s | 0,01 s |
| `portfolio_optimize(method = "min_cvar")` | 2,91 s | 0,12 s |
| `portfolio_optimize(method = "min_cdar")` | 3,22 s | 0,09 s |
| `momentum_score()` | 2,40 s | 0,25 s |
| `dcc_fit()` | 1,66 s | 0,01 s |
| `regime_hmm()` | 1,40 s | 0,23 s |

Der Code des Tutorials (Stand 54b5b4f) lief in 55 statt 115 Sekunden
(Wanduhrzeit einschließlich der Simulations- und Bootstrap-Läufe).

* Optimierer: exakte Projektion auf den Simplex mit Grenzen (Knickpunkt-
  Verfahren statt Bisektion) sowie FISTA, minimaler CVaR und minimaler CDaR
  vollständig in C++.
* Quantilsregression (`quantile_reg()`, `tail_regression()`) in C++.
* Kendalls Tau mit O(n log n) (Knight 1966) für `fit_copula()`,
  `dependence_analysis()`, `validate_dependence()` und
  `copula_scenarios()`; Ergebnis gleich `stats::cor(method = "kendall")`.
* Vorwärts-Rückwärts-Schritt des Hidden-Markov-Modells und GARCH(1,1)-Filter
  (DCC, Bootstrap-Verfahren mit GARCH) in C++.
* `momentum_score()`, Drawdown-Episoden in `deep_analysis()` und
  `pooled_bootstrap()` vektorisiert.

### Genauigkeit

* `quantile_reg()` liefert die exakte Lösung des linearen Programms: Die
  MM-Näherung wird auf eine Ecke poliert, bei Bedarf mit Austauschschritten
  verbessert, und die Optimalität wird über die Subgradientenbedingung
  (Zulässigkeits-LP) nachgewiesen. Gegen `quantreg::rq` (Verfahren "br")
  stimmten in 610 Zufallsfällen alle Zielwerte überein (relative Abweichung
  höchstens 10⁻¹⁴); vorher war die MM-Näherung in rund 3 % der Fälle nicht
  optimal.
* Rollierende Varianzen und Kovarianzen (`target_volatility()`,
  `conditional_volatility()`, `signal_volatility()`, rollierende
  Korrelation in `dependence_analysis()`) werden in zwei Durchgängen
  berechnet statt als E[x²] − E[x]². Für eine Reihe mit Mittel 10⁻⁴ und
  Streuung 10⁻⁷ sinkt der relative Fehler von 6·10⁻¹⁰ auf 8·10⁻¹⁶.
* Rollierende Mittelwerte (Signale) mit kompensierter Summe; ein fehlender
  Wert macht nur die Fenster ungültig, die ihn enthalten, statt alle
  folgenden.
* `expm1()` statt `exp(x) - 1` in `backcast_fit()`, der Kennzahl
  `"geometric"` von `pbo()` und `walk_forward()` sowie in
  `set_expected_return()`.
* Die Auslagerung nach C++ selbst ändert Ergebnisse um höchstens 5·10⁻¹⁰
  (Optimierer, Drawdowns, DCC: höchstens 3·10⁻¹²). Größere Unterschiede
  gehen auf die Fehlerkorrekturen unten zurück.

### Fehlerkorrekturen aus dem Stresstest (Red Team / Blue Team)

Vier Prüfteams haben alle exportierten Funktionen mit Randfällen und
feindlichen Eingaben angegriffen; die Befunde wurden korrigiert, mit je
einem Test abgesichert (`tests/testthat/test-blue-*.R`) und in einer zweiten
Runde von unabhängigen Prüfern nachgeprüft.

**Engine `simulation()`** – betroffen waren in dieser ersten Runde 34 der
105 Golden-Master-Fälle; sie wurden neu erzeugt. Eine unabhängige
Nachrechnung von 18 dieser Fälle bestätigt die neuen Werte; 27 typische
gültige Konfigurationen (Kaufen und Halten, Sparplan, Rebalancing, Steuern,
Gebühren, Signale) waren nach dieser Runde bitgleich zum Stand 54b5b4f. Die
Änderungen im nächsten Abschnitt betreffen viele weitere Fälle.

* Fondsmodus (`tax_mode = "funds"`): Die Fondskosten wurden bei voll
  investiertem Depot nie belastet; ein Rumpfjahr trug die volle
  Jahresgebühr; die Steuer bei Liquidation fehlte, wenn der letzte Tag ein
  31.12. war; Sparplan-Einzahlungen wurden als Gewinn versteuert und trugen
  Performancegebühr. Fehlendes Bargeld für Kosten wird jetzt per
  Teilverkauf beschafft.
* Splits mit `fractions = FALSE` schrieben Bruchstücke doppelt gut; ein
  Split im laufenden Jahr setzte die Vorabpauschale auf 0.
* Später startende Assets (`asset_start`) verschoben die Zielgewichte
  dauerhaft. (Die zunächst eingeführte Warnung „kein Erstkauf“ ohne
  `balance_mode` ist durch die Aktivierungsumschichtung ersetzt, siehe
  „Steuerrecht, Fondskosten und Kennzahlen“.)
* Zwei Sparplantermine am selben Handelstag zählten nur einmal; mit
  `dca_anchor = "end"` wanderten nicht existierende Tage (29.–31.) in den
  Vormonat statt wie dokumentiert zu entfallen.
* Ordergebühren: `dca_fee` galt auch für Rebalancing-Trades am Sparplantag
  und für die Anlage des Startkapitals am ersten Tag; der Zwangsverkauf zur
  Vorabpauschale deckte die Gebühr nicht.
* Daten: unsortierte Daten werden sortiert (vorher falscher Zeitraum),
  doppelte Daten sind ein Fehler, fehlende Kurse werden per LOCF gefüllt
  (vorher Depotwert 0), Kurse ≤ 0 sind ein Fehler, führende fehlende Kurse
  wirken wie `asset_start`. Das Attribut `filled` aus `align_series()` wird
  beachtet (vorher Handel an aufgefüllten Wochenendtagen).
* Klare Fehlermeldungen bzw. Warnungen statt kryptischer Abbrüche (Datum als
  Text, tibble, fehlende Spalten, Prozent statt Anteil bei `tax_rate`,
  `asset_bonus`, `church_tax`, unbekannte Felder in `order_fee`, ungeeignete
  `split_thresh`, `spread` ohne Wirkung u. a.).
* Dashboard (`plot()`): Sharpe, Volatilität, rollierende und monatliche
  Renditen stimmen jetzt mit `x$statistics` überein (zuflussbereinigt).
* Neu erzeugte Golden-Fälle nach Ursache:

  | Ursache | Fälle |
  |---|---|
  | Fondsmodus (Kosten, Rumpfjahr, Steuer bei Liquidation, Einzahlungen) | f07, f08, r035, r052, r086, r171, r222, r358, r443, x16 |
  | Fondsmodus und Split mit ganzen Anteilen | f28, x02 |
  | Fondsmodus und später startende Assets | r018, r460, r477 |
  | Split mit ganzen Anteilen | f11, y0082 |
  | später startende Assets (Zielgewichte) | f14, f32, x17 (vier Fälle „start“), x18, x19, y0731, y0886 |
  | später startende Assets und Sparplan-Anker „end“ | x17 (vier Fälle „end“) |
  | fehlende Kurse (LOCF statt Depotwert 0) | x22 |
  | unsortierte Daten | x23 |
  | doppelte Daten (jetzt Fehler) | x24 |

* `update_asset()` leitet das Steuerregime neu ab; `R/rebal_trigger_cookbook.R`
  lief beim Laden des Pakets und liegt jetzt unter
  `inst/examples/rebal_trigger_cookbook.R`.

**Auswertung und Daten**

* `deep_analysis()`: risikoloser Zins je Kalenderabstand aufgezinst (vorher
  bei Handelstagen nur ~69 % abgezogen), reale Kennzahlen gegen den realen
  Zins, Jahrestabelle über die Kalenderjahre (vorher Werte falschen Jahren
  zugeordnet), rollierendes Beta bei später startendem Benchmark, führende
  fehlende Werte, Sortierung und Duplikate, Attribut `filled`.
* Datumsangaben: POSIXct wird überall im eigenen Zeitzonen-Kalendertag
  gelesen (vorher UTC, ein Tag früher); Text nur als JJJJ-MM-TT bzw.
  JJJJ/MM/TT; Zahlen als Text oder Faktor (z. B. Dezimalkomma) sind ein
  Fehler statt still falsch.
* `align_series()`, `align_macro()` (Vorjahreswert per Datum),
  `splice_series()` (Proxy in echten Lücken), `return_heatmap()`
  (Rumpfjahr), `signal_analysis()` (diskrete Signale), `momentum_score()`
  (Monatsende statt Überlauf, z. B. 31.03. − 1 Monat = 29.02.),
  `tactical_simulation()` (`lag` in echten Handelstagen), `backcast()`,
  `check_series()`, `strategy_from_weights()`.

**Statistik und Optimierung**

* `reality_check()` mit einem Kandidaten (p-Wert war falsch, SPA NA),
  `scenario_risk()` (CVaR nach Rockafellar-Uryasev statt Näherung),
  `walk_forward()` (Überlappungen und Lücken), `copula_scenarios()` (mehrere
  Stress-Anlagen gemeinsam bedingt gezogen), `efficient_frontier()`
  (Grenzen geprüft), `deflated_sharpe()`/`sharpe_haircut()`/`pbo()`
  (Auslöschung bei Spalten ohne Schwankung), `cpcv_portfolio()` (ppy aus
  den Daten, Purge/Embargo bei 0), `regime_hmm()` (loglik passt zu den
  gelieferten Parametern), `risk_contributions()`, `dcc_fit()` (perfekt
  korrelierte Reihen), Kursdaten werden sortiert und auf Kurse ≤ 0 geprüft.
* Unbenannte Grenzvektoren der Länge N werden in `portfolio_optimize()`
  positionsweise angewendet (vorher still ignoriert).

**Bootstrap, Entnahme, Planung**

* Inflation aus einem Preisindex-Niveau (`keep_aux`, `inflation_type =
  "level"`) sprang an Blockgrenzen; jetzt aus den gezogenen Zeilenverhältnissen.
* `goal_optimize()`: Zielwahrscheinlichkeit nicht mehr überschätzt
  (stufentreue Interpolation, Abgleich mit der Simulation).
* `withdrawal_cohorts()` prüft den Monatskalender, `horizon_model()` zieht
  bei einem einzigen Wert korrekt, `income` mit Start nach dem Pfadende
  wirkt nicht mehr, Matrix-Eingaben werden in Dimension geprüft (vorher
  Speicherzugriff außerhalb), `bootstrap_probability()` findet Variablen der
  aufrufenden Umgebung, `summary()` von Studien wertet Drawdown-Quantile mit
  der richtigen Richtung, `plateau()` ebenso.
* Zufallszahlen: Mit `seed` bleibt das Ergebnis reproduzierbar und der
  Zufallszustand der Sitzung unverändert; mit `seed = NULL` läuft der
  Zufallsstrom jetzt weiter (vorher lieferten wiederholte Aufrufe dasselbe).

### Steuerrecht, Fondskosten und Kennzahlen

Die Steuerlogik der Engine wurde gegen den Gesetzestext geprüft und
angepasst; jede Änderung ist mit einer Handrechnung als Test abgesichert
(`tests/testthat/test-tax-law.R`, `test-engine-rest.R`) und von
unabhängigen Prüfern nachgerechnet. Insgesamt sind seit dem Stand
54b5b4f alle 105 Golden-Master-Fälle neu erzeugt (einschließlich der Runden
unten). Nur bei `f18` und `f19` entsprechen alle Zahlenfelder noch dem
Stand 54b5b4f (geprüft mit der Python-Fassung).

**Besteuerung**

* Vorabpauschale (§ 18 InvStG): Basisertrag und Deckel (Wertzuwachs im
  Kalenderjahr) beziehen sich für jedes Lot auf den Kurs zu Jahresbeginn,
  auch bei Kauf im laufenden Jahr; die Zwölftelung (je voller Monat vor dem
  Erwerbsmonat) wird nach dem Deckel angewendet. Ein zeitvariabler
  Basiszins (`base_rate_flex`) wird vom ersten Handelstag des Jahres
  genommen (vorher 31.12.); fehlende Basiszins-Werte gelten in beiden
  Datenformen (Kalender- oder Handelstage) als 0.
* Die Vorabpauschale gilt am ersten Handelstag des Folgejahres als
  zugeflossen und wird dort mit den Töpfen (Sparer-Pauschbetrag,
  Verlusttopf) des Folgejahres abgerechnet, vor den Trades des Tages; hat
  das Folgejahr keinen Handelstag, am 1.1., endet die Simulation vorher, am
  letzten Tag.
* Verluste nach Nutzung des Sparer-Pauschbetrags: zuerst Erstattung bereits
  gezahlter Steuer, dann Freigabe des Pauschbetrags, der Rest geht in den
  Verlusttopf. Eine Erstattung nach Nutzung eines Verlustvortrags wurde
  falsch berechnet. Die Erstattung aus dem letzten Jahresabschluss fehlte im
  Endwert.
* Private Veräußerungsgeschäfte (§ 23 EStG): Die Freigrenze wird vor dem
  Verlustvortrag geprüft, ein Saldo von genau 1000 EUR ist
  steuerpflichtig; die Steuer wurde bisher nur ausgewiesen, jetzt wird sie
  vom Depot bezahlt (am Abrechnungstag der Vorabpauschale, sonst am letzten
  Tag; aus Cash, sonst per Zwangsverkauf). Kauf am 29.02.: Fristende am
  28.02. des Folgejahres (§ 188 Abs. 3 BGB), Verkauf ab 01.03. steuerfrei.
* Kirchensteuer (`church_tax`) wirkt jetzt auch auf die Einkommensteuer
  (§ 23-Steuer, persönlicher Satz der Günstigerprüfung); der
  Sonderausgabenabzug der Kirchensteuer ist auf diesem Weg (mit
  `marginal_tax_rate`) nicht abgebildet, mit `taxable_income` schon (siehe
  unten). Die
  Günstigerprüfung (§ 32d Abs. 6 EStG) vergleicht die Belastung
  einschließlich Zuschlagsteuern (vorher starre Schwelle 25 %, die mit
  Kirchensteuer mehr Steuer ergeben konnte).
* Zwangsverkäufe für Steuerzahlungen runden bei `fractions = FALSE` auf
  ganze Stück auf und verkaufen bei Restfehlbetrag nach; negatives Cash
  wird nicht mehr still auf 0 gesetzt (offener Rest mit Warnung).
* Die Verkaufsmenge beim Umschichten schätzt die Steuer mit freiem
  Sparer-Pauschbetrag, Verlusttopf, § 19-Anrechnung der Vorabpauschale und
  dem Satz der Günstigerprüfung und berücksichtigt das bereits beim Asset
  liegende Cash; vorher wurde zu viel verkauft und am selben Tag
  zurückgekauft (doppelter Spread, ungewollte Gewinnrealisierung).

**Fondsmodus (`tax_mode = "funds"`)**

* `funds_fee` wird linear belastet (`funds_fee` / Tage des Jahres je Tag):
  ein volles Kalenderjahr kostet genau `funds_fee` Prozent.
* Die High-Watermark der Performancegebühr wird nach Abzug der Gebühren
  fortgeschrieben.
* Der Teilverkauf zur Deckung der Fondskosten trägt keine Ordergebühr und
  keinen Spread.

**Später startende Assets**

* Am Starttag eines Assets (`asset_start` oder erster Kurs) wird auch ohne
  `balance_mode` auf die Zielgewichte umgeschichtet, damit das Asset Mittel
  erhält (vorher kein Erstkauf). `asset_start` nach dem letzten Datentag ist
  ein Fehler (vorher still Tag 1).

**Kennzahlen mit Sparplan**

* `cagr` ist mit Einzahlungen die geldgewichtete Rendite (interner
  Zinsfuß/XIRR aus Startwert, datierten Einzahlungen und Endwert,
  Kalendertage / 365,25); vorher war es die Wachstumsrate des Depotwerts
  einschließlich Einzahlungen (z. B. 82 % bei 4 % TTWROR). Bei
  Beinahe-Totalverlust wird die Nullstelle gefunden.
* Drawdowns werden mit Einzahlungen auf dem zeitgewichteten Wertindex
  `twr_index` gemessen; Calmar, Serenity und Martin verwenden dann die
  TTWROR. An Tagen mit Einzahlung wird zum Zeitpunkt der Zahlung bewertet
  (Vortagesbestand zum Schlusskurs vor der Zahlung): ohne Kosten folgt der
  Index exakt dem Kurs, Kaufkosten der Einzahlung belasten das Kapital nach
  der Zahlung (vorher z. B. −23 % Tagesrendite bei 1 EUR Vorbestand).
* Neue Ergebniselemente `twr_index`, `invested` (Startwert plus
  Einzahlungen, brutto vor Kaufkosten) und `external_flows`. `print()`,
  `summary()` und Dashboard beschriften die CAGR mit
  Sparplan als geldgewichtet, den Drawdown als zeitgewichtet; ebenso die
  Ausgaben von `bootstrap_study()`, `sensitivity_grid()`,
  `rebalancing_sensitivity()`, `leverage_sensitivity()` und
  `param_search()`.
* Negativer Endwert (nicht gedeckte Steuerschuld): `cagr` und `ttwror` sind
  NA mit Warnung statt NaN, Drawdowns höchstens 100 %.
* `result_index()`, `deep_analysis()` (`mwrr` mit derselben XIRR-Rechnung
  wie die Engine) und `withdrawal_simulation(start_value = <Ergebnis>)`
  folgen diesen Konventionen; hält das Ansparergebnis nur noch Cash (z. B.
  `liquidate = TRUE`), gilt `cost_basis = 100` (vorher doppelte
  Besteuerung in der Entnahmephase).
* `dca_value` und `dca_span` werden geprüft (klare Meldung statt
  R-interner Fehler).

**Entnahme und Bootstrap**

* `withdrawal_rule()`: Das Argument `horizon` ist entfernt. Es hatte keine
  Wirkung; die Restjahre der Regeln ergeben sich aus der Zahl der Planjahre
  von `withdrawal_simulation()`.
* `bootstrap_config()`: neues Argument `aux_type` kennzeichnet je
  Zusatzreihe, ob sie ein Niveau (`"level"`, z. B. Preisindex; wird über
  die gezogenen Zeilenverhältnisse fortgeschrieben) oder eine Rate
  (`"rate"`, Werte der gezogenen Zeilen unverändert) ist. Ohne Angabe
  verhalten sich Konfigurationen wie bisher (Präzisierung siehe unten).

### Einkommensteuertarif, nicht definierte Kennzahlen, Anschaffungskosten

**Einkommensteuertarif (`taxable_income`, `tax_tariff`)**

* Der Einkommensteuertarif nach § 32a Abs. 1 EStG (Fassung ab VZ 2026,
  Grundtarif, Einzelveranlagung, kein Splitting) und der
  Solidaritätszuschlag nach §§ 3, 4 SolZG (Freigrenze 20 350 EUR,
  Milderungszone 11,9 %) stehen in der austauschbaren Datei
  `inst/extdata/steuertarif.csv`. Die neue Funktion `read_tax_tariff()`
  liest und prüft sie (Komma als Trennzeichen, Pflichtspalten, aufsteigende
  Zonen, Grenzsteuersatz jeder Zone zwischen 0 und 1, T(x) ≤ x; Sprung an
  einer Zonengrenze über 1 EUR: Warnung). Ein künftiger Tarif wird durch
  eine eigene Datei übernommen (`tax_tariff = "<Datei>"`).
* Neues Argument `taxable_income` von `simulation()`: zu versteuerndes
  Einkommen ohne die Kapitalerträge und § 23-Gewinne der Simulation, in EUR
  je Kalenderjahr (Zahl für alle Jahre, nach Jahren benannter Vektor oder
  `data.frame(year, taxable_income)`; ein fehlendes Simulationsjahr ist ein
  Fehler). Wirkt nur mit `tax_mode = "person"`. Dann gilt:
  * § 23-Steuer exakt nach Tarif als ESt-, Soli- und Kirchensteuer-Zuwachs
    auf das vorgegebene zvE.
  * Günstigerprüfung (§ 32d Abs. 6 Satz 1 EStG): unterjährig wird wie bei
    einer Bank die Abgeltungsteuer einbehalten; im Jahresabschluss wird die
    Gesamtbelastung mit und ohne tarifliche Besteuerung der per Saldo
    besteuerten Kapitalerträge (einschließlich Zuschlagsteuern) verglichen
    und die Differenz im Folgejahr erstattet bzw. nachgezahlt.
  * Kirchensteuer als Sonderausgabe nach dem Zahlungsjahr-Prinzip (§ 11,
    § 10 Abs. 1 Nr. 4, § 10 Abs. 4b Satz 2 und 3 EStG, siehe den
    nächsten Abschnitt).
  * `marginal_tax_rate`, `include_soli_on_income_tax` und
    `soli_rate_income_tax` wirken auf diesem Weg nicht (Warnung, wenn
    angegeben). Neues Element `tax_report$tariff_years` mit einer Zeile je
    Jahr.
  * Vereinfachungen (siehe `?simulation`, Abschnitt
    „Einkommensteuertarif“): ein Tarif für alle Simulationsjahre,
    Kirchensteuer ungerundet und ohne Kinderfreibeträge (§ 51a EStG),
    keine Vorauszahlungen, kein Verlustrücktrag.
* Ohne `taxable_income` rechnet die Engine unverändert (Weg über
  `marginal_tax_rate`). Python 0.5.0 und Julia 0.5.0 rechnen beides
  bitgleich nach.

**Nicht definierte Kennzahlen**

* Neues Ergebniselement `undefined_metrics` (`metric`, `reason`, `detail`):
  eine Zeile je Kennzahl, die `NA` ist, mit Ursache (z. B.
  `negative_end_value`, `too_short`, `zero_volatility`). `print()` und
  `summary()` zeigen „nicht definiert (Ursache)“ statt `NA`. Der Endwert
  bleibt unverändert (auch negativ). Bei einem Einzeltag sind `cagr`,
  `ttwror`, `buys` und `sells` `NA` (mit Warnung).
* Neues Element `tax_report$open_tax_debt`: am Ende offene, nicht gedeckte
  Steuerschuld in EUR (sonst 0).
* Ein Fließkommarest unter 1e-9 EUR der gezahlten Steuern nach vollständiger
  Erstattung im Jahresabschluss wird 0.
* `summary()` liefert `total_return_twr` (zeitgewichtete Gesamtrendite),
  `return_on_invested` ((Endwert − Eingezahlt) / Eingezahlt) und
  `total_return` als Alias für `total_return_twr`; mit Einzahlungen zeigt
  die Ausgabe beide Werte.
* Warnung, wenn `funds_fee` oder `bonus_fee` ohne `tax_mode = "funds"`
  angegeben werden (vorher still ohne Wirkung).

**Anschaffungskosten in der Entnahmephase**

* Neues Element `open_lots` (nur `tax_mode = "person"`): die am letzten Tag
  gehaltenen Lots je Asset (Kaufdatum, Stück, Anschaffungskurs,
  anzurechnende Vorabpauschale) mit Steuerregime, Teilfreistellung und Cash.
* `withdrawal_simulation(start_value = <Ergebnis>)` verwendet die offenen
  Lots (FIFO und Übernahme weiterer Werte siehe nächsten Abschnitt). Ohne
  `open_lots` gilt die bisherige Näherung, bei `tax_mode = "person"` jetzt
  mit Warnung. Ein Startvermögen ≤ 0 (auch ein Endwert ≤ 0 des
  Ergebnisses) ist ein Fehler.

**Zusatzreihen (`aux_type`)**

* `aux_type = "rate"` bedeutet immer Prozent pro Jahr (2 = 2 % p. a.) und
  gilt bei ausdrücklicher Angabe einheitlich in `keep_aux`,
  `withdrawal_paths()`, `withdrawal_simulation()` und `withdrawal_cohorts()`;
  `bootstrap_data()` setzt dafür das Attribut `aux_type`. Neues Argument
  `inflation_type` von `withdrawal_cohorts()` (`"level"`, `"rate_pa"`).
  Widersprechende Angaben sind ein Fehler. Ohne Angabe in `aux_type` bleibt
  das bisherige Verhalten (als Inflation die Niveau-Variante).

**Golden-Master-Fälle dieser Runde**

* Neu erzeugt: `f18`, `f19`, `f31`, `x06`, `x07`, `x08`, `x22`, `x23` (nur
  die Druckausgabe „nicht definiert“ statt NA) sowie `r324` und
  `x03_30y_details` (gezahlte Steuern 2,27e-13 bzw. 2,84e-14 EUR → 0;
  Druckausgabe ohne leeren Steuerblock). Die neuen Felder `open_tax_debt`
  und `tariff_years` gehören bewusst nicht zum Golden-Format.

### Kirchensteuer nach dem Zahlungsjahr, FIFO in der Entnahmephase

**Kirchensteuer als Sonderausgabe (Tarifweg mit `taxable_income`)**

* Die Kirchensteuer ist Sonderausgabe im Jahr ihrer Zahlung (§ 11, § 10
  Abs. 1 Nr. 4 EStG). Je Jahr gibt es einen saldierten
  Kirchensteuer-Bescheid; Nachzahlung oder Erstattung daraus wird am
  Abrechnungstag im Folgejahr gebucht. Erstattungen werden mit den im
  Erstattungsjahr gezahlten Kirchensteuern verrechnet, ein Überhang wird
  dem Einkommen hinzugerechnet (§ 10 Abs. 4b Satz 2 und 3 EStG).
* Ist die Günstigerprüfung günstiger, mindert die im Jahr auf die
  Kapitalerträge einbehaltene Kirchensteuer das zvE des Zuflussjahres. Die
  Kirchensteuer als Zuschlag zur Kapitalertragsteuer ist sonst nicht
  abziehbar (§ 10 Abs. 1 Nr. 4, 2. Halbsatz); dass der Abzug bei
  tariflicher Besteuerung erhalten bleibt, folgt der Darstellung der
  Rechtslage in der Fachliteratur (Haufe), nicht einem Urteil.
* Die Kirchensteuer auf die § 23-Einkommensteuer wirkt erst im
  Zahlungsjahr (Folgejahr). Das Jahr nach dem letzten Simulationsjahr wird
  nicht veranlagt (Ausnahme: nachlaufende Vorabpauschale).
* `tax_report$tariff_years`: neue Spalten `church_tax_paid_deductible`,
  `church_tax_refunded`, `church_tax_net_deduction`, `deduction_effect`,
  `church_tax_withheld_k`, `burden_without_gp`, `burden_with_gp` und
  `settlement`; `church_tax_deduction` und
  `church_tax_deductible_next_year` sind durch `church_tax_net_deduction`
  bzw. `church_tax_settlement_next_year` ersetzt; `refund` enthält die
  saldierte Erstattung des Jahres.
* Neues Element `tax_report$next_year` (nur `tax_mode = "person"`): der
  Steuerzustand des Jahres nach dem letzten Datentag (verbrauchter
  Sparer-Pauschbetrag, Verlusttöpfe; mit `taxable_income` der letzte
  Kirchensteuer-Bescheid) für eine Fortsetzung.

**Entnahmephase nach einer Ansparphase
(`withdrawal_simulation(start_value = <Ergebnis>)`)**

* Mit `open_lots` und `tax_mode = "person"` übernimmt die Entnahmephase
  die einzelnen Lots und verkauft je Asset die ältesten zuerst (FIFO, mit
  Anrechnung der Vorabpauschale wie in der Engine); ohne Lots bzw. mit
  ausdrücklichem `cost_basis` wie bisher mit Durchschnittskosten.
* Nicht ausdrücklich angegebene Werte werden aus dem Ergebnis übernommen:
  `asset_bonus`, `loss_carryforward` (allgemeiner Verlusttopf aus
  `next_year`), `sale_cost` (halber Spread), der im ersten Planjahr schon
  verbrauchte Sparer-Pauschbetrag und `vorabpauschale = FALSE`, wenn keine
  Fonds gehalten werden. Ein Hinweis nennt die übernommenen Werte; das
  Ergebnis führt sie unter `adopted`. Ausdrückliche Angaben haben Vorrang.
* Warnungen bei Ordergebühren der Ansparphase, uneinheitlicher
  Teilfreistellung oder uneinheitlichem Spread und bei § 23-Assets. Als
  gehalten gilt ein Asset mit Endwert > 1e-12 × Depotwert. Grenzen
  (u. a. keine unterjährige Verlusterstattung, fester Satz `tax_rate`
  ohne Kirchensteuer und Tarif) stehen in `?withdrawal_simulation`.
* `open_lots` enthält je Asset zusätzlich `asset_spread` und `order_fee`.

**Druckausgabe**

* `print()` richtet die Zeile „Martin Ratio“ wie die übrigen Kennzahlen
  aus. Deshalb sind 101 Golden-Master-Fälle neu erzeugt (alle Zahlenfelder
  unverändert); unverändert in dieser Runde sind `x21_err_missing_col`,
  `x24_dup_dates`, `y0722` und `y0871`.

### Review 7, Nachprüfung und deutsche Ausgaben

**Engine `simulation()`**

* Vorabpauschale mit dem ersten Kurs des Jahres (A7-01); Aufteilung der
  Vorabpauschale unabhängig von der Reihenfolge der Lots (A7-04).
* Rebalancing zum Tageskurs (A7-06); keine Doppelorders bei der Aktivierung
  später startender Assets (A7-03) und am ersten Tag mit `balance_mode`
  (R8-05: vorher kaufte der Handelsblock und das Rebalancing schichtete
  danach Reste um).
* Sortino Ratio: Downside-Abweichung über alle Beobachtungen,
  `sqrt(mean(pmin(Überschussrendite, 0)^2))` (Sortino/Price, wie
  `deep_analysis()`); vorher nur über die negativen Tage (A7-08).
* Ein Signal-Asset mit offener Position investiert neues Geld (A7-09).
* Liquidationstag ohne weiteren Handel (A7-02), Simulationsende am 31.12.
  (A7-11),
  Splits ohne Bestand (A7-07), wachsende Lot-Liste (A7-05).
* Prüfung von Listen-Strategien (C7-01) und der Steuerargumente mit klaren
  Warnungen (A7-10, C7-04). Warnschwellen für Anteil statt Prozent so, dass
  realistische kleine Prozentwerte nicht warnen (R8-04): `base_rate` und
  `risk_free` unter 0,05, `balance_thresh` unter 0,2, `marginal_tax_rate`
  unter 1.
* `summary()` druckt über eine eigene print-Methode
  (`print.summary.SimLevResult`, C7-06); Hilfeseite `asset_config` (C7-03).

**Entnahme und Planung**

* `withdrawal_simulation()`: Vorabpauschale der Entnahmephase im Folgejahr
  (B7-01); am Pfadende wie `simulation()` (Steuer mit den Töpfen des
  Folgejahres, Zwangsverkauf im ablaufenden Jahr, R8-03); bei einem
  Horizont H auf längeren Pfaden Endvermögen und Steuern wie auf Pfaden mit
  H Jahren (R8-02); planmäßig vollständige Entnahme der Verzehrregeln
  (`one_over_n`, `abw`, `hebeler`, `vpw`) gilt auch mit Steuern nicht als
  Fehlschlag (R8-08).
* `lumpsum_vs_dca()` exakt bei konstanten Stückzahlen (B7-02);
  `goal_optimize()` meldet die simulierte Erfolgsquote (B7-03);
  Monatsarithmetik auf das Monatsende begrenzt (B7-04); weitere Prüfungen in
  `withdrawal_max_rate()`, `withdrawal_simulation()`, `withdrawal_rule()`
  u. a. (B7-06 bis B7-08).

**Statistik und Grafik**

* `regime_hmm()` schneller und bitgleich (B7-05); Prüfungen in
  `portfolio_optimize()` (B7-09), `upper = Inf` bedeutet keine Obergrenze
  (R8-07, vorher Warnung und Abbruch); gewichtete Quantile nach Typ 7
  (B7-10); Dokumentation von `seed` (B7-11).
* `walk_forward()`: Fenster vom Startdatum aus lückenlos und ohne
  Überlappung (R8-01).
* `bootstrap_study()` meldet Fehler und Warnungen der Einzelläufe (C7-07).
* `plot()`: `panels` und `colors` (C7-08); R-Farbnamen werden akzeptiert,
  Farbwerte geprüft, Transparenz über `adjustcolor()` (R8-06); Layout,
  Achsen, Ränder und Farblogik überarbeitet (u. a. `style = "custom"` mit 3,
  5 oder 7 Panels ohne Warnung).

**Deutsche Ausgaben**

* Alle Meldungen und Ausgaben sind deutsch, z. B. `print(result)`: „SimLev
  Simulationsergebnisse“, „Wertentwicklung“, „Endwert“, „Risiko“;
  `summary()`: „SimLev Zusammenfassung“; das Dashboard ebenso.

**Golden-Master-Fälle**

* Review 7: 94 Fälle neu erzeugt (Sortino in allen, Rebalancing, Signale,
  Aktivierung, VP-Aufteilung, Splits, Jahresanfangskurs).
* Nachprüfung und Übersetzung: 101 Fälle neu erzeugt (deutsche
  Druckausgabe); davon 19 mit geänderten Zahlen durch R8-05 (`f06`, `f10`,
  `f11`, `f12`, `f27`, `f33`, `r018`, `r137`, `r290`, `r341`, `r358`,
  `r375`, `r426`, `r460`, `r477`, `x04`, `x05`, `x10`, `y0731`).

### Strukturumbau der Engine

* `simulation()` ist in interne Phasen aufgeteilt (Dateien `sim_validate.R`,
  `sim_prepare.R`, `sim_actions.R`, `sim_loop.R`, `sim_evaluate.R`):
  Eingabeprüfung, Datenvorbereitung und `sim_mem`, Termine und Flags,
  Zahlungshelfer, Tagesschleife mit Tagesschritten (Aktivierung, Split,
  Sparplan, Handel, Rebalancing, Gewinnrealisierung, Vorabpauschale,
  Fondskosten, Liquidation), Abschluss des letzten Jahres und Auswertung.
  Signatur, Ergebnisse, Warnungen (Text, Reihenfolge, Aufruf), Meldungen,
  Fehler und `details`-Ausgabe sind unverändert; bitgleich nachgewiesen
  gegen den Stand vor dem Umbau (1 182 Konfigurationen mit allen 105
  Golden-Fällen, zusätzlich 5 000 Zufallskonfigurationen, je `identical()`
  des Ergebnisobjekts).
* Toter Code entfernt: `get_tax_regime()`, `calculate_bisection_search()`
  (mit seinen Tests), der Beispielblock in `compute_rebal_trigger.R` und
  ungenutzte lokale Variablen.
* Feldfolge von `sim_mem` (Positionszugriff der C++-Kerne) zentral in
  `.SIM_MEM_LAYOUT` festgelegt und vor dem ersten C++-Aufruf geprüft;
  Reihenfolge und In-place-Semantik in den C++-Dateien kommentiert (C7-11).
* Korrektur: Mit `details = TRUE` und `taxable_income` brach
  `simulation()` ab („object 'tax_due' not found“), sobald ein § 23-Gewinn
  die Freigrenze erreichte. Die Steuer (ESt + Soli + KiSt des
  § 23-Zuwachses) wird im Tarifweg nun in der Jahresveranlagung
  ausgegeben; die Zahlen waren nicht betroffen.

### Abschlussprüfung (Review 9)

* R9-01 (Entnahme): Die Vorabpauschale am Pfadende wird mit den Steuertöpfen
  (Verlusttopf, Sparer-Pauschbetrag) nach dem Verkauf des Pfadendes
  berechnet.
* R9-02 (Engine, `details`): Im Tarifweg heißt die Zahlung aus der
  Jahresveranlagung „Veranlagung <Jahr>: Nachzahlung … (davon § 23 …,
  Kirchensteuer-Sonderausgaben …, ggf. Günstigerprüfung …)“ mit der
  Aufteilung auf die Assets, statt „§ 23 EStG: Steuer“ (auch bei Fonds ohne
  § 23-Gewinn). Nur Text, Zahlen unverändert.
* R9-03 (Zahlenformat, Singular/Plural): Beträge in Meldungen ohne
  englisches Tausenderkomma (`%.2f`), „1 Tag“/„n Tage“, „1 Tagesrendite“,
  ohne Wert nur „–“ (statt „– Tage“); ebenso „Kursspalte … fehlt“ und
  „Simulationsjahr“ im Singular.
* R9-04 (Startkapital): `summary()` zeigt „Startkapital“ (Argument
  `start_value`, neues Feld `start_capital` = `invested[1]` minus Einzahlung
  des Starttags) getrennt vom „Depotwert Starttag“ (Feld `start_value`,
  nach Kaufkosten, mit Sparrate des Starttags); das Dashboard verwendet für
  „Startkapital“ dieselbe Definition.
* R9-05 (Dashboard): Das Korrelationspanel zeigt die rollierende
  Korrelation zu `compare`; Panels, die ohne Vergleich bzw. Daten nicht
  gezeichnet werden können, entfallen mit Warnung statt eines leeren Felds.
* R9-06 (Prozent-Konvention): Die Warnung „wird als … % gelesen“ gilt auch
  für `risk_free` als Spaltenname und die Basiszins-Spalte
  (`base_rate_data`): maßgeblich ist der Median der Werte ohne `NA` und 0
  (Schwellen wie bei den Zahlen).
* R9-07 (Ausgaben): Alle Meldungen und Ausgaben verwenden echte Umlaute und
  ß (als `\u`-Escapes; der R-Code bleibt ASCII). Zahlen mit Dezimalpunkt;
  Tausendertrennung nur in Tabellen und Druckausgaben, dort mit Leerzeichen
  (z. B. „20 350“), nie mit Punkt oder Komma (`print()` der Zielplanung,
  `deep_analysis()`, Lump Sum vs. DCA, Achse des Backcast-Plots); Meldungen
  ohne Tausendertrennung.
* Golden-Master-Fälle: Zahlen unverändert; die Druckausgabe von 17 Fällen
  ändert sich durch R9-03 (`f18`, `f19`, `f31`, `r001`, `r035`, `r256`,
  `r290`, `r477`, `x04`–`x08`, `x15`, `x16`, `x22`, `x23`).

### Portabilität und Dokumentation

* Zeichenketten in `simulation.R` enthalten nur noch ASCII (Umlaute als
  `\u`-Escapes). Die Ausgabe ist unverändert; die Warnung von
  `R CMD check` und die Übersetzungswarnungen in Nicht-UTF-8-Umgebungen
  entfallen.
* Hilfeseiten durchgehend deutsch; Glossar der Argumentnamen und Einheiten
  (`?SimLev`, README).
* README: falsche Pfade und verwaiste CI-Badges korrigiert.
* Neue Tests für die C++-Kerne (`tests/testthat/test-cores.R`) und für jeden
  Befund des Stresstests (`tests/testthat/test-blue-*.R`).

### Nachtrag

* `simulation()` brach mit „subscript out of bounds“ ab, wenn `funds_fee`
  oder `bonus_fee` außerhalb des Fondsmodus angegeben war und zugleich ein
  Argument, das später geprüft wird (`church_tax` > 0 mit `tax_rate`,
  `taxable_income`): Die Warnung über die ignorierten Fondskosten
  überschrieb die interne Liste der angegebenen Argumente. Jetzt folgt nur
  die Warnung, die Simulation läuft weiter.

### Bereinigung der Schnittstelle

* Entfernt: die interaktiven Grafiken `plot_interactive()` (beide Wege,
  plotly und eigenes HTML) und der Platzhalter `export_html_dashboard()`.
  Die statischen Grafiken (`plot()`, `export_dashboard()`) bleiben.
* Entfernt: `create_config()` (Alias von `bootstrap_config()`),
  `migrate_strategy()` (die veralteten Klassen `"etn_standard"` und
  `"etn_deliverable"` setzt `asset_config()` schon mit Warnung um) und
  `as_list()` mit seinen Methoden (eine klassenlose Liste liefert
  `unclass()`).
* `portfolio_templates()` ist in `portfolio_template()` aufgegangen: Ohne
  `name` (neuer Standard `NULL`) liefert `portfolio_template()` die
  Vorlagenliste wie bisher `portfolio_templates()`; `map` und weitere
  Argumente sind dann ein Fehler.
* `Suggests`: `plotly` und `TTR` gestrichen. `TTR` bleibt in den Beispielen
  eine bequeme Möglichkeit, Indikatoren für Signale zu berechnen; es ist
  keine Abhängigkeit von SimLev und wird bei Bedarf separat installiert.
* Referenzfälle: `bootstrap/cfg_create` entfällt; `data_prep/pt_list`
  ruft `portfolio_template()` auf (Ergebnis unverändert); neu
  `data_prep/pt_err5`.

### Optionale Pakete eingebaut

Funktionen, die bisher mit einem installierten optionalen Paket einen
anderen Weg nahmen als ohne, nehmen jetzt immer den Paket-Weg. Die dafür
nötigen Teile der Pakete sind lizenzkonform (GPL) in SimLev übernommen
(Herkunft, Autoren und Anpassungen in `inst/COPYRIGHTS`, Feld `Copyright`
in `DESCRIPTION`); die Pakete selbst sind nicht mehr nötig und aus den
`Suggests` gestrichen.

* evd: `fpot()` und `fpot.norm()` aus evd 2.3-7.1 (Alec Stephenson) als
  interne Funktion `.evd_fpot()` (`R/vendor_evd.R`, nur `model = "gpd"`
  ohne `cmax`/`mper`), die negative Log-Likelihood `nlgpd` aus evd
  `src/pot.c` mit unverändertem Rumpf in `src/vendor_evd.c` (gerufen über
  eine `.Call`-Hülle, die die Argumente wie `.C` prüft). Die Ergebnisse
  sind bitgleich zu evd (alle 129 Referenzfälle des Moduls `evd`
  unverändert). Sichtbare Änderung für Nutzer ohne evd: `bootstrap()`,
  `bootstrap_study()` u. a. mit Verfahren `"evt"` schätzen die GPD der
  Tails bei mindestens 30 Überschreitungen jetzt per Maximum-Likelihood
  (`method = "MLE"`) statt mit dem Momenten-Schätzer; bei weniger
  Überschreitungen oder wenn der Fit scheitert, bleibt es beim
  Momenten-Schätzer. Referenzfall `bootstrap/bs_evtparamslisttailprob01bothtails`
  (40 Überschreitungen) neu erzeugt.
* imputeTS mit stinepack: `na_interpolation()` und `na_locf()` aus
  imputeTS 3.4 (Steffen Moritz, Sebastian Gatscha, Earo Wang, Ron Hause)
  als interne Funktionen `.imputets_na_interpolation()` und
  `.imputets_na_locf()` (`R/vendor_imputets.R`, `option = "stine"` und
  `"linear"` – diese wie im Original mit `stats::approx`, `rule = 2`, sofern
  `rule` nicht über `...` gesetzt ist (`methods::hasArg`; `methods` ist
  dafür in den `Imports`); `"spline"` und `na_remaining = "rm"`/`"mean"`
  sind nicht übernommen und brechen ab), der C++-Kern `locf` aus imputeTS
  `src/locf.cpp` mit unverändertem Rumpf in `src/vendor_imputets.cpp`
  (`.imputets_locf()`), dazu `stinterp()`, `stinemanSlopes()` und
  `parabolaSlopes()` aus stinepack 1.5 (Tomas Johannesson, Halldor
  Bjornsson, Gabor Grothendieck; GPL (>= 2)) als
  `.stinepack_stinterp()` u. a. (`R/vendor_stinepack.R`). Die Ergebnisse
  sind bitgleich zu imputeTS/stinepack (alle 203 Referenzfälle des
  Moduls `imputets` unverändert, einschließlich der drei Fälle `ni_lin_*`
  mit `option = "linear"`). Sichtbare Änderung für Nutzer ohne imputeTS:
  `backcast_fit(index_fill = "stine")` und `backcast(fill = "stine",
  index_fill = "stine")` interpolieren jetzt nach Stineman statt linear,
  der Hinweis „Paket 'imputeTS' nicht installiert, verwende lineare
  Interpolation statt Stineman.“ entfällt. Referenzfälle
  `backcast/fill_stine_0`, `fill_stine_1`, `bf_stine` und `bc_stine` neu
  erzeugt.
* rugarch mit Rsolnp und truncnorm: `ugarchspec()`,
  `ugarchfit()` und `coef()` aus rugarch 1.5-6 (Alexios Galanos, Tobias
  Kley) für den Weg von `.fit_garch11()` (sGARCH bzw. gjrGARCH(1,1),
  ARMA(0,0) mit Mittelwert, Normalverteilung, Solver `"hybrid"`) als
  interne Funktionen `.rugarch_ugarchspec()`, `.rugarch_ugarchfit()` und
  `.rugarch_coef()` mit Startwerten, Schranken, Solver-Kette (solnp →
  nlminb → zweimal gosolnp), `.makefitmodel` (Hesse-Matrix, `robustvcv`)
  und Warnungen (`R/vendor_rugarch.R`; andere Modelle, Verteilungen,
  ARMA-Terme, Regressoren u. a. sind nicht übernommen und brechen ab), der
  C-Filter `sgarchfilterC`/`gjrgarchfilterC` aus rugarch `src/` mit
  unverändertem Rumpf in `src/vendor_rugarch.c` (über `.Call`-Hüllen, die
  die Argumente wie `.C` prüfen), dazu `solnp()` und `gosolnp()` aus
  Rsolnp 1.16 (Alexios Ghalanos, Stefan Theussl) als `.rsolnp_solnp()`,
  `.rsolnp_gosolnp()` (`R/vendor_rsolnp.R`, ohne `cluster`) und
  `rtruncnorm()` aus
  truncnorm 1.0-9 (Olaf Mersmann, Heike Trautmann, Detlef Steuer, Björn
  Bornkamp; GPL (>= 2)) als `.truncnorm_rtruncnorm()`
  (`R/vendor_truncnorm.R`, `src/vendor_truncnorm.c`). gosolnp setzt wie
  im Original den globalen Zufallszustand mit
  `set.seed(as.numeric(Sys.time()))`. Die Ergebnisse sind bitgleich zu
  den Paketen (alle 173 Referenzfälle des Moduls `rugarch` unverändert,
  einschließlich der gosolnp-Fälle mit fester Uhr). Sichtbare Änderung für
  Nutzer ohne rugarch: `bootstrap()` mit den Verfahren `"garch"` und
  `"gjr_garch"` (auch die Kopplung weiterer Reihen), `dcc_fit()` und
  `dependence_analysis()` schätzen die GARCH-Stufe jetzt per rugarch
  (`method = "rugarch"` in der Meldung bzw. in `dcc_fit()$garch`) statt
  per `optim` (Nelder-Mead); andere Parameter und damit andere Pfade bzw.
  Korrelationen. `optim` und die Momente bleiben der Rückfall, wenn der
  Fit mit einem Fehler scheitert. Bei weniger als 100 Beobachtungen
  erscheint die Warnung von rugarch („ugarchfit-->waring: using less than
  100 data points for estimation“). Referenzfälle `bootstrap/fit_garch`,
  `fit_gjr`, `fit_garch_short`, `bs_garch`, `bs_gjr_garch`,
  `bs_garch_joint`, `bs_garch_regime_eu`, `bs_garch_single`,
  `bs_cross_const`, `aux_level_garch` und `dependence/dcc_fit2`,
  `dcc_fit3`, `da_basic`, `da_breaks`, `da_day` neu erzeugt.
* Numerische Ableitungen (Richardson-Extrapolation) eigenständig
  implementiert: Hesse-Matrix und Scores in `.makefitmodel` rechnen
  `.sl_richardson_hessian()` und `.sl_richardson_jacobian()`
  (`R/richardson.R`) statt der Funktionen von numDeriv; die Ergebnisse
  sind gegen numDeriv geprüft und bitgleich (alle 173 Referenzfälle des
  Moduls `rugarch` unverändert).
* Referenzfälle: Das Feld `suggests` (welche optionalen Pakete R beim
  Erzeugen installiert hatte) entfällt in allen Fällen und in
  `golden/modules/ref_tools.R`; Python und Julia brauchen ohne nachgebildete
  optionale Pakete keinen Schalter mehr (`SIMLEV_R_SUGGESTS` entfällt).
  Inhaltlich sind die Fälle unverändert.

### Ohne Rcpp

* Die C++-Kerne sind jetzt über R's eigene C-Schnittstelle angebunden
  (`.Call`, Registrierung in `src/init.c`, `GetRNGstate`/`PutRNGstate`;
  Hilfen in `src/simlev_capi.h`) statt über Rcpp. `Imports` und `LinkingTo`
  enthalten damit keine Drittpakete mehr; zum Bauen genügen R und ein C-
  und C++-Compiler. `RcppExports.R`/`RcppExports.cpp` entfallen, die
  `.Call`-Hüllen stehen in `R/cores.R`.
* Ergebnisse, Ausgaben, Warnungen, Fehlermeldungen und der Zufallszustand
  (`.Random.seed`, auch nach Fehlern) sind unverändert; alle Referenzfälle
  sind bitgleich. Fehler aus den Kernen sind jetzt Bedingungen der Klasse
  `simpleError` (bisher `Rcpp::exception` bzw. `C++Error`), Text und
  (leerer) Aufruf wie bisher.
* Interne Hüllen der Engine-Kerne mit Punkt und ohne Rcpp-Bezug, z. B.
  `.sim_buy_cpp()` statt `perform_trade_buy_cpp()`, `.sim_p20_tax_cpp()`
  statt `p20_tax_rcpp()`, `.sim_market_update_batch_cpp()` statt
  `batch_market_update()`.

### MS-GARCH ohne MSGARCH

* Die Verfahren `"ms_garch"`, `"ms_ar_garch_m"` und `"tvtp_ms_garch"` von
  `bootstrap()` und `bootstrap_study()` brauchen das Paket MSGARCH nicht
  mehr; es ist aus den `Suggests` gestrichen. SimLev schätzt das
  MS-GARCH-Modell selbst per Maximum Likelihood nach Haas, Mittnik und
  Paolella (2004): Normalverteilung, je Regime ein Varianzpfad `"sGARCH"`
  oder `"gjrGARCH"`, die Pfade aller Regime laufen parallel; Likelihood
  über den Hamilton-Filter (neuer C-Kern `src/ms_garch.c`), Maximierung mit
  `optim()` (BFGS) aus deterministischen Startwerten (Baum-Welch-EM des
  Gauß'schen HMM und Rangeinteilung der rollierenden Volatilität, je mit
  kleinem Raster für α, γ, β und die Übergangsmatrix), Regime aufsteigend
  nach unbedingter Varianz, Regimepfad per Viterbi. Die Schätzung zieht
  keine Zufallszahlen.
* Die Schätzwerte und damit die Pfade weichen von MSGARCH-Schätzungen ab
  (eigene Startwerte, Parametrisierung und Startvarianz).
* Als Varianzmodell je Regime (`ms_garch_model`, `ms_ar_garch_model`,
  `tvtp_garch_model`) sind nur noch `"sGARCH"` und `"gjrGARCH"` erlaubt,
  als Regimezahl ganze Zahlen ab 2; andere Werte sind ein Fehler mit
  deutscher Meldung.

### Parallelität gebündelt

* Mit `cores > 1` verteilt R die Arbeit unter Unix jetzt gebündelt: die
  Einheiten (Pfade, Chunks, Parameterkombinationen, Startdaten, Hebel) von
  `bootstrap()`, `bootstrap_study()`, `param_search()`,
  `sensitivity_grid()`, `sensitivity_rebalancing()`,
  `planning_lumpsum_vs_dca()` und `sensitivity_leverage()` (auch über
  `param_bootstrap()` und `overfit_walk_forward()`) gehen in höchstens
  `4 × cores` Pakete aufeinanderfolgender Einheiten, ein Fork je Paket statt
  je Einheit. Bei vielen kleinen Einheiten entfällt damit der größte Teil
  des Aufwands für die Forks (`bootstrap()` mit 400 Pfaden, `cores = 2`:
  2,18 s → 0,21 s; mit `cores = 1` 0,08 s, der Rest ist vor allem die
  Rückgabe der Pfade an den Elternprozess; `tools/bench/ergebnis_2026-10-26_rpar.csv`).
* Ergebnisse sind unverändert: jede Einheit startet wie bisher mit dem
  Zufallszustand des Aufrufers, der danach unverändert ist; Fehler einer
  Einheit ergeben dasselbe `try-error`-Element und dieselbe Warnung
  „k function calls resulted in an error“ wie bisher. Alle Referenzfälle
  sind bitgleich.
* Ausgaben und Meldungen der Einheiten werden wie bisher nicht eingefangen;
  innerhalb eines Pakets erscheinen sie jetzt in Einheitenreihenfolge
  (bisher in der Reihenfolge der Fertigstellung).
* Stürzt ein Kindprozess ab, sind alle Einheiten seines Pakets `NULL`
  (bisher nur die eine Einheit); die Warnung von `mclapply` zählt dann
  Pakete.
* Unverändert bleiben: ein Fork je Einheit mit der Normalverteilung
  `"Box-Muller"` oder einem eigenen Generator (`"user-supplied"`), deren
  Zustand nicht nur in `.Random.seed` liegt; `lapply` bei `cores < 2` oder
  einer Einheit; unter Windows der PSOCK-Cluster.

## SimLev 0.4.0

* Taktische Allokation: `tactical_rules()`, `tactical_rotation()` (Momentum,
  Dual Momentum, Canary- und Breitenschutz), `target_volatility()`,
  `glidepath()`, `blend_weights()`, `signal_state()`, `momentum_score()`;
  `tactical_simulation()` führt Zielgewichte über `event_col`/`event_weight`
  der unveränderten Engine aus.
* Optimierung: `portfolio_optimize()` (Minimum-Varianz, Mean-Variance,
  maximale Sharpe Ratio, maximale Diversifikation, Risikoparität mit
  Budgets, HRP, minimaler CVaR, inverse Volatilität, gleich; Grenzen,
  Ledoit-Wolf, Michaud-Resampling), `efficient_frontier()`,
  `rolling_optimization()`, `risk_contributions()`.
* Reihen: `bond_index_from_yields()`, `money_market_index()`,
  `currency_hedged_index()`.

## SimLev 0.3.0

* Tutorial (`inst/tutorial/SimLev_Tutorial.Rmd`).
* Auswertung: `deep_analysis()` (TWR und MWRR, Risiko, VaR/CVaR,
  Benchmark-Kennzahlen, Monats- und Jahrestabellen, Drawdown-Episoden,
  rollierende Kennzahlen).
* Sensitivitäten: `sensitivity_grid()`, `rebalancing_sensitivity()`,
  `lumpsum_vs_dca()`, `leveraged_series()`, `leverage_sensitivity()`.
* Engine: `simulation(balance_thresh_type = "relative")` (relative
  Rebalancing-Bänder; Standard unverändert).
* Signal-Bausteine: `signal_sma()`, `signal_ema()`, `signal_crossover()`,
  `signal_momentum()`, `signal_drawdown()`, `signal_volatility()`,
  `signal_combine()`.
* Parametersuche: `param_space()`, `param_range()`, `param_search()`
  (Raster, Zufall, Latin Hypercube), `plateau()`.
* Überanpassung: `pbo()`, `deflated_sharpe()`, `probabilistic_sharpe()`,
  `walk_forward()`, `param_bootstrap()`.
* Daten: `align_series()`, `check_series()`, `align_macro()`,
  `convert_currency()`, `total_return_index()`, `deflate()`,
  `splice_series()`, `strategy_from_weights()`, `portfolio_template()`,
  `portfolio_templates()`.
* Abhängigkeiten: `dependence_analysis()`, `fit_copula()`,
  `tail_dependence()`, `dcc_fit()` (DCC(1,1) in C++), `quantile_reg()`,
  `tail_regression()`, `covar_analysis()`, `validate_dependence()`,
  `regime_subset()`.

## SimLev 0.2.0

* Backcast: `backcast_fit()`, `backcast()` – Rückrechnung von ETF/ETP-
  Historien aus Basisindex, Kosten, Hebel und Finanzierungszins.
* Bootstrap: `bootstrap_config()` (Alias `create_config()`),
  `bootstrap()`, `bootstrap_data()`, `validate_bootstrap()`,
  `block_length()`, `bootstrap_study()`, `bootstrap_probability()`,
  `study_metrics()`; Kerne in C++.
* Entnahmephase: `withdrawal_rule()` (14 Regeln),
  `withdrawal_simulation()`, `withdrawal_cohorts()`, `withdrawal_paths()`,
  `withdrawal_max_rate()`, `perfect_withdrawal_rate()`, `result_index()`;
  Kern in C++.

## SimLev 0.1.0

Erste Fassung (zugleich Python und Julia 0.1.0):

* Engine `simulation()`: Buy-and-Hold und Signalstrategien, Sparpläne,
  kalender-, schwellen- und ereignisbasiertes Rebalancing, Splits,
  Bid-Ask-Spreads, laufende Fondskosten; deutsche Besteuerung mit
  Vorabpauschale, Teilfreistellung, Sparer-Pauschbetrag, Verlusttöpfen nach
  § 20 und § 23 EStG und Günstigerprüfung.
* Strategien: `asset_config()`, `create_strategy()`,
  `validate_strategy()`, `add_asset()`, `update_asset()`,
  `remove_asset()`, `migrate_strategy()`, `as_list()`.
* `compute_rebal_trigger()` für ereignisbasiertes Rebalancing.
* Ausgabe: `print`, `summary` und `plot` für Ergebnisse,
  `export_dashboard()`, `export_html_dashboard()`, `plot_interactive()`.
