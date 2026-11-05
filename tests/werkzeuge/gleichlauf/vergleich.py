#!/usr/bin/env python3
"""Python gegen R: alle Fälle von Bereichsdateien nachrechnen (Gleichlauf; bis 1.4.0 compare_reference.py
und compare_golden.py).

Aufruf: python3 tests/werkzeuge/gleichlauf/vergleich.py [--protokoll P] <datei.jsonl.gz | ordner> ... [-k muster] [-v]

Ohne Pfad der Katalog ``tests/<gruppe>/faelle``. Ordner: alle ``*.jsonl.gz`` darin. Vergleich wie die Tests
(``tests/lib/faelle.py``): Modulfälle mit ``tests/lib/reftree.py``, Engine-Fälle mit ``run_engine``.
Ausgabe je Modul ``<modul> <ok>/<n> bitgleich`` und ``Gesamt: <ok>/<n>``; Ende 1 bei einer Abweichung. Die Fälle
werden einzeln gelesen und geprüft (seit 1.6.3; bis 1.6.2 alle einer Datei zugleich).

``--protokoll P`` (seit 1.6.3) gilt für den folgenden Pfad: dessen Ausgabe (FAIL-Zeilen, Modulzeilen,
``Gesamt: <ok>/<n>``) geht nach P, genau wie bei einem eigenen Aufruf nur mit diesem Pfad; auf die Konsole kommt dann
je Datei ``Datei <pfad>: <ok>/<n> (<s> s)`` bzw. ``Datei <pfad>: FEHLER (…)`` (ein Prozess für mehrere Dateien,
``tests/werkzeuge/gleichlauf/run.py``). Ende 1, wenn eine dieser Dateien abweicht oder keinen Fall hat, oder wenn die
Dateien ohne Protokoll zusammen abweichen.
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "lib"))
sys.path.insert(0, os.path.join(HERE, "..", ".."))
import conftest  # noqa: E402,F401  (Pfad zum gebauten Paket wie in den Tests)
import faelle  # noqa: E402


def pruefe_datei(out, f, k, verbose):
    """Fälle der Datei f prüfen, Ausgabe nach out; (ok, n)."""
    strom = faelle.bereich_strom(f)
    store = next(strom)["inputs"]
    stat = {}
    for c in strom:
        key = faelle.kennung(c)
        if k and k not in key:
            continue
        m = key.split("/")[0]
        try:
            errs = faelle.pruefe(c, store, verbose=verbose)
        except Exception as e:  # noqa: BLE001
            errs = ["Werkzeugfehler: %r" % e]
        ok, n = stat.get(m, (0, 0))
        stat[m] = (ok + (not errs), n + 1)
        if errs:
            print("FAIL %s" % key, file=out)
            for e in (errs if verbose else errs[:4]):
                print("    " + e.replace("\n", "\n    ")[: (20000 if verbose else 600)], file=out)
    for m, (ok, n) in stat.items():
        print("%-16s %d/%d bitgleich" % (m, ok, n), file=out)
    return sum(s[0] for s in stat.values()), sum(s[1] for s in stat.values())


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    paths, k, verbose, prot = [], None, False, None
    it = iter(argv)
    for a in it:
        if a in ("-h", "--help"):
            print(__doc__)
            return 0
        if a in ("-k", "--protokoll"):
            v = next(it, None)
            if v is None:
                print("vergleich.py: %s ohne Wert" % a, file=sys.stderr)
                return 2
            if a == "-k":
                k = v
            else:
                prot = v
        elif a == "-v":
            verbose = True
        else:
            paths.append((a, prot))
            prot = None
    paths = paths or [(faelle.faelle_dir(g), None) for g in faelle.GRUPPEN]
    tot = tot_ok = o_ok = o_n = 0
    ohne, eigen_ok = False, True
    for p, pr in paths:
        if pr is None:          # Ausgabe auf die Konsole
            ohne = True
            for f in (faelle.bereiche(p) if os.path.isdir(p) else [p]):
                ok, n = pruefe_datei(sys.stdout, f, k, verbose)
                o_ok += ok
                o_n += n
            continue
        if os.path.isdir(p):
            print("vergleich.py: --protokoll gilt für eine Datei, nicht für den Ordner %s" % p, file=sys.stderr)
            return 2
        t0 = time.time()
        try:
            with open(pr, "w", encoding="utf-8") as h:
                ok, n = pruefe_datei(h, p, k, verbose)
                print("Gesamt: %d/%d" % (ok, n), file=h)
        except Exception as e:  # noqa: BLE001 - Datei unlesbar: diese Datei scheitert, die übrigen laufen weiter
            with open(pr, "a", encoding="utf-8") as h:
                print("Werkzeugfehler: %r" % (e,), file=h)
            print("Datei %s: FEHLER (%s)" % (p, ("%r" % (e,))[:300]), flush=True)
            eigen_ok = False
            continue
        print("Datei %s: %d/%d (%d s)" % (p, ok, n, int(round(time.time() - t0))), flush=True)
        eigen_ok = eigen_ok and ok == n and n > 0
        tot_ok += ok
        tot += n
    tot_ok += o_ok
    tot += o_n
    print("Gesamt: %d/%d" % (tot_ok, tot))
    return 0 if eigen_ok and (not ohne or (o_ok == o_n and o_n > 0)) else 1


if __name__ == "__main__":
    sys.exit(main())
