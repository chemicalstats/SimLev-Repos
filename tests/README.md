# Testkatalog von SimLev

Alle Tests des Repositorys liegen in diesem Ordner (T20, SimLev 1.4.1). Sie laufen gegen die gebauten bzw.
installierten Pakete unter `r/`, `python/` und `julia/`; die Pakete selbst brauchen `tests/` nicht (Bauen,
Installieren, `R CMD check`, `pip install`, `Pkg.build`/`using` laufen ohne diesen Ordner).

```
tests/
  run.sh        alle Suiten (R, Python, Julia), wahlweise Schnittstelle und Gleichlauf
  faelle/       Referenzfälle aus R, eine Datei je Bereich (<bereich>.jsonl.gz)
  erzeugen/     R-Generatoren je Bereich, ref_tools.R, auswahl.txt und alle.sh (alles neu erzeugen)
  r/            R-Tests (testthat): Handrechnungen, Prüfungen ohne Referenzfall, C-Bibliothek, Grafik
  python/       Python-Tests (pytest): alle Fälle, Schnittstelle, SVG-Grafik
  julia/        Julia-Tests: alle Fälle, Schnittstelle, SVG-Grafik
  gleichlauf/   Gleichlaufprüfung: alle Fälle der Generatoren und Zufallsprüfungen gegen R (nichts abgelegt)
  api/          eingefrorene öffentliche Schnittstelle der drei Sprachen
  bench/        Laufzeitmessung
```

## Befehle

Aus der Repo-Wurzel, mit `LC_ALL=C.UTF-8` (die Referenzen entstanden unter C.UTF-8):

| Was | Befehl | Laufzeit (T20) |
|---|---|---|
| alle drei Suiten | `tests/run.sh` (`--bauen` baut vorher R, Python und Julia) | rund 8 min |
| R | `R_LIBS=<Bibliothek mit SimLev> Rscript tests/r/run.R` | 15 s |
| Python | `python3 -m pytest tests/python` (C-Erweiterung an Ort und Stelle gebaut oder `simlev` installiert) | 47 s |
| Julia | `julia --project=julia tests/julia/runtests.jl` (nach `Pkg.build()`) | 7 min (Übersetzen je Fall) |
| Schnittstelle | `tests/api/run.sh --check` (`--freeze` nur mit Eintrag in `tests/api/CHANGES.md`) | 1 min |
| Gleichlauf | `tests/gleichlauf/run.sh --quick` bzw. `--full` (baut selbst; `--no-build`) | 8 bzw. 40 min |
| Fälle neu erzeugen | `R_LIBS=<…> tests/erzeugen/alle.sh [bereich …]` | 3 min |
| Laufzeitmessung | `R_LIBS=<…> tests/bench/run.sh` | siehe `bench/README.md` |

Voraussetzungen: R mit `testthat` und `jsonlite`; Python mit `pytest`, `numpy`, `pandas`; Julia 1.10 oder neuer
(`Test`, `Logging`, `Zlib_jll` sind Standardbibliotheken). Die Bitgleichheit setzt Linux auf x86-64 voraus.
Umgebung: `SIMLEV_FAELLE_DIR` (anderer Ordner der Bereichsdateien), `SIMLEV_LAX_NA=1` (NA = NaN),
`SIMLEV_STRICT_ZERO=0` (−0 = +0).

## Referenzfälle (`faelle/`)

Ein Fall besteht aus Eingaben, R-, Python- und Julia-Code und dem Ergebnis von R (Zahlen als Hex-Literale, NA und
NaN getrennt, dazu Konsolen- und Druckausgabe, Warnungen und Fehlermeldung). Python und Julia rechnen jeden Fall
nach und müssen Bit für Bit gleich sein. Die **Herkunft der Erwartung ist immer R** (Generatoren in `erzeugen/`,
nie von Hand angepasst). Format einer Bereichsdatei: Zeile 1 der Eingabespeicher, danach je Zeile ein Fall
(Einzelheiten in `erzeugen/ref_tools.R`); im Bereich `engine` stehen zusätzlich Fälle im Engine-Format
(`engine_faelle.R`, `engine_stress.R`: Daten, Strategie, Bausteine und die Ergebnisfelder von `simulation()`).

| Bereich | Was gesichert ist | Fälle (vorher → T20) | Generator |
|---|---|---|---|
| `engine` | `simulation()` mit allen Bausteinen: Kosten, Sparplan, Umschichten, Splits, Steuer (Günstigerprüfung, Tarif, Kirchensteuer, Vorabpauschale, Freibetrag), später startende Assets, `details`, `summary()`, Druck, Warn- und Fehlerpfade; Engine-Format: gezielte Fälle (`f…`, `x…`) und Zufallsfälle (`r…`, `y…`) | 394 → 110 | `engine.R`, `engine_faelle.R`, `engine_stress.R` |
| `wrapper` | Fonds-Wrapper (`wrapper_nav`, Wrapper-Assets in `simulation()`, Aufrufer), Eingabeprüfungen von `asset_config`, `create_strategy`, `strategy_*`, `tax_profile`, `simulation` | 110 → 59 | `wrapper.R` |
| `entnahme` | Entnahmephase: Regeln, Kohorten, Steuer, FIFO-Übernahme | 368 → 138 | `entnahme.R` |
| `daten` | Datenaufbereitung, Portfolio-Vorlagen, Rückrechnung (`backcast`), Signale | 319 → 126 | `daten.R` |
| `bootstrap` | Bootstrap der Pfade und Studien (auch `cores = 2`) | 207 → 97 | `bootstrap.R` |
| `planung` | Planung, Szenarien, taktische Allokation | 257 → 109 | `planung.R` |
| `forschung` | Parametersuche, Overfitting-Diagnosen, Sensitivität | 194 → 78 | `forschung.R` |
| `statistik` | statistische Tests, Tiefenanalyse | 135 → 60 | `statistik.R` |
| `modelle` | MS-GARCH, Regime (HMM), Abhängigkeit (Copulas, DCC, Quantilsregression, CoVaR) | 173 → 61 | `modelle.R` |
| `optimierung` | Portfolio-Optimierung | 180 → 56 | `optimierung.R` |
| `r_grundfunktionen` | nachgebaute R-Interna der Ports: Formatierung, NA/NaN, Statistikfunktionen, Ausdrücke | 1.676 → 388 | `r_grundfunktionen.R` |
| `slc` | C-Bibliothek: Zufall, Verteilungen, lineare Algebra, Optimierer, Modelle | 465 → 82 | `slc.R` |
| **zusammen** | | **4.478 → 1.364** (43 MB in 4.449 Dateien → 6,5 MB in 12 Dateien) | |

**Auswahl (T20):** Die Generatoren erzeugen weiter alle 4.478 Fälle (gleiche Zufallsfolge); abgelegt werden die
1.364 aus `erzeugen/auswahl.txt`. Das ist die mit gierigem Mengenüberdecken gefundene kleine Fallmenge, die in
allen Sprachen dieselben Zeilen erreicht wie alle Fälle zusammen: R (covr) und C/C++ des R-Pakets (gcov), Python
(coverage.py), Julia (`--code-coverage`), je Fall gemessen; dazu die Fälle der Grafiktests und je exportierter
Funktion mindestens ein Fall (115 von 116; `export_dashboard` schreibt eine Datei). 882 der 1.364 Fälle erreichen
mindestens eine Zeile, die kein anderer Fall erreicht. Alle Fälle der Generatoren prüft weiter der Gleichlauf.

## Sprachsuiten

| Suite | Datei | Inhalt | Herkunft der Erwartung |
|---|---|---|---|
| R | `r/test-steuer.R` | Steuerrecht (§§ 20, 23, 32a EStG, InvStG, SolZG), Tarifdatei, Anschaffungskosten aus offenen Lots | Handrechnung / Gesetz |
| | `r/test-engine.R` | Engine-Erweiterungen, Restbefunde, Verlustvortrag, zuflussbereinigte Kennzahlen | Handrechnung |
| | `r/test-entnahme.R` | Entnahme mit Lots der Ansparphase (FIFO), Review 7 Planung/Entnahme | Handrechnung |
| | `r/test-slc.R` | C-Bibliothek gegen Testvektoren, Konstanten, R-Routinen, analytische Lösungen | unabhängige Werte |
| | `r/test-pruefungen.R` | Eingabeprüfungen und Wege, die die Fälle nicht erreichen (u. a. `conditionCall`) | R-Verhalten |
| | `r/test-grafik.R` | R-Grafik (Basisgrafik: Dashboard, plot-Methoden) | R-Verhalten |
| | `r/test-api.R` | Schnittstelle gegen `api/frozen/r.json` | eingefrorener Stand |
| Python | `python/test_faelle.py` | alle Fälle aller Bereiche (je Fall ein Test, `-k <bereich>`) | R-Referenz |
| | `python/test_api.py` | Schnittstelle gegen `api/frozen/py.json` | eingefrorener Stand |
| | `python/test_grafik.py` | SVG-Grafik und `SimLevPlot.data` (gibt es in R nicht) | Werte aus den Objekten |
| Julia | `julia/runtests.jl` | dieselben drei Teile (`faelle.jl`, `api.jl`, `grafik.jl`) | wie Python |

## Gleichlauf (`gleichlauf/`)

`run.sh` erzeugt mit dem aktuellen R **alle** Fälle der Generatoren neu (`SIMLEV_GEN_ALLE=1`; `--quick` jede 20.
Kennung) und vergleicht Python und Julia dagegen (`vergleich.py`, `vergleich.jl`). Mit `--full` prüft
`faelle_diff.py`, dass die neu erzeugten Katalogdateien Byte für Byte `faelle/` entsprechen. Die
Zufallsprüfungen (`date_fuzz`, `rbase_fuzz`, `tariff_fuzz`, `sim_fuzz`, `sched_fuzz`, `metric_fuzz`) laufen nur hier
und legen keine Fälle ab; `sim_fuzz`, `sched_fuzz` und `metric_fuzz` vergleichen gegen R 1.3.0
(`SIMLEV_FUZZ_REFLIB`). `exporte.py` zählt die Exporte ohne Fall im Katalog.

## Neu erzeugen

Ändert sich ein Ergebnis von R gewollt: `tests/erzeugen/alle.sh` (oder nur die betroffenen Bereiche), dann
`git diff --stat tests/faelle` und die Suiten; Ursache in `r/NEWS.md`. Neue Fälle: im Generator des Bereichs mit
`ref_case()` anlegen und die Kennung `<modul>/<id>` in `erzeugen/auswahl.txt` eintragen.

## Lokal aufbewahren

Die Tests sollen später nicht mehr im Repository liegen, sondern nur lokal. Dafür genügt:

1. `tests/` an einen lokalen Ort kopieren (oder im Arbeitsbaum lassen),
2. `git rm -r --cached tests` bzw. den Ordner löschen und `tests/` in `.gitignore` eintragen.

Außerhalb von `tests/` verweisen nur das Haupt-README und `python/DEVELOPING.md`, `julia/DEVELOPING.md` auf
diesen Ordner; Pakete, Bau und `R CMD check` brauchen ihn nicht (T20 geprüft mit einer Kopie ohne `tests/`). Die
Suiten finden die Pakete über die Repo-Wurzel (`tests/` muss dafür neben `r/`, `python/`, `julia/` liegen) bzw. über
`R_LIBS` und das installierte `simlev`.
