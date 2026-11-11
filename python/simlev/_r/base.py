# Herkunft:           übersetzt aus R 4.3.3, src/main/summary.c, cum.c, array.c, arithmetic.c;
#                     src/library/stats/src/zeroin.c (R_zeroin2); nachgebildet nach R 4.3.3,
#                     src/library/stats/R/nlm.R (uniroot)
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle); Verfahren R. P. Brent, Algorithms for
#                     Minimization without Derivatives (1973), über Netlib go/fmin.f (ohne Urheber-
#                     und Lizenzvermerk) bzw. c/brent.shar (Kopf nicht geprüft); zeroin.c:
#                     Ergänzungen von Peter Dalgaard
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang: Summen und Kumulationen rechnen die C-Kerne
#                     core/slc_rbase*.
"""Basis-Numerik wie in R (long-double-Akkumulation).

Re-exportiert die Summenhilfen aus :mod:`simlev._r.rnum` (unterste Schicht:
``NA_REAL``, skalare und eindimensionale ``r_``-Hilfen; Rundung und
Textausgabe der Engine in :mod:`simlev._r.rformat`) und ergänzt
Funktionen von R's base mit R-Namen für Vektoren, Matrizen und DataFrames
(``mean``, ``diff``, ``pmin``, ``pmax``, ``range``; seit 1.6.1 ohne
``colSums``/``rowMeans``/``cumprod``/``cummax``/``cummin``, die nur Referenzfälle nutzten) sowie ``quiet_fp``/``env_from_caller`` für die
öffentlichen Funktionen der Module.
"""
from __future__ import annotations

from .rnum import (  # noqa: F401
    r_cumsum,
    r_mean,
    r_mean_int,
    r_pow,
    r_pow_vec,
    r_prod,
    r_rowsums,
    r_sd,
    r_sum,
    r_var,
)
from .rnum import NA_REAL, r_isna_arr  # noqa: F401

import builtins as _bi
import functools as _functools
import inspect as _inspect
import math as _math
import sys as _sys

import numpy as _np
import pandas as _pd



__all__ = ["r_cumsum", "r_mean", "r_mean_int", "r_pow", "r_pow_vec", "r_prod", "r_rowsums", "r_sd", "r_sum", "r_var",
           "mean", "diff", "pmin", "pmax", "range"]


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


def _vec(x):
    if isinstance(x, _pd.Series):
        nm = None if isinstance(x.index, _pd.RangeIndex) else list(x.index)
        return x.to_numpy(dtype=_np.float64, na_value=_np.nan), nm
    return _np.atleast_1d(_np.asarray(x, dtype=_np.float64)).ravel(order="F"), None


def _not_numeric_mean(x):
    """R ``mean.default``: weder Zahl noch Wahrheitswert (Faktor, Text, NULL). Ein ``DataFrame`` steht in Python auch
    für eine R-Matrix und gilt mit Zahlenspalten weiter als Zahl (R ``mean(<data.frame>)`` ist NA)."""
    if x is None or isinstance(x, (_pd.Categorical, str)):
        return True
    if isinstance(x, _pd.DataFrame):
        return not all(d.kind in "iufb" for d in x.dtypes)
    if isinstance(x, _pd.Series):
        return not (x.dtype.kind in "iufb")
    a = _np.asarray(x, dtype=object) if isinstance(x, (list, tuple)) else _np.asarray(x)
    if a.dtype.kind in "iufb":
        return False
    return not all(isinstance(v, (int, float, bool, _np.integer, _np.floating, _np.bool_)) for v in a.ravel())


def mean(x, na_rm=False):
    """``mean(x)`` auch für Matrizen/Arrays/DataFrame-Werte (alle Elemente); Faktor, Text und NULL ergeben seit
    1.6.4 wie R ``NA`` mit Warnung (C-066)."""
    if _not_numeric_mean(x):
        import warnings
        warnings.warn("argument is not numeric or logical: returning NA")
        return NA_REAL
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
    # seit 1.6.4 wie R diff.default (C-066): lag und differences ganze Zahlen >= 1 (bisher negativer Abstand)
    lv = list(lag) if isinstance(lag, (list, tuple, _np.ndarray)) else [lag]
    dv = list(differences) if isinstance(differences, (list, tuple, _np.ndarray)) else [differences]
    if len(lv) != 1 or len(dv) > 1 or not dv or lv[0] is None or dv[0] is None or not lv[0] >= 1 or not dv[0] >= 1:
        from .linalg import RError
        raise RError("'lag' and 'differences' must be integers >= 1")
    lag, differences = int(lv[0]), int(dv[0])
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
    if any(n % v.size for v, _ in vals):   # seit 1.6.4 wie R do_pmin (C-094), eine Warnung je Aufruf
        import warnings
        warnings.warn("an argument will be fractionally recycled", UserWarning, stacklevel=3)
    first, nm = vals[0]
    out = _np.resize(first, n).copy()
    for v, _ in vals[1:]:
        t = _np.resize(v, n)
        # wie do_pmin: (narm && ISNAN(r)) || (!ISNAN(b) && b > r) || (!narm && ISNAN(b)); als Feld (seit 1.6.4, C-071;
        # bis dahin je Element, dieselbe Bedingung, Werte unverändert kopiert)
        with _np.errstate(invalid="ignore"):
            take = (t > out) if greater else (t < out)
            if na_rm:
                take |= _np.isnan(out)
            else:
                take |= _np.isnan(t)
        _np.copyto(out, t, where=take)
    if nm is not None and len(nm) == n:
        return _pd.Series(out, index=nm)
    # seit 1.6.4 wie R mostattributes(): Form (dim, dimnames) des ersten Arguments, wenn die Länge passt (C-094)
    a0 = args[0]
    if isinstance(a0, _pd.DataFrame) and a0.size == n:
        return _pd.DataFrame(out.reshape(a0.shape, order="F"), index=a0.index, columns=a0.columns)
    if isinstance(a0, _np.ndarray) and a0.ndim >= 2 and a0.size == n:
        return out.reshape(a0.shape, order="F")
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
