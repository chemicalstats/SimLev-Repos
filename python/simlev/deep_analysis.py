"""Vertiefte Auswertung gespeicherter Ergebnisse (Gegenstück zu ``r/R/deep_analysis.R``).

:func:`result_analysis` analysiert ein oder mehrere Ergebnisse von
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
from ._r.rnum import r_colmeans, r_cummax, r_cumsum, r_mean, r_mean_int, r_sd, r_var
# Grafik: Bausteine des Stils Analysegrafiken und Zahlen wie in Julia aus svg.py
from .svg import (_MONATE_KURZ, _AnaSvg, _ana_hline, _ana_legend, _ana_lines, _ana_panel, _ana_ramp, _ana_rect,
                  _ana_svg_done, _ana_text, _ana_year_ticks, _jl_max, _jl_maximum, _jl_min, _jl_minimum)
from ._util import _dates, _days, _match_arg
from ._util import _ext
from ._util import _cagr_q, _geo_ann
from ._util import _is_num_scalar, _match_days, _pow_rec
from ._util import _fp_quiet
from .backcast import _fill_na
from .data_prep import _duplicated
from ._pruefen import chk_fmt, chk_is_factor, chk_msg, chk_num1, chk_scalar, chk_stop

__all__ = ["result_analysis", "SimLevAnalysis"]

_NAN = float("nan")   # R-NaN (z. B. mean() leerer Vektoren)
_NA = NA_REAL         # R-NA_real_
_MONTH_ABB = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


# ═══════════════════════════════════════════════════════════════════════════
# Gemeinsame Hilfen (auch für planning.py und analysis_tests.py)
# ═══════════════════════════════════════════════════════════════════════════

def _stats(name):
    return getattr(importlib.import_module("simlev._r.stats"), name)


def _message(text):
    """``message()``: Hinweis auf stderr."""
    sys.stderr.write(text + "\n")


def _to_date_days(x, what):
    """``.to_date(x, what)`` (Teil A) → Tage als float64."""
    return _days(_ext("data_prep", "_to_date")(x, what))


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


def _rdiv(a, b):
    """``a / b`` wie in R (IEEE: Division durch 0 ergibt ±Inf bzw. NaN, ohne ZeroDivisionError; seit 1.6.4,
    Entscheidung 156). Bei b != 0 gleiche Bits wie ``/``."""
    with np.errstate(all="ignore"):
        return float(np.float64(a) / np.float64(b))


def _cov(x, y):
    f = _stats("cov")
    r = f(np.asarray(x, dtype=np.float64), np.asarray(y, dtype=np.float64))
    return float(np.asarray(r, dtype=np.float64).ravel()[0])


def _col_means(M, na_rm=False):
    """``colMeans(M, na.rm)``: long-double-Summe je Spalte / Anzahl, dann double."""
    M = np.asarray(M, dtype=np.float64)
    return r_colmeans(M, na_rm=na_rm)   # C-Kern core/slc_rbase.cpp (long double wie R; wie Julia)


def _mean_lgl(b):
    """``mean(<logical>)`` (Ganzzahl-Summe / n in long double)."""
    b = np.asarray(b, dtype=bool).ravel()
    if b.size == 0:
        return _NAN
    return r_mean_int(b.astype(np.int64))


def _is_result(x):
    from .result import SimLevResult
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


def _as_numeric_col(v):
    if isinstance(v.dtype, pd.CategoricalDtype):
        return v.cat.codes.to_numpy().astype(np.float64) + 1.0
    if v.dtype.kind == "f":
        return v.to_numpy(dtype=np.float64, copy=True)          # NA/NaN-Bitmuster erhalten
    return pd.to_numeric(v, errors="coerce").to_numpy(dtype=np.float64, na_value=NA_REAL)


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
            chk_stop("c.m_da_series", name, ", ".join(names), "; nur eine Spalte: Trennzeichen prüfen (Semikolon-Dateien mit Semikolon als Trennzeichen und "
                "Dezimalkomma einlesen)"   # seit 1.6.5 sprachneutral (K29, CR2-D-9)
                if len(names) == 1 else "")
        if "value" in names:
            vc = "value"
        else:
            txt = _ext("data_prep", "_num_text_cols")(x, "date")
            if len(txt):
                _ext("data_prep", "_num_text_stop")(x, txt, name)
            num = [k for k in names if _col_is_numeric(x[k]) and k != "date"]
            if not num:
                chk_stop("c.m_da_series_2", name)
            if len(num) > 1:
                _message("Hinweis: '%s': Wertspalte '%s' verwendet (weitere numerische Spalten: %s)." % (
                    name, num[0], ", ".join(num[1:])))
            vc = num[0]
        col = x[vc]
        if isinstance(getattr(col, "dtype", None), pd.CategoricalDtype):   # Entscheidung 15
            chk_stop("spalte_faktor", "result_analysis", vc)
        if not _col_is_numeric(col):
            if len(_ext("data_prep", "_num_text_cols")(x[[vc]])):
                _ext("data_prep", "_num_text_stop")(x, vc, name)
            chk_stop("c.m_da_series_3", name, vc)   # seit 1.6.4 ohne Klasse
        v = _as_numeric_col(col)
        if chk_is_factor(x["date"]):   # seit 1.6.4 (Entscheidung 15; bis 1.6.3 still in Text umgewandelt)
            chk_stop("spalte_faktor", "result_analysis", "date")
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
        if idx.size < d.size:                  # seit 1.6.5 (CR2-D-10): Hinweis auf Zeilen ohne Datum
            _message(chk_msg("c.da_ohne_datum", name, int(d.size - idx.size)))
        d, v, fl = d[idx], v[idx], fl[idx]
        dup = _duplicated(d, from_last=True)   # duplicated(d, fromLast = TRUE) (data_prep; seit 1.6.4 ohne Liste, B-078)
        if dup.any():
            _message("Hinweis: '%s' hat %d doppelte Daten; der letzte Wert je Datum wird verwendet." % (name, int(dup.sum())))
            # seit 1.6.5 (CR2-D-10): je Datum der letzte vorhandene Wert (R .da_series)
            sel = []
            i = 0
            while i < d.size:
                j = i
                while j + 1 < d.size and d[j + 1] == d[i]:
                    j += 1
                okj = [k for k in range(i, j + 1) if not np.isnan(v[k])]
                sel.append(okj[-1] if okj else j)
                i = j + 1
            sel = np.asarray(sel, dtype=np.int64)
            d, v, fl = d[sel], v[sel], fl[sel]
        has = np.flatnonzero(~np.isnan(v))
        if not has.size:
            chk_stop("c.m_da_series_4", name, vc)
        r = slice(int(has[0]), int(has[-1]) + 1)
        d, v, fl = d[r], v[r], fl[r]
        if np.isnan(v).any():
            fl = fl | np.isnan(v)
            v = _fill_na(v, "locf")
        bad = np.flatnonzero(~np.isfinite(v) | (v <= 0))
        if bad.size:
            raise ValueError("'%s': Wertspalte '%s' muss positive Niveaus enthalten (Kurse oder Indexstände, keine "
                             "Renditen); %d Werte nicht endlich oder <= 0, z. B. am %s." % (
                                 name, vc, bad.size, _fmt_date1(d[bad[0]])))   # seit 1.6.4 ohne den Wert
        if len(v) < 2:
            chk_stop("c.m_da_series_5", name)
        return {"name": name, "date": d, "value": v, "filled": fl, "worth": None, "flows": None, "result": None}
    chk_stop("c.m_da_series_6", name)


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
        # seit 1.6.5 (CR2-X5-2): eine Series ist ein benannter Vektor (Preisindex), auch mit Länge 1
        if a.size == 1 and a.dtype.kind in "iuf" and not isinstance(inflation, pd.Series):
            inflation = float(a.ravel()[0])
            scalar = True
    if scalar:
        b = 1 + float(inflation) / 100
        cpi = _pow_rec(b, (d - d[0]) / 365.25)
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
    """Wertreihe auf Perioden-Endwerte reduzieren (letzter verfügbarer Tag). Seit 1.6.4 (B-078) über ganzzahlige
    Perioden (Monat bzw. Jahr des Tages wie ``_dates``) und Text nur für die Periodenenden (``format_date`` wie
    bisher, also auch für Jahre < 1000 wie R); bei fehlenden Daten wie bisher über Text je Tag."""
    dd = _dates(date)
    if dd.size and not np.isnat(dd).any():
        k = dd.astype("datetime64[M]" if unit == "month" else "datetime64[Y]").astype(np.int64)
        last = np.flatnonzero(np.r_[k[1:] != k[:-1], True])
        key = [str(s) for s in _fmt.format_date(dd[last], "%Y-%m" if unit == "month" else "%Y")]
    else:
        key = _key_month(date) if unit == "month" else _key_year(date)
        last = _last_of_key(key)
        key = [key[i] for i in last]
    return {"key": key, "date": np.asarray(date)[last], "value": np.asarray(value)[last],
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
    sg = s.get("start_gross")
    start = sg if sg is not None else float(w[0])   # Start brutto wie cagr der Engine
    if not fi.size:
        # seit 1.6.5 (Entscheidung 200): Startbetrag brutto (Kaufkosten am Starttag zählen), bis dahin w[0]
        if start > 0 and horizon > 0 and w[-1] >= 0:
            return _cagr_q(w[-1] / start, horizon)
        return _NA
    xirr = _ext("engine", "_xirr_rate")
    return float(xirr(np.concatenate([[0.0], t[fi]]), np.concatenate([[start], fl[fi]]), float(w[-1]), horizon))




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
    # Tiefpunkt je Episode (erstes Minimum); seit 1.6.4 je Episode nur ihre Zeilen st..en (B-079; bis 1.6.3 je
    # Episode ein Vergleich über alle Zeilen, gleiche Indizes)
    tr = np.array([int(a) + int(np.argmin(dd[a:b + 1])) for a, b in zip(st, en)], dtype=np.int64)
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


def _da_metrics(s, rate, ppy, var_levels, dd_memo=None):
    """Kennzahlen einer Reihe (``.da_metrics``) als ``pandas.Series``. ``dd_memo`` (Liste, seit 1.6.4, B-079): dort
    ``(s, Episodentabelle)``, wenn sie ohne Gleitkomma-Meldung entstand (für ``drawdowns`` deren Kopf)."""
    val = s["value"]
    fl = s["filled"]
    kk = np.concatenate([[0], np.flatnonzero(~fl[1:]) + 1]).astype(np.int64)
    vk = val[kk]
    r = vk[1:] / vk[:-1] - 1
    rfl = _da_rf(s["date"], rate, kk, s.get("defl"))
    rf = rfl["r"]
    yrs = float(s["date"][-1] - s["date"][0]) / 365.25
    # seit 1.6.5 (Entscheidung 200, M4): bei einem Ergebnis von simulation() Bezug auf den Indexstand vor den
    # Kaufkosten des Starttags (Basis 100 von result_index(), wie ttwror bzw. cagr der Engine); bis dahin val[0]
    b0 = 100.0 if s.get("result") is not None else val[0]
    tot = val[-1] / b0 - 1
    cagr = _cagr_q(val[-1] / b0, yrs)
    vol = r_sd(r) * math.sqrt(ppy)
    ex = r - rf
    down = ex[ex < 0]
    peak = r_cummax(val)
    dd = 1 - val / peak
    mdd = float(np.max(dd))
    ulcer = math.sqrt(r_mean(dd * dd))
    mr = _period_returns(_da_period_values(s["date"], val, "month"))
    yr = _period_returns(_da_period_values(s["date"], val, "year"))
    # seit 1.6.4 je Stufe ein Quantil für VaR und CVaR (B-110; bis 1.6.3 zweimal, gleiche Werte)
    qd = [_q1(r, a) for a in var_levels]
    var_d = [-q for q in qd]
    cvar_d = [-r_mean(r[r <= q]) for q in qd]
    qm = [_q1(mr, a) for a in var_levels]
    var_m = [-q for q in qm]
    cvar_m = [-r_mean(mr[mr <= q]) for q in qm]
    if dd_memo is None:
        ddt = _da_drawdowns(s["date"], val, top=1e6)
    else:
        ddt, q = _fp_quiet(lambda: _da_drawdowns(s["date"], val, top=1e6))
        if not q:
            ddt = _da_drawdowns(s["date"], val, top=1e6)
        elif len(ddt) < 1e6:
            dd_memo.append((s, ddt))
    rf_ann = rfl["ann"]
    sdex = r_sd(ex)
    # seit 1.6.5 (CR2-I-6): Streuung im Rundungsrauschen gilt als 0 (R .da_metrics, Kern sd_eff)
    zero_vol = not (sdex > 16 * math.sqrt(len(ex)) * 2.220446049250313e-16 *
                    (1 + (float(np.max(np.abs(ex))) if len(ex) else 0.0)))
    out = {
        "start_value": float(val[0]), "end_value": float(val[-1]),
        "years": yrs, "total_return": tot,
        "cagr": cagr, "mwrr": _da_mwrr(s), "volatility": vol,
        "sharpe": r_mean(ex) * ppy / (sdex * math.sqrt(ppy)) if not zero_vol else _NA,
        "sortino": (_rdiv(r_mean(ex) * ppy, math.sqrt(r_mean(np.minimum(ex, 0) * np.minimum(ex, 0))) * math.sqrt(ppy))
                    if down.size else _NA),
        "calmar": cagr / mdd if mdd > 0 else _NA,
        "max_drawdown": mdd,
        "avg_drawdown": r_mean(-ddt["depth"].to_numpy()) if len(ddt) else 0.0,
        "ulcer_index": ulcer, "upi": (cagr - rf_ann) / ulcer if ulcer > 0 else _NA,
        "longest_drawdown_days": float(np.max(ddt["days_total"].to_numpy())) if len(ddt) else 0.0,
        "recovery_factor": tot / mdd if mdd > 0 else _NA,
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
    # seit 1.6.4 (Entscheidung 146) Division wie R: Benchmark ohne Schwankung ergibt Beta NaN (0/0) statt
    # ZeroDivisionError, Alpha NaN und Treynor NA
    with np.errstate(all="ignore"):
        beta = float(np.float64(_cov(es, eb)) / np.float64(r_var(eb)))
    alpha = (r_mean(es) - beta * r_mean(eb)) * ppy
    te = r_sd(rs - rb) * math.sqrt(ppy)
    mrs = _period_returns(_da_period_values(common, vs, "month"))
    mrb = _period_returns(_da_period_values(common, vb, "month"))

    def gm(x):
        return _geo_ann(x, len(x))

    up = mrb > 0
    dn = mrb < 0
    upc = _rdiv(gm(mrs[up]), gm(mrb[up])) if up.any() else _NA
    dnc = _rdiv(gm(mrs[dn]), gm(mrb[dn])) if dn.any() else _NA
    # seit 1.6.4 (Entscheidung 156) Division wie R: Reihe ohne Schwankung (risk_free = 0) ergibt NaN statt
    # ZeroDivisionError; ebenso die Quotienten oben, deren Nenner 0 werden kann
    sharpe_s = _rdiv(r_mean(es) * ppy, r_sd(es) * math.sqrt(ppy))
    rf_ann = rfl["ann"]
    c = _cor(rs, rb)
    vals = [alpha, beta, c, c * c,
            _cor(rs[rb > 0], rb[rb > 0]) if int((rb > 0).sum()) > 2 else _NA,
            _cor(rs[rb < 0], rb[rb < 0]) if int((rb < 0).sum()) > 2 else _NA,
            upc, dnc, upc - dnc, cagr_s - cagr_b, te,
            r_mean(rs - rb) * ppy / te if te > 0 else _NA,
            sharpe_s * r_sd(rb) * math.sqrt(ppy) + rf_ann,
            (r_mean(es) * ppy) / beta if (beta == beta and beta != 0) else _NA]
    return np.array([float(v) for v in vals], dtype=np.float64)


def _da_monthly_table(s):
    """Monatsrenditen-Tabelle (Jahr x Monat, plus Jahr) als ``DataFrame``."""
    m = _da_period_values(s["date"], s["value"], "month")
    mr = _period_returns(m)
    # Schlüssel "JJJJ-MM": Jahr = alles vor "-MM" (seit 1.6.4, RP; bis 1.6.3 fest die ersten vier Zeichen, damit
    # Abbruch vor dem Jahr 1000 und falsche Jahre ab 10000)
    yy = [int(k[:-3]) for k in m["key"]]
    mm = [int(k[-2:]) for k in m["key"]]
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
        cg = _cagr_q(seg[-1] / seg[0], yrs)
        vo = r_sd(r) * math.sqrt(12)
        mdd = float(np.max(1 - seg / r_cummax(seg)))
        bt = ex = _NA
        if vb is not None and not np.isnan(vb[k - w:k + 1]).any():
            sb = vb[k - w:k + 1]
            rb = sb[1:] / sb[:-1] - 1
            cv, vr = _cov(r, rb), r_var(rb)
            if vr != 0:
                bt = cv / vr
            else:                                  # Varianz 0: Inf bzw. NaN wie R (seit 1.5.1; bisher ZeroDivisionError)
                with np.errstate(divide="ignore", invalid="ignore"):
                    bt = float(np.float64(cv) / np.float64(vr))
            ex = cg - _cagr_q(sb[-1] / sb[0], yrs)
        rf_w = float(_libm.expm1((Lk[k] - Lk[k - w]) / yrs))
        rows.append([cg, vo, (cg - rf_w) / vo if vo > 0 else _NA, mdd, bt, ex])
    out = np.array(rows, dtype=np.float64).reshape(-1, 6)
    df = pd.DataFrame({"date": _dates(d[w:])})
    for j, c in enumerate(_ROLL_COLS):
        df[c] = out[:, j]
    return df


# ═══════════════════════════════════════════════════════════════════════════
# result_analysis
# ═══════════════════════════════════════════════════════════════════════════

def _is_list_like(x):
    return isinstance(x, (list, tuple, Mapping)) and not isinstance(x, pd.DataFrame) and not _is_result(x)


def result_analysis(x, *, benchmark=None, risk_free=0, rolling_years=3, var_levels=(0.01, 0.05, 0.10), top_drawdowns=10,
                  inflation=None):
    """Vertiefte Analyse von Simulationsergebnissen.

    Wertet ein oder mehrere gespeicherte Ergebnisse von ``simulation()`` (oder Kursreihen) aus, im Umfang gängiger
    Portfolio-Backtester wie testfol.io. Bei ``SimLevResult`` ist Grundlage der zeitgewichtete Wertindex
    (``result_index()``); Sparpläne und Entnahmen verzerren die Renditen daher nicht. Tage, die ``simulation()``
    per LOCF aufgefüllt hat, werden aus den Tagesrenditen für Volatilität, Sharpe, VaR usw. ausgeschlossen.

    Args:
        x: Ein ``SimLevResult``, ein ``data.frame(date, value)`` oder eine (benannte) Liste davon, z. B. mehrere
            gespeicherte Läufe (siehe Details).
        benchmark: Benchmark für die Benchmark-Kennzahlen: ``None`` (Standard; keine), ein Name aus ``x``
            (Zeichenkette) oder ein eigenes ``SimLevResult`` bzw. ``data.frame(date, value)``; dieses wird unter
            dem Namen ``"Benchmark"`` als weitere Reihe aufgenommen. Verglichen wird auf den gemeinsamen Daten
            (mindestens 3 gemeinsame Renditen). Enthält ``x`` schon eine Reihe ``"Benchmark"``, ist ein eigenes
            Objekt hier ein Fehler.
        risk_free: Risikoloser Zins in Prozent p. a. (1 = 1 %): Skalar (Standard 0), ``data.frame(date, rate)``
            oder benannter Vektor mit Datumsnamen (jeweils Stufenfunktion: Wert gilt ab seinem Datum). Je
            ausgewerteter Rendite gilt der Zins über den Kalenderabstand zur vorigen ausgewerteten Zeile, (1 +
            Zins/100)^Tage/365.25 - 1 (Handels- und Kalendertagsdaten ergeben so dieselbe Überschussrendite;
            in 0.5.0 (Vorfassung vor den Korrekturen) je Zeile Zins / 100 / 365.25, bei Handelstagen also nur rund 69 % des
            Zinses). Mit ``inflation`` wird auch der Zins deflationiert (real). ``upi``, rollierende Sharpe und M²
            verwenden den daraus aufgezinsten Zins p. a.
        rolling_years: Fensterlänge der rollierenden Kennzahlen in Jahren (auf ganze Monate gerundet, mindestens 2
            Monate; Standard 3).
        var_levels: Wahrscheinlichkeiten für VaR und CVaR als Anteile (Standard ``[0.01, 0.05, 0.10]``);
            historisch aus Tages- und Monatsrenditen.
        top_drawdowns: Anzahl Einträge der Drawdown-Tabelle je Reihe (Standard 10, nach Tiefe sortiert); eine ganze
            Zahl ``>= 0`` oder ``inf`` (alle). Seit 1.6.4 geprüft: ``rolling_years`` endlich, ``var_levels`` ohne
            doppelte Werte, ``risk_free`` und ``inflation`` als einzelne Zahl endlich (``inflation > -100``), keine
            Kategorie-Spalten.
        inflation: Optional: Inflation in Prozent p. a. (Skalar, 2 = 2 %) oder ein Preisindex-Niveau als
            ``data.frame(date, value)`` bzw. benannter Vektor mit Datumsnamen (z. B. mit ``series_align_macro()``
            vorbereitet). Dann werden alle Kennzahlen real (in Kaufkraft des Startdatums) berechnet, auch die MWRR
            und der risikolose Zins. Ein Preisindex muss am Start jeder Reihe bekannt sein. Standard ``None`` =
            nominal.

    Returns:
        Objekt der Klasse ``SimLevAnalysis``, eine Liste mit

        - metrics: Matrix Kennzahl x Reihe. Renditen, Volatilität, Drawdowns, VaR/CVaR (``var_daily_5``,
          ``cvar_monthly_5`` usw.) als Anteile (0.07 = 7 %), Drawdowns positiv; ``years`` in Jahren,
          ``longest_drawdown_days`` in Kalendertagen; ``taxes`` in Währungseinheiten und ``trades_per_year`` nur
          bei ``SimLevResult``, sonst NA (ebenso ``mwrr``).
        - benchmark_metrics: Matrix Kennzahl x Reihe (ohne Benchmark): ``alpha``, ``beta``, ``correlation``,
          ``r_squared``, ``correlation_up``, ``correlation_down``, ``up_capture``, ``down_capture``,
          ``capture_spread``, ``active_return``, ``tracking_error``, ``information_ratio``, ``m2``, ``treynor``;
          ``None`` ohne Benchmark.
          Seit 1.6.4 rechnet die Funktion auch mit einem Benchmark ohne Schwankung (Überschussrendite konstant):
          ``alpha`` und ``beta`` sind dann NaN, ``treynor`` NA (bis 1.6.3 Abbruch in R und Python).
        - benchmark: Name der Benchmark-Reihe oder ``None``.
        - annual: Matrix Jahr x Reihe der Jahresrenditen (Anteile); Zeilen = alle Jahre aller Reihen, NA, wo eine
          Reihe kein Jahr hat.
        - monthly: Liste je Reihe: Matrix Jahr x Monat (``Jan`` bis ``Dec``) plus Spalte ``Year`` (Anteile).
        - seasonality: Matrix Monat x Reihe: mittlere Monatsrendite.
        - drawdowns: Liste je Reihe: DataFrame mit ``start``, ``trough``, ``end`` (NA, solange nicht erholt),
          ``depth`` (negativer Anteil), ``days_to_trough``, ``days_to_recover``, ``days_total`` (Kalendertage).
        - rolling: Liste je Reihe: DataFrame (Monatsende) mit ``cagr``, ``volatility``, ``sharpe``,
          ``max_drawdown``, ``beta``, ``excess_cagr`` über ``rolling_years`` (``sharpe`` = (CAGR - risikoloser
          Zins im Fenster p. a.) / Volatilität); ``None``, wenn die Reihe zu kurz ist.
        - rolling_years, risk_free, var_levels: die Eingaben.
        - correlation: Liste ``daily`` und ``monthly``: Korrelationsmatrizen der Renditen auf gemeinsamen Daten
          (bei mindestens zwei Reihen und mehr als 30 gemeinsamen Tagen, sonst ``None``).
        - series: Liste je Reihe: ``data.frame(date, value)`` der ausgewerteten (ggf. realen) Wertreihe.
        - real: ``True``, wenn ``inflation`` gesetzt war.

        Ausgabe mit ``print()``, ``summary()`` und ``plot()``, siehe SimLevAnalysis-methods.

    Details:
        Akzeptierte Eingaben (je Reihe):

        - ein ``SimLevResult`` aus ``simulation()``, ``tactical_simulation()`` usw.; nur hier gibt es MWRR,
          Steuern und Transaktionen (ältere Ergebnisse ohne Element ``filled`` gelten als ungefüllt);
        - ein ``data.frame`` mit Spalte ``date`` (Date, POSIXct mit dem Kalendertag in seiner Zeitzone oder
          ``"JJJJ-MM-TT"``) und einer Wertspalte (positive Niveaus, keine Renditen): ``value``, sonst die erste
          numerische Spalte außer ``date`` (bei mehreren mit Hinweis auf die gewählte); weitere Spalten werden
          ignoriert. Zahlen als Text oder Faktor (etwa mit Dezimalkomma eingelesen) sind ein Fehler. Die Zeilen
          werden nach Datum sortiert, bei doppeltem Datum gilt der letzte Wert (mit Hinweis). Führende und
          nachlaufende NA werden abgeschnitten, innere NA per LOCF gefüllt und wie gefüllte Tage behandelt. Trägt
          der DataFrame das Attribut ``filled`` aus ``series_align()`` (Spalte der Wertspalte bzw. einzige
          Spalte), werden diese Tage aus den Tagesrenditen ausgeschlossen. Handelstagsdaten ohne Wochenenden sind
          zulässig; z. B. eine eigene Kursreihe, ein Ergebnis von ``series_splice()`` oder ``result_index()``;
        - eine Liste solcher Objekte (auch gemischt); Namen werden zu Spaltennamen; ist die Liste nicht
          vollständig benannt, heißen alle Reihen ``S1``, ``S2``, ... Ein einzelnes Objekt heißt ``Strategie``.

        Numerische Vektoren werden nicht akzeptiert (vorher als ``data.frame(date, value)`` aufbereiten).

        Die Annualisierung (``ppy``) wird je Reihe aus den Daten ermittelt: Anzahl nicht aufgefüllter
        Tagesrenditen je Jahr (rund 365 bei Kalendertagen, rund 252 bei Handelstagen). Tagesrenditen laufen von
        einem echten (nicht gefüllten) Wert zum nächsten. Monats- und Jahreswerte sind die letzten vorhandenen
        Werte je Kalendermonat bzw. -jahr; das erste Jahr und der erste Monat können daher unvollständig sein.

        Kennzahlen je Reihe: Gesamtrendite, CAGR, geldgewichtete Rendite (MWRR, interner Zinsfuß der Ein- und
        Auszahlungen), Volatilität, Sharpe, Sortino, Calmar, maximaler und mittlerer Drawdown, Ulcer Index, UPI,
        längste Drawdown-Dauer, Recovery Factor, nötige Rendite zur Erholung, Schiefe, Kurtosis, beste und
        schlechteste Tage, Monate und Jahre, Anteil positiver Monate, Gewinn/Verlust-Verhältnis, historischer VaR
        und CVaR (täglich und monatlich), bei SimLev-Ergebnissen auch Steuern und Transaktionen.

        Bei einem ``SimLevResult`` zählen die Kaufkosten am Starttag (Spread, Ordergebühr) in Gesamtrendite, CAGR,
        MWRR, Calmar, UPI und Recovery Factor mit, wie in :func:`simulation` (seit 1.6.5): Bezug ist der Startbetrag
        brutto (``invested[0]``) bzw. der Indexstand 100 vor den Kosten, nicht der Depotwert am Starttag
        (``start_value`` der Kennzahlen). Ohne Einzahlungen ist ``mwrr`` dann gleich ``simulation()["cagr"]``, die
        CAGR gleich ``ttwror``.

        Gegen einen Benchmark: Alpha (annualisiert, CAPM auf Überschussrenditen), Beta, Korrelation gesamt sowie
        in Auf- und Abwärtsphasen, R², Up-/Down-Capture (Monatsbasis), Capture Spread, aktive Rendite, Tracking
        Error, Information Ratio, M² (Modigliani) und Treynor.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 3000
        d = pd.DataFrame({"date": pd.date_range("2010-01-01", periods=n)})
        d["A"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.010, n))
        d["B"] = 100 * np.cumprod(1 + rng.normal(2e-4, 0.006, n))
        a = simlev.simulation(d, simlev.create_strategy(A=simlev.asset_config(asset_class="etf")))
        b = simlev.simulation(d, simlev.create_strategy(A=simlev.asset_config(asset_class="etf", share=0.6),
                                                        B=simlev.asset_config(asset_class="etf", share=0.4)),
                              rebalance=simlev.rebalance_plan(span=1, unit="year"))
        da = simlev.result_analysis({"Aktien": a, "Mischung": b}, benchmark="Aktien", risk_free=1)
        print(da["metrics"].head())
    """
    if _is_result(x) or isinstance(x, pd.DataFrame):
        x = {"Strategie": x}
    if not _is_list_like(x) or not len(x):
        chk_stop("c.m_result_analysis")
    if isinstance(x, Mapping):
        keys = [str(k) for k in x.keys()]
        vals = list(x.values())
        if any(k == "" for k in keys):
            keys = ["S%d" % (i + 1) for i in range(len(vals))]
    else:
        vals = list(x)
        keys = ["S%d" % (i + 1) for i in range(len(vals))]
    fn = "result_analysis"
    ry = rolling_years
    ry_arr = np.atleast_1d(np.asarray(ry.to_numpy() if isinstance(ry, pd.Series) else ry, dtype=object))
    ry_num = all(_is_num_scalar(e) for e in ry_arr)
    if not ry_num or ry_arr.size != 1 or math.isnan(float(ry_arr[0])) or _fmt.r_round(12 * float(ry_arr[0])) < 2:
        chk_stop("c.m_result_analysis_2")   # seit 1.6.4 ohne Eingabewert
    rolling_years = float(ry_arr[0]) if not isinstance(ry_arr[0], (int, np.integer)) else ry_arr[0]
    chk_num1(rolling_years, fn, "rolling_years")   # seit 1.6.4 endlich
    vl = np.atleast_1d(np.asarray(var_levels, dtype=object))
    if (not vl.size or not all(_is_num_scalar(e) for e in vl)
            or any(math.isnan(float(e)) for e in vl) or any(float(e) <= 0 or float(e) >= 1 for e in vl)):
        chk_stop("c.m_result_analysis_3")
    var_levels = np.asarray(vl, dtype=np.float64)
    # seit 1.6.4 (B-052, B-045, B-012): var_levels ohne doppelte Werte, top_drawdowns eine ganze Zahl >= 0 oder Inf,
    # risk_free und inflation als einzelne Zahl endlich (inflation > -100)
    if len(set(var_levels.tolist())) != var_levels.size:
        chk_stop("e1.doppelt", fn, "var_levels")
    td = chk_scalar(top_drawdowns)
    if not (_is_num_scalar(td) and not math.isnan(float(td))
            and (float(td) == math.inf or (math.isfinite(float(td)) and float(td) == math.trunc(float(td))
                                           and float(td) >= 0))):
        chk_stop("e1.ganz_inf", fn, "top_drawdowns", chk_fmt(0))
    top_drawdowns = td
    from .bonds import _no_factor
    _no_factor(risk_free, fn, "risk_free")
    _no_factor(inflation, fn, "inflation")
    rf1 = chk_scalar(risk_free) if isinstance(risk_free, (list, tuple, np.ndarray)) else risk_free
    if _is_num_scalar(rf1) or rf1 is pd.NA:
        chk_num1(rf1, fn, "risk_free")
    if1 = chk_scalar(inflation) if isinstance(inflation, (list, tuple, np.ndarray)) else inflation
    if _is_num_scalar(if1) or if1 is pd.NA:
        chk_num1(if1, fn, "inflation", lo=-100, lo_open=True)
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
                chk_stop("c.m_result_analysis_5")
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

    rf_memo = []

    def rf_of(s):
        # seit 1.6.4 je Reihe einmal (B-110), wenn ohne Gleitkomma-Meldung gerechnet (sonst je Aufruf wie bisher)
        for e in rf_memo:
            if e[0] is s:
                return e[1]

        def calc():
            return np.asarray(resolve(risk_free, pd.DataFrame({"date": _dates(s["date"])}), "risk_free"), dtype=np.float64)
        v, q = _fp_quiet(calc)
        if not q:
            return calc()
        rf_memo.append((s, v))
        return v

    def ppy_of(s):
        k = int((~s["filled"][1:]).sum())
        return k / (float(s["date"][-1] - s["date"][0]) / 365.25)

    dd_memo = []
    mets = {k: _da_metrics(ser[k], rf_of(ser[k]), ppy_of(ser[k]), var_levels, dd_memo) for k in order}
    for k in order:                            # seit 1.6.5 (CR2-I-6): Hinweis bei Sharpe ohne Schwankung
        if np.isnan(mets[k]["sharpe"]) and not np.isnan(mets[k]["volatility"]):
            _message(chk_msg("c.da_sharpe", k))
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
    def dd_of(sk):
        # seit 1.6.4 Kopf der in _da_metrics gemerkten Episodentabelle (B-079; gleiche stabile Sortierung)
        for e in dd_memo:
            if e[0] is sk:
                return e[1].iloc[:max(0, int(min(top_drawdowns, len(e[1]))))].reset_index(drop=True)
        return _da_drawdowns(sk["date"], sk["value"], top_drawdowns)
    dds = {k: dd_of(ser[k]) for k in order}
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
        if Rm.shape[0] == 1:                 # vapply() liefert dann einen Vektor: cor() wie R mit Fehler (seit 1.5.1)
            raise ValueError("supply both 'x' and 'y' or a matrix-like 'x'")
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
    """Ergebnis von :func:`result_analysis` (R-Klasse ``SimLevAnalysis``).

    ``print(x)`` zeigt die wichtigsten Kennzahlen, :meth:`summary` zusätzlich
    Jahresrenditen und die größten Drawdowns, ``plot`` Grafiken (SVG, :class:`simlev.SimLevPlot`).
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
            if len(d) == 0:                    # seit 1.6.5 (CR2-X10-2) statt der leeren Tabelle
                sys.stdout.write("  (keine Drawdowns)\n")
                continue
            d = d.copy()
            d["depth"] = np.array([_sp("%.2f %%", 100 * v) for v in d["depth"].to_numpy(dtype=np.float64)], dtype=object)
            sys.stdout.write(_fmt.print_data_frame(d.iloc[:5], row_names=False) + "\n")
        return {"metrics": self["metrics"], "benchmark": self.get("benchmark_metrics"), "annual": self["annual"],
                "drawdowns": self["drawdowns"]}


def summary(object):  # noqa: A002 - R-Name
    """``summary(<SimLevAnalysis>)``."""
    return object.summary()


# ═══════════════════════════════════════════════════════════════════════════
# Grafik (SVG wie julia/src/deep_analysis.jl; Bausteine `_ana_*` in svg.py)
# ═══════════════════════════════════════════════════════════════════════════

_COLS = ["#2C6E9B", "#B5562B", "#3E8E5A", "#8A5BA8", "#C49A2C", "#4A4A4A"]


def _plot_analysis(x, type=("overview", "growth", "drawdown", "rolling", "annual", "monthly"), series=1,  # noqa: A002
                   metric="cagr"):
    """Grafiken (SVG): Wertentwicklung, Drawdowns, rollierend, Jahresrenditen oder Monats-Heatmap.

    Args:
        type: ``"overview"`` (2 x 2: Wertentwicklung, Drawdowns, rollierend, Jahresrenditen),
            ``"growth"``, ``"drawdown"``, ``"rolling"``, ``"annual"`` oder ``"monthly"``.
        series: Reihe (Name oder Nummer) für ``type = "monthly"``.
        metric: rollierende Kennzahl (``"cagr"``, ``"volatility"``, ``"sharpe"``, ``"max_drawdown"``,
            ``"beta"``, ``"excess_cagr"``).
        file: Dateiname auf ``.svg`` (sonst wird nichts geschrieben).

    Returns:
        :class:`simlev.SimLevPlot`; ``data`` je gezeichnetem Panel: ``growth`` (``series``, ``date``,
        ``growth`` = Wert / Startwert), ``drawdown`` (``series``, ``date``, ``drawdown`` als Anteil),
        ``rolling`` (``series``, ``date``, ``<metric>``), ``annual`` (``year`` und je Reihe eine Spalte,
        Anteile) bzw. ``monthly`` (``year``, ``month``, ``return``; gezeichnete Zellen).
    """
    type = _match_arg(type, ("overview", "growth", "drawdown", "rolling", "annual", "monthly"))  # noqa: A001
    nms = list(x["monthly"].keys())
    if type == "monthly":
        # seit 1.6.5 (CR2-C-4): genau ein Name oder eine ganze Zahl 1..k (R plot.SimLevAnalysis)
        sv = series
        if isinstance(sv, (list, tuple, np.ndarray)):
            sv = list(np.ravel(np.asarray(sv, dtype=object)))
            sv = sv[0] if len(sv) == 1 else None
        if isinstance(sv, str):
            bad = sv not in nms
        elif _is_num_scalar(sv) and not isinstance(sv, (bool, np.bool_)):
            fv = float(sv)
            bad = not (math.isfinite(fv) and fv == math.floor(fv) and 1 <= fv <= len(nms))
        else:
            bad = True
        if bad:
            raise ValueError("series: Name oder Nummer einer Reihe (%s)." % ", ".join(nms))
    if type in ("overview", "rolling") and metric not in _ROLL_COLS:
        chk_stop("c.m_plot_simlevanalysis_2")
    sers = x["series"]
    snames = list(sers.keys())
    cols = [_COLS[i % 6] for i in range(len(snames))]
    pct = metric not in ("beta", "sharpe")
    data = {}

    def p_growth(s, x0, y0, w, h):
        vs = [sers[k]["value"].to_numpy(dtype=np.float64) for k in snames]
        ys = [v / v[0] for v in vs]
        ds = [_days(sers[k]["date"].to_numpy()) for k in snames]
        allv = np.concatenate(ys)
        allv = allv[np.isfinite(allv)]
        alld = np.concatenate(ds)
        yt = _ana_year_ticks(alld)
        p = _ana_panel(s, x0, y0, w, h, (_jl_minimum(alld), _jl_maximum(alld)), (_jl_minimum(allv), _jl_maximum(allv)),
                       logy=True, title="Wertentwicklung (TWR, Start = 1)", ylab="Wachstum (log)", xticks=yt[0],
                       xlabels=yt[1])
        for i in range(len(snames)):
            _ana_lines(s, p, ds[i], ys[i], col=cols[i], lwd=1.3)
        _ana_legend(s, p, snames, cols)
        data["growth"] = pd.DataFrame({
            "series": np.array([k for k, v in zip(snames, ys) for _ in range(len(v))], dtype=object),
            "date": np.concatenate([sers[k]["date"].to_numpy() for k in snames]),
            "growth": np.concatenate(ys)})

    def p_dd(s, x0, y0, w, h):
        dd = []
        for k in snames:
            v = sers[k]["value"].to_numpy(dtype=np.float64)
            dd.append(v / r_cummax(v) - 1)
        ys = [100 * d for d in dd]
        ds = [_days(sers[k]["date"].to_numpy()) for k in snames]
        alld = np.concatenate(ds)
        yt = _ana_year_ticks(alld)
        p = _ana_panel(s, x0, y0, w, h, (_jl_minimum(alld), _jl_maximum(alld)), (_jl_minimum(np.concatenate(ys)), 0.0),
                       title="Drawdowns", ylab="Drawdown (%)", xticks=yt[0], xlabels=yt[1])
        for i in range(len(snames)):
            _ana_lines(s, p, ds[i], ys[i], col=cols[i], lwd=1)
        data["drawdown"] = pd.DataFrame({
            "series": np.array([k for k, v in zip(snames, dd) for _ in range(len(v))], dtype=object),
            "date": np.concatenate([sers[k]["date"].to_numpy() for k in snames]),
            "drawdown": np.concatenate(dd)})

    def p_roll(s, x0, y0, w, h):
        rl = [(k, r) for k, r in x["rolling"].items() if r is not None]
        if not rl:
            _ana_panel(s, x0, y0, w, h, (0, 1), (0, 1), title="Rollierend: Zeitraum zu kurz", box=False, xticks=[],
                       yticks=[])
            data["rolling"] = pd.DataFrame({"series": np.array([], dtype=object),
                                            "date": np.array([], dtype="datetime64[s]"),
                                            metric: np.array([], dtype=np.float64)})
            return
        f = 100 if pct else 1
        raw = [r[metric].to_numpy(dtype=np.float64) for _, r in rl]
        ys = [f * v for v in raw]
        ds = [_days(r["date"].to_numpy()) for _, r in rl]
        allv = np.concatenate(ys)
        allv = allv[np.isfinite(allv)]
        alld = np.concatenate(ds)
        yt = _ana_year_ticks(alld)
        p = _ana_panel(s, x0, y0, w, h, (_jl_minimum(alld), _jl_maximum(alld)),
                       (0.0, 1.0) if allv.size == 0 else (_jl_minimum(allv), _jl_maximum(allv)),
                       title=_sp("Rollierend %g J.: %s", float(np.ravel(x["rolling_years"])[0]), metric),
                       ylab=metric + " (%)" if pct else metric, xticks=yt[0], xlabels=yt[1])
        for i, (k, _) in enumerate(rl):
            _ana_lines(s, p, ds[i], ys[i], col=cols[snames.index(k)], lwd=1.2)
        _ana_hline(s, p, 0.0)
        data["rolling"] = pd.DataFrame({
            "series": np.array([k for (k, _), v in zip(rl, raw) for _ in range(len(v))], dtype=object),
            "date": np.concatenate([r["date"].to_numpy() for _, r in rl]),
            metric: np.concatenate(raw)})

    def p_annual(s, x0, y0, w, h):
        An = x["annual"]
        raw = An.to_numpy(dtype=np.float64)
        A = 100 * raw
        A[np.isnan(A)] = 0
        ny, k = A.shape
        p = _ana_panel(s, x0, y0, w, h, (0.5, ny + 0.5), (_jl_min(0.0, _jl_minimum(A)), _jl_max(0.0, _jl_maximum(A))),
                       title="Jahresrenditen", ylab="Rendite (%)", xticks=list(range(1, ny + 1)),
                       xlabels=[str(r) for r in An.index])
        bw = 0.8 / k
        for i in range(1, ny + 1):
            for j in range(1, k + 1):
                xl = i - 0.4 + (j - 1) * bw
                _ana_rect(s, p, xl, 0.0, xl + bw, A[i - 1, j - 1], fill=cols[j - 1])
        _ana_hline(s, p, 0.0, col="grey", dash="")
        d = {"year": np.array([int(r) for r in An.index], dtype=np.int64)}
        for j, c in enumerate(An.columns):
            d[str(c)] = raw[:, j].copy()
        data["annual"] = pd.DataFrame(d)

    def p_monthly(s, x0, y0, w, h):
        sv = list(np.ravel(np.asarray(series, dtype=object)))[0] if isinstance(series, (list, tuple, np.ndarray)) else series
        nm = sv if isinstance(sv, str) else nms[int(float(sv)) - 1]
        Mf = x["monthly"][nm]
        raw = Mf.to_numpy(dtype=np.float64)[:, :12]
        M = 100 * raw
        fin = M[np.isfinite(M)]
        lim = 1.0 if fin.size == 0 else _jl_maximum(np.abs(fin))
        if lim == 0:                           # seit 1.6.5 (CR2-C-4): ohne Monatsänderung wie ohne Werte
            lim = 1.0
        pal = _ana_ramp(["#B5562B", "#F7F3EE", "#2C6E9B"], 41)
        ny = M.shape[0]
        p = _ana_panel(s, x0, y0, w, h, (0.5, 12.5), (0.5, ny + 0.5), title="Monatsrenditen: %s" % nm,
                       xticks=list(range(1, 13)), xlabels=_MONATE_KURZ, yticks=list(range(1, ny + 1)),
                       ylabels=[str(r) for r in Mf.index])
        yy, mm, vv = [], [], []
        for i in range(1, ny + 1):
            for j in range(1, 13):
                v = float(M[i - 1, j - 1])
                if not math.isfinite(v):
                    continue
                c = pal[min(max(int(round((v + lim) / (2 * lim) * 40)) + 1, 1), 41) - 1]
                _ana_rect(s, p, j - 0.5, i - 0.5, j + 0.5, i + 0.5, fill=c)
                if ny <= 30:
                    _ana_text(s, p, j, i, _sp("%.1f", v), size=7)
                yy.append(int(Mf.index[i - 1]))
                mm.append(j)
                vv.append(float(raw[i - 1, j - 1]))
        data["monthly"] = pd.DataFrame({"year": np.array(yy, dtype=np.int64), "month": np.array(mm, dtype=np.int64),
                                        "return": np.array(vv, dtype=np.float64)})

    s = _AnaSvg(1100 if type == "overview" else 900, 760 if type == "overview" else 520)
    if type == "overview":
        p_growth(s, 0, 0, 550, 380)
        p_dd(s, 550, 0, 550, 380)
        p_roll(s, 0, 380, 550, 380)
        p_annual(s, 550, 380, 550, 380)
    else:
        {"growth": p_growth, "drawdown": p_dd, "rolling": p_roll, "annual": p_annual,
         "monthly": p_monthly}[type](s, 0, 0, 900, 520)
    return _ana_svg_done(s), data


from .svg import _plot_method  # noqa: E402

SimLevAnalysis.plot = _plot_method(_plot_analysis, "SimLevAnalysis")


from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__ + ["_da_drawdowns", "_da_rf"])

