# Herkunft:           übersetzt aus R 4.3.3, src/library/stats/src/approx.c, filter.c; nachgebildet
#                     nach R 4.3.3, src/library/stats/R/approx.R, filter.R
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang; seit 1.6.0 rechnen regularize.values und filter im C-Kern
#                     core/slc_rbase_smooth.cpp (sl_r_regularize, sl_r_filter_conv, sl_r_filter_rec).
"""Interpolation und Filter (``approx``, ``filter``), nachgebildet aus R 4.3.3
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

__all__ = ["approx", "filter"]


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
    # seit 1.6.4 wie R stopifnot(is.numeric(rule), (lenR <- length(rule)) >= 1L, lenR <= 2L) (C-061)
    ra = np.atleast_1d(np.asarray(rule, dtype=object)).ravel()
    if not all(isinstance(v, (int, float, np.integer, np.floating)) and not isinstance(v, (bool, np.bool_))
               for v in ra) or (len(ra) and all(v is None for v in ra)):
        raise RError("is.numeric(rule) is not TRUE")
    if len(ra) < 1:
        raise RError("(lenR <- length(rule)) >= 1L is not TRUE")
    if len(ra) > 2:
        raise RError("lenR <= 2L is not TRUE")
    rule = [float(v) for v in ra]
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
        if rule[0] != rule[0]:
            raise RError("missing value where TRUE/FALSE needed")
        yleft = NA_REAL if rule[0] == 1 else float(yv[0])
    if yright is None:
        if rule[1] != rule[1]:
            raise RError("missing value where TRUE/FALSE needed")
        yright = NA_REAL if rule[1] == 1 else float(yv[-1])
    # seit 1.6.4 wie R stopifnot(length(yleft) == 1L, length(yright) == 1L, length(f) == 1L) (T4-R3; bis dahin roher
    # TypeError); die f- und NA-Prüfung (C_ApproxTest) folgt in approx erst nach n und xout
    for nm, v in (("yleft", yleft), ("yright", yright), ("f", f)):
        if _rlen(v) != 1:
            raise RError("length(%s) == 1L is not TRUE" % nm)
    return xv, yv, method, _one(yleft), _one(yright), nona, notna, nx, _one(f)


def _rlen(v):
    """``length(v)`` für ein Argument (None = NULL, Skalar 1, sonst Zahl der Elemente)."""
    if v is None:
        return 0
    if isinstance(v, (str, bytes)) or np.isscalar(v):
        return 1
    return int(np.size(np.asarray(v, dtype=object)))


def _one(v):
    """Wert eines Arguments der Länge 1 als float (Skalar wie bisher float(v))."""
    if isinstance(v, (str, bytes)) or np.isscalar(v):
        return float(v)
    return float(np.asarray(v, dtype=object).ravel()[0])


def _approx_test(xv, yv, method, f, na_rm):
    """R's C_ApproxTest: f bei method "constant", dann NA in x (und y bei na.rm)."""
    if method == 2:
        if not math.isfinite(f) or f < 0 or f > 1:
            raise RError("approx(): invalid f value")
    if na_rm:
        if np.isnan(xv).any() or np.isnan(yv).any():
            raise RError("approx(): attempted to interpolate NA values")
    else:
        if np.isnan(xv).any():
            raise RError("approx(x,y, .., na.rm=FALSE): NA values in x are not allowed")


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
    n = int(math.ceil(float(n)))   # seit 1.6.4 wie R aufgerundet (C-061)
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
    # Reihenfolge der Prüfungen seit 1.6.4 wie stats::approx 4.3.3 (T4-R3): method, rule, Werte, yleft/yright/f-Längen,
    # n und xout, dann f und NA (C_ApproxTest)
    xv, yv, meth, yl, yr, nona, notna, nx, f = _approx_setup(
        x, y, method, yleft, yright, rule, f, _rmean if ties is None else ties, na_rm, ties_missing)
    if xout is None:
        if n is None:
            raise RError("argument is of length zero")
        if n != n:
            raise RError("missing value where TRUE/FALSE needed")
        if n <= 0:
            raise RError("'approx' requires n >= 1")
        if nona:
            xo = _seq_int(xv[0], xv[nx - 1], n)
        else:
            xs = xv[notna]
            xo = _seq_int(xs[0], xs[-1], n)
    _approx_test(xv, yv, meth, f, na_rm)
    if xout is not None:
        xo, _ = _vec(xout)
    res = _XY()
    res["x"] = xo if xout is None else (xout if not np.isscalar(xout) else float(xout))
    yo = _approx_core(xv, yv, xo, meth, yl, yr, f)
    res["y"] = float(yo[0]) if np.isscalar(xout) else yo
    return res


def _as_int1(v):
    """``as.integer(v)[1]`` für einen Wert (abgeschnitten; NA, Text ohne Zahl, ±Inf → ``None``)."""
    v = v[0] if isinstance(v, (list, tuple, np.ndarray)) and len(v) else v
    if v is None or isinstance(v, (list, tuple, np.ndarray)):
        return None
    if isinstance(v, str):
        try:
            v = float(v.strip())
        except ValueError:
            return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    if f != f or not -2147483648.0 < f < 2147483648.0:
        return None
    return int(math.trunc(f))


def _as_lgl1(v):
    """``as.logical(v)[1]`` für einen Wert (Text "TRUE"/"true"/"T"/"True" bzw. "FALSE"/…; Zahl != 0; sonst ``None``)."""
    v = v[0] if isinstance(v, (list, tuple, np.ndarray)) and len(v) else v
    if v is None or isinstance(v, (list, tuple, np.ndarray)):
        return None
    if isinstance(v, (bool, np.bool_)):
        return bool(v)
    if isinstance(v, str):
        return True if v in ("TRUE", "true", "T", "True") else False if v in ("FALSE", "false", "F", "False") else None
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return None if f != f else f != 0


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
    if n == 0:   # seit 1.6.4 wie R as.ts(x) (C-052)
        raise RError("'ts' object must have one or more observations")
    fv = np.atleast_1d(np.asarray(filter, dtype=np.float64)).ravel()
    nf = fv.size
    if np.isnan(fv).any():
        raise RError("missing values in 'filter'")
    Y = np.empty((n, nser))
    if method == "convolution":
        if nf > n:
            raise RError("'filter' is longer than time series")
        sv = _as_int1(sides)   # seit 1.6.4 wie R as.integer(sides), NA mit Meldung (C-052)
        if sv is None or sv not in (1, 2):
            raise RError("argument 'sides' must be 1 or 2")
        sides = sv
        cv = _as_lgl1(circular)
        if cv is None:
            raise RError("'circular' must be logical and not NA")
        circular = cv
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
        _ext.slc_r_filter(np.ascontiguousarray(X[:, s]), np.ascontiguousarray(fv), method == "recursive",
                          sides if method == "convolution" else 2, circular is True, np.ascontiguousarray(ini[:, s]), out)
        Y[:, s] = out
    if is_mat:
        return Y
    return Y[:, 0]


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
