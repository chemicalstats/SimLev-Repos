"""Hüllen der Optimierer der C-Bibliothek slc (SimLev core, Etappe 9.3): :func:`optim` und
Prüfhilfen.

Gegenstück zu ``r/R/slc_opt.R`` (``.sl_optim``) und ``julia/src/slib_opt.jl`` (``SLib.optim``).
Die Rechnung steht in ``src/core/slc_opt.c`` (Kopie von ``core/``), die Hülle in
``src/_ext_slc_opt.c`` (Modul ``simlev._ext``). Rückfrage an den Host (Entwurf B.8): Python holt
die nächste Anfrage, rechnet die Zielfunktion selbst und gibt die Antwort; der Kern ruft nie
nach Python zurück, Fehler der Zielfunktion sind gewöhnliche Python-Ausnahmen.

Seit Etappe 9.6b rufen die Ports :func:`optim` an denselben Stellen wie R. :func:`optim` nimmt die
Argumente und Steuerwerte von R's ``optim`` an, soweit SimLev sie nutzt, und gibt ein ``dict``
mit ``par``, ``value``, ``counts`` (``{"function": …, "gradient": …}``, bei Nelder-Mead
``gradient = None``), ``convergence``, ``message``, ``iterations``, ``evaluations`` (und
``trace``) zurück.
"""
from __future__ import annotations

import math

import numpy as np

from . import _ext

__all__ = ["optim", "opt_testfn", "minimize_test", "numgrad_test"]

_METHODS = {"Nelder-Mead": 3, "BFGS": 1, "L-BFGS-B": 2, "PBFGS": 2, "NM": 3}
_KNOWN = ("maxit", "maxfev", "reltol", "factr", "pgtol", "gtol", "xtol", "fnscale", "parscale", "trace")
_EPS = 2.220446049250313e-16


def _method(method):
    if method not in _METHODS:
        raise ValueError("optim: unbekanntes Verfahren %r (erlaubt: %s)" % (method, ", ".join(_METHODS)))
    return _METHODS[method]


def _control(control, m, n):
    """Steuerwerte wie in R (``.sl_opt_control``): Nelder-Mead ``maxit`` = Funktionsauswertungen,
    L-BFGS-B ``factr`` (reltol = factr * eps, Standard 1e7) und ``pgtol`` (= gtol)."""
    control = dict(control or {})
    bad = [k for k in control if k not in _KNOWN]
    if bad:
        raise ValueError("optim: unbekannte Steuerwerte %s" % ", ".join("'%s'" % k for k in bad))

    def num1(k, default):
        v = control.get(k)
        if v is None:
            return default
        if isinstance(v, bool) or not isinstance(v, (int, float, np.integer, np.floating)) or math.isnan(float(v)):
            raise ValueError("optim: Steuerwert %s muss eine Zahl sein" % k)
        return float(v)

    if control.get("factr") is not None and control.get("reltol") is not None:
        raise ValueError("optim: factr und reltol nicht zugleich angeben")
    if m == 3:
        maxfev = num1("maxfev", num1("maxit", 500.0))
        maxit = 0.0
        reltol = num1("reltol", math.sqrt(_EPS))
    else:
        maxit = num1("maxit", 100.0)
        maxfev = num1("maxfev", 0.0)
        if control.get("factr") is not None:
            reltol = num1("factr", 1e7) * _EPS
        else:
            reltol = num1("reltol", 1e7 * _EPS if m == 2 else math.sqrt(_EPS))
    gtol = num1("gtol", num1("pgtol", 1e-8))
    ctrl = (maxit, maxfev, reltol, gtol, num1("xtol", _EPS), num1("fnscale", 1.0))
    ps = control.get("parscale")
    if ps is not None:
        ps = np.asarray(ps, dtype=np.float64).ravel()
        if ps.size not in (1, n):
            raise ValueError("optim: Steuerwert parscale passt nicht zu par")
        ps = np.ascontiguousarray(np.resize(ps, n))
    return ctrl, ps, bool(control.get("trace", False))


def _bounds(b, n):
    return np.ascontiguousarray(np.resize(np.asarray(b, dtype=np.float64).ravel(), n))


def _scalar(v):
    if v is None:
        return math.nan
    a = np.asarray(v)
    if a.size != 1 or not (np.issubdtype(a.dtype, np.number) or a.dtype == np.bool_):
        raise ValueError("optim: die Zielfunktion muss eine Zahl liefern (erhalten: Länge %d)" % a.size)
    return float(a.reshape(()))


def optim(par, fn, gr=None, method="Nelder-Mead", lower=-math.inf, upper=math.inf, control=None, args=()):
    """Minimieren mit den Optimierern der C-Bibliothek slc (wie R's ``optim`` für "Nelder-Mead",
    "BFGS" und "L-BFGS-B"; letzteres ist hier der projizierte BFGS, auch "PBFGS")."""
    m = _method(method)
    x0 = np.ascontiguousarray(np.asarray(par, dtype=np.float64).ravel())
    n = x0.size
    if n == 0:
        raise ValueError("optim: par muss ein nichtleerer Zahlenvektor sein")
    ctrl, ps, trace = _control(control, m, n)
    lo = hi = None
    if m == 2:
        lo, hi = _bounds(lower, n), _bounds(upper, n)
    elif np.isfinite(np.asarray(lower, dtype=np.float64)).any() or np.isfinite(np.asarray(upper, dtype=np.float64)).any():
        raise ValueError("optim: Schranken nur mit L-BFGS-B bzw. PBFGS (nicht %s)" % method)
    ws = np.zeros(_ext.slc_opt_wsize(m, n), dtype=np.float64)
    _ext.slc_opt_init(ws, m, x0, lo, hi, ctrl, ps, gr is not None)
    x = np.empty(n, dtype=np.float64)
    tx, tf, tk = [], [], []
    while True:
        need = _ext.slc_opt_ask(ws, x)
        if need == 0:
            break
        xe = x.copy()
        if need == 1:
            v = _scalar(fn(xe, *args))
            if trace:
                tx.append(xe); tf.append(v); tk.append(1)
            _ext.slc_opt_tell(ws, v, None)
        else:
            g = np.ascontiguousarray(np.asarray(gr(xe, *args), dtype=np.float64).ravel())
            if g.size != n:
                raise ValueError("optim: der Gradient muss %d Zahlen liefern (erhalten: Länge %d)" % (n, g.size))
            if trace:
                tx.append(xe); tf.append(math.nan); tk.append(2)
            _ext.slc_opt_tell(ws, 0.0, g)
    xr = np.empty(n, dtype=np.float64)
    value, code, iters, nfev, ngev, ntot, msg = _ext.slc_opt_result(ws, xr)
    out = {"par": xr, "value": value,
           "counts": {"function": nfev, "gradient": None if m == 3 else ngev},
           "convergence": code, "message": msg, "iterations": iters, "evaluations": ntot}
    if trace:
        out["trace"] = {"x": np.array(tx, dtype=np.float64).reshape(len(tx), n), "f": np.array(tf, dtype=np.float64),
                        "need": np.array(tk, dtype=np.int32)}
    return out


# ── Prüfhilfen (Plausibilität, Gleichlauf): Prüffunktionen in C ──────────────

def opt_testfn(id, x, grad=False):  # noqa: A002 (Name wie in R)
    """Wert (``grad=False``) bzw. ``[Wert, Gradient]`` der Prüffunktion ``id`` an ``x``."""
    x = np.ascontiguousarray(np.asarray(x, dtype=np.float64).ravel())
    if not grad:
        return _ext.slc_opt_testfn(int(id), x, None)
    g = np.empty(x.size, dtype=np.float64)
    f = _ext.slc_opt_testfn(int(id), x, g)
    return [f, g]


def minimize_test(id, par, method="Nelder-Mead", lower=-math.inf, upper=math.inf, control=None, grad=False):  # noqa: A002
    """Direkter C-Weg (``sl_minimize``) mit der Prüffunktion ``id``; Steuerwerte wie :func:`optim`."""
    m = _method(method)
    x = np.array(np.asarray(par, dtype=np.float64).ravel(), dtype=np.float64)
    n = x.size
    ctrl, ps, _ = _control(control, m, n)
    lo = hi = None
    if m == 2:
        lo, hi = _bounds(lower, n), _bounds(upper, n)
    value, code, iters, nfev, ntot = _ext.slc_opt_minimize_test(int(id), m, x, lo, hi, ctrl, ps, bool(grad))
    return {"par": x, "value": value, "convergence": code, "iterations": iters, "nfev": nfev, "evaluations": ntot}


def numgrad_test(id, x, lower=None, upper=None):  # noqa: A002
    """Numerischer Gradient (B.9) der Prüffunktion ``id`` an ``x`` (Schranken wahlweise)."""
    x = np.ascontiguousarray(np.asarray(x, dtype=np.float64).ravel())
    n = x.size
    g = np.empty(n, dtype=np.float64)
    _ext.slc_numgrad_test(int(id), x, None if lower is None else _bounds(lower, n),
                          None if upper is None else _bounds(upper, n), g)
    return g
