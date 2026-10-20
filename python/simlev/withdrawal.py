"""Entnahme-Simulationen (Ruhestand / Decumulation), Port von ``r/R/withdrawal.R``.

Öffentliche Funktionen:

- :func:`withdrawal_rule` – Regel-Objekt (14 Regeln)
- :func:`withdrawal_cohorts` – historische rollierende Kohorten (Bengen/Trinity)
- :func:`withdrawal_paths` – Periodenrenditen aus Bootstrap-Pfaden, Ergebnislisten
  oder Bootstrap-Studien
- :func:`result_index` – zeitgewichteter Wertindex eines Simulationsergebnisses
- :func:`withdrawal_simulation` – schneller Kern über viele Pfade, optional mit
  vereinfachter deutscher Besteuerung
- :func:`perfect_withdrawal_rate` – PWR nach Suarez, Suarez & Walz (2015)
- :func:`withdrawal_max_rate` – maximale Anfangsrate für eine Ziel-Erfolgsquote
- :func:`horizon_model` – Laufzeit der Entnahmephase

PROZENT-KONVENTION: rate, ceiling, floor, cut, raise, exp_return usw. in
Prozent (rate = 4 bedeutet 4 % p. a.), wie im restlichen Paket.
"""
from __future__ import annotations

import contextlib
import io
import math
import time
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

from . import _withdrawal_core as _wcore
from ._r import fmt as _fmt
from ._r import rng as _rng
from ._r.rlist import RList
from ._rnum import r_cummax, r_cumprod, r_mean, r_mean_int, r_median, r_pow, r_prod, r_sum
from .bootstrap import (_MISSING, _quiet, _get, _is_boot_result, _is_num, _is_study, _message, _names, _num1, _num_vec,
                        _quantile7, _r_round0, _show, _sp, _stop, _strip1, _values, _warn, _weighted_mean,
                        _with_rng_restore, _wquantile, summary, plot)

__all__ = [
    "withdrawal_rule", "WithdrawalRule", "withdrawal_cohorts", "WithdrawalPaths", "result_index",
    "withdrawal_paths", "perfect_withdrawal_rate", "withdrawal_simulation", "SimLevWithdrawal",
    "SummarySimLevWithdrawal", "withdrawal_max_rate", "horizon_model", "SimLevHorizon", "summary", "plot",
]

_NAN = float("nan")      # R's NaN
_NA = _fmt.NA_REAL       # R's NA_real_
LD = np.longdouble

_WD_RULES = {"constant": 1, "percent": 2, "vanguard": 3, "guyton_klinger": 4, "floor_ceiling": 5, "clyatt": 6,
             "ratchet": 7, "endowment": 8, "one_over_n": 9, "vpw": 10, "abw": 11, "cape": 12, "sensible": 13,
             "hebeler": 14}

_WD_LABELS = {"constant": "Konstante reale Entnahme (Bengen/Trinity)",
              "percent": "Fester Prozentsatz des Depots",
              "vanguard": "Vanguard Dynamic Spending (Ceiling/Floor)",
              "guyton_klinger": "Guyton-Klinger-Entscheidungsregeln",
              "floor_ceiling": "Floor-and-Ceiling (Bengen 2001)",
              "clyatt": "Clyatt 95-%-Regel",
              "ratchet": "Kitces-Ratchet",
              "endowment": "Endowment-/Yale-Regel (Tobin)",
              "one_over_n": "1/N (Restlaufzeit)",
              "vpw": "Variable Percentage Withdrawal (Bogleheads)",
              "abw": "Amortisationsbasierte Entnahme (ABW)",
              "cape": "CAPE-basierte Regel",
              "sensible": "Sensible Withdrawals",
              "hebeler": "Hebeler Autopilot II"}

_DEF_IT = ("level", "rate_pa")
_DEF_FREQ = ("year", "quarter", "month")


class _Dflt(float):
    """Voreinstellung eines Arguments (für R's ``missing()``)."""

    def __repr__(self):
        return repr(float(self))


class _DfltTrue:
    """Voreinstellung ``TRUE`` (für R's ``missing()``)."""

    def __bool__(self):
        return True

    def __repr__(self):
        return "True"


_D_TRUE = _DfltTrue()


def _match_arg(arg, choices):
    from .data_prep import _match_arg as _ma
    return _ma(arg, choices)


def _fmt1(x, **kw) -> str:
    r = _fmt.format(x, **kw)
    if isinstance(r, str):
        return r
    return ", ".join(str(s) for s in np.asarray(r, dtype=object).ravel())


def _fmt_nan(x, **kw) -> str:
    """``format()`` eines Rechenergebnisses: ``nan`` ist hier R's ``NaN`` (nicht NA)."""
    x = float(x)
    return _fmt1(_fmt.R_NAN if math.isnan(x) else x, **kw)


def _fmtv(x):
    """``format(x)`` eines Vektors -> Liste von Texten (gemeinsame Formatierung)."""
    r = _fmt.format(np.asarray(x, dtype=np.float64))
    if isinstance(r, str):
        return [r]
    return [str(s) for s in np.asarray(r, dtype=object).ravel()]


def _isnull_or(x, dflt):
    return dflt if x is None else x


def _is_result(x) -> bool:
    try:
        from .result import SimLevResult
    except ImportError:  # pragma: no cover
        SimLevResult = ()
    return isinstance(x, SimLevResult) or "SimLevResult" in getattr(x, "r_class", ())


def _rget(x, name, default=None):
    """Element eines SimLevResult (Attribut, Schlüssel) oder ``default``."""
    v = None
    if isinstance(x, Mapping):
        v = x.get(name)
    else:
        v = getattr(x, name, None)
        if v is None:
            try:
                v = x[name]
            except (KeyError, TypeError, AttributeError, IndexError):
                v = None
    return default if v is None else v


def _dates_days(d):
    return np.asarray(d).astype("datetime64[D]").astype(np.int64)


def _ymd(d):
    a = np.asarray(d).astype("datetime64[D]")
    y = a.astype("datetime64[Y]").astype(np.int64) + 1970
    m = a.astype("datetime64[M]").astype(np.int64) % 12 + 1
    return y, m


def _pow_vec(x, y):
    """``x ^ y`` elementweise (Recycling), R-Semantik."""
    x = np.atleast_1d(np.asarray(x, dtype=np.float64)).ravel()
    y = np.atleast_1d(np.asarray(y, dtype=np.float64)).ravel()
    n = max(len(x), len(y)) if len(x) and len(y) else 0
    x = np.resize(x, n)
    y = np.resize(y, n)
    return np.array([r_pow(a, b) for a, b in zip(x.tolist(), y.tolist())], dtype=np.float64)


def _apply_cols(M, f):
    """``apply(M, 2, f)``: Vektor bei Länge 1 je Spalte, sonst Matrix (Ergebnis x Spalten)."""
    res = [np.atleast_1d(np.asarray(f(M[:, j]), dtype=np.float64)) for j in range(M.shape[1])]
    if not res:
        return np.zeros(0)
    if all(len(r) == 1 for r in res):
        return np.array([r[0] for r in res])
    return np.column_stack(res)


def _vapply_mat(vecs, L):
    """``as.matrix(vapply(X, f, numeric(L)))`` (Länge 1 -> Spaltenvektor)."""
    if L == 1:
        return np.array([float(np.asarray(v).ravel()[0]) for v in vecs]).reshape(-1, 1)
    if not vecs:
        return np.zeros((L, 0))
    return np.column_stack([np.asarray(v, dtype=np.float64).ravel() for v in vecs])


def _as_matrix(x):
    """``as.matrix`` für Vektor/Matrix/DataFrame."""
    if isinstance(x, pd.DataFrame):
        return x.to_numpy(dtype=np.float64)
    a = np.asarray(x, dtype=np.float64)
    if a.ndim == 0:
        return a.reshape(1, 1)
    if a.ndim == 1:
        return a.reshape(-1, 1)
    return a


# ═══════════════════════════════════════════════════════════════════════════
# Regeln
# ═══════════════════════════════════════════════════════════════════════════

class WithdrawalRule(RList):
    """Entnahmeregel (R-Klasse ``c("withdrawal_rule", "list")``)."""

    r_class = ("withdrawal_rule", "list")

    def format(self) -> str:
        return _strip1(_cat_rule(self))


def _cat_rule(x) -> str:
    out = ["Entnahmeregel\n-------------\n", "  Typ:       %s (%s)\n" % (x["type"], _WD_LABELS[x["type"]])]
    if x["type"] not in ("one_over_n", "vpw", "abw", "cape", "hebeler"):
        out.append(_sp("  Rate:      %.2f %%\n", x["rate"]))
    t = x["type"]
    ex = ""
    if t == "vanguard":
        ex = _sp("  Ceiling/Floor (real): +%.2f %% / -%.2f %%\n", x["ceiling"], x["floor"])
    elif t == "guyton_klinger":
        ex = _sp("  Guardrails: +%.0f %% / -%.0f %%, Kürzung %.0f %%, Erhöhung %.0f %%, CPR bis %d J. vor Ende\n",
                 x["ceiling"], x["floor"], x["cut"], x["raise"], int(float(x["cpr_years"])))
    elif t == "floor_ceiling":
        ex = _sp("  Korridor:  -%.0f %% / +%.0f %% um reale Erstentnahme\n", x["floor"], x["ceiling"])
    elif t == "endowment":
        ex = _sp("  Glättung:  %.0f %%\n", x["smoothing"])
    elif t == "hebeler":
        ex = _sp("  Glättung:  %.0f %%, erwartete Realrendite %.2f %%\n", x["smoothing"], x["exp_return"])
    elif t == "vpw":
        ex = _sp("  Alter %d bis %d, erwartete Realrendite %.2f %%\n", int(float(x["age"])), int(float(x["max_age"])),
                 x["exp_return"])
    elif t == "abw":
        ex = _sp("  Erwartete Realrendite %.2f %%, Zielvermögen %.0f\n", x["exp_return"], x["fv"])
    elif t == "cape":
        ex = _sp("  Rate = %.2f %% + %.2f / CAPE\n", x["cape_a"], x["cape_b"])
    elif t == "ratchet":
        ex = _sp("  +%.0f %% bei Depot > %.2f x Start, alle %d Jahre\n", x["raise"], x["ratchet_threshold"],
                 int(float(x["ratchet_gap"])))
    elif t == "sensible":
        ex = _sp("  Zusatz: %.0f %% des realen Vorjahresgewinns\n", x["extra"])
    elif t == "clyatt":
        ex = _sp("  Mindestens %.0f %% der Vorjahresentnahme\n", x["floor95"])
    out.append(ex)
    if x["min_real"] > 0 or math.isfinite(x["max_real"]):
        out.append(_sp("  Grenzen:   %.0f bis %s (real)\n", x["min_real"], _fmt1(x["max_real"])))
    return "".join(out)


def _wshow(x) -> str:
    """``paste(format(x), collapse = ", ")`` (NULL -> "")."""
    if x is None:
        return ""
    return _rshow(x)


def _rshow(x) -> str:
    if x is None:
        return "NULL"
    if isinstance(x, (bool, np.bool_)):
        return "TRUE" if x else "FALSE"
    return _show(x)


def withdrawal_rule(type=tuple(_WD_RULES), rate=4, ceiling=None, floor=None, cut=10, raise_=10,  # noqa: A002
                    cpr_years=15, inflation_cap=math.inf, skip_inflation=True, smoothing=None, exp_return=None,
                    stock_share=60, age=65, max_age=100, fv=0, cape_a=1.75, cape_b=0.5, ratchet_threshold=1.5,
                    ratchet_gap=3, extra=10, floor95=95, min_real=0, max_real=math.inf, max_rate=100, **kwargs):
    """Entnahmeregel definieren (siehe R-Dokumentation ``withdrawal_rule``).

    ``raise`` ist in Python ein Schlüsselwort: Argument ``raise_`` (oder
    ``**{"raise": 5}``).

    Returns:
        :class:`WithdrawalRule`.
    """
    if "raise" in kwargs:
        raise_ = kwargs.pop("raise")
    if kwargs:
        k = next(iter(kwargs))
        _stop("unused argument (%s = %s)" % (k, _deparse(kwargs[k])))
    type = _match_arg(type, tuple(_WD_RULES))  # noqa: A001

    def chk(x, arg, lo=-math.inf, hi=math.inf, what="", inf_ok=False, null_ok=False):
        if x is None and null_ok:
            return
        v = _num_vec(x)
        if v is None or v.size != 1 or math.isnan(v[0]) or (not inf_ok and not math.isfinite(v[0])) or \
                v[0] < lo or v[0] > hi:
            _stop("withdrawal_rule: %s muss %s sein (erhalten: %s)." % (arg, what, _rshow(x)))

    v = _num_vec(rate)
    if v is None or v.size != 1 or not math.isfinite(v[0]) or v[0] < 0 or v[0] > 100:
        _stop("rate muss zwischen 0 und 100 Prozent liegen (z. B. 4; erhalten: %s)." % _rshow(rate))
    if 0 < rate < 0.2 and type in ("constant", "percent", "vanguard", "guyton_klinger"):
        _warn("rate wirkt wie eine Dezimalzahl. PROZENT-KONVENTION: 4 bedeutet 4 %.")
    chk(ceiling, "ceiling", 0, what="NULL oder eine Zahl >= 0 in Prozent (z. B. 20)", null_ok=True)
    chk(floor, "floor", 0, 100, what="NULL oder eine Zahl von 0 bis 100 in Prozent (z. B. 20)", null_ok=True)
    chk(cut, "cut", 0, 100, what="eine Zahl von 0 bis 100 in Prozent (z. B. 10)")
    chk(raise_, "raise", 0, what="eine Zahl >= 0 in Prozent (z. B. 10)")
    chk(cpr_years, "cpr_years", 0, what="eine Zahl von Jahren >= 0 (z. B. 15)")
    chk(inflation_cap, "inflation_cap", 0, what="eine Zahl >= 0 in Prozent oder Inf (unbegrenzt)", inf_ok=True)
    if not isinstance(skip_inflation, (bool, np.bool_)):
        _stop("withdrawal_rule: skip_inflation muss TRUE oder FALSE sein (erhalten: %s)." % _rshow(skip_inflation))
    chk(smoothing, "smoothing", 0, 100, what="NULL oder eine Zahl von 0 bis 100 in Prozent (z. B. 70)", null_ok=True)
    chk(exp_return, "exp_return", -99.99, what="NULL oder eine Zahl in Prozent p. a. über -100 (z. B. 3.5)",
        null_ok=True)
    chk(stock_share, "stock_share", 0, 100, what="eine Zahl von 0 bis 100 in Prozent (z. B. 60)")
    chk(age, "age", 0, what="ein Alter in Jahren >= 0 (z. B. 65)")
    chk(max_age, "max_age", 0, what="ein Alter in Jahren >= 0 (z. B. 100)")
    if type == "vpw" and age >= max_age:
        _stop("withdrawal_rule('vpw'): age (%s) muss kleiner als max_age (%s) sein." % (_fmt1(age), _fmt1(max_age)))
    chk(fv, "fv", 0, what="ein Geldbetrag >= 0 (reales Zielvermögen)")
    chk(cape_a, "cape_a", 0, 100, what="eine Zahl von 0 bis 100 in Prozent (z. B. 1.75)")
    chk(cape_b, "cape_b", 0, what="eine Zahl >= 0 (Faktor auf 1 / CAPE, z. B. 0.5)")
    chk(ratchet_threshold, "ratchet_threshold", 0, what="ein Faktor > 0 (z. B. 1.5 = 150 %)")
    chk(ratchet_gap, "ratchet_gap", 0, what="eine Zahl von Jahren >= 0 (z. B. 3)")
    chk(extra, "extra", 0, 100, what="eine Zahl von 0 bis 100 in Prozent (z. B. 10)")
    chk(floor95, "floor95", 0, 100, what="eine Zahl von 0 bis 100 in Prozent (z. B. 95)")
    chk(min_real, "min_real", 0, what="ein Geldbetrag >= 0")
    chk(max_real, "max_real", 0, what="ein Geldbetrag >= 0 oder Inf", inf_ok=True)
    if min_real > max_real:
        _stop("withdrawal_rule: min_real (%s) darf nicht größer als max_real (%s) sein."
              % (_fmt1(min_real), _fmt1(max_real)))
    chk(max_rate, "max_rate", 0, 100, what="eine Zahl von 0 bis 100 in Prozent (z. B. 100)")
    if type == "vpw" and max_rate == 0:
        _stop("withdrawal_rule('vpw'): max_rate = 0 erlaubt keine Entnahme; Höchstsatz in Prozent > 0 angeben "
              "(z. B. 100).")
    frac = [("ceiling", _NAN if ceiling is None else float(ceiling)), ("floor", _NAN if floor is None else float(floor)),
            ("cut", float(cut)), ("raise", float(raise_)), ("smoothing", _NAN if smoothing is None else float(smoothing)),
            ("inflation_cap", float(inflation_cap)), ("extra", float(extra)), ("floor95", float(floor95)),
            ("max_rate", float(max_rate))]
    frac = [(k, v) for k, v in frac if not math.isnan(v) and 0 < v < 0.2]
    if frac:
        a = _fmtv([v for _, v in frac])
        b = _fmtv([100 * v for _, v in frac])
        _warn("withdrawal_rule: %s wirkt wie ein Anteil; PROZENT-KONVENTION: 5 bedeutet 5 %% (gemeint vermutlich %s)."
              % (", ".join("%s = %s" % (k, s) for (k, _), s in zip(frac, a)),
                 ", ".join("%s = %s" % (k, s) for (k, _), s in zip(frac, b))))
    dflt = {"vanguard": (5, 2.5), "guyton_klinger": (20, 20), "floor_ceiling": (20, 15)}.get(type, (0, 0))
    ceiling = dflt[0] if ceiling is None else ceiling
    floor = dflt[1] if floor is None else floor
    smoothing = (75 if type == "hebeler" else 70) if smoothing is None else smoothing
    exp_return = (5.0 * stock_share / 100 + 1.9 * (1 - stock_share / 100)) if exp_return is None else exp_return
    return WithdrawalRule([
        ("type", type), ("rate", rate), ("ceiling", ceiling), ("floor", floor), ("cut", cut), ("raise", raise_),
        ("cpr_years", cpr_years), ("inflation_cap", inflation_cap), ("skip_inflation", bool(skip_inflation)),
        ("smoothing", smoothing), ("exp_return", exp_return), ("age", age), ("max_age", max_age), ("fv", fv),
        ("cape_a", cape_a), ("cape_b", cape_b), ("ratchet_threshold", ratchet_threshold),
        ("ratchet_gap", ratchet_gap), ("extra", extra), ("floor95", floor95), ("min_real", min_real),
        ("max_real", max_real), ("max_rate", max_rate)])


def _deparse(v) -> str:
    from ._rnum import r_deparse
    return r_deparse(v)


def _is_rule(x) -> bool:
    return isinstance(x, WithdrawalRule) or "withdrawal_rule" in getattr(x, "r_class", ())


def _wd_param_vector(rule):
    """Parametervektor für den Kern (Reihenfolge = enum in withdrawal_core.cpp)."""
    r = rule
    f = float
    return np.array([f(r["rate"]) / 100, f(r["ceiling"]) / 100, f(r["floor"]) / 100, f(r["cut"]) / 100,
                     f(r["raise"]) / 100, f(r["cpr_years"]), f(r["inflation_cap"]) / 100, f(r["smoothing"]) / 100,
                     f(r["exp_return"]) / 100, f(r["cape_a"]) / 100, f(r["cape_b"]), f(r["ratchet_threshold"]),
                     f(r["ratchet_gap"]), f(r["extra"]) / 100, f(r["min_real"]), f(r["max_real"]), f(r["age"]),
                     f(r["max_age"]), f(r["fv"]), f(r["floor95"]) / 100,
                     1.0 if r["skip_inflation"] is True or r["skip_inflation"] is np.True_ else 0.0,
                     f(r["max_rate"]) / 100])


def _wd_ppy(frequency):
    """Perioden je Jahr (``.wd_ppy``)."""
    m = {"year": 1, "quarter": 4, "month": 12}
    if isinstance(frequency, str) and frequency in m:
        return m[frequency]
    _stop("frequency muss 'year', 'quarter' oder 'month' sein.")


def _period_ends(dates, frequency):
    """Letzte Zeile je Kalenderperiode (1-basiert), Port von ``.period_ends``."""
    y, m = _ymd(dates)
    if frequency == "year":
        key = y
    elif frequency == "quarter":
        key = y * 10 + (m - 1) // 3
    else:
        key = y * 100 + m
    if not len(key):
        return np.zeros(0, dtype=np.int64)
    chg = np.concatenate([key[1:] != key[:-1], [True]])
    return np.flatnonzero(chg) + 1


# ═══════════════════════════════════════════════════════════════════════════
# withdrawal_paths-Objekte, Kohorten
# ═══════════════════════════════════════════════════════════════════════════

class WithdrawalPaths(RList):
    """Periodenmatrizen für die Entnahme (R-Klasse ``withdrawal_paths``)."""

    r_class = ("withdrawal_paths",)


def _is_wp(x) -> bool:
    return isinstance(x, WithdrawalPaths) or "withdrawal_paths" in getattr(x, "r_class", ())


def _fill_locf(v):
    from .backcast import _fill_na
    return np.asarray(_fill_na(np.asarray(v, dtype=np.float64), "locf"), dtype=np.float64)


def _to_date(x, what):
    from .data_prep import _to_date as _td
    return _td(x, what)


def _df_col(data, name):
    if isinstance(data, pd.DataFrame):
        return data[name].to_numpy()
    return np.asarray(data[name])


@_quiet
def withdrawal_cohorts(data, price="value", inflation=None, years=30, frequency=_DEF_FREQ, step=("month", "year"),
                       wrap=False, cape=None, base_rate=None, inflation_type=_DEF_IT):
    """Historische Entnahme-Kohorten bilden (siehe R-Dokumentation ``withdrawal_cohorts``).

    Args:
        data: ``DataFrame`` mit ``date`` und Kursspalte oder ein ``SimLevResult``.

    Returns:
        :class:`WithdrawalPaths`.
    """
    it_given = inflation_type is not _DEF_IT
    frequency = _match_arg(frequency, _DEF_FREQ)
    step = _match_arg(step, ("month", "year"))
    inflation_type = _match_arg(inflation_type, _DEF_IT)
    if _is_result(data):
        if isinstance(inflation, str) or cape is not None or base_rate is not None:
            _stop("Bei einem SimLevResult sind nur numerische Inflation und keine Zusatzspalten möglich.")
        data = result_index(data)
        price = "value"
    names = [str(c) for c in data.columns] if isinstance(data, pd.DataFrame) else list(data.keys())
    if not all(c in names for c in ("date", price)):
        _stop("data braucht 'date' und die Kursspalte.")
    at = data.attrs.get("aux_type") if isinstance(data, pd.DataFrame) else None
    attr_rate = False
    if isinstance(inflation, str) and at is not None:
        nm = _names(at) or []
        vals = _values(at)
        attr_rate = inflation in nm and vals[nm.index(inflation)] == "rate"
    if attr_rate and it_given and inflation_type != "rate_pa":
        _stop(("inflation_type = '%s' passt nicht zu aux_type['%s'] = 'rate' (Attribut aus bootstrap_data()); "
               "inflation_type weglassen oder 'rate_pa' angeben.") % (inflation_type, inflation))
    infl_rate = isinstance(inflation, str) and (attr_rate or inflation_type == "rate_pa")
    dd = _to_date(_df_col(data, "date"), "withdrawal_cohorts: data$date")
    o = np.argsort(_dates_days(dd), kind="stable")
    dates = dd[o]

    def col(name):
        src = pd.Series(_df_col(data, name))
        v = np.array(pd.to_numeric(src, errors="coerce"), dtype=np.float64)
        if src.dtype.kind != "f":              # as.numeric: Fehlendes/Unlesbares → NA (Float-Werte behalten ihr Bitmuster)
            keep = np.array([isinstance(z, (float, np.floating)) for z in src.tolist()], dtype=bool)
            v[np.isnan(v) & ~keep] = _NA
        return v[o]

    px = _fill_locf(col(price))
    ends = _period_ends(dates, "month")
    mdates = dates[ends - 1]
    mpx = px[ends - 1]
    y, m = _ymd(mdates)
    mi = y * 12 + m
    gap = np.flatnonzero(np.diff(mi) != 1)
    if len(gap):
        _stop(("withdrawal_cohorts braucht l\u00fcckenlose Monatsdaten (mindestens ein Datum je Kalendermonat), "
               "aber nach %s folgt %s%s.") % (
            str(mdates[gap[0]]), str(mdates[gap[0] + 1]),
            (" (Jahresdaten? Dann Jahresrenditen als Matrix Jahre x Kohorten an withdrawal_simulation() \u00fcbergeben)"
             if r_median(np.diff(mi).astype(np.float64)) >= 12 else "")))
    if inflation is None:
        cpi = np.ones(len(ends))
    elif infl_rate:
        v = _fill_locf(col(inflation))
        dt = np.diff(_dates_days(dates)).astype(np.float64) / 365.25
        lvf = r_cumprod(np.concatenate([[1.0], _pow_vec(1 + v[1:] / 100, dt)]))
        lv = lvf[ends - 1]
        f = lv[1:] / lv[:-1]
        bad = ~np.isfinite(f) | (f <= 0)
        if bad.any():
            _stop("Spalte '%s' (Rate in Prozent p. a.) ergibt nicht endliche oder nicht positive Monatsfaktoren "
                  "(z. B. %s; Rate <= -100 %%?)." % (inflation, _fmt_nan(f[bad][0], digits=4)))
        cpi = lv
    elif isinstance(inflation, str):
        cpi = _fill_locf(col(inflation))[ends - 1]
    else:
        cpi = _pow_vec(1 + float(inflation) / 100,
                       (_dates_days(mdates) - _dates_days(mdates[:1])[0]).astype(np.float64) / 365.25)
    capev = _fill_locf(col(cape))[ends - 1] if cape is not None else None
    brv = _fill_locf(col(base_rate))[ends - 1] if base_rate is not None else None
    mret = mpx[1:] / mpx[:-1]
    minf = cpi[1:] / cpi[:-1]
    nm = len(mret)
    ppy = _wd_ppy(frequency)
    mpp = 12 / ppy
    yv = _num_vec(years)
    if yv is None or yv.size != 1 or not math.isfinite(yv[0]) or yv[0] <= 0 or \
            abs(yv[0] * 12 - _r_round0(yv[0] * 12)) > 1e-8 or math.fmod(_r_round0(yv[0] * 12), mpp) != 0:
        _stop("years muss eine positive Zahl sein, die ganze Perioden der frequency '%s' ergibt (bei 'year' ganze "
              "Jahre; erhalten: %s)." % (frequency, _show(years)))
    len_m = int(_r_round0(float(years) * 12))
    mpp = int(mpp)
    if step == "month":
        starts = np.arange(1, nm + 1)
    else:
        if nm < 1:
            _stop("wrong sign in 'by' argument")
        starts = np.arange(1, nm + 1, 12)
    if not wrap:
        starts = starts[starts + len_m - 1 <= nm]
    if not len(starts):
        _stop("Zu kurze Historie für die gewählte Kohortenlänge.")

    def take(v, s):
        return v[((s - 1 + np.arange(1, len_m + 1) - 1) % nm)]

    def agg(M):
        if mpp == 1:
            return M
        res = _apply_cols(M, lambda c: [r_prod(c[i:i + mpp]) for i in range(0, len(c), mpp)])
        return res

    Rm = agg(np.column_stack([take(mret, s) for s in starts]))
    Im = agg(np.column_stack([take(minf, s) for s in starts]))
    ns = len(starts)

    def to_mat(A):
        A = np.asarray(A, dtype=np.float64)
        return A.reshape(-1, ns, order="F") if A.ndim == 1 else A

    def pick_start(v):
        if v is None:
            return None
        Mx = np.column_stack([take(v[:-1], s) for s in starts])
        return Mx[np.arange(0, len_m, mpp), :]

    return WithdrawalPaths([
        ("returns", to_mat(Rm)), ("inflation", to_mat(Im)), ("cape", pick_start(capev)),
        ("base_rate", pick_start(brv)), ("frequency", frequency), ("start_dates", mdates[starts - 1]),
        ("historical", True), ("wrap", bool(wrap)), ("source", price)])


@_quiet
def result_index(x, base=100):
    """Zeitgewichteter Wertindex eines Simulationsergebnisses.

    Returns:
        ``DataFrame`` mit ``date``, ``value``, ``worth``, ``flows``.
    """
    if not _is_result(x):
        _stop("x muss ein SimLevResult (Ergebnis von simulation()) sein.")
    w = np.asarray(_rget(x, "worth"), dtype=np.float64).ravel()
    rep = _rget(x, "report", {})
    fls = [np.asarray(_get(a, "flows"), dtype=np.float64).ravel() for a in (rep.values() if isinstance(rep, Mapping)
                                                                          else rep)]
    if fls and len(w) > 1:
        M = np.column_stack(fls)
        fl = np.cumsum(M.astype(LD), axis=1)[:, -1].astype(np.float64)
    elif fls:
        fl = np.array([float(f[0]) for f in fls])
    else:
        fl = np.zeros(0)
    twr = _rget(x, "twr_index")
    if twr is not None and len(np.asarray(twr).ravel()) == len(w):
        idx = np.asarray(twr, dtype=np.float64).ravel()
    else:
        with np.errstate(divide="ignore", invalid="ignore"):
            g = np.concatenate([[1.0], (w[1:] - fl[1:]) / w[:-1]])
        g[~np.isfinite(g)] = 1.0
        idx = r_cumprod(g)
    dates = np.asarray(_rget(x, "dates"))
    if dates.dtype.kind in "iuf":
        dates = (np.datetime64("1970-01-01", "D") + dates.astype(np.int64).astype("timedelta64[D]"))
    else:
        dates = dates.astype("datetime64[D]")
    return pd.DataFrame({"date": dates, "value": base * idx, "worth": w, "flows": fl})


@_quiet
def _anniv_ends(dates, frequency):
    """Periodenenden als Jahrestage ab Startdatum (1-basierte Zeilen), Port von ``.anniv_ends``."""
    from .data_prep import _add_months
    step = {"year": 12, "quarter": 3, "month": 1}.get(frequency)
    d = np.asarray(dates).astype("datetime64[D]")
    d0, d1 = d[0], d[-1]
    y0, m0 = _ymd(d[:1])
    y1, m1 = _ymd(d[-1:])
    nm = int((y1[0] - y0[0]) * 12 + m1[0] - m0[0])
    last = (nm // step) * step
    ks = np.arange(0, last + 1, step) if last >= 0 else np.zeros(0, dtype=np.int64)
    tg = np.asarray(_add_months(d0, ks)).astype("datetime64[D]")
    tg = tg[tg <= d1]
    fi = np.searchsorted(_dates_days(d), _dates_days(tg), side="right")
    out = []
    for v in fi.tolist():
        if v not in out:
            out.append(v)
    return np.array(out, dtype=np.int64)


def _aux_kind(cfg, inflation, it_given, inflation_type):
    sets = list(_get(cfg, "aux_type_set", []) or [])
    if not isinstance(inflation, str) or inflation not in sets:
        return None
    at = _get(cfg, "aux_type")
    nm = _names(at) or []
    k = _values(at)[nm.index(inflation)]
    it = "level" if k == "level" else "rate_pa"
    if it_given and inflation_type != it:
        _stop("inflation_type = '%s' passt nicht zu aux_type['%s'] = '%s' in bootstrap_config(); inflation_type "
              "weglassen oder '%s' angeben." % (inflation_type, inflation, k, it))
    return k


def _is_result_list(x) -> bool:
    if isinstance(x, Mapping) and not isinstance(x, RList):
        vals = list(x.values())
    elif isinstance(x, (list, tuple)):
        vals = list(x)
    else:
        return False
    return bool(vals) and all(_is_result(v) for v in vals)


@_quiet
def withdrawal_paths(x, column=None, strategy=None, inflation=None, inflation_type=_DEF_IT, frequency=_DEF_FREQ,
                     dates=None, start_date="2000-01-01", cape=None):
    """Pfade in Perioden-Renditen für Entnahmen umwandeln (siehe R-Dokumentation).

    Args:
        x: ``SimLevBootstrapStudy``, Liste von ``SimLevResult`` oder ``bootstrap_result``.

    Returns:
        :class:`WithdrawalPaths`.
    """
    it_given = inflation_type is not _DEF_IT
    frequency = _match_arg(frequency, _DEF_FREQ)
    inflation_type = _match_arg(inflation_type, _DEF_IT)
    if inflation is not None:
        ok_inf = isinstance(inflation, str) or (_num1(inflation))
        if isinstance(inflation, (list, tuple, np.ndarray, pd.Series)) or not ok_inf:
            _stop("inflation muss NULL, eine Zahl (Prozent p. a.) oder der Name einer Zusatzreihe sein.")

    def infl_from(n_per, n_paths, ends_dates):
        if inflation is None:
            return np.ones((n_per, n_paths))
        if isinstance(inflation, str):
            return None
        f = _pow_vec(1 + float(inflation) / 100, np.diff(_dates_days(ends_dates)).astype(np.float64) / 365.25)
        return np.resize(f, n_per * n_paths).reshape((n_per, n_paths), order="F")

    def mk(R, I, C, w, src, freq):
        return WithdrawalPaths([
            ("returns", _as_matrix(R)), ("inflation", _as_matrix(I)), ("cape", _as_matrix(C) if C is not None else None),
            ("base_rate", None), ("frequency", freq), ("start_dates", None), ("historical", False), ("weights", w),
            ("source", src)])

    # 1) Gespeicherte Bootstrap-Studie
    if _is_study(x):
        if x.get("returns") is None:
            _stop("Die Studie enthält keine Periodenrenditen; bootstrap_study(..., keep_returns = 'year') "
                  "verwenden.")
        rets = x["returns"]
        strategy = list(rets.keys())[0] if strategy is None else strategy
        if strategy not in rets:
            _stop("Strategie '%s' nicht gespeichert. Verfügbar: %s" % (strategy, ", ".join(rets.keys())))
        freq = x["returns_frequency"]
        R = np.asarray(rets[strategy], dtype=np.float64)
        ok = np.isnan(R).sum(axis=0) == 0
        if isinstance(inflation, str):
            ar = x.get("aux_returns") or {}
            if ar.get(inflation) is None:
                _stop("Zusatzreihe '%s' nicht gespeichert (keep_aux)." % inflation)
            kind = _aux_kind(x["config"], inflation, it_given, inflation_type)
            if kind is None and it_given and inflation_type == "rate_pa":
                _stop(("inflation_type = 'rate_pa': die mit keep_aux gespeicherten Faktoren der Zusatzreihe '%s' sind "
                       "die Niveau-Variante (Reihe nicht in aux_type genannt). Für eine Rate in Prozent p. a. "
                       "aux_type = c(%s = 'rate') in bootstrap_config() angeben und die Studie neu rechnen.")
                      % (inflation, inflation))
            I0 = np.asarray(ar[inflation], dtype=np.float64)
            r = I0[:, ok]
            bad = ~np.isfinite(r) | (r <= 0)
            if bad.any():
                first = r.ravel(order="F")[bad.ravel(order="F")][0]
                if kind == "rate":
                    msg = "Zusatzreihe '%s' (aux_type 'rate') ergibt nicht endliche oder nicht positive Periodenfaktoren (z. B. %s)."
                else:
                    msg = ("Zusatzreihe '%s' ist kein positives Niveau (gespeicherte Periodenverhältnisse nicht "
                           "endlich oder <= 0, z. B. %s); für eine Rate in Prozent p. a. aux_type = c(<Name> = "
                           "'rate') in bootstrap_config() angeben.")
                _stop(msg % (inflation, _fmt_nan(first, digits=4)))
            I = I0
        else:
            I = infl_from(R.shape[0], R.shape[1], x["returns_dates"])
        w = x.get("path_weights")
        return mk(R[:, ok], I[:, ok], None, None if w is None else np.asarray(w, dtype=np.float64)[ok],
                  "study:" + strategy, freq)
    # 2) Liste von simulation()-Ergebnissen
    if not _is_boot_result(x) and _is_result_list(x):
        if isinstance(inflation, str):
            _stop("Bei Ergebnislisten ist 'inflation' ein Prozentsatz p. a.")
        lst = list(x.values()) if isinstance(x, Mapping) else list(x)
        idx = [result_index(r) for r in lst]
        ends = _anniv_ends(idx[0]["date"].to_numpy(), frequency)
        if len(ends) < 2:
            _stop("Ergebnisse zu kurz für eine volle Periode.")
        vecs = []
        for d in idx:
            if len(d) != len(idx[0]):
                _stop("Alle Ergebnisse müssen gleich lang sein.")
            v = d["value"].to_numpy()[ends - 1]
            vecs.append(v[1:] / v[:-1])
        R = _vapply_mat(vecs, len(ends) - 1)
        return mk(R, infl_from(R.shape[0], R.shape[1], idx[0]["date"].to_numpy()[ends - 1]), None, None, "results",
                  frequency)
    # 3) bootstrap()-Pfade
    if not _is_boot_result(x):
        _stop("x muss ein bootstrap_result, eine Liste von SimLevResult oder eine SimLevBootstrapStudy sein.")
    if column is None:
        _stop("Bei bootstrap_result muss 'column' angegeben werden.")
    P1 = x["paths"][0]
    cn = [str(c) for c in P1.columns]
    if column not in cn:
        _stop("Spalte '%s' nicht im Pfad. Verfügbar: %s" % (column, ", ".join(cn)))
    nr = P1.shape[0]
    if dates is None:
        d0 = np.asarray(_to_date(start_date, "start_date")).astype("datetime64[D]").ravel()[0]
        dates = d0 + np.arange(nr).astype("timedelta64[D]")
    else:
        dates = np.asarray(_to_date(dates, "dates")).astype("datetime64[D]")
        if len(dates) != nr:
            _stop("dates hat Länge %d, die Pfade haben %d Zeilen (path_length + 1); ein Datum je Pfadzeile angeben."
                  % (len(dates), nr))
        if np.isnat(dates).any() or (np.diff(_dates_days(dates)) <= 0).any():
            _stop("dates muss streng aufsteigend sein und darf kein NA enthalten.")
    ends = _anniv_ends(dates, frequency)
    if len(ends) < 2:
        _stop("Pfade zu kurz für eine volle Periode der gewählten frequency.")
    e1 = ends[1:] - 1
    e0 = ends[:-1] - 1

    def per(v):
        v = np.asarray(v, dtype=np.float64)
        return v[e1] / v[e0]

    n_per = len(ends) - 1
    R = _vapply_mat([per(P[column].to_numpy()) for P in x["paths"]], n_per)
    I = infl_from(R.shape[0], R.shape[1], dates[ends - 1])
    if I is None:
        if inflation not in cn:
            _stop("Zusatzreihe '%s' nicht im Pfad. Verfügbar: %s" % (inflation, ", ".join(cn)))
        kind = _aux_kind(_get(x, "config", {}), inflation, it_given, inflation_type)
        if kind is not None:
            inflation_type = "level" if kind == "level" else "rate_pa"
        dt = np.diff(_dates_days(dates)).astype(np.float64) / 365.25
        vecs = []
        for P in x["paths"]:
            if inflation_type == "rate_pa":
                v = P[inflation].to_numpy(dtype=np.float64)
                r = per(r_cumprod(np.concatenate([[1.0], _pow_vec(1 + v[1:] / 100, dt)])))
                bad = ~np.isfinite(r) | (r <= 0)
                if bad.any():
                    _stop("Zusatzreihe '%s' (Rate in Prozent p. a.) ergibt nicht endliche oder nicht positive "
                          "Periodenfaktoren (z. B. %s; Rate <= -100 %%?)." % (inflation, _fmt_nan(r[bad][0], digits=4)))
                vecs.append(r)
                continue
            lv = P.attrs.get("aux_level") if isinstance(P, pd.DataFrame) else None
            if kind == "level":
                v = P[inflation].to_numpy(dtype=np.float64)
            elif lv is not None and inflation in [str(c) for c in lv.columns]:
                v = lv[inflation].to_numpy(dtype=np.float64)
            elif _get(x, "method") in ("wild", "reset"):
                v = P[inflation].to_numpy(dtype=np.float64)
            else:
                _stop(("inflation_type = 'level': Pfad ohne Niveau-Variante der Reihe '%s' (Attribut aux_level); "
                       "beim Verfahren '%s' springen die Originalwerte an Blockgrenzen. Pfade mit bootstrap() neu "
                       "erzeugen.") % (inflation, _get(x, "method")))
            r = per(v)
            if (~np.isfinite(r) | (r <= 0)).any():
                _stop("Zusatzreihe '%s' ist kein positives Niveau (Verhältnisse nicht endlich oder <= 0); für "
                      "eine Rate inflation_type = 'rate_pa' verwenden." % inflation)
            vecs.append(r)
        I = _vapply_mat(vecs, n_per)
    C = None
    if cape is not None:
        cv = [P[cape].to_numpy(dtype=np.float64)[e0] for P in x["paths"]]
        C = np.array([v[0] for v in cv]) if n_per == 1 else np.column_stack(cv)
    w = _get(x, "weights")
    return mk(R, I, C, w, column, frequency)


# ═══════════════════════════════════════════════════════════════════════════
# Perfect Withdrawal Rate
# ═══════════════════════════════════════════════════════════════════════════

@_quiet
def _annual_real(wp):
    """Reale Jahresrenditen aus Perioden-Matrizen (Port von ``.annual_real``)."""
    ppy = _wd_ppy(wp["frequency"])
    real = np.asarray(wp["returns"], dtype=np.float64) / np.asarray(wp["inflation"], dtype=np.float64)
    if ppy == 1:
        return real
    npr = real.shape[0]
    ny = npr // ppy
    sub = real[:ny * ppy, :]
    return _apply_cols(sub, lambda c: [r_prod(c[i:i + ppy]) for i in range(0, len(c), ppy)])


@_quiet
def perfect_withdrawal_rate(real_returns, legacy=0):
    """Perfect Withdrawal Rate (PWR) je Pfad in Prozent.

    Args:
        real_returns: Matrix (Jahre x Pfade) realer Brutto-Jahresrenditen,
            Vektor (ein Pfad) oder :class:`WithdrawalPaths`.
        legacy: reales Zielvermögen als Anteil des Startvermögens (>= 0).
    """
    if _is_wp(real_returns):
        real_returns = _annual_real(real_returns)
    try:
        R = _as_matrix(real_returns)
    except (TypeError, ValueError):
        R = None
    if R is None or not R.size or np.isnan(R).any() or (~np.isfinite(R)).any():
        _stop("perfect_withdrawal_rate: real_returns muss eine Matrix endlicher realer Brutto-Jahresrenditen sein "
              "(1.05 = +5 %).")
    med = r_median(R.ravel(order="F"))
    if med < 0.5:
        _stop(("perfect_withdrawal_rate: real_returns sieht nicht wie Brutto-Renditen aus (Median %s); erwartet z. B. "
               "1.05 für +5 %%, nicht 0.05 (Nettorendite: 1 + r übergeben).") % _fmt1(med, digits=4))
    if (R < 0).any():
        _stop("perfect_withdrawal_rate: Brutto-Renditen in real_returns müssen >= 0 sein (0 = Totalverlust).")
    lv = _num_vec(legacy)
    if lv is None or lv.size != 1 or not math.isfinite(lv[0]) or lv[0] < 0:
        _stop("perfect_withdrawal_rate: legacy muss ein Anteil >= 0 sein (0.5 = 50 %% des Startvermögens; "
              "erhalten: %s)." % _show(legacy))
    legacy = float(lv[0])
    out = np.empty(R.shape[1])
    for j in range(R.shape[1]):
        r = R[:, j]
        tp = r_cumprod(r[::-1])[::-1]
        out[j] = (r_prod(r) - legacy) / r_sum(tp) * 100
    return out


# ═══════════════════════════════════════════════════════════════════════════
# Lots der Ansparphase
# ═══════════════════════════════════════════════════════════════════════════

def _lots_df(a):
    L = _get(a, "lots")
    return L


def _last_worth(report, nm):
    r = _get(report, nm)
    wv = np.asarray(_get(r, "worth", np.zeros(0)), dtype=np.float64).ravel()
    return wv[-1:] if len(wv) else wv


def _wd_held(ol, report, sv, tol=1e-12):
    """Am Ende der Ansparphase gehaltene Assets (Port von ``.wd_held``)."""
    out = []
    for nm in (ol.keys() if isinstance(ol, Mapping) else []):
        L = _lots_df(ol[nm])
        wv = _last_worth(report, nm)
        units = np.asarray(L["units"], dtype=np.float64) if L is not None and len(L) else np.zeros(0)
        if L is not None and len(L) > 0 and r_sum(units) > 0 and len(wv) == 1 and math.isfinite(wv[0]) and \
                wv[0] > tol * sv:
            out.append(nm)
    return out


@_quiet
def _wd_lots(ol, report, sv, tol=1e-12):
    """Offene Lots als FIFO-Bestand für den Kern (Port von ``.wd_lots``)."""
    n, basis, vp, group = [], [], [], []
    g = 0
    assets = 0.0
    for nm in _wd_held(ol, report, sv, tol):
        L = _lots_df(ol[nm])
        units = np.asarray(L["units"], dtype=np.float64)
        U = r_sum(units)
        keep = units > 0
        u = units[keep]
        pr = np.asarray(L["price"], dtype=np.float64)[keep]
        v = np.asarray(L["vp"], dtype=np.float64)[keep]
        wv = float(_last_worth(report, nm)[0])
        n.extend((u / U * wv).tolist())
        basis.extend((u * pr).tolist())
        vp.extend(v.tolist())
        group.extend([g] * len(u))
        g += 1
        assets = assets + wv
    cash = sv - assets
    if abs(cash) > tol * sv:
        n.append(cash)
        basis.append(cash)
        vp.append(0.0)
        group.append(g)
    return {"n": np.array(n), "basis": np.array(basis), "vp": np.array(vp), "group": np.array(group, dtype=np.int64)}


def _wd_fee_set(f) -> bool:
    """Ist eine Ordergebühr gesetzt (Zahl oder dict(fixed, percent, min, max))?"""
    if f is None:
        return False
    if isinstance(f, Mapping):
        vals = [f[k] for k in f.keys() if k in ("fixed", "percent", "min")]
        v = []
        for z in vals:
            v.extend(np.atleast_1d(np.asarray(z, dtype=object)).ravel().tolist())
    else:
        v = np.atleast_1d(np.asarray(f, dtype=object)).ravel().tolist()
    out = []
    for z in v:
        try:
            out.append(float(z))
        except (TypeError, ValueError):
            out.append(_NAN)
    return any(math.isfinite(z) and z != 0 for z in out)


# ═══════════════════════════════════════════════════════════════════════════
# withdrawal_simulation()
# ═══════════════════════════════════════════════════════════════════════════

class SimLevWithdrawal(RList):
    """Ergebnis von :func:`withdrawal_simulation` (R-Klasse ``SimLevWithdrawal``)."""

    r_class = ("SimLevWithdrawal",)

    def summary(self, probs=(0.05, 0.25, 0.5, 0.75, 0.95)):
        return _summary_wd(self, probs=probs)

    def plot(self, probs=(0.05, 0.25, 0.5, 0.75, 0.95), **kwargs):
        return _plot_wd(self, probs=probs, **kwargs)

    def format(self) -> str:
        return self.summary().format()


class SummarySimLevWithdrawal(RList):
    """Zusammenfassung (R-Klasse ``summary.SimLevWithdrawal``)."""

    r_class = ("summary.SimLevWithdrawal",)

    def format(self) -> str:
        return _strip1(_cat_summary_wd(self))


_D30 = _Dflt(30.0)
_D1000 = _Dflt(1000.0)
_D0 = _Dflt(0.0)
_D100 = _Dflt(100.0)
_D0LC = _Dflt(0.0)


def _is_logical1(v) -> bool:
    return isinstance(v, (bool, np.bool_))


@_quiet
def withdrawal_simulation(x, rule=None, start_value=1e6, inflation=0, frequency=_DEF_FREQ, strategy=None, years=None,
                          timing=("start", "end"), income=None, tax_mode=("none", "person"), tax_rate=26.375,
                          asset_bonus=_D30, sparer_pauschbetrag=1000, base_rate=3.20, vorabpauschale=_D_TRUE,
                          sale_cost=_D0, cost_basis=_D100, loss_carryforward=_D0LC, gamma=2, keep_paths=True,
                          horizon=None):
    """Entnahme-Simulation über viele Pfade (siehe R-Dokumentation ``withdrawal_simulation``).

    Args:
        x: :class:`WithdrawalPaths`, Renditematrix (Perioden x Pfade),
            ``SimLevResult``, Liste von ``SimLevResult`` oder Bootstrap-Studie.
        rule: :func:`withdrawal_rule` (Standard: konstante Regel mit 4 %).

    Returns:
        :class:`SimLevWithdrawal`.
    """
    if rule is None:
        rule = withdrawal_rule("constant")
    ab_missing = isinstance(asset_bonus, _Dflt)
    vp_missing = vorabpauschale is _D_TRUE
    sc_missing = isinstance(sale_cost, _Dflt)
    cb_missing = isinstance(cost_basis, _Dflt)
    lc_missing = isinstance(loss_carryforward, _Dflt)
    if vp_missing:
        vorabpauschale = True
    asset_bonus = float(asset_bonus) if ab_missing else asset_bonus
    sale_cost = float(sale_cost) if sc_missing else sale_cost
    cost_basis = float(cost_basis) if cb_missing else cost_basis
    loss_carryforward = float(loss_carryforward) if lc_missing else loss_carryforward
    freq_arg = frequency
    timing = _match_arg(timing, ("start", "end"))
    tax_mode = _match_arg(tax_mode, ("none", "person"))
    if horizon is not None and not _is_horizon(horizon):
        if not _num1(horizon) or float(horizon) <= 0:
            _stop("withdrawal_simulation: 'horizon' muss NULL, ein Objekt aus horizon_model() oder eine Zahl von Jahren "
                  "> 0 sein, nicht %s." % _show(horizon))
        horizon = horizon_model("fixed", years=horizon)
    if not _is_rule(rule):
        _stop("rule muss mit withdrawal_rule() erstellt werden.")
    if inflation is None:
        inflation = 0

    def chk(v, arg, what, lo=0.0, hi=math.inf):
        if not _num1(v) or float(v) < lo or float(v) > hi:
            _stop("withdrawal_simulation: '%s' muss %s sein, nicht %s." % (arg, what, _wshow(v)))

    def frac(v, arg, hi=1.0, unit="%"):
        if _num1(v) and 0 < float(v) < hi:
            _warn("withdrawal_simulation: %s = %s wird als %s %s gelesen (Prozent-Konvention); gemeint war vermutlich %s."
                  % (arg, _fmt1(v), _fmt1(v), unit, _fmt1(float(v) * 100)))

    chk(tax_rate, "tax_rate", "eine Zahl von 0 bis 100 in Prozent (z. B. 26.375)", 0, 100)
    frac(tax_rate, "tax_rate")
    chk(asset_bonus, "asset_bonus", "eine Zahl von 0 bis 100 in Prozent (z. B. 30)", 0, 100)
    frac(asset_bonus, "asset_bonus")
    chk(sparer_pauschbetrag, "sparer_pauschbetrag", "eine Zahl >= 0 (EUR je Planjahr, z. B. 1000)")
    chk(sale_cost, "sale_cost", "eine Zahl von 0 bis unter 100 in Prozent (z. B. 0.1)", 0, 99.999)
    chk(cost_basis, "cost_basis", "eine Zahl >= 0 in Prozent des Startwerts (z. B. 100)")
    frac(cost_basis, "cost_basis")
    chk(loss_carryforward, "loss_carryforward", "eine Zahl >= 0 (EUR)")
    chk(gamma, "gamma", "eine Zahl >= 0 (relative Risikoaversion, z. B. 2)")
    for a, v in (("vorabpauschale", vorabpauschale), ("keep_paths", keep_paths)):
        if not _is_logical1(v):
            _stop("withdrawal_simulation: '%s' muss TRUE oder FALSE sein, nicht %s." % (a, _wshow(v)))
    infl_is_mat = isinstance(inflation, (np.ndarray, pd.DataFrame)) and np.ndim(inflation) == 2
    if _is_num(inflation) or (isinstance(inflation, np.ndarray) and inflation.ndim < 2 and inflation.size == 1):
        chk(inflation, "inflation", "eine Zahl in Prozent p. a. über -100 (z. B. 2) oder eine Matrix", -99.999)
        frac(inflation, "inflation", hi=0.05, unit="% p. a.")
    br_is_mat = isinstance(base_rate, (np.ndarray, pd.DataFrame)) and np.ndim(base_rate) == 2
    if not br_is_mat:
        frac(base_rate, "base_rate", hi=0.05)
    if years is not None and (not _num1(years) or float(years) <= 0):
        _stop("years muss eine positive Zahl von Jahren sein (erhalten: %s)." % _show(years))
    if not br_is_mat and not _num1(base_rate):
        _stop("base_rate muss eine Zahl (Prozent) oder eine Matrix Perioden x Pfade sein.")
    if isinstance(income, Mapping) and income.get("amount") is not None and \
            not isinstance(income.get("amount"), (Mapping, list)):
        income = [income]
    if income is not None:
        okinc = isinstance(income, (list, tuple)) and all(
            isinstance(e, Mapping) and _num1(e.get("amount")) for e in income)
        if not okinc:
            _stop("income muss eine Liste von list(start = Jahr, end = Jahr, amount = Betrag) sein (amount: realer "
                  "Jahresbetrag).")
    lots = None
    adopted = {}
    spb_used1 = 0.0
    if _is_result(start_value):
        sres = start_value
        acc = result_index(sres)
        sv = float(acc["worth"].to_numpy()[-1])
        if not math.isfinite(sv) or sv <= 0:
            debt = _get(_rget(sres, "tax_report"), "open_tax_debt", 0)
            extra = ""
            if _num1(debt) and math.isfinite(float(debt)) and float(debt) > 0:
                extra = (" (offene, nicht gedeckte Steuerschuld der Ansparphase: %s EUR, tax_report$open_tax_debt)"
                         % _sp("%.2f", float(debt)))
            _stop("start_value: Endwert der Ansparphase (SimLevResult) ist %s EUR; withdrawal_simulation() braucht ein "
                  "positives Startvermögen%s." % (_sp("%.2f", sv), extra))
        ol = _rget(sres, "open_lots")
        if ol is None:
            ol = {}
        has_lots = len(ol) > 0 and all(
            isinstance(_get(a, "lots"), pd.DataFrame) and all(c in _get(a, "lots").columns for c in ("units", "price", "vp"))
            and _is_num(_get(a, "cash")) for a in ol.values())
        cb_given = not cb_missing
        report = _rget(sres, "report", {})
        if not cb_given:
            held = [_last_worth(report, nm) for nm in report.keys()]
            held_v = [float(h[0]) if len(h) == 1 else _NAN for h in held]
            if held_v and all(math.isfinite(h) for h in held_v) and all(h == 0 for h in held_v):
                cost_basis = 100.0
            elif has_lots:
                bs = [r_sum(np.asarray(_get(a, "lots")["units"], dtype=np.float64) *
                            np.asarray(_get(a, "lots")["price"], dtype=np.float64)) +
                      r_sum(np.asarray(_get(a, "lots")["vp"], dtype=np.float64)) + float(_get(a, "cash"))
                      for a in ol.values()]
                basis = r_sum(np.array(bs))
                cost_basis = 100 * basis / sv
                if tax_mode == "person":
                    lots = _wd_lots(ol, report, sv)
            else:
                if tax_mode == "person":
                    _warn("cost_basis: Näherung 100 x (Startwert brutto + Einzahlungen) / Endwert, da das "
                          "Ansparergebnis keine offenen Lots enthält (simulation() ohne tax_mode = 'person' oder "
                          "älteres Ergebnis); realisierte Gewinne und Cash zählen dabei als stille Reserven. "
                          "Für genaue Werte die Ansparphase mit tax_mode = 'person' rechnen oder cost_basis angeben.")
                inv = _rget(sres, "invested")
                inv = np.asarray(inv, dtype=np.float64).ravel() if inv is not None else np.zeros(0)
                start_gross = float(inv[0]) if len(inv) else float(acc["worth"].to_numpy()[0])
                invested = start_gross + r_sum(np.maximum(acc["flows"].to_numpy()[1:], 0))
                cost_basis = 100 * invested / sv
        if tax_mode == "person" and has_lots:
            hold_n = _wd_held(ol, report, sv)
            hold = [ol[nm] for nm in hold_n]
            reg = [str(_get(a, "regime", "investment_fund")) for a in hold]
            fund = [r == "investment_fund" for r in reg]
            mixed = any(fund) and not all(fund)
            if hold and not any(fund) and vp_missing:
                vorabpauschale = False
                adopted["vorabpauschale"] = False
            if mixed:
                _warn(("Am Ende gehaltene Assets mit verschiedenen Regimen (Investmentfonds: %s; andere: %s): "
                       "withdrawal_simulation() wendet Vorabpauschale (vorabpauschale = %s) und Teilfreistellung "
                       "(asset_bonus = %s %%) auf den ganzen Bestand an; beide werden nicht übernommen.")
                      % (", ".join(n for n, f in zip(hold_n, fund) if f), ", ".join(n for n, f in zip(hold_n, fund) if not f),
                         "TRUE" if vorabpauschale is True else "FALSE", _sp("%g", float(asset_bonus))))
            if any(r == "private_sale" for r in reg):
                _warn(("Assets mit Regime 'private_sale' (Paragraf 23 EStG: %s) am Ende der Ansparphase: Spekulationsfrist "
                       "und Freigrenze bildet withdrawal_simulation() nicht ab; deren Gewinne werden wie Fondsgewinne mit "
                       "Teilfreistellung asset_bonus = %s %% besteuert.")
                      % (", ".join(n for n, r in zip(hold_n, reg) if r == "private_sale"), _sp("%g", float(asset_bonus))))
            fs = [r != "private_sale" for r in reg]
            tfs_all = [float(_get(a, "asset_bonus", 0)) if r == "investment_fund" else 0.0 for a, r in zip(hold, reg)]
            tfs = [t for t, f in zip(tfs_all, fs) if f]
            fs_names = [n for n, f in zip(hold_n, fs) if f]
            if ab_missing and not mixed and tfs and all(fs) and all(abs(t - tfs[0]) < 1e-9 for t in tfs):
                asset_bonus = tfs[0]
                adopted["asset_bonus"] = asset_bonus
            elif not mixed and tfs and any(abs(t - float(asset_bonus)) > 1e-9 for t in tfs):
                _warn(("asset_bonus = %s %%, aber die am Ende gehaltenen Assets haben die Teilfreistellung %s; "
                       "withdrawal_simulation() rechnet mit einer Teilfreistellung für den ganzen Bestand "
                       "(asset_bonus passend angeben; bei verschiedenen Werten keine exakte Abbildung).")
                      % (_sp("%g", float(asset_bonus)), ", ".join(_sp("%s %g %%", n, t) for n, t in zip(fs_names, tfs))))
            tr = _rget(sres, "tax_report", {})
            ny_ = _get(tr, "next_year")

            def num1p(v):
                return _num1(v) and float(v) >= 0

            lc = _get(ny_, "loss_carryforward_capital") if isinstance(ny_, Mapping) and \
                num1p(_get(ny_, "loss_carryforward_capital")) else _get(tr, "loss_carryforward_capital")
            if lc_missing and num1p(lc):
                loss_carryforward = float(lc)
                adopted["loss_carryforward"] = float(lc)
            if isinstance(ny_, Mapping) and num1p(_get(ny_, "sparer_pauschbetrag_used")):
                spb_used1 = float(_get(ny_, "sparer_pauschbetrag_used"))
            spr = []
            for a in hold:
                s = _get(a, "asset_spread")
                spr.append(float(s) if _is_num(s) else _NA)
            if sc_missing and spr and not any(math.isnan(s) for s in spr):
                if all(abs(s - spr[0]) < 1e-12 for s in spr):
                    sale_cost = spr[0] / 2
                    adopted["sale_cost"] = sale_cost
                else:
                    _warn(("sale_cost nicht übernommen: die gehaltenen Assets haben verschiedene Spreads (%s); "
                           "withdrawal_simulation() rechnet mit einem Verkaufskostensatz für den ganzen Bestand "
                           "(sale_cost angeben).") % ", ".join(_sp("%s %g %%", n, s) for n, s in zip(hold_n, spr)))
            fee_set = [_wd_fee_set(_get(a, "order_fee")) for a in hold]
            if any(fee_set):
                _warn(("Ordergebühren der Ansparphase (%s) bildet withdrawal_simulation() beim Verkauf nicht ab; "
                       "gegebenenfalls in sale_cost (Prozent des Verkaufsbetrags) berücksichtigen.")
                      % ", ".join(n for n, f in zip(hold_n, fee_set) if f))
        if spb_used1 > 0:
            adopted["sparer_pauschbetrag_used_year1"] = spb_used1
        if lots is not None:
            adopted["lots"] = len(lots["n"])
        elif not cb_given and tax_mode == "person":
            adopted["cost_basis"] = cost_basis
        if adopted:
            parts = []
            for k, v in adopted.items():
                if k == "lots":
                    parts.append("%d Lots (FIFO)" % v)
                elif isinstance(v, (bool, np.bool_)):
                    parts.append("%s = %s" % (k, "TRUE" if v else "FALSE"))
                else:
                    parts.append("%s = %s" % (k, _fmt1(float(_fmt.signif(float(v), 8)))))
            _message("Hinweis: aus der Ansparphase übernommen: " + ", ".join(parts) + ".")
        start_value = sv
    if not _num1(start_value) or float(start_value) <= 0:
        _stop("start_value muss ein positiver Geldbetrag (Zahl > 0) oder ein SimLevResult sein (erhalten: %s)."
              % _wshow(start_value))
    start_value = float(start_value)
    src_taxed = False
    if _is_result(x):
        trx = _rget(x, "tax_report")
        tp = _get(trx, "total_taxes_paid")
        src_taxed = _num1(tp) and float(tp) > 0
        if not (_is_num(inflation)):
            _stop("Bei einem SimLevResult ist 'inflation' ein Prozentsatz p. a.")
        x = withdrawal_cohorts(x, inflation=inflation, years=30 if years is None else years,
                               frequency=_match_arg(freq_arg, _DEF_FREQ))
    elif _is_study(x) or _is_result_list(x):
        if not _is_study(x):
            lst = list(x.values()) if isinstance(x, Mapping) else list(x)
            src_taxed = any(_num1(_get(_rget(r, "tax_report"), "total_taxes_paid")) and
                            float(_get(_rget(r, "tax_report"), "total_taxes_paid")) > 0 for r in lst)
        x = withdrawal_paths(x, strategy=strategy, inflation=inflation, frequency=_match_arg(freq_arg, _DEF_FREQ))
    if src_taxed and tax_mode == "person" and vorabpauschale is True:
        _warn("Das Quellergebnis wurde mit Steuern gerechnet (Vorabpauschale im Index enthalten); vorabpauschale = FALSE "
              "oder eine Quelle mit tax_mode = 'none' vermeidet Doppelzählung.")
    if not _is_wp(x):
        frequency = _match_arg(freq_arg, _DEF_FREQ)
        try:
            R = _as_matrix(x)
        except (TypeError, ValueError):
            R = None
        if R is None or not R.size:
            _stop("x muss eine numerische Matrix (Perioden x Pfade) von Brutto-Periodenrenditen sein.")
        if (R[~np.isnan(R)] < 0).any():
            _stop("x muss Brutto-Periodenrenditen enthalten (z. B. 1.05 für +5 %).")
        if np.isnan(R).any():
            _stop("missing value where TRUE/FALSE needed")
        if r_median(R.ravel(order="F")) < 0.5:
            _stop("x muss Brutto-Periodenrenditen enthalten (z. B. 1.05 für +5 %).")
        if infl_is_mat and tuple(np.shape(inflation)) != R.shape:
            _stop("inflation als Matrix braucht dieselbe Dimension wie die Renditen (%d x %d), hat aber %d x %d."
                  % (R.shape[0], R.shape[1], np.shape(inflation)[0], np.shape(inflation)[1]))
        if not infl_is_mat and not _num1(inflation):
            _stop("inflation muss eine Zahl (Prozent p. a.) oder eine Matrix Perioden x Pfade sein.")
        if infl_is_mat:
            I = _as_matrix(inflation)
        else:
            I = np.full(R.shape, r_pow(1 + float(inflation) / 100, 1 / _wd_ppy(frequency)))
        x = WithdrawalPaths([("returns", R), ("inflation", I), ("cape", None), ("base_rate", None),
                             ("frequency", frequency), ("historical", False), ("start_dates", None), ("weights", None),
                             ("source", "matrix")])
    ppy = _wd_ppy(x["frequency"])
    R = x["returns"]
    I = x["inflation"]
    if not isinstance(R, np.ndarray) or R.ndim != 2 or not R.shape[0] or not R.shape[1]:
        _stop("Keine Renditen (leere Matrix bzw. keine Pfade).")
    R = np.asarray(R, dtype=np.float64)
    I = np.asarray(I, dtype=np.float64)
    if np.isnan(R).any() or np.isnan(I).any():
        _stop("Renditen/Inflation enthalten NA.")
    if I.shape != R.shape:
        _stop("Inflation (%d x %d) passt nicht zu den Renditen (%d x %d)." % (I.shape[0], I.shape[1], R.shape[0],
                                                                              R.shape[1]))
    xcape = x.get("cape")
    xbase = x.get("base_rate")
    if br_is_mat:
        base_rate = _as_matrix(base_rate)
        if xbase is None and base_rate.shape != R.shape:
            _stop("base_rate als Matrix braucht dieselbe Dimension wie die Renditen (%d x %d Perioden x Pfade), hat aber "
                  "%d x %d." % (R.shape[0], R.shape[1], base_rate.shape[0], base_rate.shape[1]))
    if years is not None:
        if abs(float(years) * ppy - _r_round0(float(years) * ppy)) > 1e-8:
            _stop("years = %s ergibt keine ganze Zahl von Perioden (%d je Jahr)." % (_fmt1(years), ppy))
        kr = min(R.shape[0], int(_r_round0(float(years) * ppy)))
        R = R[:kr, :]
        I = I[:kr, :]
        if xcape is not None:
            xcape = _as_matrix(xcape)[:kr, :]
        if xbase is not None:
            xbase = _as_matrix(xbase)[:kr, :]
        if br_is_mat:
            base_rate = base_rate[:kr, :]
    if R.shape[0] % ppy != 0:
        _warn("Periodenzahl ist kein Vielfaches eines Jahres; letztes Planjahr unvollständig.")
    ny = -(-R.shape[0] // ppy)
    nfy = R.shape[0] // ppy
    if rule["type"] == "cape" and xcape is None:
        _stop("Die CAPE-Regel braucht eine CAPE-Reihe (Argument cape in withdrawal_cohorts/withdrawal_paths).")
    CAPE = _as_matrix(xcape) if xcape is not None else np.zeros((R.shape[0], 0))
    if xbase is not None:
        BASE = _as_matrix(xbase)
    elif br_is_mat:
        BASE = base_rate
    else:
        BASE = np.full(R.shape, float(base_rate))
    inc = np.zeros(ny)
    for e in (income or []):
        s0 = e.get("start")
        s0 = 1 if s0 is None else s0
        e0 = e.get("end")
        e0 = math.inf if e0 is None else e0
        sv0 = _num_vec(s0)
        ev0 = _num_vec(e0)
        if sv0 is None or ev0 is None or sv0.size != 1 or ev0.size != 1 or math.isnan(sv0[0]) or math.isnan(ev0[0]) \
                or ev0[0] < sv0[0]:
            _stop("income: start und end müssen Planjahre mit start <= end sein (erhalten: start = %s, end = %s)."
                  % (_wshow(s0), _wshow(e0)))
        s1 = max(1, math.ceil(sv0[0]))
        e1 = min(ny, math.floor(ev0[0]) if math.isfinite(ev0[0]) else ny)
        if s1 <= e1:
            inc[s1 - 1:e1] = inc[s1 - 1:e1] + float(e["amount"])
    rp = _wd_param_vector(rule)
    t0 = time.time()
    core = _wcore.wd_simulate(
        R, I, CAPE, BASE, int(ppy), _WD_RULES[rule["type"]], rp, timing == "start", start_value, inc,
        tax_mode == "person", float(tax_rate) / 100, float(asset_bonus) / 100, float(sparer_pauschbetrag),
        vorabpauschale is True, float(sale_cost) / 100, float(cost_basis) / 100, float(loss_carryforward),
        keep_paths is True or horizon is not None,
        lots["n"] if lots is not None else np.zeros(0), lots["basis"] if lots is not None else np.zeros(0),
        lots["vp"] if lots is not None else np.zeros(0),
        lots["group"] if lots is not None else np.zeros(0, dtype=np.int64),
        max(0.0, float(sparer_pauschbetrag) - spb_used1) if spb_used1 > 0 else -1.0, horizon is not None)
    sp = core["spending"]
    w0 = sp[0, :].copy()
    gamma = float(gamma)

    def ce_fun(c):
        c = np.maximum(c, 1e-9 * start_value)
        if abs(gamma - 1) < 1e-12:
            from ._r import libm as _libm
            return float(_libm.exp(r_mean(np.asarray(_libm.log(c), dtype=np.float64))))
        return r_pow(r_mean(_pow_vec(c, 1 - gamma)), 1 / (1 - gamma))

    def dd_fun(c):
        m = r_cummax(c)
        return float(np.max(1 - c / m))

    ncol = sp.shape[1]

    def per_path(fun, H=None):
        H = np.full(ncol, ny) if H is None else H
        out = np.empty(ncol)
        for i in range(ncol):
            r = min(int(H[i]), nfy)
            out[i] = fun(sp[:r, i]) if r > 0 else _NA
        return out

    def col_means(M):
        return np.array([float(np.cumsum(M[:, j].astype(LD))[-1] / LD(M.shape[0])) if M.shape[0] else _NAN
                         for j in range(M.shape[1])])

    def col_sums(M):
        return np.array([float(np.cumsum(M[:, j].astype(LD))[-1]) if M.shape[0] else 0.0 for j in range(M.shape[1])])

    if ppy == 1 or R.shape[0] >= ppy:
        pwr = perfect_withdrawal_rate(_annual_real({"returns": R, "inflation": I, "frequency": x["frequency"]}))
    else:
        pwr = np.array([_NA])
    pwr = np.resize(np.asarray(pwr, dtype=np.float64), ncol)
    with np.errstate(divide="ignore", invalid="ignore"):
        dep = np.ceil(core["depletion_period"] / ppy)
    paths = pd.DataFrame({
        "success": core["failed"] == 0,
        "depletion_year": dep,
        "terminal_real": core["terminal_real"],
        "terminal_nominal": core["terminal_nominal"],
        "first_withdrawal": w0,
        "mean_spending": col_means(sp) if nfy == ny else per_path(r_mean),
        "min_spending": per_path(lambda c: float(np.min(c))),
        "spending_drawdown": per_path(dd_fun),
        "ce_spending": per_path(ce_fun),
        "total_spending": col_sums(sp),
        "taxes": core["taxes_real"],
        "pwr": pwr})
    if x.get("start_dates") is not None:
        paths["start"] = np.asarray(x["start_dates"]).astype("datetime64[D]")
    wealth = core["wealth"]
    if horizon is not None:
        H = _draw_horizon(horizon, R.shape[1])
        if H.max() > ny:
            _warn("Horizont bis %d Jahre, Pfade nur %d Jahre: längere Horizonte werden auf %d gekürzt."
                  % (int(H.max()), ny, ny))
            H = np.minimum(H, ny)
        dy = dep
        paths["success_full"] = paths["success"].to_numpy()
        paths["horizon"] = H.astype(np.int64)
        paths["success"] = np.isnan(dy) | (dy > H)
        paths["depletion_year"] = np.where(~np.isnan(dy) & (dy <= H), dy, _NA)
        cols = np.arange(len(H))
        paths["terminal_real"] = core["wealth_end"][H, cols]
        paths["taxes"] = core["taxes_end"][H, cols]
        paths["mean_spending"] = per_path(r_mean, H)
        paths["min_spending"] = per_path(lambda c: float(np.min(c)), H)
        paths["total_spending"] = np.array([r_sum(sp[:int(H[i]), i]) for i in range(len(H))])
        paths["spending_drawdown"] = per_path(dd_fun, H)
        paths["ce_spending"] = per_path(ce_fun, H)
        if ppy == 1:
            AR = _annual_real({"returns": R, "inflation": I, "frequency": x["frequency"]})
            paths["pwr"] = np.array([perfect_withdrawal_rate(AR[:int(H[i]), i:i + 1])[0] for i in range(len(H))])
        else:
            paths["pwr"] = _NA
        if keep_paths is not True:
            wealth = None
    w = x.get("weights")
    w = np.ones(R.shape[1]) if w is None else np.asarray(w, dtype=np.float64)
    return SimLevWithdrawal([
        ("paths", paths), ("spending", sp), ("planned", core["planned"]),
        ("wealth", wealth if keep_paths is True else None), ("rule", rule), ("start_value", start_value),
        ("frequency", x["frequency"]), ("years", ny), ("full_years", nfy), ("horizon", horizon),
        ("historical", x.get("historical") is True), ("weights", w), ("tax_mode", tax_mode), ("gamma", gamma),
        ("timing", timing), ("source", x.get("source")), ("adopted", adopted if adopted else None),
        ("elapsed", time.time() - t0)])


@_quiet
def withdrawal_max_rate(x, rule=None, success=0.95, lower=0.5, upper=20, tol=0.005, **kwargs):
    """Maximale Anfangsrate für eine Ziel-Erfolgsquote (Bisektion).

    Returns:
        Rate in Prozent (``float``) mit Attribut ``success`` (``result.success``);
        ``nan``, wenn schon ``lower`` die Zielquote verfehlt.
    """
    if rule is None:
        rule = withdrawal_rule("constant")
    if not _is_rule(rule):
        _stop("rule muss mit withdrawal_rule() erstellt werden.")
    if rule["type"] in ("one_over_n", "vpw", "abw", "cape", "hebeler"):
        _stop("withdrawal_max_rate: Die Regel '%s' nutzt rate nicht; eine Suche über rate ist dafür nicht "
              "möglich." % rule["type"])
    if not _num1(success) or float(success) <= 0 or float(success) > 1:
        hint = ""
        if _num1(success) and 1 < float(success) <= 100:
            hint = "; gemeint vermutlich %s" % _fmt1(float(success) / 100)
        _stop("withdrawal_max_rate: success muss ein Anteil mit 0 < success <= 1 sein (0.95 = 95 %%; erhalten: %s)%s."
              % (_show(success), hint))
    if not _num1(lower) or not _num1(upper) or lower < 0 or upper > 100 or lower >= upper:
        _stop("withdrawal_max_rate: lower und upper müssen Raten in Prozent mit 0 <= lower < upper <= 100 sein "
              "(erhalten: lower = %s, upper = %s)." % (_show(lower), _show(upper)))
    if not _num1(tol) or float(tol) <= 0:
        _stop("withdrawal_max_rate: tol muss eine Zahl > 0 in Prozentpunkten sein (z. B. 0.005; erhalten: %s)."
              % _show(tol))
    state = {"first": True}

    def f(rate):
        rl = WithdrawalRule(rule.items())
        rl["rate"] = rate
        if state["first"]:
            s = withdrawal_simulation(x, rl, keep_paths=False, **kwargs)
        else:
            with warnings.catch_warnings(), contextlib.redirect_stderr(io.StringIO()):
                warnings.simplefilter("ignore")
                s = withdrawal_simulation(x, rl, keep_paths=False, **kwargs)
        state["first"] = False
        return _weighted_mean(s["paths"]["success"].to_numpy(dtype=np.float64), s["weights"])

    s_lo = f(lower)
    if s_lo < success:
        return _Rate(_NA, s_lo)
    s_up = f(upper)
    if s_up >= success:
        return _Rate(upper, s_up)
    while upper - lower > tol:
        mid = (lower + upper) / 2
        s_mid = f(mid)
        if s_mid >= success:
            lower = mid
            s_lo = s_mid
        else:
            upper = mid
    return _Rate(lower, s_lo)


class _Rate(float):
    """Rate mit Attribut ``success`` (wie ``structure(rate, success = ...)``)."""

    def __new__(cls, value, success):
        obj = float.__new__(cls, value)
        obj.success = success
        return obj


# ═══════════════════════════════════════════════════════════════════════════
# Zusammenfassung, Ausgabe, Grafik
# ═══════════════════════════════════════════════════════════════════════════

@_quiet
def _summary_wd(obj, probs=(0.05, 0.25, 0.5, 0.75, 0.95)):
    p = obj["paths"]
    w = np.asarray(obj["weights"], dtype=np.float64)
    probs = np.atleast_1d(np.asarray(probs, dtype=np.float64))

    def wq(v):
        return _wquantile(np.asarray(v, dtype=np.float64), w, probs)

    def wm(v):
        return _weighted_mean(np.asarray(v, dtype=np.float64), w, na_rm=True)

    yrs = obj["years"]
    H = p["horizon"].to_numpy() if "horizon" in p.columns else None
    nfy = obj.get("full_years")
    nfy = yrs if nfy is None else nfy
    spm = np.asarray(obj["spending"], dtype=np.float64)

    def pick(y):
        j = np.arange(spm.shape[1]) if H is None else np.flatnonzero(H >= y)
        if y > nfy or not len(j):
            return np.full(len(probs), _NA)
        return _wquantile(spm[y - 1, j], w[j], probs)

    succ = p["success"].to_numpy(dtype=bool)
    sby = pd.DataFrame(np.vstack([pick(1), pick(10), pick(20), pick(30)]),
                       index=["Jahr 1", "Jahr 10", "Jahr 20", "Jahr 30"])
    pwr = p["pwr"].to_numpy(dtype=np.float64)
    if obj["historical"]:
        fin = pwr[~np.isnan(pwr)]
        if len(fin):
            swr = float(np.min(fin))
        else:
            _warn("no non-missing arguments to min; returning Inf")
            swr = math.inf
    else:
        swr = float(_wquantile(pwr, w, 0.05)[0])
    return SummarySimLevWithdrawal([
        ("rule", obj["rule"]), ("n_paths", len(p)), ("years", yrs), ("historical", obj["historical"]),
        ("success_rate", wm(succ)),
        ("depletion", _wquantile(p["depletion_year"].to_numpy(dtype=np.float64)[~succ], w[~succ], probs)
         if (~succ).any() else None),
        ("terminal_real", wq(p["terminal_real"])),
        ("preserve_rate", wm(p["terminal_real"].to_numpy() >= obj["start_value"])),
        ("first_withdrawal", wq(p["first_withdrawal"])),
        ("mean_spending", wq(p["mean_spending"])), ("min_spending", wq(p["min_spending"])),
        ("spending_drawdown", wq(p["spending_drawdown"])), ("ce_spending", wq(p["ce_spending"])),
        ("spending_by_year", sby), ("taxes", wq(p["taxes"])), ("pwr", wq(pwr)), ("swr", swr),
        ("probs", probs), ("start_value", obj["start_value"]), ("tax_mode", obj["tax_mode"]), ("gamma", obj["gamma"])])


def _cat_summary_wd(x) -> str:
    def q(v, pct=False):
        out = []
        for z in np.asarray(v, dtype=np.float64).ravel():
            if math.isnan(z):
                out.append(_sp("%10s", "–"))
            elif pct:
                out.append(_sp("%9.2f%%", z))
            else:
                out.append(_sp("%10.0f", z))
        return "".join(out)

    def fw(s):
        return _fmt.format(s, width=28)

    probs = np.asarray(x["probs"], dtype=np.float64)
    hdr = "".join(_sp("%10s", _sp("q%02d", _r_round0(100 * p))) for p in probs)
    L = "═" * 62
    out = ["\n%s\n" % L, "                 SimLev Entnahme-Simulation                    \n", "%s\n\n" % L]
    out.append("  Regel:            %s\n" % _WD_LABELS[x["rule"]["type"]])
    out.append(_sp("  Pfade:            %d %s über %d Jahre, Startvermögen %.0f\n", int(x["n_paths"]),
                   "historische Kohorten" if x["historical"] else "Pfade", int(x["years"]), float(x["start_value"])))
    out.append("  Steuern:          %s\n\n" % ("deutsche Privatperson (vereinfacht)" if x["tax_mode"] == "person"
                                              else "keine"))
    out.append(_sp("  Erfolgsquote:     %.1f %% (Depot reicht für alle geplanten Entnahmen)\n",
                   100 * x["success_rate"]))
    out.append(_sp("  Kapitalerhalt:    %.1f %% (reales Endvermögen >= Start)\n", 100 * x["preserve_rate"]))
    if x.get("depletion") is not None:
        out.append(_sp("  Erschöpfung:      Median im Jahr %.0f (bei gescheiterten Pfaden)\n",
                       float(np.asarray(x["depletion"])[math.ceil(len(probs) / 2) - 1])))
    out.append(_sp("  %s: %.2f %% der Startsumme\n",
                   "SWR historisch (min. PWR)" if x["historical"] else "SWR (5-%-Quantil PWR)", float(x["swr"])))
    out.append("\n  %s%s\n" % (fw("real, in Startkaufkraft"), hdr))
    out.append("  %s%s\n" % (fw("Endvermögen"), q(x["terminal_real"])))
    out.append("  %s%s\n" % (fw("Entnahme Jahr 1"), q(x["first_withdrawal"])))
    sby = x["spending_by_year"]
    for r in sby.index:
        out.append("  %s%s\n" % (fw("Konsum " + str(r)), q(sby.loc[r].to_numpy())))
    out.append("  %s%s\n" % (fw("Konsum Durchschnitt"), q(x["mean_spending"])))
    out.append("  %s%s\n" % (fw("Konsum Minimum"), q(x["min_spending"])))
    out.append("  %s%s\n" % (fw(_sp("Sicherheitsäquiv. (g=%g)", float(x["gamma"]))), q(x["ce_spending"])))
    out.append("  %s%s\n" % (fw("Max. Konsumrückgang"), q(100 * np.asarray(x["spending_drawdown"]), True)))
    out.append("  %s%s\n" % (fw("PWR"), q(x["pwr"], True)))
    if x["tax_mode"] == "person":
        out.append("  %s%s\n" % (fw("Steuern gesamt"), q(x["taxes"])))
    out.append("\n%s\n" % L)
    return "".join(out)


def _plot_wd(x, probs=(0.05, 0.25, 0.5, 0.75, 0.95), **kwargs):
    """Fächer des realen Vermögens und des realen Jahreskonsums (matplotlib)."""
    import matplotlib.pyplot as plt
    probs = np.asarray(probs, dtype=np.float64)
    panels = 1 if x.get("wealth") is None else 2
    fig, axes = plt.subplots(1, panels, figsize=(5 * panels, 4))
    axes = np.atleast_1d(axes)
    w = np.asarray(x["weights"], dtype=np.float64)

    def fan(ax, M, main, xs):
        Q = np.column_stack([_wquantile(M[i, :], w, probs) for i in range(M.shape[0])]) / 1000
        k = len(probs)
        for i in range(k // 2):
            ax.fill_between(xs, Q[i, :], Q[k - 1 - i, :], color="#2C6E9B", alpha=0.18, lw=0)
        ax.plot(xs, Q[math.ceil(k / 2) - 1, :], color="#2C6E9B", lw=2)
        ax.set_xlabel("Jahr")
        ax.set_ylabel("Tsd. (Startkaufkraft)")
        ax.set_title(main)

    i = 0
    if x.get("wealth") is not None:
        Wm = np.asarray(x["wealth"], dtype=np.float64)
        fan(axes[0], Wm, "Reales Vermögen", np.arange(Wm.shape[0]))
        i = 1
    S = np.asarray(x["spending"], dtype=np.float64)
    fan(axes[i], S, "Realer Konsum je Jahr", np.arange(1, S.shape[0] + 1))
    return x


# ═══════════════════════════════════════════════════════════════════════════
# Laufzeitmodell
# ═══════════════════════════════════════════════════════════════════════════

class SimLevHorizon(RList):
    """Laufzeit der Entnahmephase (R-Klasse ``SimLevHorizon``)."""

    r_class = ("SimLevHorizon",)

    def format(self) -> str:
        d = _draw_horizon(self, 20000)
        return _sp("Laufzeit der Entnahmephase (%s): Mittel %.1f Jahre, Median %g, 90 %%-Quantil %g, Bereich %g bis %g",
                   self["type"], r_mean_int(d), r_median(d.astype(np.float64)), float(_quantile7(d, 0.9)[0]),
                   float(d.min()), float(d.max()))


def _is_horizon(x) -> bool:
    return isinstance(x, SimLevHorizon) or "SimLevHorizon" in getattr(x, "r_class", ())


def horizon_model(type=("fixed", "uniform", "discrete", "normal", "triangular", "sample"),  # noqa: A002
                  years=None, prob=None, min=None, max=None, mean=None, sd=None, mode=None, seed=1):  # noqa: A002
    """Laufzeit der Entnahmephase nach eigenen Annahmen (siehe R-Dokumentation ``horizon_model``)."""
    type = _match_arg(type, ("fixed", "uniform", "discrete", "normal", "triangular", "sample"))  # noqa: A001
    need = {"fixed": ["years"], "uniform": ["min", "max"], "discrete": ["years", "prob"],
            "normal": ["mean", "sd", "min", "max"], "triangular": ["min", "mode", "max"], "sample": ["years"]}[type]
    given = {"years": years, "prob": prob, "min": min, "max": max, "mean": mean, "sd": sd, "mode": mode}
    miss = [k for k in need if given[k] is None]
    if miss:
        _stop("horizon_model('%s') braucht: %s" % (type, ", ".join(miss)))
    for k in need:
        v = given[k]
        multi = k == "prob" or (k == "years" and type in ("discrete", "sample"))
        a = _num_vec(v)
        if a is None or not a.size or (~np.isfinite(a)).any() or (not multi and a.size != 1):
            _stop("horizon_model('%s'): %s muss %s sein (erhalten: %s)." % (
                type, k, "ein endlicher Zahlenvektor" if multi else "eine endliche Zahl", _show(v)))
    for k in [k for k in need if k in ("years", "min", "max", "mean", "mode")]:
        if (_num_vec(given[k]) <= 0).any():
            _stop("horizon_model('%s'): %s muss > 0 sein (Laufzeit in Jahren; erhalten: %s)." % (type, k, _show(given[k])))
    if type == "discrete":
        yv, pv = _num_vec(years), _num_vec(prob)
        if len(yv) != len(pv) or (pv < 0).any() or r_sum(pv) <= 0:
            _stop("horizon_model('discrete'): years und prob gleich lang, prob >= 0 mit Summe > 0.")
    if min is not None and max is not None and min > max:
        _stop("min <= max erforderlich.")
    if type == "triangular" and (mode < min or mode > max):
        _stop(_sp("horizon_model('triangular'): mode (%g) muss zwischen min (%g) und max (%g) liegen.",
                  float(mode), float(min), float(max)))
    if type == "normal" and sd < 0:
        _stop("horizon_model('normal'): sd muss >= 0 sein.")
    return SimLevHorizon([("type", type), ("seed", seed)] + [(k, given[k]) for k in need])


def _seq_from_to(a, b):
    """``seq(a, b)`` (Schritt 1)."""
    a = float(a)
    b = float(b)
    n = int(math.floor(b - a + 1e-10))
    return a + np.arange(0, n + 1, dtype=np.float64)


@_quiet
def _draw_horizon(h, n):
    """Laufzeiten ziehen (Port von ``.draw_horizon``); ganzzahlig, mindestens 1."""
    n = int(n)

    def pick(x, prob=None):
        x = np.atleast_1d(np.asarray(x, dtype=np.float64))
        ix = np.asarray(_rng.sample_int(len(x), n, replace=True, prob=prob)).astype(np.int64)
        return x[ix - 1]

    def body():
        t = h["type"]
        if t == "fixed":
            return np.repeat(np.atleast_1d(np.asarray(h["years"], dtype=np.float64)), n) if n else np.zeros(0)
        if t == "uniform":
            return pick(_seq_from_to(h["min"], h["max"]))
        if t == "discrete":
            return pick(h["years"], np.atleast_1d(np.asarray(h["prob"], dtype=np.float64)))
        if t == "normal":
            z = np.asarray(_rng.rnorm(n, float(h["mean"]), float(h["sd"])), dtype=np.float64)
            r = np.array([_r_round0(v) for v in z])
            return np.minimum(float(h["max"]), np.maximum(float(h["min"]), r))
        if t == "triangular":
            u = np.atleast_1d(np.asarray(_rng.runif(n), dtype=np.float64))
            a, b, c = float(h["min"]), float(h["max"]), float(h["mode"])
            if b == a:
                return np.full(n, a)
            f = (c - a) / (b - a)
            v1 = a + np.sqrt(u * (b - a) * (c - a))
            v2 = b - np.sqrt((1 - u) * (b - a) * (b - c))
            return np.array([_r_round0(v) for v in np.where(u < f, v1, v2)])
        return pick(h["years"])

    out = _with_rng_restore(body, seed=h.get("seed") if isinstance(h, Mapping) else None)
    out = np.maximum(1.0, np.asarray(out, dtype=np.float64))
    return np.trunc(out).astype(np.int64)


# Rechnen mit NA (signalisierendes NaN) ohne numpy-Warnung "invalid value" wie in R (gemeinsamer Helfer)
from .data_prep import _quiet_fp  # noqa: E402

_quiet_fp(globals(), list(__all__) + ["_anniv_ends", "_annual_real", "_draw_horizon", "_period_ends", "_wd_fee_set", "_wd_held", "_wd_lots", "_wd_param_vector", "_wd_ppy"])
