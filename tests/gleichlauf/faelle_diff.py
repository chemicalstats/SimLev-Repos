#!/usr/bin/env python3
"""Mit dem aktuellen R neu erzeugte Bereichsdateien gegen den Katalog tests/faelle (Byte für Byte; bis T20
golden_diff.py).

Aufruf: python3 -I tests/gleichlauf/faelle_diff.py <ordner>   (run.sh: <arbeitsordner>/faelle)

Je Bereich muss <ordner>/<bereich>.jsonl.gz Byte für Byte tests/faelle/<bereich>.jsonl.gz entsprechen (gzip -9 -n,
gleicher Text). Bei einem Unterschied nennt das Werkzeug die verschiedenen Fälle. Ein Unterschied heißt: R rechnet
anders als beim letzten Neuerzeugen; der Katalog ist mit tests/erzeugen/alle.sh neu zu erzeugen (Ursache in
r/NEWS.md). Ende 1 bei einem Unterschied oder einem fehlenden Bereich.
"""
import gzip
import os
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
KAT = os.path.join(ROOT, "tests", "faelle")


def lines(p):
    with gzip.open(p, "rt", encoding="utf-8") as fh:
        return fh.read().split("\n")


def main(out):
    alt = sorted(f for f in os.listdir(KAT) if f.endswith(".jsonl.gz"))
    neu = sorted(f for f in os.listdir(out) if f.endswith(".jsonl.gz"))
    bad = n = 0
    for f in sorted(set(alt) | set(neu)):
        if f not in neu or f not in alt:
            print("FEHLT %s (%s)" % (f, "neu" if f not in neu else "Katalog"))
            bad += 1
            continue
        a, b = os.path.join(KAT, f), os.path.join(out, f)
        la, lb = lines(a), lines(b)
        n += len(la) - 2
        if open(a, "rb").read() == open(b, "rb").read():
            print("gleich      %-20s %d Fälle" % (f, len(la) - 2))
            continue
        bad += 1
        print("VERSCHIEDEN %s" % f)
        if la[0] != lb[0]:
            print("    Kopf (Eingabespeicher) verschieden")
        ia = {ln[:200].split(",")[0]: ln for ln in la[1:]}
        for ln in lb[1:]:
            k = ln[:200].split(",")[0]
            if ia.get(k) != ln:
                print("    verschieden oder neu:", k)
    print("faelle_diff: %d Bereiche, %d Fälle, %d verschieden" % (len(alt), n, bad))
    print("Gesamt: gleich" if bad == 0 else "Gesamt: VERSCHIEDEN")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
