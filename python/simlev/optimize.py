"""Portfolio-Optimierung und Risikozerlegung (Gegenstück zu ``r/R/optimize.R``).

- :func:`portfolio_optimize`    Minimum-Varianz, Mean-Variance, maximale Sharpe Ratio,
  maximale Diversifikation, Risikoparität (Risikobudgets), Hierarchical Risk Parity,
  minimaler CVaR/CDaR, inverse Volatilität, Gleichgewichtung; Box-Grenzen,
  Kovarianzschätzer (Stichprobe, Ledoit-Wolf, EWMA, Rauschfilter, Gerber),
  Resampling (Michaud)
- :func:`portfolio_frontier`    Effizienzgrenze unter denselben Grenzen
- :func:`portfolio_rolling`  Optimierung in rollierenden Fenstern -> Zielgewichte
  für :func:`simlev.tactical_simulation`
- :func:`portfolio_risk_contributions`    Euler-Zerlegung von Volatilität bzw. CVaR
- :func:`portfolio_cpcv`        kombinatorische Kreuzvalidierung (CPCV)

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
from . import _lib
from ._r import linalg as _la          # bleibende Hilfen diag, outer (Inventar A.3.2)
from ._r.rlist import RList
from ._r.rnum import r_cumsum, r_mean, r_pow, r_rowsums, r_sd, r_sum
from .tactical import (
    _as_weights_m, _colmeans, _days, _fmt1, _hold_rows_m, _mean_int,
    _period_last, _rowsums, _setdiff, _unique,
)
from .svg import _alloc_c, _alloc_ticks, _esc, _jl_max, _jl_min, _jl_str
from ._util import _dates as _as_dates, _match_arg, _which_max, _which_min
from ._util import _pow_rec, _stats as _st
from ._util import _fp_quiet
from ._util import _na as _isna
from ._pruefen import (chk_cols, chk_col_nofactor, chk_dots, chk_is_factor, chk_num1, chk_scalar,
                       chk_stop)

__all__ = ["portfolio_optimize", "portfolio_frontier", "portfolio_rolling", "portfolio_risk_contributions",
           "portfolio_cpcv", "SimLevOptimization", "SimLevFrontier", "SimLevCPCV", "SimLevBoundsPercent",
           "print_SimLevOptimization", "print_SimLevFrontier", "print_SimLevCPCV",
           "plot_SimLevOptimization", "plot_SimLevFrontier"]

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


# ── kleine R-Hilfen ──────────────────────────────────────────────────────


def _cov(R):
    """``stats::cov`` (Matrix -> ndarray)."""
    return np.asarray(_st().cov(np.asarray(R, dtype=np.float64)), dtype=np.float64)


def _col_means(R):
    return _colmeans(np.asarray(R, dtype=np.float64))


def _mp(x, y):
    """``x %m% y`` (slc-Matrixprodukt; Ergebnis ndarray)."""
    return np.asarray(_lib.matmul(x, y), dtype=np.float64)


def _mat_vec(R, w):
    """``drop(R %m% w)``."""
    return _mp(np.asarray(R, dtype=np.float64), np.asarray(w, dtype=np.float64).ravel()).ravel()


def _quad(w, S):
    """``drop(t(w) %m% S %m% w)``."""
    w = np.asarray(w, dtype=np.float64).ravel()
    return float(_mp(_mp(w.reshape(1, -1), S), w).ravel()[0])


def _quantile(x, p):
    q = _st().quantile(np.asarray(x, dtype=np.float64).ravel(), p, names=False, type=7)
    return float(np.asarray(q, dtype=np.float64).ravel()[0])


def _sum(x):
    """``sum(x)`` (long double, sequenziell; seit 1.6.3 ohne die errstate-Hülle von ``tactical._ldsum``)."""
    return r_sum(np.asarray(x, dtype=np.float64).ravel())


def _sumsq_f(A):
    """``sum(A^2)`` einer Matrix (spaltenweise Reihenfolge, long double)."""
    a = np.asarray(A, dtype=np.float64).ravel(order="F")
    return r_sum(a * a)


def _lw_acc(X, S1):
    """Ledoit-Wolf: je Zeile t ``sum((x_t x_t' - S1)^2) / N`` (spaltenweise, long double) wie die Schleife über
    ``tcrossprod`` bis 1.6.2, für endliche ``X`` in Blöcken ohne Zeilenschleife (seit 1.6.3): Produkt ``0 + x_i x_j``
    wie im Kern, Differenz, Quadrat, Zeilensumme über ``r_rowsums`` (long double, gleiche Reihenfolge)."""
    Tn, N = X.shape
    acc = np.empty(Tn)
    S1t = np.ascontiguousarray(np.asarray(S1, dtype=np.float64).T)      # [j, i] = S1[i, j]: spaltenweise Folge
    step = max(1, 2000000 // max(1, N * N))
    for a in range(0, Tn, step):
        Xb = X[a:a + step]
        Q = (0.0 + Xb[:, None, :] * Xb[:, :, None]) - S1t[None, :, :]   # [t, j, i] = x_i x_j - S1[i, j]
        Q = (Q * Q).reshape(Xb.shape[0], N * N)
        acc[a:a + step] = r_rowsums(Q) / N
    return acc


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


def _sprintf(fmt, *args):
    return _fmt.sprintf(fmt, *args)


# ═══════════════════════════════════════════════════════════════════════════
# Renditen, Prüfungen
# ═══════════════════════════════════════════════════════════════════════════

class _OptReturns(dict):
    """Interne Renditen mit ppy (R-Klasse ``SimLevOptReturns``, portfolio_cpcv)."""


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
        isnum = all(_is_numeric_col(x[c]) for c in x.columns)   # seit 1.6.4 ohne Wahrheitswerte (B-040, wie R)
        A = x.to_numpy(dtype=np.float64) if isnum else x.to_numpy(dtype=object)
    else:
        if not isinstance(x, (np.ndarray, pd.Series)):          # seit 1.6.4 wie R: keine Liste (B-057)
            raise ValueError("x muss Kursdaten mit Spalte 'date' oder eine numerische Renditematrix sein.")
        A = np.asarray(x)
        if A.ndim == 1:
            A = A.reshape(-1, 1)
        cn = None
        isnum = A.dtype.kind in "iuf"                           # seit 1.6.4 ohne Wahrheitswerte (B-040, wie R)
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


def _opt_check_x(x, assets, fn):
    """Eingabe ``x`` und ``assets`` der Optimierungsfunktionen (seit 1.6.4, K42 E4; R ``.opt_check_x``): ``assets``
    ``None`` oder Namen ohne NA, doppelte und ``'date'``; bei Kursdaten Datumsspalte keine Kategorie und die Anlagen
    als Zahlenspalten; bei einer Renditetabelle nur Zahlenspalten. Ergebnis: ``assets`` als Liste oder ``None``."""
    from .dependence import _e4_names, _e4_numcol
    assets = _e4_names(assets, fn, "assets", null_ok=True)
    if isinstance(x, pd.DataFrame) and "date" in [str(c) for c in x.columns]:
        chk_col_nofactor(x, "date", fn)
        if assets is not None:
            chk_cols(x, assets, fn)
            for a in assets:
                _e4_numcol(x, a, fn)
    elif isinstance(x, pd.DataFrame):
        cols = [str(c) for c in x.columns]
        for a in (assets if assets is not None else cols):
            if a in cols:
                _e4_numcol(x, a, fn)
    return assets


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
    # seit 1.6.4 ohne den Wert, Hinweise wertfrei (Entscheidung 8, wie 12)
    hint = ""
    if one and not chk_is_factor(alpha):
        a = float(vals[0])
        if a >= 1:
            hint = " - als Anteil angeben (Prozentangaben durch 100 teilen)"
        elif a > 0.5:
            hint = " - gemeint ist der Tail-Anteil, nicht das Konfidenzniveau (alpha = 1 - Konfidenzniveau)"
    raise ValueError("%s: alpha muss die Tail-Wahrscheinlichkeit als Anteil in (0, 0.5] sein, z. B. 0.05 = schlechteste "
                     "5 %%%s." % (fn, hint))


def _opt_bounds(b, nm, default, what="upper"):
    """``.opt_bounds``: Skalar, benannter oder positionsweiser Vektor -> Wert je Anlage."""
    names, vals, isnum = _named_vec(b)
    if (not isnum or not len(vals) or any(_isna(v) for v in vals) or chk_is_factor(b)
            or (isinstance(b, np.ndarray) and b.ndim > 1)):   # seit 1.6.4 ohne Wert, keine Kategorie/Matrix
        raise ValueError("%s: numerischer Wert bzw. Vektor ohne NA erwartet." % what)
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
        raise ValueError("lower: Untergrenzen müssen >= 0 sein (Long-only).")   # seit 1.6.4 ohne Wert
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
    e = _lib.eigen_sym(M)
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
        S1 = np.asarray(_lib.crossprod(X), dtype=np.float64) / Tn
        m = _sum(np.diag(S1)) / N
        dm = _la.diag(m, N)

        def nrm(A):
            return _sumsq_f(A) / N

        d2 = nrm(S1 - dm)
        if X.size and np.isfinite(X).all() and np.abs(X).max() < 1e75 and np.isfinite(S1).all():
            acc = _lw_acc(X, S1)   # ohne Überlauf, also auch ohne numpy-Warnung (wie die Schleife)
        else:   # NaN/Inf oder sehr große Werte: Schleife wie bis 1.6.2 (Nutzlasten, Überlaufwarnungen gleich)
            acc = np.empty(Tn)
            for t in range(Tn):
                acc[t] = nrm(np.asarray(_lib.tcrossprod(X[t, :]), dtype=np.float64) - S1)
        b2 = min(d2, _sum(acc) / (Tn * Tn))
        a2 = d2 - b2
        if not d2 > 0:
            chk_stop("e4.lw")                                     # Entscheidung 73 (B-039): keine neue Rechnung
        Sh = (b2 / d2) * dm + (a2 / d2) * S1
        return Sh * Tn / (Tn - 1)
    if type == "ewma":
        hl = min(52, max(5, Tn / 4))
        lam = r_pow(0.5, 1 / hl)
        w = _pow_rec(lam, np.arange(Tn - 1, -1, -1, dtype=np.float64))
        w = w / _sum(w)
        mu = np.array([_sum(R[:, j] * w) for j in range(N)])
        X = R - mu[None, :]
        Xs = X * np.sqrt(w)[:, None]
        C = np.asarray(_lib.crossprod(Xs), dtype=np.float64) / (1 - _sum(w * w))
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
        e = _lib.eigen_sym(C)
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
    Uu = np.asarray(_lib.crossprod(Up), dtype=np.float64)
    Dd = np.asarray(_lib.crossprod(Dn), dtype=np.float64)
    Ud = np.asarray(_lib.crossprod(Up, Dn), dtype=np.float64)
    nc = Uu + Dd
    nd = Ud + Ud.T
    with np.errstate(all="ignore"):
        G = np.where(nc + nd > 0, (nc - nd) / (nc + nd), 0.0)
    G[np.arange(N), np.arange(N)] = 1.0
    return _psd(G * np.asarray(_la.outer(sd, sd), dtype=np.float64), N)


def _opt_cov_once(A, cov_type, ppy, scache):
    """``_opt_cov_m(A, cov_type) * ppy``; mit ``scache`` (dict) dort zusätzlich eine Kopie unter ``"S"``, wenn die
    Rechnung keine Meldung geben konnte (seit 1.6.4, B-072: Wiederverwendung in ``_opt_vol`` und
    ``portfolio_risk_contributions``). ``denoise`` kann über ``cov2cor`` warnen und wird nicht gemerkt."""
    if scache is None or cov_type == "denoise":
        return _opt_cov_m(A, cov_type) * ppy
    S0, q = _fp_quiet(lambda: _opt_cov_m(A, cov_type))
    S = (S0 if q else _opt_cov_m(A, cov_type)) * ppy
    if q:
        scache["S"] = S.copy()
    return S


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
    ev = np.asarray(_lib.eigen_sym(Q, only_values=True)["values"], dtype=np.float64)
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
        dx = np.asarray(_lib.solve_spd(H, g), dtype=np.float64).ravel()   # H symmetrisch positiv definit
        step = 1.0
        fyc = []

        def fy():
            # seit 1.6.4 f(y) einmal je Schritt (B-107), wenn y > 0 und ohne Gleitkomma-Meldung; sonst wie bisher
            if fyc:
                return fyc[0]
            if (y > 0).all():
                v, q = _fp_quiet(lambda: f(y))
                if q:
                    fyc.append(v)
                    return v
            return f(y)
        while True:
            yn = y - step * dx
            if (yn <= 0).any():
                cond = True
            else:
                cond = f(yn) > fy() - 1e-4 * step * _sum(g * dx)
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
    C = np.concatenate(([0.0], r_cumsum(r)))   # C-Kern (cumsum in long double wie R)
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

def _opt_core(R, method, lo, hi, cov_type, mu, risk_free, risk_aversion, budget, alpha, ppy, scache=None):
    """``.opt_core``: ein Optimierungsschritt auf einer Renditematrix (DataFrame); ``scache`` siehe
    :func:`_opt_cov_once`."""
    nm = [str(c) for c in R.columns]
    A = R.to_numpy(dtype=np.float64)
    N = A.shape[1]
    S = _opt_cov_once(A, cov_type, ppy, scache)
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
        k = _which_max(sh, 0)
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
        return cand[_which_max(np.array([sh[k], f1[1], f2[1]]), 0)]

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


# ═══════════════════════════════════════════════════════════════════════════
# portfolio_optimize
# ═══════════════════════════════════════════════════════════════════════════

class SimLevOptimization(RList):
    """Ergebnis von :func:`portfolio_optimize` (R-Klasse ``SimLevOptimization``)."""

    r_class = ("SimLevOptimization",)

    def format(self):
        return print_SimLevOptimization(self, _return=True)

    # ``plot`` (SVG, ``SimLevPlot``) wird am Modulende über ``_plot_method`` gesetzt.


def portfolio_optimize(x, *, assets=None, method=_METHODS, lower=0, upper=1, cov=_COVS, mu=None, risk_free=0,
                       risk_aversion=4, budget=None, alpha=0.05, frequency=_FREQS, resample=0, block=None, seed=None):
    """Portfolio optimieren (Long-only, Summe 1, optionale Grenzen je Anlage).

    Bestimmt Gewichte für ein Long-only-Portfolio (Summe 1) mit optionalen Grenzen je Anlage aus historischen
    Periodenrenditen. Eingabe ist entweder ein DataFrame mit Kursen oder eine fertige Renditematrix; Ergebnis sind
    Gewichte, Kennzahlen und Risikobeiträge.

    Args:
        x: DataFrame mit Spalte ``date`` (Date) und Kursspalten (Kursniveaus, keine Renditen) oder numerische
            Matrix bzw. DataFrame ohne ``date`` mit einfachen Periodenrenditen als Anteil (Zeilen = Perioden,
            Spalten = Anlagen; ohne Spaltennamen ``A1``, ``A2``, ...).
        assets: Zeichenvektor der zu verwendenden Spalten. ``None`` (Standard) = alle numerischen Spalten außer
            ``date`` bzw. alle Spalten der Matrix.
        method: Verfahren (siehe Tabelle oben): ``"min_variance"`` (Standard), ``"max_sharpe"``,
            ``"mean_variance"``, ``"max_diversification"``, ``"risk_parity"``, ``"hrp"``, ``"min_cvar"``,
            ``"min_cdar"``, ``"inverse_vol"`` oder ``"equal"``. ``risk_parity``, ``hrp``, ``inverse_vol`` und
            ``equal`` ignorieren ``lower``/``upper`` (mit Warnung, wenn andere als die Standardgrenzen angegeben
            sind). ``risk_parity``, ``hrp`` und ``inverse_vol`` brechen bei Anlagen ohne Schwankung (Volatilität
            0, z. B. Geldmarkt mit festem Zins) mit Fehler ab.
        lower, upper: Unter- und Obergrenzen der Gewichte als Anteil (0.6 = 60 %): Skalar für alle Anlagen,
            benannter Vektor (nicht genannte Anlagen erhalten 0 bzw. 1; unbekannte Namen sind ein Fehler) oder
            unbenannter Vektor mit genau einem Wert je Anlage (in der Reihenfolge der Spalten; andere Längen sind
            ein Fehler). Standard 0 und 1. Keine NA; ``lower`` >= 0 (Long-only). Erforderlich ist sum(lower) <= 1
            <= sum(upper) und lower <= upper. ``Inf`` in ``upper`` bedeutet keine Obergrenze und wird als 1
            geführt (auch in ``bounds``); andere Obergrenzen > 1 wirken ebenfalls wie 1, erzeugen aber eine
            Warnung (vermutlich Prozent statt Anteil, z. B. 26 statt 0.26).
        cov: Kovarianzschätzer: ``"sample"`` (Standard, Stichprobe), ``"ledoit_wolf"`` (Schrumpfung auf skalierte
            Einheitsmatrix, Ledoit & Wolf 2004), ``"ewma"`` (exponentiell gewichtet, Halbwertszeit ein Viertel der
            Stichprobe, 5 bis 52 Perioden), ``"denoise"`` (Marchenko-Pastur-Rauschfilter, Laloux et al. 1999) oder
            ``"gerber"`` (Gerber-Statistik, Gerber et al. 2022).
        mu: Optional erwartete Renditen in Prozent p. a. (5 = 5 %), endlich, ohne NA: benannter Vektor (unbekannte
            Namen sind ein Fehler), unbenannter Vektor mit genau einem Wert je Anlage (in der Reihenfolge der
            Spalten) oder Skalar (für alle Anlagen gleich); nur für ``max_sharpe`` und ``mean_variance`` verwendet
            (fehlt dort eine Anlage im benannten Vektor, bricht die Funktion mit ihrem Namen ab). ``None``
            (Standard) = historisches arithmetisches Mittel, annualisiert.
        risk_free: Risikoloser Zins in Prozent p. a. (Standard 0) für ``max_sharpe`` und die ausgewiesene Sharpe
            Ratio.
        risk_aversion: Risikoaversion γ für ``mean_variance`` (Standard 4), bezogen auf Rendite und Varianz als
            Anteil p. a.
        budget: Risikobudgets für ``risk_parity``: Skalar (gleiche Budgets), benannter Vektor (nicht genannte
            Anlagen 0) oder unbenannter Vektor mit einem Wert je Anlage (Spaltenreihenfolge); Werte >= 0, wird auf
            Summe 1 normiert. ``None`` (Standard) = gleiche Risikobeiträge.
        alpha: Tail-Wahrscheinlichkeit als Anteil für CVaR und CDaR (Standard 0.05 = schlechteste 5 % der Perioden
            bzw. Drawdowns), im Bereich (0, 0.5]; nicht das Konfidenzniveau (0.95) und nicht in Prozent (5) -
            beides ist ein Fehler. Wirkt auf ``min_cvar``, ``min_cdar`` und die ausgewiesenen Kennzahlen.
        frequency: Renditefrequenz: ``"week"`` (Standard), ``"day"`` oder ``"month"``. Bei Kursdaten Aggregation
            (ISO-Woche, Kalendermonat); bei einer Renditematrix nur die Perioden je Jahr (52, 252, 12).
        resample: Anzahl Block-Bootstrap-Stichproben für das Michaud-Resampling (ganze Zahl, Standard 0 = aus);
            die Gewichte sind dann das Mittel der Einzeloptimierungen.
            Seit 1.6.4 höchstens 10^8.
        block: Mittlere Blocklänge des stationären Bootstraps für das Resampling in Perioden. ``None`` (Standard)
            = T^1/3 gerundet, mindestens 2 (T = Anzahl Perioden).
        seed: Startwert für das Resampling. Mit Startwert (ganze Zahl, |seed| < 2^53) ist das Ergebnis
            reproduzierbar und der Zufallszustand von SimLev bleibt unverändert; mit ``None`` wird genau einmal
            ein Startwert aus dem Zufallszustand von SimLev gezogen (siehe ``simlev_seed()``), wiederholte Aufrufe
            liefern dann verschiedene Ergebnisse. ``set.seed()`` wirkt nicht.

    Returns:
        Objekt der Klasse ``SimLevOptimization``, eine Liste mit

        - weights: Benannter Gewichtsvektor (Anteile, Summe 1).
        - stats: Benannter Vektor: ``expected_return`` (historisches Mittel, annualisiert, Anteil p. a.; auch wenn
          ``mu`` angegeben ist), ``volatility`` (Anteil p. a.), ``sharpe`` (bei Volatilität 0 wie auch
          ``diversification_ratio``, ``effective_n_risk`` und ``risk_share`` ``NA``, mit Warnung), ``cvar``
          (historischer CVaR je Periode, Verlust positiv, Anteil), ``cdar`` (CDaR der kumulierten, nicht
          aufgezinsten Rendite, Anteil), ``diversification_ratio``, ``effective_n`` (1 / Σ w^2),
          ``effective_n_risk`` (dasselbe für die Risikoanteile).
        - risk: DataFrame je Anlage: ``asset``, ``weight``, ``volatility_contribution`` (Anteil p. a., Summe =
          Volatilität), ``risk_share`` (Anteil an der Volatilität).

        sowie ``alpha``, ``method``, ``bounds`` (Matrix der Grenzen), ``resampled`` (Gewichte je Stichprobe oder
        ``None``), ``cov_type``, ``frequency``, ``n_obs`` (Anzahl Perioden). Methoden ``print`` und ``plot``.

    Details:
        Renditen: Bei einem DataFrame mit Spalte ``date`` werden die Kurse wie in ``dependence_analysis()``
        aufbereitet (Fortschreiben fehlender Werte, letzte Zeile je ISO-Woche bzw. Kalendermonat, bei ``"day"``
        jede Zeile außer Tagen, an denen sich keine Anlage bewegt) und in einfache Renditen P_t / P_t-1 - 1
        (Anteile) umgerechnet; die Perioden je Jahr werden aus den Daten ermittelt. Jede andere Eingabe wird als
        Matrix einfacher Periodenrenditen als Anteil (0.01 = 1 %) behandelt; Zeilen mit fehlenden Werten
        entfallen, unendliche Renditen (``Inf``) sind ein Fehler (mit Spalte und Zeile), die Perioden je Jahr sind
        dann fest 252 (``"day"``), 52 (``"week"``) bzw. 12 (``"month"``). Erwartete Renditen und Kovarianz werden
        mit diesen Perioden je Jahr annualisiert.

        - ``min_variance`` | minimale Varianz
        - ``mean_variance`` | max μ'w - (γ)/(2) w'Σ w mit Risikoaversion ``risk_aversion``
        - ``max_sharpe`` | maximale Sharpe Ratio (Suche entlang der Effizienzgrenze)
        - ``max_diversification`` | maximales Diversifikationsverhältnis w'σ / √(w'Σ w) (Choueifaty & Coignard
          2008)
        - ``risk_parity`` | gleiche (oder vorgegebene, ``budget``) Risikobeiträge (Spinu 2013)
        - ``hrp`` | Hierarchical Risk Parity (Lopez de Prado 2016)
        - ``min_cvar`` | minimaler historischer CVaR (Rockafellar & Uryasev 2000, geglättet)
        - ``min_cdar`` | minimaler Conditional Drawdown at Risk (Chekhlov, Uryasev & Zabarankin 2005)
        - ``inverse_vol``, ``equal`` | einfache Heuristiken

        Erwartete Renditen aus der Historie sind sehr unsicher; Verfahren, die sie nutzen (``max_sharpe``,
        ``mean_variance``), reagieren stark auf Schätzfehler. ``resample`` mittelt die Gewichte über
        Block-Bootstrap- Stichproben der Historie (Michaud-Resampling) und glättet diese Abhängigkeit.

    Literatur:
        Ledoit, O. & Wolf, M. (2004), Journal of Multivariate Analysis 88(2); Spinu, F. (2013), SSRN 2297383;
        Lopez de Prado, M. (2016), Journal of Portfolio Management 42(4); Rockafellar, R. T. & Uryasev, S. (2000),
        Journal of Risk 2(3); Michaud, R. (1998), Efficient Asset Management.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        R = pd.DataFrame(rng.normal([0.002, 0.001, 0.0005], [0.03, 0.02, 0.01], (520, 3)), columns=["aktien", "reits", "anleihen"])
        print(simlev.portfolio_optimize(R, method="risk_parity"))
    """
    return _portfolio_optimize(x, assets=assets, method=method, lower=lower, upper=upper, cov=cov, mu=mu,
                               risk_free=risk_free, risk_aversion=risk_aversion, budget=budget, alpha=alpha,
                               frequency=frequency, resample=resample, block=block, seed=seed)


def _portfolio_optimize(x, *, assets=None, method=_METHODS, lower=0, upper=1, cov=_COVS, mu=None, risk_free=0,
                        risk_aversion=4, budget=None, alpha=0.05, frequency=_FREQS, resample=0, block=None, seed=None,
                        weights_only=False):
    """``portfolio_optimize``; ``weights_only=True`` (portfolio_rolling, seit 1.5.1): nur die Gewichte, von den
    Kennzahlen nur die Prüfung der Volatilität mit ihrer Warnung (gleiche Meldungen wie das volle Ergebnis)."""
    method = _match_arg(method, _METHODS)
    cov = _match_arg(cov, _COVS)
    frequency = _match_arg(frequency, _FREQS)
    fn = "portfolio_optimize"                                  # seit 1.6.4 vor der Rechnung (K42 E4)
    assets = _opt_check_x(x, assets, fn)
    risk_free = chk_num1(risk_free, fn, "risk_free")           # B-018
    risk_aversion = chk_num1(risk_aversion, fn, "risk_aversion", lo=0)
    from .dependence import _e4_count
    resample = _e4_count(resample, fn, "resample", lo=0)       # B-018
    block = chk_num1(block, fn, "block", lo=1, null_ok=True)
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
            raise ValueError("mu: endliche Werte in Prozent p. a. erwartet.")   # seit 1.6.4 ohne Wert
    ppy = rr["ppy"]

    def core(Rx, scache=None):
        return _opt_core(Rx, method, lo, hi, cov, mu, risk_free, risk_aversion, budget, alpha, ppy, scache)

    sc = {}                                                    # Kovarianz von R für _opt_vol (seit 1.6.4, B-072)
    w = core(R, sc)
    wb = None
    if resample > 0:
        T = len(R)
        if block is None:
            block = max(2, float(_fmt.r_round(r_pow(T, 1 / 3))))
        from ._lib import main_stream
        from ._lib_models import boot_idx_stationary

        A = R.to_numpy(dtype=np.float64)
        S = main_stream(seed, "portfolio_optimize")                           # Hauptstrom
        wbm = np.empty((int(resample), N))
        for bb in range(int(resample)):
            idx = np.asarray(boot_idx_stationary(T, T, block, stream=S), dtype=np.int64) - 1
            wbm[bb, :] = core(pd.DataFrame(A[idx, :], columns=nm)).to_numpy()
        wb = pd.DataFrame(wbm, columns=nm)
        wv = _colmeans(wbm)
        w = pd.Series(wv / _sum(wv), index=nm)
    if weights_only:
        _opt_vol(w.to_numpy(dtype=np.float64), R.to_numpy(dtype=np.float64), ppy, cov, sc.get("S"))
        return w
    out = _opt_summary(w, R, ppy, cov, risk_free, alpha, sc.get("S"))
    res = SimLevOptimization(out)
    res["method"] = method
    res["bounds"] = pd.DataFrame(np.vstack([lo, hi]), index=["lower", "upper"])
    res["resampled"] = wb
    res["cov_type"] = cov
    res["frequency"] = frequency
    res["n_obs"] = len(R)
    return res


def _opt_vol(wv, A, ppy, cov_type, S=None):
    """Kovarianz (annualisiert) und Volatilität des Portfolios wie in ``.opt_summary`` mit dessen Warnung bei
    Volatilität 0: ``(S, vol, vq)`` (``vq`` NA bei Volatilität 0). ``S``: schon gerechnete Kovarianz von ``A``
    (seit 1.6.4, B-072, aus :func:`_opt_cov_once`), sonst neu."""
    if S is None:
        S = _opt_cov_m(A, cov_type) * ppy
    q = _quad(wv, S)
    vol = math.sqrt(max(q, 0.0)) if not math.isnan(q) else q
    if vol <= 1e-10:
        _warn("Portfolio ohne Schwankung (Volatilität 0, nur Anlagen mit konstanter Rendite): Sharpe Ratio, "
              "Diversifikationsverhältnis und Risikoanteile sind nicht definiert (NA).")
        return S, 0.0, _NA
    return S, vol, vol


def _opt_summary(w, R, ppy, cov_type, risk_free, alpha, S=None):
    """``.opt_summary``: Kennzahlen eines Gewichtsvektors (``S`` siehe :func:`_opt_vol`)."""
    A = R.to_numpy(dtype=np.float64)
    nm = list(w.index)
    wv = w.to_numpy(dtype=np.float64)
    m = _colmeans(A) * ppy
    ret = _sum(wv * m)
    rp = _mat_vec(A, wv)
    S, vol, vq = _opt_vol(wv, A, ppy, cov_type, S)
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
# portfolio_frontier
# ═══════════════════════════════════════════════════════════════════════════

class SimLevFrontier(RList):
    """Ergebnis von :func:`portfolio_frontier` (R-Klasse ``SimLevFrontier``)."""

    r_class = ("SimLevFrontier",)

    def format(self):
        return print_SimLevFrontier(self, _return=True)

    # ``plot`` (SVG, ``SimLevPlot``) wird am Modulende über ``_plot_method`` gesetzt.


def _dup_key(v):
    return tuple(("NaN" if _fmt._is_rnan(z) else "NA") if math.isnan(z) else (0.0 if z == 0 else z) for z in v)


def portfolio_frontier(x, *, assets=None, n=40, lower=0, upper=1, cov=_COVS, risk_free=0, frequency=_FREQS):
    """Effizienzgrenze: für ``n`` Risikoaversionen von 1e4 bis 0.02 (logarithmisch) ``max mu'w - gamma/2 w'Sigma w`` unter denselben Grenzen wie :func:`portfolio_optimize`.

    Berechnet Mean-Variance-effiziente Long-only-Portfolios unter denselben Grenzen wie ``portfolio_optimize()``:
    Für ``n`` Risikoaversionen γ von 1e4 bis 0.02 (logarithmisch gestuft) wird max μ'w - (γ)/(2) w'Σ w gelöst, mit
    historischen Mitteln und Kovarianz (annualisiert). Eingabe und Renditeberechnung wie bei
    ``portfolio_optimize()`` (Kurs-DataFrame mit ``date`` oder Matrix einfacher Periodenrenditen als Anteil); die
    Grenzen werden ebenso geprüft (unerfüllbare Grenzen sind ein Fehler). ``print`` zeigt den Punkt mit der
    kleinsten Volatilität ("Minimum-Varianz") und den mit der höchsten Sharpe Ratio, ``plot`` zeichnet die Grenze
    mit den Einzelanlagen und markiert den Punkt mit der höchsten Sharpe Ratio.

    Args:
        x: DataFrame mit Spalte ``date`` (Date) und Kursspalten (Kursniveaus, keine Renditen) oder numerische
            Matrix bzw. DataFrame ohne ``date`` mit einfachen Periodenrenditen als Anteil (Zeilen = Perioden,
            Spalten = Anlagen; ohne Spaltennamen ``A1``, ``A2``, ...).
        assets: Zeichenvektor der zu verwendenden Spalten. ``None`` (Standard) = alle numerischen Spalten außer
            ``date`` bzw. alle Spalten der Matrix.
        n: Anzahl der Risikoaversionen (ganze Zahl, Standard 40). Punkte mit (auf 6 Stellen) gleicher Rendite und
            Volatilität werden nur einmal behalten; das Ergebnis kann daher weniger Zeilen haben.
            Seit 1.6.4 höchstens 10^6.
        lower, upper: Unter- und Obergrenzen der Gewichte als Anteil (0.6 = 60 %): Skalar für alle Anlagen,
            benannter Vektor (nicht genannte Anlagen erhalten 0 bzw. 1; unbekannte Namen sind ein Fehler) oder
            unbenannter Vektor mit genau einem Wert je Anlage (in der Reihenfolge der Spalten; andere Längen sind
            ein Fehler). Standard 0 und 1. Keine NA; ``lower`` >= 0 (Long-only). Erforderlich ist sum(lower) <= 1
            <= sum(upper) und lower <= upper. ``Inf`` in ``upper`` bedeutet keine Obergrenze und wird als 1
            geführt (auch in ``bounds``); andere Obergrenzen > 1 wirken ebenfalls wie 1, erzeugen aber eine
            Warnung (vermutlich Prozent statt Anteil, z. B. 26 statt 0.26).
        cov: Kovarianzschätzer: ``"sample"`` (Standard, Stichprobe), ``"ledoit_wolf"`` (Schrumpfung auf skalierte
            Einheitsmatrix, Ledoit & Wolf 2004), ``"ewma"`` (exponentiell gewichtet, Halbwertszeit ein Viertel der
            Stichprobe, 5 bis 52 Perioden), ``"denoise"`` (Marchenko-Pastur-Rauschfilter, Laloux et al. 1999) oder
            ``"gerber"`` (Gerber-Statistik, Gerber et al. 2022).
        risk_free: Risikoloser Zins in Prozent p. a. (Standard 0) für ``max_sharpe`` und die ausgewiesene Sharpe
            Ratio.
        frequency: Renditefrequenz: ``"week"`` (Standard), ``"day"`` oder ``"month"``. Bei Kursdaten Aggregation
            (ISO-Woche, Kalendermonat); bei einer Renditematrix nur die Perioden je Jahr (52, 252, 12).

    Returns:
        Objekt der Klasse ``SimLevFrontier`` mit ``frontier`` (DataFrame je Punkt: ``expected_return``,
        ``volatility`` als Anteil p. a., ``sharpe`` mit ``risk_free`` (``NA`` bei Volatilität 0), dann je Anlage
        eine Gewichtsspalte), ``assets`` (DataFrame der Einzelanlagen: ``asset``, ``expected_return``,
        ``volatility``, Anteil p. a.), ``risk_free`` und ``frequency``. Methoden ``print`` und ``plot``.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        R = pd.DataFrame(rng.normal([0.002, 0.001, 0.0005], [0.03, 0.02, 0.01], (520, 3)), columns=["aktien", "reits", "anleihen"])
        ef = simlev.portfolio_frontier(R, n=20, upper=0.7)
        print(ef["frontier"].head(3))
    """
    cov = _match_arg(cov, _COVS)
    frequency = _match_arg(frequency, _FREQS)
    fn = "portfolio_frontier"                                  # seit 1.6.4 vor der Rechnung (K42 E4)
    assets = _opt_check_x(x, assets, fn)
    from .dependence import _e4_count
    from ._pruefen import SL_MAX_GITTER
    n = _e4_count(n, fn, "n", hi=SL_MAX_GITTER)                 # B-011, B-038
    risk_free = chk_num1(risk_free, fn, "risk_free")
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
    ks = [] if np.isnan(sh).all() else [_which_max(sh, 0)]
    j = _which_min(f["volatility"].to_numpy(dtype=np.float64), 0)
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
    k = None if np.isnan(sh).all() else _which_max(sh, 0)
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
# portfolio_rolling
# ═══════════════════════════════════════════════════════════════════════════

def _err_text(e):
    return str(e.args[0]) if getattr(e, "args", None) and isinstance(e.args[0], str) else str(e)


def portfolio_rolling(data, assets, *, method="min_variance", window=3, every=("month", "quarter", "year"),
                         frequency=_FREQS, **kwargs):
    """Rollierende Optimierung (Zielgewichte außerhalb der Stichprobe).

    Optimiert an jedem Entscheidungstermin auf den Renditen des zurückliegenden Fensters und hält die Gewichte bis
    zum nächsten Termin. Das Ergebnis ist eine Zielgewichtsreihe für ``tactical_simulation()``; jede Entscheidung
    nutzt nur Daten bis einschließlich des Entscheidungstags (gehandelt wird in ``tactical_simulation()`` mit
    dessen ``lag``).

    Args:
        data: DataFrame mit Spalte ``date`` (Date) und Kursspalten (Kursniveaus, keine Renditen), z. B. aus
            ``series_align()``. Eine Renditematrix ist hier nicht möglich.
        assets: Zeichenvektor der Kursspalten (Pflicht).
        method: Verfahren wie in ``portfolio_optimize()`` (Zeichenkette, Standard ``"min_variance"``).
        window: Fensterlänge in Jahren (Standard 3).
            Seit 1.6.4 eine ganze Zahl von 1 bis 100 (Jahre).
        every: Entscheidungsrhythmus: ``"month"`` (Standard), ``"quarter"`` oder ``"year"``.
        frequency: Renditefrequenz innerhalb des Fensters: ``"week"`` (Standard, ISO-Woche), ``"day"`` oder
            ``"month"``.
        **kwargs: Weitere Argumente für ``portfolio_optimize()`` (``lower``, ``upper``, ``cov``, ``mu``,
            ``risk_free``, ``budget``, ``alpha``, ``resample``, ...).

    Returns:
        Objekt der Klasse ``SimLevWeights`` (DataFrame mit ``date`` und einer Gewichtsspalte je Anlage, Anteile
        mit Zeilensumme 1, eine Zeile je Zeile von ``data``); vor dem ersten Entscheidungstermin gleich gewichtet.
        Attribute ``source`` (``"rolling <method>"``), ``decision_rows`` (Zeilennummern der Entscheidungstermine)
        und ``failed_dates`` (Date-Vektor der Termine mit fehlgeschlagener Optimierung, dort Gleichgewichtung;
        leer, wenn keine).

    Details:
        Entscheidungstermine sind die letzten Zeilen jedes Monats, Quartals bzw. Jahres, deren Datum mindestens
        ``window`` Jahre (``window * 365.25`` Tage, gerundet) nach dem ersten Datum liegt. Das Fenster umfasst die
        Zeilen mit Datum im Zeitraum (Termin - ``window * 365.25`` Tage, Termin]. Argumentfehler (unbekanntes
        ``method``, unbekannte Argumente in ``...``, unerfüllbare Grenzen) brechen sofort ab. Schlägt eine
        Optimierung an einem Termin fehl (z. B. zu wenige Perioden im Fenster), gilt dort Gleichgewichtung; die
        Funktion warnt mit der Anzahl und der ersten Fehlermeldung. Die Zeilen von ``data`` werden nach ``date``
        sortiert (mit Hinweis, falls nötig).

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 1825
        d = pd.DataFrame({"date": pd.date_range("2015-01-01", periods=n)})
        d["aktien"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        d["anleihen"] = 100 * np.cumprod(1 + rng.normal(1e-4, 0.003, n))
        w = simlev.portfolio_rolling(d, ["aktien", "anleihen"], window=2, every="quarter")
        print(w)
    """
    every = _match_arg(every, ("month", "quarter", "year"))
    frequency = _match_arg(frequency, _FREQS)
    fn = "portfolio_rolling"
    method = chk_scalar(method)
    if not isinstance(method, str) or method not in _METHODS:   # seit 1.6.4 ohne Wert
        raise ValueError("portfolio_rolling: unbekanntes Verfahren; erlaubt: %s." % ", ".join(_METHODS))
    dots = dict(kwargs)
    allowed = [a for a in _PO_FORMALS if a not in ("x", "assets", "method", "frequency")]
    # seit 1.6.4 einheitlich (Entscheidung 21); x und assets setzt portfolio_rolling selbst
    chk_dots(list(dots), allowed, fn, taken=("x", "assets", "method", "frequency"))
    from ._pruefen import chk_jahre
    from .dependence import _e4_names, _e4_numcol
    window = chk_jahre(window, fn, "window")                     # B-098, Entscheidung 70 (ganze Jahre 1 bis 100)
    assets = _e4_names(assets, fn, "assets")
    if not isinstance(data, pd.DataFrame) or "date" not in [str(c) for c in data.columns]:
        raise ValueError("portfolio_rolling: data.frame mit Spalte 'date' erwartet.")
    miss = _setdiff(assets, [str(c) for c in data.columns])
    if miss:
        raise ValueError("Spalten fehlen: %s" % ", ".join(miss))
    chk_col_nofactor(data, "date", fn)
    for a in assets:
        _e4_numcol(data, a, fn)
    _opt_check_bounds(0 if dots.get("lower") is None else dots["lower"],
                      1 if dots.get("upper") is None else dots["upper"], assets)
    _opt_check_alpha(0.05 if dots.get("alpha") is None else dots["alpha"], "portfolio_rolling")
    if dots.get("mu") is not None:
        _opt_bounds(dots["mu"], assets, _NA, "mu")
    from .dependence import _dep_sort_dates
    data = _dep_sort_dates(data, "data").reset_index(drop=True)
    d = _days(np.asarray(data["date"]))
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
    pre = _roll_prep(data, d, assets, frequency)      # seit 1.5.1: Kurse und Perioden einmal statt je Fenster
    for k, i1 in enumerate(rows):
        di = d[i1 - 1]
        lo = int(np.searchsorted(d, di - wd, side="right")) if pre is not None else 0
        w = None
        try:
            with warnings.catch_warnings():
                warnings.filterwarnings("ignore", category=SimLevBoundsPercent)
                if pre is not None and lo <= i1 - 1:
                    rr = _roll_returns(pre, lo, i1 - 1, assets, frequency)
                    w = _portfolio_optimize(rr, method=method, frequency=frequency, weights_only=True, **dots)
                else:
                    sel = (d > di - wd) & (d <= di)
                    sub = data.loc[sel, sub_cols].reset_index(drop=True)
                    w = portfolio_optimize(sub, assets=assets, method=method, frequency=frequency, **dots)["weights"]
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
        _warn("portfolio_rolling: Optimierung an %d von %d Terminen fehlgeschlagen (erster am %s: %s); dort "
              "Gleichgewichtung. Termine im Attribut 'failed_dates'."
              % (len(failed), len(rows), _fmt.format(_as_dates([d[rows[f0] - 1]]))[0], msg[f0]))
    H = _hold_rows_m(n, rows, M)
    H[:rows[0] - 1, :] = 1 / N
    out = _as_weights_m(_as_dates(d), H, assets, "rolling %s" % method)
    out.attrs["decision_rows"] = rows
    out.attrs["failed_dates"] = _as_dates(d[rows[failed] - 1]) if failed else _as_dates(np.zeros(0))
    return out


class _RetMat:
    """Renditematrix eines Fensters ohne pandas (portfolio_rolling, seit 1.5.1): ``columns``, ``to_numpy()``,
    ``len()`` wie der DataFrame, den ``_opt_returns`` sonst baut."""

    __slots__ = ("A", "columns")

    def __init__(self, A, columns):
        self.A = A
        self.columns = columns

    def __len__(self):
        return self.A.shape[0]

    def to_numpy(self, dtype=None):
        return self.A


def _roll_prep(data, d, assets, frequency):
    """Einmal je ``portfolio_rolling`` (seit 1.5.1; bis 1.5.0 je Fenster in ``_dep_returns``): Kurse je Spalte,
    unzulässige Kurse (kumuliert), letzte vorhandene Zeile je Tag (Fortschreiben), Logarithmen und Periodenwechsel
    (ISO-Woche bzw. Monat). ``None`` bei Spalten, die nicht eindeutig numerisch sind (dann je Fenster wie bisher)."""
    from .dependence import _num, _period_breaks
    cols = [str(c) for c in data.columns]
    if not assets or len(set(assets)) != len(assets) or "date" in assets or any(cols.count(a) != 1 for a in assets):
        return None
    if any(data[a].dtype.kind not in "fiub" for a in assets):
        return None
    n = len(d)
    V = np.empty((n, len(assets)))
    for j, a in enumerate(assets):
        V[:, j] = _num(data[a])
    okv = ~np.isnan(V)
    bad = okv & (~np.isfinite(V) | (V <= 0))
    nbad = np.vstack([np.zeros((1, V.shape[1]), dtype=np.int64), np.cumsum(bad, axis=0)])
    idx = np.where(okv, np.arange(n)[:, None], -1)
    idx = np.maximum.accumulate(idx, axis=0)
    cj = np.arange(V.shape[1])[None, :]
    Vf = np.where(idx >= 0, V[np.maximum(idx, 0), cj], V)
    dates = _as_dates(d)
    brk = None
    if frequency != "day":
        brk = _period_breaks(dates, frequency)                 # seit 1.6.4 ganzzahlig (B-103, B-107)
    # Logarithmen ohne die Warnung "NaNs produced" (seit 1.6.4, T3-R1): unzulässige Kurse (< 0, -Inf) gehen nur in
    # Fenster ein, die _dep_check_prices vorher ablehnt; R und Julia warnen dort nicht (gleiche Bits)
    lg = lambda A: _libm._math1(1, _libm._log, A)                 # noqa: E731
    return {"V": V, "nbad": nbad, "idx": idx, "lv": lg(Vf), "lv0": lg(V), "brk": brk, "d": d, "dates": dates}


def _roll_returns(pre, lo, hi, assets, frequency):
    """Renditen des Fensters ``lo..hi`` (0-basiert, inklusive) wie ``_opt_returns(_dep_returns(Fenster))``: Prüfung
    der Kurse, Fortschreiben nur innerhalb des Fensters (führende Lücken bleiben), letzte Zeile je Periode,
    Log-Differenzen, Zeilen mit NA entfallen (bei ``"day"`` auch Tage ohne Bewegung), einfache Renditen und ppy."""
    from .dependence import _dep_check_prices
    V, nbad = pre["V"], pre["nbad"]
    for j, a in enumerate(assets):
        if nbad[hi + 1, j] > nbad[lo, j]:
            _dep_check_prices(V[lo:hi + 1, j], a, pre["dates"][lo:hi + 1])      # meldet wie je Fenster
    if frequency == "day":
        e = np.arange(lo, hi + 1)
    else:
        e = np.concatenate([np.flatnonzero(pre["brk"][lo:hi]) + lo, [hi]]).astype(np.int64)
    L = np.where(pre["idx"][e] >= lo, pre["lv"][e], pre["lv0"][e])
    R = L[1:, :] - L[:-1, :]
    ok = ~np.isnan(R).any(axis=1) if R.size else np.ones(R.shape[0], dtype=bool)
    if frequency == "day":
        ok &= (np.abs(R) > 0).sum(axis=1) > 0
    R = R[ok]
    dd = pre["d"][e][1:][ok]
    nr = R.shape[0]
    with np.errstate(all="ignore"):
        ppy = (nr - 1) / ((dd[nr - 1] - dd[0]) / 365.25) if nr else _NAN
    return _OptReturns(R=_RetMat(_libm.expm1(R).reshape(R.shape), list(assets)), ppy=float(ppy))


# ═══════════════════════════════════════════════════════════════════════════
# portfolio_risk_contributions
# ═══════════════════════════════════════════════════════════════════════════

def portfolio_risk_contributions(x, weights, *, measure=("volatility", "cvar"), alpha=0.05, frequency=_FREQS, cov=_COVS):
    """Risikobeiträge (Euler-Zerlegung) von Volatilität oder historischem CVaR.

    Zerlegt Volatilität oder historischen CVaR eines Portfolios additiv auf die Anlagen: RC_i = w_i ∂ ρ / ∂ w_i,
    Σ_i RC_i = ρ. Für die Volatilität RC_i = w_i (Σ w)_i / σ_p, für den CVaR der mittlere Verlustbeitrag der
    Anlage in den Perioden jenseits des VaR (historische Perioden, in denen der Portfolioverlust mindestens das (1
    - ``alpha``)-Quantil der Verluste erreicht). Eingabe und Renditeberechnung wie bei ``portfolio_optimize()``.

    Args:
        x: DataFrame mit Spalte ``date`` (Date) und Kursspalten (Kursniveaus) oder Matrix einfacher
            Periodenrenditen als Anteil (siehe ``portfolio_optimize()``).
        weights: Benannter Gewichtsvektor (Anteile; Namen = Spalten von ``x``, nur diese Anlagen gehen ein; wird
            nicht normiert; unbenannte Vektoren oder unbekannte Namen sind ein Fehler) oder Objekt der Klasse
            ``SimLevOptimization`` (dessen ``weights``).
        measure: Risikomaß: ``"volatility"`` (Standard, annualisiert) oder ``"cvar"`` (historischer CVaR je
            Periode).
        alpha: Tail-Wahrscheinlichkeit als Anteil für den CVaR (Standard 0.05 = schlechteste 5 % der Perioden), im
            Bereich (0, 0.5].
        frequency, cov: Siehe ``portfolio_optimize()`` (``cov`` nur für ``measure = "volatility"``).

    Returns:
        DataFrame je Anlage: ``asset``, ``weight``, ``contribution`` (Beitrag RC_i; bei ``"volatility"`` als
        Anteil p. a., bei ``"cvar"`` als Anteil je Periode, Verlust positiv), ``share`` (Anteil am Gesamtrisiko),
        ``marginal`` (marginaler Beitrag ∂ ρ / ∂ w_i, bei ``"cvar"`` der mittlere Verlust der Anlage in den
        Tail-Perioden, also ``contribution / weight``, auch für Gewicht 0 definiert). Attribute ``total``
        (Gesamtrisiko in derselben Einheit), ``measure``, ``effective_n`` (1 / Σ share^2) und nur bei
        ``"volatility"`` ``diversification_ratio``.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        R = pd.DataFrame(rng.normal([0.002, 0.001, 0.0005], [0.03, 0.02, 0.01], (520, 3)), columns=["aktien", "reits", "anleihen"])
        print(simlev.portfolio_risk_contributions(R, {"aktien": 0.5, "reits": 0.2, "anleihen": 0.3}))
    """
    measure = _match_arg(measure, ("volatility", "cvar"))
    frequency = _match_arg(frequency, _FREQS)
    cov = _match_arg(cov, _COVS)
    _opt_check_alpha(alpha, "portfolio_risk_contributions")
    if isinstance(weights, SimLevOptimization):
        weights = weights["weights"]
    fn = "portfolio_risk_contributions"
    names, vals, isnum = _named_vec(weights)
    # seit 1.6.4 auch ohne Inf, Kategorie und Matrix
    if (not isnum or names is None or any(k == "" for k in names) or any(_isna(v) for v in vals)
            or not all(math.isfinite(float(v)) for v in vals) or chk_is_factor(weights)):
        raise ValueError("weights: benannter numerischer Vektor ohne NA erwartet (Namen = Spalten von x).")
    if len(set(names)) < len(names):
        chk_stop("e2.doppelt", fn, "weights")                  # B-052
    if "date" in names:
        chk_stop("e4.date", fn, "weights")
    if isinstance(x, pd.DataFrame) and "date" in [str(c) for c in x.columns]:
        avail = [str(c) for c in x.columns if str(c) != "date"]
    elif isinstance(x, pd.DataFrame) and not isinstance(x.columns, pd.RangeIndex):
        avail = [str(c) for c in x.columns]
    else:
        nc = np.asarray(x).shape[1] if np.ndim(x) == 2 else 1
        avail = ["A%d" % (j + 1) for j in range(nc)]
    unk = _setdiff(names, avail)
    if unk:
        raise ValueError("weights: unbekannte Anlage(n) %s; vorhanden: %s." % (
            ", ".join("'%s'" % u for u in unk), ", ".join(a for a in avail if a != "date")))
    _opt_check_x(x, names, fn)
    rr = _opt_returns(x, names, frequency)
    R = rr["R"]
    cn = [str(c) for c in R.columns]
    wmap = {}
    for k, v in zip(names, vals):
        wmap.setdefault(k, float(v))
    w = np.array([wmap[c] for c in cn], dtype=np.float64)
    A = R.to_numpy(dtype=np.float64)
    sc = {}
    if measure == "volatility":
        S = _opt_cov_once(A, cov, rr["ppy"], sc)               # seit 1.6.4 (B-072) auch für das Verhältnis unten
        tot = math.sqrt(_quad(w, S))
        if not abs(tot) > 0:
            chk_stop("e4.risiko0", fn)                            # Entscheidung 73 (B-039)
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
        if not abs(tot) > 0:
            chk_stop("e4.risiko0", fn)                            # Entscheidung 73 (B-039)
    out = pd.DataFrame({"asset": cn, "weight": w, "contribution": rc, "share": rc / tot, "marginal": mc})
    out.attrs["total"] = tot
    out.attrs["measure"] = measure
    out.attrs["effective_n"] = 1 / _sum((rc / tot) * (rc / tot))
    if measure == "volatility":
        Sd = sc["S"] if "S" in sc else _opt_cov_m(A, cov) * rr["ppy"]
        out.attrs["diversification_ratio"] = _sum(w * np.sqrt(np.diag(Sd))) / tot
    return out


# ═══════════════════════════════════════════════════════════════════════════
# portfolio_cpcv
# ═══════════════════════════════════════════════════════════════════════════

class SimLevCPCV(RList):
    """Ergebnis von :func:`portfolio_cpcv` (R-Klasse ``SimLevCPCV``)."""

    r_class = ("SimLevCPCV",)

    def format(self):
        return print_SimLevCPCV(self, _return=True)


def portfolio_cpcv(x, *, assets=None, methods=("equal", "inverse_vol", "min_variance", "risk_parity", "max_sharpe"),
                   n_groups=6, test_groups=2, purge=2, embargo=2, frequency=_FREQS):
    """Kombinatorische Kreuzvalidierung von Optimierungsverfahren (CPCV, Lopez de Prado 2018).

    Teilt die Historie in ``n_groups`` zeitlich zusammenhängende Gruppen und bildet alle Kombinationen von
    ``test_groups`` Testgruppen. Je Aufteilung wird auf den übrigen Gruppen optimiert - mit einer Sperrzone
    (``purge``) von Perioden an den Grenzen zu den Testgruppen und einem ``embargo`` danach, damit sich Trainings-
    und Testdaten nicht über Autokorrelation beeinflussen - und das Ergebnis auf den Testgruppen bewertet. Statt
    eines einzelnen Backtests entsteht so eine Verteilung der Out-of-Sample-Kennzahlen je Verfahren (Lopez de
    Prado 2018, Kap. 12).

    Args:
        x: DataFrame mit Spalte ``date`` (Date) und Kursspalten (Kursniveaus) oder Matrix einfacher
            Periodenrenditen als Anteil (siehe ``portfolio_optimize()``).
        assets: Zeichenvektor der Spalten. ``None`` (Standard) = alle numerischen Spalten außer ``date`` bzw. alle
            Spalten der Matrix.
        methods: Zeichenvektor von Verfahren aus ``portfolio_optimize()`` (Standard ``["equal", "inverse_vol",
            "min_variance", "risk_parity", "max_sharpe"]``) oder benannte Liste von Argumentlisten für
            ``portfolio_optimize()`` (z. B. ``{"mv": {"method": "min_variance", "cov": "ledoit_wolf"}}``).
        n_groups: Anzahl Gruppen insgesamt (ganze Zahl >= 2, Standard 6).
            Seit 1.6.4 höchstens 10^8.
        test_groups: Anzahl Testgruppen je Aufteilung (ganze Zahl, Standard 2, kleiner als ``n_groups``); es gibt
            choose(n_groups, test_groups) Aufteilungen.
        purge, embargo: Sperrzone und Embargo in Perioden der gewählten Frequenz (Zeilen der Renditen, ganze
            Zahlen >= 0, je Standard 2).
            Seit 1.6.4 höchstens 10^8.
        frequency: Siehe ``portfolio_optimize()``.

    Returns:
        Objekt der Klasse ``SimLevCPCV`` mit

        - splits: DataFrame je Verfahren und Aufteilung: ``method``, ``split``, ``return`` (arithmetisches Mittel,
          annualisiert, Anteil p. a.), ``volatility`` (Anteil p. a.), ``sharpe`` (annualisiert, ohne risikolosen
          Zins), ``cdar`` (CDaR bei 5 % der kumulierten, nicht aufgezinsten Testrenditen, Anteil).
        - summary: DataFrame je Verfahren, absteigend nach mittlerer Sharpe Ratio: ``method``, ``mean``, ``sd``,
          ``q10``, ``q50``, ``q90`` (der Sharpe Ratio über die Aufteilungen), ``volatility``, ``cdar`` (Mittel),
          ``best_share`` (Anteil der Aufteilungen, in denen das Verfahren die höchste Sharpe Ratio hat, 0 bis 1).

        sowie ``n_splits``, ``n_groups``, ``test_groups``, ``frequency`` und ``failed`` (DataFrame der
        fehlgeschlagenen Optimierungen mit ``method``, ``split``, ``message`` oder ``None``). Methode ``print``.

    Details:
        Eingabe und Renditeberechnung wie bei ``portfolio_optimize()``; die Gruppen sind etwa gleich lange,
        zusammenhängende Abschnitte der Periodenrenditen. Konkret werden vor jeder Testgruppe ``purge``
        Trainingsperioden entfernt und nach jeder Testgruppe ``max(purge, embargo)`` Perioden (Sperrzone und
        Embargo beginnen beide direkt nach dem Testende; bei 0 entfällt die jeweilige Sperrzone). Trainiert wird
        mit denselben Perioden je Jahr wie die Bewertung (bei Kursdaten aus den Daten geschätzt). Die Testgruppen
        einer Aufteilung werden für die Kennzahlen aneinandergehängt. Unbekannte Verfahren oder Argumente sind
        sofort ein Fehler; Verfahren, deren Optimierung in einer Aufteilung fehlschlägt, fehlen dort (mit Warnung,
        Einzelheiten in ``failed``); schlagen alle fehl, bricht die Funktion mit der ersten Fehlermeldung ab.

    Literatur:
        Lopez de Prado, M. (2018), Advances in Financial Machine Learning, Wiley, Kap. 7 und 12.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        R = pd.DataFrame(rng.normal([0.002, 0.001, 0.0005], [0.03, 0.02, 0.01], (520, 3)), columns=["aktien", "reits", "anleihen"])
        print(simlev.portfolio_cpcv(R, methods=["equal", "inverse_vol", "min_variance"], n_groups=5, test_groups=2))
    """
    frequency = _match_arg(frequency, _FREQS)
    fn = "portfolio_cpcv"                                      # seit 1.6.4 vor der Rechnung (K42 E4)
    assets = _opt_check_x(x, assets, fn)
    from .dependence import _e4_count, _e4_names
    # seit 1.6.4 Bausteine der Tabelle eingabe (ohne Wert); Obergrenze wie Entscheidung 16
    n_groups = _e4_count(n_groups, fn, "n_groups", lo=2)
    test_groups = _e4_count(test_groups, fn, "test_groups")
    purge = _e4_count(purge, fn, "purge", lo=0)
    embargo = _e4_count(embargo, fn, "embargo", lo=0)
    n_groups_v, test_groups_v = n_groups, test_groups
    ng = int(n_groups)
    tg = int(test_groups)
    purge = int(purge)
    embargo = int(embargo)
    if tg >= ng:
        raise ValueError("portfolio_cpcv: test_groups muss kleiner als n_groups sein, sonst bleibt keine Trainingsgruppe.")
    if isinstance(methods, (str, list, tuple, np.ndarray, pd.Series)) and \
            all(isinstance(m, str) for m in ([methods] if isinstance(methods, str) else list(methods))):
        methods = _e4_names(methods, fn, "methods", no_date=False)   # B-052
    rr = _opt_returns(x, assets, frequency)
    R = rr["R"]
    Tn = len(R)
    if isinstance(methods, str):
        methods = [methods]
    if isinstance(methods, (list, tuple, np.ndarray)) and all(isinstance(m, str) for m in methods) and len(methods):
        specs = {str(m): {"method": str(m)} for m in methods}
    elif isinstance(methods, Mapping) and len(methods) and all(str(k) != "" for k in methods.keys()):
        specs = {str(k): v for k, v in methods.items()}
    else:
        raise ValueError("portfolio_cpcv: methods muss ein Zeichenvektor oder eine benannte Liste von Argumentlisten sein.")
    allowed_args = [a for a in _PO_FORMALS if a not in ("x", "assets", "frequency")]
    for nm, sp in specs.items():
        if not isinstance(sp, Mapping) or any(str(k) == "" for k in sp.keys()):
            raise ValueError("portfolio_cpcv: Eintrag '%s' von methods muss eine benannte Argumentliste sein." % nm)
        if sp.get("method") is not None and not isinstance(chk_scalar(sp["method"]), str):
            chk_stop("text", fn, "methods$%s$method" % nm)       # seit 1.6.4
        if sp.get("method") is not None and sp["method"] not in _METHODS:
            raise ValueError("portfolio_cpcv: unbekanntes Verfahren '%s'; erlaubt: %s." % (sp["method"], ", ".join(_METHODS)))
        bad = [k for k in sp.keys() if k not in allowed_args]
        if bad:
            raise ValueError("portfolio_cpcv: unbekannte Argumente für portfolio_optimize() in '%s': %s."
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
        raise ValueError("portfolio_cpcv: keine Optimierung erfolgreich (z. B. '%s' in Aufteilung %d: %s)."
                         % (fl["method"].iloc[0], int(fl["split"].iloc[0]), fl["message"].iloc[0]))
    if fl is not None:
        _warn("portfolio_cpcv: %d von %d Optimierungen fehlgeschlagen (z. B. '%s' in Aufteilung %d: %s); sie fehlen in der "
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
        best.append(z["method"].iloc[_which_max(z["sharpe"].to_numpy(dtype=np.float64), 0)])
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

quiet_fp(globals(), list(__all__) + ["_cdar_hist", "_col_means", "_cov", "_cvar_hist", "_hrp", "_mat_vec", "_opt_cov", "_qp_simplex", "_risk_parity", "_opt_summary", "_portfolio_optimize"])
