# Testkatalog von SimLev

Alle Tests des Repositorys liegen in diesem Ordner, **nach Zweck gegliedert** (seit SimLev 1.4.2). Sie laufen gegen die
gebauten bzw. installierten Pakete unter `r/`, `python/` und `julia/`; die Pakete selbst brauchen `tests/` nicht (Bauen,
Installieren, `R CMD check`, `pip wheel`, `Pkg.build`/`using` laufen ohne diesen Ordner).

```
tests/
  run.sh, run.R, run.jl, conftest.py, pytest.ini   Einstiege (je Sprache einer für alle Gruppen)
  methodik/       Rechnet SimLev richtig? Steuerrecht, Tarif, Engine, Entnahme (FIFO), Kennzahlen, C-Bibliothek (R)
  gleichlauf/     Rechnen Python und Julia wie R? Szenarien und Tabellen (faelle/), ihre Generatoren (erzeugen/)
  fehler/         Richtige Meldung bei falscher Eingabe, NA und Grenzfällen (faelle/; dazu R-eigene Prüfungen)
  ausgabe/        print, summary, Grafik (faelle/; R-Basisgrafik, SVG in Python und Julia)
  schnittstelle/  Bleibt die öffentliche API stabil? (eingefrorener Stand frozen/, Abgleich der drei Sprachen)
  werkzeuge/      keine Tests: Gleichlauf-Lauf mit Zufalls- und Breitenprüfungen (gleichlauf/, zufall/, breite/), Laufzeit (bench/),
                  Doku-Prüfungen (doku/), Neuerzeugen (erzeugen.sh)
  lib/            gemeinsame Hilfen der Python- und Julia-Tests (Lesen und Vergleich der Referenzfälle; Python: faelle.py, reftree.py)
```

## Befehle

Aus der Repo-Wurzel, mit `LC_ALL=C.UTF-8` (die Referenzen entstanden unter C.UTF-8):

| Was | Befehl | Laufzeit |
|---|---|---|
| alles | `tests/run.sh` (Sprachen `r python julia`, Gruppen wählbar, z. B. `tests/run.sh python fehler`; `--bauen` baut vorher) | rund 8 min |
| R | `R_LIBS=<Bibliothek mit SimLev> Rscript tests/run.R [methodik fehler ausgabe schnittstelle]` | 15 s |
| Python | `python3 -m pytest tests` bzw. `tests/<gruppe>` (C-Erweiterung an Ort und Stelle gebaut oder `simlev` installiert) | 51 s |
| Julia | `julia --project=julia tests/run.jl [gleichlauf fehler ausgabe schnittstelle]` (nach `Pkg.build()`) | 7 min (Übersetzen je Aufruf) |
| Schnittstelle (drei Sprachen) | `tests/schnittstelle/run.sh --check` (`--freeze` nur mit Eintrag in `tests/schnittstelle/CHANGES.md`) | 1 min |
| Gleichlauf-Lauf | `tests/werkzeuge/gleichlauf/run.sh --quick` bzw. `--full` (baut selbst; `--no-build`) | 8 bzw. 40 min |
| Fälle neu erzeugen | `R_LIBS=<…> tests/werkzeuge/erzeugen.sh [bereich …]` | 32 s |
| Laufzeitmessung | `R_LIBS=<…> tests/werkzeuge/bench/run.sh` | siehe `werkzeuge/bench/README.md` |

Voraussetzungen: R mit `testthat` und `jsonlite`; Python mit `pytest`, `numpy`, `pandas`; Julia 1.10 oder neuer
(`Test`, `Logging`, `Zlib_jll` sind Standardbibliotheken). Die Bitgleichheit setzt Linux auf x86-64 voraus.
Umgebung: `SIMLEV_FAELLE_DIR` (anderer Ordner der Referenzfälle, darin `<gruppe>/<bereich>.jsonl.gz`),
`SIMLEV_LAX_NA=1` (NA = NaN), `SIMLEV_STRICT_ZERO=0` (−0 = +0).

Je Sprache läuft jede Gruppe, wo das sinnvoll ist: `methodik` nur in R (Handrechnungen und Gesetzesbeispiele gegen die
R-Fassung; Python und Julia sind über die Szenarien von `gleichlauf` an R gebunden, die dieselben Steuer-, Tarif- und
Engine-Wege rechnen), `gleichlauf`, `fehler`, `ausgabe` mit R als Herkunft der Erwartung in Python und Julia (R prüft
sie, indem `werkzeuge/erzeugen.sh` sie Byte für Byte gleich neu erzeugt), `schnittstelle` in allen drei.

Laufzeit je Gruppe (1.4.2, einzeln aufgerufen, Sekunden; R je Gruppe und Julia je Gruppe aus früheren Messungen auf
demselben Rechner, Julia übersetzt je Aufruf neu):

| Gruppe | R | Python | Julia |
|---|---|---|---|
| methodik | 5 | – | – |
| gleichlauf | (Neuerzeugen 32 für alle Bereiche) | 5 | rund 250 |
| fehler | 2 | 35 | rund 190 |
| ausgabe | 5 | 10 | rund 75 |
| schnittstelle | 2 | 0,5 | rund 9 |
| **gesamt** | 15 | 51 | 441 |

## Referenzfälle: Szenarien und Tabellen

Die Dateien `tests/<gruppe>/faelle/<bereich>.jsonl.gz` (Gruppen gleichlauf, fehler, ausgabe) entstehen aus R mit den
Generatoren `tests/gleichlauf/erzeugen/<bereich>.R` (nie von Hand angepasst; Format in `erzeugen/ref_tools.R`, Szenarien
und Tabellen der Bereiche in `erzeugen/szenario_tools.R`). Ein Test ist

- ein **Szenario**: ein Aufruf bzw. eine kurze Aufrufkette mit sprechendem Namen und einer Zeile „prüft: …“, die
  mehrere Ergebnisse zugleich prüft. Bereich engine: je ein `simulation()`-Lauf mit Ergebnis, Druck, `summary()` samt
  Druck, details-Ausgabe und Warnungen. Übrige Bereiche: die Teile eines Themas (z. B. alle Entnahmeregeln, eine
  Bootstrap-Studie mit summary und ess) in einem Test; Ergebnis ist die benannte Liste der Teile, dazu `druck_<teil>`
  für Objekte mit print-Methode. Ein Teil ist ein Aufruf bzw. eine Aufrufkette (z. B. strategy_add_asset ->
  strategy_update_asset -> strategy_validate; Gleitpfad und Regeln -> tactical_blend -> tactical_simulation); sein Name
  ist die bisherige Fallkennung, bei zusammengelegten Fällen ein neuer Name. Vorstufen, die mehrere Teile brauchen
  (z. B. eine simulation(), ein bootstrap(), eine param_search() oder eine backcast_fit()), rechnet das Szenario einmal
  (`gemein`); jeder Teil rechnet in eigenem Gültigkeitsbereich (R `local`, Python Funktion, Julia `let`).
- eine **Tabelle** „Eingabe → erwarteter Wert bzw. erwartete Meldung“ je Funktion: jede Zeile ist ein eigener Aufruf in
  frischer Umgebung (ein Fehler bricht nur seine Zeile ab), Abweichungen nennen die Zeile und das Feld
  (`Zeile ti13: result$…`). Fehler- und Warnfälle (Gruppe fehler) sind immer Tabellen; in r_grundfunktionen und slc
  sind auch die Werte Tabellen je Funktion („Eingabe → Wert“; Zeilen = Fälle aus `erzeugen/auswahl.txt`).

Python und Julia rechnen jeden Test nach und müssen Bit für Bit gleich sein (NA und NaN getrennt, Vorzeichen der Null,
Konsolen- und Druckausgabe, Warnungen, Fehlermeldung). Lange Daten sind auf den kürzesten Ausschnitt gekürzt, der die
Zeilenabdeckung hält (im Generator markiert mit `# bis 1.4.1 …`). Die bisherigen Einzelfälle der Bereiche (bis 1.4.1 hier
erzeugt) prüft als Breitenprüfung nur noch der Gleichlauf-Lauf (`tests/werkzeuge/breite/<bereich>.R`, nichts abgelegt).
Die Grafiktests finden die Objekte über `lib/faelle.fall("<modul>/<Kennung>")` (Tabellenzeile oder Teil).

### gleichlauf (Rechnen Python und Julia wie R?)

| Test (Datei `gleichlauf/faelle/…`) | Zweck | geprüfte Ergebnisse | Tests (Szenarien / Tabellen, Zeilen) | Größe |
|---|---|---|---|---|
| `engine` | `simulation()` mit allen Bausteinen (Liste unten) | Ergebnisbaum, print, summary(), details, Warnungen | 26 Szenarien | 833 KB |
| `bootstrap` | Bootstrap der Pfade und Studien (auch `cores = 2`) | Ergebnisse der Teile, print | 11 Szenarien (37 Teile) | 317 KB |
| `daten` | Datenaufbereitung, Portfolio-Vorlagen, Rückrechnung, Signale | Ergebnisse der Teile, print | 14 Szenarien (60 Teile) | 713 KB |
| `entnahme` | Entnahmephase: Regeln, Kohorten, Steuer, FIFO-Übernahme | Ergebnisse der Teile, print | 9 Szenarien (44 Teile) | 170 KB |
| `forschung` | Parametersuche, Overfitting-Diagnosen, Sensitivität | Ergebnisse der Teile, print | 11 Szenarien (41 Teile) | 191 KB |
| `modelle` | Regime, Abhängigkeit (Copulas, DCC, Quantilsregression, CoVaR) | Ergebnisse der Teile, print | 6 Szenarien (20 Teile) | 278 KB |
| `optimierung` | Portfolio-Optimierung | Ergebnisse der Teile, print | 5 Szenarien (19 Teile) | 97 KB |
| `planung` | Planung, Szenarien, taktische Allokation | Ergebnisse der Teile, print | 10 Szenarien (35 Teile) | 430 KB |
| `r_grundfunktionen` | nachgebaute R-Interna: Formatierung, NA/NaN, Statistik, Ausdrücke (je Funktion) | Wert | 51 Tabellen, 263 Zeilen | 26 KB |
| `slc` | C-Bibliothek: Zufall, Verteilungen, lineare Algebra, Optimierer, Modelle (je Funktion) | Wert | 37 Tabellen, 55 Zeilen | 381 KB |
| `statistik` | statistische Tests, Tiefenanalyse | Ergebnisse der Teile, print | 6 Szenarien (21 Teile) | 296 KB |
| `wrapper` | Fonds-Wrapper | Ergebnisse der Teile, print | 6 Szenarien (13 Teile) | 84 KB |
| **zusammen** | Herkunft der Erwartung: R | | **192 Tests (104 Szenarien, 88 Tabellen mit 318 Zeilen)** | 3.7 MB |

Szenarien des Bereichs engine (Generator `erzeugen/engine.R`; Daten der letzten 13 aus den Zufallsgeneratoren
`werkzeuge/zufall/engine_*.R`, auf den kürzesten Ausschnitt mit voller Abdeckung gekürzt):

| Szenario | prüft |
|---|---|
| `tarif_steuerschuld_negativer_endwert` | Tarif (zvE 74 000), Steuer aus der Veranlagung größer als das Depot, negativer Endwert, details |
| `grenzsteuersatz_sparplan_ohne_zinsfuss` | § 23-Steuer größer als Cash, nicht positiver TWR-Index, Sparplan ohne internen Zinsfuß |
| `guenstigerpruefung_zve_null` | Günstigerprüfung mit Tarif bei zvE 0, Ereignis-Umschichtung (skip), details |
| `tarif_zve_tabelle_spitzensteuersatz` | zvE als data.frame mit freien Spaltennamen, Spitzensteuersatz im Folgejahr, § 23 |
| `freibetrag_mit_verlusttopf` | Freibetrag nutzen (harvest) mit Verlusttopf, Ereignis-Umschichtung, details |
| `spaeter_start_mit_sparplan` | Asset mit NA am Anfang (series_align range = all), Sparplan, summary() |
| `datum_text_und_kursluecke` | Datum als Text (JJJJ-MM-TT) und Kurslücke (LOCF, Attribut filled) |
| `privatverkauf_freigrenze_sparplan` | § 23 mit Freigrenze 600, Pauschbetrag 801, Grenzsteuersatz 24, Sparplan an zwei Monatstagen (Anker Ende), liquidate, details |
| `liquidieren_gebuehr_ueber_erloes` | liquidate: Position bleibt stehen, weil die Ordergebühr den Erlös übersteigt (Warnung) |
| `ereignis_gewicht_unvollstaendig` | event_weight nennt nicht alle Assets (Warnung), event_mode replace |
| `filled_nach_zeilenauswahl` | Attribut filled nach Zeilenauswahl einer series_align()-Tabelle (Warnung), Ergebnis und Druck |
| `privatverkauf_ohne_grenzsteuersatz` | § 23 ohne Grenzsteuersatz (zwei Warnungen), Basiszins, prozentuale Ordergebühr, ganze Stücke, liquidate |
| `eigener_tarif_mit_sprung` | eigene Tarifdatei mit Sprung an der Zonengrenze (Warnung), zvE 300 000, Freibetrag ohne Verlusttopf |
| `strategie_als_liste` | Strategie als einfache Liste (ohne asset_config), liquidate |
| `vorabpauschale_letzter_tag` | Vorabpauschale am letzten Datentag, Umschichten, details |
| `details_quartal_schwelle_sparplan` | details mit Quartals-Umschichtung (Schwelle 2), Sparplan, Basiszins als Spalte, liquidate |
| `details_guenstigerpruefung_ohne_erstattung` | Günstigerprüfung ohne Erstattung (Grenzsteuersatz 35), details |
| `start_auf_wochenende` | später startende Assets mit Start auf einem Tag ohne Kurs (nur Werktage), details, liquidate |
| `privatverkauf_sparplan_tag_29` | § 23 mit Freigrenze 600, Sparplan am 29. (Februar), monatliches Umschichten, details |
| `signale_als_zahlen` | Signalspalten numerisch 0/1, Quartals-Umschichtung, liquidate |
| `signal_etf_split_negativer_basiszins` | Signal-ETF allein mit Split-Regel, jährlichem Umschichten und negativem Basiszins |
| `fallende_hebelreihe_ganze_stuecke` | fallende Hebelreihe mit ganzen Stücken, Startwert 500 EUR, Sparplan mit Umschichten (balance_dca) |
| `mehrere_signale_details` | mehrere Signal-Assets, Grenzsteuersatz 14, details |
| `winziger_startwert` | Startwert 0,01 EUR über 500 Tage, Umschichten, liquidate |
| `daten_unsortiert` | Daten nicht nach Datum sortiert |
| `spaeter_start_splits_signal_cash` | später startende Assets mit Splits vor dem Start (ohne Bestand), Reverse-Split im Bestand, Signal-Asset hält Cash, Ereignis-Umschichtung, details |

Szenarien der übrigen Bereiche (seit 1.4.2; Teil = Aufruf bzw. Aufrufkette):

**wrapper** (Generator `erzeugen/wrapper.R`)

| Szenario | prüft | Teile |
|---|---|---|
| `wrapper/fondsanteil_kalender_und_reihenfolge` | wrapper_nav: Gebühren über die Kalendertage bei Kursen nur an Werktagen (Verwaltungs- und Performancegebühr, inneres Umschichten je Quartal); unsortierte Daten | 2 |
| `wrapper/wrapper_in_simulation` | simulation() mit Wrapper-Assets: details-Protokoll (result$wrappers); ein Lauf mit Splits innen und beim direkten Asset (nicht beim Anteilswert), ganzen Stücken und NA in der Basiszins-Spalte (zählt als 0) | 2 |
| `wrapper/wrapper_in_aufrufern` | offene Bestände des Wrapper-Assets in die Entnahme, param_search mit Builder, der den Wrapper baut, Einmalanlage gegen Sparplan mit dem Anteilswert als Kurs | 3 |
| `wrapper/wrapper_konfiguration` | wrapper_config mit Liste statt Strategie und allen Feldern, mit Ereignis-Umschichtung, asset_config mit Wrapper (Ergebnis und Druck), Hinweis bei innerem Spread | 4 |
| `wrapper/strategie_mit_wrapper_bearbeiten` | Kette strategy_add_asset (Wrapper mit Signal-Asset innen) -> strategy_update_asset (Anlageklasse und Spread) -> strategy_validate mit Daten; Ergebnis und Druck der Strategie | 1 |
| `wrapper/umschicht_ausloeser` | rebalance_trigger combined aus abs_leverage (Referenz = erster nicht fehlender Wert, NA löst nicht aus), rel_leverage und vol_band | 1 |

**bootstrap** (Generator `erzeugen/bootstrap.R`)

| Szenario | prüft | Teile |
|---|---|---|
| `bootstrap/konfiguration_hilfsreihen` | bootstrap_config mit leerem aux_type und eine alte Konfiguration ohne aux_type (Pfade mit Hilfsreihe) | 2 |
| `bootstrap/blocklaenge_schaetzen` | bootstrap_block_length für quadrierte Renditen, Matrix, kurze, konstante und trendbehaftete Reihe | 5 |
| `bootstrap/zwei_maerkte_mit_hebel_und_zins` | bootstrap() mit zwei Märkten, Regime-Index, Zinsreihe und Hebel-ETFs: Rücksetzen, circular (Blocklänge 25, Pfadlänge 600), evt mit beiden Rändern, block mit automatischer Blocklänge | 4 |
| `bootstrap/regimewechsel_modelle` | bootstrap() mit MS-GARCH: AR-Anteil, drei Regime, zeitvariable Übergänge (TVTP) mit drei Regimen | 3 |
| `bootstrap/hilfsreihen_als_niveau` | Hilfsreihen als Niveau (CPI, Zins, Inflation) bei evt und garch | 2 |
| `bootstrap/sonderfaelle_der_daten` | Knock-out des Hebel-ETF, Matrix statt Tabelle, seed = NULL (Zufallsstrom aus simlev_seed) | 3 |
| `bootstrap/effektive_stichprobe` | ess = TRUE bei block, wild, regime (Gitter), tails (Druck), raw und stationary; unendliche Blocklänge | 7 |
| `bootstrap/interne_hilfen` | .ess_design, .calculate_ess und der Haupt-Zufallsstrom (Zustand nach simlev_seed) | 3 |
| `bootstrap/studie_mit_kennzahlen` | Kette bootstrap_study (Hebel-ETF, Zinsreihe, Signalstrategie mit NA-Signalen nach der Einschwingzeit; einmal gerechnet) -> summary() mit Kennzahlen und Quantilen; ess mit summary und bootstrap_probability; bootstrap_study_metrics einer Simulation | 4 |
| `bootstrap/studie_in_teilen` | bootstrap_study mit chunk_dir (löschen bzw. behalten) und Signal-Tabelle mit Argumenten | 3 |
| `bootstrap/wahrscheinlichkeiten_aus_studie` | bootstrap_probability in einem Aufruf mit Bedingungen in R-Syntax und als Skalar | 1 |

**daten** (Generator `erzeugen/daten.R`)

| Szenario | prüft | Teile |
|---|---|---|
| `data_prep/datum_umwandeln` | .to_date aus Faktor und POSIXct (Zeitzone) | 2 |
| `data_prep/reihen_ausrichten` | series_align mit max_gap, Kalender intersect bzw. union, Start und Ende, Zeilennummern statt Datum, Ganzzahlen | 6 |
| `data_prep/reihen_pruefen` | series_check: Beispiel mit negativen Werten und einer Spalte nur aus NA in einem Aufruf, Spaltenwahl, NA-Datum, Datumsfehler, nur NA, keine Spalten | 6 |
| `data_prep/makroreihen_und_deflation` | series_align_macro (diff, yoy_diff mit Verzögerung, Lücken, benannter Vektor) und series_deflate | 5 |
| `data_prep/waehrung_und_indizes` | series_convert_currency, index_total_return (voll und Einzelwert), index_bond, index_money_market, index_currency_hedged | 7 |
| `data_prep/reihen_verketten` | series_splice mit Wochenenden und Vektoren | 2 |
| `data_prep/strategie_aus_gewichten` | strategy_from_weights mit benannten Werten und Wrapper (ein Eintrag, NULL), portfolio_template | 4 |
| `backcast/hilfsfunktionen` | .resolve_series mit benannten Werten und .fill_na (linear, stine) | 4 |
| `backcast/anpassung_varianten` | backcast_fit: zeitabhängige TER, Gitter, ohne Anpassung, feste Parameter, geometrische Abgrenzung, Short-Hebel mit Verzögerung, Spline-Modell mit Währung, summary() | 8 |
| `backcast/verlustfunktionen` | backcast_fit mit den Verlustfunktionen mse, mae, median und max | 4 |
| `backcast/rueckrechnung` | Kette backcast_fit (einmal gerechnet) -> backcast auf den eigenen und auf anderen Daten; ohne Anpassung (Attribute), ohne Produktreihe, mit führenden NA im Index | 5 |
| `signals/kerne_an_den_raendern` | gleitender Mittelwert und EMA an den Rändern (Fensterlänge = n, > n, 0) | 2 |
| `signals/signale_mit_luecken` | signal_ema mit NA, signal_crossover (ema, Band, Verzögerung), signal_drawdown mit NA | 3 |
| `signals/signale_kombinieren` | signal_combine mit and (SMA, Volatilität, Momentum) und or (SMA, Drawdown) | 2 |

**entnahme** (Generator `erzeugen/entnahme.R`)

| Szenario | prüft | Teile |
|---|---|---|
| `withdrawal/regeln_voreinstellungen` | withdrawal_rule mit den Voreinstellungen aller Regeln (vanguard, floor_ceiling, clyatt, ratchet, vpw, abw, cape, sensible, hebeler, guy) und percent mit Untergrenze, je Ergebnis und Druck | 11 |
| `withdrawal/interne_hilfen` | .period_ends (Monats- und Jahresenden) und .wd_fee_set (Gebührensätze) | 2 |
| `withdrawal/horizonte` | withdrawal_horizon dreieckig (auch entartet), Stichprobe, normal mit engen Grenzen und Walker-Ziehung | 5 |
| `withdrawal/simulation_regeln_und_risikoaversion` | withdrawal_simulation mit constant, ratchet, percent (gamma 1, Pfade behalten) und sensible (gamma 0), Grafikdaten mit zwei behaltenen Pfaden | 5 |
| `withdrawal/simulation_frequenz_inflation_horizont` | withdrawal_simulation monatlich mit CAPE-Kohorten, Inflation als Matrix bzw. NULL, fester und zufälliger Horizont (monatlich mit Steuer) | 5 |
| `withdrawal/simulation_mit_einkommen_und_steuer` | Einkommen in einzelnen Jahren; Kette simulation() (einmal gerechnet) -> withdrawal_simulation bzw. result_index (Index alter Form); Startwert mit Steuertabelle (Günstigerprüfung), monatliche Steuer mit Erstattung | 5 |
| `withdrawal/hoechste_entnahmerate` | withdrawal_max_rate mit Tarif, ohne Lösung (NA) und an der oberen Grenze | 3 |
| `withdrawal/pfade_und_kohorten_aus_bootstrap` | Kette bootstrap() (Hilfsreihen als Niveau bzw. Rate, einmal gerechnet) -> withdrawal_paths mit CPI-Niveau, CAPE, Werktagen, wild ohne Attribut bzw. bootstrap_data -> withdrawal_cohorts; withdrawal_perfect_rate | 6 |
| `withdrawal/fifo_aus_der_ansparphase` | Lots der Ansparphase in die Entnahme (FIFO): Sparerpauschbetrag im Folgejahr und Liquidation | 2 |

**forschung** (Generator `erzeugen/forschung.R`)

| Szenario | prüft | Teile |
|---|---|---|
| `param_search/suchraum_und_versuchsplan` | param_space mit langer Reihe und Schrittweite, Latin Hypercube (log, ganzzahlig), diskreter Plan, Stufen, .as_spec | 5 |
| `param_search/suche_raster_und_zufall` | param_search als Raster und Zufallssuche (Grafikdaten), Liste als Suchraum, ohne Renditen, mit Spezifikation | 5 |
| `param_search/suche_mit_signalen` | param_search mit Signal-Tabelle und Signalfunktion mit NA, Plateau aus Ergebnissen, cores = 2 mit Fehler in einem Lauf | 4 |
| `param_search/plateau_auswahl` | Plateau bei Zufallssuche mit einem Parameter und bei Text-Parametern (Sortierung) | 2 |
| `overfitting/renditen_und_kennzahlen` | .of_returns mit NA (Wochen) und Vektor (Monate), .of_col_metric für sharpe, sortino, geometric, mean | 3 |
| `overfitting/pbo_und_bootstrap_pruefung` | overfit_pbo mit Sharpe; Kette param_search (einmal gerechnet) -> overfit_pbo, sharpe_deflated, sharpe_haircut, overfit_walk_forward bzw. param_bootstrap realer Strategien (Kennungen, cores = 2) | 4 |
| `overfitting/sharpe_korrekturen` | sharpe_probabilistic, sharpe_deflated (mehrere und eine Strategie), sharpe_haircut mit Attributen | 4 |
| `overfitting/walk_forward` | overfit_walk_forward mit bestem Punkt und mit Plateau-Auswahl | 2 |
| `sensitivity/gitter` | sensitivity_grid mit Tabelle als Gitter (Splits), keep, Pfaden in tax (church_tax, income.marginal_rate, harvest.day) | 4 |
| `sensitivity/umschichten` | sensitivity_rebalancing mit Bändern, relativ und mit Sparplan; planning_lumpsum_vs_dca mit Umschichten | 4 |
| `sensitivity/hebel` | series_leverage mit Knock-out, sensitivity_leverage mit Strategie, mit Spread und ohne passende Strategie | 4 |

**modelle** (Generator `erzeugen/modelle.R`)

| Szenario | prüft | Teile |
|---|---|---|
| `regimes/hmm_wochen` | regime_hmm mit zwei Regimen auf Wochenrenditen (Ergebnis, Druck, Grafikdaten) | 1 |
| `dependence/kendall_und_copulas` | .kendall_tau_core, .kendall mit NA, Copula-Likelihood und Tail-Abhängigkeit für t und Frank | 4 |
| `dependence/regime_einteilung` | .dep_regimes nach Quantilen (2, 5 Klassen, konstante Reihe) und nach Grenzen (auch skaliert) | 2 |
| `dependence/abhaengigkeitsanalyse` | dependence_analysis ohne Copulas, mit Bedingungen (Inflation, Regime), Grenzen, monatlich, DCC scheitert (identische Reihen); dependence_dcc mit drei Reihen | 6 |
| `dependence/quantils_und_tail_regression` | quantile_regression (mit und ohne Regressor), tail_regression (eine und zwei Bedingungen, monatlich mit NA), tail_covar | 4 |
| `dependence/teilmengen_nach_bedingung` | Bootstrap mit Abhängigkeit (valdep), regime_subset nach Datum und mit Bedingungen in R-Syntax | 3 |

**optimierung** (Generator `erzeugen/optimierung.R`)

| Szenario | prüft | Teile |
|---|---|---|
| `optimize/kerne_und_hilfen` | .min_cvar_core, .opt_cov gerber bei flachen Reihen, .cvar_hist und .cdar_hist | 3 |
| `optimize/verfahren_vier_anlagen` | portfolio_optimize auf vier Anlagen: min_variance (Grafikdaten), mean_variance, max_diversification, min_cdar, Risikoparität mit Teilbudget | 5 |
| `optimize/sonderfaelle_optimierung` | Risikoparität mit Resampling, eine Anlage (hrp), Tabelle mit Tagesrenditen (min_cvar) | 3 |
| `optimize/effizienzlinie_und_risikobeitraege` | portfolio_frontier; portfolio_risk_contributions mit CVaR, mit Optimierungsergebnis (Ledoit-Wolf), EWMA und Matrix ohne Namen | 5 |
| `optimize/rollierend_und_cpcv` | portfolio_rolling (max_sharpe, Quartale, Obergrenzen), portfolio_cpcv mit drei Verfahren und mit Tagesdaten | 3 |

**planung** (Generator `erzeugen/planung.R`)

| Szenario | prüft | Teile |
|---|---|---|
| `planning/verschobene_renditen` | series_shift_return mit benannter Verschiebung, Kursen unsortiert, ohne Datum | 3 |
| `planning/gepoolter_bootstrap` | bootstrap_pooled Standard, unbenannte Gewichte, Ziel (unbenannt und benannt) | 4 |
| `planning/portfoliorenditen` | portfolio_returns je Quartal und monatlich mit Gold | 2 |
| `planning/zielplanung` | planning_goal mit Beispiel (Grafikdaten), Matrix ohne Namen und Tabelle | 3 |
| `scenarios/entropy_pooling` | scenario_entropy_pooling mit Volatilitäts- und Mittelwert-Sicht, Prior, Matrix, Wahrscheinlichkeits-Sicht in R-Syntax; scenario_risk | 5 |
| `scenarios/copula_szenarien` | scenario_copula gaussian mit Stress, Stress auf zwei Reihen, Tabelle mit nicht positiv definiter Korrelation | 3 |
| `scenarios/krisen` | scenario_crisis mit eigener Krisentabelle (Umschichten) und Datum als Text | 2 |
| `tactical/signale_und_regeln` | signal_state ohne Signal, POSIXct-Datum, tactical_rules mit R-Syntax und NA, Hilfen .period_last | 4 |
| `tactical/rotation_und_volatilitaet` | tactical_rotation (Breite, inverse Volatilität), tactical_target_volatility mit sicherem Asset in den Gewichten, tactical_conditional_volatility fest und mit Hinweis | 5 |
| `tactical/gleitpfad_und_simulation` | tactical_glidepath mit Sprung, Gleitpfad mit Rotation (Grafikdaten), Kette Gleitpfad und Regeln -> tactical_blend -> tactical_simulation mit Toleranz, Verzögerung und Sparplan, Simulation mit gefüllten Tagen | 4 |

**statistik** (Generator `erzeugen/statistik.R`)

| Szenario | prüft | Teile |
|---|---|---|
| `analysis_tests/signalanalyse` | signal_analysis mit Klassen (Grafikdaten), Grenzen, binärem Signal, zweitem Signal (2D), unsortierten Daten | 5 |
| `analysis_tests/sharpe_tests` | sharpe_test Bootstrap ohne Startwert, identische Reihen, aus Simulationen; sharpe_min_track_record unendlich; .ret_from | 5 |
| `analysis_tests/reality_check` | overfit_reality_check mit benanntem Vergleich und mit Tabelle | 2 |
| `analysis_tests/heatmap` | result_heatmap auf Wochen und aus einer Simulation (Grafikdaten) | 2 |
| `deep_analysis/tiefenanalyse_simulation` | result_analysis aus Simulationen mit Vergleich und Inflation, ohne filled | 2 |
| `deep_analysis/tiefenanalyse_tabellen` | result_analysis mit CPI-Vektor, unsauberen Daten, kurzen Reihen, nur sich selbst als Vergleich, ausgerichteter Tabelle (Grafikdaten) | 5 |

### fehler (Richtige Meldung bei falscher Eingabe, NA und Grenzfällen?)

| Test | Zweck | geprüfte Ergebnisse | Tests (Tabellen, Zeilen) | Herkunft |
|---|---|---|---|---|
| `fehler/faelle/engine` | je Funktion eine Tabelle: simulation, asset_config, sim_costs, dca_plan, rebalance_plan, split_rule, tax_profile, income_rate, income_tariff, harvest_rule, funds_costs, tax_tariff | Meldungstext bzw. Wert mit Warnung je Zeile | 12, 93 | R |
| `fehler/faelle/<bereich>` (11 weitere Bereiche) | Eingabeprüfungen, Warnungen und Grenzfälle je Modul und Funktion (Zeilenname = bisherige Kennung) | Meldungstext bzw. Wert mit Warnung je Zeile | 139, 635 | R |
| `fehler/test-pruefungen.R` | Prüfungen und Wege, die die Tabellen nicht erreichen (u. a. `conditionCall`, R-eigen) | R-Bedingungen | 22 Tests (R) | R-Verhalten |
| **zusammen** | | | **151 Tabellen mit 728 Zeilen + 22 R-Tests** | |

### ausgabe (print, summary, Grafik)

| Test | Zweck | geprüfte Ergebnisse | Tests | Herkunft |
|---|---|---|---|---|
| `ausgabe/faelle/engine` | Druck der Bausteine und von asset_config() | Wert und print je Zeile | 1 Tabelle, 9 Zeilen | R |
| `ausgabe/faelle/{daten,statistik,wrapper}` | print/summary als letzter Aufruf | print | 3 Tabellen, 3 Zeilen | R |
| `ausgabe/test-grafik.R` | R-Grafik (Basisgrafik: Dashboard, plot-Methoden) | Grafikaufrufe, Rückgaben | 17 Tests (R) | R-Verhalten |
| `ausgabe/test_grafik.py`, `ausgabe/grafik.jl` | SVG-Grafik und `SimLevPlot.data` (gibt es in R nicht); Objekte aus Referenzfällen (`lib/faelle.fall`) | SVG, Datenspalten | 38 (Python), 4 Testgruppen (Julia) | Werte aus den Objekten |

Alle Szenarien und Wert-Zeilen der übrigen Gruppen prüfen die Druckausgabe ohnehin mit (Feld `print`).

### methodik (Rechnet SimLev richtig?) – nur R

| Test | Zweck | geprüfte Ergebnisse | Tests | Herkunft der Erwartung |
|---|---|---|---|---|
| `methodik/test-steuer.R` | Steuerrecht (§§ 20, 23, 32a EStG, InvStG, SolZG), Tarifdatei, Anschaffungskosten aus offenen Lots | Steuer, Tarif, Soli, Kosten | 18 (51 Tabellen, 129 Zeilen) | Gesetz, Handrechnung |
| `methodik/test-engine.R` | Engine-Erweiterungen, weitere Fälle, Verlustvortrag, zuflussbereinigte Kennzahlen (CAGR als XIRR, TTWROR) | Ergebnisfelder, Steuerbericht | 55 (117 Tabellen, 359 Zeilen) | Handrechnung, Formel |
| `methodik/test-entnahme.R` | Entnahme mit Lots der Ansparphase (FIFO), Planung/Entnahme | Steuer je Entnahme, Planwerte | 19 (68 Tabellen, 139 Zeilen) | Handrechnung |
| `methodik/test-slc.R` | C-Bibliothek gegen Testvektoren (SplitMix64), Konstanten, R-Routinen, analytische Lösungen | Werte, Meldungen | 4 (33 Tabellen, 114 Zeilen) | Testvektoren, Formel |

Die Ports sind für diese Gruppe über `gleichlauf` gesichert (dieselben Steuer-, Tarif- und Engine-Wege als Szenarien);
`methodik` bleibt daher R-only. Je Paragraph bzw. Thema (Abschnittsüberschrift mit Paragraph, sonst Testbeschreibung)
prüft eine Tabelle `tabelle("<Thema>", wert(ist, soll, quelle = …), ident(…), bed(…), pruef(…))` (`helper-tabelle.R`) die
Werte; Quelle je Zeile ist der Kommentar an der Prüfung (Rechnung, Paragraph, Formel), sonst "Handrechnung (Herleitung im
Test)". Die erwarteten Werte sind dieselben wie vor der Umstellung auf Tabellen in 1.4.2 (Liste der geprüften Werte je Datei verglichen: 135, 383, 154, 145).

### schnittstelle (Bleibt die öffentliche API stabil?)

| Test | Zweck | Tests | Herkunft |
|---|---|---|---|
| `schnittstelle/test-api.R`, `test_api.py`, `api.jl` | Funktionen, Argumente, Standardwerte, Klassen je Sprache gegen `frozen/{r,py,jl}.json` | je 1 | eingefrorener Stand |
| `schnittstelle/run.sh --check` | Abgleich der drei Sprachen (`api.json`, erklärte Abweichungen `known_differences.tsv`) | 1 | eingefrorener Stand |

### werkzeuge (keine Tests)

| Werkzeug | Zweck |
|---|---|
| `werkzeuge/gleichlauf/run.sh` | erzeugt mit dem aktuellen R **alle** Fälle der Generatoren neu (`SIMLEV_GEN_ALLE=1`; `--quick` jede 20. Kennung) und vergleicht Python und Julia (`vergleich.{py,jl}`); `--full` zusätzlich `faelle_diff.py` (Katalog Byte für Byte gleich); `exporte.py` zählt die Exporte ohne Fall |
| `werkzeuge/zufall/engine_faelle.R`, `engine_stress.R`, `packen.py` | Zufallsprüfung der Engine (500 bzw. 1000 Fälle im Engine-Format), nur im Gleichlauf-Lauf, nichts abgelegt |
| `werkzeuge/breite/<bereich>.R` | Breitenprüfung: die bisherigen Einzelfälle der neun Bereiche mit Szenarien (bis 1.4.1 Generatoren des Katalogs, gleiche Zufallsfolge), nur im Gleichlauf-Lauf (`breite_<bereich>`), nichts abgelegt |
| `werkzeuge/gleichlauf/*_fuzz.R` | Zufallsprüfungen (Datumskern, slc_rbase, Tarifkern, simulation, Vorbereitung, Kennzahlen); R bzw. R 1.3.0 als Orakel |
| `werkzeuge/bench/` | Laufzeitmessung (siehe `README.md` dort) |
| `werkzeuge/doku/beispiele.sh` (mit `beispiele.py`) | führt alle Codeblöcke der READMEs (Wurzel, `r/`, `python/`, `julia/`), der R-Vignette und der Tutorials in R, Python und Julia aus und vergleicht die Ausgabeblöcke (`--write` schreibt sie neu) |
| `werkzeuge/doku/verweise.py` | prüft relative Verweise, Bildpfade und Anker in Markdown-Dateien |
| `werkzeuge/doku/bilder.py` | erzeugt die Abbildungen des Haupt-README in `r/man/figures/` aus echten R-Läufen |
| `werkzeuge/erzeugen.sh` | Katalog mit dem installierten R neu erzeugen |

## Neu erzeugen

Ändert sich ein Ergebnis von R gewollt: `tests/werkzeuge/erzeugen.sh` (oder nur die betroffenen Bereiche), dann
`git diff --stat tests` und die Suiten; Ursache in `r/NEWS.md`. Neue Szenarien bzw. Tabellenzeilen: im Generator des
Bereichs mit `ref_init(modul, gruppe = …)` und `SZ(id, prueft, teile = list(<name> = teil(r, py, jl)))` bzw.
`TB(id, prueft, zeilen = list(zeile(z, r, py, jl)))` (`szenario_tools.R`; engine: `ref_case()`/`ref_tabelle()`)
anlegen. In r_grundfunktionen und slc: Einzelfälle ohne Gruppe (`ref_case()` nach `ref_init(modul)`) mit Kennung
`<modul>/<id>` in `erzeugen/auswahl.txt` eintragen, sie werden Zeile der Tabelle ihrer Funktion.

## Lokal aufbewahren

Die Tests sollen später nicht mehr im Repository liegen, sondern nur lokal. Dafür genügt:

1. `tests/` an einen lokalen Ort kopieren (oder im Arbeitsbaum lassen),
2. `git rm -r --cached tests` bzw. den Ordner löschen und `tests/` in `.gitignore` eintragen.

Außerhalb von `tests/` verweisen nur das Haupt-README und `r/DEVELOPING.md`, `python/DEVELOPING.md`,
`julia/DEVELOPING.md` auf diesen Ordner; Pakete, Bau und `R CMD check` brauchen ihn nicht (geprüft mit einer Kopie ohne `tests/`). Die Suiten finden
die Pakete über die Repo-Wurzel (`tests/` muss dafür neben `r/`, `python/`, `julia/` liegen) bzw. über `R_LIBS` und das
installierte `simlev`. Der Vergleich mit den Referenzfällen liegt ganz in `tests/lib` (Python `reftree.py` und
`faelle.py`, Julia `faelle.jl`; seit 1.4.2 ist kein Lade- oder Vergleichscode für Testfälle mehr im Paket). Aus dem
Paket nutzen die Tests nur die Umgebungsschalter `SIMLEV_LAX_NA`, `SIMLEV_STRICT_ZERO` und die Kollation
(`simlev._r.env` bzw. `SimLev.REnv`).
