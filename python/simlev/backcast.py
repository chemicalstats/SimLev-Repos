"""Rückrechnung (Backcast) von Produkt-Kursreihen (Gegenstück zu ``r/R/backcast.R``).

Verlängert die Historie eines ETF/ETP (auch gehebelt oder invers) über dessen
Auflegung hinaus in die Vergangenheit:

1. :func:`backcast_fit` passt die Modellparameter auf dem Überlappungszeitraum
   von Produkt und Basisindex an (Abweichungsminimierung),
2. :func:`backcast` rechnet das Produkt vor der Auflegung zurück und verkettet
   (Chain-Linking) mit der echten Kursreihe.

Strukturmodell (MSCI Daily Leveraged/Short Index, plus Fondskosten)::

    r_t = beta * L * x_t + (1 - L) * rate_t * T_t / rate_basis - TER_t * T_t / ter_basis
        - spread * m(L) * T_t / rate_basis - drag * T_t / 365

PROZENT-KONVENTION: ter, rate, spread und drag in Prozent p. a.
"""
from __future__ import annotations

import math
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

from ._pruefen import chk_msg, chk_stop   # seit 1.6.5 (Entscheidung 193)
from . import _lib
from ._r import libm as _libm
from ._r.base import quiet_fp
from ._r.fmt import NA_REAL
from ._r.rlist import RList
from ._r.rnum import _drop_na, r_cumsum, r_isna, r_mean, r_median, r_sd, r_sum
from .data_prep import (
    _as_dates, _as_date_any, _as_frame, _as_numeric, _col, _date_str, _days, _is_named_numeric,
    _is_number, _match_arg, _named_parts, _names, _names_as_dates_optional, _nrow, _to_date,
    _which_min,
)
from ._util import _which_max
from ._util import _pow1m_v
from ._util import _unique as _r_unique

__all__ = ["backcast_fit", "backcast", "SimLevBackcastFit", "SimLevBackcast", "summary_SimLevBackcastFit", "plot_SimLevBackcastFit", "plot_SimLevBackcast"]

_NAN = NA_REAL   # R-NA_real_


def _r_min(v):
    """R's ``min()`` für Doubles: NA vor NaN (jeweils das erste), sonst das Minimum."""
    v = np.asarray(v, dtype=np.float64).ravel()
    bad = np.flatnonzero(np.isnan(v))
    if bad.size:
        na = [i for i in bad if r_isna(v[i])]
        return float(v[na[0] if na else bad[0]])
    return float(np.min(v)) if v.size else math.inf


# ═══════════════════════════════════════════════════════════════════════════
# Interne Helfer
# ═══════════════════════════════════════════════════════════════════════════

def _is_numeric_value(x) -> bool:
    if _is_number(x):
        return True
    if isinstance(x, (pd.Series, pd.Index)):
        return x.dtype.kind in "iuf"
    if isinstance(x, np.ndarray):
        return x.dtype.kind in "iuf" or (x.dtype == object and x.size > 0 and all(_is_number(v) for v in x.ravel()))
    if isinstance(x, (list, tuple)):
        return len(x) > 0 and all(_is_number(v) for v in x)
    return False


def _resolve_series(x, data, what, default=0):
    """Zeitreihe aus flexibler Nutzerangabe auflösen (R: ``.resolve_series``).

    Args:
        x: ``None``, Skalar, Vektor der Länge n, Spaltenname in ``data``,
            ``DataFrame(date, value)`` als Stufenfunktion oder benannter Vektor
            (``Series``/``dict``) mit Datumsnamen (Wert gilt ab diesem Datum).
        data: ``DataFrame`` mit Spalte ``date``.
        what: Bezeichnung für Fehlermeldungen.
        default: Wert für ``None``.

    Returns:
        float-Array der Länge ``nrow(data)``.
    """
    n = _nrow(data)
    if x is None:
        return np.full(n, float(default))
    # seit 1.6.5 (CR2-P-5): Stufentabelle bzw. benannter Vektor braucht die Spalte date in data (R .resolve_series)
    if (isinstance(x, pd.DataFrame) or _is_named_numeric(x)) and "date" not in _names(data):
        chk_stop("spalten", what, "'date'")
    xf = _as_frame(x)
    if isinstance(xf, pd.DataFrame):
        if xf.shape[1] < 2:
            chk_stop("c.m_resolve_series", what)
        nm = _names(xf)
        dcol = "date" if "date" in nm else nm[0]
        vcol = [k for k in nm if k != dcol][0]
        fd = _days(_to_date(_col(xf, dcol), "%s: Datum" % what))
        if np.isnan(fd).any():   # seit 1.6.4 abgelehnt wie in R und Julia (Entscheidung 147, T3-N5)
            chk_stop("ut3.datum_fehlt", what, int(np.flatnonzero(np.isnan(fd))[0]) + 1)
        return _step_series(fd, _as_numeric(_col(xf, vcol)), _days(_to_date(_col(data, "date"), what)))
    if isinstance(x, str) or (isinstance(x, (list, tuple, np.ndarray)) and len(x) == 1 and isinstance(list(np.ravel(x))[0], str)):
        x = x if isinstance(x, str) else str(list(np.ravel(x))[0])
        if x not in _names(data):
            chk_stop("a.m_cpi_level", what, x)
        v = _as_numeric(_col(data, x))
        if np.isnan(v).any():
            v = _fill_na(v, "locf")
        return v
    if _is_named_numeric(x):
        names, vals = _named_parts(x)
        nd = _names_as_dates_optional(names)
        if len(vals) >= 1 and not np.isnan(nd).any():
            return _step_series(nd, vals, _days(_to_date(_col(data, "date"), what)))
        x = vals
    if _is_numeric_value(x):
        a = np.atleast_1d(np.asarray(x.to_numpy() if isinstance(x, pd.Series) else x, dtype=np.float64)).ravel()
        if a.size == 1:
            return np.full(n, float(a[0]))
        if a.size == n:
            return a.copy()
    raise ValueError("%s: nicht interpretierbare Angabe (Skalar, Vektor der Länge %d, Spaltenname, "
                     "data.frame(date, Wert) oder benannter Vektor mit Datumsnamen)." % (what, n))


def _step_series(from_, value, dates):
    """Stufenfunktion: Wert gilt ab Datum (vor dem ersten Datum: erster Wert). R: ``.step_series``.

    ``from_`` und ``dates`` als float-Tage oder datetime64.
    """
    f = _days(from_)
    v = np.asarray(value, dtype=np.float64)
    o = np.argsort(f, kind="stable")
    f = f[o]
    v = v[o]
    d = _days(dates)
    k = np.searchsorted(f, d, side="right")
    k[k == 0] = 1
    out = v[k - 1].astype(np.float64)
    out[np.isnan(d)] = _NAN
    return out


def _approx_y(x, y, xout):
    from ._r import stats as _st
    r = _st.approx(x, y, xout=xout)
    return np.asarray(r["y"] if isinstance(r, Mapping) else getattr(r, "y", r), dtype=np.float64)


def _fill_na(v, method=("locf", "linear", "stine", "none"), keep_leading=False):
    """Fehlende Werte füllen (R: ``.fill_na``).

    Args:
        v: numerischer Vektor.
        method: ``"locf"`` (Standard), ``"linear"``, ``"stine"`` (Stineman-Interpolation der
            inneren Lücken mit der C-Bibliothek slc, ``_lib.stineman``, seit 1.0.0; Stützstellen
            sind die Positionen der vorhandenen Werte) oder ``"none"``.
        keep_leading: Führende NAs beibehalten (True) oder rückwärts füllen.

    Returns:
        float-Array (Kopie).
    """
    method = _match_arg(method, ("locf", "linear", "stine", "none"))
    v = np.array(_as_numeric(v), dtype=np.float64)
    ok = np.flatnonzero(~np.isnan(v))
    if method == "none" or len(ok) == 0 or len(ok) == len(v):
        return v
    first, last = int(ok[0]), int(ok[-1])
    if method == "locf":
        idx = np.zeros(len(v), dtype=np.int64)
        idx[ok] = ok + 1
        idx = np.maximum.accumulate(idx)
        idx[idx == 0] = first + 1
        out = v[idx - 1]
    elif method == "linear":
        out = v.copy()
        inner = np.arange(first, last + 1)
        out[inner] = _approx_y((ok + 1).astype(np.float64), v[ok], (inner + 1).astype(np.float64))
        if last < len(v) - 1:
            out[last + 1:] = v[last]
        if first > 0:
            out[:first] = v[first]
    else:
        out = v.copy()
        gap = np.setdiff1d(np.arange(first, last + 1), ok)       # innere Lücken (0-basiert)
        out[gap] = _lib.stineman((ok + 1).astype(np.float64), v[ok], (gap + 1).astype(np.float64))
        if last < len(v) - 1:
            out[last + 1:] = v[last]
        if first > 0:
            out[:first] = v[first]
    if keep_leading and first > 0:
        out[:first] = _NAN
    return out



def _fill_locf(v):
    """``.fill_na(v, "locf")`` für ein float-Feld (seit 1.6.3 eine Fassung für sensitivity und withdrawal)."""
    return _fill_na(np.asarray(v, dtype=np.float64), "locf")


def _shift(v, k):
    """Vektor um k Zeilen verschieben (k > 0: Verzögerung). R: ``.shift``."""
    v = np.asarray(v, dtype=np.float64)
    n = len(v)
    k = int(k)
    if k == 0:
        return v.copy()
    if k > 0:
        return np.concatenate([np.full(k, _NAN), v[: max(n - k, 0)]])
    return np.concatenate([v[-k:], np.full(-k, _NAN)])


def _sq(e):
    e = np.asarray(e, dtype=np.float64)
    return e * e


def _bc_loss(e, loss):
    """Verlustfunktionen für den Fit (R: ``.bc_loss``)."""
    e = np.asarray(e, dtype=np.float64)
    e = e[np.isfinite(e)]
    if not len(e):
        return math.inf
    if loss == "rmse":
        return math.sqrt(r_mean(_sq(e)))
    if loss == "mse":
        return r_mean(_sq(e))
    if loss == "mae":
        return r_mean(np.abs(e))
    if loss == "median":
        return r_median(np.abs(e))
    if loss == "max":
        return float(np.max(np.abs(e)))
    raise ValueError("Unbekannte loss-Funktion '%s'." % loss)


def _bc_metric_table(err_mat, grid, m=None):
    """Grid-Search-Metriken (R: ``.bc_metric_table``): bestes Gitterelement je Metrik. ``err_mat``: Matrix (Spalten =
    Gitterpunkte) oder Liste der Spalten (Länge ``m`` je Spalte). Seit 1.6.4 (B-071) je Spalte einmal NA-Filter und
    abs (bis 1.6.3 je Metrik eine eigene Kopie); gleiche Werte (``x * x`` = ``|x| * |x|``, dieselben Summen)."""
    names = ("median_absolute_error", "mean_absolute_error", "mean_squared_error", "root_mean_squared_error",
             "max_absolute_error", "final_absolute_error")
    cols = err_mat if isinstance(err_mat, list) else [err_mat[:, j] for j in range(err_mat.shape[1])]
    M = [[], [], [], [], [], []]
    for x in cols:
        x = np.asarray(x, dtype=np.float64)
        a = np.abs(_drop_na(x))                 # x ohne NA/NaN (_r/rnum.py)
        q = a * a
        mq = r_mean(q)
        M[0].append(r_median(a))
        M[1].append(r_mean(a))
        M[2].append(mq)
        M[3].append(math.sqrt(mq))
        M[4].append(float(np.max(a)) if len(a) else -math.inf)
        M[5].append(abs(x[np.flatnonzero(np.isfinite(x)).max()]))
    grid = np.asarray(grid, dtype=np.float64)
    return pd.Series({k: float(grid[_which_min(M[i], -1)]) for i, k in enumerate(names)})


def _recycle2(x, y):
    x = np.asarray(x, dtype=np.float64)
    y = np.asarray(y, dtype=np.float64)
    n = max(x.size, y.size)
    return np.resize(x, n), np.resize(y, n)


class _Prep(dict):
    def __getattr__(self, k):
        return self[k]


def _bc_prepare(data, product, index, ter, leverage, rate, fx, rate_lag,
                ter_basis, rate_basis, accrual, index_fill, lag):
    """Überlappung, Komponenten und Hilfsgrößen vorbereiten (R: ``.bc_prepare``)."""
    data = _as_frame(data)
    if not isinstance(data, pd.DataFrame):
        chk_stop("c.m_bc_prepare")
    if "date" not in _names(data):
        chk_stop("c.m_bc_prepare_2")
    data = data.copy()
    dts = _to_date(_col(data, "date"), "'data$date'")
    data["date"] = dts
    dd0 = _days(dts)
    if np.isnan(dd0).any():
        chk_stop("c.m_bc_prepare_3")
    if (np.diff(dd0) <= 0).any():
        chk_stop("c.m_bc_prepare_4")
    for col in [product, index]:
        if col not in _names(data):
            chk_stop("c.m_bc_prepare_5", col)
    if not _is_numeric_value(leverage) or np.size(leverage) != 1 or float(np.ravel(leverage)[0]) == 0:
        chk_stop("c.m_bc_check_args")
    L = float(np.ravel(leverage)[0])
    idx = _as_numeric(_col(data, index))
    if fx is not None:
        idx = idx * _resolve_series(fx, data, "fx")
    if np.isnan(idx).any():
        idx = _fill_na(idx, index_fill, keep_leading=True)
    with np.errstate(invalid="ignore"):
        if (idx[~np.isnan(idx)] <= 0).any():
            chk_stop("c.m_bc_prepare_6")
    prod = _as_numeric(_col(data, product)).copy()
    with np.errstate(invalid="ignore"):
        prod[~np.isnan(prod) & (prod <= 0)] = _NAN
    n = data.shape[0]
    dd = np.concatenate([[1.0], np.diff(dd0)])
    with np.errstate(invalid="ignore", divide="ignore"):
        x = np.concatenate([[_NAN], idx[1:] / idx[:-1] - 1])
    if lag != 0:
        x = _shift(x, lag)
    ter_v = _resolve_series(ter, data, "ter")
    rate_v = _resolve_series(rate, data, "rate")
    if rate_lag != 0:
        rate_v = _fill_na(_shift(rate_v, rate_lag), "locf")
    if accrual == "geometric":
        ter_cost = _pow1m_v(*_recycle2(ter_v / 100, dd / ter_basis))   # seit 1.6.2 expm1(log1p(x) * e) (P1)
    else:
        ter_cost = ter_v / 100 * dd / ter_basis
    fin = (1 - L) * rate_v / 100 * dd / rate_basis
    m_lev = max(L - 1, 0) + max(-L, 0)
    return _Prep(data=data, n=n, dates=dd0, idx=idx, prod=prod, x=x, dd=dd, leverage=L, ter=ter_v,
                 rate=rate_v, ter_cost=ter_cost, fin=fin, sp_unit=m_lev / 100 * dd / rate_basis,
                 dr_unit=dd / 100 / 365)


def _bc_model_returns(prep, par, model, reg=None):
    """Modellrenditen für einen Parametersatz (R: ``.bc_model_returns``)."""
    return _bc_base(prep, par, model, reg) - par["spread"] * prep.sp_unit - par["drag"] * prep.dr_unit


def _bc_base(prep, par, model, reg=None):
    """Basis der Modellrenditen ohne spread und drag (R: ``.bc_base``); hängt nur im Strukturmodell von par (beta) ab."""
    if model == "structural":
        return par["beta"] * prep.leverage * prep.x + prep.fin - prep.ter_cost
    if model == "linear":
        coef = np.asarray(reg["coef"], dtype=np.float64)
        return coef[0] + coef[1] * prep.x
    base = np.full(prep.n, _NAN)
    ok = np.isfinite(prep.x)
    base[ok] = _spline_predict(reg["fit"], prep.x[ok])
    return base


def _bc_errors(r, win, obs, objective, horizon):
    """Abweichungsvektor(en) im Fit-Fenster (R: ``.bc_errors``; ``win`` 0-basiert)."""
    rr = np.array(np.asarray(r, dtype=np.float64)[win], dtype=np.float64)
    rr[0] = 0
    rr[~np.isfinite(rr)] = 0
    ls = r_cumsum(_libm.log1p(np.maximum(rr, -0.999999)))
    so = ls[obs["pos"]]
    po = obs["logp"]
    e_lvl = (so - so[0]) - (po - po[0])
    if objective == "level":
        return e_lvl
    m = len(so)
    h = max(1, int(horizon))
    e_ret = ((so[h:] - so[: m - h]) - (po[h:] - po[: m - h])) if m > h else np.empty(0)
    if objective == "return":
        return e_ret
    return {"level": e_lvl, "ret": e_ret}


def _bc_cprob(prep, model, reg, rows, obs, objective, loss, horizon, hybrid_weight):
    """Daten der Zielfunktion für die C-Bibliothek (R: ``.bc_cprob``); ``rows`` 0-basiert."""
    rows = np.asarray(rows)
    if model == "structural":
        x = np.asarray(prep.x, dtype=np.float64)[rows]
        c1 = np.asarray(prep.fin, dtype=np.float64)[rows]
        c2 = np.asarray(prep.ter_cost, dtype=np.float64)[rows]
    else:
        x = None
        c2 = None
        c1 = np.asarray(_bc_model_returns(prep, {"drag": 0.0, "spread": 0.0, "beta": 1.0}, model, reg), dtype=np.float64)[rows]
    return (x, c1, c2, float(prep.leverage), np.asarray(prep.sp_unit, dtype=np.float64)[rows],
            np.asarray(prep.dr_unit, dtype=np.float64)[rows], np.asarray(obs["pos"]) + 1, np.asarray(obs["logp"], dtype=np.float64),
            (("level", "return", "hybrid").index(objective) + 1, ("rmse", "mse", "mae", "median", "max").index(loss) + 1,
             max(1, int(horizon))), float(hybrid_weight))


def _bc_objective(r, win, obs, objective, horizon, loss, hybrid_weight):
    """Zielfunktion (R: ``.bc_objective``)."""
    e = _bc_errors(r, win, obs, objective, horizon)
    if objective != "hybrid":
        return _bc_loss(e, loss)
    return math.sqrt(hybrid_weight * r_mean(_sq(e["ret"])) + (1 - hybrid_weight) * r_mean(_sq(e["level"])))


def _cor(x, y):
    from ._r import stats as _st
    return float(_st.cor(np.asarray(x, dtype=np.float64), np.asarray(y, dtype=np.float64)))


def _bc_diagnostics(r, win, obs, dates):
    """Kennzahlen Simulation vs. Produkt (R: ``.bc_diagnostics``)."""
    rr = np.array(np.asarray(r, dtype=np.float64)[win], dtype=np.float64)
    rr[0] = 0
    rr[~np.isfinite(rr)] = 0
    ls = r_cumsum(_libm.log1p(np.maximum(rr, -0.999999)))
    pos = obs["pos"]
    so = ls[pos] - ls[pos[0]]
    po = obs["logp"] - obs["logp"][0]
    m = len(so)
    d_obs = np.asarray(dates, dtype=np.float64)[win][pos]
    yrs = float(d_obs[m - 1] - d_obs[0]) / 365.25
    ret_s = _libm.expm1(np.diff(so))      # seit 1.6.2 expm1 (P1)
    ret_p = _libm.expm1(np.diff(po))
    diffs = ret_s - ret_p
    per_year = (m - 1) / yrs if yrs > 0 else 252
    rel = 0 - _libm.expm1(so - po)        # 1 - sim/real (seit 1.6.2 genauer; 0 - : +0 wie bisher)
    out = RList()
    out["n_obs"] = m
    out["years"] = yrs
    out["start"] = _as_dates([d_obs[0]])
    out["end"] = _as_dates([d_obs[m - 1]])
    out["tracking_error"] = r_sd(diffs) * math.sqrt(per_year) * 100
    out["tracking_difference"] = ((_libm.expm1(so[m - 1] / yrs) - _libm.expm1(po[m - 1] / yrs)) * 100) if yrs > 0 else _NAN
    out["cagr_sim"] = _libm.expm1(so[m - 1] / yrs) * 100 if yrs > 0 else _NAN
    out["cagr_product"] = _libm.expm1(po[m - 1] / yrs) * 100 if yrs > 0 else _NAN
    out["final_deviation"] = _libm.expm1(so[m - 1] - po[m - 1]) * 100
    out["max_abs_deviation"] = float(np.max(np.abs(rel))) * 100
    out["rmse_level"] = math.sqrt(r_mean(_sq(so - po))) * 100
    c = _cor(ret_s, ret_p) if len(diffs) > 2 else _NAN
    out["correlation"] = c
    out["r_squared"] = c * c if len(diffs) > 2 else _NAN
    out["deviation"] = pd.DataFrame({"date": _as_dates(d_obs), "deviation": rel})
    return out


# ── Statistik-Interna (aus simlev._r.stats) ────────────────────────────────

def _optimize(f, lower, upper, tol):
    from ._r import stats as _st
    o = _st.optimize(f, lower=lower, upper=upper, tol=tol)
    return float(o["minimum"]), float(o["objective"])


def _optim_lbfgsb(par, fn, lower, upper):
    """``.sl_optim(..., method = "L-BFGS-B")`` (projizierter BFGS der C-Bibliothek slc)."""
    o = _lib.optim(np.asarray(par, dtype=np.float64), fn, method="L-BFGS-B", lower=lower, upper=upper)
    return np.asarray(o["par"], dtype=np.float64), float(o["value"]), int(o["convergence"])


def _lm_fit_coef(X, y):
    """``.sl_lsfit(cbind(1, x), y)$coefficients`` mit den Namen x1, x2 (wie lm.fit)."""
    f = _lib.lsfit(X, y)
    return pd.Series(np.asarray(f["coefficients"], dtype=np.float64), index=["x%d" % (k + 1) for k in range(X.shape[1])])


def _smooth_spline(x, y):
    """``.sl_smspline_fit(x, y)``: Glättungsspline (Reinsch 1967, GCV)."""
    return RList(**_lib.smspline_fit(x, y))


def _spline_predict(fit, x):
    """``.sl_smspline_predict(fit, x)``; außerhalb der Knoten lineare Fortsetzung."""
    return np.asarray(_lib.smspline_predict(fit, x), dtype=np.float64)


def _modify_list(base, val):
    """``utils::modifyList`` für flache Listen (``None`` entfernt Einträge)."""
    out = dict(base)
    for k, v in (val or {}).items():
        if v is None:
            out.pop(k, None)
        else:
            out[k] = v
    return out


# ═══════════════════════════════════════════════════════════════════════════
# Öffentliche Funktionen
# ═══════════════════════════════════════════════════════════════════════════

_BOUNDS0 = {"drag": [-10.0, 10.0], "spread": [-5.0, 10.0], "beta": [0.5, 1.5]}


def _default_grid():
    # seq(-3, 3, by = 0.005): from + (0:n) * by
    n = int((3 - (-3)) / 0.005 + 1e-10)
    return np.minimum(-3 + np.arange(n + 1) * 0.005, 3.0)


class SimLevBackcastFit(RList):
    """Ergebnis von :func:`backcast_fit` (R-Klasse ``SimLevBackcastFit``)."""

    r_class = ("SimLevBackcastFit",)

    def format(self) -> str:
        return _format_fit(self)

    def summary(self):
        return summary_SimLevBackcastFit(self)

# --- Eingabeprüfung Backcast (seit 1.6.4, K42 E4, B-017, B-087; Hilfen in _pruefen.py und dependence.py) -------

def _bc_check_series(x, data, fn, arg):
    """Angabe einer Reihe (ter, rate, fx) vor ``_resolve_series`` (R ``.bc_check_series``): Zahl(en) endlich,
    Spaltenname einer Zahlenspalte mit endlichen Werten oder NA, Tabelle (date, Wert) mit endlichen Zahlen; Kategorie,
    Wahrheitswerte, Listen aus Text und Matrizen sind ein Fehler."""
    from ._pruefen import chk_is_factor
    from .dependence import _e4_numcol, _e4_numscalar, _e4_isna
    if x is None:
        return x
    if chk_is_factor(x):
        chk_stop("faktor", fn, arg)
    if isinstance(x, pd.DataFrame):
        if x.shape[1] >= 2:
            nm = [str(c) for c in x.columns]
            dcol = "date" if "date" in nm else nm[0]
            vcol = [k for k in nm if k != dcol][0]
            if chk_is_factor(x[dcol]):
                chk_stop("spalte_faktor", fn, dcol)
            _e4_numcol(x, vcol, fn)
            # seit 1.6.5 (CR2-K-4): Tabelle ohne Zeile wie fehlende Werte abgelehnt
            if len(x) == 0 or not np.isfinite(np.asarray(x[vcol], dtype=np.float64)).all():
                chk_stop("e3.werte", fn, arg)
        return x
    if isinstance(x, (list, tuple, np.ndarray)) and len(x) == 1 and isinstance(list(np.ravel(np.asarray(x, dtype=object)))[0], str):
        x = str(list(np.ravel(np.asarray(x, dtype=object)))[0])
    if isinstance(x, str):
        if x == "":
            chk_stop("e4.reihe", fn, arg)
        if x in _names(data):
            _e4_numcol(data, x, fn)
            v = np.asarray(_as_numeric(_col(data, x)), dtype=np.float64)
            if np.isinf(v).any():
                chk_stop("e1.spalte_endlich", fn, x)
            # seit 1.6.5 (CR2-H-4): Spalte ohne Wert Fehler, späterer Beginn Hinweis (R .bc_check_series)
            ok = np.flatnonzero(~np.isnan(v))
            if v.size and not ok.size:
                chk_stop("c.bc_spalte_leer", fn, x, arg)
            if ok.size and ok[0] > 0:
                from ._util import _message
                _message(chk_msg("c.bc_spalte_spaet", fn, x, arg, int(ok[0])))
        return x
    if isinstance(x, Mapping):
        vals = list(x.values())
    elif isinstance(x, pd.Series):
        if not (pd.api.types.is_numeric_dtype(x.dtype) and not pd.api.types.is_bool_dtype(x.dtype)):
            chk_stop("e4.reihe", fn, arg)
        vals = list(x.to_numpy(dtype=np.float64))
    elif isinstance(x, np.ndarray):
        if x.ndim > 1:
            chk_stop("e4.reihe", fn, arg)
        vals = list(x.ravel())
    elif isinstance(x, (list, tuple)):
        vals = list(x)
    else:
        vals = [x]
    if not vals or not all(_e4_numscalar(v) or _e4_isna(v) for v in vals):
        chk_stop("e4.reihe", fn, arg)
    if not all(_e4_numscalar(v) and math.isfinite(float(v)) for v in vals):
        chk_stop("e3.werte", fn, arg)
    return x


def _bc_check_args(fn, data, product, index, ter, leverage, rate, fx, rate_lag, ter_basis, rate_basis):
    """Gemeinsame Modellangaben von ``backcast_fit()`` und ``backcast()`` ohne Fit (R ``.bc_check_args``)."""
    from ._pruefen import chk_col_nofactor, chk_df, chk_int1, chk_is_factor, chk_name1, chk_num1
    from .dependence import _e4_numcol
    chk_df(data, fn, "data")                                   # Entscheidung 6, B-057
    chk_name1(product, fn, "product")
    chk_name1(index, fn, "index")
    nm = [str(c) for c in data.columns]
    if "date" in nm:
        chk_col_nofactor(data, "date", fn)                     # Entscheidung 15
    for col in (product, index):
        if col in nm:
            _e4_numcol(data, col, fn)
    lv = leverage
    if (chk_is_factor(lv) or not _is_numeric_value(lv) or np.size(lv) != 1
            or not math.isfinite(float(np.ravel(lv)[0])) or float(np.ravel(lv)[0]) == 0):
        chk_stop("c.m_bc_check_args")   # seit 1.6.4 auch NA und Inf
    _bc_check_series(ter, data, fn, "ter")
    _bc_check_series(rate, data, fn, "rate")
    _bc_check_series(fx, data, fn, "fx")
    from .bonds import _step_start_warn                        # seit 1.6.5 (CR2-V3-4 Punkt 4)
    _step_start_warn(ter, data, fn, "ter")
    _step_start_warn(rate, data, fn, "rate")
    _step_start_warn(fx, data, fn, "fx")
    chk_int1(rate_lag, fn, "rate_lag", lo=0, hi=max(0, len(data) - 1))
    chk_num1(ter_basis, fn, "ter_basis", lo=0, lo_open=True)
    chk_num1(rate_basis, fn, "rate_basis", lo=0, lo_open=True)
    return True


def _bc_check_lag(lag, data, fn, auto_ok=True):
    """lag: ``"auto"`` (nur mit ``auto_ok``) oder ganze Zahl mit ``|lag| < nrow(data)`` (R ``.bc_check_lag``)."""
    from ._pruefen import chk_scalar
    from .dependence import _e4_numscalar
    key = "e4.lag" if auto_ok else "e4.lag_ohne_fit"
    lag = chk_scalar(lag)
    if auto_ok and isinstance(lag, str) and lag == "auto":
        return lag
    if not (_e4_numscalar(lag) and math.isfinite(float(lag)) and float(lag) == math.trunc(float(lag))
            and abs(float(lag)) < len(data)):
        chk_stop(key, fn)
    return lag


def _bc_check_par(p, fn, arg, null_ok=False):
    """drag, spread, beta als benannte Liste (dict) einzelner endlicher Zahlen (fixed, params; R ``.bc_check_par``)."""
    from ._pruefen import chk_is_factor, chk_scalar
    from .dependence import _e4_numscalar
    if p is None and null_ok:
        return p
    ok = isinstance(p, Mapping) and all(k in ("drag", "spread", "beta") for k in p)
    if ok:
        for v in p.values():
            v = v if chk_is_factor(v) else chk_scalar(v)
            if not (_e4_numscalar(v) and math.isfinite(float(v))):
                ok = False
    if not ok:
        chk_stop("e4.parameter", fn, arg)
    return p


def _chk_scalar1(x):
    from ._pruefen import chk_scalar
    return chk_scalar(x)


def _as_char_vec(x):
    if x is None:
        return []
    if isinstance(x, str):
        return [x]
    return [str(v) for v in np.ravel(np.asarray(x, dtype=object))]


def backcast_fit(data, product, index, *, ter=0, leverage=1, rate=None, fx=None,
                 model=("structural", "linear", "spline"), fit="drag", fixed=None,
                 objective=("level", "return", "hybrid"), loss=("rmse", "mse", "mae", "median", "max"),
                 horizon=1, hybrid_weight=0.5, lag=0, rate_lag=0, start=None, end=None,
                 method=("optimize", "grid"), grid=None, bounds=None, ter_basis=365, rate_basis=360,
                 accrual=("linear", "geometric"), index_fill=("locf", "linear", "stine"), validate=True):
    """Backcast-Modell an ein Produkt anpassen.

    Passt das Rückrechnungsmodell eines ETF/ETP (auch gehebelt oder invers) auf dem Zeitraum an, in dem sowohl das
    Produkt als auch sein Basisindex vorliegen. Die freien Parameter werden so gewählt, dass die Abweichung
    zwischen simuliertem und echtem Produkt minimal wird (täglich, kumuliert oder beides). Eingabe ist ein
    DataFrame mit Datum, Produktkursen (vor der Auflegung ``NA``) und Indexniveaus; das Ergebnis wird mit
    ``backcast()`` in eine verlängerte Kursreihe umgerechnet.

    Args:
        data: DataFrame mit Spalte ``date`` (Date oder umwandelbar, streng aufsteigend, ohne Duplikate) sowie den
            Spalten für Produkt und Basisindex. Typisch ein Kalendertagsraster (wie in den Projekt-Skripten) oder
            Handelstage; Lücken im Produkt (Feiertage, Börsenschluss) sind erlaubt.
        product: Spaltenname der Produkt-Kursreihe (NAV oder Börsenkurs; Niveaus, ``NA`` vor der Auflegung; Werte
            <= 0 gelten als fehlend).
        index: Spaltenname der Basisindex-Reihe (Niveau > 0, nicht Rendite; Lücken werden nach ``index_fill``
            gefüllt).
        ter: Laufende Kosten in Prozent p. a. (0.5 = 0,5 Prozent; Standard 0): Skalar, Vektor der Länge
            ``nrow(data)``, Spaltenname, DataFrame(date, ter) (Stufenfunktion, gültig ab Datum) oder benannter
            Vektor mit Datumsnamen, z. B. ``{"2010-02-24": 0.35, "2023-10-10": 0.50}``.
            Seit 1.6.5 (für ``ter``, ``rate``, ``fx`` gleich): eine Spalte ohne einen Wert ist ein Fehler, führende fehlende
            Werte erhalten den ersten Wert der Spalte (mit Hinweis), eine Tabelle ohne Zeile ist ein Fehler, eine
            Stufentabelle, die nach dem ersten Datentag beginnt, gibt eine Warnung (davor gilt ihr erster Wert).
        leverage: Hebel L des Produkts relativ zum Index als Zahl ungleich 0 (Standard 1; z. B. 2, -1, -2). Ist
            der Index bereits ein Hebelindex (z. B. MSCI USA Leveraged 2x Daily), ist ``leverage = 1`` zu setzen.
        rate: Finanzierungszins in Prozent p. a. (Tagesgeld, z. B. ESTR, EONIA, SOFR, EFFR) in denselben Formen
            wie ``ter``; ``None`` (Standard) = 0. Wirkt nur für ``leverage != 1`` (Faktor 1 - L).
        fx: Optional (Standard ``None`` = keine Umrechnung): Umrechnungsfaktor Indexwährung -> Produktwährung in
            denselben Formen wie ``ter`` (z. B. Spaltenname). Der Index wird mit ``fx`` multipliziert.
        model: ``"structural"`` (Standard, Hebel-/Kostenmodell oben), ``"linear"`` (Regression Produktrendite ~
            Indexrendite, Stambaugh- Backfill) oder ``"spline"`` (kubischer Glättungsspline nach Reinsch mit
            Knoten an allen Stützstellen und GCV-Wahl der Glättung, Ersatz für das GAM aus '01 Base Indices'; die
            Kurve weicht leicht von ``smooth.spline()`` ab, das bei vielen Punkten Knoten auswählt). Die
            Regressionsmodelle werden auf Renditen direkt aufeinanderfolgender Produktbeobachtungen geschätzt und
            eignen sich für Proxy-Rückrechnungen (z. B. MSCI USA aus S&P 500).
        fit: Zeichenvektor der zu schätzenden Parameter (Standard ``"drag"``): Teilmenge von ``"drag"``
            (Restabweichung in Prozent p. a.), ``"spread"`` (Spread auf den finanzierten Anteil in Prozent p. a.,
            nur für L != 1, sonst mit Warnung ignoriert) und ``"beta"`` (effektiver Hebel-Multiplikator, Faktor;
            nur Strukturmodell). ``character(0)`` schätzt nichts (reine Kostenrechnung).
            ``drag`` und ``spread`` wirken beide je Kalendertag und sind gemeinsam nicht bestimmbar: stehen beide in ``fit``,
            wird seit 1.6.5 mit Warnung nur ``drag`` geschätzt (``spread`` bleibt beim festen Wert aus ``fixed``). Liegt ein
            Schätzwert an der Grenze von ``bounds`` bzw. auf dem ersten oder letzten Gitterpunkt, warnt die Funktion seit
            1.6.5; das Ergebnis enthält seit 1.6.5 ``convergence`` (0 = konvergiert).
        fixed: Benannte Liste fester Parameterwerte, z. B. ``{"spread": 0.4}``; nicht genannte Parameter: drag =
            0, spread = 0 (Prozent p. a.), beta = 1. Die Werte dienen auch als Startwerte der Optimierung.
        objective: ``"level"`` (Standard; kumulierte Pfadabweichung der Log-Niveaus, wie im Skript '02 Funds
            Data'; bestimmt die Tracking Difference), ``"return"`` (Log-Renditeabweichungen über ``horizon``
            Beobachtungen; Tracking Error) oder ``"hybrid"`` (gewichtete Kombination beider RMS-Fehler).
        loss: Fehlermaß für "level" und "return": "rmse" (Standard), "mse", "mae", "median" (Median der Beträge)
            oder "max". Bei "hybrid" ohne Wirkung (immer RMS).
        horizon: Renditehorizont in Produktbeobachtungen für "return"/"hybrid" (ganze Zahl >= 1, Standard 1).
            Werte > 1 (z. B. 5) dämpfen asynchrone Schlusskurse (Xetra vs. US-Index).
            Seit 1.6.4 kleiner als die Zahl der Produktbeobachtungen im Fit-Fenster.
        hybrid_weight: Gewicht des Renditeterms bei "hybrid" als Anteil (0..1, Standard 0.5); der Niveauterm
            erhält 1 - ``hybrid_weight``.
        lag: Verzögerung des Index gegenüber dem Produkt in Zeilen (ganzzahlig, Standard 0; bei k > 0 wird die
            Produktrendite in Zeile t mit der Indexrendite aus Zeile t - k modelliert) oder ``"auto"`` (Lag aus
            -2..2 mit der höchsten Korrelation, bei negativem Hebel der niedrigsten).
            Seit 1.6.4 mit Betrag kleiner als die Zeilenzahl von data.
            Ist bei "auto" keine der fünf Korrelationen bestimmbar (jede braucht mindestens 30 gemeinsame Renditen, keine konstante Reihe), meldet die Funktion das seit 1.6.4 (lag dann angeben).
        rate_lag: Verzögerung des Zinssatzes in Zeilen (Standard 0 = Satz des Tages t; k > 0 = Satz aus Zeile t -
            k).
        start, end: Optionales Fit-Fenster (Datum oder Zeichenkette "JJJJ-MM-TT"); ``None`` (Standard) = gesamte
            Überlappung. Mindestens 20 gemeinsame Beobachtungen.
        method: ``"optimize"`` (Standard; ein Parameter mit ``stats::optimize()`` (Brent), mehrere mit
            projiziertem BFGS (C-Bibliothek von SimLev) innerhalb von ``bounds``) oder ``"grid"`` (Gittersuche für
            genau einen Parameter, wie im Skript).
        grid: Gitterwerte für ``method = "grid"`` in der Einheit des Parameters (drag, spread: Prozent p. a.;
            beta: Faktor); Standard ``seq(-3, 3, by = 0.005)``.
        bounds: Benannte Liste von Suchintervallen ``[unten, oben]`` je Parameter für ``method = "optimize"``, in
            der Einheit des Parameters; Standard ``list(drag = [-10, 10], spread = [-5, 10], beta = [0.5, 1.5]``.
            Eine eigene Liste ergänzt die Standardliste: Nicht genannte Parameter behalten ihr Standardintervall
            (je Eintrag ``[unten, oben]`` mit unten < oben).
        ter_basis, rate_basis: Tagesbasis für TER (Standard 365) und für Zins und Spread (Standard 360, Act/360).
            Seit 1.6.4 Zahlen > 0.
        accrual: Abgrenzung der TER: ``"linear"`` (Standard, TER * T / 365, Fondsbuchhaltung) oder ``"geometric"``
            ((1 + TER)^(T/365) - 1, wie in den Skripten).
        index_fill: Füllmethode für Indexlücken: "locf" (Standard), "linear" oder "stine" (Stineman-Interpolation
            nach Stineman 1980, skaliert wie stinepack; eigene Umsetzung in der C-Bibliothek von SimLev). Führende
            Lücken bleiben ``NA``.
        validate: Logisch (Standard ``True``): Out-of-Sample-Prüfung (Fit auf der jüngeren Hälfte der
            Produktbeobachtungen, Test auf der älteren, also in Backcast-Richtung); erst ab 80 Beobachtungen.

    Returns:
        Objekt der Klasse ``SimLevBackcastFit``, eine Liste mit u. a.

        - params: Liste ``drag``, ``spread`` (Prozent p. a.) und ``beta`` (Faktor).
        - fitted, model, objective, loss, loss_value, method, horizon, lag: Fit-Einstellungen, Wert der
          Zielfunktion und verwendeter Lag (Zeilen).
        - diagnostics, diagnostics_unfitted: Kennzahlen Simulation vs. Produkt mit bzw. ohne gefittete Parameter:
          ``n_obs``, ``years``, ``start``, ``end``, ``tracking_error`` (Prozent p. a.), ``tracking_difference``
          (Prozentpunkte p. a.), ``cagr_sim``, ``cagr_product``, ``final_deviation``, ``max_abs_deviation``
          (jeweils Prozent), ``rmse_level`` (RMSE der Log-Niveaus x 100), ``correlation``, ``r_squared`` und
          ``deviation`` (DataFrame date, deviation = 1 - Sim/Produkt als Anteil).
        - grid, grid_metrics: Bei ``method = "grid"``: DataFrame (value, loss) und bestes Gitterelement je
          Fehlermetrik, sonst ``None``.
        - validation: Out-of-Sample-Ergebnis (Zeiträume ``train``, ``test``, Parameter ``par``, Testkennzahlen in
          Prozent) oder ``None``.
        - regression: Regressionsfit (nur "linear"/"spline"): ``coef`` (Achsenabschnitt, Steigung) bzw. ``fit``
          (Splineobjekt der C-Bibliothek mit ``x``, ``y``, ``gam``, ``lambda``, ``df``, ``gcv``; kein
          ``smooth.spline``-Objekt).
        - inception, window: Erstes Produktdatum und Fit-Fenster.
        - drag_per_day: Drag in Prozent je Kalendertag.
        - call_args: Daten und Modellangaben für ``backcast()``.

    Details:
        Strukturmodell (``model = "structural"``) je Zeile t mit Kalendertagen T_t seit der Vorzeile und
        Indexrendite x_t: r_t = β L x_t + (1 - L) i_t T_t / B_r - TER_t T_t / B_T
        - s m(L) T_t / B_r - drag T_t / 365 mit m(L) = max(L-1, 0) + max(-L, 0), B_r = ``rate_basis``, B_T =
          ``ter_basis``; i, TER, s und drag gehen als Prozent p. a. / 100 ein. Bei den Regressionsmodellen ersetzt
          die geschätzte Regression die ersten drei Terme (``ter`` und ``rate`` gehen dann nicht ein); ``spread``
          und ``drag`` werden zusätzlich abgezogen.

    Hinweise (Python):
        Passt das Rückrechnungsmodell eines ETF/ETP auf dem Zeitraum an, in dem
        Produkt und Basisindex vorliegen (Argumente wie in R, siehe
        ``r/man/backcast_fit.Rd``). ``fixed``: ``dict`` fester Parameter
        (Standard leer); ``grid``: Standard ``seq(-3, 3, by = 0.005)``;
        ``bounds``: ``dict`` mit Suchintervallen (ergänzt die Standardliste).

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 3000
        d = pd.DataFrame({"date": pd.date_range("2010-01-01", periods=n)})
        d["idx"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        r = np.r_[0, np.diff(d["idx"]) / d["idx"].to_numpy()[:-1]]
        d["etf"] = 50 * np.cumprod(1 + 2 * r - 2 / 100 / 360 - 0.6 / 100 / 365)
        d["rate"] = 2.0
        d.loc[:1499, "etf"] = np.nan                   # Produkt erst ab Tag 1501
        fit = simlev.backcast_fit(d, "etf", "idx", ter=0.5, leverage=2, rate="rate")
        print(fit["params"]["drag"])                   # etwa 0.1 Prozent p. a.
    """
    model = _match_arg(model, ("structural", "linear", "spline"))
    objective = _match_arg(objective, ("level", "return", "hybrid"))
    loss = _match_arg(loss, ("rmse", "mse", "mae", "median", "max"))
    method = _match_arg(method, ("optimize", "grid"))
    accrual = _match_arg(accrual, ("linear", "geometric"))
    index_fill = _match_arg(index_fill, ("locf", "linear", "stine"))
    from ._pruefen import chk_bool1, chk_date1, chk_is_factor, chk_prob
    from .dependence import _e4_count, _e4_vec
    fn = "backcast_fit"                                        # seit 1.6.4 vor der Rechnung (K42 E4, B-017)
    _bc_check_args(fn, data, product, index, ter, leverage, rate, fx, rate_lag, ter_basis, rate_basis)
    leverage, ter_basis, rate_basis = _chk_scalar1(leverage), _chk_scalar1(ter_basis), _chk_scalar1(rate_basis)
    if chk_is_factor(fit):
        chk_stop("faktor", fn, "fit")
    _bc_check_par({} if fixed is None else fixed, fn, "fixed")   # B-087
    horizon = _e4_count(horizon, fn, "horizon")                # B-011, B-017
    hybrid_weight = chk_prob(hybrid_weight, fn, "hybrid_weight")
    lag = _bc_check_lag(lag, data, fn)
    rate_lag = _chk_scalar1(rate_lag)
    if start is not None:
        start = chk_date1(start, fn, "start")                  # B-011 (Entscheidung 7: keine Zahl)
    if end is not None:
        end = chk_date1(end, fn, "end")
    if grid is not None:
        try:
            _e4_vec(grid, fn, "grid")
            ga = np.atleast_1d(np.asarray(grid.to_numpy() if isinstance(grid, pd.Series) else grid, dtype=np.float64))
            gok = bool(np.isfinite(ga).all())
        except (ValueError, TypeError):
            gok = False
        if not gok:
            chk_stop("e2.zahlen_endlich", fn, "grid")          # B-017
    validate = chk_bool1(validate, fn, "validate")            # B-051
    fixed = {k: (v if not isinstance(v, (list, tuple, np.ndarray, pd.Series)) else _chk_scalar1(v))
             for k, v in dict(fixed or {}).items()}
    grid = _default_grid() if grid is None else np.atleast_1d(np.asarray(grid, dtype=np.float64))
    fit = _r_unique(_as_char_vec(fit))
    if len(fit) and not all(f in ("drag", "spread", "beta") for f in fit):
        chk_stop("c.m_backcast_fit")
    if bounds is None:
        bounds = dict(_BOUNDS0)
    if not isinstance(bounds, Mapping) or (len(bounds) and not all(k in ("drag", "spread", "beta") for k in bounds)):
        chk_stop("c.m_backcast_fit_2")
    bounds = _modify_list(_BOUNDS0, bounds)
    for k, b in bounds.items():
        ok = _is_numeric_value(b) and np.size(b) == 2 and not chk_is_factor(b)
        if ok:
            bb = np.asarray(b, dtype=np.float64).ravel()
            # seit 1.6.4 auch die Breite endlich (B-005: c(-1e308, 1e308) ergab eine endlose Brent-Suche)
            ok = bool(np.isfinite(bb).all()) and bb[0] < bb[1] and math.isfinite(float(bb[1]) - float(bb[0]))
        if not ok:                                             # seit 1.6.4 ohne Wert, endlich
            chk_stop("c.m_backcast_fit_3", k)
        bounds[k] = [float(bb[0]), float(bb[1])]
    if model != "structural" and "beta" in fit:
        warnings.warn(chk_msg("c.m_backcast_fit_4"))
        fit = [f for f in fit if f != "beta"]
    if leverage == 1 and "spread" in fit:
        warnings.warn(chk_msg("c.m_backcast_fit_5"))
        fit = [f for f in fit if f != "spread"]
    elif "drag" in fit and "spread" in fit:
        # seit 1.6.5 (K10, CR2-A-4): gemeinsam nicht bestimmbar, nur drag (R backcast_fit)
        warnings.warn(chk_msg("c.bc_kollinear", fn))
        fit = [f for f in fit if f != "spread"]

    lag_auto = isinstance(lag, str) and lag == "auto"
    prep = _bc_prepare(data, product, index, ter, leverage, rate, fx, int(rate_lag), ter_basis, rate_basis,
                       accrual, index_fill, 0 if lag_auto else int(lag))
    if lag_auto:
        with np.errstate(invalid="ignore", divide="ignore"):
            pr = np.concatenate([[_NAN], prep.prod[1:] / prep.prod[:-1] - 1])
        cand = [-2, -1, 0, 1, 2]
        cors = []
        for k in cand:
            xs = _shift(prep.x, k)
            ok = np.isfinite(xs) & np.isfinite(pr)
            cors.append(_NAN if ok.sum() < 30 else _cor(xs[ok], pr[ok]))
        sg = 1.0 if prep.leverage > 0 else -1.0
        j = _which_max([sg * c for c in cors])
        if j is None:   # keine Korrelation bestimmbar: seit 1.6.4 Meldung wie R und Julia (Entscheidung 145)
            chk_stop("ut3.lag_auto", "backcast_fit")
        lag = cand[j]
        prep = _bc_prepare(data, product, index, ter, leverage, rate, fx, int(rate_lag), ter_basis, rate_basis,
                           accrual, index_fill, int(lag))

    has = ~np.isnan(prep.prod) & ~np.isnan(prep.idx)
    if start is not None:
        has = has & (prep.dates >= _as_date_any(start)[0])
    if end is not None:
        has = has & (prep.dates <= _as_date_any(end)[0])
    if has.sum() < 20:
        chk_stop("c.m_backcast_fit_6")
    hw = np.flatnonzero(has)
    w0, w1 = int(hw.min()), int(hw.max())
    win = np.arange(w0, w1 + 1)
    inception = _as_dates([prep.dates[np.flatnonzero(~np.isnan(prep.prod)).min()]])

    def make_obs(rows):
        pos = np.flatnonzero(has[rows])
        return {"pos": pos, "logp": _libm.log(prep.prod[rows][pos])}

    obs = make_obs(win)
    # seit 1.6.4: ohne Renditepaare wäre die Zielfunktion leer (B-017; bis 1.6.3 Ergebnis an der Suchgrenze)
    if objective != "level" and horizon >= len(obs["pos"]):
        chk_stop("e4.horizont", fn, len(obs["pos"]))

    def fit_reg(rows):
        if model == "structural":
            return None
        o = np.flatnonzero(has[rows]) + rows[0]
        o = o[o > 0]
        with np.errstate(invalid="ignore", divide="ignore"):
            y = prep.prod[o] / prep.prod[o - 1] - 1
        xx = prep.x[o]
        ok = np.isfinite(y) & np.isfinite(xx) & ~np.isnan(prep.prod[o - 1])
        if ok.sum() < 20:
            chk_stop("c.m_fit_reg")
        if model == "linear":
            X = np.column_stack([np.ones(int(ok.sum())), xx[ok]])
            return RList(coef=_lm_fit_coef(X, y[ok]))
        return RList(fit=_smooth_spline(xx[ok], y[ok]))

    reg = fit_reg(win)
    par0 = _modify_list({"drag": 0.0, "spread": 0.0, "beta": 1.0}, fixed)

    def rows_of(rows, rg):
        """Fenster rows (seit 1.6.4, B-068, B-106; R ``make_obj``): Einheiten und Basis einmal je Fit auf rows
        (elementweise wie ``_bc_model_returns(prep, p, model, rg)[rows]``), die Basis ``None``, wenn sie vom gesuchten
        beta abhängt (Strukturmodell; dann je Auswertung nur auf rows)."""
        rws = np.asarray(rows)

        def cut(k):
            return np.broadcast_to(np.asarray(prep[k], dtype=np.float64), (prep.n,))[rws]
        w = {k: cut(k) for k in ("x", "fin", "ter_cost", "sp_unit", "dr_unit")}
        w["base"] = None if (model == "structural" and "beta" in fit) else \
            np.broadcast_to(np.asarray(_bc_base(prep, par0, model, rg), dtype=np.float64), (prep.n,))[rws]
        return w

    def returns_on(w, p):
        b = w["base"] if w["base"] is not None else p["beta"] * prep.leverage * w["x"] + w["fin"] - w["ter_cost"]
        return b - p["spread"] * w["sp_unit"] - p["drag"] * w["dr_unit"]

    def make_obj(rows, ob, rg):
        w = rows_of(rows, rg)
        ix = np.arange(len(rows))

        def obj(theta):
            p = dict(par0)
            for k, t in zip(fit, np.atleast_1d(np.asarray(theta, dtype=np.float64))):
                p[k] = float(t)
            return _bc_objective(returns_on(w, p), ix, ob, objective, horizon, loss, hybrid_weight)
        return obj

    def run_fit(rows, ob, rg, metrics=True):
        # metrics=False (Validierung, seit 1.6.4, B-070): im Gitter nur die Zielwerte, ohne Fehlermatrix, Metrik- und
        # Gittertabelle (genutzt wird dort nur par)
        if not len(fit):
            return {"par": dict(par0), "value": make_obj(rows, ob, rg)(np.empty(0)), "grid": None}
        if method == "grid":
            if len(fit) != 1:
                chk_stop("c.m_run_fit")
            # Modellrenditen je Gitterpunkt einmal für Zielwert und Fehlermatrix (seit 1.6.3; bis 1.6.2 zweimal),
            # nur im Fenster rows (elementweise dieselben Ausdrücke wie auf allen Zeilen); seit 1.6.4 die Basis vorab
            # in allen Modellen (B-068) und je Punkt ein _bc_errors (B-069: "level" bei objective = "level",
            # horizon bleibt dort unausgewertet, sonst "hybrid"; Zielwert wie _bc_objective)
            w = rows_of(rows, rg)
            ix = np.arange(len(rows))
            eo = "level" if objective == "level" else "hybrid"
            vl, cols = [], []
            for g in grid:
                p = dict(par0)
                p[fit[0]] = float(g)
                e = _bc_errors(returns_on(w, p), ix, ob, eo, horizon)
                if objective == "level":
                    vl.append(_bc_loss(e, loss))
                    el = e
                elif objective == "return":
                    vl.append(_bc_loss(e["ret"], loss))
                    el = e["level"]
                else:
                    vl.append(math.sqrt(hybrid_weight * r_mean(_sq(e["ret"])) + (1 - hybrid_weight) * r_mean(_sq(e["level"]))))
                    el = e["level"]
                if metrics:
                    cols.append(0 - _libm.expm1(el))
            vals = np.array(vl, dtype=np.float64)
            best = float(grid[_which_min(list(vals), -1)])
            p = dict(par0)
            p[fit[0]] = best
            if not metrics:
                return {"par": p, "value": _r_min(vals), "grid": None}
            return {"par": p, "value": _r_min(vals),
                    "grid": pd.DataFrame({"value": grid, "loss": vals}),
                    "metrics": _bc_metric_table(cols, grid, len(ob["pos"]))}
        obj = make_obj(rows, ob, rg)
        if len(fit) == 1:
            b = bounds[fit[0]]
            mn, ov = _optimize(lambda t: obj(t), b[0], b[1], 1e-8)
            p = dict(par0)
            p[fit[0]] = mn
            return {"par": p, "value": ov, "grid": None}
        lo = np.array([bounds[k][0] for k in fit], dtype=np.float64)
        hi = np.array([bounds[k][1] for k in fit], dtype=np.float64)
        # glatte Zielfunktion (rmse, mse, hybrid) mit analytischem Gradienten ganz in C (wie .sl_backcast_fit
        # in R); mae, median, max wie bis 1.1.0 über .sl_optim mit numerischem Gradienten
        if objective == "hybrid" or loss in ("rmse", "mse"):
            o = _lib.backcast_fit(_bc_cprob(prep, model, rg, rows, ob, objective, loss, horizon, hybrid_weight),
                                  np.array([par0["drag"], par0["spread"], par0["beta"]], dtype=np.float64),
                                  np.array([("drag", "spread", "beta").index(k) + 1 for k in fit], dtype=np.int32), lo, hi)
            opar, oval, conv = o["par"], float(o["value"]), int(o["convergence"])
        else:
            st = np.array([par0[k] for k in fit], dtype=np.float64)
            opar, oval, conv = _optim_lbfgsb(st, lambda t: obj(t), lo, hi)
        p = dict(par0)
        for k, t in zip(fit, opar):
            p[k] = float(t)
        return {"par": p, "value": oval, "grid": None, "convergence": conv}

    res = run_fit(win, obs, reg)
    # seit 1.6.5 (CR2-A-5, K22): Schätzwert an der Suchgrenze bzw. am Gitterrand und fehlende Konvergenz melden
    from ._pruefen import chk_msg as _cm
    for k in fit:
        v = float(res["par"][k])
        if method == "grid":
            ga = np.asarray(grid, dtype=np.float64)
            edge = v == float(np.min(ga)) or v == float(np.max(ga))
        else:
            b = bounds[k]
            edge = v <= b[0] + 1e-6 * (b[1] - b[0]) or v >= b[1] - 1e-6 * (b[1] - b[0])
        if edge:
            from ._r import fmt as _fmtm
            warnings.warn(_cm("c.bc_rand", fn, k, _fmtm.format(v, digits=6)))
    if res.get("convergence") is not None and res["convergence"] != 0:
        warnings.warn(_cm("c.bc_konvergenz", fn, int(res["convergence"])))
    r_all = _bc_model_returns(prep, res["par"], model, reg)
    diag = _bc_diagnostics(r_all[win], np.arange(len(win)), obs, prep.dates[win])
    diag_naive = _bc_diagnostics(_bc_model_returns(prep, par0, model, reg)[win], np.arange(len(win)), obs,
                                 prep.dates[win])

    oos = None
    if validate and len(obs["pos"]) >= 80:
        cut_row = int(win[obs["pos"][len(obs["pos"]) // 2 - 1]])
        tr_rows = np.arange(cut_row, w1 + 1)
        te_rows = np.arange(w0, cut_row + 1)
        ob_tr = make_obs(tr_rows)
        ob_te = make_obs(te_rows)
        try:
            rg_tr = fit_reg(tr_rows)
        except ValueError:
            rg_tr = None
        if model == "structural" or rg_tr is not None:
            res_tr = run_fit(tr_rows, ob_tr, rg_tr, metrics=False)   # nur par (B-070)
            d_te = _bc_diagnostics(_bc_model_returns(prep, res_tr["par"], model, rg_tr)[te_rows],
                                   np.arange(len(te_rows)), ob_te, prep.dates[te_rows])
            d_te0 = _bc_diagnostics(_bc_model_returns(prep, par0, model, rg_tr)[te_rows],
                                    np.arange(len(te_rows)), ob_te, prep.dates[te_rows])
            oos = RList(train=_as_dates([prep.dates[tr_rows[0]], prep.dates[w1]]),
                        test=_as_dates([prep.dates[w0], prep.dates[cut_row]]),
                        par=RList(res_tr["par"]),
                        test_rmse_level=d_te["rmse_level"], test_tracking_difference=d_te["tracking_difference"],
                        test_tracking_error=d_te["tracking_error"],
                        naive_rmse_level=d_te0["rmse_level"],
                        naive_tracking_difference=d_te0["tracking_difference"])

    out = SimLevBackcastFit()
    out["params"] = RList(res["par"])
    out["fitted"] = list(fit)
    out["model"] = model
    out["objective"] = objective
    out["loss"] = loss
    out["loss_value"] = res["value"]
    out["method"] = method
    out["horizon"] = horizon
    out["lag"] = int(lag)
    out["diagnostics"] = diag
    out["diagnostics_unfitted"] = diag_naive
    out["grid"] = res.get("grid")
    out["grid_metrics"] = res.get("metrics")
    out["validation"] = oos
    out["convergence"] = int(res["convergence"]) if res.get("convergence") is not None else 0   # seit 1.6.5 (CR2-A-5)
    out["regression"] = reg
    out["inception"] = inception
    out["window"] = _as_dates([prep.dates[w0], prep.dates[w1]])
    out["drag_per_day"] = res["par"]["drag"] / 100 / 365 * 100
    out["call_args"] = RList(data=data, product=product, index=index, ter=ter, leverage=leverage, rate=rate,
                             fx=fx, rate_lag=int(rate_lag), ter_basis=ter_basis, rate_basis=rate_basis,
                             accrual=accrual, index_fill=index_fill)
    return out


class SimLevBackcast(pd.DataFrame):
    """Ergebnis von :func:`backcast` (R-Klasse ``c("SimLevBackcast", "data.frame")``).

    ``attrs``: ``fit``, ``params``, ``splice_date``.
    """

    r_class = ("SimLevBackcast", "data.frame")

    @property
    def _constructor(self):
        return pd.DataFrame

    def format(self, **kwargs) -> str:
        return _format_backcast(self, **kwargs)

    def __repr__(self) -> str:
        return self.format()

    __str__ = __repr__

def backcast(*, fit=None, data=None, params=None, splice="inception", fill=("locf", "linear", "stine", "model"),
             rebase=None, **kwargs):
    """Produkt-Kursreihe zurückrechnen und verketten.

    Rechnet ein Produkt mit den Parametern aus ``backcast_fit()`` (oder fest vorgegebenen Parametern) über die
    gesamte Indexhistorie und verkettet die Simulation renditebasiert (Chain-Linking) mit der echten Produktreihe
    ab Auflegung. Es entsteht kein Sprung am Verkettungstag; ab dem Verkettungstag stimmt ``value`` (ohne
    ``rebase``) an allen Beobachtungstagen mit den echten Kursen überein. Das Ergebnis kann z. B. nach Umbenennen
    von ``value`` als Kursspalte für ``simulation()`` dienen.

    Args:
        fit: Ein ``SimLevBackcastFit``-Objekt aus ``backcast_fit()``. Alternativ ``None`` (Standard), dann werden
            ``data``, ``product``, ``index`` und die Modellangaben über ``...`` übergeben und ``params`` direkt
            verwendet (nur Strukturmodell).
        data: Bei ``fit``: optional anderer Datensatz (z. B. längere Indexhistorie) mit denselben Spaltennamen;
            ``None`` (Standard) = Datensatz des Fits. Bei ``fit = None`` Pflicht (Format wie in
            ``backcast_fit()``).
        params: Optional Liste mit ``drag``, ``spread`` (Prozent p. a.) und/oder ``beta`` (Faktor). Überschreibt
            einzelne Parameter des Fits; ohne Fit gelten für fehlende Einträge drag = 0, spread = 0, beta = 1.
        splice: ``"inception"`` (Standard: echte Renditen ab dem ersten Produktkurs), ``"none"`` (reine
            Modellreihe) oder ein Datum: echte Renditen ab dem ersten Produktkurs an oder nach diesem Datum
            (Fehler, wenn danach kein Produktkurs vorliegt).
        fill: Füllmethode für Produktlücken nach der Verkettung: "locf" (Standard, wie die Engine), "linear",
            "stine" (Stineman, wie bei ``index_fill``) oder "model" (Lückentage mit Modellrenditen, Endpunkte aus
            echten Kursen; erhält die echten Kurse an allen Beobachtungstagen).
        rebase: ``None`` (Standard; Produkteinheiten, echte Kurse bleiben erhalten) oder Startwert der Reihe am
            ersten Indextag, z. B. 100 (``value`` und ``model`` werden skaliert, ``product`` nicht).
            Seit 1.6.4 eine Zahl > 0.
        **kwargs: Bei ``fit = None``: Argumente wie in ``backcast_fit()`` (``product``, ``index`` als Pflicht;
            ``ter`` (Standard 0), ``leverage`` (1), ``rate`` (``None`` = 0), ``fx``, ``rate_lag``, ``ter_basis``,
            ``rate_basis``, ``accrual``, ``index_fill``, ``lag``; ``model`` nur "structural").
            Seit 1.6.4 mit ``fit`` nicht erlaubt (die Angaben stammen aus dem Fit).

    Returns:
        DataFrame der Klasse ``["SimLevBackcast", "data.frame"]`` mit einer Zeile je Zeile von ``data``: ``date``,
        ``value`` (verkettete Reihe; ``NA`` vor dem ersten Indexwert), ``return`` (einfache Rendite von ``value``
        als Anteil), ``model`` (reine Modellreihe auf gleichem Niveau), ``product`` (Rohdaten) und ``source``
        ("backcast", "product" oder "filled"). Attribute ``"fit"`` (Fit-Objekt oder ``None``), ``"params"``
        (verwendete Parameter) und ``"splice_date"`` (Verkettungsdatum oder ``NA``).
        Seit 1.6.5: an Produkttagen ist ``value`` genau der Produktkurs (bei ``rebase`` mal Faktor); beginnt der Index erst
        nach dem Verkettungstag, gelten die echten Kurse ab der Verkettung (``model`` dann ab dem ersten Tag mit Index und
        Produkt); enden die Produktkurse vor dem Datenende, warnt die Funktion (die Zeilen danach sind fortgeschrieben,
        ``source = "filled"``).

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 1000
        d = pd.DataFrame({"date": pd.date_range("2015-01-01", periods=n)})
        d["idx"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        d["etf"] = simlev.series_leverage(d, "idx", leverage=2, rate=2, expense=0.6)
        d.loc[:599, "etf"] = np.nan                    # Produkt erst ab Tag 601
        bc = simlev.backcast(data=d, product="etf", index="idx", leverage=2, rate=2, ter=0.6, rebase=100)
        print(bc["source"].value_counts())
    """
    fill = _match_arg(fill, ("locf", "linear", "stine", "model"))
    import datetime as _dtm
    from ._pruefen import chk_choice, chk_df, chk_dots, chk_num1, chk_scalar
    fn = "backcast"                                            # seit 1.6.4 vor der Rechnung (K42 E4)
    chk_dots(list(kwargs), ("product", "index", "ter", "leverage", "rate", "fx", "rate_lag", "ter_basis", "rate_basis",
                            "accrual", "index_fill", "lag", "model"), fn)   # Entscheidung 21
    if fit is not None and not isinstance(fit, SimLevBackcastFit):
        chk_stop("c.m_backcast")
    chk_df(data, fn, "data", null_ok=True)                     # Entscheidung 6
    _bc_check_par(params, fn, "params", null_ok=True)
    if params is not None:
        params = {k: chk_scalar(v) for k, v in params.items()}
    splice = chk_scalar(splice)
    if not (isinstance(splice, str) or (isinstance(splice, (_dtm.date, np.datetime64)) and not isinstance(splice, bool))):
        chk_stop("e4.splice", fn)                              # Entscheidung 7 und 15 (keine Zahl, keine Kategorie)
    rebase = chk_num1(rebase, fn, "rebase", lo=0, lo_open=True, null_ok=True)   # B-017
    if fit is None:
        dots = dict(kwargs)
        if data is None:
            chk_stop("c.m_backcast_2")
        a = _modify_list({"ter": 0, "leverage": 1, "rate": None, "fx": None, "rate_lag": 0, "ter_basis": 365,
                          "rate_basis": 360, "accrual": "linear", "index_fill": "locf"}, dots)
        if a.get("product") is None or a.get("index") is None:
            chk_stop("c.m_backcast_3")
        a["data"] = data
        model = dots.get("model") if dots.get("model") is not None else "structural"
        if not (isinstance(model, str) and model == "structural"):
            chk_stop("c.m_backcast_4")
        _bc_check_args(fn, data, a["product"], a["index"], a.get("ter"), a.get("leverage"), a.get("rate"), a.get("fx"),
                       a.get("rate_lag"), a.get("ter_basis"), a.get("rate_basis"))
        for k in ("leverage", "rate_lag", "ter_basis", "rate_basis", "accrual", "index_fill"):
            a[k] = chk_scalar(a[k])
        chk_choice(a["accrual"], fn, "accrual", ("linear", "geometric"))   # bis 1.6.3 unbekannte Werte still "linear"
        chk_choice(a["index_fill"], fn, "index_fill", ("locf", "linear", "stine"))
        _bc_check_lag(dots.get("lag") if dots.get("lag") is not None else 0, data, fn, auto_ok=False)   # ohne Fit kein 'auto'
        reg = None
        par = _modify_list({"drag": 0.0, "spread": 0.0, "beta": 1.0}, params or {})
        lag = int(chk_scalar(dots.get("lag")) if dots.get("lag") is not None else 0)
    else:
        if not isinstance(fit, SimLevBackcastFit):
            chk_stop("c.m_backcast")
        if kwargs:
            chk_stop("e4.fit_angabe", fn, str(next(iter(kwargs))))   # Entscheidung 71 (bis 1.6.3 still ignoriert)
        a = dict(fit["call_args"])
        if data is not None:
            a["data"] = data                                   # seit 1.6.4 wie im Fit geprüft
            _bc_check_args(fn, data, a["product"], a["index"], a.get("ter"), a.get("leverage"), a.get("rate"),
                           a.get("fx"), a.get("rate_lag"), a.get("ter_basis"), a.get("rate_basis"))
        model, reg, lag = fit["model"], fit["regression"], fit["lag"]
        par = _modify_list(dict(fit["params"]), params or {})
    prep = _bc_prepare(a["data"], a["product"], a["index"], a.get("ter"), a.get("leverage"), a.get("rate"),
                       a.get("fx"), int(a.get("rate_lag") or 0), a.get("ter_basis"), a.get("rate_basis"),
                       a.get("accrual"), a.get("index_fill"), lag)
    r_mod = _bc_model_returns(prep, par, model, reg)
    n = prep.n
    prod = prep.prod
    first_idx = int(np.flatnonzero(~np.isnan(prep.idx)).min())
    obs = np.flatnonzero(~np.isnan(prod))
    if (isinstance(splice, str) and splice == "none") or not len(obs):
        k0 = None
    elif isinstance(splice, str) and splice == "inception":
        k0 = int(obs[0])
    else:
        sd0 = _days(_to_date(splice, "splice"))
        if len(sd0) != 1 or math.isnan(sd0[0]):
            chk_stop("c.m_backcast_5")
        cand = obs[prep.dates[obs] >= sd0[0]]
        if not len(cand):
            raise ValueError("Kein Produktkurs ab dem Verkettungsdatum vorhanden (letzter Produktkurs am %s)."
                             % _date_str(prep.dates[obs.max()]))   # seit 1.6.4 ohne Eingabewert
        k0 = int(cand[0])
    r_out = r_mod.copy()
    source = np.array(["backcast"] * n, dtype=object)
    if k0 is not None:
        seg = np.arange(k0, n)
        last_obs = int(obs.max())
        pv = prod[seg]
        if fill == "model":
            po = np.flatnonzero(~np.isnan(pv))
            lv = np.full(len(seg), _NAN)
            lv[po] = _libm.log(pv[po])
            rm = r_mod[seg]
            lr = _libm.log1p(np.maximum(np.where(np.isfinite(rm), rm, 0.0), -0.999999))
            for j in np.flatnonzero(np.diff(po) > 1):              # seit 1.6.4 nur die Lücken (B-107)
                a0, a1 = int(po[j]), int(po[j + 1])
                if a1 - a0 > 1:
                    step = lr[a0 + 1: a1 + 1]
                    adj = ((lv[a1] - lv[a0]) - r_sum(step)) / len(step)
                    lv[a0 + 1: a1] = lv[a0] + r_cumsum(step + adj)[: a1 - a0 - 1]
            if po.max() < len(seg) - 1:
                lv[po.max() + 1:] = lv[po.max()]
            pf = _libm.exp(lv)
        else:
            pf = _fill_na(pv, fill)
        source[seg] = np.where(np.isnan(pv), "filled", "product")
        if last_obs < n - 1:
            source[last_obs + 1:] = "filled"
            # seit 1.6.5 (K23, CR2-B-4): Produktkurse enden vor dem Datenende -> Warnung (R backcast)
            warnings.warn(chk_msg("c.bc_ende", "backcast", _date_str(prep.dates[last_obs]), n - 1 - last_obs))
        with np.errstate(invalid="ignore", divide="ignore"):
            r_seg = np.concatenate([[_NAN], pf[1:] / pf[:-1] - 1])
        r_out[seg[1:]] = r_seg[1:]
        r_out[k0] = r_mod[k0]
    lr_all = _libm.log1p(np.maximum(np.where(np.isfinite(r_out), r_out, 0.0), -0.999999))
    lr_mod = _libm.log1p(np.maximum(np.where(np.isfinite(r_mod), r_mod, 0.0), -0.999999))
    # seit 1.6.5 (CR2-B-1): Renditen nur bis min(first_idx, k0) genullt, value ab k0 nicht NA; model am ersten Tag
    # mit Index und Produkt verankert (R backcast)
    f0 = first_idx if k0 is None else min(first_idx, k0)
    lr_all[: f0 + 1] = 0
    lr_mod[: first_idx + 1] = 0
    cl = r_cumsum(lr_all)
    cm = r_cumsum(lr_mod)
    if k0 is not None:
        if k0 >= first_idx:
            km = k0
        else:
            ko = obs[obs >= first_idx]
            km = int(ko[0]) if ko.size else None
        value = prod[k0] * _libm.exp(cl - cl[k0])
        model_v = prod[km] * _libm.exp(cm - cm[km]) if km is not None else np.full(n, _NAN)
    else:
        value = 100 * _libm.exp(cl)
        model_v = 100 * _libm.exp(cm)
    if f0 > 0:
        value[:f0] = _NAN
    if first_idx > 0:
        model_v[:first_idx] = _NAN
    # seit 1.6.5 (K11, CR2-B-2): an Produkttagen genau der Produktkurs
    ptd = source == "product"
    value[ptd] = prod[ptd]
    if rebase is not None:
        s = rebase / value[f0]
        value = value * s
        model_v = model_v * s
    with np.errstate(invalid="ignore", divide="ignore"):
        ret = np.concatenate([[_NAN], value[1:] / value[:-1] - 1])
    # seit 1.6.5 (CR2-W4-3): fehlende Produktkurse als NA wie in R und Julia (bis 1.6.4 schlichtes NaN, Druck "NaN")
    prod_o = np.where(np.isnan(prod), _NAN, prod)
    out = SimLevBackcast({"date": _as_dates(prep.dates), "value": value, "return": ret, "model": model_v,
                          "product": prod_o, "source": source})
    out.attrs["fit"] = fit
    out.attrs["params"] = RList(par)
    out.attrs["splice_date"] = _as_dates([prep.dates[k0]])[0] if k0 is not None else _NAN   # NA wie in R
    return out


# ═══════════════════════════════════════════════════════════════════════════
# Methoden
# ═══════════════════════════════════════════════════════════════════════════

_DLINE = "═" * 62
_SLINE = "─" * 21


def _format_fit(x) -> str:
    from ._r import fmt as _fmt
    sp = _fmt.sprintf
    d, d0 = x["diagnostics"], x["diagnostics_unfitted"]
    o = ["\n", _DLINE + "\n", "                    SimLev Backcast-Fit                        \n", _DLINE + "\n\n"]
    o.append(sp("  Modell:           %s (Ziel: %s, Verlust: %s, Methode: %s)\n",
                x["model"], x["objective"], x["loss"], x["method"]))
    o.append(sp("  Fit-Fenster:      %s bis %s (%d Beobachtungen, %.1f Jahre)\n",
                _date_str(_days(d["start"])[0]), _date_str(_days(d["end"])[0]), int(d["n_obs"]), d["years"]))
    lev = x["call_args"]["leverage"]
    flev = _fmt.format(lev)
    flev = flev if isinstance(flev, str) else str(list(flev)[0])
    o.append(sp("  Hebel / Lag:      %s / %d Zeilen\n", flev, int(x["lag"])))
    o.append("\n  Parameter\n  " + _SLINE + "\n")
    p = x["params"]

    def mark(k):
        return "(gefittet)" if k in x["fitted"] else "(fest)"

    if x["model"] == "structural":
        o.append(sp("  Beta:             %.5f %s\n", p["beta"], mark("beta")))
    if float(np.ravel(lev)[0]) != 1:
        o.append(sp("  Spread:           %+.4f %% p. a. %s\n", p["spread"], mark("spread")))
    o.append(sp("  Drag:             %+.4f %% p. a. %s  (= %+.6f %% je Tag)\n", p["drag"], mark("drag"), x["drag_per_day"]))
    reg = x["regression"]
    if reg is not None and reg.get("coef") is not None:
        cf = np.asarray(reg["coef"], dtype=np.float64)
        o.append(sp("  Regression:       a = %.3e, b = %.5f\n", cf[0], cf[1]))
    o.append("\n  Abweichung Simulation vs. Produkt     ohne Fit     mit Fit\n  " + _SLINE + "\n")

    def row(lbl, a, b, unit="%"):
        o.append(sp("  %-34s %9.4f%s %9.4f%s\n", lbl, a, unit, b, unit))

    row("Tracking Error p. a.", d0["tracking_error"], d["tracking_error"])
    row("Tracking Difference p. a.", d0["tracking_difference"], d["tracking_difference"])
    row("Endabweichung kumuliert", d0["final_deviation"], d["final_deviation"])
    row("Max. Pfadabweichung", d0["max_abs_deviation"], d["max_abs_deviation"])
    row("RMSE Log-Niveau", d0["rmse_level"], d["rmse_level"])
    o.append(sp("  %-34s %10.4f  %10.4f\n", "Korrelation Tagesrenditen", d0["correlation"], d["correlation"]))
    v = x["validation"]
    if v is not None:
        o.append("\n  Out-of-Sample (Fit jüngere, Test ältere Hälfte)\n  " + _SLINE + "\n")
        te = _days(v["test"])
        o.append(sp("  Test-Zeitraum:    %s bis %s\n", _date_str(te[0]), _date_str(te[1])))
        o.append(sp("  RMSE Log-Niveau:  %.4f %% (ohne Fit: %.4f %%)\n", v["test_rmse_level"], v["naive_rmse_level"]))
        o.append(sp("  Tracking Diff.:   %+.4f %% p. a. (ohne Fit: %+.4f %%)\n",
                    v["test_tracking_difference"], v["naive_tracking_difference"]))
    gm = x["grid_metrics"]
    if gm is not None:
        o.append("\n  Gittersuche: bestes Gitterelement je Metrik\n  " + _SLINE + "\n")
        for k, val in gm.items():
            o.append(sp("  %-26s %+.4f\n", k, val))
    o.append("\n" + _DLINE + "\n")
    txt = "".join(o)
    return txt[:-1] if txt.endswith("\n") else txt


def summary_SimLevBackcastFit(object):  # noqa: A002,N802
    """``summary.SimLevBackcastFit``: druckt den Fit, liefert Parameter, Kennzahlen und Validierung."""
    print(object.format())
    diag = RList((k, v) for k, v in object["diagnostics"].items() if k != "deviation")
    return RList(params=object["params"], diagnostics=diag, validation=object["validation"])


# ── Grafiken (SVG wie julia/src/backcast.jl; Bausteine `_bc_*` in svg.py) ──────

def _plot_fit(x, width=720, height=360):
    """``plot.SimLevBackcastFit``: Pfadabweichung im Fit-Fenster (und Verlustkurve der Gittersuche) als SVG.

    Args:
        width, height: Größe je Teilgrafik in Pixeln (mit Gittersuche zwei Teilgrafiken untereinander).
        file: Dateiname auf ``.svg`` (sonst wird nichts geschrieben).

    Returns:
        :class:`simlev.SimLevPlot`; ``data``: ``deviation`` (``date``, ``deviation`` als Anteil, gezeichnet
        in %) und mit Gittersuche ``grid`` (``value``, ``loss``).
    """
    dev = x["diagnostics"]["deviation"]
    ng = 1 if x["grid"] is None else 2
    dd = _days(dev["date"].to_numpy())
    dv = dev["deviation"].to_numpy(dtype=np.float64)

    def body(out):
        _bc_panel(out, [(dd, dv * 100, "#2C6E9B", 1)], w=width, h=height, title="Pfadabweichung im Fit-Fenster",
                  xlab="Datum", ylab="1 - Sim/Produkt (%)", hlines=[0.0], xdate=True)
        if ng == 2:
            g = x["grid"]
            _bc_panel(out, [(g["value"].to_numpy(dtype=np.float64), g["loss"].to_numpy(dtype=np.float64),
                             "#B5562B", 1)],
                      y0=height, w=width, h=height, title="Gittersuche", xlab="%s (%% p. a.)" % x["fitted"][0],
                      ylab=x["loss"], vlines=[float(x["params"][x["fitted"][0]])])

    data = {"deviation": pd.DataFrame({"date": dev["date"].to_numpy(), "deviation": dv.copy()})}
    if ng == 2:
        data["grid"] = pd.DataFrame({"value": x["grid"]["value"].to_numpy(dtype=np.float64),
                                     "loss": x["grid"]["loss"].to_numpy(dtype=np.float64)})
    return _bc_doc(body, width, height * ng), data


def _plot_backcast(x, log=True, width=720, height=450):
    """``plot.SimLevBackcast``: verkettete Reihe (Backcast/Produkt), Modellreihe und Verkettungsdatum als SVG.

    Args:
        log: logarithmische y-Achse.
        width, height: Größe in Pixeln.
        file: Dateiname auf ``.svg`` (sonst wird nichts geschrieben).

    Returns:
        :class:`simlev.SimLevPlot`; ``data``: ``backcast`` (``date``, ``value``, ``model``, ``source`` der
        gezeichneten Zeilen, d. h. mit endlichem ``value``).
    """
    from ._pruefen import chk_bool1
    log = chk_bool1(log, "plot.SimLevBackcast", "log")        # seit 1.6.4 (B-051)
    val = x["value"].to_numpy(dtype=np.float64)
    mdl = x["model"].to_numpy(dtype=np.float64)
    d = _days(x["date"].to_numpy())
    ok = np.isfinite(val)
    src = np.array([str(v) for v in x["source"]], dtype=object)
    bc = (src == "backcast") & ok
    nb = ~bc & ok
    sd0 = x.attrs.get("splice_date")
    vl = [] if sd0 is None or pd.isna(sd0) else [float(_days(np.array([sd0], dtype="datetime64[D]"))[0])]

    def body(out):
        _bc_panel(out, [(d[ok], mdl[ok], "#A6A6A6", 1), (d[bc], val[bc], "#B5562B", 1.2),
                        (d[nb], val[nb], "#2C6E9B", 1.2)],
                  w=width, h=height, title="Backcast und Produkt", xlab="Datum",
                  ylab="Wert (log. Skala)" if log else "Wert", logy=log, vlines=vl, xdate=True,
                  legend=[("Backcast", "#B5562B"), ("Produkt", "#2C6E9B"), ("Modell durchgehend", "#A6A6A6")])

    data = {"backcast": pd.DataFrame({"date": x["date"].to_numpy()[ok], "value": val[ok], "model": mdl[ok],
                                      "source": src[ok]})}
    return _bc_doc(body, width, height), data


def _format_backcast(x, **kwargs) -> str:
    from ._r import fmt as _fmt
    val = x["value"].to_numpy(dtype=np.float64)
    n_bc = int(((x["source"].to_numpy() == "backcast") & np.isfinite(val)).sum())
    dd = _days(x["date"].to_numpy())
    sd0 = x.attrs.get("splice_date")
    sds = "NA" if sd0 is None or pd.isna(sd0) else _date_str(_days(np.array([sd0]))[0])
    head = _fmt.sprintf("SimLev Backcast: %d Zeilen, %s bis %s; %d Backcast-Tage, Verkettung am %s\n",
                        int(x.shape[0]), _date_str(np.nanmin(dd)), _date_str(np.nanmax(dd)), n_bc, sds)
    df = pd.DataFrame(x).iloc[:6].reset_index(drop=True)
    body = _fmt.print_data_frame(df, types={"source": "character", "date": "Date"}, **kwargs)
    return head + body


def summary(object, *args, **kwargs):  # noqa: A002
    """Generisches ``summary()`` für Objekte dieses Moduls."""
    if isinstance(object, SimLevBackcastFit):
        return summary_SimLevBackcastFit(object)
    chk_stop("e5.methode", "summary")   # seit 1.6.5 (CR2-O-7) wie simlev.summary: ohne Typ (Entscheidung 8)


from .svg import _bc_doc, _bc_panel, _plot_method  # noqa: E402

plot_SimLevBackcastFit = _plot_method(_plot_fit, "SimLevBackcastFit")
plot_SimLevBackcastFit.__name__ = "plot_SimLevBackcastFit"
plot_SimLevBackcast = _plot_method(_plot_backcast, "SimLevBackcast")
plot_SimLevBackcast.__name__ = "plot_SimLevBackcast"
SimLevBackcastFit.plot = plot_SimLevBackcastFit
SimLevBackcast.plot = plot_SimLevBackcast

quiet_fp(globals(), __all__ + ["summary"])
