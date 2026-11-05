# Herkunft:           übersetzt aus R 4.3.3, src/library/stats/src/approx.c, filter.c; nachgebildet
#                     nach R 4.3.3, src/library/stats/R/approx.R, filter.R
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang; seit 1.6.0 rechnen regularize.values und filter im C-Kern
#                     core/slc_rbase_smooth.cpp (sl_r_regularize, sl_r_filter_conv, sl_r_filter_rec).
"""Interpolation und Filter (``approx``, ``approxfun``, ``filter``), nachgebildet aus R 4.3.3
``stats/R/approx.R``, ``filter.R`` und ``stats/src/approx.c``, ``filter.c``. Die Interpolation je Punkt
(``approx.c``) rechnet seit 1.5.0 der C-Kern ``sl_r_approx`` (core/slc_rbase.cpp).

Seit 1.0.0 entfallen ``fft``, ``bw.nrd0``, ``density``, ``smooth.spline`` und
``predict.smooth.spline``: SimLev nutzt die eigene Gauß-Kerndichte und den eigenen
Glättungsspline der C-Bibliothek slc (:mod:`simlev._lib`).
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd

from .. import _ext   # C-Kerne sl_r_approx (core/slc_rbase.cpp), slc_rbase_smooth.cpp (seit 1.6.0)
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
    # C-Kern sl_r_regularize (seit 1.6.0): NA-Paare, Sortierung, Gruppen gleicher x, mean je Gruppe
    if isinstance(ties, str) and ties == "ordered":
        mode, fun = 2, None
    elif isinstance(ties, (list, tuple)) and len(ties) == 2 and callable(ties[1]):
        mode, fun = (1 if ties[0] == "ordered" else 0), ties[1]
    else:
        mode, fun = 0, ties
    mean = fun is None or fun is _rmean or fun == "mean"
    x_in, y_in = xv, yv
    n = xv.size
    xo, yo, grp = np.empty(n), np.empty(n), np.empty(n, dtype=np.int64)
    m, nout, collapsed, kept_na = _ext.slc_r_regularize(np.ascontiguousarray(xv), np.ascontiguousarray(yv),
                                                         bool(na_rm), mode, mean, xo, yo, grp)
    xv = xo[:nout]
    if collapsed:
        if warn_collapsing:
            _warn("collapsing to unique 'x' values")
        if not mean:
            ys, g = yo[:m], grp[:m]
            yo = np.array([float(fun(ys[g == k])) for k in range(nout)])
    yv = yo[:nout]
    # notNA wie R: ohne Zusammenfassen die Maske der Eingabe (vor dem Sortieren), sonst !is.na(x)
    ok = None
    if kept_na:
        ok = ~np.isnan(xv) if collapsed else ~(np.isnan(x_in) | np.isnan(y_in))
    return xv, yv, kept_na, ok


def _approx_core(x, y, v, method, yleft, yright, f):
    """R_approxfun: Interpolation je Punkt im C-Kern ``sl_r_approx`` (core/slc_rbase.cpp, seit 1.5.0)."""
    out = np.empty(v.size)
    _ext.slc_r_approx(np.ascontiguousarray(x, dtype=np.float64), np.ascontiguousarray(y, dtype=np.float64),
                      np.ascontiguousarray(v, dtype=np.float64), int(method), float(yleft), float(yright),
                      float(f), out)
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


def _seq_int(frm, to, n):
    """``seq.int(from, to, length.out = n)`` in ``approx``: Grenzen endlich (sonst Fehler wie R); sind from, to und
    Schritt ganzzahlig, liefert R ganze Zahlen (aus -0 wird 0)."""
    frm = float(frm)
    to = float(to)
    if not math.isfinite(frm):
        raise RError("'from' must be a finite number")
    if not math.isfinite(to):
        raise RError("'to' must be a finite number")
    out = seq_len_out(frm, to, n)
    n = int(n)
    rby = 0.0
    if n > 2:
        nint = float(n - 1)
        rby = to - frm
        rby = rby / nint if math.isfinite(rby) else to / nint - frm / nint
    lim = 2147483647.0
    if (-lim - 1 <= frm <= lim and -lim - 1 <= to <= lim and frm == math.trunc(frm)
            and (n <= 1 or to == math.trunc(to)) and (n <= 2 or rby == math.trunc(rby))):
        out = out + 0.0
    return out


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
            xo = _seq_int(xv[0], xv[nx - 1], n)
        else:
            xs = xv[notna]
            xo = _seq_int(xs[0], xs[-1], n)
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
    Y = np.empty((n, nser))
    if method == "convolution":
        if nf > n:
            raise RError("'filter' is longer than time series")
        sides = int(sides)
        if sides not in (1, 2):
            raise RError("argument 'sides' must be 1 or 2")
        ini = np.zeros((0, nser))
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
            if ncol == 1 and nser > 1:   # wie R (seit 1.6.0): dim(init) <- c(nf, nser) bzw. init[, 2]
                if ia.ndim == 2:
                    raise RError("subscript out of bounds")
                raise RError("dims [product %d] do not match the length of object [%d]" % (nf * nser, nf))
            ini = ia.reshape(nf, -1) if ia.ndim == 2 else ia.reshape(nf, 1)
    out = np.empty(n)
    for s in range(nser):   # C-Kerne sl_r_filter_conv, sl_r_filter_rec (seit 1.6.0)
        _ext.slc_r_filter(np.ascontiguousarray(X[:, s]), np.ascontiguousarray(fv), method == "recursive", sides,
                          bool(circular), np.ascontiguousarray(ini[:, s]), out)
        Y[:, s] = out
    if is_mat:
        return Y
    return Y[:, 0]


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
