"""Portfolio-Optimierung und Risikozerlegung (Port von ``r/R/optimize.R``).

- :func:`portfolio_optimize`    Minimum-Varianz, Mean-Variance, maximale Sharpe Ratio,
  maximale Diversifikation, Risikoparität (Risikobudgets), Hierarchical Risk Parity,
  minimaler CVaR/CDaR, inverse Volatilität, Gleichgewichtung; Box-Grenzen,
  Kovarianzschätzer (Stichprobe, Ledoit-Wolf, EWMA, Rauschfilter, Gerber),
  Resampling (Michaud)
- :func:`efficient_frontier`    Effizienzgrenze unter denselben Grenzen
- :func:`rolling_optimization`  Optimierung in rollierenden Fenstern -> Zielgewichte
  für :func:`simlev.tactical_simulation`
- :func:`risk_contributions`    Euler-Zerlegung von Volatilität bzw. CVaR
- :func:`cpcv_portfolio`        kombinatorische Kreuzvalidierung (CPCV)

Löser ohne Zusatzpakete (Kerne in :mod:`simlev._optimize_core`): FISTA auf dem
beschränkten Simplex, gedämpftes Newton-Verfahren für die Risikoparität,
geglätteter CVaR, Clusterbaum (``hclust`` "single") für HRP.
"""
from __future__ import annotations

import itertools
import math
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

from . import _optimize_core as _core
from ._r import fmt as _fmt
from ._r import libm as _libm
from ._r import linalg as _la
from ._r.rlist import RList
from ._r.rnum import r_mean, r_pow, r_sd
from .tactical import (
    _as_dates, _as_weights_m, _colmeans, _days, _fmt1, _hold_rows_m, _ldsum, _mean_int,
    _period_last, _rowsums, _setdiff, _unique,
)
from .svg import _alloc_c, _alloc_ticks, _esc, _jl_max, _jl_min, _jl_str

__all__ = ["portfolio_optimize", "efficient_frontier", "rolling_optimization", "risk_contributions",
           "cpcv_portfolio", "SimLevOptimization", "SimLevFrontier", "SimLevCPCV", "SimLevBoundsPercent",
           "print_SimLevOptimization", "print_SimLevFrontier", "print_SimLevCPCV",
           "plot_SimLevOptimization", "plot_SimLevFrontier"]

LD = np.longdouble
_NAN = float("nan")      # R's NaN
_NA = _fmt.NA_REAL       # R's NA_real_

_METHODS = ("min_variance", "max_sharpe", "mean_variance", "max_diversification", "risk_parity", "hrp",
            "min_cvar", "min_cdar", "inverse_vol", "equal")
_COVS = ("sample", "ledoit_wolf", "ewma", "denoise", "gerber")
_FREQS = ("week", "day", "month")
_PO_FORMALS = ("x", "assets", "method", "lower", "upper", "cov", "mu", "risk_free", "risk_aversion", "budget",
               "alpha", "frequency", "resample", "block", "seed")


class SimLevBoundsPercent(UserWarning):
    """Warnklasse für Obergrenzen > 1 (vermutlich Prozent statt Anteil)."""


def _warn(msg, cat=UserWarning):
    warnings.warn(msg, cat, stacklevel=3)


def _st():
    from ._r import stats
    return stats


def _match_arg(arg, choices):
    from .data_prep import _match_arg as m
    return m(arg, choices)


# ── kleine R-Hilfen ──────────────────────────────────────────────────────

class _Mat:
    """Numerische Matrix mit Spaltennamen (intern)."""

    __slots__ = ("a", "cn")

    def __init__(self, a, cn):
        self.a = np.asarray(a, dtype=np.float64)
        self.cn = list(cn)


def _df(M, cn):
    return pd.DataFrame(np.asarray(M, dtype=np.float64), columns=list(cn))


def _cov(R):
    """``stats::cov`` (Matrix -> ndarray)."""
    return np.asarray(_st().cov(np.asarray(R, dtype=np.float64)), dtype=np.float64)


def _col_means(R):
    return _colmeans(np.asarray(R, dtype=np.float64))


def _mp(x, y):
    """``x %*% y`` (Ergebnis ndarray)."""
    return np.asarray(_la.matprod(x, y), dtype=np.float64)


def _mat_vec(R, w):
    """``drop(R %*% w)``."""
    return _mp(np.asarray(R, dtype=np.float64), np.asarray(w, dtype=np.float64).ravel()).ravel()


def _quad(w, S):
    """``drop(t(w) %*% S %*% w)``."""
    w = np.asarray(w, dtype=np.float64).ravel()
    return float(_mp(_mp(w.reshape(1, -1), S), w).ravel()[0])


def _quantile(x, p):
    q = _st().quantile(np.asarray(x, dtype=np.float64).ravel(), p, names=False, type=7)
    return float(np.asarray(q, dtype=np.float64).ravel()[0])


def _sum(x):
    return _ldsum(x)


def _sumsq_f(A):
    """``sum(A^2)`` einer Matrix (spaltenweise Reihenfolge, long double)."""
    a = np.asarray(A, dtype=np.float64).ravel(order="F")
    return _ldsum(a * a)


def _named_vec(x):
    """Benannter Vektor -> (Namen oder None, Werte als object/float, numerisch?)."""
    if isinstance(x, pd.Series):
        nm = None if isinstance(x.index, pd.RangeIndex) else [str(k) for k in x.index]
        vals = list(x.to_numpy(dtype=object))
    elif isinstance(x, Mapping):
        nm = [str(k) for k in x.keys()]
        vals = list(x.values())
    elif x is None:
        return None, [], False
    elif isinstance(x, (str, bytes)) or np.ndim(x) == 0:
        nm, vals = None, [x]
    else:
        nm, vals = None, list(np.asarray(x, dtype=object).ravel())
    isnum = all(v is None or (isinstance(v, (int, float, np.integer, np.floating)) and not isinstance(v, (bool, np.bool_)))
                for v in vals)
    return nm, vals, isnum


def _isna(v):
    return v is None or (isinstance(v, (float, np.floating)) and math.isnan(v))


def _fmt_vals(vals, isnum):
    if isnum:
        return _fmt1(np.array([_NA if v is None else float(v) for v in vals], dtype=np.float64))
    return ["NA" if _isna(v) else str(v) for v in vals]


def _sprintf(fmt, *args):
    return _fmt.sprintf(fmt, *args)


# ═══════════════════════════════════════════════════════════════════════════
# Renditen, Prüfungen
# ═══════════════════════════════════════════════════════════════════════════

class _OptReturns(dict):
    """Interne Renditen mit ppy (R-Klasse ``SimLevOptReturns``, cpcv_portfolio)."""


def _is_numeric_col(s):
    return s.dtype.kind in "iuf"


def _opt_returns(x, assets=None, frequency="week"):
    """``.opt_returns``: Periodenrenditen (einfach) -> {R (DataFrame), ppy, dates}."""
    if isinstance(x, _OptReturns):
        R = x["R"]
        if assets is not None:
            R = R[[str(a) for a in assets]]
        return {"R": R, "ppy": x["ppy"], "dates": None}
    if isinstance(x, pd.DataFrame) and "date" in [str(c) for c in x.columns]:
        if assets is None:
            assets = [str(c) for c in x.columns if _is_numeric_col(x[c]) and str(c) != "date"]
        assets = [str(a) for a in assets]
        from .dependence import _dep_returns
        rd = _dep_returns(x, assets, None, frequency)
        L = rd[assets].to_numpy(dtype=np.float64) if assets else np.zeros((len(rd), 0))
        R = pd.DataFrame(_libm.expm1(L).reshape(L.shape), columns=assets)
        dd = _days(np.asarray(rd["date"]))
        nr = len(rd)
        with np.errstate(all="ignore"):
            ppy = (nr - 1) / ((dd[nr - 1] - dd[0]) / 365.25) if nr else _NAN
        return {"R": R, "ppy": float(ppy), "dates": rd["date"].to_numpy()}
    if isinstance(x, pd.DataFrame):
        cn = [str(c) for c in x.columns] if not isinstance(x.columns, pd.RangeIndex) else None
        isnum = all(_is_numeric_col(x[c]) or x[c].dtype == bool for c in x.columns)
        A = x.to_numpy(dtype=np.float64) if isnum else x.to_numpy(dtype=object)
    else:
        A = np.asarray(x)
        if A.ndim == 1:
            A = A.reshape(-1, 1)
        cn = None
        isnum = A.dtype.kind in "iufb"
        if A.dtype == object:
            isnum = all(isinstance(v, (int, float, np.integer, np.floating)) and not isinstance(v, bool) for v in A.ravel())
            if isnum:
                A = A.astype(np.float64)
        elif isnum:
            A = A.astype(np.float64)
    if cn is None:
        cn = ["A%d" % (j + 1) for j in range(A.shape[1])]
    if assets is not None:
        assets = [str(a) for a in ([assets] if isinstance(assets, str) else assets)]
        miss = _setdiff(assets, cn)
        if miss:
            raise ValueError("Spalten fehlen: %s" % ", ".join(miss))
        A = A[:, [cn.index(a) for a in assets]]
        cn = assets
    if not isnum:
        raise ValueError("x muss Kursdaten mit Spalte 'date' oder eine numerische Renditematrix sein.")
    A = np.asarray(A, dtype=np.float64)
    _opt_check_finite(A, cn)
    ok = ~np.isnan(A).any(axis=1)
    ppy = {"day": 252, "week": 52, "month": 12}[frequency]
    return {"R": pd.DataFrame(A[ok, :], columns=cn), "ppy": ppy, "dates": None}


def _opt_check_finite(A, cn):
    """``.opt_check_finite``: unendliche Renditen mit Spalte und Zeile melden."""
    inf = np.isinf(A)
    if not inf.any():
        return
    pos = np.argwhere(inf.T)               # (Spalte, Zeile), spaltenweise wie which(arr.ind = TRUE)
    cols = _unique([cn[j] for j, _ in pos])
    j0 = pos[0][0]
    first = int(min(i for j, i in pos if j == j0)) + 1
    raise ValueError("x: unendliche Rendite(n) (Inf/-Inf) in der Renditematrix, Spalte(n) %s (%d Wert(e), erster in "
                     "Zeile %d); Renditen als endliche Anteile angeben (fehlende Werte als NA)."
                     % (", ".join("'%s'" % c for c in cols), len(pos), first))


def _opt_check_alpha(alpha, fn):
    """``.opt_check_alpha``: Tail-Wahrscheinlichkeit als Anteil in (0, 0.5]."""
    nm, vals, isnum = _named_vec(alpha)
    one = isnum and len(vals) == 1 and vals[0] is not None and math.isfinite(float(vals[0]))
    if one and float(vals[0]) > 0 and float(vals[0]) <= 0.5:
        return
    hint = ""
    if one:
        a = float(vals[0])
        if a >= 1:
            hint = _sprintf(" - als Anteil angeben (z. B. %g statt %g)", a / 100, a)
        elif a > 0.5:
            hint = _sprintf(" - gemeint ist der Tail-Anteil, nicht das Konfidenzniveau (%g -> alpha = %g)", a, 1 - a)
    raise ValueError("%s: alpha muss die Tail-Wahrscheinlichkeit als Anteil in (0, 0.5] sein, z. B. 0.05 = schlechteste "
                     "5 %% (erhalten: %s)%s." % (fn, ", ".join(_fmt_vals(vals, isnum)), hint))


def _opt_bounds(b, nm, default, what="upper"):
    """``.opt_bounds``: Skalar, benannter oder positionsweiser Vektor -> Wert je Anlage."""
    names, vals, isnum = _named_vec(b)
    if not isnum or not len(vals) or any(_isna(v) for v in vals):
        raise ValueError("%s: numerischer Wert bzw. Vektor ohne NA erwartet (erhalten: %s)."
                         % (what, ", ".join(_fmt_vals(vals, isnum))))
    v = np.array([float(x) for x in vals], dtype=np.float64)
    if names is None:
        if len(v) == 1:
            return np.repeat(v[0], len(nm))
        if len(v) == len(nm):
            return v
        raise ValueError("%s: unbenannter Vektor der Länge %d passt nicht zu %d Anlagen (Skalar, benannter Vektor "
                         "oder ein Wert je Anlage in Spaltenreihenfolge)." % (what, len(v), len(nm)))
    unk = _setdiff(names, nm)
    if unk:
        raise ValueError("%s: unbekannte Anlage(n) %s; vorhanden: %s." % (what, ", ".join("'%s'" % u for u in unk),
                                                                         ", ".join(nm)))
    out = np.repeat(float(default), len(nm))
    for k, x in zip(names, v):
        out[nm.index(k)] = x
    return out


def _opt_check_bounds(lower, upper, nm):
    """``.opt_check_bounds``: Unter- und Obergrenzen prüfen (Long-only, erfüllbar)."""
    lo = _opt_bounds(lower, nm, 0, "lower")
    hi = _opt_bounds(upper, nm, 1, "upper")
    hi[hi == math.inf] = 1.0
    if (hi > 1).any():
        big = np.flatnonzero(hi > 1)
        fb = _fmt1(hi[big])
        _warn("upper: Obergrenze(n) > 1 (%s); Grenzen sind Anteile (0.26 = 26 %%), Werte > 1 wirken wie 1. "
              "Prozentangabe? Dann durch 100 teilen." % ", ".join("%s = %s" % (nm[i], s) for i, s in zip(big, fb)),
              SimLevBoundsPercent)
    if (lo < 0).any():
        raise ValueError("lower: Untergrenzen müssen >= 0 sein (Long-only; erhalten %s)." % ", ".join(_fmt1(lo[lo < 0])))
    slo = _sum(lo)
    shi = _sum(hi)
    if slo > 1 + 1e-12 or shi < 1 - 1e-12 or (lo > hi).any():
        raise ValueError(_sprintf("Grenzen nicht erfüllbar (sum(lower) <= 1 <= sum(upper) und lower <= upper; hier "
                                  "sum(lower) = %g, sum(upper) = %g).", slo, shi))
    return lo, hi


def _opt_flat(S, nm):
    d = np.diag(S)
    return [nm[i] for i in range(len(nm)) if math.sqrt(max(d[i], 0.0)) <= 1e-10]


# ═══════════════════════════════════════════════════════════════════════════
# Kovarianzschätzer
# ═══════════════════════════════════════════════════════════════════════════

def _psd(M, N):
    e = _la.eigen(M, symmetric=True)
    V = np.asarray(e["vectors"], dtype=np.float64)
    vals = np.asarray(e["values"], dtype=np.float64)
    D = _la.diag(np.maximum(vals, 1e-12), N)
    M2 = _mp(_mp(V, D), V.T)
    return (M2 + M2.T) / 2


def _opt_cov_m(R, type):  # noqa: A002
    """``.opt_cov`` auf einer float-Matrix (ndarray)."""
    R = np.asarray(R, dtype=np.float64)
    S = _cov(R)
    Tn, N = R.shape
    if type == "sample" or N < 2:
        return S
    if type == "ledoit_wolf":
        X = R - _colmeans(R)[None, :]
        S1 = np.asarray(_la.crossprod(X), dtype=np.float64) / Tn
        m = _sum(np.diag(S1)) / N
        dm = _la.diag(m, N)

        def nrm(A):
            return _sumsq_f(A) / N

        d2 = nrm(S1 - dm)
        acc = np.empty(Tn)
        for t in range(Tn):
            acc[t] = nrm(np.outer(X[t, :], X[t, :]) - S1)
        b2 = min(d2, _sum(acc) / (Tn * Tn))
        a2 = d2 - b2
        Sh = (b2 / d2) * dm + (a2 / d2) * S1
        return Sh * Tn / (Tn - 1)
    if type == "ewma":
        hl = min(52, max(5, Tn / 4))
        lam = r_pow(0.5, 1 / hl)
        w = np.array([r_pow(lam, float(k)) for k in range(Tn - 1, -1, -1)])
        w = w / _sum(w)
        mu = np.array([_sum(R[:, j] * w) for j in range(N)])
        X = R - mu[None, :]
        Xs = X * np.sqrt(w)[:, None]
        C = np.asarray(_la.crossprod(Xs), dtype=np.float64) / (1 - _sum(w * w))
        return _psd(C, N)
    sd = np.sqrt(np.diag(S))
    if type == "denoise":
        pos = sd > 0
        if not pos.all():
            out = S * 0
            if pos.sum() > 0:
                ix = np.flatnonzero(pos)
                out[np.ix_(ix, ix)] = _opt_cov_m(R[:, ix], "denoise")
            return out
        C = np.asarray(_st().cov2cor(S), dtype=np.float64)
        e = _la.eigen(C, symmetric=True)
        vals = np.asarray(e["values"], dtype=np.float64).copy()
        V = np.asarray(e["vectors"], dtype=np.float64)
        q = 1 + math.sqrt(N / Tn)
        lmax = q * q
        noise = vals < lmax
        if noise.sum() > 1:
            vals[noise] = r_mean(vals[noise])
        C2 = _mp(_mp(V, _la.diag(vals, N)), V.T)
        C2 = np.asarray(_st().cov2cor(C2), dtype=np.float64)
        return _psd(C2 * np.asarray(_la.outer(sd, sd), dtype=np.float64), N)
    H = 0.5 * sd
    Up = (R >= H[None, :]).astype(np.float64)
    Dn = (R <= -H[None, :]).astype(np.float64)
    Uu = Up.T @ Up
    Dd = Dn.T @ Dn
    Ud = Up.T @ Dn
    nc = Uu + Dd
    nd = Ud + Ud.T
    with np.errstate(all="ignore"):
        G = np.where(nc + nd > 0, (nc - nd) / (nc + nd), 0.0)
    G[np.arange(N), np.arange(N)] = 1.0
    return _psd(G * np.asarray(_la.outer(sd, sd), dtype=np.float64), N)


def _opt_cov(R, type="sample"):  # noqa: A002
    """``.opt_cov``: Kovarianzschätzer (``sample``, ``ledoit_wolf``, ``ewma``, ``denoise``, ``gerber``)."""
    type = _match_arg(type, _COVS)  # noqa: A001
    cn = [str(c) for c in R.columns] if isinstance(R, pd.DataFrame) else None
    S = _opt_cov_m(R.to_numpy(dtype=np.float64) if isinstance(R, pd.DataFrame) else R, type)
    return pd.DataFrame(S, index=cn, columns=cn) if cn is not None else S


# ═══════════════════════════════════════════════════════════════════════════
# Löser
# ═══════════════════════════════════════════════════════════════════════════

def _proj_capped_simplex(v, lo, hi):
    return _core.proj_box_simplex(v, lo, hi)


def _qp_simplex(Q, cvec, lo, hi, w0=None, maxit=20000, tol=1e-12):
    """``.qp_simplex``: FISTA für min 0.5 w'Qw + c'w auf dem beschränkten Simplex."""
    Q = np.asarray(Q, dtype=np.float64)
    N = Q.shape[1]
    ev = np.asarray(_la.eigen(Q, symmetric=True, only_values=True)["values"], dtype=np.float64)
    L = max(float(ev.max()), 1e-12) if not np.isnan(ev).any() else _NAN
    w0 = np.repeat(1 / N, N) if w0 is None else w0
    return _core.qp_box_simplex(Q, cvec, lo, hi, w0, L, int(maxit), tol)


def _risk_parity(S, b):
    """``.risk_parity``: Risikobudgets (Spinu 2013, gedämpftes Newton)."""
    names = [str(c) for c in S.columns] if isinstance(S, pd.DataFrame) else None
    S = np.asarray(S, dtype=np.float64)
    b = np.asarray(b, dtype=np.float64).ravel()
    N = S.shape[1]
    y = 1 / np.sqrt(np.diag(S))
    y = y / _sum(y)

    def f(z):
        return 0.5 * _quad(z, S) - _sum(b * _libm.log(z))

    for _ in range(200):
        g = _mat_vec(S, y) - b / y
        H = S + _la.diag(b / (y * y), N)
        dx = np.asarray(_la.solve(H, g), dtype=np.float64).ravel()
        step = 1.0
        while True:
            yn = y - step * dx
            if (yn <= 0).any():
                cond = True
            else:
                cond = f(yn) > f(y) - 1e-4 * step * _sum(g * dx)
            if not cond:
                break
            step = step / 2
            if step < 1e-12:
                break
        y = y - step * dx
        if np.max(np.abs(dx * step)) < 1e-14:
            break
    out = y / _sum(y)
    return pd.Series(out, index=names) if names is not None else out


def _hclust_order(Dm):
    st = _st()
    D = st.as_dist(Dm)
    h = st.hclust(D, method="single")
    o = h["order"] if isinstance(h, Mapping) else h.order
    return [int(v) for v in np.asarray(o).ravel()]


def _hrp(S):
    """``.hrp``: Hierarchical Risk Parity (Lopez de Prado 2016)."""
    S = np.asarray(S, dtype=np.float64)
    N = S.shape[1]
    if N == 1:
        return np.array([1.0])
    C = np.asarray(_st().cov2cor(S), dtype=np.float64)
    Dm = (1 - C) / 2
    Dm[Dm < 0] = 0.0
    ordv = _hclust_order(np.sqrt(Dm))
    w = np.ones(N)
    clusters = [ordv]
    while clusters:
        nxt = []
        for cl in clusters:
            if len(cl) > 1:
                h = len(cl) // 2
                c1 = cl[:h]
                c2 = cl[h:]

                def cv(ix):
                    i0 = [i - 1 for i in ix]
                    s = S[np.ix_(i0, i0)]
                    iv = 1 / np.diag(s)
                    iv = iv / _sum(iv)
                    return _quad(iv, s)

                v1 = cv(c1)
                v2 = cv(c2)
                a = 1 - v1 / (v1 + v2)
                i1 = [i - 1 for i in c1]
                i2 = [i - 1 for i in c2]
                w[i1] = w[i1] * a
                w[i2] = w[i2] * (1 - a)
                nxt += [c1, c2]
        clusters = nxt
    return w / _sum(w)


def _min_cvar(R, alpha, lo, hi):
    """``.min_cvar``: minimaler CVaR (geglättet, FISTA)."""
    R = np.asarray(R, dtype=np.float64)
    N = R.shape[1]
    sc = r_sd(R.ravel(order="F"))
    w = _proj_capped_simplex(np.repeat(1 / N, N), lo, hi)
    zeta = _quantile(-_mat_vec(R, w), 1 - alpha)
    return _core.min_cvar_core(R, alpha, lo, hi, w, zeta, [sc * 0.05, sc * 0.005], 2000)


def _cdar_hist(r, alpha):
    """``.cdar_hist``: CDaR der kumulierten, nicht aufgezinsten Rendite."""
    r = np.asarray(r, dtype=np.float64).ravel()
    C = np.concatenate(([0.0], np.cumsum(r.astype(LD)).astype(np.float64)))
    D = (np.maximum.accumulate(C) - C)[1:]
    v = _quantile(D, 1 - alpha)
    return r_mean(D[D >= v])


def _min_cdar(R, alpha, lo, hi, iters=3000):
    return _core.min_cdar_core(np.asarray(R, dtype=np.float64), alpha, lo, hi, int(iters))


def _cvar_hist(r, alpha):
    """``.cvar_hist``: historischer CVaR (Verlust positiv)."""
    L = -np.asarray(r, dtype=np.float64).ravel()
    v = _quantile(L, 1 - alpha)
    return r_mean(L[L >= v])


# ═══════════════════════════════════════════════════════════════════════════
# Kern
# ═══════════════════════════════════════════════════════════════════════════

def _opt_core(R, method, lo, hi, cov_type, mu, risk_free, risk_aversion, budget, alpha, ppy):
    """``.opt_core``: ein Optimierungsschritt auf einer Renditematrix (DataFrame)."""
    nm = [str(c) for c in R.columns]
    A = R.to_numpy(dtype=np.float64)
    N = A.shape[1]
    S = _opt_cov_m(A, cov_type) * ppy
    if mu is None:
        m = _colmeans(A) * ppy
    else:
        m = np.full(N, _NA)
        mn, mv = list(mu.index), mu.to_numpy(dtype=np.float64)
        with np.errstate(invalid="ignore"):      # NA (signalisierendes NaN) ohne numpy-Warnung wie in R
            for k, x in zip(mn, mv):
                m[nm.index(k)] = x / 100

    def mu_miss():
        if np.isnan(m).any():
            raise ValueError("%s: mu für alle Anlagen angeben; es fehlt ein Wert für %s (benannter Vektor mit allen "
                             "Anlagen oder ein Wert je Spalte in Spaltenreihenfolge)."
                             % (method, ", ".join("'%s'" % nm[i] for i in range(N) if math.isnan(m[i]))))

    env = {"rf": risk_free / 100}

    def sharpe_of(w, mm):
        with np.errstate(all="ignore"):
            return float((np.float64(_sum(w * mm)) - env["rf"]) / np.sqrt(np.float64(_quad(w, S))))

    def best_sharpe(mm):
        st = _st()
        lg = st.seq_len_out(math.log(500), math.log(0.05), 30)
        ws = []
        prev = None
        for k in range(len(lg)):
            ws.append(_qp_simplex(_libm.exp(float(lg[k])) * S, -mm, lo, hi, prev, tol=1e-10))
            prev = ws[k]
        sh = np.array([sharpe_of(w, mm) for w in ws])
        k = _which_max(sh)
        a = lg[min(len(lg), k + 2) - 1]
        b = lg[max(1, k) - 1]
        w0 = ws[k]

        def fx(x):
            w = _qp_simplex(_libm.exp(float(x)) * S, -mm, lo, hi, w0, tol=1e-11)
            return w, sharpe_of(w, mm)

        gr = (math.sqrt(5) - 1) / 2
        x1 = b - gr * (b - a)
        x2 = a + gr * (b - a)
        f1 = fx(x1)
        f2 = fx(x2)
        for _ in range(25):
            if f1[1] > f2[1]:
                b = x2
                x2 = x1
                f2 = f1
                x1 = b - gr * (b - a)
                f1 = fx(x1)
            else:
                a = x1
                x1 = x2
                f1 = f2
                x2 = a + gr * (b - a)
                f2 = fx(x2)
        cand = [ws[k], f1[0], f2[0]]
        return cand[_which_max(np.array([sh[k], f1[1], f2[1]]))]

    default_bounds = bool((lo == 0).all() and (hi == 1).all())
    if method in ("inverse_vol", "risk_parity", "hrp") and N > 1:
        fl = _opt_flat(S, nm)
        if fl:
            raise ValueError("%s: Anlage(n) %s ohne Schwankung (Volatilität 0); das Verfahren ist dafür nicht "
                             "definiert. Anlage entfernen oder z. B. min_variance verwenden."
                             % (method, ", ".join("'%s'" % a for a in fl)))
    if method == "equal":
        if not default_bounds:
            _warn("equal: Grenzen werden ignoriert.")
        w = np.repeat(1 / N, N)
    elif method == "inverse_vol":
        if not default_bounds:
            _warn("inverse_vol: Grenzen werden ignoriert.")
        v = 1 / np.sqrt(np.diag(S))
        w = v / _sum(v)
    elif method == "min_variance":
        w = _qp_simplex(S, np.zeros(N), lo, hi)
    elif method == "mean_variance":
        mu_miss()
        w = _qp_simplex(risk_aversion * S, -m, lo, hi)
    elif method == "max_sharpe":
        mu_miss()
        w = best_sharpe(m)
    elif method == "max_diversification":
        env["rf"] = 0.0
        w = best_sharpe(np.sqrt(np.diag(S)))
    elif method == "risk_parity":
        if not default_bounds:
            _warn("risk_parity: Grenzen werden ignoriert.")
        if budget is None:
            b = np.repeat(1 / N, N)
        else:
            v = _opt_bounds(budget, nm, 0, "budget")
            if (v < 0).any() or _sum(v) <= 0:
                raise ValueError("budget: Risikobudgets müssen >= 0 sein, mit positiver Summe.")
            b = v / _sum(v)
        w = np.asarray(_risk_parity(S, b), dtype=np.float64)
    elif method == "hrp":
        if not default_bounds:
            _warn("hrp: Grenzen werden ignoriert.")
        w = _hrp(S)
    elif method == "min_cvar":
        w = _min_cvar(A, alpha, lo, hi)
    elif method == "min_cdar":
        w = _min_cdar(A, alpha, lo, hi)
    else:
        raise ValueError("Unbekannte Methode '%s'." % method)
    w = np.array(w, dtype=np.float64)
    w[np.abs(w) < 1e-12] = 0.0
    return pd.Series(w / _sum(w), index=nm)


def _which_max(v):
    v = np.asarray(v, dtype=np.float64)
    ok = ~np.isnan(v)
    if not ok.any():
        return 0
    mx = v[ok].max()
    return int(np.flatnonzero(ok & (v == mx))[0])


def _which_min(v):
    v = np.asarray(v, dtype=np.float64)
    ok = ~np.isnan(v)
    if not ok.any():
        return 0
    mn = v[ok].min()
    return int(np.flatnonzero(ok & (v == mn))[0])


# ═══════════════════════════════════════════════════════════════════════════
# portfolio_optimize
# ═══════════════════════════════════════════════════════════════════════════

class SimLevOptimization(RList):
    """Ergebnis von :func:`portfolio_optimize` (R-Klasse ``SimLevOptimization``)."""

    r_class = ("SimLevOptimization",)

    def format(self):
        return print_SimLevOptimization(self, _return=True)

    # ``plot`` (SVG, ``SimLevPlot``) wird am Modulende über ``_plot_method`` gesetzt.


def portfolio_optimize(x, assets=None, method=_METHODS, lower=0, upper=1, cov=_COVS, mu=None, risk_free=0,
                       risk_aversion=4, budget=None, alpha=0.05, frequency=_FREQS, resample=0, block=None, seed=None):
    """Portfolio optimieren (Long-only, Summe 1, optionale Grenzen je Anlage).

    Args:
        x: ``DataFrame`` mit Spalte ``date`` und Kursspalten oder Matrix einfacher
            Periodenrenditen als Anteil (ohne Spaltennamen ``A1``, ``A2``, …).
        assets: zu verwendende Spalten (``None`` = alle numerischen außer ``date``).
        method: ``"min_variance"`` (Standard), ``"max_sharpe"``, ``"mean_variance"``,
            ``"max_diversification"``, ``"risk_parity"``, ``"hrp"``, ``"min_cvar"``,
            ``"min_cdar"``, ``"inverse_vol"`` oder ``"equal"``.
        lower, upper: Grenzen als Anteil (Skalar, benannter Vektor oder ein Wert je Anlage).
        cov: ``"sample"``, ``"ledoit_wolf"``, ``"ewma"``, ``"denoise"`` oder ``"gerber"``.
        mu: erwartete Renditen in Prozent p. a. (für ``max_sharpe``, ``mean_variance``).
        risk_free: risikoloser Zins in Prozent p. a.
        risk_aversion: Risikoaversion für ``mean_variance``.
        budget: Risikobudgets für ``risk_parity``.
        alpha: Tail-Wahrscheinlichkeit für CVaR/CDaR, in (0, 0.5].
        frequency: ``"week"`` (Standard), ``"day"`` oder ``"month"``.
        resample: Anzahl Block-Bootstrap-Stichproben (Michaud; 0 = aus).
        block: mittlere Blocklänge (``None`` = T^(1/3) gerundet, mindestens 2).
        seed: Startwert für das Resampling (Zustand der Sitzung bleibt unverändert).

    Returns:
        :class:`SimLevOptimization` mit ``weights``, ``stats``, ``risk``, ``alpha``,
        ``method``, ``bounds``, ``resampled``, ``cov_type``, ``frequency``, ``n_obs``.
    """
    method = _match_arg(method, _METHODS)
    cov = _match_arg(cov, _COVS)
    frequency = _match_arg(frequency, _FREQS)
    rr = _opt_returns(x, assets, frequency)
    R = rr["R"]
    nm = [str(c) for c in R.columns]
    N = len(nm)
    if len(R) < N + 5:
        raise ValueError("Zu wenige Beobachtungen für die Optimierung (%d Perioden für %d Anlagen, mindestens %d)."
                         % (len(R), N, N + 5))
    lo, hi = _opt_check_bounds(lower, upper, nm)
    _opt_check_alpha(alpha, "portfolio_optimize")
    if mu is not None:
        mu = pd.Series(_opt_bounds(mu, nm, _NA, "mu"), index=nm)
        if np.isinf(mu.to_numpy()).any():
            raise ValueError("mu: endliche Werte in Prozent p. a. erwartet (erhalten: %s)." % ", ".join(_fmt1(mu.to_numpy())))
    ppy = rr["ppy"]

    def core(Rx):
        return _opt_core(Rx, method, lo, hi, cov, mu, risk_free, risk_aversion, budget, alpha, ppy)

    w = core(R)
    wb = None
    if resample > 0:
        T = len(R)
        if block is None:
            block = max(2, float(_fmt.r_round(r_pow(T, 1 / 3))))
        from ._bootstrap_core import boot_idx_stationary
        from .bootstrap import _with_rng_restore

        A = R.to_numpy(dtype=np.float64)

        def run():
            out = np.empty((int(resample), N))
            for bb in range(int(resample)):
                idx = np.asarray(boot_idx_stationary(T, T, block), dtype=np.int64) - 1
                out[bb, :] = core(pd.DataFrame(A[idx, :], columns=nm)).to_numpy()
            return out

        wbm = _with_rng_restore(run, seed=seed)
        wb = pd.DataFrame(wbm, columns=nm)
        wv = _colmeans(wbm)
        w = pd.Series(wv / _sum(wv), index=nm)
    out = _opt_summary(w, R, ppy, cov, risk_free, alpha)
    res = SimLevOptimization(out)
    res["method"] = method
    res["bounds"] = pd.DataFrame(np.vstack([lo, hi]), index=["lower", "upper"])
    res["resampled"] = wb
    res["cov_type"] = cov
    res["frequency"] = frequency
    res["n_obs"] = len(R)
    return res


def _opt_summary(w, R, ppy, cov_type, risk_free, alpha):
    """``.opt_summary``: Kennzahlen eines Gewichtsvektors."""
    A = R.to_numpy(dtype=np.float64)
    nm = list(w.index)
    wv = w.to_numpy(dtype=np.float64)
    S = _opt_cov_m(A, cov_type) * ppy
    m = _colmeans(A) * ppy
    q = _quad(wv, S)
    vol = math.sqrt(max(q, 0.0)) if not math.isnan(q) else q
    ret = _sum(wv * m)
    rp = _mat_vec(A, wv)
    if vol <= 1e-10:
        _warn("Portfolio ohne Schwankung (Volatilität 0, nur Anlagen mit konstanter Rendite): Sharpe Ratio, "
              "Diversifikationsverhältnis und Risikoanteile sind nicht definiert (NA).")
        vol = 0.0
        vq = _NA
    else:
        vq = vol
    rc = wv * _mat_vec(S, wv) / vq
    stats = pd.Series({
        "expected_return": ret, "volatility": vol, "sharpe": (ret - risk_free / 100) / vq,
        "cvar": _cvar_hist(rp, alpha), "cdar": _cdar_hist(rp, alpha),
        "diversification_ratio": _sum(wv * np.sqrt(np.diag(S))) / vq,
        "effective_n": 1 / _sum(wv * wv), "effective_n_risk": 1 / _sum((rc / vq) * (rc / vq))}, dtype=np.float64)
    risk = pd.DataFrame({"asset": nm, "weight": wv,
                         "volatility_contribution": np.zeros(len(wv)) if math.isnan(vq) else rc,
                         "risk_share": rc / vq})
    return {"weights": w, "stats": stats, "risk": risk, "alpha": alpha}


def print_SimLevOptimization(x, _return=False):  # noqa: N802 - R-Name
    """``print.SimLevOptimization``."""
    rs = x.get("resampled")
    lines = [_sprintf("SimLev-Optimierung: %s%s (%d Perioden, %s, Kovarianz %s)", x["method"],
                      _sprintf(", Resampling %d", len(rs)) if rs is not None else "", int(x["n_obs"]), x["frequency"],
                      x["cov_type"]), ""]
    r = x["risk"]
    df = pd.DataFrame({"Anlage": list(r["asset"]),
                       "Gewicht": list(np.asarray(_fmt.sprintf("%.1f %%", 100 * r["weight"].to_numpy(dtype=np.float64)),
                                                  dtype=object).ravel()),
                       "Risikoanteil": list(np.asarray(_fmt.sprintf("%.1f %%", 100 * r["risk_share"].to_numpy(
                           dtype=np.float64)), dtype=object).ravel())})
    lines.append(_fmt.print_data_frame(df, row_names=False))
    s = x["stats"]
    lines.append("")
    lines.append(_sprintf("Erwartete Rendite %.2f %% p. a. (historisch), Volatilität %.2f %%, Sharpe %.3f",
                          100 * s["expected_return"], 100 * s["volatility"], s["sharpe"]))
    lines.append(_sprintf("CVaR(%g) %.2f %% je Periode, CDaR(%g) %.2f %% (kumuliert)", float(x["alpha"]),
                          100 * s["cvar"], float(x["alpha"]), 100 * s["cdar"]))
    lines.append(_sprintf("Diversifikationsverhältnis %.2f, effektive Anzahl: Gewichte %.1f, Risiko %.1f",
                          s["diversification_ratio"], s["effective_n"], s["effective_n_risk"]))
    txt = "\n".join(lines)
    if _return:
        return txt
    print(txt)
    return x


def plot_SimLevOptimization(x, width=700, height=420):  # noqa: N802 - R-Name
    """``plot.SimLevOptimization``: Gewichte und Risikoanteile je Anlage als gruppierte Balken (SVG).

    Liefert ``(svg, data)``; ``data["weights"]``: ``asset``, ``weight``, ``risk_share`` (Anteile).
    Über ``x.plot()`` bzw. ``simlev.plot(x)`` entsteht daraus ein ``SimLevPlot``.
    """
    r = x["risk"]
    a = [str(v) for v in r["asset"]]
    wr = np.asarray(r["weight"], dtype=np.float64).ravel()
    sr = np.asarray(r["risk_share"], dtype=np.float64).ravel()
    w = 100 * wr
    s_ = 100 * sr
    vals = [float(v) for v in np.concatenate([w, s_, [0.0]]) if math.isfinite(v)]
    ymax = max(vals) * 1.08
    ymin = _jl_min(0.0, min(vals))
    L, R, T, B = 60.0, 20.0, 40.0, 50.0
    pw = width - L - R
    ph = height - T - B

    def py(v):
        return T + ph * (1 - (v - ymin) / (ymax - ymin))
    out = ["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%s\" height=\"%s\" viewBox=\"0 0 %s %s\" "
           "font-family=\"sans-serif\">" % (_jl_str(width), _jl_str(height), _jl_str(width), _jl_str(height)),
           "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>",
           "<text x=\"%s\" y=\"22\" text-anchor=\"middle\" font-size=\"15\" font-weight=\"bold\">%s</text>"
           % (_jl_str(width / 2), _esc("Gewichte und Risikoanteile (%s)" % x["method"]))]
    for t in _alloc_ticks(ymin, ymax):
        out.append("<line x1=\"%s\" x2=\"%s\" y1=\"%s\" y2=\"%s\" stroke=\"#e5e5e5\"/>"
                   % (_jl_str(L), _jl_str(L + pw), _alloc_c(py(t)), _alloc_c(py(t))))
        out.append("<text x=\"%s\" y=\"%s\" text-anchor=\"end\" font-size=\"11\">%s</text>"
                   % (_jl_str(L - 6), _alloc_c(py(t) + 4), _alloc_c(t)))
    out.append("<text x=\"16\" y=\"%s\" font-size=\"12\" transform=\"rotate(-90 16 %s)\" text-anchor=\"middle\">%%</text>"
               % (_jl_str(T + ph / 2), _jl_str(T + ph / 2)))
    K = len(a)
    gw = pw / max(K, 1)
    for k in range(K):
        x0 = L + k * gw + gw * 0.15
        bw = gw * 0.35
        for j, (v, col) in enumerate(((float(w[k]), "#2C6E9B"), (float(s_[k]), "#B5562B"))):
            if not math.isfinite(v):
                continue
            y1 = py(_jl_max(v, 0.0))
            y0 = py(_jl_min(v, 0.0))
            out.append("<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"%s\"/>"
                       % (_alloc_c(x0 + j * bw), _alloc_c(y1), _alloc_c(bw), _alloc_c(y0 - y1), col))
        out.append("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" font-size=\"11\">%s</text>"
                   % (_alloc_c(L + (k + 1 - 0.5) * gw), _jl_str(T + ph + 18), _esc(a[k])))
    for j, (lab, col) in enumerate((("Gewicht", "#2C6E9B"), ("Risikoanteil", "#B5562B"))):
        yy = T + 6 + j * 16
        out.append("<rect x=\"%s\" y=\"%s\" width=\"10\" height=\"10\" fill=\"%s\"/>" % (_jl_str(L + pw - 110), _jl_str(yy), col))
        out.append("<text x=\"%s\" y=\"%s\" font-size=\"11\">%s</text>" % (_jl_str(L + pw - 95), _jl_str(yy + 9), lab))
    out.append("</svg>")
    data = {"weights": pd.DataFrame({"asset": a, "weight": wr, "risk_share": sr})}
    return "\n".join(out) + "\n", data


# ═══════════════════════════════════════════════════════════════════════════
# efficient_frontier
# ═══════════════════════════════════════════════════════════════════════════

class SimLevFrontier(RList):
    """Ergebnis von :func:`efficient_frontier` (R-Klasse ``SimLevFrontier``)."""

    r_class = ("SimLevFrontier",)

    def format(self):
        return print_SimLevFrontier(self, _return=True)

    # ``plot`` (SVG, ``SimLevPlot``) wird am Modulende über ``_plot_method`` gesetzt.


def _dup_key(v):
    return tuple(("NaN" if _fmt._is_rnan(z) else "NA") if math.isnan(z) else (0.0 if z == 0 else z) for z in v)


def efficient_frontier(x, assets=None, n=40, lower=0, upper=1, cov=_COVS, risk_free=0, frequency=_FREQS):
    """Effizienzgrenze: für ``n`` Risikoaversionen von 1e4 bis 0.02 (logarithmisch)
    ``max mu'w - gamma/2 w'Sigma w`` unter denselben Grenzen wie :func:`portfolio_optimize`.

    Returns:
        :class:`SimLevFrontier` mit ``frontier`` (``expected_return``, ``volatility``,
        ``sharpe``, Gewichte je Anlage), ``assets``, ``risk_free``, ``frequency``.
    """
    cov = _match_arg(cov, _COVS)
    frequency = _match_arg(frequency, _FREQS)
    rr = _opt_returns(x, assets, frequency)
    R = rr["R"]
    nm = [str(c) for c in R.columns]
    lo, hi = _opt_check_bounds(lower, upper, nm)
    A = R.to_numpy(dtype=np.float64)
    S = _opt_cov_m(A, cov) * rr["ppy"]
    m = _colmeans(A) * rr["ppy"]
    gs = _libm.exp(_st().seq_len_out(math.log(1e4), math.log(0.02), int(n)))
    gs = np.atleast_1d(gs)
    W = np.array([_qp_simplex(g * S, -m, lo, hi) for g in gs]).reshape(len(gs), len(nm))
    ret = _mat_vec(W, m) if len(nm) > 0 else np.zeros(len(gs))
    WS = _mp(W, S)
    vol = np.sqrt(np.maximum(_rowsums(WS * W), 0))
    rret = np.asarray(_fmt.r_round(ret, 6), dtype=np.float64)
    rvol = np.asarray(_fmt.r_round(vol, 6), dtype=np.float64)
    seen = set()
    keep = []
    for a, b in zip(rret, rvol):
        k = _dup_key((a, b))
        keep.append(k not in seen)
        seen.add(k)
    keep = np.array(keep, dtype=bool)
    with np.errstate(all="ignore"):
        sh = np.where(vol > 1e-10, (ret - risk_free / 100) / vol, _NA)
    fr = pd.DataFrame({"expected_return": ret, "volatility": vol, "sharpe": sh})
    for j, a in enumerate(nm):
        fr[a] = W[:, j]
    fr = fr.loc[keep].copy()
    fr.index = np.flatnonzero(keep) + 1
    res = SimLevFrontier()
    res["frontier"] = fr
    res["assets"] = pd.DataFrame({"asset": nm, "expected_return": m, "volatility": np.sqrt(np.diag(S))}, index=nm)
    res["risk_free"] = risk_free
    res["frequency"] = frequency
    return res


def print_SimLevFrontier(x, _return=False):  # noqa: N802 - R-Name
    """``print.SimLevFrontier``: Minimum-Varianz und Max.-Sharpe-Punkt."""
    f = x["frontier"]
    sh = f["sharpe"].to_numpy(dtype=np.float64)
    ks = [] if np.isnan(sh).all() else [_which_max(sh)]
    j = _which_min(f["volatility"].to_numpy(dtype=np.float64))
    idx = _unique([j] + ks)
    show = f.iloc[idx].copy()
    show.index = ["Minimum-Varianz", "Max. Sharpe"][:len(show)]
    for c in show.columns:
        show[c] = np.asarray(_fmt.r_round(show[c].to_numpy(dtype=np.float64), 4), dtype=np.float64)
    txt = "Effizienzgrenze: %d Punkte\n%s" % (len(f), _fmt.print_data_frame(show))
    if _return:
        return txt
    print(txt)
    return x


def plot_SimLevFrontier(x, width=700, height=480):  # noqa: N802 - R-Name
    """``plot.SimLevFrontier``: Effizienzgrenze (Linie) mit Einzelanlagen und dem Punkt mit der
    höchsten Sharpe Ratio (SVG).

    Liefert ``(svg, data)`` mit ``frontier`` (``volatility``, ``expected_return``), ``assets``
    (``asset``, ``volatility``, ``expected_return``) und ``max_sharpe`` (Anteile p. a.).
    """
    f = x["frontier"]
    a = x["assets"]
    fvol = np.asarray(f["volatility"], dtype=np.float64).ravel()
    fret = np.asarray(f["expected_return"], dtype=np.float64).ravel()
    avol = np.asarray(a["volatility"], dtype=np.float64).ravel()
    aret = np.asarray(a["expected_return"], dtype=np.float64).ravel()
    fv, fr, av, ar = 100 * fvol, 100 * fret, 100 * avol, 100 * aret
    xmax = 1.18 * max(float(v) for v in np.concatenate([fv, av, [1e-9]]) if math.isfinite(v))
    ys = [float(v) for v in np.concatenate([fr, ar]) if math.isfinite(v)]
    ymin = min(ys) - 0.3
    ymax = max(ys) + 0.3
    L, R, T, B = 60.0, 20.0, 40.0, 50.0
    pw = width - L - R
    ph = height - T - B

    def px(v):
        return L + pw * v / xmax

    def py(v):
        return T + ph * (1 - (v - ymin) / (ymax - ymin))
    out = ["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%s\" height=\"%s\" viewBox=\"0 0 %s %s\" "
           "font-family=\"sans-serif\">" % (_jl_str(width), _jl_str(height), _jl_str(width), _jl_str(height)),
           "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>",
           "<text x=\"%s\" y=\"22\" text-anchor=\"middle\" font-size=\"15\" font-weight=\"bold\">Effizienzgrenze</text>"
           % _jl_str(width / 2)]
    for t in _alloc_ticks(0.0, xmax):
        out.append("<line x1=\"%s\" x2=\"%s\" y1=\"%s\" y2=\"%s\" stroke=\"#e5e5e5\"/>"
                   % (_alloc_c(px(t)), _alloc_c(px(t)), _jl_str(T), _jl_str(T + ph)))
        out.append("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" font-size=\"11\">%s</text>"
                   % (_alloc_c(px(t)), _jl_str(T + ph + 16), _alloc_c(t)))
    for t in _alloc_ticks(ymin, ymax):
        out.append("<line x1=\"%s\" x2=\"%s\" y1=\"%s\" y2=\"%s\" stroke=\"#e5e5e5\"/>"
                   % (_jl_str(L), _jl_str(L + pw), _alloc_c(py(t)), _alloc_c(py(t))))
        out.append("<text x=\"%s\" y=\"%s\" text-anchor=\"end\" font-size=\"11\">%s</text>"
                   % (_jl_str(L - 6), _alloc_c(py(t) + 4), _alloc_c(t)))
    out.append("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" font-size=\"12\">Volatilität (%% p. a.)</text>"
               % (_jl_str(L + pw / 2), _jl_str(height - 10)))
    out.append("<text x=\"16\" y=\"%s\" font-size=\"12\" transform=\"rotate(-90 16 %s)\" text-anchor=\"middle\">"
               "Rendite (%% p. a., historisch)</text>" % (_jl_str(T + ph / 2), _jl_str(T + ph / 2)))
    pts = " ".join("%s,%s" % (_alloc_c(px(v)), _alloc_c(py(r_))) for v, r_ in zip(fv.tolist(), fr.tolist())
                   if math.isfinite(v) and math.isfinite(r_))
    out.append("<polyline points=\"%s\" fill=\"none\" stroke=\"#2C6E9B\" stroke-width=\"2\"/>" % pts)
    for k, nm in enumerate(a["asset"]):
        out.append("<circle cx=\"%s\" cy=\"%s\" r=\"4\" fill=\"#B5562B\"/>"
                   % (_alloc_c(px(av[k])), _alloc_c(py(ar[k]))))
        out.append("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" font-size=\"10\">%s</text>"
                   % (_alloc_c(px(av[k])), _alloc_c(py(ar[k]) - 8), _esc(nm)))
    sh = np.asarray(f["sharpe"], dtype=np.float64).ravel()
    k = None if np.isnan(sh).all() else _which_max(sh)
    if k is not None:
        cx, cy = px(fv[k]), py(fr[k])
        out.append("<polygon points=\"%s,%s %s,%s %s,%s\" fill=\"#3E8E5A\"/>"
                   % (_alloc_c(cx), _alloc_c(cy - 6), _alloc_c(cx - 5), _alloc_c(cy + 4), _alloc_c(cx + 5),
                      _alloc_c(cy + 4)))
    out.append("</svg>")
    ks = [] if k is None else [k]
    data = {"frontier": pd.DataFrame({"volatility": fvol, "expected_return": fret}),
            "assets": pd.DataFrame({"asset": [str(v) for v in a["asset"]], "volatility": avol, "expected_return": aret}),
            "max_sharpe": pd.DataFrame({"volatility": fvol[ks], "expected_return": fret[ks]})}
    return "\n".join(out) + "\n", data


# ═══════════════════════════════════════════════════════════════════════════
# rolling_optimization
# ═══════════════════════════════════════════════════════════════════════════

def _err_text(e):
    return str(e.args[0]) if getattr(e, "args", None) and isinstance(e.args[0], str) else str(e)


def rolling_optimization(x, assets, method="min_variance", window=3, every=("month", "quarter", "year"),
                         frequency=_FREQS, **kwargs):
    """Rollierende Optimierung (Zielgewichte außerhalb der Stichprobe).

    An jedem Entscheidungstermin (letzte Zeile je Monat/Quartal/Jahr, mindestens
    ``window`` Jahre nach dem ersten Datum) wird auf dem Fenster (Termin - window*365.25
    Tage, Termin] optimiert; fehlgeschlagene Termine erhalten Gleichgewichtung (Warnung).

    Returns:
        :class:`simlev.tactical.SimLevWeights` mit ``attrs`` ``source``,
        ``decision_rows`` und ``failed_dates``.
    """
    every = _match_arg(every, ("month", "quarter", "year"))
    frequency = _match_arg(frequency, _FREQS)
    if not isinstance(method, str) or method not in _METHODS:
        mv = [method] if isinstance(method, str) or np.ndim(method) == 0 else list(method)
        raise ValueError("rolling_optimization: unbekanntes Verfahren %s; erlaubt: %s."
                         % (", ".join("'%s'" % m for m in mv), ", ".join(_METHODS)))
    dots = dict(kwargs)
    allowed = [a for a in _PO_FORMALS if a not in ("x", "assets", "method", "frequency")]
    bad = [k for k in dots if k not in allowed]
    if bad:
        raise ValueError("rolling_optimization: unbekannte bzw. unbenannte Argumente für portfolio_optimize() in "
                         "...: %s." % ", ".join("'%s'" % b for b in _unique(bad)))
    if not isinstance(x, pd.DataFrame) or "date" not in [str(c) for c in x.columns]:
        raise ValueError("rolling_optimization: data.frame mit Spalte 'date' erwartet.")
    assets = [assets] if isinstance(assets, str) else [str(a) for a in assets]
    miss = _setdiff(assets, [str(c) for c in x.columns])
    if miss:
        raise ValueError("Spalten fehlen: %s" % ", ".join(miss))
    _opt_check_bounds(0 if dots.get("lower") is None else dots["lower"],
                      1 if dots.get("upper") is None else dots["upper"], assets)
    _opt_check_alpha(0.05 if dots.get("alpha") is None else dots["alpha"], "rolling_optimization")
    if dots.get("mu") is not None:
        _opt_bounds(dots["mu"], assets, _NA, "mu")
    from .dependence import _dep_sort_dates
    x = _dep_sort_dates(x, "x").reset_index(drop=True)
    d = _days(np.asarray(x["date"]))
    n = len(d)
    N = len(assets)
    rows = _period_last(d, every)
    wd = float(_fmt.r_round(window * 365.25))
    first_ok = d[0] + wd
    rows = rows[d[rows - 1] >= first_ok]
    if not len(rows):
        raise ValueError("Historie kürzer als das Fenster.")
    msg = [""] * len(rows)
    M = np.empty((len(rows), N))
    sub_cols = ["date"] + assets
    for k, i1 in enumerate(rows):
        di = d[i1 - 1]
        sel = (d > di - wd) & (d <= di)
        sub = x.loc[sel, sub_cols].reset_index(drop=True)
        w = None
        try:
            with warnings.catch_warnings():
                warnings.filterwarnings("ignore", category=SimLevBoundsPercent)
                w = portfolio_optimize(sub, assets, method=method, frequency=frequency, **dots)["weights"]
            w = np.asarray(w, dtype=np.float64)
        except Exception as e:  # noqa: BLE001 - wie tryCatch(error = ...)
            msg[k] = _err_text(e)
            w = np.full(N, _NA)
        if np.isnan(w).any():
            if not msg[k]:
                msg[k] = "Gewichte NA"
            w = np.repeat(1 / N, N)
        M[k, :] = w
    failed = [k for k in range(len(rows)) if msg[k]]
    if failed:
        f0 = failed[0]
        _warn("rolling_optimization: Optimierung an %d von %d Terminen fehlgeschlagen (erster am %s: %s); dort "
              "Gleichgewichtung. Termine im Attribut 'failed_dates'."
              % (len(failed), len(rows), _fmt.format(_as_dates([d[rows[f0] - 1]]))[0], msg[f0]))
    H = _hold_rows_m(n, rows, M)
    H[:rows[0] - 1, :] = 1 / N
    out = _as_weights_m(_as_dates(d), H, assets, "rolling %s" % method)
    out.attrs["decision_rows"] = rows
    out.attrs["failed_dates"] = _as_dates(d[rows[failed] - 1]) if failed else _as_dates(np.zeros(0))
    return out


# ═══════════════════════════════════════════════════════════════════════════
# risk_contributions
# ═══════════════════════════════════════════════════════════════════════════

def risk_contributions(x, weights, measure=("volatility", "cvar"), alpha=0.05, frequency=_FREQS, cov=_COVS):
    """Risikobeiträge (Euler-Zerlegung) von Volatilität oder historischem CVaR.

    Returns:
        ``DataFrame`` je Anlage (``asset``, ``weight``, ``contribution``, ``share``,
        ``marginal``) mit ``attrs`` ``total``, ``measure``, ``effective_n`` und bei
        ``"volatility"`` ``diversification_ratio``.
    """
    measure = _match_arg(measure, ("volatility", "cvar"))
    frequency = _match_arg(frequency, _FREQS)
    cov = _match_arg(cov, _COVS)
    _opt_check_alpha(alpha, "risk_contributions")
    if isinstance(weights, SimLevOptimization):
        weights = weights["weights"]
    names, vals, isnum = _named_vec(weights)
    if not isnum or names is None or any(k == "" for k in names) or any(_isna(v) for v in vals):
        raise ValueError("weights: benannter numerischer Vektor ohne NA erwartet (Namen = Spalten von x).")
    if isinstance(x, pd.DataFrame) and "date" in [str(c) for c in x.columns]:
        avail = [str(c) for c in x.columns]
    elif isinstance(x, pd.DataFrame) and not isinstance(x.columns, pd.RangeIndex):
        avail = [str(c) for c in x.columns]
    else:
        nc = np.asarray(x).shape[1] if np.ndim(x) == 2 else 1
        avail = ["A%d" % (j + 1) for j in range(nc)]
    unk = _setdiff(names, avail)
    if unk:
        raise ValueError("weights: unbekannte Anlage(n) %s; vorhanden: %s." % (
            ", ".join("'%s'" % u for u in unk), ", ".join(a for a in avail if a != "date")))
    rr = _opt_returns(x, names, frequency)
    R = rr["R"]
    cn = [str(c) for c in R.columns]
    wmap = {}
    for k, v in zip(names, vals):
        wmap.setdefault(k, float(v))
    w = np.array([wmap[c] for c in cn], dtype=np.float64)
    A = R.to_numpy(dtype=np.float64)
    if measure == "volatility":
        S = _opt_cov_m(A, cov) * rr["ppy"]
        tot = math.sqrt(_quad(w, S))
        mc = _mat_vec(S, w) / tot
        rc = w * mc
    else:
        rp = _mat_vec(A, w)
        L = -rp
        v = _quantile(L, 1 - alpha)
        tail = L >= v
        mc = _colmeans(-A[tail, :])
        rc = mc * w
        tot = _sum(rc)
    out = pd.DataFrame({"asset": cn, "weight": w, "contribution": rc, "share": rc / tot, "marginal": mc})
    out.attrs["total"] = tot
    out.attrs["measure"] = measure
    out.attrs["effective_n"] = 1 / _sum((rc / tot) * (rc / tot))
    if measure == "volatility":
        out.attrs["diversification_ratio"] = _sum(w * np.sqrt(np.diag(_opt_cov_m(A, cov) * rr["ppy"]))) / tot
    return out


# ═══════════════════════════════════════════════════════════════════════════
# cpcv_portfolio
# ═══════════════════════════════════════════════════════════════════════════

class SimLevCPCV(RList):
    """Ergebnis von :func:`cpcv_portfolio` (R-Klasse ``SimLevCPCV``)."""

    r_class = ("SimLevCPCV",)

    def format(self):
        return print_SimLevCPCV(self, _return=True)


def _int1_ok(v, lo):
    nm, vals, isnum = _named_vec(v)
    if not isnum or len(vals) != 1 or vals[0] is None:
        return False, vals, isnum
    f = float(vals[0])
    return (math.isfinite(f) and f == float(_fmt.r_round(f)) and f >= lo), vals, isnum


def cpcv_portfolio(x, assets=None, methods=("equal", "inverse_vol", "min_variance", "risk_parity", "max_sharpe"),
                   n_groups=6, test_groups=2, purge=2, embargo=2, frequency=_FREQS):
    """Kombinatorische Kreuzvalidierung von Optimierungsverfahren (CPCV, Lopez de Prado 2018).

    Args:
        x: wie :func:`portfolio_optimize`.
        assets: Spalten (``None`` = alle).
        methods: Zeichenvektor von Verfahren oder benanntes ``dict`` von
            Argumentlisten für :func:`portfolio_optimize`.
        n_groups, test_groups: Gruppen insgesamt und je Aufteilung im Test.
        purge, embargo: Sperrzone und Embargo in Perioden.
        frequency: wie :func:`portfolio_optimize`.

    Returns:
        :class:`SimLevCPCV` mit ``splits``, ``summary``, ``n_splits``, ``n_groups``,
        ``test_groups``, ``frequency``, ``failed``.
    """
    frequency = _match_arg(frequency, _FREQS)
    rr = _opt_returns(x, assets, frequency)
    R = rr["R"]
    Tn = len(R)
    for v, nm, lo in ((n_groups, "n_groups", 2), (test_groups, "test_groups", 1), (purge, "purge", 0),
                      (embargo, "embargo", 0)):
        ok, vals, isnum = _int1_ok(v, lo)
        if not ok:
            raise ValueError("cpcv_portfolio: %s muss eine ganze Zahl >= %d sein (erhalten: %s)."
                             % (nm, lo, ", ".join(_fmt_vals(vals, isnum))))
    n_groups_v, test_groups_v = n_groups, test_groups
    ng = int(n_groups)
    tg = int(test_groups)
    purge = int(purge)
    embargo = int(embargo)
    if tg >= ng:
        raise ValueError("cpcv_portfolio: test_groups (%d) muss kleiner als n_groups (%d) sein, sonst bleibt keine "
                         "Trainingsgruppe." % (tg, ng))
    if isinstance(methods, str):
        methods = [methods]
    if isinstance(methods, (list, tuple, np.ndarray)) and all(isinstance(m, str) for m in methods) and len(methods):
        specs = {str(m): {"method": str(m)} for m in methods}
    elif isinstance(methods, Mapping) and len(methods) and all(str(k) != "" for k in methods.keys()):
        specs = {str(k): v for k, v in methods.items()}
    else:
        raise ValueError("cpcv_portfolio: methods muss ein Zeichenvektor oder eine benannte Liste von Argumentlisten sein.")
    allowed_args = [a for a in _PO_FORMALS if a not in ("x", "assets", "frequency")]
    for nm, sp in specs.items():
        if not isinstance(sp, Mapping) or any(str(k) == "" for k in sp.keys()):
            raise ValueError("cpcv_portfolio: Eintrag '%s' von methods muss eine benannte Argumentliste sein." % nm)
        if sp.get("method") is not None and sp["method"] not in _METHODS:
            raise ValueError("cpcv_portfolio: unbekanntes Verfahren '%s'; erlaubt: %s." % (sp["method"], ", ".join(_METHODS)))
        bad = [k for k in sp.keys() if k not in allowed_args]
        if bad:
            raise ValueError("cpcv_portfolio: unbekannte Argumente für portfolio_optimize() in '%s': %s."
                             % (nm, ", ".join("'%s'" % b for b in _unique(bad))))
    grp = np.asarray(_st().cut(np.arange(1, Tn + 1), ng, labels=False), dtype=np.float64)
    combos = list(itertools.combinations(range(1, ng + 1), tg))
    A = R.to_numpy(dtype=np.float64)
    cn = [str(c) for c in R.columns]
    rows = []
    fails = []
    warned = []
    for cidx, comb in enumerate(combos, start=1):
        test = np.isin(grp, comb)
        train = ~test

        def drop_rows(a, b):
            a = max(1, a)
            b = min(Tn, b)
            if b >= a:
                train[a - 1:b] = False

        tv = test.astype(np.int64)
        starts = np.flatnonzero(np.diff(np.concatenate(([0], tv))) == 1) + 1
        ends = np.flatnonzero(np.diff(np.concatenate((tv, [0]))) == -1) + 1
        for s0 in starts:
            drop_rows(s0 - purge, s0 - 1)
        for e in ends:
            drop_rows(e + 1, e + max(purge, embargo))
        Rtr = _OptReturns(R=pd.DataFrame(A[train, :], columns=cn), ppy=rr["ppy"])
        Rte = A[test, :]
        for nm, sp in specs.items():
            w = None
            try:
                with warnings.catch_warnings(record=True) as wl:
                    warnings.simplefilter("always")
                    w = portfolio_optimize(Rtr, frequency=frequency, **dict(sp))["weights"]
                _replay(wl, nm, warned)
            except Exception as e:  # noqa: BLE001 - wie tryCatch(error = ...)
                try:
                    _replay(wl, nm, warned)
                except NameError:
                    pass
                fails.append({"method": nm, "split": cidx, "message": _err_text(e)})
                w = None
            if w is None:
                continue
            r = _mat_vec(Rte, w[cn].to_numpy(dtype=np.float64))
            mr = r_mean(r)
            sr = r_sd(r)
            with np.errstate(all="ignore"):
                shr = float(np.float64(mr) / np.float64(sr) * math.sqrt(rr["ppy"]))
            rows.append({"method": nm, "split": cidx, "return": mr * rr["ppy"], "volatility": sr * math.sqrt(rr["ppy"]),
                         "sharpe": shr, "cdar": _cdar_hist(r, 0.05)})
    fl = pd.DataFrame(fails, columns=["method", "split", "message"]) if fails else None
    if not rows:
        raise ValueError("cpcv_portfolio: keine Optimierung erfolgreich (z. B. '%s' in Aufteilung %d: %s)."
                         % (fl["method"].iloc[0], int(fl["split"].iloc[0]), fl["message"].iloc[0]))
    if fl is not None:
        _warn("cpcv_portfolio: %d von %d Optimierungen fehlgeschlagen (z. B. '%s' in Aufteilung %d: %s); sie fehlen in der "
              "Auswertung, Einzelheiten in $failed." % (len(fl), len(combos) * len(specs), fl["method"].iloc[0],
                                                        int(fl["split"].iloc[0]), fl["message"].iloc[0]))
    sp = pd.DataFrame(rows, columns=["method", "split", "return", "volatility", "sharpe", "cdar"])
    st = _st()
    summ = []
    from ._r._collate import r_key   # split(): Stufen nach R's Kollation
    for m in sorted(sp["method"].unique().tolist(), key=r_key):
        z = sp[sp["method"] == m]
        v = z["sharpe"].to_numpy(dtype=np.float64)
        summ.append({"method": m, "mean": r_mean(v), "sd": r_sd(v), "q10": _quantile(v, 0.1),
                     "q50": float(st.median(v)), "q90": _quantile(v, 0.9),
                     "volatility": r_mean(z["volatility"].to_numpy(dtype=np.float64)),
                     "cdar": r_mean(z["cdar"].to_numpy(dtype=np.float64)), "best_share": _NA})
    summ = pd.DataFrame(summ, columns=["method", "mean", "sd", "q10", "q50", "q90", "volatility", "cdar", "best_share"])
    best = []
    for s in sorted(sp["split"].unique().tolist()):
        z = sp[sp["split"] == s]
        best.append(z["method"].iloc[_which_max(z["sharpe"].to_numpy(dtype=np.float64))])
    best = np.array(best, dtype=object)
    summ["best_share"] = [_mean_int(best == m) for m in summ["method"]]
    o = st.order(-summ["mean"].to_numpy(dtype=np.float64))
    o = np.asarray(o, dtype=np.int64).ravel() - 1
    summ = summ.iloc[o].reset_index(drop=True)
    res = SimLevCPCV()
    res["splits"] = sp
    res["summary"] = summ
    res["n_splits"] = len(combos)
    res["n_groups"] = n_groups_v
    res["test_groups"] = test_groups_v
    res["frequency"] = frequency
    res["failed"] = fl
    return res


def _replay(wl, nm, warned):
    """Warnungen aus portfolio_optimize weitergeben; SimLevBoundsPercent nur einmal je Verfahren."""
    for w in wl:
        if issubclass(w.category, SimLevBoundsPercent):
            if nm in warned:
                continue
            warned.append(nm)
        warnings.warn_explicit(w.message, w.category, w.filename, w.lineno)


def print_SimLevCPCV(x, _return=False):  # noqa: N802 - R-Name
    """``print.SimLevCPCV``."""
    s = x["summary"]

    def col(fmt_, v):
        return list(np.asarray(_fmt.sprintf(fmt_, np.asarray(v, dtype=np.float64)), dtype=object).ravel())

    df = pd.DataFrame({"Verfahren": list(s["method"]), "Sharpe Mittel": col("%.3f", s["mean"]),
                       "Sharpe Sd": col("%.3f", s["sd"]), "10 %": col("%.3f", s["q10"]), "90 %": col("%.3f", s["q90"]),
                       "Vola": col("%.2f %%", 100 * s["volatility"]), "CDaR": col("%.2f %%", 100 * s["cdar"]),
                       "bestes Verfahren": col("%.0f %%", 100 * s["best_share"])})
    txt = "CPCV: %d Gruppen, je %d Testgruppen, %d Aufteilungen (%s)\n\n%s" % (
        int(x["n_groups"]), int(x["test_groups"]), int(x["n_splits"]), x["frequency"],
        _fmt.print_data_frame(df, row_names=False))
    if _return:
        return txt
    print(txt)
    return x


# plot-Methoden (SVG, ``SimLevPlot``) wie Julias ``_plot_method(plot_SimLevOptimization, …)``
from .svg import _plot_method  # noqa: E402

SimLevOptimization.plot = _plot_method(plot_SimLevOptimization, "SimLevOptimization")
SimLevFrontier.plot = _plot_method(plot_SimLevFrontier, "SimLevFrontier")

# Rechnen mit NA (signalisierendes NaN) ohne numpy-Warnung "invalid value" wie in R (gemeinsamer Helfer)
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), list(__all__) + ["_cdar_hist", "_col_means", "_cov", "_cvar_hist", "_hrp", "_mat_vec", "_opt_cov", "_qp_simplex", "_risk_parity", "_opt_summary"])
