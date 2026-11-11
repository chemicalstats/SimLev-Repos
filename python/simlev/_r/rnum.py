# Herkunft:           übersetzt aus R 4.3.3, src/main/summary.c, cum.c, array.c, arithmetic.c
#                     (R_zeroin2/uniroot aus zeroin.c bzw. nlm.R entfallen, XIRR im Kern)
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang: Summen und Kumulationen rechnen die C-Kerne
#                     core/slc_rbase*.
"""R-kompatible Numerik (Kern der R-Nachbildung, Gegenstück zu ``julia/src/r/rnum.jl``).

Aufgabenteilung in ``simlev._r``: Dieses Modul ist die unterste Schicht und
importiert nichts aus ``simlev``. Es definiert ``NA_REAL`` (R's
``NA_real_``, die einzige Definition im Paket; öffentlich als ``simlev.NA``)
mit ``r_isna``/``r_isna_arr`` und die skalaren bzw. eindimensionalen
Engine-Hilfen mit ``r_``-Präfix: Summen, Mittel, Varianzen und Produkte in
long double und ``r_pow`` (``R_POW``; ``r_uniroot`` ist entfallen: XIRR im Kern
``core/evaluate_core_impl.h``; ``r_mod1`` und ``r_cummin`` seit 1.6.1, ohne Aufrufer). Darauf bauen auf:

- :mod:`simlev._r.rformat`: ``r_round``, ``r_signif``, ``r_format``,
  ``r_as_character``, ``r_deparse``, ``r_sprintf`` (Textausgabe der Engine),
- :mod:`simlev._r.base`: re-exportiert die Summenhilfen und ergänzt
  Funktionen von R's base mit R-Namen für Vektoren, Matrizen und DataFrames
  (``mean``, ``diff``, ``pmin``, ``range``), dazu
  ``quiet_fp`` (Gleitkomma-Warnungen bei NA unterdrücken, ``env`` aus dem
  Aufrufer) und ``sys_time``,
- :mod:`simlev._r.fmt`: die volle Formatierung (``format``, ``formatC``,
  ``print``).

R akkumuliert Summen, Mittelwerte, Varianzen und Produkte intern mit
``long double`` (auf x86-64 Linux: 80-Bit-Extended-Precision). rechnen
``r_sum``, ``r_prod``, ``r_mean``, ``r_var``, die Kumulationen, ``r_rowsums``/
``r_colsums`` und ``r_pow_vec`` mit den C-Kernen ``core/slc_rbase.cpp`` (über
:mod:`simlev._ext`), die Julia ebenso nutzt; sie akkumulieren in long double
wie R und sind gegen R bitgleich geprüft.

Transzendente Funktionen: immer ``math.*`` (glibc-libm wie R), nie die
SIMD-Varianten von numpy (``np.exp``, ``np.log``, ``np.power`` …), die auf
Rechnern mit AVX-512 in den letzten Bits abweichen können.

rechnet Python nirgends mehr mit ``numpy.longdouble``: auch ``%%``
(:mod:`simlev._r.rexpr`), ``R_strtod`` (:mod:`simlev._r.rexpr`) und ``scientific()``
(:mod:`simlev._r.fmt`, :mod:`simlev._r.rformat`) nutzen die C-Kerne
``core/slc_rbase_num.cpp``, wie Julia. Auf Plattformen, deren
C-``long double`` nur 64 Bit breit ist (z. B. macOS auf Apple Silicon,
Windows), verhält sich R dort ebenso; die Bitgleichheit ist dann
plattformabhängig.
"""
from __future__ import annotations

import math
import struct

import numpy as np

from .. import _ext   # C-Erweiterung (Kerne core/slc_rbase*.cpp)

_NAN = float("nan")

__all__ = [
    "NA_REAL", "r_isna", "r_isna_arr", "r_sum", "r_cumsum", "r_prod", "r_cumprod", "r_mean", "r_mean_int", "r_var",
    "r_sd", "r_rowsums", "r_colsums", "r_rowmeans", "r_colmeans", "r_pow", "r_pow_vec", "r_median", "r_cummax",
    "r_strtod", "r_string_to_real",
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


def _bits(x: float) -> int:
    return _PACK_Q.unpack(_PACK_D.pack(x))[0]


def r_isna(x) -> bool:
    """``R_IsNA(x)``: True nur für R's NA (NaN mit Nutzlast 1954), nicht für NaN."""
    x = float(x)
    return x != x and (_bits(x) & 0xFFFFFFFF) == 1954


def r_isna_arr(a) -> np.ndarray:
    """Maske ``R_IsNA`` für ein Array."""
    a = np.ascontiguousarray(a, dtype=np.float64)
    return np.isnan(a) & ((a.view(np.uint64) & np.uint64(0xFFFFFFFF)) == np.uint64(1954))


# ═══════════════════════════════════════════════════════════════════════════
# Summen, Mittelwerte, Varianzen (C-Kerne core/slc_rbase.cpp, long double wie R)
# ═══════════════════════════════════════════════════════════════════════════

def _c64(x) -> np.ndarray:
    """Zusammenhängendes float64-Feld (eindimensional) für die C-Kerne."""
    return np.ascontiguousarray(np.asarray(x, dtype=np.float64).ravel())


def _text(x, kind):
    """Text wie R (seit 1.6.4, C-060; bis 1.6.3 wandelte numpy Ziffern-Text still in Zahlen): ``kind`` "sum" Fehler
    (sum, prod), "mean" NA mit Warnung, "num" Umwandlung wie as.numeric (NA mit Warnung bei Nicht-Zahlen; cumsum,
    cumprod, cummax, var, sd). Ergebnis: x unverändert (kein Text), sonst die Zahlen bzw. None (mean)."""
    from .libm import _is_text
    if not _is_text(x):
        return x
    if kind == "sum":
        from .linalg import RError
        raise RError("invalid 'type' (character) of argument")
    if kind == "mean":
        import warnings
        warnings.warn("argument is not numeric or logical: returning NA")
        return None
    from .rexpr import as_numeric
    return as_numeric(list(np.asarray(x, dtype=object).ravel()) if not isinstance(x, str) else [x])


def r_sum(x, na_rm: bool = False) -> float:
    """``sum(x)`` wie in R (long-double-Akkumulator, sequenziell)."""
    return _ext.slc_r_sum(_c64(_text(x, "sum")), 0, bool(na_rm))


def r_cumsum(x) -> np.ndarray:
    """``cumsum(x)`` wie in R (long-double-Akkumulator; NA/NaN über ``handleNaN``)."""
    a = _c64(_text(x, "num"))
    out = np.empty(a.size)
    _ext.slc_r_cum(0, a, out)
    return out


def r_prod(x, na_rm: bool = False) -> float:
    """``prod(x)`` wie in R (long-double-Akkumulator)."""
    return _ext.slc_r_sum(_c64(_text(x, "sum")), 1, bool(na_rm))


def r_cumprod(x) -> np.ndarray:
    """``cumprod(x)`` wie in R (long-double-Akkumulator; NA/NaN über ``handleNaN``)."""
    a = _c64(_text(x, "num"))
    out = np.empty(a.size)
    _ext.slc_r_cum(1, a, out)
    return out


def r_cummax(x) -> np.ndarray:
    """``cummax(x)`` wie in R (ab dem ersten NA/NaN über ``handleNaN``)."""
    a = _c64(_text(x, "num"))
    out = np.empty(a.size)
    _ext.slc_r_cum(2, a, out)
    return out


def r_mean(x, na_rm: bool = False) -> float:
    """``mean(x)`` für Doubles wie R (Summe/n in long double plus Korrekturdurchlauf)."""
    x = _text(x, "mean")
    if x is None:
        return NA_REAL
    a = _c64(x)
    if na_rm:
        a = _drop_na(a)
    return _ext.slc_r_sum(a, 2, False)


def r_mean_int(x) -> float:
    """``mean(x)`` für Integer-Vektoren wie in R (long-double Summe / n)."""
    return _ext.slc_r_mean_int(np.ascontiguousarray(np.asarray(x, dtype=np.int64).ravel()))


def r_var(x, na_rm: bool = False) -> float:
    """``var(x)`` (Pearson) wie R (NA bei fehlenden Werten oder n < 2)."""
    a = _c64(_text(x, "num"))
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
    """``stats::median(x)`` für Zahlen: Kern ``sl_r_median`` (Teilsortierung wie R's ``rPsort2``, Mittel der beiden
    mittleren Werte mit long double). Seit 1.6.3 über den Kern statt ``np.sort``: bei ±0 in der Mitte stimmt das
    Vorzeichen der Null wie in R (``np.sort`` ordnet −0 und +0 anders als R's Teilsortierung)."""
    r = _ext.slc_r_median(np.ascontiguousarray(_as_f64(x)), bool(na_rm), False)
    return NA_REAL if r is None else r   # x[NA_integer_] bzw. leer


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


def r_rowmeans(m: np.ndarray, na_rm: bool = False) -> np.ndarray:
    """``rowMeans(m)`` wie in R (Kern wie ``r_rowsums``, Summe / Anzahl in long double)."""
    return _margsums(m, na_rm, True, True)


def r_colmeans(m: np.ndarray, na_rm: bool = False) -> np.ndarray:
    """``colMeans(m)`` wie in R (Kern wie ``r_colsums``, Summe / Anzahl in long double)."""
    return _margsums(m, na_rm, True, False)


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


# ═══════════════════════════════════════════════════════════════════════════
# R_strtod und String_to_real (bis 1.2.0 in rexpr.py bzw. mit float() in fmt.py)
# ═══════════════════════════════════════════════════════════════════════════

_SPACE_C = frozenset(" \t\n\v\f\r")
_NUMCHARS = frozenset("0123456789abcdefABCDEF.xXpPeE+-")


def r_strtod(cs, i0: int = 0):
    """R's ``R_strtod`` (NA = FALSE) auf ``cs`` (Text oder Zeichenliste) ab Index ``i0`` (0-basiert).

    Rückgabe ``(Wert, Endindex)``; ohne Ziffer ``(NA, i0)``. Leerraum, Vorzeichen, ``NaN``/``Inf``/``infinity``
    (Groß-/Kleinschreibung egal) prüft der Host; der Zahlteil (dezimal mit Exponent, hexadezimal mit Punkt und
    p-Exponent) rechnet der C-Kern ``sl_r_strtod_num`` (core/slc_rbase_num.cpp) in long double. Betrag über
    DBL_MAX (in long double) ergibt ±Inf wie R."""
    n = len(cs)

    def at(k):
        return cs[k] if k < n else "\0"

    p = i0
    while at(p) in _SPACE_C:
        p += 1
    sign = 1.0
    if at(p) == "-":
        sign = -1.0
        p += 1
    elif at(p) == "+":
        p += 1

    def low(k, m):
        return "".join(cs[k:min(n, k + m)]).lower()

    if low(p, 3) == "nan":
        return (math.nan, p + 3)              # R: NaN ohne Vorzeichen (0x7FF8000000000000)
    if low(p, 8) == "infinity":
        return (sign * math.inf, p + 8)
    if low(p, 3) == "inf":
        return (sign * math.inf, p + 3)
    # Übergeben werden die Zeichen, die der Kern lesen kann (ASCII, gelesene Bytes = Zeichen), und ein weiteres:
    # "0x" gilt wie in R nur, wenn danach noch etwas folgt.
    q = p
    while q < n and cs[q] in _NUMCHARS:
        q += 1
    v, used, gt = _ext.slc_r_strtod_num("".join(cs[p:q + 1]).encode("utf-8", "surrogatepass"))
    if used < 0:
        return (NA_REAL, i0)
    if gt:
        v = math.inf
    return (sign * v, p + used)


def r_string_to_real(s):
    """``String_to_real`` (``as.numeric(<Text>)``): (Wert, ungültig?). NA und leere bzw. nur aus Leerraum
    bestehende Texte ergeben NA ohne Warnung, ungültige Texte (auch "NA" als Text) NA mit Warnung (ungültig)."""
    if s is None:
        return (NA_REAL, False)
    if all(c in _SPACE_C for c in s):
        return (NA_REAL, False)
    v, e = r_strtod(s, 0)
    if all(c in _SPACE_C for c in s[e:]):
        return (v, False)
    return (NA_REAL, True)
