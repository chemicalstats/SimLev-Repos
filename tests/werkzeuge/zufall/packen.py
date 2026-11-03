#!/usr/bin/env python3
"""Zufallsfälle der Engine (Engine-Format) zu einer Datei für den Gleichlauf packen (nichts wird abgelegt).

Aufruf: python3 -I tests/werkzeuge/zufall/packen.py <arbeitsordner> <ziel.jsonl.gz>
Liest <arbeitsordner>/cases/*.json (engine_faelle.R) und <arbeitsordner>/stress/*.json (engine_stress.R) und schreibt
sie wie eine Bereichsdatei (Zeile 1 Kopf ohne Eingabespeicher, dann je Zeile ein Fall); tests/werkzeuge/gleichlauf/
vergleich.{py,jl} rechnen sie in Python und Julia nach (Engine-Format, run_engine).
"""
import gzip
import os
import sys


def main(src, ziel):
    zeilen = []
    for d in ("cases", "stress"):
        p = os.path.join(src, d)
        for f in sorted(os.listdir(p)) if os.path.isdir(p) else []:
            if f.endswith(".json"):
                with open(os.path.join(p, f), encoding="utf-8") as fh:
                    zeilen.append(fh.read().strip())
    with gzip.open(ziel, "wt", encoding="utf-8") as fh:
        fh.write('{"format":3,"bereich":"zufall_engine","faelle":%d,"inputs":{}}\n' % len(zeilen))
        for z in zeilen:
            fh.write(z + "\n")
    print("zufall_engine: %d Fälle -> %s" % (len(zeilen), ziel))
    return 0 if zeilen else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
