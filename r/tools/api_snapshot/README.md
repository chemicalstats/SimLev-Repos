# Schnittstellen-Abgleich (`tools/api_snapshot/`)

Zeigt mit einem Befehl, ob R, Python und Julia dieselbe öffentliche Schnittstelle haben
(Funktionsnamen, Argumentnamen, Reihenfolge, Standardwerte). Ab Etappe 6.6 dient es als Test.

``` bash
tools/api_snapshot/run.sh            # aus beliebigem Ordner; Bericht auf der Konsole
tools/api_snapshot/run.sh --check    # Rückgabewert 1, wenn nicht erklärte Abweichungen bleiben
tools/api_snapshot/run.sh -v --md /tmp/abweichungen.md   # auch bewusste zeigen, Liste als Markdown
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
| `make_struktur.py` | erzeugt `docs/STRUKTUR.md` aus `api.json` |
| `api.json` | zusammengeführter Stand (wird von `run.sh` neu geschrieben) |
| `out/` | Einzelauszüge je Sprache (nicht eingecheckt) |

Neue bewusste Abweichung: Zeile in `known_differences.tsv` mit Begründung aus Doku oder Code
und Fundstelle; ohne Beleg `unklar`.
