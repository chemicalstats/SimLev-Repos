"""Optimierungskerne aus ``r/src/research_core.cpp`` (Python-Hüllen).

- :func:`proj_box_simplex`  exakte Projektion auf {w : sum w = 1, lo <= w <= hi}
  (Knickpunkt-Verfahren), ``.proj_box_simplex``
- :func:`qp_box_simplex`    min 0.5 w'Qw + c'w auf dem beschraenkten Simplex
  (FISTA mit adaptivem Neustart), ``.qp_box_simplex``
- :func:`min_cvar_core`     minimaler CVaR (geglaettete Rockafellar-Uryasev-
  Formulierung, FISTA mit Schrittweitensuche), ``.min_cvar_core``
- :func:`min_cdar_core`     minimaler CDaR (projizierter Subgradient),
  ``.min_cdar_core``

Es rechnen die gemeinsamen Kerne von R und Python (``core/research_core_impl.h`` über
``simlev._ext``, Etappe 7.3a). Die bitgleichen Python-Ports als Rückfall (``SIMLEV_NO_EXT=1``),
die Nachbildung von libstdc++ ``std::sort``/``std::nth_element`` und ``quantile7`` sind mit
Etappe 9.6c entfallen.
"""
from __future__ import annotations

import numpy as np

from . import _ext

__all__ = ["proj_box_simplex", "qp_box_simplex", "min_cvar_core", "min_cdar_core"]


def _c1(x):
    """Zahlenvektor als zusammenhängendes float64-Feld für den gemeinsamen Kern."""
    return np.ascontiguousarray(np.asarray(x, dtype=np.float64).ravel())


def _mat(R):
    """Matrix (Vektor als eine Spalte)."""
    R = np.asarray(R, dtype=np.float64)
    return R.reshape(-1, 1) if R.ndim == 1 else R


def proj_box_simplex(v, lo, hi):
    """``.proj_box_simplex(v, lo, hi)``: Projektion auf den beschraenkten Simplex."""
    va, la, ha = _c1(v), _c1(lo), _c1(hi)
    out = np.empty(va.size)
    _ext.proj_box_simplex(va, la, ha, out)
    return out


def qp_box_simplex(Q, cvec, lo, hi, w0, L, maxit, tol):
    """``.qp_box_simplex``: FISTA mit adaptivem Neustart fuer min 0.5 w'Qw + c'w."""
    Q = np.asarray(Q, dtype=np.float64)
    n = Q.shape[1]
    out = np.empty(n)
    _ext.qp_box_simplex(np.ravel(Q, order="F"), Q.shape[0], n, _c1(cvec), _c1(lo), _c1(hi), _c1(w0), float(L),
                        int(maxit), float(tol), out)
    return out


def min_cvar_core(R, alpha, lo, hi, w0, zeta0, scales, maxit):
    """``.min_cvar_core``: minimaler CVaR (geglaettet, FISTA mit Schrittweitensuche)."""
    R = _mat(R)
    T, N = R.shape
    out = np.empty(N)
    _ext.min_cvar_core(np.ravel(R, order="F"), T, N, float(alpha), _c1(lo), _c1(hi), _c1(w0), float(zeta0),
                       _c1(scales), int(maxit), out)
    return out


def min_cdar_core(R, alpha, lo, hi, iters):
    """``.min_cdar_core``: minimaler CDaR (projizierter Subgradient, bestes Iterat)."""
    R = _mat(R)
    T, N = R.shape
    out = np.empty(N)
    _ext.min_cdar_core(np.ravel(R, order="F"), T, N, float(alpha), _c1(lo), _c1(hi), int(iters), out)
    return out
