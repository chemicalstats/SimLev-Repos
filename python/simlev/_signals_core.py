"""Rollierende Kerne aus ``r/src/research_core.cpp`` (``.roll_mean_core``, ``.roll_cov_core``).

Bitgleiche Nachbildung der C++-Fassungen (double-Arithmetik in derselben
Reihenfolge).
"""
from __future__ import annotations

import math

import numpy as np

from ._r.fmt import NA_REAL

__all__ = ["roll_mean_core", "roll_cov_core"]

_NAN = NA_REAL   # R-NA_real_


def roll_mean_core(x, n):
    """``.roll_mean_core(x, n)``: rollierender Mittelwert mit kompensierter Summe (Neumaier).

    Fenster der Länge ``n`` einschließlich der aktuellen Zeile; NA für
    Fenster mit nicht endlichen Werten. Die Summe wird alle 4096 Schritte neu
    aufgebaut.
    """
    x = np.asarray(x, dtype=np.float64).ravel()
    m = x.size
    n = int(n)
    out = np.full(m, _NAN)
    if n < 1 or n > m:
        return out
    xs = x.tolist()
    fin = np.isfinite(x).tolist()
    s = 0.0
    comp = 0.0
    bad = 0

    def rebuild(end):
        nonlocal s, comp, bad
        s = 0.0
        comp = 0.0
        bad = 0
        for k in range(end - n + 1, end + 1):
            if fin[k]:
                v = xs[k]
                t = s + v
                if abs(s) >= abs(v):
                    comp += (s - t) + v
                else:
                    comp += (v - t) + s
                s = t
            else:
                bad += 1

    rebuild(n - 1)
    res = out.tolist()
    res[n - 1] = _NAN if bad else (s + comp) / n
    for i in range(n, m):
        if (i - n) % 4096 == 4095:
            rebuild(i)
        else:
            if fin[i]:
                v = xs[i]
                t = s + v
                if abs(s) >= abs(v):
                    comp += (s - t) + v
                else:
                    comp += (v - t) + s
                s = t
            else:
                bad += 1
            if fin[i - n]:
                v = -xs[i - n]
                t = s + v
                if abs(s) >= abs(v):
                    comp += (s - t) + v
                else:
                    comp += (v - t) + s
                s = t
            else:
                bad -= 1
        res[i] = _NAN if bad else (s + comp) / n
    return np.array(res, dtype=np.float64)


def roll_cov_core(x, y, n):
    """``.roll_cov_core(x, y, n)``: rollierende Kovarianz (Populationsform, Zwei-Pass).

    ``(sum(dx*dy) - sum(dx)*sum(dy)/n) / n`` je Fenster; NA, wenn das Fenster
    einen nicht endlichen Wert enthält.
    """
    x = np.asarray(x, dtype=np.float64).ravel()
    y = np.asarray(y, dtype=np.float64).ravel()
    m = x.size
    n = int(n)
    out = np.full(m, _NAN)
    if n < 1 or n > m or y.size != m:
        return out
    w = m - n + 1                                   # Fenster i = n-1 .. m-1
    okx = np.isfinite(x) & np.isfinite(y)
    sx = np.zeros(w)
    sy = np.zeros(w)
    bad = np.zeros(w, dtype=bool)
    for k in range(n):                              # gleiche Summationsreihenfolge je Fenster
        sx = sx + x[k:k + w]
        sy = sy + y[k:k + w]
        bad |= ~okx[k:k + w]
    mx = sx / n
    my = sy / n
    c = np.zeros(w)
    cx = np.zeros(w)
    cy = np.zeros(w)
    for k in range(n):
        dx = x[k:k + w] - mx
        dy = y[k:k + w] - my
        c = c + dx * dy
        cx = cx + dx
        cy = cy + dy
    res = (c - cx * cy / n) / n
    res[bad] = _NAN
    out[n - 1:] = res
    return out


# R's NA_real_ ist ein signalisierendes NaN; numpy-Warnungen "invalid value" unterdrücken (R kennt sie nicht).
roll_mean_core = np.errstate(invalid="ignore")(roll_mean_core)
roll_cov_core = np.errstate(invalid="ignore")(roll_cov_core)
