"""R-kompatible Numerik.

R akkumuliert Summen, Mittelwerte, Varianzen und Produkte intern mit
``long double`` (auf x86-64 Linux: 80-Bit-Extended-Precision). Damit die
Python-Portierung bitgleich zum R-Paket rechnet, bilden die Funktionen in
diesem Modul exakt diese Akkumulationsreihenfolge und -genauigkeit nach.

Auf Plattformen, auf denen ``numpy.longdouble`` nur 64 Bit breit ist
(z. B. macOS auf Apple Silicon, Windows), verhält sich R dort ebenfalls mit
64-Bit-``long double`` bzw. weicht in den letzten Bits ab; die Funktionen
bleiben korrekt, die Bitgleichheit ist dann plattformabhängig.
"""
from __future__ import annotations

import math

import numpy as np

LD = np.longdouble
_NAN = float("nan")


def _as_f64(x) -> np.ndarray:
    return np.asarray(x, dtype=np.float64).ravel()


def _drop_na(x: np.ndarray) -> np.ndarray:
    return x[~np.isnan(x)]


def r_sum(x, na_rm: bool = False) -> float:
    """``sum(x)`` wie in R (long-double-Akkumulator, sequenziell)."""
    a = _as_f64(x)
    if na_rm:
        a = _drop_na(a)
    if a.size == 0:
        return 0.0
    return float(np.cumsum(a, dtype=LD)[-1])


def r_cumsum(x) -> np.ndarray:
    """``cumsum(x)`` wie in R (long-double-Akkumulator)."""
    a = _as_f64(x)
    if a.size == 0:
        return a.copy()
    return np.cumsum(a, dtype=LD).astype(np.float64)


def r_prod(x, na_rm: bool = False) -> float:
    """``prod(x)`` wie in R (long-double-Akkumulator)."""
    a = _as_f64(x)
    if na_rm:
        a = _drop_na(a)
    if a.size == 0:
        return 1.0
    return float(np.cumprod(a, dtype=LD)[-1])


def r_mean(x, na_rm: bool = False) -> float:
    """``mean(x)`` für Doubles wie in R (Summe/n plus Korrekturdurchlauf)."""
    a = _as_f64(x)
    if na_rm:
        a = _drop_na(a)
    n = a.size
    if n == 0:
        return _NAN
    al = a.astype(LD)
    s = np.cumsum(al)[-1] / LD(n)
    if math.isfinite(float(s)):
        t = np.cumsum(al - s)[-1]
        s = s + t / LD(n)
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
    """``var(x)`` (Pearson) wie R's ``cov_complete1``."""
    a = _as_f64(x)
    if na_rm:
        a = _drop_na(a)
    elif np.isnan(a).any():
        return _NAN
    n = a.size
    if n <= 1:
        return _NAN
    al = a.astype(LD)
    xm = LD(_r_mean_ld(al))          # Mittelwert wird in R als double gespeichert
    d = al - xm
    s = np.cumsum(d * d)[-1]
    return float(s / LD(n - 1))


def r_sd(x, na_rm: bool = False) -> float:
    """``sd(x)`` wie in R: ``sqrt(var(x))``."""
    v = r_var(x, na_rm=na_rm)
    return math.sqrt(v) if not math.isnan(v) else _NAN


def r_rowsums(m: np.ndarray, na_rm: bool = False) -> np.ndarray:
    """``rowSums(m)`` wie in R (long-double-Akkumulator, spaltenweise)."""
    m = np.asarray(m, dtype=np.float64)
    if m.ndim == 1:
        m = m.reshape(-1, 1)
    acc = np.zeros(m.shape[0], dtype=LD)
    for j in range(m.shape[1]):
        col = m[:, j]
        if na_rm:
            acc = acc + np.where(np.isnan(col), 0.0, col).astype(LD)
        else:
            acc = acc + col.astype(LD)
    return acc.astype(np.float64)


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
            return (0.0 if y < 0 else (-math.inf if int(y) % 2 else math.inf))
    if not math.isfinite(y):
        if x >= 0:
            if y > 0:
                return math.inf if x >= 1 else 0.0
            return 0.0 if x >= 1 else math.inf
    return _NAN


def r_pow_vec(x, y: float) -> np.ndarray:
    """Elementweises ``x ^ y`` mit R-Semantik (libm, keine SIMD-Varianten)."""
    a = _as_f64(x)
    return np.fromiter((r_pow(v, y) for v in a), dtype=np.float64, count=a.size)


def r_mod1(x: float) -> float:
    """``x %% 1`` für endliche Doubles wie R's ``myfmod(x, 1)``."""
    x = float(x)
    if not math.isfinite(x):
        return _NAN
    q = x
    tmp = LD(x) - LD(math.floor(q)) * LD(1.0)
    return float(tmp - LD(math.floor(float(tmp))) * LD(1.0))
