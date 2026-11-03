#!/usr/bin/env python3
"""Erzeugt die Abbildungen des Haupt-README aus echten Läufen der R-Blöcke.

    python3 tests/werkzeuge/doku/bilder.py

Führt alle R-Blöcke von README.md (wie beispiele.py) in einem Lauf aus und schreibt danach die
Dashboards als PNG nach r/man/figures/ (1800 x 1350 Pixel wie die übrigen Abbildungen). Die Namen
der Objekte (res_mix) stammen aus dem README. Voraussetzung: R-Paket aus R_LIBS.
"""
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import beispiele  # noqa: E402

FIG = os.path.join(beispiele.ROOT, "r", "man", "figures")
NACH = """
png({f!r}, width = 1800, height = 1350, res = 150)
plot(res_mix)
invisible(dev.off())
"""


def main():
    bl, _ = beispiele.blocks(os.path.join(beispiele.ROOT, "README.md"))
    code = "\n".join(b["code"] for b in bl if b["lang"] == "r")
    code += NACH.format(f=os.path.join(FIG, "README-ansparphase.png"))
    env = dict(os.environ)
    env.setdefault("LC_ALL", "C.UTF-8")
    with tempfile.TemporaryDirectory(prefix="simlev-bilder-") as tmp:
        f = os.path.join(tmp, "bilder.R")
        with open(f, "w", encoding="utf-8") as h:
            h.write(code)
        p = subprocess.run(["Rscript", f], cwd=tmp, env=env, capture_output=True, text=True)
    if p.returncode != 0:
        print(p.stderr[-3000:])
        return 1
    print("geschrieben: r/man/figures/README-ansparphase.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
