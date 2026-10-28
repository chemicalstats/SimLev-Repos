"""Nachbildung von evd 2.3-7.1 (Teil: ``fpot``), im R-Paket übernommen als ``.evd_fpot``.

Herkunft: R-Paket evd 2.3-7.1 (CRAN, 2024-09-21), ``R/uvfit.R`` (``fpot``,
``fpot.norm``) und ``src/pot.c`` (``nlgpd``); Autoren: Alec Stephenson.
Function fbvpot by Chris Ferro. Lizenz: GPL-3. Nach Python übertragen und
angepasst für SimLev (siehe ``python/COPYRIGHTS.md``).

Nachgebildet ist ``fpot(x, threshold, model = "gpd", ...)`` mit
``fpot.norm`` (``cmax = FALSE``, ``mper = NULL``): Startwerte, die negative
Log-Likelihood ``nlgpd`` aus ``src/pot.c`` (Strafwert ``1e6``,
Exponential-Grenzfall für ``|shape| <= DBL_EPSILON^0.3``), die Prüfung von
``.C`` auf nicht endliche Argumente, der ``optim``-Aufruf mit
``hessian = TRUE``, feste Parameter (``scale``/``shape``), die
Standardfehler über ``qr``/``solve.qr`` und alle Meldungen von evd.
Nicht nachgebildet sind ``model = "pp"``, ``cmax = TRUE`` (Cluster) und
``mper`` (Quantil-Parametrisierung); sie werfen einen Fehler.

SimLev nutzt ``fpot`` in ``.fit_tail`` (``bootstrap``, Verfahren ``"evt"``)
bei mindestens 30 Überschreitungen; R nutzt dafür die übernommene Fassung
``.evd_fpot`` (``r/R/vendor_evd.R``, ``r/src/vendor_evd.c``), evd selbst ist
nicht mehr nötig.
"""
from __future__ import annotations

import math
from collections.abc import Mapping

import numpy as np
import pandas as pd

from . import env as _env
from . import libm as _libm
from . import linalg as _la
from . import stats as _stats
from .linalg import RError
from .rlist import RList
from .rnum import r_mean

__all__ = ["fpot", "nlgpd", "Pot"]

_DBL_EPS = 2.220446049250313e-16
# eps = R_pow(DBL_EPSILON, 0.3) in nlgpd (pot.c)
_EPS = _libm.pow(_DBL_EPS, 0.3)


class Pot(RList):
    """Ergebnis von ``fpot`` (R-Klasse ``c("pot", "uvevd", "evd")``)."""
    r_class = ("pot", "uvevd", "evd")


def _c_check(args):
    """``.C`` mit ``NAOK = FALSE``: nicht endliche double-Argumente sind ein Fehler."""
    for k, a in enumerate(args, start=1):
        for v in (a if isinstance(a, (list, tuple)) else (a,)):
            if not math.isfinite(v):
                raise RError("NA/NaN/Inf in foreign function call (arg %d)" % k)


def nlgpd(exceed, loc, scale, shape):
    """Negative Log-Likelihood der GPD wie ``nlgpd`` in evd ``src/pot.c``.

    Liefert ``1e6`` für ``scale <= 0`` oder einen Punkt außerhalb des
    Trägers; für ``|shape| <= DBL_EPSILON^0.3`` die Exponentialverteilung.
    Summiert wie in C sequenziell in ``double``.

    Argumente: ``exceed`` Überschreitungen (Liste von float), ``loc``
    Schwelle, ``scale``, ``shape``.
    """
    scale = float(scale)
    shape = float(shape)
    loc = float(loc)
    _c_check([exceed, len(exceed) * 0.0, loc, scale, shape])
    ext = _env.ext()
    if ext is not None:
        # gemeinsamer Kern (r/src/vendor_evd_impl.h, Etappe 7.3a); data wird ueberschrieben
        return ext.evd_nlgpd(np.array(exceed, dtype=np.float64), loc, scale, shape)
    if scale <= 0:
        return 1e6
    lsc = _libm.log(1 / scale)
    dvec = []
    if math.fabs(shape) <= _EPS:
        for v in exceed:
            d = (v - loc) / scale
            dvec.append(lsc - d)
    else:
        a = 1 / shape + 1
        for v in exceed:
            d = (v - loc) / scale
            d = 1 + shape * d
            if d <= 0:
                return 1e6
            dvec.append(lsc - a * _libm.log(d))
    dns = 0.0
    for v in dvec:
        dns = dns - v
    return dns


def _is_numeric_vec(x):
    if x is None:
        return None
    if isinstance(x, pd.Series):
        a = x.to_numpy()
    else:
        a = np.asarray(x)
    if a.dtype.kind not in "iuf":
        return None
    return np.asarray(a, dtype=np.float64).ravel()


def fpot(x, threshold, model="gpd", start=None, npp=None, cmax=False, r=1, ulow=-math.inf,
         rlow=1, mper=None, std_err=True, corr=False, method="BFGS", warn_inf=True, **kwargs):
    """Peaks-over-Threshold-Anpassung der verallgemeinerten Pareto-Verteilung (evd ``fpot``).

    Maximum-Likelihood-Schätzung von ``scale`` und ``shape`` der GPD für die
    Werte von ``x`` über ``threshold`` (``optim`` mit ``method``,
    ``hessian = TRUE``), bitgleich zu evd 2.3-7.1.

    Argumente:
        x: numerischer Vektor (NA-Werte werden übergangen).
        threshold: Schwelle (Zahl).
        model: nur ``"gpd"`` ist nachgebildet.
        start: dict mit Startwerten (``scale``, ``shape``); Standard: Mittel
            der Überschreitungen minus Schwelle und ``0``.
        npp: Beobachtungen je Periode (nur im Ergebnis), Standard ``len(x)``.
        cmax, r, ulow, rlow, mper: nur die Voreinstellungen sind nachgebildet.
        std_err: Standardfehler und Kovarianzmatrix berechnen.
        corr: Korrelationsmatrix (mit ``std_err``).
        method: Verfahren für ``optim``.
        warn_inf: warnen, wenn die negative Log-Likelihood am Start unendlich
            (``1e6``) ist.
        **kwargs: feste Parameter ``scale``/``shape`` sowie ``control``,
            ``lower``, ``upper`` für ``optim`` (wie R's ``...``).

    Ergebnis: :class:`Pot` mit den Elementen von R (``estimate``, ``std.err``,
    ``fixed``, ``param``, ``deviance``, ``corr``, ``var.cov``,
    ``convergence``, ``counts``, ``message``, ``threshold``, …, ``scale``;
    ohne ``call``).
    """
    if model not in ("gpd", "pp"):
        raise RError("'arg' should be one of “gpd”, “pp”")
    xv = _is_numeric_vec(x)
    if xv is None or xv.size == 0:
        raise RError("`x' must be a non-empty numeric vector")
    th = _is_numeric_vec(threshold)
    if th is None or th.size != 1:
        raise RError("`threshold' must be a numeric value")
    threshold = float(th[0])
    if mper is not None:
        if model == "pp":
            raise RError("`mper' cannot be specified in point process models")
        raise RError("evd-Nachbildung: fpot mit mper (fpot.quantile) nicht nachgebildet")
    if model == "pp":
        raise RError('evd-Nachbildung: fpot mit model = "pp" nicht nachgebildet')
    if cmax:
        raise RError("evd-Nachbildung: fpot mit cmax = TRUE (clusters) nicht nachgebildet")
    param = ["scale", "shape"]
    opt_kw = {}
    dots = []                                   # list(...) in Reihenfolge
    for k, v in kwargs.items():
        if k in ("control", "lower", "upper"):
            opt_kw[k] = v
        elif k in param:
            dots.append((k, float(np.asarray(v, dtype=np.float64).ravel()[0])))
        else:
            raise TypeError("fpot: unbekanntes Argument %r" % k)
    dot_names = [k for k, _ in dots]
    nn = xv.size
    if npp is None:
        npp = nn
    # fpot.norm, cmax = FALSE
    if math.isnan(threshold):
        exceed = [threshold] * int(np.count_nonzero(~np.isnan(xv)))   # x[NA] -> NA
    else:
        exceed = xv[(xv > threshold) & ~np.isnan(xv)].tolist()
    nhigh = nat = len(exceed)
    if not nhigh:
        raise RError("no data above threshold")
    pat = nat / nn
    if start is None:
        st = [("scale", r_mean(np.array(exceed, dtype=np.float64)) - threshold), ("shape", 0.0)]
        st = [(k, v) for k, v in st if k not in dot_names]
    else:
        if not isinstance(start, Mapping):
            raise RError("`start' must be a named list")
        st = [(str(k), float(np.asarray(v, dtype=np.float64).ravel()[0])) for k, v in start.items()]
    if not st:
        raise RError("there are no parameters left to maximize over")
    nm = [k for k, _ in st]
    if any(k not in param for k in nm):
        raise RError("`start' specifies unknown arguments")
    fixed = [(k, v) for k, v in dots if k in param]
    if any(p not in nm + [k for k, _ in fixed] for p in param):
        raise RError("unspecified parameters")
    for k, _ in fixed:
        if k in nm:
            raise RError('formal argument "%s" matched by multiple actual arguments' % k)
    fixed_d = dict(fixed)

    def nllh(p):
        pv = np.asarray(p, dtype=np.float64).ravel()
        a = dict(zip(nm, pv.tolist()))
        a.update(fixed_d)
        return nlgpd(exceed, threshold, a["scale"], a["shape"])

    p0 = pd.Series([v for _, v in st], index=nm, dtype=np.float64)
    if warn_inf and nllh(p0) == 1e6:
        _stats._warn("negative log-likelihood is infinite at starting values")
    opt = _stats.optim(p0, nllh, method=method, hessian=True, **opt_kw)
    par = opt["par"]
    if not isinstance(par, pd.Series):
        par = pd.Series(np.atleast_1d(np.asarray(par, dtype=np.float64)), index=nm)
    conv = opt["convergence"]
    if conv != 0:
        _stats._warn("optimization may not have succeeded")
        if conv == 1:
            conv = "iteration limit reached"
    else:
        conv = "successful"
    if std_err:
        tol = _libm.pow(_DBL_EPS, 0.5)          # .Machine$double.eps^0.5
        q = _la.qr(opt["hessian"], tol=tol)
        if q["rank"] != np.shape(q["qr"])[1]:
            raise RError("observed information matrix is singular; use std.err = FALSE")
        var_cov = _la.solve_qr(q)
        se = np.asarray(_la.diag(var_cov), dtype=np.float64).ravel()
        le = se <= 0
        if le.any():
            raise RError("observed information matrix is singular; use std.err = FALSE")
        if np.isnan(se).any():
            raise RError("missing value where TRUE/FALSE needed")
        se = pd.Series(np.sqrt(se), index=nm)
        if corr:
            mat = _la.diag(1 / se.to_numpy(), nrow=se.size)
            cm = _la.matprod(_la.matprod(mat, var_cov), mat)
            cm = np.array(np.asarray(cm, dtype=np.float64), copy=True)
            cm[np.arange(se.size), np.arange(se.size)] = 1.0
            corr_v = pd.DataFrame(cm, index=nm, columns=nm)
        else:
            corr_v = None
    else:
        se = var_cov = corr_v = None
    fixed_v = pd.Series([v for _, v in fixed], index=[k for k, _ in fixed], dtype=np.float64) \
        if fixed else None
    param_v = pd.concat([par, fixed_v]) if fixed_v is not None else par.copy()
    scale = pd.Series([param_v["scale"]], index=["scale"])
    res = Pot()
    res["estimate"] = par
    res["std.err"] = se
    res["fixed"] = fixed_v
    res["param"] = param_v
    res["deviance"] = 2 * opt["value"]
    res["corr"] = corr_v
    res["var.cov"] = var_cov
    res["convergence"] = conv
    res["counts"] = opt["counts"]
    res["message"] = opt["message"]
    res["threshold"] = threshold
    res["cmax"] = False
    res["r"] = None
    res["ulow"] = ulow
    res["rlow"] = rlow
    res["npp"] = npp
    res["nhigh"] = nhigh
    res["nat"] = nat
    res["pat"] = pat
    res["extind"] = None
    res["data"] = x
    res["exceedances"] = np.array(exceed, dtype=np.float64)
    res["mper"] = None
    res["scale"] = scale
    return res


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), ["fpot", "nlgpd"])
