#!/usr/bin/env python3
"""tests/gleichlauf/exporte.py – Abdeckung der Exporte durch Referenzfälle (Entwurf C.8; bis T20 coverage.py).

Liest die exportierten R-Funktionen aus ``tests/api/api.json`` und sucht im R-Code (Feld ``r``) bzw. in den
Bausteinen (Engine-Format, Feld ``args``) aller Fälle der Bereichsdateien unter ``--dir`` (Standard tests/faelle)
nach ``name(``. Gibt die Exporte ohne Fall aus; das Ziel ist 0 (fehlende Fälle in tests/erzeugen/<bereich>.R ergänzen).
Ende 0 immer (Bericht), außer mit ``--strict``.
"""
import argparse
import gzip
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))


def cases(d):
    for f in sorted(os.listdir(d)):
        if f.endswith(".jsonl.gz"):
            with gzip.open(os.path.join(d, f), "rt", encoding="utf-8") as fh:
                fh.readline()
                for ln in fh:
                    if ln.strip():
                        yield json.loads(ln)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=os.path.join(ROOT, "tests", "faelle"), help="Ordner der Bereichsdateien")
    ap.add_argument("--api", default=os.path.join(ROOT, "tests", "api", "api.json"))
    ap.add_argument("--strict", action="store_true")
    a = ap.parse_args(argv)
    api = json.load(open(a.api, encoding="utf-8"))
    names = sorted({f["R"]["name"] for f in api["functions"] if f.get("kind") == "function" and f.get("R")})
    # zusätzlich: simlev_seed ist neu (noch nicht in einem eingefrorenen Stand)
    if "simlev_seed" not in names:
        names.append("simlev_seed")
    code = []
    n = 0
    for c in cases(a.dir):
        n += 1
        code.append(c.get("r") or "")
        if "module" not in c:     # Engine-Format: simulation() mit den Bausteinen in args
            code.append("simulation(")
            code += ["%s(" % b for b in re.findall(r'"block": *"([A-Za-z_.0-9]+)"', json.dumps(c.get("args") or {}))]
    text = "\n".join(code)
    miss = [nm for nm in names if not re.search(r"(?<![A-Za-z0-9_.])" + re.escape(nm) + r"\s*\(", text)]
    print("Abdeckung: %d Exporte, %d Fälle, ohne Fall: %d" % (len(names), n, len(miss)))
    for nm in miss:
        print("  ohne Fall:", nm)
    return 1 if (a.strict and miss) else 0


if __name__ == "__main__":
    sys.exit(main())
