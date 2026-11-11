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

## SimLev 1.6.5

Version (R/Python/Julia). Erweiterungen bestehender Funktionen (neue Argumente, Ausgaben und Hinweise), Berichtigungen aus der Code- und der Mathematikprüfung nach 1.6.4 und aus der Prüfrunde von 1.6.5, ein gemeinsamer Studienkern, Meldungen aus der gemeinsamen Tabelle und ein sauberer Abbruch mit Strg-C. Gültige Eingaben rechnen bitgleich zu 1.6.4, außer bei den Punkten unter „Geändert (Ergebnisse)“ und „Berichtigt“. Ergebnisse ändern sich vor allem bei den Kennzahlen mit Kaufkosten am Starttag (auch in `result_analysis()`), bei Steuerzahlungen aus freiem Geld, beim GARCH- und MS-GARCH-Bootstrap, bei Bootstrap-Verfahren ohne angegebene Blocklänge (jetzt `"auto"`), bei `sharpe_test(method = "bootstrap")`, `sharpe_haircut()`, `sharpe_deflated()`, der Zielvolatilität, `serenity` und `martin_ratio`, bei Kennzahlen ohne Schwankung (NA statt riesiger Werte) und in einzelnen Analysen (Abhängigkeit, Optimierung, Szenarien, Rückrechnung). Öffentliche Schnittstelle (`tests/schnittstelle/CHANGES.md`): neue Argumente `sim_costs(custody_fee)`, `rebalance_trigger(combine)`, `periods` in `withdrawal_simulation()`, `withdrawal_cohorts()` und `bootstrap_pooled()`, `portfolio_optimize(cvar_coarse)`, `tactical_target_volatility(risk, estimator, alpha, lpm_order, lambda, exponent, min_exposure, risk_floor, reference, cushion, cushion_window)`, `overfit_walk_forward(correlation)`, `sharpe_deflated(expected_max)`, `sharpe_haircut(distribution)`, `tactical_rotation(vol_window)`, `overfit_pbo(n_splits, seed)`, `sharpe_test(studentize, kernel, prewhiten)`; neue Ansichten `view_cor()` und `view_rank()` für `scenario_entropy_pooling()`; in `params` von `bootstrap()` die Standardwerte `L`/`block_length = "auto"` und der Eintrag `vol_unit`; eine feste Zahl in `cores` ist der Höchstwert der automatischen Wahl.

Gleichheit der drei Sprachen: Stufenmodell wie in 1.6.4 (bitgleich; Toleranz relativ 1e-12 nur für `summary()` von `simulation()` und `sharpe_probabilistic()`, Entscheidung 152, `tests/lib/toleranz.tsv` unverändert; Druck zeichengleich). Alle Punkte gelten in R, Python und Julia gleich, wo nicht eine Sprache genannt ist; die drei Sprachen rechnen auch in den geänderten Fällen Bit für Bit gleich.

Gewollte Abweichung von R („Richtig vor R“, Entscheidung 123):

- pbeta, pt und qt des Kerns bei kleinem Formparameter (ein Parameter ≤ 1e-3, bei pt/qt df ≤ 2e-3; Entscheidung 116): das kleine Ende entsteht direkt aus der Potenzreihe (DLMF 8.17.7) mit einem ohne Auslöschung gebildeten ln Γ-Verhältnis. Rasterprobe (7 708 geänderte Werte gegen eine Rechnung mit 420 Stellen): größter relativer Fehler 4,5e-15; R 4.3.3 rechnet dort nur die erste Ordnung und liegt bis 1,0e-13 daneben (1.6.4 bis zum Faktor 1e286). Einzelheiten unter „Berichtigt (Kern)“.

Berichtigt (Engine, Kosten, Steuer, Kennzahlen):

- Startkosten zählen (MA2-1, Entscheidung 186 M4): `cagr`, `ttwror`, `twr_index` (erste Stufe W_1 / (start_value + Rate am Starttag)), Drawdowns, alle Renditekennzahlen und `summary()$total_return_twr` beziehen sich auf `start_value` plus Rate am Starttag. Beispiel (fallender Kurs, 545 Tage): `cagr` alt −0.068418 bei Spread 0,2 % und 2 % gleich, neu −0.069044 bzw. −0.074632. `result_analysis()` für ein Ergebnis von `simulation()` rechnet ebenso (Entscheidung 200): Gesamtrendite, CAGR, MWRR, Calmar, UPI und Recovery Factor beziehen sich auf den Startbetrag brutto (`invested[1]`) bzw. den Indexstand 100 vor den Kosten statt auf den Depotwert am Starttag; mit Benchmark folgt `active_return`. Beispiel Spread 2 %, Ordergebühr 100 EUR, Start 10 000 EUR, ohne Einzahlungen: `cagr` 0,155268 → 0,147039 (wie `ttwror`), `mwrr` 0,155268 → 0,147039 (wie `simulation()$cagr`), `total_return` 0,497585 → 0,467929 (wie `summary()$total_return_twr`). Mit Einzahlungen war `mwrr` schon so berechnet; ohne Kaufkosten am Starttag und für Kurs- bzw. Indextabellen bitgleich; `start_value` der Kennzahlen und die Perioden- und Drawdown-Tabellen von `result_analysis()` bleiben beim Depotwert am Starttag. Hilfe zu `total_return_twr` und `result_analysis()` angeglichen (PRG1-2).
- Steuern zuerst aus Guthaben (MA1-2, M2): an Zahltagen geht die Sparrate vor der Steuer ein; reicht das Geld des Assets nicht, zahlt das freie Geld der anderen Assets („Zahlung … EUR aus dem Geldbestand von B“), erst dann wird verkauft. Beispiel: Vorabpauschale 32,87 EUR, B hält 10 000 EUR: alt Verkauf 0,37 Stück A mit Mindestgebühr 10 EUR, neu Zahlung aus B.
- `harvest_rule(loss_pot = FALSE)` erntet nicht mehr in Jahren mit Verlusttopf (MA1-1, M1); der Verlusttopf bleibt erhalten (Beispiel 1000 EUR statt 3.5e-8).
- Nach vollständigem Verkauf bleibt kein Rest-Lot von 1e-15 Stück (MA1-3); keine Zeile „Teilzahlung … 0.00 EUR“ mehr in `details` (MA1-5).
- Kauf aus Restgeld per Kaufsignal erst ab 1e-12 des Depotwerts statt bei jedem Betrag über 0: keine Käufe aus reinen Rundungsresten mehr (z. B. 3e-16 Anteile), gleich für kleine und große Depots (A-031, Entscheidung 172). Die festen Grenzen beim Startkauf und im Rebalancing (0,005/0,01 EUR) bleiben (Entscheidung 194); deren Ursache, die Reste des Rebalancing-Verkaufs, wird in 1.6.6 behoben.
- Sharpe, Variationskoeffizient, Schiefe und Wölbung: eine Streuung im Rundungsrauschen (höchstens 16 √N ε (1 + max|x|)) gilt als 0; z. B. Festzins-Geldmarkt `sharpe` NA (`zero_volatility`) statt 2.2e13 (MA2-4, M7). Die Hilfe zu `zero_volatility` in `undefined_metrics` nennt auch `serenity` (PR1-4).
- `martin_ratio` = (CAGR − risikoloser Zins) / Ulcer Index (MA2-3, M6; bis 1.6.4 ohne Abzug).
- `serenity` ist die Serenity Ratio nach KeyQuant (MA2-2, M5, Entscheidung 194): (CAGR bzw. TTWROR − risikoloser Zins) / (Ulcer Index · Pitfall), Pitfall = CDaR(95 %) / Volatilität p. a.; das Niveau 95 % und die jährliche Rechnung sind eigene Festlegung (Quelle AlternativeSoft, LITERATUR.md). Bis 1.6.4 CAGR / (Ulcer Index · Max Drawdown); Beispiel (fallender Kurs): −7.1022 → −0.0762, mit risk_free = 2: −0.0985. Ohne Schwankung NA (`zero_volatility`).
- `risk_free` als Spalte: fehlende Werte und Zinsen ≤ −100 sind ein Fehler, ebenso eine Zahl ≤ −100 (MA2-5, M8).
- `rebalance_trigger()`: Abweichung genau auf der Schwelle löst nicht aus (kleine Toleranz, K15); Referenz 0 wird durch den ersten Wert ≠ 0 ersetzt statt den Auslöser zu sperren (K14); R meldet eine benannte Liste wie Python/Julia (D-3).
- `details`: Die Depotgebühr hat einen eigenen Anlass: Verkäufe für sie stehen unter „Depotgebühr:“ (nicht „Steuerereignis:“), die Zahlung aus dem Geld lautet „Zahlung … EUR aus dem Geldbestand von B“ (PR1-2, PRG1-4). Eine nicht gedeckte Depotgebühr erscheint in der Warnung als offene Gebühr; bei negativem Endwert nennt die Warnung „nicht gedeckte Steuer- oder Gebührenschuld“ (PR1-3).
- `index_bond()`: Rentenbarwert über `log1p`/`expm1` ohne Auslöschung bei sehr kleinen Renditen (X44-1; letzte Bits).
- `series_check()`: Wochen- und Monatsdaten ohne falsche Kalenderlücken (B-6), Python ohne numpy-Warnungen (B-10), `print(max_issues)` geprüft (W1-2).
- `tax_tariff()`: Datei mit BOM und Kommentar, nur CR als Zeilenende, NUL-Byte, Felder in Anführungszeichen in allen Sprachen gleich (B-7, B-8, X16-1).
- Python: Randfälle von Schiefe und Wölbung (sd nicht endlich) wie R und Julia (X20-2); Zahl aus Text wie R (X42-1); benannte Zahlen als `dict` mit `None` (X17-2); `SimLevWrapperNav` mit Ausgabe und Kopie (W2-2). Python und Julia: der Merkspeicher des Wrappers erkennt eine geänderte Wrapper-Konfiguration am Inhalt (X8-1; vorher drei gleiche `cagr` in `param_search`). Julia: der tiefe Vergleich für die Vorlagen des Studienkerns und den Merkspeicher der Fonds-Wrapper hielt verschiedene Symbole (und andere Werte ohne Felder) für gleich; kein Nutzerweg bekannt (PRG1-1).

Berichtigt (Bootstrap, Entnahme, Planung):

- GARCH-Bootstrap, erster Tag (CR1-1, Entscheidung 185 K1; Kern): Der erste simulierte Tag hat die unbedingte Varianz (bzw. je Regime) statt einer um den Anteil alpha zu kleinen. Probe 400 Pfade: mittleres eps² am Tag 1 6,05e-5 → 6,56e-5 (Faktor 1,083 = 1 / (1 − alpha)). Betrifft `garch`, `gjr_garch`, die MS-GARCH-Verfahren und die Kopplung weiterer Reihen.
- GARCH-Filter (CR1-3, K1): Nach der ML-Schätzung startet der Filter für Varianzen und Residuen mit derselben Varianz wie die Likelihood (Stichprobenvarianz) statt mit omega / (1 − Persistenz); die Parameter bleiben gleich, die ersten rund 50 Residuen ändern sich leicht. Das wirkt auch auf die erste Stufe von `dependence_dcc()`/`dependence_analysis(dcc = TRUE)`.
- Drift von `ms_ar_garch_m` und `tvtp_ms_garch` (CR2-C-12, K2): Der Achsenabschnitt je Regime wird nach `phi` und `lambda` (samt ihren Grenzen) neu bestimmt, sodass der bedingte Mittelwert im Regime dem Datenmittel entspricht. Pfadprobe (3000 Tage, 200 Pfade zu 2500 Tagen): Abweichung des Pfadmittels vom Datenmittel +1,14 % bzw. +1,25 % p. a. → −0,34 % bzw. −0,23 % p. a. (im Rahmen des Zufallsfehlers).
- MS-GARCH mit einem Regime unter 10 Tagen (Entscheidung 195): Nur Regime ab 10 Tagen werden auf Mittel 0 und Streuung 1 gebracht; ein kleineres Regime zieht aus allen Tagen, ohne dass alle Residuen erneut normiert werden (bis 1.6.4 hob das die Normierung der anderen Regime auf). Probe (800 Tage, drei Regime mit 601/198/1 Tagen): Residuen der Regime 1 und 2 vorher Mittel −0,018, Streuung 0,866, jetzt 0 und 1. Ohne kleines Regime bitgleich.
- Stationäre Verteilung der Regime (CR2-M-1, CR1-Y2-1, CR1-Y10-1; Kern): Start-Regime der MS-GARCH-Pfade, Start des Filters und Verfahren `regime` rechnen die stationäre Verteilung direkt (LU-Zerlegung) statt mit höchstens 1000 bzw. 2000 Potenzschritten. Beispiel Verweilwahrscheinlichkeiten 0,9999/0,999: 0,909 statt 0,773. Übergangsmatrix mit einem Regime ohne Übergang: Gleichverteilung statt NaN (CR1-Y2-2).
- ESS-Gittersuche (CR2-J-2, P04-R13, CR2-O-2): Die Pfadzahl ist genau `n` (Rest nach größtem Bruchteil; bis 1.6.4 z. B. 199 statt 200); Kombinationen ohne Pfad entfallen mit Hinweis; beim Verfahren `regime` rechnet die ESS mit der Verweildauer der geschätzten Übergangsmatrix der jeweiligen Kombination; Gitterwerte NA/NaN/0 ergeben eine Meldung statt eines Rohfehlers.
- `evt` (CR2-S-2): Der Momentenschätzer rechnet `scale` aus dem begrenzten `shape`, das Randmittel bleibt das Datenmittel. GPD-Ziehung ohne Sprung an |shape| < 1e-10 (CR1-Y23-1); `tails` gibt die Wahrscheinlichkeit eines leeren linken Rands der Mitte (CR1-R2-1).
- Rollierende Volatilität (`regime`) mit dem korrigierten Zwei-Durchgangs-Verfahren (Chan, Golub, LeVeque 1983; Entscheidung 141); Ergebnisse in den letzten Stellen anders.
- Blocklänge nach Politis-White (CR2-X51-1): Eingaben mit NaN ergeben wie eine Reihe ohne Schwankung die Blocklänge 1 (bis 1.6.4 R Rohfehler „missing value where TRUE/FALSE needed“, Julia NaN, Python 1).
- `series_shift_return` (CR2-E-7, K4; CR2-E-8, CR2-E-9): Standard-`ppy` bei Renditen (n − 1) / Spanne (10 Jahresrenditen mit Ziel 4 %: 3,59 % → 4,0009 %); Werte ≤ 0, Renditen, die wie einfache Renditen aussehen, und weniger als zwei Werte ergeben eine Meldung; bei Kursen mit Lücken zählt die Spanne vom ersten bis zum letzten vorhandenen Kurs (Probe 2,80 % → 4,0006 %).
- `portfolio_returns`, `bootstrap_pooled` (CR2-K-1, CR2-K-3): Eine ganz fehlende Periode ergibt keine Rendite über die Lücke mehr (Hinweis mit Datum); Kurse ≤ 0 oder unendlich am Periodenende sind ein Fehler mit Spalte und Datum.
- `withdrawal_perfect_rate` (CR2-M-8): Totalverlust im letzten Jahr ergibt ohne `legacy` die endliche PWR (bisher NaN), mit `legacy > 0` NA mit Hinweis (bisher −Inf).
- `.wd_lots` (CR2-X7-3): Fehlbeträge über das wertgrößte Asset hinaus werden bei den nächsten Assets ausgeglichen; Summe der Lots = Startwert, Gruppen lückenlos. `result_index` mit einem Tag und mehreren Assets: eine Zahlung je Tag (CR2-O-3).
- `planning_lumpsum_vs_dca` (CR2-F-5, K12; CR2-W3-1, CR2-W3-3): Ein Start zählt, wenn sein Fenster am letzten Datentag endet (genau `horizon` Jahre Daten reichen); ein Vorsprung mit |advantage| ≤ 1e-12 · max(1, |Werte|) ist ein Gleichstand und zählt weder als vorn (`win_rate`, MLSA) noch als hinten (MLSD); Beträge unter 1 in der Anzeige mit allen Stellen. Druck einer Teilmenge (R `x[1:3, ]`, Julia `rows(x, 1:3)`): Kennzahlen aus den vorhandenen Zeilen (CR2-W3-2).
- `planning_goal` (CR2-C-6): Rasterpunkte relativ näher als 1e-12 an Ziel oder Startwert entfallen (Probe: 237 Warnungen „collapsing to unique 'x' values“ → 0); Beträge ab 2^31 in der Anzeige nicht mehr „NA“ (CR2-X37-2).
- `withdrawal_horizon` (CR2-E-3, K32; CR2-E-4): Die Anzeige mit `seed = NULL` verbraucht den Zufallszustand nicht mehr.
- `bootstrap_study` (CR2-A-1, K9; CR2-S-3, CR2-X5-3, CR2-X4-3, E-T2-5): eigene Kennzahlen werden nach Namen zugeordnet; Quantilspalten heißen ohne Rundung (`q02.5`, `q97.5`), doppelte `probs` einmal; die Grafik übergeht Strategien mit weniger als zwei Werten mit Hinweis; verwaiste Zwischendateien in `chunk_dir` werden mit Hinweis entfernt.
- Python: Fehlender Startwert einer Niveau-Reihe heißt „NA“ wie in R und Julia (CR2-G-2); Bedingung als Funktion in `bootstrap_probability` liest Text und nullbare Spalten wie R `as.logical` (CR2-X9-2); `object`-Spalten mit Zahlen gelten als numerisch (CR2-X6-2). Julia: Wahrheitswert-Matrix gilt in `bootstrap()` als nicht numerisch, Zahlenmatrix mit `missing` als numerisch (CR2-X6-2); `withdrawal_paths` nimmt ein Tupel von Ergebnissen (CR2-X20-1); `r_summary(x, probs)` liest Argumente ohne Namen (CR2-X8-4); Zahlung 0 bei +0 und −0 einmal (CR2-X53-1).
- Python, Julia: Grafik der Entnahme mit Achsenwerten und Einheit wie R (CR2-L-1).

Berichtigt (Analysen, Optimierung, Szenarien, Grafik):

- Eine einzige Anlage in `inverse_vol`/`risk_parity`: Gewicht 1 (K38, G-4); Kovarianz mit Überlauf: Meldung (X49-1).
- `copula_fit()`: Hinweis, wenn ein Schätzwert am Rand des Suchbereichs liegt (Clayton/Gumbel oben, Frank ±60, X7-1; Gauß- und t-Copula bei 1 − |ρ| ≤ 1e-12, also nahezu vollständiger Abhängigkeit, wo die Log-Likelihood ein Rundungsergebnis ist und ohne Hinweis den AIC-Vergleich gewann, PRG2-4); Werte unverändert.
- Regime-Beschriftung mit genügend Stellen (X4-2); Zustandsspalte ganz NA erlaubt (X19-1); Grafiken: Paarnamen mit „ ~ “ (L-2), Legenden ohne DCC/KI (X7-4), Farben ab der 6./7. Reihe (X58-1, M-10), Datumsachsen unter zwei Jahren und unter 548 Tagen (X2-2, X9-3), Betragsformat mit Übertrag (X16-2).
- Python: `backcast`-Druck zeigt NA (W4-3), `view_*` mit Feld als Wert (V3-2), Datumsprüfung in `regime_states` (X11-1); `portfolio_rolling()` und `portfolio_cpcv()` nehmen `cvar_coarse` an wie R (bis dahin „unbekanntes Argument 'cvar_coarse'“; PRG2-3, ebenso Julia). Julia: Hexfarben streng (N-3), `breaks` als Paare (X4-1), erstes Extremum bei −0/+0 (X40-1), Vektor von Paaren als benannter Vektor in der Rückrechnung (H-5).
- Hilfe: `portfolio_optimize` (Ledoit-Wolf, Gerber, Denoise; M-2, M-6, M-7), `dependence_dcc` (Einheit; J-4), Copula- und QR-Formeln (V3-3), Ränder von `tail_dependence`.

Berichtigt (Forschung, Tests, Taktik, Signale, Sensitivität):

- `sharpe_haircut()`: kein Auffüllen von `n_tests` mehr (Holm und BY über die echten p-Werte, BY-Faktor im Kern; gleiche Werte, bis 10^8 ohne Speicherbedarf; CR2-I-1); bei |t| ab etwa 38 Rechnung im Log-Maßstab statt `Inf`/`-Inf` (CR2-I-2).
- `overfit_walk_forward(metric = "geometric", risk_free > 0)`: Warnung zur Überrendite unter −1 statt „NaNs produced“ (CR2-D-7, K16).
- `tactical_rules()` und die übrigen Regeltexte: Syntaxfehler in einem Text über 256 Bytes zeigen in allen Sprachen nur die Fehlerzeile bis zur Fehlerstelle (höchstens 80 Zeichen) mit `^` dahinter; die Kurzform gilt, sobald der ganze Text länger als 256 Bytes ist, auch bei frühem Fehler (bis 1.6.4 R um ein Zeichen anders, Schnitt mitten in Umlauten, Warnung „input string 1 is invalid“; CR2-X10-1, PR2-3).
- Python und Julia: komplexe Zahlen in Regeltexten (`1i`, `NA_complex_`) werden erst nach dem Zerlegen des ganzen Textes abgelehnt wie in R: ein Syntaxfehler hinter einer komplexen Konstante (`1i 2`, `H + 3i )`, `(1i`, `1e3i H`, `1i + * 2`) meldet wie R den Syntaxfehler statt „RExpr: komplexe Zahlen werden nicht unterstützt“ (Entscheidung 199, PR2-4). In R unverändert.
- `tactical_glidepath()` mit einer Anlage und `plot()` einer Gewichtsreihe mit einer Spalte (nur R; CR2-I-3, CR2-S-4); R `plot()` einer Signal-Analyse mit einem Bereich aus einer Beobachtung (CR2-X55-1); R `print()` von Zielgewichten ohne Spalte `date` oder ohne Zeilen: Tabellendruck wie Python (CR2-W2-4).
- Druck des Parameterraums: Grenzen und Rasterwerte einzeln ohne Exponentenschreibweise (bis 1.6.4 z. B. „1.23457e+06“, „1.0e+00, 2.5e+00“; CR2-W2-3).
- Julia `signal_analysis()`: −0.0 und 0.0 sind ein Signalwert (CR2-X37-1); Julia `sharpe_test`/`sharpe_min_track_record` nehmen `Vector{Any}` aus Zahlen an (CR2-X27-1); Python/Julia `plot()` einer Heatmap ohne Wertänderung (CR2-N-2); Julia `sensitivity_grid()` nimmt ein Tupel von Paaren wieder an (Beispiel der Hilfe; CR2-C-9, K28).
- Hilfe in Python und Julia: Formeln von `sharpe_probabilistic` und `sharpe_min_track_record` lesbar (CR2-V3-3).

Berichtigt (Kern, R-Nachbildungen in Python und Julia, Regelausdrücke):

- pbeta, pt, qt bei kleinem Formparameter (CR1-Y3-1, Entscheidung 116; siehe „Richtig vor R“): Beispiel `pbeta(1e-290, 1e-300, 0.5, lower.tail = FALSE)`: 1.6.4 2,557e-299 (mit Meldung), jetzt 6,691e-298; `pbeta(1e-20, 5e-17, 3, lower.tail = FALSE)`: 1.6.4 0, jetzt 2,228e-15. Die Meldung „Kettenbruch nicht konvergiert“ erscheint nur noch, wenn das gelieferte Ende betroffen ist.
- Interne Normaldichte (R `.sl_dnorm`, Python `_lib.dnorm`, Julia `SLib.dnorm`) mit `log = TRUE` für große |x| wie R `dnorm`: Schwelle `2 * sqrt(DBL_MAX)` wie R statt 1e150; für 1e150 < |x| ≤ 1,9e154 −x²/2 statt −Inf, darüber −Inf, nie NaN (CR1-Y8-2, PR1-1). Kein Paketweg nutzt `log = TRUE`.
- Zufallszahlen: `sl_unif01` liefert nie genau 1 (für eine von 2^53 Ausgaben ergab sich 1, `rnorm` dann NaN); alle übrigen Ziehungen bitgleich (CR1-Y8-1).
- Strg-C (Entscheidungen 171, 188; C-033, CR1-Y6-1): R bricht in den Kernen mit einer echten Unterbrechung ab (Bedingung `interrupt` statt des Fehlers „Benutzerabbruch“, den `tryCatch(error = )` verschluckte); die t-Copula (`copula_fit`, `scenario_copula`) bricht in allen drei Sprachen schon während der Schätzung ab (R rechnete bis 1.6.4 auf dem langsamen Weg weiter, Python und Julia erst nach dem Kern). Probe `copula_fit(families = "t")` mit 400 000 Paaren, Strg-C nach 1 s: R 28,5 s → 1,4 s, Python 15,4 s → 1,4 s, Julia 1,5 s.
- Regelausdrücke (Python, Julia; R über den gemeinsamen Umfang): `Inf:Inf` mit der Meldung von R „negative length vectors are not allowed“ (CR2-L-3); `mean(x, trim = )` nimmt nur eine Zahl an, `trim = NA` mit Werten ist der Fehler von R (CR2-Q-2); `(function(z) z)(2)`, `(\(z) z)(2)`, `base::sum(1, 2)` und `stats::sd(x)` mit derselben Meldung wie ohne Aufruf statt „attempt to apply non-function“ (CR2-D-12); `trunc(<Datum>, "years")` vor dem Jahr 0 in Python einen Tag daneben (CR2-O-6); Zahl der Länge 1 `+`/`*` Vektor mit NA/NaN im Vektor: die NA/NaN-Art wie R (CR2-X38-1, Entscheidung 189).
- Python `from_python` (Regelausdrücke): Datumsspalte mit Zeitzone ergibt den Ortstag (1.6.4 der UTC-Tag samt numpy-Warnung), `np.timedelta64` gilt wie andere Zeitspannen als „keine Daten“ statt Rohfehler (CR2-F-9); Wahrheitswerte neben Zahlen werden wie in R `c()` zu Zahlen (Python und Julia, CR2-C-11). Julia `from_julia`: `nothing` im Vektor wie `missing`, `[:a, :b]` als Text (CR2-C-11).
- `r_deparse` (Python, Julia): leere Vektoren nach Typ (`character(0)`, `integer(0)`, `logical(0)`); Julia benannte Vektoren als `c(a = 1)` und Datum nur aus NA als `structure(NA_real_, class = "Date")` (CR2-C-11).
- `r_format` (Python, Julia): `width` auch bei Wahrheitswerten und reinen NA-Vektoren; mit `big_mark` erst die Breite, dann die Tausenderzeichen wie R; Python misst Text nach Anzeigebreite (CR2-D-13).
- `cut` (Python, Julia): `breaks = Inf` mit Warnung und Meldung von R; weniger als zwei Grenzen wie R (eine Stufe „(,]“); Julia liefert die Codes immer als Vektor (CR2-D-14). `.bincode` (Kern) trifft mit genau einer Grenze und `include.lowest` diese wie R.
- Interne Hilfen: `paste(…, NULL)` hängt wie R den Trenner an (CR2-R-6); `_r_as_int1` liest Text wie R `as.integer` (Hex, nur ASCII-Ziffern, Warnungen wie R; CR2-Q-3); `optim` (intern) mit gebrochenem `maxit` in Julia und leerer Schranke in Python/Julia wie R (CR2-L-4).
- Python: `pd.NaT` als einzelnes Datum mit der Meldung statt Rohfehler (CR2-X8-3); `RList.format` mit Schlüsseln, die kein Text sind (CR2-W3-3). Julia: Text mit ungültigem UTF-8 druckt wie R `\xHH` statt `InvalidCharError` (CR2-X4-4); `attrs(1)` nennt das Argument `x` (CR2-V3-4).
- Julia `NamedMat` (CR2-W4-1, Entscheidung 189): `m["zeile", "spalte"]` (bis 1.6.4 immer MethodError), Namenvektoren `m[:, ["x", "z"]]`, Zuweisung nach Namen; Zahl der Namen wird geprüft, ein fehlender Name meldet „kein Element mit dem Namen …“ statt `KeyError`. Teilmatrizen bleiben gewöhnliche Matrizen.
- Julia `RVector`/`RFrame` (CR2-W1-5): so viele Namen wie Werte (Meldung statt späterem `BoundsError`); doppelte Spaltennamen in `RFrame` bleiben erlaubt, die Funktionen melden sie wie in R.
- Julia C-Hülle: die Ergebnisfelder eines Kerns werden nach dem Kopieren freigegeben (bis 1.6.4 bis zum nächsten Kernaufruf belegt, z. B. 93 MB nach `wd_simulate` mit 60 000 Pfaden; CR1-5). Python: Länge des Puffers vor dessen Freigabe gelesen (CR1-Y17-1).

Geändert (Ergebnisse):

- Blocklänge `"auto"` als Standard (Entscheidung 178): `params$L` (`stationary`) und `params$block_length` (`block`, `circular`) von `bootstrap()` und `bootstrap_study()` sind ohne Angabe `"auto"` statt 20: Politis-White wie `bootstrap_block_length()`, Höchstwert über die Reihen und ihre Beträge; der gewählte Wert erscheint als Meldung. Mit angegebener Zahl unverändert. Beispiel (1500 Tagesrenditen): `L` 74, `block_length` 84.
- `sharpe_test(method = "bootstrap")`: standardmäßig studentisierter zirkulärer Block-Bootstrap nach Ledoit & Wolf (2008; siehe „Neu“). Probe S07, Wochenrenditen, T = 228, B = 499: p 0,0962 → 0,124, Standardfehler p. a. 0,635 → 0,664, Intervall [−0,28; 2,18] → [−0,31; 2,39]. Bei Tabellen und Ergebnissen werden erst die gemeinsamen Perioden-Enddaten bestimmt, dann die Renditen zwischen ihnen gebildet, mit Hinweis bei übersprungenen Perioden (CR2-H-2); `method = "hac"`: Schwankung über die Abweichungen vom Mittel (Entscheidung 142, letzte Stellen).
- `sharpe_haircut()`: p-Wert und Rückrechnung mit der t-Verteilung mit T − 1 Freiheitsgraden (Harvey & Liu 2015, Gl. 3; Entscheidung 190); bei kurzen Reihen größerer Abschlag (z. B. T = 36, SR 1 p. a. monatlich, 10 Tests: Abschlag Bonferroni 0,878 → 0,942). Mit dem Standard braucht ein Vektor `n_obs >= 2`. `distribution = "normal"` rechnet wie bisher.
- `sharpe_deflated()`: erwartetes Maximum ohne Können exakt (Gauß-Legendre-Quadratur im Kern) statt der Näherung von Bailey & López de Prado; nie negativ, für N = 1 genau 0 (CR2-K-2, Entscheidung 189). `sr0` und `dsr` ändern sich um wenige Prozent von `sr0`; `expected_max = "bailey"` rechnet die bisherige Näherung.
- `tactical_target_volatility()`, `tactical_conditional_volatility()`: Die Schwankung jeder Zeile wird mit den Gewichten dieser Zeile über die letzten `window` Bewegungstage geschätzt (bis 1.6.4 aus dem früher gehaltenen Portfolio; nach einem Wechsel der Anlagen ein Fenster lang falsch; CR2-V1-1) und mit dem Teiler n − 1 (bis 1.6.4 n; Risikoanteile beim Standardfenster 63 um 0,8 % kleiner; CR2-R-2). Rechnung im Kern. Attribut `volatility` entsprechend.
- `overfit_walk_forward()`: Kennzahlen ohne Schwankung (Standardabweichung bzw. Abwärtsschwankung ≤ 1e-10 je Tag) sind NA mit Warnung statt ≈ 1e146 und werden nicht gewählt; `oos_rank`, `efficiency` und Mittel über die Werte mit Kennzahl (CR2-D-4, K6). Auswahl und `oos_rank` mit Toleranz: Werte bis auf 1e-12 relativ gleich zählen als Gleichstand (erster Punkt bzw. mittlerer Rang; CR2-W2-1).
- `overfit_pbo()`: Sharpe bzw. Sortino einer Hälfte ohne Schwankung ist NA (bis 1.6.4 ≈ 1e146, der Punkt wurde immer gewählt); PBO und Verlustanteil über die Aufteilungen mit Kennzahl, Warnung mit deren Zahl (CR2-P-1). `"geometric"`: eine Hälfte mit Totalverlust (Rendite ≤ −1) hat die Kennzahl −1 (bis 1.6.4 alle Aufteilungen NA; CR2-P-2). Auswahl und Rang mit Toleranz wie beim Walk-Forward (CR2-W2-1).
- `overfit_reality_check()`: Perioden mit NA/NaN in einer Vergleichsreihe (Vektor) entfallen für alle Strategien (bis 1.6.4 R NA, Python p = 0, Julia Rohfehler; CR2-X9-1); `benchmark = <Nummer>` zählt die Spalten der Eingabe bzw. die id (CR2-D-5, K7).
- `signal_analysis()`: bei `step < horizon` (überlappende Vorwärtsrenditen) t je Bereich, t aller Stichtage und Spread mit Newey-West-Standardfehlern (Bartlett, Lag ⌈horizon/step⌉ − 1), p-Wert des Spreads aus der Normalverteilung (CR2-5, K3). Mit dem Standard `step = horizon` unverändert.
- `signal_ema()`, `signal_crossover(type = "ema")`: führende NA werden übersprungen, Warnung bei NA (CR2-V1-5).
- `param_bootstrap(map = …)`: die Angabe ersetzt gleiche Aliase der Suche (in R gewann bis 1.6.4 still die Suche; CR2-F-3, K18).
- `param_plateau()` / `summary(param_search)`: Punkte ohne eigenen Wert haben kein Plateau (`plateau_mean`, `plateau_min` NA); ein fehlgeschlagener Punkt kann nicht mehr „Bestes Plateau“ sein, `param_bootstrap(by = "plateau")` wählt ihn nicht mehr (CR2-R-1, Entscheidung 189). Bei einer Zufalls-/LHS-Suche mit genau einem Punkt eine Zeile mit `neighbours = 1` (bis 1.6.4 p Zeilen bzw. Rohfehler in `summary`, Python und Julia; CR2-X1-1).
- `sensitivity_leverage()`: liegen mehrere Hebel mit dem besten Wert gleichauf (relativ 1e-12, z. B. Sharpe ohne Finanzierungskosten), ist `optimal` NA mit Hinweis und Druckzeile (bis 1.6.4 entschied Rundungsrauschen; CR2-X15-1, Entscheidung 189). Alle Spalten von `data` gehen mit an `simulation()` (Signal- und Ereignisspalten einer eigenen Strategie; CR2-H-6).
- Kernquantil wie R (`quantile(type = 7)`) für Bandbreiten der Kerndichte, CDaR in `min_cdar` und Kennzahlen (C-093).
- `portfolio_optimize(method = "hrp")`: Abstand der Cluster nach López de Prado (2016) – euklidischer Abstand der Spalten der Korrelationsabstandsmatrix (X17-1).
- `risk_budget` mit Budget 0: Gewicht 0, Risikoparität über die übrigen Anlagen (J-1).
- `max_sharpe`/`max_diversification`: Suchbereich der Risikoaversion wird verlängert, wenn das Optimum am Rand liegt (K8; Gewichte sonst in den letzten Stellen gleich).
- `portfolio_optimize()`, `portfolio_frontier()`, `portfolio_risk_contributions()`, `portfolio_cpcv()` mit Kursdaten: eine angebrochene letzte Periode (Abstand der letzten beiden Periodenenden kürzer als die Hälfte des mittleren Abstands, z. B. Daten bis Montag bei Wochenrenditen) fällt aus den Perioden je Jahr, Mittelwert und Kovarianz (K13, CR2-F-8, Entscheidung 195). Daten bis zum Periodenende rechnen bitgleich; `portfolio_rolling()` rechnet seine Fenster wie bisher.
- `copula_fit()`: Gauß-Copula ohne Schranke |r| ≤ 0,995 (E-T3-5), Frank-Copula numerisch stabil (X7-1); die Likelihood ist dabei gleich oder höher.
- `tail_dependence()`: Ränder gespiegelt über Ränge, Teiler n·q (S-1).
- `quantile_regression()`/`tail_regression()`: Regressoren werden vor der Rechnung zentriert und skaliert (K5).
- `scenario_risk()`: Quantil mit Toleranz wie `quantile(type = 1)` (CR2-4).
- `scenario_entropy_pooling()` mit `view_cor()`: Mittel und Standardabweichung beider Spalten werden als Gleichungen festgehalten (Mittel m, zweites Moment um m gleich s², Werte wie in der Korrelationsbedingung), damit die Korrelation nach der Umgewichtung die Annahme trifft (Entscheidungen 199, 201; PR2-2). Eigene Annahmen gehen vor: kein festes Mittel für eine Spalte mit `view_mean()` oder `view_rank()`, keine feste Streuung für eine Spalte mit `view_vol()`. Probe (2000 Szenarien, A und B unabhängig): `view_cor("A", "B", 0.8)` allein ergab vorher die Korrelation 0,5623 (sd A 2,07 → 2,51), jetzt 0,8000 bei unveränderten Mitteln und Streuungen; mit korrelierten Spalten (1500 Szenarien) ergab `view_cor(…, 0.9, ">=")` 0,76, jetzt 0,90.
- `backcast()`: `value` an Produkttagen gleich dem Produktkurs; Index später als das Produkt verankert richtig (B-1, B-2, K11). `backcast_fit(fit = c("drag", "spread"))`: Warnung, geschätzt wird nur `drag` (beide sind bei festem Hebel kollinear; K10).
- `result_heatmap()`: Haltedauer in Kalenderjahren (fehlendes Jahr = leere Zellen); grobe Daten (Monatsdaten am Monatsersten) mit Dezemberwert als Jahresende, erstes Jahr entfällt; fallen alle Zeilen auf den 1.1. (Jahresdaten zum Jahresanfang), gilt jeder Wert als Jahresende des Vorjahres, die Rendite 1.1.2010 → 1.1.2011 steht in der Zeile 2010 (N-1, Entscheidung 195).
- `result_analysis()`: bei doppeltem Datum gilt der letzte nicht fehlende Wert (D-10); Kaufkosten am Starttag siehe „Berichtigt“ (Entscheidung 200).
- Feste Zahl in `cores` ist der Höchstwert der automatischen Wahl (Entscheidungen 140, 179): `bootstrap()`, `bootstrap_study()`, `param_search()`, `sensitivity_*()`, `planning_lumpsum_vs_dca()` messen und planen mit einer festen Zahl wie mit `"auto"`, nehmen aber höchstens so viele Prozesse; bis 1.6.4 startete eine feste Zahl immer so viele Prozesse ohne Messung (kleine Rechnungen wurden dadurch langsamer). Die Ergebnisse hängen weiter nicht von `cores` ab.
- Hinweis zum Auffüllen fehlender Kalendertage nur noch bei einer Lücke über 5 Kalendertage (mehr als Wochenende und Feiertage), mit der größten Lücke (Entscheidung 180).

Neue Ablehnungen und Meldungen (Ergebnisse gültiger Eingaben unverändert):

- Meldungen aus der Tabelle (Entscheidung 193, FB-7): die an Anwender gerichteten Fehler- und Warnungstexte der Paketdateien, die bisher direkt im Code standen, kommen aus `core/meldungen.tsv` (Schlüssel mit Paketpräfix, z. B. `a.*`, `b1.*`, `b2b.*`, `c.*`, `e.*`; Wortlaut gleich; in den Dateien von Paket A allein 351 Aufrufe); interne Fehler bleiben im Code und tragen den Funktionsnamen, englische Texte der R-Nachbildungen bleiben. Julia: Texte der Tabelle mit Prozentzeichen (`%%`) erscheinen wie in R und Python mit „%“. Meldungen zu Zahlen als Text und zu unlesbaren Datumswerten ohne R-Befehle, in allen Sprachen gleich (K29, CR2-D-9).
- Fehlt die Spalte `date`, sagt die Meldung, dass das Datum eine eigene Spalte sein muss (FB-4). Datumstext streng (K27): „2024-01-011“ und „05-01-2024“ sind Fehler (`asset_config(start)`, Bausteine, `.to_date`). Einzelnes Datum vor dem 01.01.0001 überall abgelehnt (Python kennt kein Jahr 0).
- Engine und Bausteine: `simulation()` mit Ereignisspalte (`event_col`) nur aus Signalen TRUE/FALSE bzw. 0/1 (K36), Hinweis, wenn `event_weight` an Ereignistagen nicht verwendbar ist (G-6); Python: vier Eingabefehler mit Meldung statt `UnboundLocalError` (A-3); `taxable_income` als Python-`Series` mit `RangeIndex` (K17) und Tabelle mit fehlendem Jahr (C-2, D-15) mit einer Meldung in allen Sprachen. `strategy_from_weights()`: fremde oder doppelte Namen je Asset sind ein Fehler (K30); Summenmeldung mit 8 Stellen und „Inf“ in Python (E-6, X3-1); Julia nimmt einen einzelnen benannten Wert an. `sim_args()` lehnt einen Nicht-Baustein ab (F-1); doppelte Tage in `dca_plan`/`rebalance_plan` ohne Füll-Leerzeichen (F-2), R nennt sie ohne „L“ (z. B. `days = 1` statt `1L`; CR2-X6-3); Warnung bei `income_rate(soli_rate = 0.055)` und `funds_costs(performance_fee = 0.05)` (V2-3); Geldbeträge im Druck ohne Exponentenschreibweise (W2-3); `wrapper_config`-Meldungen (G-5). `chk_as_num` (Tarifdatei von `tax_tariff`) mit strenger Zahlengrammatik: „1400e“, „0x1p3“, „Infinity“ sind ein Fehler (R und Julia lasen sie bis 1.6.4; CR2-X13-1, Entscheidung 189); `chk_msg` verbindet Werte mit Länge ≠ 1 mit „, “ (R gab leere bzw. aneinandergehängte Meldungen; CR2-W1-4).
- Daten und Indizes: `index_total_return()` verlangt Kurse > 0 (I-4); `series_align()` mit leerer Quelle meldet das (I-5); `series_splice()` prüft Zeilen und Werte (C-5); `index_bond()`, `index_money_market()`, `index_currency_hedged()` prüfen das Datum, `series_deflate()` Preisindex > 0 und `suffix` (V1-4); Stufentabellen in `index_money_market()`, `index_bond()` (`yield`), `index_currency_hedged()` (`domestic_rate`, `foreign_rate`) und `series_convert_currency()`, die erst nach dem ersten Datentag beginnen, warnen (V3-4.4). `index_money_market()`: fehlende Werte in der Zinsreihe und ein Tagesfaktor ≤ 0 sind ein Fehler (bis 1.6.4 als Spalte still mit dem Vorwert gefüllt bzw. negativer Index; CR2-V3-4). Preisindex, der mehr als 92 Tage vor dem letzten Datum der Reihe endet (`series_deflate()`, `result_analysis(inflation = …)`): Warnung „Der Preisindex endet am …; danach gilt sein letzter Stand“ (bis 1.6.4 still ohne weitere Inflation; CR2-X5-1). `split_rule()`: benannte Schwellen auch in Python (`dict`) und Julia (`NamedTuple`) wie in R (CR2-W3-3). Python: `portfolio_template("60_40")` positionsweise wie R (J-3).
- Bootstrap: unbekannte Namen in `params` und `ess_grid` sind ein Fehler; `vol_window` höchstens so lang wie die Historie, `n_regimes` höchstens ein Regime je 10 Renditen; unbekannte oder abgekürzte Felder in `letfs` sind ein Fehler; eine Pfadspalte `date` in `bootstrap_data` ist ein Fehler; `bootstrap_probability`/`bootstrap_validate` ohne Rohfehler (CR2-O-1, CR2-M-9, CR2-A-2, CR2-N-4, CR2-H-3). `bootstrap()` bricht vorab ab, wenn die Pfade mehr Arbeitsspeicher brauchen als frei ist; Hinweis bei Pfaden über das Fünffache der Historie und bei GARCH-Schätzung auf weniger als 500 Renditen (FB-5, FB-6). `bootstrap_study`: andere Kennzahlnamen in einem Pfad und ungültige `probs` mit Meldung. Python: leere `indices` mit Meldung (CR2-A-2); `simlev.bootstrap.summary`/`plot` ohne passendes Objekt mit Meldung (CR2-O-7).
- Entnahme und Planung: `withdrawal_cohorts` (CR2-A-6): Kurs- und Preisindexwerte ≤ 0 oder unendlich sind ein Fehler mit Spalte und erstem Datum. `withdrawal_max_rate` (CR2-F-10, K22): Hinweis, wenn schon `upper` die Zielquote erreicht (Ergebnis ist die Suchgrenze), mit Zusatz für Regeln, die nicht scheitern können. `withdrawal_rule` (CR2-B-9, K25): die Warnung „wirkt wie ein Anteil“ gilt für alle Regeln mit `rate` und für `cape_a`; `smoothing` und `floor95` schon bei Werten ≤ 1; Anzeige der Grenzen und des Alters ohne Exponent und ohne Rundung (CR2-X6-3). `withdrawal_horizon`: nicht genutzte Argumente ergeben eine Warnung statt einer Prüfung; `normal` mit Mittel außerhalb `[min, max]` einen Hinweis (CR2-E-3, CR2-E-4). `planning_lumpsum_vs_dca()`: `months` höchstens 12 × `horizon` (bis 1.6.4 drei verschiedene Rohfehler; CR2-F-6). Kern: `wd_tariff_compact` mit negativer Jahreszahl ergibt eine Meldung statt einer Division durch null (CR1-Y9-1). Julia: `missing` in Rendite- oder Inflationsmatrix von `withdrawal_simulation` ergibt die Meldung statt eines Rohfehlers (CR2-X8-2).
- Analysen, Optimierung, Szenarien: Fehlermeldungen statt Rohfehler bzw. stiller Fehlschläge in `scenario_crisis()` mit Anlage namens `portfolio`, `start` … (K31); `tail_covar()` mit zu wenigen Perioden (R-5); `backcast()` mit leerer Stufentabelle oder Spalte ohne Wert (K-4, H-4), Tabelle ohne `date` (P-5), fehlendem `index` in R (B-3); `dependence_analysis()` mit Konstante und Zustandsvariablen (X51-1), `breaks` mit NaN (X1-2); `scenario_*` mit Matrix ohne Spaltennamen oder nicht endlichen Werten (P-6); `view_*(op = )` ohne Teilnamen (V3-4); `plot(<SimLevAnalysis>, series = 1.5 / NaN)` (C-4); `export_dashboard()` in einen fehlenden Ordner bzw. bei Fehler der Grafik (V1-3). Hinweise: `cov = "ledoit_wolf"` bei Varianzen, die sich um mehr als das 100-Fache unterscheiden (M-2); Stressband von `scenario_copula()` unter 1/T bzw. über 1 − 1/T (K20); `view_vol(…, 0)` (V3-4); Krise nur teilweise in den Daten (E-2); Rückrechnung: Zinsspalte beginnt spät (H-4), Produkt endet vor dem Datenende (K23), Stufentabelle beginnt nach dem ersten Datentag (V3-4); `result_analysis()`: Zeilen ohne Datum entfernt, Sharpe Ratio ohne Schwankung nicht definiert (D-10, I-6); Druck der Effizienzlinie bei flacher Kurve (X3-2). `backcast_fit()`: Warnung, wenn ein Schätzwert an der Grenze von `bounds` bzw. am Rand von `grid` liegt oder die Suche nicht konvergiert (A-5); `regime_hmm()`: Warnung bei erreichter Iterationsgrenze (K34). Python: `summary()` mit Katalogmeldung (O-7). Julia: `NamedTuple`/`Dict` nicht als Tabelle (D-11).
- Forschung, Tests, Taktik, Signale: `overfit_pbo`, `overfit_walk_forward`, `sharpe_deflated`, `sharpe_haircut`, `overfit_reality_check`: Renditen unter −1 und `dates` mit nur einem Tag sind Fehler mit Meldung (CR2-G-7); `overfit_pbo` ohne zwei gültige Paare ohne Rohmeldung von `lm` (CR2-P-3). `sharpe_test(method = "bootstrap")`: Stichproben mit Varianz 0 ergeben eine klare Meldung statt eines Rohfehlers, `block` höchstens die Zahl der Renditepaare (CR2-H-1), mit `studentize = TRUE` höchstens ein Viertel der Renditepaare (mindestens 4 Blöcke für die Block-Kovarianz Ψ*, sonst ist sie singulär; bis dahin lieferten größere Blöcke ohne Meldung unbrauchbare p-Werte und Intervalle, Probe T = 120, `block = 60`: Intervall der Differenz p. a. [−45,5; 47,1]): „sharpe_test: block darf mit studentize = TRUE höchstens 30 sein (ein Viertel der 120 Renditepaare, abgerundet): …“ (PR2-1); der Standard `max(2, round(T^(1/3)))` ist nie betroffen. `overfit_reality_check()`: Inf in der Vergleichsreihe und weniger als drei Perioden sind Fehler (CR2-X9-1, CR2-D-6); Meldung zur Spalte mit Funktionsnamen; Druck „1 Strategie“ (CR2-W3-3). `param_bootstrap(include = …)`: ein Name `p<id>` eines Suchpunkts ist ein Fehler (Python/Julia ersetzten den Suchpunkt still; CR2-F-4, K35); Namen ohne Exponentenschreibweise. `tactical_rules()`: ein Regeltext mit mehreren Ausdrücken ist ein Fehler (bis 1.6.4 galt still der letzte), das Ergebnis eines Ausdrucks oder einer Funktion muss logisch oder 0/1 sein, Längenmeldung mit Regel und beiden Längen (CR2-E-12, K33). `tactical_target_volatility()`, `tactical_conditional_volatility()`: `window` höchstens 2147483647 (Julia `InexactError`; CR2-X2-1); Julia: Paar mit Wahrheitswert als Gewicht mit derselben Meldung wie R/Python (CR2-X15-2). `signal_volatility()`: `n >= 2`, Kurse > 0 (CR2-R-4). `sharpe_probabilistic()`: eine Matrix wird in allen Sprachen abgelehnt (CR2-V2-4). Python `signal_combine` lehnt eine Tabelle ab (K37).
- Parametersuche und Sensitivität: `param_search()`: `burn_in` ≥ Zahl der Datenzeilen ist vorab ein Fehler (bis 1.6.4 nach der Rechnung „alle Punkte fehlgeschlagen“ mit je Sprache anderer Meldung); Hinweis, wenn der Zufalls-/LHS-Plan weniger als `n` zulässige Punkte hat (CR2-A-7, K22); ein falscher Name in `objective` wird nach dem ersten Punkt gemeldet statt nach allen (CR2-W1-3). `param_space()`: doppelte Dimensionsnamen und Datumswerte sind in allen Sprachen ein Fehler (CR2-O-4, CR2-W2-4); `param_range(step = …)` höchstens 1e6 Rasterpunkte, `n` neben `step` ohne Rohfehler (CR2-M-5). `sensitivity_rebalancing()`: `frequencies` vorab geprüft (Einheit month/quarter/year, Abstand ganze Zahl bis zur Grenze von `rebalance_plan()`); einzelne fehlgeschlagene Läufe mit Warnung (Anzahl und Meldungen), alle fehlgeschlagen ein Fehler (CR2-C-10, K26). `sensitivity_leverage()`: alle Läufe fehlgeschlagen = Fehler mit den Meldungen, einzelne = Warnung; eigene Strategie ohne Asset `LEV` und eine Spalte `LEV` in `data` sind Fehler (bis 1.6.4 still eine leere Tabelle; CR2-H-6, Entscheidungen 189, 197). `series_leverage()` / `sensitivity_leverage()`: Datum ohne NA und aufsteigend, Index nach dem Auffüllen endlich und > 0 (Fehler mit Zeile), Zinsreihe ohne Lücke (Fehler mit Datum; bis 1.6.4 still NA, 0 oder je Sprache verschieden; CR2-V2-1). Python `simlev.param_search.summary()` ohne passendes Objekt: Meldung `e5.methode` statt `TypeError` (CR2-O-7).
- Julia `Dict`, wo die Reihenfolge das Ergebnis bestimmt (K19, CR2-7; in 1.6.5 Warnung, später Fehler): Warnung `c.dict_reihenfolge` bei einem `Dict` mit mehreren Einträgen für `strategies`, `datasets`, `candidates`, eine Liste von Reihen, `grid`, `frequencies` bzw. `space`.

Neu:

- `sim_costs(custody_fee = )`: jährliche Depotgebühr, fest (Zahl in EUR) oder `list(fixed, percent, min, max)` mit `percent` in Prozent p. a. des Depotwerts am 31.12.; im ersten und in einem angebrochenen letzten Jahr (am letzten Tag) anteilig nach Kalendertagen. Gezahlt wird aus Geld, dann durch Verkauf wie eine Steuer; zählt in `fees_paid`; `details` zeigt die Zeilen mit dem Präfix „Depotgebühr:“ (Entscheidungen 150, 194).
- `rebalance_trigger(type = "combined", combine = "and")`: UND-Verknüpfung der Teilauslöser (Standard `"or"` wie bisher; Entscheidung 150).
- `index_bond()`: Attribut `convexity` (Konvexität je Tag, Jahre²; Python auch `x.convexity`; Entscheidung 151).
- Laufzeit in Perioden (Entscheidung 173): neues letztes Argument `periods` in `withdrawal_simulation()` (die ersten `periods` Zeilen, z. B. 10 Quartale; auch für `withdrawal_max_rate()` und die Kohorten eines `SimLevResult`), `withdrawal_cohorts()` und `bootstrap_pooled()` (Länge in Perioden der `frequency`, z. B. 30 Monate). `years` und `periods` zusammen sind ein Fehler. `portfolio_returns()` hat kein Längenargument, `withdrawal_horizon()` bleibt bei ganzen Planjahren (Lebensdauer; der Kern wertet den Horizont an Jahresgrenzen aus).
- Regimefenster in Kalendertagen (E-T2-6): `params$vol_unit = "days"` (Standard `"rows"` wie bisher) misst `vol_window` beim Verfahren `regime` in Kalendertagen über die Spalte `date`; Lücken wie Wochenenden zählen mit.
- `sharpe_test(studentize = TRUE, kernel = NULL, prewhiten = NULL)` (Entscheidungen 177, 197): `method = "bootstrap"` rechnet standardmäßig den studentisierten zirkulären Block-Bootstrap nach Ledoit & Wolf (2008, Abschnitt 3.2.2, Gl. 7–9): je Stichprobe Blöcke fester Länge `block` mit gleichverteiltem Start, Standardfehler der Stichprobe aus der Block-Kovarianz Ψ* = l⁻¹ Σ ζⱼζⱼ′ (l = ⌊T/b⌋), d*ₘ = |Δ*ₘ − Δ| / s(Δ*ₘ), p = (#{d*ₘ ≥ d} + 1)/(B + 1), Intervall Δ ± q₀.₉₅(d*) s(Δ); `studentize = FALSE` = stationärer Bootstrap wie bis 1.6.4 (bitgleich). HAC mit `kernel = "qs"` (Quadratic Spectral, Bandbreite 1.3221 (α̂(2) T)^(1/5) nach Andrews 1991 aus AR(1)-Näherungen) und `prewhiten = TRUE` (VAR(1) nach Andrews & Monahan 1992), dann Schätzer von Ledoit & Wolf (Abschnitt 3.1) mit Faktor T/(T − 4); Standard bei `method = "hac"` (weiter der Standard von `method`) Bartlett ohne Prewhitening (bitgleich), beim studentisierten Bootstrap QS mit Prewhitening. Neue Kerne `research_vec` op 8 und 9.
- `tactical_target_volatility()`: Risikomaße `risk = "sd"` (Standard), `"downside"`, `"lpm"` (`lpm_order`), `"var"`, `"es"` (EWMA-gefiltert, `alpha`); Schätzer `estimator = "window"` (Standard) oder `"ewma"` (`lambda`, Start mit 21 Bewegungstagen); Potenzregel `exponent`; `min_exposure`, `risk_floor` (Boden der Risikoschätzung relativ zur Referenz); `reference = "median"` (expandierender Median der eigenen Risikowerte ab 63 Werten); Drawdown-Polster am Index des Risikoportfolios `cushion`, `cushion_window`; `ppy = "rolling"` (gleitende Annualisierung mit den Bewegungstagen der letzten 365,25 Tage). lit1 S1–S5, S7; Entscheidungen 175, 192, 196. Standardwerte wie bisher.
- `overfit_walk_forward(correlation = "spearman")`: Walk-Forward-Korrelation je Fenster (Tinsley 2026) zwischen In-Sample- und Out-of-Sample-Kennzahl aller Punkte, Spalten `wfc`, `oos_positive`, `is_pos_oos_neg` in `windows`, `mean_wfc` und `median_wfc` in `summary`, eine Zeile im Druck; `"kendall"`, `"pearson"` wählbar (W1/W2, Entscheidung 192).
- `sharpe_deflated(expected_max = "exact")` (siehe „Geändert“; `"bailey"` rechnet die bisherige Näherung). Die effektive Versuchsanzahl N_eff ist in der Hilfe als Heuristik ohne Quelle gekennzeichnet (Entscheidung 181; Versuchszahl über Cluster auf 1.7.0 verschoben, Entscheidung 196).
- `sharpe_haircut(distribution = "t")` (siehe „Geändert“; `"normal"` rechnet wie bisher).
- `tactical_rotation(vol_window = 63)`: Fenster der Schwankung für `weighting = "inverse_vol"` (Entscheidung 144).
- `overfit_pbo(n_splits, seed)`: Zufallsauswahl von `n_splits` Aufteilungen ohne Zurücklegen (SimLev-Zufallsstrom); Näherung ohne Literaturquelle, Standardfehler etwa sqrt(p (1 − p) / n_splits), im Druck genannt; Standard alle Aufteilungen wie bisher (E-T2-2, Entscheidung 196).
- `param_plateau()`: Spalte `valid` (Nachbarn mit Wert); `print()` für `param_range()` (eine Zeile wie im Parameterraum, CR2-W4-3). `sensitivity_leverage()`: Attribut `failed` (Hebel und Meldung fehlgeschlagener Läufe).
- `view_cor(var1, var2, value, op)` und `view_rank(vars)`: Ansichten auf die Korrelation zweier Variablen und auf die Rangfolge der Mittelwerte (`vars[1] >= vars[2] >= …`) für `scenario_entropy_pooling()` (E-T3-3). Das Ergebnis enthält die Ansichten wie übergeben in `views0`.
- `portfolio_optimize(cvar_coarse = TRUE)`: mit `FALSE` rechnet `min_cvar` nur die feine Glättungsstufe (je nach Daten bis rund 40 % schneller, gemessen 3–41 %; Gewichte in der 5.–6. Nachkommastelle anders), auch über `portfolio_rolling()` und `portfolio_cpcv()`. Erreicht die letzte Stufe die Schrittgrenze (2000), kommt immer eine Warnung (K39, CR1-2).
- `portfolio_rolling()`: Attribut `turnover` (Umschlag je Termin, Summe der absoluten Gewichtsänderungen, erster Termin gegen gleiche Gewichte; E-T3-4). `scenario_crisis(rebalance = TRUE)`: Spalte `days_to_recover_rebalanced` (Erholungsdauer des umgeschichteten Portfolios; E-T3-1).
- `regime_hmm()`: Felder `iterations`, `converged`, `n_failed`, Druckzeile „Schritte“ (K34). `backcast_fit()`: Feld `convergence` (A-5).
- `print()` und `summary()` von `SimLevResult`: bei einer Auswertung über weniger als ein Jahr (unter 365 Tagen) eine Zeile unter den Kennzahlen „Hinweis: Auswertung über N Tage (unter einem Jahr); annualisierte Kennzahlen (CAGR, Sharpe, Sortino, Calmar und weitere) sind hochgerechnet.“ (FB-6, Entscheidungen 184 und 197); keine Meldung in `simulation()`, kein neues Feld.
- Regelausdrücke: `rev`, `which`, `seq_len`, `cumprod`, `cummax`, `cummin`, `diff`, `head`, `tail` (E-T4-1) in Python und Julia wie R 4.3.3 (Typen, Namen, Datum/difftime, Warnungen, Fehler); in R über den gemeinsamen Umfang der Regeltexte.
- Julia: `RFrame(nt)` und `RFrame(; date = d, A = a)` (FB-2); `print(x)`/`println(x)`/`string(x)` zeigen bei Bausteinen und Ergebnissen die Druckausgabe (CR2-V1-2); `inherits(<RFrame>, "data.frame")` ist wahr wie in R (CR2-V3-4). Python: `print()` gibt es für alle Ergebnisse (`RList`, CR2-W1-1); `summary(x, …)` übergeht unbekannte Schlüsselwörter wie R und die Hilfe (CR2-O-7).
- Kern: `sl_ctx_set_interrupt` (Abbruchhaken für Hosts ohne Kenntnis des Kontexts); pt/qt stehen in allen drei Sprachen bitgleich über den Kern bereit (`.sl_pt`/`.sl_qt`, `_lib.pt`/`qt`, `SLib._pt`/`_qt`; Entscheidung 190).
- Doku: Hilfe zu `tax_profile()` mit Abschnitt „Rechtsstand“ – heutiges Recht für alle simulierten Jahre (M3); `average_drawdown` (mittlere Tiefe an Tagen unter dem Hoch), `avg_recovery_time` (mittlere Dauer abgeschlossener Phasen) (M9); Aktien- und Mischfonds „mehr als 50 %“ bzw. „mindestens 25 %“ (MA1-4); Formeln in Python und Julia lesbar (V3-3). LITERATUR.md: Abschnitt „Kennzahlen der Simulation“ (Sharpe 1966/1994, Sortino und Price 1994, Martin und McCann 1989; M10).

Schneller (Ergebnisse bitgleich, soweit nicht oben genannt):

- Messungen der Pakete (Median, vorher → nachher; die Maschine war dabei teils durch einen zweiten Lauf belastet):
  - Studienkern (siehe „Intern“; 1 Kern, 1 600 Pfade × 2 520 Tage mit Steuer und vierteljährlichem Rebalancing): `bootstrap_study()` R 5,4 → 3,0 s (−45 %), Python 6,0 → 4,4 s (−26 %), Julia 2,6 → 2,2 s (−17 %); `sensitivity_leverage()` R −26 %; `param_search()` mit Signalen R −13 %. `sensitivity_grid()`, `sensitivity_rebalancing()` und `planning_lumpsum_vs_dca()` ändern je Punkt die Argumente bzw. das Zeitfenster und rechnen weiter vollständig (unverändert schnell).
  - `bootstrap_pooled()`: die Ziehung der Länderblöcke (Land, Blocklänge, Startzeile) läuft im Kern statt je Zug im Interpreter (K40, CR2-6), dieselben Züge in derselben Reihenfolge; 20 000 Pfade × 30 Jahre monatlich: R 2,07 → 0,49 s (−76 %), Python 1,46 → 0,36 s (−75 %), Julia 2,63 → 0,61 s (−77 %).
  - `withdrawal_max_rate` (CR2-1): Suchschritte ab dem zweiten rechnen nur die Erfolge je Pfad. 10 000 Pfade, Median aus 7: R 0,595 → 0,422 s (−29 %), Python 0,828 → 0,522 s (−37 %).
  - R `bootstrap()` (CR2-E-13): die je Lauf festen Angaben des Pfadaufbaus einmal je Lauf wie in Python und Julia. 2520 Zeilen, ein Index, zwei Hebelprodukte, eine Zusatzreihe, n = 2000, Median aus 9 (zwei Läufe): 0,743/0,711 → 0,486/0,472 s (−34 %).
  - Julia `withdrawal_simulation` ohne Kopien der Matrizen (CR2-2; 40 × 10 000, Median aus 7: 0,124 → 0,094 s, −24 %); Vorwärtssimulation von `planning_goal` in einer typisierten Funktion (CR2-C-7; im ganzen Aufruf 500 × 4, n_sim = 2000 nicht messbar: 3,107 → 3,152 s, die Rechnung wird dort von der Optimierung bestimmt).
  - Python `signal_combine` vektorisiert (CR2-G-1): drei Signale, 1 Mio. Zeilen 2,77 → 0,048 s (−98 %); mit NA in einem object-Feld 3,13 → 1,01 s. Julia ohne Elementschleife über `Union`-Vektoren.
  - Python `plot()` einer Parametersuche: Stufen in einem Durchgang (CR2-D-16): ein Parameter, 2000 Punkte 2,41 → 0,46 s; Raster 40 × 60 0,29 → 0,13 s. Python/Julia: doppelte Rasterstufen und Planzeilen über Mengen statt quadratisch (CR2-M-3): Python 20 000 Stufen 4,26 → 0,016 s. `planning_lumpsum_vs_dca()`: R füllt die Kursspalten einmal, Julia liest Berichtsspalten ohne Kopie (CR2-F-7).
  - Python-Regelausdrücke (CR2-A-8, Entscheidung 111, teilweise): Vergleiche, `&`/`|`, Grundrechenarten und `ifelse` rechnen ab 32 Werten über numpy-Felder, Umwandlung nach außen als Feld; bitgleich (NaN-Regel über Masken). 10^6 Zeilen: `cagr > 0.05` 0,641 → 0,138 s (−78 %), `cagr > 0.05 & max_drawdown <= 0.3` 1,200 → 0,324 s (−73 %), `ifelse(sharpe > 0.5, cagr, 0) > 0.02 | abs(max_drawdown - 0.3) < 0.1` 3,478 → 0,786 s (−77 %). Julia `ifelse` mit Zahlen typstabil. Python `chk_numvec` nimmt Zahlenfelder ohne Elementschleife an (CR2-V2-2); `pmax`/`pmin` mit Einzelwert ohne `np.resize` (CR2-O-5).
  - Ohne eigene Zahlen: R `series_check()` (B-5); `tax_tariff()` merkt den Tarif ohne `system.file()` je Aufruf (Q-1); Julia `wrapper_nav()` (D-8), `index_money_market()`, `index_currency_hedged()`, `index_bond()` typisiert (V3-1). `portfolio_optimize(cvar_coarse = FALSE)` siehe „Neu“.
- Laufzeit gegenüber 1.6.4 (`tests/werkzeuge/bench/run.py` auf der ruhigen Entwicklungsmaschine, je Lauf ein frischer Prozess, ein Faden; fünf Runden mit 1.6.4 und 1.6.5 abwechselnd, je Aufgabe Median der Rundenmediane aus je 3 Läufen; genannt nur Unterschiede, deren Rundenspannen sich nicht überlappen): `bootstrap_study()` mit zwei Anlagen, Steuer und Rebalancing, 200 Pfade (T3s) R 605 → 354 ms (−41 %), Python 624 → 450 ms (−28 %); `bootstrap_study()` mit einer Anlage, 50 Pfade (T3) R 141 → 93 ms (−34 %); `withdrawal_max_rate()` mit 2 000 Pfaden × 30 Jahren (T4m) R 85 → 46 ms (−46 %), Python 88,9 → 54,5 ms (−39 %), Julia 107 → 58,3 ms (−46 %, Spannen überlappen); `bootstrap_pooled()` mit 2 000 Pfaden × 15 Jahren monatlich (T9) R 96 → 22 ms (−77 %), Python 54,7 → 15,8 ms (−71 %), Julia 88,0 → 23,4 ms (−73 %); `signal_combine()` dreier Signale mit 10^6 Zeilen (T10) Python 1,97 s → 33,6 ms (−98 %), Julia 424 → 6,4 ms (−98 %), Julia erster Aufruf 1,01 s → 351 ms. Alle übrigen Aufgaben (Laden, `simulation()` über 30 Jahre, GARCH-Bootstrap, Entnahme mit und ohne Steuern, `dependence_analysis()`, `min_cvar`, `hrp`, MS-GARCH-Fit) liegen innerhalb der Streuung (z. B. `simulation()` 30 Jahre R 6,0 → 7,0 ms, Python 4,0 → 4,2 ms; MS-GARCH-Fit R 320 → 343 ms, Python 279 → 287 ms, Julia 306 → 293 ms).

Langsamer:

- `bootstrap()` stationär ohne angegebene Blocklänge (T1, 200 Pfade × 2 520 Tage): R 22 → 42 ms, Python 11,5 → 26,4 ms, Julia 13,4 → 34,6 ms, weil der Standard jetzt `L = "auto"` ist (Politis-White je Lauf, andere Blocklänge; Entscheidung 178). Mit fester Blocklänge `L = 20` (Nachmessung, vier Runden): R 21 → 17,5 ms, Python 12,4 → 14,1 ms (Streuung), Julia 15,2 → 9,9 ms.
- Julia, erster Aufruf nach dem Laden: `bootstrap()` stationär (T1) 93 → 206 ms, `bootstrap_study()` (T3) 196 → 377 ms, mit Steuer und Rebalancing (T3s) 297 → 456 ms (Ursache nicht untersucht); die folgenden Aufrufe sind nicht langsamer.
- `portfolio_optimize(method = "min_cvar")` mit Tagesdaten bis Dienstag (T6): in der Hauptmessung innerhalb der Streuung (R 74 → 84 ms, Python 70,9 → 84,4 ms, Julia 70,0 → 91,0 ms), in der Nachmessung R +25 %, Julia +35 %. Ursache ist die geänderte Eingabe: die angebrochene letzte Woche fällt weg (1 044 → 1 043 Wochen, K13), die Optimierung nimmt dadurch einen anderen Weg; mit Daten bis zum Periodenende sind die Gewichte bitgleich und die Zeiten gleich (R 82 → 90 ms bzw. 71 → 71 ms).

Entfallen:

- Meldungstabelle: fünf Texte standen unter zwei Schlüsseln; die Aufrufer nutzen jetzt `a.m_sim_check_inputs`, `a.m_sim_check_inputs_2`, `a.m_sim_check_inputs_3`, `a.m_cpi_level` und `a.m_idx_rate`, die Schlüssel `b2b.m_param_search_2`, `b2b.m_e2_check_strategy`, `b2b.m_e2_check_strategy_2`, `c.m_resolve_series_2` und `c.m_resolve_series_3` entfallen (Texte unverändert; PR2-6).
- Dateien wurden nicht gelöscht oder verschoben; neu sind `r/R/sim_prepared.R`, `python/simlev/_sim_prepared.py`, `julia/src/sim_prepared.jl` (Studienkern), `tests/werkzeuge/meldungen_inventar.py` und `tests/werkzeuge/gleichlauf/rexpr_fuzz.R`.

Intern, Bau, Doku und Tests:

- Studienkern (Entscheidung 176, FB-12): Innerhalb einer Studie merkt sich `simulation()` ab dem zweiten Aufruf mit derselben Strategie und denselben Argumenten den vorbereiteten Lauf (Prüfung, Daten, Kalender, Bausteine, Eingabe der Tagesengine) und tauscht je Pfad bzw. Punkt nur die Kurs- und Signalspalten; Tagesengine und Auswertung rechnen dann in einem Kernaufruf (`sim_run_prepared`, gleicher Kern aus R, Python und Julia). Genutzt wird das, wo sich je Lauf nur Kurse oder Signale ändern: `bootstrap_study()` (Pfade), `param_search()` mit Signal-Bausteinen, `sensitivity_leverage()` (Hebelreihen). Läufe, deren Vorbereitung Meldungen oder Warnungen ergibt, Fonds-Wrapper, `details = TRUE` und auffällige Kurse oder Signale rechnen wie bisher vollständig. Bitgleich zum Stand davor (Gleichlauf aller Studienfamilien).
- R, Hilfe: der roxygen-Block von `quantile_regression()` stand vor den internen Hilfen `.qr_scale`/`.qr_unscale` (eine Neuerzeugung hätte `.qr_scale` exportiert und `quantile_regression` verloren; PRG2-1); 17 seit 1.6.5 neue Argumente standen nur in den Rd-Dateien (`tactical_target_volatility`: risk, estimator, alpha, lpm_order, lambda, exponent, min_exposure, risk_floor, reference, cushion, cushion_window und `ppy = "rolling"`; `sharpe_test`: studentize, kernel, prewhiten; `overfit_walk_forward`: correlation; `sharpe_deflated`: expected_max; `sharpe_haircut`: distribution; `tactical_rotation`: vol_window) und stehen jetzt in den roxygen-Quellen (PRG2-2). Die Rd-Dateien dieser Funktionen und von `views`, `copula_fit` entstehen unverändert aus roxygen2 7.3.1 (dabei nur Zeilenumbrüche, Reihenfolge der Argumente und in `sharpe_deflated` der Satz „Seit 1.6.4 genau ein Datum je Zeile …“ zu `dates` aus `overfit_pbo` neu).
- Prüfwerkzeuge: `tests/werkzeuge/meldungen_inventar.py` (alle Fehler- und Warnungstexte außerhalb von `core/meldungen.tsv` mit Funktionsnamen, FB-7); Gleichlauf: Zufallsprüfung der Regelausdrücke `rexpr_fuzz.R` mit Warnungen und `(-Inf)^y` um 2^64 (E-T4-6, E-T4-5), Laufzeit je Fall und je Modul in `vergleich.py`/`vergleich.jl` (FB-14), höchster Speicher je Prozess im Bericht, Julia-Vergleich mit `--heap-size-hint=1200M` und Speicherfreigabe je Datei.
- Messbasis `tests/werkzeuge/bench/`: neue Aufgaben `T3s` (`bootstrap_study()` mit zwei Anlagen, Steuer und vierteljährlichem Rebalancing, Blocklänge fest 20), `T4m` (`withdrawal_max_rate()`), `T9` (`bootstrap_pooled()`, zwei Länder, 2 000 Pfade × 15 Jahre monatlich) und `T10` (`signal_combine()` dreier Signale mit 10^6 Zeilen), Zeile „Daten2:“ mit den Prüfsummen ihrer Eingaben.
- Tests: Referenzkatalog der berührten Bereiche je Paket mit R neu erzeugt (u. a. bootstrap, daten, engine, entnahme, forschung, statistik, wrapper, modelle, planung, r_grundfunktionen, optimierung, slc), neue Fälle zu Depotgebühr, `combine = "and"`, `convexity`, großen |x| in `dnorm` (PRG1-3, PR1-1) und kurzen Zeiträumen; Test `test-entnahme.R` erwartet die gewollte Warnung „… ohne Schwankung …“ von `overfit_walk_forward()` (PR2-5). 1.6.5 hat keinen eigenen Finaltest und keine neue Referenzablage; die Zufallsprüfungen vergleichen weiter gegen die Ablage von R 1.6.4 (Entscheidung 198).

## SimLev 1.6.4

Patch (R/Python/Julia). Einheitliche Eingabeprüfung in allen öffentlichen Funktionen mit Meldungen aus einer gemeinsamen Tabelle, Berichtigungen falscher Ergebnisse und der Parallelität, R-Nachbildungen in Python und Julia näher an R 4.3.3, schneller in allen drei Sprachen, Standard `cores = "auto"`. Für gültige Eingaben bleiben Ergebnisse, Ausgaben, Meldungen und Warnungen bitgleich zu 1.6.3, außer bei den Punkten unter „Berichtigt“ und „Geändert“. Ergebnisse ändern sich dort vor allem bei Signalspalten aus 0/1, bei `index_bond()` mit Duration, bei Schiefe und Wölbung (letzte Bits), an Grenzwerten von pt, pbeta und der Zufallszahlen, in der Entnahme mit genau einer Periode bzw. einem unterjährigen Planjahr, beim Restgeld nach der Ansparphase, in Grafiken und bei `rep()` in Regeltexten (Python, Julia). Öffentliche Schnittstelle: neuer Standard `cores = "auto"` und neues Argument `sharpe_deflated(rho_method)` (`tests/schnittstelle/CHANGES.md`); im summary-Objekt der Entnahme das neue Element `depletion_median`.

Gleichheit der drei Sprachen (Stufenmodell, seit 1.6.4):

- Auf einem Rechner liefern R, Python und Julia **bitgleich**: Engine, Zufallszahlen und alles, was Verzweigungen, Auswahl oder Optimierung steuert, dazu Meldungen und Warnungen; streng NA ≠ NaN und +0 ≠ −0.
- **Mit Toleranz** relativ 1e-12 (NA und NaN getrennt, ±0 gleich) dürfen nur reine Auswertungen abweichen, deren Ergebnis in keine weitere Rechnung eingeht. Freigegeben sind nur `summary()` von `simulation()` und `sharpe_probabilistic()` (Entscheidung 152; Liste `tests/lib/toleranz.tsv`). Die Rechnung des Pakets ist dadurch nicht geändert; die Vergleiche der Tests kennen die Stufe.
- **Gedruckte Ausgaben** (print, summary, Tabellen) bleiben in jeder Stufe zeichengleich.
- Zwischen Plattformen dürfen die letzten Bits abweichen; belegt wird die Gleichheit durch die Tests auf der Entwicklungsmaschine (Linux x86-64, glibc).
- R rechnet cov, cor, var, sd, optimize, approx, filter, dist und hclust (intern) jetzt über die SimLev-Kerne statt über R's eigenen C- bzw. Fortran-Code (Entscheidungen 121, 130). R's Code ist ohne `-ffp-contract=off` übersetzt und darf auf ARM Multiplikation und Addition zusammenziehen, die Kerne nicht; damit rechnen R, Python und Julia diese Wege mit demselben Code. Auf x86-64 sind Ergebnisse, Warnungen und Fehlermeldungen bitgleich zu 1.6.3, außer bei Kendall (unten).

Gewollte Abweichungen von R („Richtig vor R“, Entscheidung 123: rechnet R nachweislich falsch oder liefert NaN, wo der Grenzwert feststeht, gilt mit Beleg der richtige Wert in allen drei Sprachen):

- pbeta des Kerns, wo R selbst NaN mit „NaNs produced“ gibt (Überlauf in toms708, z. B. `pbeta(0.2, 1e-100, 1e300)`): der Grenzwert 0 bzw. 1 (Entscheidung 115). `pbeta(1e-100, 1e100, 1e200)`: 0 (lower) bzw. 1 (upper), mathematisch richtig; R gibt 0,5 (Entscheidung 116). Bekannte Grenze: Liegt das gesuchte Ende in solchen Fällen unter etwa 1e-13, wird es als Komplement berechnet und ist nur absolut genau (Fehler bis 1,2e-13, z. B. `pbeta(1e-300, 1e-320, 1e-100, lower.tail = FALSE)` 1,1e-13 statt 1e-220); vorher NaN.
- Kendall-Korrelation einer Matrix mit einer NA-Spalte (`cor(x, method = "kendall")`, `use = "everything"`; in SimLev über dependence_analysis() und scenario_copula(), wenn die Daten NA enthalten): R las dort ein nicht gesetztes Hilfsfeld; je nach Speicherinhalt kam NA mit oder ohne Ruhe-Bit und manchmal die Warnung „the standard deviation is zero“. Jetzt in allen drei Sprachen reproduzierbar ein stilles NA ohne Warnung (Entscheidung 130).
- Bekannt und unverändert (R-Nachbildungen in Python und Julia): `max`/`min` aus Datum und Text ergeben Text, R ein Datum mit Text als Speicher (Entscheidung 106); Datumswerte sind immer double, R speichert `as.Date(5L)` als integer (107); Zeitdifferenzen nur in Tagen (105). Python-Regeltexte halten Vektoren als Listen (rund 40 Byte je Wert für `:` und berechnete Zahlen); `1:1e8` an der Längengrenze braucht hochgerechnet etwa 3,7 GiB und endet unter einer Speichergrenze von 2 GiB mit MemoryError, Julia braucht 9 Byte je Wert; der Umbau auf kompakte Felder folgt in 1.6.5 (Entscheidung 111).

Berichtigt (Ergebnisse):

- simulation() mit Signalspalten aus 0/1 (integer oder double, z. B. aus `read.csv`; Entscheidung 137): An Umschichtungstagen (Ein- und Ausstieg der Signal-Assets) und bei der Kaufregel „kaufen nur ohne gleichzeitiges Verkaufssignal“ zählte nur ein logisches TRUE, eine 1 wurde übergangen; mit denselben Signalen als 0/1 kam ein anderes Ergebnis heraus als mit TRUE/FALSE (Beispiel 952,02 statt 982,91 EUR). Jetzt wirkt 1 überall wie TRUE (im gemeinsamen Kern); logische Signale bitgleich.
- index_bond(), Attribut `duration` und Verfahren `method = "duration"` (Entscheidung 136): Duration (beim Verfahren „duration“ auch die Konvexität) geschlossen, D = −expm1(−n·log1p(i))/(i·m) (bei i = 0 die Laufzeit), Konvexität mit Reihe nahe i = 0, statt über zentrale Differenzen (h = 1e-4, relativer Fehler der Duration bis 2e-6 bei 30 Jahren); jetzt höchstens 7,4e-15 relativ (Probe gegen Rmpfr). Indexwerte von `method = "duration"` ändern sich in den hinteren Stellen; das Standardverfahren bleibt bitgleich.
- simulation(): Kurse außerhalb von 1e-100 bis 1e100 werden mit Meldung abgelehnt (bisher wurde ein Asset still wertlos oder das Depot endete bei −Inf); wird während der Rechnung eine Stückzahl oder ein Depotwert unendlich, bricht simulation() mit eigener Meldung ab (Entscheidung 103). Kaufbeträge unter etwa 1e-208 EUR je Kurs, bei denen die Stückzahl still zu 0 unterlief, brechen ab mit „simulation: ein Kaufbetrag ist im Verhältnis zum Kurs zu klein für den Zahlbereich (die Stückzahl wäre 0); Kurse und Beträge in einer passenden Einheit angeben.“; Ganzstückkäufe mit Betrag unter dem Kurs bleiben ohne Kauf und ohne Meldung.
- withdrawal_paths() mit genau einer Periode (z. B. Pfade von gut einem Jahr): Pfade und Perioden waren vertauscht (aus n Pfaden wurde ein Pfad über n Perioden); jetzt Perioden × Pfade, in R mit den Spaltennamen. Gilt für Pfade aus bootstrap() (auch `cape`) und Listen von Ergebnissen aus simulation().
- withdrawal_perfect_rate() und die Spalte `pwr` von withdrawal_simulation() bei genau einem unterjährigen Planjahr (Quartals- oder Monatsdaten): bisher ein falscher Wert für alle Pfade (z. B. 32,5 statt 100), jetzt die PWR je Pfad.
- Zusammenfassung der Entnahme (summary(), print()): „Median im Jahr …“ ist jetzt immer der gewichtete Median (0,5-Quantil) der Erschöpfungsjahre, bisher das mittlere Element von `probs` (bei eigenen `probs` falsch, in R mit `probs = c(0.1, 0.9)` ein Fehler). Neues Element `depletion_median` am Ende des summary-Objekts (Entscheidung 102).
- withdrawal_simulation(start_value = <Ergebnis>): Ein negativer Geldbestand am Ende der Ansparphase (Rundungsrest oder ungedeckte Steuer) wird nicht mehr als Anteil mit negativem Wert geführt (konnte die Steuer beim Verkauf mindern), sondern vom ältesten Lot des wertgrößten Assets abgezogen, Anschaffungskosten und Vorabpauschale anteilig; reicht er nicht, die nächsten Lots desselben Assets (Entscheidungen 104, 109).
- Entnahmeregeln `vpw`, `abw` und `hebeler` mit erwarteter Rendite nahe 0: Annuität ohne Auslöschung, für |r| < 0,01 % bisher bis in die 5. Stelle ungenau, für 0 < |r| < 1e-10 Prozent bisher als 1/n mit bis zu 5e-10 relativem Fehler, jetzt höchstens 2,2e-16. Für 0, −0 und übliche Renditen bitgleich.
- result_analysis() mit Daten vor dem Jahr 1000 oder ab 10000: Die Monatstabelle liest das Jahr ganz. Bisher brach Jahr 950 in R und Python ab und Jahr 10000 erschien als 1000; Julia rechnete Jahre ≥ 0 schon richtig, jetzt auch Jahre < 0 (Entscheidung 120).
- result_analysis() mit einem Benchmark ohne Schwankung (`risk_free = 0`): bisher brachen R und Python ab, Julia lieferte `treynor` NaN; jetzt rechnet die Funktion, `beta` und `alpha` NaN, `treynor` NA (Entscheidung 146). Python mit konstanter Strategiereihe und `risk_free = 0`: bisher ZeroDivisionError, jetzt wie R und Julia (`m2` NaN); Sortino, Up- und Down-Capture gegen einen Nenner 0 geschützt. R: die Warnung „the standard deviation is zero“ kommt bei konstanten Reihen einmal statt doppelt, wie in Python und Julia (Entscheidung 156).
- sensitivity_leverage(): Das Attribut `optimal` hat immer `cagr` und `sharpe` (NA ohne Wert); bisher fehlte `cagr`, wenn eigene `metrics` kein `cagr` lieferten oder alle `cagr` NA waren, und der Druck zeigte den Sharpe-Hebel als CAGR.
- sharpe_haircut(): `n_tests` kleiner als die Zahl der Sharpe Ratios wurde still durch diese Zahl ersetzt (das Attribut nannte den angegebenen Wert); jetzt Meldung „sharpe_haircut: n_tests muss mindestens so groß sein wie die Zahl der Sharpe Ratios bzw. der ausgewerteten Spalten von x.“
- tactical_rotation(weighting = "inverse_vol"): Jeder Termin vor Zeile 63 brach mit „Zeilen ohne positive Gewichte“ ab, mit Wochen- und Monatskursen auch mit den Standardrückblicken; jetzt beginnen die Termine ab Zeile 63, wenn das Fenster der Schwankung voll ist. Rechnende Fälle unverändert (Entscheidung 144; das wählbare Fenster folgt in 1.6.5).
- withdrawal_max_rate(tol) unter dem Abstand benachbarter Zahlen (z. B. `tol = 1e-16`) und backcast_fit(bounds) mit unendlicher Breite ließen die Suche endlos laufen; jetzt endet die Bisektion, sobald die Mitte keine neue Zahl mehr ist, bzw. kommt die bestehende Meldung zu `bounds`. Für bisher endende Suchen unverändert.
- Ausgleichsrechnung des Kerns (`backcast_fit(model = "linear")`, Abhängigkeit, Forschung, Bootstrap) mit Werten ab etwa 1e154: bisher still falsche Koeffizienten, jetzt richtig; übliche Werte unverändert.
- Verteilungen und Zufallszahlen des Kerns an Grenzwerten wie R (Entscheidungen 95, 96, 110): `rnorm` mit unendlichem Mittelwert (±Inf statt NaN) und `sd = 0` (Mittelwert mit Vorzeichen der Null), `rgamma` mit shape oder scale 0 bzw. Inf, `rchisq` mit df = 0 (der Zufallsstrom bleibt); `pnorm`, `qnorm`, `dnorm` prüfen die Randfälle in R's Reihenfolge (64 Randfälle bisher anders); `pt`/`qt` für df > 1e20 über die Normalverteilung (bisher ab etwa 1e80 still falsch, bei 1e300 NaN), `qt(0)`/`qt(1)` ±Inf auch bei ungültigem df; `pt(1e300, df = 1e-300)` 0,5 und allgemein `pt` mit df unter etwa 4e-16 der Wert statt NaN mit Warnung „pt: Kettenbruch nicht konvergiert“; `pbeta` mit Parametern 0 oder Inf die Grenzwerte, `pbeta(0.5, 1e-300, 1e300)` 1 statt NaN mit Warnung. `qt` und alle bisher endlichen Werte von `pt`/`pbeta` bitgleich.
- t-Verteilung auf mehreren Threads (Kern; R `.sl_pt`/`.sl_qt`, t-Copula in allen drei Sprachen): Auf Rechnern mit mehr als 64 logischen Prozessoren kam ab 33 280 Werten eine falsche Warnung „Kettenbruch nicht konvergiert“, ab 69 Threads las der Kern hinter seinem Arbeitsfeld, und die t-Copula fiel immer auf den langsamen Weg zurück; jetzt Merker je Aufruf ohne feste Thread-Grenze, Werte unverändert.
- Grafik: Dashboard-Verteilungsbild mit der Normalverteilungskurve auf der Klassenbreite der Balken (bisher bis zum Faktor 1,8 daneben; Entscheidung 91). Python und Julia wie R (Entscheidung 99): Histogramm zählt Werte auf Klassengrenzen wie `hist()` (Toleranz 1e-7 der Klassenbreite); Monats-Heatmap mit rechts geschlossenen Klassen und R's Farben (bisher jede ganze Prozentzahl eine Stufe höher, 0 % grün statt rot); Farbverläufe wie `colorRampPalette()` (abgeschnitten, Großbuchstaben); `plot(<SimLevParamSearch>)` in 64 Stufen über den Wertebereich; Bootstrap-Studie mit „&“ oder „<“ im Strategienamen ergibt gültiges SVG. Python: Dashboard-Kennzahlen „NA%“ statt „NaN%“, Achsenteilungen mit Logarithmen wie Julia; Julia: Linienverdichtung behandelt −0 und +0 gleich.
- plot(<SimLevWithdrawal>, probs = <ein Wert>) brach in R ab („incorrect number of dimensions“), jetzt eine Linie wie in Python und Julia; leere `probs` ergeben „plot: probs muss mindestens einen Wert enthalten.“
- format(<Tabelle>) (Python, Julia): Textspalten (auch Faktoren) werden ohne `justify` nicht mehr aufgefüllt, wie R's `format.data.frame` (alt `"x " "yy"`, neu `"x" "yy"`).
- Python: summary(<SimLevBootstrapStudy>, metrics = "cagr") mit einem einzelnen Namen lieferte eine leere Tabelle; sharpe_haircut() mit genau einer Sharpe Ratio brach mit IndexError ab; scenario_entropy_pooling() mit Nullen im Prior brach mit „math domain error“ ab; portfolio_rolling() mit einem Kurs < 0 oder −Inf gab zwei zusätzliche Warnungen „NaNs produced“; Zahlen in Tarifdateien wurden in seltenen Fällen im letzten Bit anders gelesen (jetzt R_strtod). Jetzt jeweils wie R und Julia.
- Julia: signal_ema() und signal_crossover(type = "ema") mit n = Länge − 1 (bisher MethodError); tactical_simulation() erkennt die gefüllten Tage aus series_align() (bisher nie; mit `lag ≥ 1` lagen Wechsel auch auf LOCF-Tagen); dependence_analysis(conditions) mit −0 und 0 als einem Wert (bisher andere Regimegrenzen); regime_states() mit einem getypten Datumsvektor nur aus fehlenden Werten (NA je Zeile); scenario_entropy_pooling() und scenario_copula() mit einer Matrix ohne die verlangte Anlage („Spalte(n) '…' fehlen in data.“ statt KeyError). Jetzt jeweils wie R und Python.
- R: `simulation(details = TRUE)` mit Sparplan druckt Assetnamen mit „%“ richtig (bisher „too few arguments“, „invalid format“ oder „A%“ statt „A%%“); series_check() zählt zwei gleiche unendliche Werte hintereinander wie Python und Julia (bisher `stale_max` NA).

Berichtigt (Parallelität, `cores ≥ 2` und `"auto"`):

- Eine feste Zahl `cores ≥ 2` in bootstrap(), bootstrap_study(), param_search(), param_bootstrap(), sensitivity_grid(), sensitivity_rebalancing(), sensitivity_leverage() und planning_lumpsum_vs_dca() verteilt über denselben Weg wie `"auto"`, nur ohne Vorabmessung (Entscheidung 133). Fehler, Warnungen und Ausgaben der Einheiten erscheinen wie mit `cores = 1` in Einheitenreihenfolge; Ergebnisse gültiger Eingaben bitgleich.
  - R bisher über `mclapply`: Ein Fehler kam als `try-error` mit der Warnung „k function calls resulted in an error“ zurück und führte zu Folgefehlern („subscript out of bounds“ u. a.) oder still fehlenden Zeilen (sensitivity_rebalancing(), sensitivity_leverage(), bootstrap_study() mit „k Chunks mit Fehler“); ein abgestürztes Kind lieferte `NULL` mit still fehlenden Zeilen; Ausgaben erschienen ungeordnet, Warnungen gingen verloren. Jetzt wird der erste Fehler in Einheitenreihenfolge ausgelöst wie mit `cores = 1`. R unter Windows (PSOCK-Cluster) unverändert.
  - Python und Julia: Warnungen der Einheiten gingen verloren (Python ohne `fork` auch bei nacheinander gerechneten Einheiten, Julia auch mit einem Thread); jetzt wie mit `cores = 1`.
  - Endet ein Hilfsprozess ohne Ergebnis, melden R und Python gleich „par_lapply: Ein Hilfsprozess endete ohne Ergebnis.“, Python in Einheitenreihenfolge (ein früherer Fehler kommt zuerst). In R entfällt die Warnung „k parallel job(s) did not deliver a result“ beim Aufräumen nach einem Fehler.
  - Der Hinweis zu `SIMLEV_THREADS` erscheint an derselben Stelle wie mit `cores = 1` (bisher vor den Einheiten).
- R, Python unter Linux: Kindprozesse enden mit dem Elternprozess, auch nach einem harten Ende (SIGKILL, Speicherwächter, Neustart eines Jupyter-Kerns; Kernhilfe `sl_child_guard`, `PR_SET_PDEATHSIG`); bisher lebten sie dauerhaft weiter (je rund 60 MB). In Python schließt jedes Kind die geerbten Verbindungsenden seiner Geschwister. Unter macOS und Windows wie bisher.
- Julia, mehrere Threads:
  - bootstrap_study() und param_bootstrap() mit fester Zahl `cores ≥ 2`: Alle Aufgaben teilten eine Variable für das Simulationsergebnis; Kennzahlen und Renditen (`keep_returns`) einzelner Pfade konnten zu einem anderen Pfad oder einer anderen Strategie gehören (die gezogenen Pfade waren richtig). Jetzt bitgleich zu `cores = 1`.
  - `r_sprintf` und alles, was darüber formatiert, auf Thread ≥ 2: Die Formatierpuffer stammten aus dem Vorkompilieren und hatten nur einen Platz; es kam ein BoundsError, planning_lumpsum_vs_dca(…, cores = 2) brach ab, bootstrap_study() verlor still Ergebniszeilen, eigener Code mit `Threads.@spawn simulation(…)` war ebenso betroffen. Jetzt werden die Puffer beim Laden neu aufgesetzt und unter einer Sperre ergänzt.
  - planning_lumpsum_vs_dca(): der gemeinsame Zwischenspeicher der Kurse wird nur unter einer Sperre beschrieben (bisher Wettlauf, in Proben nicht beobachtet).
  - Ausgaben der Einheiten gingen verloren oder landeten bei der falschen Einheit, die Thread-Grenze je Aufgabe konnte überschrieben werden (Ergebnisse nicht betroffen).
  - Strg-C während paralleler Einheiten (REPL): Nach dem Abbruch beginnen keine neuen Einheiten mehr (Probe 0,92 s, 5 von 16 Einheiten; bisher 2,40 s, alle 16).

Berichtigt (R-Nachbildungen in Python und Julia, wie R 4.3.3; R selbst unverändert):

- Regeltexte (RExpr: tactical_rules(), regime_subset(), view_prob(), scenario_entropy_pooling(), bootstrap_probability()):
  - `c()` mit Namen wie R (Namen setzen sich zusammen, `[`/`[[` über Namen, Operatoren und Funktionen führen sie wie R); bisher wurden Namen verworfen und `x["b"]` war still NA.
  - `as.Date` mit `origin`, `format`, `tryFormats`, `optional` (Übertragung von R's `strptime`; `%z`/`%s` in der Systemzeitzone; bisher fielen die Angaben still weg); `as.Date(<Text>)`: das erste nicht fehlende Element bestimmt die Vorlage, „2020-01“ ist ein Fehler (bisher in Julia der 1. Januar).
  - Datumswerte als double mit Bruchteilen, NaN und ±Inf (bisher ganze Tage, Bruchteile still abgerundet); Datum − Datum eine Zeitdifferenz in Tagen; `is.finite(<Datum>)` TRUE für endliche Daten (bisher immer FALSE, eine solche Regel wählte still keine Zeile); Math-Gruppe, `round`/`trunc`, `%in%`, `min`/`max`/`sum`, `var`/`sd`, `pmin`/`pmax`, `quantile` mit Datum wie R; `Datum + "2"` ein Fehler. Jahre außerhalb 1000–9999 ohne Auffüllen („53-06-19“, bisher in Julia abgeschnitten). Nach außen bleiben Datumswerte Kalendertage.
  - `rep()` ganz wie R (Entscheidung 157; ändert auch gültige Fälle): `rep(NULL, …)` ist NULL (mit length.out > 0 die Warnung „'x' is NULL so the result will be NULL“), leeres `x` gibt `x` ohne Prüfung von `times`, aufgefüllte Namen `""`, `each = 0` mit `length.out` ein Fehler, „first element used of 'length.out' argument“, Warnungen bei benanntem `x` einmal; `rep(times = Inf)` „invalid 'times' argument“.
  - `ifelse` wertet `yes` nur bei einem TRUE und `no` nur bei einem FALSE aus (bisher immer beide; `ifelse(x >= 0, sqrt(x), -sqrt(-x))` warnte bei nur positiven x); `numeric()` & Co. mit der Länge wie R's `asVecSize`; `var(x, NULL)` wie `var(x)`; Mathefunktionen mit NULL, Text als `digits` bzw. `base` ein Fehler wie R; `^` mit zwei NaN wie R (`NA^NaN` NaN); `log(x, base)` mit NA-Basis ohne „NaNs produced“; `(-Inf)^y` mit y > 2^64 mit R's Warnung „probable complete loss of accuracy in modulus“; `a = b <- 3`, doppelte Formale, `NULL$x`, `NULL[...]`, `!character(0)`, `cumsum(NULL)` wie R; Namen mit Ziffern und Zahlzeichen anderer Schriften nach der Zeichentabelle von glibc 2.39.
  - Meldungen geben Text und Ausdrücke wie R's deparse wieder (Steuerzeichen als `\001`); `||` prüft den Typ; ein einzelnes Surrogat ergibt „unpaired surrogate Unicode point …“.
  - Spalten mit Listen oder komplexen Zahlen: „RExpr: Spalte '<name>' hat einen Typ, den Regeltexte nicht unterstützen (nur Zahlen, Wahrheitswerte, Text und Datum)“; bisher rechneten Python und Julia still mit einer gleichnamigen Größe der Umgebung. Bei doppelten Spaltennamen gilt die erste Spalte. Python: komplexe Spalten nicht mehr still in ihren Realteil umgewandelt.
- Zahlen und Text: `sum`, `prod`, `mean`, `cumsum`, `cumprod`, `cummax`, `var`, `exp`, `log`, `^` mit Text mit R's Meldungen (bisher rechnete Julia mit Zeichencodes, `"ab"^2` ergab 9409 9604, Python wandelte Ziffern-Text still um); RLibm (exp, log, log1p, expm1, log2, log10, sin, cos, tan, tanh, atan) mit R's Warnung „NaNs produced“ einmal je Aufruf, `pow` und `pmin`/`pmax` mit R's Recycling-Warnungen, `pmin`/`pmax` in der Form des ersten Arguments; Bitmuster von NaN und NA wie R (Python `log(-1)` R_NaN, Julia `sqrt(-4)` das NaN der Hardware, NA bleibt in `exp`, `floor`, `sqrt` Bit für Bit; Kern `exp`/`expm1(NA)` NA; Entscheidung 101); Vorzeichen der Null (Python `floor`/`ceiling`/`trunc` behalten −0, Julia `sign(-0)` +0); `median` und `quantile` mit Text, Faktor und Datum wie R bzw. mit eigener Meldung; `rank(ties_method)`, `cor`/`cov(method)` mit Teilnamen wie `match.arg`; `paste(sep, collapse)` nur Text; `var`/`cov`/`cor` mit NULL wie R; `diag(n)` (Python `diag(3)` die 3×3-Einheitsmatrix); Python `pow`, `rank`, `order`, `sort` lesen Matrizen spaltenweise; Python `log(x, 1)` ±Inf bzw. NaN statt ZeroDivisionError.
- Formatieren und Druck: `format()` mit Breite über 999 Zeichen höchstens 999 wie R (bisher fehlte die Zahl ganz oder teilweise); `sprintf("%1$e %1$d")` wie R (bisher Fehler); `format(<Tabelle>, …)` wendet `width`, `nsmall`, `big_mark` usw. je Spalte an (bisher still verworfen); `round`/`signif` mit `digits < 0` auf ganzen Zahlen und mit R's Meldungen; `nchar(NA)` NA für „chars“ und „bytes“ (bisher 2), `nchar(type)` mit Teilnamen; `formatC`, `format`, `print`-Hilfen und `set_options(digits)` prüfen `width`, `digits`, `nsmall`, `justify`, `trim` wie R; druckbare Zeichen nach einer festen Tabelle aus glibc 2.39 (C.UTF-8; bisher nach der Unicode-Fassung der Sprache, Julia zeigte rund 10 000 neuere Zeichen roh); Matrixdruck mit Umlauten im Zeilentitel nach Bytes aufgefüllt; Datumstext ±Inf als „Inf“/„-Inf“; `r_format`/`r_deparse`: Datum als `structure(19753, class = "Date")`, gemischte Vektoren wie `c()`; Julia: leere `RList` druckt `list()`.
- Weitere: `sort_partial`, `order(decreasing)`, `hclust` mit NA/NaN/Inf, `p_adjust` mit `n = Inf`, `approx`/`approxfun` (Prüfreihenfolge, Texte, keine überzählige Warnung „collapsing to unique 'x' values“), `cut` mit NA in `breaks` und in `labels`, `quantile(type)`, `filter`, `seq`/`approx` mit `length.out`, `all.equal` (Abweichung wie R, `tolerance` geprüft), Julia `tabulate(nbins)`, `rle` und `as.numeric(<Text>)` (nur ASCII), Python Nullable-Spalten und `diff`, `hclust("ward")`-Hinweis auf stderr, Pickeln von `dist`- und `scale`-Objekten, ein mehrdeutiger Teilanfang in der internen Hilfe `match.arg` („'arg' should be one of …“): jeweils wie R. Bisher je nach Fall Hängen, Absturz, fremder Speicher, ein Ergebnis oder ein technischer Fehler.

Geändert (Standardwert, neue Option):

- `cores = "auto"` ist der Standard von bootstrap(), bootstrap_study(), param_search(), sensitivity_grid(), sensitivity_rebalancing(), sensitivity_leverage() und planning_lumpsum_vs_dca() (bis 1.6.3 `1`); param_bootstrap() übernimmt ihn über `...`.
  - SimLev rechnet die ersten Einheiten nacheinander, misst ihre Rechenzeit und wählt mit einem gemeinsamen Planer im Kern (`core/slc_prep.cpp`) die Zahl der Läufe und der Kern-Threads je Lauf. Er berücksichtigt die freien Prozessoren, den freien Speicher, die Rechenzeit je Einheit, die Ergebnisgröße und die Startkosten je Sprache; kleine Rechnungen bleiben bei einem Lauf. Unter Linux zählen Prozesse mit niedrigerer Priorität (größerem `nice`) nicht als belegter Prozessor, gleich oder höher priorisierte voll (Entscheidung 139).
  - Höchstens so viele Läufe wie freie Prozessoren (Julia höchstens `Threads.nthreads()`) und wie der freie Speicher trägt; Kern-Threads je Lauf: freie Prozessoren / Läufe, mindestens 1, höchstens `SIMLEV_THREADS`. Nacheinander unter Windows (R), ohne `fork` (Python unter Windows und macOS), in Julia ohne `-t` und auf einem Prozessor.
  - Ergebnisse bitgleich zu `cores = 1`; Ausgaben, Meldungen, Warnungen und Fehler der Einheiten in Einheitenreihenfolge. Kopfzeile von bootstrap_study(): „… auto Kern(e)“. Julia verteilt auch die Studien (bootstrap_study(), param_search(), sensitivity_*(), planning_lumpsum_vs_dca()) auf Aufgaben (Entscheidung 134); Ausgaben, die eigene Funktionen des Anwenders (etwa `metrics`) direkt mit `println`/`print` schreiben, erscheinen dort bei mehreren Aufgaben in der Reihenfolge, in der die Einheiten fertig werden.
  - Eine feste Zahl rechnet wie bisher; mehr als die Zahl der Prozessoren wird mit „Hinweis: <funktion>: cores auf <P> begrenzt (Zahl der Prozessoren).“ begrenzt. Doku: Eine feste Zahl lohnt sich bei rechenintensiven Teilrechnungen, sonst `"auto"` (Entscheidung 140).
  - Ungültiges `cores`: „<funktion>: cores muss "auto" oder eine ganze Zahl ≥ 1 sein.“
- bootstrap_study(progress = TRUE) meldet „Chunk k/n fertig“ bei jedem `cores`, in Einheitenreihenfolge (bisher nur bei `cores = 1` und `"auto"`; Entscheidung 135).
- Kern-Threads (`SIMLEV_THREADS`, qt/pt, t-Copula): höchstens die Zahl der Prozessoren (bisher ohne Einstellung höchstens 8, mit Einstellung bis 64), mehr mit „Hinweis: SIMLEV_THREADS auf <P> begrenzt (Zahl der Prozessoren).“ einmal je Sitzung; in parallelen Läufen je Einheit höchstens Prozessoren / Einheiten. `SIMLEV_THREADS` gilt nur aus ASCII-Ziffern („2.7“, „0x10“, „+3“ als nicht gesetzt; bisher las R „2.7“ als 2).
- Neu: `sharpe_deflated(rho_method = c("cor", "linear"))` (Entscheidung 92): `"linear"` rechnet die mittlere paarweise Korrelation in O(T N) statt über die volle Korrelationsmatrix; das Ergebnis weicht in den letzten Stellen ab und ist in den drei Sprachen gleich. Bei N = 1 200, T = 1 500: R 1,40 → 0,165 s, Python 1,24 → 0,085 s, Julia 1,43 → 0,096 s. Standard `"cor"` wie bisher.
- Regeltexte (tactical_rules(), view_prob() in scenario_entropy_pooling(), regime_subset()) gelten in R, Python und Julia im gemeinsamen Umfang: Spalten, Variablen und eigene Funktionen des Aufrufers, Operatoren, `if` und die Funktionen der Regeltexte (Entscheidung 143). R lehnt andere Funktionen (z. B. `cumprod`, `stats::sd`, `Sys.time()`, `rank`) jetzt mit denselben Meldungen ab wie Python und Julia; Julia sucht nicht mehr in `Base` oder in geladenen Paketen (bisher z. B. `minimum`, `clamp`, rohe MethodErrors bei `isodd`). Eine Funktion von `data` bzw. der Szenario-Tabelle ist jetzt auch in R erlaubt (`when`, `condition`, `expr`). Komplexe Zahlen sind ein Fehler („RExpr: komplexe Zahlen werden nicht unterstützt“). Mehr als 200 verschachtelte Ebenen ergeben überall „RExpr: Ausdruck ist zu tief verschachtelt (höchstens 200 Ebenen)“ (bisher Stapelüberlauf je Sprache verschieden, Julia konnte abbrechen; Entscheidung 75); Vektoren mit mehr als 1e8 Werten „RExpr: Ergebnis wäre zu lang (höchstens 100000000 Elemente)“ (bisher belegten Python und Julia den Speicher; Entscheidung 79); in Python und Julia mehr als 50 offene Klammern „contextstack overflow“ wie R.
- regime_subset(condition): Vektor bzw. Ergebnis des Ausdrucks wird in allen Sprachen wie R mit `as.logical` gelesen (Zahlen ≠ 0 wahr, „TRUE“/„FALSE“, „T“/„F“, „true“/„false“, NA = FALSE); anderer Text, Faktor, Datum, Liste und Matrix sind ein Fehler (bisher in Python jeder nicht leere Text wahr); ein leerer Ausdruck ist ein Fehler.

Neue Ablehnungen und Meldungen (Eingabeprüfung):

- Grundsätze, in allen drei Sprachen gleich (Entscheidungen 1–74, 155): Eingaben werden vor der Rechnung geprüft (vorhanden, Typ, Wertebereich); Meldungen im Stil „<funktion>: <argument> muss …“ aus der Tabelle `eingabe` in `core/meldungen.tsv` (erzeugt mit `core/gen_meldungen.py`), zeichengleich in R, Python und Julia, über einheitliche Prüfhilfen `chk_*` (R `R/pruefen.R`, Python `simlev/_pruefen.py`, Julia `src/pruefen.jl`; intern). Für gültige Eingaben ändert sich nichts. Wo R eine unsinnige Eingabe still annahm, geht die Prüfung vor, auch in R. Bisher liefen solche Eingaben je Sprache verschieden still durch, rechneten falsch oder brachen mit Rohfehlern (R-Meldungen wie „the condition has length > 1“, Python TypeError/KeyError, Julia MethodError/BoundsError) ab.
  - Meldungen nennen den Eingabewert nicht mehr (Entscheidung 8; bisher „, nicht …“, „= …“, „(ist: …)“, „(erhalten: …)“, „(Klasse …)“, z. B. „asset_config: share muss eine einzelne Zahl sein, nicht "0.5".“ → „asset_config: share muss eine einzelne Zahl sein.“). Namen von Assets und Spalten, Zeilennummern, Daten als Ort in `data` und Grenzen bleiben. Prozentangaben zwischen 1 und 100 für Anteile (`share`, `success`): „…; Prozentangaben durch 100 teilen.“ (Entscheidung 12).
  - Alle Meldungen von Eingabeprüfungen beginnen mit dem Funktionsnamen (bisher u. a. „start_value muss ein Geldbetrag > 0 sein.“, „LETF 1: expense muss >= 0 sein“, „order_fee/dca_fee: …“; jetzt z. B. „planning_goal: start_value muss …“, „bootstrap_config: letfs[[1]]$expense muss >= 0 sein.“, „sim_costs: order_fee$fixed muss eine einzelne endliche Zahl sein.“). Auswahlargumente melden „<funktion>: <argument> muss einer von "…", "…" sein.“ statt R's „'arg' should be one of …“; gültige Werte und eindeutige Präfixe bleiben. `seed`: „<funktion>: seed muss eine ganze Zahl mit |seed| < 2^53 sein.“; wie in R gilt auch `42.0` als ganze Zahl.
  - Python und Julia: Vektoren der Länge 1 gelten wie in R als Einzelwerte (Entscheidung 4). Python: sehr große Ganzzahlen (≥ 2^1024) ergeben die Meldung wie R `1e400` statt OverflowError; ganze Zahlen erscheinen in Meldungen ohne Exponent („100000“ statt „1e+05“).
  - `data` nur als Tabelle (Entscheidung 6): R data.frame, Python nur `pandas.DataFrame`, Julia nur `RFrame` (bisher auch `dict`, `NamedTuple`, `Dict`, Paar-Vektoren), z. B. „simulation: data muss eine Tabelle mit Spalte 'date' und je Asset einer Kursspalte sein (R: data.frame, Python: pandas.DataFrame, Julia: RFrame; andere Formen vorher umwandeln, z. B. as.data.frame(x), pandas.DataFrame(x) bzw. RFrame(pairs(x)...)).“ Funktionen, die simulation() intern mit selbst umgewandelten Daten aufrufen, sind nicht betroffen.
  - Faktoren (R) bzw. Kategorien (Python, Julia `RFactor`) werden weder als Argument noch als Spalte angenommen, auch nicht als Datumsspalte (bisher still in Text bzw. Datum umgewandelt oder mit den Codes gerechnet): „<funktion>: <argument> darf kein Faktor (Kategorie) sein.“ bzw. „… Spalte '<name>' darf kein Faktor (Kategorie) sein.“ (Entscheidung 15). Eine Spalte nur aus NA gilt als Zahlenspalte (Entscheidung 14).
  - Wahrheitswerte nur TRUE/FALSE (`deliverable`, `fractions`, `liquidate`, `details`, `skip`, `ess`, `progress`, `verbose`, `wrap`, `anchored`, `effective`, `intercept`, …); NULL ist ein Fehler (bisher bei `liquidate`/`details` FALSE; bisher galten je Sprache `isTRUE`, `bool()` oder `== true`, Python las Text „FALSE“ als wahr). Signale nur TRUE/FALSE oder 0/1, NA erlaubt (Entscheidung 1; bisher jede Zahl ≠ 0, in Python und Julia Text als wahr).
  - Ganze Zahlen ohne Abschneiden (`n`, `B`, `max_tries`, `window`, `lag`, `span`, `lookbacks`, `top`, `k`, `horizon`, `years` u. a.; bisher 2,5 still zu 2 oder aufgerundet; Entscheidungen 19, 23, 32). Gemeinsame Obergrenzen (Entscheidungen 16, 36, 46): Laufzeiten höchstens 100 Jahre (36 600 Tage, 1 200 Monate), Anzahlen höchstens 10^8, Raster höchstens 10^6, Meldung „<funktion>: <argument> darf höchstens <grenze> sein.“ `years` nur ganze Jahre, auch bei Quartals- und Monatsdaten (Entscheidung 47; gebrochene Jahre als künftige Funktion vorgemerkt).
  - Unbekannte und doppelte Argumente in `...` und doppelte Namen in `sim_args`: „<funktion>: unbekanntes Argument '<name>'.“ bzw. „… doppeltes Argument '<name>'.“ (Entscheidung 21; bisher R „unused argument“ bzw. still das erste, Julia still das letzte). Felder von Listen-Assets: „unbekanntes Feld '<feld>' in Asset '<asset>'“, mehrfach, unbenannt (bisher Tippfehler wie `sprad` still ohne Spread).
  - Datumsangaben nur als Datum, Datum-Uhrzeit oder Text „JJJJ-MM-TT“ der Länge 1 (keine Zahl als Tage seit 1970); Datumsspalten aufsteigend ohne NA, wo die Rechnung das braucht; Datum-Wert-Tabellen (cpi, risk_free, ter, rate, fx, yield) mit fehlendem Datum: „<arg>: Datum fehlt in Zeile n.“ (bisher brach R ab, Python und Julia übergingen die Zeile; Entscheidung 147).
- Engine und Konfiguration: asset_config() (`spread` endlich, `deliverable`, `start`, `tax_regime`, `signal_buy`/`signal_sell` als einzelner Name); Listen-Assets wie asset_config() geprüft (bisher liefen negative Spreads mit Geld aus dem Nichts, Teilfreistellung über 100 % und negative Anteile still durch); create_strategy(), strategy_validate(), strategy_add_asset() (ein vorhandener Name überschreibt nicht mehr still: „Ein Asset mit diesem Namen ist schon in der Strategie; zum Ändern strategy_update_asset() verwenden.“), strategy_update_asset() (unbekannte Angaben bisher nur eine Warnung), strategy_remove_asset(), strategy_from_weights(); simulation(): `start_value` endlich, `risk_free` als einzelne Zahl oder Name einer Zahlenspalte, Spalte `.filled` in `data` (schaltete den Handel still ab), Basiszinsspalte ohne NA und numerisch (NA bisher still 0; Entscheidungen 17, 42), Signalspalten, Julia doppelter Asset-Name; Bausteine dca_plan(), rebalance_plan() (`span` eine ganze Zahl von 1 bis 2147483647, `event_weight` benannt, `days`), sim_costs() und `order_fee` (einzelne Zahlen, `max` auch Inf, keine doppelten Felder), harvest_rule(day) (nur ASCII-Ziffern, Monat 01–12, Tag 01–31; „harvest_rule: day im Format 'MM-TT' (Monat 01 bis 12, Tag 01 bis 31) und vor dem 31.12. angeben (z. B. '12-15').“), income_tariff(), income() (`start` ein ganzes Planjahr ≥ 1; Entscheidung 44), tax_tariff() (UTF-8-BOM übergangen, Ordner, nicht UTF-8, fehlendes Anführungszeichen, doppelte Pflichtspalte, fremde Ziffern und Unicode-Leerraum mit Meldung; Entscheidung 27), wrapper_config(), wrapper_nav(), rebalance_trigger() (`type`, `threshold`, Spaltennamen, vorhandene `out_col` nicht mehr still überschrieben, Teil-Trigger nur mit erlaubten Feldern), index_bond(), index_money_market(), index_currency_hedged() (`yield` je Kuponperiode > −100 %, Zinsspalten numerisch, `local` in der Länge von `data`, 0 Datenzeilen ein Fehler), result_analysis(), format_result() und format_summary() (Julia).
- Bootstrap und Studien: bootstrap() und bootstrap_study() (`n`, `method`, `ess`, `ess_grid` nur Zahlen und Wahrheitswerte, `max_tries`, `params` einschließlich `n_regimes`, `vol_window`, `tail_prob`, `both_tails`, höchstens 64 MS-GARCH-Regime, Prüfung vor der Vorberechnung, Text- und Faktorspalten, ESS mit weniger als 4 Renditen; `burn_in`, `chunk_size`, `chunk_dir` (bisher `""` ins Wurzelverzeichnis), doppelte Strategienamen, Strategien wie in simulation() vor dem Ziehen geprüft, eigene Kennzahlen mit eindeutigen Namen, `benchmark`, `sim_args`, `metrics`, `start`, `map`); Zwischendateien in `chunk_dir` werden atomar geschrieben, eine beschädigte bricht mit „Zwischendatei von Chunk <k> in chunk_dir ist unvollständig oder beschädigt …“ ab; bootstrap_config() (`indices`, `aux`, `letfs` als Liste von Listen, `rate_basis`, `ter_basis`, `days` > 0, `spread` ≥ 0, `regime_index`); bootstrap_data() (`i`; eine einzelne Pfadmatrix bzw. Tabelle wird wie dokumentiert angenommen), bootstrap_validate(), bootstrap_probability() (mindestens eine Bedingung), bootstrap_study_metrics(), bootstrap_block_length(), bootstrap_pooled() (`n`, `years`, `L` höchstens 100 Jahre, `country_weights` nach Namen zugeordnet statt nach Position, `target`, fehlende Spalten, unsortiertes Datum); sensitivity_grid(), sensitivity_rebalancing(), sensitivity_leverage(), series_leverage() (eine fehlende Indexspalte ergab in R still eine Reihe nur aus Kosten), planning_lumpsum_vs_dca(), param_range() (NaN/Inf, `n` höchstens 10^6), param_space(), param_search(), param_plateau(), param_bootstrap() (`ids`, `top`, `map`, `include`). Eigene Kennzahlen aus `metrics` in den Sensitivitäten und param_search() werden wie in bootstrap_study() geprüft (unbenannt, leer, doppelt oder gleich einer festen Spalte; bisher je Sprache verschiedene Tabellen; Entscheidung 43).
- Entnahme und Planung: withdrawal_rule() (`type`, `rate` 0–100, `cpr_years` und `ratchet_gap` höchstens 100), withdrawal_horizon() (ganze Jahre von 1 bis 100), withdrawal_cohorts() (Spalten numerisch, `cape`/`base_rate`/`inflation` vorhanden und ohne NA, `wrap`), withdrawal_paths() (`start`, `cape` als Pfadspalte), withdrawal_simulation() (Renditen ohne NA und endlich, Inflation > 0 und endlich, `horizon`, `years`, `income`, Felder mit mehr als zwei Dimensionen), withdrawal_max_rate(), withdrawal_perfect_rate(), series_shift_return(), portfolio_returns() (`candidates`, Gewichte endlich mit Summe > 0), planning_goal() (`n_grid`, `n_sim` ganze Zahlen), result_index() (`base` > 0).
- Forschung und Statistik: overfit_pbo() (`S` eine gerade ganze Zahl von 2 bis 24, Entscheidung 138; S = 26 brauchte rund 1,7 GB, S = 28 über 6 GB: „overfit_pbo: S darf höchstens 24 sein (choose(24, 12) = 2704156 Aufteilungen der CSCV; größere S brauchen zu viel Speicher).“), overfit_pbo(), sharpe_deflated(), sharpe_haircut() und overfit_reality_check() mit Renditematrix (`dates` je Zeile ein Datum, aufsteigend, ohne NA; keine unendlichen Renditen; logische Spalten nicht als Renditen; bisher rechnete R mit unsortierten Daten still mit verschobenen Perioden), sharpe_probabilistic(), sharpe_deflated() (`id`; bisher in Python 0 und negative von hinten gezählt), sharpe_haircut() (`n_tests` bis 10^8), sharpe_test(), sharpe_min_track_record(), overfit_walk_forward() (`step = 0` lief bisher endlos), signal_analysis(), result_heatmap().
- Taktik und Signale: signal_sma(), signal_ema(), signal_crossover(), signal_momentum(), signal_drawdown() (bisher schaute `window ≤ 0` in R in künftige Kurse), signal_volatility(), signal_combine(), signal_state(), momentum_score() und tactical_rotation() (`lookbacks` ganze Zahlen von 1 bis 1200 Monaten; bisher rechneten negative Rückblicke still mit künftigen Kursen), tactical_rules() (je Regel nur `when` und `weights`; Tippfehler wie `weight` bisher still ohne Gewicht), tactical_target_volatility(), tactical_conditional_volatility(), tactical_glidepath(), tactical_blend(), tactical_simulation().
- Abhängigkeit, Regime, Optimierung, Backcast, Szenarien: copula_fit(), tail_dependence(), dependence_dcc(), dependence_analysis() (Zustandsspalte gleichen Namens überschrieb bisher still die Rendite), quantile_regression(), tail_regression(), tail_covar(), dependence_validate(), regime_hmm(), regime_states(), portfolio_optimize(), portfolio_frontier(), portfolio_risk_contributions() (Gesamtrisiko 0 und Ledoit-Wolf mit d² = 0 mit eigener Meldung), portfolio_cpcv(), portfolio_rolling(), backcast_fit() (unendliche Kosten ergaben bisher ein Ergebnis an der Suchgrenze; `lag = "auto"` ohne bestimmbare Korrelation: „backcast_fit: lag = "auto": keine Korrelation bestimmbar (mindestens 30 gemeinsame Renditen mit Schwankung nötig); lag angeben.“, Entscheidung 145), backcast() (mit Fit sind Modellangaben in `...` ein Fehler, bisher still ignoriert), view_mean(), view_prob(), view_vol(), scenario_entropy_pooling(), scenario_copula(), scenario_risk(), scenario_crisis() (Summe der Gewichte ≤ 0: „scenario_crisis: Summe der Gewichte muss positiv sein.“), plot() einer Abhängigkeitsanalyse.
- Datenaufbereitung, Grafik, Hilfen: series_align(), series_check() (`columns` ohne doppelte Werte), series_align_macro() (`lag` ≥ 0, `name` keine vorhandene Spalte), series_convert_currency(), index_total_return(), series_deflate(), series_splice() (genau eine Wertspalte je Quelle), portfolio_template(); export_dashboard() (`x` aus simulation() vor dem Öffnen der Datei geprüft, bisher schrieb R eine fremde Grafik; `width`/`height` 3 bis 100 Zoll, plot_dashboard() in Python und Julia 300 bis 10000 Pixel), plot(<SimLevResult>) (unbekannte benannte Argumente ein Fehler, bisher in R ignoriert, in Python und Julia eine Warnung; Farbnummern als Text nur aus ASCII-Ziffern; Farben ±Inf bzw. ≥ 2^31 transparent wie in R), plot(<SimLevParamSearch>) ohne endliche Kennzahl, interner Optimierer (`maxit` ab 2^31, Zielfunktion ohne Wert). Python: Tageszahlen ±Inf oder |x| ≥ 2^63 werden auf jeder Plattform NaT. Python und Julia: `summary()`/`plot()` ohne Methode „summary: keine Methode für dieses Objekt.“; Julia `nrow`, `ncol`, `rows`, `inherits`, `attrs`, `isna_strict` mit Meldungen statt MethodError.
- Python: signal_state() und Signalbedingungen in tactical_rules() nehmen pandas-Felder mit fehlenden Werten an (`pd.array([True, pd.NA], dtype="boolean")`, `Int64`) wie R `c(TRUE, NA)`. Python und Julia: ein Textvektor nur aus NA gilt wie in R nicht als Signal (Entscheidung 164).

Schneller (Messungen der Pakete, Median, vorher → nachher; die Maschine war dabei meist durch einen zweiten Agenten belastet, Werte unter etwa 3 ms schwanken um ±15 %; Ergebnisse bitgleich, soweit nicht oben genannt):

- simulation() und Auswertung: Schiefe und Wölbung in einer Schleife über d·d statt pow (`calculate_skewness()` + `calculate_kurtosis()`, 30 Jahre Tagesrenditen) R 0,886 → 0,427 ms, Python 0,705 → 0,226 ms, Julia 0,845 → 0,298 ms; die Werte ändern sich in den letzten Bits (in 2 103 Zufallsfällen bis 6e-14 relativ, bei |Schiefe| < 1e-4 einmal 2,4e-12; gegen den exakten Wert gleich genau wie pow), gedruckte Ausgaben unverändert (Entscheidung 127). Tagesengine (30 Jahre, 4 Assets, Sparplan, Rebalancing) R ohne Steuer 1,47 → 1,20 ms, Gebühr und Vorabpauschale 2,37 → 2,00 ms; Kennzahlen R 2,21 → 1,96 ms; interne Rendite mit Einzahlungen je Aufruf R 206 → 122 µs, Python 205 → 114 µs, Julia 207 → 124 µs; `risk_free = 2` über 30 Jahre R 5,98 → 5,68 ms, Python 5,42 → 4,62 ms, Julia 4,96 → 3,69 ms; Prüfung der Kursspalten in R 1,96 → 1,15 ms; Julia mit Basiszinsspalte 16,4 → 6,4 ms; Python (30 Jahre, 4 Assets, mit Steuer) 11,2 → 9,5 ms, kleine Läufe (365 Tage) 1,559 → 1,195 ms. Einkommensteuer im Tarifweg: 1 Mio. Jahresabschlüsse mit Günstigerprüfung 815 → 562 ms.
- index_bond() (30 Jahre Tagesdaten): Standardverfahren R 2,51 → 1,42 ms, Python 1,71 → 1,22 ms; `method = "duration"` R 3,70 → 1,78 ms, Python 2,30 → 1,44 ms, Julia 10,7 → 8,4 ms.
- bootstrap() (1 000 Pfade × 2 520 Zeilen): R stationary 362 → 299 ms, Julia 234 → 200 ms; bootstrap_block_length() bzw. `L = "auto"`, n = 50 000: R 217 → 110 ms, Python 35,8 → 19,4 ms, Julia 47,5 → 33,9 ms. R bootstrap_study() mit 21 334 Warnungseinträgen: Zusammenfassung 2 609 → 61 ms (wuchs bisher quadratisch). Aufteilung von 100 000 Pfaden in Chunks: Python 113 → 3,2 ms, Julia 74 → 14 ms.
- Entnahme: withdrawal_cohorts() (85 Jahre Monatsdaten, 660 Kohorten) Python `"quarter"` 285 → 13,1 ms, `"year"` 89,3 → 13,9 ms, Julia 18,7 → 10,0 ms; Python Ausgabe eines Anlagehorizonts 14,8 → 1,3 ms; gewichtete Quantile in summary() (Python, N = 50 000) 5,4 → 1,9 ms.
- dependence_validate() (150 Pfade): R 0,452 → 0,170 s, Python 0,339 → 0,149 s, Julia 95,3 → 74,7 ms. Python regime_states() 56,4 → 0,8 ms, regime_subset() 55,8 → 1,8 ms.
- backcast_fit(method = "grid"), n = 8 000, 1 201 Punkte: structural R 1,771 → 0,717 s, Python 0,849 → 0,318 s, Julia 0,937 → 0,441 s; linear R 1,907 → 0,882 s, Python 0,860 → 0,320 s, Julia 7,83 → 0,44 s; spline Python 1,555 → 0,347 s, Julia 1,725 → 0,486 s. Julia `model = "linear"` (Brent) 89,8 → 14,2 ms.
- Optimierung (N = 60): portfolio_risk_contributions() mit Ledoit-Wolf R 0,229 → 0,115 s, Python 0,107 → 0,055 s; Python portfolio_optimize() mit Ledoit-Wolf 0,106 → 0,060 s; Julia `max_sharpe` 81,2 → 53,0 ms; `min_cvar` (T = 1 260, N = 30) Julia 0,796 → 0,453 s. portfolio_rolling() in R (6 Anlagen, 20 Jahre): Quartal/Woche 0,165 → 0,047 s, Monat mit risk_parity 0,627 → 0,248 s.
- Forschung: param_plateau() und print/summary einer Rastersuche (P = 9 261) R 2,164 → 0,157 s, Python 3,011 → 0,110 s, Julia 0,296 → 0,016 s; Python overfit_reality_check() (K = 25) 0,126 → 0,045 s; overfit_pbo() wöchentlich mit Datum Python 70,7 → 49,3 ms, Julia 71,4 → 40,6 ms; Julia param_bootstrap() hält die Studienergebnisse nicht mehr global fest (12 × 16 MB: 183 MiB → 0 MiB nach GC).
- Analyse und Taktik: Python result_analysis() (3 Reihen, 60 Jahre) 0,265 → 0,090 s, Julia 66,9 → 54,4 ms; R tactical_rules() (60 Jahre, 5 Regeln) 94 → 22 ms; series_splice() R 134 → 52 ms, Python 43,4 → 22,7 ms.
- Grafik: plot(<SimLevWeights>) (45 Jahre, 5 Spalten) Python 0,878 → 0,085 s, Julia 0,390 → 0,039 s; R plot(<SimLevResult>) (PDF) 0,275 → 0,140 s; Python plot_dashboard() 61,9 → 22,8 ms.
- Regeltexte (Python, Julia): Julia `%in%` über Mengen (`sum(s %in% t)` mit 40 000 Texten 6,78 s → 0,0057 s); Julia Spalten erst beim Zugriff umgewandelt (`eval_r` mit 200 Spalten 14 749 → 177 µs); `rep()` Julia `rep(1, 1e7)` 6,81 s → 70 ms, Python `rep(1:2, each = 5e6)` 541 → 82 ms; Python Datumsergebnis mit 100 000 Tagen 24,0 → 5,9 ms; Python `pmin`/`pmax` mit 3 Argumenten 2,99 → 0,27 ms. Speicher: Zwischenspeicher der Regeltexte höchstens 1 000 Einträge (nach 20 000 verschiedenen Regeltexten Python 3,3 statt 66,0 MiB, Julia 2,7 statt 54,1 MiB); Python `rep()` und Konstruktoren mit 8 statt 16 Byte je Wert.
- Quantile mit vielen Wahrscheinlichkeiten (n = 20 000, 5 000 probs; Python, Julia) 14,2–23,7 → 1,5–1,6 ms; Python `r_format` mit 1 000 Werten 3,40 → 1,08 ms; Python Backcast mit `accrual = "geometric"` (Vorbereitung) 18,5 → 2,1 ms.
- R über die Kerne (je Aufruf): sd (n = 250) 9,0 → 6,8 µs, var 10,4 → 7,6 µs, `cor(x, y, kendall)` (n = 200) 114 → 62 µs, filter (n = 2 500) 71,7 → 45,3 µs, hclust (N = 30) 39,0 → 29,4 µs; dist (Kern, alle drei Sprachen, eine Schleife je Methode) R 60 × 400 euklidisch 1 253 → 713 µs.
- `cores = "auto"` (P = 2, ohne Fremdlast) gegen `cores = 1`: R bootstrap_study() mit 400 Pfaden 1,06 → 0,78 s, sensitivity_grid() mit 24 Punkten R 0,85 → 0,55 s, Python 0,87 → 0,62 s; mit niedriger priorisierter Last daneben (R, 24 Einheiten zu 40 ms) 0,969 → 0,542 s; Julia (`-t 2`) sensitivity_rebalancing() mit 12 Einheiten 0,522 → 0,347 s, bootstrap_study() mit 8 Chunks 0,340 → 0,224 s. Python bei vielen leichten Einheiten (`bootstrap(n = 2000)`) 0,161 → 0,138 s. Kleine Rechnungen bleiben bei einem Lauf.
- Julia: erste Aufrufe nach dem Laden (die Vorkompilier-Arbeitslast übergibt die Daten als `RFrame`; bis dahin brachen 13 von 21 Schritten still ab; Entscheidung 154): dependence_analysis() 4,58 → 0,35 s, regime_hmm() 2,77 → 0,08 s, bootstrap() 0,98 → 0,08 s, tactical_rotation() 1,77 → 0,31 s, portfolio_optimize() 0,90 → 0,24 s.
- Laufzeit gegenüber 1.6.3 (`tests/werkzeuge/bench/run.py` auf der ruhigen Entwicklungsmaschine, je Lauf ein frischer Prozess, ein Faden; fünf Runden mit 1.6.3 und 1.6.4 abwechselnd, je Aufgabe Median der Rundenmediane aus je 3 Läufen): deutlich schneller simulation() über 30 Jahre mit Steuer, Sparplan und Rebalancing (S30) Python 8,2 → 5,4 ms (−34 %), Julia 9,4 → 3,7 ms (−61 %), erster Aufruf in Julia 251 → 122 ms (−51 %); erster Aufruf von dependence_analysis() in Julia (T5) 360 → 61 ms (−83 %). Python withdrawal_simulation() mit 2 000 Pfaden × 30 Jahren (T4) 8,3 → 8,1 ms, mit Steuern (T4s) 9,1 → 8,7 ms, innerhalb der Streuung (1.6.4 nach Behebung einer vor der Veröffentlichung gefundenen Verlangsamung der neuen NA-Prüfung eigens gemessen: fünf frische Prozesse, Median der Rundenmediane, Spannen 7,7–9,7 ms bzw. 8,7–11,8 ms). Die übrigen Aufgaben (bootstrap() stationär und GARCH, bootstrap_study(), Entnahme mit Tarifweg, dependence_analysis(), portfolio_optimize() mit min_cvar und hrp, MS-GARCH-Schätzung) liegen in allen drei Sprachen innerhalb der Streuung der Runden (Mediane −29 % bis +25 %, die Spannen der Runden überlappen; Nachmessungen mit sechs Prozessen je Fassung zeigten bei R T2, T4t, T7 und Python T1, T2 keine Änderung). Laden: R 11 → 13 ms, Python 274 → 256 ms, Julia 0,74 → 0,79 s (innerhalb der Streuung).

Langsamer:

- R optimize (intern) über den Kern: zunächst 17,6 → 29,2 µs je Aufruf mit einer billigen Zielfunktion (gut 10 µs Verwaltung je Aufruf); danach mit der Schleife der Zielfunktionsaufrufe in C 22,6 → 16,2 µs (spätere, eigene Messung; gegen 1.6.3 nicht eigens gemessen). R approx (intern) 28,4 → 30,6 µs bzw. 111 → 125 µs; R dist zunächst 657 → 737 µs (danach schneller, siehe oben). Bei den Likelihoods in SimLev fällt das nicht ins Gewicht.
- Julia: Vorkompilieren beim Bau 208 → 293 s, Speicherspitze 2,53 → 2,97 GB (rund 3 GB freier Arbeitsspeicher nötig); erster Aufruf von simulation() 0,084 → 0,094 s und rebalance_trigger() 0,069 → 0,117 s.

Entfallen (ohne Aufrufer bzw. Leser; Ergebnisse unverändert):

- Kern: der Zustandswert `S_CPI1` der Entnahme (immer 1), der Schalter „nur Wert ohne Gradient“ des DCC, der seit 1.1.0 unerreichbare sGARCH-Zweig der GJR-Zielfunktion, `TariffCore::diff`, die Einsprünge `simlev_c_engine_open_lots_n`/`simlev_c_engine_open_lots` der C-Schnittstelle (R nutzt die kompakte Lot-Ausgabe weiter) und `refund_due` aus `simlev_c_engine_counts`; der interne Einstieg `hmm_forward_backward` samt R-Hülle `.hmm_forward_backward`, Python `simlev._ext.hmm_forward_backward` und Julia `DependenceCore.hmm_forward_backward` (`hmm_em` ruft `hmm_fb_raw` weiter direkt; Entscheidung 158).
- R: `.show_arg_s`, immer wahre Bedingungen in sharpe_test() und plot.SimLevResult(), die unerreichbare Behandlung von `try-error`-Chunks in bootstrap_study().
- Python: interne Felder ohne Leser der Simulation (Klasse, Lieferbarkeit, Tagesindex je Asset, `kapest_rate`, `due_info`, `refund_due`), der Zweig `compact` der Engine-Hülle, `_sim_blocks._show`, `_vec_of`, `_cls`, `config._cls_all`, `config._r_class`, `_fmt_any`, `_fmt_nan`, `_wshow`, `_rshow`, `bootstrap._show`, `data_prep._fmt_num`, `deep_analysis._r_class`, die Zweige für `dict` und eindimensionale Felder in `_scen_frame`, ungenutzte Hilfen im Regelausdruck und im Zahlformat, ungenutzte Importe.
- Julia: interne Felder ohne Leser (`kapest_rate`, `due_info`, `refund_due`, `Cfg.tax_rate`), RLibm `atanh`, `asin`, `acos`, `sinh`, `cosh`, `lgamma_c`, `atan2`, `RParallel._add!`, `_blk_show`, `_blk_vec`, `_cls_all`, `_blk_cls`, `_r_class1`, `_check_taxable_income`, `_fmt_any`, `_fmt_nan`, `_wshow`, `_rshow`, `_show`, `_showable`, `_fr_class`, `_r_class`, `_fmt_vec`, ungenutzte Importe; die Übergangsformen der Zeichenfunktionen („nur SVG-Text“, Daten `nothing`; der exportierte Konstruktor `SimLevPlot(svg)` bleibt).
- Python und Julia: die unerreichbaren Zweige für `start = Inf`/`end = -Inf` in withdrawal_simulation(income), die Textfehler und das Recyceln ungleicher Längen in signal_state(), die nie genutzten Parameter `file` interner Grafikhilfen.
- Zusammengelegt (je eine Fassung): Mittelwert und Varianz von GARCH, MS-GARCH, GPD und Kerndichte (`slc_mean`, `slc_var_m`), die NaN-Regeln (`slc_quiet`, `slc_lnan`), die Rechnung je Element von pt/qt für einen und mehrere Threads, die Gewichte der Erstattung der Tagesengine; R Periodenenden (`.period_ends`) für bootstrap_pooled(), portfolio_returns() und die Entnahme, Hilfen der C-Hüllen in `huelle_r.h`; Python `print()` der Ergebnisklassen (vorher zwölf gleiche Methoden), var() über denselben Kernweg wie cov(); Python und Julia Zahl als Text über den Kern `sl_r_as_character_real` wie R's `as.character`; doppelte kleine Hilfen in Python und Julia.
- Repository: die Logo-Varianten `r/man/figures/simlev-blue.png` und `simlev-green.png` liegen jetzt in `assets/` (Entscheidung 167).

Intern, Bau, Doku und Tests:

- Kern: Längenprüfungen der Hüllen (R `.Call`, Python-Erweiterung, Julia `ccall`) für Projektion, QP, CVaR/CDaR, Quantilsregression, Kendall, rollierende Kovarianz, MS-GARCH, Optimierer, Viterbi, Kerndichte, Brent; Bereichsprüfungen ohne Ganzzahlüberlauf (Momentum-Rückblick, Spaltensummen mit Zeilenauswahl, Tage außerhalb ±1e9, Periodenzahl der Entnahme in 64 Bit); Fehler statt still falscher Werte oder endloser Suche bei nicht endlichen Angaben in Bootstrap-Kernen, Brent-Suche, t-Copula, Quantilsregression, HMM, Zielplanung, MS-GARCH ohne Speicher; formatC mit großer Breite schreibt den ganzen Text (bisher ab Breite 8 705 fremder Speicher, ab etwa 100 000 Absturz in Python und Julia); Teilsortierung, hclust, p.adjust und cov2cor ohne Zugriff außerhalb der Felder; R-Hülle allokiert unter `R_UnwindProtect`, Python-Hülle prüft jede neue Zahl. Über die öffentlichen Funktionen kommen solche Werte nicht an bzw. die Hüllen melden sie vorher.
- Python, Bau: Das Datenverzeichnis `simlev.data` (Tarifdatei, Anlageklassen, R-Farben) steht als Paket in `pyproject.toml`; setuptools warnt beim Bau nicht mehr, dass `simlev.data` in `packages` fehlt (Entscheidung 168). Inhalt von Wheel und sdist unverändert.
- Julia, Doku: README, `examples/schnellstart.jl` und `examples/tutorial.md` legen die Daten als `RFrame` an und nennen nur noch `RFrame` als Eingabe (eine NamedTuple-, Dict- oder DataFrame-Tabelle lehnt simulation() seit 1.6.4 ab). Python- und Julia-README: `result.trades` enthält je Asset `buys`, `sells` und `taxes` (bisher als „alle Buchungen (Lots, …)“ beschrieben). Neues Werkzeug `tests/werkzeuge/precompile_check.jl` führt die Vorkompilier-Arbeitslast mit sichtbaren Fehlern aus.
- Doku: Rd-Seiten, Python- und Julia-Docstrings nennen die neuen Grenzen und den Standard `cores = "auto"`; veraltete Verweise in `r/.Rbuildignore`, `julia/.gitignore`, `STRUKTUR.md`, den DEVELOPING-Dateien und `tests/schnittstelle/README.md` berichtigt.
- Tests (Ordner tests des Repositorys):
  - Die Vergleiche der Referenzfälle in Python (`tests/lib/reftree.py`) und Julia (`tests/lib/faelle.jl`, damit auch `tests/werkzeuge/gleichlauf/vergleich.{py,jl}`) kennen das Stufenmodell; Toleranz nur für die Teile in `tests/lib/toleranz.tsv`, Text, Druck, Konsole und Warnungen zeichengleich, alles andere bitgleich (Schalter `SIMLEV_LAX_NA`, `SIMLEV_STRICT_ZERO` unverändert).
  - Katalog `tests/{gleichlauf,fehler,ausgabe}/faelle` mit R 1.6.4 neu erzeugt; Fälle, die seit 1.6.4 ungültig sind, neu gefasst, der bisherige Aufruf jeweils als eigene Fehlerzeile; Tabellenzeilen kennen `nur = "py" | "jl"`; neue Fälle zu ungültigem `cores`, zu `rep()`, `var` mit NULL und den Regeltexten; `tests/schnittstelle/api.json` neu geschrieben (nur Zeilennummern). Die Python- und Julia-Tests mit alten R-Meldungen sind damit grün.
  - Die Zufallsprüfungen vergleichen gegen abgelegte Ausgaben von R 1.6.4 (`tests/werkzeuge/gleichlauf/run.py --ref-erzeugen 164`, `/home/claude/rlib164`). Erzeugt in 14 min 18 s, größter Prozess 2,71 GB; die vollen Dateien sind inhaltlich gleich den Ausgaben von R neu im Finaltest, gegen die Python und Julia in allen 23 Familien bitgleich waren. `tests/werkzeuge/bench/bench.jl` übergibt die Daten als `RFrame` (die NamedTuple-Tabellen lehnt 1.6.4 ab; bis dahin brach die Julia-Messung bei S30 ab).
  - Berichtigt: `tests/lib/reftree.py` mit `np.datetime64("NaT", "D")` (unter numpy 2.5 bisher 540 DeprecationWarnings); Julia-Übersetzungen zweier Breitenfälle in `tests/werkzeuge/breite/`.

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
