# Herkunft:           übersetzt aus R 4.3.3, src/library/stats/src/distance.c, hclust.f;
#                     nachgebildet nach R 4.3.3, src/library/stats/R/dist.R, hclust.R
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle); hclust.f: F. Murtagh (1986), Änderungen Ross
#                     Ihaka, Fritz Leisch, Martin Maechler (ohne eigenen Lizenzvermerk)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang; seit 1.6.0 rechnen Abstände und Clusterbaum im Kern
#                     core/slc_rbase_clust.cpp (sl_r_dist, sl_r_hclust), hier bleiben Argumente und Rückgabe.
"""Distanzen und hierarchische Clusteranalyse (``dist``, ``as.dist``, ``hclust``), nachgebildet aus R 4.3.3
``stats/R/dist.R``, ``hclust.R`` und ``stats/src/distance.c``, ``hclust.f``.
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd

from .linalg import RError, _as_matrix
from .rlist import RList
from .stats_sort import _warn
from .. import _ext   # C-Kern core/slc_rbase_clust.cpp (seit 1.6.0)

__all__ = [
    "RDist", "RHclust", "dist_as_matrix", "hclust", "dist", "as_dist",
]


# ── dist / hclust ────────────────────────────────────────────────────────

class RDist(np.ndarray):
    """``dist``-Objekt: unteres Dreieck spaltenweise, Attribute ``Size``,
    ``Labels``, ``Diag``, ``Upper``, ``method``."""

    def __new__(cls, v, size, labels=None, diag=False, upper=False, method=None):
        obj = np.asarray(v, dtype=np.float64).view(cls)
        obj.Size = int(size)
        obj.Labels = labels
        obj.Diag = diag
        obj.Upper = upper
        obj.method = method
        return obj

    def __array_finalize__(self, obj):
        for k in ("Size", "Labels", "Diag", "Upper", "method"):
            setattr(self, k, getattr(obj, k, None))


_DIST_METHODS = ["euclidean", "maximum", "manhattan", "canberra", "binary", "minkowski"]


def dist(x, method="euclidean", diag=False, upper=False, p=2):
    """``dist(x, method, diag, upper, p)``; Ergebnis :class:`RDist` (Kern ``sl_r_dist``)."""
    if method and "euclidian".startswith(method):
        method = "euclidean"
    # pmatch: exakt vor eindeutig partiell; mehrdeutig oder leer ist NA ("invalid", seit 1.6.0 wie R)
    hits = [_DIST_METHODS.index(method)] if method in _DIST_METHODS else \
        [i for i, m in enumerate(_DIST_METHODS) if method and m.startswith(method)]
    if len(hits) != 1:
        raise RError("invalid distance method")
    mi = hits[0] + 1
    m = _as_matrix(x)
    X = m.mat()
    nr, nc = X.shape
    if mi == 6 and (not math.isfinite(p) or p <= 0):
        raise RError("distance(): invalid p")
    out = np.empty(nr * (nr - 1) // 2)
    if _ext.slc_r_dist(np.ascontiguousarray(X, dtype=np.float64).ravel(order="F"), nr, nc, mi, float(p), out):
        _warn("treating non-finite values as NA")
    return RDist(out, nr, m.rn, diag, upper, _DIST_METHODS[mi - 1])


def as_dist(m, diag=False, upper=False):
    """``as.dist(m)``: unteres Dreieck einer Matrix als :class:`RDist`."""
    if isinstance(m, RDist):
        return m
    mm = _as_matrix(m)
    A = mm.mat()
    p = A.shape[0]
    if A.shape[1] != p:
        _warn("non-square matrix")
    i, j = np.indices(A.shape)
    sel = (i > j)
    vals = A.ravel(order="F")[sel.ravel(order="F")]
    labels = mm.rn if mm.rn is not None else mm.cn
    return RDist(vals, p, labels, diag, upper, None)


def dist_as_matrix(d):
    """``as.matrix(<dist>)`` (dimnames ``Labels`` bzw. ``1..n``)."""
    size = d.Size
    df = np.zeros((size, size))
    i, j = np.indices(df.shape)
    sel = (i > j).ravel(order="F")
    flat = df.ravel(order="F")
    flat[sel] = np.asarray(d, dtype=np.float64)
    df = flat.reshape((size, size), order="F")
    df = df + df.T
    lab = d.Labels if d.Labels is not None else [str(k + 1) for k in range(size)]
    return pd.DataFrame(df, index=lab, columns=lab)


class RHclust(RList):
    r_class = ("hclust",)


_HC_METHODS = ["ward.D", "single", "complete", "average", "mcquitty", "median", "centroid", "ward.D2"]


def hclust(d, method="complete", members=None):
    """``hclust(d, method, members)`` (Fortran ``hclust``/``hcass2``, seit 1.6.0 Kern ``sl_r_hclust``).

    Ergebnis ``RHclust`` mit ``merge`` (int-Matrix), ``height``, ``order``,
    ``labels``, ``method``, ``call``, ``dist.method``.
    """
    if method == "ward":
        print('The "ward" method has been renamed to "ward.D"; note new "ward.D2"')
        method = "ward.D"
    hits = [i for i, m in enumerate(_HC_METHODS) if method and m.startswith(method)]
    if method in _HC_METHODS:
        hits = [_HC_METHODS.index(method)]
    if len(hits) != 1:   # pmatch: mehrdeutig oder leer ist NA ("invalid", seit 1.6.0 wie R)
        raise RError("invalid clustering method " + method)
    iopt = hits[0] + 1
    if not isinstance(d, RDist):
        raise RError("invalid dissimilarities")
    n = int(d.Size)
    if n > 65536:
        raise RError("size cannot be NA nor exceed 65536")
    if n < 2:
        raise RError("must have n >= 2 objects to cluster")
    ln = n * (n - 1) // 2
    if d.size != ln:
        if d.size < ln:
            raise RError("dissimilarities of improper length")
        _warn("dissimilarities of improper length")
    membr = [1.0] * n if members is None else [float(v) for v in members]
    if len(membr) != n:
        raise RError("invalid length of members")
    diss = np.ascontiguousarray(np.asarray(d, dtype=np.float64)[:ln])
    merge = np.empty((n - 1) * 2, dtype=np.int64)
    height = np.empty(n - 1)
    order = np.empty(n, dtype=np.int64)
    _ext.slc_r_hclust(n, iopt, np.ascontiguousarray(membr, dtype=np.float64), diss, merge, height, order)
    res = RHclust()
    res["merge"] = merge.reshape((n - 1, 2), order="F")
    res["height"] = height
    res["order"] = order
    res["labels"] = d.Labels
    res["method"] = _HC_METHODS[iopt - 1]
    res["call"] = None
    res["dist.method"] = d.method
    return res


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
