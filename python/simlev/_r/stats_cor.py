# Herkunft:           übersetzt aus R 4.3.3, src/library/stats/src/cov.c; nachgebildet nach R 4.3.3,
#                     src/library/stats/R/cor.R; src/library/base/R/scale.R
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang: Kovarianz und Korrelation rechnet der C-Kern
#                     core/slc_rbase_cov.cpp, seit 1.6.0 Ränge, cov2cor und scale core/slc_rbase_cor.cpp.
"""Kovarianz und Korrelation (``cor``, ``cov``, ``var``, ``sd``, ``cov2cor``) sowie ``scale``, nachgebildet aus
R 4.3.3 ``src/library/stats/src/cov.c``, ``stats/R/cor.R`` und ``base/R/scale.R``.

Den Kern von ``cov``/``cor`` (pearson, kendall; alle ``use``) rechnet C (``core/slc_rbase_cov.cpp``, gemeinsam
mit Julia), seit 1.6.0 auch Ränge für kendall/spearman mit den NA-Regeln, ``cov2cor`` und ``scale``
(``core/slc_rbase_cor.cpp``); hier bleiben Argumentprüfung und die Ergebnisform.
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd

from .linalg import RError, _as_r, _as_matrix, _out
from .stats_sort import _NAN, _warn
from .. import _ext   # C-Kerne core/slc_rbase_cov.cpp, slc_rbase_cor.cpp (seit 1.6.0)

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


_METHODS = {"pearson": 0, "kendall": 1, "spearman": 2}


def _cor_cov(x, y, use, method, cor, need_xy=True):
    """R's ``cor``/``cov`` (C-Kern ``sl_r_cor``, seit 1.6.0: Ränge, NA-Regeln und paarweise Rangkorrelation im
    Kern); hier Argumente, Formen und Namen. ``need_xy = False`` (``var``): ein Vektor ohne ``y`` ist erlaubt (seit
    1.6.4 rechnet ``var`` hierüber statt über eine eigene Fassung ``_corcov`` mit ``sl_r_cov``; mit method = 0 prüft
    ``sl_r_cor`` dasselbe und rechnet ``sl_r_cov``)."""
    na_method = _pmatch_use(use)
    # seit 1.6.4 wie R match.arg (RP, C-056): Teilnamen ("k", "s"), NULL bzw. alle drei = "pearson"; bis 1.6.3 nur volle
    # Namen
    from .fmt import _r_match_arg
    try:
        method = _r_match_arg(method, ("pearson", "kendall", "spearman"))
    except ValueError as e:
        raise RError(str(e)) from None
    is_mat = isinstance(x, pd.DataFrame) or (isinstance(x, np.ndarray) and x.ndim == 2)
    if need_xy and not is_mat and y is None:
        raise RError("supply both 'x' and 'y' or a matrix-like 'x'")
    if x is None:   # NULL wie R 4.3.3 (seit 1.6.4, K43 RS; bis dahin NA bzw. „incompatible dimensions“)
        if not need_xy:
            raise RError("'x' is NULL")               # var: C_cov
        raise RError("'x' must be numeric" if cor else "is.numeric(x) || is.logical(x) is not TRUE")
    X, xmat, xcn = _as_cov_input(x)
    n, ncx = X.shape
    ansmat = xmat
    Y, ycn, ncy, ymat = None, None, ncx, False
    if y is not None:
        Y, ymat, ycn = _as_cov_input(y)
        if Y.shape[0] != n:
            raise RError("incompatible dimensions")
        ansmat = ansmat or ymat
        ncy = Y.shape[1]
    ans = np.empty(ncx * ncy)
    try:
        sd0 = _ext.slc_r_cor(np.ascontiguousarray(X.ravel(order="F")), n, ncx, xmat,
                             None if Y is None else np.ascontiguousarray(Y.ravel(order="F")), ncy, ymat,
                             na_method, _METHODS[method], bool(cor), ans)
    except ValueError as e:
        raise RError(str(e)) from None
    if sd0:
        _warn("the standard deviation is zero")
    ans = ans.reshape((ncx, ncy), order="F")
    if na_method == 3 and method != "pearson" and y is None and ncx == 1:
        # R: r + t(r) - diag(diag(r)); diag() eines Skalars baut eine Einheitsmatrix
        d = ans[0, 0]
        if d != d:
            raise RError("invalid 'nrow' value (too large or NA)")
        m = int(d)
        if m < 0:
            raise RError("invalid 'nrow' value (< 0)")
        if m != 1:
            raise RError("non-conformable arrays")
        ans = (ans + ans) - 1.0
    if ansmat:
        return _out(ans, xcn, xcn if y is None else ycn)
    v = ans.ravel(order="F")
    if v.size == 1:
        return float(v[0])
    return v


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
    return _cor_cov(x, y, use, "pearson", False, need_xy=False)


def sd(x, na_rm=False):
    """``sd(x, na.rm)`` = ``sqrt(var(x, na.rm))``."""
    if isinstance(x, pd.DataFrame) or (isinstance(x, np.ndarray) and x.ndim == 2):
        x = np.asarray(x, dtype=np.float64).ravel(order="F")
    elif x is None:                     # R: as.double(NULL) = numeric(0), also NA (seit 1.6.4 ausdrücklich, K43 RS)
        x = np.empty(0, dtype=np.float64)
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
    r = np.empty(p * p)
    if _ext.slc_r_cov2cor(np.ascontiguousarray(m.mat(), dtype=np.float64).ravel(order="F"), p, r):   # C-Kern (seit 1.6.0)
        _warn("diag(V) had non-positive or NA entries; the non-finite result may be dubious")
    r = r.reshape((p, p), order="F")
    return _out(r, m.rn, m.cn)


def scale(x, center=True, scale=True):
    """``scale.default(x, center, scale)``; Ergebnis-Matrix mit Attributen
    ``scaled_center``/``scaled_scale`` (als Attribute des Rückgabeobjekts
    nicht möglich – daher Tupel-frei: ``ndarray`` und ``.attrs`` bei DataFrame)."""
    m = _as_matrix(x)
    X = m.mat()
    nr, nc = X.shape
    cen = None
    sc = None
    cm = 1 if (isinstance(center, (bool, np.bool_)) and center) else 0
    if not isinstance(center, (bool, np.bool_)):
        cen = np.asarray(center, dtype=np.float64).ravel()
        if cen.size != nc:
            raise RError("length of 'center' must equal the number of columns of 'x'")
        cm = 2
    sm = 1 if (isinstance(scale, (bool, np.bool_)) and scale) else 0
    if not isinstance(scale, (bool, np.bool_)):
        sc = np.asarray(scale, dtype=np.float64).ravel()
        if sc.size != nc:
            raise RError("length of 'scale' must equal the number of columns of 'x'")
        sm = 2
    cen = np.empty(nc) if cm == 1 else (np.ascontiguousarray(cen) if cm == 2 else None)
    sc = np.empty(nc) if sm == 1 else (np.ascontiguousarray(sc) if sm == 2 else None)
    xf = np.array(X, dtype=np.float64).ravel(order="F")
    _ext.slc_r_scale(xf, nr, nc, cm, cen if cen is not None else np.zeros(nc), sm,
                     sc if sc is not None else np.zeros(nc))   # C-Kern sl_r_scale (seit 1.6.0)
    X = xf.reshape((nr, nc), order="F")
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

    # seit 1.6.4 (C-046): die Attribute gehen beim Pickeln mit (bis 1.6.3 fielen sie weg)
    def __reduce__(self):
        f, a, st = super().__reduce__()
        return f, a, (st, self.scaled_center, self.scaled_scale)

    def __setstate__(self, state):
        st, c, sc = state
        super().__setstate__(st)
        self.scaled_center = c
        self.scaled_scale = sc


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
