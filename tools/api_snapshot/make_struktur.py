#!/usr/bin/env python3
"""Erzeugt docs/STRUKTUR.md (Zuordnungstabelle R / Python / Julia) aus api.json.

Aufruf aus der Repo-Wurzel (nach compare_api.py)::

    python3 tools/api_snapshot/make_struktur.py [--api tools/api_snapshot/api.json] [--out docs/STRUKTUR.md]

Nur Standardbibliothek. Die Datei wird vollständig neu geschrieben; Änderungen
von Hand gehen verloren (Kopf und Schichten stehen hier im Skript).
"""
from __future__ import annotations

import argparse
import json
import os

# Schichten (zentrales Entwicklungsdokument, Anhang F)
SCHICHTEN = [
    ("0", "R-Interna, eingebaute Pakete", "(R selbst), `vendor_*`", "`simlev/_r/`", "`src/r/`"),
    ("1", "Daten und Strategie", "`data_prep.R`, `strategy.R` …", "`data_prep.py`, `config.py`", "`data_prep.jl`, `config.jl`"),
    ("2", "Engine", "`simulation.R`, `sim_*.R`, Kerne", "`engine.py`, `_sim_*.py`, `_core.py`, `result.py`", "`engine.jl`, `sim_*.jl`"),
    ("3", "Analysen", "je eine `.R`", "je ein Modul", "je eine Datei"),
    ("4", "Ausgabe", "`print`-Methoden, `plot_dashboard.R`", "`svg.py`, `dashboard.py`", "`svg.jl`, `dashboard.jl`"),
]

PREFIX = {"R": "r/R/", "Python": "python/simlev/", "Julia": "julia/src/"}


def short(path, lang):
    if not path:
        return ""
    p = PREFIX[lang]
    return path[len(p):] if path.startswith(p) else path


def cell_name(e, lang):
    if e is None:
        return "–"
    return "`%s`" % e["name"]


def cell_file(e, lang):
    if e is None or not e.get("file"):
        return "–"
    return "`%s`" % short(e["file"], lang)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(os.path.dirname(here))
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", default=os.path.join(here, "api.json"))
    ap.add_argument("--out", default=os.path.join(root, "docs", "STRUKTUR.md"))
    a = ap.parse_args()
    with open(a.api, encoding="utf-8") as fh:
        api = json.load(fh)

    funcs = [f for f in api["functions"] if f["kind"] == "function"]
    meths = [f for f in api["functions"] if f["kind"] == "method"]

    def sort_key(f):
        r = f.get("R") or {}
        return (0 if r else 1, short(r.get("file") or "", "R"), f["key"])

    c = api["counts"]
    L = []
    L.append("# Struktur: Zuordnung R / Python / Julia\n")
    L.append("Diese Datei ist erzeugt; nicht von Hand ändern.\n")
    L.append("- **Erzeugt** mit `tools/api_snapshot/run.sh` (Auszüge `api_r.R`, `api_py.py`, `api_jl.jl`, "
             "Vergleich `compare_api.py`, diese Datei `make_struktur.py`) aus `tools/api_snapshot/api.json`.")
    L.append("- **Stand:** %s." % api["generated"])
    L.append("- **Umfang:** R %d Exporte und %d S3-Methoden, Python %d Funktionen und %d Methoden, "
             "Julia %d Funktionen und %d Methoden." % (c["R"]["functions"], c["R"]["methods"],
                                                      c["Python"]["functions"], c["Python"]["methods"],
                                                      c["Julia"]["functions"], c["Julia"]["methods"]))
    L.append("- **Zuordnung:** R `a.b` → `a_b`; S3-Methode `<generic>.<Klasse>` → Python `<Klasse>.<generic>` "
             "(print über `.print` bzw. `.format`), Julia registrierte Methode (`show`, `r_summary`, `r_plot`). "
             "Regeln: `python/DEVELOPING.md`, `julia/DEVELOPING.md`.")
    L.append("- **Abweichungen** der Argumente und Standardwerte meldet `compare_api.py`; bekannte stehen in "
             "`tools/api_snapshot/known_differences.tsv`.")
    L.append("- Dateien relativ zu `r/R/`, `python/simlev/` bzw. `julia/src/`.\n")

    L.append("## Schichten\n")
    L.append("| Schicht | Inhalt | R | Python | Julia |")
    L.append("|---|---|---|---|---|")
    for s in SCHICHTEN:
        L.append("| %s |" % " | ".join(s))
    L.append("")

    def table(rows, title):
        L.append("## %s (%d)\n" % (title, len(rows)))
        L.append("| Name R | Datei R | Name Python | Datei Python | Name Julia | Datei Julia |")
        L.append("|---|---|---|---|---|---|")
        for f in sorted(rows, key=sort_key):
            L.append("| %s | %s | %s | %s | %s | %s |" % (
                cell_name(f.get("R"), "R"), cell_file(f.get("R"), "R"),
                cell_name(f.get("Python"), "Python"), cell_file(f.get("Python"), "Python"),
                cell_name(f.get("Julia"), "Julia"), cell_file(f.get("Julia"), "Julia")))
        L.append("")

    table([f for f in funcs if f.get("R")], "Öffentliche Funktionen (R-Exporte)")
    table(meths, "S3-Methoden")
    table([f for f in funcs if not f.get("R")], "Nur in den Ports")

    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L))
    print("STRUKTUR.md: %d Funktionen, %d Methoden -> %s" % (len(funcs), len(meths), os.path.relpath(a.out)))


if __name__ == "__main__":
    main()
