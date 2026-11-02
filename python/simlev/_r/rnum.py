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
``long double`` (auf x86-64 Linux: 80-Bit-Extended-Precision). Seit N8 rechnen
``r_sum``, ``r_prod``, ``r_mean``, ``r_var``, die Kumulationen, ``r_rowsums``/
``r_colsums`` und ``r_pow_vec`` mit den C-Kernen ``core/slc_rbase.c`` (über
:mod:`simlev._ext`), die Julia ebenso nutzt; sie akkumulieren in long double
wie R und sind gegen R bitgleich geprüft.

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

from .. import _ext   # C-Erweiterung (N8: Kerne core/slc_rbase*.c)

LD = np.longdouble
_NAN = float("nan")

__all__ = [
    "LD", "NA_REAL", "r_isna", "r_isna_arr", "na_or_nan", "r_sum", "r_cumsum", "r_prod", "r_cumprod", "r_mean", "r_mean_int", "r_var", "r_sd",
    "r_rowsums", "r_colsums", "r_cummin", "r_pow", "r_pow_vec", "r_exp_vec", "r_mod1",
    "r_median", "r_cummax", "r_uniroot", "r_zeroin2", "c_div",
    "X86_NAN", "nan_quiet", "n_add", "n_sub", "n_mul", "n_div", "n_sqrt", "n_log", "n_exp",
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


def c_div(a: float, b: float) -> float:
    """``a / b`` wie C bzw. R auf x86-64 (IEEE, kein ``ZeroDivisionError``).

    Für ``b != 0`` ist das Pythons Division (dieselbe Maschinenoperation). Für
    ``b == 0`` rechnet die Maschine: ``±Inf`` mit dem Vorzeichen aus beiden
    Operanden, ``0/0`` das Standard-NaN ``0xfff8…`` (negatives Vorzeichen), ein
    NaN-Zähler bleibt mit seiner Nutzlast erhalten (NA bleibt NA).
    """
    try:
        return a / b
    except ZeroDivisionError:
        with np.errstate(all="ignore"):
            return float(np.float64(a) / np.float64(b))


# ── NaN-genaue Einzeloperationen ─────────────────────────────────────────────
#
# Treffen in einer Operation zwei NaN aufeinander (etwa NA und NaN), behält
# x86-64/SSE die Nutzlast des ersten Operanden der Maschinenanweisung
# (``addsd src, dst``: dst). Welcher Operand das ist, legt der C-Compiler fest,
# bei kommutativen Operationen auch entgegen der Quelltextfolge; CPython wählt
# wieder anders (``a + b`` behält b, ``a * b`` behält a). Ungültige Operationen
# (0/0, Inf - Inf, log oder sqrt einer negativen Zahl) liefern in C das
# Standard-NaN von x86 (Vorzeichen gesetzt, 0xFFF8000000000000), Python
# ``math.nan`` ist +NaN. Die Funktionen ``n_*`` rechnen eine Operation wie die
# SSE-Anweisung mit ``a`` als erstem Operanden; die reinen Python-Kerne nutzen
# sie auf ihrem NaN-genauen Weg mit der Operandenfolge aus dem Maschinencode des
# R-Baus (gcc -O2, x86-64).

_QUIET = 0x0008000000000000
X86_NAN = _PACK_D.unpack(_PACK_Q.pack(0xFFF8000000000000))[0]   # Standard-NaN (0/0) auf x86-64


def nan_quiet(x: float) -> float:
    """``x`` als stilles NaN (wie jede Gleitkomma-Operation es zurückgibt)."""
    return _PACK_D.unpack(_PACK_Q.pack(_PACK_Q.unpack(_PACK_D.pack(x))[0] | _QUIET))[0]


def _nn(r: float, a: float, b: float) -> float:
    if a != a and b != b:
        return nan_quiet(a)
    return r


def n_add(a: float, b: float) -> float:
    """``a + b`` (SSE, ``a`` erster Operand)."""
    return _nn(a + b, a, b)


def n_sub(a: float, b: float) -> float:
    """``a - b`` (SSE)."""
    return _nn(a - b, a, b)


def n_mul(a: float, b: float) -> float:
    """``a * b`` (SSE, ``a`` erster Operand)."""
    return _nn(a * b, a, b)


def n_div(a: float, b: float) -> float:
    """``a / b`` (SSE), auch für ``b == 0``."""
    if b == 0.0 or b != b or a != a:
        with np.errstate(all="ignore"):
            r = float(np.float64(a) / np.float64(b))
        return _nn(r, a, b)
    return a / b


def n_sqrt(x: float) -> float:
    """``sqrtsd`` bzw. glibc ``sqrt``: sqrt(NaN) = NaN (still), sqrt(<0) = Standard-NaN von x86."""
    if x >= 0.0:
        return math.sqrt(x)
    if x != x:
        return nan_quiet(x)
    return X86_NAN


def n_log(x: float) -> float:
    """glibc ``log``: log(NaN) = NaN (still), log(<0) und log(-Inf) = Standard-NaN von x86."""
    if x > 0.0:
        return math.log(x)
    if x == 0.0:
        return -math.inf
    if x != x:
        return nan_quiet(x)
    return X86_NAN


def n_exp(x: float) -> float:
    """glibc ``exp`` (NaN still, Überlauf Inf)."""
    if x != x:
        return nan_quiet(x)
    try:
        return math.exp(x)
    except OverflowError:
        return math.inf


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
# Summen, Mittelwerte, Varianzen (N8: C-Kerne core/slc_rbase.c, long double wie R)
# ═══════════════════════════════════════════════════════════════════════════

def _c64(x) -> np.ndarray:
    """Zusammenhängendes float64-Feld (eindimensional) für die C-Kerne."""
    return np.ascontiguousarray(np.asarray(x, dtype=np.float64).ravel())


def r_sum(x, na_rm: bool = False) -> float:
    """``sum(x)`` wie in R (long-double-Akkumulator, sequenziell)."""
    return _ext.slc_r_sum(_c64(x), 0, bool(na_rm))


def r_cumsum(x) -> np.ndarray:
    """``cumsum(x)`` wie in R (long-double-Akkumulator; NA/NaN über ``handleNaN``)."""
    a = _c64(x)
    out = np.empty(a.size)
    _ext.slc_r_cum(0, a, out)
    return out


def r_prod(x, na_rm: bool = False) -> float:
    """``prod(x)`` wie in R (long-double-Akkumulator)."""
    return _ext.slc_r_sum(_c64(x), 1, bool(na_rm))


def r_cumprod(x) -> np.ndarray:
    """``cumprod(x)`` wie in R (long-double-Akkumulator; NA/NaN über ``handleNaN``)."""
    a = _c64(x)
    out = np.empty(a.size)
    _ext.slc_r_cum(1, a, out)
    return out


def r_cummax(x) -> np.ndarray:
    """``cummax(x)`` wie in R (ab dem ersten NA/NaN über ``handleNaN``)."""
    a = _c64(x)
    out = np.empty(a.size)
    _ext.slc_r_cum(2, a, out)
    return out


def r_cummin(x) -> np.ndarray:
    """``cummin(x)`` wie in R."""
    a = _c64(x)
    out = np.empty(a.size)
    _ext.slc_r_cum(3, a, out)
    return out


def r_mean(x, na_rm: bool = False) -> float:
    """``mean(x)`` für Doubles wie R (Summe/n in long double plus Korrekturdurchlauf)."""
    a = _c64(x)
    if na_rm:
        a = _drop_na(a)
    return _ext.slc_r_sum(a, 2, False)


def r_mean_int(x) -> float:
    """``mean(x)`` für Integer-Vektoren wie in R (long-double Summe / n)."""
    return _ext.slc_r_mean_int(np.ascontiguousarray(np.asarray(x, dtype=np.int64).ravel()))


def r_var(x, na_rm: bool = False) -> float:
    """``var(x)`` (Pearson) wie R (NA bei fehlenden Werten oder n < 2)."""
    a = _c64(x)
    if na_rm:
        a = _drop_na(a)
    elif np.isnan(a).any():
        return NA_REAL
    return _ext.slc_r_sum(a, 3, False)


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


def _margsums(m, na_rm: bool, mean: bool, rows: bool) -> np.ndarray:
    m = np.asarray(m, dtype=np.float64)
    if m.ndim == 1:
        m = m.reshape(-1, 1)
    nr, nc = m.shape
    out = np.empty(nr if rows else nc)
    _ext.slc_r_margsums(np.ascontiguousarray(m.ravel(order="F")), nr, nc, bool(na_rm), bool(mean), bool(rows), out)
    return out


def r_rowsums(m: np.ndarray, na_rm: bool = False) -> np.ndarray:
    """``rowSums(m)`` wie in R (long-double-Akkumulator je Zeile, spaltenweise)."""
    return _margsums(m, na_rm, False, True)


def r_colsums(m: np.ndarray, na_rm: bool = False) -> np.ndarray:
    """``colSums(m)`` wie in R (long-double-Akkumulator je Spalte)."""
    return _margsums(m, na_rm, False, False)


# ═══════════════════════════════════════════════════════════════════════════
# Potenz, Exponentialfunktion, Rest
# ═══════════════════════════════════════════════════════════════════════════

def r_pow(x: float, y: float) -> float:
    """Skalares ``x ^ y`` wie R's ``R_POW``/``R_pow`` (C-Kern ``sl_r_pow1``, libm ``pow``)."""
    return _ext.slc_r_pow1(float(x), float(y))


def r_pow_vec(x, y: float) -> np.ndarray:
    """Elementweises ``x ^ y`` mit R-Semantik (C-Kern ``sl_r_pow``, libm ``pow``)."""
    a = _c64(x)
    out = np.empty(a.size)
    _ext.slc_r_pow(a, float(y), out)
    return out


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
