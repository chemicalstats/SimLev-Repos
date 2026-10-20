"""R-kompatible Numerik und Zahlenformatierung.

R akkumuliert Summen, Mittelwerte, Varianzen und Produkte intern mit
``long double`` (auf x86-64 Linux: 80-Bit-Extended-Precision). Damit die
Python-Portierung bitgleich zum R-Paket rechnet, bilden die Funktionen in
diesem Modul exakt diese Akkumulationsreihenfolge und -genauigkeit nach.

Zusätzlich enthält das Modul Nachbildungen von R-Funktionen, deren Ergebnis
in Ausgaben oder Rechnungen sichtbar wird: ``round()`` (``nmath/fround.c``),
``signif()`` (``fprec.c``), ``format()``/``as.character()``/``deparse()`` für
Zahlen (``formatReal``/``scientific`` aus ``main/format.c``), ``sprintf()``
mit R-Verhalten für ``NA``/``NaN``/``Inf`` und ``uniroot()`` (Brent-Verfahren
``R_zeroin2``).

Transzendente Funktionen: immer ``math.*`` (glibc-libm wie R), nie die
SIMD-Varianten von numpy (``np.exp``, ``np.log``, ``np.power`` …), die auf
Rechnern mit AVX-512 in den letzten Bits abweichen können.

Auf Plattformen, auf denen ``numpy.longdouble`` nur 64 Bit breit ist
(z. B. macOS auf Apple Silicon, Windows), verhält sich R dort ebenfalls mit
64-Bit-``long double`` bzw. weicht in den letzten Bits ab; die Funktionen
bleiben korrekt, die Bitgleichheit ist dann plattformabhängig.
"""
from __future__ import annotations

import datetime as _dt
import math
import re
import struct
import warnings
from typing import Any, Callable, Sequence

import numpy as np

LD = np.longdouble
_NAN = float("nan")

__all__ = [
    "LD", "NA_REAL", "r_isna", "r_isna_arr", "na_or_nan", "r_sum", "r_cumsum", "r_prod", "r_cumprod", "r_mean", "r_mean_int", "r_var", "r_sd",
    "r_rowsums", "r_colsums", "r_pow", "r_pow_vec", "r_exp_vec", "r_mod1", "r_round", "r_signif",
    "r_median", "r_cummax", "r_format", "r_format1", "r_as_character", "r_deparse", "r_sprintf",
    "r_uniroot", "r_zeroin2",
]


def _as_f64(x) -> np.ndarray:
    return np.asarray(x, dtype=np.float64).ravel()


def _drop_na(x: np.ndarray) -> np.ndarray:
    return x[~np.isnan(x)]


# ═══════════════════════════════════════════════════════════════════════════
# NA und NaN
# ═══════════════════════════════════════════════════════════════════════════
# R's NA_real_ ist ein NaN mit der Nutzlast 1954 im unteren 32-Bit-Wort, im
# Speicher signalisierend (0x7FF00000000007A2); jedes andere NaN ist R's NaN.

_PACK_D = struct.Struct("<d")
_PACK_Q = struct.Struct("<Q")
#: R's ``NA_real_`` (Bitmuster wie in R)
NA_REAL = _PACK_D.unpack(_PACK_Q.pack(0x7FF00000000007A2))[0]
_QUIET = 0x0008000000000000
_FRAC = 0x000FFFFFFFFFFFFF
_INDEF = 0xFFF8000000000000          # x87 "real indefinite" (ungültige Operation)


def _bits(x: float) -> int:
    return _PACK_Q.unpack(_PACK_D.pack(x))[0]


def _from_bits(b: int) -> float:
    return _PACK_D.unpack(_PACK_Q.pack(b))[0]


def r_isna(x) -> bool:
    """``R_IsNA(x)``: True nur für R's NA (NaN mit Nutzlast 1954), nicht für NaN."""
    x = float(x)
    return x != x and (_bits(x) & 0xFFFFFFFF) == 1954


def r_isna_arr(a) -> np.ndarray:
    """Maske ``R_IsNA`` für ein Array."""
    a = np.ascontiguousarray(a, dtype=np.float64)
    return np.isnan(a) & ((a.view(np.uint64) & np.uint64(0xFFFFFFFF)) == np.uint64(1954))


def na_or_nan(*vals) -> float:
    """NA, falls ein Wert NA ist, sonst R's NaN (wie ``if_NA_Math*_set``)."""
    for v in vals:
        if r_isna(v):
            return NA_REAL
    return _NAN


def _x87_nan(vals, mul: bool = False, init: float = 0.0):
    """NaN-Ergebnis einer sequenziellen ``long double``-Kumulation ``acc op= x[i]``.

    Bildet die x87-Regel nach, die R's ``s += x[i]`` (``fadd m64``) trifft: Ist
    der Akkumulator schon NaN, gewinnt ein signalisierendes NaN aus dem Speicher
    (R's NA) nie, ein ruhiges nur mit größerer Mantisse (bei Gleichstand das
    positive). Liefert das Ergebnis als ``float`` (Bits wie in R) oder ``None``,
    wenn kein NaN entsteht.
    """
    acc = LD(init)
    nb = None
    for v in vals:
        v = float(v)
        if nb is None:
            if v != v:
                nb = _bits(v) | _QUIET
            else:
                with np.errstate(invalid="ignore"):
                    acc = acc * LD(v) if mul else acc + LD(v)
                if acc != acc:
                    nb = _INDEF
        elif v != v:
            b = _bits(v)
            if b & _QUIET:
                fa, fb = nb & _FRAC, b & _FRAC
                if fb > fa or (fb == fa and (nb >> 63)):
                    nb = b
    return None if nb is None else _from_bits(nb)


def _handle_nan(x: np.ndarray, out: np.ndarray) -> np.ndarray:
    """R's ``handleNaN`` (cum.c): ab dem ersten NaN NA (sobald ein NA vorkam) bzw. NaN."""
    has_nan = has_na = False
    for i, v in enumerate(x.tolist()):
        if not has_nan and v != v:
            has_nan = True
        if has_nan and not has_na and r_isna(v):
            has_na = True
        if has_na:
            out[i] = NA_REAL
        elif has_nan:
            out[i] = _NAN
    return out


# ═══════════════════════════════════════════════════════════════════════════
# Summen, Mittelwerte, Varianzen (long double wie R)
# ═══════════════════════════════════════════════════════════════════════════

def r_sum(x, na_rm: bool = False) -> float:
    """``sum(x)`` wie in R (long-double-Akkumulator, sequenziell)."""
    a = _as_f64(x)
    if na_rm:
        a = _drop_na(a)
    if a.size == 0:
        return 0.0
    with np.errstate(invalid="ignore"):
        r = float(np.cumsum(a, dtype=LD)[-1])
    if r != r:
        return _x87_nan(a)
    return r


def r_cumsum(x) -> np.ndarray:
    """``cumsum(x)`` wie in R (long-double-Akkumulator; NA/NaN über ``handleNaN``)."""
    a = _as_f64(x)
    if a.size == 0:
        return a.copy()
    with np.errstate(invalid="ignore"):
        out = np.cumsum(a, dtype=LD).astype(np.float64)
    if out[-1] != out[-1]:
        _handle_nan(a, out)
    return out


def r_prod(x, na_rm: bool = False) -> float:
    """``prod(x)`` wie in R (long-double-Akkumulator)."""
    a = _as_f64(x)
    if na_rm:
        a = _drop_na(a)
    if a.size == 0:
        return 1.0
    with np.errstate(invalid="ignore"):
        r = float(np.cumprod(a, dtype=LD)[-1])
    if r != r:
        return _x87_nan(a, mul=True, init=1.0)
    return r


def r_cumprod(x) -> np.ndarray:
    """``cumprod(x)`` wie in R (long-double-Akkumulator; NA/NaN über ``handleNaN``)."""
    a = _as_f64(x)
    if a.size == 0:
        return a.copy()
    with np.errstate(invalid="ignore"):
        out = np.cumprod(a, dtype=LD).astype(np.float64)
    if out[-1] != out[-1]:
        _handle_nan(a, out)
    return out


def r_cummax(x) -> np.ndarray:
    """``cummax(x)`` wie in R (ab dem ersten NA/NaN über ``handleNaN``)."""
    a = _as_f64(x)
    out = np.empty_like(a)
    m = -math.inf
    for i, v in enumerate(a.tolist()):
        if v != v:
            return _handle_nan(a, out)
        if not (m > v):
            m = v
        out[i] = m
    return out


def r_mean(x, na_rm: bool = False) -> float:
    """``mean(x)`` für Doubles wie R's ``real_mean`` (Summe/n plus Korrekturdurchlauf)."""
    a = _as_f64(x)
    if na_rm:
        a = _drop_na(a)
    n = a.size
    if n == 0:
        return _NAN
    with np.errstate(invalid="ignore", over="ignore"):
        al = a.astype(LD)
        ln = LD(n)
        s = np.cumsum(al)[-1]
        finite_s = math.isfinite(float(s))
        if finite_s:
            s = s / ln
        else:
            q = a / float(n)                       # double-Division wie dx[k]/n
            s = np.cumsum(q, dtype=LD)[-1]
            if s != s:
                return _x87_nan(q)
        if finite_s and math.isfinite(float(s)):
            t = np.cumsum(al - s)[-1]
            s = s + t / ln
        elif math.isfinite(float(s)):
            t = np.cumsum((al - s) / ln)[-1]
            s = s + t
    return float(s)


def r_mean_int(x) -> float:
    """``mean(x)`` für Integer-Vektoren wie in R (long-double Summe / n)."""
    a = np.asarray(x, dtype=np.int64).ravel()
    n = a.size
    if n == 0:
        return _NAN
    s = LD(0)
    for v in a:
        s += LD(int(v))
    return float(s / LD(n))


def _r_mean_ld(al: np.ndarray) -> float:
    """MEAN-Makro aus R's cov.c; liefert den auf double gerundeten Mittelwert."""
    n = al.size
    s = np.cumsum(al)[-1]
    tmp = s / LD(n)
    if math.isfinite(float(tmp)):
        s2 = np.cumsum(al - tmp)[-1]
        tmp = tmp + s2 / LD(n)
    return float(tmp)


def r_var(x, na_rm: bool = False) -> float:
    """``var(x)`` (Pearson) wie R's ``cov_complete1`` (NA bei fehlenden Werten oder n < 2)."""
    a = _as_f64(x)
    if na_rm:
        a = _drop_na(a)
    elif np.isnan(a).any():
        return NA_REAL
    n = a.size
    if n <= 1:
        return NA_REAL
    al = a.astype(LD)
    xm = LD(_r_mean_ld(al))          # Mittelwert wird in R als double gespeichert
    d = al - xm
    s = np.cumsum(d * d)[-1]
    return float(s / LD(n - 1))


def r_sd(x, na_rm: bool = False) -> float:
    """``sd(x)`` wie in R: ``sqrt(var(x))``."""
    v = r_var(x, na_rm=na_rm)
    if v != v:
        return v
    return math.sqrt(v) if v >= 0 else _NAN


def r_median(x, na_rm: bool = False) -> float:
    """``stats::median(x)`` für Zahlen (Mittel der beiden mittleren Werte mit long double)."""
    a = _as_f64(x)
    if na_rm:
        a = _drop_na(a)
    elif np.isnan(a).any():
        return NA_REAL                  # x[NA_integer_]
    n = a.size
    if n == 0:
        return NA_REAL
    s = np.sort(a)
    half = (n + 1) // 2
    if n % 2 == 1:
        return float(s[half - 1])
    return r_mean(s[half - 1:half + 1])


def r_rowsums(m: np.ndarray, na_rm: bool = False) -> np.ndarray:
    """``rowSums(m)`` wie in R (long-double-Akkumulator, spaltenweise)."""
    m = np.asarray(m, dtype=np.float64)
    if m.ndim == 1:
        m = m.reshape(-1, 1)
    acc = np.zeros(m.shape[0], dtype=LD)
    with np.errstate(invalid="ignore"):
        for j in range(m.shape[1]):
            col = m[:, j]
            if na_rm:
                acc = acc + np.where(np.isnan(col), 0.0, col).astype(LD)
            else:
                acc = acc + col.astype(LD)
    out = acc.astype(np.float64)
    if not na_rm:
        for i in np.flatnonzero(np.isnan(out)):
            out[i] = _x87_nan(m[i, :])
    return out


def r_colsums(m: np.ndarray, na_rm: bool = False) -> np.ndarray:
    """``colSums(m)`` wie in R (long-double-Akkumulator je Spalte)."""
    m = np.asarray(m, dtype=np.float64)
    if m.ndim == 1:
        m = m.reshape(-1, 1)
    return np.array([r_sum(m[:, j], na_rm=na_rm) for j in range(m.shape[1])], dtype=np.float64)


# ═══════════════════════════════════════════════════════════════════════════
# Potenz, Exponentialfunktion, Rest
# ═══════════════════════════════════════════════════════════════════════════

def r_pow(x: float, y: float) -> float:
    """Skalares ``x ^ y`` wie R's ``R_POW``/``R_pow`` (Linux: libm ``pow``)."""
    x = float(x)
    y = float(y)
    if y == 2.0:
        return x * x
    if x == 1.0 or y == 0.0:
        return 1.0
    if x == 0.0:
        if y > 0.0:
            return 0.0
        if y < 0.0:
            return math.inf
        return y
    if math.isfinite(x) and math.isfinite(y):
        try:
            return math.pow(x, y)
        except ValueError:          # negative Basis, nicht-ganzzahliger Exponent
            return _NAN
        except OverflowError:
            if x < 0 and y == math.floor(y) and int(y) % 2 == 1:
                return -math.inf
            return math.inf
    if math.isnan(x) or math.isnan(y):
        return x + y
    # Unendlichkeiten: wie R_pow
    if not math.isfinite(x):
        if x > 0:
            return 0.0 if y < 0.0 else math.inf
        if math.isfinite(y) and y == math.floor(y):
            return (0.0 if y < 0 else (x if math.fmod(y, 2.0) != 0 else -x))
    if not math.isfinite(y):
        if x >= 0:
            if y > 0:
                return math.inf if x >= 1 else 0.0
            return math.inf if x < 1 else 0.0
    return _NAN


def r_pow_vec(x, y: float) -> np.ndarray:
    """Elementweises ``x ^ y`` mit R-Semantik (libm, keine SIMD-Varianten)."""
    a = _as_f64(x)
    return np.fromiter((r_pow(v, y) for v in a), dtype=np.float64, count=a.size)


def r_exp_vec(x) -> np.ndarray:
    """Elementweises ``exp(x)`` über libm (``math.exp``) wie R."""
    a = _as_f64(x)
    out = np.empty_like(a)
    for i, v in enumerate(a):
        try:
            out[i] = math.exp(v)
        except OverflowError:
            out[i] = math.inf
    return out


def r_mod1(x: float) -> float:
    """``x %% 1`` für endliche Doubles wie R's ``myfmod(x, 1)``."""
    x = float(x)
    if not math.isfinite(x):
        return _NAN
    q = x
    tmp = LD(x) - LD(math.floor(q)) * LD(1.0)
    return float(tmp - LD(math.floor(float(tmp))) * LD(1.0))


def _ffloor(x: float) -> float:
    return float(np.floor(x))


def _fceil(x: float) -> float:
    return float(np.ceil(x))


def _r_pow_di(x: float, n: int) -> float:
    """``R_pow_di``: x hoch ganzzahliges n durch wiederholtes Quadrieren."""
    xn = 1.0
    if math.isnan(x):
        return x
    if n != 0:
        if not math.isfinite(x):
            return r_pow(x, float(n))
        neg = n < 0
        if neg:
            n = -n
        while True:
            if n & 1:
                xn *= x
            n >>= 1
            if n:
                x *= x
            else:
                break
        if neg:
            xn = 1.0 / xn
    return xn


_M_LOG10_2 = 0.301029995663981195213738894724


def r_round(x: float, digits: float = 0.0) -> float:
    """``round(x, digits)`` wie R >= 4.0.0 (``nmath/fround.c``)."""
    x = float(x)
    digits = float(digits)
    max10e = 308
    if math.isnan(x) or math.isnan(digits):
        return x + digits
    if not math.isfinite(x):
        return x
    if digits > 308 + 15 or x == 0.0:
        return x
    if digits < -max10e:
        return 0.0
    if digits == 0.0:
        return float(np.rint(x))
    dig = int(_ffloor(digits + 0.5))
    sgn = 1.0
    if x < 0.0:
        sgn = -1.0
        x = -x
    logb = math.frexp(x)[1] - 1
    l10x = _M_LOG10_2 * (0.5 + logb)
    if l10x + dig > 15:
        return sgn * x
    if dig <= max10e:
        pow10 = _r_pow_di(10.0, dig)
        x10 = x * pow10
        i10 = _ffloor(x10)
        xd = i10 / pow10
        xu = _fceil(x10) / pow10
    else:
        e10 = dig - max10e
        p10 = _r_pow_di(10.0, e10)
        pow10 = _r_pow_di(10.0, max10e)
        x10 = (x * pow10) * p10
        i10 = _ffloor(x10)
        xd = i10 / pow10 / p10
        xu = _fceil(x10) / pow10 / p10
    du = xu - x
    dd = x - xd
    return sgn * (xu if (du < dd or (math.fmod(i10, 2.0) == 1 and du == dd)) else xd)


def r_signif(x: float, digits: float = 6) -> float:
    """``signif(x, digits)`` wie R (``nmath/fprec.c``)."""
    x = float(x)
    max10e = 308
    if math.isnan(x) or math.isnan(digits):
        return x + digits
    if not math.isfinite(x):
        return x
    if not math.isfinite(digits):
        if digits > 0:
            return x
        digits = 1.0
    if x == 0:
        return x
    dig = int(round(digits))
    if dig > 22:
        return x
    if dig < 1:
        dig = 1
    sgn = 1.0
    if x < 0.0:
        sgn = -sgn
        x = -x
    l10 = math.log10(x)
    e10 = int(dig - 1 - _ffloor(l10))
    if abs(l10) < max10e - 2:
        p10 = 1.0
        if e10 > max10e:
            p10 = _r_pow_di(10.0, e10 - max10e)
            e10 = max10e
        if e10 > 0:
            pow10 = _r_pow_di(10.0, e10)
            return sgn * (float(np.rint((x * pow10) * p10)) / pow10) / p10
        pow10 = _r_pow_di(10.0, -e10)
        return sgn * (float(np.rint(x / pow10)) * pow10)
    do_round = max10e - l10 >= _r_pow_di(10.0, -dig)
    e2 = dig + (1 if e10 > 0 else -1) * 22
    p10 = _r_pow_di(10.0, e2)
    x *= p10
    P10 = _r_pow_di(10.0, e10 - e2)
    x *= P10
    if do_round:
        x += 0.5
    x = _ffloor(x) / p10
    return sgn * x / P10


# ═══════════════════════════════════════════════════════════════════════════
# Zahlenformatierung wie R (format.c, printutils.c)
# ═══════════════════════════════════════════════════════════════════════════

_TBL = [LD("1e%d" % k) for k in range(28)]
_KP_MAX = 27


def _scientific(x: float, digits: int):
    """``scientific()`` aus R's format.c: (neg, kpower, nsig, roundingwidens)."""
    if x == 0.0:
        return 0, 0, 1, False
    if x < 0.0:
        neg, r = 1, -x
    else:
        neg, r = 0, x
    if digits >= 16:
        s = "%#.*e" % (digits - 1, r)
        mant, ex = s.split("e")
        kpower = int(ex)
        digs = mant.replace(".", "")
        i = digits
        while i >= 2 and digs[i - 1] == "0":
            i -= 1
        return neg, kpower, i, False
    kp = int(math.floor(math.log10(r))) - digits + 1
    r_prec = LD(r)
    if abs(kp) <= _KP_MAX:
        if kp > 0:
            r_prec = r_prec / _TBL[kp]
        elif kp < 0:
            r_prec = r_prec * _TBL[-kp]
    else:
        r_prec = r_prec / np.power(LD(10.0), LD(kp))
    if r_prec < _TBL[digits - 1]:
        r_prec = r_prec * LD(10.0)
        kp -= 1
    alpha = float(np.rint(r_prec))
    nsig = digits
    for _ in range(1, digits + 1):
        alpha /= 10.0
        if alpha == math.floor(alpha):
            nsig -= 1
        else:
            break
    if nsig == 0 and digits > 0:
        nsig = 1
        kp += 1
    kpower = kp + digits - 1
    rgt = digits - kpower
    rgt = 0 if rgt < 0 else (_KP_MAX if rgt > _KP_MAX else rgt)
    fuzz = 0.5 / float(_TBL[rgt])
    rw = 0 < kpower <= _KP_MAX and LD(r) < _TBL[kpower] - LD(fuzz)
    return neg, kpower, nsig, bool(rw)


def _format_real(xs: Sequence[float], digits: int = 7, nsmall: int = 0, scipen: int = 0):
    """``formatReal()``: gemeinsame Breite w, Nachkommastellen d, Exponentformat e."""
    naflag = nanflag = posinf = neginf = False
    neg = 0
    mnl = 10 ** 9
    mxl = rgt = mxsl = mxns = -10 ** 9
    for x in xs:
        if not math.isfinite(x):
            if math.isnan(x):
                if r_isna(x):
                    naflag = True
                else:
                    nanflag = True
            elif x > 0:
                posinf = True
            else:
                neginf = True
            continue
        neg_i, kpower, nsig, rw = _scientific(x, digits)
        left = kpower + 1
        if rw:
            left -= 1
        sleft = neg_i + (1 if left <= 0 else left)
        right = nsig - left
        if neg_i:
            neg = 1
        rgt = max(rgt, right)
        mxl = max(mxl, left)
        mnl = min(mnl, left)
        mxsl = max(mxsl, sleft)
        mxns = max(mxns, nsig)
    if digits == 0:
        rgt = 0
    if mxl < 0:
        mxsl = 1 + neg
    if rgt < 0:
        rgt = 0
    wF = mxsl + rgt + (1 if rgt != 0 else 0)
    e = 2 if (mxl > 100 or mnl <= -99) else 1
    if mxns != -10 ** 9:
        d = mxns - 1
        w = neg + (1 if d > 0 else 0) + d + 4 + e
        if wF <= w + scipen:
            e = 0
            if nsmall > rgt:
                rgt = nsmall
                wF = mxsl + rgt + (1 if rgt != 0 else 0)
            d = rgt
            w = wF
    else:
        w = d = e = 0
    if naflag and w < 2:
        w = 2
    if nanflag and w < 3:
        w = 3
    if posinf and w < 3:
        w = 3
    if neginf and w < 4:
        w = 4
    return w, d, e


def _encode_real(x: float, w: int, d: int, e: int, na: str = "NA", drop0: bool = False) -> str:
    if x == 0.0:
        x = 0.0
    if not math.isfinite(x):
        s = (na if r_isna(x) else "NaN") if math.isnan(x) else ("Inf" if x > 0 else "-Inf")
        return s.rjust(w)
    if e:
        s = ("%#*.*e" % (w, d, x)) if d else ("%*.*e" % (w, d, x))
    else:
        s = "%*.*f" % (w, d, x)
    if drop0 and "." in s:
        m = re.match(r"^(.*?\.)(\d*)(.*)$", s)
        head, digs, tail = m.group(1), m.group(2), m.group(3)
        digs = digs.rstrip("0")
        s = (head + digs if digs else head[:-1]) + tail
    return s


def _insert_big_mark(s: str, mark: str) -> str:
    m = re.match(r"^(\s*[-+]?)(\d+)(.*)$", s)
    if not m or len(m.group(2)) < 4:
        return s
    digs = m.group(2)
    rev = digs[::-1]
    parts = [rev[i:i + 3] for i in range(0, len(rev), 3)]
    return m.group(1) + mark[::-1].join(parts)[::-1] + m.group(3)


def _is_num(x) -> bool:
    return isinstance(x, (int, float, np.integer, np.floating)) and not isinstance(x, (bool, np.bool_))


def r_format(x: Any, digits: int | None = None, nsmall: int = 0, big_mark: str = "",
             scientific: bool | None = None, width: int | None = None) -> list[str]:
    """``format(x, ...)`` für einen Vektor wie R (gemeinsame Breite).

    ``x`` darf eine Zahl, ein Wahrheitswert, ein Text, ein Datum oder eine Folge davon
    sein. Rückgabe: Liste der formatierten Elemente.
    """
    if x is None:
        return []
    vals = list(x) if isinstance(x, (list, tuple, np.ndarray)) else [x]
    if not vals:
        return []
    dg = 7 if digits is None else int(digits)
    scipen = 0 if scientific is None else (-99 if scientific else 310)
    if all(_is_num(v) or v is None for v in vals) and any(_is_num(v) for v in vals):
        fv = [NA_REAL if v is None else float(v) for v in vals]
        w, d, e = _format_real(fv, dg, nsmall, scipen)
        out = [_encode_real(v, w, d, e) for v in fv]
        if big_mark:
            out = [_insert_big_mark(s, big_mark) for s in out]
            ww = max(len(s) for s in out)
            out = [s.rjust(ww) for s in out]
        if width:
            out = [s.rjust(width) for s in out]
        return out
    if all(isinstance(v, (bool, np.bool_)) or v is None for v in vals):
        out = ["NA" if v is None else ("TRUE" if v else "FALSE") for v in vals]
        w = max(len(s) for s in out)
        return [s.rjust(w) for s in out]
    out = [_as_str(v) for v in vals]
    w = max(width or 0, max(len(s) for s in out))
    return [s.ljust(w) for s in out]


def r_format1(x: Any, **kw) -> str:
    """``format(x)`` für einen einzelnen Wert."""
    r = r_format(x, **kw)
    return r[0] if r else "character(0)"


def _as_str(v: Any) -> str:
    if v is None:
        return "NA"
    if isinstance(v, str):
        return v
    if isinstance(v, (bool, np.bool_)):
        return "TRUE" if v else "FALSE"
    if isinstance(v, (_dt.date, np.datetime64)):
        if isinstance(v, np.datetime64):
            return str(v.astype("datetime64[D]"))
        if isinstance(v, _dt.datetime):
            return v.date().isoformat()
        return v.isoformat()
    if _is_num(v):
        return r_as_character(v)
    return str(v)


def r_as_character(x: Any) -> str:
    """``as.character(x)`` für eine Zahl (15 signifikante Stellen, ohne Endnullen)."""
    if isinstance(x, (bool, np.bool_)):
        return "TRUE" if x else "FALSE"
    if isinstance(x, (int, np.integer)) and not isinstance(x, (bool, np.bool_)) and abs(int(x)) < 2 ** 31:
        return str(int(x))
    xf = float(x)
    if math.isnan(xf):
        return "NA" if r_isna(xf) else "NaN"
    w, d, e = _format_real([xf], 15, 0, 0)
    return _encode_real(xf, w, d, e, drop0=True)


def r_deparse(x: Any) -> str:
    """``paste(deparse(x), collapse = "")`` für einfache Werte (Zahlen, Text, Wahrheitswerte, Vektoren)."""
    def one(v, all_na=False):
        if v is None:
            return "NA"
        if isinstance(v, str):
            return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
        if isinstance(v, (bool, np.bool_)):
            return "TRUE" if v else "FALSE"
        if isinstance(v, (_dt.date, np.datetime64)):
            return '"%s"' % _as_str(v)
        if _is_num(v):
            f = float(v)
            if math.isnan(f):
                if not r_isna(f):
                    return "NaN"
                # Ein Double-Vektor nur aus NA: NA_real_ (sonst wäre er logisch)
                return "NA_real_" if all_na else "NA"
            if math.isinf(f):
                return "Inf" if f > 0 else "-Inf"
            w, d, e = _format_real([f], 15, 0, 0)
            return _encode_real(f, w, d, e)
        return repr(v)
    if x is None:
        return "NULL"
    if isinstance(x, dict):
        if not x:
            return "list()"
        return "list(" + ", ".join("%s = %s" % (k, r_deparse(v)) for k, v in x.items()) + ")"
    if isinstance(x, (list, tuple, np.ndarray)):
        vals = list(x)
        if not vals:
            return "NULL" if isinstance(x, (list, tuple)) else "numeric(0)"
        if any(isinstance(v, (list, tuple, dict)) for v in vals):
            return "list(" + ", ".join(r_deparse(v) for v in vals) + ")"
        all_na = all(_is_num(v) and r_isna(float(v)) for v in vals)
        if len(vals) == 1:
            return one(vals[0], all_na)
        return "c(" + ", ".join(one(v, all_na) for v in vals) + ")"
    return one(x, True)


_SPEC = re.compile(r"%(?P<flags>[-+ #0]*)(?P<width>\*|\d+)?(?:\.(?P<prec>\*|\d+))?(?P<conv>[diouxXeEfFgGaAcs%])")


def r_sprintf(fmt: str, *args: Any) -> str:
    """``sprintf(fmt, ...)`` mit R-Verhalten für Skalare.

    Zahlen werden wie in R behandelt: ``NA``/``NaN``/``Inf`` in Gleitkomma-Formaten
    als Text (gleiche Breite), ganze Doubles in ``%d``, Zahlen in ``%s`` über
    ``as.character()``; Datumswerte in ``%s`` als JJJJ-MM-TT.
    """
    out = []
    pos = 0
    ai = 0
    for m in _SPEC.finditer(fmt):
        out.append(fmt[pos:m.start()])
        pos = m.end()
        conv = m.group("conv")
        if conv == "%":
            out.append("%")
            continue
        flags = m.group("flags") or ""
        width = m.group("width")
        prec = m.group("prec")
        if width == "*":
            width = str(int(args[ai]))
            ai += 1
        if prec == "*":
            prec = str(int(args[ai]))
            ai += 1
        v = args[ai]
        ai += 1
        spec = "%" + flags + (width or "") + ("." + prec if prec is not None else "")
        if conv in "eEfFgGaA":
            if v is None or (_is_num(v) and not math.isfinite(float(v))):
                if v is None or math.isnan(float(v)):
                    s = "NA" if (v is None or r_isna(float(v))) else "NaN"
                    s = " " + s if " " in flags else s
                elif float(v) > 0:
                    s = "+Inf" if "+" in flags else (" Inf" if " " in flags else "Inf")
                else:
                    s = "-Inf"
                out.append(("%" + flags.replace("0", "").replace("+", "").replace(" ", "")
                            + (width or "") + "s") % s)
            else:
                out.append((spec + conv) % float(v))
        elif conv in "dioxX":
            if v is None or (isinstance(v, float) and math.isnan(v)):
                out.append(("%" + flags.replace("0", "") + (width or "") + "s") % "NA")
            elif isinstance(v, (bool, np.bool_)):
                out.append((spec + conv) % int(v))
            else:
                fv = float(v)
                if fv != int(fv):
                    raise ValueError("invalid format '%s'; use format %%f, %%e, %%g or %%a for numeric objects"
                                     % (spec + conv))
                out.append((spec + conv) % int(fv))
        elif conv == "s":
            out.append((spec + "s") % _as_str(v))
        else:
            out.append((spec + conv) % v)
    out.append(fmt[pos:])
    return "".join(out)


# ═══════════════════════════════════════════════════════════════════════════
# Nullstellensuche: stats::uniroot() mit R_zeroin2 (Brent)
# ═══════════════════════════════════════════════════════════════════════════

_DBL_EPS = 2.220446049250313e-16
_DBL_MAX = 1.7976931348623157e308


def r_zeroin2(f: Callable[[float], float], ax: float, bx: float, fa: float, fb: float,
              tol: float, maxit: int):
    """Port von ``R_zeroin2`` (stats/src/zeroin.c). Rückgabe: (Wurzel, Iterationen, Genauigkeit)."""
    a, b = ax, bx
    c, fc = a, fa
    maxit_c = maxit + 1
    if fa == 0.0:
        return a, 0, 0.0
    if fb == 0.0:
        return b, 0, 0.0
    while maxit_c:
        maxit_c -= 1
        prev_step = b - a
        if abs(fc) < abs(fb):
            a = b
            b = c
            c = a
            fa = fb
            fb = fc
            fc = fa
        tol_act = 2 * _DBL_EPS * abs(b) + tol / 2
        new_step = (c - b) / 2
        if abs(new_step) <= tol_act or fb == 0.0:
            return b, maxit - maxit_c, abs(c - b)
        if abs(prev_step) >= tol_act and abs(fa) > abs(fb):
            cb = c - b
            if a == c:
                t1 = fb / fa
                p = cb * t1
                q = 1.0 - t1
            else:
                q = fa / fc
                t1 = fb / fc
                t2 = fb / fa
                p = t2 * (cb * q * (q - t1) - (b - a) * (t1 - 1.0))
                q = (q - 1.0) * (t1 - 1.0) * (t2 - 1.0)
            if p > 0.0:
                q = -q
            else:
                p = -p
            if p < (0.75 * cb * q - abs(tol_act * q) / 2) and p < abs(prev_step * q / 2):
                new_step = p / q
        if abs(new_step) < tol_act:
            new_step = tol_act if new_step > 0.0 else -tol_act
        a = b
        fa = fb
        b += new_step
        fb = f(b)
        if (fb > 0 and fc > 0) or (fb < 0 and fc < 0):
            c = a
            fc = fa
    return b, -1, abs(c - b)


def r_uniroot(f: Callable[[float], float], interval: Sequence[float], f_lower: float | None = None,
              f_upper: float | None = None, tol: float = _DBL_EPS ** 0.25, maxiter: int = 1000) -> dict:
    """``stats::uniroot(f, interval, f.lower =, f.upper =, tol =, maxiter =)`` (extendInt = "no")."""
    lower, upper = min(interval), max(interval)
    if not lower < upper:
        raise ValueError("lower < upper  is not fulfilled")
    if f_lower is None:
        f_lower = f(lower)
    if f_upper is None:
        f_upper = f(upper)
    if math.isnan(f_lower):
        raise ValueError("f.lower = f(lower) is NA")
    if math.isnan(f_upper):
        raise ValueError("f.upper = f(upper) is NA")

    def trunc(v):
        return max(min(v, _DBL_MAX), -_DBL_MAX)

    def sign(v):
        return (v > 0) - (v < 0)
    if not sign(f_lower) * sign(f_upper) <= 0:
        raise ValueError("f() values at end points not of opposite sign")

    def fcn2(x):
        v = float(f(x))
        if not math.isfinite(v):
            if v == -math.inf:
                warnings.warn("-Inf replaced by maximally negative value")
                return -_DBL_MAX
            warnings.warn("NA/Inf replaced by maximum positive value")
            return _DBL_MAX
        return v
    root, it, prec = r_zeroin2(fcn2, lower, upper, trunc(f_lower), trunc(f_upper), tol, maxiter)
    if it < 0:
        warnings.warn("_NOT_ converged in %d iterations" % maxiter)
        it = maxiter
    return {"root": root, "iter": it, "estim.prec": prec}
