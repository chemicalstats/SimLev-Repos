# SimLev.jl (Julia) – Änderungen je Version

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
