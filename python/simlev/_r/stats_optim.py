"""Eindimensionale Verfahren ``optimize`` und ``uniroot``, nachgebildet aus R 4.3.3
``stats/R/optimize.R`` und ``stats/src/optimize.c``.

Seit Etappe 9.6c entfallen ``optim``, ``optimhess`` und ``nlminb`` (PORT): SimLev optimiert mit den
eigenen Verfahren der C-Bibliothek slc (:mod:`simlev._lib`, Entwurf B.8).
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd

from .linalg import RError
from .rlist import RList
from .rnum import NA_REAL
from .stats_sort import _DBL_MAX, _NAN, _warn

__all__ = ["optimize", "optimise", "uniroot"]


# ── optimize / uniroot ────────────────────────────────────────────────────

def _g(x):
    return "%g" % x


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
    from ._optim import brent_fmin
    with np.errstate(all="ignore"):
        val = brent_fmin(lower, upper, fcn1, tol)
    res = _OptRes()
    res["maximum" if maximum else "minimum"] = val
    obj = f(val, *args, **kwargs)
    a = _num1(obj, "")
    res["objective"] = float(a[0]) if a.size == 1 else obj
    return res


optimise = optimize


def uniroot(f, interval=None, *args, lower=None, upper=None, f_lower=None, f_upper=None,
            extendInt="no", check_conv=False, tol=0.0001220703125, maxiter=1000, trace=0, **kwargs):
    """``uniroot(f, interval, ..., lower, upper, f.lower, f.upper, extendInt,
    check.conv, tol, maxiter, trace)``; ``RList`` mit ``root``, ``f_root``
    (R-Name ``f.root``), ``iter``, ``init_it`` (``init.it``), ``estim_prec``
    (``estim.prec``)."""
    from ._optim import zeroin2
    if interval is not None and len(interval) != 2:
        raise RError("'interval' must be a vector of length 2")
    if lower is None:
        lower = min(interval)
    if upper is None:
        upper = max(interval)
    lower = float(lower)
    upper = float(upper)
    if not lower < upper:
        raise RError("lower < upper  is not fulfilled")

    def ff(x):
        v = _num1(f(x, *args, **kwargs), "")
        return float(v[0]) if v.size >= 1 else _NAN
    if f_lower is None:
        f_lower = ff(lower)
    if f_lower != f_lower:
        raise RError("f.lower = f(lower) is NA")
    if f_upper is None:
        f_upper = ff(upper)
    if f_upper != f_upper:
        raise RError("f.upper = f(upper) is NA")
    f_lower = float(f_lower)
    f_upper = float(f_upper)
    sigs = {"yes": None, "downX": -1.0, "no": 0.0, "upX": 1.0}
    ext = [k for k in sigs if k.startswith(extendInt)] if extendInt else []
    if len(ext) != 1:
        raise RError("'arg' should be one of “no”, “yes”, “downX”, “upX”")
    Sig = sigs[ext[0]]

    def trunc(x):
        return max(min(x, _DBL_MAX), -_DBL_MAX) if x == x else x
    flo = trunc(f_lower)
    fup = trunc(f_upper)
    with np.errstate(all="ignore"):
        doX = (Sig is None and flo * fup > 0) or (Sig is not None and (Sig * flo > 0 or Sig * fup < 0))
    it = 0
    if doX:
        if trace:
            print("search in [%s,%s]%s" % (_g(lower), _g(upper), "\n" if trace >= 2 else " ... "), end="")

        def Delta(u):
            return 0.01 * max(1e-4, abs(u))
        if Sig is None:
            delta = [Delta(lower), Delta(upper)]
            while (f_lower * f_upper > 0) and (math.isfinite(lower) or math.isfinite(upper)):
                iF = [math.isfinite(lower), math.isfinite(upper)]
                it += 1
                if it > maxiter:
                    raise RError("no sign change found in %d iterations" % (it - 1))
                if iF[0]:
                    ol, of = lower, f_lower
                    lower = lower - delta[0]
                    f_lower = ff(lower)
                    if f_lower != f_lower:
                        lower, f_lower = ol, of
                        delta[0] = delta[0] / 4
                if iF[1]:
                    ol, of = upper, f_upper
                    upper = upper + delta[1]
                    f_upper = ff(upper)
                    if f_upper != f_upper:
                        upper, f_upper = ol, of
                        delta[1] = delta[1] / 4
                if trace >= 2:
                    print(" .. modified lower,upper: (%15s,%15s)" % (_g(lower), _g(upper)))
                delta = [2 * delta[0], 2 * delta[1]]
        else:
            delta = Delta(lower)
            while Sig * f_lower > 0:
                it += 1
                if it > maxiter:
                    raise RError("no sign change found in %d iterations" % (it - 1))
                lower = lower - delta
                f_lower = ff(lower)
                if trace >= 2:
                    print(" .. modified lower: %s" % _g(lower))
                delta = 2 * delta
            delta = Delta(upper)
            while Sig * f_upper < 0:
                it += 1
                if it > maxiter:
                    raise RError("no sign change found in %d iterations" % (it - 1))
                upper = upper + delta
                f_upper = ff(upper)
                if trace >= 2:
                    print(" .. modified upper: %s" % _g(upper))
                delta = 2 * delta
        if trace and trace < 2:
            print("extended to [%s, %s] in %d steps" % (_g(lower), _g(upper), it))
    sg = lambda v: (0.0 if v == 0 else math.copysign(1.0, v)) if v == v else _NAN  # noqa: E731
    prod = sg(f_lower) * sg(f_upper)
    if not (prod == prod and prod <= 0):
        raise RError("did not succeed extending the interval endpoints for f(lower) * f(upper) <= 0"
                     if doX else "f() values at end points not of opposite sign")
    if doX and it:
        flo = trunc(f_lower)
        fup = trunc(f_upper)
    if not math.isfinite(lower):
        raise RError("invalid 'xmin' value")
    if not math.isfinite(upper):
        raise RError("invalid 'xmax' value")
    if lower >= upper:
        raise RError("'xmin' not less than 'xmax'")
    tol = float(tol)
    if not math.isfinite(tol) or tol <= 0.0:
        raise RError("invalid 'tol' value")
    maxit = int(maxiter)
    if maxit <= 0:
        raise RError("'maxiter' must be positive")
    warned = []

    def fcn2(x):
        v = _num1(f(x, *args, **kwargs), "")
        if v.size != 1:
            raise RError("invalid function value in 'zeroin'")
        val = float(v[0])
        if not math.isfinite(val):
            if val == -math.inf:
                msg = "-Inf replaced by maximally negative value"
                if check_conv:
                    warned.append(msg)
                else:
                    _warn(msg)
                return -_DBL_MAX
            msg = "NA/Inf replaced by maximum positive value"
            if check_conv:
                warned.append(msg)
            else:
                _warn(msg)
            return _DBL_MAX
        return val
    with np.errstate(all="ignore"):
        root, itr, prec = zeroin2(lower, upper, flo, fup, fcn2, tol, maxit)
    if check_conv and warned:
        raise RError("convergence problem in zero finding: " + warned[0])
    itr = int(itr)
    if itr < 0:
        msg = ("_NOT_ converged in %d iteration" if maxiter == 1 else "_NOT_ converged in %d iterations") % maxiter
        if check_conv:
            raise RError(msg)
        _warn(msg)
        itr = int(maxiter)
    if doX:
        itr = itr + it
        init_it = it
    else:
        init_it = NA_REAL               # NA_integer_
    res = _OptRes()
    res["root"] = root
    res["f.root"] = ff(root)
    res["iter"] = itr
    res["init.it"] = init_it
    res["estim.prec"] = prec
    return res


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
