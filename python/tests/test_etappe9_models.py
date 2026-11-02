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
    # N3: analytischer GJR-Gradient gegen zentrale Differenzen (Schritt 1e-5 max(|x|, 1), mu in Einheiten von sd(e))
    tg = np.array([3e-4, -13.1, -3.2, -4.5, 2.0])
    sc = np.array([np.std(e, ddof=1), 1, 1, 1, 1])
    gg = L.garch11_grad(tg, e)
    gq = np.empty(5)
    for i in range(5):
        h = 1e-5 * max(abs(tg[i] / sc[i]), 1.0) * sc[i]
        a, b = tg.copy(), tg.copy()
        a[i] += h
        b[i] -= h
        gq[i] = (L.garch11_grad(a, e)["value"] - L.garch11_grad(b, e)["value"]) / (2 * h)
    assert np.max(np.abs(gg["gradient"] - gq) * sc) < 1e-5 * max(np.max(np.abs(gq * sc)), 1.0)
    # N4: dasselbe für sGARCH (theta = (mu, log omega, a, b))
    ts = np.array([3e-4, -13.1, -2.6, 2.3])
    ss = sc[:4]
    gs = L.garch11_grad(ts, e, False)
    gq = np.empty(4)
    for i in range(4):
        h = 1e-5 * max(abs(ts[i] / ss[i]), 1.0) * ss[i]
        a, b = ts.copy(), ts.copy()
        a[i] += h
        b[i] -= h
        gq[i] = (L.garch11_grad(a, e, False)["value"] - L.garch11_grad(b, e, False)["value"]) / (2 * h)
    assert len(gs["gradient"]) == 4
    assert np.max(np.abs(gs["gradient"] - gq) * ss) < 1e-5 * max(np.max(np.abs(gq * ss)), 1.0)
    i1 = L.boot_idx_stationary(300, 50, 10, stream=L.Stream(1))
    i2 = L.boot_idx_stationary(300, 50, 10, stream=L.Stream(1))
    assert np.array_equal(i1, i2) and i1.min() >= 1 and i1.max() <= 300
    with pytest.raises(ValueError, match="block_length"):
        L.boot_idx_block(10, 5, 20, False, stream=s)


def test_n5_backcast_obj_grad_fit():
    """N5: Backcast-Zielfunktion in C mit analytischem Gradienten, Fit (wie r/tests/etappe94-models.R)."""
    rng = np.random.default_rng(3)
    bx = rng.normal(3e-4, 0.01, 300)
    bpos = np.sort(rng.choice(np.arange(1, 301), 250, replace=False)).astype(np.int32)
    bpos[0] = 1
    bl = (np.log(50) + np.cumsum(np.log1p(2.01 * bx - 4e-5 + rng.normal(0, 2e-4, 300))))[bpos - 1]
    pr = (bx, np.full(300, -1 / 36000), np.full(300, 0.5 / 36500), 2.0, np.full(300, 1 / 36000), np.full(300, 1 / 36500),
          bpos, bl, (3, 1, 2), 0.3)
    th = np.array([0.7, 0.3, 1.01])
    gb = L.backcast_obj(pr, th, [1, 2, 3], True)
    gq = np.zeros(3)
    for i in range(3):
        h = 1e-6 * max(abs(th[i]), 1.0)
        a, b = th.copy(), th.copy()
        a[i] += h
        b[i] -= h
        gq[i] = (L.backcast_obj(pr, a, [1, 2, 3])["value"] - L.backcast_obj(pr, b, [1, 2, 3])["value"]) / (2 * h)
    assert np.max(np.abs(gb["gradient"] - gq)) < 1e-6 * np.max(np.abs(gq))
    fb = L.backcast_fit(pr, [0.0, 0.0, 1.0], [1, 2, 3], [-10.0, -5.0, 0.5], [10.0, 10.0, 1.5])
    assert fb["convergence"] == 0 and fb["value"] <= gb["value"]
