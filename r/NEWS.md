# SimLev (R) – Änderungen je Version

Die Python- und die Julia-Fassung sind seit ihrer Version 0.5.0
vollständige Ports dieser R-Fassung 0.5.0 (alle Exporte, alle
Erweiterungen) und bitgleich zu ihr; ihre Änderungen stehen in
[`python/NEWS.md`](../python/NEWS.md) und
[`julia/NEWS.md`](../julia/NEWS.md). Ihre Vorversionen 0.1.0 enthielten nur
die Engine und entsprachen dem früheren Stand des R-Pakets, der vor
den Korrekturen ebenfalls als 0.5.0 bezeichnet war; im Folgenden heißt er
„0.5.0 (Vorfassung vor den Korrekturen)“. Bis zu diesem Stand blieben die 105
Golden-Master-Fälle der Engine bitgleich; die aktuelle Fassung 0.5.0
korrigiert Rechenfehler der Engine, setzt die Besteuerung nach geltendem
Recht um, gibt alle Ausgaben auf Deutsch aus und erzeugt alle 105 Fälle
neu (siehe unten). Python 0.5.0 und Julia 0.5.0 sind zu allen Fällen
bitgleich (seit 0.10.0 90; die 15 Fälle des entfernten Fondsmodus entfielen).

## SimLev 1.6.3

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

## SimLev 1.6.2

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

## SimLev 1.6.1

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

## SimLev 1.6.0

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

## SimLev 1.5.2

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

## SimLev 1.5.1

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

## SimLev 1.5.0

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

## SimLev 1.4.3

Patch-Update (R/Python/Julia). Ergebnisse und Meldungen bleiben unverändert, die Druckausgabe ändert sich nur durch zwei Korrekturen (unten); dazu ergänzt 1.4.3 Dateien, die in 1.4.2 fehlten, und ersetzt die Beispieldaten.

- Vollständigkeit: Julia: src/result.jl (Ergebnisobjekt SimLevResult mit print und summary) fehlte in 1.4.2, obwohl SimLev.jl die Datei einbindet; das Paket ließ sich daher nicht laden. R: die Hilfeseiten momentum_score.Rd und result_analysis.Rd fehlten in 1.4.2 und sind ergänzt.
- Beispieldaten: anlageklassen.csv neu erzeugt (in allen drei Paketen, mit Erzeugerskript). Rendite, Volatilität und Korrelation sind jetzt runde, hypothetische Annahmen zur Konstruktion eines Beispieldatensatzes (Rendite/Volatilität p. a.: Aktien 9 %/16 %, Anleihen 5 %/6 %, Rohstoffe 7 %/16 %, Managed Futures 8 %/10 %), kein Abbild realer Märkte; in 1.4.2 folgten sie Abrams, Bhaduri und Flores (2012), der Abschnitt „Beispieldaten“ in LITERATUR.md entfällt. Fallstudie im README, Tutorials und Abbildungen mit den neuen Daten neu gerechnet.
- Druckausgabe berichtigt (Zahlen unverändert): Im Druck von withdrawal_simulation() (summary) stehen fehlende Werte („–“) wieder rechtsbündig in ihrer Spalte; die Breite wurde mit sprintf("%10s") in Bytes statt Zeichen bemessen, und der Gedankenstrich hat in UTF-8 drei Bytes, die Zeile war daher je Spalte um zwei Zeichen zu kurz (R, Python und Julia). Julia: display() hängt an Ergebnisobjekte, deren Druck schon mit einem Zeilenumbruch endet (z. B. Optimierung, Parametersuche, sharpe_deflated, overfit_pbo), keine Leerzeile mehr an; die Ausgabe gleicht damit der von R und Python.
- Dokumentation: Versionsnamen statt Commit-Verweisen; der frühere Stand des R-Pakets heißt „0.5.0 (Vorfassung vor den Korrekturen)“ (erklärt in der Einleitung von r/NEWS.md).
- Tests: Der Abgleich der Beispielausgaben (tests/werkzeuge/doku/beispiele.py) vergleicht auch Leerzeilen; die Entnahme-Fälle in gleichlauf und fehler sind an den berichtigten Druck angepasst.

## SimLev 1.4.2

Patch-Update (R/Python/Julia). Ergebnisse, Ausgaben und Meldungen bleiben unverändert; neu sind Dokumentation, Hilfe, Beispieldaten und die Gliederung der Tests.

- Dokumentation: Das Haupt-README ist eine Fallstudie (Aktien, Anleihen, Rohstoffe und Managed Futures für einen deutschen Privatanleger, Ansparphase und Entnahme) mit Code in R, Python und Julia und echten, in allen drei Sprachen gleichen Ausgaben, dazu ein Haftungsausschluss. Je Sprache ein Tutorial mit denselben Kapiteln (R: Vignette, Python und Julia: examples/tutorial.md); das frühere R-Tutorial inst/tutorial geht darin auf. Kurze Sprach-READMEs, DEVELOPING je Sprache, Zuordnung der Funktionen in STRUKTUR.md und Quellen in LITERATUR.md; der Ordner docs entfällt, die Bilder liegen bei den Paketen. Alle drei Sprachen sind gleichrangig beschrieben: Die Rechenkerne liegen als gemeinsamer C/C++-Code in core/, die Sprachpakete bilden die Schnittstelle darum.
- Beispieldaten: anlageklassen.csv (synthetische Tageskurse für Aktien, Anleihen, Rohstoffe und Managed Futures 2005–2024; Rendite, Volatilität und Korrelation nach Abrams, Bhaduri und Flores 2012) mit Erzeugerskript, in allen drei Paketen.
- Hilfe: Alle 116 Exporte haben in R, Python und Julia Beschreibung, Argumente, Rückgabe und ein lauffähiges Beispiel; Python- und Julia-Docstrings inhaltlich gleich der R-Hilfe. Berichtigt: withdrawal_simulation ohne das nicht vorhandene Argument sparer_pauschbetrag, die alten Einzelargumente galten bis 0.8.0, DCC-Schätzung mit BFGS (Nelder-Mead nur als Rückfall).
- Quelltext: Kommentare überarbeitet, ohne interne Arbeitsstände; Maschinencode der C/C++-Kerne unverändert.
- Tests (Ordner tests des Repositorys, nicht Teil der Pakete): nach Zweck gegliedert in methodik (Steuerrecht, Tarif, Engine, Entnahme, Kennzahlen, C-Bibliothek; Erwartung aus Gesetz, Handrechnung, Formel bzw. Testvektoren), gleichlauf (alle drei Sprachen rechnen bitgleich), fehler, ausgabe, schnittstelle und werkzeuge, mit einem Einstieg je Sprache und tests/run.sh. Aus 1.364 Referenzfällen werden 347 Tests: Szenarien, die mehrere Ergebnisse zugleich prüfen (in sechs Bereichen als Aufrufketten), und Tabellen „Eingabe → Meldung“ bzw. „Eingabe → Wert“; 5,2 statt 6,5 MB, Zeilenabdeckung in R, C/C++, Python und Julia unverändert, alle bisher geprüften Meldungen bleiben geprüft. Die methodik-Tests stehen als Tabellen mit Quelle je Zeile; die erwarteten Werte sind unverändert.

## SimLev 1.4.1

Patch-Update (R/Python/Julia). Ergebnisse und Meldungstexte bleiben gleich; in R ändert sich nur die Kopfzeile der Meldungen aus dem Kern (unten).

- R: Abbrüche und Warnungen aus dem Kern von simulation(), die bis 1.4.0 als Aufruf (conditionCall) einen festen Ausdruck der früheren Phasen trugen (Aufrufe von .perform_trade_buy, .perform_trade_sell und .perform_asset_split, if-Bedingungen mit NA, max() ohne Werte, stats::uniroot im internen Zinsfuß), nennen jetzt den Aufruf von simulation() wie die Eingabeprüfungen; bei der Ausgabe ändert sich nur die Kopfzeile (z. B. „Fehler in simulation(d, s, splits = split_rule(…))“ statt „Fehler in .perform_asset_split(…)“), der Meldungstext bleibt wortgleich. Warnungen des internen Zinsfußes außerhalb von simulation() (MWRR in result_analysis) tragen keinen Aufruf mehr. Python und Julia sind nicht betroffen (sie bilden keine R-Aufrufe nach).
- Tests: Alle Tests liegen in einem eigenen Ordner tests des Repositorys mit einem Katalog (README): Referenzfälle aus R, eine Datei je Bereich (12 statt 4.449 Dateien, 6,5 statt 43 MB), ihre Generatoren, die Suiten für R, Python und Julia, der Gleichlauf, die eingefrorene Schnittstelle und die Laufzeitmessung. Die Ordner golden und tools sowie die Testordner der drei Pakete entfallen; die Pakete brauchen zum Bauen und Prüfen keine Tests. Den Abgleich der C-Kopien macht jetzt core/sync.py. Von 4.479 Referenzfällen (4.395 Modul- und 84 Engine-Fälle) bleiben 1.364: die je Fall gemessene kleine Fallmenge, die in R (mit C/C++), Python und Julia dieselben Codezeilen erreicht wie alle Fälle zusammen (Zeilenabdeckung erhalten), dazu je exportierter Funktion ein Fall. Die Generatoren erzeugen weiter alle Fälle (bis auf einen: die Warnung von cor(…, use = "everything", method = "kendall") mit NA ist in R 4.3.3 nicht reproduzierbar); der Gleichlauf vergleicht Python und Julia mit allen. Die Eingabeprüfungen von asset_config(), create_strategy(), strategy_validate(), strategy_update_asset(), tax_profile() und simulation() (Listen-Strategie, risk_free- und Basiszins-Spalte) sind Referenzfälle im Bereich wrapper und werden in allen drei Sprachen gegen R geprüft.

## SimLev 1.4.0

Minor-Update (R/Python/Julia). Ergebnisse, Ausgaben, Warnungen und Fehler bleiben bitgleich zu 1.3.0 (R); Python und Julia sind in den unten genannten Fällen jetzt wie R.

- simulation(): Die Engine ist ein gemeinsamer C++-Kern für R, Python und Julia (core/engine_core_impl.h, core/prepare_core_impl.h, core/evaluate_core_impl.h). Er umfasst die Tagesschleife (Kauf, Verkauf, Sparplan, Rebalancing, Liquidation), die Steuerphasen (Jahreswechsel, Vorabpauschale, § 23, Günstigerprüfung und Tarif, Verkäufe zum Ausschöpfen des Freibetrags, Steuerzahlung, Splits), die Vorbereitung (Termine wie seq.Date, Flags, Anfangszustand) und die Auswertung (Renditen, XIRR, Risikokennzahlen). Warnungen, Fehler und details-Ausgaben gibt der Kern als Codes aus; die Texte setzen die Sprachen wortgleich und in derselben Reihenfolge wie bisher. In den Sprachen bleiben Eingabeprüfung, Datenaufbereitung, Ergebnisobjekte, print, summary und plot sowie die Kennzahl-Helfer calculate_*.
- Laufzeit gegenüber 1.3.0 (tools/bench, Median über 6 Runden, alt und neu abwechselnd): S30 (eine Simulation über 30 Jahre mit Sparplan, Rebalancing und Steuer) R −94 %, Python −79 %, Julia −39 %; T3 (bootstrap_study mit Simulation je Pfad) R −64 %, Python −30 %, Julia −23 %. Aufgaben ohne simulation() unverändert im Rahmen der Messstreuung.
- Python und Julia (Abweichungen von R behoben): NA in einer Signalspalte bricht nicht mehr ab, sondern wirkt wie in R (kein Handelstag; an einem Jahreswechsel Abbruch wie R mit „missing value where TRUE/FALSE needed“), auch bei Signalen ohne Bestand bzw. ohne Geld. risk_free als logische oder Text-Spalte wird wie as.numeric gelesen, mit der Warnung „NAs introduced by coercion“. Ein Terminplan mit Spanne 0 oder negativ bzw. mit Start nach dem letzten Tag meldet den Fehler wie R statt in eine Endlosschleife zu laufen. NA in Bedingungen der Auswertung bricht wie in R ab, statt weiterzurechnen.
- Julia: Erster Aufruf jeder Hauptfunktion in einem frischen Prozess höchstens etwa 1 s (vorher bis 6 s); dafür Vorkompilieren etwa 240 s und Cache etwa 118 MB. Die Feldgrößen der flachen Felder zwischen Julia und der C-Hülle werden beim Vorkompilieren abgeglichen.
- Gleichlauf: Zufallsprüfungen über simulation() (sim_fuzz), Terminpläne (sched_fuzz) und Kennzahlen (metric_fuzz) mit Referenz aus R 1.3.0 in tools/gleichlauf/run.sh.

## SimLev 1.3.0

Minor-Update (R/Python/Julia).

- withdrawal_simulation: Tarifweg mit tax_profile(income = income_tariff(...)). Veranlagung je Planjahr und Pfad mit Einkommensteuer, Solidaritätszuschlag, Kirchensteuer, Günstigerprüfung und Kirchensteuer-Saldo des Vorjahres, gerechnet wie in simulation() (gemeinsamer Kern core/tariff_core_impl.h, bitgleich zu den R-Funktionen von simulation()). Der Saldo eines Jahres wird mit der ersten Entnahme des Folgejahres gezahlt bzw. mindert sie; eine Erstattung über die Entnahme hinaus fließt ins Depot. Am Pfadende und am Horizont wird sofort abgerechnet. Das zu versteuernde Einkommen gilt nominal wie angegeben (eine Zahl für alle Planjahre oder ein Vektor der Länge Planjahre; nach Kalenderjahren benannt nur mit einem SimLevResult als start_value). Das Argument income (z. B. Rente) zählt nicht dazu; den steuerpflichtigen Teil rechnen Nutzer selbst in taxable_income ein. Kirchensteuer und Günstigerprüfung werden wie bisher ausdrücklich in tax_profile() angegeben, nichts wird aus der Ansparphase übernommen. Neues Ergebnisfeld tariff_years (nur mit Tarifweg). Ohne Tarifweg bleiben alle Ergebnisse gleich.
- income_tariff() nimmt einen Vektor ohne Namen an; simulation() meldet einen solchen Vektor jetzt beim Lauf statt beim Aufruf von income_tariff().
- Python und Julia: Datumsformat mit allen strftime-Schaltern, Breiten und E/O-Formen wie R unter Linux (glibc); %OS beachtet digits.secs der internen Optionen; leeres Format und Ergebnisse über 2048 Bytes wie in R.
- Python und Julia: Zahlenlesen wie as.numeric (mehr als 17 Ziffern, Überlauf knapp über DBL_MAX, Hex-Zahlen mit sehr kleinem Exponenten, "-nan", "0x ") und %% bzw. %/% einschließlich NaN-Vorzeichen jetzt wie R; Python rechnet ohne numpy.longdouble über den gemeinsamen Kern core/slc_rbase_num.c.
- Dokumentation: Quelle zu regime_hmm berichtigt (Nystrup u. a. 2015, Journal of Portfolio Management 42(1)), Rabiner (1989) und Schwarz (1978) ergänzt; Quellen und Abweichungen für die Entnahmeregeln clyatt, endowment, sensible, hebeler, cape, one_over_n und abw.
- Herkunft und Rechte: einheitlicher Herkunftsblock in den Dateiköpfen; die gemeinsamen Kerne core/slc_rbase* sind als Nachbildung von R-Quellen ausgewiesen; COPYRIGHTS in allen drei Paketen gleich gegliedert (u. a. Singleton-Quicksort, Brent, hclust, Kalenderalgorithmen nach Hinnant); das Python-Wheel enthält COPYRIGHTS.md.
- Gleichlauf: Zufallsprüfungen für NA/NaN in den Engine-Kernen, Datum, R-Grundfunktionen und Tarif laufen in tools/gleichlauf/run.sh mit; R und Python werden dort stets vollständig neu gebaut.

## SimLev 1.2.0

Minor-Update (R/Python/Julia).

- sGARCH-Schätzung in einem einzigen Lauf: Trust-Region-Newton mit exakter Hesse-Matrix (Likelihood, Gradient und Hesse-Matrix in einem Durchlauf) auf den natürlichen Parametern mit den Schranken omega, alpha, beta >= 0 und alpha + beta < 1; der Startpunkt wird ohne Optimierung aus 12 Kandidaten (Variance Targeting und Momentenschätzer) nach der Likelihood gewählt. Ein Fit kann den Rand alpha = 0 so wieder verlassen. Auf 160 Prüfreihen stets der beste bekannte Wert (1.1.0: 38-mal darunter), auf 720 neuen simulierten Reihen 18-mal darunter (1.1.0: 213-mal); im Mittel schneller als 1.1.0. sGARCH-abhängige Ergebnisse (GARCH-Bootstrap, DCC) ändern sich. Die Persistenz am Rand ist jetzt genau 1 - 2^-50, die IGARCH-Warnung kann daher häufiger erscheinen.
- MS-GARCH: Likelihood und Gradient in einem Durchlauf, eigene Fassung für 2 und 3 Regime; etwa 1,6- bis 1,8-mal schneller bei gleichen Ergebnissen. Die Starts laufen mit cores > 1 parallel (POSIX-Threads, unter Windows nacheinander); das Ergebnis hängt nicht von der Thread-Zahl ab.
- Eine Bibliothek für alle Sprachen: Julia rechnet die Kerne von Engine, Steuer, FIFO, Entnahme und Research über dieselben C++-Kerne wie R und Python (C-Schnittstelle core/simlev_cabi.cpp); die eigenen Julia-Nachbauten entfallen. Julia braucht dafür einen C++-Compiler.
- Python und Julia rechnen die Nachbildungen der R-Grundfunktionen (Summen, Kumulationen, Sortierung, Rang, Quantile, tabulate, findInterval, cov/cor) über einen gemeinsamen C-Kern (core/slc_rbase*); Python bis zu 3-mal, Julia bis zu 1,5-mal schneller in den betroffenen Aufgaben. Kleine Randfälle (x^NA, findInterval mit einem Stützpunkt, Kendall mit Inf) verhalten sich jetzt wie in R.
- Engine-, Steuer- und FIFO-Kerne: Treffen NA und NaN in einer Rechenoperation zusammen, gilt die dokumentierte Regel „NA vor NaN“, unabhängig von Compiler und Operandenreihenfolge. R, Python und Julia rechnen damit auch in solchen Randfällen bitgleich; in R ändern sich nur NA/NaN-Randfälle, Ergebnisse mit gewöhnlichen Zahlen bleiben gleich.
- Python und Julia formatieren Datumswerte (strftime-Formate einschließlich %OSn) und lesen as.Date im Format %Y-%m-%d über einen gemeinsamen C-Kern (core/slc_rbase_date.c); die eigenen Nachbildungen entfallen. Python ist in den Aufgaben T5–T7 um etwa 50–80 % schneller.
- Julia rechnet Summen, Mittel und Kumulationen in erweiterter Genauigkeit sowie das Zahlenlesen wie R_strtod, %%, %/% und scientific() über die C-Kerne core/slc_rbase* (neu: core/slc_rbase_num.c); die eigene long-double-Nachbildung (ld80.jl) entfällt.

## SimLev 1.1.0

Minor-Update (R/Python/Julia).

- GARCH-Schätzung: analytischer Gradient für sGARCH und GJR-GARCH (f und g in einem Durchlauf, ganz im C-Kern); GJR-Fit etwa 13-mal, sGARCH-Fit etwa 8- bis 11-mal schneller bei gleicher oder besserer Likelihood. GARCH-abhängige Ergebnisse (GARCH-Bootstrap, DCC) ändern sich in den letzten Stellen.
- GPD-, DCC- und Backcast-Schätzung mit analytischem Gradienten: GPD-Fit etwa 2,5-mal, backcast_fit (rmse, mse, hybrid; Zielfunktion jetzt ganz im C-Kern) etwa 5- bis 7-mal schneller, bei gleicher oder besserer Güte. DCC mit BFGS statt Nelder-Mead: schneller und häufig mit besserer Likelihood, in Einzelfällen (2–6 %) aber in einem anderen lokalen Optimum mit geringerer Likelihood als 1.0.0. Die abhängigen Ergebnisse (EVT, dependence_dcc, backcast_fit) ändern sich.
- Genauigkeit: Steuerkern und Kendall-Tau ohne long double (kompensierte Summen bzw. exakte Ganzzahlrechnung), damit plattformunabhängig und korrekt gerundet; keine Ergebnisänderung.
- Entnahme: withdrawal_simulation rechnet mit Kirchensteuer und Günstigerprüfung über income_rate() (gemeinsamer Steuersatz-Baustein mit simulation()); income_tariff() ergibt dort einen Fehler mit Verweis auf income_rate(). Angaben der Ansparphase werden nicht übernommen, sondern in tax_profile() angegeben.
- keep_paths: TRUE behält alle Pfade, eine Zahl k die ersten k (bootstrap_study, withdrawal_simulation); ungültige Werte ergeben einen Fehler. Vermögensfächer mit Titelzusatz „(erste k von n Pfaden)“; Chunk-Dateien tragen bei k > 0 den Zusatz _keep<k>. Geändert: bootstrap_study(keep_paths = TRUE) behielt bisher still einen Pfad.
- keep_returns: param_search(keep_returns = c("day", "none")); TRUE/FALSE ergeben einen Fehler mit Hinweis auf die neuen Werte.

## SimLev 1.0.0

Major-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Rechenkern: eigene C-Bibliothek für alle drei Sprachen (Julia per ccall): Zufallsgenerator, Verteilungen, lineare Algebra, Optimierer, GARCH/GJR-, GPD-, DCC- und MS-GARCH-Schätzung, Stineman-Interpolation, Glättungsspline, Kerndichte; geschrieben nach Fachliteratur.
- Unabhängigkeit: kein Code aus evd, imputeTS, stinepack, rugarch, Rsolnp, truncnorm oder numDeriv mehr; die Pakete stehen nur noch im Literaturverzeichnis.
- Zufall: eigener Generator mit simlev_seed() und seed-Argument; set.seed steuert SimLev nicht mehr; Ergebnisse unabhängig von cores und in R, Python und Julia gleich. Zufallsergebnisse ändern sich gegenüber 0.10.0.
- Schätzer: GJR-GARCH mit gamma < 0 unter alpha + gamma >= 0 und Stationarität (im Vergleich mit rugarch 51 von 51 Fällen gleichwertig oder besser); MS-GARCH mit analytischem Gradienten; t-Copula über ein Profil in nu mit Gauss-Grenzfall; qnorm mit eigenen Startnäherungen, rnorm und rgamma schneller als in R.
- Geändert: GARCH-Label "ml", dependence_dcc deterministisch; set_seed und rng_kind in Python und Julia entfallen; C-Bibliothek in Python und Julia Pflicht.
- Doku: Literaturabschnitt mit 112 geprüften Quellen, COPYRIGHTS und NEWS neu; Schnittstelle neu eingefroren.

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

Diese Fassung fasst den zunächst als 0.5.0 veröffentlichten Stand,
0.5.0 (Vorfassung vor den Korrekturen), Grundlage der Python- und Julia-Fassung 0.1.0, und alle danach
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

### SimLev eigenständig (1.0.0)

SimLev nutzt keine Funktionen aus
fremden Paketen mehr. Zufall und Numerik rechnet eine eigene C-Bibliothek
(kanonisch in `core/`, Kopien in `src/`, `python/src/core/`,
`julia/deps/core/`), die R, Python und Julia gemeinsam nutzen. Die Pakete
evd, imputeTS, stinepack, rugarch, Rsolnp, truncnorm, MSGARCH und numDeriv
erscheinen nur noch als Literatur bzw. Prüforakel (Abschnitt „Literatur“
[`LITERATUR.md`](../LITERATUR.md)); `inst/COPYRIGHTS` und das Feld `Copyright:` in
`DESCRIPTION` nennen keine fremden Autoren mehr. Die Quellen jedes Kerns
stehen im Kopf seiner Datei und im Abschnitt „Literatur“.

**Was ersetzt wurde:**

| Bereich | bisher | jetzt (C-Bibliothek von SimLev) |
|---|---|---|
| Zufall | R's Zufallszahlen (`set.seed()`, Mersenne-Twister, L'Ecuyer-CMRG je Pfad, `sample.int`, `rnorm`, `rgeom`, `rchisq`) | xoshiro256** mit SplitMix64-Seeding, unabhängige Ströme über Sprünge um 2^128, eigene Ziehungen (Inversion, Lemire, Marsaglia-Tsang); neu `simlev_seed()` |
| Verteilungen | `pnorm`, `qnorm`, `dnorm`, `pt`, `qt`, `lgamma`, `plogis`, `qlogis` aus R | eigene Kerne (Reihen, Kettenbrüche, Asymptotik nach DLMF) |
| lineare Algebra | `chol`, `solve`, `backsolve`, `determinant`, `eigen`, `%*%`, `crossprod`, `tcrossprod`, `qr`, `lm`, `lm.fit`, `poly`, `glm` | Cholesky, SPD-Löser, Jacobi-Eigenwerte, Householder-QR mit Pivotisierung, Logit-IRLS, Matrixprodukt mit fester Summationsfolge |
| Optimierer | `optim` (Nelder-Mead, BFGS, L-BFGS-B) | BFGS, projizierter BFGS, Nelder-Mead |
| GARCH/GJR (`bootstrap()` `"garch"`, `"gjr_garch"`, Kopplung, `dependence_dcc()`, `dependence_analysis()`) | `ugarchfit` aus rugarch mit Rsolnp (`solnp`, `gosolnp`), truncnorm und eigener Richardson-Hesse-Matrix | eigene Maximum-Likelihood-Schätzung |
| GPD (`"evt"`) | `fpot` aus evd | eigene Maximum-Likelihood-Schätzung |
| DCC | `optim` (Nelder-Mead) und eigener Filter | ganz in C |
| MS-GARCH (`"ms_garch"`, `"ms_ar_garch_m"`, `"tvtp_ms_garch"`) | eigene Schätzung mit `optim`, 2 Starts | ganz in C, 12 Starts |
| Stineman (`fill = "stine"`, `index_fill = "stine"`) | `na_interpolation` aus imputeTS mit `stinterp` aus stinepack | eigener Kern |
| Glättungsspline (`backcast_fit(model = "spline")`) | `smooth.spline` | Reinsch-Spline mit Knoten an allen Stützstellen, Glättung per GCV |
| Kerndichte (nur Grafik) | `density` | eigene Gauß-Kerndichte, Bandbreite nach Silverman |
| Welch-Test (`signal_analysis()`) | `t.test` | eigener Welch-Test |
| Bootstrap-Kerne | C++ mit R's Zufallszahlen | C mit dem Zufall von SimLev |

Weiter genutzt werden Grundfunktionen von R wie `quantile`, `sort`, `order`,
`cor`, `approx`, `filter`, `optimize`, `uniroot`, `hclust`, `p.adjust`,
`format` und `sprintf`; Python und Julia bilden sie nach (siehe
`python/COPYRIGHTS.md`, `julia/COPYRIGHTS.md`).

**Was sich für Nutzer ändert, mit Umstellungshinweisen:**

- **Zufall und `seed`:** `set.seed()`, `RNGkind()` und `.Random.seed` wirken
  auf SimLev nicht mehr; SimLev liest, setzt und löscht `.Random.seed` nie.
  Den Zustand setzt `simlev_seed(k)`; zufällige Funktionen nehmen weiter
  `seed`. Mit `seed = NULL` zieht ein Aufruf genau einmal einen Startwert k
  aus dem Zustand von SimLev und rechnet wie mit `seed = k`
  (`bootstrap()`/`bootstrap_study()` legen k unter `$seed` ab); mit
  `seed = k` bleibt der Zustand unberührt. Ergebnisse hängen nicht von
  `cores` oder `chunk_size` ab und sind in R, Python und Julia bitgleich.
  Zufällige Ergebnisse ändern sich gegenüber früher (anderer Generator,
  gleiche Verteilung); mit einem alten Seed gespeicherte Ergebnisse lassen
  sich nicht exakt wiederholen. `withdrawal_max_rate()` löst
  `horizon$seed = NULL` einmal auf und nutzt in allen Suchschritten dieselben
  Laufzeiten. Umstellung: `set.seed(1); bootstrap(…)` wird zu
  `bootstrap(…, seed = 1)` oder `simlev_seed(1); bootstrap(…)`. Eigene
  Eingabedaten dürfen weiter mit `set.seed()` und `rnorm()` erzeugt werden.
- **GARCH-Label `"ml"`:** Die GARCH-Stufe meldet ihren Weg als `"ml"` statt
  `"rugarch"` bzw. `"optim"` (Rückfälle `"momente"` und `"konstant"`; Spalte
  `method` von `dependence_dcc()`, Meldungen von `bootstrap()`). Code, der
  auf `"rugarch"` prüft, muss auf `"ml"` umgestellt werden. Die
  Schätzwerte ändern sich; die Log-Likelihood ist in den Referenzreihen gleich
  oder höher als mit rugarch (Ausnahme GJR mit negativem Leverage, unten).
  Die rugarch-Meldung zu weniger als 100 Datenpunkten entfällt; neu ist die
  Warnung „GARCH: ML-Schätzung fehlgeschlagen, verwende Moment-Schätzer“.
- **`dependence_dcc()` deterministisch:** Der seltene Rückfall auf gosolnp,
  der den Zufallszustand aus der Uhrzeit setzte, entfällt. Wiederholte Aufrufe
  liefern dieselben Zahlen, unabhängig von der Uhrzeit.
- **GJR mit γ ≥ 0:** Die Parametrisierung erzwingt γ ≥ 0. Bei negativem
  Leverage-Effekt schätzt SimLev γ = 0, wo rugarch ein kleines negatives γ
  zuließ (α + γ ≥ 0); in 19 von 51 GJR-Prüffällen lag rugarch dort besser,
  um bis zu 1,6·10⁻³ relativ in der Log-Likelihood. Umstellung: Bei Daten mit
  negativem Leverage `"garch"` statt `"gjr_garch"` verwenden.
- **Spline und Kerndichte:** `backcast_fit(model = "spline")` nutzt einen
  Reinsch-Glättungsspline mit Knoten an allen Stützstellen statt
  `smooth.spline()` (das bei vielen Punkten Knoten auswählt);
  `regression$fit` ist ein Splineobjekt von SimLev. In den Referenzfällen
  weichen die Renditen um bis zu 3·10⁻³ relativ ab, die Kennzahlen um bis zu
  1,6 %; der Zielwert des Fits ist gleich oder kleiner. Die Kerndichte in
  `plot()` von Bootstrap-Studien summiert direkt statt über FFT; gegen
  `density()` lag der Unterschied bei bis zu 4,2·10⁻³ des Maximums (nur
  Grafik).
- **Fehler bei Randfällen:** Die Kerne prüfen ihre Eingaben strenger als R:
  NA, NaN oder Inf in der rechten Seite eines linearen Gleichungssystems
  (Risikoparität, Copula-Szenarien) ergibt den Fehler „solve: NA/NaN/Inf in
  der rechten Seite“ statt NA im Ergebnis; nicht endliche Werte in einer
  Stineman-Interpolation (`fill = "stine"`) ergeben „stinterp: NA/NaN/Inf
  in y“ statt Inf/NaN; eine 0×0-Matrix ergibt ein leeres Ergebnis statt eines
  Fehlers. Die Meldung zu einer nicht positiv definiten Matrix ist deutsch
  („chol: Matrix nicht positiv definit (führende Minore der Ordnung k)“).
- **Welch-Test mit NA:** Sind in `signal_analysis()` beide verglichenen
  Bereiche konstant, sind t und p `NA`, statt dass `t.test()` mit „data are
  essentially constant“ abbricht. `signal_analysis()$fit$model` ist kein
  `lm`-Objekt mehr (Koeffizienten `(Intercept)`, `z`, `z^2`, …, Basis
  `c(center, scale)`); angepasste Werte und R² sind gleich.
- **Schranken bei BFGS und Nelder-Mead:** Die interne Optimierer-Hülle
  `.sl_optim()` bricht mit einem Fehler ab, wenn Schranken mit BFGS oder
  Nelder-Mead übergeben werden (`optim()` warnte und wechselte das
  Verfahren). Kein exportierter Aufruf ist betroffen; wer `.sl_optim()`
  direkt nutzt, wählt `"L-BFGS-B"` bzw. `"PBFGS"`.
- **Warnung zur IGARCH-Nähe:** Auf Daten ohne Volatilitätsbündelung liegt die
  ML-Schätzung oft am Rand β → 1; dann erscheint häufiger die Warnung
  „GARCH: Persistenz 1.0000 (nahe IGARCH)“ (ab Persistenz 0,999). Die
  Simulation läuft weiter; der Filter startet dann mit der
  Stichprobenvarianz.
- **Weitere kleine Änderungen:** `sharpe_haircut()` rechnet die
  Rücktransformation über das obere Ende der Normalverteilung (sichtbar nur
  bei p < 10⁻⁸); die IRLS-Warnung lautet „glm: Algorithmus konvergiert nicht“
  statt „glm.fit: algorithm did not converge“. Alle übrigen Ergebnisse
  ändern sich nur im Rahmen der Rechengenauigkeit.

**Laufzeit** (`tools/bench`, Median in Sekunden, ein Kern, vor und nach dem
Einbau der eigenen Kerne (1.0.0), beide mit dem eigenen Zufall):

| Aufgabe | R vorher | R jetzt | Python vorher | Python jetzt | Julia vorher | Julia jetzt |
|---|---|---|---|---|---|---|
| S30 `simulation`, 30 Jahre | 0,228 | 0,223 | 0,120 | 0,079 | 0,023 | 0,019 |
| T1 `bootstrap` stationär | 0,039 | 0,040 | 0,031 | 0,039 | 0,023 | 0,014 |
| T2 `bootstrap` GARCH | 0,390 | 0,028 | 0,253 | 0,040 | 0,163 | 0,021 |
| T3 `bootstrap_study` | 0,477 | 0,570 | 0,537 | 0,528 | 0,094 | 0,099 |
| T4 `withdrawal_simulation` | 0,060 | 0,110 | 0,111 | 0,111 | 0,073 | 0,052 |
| T5 `dependence_analysis` mit DCC | 0,393 | 0,051 | 0,515 | 0,114 | 0,076 | 0,031 |
| T6 `min_cvar` | 0,084 | 0,083 | 0,157 | 0,120 | 0,085 | 0,083 |
| T7 `hrp` | 0,005 | 0,007 | 0,045 | 0,044 | 0,004 | 0,004 |
| T8 MS-GARCH-Schätzung | 0,938 | 1,293 | 0,518 | 1,271 | 0,265 | 1,325 |

GARCH und DCC sind 6- bis 14-mal schneller. Die MS-GARCH-Schätzung ist in
allen drei Sprachen gleich teuer (etwa 1,3 s), weil sie jetzt im selben
C-Kern zwölf statt zwei Starts rechnet. T3 und T4 schwanken in R; zwei
Wiederholungen ergaben keinen gesicherten Unterschied.

**Entfernt:** `R/vendor_*.R` und `src/vendor_*` (evd, imputeTS, stinepack,
rugarch, Rsolnp, truncnorm), `R/richardson.R`, die früheren Bootstrap-, DCC-
und MS-GARCH-Kerne (`src/bootstrap_core.cpp`, `src/dependence_core.cpp`,
`src/ms_garch.c`) und die nicht mehr genutzten Hüllen (`.imputets_locf`,
`.dcc_filter`, `.ms_garch_filter`, `.boot_*`, `.ms_garch_unpack/pack/stat`).
Die geteilten Kerne der Engine, FIFO, Steuer, Research und Entnahme liegen
kanonisch in `core/`; ihr Maschinencode in R ist unverändert. Die
Schnittstelle ist mit `simlev_seed()` neu festgeschrieben
(`tools/api_snapshot/CHANGES.md`).

**Tests:** Die testthat-Suite und die gespeicherten Referenzfälle beschreiben
den Stand davor und sind bis zum Neuaufbau ausgesetzt (`SIMLEV_LEGACY_TESTS=1`
führt sie aus). Bis dahin prüft die Gleichlaufprüfung
`tools/gleichlauf/run.sh`: Der vollständige Lauf vom 27.10.2026 ergab 4.260
von 4.260 Modul-Fällen und 1.182 von 1.182 Engine-Fällen in Python und Julia
bitgleich zu R.

### Eigene numerische Kerne (1.0.0)

- **Verteilungen, lineare Algebra, Optimierer und Modelle aus der C-Bibliothek von SimLev statt R's stats bzw. der übernommenen Pakete:** `pnorm`/`qnorm`/`dnorm`/`pt`/`qt`/`lgamma`/`plogis`/`qlogis`, `chol`/`solve`/`backsolve`/`determinant`/`eigen`, `%*%`/`crossprod`/`tcrossprod` (internes `%m%`, je Element aufsteigend summiert), `qr`/`lm`/`lm.fit`/`poly`/`glm`, `t.test` (eigener Welch-Test), `density` (eigene Gauß-Kerndichte, nur Grafik) und `optim` (BFGS, projizierter BFGS, Nelder-Mead) rechnen in SimLev selbst. **Geänderte Ergebnisse:** Die GARCH-Stufe von `bootstrap()` (`"garch"`, `"gjr_garch"`, Kopplung) und `dependence_dcc()`/`dependence_analysis()` schätzt per eigener ML (GJR mit γ ≥ 0) statt mit rugarch und meldet den Weg `"ml"` statt `"rugarch"`/`"optim"` (Warnung „GARCH: ML-Schätzung fehlgeschlagen, verwende Moment-Schätzer“); `dependence_dcc()` ist deterministisch (kein gosolnp-Rückfall mit Uhrzeit-Seed mehr); der GPD-Fit (`"evt"`) nutzt eine eigene ML statt evd; MS-GARCH läuft ganz in C mit zwölf Starts; `backcast_fit(model = "spline")` nutzt einen Reinsch-Glättungsspline mit Knoten an allen Stützstellen (`regression$fit` ist ein SimLev-Splineobjekt), `"stine"` eine eigene Stineman-Interpolation; `signal_analysis()$fit$model` ist kein `lm`-Objekt mehr (Koeffizienten, angepasste Werte, Grad, Basis; angepasste Werte und R² unverändert); `sharpe_haircut()` rechnet die Rücktransformation über das obere Normalende. Alle übrigen Ergebnisse ändern sich nur im Rahmen der Rechengenauigkeit; R, Python und Julia bleiben bitgleich. Zusammenfassung oben („SimLev eigenständig“).

### Eigener Zufall (1.0.0)

- **Zufall von SimLev statt R's Zufallszahlen:** Alle zufälligen Funktionen (`bootstrap()`, `bootstrap_study()`, `param_bootstrap()`, `param_search()`, `sharpe_test()`, `overfit_reality_check()`, `dependence_analysis()`, `tail_regression()`, `portfolio_optimize()`, `portfolio_rolling()`, `bootstrap_pooled()`, `planning_goal()`, `scenario_copula()`, `regime_hmm()`, `withdrawal_horizon()`/`withdrawal_simulation()`/`withdrawal_max_rate()`) ziehen aus dem Zufallszustand von SimLev (xoshiro256**, neu `simlev_seed()`); `seed = NULL` zieht genau einmal einen Startwert daraus, `set.seed()` wirkt nicht mehr. Zufällige Ergebnisse ändern sich daher (gleiche Verteilung), sind aber in R, Python und Julia bitgleich und unabhängig von `cores`; `withdrawal_max_rate()` nutzt bei `horizon$seed = NULL` in allen Suchschritten dieselben Laufzeiten. Zusammenfassung oben („SimLev eigenständig“).

### Restpunkte Fonds-Wrapper (0.10.0)

- **Auswahl aus `wrapper_nav()`:** Neue Methode `[.SimLevWrapperNav`: Jede Auswahl von Zeilen oder Spalten (`x[i, ]`, `x[j]`, `x[]`, über `[` auch `head()`, `tail()`, `subset()`) liefert einen gewöhnlichen `data.frame` ohne Klasse `SimLevWrapperNav` und ohne die Attribute `inner` und `wrapper` (bisher behielt eine Zeilenauswahl Klasse und Attribute, eine Spaltenauswahl die Klasse), weil das innere Ergebnis nicht mehr zum Ausschnitt passt. Python und Julia ebenso. Das ganze Objekt bleibt unverändert nutzbar, auch in `withdrawal_simulation(x = …)`.
- **`withdrawal_simulation()`:** Eine Tabelle mit Spalte `date` (z. B. ein Ausschnitt aus `wrapper_nav()`) als `x` ergibt jetzt einen klaren Fehler mit Hinweis auf `withdrawal_cohorts(x, price = …)` (bisher „x muss eine numerische Matrix …“, in Python ohne Fehler mit unsinnigen Zahlen).
- **`strategy_from_weights()`/`portfolio_template()` mit `wrapper`:** Ein `SimLevWrapperConfig` gilt für alle Assets, eine benannte Liste solcher Objekte je Asset (Assets ohne Eintrag ohne Wrapper; in `portfolio_template()` gelten die Namen nach `map`). Unbekannte Namen, andere Elemente, eine Liste ohne Namen und `wrapper` mit `trading = "signal"` (Meldung nennt das Asset) sind ein Fehler. Bisher wurde ein `SimLevWrapperConfig` als benannte Liste je Asset zerlegt (R: Fehler von `asset_config()`, Python und Julia: Wrapper stillschweigend weggelassen).
- Neue Referenzfälle: `wrapper` 9 (jetzt 81), `data_prep` 15 (jetzt 175); alle bisherigen Fälle byte-gleich.

### Fonds-Wrapper (0.10.0)

Neu: `wrapper_config()`, `wrapper_nav()` und das Argument `asset_config(wrapper = )`. Ein Fonds-Wrapper (Zertifikat oder Fonds über eine innere Strategie) ist **ein** Asset der Strategie; `simulation()` rechnet vor der Engine seinen Anteilswert aus den inneren Spalten von `data` und handelt und besteuert ihn wie ein Einzelpapier. Alle bisherigen Referenzfälle rechnen unverändert; neu ist das Modul `golden/modules/wrapper` (72 Fälle; Python und Julia bitgleich seit Teil D).

- **`wrapper_config(strategy, rebalance, costs = funds_costs(), order_fee, volume)`:** innere Strategie (Signale erlaubt, keine verschachtelten Wrapper), inneres Umschichten, Kosten, Ordergebühr der inneren Käufe und Verkäufe (Format wie `sim_costs()`) und Fondsvolumen in EUR (Pflicht bei festen Beträgen `fixed`, `min`, `max`; die innere Rechnung startet dann mit diesem Volumen, sonst mit 100). Innere Spreads gelten wie angegeben; Werte > 0 ergeben einen Hinweis.
- **Anteilswert (`wrapper_nav()`):** innere Bruttorechnung ohne Steuern mit `fractions = TRUE`; Verwaltungsgebühr täglich je Kalendertag (`fee / 100 · Δd / 365` bzw. `/ 366` im Schaltjahr); Performancegebühr täglich gegen die High-Water-Mark abgegrenzt und am letzten Datentag jedes Kalenderjahres festgeschrieben (ESMA-Leitlinien zu Performancegebühren für OGAW; bei Zertifikaten gelten die Emissionsbedingungen). Ergebnis `SimLevWrapperNav` mit `date`, `nav`, `gross`, `fee`, `perf_fee` (abgegrenzt), `perf_paid` (festgeschrieben) und `hwm`, inneres Ergebnis als Attribut `inner`; Druck mit Zeitraum, Kosten und Endwert. Auch als Renditequelle `withdrawal_simulation(x = wrapper_nav(...))`.
- **`asset_config(wrapper = )`:** Der Asset-Name ist dann keine Kursspalte (gleichnamige Spalte in `data`: Fehler), nur `trading = "bnh"` (keine Signale auf den Anteilswert). Steuer nach `asset_class`/`tax_regime` (Zertifikat = Kapitalforderung; `tax_regime = "investment_fund"` mit Teilfreistellung und Vorabpauschale), Spread, Order- und Sparplangebühren, Kirchensteuer, `harvest` und `open_lots` wie bei jedem Asset. `print()` zeigt eine Zeile zum Wrapper; `strategy_update_asset()` (auch `wrapper =` hinzufügen bzw. mit `NULL` entfernen), `strategy_add_asset()` und `strategy_validate()` (prüft die inneren Spalten) gehen damit.
- **`simulation()`:** `splits` gelten für die inneren Spalten, der Anteilswert splittet nicht. Beginnt der Anteilswert später, gilt der bestehende Weg für später startende Assets. Mit `details = TRUE` kommt `result$wrappers` (je Wrapper-Asset der `SimLevWrapperNav`) dazu; ohne `details` bleibt das Ergebnis unverändert. Meldungen, Warnungen und Fehler der inneren Rechnung tragen das Präfix „Wrapper '<Name>' (innere Rechnung)“.
- **Aufrufer:** `bootstrap_study()`, `param_search()` (der `builder` kann den Wrapper bauen), `param_bootstrap()`, `sensitivity_*()` und `overfit_*()` gehen über `simulation()` und rechnen den Anteilswert je Pfad bzw. Lauf neu; Bootstrap zieht die inneren Spalten. `planning_lumpsum_vs_dca()` nimmt als Kurs des Wrappers den Anteilswert im Fenster. `tactical_simulation()`, `strategy_from_weights()` und `portfolio_template()` bauen ihre Strategien selbst aus Spalten bzw. Gewichten (ohne Wrapper).
- **`print(funds_costs())`** zeigt die Überschrift „Fondskosten (funds_costs)“ statt „Fondsmodus“ (Referenzfälle `engine/pr18`, `pr19`; Python und Julia gleich angepasst).

### Standard-Spread 0 und alter Fondsmodus entfernt (0.10.0)

Die Schnittstelle ist neu eingefroren (`tools/api_snapshot/CHANGES.md`).

- **Standard-Spread jetzt 0:** `asset_config(spread = 0)` statt `0.1`; wer Spreads abbilden will, gibt sie an. Ausdrücklich gesetzte Werte bleiben. Ohne Angabe rechnen damit `asset_config()`, Listen an `create_strategy()`, `strategy_from_weights()`, `portfolio_template()`, die `asset_args` von `tactical_simulation()` und die Standardstrategie von `sensitivity_leverage()` ohne Spread (bisher 0,1 %). Die Referenzfälle bleiben gleich: Ihre Generatoren schreiben `spread = 0.1` jetzt aus.
- **Alter Fondsmodus entfernt:** `simulation()` hat kein Argument `funds` mehr; `simulation(..., funds = funds_costs())` ergibt den üblichen Fehler für ein unbekanntes Argument (`unused argument (funds = funds_costs())`), ohne Sonderbehandlung. Entfallen sind der Engine-Weg `tax_mode = "funds"` (Fondskosten am 31.12. und anteilig am letzten Tag mit Teilverkauf, Performancegebühr gegen den Höchststand des Depots, Steuer auf den Gesamtgewinn bei Liquidation) sowie der Baustein `funds` in `sim_args`, Rastern und Suchräumen (Pfade `"funds.*"`); die flachen Namen `funds_fee` und `bonus_fee` sind jetzt unbekannte Argumente. Die geteilten C/C++-Kerne enthielten keinen Fondscode.
- **Umstellung:** Nachfolger ist der Fonds-Wrapper `wrapper_config()` (siehe oben) mit `funds_costs()` als Kostenbaustein: Der Wrapper wird als eigene Kursreihe (Anteilswert) gerechnet und außen wie ein Einzelpapier gehandelt und besteuert. Unterschiede zum alten Modus: Die Fondskosten werden täglich vom Anteilswert abgezogen (bisher am 31.12. aus der Summe der Tageswerte bzw. anteilig am letzten Tag), und die Performancegebühr bemisst sich am Höchststand je Anteil (bisher am Höchststand des Depots, der mit jeder Einzahlung stieg). `funds_costs()` bleibt mit Prüfung und Druckausgabe exportiert; `simulation()` nimmt es nicht an.
- **Referenzfälle:** Entfernt sind die 39 Referenzfälle des Fondsmodus: 13 in `golden/cases` (`f07_funds_liq`, `f08_funds_1231`, `f28_details_split_funds`, `r018`, `r035`, `r052`, `r086`, `r171`, `r222`, `r358`, `r443`, `r460`, `r477`), 2 in `golden/extra` (`x02_30y_funds_split_int`, `x16_funds_fee_high`) und 24 im Modul `engine` (`bk01`, `bk18`, `bk19`, `ch12`, `fee05`, `fu01`–`fu11`, `fu14`, `fu16`, `gp05`, `hv15`, `zz02`, `zz08`, `zz13`, `zz20`); Engine-Fälle jetzt 90 (55 + 35), Modul-Fälle 4.659. Alle übrigen Fälle rechnen unverändert (Nachweis und Liste in `golden/README.md`, im Repository bis 1.4.0); acht Fehlerfälle in `bootstrap`, `param_search` und `sensitivity` nennen `funds` nicht mehr in der Liste der Bausteine.

### Eingefrorene Schnittstelle (0.9.0)

Die Schnittstelle 0.5.0 ist in `tools/api_snapshot/frozen/r.json` festgehalten und wird von `tests/testthat/test-api-frozen.R` und `tools/api_snapshot/run.sh --check` geprüft; Änderungen nur über `run.sh --freeze` mit Eintrag in `tools/api_snapshot/CHANGES.md`.

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

`simulation(data, strategy, start_value = 10000, costs = sim_costs(), dca = NULL, rebalance = NULL, splits = NULL, tax = NULL, risk_free = 0, fractions = TRUE, liquidate = FALSE, details = FALSE)`

`NULL` heißt aus. Die flachen Argumente bis 0.8.0 gibt es nicht mehr (keine Aliasse); die Engine rechnet unverändert, alle Referenzfälle sind nach der Übersetzung bitgleich (Nachweis mit `golden/tools/blocks_from_flat.py`). Jeder Baustein prüft seine Argumente selbst und hat eine Druckausgabe.

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
| `tax_mode = "funds"`, `funds_fee`, `bonus_fee` | `funds = funds_costs(fee, performance_fee)`, seit 0.10.0 entfernt (siehe oben) |
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
Tagesdaten, 0.5.0 (Vorfassung vor den Korrekturen) gegen die aktuelle Fassung:

| Funktion | 0.5.0 (Vorfassung vor den Korrekturen) | aktuell |
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

Der Code des Tutorials in der Form von 0.5.0 (Vorfassung vor den Korrekturen) lief in 55 statt 115 Sekunden
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
Gebühren, Signale) waren nach dieser Runde bitgleich zu 0.5.0 (Vorfassung vor den Korrekturen). Die
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
unabhängigen Prüfern nachgerechnet. Insgesamt sind seit 0.5.0 (Vorfassung vor den Korrekturen)
alle 105 Golden-Master-Fälle neu erzeugt (einschließlich der Runden
unten). Nur bei `f18` und `f19` entsprechen alle Zahlenfelder noch denen
von 0.5.0 (Vorfassung vor den Korrekturen); geprüft mit der Python-Fassung.

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

### Korrekturen in Engine, Entnahme, Statistik und Grafik; deutsche Ausgaben

**Engine `simulation()`**

* Vorabpauschale mit dem ersten Kurs des Jahres; Aufteilung der
  Vorabpauschale unabhängig von der Reihenfolge der Lots.
* Rebalancing zum Tageskurs; keine Doppelorders bei der Aktivierung
  später startender Assets und am ersten Tag mit `balance_mode`
  (vorher kaufte der Handelsblock und das Rebalancing schichtete
  danach Reste um).
* Sortino Ratio: Downside-Abweichung über alle Beobachtungen,
  `sqrt(mean(pmin(Überschussrendite, 0)^2))` (Sortino/Price, wie
  `deep_analysis()`); vorher nur über die negativen Tage.
* Ein Signal-Asset mit offener Position investiert neues Geld.
* Liquidationstag ohne weiteren Handel, Simulationsende am 31.12.,
  Splits ohne Bestand, wachsende Lot-Liste.
* Prüfung von Listen-Strategien und der Steuerargumente mit klaren
  Warnungen. Warnschwellen für Anteil statt Prozent so, dass
  realistische kleine Prozentwerte nicht warnen: `base_rate` und
  `risk_free` unter 0,05, `balance_thresh` unter 0,2, `marginal_tax_rate`
  unter 1.
* `summary()` druckt über eine eigene print-Methode
  (`print.summary.SimLevResult`); Hilfeseite `asset_config`.

**Entnahme und Planung**

* `withdrawal_simulation()`: Vorabpauschale der Entnahmephase im Folgejahr;
  am Pfadende wie `simulation()` (Steuer mit den Töpfen des
  Folgejahres, Zwangsverkauf im ablaufenden Jahr); bei einem
  Horizont H auf längeren Pfaden Endvermögen und Steuern wie auf Pfaden mit
  H Jahren; planmäßig vollständige Entnahme der Verzehrregeln
  (`one_over_n`, `abw`, `hebeler`, `vpw`) gilt auch mit Steuern nicht als
  Fehlschlag.
* `lumpsum_vs_dca()` exakt bei konstanten Stückzahlen;
  `goal_optimize()` meldet die simulierte Erfolgsquote;
  Monatsarithmetik auf das Monatsende begrenzt; weitere Prüfungen in
  `withdrawal_max_rate()`, `withdrawal_simulation()`, `withdrawal_rule()`
  u. a..

**Statistik und Grafik**

* `regime_hmm()` schneller und bitgleich; Prüfungen in
  `portfolio_optimize()`, `upper = Inf` bedeutet keine Obergrenze
  (vorher Warnung und Abbruch); gewichtete Quantile nach Typ 7;
  Dokumentation von `seed`.
* `walk_forward()`: Fenster vom Startdatum aus lückenlos und ohne
  Überlappung.
* `bootstrap_study()` meldet Fehler und Warnungen der Einzelläufe.
* `plot()`: `panels` und `colors`; R-Farbnamen werden akzeptiert,
  Farbwerte geprüft, Transparenz über `adjustcolor()`; Layout,
  Achsen, Ränder und Farblogik überarbeitet (u. a. `style = "custom"` mit 3,
  5 oder 7 Panels ohne Warnung).

**Deutsche Ausgaben**

* Alle Meldungen und Ausgaben sind deutsch, z. B. `print(result)`: „SimLev
  Simulationsergebnisse“, „Wertentwicklung“, „Endwert“, „Risiko“;
  `summary()`: „SimLev Zusammenfassung“; das Dashboard ebenso.

**Golden-Master-Fälle**

* Korrekturen oben: 94 Fälle neu erzeugt (Sortino in allen, Rebalancing, Signale,
  Aktivierung, VP-Aufteilung, Splits, Jahresanfangskurs).
* Nachprüfung und Übersetzung: 101 Fälle neu erzeugt (deutsche
  Druckausgabe); davon 19 mit geänderten Zahlen durch die Korrektur der Doppelorders am ersten Tag mit `balance_mode` (`f06`, `f10`,
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
  Reihenfolge und In-place-Semantik in den C++-Dateien kommentiert.
* Korrektur: Mit `details = TRUE` und `taxable_income` brach
  `simulation()` ab („object 'tax_due' not found“), sobald ein § 23-Gewinn
  die Freigrenze erreichte. Die Steuer (ESt + Soli + KiSt des
  § 23-Zuwachses) wird im Tarifweg nun in der Jahresveranlagung
  ausgegeben; die Zahlen waren nicht betroffen.

### Meldungen, Zahlenformat und Dashboard

* Entnahme: Die Vorabpauschale am Pfadende wird mit den Steuertöpfen
  (Verlusttopf, Sparer-Pauschbetrag) nach dem Verkauf des Pfadendes
  berechnet.
* Engine, `details`: Im Tarifweg heißt die Zahlung aus der
  Jahresveranlagung „Veranlagung <Jahr>: Nachzahlung … (davon § 23 …,
  Kirchensteuer-Sonderausgaben …, ggf. Günstigerprüfung …)“ mit der
  Aufteilung auf die Assets, statt „§ 23 EStG: Steuer“ (auch bei Fonds ohne
  § 23-Gewinn). Nur Text, Zahlen unverändert.
* Zahlenformat, Singular/Plural: Beträge in Meldungen ohne
  englisches Tausenderkomma (`%.2f`), „1 Tag“/„n Tage“, „1 Tagesrendite“,
  ohne Wert nur „–“ (statt „– Tage“); ebenso „Kursspalte … fehlt“ und
  „Simulationsjahr“ im Singular.
* Startkapital: `summary()` zeigt „Startkapital“ (Argument
  `start_value`, neues Feld `start_capital` = `invested[1]` minus Einzahlung
  des Starttags) getrennt vom „Depotwert Starttag“ (Feld `start_value`,
  nach Kaufkosten, mit Sparrate des Starttags); das Dashboard verwendet für
  „Startkapital“ dieselbe Definition.
* Dashboard: Das Korrelationspanel zeigt die rollierende
  Korrelation zu `compare`; Panels, die ohne Vergleich bzw. Daten nicht
  gezeichnet werden können, entfallen mit Warnung statt eines leeren Felds.
* Prozent-Konvention: Die Warnung „wird als … % gelesen“ gilt auch
  für `risk_free` als Spaltenname und die Basiszins-Spalte
  (`base_rate_data`): maßgeblich ist der Median der Werte ohne `NA` und 0
  (Schwellen wie bei den Zahlen).
* Ausgaben: Alle Meldungen und Ausgaben verwenden echte Umlaute und
  ß (als `\u`-Escapes; der R-Code bleibt ASCII). Zahlen mit Dezimalpunkt;
  Tausendertrennung nur in Tabellen und Druckausgaben, dort mit Leerzeichen
  (z. B. „20 350“), nie mit Punkt oder Komma (`print()` der Zielplanung,
  `deep_analysis()`, Lump Sum vs. DCA, Achse des Backcast-Plots); Meldungen
  ohne Tausendertrennung.
* Golden-Master-Fälle: Zahlen unverändert; die Druckausgabe von 17 Fällen
  ändert sich durch das Zahlenformat in Meldungen (`f18`, `f19`, `f31`, `r001`, `r035`, `r256`,
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

### Korrektur der Fondskosten-Argumente

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
