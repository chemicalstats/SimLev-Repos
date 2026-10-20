"""C-Semantik für die nmath-Portierung (interne Hilfen).

Python-``math`` ruft für ``log``, ``exp``, ``log1p``, ``expm1``, ``pow``,
``sin``/``cos``/``tan`` die Funktionen der System-libm (glibc) auf, wirft
aber an Polstellen und bei Überlauf Ausnahmen, wo C IEEE-754-Werte liefert.
Die Funktionen hier bilden das C-Verhalten nach (``-Inf``, ``Inf``, ``NaN``),
ohne die Rechenergebnisse im Normalfall zu verändern.

Außerdem: Konstanten aus ``Rmath.h``/``float.h`` und R's ``fmax2``,
``fmin2``, ``fsign``, ``imax2``, ``imin2``, ``R_forceint``, ``R_pow_di``.
"""
from __future__ import annotations

import math
import warnings

__all__ = []  # nur intern

INF = math.inf
NINF = -math.inf
NAN = math.nan

# float.h
DBL_EPSILON = 2.220446049250313e-16
DBL_MIN = 2.2250738585072014e-308
DBL_MAX = 1.7976931348623157e308
DBL_MANT_DIG = 53
DBL_MIN_EXP = -1021
DBL_MAX_EXP = 1024
INT_MAX = 2147483647

# Rmath.h
M_E = 2.718281828459045235360287471353
M_LOG2E = 1.442695040888963407359924681002
M_LOG10E = 0.434294481903251827651128918917
M_LN2 = 0.693147180559945309417232121458
M_LN10 = 2.302585092994045684017991454684
M_PI = 3.141592653589793238462643383280
M_2PI = 6.283185307179586476925286766559
M_PI_2 = 1.570796326794896619231321691640
M_PI_4 = 0.785398163397448309615660845820
M_1_PI = 0.318309886183790671537767526745
M_2_PI = 0.636619772367581343075535053490
M_2_SQRTPI = 1.128379167095512573896158903122
M_SQRT2 = 1.414213562373095048801688724210
M_SQRT1_2 = 0.707106781186547524400844362105
M_SQRT_3 = 1.732050807568877293527446341506
M_SQRT_32 = 5.656854249492380195206754896838
M_LOG10_2 = 0.301029995663981195213738894724
M_SQRT_PI = 1.772453850905516027298167483341
M_1_SQRT_2PI = 0.398942280401432677939946059934
M_SQRT_2dPI = 0.797884560802865355879892119869
M_LN_2PI = 1.837877066409345483560659472811
M_LN_SQRT_PI = 0.572364942924700087071713675677
M_LN_SQRT_2PI = 0.918938533204672741780329736406
M_LN_SQRT_PId2 = 0.225791352644727432363097614947

_isnan = math.isnan
_isfinite = math.isfinite
_mlog = math.log
_mlog1p = math.log1p
_mexp = math.exp
_mexpm1 = math.expm1
_mpow = math.pow
_copysign = math.copysign


def ml_warning(msg):
    """R-Warnung aus C-Code (``MATHLIB_WARNING``) ausgeben."""
    warnings.warn(msg, stacklevel=3)


# ── libm mit C-Semantik ────────────────────────────────────────────────────

def log(x):
    try:
        return _mlog(x)
    except ValueError:
        if x == 0.0:
            return NINF
        return NAN


def log1p(x):
    try:
        return _mlog1p(x)
    except ValueError:
        if x == -1.0:
            return NINF
        return NAN


def exp(x):
    try:
        return _mexp(x)
    except OverflowError:
        return INF


def expm1(x):
    try:
        return _mexpm1(x)
    except OverflowError:
        return INF


def _odd_int(y):
    return _isfinite(y) and y == math.floor(y) and math.fmod(y, 2.0) != 0.0


def pow(x, y):  # noqa: A001 - Name wie in C
    """C ``pow(x, y)`` (libm), ohne R's Sonderbehandlung."""
    try:
        return _mpow(x, y)
    except ValueError:
        if x == 0.0:      # Polstelle: pow(+-0, y<0)
            if _odd_int(y) and _copysign(1.0, x) < 0:
                return NINF
            return INF
        return NAN        # negative Basis, nicht ganzzahliger Exponent
    except OverflowError:
        if x < 0 and _odd_int(y):
            return NINF
        return INF


def sqrt(x):
    if x >= 0.0:
        return math.sqrt(x)
    if x != x:
        return x
    return NAN


def ldexp(x, e):
    try:
        return math.ldexp(x, e)
    except OverflowError:
        return _copysign(INF, x)


def floor(x):
    """C ``floor`` (double → double)."""
    if _isfinite(x):
        return float(math.floor(x)) if x == x else x
    return x


def trunc(x):
    if _isfinite(x):
        return float(math.trunc(x))
    return x


def fmod(x, y):
    try:
        return math.fmod(x, y)
    except ValueError:
        return NAN


def nearbyint(x):
    """``R_forceint`` = C ``nearbyint`` (Rundung zur nächsten geraden Zahl)."""
    if _isfinite(x):
        r = float(round(x))
        if r == 0.0:
            return _copysign(0.0, x)
        return r
    return x


R_forceint = nearbyint


def R_nonint(x):
    return abs(x - nearbyint(x)) > 1e-7 * fmax2(1.0, abs(x))


def dv(a, b):
    """``a / b`` mit IEEE-Semantik (auch für ``b == 0``)."""
    try:
        return a / b
    except ZeroDivisionError:
        if a != a or a == 0.0:
            return NAN
        if (a > 0) == (_copysign(1.0, b) > 0):
            return INF
        return NINF


def c_int(x):
    """C-Cast ``(int) x`` (Abschneiden; außerhalb des Bereichs wie x86: INT_MIN)."""
    if x != x or x >= 2147483648.0 or x <= -2147483649.0:
        return -2147483648
    return int(x)


def sin(x):
    try:
        return math.sin(x)
    except ValueError:
        return NAN


def cos(x):
    try:
        return math.cos(x)
    except ValueError:
        return NAN


def tan(x):
    try:
        return math.tan(x)
    except ValueError:
        return NAN


# ── R-Hilfen ──────────────────────────────────────────────────────────────

def fmax2(x, y):
    if x != x or y != y:
        return x + y
    return y if x < y else x


def fmin2(x, y):
    if x != x or y != y:
        return x + y
    return x if x < y else y


def imax2(x, y):
    return y if x < y else x


def imin2(x, y):
    return x if x < y else y


def fsign(x, y):
    if x != x or y != y:
        return x + y
    return abs(x) if y >= 0 else -abs(x)


def R_pow(x, y):
    """R's ``R_pow`` (arithmetic.c)."""
    if y == 2.0:
        return x * x
    if x == 1.0 or y == 0.0:
        return 1.0
    if x == 0.0:
        if y > 0.0:
            return 0.0
        elif y < 0:
            return INF
        return y
    if _isfinite(x) and _isfinite(y):
        return pow(x, y)
    if x != x or y != y:
        return x + y
    if not _isfinite(x):
        if x > 0:
            return 0.0 if y < 0.0 else INF
        else:
            if _isfinite(y) and y == math.floor(y):
                return 0.0 if y < 0.0 else (x if _myfmod2(y) != 0 else -x)
    if not _isfinite(y):
        if x >= 0:
            if y > 0:
                return INF if x >= 1 else 0.0
            else:
                return 0.0 if x >= 1 else INF
    return NAN


def _myfmod2(x1):
    # myfmod(x1, 2.) für endliches ganzzahliges x1
    q = x1 / 2.0
    tmp = x1 - math.floor(q) * 2.0
    return tmp - math.floor(tmp / 2.0) * 2.0


def R_pow_di(x, n):
    """R's ``R_pow_di(x, n)`` (ganzzahliger Exponent)."""
    xn = 1.0
    if x != x:
        return x
    n = int(n)
    if n != 0:
        if not _isfinite(x):
            return R_pow(x, float(n))
        is_neg = n < 0
        if is_neg:
            n = -n
        while True:
            if n & 1:
                xn *= x
            n >>= 1
            if n:
                x *= x
            else:
                break
        if is_neg:
            xn = dv(1.0, xn)
    return xn


def logspace_add(logx, logy):
    """``log(exp(logx) + exp(logy))`` wie R's ``logspace_add``."""
    return fmax2(logx, logy) + log1p(exp(-abs(logx - logy)))


def logspace_sub(logx, logy):
    """``log(exp(logx) - exp(logy))`` wie R's ``logspace_sub``."""
    return logx + R_Log1_Exp(logy - logx)


def R_Log1_Exp(x):
    """``log(1 - exp(x))`` (dpq.h)."""
    return log(-expm1(x)) if x > -M_LN2 else log1p(-exp(x))


# C-lgamma (libm), nur für lbeta() bei winzigen Argumenten
try:  # pragma: no cover - plattformabhängig
    import ctypes as _ct
    import ctypes.util as _ctu

    _libm = _ct.CDLL(_ctu.find_library("m") or "libm.so.6")
    _libm.lgamma.restype = _ct.c_double
    _libm.lgamma.argtypes = [_ct.c_double]

    def c_lgamma(x):
        return _libm.lgamma(x)
except Exception:  # noqa: BLE001
    def c_lgamma(x):
        try:
            return math.lgamma(x)
        except ValueError:
            return INF
