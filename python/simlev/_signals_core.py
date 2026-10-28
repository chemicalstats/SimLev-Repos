"""Rollierende Kerne aus ``r/src/research_core.cpp`` (``.roll_mean_core``, ``.roll_cov_core``).

Python-Hüllen um die gemeinsamen Kerne von R und Python (``core/research_core_impl.h`` über
``simlev._ext``, Etappe 7.3a). Die bitgleichen Python-Ports als Rückfall (``SIMLEV_NO_EXT=1``)
sind mit Etappe 9.6c entfallen.
"""
from __future__ import annotations


import numpy as np

from . import _ext

__all__ = ["roll_mean_core", "roll_cov_core"]

_I32 = 2147483647


def _n32(n):
    """Fensterlänge wie R's ``as.integer`` für den Kern: außerhalb von int32 bleibt sie außerhalb von
    1 … Länge (der Kern liefert dann nur NA)."""
    return min(max(int(n), -_I32 - 1), _I32)


def roll_mean_core(x, n):
    """``.roll_mean_core(x, n)``: rollierender Mittelwert mit kompensierter Summe (Neumaier).

    Fenster der Länge ``n`` einschließlich der aktuellen Zeile; NA für
    Fenster mit nicht endlichen Werten. Die Summe wird alle 4096 Schritte neu
    aufgebaut.
    """
    x = np.asarray(x, dtype=np.float64).ravel()
    out = np.empty(x.size)
    _ext.roll_mean_core(np.ascontiguousarray(x), _n32(n), out)
    return out


def roll_cov_core(x, y, n):
    """``.roll_cov_core(x, y, n)``: rollierende Kovarianz (Populationsform, Zwei-Pass).

    ``(sum(dx*dy) - sum(dx)*sum(dy)/n) / n`` je Fenster; NA, wenn das Fenster
    einen nicht endlichen Wert enthält.
    """
    x = np.asarray(x, dtype=np.float64).ravel()
    y = np.asarray(y, dtype=np.float64).ravel()
    out = np.empty(x.size)
    _ext.roll_cov_core(np.ascontiguousarray(x), np.ascontiguousarray(y), _n32(n), out)
    return out


# R's NA_real_ ist ein signalisierendes NaN; numpy-Warnungen "invalid value" unterdrücken (R kennt sie nicht).
roll_mean_core = np.errstate(invalid="ignore")(roll_mean_core)
roll_cov_core = np.errstate(invalid="ignore")(roll_cov_core)
