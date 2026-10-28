"""Rauchprobe der Optimierer der C-Bibliothek slc (Etappe 9.3): läuft immer, auch ohne
SIMLEV_LEGACY_TESTS. Gegenstück zu r/tests/etappe93-opt.R und julia/test/etappe93_opt.jl; die
Gleichheit mit R und Julia prüft tools/gleichlauf/."""
import math

import numpy as np
import pytest

import simlev._lib as L


def fr(x):
    return L.opt_testfn(1, x)


def gr(x):
    return L.opt_testfn(1, x, True)[1]


@pytest.mark.parametrize("method", ["Nelder-Mead", "BFGS", "L-BFGS-B"])
def test_rosenbrock_und_c_weg(method):
    o = L.optim([-1.2, 1.0], fr, method=method)
    assert o["convergence"] == 0 and o["value"] < 1e-12 and np.max(np.abs(o["par"] - 1)) < 1e-5
    assert list(o["counts"]) == ["function", "gradient"]
    assert (o["counts"]["gradient"] is None) == (method == "Nelder-Mead")
    c = L.minimize_test(1, [-1.2, 1.0], method)
    assert np.array_equal(c["par"], o["par"]) and c["value"] == o["value"] and c["evaluations"] == o["evaluations"]


def test_gradient_schranken_steuerwerte():
    o = L.optim([-1.2, 1.0], fr, gr, method="BFGS")
    assert o["convergence"] == 0 and o["value"] < 1e-15 and o["evaluations"] == o["counts"]["function"]
    o = L.optim(np.zeros(4), lambda x: L.opt_testfn(8, x), method="L-BFGS-B", lower=-1, upper=1)
    assert o["convergence"] == 0 and list(o["par"]) == [1.0, -1.0, 1.0, -1.0] and abs(o["value"] - 2.5) < 1e-14
    o = L.optim([-1.2, 1.0], fr, control={"maxit": 10})
    assert o["convergence"] == 1 and o["counts"]["function"] == 10
    o = L.optim([1.0, 1.0], lambda x: 3 - (x[0] - 2) ** 2 - (x[1] + 1) ** 2, method="BFGS", control={"fnscale": -1})
    assert abs(o["value"] - 3) < 1e-12 and np.max(np.abs(o["par"] - [2, -1])) < 1e-6


def test_nan_und_fehler():
    o = L.optim([3.0, 3.0, 3.0], lambda x: L.opt_testfn(7, x), method="BFGS")
    assert o["convergence"] == 0 and abs(o["value"] - sum(1 + math.log(k) for k in (1, 2, 3))) < 1e-10
    with pytest.raises(ValueError, match="^BFGS: Zielfunktion am Startwert nicht endlich$"):
        L.optim([1.0, 1.0], lambda x: math.nan, method="BFGS")
    with pytest.raises(ValueError, match=r"^optim: Schranken nur mit L-BFGS-B bzw. PBFGS \(nicht BFGS\)$"):
        L.optim([1.0, 1.0], fr, method="BFGS", lower=0.0)
    with pytest.raises(ValueError, match="^optim: unbekannte Steuerwerte 'abstol'$"):
        L.optim([1.0, 1.0], fr, control={"abstol": 1})


def test_numgrad():
    x = [0.3, -0.7, 1.1]
    assert np.max(np.abs(L.numgrad_test(1, x) - L.opt_testfn(1, x, True)[1])) < 1e-6
    assert L.numgrad_test(8, [1.0, 2.0], [1.0, -math.inf], [1.0, math.inf])[0] == 0.0
