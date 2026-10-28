"""Kovarianz und Korrelation (``cor``, ``cov``, ``var``, ``sd``, ``cov2cor``) sowie ``scale``, nachgebildet aus
R 4.3.3 ``src/library/stats/src/cov.c``, ``stats/R/cor.R`` und ``base/R/scale.R``.
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd

from .linalg import RError, _as_r, _as_matrix, _out
from .rnum import NA_REAL
from .stats_sort import LD, _NAN, _rsum, _warn, rank

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


def _mean_ind(col, ind, nobs):
    """MEAN-Makro: zwei Durchläufe in long double; Ergebnis double."""
    xl = col[ind].astype(LD)
    s = np.cumsum(xl)[-1] if xl.size else LD(0)
    tmp = s / LD(nobs)
    if math.isfinite(float(tmp)):
        s2 = np.cumsum(xl - tmp)[-1] if xl.size else LD(0)
        tmp = tmp + s2 / LD(nobs)
    return float(tmp)


def _sign(a):
    return np.sign(a)


def _kendall_sum(xx, yy):
    """sum_k sum_n1 sign(xx[k]-xx[n1]) * sign(yy[k]-yy[n1]) (exakt, ganzzahlig)."""
    n = xx.size
    tot = 0
    step = max(1, 4000000 // max(1, n))
    for s in range(0, n, step):
        e = min(n, s + step)
        sx = np.sign(xx[s:e, None] - xx[None, :])
        sy = np.sign(yy[s:e, None] - yy[None, :])
        tot += int(np.sum(sx * sy, dtype=np.int64)) if True else 0
    return float(tot)


def _kendall_count_ne(xx):
    n = xx.size
    tot = 0
    step = max(1, 4000000 // max(1, n))
    for s in range(0, n, step):
        e = min(n, s + step)
        tot += int(np.count_nonzero(xx[s:e, None] != xx[None, :]))
    return float(tot)


def _corcov(x, y, method_na, kendall, cor):
    X, xmat, xcn = _as_cov_input(x)
    n, ncx = X.shape
    ansmat = xmat
    if y is None:
        Y = None
        ncy = ncx
        ycn = None
    else:
        Y, ymat, ycn = _as_cov_input(y)
        if ymat:
            if Y.shape[0] != n:
                raise RError("incompatible dimensions")
            ansmat = True
        else:
            if Y.shape[0] != n:
                raise RError("incompatible dimensions")
        ncy = Y.shape[1]
    na_fail = False
    everything = False
    empty_err = True
    pair = False
    if method_na == 1:
        na_fail = True
    elif method_na == 2:
        if X.size == 0:
            raise RError("no complete element pairs")
    elif method_na == 3:
        pair = True
    elif method_na == 4:
        everything = True
        empty_err = False
    elif method_na == 5:
        empty_err = False
    else:
        raise RError("invalid 'use' (computational method)")
    if empty_err and X.size == 0:
        raise RError("'x' is empty")
    ans = np.full((ncx, ncy), NA_REAL)
    sd0 = [False]
    with np.errstate(all="ignore"):
        if Y is None:
            if everything:
                has_na = np.isnan(X).any(axis=0) if n else np.zeros(ncx, dtype=bool)
                _cov_na_1(X, has_na, ans, sd0, cor, kendall)
            elif not pair:
                ind = _complete(X, None, na_fail)
                _cov_complete1(X, ind, ans, sd0, cor, kendall)
                if empty_err and not ind.any():
                    raise RError("no complete element pairs")
            else:
                _cov_pairwise(X, X, ans, sd0, cor, kendall, sym=True)
        else:
            if everything:
                hx = np.isnan(X).any(axis=0) if n else np.zeros(ncx, dtype=bool)
                hy = np.isnan(Y).any(axis=0) if n else np.zeros(ncy, dtype=bool)
                _cov_na_2(X, Y, hx, hy, ans, sd0, cor, kendall)
            elif not pair:
                ind = _complete(X, Y, na_fail)
                _cov_complete2(X, Y, ind, ans, sd0, cor, kendall)
                if empty_err and not ind.any():
                    raise RError("no complete element pairs")
            else:
                _cov_pairwise(X, Y, ans, sd0, cor, kendall, sym=False)
    if sd0[0]:
        _warn("the standard deviation is zero")
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


def _complete(X, Y, na_fail):
    ind = ~np.isnan(X).any(axis=1)
    if Y is not None:
        ind &= ~np.isnan(Y).any(axis=1)
    if na_fail and not ind.all():
        raise RError("missing observations in cov/cor")
    return ind


def _ld_cross(a, am, b, bm):
    """sum (LD)(a - am) * (b - bm) mit am, bm als long double."""
    if a.size == 0:
        return LD(0)
    d1 = a.astype(LD) - LD(am)
    d2 = b.astype(LD) - LD(bm)
    return np.cumsum(d1 * d2)[-1]


def _clamp(v):
    return 1.0 if v >= 1.0 else (-1.0 if v <= -1.0 else v)


def _cov_complete1(X, ind, ans, sd0, cor, kendall):
    n, ncx = X.shape
    nobs = int(ind.sum())
    if nobs <= 1:
        ans[:, :] = NA_REAL
        return
    xm = np.zeros(ncx)
    if not kendall:
        for i in range(ncx):
            xm[i] = _mean_ind(X[:, i], ind, nobs)
        n1 = nobs - 1
    Xi = X[ind]
    for i in range(ncx):
        if not kendall:
            for j in range(i + 1):
                s = _ld_cross(Xi[:, i], xm[i], Xi[:, j], xm[j])
                ans[i, j] = ans[j, i] = float(s / LD(n1))
        else:
            for j in range(i + 1):
                s = _kendall_sum(Xi[:, i], Xi[:, j])
                ans[i, j] = ans[j, i] = s
    if cor:
        for i in range(ncx):
            xm[i] = math.sqrt(ans[i, i]) if ans[i, i] >= 0 else _NAN
        for i in range(ncx):
            for j in range(i):
                if xm[i] == 0 or xm[j] == 0:
                    sd0[0] = True
                    ans[i, j] = ans[j, i] = NA_REAL
                else:
                    s = ans[i, j] / (xm[i] * xm[j])
                    ans[i, j] = ans[j, i] = _clamp(s)
            ans[i, i] = 1.0


def _mean_all(col):
    n = col.size
    xl = col.astype(LD)
    s = np.cumsum(xl)[-1]
    tmp = s / LD(n)
    if math.isfinite(float(tmp)):
        s2 = np.cumsum(xl - tmp)[-1]
        tmp = tmp + s2 / LD(n)
    return float(tmp)


def _cov_na_1(X, has_na, ans, sd0, cor, kendall):
    n, ncx = X.shape
    if n <= 1:
        ans[:, :] = NA_REAL
        return
    # kendall: R lässt xm[] für NA-Spalten uninitialisiert (kein sd_0-Treffer)
    xm = np.full(ncx, _NAN)
    if not kendall:
        for i in range(ncx):
            xm[i] = NA_REAL if has_na[i] else _mean_all(X[:, i])
        n1 = n - 1
    for i in range(ncx):
        if has_na[i]:
            ans[i, :i + 1] = NA_REAL
            ans[:i + 1, i] = NA_REAL
            continue
        for j in range(i + 1):
            if has_na[j]:
                ans[i, j] = ans[j, i] = NA_REAL
            elif not kendall:
                s = _ld_cross(X[:, i], xm[i], X[:, j], xm[j])
                ans[i, j] = ans[j, i] = float(s / LD(n1))
            else:
                ans[i, j] = ans[j, i] = _kendall_sum(X[:, i], X[:, j])
    if cor:
        for i in range(ncx):
            if not has_na[i]:
                xm[i] = math.sqrt(ans[i, i]) if ans[i, i] >= 0 else _NAN
        for i in range(ncx):
            if not has_na[i]:
                for j in range(i):
                    if xm[i] == 0 or xm[j] == 0:
                        sd0[0] = True
                        ans[i, j] = ans[j, i] = NA_REAL
                    else:
                        s = ans[i, j] / (xm[i] * xm[j])
                        ans[i, j] = ans[j, i] = _clamp(s)
            ans[i, i] = 1.0


def _sdev2(col, m, n1, kendall):
    """COV_SDEV aus cov_complete2/cov_na_2: (double) SQRTL(sum)."""
    if not kendall:
        s = _ld_cross(col, m, col, m) / LD(n1)
    else:
        s = LD(_kendall_count_ne(col))
    return float(np.sqrt(s))


def _cov_complete2(X, Y, ind, ans, sd0, cor, kendall):
    n, ncx = X.shape
    ncy = Y.shape[1]
    nobs = int(ind.sum())
    if nobs <= 1:
        ans[:, :] = NA_REAL
        return
    xm = np.zeros(ncx)
    ym = np.zeros(ncy)
    n1 = nobs - 1
    if not kendall:
        for i in range(ncx):
            xm[i] = _mean_ind(X[:, i], ind, nobs)
        for i in range(ncy):
            ym[i] = _mean_ind(Y[:, i], ind, nobs)
    Xi = X[ind]
    Yi = Y[ind]
    for i in range(ncx):
        for j in range(ncy):
            if not kendall:
                s = _ld_cross(Xi[:, i], xm[i], Yi[:, j], ym[j])
                ans[i, j] = float(s / LD(n1))
            else:
                ans[i, j] = _kendall_sum(Xi[:, i], Yi[:, j])
    if cor:
        xs = np.array([_sdev2(Xi[:, i], xm[i], n1, kendall) for i in range(ncx)])
        ys = np.array([_sdev2(Yi[:, j], ym[j], n1, kendall) for j in range(ncy)])
        for i in range(ncx):
            for j in range(ncy):
                if xs[i] == 0.0 or ys[j] == 0.0:
                    sd0[0] = True
                    ans[i, j] = NA_REAL
                else:
                    ans[i, j] = _clamp(ans[i, j] / (xs[i] * ys[j]))


def _cov_na_2(X, Y, hx, hy, ans, sd0, cor, kendall):
    n, ncx = X.shape
    ncy = Y.shape[1]
    if n <= 1:
        ans[:, :] = NA_REAL
        return
    xm = np.zeros(ncx)
    ym = np.zeros(ncy)
    n1 = n - 1
    if not kendall:
        for i in range(ncx):
            xm[i] = NA_REAL if hx[i] else _mean_all(X[:, i])
        for i in range(ncy):
            ym[i] = NA_REAL if hy[i] else _mean_all(Y[:, i])
    for i in range(ncx):
        if hx[i]:
            ans[i, :] = NA_REAL
            continue
        for j in range(ncy):
            if hy[j]:
                ans[i, j] = NA_REAL
            elif not kendall:
                ans[i, j] = float(_ld_cross(X[:, i], xm[i], Y[:, j], ym[j]) / LD(n1))
            else:
                ans[i, j] = _kendall_sum(X[:, i], Y[:, j])
    if cor:
        xs = np.array([NA_REAL if hx[i] else _sdev2(X[:, i], xm[i], n1, kendall) for i in range(ncx)])
        ys = np.array([NA_REAL if hy[j] else _sdev2(Y[:, j], ym[j], n1, kendall) for j in range(ncy)])
        for i in range(ncx):
            if hx[i]:
                continue
            for j in range(ncy):
                if hy[j]:
                    continue
                if xs[i] == 0.0 or ys[j] == 0.0:
                    sd0[0] = True
                    ans[i, j] = NA_REAL
                else:
                    ans[i, j] = _clamp(ans[i, j] / (xs[i] * ys[j]))


def _cov_pairwise(X, Y, ans, sd0, cor, kendall, sym):
    n, ncx = X.shape
    ncy = Y.shape[1]
    for i in range(ncx):
        jr = range(i + 1) if sym else range(ncy)
        for j in jr:
            xx = X[:, i]
            yy = Y[:, j]
            ok = ~(np.isnan(xx) | np.isnan(yy))
            nobs = int(ok.sum())
            if nobs >= 2:
                xo = xx[ok]
                yo = yy[ok]
                if not kendall:
                    xmean = np.cumsum(xo.astype(LD))[-1] / LD(nobs)
                    ymean = np.cumsum(yo.astype(LD))[-1] / LD(nobs)
                    n1 = nobs - 1
                    xmd = xo.astype(LD) - xmean
                    ymd = yo.astype(LD) - ymean
                    s = np.cumsum(xmd * ymd)[-1]
                    xsd = np.cumsum(xmd * xmd)[-1]
                    ysd = np.cumsum(ymd * ymd)[-1]
                else:
                    # sum over k, n1 < k (je Paar einmal)
                    s = LD(0)
                    xsd = LD(0)
                    ysd = LD(0)
                    m = xo.size
                    for k in range(m):
                        sx = np.sign(xo[k] - xo[:k])
                        sy = np.sign(yo[k] - yo[:k])
                        s += LD(float(np.sum(sx * sy)))
                        xsd += LD(float(np.sum(sx * sx)))
                        ysd += LD(float(np.sum(sy * sy)))
                if cor:
                    if xsd == 0 or ysd == 0:
                        sd0[0] = True
                        val = NA_REAL
                    else:
                        if not kendall:
                            xsd = xsd / LD(n1)
                            ysd = ysd / LD(n1)
                            s = s / LD(n1)
                        s = s / (np.sqrt(xsd) * np.sqrt(ysd))
                        s = LD(1) if s >= 1 else (LD(-1) if s <= -1 else s)
                        val = float(s)
                elif not kendall:
                    val = float(s / LD(n1))
                else:
                    val = float(s)
                ans[i, j] = val
            else:
                ans[i, j] = NA_REAL
            if sym:
                ans[j, i] = ans[i, j]


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
    ok = col[~np.isnan(col)]
    if ok.size == 0:
        return _NAN
    return float(np.cumsum(ok.astype(LD))[-1] / LD(ok.size))


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
