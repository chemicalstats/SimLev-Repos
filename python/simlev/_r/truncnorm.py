"""Nachbildung von ``truncnorm::rtruncnorm`` (truncnorm 1.0-9).

Herkunft: R-Paket truncnorm 1.0-9 (CRAN, 2023-03-20), ``R/truncnorm.R``
(``rtruncnorm``) und ``src/rtruncnorm.c``; Autoren: Olaf Mersmann [aut,
cre], Heike Trautmann [aut], Detlef Steuer [aut], Björn Bornkamp [aut].
Lizenz: GPL (>= 2), in SimLev unter GPL-3. Nach Python übertragen und
angepasst für SimLev (siehe ``python/COPYRIGHTS.md``); im R-Paket übernommen
als ``.truncnorm_rtruncnorm`` (``r/R/vendor_truncnorm.R``,
``r/src/vendor_truncnorm.c``).

Gestutzte Normalverteilung nach ``src/rtruncnorm.c`` (Bornkamp, Mersmann):
je nach Lage der Schranken Normal-, Halbnormal-, Gleichverteilungs- oder
Exponential-Verwerfungsverfahren (Robert 1995, Schwellen ``t1`` bis
``t4``). Die Zufallszahlen kommen wie in R aus :mod:`simlev._r.rng`
(``unif_rand``, ``norm_rand``, ``exp_rand`` über ``runif``, ``rnorm``,
``rexp`` von nmath), ``dnorm`` aus :mod:`simlev._r.nmath`, ``exp`` und
``pow`` aus der glibc-libm (der C-Code ruft ``pow`` direkt auf).

Nachgebildet ist der R-Wrapper (``stopifnot`` der Längen, ``n`` als Länge
bzw. ``as.integer(n)``, ``NULL`` bei ``n == 0``) und ``do_rtruncnorm``
(Recycling der Argumente auf die größte Länge, ``NA`` bei ``b <= a`` und
bei ``NA``/``NaN``-Schranken).
"""
from __future__ import annotations

import math
import warnings

import numpy as np

from . import rnum as _rn
from . import libm as _libm
from . import nmath as _nm
from . import rng as _rng
from .linalg import RError

__all__ = ["rtruncnorm"]

_T1 = 0.15
_T2 = 2.18
_T3 = 0.725
_T4 = 0.45
_M_1_SQRT_2PI = 0.398942280401432677939946059934
_DBL_MAX = 1.7976931348623157e308


def _cpow2(x):
    """C ``pow(x, 2)`` (glibc, nicht R's ``R_pow``)."""
    try:
        return math.pow(x, 2.0)
    except OverflowError:
        return math.inf
    except ValueError:
        return math.nan


def _div(a, b):
    """``a / b`` mit C-Semantik (Inf/NaN statt ZeroDivisionError)."""
    with np.errstate(all="ignore"):
        return float(np.float64(a) / np.float64(b))


def _dnorm(x):
    return _nm.dnorm4(x, 0.0, 1.0, False)


def _ers_a_inf(a):
    ainv = _div(1.0, a)
    while True:
        x = _rng.rexp1(ainv) + a
        rho = _libm._exp(-0.5 * _cpow2(x - a))
        if not (_rng.runif1(0.0, 1.0) > rho):
            return x


def _ers_a_b(a, b):
    ainv = _div(1.0, a)
    while True:
        x = _rng.rexp1(ainv) + a
        rho = _libm._exp(-0.5 * _cpow2(x - a))
        if not (_rng.runif1(0.0, 1.0) > rho or x > b):
            return x


def _nrs_a_b(a, b):
    x = -_DBL_MAX
    while x < a or x > b:
        x = _rng.rnorm1(0.0, 1.0)
    return x


def _nrs_a_inf(a):
    x = -_DBL_MAX
    while x < a:
        x = _rng.rnorm1(0.0, 1.0)
    return x


def _hnrs_a_b(a, b):
    x = a - 1.0
    while x < a or x > b:
        x = _rng.rnorm1(0.0, 1.0)
        x = abs(x)
    return x


def _urs_a_b(a, b):
    phi_a = _dnorm(a)
    ub = _M_1_SQRT_2PI if (a < 0 and b > 0) else phi_a
    while True:
        x = _rng.runif1(a, b)
        if not (_rng.runif1(0.0, 1.0) * ub > _nm.dnorm4(x, 0.0, 1.0, False)):
            return x


def _r_lefttruncnorm(a, mean, sd):
    alpha = _div(a - mean, sd)
    if alpha < _T4:
        return mean + sd * _nrs_a_inf(alpha)
    return mean + sd * _ers_a_inf(alpha)


def _r_righttruncnorm(b, mean, sd):
    beta = _div(b - mean, sd)
    return mean - sd * _r_lefttruncnorm(-beta, 0.0, 1.0)


def _r_truncnorm(a, b, mean, sd):
    alpha = _div(a - mean, sd)
    beta = _div(b - mean, sd)
    phi_a = _dnorm(alpha)
    phi_b = _dnorm(beta)
    if beta <= alpha:
        return _rn.NA_REAL
    if alpha <= 0 and 0 <= beta:                       # 2
        if phi_a <= _T1 or phi_b <= _T1:               # 2 (a)
            return mean + sd * _nrs_a_b(alpha, beta)
        return mean + sd * _urs_a_b(alpha, beta)       # 2 (b)
    if alpha > 0:                                      # 3
        if _div(phi_a, phi_b) <= _T2:                       # 3 (a)
            return mean + sd * _urs_a_b(alpha, beta)
        if alpha < _T3:                                # 3 (b)
            return mean + sd * _hnrs_a_b(alpha, beta)
        return mean + sd * _ers_a_b(alpha, beta)       # 3 (c)
    if _div(phi_b, phi_a) <= _T2:                           # 3s (a)
        return mean - sd * _urs_a_b(-beta, -alpha)
    if beta > -_T3:                                    # 3s (b)
        return mean - sd * _hnrs_a_b(-beta, -alpha)
    return mean - sd * _ers_a_b(-beta, -alpha)         # 3s (c)


def _num(x):
    return np.atleast_1d(np.asarray(x, dtype=np.float64)).ravel()


def rtruncnorm(n, a=-math.inf, b=math.inf, mean=0.0, sd=1.0):
    """``truncnorm::rtruncnorm(n, a, b, mean, sd)``: Zufallszahlen der gestutzten Normalverteilung.

    Argumente:
        n: Anzahl (eine Zahl; ein Vektor der Länge > 1 zählt wie in R
            über seine Länge).
        a, b: untere und obere Schranke (``-inf``/``inf`` = ungestutzt).
        mean, sd: Mittelwert und Standardabweichung der zugrunde liegenden
            Normalverteilung.

    Die Argumente werden wie in R auf die größte Länge recycelt. Ergebnis:
    ``numpy.ndarray`` bzw. ``None`` bei ``n == 0``; ``NA`` für ``b <= a``.
    """
    av, bv, mv, sv = _num(a), _num(b), _num(mean), _num(sd)
    for v, nm in ((av, "a"), (bv, "b"), (mv, "mean"), (sv, "sd")):
        if v.size == 0:
            raise RError("length(%s) > 0 is not TRUE" % nm)
    nv = np.atleast_1d(np.asarray(n, dtype=object)).ravel() if not np.isscalar(n) else None
    if nv is not None and nv.size > 1:
        nn_ = nv.size
    else:
        x = n if nv is None else nv[0]
        if isinstance(x, (bool, np.bool_)) or not isinstance(x, (int, float, np.integer, np.floating)):
            raise RError("non-numeric argument n.")
        xf = float(x)
        if xf != xf:                                    # if (n == 0) mit NA
            raise RError("missing value where TRUE/FALSE needed")
        if xf == 0:
            return None
        if xf >= 2147483648.0 or xf <= -2147483648.0:   # as.integer(n) = NA
            warnings.warn("NAs introduced by coercion to integer range", UserWarning, stacklevel=2)
            raise RError("n is NA - aborting.")
        nn_ = int(xf)                                   # as.integer(n)
    nn = max(nn_, max(max(av.size, bv.size), max(mv.size, sv.size)))
    out = np.empty(max(nn, 0))
    _rng._get_state()                                   # GetRNGstate()
    for i in range(nn):
        ca = float(av[i % av.size])
        cb = float(bv[i % bv.size])
        cm = float(mv[i % mv.size])
        cs = float(sv[i % sv.size])
        fa = math.isfinite(ca)
        fb = math.isfinite(cb)
        if fa and fb:
            out[i] = _r_truncnorm(ca, cb, cm, cs)
        elif ca == -math.inf and fb:
            out[i] = _r_righttruncnorm(cb, cm, cs)
        elif fa and cb == math.inf:
            out[i] = _r_lefttruncnorm(ca, cm, cs)
        elif ca == -math.inf and cb == math.inf:
            out[i] = _rng.rnorm1(cm, cs)
        else:
            out[i] = _rn.NA_REAL
    _rng._S.exists = True                               # PutRNGstate()
    return out


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), ["rtruncnorm"])
