# Messbasis (`tools/bench/`)

Wiederholbare Laufzeitmessung in R, Python und Julia: Nachweis, dass Umbauten nicht langsamer
machen, und Vorher-Werte für den C++-Pilot (Etappe 7).

``` bash
R_LIBS=<Bibliothek mit installiertem SimLev> tools/bench/run.sh          # alle Aufgaben außer P1
R_LIBS=<…> tools/bench/run.sh P1                                          # cores = 1 gegen 2 (Julia mit 2 Threads)
R_LIBS=<…> tools/bench/run.sh T1,T8                                       # Auswahl
R_LIBS=<…> tools/bench/run.sh --ohne-c T8                                 # dazu Python ohne C-Erweiterung (auch mit P1)
python3 tools/bench/merge.py --md --alt tools/bench/anhang_e_2026-10-20.csv tools/bench/out/*.csv
```

`run.sh` misst die drei Sprachen **nacheinander** (nichts anderes nebenher laufen lassen), mit
`LC_ALL=C.UTF-8` und einem Kern (`OMP_NUM_THREADS=1`, `OPENBLAS_NUM_THREADS=1`,
`JULIA_NUM_THREADS=1`, `cores = 1`), und schreibt `out/{r,python,julia}.csv` sowie
`ergebnis_<JJJJ-MM-TT>.csv`. Eine vorhandene Ergebnisdatei wird nie überschrieben: Der nächste Lauf
am selben Tag schreibt `ergebnis_<JJJJ-MM-TT>_2.csv`, dann `_3`, … (bei `P1`
`ergebnis_<JJJJ-MM-TT>_parallel_2.csv`). `out/` ist ein Zwischenordner mit den Einzelauszügen des
letzten Laufs; jeder Lauf überschreibt ihn (alle Zeilen stehen auch in der Ergebnisdatei). Die Skripte einzeln: `Rscript tools/bench/bench.R [csv] [aufgaben]`,
`python3 tools/bench/bench.py …`, `julia --project=julia tools/bench/bench.jl …` (aus der Repo-Wurzel).

**Python mit und ohne C-Erweiterung (Etappe 7.2, seit 7.3a alle gemeinsamen Kerne):** `bench.py`
misst mit der C-Erweiterung `simlev._ext`, wenn sie gebaut ist (Sprache `Python`), sonst bzw. mit
`SIMLEV_NO_EXT=1` die reinen Python-Kerne (Sprache `Python ohne C`); die erste Ausgabezeile nennt
den Zustand.
`run.sh --ohne-c …` misst Python zusätzlich ohne Erweiterung (`out/python_ohne_c*.csv`).

**Messweise:** je Aufgabe 1 Aufwärmlauf (`erster_lauf_s`; in Julia mit Kompilierung), dann
3 Läufe; Spalten `aufgabe, sprache, median_s, min_s, max_s, erster_lauf_s`. Julia vorher einmal
vollständig vorkompilieren (ohne `SIMLEV_SKIP_PRECOMPILE`), sonst enthält der erste Lauf die
ganze Kompilierung.

**Daten:** in den Skripten mit festem Seed erzeugt; Python und Julia nutzen den R-Zufallsgenerator
der Ports und erhalten dieselben Zahlen wie R (die Zeile `Daten:` zeigt Prüfsummen, die in allen
drei Sprachen gleich sein müssen).

| Aufgabe | Inhalt |
|---|---|
| `Laden` | `library(SimLev)` / `import simlev` / `using SimLev` im laufenden Prozess (einmal gemessen) |
| `S30` | `simulation` 30 Jahre täglich, 2 Assets, Steuer `person`, Sparplan 200 monatlich, Rebalancing vierteljährlich |
| `T1` | `bootstrap` stationär, 200 Pfade × 10 Jahre (2.520 Tage) |
| `T2` | `bootstrap` GARCH (rugarch-Weg), 50 Pfade × 10 Jahre |
| `T3` | `bootstrap_study` stationär, 50 Pfade × 10 Jahre, eine Strategie (Simulation je Pfad) |
| `T4` | `withdrawal_simulation`, konstante Entnahme 4 %, 2.000 Pfade × 30 Jahre |
| `T5` | `dependence_analysis`, 4 Assets mit DCC, ohne Copulas |
| `T6` | `portfolio_optimize` `min_cvar`, 4 Assets |
| `T7` | `portfolio_optimize` `hrp`, 4 Assets |
| `T8` | MS-GARCH-Schätzung `.ms_garch_fit` / `_ms_garch_fit`, 2 Regime gjrGARCH, n = 2.000 (Daten wie `golden/modules/gen_ms_garch.R`, `gjr2`) |
| `T3c2` | wie `T3`, aber `cores = 2` (Fork); nur R und nur auf Anforderung (`bench.R <csv> T3,T3c2`) |
| `P1c1`, `P1c2` | `bootstrap` stationär, 400 Pfade × 10 Jahre, `cores = 1` bzw. `2` (R/Python: Fork, Julia: Threads); nur mit `run.sh P1`, Ergebnis `ergebnis_<JJJJ-MM-TT>_parallel.csv` |

Daten von T1–T7: 4 Kursreihen über 20 Jahre täglich (Seed 7) und 30 × 2.000 Wachstumsfaktoren;
`S30`: Seed 1. `anhang_e_2026-10-20.csv` enthält die alten Werte (Anhang E des
Entwicklungsdokuments) zum Vergleich; `merge.py` stellt sie daneben.
`ergebnis_2026-10-26_rpar.csv`: R vor und nach dem Bündeln der Einheiten in `.par_lapply`
(Spalte `stand`; P1c1, P1c2, T3, T3c2).
