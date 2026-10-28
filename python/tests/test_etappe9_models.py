"""Rauchprobe der Modelle der C-Bibliothek slc (Etappe 9.4): läuft immer, auch ohne
SIMLEV_LEGACY_TESTS. Gegenstück zu r/tests/etappe94-models.R und julia/test/etappe94_models.jl; die
Gleichheit mit R und Julia prüft tools/gleichlauf/."""
import numpy as np
import pytest

import simlev._lib as L


def _garch():
    s = L.Stream(7)
    z = L.rnorm(1500, stream=s)
    e = np.empty(1500)
    v, ep = 1e-4, 0.0
    for t in range(1500):
        if t > 0:
            v = 2e-6 + 0.08 * ep * ep + 0.9 * v
        ep = np.sqrt(v) * z[t]
        e[t] = 3e-4 + ep
    return e, s


def test_garch():
    e, _ = _garch()
    f = L.garch11_fit(e)
    assert f["convergence"] == 0 and abs(f["alpha"] - 0.08) < 0.05 and abs(f["beta"] - 0.9) < 0.05
    assert abs(f["loglik"] + L.garch11_nll(e, [f["mu"], f["omega"], f["alpha"], f["beta"]])) < 1e-8
    g = L.fit_garch11(e, gjr=True)
    assert g["method"] == "ml" and g["alpha"] + g["gamma"] >= 0  # N1: gamma < 0 zulässig
    assert L.fit_garch11(np.full(30, 1e-3))["method"] == "konstant"
    with pytest.warns(UserWarning, match="ML-Sch"):
        L.fit_garch11(e[:6])
    with pytest.raises(ValueError, match="zu wenige"):
        L.garch11_fit(e[:9])


def test_gpd_dcc_ms_boot():
    e, s = _garch()
    x = 0.01 * np.expm1(-0.2 * np.log(L.runif(400, stream=s))) / 0.2
    p = L.gpd_fit(x)
    assert p["convergence"] == 0 and abs(p["shape"] - 0.2) < 0.15
    Z = L.rnorm(600, stream=s).reshape(300, 2, order="F")
    d = L.dcc_fit(Z, np.corrcoef(Z.T))
    assert d["a"] >= 0 and d["b"] >= 0 and d["a"] + d["b"] < 0.999
    m = L.ms_garch_fit(e[:600], 2, "sGARCH")
    assert np.isfinite(m["loglik"]) and set(np.unique(m["regimes"])) <= {1, 2}
    # N1: analytischer Gradient gegen zentrale Differenzen (Schritt 1e-5 max(|x|, 1))
    th = L.ms_garch_starts(e[:600], 2, "gjrGARCH", all=True)[:, 2]
    gr = L.ms_garch_grad(th, e[:600], 2, "gjrGARCH")
    gn = np.empty(th.size)
    for i in range(th.size):
        h = 1e-5 * max(abs(th[i]), 1.0)
        a, b = th.copy(), th.copy()
        a[i] += h
        b[i] -= h
        gn[i] = (L.ms_garch_nll(a, e[:600], 2, "gjrGARCH") - L.ms_garch_nll(b, e[:600], 2, "gjrGARCH")) / (2 * h)
    assert gr["value"] == L.ms_garch_nll(th, e[:600], 2, "gjrGARCH")
    assert np.max(np.abs(gr["gradient"] - gn)) < 1e-5 * max(np.max(np.abs(gn)), 1.0)
    i1 = L.boot_idx_stationary(300, 50, 10, stream=L.Stream(1))
    i2 = L.boot_idx_stationary(300, 50, 10, stream=L.Stream(1))
    assert np.array_equal(i1, i2) and i1.min() >= 1 and i1.max() <= 300
    with pytest.raises(ValueError, match="block_length"):
        L.boot_idx_block(10, 5, 20, False, stream=s)
