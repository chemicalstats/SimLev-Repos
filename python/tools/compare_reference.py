"""Vergleicht die Python-Erweiterungsmodule bitgenau mit R-Referenzfällen.

Aufruf: python compare_reference.py [modul ...] [-k muster] [-v]

Ohne Modulnamen werden alle Ordner unter ``golden/modules/`` geprüft.
"""
from __future__ import annotations

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
from simlev._r.reftree import load_case, run_case  # noqa: E402

ROOT = os.path.join(HERE, "..", "..", "golden", "modules")


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("modules", nargs="*")
    ap.add_argument("-k", default=None, help="nur Fälle, deren Kennung dies enthält")
    ap.add_argument("-v", action="store_true", help="Abweichungen ausführlich")
    ap.add_argument("--dir", default=ROOT)
    a = ap.parse_args(argv)
    mods = a.modules or sorted(d for d in os.listdir(a.dir) if os.path.isdir(os.path.join(a.dir, d)))
    tot_ok = tot = 0
    for m in mods:
        d = os.path.join(a.dir, m)
        files = sorted(f for f in os.listdir(d) if f.endswith(".json.gz") or f.endswith(".json"))
        if a.k:
            files = [f for f in files if a.k in f]
        ok = 0
        for f in files:
            case = load_case(os.path.join(d, f))
            errs = run_case(case)
            if errs:
                print("FAIL %s/%s" % (m, f))
                for e in (errs if a.v else errs[:4]):
                    print("    " + e.replace("\n", "\n    ")[: (20000 if a.v else 600)])
            else:
                ok += 1
        print("%-16s %d/%d bitgleich" % (m, ok, len(files)))
        tot_ok += ok
        tot += len(files)
    print("Gesamt: %d/%d" % (tot_ok, tot))
    return 0 if tot_ok == tot else 1


if __name__ == "__main__":
    sys.exit(main())
