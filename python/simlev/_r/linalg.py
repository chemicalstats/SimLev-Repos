"""Lineare Algebra wie in R 4.3.3 (Referenz-BLAS/LAPACK 3.12), bitgleich.

Abbildung der R-Funktionen:

==================  ==========================================================
R                   Python
==================  ==========================================================
``x %*% y``         :func:`matprod` (``R_Matprod = "default"``: bei NaN/Inf
                    ``simple_matprod``, sonst ``dgemm``/``dgemv``)
``crossprod``       :func:`crossprod` (``dsyrk`` + Spiegeln bzw. ``dgemm``)
``tcrossprod``      :func:`tcrossprod`
``outer``, ``%o%``  :func:`outer`
``solve``           :func:`solve` (``dgesv`` + ``dgecon``), ``solve_qr``
``chol``            :func:`chol` (``dpotrf``, ``pivot = FALSE``)
``chol2inv``        :func:`chol2inv` (``dpotri``)
``backsolve``       :func:`backsolve`, :func:`forwardsolve` (``dtrsm``)
``determinant``     :func:`determinant` (``dgetrf``), :func:`det`
``eigen``           :func:`eigen` (symmetrisch, ``La_rs`` → ``dsyevr``)
``qr``              :func:`qr` (LINPACK ``dqrdc2``), :func:`qr_coef`,
                    :func:`qr_qty`, :func:`qr_qy`, :func:`qr_resid`,
                    :func:`qr_fitted`, :func:`qr_solve`, :func:`qr_R`,
                    :func:`qr_Q`
``diag``            :func:`diag`
``isSymmetric``     :func:`is_symmetric`
==================  ==========================================================

Eingaben: 2-D ``numpy``-Arrays oder ``pandas.DataFrame`` (Matrix, dimnames
aus Index/Spalten; ein ``RangeIndex`` gilt als „keine Namen“), 1-D-Arrays,
Listen, Skalare (Vektor), ``pandas.Series`` (benannter Vektor). Matrizen
werden als 2-D-``ndarray`` zurückgegeben, mit dimnames als ``DataFrame``.
``pivot`` von :func:`qr` ist wie in R 1-basiert.

Alle Kernroutinen (BLAS, ``dpotrf``, ``dgetrf``, ``dgecon``, ``dpotri``,
LINPACK, Eigenwerte ohne Vektoren) sind reine numpy-Ports und unabhängig von
einer System-Bibliothek bitgleich. Nur ``eigen(..., only_values=False)`` ruft
``dsyevr`` der System-Referenz-LAPACK über ``ctypes`` auf (siehe
:mod:`simlev._r._lapack`); fehlt sie, rechnet numpy (mit Warnung) und
Bitgleichheit ist nicht garantiert.
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd

from . import _blas as B
from . import fmt as _fmt
from . import _lapack as LA
from . import _linpack as LP
from .rlist import RList

__all__ = ["matprod", "crossprod", "tcrossprod", "outer", "solve", "solve_qr", "chol",
           "chol2inv", "backsolve", "forwardsolve", "determinant", "det", "eigen",
           "qr", "qr_coef", "qr_qty", "qr_qy", "qr_resid", "qr_fitted", "qr_solve", "qr_R",
           "qr_Q", "diag", "is_symmetric", "all_equal_numeric", "RError"]

_DBL_EPS = 2.220446049250313e-16


class RError(ValueError):
    """Fehler mit R's Meldungstext (``conditionMessage``)."""


class RQR(RList):
    """Ergebnis von :func:`qr` (R-Klasse ``qr``)."""
    r_class = ("qr",)


class REigen(RList):
    r_class = ("eigen",)


class RDet(RList):
    r_class = ("det",)


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


# ── Matrixprodukte ────────────────────────────────────────────────────────

def _may_have_nan_or_inf(v):
    """``mayHaveNaNOrInf`` aus array.c (ungenau: Summe benachbarter Paare)."""
    n = v.size
    if n == 0:
        return False
    with np.errstate(all="ignore"):
        if (n & 1) and not math.isfinite(v[0]):
            return True
        a = v[n & 1:]
        s = a[0::2] + a[1::2]
        return not bool(np.isfinite(s).all())


def _simple(X, Y):
    """``Z[i,k] = sum_j X[i,j]*Y[j,k]`` in double (sequenziell)."""
    return B.seqdot(np.ascontiguousarray(X.T), Y)


def _matprod_core(X, Y):
    nrx, ncx = X.shape
    nry, ncy = Y.shape
    if nrx == 0 or ncx == 0 or nry == 0 or ncy == 0:
        return np.zeros((nrx, ncy))
    xv = X.ravel(order="F")
    yv = Y.ravel(order="F")
    if _may_have_nan_or_inf(xv) or _may_have_nan_or_inf(yv):
        return _simple(X, Y)
    Z = np.zeros((nrx, ncy), order="F")
    if ncy == 1:
        z = np.zeros(nrx)
        B.dgemv("N", 1.0, X, Y[:, 0], 0.0, z)
        Z[:, 0] = z
    elif nrx == 1:
        z = np.zeros(ncy)
        B.dgemv("T", 1.0, Y, X[0, :], 0.0, z)
        Z[0, :] = z
    else:
        B.dgemm("N", "N", 1.0, X, Y, 0.0, Z)
    return Z


def matprod(x, y):
    """``x %*% y`` wie R 4.3 (``matprod``, Voreinstellung ``"default"``)."""
    mx = _as_r(x)
    my = _as_r(y)
    if not mx.is_matrix and not my.is_matrix:
        nry = my.length
        ncy = 1
        nrx = 1
        ncx = mx.length
        if ncx == 1:
            ncy = nry
            nry = 1
    elif not mx.is_matrix:
        nry, ncy = my.dim
        nrx = ncx = 0
        if mx.length == nry:
            nrx, ncx = 1, nry
        elif nry == 1:
            nrx, ncx = mx.length, 1
    elif not my.is_matrix:
        nrx, ncx = mx.dim
        nry = ncy = 0
        if my.length == ncx:
            nry, ncy = ncx, 1
        elif ncx == 1:
            nry, ncy = 1, my.length
    else:
        nrx, ncx = mx.dim
        nry, ncy = my.dim
    if ncx != nry:
        raise RError("non-conformable arguments")
    X = np.asfortranarray(mx.v.reshape((nrx, ncx), order="F"))
    Y = np.asfortranarray(my.v.reshape((nry, ncy), order="F"))
    with np.errstate(all="ignore"):
        Z = _matprod_core(X, Y)
    rn = mx.rn if mx.is_matrix else None
    cn = my.cn if my.is_matrix else None
    return _out(Z, rn, cn)


def _sym_dims_cross(m):
    if m.is_matrix:
        return m.dim
    if m.length == 1:
        return 1, 1
    return m.length, 1


def crossprod(x, y=None):
    """``crossprod(x, y)`` = ``t(x) %*% y`` wie R (``dsyrk`` bei ``y = NULL``)."""
    mx = _as_r(x)
    sym = y is None
    my = mx if sym else _as_r(y)
    if not mx.is_matrix and not my.is_matrix:
        if mx.length == 1:
            nrx = ncx = nry = 1
            ncy = my.length
        else:
            nry, ncy = my.length, 1
            nrx, ncx = mx.length, 1
    elif not mx.is_matrix:
        nry, ncy = my.dim
        nrx = ncx = 0
        if mx.length == nry:
            nrx, ncx = nry, 1
    elif not my.is_matrix:
        nrx, ncx = mx.dim
        nry = ncy = 0
        if my.length == nrx:
            nry, ncy = nrx, 1
        elif nrx == 1:
            nry, ncy = 1, my.length
    else:
        nrx, ncx = mx.dim
        nry, ncy = my.dim
    if nrx != nry:
        raise RError("non-conformable arguments")
    X = np.asfortranarray(mx.v.reshape((nrx, ncx), order="F"))
    with np.errstate(all="ignore"):
        if sym:
            Z = _symcrossprod(X)
        else:
            Y = np.asfortranarray(my.v.reshape((nry, ncy), order="F"))
            Z = _crossprod_core(X, Y)
    rn = mx.cn if mx.is_matrix else None
    cn = my.cn if my.is_matrix else None
    return _out(Z, rn, cn)


def _symcrossprod(X):
    nr, nc = X.shape
    if nr == 0 or nc == 0:
        return np.zeros((nc, nc))
    if _may_have_nan_or_inf(X.ravel(order="F")):
        return B.seqdot(X, X)
    Z = np.zeros((nc, nc), order="F")
    B.dsyrk("U", "T", 1.0, X, 0.0, Z)
    il = np.tril_indices(nc, -1)
    Z[il] = Z.T[il]
    return Z


def _crossprod_core(X, Y):
    nrx, ncx = X.shape
    nry, ncy = Y.shape
    if nrx == 0 or ncx == 0 or nry == 0 or ncy == 0:
        return np.zeros((ncx, ncy))
    if _may_have_nan_or_inf(X.ravel(order="F")) or _may_have_nan_or_inf(Y.ravel(order="F")):
        return B.seqdot(X, Y)
    Z = np.zeros((ncx, ncy), order="F")
    if ncy == 1:
        z = np.zeros(ncx)
        B.dgemv("T", 1.0, X, Y[:, 0], 0.0, z)
        Z[:, 0] = z
    elif ncx == 1:
        z = np.zeros(ncy)
        B.dgemv("T", 1.0, Y, X[:, 0], 0.0, z)
        Z[0, :] = z
    else:
        B.dgemm("T", "N", 1.0, X, Y, 0.0, Z)
    return Z


def tcrossprod(x, y=None):
    """``tcrossprod(x, y)`` = ``x %*% t(y)`` wie R (``dsyrk`` bei ``y = NULL``)."""
    mx = _as_r(x)
    sym = y is None
    my = mx if sym else _as_r(y)
    if not mx.is_matrix and not my.is_matrix:
        nry, ncy = my.length, 1
        nrx, ncx = mx.length, 1
    elif not mx.is_matrix:
        nry, ncy = my.dim
        nrx = ncx = 0
        if mx.length == ncy:
            nrx, ncx = 1, ncy
        elif ncy == 1:
            nrx, ncx = mx.length, 1
    elif not my.is_matrix:
        nrx, ncx = mx.dim
        if nrx == 1:
            nry, ncy = 1, my.length
        else:
            nry, ncy = my.length, 1
    else:
        nrx, ncx = mx.dim
        nry, ncy = my.dim
    if ncx != ncy:
        raise RError("non-conformable arguments")
    X = np.asfortranarray(mx.v.reshape((nrx, ncx), order="F"))
    with np.errstate(all="ignore"):
        if sym:
            Z = _symtcrossprod(X)
        else:
            Y = np.asfortranarray(my.v.reshape((nry, ncy), order="F"))
            Z = _tcrossprod_core(X, Y)
    rn = mx.rn if mx.is_matrix else None
    cn = my.rn if my.is_matrix else None
    return _out(Z, rn, cn)


def _symtcrossprod(X):
    nr, nc = X.shape
    if nr == 0 or nc == 0:
        return np.zeros((nr, nr))
    if _may_have_nan_or_inf(X.ravel(order="F")):
        Xt = np.ascontiguousarray(X.T)
        return B.seqdot(Xt, Xt)
    Z = np.zeros((nr, nr), order="F")
    B.dsyrk("U", "N", 1.0, X, 0.0, Z)
    il = np.tril_indices(nr, -1)
    Z[il] = Z.T[il]
    return Z


def _tcrossprod_core(X, Y):
    nrx, ncx = X.shape
    nry, ncy = Y.shape
    if nrx == 0 or ncx == 0 or nry == 0 or ncy == 0:
        return np.zeros((nrx, nry))
    if _may_have_nan_or_inf(X.ravel(order="F")) or _may_have_nan_or_inf(Y.ravel(order="F")):
        return B.seqdot(np.ascontiguousarray(X.T), np.ascontiguousarray(Y.T))
    Z = np.zeros((nrx, nry), order="F")
    if nry == 1:
        z = np.zeros(nrx)
        B.dgemv("N", 1.0, X, Y[0, :], 0.0, z)
        Z[:, 0] = z
    elif nrx == 1:
        z = np.zeros(nry)
        B.dgemv("N", 1.0, Y, X[0, :], 0.0, z)
        Z[0, :] = z
    else:
        B.dgemm("N", "T", 1.0, X, Y, 0.0, Z)
    return Z


def outer(X, Y, FUN="*"):
    """``outer(X, Y, FUN)``; ``FUN`` ``"*"`` (über ``tcrossprod`` wie R),
    ``"+"``, ``"-"``, ``"/"``, ``"^"`` oder eine vektorisierte Funktion."""
    mx = _as_r(X)
    my = _as_r(Y)
    dX = list(mx.dim) if mx.is_matrix else [mx.length]
    dY = list(my.dim) if my.is_matrix else [my.length]
    if isinstance(FUN, str) and FUN == "*":
        Z = np.asarray(tcrossprod(mx.v, my.v))
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


# ── solve ─────────────────────────────────────────────────────────────────

def solve(a, b=None, tol=_DBL_EPS):
    """``solve.default(a, b, tol)`` (``La_solve``: ``dgesv`` + ``dgecon``)."""
    if isinstance(a, RQR):
        import warnings
        warnings.warn('solve.default called with a "qr" object: use \'qr.solve\'')
        return solve_qr(a, b)
    ma = _as_matrix(a)
    n, n2 = ma.dim
    if b is None:
        Bm = np.eye(n)
        bnames_c = ma.rn
        b_is_mat = True
        b_rows = n
    else:
        mb = _as_r(b)
        b_is_mat = mb.is_matrix
        if b_is_mat:
            b_rows = mb.dim[0]
            Bm = mb.mat()
            bnames_c = mb.cn
        else:
            Bm = mb.v.reshape(-1, 1).copy()
            bnames_c = None
            b_rows = mb.length
    if n == 0:
        raise RError("'a' is 0-diml")
    if n2 != n:
        raise RError("'a' (%d x %d) must be square" % (n, n2))
    if b_is_mat:
        p = Bm.shape[1]
        if p == 0:
            raise RError("no right-hand side in 'b'")
        if b_rows != n:
            raise RError("'b' (%d x %d) must be compatible with 'a' (%d x %d)" % (b_rows, p, n, n))
    else:
        p = 1
        if b_rows != n:
            raise RError("'b' (%d x %d) must be compatible with 'a' (%d x %d)" % (b_rows, p, n, n))
    A = ma.mat()
    avals = A.copy(order="F")
    Bm = np.asfortranarray(Bm, dtype=np.float64)
    ipiv = np.zeros(n, dtype=np.int64)
    with np.errstate(all="ignore"):
        info = LA.dgesv(avals, Bm, ipiv)
        if info > 0:
            raise RError("Lapack routine %s: system is exactly singular: U[%d,%d] = 0" % ("dgesv", info, info))
        if np.isfinite(avals).all() and tol > 0:
            anorm = LA.dlange("1", avals if ma.is_int else A)
            rcond = LA.dgecon("1", avals, anorm)
            if rcond < tol:
                raise RError("system is computationally singular: reciprocal condition number = %s"
                             % _fmt_g(rcond))
    if b_is_mat:
        rn = ma.cn
        cn = bnames_c
        if rn is not None or cn is not None:
            return _out(Bm, rn, cn)
        return Bm
    return _vec_out(Bm[:, 0].copy(), ma.cn)


def _fmt_g(x):
    return "%g" % x


# ── Cholesky ─────────────────────────────────────────────────────────────

def chol(x, pivot=False, tol=-1):
    """``chol.default(x)`` (``La_chol`` mit ``dpotrf('U')``)."""
    if pivot:
        raise NotImplementedError("chol(pivot = TRUE) ist nicht portiert")
    m = _as_matrix(x)
    nr, nc = m.dim
    if nr != nc:
        raise RError("'a' must be a square matrix")
    if nr <= 0:
        raise RError("'a' must have dims > 0")
    A = m.mat()
    A[np.tril_indices(nr, -1)] = 0.0
    with np.errstate(all="ignore"):
        info = LA.dpotrf("U", A)
    if info != 0:
        if info > 0:
            raise RError("the leading minor of order %d is not positive" % info)
        raise RError("argument %d of Lapack routine %s had invalid value" % (-info, "dpotrf"))
    return _out(A, m.rn, m.cn)


def chol2inv(x, size=None):
    """``chol2inv(x, size)`` (``La_chol2inv`` mit ``dpotri('U')``)."""
    mm = _as_r(x)
    if size is None:
        size = mm.dim[1] if mm.is_matrix else 1
    sz = int(size)
    if sz < 1:
        raise RError("'size' argument must be a positive integer")
    if mm.is_matrix:
        m, n = mm.dim
        Am = mm.mat()
    elif sz == 1:
        m = n = 1
        Am = mm.v.reshape(1, -1)[:, :1]
    else:
        raise RError("'a' must be a numeric matrix")
    if sz > n:
        raise RError("'size' cannot exceed ncol(x) = %d" % n)
    if sz > m:
        raise RError("'size' cannot exceed nrow(x) = %d" % m)
    ans = np.zeros((sz, sz), order="F")
    iu = np.triu_indices(sz)
    ans[iu] = Am[:sz, :sz][iu]
    with np.errstate(all="ignore"):
        info = LA.dpotri("U", ans)
    if info != 0:
        if info > 0:
            raise RError("element (%d, %d) is zero, so the inverse cannot be computed" % (info, info))
        raise RError("argument %d of Lapack routine %s had invalid value" % (-info, "dpotri"))
    il = np.tril_indices(sz, -1)
    ans[il] = ans.T[il]
    return ans


# ── backsolve ────────────────────────────────────────────────────────────

def _backsolve(r, x, k, upper, transpose):
    mr = _as_matrix(r)
    mx = _as_r(x)
    x_mat = mx.is_matrix
    X = mx.mat()
    nrr, ncr = mr.dim
    nrb, ncb = X.shape
    if k is None:
        k = ncr
    k = int(k)
    if k <= 0 or k > nrr or k > ncr or k > nrb:
        raise RError("invalid '%s' argument" % "k")
    R = mr.mat()
    for i in range(k):
        if R[i, i] == 0.0:
            raise RError("singular matrix in 'backsolve'. First zero in diagonal [%d]" % (i + 1))
    ans = np.asfortranarray(X[:k, :].copy())
    if k > 0 and ncb > 0:
        with np.errstate(all="ignore"):
            B.dtrsm("L", "U" if upper else "L", "T" if transpose else "N", "N", 1.0, R[:k, :k], ans)
    if x_mat:
        return ans
    return ans[:, 0].copy() if ans.shape[1] == 1 else ans


def backsolve(r, x, k=None, upper_tri=True, transpose=False):
    """``backsolve(r, x, k, upper.tri, transpose)`` (``dtrsm``)."""
    return _backsolve(r, x, k, bool(upper_tri), bool(transpose))


def forwardsolve(l, x, k=None, upper_tri=False, transpose=False):
    """``forwardsolve(l, x, k, upper.tri, transpose)`` (``dtrsm``)."""
    return _backsolve(l, x, k, bool(upper_tri), bool(transpose))


# ── Determinante ─────────────────────────────────────────────────────────

def determinant(x, logarithm=True):
    """``determinant(x, logarithm)``: ``RDet`` mit ``modulus`` und ``sign``."""
    m = _as_matrix(x)
    nr, nc = m.dim
    if nc != nr:
        raise RError("'x' must be a square matrix")
    res = RDet()
    if nc < 1:
        res["modulus"] = 0.0 if logarithm else 1.0
        res["sign"] = 1
        res._logarithm = bool(logarithm)
        return res
    A = m.mat()
    n = nr
    ipiv = np.zeros(n, dtype=np.int64)
    sign = 1
    with np.errstate(all="ignore"):
        info = LA.dgetrf(A, ipiv)
        if info > 0:
            modulus = -math.inf if logarithm else 0.0
        else:
            for i in range(n):
                if ipiv[i] != i + 1:
                    sign = -sign
            if logarithm:
                modulus = 0.0
                for i in range(n):
                    dii = float(A[i, i])
                    a = -dii if dii < 0 else dii
                    modulus += (math.log(a) if a > 0 else (-math.inf if a == 0 else math.nan))
                    if dii < 0:
                        sign = -sign
            else:
                modulus = 1.0
                for i in range(n):
                    modulus *= float(A[i, i])
                if modulus < 0:
                    modulus = -modulus
                    sign = -sign
    res["modulus"] = modulus
    res["sign"] = sign
    res._logarithm = bool(logarithm)
    return res


def det(x):
    """``det(x)`` = ``sign * exp(modulus)`` aus ``determinant(x, TRUE)``."""
    z = determinant(x, logarithm=True)
    mod = z["modulus"]
    try:
        e = math.exp(mod)
    except OverflowError:
        e = math.inf
    return z["sign"] * e


# ── Eigenwerte ───────────────────────────────────────────────────────────

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


def eigen(x, symmetric=None, only_values=False, backend="auto"):
    """``eigen(x, symmetric, only.values)`` für symmetrische Matrizen.

    Werte absteigend wie R (``rev`` der ``dsyevr``-Reihenfolge), Vektoren in
    den Spalten (Vorzeichen wie ``dstemr`` der Referenz-LAPACK). Ergebnis:
    ``REigen`` mit ``values`` und ``vectors`` (``None`` bei ``only_values``).
    """
    m = _as_matrix(x)
    n, nc = m.dim
    if n != nc:
        raise RError("non-square matrix in 'eigen'")
    if n == 0:
        raise RError("0 x 0 matrix")
    A = m.mat()
    if not np.isfinite(A).all():
        raise RError("infinite or missing values in 'x'")
    if symmetric is None:
        symmetric = is_symmetric(A)
    if not symmetric:
        raise NotImplementedError("eigen(): nur symmetrische Matrizen sind portiert (La_rs)")
    with np.errstate(all="ignore"):
        w, z, info, used = LA.dsyevr(A, only_values=bool(only_values), backend=backend)
    if info != 0:
        raise RError("error code %d from Lapack routine '%s'" % (info, "dsyevr"))
    res = REigen()
    res["values"] = np.asarray(w)[::-1].copy()
    res["vectors"] = None if only_values else np.asfortranarray(np.asarray(z)[:, ::-1])
    res._backend = used
    return res


# ── QR (LINPACK) ─────────────────────────────────────────────────────────

def qr(x, tol=1e-07, LAPACK=False):
    """``qr.default(x, tol)`` mit LINPACK ``dqrdc2`` (``LAPACK = FALSE``)."""
    if LAPACK:
        raise NotImplementedError("qr(LAPACK = TRUE) ist nicht portiert")
    m = _as_matrix(x)
    X = m.mat()
    k, qraux, jpvt = LP.dqrdc2(X, float(tol))
    cn = m.cn
    if cn is not None:
        cn = [cn[i - 1] for i in jpvt]
    res = RQR()
    res["qr"] = _out(X, m.rn, cn)
    res["rank"] = int(k)
    res["qraux"] = qraux
    res["pivot"] = jpvt.astype(np.int64)
    return res


def _qr_parts(q):
    Q = q["qr"]
    if isinstance(Q, pd.DataFrame):
        cn = _names(Q.columns)
        X = np.asfortranarray(Q.to_numpy(dtype=np.float64))
    else:
        cn = None
        X = np.asfortranarray(np.asarray(Q, dtype=np.float64))
    return X, cn, int(q["rank"]), np.asarray(q["qraux"], dtype=np.float64), np.asarray(q["pivot"], dtype=np.int64)


def _check_qr(q, msg="first argument must be a QR decomposition"):
    if not (isinstance(q, RQR) or (isinstance(q, dict) and "qr" in q and "qraux" in q)):
        raise RError(msg)


def qr_coef(qr, y):
    """``qr.coef(qr, y)`` (LINPACK ``dqrcf``); NA für ausgeschlossene Spalten."""
    _check_qr(qr)
    X, nam, k, qraux, pivot = _qr_parts(qr)
    n, p = X.shape
    my = _as_r(y)
    im = my.is_matrix
    Y = my.mat()
    ny = Y.shape[1]
    if Y.shape[0] != n:
        raise RError("'qr' and 'y' must have the same number of rows")
    coef = np.full((p, ny), _fmt.NA_REAL)
    pivotted = None
    if p == 0:
        pivotted = False
    elif k > 0:
        with np.errstate(all="ignore"):
            b, info = LP.dqrcf(X, k, qraux, Y)
        if info:
            raise RError("exact singularity in 'qr.coef'")
        pivotted = k < p
        if pivotted:
            coef[pivot[:k] - 1, :] = b
        else:
            coef = b
    rn = None
    if nam is not None:
        if pivotted is None:
            pivotted = bool(np.any(np.diff(pivot) < 0))
        if pivotted:
            rn = [None] * p
            for i, pv in enumerate(pivot):
                rn[pv - 1] = nam[i]
        else:
            rn = list(nam)
    if im:
        return _out(coef, rn, my.cn)
    v = coef[:, 0].copy() if ny == 1 else coef
    if ny == 1:
        return _vec_out(v, rn)
    return _out(coef, rn, None)


def _qr_apply(qr, y, fn, check_k0=False):
    X, nam, k, qraux, pivot = _qr_parts(qr)
    n = X.shape[0]
    my = _as_r(y)
    Y = my.mat()
    if Y.shape[0] != n:
        raise RError("'qr' and 'y' must have the same number of rows")
    with np.errstate(all="ignore"):
        Z = fn(X, k, qraux, Y)
    if my.is_matrix:
        return _out(Z, my.rn, my.cn)
    return _vec_out(Z[:, 0].copy(), my.names)


def qr_qty(qr, y):
    """``qr.qty(qr, y)`` = Q' y."""
    _check_qr(qr, "argument is not a QR decomposition")
    return _qr_apply(qr, y, LP.dqrqty)


def qr_qy(qr, y):
    """``qr.qy(qr, y)`` = Q y."""
    _check_qr(qr, "argument is not a QR decomposition")
    return _qr_apply(qr, y, LP.dqrqy)


def qr_resid(qr, y):
    """``qr.resid(qr, y)``."""
    _check_qr(qr, "argument is not a QR decomposition")
    if int(qr["rank"]) == 0:
        return y
    return _qr_apply(qr, y, LP.dqrrsd)


def qr_fitted(qr, y, k=None):
    """``qr.fitted(qr, y, k = qr$rank)``."""
    _check_qr(qr, "argument is not a QR decomposition")
    kk = int(qr["rank"]) if k is None else int(k)
    if kk > int(qr["rank"]):
        raise RError("'k' is too large")
    return _qr_apply(qr, y, lambda X, _k, qa, Y: LP.dqrxb(X, kk, qa, Y))


def qr_solve(a, b=None, tol=1e-7):
    """``qr.solve(a, b, tol)``."""
    q = a if isinstance(a, RQR) else qr(a, tol=tol)
    X, _, k, _, _ = _qr_parts(q)
    nr, nc = X.shape
    if k != min(nc, nr):
        raise RError("singular matrix 'a' in solve")
    if b is None:
        if nc != nr:
            raise RError("only square matrices can be inverted")
        b = np.eye(nc)
    res = qr_coef(q, b)
    if isinstance(res, (pd.DataFrame, pd.Series)):
        return res.fillna(0.0)
    res = np.where(np.isnan(res), 0.0, res)
    return res


def solve_qr(a, b=None):
    """``solve.qr(a, b)``."""
    if not isinstance(a, RQR):
        raise RError('this is the "qr" method for the generic function solve()')
    X, _, k, _, _ = _qr_parts(a)
    nr, nc = X.shape
    if k != min(nc, nr):
        raise RError("singular matrix 'a' in 'solve'")
    if b is None:
        if nc != nr:
            raise RError("only square matrices can be inverted")
        b = np.eye(nc)
    res = qr_coef(a, b)
    if isinstance(res, (pd.DataFrame, pd.Series)):
        return res.fillna(0.0)
    return np.where(np.isnan(res), 0.0, res)


def qr_R(qr, complete=False):
    """``qr.R(qr, complete)``."""
    X, cn, _, _, _ = _qr_parts(qr)
    R = X.copy()
    if not complete:
        R = R[:min(R.shape), :]
    i, j = np.indices(R.shape)
    R[i > j] = 0.0
    return _out(R, None, cn)


def qr_Q(qr, complete=False):
    """``qr.Q(qr, complete)``."""
    X, _, _, _, _ = _qr_parts(qr)
    n = X.shape[0]
    if complete:
        D = np.eye(n)
    else:
        nc = min(X.shape)
        D = np.zeros((n, nc))
        D[np.arange(nc), np.arange(nc)] = 1.0
    return qr_qy(qr, D)


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
