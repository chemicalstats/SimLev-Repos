"""Kerne für Kendalls Tau, Quantilsregression und HMM (Python-Hüllen).

Rufen aus ``core/research_core_impl.h`` (über ``simlev._ext``) ``.kendall_tau_core``,
``.quantile_reg_core`` und ``.hmm_forward_backward`` mit denselben Quellen wie R und Julia auf. Seit
1.0.0 entfallen die bitgleichen Python-Ports als Rückfall (``SIMLEV_NO_EXT=1``, samt der
Nachbildung von libstdc++ ``std::sort``) und der Port des DCC-Filters (``.dcc_filter``,
``chol_small``); den DCC-Filter rechnet die C-Bibliothek slc (:func:`simlev._lib.dcc_filter`).
"""
from __future__ import annotations

import numpy as np

from . import _ext

__all__ = ["kendall_tau_core", "quantile_reg_core", "hmm_forward_backward", "hmm_em", "goal_dp", "pbo_cscv", "QuantileRegError"]


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
    al, ga = np.empty((K, T)), np.empty((K, T))
    xi = np.empty((K, K))
    cs = np.empty(T)
    _ext.hmm_forward_backward(np.ravel(Bm, order="F"), T, K, np.ravel(Am, order="F"), Am.shape[0], p0a,
                              al, ga, xi, cs)
    al, ga = (np.ascontiguousarray(a.T) for a in (al, ga))
    return {"filtered": al, "smoothed": ga, "xi": np.ascontiguousarray(xi.T), "scale": cs}


def hmm_em(X, k, mu, S, A, n_iter, tol, ridge):
    """Baum-Welch-EM aus einem Startwert (R: ``.hmm_em_core``, seit 1.5.0): ``None`` bei Fehler, sonst dict
    ``mu``, ``S`` (Liste k Matrizen), ``A``, ``p0``, ``ll``, ``filtered``, ``smoothed``, ``lB``, ``iter``."""
    X = np.asarray(X, dtype=np.float64)
    Tn, d = X.shape
    k = int(k)
    f64 = lambda a: np.ascontiguousarray(np.ravel(np.asarray(a, dtype=np.float64), order="F"))  # noqa: E731
    mu_b = f64(np.asarray(mu, dtype=np.float64).reshape(k, d))
    S_b = np.ascontiguousarray(np.concatenate([f64(np.asarray(s, dtype=np.float64).reshape(d, d)) for s in S]))
    A_b = f64(np.asarray(A, dtype=np.float64).reshape(k, k))
    p0 = np.empty(k)
    out = [np.empty(Tn * k) for _ in range(3)]
    st, ll, it = _ext.hmm_em(f64(X), Tn, d, k, mu_b, S_b, A_b, p0, int(n_iter), float(tol), f64(ridge), *out)
    if st:
        return None
    mat = lambda b, nr, nc: np.ascontiguousarray(b.reshape(nc, nr).T)  # noqa: E731
    return {"mu": mat(mu_b, k, d), "S": [mat(S_b[j * d * d:(j + 1) * d * d], d, d) for j in range(k)],
            "A": mat(A_b, k, k), "p0": p0, "ll": ll, "filtered": mat(out[0], Tn, k), "smoothed": mat(out[1], Tn, k),
            "lB": mat(out[2], Tn, k), "iter": it}


def goal_dp(R, grid, cf, goal, wmin, wmax, start_value, tie_score):
    """Rückwärtsrekursion von ``planning_goal()`` (R: ``.goal_dp``, seit 1.5.0): dict ``static``, ``policy``
    (horizon x ng, ganzzahlig), ``value`` (ng x (horizon + 1)), ``p_dp``, ``collapsed`` (Zahl der approx-Aufrufe
    mit zusammengefassten gleichen log(grid)-Werten)."""
    R = np.asarray(R, dtype=np.float64)
    S, K = R.shape
    grid = np.ascontiguousarray(np.asarray(grid, dtype=np.float64).ravel())
    cf = np.ascontiguousarray(np.asarray(cf, dtype=np.float64).ravel())
    ng, h = grid.size, cf.size
    stat = np.empty(K)
    pol = np.empty(h * ng, dtype=np.int32)
    val = np.empty(ng * (h + 1))
    nc, p_dp = _ext.goal_dp(np.ascontiguousarray(np.ravel(R, order="F")), S, K, grid, cf, float(goal), float(wmin),
                            float(wmax), float(start_value),
                            np.ascontiguousarray(np.asarray(tie_score, dtype=np.float64).ravel()), stat, pol, val)
    return {"static": stat, "policy": pol.reshape(ng, h).T.astype(np.int64), "value": val.reshape(h + 1, ng).T.copy(),
            "p_dp": p_dp, "collapsed": nc}


def pbo_cscv(Bs, Ts, combos, half, metric, S, N):
    """Aufteilungen der CSCV von ``overfit_pbo()`` (R: ``.pbo_cscv``, seit 1.5.0): ``(lambda, is_best, oos_best,
    oos_median)``. ``Bs``: fünf Blocksummen S x N, ``Ts``: deren Spaltensummen, ``combos``: C x S/2 (1-basiert)."""
    Bv = np.ascontiguousarray(np.concatenate([np.ravel(np.asarray(B, dtype=np.float64), order="F") for B in Bs]))
    Tv = np.ascontiguousarray(np.concatenate([np.asarray(t, dtype=np.float64).ravel() for t in Ts]))
    cb = np.ascontiguousarray(np.asarray(combos, dtype=np.int32).ravel())     # je Aufteilung S/2 Blöcke
    C = cb.size // (int(S) // 2)
    out = [np.empty(C) for _ in range(4)]
    _ext.pbo_cscv(Bv, Tv, cb, float(half), ["sharpe", "sortino", "geometric", "mean"].index(metric), int(S), int(N),
                  *out)
    return tuple(out)


def wrapper_nav_core(G, day, yr, fee, pf, S, d0):
    """Tagesschleife des NAV von ``wrapper_nav()`` (R: ``.wrapper_nav_core``, seit 1.5.1; core/wrapper_core_impl.h):
    ``(bad, nav, gross, fee, perf_fee, perf_paid, hwm)``, ``bad`` -1 oder der erste Tag (0-basiert) ohne Anteilswert."""
    G = np.ascontiguousarray(G, dtype=np.float64)
    n = G.size
    out = [np.zeros(n) for _ in range(6)]
    bad = _ext.wrapper_nav_core(G, np.ascontiguousarray(day, dtype=np.float64), np.ascontiguousarray(yr, dtype=np.int32),
                                float(fee), float(pf), float(S), float(d0), *out)
    return (int(bad),) + tuple(out)

