# Herkunft:           nachgebildet nach R 4.3.3, src/library/stats/R/optimize.R und src/library/stats/src/optimize.c
#                     (do_fmin, fcn1); Brent_fmin seit 1.6.0 im Kern (core/slc_opt_fmin.cpp, bis 1.5.2 _optim.py)
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle); Verfahren R. P. Brent, Algorithms for
#                     Minimization without Derivatives (1973), über Netlib go/fmin.f (ohne Urheber-
#                     und Lizenzvermerk)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang.
"""Eindimensionales Verfahren ``optimize``, nachgebildet aus R 4.3.3
``stats/R/optimize.R`` und ``stats/src/optimize.c``; das Verfahren (Brent fmin) rechnet seit 1.6.0 der Kern
(``core/slc_opt_fmin.cpp``, Frage/Antwort über ``simlev._ext.slc_fmin_*``).

Seit 1.0.0 entfallen ``optim``, ``optimhess`` und ``nlminb`` (PORT): SimLev optimiert mit den
eigenen Verfahren der C-Bibliothek slc (:mod:`simlev._lib`). Seit 1.5.2 entfällt ``uniroot`` (ohne
Aufrufer, seit 1.4.0 rechnet XIRR im Kern mit ``sl_r_zeroin2``).
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd

from .. import _ext
from .linalg import RError
from .rlist import RList
from .stats_sort import _DBL_MAX, _warn

__all__ = ["optimize"]


# ── optimize ────────────────────────────────────────────────────

class _OptRes(RList):
    pass


def _num1(v, what):
    """Rückgabe einer Zielfunktion als double (``coerceVector``)."""
    if isinstance(v, (pd.Series, pd.DataFrame)):
        v = v.to_numpy()
    a = np.asarray(v, dtype=np.float64).ravel()
    return a


def optimize(f, interval=None, *args, lower=None, upper=None, maximum=False,
             tol=0.0001220703125, **kwargs):
    """``optimize(f, interval, ..., lower, upper, maximum, tol)`` (Brent ``fmin``).

    Ergebnis: ``RList`` mit ``minimum`` (bzw. ``maximum``) und ``objective``.
    """
    if lower is None:
        lower = min(interval)
    if upper is None:
        upper = max(interval)
    lower = float(lower)
    upper = float(upper)
    sgn = -1.0 if maximum else 1.0

    def fcn1(x):
        s = f(x, *args, **kwargs)
        a = _num1(s, "optimize")
        if a.size != 1:
            raise RError("invalid function value in 'optimize'")
        v = float(sgn * a[0]) if maximum else float(a[0])
        if not math.isfinite(v):
            _warn("NA/Inf replaced by maximum positive value")
            return _DBL_MAX
        return v
    if not math.isfinite(lower):
        raise RError("invalid 'xmin' value")
    if not math.isfinite(upper):
        raise RError("invalid 'xmax' value")
    if lower >= upper:
        raise RError("'xmin' not less than 'xmax'")
    tol = float(tol)
    if not math.isfinite(tol) or tol <= 0.0:
        raise RError("invalid 'tol' value")
    # Brent fmin seit 1.6.0 im Kern (core/slc_opt_fmin.cpp, Frage/Antwort; bis 1.5.2 _r/_optim.py)
    ws = np.empty(24)                          # SL_FMIN_WS
    _ext.slc_fmin_init(ws, lower, upper, tol)
    with np.errstate(all="ignore"):
        need, val = _ext.slc_fmin_ask(ws)
        while need:
            _ext.slc_fmin_tell(ws, fcn1(val))
            need, val = _ext.slc_fmin_ask(ws)
    res = _OptRes()
    res["maximum" if maximum else "minimum"] = val
    obj = f(val, *args, **kwargs)
    a = _num1(obj, "")
    res["objective"] = float(a[0]) if a.size == 1 else obj
    return res




from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
