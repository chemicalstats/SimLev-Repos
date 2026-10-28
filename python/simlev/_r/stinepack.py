"""Nachbildung von stinepack 1.5 (Stineman-Interpolation), im R-Paket übernommen als ``.stinepack_stinterp``.

Herkunft: R-Paket stinepack 1.5 (CRAN, 2024-03-07), ``R/stinterp.R``,
``R/stinemanSlopes.R`` und ``R/parabolaSlopes.R``; Autoren: Tomas Johannesson
& Halldor Bjornsson, Icelandic Met. Office; Gabor Grothendieck. Lizenz:
GPL (>= 2), in SimLev unter GPL-3. Nach Python übertragen und angepasst für
SimLev (siehe ``python/COPYRIGHTS.md``).

Nachgebildet sind ``stinterp(x, y, xout, yp, method)`` mit allen
Eingabeprüfungen und Meldungen sowie die Steigungen ``stinemanSlopes``
(mit und ohne Skalierung) und ``parabolaSlopes``. Die Rechenreihenfolge
folgt dem R-Code Zeile für Zeile, auch in den Eigenheiten von stinepack:

* ``NA`` in ``y`` wird nicht geprüft (die Prüfung fragt zweimal ``x``) und
  läuft in die Rechnung;
* ``missing(yp)`` ist in R nach der Zuweisung der Steigungen ``FALSE``, der
  rationale Zweig wird darum auch für zwei Stützstellen ausgeführt;
* ``yo[id] <- …`` mit ``NA`` im logischen Index bricht wie in R mit
  "NAs are not allowed in subscripted assignments" ab, sobald mehr als ein
  Element ausgewählt ist; ``if`` mit ``NA`` mit
  "missing value where TRUE/FALSE needed".

imputeTS nutzt ``stinterp`` in ``na_interpolation(option = "stine")``
(siehe :mod:`simlev._r.imputets`); R nutzt die übernommene Fassung
(``r/R/vendor_stinepack.R``), stinepack selbst ist nicht mehr nötig.
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd

from .linalg import RError
from .rlist import RList
from .rnum import NA_REAL

__all__ = ["stinterp", "stinemanSlopes", "parabolaSlopes"]

_DBL_EPS = 2.220446049250313e-16


class _Missing:
    def __repr__(self):
        return "<fehlt>"


MISSING = _Missing()


# ── R-Logik (dreiwertig: True, False, None = NA) ────────────────────────────

def _cmp(a, b, op):
    if math.isnan(a) or math.isnan(b):
        return None
    return bool(op(a, b))


def _and(a, b):
    """R-``&&``: FALSE gewinnt, sonst NA vor TRUE."""
    if a is False:
        return False
    if a is True:
        return b
    return False if b is False else None


def _or(a, b):
    """R-``||``: TRUE gewinnt, sonst NA vor FALSE."""
    if a is True:
        return True
    if a is False:
        return b
    return True if b is True else None


def _if(v):
    """R-``if (v)``: NA ist ein Fehler."""
    if v is None:
        raise RError("missing value where TRUE/FALSE needed")
    return v


def _any3(flags):
    """R-``any()`` über dreiwertige Werte."""
    na = False
    for f in flags:
        if f is True:
            return True
        if f is None:
            na = True
    return None if na else False


def _isna_obj(v):
    return v is None or v is pd.NA or (isinstance(v, (float, np.floating)) and math.isnan(v))


def classify(x):
    """Atomaren R-Vektor erkennen: ``(typ, werte, ist_vektor)``.

    ``typ`` ist ``"num"`` (double/integer), ``"lgl"``, ``"chr"`` oder
    ``"null"``; ``werte`` ist bei ``"num"`` ein float64-Array (NA als R-NA),
    sonst ein object-Array; ``ist_vektor`` entspricht ``is.vector(x)``
    (Matrizen und data.frames: ``False``).
    """
    if x is None:
        return "null", np.zeros(0), False
    if isinstance(x, pd.DataFrame):
        return "df", None, False
    isvec = True
    if isinstance(x, pd.Series):
        a = x.to_numpy()
    elif isinstance(x, (list, tuple)):
        a = np.array(x, dtype=object) if any(_isna_obj(v) or isinstance(v, (str, bool, np.bool_)) for v in x) else np.asarray(x)
    else:
        a = np.asarray(x)
        if a.ndim > 1:
            isvec = False
    if a.ndim == 0:
        a = a.reshape(1)
    if a.dtype.kind in "iuf":
        return "num", np.asarray(a, dtype=np.float64).ravel(order="F"), isvec
    if a.dtype.kind == "b":
        return "lgl", a.astype(object).ravel(order="F"), isvec
    if a.dtype.kind in "USO":
        flat = a.ravel(order="F")
        vals = [v for v in flat if not _isna_obj(v)]
        if a.dtype.kind == "O" and (vals or any(isinstance(v, (float, np.floating)) for v in flat)) and \
                all(isinstance(v, (int, float, np.integer, np.floating)) and not isinstance(v, (bool, np.bool_)) for v in vals):
            return "num", np.array([NA_REAL if (v is None or v is pd.NA) else float(v) for v in flat], dtype=np.float64), isvec
        if a.dtype.kind == "O" and all(isinstance(v, (bool, np.bool_)) for v in vals):
            return "lgl", np.array([None if _isna_obj(v) else bool(v) for v in flat], dtype=object), isvec
        return "chr", np.array([None if _isna_obj(v) else str(v) for v in flat], dtype=object), isvec
    return "chr", a.astype(object).ravel(order="F"), isvec


def _isna_vals(kind, v):
    if kind == "num":
        return np.isnan(v)
    return np.array([_isna_obj(e) for e in v], dtype=bool)


def _match_method(method):
    """``match.arg(method)`` mit den Wahlen von stinterp."""
    choices = ("scaledstineman", "stineman", "parabola")
    if method is None:
        return choices[0]
    if isinstance(method, (list, tuple, np.ndarray)):
        if tuple(method) == choices:
            return choices[0]
        if len(method) != 1:
            raise RError("'arg' must be of length 1")
        method = method[0]
    if not isinstance(method, str):
        raise RError("'arg' must be NULL or a character vector")
    if method in choices:
        return method
    hits = [c for c in choices if c.startswith(method)] if method else []
    if len(hits) == 1:
        return hits[0]
    raise RError("'arg' should be one of %s" % ", ".join("“%s”" % c for c in choices))


# ── Steigungen ──────────────────────────────────────────────────────────────

def _range_diff(v):
    """``diff(range(v))`` für einen double-Vektor (NA/NaN ergeben NaN)."""
    if np.isnan(v).any():
        return math.nan
    return float(v.max()) - float(v.min())


def stinemanSlopes(x, y, scale=False):
    """Steigungen nach Stineman (stinepack ``stinemanSlopes``).

    Args:
        x: Stützstellen (streng steigend).
        y: Werte an den Stützstellen.
        scale: ``True``: x und y vorher auf ihre Spannweite skalieren
            (Voreinstellung von ``stinterp``, Methode "scaledstineman").

    Returns:
        float-Array der Steigungen an den Stützstellen.
    """
    x = np.array(classify(x)[1], dtype=np.float64)
    y = np.array(classify(y)[1], dtype=np.float64)
    m = x.size
    m1 = m - 1
    if m == 2:
        return np.repeat(np.diff(y) / np.diff(x), 2)
    if scale:
        sx = _range_diff(x)
        sy = _range_diff(y)
        if _if(_cmp(sy, 0.0, lambda a, b: a <= b)):
            sy = 1.0
        x = x / sx
        y = y / sy
    dx = np.diff(x)
    dy = np.diff(y)
    yp = np.full(m, NA_REAL)
    dxp, dyp = dx[1:], dy[1:]          # dx[-1], dy[-1]
    dxm, dym = dx[:-1], dy[:-1]        # dx[-m1], dy[-m1]
    dx2dy2p = dxp * dxp + dyp * dyp
    dx2dy2m = dxm * dxm + dym * dym
    yp[1:m1] = (dym * dx2dy2p + dyp * dx2dy2m) / (dxm * dx2dy2p + dxp * dx2dy2m)
    ge = lambda a, b: a >= b  # noqa: E731
    le = lambda a, b: a <= b  # noqa: E731
    for k, j, i in ((0, 1, 0), (m - 1, m1 - 1, m1 - 1)):
        s = dy[i] / dx[i]                  # numpy-Skalare: Division durch 0 wie in C
        q = yp[j]
        c = _or(_and(_cmp(s, 0.0, ge), _cmp(s, q, ge)), _and(_cmp(s, 0.0, le), _cmp(s, q, le)))
        if _if(c):
            yp[k] = 2 * s - q
        else:
            yp[k] = s + abs(s) * (s - q) / (abs(s) + abs(s - q))
    if scale:
        yp = yp * sy / sx
    return yp


def parabolaSlopes(x, y):
    """Steigungen der Parabel durch je drei Punkte (stinepack ``parabolaSlopes``).

    Args:
        x: Stützstellen (streng steigend).
        y: Werte an den Stützstellen.

    Returns:
        float-Array der Steigungen an den Stützstellen.
    """
    x = np.array(classify(x)[1], dtype=np.float64)
    y = np.array(classify(y)[1], dtype=np.float64)
    m = x.size
    m1 = m - 1
    dx = np.diff(x)
    dy = np.diff(y)
    dydx = dy / dx
    if m == 2:
        return np.repeat(dydx, 2)
    first = (dydx[0] * (2 * dx[0] + dx[1]) - dydx[1] * dx[0]) / (dx[0] + dx[1])
    mid = (dydx[:-1] * dx[1:] + dydx[1:] * dx[:-1]) / (dx[1:] + dx[:-1])
    last = (dydx[m1 - 1] * (2 * dx[m1 - 1] + dx[m1 - 2]) - dydx[m1 - 2] * dx[m1 - 1]) / (dx[m1 - 1] + dx[m1 - 2])
    return np.concatenate([[first], mid, [last]])


# ── Interpolation ───────────────────────────────────────────────────────────

def _lgl_cmp(v, op):
    """Elementweiser Vergleich mit 0 als dreiwertige Liste (NaN → NA)."""
    return [None if math.isnan(e) else op(e, 0.0) for e in v.tolist()]


def _sub_assign(yo, flags, value_fn):
    """``yo[id] <- wert`` mit logischem Index ``id`` (Liste aus True/False/None)."""
    sel = [i for i, f in enumerate(flags) if f is not False]
    if not sel:
        return
    if any(flags[i] is None for i in sel):
        if len(sel) > 1:
            raise RError("NAs are not allowed in subscripted assignments")
        return                                   # Länge 1: NA-Index wird übergangen
    idx = np.array(sel, dtype=np.int64)
    yo[idx] = value_fn(idx)


def _find_interval(xout, x):
    """``findInterval(xout, x, rightmost.closed = TRUE)`` (1-basiert)."""
    r = np.searchsorted(x, xout, side="right").astype(np.int64)
    m = x.size
    r[xout == x[m - 1]] = m - 1
    return r


def stinterp(x=MISSING, y=MISSING, xout=MISSING, yp=MISSING, method=MISSING):
    """Stineman-Interpolation (stinepack ``stinterp``).

    Args:
        x: Stützstellen (numerischer Vektor, streng steigend, ohne NA).
        y: Werte an den Stützstellen (gleiche Länge wie ``x``).
        xout: Stellen, an denen interpoliert wird (ohne NA).
        yp: optionale Steigungen an den Stützstellen; ohne Angabe nach
            ``method``.
        method: ``"scaledstineman"`` (Standard), ``"stineman"`` oder
            ``"parabola"`` (Teilwörter wie bei ``match.arg``); nicht zusammen
            mit ``yp``.

    Returns:
        ``RList`` mit ``x`` (= ``xout``) und ``y`` (``NA`` außerhalb von
        ``range(x)``).
    """
    if x is MISSING or y is MISSING or xout is MISSING:
        raise RError("Wrong number of input arguments, x, y and xout must be specified")
    kx, xv, vx = classify(x)
    ky, yv, vy = classify(y)
    ko, ov, vo = classify(xout)
    if not (vx and vy and vo) or not (kx == "num" and ky == "num" and ko == "num"):
        raise RError("x, y and xout must be numeric vectors")
    if xv.size < 2:
        raise RError("x must have 2 or more elements")
    if xv.size != yv.size:
        raise RError("x must have the same number of elements as y")
    if np.isnan(xv).any() or np.isnan(ov).any():
        raise RError("NAs in x, y or xout are not allowed")
    if yp is not MISSING:
        kp, pv, vp = classify(yp)
        if not vp or kp != "num":
            raise RError("yp must be a numeric vector")
        if yv.size != pv.size:
            raise RError("When specified, yp must have the same number of elements as y")
        if np.isnan(pv).any():
            raise RError("NAs in yp are not allowed")
        if method is not MISSING:
            raise RError("Method should not be specified if yp is given")
    dx = np.diff(xv)
    dy = np.diff(yv)
    if _if(_any3(_lgl_cmp(dx, lambda a, b: a <= b))):
        raise RError("The values of x must strictly increasing")
    if yp is MISSING:
        meth = _match_method(None if method is MISSING else method)
        if meth == "scaledstineman":
            pv = stinemanSlopes(xv, yv, scale=True)
        elif meth == "stineman":
            pv = stinemanSlopes(xv, yv, scale=False)
        else:
            pv = parabolaSlopes(xv, yv)
    pv = np.asarray(pv, dtype=np.float64)
    m = xv.size
    m1 = m - 1
    s = dy / dx
    k = ov.size
    ix = _find_interval(ov, xv)
    xmin = float(xv.min())
    xmax = float(xv.max())
    epx = 5 * _DBL_EPS * (xmax - xmin)
    ix[(xmin - epx <= ov) & (ov <= xmin)] = 1
    ix[(xmax <= ov) & (ov <= xmax + epx)] = m1
    idx = (1 <= ix) & (ix <= m1)
    i1 = ix[idx] - 1                       # 0-basiert
    i2 = i1 + 1
    xo = ov[idx]
    dxo1 = xo - xv[i1]
    dxo2 = xo - xv[i2]
    y0o = yv[i1] + s[i1] * dxo1
    dyo1 = (pv[i1] - s[i1]) * dxo1
    dyo2 = (pv[i2] - s[i1]) * dxo2
    dyo1dyo2 = dyo1 * dyo2
    yo = y0o.copy()
    # R: `if (m > 2 || !missing(yp))` ist immer wahr, weil yp vorher zugewiesen wurde
    _sub_assign(yo, _lgl_cmp(dyo1dyo2, lambda a, b: a > b),
                lambda j: y0o[j] + dyo1dyo2[j] / (dyo1[j] + dyo2[j]))
    dxi = dx[i1]
    _sub_assign(yo, _lgl_cmp(dyo1dyo2, lambda a, b: a < b),
                lambda j: y0o[j] + dyo1dyo2[j] * (dxo1[j] + dxo2[j]) / (dyo1[j] - dyo2[j]) / dxi[j])
    yout = np.full(k, NA_REAL)
    yout[idx] = yo
    res = RList()
    res["x"] = xout if not isinstance(xout, (list, tuple)) else ov
    res["y"] = yout
    return res


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), ["stinterp", "stinemanSlopes", "parabolaSlopes"])


def _quiet_all(ns, names):
    """Auch Überlauf und Division durch 0 still (R rechnet ohne Meldung mit Inf weiter)."""
    import functools
    for nm in names:
        f = ns[nm]
        ns[nm] = functools.wraps(f)(np.errstate(all="ignore")(f))


_quiet_all(globals(), ["stinterp", "stinemanSlopes", "parabolaSlopes"])
