"""Kovarianz und Korrelation (``cor``, ``cov``, ``var``, ``sd``, ``cov2cor``) sowie ``scale``, nachgebildet aus
R 4.3.3 ``src/library/stats/src/cov.c``, ``stats/R/cor.R`` und ``base/R/scale.R``.

Seit N8 rechnet der Kern von ``cov``/``cor`` (pearson, kendall; alle ``use``) in C
(``core/slc_rbase_cov.c``, gemeinsam mit Julia); hier bleiben Argumentprüfung, Ränge für
spearman und die Ergebnisform.
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd

from .linalg import RError, _as_r, _as_matrix, _out
from .rnum import NA_REAL, _margsums
from .stats_sort import _NAN, _rsum, _warn, rank
from .. import _ext   # N8: C-Kern core/slc_rbase_cov.c

__all__ = [
    "var", "sd", "cov", "cor", "cov2cor", "scale",
]


# ── cov / cor (cov.c) ────────────────────────────────────────────────────

_USE = ["all.obs", "complete.obs", "pairwise.complete.obs", "everything", "na.or.complete"]


def _pmatch_use(use):
    hits = [i for i, u in enumerate(_USE) if u.startswith(use)]
    if len(hits) != 1:
        if use in _USE:
            return _USE.index(use) + 1
        raise RError("invalid 'use' argument")
    return hits[0] + 1


def _as_cov_input(x):
    """→ (Matrix n×nc float64, ist_matrix, colnames)."""
    if isinstance(x, pd.DataFrame):
        a = np.asarray(x.to_numpy(dtype=np.float64), dtype=np.float64)
        cn = None if isinstance(x.columns, pd.RangeIndex) else [str(c) for c in x.columns]
        return a, True, cn
    if isinstance(x, pd.Series):
        return x.to_numpy(dtype=np.float64).reshape(-1, 1), False, None
    a = np.asarray(x)
    if a.dtype == object:
        a = np.array([np.nan if v is None else v for v in a.ravel()], dtype=np.float64).reshape(a.shape)
    a = a.astype(np.float64)
    if a.ndim == 2:
        return a, True, None
    return a.reshape(-1, 1), False, None


def _corcov(x, y, method_na, kendall, cor):
    """R's ``cor``/``cov`` mit ``use`` als Zahl 1–5 (C-Kern ``sl_r_cov``, N8)."""
    X, xmat, xcn = _as_cov_input(x)
    n, ncx = X.shape
    ansmat = xmat
    if y is None:
        Y = None
        ncy = ncx
        ycn = None
    else:
        Y, ymat, ycn = _as_cov_input(y)
        if Y.shape[0] != n:
            raise RError("incompatible dimensions")
        if ymat:
            ansmat = True
        ncy = Y.shape[1]
    if method_na not in (1, 2, 3, 4, 5):
        raise RError("invalid 'use' (computational method)")
    if method_na == 2 and X.size == 0:
        raise RError("no complete element pairs")
    if method_na in (1, 2, 3) and X.size == 0:
        raise RError("'x' is empty")
    ans = np.empty(ncx * ncy)
    try:
        sd0 = _ext.slc_r_cov(np.ascontiguousarray(X.ravel(order="F")), n, ncx,
                             None if Y is None else np.ascontiguousarray(Y.ravel(order="F")), ncy,
                             method_na, int(bool(kendall)), int(bool(cor)), ans)
    except ValueError as e:
        raise RError(str(e)) from None
    if sd0:
        _warn("the standard deviation is zero")
    ans = ans.reshape((ncx, ncy), order="F")
    if ansmat:
        if y is None:
            rn = cn = xcn
        else:
            rn, cn = xcn, ycn
        return _out(ans, rn, cn)
    v = ans.ravel(order="F")
    if v.size == 1:
        return float(v[0])
    return v


def _rank_cols(u):
    """``Rank`` aus cor(): Ränge (na.last = "keep") je Spalte."""
    if isinstance(u, pd.DataFrame):
        a = u.to_numpy(dtype=np.float64)
        out = np.column_stack([np.asarray(rank(a[:, j], na_last="keep"), dtype=np.float64)
                               for j in range(a.shape[1])]) if a.shape[0] > 1 else \
            np.tile(np.arange(1, a.shape[0] + 1, dtype=np.float64)[:, None], (1, a.shape[1]))
        return pd.DataFrame(out, index=u.index, columns=u.columns)
    a = np.asarray(u, dtype=np.float64)
    if a.size == 0:
        return a
    if a.ndim == 2:
        if a.shape[0] > 1:
            return np.column_stack([np.asarray(rank(a[:, j], na_last="keep"), dtype=np.float64)
                                    for j in range(a.shape[1])])
        return np.tile(np.arange(1, a.shape[0] + 1, dtype=np.float64)[:, None], (1, a.shape[1]))
    return np.asarray(rank(a, na_last="keep"), dtype=np.float64)


def _na_omit_rows(x):
    if isinstance(x, pd.DataFrame):
        m = ~np.isnan(x.to_numpy(dtype=np.float64)).any(axis=1)
        return x[m]
    a = np.asarray(x, dtype=np.float64)
    if a.ndim == 2:
        return a[~np.isnan(a).any(axis=1)]
    return a[~np.isnan(a)]


def _drop_rows(x, keep):
    if isinstance(x, pd.DataFrame):
        return x[keep]
    if isinstance(x, pd.Series):
        return x[keep]
    a = np.asarray(x, dtype=np.float64)
    return a[keep] if a.ndim == 1 else a[keep, :]


def _cor_cov(x, y, use, method, cor):
    na_method = _pmatch_use(use)
    if method not in ("pearson", "kendall", "spearman"):
        raise RError("'arg' should be one of “pearson”, “kendall”, “spearman”")
    is_mat = isinstance(x, pd.DataFrame) or (isinstance(x, np.ndarray) and x.ndim == 2)
    if not is_mat and y is None:
        raise RError("supply both 'x' and 'y' or a matrix-like 'x'")
    if method == "pearson":
        return _corcov(x, y, na_method, False, cor)
    kend = method == "kendall"
    if na_method in (2, 5):
        if y is None:
            return _corcov(_rank_cols(_na_omit_rows(x)), None, na_method, kend, cor)
        X, _, _ = _as_cov_input(x)
        Y, _, _ = _as_cov_input(y)
        keep = ~(np.isnan(X).any(axis=1) | np.isnan(Y).any(axis=1))
        return _corcov(_rank_cols(_drop_rows(x, keep)), _rank_cols(_drop_rows(y, keep)), na_method, kend, cor)
    if na_method != 3:
        xr = _rank_cols(x)
        yr = None if y is None else _rank_cols(y)
        return _corcov(xr, yr, na_method, kend, cor)
    if not cor:
        raise RError("cannot handle 'pairwise.complete.obs'")
    # paarweise, Rangkorrelation
    X, xmat, xcn = _as_cov_input(x)
    if y is None:
        ncx = X.shape[1]
        if ncx == 0:
            raise RError("'x' is empty")
        r = np.zeros((ncx, ncx))
        for i in range(ncx):
            for j in range(i + 1):
                x2 = X[:, i]
                y2 = X[:, j]
                ok = ~(np.isnan(x2) | np.isnan(y2))
                r[i, j] = _corcov(np.asarray(rank(x2[ok]), dtype=np.float64),
                                  np.asarray(rank(y2[ok]), dtype=np.float64), 1, kend, True) if ok.any() else NA_REAL
        if ncx == 1:
            # R: r + t(r) - diag(diag(r)); diag() eines Skalars baut eine Einheitsmatrix
            d = r[0, 0]
            if d != d:
                raise RError("invalid 'nrow' value (too large or NA)")
            m = int(d)
            if m < 0:
                raise RError("invalid 'nrow' value (< 0)")
            if m != 1:
                raise RError("non-conformable arrays")
            r = (r + r) - 1.0
        else:
            r = r + r.T - np.diag(np.diag(r))
        return _out(r, xcn, xcn)
    Y, ymat, ycn = _as_cov_input(y)
    if X.size == 0 or Y.size == 0:
        raise RError("both 'x' and 'y' must be non-empty")
    r = np.zeros((X.shape[1], Y.shape[1]))
    for i in range(X.shape[1]):
        for j in range(Y.shape[1]):
            x2 = X[:, i]
            y2 = Y[:, j]
            ok = ~(np.isnan(x2) | np.isnan(y2))
            r[i, j] = _corcov(np.asarray(rank(x2[ok]), dtype=np.float64),
                              np.asarray(rank(y2[ok]), dtype=np.float64), 1, kend, True) if ok.any() else NA_REAL
    if xmat or ymat:
        return _out(r, xcn, ycn)
    return float(r[0, 0]) if r.size == 1 else r.ravel()


def cor(x, y=None, use="everything", method="pearson"):
    """``cor(x, y, use, method)``: pearson, kendall, spearman."""
    return _cor_cov(x, y, use, method, True)


def cov(x, y=None, use="everything", method="pearson"):
    """``cov(x, y, use, method)``."""
    return _cor_cov(x, y, use, method, False)


def var(x, y=None, na_rm=False, use=None):
    """``var(x, y, na.rm, use)``."""
    if use is None:
        use = "na.or.complete" if na_rm else "everything"
    na_method = _pmatch_use(use)
    return _corcov(x, y, na_method, False, False)


def sd(x, na_rm=False):
    """``sd(x, na.rm)`` = ``sqrt(var(x, na.rm))``."""
    if isinstance(x, pd.DataFrame) or (isinstance(x, np.ndarray) and x.ndim == 2):
        x = np.asarray(x, dtype=np.float64).ravel(order="F")
    v = var(x, na_rm=na_rm)
    if v != v:
        return v                        # sqrt(NA) = NA, sqrt(NaN) = NaN
    return math.sqrt(v) if v >= 0 else _NAN


def cov2cor(V):
    """``cov2cor(V)``."""
    m = _as_r(V)
    if not m.is_matrix or m.dim[0] != m.dim[1]:
        raise RError("'V' is not a square numeric matrix")
    p = m.dim[0]
    A = m.mat()
    D = np.diag(A).copy()
    from .fmt import _nan_mask
    with np.errstate(all="ignore"):
        pos = ~np.isnan(D) & (D > 0)
        Is = D.copy()
        Is[pos] = np.sqrt(1.0 / D[pos])
        Is[~pos] = np.nan                      # R: Is[!pos] <- NaN
        if (~pos).any() or (~np.isfinite(Is)).any():
            _warn("diag(V) had non-positive or NA entries; the non-finite result may be dubious")
        r = (Is[:, None] * A) * Is[None, :]
    # R: `Is * V` (Recycling-Schleife) reicht bei zwei NaN-Operanden den aus V
    # durch, `* rep(Is, each = p)` (gleiche Länge) den linken. Ergebnis ist also
    # genau dann NA, wenn V[i,j] NA ist; jedes andere NaN ist R-NaN.
    na_v = np.isnan(A) & ~_nan_mask(A)
    r[np.isnan(r) & ~na_v] = np.nan
    r[na_v] = NA_REAL
    if p:
        r[np.arange(p), np.arange(p)] = 1.0
    return _out(r, m.rn, m.cn)


def scale(x, center=True, scale=True):
    """``scale.default(x, center, scale)``; Ergebnis-Matrix mit Attributen
    ``scaled_center``/``scaled_scale`` (als Attribute des Rückgabeobjekts
    nicht möglich – daher Tupel-frei: ``ndarray`` und ``.attrs`` bei DataFrame)."""
    m = _as_matrix(x)
    X = m.mat()
    nc = X.shape[1]
    cen = None
    sc = None
    with np.errstate(all="ignore"):
        if isinstance(center, (bool, np.bool_)):
            if center:
                cen = np.array([_colmean_narm(X[:, j]) for j in range(nc)])
                X = X - cen[None, :]
        else:
            cen = np.asarray(center, dtype=np.float64).ravel()
            if cen.size != nc:
                raise RError("length of 'center' must equal the number of columns of 'x'")
            X = X - cen[None, :]
        if isinstance(scale, (bool, np.bool_)):
            if scale:
                sc = np.empty(nc)
                for j in range(nc):
                    v = X[:, j]
                    v = v[~np.isnan(v)]
                    sc[j] = math.sqrt(_rsum(v * v) / max(1, v.size - 1))
                X = X / sc[None, :]
        else:
            sc = np.asarray(scale, dtype=np.float64).ravel()
            if sc.size != nc:
                raise RError("length of 'scale' must equal the number of columns of 'x'")
            X = X / sc[None, :]
    out = pd.DataFrame(X, index=m.rn, columns=m.cn)
    out.attrs["scaled:center"] = cen
    out.attrs["scaled:scale"] = sc
    if m.rn is None and m.cn is None:
        res = _ScaledArray(X)
        res.scaled_center = cen
        res.scaled_scale = sc
        return res
    return out


class _ScaledArray(np.ndarray):
    def __new__(cls, a):
        return np.asarray(a).view(cls)

    def __array_finalize__(self, obj):
        self.scaled_center = getattr(obj, "scaled_center", None)
        self.scaled_scale = getattr(obj, "scaled_scale", None)


def _colmean_narm(col):
    """``colMeans(x, na.rm = TRUE)`` einer Spalte (long-double-Summe / Anzahl, C-Kern)."""
    return float(_margsums(col, True, True, False)[0])


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
