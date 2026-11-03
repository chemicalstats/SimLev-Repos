"""Gleichlauf: Python rechnet wie R (Szenarien und Tabellen aus tests/gleichlauf/faelle; Herkunft der Erwartung R).

Je Test (Szenario bzw. Tabelle) ein pytest-Fall <bereich>/<modul>/<id>; Abweichungen nennen Feld bzw. Tabellenzeile.
Bitgleichheit setzt 80-Bit-``long double`` wie in R voraus (Linux/x86-64). Anderer Ordner über ``SIMLEV_FAELLE_DIR``.
"""
import numpy as np
import pytest

import faelle

TESTS = faelle.katalog("gleichlauf")
EXACT = np.finfo(np.longdouble).nmant >= 63


def test_katalog_vorhanden():
    # ohne diesen Test entfielen die Vergleiche bei falschem Pfad still
    assert TESTS, "keine Tests in %s" % faelle.faelle_dir("gleichlauf")


@pytest.mark.skipif(not EXACT, reason="Bitgleichheit setzt 80-Bit-long-double voraus (Linux/x86-64)")
@pytest.mark.parametrize("kennung,case,store", TESTS, ids=[t[0] for t in TESTS])
def test_gleichlauf(kennung, case, store):
    errs = faelle.pruefe(case, store, verbose=True)
    assert not errs, "\n".join(errs)
