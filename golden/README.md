# Golden-Master-Fälle

Dieser Ordner enthält die gemeinsamen Referenzfälle, an denen die Python-
und die Julia-Fassung ihre Bitgleichheit zum R-Paket prüfen. Jeder Fall ist
eine gzip-komprimierte JSON-Datei mit den Eingabedaten, der Strategie, den
Argumenten von `simulation()` und den exakten Ergebnissen aus R
(Gleitkommazahlen als Hex-Literale, `NA` und `NaN` getrennt).

| Ordner | Fälle | Geprüft von | Inhalt |
|---|---|---|---|
| `cases/` | 68 | Python, Julia | 38 gezielte Fälle für jeden Steuer- und Sonderpfad (`f01`–`f38`) und 30 Zufallsfälle (`r…`) |
| `extra/` | 37 | Julia | Stressfälle: 30 Jahre, Totalverlust-Hebel, mehrere Signal-Assets, konstante Preise, Kalender-Randfälle, Extremwerte, Fehlerpfade (`x…`, `y…`) |

`extra/x24_dup_dates.json.gz` ist eine bewusste Abweichung: R rechnet mit
doppelten Datumswerten stillschweigend weiter, Julia bricht mit einer
Fehlermeldung ab.

## Neue Fälle erzeugen

Benötigt werden R, das R-Paket SimLev (aus `../r`) und `jsonlite`.

``` bash
# Zielordner, Anzahl Zufallsfälle, Startwert
LC_ALL=C.UTF-8 Rscript golden/golden_cases.R /tmp/golden 500 4711
LC_ALL=C.UTF-8 Rscript golden/stress_cases.R /tmp/stress 1000 90210
```

Die Generatoren schreiben unkomprimierte `.json`-Dateien. Für die Ablage in
`cases/` oder `extra/` komprimieren Sie sie mit `gzip -9`; die Testsuiten
lesen nur `.json.gz`.

Abgleich mit den Ports:

``` bash
python python/tools/compare_golden.py /tmp/golden
julia --project=julia julia/tools/compare_golden.jl /tmp/golden
```

Wer die Rechenlogik des R-Pakets ändert, erzeugt die Fälle in `cases/` und
`extra/` neu und zieht beide Ports nach, bis alle Fälle wieder bitgleich
sind. Die CI prüft bei jeder Änderung in diesem Ordner Python und Julia.
