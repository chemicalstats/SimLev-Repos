"""Selbsttest für simlev._r.stats und die Ergänzungen in simlev._r.base.

Die vollständige Bitgleichheit prüfen die Referenzfälle in
``golden/modules/r_stats`` (Generator ``golden/modules/gen_r_stats.R``,
``tools/compare_reference.py r_stats``) in ``test_module_reference.py``.
Zusätzlich: bekannte R-Werte (Hex aus R 4.3.3), Form der Ergebnisse,
Warnungen/Fehler und die R-NaN-Markierung.
"""
import math
import warnings

import numpy as np
import pandas as pd
import pytest

import simlev._r.base as rb
import simlev._r.fmt as fm
import simlev._r.stats as st

EXACT = np.finfo(np.longdouble).nmant >= 63

X = np.array([3.1, -0.4, 2.2, 5.9, 1.05, 0.3, 4.4])


def _fr(p):
    a = p[1] - p[0] * p[0]
    b = 1 - p[0]
    return 100 * (a * a) + b * b


# Werte aus R 4.3.3: sprintf("%a", ...)
KNOWN = [
    (lambda: st.quantile(X, 0.3, names=False), "0x1.cccccccccccccp-1"),
    (lambda: st.quantile(X, 0.3, type=6, names=False), "0x1.3333333333333p-1"),
    (lambda: st.var(X), "0x1.48ff832b65e9ap+2"),
    (lambda: st.sd(X), "0x1.22367eed49a7cp+1"),
    (lambda: st.cor(X, X[::-1] ** 2), "0x1.b3b679d319d2ap-1"),
    (lambda: st.cor(X, X[::-1], method="kendall"), "0x1.6db6db6db6db7p-1"),
    (lambda: st.optimize(lambda t: (t - 0.37) * (t - 0.37) + math.sin(3 * t), (-1, 2))["minimum"],
     "-0x1.6be70f906f58cp-2"),
    (lambda: st.uniroot(lambda t: math.pow(t, 3) - t - 1, (1, 2))["root"], "0x1.5320b5175b36fp+0"),
    (lambda: st.optim(np.array([-1.2, 1]), _fr, method="BFGS")["par"][0], "0x1.ffe65dde3fd47p-1"),
    (lambda: st.optim(np.array([-1.2, 1]), _fr, method="BFGS")["par"][1], "0x1.ffccab6f2bb5ep-1"),
    (lambda: st.fft(X)[0].real, "0x1.08ccccccccccdp+4"),
]


@pytest.mark.skipif(not EXACT, reason="Bitgleichheit setzt 80-Bit-long-double voraus")
@pytest.mark.parametrize("i", range(len(KNOWN)))
def test_known_values(i):
    f, hx = KNOWN[i]
    got = float(f())
    assert got == float.fromhex(hx), (got.hex(), hx)


def test_optim_counts_and_form():
    o = st.optim(np.array([-1.2, 1]), _fr, method="BFGS")
    assert list(o["counts"].index) == ["function", "gradient"]
    assert list(o["counts"]) == [118, 38]
    assert o["convergence"] == 0 and o["message"] is None


def test_quantile_names():
    q = st.quantile(X, [0, 0.013, 1 / 3, 1])
    assert isinstance(q, pd.Series)
    assert list(q.index) == ["0%", "1.3%", "33.33333%", "100%"]


def test_rank_order_one_based():
    v = np.array([3, 1, 4, 1, 5.0])
    assert list(st.order(v)) == [2, 4, 1, 3, 5]
    assert list(st.rank(v)) == [3, 1.5, 4, 1.5, 5]
    assert list(st.rank(v, ties_method="min")) == [3, 1, 4, 1, 5]


def test_sd_zero_warning():
    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        r = st.cor(X, np.ones(7))
    assert math.isnan(r)
    assert [str(m.message) for m in w] == ["the standard deviation is zero"]


def test_kendall_na_no_warning():
    M = np.column_stack([X, X[::-1], X * X])
    M[2, 0] = np.nan
    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        st.cor(M, method="kendall")
    assert not w


def test_r_nan_marking():
    assert fm._is_rnan(st.weighted_mean([1.0, 2.0], [0.0, 0.0]))
    assert not fm._is_rnan(st.weighted_mean([fm.NA_REAL, 2.0], [1.0, 1.0]))
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        r = st.cov2cor(np.array([[1, fm.NA_REAL], [fm.NA_REAL, -1.0]]))
    assert not fm._is_rnan(r[0, 1]) and math.isnan(r[0, 1])


def test_uniroot_errors():
    with pytest.raises(ValueError, match="f\\(\\) values at end points not of opposite sign"):
        st.uniroot(lambda t: t * t + 1, (-1, 2))


def test_lm_poly_names():
    d = pd.DataFrame({"forward": np.linspace(0, 1, 9) ** 2, "signal": np.linspace(0, 1, 9)})
    m = st.lm("forward ~ poly(signal, 1)", data=d)
    assert list(st.coef(m).index) == ["(Intercept)", "poly(signal, 1)"]
    m = st.lm("forward ~ poly(signal, 2)", data=d)
    assert list(st.coef(m).index) == ["(Intercept)", "poly(signal, 2)1", "poly(signal, 2)2"]


def test_fft_roundtrip():
    z = st.fft(st.fft(X), inverse=True) / X.size
    assert np.allclose(z.real, X) and np.allclose(z.imag, 0)


def test_base_helpers():
    M = np.array([[1.0, np.nan], [2.0, 3.0]])
    assert list(rb.colSums(M, na_rm=True)) == [3.0, 3.0]
    assert np.isnan(rb.rowMeans(M)[0])
    assert list(rb.cumprod([1, 2, np.nan, 3])[:2]) == [1.0, 2.0]
    assert list(rb.range([3, np.nan, 1], na_rm=True)) == [1.0, 3.0]
    assert list(rb.diff([1, 4, 9, 16], differences=2)) == [2.0, 2.0]
