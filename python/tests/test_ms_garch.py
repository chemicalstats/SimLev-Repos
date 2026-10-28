"""Tests der eigenen MS-GARCH-Schätzung (``simlev.ms_garch._ms_garch_fit``; Kern
``simlev._bootstrap_core.ms_garch_filter``) und der Verfahren "ms_garch",
"ms_ar_garch_m" und "tvtp_ms_garch" von ``bootstrap()``.

Port von ``r/tests/testthat/test-ms-garch.R``; die Datensätze werden mit dem
R-Zufallsgenerator (``simlev._r.rng``) genau wie dort simuliert.
"""
import contextlib
import io
import math
import warnings

import numpy as np
import pandas as pd
import pytest

import simlev
from simlev import _bootstrap_core as C
from simlev import ms_garch as M
from simlev._r import rng

MS_TRUE = {"om": np.array([2e-6, 2e-5]), "al": np.array([0.02, 0.05]), "ga": np.array([0.04, 0.10]),
           "be": np.array([0.92, 0.85]), "P": np.array([[0.99, 0.01], [0.03, 0.97]])}


def _sim_ms_gjr(n, om, al, ga, be, P, seed):
    """2-Regime-MS-GJR-GARCH nach Haas, Mittnik und Paolella (2004) wie ``sim_ms_gjr`` im R-Test."""
    rng.set_seed(seed)
    K = len(om)
    hk = om / (1 - al - ga / 2 - be)
    s = 1
    y = np.zeros(n)
    st = np.zeros(n, dtype=np.int64)
    for t in range(n):
        if t > 0:
            s = int(rng.sample_int(K, 1, prob=P[s - 1, :])[0])
            e = y[t - 1]
            hk = om + (al + ga * (1.0 if e < 0 else 0.0)) * (e * e) + be * hk
        st[t] = s
        y[t] = math.sqrt(hk[s - 1]) * float(rng.rnorm(1)[0])
    return y, st


@pytest.fixture(scope="module")
def ms_sim():
    p = MS_TRUE
    return _sim_ms_gjr(3000, p["om"], p["al"], p["ga"], p["be"], p["P"], 2)


def test_ms_garch_filter_follows_hamilton_recursion():
    rng.set_seed(1)
    y = np.asarray(rng.rnorm(50, 0, 0.01), dtype=np.float64)
    om = np.array([1e-6, 5e-6]); al = np.array([0.05, 0.1]); be = np.array([0.9, 0.8]); ga = np.array([0.02, 0.05])
    P = np.array([[0.95, 0.05], [0.1, 0.9]]); xi0 = np.array([2 / 3, 1 / 3]); h1 = float(np.var(y, ddof=1))
    f = C.ms_garch_filter(y, om, al, be, ga, P, xi0, h1)
    n = len(y)
    h = np.zeros((n, 2)); pred = np.zeros((n, 2)); filt = np.zeros((n, 2)); ll = 0.0; xi = xi0.copy()
    for t in range(n):
        h[t] = h1 if t == 0 else om + (al + ga * (y[t - 1] < 0)) * y[t - 1] ** 2 + be * h[t - 1]
        phi = np.exp(-0.5 * y[t] ** 2 / h[t]) / np.sqrt(2 * np.pi * h[t])
        pred[t] = xi
        ft = np.sum(xi * phi)
        filt[t] = xi * phi / ft
        ll += math.log(ft)
        xi = P.T @ filt[t]
    np.testing.assert_allclose(f["h"], h, rtol=1e-14)
    np.testing.assert_allclose(f["pred"], pred, rtol=1e-12)
    np.testing.assert_allclose(f["filt"], filt, rtol=1e-12)
    assert f["loglik"] == pytest.approx(ll, rel=1e-12)
    np.testing.assert_allclose(f["lB"], -0.5 * y.reshape(-1, 1) ** 2 / h - 0.5 * np.log(2 * np.pi * h), rtol=1e-12)
    # Nicht endliche Dichte -> loglik = -Inf
    assert C.ms_garch_filter(y, [-1, -1], [0, 0], [0, 0], [0, 0], P, xi0, -1)["loglik"] == -math.inf


def test_ms_garch_fit_deterministic_and_consistent(ms_sim):
    y = ms_sim[0][:1000]
    rng.set_seed(123)
    s0 = rng.get_random_seed()
    f1 = M._ms_garch_fit(y, 2, "gjrGARCH")
    assert np.array_equal(rng.get_random_seed(), s0)
    f2 = M._ms_garch_fit(y, 2, "gjrGARCH")
    assert list(f1) == ["omega", "alpha", "beta", "gamma", "P", "regimes", "s2", "loglik", "convergence"]
    for k in f1:
        assert np.array_equal(np.asarray(f1[k]), np.asarray(f2[k]))
    for model, K in (("gjrGARCH", 2), ("sGARCH", 2), ("sGARCH", 3)):
        f = f1 if (model, K) == ("gjrGARCH", 2) else M._ms_garch_fit(y, K, model)
        assert len(f["s2"]) == len(y) and np.all(np.isfinite(f["s2"]) & (f["s2"] > 0))
        assert f["P"].shape == (K, K) and np.allclose(f["P"].sum(axis=1), 1, atol=1e-12) and np.all(f["P"] >= 0)
        unc = f["omega"] / (1 - f["alpha"] - f["gamma"] / 2 - f["beta"])
        assert np.all(np.diff(unc) >= 0)
        assert math.isfinite(f["loglik"])
        assert f["regimes"].dtype.kind == "i" and len(f["regimes"]) == len(y)
        assert set(f["regimes"].tolist()) <= set(range(1, K + 1))
        assert np.all(f["alpha"] + f["gamma"] / 2 + f["beta"] < 1)
        if model == "sGARCH":
            assert np.array_equal(f["gamma"], np.zeros(K))


def test_ms_garch_fit_recovers_known_parameters(ms_sim):
    # Grenzen wie im R-Test (Probelauf in R: Verhältnisse 1.074 bzw. 1.146, Diagonale 0.9921 / 0.9742)
    p = MS_TRUE
    y, s = ms_sim
    f = M._ms_garch_fit(y, 2, "gjrGARCH")
    ratio = (f["omega"] / (1 - f["alpha"] - f["gamma"] / 2 - f["beta"])) / (p["om"] / (1 - p["al"] - p["ga"] / 2 - p["be"]))
    assert 0.75 < ratio[0] < 1.25 and 0.6 < ratio[1] < 1.7, ratio
    assert abs(f["P"][0, 0] - 0.99) < 0.01 and abs(f["P"][1, 1] - 0.97) < 0.04
    assert np.mean(f["regimes"] == s) > 0.8
    assert f["convergence"] == 0


def test_ms_garch_fit_rejects_other_models_and_regime_numbers():
    y = np.linspace(-0.01, 0.01, 300)
    with pytest.raises(ValueError, match=r'muss "sGARCH" oder "gjrGARCH" sein \(erhalten: eGARCH\)'):
        M._ms_garch_fit(y, 2, "eGARCH")
    with pytest.raises(ValueError, match="ganze Zahl >= 2"):
        M._ms_garch_fit(y, 1, "sGARCH")
    with pytest.raises(ValueError, match=r"ganze Zahl >= 2 sein \(erhalten: 2.5\)"):
        M._ms_garch_fit(y, 2.5, "sGARCH")


def test_ms_garch_methods_run_end_to_end(ms_sim):
    n = 600
    us = 1 + 3e-4 + ms_sim[0][:n]
    rng.set_seed(4)
    d = pd.DataFrame({"us": us, "eu": us * (1 + np.asarray(rng.rnorm(n, 0, 0.004), dtype=np.float64))})
    cfg = simlev.bootstrap_config({"us": "us", "eu": "eu"}, regime_index="us")

    def run(method, params=None):
        buf = io.StringIO()
        with warnings.catch_warnings(), contextlib.redirect_stderr(buf):
            warnings.simplefilter("ignore")
            b = simlev.bootstrap(d, cfg, method, n=2, seed=1, progress=False, params=params or {})
        return b, buf.getvalue()

    for m in ("ms_garch", "ms_ar_garch_m", "tvtp_ms_garch"):
        b, _ = run(m)
        assert len(b["paths"]) == 2
        P1 = np.asarray(b["paths"][0], dtype=np.float64)
        assert P1.shape == (n + 1, 2) and np.all(np.isfinite(P1)), m
        b2, _ = run(m)
        for a, c in zip(b["paths"], b2["paths"]):
            assert np.array_equal(np.asarray(a), np.asarray(c))
    _, msg = run("ms_garch", {"ms_garch_model": "sGARCH"})
    assert "MS-GARCH(2, sGARCH): P(stay)" in msg
    with pytest.raises(ValueError, match="Vorberechnung fehlgeschlagen: MS-GARCH: Varianzmodell"):
        run("ms_garch", {"ms_garch_model": "eGARCH"})
    with pytest.raises(ValueError, match="ganze Zahl >= 2"):
        run("tvtp_ms_garch", {"tvtp_n_regimes": 1})
