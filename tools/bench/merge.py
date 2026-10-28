#!/usr/bin/env python3
"""Führt die CSV von bench.R, bench.py und bench.jl zu einer Tabelle zusammen.

Aufruf aus der Repo-Wurzel::

    python3 tools/bench/merge.py [--out tools/bench/ergebnis_<datum>.csv]
        [--alt tools/bench/anhang_e_2026-10-20.csv] [--md] r.csv python.csv julia.csv

Schreibt die Zeilen aller drei Dateien (Spalten aufgabe, sprache, median_s,
min_s, max_s, erster_lauf_s) in eine CSV und druckt eine Übersicht
Aufgabe × Sprache (Median; Julia zusätzlich erster Lauf), mit ``--alt`` auch
die alten Werte daneben. ``--md`` druckt die Übersicht als Markdown-Tabelle.
Nur Standardbibliothek.
"""
import argparse
import csv
import os

ORDER = ["Laden", "S30", "T1", "T2", "T3", "T4", "T5", "T6", "T7", "T8", "P1c1", "P1c2"]
LANGS = ["R", "Python", "Julia"]
COLS = ["aufgabe", "sprache", "median_s", "min_s", "max_s", "erster_lauf_s"]


def read(path):
    with open(path, newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def fmt(v):
    if v in (None, ""):
        return "–"
    x = float(v)
    return ("%.3f" % x) if x >= 0.01 else ("%.4f" % x)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("inputs", nargs="*", default=[os.path.join(here, "out", f) for f in ("r.csv", "python.csv", "julia.csv")])
    ap.add_argument("--out", default=None)
    ap.add_argument("--alt", default=None)
    ap.add_argument("--md", action="store_true")
    a = ap.parse_args()
    rows = []
    for p in a.inputs:
        rows += read(p)
    rows.sort(key=lambda r: (ORDER.index(r["aufgabe"]) if r["aufgabe"] in ORDER else 99, LANGS.index(r["sprache"])))
    if a.out:
        with open(a.out, "w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh, lineterminator="\n")
            w.writerow(COLS)
            for r in rows:
                w.writerow([r[c] for c in COLS])
    new = {(r["aufgabe"], r["sprache"]): r for r in rows}
    old = {}
    if a.alt:
        old = {(r["aufgabe"], r["sprache"]): r for r in read(a.alt)}
    tasks = [t for t in ORDER if any((t, l) in new for l in LANGS)]
    hdr = ["Aufgabe"] + ["%s neu" % l for l in LANGS] + ["Julia erster Lauf"]
    if old:
        hdr += ["%s alt" % l for l in LANGS] + ["Julia erster alt"]
    table = []
    for t in tasks:
        line = [t] + [fmt(new.get((t, l), {}).get("median_s")) for l in LANGS]
        line.append(fmt(new.get((t, "Julia"), {}).get("erster_lauf_s")))
        if old:
            line += [fmt(old.get((t, l), {}).get("median_s")) for l in LANGS]
            line.append(fmt(old.get((t, "Julia"), {}).get("erster_lauf_s")))
        table.append(line)
    if a.md:
        print("| " + " | ".join(hdr) + " |")
        print("|" + "---|" * len(hdr))
        for line in table:
            print("| " + " | ".join(line) + " |")
    else:
        wd = [max(len(h), *(len(l[i]) for l in table)) for i, h in enumerate(hdr)]
        print("  ".join(h.ljust(wd[i]) for i, h in enumerate(hdr)))
        for line in table:
            print("  ".join(v.ljust(wd[i]) for i, v in enumerate(line)))
    if a.out:
        print("->", os.path.relpath(a.out))


if __name__ == "__main__":
    main()
