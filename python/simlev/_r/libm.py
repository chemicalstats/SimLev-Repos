# Herkunft:           nachgebildet nach R 4.3.3, Randregeln von src/main/arithmetic.c um die
#                     libm-Funktionen
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang.
"""Elementweise libm-Funktionen.

numpy nutzt auf Rechnern mit AVX-512 eigene SIMD-Implementierungen für
``exp``, ``log``, ``log1p``, ``expm1``, ``power``, ``tanh`` usw., die in den
letzten Bits von glibc-libm abweichen. R ruft libm direkt auf. Die
Funktionen hier wenden ``math.*`` (= libm) elementweise an und geben bei
Skalaren Skalare, sonst ``float64``-Arrays gleicher Form zurück. Seit 1.5.2
rechnen ``exp``, ``log``, ``log1p``, ``expm1``, ``log2``, ``log10`` und
``pow`` Felder in einer C-Schleife mit denselben libm-Funktionen
(``sl_r_math1``, ``sl_r_pow_rec`` in ``core/slc_rbase.cpp``); Skalare weiter
über ``math.*``.

Seit 1.6.4 (C-094, Entscheidung 80) warnen die Funktionen wie R's ``math1``/``math2`` einmal je Aufruf mit
"NaNs produced", wenn ein Ergebnis NaN ist, ohne dass die Eingabe (bzw. bei ``log(x, base)`` keine der beiden) NaN war;
``pow`` warnt wie R's Arithmetik bei Längen, die kein Vielfaches voneinander sind, und wie R's ``R_pow`` je Element
``(-Inf)^y`` mit endlichem ``y > 2^64`` mit "probable complete loss of accuracy in modulus" (T4-R2). Für die elementweise Anwendung ohne
Warnung (RExpr warnt selbst je Ausdruck) gibt es die Skalarkerne in ``_KERN`` und ``_logb``.
"""
from __future__ import annotations

import math
import warnings

import numpy as np

from .. import _ext
from .rnum import NA_REAL, _bits
from .rnum import r_pow as _r_pow

__all__ = ["exp", "log", "log1p", "expm1", "log2", "log10", "pow", "sin", "cos", "tan", "tanh", "atan", "apply1"]


def _nan_wrap(f):
    def g(x):
        try:
            return f(x)
        except ValueError:
            if x != x:
                return x
            return math.nan
        except OverflowError:
            return math.inf
    return g


def _nan_warn(out, x, base=None):
    """R ``math1``/``math2``: Warnung "NaNs produced", wenn ein Ergebnis NaN ist und die Eingabe nicht (seit 1.6.4,
    C-094); Ergebnis unverändert."""
    if np.isscalar(out) or (isinstance(out, np.ndarray) and out.ndim == 0):
        bad = out != out and not (x != x) and (base is None or base == base)
    else:
        m = np.isnan(out)
        if m.any():
            m &= ~np.isnan(np.asarray(x, dtype=np.float64).reshape(out.shape))
            if base is not None:
                m &= not (base != base)
        bad = bool(m.any())
    if bad:
        warnings.warn("NaNs produced", UserWarning, stacklevel=3)
    return out


def _is_text(x):
    """Text (str, Bytes oder ein Feld bzw. eine Folge mit Text): R-Funktionen für Zahlen lehnen ihn ab (seit 1.6.4,
    C-060; bis 1.6.3 wandelte numpy Ziffern-Text still in Zahlen)."""
    if isinstance(x, (str, bytes)):
        return True
    if isinstance(x, np.ndarray):
        return x.dtype.kind in "USO" and any(isinstance(t, (str, bytes)) for t in x.ravel().tolist())
    if isinstance(x, (list, tuple)):
        return any(isinstance(t, (str, bytes)) for t in x)
    return False


def _math_text(x):
    if _is_text(x):
        from .linalg import RError
        raise RError("non-numeric argument to mathematical function")


def apply1(f, x):
    """``f`` (Skalarfunktion) elementweise auf ``x`` anwenden."""
    _math_text(x)
    if np.isscalar(x) or (isinstance(x, np.ndarray) and x.ndim == 0):
        return f(float(x))
    a = np.asarray(x, dtype=np.float64)
    flat = a.ravel()
    out = np.fromiter(map(f, flat.tolist()), dtype=np.float64, count=flat.size)
    return out.reshape(a.shape)


def _log(x):
    if x > 0:
        return math.log(x)
    if x == 0:
        return -math.inf
    if x != x:
        return x
    return math.nan


def _log1p(x):
    if x > -1:
        return math.log1p(x)
    if x == -1:
        return -math.inf
    if x != x:
        return x
    return math.nan


def _is_na(x):
    return x != x and (_bits(x) & 0xFFFFFFFF) == 1954


def _nan_lb(x):
    """NaN-Regel von R's math2/logbase für log2/log10 (seit 1.6.4, C-068): NA ergibt NA_real_, jedes andere NaN R_NaN."""
    return NA_REAL if _is_na(x) else math.nan


def _log2(x):
    if x > 0:
        return math.log2(x)
    if x == 0:
        return -math.inf
    return _nan_lb(x)   # x < 0: R_NaN (math.nan = 0x7FF8…); bis 1.6.3 NaN unverändert


def _log10(x):
    if x > 0:
        return math.log10(x)
    if x == 0:
        return -math.inf
    return _nan_lb(x)


def _exp(x):
    if x != x:
        return x   # seit 1.6.4 wie R math1 (C-068): NaN in x bleibt x (auch NA 0x7FF0…07A2), wie der Kern
    try:
        return math.exp(x)
    except OverflowError:
        return math.inf


def _expm1(x):
    if x != x:
        return x   # wie _exp (seit 1.6.4, C-068)
    try:
        return math.expm1(x)
    except OverflowError:
        return math.inf


def _math1(kind, slow, x):
    """``slow`` (Skalarfunktion, R-Regeln) auf Skalare; Felder mit der C-Schleife ``sl_r_math1`` (gleiche libm)."""
    _math_text(x)
    if np.isscalar(x) or (isinstance(x, np.ndarray) and x.ndim == 0):
        return slow(float(x))
    a = np.ascontiguousarray(x, dtype=np.float64)
    out = np.empty(a.shape)
    _ext.slc_r_math1(kind, a.reshape(-1), out.reshape(-1))
    return out


def exp(x):
    return _nan_warn(_math1(0, _exp, x), x)


def log(x, base=None):
    if base is None:
        return _nan_warn(_math1(1, _log, x), x)
    # R: log(x, base) = R_log(x) / R_log(base) (arithmetic.c logbase)
    if base == 10:
        return log10(x)
    if base == 2:
        return log2(x)
    lb = _log(float(base))
    fb = float(base)
    # seit 1.6.4 (Befund C-029) Division in C-Semantik wie R und Julia: Basis 1 (log 1 = 0) ergibt ±Inf bzw. NaN statt
    # ZeroDivisionError; NaN in x oder base nach R's math2 (seit 1.6.4, C-068: NA ergibt NA_real_, sonst R_NaN)
    def one(v):
        if v != v or fb != fb:
            return NA_REAL if (_is_na(v) or _is_na(fb)) else math.nan
        return _cdiv(_log(v), lb)
    return _nan_warn(apply1(one, x), x, fb)


def _logb(x, b):
    """Skalar ``log(x, b)`` wie :func:`log`, ohne Warnung (für RExpr)."""
    if b == 10:
        return _log10(x)
    if b == 2:
        return _log2(x)
    if x != x or b != b:   # math2 (seit 1.6.4, C-068)
        return NA_REAL if (_is_na(x) or _is_na(float(b))) else math.nan
    return _cdiv(_log(x), _log(float(b)))


def _cdiv(a, b):
    """``a / b`` mit IEEE-Regeln (Division durch 0 ergibt ±Inf bzw. NaN, ohne Ausnahme)."""
    if b == 0.0:
        if a != a or a == 0.0:
            return float("nan")
        return math.copysign(math.inf, a) * math.copysign(1.0, b)
    return a / b


def log1p(x):
    return _nan_warn(_math1(2, _log1p, x), x)


def expm1(x):
    return _nan_warn(_math1(3, _expm1, x), x)


def log2(x):
    return _nan_warn(_math1(4, _log2, x), x)


def log10(x):
    return _nan_warn(_math1(5, _log10, x), x)


def pow(x, y):  # noqa: A001 - Name wie in C
    """``x ^ y`` mit R-Semantik (``x*x`` für ``y == 2``, sonst libm ``pow``); Felder mit Recycling in C."""
    if _is_text(x) or _is_text(y):   # seit 1.6.4 wie R (C-060)
        from .linalg import RError
        raise RError("non-numeric argument to binary operator")
    if np.isscalar(x) and np.isscalar(y):
        fx, fy = float(x), float(y)
        r = _r_pow(fx, fy)
        if fx == -math.inf and _POW_LOSS < fy < math.inf:
            _pow_loss_warn(1)
        return r
    a = np.asarray(x, dtype=np.float64)
    b = np.asarray(y, dtype=np.float64)
    # seit 1.6.4 wie R (C-045): Matrizen spaltenweise (bis 1.6.3 zeilenweise abgeflacht), ein längerer Vektor als die
    # Matrix ist ein Fehler, zwei Felder brauchen gleiche Maße
    if a.ndim > 1 and b.ndim > 1 and a.shape != b.shape:
        from .linalg import RError
        raise RError("non-conformable arrays")
    for arr, oth in ((a, b), (b, a)):
        if arr.ndim > 1 and oth.ndim <= 1 and oth.size > arr.size and arr.size > 0:
            from .linalg import RError
            raise RError("dims [product %d] do not match the length of object [%d]" % (arr.size, oth.size))
    if a.size == 0 or b.size == 0:
        return np.empty(0)
    shape = a.shape if (a.ndim > 1 or (a.size >= b.size and b.ndim <= 1)) else b.shape
    if max(a.size, b.size) % min(a.size, b.size):   # seit 1.6.4 wie R's Arithmetik (C-094)
        warnings.warn("longer object length is not a multiple of shorter object length", UserWarning, stacklevel=2)
    out = np.empty(max(a.size, b.size))
    nw = _ext.slc_r_pow_rec(np.ascontiguousarray(a.ravel(order="F")), np.ascontiguousarray(b.ravel(order="F")), out)
    if nw:
        _pow_loss_warn(nw)
    return out.reshape(shape, order="F")


# R_pow ruft für (-Inf)^y mit ganzem y >= 0 myfmod(y, 2); das warnt bei |y / 2| * LDBL_EPSILON > 1, also y > 2^64
# (seit 1.6.4, T4-R2; der Kern sl_r_pow_rec zählt die Fälle, die Werte sind unverändert)
_POW_LOSS = 18446744073709551616.0


def _pow_loss_warn(n):
    for _ in range(n):
        warnings.warn("probable complete loss of accuracy in modulus", UserWarning, stacklevel=3)


_sin, _cos, _tan = _nan_wrap(math.sin), _nan_wrap(math.cos), _nan_wrap(math.tan)


def sin(x):
    return _nan_warn(apply1(_sin, x), x)


def cos(x):
    return _nan_warn(apply1(_cos, x), x)


def tan(x):
    return _nan_warn(apply1(_tan, x), x)


def tanh(x):
    return _nan_warn(apply1(math.tanh, x), x)


def atan(x):
    return _nan_warn(apply1(math.atan, x), x)


# Skalarkerne ohne Warnung (R-Randfälle wie die Funktionen oben; seit 1.6.4 für RExpr, das je Ausdruck warnt)
_KERN = {"exp": _exp, "log": _log, "log1p": _log1p, "expm1": _expm1, "log2": _log2, "log10": _log10, "sin": _sin,
         "cos": _cos, "tan": _tan, "tanh": math.tanh, "atan": math.atan}
