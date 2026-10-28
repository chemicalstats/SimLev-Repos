"""Vertiefte Auswertung gespeicherter Ergebnisse (Port von ``r/R/deep_analysis.R``).

:func:`deep_analysis` analysiert ein oder mehrere Ergebnisse von
:func:`simlev.simulation` (oder beliebige Kursreihen) nachträglich, im Umfang
von Portfolio-Backtestern wie testfol.io: Benchmark-Kennzahlen (Alpha, Beta,
Capture, Tracking Error, Information Ratio, M²), VaR/CVaR, Rendite- und
Monatstabellen, Saisonalität, Drawdown-Tabelle, rollierende Kennzahlen und
geldgewichtete Rendite (MWRR). Die Simulation selbst bleibt unverändert.

Die internen Helfer ``_da_series`` und ``_da_deflate`` werden auch von
:mod:`simlev.analysis_tests` genutzt.
"""
from __future__ import annotations

import importlib
import math
import sys
from collections.abc import Mapping

import numpy as np
import pandas as pd

from ._r import fmt as _fmt
from ._r import libm as _libm
from ._r.fmt import NA_REAL
from ._r.rlist import RList
from ._r.rnum import LD, r_cummax, r_cumsum, r_mean, r_mean_int, r_pow, r_prod, r_sd, r_var

__all__ = ["deep_analysis", "SimLevAnalysis"]

_NAN = float("nan")   # R-NaN (z. B. mean() leerer Vektoren)
_NA = NA_REAL         # R-NA_real_
_EPOCH = np.datetime64("1970-01-01", "D")
_MONTH_ABB = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
_MONATE_KURZ = ["Jan", "Feb", "Mär", "Apr", "Mai", "Jun", "Jul", "Aug", "Sep", "Okt", "Nov", "Dez"]


# ═══════════════════════════════════════════════════════════════════════════
# Gemeinsame Hilfen (auch für planning.py und analysis_tests.py)
# ═══════════════════════════════════════════════════════════════════════════

def _ext(mod, name):
    """Funktion ``name`` aus ``simlev.<mod>`` (spät geladen; parallel portierte Module)."""
    m = importlib.import_module("simlev." + mod)
    return getattr(m, name)


def _stats(name):
    return getattr(importlib.import_module("simlev._r.stats"), name)


def _message(text):
    """``message()``: Hinweis auf stderr."""
    sys.stderr.write(text + "\n")


def _match_arg(value, choices, argname="arg"):
    from .config import _match_arg as ma
    return ma(value, choices, argname)


def _days(d):
    """Datum (``datetime64``-Array) → Tage seit 1970 als float64 (NaT → NaN)."""
    a = np.asarray(d)
    if a.dtype.kind == "M":
        a = a.astype("datetime64[D]")
        out = (a - _EPOCH).astype(np.int64).astype(np.float64)
        out[np.isnat(a)] = _NA
        return out
    return np.asarray(a, dtype=np.float64)


def _dates(days):
    """Tage seit 1970 (float) → ``datetime64[D]``-Array (NaN → NaT)."""
    a = np.asarray(days, dtype=np.float64)
    out = np.full(a.shape, np.datetime64("NaT", "D"), dtype="datetime64[D]")
    ok = ~np.isnan(a)
    out[ok] = _EPOCH + a[ok].astype(np.int64).astype("timedelta64[D]")
    return out


def _to_date_days(x, what):
    """``.to_date(x, what)`` (Teil A) → Tage als float64."""
    return _days(_ext("data_prep", "_to_date")(x, what))


def _fill_na(v, method="locf", keep_leading=False):
    return np.asarray(_ext("backcast", "_fill_na")(v, method, keep_leading=keep_leading), dtype=np.float64)


def _fmt_date1(day):
    """``format(<Date>)`` eines Tages (NA → "NA")."""
    if day is None or (isinstance(day, float) and math.isnan(day)):
        return "NA"
    return str(_fmt.format_date(_dates([day]))[0])


def _key_month(days):
    """``format(date, "%Y-%m")`` (Monatsschlüssel)."""
    return [str(s) for s in _fmt.format_date(_dates(days), "%Y-%m")]


def _key_year(days):
    return [str(s) for s in _fmt.format_date(_dates(days), "%Y")]


def _key_isoweek(days):
    return [str(s) for s in _fmt.format_date(_dates(days), "%G-%V")]


def _last_of_key(key):
    """``which(c(key[-1] != key[-length(key)], TRUE))`` (0-basiert)."""
    n = len(key)
    return np.array([i for i in range(n) if i == n - 1 or key[i + 1] != key[i]], dtype=np.int64)


def _quantile(x, probs):
    """``stats::quantile(x, probs, names = FALSE)`` (Typ 7)."""
    q = _stats("quantile")
    try:
        r = q(np.asarray(x, dtype=np.float64), probs, names=False)
    except TypeError:
        r = q(np.asarray(x, dtype=np.float64), probs)
    return np.atleast_1d(np.asarray(r, dtype=np.float64))


def _q1(x, p):
    return float(_quantile(x, [p])[0])


def _cor(x, y=None):
    """``stats::cor(x, y)`` (Pearson)."""
    f = _stats("cor")
    if y is None:
        return f(x)
    r = f(np.asarray(x, dtype=np.float64), np.asarray(y, dtype=np.float64))
    return float(np.asarray(r, dtype=np.float64).ravel()[0])


def _cov(x, y):
    f = _stats("cov")
    r = f(np.asarray(x, dtype=np.float64), np.asarray(y, dtype=np.float64))
    return float(np.asarray(r, dtype=np.float64).ravel()[0])


def _col_means(M, na_rm=False):
    """``colMeans(M, na.rm)``: long-double-Summe je Spalte / Anzahl, dann double."""
    M = np.asarray(M, dtype=np.float64)
    out = np.empty(M.shape[1])
    for j in range(M.shape[1]):
        c = M[:, j]
        if na_rm:
            c = c[~np.isnan(c)]
        if c.size == 0:
            out[j] = _NAN
            continue
        s = np.cumsum(c.astype(LD))[-1]
        out[j] = float(s / LD(c.size))
    return out


def _row_means(M):
    """``rowMeans(M)``: long-double-Summe über Spalten / p, dann double."""
    M = np.asarray(M, dtype=np.float64)
    n, p = M.shape
    acc = np.zeros(n, dtype=LD)
    for j in range(p):
        acc = acc + M[:, j].astype(LD)
    return (acc / LD(p)).astype(np.float64)


def _mean_lgl(b):
    """``mean(<logical>)`` (Ganzzahl-Summe / n in long double)."""
    b = np.asarray(b, dtype=bool).ravel()
    if b.size == 0:
        return _NAN
    return r_mean_int(b.astype(np.int64))


def _is_num_scalar(x):
    return isinstance(x, (int, float, np.integer, np.floating)) and not isinstance(x, (bool, np.bool_))


def _is_result(x):
    try:
        from .result import SimLevResult
    except ImportError:  # pragma: no cover
        return False
    return isinstance(x, SimLevResult)


def _rget(x, name, default=None):
    """Element eines Ergebnisobjekts (Attribut oder Schlüssel)."""
    if isinstance(x, Mapping):
        return x.get(name, default)
    return getattr(x, name, default)


def _col_is_numeric(v):
    """``is.numeric()`` einer data.frame-Spalte."""
    dt = v.dtype
    if isinstance(dt, pd.CategoricalDtype) or pd.api.types.is_bool_dtype(dt):
        return False
    if dt == object:
        vals = [e for e in v.tolist() if e is not None and not (isinstance(e, float) and math.isnan(e))]
        return bool(vals) and all(_is_num_scalar(e) for e in vals)
    return bool(pd.api.types.is_numeric_dtype(dt)) and dt.kind != "c"


def _r_class(v):
    """``class(v)[1]`` einer data.frame-Spalte (für Meldungen)."""
    dt = v.dtype
    if isinstance(dt, pd.CategoricalDtype):
        return "factor"
    if pd.api.types.is_bool_dtype(dt):
        return "logical"
    if dt.kind == "M":
        return "Date"
    if dt.kind in "iu":
        return "integer"
    if dt.kind == "f":
        return "numeric"
    if dt == object:
        vals = [e for e in v.tolist() if e is not None]
        if vals and all(isinstance(e, (bool, np.bool_)) for e in vals):
            return "logical"
    return "character"


def _as_numeric_col(v):
    if isinstance(v.dtype, pd.CategoricalDtype):
        return v.cat.codes.to_numpy().astype(np.float64) + 1.0
    if v.dtype.kind == "f":
        return v.to_numpy(dtype=np.float64, copy=True)          # NA/NaN-Bitmuster erhalten
    return pd.to_numeric(v, errors="coerce").to_numpy(dtype=np.float64, na_value=NA_REAL)


def _duplicated_last(d):
    """``duplicated(d, fromLast = TRUE)``."""
    seen = set()
    out = np.zeros(len(d), dtype=bool)
    for i in range(len(d) - 1, -1, -1):
        k = d[i]
        k = "NA" if (isinstance(k, float) and math.isnan(k)) else k
        if k in seen:
            out[i] = True
        else:
            seen.add(k)
    return out


# ═══════════════════════════════════════════════════════════════════════════
# Reihen aufbereiten
# ═══════════════════════════════════════════════════════════════════════════

def _da_series(x, name):
    """Eine Reihe für die Analyse aufbereiten (``.da_series``).

    Liefert ein dict mit ``name``, ``date`` (Tage seit 1970, float64), ``value``,
    ``filled`` (bool), ``worth``, ``flows``, ``result`` und ggf. ``start_gross``.
    """
    if _is_result(x):
        ix = _ext("withdrawal", "result_index")(x)
        value = np.asarray(ix["value"], dtype=np.float64)
        n = len(value)
        fl0 = _rget(x, "filled")
        if fl0 is None:
            fl = np.zeros(n, dtype=bool)
        else:
            fa = np.asarray(fl0, dtype=object).ravel()
            if len(fa) != n:
                fl = np.zeros(n, dtype=bool)
            else:
                fl = np.array([bool(e) if e is not None and not (isinstance(e, float) and math.isnan(e)) else False
                               for e in fa], dtype=bool)
        inv = _rget(x, "invested")
        inv = None if inv is None else np.asarray(inv, dtype=np.float64).ravel()
        return {"name": name, "date": _to_date_days(ix["date"], "'%s'" % name), "value": value, "filled": fl,
                "worth": np.asarray(ix["worth"], dtype=np.float64), "flows": np.asarray(ix["flows"], dtype=np.float64),
                "result": x, "start_gross": float(inv[0]) if inv is not None and inv.size else None}
    if isinstance(x, pd.DataFrame):
        names = [str(c) for c in x.columns]
        if "date" not in names:
            raise ValueError("'%s': data.frame braucht eine Spalte 'date' (vorhanden: %s)%s." % (
                name, ", ".join(names),
                "; nur eine Spalte: Trennzeichen prüfen, Semikolon-Dateien mit read.csv2() einlesen"
                if len(names) == 1 else ""))
        if "value" in names:
            vc = "value"
        else:
            txt = _ext("data_prep", "_num_text_cols")(x, "date")
            if len(txt):
                _ext("data_prep", "_num_text_stop")(x, txt, name)
            num = [k for k in names if _col_is_numeric(x[k]) and k != "date"]
            if not num:
                raise ValueError("'%s': keine numerische Wertspalte gefunden." % name)
            if len(num) > 1:
                _message("Hinweis: '%s': Wertspalte '%s' verwendet (weitere numerische Spalten: %s)." % (
                    name, num[0], ", ".join(num[1:])))
            vc = num[0]
        col = x[vc]
        if not _col_is_numeric(col):
            if len(_ext("data_prep", "_num_text_cols")(x[[vc]])):
                _ext("data_prep", "_num_text_stop")(x, vc, name)
            raise ValueError("'%s': Wertspalte '%s' ist nicht numerisch (Klasse %s)." % (name, vc, _r_class(col)))
        v = _as_numeric_col(col)
        d = _to_date_days(x["date"], "'%s': Spalte 'date'" % name)
        fm = x.attrs.get("filled") if hasattr(x, "attrs") else None
        fl = np.zeros(len(v), dtype=bool)
        if fm is not None:
            if isinstance(fm, pd.DataFrame):
                fmat, fcols = fm.to_numpy(dtype=object), [str(c) for c in fm.columns]
            else:
                fmat = np.asarray(fm, dtype=object)
                fcols = None
                if fmat.ndim == 1:
                    fmat = None
            if fmat is not None and fmat.ndim == 2 and fmat.shape[0] == len(v):
                j = None
                if fcols is not None and vc in fcols:
                    j = fcols.index(vc)
                elif fmat.shape[1] == 1:
                    j = 0
                if j is not None:
                    fl = np.array([e is True or (isinstance(e, (bool, np.bool_)) and bool(e)) for e in fmat[:, j]],
                                  dtype=bool)
        idx = np.flatnonzero(~np.isnan(d))
        idx = idx[np.argsort(d[idx], kind="stable")]
        d, v, fl = d[idx], v[idx], fl[idx]
        dup = _duplicated_last(list(d))
        if dup.any():
            _message("Hinweis: '%s' hat %d doppelte Daten; der letzte Wert je Datum wird verwendet." % (name, int(dup.sum())))
            d, v, fl = d[~dup], v[~dup], fl[~dup]
        has = np.flatnonzero(~np.isnan(v))
        if not has.size:
            raise ValueError("'%s': Wertspalte '%s' hat keine Werte." % (name, vc))
        r = slice(int(has[0]), int(has[-1]) + 1)
        d, v, fl = d[r], v[r], fl[r]
        if np.isnan(v).any():
            fl = fl | np.isnan(v)
            v = _fill_na(v, "locf")
        bad = np.flatnonzero(~np.isfinite(v) | (v <= 0))
        if bad.size:
            raise ValueError("'%s': Wertspalte '%s' muss positive Niveaus enthalten (Kurse oder Indexstände, keine "
                             "Renditen); %d Werte <= 0, z. B. %s am %s." % (
                                 name, vc, bad.size, _fmt.format(float(v[bad[0]])), _fmt_date1(d[bad[0]])))
        if len(v) < 2:
            raise ValueError("'%s': mindestens zwei Daten mit Wert nötig." % name)
        return {"name": name, "date": d, "value": v, "filled": fl, "worth": None, "flows": None, "result": None}
    raise ValueError("'%s' muss ein SimLevResult oder ein data.frame(date, value) sein." % name)


def _da_rf(date, rate, kk, defl=None):
    """Risikoloser Zins je ausgewerteter Rendite (``.da_rf``); ``kk`` 0-basiert.

    Liefert dict ``r`` (Zins je Rendite zwischen den Zeilen ``kk``), ``ann``
    (p. a., geometrisch) und ``cum`` (kumulierter Log-Zins je Zeile).
    """
    date = _days(date)
    rate = np.asarray(rate, dtype=np.float64)
    kk = np.asarray(kk, dtype=np.int64)
    g = np.concatenate([[0.0], _libm.log1p(rate[1:] / 100) * np.diff(date) / 365.25]) if len(date) > 1 else np.zeros(len(date))
    if defl is not None:
        g = g - np.concatenate([[0.0], np.diff(_libm.log(np.asarray(defl, dtype=np.float64)))])
    L = r_cumsum(g)
    span = float(date[-1] - date[0]) / 365.25
    return {"r": _libm.expm1(np.diff(L[kk])),
            "ann": float(_libm.expm1((L[-1] - L[0]) / max(span, 1e-9))),
            "cum": L}


def _da_deflate(s, inflation):
    """Reihe deflationieren (Kaufkraft des Startdatums), ``.da_deflate``."""
    d = s["date"]
    scalar = _is_num_scalar(inflation)
    if not scalar and isinstance(inflation, (np.ndarray, list, tuple, pd.Series)) and not isinstance(inflation, pd.DataFrame):
        a = np.asarray(inflation.to_numpy() if isinstance(inflation, pd.Series) else inflation)
        if a.size == 1 and a.dtype.kind in "iuf":
            inflation = float(a.ravel()[0])
            scalar = True
    if scalar:
        b = 1 + float(inflation) / 100
        cpi = np.array([r_pow(b, e) for e in (d - d[0]) / 365.25], dtype=np.float64)
    else:
        cpi = np.asarray(_ext("data_prep", "_cpi_level")(inflation, pd.DataFrame({"date": _dates(d)}), _dates(d),
                                                         "inflation"), dtype=np.float64)
    if np.isnan(cpi).any():
        ok = np.flatnonzero(~np.isnan(cpi))
        raise ValueError("inflation: Preisindex erst ab %s bekannt, die Reihe '%s' beginnt am %s." % (
            _fmt_date1(d[ok[0]]) if ok.size else "NA", s["name"], _fmt_date1(d[0])))
    f = cpi / cpi[0]
    s = dict(s)
    s["defl"] = f
    s["value"] = s["value"] / f
    if s.get("worth") is not None:
        s["worth"] = s["worth"] / f
    if s.get("flows") is not None:
        s["flows"] = s["flows"] / f
    return s


def _da_period_values(date, value, unit):
    """Wertreihe auf Perioden-Endwerte reduzieren (letzter verfügbarer Tag)."""
    key = _key_month(date) if unit == "month" else _key_year(date)
    last = _last_of_key(key)
    return {"key": [key[i] for i in last], "date": np.asarray(date)[last], "value": np.asarray(value)[last],
            "start_value": float(value[0]), "start_date": float(date[0])}


def _period_returns(m):
    v = m["value"]
    return np.concatenate([[v[0] / m["start_value"]], v[1:] / v[:-1]]) - 1


def _da_mwrr(s):
    """Interne-Zinsfuß-Rendite (MWRR, p. a.) eines Ergebnisses (``.da_mwrr``)."""
    if s.get("worth") is None:
        return _NA
    w = s["worth"]
    n = len(w)
    if n < 2:
        return _NA
    t = (s["date"] - s["date"][0]) / 365.25
    horizon = float(t[-1])
    fl = np.asarray(s["flows"], dtype=np.float64) if s.get("flows") is not None else np.zeros(0)
    if len(fl) != n:
        fl = np.zeros(n)
    fl = np.where(np.isnan(fl), 0.0, fl)
    fi = np.flatnonzero((np.arange(n) > 0) & (fl != 0))
    if not fi.size:
        if w[0] > 0 and horizon > 0 and w[-1] >= 0:
            return r_pow(w[-1] / w[0], 1 / horizon) - 1
        return _NA
    sg = s.get("start_gross")
    start = sg if sg is not None else float(w[0])
    xirr = _ext("engine", "_xirr_rate")
    return float(xirr(np.concatenate([[0.0], t[fi]]), np.concatenate([[start], fl[fi]]), float(w[-1]), horizon))


_DD_COLS = ["start", "trough", "end", "depth", "days_to_trough", "days_to_recover", "days_total"]


def _da_drawdowns(date, value, top=10):
    """Drawdown-Episoden (``.da_drawdowns``), nach Tiefe sortiert."""
    date = _days(date)
    value = np.asarray(value, dtype=np.float64)
    peak = r_cummax(value)
    dd = value / peak - 1
    n = len(value)
    neg = dd < 0
    prev = np.concatenate([[False], neg[:-1]])
    nxt = np.concatenate([neg[1:], [False]])
    st = np.flatnonzero(neg & ~prev)
    if not st.size:
        e = np.empty(0, dtype="datetime64[D]")
        return pd.DataFrame({"start": e, "trough": e, "end": e, "depth": np.zeros(0), "days_to_trough": np.zeros(0),
                             "days_to_recover": np.zeros(0), "days_total": np.zeros(0)})
    en = np.flatnonzero(neg & ~nxt)
    seg = np.cumsum(neg & ~prev)[neg]
    rows = np.flatnonzero(neg)
    tr = []
    for k in range(1, int(seg.max()) + 1):
        r = rows[seg == k]
        tr.append(int(r[int(np.argmin(dd[r]))]))
    tr = np.array(tr, dtype=np.int64)
    s0 = np.maximum(0, st - 1)
    rec = en + 1
    opn = rec > n - 1          # 0-basiert: Erholungszeile hinter dem Ende = offen
    recc = np.minimum(rec, n - 1)
    end = date[recc].copy()
    end[opn] = _NA
    tab = pd.DataFrame({
        "start": date[s0], "trough": date[tr], "end": end, "depth": dd[tr],
        "days_to_trough": date[tr] - date[s0],
        "days_to_recover": np.where(opn, _NA, date[recc] - date[tr]),
        "days_total": np.where(opn, date[-1] - date[s0], date[recc] - date[s0])})
    o = np.argsort(tab["depth"].to_numpy(), kind="stable")
    tab = tab.iloc[o].reset_index(drop=True)
    tab = tab.iloc[:max(0, int(min(top, len(tab))))].reset_index(drop=True)
    for c in ("start", "trough", "end"):
        tab[c] = _dates(tab[c].to_numpy(dtype=np.float64))
    return tab


def _calc_skew(r):
    v = _ext("engine", "calculate_skewness")(r)
    return _NA if v is None else float(v)


def _calc_kurt(r):
    v = _ext("engine", "calculate_kurtosis")(r)
    return _NA if v is None else float(v)


def _sum_any(v):
    if v is None:
        return 0.0
    if isinstance(v, Mapping):
        return float(sum(_sum_any(e) for e in v.values()))
    return float(np.sum(np.asarray(v, dtype=np.float64)))


def _da_metrics(s, rate, ppy, var_levels):
    """Kennzahlen einer Reihe (``.da_metrics``) als ``pandas.Series``."""
    val = s["value"]
    fl = s["filled"]
    kk = np.concatenate([[0], np.flatnonzero(~fl[1:]) + 1]).astype(np.int64)
    vk = val[kk]
    r = vk[1:] / vk[:-1] - 1
    rfl = _da_rf(s["date"], rate, kk, s.get("defl"))
    rf = rfl["r"]
    yrs = float(s["date"][-1] - s["date"][0]) / 365.25
    cagr = r_pow(val[-1] / val[0], 1 / yrs) - 1
    vol = r_sd(r) * math.sqrt(ppy)
    ex = r - rf
    down = ex[ex < 0]
    peak = r_cummax(val)
    dd = 1 - val / peak
    mdd = float(np.max(dd))
    ulcer = math.sqrt(r_mean(dd * dd))
    mr = _period_returns(_da_period_values(s["date"], val, "month"))
    yr = _period_returns(_da_period_values(s["date"], val, "year"))
    var_d, cvar_d, var_m, cvar_m = [], [], [], []
    for a in var_levels:
        q = _q1(r, a)
        var_d.append(-q)
    for a in var_levels:
        q = _q1(r, a)
        cvar_d.append(-r_mean(r[r <= q]))
    for a in var_levels:
        var_m.append(-_q1(mr, a))
    for a in var_levels:
        q = _q1(mr, a)
        cvar_m.append(-r_mean(mr[mr <= q]))
    ddt = _da_drawdowns(s["date"], val, top=1e6)
    rf_ann = rfl["ann"]
    sdex = r_sd(ex)
    out = {
        "start_value": float(val[0]), "end_value": float(val[-1]),
        "years": yrs, "total_return": val[-1] / val[0] - 1,
        "cagr": cagr, "mwrr": _da_mwrr(s), "volatility": vol,
        "sharpe": r_mean(ex) * ppy / (sdex * math.sqrt(ppy)) if sdex > 0 else _NA,
        "sortino": (r_mean(ex) * ppy / (math.sqrt(r_mean(np.minimum(ex, 0) * np.minimum(ex, 0))) * math.sqrt(ppy))
                    if down.size else _NA),
        "calmar": cagr / mdd if mdd > 0 else _NA,
        "max_drawdown": mdd,
        "avg_drawdown": r_mean(-ddt["depth"].to_numpy()) if len(ddt) else 0.0,
        "ulcer_index": ulcer, "upi": (cagr - rf_ann) / ulcer if ulcer > 0 else _NA,
        "longest_drawdown_days": float(np.max(ddt["days_total"].to_numpy())) if len(ddt) else 0.0,
        "recovery_factor": (val[-1] / val[0] - 1) / mdd if mdd > 0 else _NA,
        "required_to_recover": 1 / (1 - dd[-1]) - 1 if dd[-1] > 0 else 0.0,
        "skewness": _calc_skew(r), "excess_kurtosis": _calc_kurt(r),
        "best_day": float(np.max(r)), "worst_day": float(np.min(r)),
        "best_month": float(np.max(mr)), "worst_month": float(np.min(mr)),
        "best_year": float(np.max(yr)), "worst_year": float(np.min(yr)),
        "positive_months": _mean_lgl(mr > 0),
        "avg_gain": r_mean(r[r > 0]), "avg_loss": r_mean(r[r < 0]),
        "gain_loss_ratio": r_mean(r[r > 0]) / abs(r_mean(r[r < 0])) if (r < 0).any() else _NA,
    }
    lab = [_fmt.sprintf("%g", 100 * a) for a in var_levels]
    lab = [str(x if isinstance(x, str) else np.asarray(x).ravel()[0]) for x in lab]
    for pre, vals in (("var_daily_", var_d), ("cvar_daily_", cvar_d), ("var_monthly_", var_m), ("cvar_monthly_", cvar_m)):
        for lb, v in zip(lab, vals):
            out[pre + lb] = float(v)
    res = s.get("result")
    if res is not None:
        tr = _rget(res, "tax_report")
        tx = _rget(tr, "total_taxes_paid") if tr is not None else None
        out["taxes"] = float(tx) if tx is not None else 0.0
        out["trades_per_year"] = _sum_any(_rget(res, "buys")) + _sum_any(_rget(res, "sells"))
    else:
        out["taxes"] = _NA
        out["trades_per_year"] = _NA
    return pd.Series({k: float(v) for k, v in out.items()}, dtype=np.float64)


_BM_ROWS = ["alpha", "beta", "correlation", "r_squared", "correlation_up", "correlation_down",
            "up_capture", "down_capture", "capture_spread", "active_return", "tracking_error",
            "information_ratio", "m2", "treynor"]


def _match_days(a, b):
    """``match(a, b)`` für Tage (0-basiert, -1 = kein Treffer)."""
    pos = {}
    for i, v in enumerate(b):
        if v not in pos:
            pos[v] = i
    return np.array([pos.get(v, -1) for v in a], dtype=np.int64)


def _da_benchmark(s, b, rate, ppy, cagr_s, cagr_b):
    """Benchmark-Kennzahlen auf gemeinsamen Tagen (``.da_benchmark``)."""
    common = np.array(sorted(set(s["date"].tolist()) & set(b["date"].tolist())), dtype=np.float64)
    is_ = _match_days(common, s["date"])
    ib = _match_days(common, b["date"])
    vs = s["value"][is_]
    vb = b["value"][ib]
    keep = ~(s["filled"][is_][1:] | b["filled"][ib][1:])
    if int(keep.sum()) < 3:
        raise ValueError("Benchmark '%s' und Reihe '%s' haben zu wenige gemeinsame Daten (%d gemeinsame Renditen, "
                         "mindestens 3)." % (b["name"], s["name"], int(keep.sum())))
    kk = np.concatenate([[0], np.flatnonzero(keep) + 1]).astype(np.int64)
    rs = vs[kk][1:] / vs[kk][:-1] - 1
    rb = vb[kk][1:] / vb[kk][:-1] - 1
    rfl = _da_rf(common, np.asarray(rate)[is_], kk, s["defl"][is_] if s.get("defl") is not None else None)
    rf = rfl["r"]
    es = rs - rf
    eb = rb - rf
    beta = _cov(es, eb) / r_var(eb)
    alpha = (r_mean(es) - beta * r_mean(eb)) * ppy
    te = r_sd(rs - rb) * math.sqrt(ppy)
    mrs = _period_returns(_da_period_values(common, vs, "month"))
    mrb = _period_returns(_da_period_values(common, vb, "month"))

    def gm(x):
        return r_pow(r_prod(1 + x), 1 / len(x)) - 1

    up = mrb > 0
    dn = mrb < 0
    upc = gm(mrs[up]) / gm(mrb[up]) if up.any() else _NA
    dnc = gm(mrs[dn]) / gm(mrb[dn]) if dn.any() else _NA
    sharpe_s = r_mean(es) * ppy / (r_sd(es) * math.sqrt(ppy))
    rf_ann = rfl["ann"]
    c = _cor(rs, rb)
    vals = [alpha, beta, c, c * c,
            _cor(rs[rb > 0], rb[rb > 0]) if int((rb > 0).sum()) > 2 else _NA,
            _cor(rs[rb < 0], rb[rb < 0]) if int((rb < 0).sum()) > 2 else _NA,
            upc, dnc, upc - dnc, cagr_s - cagr_b, te,
            r_mean(rs - rb) * ppy / te if te > 0 else _NA,
            sharpe_s * r_sd(rb) * math.sqrt(ppy) + rf_ann,
            (r_mean(es) * ppy) / beta if beta != 0 else _NA]
    return np.array([float(v) for v in vals], dtype=np.float64)


def _da_monthly_table(s):
    """Monatsrenditen-Tabelle (Jahr x Monat, plus Jahr) als ``DataFrame``."""
    m = _da_period_values(s["date"], s["value"], "month")
    mr = _period_returns(m)
    yy = [int(k[:4]) for k in m["key"]]
    mm = [int(k[5:7]) for k in m["key"]]
    years = sorted(set(yy))
    pos = {y: i for i, y in enumerate(years)}
    M = np.full((len(years), 12), _NA)
    for y, mo, v in zip(yy, mm, mr):
        M[pos[y], mo - 1] = v
    yv = _da_period_values(s["date"], s["value"], "year")
    yr = _period_returns(yv)
    ykey = {}
    for i, k in enumerate(yv["key"]):
        ykey.setdefault(int(k), i)
    yc = np.array([yr[ykey[y]] if y in ykey else _NA for y in years], dtype=np.float64)
    df = pd.DataFrame(M, index=[str(y) for y in years], columns=_MONTH_ABB)
    df["Year"] = yc
    return df


_ROLL_COLS = ["cagr", "volatility", "sharpe", "max_drawdown", "beta", "excess_cagr"]


def _da_rolling(s, b, window_m, rf_cum):
    """Rollierende Kennzahlen auf Monatsbasis (``.da_rolling``); ``None`` bei zu kurzer Reihe."""
    m = _da_period_values(s["date"], s["value"], "month")
    v = np.concatenate([[m["start_value"]], m["value"]])
    d = np.concatenate([[m["start_date"]], m["date"]])
    Lk = np.asarray(rf_cum)[_match_days(d, s["date"])]
    n = len(v)
    w = int(window_m)
    if n <= w:
        return None
    vb = None
    if b is not None:
        kb = np.searchsorted(b["date"], d, side="right")
        vv = np.where(kb > 0, b["value"][np.maximum(kb, 1) - 1], _NA)
        vv[~np.isfinite(vv) | (vv <= 0)] = _NA
        vb = vv
    rows = []
    for k in range(w, n):
        seg = v[k - w:k + 1]
        r = seg[1:] / seg[:-1] - 1
        yrs = float(d[k] - d[k - w]) / 365.25
        cg = r_pow(seg[-1] / seg[0], 1 / yrs) - 1
        vo = r_sd(r) * math.sqrt(12)
        mdd = float(np.max(1 - seg / r_cummax(seg)))
        bt = ex = _NA
        if vb is not None and not np.isnan(vb[k - w:k + 1]).any():
            sb = vb[k - w:k + 1]
            rb = sb[1:] / sb[:-1] - 1
            bt = _cov(r, rb) / r_var(rb)
            ex = cg - (r_pow(sb[-1] / sb[0], 1 / yrs) - 1)
        rf_w = float(_libm.expm1((Lk[k] - Lk[k - w]) / yrs))
        rows.append([cg, vo, (cg - rf_w) / vo if vo > 0 else _NA, mdd, bt, ex])
    out = np.array(rows, dtype=np.float64).reshape(-1, 6)
    df = pd.DataFrame({"date": _dates(d[w:])})
    for j, c in enumerate(_ROLL_COLS):
        df[c] = out[:, j]
    return df


# ═══════════════════════════════════════════════════════════════════════════
# deep_analysis
# ═══════════════════════════════════════════════════════════════════════════

def _is_list_like(x):
    return isinstance(x, (list, tuple, Mapping)) and not isinstance(x, pd.DataFrame) and not _is_result(x)


def deep_analysis(x, benchmark=None, risk_free=0, rolling_years=3, var_levels=(0.01, 0.05, 0.10), top_drawdowns=10,
                  inflation=None):
    """Vertiefte Analyse von Simulationsergebnissen.

    Wertet ein oder mehrere gespeicherte Ergebnisse von :func:`simlev.simulation`
    (oder Kursreihen) aus. Bei ``SimLevResult`` ist Grundlage der
    zeitgewichtete Wertindex (``result_index``); von der Simulation
    aufgefüllte Tage werden aus den Tagesrenditen ausgeschlossen.

    Args:
        x: ``SimLevResult``, ``DataFrame(date, value)`` oder eine Liste
            (unbenannt: Reihen ``S1``, ``S2``, …) bzw. ein ``dict`` davon.
        benchmark: ``None`` (keine), Name einer Reihe aus ``x`` oder eigenes
            ``SimLevResult``/``DataFrame`` (Name ``"Benchmark"``).
        risk_free: Risikoloser Zins in Prozent p. a.: Skalar,
            ``DataFrame(date, rate)`` oder benannter Vektor mit Datumsnamen.
        rolling_years: Fensterlänge der rollierenden Kennzahlen in Jahren.
        var_levels: Wahrscheinlichkeiten für VaR und CVaR (Anteile).
        top_drawdowns: Anzahl Einträge der Drawdown-Tabelle je Reihe.
        inflation: ``None`` (nominal), Inflation in Prozent p. a. oder
            Preisindex als ``DataFrame(date, value)`` bzw. benannter Vektor.

    Returns:
        :class:`SimLevAnalysis` (``metrics``, ``benchmark_metrics``,
        ``benchmark``, ``annual``, ``monthly``, ``seasonality``, ``drawdowns``,
        ``rolling``, ``rolling_years``, ``correlation``, ``series``,
        ``risk_free``, ``var_levels``, ``real``).
    """
    if _is_result(x) or isinstance(x, pd.DataFrame):
        x = {"Strategie": x}
    if not _is_list_like(x) or not len(x):
        raise ValueError("x muss ein SimLevResult, ein data.frame oder eine Liste davon sein.")
    if isinstance(x, Mapping):
        keys = [str(k) for k in x.keys()]
        vals = list(x.values())
        if any(k == "" for k in keys):
            keys = ["S%d" % (i + 1) for i in range(len(vals))]
    else:
        vals = list(x)
        keys = ["S%d" % (i + 1) for i in range(len(vals))]
    ry = rolling_years
    ry_arr = np.atleast_1d(np.asarray(ry.to_numpy() if isinstance(ry, pd.Series) else ry, dtype=object))
    ry_num = all(_is_num_scalar(e) for e in ry_arr)
    if not ry_num or ry_arr.size != 1 or math.isnan(float(ry_arr[0])) or _fmt.r_round(12 * float(ry_arr[0])) < 2:
        txt = _fmt.format(np.asarray(ry_arr, dtype=np.float64)) if ry_num and ry_arr.size else _fmt.format(ry_arr)
        txt = [str(t) for t in np.atleast_1d(txt)]
        raise ValueError("".join("rolling_years muss mindestens 2/12 (zwei Monate) betragen (ist: %s)." % t for t in txt))
    rolling_years = float(ry_arr[0]) if not isinstance(ry_arr[0], (int, np.integer)) else ry_arr[0]
    vl = np.atleast_1d(np.asarray(var_levels, dtype=object))
    if (not vl.size or not all(_is_num_scalar(e) for e in vl)
            or any(math.isnan(float(e)) for e in vl) or any(float(e) <= 0 or float(e) >= 1 for e in vl)):
        raise ValueError("var_levels: Wahrscheinlichkeiten als Anteile zwischen 0 und 1, z. B. c(0.01, 0.05).")
    var_levels = np.asarray(vl, dtype=np.float64)
    ser = {}
    order = []
    for k, v in zip(keys, vals):
        s = _da_series(v, k)
        if k not in ser:
            order.append(k)
        ser[k] = s
    bname = None
    bser = None
    if benchmark is not None:
        if isinstance(benchmark, str) or (isinstance(benchmark, (list, tuple, np.ndarray))
                                          and len(benchmark) and all(isinstance(e, str) for e in benchmark)):
            bl = [benchmark] if isinstance(benchmark, str) else list(benchmark)
            if len(bl) != 1 or bl[0] not in ser:
                raise ValueError("benchmark muss ein Name aus x sein (%s)." % ", ".join(order))
            bname = bl[0]
            bser = ser[bname]
        else:
            bname = "Benchmark"
            if bname in ser:
                raise ValueError("x enthält bereits eine Reihe 'Benchmark'; benchmark = \"Benchmark\" wählen oder "
                                 "die Reihe in x umbenennen.")
            bser = _da_series(benchmark, bname)
            ser[bname] = bser
            order.append(bname)
    for k in order:
        s = ser[k]
        nn = int((~s["filled"][1:]).sum())
        if nn < 2:
            raise ValueError("'%s': zu kurz (%d Renditen ohne gefüllte Tage, mindestens 2)." % (s["name"], nn))
    if inflation is not None:
        ser = {k: _da_deflate(ser[k], inflation) for k in order}
        if bname is not None:
            bser = ser[bname]
    resolve = _ext("backcast", "_resolve_series")

    def rf_of(s):
        return np.asarray(resolve(risk_free, pd.DataFrame({"date": _dates(s["date"])}), "risk_free"), dtype=np.float64)

    def ppy_of(s):
        k = int((~s["filled"][1:]).sum())
        return k / (float(s["date"][-1] - s["date"][0]) / 365.25)

    mets = {k: _da_metrics(ser[k], rf_of(ser[k]), ppy_of(ser[k]), var_levels) for k in order}
    met = pd.DataFrame({k: mets[k].to_numpy() for k in order}, index=list(mets[order[0]].index))
    bm = None
    if bser is not None:
        others = [k for k in order if k != bname]
        cols = {}
        for nm in others:
            cols[nm] = _da_benchmark(ser[nm], bser, rf_of(ser[nm]), ppy_of(ser[nm]),
                                     float(met.loc["cagr", nm]), float(met.loc["cagr", bname]))
        bm = pd.DataFrame(cols, index=_BM_ROWS, columns=others, dtype=np.float64)
    monthly = {k: _da_monthly_table(ser[k]) for k in order}
    yrs_all = sorted(set(y for k in order for y in monthly[k].index))
    def _year_col(M):                     # M[, "Year"][match(yrs_all, rownames(M))] (fehlend = NA)
        pos = {y: i for i, y in enumerate(M.index)}
        yv = M["Year"].to_numpy(dtype=np.float64)
        return np.array([yv[pos[y]] if y in pos else _NA for y in yrs_all], dtype=np.float64)

    annual = pd.DataFrame({k: _year_col(monthly[k]) for k in order}, index=yrs_all, columns=order)
    seasonality = pd.DataFrame({k: _col_means(monthly[k].iloc[:, :12].to_numpy(dtype=np.float64), na_rm=True)
                                for k in order}, index=_MONTH_ABB, columns=order)
    dds = {k: _da_drawdowns(ser[k]["date"], ser[k]["value"], top_drawdowns) for k in order}
    w = int(_fmt.r_round(12 * float(rolling_years)))
    rolling = {}
    for k in order:
        s = ser[k]
        rolling[k] = _da_rolling(s, bser if (bser is not None and s is not bser) else None, w,
                                 _da_rf(s["date"], rf_of(s), [0], s.get("defl"))["cum"])
    common = list(ser[order[0]]["date"].tolist())
    for k in order[1:]:
        st = set(ser[k]["date"].tolist())
        common = [c for c in common if c in st]
    common = list(dict.fromkeys(common))
    cor_d = cor_m = None
    if len(order) > 1 and len(common) > 30:
        cm = np.array(common, dtype=np.float64)
        Rd = np.column_stack([_ratio_m1(ser[k]["value"][_match_days(cm, ser[k]["date"])]) for k in order])
        cor_d = _cor_frame(Rd, order)
        Rm = np.column_stack([_ratio_m1(_da_period_values(cm, ser[k]["value"][_match_days(cm, ser[k]["date"])], "month")["value"])
                              for k in order])
        cor_m = _cor_frame(Rm, order)
    series = {k: pd.DataFrame({"date": _dates(ser[k]["date"]), "value": ser[k]["value"]}) for k in order}
    return SimLevAnalysis([
        ("metrics", met), ("benchmark_metrics", bm), ("benchmark", bname), ("annual", annual),
        ("monthly", monthly), ("seasonality", seasonality), ("drawdowns", dds), ("rolling", rolling),
        ("rolling_years", rolling_years), ("correlation", {"daily": cor_d, "monthly": cor_m}),
        ("series", series), ("risk_free", risk_free), ("var_levels", var_levels), ("real", inflation is not None)])


def _ratio_m1(v):
    v = np.asarray(v, dtype=np.float64)
    return v[1:] / v[:-1] - 1


def _cor_frame(M, names):
    r = _cor(np.asarray(M, dtype=np.float64))
    a = np.asarray(r.to_numpy() if isinstance(r, pd.DataFrame) else r, dtype=np.float64)
    return pd.DataFrame(a, index=list(names), columns=list(names))


# ═══════════════════════════════════════════════════════════════════════════
# Ausgabe
# ═══════════════════════════════════════════════════════════════════════════

_PCT = {"total_return", "cagr", "mwrr", "volatility", "max_drawdown", "avg_drawdown", "ulcer_index",
        "required_to_recover", "best_day", "worst_day", "best_month", "worst_month", "best_year", "worst_year",
        "positive_months", "avg_gain", "avg_loss", "alpha", "active_return", "tracking_error", "m2", "treynor"}

_LABELS = {
    "total_return": "Gesamtrendite", "cagr": "CAGR (TWR)", "mwrr": "MWRR (geldgewichtet)",
    "volatility": "Volatilität p. a.", "sharpe": "Sharpe", "sortino": "Sortino", "calmar": "Calmar",
    "max_drawdown": "Max. Drawdown", "avg_drawdown": "Mittlerer Drawdown", "ulcer_index": "Ulcer Index",
    "upi": "Ulcer Performance Index", "longest_drawdown_days": "Längster Drawdown",
    "recovery_factor": "Recovery Factor", "best_year": "Bestes Jahr", "worst_year": "Schlechtestes Jahr",
    "worst_month": "Schlechtester Monat", "positive_months": "Positive Monate", "var_daily_5": "VaR 5 % (Tag)",
    "cvar_daily_5": "CVaR 5 % (Tag)", "var_monthly_5": "VaR 5 % (Monat)", "cvar_monthly_5": "CVaR 5 % (Monat)",
    "taxes": "Steuern", "alpha": "Alpha p. a.", "beta": "Beta", "correlation": "Korrelation",
    "r_squared": "R²", "up_capture": "Up-Capture", "down_capture": "Down-Capture",
    "capture_spread": "Capture Spread", "active_return": "Aktive Rendite p. a.",
    "tracking_error": "Tracking Error", "information_ratio": "Information Ratio",
    "m2": "M² (Modigliani)", "treynor": "Treynor"}

_SHOW = ["total_return", "cagr", "mwrr", "volatility", "sharpe", "sortino", "calmar", "max_drawdown",
         "avg_drawdown", "ulcer_index", "upi", "longest_drawdown_days", "best_year", "worst_year",
         "worst_month", "positive_months", "var_daily_5", "cvar_daily_5", "var_monthly_5",
         "cvar_monthly_5", "taxes"]

_BAR = "═" * 62


def _s(x):
    """Erstes Element einer fmt-Ausgabe als ``str``."""
    if isinstance(x, str):
        return x
    return str(np.asarray(x, dtype=object).ravel()[0])


def _sp(fmtstr, *args):
    return _s(_fmt.sprintf(fmtstr, *args))


def _da_fmt(k, v):
    if v is None or math.isnan(v):
        return "–"
    if k in _PCT or k.startswith("var_") or k.startswith("cvar_"):
        return _sp("%.2f %%", 100 * v)
    if k in ("start_value", "end_value", "taxes"):
        return _s(_fmt.formatC(float(v), format="f", digits=0, big_mark=" "))
    if k == "longest_drawdown_days":
        return _sp("%.0f T.", v)
    return _sp("%.3f", v)


def _fmtc_w(strs, w):
    """``paste(formatC(strs, width = w), collapse = "")`` (gemeinsame Breite wie R)."""
    if not len(strs):
        return ""
    return "".join(str(t) for t in np.atleast_1d(_fmt.formatC(np.array([str(t) for t in strs], dtype=object), width=w)))


def _rows_text(M, keys, w):
    out = []
    for k in keys:
        cells = [_da_fmt(k, float(v)) for v in M.loc[k].to_numpy(dtype=np.float64)]
        out.append("  %s%s\n" % (_s(_fmt.format(_LABELS[k], width=26)), _fmtc_w(cells, w)))
    return out


def _nchar(s):
    return int(np.asarray(_fmt.nchar(s)).ravel()[0])


class SimLevAnalysis(RList):
    """Ergebnis von :func:`deep_analysis` (R-Klasse ``SimLevAnalysis``).

    ``print(x)`` zeigt die wichtigsten Kennzahlen, :meth:`summary` zusätzlich
    Jahresrenditen und die größten Drawdowns, :meth:`plot` Grafiken.
    """

    r_class = ("SimLevAnalysis",)

    def format(self):
        M = self["metrics"]
        rn = list(M.index)
        show = [k for k in _SHOW if k in rn]
        cn = [str(c) for c in M.columns]
        w = max(12, max(_nchar(c) for c in cn) + 1)
        out = ["\n" + _BAR + "\n", "                    SimLev Detailanalyse                       \n", _BAR + "\n"]
        s1 = next(iter(self["series"].values()))
        dd = _days(s1["date"].to_numpy())
        out.append("  Zeitraum: %s bis %s (%s Jahre)%s\n\n" % (
            _fmt_date1(float(np.min(dd))), _fmt_date1(float(np.max(dd))), _sp("%.1f", float(M.iloc[rn.index("years"), 0])),
            ", real (Kaufkraft zu Beginn)" if self.get("real") is True else ""))
        out.append(_sp("  %-26s%s\n", "", _fmtc_w(cn, w)))
        out += _rows_text(M, show, w)
        B = self.get("benchmark_metrics")
        if B is not None:
            out.append("\n  Gegen Benchmark '%s'\n" % self["benchmark"])
            out.append(_sp("  %-26s%s\n", "", _fmtc_w([str(c) for c in B.columns], w)))
            out += _rows_text(B, ["alpha", "beta", "correlation", "r_squared", "up_capture", "down_capture",
                                  "capture_spread", "active_return", "tracking_error", "information_ratio", "m2"], w)
        out.append(_BAR + "\n")
        txt = "".join(out)
        return txt[:-1] if txt.endswith("\n") else txt

    def summary(self):
        """Druckt Kennzahlen, Jahresrenditen (%) und je Reihe die fünf größten Drawdowns.

        Returns:
            dict mit ``metrics``, ``benchmark``, ``annual`` und ``drawdowns``.
        """
        sys.stdout.write(self.format() + "\n")
        sys.stdout.write("\n  Jahresrenditen (%)\n")
        A = self["annual"]
        Ar = pd.DataFrame(_fmt.r_round(100 * A.to_numpy(dtype=np.float64), 2), index=A.index, columns=A.columns)
        sys.stdout.write(_fmt.print_matrix(Ar) + "\n")
        for nm, d in self["drawdowns"].items():
            sys.stdout.write("\n  Größte Drawdowns: %s\n" % nm)
            d = d.copy()
            d["depth"] = np.array([_sp("%.2f %%", 100 * v) for v in d["depth"].to_numpy(dtype=np.float64)], dtype=object)
            sys.stdout.write(_fmt.print_data_frame(d.iloc[:5], row_names=False) + "\n")
        return {"metrics": self["metrics"], "benchmark": self.get("benchmark_metrics"), "annual": self["annual"],
                "drawdowns": self["drawdowns"]}

    def plot(self, type=("overview", "growth", "drawdown", "rolling", "annual", "monthly"), series=1,  # noqa: A002
             metric="cagr", **kwargs):
        """Grafiken: Wertentwicklung, Drawdowns, rollierend, Jahresrenditen oder Monats-Heatmap (matplotlib)."""
        type = _match_arg(type, ("overview", "growth", "drawdown", "rolling", "annual", "monthly"))  # noqa: A001
        names = list(self["monthly"].keys())
        if type == "monthly":
            bad = False
            if isinstance(series, (list, tuple, np.ndarray)) and len(series) != 1:
                bad = True
            elif isinstance(series, str):
                bad = series not in names
            elif _is_num_scalar(series):
                bad = not (series >= 1 and series <= len(names))
            if bad:
                raise ValueError("series: Name oder Nummer einer Reihe (%s)." % ", ".join(names))
        if type in ("overview", "rolling") and metric not in _ROLL_COLS:
            raise ValueError("metric: 'cagr', 'volatility', 'sharpe', 'max_drawdown', 'beta' oder 'excess_cagr'.")
        return _plot_analysis(self, type, series, metric, **kwargs)


def summary(object):  # noqa: A002 - R-Name
    """``summary(<SimLevAnalysis>)``."""
    return object.summary()


def _plot_analysis(x, type, series, metric, **kwargs):  # noqa: A002
    import matplotlib.pyplot as plt
    cols = ["#2C6E9B", "#B5562B", "#3E8E5A", "#8A5BA8", "#C49A2C", "#4A4A4A"]
    nms = list(x["series"].keys())
    pct = metric not in ("beta", "sharpe")

    def p_growth(ax):
        for i, (nm, s) in enumerate(x["series"].items()):
            v = s["value"].to_numpy(dtype=float)
            ax.plot(s["date"], v / v[0], color=cols[i % 6], lw=1.3, label=nm)
        ax.set_yscale("log")
        ax.set_ylabel("Wachstum (log)")
        ax.set_title("Wertentwicklung (TWR, Start = 1)")
        ax.legend(loc="upper left", frameon=False, fontsize=8)

    def p_dd(ax):
        for i, (nm, s) in enumerate(x["series"].items()):
            v = s["value"].to_numpy(dtype=float)
            ax.plot(s["date"], 100 * (v / r_cummax(v) - 1), color=cols[i % 6], lw=1)
        ax.set_ylabel("Drawdown (%)")
        ax.set_title("Drawdowns")

    def p_roll(ax):
        rl = {k: v for k, v in x["rolling"].items() if v is not None}
        if not rl:
            ax.set_title("Rollierend: Zeitraum zu kurz")
            ax.axis("off")
            return
        for nm, r in rl.items():
            ax.plot(r["date"], r[metric] * (100 if pct else 1), color=cols[nms.index(nm) % 6], lw=1.2)
        ax.axhline(0, color="grey", ls=":")
        ax.set_ylabel(metric if not pct else "%s (%%)" % metric)
        ax.set_title("Rollierend %g J.: %s" % (x["rolling_years"], metric))

    def p_annual(ax):
        A = (100 * x["annual"]).fillna(0)
        k = A.shape[1]
        pos = np.arange(A.shape[0])
        for j, c in enumerate(A.columns):
            ax.bar(pos + j / (k + 1), A[c], width=1 / (k + 1), color=cols[j % 6])
        ax.set_xticks(pos + (k - 1) / (2 * (k + 1)))
        ax.set_xticklabels(A.index, fontsize=7, rotation=90)
        ax.axhline(0, color="grey")
        ax.set_ylabel("Rendite (%)")
        ax.set_title("Jahresrenditen")

    def p_monthly(ax):
        nm = series if isinstance(series, str) else nms[int(series) - 1]
        M = 100 * x["monthly"][nm].iloc[:, :12]
        lim = float(np.nanmax(np.abs(M.to_numpy(dtype=float))))
        ax.imshow(M.to_numpy(dtype=float), cmap="RdBu", vmin=-lim, vmax=lim, aspect="auto")
        ax.set_xticks(range(12))
        ax.set_xticklabels(_MONATE_KURZ, fontsize=7)
        ax.set_yticks(range(M.shape[0]))
        ax.set_yticklabels(M.index, fontsize=6)
        ax.set_title("Monatsrenditen: %s" % nm)

    if type == "overview":
        fig, axs = plt.subplots(2, 2, figsize=(12, 8))
        p_growth(axs[0, 0])
        p_dd(axs[0, 1])
        p_roll(axs[1, 0])
        p_annual(axs[1, 1])
    else:
        fig, ax = plt.subplots(figsize=(9, 5))
        {"growth": p_growth, "drawdown": p_dd, "rolling": p_roll, "annual": p_annual, "monthly": p_monthly}[type](ax)
    fig.tight_layout()
    return x


from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__ + ["_da_drawdowns", "_da_rf", "_without_filled"])
