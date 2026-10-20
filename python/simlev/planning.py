"""Renditeannahmen, Länder-Bootstrap und Zielplanung (Port von ``r/R/planning.R``).

- :func:`set_expected_return`  verschiebt historische Renditen auf eine eigene
  Renditeannahme (Streuung, Abhängigkeiten und Verlaufsmuster bleiben erhalten)
- :func:`pooled_bootstrap`     stationärer Block-Bootstrap über mehrere Länder
  (Anarkulova, Cederburg & O'Doherty 2022); liefert Pfade für
  ``withdrawal_simulation()``
- :func:`portfolio_returns`    Periodenrenditen von Kandidaten-Portfolios
- :func:`goal_optimize`        dynamische Programmierung: welches Portfolio
  maximiert je Zeitpunkt und Vermögen die Wahrscheinlichkeit, ein Ziel zu
  erreichen (Das, Ostrov, Radhakrishnan & Srivastav 2020)
"""
from __future__ import annotations

import math
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

from ._r import fmt as _fmt
from ._r.fmt import NA_REAL
from ._r import libm as _libm
from ._r import nmath as _nm
from ._r import rng as _rng
from ._r.rlist import RList
from ._rnum import r_mean, r_sd, r_sum
from .deep_analysis import (
    _ext, _fill_na, _is_num_scalar, _key_month, _key_year, _last_of_key, _match_arg, _mean_lgl,
    _row_means, _sp, _stats, _to_date_days,
)

__all__ = ["set_expected_return", "pooled_bootstrap", "portfolio_returns", "goal_optimize", "SimLevGoalPlan"]

_NAN = NA_REAL   # R-NA_real_


def _num_col(v):
    """``as.numeric`` einer Spalte; NA/NaN-Bitmuster numerischer Spalten bleiben erhalten (sonst NA)."""
    if getattr(v, "dtype", None) is not None and v.dtype.kind == "f":
        return v.to_numpy(dtype=np.float64, copy=True)
    return pd.to_numeric(v, errors="coerce").to_numpy(dtype=np.float64, na_value=NA_REAL)


def _numvals(x):
    """Werte und Namen eines numerischen Arguments (Skalar, Liste, Array, Series, dict)."""
    if isinstance(x, pd.Series):
        nm = None if isinstance(x.index, pd.RangeIndex) else [str(i) for i in x.index]
        return x.to_numpy(dtype=object), nm
    if isinstance(x, Mapping):
        return np.array(list(x.values()), dtype=object), [str(k) for k in x.keys()]
    return np.atleast_1d(np.asarray(x, dtype=object)).ravel(), None


def _all_num(a):
    return all(_is_num_scalar(e) for e in a)


def _as_num(a):
    return np.array([float(e) for e in a], dtype=np.float64)


# ═══════════════════════════════════════════════════════════════════════════
# set_expected_return
# ═══════════════════════════════════════════════════════════════════════════

def set_expected_return(data, columns, target, type=("returns", "prices"), ppy=None):  # noqa: A002 - R-Name
    """Historische Renditen auf eine Renditeannahme verschieben.

    Verschiebt die logarithmierten Renditen jeder Spalte um eine Konstante, so
    dass die geometrische Rendite der Historie der Annahme entspricht.

    Args:
        data: DataFrame mit den Spalten aus ``columns`` (``date`` optional).
        columns: Namen der zu verschiebenden Spalten.
        target: Zielrendite in Prozent p. a. (Skalar oder benannt je Spalte).
        type: ``"returns"`` (Brutto-Renditen je Zeile) oder ``"prices"`` (Kursniveaus).
        ppy: Renditen je Jahr (``None`` = aus ``date`` geschätzt, sonst 252).

    Returns:
        Kopie von ``data`` mit angepassten Spalten; ``attrs["shift"]``: angewendete
        Verschiebung je Spalte in Prozent p. a. (``pandas.Series``).
    """
    type = _match_arg(type, ("returns", "prices"))  # noqa: A001
    if not isinstance(data, pd.DataFrame):
        raise ValueError("data muss ein data.frame sein.")
    columns = [columns] if isinstance(columns, str) else [str(c) for c in columns]
    names = [str(c) for c in data.columns]
    miss = [c for c in dict.fromkeys(columns) if c not in names]
    if miss:
        raise ValueError("Spalte(n) nicht in data: %s." % ", ".join(miss))
    tv, tn = _numvals(target)
    if not _all_num(tv) or np.isnan(_as_num(tv)).any():
        raise ValueError("target muss numerisch sein (Prozent p. a., z. B. 4).")
    tv = _as_num(tv)
    if len(tv) == 1 and tn is None:
        tg = {c: float(tv[0]) for c in columns}
    elif tn is None or [c for c in columns if c not in tn]:
        lst = columns if tn is None else [c for c in columns if c not in tn]
        raise ValueError("target braucht einen Skalar oder einen benannten Eintrag je Spalte aus columns; fehlt für: %s."
                         % ", ".join(lst))
    else:
        tg = {}
        for k, v in zip(tn, tv):
            tg.setdefault(k, float(v))
    n = len(data)
    dd = _to_date_days(data["date"], "set_expected_return: data$date") if "date" in names else None
    if dd is not None:
        o = np.argsort(np.where(np.isnan(dd), np.inf, dd), kind="stable")
        o = np.concatenate([o[~np.isnan(dd[o])], o[np.isnan(dd[o])]])
    else:
        o = np.arange(n)
    if type == "prices" and dd is not None:
        vals = ["NA" if math.isnan(v) else v for v in dd.tolist()]
        if len(set(vals)) < len(vals):
            raise ValueError("type = 'prices': date enthält doppelte Daten; Kursniveaus brauchen eine eindeutige Zeitfolge.")
    if ppy is None:
        if dd is not None:
            ok = dd[~np.isnan(dd)]
            ppy = (n - (1 if type == "prices" else 0)) / ((float(np.max(ok)) - float(np.min(ok))) / 365.25)
        else:
            ppy = 252.0
    ppy = float(ppy)
    out = data.copy()
    shift = {}
    for k in columns:
        v = _num_col(data[k])
        lr = _libm.log(v) if type == "returns" else np.diff(_libm.log(v[o]))
        g_hist = r_mean(lr, na_rm=True)
        g_tgt = float(_libm.log1p(tg[k] / 100)) / ppy
        delta = g_tgt - g_hist
        if type == "returns":
            out[k] = v * float(_libm.exp(delta))
        else:
            pos = np.zeros(n, dtype=np.float64)
            pos[o] = np.arange(1, n + 1, dtype=np.float64)
            out[k] = v * _libm.exp(delta * (pos - 1))
        shift[k] = 100 * float(_libm.expm1(delta * ppy))
    out.attrs["shift"] = pd.Series([shift[k] for k in dict.fromkeys(columns)], index=list(dict.fromkeys(columns)),
                                   dtype=np.float64)
    return out


# ═══════════════════════════════════════════════════════════════════════════
# Periodenrenditen
# ═══════════════════════════════════════════════════════════════════════════

def _period_keys(d, frequency):
    if frequency == "month":
        return _key_month(d)
    if frequency == "quarter":
        ym = _key_month(d)
        return ["%s %d" % (k[:4], (int(k[5:7]) - 1) // 3) for k in ym]
    return _key_year(d)


def _period_gross(df, columns, frequency):
    """Periodenrenditen (brutto) aus Kursreihen, ``.period_gross``; ``DataFrame`` Perioden x Spalten."""
    columns = [columns] if isinstance(columns, str) else list(columns)
    d = _to_date_days(df["date"], "data$date")
    key = _period_keys(d, frequency)
    end = _last_of_key(key)
    V = np.column_stack([_fill_na(_num_col(df[k]),
                                  "locf", keep_leading=True)[end] for k in columns]) if columns else np.zeros((len(end), 0))
    G = V[1:, :] / V[:-1, :]
    ok = ~np.isnan(G).any(axis=1)
    return pd.DataFrame(G[ok, :], columns=columns)


def _wd_ppy(frequency):
    try:
        return _ext("withdrawal", "_wd_ppy")(frequency)
    except (ImportError, AttributeError):  # pragma: no cover - Teil B noch nicht verfügbar
        return {"year": 1, "quarter": 4, "month": 12}[frequency]


def _paths_class():
    """Klasse für ``withdrawal_paths`` (Teil B), sonst die lokale."""
    try:
        cls = _ext("withdrawal", "WithdrawalPaths")
        return cls
    except (ImportError, AttributeError):
        return WithdrawalPathsPB


class WithdrawalPathsPB(RList):
    """Ergebnis von :func:`pooled_bootstrap` (R-Klasse ``withdrawal_paths``), falls Teil B keine Klasse liefert."""

    r_class = ("withdrawal_paths",)

    def format(self):
        return "<withdrawal_paths: %s>" % ", ".join(self.keys())


def pooled_bootstrap(datasets, columns, weights=None, inflation=None, frequency=("year", "quarter", "month"),
                     n=1000, years=30, L=None, country_weights=None, target=None, seed=None):
    """Länder-Bootstrap für lange Horizonte.

    Stationärer Block-Bootstrap über mehrere Länder: jeder Block stammt aus
    einem zufällig gezogenen Land und beginnt an einer zufälligen Stelle
    seiner Historie (zyklisch); Blocklänge = 1 + geometrisch verteilte Zahl.

    Args:
        datasets: ``dict`` Land -> DataFrame (``date``, Kursspalten, ggf. Preisindex).
        columns: Kursspalten (in allen Ländern gleich benannt).
        weights: Portfolio-Gewichte je Spalte (benannt oder in Reihenfolge von
            ``columns``); ``None`` = gleiche Gewichte.
        inflation: ``None`` oder Name einer Preisindex-Spalte.
        frequency: ``"year"`` (Standard), ``"quarter"`` oder ``"month"``.
        n: Anzahl Pfade. years: Länge je Pfad in Jahren.
        L: mittlere Blocklänge in Perioden (``None`` = 10 Jahre).
        country_weights: Ziehungswahrscheinlichkeiten je Land.
        target: Renditeannahmen in Prozent p. a. (Skalar oder benannt).
        seed: Startwert (``None`` = aktueller Zufallsstrom).

    Returns:
        ``withdrawal_paths``-Objekt (``returns``, ``inflation``, ``assets``,
        ``countries``, ``country_names``, …).
    """
    frequency = _match_arg(frequency, ("year", "quarter", "month"))
    if not isinstance(datasets, Mapping) or any(str(k) == "" for k in datasets.keys()):
        raise ValueError("datasets muss eine benannte Liste sein (Land -> data.frame).")
    columns = [columns] if isinstance(columns, str) else list(columns)
    ppy = _wd_ppy(frequency)
    if weights is not None:
        wv, wn = _numvals(weights)
        if (not _all_num(wv) or len(wv) != len(columns) or np.isnan(_as_num(wv)).any() or (_as_num(wv) < 0).any()
                or r_sum(_as_num(wv)) <= 0):
            raise ValueError("weights muss je Spalte aus columns (%d) ein Gewicht >= 0 enthalten (Summe > 0)." % len(columns))
        wv = _as_num(wv)
        if wn is None:
            wn = list(columns)
        elif set(wn) != set(columns):
            raise ValueError("Namen von weights (%s) passen nicht zu columns (%s)." % (", ".join(wn), ", ".join(columns)))
        weights = (wn, wv)
    cols = columns + ([inflation] if inflation is not None else [])
    ctry_names = [str(k) for k in datasets.keys()]
    G = [np.array(_period_gross(df, cols, frequency).to_numpy(dtype=np.float64)) for df in datasets.values()]
    if any(g.shape[0] < 2 for g in G):
        raise ValueError("Ein Land hat zu wenige Perioden.")
    ci = {c: i for i, c in reversed(list(enumerate(cols)))}
    if target is not None:
        tv, tn = _numvals(target)
        tv = _as_num(tv)
        if len(tv) == 1 and tn is None:
            tg = [(c, float(tv[0])) for c in columns]
        else:
            tg = list(zip(tn, tv.tolist())) if tn is not None else []
        for k, t in tg:
            j = ci[k]
            all_lr = np.concatenate([_libm.log(g[:, j]) for g in G])
            delta = float(_libm.log1p(t / 100)) / ppy - r_mean(all_lr)
            ed = float(_libm.exp(delta))
            for g in G:
                g[:, j] = g[:, j] * ed
    if L is None:
        L = 10 * ppy
    L = float(L)
    nper = int(years * ppy)
    nc = len(G)
    cw = np.repeat(1 / nc, nc) if country_weights is None else np.asarray(country_weights, dtype=np.float64).ravel()
    cw = cw / r_sum(cw)
    nrs = [g.shape[0] for g in G]

    def draw_all():
        out = []
        for _ in range(int(n)):
            ctry = np.zeros(nper, dtype=np.int64)
            row = np.zeros(nper, dtype=np.int64)
            t = 1
            while t <= nper:
                cidx = int(_rng.sample_int(nc, 1, prob=cw)[0])
                ln = 1 + float(_rng.rgeom(1, 1 / L)[0])
                nr = nrs[cidx - 1]
                st = int(_rng.sample_int(nr, 1)[0])
                take = int(min(ln, nper - t + 1))
                idx = ((st - 1 + np.arange(1, take + 1) - 1) % nr) + 1
                ctry[t - 1:t - 1 + take] = cidx
                row[t - 1:t - 1 + take] = idx
                t += take
            out.append((ctry, row))
        return out

    draw = _ext("bootstrap", "_with_rng_restore")(draw_all, seed=seed)
    Gall = np.vstack(G)
    off = np.concatenate([[0], np.cumsum(nrs)])[:nc]
    gi = np.column_stack([off[c - 1] + r for c, r in draw]) if draw else np.zeros((nper, 0), dtype=np.int64)
    A = {k: Gall[gi - 1, j].reshape(nper, int(n)) for k, j in ((c, ci[c]) for c in dict.fromkeys(cols))}
    if weights is None:
        wn, wv = list(columns), np.repeat(1 / len(columns), len(columns))
    else:
        wn, wv = weights
        wv = wv / r_sum(wv)
    Rp = None
    for k, wk in zip(wn, wv):
        term = wk * A[k]
        Rp = term if Rp is None else Rp + term
    Inf_m = A[inflation] if inflation is not None else np.ones((nper, int(n)))
    cmat = np.array([[ctry_names[c - 1] for c in col] for col in (dr[0] for dr in draw)], dtype=object).T \
        if draw else np.zeros((nper, 0), dtype=object)
    cls = _paths_class()
    return cls([("returns", Rp), ("inflation", Inf_m), ("cape", None), ("base_rate", None), ("frequency", frequency),
                ("historical", False), ("start_dates", None), ("weights", None), ("source", "pooled_bootstrap"),
                ("assets", {k: A[k] for k in columns}), ("countries", cmat), ("country_names", ctry_names)])


# ═══════════════════════════════════════════════════════════════════════════
# portfolio_returns
# ═══════════════════════════════════════════════════════════════════════════

def _dgemv_n(A, x):
    """``A %*% x`` (Matrix mal Vektor) wie R (``R_Matprod = "default"``)."""
    from ._r import linalg as _lin
    r = _lin.matprod(A, x.reshape(-1, 1))
    return np.asarray(r.to_numpy() if isinstance(r, pd.DataFrame) else r, dtype=np.float64).ravel()


def portfolio_returns(data, candidates, frequency=("year", "quarter", "month")):
    """Periodenrenditen von Kandidaten-Portfolios (feste Gewichte, Rebalancing je Periode).

    Args:
        data: DataFrame mit ``date`` und den Kursspalten der Kandidaten.
        candidates: Liste bzw. ``dict`` benannter Gewichtsvektoren
            (``Series``/``dict``: Kursspalte -> Gewicht); ``dict``-Schlüssel
            werden Spaltennamen, sonst ``P1``, ``P2``, …
        frequency: ``"year"`` (Standard), ``"quarter"`` oder ``"month"``.

    Returns:
        DataFrame Perioden x Kandidaten mit Brutto-Renditen.
    """
    frequency = _match_arg(frequency, ("year", "quarter", "month"))
    if isinstance(candidates, Mapping):
        cnames = [str(k) for k in candidates.keys()]
        cands = list(candidates.values())
    else:
        cands = list(candidates)
        cnames = ["P%d" % (i + 1) for i in range(len(cands))]
    ws = []
    for w in cands:
        wv, wn = _numvals(w)
        ws.append((wn, _as_num(wv)))
    a = list(dict.fromkeys(k for wn, _ in ws for k in (wn or [])))
    G = _period_gross(data, a, frequency)
    Gm = G.to_numpy(dtype=np.float64)
    cols = []
    for wn, wv in ws:
        sub = np.column_stack([Gm[:, a.index(k)] for k in wn]) if wn else np.zeros((Gm.shape[0], 0))
        cols.append(_dgemv_n(sub, wv / r_sum(wv)))
    M = np.column_stack(cols) if cols else np.zeros((Gm.shape[0], 0))
    return pd.DataFrame(M, columns=cnames)


# ═══════════════════════════════════════════════════════════════════════════
# goal_optimize
# ═══════════════════════════════════════════════════════════════════════════

def _approx2(x, y, xout):
    """``approx(x, y, xout, rule = 2)$y``."""
    r = _stats("approx")(x, y, xout=xout, rule=2)
    v = r["y"] if isinstance(r, Mapping) else getattr(r, "y")
    return np.atleast_1d(np.asarray(v, dtype=np.float64))


def _fmt_vals(v):
    a = np.atleast_1d(np.asarray(v, dtype=object)).ravel()
    try:
        f = np.asarray(a, dtype=np.float64)
        out = _fmt.format(f) if f.size != 1 else _fmt.format(float(f[0]))
    except (TypeError, ValueError):
        out = _fmt.format(a)
    return ", ".join(str(s) for s in np.atleast_1d(out))


def goal_optimize(returns, start_value, goal, horizon, contributions=0, n_grid=301, n_sim=5000, seed=None):
    """Zielbasierte Allokation per dynamischer Programmierung (Das et al. 2020).

    Bestimmt für jeden Zeitpunkt und jedes Vermögen den Kandidaten, der die
    Wahrscheinlichkeit maximiert, zum Horizont ``goal`` zu erreichen; die
    gemeldete ``probability`` ist die Erfolgsquote der Vorwärtssimulation.

    Args:
        returns: Matrix (Szenarien x Kandidaten) von Brutto-Periodenrenditen.
        start_value: Startvermögen (> 0). goal: Zielvermögen (>= 0).
        horizon: Anzahl Perioden (ganze Zahl >= 1).
        contributions: Zahlung je Periode (Skalar oder Vektor, ``rep_len``).
        n_grid: Punkte des logarithmischen Vermögensrasters (>= 2).
        n_sim: Pfade der Vorwärtssimulation. seed: Startwert.

    Returns:
        :class:`SimLevGoalPlan`.
    """
    if isinstance(returns, pd.DataFrame):
        cn0 = [str(c) for c in returns.columns] if not isinstance(returns.columns, pd.RangeIndex) else None
        try:
            R = returns.to_numpy(dtype=np.float64, na_value=NA_REAL)
            isnum = all(pd.api.types.is_numeric_dtype(t) and not pd.api.types.is_bool_dtype(t) for t in returns.dtypes)
        except (TypeError, ValueError):
            R, isnum = None, False
    else:
        a = np.asarray(returns)
        if a.ndim == 1:
            a = a.reshape(-1, 1)
        isnum = a.dtype.kind in "iuf"
        R = a.astype(np.float64) if isnum else None
        cn0 = None
    S, K = (R.shape if R is not None else (0, 0))
    if not isnum or not S or not K or (~np.isfinite(R)).any() or (R < 0).any():
        raise ValueError("returns muss eine Matrix (Szenarien x Kandidaten) endlicher Brutto-Renditen >= 0 ohne NA sein "
                         "(z. B. 1.05).")

    def num1(v):
        a = np.atleast_1d(np.asarray(v, dtype=object)).ravel()
        return len(a) == 1 and _is_num_scalar(a[0]) and math.isfinite(float(a[0]))

    if not num1(start_value) or float(np.ravel(start_value)[0]) <= 0:
        raise ValueError("start_value muss ein Geldbetrag > 0 sein (erhalten: %s)." % _fmt_vals(start_value))
    if not num1(goal) or float(np.ravel(goal)[0]) < 0:
        raise ValueError("goal muss ein Geldbetrag >= 0 sein (erhalten: %s)." % _fmt_vals(goal))
    if not num1(horizon) or float(np.ravel(horizon)[0]) < 1 or float(np.ravel(horizon)[0]) != _fmt.r_round(float(np.ravel(horizon)[0])):
        raise ValueError("horizon muss eine ganze Zahl >= 1 sein (Anzahl Perioden; erhalten: %s)." % _fmt_vals(horizon))
    if not num1(n_grid) or float(np.ravel(n_grid)[0]) < 2:
        raise ValueError("n_grid muss eine ganze Zahl >= 2 sein (erhalten: %s)." % _fmt_vals(n_grid))
    if not num1(n_sim) or float(np.ravel(n_sim)[0]) < 1:
        raise ValueError("n_sim muss eine ganze Zahl >= 1 sein (erhalten: %s)." % _fmt_vals(n_sim))
    cv = np.atleast_1d(np.asarray(contributions.to_numpy() if isinstance(contributions, pd.Series) else contributions,
                                  dtype=object)).ravel()
    if not _all_num(cv) or not len(cv) or (~np.isfinite(_as_num(cv))).any():
        raise ValueError("contributions muss ein endlicher Geldbetrag oder Vektor von Geldbeträgen sein.")
    start_value = float(np.ravel(start_value)[0])
    goal = float(np.ravel(goal)[0])
    horizon = int(float(np.ravel(horizon)[0]))
    n_grid = float(np.ravel(n_grid)[0])
    n_sim = int(float(np.ravel(n_sim)[0]))
    cn = cn0 if cn0 is not None else ["P%d" % (j + 1) for j in range(K)]
    cvf = _as_num(cv)
    cf = np.array([cvf[i % len(cvf)] for i in range(horizon)], dtype=np.float64)
    wmax = max(goal, start_value) * 20
    pos = [v for v in (goal, start_value) if v > 0]
    wmin = max(1e-6, min(pos) / 1000)
    lg = _stats("seq_len_out")(float(_libm.log(wmin)), float(_libm.log(wmax)), int(math.ceil(n_grid)))
    pts = list(_libm.exp(np.asarray(lg, dtype=np.float64)))
    if goal > 0:
        pts.append(goal)
    pts.append(start_value)
    grid = np.array(sorted(set(float(p) for p in pts)), dtype=np.float64)
    ng = len(grid)
    lgrid = _libm.log(grid)

    def term(W):
        return (np.asarray(W) >= goal).astype(np.float64)

    V = term(grid)
    pol = np.zeros((horizon, ng), dtype=np.int64)
    Vt = [None] * (horizon + 1)
    Vt[horizon] = V

    def interp(Vn, W):
        W = np.atleast_1d(np.asarray(W, dtype=np.float64))
        out = np.zeros(len(W))
        out[W >= wmax] = 1.0 * (wmax >= goal)
        out[W <= 0] = 0.0
        mid = (W > 0) & (W < wmax)
        z = _nm.qnorm(np.minimum(1 - 1e-12, np.maximum(1e-12, np.asarray(Vn, dtype=np.float64))))
        Wm = W[mid]
        if Wm.size:
            pn = np.atleast_1d(np.asarray(_nm.pnorm(_approx2(lgrid, np.asarray(z, dtype=np.float64), _libm.log(Wm))),
                                          dtype=np.float64))
            alt = 0.0 if goal > 0 else float(Vn[0])
            out[mid] = np.where(Wm < wmin, alt, pn)
        return out

    def expect(Vn, base, k, last):
        X = np.multiply.outer(base, R[:, k])
        xv = X.ravel(order="F")
        v = (term(xv) if last else interp(Vn, xv)).reshape(X.shape, order="F")
        e = _row_means(v)
        e[base <= 0] = 0.0
        return e

    static = np.zeros(K)
    for k in range(K):
        Vs = V
        for t in range(horizon, 0, -1):
            Vs = expect(Vs, grid + cf[t - 1], k, t == horizon)
        static[k] = float(interp(Vs, start_value)[0])
    lr = _libm.log(np.maximum(R, 1e-300))
    sds = np.array([r_sd(lr[:, j]) for j in range(K)])
    risk_rank = np.empty(K, dtype=np.int64)
    risk_rank[np.argsort(sds, kind="stable")] = np.arange(1, K + 1)
    tie_score = np.tile((K + 1 - risk_rank).astype(np.float64), (ng, 1))
    for t in range(horizon, 0, -1):
        base = grid + cf[t - 1]
        E = np.column_stack([expect(V, base, k, t == horizon) for k in range(K)])
        best = E >= (np.max(E, axis=1) - 1e-9)[:, None]
        sc = np.where(best, tie_score, 0.0)
        pol[t - 1, :] = np.argmax(sc, axis=1) + 1
        V = E[np.arange(ng), pol[t - 1, :] - 1]
        Vt[t - 1] = V
    p_dp = float(interp(V, start_value)[0])

    def run():
        W = np.repeat(start_value, n_sim)
        choice = np.zeros((horizon, n_sim), dtype=np.int64)
        ruined = np.zeros(n_sim, dtype=bool)
        for t in range(horizon):
            base = W + cf[t]
            alive = (base > 0) & ~ruined
            ruined = ruined | ~alive
            g = np.maximum(1, np.minimum(ng, np.searchsorted(lgrid, _libm.log(np.maximum(W, wmin)), side="right")))
            k = pol[t, g - 1]
            choice[t, :] = k
            draw = _rng.sample_int(S, n_sim, replace=True)
            W = np.where(alive, base * R[draw - 1, k - 1], 0.0)
        return {"terminal": W, "choice": choice, "success": ~ruined & (W >= goal)}

    sim = _ext("bootstrap", "_with_rng_restore")(run, seed=seed)
    p_sim = _mean_lgl(sim["success"])
    se = math.sqrt(p_sim * (1 - p_sim) / n_sim)
    tol = 4 * math.sqrt(max(p_sim * (1 - p_sim), 1 / n_sim) / n_sim) + 0.01
    if abs(p_dp - p_sim) > tol:
        warnings.warn(_sp("goal_optimize: DP-Wert %.1f %% weicht von der Vorwärtssimulation %.1f %% ab; "
                          "probability ist der simulierte Wert (n_grid erhöhen).", 100 * p_dp, 100 * p_sim))
    return SimLevGoalPlan([
        ("probability", p_sim), ("probability_se", se), ("probability_dp", p_dp),
        ("static", pd.Series(static, index=cn)), ("policy", pol), ("grid", grid), ("value", Vt),
        ("simulation", sim), ("goal", goal), ("start_value", start_value), ("horizon", horizon),
        ("contributions", cf), ("candidates", cn)])


def _eur(v):
    a = _fmt.r_round(np.atleast_1d(np.asarray(v, dtype=np.float64)))
    out = _fmt.formatC(a, format="d", big_mark=" ")
    return [str(s) for s in np.atleast_1d(out)]


class SimLevGoalPlan(RList):
    """Ergebnis von :func:`goal_optimize` (R-Klasse ``SimLevGoalPlan``)."""

    r_class = ("SimLevGoalPlan",)

    def format(self):
        cf = np.asarray(self["contributions"], dtype=np.float64)
        pay = ""
        if (cf != 0).any():
            pay = ", Zahlungen %s je Periode" % "/".join(_eur(list(dict.fromkeys(cf.tolist()))))
        out = [_sp("Zielplanung: Ziel %s in %d Perioden, Start %s%s\n", _eur(self["goal"])[0], int(self["horizon"]),
                   _eur(self["start_value"])[0], pay)]
        pse = self.get("probability_se")
        out.append(_sp("Zielwahrscheinlichkeit dynamisch: %.1f %% (Vorwärtssimulation, SE %.1f Prozentpunkte; "
                       "DP-Wert %.1f %%)\n", 100 * self["probability"], 100 * (_NAN if pse is None else pse),
                       100 * self["probability_dp"]))
        st = self["static"]
        sv = np.asarray(st, dtype=np.float64)
        best = int(np.argmax(sv))
        out.append(_sp("Bester fester Kandidat: %s mit %.1f %%\n\n", str(st.index[best]), 100 * sv[best]))
        out.append(_fmt.print_vector(pd.Series(_fmt.r_round(100 * sv, 1), index=list(st.index))) + "\n")
        cands = list(self["candidates"])
        first = np.asarray(self["simulation"]["choice"])[0, :]
        cnt = np.bincount(first - 1, minlength=len(cands))
        out.append("\nWahl im ersten Schritt: %s" % cands[int(np.argmax(cnt))])
        return "".join(out)

    def plot(self, **kwargs):
        """Optimale Kandidatenwahl je Periode und Vermögen (Vermögen log10)."""
        import matplotlib.pyplot as plt
        g = np.asarray(self["grid"])
        keep = (g >= self["goal"] / 20) & (g <= self["goal"] * 3)
        P = np.asarray(self["policy"])[:, keep]
        fig, ax = plt.subplots(figsize=(9, 5))
        ax.pcolormesh(np.arange(1, self["horizon"] + 1), np.log10(g[keep]), P.T, cmap="coolwarm",
                      vmin=1, vmax=len(self["candidates"]), shading="nearest", **kwargs)
        if self["goal"] > 0:
            ax.axhline(math.log10(self["goal"]), ls="--", color="k")
        ax.set_xlabel("Periode")
        ax.set_ylabel("Vermögen (log10)")
        ax.set_title("Optimale Wahl je Zeit und Vermögen")
        return self


from .data_prep import _quiet_fp  # noqa: E402

_quiet_fp(globals(), __all__ + ["_period_gross"])
