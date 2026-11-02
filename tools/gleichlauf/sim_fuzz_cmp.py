#!/usr/bin/env python3
"""E17: Zufallsfälle über simulation() (tools/gleichlauf/sim_fuzz.R) – R neu gegen die Referenz aus R 1.3.0.

Aufruf: python3 -I tools/gleichlauf/sim_fuzz_cmp.py <referenz/sim_fuzz> <neu/sim_fuzz>
(ebenso für den Datums-Fuzz tools/gleichlauf/sched_fuzz.R, Modul sched_fuzz; E17 Stufe 2)

Vergleicht jede Datei (Fälle und Eingabespeicher) streng: gleicher JSON-Baum (Zahlen als Hex-Literale, also
bitgleich einschließlich NA/NaN und Vorzeichen der Null), gleiche Konsolenausgabe, gleiche print()-Ausgabe,
gleiche Warnungen und Fehlertexte. Dazu die Zahl der Fälle auf dem Weg der Tagesengine im C++-Kern (ohne
Steuer, Splits und details; nach dem Code des Falls). Ende 1 bei einer Abweichung oder fehlenden Dateien.
"""
import gzip
import json
import os
import sys


def load(p):
    with gzip.open(p, "rt", encoding="utf-8") as fh:
        return json.load(fh)


def first_diff(a, b, path=""):
    if type(a) is not type(b):
        return path or "/"
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                return "%s/%s" % (path, k)
            d = first_diff(a[k], b[k], "%s/%s" % (path, k))
            if d:
                return d
        return None
    if isinstance(a, list):
        if len(a) != len(b):
            return path + " (Länge)"
        for i, (x, y) in enumerate(zip(a, b)):
            d = first_diff(x, y, "%s[%d]" % (path, i))
            if d:
                return d
        return None
    return None if a == b else (path or "/")


def main(argv):
    ref, new = argv[1], argv[2]
    fr = sorted(f for f in os.listdir(ref) if f.endswith(".json.gz"))
    fn = sorted(f for f in os.listdir(new) if f.endswith(".json.gz"))
    bad = 0
    for f in sorted(set(fr) ^ set(fn)):
        print("FEHLT %s (%s)" % (f, "neu" if f in fr else "Referenz"))
        bad += 1
    n = engine = errors = warned = 0
    for f in sorted(set(fr) & set(fn)):
        a, b = load(os.path.join(ref, f)), load(os.path.join(new, f))
        d = first_diff(a, b)
        if d:
            print("ABWEICHUNG %s: %s" % (f, d))
            bad += 1
        if f.startswith("_"):
            continue
        n += 1
        code = a.get("r", "")
        if "tax = " not in code and "splits = " not in code and "details = TRUE" not in code and "error" not in a:
            engine += 1
        errors += "error" in a
        warned += bool(a.get("warnings"))
    print("sim_fuzz: %d Fälle, davon %d ohne Steuer/Splits/details (Tagesengine), %d mit Fehler, %d mit Warnungen"
          % (n, engine, errors, warned))
    print("sim_fuzz: %d/%d Dateien gleich" % (len(set(fr) & set(fn)) - bad + len(set(fr) ^ set(fn)) * 0,
                                              len(set(fr) | set(fn))) if bad else
          "sim_fuzz: alle %d Dateien gleich (R neu = R 1.3.0)" % len(fr))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
