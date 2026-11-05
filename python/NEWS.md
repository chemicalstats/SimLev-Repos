# simlev (Python) – Änderungen je Version

## simlev (Python) 1.6.2

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

## simlev (Python) 1.6.1

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

## simlev (Python) 1.6.0

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

## simlev (Python) 1.5.2

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

## simlev (Python) 1.5.1

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

## simlev (Python) 1.5.0

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

## simlev (Python) 1.4.3

Patch-Update (R/Python/Julia). Ergebnisse und Meldungen bleiben unverändert, die Druckausgabe ändert sich nur durch zwei Korrekturen (unten); dazu ergänzt 1.4.3 Dateien, die in 1.4.2 fehlten, und ersetzt die Beispieldaten.

- Vollständigkeit: Julia: src/result.jl (Ergebnisobjekt SimLevResult mit print und summary) fehlte in 1.4.2, obwohl SimLev.jl die Datei einbindet; das Paket ließ sich daher nicht laden. R: die Hilfeseiten momentum_score.Rd und result_analysis.Rd fehlten in 1.4.2 und sind ergänzt.
- Beispieldaten: anlageklassen.csv neu erzeugt (in allen drei Paketen, mit Erzeugerskript). Rendite, Volatilität und Korrelation sind jetzt runde, hypothetische Annahmen zur Konstruktion eines Beispieldatensatzes (Rendite/Volatilität p. a.: Aktien 9 %/16 %, Anleihen 5 %/6 %, Rohstoffe 7 %/16 %, Managed Futures 8 %/10 %), kein Abbild realer Märkte; in 1.4.2 folgten sie Abrams, Bhaduri und Flores (2012), der Abschnitt „Beispieldaten“ in LITERATUR.md entfällt. Fallstudie im README, Tutorials und Abbildungen mit den neuen Daten neu gerechnet.
- Druckausgabe berichtigt (Zahlen unverändert): Im Druck von withdrawal_simulation() (summary) stehen fehlende Werte („–“) wieder rechtsbündig in ihrer Spalte; die Breite wurde mit sprintf("%10s") in Bytes statt Zeichen bemessen, und der Gedankenstrich hat in UTF-8 drei Bytes, die Zeile war daher je Spalte um zwei Zeichen zu kurz (R, Python und Julia). Julia: display() hängt an Ergebnisobjekte, deren Druck schon mit einem Zeilenumbruch endet (z. B. Optimierung, Parametersuche, sharpe_deflated, overfit_pbo), keine Leerzeile mehr an; die Ausgabe gleicht damit der von R und Python.
- Dokumentation: Versionsnamen statt Commit-Verweisen; der frühere Stand des R-Pakets heißt „0.5.0 (Vorfassung vor den Korrekturen)“ (erklärt in der Einleitung von r/NEWS.md).
- Tests: Der Abgleich der Beispielausgaben (tests/werkzeuge/doku/beispiele.py) vergleicht auch Leerzeilen; die Entnahme-Fälle in gleichlauf und fehler sind an den berichtigten Druck angepasst.

## simlev (Python) 1.4.2

Patch-Update (R/Python/Julia). Ergebnisse, Ausgaben und Meldungen bleiben unverändert; neu sind Dokumentation, Hilfe, Beispieldaten und die Gliederung der Tests.

- Dokumentation: Das Haupt-README ist eine Fallstudie (Aktien, Anleihen, Rohstoffe und Managed Futures für einen deutschen Privatanleger, Ansparphase und Entnahme) mit Code in R, Python und Julia und echten, in allen drei Sprachen gleichen Ausgaben, dazu ein Haftungsausschluss. Je Sprache ein Tutorial mit denselben Kapiteln (R: Vignette, Python und Julia: examples/tutorial.md); das frühere R-Tutorial inst/tutorial geht darin auf. Kurze Sprach-READMEs, DEVELOPING je Sprache, Zuordnung der Funktionen in STRUKTUR.md und Quellen in LITERATUR.md; der Ordner docs entfällt, die Bilder liegen bei den Paketen. Alle drei Sprachen sind gleichrangig beschrieben: Die Rechenkerne liegen als gemeinsamer C/C++-Code in core/, die Sprachpakete bilden die Schnittstelle darum.
- Beispieldaten: anlageklassen.csv (synthetische Tageskurse für Aktien, Anleihen, Rohstoffe und Managed Futures 2005–2024; Rendite, Volatilität und Korrelation nach Abrams, Bhaduri und Flores 2012) mit Erzeugerskript, in allen drei Paketen.
- Hilfe: Alle 116 Exporte haben in R, Python und Julia Beschreibung, Argumente, Rückgabe und ein lauffähiges Beispiel; Python- und Julia-Docstrings inhaltlich gleich der R-Hilfe. Berichtigt: withdrawal_simulation ohne das nicht vorhandene Argument sparer_pauschbetrag, die alten Einzelargumente galten bis 0.8.0, DCC-Schätzung mit BFGS (Nelder-Mead nur als Rückfall).
- Quelltext: Kommentare überarbeitet, ohne interne Arbeitsstände; Maschinencode der C/C++-Kerne unverändert.
- Tests (Ordner tests des Repositorys, nicht Teil der Pakete): nach Zweck gegliedert in methodik (Steuerrecht, Tarif, Engine, Entnahme, Kennzahlen, C-Bibliothek; Erwartung aus Gesetz, Handrechnung, Formel bzw. Testvektoren), gleichlauf (alle drei Sprachen rechnen bitgleich), fehler, ausgabe, schnittstelle und werkzeuge, mit einem Einstieg je Sprache und tests/run.sh. Aus 1.364 Referenzfällen werden 347 Tests: Szenarien, die mehrere Ergebnisse zugleich prüfen (in sechs Bereichen als Aufrufketten), und Tabellen „Eingabe → Meldung“ bzw. „Eingabe → Wert“; 5,2 statt 6,5 MB, Zeilenabdeckung in R, C/C++, Python und Julia unverändert, alle bisher geprüften Meldungen bleiben geprüft. Die methodik-Tests stehen als Tabellen mit Quelle je Zeile; die erwarteten Werte sind unverändert.
- Intern: Das Modul simlev._r.reftree (Laden und Vergleichen der Referenzfälle) gehört nicht mehr zum Paket, sein Vergleichsteil liegt in tests/lib; simlev._r.env ohne golden_dir() und module_dir() (SIMLEV_GOLDEN_DIR und SIMLEV_MODULE_DIR wirkten seit 1.4.1 nicht mehr).

## simlev (Python) 1.4.1

Patch-Update (R/Python/Julia). Ergebnisse und Meldungstexte bleiben gleich; in R ändert sich nur die Kopfzeile der Meldungen aus dem Kern (unten).

- R: Abbrüche und Warnungen aus dem Kern von simulation(), die bis 1.4.0 als Aufruf (conditionCall) einen festen Ausdruck der früheren Phasen trugen (Aufrufe von .perform_trade_buy, .perform_trade_sell und .perform_asset_split, if-Bedingungen mit NA, max() ohne Werte, stats::uniroot im internen Zinsfuß), nennen jetzt den Aufruf von simulation() wie die Eingabeprüfungen; bei der Ausgabe ändert sich nur die Kopfzeile (z. B. „Fehler in simulation(d, s, splits = split_rule(…))“ statt „Fehler in .perform_asset_split(…)“), der Meldungstext bleibt wortgleich. Warnungen des internen Zinsfußes außerhalb von simulation() (MWRR in result_analysis) tragen keinen Aufruf mehr. Python und Julia sind nicht betroffen (sie bilden keine R-Aufrufe nach).
- Tests: Alle Tests liegen in einem eigenen Ordner tests des Repositorys mit einem Katalog (README): Referenzfälle aus R, eine Datei je Bereich (12 statt 4.449 Dateien, 6,5 statt 43 MB), ihre Generatoren, die Suiten für R, Python und Julia, der Gleichlauf, die eingefrorene Schnittstelle und die Laufzeitmessung. Die Ordner golden und tools sowie die Testordner der drei Pakete entfallen; die Pakete brauchen zum Bauen und Prüfen keine Tests. Den Abgleich der C-Kopien macht jetzt core/sync.py. Von 4.479 Referenzfällen (4.395 Modul- und 84 Engine-Fälle) bleiben 1.364: die je Fall gemessene kleine Fallmenge, die in R (mit C/C++), Python und Julia dieselben Codezeilen erreicht wie alle Fälle zusammen (Zeilenabdeckung erhalten), dazu je exportierter Funktion ein Fall. Die Generatoren erzeugen weiter alle Fälle (bis auf einen: die Warnung von cor(…, use = "everything", method = "kendall") mit NA ist in R 4.3.3 nicht reproduzierbar); der Gleichlauf vergleicht Python und Julia mit allen. Die Eingabeprüfungen von asset_config(), create_strategy(), strategy_validate(), strategy_update_asset(), tax_profile() und simulation() (Listen-Strategie, risk_free- und Basiszins-Spalte) sind Referenzfälle im Bereich wrapper und werden in allen drei Sprachen gegen R geprüft.

## simlev (Python) 1.4.0

Minor-Update (R/Python/Julia). Ergebnisse, Ausgaben, Warnungen und Fehler bleiben bitgleich zu 1.3.0 (R); Python und Julia sind in den unten genannten Fällen jetzt wie R.

- simulation(): Die Engine ist ein gemeinsamer C++-Kern für R, Python und Julia (core/engine_core_impl.h, core/prepare_core_impl.h, core/evaluate_core_impl.h). Er umfasst die Tagesschleife (Kauf, Verkauf, Sparplan, Rebalancing, Liquidation), die Steuerphasen (Jahreswechsel, Vorabpauschale, § 23, Günstigerprüfung und Tarif, Verkäufe zum Ausschöpfen des Freibetrags, Steuerzahlung, Splits), die Vorbereitung (Termine wie seq.Date, Flags, Anfangszustand) und die Auswertung (Renditen, XIRR, Risikokennzahlen). Warnungen, Fehler und details-Ausgaben gibt der Kern als Codes aus; die Texte setzen die Sprachen wortgleich und in derselben Reihenfolge wie bisher. In den Sprachen bleiben Eingabeprüfung, Datenaufbereitung, Ergebnisobjekte, print, summary und plot sowie die Kennzahl-Helfer calculate_*.
- Laufzeit gegenüber 1.3.0 (tools/bench, Median über 6 Runden, alt und neu abwechselnd): S30 (eine Simulation über 30 Jahre mit Sparplan, Rebalancing und Steuer) R −94 %, Python −79 %, Julia −39 %; T3 (bootstrap_study mit Simulation je Pfad) R −64 %, Python −30 %, Julia −23 %. Aufgaben ohne simulation() unverändert im Rahmen der Messstreuung.
- Python und Julia (Abweichungen von R behoben): NA in einer Signalspalte bricht nicht mehr ab, sondern wirkt wie in R (kein Handelstag; an einem Jahreswechsel Abbruch wie R mit „missing value where TRUE/FALSE needed“), auch bei Signalen ohne Bestand bzw. ohne Geld. risk_free als logische oder Text-Spalte wird wie as.numeric gelesen, mit der Warnung „NAs introduced by coercion“. Ein Terminplan mit Spanne 0 oder negativ bzw. mit Start nach dem letzten Tag meldet den Fehler wie R statt in eine Endlosschleife zu laufen. NA in Bedingungen der Auswertung bricht wie in R ab, statt weiterzurechnen.
- Julia: Erster Aufruf jeder Hauptfunktion in einem frischen Prozess höchstens etwa 1 s (vorher bis 6 s); dafür Vorkompilieren etwa 240 s und Cache etwa 118 MB. Die Feldgrößen der flachen Felder zwischen Julia und der C-Hülle werden beim Vorkompilieren abgeglichen.
- Gleichlauf: Zufallsprüfungen über simulation() (sim_fuzz), Terminpläne (sched_fuzz) und Kennzahlen (metric_fuzz) mit Referenz aus R 1.3.0 in tools/gleichlauf/run.sh.

## simlev (Python) 1.3.0

Minor-Update (R/Python/Julia).

- withdrawal_simulation: Tarifweg mit tax_profile(income = income_tariff(...)). Veranlagung je Planjahr und Pfad mit Einkommensteuer, Solidaritätszuschlag, Kirchensteuer, Günstigerprüfung und Kirchensteuer-Saldo des Vorjahres, gerechnet wie in simulation() (gemeinsamer Kern core/tariff_core_impl.h, bitgleich zu den R-Funktionen von simulation()). Der Saldo eines Jahres wird mit der ersten Entnahme des Folgejahres gezahlt bzw. mindert sie; eine Erstattung über die Entnahme hinaus fließt ins Depot. Am Pfadende und am Horizont wird sofort abgerechnet. Das zu versteuernde Einkommen gilt nominal wie angegeben (eine Zahl für alle Planjahre oder ein Vektor der Länge Planjahre; nach Kalenderjahren benannt nur mit einem SimLevResult als start_value). Das Argument income (z. B. Rente) zählt nicht dazu; den steuerpflichtigen Teil rechnen Nutzer selbst in taxable_income ein. Kirchensteuer und Günstigerprüfung werden wie bisher ausdrücklich in tax_profile() angegeben, nichts wird aus der Ansparphase übernommen. Neues Ergebnisfeld tariff_years (nur mit Tarifweg). Ohne Tarifweg bleiben alle Ergebnisse gleich.
- income_tariff() nimmt einen Vektor ohne Namen an; simulation() meldet einen solchen Vektor jetzt beim Lauf statt beim Aufruf von income_tariff().
- Python und Julia: Datumsformat mit allen strftime-Schaltern, Breiten und E/O-Formen wie R unter Linux (glibc); %OS beachtet digits.secs der internen Optionen; leeres Format und Ergebnisse über 2048 Bytes wie in R.
- Python und Julia: Zahlenlesen wie as.numeric (mehr als 17 Ziffern, Überlauf knapp über DBL_MAX, Hex-Zahlen mit sehr kleinem Exponenten, "-nan", "0x ") und %% bzw. %/% einschließlich NaN-Vorzeichen jetzt wie R; Python rechnet ohne numpy.longdouble über den gemeinsamen Kern core/slc_rbase_num.c.
- Dokumentation: Quelle zu regime_hmm berichtigt (Nystrup u. a. 2015, Journal of Portfolio Management 42(1)), Rabiner (1989) und Schwarz (1978) ergänzt; Quellen und Abweichungen für die Entnahmeregeln clyatt, endowment, sensible, hebeler, cape, one_over_n und abw.
- Herkunft und Rechte: einheitlicher Herkunftsblock in den Dateiköpfen; die gemeinsamen Kerne core/slc_rbase* sind als Nachbildung von R-Quellen ausgewiesen; COPYRIGHTS in allen drei Paketen gleich gegliedert (u. a. Singleton-Quicksort, Brent, hclust, Kalenderalgorithmen nach Hinnant); das Python-Wheel enthält COPYRIGHTS.md.
- Gleichlauf: Zufallsprüfungen für NA/NaN in den Engine-Kernen, Datum, R-Grundfunktionen und Tarif laufen in tools/gleichlauf/run.sh mit; R und Python werden dort stets vollständig neu gebaut.

## simlev (Python) 1.2.0

Minor-Update (R/Python/Julia).

- sGARCH-Schätzung in einem einzigen Lauf: Trust-Region-Newton mit exakter Hesse-Matrix (Likelihood, Gradient und Hesse-Matrix in einem Durchlauf) auf den natürlichen Parametern mit den Schranken omega, alpha, beta >= 0 und alpha + beta < 1; der Startpunkt wird ohne Optimierung aus 12 Kandidaten (Variance Targeting und Momentenschätzer) nach der Likelihood gewählt. Ein Fit kann den Rand alpha = 0 so wieder verlassen. Auf 160 Prüfreihen stets der beste bekannte Wert (1.1.0: 38-mal darunter), auf 720 neuen simulierten Reihen 18-mal darunter (1.1.0: 213-mal); im Mittel schneller als 1.1.0. sGARCH-abhängige Ergebnisse (GARCH-Bootstrap, DCC) ändern sich. Die Persistenz am Rand ist jetzt genau 1 - 2^-50, die IGARCH-Warnung kann daher häufiger erscheinen.
- MS-GARCH: Likelihood und Gradient in einem Durchlauf, eigene Fassung für 2 und 3 Regime; etwa 1,6- bis 1,8-mal schneller bei gleichen Ergebnissen. Die Starts laufen mit cores > 1 parallel (POSIX-Threads, unter Windows nacheinander); das Ergebnis hängt nicht von der Thread-Zahl ab.
- Eine Bibliothek für alle Sprachen: Julia rechnet die Kerne von Engine, Steuer, FIFO, Entnahme und Research über dieselben C++-Kerne wie R und Python (C-Schnittstelle core/simlev_cabi.cpp); die eigenen Julia-Nachbauten entfallen. Julia braucht dafür einen C++-Compiler.
- Python und Julia rechnen die Nachbildungen der R-Grundfunktionen (Summen, Kumulationen, Sortierung, Rang, Quantile, tabulate, findInterval, cov/cor) über einen gemeinsamen C-Kern (core/slc_rbase*); Python bis zu 3-mal, Julia bis zu 1,5-mal schneller in den betroffenen Aufgaben. Kleine Randfälle (x^NA, findInterval mit einem Stützpunkt, Kendall mit Inf) verhalten sich jetzt wie in R.
- Engine-, Steuer- und FIFO-Kerne: Treffen NA und NaN in einer Rechenoperation zusammen, gilt die dokumentierte Regel „NA vor NaN“, unabhängig von Compiler und Operandenreihenfolge. R, Python und Julia rechnen damit auch in solchen Randfällen bitgleich; in R ändern sich nur NA/NaN-Randfälle, Ergebnisse mit gewöhnlichen Zahlen bleiben gleich.
- Python und Julia formatieren Datumswerte (strftime-Formate einschließlich %OSn) und lesen as.Date im Format %Y-%m-%d über einen gemeinsamen C-Kern (core/slc_rbase_date.c); die eigenen Nachbildungen entfallen. Python ist in den Aufgaben T5–T7 um etwa 50–80 % schneller.
- Julia rechnet Summen, Mittel und Kumulationen in erweiterter Genauigkeit sowie das Zahlenlesen wie R_strtod, %%, %/% und scientific() über die C-Kerne core/slc_rbase* (neu: core/slc_rbase_num.c); die eigene long-double-Nachbildung (ld80.jl) entfällt.

## simlev (Python) 1.1.0

Minor-Update (R/Python/Julia).

- GARCH-Schätzung: analytischer Gradient für sGARCH und GJR-GARCH (f und g in einem Durchlauf, ganz im C-Kern); GJR-Fit etwa 13-mal, sGARCH-Fit etwa 8- bis 11-mal schneller bei gleicher oder besserer Likelihood. GARCH-abhängige Ergebnisse (GARCH-Bootstrap, DCC) ändern sich in den letzten Stellen.
- GPD-, DCC- und Backcast-Schätzung mit analytischem Gradienten: GPD-Fit etwa 2,5-mal, backcast_fit (rmse, mse, hybrid; Zielfunktion jetzt ganz im C-Kern) etwa 5- bis 7-mal schneller, bei gleicher oder besserer Güte. DCC mit BFGS statt Nelder-Mead: schneller und häufig mit besserer Likelihood, in Einzelfällen (2–6 %) aber in einem anderen lokalen Optimum mit geringerer Likelihood als 1.0.0. Die abhängigen Ergebnisse (EVT, dependence_dcc, backcast_fit) ändern sich.
- Genauigkeit: Steuerkern und Kendall-Tau ohne long double (kompensierte Summen bzw. exakte Ganzzahlrechnung), damit plattformunabhängig und korrekt gerundet; keine Ergebnisänderung.
- Entnahme: withdrawal_simulation rechnet mit Kirchensteuer und Günstigerprüfung über income_rate() (gemeinsamer Steuersatz-Baustein mit simulation()); income_tariff() ergibt dort einen Fehler mit Verweis auf income_rate(). Angaben der Ansparphase werden nicht übernommen, sondern in tax_profile() angegeben.
- keep_paths: TRUE behält alle Pfade, eine Zahl k die ersten k (bootstrap_study, withdrawal_simulation); ungültige Werte ergeben einen Fehler. Vermögensfächer mit Titelzusatz „(erste k von n Pfaden)“; Chunk-Dateien tragen bei k > 0 den Zusatz _keep<k>. Geändert: bootstrap_study(keep_paths = TRUE) behielt bisher still einen Pfad.
- keep_returns: param_search(keep_returns = c("day", "none")); TRUE/FALSE ergeben einen Fehler mit Hinweis auf die neuen Werte.

## simlev (Python) 1.0.0

Major-Update (R/Python/Julia). Einzelheiten stehen im Abschnitt 0.5.0, der während der Entwicklung bis 1.0.0 fortgeschrieben wurde.

- Rechenkern: eigene C-Bibliothek für alle drei Sprachen (Julia per ccall): Zufallsgenerator, Verteilungen, lineare Algebra, Optimierer, GARCH/GJR-, GPD-, DCC- und MS-GARCH-Schätzung, Stineman-Interpolation, Glättungsspline, Kerndichte; geschrieben nach Fachliteratur.
- Unabhängigkeit: kein Code aus evd, imputeTS, stinepack, rugarch, Rsolnp, truncnorm oder numDeriv mehr; die Pakete stehen nur noch im Literaturverzeichnis.
- Zufall: eigener Generator mit simlev_seed() und seed-Argument; set.seed steuert SimLev nicht mehr; Ergebnisse unabhängig von cores und in R, Python und Julia gleich. Zufallsergebnisse ändern sich gegenüber 0.10.0.
- Schätzer: GJR-GARCH mit gamma < 0 unter alpha + gamma >= 0 und Stationarität (im Vergleich mit rugarch 51 von 51 Fällen gleichwertig oder besser); MS-GARCH mit analytischem Gradienten; t-Copula über ein Profil in nu mit Gauss-Grenzfall; qnorm mit eigenen Startnäherungen, rnorm und rgamma schneller als in R.
- Geändert: GARCH-Label "ml", dependence_dcc deterministisch; set_seed und rng_kind in Python und Julia entfallen; C-Bibliothek in Python und Julia Pflicht.
- Doku: Literaturabschnitt mit 112 geprüften Quellen, COPYRIGHTS und NEWS neu; Schnittstelle neu eingefroren.

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
R-Pakets, 0.5.0 (Vorfassung vor den Korrekturen); der Name ist in der
Einleitung von [`r/NEWS.md`](../r/NEWS.md) erklärt. Zwischenversionen 0.2 bis
0.4 der Python-Fassung gibt es nicht; alle Änderungen sind in 0.5.0
zusammengefasst. Die Begründungen der fachlichen Änderungen stehen in
[`r/NEWS.md`](../r/NEWS.md), Abschnitt „SimLev 0.5.0“.

### SimLev eigenständig (1.0.0)

SimLev nutzt keine Funktionen aus
fremden Paketen mehr. Zufall und Numerik rechnet wie in R und Julia die
eigene C-Bibliothek (Quellen in `core/` des Repositorys, Kopien in
`src/core/`, Hüllen `simlev._lib`). Die vollständige Liste, was ersetzt
wurde, die Laufzeiten und die Begründungen stehen in
[`r/NEWS.md`](../r/NEWS.md) (Abschnitt „SimLev eigenständig“); die Ergebnisse sind
bitgleich zu R. Die Quellen der Verfahren stehen im Abschnitt
[`LITERATUR.md`](../LITERATUR.md), die bleibenden
Nachbildungen von R-Grundfunktionen in [`COPYRIGHTS.md`](COPYRIGHTS.md).

**Was ersetzt wurde:** die Nachbildungen von R's Zufallszahlen
(`simlev._r.rng`, C-Fassung `src/_rng_r.c`), Verteilungen (`nmath`,
`_toms708`, `_cmath`), linearer Algebra (`_blas`, `_lapack`, `_linpack`,
Teile von `linalg`), Optimierern (`_lbfgsb`, `port`, `optim` in
`stats_optim`/`_optim`), `lm`/`glm`/`t.test` (`stats_models`),
`smooth.spline`/`density`/`fft` (`_sbart`, `_fft`, `stats_smooth`) und der
Pakete evd, rugarch, Rsolnp, truncnorm, imputeTS und stinepack
(`simlev._r.{evd, rugarch, solnp, truncnorm, imputets, stinepack}`), dazu
`simlev._bootstrap_core` und die reinen Python-Kerne als Rückfall.

**Was sich für Nutzer ändert, mit Umstellungshinweisen** (Einzelheiten wie
in R):

- **Installation:** Die C-Erweiterung `simlev._ext` ist Pflicht; zum
  Installieren braucht es einen C- und C++-Compiler und die Python-Header.
  Ohne Compiler bricht `pip install` ab (bisher rechnete SimLev dann in
  reinem Python).
- **Zufall und `seed`:** Die Exporte `set_seed` und `rng_kind` entfallen.
  Den Zustand setzt `simlev.simlev_seed(k)`; zufällige Funktionen nehmen
  weiter `seed`. Mit `seed=None` zieht ein Aufruf genau einmal einen
  Startwert aus dem Zustand von SimLev. Ergebnisse hängen nicht von `cores`
  ab. Zufällige Ergebnisse ändern sich gegenüber früher (anderer Generator,
  gleiche Verteilung). Umstellung: `simlev.set_seed(1); simlev.bootstrap(…)`
  wird zu `simlev.bootstrap(…, seed=1)` oder `simlev.simlev_seed(1);
  simlev.bootstrap(…)`.
- **GARCH-Label `"ml"`** statt `"rugarch"`/`"optim"`, **`dependence_dcc()`
  deterministisch**, **GJR mit γ ≥ 0**, eigener **Spline** und eigene
  **Kerndichte**, strengere **Fehler bei Randfällen** (NA/NaN/Inf in der
  rechten Seite eines Gleichungssystems, nicht endliche Werte bei Stineman;
  0×0-Matrix ergibt ein leeres Ergebnis), **Welch-Test mit NA** bei
  konstanten Bereichen in `signal_analysis()`, **Schranken bei BFGS und
  Nelder-Mead** in der internen Hülle `simlev._lib.optim` ein Fehler, häufiger
  die **Warnung zur IGARCH-Nähe**: wie in [`r/NEWS.md`](../r/NEWS.md).
- **Schalter entfallen:** `SIMLEV_NO_EXT` (reine Python-Kerne),
  `SIMLEV_LAPACK` (System-LAPACK für Eigenvektoren) und `SIMLEV_R_SYS_TIME`
  (Uhr für gosolnp).
- **Laufzeit** (`tools/bench`, Median, ein Kern, vor und nach dem Einbau der
  eigenen Kerne): GARCH-Bootstrap (T2) 0,253 → 0,040 s, `dependence_analysis`
  mit DCC (T5) 0,515 → 0,114 s, `simulation` 30 Jahre (S30) 0,120 → 0,079 s,
  MS-GARCH-Schätzung (T8) 0,518 → 1,271 s (zwölf statt zwei Starts im
  gemeinsamen C-Kern); die übrigen Aufgaben etwa gleich. Tabelle in
  [`r/NEWS.md`](../r/NEWS.md).

**Tests:** Die frühere Suite ist bis zum Neuaufbau ausgesetzt
(`SIMLEV_LEGACY_TESTS=1` lädt sie); `pytest` führt die Rauchproben
für 1.0.0 aus. Maßgeblich ist die Gleichlaufprüfung
`tools/gleichlauf/run.sh` (27.10.2026: 4.260/4.260 Modul- und 1.182/1.182
Engine-Fälle bitgleich zu R).

### Eigene numerische Kerne (1.0.0)

- **C-Bibliothek statt der Nachbildungen von R's Numerik:** Verteilungen, lineare Algebra und Matrixprodukt, kleinste Quadrate und Logit-IRLS, Welch-Test, Kerndichte, Optimierer, GARCH/GJR, GPD, DCC, MS-GARCH, Stineman und Glättungsspline rufen wie in R die C-Bibliothek (`simlev._lib`) statt `simlev._r.nmath`, `linalg`, `stats_models`, `stats_smooth`, `stats_optim`, `rugarch`, `evd` und `imputets`; die Nachbildungen werden nicht mehr aufgerufen und entfallen in 9.6c. Geänderte Ergebnisse und Labels (GARCH `"ml"`, DCC deterministisch, Spline, Kerndichte, `signal_analysis()["fit"]["model"]`) wie in [`r/NEWS.md`](../r/NEWS.md); bitgleich zu R.

### Eigener Zufall (1.0.0)

- **Zufall der C-Bibliothek statt der Nachbildung von R's Zufallszahlen:** Alle zufälligen Funktionen ziehen wie in R aus dem Zufallszustand von SimLev (neu `simlev_seed()`); `seed=None` zieht genau einmal einen Startwert daraus, `set_seed()` (Nachbildung von R's `set.seed()`) wirkt auf SimLev nicht mehr. Ergebnisse bitgleich zu R und unabhängig von `cores`; Einzelheiten in [`r/NEWS.md`](../r/NEWS.md).

### Reine Python-Kerne in NaN-Randfällen (0.10.0)

- **Bitgleich zu R auch ohne C-Erweiterung:** Die reinen Python-Kerne (`SIMLEV_NO_EXT=1` bzw. ohne Compiler) liefern jetzt auch bei NA/NaN-gemischten Eingaben, Division durch 0 und NaN-Vorzeichen dieselben Bits wie R: `min_cvar_core`/`min_cdar_core` (Division durch 0 wie C, `quantile7` mit Nachbildung von `std::nth_element`), `hmm_forward_backward`, `dcc_filter`, `garch_filter`, die Engine-Kerne in `_core.py`, `boot_wild`, `boot_garch`, `boot_ms_garch` und `rtruncnorm` (Operandenfolge des R-Baus über `simlev._r.rnum.n_add` usw., weil CPython je nach spezialisiertem Bytecode bei zwei NaN verschieden wählt); `_qnorm_std` hat den Zweig r > 27 aus R 4.3.3 (Zufallsvergleiche: vorher 2.868/3.000, 377/400, 4.478/4.500, 4.443/4.500, 6.954/7.000, 13.808/14.000 Fälle bitgleich, jetzt alle; neu `tests/test_reine_kerne_nan.py`).

### Restpunkte Fonds-Wrapper (0.10.0)

- **Auswahl aus `wrapper_nav()`:** Jede Auswahl (`iloc`, `loc`, Spalten, `head()`, `tail()`, `query()`, `copy()`) ist ein gewöhnlicher `pandas.DataFrame` ohne `attrs` (bisher wurden `attrs["inner"]` und `attrs["wrapper"]` mitkopiert, tief bei jeder Spaltenauswahl); wie R `[.SimLevWrapperNav`. Umgesetzt über `_NavAttrs` (die `attrs` des ganzen Objekts geben bei der Weitergabe durch pandas ein leeres `dict`).
- **`withdrawal_simulation()`:** Ein `DataFrame` mit Spalte `date` als `x` ergibt den Fehler wie in R (bisher wurde er ohne Fehler als Renditematrix gelesen).
- **`strategy_from_weights()`/`portfolio_template()` mit `wrapper`:** ein `SimLevWrapperConfig` für alle Assets, ein `dict` Asset → `SimLevWrapperConfig` je Asset, Fehler wie in R (bisher wurde ein einzelnes `SimLevWrapperConfig` stillschweigend weggelassen).

### Fonds-Wrapper (0.10.0)

Port des Fonds-Wrappers aus R (Begründung und Rechenregeln in [`r/NEWS.md`](../r/NEWS.md) und im Kopf von `simlev/wrapper.py`); bitgleich zu R in allen 72 Fällen des neuen Referenzmoduls `golden/modules/wrapper`, mit und ohne C-Erweiterung. Die Schnittstelle ist neu eingefroren (`tools/api_snapshot/CHANGES.md`).

- **Neu:** `wrapper_config(strategy, *, rebalance=None, costs=funds_costs(), order_fee=None, volume=None)` → `SimLevWrapperConfig`, `wrapper_nav(data, wrapper, *, splits=None)` → `SimLevWrapperNav` (`DataFrame` mit `date`, `nav`, `gross`, `fee`, `perf_fee`, `perf_paid`, `hwm`; `attrs["inner"]` und `attrs["wrapper"]`; Teilmengen sind gewöhnliche `DataFrame`) und `asset_config(..., wrapper=None)`. Beide Klassen drucken wie die R-Methoden (`print(x)`, `x.format()`).
- **Engine:** `simulation()` rechnet je Wrapper-Asset den Anteilswert aus den inneren Spalten (`_sim_phases._sim_check_inputs`) und hängt ihn als Kursspalte an; der Anteilswert splittet nicht (`cfg["no_split"]`), mit `details=True` kommt `result.wrappers` dazu. Die normalisierten Daten gehen als `_Frame` an die innere Rechnung (`simulation()` nimmt intern auch ein `_Frame`).
- **Paketzustand:** Der Zustand der Ordergebühren (`_sim_base._FEE`, R `.fee_env`) wird vor der inneren Rechnung gesichert und danach, auch nach einem Fehler, wiederhergestellt.
- **Meldungen:** Hinweise der inneren Rechnung erscheinen auf `sys.stderr` als „Hinweis: Wrapper '<Name>' (innere Rechnung): …“ (in `wrapper_nav()` „wrapper_nav (innere Rechnung)“), Warnungen und Fehler als „simulation: Wrapper '<Name>' (innere Rechnung): …“. Bei Handelstagsdaten steht der Auffüll-Hinweis daher wie in R zweimal.
- **Aufrufer:** `strategy_validate()` (Spaltenkollision, innere Spalten und Signale), `strategy_update_asset(..., wrapper=…)` (auch `None` zum Entfernen), `planning_lumpsum_vs_dca()` (Kurs des Wrappers = Anteilswert im Fenster) und `withdrawal_simulation(wrapper_nav(...))`; `bootstrap_study`, `param_search`, `sensitivity_*` und `overfit_*` gehen unverändert über `simulation()`. Kursspalten einer Strategie liefert `config._strategy_columns` (R `.strategy_columns`).
- **Tests:** `tests/test_wrapper.py` (Port von `test-wrapper.R`: Plausibilität, Handbeispiel, Startkosten, NA-Tage, Fehler, Hinweise, Gebührenzustand, Splits, Aufrufer, Druck).

### Standard-Spread 0 und alter Fondsmodus entfernt (0.10.0)

Begründung in [`r/NEWS.md`](../r/NEWS.md); die Schnittstelle ist neu eingefroren (`tools/api_snapshot/CHANGES.md`).

- **Standard-Spread jetzt 0:** `asset_config(spread = 0)` statt `0.1`; wer Spreads abbilden will, gibt sie an. Ausdrücklich gesetzte Werte bleiben. Ohne Angabe rechnen damit `asset_config()`, Listen an `create_strategy()`, `strategy_from_weights()`, `portfolio_template()`, die `asset_args` von `tactical_simulation()` und die Standardstrategie von `sensitivity_leverage()` ohne Spread (bisher 0,1 %). Die Referenzfälle bleiben gleich: Ihre Generatoren schreiben `spread = 0.1` jetzt aus.
- **Alter Fondsmodus entfernt:** `simulation()` hat kein Argument `funds` mehr; `simulation(..., funds=funds_costs())` ergibt den üblichen Fehler für ein unbekanntes Argument (`TypeError: simulation() got an unexpected keyword argument 'funds'`), ohne Sonderbehandlung. Entfallen sind der Engine-Weg `tax_mode = "funds"` (Fondskosten am 31.12. und anteilig am letzten Tag mit Teilverkauf, Performancegebühr gegen den Höchststand des Depots, Steuer auf den Gesamtgewinn bei Liquidation) sowie der Baustein `funds` in `sim_args`, Rastern und Suchräumen (Pfade `"funds.*"`); die flachen Namen `funds_fee` und `bonus_fee` sind jetzt unbekannte Argumente. Die geteilten C/C++-Kerne enthielten keinen Fondscode. `result.trades` hat keinen Eintrag `fees` mehr (er enthielt nur die Fondskosten); entfernt sind auch die Hilfen dafür (`_calculate_fund_fees`, `_Actions.raise_cash`, `flag_fund_fee`, `totals["total_value"]`).
- **Umstellung:** Nachfolger ist der Fonds-Wrapper `wrapper_config()` (siehe oben) mit `funds_costs()` als Kostenbaustein: Der Wrapper wird als eigene Kursreihe (Anteilswert) gerechnet und außen wie ein Einzelpapier gehandelt und besteuert. Unterschiede zum alten Modus: Die Fondskosten werden täglich vom Anteilswert abgezogen (bisher am 31.12. aus der Summe der Tageswerte bzw. anteilig am letzten Tag), und die Performancegebühr bemisst sich am Höchststand je Anteil (bisher am Höchststand des Depots, der mit jeder Einzahlung stieg). `funds_costs()` bleibt mit Prüfung und Druckausgabe exportiert; `simulation()` nimmt es nicht an.
- **Referenzfälle:** Entfernt sind die 39 Referenzfälle des Fondsmodus: 13 in `golden/cases` (`f07_funds_liq`, `f08_funds_1231`, `f28_details_split_funds`, `r018`, `r035`, `r052`, `r086`, `r171`, `r222`, `r358`, `r443`, `r460`, `r477`), 2 in `golden/extra` (`x02_30y_funds_split_int`, `x16_funds_fee_high`) und 24 im Modul `engine` (`bk01`, `bk18`, `bk19`, `ch12`, `fee05`, `fu01`–`fu11`, `fu14`, `fu16`, `gp05`, `hv15`, `zz02`, `zz08`, `zz13`, `zz20`); Engine-Fälle jetzt 90 (55 + 35), Modul-Fälle 4.659. Alle übrigen Fälle rechnen unverändert (Nachweis und Liste in `golden/README.md`, im Repository bis 1.4.0); acht Fehlerfälle in `bootstrap`, `param_search` und `sensitivity` nennen `funds` nicht mehr in der Liste der Bausteine.

### Geschwindigkeit (0.9.1)

Schneller bei gleichen Ergebnissen (alle Referenz- und Golden-Fälle bitgleich, Schnittstelle unverändert):

- **Reines Python:** `libm.exp`/`log` auf Feldern ohne Python-Hülle je Element, `r_pow_vec` und `_pow_vec` mit schnellem Weg für endliche Basen, `sell_count` mit fortlaufenden long-double-Summen über `np.cumsum`, Probelauf der Vorabpauschale kopiert nur `totals` und `status`, Datumsspalten auf dem ganzen Feld, `dgemm` mit langem k als fortlaufende Summe, MS-GARCH-Filter und stationäre Verteilung für zwei Regime mit lokalen Variablen, Entnahme-Kern ohne Neudefinition je Periode. Rechenfolge und libm-Aufrufe sind dieselben.
- **Optionale C-Erweiterung:** `simlev._ext_msgarch` nutzt denselben MS-GARCH-Filterkern wie das R-Paket (`r/src/ms_garch_core.c`, Kopie in `python/src/`). `pip install` baut sie, wenn ein C-Compiler vorhanden ist; sonst rechnet wie bisher der reine Python-Kern. `SIMLEV_NO_EXT=1` erzwingt den Python-Kern. Eine MS-GARCH-Schätzung (2 Regime, n = 2.000) braucht damit etwa 0,4 s statt 4,5 s.
- **Gemeinsame Kerne:** Die Erweiterung heißt jetzt `simlev._ext` und enthält alle nativen Kerne des R-Pakets ohne Zufallszahlen, aus denselben Quellen wie R (`r/src/*_impl.h`, `ms_garch_impl.c`; Kopien in `python/src/`): MS-GARCH-Filter, die Forschungskerne (`proj_box_simplex`, `qp_box_simplex`, `min_cvar_core`, `min_cdar_core`, `roll_mean_core`, `roll_cov_core`, `kendall_tau_core`, `quantile_reg_core`, `hmm_forward_backward`, `garch_filter`), den Entnahme-Kern, den DCC-Filter, die rugarch-Filter, `nlgpd` (evd), `locf` (imputeTS) und die Engine-Kerne (`_core.py`: Report, Kauf, Markt-Update, FIFO, Steuer). Der R-Bau ist dabei unverändert (gleicher Maschinencode). Ohne Compiler oder mit `SIMLEV_NO_EXT=1` rechnen die reinen Python-Kerne wie bisher. Ob die Erweiterung aktiv ist, zeigt `simlev._r.env.ext() is not None`. Der reine MS-GARCH-Filter liefert jetzt auch bei NA/NaN in den Daten dieselben NaN-Bits wie R. Messbasis (`tools/bench/ergebnis_2026-10-26_kerne.csv`, Median, mit gegen ohne Erweiterung): `portfolio_optimize` `min_cvar` 0,17 s statt 0,87 s, `dependence_analysis` mit DCC 0,50 s statt 1,01 s, `withdrawal_simulation` 0,12 s statt 0,30 s, `bootstrap` GARCH 0,51 s statt 0,62 s, Simulation 30 Jahre 0,083 s statt 0,094 s.
- **Kerne mit Zufallszahlen:** Auch die Bootstrap-Kerne (`_bootstrap_core`: Index-Ziehungen IID, Block, stationär, Regime, Tails, dazu Wild, Reset, EVT, GARCH, MS-GARCH sowie `rolling_vol`, `assign_regimes`, `estimate_trans_mat`) und `rtruncnorm` (truncnorm, Startwerte von gosolnp) rechnen in `simlev._ext` mit denselben Quellen wie R (`r/src/bootstrap_core_impl.h`, `r/src/vendor_truncnorm_impl.h`). Die Zufallszahlen zieht dort eine C-Nachbildung von R's Generatoren (`src/_rng_r.c`, aus R 4.3.3: Mersenne-Twister und L'Ecuyer-CMRG, Normalverteilung per Inversion, `exp_rand`, `rgeom`/`rpois`, `dnorm`) auf dem Zustand von `simlev._r.rng`; danach ist der Zustand derselbe wie nach dem reinen Python-Kern, `set_seed`, `.Random.seed` und L'Ecuyer-Streams (`cores`) wirken unverändert. Andere Zufallsarten und Eingaben außerhalb des gültigen Bereichs rechnet still der reine Python-Kern. Der R-Bau ist unverändert (gleicher Maschinencode). Messbasis (`tools/bench/ergebnis_2026-10-26_rng.csv`, Median, mit gegen ohne Erweiterung): `bootstrap` stationär 200 Pfade 0,048 s statt 0,35 s, `bootstrap_study` 0,50 s statt 0,59 s, `bootstrap` 400 Pfade mit `cores = 1` 0,11 s statt 0,81 s, mit `cores = 2` 0,29 s statt 0,59 s.

### Eingefrorene Schnittstelle (0.9.0)

Die Schnittstelle 0.5.0 ist in `tools/api_snapshot/frozen/py.json` festgehalten und wird von `tests/test_api_frozen.py` und `tools/api_snapshot/run.sh --check` geprüft; Änderungen nur über `run.sh --freeze` mit Eintrag in `tools/api_snapshot/CHANGES.md`.

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
- **Python: Nicht-Pflichtargumente nur als Schlüsselwort** (`*` in der Signatur) in allen öffentlichen Funktionen mit R-Gegenstück, z. B. `asset_config(asset_class='etf', trading='bnh', share=0.6)`, `withdrawal_simulation(R, rule=withdrawal_rule(type='vanguard'))`, `bootstrap(d, cfg, method='stationary', n=100)`. Pflichtargumente bleiben positionell, auch wenn sie in R nach optionalen stehen (`bootstrap_study(data, config, method, n, strategies, *, …)`, `param_search(data, builder, space, *, …)`, `tactical_glidepath(data, from_, to, *, …)`). Nicht betroffen: die Nachbildungen von R-Basisfunktionen `set_seed`, `rng_kind`, `isna_strict`.

### Bausteine für `simulation()` (0.9.0)

`simulation()` nimmt die Einstellungen jetzt als Bausteine:

`simulation(data, strategy, start_value=10000, costs=sim_costs(), dca=None, rebalance=None, splits=None, tax=None, risk_free=0, fractions=True, liquidate=False, details=False)`

`None` heißt aus. Die flachen Argumente bis 0.8.0 gibt es nicht mehr (keine Aliasse); die Engine rechnet unverändert, alle Referenzfälle sind nach der Übersetzung bitgleich (Nachweis mit `golden/tools/blocks_from_flat.py`). Jeder Baustein prüft seine Argumente selbst und hat eine Druckausgabe.

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
| `tax_mode = "funds"`, `funds_fee`, `bonus_fee` | `funds = funds_costs(fee, performance_fee)`, seit 0.10.0 entfernt (siehe oben) |
| `spread` (ohne Wirkung, nur Warnung) | entfällt; der Spread gilt je Asset (`asset_config(spread = )`) |

Neue Regeln: `tax_profile()` mit `rate` und `church_tax` > 0 ist ein Fehler (mit Kirchensteuer gilt der Satz nach § 32d Abs. 1 EStG); `income` nimmt entweder `income_rate()` oder `income_tariff()`. Freibetrag-Ausschöpfung ohne persönliche Besteuerung lässt sich nicht mehr angeben (bisher wirkungslos); die Warnungen zu wirkungslosen flachen Argumenten entfallen. Fehlermeldungen der Prüfungen nennen den Baustein (z. B. `dca_plan: 'value' muss …`, `tax_profile: church_tax …`). Mit `sparer_pauschbetrag = 0` steht in `tax_report$sparer_pauschbetrag_annual` 0 (bisher der angegebene Betrag neben `use_sparer_pauschbetrag = False`).

Weitere Änderungen: `plot(<SimLevWeights>, main = "Zielgewichte")` hat den Titel als Argument (R wie die Ports); das Modul `simlev.tax_tariff` heißt `simlev._tax_tariff` (die Funktion `simlev.tax_tariff()` bleibt öffentlich).


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
  und `golden/extra` (35 Fälle, seit 0.10.0) und nimmt mehrere Ordner oder Dateien sowie
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
  R 0.5.0, siehe `r/NEWS.md`, „Korrektur der Fondskosten-Argumente“); bisher bildete Python den Fehler
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
