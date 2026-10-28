"""Interpolation und Filter (``approx``, ``approxfun``, ``filter``), nachgebildet aus R 4.3.3
``stats/R/approx.R``, ``filter.R`` und ``stats/src/approx.c``, ``filter.c``.

Seit Etappe 9.6c entfallen ``fft``, ``bw.nrd0``, ``density``, ``smooth.spline`` und
``predict.smooth.spline``: SimLev nutzt die eigene Gauß-Kerndichte und den eigenen
Glättungsspline der C-Bibliothek slc (:mod:`simlev._lib`, Entwurf B.15, B.16).
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd

from .linalg import RError
from .rlist import RList
from .rnum import NA_REAL
from .stats_sort import _rmean, _vec, _warn, seq_len_out

__all__ = ["approx", "approxfun", "filter"]


# ── approx / filter ──────────────────────────────────────────────────────

def _regularize(x, y, ties, warn_collapsing, na_rm):
    xv, _ = _vec(x)
    if y is None:
        yv = xv
        xv = np.arange(1, xv.size + 1, dtype=np.float64)
    else:
        yv, _ = _vec(y)
    if xv.size != yv.size:
        raise RError("'x' and 'y' lengths differ")
    kept_na = False
    na = np.isnan(xv) | np.isnan(yv)
    ok = ~na
    if na.any():
        if na_rm:
            xv = xv[ok]
            yv = yv[ok]
            nx = xv.size
        else:
            kept_na = True
            nx = int(ok.sum())
    else:
        nx = xv.size
    ordered = False
    fun = ties
    if isinstance(ties, str) and ties == "ordered":
        ordered = True
        fun = None
    elif isinstance(ties, (list, tuple)) and len(ties) == 2 and callable(ties[1]):
        fun = ties[1]
        ordered = ties[0] == "ordered"
    if not (isinstance(ties, str) and ties == "ordered"):
        xx = xv[ok] if kept_na else xv
        if not ordered and xx.size > 1 and (np.diff(xx) < 0).any():
            o = np.argsort(xv, kind="stable")
            xv = xv[o]
            yv = yv[o]
        ux = pd.unique(xv)
        if ux.size < nx:
            if warn_collapsing:
                _warn("collapsing to unique 'x' values")
            if fun is None or fun is _rmean or fun == "mean":
                f = _rmean
            else:
                f = fun
            groups = {}
            keys = []
            for xi, yi in zip(xv.tolist(), yv.tolist()):
                k = xi if xi == xi else "NA"
                if k not in groups:
                    groups[k] = []
                    keys.append(k)
                groups[k].append(yi)
            yv = np.array([float(f(np.array(groups[k]))) for k in keys])
            xv = np.asarray(ux, dtype=np.float64)
            if kept_na:
                ok = ~np.isnan(xv)
    return xv, yv, kept_na, (ok if kept_na else None)


def _approx_core(x, y, v, method, yleft, yright, f):
    n = x.size
    out = np.empty(v.size)
    if n == 0:
        out[:] = np.nan
        return out
    f2 = f
    f1 = 1 - f
    with np.errstate(all="ignore"):
        for k, vk in enumerate(v.tolist()):
            if vk != vk:
                out[k] = vk
                continue
            i = 0
            j = n - 1
            if vk < x[i]:
                out[k] = yleft
                continue
            if vk > x[j]:
                out[k] = yright
                continue
            while i < j - 1:
                ij = (i + j) // 2
                if vk < x[ij]:
                    j = ij
                else:
                    i = ij
            if vk == x[j]:
                out[k] = y[j]
                continue
            if vk == x[i]:
                out[k] = y[i]
                continue
            if method == 1:
                out[k] = y[i] + (y[j] - y[i]) * ((vk - x[i]) / (x[j] - x[i]))
            else:
                out[k] = (y[i] * f1 if f1 != 0.0 else 0.0) + (y[j] * f2 if f2 != 0.0 else 0.0)
    return out


def _approx_setup(x, y, method, yleft, yright, rule, f, ties, na_rm, ties_missing):
    meth = {"linear": 1, "constant": 2}
    m = [v for k, v in meth.items() if k.startswith(method)] if method else []
    if len(m) != 1:
        raise RError("invalid interpolation method")
    method = m[0]
    rule = list(np.atleast_1d(rule))
    if len(rule) == 1:
        rule = rule * 2
    xv, yv, kept_na, notna = _regularize(x, y, ties, ties_missing, na_rm)
    nona = na_rm or not kept_na
    nx = xv.size if nona else int(notna.sum())
    if nx <= 1:
        if method == 1:
            raise RError("need at least two non-NA values to interpolate")
        if nx == 0:
            raise RError("zero non-NA points")
    if yleft is None:
        yleft = NA_REAL if rule[0] == 1 else float(yv[0])
    if yright is None:
        yright = NA_REAL if rule[1] == 1 else float(yv[-1])
    if method == 2:
        if not math.isfinite(f) or f < 0 or f > 1:
            raise RError("approx(): invalid f value")
    if na_rm:
        if np.isnan(xv).any() or np.isnan(yv).any():
            raise RError("approx(): attempted to interpolate NA values")
    else:
        if np.isnan(xv).any():
            raise RError("approx(x,y, .., na.rm=FALSE): NA values in x are not allowed")
    return xv, yv, method, float(yleft), float(yright), nona, notna, nx


class _XY(RList):
    pass


def approx(x, y=None, xout=None, method="linear", n=50, yleft=None, yright=None, rule=1, f=0,
           ties=None, na_rm=True):
    """``approx(x, y, xout, method, n, yleft, yright, rule, f, ties, na.rm)``.

    ``ties=None`` entspricht R's Voreinstellung ``mean`` (mit Warnung beim
    Zusammenfassen); ``"ordered"``, eine Funktion oder ``("ordered", fun)``.
    Ergebnis: ``RList`` mit ``x`` und ``y``.
    """
    ties_missing = ties is None
    xv, yv, meth, yl, yr, nona, notna, nx = _approx_setup(
        x, y, method, yleft, yright, rule, float(f), _rmean if ties is None else ties, na_rm, ties_missing)
    if xout is None:
        if n <= 0:
            raise RError("'approx' requires n >= 1")
        if nona:
            xo = seq_len_out(xv[0], xv[nx - 1], n)
        else:
            xs = xv[notna]
            xo = seq_len_out(xs[0], xs[-1], n)
    else:
        xo, _ = _vec(xout)
    res = _XY()
    res["x"] = xo if xout is None else (xout if not np.isscalar(xout) else float(xout))
    yo = _approx_core(xv, yv, xo, meth, yl, yr, float(f))
    res["y"] = float(yo[0]) if np.isscalar(xout) else yo
    return res


def approxfun(x, y=None, method="linear", yleft=None, yright=None, rule=1, f=0, ties=None, na_rm=True):
    """``approxfun(...)``: liefert eine Funktion ``v -> y``."""
    ties_missing = ties is None
    xv, yv, meth, yl, yr, nona, notna, nx = _approx_setup(
        x, y, method, yleft, yright, rule, float(f), _rmean if ties is None else ties, na_rm, ties_missing)
    ff = float(f)

    def fun(v):
        vv, _ = _vec(v)
        out = _approx_core(xv, yv, vv, meth, yl, yr, ff)
        if np.isscalar(v):
            return float(out[0])
        return out
    fun.x = xv
    fun.y = yv
    return fun


def filter(x, filter, method="convolution", sides=2, circular=False, init=None):
    """``filter(x, filter, method, sides, circular, init)`` (ohne ts-Attribute)."""
    meth = [m for m in ("convolution", "recursive") if m.startswith(method)]
    if len(meth) != 1:
        raise RError("'arg' should be one of “convolution”, “recursive”")
    method = meth[0]
    X = np.asarray(x.to_numpy() if isinstance(x, (pd.Series, pd.DataFrame)) else x, dtype=np.float64)
    is_mat = X.ndim == 2
    if not is_mat:
        X = X.reshape(-1, 1)
    n, nser = X.shape
    fv = np.atleast_1d(np.asarray(filter, dtype=np.float64)).ravel()
    nf = fv.size
    if np.isnan(fv).any():
        raise RError("missing values in 'filter'")
    Y = np.full((n, nser), NA_REAL)
    with np.errstate(all="ignore"):
        if method == "convolution":
            if nf > n:
                raise RError("'filter' is longer than time series")
            sides = int(sides)
            if sides not in (1, 2):
                raise RError("argument 'sides' must be 1 or 2")
            nshift = nf // 2 if sides == 2 else 0
            for s in range(nser):
                xs = X[:, s]
                if not circular:
                    i = np.arange(n)
                    valid = (i + nshift - (nf - 1) >= 0) & (i + nshift < n)
                    iv = i[valid]
                    z = np.zeros(iv.size)
                    bad = np.zeros(iv.size, dtype=bool)
                    for j in range(nf):
                        t = xs[iv + nshift - j]
                        bad |= np.isnan(t)
                        z = z + fv[j] * t
                    z[bad] = NA_REAL
                    Y[iv, s] = z
                else:
                    i = np.arange(n)
                    z = np.zeros(n)
                    bad = np.zeros(n, dtype=bool)
                    for j in range(nf):
                        ii = i + nshift - j
                        ii = np.where(ii < 0, ii + n, ii)
                        ii = np.where(ii >= n, ii - n, ii)
                        t = xs[ii]
                        bad |= np.isnan(t)
                        z = z + fv[j] * t
                    z[bad] = NA_REAL
                    Y[:, s] = z
        else:
            if init is None:
                ini = np.zeros((nf, nser))
            else:
                ia = np.asarray(init, dtype=np.float64)
                ni = ia.shape[0] if ia.ndim >= 1 else 1
                if ia.ndim == 0:
                    ia = ia.reshape(1)
                    ni = 1
                if ni != nf:
                    raise RError("length of 'init' must equal length of 'filter'")
                ncol = ia.shape[1] if ia.ndim == 2 else 1
                if ncol != 1 and ncol != nser:
                    if nser == 1:
                        raise RError("'init' must have %d column" % nser)
                    raise RError("'init' must have 1 or %d columns" % nser)
                ini = ia.reshape(nf, -1) if ia.ndim == 2 else ia.reshape(nf, 1)
                if ini.shape[1] == 1 and nser > 1:
                    ini = np.repeat(ini, nser, axis=1)
            for s in range(nser):
                r = np.concatenate([ini[::-1, s], np.zeros(n)]).tolist()
                xs = X[:, s].tolist()
                fl = fv.tolist()
                for i in range(n):
                    sm = xs[i]
                    if sm != sm:
                        r[nf + i] = NA_REAL
                        continue
                    badf = False
                    for j in range(nf):
                        tmp = r[nf + i - j - 1]
                        if tmp == tmp:
                            sm += tmp * fl[j]
                        else:
                            r[nf + i] = NA_REAL
                            badf = True
                            break
                    if not badf:
                        r[nf + i] = sm
                Y[:, s] = r[nf:]
    if is_mat:
        return Y
    return Y[:, 0]


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
