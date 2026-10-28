"""Optimierer ``optimize``, ``uniroot``, ``optim``, ``optimhess`` und die ``nlminb``-Anbindung an die
PORT-Bibliothek, nachgebildet aus R 4.3.3 ``stats/R/optimize.R``, ``optim.R``, ``nlminb.R`` und
``stats/src/optimize.c``, ``optim.c``, ``port.c``.
"""
from __future__ import annotations

import math
from collections.abc import Mapping

import numpy as np
import pandas as pd

from .linalg import RError, _out
from .rlist import RList
from .rnum import NA_REAL
from .stats_sort import _DBL_EPS, _DBL_MAX, _NAN, _warn

__all__ = [
    "optimize", "optimise", "uniroot", "optim", "optimhess", "nlminb",
]


# ── optimize / uniroot / optim ───────────────────────────────────────────

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


def _g(x):
    return "%g" % x


_OPTIM_METHODS = ("Nelder-Mead", "BFGS", "CG", "L-BFGS-B", "SANN", "Brent")


class _Fn:
    """fminfn/fmingr aus optim.c."""

    def __init__(self, fn, gr, fnscale, parscale, ndeps, names, lower=None, upper=None, usebounds=False):
        self.fn = fn
        self.gr = gr
        self.fnscale = fnscale
        self.parscale = parscale
        self.ndeps = ndeps
        self.names = names
        self.lower = lower
        self.upper = upper
        self.usebounds = usebounds

    def _wrap(self, x):
        a = np.array(x, dtype=np.float64)
        if self.names is not None:
            return pd.Series(a, index=self.names)
        return a

    def _call(self, x):
        s = _num1(self.fn(self._wrap(x)), "")
        if s.size != 1:
            raise RError("objective function in optim evaluates to length %d not 1" % s.size)
        return float(s[0])

    def fminfn(self, p):
        x = []
        for i, pi in enumerate(p):
            if not math.isfinite(pi):
                raise RError("non-finite value supplied by optim")
            x.append(pi * self.parscale[i])
        return self._call(x) / self.fnscale

    def fmingr(self, p):
        n = len(p)
        ps = self.parscale
        if self.gr is not None:
            x = []
            for i in range(n):
                if not math.isfinite(p[i]):
                    raise RError("non-finite value supplied by optim")
                x.append(p[i] * ps[i])
            s = _num1(self.gr(self._wrap(x)), "")
            if s.size != n:
                raise RError("gradient in optim evaluated to length %d not %d" % (s.size, n))
            return [float(s[i]) * ps[i] / self.fnscale for i in range(n)]
        df = [0.0] * n
        x = [p[i] * ps[i] for i in range(n)]
        if not self.usebounds:
            for i in range(n):
                eps = self.ndeps[i]
                x[i] = (p[i] + eps) * ps[i]
                val1 = self._call(x) / self.fnscale
                x[i] = (p[i] - eps) * ps[i]
                val2 = self._call(x) / self.fnscale
                with np.errstate(all="ignore"):
                    df[i] = float(np.float64(val1 - val2) / np.float64(2 * eps))
                if not math.isfinite(df[i]):
                    raise RError("non-finite finite-difference value [%d]" % (i + 1))
                x[i] = p[i] * ps[i]
        else:
            for i in range(n):
                epsused = eps = self.ndeps[i]
                tmp = p[i] + eps
                if tmp > self.upper[i]:
                    tmp = self.upper[i]
                    epsused = tmp - p[i]
                x[i] = tmp * ps[i]
                val1 = self._call(x) / self.fnscale
                tmp = p[i] - eps
                if tmp < self.lower[i]:
                    tmp = self.lower[i]
                    eps = p[i] - tmp
                x[i] = tmp * ps[i]
                val2 = self._call(x) / self.fnscale
                with np.errstate(all="ignore"):
                    df[i] = float(np.float64(val1 - val2) / np.float64(epsused + eps))
                if not math.isfinite(df[i]):
                    raise RError("non-finite finite-difference value [%d]" % (i + 1))
                x[i] = p[i] * ps[i]
        return df


def optim(par, fn, gr=None, *args, method="Nelder-Mead", lower=-math.inf, upper=math.inf,
          control=None, hessian=False, **kwargs):
    """``optim(par, fn, gr, ..., method, lower, upper, control, hessian)``.

    Methoden: ``"Nelder-Mead"``, ``"BFGS"``, ``"CG"``, ``"L-BFGS-B"``,
    ``"Brent"``. ``control`` wie in R (``maxit``, ``reltol``, ``abstol``,
    ``fnscale``, ``parscale``, ``ndeps``, ``factr``, ``pgtol``, ``lmm``,
    ``alpha``, ``beta``, ``gamma``, ``type``, ``trace``, ``REPORT``,
    ``warn.1d.NelderMead``). Ergebnis: ``RList`` mit ``par``, ``value``,
    ``counts`` (Series ``function``/``gradient``), ``convergence``,
    ``message`` (und ``hessian``).
    """
    names = None
    if isinstance(par, pd.Series):
        names = None if isinstance(par.index, pd.RangeIndex) else [str(i) for i in par.index]
        pv = par.to_numpy(dtype=np.float64)
    else:
        pv = np.atleast_1d(np.asarray(par, dtype=np.float64)).ravel()
    fn1 = (lambda p: fn(p, *args, **kwargs))
    gr1 = (lambda p: gr(p, *args, **kwargs)) if gr is not None else None
    meths = [m for m in _OPTIM_METHODS if m.startswith(method)]
    if len(meths) != 1:
        raise RError("'arg' should be one of “Nelder-Mead”, “BFGS”, “CG”, "
                     "“L-BFGS-B”, “SANN”, “Brent”")
    method = meths[0]
    lo = np.atleast_1d(np.asarray(lower, dtype=np.float64)).ravel()
    up = np.atleast_1d(np.asarray(upper, dtype=np.float64)).ravel()
    if ((lo > -math.inf).any() or (up < math.inf).any()) and method not in ("L-BFGS-B", "Brent"):
        _warn("bounds can only be used with method L-BFGS-B (or Brent)")
        method = "L-BFGS-B"
    npar = pv.size
    con = {"trace": 0, "fnscale": 1.0, "parscale": np.ones(npar), "ndeps": np.full(npar, 1e-3),
           "maxit": 100, "abstol": -math.inf, "reltol": math.sqrt(_DBL_EPS), "alpha": 1.0,
           "beta": 0.5, "gamma": 2.0, "REPORT": 10, "warn.1d.NelderMead": True, "type": 1,
           "lmm": 5, "factr": 1e7, "pgtol": 0.0, "tmax": 10, "temp": 10.0}
    nms = list(con.keys())
    if method == "Nelder-Mead":
        con["maxit"] = 500
    if method == "SANN":
        con["maxit"] = 10000
        con["REPORT"] = 100
    control = dict(control or {})
    ctl = {}
    for k, v in control.items():
        kk = k.replace("warn_1d_NelderMead", "warn.1d.NelderMead")
        ctl[kk] = v
    con.update(ctl)
    no = [k for k in ctl if k not in nms]
    if no:
        _warn("unknown names in control: " + ", ".join(no))
    if con["trace"] < 0:
        _warn("read the documentation for 'trace' more carefully")
    elif method == "SANN" and con["trace"] and int(con["REPORT"]) == 0:
        raise RError("'trace != 0' needs 'REPORT >= 1'")
    if method == "L-BFGS-B" and any(k in ctl for k in ("reltol", "abstol")):
        _warn("method L-BFGS-B uses 'factr' (and 'pgtol') instead of 'reltol' and 'abstol'")
    if npar == 1 and method == "Nelder-Mead" and con["warn.1d.NelderMead"] is True:
        _warn('one-dimensional optimization by Nelder-Mead is unreliable:\nuse "Brent" or optimize() directly')
    if npar > 1 and method == "Brent":
        raise RError('method = "Brent" is only available for one-dimensional optimization')
    lo = np.resize(lo, npar) if npar else lo[:0]
    up = np.resize(up, npar) if npar else up[:0]
    res = _OptRes()
    if method == "Brent":
        if not (np.isfinite(lo).all() and np.isfinite(up).all()):
            raise RError("'lower' and 'upper' must be finite values")
        fs = float(con["fnscale"])
        o = optimize(lambda p: _num1(fn(p, *args, **kwargs), "")[0] / fs, lower=float(lo[0]),
                     upper=float(up[0]), tol=float(con["reltol"]))
        res["par"] = o["minimum"]
        res["value"] = o["objective"] * fs
        res["counts"] = pd.Series([NA_REAL, NA_REAL], index=["function", "gradient"])
        res["convergence"] = 0
        res["message"] = None
    else:
        res = _optim_c(pv, names, fn1, gr1, method, con, lo, up)
    if hessian:
        res["hessian"] = optimhess(res["par"], fn, gr, *args, control=con, **kwargs)
    return res


def _asint(v):
    if v is None:
        raise RError("'maxit' is not an integer")
    return int(float(v))


def _optim_c(pv, names, fn1, gr1, method, con, lo, up):
    from ._optim import nmmin, vmmin, cgmin
    from ._lbfgsb import lbfgsb
    npar = pv.size
    trace = int(con["trace"])
    fnscale = float(con["fnscale"])
    ps = np.atleast_1d(np.asarray(con["parscale"], dtype=np.float64)).ravel()
    if ps.size != npar:
        raise RError("'parscale' is of the wrong length")
    ps = ps.tolist()
    dpar = [float(pv[i]) / ps[i] for i in range(npar)]
    abstol = float(con["abstol"])
    reltol = float(con["reltol"])
    maxit = _asint(con["maxit"])

    def get_ndeps():
        nd = np.atleast_1d(np.asarray(con["ndeps"], dtype=np.float64)).ravel()
        if nd.size != npar:
            raise RError("'ndeps' is of the wrong length")
        return nd.tolist()
    res = _OptRes()
    msg = None
    with np.errstate(all="ignore"):
        if method == "Nelder-Mead":
            F = _Fn(fn1, None, fnscale, ps, None, names)
            X, val, fail, fncount = nmmin(npar, dpar, F.fminfn, abstol, reltol, float(con["alpha"]),
                                          float(con["beta"]), float(con["gamma"]), trace, maxit)
            par = [X[i] * ps[i] for i in range(npar)]
            grcount = None
        elif method == "SANN":
            raise NotImplementedError('optim(method = "SANN") ist nicht portiert')
        elif method == "BFGS":
            nrep = int(con["REPORT"])
            nd = None if gr1 is not None else get_ndeps()
            F = _Fn(fn1, gr1, fnscale, ps, nd, names)
            b, val, fncount, grcount, fail = vmmin(npar, dpar, F.fminfn, F.fmingr, maxit, trace,
                                                   [1] * npar, abstol, reltol, nrep)
            par = [b[i] * ps[i] for i in range(npar)]
        elif method == "CG":
            typ = int(con["type"])
            nd = None if gr1 is not None else get_ndeps()
            F = _Fn(fn1, gr1, fnscale, ps, nd, names)
            X, val, fail, fncount, grcount = cgmin(npar, dpar, F.fminfn, F.fmingr, abstol, reltol,
                                                   typ, trace, maxit)
            par = [X[i] * ps[i] for i in range(npar)]
        else:  # L-BFGS-B
            nrep = int(con["REPORT"])
            factr = float(con["factr"])
            pgtol = float(con["pgtol"])
            lmm = int(con["lmm"])
            nd = None if gr1 is not None else get_ndeps()
            lower = [float(lo[i]) / ps[i] for i in range(npar)]
            upper = [float(up[i]) / ps[i] for i in range(npar)]
            nbd = []
            for i in range(npar):
                if not math.isfinite(lower[i]):
                    nbd.append(0 if not math.isfinite(upper[i]) else 3)
                else:
                    nbd.append(1 if not math.isfinite(upper[i]) else 2)
            F = _Fn(fn1, gr1, fnscale, ps, nd, names, lower, upper, usebounds=True)
            x, val, fail, fncount, grcount, msg = lbfgsb(npar, lmm, dpar, lower, upper, nbd, F.fminfn,
                                                         F.fmingr, factr, pgtol, maxit, trace, nrep)
            par = [x[i] * ps[i] for i in range(npar)]
    p = np.array(par, dtype=np.float64)
    res["par"] = pd.Series(p, index=names) if names is not None else (p if p.size != 1 else p)
    res["value"] = val * fnscale
    res["counts"] = pd.Series([float(fncount), NA_REAL if grcount is None else float(grcount)],
                              index=["function", "gradient"])
    res["convergence"] = int(fail)
    res["message"] = msg
    return res


def optimhess(par, fn, gr=None, *args, control=None, **kwargs):
    """``optimHess(par, fn, gr, ..., control)`` (Hesse-Matrix wie in optim)."""
    names = None
    if isinstance(par, pd.Series):
        names = None if isinstance(par.index, pd.RangeIndex) else [str(i) for i in par.index]
        pv = par.to_numpy(dtype=np.float64)
    else:
        pv = np.atleast_1d(np.asarray(par, dtype=np.float64)).ravel()
    npar = pv.size
    con = {"fnscale": 1.0, "parscale": np.ones(npar), "ndeps": np.full(npar, 1e-3)}
    if control:
        con.update({k: v for k, v in control.items() if k in con})
    fnscale = float(con["fnscale"])
    ps = np.atleast_1d(np.asarray(con["parscale"], dtype=np.float64)).ravel()
    if ps.size != npar:
        raise RError("'parscale' is of the wrong length")
    ps = ps.tolist()
    nd = np.atleast_1d(np.asarray(con["ndeps"], dtype=np.float64)).ravel()
    if nd.size != npar:
        raise RError("'ndeps' is of the wrong length")
    nd = nd.tolist()
    fn1 = (lambda p: fn(p, *args, **kwargs))
    gr1 = (lambda p: gr(p, *args, **kwargs)) if gr is not None else None
    F = _Fn(fn1, gr1, fnscale, ps, nd, names)
    dpar = [float(pv[i]) / ps[i] for i in range(npar)]
    ans = np.zeros((npar, npar))
    with np.errstate(all="ignore"):
        for i in range(npar):
            eps = nd[i] / ps[i]
            dpar[i] = dpar[i] + eps
            df1 = F.fmingr(dpar)
            dpar[i] = dpar[i] - 2 * eps
            df2 = F.fmingr(dpar)
            for j in range(npar):
                ans[j, i] = float(np.float64(fnscale * (df1[j] - df2[j])) /
                                  np.float64(2 * eps * ps[i] * ps[j]))
            dpar[i] = dpar[i] + eps
        for i in range(npar):
            for j in range(i):
                tmp = 0.5 * (ans[j, i] + ans[i, j])
                ans[j, i] = ans[i, j] = tmp
    return _out(ans, names, names)


# ── nlminb (PORT) ─────────────────────────────────────────────────────────

_PORT_CPOS = (("eval.max", 17), ("iter.max", 18), ("trace", 19), ("maxiter", 18),
              ("abs.tol", 31), ("rel.tol", 32), ("x.tol", 33), ("xf.tol", 34),
              ("step.min", 35), ("step.max", 36), ("sing.tol", 37),
              ("scale.init", 38), ("diff.g", 42))

_PORT_MSG = {3: "X-convergence (3)", 4: "relative convergence (4)",
             5: "both X-convergence and relative convergence (5)",
             6: "absolute function convergence (6)", 7: "singular convergence (7)",
             8: "false convergence (8)",
             9: "function evaluation limit reached without convergence (9)",
             10: "iteration limit reached without convergence (10)",
             14: "storage only has been allocated (14)", 15: "LIV too small (15)",
             16: "LV too small (16)", 63: "fn cannot be computed at initial par (63)",
             65: "gr cannot be computed at initial par (65)",
             300: "initial par violates constraints"}


class NlminbResult(RList):
    """Ergebnis von ``nlminb`` (unbenannte R-Liste)."""


def _pmatch(nms, table):
    """``pmatch(nms, table)`` (duplicates.ok = FALSE); 1-basiert, None = NA."""
    used = [False] * len(table)
    ans = [None] * len(nms)
    for i, s in enumerate(nms):
        for j, t in enumerate(table):
            if not used[j] and s == t:
                ans[i] = j + 1
                used[j] = True
                break
    for i, s in enumerate(nms):
        if ans[i] is not None or len(s) == 0:
            continue
        mtch = 0
        cnt = 0
        for j, t in enumerate(table):
            if not used[j] and t.startswith(s):
                mtch = j + 1
                cnt += 1
        if mtch > 0 and cnt == 1:
            used[mtch - 1] = True
            ans[i] = mtch
    return ans


def _r_any_ne(x, ref):
    """``any(x != ref)`` mit R's NA-Logik (None = NA)."""
    na = False
    for e in x:
        if e != e:
            na = True
        elif e != ref:
            return True
    return None if na else False


def _ctl_int(val):
    """``as.integer`` eines Steuerwerts (NA -> INT_MIN)."""
    if isinstance(val, (bool, np.bool_)):
        return int(val)
    f = float(val)
    if f != f or abs(f) >= 2147483648.0:
        if f == f:
            _warn("NAs introduced by coercion to integer range")
        return -2147483648
    return int(f)


def nlminb(start, objective, gradient=None, hessian=None, *args, scale=1, control=None,
           lower=-math.inf, upper=math.inf, **kwargs):
    """``nlminb(start, objective, gradient, hessian, ..., scale, control, lower, upper)``.

    Minimierung mit der PORT-Bibliothek (``drmnf``, ``drmng``, ``drmnh`` und
    die Varianten mit Schranken ``drmnfb``, ``drmngb``, ``drmnhb``) wie in R.

    Argumente:
        start: Startwerte (Array, Liste oder benannte ``Series``).
        objective: Zielfunktion ``objective(par, *args, **kwargs)``; ``par``
            ist wie ``start`` benannt (``Series``) oder ein Array.
        gradient: optional, Gradient ``gradient(par, ...)`` (Länge n).
        hessian: optional (nur mit ``gradient``), Hesse-Matrix (n x n).
        *args, **kwargs: weitere Argumente für die Funktionen (R's ``...``).
        scale: Skalierung der Parameter (wird auf n verlängert).
        control: ``dict`` mit ``eval.max``, ``iter.max``, ``trace``,
            ``abs.tol``, ``rel.tol``, ``x.tol``, ``xf.tol``, ``step.min``,
            ``step.max``, ``sing.tol``, ``scale.init``, ``diff.g``
            (Teilnamen wie in R erlaubt).
        lower, upper: Schranken (werden auf n verlängert).

    Ergebnis: Liste mit ``par``, ``objective``, ``convergence``,
    ``iterations``, ``evaluations`` (``Series`` ``function``/``gradient``) und
    ``message``.
    """
    from . import port as _port
    if isinstance(start, pd.Series):
        names = None if isinstance(start.index, pd.RangeIndex) else [str(i) for i in start.index]
        pv = start.to_numpy(dtype=np.float64).copy()
    elif isinstance(start, Mapping):
        names = [str(k) for k in start.keys()]
        pv = np.array([float(v) for v in start.values()], dtype=np.float64)
    else:
        names = None
        pv = np.atleast_1d(np.asarray(start, dtype=np.float64)).ravel().copy()
    n = pv.size
    liv = 78 + 3 * n
    lv = 130 + (n * (n + 27)) // 2
    iv = np.zeros(liv + 1, dtype=np.int64)   # 1-basiert (iv[0] ungenutzt)
    v = np.zeros(lv + 1, dtype=np.float64)
    _port.divset(2, iv, liv, lv, v)
    if control:
        if not isinstance(control, Mapping):
            raise RError("'control' argument must be a named list")
        nms = [str(k) for k in control.keys()]
        vals = list(control.values())
        tab = [k for k, _ in _PORT_CPOS]
        pos = _pmatch(nms, tab)
        nap = [p is None for p in pos]
        if any(nap):
            msg = "unrecognized control element named %s ignored" if len(nap) == 1 else \
                "unrecognized control elements named %s ignored"
            _warn(msg % ", ".join("‘%s’" % nms[i] for i in range(len(nms)) if nap[i]))
            vals = [vals[i] for i in range(len(vals)) if not nap[i]]
            pos = [p for p in pos if p is not None]
        ivv = [(_PORT_CPOS[p - 1][1], vals[i]) for i, p in enumerate(pos) if p <= 4]
        vvv = [(_PORT_CPOS[p - 1][1], vals[i]) for i, p in enumerate(pos) if p > 4]
        ivi = [_ctl_int(val) for _, val in ivv]
        for (k, _), val in zip(ivv, ivi):
            iv[k] = val
        for k, val in vvv:
            v[k] = float(val)
    fn = (lambda p: objective(p, *args, **kwargs))
    gr = hs = None
    if gradient is not None:
        gr = (lambda p: gradient(p, *args, **kwargs))
        if hessian is not None:
            if isinstance(hessian, (bool, np.bool_)):
                raise RError("logical 'hessian' argument not allowed.  See documentation.")
            hs = (lambda p: hessian(p, *args, **kwargs))
    lo = np.atleast_1d(np.asarray(lower, dtype=np.float64)).ravel()
    up = np.atleast_1d(np.asarray(upper, dtype=np.float64)).ravel()
    a1 = _r_any_ne(lo, -math.inf)
    bounded = True if a1 is True else _r_any_ne(up, math.inf)
    if a1 is None and bounded is False:
        bounded = None
    if bounded is None:
        raise RError("missing value where TRUE/FALSE needed")
    low = np.resize(lo, n) if bounded else None
    upp = np.resize(up, n) if bounded else None
    sc = np.atleast_1d(np.asarray(scale, dtype=np.float64)).ravel()
    d = np.resize(sc, n) if n else sc[:0]
    x = _port.port_nlminb(fn, gr, hs, low, upp, d, iv, v, pv, names)
    iv1 = int(iv[1])
    res = NlminbResult()
    res["par"] = pd.Series(x, index=names) if names is not None else x
    res["objective"] = float(v[10])
    res["convergence"] = 0 if 3 <= iv1 <= 6 else 1
    res["iterations"] = int(iv[31])
    res["evaluations"] = pd.Series([int(iv[6]), int(iv[30])], index=["function", "gradient"])
    if 19 <= iv1 <= 43:
        hit = [k for k, p in _PORT_CPOS if p == iv1]
        from .fmt import sprintf as _sprintf
        if hit:
            msg = _sprintf("'control' component '%s' = %g, is out of range", hit[0], float(v[iv1]))
        else:
            msg = _sprintf("V[IV[1]] = V[%d] = %g is out of range (see PORT docu.)", iv1,
                           float(v[iv1]))
    else:
        msg = _PORT_MSG.get(iv1, "See PORT documentation.  Code (%d)" % iv1)
    res["message"] = msg
    return res


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
