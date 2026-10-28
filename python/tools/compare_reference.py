"""Vergleicht die Python-Erweiterungsmodule bitgenau mit R-Referenzfällen.

Aufruf: python compare_reference.py [modul ...] [-k muster] [-v]

Ohne Modulnamen werden alle Ordner unter ``golden/modules/`` geprüft (bzw. unter
``SIMLEV_MODULE_DIR`` oder ``--dir``). Gelesen werden beide Formate der Fälle (Format 2 mit
Eingabespeicher ``_inputs.json.gz``, s. ``golden/README.md``).

Etappe 9 (Entwurf C.7): Der Vergleich mit ``golden/modules`` ist ausgesetzt; ohne
``SIMLEV_LEGACY_TESTS=1`` endet das Skript mit einem Hinweis und Ende 0, außer ``--dir`` bzw.
``SIMLEV_MODULE_DIR`` zeigt auf ein anderes Verzeichnis (Gleichlaufprüfung, ``tools/gleichlauf/``).
"""
from __future__ import annotations

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
from simlev._r.reftree import list_cases, load_case, run_case  # noqa: E402
from simlev._r import env as _env  # noqa: E402

ROOT = os.path.join(HERE, "..", "..", "golden", "modules")


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("modules", nargs="*")
    ap.add_argument("-k", default=None, help="nur Fälle, deren Kennung dies enthält")
    ap.add_argument("-v", action="store_true", help="Abweichungen ausführlich")
    ap.add_argument("--dir", default=_env.module_dir() or ROOT)
    a = ap.parse_args(argv)
    if not _env.legacy_tests() and os.path.abspath(a.dir) == os.path.abspath(ROOT):
        print("compare_reference: Etappe 9 – Vergleich mit golden/modules ausgesetzt "
              "(SIMLEV_LEGACY_TESTS=1, oder --dir/SIMLEV_MODULE_DIR für ein anderes Verzeichnis)")
        return 0
    mods = a.modules or sorted(d for d in os.listdir(a.dir) if os.path.isdir(os.path.join(a.dir, d)))
    tot_ok = tot = 0
    for m in mods:
        d = os.path.join(a.dir, m)
        files = list_cases(d)
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
