"""Bitgleichheit zu R: vergleicht jede Tageszahl, Kennzahl und Textausgabe mit
Referenzergebnissen, die mit dem R-Paket SimLev 0.5.0 erzeugt wurden.

Die Referenzen liegen komprimiert in den gemeinsamen Ordnern ``golden/cases/`` (68) und
``golden/extra/`` (37) des Repositorys. Verglichen wird mit ``tools/compare_golden.py``
(``worth``, ``drawdowns``, ``filled``, ``cagr``, ``ttwror``, ``statistics``, ``tax_report``,
``buys``, ``sells``, ``report``, Druckausgabe und ``details``-Ausgabe). Andere Ordner lassen
sich über die Umgebungsvariable ``SIMLEV_GOLDEN_DIR`` (durch ``os.pathsep`` getrennt) setzen.
"""
import os
import sys

import numpy as np
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
import compare_golden  # noqa: E402
from simlev._r import env as _env  # noqa: E402

DIRS = (_env.golden_dir().split(os.pathsep) if _env.golden_dir()
        else compare_golden.DEFAULT_DIRS)
CASES = [os.path.join(d, f) for d in DIRS if os.path.isdir(d) for f in sorted(os.listdir(d))
         if f.endswith(".json.gz")]

# Bitgleichheit setzt 80-Bit-long-double wie in R voraus (Linux/x86-64).
EXACT = np.finfo(np.longdouble).nmant >= 63


def test_golden_cases_present():
    # Ohne diesen Test würden die Bitgleichheits-Tests bei falschem Pfad still entfallen.
    assert len(CASES) >= 90 or _env.golden_dir(), "Golden-Fälle fehlen in %s" % (DIRS,)


@pytest.mark.skipif(not EXACT, reason="Bitgleichheit nur mit 80-Bit-long-double (Linux/x86-64)")
@pytest.mark.parametrize("path", CASES, ids=[os.path.basename(p).split(".json")[0] for p in CASES])
def test_bitgleich_zu_r(path):
    errs = compare_golden.run(path, verbose=True)
    assert not errs, "\n".join(errs)
