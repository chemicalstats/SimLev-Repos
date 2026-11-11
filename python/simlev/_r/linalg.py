# Herkunft:           nachgebildet nach R 4.3.3, src/library/base/R/outer.R, diag.R, all.equal.R
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang.
"""Lineare Hilfen wie in R 4.3.3, die neben der C-Bibliothek slc bleiben.

==================  ==========================================================
R                   Python
==================  ==========================================================
``outer``, ``%o%``  :func:`outer`
``diag``            :func:`diag`
``all.equal``       :func:`all_equal_numeric` (numerisch)
==================  ==========================================================

Dazu die Hilfen :class:`RError` (Fehler mit R's Meldungstext), ``_as_matrix``, ``_out`` und
``_vec_out`` für die übrigen ``_r``-Module.

Seit 1.0.0 rechnet SimLev Matrixprodukte, Cholesky, Dreieckslöser, SPD-Löser,
Eigenwerte und QR/kleinste Quadrate in der C-Bibliothek slc (:mod:`simlev._lib`). Die Nachbildungen von ``%*%``, ``crossprod``, ``solve``, ``chol``, ``backsolve``,
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

__all__ = ["outer", "diag", "all_equal_numeric", "RError"]

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
    """``outer(X, Y)`` mit ``FUN = "*"`` (wie R über ein Matrixprodukt mit innerer Länge 1: jedes Element ist
    ``0 + x[i] * y[j]``, also ``+0`` statt ``-0``). Seit 1.6.3 nur dieser Fall (einziger Aufrufer
    ``optimize``; die Zweige ``+ - / ^`` und Funktionen hatten keinen Aufrufer)."""
    if not (isinstance(FUN, str) and FUN == "*"):
        raise RError("unsupported FUN")
    mx = _as_r(X)
    my = _as_r(Y)
    dX = list(mx.dim) if mx.is_matrix else [mx.length]
    dY = list(my.dim) if my.is_matrix else [my.length]
    # Seit 1.0.0 ohne die Nachbildung der Referenz-BLAS: bei innerer Länge 1 ist das
    # Matrixprodukt genau die Summe 0 + Produkt (wie dgemm und R's simple_matprod).
    with np.errstate(all="ignore"):
        Z = 0.0 + np.multiply.outer(np.asarray(mx.v, dtype=np.float64), np.asarray(my.v, dtype=np.float64))
    flat = Z.ravel(order="F")
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
    """Kern von ``all.equal.numeric`` (ohne Attribute); ``True`` oder Text. Seit 1.6.4 (Befund C-095) wie R:
    ``tolerance`` muss eine Zahl sein, NaN ergibt bei Unterschieden R's Fehler, die Abweichung steht wie
    ``format(xy)`` (7 Stellen) im Text."""
    from .rnum import r_sum
    from .rformat import r_format1
    if isinstance(tolerance, (bool, np.bool_)) or not isinstance(tolerance, (int, float, np.integer, np.floating)):
        raise ValueError("'tolerance' should be numeric")
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
        if math.isnan(float(tolerance)):
            raise ValueError("missing value where TRUE/FALSE needed")
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
        return "Mean %s difference: %s" % (what, r_format1(float(xy), digits=7))
    return True


# ── diag ──────────────────────────────────────────────────────────────────


def _as_integer1(v):
    """asInteger von R für nrow/ncol: erste Zahl abgeschnitten; NA, nicht lesbarer Text und |x| >= 2^31 ergeben None
    (außerhalb von int mit R's Warnung)."""
    import warnings
    a = np.asarray(v, dtype=object).ravel()
    if a.size == 0:
        return None
    t = a[0]
    if t is None:
        return None
    if isinstance(t, (bool, np.bool_)):
        return int(t)
    if isinstance(t, str):
        from .rnum import r_string_to_real
        f, bad = r_string_to_real(t)
        if bad:
            warnings.warn("NAs introduced by coercion", UserWarning, stacklevel=3)
    else:
        f = float(t)
    if f != f:
        return None
    if not (-2147483648.0 < f < 2147483648.0):
        warnings.warn("NAs introduced by coercion to integer range", UserWarning, stacklevel=3)
        return None
    return int(math.trunc(f))


def diag(x=1, nrow=None, ncol=None):
    """``diag(x, nrow, ncol)`` wie R für einen Vektor oder eine Zahl ``x`` (seit 1.6.3 ohne den Matrixfall). Seit 1.6.4
    wie R (C-044, Entscheidung 97): ``diag(n)`` ohne nrow/ncol ist die n×n-Einheitsmatrix (bis 1.6.3 1×1 mit n),
    nrow/ncol wie asInteger mit R's Meldungen, ein leerer Vektor ergibt bei Größe 0 eine 0×0-Matrix."""
    if isinstance(x, (pd.DataFrame, np.ndarray)) and np.ndim(x) == 2:
        raise RError("diag: Matrixfall entfallen (interner Fehler)")
    if nrow is None and ncol is None and np.size(x) == 1:
        n = _as_integer1(x)
        v = np.array([1.0])
    else:
        v = np.asarray(x, dtype=np.float64).ravel()
        n = v.size
    if nrow is not None:
        n = _as_integer1(nrow)
    nc = n if ncol is None else _as_integer1(ncol)
    if n is None:
        raise RError("invalid 'nrow' value (too large or NA)")
    if n < 0:
        raise RError("invalid 'nrow' value (< 0)")
    if nc is None:
        raise RError("invalid 'ncol' value (too large or NA)")
    if nc < 0:
        raise RError("invalid 'ncol' value (< 0)")
    mn = min(n, nc)
    if mn > 0 and v.size == 0:
        raise RError("'x' must have positive length")
    out = np.zeros((n, nc))
    if mn > 0:
        out[np.arange(mn), np.arange(mn)] = np.resize(v, mn)
    return out


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
