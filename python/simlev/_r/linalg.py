"""Lineare Hilfen wie in R 4.3.3, die nach Etappe 9.6c bleiben.

==================  ==========================================================
R                   Python
==================  ==========================================================
``outer``, ``%o%``  :func:`outer`
``diag``            :func:`diag`
``isSymmetric``     :func:`is_symmetric`
``all.equal``       :func:`all_equal_numeric` (numerisch)
==================  ==========================================================

Dazu die Hilfen :class:`RError` (Fehler mit R's Meldungstext), ``_as_matrix``, ``_out`` und
``_vec_out`` für die übrigen ``_r``-Module.

Seit Etappe 9.6c rechnet SimLev Matrixprodukte, Cholesky, Dreieckslöser, SPD-Löser,
Eigenwerte und QR/kleinste Quadrate in der C-Bibliothek slc (:mod:`simlev._lib`, Entwurf
B.5–B.7). Die Nachbildungen von ``%*%``, ``crossprod``, ``solve``, ``chol``, ``backsolve``,
``determinant``, ``eigen`` und ``qr`` über Referenz-BLAS, LAPACK und LINPACK sind entfallen.

Eingaben: 2-D ``numpy``-Arrays oder ``pandas.DataFrame`` (Matrix, dimnames
aus Index/Spalten; ein ``RangeIndex`` gilt als „keine Namen“), 1-D-Arrays,
Listen, Skalare (Vektor), ``pandas.Series`` (benannter Vektor). Matrizen
werden als 2-D-``ndarray`` zurückgegeben, mit dimnames als ``DataFrame``.
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd

__all__ = ["outer", "diag", "is_symmetric", "all_equal_numeric", "RError"]

_DBL_EPS = 2.220446049250313e-16


class RError(ValueError):
    """Fehler mit R's Meldungstext (``conditionMessage``)."""


# ── Ein-/Ausgabe ──────────────────────────────────────────────────────────

class _M:
    """R-Objekt: Werte (spaltenweise), dim (oder None), dimnames, names."""

    __slots__ = ("v", "dim", "rn", "cn", "names", "is_int")

    def __init__(self, v, dim=None, rn=None, cn=None, names=None, is_int=False):
        self.v = v
        self.dim = dim
        self.rn = rn
        self.cn = cn
        self.names = names
        self.is_int = is_int

    @property
    def is_matrix(self):
        return self.dim is not None

    @property
    def length(self):
        return int(self.v.size)

    def mat(self):
        """Als n×p-Array (Fortran-Ordnung, Kopie)."""
        if self.dim is None:
            return np.asfortranarray(self.v.reshape(-1, 1)).copy()
        return np.array(self.v.reshape(self.dim, order="F"), dtype=np.float64, order="F")

    @property
    def has_dimnames(self):
        return self.rn is not None or self.cn is not None


def _names(idx):
    if idx is None or isinstance(idx, pd.RangeIndex):
        return None
    return [str(x) for x in idx]


def _as_r(x):
    if isinstance(x, _M):
        return x
    if isinstance(x, pd.DataFrame):
        a = x.to_numpy(dtype=np.float64)
        return _M(a.ravel(order="F").copy(), a.shape, _names(x.index), _names(x.columns))
    if isinstance(x, pd.Series):
        is_int = np.issubdtype(x.dtype, np.integer) or x.dtype == bool
        a = x.to_numpy(dtype=np.float64)
        nm = None if isinstance(x.index, pd.RangeIndex) else [str(i) for i in x.index]
        return _M(a.copy(), None, names=nm, is_int=is_int)
    a = np.asarray(x)
    is_int = np.issubdtype(a.dtype, np.integer) or a.dtype == bool
    a = a.astype(np.float64)
    if a.ndim == 0:
        return _M(a.reshape(1), None, is_int=is_int)
    if a.ndim == 1:
        return _M(a.copy(), None, is_int=is_int)
    if a.ndim == 2:
        return _M(a.ravel(order="F").copy(), a.shape, is_int=is_int)
    raise RError("arrays with more than 2 dimensions are not supported")


def _as_matrix(x):
    """``as.matrix``: Vektoren werden zu n×1 (names → rownames)."""
    m = _as_r(x)
    if m.dim is None:
        return _M(m.v, (m.length, 1), m.names, None, None, m.is_int)
    return m


def _out(Z, rn=None, cn=None):
    if rn is None and cn is None:
        return Z
    return pd.DataFrame(Z, index=rn, columns=cn)


def _vec_out(v, names=None):
    if names is None:
        return v
    return pd.Series(v, index=names)


# ── outer ─────────────────────────────────────────────────────────────────


def outer(X, Y, FUN="*"):
    """``outer(X, Y, FUN)``; ``FUN`` ``"*"`` (wie R über ein Matrixprodukt mit innerer Länge 1:
    jedes Element ist ``0 + x[i] * y[j]``, also ``+0`` statt ``-0``), ``"+"``, ``"-"``, ``"/"``,
    ``"^"`` oder eine vektorisierte Funktion."""
    mx = _as_r(X)
    my = _as_r(Y)
    dX = list(mx.dim) if mx.is_matrix else [mx.length]
    dY = list(my.dim) if my.is_matrix else [my.length]
    if isinstance(FUN, str) and FUN == "*":
        # Seit 9.6c ohne die Nachbildung der Referenz-BLAS: bei innerer Länge 1 ist das
        # Matrixprodukt genau die Summe 0 + Produkt (wie dgemm und R's simple_matprod).
        with np.errstate(all="ignore"):
            Z = 0.0 + np.multiply.outer(np.asarray(mx.v, dtype=np.float64), np.asarray(my.v, dtype=np.float64))
        flat = Z.ravel(order="F")
    else:
        yy = np.repeat(my.v, mx.length)
        xx = np.tile(mx.v, my.length) if mx.length else mx.v
        with np.errstate(all="ignore"):
            if FUN == "+":
                flat = xx + yy
            elif FUN == "-":
                flat = xx - yy
            elif FUN == "/":
                flat = xx / yy
            elif FUN == "^":
                from .rnum import r_pow
                flat = np.array([r_pow(a, b) for a, b in zip(xx.tolist(), yy.tolist())])
            elif callable(FUN):
                flat = np.asarray(FUN(xx, yy), dtype=np.float64)
            else:
                raise RError("unsupported FUN")
    dims = dX + dY
    if len(dims) == 2:
        Z = flat.reshape(dims, order="F")
        rn = mx.names if not mx.is_matrix else None
        cn = my.names if not my.is_matrix else None
        if mx.is_matrix or my.is_matrix:
            return Z
        return _out(Z, rn, cn)
    return flat.reshape(dims, order="F")


# ── Vergleich, Symmetrie ──────────────────────────────────────────────────

def all_equal_numeric(target, current, tolerance=1.4901161193847656e-08):
    """Kern von ``all.equal.numeric`` (ohne Attribute); ``True`` oder Text."""
    from .rnum import r_sum
    t = np.asarray(target, dtype=np.float64).ravel(order="F")
    c = np.asarray(current, dtype=np.float64).ravel(order="F")
    if t.size != c.size:
        return "Numeric: lengths (%d, %d) differ" % (t.size, c.size)
    out = np.isnan(t)
    if (out != np.isnan(c)).any():
        return "'is.NA' value mismatch: %d in current %d in target" % (int(np.isnan(c).sum()), int(out.sum()))
    with np.errstate(all="ignore"):
        out = out | (t == c)
        if out.all():
            return True
        keep = ~out
        t = t[keep]
        c = c[keep]
        N = t.size
        scale = r_sum(np.abs(t) / N)
        what = "relative"
        if not (math.isfinite(scale) and scale > tolerance):
            scale = 1.0
            what = "absolute"
        xy = r_sum(np.abs(t - c) / (N * scale))
    if math.isnan(xy) or xy > tolerance:
        return "Mean %s difference: %s" % (what, xy)
    return True


def is_symmetric(x, tol=100 * _DBL_EPS, tol1=None):
    """``isSymmetric.matrix(x, tol)``."""
    if tol1 is None:
        tol1 = 8 * tol
    m = _as_r(x)
    if not m.is_matrix:
        return False
    n, nc = m.dim
    if n != nc:
        return False
    A = m.mat()
    # dimnames: attr.all.equal(x, t(x)) verlangt dimnames(x) == rev(dimnames(x))
    if m.has_dimnames and m.rn != m.cn:
        return False
    if n > 1 and tol1 is not None:
        for i in sorted(set([1, 2, n - 1, n]), key=[1, 2, n - 1, n].index):
            if i < 1 or i > n:
                continue
            r = all_equal_numeric(A[i - 1, :], A[:, i - 1], tolerance=tol1)
            if r is not True:
                return False
    return all_equal_numeric(A, A.T, tolerance=tol) is True


# ── diag ──────────────────────────────────────────────────────────────────


def diag(x=1, nrow=None, ncol=None, names=True):
    """``diag(x, nrow, ncol)`` wie R."""
    if isinstance(x, (pd.DataFrame, np.ndarray)) and np.ndim(x) == 2:
        if nrow is not None or ncol is not None:
            raise RError("'nrow' or 'ncol' cannot be specified when 'x' is a matrix")
        m = _as_r(x)
        A = m.mat()
        mm = min(A.shape)
        if mm == 0:
            return np.zeros(0)
        y = A[np.arange(mm), np.arange(mm)].copy()
        if names and m.rn is not None and m.cn is not None and m.rn[:mm] == m.cn[:mm]:
            return pd.Series(y, index=m.rn[:mm])
        return y
    if np.ndim(x) == 0 and nrow is None and ncol is None:
        n = int(x)
        v = np.array([1.0])
    else:
        v = np.asarray(x, dtype=np.float64).ravel()
        n = v.size
    if nrow is not None:
        n = int(nrow)
    nc = n if ncol is None else int(ncol)
    if v.size == 0:
        raise RError("'x' must have positive length")
    out = np.zeros((n, nc))
    mn = min(n, nc)
    if mn > 0:
        out[np.arange(mn), np.arange(mn)] = np.resize(v, mn)
    return out


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
