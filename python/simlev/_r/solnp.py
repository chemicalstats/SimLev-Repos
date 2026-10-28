"""Nachbildung von ``Rsolnp::solnp`` (Rsolnp 1.16, Ghalanos & Theussl).

Herkunft: R-Paket Rsolnp 1.16 (CRAN, 2015-12-28), ``solnp``, ``gosolnp`` und
Hilfen; Autoren: Alexios Ghalanos and Stefan Theussl. Lizenz: GPL (laut
``inst/COPYRIGHTS`` von Rsolnp GPL-3). Nach Python übertragen und angepasst
für SimLev (siehe ``python/COPYRIGHTS.md``); im R-Paket übernommen als
``.rsolnp_solnp`` und ``.rsolnp_gosolnp`` (``r/R/vendor_rsolnp.R``).

SQP-Verfahren nach Y. Ye (1989) mit erweiterter Lagrange-Funktion für
Gleichungs- und Ungleichungsnebenbedingungen und Parameterschranken. Die
Rechenschritte folgen dem R-Code von ``solnp``, ``.subnp`` und den Hilfen
(``.checkpars``, ``.checkfun``, ``.checkineq``, ``.checkeq``,
``.safefunx``, ``.solnpctrl``, ``.vnorm``, ``.solvecond``) Zeile für Zeile;
Matrixprodukte, ``chol``, ``solve`` und ``qr.solve`` kommen aus
:mod:`simlev._r.linalg` (Referenz-BLAS/LAPACK/LINPACK wie R).

Nicht nachgebildet ist die Laufzeitmessung (``elapsed`` ist ``None``).
``.solvecond`` (Konditionszahl über ``svd``) beeinflusst nur eine
Meldung bei ``trace > 0``; die Fehlerprüfung von ``svd`` (nicht endliche
Werte) ist nachgebildet, die Konditionszahl selbst für mehr als eine
Nebenbedingung über numpy berechnet (nicht bitgleich, nur für die Meldung).
"""
from __future__ import annotations

import math
import sys
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

from . import rformat as _rf
from . import rnum as _rn
from . import linalg as _la
from .linalg import RError
from .rlist import RList

__all__ = ["solnp", "SolnpResult", "gosolnp", "GosolnpResult"]

_EPS = 2.220446049250313e-16          # Rsolnp:::.eps = .Machine$double.eps
_SQRT_EPS = math.sqrt(_EPS)
_DBL_XMAX = sys.float_info.max


class SolnpResult(RList):
    """Ergebnis von :func:`solnp` (R-Liste ``pars``, ``convergence``, ``values``, …)."""


class _NotPorted(Exception):
    """Lage, die der Nachbau nicht abdeckt (würde in R anders weiterlaufen)."""


# ── kleine R-Hilfen ─────────────────────────────────────────────────────────

def _rif(x):
    """``if (x)`` in R: NA/NaN ergibt einen Fehler."""
    x = float(x)
    if x != x:
        raise RError("missing value where TRUE/FALSE needed")
    return x != 0.0


_OPS = {"<": lambda a, b: a < b, "<=": lambda a, b: a <= b, ">": lambda a, b: a > b,
        ">=": lambda a, b: a >= b}


def _c(a, op, b):
    """Vergleich ``a op b`` im ``if``/``while`` von R: NA/NaN ergibt einen Fehler."""
    a = float(a)
    b = float(b)
    if a != a or b != b:
        raise RError("missing value where TRUE/FALSE needed")
    return _OPS[op](a, b)


def _rall(v):
    """``all(v)`` mit R's NA-Logik (None = NA); NA ergibt im ``if`` einen Fehler."""
    na = False
    for x in v:
        if x is None:
            na = True
        elif not x:
            return False
    if na:
        raise RError("missing value where TRUE/FALSE needed")
    return True


def _rmax(v):
    """``max(v)`` (ohne na.rm) wie R's ``rmax``."""
    s = 0.0
    upd = False
    for x in np.asarray(v, dtype=np.float64).ravel().tolist():
        if x != x:
            if not _rn.r_isna(s):
                s = x
            upd = True
        elif not upd or x > s:
            s = x
            upd = True
    return s if upd else -math.inf


def _rmin(v):
    """``min(v)`` (ohne na.rm) wie R's ``rmin``."""
    s = 0.0
    upd = False
    for x in np.asarray(v, dtype=np.float64).ravel().tolist():
        if x != x:
            if not _rn.r_isna(s):
                s = x
            upd = True
        elif not upd or x < s:
            s = x
            upd = True
    return s if upd else math.inf


def _vnorm(x):
    """``.vnorm(x) = sum(x^2)^(1/2)``."""
    a = np.asarray(x, dtype=np.float64).ravel()
    return _rn.r_pow(_rn.r_sum(a * a), 0.5)


def _mm(X, Y):
    """``X %*% Y`` für zwei Matrizen (2-D-Arrays) wie R's ``matprod``."""
    X = np.asfortranarray(np.asarray(X, dtype=np.float64))
    Y = np.asfortranarray(np.asarray(Y, dtype=np.float64))
    if X.shape[1] != Y.shape[0]:
        raise RError("non-conformable arguments")
    with np.errstate(all="ignore"):
        return _la._matprod_core(X, Y)


def _col(v):
    return np.asarray(v, dtype=np.float64).reshape(-1, 1)


def _row(v):
    return np.asarray(v, dtype=np.float64).reshape(1, -1)


def _outer(v):
    """``v %*% t(v)`` für einen Vektor ``v``."""
    return _mm(_col(v), _row(v))


def _row_min_sorted(gap):
    """``t(apply(gap, 1, sort))[, 1]`` für eine Matrix mit zwei Spalten."""
    out = np.empty(gap.shape[0])
    for i in range(gap.shape[0]):
        a, b = float(gap[i, 0]), float(gap[i, 1])
        if a != a or b != b:
            raise _NotPorted("solnp-Nachbildung: NA/NaN in den Abständen zu den Schranken")
        out[i] = b if b < a else a
    return out


def _solvecond(a):
    """``.solvecond(a)``: Konditionszahl über ``svd(a)$d``."""
    a = np.asarray(a, dtype=np.float64)
    if not np.isfinite(a).all():
        raise RError("infinite or missing values in 'x'")
    if a.shape[0] == 1 or a.shape[1] == 1:
        return math.inf if not np.any(a != 0.0) else 1.0
    d = np.linalg.svd(a, compute_uv=False)
    if np.any(d == 0.0):
        return math.inf
    return float(d.max() / d.min())


def _cat(txt):
    sys.stdout.write(txt)


def _subnpmsg(m):
    g1 = "solnp-->"
    if m == "m1":
        txt = ("\n" + g1 + "Redundant constraints were found. Poor\n" + g1
               + "intermediate results may result.Suggest that you\n" + g1
               + "remove redundant constraints and re-OPTIMIZE\n")
    elif m == "m2":
        txt = ("\n" + g1 + "The linearized problem has no feasible\n" + g1
               + "solution.  The problem may not be feasible.\n")
    else:
        txt = ("\n" + g1 + "Minor optimization routine did not converge in the \n" + g1
               + "specified number of minor iterations.  You may need\n" + g1
               + "to increase the number of minor iterations.        \n")
    _cat(txt)


def _report(it, funv, pars):
    """``.report(iter, funv, pars)`` (nur bei ``trace > 0``)."""
    from . import fmt as _fmt
    try:
        f1 = _fmt.format(funv, digits=4, scientific=5, nsmall=4)
        f2 = _fmt.format(np.asarray(pars, dtype=np.float64), digits=4, scientific=6, nsmall=5)
        f1 = f1 if isinstance(f1, str) else " ".join(np.atleast_1d(f1).tolist())
        f2 = " ".join(np.atleast_1d(f2).tolist())
    except Exception:  # noqa: BLE001 - nur Fortschrittsanzeige
        f1 = repr(float(funv))
        f2 = " ".join(repr(float(x)) for x in np.ravel(pars))
    _cat("\nIter: %d fn: %s\t Pars:  %s" % (it, f1, f2))


def _warn(msg):
    warnings.warn(msg, UserWarning, stacklevel=3)


def _as_vec(x):
    if x is None:
        return None
    if isinstance(x, pd.Series):
        return x.to_numpy(dtype=np.float64).copy()
    return np.atleast_1d(np.asarray(x, dtype=np.float64)).ravel().copy()


def _num1(v):
    """Ergebnis einer Nutzerfunktion als Double-Vektor."""
    if v is None:
        return np.zeros(0)
    if isinstance(v, pd.Series):
        return v.to_numpy(dtype=np.float64)
    return np.atleast_1d(np.asarray(v, dtype=np.float64)).ravel()


def _r_str(v):
    """``paste(v)`` einer Zahl (nur für die Warnung nicht endlicher Werte)."""
    if _rn.r_isna(v):
        return "NA"
    if v != v:
        return "NaN"
    if v == math.inf:
        return "Inf"
    if v == -math.inf:
        return "-Inf"
    return _rf.r_as_character(v)


# ── Steuerung ───────────────────────────────────────────────────────────────

def _solnpctrl(control):
    """``Rsolnp:::.solnpctrl``: rho, outer.iter, inner.iter, delta, tol, trace."""
    defaults = {"rho": 1.0, "outer.iter": 400.0, "inner.iter": 800.0, "delta": 1e-07,
                "tol": 1e-08, "trace": 1.0}
    if not control:
        return defaults
    if not isinstance(control, Mapping):
        raise RError("'control' muss eine benannte Liste sein")
    npar = [str(k).lower() for k in control.keys()]
    vals = dict(zip(npar, list(control.values())))
    ans = {}
    for key, k in (("rho", 3), ("outer.iter", 10), ("inner.iter", 10), ("delta", 5),
                   ("tol", 3), ("trace", 5)):
        if any(s[:k] == key[:k] for s in npar):
            v = vals.get(key, None)
            ans[key] = _rn.NA_REAL if v is None else float(v)
        else:
            ans[key] = defaults[key]
    return ans


# ── solnp ───────────────────────────────────────────────────────────────────

class _Env:
    """Gegenstück zu ``.solnpenv``."""

    __slots__ = ("xnames", "nfn", "errors", "LB", "UB", "fun", "eqfun", "ineqfun",
                 "ineqLB", "ineqUB", "eqB", "ind", "args", "kwargs")


def _call(env, f, x):
    """Nutzerfunktion mit benannten Parametern (wie ``names(x) = xnames``) aufrufen."""
    if env.xnames is not None:
        x = pd.Series(np.asarray(x, dtype=np.float64), index=env.xnames)
    return f(x, *env.args, **env.kwargs)


def _safefunx(env, x):
    """``.safefunx``: nicht endliche Zielwerte werden zu 1e24 (mit Warnung)."""
    v = _num1(_call(env, env.fun, x))
    v = float(v[0]) if v.size else math.nan
    if v != v or not math.isfinite(v):
        _warn("\nsolnp-->warning: %s detected in function call...check your function\n" % _r_str(v))
        v = 1e24
    return v


def _eqv(env, x):
    if env.eqfun is None:
        return np.zeros(0)
    return _num1(_call(env, env.eqfun, x)) - env.eqB


def _ineqv(env, x):
    if env.ineqfun is None:
        return np.zeros(0)
    return _num1(_call(env, env.ineqfun, x))


def _checkpars(pars, LB, UB, env):
    if pars is None:
        raise RError("\nsolnp-->error: must supply starting parameters\n")
    if LB is not None:
        if len(pars) != len(LB):
            raise RError("\nsolnp-->error: LB length not equal to parameter length\n")
        if UB is None:
            UB = np.full(len(LB), _DBL_XMAX / 2)
    if UB is not None:
        if len(pars) != len(UB):
            raise RError("\nsolnp-->error: UB length not equal to parameter length\n")
        if LB is None:
            LB = np.full(len(UB), -_DBL_XMAX / 2)
    if UB is not None:
        with np.errstate(invalid="ignore"):
            cmp = LB > UB
        if np.any(cmp):
            raise RError("\nsolnp-->error: UB must be greater than LB\n")
        if np.any(LB == UB):
            _warn("\nsolnp-->warning: Equal Lower/Upper Bounds Found. Consider\n\n\t\t\t\t\t\texcluding fixed parameters.\n")
    if LB is not None and not np.any(np.isfinite(LB)):
        idx = ~np.isfinite(LB)
        LB = LB.copy()
        LB[idx] = np.sign(LB[idx]) * _DBL_XMAX / 2
    if UB is not None and not np.any(np.isfinite(UB)):
        idx = ~np.isfinite(UB)
        UB = UB.copy()
        UB[idx] = np.sign(UB[idx]) * _DBL_XMAX / 2
    env.LB = LB
    env.UB = UB


def solnp(pars, fun, *args, eqfun=None, eqB=None, ineqfun=None, ineqLB=None, ineqUB=None,
          LB=None, UB=None, control=None, **kwargs):
    """``Rsolnp::solnp(pars, fun, eqfun, eqB, ineqfun, ineqLB, ineqUB, LB, UB, control, ...)``.

    Nichtlineare Optimierung mit Nebenbedingungen (augmented Lagrange, SQP).

    Argumente:
        pars: Startwerte (Array oder benannte ``Series``).
        fun: Zielfunktion ``fun(pars, *args, **kwargs)`` (Skalar).
        *args, **kwargs: weitere Argumente für alle Funktionen (R's ``...``).
        eqfun, eqB: Gleichungsnebenbedingungen ``eqfun(pars) = eqB``.
        ineqfun, ineqLB, ineqUB: Ungleichungen ``ineqLB <= ineqfun(pars) <= ineqUB``.
        LB, UB: Parameterschranken.
        control: ``dict`` mit ``rho``, ``outer.iter``, ``inner.iter``,
            ``delta``, ``tol``, ``trace`` (Voreinstellung wie Rsolnp:
            1, 400, 800, 1e-7, 1e-8, 1).

    Ergebnis: :class:`SolnpResult` mit ``pars``, ``convergence`` (0 =
    konvergiert, 1 = Iterationsgrenze, 2 = Hesse-Matrix nicht invertierbar),
    ``values``, ``lagrange``, ``hessian``, ``ineqx0``, ``nfuneval``,
    ``outer.iter``, ``elapsed`` (``None``) und ``vscale``.
    """
    with np.errstate(all="ignore"):
        return _solnp(pars, fun, args, kwargs, eqfun, eqB, ineqfun, ineqLB, ineqUB, LB, UB, control)


def _solnp(pars, fun, args, kwargs, eqfun, eqB, ineqfun, ineqLB, ineqUB, LB, UB, control):
    env = _Env()
    env.args = args
    env.kwargs = kwargs
    if isinstance(pars, pd.Series) and not isinstance(pars.index, pd.RangeIndex):
        env.xnames = [str(i) for i in pars.index]
    else:
        env.xnames = None
    pars_in = pars
    pars = _as_vec(pars) if pars is not None else None
    env.nfn = 0
    env.errors = 0
    ind = [0.0] * 11
    if pars is None:
        _checkpars(None, None, None, env)
    np_ = len(pars)
    ind[0] = np_
    _checkpars(pars, _as_vec(LB), _as_vec(UB), env)
    if env.LB is not None or env.UB is not None:
        ind[9] = 1
    # .checkfun
    if not callable(fun):
        raise RError("\nsolnp-->error: fun does not appear to be a function\n")
    val = _num1(fun(pars_in, *args, **kwargs))
    if val.size != 1:
        raise RError("\nsolnp-->error: objective function returns value of length greater than 1!\n")
    funv = float(val[0])
    env.fun = fun
    env.nfn += 1
    env.eqfun = None
    env.ineqfun = None
    ineqx0 = None
    if ineqfun is not None:
        ineqv = _num1(ineqfun(pars_in, *args, **kwargs))
        n = ineqv.size
        if ineqLB is None:
            raise RError("\nsolnp-->error: inequality function given without lower bounds\n")
        ineqLB = _as_vec(ineqLB)
        if ineqLB.size != n:
            raise RError("\nsolnp-->error: inequality function returns vector of different length to\n\t\t\t\t\t\t\tinequality lower bounds\n")
        if ineqUB is None:
            raise RError("\nsolnp-->error: inequality function given without upper bounds\n")
        ineqUB = _as_vec(ineqUB)
        if ineqUB.size != n:
            raise RError("\nsolnp-->error: inequality function returns vector of different length to\n\t\t\t\t\t\t\tinequality upper bounds\n")
        if np.any(ineqLB > ineqUB):
            raise RError("\nsolnp-->error: ineqUB must be greater than ineqLB\n")
        env.ineqLB = ineqLB
        env.ineqUB = ineqUB
        env.ineqfun = ineqfun
        ind[3] = 1
        nineq = ineqLB.size
        ind[4] = nineq
        lbx = ineqLB.copy()
        ubx = ineqUB.copy()
        lbx[~np.isfinite(ineqLB)] = -1e10
        ubx[~np.isfinite(ineqUB)] = 1e10
        ineqx0 = (lbx + ubx) / 2
        ind[5] = 0
    else:
        ineqv = np.zeros(0)
        nineq = 0
        env.ineqLB = None
        env.ineqUB = None
    if eqfun is not None:
        eqB_v = _as_vec(eqB) if eqB is not None else np.zeros(0)
        eqv = _num1(eqfun(pars_in, *args, **kwargs)) - eqB_v
        if eqv.size != eqB_v.size:
            raise RError("\nsolnp-->error: equality function returns vector of different length\n\t\t\t\t\t\tto equality value\n")
        env.eqB = eqB_v
        env.eqfun = eqfun
        ind[6] = 1
        neq = eqB_v.size
        ind[7] = neq
        ind[8] = 0
    else:
        eqv = np.zeros(0)
        neq = 0
        env.eqB = np.zeros(0)
    if ind[9] or ind[3]:
        ind[10] = 1
    env.ind = ind
    pb_rows = []
    if env.ineqLB is not None:
        pb_rows.append(np.column_stack([env.ineqLB, env.ineqUB]))
    if env.LB is not None:
        pb_rows.append(np.column_stack([env.LB, env.UB]))
    pb = np.vstack(pb_rows) if pb_rows else None
    ctrl = _solnpctrl(control)
    rho = ctrl["rho"]
    maxit = ctrl["outer.iter"]
    minit = ctrl["inner.iter"]
    delta = ctrl["delta"]
    tol = ctrl["tol"]
    trace = ctrl["trace"]
    tc = nineq + neq
    j = funv
    jh = [funv]
    tt = np.zeros(3)
    if tc > 0:
        lam = np.zeros(tc)
        constraint = np.concatenate([eqv, ineqv])
        if ind[3]:
            c_in = constraint[neq:tc]
            tmp1 = c_in - env.ineqLB
            tmp2 = env.ineqUB - c_in
            tmin = np.array([_rmin([tmp1[i], tmp2[i]]) for i in range(nineq)])
            if _rall([t > 0 if t == t else None for t in tmin.tolist()]):
                ineqx0 = c_in.copy()
            constraint[neq:tc] = c_in - ineqx0
        tt[1] = _vnorm(constraint)
        mx = [tt[1] - 10 * tol, float(nineq)]
        mx = [x for x in mx if x == x]
        if _c(_rmax(mx) if mx else -math.inf, '<=', 0):
            rho = 0.0
    else:
        lam = np.zeros(1)
    p = np.concatenate([ineqx0 if ineqx0 is not None else np.zeros(0), pars])
    hessv = np.eye(np_ + nineq)
    mu = float(np_)
    it = 0
    ob = np.concatenate([[funv], eqv, ineqv])
    vscale = None
    while _c(it, '<', maxit):
        it += 1
        sub_ctrl = (rho, minit, delta, tol, trace)
        if ind[6]:
            vs = np.concatenate([[ob[0]], np.ones(neq) * _rmax(np.abs(ob[1:neq + 1]))])
        else:
            vs = np.ones(1)
        if not ind[10]:
            vs = np.concatenate([vs, p])
        else:
            vs = np.concatenate([vs, np.ones(len(p))])
        vscale = np.empty(vs.size)
        for i, x in enumerate(vs.tolist()):
            ax = abs(x)
            m1 = _rmax([ax, tol])
            vscale[i] = _rmin([m1, 1 / tol])
        res = _subnp(p, lam, ob, hessv, mu, vscale, sub_ctrl, env, pb)
        if env.errors == 1:
            maxit = it
        p = res["p"]
        lam = res["y"]
        hessv = res["hessv"]
        mu = res["lambda"]
        temp = p[nineq:nineq + np_]
        funv = _safefunx(env, temp)
        env.nfn += 1
        if _rif(trace):
            _report(it, funv, temp)
        eqv = _eqv(env, temp)
        ineqv = _ineqv(env, temp)
        ob = np.concatenate([[funv], eqv, ineqv])
        tt[0] = (j - ob[0]) / _rmax([abs(ob[0]), 1.0])
        j = ob[0]
        if tc > 0:
            constraint = ob[1:tc + 1].copy()
            if ind[3]:
                c_in = constraint[neq:tc]
                tempv = np.concatenate([c_in - pb[:nineq, 0], pb[:nineq, 1] - c_in])
                if _c(_rmin(tempv), '>', 0):
                    p[:nineq] = c_in
                constraint[neq:tc] = c_in - p[:nineq]
            tt[2] = _vnorm(constraint)
            if _c(tt[2], '<', 10 * tol):
                rho = 0.0
                mu = _rmin([mu, tol])
            if _c(tt[2], '<', 5 * tt[1]):
                rho = rho / 5
            if _c(tt[2], '>', 10 * tt[1]):
                rho = 5 * _rmax([rho, math.sqrt(tol)])
            if _c(_rmax([tol + tt[0], tt[1] - tt[2]]), '<=', 0):
                lam = np.zeros(1)
                hessv = np.diag(np.diag(hessv).copy())
            tt[1] = tt[2]
        if _c(_vnorm(tt[0:2]), '<=', tol):
            maxit = it
        jh.append(j)
    if ind[3]:
        ineqx0 = p[:nineq].copy()
    p = p[nineq:nineq + np_].copy()
    if env.errors == 1:
        convergence = 2
        if _rif(trace):
            _cat("\nsolnp--> Solution not reliable....Problem Inverting Hessian.\n")
    elif _c(_vnorm(tt[0:2]), '<=', tol):
        convergence = 0
        if _rif(trace):
            _cat("\nsolnp--> Completed in %d iterations\n" % it)
    else:
        convergence = 1
        if _rif(trace):
            _cat("\nsolnp--> Exiting after maximum number of iterations\nTolerance not achieved\n")
    out = SolnpResult()
    out["pars"] = pd.Series(p, index=env.xnames) if env.xnames is not None else p
    out["convergence"] = convergence
    out["values"] = np.asarray(jh, dtype=np.float64)
    out["lagrange"] = lam
    out["hessian"] = hessv
    out["ineqx0"] = ineqx0
    out["nfuneval"] = env.nfn
    out["outer.iter"] = it
    out["elapsed"] = None
    out["vscale"] = vscale
    return out


def _eval_ob(env, x, vsc):
    """``c(funv, eqv, ineqv) / vscale[1:(nc + 1)]`` mit Zähler (wie in ``.subnp``)."""
    funv = _safefunx(env, x)
    eqv = _eqv(env, x)
    ineqv = _ineqv(env, x)
    env.nfn += 1
    return np.concatenate([[funv], eqv, ineqv]) / vsc


def _subnp(pars, yy, ob, hessv, lam, vscale, ctrl, env, pb):
    """``Rsolnp:::.subnp`` (ein SQP-Teilproblem)."""
    ind = env.ind
    rho, maxit, delta, tol, trace = ctrl
    neq = int(ind[7])
    nineq = int(ind[4])
    np_ = int(ind[0])
    ch = 1
    alp = [0.0, 0.0, 0.0]
    nc = neq + nineq
    npic = np_ + nineq
    p0 = np.asarray(pars, dtype=np.float64).copy()
    pb = None if pb is None else pb.copy()
    sob = [0.0, 0.0, 0.0]
    ob = np.asarray(ob, dtype=np.float64) / vscale[0:nc + 1]
    vs_p = vscale[neq + 1:nc + np_ + 1]          # vscale[(neq + 2):(nc + np + 1)]
    vs_x = vscale[nc + 1:nc + np_ + 1]           # vscale[(nc + 2):(nc + np + 1)]
    vs_o = vscale[0:nc + 1]
    p0 = p0 / vs_p
    mm = 0
    if ind[10]:
        mm = nineq if not ind[9] else npic
        vv = vscale[neq + 1:neq + mm + 1]
        pb = pb / np.column_stack([vv, vv])
    yy = np.asarray(yy, dtype=np.float64).ravel()
    if nc > 0:
        yy = vscale[1:nc + 1] * yy / vscale[0]
    hessv = hessv * _outer(vs_p) / vscale[0]
    j = float(ob[0])
    a = None
    if ind[3]:
        if not ind[6]:
            a = np.hstack([-np.eye(nineq), np.zeros((nineq, np_))])
        else:
            a = np.vstack([np.hstack([np.zeros((neq, nineq)), np.zeros((neq, np_))]),
                           np.hstack([-np.eye(nineq), np.zeros((nineq, np_))])])
    if ind[6] and not ind[3]:
        a = np.zeros((neq, np_))
    if not ind[6] and not ind[3]:
        a = np.zeros((1, np_))
    g = np.zeros(npic)
    p = p0[0:npic].copy()
    b = None
    if nc > 0:
        constraint = ob[1:nc + 1].copy()
        for i in range(np_):
            p0[nineq + i] = p0[nineq + i] + delta
            tmpv = p0[nineq:npic] * vs_x
            ob = _eval_ob(env, tmpv, vs_o)
            g[nineq + i] = (ob[0] - j) / delta
            a[:, nineq + i] = (ob[1:nc + 1] - constraint) / delta
            p0[nineq + i] = p0[nineq + i] - delta
        if ind[3]:
            constraint[neq:neq + nineq] = constraint[neq:neq + nineq] - p0[0:nineq]
        if _c(_solvecond(a), '>', 1 / _EPS):
            if _rif(trace):
                _subnpmsg("m1")
        b = _mm(a, _col(p0))[:, 0] - constraint
        ch = -1
        alp[0] = tol - _rmax(np.abs(constraint))
        if _c(alp[0], '<=', 0):
            ch = 1
            if not ind[10]:
                aat = _mm(a, a.T)
                sv = _la.solve(aat, constraint)
                p0 = p0 - _mm(a.T, _col(np.asarray(sv, dtype=np.float64)))[:, 0]
                alp[0] = 1.0
        if _c(alp[0], '<=', 0):
            p0 = np.concatenate([p0, [1.0]])
            a = np.hstack([a, -_col(constraint)])
            cx = np.concatenate([np.zeros(npic), [1.0]])
            dx = np.ones(npic + 1)
            go = 1.0
            minit = 0
            while _c(go, '>=', tol):
                minit += 1
                gap = np.column_stack([p0[0:mm] - pb[:, 0], pb[:, 1] - p0[0:mm]])
                dx[0:mm] = _row_min_sorted(gap)
                dx[npic] = p0[npic]
                if not ind[9]:
                    dx[mm:npic] = _rmax(np.concatenate([dx[0:mm], [100.0]])) * np.ones(npic - mm)
                try:
                    D = np.diag(dx.copy())
                    lhs = _mm(a, D).T.copy()
                    y = _la.qr_solve(lhs, _col(dx * cx))
                    y = np.asarray(y, dtype=np.float64).reshape(-1)
                except RError:
                    p = p0 * vs_p if p0.size == vs_p.size else _recycle_mul(p0, vs_p)
                    yret = 0.0 if nc > 0 else y
                    hessv = vscale[0] * hessv / _outer(vs_p)
                    env.errors = 1
                    return {"p": p, "y": np.atleast_1d(yret), "hessv": hessv, "lambda": lam}
                v = dx * (dx * (cx - _mm(a.T, _col(y))[:, 0]))
                if _c(v[npic], '>', 0):
                    z = p0[npic] / v[npic]
                    for i in range(mm):
                        if _c(v[i], '<', 0):
                            z = _rmin([z, -(pb[i, 1] - p0[i]) / v[i]])
                        elif _c(v[i], '>', 0):
                            z = _rmin([z, (p0[i] - pb[i, 0]) / v[i]])
                    if _c(z, '>=', p0[npic] / v[npic]):
                        p0 = p0 - z * v
                    else:
                        p0 = p0 - 0.9 * z * v
                    go = p0[npic]
                    if minit >= 10:
                        go = 0.0
                else:
                    go = 0.0
                    minit = 10
            if minit >= 10:
                if _rif(trace):
                    _subnpmsg("m2")
            a = a[:, 0:npic].copy()
            b = _mm(a, _col(p0[0:npic]))[:, 0]
    p = p0[0:npic].copy()
    y = np.zeros(1)
    if ch > 0:
        tmpv = p[nineq:npic] * vs_x
        ob = _eval_ob(env, tmpv, vs_o)
    j = float(ob[0])
    if ind[3]:
        ob = ob.copy()
        ob[neq + 1:nc + 1] = ob[neq + 1:nc + 1] - p[0:nineq]
    if nc > 0:
        ob = ob.copy()
        ob[1:nc + 1] = ob[1:nc + 1] - _mm(a, _col(p))[:, 0] + b
        j = float(ob[0] - _mm(_row(yy), _col(ob[1:nc + 1]))[0, 0]
                  + rho * _rn.r_pow(_vnorm(ob[1:nc + 1]), 2.0))
    minit = 0
    yg = None
    sx = None
    reduce = None
    sc = [0.0, 0.0]
    ob1 = ob2 = ob3 = ob
    ptt = None
    while _c(minit, '<', maxit):
        minit += 1
        if ch > 0:
            for i in range(np_):
                p[nineq + i] = p[nineq + i] + delta
                tmpv = p[nineq:npic] * vs_x
                obm = _eval_ob(env, tmpv, vs_o)
                if ind[3]:
                    obm[neq + 1:nc + 1] = obm[neq + 1:nc + 1] - p[0:nineq]
                if nc > 0:
                    obm[1:nc + 1] = obm[1:nc + 1] - _mm(a, _col(p))[:, 0] + b
                    obm_s = float(obm[0] - _mm(_row(yy), _col(obm[1:nc + 1]))[0, 0]
                                  + rho * _rn.r_pow(_vnorm(obm[1:nc + 1]), 2.0))
                else:
                    obm_s = float(obm[0])
                g[nineq + i] = (obm_s - j) / delta
                p[nineq + i] = p[nineq + i] - delta
            if ind[3]:
                g[0:nineq] = 0.0
        if minit > 1:
            yg = g - yg
            sx = p - sx
            sc[0] = float(_mm(_mm(_row(sx), hessv), _col(sx))[0, 0])
            sc[1] = float(_mm(_row(sx), _col(yg))[0, 0])
            if _c(sc[0] * sc[1], '>', 0):
                sx = _mm(hessv, _col(sx))[:, 0]
                hessv = hessv - _outer(sx) / sc[0] + _outer(yg) / sc[1]
        dx = 0.01 * np.ones(npic)
        if ind[10]:
            gap = np.column_stack([p[0:mm] - pb[:, 0], pb[:, 1] - p[0:mm]])
            gap = _row_min_sorted(gap)
            gap = gap + _SQRT_EPS * np.ones(mm)
            dx[0:mm] = np.ones(mm) / gap
            if not ind[9]:
                dx[mm:npic] = _rmin(np.concatenate([dx[0:mm], [0.01]])) * np.ones(npic - mm)
        go = -1.0
        lam = lam / 10
        while _c(go, '<=', 0):
            try:
                cz = _la.chol(hessv + lam * np.diag(dx * dx))
                cz = np.asarray(cz, dtype=np.float64)
            except RError:
                return _subnp_fail(p, vs_p, nc, vscale, hessv, lam, env)
            try:
                cz = np.asarray(_la.solve(cz), dtype=np.float64)
            except RError:
                return _subnp_fail(p, vs_p, nc, vscale, hessv, lam, env)
            yg = _mm(cz.T, _col(g))[:, 0]
            if nc == 0:
                u = _mm(-cz, _col(yg))[:, 0]
            else:
                cta = _mm(cz.T, a.T)
                try:
                    y = np.asarray(_la.qr_solve(cta, _col(yg)), dtype=np.float64).reshape(-1)
                except RError:
                    return _subnp_fail(p, vs_p, nc, vscale, hessv, lam, env)
                u = _mm(-cz, _col(yg - _mm(cta, _col(y))[:, 0]))[:, 0]
            p0 = u[0:npic] + p
            if not ind[10]:
                go = 1.0
            else:
                go = _rmin(np.concatenate([p0[0:mm] - pb[:, 0], pb[:, 1] - p0[0:mm]]))
                lam = 3 * lam
        alp[0] = 0.0
        ob1 = ob
        ob2 = ob1
        sob[0] = j
        sob[1] = j
        ptt = np.column_stack([p, p, p0])
        alp[2] = 1.0
        tmpv = ptt[nineq:npic, 2] * vs_x
        ob3 = _eval_ob(env, tmpv, vs_o)
        sob[2] = float(ob3[0])
        if ind[3]:
            ob3[neq + 1:nc + 1] = ob3[neq + 1:nc + 1] - ptt[0:nineq, 2]
        if nc > 0:
            ob3[1:nc + 1] = ob3[1:nc + 1] - _mm(a, _col(ptt[:, 2]))[:, 0] + b
            sob[2] = float(ob3[0] - _mm(_row(yy), _col(ob3[1:nc + 1]))[0, 0]
                           + rho * _rn.r_pow(_vnorm(ob3[1:nc + 1]), 2.0))
        go = 1.0
        while _c(go, '>', tol):
            alp[1] = (alp[0] + alp[2]) / 2
            ptt[:, 1] = (1 - alp[1]) * p + alp[1] * p0
            tmpv = ptt[nineq:npic, 1] * vs_x
            ob2 = _eval_ob(env, tmpv, vs_o)
            sob[1] = float(ob2[0])
            if ind[3]:
                ob2[neq + 1:nc + 1] = ob2[neq + 1:nc + 1] - ptt[0:nineq, 1]
            if nc > 0:
                ob2[1:nc + 1] = ob2[1:nc + 1] - _mm(a, _col(ptt[:, 1]))[:, 0] + b
                sob[1] = float(ob2[0] - _mm(_row(yy), _col(ob2[1:nc + 1]))[0, 0]
                               + rho * _rn.r_pow(_vnorm(ob2[1:nc + 1]), 2.0))
            obm = _rmax(sob)
            if _c(obm, '<', j):
                obn = _rmin(sob)
                go = tol * (obm - obn) / (j - obm)
            condif1 = _c(sob[1], '>=', sob[0])
            condif2 = _c(sob[0], '<=', sob[2]) and _c(sob[1], '<', sob[0])
            condif3 = _c(sob[1], '<', sob[0]) and _c(sob[0], '>', sob[2])
            if condif1:
                sob[2] = sob[1]
                ob3 = ob2
                alp[2] = alp[1]
                ptt[:, 2] = ptt[:, 1]
            if condif2:
                sob[2] = sob[1]
                ob3 = ob2
                alp[2] = alp[1]
                ptt[:, 2] = ptt[:, 1]
            if condif3:
                sob[0] = sob[1]
                ob1 = ob2
                alp[0] = alp[1]
                ptt[:, 0] = ptt[:, 1]
            if _c(go, '>=', tol):
                go = alp[2] - alp[0]
        sx = p.copy()
        yg = g.copy()
        ch = 1
        obn = _rmin(sob)
        if _c(j, '<=', obn):
            maxit = minit
        reduce = (j - obn) / (1 + abs(j))
        if _c(reduce, '<', tol):
            maxit = minit
        condif1 = _c(sob[0], '<', sob[1])
        condif2 = _c(sob[2], '<', sob[1]) and _c(sob[0], '>=', sob[1])
        condif3 = _c(sob[0], '>=', sob[1]) and _c(sob[2], '>=', sob[1])
        if condif1:
            j = sob[0]
            p = ptt[:, 0].copy()
            ob = ob1
        if condif2:
            j = sob[2]
            p = ptt[:, 2].copy()
            ob = ob3
        if condif3:
            j = sob[1]
            p = ptt[:, 1].copy()
            ob = ob2
    p = p * vs_p
    if nc > 0:
        y = vscale[0] * np.asarray(y, dtype=np.float64).ravel() / vscale[1:nc + 1]
    hessv = vscale[0] * hessv / _outer(vs_p)
    if reduce is None:
        raise RError("object 'reduce' not found")
    if _c(reduce, '>', tol):
        if _rif(trace):
            _subnpmsg("m3")
    return {"p": p, "y": y, "hessv": hessv, "lambda": lam}


def _recycle_mul(a, b):
    n = max(a.size, b.size)
    if n % min(a.size, b.size):
        _warn("longer object length is not a multiple of shorter object length")
    return np.resize(a, n) * np.resize(b, n)


def _subnp_fail(p, vs_p, nc, vscale, hessv, lam, env):
    """Rücksprung von ``.subnp`` nach fehlgeschlagener Zerlegung (``.solnp_errors = 1``)."""
    p = p * vs_p
    y = np.zeros(1)
    hessv = vscale[0] * hessv / _outer(vs_p)
    env.errors = 1
    return {"p": p, "y": y, "hessv": hessv, "lambda": lam}


# ── gosolnp ─────────────────────────────────────────────────────────────────

class GosolnpResult(RList):
    """Ergebnis von :func:`gosolnp` (Ergebnis von ``solnp`` mit ``start.pars`` und ``rseed``)."""


def _r_or(a, b):
    """``a | b`` für logische Skalare mit R's NA-Logik (None = NA)."""
    if a is True or b is True:
        return True
    if a is None or b is None:
        return None
    return False


def _lgl_gt0(v):
    """``v > 0`` für eine Zahl (NaN -> NA)."""
    return None if v != v else v > 0


def _r_any(vals):
    """``any(vals)`` mit R's NA-Logik (None = NA)."""
    na = False
    for x in vals:
        if x is True:
            return True
        if x is None:
            na = True
    return None if na else False


def _cmp_vec(x, op, y):
    """``x op y`` elementweise mit Recycling; NA (None) bei NaN."""
    nx, ny = len(x), len(y)
    n = max(nx, ny) if nx and ny else 0
    out = []
    for i in range(n):
        a = float(x[i % nx])
        b = float(y[i % ny])
        out.append(None if (a != a or b != b) else _OPS[op](a, b))
    return out


def _gos_call(f, x, parnames, args, kwargs):
    if parnames is not None:
        x = pd.Series(np.asarray(x, dtype=np.float64), index=parnames)
    return f(x, *args, **kwargs)


def _apply_rows(mat, f):
    """``apply(mat, 1, f)`` für Zeilen mit Skalar- bzw. Vektorergebnis (Liste der Ergebnisse).

    Hat ``mat`` keine Zeilen, ruft R ``f`` einmal mit einem Nullvektor auf
    und verwirft das Ergebnis (``ans[1L][-1L]``).
    """
    if mat.shape[0] == 0:
        f(np.zeros(mat.shape[1]))
        return []
    return [f(mat[i, :].copy()) for i in range(mat.shape[0])]


def _distr_opt(distr_opt, j, key):
    """``distr.opt[[j]]$key`` (``None`` wie ``NULL``)."""
    if distr_opt is None or j >= len(distr_opt):
        raise RError("subscript out of bounds")
    d = distr_opt[j]
    if d is None:
        return None
    v = d.get(key) if isinstance(d, Mapping) else getattr(d, key, None)
    return v


def _as_integer_seed(x):
    """``as.integer(rseed)`` (NA mit Warnung außerhalb des Integer-Bereichs)."""
    v = float(np.asarray(x, dtype=np.float64).ravel()[0])
    if v != v:
        return None
    if v >= 2147483648.0 or v <= -2147483648.0:
        _warn("NAs introduced by coercion to integer range")
        return None
    return int(v)


def _randpars(pars, fixed, fun, ineqfun, ineqLB, ineqUB, LB, UB, distr, distr_opt, n_restarts,
              n_sim, rseed, parnames, args, kwargs):
    """``Rsolnp:::.randpars`` (ohne ``trace`` und ``cluster``)."""
    from . import rng as _rng
    from .truncnorm import rtruncnorm
    N = len(LB)
    nr = n_restarts * n_sim
    rnd = np.full((nr, N), _rn.NA_REAL)
    if fixed is not None:
        for f in fixed:
            rnd[:, f - 1] = pars[f - 1]
    nf = [j for j in range(1, N + 1) if fixed is None or j not in fixed]
    if not nf:
        raise NotImplementedError("gosolnp-Nachbildung: alle Parameter fest (for (i in 1:0) in R)")
    # set.seed(rseed)
    if rseed is None:
        raise RError("supplied seed is not a valid integer")
    _rng.set_seed(rseed)
    for j in nf:
        k = j - 1
        dj = distr[k] if k < len(distr) else None       # distr[j] (NA außerhalb)
        dj = None if dj is None or dj != dj else int(dj)
        if dj == 1:
            col = _rng.runif(nr, LB[k], UB[k])
        elif dj == 2:
            col = rtruncnorm(nr, a=float(LB[k]), b=float(UB[k]),
                             mean=_as_vec(_distr_opt(distr_opt, k, "mean")),
                             sd=_as_vec(_distr_opt(distr_opt, k, "sd")))
        elif dj == 3:
            col = _rng.rnorm(nr, _as_vec(_distr_opt(distr_opt, k, "mean")),
                             _as_vec(_distr_opt(distr_opt, k, "sd")))
        else:
            col = None                                  # switch() ohne Treffer: NULL
        col = np.zeros(0) if col is None else np.asarray(col, dtype=np.float64)
        if col.size == 0 or nr % col.size:
            raise RError("number of items to replace is not a multiple of replacement length")
        rnd[:, k] = np.resize(col, nr)
    if ineqfun is not None:
        ilb = _as_vec(ineqLB)
        iub = _as_vec(ineqUB)
        if ilb.size == 1:
            vals = _apply_rows(rnd, lambda x: _num1(_gos_call(ineqfun, x, parnames, args, kwargs)))
            ineqv = np.concatenate(vals) if vals else np.zeros(0)
            lt = _cmp_vec(ineqv, "<", ilb)
            gt = _cmp_vec(ineqv, ">", iub)
            lbviol = None if None in lt else sum(lt)
            ubviol = None if None in gt else sum(gt)
            cond = _r_or(None if lbviol is None else lbviol > 0, None if ubviol is None else ubviol > 0)
            if cond is None:
                raise RError("missing value where TRUE/FALSE needed")
            if cond:
                vidx = [i for i, t in enumerate(lt) if t is True] + [i for i, t in enumerate(gt) if t is True]
                keep = np.ones(rnd.shape[0], dtype=bool)
                keep[[v % rnd.shape[0] for v in vidx]] = False
                rnd = rnd[keep, :]
        else:
            vals = _apply_rows(rnd, lambda x: _num1(_gos_call(ineqfun, x, parnames, args, kwargs)))
            lbv = []
            ubv = []
            for v in vals:
                a = _r_any(_cmp_vec(v, "<", ilb))
                b = _r_any(_cmp_vec(v, ">", iub))
                lbv.append(None if a is None else int(a))
                ubv.append(None if b is None else int(b))
            c1 = _r_any([None if v is None else v > 0 for v in lbv])
            c2 = _r_any([None if v is None else v > 0 for v in ubv])
            cond = _r_or(c1, c2)
            if cond is None:
                raise RError("missing value where TRUE/FALSE needed")
            if cond:
                vidx = [i for i, v in enumerate(lbv) if v is not None and v > 0] + \
                       [i for i, v in enumerate(ubv) if v is not None and v > 0]
                keep = np.ones(rnd.shape[0], dtype=bool)
                keep[vidx] = False
                rnd = rnd[keep, :]

    def safefun(x):
        """``Rsolnp:::.safefun``."""
        v = _num1(_gos_call(fun, x, parnames, args, kwargs))
        v = float(v[0]) if v.size else math.nan
        if v != v or not math.isfinite(v):
            _warn("\ngosolnp-->warning: %s detected in function call...check your function\n" % _r_str(v))
            v = 1e24
        return v

    evfun = np.asarray(_apply_rows(rnd, safefun), dtype=np.float64)
    ix = np.argsort(evfun, kind="stable")             # sort.int(..., index.return = TRUE)
    zx = evfun[ix]
    out = np.full((n_restarts, N + 1), _rn.NA_REAL)
    for i in range(n_restarts):
        if i < ix.size:
            out[i, :N] = rnd[ix[i], :]
            out[i, N] = zx[i]
    return out


def gosolnp(pars=None, fixed=None, fun=None, *args, eqfun=None, eqB=None, ineqfun=None, ineqLB=None,
            ineqUB=None, LB=None, UB=None, control=None, distr=None, distr_opt=None, n_restarts=1,
            n_sim=20000, cluster=None, rseed=None, **kwargs):
    """``Rsolnp::gosolnp``: ``solnp`` mit zufälligen Startwerten (Rsolnp 1.16).

    Zieht ``n_restarts * n_sim`` Parametervektoren (je Parameter nach
    ``distr``: 1 = gleichverteilt in ``[LB, UB]``, 2 = gestutzte
    Normalverteilung mit ``distr_opt[j]["mean"]``/``["sd"]``
    (:func:`simlev._r.truncnorm.rtruncnorm`), 3 = Normalverteilung), verwirft
    die, die die Ungleichungen verletzen, und startet :func:`solnp` von den
    ``n_restarts`` Vektoren mit dem kleinsten Zielwert.

    Argumente wie in R (``distr.opt`` → ``distr_opt``, ``n.restarts`` →
    ``n_restarts``, ``n.sim`` → ``n_sim``); ``*args``, ``**kwargs`` gehen an
    alle Funktionen (R's ``...``). Wie in R setzt die Funktion den globalen
    Zufallszustand mit ``set.seed(rseed)``; bei ``rseed = None`` ist der
    Startwert ``as.numeric(Sys.time())`` (:func:`simlev._r.base.sys_time`,
    durch ``set.seed`` auf ganze Sekunden abgeschnitten).

    Ergebnis: :class:`GosolnpResult` (Ergebnis von ``solnp`` und
    ``start.pars``, ``rseed``); scheitert ``solnp`` mit einem Fehler, wie in R
    ``values = 1e10``, ``convergence = 0`` und ``pars = NA``.

    Nicht nachgebildet: ``cluster`` (parallele Auswertung),
    ``control$eval.type = 2`` (``.randpars2``) und ``control$trace``.
    """
    from . import base as _base
    with np.errstate(all="ignore"):
        if isinstance(pars, pd.Series) and not isinstance(pars.index, pd.RangeIndex):
            parnames = [str(i) for i in pars.index]
        else:
            parnames = None
        pv = _as_vec(pars) if pars is not None else None
        ctrl = dict(control) if control else {}
        tr = ctrl.get("trace")
        trace = False if tr is None else _rif(float(np.asarray(tr, dtype=np.float64).ravel()[0]))
        et = ctrl.get("eval.type")
        parmethod = 1 if et is None else int(min(abs(float(et)), 2))
        if parmethod == 0:
            parmethod = 1
        ctrl.pop("eval.type", None)
        if rseed is None:
            rseed_v = _base.sys_time()
            seed = rseed_v
        else:
            seed = _as_integer_seed(rseed)
            rseed_v = _rn.NA_REAL if seed is None else seed
        if LB is None:
            raise RError("\ngosolnp-->error: the function requires lower parameter bounds\n")
        if UB is None:
            raise RError("\ngosolnp-->error: the function requires upper parameter bounds\n")
        if fixed is not None and pars is None:
            raise RError("\ngosolnp-->error: you need to provide a pars vector if using the fixed option\n")
        LBv = _as_vec(LB)
        UBv = _as_vec(UB)
        n = len(pv) if pv is not None else LBv.size
        if fixed is not None:
            fx = []
            for f in np.atleast_1d(np.asarray(fixed)).ravel().tolist():
                if f not in fx:
                    fx.append(f)
            if any(not (float(f) == int(f) and 1 <= int(f) <= n) for f in fx):
                raise RError("\ngosolnp-->error: fixed indices out of bounds\n")
            fixed = [int(f) for f in fx]
        dv = np.ones(LBv.size) if distr is None else _as_vec(distr)
        for code in (2, 3):
            for j in [i for i, d in enumerate(dv.tolist()) if d == code]:
                if _distr_opt(distr_opt, j, "mean") is None:
                    raise RError("\ngosolnp-->error: distr.opt[[,%d]] missing mean\n" % (j + 1))
                if _distr_opt(distr_opt, j, "sd") is None:
                    raise RError("\ngosolnp-->error: distr.opt[[,%d]] missing sd\n" % (j + 1))
        if cluster is not None:
            raise NotImplementedError("gosolnp-Nachbildung: cluster (parallele Auswertung) nicht nachgebildet")
        if parmethod != 1:
            raise NotImplementedError("gosolnp-Nachbildung: control$eval.type = 2 (.randpars2) nicht nachgebildet")
        if trace:
            raise NotImplementedError("gosolnp-Nachbildung: control$trace nicht nachgebildet")
        n_restarts = int(n_restarts)
        n_sim = int(n_sim)
        rnd = _randpars(pv, fixed, fun, ineqfun, ineqLB, ineqUB, LBv, UBv, dv.tolist(), distr_opt,
                        n_restarts, n_sim, seed, parnames, args, kwargs)
        rnd = rnd[:, :n]
        solution = []
        for i in range(n_restarts):
            xx = rnd[i, :].copy()
            x_in = pd.Series(xx, index=parnames) if parnames is not None else xx
            try:
                ans = solnp(x_in, fun, *args, eqfun=eqfun, eqB=eqB, ineqfun=ineqfun, ineqLB=ineqLB,
                            ineqUB=ineqUB, LB=LB, UB=UB, control=ctrl, **kwargs)
            except RError:
                ans = GosolnpResult()
                ans["values"] = 1e10
                ans["convergence"] = 0
                ans["pars"] = np.full(xx.size, _rn.NA_REAL)
            solution.append(ans)
        if n_restarts > 1:
            best = []
            for x in solution:
                if x["convergence"] != 0:
                    best.append(None)
                else:
                    vals = np.atleast_1d(np.asarray(x["values"], dtype=np.float64))
                    best.append(float(vals[-1]))
            fin = [b for b in best if b is not None and b == b]
            if not fin:
                raise RError("\ngosolnp-->Could not find a feasible starting point...exiting\n")
            mn = min(fin)
            nb = next(i for i, b in enumerate(best) if b is not None and b == mn)
        else:
            nb = 0
        sol = GosolnpResult()
        for k, v in solution[nb].items():
            sol[k] = v
        sp = rnd[nb, :].copy()
        sol["start.pars"] = pd.Series(sp, index=parnames) if parnames is not None else sp
        sol["rseed"] = rseed_v
        return sol


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), ["solnp", "gosolnp"])
