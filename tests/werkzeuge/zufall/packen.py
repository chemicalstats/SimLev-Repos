#!/usr/bin/env python3
"""Zufallsfälle der Engine (Engine-Format) zu einer Datei für den Gleichlauf packen (nichts wird abgelegt).

Aufruf: python3 -I tests/werkzeuge/zufall/packen.py <arbeitsordner> <ziel.jsonl.gz>
Liest <arbeitsordner>/cases/*.json (engine_faelle.R) und <arbeitsordner>/stress/*.json (engine_stress.R) und schreibt
sie wie eine Bereichsdatei (Zeile 1 Kopf ohne Eingabespeicher, dann je Zeile ein Fall); tests/werkzeuge/gleichlauf/
vergleich.{py,jl} rechnen sie in Python und Julia nach (Engine-Format, run_engine). Seit 1.6.3 Fall für Fall (bis 1.6.2
alle Zeilen zugleich im Speicher) und mit gzip-Stufe 1 (eine Arbeitsdatei; bis 1.6.2 Stufe 9, gleicher Inhalt).
"""
import gzip
import os
import sys


def main(src, ziel):
    dateien = []
    for d in ("cases", "stress"):
        p = os.path.join(src, d)
        dateien += [os.path.join(p, f) for f in (sorted(os.listdir(p)) if os.path.isdir(p) else []) if f.endswith(".json")]
    with gzip.open(ziel, "wt", encoding="utf-8", compresslevel=1) as fh:
        fh.write('{"format":3,"bereich":"zufall_engine","faelle":%d,"inputs":{}}\n' % len(dateien))
        for f in dateien:
            with open(f, encoding="utf-8") as h:
                fh.write(h.read().strip() + "\n")
    print("zufall_engine: %d Fälle -> %s" % (len(dateien), ziel))
    return 0 if dateien else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
