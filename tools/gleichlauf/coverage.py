#!/usr/bin/env python3
"""tools/gleichlauf/coverage.py – Abdeckung der Exporte durch Gleichlauffälle (Entwurf C.8, Schritt 5).

Liest die exportierten R-Funktionen aus ``tools/api_snapshot/api.json`` und sucht im R-Code (Feld
``r``) aller Fälle unter ``--dir`` (und optional ``--golden``-Ordnern der Engine) nach ``name(``.
Gibt die Exporte ohne Fall aus; das Ziel ist 0 (fehlende Fälle in ``tools/gleichlauf/extra_cases.R``).
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
    for root, _, files in os.walk(d):
        for f in files:
            if f.endswith(".json.gz") and not f.startswith("_"):
                with gzip.open(os.path.join(root, f), "rt", encoding="utf-8") as fh:
                    yield json.load(fh)
            elif f.endswith(".json") and not f.startswith("_"):
                with open(os.path.join(root, f), encoding="utf-8") as fh:
                    yield json.load(fh)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True, help="Ordner der Modulfälle")
    ap.add_argument("--api", default=os.path.join(ROOT, "tools", "api_snapshot", "api.json"))
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
        code.append(json.dumps(c.get("call") or ""))      # Engine-Fälle beschreiben den Aufruf anders
    text = "\n".join(code)
    miss = [nm for nm in names if not re.search(r"(?<![A-Za-z0-9_.])" + re.escape(nm) + r"\s*\(", text)]
    print("Abdeckung: %d Exporte, %d Fälle, ohne Fall: %d" % (len(names), n, len(miss)))
    for nm in miss:
        print("  ohne Fall:", nm)
    return 1 if (a.strict and miss) else 0


if __name__ == "__main__":
    sys.exit(main())
