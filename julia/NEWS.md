# SimLev.jl (Julia) – Änderungen je Version

## SimLev.jl 0.5.0

Die Julia-Fassung ist jetzt ein vollständiger Port des R-Pakets SimLev
0.5.0: alle 110 Exporte aus `r/NAMESPACE`, bitgleich zu R. Die Vorversion
0.1.0 enthielt nur die Engine und entsprach dem früheren Stand des
R-Pakets vor den Korrekturen (Commit 54b5b4f). Zwischenversionen 0.2 bis
0.4 der Julia-Fassung gibt es nicht; alle Änderungen sind in 0.5.0
zusammengefasst. Die Begründungen der fachlichen Änderungen stehen in
[`r/NEWS.md`](../r/NEWS.md), Abschnitt „SimLev 0.5.0“. Das Paket braucht
weiterhin nur die Standardbibliothek (`Dates`, `Printf`, `Logging`;
`LinearAlgebra` nur als Ersatzweg für Eigenvektoren).

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
* `cores > 1` rechnet sequenziell mit der Zufallssemantik von
  `mclapply(mc.set.seed = FALSE)`, also mit denselben Ergebnissen wie R.

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
  es nicht mehr (wie in R). Unbekannte Schlüsselwörter werden wie R's `...`
  stillschweigend übergangen. Das Statistik-Panel zeigt die Sharpe Ratio
  aus `statistics` statt einer vereinfachten Formel.
* `export_dashboard()` schreibt wie bisher SVG, jetzt aber immer, auch bei
  anderen Dateiendungen (früher `.html` direkt sowie `.pdf` und `.png`
  über `rsvg-convert`); die Meldung erscheint wie in R auf `stderr`, die
  Rückgabe ist `nothing` statt des Dateinamens.
* `export_html_dashboard()` ist jetzt wie in R nur ein Platzhalter und
  bricht mit der Meldung ab, die R ohne plotly ausgibt (früher schrieb die
  Funktion das interaktive Dashboard). Das interaktive Dashboard schreibt
  `plot_interactive()`, jetzt mit dem Argument `engine`; das HTML ist
  byte-identisch zu R.
* `simulation()` bricht nicht mehr mit „subscript out of bounds“ ab, wenn
  `funds_fee` oder `bonus_fee` außerhalb des Fondsmodus zusammen mit
  `church_tax`/`tax_rate` oder `taxable_income` angegeben ist (Korrektur in
  R 0.5.0, siehe `r/NEWS.md`, Nachtrag); bisher bildete Julia den Fehler
  nach.

### Prüfwerkzeuge

* `tools/compare_golden.jl` prüft die Engine-Fälle eines Ordners
  (`golden/cases`, 68 Fälle; `golden/extra`, 37 Fälle) strikt mit NA ≠ NaN,
  einschließlich `print` und `details = true`; alle 105 Fälle sind
  bitgleich, ebenso 469 frisch erzeugte Zufalls- und Stressfälle.
* Neu: `tools/compare_reference.jl` und `test/reftree.jl` vergleichen die
  Erweiterungen, die Engine (Modul `engine`, 249 Fälle zu den Argumenten
  und Ergebniselementen von 0.5.0) und die R-Interna mit den 4.536
  Referenzfällen aus `golden/modules/`. Jeder Fall enthält dafür neben R- und Python-Code
  Julia-Code (Feld `jl`). Verglichen werden Ergebnis (NA ≠ NaN, Vorzeichen
  der Null), Konsolen- und Druckausgabe, Warnungen und Fehlermeldungen;
  alle 4.536 Fälle sind bitgleich.
* `Pkg.test()` umfasst 946 Tests: alle Engine-Fälle, von den Modul-Fällen
  eine Auswahl (alle mit `SIMLEV_FULL_TESTS=1`) sowie Tests für `F80`,
  Engine, Ausgabe und den Auswerter für Bedingungen.

### Bekannte Grenzen

* Bitgleichheit ist unter Linux x86-64 mit glibc geprüft. Die
  libm-Aufrufe der R-Interna sind auf `libm.so.6` (glibc) eingestellt;
  unter macOS und Windows ist die Fassung nicht geprüft.
* evd (2.3-7.1, `fpot`) und rugarch (1.5-6, `ugarchfit` mit Rsolnp 1.16
  `solnp`, `nlminb` und `gosolnp` mit `rtruncnorm` aus truncnorm 1.0-9) sind
  nachgebildet (`SimLev.REvd`, `RRugarch`, `RSolnp`, `RTruncnorm`,
  `RStats.nlminb` mit `RPort`); standardmäßig wie R mit beiden Paketen,
  `ENV["SIMLEV_R_SUGGESTS"] = "none"` wie R ohne sie. gosolnp setzt wie in R
  den Zufallszustand aus der Uhrzeit; `ENV["SIMLEV_R_SYS_TIME"]` stellt die
  Uhr fest. imputeTS 3.4 mit stinepack 1.5 ist nachgebildet (`RImputeTS`,
  `RStinepack`; `fill = "stine"` im Backcast nach Stineman). MSGARCH,
  plotly und TTR gelten als nicht installiert (die
  MS-GARCH-Verfahren melden wie R, dass `MSGARCH` fehlt).
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
interaktivem HTML-Dashboard, bitgleich zum damaligen Stand des R-Pakets
(Commit 54b5b4f).
