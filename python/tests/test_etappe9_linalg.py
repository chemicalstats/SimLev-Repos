"""Rauchprobe der Etappe 9.2 der C-Bibliothek slc (lineare Algebra, Matrixprodukt, kleinste Quadrate,
Stineman, Glättungsspline, Kerndichte): läuft immer, auch ohne SIMLEV_LEGACY_TESTS. Gegenstück zu
r/tests/etappe92-smoke.R und julia/test/etappe92_smoke.jl; die Gleichheit der Sprachen prüft
tools/gleichlauf/ (Modul slc_linalg)."""
import math
import warnings

import numpy as np
import pytest

import simlev._lib as L


def test_chol_solve_eigen():
    a = np.array([[4.0, 2.0], [2.0, 3.0]])
    r = L.chol(a)
    assert np.array_equal(r, np.array([[2.0, 1.0], [0.0, math.sqrt(2.0)]]))
    assert np.allclose(L.solve_spd(a, [1.0, 2.0]), [-0.125, 0.75], rtol=0, atol=1e-15)
    assert np.allclose(L.solve_spd(a) @ a, np.eye(2), atol=1e-15)
    assert abs(L.logdet_spd(a) - math.log(8.0)) < 1e-15
    e = L.eigen_sym(a)
    assert np.allclose(e["values"], [(7 + math.sqrt(17)) / 2, (7 - math.sqrt(17)) / 2], atol=1e-15)
    assert e["vectors"].shape == (2, 2) and L.eigen_sym(a, only_values=True)["vectors"] is None
    with pytest.raises(ValueError, match=r"^chol: Matrix nicht positiv definit \(führende Minore der Ordnung 2\)$"):
        L.chol(np.array([[1.0, 2.0], [2.0, 1.0]]))
    with pytest.raises(ValueError, match="^solve: Matrix numerisch singulär$"):
        L.solve_spd(np.diag([1e20, 1.0]), [1.0, 2.0])


def test_matmul_lsfit_logit():
    x = np.arange(1.0, 7.0).reshape((2, 3), order="F")
    assert np.array_equal(L.matmul(x, x.T), x @ x.T) and np.array_equal(L.crossprod(x), x.T @ x)
    assert L.matmul([1.0, 2.0, 3.0], [1.0, 2.0, 3.0]).tolist() == [[14.0]]
    with pytest.raises(ValueError, match="^%m%: nicht passende Argumente$"):
        L.matmul(x, x)
    t = np.arange(1.0, 6.0)
    f = L.lsfit(np.c_[np.ones(5), t, 2 * t], [1.0, 3.0, 2.0, 5.0, 4.0])
    assert f["rank"] == 2 and f["pivot"].tolist() == [1, 2, 3] and math.isnan(f["coefficients"][2])
    assert np.allclose(f["coefficients"][:2], [0.6, 0.8], atol=1e-14)
    g = L.logit_irls(np.c_[np.ones(6), np.arange(1.0, 7.0)], [0.0, 0.0, 1.0, 0.0, 1.0, 1.0])
    assert g["converged"]
    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        L.logit_irls(np.c_[np.ones(6), [-2.0, -1.0, -0.5, 0.5, 1.0, 2.0]], [0.0, 0.0, 0.0, 1.0, 1.0, 1.0])
    assert [str(m.message) for m in w] == ["glm: angepasste Wahrscheinlichkeiten numerisch 0 oder 1"]


def test_stineman_spline_kde():
    s = L.stineman([1.0, 2.0, 4.0], [1.0, 3.0, 2.0], [1.0, 1.5, 4.0, 5.0])
    assert s[0] == 1.0 and s[2] == 2.0 and math.isnan(s[3]) and 1 < s[1] < 3
    sp = L.smspline_fit(np.arange(1.0, 11.0), np.sin(np.arange(1.0, 11.0)))
    assert len(sp["x"]) == 10 and 2 < sp["df"] < 10 and sp["gam"][0] == 0.0
    with pytest.raises(ValueError, match="^smooth.spline: mindestens 4 verschiedene x-Werte$"):
        L.smspline_fit([1.0, 2.0, 3.0, 3.0], [1.0, 2.0, 3.0, 4.0])
    k = L.kde([-1.0, 0.0, 2.0, 3.0, 3.5])
    assert len(k["x"]) == 512 and abs(k["y"].sum() * (k["x"][1] - k["x"][0]) - 1) < 1e-3
