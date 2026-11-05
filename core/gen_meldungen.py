#!/usr/bin/env python3
"""core/gen_meldungen.py – Meldungstabellen der Kerne aus einer Quelle (seit 1.6.0).

Liest ``core/meldungen.tsv`` (Code->Text-Tabellen der Tagesengine und der Auswertung: Spalten
``tabelle``, ``schluessel``, ``text``; Vorlagen im Format von ``sprintf``, Fluchtfolgen ``\\t``,
``\\n``, ``\\\\``) und schreibt dieselben Tabellen für die drei Sprachen:

    r/R/meldungen.R               .MELD_<TABELLE> <- c("<schluessel>" = "<text>", ...)
    python/simlev/_meldungen.py   <TABELLE> = {"<schluessel>": "<text>", ...}
    julia/src/meldungen.jl        const _MELD_<TABELLE> = Dict{String,String}("<schluessel>" => "<text>", ...)

Die Texte sind in allen drei Dateien zeichengleich (R mit ``\\uXXXX`` für Nicht-ASCII wie die übrigen
R-Quellen, Python mit ``\\uXXXX``, Julia UTF-8 mit ``\\$``). Die Logik (welcher Text, welche
Argumente) bleibt je Sprache in ``.sim_engine_signal``/``.sim_engine_detail``,
``.sim_eval_detail``/``.sim_eval_warn`` und ihren Gegenstücken.

Aufruf::

    python3 core/gen_meldungen.py            # schreibt die drei Dateien
    python3 core/gen_meldungen.py --check    # Ende 1, wenn eine Datei abweicht (core/sync.py --check)

Nur Standardbibliothek.
"""
from __future__ import annotations

import argparse
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SRC = os.path.join(ROOT, "core", "meldungen.tsv")
OUT_R = os.path.join(ROOT, "r", "R", "meldungen.R")
OUT_PY = os.path.join(ROOT, "python", "simlev", "_meldungen.py")
OUT_JL = os.path.join(ROOT, "julia", "src", "meldungen.jl")
KOPF = "erzeugt von core/gen_meldungen.py aus core/meldungen.tsv – nicht von Hand ändern"


def lies() -> dict[str, list[tuple[str, str]]]:
    """Tabellen in der Reihenfolge der Datei; Schlüssel je Tabelle eindeutig."""
    tab: dict[str, list[tuple[str, str]]] = {}
    with open(SRC, encoding="utf-8") as fh:
        zeilen = fh.read().split("\n")
    kopf = False
    for nr, z in enumerate(zeilen, 1):
        if not z or z.startswith("#"):
            continue
        if not kopf:
            if z != "tabelle\tschluessel\ttext":
                raise SystemExit("gen_meldungen: Zeile %d: Kopfzeile tabelle/schluessel/text erwartet" % nr)
            kopf = True
            continue
        teile = z.split("\t")
        if len(teile) != 3:
            raise SystemExit("gen_meldungen: Zeile %d: drei Spalten erwartet" % nr)
        t, k, roh = teile
        text, i = [], 0
        while i < len(roh):
            c = roh[i]
            if c == "\\":
                n = roh[i + 1] if i + 1 < len(roh) else ""
                if n not in ("t", "n", "\\"):
                    raise SystemExit("gen_meldungen: Zeile %d: unbekannte Fluchtfolge \\%s" % (nr, n))
                text.append({"t": "\t", "n": "\n", "\\": "\\"}[n])
                i += 2
            else:
                text.append(c)
                i += 1
        liste = tab.setdefault(t, [])
        if any(k == a for a, _ in liste):
            raise SystemExit("gen_meldungen: Zeile %d: Schlüssel %s/%s doppelt" % (nr, t, k))
        liste.append((k, "".join(text)))
    return tab


def lit_r(s: str) -> str:
    out = []
    for c in s:
        if c == "\\":
            out.append("\\\\")
        elif c == '"':
            out.append('\\"')
        elif c == "\t":
            out.append("\\t")
        elif c == "\n":
            out.append("\\n")
        elif ord(c) < 32:
            raise SystemExit("gen_meldungen: Steuerzeichen %r" % c)
        elif ord(c) < 128:
            out.append(c)
        elif ord(c) <= 0xFFFF:
            out.append("\\u%04x" % ord(c))
        else:
            out.append("\\U%08x" % ord(c))
    return '"' + "".join(out) + '"'


def lit_py(s: str) -> str:
    out = []
    for c in s:
        if c == "\\":
            out.append("\\\\")
        elif c == '"':
            out.append('\\"')
        elif c == "\t":
            out.append("\\t")
        elif c == "\n":
            out.append("\\n")
        elif ord(c) < 128:
            out.append(c)
        elif ord(c) <= 0xFFFF:
            out.append("\\u%04x" % ord(c))
        else:
            out.append("\\U%08x" % ord(c))
    return '"' + "".join(out) + '"'


def lit_jl(s: str) -> str:
    out = []
    for c in s:
        if c == "\\":
            out.append("\\\\")
        elif c == '"':
            out.append('\\"')
        elif c == "$":
            out.append("\\$")
        elif c == "\t":
            out.append("\\t")
        elif c == "\n":
            out.append("\\n")
        else:
            out.append(c)
    return '"' + "".join(out) + '"'


def name(t: str) -> str:
    return t.upper()


def text_r(tab) -> str:
    z = ["# r/R/meldungen.R -- Meldungstabellen der Kerne (seit 1.6.0); "
         + KOPF.replace("ä", "ae").replace("–", "--") + " (nur ASCII).",
         "# Nutzung: .sim_engine_signal/.sim_engine_detail (R/sim_engine.R), .sim_eval_detail/.sim_eval_warn",
         "# (R/sim_evaluate.R); Gegenstuecke python/simlev/_meldungen.py, julia/src/meldungen.jl.", ""]
    for t, liste in tab.items():
        z.append(".MELD_%s <- c(" % name(t))
        z += ["  %s = %s%s" % (lit_r(k), lit_r(v), "," if j + 1 < len(liste) else "")
              for j, (k, v) in enumerate(liste)]
        z += [")", ""]
    return "\n".join(z)


def text_py(tab) -> str:
    z = ['"""Meldungstabellen der Kerne (seit 1.6.0); %s.' % KOPF, "",
         "Nutzung: ``_sim_engine`` (Tagesengine), ``_sim_evaluate`` und ``_sim_base`` (Auswertung); Gegenstücke",
         "``r/R/meldungen.R`` und ``julia/src/meldungen.jl``.", '"""', ""]
    for t, liste in tab.items():
        z.append("%s = {" % name(t))
        z += ["    %s: %s," % (lit_py(k), lit_py(v)) for k, v in liste]
        z += ["}", ""]
    return "\n".join(z)


def text_jl(tab) -> str:
    z = ["# julia/src/meldungen.jl – Meldungstabellen der Kerne (seit 1.6.0); " + KOPF + ".",
         "# Nutzung: sim_engine.jl (Tagesengine), sim_evaluate.jl und engine.jl (Auswertung); Gegenstücke",
         "# r/R/meldungen.R und python/simlev/_meldungen.py.", ""]
    for t, liste in tab.items():
        z.append("const _MELD_%s = Dict{String,String}(" % name(t))
        z += ["    %s => %s," % (lit_jl(k), lit_jl(v)) for k, v in liste]
        z += [")", ""]
    return "\n".join(z)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args(argv)
    tab = lies()
    bad = 0
    for pfad, text in ((OUT_R, text_r(tab)), (OUT_PY, text_py(tab)), (OUT_JL, text_jl(tab))):
        rel = os.path.relpath(pfad, ROOT)
        alt = open(pfad, encoding="utf-8").read() if os.path.isfile(pfad) else None
        if alt == text:
            continue
        if a.check:
            print("gen_meldungen: %s %s" % (rel, "weicht ab" if alt is not None else "fehlt"))
            bad += 1
        else:
            with open(pfad, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(text)
            print("gen_meldungen: %s geschrieben" % rel)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
