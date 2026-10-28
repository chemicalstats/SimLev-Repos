"""Rückrechnung (Backcast) von Produkt-Kursreihen (Port von ``r/R/backcast.R``).

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

from . import _lib
from ._r import libm as _libm
from ._r.base import quiet_fp
from ._r.fmt import NA_REAL
from ._r.rlist import RList
from ._r.rnum import r_cumsum, r_isna, r_mean, r_median, r_pow, r_sd, r_sum
from .data_prep import (
    _as_dates, _as_date_any, _as_frame, _as_numeric, _col, _date_str, _days, _is_named_numeric,
    _is_number, _match_arg, _named_parts, _names, _names_as_dates_optional, _nrow, _to_date,
    _which_min,
)

__all__ = ["backcast_fit", "backcast", "SimLevBackcastFit", "SimLevBackcast",
           "print_SimLevBackcastFit", "summary_SimLevBackcastFit", "plot_SimLevBackcastFit",
           "print_SimLevBackcast", "plot_SimLevBackcast"]

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
    """Zeitreihe aus flexibler Nutzerangabe auflösen (Port von ``.resolve_series``).

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
    xf = _as_frame(x)
    if isinstance(xf, pd.DataFrame):
        if xf.shape[1] < 2:
            raise ValueError("%s: data.frame braucht die Spalten date und Wert." % what)
        nm = _names(xf)
        dcol = "date" if "date" in nm else nm[0]
        vcol = [k for k in nm if k != dcol][0]
        return _step_series(_days(_to_date(_col(xf, dcol), "%s: Datum" % what)), _as_numeric(_col(xf, vcol)),
                            _days(_to_date(_col(data, "date"), what)))
    if isinstance(x, str) or (isinstance(x, (list, tuple, np.ndarray)) and len(x) == 1 and isinstance(list(np.ravel(x))[0], str)):
        x = x if isinstance(x, str) else str(list(np.ravel(x))[0])
        if x not in _names(data):
            raise ValueError("%s: Spalte '%s' fehlt im Datensatz." % (what, x))
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
    """Stufenfunktion: Wert gilt ab Datum (vor dem ersten Datum: erster Wert). Port von ``.step_series``.

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
    """Fehlende Werte füllen (Port von ``.fill_na``).

    Args:
        v: numerischer Vektor.
        method: ``"locf"`` (Standard), ``"linear"``, ``"stine"`` (Stineman-Interpolation der
            inneren Lücken mit der C-Bibliothek slc, ``_lib.stineman``, seit Etappe 9.6b; Stützstellen
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


def _shift(v, k):
    """Vektor um k Zeilen verschieben (k > 0: Verzögerung). Port von ``.shift``."""
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
    """Verlustfunktionen für den Fit (Port von ``.bc_loss``)."""
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


def _bc_metric_table(err_mat, grid):
    """Grid-Search-Metriken (Port von ``.bc_metric_table``): bestes Gitterelement je Metrik."""
    def finite_last(x):
        f = np.flatnonzero(np.isfinite(x))
        return abs(x[f.max()])

    def nn(x):
        return x[~np.isnan(x)]

    metrics = {
        "median_absolute_error": lambda x: r_median(np.abs(nn(x))),
        "mean_absolute_error": lambda x: r_mean(np.abs(nn(x))),
        "mean_squared_error": lambda x: r_mean(_sq(nn(x))),
        "root_mean_squared_error": lambda x: math.sqrt(r_mean(_sq(nn(x)))),
        "max_absolute_error": lambda x: float(np.max(np.abs(nn(x)))) if len(nn(x)) else -math.inf,
        "final_absolute_error": finite_last,
    }
    grid = np.asarray(grid, dtype=np.float64)
    out = {}
    for k, f in metrics.items():
        vals = [f(err_mat[:, j]) for j in np.arange(err_mat.shape[1])]
        out[k] = float(grid[_which_min(vals)])
    return pd.Series(out)


def _rpow_vec2(x, y):
    x = np.asarray(x, dtype=np.float64)
    y = np.asarray(y, dtype=np.float64)
    n = max(x.size, y.size)
    x = np.resize(x, n)
    y = np.resize(y, n)
    return np.array([r_pow(a, b) for a, b in zip(x, y)], dtype=np.float64)


class _Prep(dict):
    def __getattr__(self, k):
        return self[k]


def _bc_prepare(data, product, index, ter, leverage, rate, fx, rate_lag,
                ter_basis, rate_basis, accrual, index_fill, lag):
    """Überlappung, Komponenten und Hilfsgrößen vorbereiten (Port von ``.bc_prepare``)."""
    data = _as_frame(data)
    if not isinstance(data, pd.DataFrame):
        raise ValueError("'data' muss ein data.frame sein.")
    if "date" not in _names(data):
        raise ValueError("'data' braucht eine Spalte 'date'.")
    data = data.copy()
    dts = _to_date(_col(data, "date"), "'data$date'")
    data["date"] = dts
    dd0 = _days(dts)
    if np.isnan(dd0).any():
        raise ValueError("'data$date' enthält fehlende Daten.")
    if (np.diff(dd0) <= 0).any():
        raise ValueError("'data$date' muss streng aufsteigend und ohne Duplikate sein.")
    for col in [product, index]:
        if col not in _names(data):
            raise ValueError("Spalte '%s' fehlt im Datensatz." % col)
    if not _is_numeric_value(leverage) or np.size(leverage) != 1 or float(np.ravel(leverage)[0]) == 0:
        raise ValueError("'leverage' muss eine Zahl ungleich 0 sein.")
    L = float(np.ravel(leverage)[0])
    idx = _as_numeric(_col(data, index))
    if fx is not None:
        idx = idx * _resolve_series(fx, data, "fx")
    if np.isnan(idx).any():
        idx = _fill_na(idx, index_fill, keep_leading=True)
    with np.errstate(invalid="ignore"):
        if (idx[~np.isnan(idx)] <= 0).any():
            raise ValueError("Indexwerte müssen positiv sein.")
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
        ter_cost = _rpow_vec2(1 + ter_v / 100, dd / ter_basis) - 1
    else:
        ter_cost = ter_v / 100 * dd / ter_basis
    fin = (1 - L) * rate_v / 100 * dd / rate_basis
    m_lev = max(L - 1, 0) + max(-L, 0)
    return _Prep(data=data, n=n, dates=dd0, idx=idx, prod=prod, x=x, dd=dd, leverage=L, ter=ter_v,
                 rate=rate_v, ter_cost=ter_cost, fin=fin, sp_unit=m_lev / 100 * dd / rate_basis,
                 dr_unit=dd / 100 / 365)


def _bc_model_returns(prep, par, model, reg=None):
    """Modellrenditen für einen Parametersatz (Port von ``.bc_model_returns``)."""
    if model == "structural":
        base = par["beta"] * prep.leverage * prep.x + prep.fin - prep.ter_cost
    elif model == "linear":
        coef = np.asarray(reg["coef"], dtype=np.float64)
        base = coef[0] + coef[1] * prep.x
    else:
        base = np.full(prep.n, _NAN)
        ok = np.isfinite(prep.x)
        base[ok] = _spline_predict(reg["fit"], prep.x[ok])
    return base - par["spread"] * prep.sp_unit - par["drag"] * prep.dr_unit


def _bc_errors(r, win, obs, objective, horizon):
    """Abweichungsvektor(en) im Fit-Fenster (Port von ``.bc_errors``; ``win`` 0-basiert)."""
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


def _bc_objective(r, win, obs, objective, horizon, loss, hybrid_weight):
    """Zielfunktion (Port von ``.bc_objective``)."""
    e = _bc_errors(r, win, obs, objective, horizon)
    if objective != "hybrid":
        return _bc_loss(e, loss)
    return math.sqrt(hybrid_weight * r_mean(_sq(e["ret"])) + (1 - hybrid_weight) * r_mean(_sq(e["level"])))


def _cor(x, y):
    from ._r import stats as _st
    return float(_st.cor(np.asarray(x, dtype=np.float64), np.asarray(y, dtype=np.float64)))


def _bc_diagnostics(r, win, obs, dates):
    """Kennzahlen Simulation vs. Produkt (Port von ``.bc_diagnostics``)."""
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
    ret_s = _libm.exp(np.diff(so)) - 1
    ret_p = _libm.exp(np.diff(po)) - 1
    diffs = ret_s - ret_p
    per_year = (m - 1) / yrs if yrs > 0 else 252
    rel = 1 - _libm.exp(so - po)
    out = RList()
    out["n_obs"] = m
    out["years"] = yrs
    out["start"] = _as_dates([d_obs[0]])
    out["end"] = _as_dates([d_obs[m - 1]])
    out["tracking_error"] = r_sd(diffs) * math.sqrt(per_year) * 100
    out["tracking_difference"] = ((_libm.exp(so[m - 1] / yrs) - _libm.exp(po[m - 1] / yrs)) * 100) if yrs > 0 else _NAN
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
    """``.sl_smspline_fit(x, y)``: Glättungsspline (Reinsch 1967, GCV; Entwurf B.15)."""
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


def _r_unique(seq):
    out = []
    for s in seq:
        if s not in out:
            out.append(s)
    return out


# ═══════════════════════════════════════════════════════════════════════════
# Öffentliche Funktionen
# ═══════════════════════════════════════════════════════════════════════════

_BOUNDS0 = {"drag": [-10.0, 10.0], "spread": [-5.0, 10.0], "beta": [0.5, 1.5]}
_GRID0 = None


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

    Passt das Rückrechnungsmodell eines ETF/ETP auf dem Zeitraum an, in dem
    Produkt und Basisindex vorliegen (Argumente wie in R, siehe
    ``r/man/backcast_fit.Rd``). ``fixed``: ``dict`` fester Parameter
    (Standard leer); ``grid``: Standard ``seq(-3, 3, by = 0.005)``;
    ``bounds``: ``dict`` mit Suchintervallen (ergänzt die Standardliste).

    Returns:
        :class:`SimLevBackcastFit`.
    """
    model = _match_arg(model, ("structural", "linear", "spline"))
    objective = _match_arg(objective, ("level", "return", "hybrid"))
    loss = _match_arg(loss, ("rmse", "mse", "mae", "median", "max"))
    method = _match_arg(method, ("optimize", "grid"))
    accrual = _match_arg(accrual, ("linear", "geometric"))
    index_fill = _match_arg(index_fill, ("locf", "linear", "stine"))
    fixed = dict(fixed or {})
    grid = _default_grid() if grid is None else np.atleast_1d(np.asarray(grid, dtype=np.float64))
    fit = _r_unique(_as_char_vec(fit))
    if len(fit) and not all(f in ("drag", "spread", "beta") for f in fit):
        raise ValueError("'fit' darf nur 'drag', 'spread' und 'beta' enthalten.")
    if bounds is None:
        bounds = dict(_BOUNDS0)
    if not isinstance(bounds, Mapping) or (len(bounds) and not all(k in ("drag", "spread", "beta") for k in bounds)):
        raise ValueError("'bounds' muss eine benannte Liste mit Einträgen drag, spread und/oder beta sein, "
                         "z. B. list(drag = c(-5, 5)).")
    bounds = _modify_list(_BOUNDS0, bounds)
    for k, b in bounds.items():
        ok = _is_numeric_value(b) and np.size(b) == 2
        if ok:
            bb = np.asarray(b, dtype=np.float64).ravel()
            ok = not np.isnan(bb).any() and bb[0] < bb[1]
        if not ok:
            from ._r import fmt as _fmt
            fb = _fmt.format(b)
            fb = [fb] if isinstance(fb, str) else list(fb)
            raise ValueError("bounds$%s muss c(unten, oben) mit unten < oben sein (ist: %s)." % (k, ", ".join(fb)))
        bounds[k] = [float(bb[0]), float(bb[1])]
    if model != "structural" and "beta" in fit:
        warnings.warn("'beta' wird bei Regressionsmodellen über die Regression geschätzt und hier ignoriert.")
        fit = [f for f in fit if f != "beta"]
    if leverage == 1 and "spread" in fit:
        warnings.warn("'spread' ist bei leverage = 1 nicht identifizierbar und wird ignoriert.")
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
        lag = cand[_which_max([sg * c for c in cors])]
        prep = _bc_prepare(data, product, index, ter, leverage, rate, fx, int(rate_lag), ter_basis, rate_basis,
                           accrual, index_fill, int(lag))

    has = ~np.isnan(prep.prod) & ~np.isnan(prep.idx)
    if start is not None:
        has = has & (prep.dates >= _as_date_any(start)[0])
    if end is not None:
        has = has & (prep.dates <= _as_date_any(end)[0])
    if has.sum() < 20:
        raise ValueError("Zu wenige gemeinsame Beobachtungen von Produkt und Index (mindestens 20).")
    hw = np.flatnonzero(has)
    w0, w1 = int(hw.min()), int(hw.max())
    win = np.arange(w0, w1 + 1)
    inception = _as_dates([prep.dates[np.flatnonzero(~np.isnan(prep.prod)).min()]])

    def make_obs(rows):
        pos = np.flatnonzero(has[rows])
        return {"pos": pos, "logp": _libm.log(prep.prod[rows][pos])}

    obs = make_obs(win)

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
            raise ValueError("Zu wenige aufeinanderfolgende Beobachtungen für das Regressionsmodell.")
        if model == "linear":
            X = np.column_stack([np.ones(int(ok.sum())), xx[ok]])
            return RList(coef=_lm_fit_coef(X, y[ok]))
        return RList(fit=_smooth_spline(xx[ok], y[ok]))

    reg = fit_reg(win)
    par0 = _modify_list({"drag": 0.0, "spread": 0.0, "beta": 1.0}, fixed)

    def obj_fun(theta, rows, ob, rg):
        p = dict(par0)
        for k, t in zip(fit, np.atleast_1d(np.asarray(theta, dtype=np.float64))):
            p[k] = float(t)
        rr = _bc_model_returns(prep, p, model, rg)[rows]
        return _bc_objective(rr, np.arange(len(rows)), ob, objective, horizon, loss, hybrid_weight)

    def run_fit(rows, ob, rg):
        if not len(fit):
            return {"par": dict(par0), "value": obj_fun(np.empty(0), rows, ob, rg), "grid": None}
        if method == "grid":
            if len(fit) != 1:
                raise ValueError("method = 'grid' unterstützt genau einen Parameter in 'fit'.")
            vals = np.array([obj_fun(g, rows, ob, rg) for g in grid], dtype=np.float64)
            best = float(grid[_which_min(list(vals))])
            cols = []
            for g in grid:
                p = dict(par0)
                p[fit[0]] = float(g)
                e = _bc_errors(_bc_model_returns(prep, p, model, rg)[rows], np.arange(len(rows)), ob, "level", 1)
                cols.append(1 - _libm.exp(e))
            err_mat = np.column_stack(cols) if cols else np.empty((len(ob["pos"]), 0))
            p = dict(par0)
            p[fit[0]] = best
            return {"par": p, "value": _r_min(vals),
                    "grid": pd.DataFrame({"value": grid, "loss": vals}),
                    "metrics": _bc_metric_table(err_mat, grid)}
        if len(fit) == 1:
            b = bounds[fit[0]]
            mn, ov = _optimize(lambda t: obj_fun(t, rows, ob, rg), b[0], b[1], 1e-8)
            p = dict(par0)
            p[fit[0]] = mn
            return {"par": p, "value": ov, "grid": None}
        st = np.array([par0[k] for k in fit], dtype=np.float64)
        lo = np.array([bounds[k][0] for k in fit])
        hi = np.array([bounds[k][1] for k in fit])
        opar, oval, conv = _optim_lbfgsb(st, lambda t: obj_fun(t, rows, ob, rg), lo, hi)
        p = dict(par0)
        for k, t in zip(fit, opar):
            p[k] = float(t)
        return {"par": p, "value": oval, "grid": None, "convergence": conv}

    res = run_fit(win, obs, reg)
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
            res_tr = run_fit(tr_rows, ob_tr, rg_tr)
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
    out["regression"] = reg
    out["inception"] = inception
    out["window"] = _as_dates([prep.dates[w0], prep.dates[w1]])
    out["drag_per_day"] = res["par"]["drag"] / 100 / 365 * 100
    out["call_args"] = RList(data=data, product=product, index=index, ter=ter, leverage=leverage, rate=rate,
                             fx=fx, rate_lag=int(rate_lag), ter_basis=ter_basis, rate_basis=rate_basis,
                             accrual=accrual, index_fill=index_fill)
    return out


def _which_max(a) -> int:
    best = -1
    bv = -math.inf
    for i, v in enumerate(a):
        if not math.isnan(v) and (best < 0 or v > bv):
            best, bv = i, v
    if best < 0:
        raise ValueError("argument of length 0")
    return best


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

    Args:
        fit: :class:`SimLevBackcastFit` oder ``None`` (dann ``data``,
            ``product``, ``index`` und Modellangaben über ``**kwargs``; nur
            Strukturmodell).
        data: optional anderer Datensatz (bei ``fit``) bzw. Pflicht ohne Fit.
        params: ``dict`` mit ``drag``, ``spread`` und/oder ``beta``.
        splice: ``"inception"``, ``"none"`` oder ein Datum.
        fill: ``"locf"``, ``"linear"``, ``"stine"`` oder ``"model"``.
        rebase: ``None`` oder Startwert am ersten Indextag.

    Returns:
        :class:`SimLevBackcast` (DataFrame mit ``date``, ``value``,
        ``return``, ``model``, ``product``, ``source``).
    """
    fill = _match_arg(fill, ("locf", "linear", "stine", "model"))
    if fit is None:
        dots = dict(kwargs)
        if data is None:
            raise ValueError("Ohne 'fit' muss 'data' angegeben werden.")
        a = _modify_list({"ter": 0, "leverage": 1, "rate": None, "fx": None, "rate_lag": 0, "ter_basis": 365,
                          "rate_basis": 360, "accrual": "linear", "index_fill": "locf"}, dots)
        if a.get("product") is None or a.get("index") is None:
            raise ValueError("'product' und 'index' müssen angegeben werden.")
        a["data"] = data
        model = dots.get("model") if dots.get("model") is not None else "structural"
        if model != "structural":
            raise ValueError("Ohne Fit ist nur model = 'structural' möglich.")
        reg = None
        par = _modify_list({"drag": 0.0, "spread": 0.0, "beta": 1.0}, params or {})
        lag = int(dots.get("lag") if dots.get("lag") is not None else 0)
    else:
        if not isinstance(fit, SimLevBackcastFit):
            raise ValueError("'fit' muss ein SimLevBackcastFit-Objekt sein.")
        a = dict(fit["call_args"])
        if data is not None:
            a["data"] = data
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
            raise ValueError("splice: \"inception\", \"none\" oder ein Datum ('JJJJ-MM-TT').")
        cand = obs[prep.dates[obs] >= sd0[0]]
        if not len(cand):
            raise ValueError("Kein Produktkurs ab dem Verkettungsdatum %s vorhanden (letzter Produktkurs am %s)."
                             % (_date_str(sd0[0]), _date_str(prep.dates[obs.max()])))
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
            for j in np.arange(len(po) - 1):
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
        with np.errstate(invalid="ignore", divide="ignore"):
            r_seg = np.concatenate([[_NAN], pf[1:] / pf[:-1] - 1])
        r_out[seg[1:]] = r_seg[1:]
        r_out[k0] = r_mod[k0]
    lr_all = _libm.log1p(np.maximum(np.where(np.isfinite(r_out), r_out, 0.0), -0.999999))
    lr_mod = _libm.log1p(np.maximum(np.where(np.isfinite(r_mod), r_mod, 0.0), -0.999999))
    lr_all[: first_idx + 1] = 0
    lr_mod[: first_idx + 1] = 0
    cl = r_cumsum(lr_all)
    cm = r_cumsum(lr_mod)
    if k0 is not None:
        value = prod[k0] * _libm.exp(cl - cl[k0])
        model_v = prod[k0] * _libm.exp(cm - cm[k0])
    else:
        value = 100 * _libm.exp(cl)
        model_v = 100 * _libm.exp(cm)
    if first_idx > 0:
        value[:first_idx] = _NAN
        model_v[:first_idx] = _NAN
    if rebase is not None:
        s = rebase / value[first_idx]
        value = value * s
        model_v = model_v * s
    with np.errstate(invalid="ignore", divide="ignore"):
        ret = np.concatenate([[_NAN], value[1:] / value[:-1] - 1])
    out = SimLevBackcast({"date": _as_dates(prep.dates), "value": value, "return": ret, "model": model_v,
                          "product": prod, "source": source})
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


def print_SimLevBackcastFit(x):  # noqa: N802
    """``print.SimLevBackcastFit``."""
    print(x.format())
    return x


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


def print_SimLevBackcast(x, **kwargs):  # noqa: N802
    """``print.SimLevBackcast``: Kopfzeile und die ersten Zeilen."""
    print(x.format(**kwargs))
    return x


def summary(object, *args, **kwargs):  # noqa: A002
    """Generisches ``summary()`` für Objekte dieses Moduls."""
    if isinstance(object, SimLevBackcastFit):
        return summary_SimLevBackcastFit(object)
    raise TypeError("kein summary() für %s" % type(object).__name__)


from .svg import _bc_doc, _bc_panel, _plot_method  # noqa: E402

plot_SimLevBackcastFit = _plot_method(_plot_fit, "SimLevBackcastFit")
plot_SimLevBackcastFit.__name__ = "plot_SimLevBackcastFit"
plot_SimLevBackcast = _plot_method(_plot_backcast, "SimLevBackcast")
plot_SimLevBackcast.__name__ = "plot_SimLevBackcast"
SimLevBackcastFit.plot = plot_SimLevBackcastFit
SimLevBackcast.plot = plot_SimLevBackcast

quiet_fp(globals(), __all__ + ["summary"])
