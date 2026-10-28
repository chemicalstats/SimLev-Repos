"""Elementweise libm-Funktionen.

numpy nutzt auf Rechnern mit AVX-512 eigene SIMD-Implementierungen für
``exp``, ``log``, ``log1p``, ``expm1``, ``power``, ``tanh`` usw., die in den
letzten Bits von glibc-libm abweichen. R ruft libm direkt auf. Die
Funktionen hier wenden ``math.*`` (= libm) elementweise an und geben bei
Skalaren Skalare, sonst ``float64``-Arrays gleicher Form zurück.
"""
from __future__ import annotations

import math

import numpy as np

from .rnum import r_pow as _r_pow

__all__ = ["exp", "log", "log1p", "expm1", "log2", "log10", "pow", "sin", "cos", "tan",
           "tanh", "atanh", "atan", "atan2", "asin", "acos", "sinh", "cosh", "lgamma_c",
           "apply1", "apply2"]


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


def apply1(f, x):
    """``f`` (Skalarfunktion) elementweise auf ``x`` anwenden."""
    if np.isscalar(x) or (isinstance(x, np.ndarray) and x.ndim == 0):
        return f(float(x))
    a = np.asarray(x, dtype=np.float64)
    flat = a.ravel()
    out = np.fromiter(map(f, flat.tolist()), dtype=np.float64, count=flat.size)
    return out.reshape(a.shape)


def apply2(f, x, y):
    """``f(x, y)`` elementweise mit R-Recycling (Länge 1 oder gleich)."""
    sx = np.isscalar(x)
    sy = np.isscalar(y)
    if sx and sy:
        return f(float(x), float(y))
    a = np.asarray(x, dtype=np.float64)
    b = np.asarray(y, dtype=np.float64)
    if a.size == 0 or b.size == 0:
        return np.empty(0)
    shape = a.shape if a.size >= b.size else b.shape
    af = a.ravel().tolist()
    bf = b.ravel().tolist()
    n = max(len(af), len(bf))
    out = np.fromiter((f(af[i % len(af)], bf[i % len(bf)]) for i in range(n)), dtype=np.float64, count=n)
    return out.reshape(shape)


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


def _log2(x):
    if x > 0:
        return math.log2(x)
    if x == 0:
        return -math.inf
    return x if x != x else math.nan


def _log10(x):
    if x > 0:
        return math.log10(x)
    if x == 0:
        return -math.inf
    return x if x != x else math.nan


def _exp(x):
    try:
        return math.exp(x)
    except OverflowError:
        return math.inf


def _expm1(x):
    try:
        return math.expm1(x)
    except OverflowError:
        return math.inf


def _atanh(x):
    if x == 1.0:
        return math.inf
    if x == -1.0:
        return -math.inf
    try:
        return math.atanh(x)
    except ValueError:
        return math.nan


def _apply_math(fast, slow, x):
    """Wie ``apply1(slow, x)``, zuerst aber mit der ``math``-Funktion ``fast`` direkt.

    Gilt nur, wenn ``slow(v)`` für jedes ``v``, bei dem ``fast(v)`` keine
    Ausnahme wirft, genau ``fast(v)`` ist (``_exp``, ``_log``): Dann ergibt ein
    Durchlauf ohne Ausnahme dieselben Bits. Bei einer Ausnahme (Überlauf,
    ``log(0)``, ``log(<0)``) rechnet ``apply1`` das ganze Feld neu.
    Etappe 7.1: spart den Python-Aufruf von ``slow`` je Element.
    """
    if np.isscalar(x) or (isinstance(x, np.ndarray) and x.ndim == 0):
        return slow(float(x))
    a = np.asarray(x, dtype=np.float64)
    flat = a.ravel().tolist()
    try:
        out = np.fromiter(map(fast, flat), dtype=np.float64, count=len(flat))
    except (ValueError, OverflowError):
        return apply1(slow, a)
    return out.reshape(a.shape)


def exp(x):
    return _apply_math(math.exp, _exp, x)


def log(x, base=None):
    if base is None:
        return _apply_math(math.log, _log, x)
    # R: log(x, base) = R_log(x) / R_log(base) (arithmetic.c logbase)
    if base == 10:
        return apply1(_log10, x)
    if base == 2:
        return apply1(_log2, x)
    lb = _log(float(base))
    return apply1(lambda v: _log(v) / lb, x)


def log1p(x):
    return apply1(_log1p, x)


def expm1(x):
    return apply1(_expm1, x)


def log2(x):
    return apply1(_log2, x)


def log10(x):
    return apply1(_log10, x)


def pow(x, y):  # noqa: A001 - Name wie in C
    """``x ^ y`` mit R-Semantik (``x*x`` für ``y == 2``, sonst libm ``pow``)."""
    return apply2(_r_pow, x, y)


sin = lambda x: apply1(_nan_wrap(math.sin), x)  # noqa: E731
cos = lambda x: apply1(_nan_wrap(math.cos), x)  # noqa: E731
tan = lambda x: apply1(_nan_wrap(math.tan), x)  # noqa: E731
tanh = lambda x: apply1(math.tanh, x)  # noqa: E731
atanh = lambda x: apply1(_atanh, x)  # noqa: E731
atan = lambda x: apply1(math.atan, x)  # noqa: E731
asin = lambda x: apply1(_nan_wrap(math.asin), x)  # noqa: E731
acos = lambda x: apply1(_nan_wrap(math.acos), x)  # noqa: E731
sinh = lambda x: apply1(_nan_wrap(math.sinh), x)  # noqa: E731
cosh = lambda x: apply1(_nan_wrap(math.cosh), x)  # noqa: E731
lgamma_c = lambda x: apply1(_nan_wrap(math.lgamma), x)  # noqa: E731  (C-lgamma, nicht R's lgammafn)


def atan2(y, x):
    return apply2(math.atan2, y, x)
