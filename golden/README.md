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

Stand R 0.5.0 (aktuelle Fassung): Alle 105 Fälle sind nach den
Engine-Korrekturen, steuerrechtlichen Anpassungen und der Übersetzung der
Ausgaben ins Deutsche neu erzeugt (Begründung in `r/NEWS.md`), zuletzt 101
davon wegen der deutschen Druckausgabe, 19 davon zusätzlich mit geänderten
Zahlen (keine Doppelorders am ersten Tag). Python und Julia entsprechen
noch dem früheren Stand des R-Pakets vor den Korrekturen (Commit 54b5b4f,
damals ebenfalls als 0.5.0 bezeichnet); Python trifft keinen der 68 Fälle
in `cases/` vollständig, nur in `f18` und `f19` sind alle Zahlenfelder noch
bitgleich. Die neuen
R-Ergebnisfelder `tax_report$open_tax_debt` und `tax_report$tariff_years`
gehören bewusst nicht zum Golden-Format.
`extra/x24_dup_dates.json.gz` erwartet jetzt auch in R einen Fehler
(doppelte Datumswerte), wie bisher schon in Julia.

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
sind. Prüfen Sie nach jeder Änderung in diesem Ordner Python und Julia mit
den Werkzeugen oben bzw. den Testsuiten.
