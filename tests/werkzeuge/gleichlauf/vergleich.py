#!/usr/bin/env python3
"""Python gegen R: alle Fälle von Bereichsdateien nachrechnen (Gleichlauf; bis 1.4.0 compare_reference.py
und compare_golden.py).

Aufruf: python3 tests/werkzeuge/gleichlauf/vergleich.py <datei.jsonl.gz | ordner> ... [-k muster] [-v]

Ohne Pfad der Katalog ``tests/<gruppe>/faelle``. Ordner: alle ``*.jsonl.gz`` darin. Vergleich wie die Tests
(``tests/lib/faelle.py``): Modulfälle mit ``tests/lib/reftree.py``, Engine-Fälle mit ``run_engine``.
Ausgabe je Modul ``<modul> <ok>/<n> bitgleich`` und ``Gesamt: <ok>/<n>``; Ende 1 bei einer Abweichung.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "lib"))
sys.path.insert(0, os.path.join(HERE, "..", ".."))
import conftest  # noqa: E402,F401  (Pfad zum gebauten Paket wie in den Tests)
import faelle  # noqa: E402


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("paths", nargs="*")
    ap.add_argument("-k", default=None, help="nur Fälle, deren Kennung dies enthält")
    ap.add_argument("-v", action="store_true", help="Abweichungen ausführlich")
    a = ap.parse_args(argv)
    files = []
    for p in (a.paths or [faelle.faelle_dir(g) for g in faelle.GRUPPEN]):
        files += faelle.bereiche(p) if os.path.isdir(p) else [p]
    tot = tot_ok = 0
    for f in files:
        head, cases = faelle.lies_bereich(f)
        stat = {}
        for c in cases:
            key = faelle.kennung(c)
            if a.k and a.k not in key:
                continue
            m = key.split("/")[0]
            try:
                errs = faelle.pruefe(c, head["inputs"], verbose=a.v)
            except Exception as e:  # noqa: BLE001
                errs = ["Werkzeugfehler: %r" % e]
            ok, n = stat.get(m, (0, 0))
            stat[m] = (ok + (not errs), n + 1)
            if errs:
                print("FAIL %s" % key)
                for e in (errs if a.v else errs[:4]):
                    print("    " + e.replace("\n", "\n    ")[: (20000 if a.v else 600)])
        for m, (ok, n) in stat.items():
            print("%-16s %d/%d bitgleich" % (m, ok, n))
            tot_ok += ok
            tot += n
    print("Gesamt: %d/%d" % (tot_ok, tot))
    return 0 if tot_ok == tot and tot > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
