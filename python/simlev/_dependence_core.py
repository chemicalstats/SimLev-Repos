"""Kerne für Kendalls Tau, Quantilsregression und HMM (Python-Hüllen).

Rufen aus ``core/research_core_impl.h`` (über ``simlev._ext``, Etappe 7.3a) ``.kendall_tau_core``,
``.quantile_reg_core`` und ``.hmm_forward_backward`` mit denselben Quellen wie R auf. Seit
Etappe 9.6c entfallen die bitgleichen Python-Ports als Rückfall (``SIMLEV_NO_EXT=1``, samt der
Nachbildung von libstdc++ ``std::sort``) und der Port des DCC-Filters (``.dcc_filter``,
``chol_small``); den DCC-Filter rechnet die C-Bibliothek slc (:func:`simlev._lib.dcc_filter`).
"""
from __future__ import annotations

import numpy as np

from . import _ext

__all__ = ["kendall_tau_core", "quantile_reg_core", "hmm_forward_backward", "QuantileRegError"]


class QuantileRegError(RuntimeError):
    """Fehler aus dem Quantilsregressions-Kern (Rcpp ``stop``)."""


def kendall_tau_core(x, y):
    """``.kendall_tau_core(x, y)``: Kendalls Tau-b in O(n log n)."""
    x = np.asarray(x, dtype=np.float64).ravel()
    y = np.asarray(y, dtype=np.float64).ravel()
    return _ext.kendall_tau_core(np.ascontiguousarray(x), np.ascontiguousarray(y))


def quantile_reg_core(y, X, tau, beta0, sc, tol, maxit):
    """``.quantile_reg_core``; liefert ``(beta, optimal)``."""
    y = np.asarray(y, dtype=np.float64).ravel()
    X = np.asarray(X, dtype=np.float64)
    if X.ndim == 1:
        X = X.reshape(-1, 1)
    n, p = X.shape
    beta = np.ascontiguousarray(np.asarray(beta0, dtype=np.float64).ravel())
    try:
        b, opt = _ext.quantile_reg_core(np.ascontiguousarray(y), np.ravel(X, order="F"), n, p, float(tau),
                                        beta, float(sc), float(tol), int(maxit))
    except ValueError as e:                 # Fehler des Kerns (stop)
        raise QuantileRegError(str(e)) from None
    if b is None:
        return np.zeros(0), None
    return np.frombuffer(b, dtype=np.float64), opt


def hmm_forward_backward(B, A, p0):
    """``.hmm_forward_backward(B, A, p0)`` → dict filtered, smoothed, xi, scale."""
    Bm = np.asarray(B, dtype=np.float64)
    T, K = Bm.shape
    Am = np.asarray(A, dtype=np.float64)
    p0a = np.ascontiguousarray(np.asarray(p0, dtype=np.float64).ravel())
    out = [np.empty((K, T)) for _ in range(3)]
    xi = np.empty((K, K))
    cs = np.empty(T)
    _ext.hmm_forward_backward(np.ravel(Bm, order="F"), T, K, np.ravel(Am, order="F"), Am.shape[0], p0a,
                              *out, xi, cs)
    al, ga = (np.ascontiguousarray(a.T) for a in (out[0], out[2]))
    return {"filtered": al, "smoothed": ga, "xi": np.ascontiguousarray(xi.T), "scale": cs}
