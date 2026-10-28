"""Distanzen und hierarchische Clusteranalyse (``dist``, ``as.dist``, ``hclust``), nachgebildet aus R 4.3.3
``stats/R/dist.R``, ``hclust.R`` und ``stats/src/distance.c``, ``hclust.f``.
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd

from .linalg import RError, _as_matrix
from .rlist import RList
from .rnum import NA_REAL
from .stats_sort import _DBL_MAX, _warn

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
    """``dist(x, method, diag, upper, p)``; Ergebnis :class:`RDist`."""
    from .rnum import r_pow
    if "euclidian".startswith(method):
        method = "euclidean"
    hits = [i for i, m in enumerate(_DIST_METHODS) if m.startswith(method)]
    if not hits:
        raise RError("invalid distance method")
    if len(hits) > 1 and method not in _DIST_METHODS:
        raise RError("ambiguous distance method")
    mi = hits[0] + 1 if len(hits) == 1 else _DIST_METHODS.index(method) + 1
    m = _as_matrix(x)
    X = m.mat()
    nr, nc = X.shape
    if mi == 6 and (not math.isfinite(p) or p <= 0):
        raise RError("distance(): invalid p")
    out = []
    warned = [False]
    with np.errstate(all="ignore"):
        for j in range(nr):
            for i in range(j + 1, nr):
                out.append(_dist1(X[i], X[j], mi, p, warned, r_pow))
    if warned[0]:
        _warn("treating non-finite values as NA")
    return RDist(np.array(out), nr, m.rn, diag, upper, _DIST_METHODS[mi - 1])


def _dist1(a, b, method, p, warned, r_pow):
    nc = a.size
    ok = ~(np.isnan(a) | np.isnan(b))
    if method == 1:
        dev = a - b
        m = ok & ~np.isnan(dev)
        cnt = int(m.sum())
        if cnt == 0:
            return NA_REAL
        d = 0.0
        for v in dev[m].tolist():
            d += v * v
        if cnt != nc:
            d /= (cnt / nc)
        return math.sqrt(d)
    if method == 2:
        dev = np.abs(a - b)
        m = ok & ~np.isnan(dev)
        if not m.any():
            return NA_REAL
        d = -_DBL_MAX
        for v in dev[m].tolist():
            if v > d:
                d = v
        return d
    if method == 3:
        dev = np.abs(a - b)
        m = ok & ~np.isnan(dev)
        cnt = int(m.sum())
        if cnt == 0:
            return NA_REAL
        d = 0.0
        for v in dev[m].tolist():
            d += v
        if cnt != nc:
            d /= (cnt / nc)
        return d
    if method == 4:
        d = 0.0
        cnt = 0
        for x1, x2, o in zip(a.tolist(), b.tolist(), ok.tolist()):
            if not o:
                continue
            s = abs(x1) + abs(x2)
            df = abs(x1 - x2)
            if s > 2.2250738585072014e-308 or df > 2.2250738585072014e-308:
                dev = float(np.float64(df) / np.float64(s))
                if dev == dev or (not math.isfinite(df) and df == s and True):
                    if dev != dev:
                        dev = 1.0
                    d += dev
                    cnt += 1
        if cnt == 0:
            return NA_REAL
        if cnt != nc:
            d /= (cnt / nc)
        return d
    if method == 5:
        total = 0
        count = 0
        dd = 0
        for x1, x2, o in zip(a.tolist(), b.tolist(), ok.tolist()):
            if not o:
                continue
            if not (math.isfinite(x1) and math.isfinite(x2)):
                warned[0] = True
            else:
                if x1 != 0.0 or x2 != 0.0:
                    count += 1
                    if not (x1 != 0.0 and x2 != 0.0):
                        dd += 1
                total += 1
        if total == 0:
            return NA_REAL
        if count == 0:
            return 0.0
        return dd / count
    dev = a - b
    m = ok & ~np.isnan(dev)
    cnt = int(m.sum())
    if cnt == 0:
        return NA_REAL
    d = 0.0
    for v in dev[m].tolist():
        d += r_pow(abs(v), p)
    if cnt != nc:
        d /= (cnt / nc)
    return r_pow(d, 1.0 / p)


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
    """``hclust(d, method, members)`` (Fortran ``hclust``/``hcass2``).

    Ergebnis ``RHclust`` mit ``merge`` (int-Matrix), ``height``, ``order``,
    ``labels``, ``method``, ``call``, ``dist.method``.
    """
    if method == "ward":
        print('The "ward" method has been renamed to "ward.D"; note new "ward.D2"')
        method = "ward.D"
    hits = [i for i, m in enumerate(_HC_METHODS) if m.startswith(method)]
    if method in _HC_METHODS:
        hits = [_HC_METHODS.index(method)]
    if not hits:
        raise RError("invalid clustering method " + method)
    if len(hits) > 1:
        raise RError("ambiguous clustering method " + method)
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
    diss = [0.0] + [float(v) for v in np.asarray(d, dtype=np.float64).tolist()]
    ia, ib, crit = _hclust_f(n, ln, iopt, membr, diss)
    order, iia, iib = _hcass2(n, ia, ib)
    res = RHclust()
    res["merge"] = np.column_stack([np.array(iia[1:n], dtype=np.int64), np.array(iib[1:n], dtype=np.int64)])
    res["height"] = np.array(crit[1:n])
    res["order"] = np.array(order[1:], dtype=np.int64)
    res["labels"] = d.Labels
    res["method"] = _HC_METHODS[iopt - 1]
    res["call"] = None
    res["dist.method"] = d.method
    return res


def _ioffst(n, i, j):
    return j + (i - 1) * n - (i * (i + 1)) // 2


def _fmin_(a, b):
    return a if a <= b else b


def _fmax_(a, b):
    return a if a >= b else b


def _hclust_f(n, ln, iopt, membr, diss):
    INF = 1.0e300
    ia = [0] * (n + 1)
    ib = [0] * (n + 1)
    crit = [0.0] * (n + 1)
    nn = [0] * (n + 1)
    disnn = [0.0] * (n + 1)
    membr = [0.0] + list(membr)
    flag = [True] * (n + 1)
    im = jj = jm = 0
    ncl = n
    if iopt == 8:
        for i in range(1, ln + 1):
            diss[i] = diss[i] * diss[i]
    for i in range(1, n):
        dmin = INF
        for j in range(i + 1, n + 1):
            ind = _ioffst(n, i, j)
            if dmin > diss[ind]:
                dmin = diss[ind]
                jm = j
        nn[i] = jm
        disnn[i] = dmin
    isWard = iopt in (1, 8)
    while True:
        dmin = INF
        for i in range(1, n):
            if flag[i] and disnn[i] < dmin:
                dmin = disnn[i]
                im = i
                jm = nn[i]
        ncl -= 1
        i2 = min(im, jm)
        j2 = max(im, jm)
        ia[n - ncl] = i2
        ib[n - ncl] = j2
        if iopt == 8:
            dmin = math.sqrt(dmin)
        crit[n - ncl] = dmin
        flag[j2] = False
        dmin = INF
        for k in range(1, n + 1):
            if flag[k] and k != i2:
                ind1 = _ioffst(n, i2, k) if i2 < k else _ioffst(n, k, i2)
                ind2 = _ioffst(n, j2, k) if j2 < k else _ioffst(n, k, j2)
                d12 = diss[_ioffst(n, i2, j2)]
                if isWard:
                    v = ((membr[i2] + membr[k]) * diss[ind1] + (membr[j2] + membr[k]) * diss[ind2]) - membr[k] * d12
                    diss[ind1] = v / ((membr[i2] + membr[j2]) + membr[k])
                elif iopt == 2:
                    diss[ind1] = _fmin_(diss[ind1], diss[ind2])
                elif iopt == 3:
                    diss[ind1] = _fmax_(diss[ind1], diss[ind2])
                elif iopt == 4:
                    diss[ind1] = (membr[i2] * diss[ind1] + membr[j2] * diss[ind2]) / (membr[i2] + membr[j2])
                elif iopt == 5:
                    diss[ind1] = (diss[ind1] + diss[ind2]) / 2
                elif iopt == 6:
                    diss[ind1] = ((diss[ind1] + diss[ind2]) - d12 / 2) / 2
                elif iopt == 7:
                    diss[ind1] = (membr[i2] * diss[ind1] + membr[j2] * diss[ind2] -
                                  membr[i2] * membr[j2] * d12 / (membr[i2] + membr[j2])) / (membr[i2] + membr[j2])
                if i2 < k:
                    if diss[ind1] < dmin:
                        dmin = diss[ind1]
                        jj = k
                else:
                    if diss[ind1] < disnn[k]:
                        disnn[k] = diss[ind1]
                        nn[k] = i2
        membr[i2] = membr[i2] + membr[j2]
        disnn[i2] = dmin
        nn[i2] = jj
        for i in range(1, n):
            if flag[i] and (nn[i] == i2 or nn[i] == j2):
                dmin = INF
                for j in range(i + 1, n + 1):
                    if flag[j]:
                        ind = _ioffst(n, i, j)
                        if diss[ind] < dmin:
                            dmin = diss[ind]
                            jj = j
                nn[i] = jj
                disnn[i] = dmin
        if not (ncl > 1):
            break
    return ia, ib, crit


def _hcass2(n, ia, ib):
    iia = [0] * (n + 1)
    iib = [0] * (n + 1)
    iorder = [0] * (n + 1)
    for i in range(1, n + 1):
        iia[i] = ia[i]
        iib[i] = ib[i]
    for i in range(1, n - 1):
        k = min(ia[i], ib[i])
        for j in range(i + 1, n):
            if ia[j] == k:
                iia[j] = -i
            if ib[j] == k:
                iib[j] = -i
    for i in range(1, n):
        iia[i] = -iia[i]
        iib[i] = -iib[i]
    for i in range(1, n):
        if iia[i] > 0 and iib[i] < 0:
            k = iia[i]
            iia[i] = iib[i]
            iib[i] = k
        if iia[i] > 0 and iib[i] > 0:
            k1 = min(iia[i], iib[i])
            k2 = max(iia[i], iib[i])
            iia[i] = k1
            iib[i] = k2
    iorder[1] = iia[n - 1]
    iorder[2] = iib[n - 1]
    loc = 2
    for i in range(n - 2, 0, -1):
        for j in range(1, loc + 1):
            if iorder[j] == i:
                iorder[j] = iia[i]
                if j == loc:
                    loc += 1
                    iorder[loc] = iib[i]
                else:
                    loc += 1
                    for k in range(loc, j + 1, -1):
                        iorder[k] = iorder[k - 1]
                    iorder[j + 1] = iib[i]
                break
    for i in range(1, n + 1):
        iorder[i] = -iorder[i]
    return iorder, iia, iib


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
