"""R-kompatible Numerik (Kern der R-Nachbildung, Gegenstück zu ``julia/src/r/rnum.jl``).

Aufgabenteilung in ``simlev._r``: Dieses Modul ist die unterste Schicht und
importiert nichts aus ``simlev``. Es definiert ``NA_REAL`` (R's
``NA_real_``, die einzige Definition im Paket; öffentlich als ``simlev.NA``)
mit ``r_isna``/``r_isna_arr`` und die skalaren bzw. eindimensionalen
Engine-Hilfen mit ``r_``-Präfix: Summen, Mittel, Varianzen und Produkte in
long double, ``r_pow`` (``R_POW``), ``r_mod1`` und ``r_uniroot``
(Brent-Verfahren ``R_zeroin2``). Darauf bauen auf:

- :mod:`simlev._r.rformat`: ``r_round``, ``r_signif``, ``r_format``,
  ``r_as_character``, ``r_deparse``, ``r_sprintf`` (Textausgabe der Engine),
- :mod:`simlev._r.base`: re-exportiert die Summenhilfen und ergänzt
  Funktionen von R's base mit R-Namen für Vektoren, Matrizen und DataFrames
  (``colSums``, ``rowMeans``, ``cumprod``, ``pmin``, ``range`` …), dazu
  ``quiet_fp`` (Gleitkomma-Warnungen bei NA unterdrücken, ``env`` aus dem
  Aufrufer) und ``sys_time``,
- :mod:`simlev._r.fmt`: die volle Formatierung (``format``, ``formatC``,
  ``print``).

R akkumuliert Summen, Mittelwerte, Varianzen und Produkte intern mit
``long double`` (auf x86-64 Linux: 80-Bit-Extended-Precision). Damit die
Python-Portierung bitgleich zum R-Paket rechnet, bilden die Funktionen in
diesem Modul exakt diese Akkumulationsreihenfolge und -genauigkeit nach.

Transzendente Funktionen: immer ``math.*`` (glibc-libm wie R), nie die
SIMD-Varianten von numpy (``np.exp``, ``np.log``, ``np.power`` …), die auf
Rechnern mit AVX-512 in den letzten Bits abweichen können.

Auf Plattformen, auf denen ``numpy.longdouble`` nur 64 Bit breit ist
(z. B. macOS auf Apple Silicon, Windows), verhält sich R dort ebenfalls mit
64-Bit-``long double`` bzw. weicht in den letzten Bits ab; die Funktionen
bleiben korrekt, die Bitgleichheit ist dann plattformabhängig.
"""
from __future__ import annotations

import math
import struct
import warnings
from typing import Callable, Sequence

import numpy as np

LD = np.longdouble
_NAN = float("nan")

__all__ = [
    "LD", "NA_REAL", "r_isna", "r_isna_arr", "na_or_nan", "r_sum", "r_cumsum", "r_prod", "r_cumprod", "r_mean", "r_mean_int", "r_var", "r_sd",
    "r_rowsums", "r_colsums", "r_pow", "r_pow_vec", "r_exp_vec", "r_mod1",
    "r_median", "r_cummax", "r_uniroot", "r_zeroin2",
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
