"""Basis-Numerik wie in R (long-double-Akkumulation).

Re-exportiert die Summenhilfen aus :mod:`simlev._r.rnum` (unterste Schicht:
``NA_REAL``, skalare und eindimensionale ``r_``-Hilfen; Rundung und
Textausgabe der Engine in :mod:`simlev._r.rformat`) und ergänzt
Funktionen von R's base mit R-Namen für Vektoren, Matrizen und DataFrames
(``colSums``, ``rowMeans``, ``cumprod``, ``cummax``, ``diff``, ``pmin``,
``range`` …), ``sys_time`` sowie ``quiet_fp``/``env_from_caller`` für die
öffentlichen Funktionen der Module.
"""
from __future__ import annotations

from .rnum import (  # noqa: F401
    r_cumsum,
    r_mean,
    r_mean_int,
    r_mod1,
    r_pow,
    r_pow_vec,
    r_prod,
    r_rowsums,
    r_sd,
    r_sum,
    r_var,
)
from .rnum import NA_REAL, _handle_nan, _x87_nan, r_isna_arr  # noqa: F401

import builtins as _bi
import functools as _functools
import inspect as _inspect
import math as _math
import os as _os
import sys as _sys
import time as _time

import numpy as _np
import pandas as _pd

_LD = _np.longdouble

__all__ = ["r_cumsum", "r_mean", "r_mean_int", "r_mod1", "r_pow", "r_pow_vec", "r_prod",
           "r_rowsums", "r_sd", "r_sum", "r_var", "colSums", "colMeans", "rowSums", "rowMeans",
           "cumprod", "cummax", "cummin", "mean", "diff", "pmin", "pmax", "range", "sys_time"]


def _mat(x):
    """→ (Werte n×p, rownames, colnames)."""
    if isinstance(x, _pd.DataFrame):
        rn = None if isinstance(x.index, _pd.RangeIndex) else [str(i) for i in x.index]
        cn = None if isinstance(x.columns, _pd.RangeIndex) else [str(c) for c in x.columns]
        return _np.asarray(x.to_numpy(dtype=_np.float64, na_value=_np.nan), dtype=_np.float64), rn, cn
    a = _np.asarray(x, dtype=_np.float64)
    if a.ndim != 2:
        from .linalg import RError
        raise RError("'x' must be an array of at least two dimensions")
    return a, None, None


def _named(v, names):
    if names is None:
        return v
    return _pd.Series(v, index=names)


def _col_sums(a, na_rm, mean):
    n, p = a.shape
    out = _np.empty(p)
    for j in _bi.range(p):
        c = a[:, j]
        if na_rm:
            c = c[~_np.isnan(c)]
            cnt = c.size
        else:
            cnt = n
        with _np.errstate(invalid="ignore"):
            s = _np.cumsum(c.astype(_LD))[-1] if c.size else _LD(0)
        if s != s:
            out[j] = _x87_nan(c)            # NA/NaN nach der x87-Regel wie R
            continue
        if mean:
            with _np.errstate(all="ignore"):
                s = s / _LD(cnt)
        out[j] = float(s)
    return out


def colSums(x, na_rm=False):
    """``colSums(x, na.rm)`` (long double je Spalte)."""
    a, rn, cn = _mat(x)
    return _named(_col_sums(a, na_rm, False), cn)


def colMeans(x, na_rm=False):
    """``colMeans(x, na.rm)`` (long-double-Summe / Anzahl)."""
    a, rn, cn = _mat(x)
    return _named(_col_sums(a, na_rm, True), cn)


def _row_sums(a, na_rm, mean):
    n, p = a.shape
    acc = _np.zeros(n, dtype=_LD)
    cnt = _np.zeros(n, dtype=_np.int64)
    for j in _bi.range(p):
        c = a[:, j]
        if na_rm:
            ok = ~_np.isnan(c)
            acc[ok] += c[ok].astype(_LD)
            cnt += ok
        else:
            with _np.errstate(invalid="ignore"):
                acc += c.astype(_LD)
    if mean:
        with _np.errstate(all="ignore"):
            acc = acc / (cnt.astype(_LD) if na_rm else _LD(p))
    out = acc.astype(_np.float64)
    if not na_rm:
        for i in _np.flatnonzero(_np.isnan(out)):
            r = _x87_nan(a[i, :])           # NA/NaN nach der x87-Regel wie R
            if r is not None:
                out[i] = r
    return out


def rowSums(x, na_rm=False):
    """``rowSums(x, na.rm)`` (spaltenweise in long double akkumuliert)."""
    a, rn, cn = _mat(x)
    return _named(_row_sums(a, na_rm, False), rn)


def rowMeans(x, na_rm=False):
    """``rowMeans(x, na.rm)``."""
    a, rn, cn = _mat(x)
    return _named(_row_sums(a, na_rm, True), rn)


def _vec(x):
    if isinstance(x, _pd.Series):
        nm = None if isinstance(x.index, _pd.RangeIndex) else list(x.index)
        return x.to_numpy(dtype=_np.float64, na_value=_np.nan), nm
    return _np.atleast_1d(_np.asarray(x, dtype=_np.float64)).ravel(order="F"), None


def cumprod(x):
    """``cumprod(x)`` (``LDOUBLE``-Produkt, NA/NaN ab dem ersten Auftreten)."""
    v, nm = _vec(x)
    if v.size == 0:
        return v
    with _np.errstate(invalid="ignore"):
        out = _np.cumprod(v.astype(_LD)).astype(_np.float64)
    if out[-1] != out[-1]:
        _handle_nan(v, out)
    return _named(out, nm)


def _cumext(x, fn):
    v, nm = _vec(x)
    out = _np.empty(v.size)
    m = None
    for i, t in enumerate(v.tolist()):
        if t != t:
            _handle_nan(v, out)
            break
        m = t if m is None else fn(m, t)
        out[i] = m
    return _named(out, nm)


def cummax(x):
    """``cummax(x)`` (double, ``(max > x) ? max : x``)."""
    return _cumext(x, lambda m, t: m if m > t else t)


def cummin(x):
    """``cummin(x)``."""
    return _cumext(x, lambda m, t: m if m < t else t)


def mean(x, na_rm=False):
    """``mean(x)`` auch für Matrizen/Arrays/DataFrame-Werte (alle Elemente)."""
    if isinstance(x, _pd.DataFrame):
        a = x.to_numpy(dtype=_np.float64).ravel(order="F")
    else:
        a = _np.asarray(x)
        if a.dtype.kind in "iub":
            from .rnum import r_mean_int
            return r_mean_int(a.ravel(order="F"))
        a = a.astype(_np.float64).ravel(order="F")
    return r_mean(a, na_rm=na_rm)


def diff(x, lag=1, differences=1):
    """``diff(x, lag, differences)`` für Vektoren und Matrizen (zeilenweise)."""
    if isinstance(x, _pd.DataFrame) or (isinstance(x, _np.ndarray) and x.ndim == 2):
        a, rn, cn = _mat(x)
        for _ in _bi.range(differences):
            if a.shape[0] <= lag:
                return a[:0]
            a = a[lag:] - a[:-lag]
        if rn is not None or cn is not None:
            return _pd.DataFrame(a, index=rn[lag * differences:] if rn else None, columns=cn)
        return a
    v, nm = _vec(x)
    for _ in _bi.range(differences):
        if v.size <= lag:
            return v[:0]
        v = v[lag:] - v[:-lag]
        if nm is not None:
            nm = nm[lag:]
    return _named(v, nm)


def _pext(args, na_rm, greater):
    vals = [_vec(a) for a in args]
    if not vals:
        from .linalg import RError
        raise RError("no arguments")
    n = max(v.size for v, _ in vals)
    if any(v.size == 0 for v, _ in vals):
        return _np.zeros(0)
    first, nm = vals[0]
    out = _np.resize(first, n).copy()
    for v, _ in vals[1:]:
        t = _np.resize(v, n)
        for i in _bi.range(n):
            a = out[i]
            b = t[i]
            # wie do_pmin: (narm && ISNAN(r)) || (!ISNAN(b) && b > r) || (!narm && ISNAN(b))
            if (na_rm and a != a) or (b > a if greater else b < a) or (not na_rm and b != b):
                out[i] = b
    if nm is not None and len(nm) == n:
        return _pd.Series(out, index=nm)
    return out


def pmax(*args, na_rm=False):
    """``pmax(..., na.rm)`` mit Recycling; Namen vom ersten Argument."""
    return _pext(args, na_rm, True)


def pmin(*args, na_rm=False):
    """``pmin(..., na.rm)``."""
    return _pext(args, na_rm, False)


def range(*args, na_rm=False, finite=False):  # noqa: A001 - Name wie in R
    """``range(..., na.rm, finite)`` = ``c(min, max)``."""
    import warnings
    v = _np.concatenate([_vec(a)[0] for a in args]) if args else _np.zeros(0)
    if finite:
        v = v[_np.isfinite(v)]
    elif na_rm:
        v = v[~_np.isnan(v)]
    elif _np.isnan(v).any():
        x = NA_REAL if r_isna_arr(v).any() else _np.nan    # NA schlägt NaN (rmin/rmax)
        return _np.array([x, x])
    if v.size == 0:
        warnings.warn("no non-missing arguments to min; returning Inf")
        warnings.warn("no non-missing arguments to max; returning -Inf")
        return _np.array([_math.inf, -_math.inf])
    return _np.array([float(v.min()), float(v.max())])


def sys_time():
    """``as.numeric(Sys.time())``: Sekunden seit 1970-01-01 UTC (Double, mit Nachkommastellen).

    Zentrale Uhr der R-Nachbildungen (z. B. ``Rsolnp::gosolnp`` mit
    ``rseed = NULL``). Ist die Umgebungsvariable ``SIMLEV_R_SYS_TIME``
    gesetzt (eine Zahl, Sekunden seit 1970), liefert die Funktion diesen
    Wert statt der Uhrzeit (Prüfschalter für Tests und Referenzfälle).
    """
    v = _os.environ.get("SIMLEV_R_SYS_TIME")
    if v is not None and v.strip() != "":
        return float(v)
    return _time.time()


def caller_env(frame):
    """Namensraum eines Frames wie ``parent.frame()``: globale Namen, überlagert von den lokalen."""
    env = dict(frame.f_globals)
    env.update(frame.f_locals)
    return env


def env_from_caller(f):
    """Markiert eine Funktion, deren Argument ``env`` wie in R ``parent.frame()`` voreingestellt ist.

    :func:`quiet_fp` hüllt so markierte Funktionen so, dass ``env=None``
    (bzw. ein fehlendes ``env``) durch den Namensraum des Aufrufers
    (:func:`caller_env`) ersetzt wird, bevor die Funktion läuft. Die Funktion
    selbst liest keinen Frame; ein ausdrücklich übergebenes ``env`` bleibt
    unverändert.
    """
    f._simlev_env_from_caller = True
    return f


def _quiet(f):
    g = _np.errstate(invalid="ignore")(f)
    if getattr(f, "_simlev_env_from_caller", False):
        sig = _inspect.signature(f)
        par = sig.parameters["env"]
        pos = (list(sig.parameters).index("env")
               if par.kind is _inspect.Parameter.POSITIONAL_OR_KEYWORD else None)
        inner = g

        @_functools.wraps(f)
        def g(*args, **kwargs):
            if pos is not None and len(args) > pos:
                if args[pos] is None:
                    fr = _sys._getframe(1)
                    try:
                        args = args[:pos] + (caller_env(fr),) + args[pos + 1:]
                    finally:
                        del fr
            elif kwargs.get("env") is None:
                fr = _sys._getframe(1)
                try:
                    kwargs["env"] = caller_env(fr)
                finally:
                    del fr
            return inner(*args, **kwargs)
    g._simlev_quiet_fp = True
    return g


def quiet_fp(ns, names):
    """Öffentliche Funktionen ``names`` im Namensraum ``ns`` in ``np.errstate(invalid="ignore")`` hüllen.

    R's ``NA_real_`` ist ein signalisierendes NaN; numpy meldet für jede
    Rechnung damit "invalid value encountered". R kennt diese Warnung nicht,
    darum werden Gleitkomma-Ausnahmen der Klasse *invalid* in den
    öffentlichen Funktionen unterdrückt (wie in R).

    Funktionen mit :func:`env_from_caller` (Bedingungen in R-Syntax mit
    ``env = parent.frame()``) bekommen zusätzlich den Namensraum ihres
    Aufrufers als ``env``, wenn keiner übergeben wird.
    """
    for nm in names:
        f = ns.get(nm)
        if isinstance(f, type):           # Klassen: öffentliche Methoden
            for mn, m in list(vars(f).items()):
                if (not mn.startswith("_") and _inspect.isfunction(m)
                        and not getattr(m, "_simlev_quiet_fp", False)):
                    setattr(f, mn, _quiet(m))
            continue
        if callable(f) and not getattr(f, "_simlev_quiet_fp", False):
            ns[nm] = _quiet(f)


quiet_fp(globals(), __all__)
