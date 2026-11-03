# Schnittstellen-Abgleich (`tests/schnittstelle/`)

Zeigt mit einem Befehl, ob R, Python und Julia dieselbe öffentliche Schnittstelle haben
(Funktionsnamen, Argumentnamen, Reihenfolge, Standardwerte). Seit 0.9.0 dient es als Test.

``` bash
tests/schnittstelle/run.sh            # aus beliebigem Ordner; Bericht auf der Konsole
tests/schnittstelle/run.sh --check    # Rückgabewert 1, wenn nicht erklärte Abweichungen bleiben
                                     # oder eine Sprache vom eingefrorenen Stand (frozen/) abweicht
tests/schnittstelle/run.sh --freeze   # frozen/ neu festschreiben; nur mit neuem Eintrag in CHANGES.md
tests/schnittstelle/run.sh -v --md /tmp/abweichungen.md   # auch bewusste zeigen, Liste als Markdown
```

Braucht `Rscript` (mit jsonlite), `python3` und `julia` (Projekt `julia/`); sonst nur die
Standardbibliotheken. `run.sh` setzt `LC_ALL=C.UTF-8`.

| Datei | Zweck |
|---|---|
| `api_r.R` | R-Auszug aus `r/NAMESPACE` und den Quellen `r/R/*.R` (geparst, nicht ausgeführt) |
| `api_py.py` | Python-Auszug: `simlev.__all__` und die Methoden `print`/`summary`/`plot` der Klassen mit `r_class` |
| `api_jl.jl` | Julia-Auszug: `names(SimLev)` und die registrierten `show`/`r_summary`/`r_plot`-Methoden; Standardwerte aus dem Quelltext |
| `compare_api.py` | Zuordnung, Vergleich, Bericht; schreibt `api.json` (Tabelle der Gleichsetzungen im Kopf des Skripts) |
| `known_differences.tsv` | bekannte Abweichungen mit Begründung (`bewusst`) bzw. ohne (`unklar`, wird gemeldet) |
| `make_struktur.py` | erzeugt `STRUKTUR.md` (Repo-Wurzel) aus `api.json` |
| `api.json` | zusammengeführter Stand (wird von `run.sh` neu geschrieben) |
| `frozen/r.json`, `frozen/py.json`, `frozen/jl.json` | eingefrorene Schnittstelle je Sprache (nur `run.sh --freeze` schreibt sie) |
| `CHANGES.md` | ein Eintrag je Festschreibung von `frozen/` (Datum, was, warum) |
| `out/` | Einzelauszüge je Sprache (nicht eingecheckt) |

Neue bewusste Abweichung: Zeile in `known_differences.tsv` mit Begründung aus Doku oder Code
und Fundstelle; ohne Beleg `unklar`.

## Eingefrorene Schnittstelle (`frozen/`)

Die Schnittstelle 0.5.0 ist je Sprache festgehalten; die Tests jeder Sprache
prüfen dagegen und brauchen nur die eigene Sprache:

| Sprache | Datei | Test | Auszug |
|---|---|---|---|
| R | `frozen/r.json` | `r/tests/testthat/test-api-frozen.R` | `Rscript api_r.R … --frozen-check frozen/r.json` (eigener Prozess); bei `R CMD check` übersprungen, wenn das Repo nicht erreichbar ist |
| Python | `frozen/py.json` | `tests/schnittstelle/test_api.py` | `python3 api_py.py … --frozen-check frozen/py.json` (eigener Prozess) |
| Julia | `frozen/jl.json` | `tests/schnittstelle/api.jl` (in `runtests.jl`) | `api_jl.jl` per `include` in ein eigenes Modul, `frozen_check(…)` im Testprozess |

**Inhalt.** Je Funktion (`functions`) und je Methode (`methods`,
Schlüssel `<generic>.<Klasse>`) die Argumente in Reihenfolge, ein Argument je
Zeile: `name`, `kind` (Art wie im Auszug: R `arg`/`dots`; Python
`positional_or_keyword`, `keyword_only`, `var_positional`, `var_keyword`;
Julia `positional`, `keyword`, `varargs`, `kwargs_rest`), `default` (Text wie
im Auszug, `null` = kein Standardwert), wo vorhanden `value` (ausgewerteter
Standardwert, z. B. R `names(.wd_rules)`; in Julia nur Werte, die sich als
Literal schreiben lassen), `match_arg` und `default_known: false`
(Platzhalter wie `_MISSING`/`_UNSET` bzw. nicht ermittelbar). Dazu die Namen
der exportierten Klassen bzw. Typen (`classes`) und sonstigen Exporte
(`other`). Nicht enthalten sind Datei, Zeile, Modul, Datum, Vermerke und die
Julia-Nebenmethoden (`variants`); Verschiebungen im Code ändern den Stand
also nicht. Schlüssel sind sortiert, das Format ist in allen drei Sprachen
gleich. `stand` nennt den Eintrag in `CHANGES.md`.

**Meldung.** Bei Abweichung listet der Test jede Änderung (`Funktion neu/weg`,
`Methode neu/weg`, `Argument neu/weg`, `Argumente umsortiert`, `Art von x
geändert`, `Standardwert von x geändert`, `Klasse neu/weg`) und den Weg zum
Neu-Festschreiben. Von Hand: `Rscript tests/schnittstelle/api_r.R
/tmp/a.json --frozen-check tests/schnittstelle/frozen/r.json` (entsprechend
`api_py.py`, `julia --project=julia tests/schnittstelle/api_jl.jl`).

**Neu festschreiben** (eine gewollte Änderung, z. B. ein neues Argument):

1. Eintrag oben in `CHANGES.md` (unter der Vorlage):

   ```
   ## JJJJ-MM-TT – Titel
   - Was: welche Funktionen, Argumente oder Standardwerte sich ändern
   - Warum: Grund (Version, Entscheidung, Fehler)
   ```

2. `tests/schnittstelle/run.sh --freeze` schreibt `frozen/r.json`,
   `frozen/py.json` und `frozen/jl.json` neu (mit der Überschrift als
   `stand`) und zeigt die Unterschiede als Diff. Das Skript bricht ab und
   lässt `frozen/` unverändert, wenn `CHANGES.md` fehlt, der oberste Eintrag
   nicht diese Form hat (Datum, `- Was:`, `- Warum:`) oder schon als `stand`
   in `frozen/` steht (kein neuer Eintrag).
3. `frozen/` und `CHANGES.md` zusammen einchecken.

`run.sh --check` meldet außerdem einen `stand` in `frozen/`, der nicht als
Überschrift in `CHANGES.md` steht (von Hand geänderte Dateien).

