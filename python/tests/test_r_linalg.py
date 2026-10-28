"""Selbsttest für simlev._r.linalg (und die internen BLAS/LAPACK/LINPACK-Ports).

Die vollständige Bitgleichheit prüfen die Referenzfälle in
``golden/modules/r_linalg`` (Generator ``golden/modules/gen_r_linalg.R``,
``tools/compare_reference.py r_linalg``) in ``test_module_reference.py``.
"""
import numpy as np
import pytest

import simlev._r.linalg as la
from simlev._r import _lapack

A3 = np.array([[2, 3, 4], [1, 0.5, 2], [1, 1, 7.0]])
S2 = np.array([[2, 1], [1, 3.0]])

# Werte aus R 4.3.3: sprintf("%a", ...)
KNOWN = [
    (lambda: la.det(A3), "-0x1.3ffffffffffffp+3"),
    (lambda: la.solve(S2)[0, 0], "0x1.3333333333333p-1"),
    (lambda: la.solve(S2)[1, 0], "-0x1.999999999999ap-3"),
    (lambda: la.chol(np.array([[4, 2], [2, 3.0]]))[1, 1], "0x1.6a09e667f3bcdp+0"),
    (lambda: la.eigen(S2, only_values=True)["values"][0], "0x1.cf1bbcdcbfa54p+1"),
    (lambda: la.eigen(S2, only_values=True)["values"][1], "0x1.61c8864680b58p+0"),
]


@pytest.mark.parametrize("i", range(len(KNOWN)))
def test_known_values(i):
    f, hx = KNOWN[i]
    got = float(f())
    assert got == float.fromhex(hx), (got.hex(), hx)


def test_eigen_values_pure_port_matches_backend():
    rng = np.random.default_rng(5)
    G = rng.standard_normal((60, 40))
    S = G.T @ G
    w, info = _lapack.dsyevr_values(S.copy(order="F"))
    assert info == 0
    if _lapack.system_lapack() is not None:
        w2, _, info2, backend = _lapack.dsyevr(S.copy(order="F"), only_values=True, backend="system")
        assert info2 == 0 and np.array_equal(w, w2)


def test_eigen_order_and_shape():
    e = la.eigen(np.diag([2.0, 5, 2, 1]))
    assert list(e["values"]) == [5, 2, 2, 1]
    assert e["vectors"].shape == (4, 4)


def test_solve_singular_message():
    with pytest.raises(ValueError, match="Lapack routine dgesv: system is exactly singular: U\\[1,1\\] = 0"):
        la.solve(np.zeros((3, 3)))


def test_chol_not_pd():
    with pytest.raises(ValueError, match="leading minor of order 2 is not positive"):
        la.chol(np.array([[1, 2], [2, 1.0]]))


def test_qr_rank_and_pivot():
    X = np.column_stack([np.ones(6), np.arange(6.0), 2 * np.arange(6.0)])
    q = la.qr(X)
    assert q["rank"] == 2
    assert list(q["pivot"]) == [1, 2, 3]


def test_matprod_shapes():
    assert la.matprod(np.ones(3), np.ones(3)).shape == (1, 1)
    assert la.crossprod(np.ones((4, 2))).shape == (2, 2)
    with pytest.raises(ValueError, match="non-conformable arguments"):
        la.matprod(np.ones((2, 3)), np.ones((2, 3)))
