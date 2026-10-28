"""Schutz vor Überanpassung bei Parametersuchen (R: ``overfitting.R``).

- :func:`pbo`                   Probability of Backtest Overfitting mit
                                Combinatorially Symmetric Cross-Validation
                                (Bailey, Borwein, López de Prado & Zhu 2017)
- :func:`deflated_sharpe`       Deflated Sharpe Ratio (Bailey & López de Prado
                                2014) inkl. effektiver Versuchsanzahl
- :func:`probabilistic_sharpe`  Probabilistic Sharpe Ratio (Bailey & López de
                                Prado 2012)
- :func:`walk_forward`          rollierende Auswahl In-Sample, Bewertung
                                Out-of-Sample
- :func:`param_bootstrap`       beste Punkte einer Suche auf Bootstrap-Pfaden
- :func:`sharpe_haircut`        Sharpe-Ratio-Abschlag für Mehrfachtests

Alle Verfahren arbeiten auf den täglichen TWR-Renditen, die
:func:`simlev.param_search` je Punkt speichert.
"""
from __future__ import annotations

import importlib
import itertools
import math
import warnings

import numpy as np
import pandas as pd

from ._r import libm as _libm
from ._r import nmath as _nmath
from ._r import fmt as _fmt
from ._r.rlist import RList
from ._r.rnum import LD, r_mean, r_mean_int, r_median, r_pow, r_prod, r_cumprod, r_sum, r_var, r_sd

__all__ = ["pbo", "probabilistic_sharpe", "deflated_sharpe", "walk_forward", "param_bootstrap",
           "sharpe_haircut", "SimLevPBO", "SimLevDSR", "SimLevWalkForward"]

_NAN = float("nan")      # R's NaN
_NA = _fmt.NA_REAL       # R's NA_real_
_EPOCH = np.datetime64("1970-01-01", "D")


# ─────────────────────────────────────────────────────────────────────────────
# Fremdfunktionen (andere Bearbeiter) und R-Interna
# ─────────────────────────────────────────────────────────────────────────────

def _ext(mod, name):
    """Funktion ``name`` aus ``simlev.<mod>`` (spät geladen, parallel portiert)."""
    m = importlib.import_module("simlev." + mod)
    return getattr(m, name)


def _match_arg(value, choices, argname="arg"):
    from .config import _match_arg as ma
    return ma(value, choices, argname)


def _as_dates(x):
    """Datumswerte (bereits von ``_to_date`` geprüft) → ``datetime64[D]``-Array."""
    if x is None:
        return None
    a = np.asarray(x)
    if np.issubdtype(a.dtype, np.datetime64):
        return a.astype("datetime64[D]").ravel()
    return pd.to_datetime(pd.Series(np.asarray(x).ravel())).to_numpy().astype("datetime64[D]")


def _to_date(x, what):
    return _as_dates(_ext("data_prep", "_to_date")(x, what))


def _days(d):
    """Datum → Tage seit 1970 (float64)."""
    return (d.astype("datetime64[D]") - _EPOCH).astype(np.int64).astype(np.float64)


def _colsums(M):
    """``colSums`` (long-double-Akkumulator, sequenziell)."""
    n, p = M.shape
    if n == 0:
        return np.zeros(p)
    return np.cumsum(M.astype(LD), axis=0)[-1].astype(np.float64)


def _colmeans(M):
    """``colMeans``: long-double-Summe / n, dann double."""
    n, p = M.shape
    if n == 0:
        return np.full(p, _NAN)
    return (np.cumsum(M.astype(LD), axis=0)[-1] / LD(n)).astype(np.float64)


def _rowsums(M):
    n, p = M.shape
    acc = np.zeros(n, dtype=LD)
    for j in range(p):
        acc = acc + M[:, j].astype(LD)
    return acc.astype(np.float64)


def _rowmeans(M):
    n, p = M.shape
    acc = np.zeros(n, dtype=LD)
    for j in range(p):
        acc = acc + M[:, j].astype(LD)
    return (acc / LD(p)).astype(np.float64)


def _rowsum(M, codes, ng):
    """``rowsum(x, g, reorder = FALSE)``: double-Akkumulation in Zeilenreihenfolge."""
    out = np.zeros((ng, M.shape[1]))
    with np.errstate(invalid="ignore"):     # NA (signalisierendes NaN) wie in R ohne Warnung
        for i in range(M.shape[0]):
            out[codes[i]] = out[codes[i]] + M[i]
    return out


def _matprod(A, B):
    """``A %*% B`` wie R (``simlev._r.linalg.matprod``)."""
    from ._r.linalg import matprod
    return np.asarray(matprod(A, B), dtype=np.float64)


def _which_max(v):
    """``which.max``: erster Index (0-basiert) des Maximums ohne NA; ``None`` wenn leer."""
    v = np.asarray(v, dtype=np.float64)
    ok = ~np.isnan(v)
    if not ok.any():
        return None
    best = None
    for i in range(v.size):
        if ok[i] and (best is None or v[i] > v[best]):
            best = i
    return best


def _max_col_first(M):
    """``max.col(M, ties.method = "first")`` (0-basiert; -1 = NA)."""
    out = np.empty(M.shape[0], dtype=np.int64)
    for r in range(M.shape[0]):
        row = M[r]
        if np.isnan(row).any():
            out[r] = -1
            continue
        out[r] = int(np.argmax(row))      # erstes Maximum, exakte Vergleiche wie maxcol.c
    return out


def _rank_avg(x):
    """``rank(x)`` mit ``ties.method = "average"``."""
    from ._r.stats import rank
    return np.asarray(rank(np.asarray(x, dtype=np.float64)), dtype=np.float64)


def _stats(name):
    st = importlib.import_module("simlev._r.stats")
    return getattr(st, name)


def _lm_coef(x, y):
    """Koeffizienten (Achsenabschnitt, Steigung) von ``lm(y ~ x)``."""
    f = _stats("lm_fit")
    x = np.asarray(x, float)
    y = np.asarray(y, float)
    ok = ~(np.isnan(x) | np.isnan(y))                 # na.action = na.omit
    X = np.column_stack([np.ones(int(ok.sum())), x[ok]])
    fit = f(X, y[ok])
    cf = fit["coefficients"] if isinstance(fit, dict) or hasattr(fit, "keys") else fit
    cf = np.asarray(cf, dtype=np.float64).ravel()
    return float(cf[0]), float(cf[1])


def _cor(M):
    return np.asarray(_stats("cor")(M), dtype=np.float64)


def _p_adjust(p, method, n):
    return np.asarray(_stats("p_adjust")(p, method=method, n=n), dtype=np.float64)


def _sprintf(f, *a):
    return _fmt.sprintf(f, *a)


def _cat(s):
    print(s, end="")


# ─────────────────────────────────────────────────────────────────────────────
# Renditematrix
# ─────────────────────────────────────────────────────────────────────────────

def _is_param_search(x):
    try:
        from .param_search import SimLevParamSearch
    except ImportError:          # pragma: no cover
        return False
    return isinstance(x, SimLevParamSearch)


def _as_return_matrix(x):
    """``as.matrix(x)`` einer numerischen Eingabe → (Matrix, Spaltennamen oder None, Zeilennamen)."""
    rn = None
    if isinstance(x, pd.DataFrame):
        ok = all(pd.api.types.is_numeric_dtype(x[c]) and not pd.api.types.is_bool_dtype(x[c]) for c in x.columns)
        if not ok:
            raise ValueError("x muss ein SimLevParamSearch oder eine numerische Renditematrix sein.")
        cn = None if isinstance(x.columns, pd.RangeIndex) else [str(c) for c in x.columns]
        if not isinstance(x.index, pd.RangeIndex):
            rn = [str(i) for i in x.index]
        return x.to_numpy(dtype=np.float64, na_value=_NA), cn, rn
    if isinstance(x, pd.Series):
        a = x.to_numpy()
        if a.dtype.kind not in "iuf":
            raise ValueError("x muss ein SimLevParamSearch oder eine numerische Renditematrix sein.")
        rn = None if isinstance(x.index, pd.RangeIndex) else [str(i) for i in x.index]
        return a.astype(np.float64).reshape(-1, 1), None, rn
    a = np.asarray(x)
    if a.dtype.kind not in "iuf":
        raise ValueError("x muss ein SimLevParamSearch oder eine numerische Renditematrix sein.")
    a = a.astype(np.float64)
    if a.ndim == 1:
        a = a.reshape(-1, 1)
    return a, None, None


def _returns_frame(R, cols, rn=None):
    df = pd.DataFrame(R, columns=list(cols))
    if rn is not None:
        df.index = list(rn)
    return df


def _of_returns_np(x, frequency, dates=None, risk_free=0):
    """Wie ``.of_returns``; liefert ``(R, Spaltennamen, Zeilennamen, dates, ppy, cols)`` mit numpy."""
    if _is_param_search(x):
        if x.get("returns") is None:
            raise ValueError("Suche ohne gespeicherte Renditen (keep_returns = FALSE).")
        ret = x["returns"]
        if isinstance(ret, pd.DataFrame):
            R = ret.to_numpy(dtype=np.float64, na_value=_NA)
            cn = [str(c) for c in ret.columns]
        else:
            R = np.asarray(ret, dtype=np.float64)
            if R.ndim == 1:
                R = R.reshape(-1, 1)
            cn = ["p%d" % (j + 1) for j in range(R.shape[1])]
        rn = None
        dates = x.get("dates")
    else:
        R, cn, rn = _as_return_matrix(x)
        if cn is None:
            cn = ["p%d" % (j + 1) for j in range(R.shape[1])]
    keep = np.isfinite(R).sum(axis=0) > 0
    R = R[:, keep]
    cn = [c for c, k in zip(cn, keep) if k]
    if dates is not None:
        dates = _to_date(dates, "dates")
    if dates is not None and frequency != "day":
        key = _fmt.format_date(dates, "%G-%V" if frequency == "week" else "%Y-%m")
        key = [str(k) for k in key]
        if len(key) != R.shape[0]:
            raise ValueError("incorrect length for 'group'")
        lev = list(dict.fromkeys(key))
        pos = {k: i for i, k in enumerate(lev)}
        codes = np.array([pos[k] for k in key], dtype=np.int64)
        S = _rowsum(_libm.log1p(R), codes, len(lev))
        R = _libm.exp(S) - 1.0
        rn = lev
        last = np.array([key[i] != key[i + 1] for i in range(len(key) - 1)] + [True], dtype=bool)
        dates = dates[last]
    ok = ~np.isnan(R).any(axis=1)
    R = R[ok]
    if rn is not None:
        rn = [r for r, k in zip(rn, ok) if k]
    if dates is not None:
        dates = dates[ok]
    if dates is not None and len(dates) > 1:
        span = float(_days(dates[-1:])[0] - _days(dates[:1])[0])
        ppy = (len(dates) - 1) / (span / 365.25)
    else:
        ppy = {"day": 252.0, "week": 52.0, "month": 12.0}[frequency]
    R = R - risk_free / 100 / ppy
    cols = np.nonzero(keep)[0].astype(np.int64) + 1
    return R, cn, rn, dates, ppy, cols


def _of_returns(x, frequency, dates=None, risk_free=0):
    """Renditematrix und Datum aus Suche oder Matrix holen, ggf. aggregieren (``.of_returns``).

    Liefert ein dict mit ``R`` (``pandas.DataFrame``, Spalten = Punkte, bei
    Aggregation Zeilennamen = Wochen-/Monatsschlüssel), ``dates``
    (``datetime64[D]``-Array oder ``None``), ``ppy`` (Perioden je Jahr) und
    ``cols`` (1-basierte Spaltennummern der ursprünglichen Matrix, int64).
    """
    R, cn, rn, dates, ppy, cols = _of_returns_np(x, frequency, dates, risk_free)
    return {"R": _returns_frame(R, cn, rn), "dates": dates, "ppy": ppy, "cols": cols}


class _RR:
    """Interne Renditequelle (numpy) wie die Liste ``rr`` in R."""

    def __init__(self, R, cn, rn, dates, ppy, cols):
        self.R, self.cn, self.rn, self.dates, self.ppy, self.cols = R, list(cn), rn, dates, ppy, cols


def _rr(x, frequency, dates=None, risk_free=0):
    return _RR(*_of_returns_np(x, frequency, dates, risk_free))


def _of_metric(n, s1, s2, sdn, sl, metric, c1=None):
    """Kennzahl aus Summen-Statistiken (spaltenweise, auch Matrizen); Argumente
    ``s2``, ``sdn``, ``sl``, ``c1`` dürfen Funktionen sein (verzögerte Auswertung wie in R)."""
    def ev(v):
        return v() if callable(v) else v
    s1 = ev(s1)
    m = s1 / n
    if metric == "sharpe":
        c1 = s1 if c1 is None else ev(c1)
        return m / np.sqrt(np.maximum((ev(s2) - c1 * c1 / n) / (n - 1), 1e-300))
    if metric == "sortino":
        return m / np.sqrt(np.maximum(ev(sdn) / n, 1e-300))
    if metric == "geometric":
        return _libm.expm1(ev(sl) / n)
    if metric == "mean":
        return m
    raise ValueError("metric: 'sharpe', 'sortino', 'geometric' oder 'mean'.")


def _of_col_metric(R, metric):
    """Kennzahl je Spalte einer Renditematrix (``.of_col_metric``)."""
    if isinstance(R, pd.DataFrame):
        names = [str(c) for c in R.columns]
        out = _of_col_metric(R.to_numpy(dtype=np.float64), metric)
        return pd.Series(out, index=names)
    R = np.asarray(R, dtype=np.float64)
    if R.ndim == 1:
        R = R.reshape(-1, 1)
    Rc = R - _colmeans(R)[None, :]
    return np.asarray(_of_metric(R.shape[0], _colsums(R), lambda: _colsums(Rc * Rc),
                                 lambda: (lambda P: _colsums(P * P))(np.minimum(R, 0.0)),
                                 lambda: _colsums(_libm.log1p(R)), metric, c1=lambda: _colsums(Rc)),
                      dtype=np.float64)


def _of_drop_flat(rr, what):
    """Spalten ohne Schwankung (Sharpe Ratio nicht definiert) ausschließen."""
    R = rr.R
    sdv = np.array([r_sd(R[:, j]) for j in range(R.shape[1])])
    flat = np.nonzero(~(sdv > 1e-10))[0]
    if not flat.size:
        return rr
    if flat.size == R.shape[1]:
        raise ValueError("%s: alle Spalten ohne Schwankung (Standardabweichung <= 1e-10); Sharpe Ratio nicht definiert." % what)
    warnings.warn("%s: %d Spalte(n) ohne Schwankung (Standardabweichung <= 1e-10 je Periode, z. B. Geldmarkt mit festem Zins; "
                  "Punkt(e) %s) ausgeschlossen - Sharpe Ratio dort nicht definiert."
                  % (what, flat.size, ", ".join(str(int(rr.cols[j])) for j in flat)), UserWarning, stacklevel=3)
    keep = np.ones(R.shape[1], dtype=bool)
    keep[flat] = False
    rr.R = R[:, keep]
    rr.cn = [c for c, k in zip(rr.cn, keep) if k]
    rr.cols = rr.cols[keep]
    return rr


# ─────────────────────────────────────────────────────────────────────────────
# PBO
# ─────────────────────────────────────────────────────────────────────────────

class SimLevPBO(RList):
    """Ergebnis von :func:`pbo` (R-Klasse ``SimLevPBO``)."""

    r_class = ("SimLevPBO",)

    def format(self):
        x = self
        out = ["Probability of Backtest Overfitting (PBO, CSCV)\n"]
        out.append(_sprintf("  %d Punkte, %d Beobachtungen (%s), S = %d Blöcke, %d Aufteilungen, Kennzahl %s\n",
                            x["n_points"], x["n_obs"], x["frequency"], x["S"], x["n_combos"], x["metric"]))
        out.append(_sprintf("  PBO:                              %.1f %%\n", 100 * x["pbo"]))
        out.append(_sprintf("  Median-Logit lambda:              %.2f\n", r_median(x["lambda"])))
        out.append(_sprintf("  Leistungsabfall (Steigung OOS~IS): %.2f\n", x["slope"]))
        out.append(_sprintf("  OOS-Verlustwahrscheinlichkeit:    %.1f %%\n", 100 * x["prob_loss"]))
        ob = np.asarray(x["oos_best"], float)
        om = np.asarray(x["oos_median"], float)
        out.append(_sprintf("  Gewählter Punkt OOS vor Median:   %.1f %%\n", 100 * _mean_lgl(ob > om, np.isnan(ob) | np.isnan(om))))
        N = int(x["n_points"])
        out.append(_sprintf("  Lesart: PBO nahe 0 = Auswahl trägt, um %.0f %% = Zufall%s, darüber = Auswahl schadet.\n",
                            100 * (N + N % 2) / (2 * N), " (ungerade Punktezahl: (N + 1) / (2N))" if N % 2 else ""))
        return "".join(out)[:-1]

    def print(self):
        print(self.format())
        return self

    def plot(self, **kwargs):
        return _plot_pbo(self, **kwargs)


def _mean_lgl(v, na=None):
    """``mean()`` eines logischen Vektors (NA, falls ``na`` irgendwo wahr)."""
    v = np.asarray(v, dtype=bool)
    if na is not None and np.asarray(na).any():
        return _NA
    if v.size == 0:
        return _NAN
    return r_mean_int(v.astype(np.int64))


def pbo(x, S=16, metric=("sharpe", "sortino", "geometric", "mean"),
        frequency=("week", "day", "month"), dates=None, risk_free=0):
    """Probability of Backtest Overfitting (CSCV).

    Teilt die Renditehistorie aller Punkte einer Parametersuche in ``S`` gleich
    lange Blöcke und bildet alle ``choose(S, S/2)`` Aufteilungen in In-Sample-
    und Out-of-Sample-Hälften. Je Aufteilung wird der In-Sample-beste Punkt
    bestimmt und sein Rang Out-of-Sample gemessen (Logit lambda). Die PBO ist der
    Anteil der Aufteilungen mit lambda <= 0.

    Args:
        x: ``SimLevParamSearch`` mit gespeicherten Renditen oder numerische
            Renditematrix (Zeilen = Perioden, Spalten = Punkte).
        S: Anzahl Blöcke (gerade ganze Zahl >= 2, Standard 16).
        metric: ``"sharpe"`` (Standard), ``"sortino"``, ``"geometric"`` oder ``"mean"``.
        frequency: ``"week"`` (Standard), ``"day"`` oder ``"month"``.
        dates: Datum je Zeile (nur Matrix-Eingabe).
        risk_free: risikoloser Zins in Prozent p. a.

    Returns:
        :class:`SimLevPBO`.
    """
    metric = _match_arg(metric, ("sharpe", "sortino", "geometric", "mean"), "metric")
    frequency = _match_arg(frequency, ("week", "day", "month"), "frequency")
    S = int(S)
    if S < 2 or S % 2:
        raise ValueError("S muss gerade und >= 2 sein.")
    rr = _rr(x, frequency, dates, risk_free)
    if metric == "sharpe":
        rr = _of_drop_flat(rr, "pbo")
    R = rr.R
    N = R.shape[1]
    Tn = R.shape[0]
    if N < 2:
        raise ValueError("Mindestens zwei Punkte nötig.")
    bl = Tn // S
    if bl < 4:
        raise ValueError("Zu wenige Beobachtungen (%d) für S = %d Blöcke." % (Tn, S))
    R = R[Tn - bl * S:Tn]
    blk = np.repeat(np.arange(S), bl)
    Rc = R - _colmeans(R)[None, :]
    B1 = _rowsum(R, blk, S)
    B2 = _rowsum(Rc * Rc, blk, S)
    Pm = np.minimum(R, 0.0)
    Bd = _rowsum(Pm * Pm, blk, S)
    Bl = _rowsum(_libm.log1p(R), blk, S)
    Bc = _rowsum(Rc, blk, S)
    T1, T2, Td, Tl, Tc = (_colsums(B) for B in (B1, B2, Bd, Bl, Bc))
    combos = np.array(list(itertools.combinations(range(S), S // 2)), dtype=np.int64)   # C x S/2
    C = combos.shape[0]
    half = bl * S / 2
    lam = np.zeros(C)
    isb = np.zeros(C)
    oosb = np.zeros(C)
    oosm = np.zeros(C)
    for st in range(0, C, 2000):
        idx = np.arange(st, min(C, st + 2000))
        k = idx.size
        Ind = np.zeros((k, S))
        Ind[np.repeat(np.arange(k), S // 2), combos[idx].ravel()] = 1.0
        I1, I2, Id, Il, Ic = (_matprod(Ind, B) for B in (B1, B2, Bd, Bl, Bc))

        def rep_t(v):
            return np.tile(np.asarray(v, float)[None, :], (k, 1))
        IS = _of_metric(half, I1, I2, Id, Il, metric, c1=Ic)
        OOS = _of_metric(half, rep_t(T1) - I1, rep_t(T2) - I2, rep_t(Td) - Id, rep_t(Tl) - Il, metric,
                         c1=rep_t(Tc) - Ic)
        best = _max_col_first(IS)
        rows = np.arange(k)
        bb = np.where(best < 0, 0, best)
        ob = np.where(best < 0, _NA, OOS[rows, bb])
        with np.errstate(invalid="ignore"):
            lt = (OOS < ob[:, None]).astype(np.float64)
            eq = (OOS == ob[:, None]).astype(np.float64)
        na = np.isnan(OOS).any(axis=1) | np.isnan(ob)
        rk = _rowsums(lt) + (_rowsums(eq) + 1) / 2
        rk[na] = _NA
        w = rk / (N + 1)
        lam[idx] = _libm.log(w / (1 - w))
        isb[idx] = np.where(best < 0, _NA, IS[rows, bb])
        oosb[idx] = ob
        oosm[idx] = [r_median(OOS[i]) for i in range(k)]
    intercept, slope = _lm_coef(isb, oosb)
    return SimLevPBO(pbo=_mean_lgl(lam <= 0, np.isnan(lam)), **{"lambda": lam}, is_best=isb, oos_best=oosb,
                     oos_median=oosm, slope=slope, intercept=intercept,
                     prob_loss=_mean_lgl(oosb < 0, np.isnan(oosb)), S=S, n_combos=C, n_points=N, n_obs=bl * S,
                     metric=metric, frequency=frequency, ppy=rr.ppy)


def _plot_pbo(x, **kwargs):
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(1, 2, figsize=(10, 4))
    lam = np.asarray(x["lambda"], float)
    ax[0].hist(lam[np.isfinite(lam)], bins=40, color="#2C6E9B", edgecolor="white")
    ax[0].axvline(0, color="#B5562B", lw=2)
    ax[0].set_title("Logits (PBO %.0f %%)" % (100 * x["pbo"]))
    ax[0].set_xlabel("λ")
    ax[0].set_ylabel("Häufigkeit")
    ax[1].scatter(x["is_best"], x["oos_best"], s=4, color="#2C6E9B", alpha=0.4)
    xs = np.array([np.nanmin(x["is_best"]), np.nanmax(x["is_best"])])
    ax[1].plot(xs, x["intercept"] + x["slope"] * xs, color="#B5562B", lw=2)
    ax[1].axhline(0, color="grey", ls=":")
    ax[1].set_xlabel("%s In-Sample (bester Punkt)" % x["metric"])
    ax[1].set_ylabel("Out-of-Sample")
    ax[1].set_title("Leistungsabfall")
    return x


# ─────────────────────────────────────────────────────────────────────────────
# PSR / DSR
# ─────────────────────────────────────────────────────────────────────────────

def probabilistic_sharpe(r, benchmark=0, ppy=52):
    """Probabilistic Sharpe Ratio.

    Wahrscheinlichkeit, dass die wahre Sharpe Ratio über ``benchmark`` liegt,
    unter Berücksichtigung von Stichprobenlänge, Schiefe und Wölbung.

    Args:
        r: numerischer Vektor einfacher Periodenrenditen (Anteil); nicht
            endliche Werte werden entfernt.
        benchmark: Vergleichs-Sharpe-Ratio p. a. (Standard 0).
        ppy: Perioden je Jahr (Standard 52).

    Returns:
        float: Wahrscheinlichkeit (0 bis 1).
    """
    r = np.asarray(r, dtype=np.float64).ravel()
    r = r[np.isfinite(r)]
    n = r.size
    mu = r_mean(r)
    sd = r_sd(r)
    sr = mu / sd
    sr0 = benchmark / math.sqrt(ppy)
    z = (r - r_mean(r)) / r_sd(r)
    g3 = r_mean(np.array([r_pow(v, 3.0) for v in z]))
    g4 = r_mean(np.array([r_pow(v, 4.0) for v in z]))
    den = 1 - g3 * sr + (g4 - 1) / 4 * (sr * sr)
    den = den if (math.isnan(den) or den >= 1e-12) else 1e-12
    q = (sr - sr0) * math.sqrt(n - 1) / math.sqrt(den)
    return float(_nmath.pnorm(q))


class SimLevDSR(RList):
    """Ergebnis von :func:`deflated_sharpe` (R-Klasse ``SimLevDSR``)."""

    r_class = ("SimLevDSR",)

    def format(self):
        x = self
        out = ["Deflated Sharpe Ratio\n"]
        out.append(_sprintf("  Punkt #%d, %d Beobachtungen (%s)\n", x["id"], x["n_obs"], x["frequency"]))
        out.append(_sprintf("  Sharpe Ratio (p. a.):                 %.3f\n", x["sharpe"]))
        out.append(_sprintf("  Versuche: %d nominal, %.1f effektiv (mittlere Korrelation %.2f), verwendet %.1f\n",
                            x["n_points"], x["n_eff"], x["rho"], float(x["n_trials"])))
        out.append(_sprintf("  Erwartetes Maximum ohne Können (p. a.):  %.3f\n", x["sr0"]))
        out.append(_sprintf("  PSR (SR > 0):                         %.1f %%\n", 100 * x["psr"]))
        out.append(_sprintf("  DSR (SR > erwartetes Maximum):        %.1f %%\n", 100 * x["dsr"]))
        out.append("  Lesart: DSR über 95 % = Ergebnis hält der Mehrfachtest-Korrektur stand.\n")
        return "".join(out)[:-1]

    def print(self):
        print(self.format())
        return self


def deflated_sharpe(x, id=None, n_trials=None, effective=True,  # noqa: A002 - R-Argumentname
                    frequency=("week", "day", "month"), dates=None, risk_free=0):
    """Deflated Sharpe Ratio.

    Korrigiert die Sharpe Ratio des besten Punkts einer Suche um die Zahl der
    Versuche (erwartetes Maximum aus ``N`` wertlosen Versuchen, effektive
    Versuchsanzahl aus der mittleren paarweisen Korrelation).

    Args:
        x: ``SimLevParamSearch`` mit Renditen oder numerische Renditematrix.
        id: zu prüfender Punkt (``id`` bzw. Spaltennummer); ``None`` = höchste Sharpe Ratio.
        n_trials: Versuchsanzahl (überschreibt die Schätzung).
        effective: effektive Versuchsanzahl verwenden (Standard ``True``).
        frequency, dates, risk_free: wie bei :func:`pbo`.

    Returns:
        :class:`SimLevDSR`.
    """
    frequency = _match_arg(frequency, ("week", "day", "month"), "frequency")
    rr = _of_drop_flat(_rr(x, frequency, dates, risk_free), "deflated_sharpe")
    R = rr.R
    N = R.shape[1]
    sr = _of_col_metric(R, "sharpe")
    if id is None:
        j = _which_max(sr)
    else:
        hits = np.nonzero(rr.cols == float(id))[0]
        if not hits.size:
            raise ValueError("id nicht unter den gültigen Punkten (Spalten ohne endliche Werte oder ohne Schwankung zählen nicht).")
        j = int(hits[0])
    if N > 1:
        Cm = _cor(R)
        iu = [Cm[i, jj] for jj in range(N) for i in range(jj)]
        rho = r_mean(np.array(iu, dtype=np.float64), na_rm=True)
    else:
        rho = 1.0
    n_eff = max(1.0, rho + (1 - max(rho, 0.0)) * N)
    if math.isnan(rho):
        raise ValueError("missing value where TRUE/FALSE needed")  # R: if (rho < 0) mit NaN
    if rho < 0:
        n_eff = N
    Nt = n_trials if n_trials is not None else (n_eff if effective else N)
    v = r_var(sr) if N > 1 else 0.0
    g = 0.5772156649
    if Nt > 1 and v > 0:
        sr0 = math.sqrt(v) * ((1 - g) * _nmath.qnorm(1 - 1 / Nt) + g * _nmath.qnorm(1 - 1 / (Nt * _libm.exp(1.0))))
    else:
        sr0 = 0.0
    r = R[:, j]
    sq = math.sqrt(rr.ppy)
    return SimLevDSR(id=int(rr.cols[j]), sharpe=float(sr[j]) * sq, sr0=sr0 * sq,
                     psr=probabilistic_sharpe(r, 0, rr.ppy), dsr=probabilistic_sharpe(r, sr0 * sq, rr.ppy),
                     n_trials=Nt, n_points=N, n_eff=n_eff, rho=rho, var_sr=v * rr.ppy, n_obs=R.shape[0],
                     frequency=frequency)


# ─────────────────────────────────────────────────────────────────────────────
# Walk-Forward
# ─────────────────────────────────────────────────────────────────────────────

class SimLevWalkForward(RList):
    """Ergebnis von :func:`walk_forward` (R-Klasse ``SimLevWalkForward``)."""

    r_class = ("SimLevWalkForward",)

    def format(self):
        x = self
        out = [_sprintf("Walk-Forward (%s, Training %g J., Test %g J., Auswahl %s nach %s)\n",
                        "verankert" if x["anchored"] else "rollierend", x["train"], x["test"], x["select"], x["metric"])]
        W = x["windows"]
        ts = np.asarray(W["test_start"]).astype("datetime64[D]")
        te = np.asarray(W["test_end"]).astype("datetime64[D]")
        test = ["%s bis %s" % (a, b) for a, b in zip(_fmt.format_date(ts, "%Y-%m"), _fmt.format_date(te, "%Y-%m"))]
        cols = {"Test": np.array(test, dtype=object), "Punkt": np.asarray(W["id"])}
        for p in x["params"]:
            cols[p] = W[p].to_numpy()
        cols["IS"] = _fmt_vec("%.3f", W["is_metric"])
        cols["OOS"] = _fmt_vec("%.3f", W["oos_metric"])
        cols["OOS-Rang"] = _fmt_vec("%.0f %%", 100 * W["oos_rank"].to_numpy(dtype=float))
        cols["Rendite"] = _fmt_vec("%.1f %%", 100 * W["oos_return"].to_numpy(dtype=float))
        cols["Mittel"] = _fmt_vec("%.1f %%", 100 * W["oos_average"].to_numpy(dtype=float))
        y = pd.DataFrame(cols)
        out.append(_fmt.print_data_frame(y, row_names=False) + "\n")
        s = x["summary"]
        out.append(_sprintf("\nCAGR Walk-Forward %.2f %%, Rückschau-Bester (#%d) %.2f %%, Durchschnitt aller Punkte %.2f %%\n",
                            100 * s["cagr_walk_forward"], x["hindsight_id"], 100 * s["cagr_hindsight"], 100 * s["cagr_average"]))
        out.append(_sprintf("Mittlerer OOS-Rang %.0f %% (50 %% = Zufall), Effizienz OOS/IS %.2f, %d Wechsel\n",
                            100 * s["mean_oos_rank"], s["efficiency"], s["switches"]))
        return "".join(out)[:-1]

    def print(self):
        print(self.format())
        return self

    def plot(self, **kwargs):
        import matplotlib.pyplot as plt
        s = self["series"]
        fig, ax = plt.subplots(figsize=(9, 4.5))
        ax.plot(s["date"], s["walk_forward"], color="#2C6E9B", lw=2, label="Walk-Forward")
        ax.plot(s["date"], s["hindsight"], color="#B5562B", lw=1.3, label="Rückschau-Bester")
        ax.plot(s["date"], s["average"], color="0.45", lw=1.3, label="Durchschnitt")
        ax.set_yscale("log")
        ax.set_ylabel("Wachstum (log)")
        ax.set_title("Walk-Forward Out-of-Sample")
        ax.legend(loc="upper left", frameon=False, fontsize=8)
        return self


def _fmt_vec(f, v):
    out = _fmt.sprintf(f, np.asarray(v, dtype=np.float64))
    if isinstance(out, str):
        out = np.array([out], dtype=object)
    return np.asarray(out, dtype=object)


def _r_round(x):
    from ._r.fmt import r_round
    return float(r_round(x))


def walk_forward(x, train=5, test=1, step=None, anchored=False,
                 metric=("sharpe", "sortino", "geometric", "mean"),
                 select=("best", "plateau"), risk_free=0):
    """Walk-Forward-Auswahl.

    Wählt in rollierenden Trainingsfenstern den besten Punkt einer
    Parametersuche (oder das beste Plateau) und verkettet dessen Renditen im
    jeweils folgenden Testfenster.

    Args:
        x: ``SimLevParamSearch`` mit gespeicherten Renditen.
        train, test, step: Fensterlängen und Vorschub in Jahren (Standard 5, 1,
            ``step = test``); intern ganze Monate.
        anchored: ``True`` = Training beginnt immer am ersten Tag.
        metric: ``"sharpe"`` (Standard), ``"sortino"``, ``"geometric"`` oder ``"mean"``.
        select: ``"best"`` (Standard) oder ``"plateau"``.
        risk_free: risikoloser Zins in Prozent p. a.

    Returns:
        :class:`SimLevWalkForward`.
    """
    if step is None:
        step = test
    metric = _match_arg(metric, ("sharpe", "sortino", "geometric", "mean"), "metric")
    select = _match_arg(select, ("best", "plateau"), "select")
    if not _is_param_search(x) or x.get("returns") is None:
        raise ValueError("x muss ein SimLevParamSearch mit Renditen sein.")
    rr = _rr(x, "day", risk_free=risk_free)
    R = rr.R
    d = rr.dates
    dn = _days(d)
    if select == "plateau":
        from .param_search import _ps_neighbours
        nb = _ps_neighbours(x)
    add_months = _ext("data_prep", "_add_months")

    def add_m(date, months):
        out = _as_dates(add_months(np.array([date], dtype="datetime64[D]"), _r_round(months)))
        return out[0]
    t0 = d[0]
    last = d[-1]
    win = []
    k = 0
    n_res = len(x["results"])
    while True:
        ts = add_m(t0, 12 * (train + k * step))
        if ts >= last:
            break
        tr = t0 if anchored else add_m(t0, 12 * k * step)
        te = add_m(t0, 12 * (train + k * step + test))
        is_rows = np.nonzero((d >= tr) & (d < ts))[0]
        oos_rows = np.nonzero((d >= ts) & (d < te))[0]
        if is_rows.size < 20 or oos_rows.size < 5:
            break
        m_is = _of_col_metric(R[is_rows], metric)
        score = m_is
        if select == "plateau":
            full = np.full(n_res, _NA)
            full[rr.cols - 1] = m_is
            score = np.array([r_mean(full[np.asarray(nb[int(cid) - 1]) - 1], na_rm=True) for cid in rr.cols])
        j = _which_max(score)
        m_oos = _of_col_metric(R[oos_rows], metric)
        Ro = R[oos_rows]
        win.append({"train_start": d[is_rows[0]], "test_start": d[oos_rows[0]], "test_end": d[oos_rows[-1]],
                    "id": int(rr.cols[j]), "is_metric": float(m_is[j]), "oos_metric": float(m_oos[j]),
                    "oos_rank": (_rank_avg(m_oos)[j] - 0.5) / m_oos.size,
                    "oos_return": r_prod(1 + Ro[:, j]) - 1,
                    "oos_average": r_mean(np.array([r_prod(1 + Ro[:, c]) for c in range(Ro.shape[1])]) - 1)})
        k += 1
    if not win:
        raise ValueError("Historie zu kurz für ein Trainings- und Testfenster.")
    params = list(x["params"])
    res = x["results"]
    ids = np.array([w["id"] for w in win], dtype=np.int64)
    Wd = {"train_start": np.array([w["train_start"] for w in win], dtype="datetime64[D]"),
          "test_start": np.array([w["test_start"] for w in win], dtype="datetime64[D]"),
          "test_end": np.array([w["test_end"] for w in win], dtype="datetime64[D]"),
          "id": ids}
    for p in params:
        Wd[p] = res[p].to_numpy()[ids - 1]
    for nm in ("is_metric", "oos_metric", "oos_rank", "oos_return", "oos_average"):
        Wd[nm] = np.array([w[nm] for w in win], dtype=np.float64)
    W = pd.DataFrame(Wd)
    nW = len(W)
    seg = []
    for i in range(nW):
        r = np.nonzero((d >= Wd["test_start"][i]) & (d <= Wd["test_end"][i]))[0]
        if i < nW - 1:
            r = r[d[r] < Wd["test_start"][i + 1]]
        seg.append(r)
    rows = np.concatenate(seg).astype(np.int64)
    colpos = {int(c): i for i, c in enumerate(rr.cols)}
    chosen = np.repeat(np.array([colpos[int(i)] for i in ids], dtype=np.int64), [len(s) for s in seg])
    wf = R[rows, chosen]
    span = R[rows]
    hind = _which_max(np.array([r_prod(1 + span[:, c]) for c in range(span.shape[1])]))
    gaps = dn[rows[1:]] - dn[rows[1:] - 1]
    yrs = r_sum(gaps) / 365.25

    def ann(r):
        return r_pow(r_prod(1 + r), 1 / yrs) - 1
    avg = _rowmeans(span)
    series = pd.DataFrame({"date": d[rows], "walk_forward": r_cumprod(1 + wf), "hindsight": r_cumprod(1 + span[:, hind]),
                           "average": r_cumprod(1 + avg)})
    smry = pd.Series({"cagr_walk_forward": ann(wf), "cagr_hindsight": ann(span[:, hind]), "cagr_average": ann(avg),
                      "mean_oos_rank": r_mean(Wd["oos_rank"]),
                      "efficiency": r_mean(Wd["oos_metric"]) / r_mean(Wd["is_metric"]),
                      "switches": float(np.sum(ids[1:] != ids[:-1]))}, dtype=np.float64)
    return SimLevWalkForward(windows=W, series=series, summary=smry, hindsight_id=int(rr.cols[hind]), metric=metric,
                             select=select, train=train, test=test, anchored=anchored, params=params)


# ─────────────────────────────────────────────────────────────────────────────
# Bootstrap der besten Punkte
# ─────────────────────────────────────────────────────────────────────────────

def param_bootstrap(x, data, config, ids=None, top=5, by=("objective", "plateau"), map=None,  # noqa: A002
                    include=None, **kwargs):
    """Beste Punkte einer Parametersuche auf Bootstrap-Pfaden prüfen.

    Baut für die ``top`` besten Punkte (nach Zielgröße oder Plateau) die
    Strategie-Spezifikationen mit dem ``builder`` der Suche und wertet sie
    gemeinsam mit :func:`simlev.bootstrap_study` auf denselben Pfaden aus.

    Args:
        x: ``SimLevParamSearch``.
        data: Historie für die Pfaderzeugung (wie bei ``bootstrap()``).
        config: Konfiguration aus ``bootstrap_config()``.
        ids: ``id``-Werte aus ``x.results``; ``None`` = die ``top`` besten nach ``by``.
        top: Anzahl bester Punkte (Standard 5).
        by: ``"objective"`` (Standard) oder ``"plateau"``.
        map: Spalten-Aliase (dict), die jeder Spezifikation hinzugefügt werden.
        include: weitere Strategien (dict) im Format von ``strategies``.
        **kwargs: weitere Argumente für ``bootstrap_study()``.

    Returns:
        ``SimLevBootstrapStudy`` mit Attribut ``param_ids`` (Strategiename -> id).
    """
    from .param_search import _as_spec, plateau, _modify_list, _order, _row_params
    by = _match_arg(by, ("objective", "plateau"), "by")
    if not _is_param_search(x):
        raise ValueError("x muss ein SimLevParamSearch sein.")
    include = {} if include is None else include
    res = x["results"]
    if ids is None:
        v = plateau(x)["plateau_mean"].to_numpy(dtype=float) if by == "plateau" else res[x["objective"]].to_numpy(dtype=float)
        o = _order(v, decreasing=x.get("maximize") is True, na_last=None)
        ids = res["id"].to_numpy()[o[:int(top)]]
    ids = [int(i) for i in np.atleast_1d(ids)]
    specs = {}
    for i in ids:
        sp = dict(_as_spec(x["builder"](_row_params(res, i - 1, x["params"]))))
        if map is not None:
            sp["map"] = {**dict(sp.get("map") or {}), **dict(map)}
        specs["p%d" % i] = sp
    args = _modify_list({"data": data, "config": config, "strategies": {**specs, **dict(include)},
                         "sim_args": x["sim_args"], "burn_in": x["burn_in"]}, kwargs)
    st = _ext("bootstrap", "bootstrap_study")(**args)
    pid = pd.Series(ids, index=list(specs.keys()), dtype=np.int64)
    # R-Attribut param_ids: bei Listenobjekten als Python-Attribut ``attrs`` (kein Listenelement)
    attrs = getattr(st, "attrs", None)
    if not isinstance(attrs, dict):
        attrs = {}
        object.__setattr__(st, "attrs", attrs)
    attrs["param_ids"] = pid
    return st


# ─────────────────────────────────────────────────────────────────────────────
# Haircut
# ─────────────────────────────────────────────────────────────────────────────

def _sign(v):
    return np.where(v > 0, 1.0, np.where(v < 0, -1.0, np.where(np.isnan(v), v, 0.0)))


def sharpe_haircut(x, n_obs=None, n_tests=None, frequency=("week", "day", "month"), dates=None,
                   risk_free=0, ppy=52):
    """Sharpe-Ratio-Abschlag für Mehrfachtests (Harvey & Liu 2015).

    Wandelt die Sharpe Ratio jedes Punkts in t- und p-Wert, korrigiert die
    p-Werte (Bonferroni, Holm, Benjamini-Hochberg-Yekutieli) und rechnet sie in
    eine abgeschlagene Sharpe Ratio zurück.

    Args:
        x: ``SimLevParamSearch`` mit Renditen, numerische Renditematrix oder
            Vektor annualisierter Sharpe Ratios (dann ``n_obs`` und ``ppy``).
        n_obs: Anzahl Perioden (nur und zwingend bei Vektor-Eingabe).
        n_tests: Gesamtzahl der Versuche (Standard: Anzahl Sharpe Ratios).
        frequency, dates, risk_free: wie bei :func:`pbo`.
        ppy: Perioden je Jahr, nur bei Vektor-Eingabe (Standard 52).

    Returns:
        ``pandas.DataFrame`` absteigend nach ``sharpe``; ``attrs`` ``n_tests`` und ``n_obs``.
    """
    frequency = _match_arg(frequency, ("week", "day", "month"), "frequency")
    names = None
    is_vec = False
    if isinstance(x, pd.Series) or (isinstance(x, (list, tuple)) and not any(isinstance(e, (list, tuple, np.ndarray)) for e in x)) \
            or (isinstance(x, np.ndarray) and x.ndim <= 1) or isinstance(x, (int, float)) and not isinstance(x, bool):
        a = x.to_numpy() if isinstance(x, pd.Series) else np.asarray(x)
        if a.dtype.kind in "iuf":
            is_vec = True
            if isinstance(x, pd.Series) and not isinstance(x.index, pd.RangeIndex):
                names = [str(i) for i in x.index]
    if is_vec:
        if n_obs is None:
            raise ValueError("n_obs angeben.")
        sr = np.atleast_1d(np.asarray(a, dtype=np.float64)) / math.sqrt(ppy)
        Tn = n_obs
        ids = np.arange(1, sr.size + 1, dtype=np.int64)
    else:
        rr = _of_drop_flat(_rr(x, frequency, dates, risk_free), "sharpe_haircut")
        sr = _of_col_metric(rr.R, "sharpe")
        names = rr.cn
        Tn = rr.R.shape[0]
        ppy = rr.ppy
        ids = rr.cols
    M = n_tests if n_tests is not None else sr.size
    tstat = sr * math.sqrt(Tn)
    p = 2 * np.asarray(_nmath.pnorm(-np.abs(tstat)), dtype=np.float64)

    def padj(method):
        pp = np.concatenate([p, np.ones(int(max(0, M - p.size)))])
        return _p_adjust(pp, method, max(M, p.size))[:p.size]

    def back(pa):
        return _sign(sr) * np.asarray(_nmath.qnorm(1 - np.minimum(pa, 1) / 2), dtype=np.float64) / math.sqrt(Tn) * math.sqrt(ppy)
    out = pd.DataFrame({"id": ids, "sharpe": sr * math.sqrt(ppy), "t": tstat, "p": p})
    if names is not None:
        out.index = names
    for nm, m in (("bonferroni", "bonferroni"), ("holm", "holm"), ("bhy", "BY")):
        pa = padj(m)
        sa = back(pa)
        out["p_" + nm] = pa
        out["sharpe_" + nm] = sa
        sh = out["sharpe"].to_numpy()
        with np.errstate(divide="ignore", invalid="ignore"):
            out["haircut_" + nm] = np.where(np.isnan(sh) | (sh == 0), _NA, 1 - sa / sh)   # ifelse: NA-Test → NA
    o = _order(-out["sharpe"].to_numpy())
    res = out.iloc[o]
    if names is None:
        res.index = (np.asarray(o) + 1)
    res.attrs["n_tests"] = M
    res.attrs["n_obs"] = Tn
    return res


def _order(v, decreasing=False, na_last=True):
    from .param_search import _order as o
    return o(v, decreasing=decreasing, na_last=na_last)


# Rechnen mit NA (signalisierendes NaN) ohne numpy-Warnung "invalid value" wie in R (gemeinsamer Helfer)
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), list(__all__) + ["_of_col_metric", "_of_metric", "_of_returns"])
