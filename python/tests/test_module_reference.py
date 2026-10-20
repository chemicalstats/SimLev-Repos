"""Bitgleichheit der Erweiterungsmodule zu R.

Liest die Referenzfälle aus ``golden/modules/<modul>/`` (erzeugt mit den
Generatoren ``golden/modules/gen_*.R``) und vergleicht Ergebnis, Konsolen-
und Druckausgabe sowie Warnungen und Fehlermeldungen.
"""
import os

import numpy as np
import pytest

from simlev._r.reftree import load_case, run_case

ROOT = os.environ.get("SIMLEV_MODULE_DIR") or os.path.join(
    os.path.dirname(__file__), "..", "..", "golden", "modules")
CASES = []
if os.path.isdir(ROOT):
    for m in sorted(os.listdir(ROOT)):
        d = os.path.join(ROOT, m)
        if os.path.isdir(d):
            CASES += [os.path.join(m, f) for f in sorted(os.listdir(d)) if f.endswith(".json.gz")]

EXACT = np.finfo(np.longdouble).nmant >= 63


@pytest.mark.skipif(not EXACT, reason="Bitgleichheit setzt 80-Bit-long-double voraus (Linux/x86-64)")
@pytest.mark.parametrize("case", CASES)
def test_module_reference(case):
    errs = run_case(load_case(os.path.join(ROOT, case)))
    assert not errs, "\n".join(errs)
