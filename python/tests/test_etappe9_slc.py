"""Rauchprobe der C-Bibliothek slc (Etappe 9.1): läuft immer, auch ohne SIMLEV_LEGACY_TESTS.

Prüft Laden, ``simlev_seed``, Testvektoren (unabhängig mit Ganzzahlen nachgerechnet, siehe
scratchpad/e91/plaus_rng.txt), Ströme, Fehler- und Warnungstexte und einige Werte der
Verteilungen. Die Gleichheit mit R und Julia prüft tools/gleichlauf/.
"""
import warnings

import numpy as np
import pytest

import simlev
from simlev import _lib as L


def test_laden_und_export():
    assert "simlev_seed" in simlev.__all__
    assert simlev.simlev_seed(1) == 1
    assert L.version() == "0.1.0"


def test_testvektor_seed42():
    simlev.simlev_seed(42)
    # Zustand = erste vier Ausgaben von SplitMix64(42) (= java.util.SplittableRandom(42))
    assert L.state_hex() == ["bdd732262feb6e95", "28efe333b266f103", "47526757130f9f52", "581ce1ff0e4ae394"]
    assert L.u64(2) == ["15780b2e0c2ec716", "6104d9866d113a7e"]


def test_reproduzierbar_und_stroeme():
    simlev.simlev_seed(7)
    a = L.runif(5)
    simlev.simlev_seed(7)
    assert np.array_equal(a, L.runif(5))
    s = L.Stream(7)
    assert np.array_equal(a, L.runif(5, stream=s))
    u = L.streams(L.Stream(7), 3)
    assert len(u) == 3 and len({tuple(x.hex()) for x in u}) == 3
    assert all(0 < v < 1 for v in L.runif(1000, stream=u[0]))


def test_seed_fehler():
    for bad, txt in ((1.5, "1.5"), ("a", "'a'"), (True, "True"), (2 ** 53, "9007199254740992")):
        with pytest.raises(ValueError, match=r"seed: ganze Zahl erwartet \(erhalten: %s\)" % txt.replace(".", r"\.")):
            simlev.simlev_seed(bad)


def test_warnung_und_fehler_aus_dem_kern():
    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        r = L.qnorm([2.0, 0.5])
    assert np.isnan(r[0]) and r[1] == 0.0
    assert [str(x.message) for x in w] == ["qnorm: NaN erzeugt"]
    with pytest.raises(ValueError, match="Stichprobe größer als die Grundgesamtheit"):
        L.sample(3, 5)
    with L.in_unit(), pytest.raises(RuntimeError, match="globaler Zufallszustand in paralleler Einheit"):
        L.runif(1)


def test_verteilungen_stichprobe():
    assert L.qnorm(0.975) == pytest.approx(1.959963984540054, rel=1e-15)
    assert L.pnorm(-38.0) > 0
    assert L.lgamma(0.5) == pytest.approx(0.5723649429247001, rel=1e-15)
    assert L.pt(2.0, 5.0) == pytest.approx(0.9490302605850709, rel=1e-14)
    assert L.qt(0.975, 10.0) == pytest.approx(2.228138851986274, rel=1e-14)
    assert L.pbeta(0.3, 2.0, 3.0) == pytest.approx(0.3483, rel=1e-12)
    assert L.qlogis(L.plogis(0.3)) == pytest.approx(0.3, rel=1e-15)
    na = np.array([0x7FF00000000007A2], dtype=np.uint64).view(np.float64)
    out = L.pnorm(na)
    assert out.view(np.uint64)[0] == na.view(np.uint64)[0]      # NA bleibt NA (Nutzlast 1954)
