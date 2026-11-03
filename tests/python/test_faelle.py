"""Bitgleichheit zu R über den Katalog ``tests/faelle`` (T20): alle Fälle aller Bereiche.

Je Fall ein Test ``<bereich>/<modul>/<id>``; Auswahl mit ``-k`` (z. B. ``-k entnahme``). Anderer Ordner über
``SIMLEV_FAELLE_DIR``. Bitgleichheit setzt 80-Bit-``long double`` wie in R voraus (Linux/x86-64).
"""
import os

import numpy as np
import pytest

import faelle

_HEADS = {}
CASES = []
for _p in faelle.bereiche():
    _b = os.path.basename(_p)[: -len(".jsonl.gz")]
    _head, _cases = faelle.lies_bereich(_p)
    _HEADS[_b] = _head["inputs"]
    CASES += [(_b, c) for c in _cases]

EXACT = np.finfo(np.longdouble).nmant >= 63


def test_katalog_vorhanden():
    # ohne diesen Test entfielen die Vergleiche bei falschem Pfad still
    assert len(CASES) > 0, "keine Fälle in %s" % faelle.FAELLE


@pytest.mark.skipif(not EXACT, reason="Bitgleichheit setzt 80-Bit-long-double voraus (Linux/x86-64)")
@pytest.mark.parametrize("bereich,case", CASES, ids=["%s/%s" % (b, faelle.kennung(c)) for b, c in CASES])
def test_fall(bereich, case):
    errs = faelle.pruefe(case, _HEADS[bereich], verbose=True)
    assert not errs, "\n".join(errs)
