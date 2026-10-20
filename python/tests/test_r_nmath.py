"""Schneller Selbsttest für simlev._r.nmath (Ports der R-nmath-Funktionen).

Die eigentliche Bitgleichheit prüfen die Referenzfälle in
``golden/modules/r_nmath`` (``tools/compare_reference.py r_nmath``); hier nur
bekannte R-Werte (als Hex-Literale aus R 4.3.3), exakte Symmetrien, Form
der Ergebnisse und Warnungen.
"""
import math
import warnings

import numpy as np
import pandas as pd
import pytest

import simlev._r.nmath as nm

# Werte aus R 4.3.3: sprintf("%a", ...)
KNOWN = [
    (lambda: nm.pnorm(1.96), "0x1.f33379d3bd368p-1"),
    (lambda: nm.qnorm(0.975), "0x1.f5c0331eeff82p+0"),
    (lambda: nm.qt(0.975, 10), "0x1.1d33a7661d302p+1"),
    (lambda: nm.pt(2, 5), "0x1.e5e74b5841254p-1"),
    (lambda: nm.lgamma(0.5), "0x1.250d048e7a1bdp-1"),
    (lambda: nm.gamma(0.5), "0x1.c5bf891b4ef6bp+0"),
    (lambda: nm.beta(2, 3), "0x1.5555555555555p-4"),
    (lambda: nm.pchisq(3.84, 1), "0x1.e660b211b862fp-1"),
    (lambda: nm.qchisq(0.95, 1), "0x1.ebb4ec31e7ef5p+1"),
    (lambda: nm.pf(4, 3, 10), "0x1.ead47a0c5e82p-1"),
    (lambda: nm.qgamma(0.5, 2), "0x1.ada825f9762b4p+0"),
    (lambda: nm.plogis(1), "0x1.764d4f5d5a2bdp-1"),
    (lambda: nm.qlogis(0.3), "-0x1.b1d10670aae99p-1"),
    (lambda: nm.dt(1, 2), "0x1.8a2345cc04426p-3"),
    (lambda: nm.dnorm(1), "0x1.ef8e58e331738p-3"),
    (lambda: nm.pbeta(0.3, 2, 3), "0x1.64a8c154c985dp-2"),
    (lambda: nm.qt(1e-10, 2.5), "-0x1.11eb808e45f09p+13"),
    (lambda: nm.pt(-40, 3, log_p=True), "-0x1.5f13c44b9e406p+3"),
    (lambda: nm.lbeta(1e5, 2e5), "-0x1.74f77150d37b6p+17"),
    (lambda: nm.gamma(171), "0x1.4ab78644188fdp+1019"),
    (lambda: nm.lgamma(-0.5), "0x1.43f89a3f0edd6p+0"),
]


@pytest.mark.parametrize("i", range(len(KNOWN)))
def test_known_values(i):
    f, hx = KNOWN[i]
    got = f()
    assert isinstance(got, float)
    assert got == float.fromhex(hx), (got.hex(), hx)


def test_exact_integers_and_limits():
    assert nm.gamma(5) == 24.0
    assert nm.gamma(11) == 3628800.0
    assert nm.lgamma(1) == 0.0 and nm.lgamma(2) == 0.0
    assert nm.qnorm(0.5) == 0.0
    assert nm.qnorm(0) == -math.inf and nm.qnorm(1) == math.inf
    assert nm.qt(0, 3) == -math.inf and nm.qt(1, 3) == math.inf
    assert nm.pt(math.inf, 2) == 1.0 and nm.pt(-math.inf, 2) == 0.0
    assert nm.pnorm(0, log_p=True) == -math.log(2) or nm.pnorm(0, log_p=True) == math.log(0.5)
    assert nm.pbeta(0, 2, 3) == 0.0 and nm.pbeta(1, 2, 3) == 1.0
    assert nm.qgamma(0, 2) == 0.0 and nm.qchisq(1, 3) == math.inf
    assert nm.lgamma(-3) == math.inf
    # df = Inf: t-Verteilung = Normalverteilung
    assert nm.pt(1.5, math.inf) == nm.pnorm(1.5)
    assert nm.dt(0.7, math.inf) == nm.dnorm(0.7)
    assert nm.qt(0.3, 1e21) == nm.qnorm(0.3)


def test_exact_symmetries():
    x = np.linspace(-50, 50, 2001)
    assert np.array_equal(nm.pnorm(-x), nm.pnorm(x, lower_tail=False))
    assert np.array_equal(nm.pnorm(-x, log_p=True), nm.pnorm(x, lower_tail=False, log_p=True))
    assert np.array_equal(nm.dnorm(-x), nm.dnorm(x))
    xn = x[x != 0]
    p = np.linspace(1e-6, 1 - 1e-6, 301)
    for df in (1, 1.5, 2, 3, 4.5, 10, 30, 1e5):
        assert np.array_equal(nm.pt(-xn, df), nm.pt(xn, df, lower_tail=False))
        assert np.array_equal(nm.qt(p, df, lower_tail=False), -nm.qt(p, df))
        assert np.array_equal(nm.dt(-x, df), nm.dt(x, df))


def test_roundtrips():
    p = np.linspace(0.001, 0.999, 199)
    assert np.allclose(nm.pnorm(nm.qnorm(p)), p, rtol=1e-14, atol=0)
    for df in (0.5, 1, 2.5, 7, 100):
        assert np.allclose(nm.pt(nm.qt(p, df), df), p, rtol=1e-10, atol=0)
    for df in (0.3, 1, 4, 50):
        assert np.allclose(nm.pchisq(nm.qchisq(p, df), df), p, rtol=1e-9, atol=0)
    assert np.allclose(nm.plogis(nm.qlogis(p)), p, rtol=1e-14, atol=0)
    lb = nm.lbeta(np.array([0.5, 3.0, 20.0]), np.array([2.0, 7.0, 15.0]))
    assert np.allclose(np.exp(lb), nm.beta(np.array([0.5, 3.0, 20.0]), np.array([2.0, 7.0, 15.0])), rtol=1e-13)


def test_shapes_and_recycling():
    assert isinstance(nm.pnorm(1.0), float)
    assert isinstance(nm.qt(np.float64(0.3), 4), float)
    r = nm.qt(np.array([0.1, 0.5, 0.9, 0.2]), np.array([3.0, 30.0]))
    assert r.shape == (4,)
    assert r[0] == nm.qt(0.1, 3) and r[1] == nm.qt(0.5, 30) and r[3] == nm.qt(0.2, 30)
    U = np.array([[0.1, 0.2], [0.5, 0.7], [0.9, 0.99]])
    Z = nm.qt(U, 4)
    assert Z.shape == (3, 2) and Z[2, 1] == nm.qt(0.99, 4)
    s = nm.pnorm(pd.Series([-1.0, 0.0, 2.0], index=["a", "b", "c"]))
    assert isinstance(s, pd.Series) and list(s.index) == ["a", "b", "c"]
    assert nm.pnorm(np.array([])).shape == (0,)
    # Deduplizierung gleicher Eingaben ändert nichts am Ergebnis
    v = np.tile(np.array([0.01, 0.3, 0.3, 0.77, -0.0, 0.0]), 50)
    assert np.array_equal(nm.qt(v, 3.5), np.array([nm.qt(float(u), 3.5) for u in v]))


def _warns(f):
    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        res = f()
    return res, [str(x.message) for x in w]


def test_warnings():
    r, w = _warns(lambda: nm.qt(np.array([0.5, 2.0]), 3))
    assert r[0] == 0.0 and math.isnan(r[1]) and w == ["NaNs produced"]
    r, w = _warns(lambda: nm.pnorm(np.array([1.0, np.nan])))
    assert w == []
    r, w = _warns(lambda: nm.gamma(1e-309))
    assert r == math.inf and w == ["value out of range in 'gammafn'"]
    r, w = _warns(lambda: nm.lgamma(-11 + 1e-12))
    assert w == ["full precision may not have been achieved in 'lgamma'"]
    r, w = _warns(lambda: nm.pbeta(1e-320, 1e-5, 0.5))
    assert w == ["bgrat(a=20.5, b=1e-05, x=1, y=9.99989e-321): z=1.99998e-319, "
                 "b*z == 0 underflow, hence inaccurate pbeta()"]
    r, w = _warns(lambda: nm.qgamma(0.5, 2, rate=2, scale=0.5))
    assert w == ["specify 'rate' or 'scale' but not both"]
    with pytest.raises(ValueError, match="specify 'rate' or 'scale' but not both"):
        nm.qgamma(0.5, 2, rate=2, scale=2)


def test_helpers():
    assert nm.stirlerr(2.5) == 0.03316287351993628748511048
    assert nm.stirlerr(np.float64(1.0)) == 0.0810614667953272582196702
    assert nm.log1pmx(0.0) == 0.0 and nm.lgamma1p(0.0) == 0.0
    assert abs(nm.lgamma1p(0.3) - math.lgamma(1.3)) < 1e-15
    assert abs(nm.log1pmx(0.2) - (math.log1p(0.2) - 0.2)) < 1e-16
    assert abs(nm.logspace_add(math.log(2), math.log(3)) - math.log(5)) < 1e-15
    assert nm.bd0(3.0, 3.0) == 0.0
    yh, yl = nm.ebd0(3.0, 5.0)
    assert abs((yh + yl) - (3 * math.log(3 / 5) + 5 - 3)) < 1e-14
    assert abs(nm.lgammacor(20.0) - (math.lgamma(20) - (19.5 * math.log(20) - 20 + 0.5 * math.log(2 * math.pi)))) < 1e-14
    assert abs(nm.dpois_raw(3.0, 2.0) - math.exp(-2) * 8 / 6) < 1e-16
    assert nm.lgammafn(0.5) == nm.lgamma(0.5) and nm.gammafn(4.5) == nm.gamma(4.5)
