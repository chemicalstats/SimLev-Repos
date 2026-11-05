# SimLev.jl (Julia) – Änderungen je Version

## SimLev.jl 1.6.3

Patch (R/Python/Julia). Schneller und schlanker in allen drei Sprachen und im gemeinsamen Kern, in Julia mit kürzerer Ladezeit. Ergebnisse, Ausgaben, Meldungen und Warnungen sind bitgleich zu 1.6.2, außer bei den Punkten „Berichtigt:“ unten. Die öffentliche Schnittstelle bleibt gleich; in Python entfällt nur die nie erreichte Klasse `planning.WithdrawalPathsPB`.

- Berichtigt: bootstrap_config() prüft die Felder der Hebelprodukte (`letfs`) auf Typ und Länge, in allen drei Sprachen mit derselben Meldung.
  - `leverage`, `expense`, `spread`, `rate_basis`, `ter_basis`: einzelne endliche Zahl („LETF i: <feld> muss eine einzelne endliche Zahl sein“).
  - `finance`, `days`: einzelne endliche Zahl oder Name einer Zusatzreihe aus `aux` („LETF i: <feld> muss eine einzelne endliche Zahl oder der Name einer Zusatzreihe aus aux sein“).
  - `base`, `name`: einzelner Text, nicht NA („LETF i: base muss ein einzelner Name (Text) sein“ bzw. „LETF i: name muss …“).
  - Bisher gingen Vektoren, Text, logische Werte, NA, unendliche Werte und in R ein Faktor als `base` still durch; bootstrap() und bootstrap_study() rechneten sie über einen Rückfall in der Sprache. In R griff `base = factor("eu")` dabei über den Faktorcode auf eine falsche Spalte zu, ohne Meldung; Python und Julia nahmen andere Eingaben an als R. Jetzt: Fehler beim Erstellen der Konfiguration. Für gültige Eingaben ändert sich nichts.
- bootstrap(), bootstrap_study(): Der Pfad entsteht immer im Kern; der Rückfall in der Sprache entfällt (R `.letf_returns`, Python und Julia `_letf_returns`, mit den Spaltenhilfen).
- Berichtigt: bootstrap_study(chunk_dir): Die Chunk-Dateien tragen eine Sprachkennung.
  - Namen: R `chunk_<Nr>_seed<Seed>[_<keep_returns>][_keep<k>]_r.rds` (saveRDS), Python `…_py.pkl` (pickle), Julia `…_jl.bin` (eigenes Binärformat, siehe „Nur Julia:“).
  - Bisher hießen die Dateien in allen drei Sprachen `….rds`, mit drei verschiedenen Formaten; ein gemeinsames Verzeichnis ließ eine Sprache an den Dateien einer anderen scheitern.
  - Jetzt bricht die Studie vor der Rechnung ab, wenn zu einem Chunk nur eine Datei einer anderen Sprache oder der Form bis 1.6.2 vorliegt, in allen drei Sprachen mit derselben Meldung: „chunk_dir: '<Datei>' stammt von einer anderen Sprache oder einer älteren Fassung von SimLev (bis 1.6.2) und wird nicht gelesen; je Sprache ein eigenes Verzeichnis verwenden.“ Chunk-Verzeichnisse aus 1.6.2 werden nicht mehr gelesen; der Lauf muss neu beginnen.
- Kern (`core/`), bitgleich:
  - simulation() und alles, was darauf aufbaut: Vorbereitung und Auswertung schlanker (Kalenderdatum je Tag fortgezählt, Termine bei lückenlosen Tagen über den Index, Zeilensummen ohne Kopie, Mittel und Varianz der Tagesrenditen einmal statt dreimal, Kursreihen erst beim ersten Split kopiert). Instruktionen im Kern (callgrind, simulation() über 30 Jahre mit 4 Anlagen bzw. bootstrap_study() mit 20 Pfaden): Vorbereitung −56 % bzw. −39 %, Auswertung −10 % bzw. −12 %, Kern insgesamt −18 % bzw. −15 %.
  - copula_fit(), dependence_analysis() mit t-Copula, scenario_copula(): eine Profil-Likelihood weniger je Fit (der Wert am Ergebnis der Brent-Suche wird gemerkt).
  - Neue interne Einsprünge, die die Sprachen nutzen: gleitendes Maximum (`roll_max_core`, für signal_drawdown(window)), kompakte Ausgabe der offenen Lots der Tagesengine, Spaltensummen über einen Zeilenindex (`sl_r_colsums_idx`, für overfit_reality_check()), Bootstrap-Pfad aus Quelle und Zeilenindex (`sl_boot_path_src`, Python und Julia).
- tax_tariff() ohne eigene Datei (und damit simulation() mit income_tariff()) liest die mitgelieferte Tarifdatei je Sitzung einmal, in allen drei Sprachen gleich: Schlüssel sind Pfad, Größe und Änderungszeit; gemerkt nur ohne Warnung; jeder Aufruf erhält eine eigene Kopie.
- Studien mit Fonds-Wrappern (sensitivity_grid(), sensitivity_rebalancing(), param_search(), bootstrap_study()): Der Anteilswert eines Wrappers wird bei gleichen Daten, Wrapper und Splits einmal je Studie gerechnet, wenn die innere Rechnung ohne Meldung und ohne Warnung blieb; sonst wie bisher je Lauf.
- In allen drei Sprachen schneller über dieselben Wege: signal_drawdown(window) mit dem gleitenden Maximum des Kerns (O(n) statt O(n · window)); overfit_reality_check() mit Spaltenmitteln ohne Zeilenkopie; withdrawal_max_rate() bereitet die Renditequelle nur im ersten Suchschritt auf; backcast_fit(method = "grid") rechnet die Modellrenditen je Gitterpunkt einmal und nur im Fit-Fenster; portfolio_optimize(), portfolio_rolling() und portfolio_risk_contributions() mit Ledoit-Wolf ohne Zeilenschleife; tactical_conditional_volatility() mit beiden Quantilen in einem Aufruf; param_plateau() und die Nachbarschaften des Rasters ohne Schleife je Punktpaar.
- Laufzeit gegenüber 1.6.2 (Median; 1.6.2 und 1.6.3 abwechselnd, je Lauf ein frischer Prozess, ein Faden; 10 Läufe je Aufgabe und Fassung in R und Python, 20 in Julia; aufgenommen nur Änderungen über der Streuung und ab 10 %):
  - bootstrap_study() mit drei Strategien (eine mit signal_drawdown(window), eine mit Einkommensteuertarif), 250 Pfade: R 7,84 → 2,70 s (−66 %), Python 4,67 → 3,06 s (−35 %), Julia 2,05 → 1,33 s (−35 %); in R mit `burn_in = 252` und 100 Pfaden 3,13 → 1,08 s (−65 %).
  - signal_drawdown(window = 252) mit 30 000 Werten: R 92,5 → 1,5 ms (−98 %), Python 53,8 → 0,7 ms (−99 %), Julia 21,4 → 0,9 ms (−96 %).
  - overfit_reality_check() mit 100 Strategien: R 0,55 → 0,22 s (−60 %), Python 1,25 → 0,63 s (−50 %), Julia 0,38 → 0,20 s (−46 %).
  - param_plateau() mit Ausgabe und Grafik, 400 Punkte: R 406 → 28 ms (−93 %), Python 116 → 75 ms (−35 %), Julia 57 → 4 ms (−93 %).
  - portfolio_rolling(cov = "ledoit_wolf"), 20 Anlagen: R 2,34 → 1,53 s (−35 %), Python 1,06 → 0,73 s (−32 %), Julia 0,66 → 0,31 s (−52 %); mit 5 Anlagen R 1,49 → 0,71 s (−52 %), Python 0,79 → 0,24 s (−70 %), Julia 0,14 → 0,08 s (−47 %).
  - portfolio_optimize(cov = "ledoit_wolf"), 20 Anlagen: R 38 → 20 ms (−49 %), Python 37 → 23 ms (−39 %), Julia 15 → 6 ms (−59 %); portfolio_risk_contributions() Python 130 → 66 ms (−49 %), Julia 134 → 49 ms (−64 %).
  - sensitivity_grid() mit Fonds-Wrapper, 32 Läufe: R 0,84 → 0,58 s (−31 %), Python 0,48 → 0,30 s (−38 %), Julia 0,77 → 0,30 s (−62 %).
  - withdrawal_max_rate() auf einer Studie mit 4 000 Pfaden: R 0,54 → 0,36 s (−34 %), Python 0,39 → 0,30 s (−23 %), Julia 0,78 → 0,44 s (−43 %).
  - withdrawal_paths() mit Inflationsreihe und withdrawal_simulation(), 1 000 Pfade: R 0,63 → 0,49 s (−23 %), Python 1,82 → 0,34 s (−81 %), Julia 0,47 → 0,29 s (−39 %).
  - backcast_fit(method = "grid"), rund 5 200 Tage: R 0,96 → 0,74 s (−24 %), Python 0,47 → 0,37 s (−21 %), Julia 0,38 → 0,35 s (−10 %).
  - tactical_conditional_volatility(), 40 Jahre: R 146 → 104 ms (−29 %), Python 75 → 63 ms (−16 %), Julia 62 → 54 ms (−14 %).
  - scenario_entropy_pooling(), 10 000 Tage: Python 9,9 → 6,8 ms (−31 %), Julia 19,2 → 12,9 ms (−33 %).
  - Nur R: simulation() mit Einkommensteuertarif (10 Jahre) 19 → 6 ms (−68 %); withdrawal_cohorts(frequency = "quarter") 131 → 12 ms (−91 %); signal_combine() mit 3 Signalen und 30 000 Werten 58 → 4 ms (−93 %).
  - Nur Python: tactical_rules() mit 3 Textregeln und 20 Spalten 138 → 24 ms (−83 %); bootstrap_probability() mit 4 Bedingungen 48 → 14 ms (−70 %), mit `path %in% (1:1000)` 119 → 5 ms (−95 %); bootstrap() mit 4 000 Pfaden 0,77 → 0,57 s (−26 %), mit `cores = 2` und 1 000 Pfaden 0,53 → 0,33 s (−38 %); overfit_pbo() 114 → 89 ms (−22 %); simulation() mit Steuern 13,8 → 11,2 ms (−19 %); plot(overfit_walk_forward()) mit 60 Jahren 0,43 → 0,31 s (−29 %); 100 Aufrufe von tax_tariff() 37 → 3 ms (−92 %).
  - Nur Julia: summary(bootstrap_study()) mit 1 000 Pfaden 262 → 2,8 ms (−99 %); bootstrap_study(chunk_dir) beim Laden von 1 000 Pfaden 0,90 → 0,03 s (−97 %); bootstrap() mit 4 000 Pfaden 0,95 → 0,47 s (−50 %), mit 2 Threads und 1 000 Pfaden 0,29 → 0,15 s (−48 %); withdrawal_simulation(frequency = "month") mit 10 000 Pfaden 0,60 → 0,45 s (−25 %); simulation() mit Steuern 8,3 → 7,5 ms (−11 %).
  - Langsamer: Python overfit_reality_check() mit 25 Strategien 0,12 → 0,17 s (+33 bis +38 %, in einer Nachmessung bestätigt; mit 50 und 100 Strategien schneller, siehe oben). Julia `using SimLev` 0,64 → 0,80 s (+26 %, Speicher nach dem Laden +3 MB); dafür der erste Aufruf in einem frischen Prozess über 33 Aufgaben zusammen 77 → 55 s (−29 %), z. B. tactical_conditional_volatility() 2,16 → 0,52 s, withdrawal_paths() 2,75 → 0,88 s; langsamer nur simulation() mit Tarif 0,54 → 0,65 s (+20 %).
  - Unverändert im Rahmen der Streuung: u. a. simulation() mit Steuern in R, param_search(), scenario_copula(), dependence_analysis(), regime_hmm(), result_analysis(), Grafiken.
- Tests (Ordner tests des Repositorys): Prüffälle, Urteile und Meldungen sind unverändert, außer den neuen Fällen unten.
  - Neue Fälle im Katalog zu den Berichtigungen: LETF-Prüfung, fremde und alte Chunk-Dateien, zweiter Lauf mit `chunk_dir`, Text-Logik in signal_state() und tactical_rules(), `cummax` mit NaN vor NA, Median bei ±0, Anzeigebreite, Lücken in der Tiefenanalyse und in Krisenszenarien, match.arg in Julia. Katalog 1.6.2 gegen 1.6.3: 13 von 343 Tests neu oder geändert, die übrigen 330 Byte für Byte gleich.
  - Die Zufallsprüfungen vergleichen gegen abgelegte Ausgaben von R 1.6.3 (`tests/werkzeuge/gleichlauf/run.py --ref-erzeugen 163`); das Manifest enthält seit 1.6.3 auch die Prüfsummen der mit `source()` geladenen Hilfsdateien.
  - `tests/run.py` führt die Sprachen gleichzeitig aus (`--jobs N`, Standard 2; `--jobs 1` nacheinander wie bisher); die Ausgabe erscheint je Sprache als Block in der Reihenfolge R, Python, Julia. Ebenso `tests/schnittstelle/run.py` (drei Auszüge zu zweit) und `tests/werkzeuge/doku/beispiele.py`.
  - R-Generatoren: Jeder Zufallsfall wird einmal ausgewertet (Warnungen und Fehler aus derselben Auswertung); die 22 Kopien von `fuzz_case` liegen einmal in `ref_tools.R`. Der Genauigkeitsteil mit Rmpfr von `eigen_fuzz.R` und `prec_fuzz.R` läuft nur ab 1 000 Fällen (`--full`) oder mit `SIMLEV_FUZZ_GENAU=1`. Arbeitsdateien mit gzip-Stufe 1 (`SIMLEV_GZIP_STUFE`), Katalog und Ablage weiter mit Stufe 9. 427 Breitenfälle entfallen, die wörtlich im Katalog stehen.
  - Gleichlauf (`run.py`): `vergleich.py` und `vergleich.jl` lesen die Fälle einzeln; je Sprache prüft ein Prozess alle Zufallsreferenzen (Protokolle weiter je Familie, `--protokoll`); Julia immer nur in einem Prozess zur Zeit (Vergleiche weiter mit `--heap-size-hint=2G`), die übrigen Schritte daneben; bereite Schritte beginnen nach ihrer letzten Dauer (längste zuerst). `sim_fuzz_cmp.py` liest beide Dateien im Gleichschritt, `packen.py` packt Fall für Fall. Ohne `faelle_diff` setzt `run.py` `SIMLEV_GEN_NUR_ALLE=1`. `vergleich.jl` ohne Pfad prüft wieder den Katalog; bis 1.6.2 brach es mit `UndefVarError` ab.
  - Zeiten gegenüber 1.6.2: voller Gleichlauf 30 statt 60 min; kurzer Gleichlauf (`--quick`) mit einem Schritt zur Zeit 11 bis 12 statt 15 bis 18 min; Julia, alle Engine-Zufallsfälle (`--full`) 47 statt 227 s bei 0,57 statt 3,48 GB Speicher; Packen der vollen Fälle 13,5 statt 73,6 s; Referenz erzeugen 14 statt rund 30 min.
  - Entfallen: ungenutzte Hilfen in `tests/lib/_helpers.py` (7 Funktionen), `fmt_args` in `tests/schnittstelle/compare_api.py`, die doppelt geführte Generatorliste (nur `erzeugen.py`), Hex- und NA-Hilfen (nur `reftree.py`), `SHARED_TARGETS` in `core/sync.py`.

Nur R:

- simulation(): Die Tagesengine gibt je Anlage nur noch die Zahl der Käufe und Verkäufe und (mit `tax_mode = "person"`) die offenen Lots als Spalten zurück; die Einzelobjekte je Lot, Verkauf und Steuerbuchung entfallen. Die Jahreszeilen des Tarifwegs (`tax_report$tariff_years`) entstehen Spalte für Spalte statt mit data.frame() je Jahr und rbind().
- Weitere Wege: Zuordnung des Wrapper-Anteilswerts zu den Datentagen über die Tageszahl statt über Text; portfolio_optimize() rechnet die Kovarianz einmal für Optimierung und Kennzahlen (ein zweites Mal nur, wenn ihre Rechnung warnte); result_analysis() ohne doppelte Kennzahlen der ersten Reihe; withdrawal_cohorts() mit `frequency = "quarter"`/`"month"` mit Periodenprodukten im Kern (wie prod()); signal_combine() mit logischen Signalen elementweise; bootstrap_study() mit `burn_in` schneidet den Ausschnitt einmal je Pfad für Strategien ohne `signal`/`map`.
- Entfallen (ohne Aufrufer bzw. Leser): das nie übergebene interne Argument `spread` samt Warnung, das cfg-Feld `tax_rate`, Zustandsfelder ohne Leser in `sim_mem`, `.SIM_MEM_LAYOUT`/`.sim_check_layout`, die C-Einsprünge `C_sl_pt`/`C_sl_qt`, unbenutzte Hilfen des R-Hosts in `src/simlev_capi.h` und der Import `methods::hasArg` (NAMESPACE und DESCRIPTION; die Exporte bleiben).
- Zusammengelegt: Kontext-, Rückmelde- und Prüfhilfen der fünf slc-Hüllen in `src/huelle_r.h`; eine Spaltenliste der Tarif-Jahreszeilen; `.show_arg_s` und `.fill_na(, "locf")` statt dreier Kopien.
- Doku: `man/SimLev-package.Rd` nennt die Vignette (`vignette("getting-started")`) statt des entfallenen `inst/tutorial`; Kommentare in `src/Makevars`, `R/simulation.R`, `R/sim_prepare.R`; `.Rbuildignore` ohne die Regel für ein nicht vorhandenes Bild.

Nur Python und Julia:

- Berichtigt: Anzeigebreite von Zeichen wie R 4.3.3 unter C.UTF-8 (`nchar(type = "width")` in Bedingungen und Ausdrücken in R-Syntax, `fmt.nchar`, Spaltenbreiten im Druck). Eine Tabelle aus R gilt für alle Codepunkte, in Python und Julia dieselbe.
  - Bisher kam die Breite aus dem Unicode-Stand der Sprache. Python-RExpr zählte 159 Format- und Steuerzeichen (Cf) mit 1, R mit 0; beide `fmt.nchar` zählten die Hangul-Jamo U+1160–U+11FF und die Steuerzeichen U+0001–U+001F, U+007F–U+009F mit 1, R mit 0; Julia zählte 56 170 nicht vergebene Codepunkte (fast alle in U+2xxxx und U+3xxxx) mit 1 (R 2), Julia-RExpr U+2028 mit 0 (R 1). Über alle Codepunkte wichen Python-fmt in 466, Python-RExpr in 616, Julia-fmt in 57 063 und Julia-RExpr in 57 464 Codepunkten von R ab. Jetzt: 0 Abweichungen.
- Berichtigt: signal_state() und tactical_rules() mit Text als Logik wie R. Text in `sell` ergibt „invalid argument type“, Text in `buy` (auch nur NA als Text) „operations are possible only for numeric, logical or complex types“; ein Textvektor als `when` ist eine Folge von Ausdrücken in R-Syntax, es gilt der letzte. Bisher wertete Python Text mit `bool()` aus („FALSE“ wurde wahr), Julia jeden Text als wahr; ein Textvektor als `when` galt als logischer Vektor.
- scenario_copula() mit empirischen Rändern und das Auffüllen `"linear"` im Backcast: Die Nachbildung von approx bildet Gruppen und Gruppenmittel in O(m) statt O(m²) (approx mit 40 000 verschiedenen x: 1,30 → 0,005 s).
- bootstrap(), bootstrap_study(): Pfade aus gezogenen Zeilen liest der Kern direkt aus der Renditematrix (`sl_boot_path_src`).

Nur Python:

- Berichtigt: signal_drawdown() mit `window`: Enthält ein Fenster −0 und +0 und ist sein Hoch genau 0, ist das Hoch wie in R der zuerst auftretende Wert. Bisher bestimmte `np.max` das Vorzeichen (abhängig von der SIMD-Reduktion), und das Signal konnte von R abweichen, z. B. `signal_drawdown([-0.0, 0.0, -1.0], window = 3)`: bisher Verkauf in Zeile 3, jetzt wie R Kauf (Kurs / Hoch = −1/−0 = +Inf, Abstand −Inf). Nur bei Kursen ≤ 0 möglich; positive Kurse sind unverändert. In einer Probe mit 6 000 Fällen wich die alte Fassung in 303 von R ab, die neue in keinem.
- Berichtigt: Median bei ±0 in der Mitte wie R (`_r.rnum.r_median` über den Kern `sl_r_median` statt `np.sort`); bisher z. B. median(c(1, 0, −0)) = −0 statt 0. An den Aufrufstellen zeigte das kein Ergebnis.
- Schneller: withdrawal_simulation() und withdrawal_paths() mit Inflationsreihe (`inflation_type = "rate_pa"`) rechnen die Potenz je Periode im Kern statt je Element, ebenso die Zusatzreihen in bootstrap_study(), die deflationierten Werte in result_analysis(), EWMA-Kovarianz und rollierende Renditen im Dashboard; simulation() liest Spalten von `data` ohne Indexer und logische Spalten ohne Schleife je Element; bootstrap_study() kopiert die Pfaddaten je Strategie nur mit Signalfunktion oder `map`; die Dicts von `SimLevResult.trades` entstehen erst beim Zugriff; bootstrap() mit `cores = 2` gibt die Pfade in Blöcken an die Kindprozesse; Bedingungen in R-Syntax (tactical_rules(), bootstrap_probability() u. a.) wandeln Spalten erst beim ersten Zugriff um, `%in%` über eine Menge; plot() von overfit_walk_forward(), overfit_pbo(), param_search() und param_plateau(), print_matrix, scenario_entropy_pooling().
- Entfallen: `planning.WithdrawalPathsPB` und die Rückfälle in `_paths_class()` und `_wd_ppy()` (nie erreicht; bootstrap_pooled() liefert wie bisher `withdrawal.WithdrawalPaths`, Ausgabe unverändert; damit entfällt `print.withdrawal_paths` aus der eingefrorenen Schnittstelle). Tote Konstanten, Funktionen und Zweige der Analyseschicht und von `_r`/`_lib` (u. a. `_lib.version`, `_r.libm.atanh/asin/acos/sinh/cosh/lgamma_c`, `_r.stats.coef/fitted/residuals/optimise`, `_r.env.SWITCHES`), der nie gesetzte Parameter `spread` von `engine._simulation_flat` samt unerreichbarer Warnung, das Feld `tax_rate` der Eingangsprüfung, tote Teile der C-Hülle.
- Zusammengelegt (je eine Fassung): `_Missing`, `message`, `_fmt1`, `unique`, `match` für Tage, `_is_strategy`, `_colmeans`, `_rank_avg`, `_fill_locf`, `_is_num`, `RError`, `_bits`, die Sperrlogik des Zufallszustands, die Hilfen der slc-Hüllen (`src/_ext_slc_hull.h`).
- Bau: `setup.py` nimmt alle `src/core/*_core_impl.h` in `depends` auf; bisher fehlte `wrapper_core_impl.h`, und `build_ext --inplace` baute nach einer Änderung nur dieser Datei nicht neu.
- Doku berichtigt: `DEVELOPING.md`, Kommentare in `src/_ext_common.h`, `_r/stats.py`, `_r/env.py`.

Nur Julia:

- Erster Aufruf in einem frischen Prozess kürzer: Die großen Einstiege mit Schlüsselwörtern (withdrawal_simulation(), withdrawal_paths(), bootstrap_config(), planning_goal(), result_analysis(), overfit_pbo(), bootstrap_study(), param_search(), sensitivity_grid()) werden einmal für alle Typen der Schlüsselwörter übersetzt (`@nospecialize`) statt je Typkombination; je neue Form der Argumente 0,1–0,2 s statt 0,4–0,8 s. Die Arbeitslast beim Vorkompilieren deckt zusätzlich die Grafiken von Analyse, Signalanalyse, Parametersuche, Walk-forward und Rotation ab, die Entnahme über Pfade, die Taktik, overfit_reality_check(), sharpe_deflated(), backcast_fit(), Ledoit-Wolf, Entropy-Pooling und `cores = 2` über Threads. Erste Aufrufe: overfit_walk_forward() mit Grafik 5,0 → 1,4 s, tactical_conditional_volatility() 1,9 → 0,4 s, tactical_rules() 1,2 → 0,4 s, Entnahme über Pfade 2,3 → 0,6 s, overfit_pbo() 0,54 → 0,21 s, bootstrap(cores = 2) 1,04 → 0,64 s; 30 Messfälle zusammen 50,0 → 34,6 s. Kosten: Laden 0,61 → 0,76 s, Speicher nach dem Laden 349 → 361 MB, Vorkompilier-Cache 111 → 122 MB; `Pkg.build()` 287 → 275 s, weil der C++-Teil gleichzeitig übersetzt (Vorkompilieren 232 → 253 s).
- Schneller: summary() einer Studie gruppiert die Pfade über eine Tabelle; withdrawal_simulation() und withdrawal_max_rate() lesen eine Pfadspalte ohne Kopie der ganzen Matrix; simulation() mit mehreren Strategien ohne Signal kopiert die Daten nicht mehr; scenario_entropy_pooling(); Ausgabe mit `cores ≥ 2` ohne Kopie je Schreibvorgang.
- chunk_dir: eigenes Binärformat (Kopf `SLVCHNK`, Fassung 1, Werte mit ihren rohen Bits, bitgleich) statt Julia-Quelltext, der mit `Meta.parse` und `Core.eval` gelesen wurde. Gelesen wird kein Code mehr.
- Drawdown der Tiefenanalyse (result_analysis(), rollierende Kennzahlen, Grafikdaten) und scenario_crisis(): `cummax` über den Kern `sl_r_cummax` wie R und Python statt zweier eigener Schleifen mit anderen NA/NaN-Regeln (z. B. ergab c(1, NaN, 0,5, NA, 0,4) bisher NaN statt NA ab dem NA). In den Fällen ändert sich kein Ergebnis.
- Eine Fassung von `match.arg` (`_match_arg` aus util.jl; `match_arg` in config.jl entfällt, wie in NEWS 1.6.1 angekündigt). Berichtigt im Randfall: Ein Vektor mit Symbolen, z. B. `asset_config([:etc])`, wird wie Text angenommen (bisher „'arg' must be NULL or a character vector“); ein nicht textförmiger Vektor, dessen `string()` der ganzen Auswahl gleicht, ergibt wie in R den Fehler statt der ersten Wahl.
- Der tote Abbruchweg der C-ABI-Hülle entfällt (Export `simlev_c_interrupt`, Rückgabecode 2, `CAbi.INTERRUPT`); ein `ccall` lässt sich wie bisher nicht unterbrechen, Strg-C wirkt erst nach der Rückkehr des Kerns.
- Entfallen (ohne Leser oder Aufrufer): Zustandsfelder der Engine aus der Zeit vor 1.4.0 (`Market.asset_day`, `Trades.fifo_front`, `AssetInfo.class`, `AssetInfo.deliverable`, `VPPending`, `Totals.vp_pending`, `p23_due`, `private_sale_net_ytd_by`), der ungeprüfte Parameter `spread` von `_simulation_flat`, `REnv.SWITCHES`, Nachbildungen und Hilfen ohne Aufrufer (`is_leap`, `c_ldexp`, `c_frexp`, `c_sqrt` bis `c_acosh`, `c_pow`, `c_fmod`, `c_hypot`, `r_pow_vec`, `r_mod1`, `optimise`, `SLib.version`, `RLinalg.ismat`, `RBase.cummax`, `RBase.cummin`, `RFmt.NA_REAL`, `r_format_digits`, `rsprintf`, `_flex`), ungelesene Parameter interner Funktionen und ungelesene Ausgaben der C-Hülle, `Logging` als Abhängigkeit in `Project.toml`.
- Zusammengelegt: `_isna`, `_pmax`/`_pmin` (eine Fassung nach der R-Regel), `_sprintf`, `_ldsum`, Spaltensummen und -mittel, `_unique`/`_setdiff`, Tarifspalten, Regimenamen, die Liste der Kennzahlen, bei denen kleiner besser ist.
- Doku: Kopf von `src/r/base.jl`; Abbruch in `DEVELOPING.md`, `src/cabi.jl`, `core/simlev_cabi.cpp` (der Kommentar dort behauptete, kein Kern rufe die Prüfung auf; `hmm_em`, `goal_dp` und `pbo_cscv` tun es).

## SimLev.jl 1.6.2

Patch (R/Python/Julia). Genauere Formeln für Renditen und Kennzahlen und eine schnellere, orthogonalere Eigenzerlegung. **Ergebnisse ändern sich in den letzten Stellen** (relativ meist unter 1e-14, in Einzelwerten nahe 0 auch mehr, siehe unten) in den unten genannten Funktionen, in R, Python und Julia gleich; alle drei Sprachen bleiben bitgleich zueinander. Alles andere ist bitgleich zu 1.6.1.

Ergebnisänderungen (Grund: Auslöschung bzw. Rundung der bisherigen Formeln):

- simulation() und alles, was darauf aufbaut (Studien, Bootstrap, Parametersuche, Sensitivität, Wrapper): `cagr` und `ttwror` als expm1(log(q) / Jahre) statt q^(1/Jahre) − 1 (Kern `core/evaluate_core_impl.h`); damit auch `calmar`, `serenity`, `martin_ratio`. Bisher Median 8, höchstens rund 10³ ulp Fehler, jetzt höchstens etwa 1 ulp (bei kurzen Zeiträumen mehr, durch die Kondition von q^(1/T) bedingt). Änderung in den Referenzfällen höchstens 24 ulp (3,7e-15 relativ).
- backcast_fit(), backcast(): Diagnose (`tracking_error`, `tracking_difference`, `max_abs_deviation`, `deviation`, `correlation`) mit expm1 statt exp(x) − 1 und 1 − exp(x); `tracking_difference` als expm1(a) − expm1(b). Mit `accrual = "geometric"` die TER-Kosten als expm1(log1p(TER) · T/Basis) statt (1 + TER)^(T/Basis) − 1 (ändert auch die Anpassung). Abweichungen nahe 0 sind jetzt richtig statt 0 bzw. ±1e-16-Rauschen (bisher Einzelwerte mit bis zu 10⁵ ulp, bei 1 − exp(·) bis 10⁷ ulp).
- overfit_pbo(), sharpe_deflated(), sharpe_haircut(), overfit_reality_check() mit `frequency = "week"`/`"month"`: Periodenrenditen als expm1(rowsum(log1p(R))) statt exp(…) − 1 (bisher Median 11, höchstens 2·10⁴ ulp).
- overfit_walk_forward(): `cagr_*` als expm1(Σ log1p(r) / Jahre), `oos_return`, `oos_average` als expm1(Σ log1p(r)) statt prod(1 + r)^(1/Jahre) − 1 bzw. prod(1 + r) − 1 (bei Renditen < −1 oder NA wie bisher).
- result_analysis() und die übrigen Auswertungen aus deep_analysis (CAGR, internen Zinsfuß ohne Zuflüsse, rollierende CAGR und Überschussrendite, Capture-Ratios über das geometrische Mittel), result_heatmap() (annualisierte Renditen), signal_analysis() (`annualized`): wie CAGR oben.
- copula_fit(), dependence_analysis() mit Copulas, scenario_copula() über den Fit: log(1 − r²) der Gauß- und t-Copula als log1p(−r²) für r² < 1/2, sonst log((1 − r)(1 + r)), und 1 − r² als (1 − r)(1 + r) (höchstens 1,4 ulp; bisher bis 10⁶ ulp für r → 1 und bis 10¹⁵ ulp relativ für kleine r). Der Optimierer kann dadurch an einer anderen Stelle enden (Parameter in den Referenzfällen bis 2,3e-5 relativ, meist im flachen Profil von nu).
- Symmetrische Eigenzerlegung (`core/slc_linalg.cpp`, intern; portfolio_optimize() mit min_variance, max_diversification, risk_parity, Kovarianzen ewma/denoise, Schrittweite von qp_simplex, scenario_copula(), dependence_dcc()): Householder-Tridiagonalisierung und implizites QL/QR statt zyklischem Jacobi. Gemessen gegen eine Rechnung in 113 Bit (n = 5 bis 500): orthogonaler (n = 500: 1e-14 statt 5,5e-13), Residuum und Eigenwertfehler bezogen auf ‖A‖ ab n = 20 kleiner, darunter bis zum Faktor 2 größer (≤ 1,6e-15); bei n = 500 etwa 12-mal so schnell (mit Vektoren 0,13 statt 1,55 s). Reihenfolge (absteigend) und Vorzeichen (betragsgrößte Komponente positiv) wie bisher. Behoben: Jacobi brach bei vielfachen Eigenwerten und n ≥ 100 mit „konvergiert nicht (60 Durchläufe)“ ab (z. B. drei 50-fache Eigenwerte, wie sie das Entrauschen erzeugt). Gewichte und Kennzahlen ändern sich in den letzten Stellen (Referenzfälle bis 1,2e-10 relativ über die Abbruchschranke von qp_simplex); bei mehrfachen Eigenwerten können die Vektoren eine andere Basis desselben Eigenraums sein.

Weitere Stellen mit denselben Mustern bleiben unverändert: Grafiken des Dashboards (rollierende CAGR, Monatsrenditen; Anzeige mit einer Nachkommastelle), Anleihekurs (Datenaufbereitung), Zins- und Inflationsfaktoren (1 + x)^t ohne „− 1“ (keine Auslöschung).

- Laufzeit gegenüber 1.6.1 (große Fälle, abwechselnd, 2 Runden): portfolio_optimize() mit 500 Anlagen −27 % (R), −35 % (Python), −29 % (Julia), portfolio_rolling() mit 50 Anlagen −14 % (R, Julia); Backcast und PBO unverändert.
- Tests (Ordner tests des Repositorys): Referenzen nur noch auf ausdrücklichen Befehl, einmal je Versionsschritt. Die Zufallsprüfungen vergleichen gegen abgelegte Ausgaben von R 1.6.2 (`tests/werkzeuge/gleichlauf/run.py --ref-erzeugen 162`, mit Version, Startwerten, Fallzahl und Prüfsumme; fehlt die Ablage oder passt sie nicht, bricht der Lauf mit Meldung ab); nur noch eine Vorversion (bis 1.6.1 R 1.3.0 bis 1.5.2). Der Katalog `tests/*/faelle` entsteht nur über `tests/werkzeuge/erzeugen.py`. Der Gleichlauf führt unabhängige Schritte gleichzeitig aus (`--jobs`, Standard 2); voller Lauf 60 statt 118 min. Neue Zufallsprüfung `prec_fuzz` (expm1, log1p, CAGR, Periodenaggregation, Copula-Dichte; Fehler in ulp gegen Rmpfr); `eigen_fuzz` prüft zusätzlich Residuum, Orthogonalität und Eigenwerte gegen Rmpfr.

## SimLev.jl 1.6.1

Patch (R/Python/Julia). Weniger Code in Python und Julia, schnellerer Wirtscode und kürzere erste Aufrufe in Julia; Ergebnisse, Ausgaben, Warnungen und Fehler bleiben bitgleich zu 1.6.0 (geprüft gegen R 1.5.2), außer den unten als „Berichtigt“ genannten Meldungen von match.arg in Randfällen.

- simulation(): Assets ohne Signalspalte (Kaufen und Halten) bekommen keine Spalte aus FALSE je Tag mehr; der Kern der Tagesengine liest für sie FALSE an jedem Tag (leerer Zeiger, `core/engine_core_impl.h`, `core/prepare_core_impl.h`). R übergibt weiter seine Vektoren.
- t-Copula (dependence_analysis() mit `copulas = TRUE`, scenario_copula()): Auf einer ruhigen Maschine nachgemessen, mit zwei Threads gegen einen (`SIMLEV_THREADS=1`) in allen drei Sprachen −26 bis −46 %; die Voreinstellung (Zahl der Prozessoren, höchstens 8) bleibt.
- Laufzeit gegenüber 1.6.0 (große Fälle, alt und neu abwechselnd, 2 Runden): Python simulation() −14 bis −46 %, sensitivity_grid() −67 %, tactical_rules() −93 %, bootstrap_study() −42 %, wrapper_nav() −62 %; Julia tactical_rules() −63 %, tactical_simulation() −38 bis −46 %, portfolio_optimize("hrp") −25 %, portfolio_rolling() −28 %; R simulation() mit 200/500 Anlagen −14 bis −17 %.
- Tests (Ordner tests des Repositorys): Referenzfälle können für eine Sprache allein gelten (`ref_case(..., nur = "py" | "jl")`), wenn die Nachbildung der anderen Sprache ohne Aufrufer entfallen ist. Entfallen sind die Fälle der gestrichenen Nachbildungen in beiden Sprachen (cat, print.factor, toString, prettyNum, encodeString, weighted.mean, complete.cases, cumprod über `simlev._r.base`); `opt_scipen` prüft cat() nicht mehr.

Nur R:

- `src/Makevars`, `Makevars.win`: Die Gleitkomma-Schalter (`-ffp-contract=off -fno-fast-math`) stehen wie bis 1.5.2 in einer eigenen Variablen mit einer Regel je Datei; R CMD check meldete sie in 1.6.0 in `PKG_CXXFLAGS` als WARNING (nicht portabel). Gleicher Maschinencode (alle 33 Objekte verglichen).
- withdrawal_simulation() mit Tarifweg: die Jahreszeilen (`tax_report$tariff_years`) entstehen als Liste mit einem Aufbau statt Spalte für Spalte (`.wd_tariff_years`).
- simulation(): Die Tage je Asset entstehen einmal je Lauf statt je Asset, die offenen Lots je Asset (`open_lots`) ohne data.frame() je Asset; 500 Anlagen mit Steuer −10 %.

Nur Python und Julia:

- Nachbildungen von R-Funktionen ohne Aufrufer im Paket entfallen (bisher nur von Referenzfällen genutzt), siehe die Listen unter „Nur Python“ und „Nur Julia“. Die Umgebungsschalter `SIMLEV_LAX_NA`, `SIMLEV_STRICT_ZERO` und `SIMLEV_COLLATE` bleiben (dokumentiert, von den Tests gelesen), ebenso `set_options` (vom Zufallstest des Datumsformats genutzt).
- Bau: Sprünge nicht über 32-Byte-Grenzen (`-Wa,-mbranches-within-32B-boundaries`, nur wenn der Assembler es kennt; `python/setup.py`, `julia/deps/build.jl`). Ohne den Schalter schwankte die Laufzeit einzelner Kerne je nach Lage im Code um bis zu 30 % (Intel-JCC-Erratum; z. B. `qp_box_simplex` in portfolio_rolling() bei gleichem Objektcode +28 %). Nur Auffüllung, gleiche Befehle. Nachgeprüft danach: alle Fälle und Zufallsfälle des Gleichlaufs in Python (50.318/50.318), Datums- und Grundfunktionsprüfungen in Python und Julia, Julia-Build; der Julia-Vergleich aller Fälle und tests/run.py für Python und Julia sind nach dem Schalter nicht erneut gelaufen.
- Eine Fassung von `match.arg` je Sprache (bis 1.6.0 in Python zwei, in Julia drei): Prüfungen und Meldungen wie R 4.3.3. Berichtigt (bisher nur in Randfällen anders als R): ein leerer Vektor als Wahl meldet „'arg' should be one of …“ statt „'arg' must be of length 1“, ein Vektor mit Nicht-Text „'arg' must be NULL or a character vector“, bei einer einzigen Wahl lautet die Meldung „'arg' should be “…”“, doppelte und leere Wahlen erscheinen nicht in der Meldung.
- Eine Fassung von `which.max`/`which.min` je Sprache (bis 1.6.0 vier bis fünf Kopien mit verschiedenen Rückgaben bei leerer Eingabe; die Aufrufer behalten ihr Verhalten).

Nur Python:

- Entfallen (ohne Aufrufer): `_r.base.colSums`/`colMeans`/`rowSums`/`rowMeans`/`cumprod`/`cummax`/`cummin` (das Paket nutzt `_r.rnum`), `_r.fmt.prettyNum`, `encode_string`, `paste0`, `to_string`, `print_factor`, `print_list`, `print_default`, `cat_str`, `r_cat`, `_r.stats` `weighted_mean`, `complete_cases`, `rle`, `tabulate`, `findInterval`, `ecdf`, `ave`, `aggregate`, `approxfun`, `_r.libm.apply2`/`atan2`, `_r.rnum.r_mod1`/`r_cummin`, `_collate.collate_reset`; die C-Hüllen `slc_qt`/`slc_pt` (seit 1.6.0 über die Thread-Fassungen) und `slc_r_scientific`/`slc_r_scientific_vec`.
- Schnellere Wege: Signale (`signal_*`, `_sig_out`), tactical_rules() und signal_state() wandeln bool- und float64-Felder ohne Schleife je Wert um; bootstrap_study() baut Pfadtabelle, Ergebniszeilen und Tabelle je Strategie mit einem Aufbau.
- Doppelte Hilfen zusammengelegt (`_lib_models` nutzt die Matrixhilfen aus `_lib_linalg`, `tactical` die Kalenderrechnung aus `data_prep`, eine Fassung von `_days`/`_dates`, ein Aufruf von `_callable_module` für bootstrap und param_search, eine Prüfung doppelter Namen in `data_prep`).

Nur Julia:

- Entfallen (ohne Aufrufer): `RFmt.r_factor`, `encode_string`, `to_string`, `prettyNum`, `format_date`, `print_factor`, `format_data_frame`, `cat_str`, `r_cat`, `RBase.r_diff`, `r_range`, `RLinalg.outer`, `RStats.dist_as_matrix`, `complete_cases`, `weighted_mean`, `collate_key` und Reste aus 1.6.0 (`_rb_scientific`, `_cpow`, `_as_float`, `_DBL_DIG`, `_MAX10E`, `_DOUBLE_LINE`). `RFactor` bleibt als Typ (Eingaben der Druckausgabe), ebenso die `IndexStyle`-Methoden von `RFactor` und `RVector` (ruft Base selbst auf).
- Typstabilität: signal_state(), tactical_rules(), `_fill_na` (Backcast, Tactical) und die Renditen von dependence_analysis()/portfolio_optimize() (`_dep_returns`, `_opt_returns`) laufen hinter Funktionsgrenzen mit festen Typen; portfolio_optimize(method = "hrp") mit 200 Anlagen −25 bis −47 %, portfolio_rolling() −28 %.
- Erster Aufruf in einem frischen Prozess: Die Arbeitslast beim Vorkompilieren deckt zusätzlich dependence_analysis() mit Copulas, scenario_copula() (t und Gauß), result_analysis() eines Ergebnisses von simulation(), portfolio_optimize() und tactical_rotation() mit `RFrame` ab: erster Aufruf scenario_copula() 2,4 → 0,4 s, result_analysis() 0,9 → 0,2 s, dependence_analysis() mit Copulas 0,8 → 0,5 s, tactical_rotation() 0,75 → 0,21 s, portfolio_optimize() 0,33 → 0,20 s; Ladezeit (0,6 s) und Pkg.build() mit Vorkompilieren (262 s) unverändert.

## SimLev.jl 1.6.0

Minor-Update (R/Python/Julia). Der Kern ist einheitlich C++, die Rechenschritte, die bei großen Strategien und Daten die meiste Zeit kosten, rechnet er in allen drei Sprachen mit demselben Code, ebenso die bis 1.5.2 in Python und Julia je für sich nachgebildeten Grundfunktionen von R. Ergebnisse, Ausgaben, Warnungen und Fehler bleiben bitgleich zu 1.5.2, außer den unten als „Berichtigt“ genannten Abweichungen der Ports von R.

- Kern einheitlich in C++: Die Bibliothek slc (`core/slc_*.c`, bis 1.5.2 C99) ist jetzt C++ (`core/slc_*.cpp`), ebenso die Hüllen (`r/src/init.cpp`, `r/src/slc_r*.cpp`, `python/src/_ext_slc*.cpp`). Alle drei Builds übersetzen nur noch C++ mit denselben Schaltern (`-std=gnu++17 -O2 -ffp-contract=off -fno-fast-math`, MS-GARCH-Starts mit Threads außer unter Windows); zum Bauen genügt ein C++-Compiler. Die öffentliche Schnittstelle (`slc.h`, `slc_*.h`) und die C-ABI-Hülle behalten die C-Bindung (`extern "C"`); die exportierten Symbole und die `ccall`s von Julia sind unverändert. Alle Funktionen der Bibliothek tragen die Angabe, dass sie nie werfen (`SL_NOTHROW`); ohne sie war der MS-GARCH-Fit in Julia 7 % langsamer als mit der C-Fassung.
- Meldungstabellen aus einer Quelle: Die Code→Text-Tabellen der Tagesengine (Warnungen, Abbrüche, `details`-Ausgaben, Anlässe der Käufe und Verkäufe, Bezeichnungen der Steuerzahlungen) und der Auswertung von simulation() (Ursachen nicht definierter Kennzahlen, Warnungen einschließlich derer von `uniroot`) stehen in `core/meldungen.tsv`; `core/gen_meldungen.py` (nur Standardbibliothek) erzeugt daraus `r/R/meldungen.R`, `python/simlev/_meldungen.py` und `julia/src/meldungen.jl`, `core/sync.py --check` prüft, dass sie aktuell sind. Die Texte sind wortgleich zu 1.5.2.
- simulation() mit Handelstagsdaten (Lücken im Kalender): Das Auffüllen auf Kalendertage (letzter Wert für Zahlen, Signale FALSE, Spalte `.filled`) rechnet der Kern (`core/slc_prep.cpp`); bis 1.5.2 R über `merge()` mit Datumstext je Tag, Python und Julia über Schleifen je Tag. Das gilt für alle Studien über simulation() (param_search(), sensitivity_grid(), bootstrap_study(), overfit_walk_forward() …). Spalten mit Attributen oder Faktoren und nicht ganzzahlige Datumswerte laufen in R wie bisher über `merge()`.
- bootstrap() und bootstrap_study(): Jeder Pfad (Kurse, Hebelprodukte mit Knockout, Zusatzreihen und ihre Niveau-Variante `aux_level`) entsteht in einem Aufruf des Kerns (`core/slc_bootpath.cpp`) statt spaltenweise in der Sprache.
- t-Copula (copula_fit(), dependence_analysis() mit `copulas = TRUE`, scenario_copula() mit `family = "t"`): Die Profil-Likelihood über nu rechnet ganz im Kern (`core/slc_tcop.cpp`), mit dem Brent-Verfahren wie `stats::optimize` (`core/slc_opt_fmin.cpp`). Nur wenn eine Auswertung nicht endlich ist oder qt warnt, rechnet die Sprache wie bisher (gleiche Meldungen).
- qt und pt der Bibliothek slc rechnen elementweise auf mehreren Threads; das Ergebnis hängt nicht von der Zahl der Threads ab. Neue Umgebungsvariable `SIMLEV_THREADS` (ganze Zahl ab 1; ohne sie die Zahl der Prozessoren, höchstens 8; unter Windows ohne Threads).
- Symmetrische Eigenzerlegung (portfolio_optimize(), portfolio_rolling(), scenario_copula() u. a.): Das zyklische Jacobi-Verfahren dreht je Schritt zwei zusammenhängende Spalten und trägt die Zeilen blockweise nach (gleiche Drehfolge, gleiche Rechnung je Element); bei 500 Anlagen etwa 2,4-mal so schnell.
- momentum_score() und tactical_rotation(): Rückblickzeilen (ganzzahlige Kalenderrechnung), letzter Wert, Renditen und Scores rechnet der Kern.
- Laufzeit gegenüber 1.5.2 (Median, alt und neu abwechselnd, große Fälle): R param_search() mit Werktagsdaten −85 %, simulation() mit Werktagsdaten −36 bis −65 %, sensitivity_grid() −54 %; tactical_rotation() R −66 bis −75 %, Python −34 bis −40 %, Julia −92 bis −94 %; bootstrap() −20 bis −38 %; dependence_analysis() mit Copulas und scenario_copula() R und Julia −35 bis −46 %, Python −2 bis −7 %; portfolio_optimize() mit 500 Anlagen −29 bis −34 %. Keine andere gemessene Aufgabe messbar langsamer.
- Tests (Ordner tests des Repositorys): `tests/werkzeuge/gleichlauf/run.py` kennt die Referenz R 1.5.2 (`REFLIBS` „152“, `SIMLEV_FUZZ_REFLIB152`) und die Option `--ref KENNUNG`, mit der alle Zufallsprüfungen gegen eine Referenz laufen. Neue Zufallsprüfungen mit 1.5.2 als Referenz: cal_fuzz (simulation() mit lückenhaften Kalendern), boot_fuzz (bootstrap() mit Hebelprodukten, Zusatzreihen, Knockouts, allen Verfahren), copula_fuzz (copula_fit, scenario_copula, dependence_analysis, optimize, qt/pt mit Threads), mom_fuzz (momentum_score, tactical_rotation), eigen_fuzz (Eigenzerlegung, portfolio_optimize), clust_fuzz (dist, hclust), vec_fuzz (cut, .bincode, seq.int, median, sort), cor_fuzz (cor/cov mit allen use und Verfahren, cov2cor, scale), padj_fuzz (p.adjust, ecdf) und fmt_fuzz (sprintf, formatC, format, as.character, round, signif); approx_fuzz prüft zusätzlich filter() und regularize.values(). Abgedeckt sind NA, NaN, ±Inf, ±0, Bindungen, leere Eingaben, Nicht-ASCII und alle Methoden bzw. Optionen.

Nur R:

- Das Paket enthält keine C-Quellen mehr (`src/` nur C++, `CXX_STD = CXX17`). Die C++-Kerne bekommen dieselben Gleitkomma-Schalter wie in Python und Julia (`-ffp-contract=off -fno-fast-math`); auf x86-64 ohne FMA ändert das am Ergebnis nichts.
- `.sl_qt`/`.sl_pt` rufen die Kerne mit Threads (neue .Call-Hüllen in `src/prep_r.cpp`). Die Grundfunktionen von R rechnet R weiter selbst; die neuen Kerne `core/slc_rbase_*.cpp` gehen nur in Python und Julia.

Nur Python und Julia:

- Grundfunktionen von R im Kern: dist/hclust (Lance-Williams nach hclust.f), cut/.bincode, seq.int(length.out), median, cor/cov mit Rängen (kendall, spearman, alle use, paarweise), cov2cor, scale, regularize.values (approx, approxfun), filter (Faltung, rekursiv), p.adjust, ecdf, round/signif, formatReal/encodeReal, as.character für Zahlen, formatC und sprintf rechnet der gemeinsame C++-Kern (`core/slc_rbase2.h`, `core/slc_rbase_{clust,vec,cor,smooth,models,fmt}.cpp`); die Sprachen behalten dünne Hüllen. sprintf gibt es je Sprache nur noch einmal: Der schnelle Weg der Engine-Texte ruft denselben Kern wie die Vektorform, jede Umwandlung formatiert wie R über snprintf der C-Bibliothek. Die Nachbildung von `stats::optimize` rechnet Brent im Kern.
- Laufzeit (zusätzlich zu oben): portfolio_optimize(method = "hrp") mit 200 Anlagen in Python −27 %, print/summary in Python −50 %; withdrawal_simulation() mit 10.000 Pfaden in Julia −36 %, Dashboard in Julia −22 %.
- Berichtigt (momentum_score(), tactical_rotation()): Nicht aufsteigend sortierte Daten brechen wie in R mit „'vec' must be sorted non-decreasingly and not contain NAs“ ab (bisher ohne Fehler mit falschen Rückblicken).
- Berichtigt (dist, hclust): Eine mehrdeutige oder leere Abkürzung der Methode meldet wie R „invalid distance method“ bzw. „invalid clustering method …“ (bisher „ambiguous …“ bzw. bei dist "" die euklidische Distanz).
- Berichtigt (cut mit einer Anzahl von Intervallen): Enthält x ±Inf oder nur NA, bricht cut wie R ab („'from' must be a finite number“ bzw. „'to' must be a finite number“, bei nur NA mit den Warnungen von range(), bei nur +Inf bzw. nur −Inf „missing value where TRUE/FALSE needed“; bisher Grenzen aus nicht endlichen Werten).
- Berichtigt (filter, method = "recursive"): init als Vektor bzw. als Matrix mit einer Spalte bei mehreren Reihen bricht wie R ab („dims [product …] do not match the length of object […]“ bzw. „subscript out of bounds“; bisher für alle Reihen wiederholt).
- Berichtigt (round, signif): Ist x oder digits NA, ist das Ergebnis wie in R NA, sonst bei NaN NaN (bisher z. B. signif(NaN, NA) = NaN statt NA).
- Berichtigt (sprintf der Engine-Texte, r_sprintf): Breiten bei %s zählen wie in R Bytes (bisher Zeichen, z. B. sprintf("[%5s]", "äö") = "[ äö]" statt "[   äö]"); NaN in %d bricht wie in R ab. Die Pakete rufen r_sprintf nicht mit solchen Eingaben auf.

Nur Python:

- Berichtigt (r_sprintf): Wahrheitswerte in %x/%o brechen wie in R ab (bisher eine Zahl); in `simlev._r.fmt.sprintf` bricht ein Wahrheitswert als Argument von * wie in R ab („argument for '*' conversion specification must be a number“).
- bootstrap(): kein DataFrame-Aufbau mehr aus Teilblöcken je Pfad; der Rahmen entsteht ohne Kopie aus dem Ergebnis des Kerns.
- Schneller: sprintf in der Vektorform drei- bis zwanzigmal, formatC drei-, signif dreißigmal; Engine-Texte (r_sprintf) 1,0–1,7 µs statt 1,4–2,3 µs, mit %s von Zahlen 1,4 statt 11 µs. Die Erweiterung `simlev._ext` wird nur aus C++-Quellen gebaut (`MANIFEST.in`); `simlev/_r/_optim.py` entfällt.

Nur Julia:

- Berichtigt (r_sprintf): %x/%X mit den Flags + oder Leerzeichen schreiben wie glibc und R kein Vorzeichen (bisher "+ff"); %#s und NA mit %#G wie R ohne Anführungszeichen.
- momentum_score(): ohne die typinstabile Hilfe `_fill_na` (bei 200 Anlagen deutlich kürzer). bootstrap() kopiert die Zusatzreihen nicht mehr je Pfad (weniger Spitzenspeicher).
- Intern: die eigene snprintf-Anbindung (`_c_sprintf`, `_LIBC`) entfällt; r_sprintf 0,4–0,5 µs statt 0,55–0,8 µs je Aufruf, sprintf und formatC über 200 Werte 40 % bzw. 80 % schneller. `src/r/_optim.jl` entfällt.
- `deps/build.jl` übersetzt alle Quellen von `libslc` mit dem C++-Compiler (`ENV["SIMLEV_CXX"]`; `SIMLEV_CC` entfällt, beim Bau eine Warnung, falls gesetzt). `SIMLEV_THREADS` steht in `REnv.SWITCHES` und in `DEVELOPING.md`.

## SimLev.jl 1.5.2

Patch-Update (R/Python/Julia). Funde der Codeprüfung: schnellere Schleifen in Python, Julia und R, weniger doppelter und toter Code in Python und Julia; die Werkzeuge des Repositorys sind auf Python umgestellt. Ergebnisse, Ausgaben, Warnungen und Fehler bleiben bitgleich zu 1.5.1, außer der unten als „Berichtigt“ genannten Abweichung der Ports von R.

- Laufzeit gegenüber 1.5.1 (Median, alt und neu abwechselnd, ein Kern, 21 bis 150 Läufe je Aufgabe): Python backcast_fit() −57 %, rebalance_trigger() −81 %, scenario_entropy_pooling() −46 bis −72 %, simulation() −11 bis −34 %, overfit_pbo() −12 bis −32 %, dependence_analysis() −26 %, series_align() −25 %; Julia overfit_walk_forward() −75 %, simulation() mit Signalspalten −16 bis −27 %; R bootstrap() −23 %. Keine andere Aufgabe messbar langsamer.
- Werkzeuge: Die Shell-Skripte sind durch Python-Skripte ersetzt (Python 3.10 oder neuer, nur Standardbibliothek; gleiche Optionen, Ausgaben, Protokolle und Rückgabewerte): `tests/run.py` (bisher `tests/run.sh`), `tests/schnittstelle/run.py`, `tests/werkzeuge/gleichlauf/run.py`, `tests/werkzeuge/bench/run.py`, `tests/werkzeuge/erzeugen.py`; die Doku-Beispiele prüft `tests/werkzeuge/doku/beispiele.py` ohne Dateiangabe selbst (bisher `beispiele.sh`). Das Repository braucht damit keine Bash mehr; R, Python und Julia bleiben dort, wo sie die Pakete ausführen (Generatoren, Testläufer, Vergleiche).
- Tests (Ordner tests des Repositorys): neue Zufallsprüfung libm_fuzz im Gleichlauf mit 1.5.1 als Referenz (libm elementweise mit NA, NaN, ±Inf, ±0 und subnormalen Zahlen, Pseudo-Beobachtungen, rebalance_trigger(), doppelte Tage in series_align() und simulation(), scenario_entropy_pooling()). Der Referenzfall dependence/kendall_und_copulas setzt das NA in die letzte Spalte: R 4.3.3 liest in stats::cor(method = "kendall") mit NA einen nicht gesetzten Wert (cov_na_1 in stats/src/cov.c) und warnte deshalb zufällig „the standard deviation is zero“. Die Referenzfälle der entfallenen uniroot-Nachbildung und von .ldmvn entfallen.

Nur R:

- bootstrap() und die Studien darüber: Die Pfade aus den Renditen (.build_path) entstehen in einer Spaltenschleife statt mit apply() (gleiche Werte und Namen).
- Intern: unbenutzte Argumente entfernt (.sim_build_state, .sim_build_calendar, .resolve_auto, .get_base_params, .ess_design, .wd_tariff_years); .ldmvn entfällt (ohne Aufrufer seit 1.5.0, regime_hmm rechnet im Kern).

Nur Python und Julia:

- Berichtigt (signif() der Engine-Textausgabe, r_signif): Nicht ganzzahlige digits werden wie in R mit C-round() gerundet (bisher Runden auf gerade, z. B. signif(x, 2.5) mit 2 statt 3 Stellen). Die Pakete rufen r_signif nur mit ganzzahligen Stellen auf; über die öffentliche Schnittstelle nicht erreichbar.
- Eine Formatierungsschicht: Runden (round, signif) und formatReal/encodeReal der Engine-Textausgabe (rformat) rechnen die Funktionen der R-Formatierung (fmt bzw. RFmt; bisher eine zweite Nachbildung). Die skalare sprintf()-Fassung der Engine bleibt (schneller; nicht in allen Randfällen gleich der vollen Fassung).
- Entfallen (ohne Aufrufer): die Nachbildung von stats::uniroot mit R_zeroin2 (XIRR rechnet seit 1.4.0 der Kern), isSymmetric, _row_means, _max_col_first, _ldmvn und weitere Hilfen; unbenutzte Argumente wie in R.

Nur Python:

- libm elementweise (exp, log, log1p, expm1, log2, log10, ^) rechnet für Felder eine C-Schleife mit denselben glibc-Funktionen (core/slc_rbase.c, sl_r_math1 und sl_r_pow_rec) statt math.* je Element in Python; Skalare wie bisher.
- scenario_entropy_pooling(): R-min/max ohne Python-Schleife, das duale Problem wird je Punkt einmal ausgewertet (Ziel und Gradient teilen sich das Ergebnis). Ein Aufruf mit unerfüllbarer Annahme (400 Zeilen, Optimierer bis an die Grenze) braucht 5,5 statt 26,8 s CPU (R 7 s).
- simulation(): doppelte Tage ohne Python-Schleife (die Daten sind dort sortiert); series_align() und weitere: duplicated() für Zahlen ohne Schleife; rebalance_trigger() ohne float()/np.isnan je Tag; Pseudo-Beobachtungen der Copulas über den Rang-Kern (sl_r_rank).
- Gemeinsame interne Hilfen in simlev/_util.py (match.arg in zwei Fassungen, cov2cor, späte Importe u. a.) statt Weiterleitungen und Kopien je Modul.

Nur Julia:

- overfit_walk_forward(): Fenstergrenzen vor der Suche gebunden (bisher dynamischer Feldzugriff je Tag).
- simulation() mit Signalspalten: Umwandlung der Signale hinter einer Funktionsgrenze (je Spaltentyp übersetzt).

## SimLev.jl 1.5.1

Patch-Update (R/Python/Julia). Technische Korrekturen nach der Messung der Laufzeiten: Datumsrechnung, Fensterrenditen, NAV der Fonds-Wrapper im gemeinsamen Kern, Prüf-Cache der Studien. Ergebnisse, Ausgaben, Warnungen und Fehler bleiben bitgleich zu 1.5.0; Python und Julia sind in den unten genannten Fällen jetzt wie R.

- wrapper_nav() und Wrapper-Assets in simulation(): Die Tagesschleife des Anteilswerts (Verwaltungsgebühr je Kalendertag, Performancegebühr über der High Water Mark, Festschreibung am Jahresende) rechnet der gemeinsame Kern (core/wrapper_core_impl.h). Innere Rechnung, Auswahl der NAV-Tage und Meldungen bleiben in der Sprache.
- Studien über simulation() (bootstrap_study(), param_search(), sensitivity_grid(), sensitivity_rebalancing(), sensitivity_leverage(), planning_lumpsum_vs_dca()): Prüf-Cache je Studie. Prüfungen und Umwandlungen, die ohne Meldung durchgingen und sich zwischen den Läufen nicht ändern (Datumsspalte, eindeutige Tage; in R auch die Prüfung der Strategie und der Kalendertage), rechnet simulation() nur einmal je Studie. Meldungen, Warnungen und Fehler entstehen weiter je Lauf in gleichem Inhalt, gleicher Reihenfolge und Anzahl.
- Tests (Ordner tests des Repositorys): drei neue Zufallsprüfungen im Gleichlauf mit 1.5.0 als Referenz (nav_fuzz: wrapper_nav; rolling_fuzz: portfolio_rolling, result_analysis, Periodenrenditen; study_fuzz: Studien mit allen Meldungen in Reihenfolge; quick je 300, full je 2.000 Fälle); pbo_fuzz prüft auch ±Inf und S ≥ 34.
- R: Datumsrechnung ohne POSIXlt je Tag. result_analysis() (Monats- und Jahresschlüssel, Fensterlängen der rollierenden Kennzahlen), portfolio_rolling() und die Periodenrenditen von dependence_analysis(), portfolio_optimize() und weiteren Funktionen mit Kursdaten (ISO-Woche, Monat), die Entscheidungstermine der taktischen Funktionen und wrapper_nav() (Jahr je Tag, Abgleich der Tage) rechnen Jahr, Monat und Woche ganzzahlig aus der Tageszahl statt über format() bzw. match() auf Texten; format() nur noch für die wenigen ausgegebenen Schlüssel.
- Laufzeit gegenüber 1.5.0 (Median, alt und neu abwechselnd, ein Kern, 42 bis 168 Läufe je Aufgabe): wrapper_nav() R −78 %, Python −47 %, Julia −40 %; result_analysis() R −49 %, Julia −34 % (Python unverändert); portfolio_rolling() R −14 %, Python −88 % (263 → 32 ms); backcast_fit() Julia −89 % (47 → 5 ms); Studien: param_search() R −7 %, Python −8 bis −14 %, Julia −31 bis −51 %; bootstrap_study() Python −19 %, Julia −20 % (R unverändert); sensitivity_grid() Python −13 %, Julia −20 %; planning_lumpsum_vs_dca() R −7 %, Python −18 %, Julia −27 %. Übrige Aufgaben unverändert (innerhalb der Messstreuung).

Nur Python und Julia:

- Berichtigt (overfit_pbo(), wie R): Spalten, deren Standardabweichung wegen ±Inf nicht definiert ist (NaN), gelten nicht als „ohne Schwankung“ (bisher ausgeschlossen, mit Folgefehler „Mindestens zwei Punkte nötig.“ bzw. „alle Spalten ohne Schwankung“); log1p() warnt bei Renditen unter −1 und −Inf mit „NaNs produced“; ohne ein gültiges Paar von In- und Out-of-Sample-Kennzahl meldet die Regression wie R „lm: Längen von x und y passen nicht“ (bisher „lm: 0 (nicht-NA) Fälle“ bzw. kein Fehler).
- Berichtigt (overfit_pbo()): Bei S ≥ 34 (mehr als 2^31 − 1 Aufteilungen) bricht die Funktion wie R sofort mit der Warnung „NAs introduced by coercion to integer range“ und dem Fehler „invalid 'ncol' value (too large or NA)“ ab, statt alle Kombinationen aufzubauen (Python lief bisher aus dem Speicher); die Aufteilungen liegen als ganzzahlige Matrix vor (wie R), ohne Zwischenliste.
- Berichtigt (result_analysis()): Hat das Fenster der rollierenden Kennzahlen eine Benchmark ohne Schwankung, ist beta wie in R Inf bzw. NaN (Python brach bisher mit ZeroDivisionError ab); liegen die gemeinsamen Tage in genau zwei Kalendermonaten, meldet die Funktion wie R den Fehler von cor() („supply both 'x' and 'y' or a matrix-like 'x'“).

Nur Python:

- portfolio_rolling(): Kurse, Prüfung, Periodenwechsel und Fortschreiben werden einmal je Aufruf aufbereitet statt je Fenster über pandas; die Renditen je Fenster entstehen daraus mit numpy (gleiche Zahlen, Meldungen und Fehler je Fenster wie bisher).
- Studien: Die Umwandlung der Datumsspalte (pandas → Tage) und die Prüfung auf doppelte Tage entfallen ab dem zweiten Lauf einer Studie (Prüf-Cache), in planning_lumpsum_vs_dca() auch für die Zeitfenster der Daten.
- Paket: Lizenzangabe nach PEP 639 (license = "GPL-3.0-only" als SPDX-Ausdruck, license-files = LICENSE.md und COPYRIGHTS.md in [project]; die Lizenz-Klassifikation entfällt); der Bau braucht setuptools ≥ 77.0.3 (pip baut mit Build-Isolation). Das Wheel enthält LICENSE.md und COPYRIGHTS.md unter dist-info/licenses.

Nur Julia:

- backcast_fit(): Die Modellrenditen je Parametersatz (_bc_model_returns) rechnen typstabil in eigenen Schleifen (bisher dynamische Aufrufe je Tag, 5,6-mal langsamer als R).
- result_index() (und damit param_search() und andere Studien): Die Zahlungen je Tag werden ohne neuen Vektor je Tag summiert.

## SimLev.jl 1.5.0

Minor-Update (R/Python/Julia). Rechenintensive Teile laufen jetzt im gemeinsamen C/C++-Kern (core/) statt in jeder Sprache für sich. Ergebnisse, Ausgaben, Warnungen und Fehler bleiben bitgleich zu 1.4.3; Python und Julia sind in den unten genannten Fällen jetzt wie R.

- withdrawal_simulation(), withdrawal_max_rate(), withdrawal_perfect_rate(): Die Kennzahlen je Pfad (mittlere, kleinste und sicherheitsäquivalente Entnahme, Drawdown der Entnahmen, Summe; auch bis zum Horizont), die Perfect Withdrawal Rate mit ihren Prüfungen, die realen Jahresrenditen aus Perioden und die Jahreszeilen des Tarifwegs rechnet der Kern (core/withdrawal_core_impl.h). Meldungen und ihre Aufrufe bleiben unverändert.
- regime_hmm(): Der Baum-Welch-EM (E- und M-Schritt, Log-Dichten, Abbruchtest) läuft im Kern (core/research_core_impl.h); Startwerte und Zufall bleiben in der Sprache.
- planning_goal(): Die Rückwärtsrekursion über das Vermögensgitter (Wertfunktion, Interpolation auf der Probit-Skala, Politik je Periode) läuft im Kern; Gitter und Vorwärtssimulation bleiben in der Sprache.
- overfit_pbo(): Die Aufteilungen der CSCV (In- und Out-of-Sample-Kennzahlen, bester Punkt, Rang, Logit, Median) laufen im Kern.
- Laufzeit gegenüber 1.4.3 (Median über 21 Läufe, alt und neu abwechselnd, ein Kern): regime_hmm (k = 2, Wochendaten) R −76 %, Python −72 %, Julia −79 %; overfit_pbo (S = 16) R −86 %, Python −64 %, Julia −50 %; planning_goal (n_grid 101, n_sim 1.000) R −43 %, Python −96 % (5,4 s → 0,23 s), Julia −49 %; withdrawal_simulation (2.000 Pfade, 30 Jahre) R −88 %, Python −81 %, Julia −37 %, mit Einkommensteuertarif R −55 %, Python −30 %, Julia −17 %; withdrawal_max_rate R −75 %, Python −80 %, Julia −21 %. Übrige Aufgaben unverändert (innerhalb der Messstreuung).
- Tests (Ordner tests des Repositorys): fünf neue Zufallsprüfungen im Gleichlauf mit 1.4.3 als Referenz (approx_fuzz, wd_fuzz, hmm_fuzz, goal_fuzz, pbo_fuzz; quick je 300, full je 2.000 Fälle).

Nur Python und Julia:

- approx() und approxfun() (und damit planning_goal(), Szenarien, backcast_fit()) interpolieren im Kern (core/slc_rbase.c, wie R's approx.c); in Python fällt die langsame Schleife weg.
- Berichtigt: approx(x, y, n = …) ohne xout meldet bei nicht endlichen Grenzen wie R „'from' must be a finite number“ bzw. „'to' …“ (bisher kein Fehler), und bei ganzzahligen Grenzen und Schrittweite liefert es wie R 0 statt −0.

Nur Python:

- Berichtigt: regime_hmm() gibt bei einer Übergangswahrscheinlichkeit 1 (erwartete Dauer unendlich) wie R keine Warnung „divide by zero“ mehr aus.

## SimLev.jl 1.4.3

Patch-Update (R/Python/Julia). Ergebnisse und Meldungen bleiben unverändert, die Druckausgabe ändert sich nur durch zwei Korrekturen (unten); dazu ergänzt 1.4.3 Dateien, die in 1.4.2 fehlten, und ersetzt die Beispieldaten.

- Vollständigkeit: Julia: src/result.jl (Ergebnisobjekt SimLevResult mit print und summary) fehlte in 1.4.2, obwohl SimLev.jl die Datei einbindet; das Paket ließ sich daher nicht laden. R: die Hilfeseiten momentum_score.Rd und result_analysis.Rd fehlten in 1.4.2 und sind ergänzt.
- Beispieldaten: anlageklassen.csv neu erzeugt (in allen drei Paketen, mit Erzeugerskript). Rendite, Volatilität und Korrelation sind jetzt runde, hypothetische Annahmen zur Konstruktion eines Beispieldatensatzes (Rendite/Volatilität p. a.: Aktien 9 %/16 %, Anleihen 5 %/6 %, Rohstoffe 7 %/16 %, Managed Futures 8 %/10 %), kein Abbild realer Märkte; in 1.4.2 folgten sie Abrams, Bhaduri und Flores (2012), der Abschnitt „Beispieldaten“ in LITERATUR.md entfällt. Fallstudie im README, Tutorials und Abbildungen mit den neuen Daten neu gerechnet.
- Druckausgabe berichtigt (Zahlen unverändert): Im Druck von withdrawal_simulation() (summary) stehen fehlende Werte („–“) wieder rechtsbündig in ihrer Spalte; die Breite wurde mit sprintf("%10s") in Bytes statt Zeichen bemessen, und der Gedankenstrich hat in UTF-8 drei Bytes, die Zeile war daher je Spalte um zwei Zeichen zu kurz (R, Python und Julia). Julia: display() hängt an Ergebnisobjekte, deren Druck schon mit einem Zeilenumbruch endet (z. B. Optimierung, Parametersuche, sharpe_deflated, overfit_pbo), keine Leerzeile mehr an; die Ausgabe gleicht damit der von R und Python.
- Dokumentation: Versionsnamen statt Commit-Verweisen; der frühere Stand des R-Pakets heißt „0.5.0 (Vorfassung vor den Korrekturen)“ (erklärt in der Einleitung von r/NEWS.md).
- Tests: Der Abgleich der Beispielausgaben (tests/werkzeuge/doku/beispiele.py) vergleicht auch Leerzeilen; die Entnahme-Fälle in gleichlauf und fehler sind an den berichtigten Druck angepasst.

## SimLev.jl 1.4.2

Patch-Update (R/Python/Julia). Ergebnisse, Ausgaben und Meldungen bleiben unverändert; neu sind Dokumentation, Hilfe, Beispieldaten und die Gliederung der Tests.

- Dokumentation: Das Haupt-README ist eine Fallstudie (Aktien, Anleihen, Rohstoffe und Managed Futures für einen deutschen Privatanleger, Ansparphase und Entnahme) mit Code in R, Python und Julia und echten, in allen drei Sprachen gleichen Ausgaben, dazu ein Haftungsausschluss. Je Sprache ein Tutorial mit denselben Kapiteln (R: Vignette, Python und Julia: examples/tutorial.md); das frühere R-Tutorial inst/tutorial geht darin auf. Kurze Sprach-READMEs, DEVELOPING je Sprache, Zuordnung der Funktionen in STRUKTUR.md und Quellen in LITERATUR.md; der Ordner docs entfällt, die Bilder liegen bei den Paketen. Alle drei Sprachen sind gleichrangig beschrieben: Die Rechenkerne liegen als gemeinsamer C/C++-Code in core/, die Sprachpakete bilden die Schnittstelle darum.
- Beispieldaten: anlageklassen.csv (synthetische Tageskurse für Aktien, Anleihen, Rohstoffe und Managed Futures 2005–2024; Rendite, Volatilität und Korrelation nach Abrams, Bhaduri und Flores 2012) mit Erzeugerskript, in allen drei Paketen.
- Hilfe: Alle 116 Exporte haben in R, Python und Julia Beschreibung, Argumente, Rückgabe und ein lauffähiges Beispiel; Python- und Julia-Docstrings inhaltlich gleich der R-Hilfe. Berichtigt: withdrawal_simulation ohne das nicht vorhandene Argument sparer_pauschbetrag, die alten Einzelargumente galten bis 0.8.0, DCC-Schätzung mit BFGS (Nelder-Mead nur als Rückfall).
- Quelltext: Kommentare überarbeitet, ohne interne Arbeitsstände; Maschinencode der C/C++-Kerne unverändert.
- Tests (Ordner tests des Repositorys, nicht Teil der Pakete): nach Zweck gegliedert in methodik (Steuerrecht, Tarif, Engine, Entnahme, Kennzahlen, C-Bibliothek; Erwartung aus Gesetz, Handrechnung, Formel bzw. Testvektoren), gleichlauf (alle drei Sprachen rechnen bitgleich), fehler, ausgabe, schnittstelle und werkzeuge, mit einem Einstieg je Sprache und tests/run.sh. Aus 1.364 Referenzfällen werden 347 Tests: Szenarien, die mehrere Ergebnisse zugleich prüfen (in sechs Bereichen als Aufrufketten), und Tabellen „Eingabe → Meldung“ bzw. „Eingabe → Wert“; 5,2 statt 6,5 MB, Zeilenabdeckung in R, C/C++, Python und Julia unverändert, alle bisher geprüften Meldungen bleiben geprüft. Die methodik-Tests stehen als Tabellen mit Quelle je Zeile; die erwarteten Werte sind unverändert.
- Intern: SimLev.REnv ohne full_tests(), golden_dir() und module_dir() (SIMLEV_FULL_TESTS, SIMLEV_GOLDEN_DIR und SIMLEV_MODULE_DIR wirkten seit 1.4.1 nicht mehr).

## SimLev.jl 1.4.1

Patch-Update (R/Python/Julia). Ergebnisse und Meldungstexte bleiben gleich; in R ändert sich nur die Kopfzeile der Meldungen aus dem Kern (unten).

- R: Abbrüche und Warnungen aus dem Kern von simulation(), die bis 1.4.0 als Aufruf (conditionCall) einen festen Ausdruck der früheren Phasen trugen (Aufrufe von .perform_trade_buy, .perform_trade_sell und .perform_asset_split, if-Bedingungen mit NA, max() ohne Werte, stats::uniroot im internen Zinsfuß), nennen jetzt den Aufruf von simulation() wie die Eingabeprüfungen; bei der Ausgabe ändert sich nur die Kopfzeile (z. B. „Fehler in simulation(d, s, splits = split_rule(…))“ statt „Fehler in .perform_asset_split(…)“), der Meldungstext bleibt wortgleich. Warnungen des internen Zinsfußes außerhalb von simulation() (MWRR in result_analysis) tragen keinen Aufruf mehr. Python und Julia sind nicht betroffen (sie bilden keine R-Aufrufe nach).
- Tests: Alle Tests liegen in einem eigenen Ordner tests des Repositorys mit einem Katalog (README): Referenzfälle aus R, eine Datei je Bereich (12 statt 4.449 Dateien, 6,5 statt 43 MB), ihre Generatoren, die Suiten für R, Python und Julia, der Gleichlauf, die eingefrorene Schnittstelle und die Laufzeitmessung. Die Ordner golden und tools sowie die Testordner der drei Pakete entfallen; die Pakete brauchen zum Bauen und Prüfen keine Tests. Den Abgleich der C-Kopien macht jetzt core/sync.py. Von 4.479 Referenzfällen (4.395 Modul- und 84 Engine-Fälle) bleiben 1.364: die je Fall gemessene kleine Fallmenge, die in R (mit C/C++), Python und Julia dieselben Codezeilen erreicht wie alle Fälle zusammen (Zeilenabdeckung erhalten), dazu je exportierter Funktion ein Fall. Die Generatoren erzeugen weiter alle Fälle (bis auf einen: die Warnung von cor(…, use = "everything", method = "kendall") mit NA ist in R 4.3.3 nicht reproduzierbar); der Gleichlauf vergleicht Python und Julia mit allen. Die Eingabeprüfungen von asset_config(), create_strategy(), strategy_validate(), strategy_update_asset(), tax_profile() und simulation() (Listen-Strategie, risk_free- und Basiszins-Spalte) sind Referenzfälle im Bereich wrapper und werden in allen drei Sprachen gegen R geprüft.

## SimLev.jl 1.4.0

Minor-Update (R/Python/Julia). Ergebnisse, Ausgaben, Warnungen und Fehler bleiben bitgleich zu 1.3.0 (R); Python und Julia sind in den unten genannten Fällen jetzt wie R.

- simulation(): Die Engine ist ein gemeinsamer C++-Kern für R, Python und Julia (core/engine_core_impl.h, core/prepare_core_impl.h, core/evaluate_core_impl.h). Er umfasst die Tagesschleife (Kauf, Verkauf, Sparplan, Rebalancing, Liquidation), die Steuerphasen (Jahreswechsel, Vorabpauschale, § 23, Günstigerprüfung und Tarif, Verkäufe zum Ausschöpfen des Freibetrags, Steuerzahlung, Splits), die Vorbereitung (Termine wie seq.Date, Flags, Anfangszustand) und die Auswertung (Renditen, XIRR, Risikokennzahlen). Warnungen, Fehler und details-Ausgaben gibt der Kern als Codes aus; die Texte setzen die Sprachen wortgleich und in derselben Reihenfolge wie bisher. In den Sprachen bleiben Eingabeprüfung, Datenaufbereitung, Ergebnisobjekte, print, summary und plot sowie die Kennzahl-Helfer calculate_*.
- Laufzeit gegenüber 1.3.0 (tools/bench, Median über 6 Runden, alt und neu abwechselnd): S30 (eine Simulation über 30 Jahre mit Sparplan, Rebalancing und Steuer) R −94 %, Python −79 %, Julia −39 %; T3 (bootstrap_study mit Simulation je Pfad) R −64 %, Python −30 %, Julia −23 %. Aufgaben ohne simulation() unverändert im Rahmen der Messstreuung.
- Python und Julia (Abweichungen von R behoben): NA in einer Signalspalte bricht nicht mehr ab, sondern wirkt wie in R (kein Handelstag; an einem Jahreswechsel Abbruch wie R mit „missing value where TRUE/FALSE needed“), auch bei Signalen ohne Bestand bzw. ohne Geld. risk_free als logische oder Text-Spalte wird wie as.numeric gelesen, mit der Warnung „NAs introduced by coercion“. Ein Terminplan mit Spanne 0 oder negativ bzw. mit Start nach dem letzten Tag meldet den Fehler wie R statt in eine Endlosschleife zu laufen. NA in Bedingungen der Auswertung bricht wie in R ab, statt weiterzurechnen.
- Julia: Erster Aufruf jeder Hauptfunktion in einem frischen Prozess höchstens etwa 1 s (vorher bis 6 s); dafür Vorkompilieren etwa 240 s und Cache etwa 118 MB. Die Feldgrößen der flachen Felder zwischen Julia und der C-Hülle werden beim Vorkompilieren abgeglichen.
- Gleichlauf: Zufallsprüfungen über simulation() (sim_fuzz), Terminpläne (sched_fuzz) und Kennzahlen (metric_fuzz) mit Referenz aus R 1.3.0 in tools/gleichlauf/run.sh.

## SimLev.jl 1.3.0

Minor-Update (R/Python/Julia).

- withdrawal_simulation: Tarifweg mit tax_profile(income = income_tariff(...)). Veranlagung je Planjahr und Pfad mit Einkommensteuer, Solidaritätszuschlag, Kirchensteuer, Günstigerprüfung und Kirchensteuer-Saldo des Vorjahres, gerechnet wie in simulation() (gemeinsamer Kern core/tariff_core_impl.h, bitgleich zu den R-Funktionen von simulation()). Der Saldo eines Jahres wird mit der ersten Entnahme des Folgejahres gezahlt bzw. mindert sie; eine Erstattung über die Entnahme hinaus fließt ins Depot. Am Pfadende und am Horizont wird sofort abgerechnet. Das zu versteuernde Einkommen gilt nominal wie angegeben (eine Zahl für alle Planjahre oder ein Vektor der Länge Planjahre; nach Kalenderjahren benannt nur mit einem SimLevResult als start_value). Das Argument income (z. B. Rente) zählt nicht dazu; den steuerpflichtigen Teil rechnen Nutzer selbst in taxable_income ein. Kirchensteuer und Günstigerprüfung werden wie bisher ausdrücklich in tax_profile() angegeben, nichts wird aus der Ansparphase übernommen. Neues Ergebnisfeld tariff_years (nur mit Tarifweg). Ohne Tarifweg bleiben alle Ergebnisse gleich.
- income_tariff() nimmt einen Vektor ohne Namen an; simulation() meldet einen solchen Vektor jetzt beim Lauf statt beim Aufruf von income_tariff().
- Python und Julia: Datumsformat mit allen strftime-Schaltern, Breiten und E/O-Formen wie R unter Linux (glibc); %OS beachtet digits.secs der internen Optionen; leeres Format und Ergebnisse über 2048 Bytes wie in R.
- Python und Julia: Zahlenlesen wie as.numeric (mehr als 17 Ziffern, Überlauf knapp über DBL_MAX, Hex-Zahlen mit sehr kleinem Exponenten, "-nan", "0x ") und %% bzw. %/% einschließlich NaN-Vorzeichen jetzt wie R; Python rechnet ohne numpy.longdouble über den gemeinsamen Kern core/slc_rbase_num.c.
- Dokumentation: Quelle zu regime_hmm berichtigt (Nystrup u. a. 2015, Journal of Portfolio Management 42(1)), Rabiner (1989) und Schwarz (1978) ergänzt; Quellen und Abweichungen für die Entnahmeregeln clyatt, endowment, sensible, hebeler, cape, one_over_n und abw.
- Herkunft und Rechte: einheitlicher Herkunftsblock in den Dateiköpfen; die gemeinsamen Kerne core/slc_rbase* sind als Nachbildung von R-Quellen ausgewiesen; COPYRIGHTS in allen drei Paketen gleich gegliedert (u. a. Singleton-Quicksort, Brent, hclust, Kalenderalgorithmen nach Hinnant); das Python-Wheel enthält COPYRIGHTS.md.
- Gleichlauf: Zufallsprüfungen für NA/NaN in den Engine-Kernen, Datum, R-Grundfunktionen und Tarif laufen in tools/gleichlauf/run.sh mit; R und Python werden dort stets vollständig neu gebaut.

## SimLev.jl 1.2.0

Minor-Update (R/Python/Julia).

- sGARCH-Schätzung in einem einzigen Lauf: Trust-Region-Newton mit exakter Hesse-Matrix (Likelihood, Gradient und Hesse-Matrix in einem Durchlauf) auf den natürlichen Parametern mit den Schranken omega, alpha, beta >= 0 und alpha + beta < 1; der Startpunkt wird ohne Optimierung aus 12 Kandidaten (Variance Targeting und Momentenschätzer) nach der Likelihood gewählt. Ein Fit kann den Rand alpha = 0 so wieder verlassen. Auf 160 Prüfreihen stets der beste bekannte Wert (1.1.0: 38-mal darunter), auf 720 neuen simulierten Reihen 18-mal darunter (1.1.0: 213-mal); im Mittel schneller als 1.1.0. sGARCH-abhängige Ergebnisse (GARCH-Bootstrap, DCC) ändern sich. Die Persistenz am Rand ist jetzt genau 1 - 2^-50, die IGARCH-Warnung kann daher häufiger erscheinen.
- MS-GARCH: Likelihood und Gradient in einem Durchlauf, eigene Fassung für 2 und 3 Regime; etwa 1,6- bis 1,8-mal schneller bei gleichen Ergebnissen. Die Starts laufen mit cores > 1 parallel (POSIX-Threads, unter Windows nacheinander); das Ergebnis hängt nicht von der Thread-Zahl ab.
- Eine Bibliothek für alle Sprachen: Julia rechnet die Kerne von Engine, Steuer, FIFO, Entnahme und Research über dieselben C++-Kerne wie R und Python (C-Schnittstelle core/simlev_cabi.cpp); die eigenen Julia-Nachbauten entfallen. Julia braucht dafür einen C++-Compiler.
- Python und Julia rechnen die Nachbildungen der R-Grundfunktionen (Summen, Kumulationen, Sortierung, Rang, Quantile, tabulate, findInterval, cov/cor) über einen gemeinsamen C-Kern (core/slc_rbase*); Python bis zu 3-mal, Julia bis zu 1,5-mal schneller in den betroffenen Aufgaben. Kleine Randfälle (x^NA, findInterval mit einem Stützpunkt, Kendall mit Inf) verhalten sich jetzt wie in R.
- Engine-, Steuer- und FIFO-Kerne: Treffen NA und NaN in einer Rechenoperation zusammen, gilt die dokumentierte Regel „NA vor NaN“, unabhängig von Compiler und Operandenreihenfolge. R, Python und Julia rechnen damit auch in solchen Randfällen bitgleich; in R ändern sich nur NA/NaN-Randfälle, Ergebnisse mit gewöhnlichen Zahlen bleiben gleich.
- Python und Julia formatieren Datumswerte (strftime-Formate einschließlich %OSn) und lesen as.Date im Format %Y-%m-%d über einen gemeinsamen C-Kern (core/slc_rbase_date.c); die eigenen Nachbildungen entfallen. Python ist in den Aufgaben T5–T7 um etwa 50–80 % schneller.
- Julia rechnet Summen, Mittel und Kumulationen in erweiterter Genauigkeit sowie das Zahlenlesen wie R_strtod, %%, %/% und scientific() über die C-Kerne core/slc_rbase* (neu: core/slc_rbase_num.c); die eigene long-double-Nachbildung (ld80.jl) entfällt.

## SimLev.jl 1.1.0

Minor-Update (R/Python/Julia).

- GARCH-Schätzung: analytischer Gradient für sGARCH und GJR-GARCH (f und g in einem Durchlauf, ganz im C-Kern); GJR-Fit etwa 13-mal, sGARCH-Fit etwa 8- bis 11-mal schneller bei gleicher oder besserer Likelihood. GARCH-abhängige Ergebnisse (GARCH-Bootstrap, DCC) ändern sich in den letzten Stellen.
- GPD-, DCC- und Backcast-Schätzung mit analytischem Gradienten: GPD-Fit etwa 2,5-mal, backcast_fit (rmse, mse, hybrid; Zielfunktion jetzt ganz im C-Kern) etwa 5- bis 7-mal schneller, bei gleicher oder besserer Güte. DCC mit BFGS statt Nelder-Mead: schneller und häufig mit besserer Likelihood, in Einzelfällen (2–6 %) aber in einem anderen lokalen Optimum mit geringerer Likelihood als 1.0.0. Die abhängigen Ergebnisse (EVT, dependence_dcc, backcast_fit) ändern sich.
- Genauigkeit: Steuerkern und Kendall-Tau ohne long double (kompensierte Summen bzw. exakte Ganzzahlrechnung), damit plattformunabhängig und korrekt gerundet; keine Ergebnisänderung.
- Entnahme: withdrawal_simulation rechnet mit Kirchensteuer und Günstigerprüfung über income_rate() (gemeinsamer Steuersatz-Baustein mit simulation()); income_tariff() ergibt dort einen Fehler mit Verweis auf income_rate(). Angaben der Ansparphase werden nicht übernommen, sondern in tax_profile() angegeben.
- keep_paths: TRUE behält alle Pfade, eine Zahl k die ersten k (bootstrap_study, withdrawal_simulation); ungültige Werte ergeben einen Fehler. Vermögensfächer mit Titelzusatz „(erste k von n Pfaden)“; Chunk-Dateien tragen bei k > 0 den Zusatz _keep<k>. Geändert: bootstrap_study(keep_paths = TRUE) behielt bisher still einen Pfad.
- keep_returns: param_search(keep_returns = c("day", "none")); TRUE/FALSE ergeben einen Fehler mit Hinweis auf die neuen Werte.

## SimLev.jl 1.0.0

Major-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Rechenkern: eigene C-Bibliothek für alle drei Sprachen (Julia per ccall): Zufallsgenerator, Verteilungen, lineare Algebra, Optimierer, GARCH/GJR-, GPD-, DCC- und MS-GARCH-Schätzung, Stineman-Interpolation, Glättungsspline, Kerndichte; geschrieben nach Fachliteratur.
- Unabhängigkeit: kein Code aus evd, imputeTS, stinepack, rugarch, Rsolnp, truncnorm oder numDeriv mehr; die Pakete stehen nur noch im Literaturverzeichnis.
- Zufall: eigener Generator mit simlev_seed() und seed-Argument; set.seed steuert SimLev nicht mehr; Ergebnisse unabhängig von cores und in R, Python und Julia gleich. Zufallsergebnisse ändern sich gegenüber 0.10.0.
- Schätzer: GJR-GARCH mit gamma < 0 unter alpha + gamma >= 0 und Stationarität (im Vergleich mit rugarch 51 von 51 Fällen gleichwertig oder besser); MS-GARCH mit analytischem Gradienten; t-Copula über ein Profil in nu mit Gauss-Grenzfall; qnorm mit eigenen Startnäherungen, rnorm und rgamma schneller als in R.
- Geändert: GARCH-Label "ml", dependence_dcc deterministisch; set_seed und rng_kind in Python und Julia entfallen; C-Bibliothek in Python und Julia Pflicht.
- Doku: Literaturabschnitt mit 112 geprüften Quellen, COPYRIGHTS und NEWS neu; Schnittstelle neu eingefroren.

## SimLev.jl 0.10.0

Minor-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Wrapper: wrapper_config() und asset_config(wrapper = ) bilden einen Zertifikat- bzw. Fonds-Wrapper als eigene Kursreihe ab (wrapper_nav()); innere Assets mit eigenem Umschichten und Orderkosten, tägliche Verwaltungs- und Performancegebühr mit High-Water-Mark; außen gelten Spread, Gebühren und Steuern wie bei jedem Asset.
- Geändert: asset_config() hat den Standard-Spread 0; der alte Fondsmodus simulation(funds = ) entfällt.
- Strategien: strategy_from_weights() und portfolio_template() nehmen Wrapper je Asset.
- Qualität: NaN-Randfälle der reinen Python- und Julia-Kerne an R angeglichen; Messskript überschreibt keine Ergebnisse.

## SimLev.jl 0.9.1

Patch-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Python: C-Erweiterung mit denselben Kernen wie R (Engine, FIFO, Steuer, Research, Entnahme, Abhängigkeit, Bootstrap, MS-GARCH-Filter), Zufallszahlen bitgleich zu R; reines Python bleibt als Rückfall.
- R: Parallelität gebündelt (wenige Forks statt einer je Einheit), z. B. bootstrap mit 2 Kernen 2,2 s -> 0,2 s.
- Ergebnisse in allen drei Sprachen unverändert.

## SimLev.jl 0.9.0

Minor-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Namen: einheitliche Benennung der Funktionen und Argumente in allen drei Sprachen (Tabelle alt -> neu im Abschnitt 0.5.0).
- Simulation: simulation() mit Bausteinen sim_costs, dca_plan, rebalance_plan, split_rule, tax_profile und funds_costs; Pfadnotation wie "dca.value" für Raster und Suchräume.
- Aufrufer: Bootstrap-Studien, Parametersuche, Sensitivitäten und Planung gehen über simulation(); Optionen nur noch als Schlüsselwort.
- Schnittstelle: Stand der drei Sprachen eingefroren und automatisch abgeglichen.

## SimLev.jl 0.8.0

Minor-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Prüfwerkzeuge: Abgleich der Schnittstelle der drei Sprachen (tools/api_snapshot), Referenzfälle in kompaktem Format mit gemeinsamen Eingaben, Laufzeitmessung (tools/bench).
- Verschlankung: entfernt sind interaktive Grafiken, create_config, migrate_strategy, as_list sowie scipy und TTR; Engine in Teilmodule aufgeteilt, Schichtentest, Schalter SIMLEV_* an einer Stelle.
- Parallelität: cores in Python (Fork-Prozesse) und Julia (Threads) mit denselben Ergebnissen wie R.

## SimLev.jl 0.7.0

Minor-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- MS-GARCH: Maximum-Likelihood-Schätzung nach Haas, Mittnik und Paolella (2004) für 2–3 Regime mit sGARCH/gjrGARCH; Startwerte aus HMM-EM und Rangeinteilung, Raster und BFGS.
- Bootstrap: Verfahren ms_garch nutzt die eigene Schätzung; das Paket MSGARCH wird nicht mehr gebraucht.
- Prüfung: im Vergleich mit MSGARCH 20 von 20 Fällen gleichwertig; R, Python und Julia bitgleich.

## SimLev.jl 0.6.0

Minor-Update (Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Grafik: Python zeichnet wie Julia eigenes SVG statt matplotlib; Dashboard, Analyse-, Abhängigkeits- und Überanpassungsgrafiken in einem Grafikmodul je Sprache.
- Datenobjekt: Grafiken liefern SimLevPlot mit svg, data, source und kind, damit eigene Darstellungen aus den Daten möglich sind.
- Optionen der Grafikfunktionen nur noch als Schlüsselwort.

## SimLev.jl 0.5.1

Patch-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Abhängigkeiten: evd (GPD-Anpassung), imputeTS/stinepack (Interpolation), rugarch mit Rsolnp und truncnorm (GARCH-Schätzung) als interne Teile eingebaut; R braucht zur Laufzeit nur Basis-R.
- Ableitungen: eigene Richardson-Extrapolation für Hesse- und Jacobi-Matrix statt numDeriv.
- C/C++-Kerne: Anbindung über R's C-Schnittstelle statt Rcpp, Fehlertexte unverändert.
- Ports: Python und Julia bilden die eingebauten Teile bitgleich nach; kleinere Korrekturen in Simulation und linearer Algebra.

## SimLev.jl 0.5.0

Die Julia-Fassung ist jetzt ein vollständiger Port des R-Pakets SimLev
0.5.0: alle 104 Exporte aus `r/NAMESPACE`, bitgleich zu R. Die Vorversion
0.1.0 enthielt nur die Engine und entsprach dem früheren Stand des
R-Pakets, 0.5.0 (Vorfassung vor den Korrekturen); der Name ist in der
Einleitung von [`r/NEWS.md`](../r/NEWS.md) erklärt. Zwischenversionen 0.2 bis
0.4 der Julia-Fassung gibt es nicht; alle Änderungen sind in 0.5.0
zusammengefasst. Die Begründungen der fachlichen Änderungen stehen in
[`r/NEWS.md`](../r/NEWS.md), Abschnitt „SimLev 0.5.0“. Das Paket braucht
weiterhin nur die Standardbibliothek (`Dates`, `Printf`, `Logging`;
`LinearAlgebra` nur als Ersatzweg für Eigenvektoren).

### SimLev eigenständig (1.0.0)

SimLev nutzt keine Funktionen aus
fremden Paketen mehr. Zufall und Numerik rechnet wie in R und Python die
eigene C-Bibliothek (Quellen in `core/` des Repositorys, Kopien in
`deps/core/`, gebaut von `deps/build.jl`, Hüllen `SimLev.SLib` per
`ccall`). Die vollständige Liste, was ersetzt wurde, die Laufzeiten und die
Begründungen stehen in [`r/NEWS.md`](../r/NEWS.md) (Abschnitt „SimLev eigenständig“);
die Ergebnisse sind bitgleich zu R. Die Quellen der Verfahren stehen im
[`LITERATUR.md`](../LITERATUR.md), die
bleibenden Nachbildungen von R-Grundfunktionen in
[`COPYRIGHTS.md`](COPYRIGHTS.md).

**Was ersetzt wurde:** die Module `RRng`, `RNmath`, `RPort`, `REvd`,
`RRugarch`, `RSolnp`, `RTruncnorm`, `RStinepack` und `RImputeTS` samt
`src/r/{_toms708, _cmath, _blas, _lapack, _linpack, _lbfgsb, _sbart,
_fft}.jl`, die Teile von `RLinalg` und `RStats` für `optim`, `lm`, `glm`,
`t.test`, `smooth.spline`, `density` und die lineare Algebra, `BootstrapCore`
und der Port des DCC-Filters. Die eigenen Ports der Engine-, FIFO-, Steuer-,
Research-, Entnahme- und Abhängigkeitskerne bleiben.

**Was sich für Nutzer ändert, mit Umstellungshinweisen** (Einzelheiten wie
in R):

- **Installation:** `Pkg.add`/`Pkg.build` braucht einen C-Compiler (`cc`,
  `gcc` oder `clang`, sonst `ENV["SIMLEV_CC"]`); ohne die gebaute Bibliothek
  bricht `using SimLev` mit einem Hinweis auf `Pkg.build("SimLev")` ab. Das
  Paket braucht kein `LinearAlgebra` und keine System-LAPACK mehr.
- **Zufall und `seed`:** Die Exporte `set_seed` und `rng_kind` entfallen.
  Den Zustand setzt `simlev_seed(k)` (prozessweit mit Sperre); zufällige
  Funktionen nehmen weiter `seed`. Mit `seed = nothing` zieht ein Aufruf
  genau einmal einen Startwert aus dem Zustand von SimLev. Ergebnisse hängen
  weder von `cores` noch von `julia -t` ab. Zufällige Ergebnisse ändern sich
  gegenüber früher (anderer Generator, gleiche Verteilung). Umstellung:
  `set_seed(1); bootstrap(…)` wird zu `bootstrap(…; seed = 1)` oder
  `simlev_seed(1); bootstrap(…)`.
- **GARCH-Label `"ml"`** statt `"rugarch"`/`"optim"`, **`dependence_dcc()`
  deterministisch**, **GJR mit γ ≥ 0**, eigener **Spline** und eigene
  **Kerndichte**, strengere **Fehler bei Randfällen** (NA/NaN/Inf in der
  rechten Seite eines Gleichungssystems, nicht endliche Werte bei Stineman;
  0×0-Matrix ergibt ein leeres Ergebnis), **Welch-Test mit NA** bei
  konstanten Bereichen in `signal_analysis()`, **Schranken bei BFGS und
  Nelder-Mead** in der internen Hülle `SLib.optim` ein Fehler, häufiger die
  **Warnung zur IGARCH-Nähe**: wie in [`r/NEWS.md`](../r/NEWS.md).
- **Schalter entfallen:** `SIMLEV_LAPACK` und `SIMLEV_R_SYS_TIME`; neu
  `SIMLEV_CC` (Compiler für `Pkg.build`).
- **Laufzeit** (`tools/bench`, Median, ein Kern, vor und nach dem Einbau der
  eigenen Kerne): GARCH-Bootstrap (T2) 0,163 → 0,021 s, `dependence_analysis`
  mit DCC (T5) 0,076 → 0,031 s, `simulation` 30 Jahre (S30) 0,023 → 0,019 s,
  MS-GARCH-Schätzung (T8) 0,265 → 1,325 s (zwölf statt zwei Starts im
  gemeinsamen C-Kern); die übrigen Aufgaben etwa gleich. Tabelle in
  [`r/NEWS.md`](../r/NEWS.md).

**Tests:** Die frühere Suite ist bis zum Neuaufbau ausgesetzt
(`SIMLEV_LEGACY_TESTS=1` lädt sie); `Pkg.test()` führt den Testsatz
für 1.0.0 aus. Maßgeblich ist die Gleichlaufprüfung
`tools/gleichlauf/run.sh` (27.10.2026: 4.260/4.260 Modul- und 1.182/1.182
Engine-Fälle bitgleich zu R).

### Eigene numerische Kerne (1.0.0)

- **C-Bibliothek statt `RNmath`, `RLinalg`, `RStats` (optim, lm, glm, smooth.spline, density, t.test), `RRugarch`, `REvd` und `RImputeTS`:** Verteilungen, lineare Algebra und Matrixprodukt, kleinste Quadrate und Logit-IRLS, Welch-Test, Kerndichte, Optimierer, GARCH/GJR, GPD, DCC, MS-GARCH, Stineman und Glättungsspline laufen wie in R per `ccall` in der C-Bibliothek (`SimLev.SLib`); die Arbeitslast der Vorkompilierung zieht ihre Daten aus einem SimLev-Strom statt aus `RRng`. Die Nachbildungen werden nicht mehr aufgerufen und entfallen in 9.6c. Geänderte Ergebnisse und Labels (GARCH `"ml"`, DCC deterministisch, Spline, Kerndichte, `signal_analysis()["fit"]["model"]`) wie in [`r/NEWS.md`](../r/NEWS.md); bitgleich zu R.

### Eigener Zufall (1.0.0)

- **Zufall der C-Bibliothek statt `RRng`:** Alle zufälligen Funktionen ziehen wie in R aus dem Zufallszustand von SimLev (neu `simlev_seed()`, prozessweit mit Sperre); `seed = nothing` zieht genau einmal einen Startwert daraus, `set_seed()` wirkt auf SimLev nicht mehr; die Bootstrap-Kerne laufen per `ccall` in der C-Bibliothek. Ergebnisse bitgleich zu R und unabhängig von `cores` und `julia -t`; Einzelheiten in [`r/NEWS.md`](../r/NEWS.md).

### Ports in NaN-Randfällen (0.10.0)

- **Bitgleich zu R auch bei NA/NaN-gemischten Eingaben:** Die Ports von `min_cdar_core` (`quantile7` mit Nachbildung von `std::nth_element`), `hmm_forward_backward`, `dcc_filter`, `garch_filter`, `rolling_vol` (`std::max` statt Julias `max`), der Engine-Kerne (`core.jl`), `boot_wild`, `boot_garch`, `boot_ms_garch` (auch `std::min`/`std::max` bei TVTP) und `rtruncnorm` rechnen Additionen und Multiplikationen mit zwei möglichen NaN in der Operandenfolge des R-Baus (`nan_add`, `nan_mul` in `src/r/rnum.jl`); in den Zufallsvergleichen gegen R (Fälle wie Python) vorher z. B. `dcc_filter` 377/400, `boot_wild` 1.875/2.000, `rtruncnorm` 1.941/2.000, jetzt alle bitgleich; neu `test/nan_kerne_tests.jl`.

### Restpunkte Fonds-Wrapper (0.10.0)

- **Auswahl aus `wrapper_nav()`:** `rows(x, i)` liefert eine gewöhnliche Tabelle (`RFrame`) ohne Klasse `SimLevWrapperNav` und ohne Attribute (bisher blieben beide); wie R `[.SimLevWrapperNav`. Neu intern `register_plain_rows!` (Klassen, deren Zeilenauswahl gewöhnlich wird); andere Klassen behalten bei `rows` Klasse und Attribute.
- **`withdrawal_simulation()`:** Ein `RFrame` mit Spalte `date` als `x` ergibt den Fehler wie in R.
- **`strategy_from_weights()`/`portfolio_template()` mit `wrapper`:** ein `SimLevWrapperConfig` für alle Assets, eine benannte Liste (NamedTuple, `Dict`, `RList`, Paare) je Asset, Fehler wie in R (bisher wurde ein einzelnes `SimLevWrapperConfig` stillschweigend weggelassen).

### Fonds-Wrapper (0.10.0)

Port des Fonds-Wrappers aus R (Begründung und Rechenregeln in [`r/NEWS.md`](../r/NEWS.md) und im Kopf von `src/wrapper.jl`); bitgleich zu R in allen 72 Fällen des neuen Referenzmoduls `golden/modules/wrapper`, auch mit `julia -t 2`. Die Schnittstelle ist neu eingefroren (`tools/api_snapshot/CHANGES.md`).

- **Neu (exportiert):** `wrapper_config(strategy; rebalance = nothing, costs = funds_costs(), order_fee = nothing, volume = nothing)` → `RList` der Klasse `SimLevWrapperConfig`, `wrapper_nav(data, wrapper; splits = nothing)` → `RFrame` der Klasse `SimLevWrapperNav` (`date`, `nav`, `gross`, `fee`, `perf_fee`, `perf_paid`, `hwm`; `attrs(x)["inner"]` und `attrs(x)["wrapper"]`) und `asset_config(...; wrapper = nothing)` (auch als elftes Positionsargument wie in R). Druck über `register_print!` wie die R-Methoden; Vorkompilier-Arbeitslast um Wrapper und Anteilswert ergänzt.
- **Engine:** `simulation()` rechnet je Wrapper-Asset den Anteilswert aus den inneren Spalten (`_sim_phases._sim_check_inputs`) und hängt ihn als Kursspalte an; der Anteilswert splittet nicht (`cfg["no_split"]`), mit `details=True` kommt `result.wrappers` dazu. Die normalisierten Daten gehen als `_Frame` an die innere Rechnung (`simulation()` nimmt intern auch ein `_Frame`); `Cfg` hat die Felder `no_split` und `wrappers`.
- **Paketzustand:** Den Zustand der Ordergebühren (R `.fee_env`) hält Julia je Lauf (`Run.fee_current`, `Run.fee_paid`); die innere Rechnung ist ein eigener Lauf und lässt den äußeren unverändert, zu sichern ist nichts (Test: äußere Gebühren gleich wie mit dem Anteilswert als Kursspalte).
- **Meldungen:** Hinweise der inneren Rechnung gehen über `RParallel.with_message_stream` (neu: Meldungen von `r_stderr()` in der laufenden Aufgabe an einen Strom, der sie umformt) und erscheinen als „Hinweis: Wrapper '<Name>' (innere Rechnung): …“ (in `wrapper_nav()` „wrapper_nav (innere Rechnung)“), Warnungen (über einen Logger, der an den äußeren weitergibt) und Fehler als „simulation: Wrapper '<Name>' (innere Rechnung): …“. Bei Handelstagsdaten steht der Auffüll-Hinweis daher wie in R zweimal.
- **Aufrufer:** `strategy_validate()` (Spaltenkollision, innere Spalten und Signale), `strategy_update_asset(...; wrapper = …)` (auch `nothing` zum Entfernen), `planning_lumpsum_vs_dca()` (Kurs des Wrappers = Anteilswert im Fenster) und `withdrawal_simulation(wrapper_nav(...))`; `bootstrap_study`, `param_search`, `sensitivity_*` und `overfit_*` gehen unverändert über `simulation()`. Kursspalten einer Strategie liefert `_strategy_columns` in `config.jl` (R `.strategy_columns`).
- **Tests:** `test/wrapper_tests.jl` (Port von `test-wrapper.R`: Plausibilität, Handbeispiel, Startkosten, NA-Tage, Fehler, Hinweise, Gebührenzustand, Splits, Aufrufer, Druck).

### Standard-Spread 0 und alter Fondsmodus entfernt (0.10.0)

Begründung in [`r/NEWS.md`](../r/NEWS.md); die Schnittstelle ist neu eingefroren (`tools/api_snapshot/CHANGES.md`).

- **Standard-Spread jetzt 0:** `asset_config(spread = 0)` statt `0.1`; wer Spreads abbilden will, gibt sie an. Ausdrücklich gesetzte Werte bleiben. Ohne Angabe rechnen damit `asset_config()`, Listen an `create_strategy()`, `strategy_from_weights()`, `portfolio_template()`, die `asset_args` von `tactical_simulation()` und die Standardstrategie von `sensitivity_leverage()` ohne Spread (bisher 0,1 %). Die Referenzfälle bleiben gleich: Ihre Generatoren schreiben `spread = 0.1` jetzt aus.
- **Alter Fondsmodus entfernt:** `simulation()` hat kein Argument `funds` mehr; `simulation(...; funds = funds_costs())` ergibt den üblichen Fehler für ein unbekanntes Schlüsselwort (`MethodError`: `got unsupported keyword argument "funds"`), ohne Sonderbehandlung. Entfallen sind der Engine-Weg `tax_mode = "funds"` (Fondskosten am 31.12. und anteilig am letzten Tag mit Teilverkauf, Performancegebühr gegen den Höchststand des Depots, Steuer auf den Gesamtgewinn bei Liquidation) sowie der Baustein `funds` in `sim_args`, Rastern und Suchräumen (Pfade `"funds.*"`); die flachen Namen `funds_fee` und `bonus_fee` sind jetzt unbekannte Argumente. Die geteilten C/C++-Kerne enthielten keinen Fondscode. `result.trades` hat keinen Eintrag `fees` mehr (er enthielt nur die Fondskosten); entfernt sind auch `FeeEntry`, `Totals.total_value`, `Flags.flag_fund_fee`, `_calculate_fund_fees` und `_raise_cash!`.
- **Umstellung:** Nachfolger ist der Fonds-Wrapper `wrapper_config()` (siehe oben) mit `funds_costs()` als Kostenbaustein: Der Wrapper wird als eigene Kursreihe (Anteilswert) gerechnet und außen wie ein Einzelpapier gehandelt und besteuert. Unterschiede zum alten Modus: Die Fondskosten werden täglich vom Anteilswert abgezogen (bisher am 31.12. aus der Summe der Tageswerte bzw. anteilig am letzten Tag), und die Performancegebühr bemisst sich am Höchststand je Anteil (bisher am Höchststand des Depots, der mit jeder Einzahlung stieg). `funds_costs()` bleibt mit Prüfung und Druckausgabe exportiert; `simulation()` nimmt es nicht an.
- **Referenzfälle:** Entfernt sind die 39 Referenzfälle des Fondsmodus: 13 in `golden/cases` (`f07_funds_liq`, `f08_funds_1231`, `f28_details_split_funds`, `r018`, `r035`, `r052`, `r086`, `r171`, `r222`, `r358`, `r443`, `r460`, `r477`), 2 in `golden/extra` (`x02_30y_funds_split_int`, `x16_funds_fee_high`) und 24 im Modul `engine` (`bk01`, `bk18`, `bk19`, `ch12`, `fee05`, `fu01`–`fu11`, `fu14`, `fu16`, `gp05`, `hv15`, `zz02`, `zz08`, `zz13`, `zz20`); Engine-Fälle jetzt 90 (55 + 35), Modul-Fälle 4.659. Alle übrigen Fälle rechnen unverändert (Nachweis und Liste in `golden/README.md`, im Repository bis 1.4.0); acht Fehlerfälle in `bootstrap`, `param_search` und `sensitivity` nennen `funds` nicht mehr in der Liste der Bausteine.

### Eingefrorene Schnittstelle (0.9.0)

Die Schnittstelle 0.5.0 ist in `tools/api_snapshot/frozen/jl.json` festgehalten und wird von `test/api_frozen_tests.jl` und `tools/api_snapshot/run.sh --check` geprüft; Änderungen nur über `run.sh --freeze` mit Eintrag in `tools/api_snapshot/CHANGES.md`.

### Umbenennungen (0.9.0)

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

### Aufrufer von `simulation()`, Argumentordnung (0.9.0)

- **Fondsmodus mit eigenen Steuern** (Korrektur der Bausteine; seit 0.10.0 samt Fondsmodus entfernt, siehe oben): `simulation(funds = funds_costs(...), tax = tax_profile(...))` ist wieder erlaubt; der Fondsmodus steht für einen eigenen Wrapper (etwa ein Zertifikat) mit eigenen Kosten und eigener Steuer. Aus `tax_profile()` wirken dort wie früher mit `tax_mode = "funds"` der Satz `rate` bzw. die Kirchensteuer `church_tax` (Satz nach § 32d Abs. 1 EStG) für die Steuer auf den Gesamtgewinn bei Liquidation; `harvest` und `income_tariff()` wirken nicht (Warnung), die übrigen Angaben still nicht. Ohne `tax` gilt wie bisher 26,375 %. Referenzfall `ch12` rechnet wieder wie in 0.8.0.
- **`sim_args` mit Bausteinen** in `bootstrap_study()`, `param_search()`, `param_bootstrap()`, `sensitivity_grid()`, `sensitivity_leverage()`, `sensitivity_rebalancing()`, `planning_lumpsum_vs_dca()` und den Zusatzargumenten von `tactical_simulation()`: Argumente von `simulation()`, z. B. `sim_args = list(start_value = 1000, tax = tax_profile(), dca = dca_plan(100, 1))`. Die Aufrufer gehen über `simulation()`. Alte flache Namen sind ein Fehler, der den Baustein nennt: `sensitivity_grid: dca_value gibt es nicht mehr; bitte dca = dca_plan(value = …) (Pfad "dca.value").`; unbekannte Namen ebenso (`unbekanntes Argument … für simulation()`).
- **Pfade zu Bausteinparametern** in Rastern (`sensitivity_grid(grid = )`), Suchräumen (`param_space()` ohne `builder`), den `args` einer Spezifikation und in `sim_args`: `"dca.value"`, `"rebalance.thresh"`, `"tax.rate"`, `"tax.church_tax"`, für Teilbausteine `"tax.income.marginal_rate"`, `"tax.harvest.day"`. Ein Pfad baut den Baustein für jeden Lauf neu, Grundwerte aus dem Baustein in `sim_args` (ohne ihn die Standardwerte des Konstruktors). Ergebnisspalten heißen wie der Pfad (bisher wie das flache Argument, z. B. `balance_unit` → `rebalance.unit`). Unbekannte Pfade nennen die möglichen Bausteine und Parameter. `sensitivity_rebalancing()` setzt Frequenz, Versatz und Band über diese Pfade, die übrigen Angaben eines `rebalance_plan()` aus `sim_args` bleiben erhalten.
- **`withdrawal_simulation(tax = tax_profile())`** statt `tax_mode`, `tax_rate`, `sparer_pauschbetrag`: ausgewertet werden `rate` und `sparer_pauschbetrag`; was die Entnahmephase nicht abbildet (`church_tax`, `private_sale_threshold`, `base_rate`, `guenstigerpruefung`, `income`, `harvest`), ist ein Fehler. `partial_exemption`, `vorabpauschale`, `cost_basis`, `loss_carryforward`, `sale_cost` und der Basiszins `base_rate` (auch als Matrix) bleiben eigene Argumente; das Ergebniselement `tax_mode` bleibt (`"person"`/`"none"`).
- **`seed`, `cores`, `progress` am Ende** (Reihenfolge `…, max_tries, chunk_size, seed, cores, progress`): `bootstrap()`, `bootstrap_study()`, `param_search()` (`keep_returns` vor `seed`, `cores`), `sensitivity_grid()` (`keep_results` vor `cores`), `sharpe_test()` (`ppy` vor `seed`).
- **`portfolio_rolling(data, …)`** statt `x` (das erste Argument ist nur eine Tabelle mit Datumsspalte).

### Bausteine für `simulation()` (0.9.0)

`simulation()` nimmt die Einstellungen jetzt als Bausteine:

`simulation(data, strategy; start_value = 10000, costs = sim_costs(), dca = nothing, rebalance = nothing, splits = nothing, tax = nothing, risk_free = 0, fractions = true, liquidate = false, details = false, io = stdout)`

`nothing` heißt aus. Die flachen Argumente bis 0.8.0 gibt es nicht mehr (keine Aliasse); die Engine rechnet unverändert, alle Referenzfälle sind nach der Übersetzung bitgleich (Nachweis mit `golden/tools/blocks_from_flat.py`). Jeder Baustein prüft seine Argumente selbst und hat eine Druckausgabe.

| bisher (flach) | jetzt |
|---|---|
| `order_fee`, `dca_fee` | `costs = sim_costs(order_fee, dca_fee)` |
| `dca_mode = true`, `dca_value`, `dca_span`, `dca_days`, `dca_unit`, `dca_anchor`, `dca_start`, `dca_skip`, `balance_dca` | `dca = dca_plan(value, span, days, unit, anchor, start, skip, fill_deficits)` |
| `balance_mode = true`, `balance_span`, `balance_days`, `balance_unit`, `balance_anchor`, `balance_start`, `balance_skip`, `balance_thresh`, `balance_thresh_type`, `event_col`, `event_mode`, `event_weight` | `rebalance = rebalance_plan(span, days, unit, anchor, start, skip, thresh, thresh_type, event_col, event_mode, event_weight)` |
| nur Ereignisse (`balance_mode = false` mit `event_col`, `event_mode = "replace"`) | `rebalance_plan(event_col = , event_mode = "replace", skip = true)` |
| `split_mode = true`, `split_thresh` | `splits = split_rule(thresh)` |
| `tax_mode = "person"`, `tax_rate`, `church_tax`, `sparer_pauschbetrag`, `use_sparer_pauschbetrag = false`, `private_sale_threshold`, `base_rate`, `base_rate_flex` mit `base_rate_data`, `use_guenstigerpruefung` | `tax = tax_profile(rate, church_tax, sparer_pauschbetrag, private_sale_threshold, base_rate, guenstigerpruefung, income, harvest)`; `sparer_pauschbetrag = 0` heißt ohne Pauschbetrag, `base_rate` ist eine Zahl oder ein Spaltenname |
| `marginal_tax_rate`, `include_soli_on_income_tax`, `soli_rate_income_tax` | `income = income_rate(marginal_rate, soli_rate)` (`soli_rate = 0` heißt ohne Soli) |
| `taxable_income`, `tax_tariff` | `income = income_tariff(taxable_income, tariff)` |
| `harvest_mode = true`, `harvest_day`, `harvest_loss_pot` | `harvest = harvest_rule(day, loss_pot)` |
| `tax_mode = "funds"`, `funds_fee`, `bonus_fee` | `funds = funds_costs(fee, performance_fee)`, seit 0.10.0 entfernt (siehe oben) |
| `spread` (ohne Wirkung, nur Warnung) | entfällt; der Spread gilt je Asset (`asset_config(spread = )`) |

Neue Regeln: `tax_profile()` mit `rate` und `church_tax` > 0 ist ein Fehler (mit Kirchensteuer gilt der Satz nach § 32d Abs. 1 EStG); `income` nimmt entweder `income_rate()` oder `income_tariff()`. Freibetrag-Ausschöpfung ohne persönliche Besteuerung lässt sich nicht mehr angeben (bisher wirkungslos); die Warnungen zu wirkungslosen flachen Argumenten entfallen. Fehlermeldungen der Prüfungen nennen den Baustein (z. B. `dca_plan: 'value' muss …`, `tax_profile: church_tax …`). Mit `sparer_pauschbetrag = 0` steht in `tax_report$sparer_pauschbetrag_annual` 0 (bisher der angegebene Betrag neben `use_sparer_pauschbetrag = false`).

Weitere Änderungen: `plot(<SimLevWeights>, main = "Zielgewichte")` hat den Titel als Argument (R wie die Ports).


### Engine (`simulation()`)

* Alle Korrekturen der R-Engine nach 0.5.0 (Vorfassung vor den Korrekturen) sind übernommen,
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
  zeitgewichteten Wertindex `twr_index` gemessen; nicht definierte
  Kennzahlen stehen mit Ursache in `undefined_metrics`.
* Neue Argumente wie in R: `balance_thresh_type` (relative
  Rebalancing-Bänder), `order_fee`, `dca_fee`, `church_tax`,
  `harvest_mode`, `harvest_day`, `harvest_loss_pot`, `taxable_income` und
  `tax_tariff`; neu ist `read_tax_tariff()` mit der mitgelieferten
  Tarifdatei `data/steuertarif.csv`.
* Neue Ergebniselemente wie in R: `twr_index`, `invested`,
  `external_flows`, `undefined_metrics`, `open_lots`, `fees_paid`,
  `harvest_days` sowie `tax_report.open_tax_debt`,
  `tax_report.tariff_years` und `tax_report.next_year`.
* Eingabeprüfung wie in R: Unsortierte Daten werden mit Hinweis sortiert,
  einzelne fehlende Kurse per LOCF gefüllt, führende fehlende Kurse wirken
  wie ein späteres `asset_start`; doppelte Datumswerte und Kurse ≤ 0 sind
  Fehler. Warnungen gibt es u. a. für wirkungslose Argumente (`spread`,
  `funds_fee` außerhalb von `tax_mode = "funds"`).
* Alle Meldungen, `print`, `summary`, das Ereignisprotokoll von
  `details = true` und das Dashboard sind deutsch und wortgleich zu R
  (früher englische Bezeichnungen wie „Final Value“).

### Erweiterungen

* Neu sind alle Erweiterungen des R-Pakets mit gleichen Namen, Argumenten
  und Ergebnissen: Datenaufbereitung, Backcast, Anleihen und Geldmarkt,
  Signale, Bootstrap, Entnahmephase, Abhängigkeiten, Regime, Szenarien,
  Optimierung, taktische Allokation, vertiefte Analyse, Planung,
  statistische Prüfungen, Überanpassung, Parametersuche und
  Sensitivitäten. Jedes Modul ist ein Untermodul (`SimLev.Bootstrap`,
  `SimLev.Optimize` …), seine öffentlichen Funktionen stehen nach
  `using SimLev` direkt bereit. Die C++-Kerne des R-Pakets sind in
  `src/<name>_core.jl` übertragen.
* Für die Erweiterungen bildet die Julia-Fassung in `src/r/` nach, was R
  selbst beisteuert: Zufallszahlen (`set_seed()`, Mersenne-Twister,
  L'Ecuyer-CMRG-Streams, `sample.int`, `rnorm` …), Verteilungsfunktionen
  aus nmath, die benötigten stats-Funktionen, lineare Algebra wie
  Referenz-BLAS/LAPACK und LINPACK sowie Formatierung und Druckausgabe.
* Bedingungen als Text (`tactical_rules()`, `bootstrap_probability()`,
  `regime_subset()`, `view_prob()`) wertet ein gemeinsamer Auswerter in
  R-Syntax aus (`SimLev.RExpr`), mit R's Vorrangregeln, NA-Logik, `%in%`
  und `%%`. Die Python-Fassung nutzt dafür Python- bzw. pandas-Ausdrücke.
* `cores > 1` rechnet parallel mit `Threads.@spawn`, wenn Julia mit
  mehreren Threads läuft (`julia -t auto`, `JULIA_NUM_THREADS`), sonst
  nacheinander; in beiden Fällen mit der Zufallssemantik von
  `mclapply(mc.set.seed = FALSE)`, also mit denselben Ergebnissen wie R
  (`SimLev.RParallel.par_lapply`, Nachbildung von `.par_lapply`). Jede
  Aufgabe rechnet mit einer eigenen Kopie des Zufallszustands
  (`RRng.with_state`); Meldungen gehen über `RParallel.r_stderr()` und
  erscheinen in der Reihenfolge der Einheiten, Warnungen gehen wie in R
  verloren, ein Fehler bricht wie bei `cores = 1` ab. Dafür sind die
  veränderlichen globalen Zustände thread-sicher: `suppressMessages`
  (`_no_messages`, `Overfitting._quiet`) wirkt je Aufgabe statt über
  `redirect_stderr`, der Abfang-Handler von `portfolio_optimize` ist
  task-lokal, Kollation, System-LAPACK und `param_ids` richten sich unter
  einer Sperre ein, `bsplvb` (smooth.spline) hält seinen Zustand je Aufruf.
  `cores` zwischen 1 und 2 rechnet wie in R als `lapply`.
* MS-GARCH ohne MSGARCH, eigene Schätzung wie R: Die Verfahren
  `"ms_garch"`, `"ms_ar_garch_m"` und `"tvtp_ms_garch"` von `bootstrap()`
  und `bootstrap_study()` laufen jetzt auch in Julia, bitgleich zu R. Das
  Untermodul `SimLev.MsGarch` (`src/ms_garch.jl`, Port von
  `r/R/ms_garch.R`) schätzt das Modell nach Haas, Mittnik und Paolella
  (2004) per Maximum Likelihood (`optim` mit BFGS aus deterministischen
  Startwerten: Baum-Welch-EM und Rangeinteilung der Volatilität, je mit
  kleinem Raster); den Hamilton-Filter rechnet
  `BootstrapCore.ms_garch_filter` (Port von `r/src/ms_garch.c`). Das EM von
  `regime_hmm()` ist wie in R in `Regimes._hmm_em`, `_hmm_init_rank` und
  `_hmm_init_cl` herausgelöst (Ergebnis unverändert). Die Meldung „Paket
  fehlt“ entfällt.

### Rechenweise

* `F80` (80-Bit-`long double`) rechnet auf x86-64 jetzt direkt mit dem
  x87-Format der Hardware (über `llvmcall`), deutlich schneller als der
  Software-Nachbau, der auf anderen Prozessoren als `F80Soft` weiter
  verwendet wird.
* Mathematische Funktionen der R-Interna kommen wie in R aus glibc-libm
  (per `ccall`), Matrixprodukte folgen der Reihenfolge der Referenz-BLAS,
  Eigenvektoren kommen aus der Referenz-LAPACK des Systems
  (`SIMLEV_LAPACK`; ohne sie mit Warnung über `LinearAlgebra.eigen`, nicht
  bitgleich).
* Zeichenketten werden wie in R mit der ICU-Kollation sortiert und verglichen
  (System-ICU per `ccall`, `SIMLEV_ICU`, `SIMLEV_COLLATE`).
* Innerer Aufbau: `ld80.jl`, `rnum.jl` und `rformat.jl` liegen bei den
  übrigen R-Interna in `src/r/`; `src/SimLev.jl` bindet erst die R-Interna,
  dann die Engine und dann die Module ein (C++-Kerne jeweils vor ihrem
  Modul). Das ungenutzte `RFmt.R_NAN` entfällt (R's NaN ist `NaN`). Alle
  SVG-Zeichenbausteine stehen im Grafikmodul `src/svg.jl` (vor
  `dashboard.jl` und den Modulen; Abschnitte und Namen wie
  `python/simlev/svg.py`, ein Präfix je Grafikstil).

### Änderungen der Julia-API

* `SimLevResult` ist kein `struct` mit festen Feldern mehr, sondern wie
  eine R-Liste aufgebaut (`AbstractDict{String,Any}` über einer `RList`):
  Elemente in der Reihenfolge von R, Zugriff über `res.name` oder
  `res["name"]`, erweiterbar wie in R. `statistics`, `tax_report` und je
  Asset `report` sind `RList` statt NamedTuple, `buys` und `sells`
  `RVector`. Schreibweisen wie `result.statistics.sharpe` und
  `result.report["WORLD"].total` funktionieren unverändert; `result.trades`
  gibt es weiterhin (nur Julia).
* Neue Datentypen und Hilfen für R-Objekte: `RList`, `RFrame`, `RVector`,
  `NamedMat`, `named`, `nrow`, `ncol`, `rows`, `attrs`, `r_class`,
  `inherits`; generische Funktionen `r_summary(x)` und `r_plot(x)` für alle
  Ergebnisobjekte. Numerisches NA ist `SimLev.NA`, andere NA sind
  `missing`. Tabellen übergeben Sie den Erweiterungen als `RFrame` (einige
  nehmen nur diese Form); `simulation()` nimmt weiterhin auch NamedTuple,
  `Dict` und andere Tabellen.
* `summary(result)` gibt jetzt ein `SimLevSummary` (R-Klasse
  `summary.SimLevResult`) zurück, das in der REPL wie in R gedruckt wird;
  `verbose = true` druckt zusätzlich (früher NamedTuple und Ausgabe
  standardmäßig).
* `plot_dashboard()`: `width` und `height` sind jetzt Pixel (Standard
  1400 × automatisch) statt Zoll; die Argumente `currency` und `file` gibt
  es nicht mehr (wie in R). Das Statistik-Panel zeigt die Sharpe Ratio
  aus `statistics` statt einer vereinfachten Formel.
* `export_dashboard()` schreibt nur noch SVG (früher `.html` direkt sowie
  `.pdf` und `.png` über `rsvg-convert`); andere Dateiendungen ergeben
  einen Fehler. Die Meldung erscheint wie in R auf `stderr`, die Rückgabe
  ist `nothing` statt des Dateinamens.
* Grafikobjekt: `SimLevDashboard` heißt jetzt `SimLevPlot` (ohne Alias).
  Dashboard und alle `plot`-Methoden liefern es mit den Feldern `svg`,
  `data` (die dargestellten Werte je Panel als `RFrame` in einer `RList`,
  unskaliert und nicht ausgedünnt; für eigene Grafiken), `source` (das
  Eingabeobjekt) und `kind` (dessen Klasse); Python liefert dasselbe
  Objekt mit denselben Daten. Geschrieben wird nur mit `file = "….svg"`;
  unbekannte Schlüsselwörter ergeben eine Warnung statt stillem
  Übergehen.
  Behoben: ungültige Farben in `plot.SimLevParamSearch` (Überlauf im
  Farbverlauf) und Achsenmarken des Dashboards, die wegen `10.0^k` aus
  Base minimal von R abwichen (jetzt libm wie R).
* Entfernt wie in R: das interaktive HTML-Dashboard (`plot_interactive()`,
  `export_html_dashboard()`; Dateien `src/interactive.jl` und
  `src/html_templates.jl`) sowie `create_config()`, `migrate_strategy()`,
  `as_list()` und `portfolio_templates()` (jetzt `portfolio_template()`
  ohne `name`; `name` geht auch als Schlüsselwort). Das statische
  SVG-Dashboard (`plot_dashboard()`, `export_dashboard()`) bleibt.
* `simulation()` bricht nicht mehr mit „subscript out of bounds“ ab, wenn
  `funds_fee` oder `bonus_fee` außerhalb des Fondsmodus zusammen mit
  `church_tax`/`tax_rate` oder `taxable_income` angegeben ist (Korrektur in
  R 0.5.0, siehe `r/NEWS.md`, „Korrektur der Fondskosten-Argumente“); bisher bildete Julia den Fehler
  nach.

### Prüfwerkzeuge

* `tools/compare_golden.jl` prüft die Engine-Fälle eines Ordners
  (`golden/cases`, 55 Fälle; `golden/extra`, 35 Fälle, seit 0.10.0) strikt mit NA ≠ NaN,
  einschließlich `print` und `details = true`; alle 90 Fälle sind
  bitgleich, ebenso 469 frisch erzeugte Zufalls- und Stressfälle.
* Neu: `tools/compare_reference.jl` und `test/reftree.jl` vergleichen die
  Erweiterungen, die Engine (Modul `engine`, 249 Fälle zu den Argumenten
  und Ergebniselementen von 0.5.0) und die R-Interna mit den 4.536
  Referenzfällen aus `golden/modules/`. Jeder Fall enthält dafür neben R- und Python-Code
  Julia-Code (Feld `jl`). Verglichen werden Ergebnis (NA ≠ NaN, Vorzeichen
  der Null), Konsolen- und Druckausgabe, Warnungen und Fehlermeldungen;
  alle 4.536 Fälle sind bitgleich.
* `Pkg.test()` umfasst 929 Tests: alle Engine-Fälle, von den Modul-Fällen
  eine Auswahl (alle mit `SIMLEV_FULL_TESTS=1`) sowie Tests für `F80`,
  Engine, Ausgabe und den Auswerter für Bedingungen.
* `tools/compare_golden.jl` prüft ohne Pfad `golden/cases` und
  `golden/extra` und nimmt mehrere Ordner (mit Gesamtsumme).
* Neu: `test/layers_tests.jl` prüft die Schichten der Dateien in `src/`
  (0 R-Interna, 1 Daten und Strategie, 2 Engine, 3 Analysen, 4 Ausgabe; kein
  Zugriff auf eine höhere Schicht, bekannte Ausnahmen begründet) und dass
  die Schalter `SIMLEV_*` nur in `src/r/env.jl` gelesen werden.
* Alle Umgebungsschalter `SIMLEV_*` liest jetzt `SimLev.REnv`
  (`src/r/env.jl`, Tabelle in `DEVELOPING.md`); Wirkung, Standardwerte und
  Meldungen sind unverändert.
* Ausdrücke in `test/rexpr_tests.jl`, die ein Referenzfall
  (`golden/modules/rexpr`) wörtlich prüft, stehen nur noch dort.
* Vorkompilierung: Die Arbeitslast deckt nur noch die häufigen Wege ab
  (Engine, `bootstrap` stationär und GARCH über den rugarch-Weg,
  `bootstrap_study`, MS-GARCH-Schätzung, Entnahme, Optimierung,
  `deep_analysis`); Parametersuche, Abhängigkeiten, Szenarien,
  Sensitivitäten, Taktik, Planung und `align_series` übersetzt erst ihr
  erster Aufruf.

### Bekannte Grenzen

* Bitgleichheit ist unter Linux x86-64 mit glibc geprüft. Die
  libm-Aufrufe der R-Interna sind auf `libm.so.6` (glibc) eingestellt;
  unter macOS und Windows ist die Fassung nicht geprüft.
* evd (2.3-7.1, `fpot`) und rugarch (1.5-6, `ugarchfit` mit Rsolnp 1.16
  `solnp`, `nlminb` und `gosolnp` mit `rtruncnorm` aus truncnorm 1.0-9) sind
  nachgebildet (`SimLev.REvd`, `RRugarch`, `RSolnp`, `RTruncnorm`,
  `RStats.nlminb` mit `RPort`). evd gilt immer, weil das R-Paket
  `evd::fpot` übernommen hat (`.evd_fpot`, siehe `r/NEWS.md`, „Optionale
  Pakete eingebaut“), ebenso `_fit_tail`; Herkunft und Lizenz
  in `COPYRIGHTS.md`. Ebenso gilt rugarch immer, weil das R-Paket
  `rugarch::ugarchfit` mit Rsolnp `solnp`/`gosolnp` und truncnorm
  `rtruncnorm` übernommen hat (`.rugarch_ugarchfit`), ebenso `_fit_garch11`
  (`optim` und die Momente nur noch als Rückfall bei einem Fehler); Herkunft und Lizenz der Nachbildungen
  (rugarch, Rsolnp, truncnorm) in `COPYRIGHTS.md`. Numerische Ableitungen
  (Richardson-Extrapolation) eigenständig implementiert: Hesse-Matrix und
  Scores rechnen `RRugarch._richardson_hessian`/`_richardson_jacobian` wie
  `.sl_richardson_hessian`/`.sl_richardson_jacobian` im R-Paket statt einer
  Nachbildung von numDeriv; Ergebnisse gegen numDeriv geprüft und bitgleich.
  gosolnp setzt wie in R
  den Zufallszustand aus der Uhrzeit; `ENV["SIMLEV_R_SYS_TIME"]` stellt die
  Uhr fest. imputeTS 3.4 mit stinepack 1.5 ist nachgebildet (`RImputeTS`,
  `RStinepack`; `fill = "stine"` im Backcast nach Stineman) und gilt immer,
  weil das R-Paket `na_interpolation(option = "stine")` mit `na_locf` und
  `stinterp` übernommen hat (`.imputets_na_interpolation`), ebenso
  `_fill_na` (kein Rückfall auf linear mit Hinweis).
  `RImputeTS.na_interpolation` mit `option = "linear"` interpoliert wie
  imputeTS (auch in R übernommen); wie die Übernahme brechen `option =
  "spline"` und `na_locf` mit `na_remaining = "rm"`/`"mean"` mit deren
  Meldung ab. Da R evd, imputeTS und rugarch übernommen hat, entfallen das
  Untermodul `RSuggests` (`src/r/suggests.jl`) und die Umgebungsvariable
  `SIMLEV_R_SUGGESTS`; die Referenzfälle haben kein Feld `suggests` mehr.
  MSGARCH wird nicht gebraucht; die MS-GARCH-Verfahren schätzen wie R
  selbst (siehe Erweiterungen).
* `nlminb`: An drei Stellen liest die PORT-Bibliothek nicht gesetzte
  Variablen (in R Stapelreste); Julia setzt 0. Das kann nur in
  Sonderfällen die Meldung (Code 3 statt 5) oder Läufe mit Inf/NaN in
  Gradient bzw. Hesse-Matrix ändern.
* Grafiken sind nicht bitgleich (SVG ohne externe Pakete statt
  Base-Grafik), die dargestellten Daten schon.
* Die Vorkompilierung dauert einmalig einige Minuten; der erste Aufruf
  einer Funktion in einer Sitzung braucht wegen der Kompilierung noch
  einige Sekunden.

## SimLev.jl 0.1.0

Erste Fassung: die Engine `simulation()` mit Strategien,
`compute_rebal_trigger()`, `print`/`summary`, statischem SVG-Dashboard und
interaktivem HTML-Dashboard, bitgleich zum damaligen Stand des R-Pakets,
0.5.0 (Vorfassung vor den Korrekturen).
