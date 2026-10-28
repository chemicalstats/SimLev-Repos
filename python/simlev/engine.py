"""Backtest-Engine (Port von ``simulation()`` aus SimLev 0.5.0).

Die Struktur folgt den Phasen des R-Pakets (``simulation.R``, ``sim_validate.R``,
``sim_prepare.R``, ``sim_actions.R``, ``sim_loop.R``, ``sim_evaluate.R``), damit beide
Implementierungen Zeile für Zeile vergleichbar bleiben und bitgleich rechnen:

1. ``_sim_check_inputs``   Eingabeprüfung, Steuer- und Gebühreneinstellungen
2. ``_sim_prepare_data``   Kalenderraster, LOCF; ``_sim_build_state`` (``sim_mem``);
   ``_sim_build_calendar`` (Termine und Flags); ``_sim_init_weights``; ``_sim_build_schedule``
3. ``_Actions``            Zahlungs- und Abrechnungshelfer
4. ``_sim_run_days``       Tagesschleife mit den Tagesschritten ``_sim_day_*``
5. ``_sim_close_years``    Abschluss des letzten Jahres
6. ``_sim_returns``, ``_sim_risk_stats``, ``_sim_undefined_metrics``, ``_sim_result``

Der Simulationszustand ``sim`` ist ein ``dict`` mit den Teilen ``assets``, ``status``,
``market``, ``trades``, ``report`` und ``totals`` wie ``sim_mem`` in R. Tagesindizes
(``time``) sind wie in R 1-basiert.
"""
from __future__ import annotations

import copy
import datetime as _dt
import math
import re
import sys
import warnings
from typing import Any, Mapping, Sequence

import numpy as np
import pandas as pd

from . import _core as core
from ._dates import days_from_civil, fmt_date, from_days, is_leap, year_of
from ._r.rformat import r_as_character, r_deparse, r_format, r_format1, r_round, r_sprintf
from ._r.rnum import (
    r_colsums,
    r_cummax,
    r_cumprod,
    r_cumsum,
    r_mean,
    r_mean_int,
    r_median,
    r_pow,
    r_pow_vec,
    r_prod,
    r_rowsums,
    r_sd,
    r_sum,
    r_uniroot,
)
from .config import _match_arg
from .tax_tariff import SimLevTaxTariff, read_tax_tariff, tariff_income_tax, tariff_soli

__all__ = ["simulation", "calculate_skewness", "calculate_kurtosis", "calculate_partials",
           "calculate_dates_flags", "xirr_rate", "apply_spread"]

from ._r.rnum import NA_REAL as NA  # noqa: E402  R's NA_real_ (Nutzlast 1954)


# ═══════════════════════════════════════════════════════════════════════════
# Ausgabe und Hilfen
# ═══════════════════════════════════════════════════════════════════════════

def _cat(text: str) -> None:
    """``cat()``: Ausgabe auf stdout (details-Protokoll)."""
    sys.stdout.write(text)


def _message(text: str) -> None:
    """``message()``: Hinweis auf stderr."""
    sys.stderr.write(text + "\n")


def _warn(text: str) -> None:
    """``warning()``: Python-Warnung mit dem deutschen Text aus R."""
    warnings.warn(text, UserWarning, stacklevel=3)


def _stop(text: str):
    """``stop()``: Fehler mit dem deutschen Text aus R."""
    raise ValueError(text)


def _sp(fmt: str, *args) -> str:
    return r_sprintf(fmt, *args)


def _rmin(a: float, b: float) -> float:
    """R ``min(a, b)`` für zwei Skalare (NaN pflanzt sich fort)."""
    if a != a or b != b:
        return NA
    return b if b < a else a


def _rmax(a: float, b: float) -> float:
    """R ``max(a, b)`` für zwei Skalare (NaN pflanzt sich fort)."""
    if a != a or b != b:
        return NA
    return b if b > a else a


def _isna(x: Any) -> bool:
    if x is None:
        return True
    if isinstance(x, (float, np.floating)) and math.isnan(x):
        return True
    try:
        return x is pd.NA or x is pd.NaT
    except Exception:  # noqa: BLE001
        return False


def _is_num(x: Any) -> bool:
    return isinstance(x, (int, float, np.integer, np.floating)) and not isinstance(x, (bool, np.bool_))


def _is_bool(x: Any) -> bool:
    return isinstance(x, (bool, np.bool_))


def _is_true(x: Any) -> bool:
    """R ``isTRUE()``: nur ein echtes logisches TRUE zählt."""
    return isinstance(x, (bool, np.bool_)) and bool(x)


def _truthy(x: Any) -> bool:
    """Wert eines Signals in ``&&``-Ausdrücken (Zahl ungleich 0 = TRUE; NA ist ein Fehler)."""
    if _isna(x):
        raise ValueError("missing value where TRUE/FALSE needed")
    return bool(x)


def _num_vec(x: Any) -> list | None:
    """Zahlenvektor aus Skalar/Folge (None, wenn nicht numerisch)."""
    if _is_num(x):
        return [float(x)]
    if isinstance(x, (list, tuple, np.ndarray, pd.Series)):
        vals = list(np.asarray(x, dtype=object).ravel())
        if all(_is_num(v) or v is None for v in vals):
            return [NA if v is None else float(v) for v in vals]
    return None


def _n_tage(n: Any) -> str:
    """``.n_tage()``: "1 Tag" bzw. "n Tage" (R9-03)."""
    s = n if isinstance(n, str) else "%d" % int(n)
    return "1 Tag" if s == "1" else s + " Tage"


_DOUBLE_LINE = "\u2550" * 62


def _r_class_name(x: Any) -> str:
    """Klassenname wie ``class(x)[1]`` in R für Python-Werte."""
    if isinstance(x, (bool, np.bool_)):
        return "logical"
    if _is_num(x):
        return "numeric"
    if isinstance(x, str):
        return "character"
    if isinstance(x, (list, tuple)):
        return "list"
    if isinstance(x, np.ndarray):
        return {"b": "logical", "i": "integer", "u": "integer", "f": "numeric", "U": "character"}.get(
            x.dtype.kind, "list") if x.ndim < 2 else "matrix"
    return type(x).__name__


class _Default:
    """Standardwert eines Arguments (zeigt an, dass das Argument nicht angegeben wurde)."""

    __slots__ = ("value",)

    def __init__(self, value: Any):
        self.value = value

    def __repr__(self) -> str:
        return repr(self.value)


def _unwrap(x: Any) -> Any:
    return x.value if isinstance(x, _Default) else x


# ═══════════════════════════════════════════════════════════════════════════
# Datumswerte
# ═══════════════════════════════════════════════════════════════════════════

def _r_strptime_ymd(s: str) -> int | None:
    """``as.Date(s, format = "%Y-%m-%d")`` wie R's strptime (Ziffernfelder, Rest ignoriert)."""
    rp = 0

    def get_number(lo, hi, n):
        nonlocal rp
        while rp < len(s) and s[rp] == " ":
            rp += 1
        if rp >= len(s) or not ("0" <= s[rp] <= "9"):
            return None
        val = 0
        k = n
        while True:
            val = val * 10 + (ord(s[rp]) - 48)
            rp += 1
            k -= 1
            if not (k > 0 and rp < len(s) and "0" <= s[rp] <= "9"):
                break
        if val < lo or val > hi:
            return None
        return val
    y = get_number(0, 9999, 4)
    if y is None or rp >= len(s) or s[rp] != "-":
        return None
    rp += 1
    m = get_number(1, 12, 2)
    if m is None or rp >= len(s) or s[rp] != "-":
        return None
    rp += 1
    d = get_number(1, 31, 2)
    if d is None:
        return None
    try:
        return days_from_civil(y, m, d)
    except ValueError:
        return None


def _as_date(x: Any) -> int | None:
    """``as.Date(x)`` für einen Wert (Text JJJJ-MM-TT bzw. JJJJ/MM/TT, Datum, Zahl); None = NA."""
    if x is None:
        return None
    if isinstance(x, (list, tuple, np.ndarray)) and not isinstance(x, str):
        vals = list(x)
        if len(vals) != 1:
            return None
        x = vals[0]
    if isinstance(x, str):
        z = _r_strptime_ymd(x)
        if z is None:
            z = _r_strptime_ymd(x.replace("/", "-", 2)) if re.match(r"^\s*\d{1,4}/\d{1,2}/\d", x) else None
        return z
    if isinstance(x, np.datetime64):
        if np.isnat(x):
            return None
        return int(x.astype("datetime64[D]").astype(np.int64))
    if isinstance(x, pd.Timestamp):
        if x is pd.NaT:
            return None
        if x.tzinfo is not None:
            x = x.tz_localize(None)
        return x.to_pydatetime().date().toordinal() - _dt.date(1970, 1, 1).toordinal()
    if isinstance(x, _dt.datetime):
        return x.date().toordinal() - _dt.date(1970, 1, 1).toordinal()
    if isinstance(x, _dt.date):
        return x.toordinal() - _dt.date(1970, 1, 1).toordinal()
    if _is_num(x):
        if math.isnan(float(x)):
            return None
        return int(math.floor(float(x)))
    return None


def _date_or_fail(x: Any) -> int:
    z = _as_date(x)
    if z is None:
        raise ValueError("character string is not in a standard unambiguous format")
    return z


# ═══════════════════════════════════════════════════════════════════════════
# Spaltenorientierte Daten (data.frame)
# ═══════════════════════════════════════════════════════════════════════════

class _Frame:
    """Spaltenorientierte Sicht auf ``data`` mit R-Spaltenarten.

    Arten: ``numeric`` (float64, NaN = NA), ``logical`` (object: True/False/None),
    ``character`` (object: str/None), ``factor`` (object: str/None), ``date`` (Tage seit
    1970-01-01 als float, NaN = NA), ``posixct`` (wie date, aus Datum-Uhrzeit), ``other``.
    """

    def __init__(self, names: list, cols: dict, kinds: dict, filled_attr: Any = None):
        self.names = names
        self.cols = cols
        self.kinds = kinds
        self.filled_attr = filled_attr

    @property
    def nrow(self) -> int:
        return len(self.cols[self.names[0]]) if self.names else 0

    def __contains__(self, name: Any) -> bool:
        return isinstance(name, str) and name in self.cols

    def get(self, name: str):
        return self.cols.get(name)

    def set(self, name: str, arr, kind: str) -> None:
        if name not in self.cols:
            self.names.append(name)
        self.cols[name] = arr
        self.kinds[name] = kind

    def drop(self, name: str) -> None:
        if name in self.cols:
            self.names.remove(name)
            del self.cols[name]
            del self.kinds[name]

    def take(self, idx: np.ndarray) -> None:
        for nm in self.names:
            self.cols[nm] = self.cols[nm][idx]

    def is_numeric(self, name: str) -> bool:
        return self.kinds.get(name) == "numeric"

    def r_class(self, name: str) -> str:
        return {"numeric": "numeric", "logical": "logical", "character": "character", "factor": "factor",
                "date": "Date", "posixct": "POSIXct"}.get(self.kinds.get(name), "list")


_EPOCH_ORD = _dt.date(1970, 1, 1).toordinal()


def _classify_values(vals: list) -> tuple[str, np.ndarray]:
    ok = [v for v in vals if not _isna(v)]
    n = len(vals)
    if not ok:
        return "logical", np.array([None] * n, dtype=object)
    if all(_is_bool(v) for v in ok):
        return "logical", np.array([None if _isna(v) else bool(v) for v in vals], dtype=object)
    if all(_is_num(v) for v in ok):
        return "numeric", np.array([NA if _isna(v) else float(v) for v in vals], dtype=np.float64)
    if all(isinstance(v, str) for v in ok):
        return "character", np.array([None if _isna(v) else v for v in vals], dtype=object)
    if all(isinstance(v, (_dt.date, np.datetime64)) for v in ok):
        days, midnight = [], True
        for v in vals:
            if _isna(v) or (isinstance(v, np.datetime64) and np.isnat(v)):
                days.append(NA)
                continue
            if isinstance(v, pd.Timestamp):
                if v.tzinfo is not None:
                    midnight = False
                    v = v.tz_localize(None)
                if v != v.normalize():
                    midnight = False
                days.append(float(v.normalize().to_pydatetime().date().toordinal() - _EPOCH_ORD))
            elif isinstance(v, _dt.datetime):
                if v.tzinfo is not None or v.time() != _dt.time(0):
                    midnight = False
                days.append(float(v.date().toordinal() - _EPOCH_ORD))
            elif isinstance(v, np.datetime64):
                d = v.astype("datetime64[D]")
                if d != v:
                    midnight = False
                days.append(float(d.astype(np.int64)))
            else:
                days.append(float(v.toordinal() - _EPOCH_ORD))
        return ("date" if midnight else "posixct"), np.array(days, dtype=np.float64)
    return "other", np.array(vals, dtype=object)


def _column(v: Any) -> tuple[str, np.ndarray]:
    """Eine Spalte (pandas.Series, ndarray, Folge) in (Art, Array) umwandeln."""
    if isinstance(v, pd.Series):
        dt = v.dtype
        if isinstance(dt, pd.CategoricalDtype):
            return "factor", np.array([None if _isna(x) else str(x) for x in v], dtype=object)
        if pd.api.types.is_bool_dtype(dt):
            if dt == bool:
                return "logical", np.array([bool(x) for x in v], dtype=object)
            return "logical", np.array([None if _isna(x) else bool(x) for x in v], dtype=object)
        if pd.api.types.is_datetime64_any_dtype(dt):
            s = v
            midnight = True
            if getattr(dt, "tz", None) is not None:
                s = v.dt.tz_localize(None)
                midnight = False
            norm = s.dt.normalize()
            if not (norm.isna() | (norm == s)).all():
                midnight = False
            days = np.array([NA if _isna(x) else float(x.to_pydatetime().date().toordinal() - _EPOCH_ORD)
                             for x in norm], dtype=np.float64)
            return ("date" if midnight else "posixct"), days
        if pd.api.types.is_numeric_dtype(dt):
            return "numeric", v.to_numpy(dtype=np.float64, na_value=np.nan)
        if pd.api.types.is_string_dtype(dt) and not pd.api.types.is_object_dtype(dt):
            return "character", np.array([None if _isna(x) else str(x) for x in v], dtype=object)
        return _classify_values(list(v))
    arr = np.asarray(v)
    if arr.ndim == 0:
        arr = arr.reshape(1)
    if arr.dtype.kind == "b":
        return "logical", np.array([bool(x) for x in arr], dtype=object)
    if arr.dtype.kind in "iuf":
        return "numeric", arr.astype(np.float64)
    if arr.dtype.kind == "M":
        return _column(pd.Series(arr))
    if arr.dtype.kind in "US":
        return "character", np.array([str(x) for x in arr], dtype=object)
    return _classify_values(list(arr))


def _to_frame(data: Any) -> _Frame:
    if isinstance(data, pd.DataFrame):
        names = [str(c) for c in data.columns]
        if len(set(names)) != len(names):
            dup = [nm for i, nm in enumerate(names) if nm in names[:i]][0]
            _stop("simulation: Spaltenname '%s' kommt in 'data' mehrfach vor; jede Spalte muss eindeutig benannt "
                  "sein." % dup)
        cols, kinds = {}, {}
        for j, nm in enumerate(names):
            k, a = _column(data.iloc[:, j])
            cols[nm], kinds[nm] = a, k
        return _Frame(names, cols, kinds, data.attrs.get("filled") if hasattr(data, "attrs") else None)
    names = [str(k) for k in data.keys()]
    cols, kinds = {}, {}
    for k, nm in zip(data.keys(), names):
        kk, a = _column(data[k])
        cols[nm], kinds[nm] = a, kk
    lens = {len(a) for a in cols.values()}
    if len(lens) > 1:
        _stop("simulation: alle Spalten von 'data' m\u00fcssen gleich lang sein.")
    return _Frame(names, cols, kinds, getattr(data, "attrs", {}).get("filled") if hasattr(data, "attrs") else None)


def _filled_matrix(fa: Any) -> tuple[np.ndarray | None, list | None, int]:
    """Attribut ``filled``: (Matrix, Spaltennamen, Zeilenzahl); Vektor: Matrix None."""
    if fa is None:
        return None, None, 0
    if isinstance(fa, pd.DataFrame):
        return np.asarray(fa.to_numpy(), dtype=bool), [str(c) for c in fa.columns], len(fa)
    if isinstance(fa, Mapping):
        keys = list(fa.keys())
        m = np.column_stack([np.asarray(fa[k], dtype=bool) for k in keys]) if keys else np.zeros((0, 0), bool)
        return m, [str(k) for k in keys], m.shape[0]
    a = np.asarray(fa)
    if a.ndim == 2:
        return a.astype(bool), None, a.shape[0]
    return None, None, a.size


# ═══════════════════════════════════════════════════════════════════════════
# Gebühren (R: .fee_env, .fee_spec, .fee_amount, .fee_volume)
# ═══════════════════════════════════════════════════════════════════════════

class _FeeEnv:
    """Paket-Umgebung ``.fee_env``: aktuelle Gebührenangabe und Summe der Gebühren."""

    def __init__(self):
        self.current: dict | None = None
        self.paid = 0.0


_FEE = _FeeEnv()


def _fee_spec(x: Any) -> dict | None:
    if x is None:
        return None
    if _is_num(x):
        x = {"fixed": float(x)}
    if not isinstance(x, Mapping):
        _stop("order_fee/dca_fee: Zahl (EUR je Order) oder list(fixed, percent, min, max).")
    names = [str(k) for k in x.keys()]
    unk = [k for k in names if k not in ("fixed", "percent", "min", "max")]
    if len(x) and (any(k == "" for k in names) or unk):
        _stop("order_fee/dca_fee: unbekannte oder unbenannte Felder (%s); erlaubt sind fixed, percent, min, max."
              % ", ".join(unk if unk else ["ohne Namen"]))

    def g(k, dflt):
        v = x.get(k)
        return dflt if v is None else float(v)
    s = {"fixed": g("fixed", 0.0), "percent": g("percent", 0.0) / 100, "min": g("min", 0.0), "max": g("max", math.inf)}
    if s["fixed"] < 0 or s["percent"] < 0 or s["min"] < 0 or s["max"] < s["min"]:
        _stop("Geb\u00fchren m\u00fcssen nicht negativ sein (min <= max).")
    if s["fixed"] == 0 and s["percent"] == 0 and s["min"] == 0:
        return None
    return s


def _fee_amount(f: dict, volume: float) -> float:
    return _rmin(_rmax(f["fixed"] + f["percent"] * volume, f["min"]), f["max"])


def _fee_volume(f: dict, money: float) -> float:
    v = (money - f["fixed"]) / (1 + f["percent"])
    fee = f["fixed"] + f["percent"] * v
    if fee < f["min"]:
        v = money - f["min"]
    elif fee > f["max"]:
        v = money - f["max"]
    return _rmax(0.0, v)


# ═══════════════════════════════════════════════════════════════════════════
# Termine und Flags
# ═══════════════════════════════════════════════════════════════════════════

def _add_months_first(z_first: int, k: int) -> int:
    d = from_days(z_first)
    tot = (d.year * 12 + (d.month - 1)) + k
    return days_from_civil(tot // 12, tot % 12 + 1, 1)


def _calculate_dates_flags(mode, span, unit, days, dates: np.ndarray, value, anchor, start_date,
                           skip_start, liquidate) -> np.ndarray:
    n = dates.size
    if not mode or unit is None or (value is not None and value <= 0):
        return np.zeros(n, dtype=bool)
    if span is None:
        span = 1
    unit = _match_arg(unit, ("month", "quarter", "year"), "unit")
    anchor = _match_arg(anchor, ("start", "end"), "anchor")
    dmin, dmax = int(dates.min()), int(dates.max())
    start = dmin if start_date is None else _date_or_fail(start_date)
    day_list = None
    if days is not None:
        day_list = [float(v) for v in np.atleast_1d(np.asarray(days, dtype=np.float64))]
    schedule: list[float] = []
    sdt = from_days(start)
    if unit in ("month", "quarter"):
        step = int(span) * (3 if unit == "quarter" else 1)
        f = days_from_civil(sdt.year, sdt.month, 1)
        base_seq = []
        k = 0
        while True:
            z = _add_months_first(f, k * step)
            if z > dmax:
                break
            base_seq.append(z)
            k += 1
        if day_list is None:
            schedule = [float(z) for z in base_seq]
        else:
            for m0 in base_seq:
                dd0 = from_days(m0)
                yr, mon = dd0.year, dd0.month
                for dd in day_list:
                    if anchor == "start":
                        r = _r_strptime_ymd("%s-%s-%s" % (yr, mon, r_as_character(dd)))
                        schedule.append(NA if r is None else float(r))
                    elif unit == "month":
                        if mon == 12:
                            month_end = days_from_civil(yr + 1, 1, 1) - 1
                        else:
                            month_end = days_from_civil(yr, mon + 1, 1) - 1
                        d_end = float(month_end) - (dd - 1)
                        schedule.append(NA if d_end < m0 else d_end)
                    else:
                        end_mon, end_yr = mon + 3, yr
                        if end_mon > 12:
                            end_mon -= 12
                            end_yr = yr + 1
                        quarter_end = days_from_civil(end_yr, end_mon, 1) - 1
                        schedule.append(float(quarter_end) - (dd - 1))
    else:
        base_years = []
        y = sdt.year
        while days_from_civil(y, 1, 1) <= dmax:
            base_years.append(y)
            y += int(span)
        if day_list is None:
            schedule = [float(days_from_civil(y, 1, 1)) for y in base_years]
        else:
            for y in base_years:
                for dd in day_list:
                    if anchor == "start":
                        r = _r_strptime_ymd("%s-1-%s" % (y, r_as_character(dd)))
                        schedule.append(NA if r is None else float(r))
                    else:
                        schedule.append(float(days_from_civil(y, 12, 31)) - (dd - 1))
    date_set = set(int(z) for z in dates)
    sched = [s for s in schedule if not math.isnan(s) and s == int(s) and int(s) in date_set]
    if skip_start:
        sched = [s for s in sched if s != dmin]
    if liquidate:
        sched = [s for s in sched if s != dmax]
    sset = set(int(s) for s in sched)
    return np.array([int(z) in sset for z in dates], dtype=bool)


def _calculate_split_flags(sim: dict, base: float, mode: bool, dates: np.ndarray, split_thresh) -> np.ndarray:
    n = dates.size
    if not mode or split_thresh is None:
        return np.zeros(n, dtype=bool)
    lo, hi = float(split_thresh[0]), float(split_thresh[1])
    flag = np.zeros(n, dtype=bool)
    for name in sim["market"]:
        prices = np.array(sim["market"][name]["asset_price"], dtype=np.float64)
        for i in range(n):
            cp = float(prices[i])
            if cp > hi:
                flag[i] = True
                ratio = cp / base
                prices[i:] = prices[i:] / ratio
            elif cp < lo:
                flag[i] = True
                ratio = base / cp
                prices[i:] = prices[i:] * ratio
    return flag


def _ym(z: int) -> int:
    d = from_days(z)
    return d.year * 12 + d.month


def _shift_off_filled(flags: np.ndarray, filled: np.ndarray, mon: list) -> np.ndarray:
    hit = np.flatnonzero(flags.astype(bool) & filled)
    if hit.size == 0:
        return flags
    flags = flags.copy()
    n = flags.size
    logical = flags.dtype == bool
    for i in hit:
        j = i + 1
        while j < n and filled[j]:
            j += 1
        if j >= n or mon[j] != mon[i]:
            j = i - 1
            while j >= 0 and filled[j]:
                j -= 1
        if logical:
            flags[i] = False
            if 0 <= j < n:
                flags[j] = True
        else:
            if 0 <= j < n:
                flags[j] = flags[j] + flags[i]
            flags[i] = 0
    return flags


# ═══════════════════════════════════════════════════════════════════════════
# Handels- und Steuerfunktionen (simulation.R)
# ═══════════════════════════════════════════════════════════════════════════

def _apply_spread(price: float, spread: float, direction: str) -> float:
    if direction == "buy":
        return price * (1 + spread / 2)
    return price * (1 - spread / 2)


def _calculate_buy_signal(sim: dict, name: str, index: int) -> bool:
    a = sim["assets"][name]
    st = sim["status"][name]
    mk = sim["market"][name]
    sig = False
    if a["style"] == "signal" and _truthy(mk["signal_buy"][index - 1]) and st["money"] > 0 and st["count"] == 0:
        sig = True
    if a["style"] == "signal" and st["count"] > 0 and st["money"] > 0 and not _is_true(mk["signal_sell"][index - 1]):
        sig = True
    if a["style"] == "bnh" and st["money"] > 0:
        sig = True
    return sig


def _calculate_sell_signal(sim: dict, name: str, index: int) -> bool:
    a = sim["assets"][name]
    sig = False
    if a["style"] == "signal" and _truthy(sim["market"][name]["signal_sell"][index - 1]) \
            and sim["status"][name]["count"] > 0:
        sig = True
    if a["style"] == "bnh":
        sig = False
    return sig


def _perform_trade_buy(sim: dict, name: str, index: int, reason: str, spread: float, fractions: bool,
                       details: bool, count: float | None = None) -> dict:
    market_price = float(sim["market"][name]["asset_price"][index - 1])
    if math.isnan(market_price) or market_price <= 0:
        _warn(_sp("perform_trade_buy: ung\u00fcltiger Kurs (%.4f) f\u00fcr %s am %s; der Kauf wird \u00fcbersprungen.",
                  market_price, name, fmt_date(sim["market"][name]["asset_day"][index - 1])))
        return sim
    trade_price = _apply_spread(market_price, spread, "buy")
    if count is None:
        money = sim["status"][name]["money"]
        trade_count = money / trade_price if fractions else float(math.floor(money / trade_price))
    else:
        trade_count = count
    fee = _FEE.current
    if fee is not None:
        money = sim["status"][name]["money"]
        if count is None or trade_count * trade_price + _fee_amount(fee, trade_count * trade_price) > money + 1e-9:
            vol = _fee_volume(fee, money)
            trade_count = vol / trade_price if fractions else float(math.floor(vol / trade_price))
        if trade_count <= 0:
            return sim
        fee_paid = _fee_amount(fee, trade_count * trade_price)
        trade_price = trade_price + fee_paid / trade_count
        _FEE.paid = _FEE.paid + fee_paid
    if trade_count <= 0:
        return sim
    core.perform_trade_buy_cpp(sim, name, index, trade_count, trade_price, market_price)
    if details:
        _cat(_sp("%s\tKauf %.2fx %s zu %.2f EUR je Anteil am %s\n", reason, trade_count, name, trade_price,
                 fmt_date(sim["market"][name]["asset_day"][index - 1])))
    return sim


def _perform_trade_sell(sim: dict, name: str, index: int, tax_mode: str, tax_rate: float,
                        effective_tax_rate: float | None, marginal_tax_rate, private_sale_threshold,
                        use_sparer_pauschbetrag: bool, tax_regime: str | None, reason: str,
                        spread: float, details: bool, count: float | None = None,
                        price: float | None = None) -> dict:
    if effective_tax_rate is None:
        effective_tax_rate = tax_rate
    market_price = float(sim["market"][name]["asset_price"][index - 1])
    trade_price = _apply_spread(market_price, spread, "sell")
    current_date = int(sim["market"][name]["asset_day"][index - 1])
    available = sim["status"][name]["count"]
    if count is None:
        trade_count = available
    else:
        if count > available:
            _warn(_sp("perform_trade_sell: angeforderte Verkaufsmenge %.4f \u00fcbersteigt den Bestand %.4f von %s; "
                      "verkauft wird der gesamte Bestand.", count, available, name))
        trade_count = _rmin(count, available)
    if trade_count <= 0:
        return sim
    fee = _FEE.current
    if fee is not None:
        fee_paid = _fee_amount(fee, trade_count * trade_price)
        if trade_count * trade_price - fee_paid <= 0:
            return sim
        trade_price = trade_price - fee_paid / trade_count
        _FEE.paid = _FEE.paid + fee_paid
    tr = sim["trades"][name]
    if price is None and tax_mode == "person":
        fifo_price = core.calculate_fifo_price(tr["buys"], trade_count, int(tr["fifo_front"]))
    else:
        fifo_price = 0.0 if price is None else price
    trade_gain = (trade_price - fifo_price) * trade_count
    capital_gains_tax = 0.0
    if tax_regime is None:
        tax_regime = "none"
    lot_result = None
    if tax_mode == "person":
        if tax_regime == "none":
            tax_regime = sim["assets"][name]["tax_regime"]
        totals = sim["totals"]
        if tax_regime == "investment_fund":
            bonus = sim["assets"][name]["bonus"]
            vp_paid = core.calculate_fifo_vorabpauschale(tr["buys"], trade_count, int(tr["fifo_front"]))
            adjusted = trade_gain - vp_paid
            res = core.p20_tax(adjusted, bonus, totals, effective_tax_rate, use_sparer_pauschbetrag)
            capital_gains_tax = res["tax"]
            if details:
                if vp_paid > 0:
                    _cat(_sp("\t\t=> Vorabpauschale-Anrechnung (\u00a7 19 InvStG): %.2f EUR\n", vp_paid))
                if res["spb_used"] > 0:
                    _cat(_sp("\t\t=> Sparerpauschbetrag: %.2f EUR (verbleibend: %.2f EUR)\n",
                             res["spb_used"], totals["sparer_pauschbetrag_remaining"]))
        elif tax_regime == "capital_gains":
            res = core.p20_tax(trade_gain, 0.0, totals, effective_tax_rate, use_sparer_pauschbetrag)
            capital_gains_tax = res["tax"]
        elif tax_regime == "private_sale":
            lot_result = core.calculate_private_sale_tax(tr["buys"], int(tr["fifo_front"]), trade_count,
                                                         trade_price, current_date)
            if details:
                if lot_result["exempt_gain"] > 0:
                    _cat(_sp("\t\t=> Steuerfreier Gewinn (Haltedauer > 1 Jahr): %.2f EUR\n", lot_result["exempt_gain"]))
                if lot_result["exempt_loss"] > 0:
                    _cat(_sp("\t\t=> Nicht verrechenbarer Verlust (Haltedauer > 1 Jahr): %.2f EUR\n",
                             lot_result["exempt_loss"]))
            net_by = lot_result["taxable_gain"] - lot_result["taxable_loss"]
            if net_by != 0:
                by = totals.get("private_sale_net_ytd_by")
                if by is None:
                    by = {}
                    totals["private_sale_net_ytd_by"] = by
                by[name] = by.get(name, 0.0) + net_by
            if lot_result["taxable_gain"] > 0:
                totals["private_sale_gains_ytd"] = totals["private_sale_gains_ytd"] + lot_result["taxable_gain"]
                if details:
                    _cat(_sp("\t\t=> Steuerpflichtiger Gewinn (Haltedauer < 1 Jahr): %.2f EUR (seit Jahresbeginn: "
                             "%.2f EUR)\n", lot_result["taxable_gain"], totals["private_sale_gains_ytd"]))
            if lot_result["taxable_loss"] > 0:
                totals["private_sale_losses_ytd"] = totals["private_sale_losses_ytd"] + lot_result["taxable_loss"]
                if details:
                    _cat(_sp("\t\t=> Verrechenbarer Verlust (Haltedauer < 1 Jahr): %.2f EUR (seit Jahresbeginn: "
                             "%.2f EUR)\n", lot_result["taxable_loss"], totals["private_sale_losses_ytd"]))
            capital_gains_tax = 0.0
    core.calculate_sell_report(sim, name, index, trade_count, trade_price, market_price, capital_gains_tax)
    if tax_mode == "person":
        core.fifo_consume(sim, name, trade_count)
    if details:
        _cat(_sp("%s\tVerkauf %.2fx %s zu %.2f EUR je Anteil am %s\n", reason, trade_count, name, trade_price,
                 fmt_date(current_date)))
        if tax_mode == "person" and tax_regime not in ("none", "private_sale"):
            _cat(_sp("\t\t=> %s: %.2f EUR; Steuer: %.2f EUR\n", "Verlust" if trade_gain < 0 else "Gewinn",
                     trade_gain, capital_gains_tax))
    person = tax_mode == "person"
    entry = {
        "event_date": current_date,
        "event_type": "Sell",
        "asset_count": trade_count,
        "asset_price": trade_price,
        "event_gain": trade_gain if person else NA,
        "event_taxes": capital_gains_tax if person else NA,
        "tax_regime": tax_regime if person else None,
        "tax_deferred": (tax_regime == "private_sale") if person else False,
        "holding_exempt": (lot_result["exempt_gain"]
                           if person and tax_regime == "private_sale" and lot_result is not None else NA),
    }
    tr["sell_count"] += 1
    tr["sells"].append(entry)
    return sim


def _calculate_sell_count(sim: dict, name: str, target: float, index: int, spread: float, fractions: bool,
                          tax_mode: str, tax_rate: float, tax_regime: str | None = None) -> dict:
    market_price = float(sim["market"][name]["asset_price"][index - 1])
    trade_price = _apply_spread(market_price, spread, "sell")
    total_shares = sim["status"][name]["count"]
    if total_shares <= 0:
        return {"sell_count": 0.0, "fifo_price": 0.0}
    if target <= 0:
        return {"sell_count": 0.0, "fifo_price": 0.0}
    tr = sim["trades"][name]
    if tax_regime is None:
        tax_regime = sim["assets"][name]["tax_regime"]
    tax_regime = tax_regime if tax_mode == "person" else "none"
    bonus = sim["assets"][name]["bonus"] if tax_regime == "investment_fund" else 0.0
    spb_rem = sim["totals"].get("sparer_pauschbetrag_remaining")
    loss_pool = sim["totals"]["loss_capital_gains"] + _rmax(0.0, 0.0 if spb_rem is None else spb_rem)
    regime_code = {"none": 0, "investment_fund": 1, "capital_gains": 2, "private_sale": 3}.get(tax_regime, 0)
    return core.sell_count(tr["buys"], int(tr["fifo_front"]), target, trade_price, total_shares, bool(fractions),
                           regime_code, bonus, loss_pool, tax_rate)


def _calculate_flat_rate(sim: dict, name: str, index: int, dates: np.ndarray, tax_regime: str | None = None,
                         filled: np.ndarray | None = None) -> dict:
    if tax_regime is None:
        tax_regime = sim["assets"][name]["tax_regime"]
    empty = {"total_vp": 0.0, "lot_indices": [], "lot_vps": []}
    if tax_regime != "investment_fund":
        return empty
    date_index = int(dates[index - 1])
    yr = year_of(date_index)
    start_of_year = days_from_civil(yr, 1, 1)
    end_of_year = days_from_civil(yr, 12, 31)
    year_start_index = max(1, int(start_of_year - int(dates[0])) + 1)
    rate_index = year_start_index
    if filled is not None:
        while rate_index < index and bool(filled[rate_index - 1]):
            rate_index += 1
        if bool(filled[rate_index - 1]):
            rate_index = year_start_index
    prices = sim["market"][name]["asset_price"]
    year_start_price = float(prices[rate_index - 1])
    raw = float(sim["market"][name]["base_rates"][rate_index - 1]) / 100
    base_rate = _rmax(0.0, raw)
    if base_rate <= 0:
        return empty
    market_price = float(prices[index - 1])
    tr = sim["trades"][name]
    return core.flat_rate(tr["buys"], int(tr["fifo_front"]), base_rate, year_start_price, market_price,
                          start_of_year, end_of_year)


def _calculate_fund_fees(sim: dict, index: int, dates: np.ndarray, assets: list, funds_fee: float,
                         bonus_fee: float, details: bool) -> dict:
    cur = int(dates[index - 1])
    event_date = days_from_civil(year_of(cur), 1, 1)
    idx = np.flatnonzero((dates >= event_date) & (dates <= cur))
    zero = {a: 0.0 for a in assets}
    if idx.size == 0:
        return {"total_fees": 0.0, "total_value": sim["totals"]["total_value"], "asset_fees": zero}
    asset_totals = np.column_stack([sim["report"][a]["total"][idx] for a in assets])
    yr = year_of(cur)
    days_in_year = 366 if is_leap(yr) else 365
    daily_rate = funds_fee / 100 / days_in_year
    basic_fees = r_colsums(asset_totals * daily_rate, na_rm=True)
    basic_value = r_sum(basic_fees)
    flows_period = r_sum([r_sum(sim["report"][a]["flows"][idx]) for a in assets])
    total_value = sim["totals"]["total_value"] + flows_period
    status_totals = np.array([sim["status"][a]["total"] for a in assets], dtype=np.float64)
    market_value = r_sum(status_totals, na_rm=True)
    above_mark = market_value > total_value
    bonus_value = (market_value - total_value) * (bonus_fee / 100) if above_mark else 0.0
    if market_value > 0:
        asset_fees_v = basic_fees + bonus_value * status_totals / market_value
    else:
        asset_fees_v = basic_fees + 0.0
    total_fees = basic_value + bonus_value
    if above_mark:
        total_value = _rmax(total_value, market_value - total_fees)
    if details:
        _cat(_sp("Fondskosten:\tFondsgeb\u00fchren %.2f EUR am %s\n\t\t=> Grundgeb\u00fchr: %.2f EUR; "
                 "Performancegeb\u00fchr: %.2f EUR\n", total_fees, fmt_date(cur), basic_value, bonus_value))
    return {"total_fees": total_fees, "total_value": total_value,
            "asset_fees": {a: float(v) for a, v in zip(assets, asset_fees_v)}}


def _split(sim: dict, name: str, ratio: float, forward: bool) -> dict:
    st = sim["status"][name]
    current_count, current_price, current_worth = st["count"], st["price"], st["worth"]
    if forward:
        split_count = current_count * ratio
        split_price = current_price / ratio
    else:
        split_count = current_count / ratio
        split_price = current_price * ratio
    tr = sim["trades"][name]
    n_lots = tr["buy_count"]
    for k in range(n_lots):
        buy = tr["buys"][k]
        if not buy or buy["remaining"] <= 0:
            continue
        orig = buy.get("original")
        if orig is None:
            orig = buy["remaining"]
        nb = dict(buy)
        if forward:
            nb["count"] = buy["count"] * ratio
            nb["price"] = buy["price"] / ratio
            nb["remaining"] = buy["remaining"] * ratio
            nb["original"] = orig * ratio
        else:
            nb["count"] = buy["count"] / ratio
            nb["price"] = buy["price"] * ratio
            nb["remaining"] = buy["remaining"] / ratio
            nb["original"] = orig / ratio
        tr["buys"][k] = nb
    tr["fifo_front"] = core.update_fifo_front(tr["buys"], 1)
    st["count"] = split_count
    st["price"] = split_price
    st["worth"] = current_worth
    mk = sim["market"][name]
    if forward:
        mk["asset_price"] = mk["asset_price"] / ratio
    else:
        mk["asset_price"] = mk["asset_price"] * ratio
    return sim


def _perform_asset_split(sim: dict, name: str, ratio: float, index: int, type_: str, fractions: bool = True,
                         details: bool = False, current_date: int | None = None) -> dict:
    if type_ not in ("forward", "reverse"):
        _stop("perform_asset_split: type muss \"forward\" oder \"reverse\" sein, nicht %s." % r_deparse(type_))
    if ratio <= 0:
        _stop("perform_asset_split: ratio muss > 0 sein (Split-Verh\u00e4ltnis), nicht %s." % r_format1(ratio))
    sim = _split(sim, name, ratio, forward=(type_ == "forward"))
    if details:
        desc = ("1 : " + r_format1(ratio, digits=5)) if type_ == "forward" else (r_format1(ratio, digits=5) + " : 1")
        action = "Split" if type_ == "forward" else "Reverse-Split"
        ds = fmt_date(current_date) if current_date is not None else "(ohne Datum)"
        _cat("Split-Ereignis:\t%s %s im Verh\u00e4ltnis %s am %s\n" % (action, name, desc, ds))
    return sim


def _perform_gain_harvest(sim: dict, name: str, index: int, tax_regime: str, spread: float, fractions: bool,
                          use_loss_pot: bool, use_spb: bool, tax_mode: str, tax_rate: float,
                          effective_tax_rate: float, marginal_tax_rate, private_sale_threshold, details: bool) -> dict:
    if tax_regime not in ("investment_fund", "capital_gains"):
        return sim
    total = sim["status"][name]["count"]
    if total <= 0:
        return sim
    room = (sim["totals"]["sparer_pauschbetrag_remaining"] if use_spb else 0.0) + \
        (sim["totals"]["loss_capital_gains"] if use_loss_pot else 0.0)
    if room <= 0.01:
        return sim
    market_price = float(sim["market"][name]["asset_price"][index - 1])
    if math.isnan(market_price) or market_price <= 0:
        return sim
    sell_price = _apply_spread(market_price, spread, "sell")
    trades = sim["trades"][name]["buys"]
    front = int(sim["trades"][name]["fifo_front"])
    bonus = sim["assets"][name]["bonus"] if tax_regime == "investment_fund" else 0.0
    fee = _FEE.current

    def taxable(n: float, with_fee: bool = True) -> float:
        if n <= 0:
            return 0.0
        px = sell_price
        if with_fee and fee is not None:
            px = px - _fee_amount(fee, n * sell_price) / n
        g = (px - core.calculate_fifo_price(trades, n, front)) * n
        if tax_regime == "investment_fund":
            g = g - core.calculate_fifo_vorabpauschale(trades, n, front)
        return (1 - bonus) * g
    first_lot = _rmin(total, _rmax(1e-9, total * 1e-6))
    if taxable(first_lot, False) <= 0:
        return sim
    if taxable(total) <= room:
        n = total
    else:
        lo, hi = 0.0, total
        for _ in range(60):
            mid = (lo + hi) / 2
            if taxable(mid) > room:
                hi = mid
            else:
                lo = mid
            if hi - lo < total * 1e-10:
                break
        n = lo
    if not fractions:
        n = float(math.floor(n))
    if n <= 0 or taxable(n) <= 0:
        return sim
    if details:
        _cat(_sp("Freibetrag:\tRealisierung von Gewinnen %.2f EUR mit %.4fx %s (freier Sparer-Pauschbetrag/"
                 "Verlusttopf %.2f EUR)\n", taxable(n), n, name, room))
    sim = _perform_trade_sell(sim, name, index, tax_mode, tax_rate, effective_tax_rate, marginal_tax_rate,
                              private_sale_threshold, use_spb, tax_regime, "Freibetrag:", spread, details, count=n)
    sim = _perform_trade_buy(sim, name, index, "Freibetrag:", spread, fractions, details)
    return sim


# ═══════════════════════════════════════════════════════════════════════════
# Tarifweg (taxable_income, tax_tariff)
# ═══════════════════════════════════════════════════════════════════════════

def _check_taxable_income(x: Any, years: list[int]) -> dict:
    form = ("eine Zahl (zvE in EUR f\u00fcr alle Jahre), ein nach Kalenderjahren benannter Zahlenvektor "
            "(z. B. c(\"2024\" = 50000, \"2025\" = 52000)) oder ein data.frame mit den Spalten year und taxable_income")
    names: list | None = None
    vals: list | None = None
    if isinstance(x, pd.DataFrame):
        nm = [str(c).lower() for c in x.columns]
        yc = next((nm.index(c) for c in ("year", "jahr") if c in nm), None)
        vc = next((nm.index(c) for c in ("taxable_income", "betrag", "amount", "zve") if c in nm), None)
        if yc is None or vc is None:
            if x.shape[1] != 2:
                _stop("simulation: taxable_income als data.frame braucht die Spalten year und taxable_income (oder "
                      "genau zwei Spalten Jahr, Betrag); vorhanden: %s." % ", ".join(str(c) for c in x.columns))
            yc, vc = 0, 1
        kind, col = _column(x.iloc[:, vc])
        if kind != "numeric":
            _stop("simulation: taxable_income: Spalte '%s' (Betrag) muss numerisch sein." % x.columns[vc])
        vals = [float(v) for v in col]
        names = [r_as_character(v) if _is_num(v) else str(v) for v in x.iloc[:, yc]]
    elif isinstance(x, pd.Series):
        kind, col = _column(x)
        if kind != "numeric":
            vals = None
        else:
            vals = [float(v) for v in col]
            if not isinstance(x.index, pd.RangeIndex):
                names = [r_as_character(v) if _is_num(v) else str(v) for v in x.index]
    elif isinstance(x, Mapping):
        if all(_is_num(v) for v in x.values()) and len(x):
            vals = [float(v) for v in x.values()]
            names = [r_as_character(k) if _is_num(k) else str(k) for k in x.keys()]
    else:
        vals = _num_vec(x)
        if vals is not None and len(vals) == 0:
            vals = None
    if vals is None or (isinstance(x, np.ndarray) and x.ndim > 1):
        shown = r_format(list(x) if isinstance(x, (list, tuple, np.ndarray)) else x)
        _stop("simulation: taxable_income muss %s sein, nicht %s." % (form, ", ".join(shown[:3])))
    for i, v in enumerate(vals):
        if not math.isfinite(v):
            _stop("simulation: taxable_income enth\u00e4lt einen ung\u00fcltigen Wert (%s%s); erwartet werden endliche "
                  "Betr\u00e4ge in EUR." % (r_format1(v), (" f\u00fcr %s" % names[i]) if names is not None else ""))
    if len(vals) == 1 and names is None:
        return {"all": vals[0], "by_year": None}
    if names is None or any(nm is None or nm == "" for nm in names):
        _stop("simulation: taxable_income mit %d Werten muss nach Kalenderjahren benannt sein; erwartet wird %s."
              % (len(vals), form))
    yy = []
    for nm in names:
        t = nm.strip()
        try:
            y = int(float(t)) if re.match(r"^[-+]?\d+(\.\d*)?([eE][-+]?\d+)?$", t) else None
        except ValueError:
            y = None
        if y is None or str(y) != t:
            _stop("simulation: taxable_income: Name '%s' ist kein Kalenderjahr (erwartet z. B. \"2024\")." % nm)
        yy.append(y)
    for i, y in enumerate(yy):
        if y in yy[:i]:
            _stop("simulation: taxable_income: Jahr %d kommt mehrfach vor." % y)
    miss = [y for y in years if y not in yy]
    if miss:
        _stop("simulation: taxable_income fehlt f\u00fcr %s %s (angegeben: %s); je Kalenderjahr der Simulation "
              "(%d bis %d) wird ein Betrag ben\u00f6tigt." % ("Simulationsjahr" if len(miss) == 1 else "Simulationsjahre",
                                                              ", ".join(str(m) for m in miss),
                                                              ", ".join(str(y) for y in sorted(yy)),
                                                              min(years), max(years)))
    return {"all": None, "by_year": {str(y): v for y, v in zip(yy, vals)}}


class _TariffEnv:
    """Umgebung der Tarifrechnung (R: ``tariff_env``)."""

    def __init__(self):
        self.tariff: SimLevTaxTariff | None = None
        self.zve_all: float | None = None
        self.zve: dict | None = None
        self.ks: dict = {}
        self.church_k = 0.0
        self.kapest_rate = 0.25
        self.use_gp = False
        self.rows: list = []
        self.refund_due = 0.0
        self.due_info: list | None = None


def _tariff_base(env: _TariffEnv, year: int) -> dict:
    if env.zve_all is not None:
        zv = env.zve_all
    else:
        zv = env.zve.get(str(year), NA) if env.zve is not None else NA
    ks = env.ks.get(str(year))
    if ks is None or (isinstance(ks, float) and math.isnan(ks)):
        ks = 0.0
    return {"zve": zv, "ks_prev": ks}


def _tariff_full(env: _TariffEnv, x: float) -> dict:
    e = tariff_income_tax(env.tariff, x)
    so = tariff_soli(env.tariff, e)
    ki = env.church_k * e
    return {"est": e, "soli": so, "kist": ki, "total": e + so + ki}


def _tariff_diff(env: _TariffEnv, x1: float, x0: float) -> dict:
    if math.isnan(x1) or math.isnan(x0):
        return {"est": 0.0, "soli": 0.0, "kist": 0.0, "total": 0.0}
    a = _tariff_full(env, x1)
    b = _tariff_full(env, x0)
    return {k: a[k] - b[k] for k in ("est", "soli", "kist", "total")}


def _tariff_close(env: _TariffEnv, year: int, g23: float, k_base: float, abg_rate: float, details: bool = False):
    b = _tariff_base(env, year)
    if math.isnan(b["zve"]):
        return NA
    k = _rmax(0.0, k_base)
    abg = k * abg_rate
    kabg = k * env.kapest_rate * env.church_k
    gp_on = bool(env.use_gp) and k > 0
    B0 = b["zve"] - b["ks_prev"]
    B1 = B0 - kabg
    X0 = _tariff_diff(env, B0 + g23, b["zve"])["total"] + abg
    X1 = _tariff_diff(env, B1 + g23 + k, b["zve"])["total"] if gp_on else NA
    fav = gp_on and X1 < X0
    Bx = B1 if fav else B0
    ded = _tariff_diff(env, Bx, b["zve"])
    p23 = _tariff_diff(env, Bx + g23, Bx)
    if env.use_gp:
        tk = _tariff_diff(env, B1 + g23 + k, B1 + g23)
    else:
        tk = {"est": NA, "soli": NA, "kist": NA, "total": NA}
    tot = _tariff_diff(env, Bx + g23 + (k if fav else 0.0), b["zve"])
    D = (X1 if fav else X0) - abg
    ks = tot["kist"] - (kabg if fav else 0.0)
    env.ks[str(year + 1)] = ks
    paid = _rmax(0.0, b["ks_prev"]) + (kabg if fav else 0.0)
    refunded = _rmax(0.0, -b["ks_prev"])
    env.rows.append({
        "year": int(year), "taxable_income": b["zve"],
        "church_tax_paid_deductible": paid, "church_tax_refunded": refunded,
        "church_tax_net_deduction": paid - refunded,
        "taxable_income_net": Bx, "deduction_effect": ded["total"],
        "gain_p23": g23, "income_tax_p23": p23["est"], "soli_p23": p23["soli"], "church_tax_p23": p23["kist"],
        "tax_p23": p23["total"],
        "capital_income": k, "abgeltung_burden": abg, "church_tax_withheld_k": kabg,
        "tariff_income_tax_k": tk["est"], "tariff_soli_k": tk["soli"], "tariff_church_tax_k": tk["kist"],
        "tariff_burden": tk["total"],
        "burden_without_gp": X0, "burden_with_gp": X1, "guenstiger": bool(fav),
        "settlement": D, "refund": _rmax(0.0, -D), "church_tax_settlement_next_year": ks})
    if details:
        _cat(_sp("  Tarif %d: zvE %.2f EUR - KiSt-Sonderausgaben %.2f EUR (gezahlt %.2f, erstattet %.2f) = %.2f EUR "
                 "(Wirkung %.2f EUR)\n", year, b["zve"], paid - refunded, paid, refunded, Bx, ded["total"]))
        if g23 > 0:
            _cat(_sp("    \u00a7 23: Gewinn %.2f EUR -> Steuerlast ESt %.2f + Soli %.2f + KiSt %.2f = %.2f EUR\n",
                     g23, p23["est"], p23["soli"], p23["kist"], p23["total"]))
        if env.use_gp:
            _cat(_sp("    G\u00fcnstigerpr\u00fcfung: K %.2f EUR, Abgeltungsteuer %.2f EUR (KiSt %.2f), Tarif auf K %.2f EUR "
                     "(ESt %.2f + Soli %.2f + KiSt %.2f); Belastung ohne %.2f / mit %s EUR -> %s\n",
                     k, abg, kabg, tk["total"], tk["est"], tk["soli"], tk["kist"], X0,
                     "-" if math.isnan(X1) else _sp("%.2f", X1), "Tarif" if fav else "Abgeltungsteuer bleibt"))
        _cat(_sp("    Abrechnung: %s %.2f EUR; KiSt-Bescheid %+.2f EUR (Sonderausgabe %d)\n",
                 "Nachzahlung" if D >= 0 else "Erstattung", abs(D), ks, year + 1))
    return D


def _positive_by(sim: dict) -> dict:
    by = sim["totals"].get("private_sale_net_ytd_by")
    if not by:
        return {}
    return {k: _rmax(v, 0.0) for k, v in by.items() if math.isfinite(v)}


def _book_tax_due(sim: dict, tax_due: float) -> dict:
    by = _positive_by(sim)
    if not by or r_sum(list(by.values())) <= 0:
        by = {nm: 1.0 for nm in sim["status"]}
    s = r_sum(list(by.values()))
    due = {k: tax_due * v / s for k, v in by.items()}
    old = sim["totals"].get("p23_due")
    if old:
        merged = dict(old)
        for k, v in due.items():
            merged[k] = merged.get(k, 0.0) + v
        due = merged
    sim["totals"]["p23_due"] = due
    return sim


def _tariff_book(sim: dict, env: _TariffEnv, D: float) -> dict:
    if math.isnan(D) or D == 0:
        return sim
    sim["totals"]["total_taxes"] = sim["totals"]["total_taxes"] + D
    if D > 0:
        rw = env.rows[-1]
        by = _positive_by(sim)
        info = {"year": rw["year"], "D": D, "p23": rw["tax_p23"], "ded": rw["deduction_effect"],
                "by_p23": len(by) > 0 and r_sum(list(by.values())) > 0}
        env.due_info = (env.due_info or []) + [info]
        sim = _book_tax_due(sim, D)
    else:
        env.refund_due = env.refund_due - D
        if abs(sim["totals"]["total_taxes"]) < 1e-9:
            sim["totals"]["total_taxes"] = 0.0
    return sim


# ═══════════════════════════════════════════════════════════════════════════
# Jahreswechsel (handle_year_change)
# ═══════════════════════════════════════════════════════════════════════════

def _handle_year_change(sim: dict, current_date: int, marginal_tax_rate, private_sale_threshold,
                        sparer_pauschbetrag, use_sparer_pauschbetrag, soli_factor_income=1.0,
                        effective_tax_rate=None, details=False, church_factor=0.0,
                        tariff_env: _TariffEnv | None = None) -> dict:
    totals = sim["totals"]
    current_year = year_of(current_date)
    stored_year = totals["current_year"]
    if current_year == stored_year:
        return sim
    if details:
        _cat("\n" + _DOUBLE_LINE + "\n")
        _cat("  JAHRESWECHSEL: %d -> %d\n" % (stored_year, current_year))
        _cat(_DOUBLE_LINE + "\n")
    ytd_gains = totals["private_sale_gains_ytd"]
    ytd_losses = totals["private_sale_losses_ytd"]
    net_saldo = ytd_gains - ytd_losses
    internal_offset = _rmin(ytd_gains, ytd_losses)
    net_ytd_losses = _rmax(0.0, -net_saldo)
    carryforward_offset = 0.0
    net_gain = 0.0
    if net_saldo >= private_sale_threshold and net_saldo > 0:
        carryforward_offset = _rmin(net_saldo, totals["loss_private_sales"])
        totals["loss_private_sales"] = totals["loss_private_sales"] - carryforward_offset
        net_gain = net_saldo - carryforward_offset
        if details and carryforward_offset > 0:
            _cat(_sp("  \u00a7 23 EStG: Verlustvortrag verwendet: %.2f EUR\n", carryforward_offset))
            _cat(_sp("             Verbleibender Vortrag: %.2f EUR\n", totals["loss_private_sales"]))
    if details:
        _cat("  \u00a7 23 EStG Jahres\u00fcbersicht %d:\n" % stored_year)
        _cat(_sp("    Bruttogewinne (< 1 Jahr):    %10.2f EUR\n", ytd_gains))
        _cat(_sp("    Bruttoverluste (< 1 Jahr):   %10.2f EUR\n", ytd_losses))
        _cat(_sp("    Interne Verrechnung:         %10.2f EUR\n", internal_offset))
        _cat(_sp("    Verlustvortrag-Verrechnung:  %10.2f EUR\n", carryforward_offset))
        _cat("    " + "\u2500" * 41 + "\n")
        _cat(_sp("    Netto-Ergebnis:              %10.2f EUR\n", net_saldo - carryforward_offset))
    if net_gain > 0:
        tax_due = None
        if tariff_env is None:
            if marginal_tax_rate is None:
                _warn(_sp("simulation: Paragraf 23 EStG: Gewinne (%.2f EUR) erreichen die Freigrenze (%.2f EUR), ",
                          net_saldo, private_sale_threshold) +
                      "aber 'marginal_tax_rate' ist nicht gesetzt.\n" +
                      "Verwendet wird 42 % (Spitzensteuersatz); marginal_tax_rate in Prozent angeben (z. B. 42).")
                marginal_tax_rate = 0.42
            tax_due = net_gain * marginal_tax_rate * (soli_factor_income + church_factor)
            totals["total_taxes"] = totals["total_taxes"] + tax_due
            sim = _book_tax_due(sim, tax_due)
        if details:
            _cat("\n  \u26a0 FREIGRENZE ERREICHT!\n")
            _cat(_sp("    Jahressaldo %.2f EUR >= Freigrenze %.2f EUR\n", net_saldo, private_sale_threshold))
            _cat(_sp("    \u2192 GESAMTER Gewinn nach Verlustvortrag steuerpflichtig: %.2f EUR (Freigrenze, kein "
                     "Freibetrag!)\n", net_gain))
            if tariff_env is not None:
                _cat("    \u2192 Steuer nach dem Einkommensteuertarif (ESt + Soli + KiSt des \u00a7 23-Zuwachses): siehe "
                     "Jahresveranlagung unten (Zeile \u00a7 23)\n")
            else:
                _cat(_sp("    \u2192 Steuersatz: %.1f%%%s%s\n", marginal_tax_rate * 100,
                         _sp(" + %.1f%%%% Soli", (soli_factor_income - 1) * 100) if soli_factor_income > 1 else "",
                         _sp(" + %.1f%% KiSt", church_factor * 100) if church_factor > 0 else ""))
                _cat(_sp("    \u2192 Steuerlast: %.2f EUR\n", tax_due))
    elif net_ytd_losses > 0:
        totals["loss_private_sales"] = totals["loss_private_sales"] + net_ytd_losses
        if details:
            _cat(_sp("\n  Nettoverlust %.2f EUR \u2192 Vortrag ins n\u00e4chste Jahr\n", net_ytd_losses))
            _cat(_sp("  Gesamter Verlustvortrag: %.2f EUR\n", totals["loss_private_sales"]))
    elif 0 < net_saldo < private_sale_threshold:
        if details:
            _cat(_sp("\n  \u2713 Jahressaldo %.2f EUR < Freigrenze %.2f EUR \u2192 STEUERFREI (Verlustvortrag "
                     "unver\u00e4ndert)\n", net_saldo, private_sale_threshold))
    else:
        if details:
            _cat("\n  Keine steuerpflichtigen \u00a7 23 Vorg\u00e4nge in %d\n" % stored_year)

    if details and use_sparer_pauschbetrag:
        spb_annual = totals["sparer_pauschbetrag_annual"]
        spb_remaining = totals["sparer_pauschbetrag_remaining"]
        _cat("\n  Sparerpauschbetrag %d:\n" % stored_year)
        _cat(_sp("    Jahresbetrag:    %10.2f EUR\n", spb_annual))
        _cat(_sp("    Verwendet:       %10.2f EUR\n", spb_annual - spb_remaining))
        _cat(_sp("    Verfallen:       %10.2f EUR\n", spb_remaining))

    def g0(k):
        v = totals.get(k)
        return 0.0 if v is None else v
    cgt_loss_added = g0("cgt_loss_added_ytd")
    cgt_loss_used = g0("cgt_loss_used_ytd")
    cgt_base_taxed = g0("cgt_base_taxed_ytd")
    carry_start = g0("cgt_pool_start_ytd")
    carry_used = 0.0
    if carry_start > 0:
        spb_used_ytd = _rmax(0.0, totals["sparer_pauschbetrag_annual"] - totals["sparer_pauschbetrag_remaining"]) \
            if use_sparer_pauschbetrag else 0.0
        carry_used = _rmin(carry_start, _rmax(0.0, cgt_loss_used + spb_used_ytd + cgt_base_taxed - cgt_loss_added))
    unused_loss = _rmax(0.0, cgt_loss_added - (cgt_loss_used - carry_used))
    unused_loss = _rmin(unused_loss, totals["loss_capital_gains"])
    refund_base = _rmin(unused_loss, cgt_base_taxed)
    refund_done = refund_base > 0 and effective_tax_rate is not None and effective_tax_rate > 0
    if refund_done:
        refund = refund_base * effective_tax_rate
        names = list(sim["status"].keys())
        w = [float(sim["status"][nm].get("actual") if sim["status"][nm].get("actual") is not None else 0.0)
             for nm in names]
        sw = r_sum(w)
        w = [x / sw for x in w] if sw > 0 else [1 / len(names)] * len(names)
        for nm, wi in zip(names, w):
            sim["status"][nm]["money"] = sim["status"][nm]["money"] + refund * wi
        totals["total_taxes"] = totals["total_taxes"] - refund
        totals["loss_capital_gains"] = totals["loss_capital_gains"] - refund_base
        if details:
            _cat(_sp("  \u00a7 20 EStG: Unterj\u00e4hrige Verlustverrechnung -> Erstattung %.2f EUR in den Geldbestand\n",
                     refund))
    if use_sparer_pauschbetrag:
        spb_used_year = _rmax(0.0, totals["sparer_pauschbetrag_annual"] - totals["sparer_pauschbetrag_remaining"])
        taxed_left = cgt_base_taxed - (refund_base if refund_done else 0.0)
        release = _rmax(0.0, _rmin(spb_used_year, totals["loss_capital_gains"] - taxed_left))
        if release > 0:
            totals["loss_capital_gains"] = totals["loss_capital_gains"] - release
            totals["sparer_pauschbetrag_remaining"] = totals["sparer_pauschbetrag_remaining"] + release
            totals["sparer_pauschbetrag_used_total"] = totals["sparer_pauschbetrag_used_total"] - release
            if details:
                _cat(_sp("  \u00a7 20 EStG: Verlust gibt Sparer-Pauschbetrag frei: %.2f EUR (genutzt %d: %.2f EUR, "
                         "Verlusttopf %.2f EUR)\n", release, stored_year, spb_used_year - release,
                         totals["loss_capital_gains"]))
    any_refund = refund_done
    if tariff_env is not None:
        k_base = _rmax(0.0, cgt_base_taxed - (refund_base if refund_done else 0.0))
        D = _tariff_close(tariff_env, stored_year, net_gain, k_base,
                          effective_tax_rate if effective_tax_rate is not None else 0.0, details)
        sim = _tariff_book(sim, tariff_env, D)
        if not math.isnan(D) and D < 0:
            any_refund = True
    if any_refund and abs(totals["total_taxes"]) < 1e-9:
        totals["total_taxes"] = 0.0
    totals["private_sale_gains_ytd"] = 0.0
    totals["private_sale_losses_ytd"] = 0.0
    if totals.get("private_sale_net_ytd_by"):
        for k in totals["private_sale_net_ytd_by"]:
            totals["private_sale_net_ytd_by"][k] = 0.0
    totals["cgt_base_taxed_ytd"] = 0.0
    totals["cgt_loss_added_ytd"] = 0.0
    totals["cgt_loss_used_ytd"] = 0.0
    totals["cgt_pool_start_ytd"] = totals["loss_capital_gains"]
    if use_sparer_pauschbetrag:
        totals["sparer_pauschbetrag_remaining"] = sparer_pauschbetrag
    totals["current_year"] = current_year
    if details:
        _cat("\n  Tracker zur\u00fcckgesetzt f\u00fcr Jahr %d\n" % current_year)
        _cat(_DOUBLE_LINE + "\n\n")
    return sim


# ═══════════════════════════════════════════════════════════════════════════
# Kennzahlen
# ═══════════════════════════════════════════════════════════════════════════

def _xirr_rate(t: np.ndarray, amount: np.ndarray, end_value: float, horizon: float) -> float:
    """``.xirr_rate()``: interner Zinsfuß p. a. (Brent über u = T log(1 + r))."""
    t = np.asarray(t, dtype=np.float64)
    amount = np.asarray(amount, dtype=np.float64)
    keep = np.isfinite(amount) & (amount != 0)
    t = t[keep]
    amount = amount[keep]
    if amount.size == 0 or not (horizon > 0) or not math.isfinite(end_value):
        return NA
    if end_value == 0 and np.all(amount >= 0):
        return -1.0
    e = (horizon - t) / horizon

    def g(u: float) -> float:
        ex = np.empty(e.size)
        for i, v in enumerate(e):
            try:
                ex[i] = math.exp(u * v)
            except OverflowError:
                ex[i] = math.inf
        return r_sum(amount * ex) - end_value
    grid = [-200.0 + 5.0 * i for i in range(81)]
    gv = [g(u) for u in grid]
    k = None
    for i in range(80):
        if gv[i + 1] * gv[i] <= 0:
            k = i
            break
    if k is not None:
        br = [grid[k], grid[k + 1]]
        fb = [gv[k], gv[k + 1]]
    else:
        if not (gv[0] > 0) or not np.any(e > 0):
            return NA
        lo_lim = -800 / float(np.min(e[e > 0]))
        hi = grid[0]
        ghi = gv[0]
        lo = hi
        glo = ghi
        while glo > 0 and lo > lo_lim:
            hi = lo
            ghi = glo
            lo = _rmax(2 * lo, lo_lim)
            glo = g(lo)
        if glo > 0:
            return NA
        br = [lo, hi]
        fb = [glo, ghi]
    u = r_uniroot(g, br, f_lower=fb[0], f_upper=fb[1], tol=1e-14, maxiter=1000)["root"]
    return math.expm1(u / horizon)


def _calculate_skewness(x: np.ndarray) -> float:
    x = x[~np.isnan(x)]
    n = x.size
    if n < 3:
        return NA
    mean_x = r_mean(x)
    sd_x = r_sd(x)
    if sd_x == 0:
        return NA
    return (n / ((n - 1.0) * (n - 2.0))) * r_sum(r_pow_vec(x - mean_x, 3.0)) / r_pow(sd_x, 3.0)


def _calculate_kurtosis(x: np.ndarray, excess: bool = True) -> float:
    x = x[~np.isnan(x)]
    n = x.size
    if n < 4:
        return NA
    mean_x = r_mean(x)
    sd_x = r_sd(x)
    if sd_x == 0:
        return NA
    nf = float(n)
    kurt = (nf * (nf + 1)) / ((nf - 1) * (nf - 2) * (nf - 3)) * r_sum(r_pow_vec(x - mean_x, 4.0)) / r_pow(sd_x, 4.0)
    if excess:
        kurt = kurt - (3 * r_pow(nf - 1, 2.0)) / ((nf - 2) * (nf - 3))
    return kurt


def _calculate_partials(returns: np.ndarray, lower: bool) -> float:
    v = np.maximum(0.0, -returns) if lower else np.maximum(0.0, returns)
    v = np.where(np.isnan(returns), NA, v)
    return r_mean(v, na_rm=True)


# ── Öffentliche Helfer für andere Module (Namen wie in R) ──────────────────

def calculate_skewness(x, na_rm: bool = True) -> float:
    """``calculate_skewness(x, na.rm = TRUE)`` (Stichproben-Schiefe wie in simulation.R)."""
    a = np.asarray(x, dtype=np.float64).ravel()
    if not na_rm and np.isnan(a).any():
        return NA
    return _calculate_skewness(a)


def calculate_kurtosis(x, na_rm: bool = True, excess: bool = True) -> float:
    """``calculate_kurtosis(x, na.rm = TRUE, excess = TRUE)`` (Stichproben-Kurtosis wie in simulation.R)."""
    a = np.asarray(x, dtype=np.float64).ravel()
    if not na_rm and np.isnan(a).any():
        return NA
    return _calculate_kurtosis(a, excess=excess)


def calculate_partials(returns, exp: float = 1, type: str = "lower") -> float:
    """``calculate_partials(returns, exp = 1, type = c("lower", "higher"))``: mittleres Partialmoment."""
    a = np.asarray(returns, dtype=np.float64).ravel()
    v = np.maximum(0.0, -a) if type == "lower" else np.maximum(0.0, a)
    v = np.where(np.isnan(a), NA, v)
    return r_mean(r_pow_vec(v, float(exp)), na_rm=True)


def calculate_dates_flags(mode, span, unit, days, dates, value=None, anchor=("start", "end"), start_date=None,
                          skip_start=False, liquidate=False) -> np.ndarray:
    """``calculate_dates_flags()``: logischer Vektor der Termine (Sparplan, Rebalancing) zu ``dates``.

    ``dates`` als Tage seit 1970-01-01 (ganzzahlig) oder ``datetime64``.
    """
    d = np.asarray(dates)
    if np.issubdtype(d.dtype, np.datetime64):
        d = d.astype("datetime64[D]").astype(np.int64)
    return _calculate_dates_flags(mode, span, unit, days, d.astype(np.int64), value, anchor, start_date,
                                  skip_start, liquidate)


def xirr_rate(t, amount, end_value: float, horizon: float) -> float:
    """``.xirr_rate()``: geldgewichtete Rendite p. a. (interner Zinsfuß) wie in ``simulation()``."""
    return _xirr_rate(np.asarray(t, dtype=np.float64), np.asarray(amount, dtype=np.float64), float(end_value),
                      float(horizon))


apply_spread = _apply_spread


# ═══════════════════════════════════════════════════════════════════════════
# Phase 1: Eingabeprüfung (sim_validate.R)
# ═══════════════════════════════════════════════════════════════════════════

def _frac_warn_col(fr: _Frame, col: str, arg: str, hi: float) -> None:
    if not fr.is_numeric(col):
        return
    v = fr.get(col)
    v = v[~np.isnan(v) & (v != 0)]
    if v.size == 0:
        return
    m = r_median(v)
    if math.isfinite(m) and 0 < m < hi:
        _warn("simulation: %s-Spalte '%s' hat den Median %s und wird als %s %% gelesen (Prozent-Konvention); gemeint "
              "waren vermutlich Werte x 100 (Median %s)." % (arg, col, r_format1(m), r_format1(m), r_format1(m * 100)))


def _sim_check_inputs(data, strategy, start_value, spread, details, dca_mode, dca_value, dca_span, dca_days,
                      balance_mode, balance_days, balance_thresh, balance_thresh_type, tax_mode, tax_rate,
                      marginal_tax_rate, use_guenstigerpruefung, private_sale_threshold, sparer_pauschbetrag,
                      use_sparer_pauschbetrag, include_soli_on_income_tax, soli_rate_income_tax, base_rate,
                      funds_fee, bonus_fee, fractions, risk_free, split_mode, split_thresh, event_col, church_tax,
                      order_fee, dca_fee, harvest_mode, harvest_day, taxable_income, tax_tariff, given) -> dict:
    tax_mode = _match_arg(tax_mode, ("none", "person", "funds"), "tax_mode")
    if not isinstance(data, (pd.DataFrame, Mapping)):
        _stop("simulation: data muss ein data.frame mit Spalte 'date' und je Asset einer Kursspalte sein, nicht %s."
              % ("fehlend" if data is None else _r_class_name(data)))
    if strategy is None or len(strategy) == 0:
        _stop("simulation: strategy muss eine nicht leere, benannte Liste von Asset-Konfigurationen sein (z. B. aus "
              "create_strategy()), nicht %s." % ("fehlend" if strategy is None else "leer (L\u00e4nge 0)"))
    if spread is not None:
        _warn("simulation: Das Argument 'spread' wird nicht ausgewertet; ma\u00dfgeblich ist asset_spread je Asset "
              "(asset_config()).")
    if isinstance(data, pd.DataFrame):
        names_d = [str(c) for c in data.columns]
        dup = [nm for i, nm in enumerate(names_d) if nm in names_d[:i]]
    else:
        dup = []
    if not isinstance(strategy, Mapping) or any(str(k) == "" for k in strategy.keys()):
        _stop("simulation: Alle Assets in 'strategy' m\u00fcssen benannt sein (Name = Kursspalte in 'data').")
    if dup:
        _stop("simulation: Spaltenname '%s' kommt in 'data' mehrfach vor; jede Spalte muss eindeutig benannt sein."
              % dup[0])
    fr = _to_frame(data)
    filled_attr = fr.filled_attr
    strat: dict = {}
    for k, a in strategy.items():
        nm = str(k)
        if not isinstance(a, Mapping):
            _stop("simulation: Asset '%s' in 'strategy' muss eine Liste bzw. asset_config() sein." % nm)
        strat[nm] = dict(a)
    cls_ok = ["etf", "etn", "etc", "certificate", "etn_standard", "etn_deliverable"]
    for nm, a in strat.items():
        ac = a.get("asset_class")
        if not isinstance(ac, str) or ac not in cls_ok:
            _stop("simulation: asset_class %s von Asset '%s' ist ung\u00fcltig; erlaubt sind %s (veraltet: etn_standard, "
                  "etn_deliverable). Strategie am besten mit create_strategy()/asset_config() bauen."
                  % (r_deparse(ac), nm, ", ".join(cls_ok[:4])))
        tr_ = a.get("tax_regime")
        if tr_ is not None and (not isinstance(tr_, str) or tr_ not in ("investment_fund", "capital_gains",
                                                                           "private_sale")):
            _stop("simulation: tax_regime %s von Asset '%s' ist ung\u00fcltig; erlaubt sind investment_fund, capital_gains, "
                  "private_sale (oder weglassen: aus asset_class abgeleitet). Ohne Steuern tax_mode = \"none\" verwenden."
                  % (r_deparse(tr_), nm))
        at = a.get("action_type")
        if not isinstance(at, str) or at not in ("bnh", "signal"):
            _stop("simulation: action_type %s von Asset '%s' ist ung\u00fcltig; erlaubt sind \"bnh\" und \"signal\"."
                  % (r_deparse(at), nm))
    if "date" not in fr:
        _stop("simulation: Spalte 'date' fehlt in 'data'.")
    miss = [nm for nm in strat if nm not in fr]
    if miss:
        _stop("simulation: %s %s in 'data'; je Asset der Strategie wird eine Spalte gleichen Namens erwartet "
              "(vorhanden: %s)." % ("Kursspalte" if len(miss) == 1 else "Kursspalten",
                                    ", ".join("'%s'" % m for m in miss) + " " + ("fehlt" if len(miss) == 1 else "fehlen"),
                                    ", ".join(nm for nm in fr.names if nm != "date")))
    if fr.nrow < 1:
        _stop("simulation: 'data' enth\u00e4lt keine Zeilen.")
    kind = fr.kinds["date"]
    if kind == "factor":
        kind = "character"
    if kind == "character":
        raw = fr.get("date")
        dd = np.array([NA if v is None else (NA if (z := _r_strptime_ymd(v)) is None else float(z)) for v in raw],
                      dtype=np.float64)
        bad = [i for i in range(len(raw)) if math.isnan(dd[i]) and raw[i] is not None]
        if bad:
            _stop("simulation: Spalte 'date' ist Text und '%s' (Zeile %d) ist kein Datum im Format JJJJ-MM-TT; vorher "
                  "mit as.Date(..., format = ...) umwandeln." % (raw[bad[0]], bad[0] + 1))
        fr.set("date", dd, "date")
        _message("Hinweis: Spalte 'date' wurde von Text in Date umgewandelt.")
    elif kind == "posixct":
        fr.kinds["date"] = "date"
        _message("Hinweis: Spalte 'date' wurde von Datum-Uhrzeit in Date umgewandelt.")
    if fr.kinds["date"] != "date":
        _stop("simulation: Spalte 'date' muss die Klasse Date haben (ist: %s)." % fr.r_class("date"))
    dvals = fr.get("date")
    if np.isnan(dvals).any():
        _stop("simulation: Spalte 'date' enth\u00e4lt NA (erstmals in Zeile %d)." % (int(np.flatnonzero(np.isnan(dvals))[0]) + 1))
    fa_m, fa_cols, fa_n = _filled_matrix(filled_attr)
    if np.any(np.diff(dvals) < 0):
        o = np.argsort(dvals, kind="stable")
        fr.take(o)
        if fa_m is not None and fa_m.shape[0] == len(o):
            fa_m = fa_m[o, :]
        _message("Hinweis: 'data' war nicht aufsteigend nach Datum sortiert und wurde sortiert.")
    dvals = fr.get("date")
    seen = set()
    dup_first = None
    n_dup = 0
    for z in dvals:
        if z in seen:
            n_dup += 1
            if dup_first is None:
                dup_first = z
        seen.add(z)
    if dup_first is not None:
        _stop("simulation: Datum %s kommt in 'data' mehrfach vor (%d doppelte Zeilen); je Tag genau eine Zeile."
              % (fmt_date(int(dup_first)), n_dup))
    nrow = fr.nrow
    if filled_attr is not None and fa_n != nrow:
        _warn("simulation: Attribut 'filled' von 'data' hat %d Zeilen, 'data' aber %d (z. B. nach Zeilenauswahl einer "
              "align_series()-Ausgabe); es wird ignoriert, aufgef\u00fcllte Tage gelten dann als Handelstage. Zeitraum "
              "besser mit align_series(..., start =, end =) w\u00e4hlen." % (fa_n, nrow))
        fa_m = None
    pre_filled = np.zeros(nrow, dtype=bool)
    if fa_m is not None and fa_m.shape[0] == nrow and fa_cols is not None:
        fc = [nm for nm in strat if nm in fa_cols]
        if fc:
            real = np.zeros(nrow, dtype=np.int64)
            for nm in fc:
                col = fr.get(nm)
                isna = np.isnan(col) if fr.is_numeric(nm) else np.array([_isna(v) for v in col])
                real += (~fa_m[:, fa_cols.index(nm)] & ~isna).astype(np.int64)
            pre_filled = real == 0
    all_na = np.ones(nrow, dtype=bool)
    for nm in strat:
        col = fr.get(nm)
        isna = np.isnan(col) if fr.is_numeric(nm) else np.array([_isna(v) for v in col], dtype=bool)
        all_na &= isna
    if all_na[0]:
        _stop("simulation: In der ersten Zeile von 'data' fehlen alle Kurse (NA); mindestens ein Asset muss am ersten "
              "Tag notieren. Daten erst ab dem ersten Kurs \u00fcbergeben.")
    pre_filled = pre_filled | all_na
    for nm in strat:
        if not fr.is_numeric(nm):
            _stop("simulation: Kursspalte '%s' muss numerisch sein (ist: %s)." % (nm, fr.r_class(nm)))
        v = fr.get(nm)
        bad = np.flatnonzero(~np.isnan(v) & ~(np.isfinite(v) & (v > 0)))
        if bad.size:
            _stop("simulation: Kursspalte '%s' enth\u00e4lt ung\u00fcltige Kurse (<= 0 oder unendlich), erstmals am %s "
                  "(Wert %s); erwartet werden positive Kursniveaus." % (nm, fmt_date(int(dvals[bad[0]])),
                                                                       r_format1(float(v[bad[0]]))))
        ok = np.flatnonzero(~np.isnan(v))
        if ok.size == 0:
            _stop("simulation: Kursspalte '%s' enth\u00e4lt nur NA." % nm)
        if ok.size < v.size:
            if ok[0] > 0:
                st0 = strat[nm].get("asset_start")
                st_new = max(int(dvals[ok[0]]), int(dvals[0]) if st0 is None else _date_or_fail(st0))
                strat[nm]["asset_start"] = st_new
                _message("Hinweis: '%s' hat erst ab %s Kurse; das Asset wird wie mit asset_start = %s behandelt."
                         % (nm, fmt_date(int(dvals[ok[0]])), fmt_date(st_new)))
            n_gap = int(np.isnan(v).sum()) - int(ok[0])
            if n_gap > 0:
                _message("Hinweis: '%s': %d fehlende Kurse (NA) per LOCF gef\u00fcllt." % (nm, n_gap))
            idx = np.zeros(v.size, dtype=np.int64)
            idx[ok] = ok + 1
            idx = np.maximum.accumulate(idx)
            idx[idx == 0] = ok[0] + 1
            fr.cols[nm] = v[idx - 1]

    if start_value is None or (_is_num(start_value) and math.isnan(float(start_value))):
        start_value = 10000.0
        _message("Hinweis: start_value ist NULL oder NA; verwendet wird der Standardwert 10000 EUR.")
    if not _is_num(start_value) or start_value <= 0:
        _stop("simulation: start_value muss eine positive Zahl sein (Anfangskapital in EUR, z. B. 10000), nicht %s."
              % r_deparse(start_value))
    start_value = float(start_value)
    if not _is_num(tax_rate) or math.isnan(float(tax_rate)) or tax_rate < 0 or tax_rate > 100:
        _stop("simulation: tax_rate muss eine einzelne Zahl in Prozent zwischen 0 und 100 sein (z. B. 26.375 f\u00fcr "
              "26,375 %%), nicht %s." % r_deparse(tax_rate))
    tax_rate = float(tax_rate)
    if 0 < tax_rate < 1:
        _warn("simulation: tax_rate = %s wird als %s %% gelesen (Prozent-Konvention); gemeint war vermutlich %s."
              % (r_format1(tax_rate), r_format1(tax_rate), r_format1(tax_rate * 100)))
    if church_tax is not None:
        if not _is_num(church_tax) or math.isnan(float(church_tax)) or church_tax < 0 or church_tax > 100:
            _stop("simulation: church_tax muss eine Zahl in Prozent zwischen 0 und 100 sein (in Deutschland 8 oder 9), "
                  "nicht %s." % ", ".join(r_format(church_tax)))
        church_tax = float(church_tax)
        if 0 < church_tax < 1:
            _warn("simulation: church_tax = %s wird als %s %% gelesen (Prozent-Konvention); gemeint war vermutlich %s."
                  % (r_format1(church_tax), r_format1(church_tax), r_format1(church_tax * 100)))
        elif church_tax > 9:
            _warn("simulation: church_tax = %s %% ist ungew\u00f6hnlich hoch (Kirchensteuer in Deutschland: 8 oder 9 %%)."
                  % r_format1(church_tax))
    if _is_true(harvest_mode) and tax_mode != "person":
        _warn("simulation: harvest_mode wirkt nur mit tax_mode = \"person\" und wird hier ignoriert.")

    def show_arg(x):
        return "NULL" if x is None else r_deparse(x)

    def chk_num(x, arg, what, mn=0.0, null_ok=False):
        if x is None and null_ok:
            return
        if not _is_num(x) or not math.isfinite(float(x)) or (mn is not None and x < mn):
            _stop("simulation: '%s' muss %s sein, nicht %s." % (arg, what, show_arg(x)))
    chk_num(sparer_pauschbetrag, "sparer_pauschbetrag", "eine einzelne endliche Zahl >= 0 (EUR je Jahr, z. B. 1000)")
    chk_num(private_sale_threshold, "private_sale_threshold",
            "eine einzelne endliche Zahl >= 0 (Freigrenze in EUR, z. B. 1000)")
    chk_num(base_rate, "base_rate", "NULL oder eine einzelne endliche Zahl (Basiszins in Prozent, z. B. 2.29; "
            "negativ erlaubt)", mn=None, null_ok=True)
    chk_num(marginal_tax_rate, "marginal_tax_rate", "NULL oder eine einzelne Zahl in Prozent von 0 bis 50 (z. B. 42)",
            null_ok=True)
    chk_num(balance_thresh, "balance_thresh", "NULL oder eine einzelne endliche Zahl >= 0 in Prozent (z. B. 5)",
            null_ok=True)
    for a, x in (("use_guenstigerpruefung", use_guenstigerpruefung),
                 ("include_soli_on_income_tax", include_soli_on_income_tax),
                 ("fractions", fractions), ("use_sparer_pauschbetrag", use_sparer_pauschbetrag)):
        if not _is_bool(x):
            _stop("simulation: '%s' muss TRUE oder FALSE sein, nicht %s." % (a, show_arg(x)))
    sparer_pauschbetrag = float(sparer_pauschbetrag)
    private_sale_threshold = float(private_sale_threshold)
    use_guenstigerpruefung = bool(use_guenstigerpruefung)
    include_soli_on_income_tax = bool(include_soli_on_income_tax)
    fractions = bool(fractions)
    use_sparer_pauschbetrag = bool(use_sparer_pauschbetrag)

    def frac_warn(x, arg, hi=1.0):
        if _is_num(x) and math.isfinite(float(x)) and 0 < x < hi:
            _warn("simulation: %s = %s wird als %s %% gelesen (Prozent-Konvention); gemeint war vermutlich %s."
                  % (arg, r_format1(x), r_format1(x), r_format1(x * 100)))
    frac_warn(base_rate, "base_rate", hi=0.05)
    frac_warn(marginal_tax_rate, "marginal_tax_rate")
    frac_warn(balance_thresh, "balance_thresh", hi=0.2)
    frac_warn(risk_free, "risk_free", hi=0.05)
    if isinstance(risk_free, str) and risk_free in fr:
        _frac_warn_col(fr, risk_free, "risk_free", hi=0.05)
    if not _is_true(dca_mode) and dca_value is not None:
        _warn("simulation: dca_value wirkt nur mit dca_mode = TRUE und wird ignoriert.")
    if not _is_true(balance_mode) and event_col is None and balance_thresh is not None:
        _warn("simulation: balance_thresh wirkt nur mit balance_mode = TRUE oder event_col (Rebalancing) und wird "
              "ignoriert.")
    if event_col is None and given["event_mode"]:
        _warn("simulation: event_mode wirkt nur zusammen mit event_col und wird ignoriert.")

    def check_days(x, arg):
        if x is None:
            return
        v = _num_vec(x)
        if v is None or any(math.isnan(d) for d in v) or any(d < 1 or d > 31 or d != r_round(d) for d in v):
            shown = r_format(list(x) if isinstance(x, (list, tuple, np.ndarray)) else x)
            _stop("simulation: %s muss ganze Zahlen von 1 bis 31 enthalten, nicht %s." % (arg, ", ".join(shown)))
    check_days(dca_days, "dca_days")
    check_days(balance_days, "balance_days")
    days_out = {}
    for a, x in (("dca_days", dca_days), ("balance_days", balance_days)):
        if x is not None:
            v = _num_vec(x)
            u = []
            for d in v:
                if d not in u:
                    u.append(d)
            if len(u) < len(v):
                _warn("simulation: %s enth\u00e4lt doppelte Tage (%s); jeder Tag ergibt nur einen Termin, verwendet wird "
                      "%s = %s." % (a, ", ".join(r_format(v)), a, r_deparse(u)))
                x = u
        days_out[a] = x
    dca_days, balance_days = days_out["dca_days"], days_out["balance_days"]
    if _is_true(split_mode) and split_thresh is not None:
        st_v = _num_vec(split_thresh)
        if st_v is None or len(st_v) != 2 or any(math.isnan(v) for v in st_v):
            shown = r_format(list(split_thresh) if isinstance(split_thresh, (list, tuple, np.ndarray)) else split_thresh)
            _stop("simulation: split_thresh muss ein Zahlenvektor c(untere, obere) der L\u00e4nge 2 sein, nicht %s."
                  % ", ".join(shown))
        if not (st_v[0] < 100 < st_v[1]):
            _warn("simulation: split_thresh = c(%s, %s) schlie\u00dft den Zielkurs 100 nicht ein (erwartet untere < 100 < "
                  "obere). Ein Split setzt den Kurs auf 100; liegt 100 au\u00dferhalb der Schwellen, folgt danach an jedem "
                  "Tag ein weiterer Split (mit fractions = FALSE jeweils mit Spitzenausgleich)."
                  % (r_format1(st_v[0]), r_format1(st_v[1])))
    if tax_mode != "funds" and (given["funds_fee"] or given["bonus_fee"]):
        gv = [a for a, g in (("funds_fee", given["funds_fee"]), ("bonus_fee", given["bonus_fee"])) if g]
        _warn("simulation: %s wirkt nur bei tax_mode = \"funds\" (hier tax_mode = \"%s\") und wird ignoriert."
              % (" und ".join(gv), tax_mode))
    if tax_mode == "funds":
        for a, x in (("funds_fee", funds_fee), ("bonus_fee", bonus_fee)):
            if not _is_num(x) or math.isnan(float(x)) or x < 0 or x > 100:
                _stop("simulation: %s muss eine Zahl in Prozent zwischen 0 und 100 sein (z. B. %s), nicht %s."
                      % (a, "0.95 f\u00fcr 0,95 % p. a." if a == "funds_fee" else "5 f\u00fcr 5 %",
                         ", ".join(r_format(x)) if x is not None else "NULL"))     # format(NULL) = "NULL"

    tariff_on = taxable_income is not None and tax_mode == "person"
    if taxable_income is not None and tax_mode != "person":
        _warn("simulation: taxable_income wirkt nur bei tax_mode = \"person\" (hier \"%s\") und wird ignoriert." % tax_mode)
    if taxable_income is None and tax_tariff is not None:
        _warn("simulation: tax_tariff wirkt nur zusammen mit taxable_income (zu versteuerndes Einkommen je Jahr) und "
              "wird ignoriert.")
    tariff_env = None
    if tariff_on:
        y0, y1 = year_of(int(dvals.min())), year_of(int(dvals.max()))
        zv = _check_taxable_income(taxable_income, list(range(y0, y1 + 1)))
        if tax_tariff is None:
            tt = read_tax_tariff()
        elif isinstance(tax_tariff, SimLevTaxTariff):
            tt = tax_tariff
        elif isinstance(tax_tariff, str):
            tt = read_tax_tariff(tax_tariff)
        else:
            _stop("simulation: tax_tariff muss NULL (mitgelieferte Tarifdatei), ein Dateipfad oder ein Objekt aus "
                  "read_tax_tariff() sein.")
        tariff_env = _TariffEnv()
        tariff_env.tariff = tt
        tariff_env.zve_all = zv["all"]
        tariff_env.zve = zv["by_year"]
        tariff_env.church_k = church_tax / 100 if (church_tax is not None and church_tax > 0) else 0.0
        tariff_env.kapest_rate = 0.25 / (1 + 0.25 * tariff_env.church_k)
        tariff_env.use_gp = bool(use_guenstigerpruefung)
        ign = [a for a, g in (("marginal_tax_rate", given["marginal_tax_rate"] and marginal_tax_rate is not None),
                              ("include_soli_on_income_tax", given["include_soli_on_income_tax"]),
                              ("soli_rate_income_tax", given["soli_rate_income_tax"])) if g]
        if ign:
            _warn("simulation: Mit taxable_income gilt der Einkommensteuertarif der Tarifdatei (ESt und Soli); %s wirkt "
                  "dann nicht." % ", ".join(ign))

    def is_private(a):
        return (a.get("tax_regime") == "private_sale" or a.get("asset_class") == "etn_deliverable"
                or (a.get("asset_class") in ("etn", "etc") and _is_true(a.get("deliverable"))))
    has_private_sale = any(is_private(a) for a in strat.values())
    if has_private_sale and marginal_tax_rate is None and tax_mode == "person" and not tariff_on:
        _warn("simulation: marginal_tax_rate ist nicht gesetzt, die Strategie enth\u00e4lt aber Assets mit tax_regime = "
              "\"private_sale\"; Gewinne nach Paragraf 23 EStG werden dann m\u00f6glicherweise nicht korrekt besteuert. "
              "marginal_tax_rate in Prozent angeben (z. B. 42).")
    if marginal_tax_rate is not None and (marginal_tax_rate < 0 or marginal_tax_rate > 50):
        _stop("simulation: marginal_tax_rate muss ein Grenzsteuersatz in Prozent zwischen 0 und 50 sein (z. B. 42 f\u00fcr "
              "42 %%), nicht %s." % r_deparse(marginal_tax_rate))
    if church_tax is not None and church_tax > 0:
        if given["tax_rate"] and abs(tax_rate - 26.375) > 1e-9:
            _warn("church_tax \u00fcberschreibt das angegebene tax_rate.")
        k = church_tax / 100
        tax_rate = 100 * 0.25 / (1 + 0.25 * k) * (1 + 0.055 + k)
    church_k = church_tax / 100 if (church_tax is not None and church_tax > 0) else 0.0
    tax_rate = tax_rate / 100
    if marginal_tax_rate is not None:
        marginal_tax_rate = float(marginal_tax_rate) / 100
    soli_rate_income_tax = float(soli_rate_income_tax) / 100
    if balance_thresh is not None:
        balance_thresh = float(balance_thresh) / 100
    balance_thresh_type = _match_arg(balance_thresh_type, ("absolute", "relative"), "balance_thresh_type")
    fee_order = _fee_spec(order_fee)
    fee_dca = fee_order if dca_fee is None else _fee_spec(dca_fee)
    fees_on = fee_order is not None or fee_dca is not None
    _FEE.current = None
    _FEE.paid = 0.0
    if _is_true(harvest_mode):
        if not isinstance(harvest_day, str) or not re.match(r"^\d{2}-\d{2}$", harvest_day) or harvest_day >= "12-31":
            _stop("harvest_day im Format 'MM-TT' und vor dem 31.12. angeben (z. B. '12-15').")
    if dca_mode:
        def one_num(x):
            return _is_num(x) and math.isfinite(float(x))
        if not one_num(dca_value) or dca_value <= 0:
            _stop("simulation: 'dca_value' muss bei dca_mode = TRUE eine einzelne endliche Zahl > 0 sein (Betrag je "
                  "Sparplan-Termin in EUR), nicht %s." % show_arg(dca_value))
        if not one_num(dca_span) or dca_span < 1 or dca_span != r_round(float(dca_span)):
            _stop("simulation: 'dca_span' muss bei dca_mode = TRUE eine einzelne ganze Zahl >= 1 sein (Perioden "
                  "zwischen zwei Terminen), nicht %s." % show_arg(dca_span))
        dca_value = float(dca_value)
    shares = [a.get("asset_share") for a in strat.values()]
    total_weight = r_sum([NA if s is None else float(s) for s in shares], na_rm=True)
    if abs(total_weight - 1.0) > 1e-6:
        _stop(_sp("simulation: Asset-Gewichte (asset_share) summieren sich auf %.4f, m\u00fcssen aber exakt 1.0 ergeben "
                  "(Anteile, z. B. 0.6 und 0.4).\n  Aktuelle Gewichte: %s", total_weight,
                  ", ".join(_sp("%s=%.3f", k, NA if v.get("asset_share") is None else float(v.get("asset_share")))
                            for k, v in strat.items())))
    effective_tax_rate = tax_rate
    if use_guenstigerpruefung and not tariff_on:
        if marginal_tax_rate is None:
            _warn("simulation: G\u00fcnstigerpr\u00fcfung aktiviert (use_guenstigerpruefung = TRUE), aber 'marginal_tax_rate' "
                  "ist nicht gesetzt.\nVerwendet wird die Abgeltungsteuer (" + r_as_character(r_round(tax_rate * 100, 2)) +
                  " %).\nF\u00fcr eine korrekte G\u00fcnstigerpr\u00fcfung marginal_tax_rate in Prozent angeben (z. B. 42).")
        else:
            personal_rate = marginal_tax_rate * (((1 + soli_rate_income_tax) if include_soli_on_income_tax else 1.0)
                                                 + church_k)
            if personal_rate < tax_rate:
                effective_tax_rate = personal_rate
                if details:
                    _cat(_sp("\u2550\u2550\u2550 G\u00fcnstigerpr\u00fcfung aktiv \u2550\u2550\u2550\n  Pers\u00f6nlicher Steuersatz: "
                             "%.2f%%\n  Effektiver Steuersatz: %.2f%% (statt %.2f%% Abgeltungsteuer)\n  Ersparnis: %.2f "
                             "Prozentpunkte\n\n", marginal_tax_rate * 100, effective_tax_rate * 100, tax_rate * 100,
                             (tax_rate - effective_tax_rate) * 100))
            else:
                if details:
                    _cat(_sp("\u2550\u2550\u2550 G\u00fcnstigerpr\u00fcfung gepr\u00fcft \u2550\u2550\u2550\n  Pers\u00f6nlicher "
                             "Steuersatz: %.2f%%\n  Abgeltungsteuer: %.2f%% \u2192 bleibt g\u00fcnstiger\n\n",
                             personal_rate * 100, tax_rate * 100))
    soli_factor_income = (1 + soli_rate_income_tax) if include_soli_on_income_tax else 1.0
    return {"data": fr, "strategy": strat, "tax_mode": tax_mode, "start_value": start_value,
            "tax_rate": tax_rate, "marginal_tax_rate": marginal_tax_rate, "effective_tax_rate": effective_tax_rate,
            "soli_factor_income": soli_factor_income, "church_k": church_k, "tariff_env": tariff_env,
            "private_sale_threshold": private_sale_threshold, "sparer_pauschbetrag": sparer_pauschbetrag,
            "use_sparer_pauschbetrag": use_sparer_pauschbetrag, "fractions": fractions,
            "fee_order": fee_order, "fee_dca": fee_dca, "fees_on": fees_on, "order_fee": order_fee,
            "dca_mode": dca_mode, "dca_value": dca_value, "dca_days": dca_days,
            "balance_mode": balance_mode, "balance_days": balance_days,
            "balance_thresh": balance_thresh, "balance_thresh_type": balance_thresh_type,
            "base_rate": base_rate, "risk_free": risk_free, "harvest_mode": harvest_mode,
            "split_mode": split_mode, "event_col": event_col, "pre_filled": pre_filled}


# ═══════════════════════════════════════════════════════════════════════════
# Phase 2: Datenvorbereitung, sim_mem, Termine (sim_prepare.R)
# ═══════════════════════════════════════════════════════════════════════════

def _locf_fill(v: np.ndarray) -> np.ndarray:
    isna = np.isnan(v)
    non_na = np.flatnonzero(~isna)
    if non_na.size == 0:
        return v
    idx = np.zeros(v.size, dtype=np.int64)
    idx[non_na] = non_na + 1
    idx = np.maximum.accumulate(idx)
    idx[idx == 0] = non_na[0] + 1
    return v[idx - 1]


def _sim_prepare_data(fr: _Frame, pre_filled: np.ndarray, base_rate_flex, base_rate_data) -> dict:
    dates = fr.get("date")
    start_date = int(dates[0])
    stopp_date = int(dates[-1])
    if _is_true(base_rate_flex) and isinstance(base_rate_data, str) and base_rate_data in fr:
        _frac_warn_col(fr, base_rate_data, "base_rate_data", hi=0.05)
    if _is_true(base_rate_flex) and isinstance(base_rate_data, str) and base_rate_data in fr:
        col = fr.get(base_rate_data)
        k = fr.kinds[base_rate_data]
        if k == "numeric" and np.isnan(col).any():
            col = col.copy()
            col[np.isnan(col)] = 0.0
            fr.cols[base_rate_data] = col
        elif k != "numeric" and all(_isna(v) for v in col):
            fr.set(base_rate_data, np.zeros(len(col)), "numeric")
    expected_days = (stopp_date - start_date) + 1
    if fr.nrow != expected_days:
        _message("Hinweis: %d Zeilen, erwartet %d Kalendertage. Fehlende Tage werden aufgef\u00fcllt (LOCF; Signale = "
                 "FALSE)." % (fr.nrow, expected_days))
        all_dates = np.arange(start_date, stopp_date + 1, dtype=np.int64)
        pos = {int(z): i for i, z in enumerate(fr.get("date"))}
        src = np.array([pos.get(int(z), -1) for z in all_dates], dtype=np.int64)
        have = src >= 0
        n = all_dates.size
        new_cols, new_kinds = {"date": all_dates.astype(np.float64)}, {"date": "date"}
        names = ["date"] + [nm for nm in fr.names if nm != "date"]
        for nm in names[1:]:
            v = fr.cols[nm]
            k = fr.kinds[nm]
            if k in ("numeric", "date", "posixct"):
                out = np.full(n, NA)
                out[have] = v[src[have]]
                if k == "numeric":
                    out = _locf_fill(out)
            else:
                out = np.empty(n, dtype=object)
                out[:] = None
                out[have] = v[src[have]]
                if k == "logical":
                    out = np.array([False if x is None else x for x in out], dtype=object)
            new_cols[nm], new_kinds[nm] = out, k
        filled = np.ones(n, dtype=bool)
        filled[have] = np.asarray(pre_filled, dtype=bool)[src[have]]
        new_cols[".filled"], new_kinds[".filled"] = filled, "filled"
        names.append(".filled")
        fr.names, fr.cols, fr.kinds = names, new_cols, new_kinds
    elif np.any(pre_filled):
        fr.set(".filled", np.asarray(pre_filled, dtype=bool), "filled")
    return {"data": fr, "start_date": start_date, "stopp_date": stopp_date}


def _signal_col(fr: _Frame, col: str | None, n: int) -> np.ndarray:
    if col is None:
        return np.array([False] * n, dtype=object)
    v = fr.get(col)
    if fr.kinds[col] == "numeric":
        return np.array(v, dtype=np.float64)
    return np.array(v, dtype=object)


def _sim_build_state(fr: _Frame, strategy: dict, start_value: float, start_date: int, stopp_date: int,
                     sparer_pauschbetrag: float, use_sparer_pauschbetrag: bool, base_rate, base_rate_flex,
                     base_rate_data) -> dict:
    n = fr.nrow
    sim: dict = {
        "assets": {}, "status": {}, "market": {}, "trades": {}, "report": {},
        "totals": {
            "total_value": start_value, "total_taxes": 0.0, "loss_capital_gains": 0.0, "loss_private_sales": 0.0,
            "private_sale_gains_ytd": 0.0, "private_sale_losses_ytd": 0.0,
            "sparer_pauschbetrag_annual": sparer_pauschbetrag,
            "sparer_pauschbetrag_remaining": sparer_pauschbetrag if use_sparer_pauschbetrag else 0.0,
            "sparer_pauschbetrag_used_total": 0.0, "current_year": year_of(start_date),
            "cgt_base_taxed_ytd": 0.0, "cgt_loss_added_ytd": 0.0, "cgt_loss_used_ytd": 0.0,
            "cgt_pool_start_ytd": 0.0,
        },
    }
    for name, a in strategy.items():
        ac = a.get("asset_class")
        deliverable = _is_true(a.get("deliverable"))
        regime = a.get("tax_regime")
        if regime is None:
            regime = {"etf": "investment_fund", "etn": "private_sale" if deliverable else "capital_gains",
                      "etc": "private_sale" if deliverable else "capital_gains", "certificate": "capital_gains",
                      "etn_standard": "capital_gains", "etn_deliverable": "private_sale"}.get(ac, "capital_gains")
        st_raw = a.get("asset_start")
        bonus = a.get("asset_bonus")
        sim["assets"][name] = {
            "class": ac, "style": a.get("action_type"),
            "start": start_date if st_raw is None else _date_or_fail(st_raw),
            "tax_regime": regime, "bonus": (0.0 if bonus is None else float(bonus)) / 100,
            "deliverable": a.get("deliverable") if a.get("deliverable") is not None else False,
        }
        if a.get("action_type") == "signal":
            sb, ss = a.get("signal_buy"), a.get("signal_sell")
            if sb is None or sb not in fr:
                _stop("simulation: signal_buy-Spalte '%s' fehlt im Datensatz (Asset '%s')." % (sb if sb is not None
                                                                                            else "NULL", name))
            if ss is None or ss not in fr:
                _stop("simulation: signal_sell-Spalte '%s' fehlt im Datensatz (Asset '%s')." % (ss if ss is not None
                                                                                             else "NULL", name))
        share = float(a.get("asset_share"))
        sim["status"][name] = {"count": 0.0, "price": 0.0, "worth": 0.0, "money": share * start_value,
                               "total": share * start_value, "target": share, "actual": share, "differ": 0.0}
        if base_rate_flex:
            if base_rate_data is None or base_rate_data not in fr:
                if base_rate_data is None:
                    _stop("simulation: base_rate_flex = TRUE braucht base_rate_data (Name der Basiszins-Spalte in data, "
                          "Prozent p. a.); base_rate_data fehlt.")
                _stop("simulation: base_rate_data-Spalte '%s' fehlt in data (base_rate_flex = TRUE braucht eine "
                      "Basiszins-Spalte in Prozent p. a.; vorhanden: %s)." % (base_rate_data, ", ".join(fr.names)))
            br = np.array(fr.get(base_rate_data), dtype=np.float64)
            br[np.isnan(br)] = 0.0
        else:
            br = np.full(n, float(base_rate) if base_rate is not None else 0.0)
        spread_a = a.get("asset_spread")
        sim["market"][name] = {
            "asset_day": np.arange(start_date, stopp_date + 1, dtype=np.int64),
            "base_rates": br,
            "asset_price": np.array(fr.get(name), dtype=np.float64),
            "signal_buy": _signal_col(fr, a.get("signal_buy"), n),
            "signal_sell": _signal_col(fr, a.get("signal_sell"), n),
            "spread_rate": (0.0 if spread_a is None else float(spread_a)) / 100,
        }
        sim["trades"][name] = {"buys": [], "buy_count": 0, "sells": [], "sell_count": 0, "taxes": [],
                               "tax_count": 0, "fees": [], "fee_count": 0, "fifo_front": 1}
        st = sim["status"][name]
        worth0, money0, total0 = np.zeros(n), np.zeros(n), np.zeros(n)
        worth0[0], money0[0], total0[0] = st["worth"], st["money"], st["total"]
        sim["report"][name] = {"worth": worth0, "money": money0, "flows": np.zeros(n), "total": total0,
                               "share": np.zeros(n)}
    return sim


def _as_logical_col(fr: _Frame, col: str) -> np.ndarray:
    v = fr.get(col)
    k = fr.kinds[col]
    out = np.zeros(len(v), dtype=bool)
    for i, x in enumerate(v):
        if _isna(x):
            continue
        if k == "numeric":
            out[i] = x != 0
        elif isinstance(x, str):
            out[i] = x in ("TRUE", "true", "T", "True")
        else:
            out[i] = bool(x)
    return out


def _sim_build_calendar(fr: _Frame, sim: dict, strategy: dict, start_date: int, stopp_date: int, liquidate,
                        dca_mode, dca_span, dca_unit, dca_days, dca_value, dca_anchor, dca_start, dca_skip,
                        balance_mode, balance_span, balance_unit, balance_days, balance_anchor, balance_start,
                        balance_skip, event_col, event_mode, event_weight, split_mode, split_thresh) -> dict:
    flag_date = np.arange(start_date, stopp_date + 1, dtype=np.int64)
    n = flag_date.size
    if ".filled" in fr:
        flag_filled = np.asarray(fr.get(".filled"), dtype=bool).copy()
    else:
        flag_filled = np.zeros(n, dtype=bool)
    fr.drop(".filled")
    flag_assets = list(strategy.keys())
    liquidate = bool(liquidate)
    flag_liquidate = liquidate & (flag_date == stopp_date)
    for a, sd0, mode in (("dca", dca_start, dca_mode), ("balance", balance_start, balance_mode)):
        if not _is_true(mode) or sd0 is None:
            continue
        sd1 = _as_date(sd0)
        if sd1 is None:
            _stop("simulation: %s_start = '%s' ist kein Datum (erwartet Date oder \"JJJJ-MM-TT\")."
                  % (a, r_format1(sd0) if not isinstance(sd0, str) else sd0))
        if sd1 > stopp_date:
            _stop("simulation: %s_start (%s) liegt nach dem letzten Datentag (%s); es g\u00e4be keine Termine."
                  % (a, fmt_date(sd1), fmt_date(stopp_date)))
    flag_rebalance = _calculate_dates_flags(balance_mode, balance_span, balance_unit, balance_days, flag_date, None,
                                            balance_anchor, balance_start, balance_skip, liquidate)
    flag_dca = _calculate_dates_flags(dca_mode, dca_span, dca_unit, dca_days, flag_date, dca_value, dca_anchor,
                                      dca_start, dca_skip, liquidate)
    md = [from_days(int(z)) for z in flag_date]
    flag_taxes = np.array([x.month == 12 and x.day == 31 for x in md], dtype=bool)
    event_mode = _match_arg(event_mode, ("additional", "replace"), "event_mode")
    flag_event = np.zeros(n, dtype=bool)
    if event_col is not None:
        if event_col not in fr:
            _stop("simulation: event_col '%s' nicht im Datensatz gefunden." % event_col)
        flag_event = _as_logical_col(fr, event_col)
        if event_weight is not None:
            if not isinstance(event_weight, Mapping) or any(str(k) == "" for k in event_weight):
                _stop("simulation: event_weight muss benannt sein (Asset = Spaltenname), z. B. c(A = \"wA\", B = \"wB\").")
            event_weight = {str(k): v for k, v in event_weight.items()}
            unk = [k for k in event_weight if k not in strategy]
            if unk:
                _stop("simulation: event_weight nennt unbekannte Assets: %s." % ", ".join(unk))
            for nm, col in event_weight.items():
                if not isinstance(col, str) or col not in fr:
                    _stop("simulation: event_weight-Spalte '%s' (Asset '%s') fehlt in 'data'."
                          % (",".join(col) if isinstance(col, (list, tuple)) else str(col), nm))
                if not fr.is_numeric(col):
                    _stop("simulation: event_weight-Spalte '%s' muss nicht negative Zahlen enthalten." % col)
                wv = fr.get(col)[flag_event]
                if np.any(wv[~np.isnan(wv)] < 0):
                    _stop("simulation: event_weight-Spalte '%s' muss nicht negative Zahlen enthalten." % col)
            fehlt = [nm for nm in strategy if nm not in event_weight]
            if fehlt:
                _warn("simulation: event_weight nennt nicht alle Assets (es fehlt: %s); an Event-Tagen gelten dann die "
                      "Strategie-Gewichte." % ", ".join(fehlt))
        guard = (flag_date != flag_date[0]) & ((not liquidate) | (flag_date != stopp_date))
        flag_event = flag_event & guard
        if event_mode == "additional":
            flag_rebalance = flag_rebalance | flag_event
        else:
            flag_rebalance = flag_event.copy()
    flag_trade = ~flag_rebalance & (flag_date != stopp_date) & ~flag_filled
    flag_split = _calculate_split_flags(sim, 100.0, split_mode, flag_date, split_thresh)
    flag_dca_n = flag_dca.astype(np.float64)
    if flag_filled.any():
        mon = [_ym(int(z)) for z in flag_date]
        flag_rebalance = _shift_off_filled(flag_rebalance, flag_filled, mon)
        flag_dca_n = _shift_off_filled(flag_dca_n, flag_filled, mon)
        flag_dca = flag_dca_n > 0
        flag_split = _shift_off_filled(flag_split, flag_filled, mon)
        flag_liquidate = _shift_off_filled(flag_liquidate, flag_filled, mon)
        if flag_liquidate.any():
            flag_rebalance = flag_rebalance & ~flag_liquidate
            flag_dca_n = np.where(flag_liquidate, 0.0, flag_dca_n)
            flag_dca = flag_dca_n > 0
        flag_trade = ~flag_rebalance & (flag_date != stopp_date) & ~flag_filled
    for name in flag_assets:
        st_a = sim["assets"][name]["start"]
        if st_a is not None and st_a > stopp_date:
            _stop("simulation: asset_start von '%s' (%s) liegt nach dem letzten Datentag (%s); das Asset w\u00e4re nie "
                  "handelbar. asset_start auf ein Datum im Datenzeitraum setzen oder das Asset aus der Strategie "
                  "entfernen." % (name, fmt_date(st_a), fmt_date(stopp_date)))
    return {"data": fr,
            "flags": {"flag_date": flag_date, "flag_filled": flag_filled, "flag_assets": flag_assets,
                      "flag_liquidate": flag_liquidate, "flag_rebalance": flag_rebalance, "flag_dca": flag_dca,
                      "flag_dca_n": flag_dca_n, "flag_taxes": flag_taxes, "flag_event": flag_event,
                      "flag_trade": flag_trade, "flag_split": flag_split},
            "event_weight": event_weight if event_col is not None else None}


def _sim_init_weights(sim: dict, flag_assets: list, flag_date: np.ndarray, start_value: float) -> dict:
    initial_assets = [nm for nm in flag_assets if sim["assets"][nm]["start"] <= int(flag_date[0])]
    if not initial_assets:
        _stop("simulation: Kein Asset ist am ersten Datentag (%s) handelbar (asset_start bzw. erste Kurse sp\u00e4ter); "
              "mindestens ein Asset muss ab Beginn handelbar sein." % fmt_date(int(flag_date[0])))
    initial_weights_sum = r_sum([sim["status"][nm]["actual"] for nm in initial_assets])
    all_weights_sum = r_sum([sim["status"][nm]["actual"] for nm in flag_assets])
    for nm in flag_assets:
        st = sim["status"][nm]
        target_weight = st["actual"] / all_weights_sum
        if nm in initial_assets:
            normalized_weight = st["actual"] / initial_weights_sum
            st["actual"] = target_weight
            st["money"] = start_value * normalized_weight
            st["total"] = start_value * normalized_weight
        else:
            st["actual"] = target_weight
            st["differ"] = 0.0
            st["money"] = 0.0
            st["total"] = 0.0
    return {"sim": sim, "initial_assets": initial_assets}


def _sim_build_schedule(sim: dict, fl: dict, stopp_date: int, tax_mode: str, harvest_mode, harvest_day) -> dict:
    flag_date, flag_filled, flag_assets = fl["flag_date"], fl["flag_filled"], fl["flag_assets"]
    n = flag_date.size
    asset_starts = [int(sim["assets"][nm]["start"]) for nm in flag_assets]
    if flag_filled.any():
        mon = [_ym(int(z)) for z in flag_date]
        pos = {int(z): i for i, z in enumerate(flag_date)}
        shifted = []
        for dz in asset_starts:
            i = pos.get(dz)
            if i is None or not flag_filled[i]:
                shifted.append(dz)
                continue
            j = i + 1
            while j < n and flag_filled[j]:
                j += 1
            if j >= n or mon[j] != mon[i]:
                j = i - 1
                while j >= 0 and flag_filled[j]:
                    j -= 1
            shifted.append(int(flag_date[max(min(j, n - 1), 0)]))
        asset_starts = shifted
    start_set = set(asset_starts)
    flag_active = np.array([int(z) in start_set for z in flag_date], dtype=bool)
    pos_all = {int(z): i + 1 for i, z in enumerate(flag_date)}
    asset_start_indices = [pos_all.get(z, 1) for z in asset_starts]
    flag_harvest = np.zeros(n, dtype=bool)
    if _is_true(harvest_mode) and tax_mode == "person":
        mds = [from_days(int(z)) for z in flag_date]
        md_s = ["%02d-%02d" % (d.month, d.day) for d in mds]
        yrs = [d.year for d in mds]
        seen_years = []
        for y in yrs:
            if y not in seen_years:
                seen_years.append(y)
        for y in seen_years:
            js = [i for i in range(n) if yrs[i] == y and md_s[i] >= harvest_day and md_s[i] < "12-31"
                  and not flag_filled[i]]
            if js:
                flag_harvest[js[0]] = True
    flag_fund_fee = (tax_mode == "funds") & (fl["flag_taxes"] | (flag_date == stopp_date))
    flag_liquidate = fl["flag_liquidate"]
    if tax_mode == "funds" and flag_liquidate.any() and not flag_liquidate[n - 1]:
        liq_i = int(np.flatnonzero(flag_liquidate).max())
        flag_fund_fee = flag_fund_fee.copy()
        flag_fund_fee[liq_i + 1:] = False
        flag_fund_fee[liq_i] = True
    flag_definite = flag_active | fl["flag_split"] | fl["flag_dca"] | fl["flag_rebalance"] | fl["flag_taxes"] | \
        flag_liquidate | flag_harvest | flag_fund_fee
    strategy_types = {nm: sim["assets"][nm]["style"] for nm in flag_assets}
    has_bnh = any(t == "bnh" for t in strategy_types.values())
    has_signal = any(t == "signal" for t in strategy_types.values())
    tax_regimes = {nm: sim["assets"][nm]["tax_regime"] for nm in flag_assets}
    spread_rates = {nm: sim["market"][nm]["spread_rate"] for nm in flag_assets}
    flag_signal = np.zeros(n, dtype=bool)
    if has_signal:
        for nm in flag_assets:
            if sim["assets"][nm]["style"] == "signal":
                b = np.array([_truthy(x) for x in sim["market"][nm]["signal_buy"]], dtype=bool)
                s = np.array([_truthy(x) for x in sim["market"][nm]["signal_sell"]], dtype=bool)
                flag_signal = flag_signal | b | s
    flag_bnh_potential = np.zeros(n, dtype=bool)
    if has_bnh:
        flag_bnh_potential[0] = True
    flag_slow_path = flag_definite | flag_signal | flag_bnh_potential
    flag_year_change = np.zeros(n, dtype=bool)
    flag_vp_settle = np.zeros(n, dtype=bool)
    if tax_mode == "person":
        years = np.array([year_of(int(z)) for z in flag_date], dtype=np.int64)
        if n > 1:
            flag_year_change[1:] = np.diff(years) > 0
        for ys in np.flatnonzero(flag_year_change):
            j = ys
            while j < n and flag_filled[j] and years[j] == years[ys]:
                j += 1
            if j >= n or years[j] != years[ys]:
                j = ys
            flag_vp_settle[j] = True
    flag_slow_path = flag_slow_path | flag_vp_settle
    flag_individual = flag_slow_path | flag_year_change
    out = dict(fl)
    out.update({"asset_starts": asset_starts, "flag_active": flag_active, "asset_start_indices": asset_start_indices,
                "flag_harvest": flag_harvest, "flag_fund_fee": flag_fund_fee, "strategy_types": strategy_types,
                "tax_regimes": tax_regimes, "spread_rates": spread_rates, "flag_slow_path": flag_slow_path,
                "flag_year_change": flag_year_change, "flag_vp_settle": flag_vp_settle,
                "individual_days": [int(i) + 1 for i in np.flatnonzero(flag_individual)], "n_total_days": n})
    return out


# ═══════════════════════════════════════════════════════════════════════════
# Phase 3: Zahlungs- und Abrechnungshelfer (sim_actions.R)
# ═══════════════════════════════════════════════════════════════════════════

class _Actions:
    """Helfer der Tagesschleife (R: ``.sim_make_actions``); teilt ``tax_unpaid_total``."""

    def __init__(self, cfg: dict, fl: dict, details: bool):
        self.cfg = cfg
        self.fl = fl
        self.details = details
        self.tax_unpaid_total = 0.0

    # ── Kauf mit Sparplan- bzw. Ordergebühr ─────────────────────────────────
    def buy_with_fee(self, sim: dict, name: str, time: int, reason: str) -> dict:
        cfg, fl = self.cfg, self.fl
        sr = fl["spread_rates"][name]
        if cfg["fees_on"] and fl["flag_dca"][time - 1] and fl["strategy_types"][name] == "bnh":
            money = sim["status"][name]["money"]
            dca_part = _rmin(_rmax(0.0, sim["report"][name]["flows"][time - 1]), money)
            if time == 1 and money - dca_part > 0.005:
                _FEE.current = cfg["fee_order"]
                sim["status"][name]["money"] = money - dca_part
                sim = _perform_trade_buy(sim, name, time, reason, sr, cfg["fractions"], self.details)
                sim["status"][name]["money"] = sim["status"][name]["money"] + dca_part
            _FEE.current = cfg["fee_dca"]
        sim = _perform_trade_buy(sim, name, time, reason, sr, cfg["fractions"], self.details)
        if cfg["fees_on"]:
            _FEE.current = cfg["fee_order"]
        return sim

    def _sell(self, sim, name, time, reason, spread, count=None, price=None, tax_mode=None):
        cfg = self.cfg
        return _perform_trade_sell(sim, name, time, cfg["tax_mode"] if tax_mode is None else tax_mode,
                                   cfg["tax_rate"], cfg["effective_tax_rate"], cfg["marginal_tax_rate"],
                                   cfg["private_sale_threshold"], cfg["use_sparer_pauschbetrag"],
                                   self.fl["tax_regimes"][name], reason, spread, self.details, count=count, price=price)

    # ── Verkaufsmenge nach Steuer und Gebühr ────────────────────────────────
    def sell_count_net(self, sim: dict, name: str, need: float, time: int, round_up: bool = False) -> dict:
        cfg, fl = self.cfg, self.fl
        fr_ = cfg["fractions"] or round_up

        def sc_of(target):
            return _calculate_sell_count(sim, name, target, time, fl["spread_rates"][name], fr_, cfg["tax_mode"],
                                         cfg["effective_tax_rate"], fl["tax_regimes"][name])
        fee = _FEE.current
        target = need
        if fee is not None:
            px = _apply_spread(float(sim["market"][name]["asset_price"][time - 1]), fl["spread_rates"][name], "sell")
            for _ in range(3):
                target = need + _fee_amount(fee, _rmax(sc_of(target)["sell_count"], 1e-12) * px)
        res = sc_of(target)
        if round_up and not cfg["fractions"] and res["sell_count"] > 0:
            res = {"sell_count": _rmin(sim["status"][name]["count"], float(math.ceil(res["sell_count"] - 1e-9))),
                   "fifo_price": None}
        return res

    # ── Bargeld für Fondskosten ────────────────────────────────────────────
    def raise_cash(self, sim: dict, name: str, need: float, time: int, reason: str) -> dict:
        cfg = self.cfg
        short = need - sim["status"][name]["money"]
        if short <= 0 or sim["status"][name]["count"] <= 0:
            return sim
        fee_keep = _FEE.current
        _FEE.current = None
        try:
            if cfg["tax_mode"] != "person":
                px = float(sim["market"][name]["asset_price"][time - 1])
                n_sell = _rmin(sim["status"][name]["count"],
                               short / px if cfg["fractions"] else float(math.ceil(short / px - 1e-9)))
            else:
                n_sell = _calculate_sell_count(sim, name, short, time, 0.0, cfg["fractions"], cfg["tax_mode"],
                                               cfg["effective_tax_rate"], self.fl["tax_regimes"][name])["sell_count"]
            sim = self._sell(sim, name, time, reason, 0.0, count=n_sell)
            if not cfg["fractions"] and sim["status"][name]["money"] < need - 1e-9 and sim["status"][name]["count"] > 0:
                sim = self._sell(sim, name, time, reason, 0.0, count=_rmin(1.0, sim["status"][name]["count"]))
        finally:
            _FEE.current = fee_keep
        return sim

    # ── Zahlung aus einem Asset ────────────────────────────────────────────
    def pay_one(self, sim: dict, name: str, amount: float, time: int, label: str) -> tuple[dict, float]:
        cfg, fl, details = self.cfg, self.fl, self.details
        fd = fmt_date(int(fl["flag_date"][time - 1]))
        money = sim["status"][name]["money"]
        if money >= amount:
            sim["status"][name]["money"] = money - amount
            if details:
                _cat(_sp("Steuerereignis:\tZahlung %s %.2f EUR f\u00fcr %s aus dem Geldbestand am %s\n",
                         label, amount, name, fd))
            return sim, 0.0
        remaining = amount
        if money > 0:
            remaining = amount - money
            sim["status"][name]["money"] = 0.0
            if details:
                _cat(_sp("Steuerereignis:\tTeilzahlung %s %.2f EUR aus dem Geldbestand am %s\n", label, money, fd))
        c0 = sim["status"][name]["money"]

        def raised(sm):
            return sm["status"][name]["money"] - c0
        for k in range(1, 11):
            short = remaining - raised(sim)
            if short <= 0.005 or sim["status"][name]["count"] <= 0:
                break
            sell_result = self.sell_count_net(sim, name, short, time, round_up=True)
            n_sell = sell_result["sell_count"]
            if k > 1 or not (n_sell > 0):
                cnt = sim["status"][name]["count"]
                n_sell = _rmax(n_sell, _rmin(cnt, 1e-6) if cfg["fractions"] else _rmin(1.0, cnt))
            before = raised(sim)
            sim = self._sell(sim, name, time, "Steuerereignis:", fl["spread_rates"][name], count=n_sell,
                             price=sell_result["fifo_price"])
            if raised(sim) <= before:
                break
        short = remaining - raised(sim)
        unpaid = 0.0
        if short <= 0.005:
            sim["status"][name]["money"] = sim["status"][name]["money"] - remaining
        else:
            sim["status"][name]["money"] = c0
            unpaid = short
        if details and remaining - unpaid > 0:
            _cat(_sp("\t\t=> Anteile verkauft f\u00fcr den Rest von %.2f EUR (%s)\n", remaining - unpaid, label))
        return sim, unpaid

    # ── Steuerzahlung mit Rückgriff auf die übrigen Assets ──────────────────
    def pay_tax(self, sim: dict, name: str, amount: float, time: int, label: str) -> dict:
        fl = self.fl
        sim, unpaid = self.pay_one(sim, name, amount, time, label)
        if unpaid > 1e-6:
            others = [nm for nm in fl["flag_assets"] if nm != name]
            val = {nm: sim["status"][nm]["count"] * float(sim["market"][nm]["asset_price"][time - 1]) +
                   _rmax(0.0, sim["status"][nm]["money"]) for nm in others}
            order = sorted(range(len(others)), key=lambda i: -val[others[i]])
            for i in order:
                nm = others[i]
                if unpaid <= 1e-6:
                    break
                if not (val[nm] > 0):
                    continue
                sim, unpaid = self.pay_one(sim, nm, unpaid, time, label)
        if unpaid > 1e-6:
            sim["status"][name]["money"] = sim["status"][name]["money"] - unpaid
            self.tax_unpaid_total = self.tax_unpaid_total + unpaid
            _warn(_sp("simulation: %s von %.2f EUR am %s: das Depot reicht nicht aus; %.2f EUR bleiben als negativer "
                      "Geldbestand (Steuerschuld) bei '%s'.", label, amount, fmt_date(int(fl["flag_date"][time - 1])),
                      unpaid, name))
        return sim

    # ── Vorabpauschale bezahlen ───────────────────────────────────────────
    def pay_vp(self, sim: dict, name: str, tax_debt: float, time: int, meta: dict, prepaid: float = 0.0) -> dict:
        if prepaid == 0:
            sim = self.pay_tax(sim, name, tax_debt, time, "Vorabpauschale")
        elif tax_debt - prepaid > 1e-9:
            sim = self.pay_tax(sim, name, tax_debt - prepaid, time, "Vorabpauschale")
        elif tax_debt - prepaid < -1e-9:
            sim["status"][name]["money"] = sim["status"][name]["money"] + (prepaid - tax_debt)
        sim["totals"]["total_taxes"] = sim["totals"]["total_taxes"] + tax_debt
        entry = {"event_date": int(self.fl["flag_date"][time - 1]), "assessment_date": meta["assessment_date"],
                 "event_type": "Vorabpauschale", "flat_rate_gross": meta["flat_rate"],
                 "bonus_applied": meta["bonus"], "flat_rate_taxable": meta["flat_rate"] * (1 - meta["bonus"]),
                 "spb_used": meta["spb_used"], "taxes_paid": tax_debt}
        tr = sim["trades"][name]
        tr["tax_count"] += 1
        tr["taxes"].append(entry)
        return sim

    # ── § 23-Steuer bzw. Nachzahlung der Veranlagung ───────────────────────
    def settle_p23(self, sim: dict, time: int) -> dict:
        tariff_env = self.cfg["tariff_env"]
        details = self.details
        due = sim["totals"].pop("p23_due", None) or {}
        info = tariff_env.due_info if tariff_env is not None else None
        if tariff_env is not None:
            tariff_env.due_info = None
        fd = fmt_date(int(self.fl["flag_date"][time - 1]))
        label = ("Steuer aus der Veranlagung %s" % "/".join(str(i["year"]) for i in info)) if info else "\u00a7 23-Steuer"
        if details and info and any(v > 0 for v in due.values()):
            for i in info:
                rest = i["D"] - i["p23"] - i["ded"]
                _cat(_sp("Steuerereignis:\tVeranlagung %d: Nachzahlung %.2f EUR (davon \u00a7 23 %.2f EUR, "
                         "Kirchensteuer-Sonderausgaben %.2f EUR%s) am %s, aufgeteilt %s\n", i["year"], i["D"], i["p23"],
                         i["ded"], _sp(", G\u00fcnstigerpr\u00fcfung %.2f EUR", rest) if abs(rest) >= 0.005 else "", fd,
                         "nach dem \u00a7 23-Jahressaldo je Asset" if i["by_p23"] else "zu gleichen Teilen auf die Assets"))
        for nm, v in due.items():
            if not (v > 0):
                continue
            if details:
                if info:
                    _cat(_sp("\t\t=> Anteil %s: %.2f EUR\n", nm, v))
                else:
                    _cat(_sp("Steuerereignis:\t\u00a7 23 EStG: Steuer %.2f EUR (%s) am %s\n", v, nm, fd))
            sim = self.pay_tax(sim, nm, v, time, label)
            tr = sim["trades"][nm]
            tr["tax_count"] += 1
            tr["taxes"].append({"event_date": int(self.fl["flag_date"][time - 1]), "event_type": "Private sale tax",
                                "taxes_paid": v})
        return sim

    # ── Erstattung aus der Günstigerprüfung ───────────────────────────────
    def gp_pending(self) -> bool:
        te = self.cfg["tariff_env"]
        return te is not None and te.refund_due > 0

    def settle_gp(self, sim: dict, time: int) -> dict:
        te = self.cfg["tariff_env"]
        refund = te.refund_due
        te.refund_due = 0.0
        fa = self.fl["flag_assets"]
        w = [float(sim["status"][nm].get("actual") if sim["status"][nm].get("actual") is not None else 0.0)
             for nm in fa]
        sw = r_sum(w)
        w = [x / sw for x in w] if sw > 0 else [1 / len(fa)] * len(fa)
        for nm, wi in zip(fa, w):
            sim["status"][nm]["money"] = sim["status"][nm]["money"] + refund * wi
        if self.details:
            _cat(_sp("Steuerereignis:\tG\u00fcnstigerpr\u00fcfung: Erstattung %.2f EUR in den Geldbestand am %s\n",
                     refund, fmt_date(int(self.fl["flag_date"][time - 1]))))
        return sim

    # ── Steuer der offenen Vorabpauschalen ─────────────────────────────────
    def vp_taxes(self, sim: dict, pend: list) -> tuple[dict, list]:
        cfg = self.cfg
        res: list = [None] * len(pend)
        if len(pend) > 1:
            taxable = [p["flat_rate"] * (1 - p["bonus"]) for p in pend]
            st = r_sum(taxable)
            pooled = core.vp_tax(st, 0.0, sim["totals"], cfg["effective_tax_rate"], cfg["use_sparer_pauschbetrag"])
            share = [t / st for t in taxable] if st > 0 else [1 / len(pend)] * len(pend)
            for j in range(len(pend)):
                res[j] = {"tax": pooled["tax"] * share[j], "spb_used": pooled["spb_used"] * share[j]}
        elif len(pend) == 1:
            p = pend[0]
            r1 = core.vp_tax(p["flat_rate"], p["bonus"], sim["totals"], cfg["effective_tax_rate"],
                             cfg["use_sparer_pauschbetrag"])
            res[0] = {"tax": r1["tax"], "spb_used": r1["spb_used"]}
        return sim, res

    # ── Zufluss der festgesetzten Vorabpauschalen ──────────────────────────
    def settle_vp(self, sim: dict, time: int, prepaid: list | None = None) -> dict:
        pend = sim["totals"].pop("vp_pending", None) or []
        sim, res = self.vp_taxes(sim, pend)
        fd = fmt_date(int(self.fl["flag_date"][time - 1]))
        for j, p in enumerate(pend):
            result = res[j]
            pre = 0.0 if prepaid is None else prepaid[j]
            if self.details:
                _cat(_sp("Steuerereignis:\tVorabpauschale %s (festgesetzt %s): %.2f EUR, nach TFS %.2f EUR, SPB %.2f EUR, "
                         "Steuer %.2f EUR am %s\n", p["name"], fmt_date(p["assessment_date"]), p["flat_rate"],
                         p["flat_rate"] * (1 - p["bonus"]), result["spb_used"], result["tax"], fd))
            if result["tax"] > 0 or pre > 0:
                sim = self.pay_vp(sim, p["name"], result["tax"], time,
                                  {"flat_rate": p["flat_rate"], "bonus": p["bonus"], "spb_used": result["spb_used"],
                                   "assessment_date": p["assessment_date"]}, prepaid=pre)
        return sim


# ═══════════════════════════════════════════════════════════════════════════
# Phase 4: Tagesschleife (sim_loop.R)
# ═══════════════════════════════════════════════════════════════════════════

def _sim_run_days(sim: dict, fl: dict, cfg: dict, act: _Actions, fr: _Frame, strategy: dict, liquidate,
                  event_weight, split_thresh, funds_fee, bonus_fee, balance_dca, harvest_loss_pot,
                  details: bool) -> dict:
    flag_date, flag_assets = fl["flag_date"], fl["flag_assets"]
    flag_rebalance = fl["flag_rebalance"].copy()
    flag_trade = fl["flag_trade"].copy()
    fl = dict(fl)
    fl["flag_rebalance"], fl["flag_trade"] = flag_rebalance, flag_trade
    tax_mode = cfg["tax_mode"]
    prev_end = 0
    active_assets: list = []
    for time in fl["individual_days"]:
        t0 = time - 1
        if time > prev_end + 1:
            core.batch_market_update(sim, flag_assets, prev_end + 1, time - 1)
        if fl["flag_year_change"][t0]:
            sim = _handle_year_change(sim, int(flag_date[t0]), cfg["marginal_tax_rate"], cfg["private_sale_threshold"],
                                      cfg["sparer_pauschbetrag"], cfg["use_sparer_pauschbetrag"],
                                      cfg["soli_factor_income"], cfg["effective_tax_rate"], details, cfg["church_k"],
                                      cfg["tariff_env"])
        if not fl["flag_slow_path"][t0]:
            core.perform_market_update(sim, flag_assets, time)
            prev_end = time
            continue
        if fl["flag_active"][t0] or len(active_assets) == 0:
            active_assets = [nm for nm, si in zip(flag_assets, fl["asset_start_indices"]) if si <= time]
        if cfg["fees_on"]:
            _FEE.current = cfg["fee_order"]
        flag_fast_report = True
        if tax_mode == "person" and fl["flag_vp_settle"][t0] and (sim["totals"].get("vp_pending") or
                                                                   sim["totals"].get("p23_due") or act.gp_pending()):
            if sim["totals"].get("vp_pending"):
                sim = act.settle_vp(sim, time)
            if sim["totals"].get("p23_due"):
                sim = act.settle_p23(sim, time)
            if act.gp_pending():
                sim = act.settle_gp(sim, time)
            core.calculate_total_report(sim, flag_assets, time)
            flag_fast_report = False
        if fl["flag_active"][t0]:
            sim, rebalance_now = _sim_day_activate(sim, time, active_assets, fl, cfg, details)
            if rebalance_now:
                flag_rebalance[t0] = True
                flag_trade[t0] = False
            flag_fast_report = False
        if fl["flag_split"][t0]:
            sim = _sim_day_split(sim, time, active_assets, fl, cfg, act, split_thresh, details)
            flag_fast_report = False
        if fl["flag_dca"][t0]:
            sim = _sim_day_dca(sim, time, active_assets, fl, cfg, strategy, balance_dca, details)
            flag_fast_report = False
        if flag_trade[t0]:
            sim, traded = _sim_day_trade(sim, time, active_assets, fl, cfg, act, details)
            if traded:
                flag_fast_report = False
        if flag_rebalance[t0]:
            sim = _sim_day_rebalance(sim, time, active_assets, fl, cfg, act, fr, event_weight, details)
            flag_fast_report = False
        if fl["flag_harvest"][t0]:
            sim = _sim_day_harvest(sim, time, active_assets, fl, cfg, harvest_loss_pot, details)
            flag_fast_report = False
        if fl["flag_taxes"][t0]:
            sim = _sim_day_assess_vp(sim, time, fl, cfg, liquidate, details)
            flag_fast_report = False
        if fl["flag_fund_fee"][t0]:
            sim = _sim_day_fund_fee(sim, time, fl, act, funds_fee, bonus_fee, details)
            flag_fast_report = False
        if fl["flag_liquidate"][t0]:
            sim = _sim_day_liquidate(sim, time, fl, cfg, act, details)
            flag_fast_report = False
        if flag_fast_report:
            core.perform_market_update(sim, flag_assets, time)
        prev_end = time
    if prev_end < fl["n_total_days"]:
        core.batch_market_update(sim, flag_assets, prev_end + 1, fl["n_total_days"])
    return sim


def _sim_day_activate(sim, time, active_assets, fl, cfg, details):
    flag_assets, flag_date, asset_starts = fl["flag_assets"], fl["flag_date"], fl["asset_starts"]
    initial_assets = fl["initial_assets"]
    t0 = time - 1
    rebalance_now = False
    for nm in flag_assets:
        if nm in active_assets:
            continue
        for key in ("signal_buy", "signal_sell"):
            arr = sim["market"][nm][key]
            arr[t0] = 0.0 if arr.dtype == np.float64 else False
    today = int(flag_date[t0])
    late_now = any(sd == today and nm not in initial_assets for nm, sd in zip(flag_assets, asset_starts))
    if cfg["balance_mode"] or late_now:
        cws = r_sum([sim["status"][nm]["actual"] for nm in active_assets])
        for nm in active_assets:
            sim["status"][nm]["differ"] = sim["status"][nm]["actual"] / cws
        if details:
            new_assets = [nm for nm, sd in zip(flag_assets, asset_starts) if sd == today]
            if new_assets:
                _cat("Marktereignis:\tHandel mit %s ab jetzt m\u00f6glich.\n" % ", ".join(new_assets))
        rebalance_now = True
    core.calculate_total_report(sim, flag_assets, time)
    return sim, rebalance_now


def _sim_day_split(sim, time, active_assets, fl, cfg, act, split_thresh, details):
    flag_assets, flag_date = fl["flag_assets"], fl["flag_date"]
    t0 = time - 1
    lo, hi = float(split_thresh[0]), float(split_thresh[1])
    held = [nm for nm in active_assets if sim["status"][nm]["count"] > 0]
    for nm in [x for x in flag_assets if x not in held]:
        px0 = float(sim["market"][nm]["asset_price"][t0])
        if px0 > hi or px0 < lo:
            sim["market"][nm]["asset_price"] = sim["market"][nm]["asset_price"] / (px0 / 100)
            if details:
                _cat("Split-Ereignis:\t%s ohne Bestand: Kursreihe %s %s am %s\n"
                     % (nm, "1 :" if px0 > hi else ": 1",
                        r_format1(px0 / 100 if px0 > hi else 100 / px0, digits=5), fmt_date(int(flag_date[t0]))))
    for nm in active_assets:
        if sim["status"][nm]["count"] > 0:
            split_price = float(sim["market"][nm]["asset_price"][t0])
            if split_price > hi:
                sim = _perform_asset_split(sim, nm, split_price / 100, time, "forward", cfg["fractions"], details,
                                           int(flag_date[t0]))
            if split_price < lo:
                sim = _perform_asset_split(sim, nm, 100 / split_price, time, "reverse", cfg["fractions"], details,
                                           int(flag_date[t0]))
            split_cnt = sim["status"][nm]["count"]
            split_frac = split_cnt - math.floor(split_cnt + 1e-9)
            if not cfg["fractions"] and split_frac > 1e-9:
                fee_keep = _FEE.current
                _FEE.current = None
                sim = act._sell(sim, nm, time, "Split:", 0.0, count=split_frac)
                _FEE.current = fee_keep
    core.calculate_total_report(sim, flag_assets, time)
    return sim


def _sim_day_dca(sim, time, active_assets, fl, cfg, strategy, balance_dca, details):
    flag_assets, flag_date = fl["flag_assets"], fl["flag_date"]
    t0 = time - 1
    dca_amount = cfg["dca_value"] * fl["flag_dca_n"][t0]
    strat_w = np.array([float(strategy[nm]["asset_share"]) for nm in active_assets], dtype=np.float64)
    strat_w = strat_w / r_sum(strat_w, na_rm=True)
    if balance_dca and len(active_assets) > 1:
        core.calculate_total_report(sim, flag_assets, time)
        totals_now = np.array([sim["status"][nm]["total"] for nm in active_assets], dtype=np.float64)
        desired = strat_w * (r_sum(totals_now, na_rm=True) + dca_amount)
        deficit = np.maximum(0.0, desired - totals_now)
        if r_sum(deficit) > dca_amount:
            alloc = dca_amount * deficit / r_sum(deficit)
        else:
            alloc = deficit + (dca_amount - r_sum(deficit)) * strat_w
        for nm, v in zip(active_assets, alloc):
            core.dca_flows_allocation(sim, nm, float(v), time)
    else:
        for nm, w in zip(active_assets, strat_w):
            core.dca_flows_allocation(sim, nm, float(w) * dca_amount, time)
    if details:
        parts = "; ".join(_sp("%s %.2f EUR", nm, sim["report"][nm]["flows"][t0]) for nm in active_assets)
        _cat(_sp("Einzahlung:\t%.2f EUR in das Depot am %s\n\t\t=> ", dca_amount, fmt_date(int(flag_date[t0]))) + parts
             + "\n")
    core.calculate_total_report(sim, flag_assets, time)
    return sim


def _sim_day_trade(sim, time, active_assets, fl, cfg, act, details):
    trade_event = False
    for nm in active_assets:
        f_buy = _calculate_buy_signal(sim, nm, time)
        f_sell = _calculate_sell_signal(sim, nm, time)
        if f_buy:
            sim = act.buy_with_fee(sim, nm, time, "Handelssignal:")
            trade_event = True
        if f_sell:
            sim = act._sell(sim, nm, time, "Handelssignal:", fl["spread_rates"][nm])
            trade_event = True
    if trade_event:
        core.calculate_total_report(sim, fl["flag_assets"], time)
    return sim, trade_event


def _sim_day_rebalance(sim, time, active_assets, fl, cfg, act, fr, event_weight, details):
    flag_assets, flag_date = fl["flag_assets"], fl["flag_date"]
    t0 = time - 1
    fd = fmt_date(int(flag_date[t0]))
    sr = fl["spread_rates"]
    balance_thresh = cfg["balance_thresh"]
    at = np.array([sim["status"][nm]["actual"] for nm in active_assets], dtype=np.float64)
    at = at / r_sum(at, na_rm=True)
    active_targets = dict(zip(active_assets, (float(v) for v in at)))
    if event_weight is not None and bool(fl["flag_event"][t0]):
        ow = []
        for nm in active_assets:
            col = event_weight.get(nm)
            ow.append(NA if col is None else float(fr.get(col)[t0]))
        ow_a = np.array(ow, dtype=np.float64)
        if np.all(np.isfinite(ow_a)) and r_sum(ow_a) > 0:
            ow_a = ow_a / r_sum(ow_a)
            active_targets = dict(zip(active_assets, (float(v) for v in ow_a)))
    signal_cash_only: list = []
    for nm in active_assets:
        if sim["assets"][nm]["style"] == "signal":
            has_pos = sim["status"][nm]["count"] > 0
            sig_buy = _is_true(sim["market"][nm]["signal_buy"][t0])
            sig_sell = _is_true(sim["market"][nm]["signal_sell"][t0])
            if has_pos and sig_sell:
                sim = act._sell(sim, nm, time, "Rebalancing/Signal-Ausstieg:", sr[nm])
                signal_cash_only.append(nm)
            elif not has_pos and sig_buy:
                sim = _perform_trade_buy(sim, nm, time, "Rebalancing/Signal-Einstieg:", sr[nm], cfg["fractions"],
                                         details)
            elif not has_pos and not sig_buy:
                signal_cash_only.append(nm)
    core.calculate_total_report(sim, flag_assets, time)
    actual_weights = {nm: sim["status"][nm]["differ"] for nm in active_assets}
    today = int(flag_date[t0])
    new_asset = any(sd == today for sd in fl["asset_starts"])
    force_rebalance = new_asset
    if force_rebalance and details:
        new_assets = [nm for nm, sd in zip(flag_assets, fl["asset_starts"]) if sd == today]
        _cat("Rebalancing:\tErzwungenes Rebalancing am %s wegen neu handelbarer Assets: %s\n"
             % (fd, ", ".join(new_assets)))
    if force_rebalance:
        event_rebalance = True
    elif balance_thresh is None:
        event_rebalance = True
    else:
        if cfg["balance_thresh_type"] == "relative":
            deviations = [abs(actual_weights[nm] / active_targets[nm] - 1) if active_targets[nm] != 0 else
                          (math.inf if actual_weights[nm] != 0 else NA) for nm in active_assets]
        else:
            deviations = [abs(active_targets[nm] - actual_weights[nm]) for nm in active_assets]
        devs_ok = [x for x in deviations if not math.isnan(x)]
        max_deviation = max(devs_ok) if devs_ok else -math.inf
        event_rebalance = max_deviation > balance_thresh
        if details:
            if event_rebalance:
                _cat(_sp("Rebalancing:\tRebalancing am %s (max. Abweichung: %.2f%% > Schwelle: %.2f%%)\n", fd,
                         max_deviation * 100, balance_thresh * 100))
                for nm, dev in zip(active_assets, deviations):
                    if dev > balance_thresh:
                        _cat(_sp("\t\t=> %s: Ziel=%.1f%%, Ist=%.1f%%, Abweichung=%.2f%%\n", nm, active_targets[nm] * 100,
                                 actual_weights[nm] * 100, dev * 100))
            else:
                _cat(_sp("Rebalancing:\tKein Rebalancing am %s (max. Abweichung: %.2f%% < Schwelle: %.2f%%)\n", fd,
                         max_deviation * 100, balance_thresh * 100))
    if event_rebalance:
        differ_weights = {nm: active_targets[nm] - actual_weights[nm] for nm in active_assets}
        total_strategy = r_sum([sim["status"][nm]["total"] for nm in active_assets], na_rm=True)
        transfer_pool = 0.0
        transfer_value = {nm: abs(differ_weights[nm] * total_strategy) for nm in active_assets}
        for nm in [x for x in active_assets if differ_weights[x] < 0]:
            sell_target = transfer_value[nm] - _rmax(0.0, sim["status"][nm]["money"])
            if sim["status"][nm]["count"] > 0 and sell_target > 0:
                srs = _calculate_sell_count(sim, nm, sell_target, time, sr[nm], cfg["fractions"], cfg["tax_mode"],
                                            cfg["effective_tax_rate"], fl["tax_regimes"][nm])
                sim = act._sell(sim, nm, time, "Rebalancing:", sr[nm], count=srs["sell_count"],
                                price=srs["fifo_price"])
            available_cash = _rmin(sim["status"][nm]["money"], transfer_value[nm])
            transfer_pool = transfer_pool + available_cash
            sim["status"][nm]["money"] = sim["status"][nm]["money"] - available_cash
            if details:
                _cat(_sp("\t\t%.2f EUR von %s in den Rebalancing-Topf\n", available_cash, nm))
        for nm in [x for x in active_assets if differ_weights[x] > 0]:
            allocation = _rmin(transfer_value[nm], transfer_pool)
            if allocation > 0:
                sim["status"][nm]["money"] = sim["status"][nm]["money"] + allocation
                transfer_pool = transfer_pool - allocation
                if details:
                    _cat(_sp("Rebalancing:\t%.2f EUR aus dem Rebalancing-Topf an %s\n", allocation, nm))
                if nm in signal_cash_only:
                    if details:
                        _cat(_sp("\t\t=> %s h\u00e4lt %.2f EUR als Cash-Reserve (Signal inaktiv)\n", nm,
                                 sim["status"][nm]["money"]))
                else:
                    sim = _perform_trade_buy(sim, nm, time, "Rebalancing:", sr[nm], cfg["fractions"], details)
        if transfer_pool > 0.01:
            if details:
                _cat(_sp("\t\tRestverteilung von %.2f EUR aus dem Rebalancing-Topf\n", transfer_pool))
            for nm in active_assets:
                redistribution = active_targets[nm] * transfer_pool
                sim["status"][nm]["money"] = sim["status"][nm]["money"] + redistribution
                if details:
                    _cat(_sp("\t\t=> %.2f EUR an %s\n", redistribution, nm))
    for nm in active_assets:
        st = sim["status"][nm]
        if nm not in signal_cash_only and st["money"] > 0.005 and \
                (sim["assets"][nm]["style"] != "signal" or st["count"] > 0):
            sim = act.buy_with_fee(sim, nm, time, "Rebalancing:")
    core.calculate_total_report(sim, flag_assets, time)
    return sim


def _sim_day_harvest(sim, time, active_assets, fl, cfg, harvest_loss_pot, details):
    if cfg["fees_on"]:
        _FEE.current = cfg["fee_order"]
    for nm in active_assets:
        sim = _perform_gain_harvest(sim, nm, time, fl["tax_regimes"][nm], fl["spread_rates"][nm], cfg["fractions"],
                                    bool(harvest_loss_pot), cfg["use_sparer_pauschbetrag"], cfg["tax_mode"],
                                    cfg["tax_rate"], cfg["effective_tax_rate"], cfg["marginal_tax_rate"],
                                    cfg["private_sale_threshold"], details)
    core.calculate_total_report(sim, fl["flag_assets"], time)
    return sim


def _sim_day_assess_vp(sim, time, fl, cfg, liquidate, details):
    flag_assets, flag_date, flag_filled = fl["flag_assets"], fl["flag_date"], fl["flag_filled"]
    t0 = time - 1
    if cfg["tax_mode"] == "person" and not (bool(liquidate) and fl["flag_liquidate"][t0]):
        for nm in flag_assets:
            regime = fl["tax_regimes"][nm]
            if regime == "investment_fund" and sim["status"][nm]["count"] > 0:
                vp_result = _calculate_flat_rate(sim, nm, time, flag_date, regime, flag_filled)
                flat_rate = vp_result["total_vp"]
                buys_l = sim["trades"][nm]["buys"]
                for vp_i, lv in zip(vp_result["lot_indices"], vp_result["lot_vps"]):
                    lot = buys_l[vp_i - 1]
                    cur = lot.get("vp")
                    lot["vp"] = (0.0 if cur is None else cur) + lv
                if flat_rate > 0:
                    pend = sim["totals"].get("vp_pending")
                    if pend is None:
                        pend = []
                    pend = list(pend) + [{"name": nm, "flat_rate": flat_rate, "bonus": sim["assets"][nm]["bonus"],
                                          "assessment_date": int(flag_date[t0])}]
                    sim["totals"]["vp_pending"] = pend
                    if details:
                        _cat(_sp("Steuerereignis:\tVorabpauschale %s: %.2f EUR festgesetzt am %s (Zufluss und Steuer am "
                                 "ersten Handelstag des Folgejahres)\n", nm, flat_rate, fmt_date(int(flag_date[t0]))))
    core.calculate_total_report(sim, flag_assets, time)
    return sim


def _sim_day_fund_fee(sim, time, fl, act, funds_fee, bonus_fee, details):
    flag_assets, flag_date = fl["flag_assets"], fl["flag_date"]
    core.calculate_total_report(sim, flag_assets, time)
    result_fees = _calculate_fund_fees(sim, time, flag_date, flag_assets, funds_fee, bonus_fee, details)
    sim["totals"]["total_value"] = result_fees["total_value"]
    for nm in flag_assets:
        fee_i = result_fees["asset_fees"][nm]
        if not math.isfinite(fee_i) or fee_i <= 0:
            continue
        if sim["status"][nm]["money"] < fee_i:
            sim = act.raise_cash(sim, nm, fee_i, time, "Fondskosten:")
        paid = _rmin(fee_i, _rmax(0.0, sim["status"][nm]["money"]))
        sim["status"][nm]["money"] = sim["status"][nm]["money"] - paid
        if details:
            _cat(_sp("\t\t=> %.2f EUR Geb\u00fchren von %s abgezogen\n", paid, nm))
        tr = sim["trades"][nm]
        tr["fee_count"] += 1
        tr["fees"].append({"event_date": int(flag_date[time - 1]), "event_type": "Fees", "fees_paid": paid})
    core.calculate_total_report(sim, flag_assets, time)
    return sim


def _sim_day_liquidate(sim, time, fl, cfg, act, details):
    flag_assets, flag_date = fl["flag_assets"], fl["flag_date"]
    tax_mode = cfg["tax_mode"]
    for nm in flag_assets:
        if sim["status"][nm]["count"] > 0:
            tax_type = "person" if tax_mode == "person" else "none"
            sim = act._sell(sim, nm, time, "Liquidation:", fl["spread_rates"][nm], tax_mode=tax_type)
            if sim["status"][nm]["count"] > 0:
                _warn(_sp("simulation: liquidate = TRUE: Position '%s' (Wert %.2f EUR) wurde nicht verkauft, weil die "
                          "Ordergeb\u00fchr den Erl\u00f6s \u00fcbersteigt.", nm, sim["status"][nm]["worth"]))
    if tax_mode == "funds":
        core.calculate_total_report(sim, flag_assets, time)
        final_value = r_sum([sim["status"][x]["total"] for x in flag_assets], na_rm=True)
        deposits = r_sum([r_sum(sim["report"][x]["flows"][:time]) for x in flag_assets])
        total_gains = final_value - cfg["start_value"] - deposits
        if total_gains > 0:
            total_taxes = total_gains * cfg["tax_rate"]
            cash = {x: _rmax(0.0, sim["status"][x]["money"]) for x in flag_assets}
            sc = r_sum(list(cash.values()))
            tax_weights = {x: cash[x] / sc for x in flag_assets} if sc > 0 else \
                {x: 1 / len(flag_assets) for x in flag_assets}
            for nm in flag_assets:
                tpa = _rmin(total_taxes * tax_weights[nm], cash[nm])
                sim["status"][nm]["money"] = sim["status"][nm]["money"] - tpa
                sim["totals"]["total_taxes"] = sim["totals"]["total_taxes"] + tpa
            if details:
                _cat(_sp("Liquidation:\tSteuern %.2f EUR auf den Gesamtgewinn von %.2f EUR am %s\n", total_taxes,
                         total_gains, fmt_date(int(flag_date[time - 1]))))
    core.calculate_total_report(sim, flag_assets, time)
    return sim


# ═══════════════════════════════════════════════════════════════════════════
# Phase 5: Abschluss des letzten Jahres
# ═══════════════════════════════════════════════════════════════════════════

def _sim_close_years(sim: dict, fl: dict, cfg: dict, act: _Actions, stopp_date: int, details: bool) -> dict:
    n_total_days = fl["n_total_days"]
    tariff_env = cfg["tariff_env"]
    next_jan1 = days_from_civil(year_of(stopp_date) + 1, 1, 1)

    def final_year_change(s, te=tariff_env, det=details):
        return _handle_year_change(s, next_jan1, cfg["marginal_tax_rate"], cfg["private_sale_threshold"],
                                   cfg["sparer_pauschbetrag"], cfg["use_sparer_pauschbetrag"],
                                   cfg["soli_factor_income"], cfg["effective_tax_rate"], det, cfg["church_k"], te)
    if cfg["tax_mode"] == "person":
        if sim["totals"].get("vp_pending"):
            vp_year = year_of(sim["totals"]["vp_pending"][0]["assessment_date"])
            prepaid = None
            if sim["totals"]["current_year"] <= vp_year:
                dry = copy.deepcopy(sim)
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore")
                    dry = final_year_change(dry, None, False)
                pend = sim["totals"]["vp_pending"]
                _, res = act.vp_taxes(dry, pend)
                prepaid = [r["tax"] for r in res]
                for j, p in enumerate(pend):
                    if prepaid[j] > 0:
                        sim = act.pay_tax(sim, p["name"], prepaid[j], n_total_days, "Vorabpauschale")
                sim = final_year_change(sim)
            sim = act.settle_vp(sim, n_total_days, prepaid=prepaid)
        sim = final_year_change(sim)
        if tariff_env is not None:
            y_last = sim["totals"]["current_year"]
            cbt = sim["totals"].get("cgt_base_taxed_ytd") or 0.0
            if tariff_env.use_gp and y_last > year_of(stopp_date) and cbt > 0:
                D = _tariff_close(tariff_env, y_last, 0.0, cbt, cfg["effective_tax_rate"], details)
                sim = _tariff_book(sim, tariff_env, D)
        if sim["totals"].get("p23_due"):
            sim = act.settle_p23(sim, n_total_days)
        if tariff_env is not None and act.gp_pending():
            sim = act.settle_gp(sim, n_total_days)
        core.calculate_total_report(sim, fl["flag_assets"], n_total_days)
    return sim


# ═══════════════════════════════════════════════════════════════════════════
# Phase 6: Auswertung (sim_evaluate.R)
# ═══════════════════════════════════════════════════════════════════════════

def _sim_compact_trades(sim: dict, flag_assets: list) -> dict:
    out = {}
    for nm in flag_assets:
        tr = sim["trades"][nm]
        out[nm] = {"buys": tr["buys"][:tr["buy_count"]], "sells": tr["sells"][:tr["sell_count"]],
                   "taxes": tr["taxes"][:tr["tax_count"]], "fees": tr["fees"][:tr["fee_count"]]}
    return out


def _sim_returns(sim: dict, flag_date: np.ndarray, flag_assets: list, flag_filled: np.ndarray, start_date: int,
                 stopp_date: int, start_value: float, tax_unpaid_total: float) -> dict:
    total_worth = r_rowsums(np.column_stack([sim["report"][nm]["total"] for nm in flag_assets]), na_rm=True)
    total_flows = r_rowsums(np.column_stack([sim["report"][nm]["flows"] for nm in flag_assets]), na_rm=True)
    start_worth = float(total_worth[0])
    n_days_sim = total_worth.size
    stopp_worth = float(total_worth[n_days_sim - 1])
    ann_factor = float(stopp_date - start_date) / 365.25
    cagr = r_pow(stopp_worth / start_worth, 1 / ann_factor) - 1 if (start_worth > 0 and ann_factor > 0) else NA
    n = n_days_sim
    if n >= 2:
        period_change = np.concatenate([[NA], total_worth[1:] - total_worth[:-1] - total_flows[1:]])
        prev_total = np.concatenate([[NA], total_worth[:-1]])
        with np.errstate(divide="ignore", invalid="ignore"):
            cond = (~np.isnan(prev_total)) & (prev_total > 0)
            period_return = np.where(cond, period_change / prev_total, 0.0)
        fday = np.flatnonzero(np.concatenate([[False], ~np.isnan(total_flows[1:]) & (total_flows[1:] != 0)]))
        if fday.size:
            v_pre = np.zeros(fday.size)
            with np.errstate(divide="ignore", invalid="ignore"):
                for nm in flag_assets:
                    rep_a = sim["report"][nm]
                    px = np.asarray(sim["market"][nm]["asset_price"], dtype=np.float64)
                    w_prev = rep_a["worth"][fday - 1]
                    gr = px[fday] / px[fday - 1]
                    v_pre = v_pre + np.where((w_prev != 0) & np.isfinite(gr), w_prev * gr, 0.0) + \
                        rep_a["money"][fday - 1]
                pt = prev_total[fday]
                g1 = np.where(~np.isnan(pt) & (pt > 0), v_pre / pt, 1.0)
                den = v_pre + total_flows[fday]
                g2 = np.where(np.isfinite(den) & (den > 0), total_worth[fday] / den, 1.0)
            period_return[fday] = g1 * g2 - 1
        period_return[0] = NA
    else:
        period_return = np.array([NA])
    ttwror = r_pow(r_prod(1 + period_return, na_rm=True), 1 / ann_factor) - 1 if ann_factor > 0 else NA
    has_ext_flows = n_days_sim >= 2 and bool(np.any(total_flows[1:][~np.isnan(total_flows[1:])] != 0))
    fl0 = total_flows.copy()
    fl0[np.isnan(fl0)] = 0.0
    invested = start_value + r_cumsum(fl0)
    twr_growth = 1 + period_return[1:] if n_days_sim >= 2 else np.zeros(0)
    twr_growth = np.where(np.isfinite(twr_growth), twr_growth, 1.0)
    twr_index = r_cumprod(np.concatenate([[1.0], twr_growth]))
    start_gross = NA
    fi = np.zeros(0, dtype=np.int64)
    if has_ext_flows:
        fi = np.flatnonzero((np.arange(n_days_sim) > 0) & ~np.isnan(total_flows) & (total_flows != 0))
        t_fl = (flag_date[fi] - start_date).astype(np.float64) / 365.25
        start_gross = start_value + fl0[0]
        cagr = _xirr_rate(np.concatenate([[0.0], t_fl]), np.concatenate([[start_gross], total_flows[fi]]),
                          stopp_worth, ann_factor) if ann_factor > 0 else NA
        if math.isnan(cagr) and ann_factor > 0 and not (math.isfinite(stopp_worth) and stopp_worth < 0):
            _warn(_sp("simulation: geldgewichtete Rendite (cagr) mit Einzahlungen nicht bestimmbar (Startwert %.2f EUR, "
                      "Einzahlungen %.2f EUR, Endwert %.2f EUR): kein interner Zinsfu\u00df gefunden; cagr = NA.",
                      start_gross, r_sum(total_flows[fi]), stopp_worth))
    if tax_unpaid_total > 0:
        open_tax_debt = r_sum([_rmax(0.0, -sim["status"][nm]["money"]) for nm in flag_assets])
    else:
        open_tax_debt = 0.0
    neg_detail = _sp("Endwert %.2f EUR negativ: offene Steuerschuld %.2f EUR", stopp_worth, open_tax_debt) \
        if open_tax_debt > 0 else _sp("Endwert %.2f EUR negativ", stopp_worth)
    if math.isfinite(stopp_worth) and stopp_worth < 0:
        if not has_ext_flows:
            cagr = NA
        if isinstance(ttwror, float) and math.isnan(ttwror):
            ttwror = NA
        _warn(_sp("simulation: Endwert negativ (%.2f EUR, %s); Verlust \u00fcber 100 %%: cagr und ttwror sind nicht definiert "
                  "(NA), Drawdowns auf 100 %% begrenzt.", stopp_worth,
                  _sp("offene Steuerschuld %.2f EUR", open_tax_debt) if open_tax_debt > 0 else
                  "nicht gedeckte Steuerschuld"))
    elif isinstance(ttwror, float) and math.isnan(ttwror) and ann_factor > 0:
        ttwror = NA
        if not (has_ext_flows and np.any(twr_index <= 0)):
            _warn("simulation: zeitgewichteter Wertindex wird negativ (Tagesrendite unter -100 %); ttwror ist nicht "
                  "definiert (NA).")

    def why_na(metric):
        if ann_factor <= 0:
            return ["too_short", "Zeitraum %s, Laufzeit 0 Jahre (Einzeltag)" % _n_tage(n_days_sim)]
        if math.isfinite(stopp_worth) and stopp_worth < 0:
            return ["negative_end_value", neg_detail]
        if metric == "cagr" and has_ext_flows:
            return ["no_irr_solution", _sp("kein interner Zinsfu\u00df: Startwert %.2f EUR, Einzahlungen %.2f EUR, Endwert "
                                           "%.2f EUR", start_gross, r_sum(total_flows[fi]), stopp_worth)]
        if metric == "cagr" and not (start_worth > 0):
            return ["zero_start_value", _sp("Depotwert am Starttag %.2f EUR", start_worth)]
        i0 = np.flatnonzero(twr_index <= 0)
        if i0.size:
            i0 = int(i0[0])
            return ["nonpositive_twr_index", _sp("zeitgewichteter Wertindex am %s nicht positiv (Tagesrendite %.2f %%)",
                                                 fmt_date(int(flag_date[i0])), 100 * period_return[i0])]
        return ["not_finite", "Rechnung ergibt keinen endlichen Wert"]
    why_ret = {"cagr": why_na("cagr") if math.isnan(cagr) else None,
               "ttwror": why_na("ttwror") if math.isnan(ttwror) else None}
    if ann_factor <= 0:
        _warn("simulation: Zeitraum %s (Laufzeit 0 Jahre): cagr und ttwror sind nicht definiert (NA)."
              % _n_tage(n_days_sim))
    elif not has_ext_flows and math.isnan(cagr) and why_ret["cagr"] is not None and why_ret["cagr"][0] == "zero_start_value":
        _warn(_sp("simulation: Depotwert am Starttag %.2f EUR: cagr ist nicht definiert (NA).", start_worth))
    ret_dd = ttwror if has_ext_flows else cagr
    dd_series = twr_index if has_ext_flows else total_worth
    running_max = r_cummax(dd_series)
    with np.errstate(divide="ignore", invalid="ignore"):
        drawdowns = np.where(running_max > 0, (running_max - dd_series) / running_max, 0.0)
    drawdowns = np.where(np.isnan(running_max), NA, drawdowns)
    if has_ext_flows and np.any(twr_index <= 0):
        i0 = int(np.flatnonzero(twr_index <= 0)[0])
        _warn(_sp("simulation: zeitgewichteter Wertindex am %s nicht positiv (Tagesrendite %.2f %% bei Depotwert %.2f EUR "
                  "am Vortag und Einzahlung %.2f EUR); TTWROR und die zeitgewichteten Drawdowns sind nicht "
                  "aussagekr\u00e4ftig (Drawdowns auf 100 %% begrenzt).", fmt_date(int(flag_date[i0])),
                  100 * period_return[i0], total_worth[i0 - 1], total_flows[i0]))
        drawdowns = np.where(np.isnan(drawdowns), drawdowns, np.minimum(drawdowns, 1.0))
    if np.any(drawdowns[~np.isnan(drawdowns)] > 1):
        i0 = int(np.flatnonzero(drawdowns > 1)[0])
        if not (math.isfinite(stopp_worth) and stopp_worth < 0):
            _warn(_sp("simulation: Depotwert am %s negativ (%.2f EUR, Steuerschuld); Drawdowns auf 100 %% begrenzt.",
                      fmt_date(int(flag_date[i0])), total_worth[i0]))
        drawdowns = np.where(np.isnan(drawdowns), drawdowns, np.minimum(drawdowns, 1.0))
    dd_ok = drawdowns[~np.isnan(drawdowns)]
    max_drawdown = float(dd_ok.max()) if dd_ok.size else -math.inf
    if not math.isfinite(max_drawdown):
        max_drawdown = 0.0
    with np.errstate(divide="ignore", invalid="ignore"):
        portfolio_returns = np.diff(total_worth) / total_worth[:-1]
    portfolio_returns[~np.isfinite(portfolio_returns)] = 0.0
    ttwror_returns = period_return[1:].copy()
    ttwror_returns[~np.isfinite(ttwror_returns)] = 0.0
    has_flows = bool(np.any(total_flows[~np.isnan(total_flows)] != 0))
    risk_returns = ttwror_returns if has_flows else portfolio_returns
    if flag_filled.size == risk_returns.size + 1:
        returns_filled_mask = flag_filled[1:]
    else:
        returns_filled_mask = np.zeros(risk_returns.size, dtype=bool)
    if returns_filled_mask.size == risk_returns.size and returns_filled_mask.any():
        risk_returns = risk_returns[~returns_filled_mask]
    ann_periods = risk_returns.size / ann_factor if (ann_factor > 0 and risk_returns.size > 0) else 365.25
    return {"total_worth": total_worth, "twr_index": twr_index, "invested": invested, "has_ext_flows": has_ext_flows,
            "cagr": cagr, "ttwror": ttwror, "why_ret": why_ret, "open_tax_debt": open_tax_debt, "ret_dd": ret_dd,
            "dd_series": dd_series, "running_max": running_max, "drawdowns": drawdowns, "max_drawdown": max_drawdown,
            "risk_returns": risk_returns, "returns_filled_mask": returns_filled_mask, "ann_factor": ann_factor,
            "ann_periods": ann_periods, "n_days_sim": n_days_sim}


def _sim_risk_stats(r: dict, risk_free, fr: _Frame) -> dict:
    risk_returns = r["risk_returns"]
    mask = r["returns_filled_mask"]
    days_per_year = r["ann_periods"]
    n_days_sim = r["n_days_sim"]
    drawdowns, dd_series, running_max = r["drawdowns"], r["dd_series"], r["running_max"]
    max_drawdown, ret_dd = r["max_drawdown"], r["ret_dd"]
    daily_mean = r_mean(risk_returns, na_rm=True)
    daily_sd = r_sd(risk_returns, na_rm=True)
    if not math.isfinite(daily_mean):
        daily_mean = 0.0
    if not math.isfinite(daily_sd):
        daily_sd = 0.0
    daily_cv = abs(daily_sd / daily_mean) if daily_mean != 0 else NA
    if risk_free is None:
        risk_free = 0
    if isinstance(risk_free, str):
        if risk_free not in fr:
            _stop("risk_free: Spalte '%s' fehlt im Datensatz." % risk_free)
        col = fr.get(risk_free)
        rf_full = np.array(col, dtype=np.float64) if fr.is_numeric(risk_free) else \
            np.array([NA if _isna(v) else (float(v) if _is_num(v) else NA) for v in col], dtype=np.float64)
    else:
        rf_full = np.full(n_days_sim, float(risk_free))
    rf_full[~np.isfinite(rf_full)] = 0.0
    rf_full = rf_full / 100
    rf_returns = rf_full[1:] if rf_full.size >= 2 else np.zeros(0)
    if mask.size == rf_returns.size and mask.any():
        rf_returns = rf_returns[~mask]
    if rf_returns.size != risk_returns.size:
        rf_returns = np.full(risk_returns.size, r_mean(rf_returns) if rf_returns.size else 0.0)
    rf_daily = r_pow_vec(1 + rf_returns, 1 / days_per_year) - 1
    excess = risk_returns - rf_daily
    rf_effective = r_mean(rf_returns) * 100 if rf_returns.size else 0.0
    mean_excess = r_mean(excess, na_rm=True)
    sd_excess = r_sd(excess, na_rm=True)
    if not math.isfinite(mean_excess):
        mean_excess = 0.0
    if not math.isfinite(sd_excess):
        sd_excess = 0.0
    downside = excess[excess < 0]
    if downside.size > 0:
        dmin = np.minimum(excess, 0.0)
        downside_sd_excess = math.sqrt(r_mean(dmin * dmin, na_rm=True))
    else:
        downside_sd_excess = 0.0
    sqrt_dpy = math.sqrt(days_per_year)
    sharpe = (mean_excess * days_per_year) / (sd_excess * sqrt_dpy) if sd_excess > 0 else NA
    sortino = (mean_excess * days_per_year) / (downside_sd_excess * sqrt_dpy) if downside_sd_excess > 0 else NA
    calmar = ret_dd / max_drawdown if (max_drawdown > 0 and not math.isnan(ret_dd)) else NA
    ulcer_index = math.sqrt(r_mean(drawdowns * drawdowns, na_rm=True)) if drawdowns.size else NA
    if not math.isfinite(ulcer_index):
        ulcer_index = 0.0
    martin_ratio = ret_dd / ulcer_index if (ulcer_index > 0 and not math.isnan(ret_dd)) else NA
    serenity = ret_dd / (ulcer_index * max_drawdown) if (ulcer_index > 0 and max_drawdown > 0
                                                         and not math.isnan(ret_dd)) else NA
    gains = r_sum(risk_returns[risk_returns > 0], na_rm=True)
    losses = abs(r_sum(risk_returns[risk_returns < 0], na_rm=True))
    omega = gains / losses if losses > 0 else NA
    gain_to_pain = r_sum(risk_returns, na_rm=True) / losses if losses > 0 else NA
    dd_active = drawdowns[drawdowns > 0]
    average_drawdown = r_mean(dd_active) if dd_active.size > 0 else 0.0
    longest_dd = 0
    current_dd = 0
    recovery_times: list = []
    in_dd = False
    dd_start = 0
    for i in range(dd_series.size):
        below = dd_series[i] < running_max[i]
        if below:
            current_dd += 1
            if current_dd > longest_dd:
                longest_dd = current_dd
        else:
            current_dd = 0
        if below:
            if not in_dd:
                dd_start = i + 1
                in_dd = True
        elif in_dd:
            recovery_times.append((i + 1) - dd_start)
            in_dd = False
    avg_recovery_time = r_mean_int(recovery_times) if recovery_times else NA
    statistics = {
        "mean": daily_mean, "sd": daily_sd, "cv": daily_cv, "risk_free": rf_effective,
        "skewness": _calculate_skewness(risk_returns), "kurtosis": _calculate_kurtosis(risk_returns),
        "lpm": _calculate_partials(risk_returns, lower=True), "hpm": _calculate_partials(risk_returns, lower=False),
        "sharpe": sharpe, "sortino": sortino, "calmar": calmar, "omega": omega, "gain_to_pain": gain_to_pain,
        "serenity": serenity, "martin_ratio": martin_ratio, "max_drawdown": max_drawdown,
        "average_drawdown": average_drawdown, "ulcer_index": ulcer_index, "longest_drawdown": int(longest_dd),
        "avg_recovery_time": avg_recovery_time,
    }
    return {"statistics": statistics, "longest_dd": longest_dd}


def _sim_undefined_metrics(r: dict, rs: dict, trades: dict, flag_assets: list) -> dict:
    n_r = r["risk_returns"].size
    why_ret, ret_dd, ann_factor, n_days_sim = r["why_ret"], r["ret_dd"], r["ann_factor"], r["n_days_sim"]
    statistics, longest_dd = rs["statistics"], rs["longest_dd"]

    def few(k):
        return ["too_short", "keine Tagesrendite (Einzeltag)" if n_r == 0 else
                "nur %d %s, mindestens %d n\u00f6tig" % (n_r, "Tagesrendite" if n_r == 1 else "Tagesrenditen", k)]
    ret_name = "ttwror" if r["has_ext_flows"] else "cagr"

    def inherit():
        w = why_ret[ret_name]
        return [w[0], "%s nicht definiert: %s" % (ret_name, w[1])]
    no_dd = ["no_drawdown", "kein Drawdown im Zeitraum (max_drawdown 0)"]
    zero_vol = ["zero_volatility", "Standardabweichung der %d Tagesrenditen ist 0 (konstanter Verlauf)" % n_r]
    rd_na = isinstance(ret_dd, float) and math.isnan(ret_dd)

    def why_stat(m):
        if m == "cv":
            return few(1) if n_r == 0 else ["zero_mean_return", "mittlere Tagesrendite ist 0"]
        if m == "skewness":
            return few(3) if n_r < 3 else zero_vol
        if m == "kurtosis":
            return few(4) if n_r < 4 else zero_vol
        if m in ("lpm", "hpm"):
            return few(1)
        if m == "sharpe":
            return few(2) if n_r < 2 else ["zero_volatility",
                                           "Standardabweichung der %d \u00dcberschussrenditen ist 0" % n_r]
        if m == "sortino":
            return few(1) if n_r < 1 else ["no_negative_returns",
                                           "keine negativen \u00dcberschussrenditen (Downside-Abweichung 0)"]
        if m in ("calmar", "serenity"):
            return inherit() if rd_na else no_dd
        if m in ("omega", "gain_to_pain"):
            return few(1) if n_r < 1 else ["no_negative_returns", "keine negativen Tagesrenditen"]
        if m == "martin_ratio":
            return inherit() if rd_na else ["no_drawdown", "kein Drawdown im Zeitraum (Ulcer Index 0)"]
        if m == "avg_recovery_time":
            if ann_factor <= 0:
                return ["too_short", "Zeitraum %s, Laufzeit 0 Jahre (Einzeltag)" % _n_tage(n_days_sim)]
            return ["no_recovery", "kein Drawdown im Zeitraum" if longest_dd == 0 else
                    "Drawdown bis zum Ende nicht aufgeholt (l\u00e4ngster Drawdown %s)" % _n_tage(longest_dd)]
        return ["not_finite", "Rechnung ergibt keinen endlichen Wert"]
    buys = pd.Series({x: (len(trades[x]["buys"]) / ann_factor if ann_factor > 0 else NA) for x in flag_assets},
                     dtype=np.float64)
    sells = pd.Series({x: (len(trades[x]["sells"]) / ann_factor if ann_factor > 0 else NA) for x in flag_assets},
                      dtype=np.float64)
    um: dict = {}
    for m in ("cagr", "ttwror"):
        if math.isnan(r[m]):
            um[m] = why_ret[m]
    for m, v in statistics.items():
        if isinstance(v, float) and math.isnan(v):
            um[m] = why_stat(m)
    for m, v in (("buys", buys), ("sells", sells)):
        if v.isna().any():
            um[m] = ["too_short", "Zeitraum %s, Laufzeit 0 Jahre: keine Anzahl je Jahr (Einzeltag)" % _n_tage(n_days_sim)]
    undefined_metrics = pd.DataFrame({"metric": pd.Series(list(um.keys()), dtype=object),
                                      "reason": pd.Series([v[0] for v in um.values()], dtype=object),
                                      "detail": pd.Series([v[1] for v in um.values()], dtype=object)})
    return {"undefined_metrics": undefined_metrics, "buys": buys, "sells": sells}


def _sim_result(sim: dict, trades: dict, fl: dict, cfg: dict, r: dict, rs: dict, um: dict):
    from .result import SimLevResult
    flag_date, flag_assets = fl["flag_date"], fl["flag_assets"]
    tax_mode, strategy = cfg["tax_mode"], cfg["strategy"]
    tariff_env = cfg["tariff_env"]
    open_lots = None
    if tax_mode == "person":
        open_lots = {}
        for nm in flag_assets:
            lots = [b for b in trades[nm]["buys"] if b and b["remaining"] > 0]
            sp_ = strategy[nm].get("asset_spread")
            open_lots[nm] = {
                "lots": pd.DataFrame({
                    "date": pd.Series(np.array([b["date"] for b in lots], dtype=np.int64).astype("datetime64[D]")),
                    "units": pd.Series([b["remaining"] for b in lots], dtype=np.float64),
                    "price": pd.Series([b["price"] for b in lots], dtype=np.float64),
                    "vp": pd.Series([b.get("vp") if b.get("vp") is not None else 0.0 for b in lots], dtype=np.float64)}),
                "regime": fl["tax_regimes"][nm],
                "asset_bonus": 100 * sim["assets"][nm]["bonus"],
                "cash": sim["status"][nm]["money"],
                "asset_spread": 0.0 if sp_ is None else float(sp_),
                "order_fee": cfg["order_fee"],
            }
    totals = sim["totals"]
    tax_report = {
        "total_taxes_paid": totals["total_taxes"],
        "loss_carryforward_capital": totals["loss_capital_gains"],
        "loss_carryforward_private": totals["loss_private_sales"],
        "sparer_pauschbetrag_annual": totals["sparer_pauschbetrag_annual"],
        "sparer_pauschbetrag_used": totals["sparer_pauschbetrag_used_total"],
        "sparer_pauschbetrag_tax_saved": totals["sparer_pauschbetrag_used_total"] * cfg["effective_tax_rate"],
        "open_tax_debt": r["open_tax_debt"],
    }
    if tariff_env is not None and tariff_env.rows:
        tax_report["tariff_years"] = pd.DataFrame(tariff_env.rows)
    if tax_mode == "person":
        use_spb = cfg["use_sparer_pauschbetrag"]
        ny = int(totals["current_year"])

        def g0(k):
            v = totals.get(k)
            return 0.0 if v is None else v
        nyd = {
            "year": ny,
            "sparer_pauschbetrag_used": _rmax(0.0, totals["sparer_pauschbetrag_annual"] -
                                              totals["sparer_pauschbetrag_remaining"]) if use_spb else 0.0,
            "sparer_pauschbetrag_remaining": totals["sparer_pauschbetrag_remaining"] if use_spb else 0.0,
            "loss_carryforward_capital": totals["loss_capital_gains"],
            "loss_carryforward_private": totals["loss_private_sales"],
            "capital_income_taxed": g0("cgt_base_taxed_ytd"),
            "loss_capital_added": g0("cgt_loss_added_ytd"),
            "loss_capital_used": g0("cgt_loss_used_ytd"),
            "loss_capital_start": g0("cgt_pool_start_ytd"),
            "private_sale_net": g0("private_sale_gains_ytd") - g0("private_sale_losses_ytd"),
        }
        if tariff_env is not None:
            ks = tariff_env.ks.get(str(ny))
            nyd["church_tax_settlement"] = ks if (ks is not None and not math.isnan(ks)) else 0.0
            nyd["tariff_assessed"] = any(rw["year"] == ny for rw in tariff_env.rows)
        tax_report["next_year"] = nyd
    res = SimLevResult()
    res["dates"] = flag_date.astype("datetime64[D]")
    res["filled"] = fl["flag_filled"].copy()
    res["worth"] = r["total_worth"]
    res["twr_index"] = r["twr_index"]
    res["invested"] = r["invested"]
    res["external_flows"] = bool(r["has_ext_flows"])
    res["cagr"] = float(r["cagr"])
    res["ttwror"] = float(r["ttwror"])
    res["drawdowns"] = r["drawdowns"]
    res["statistics"] = rs["statistics"]
    res["buys"] = um["buys"]
    res["sells"] = um["sells"]
    res["report"] = sim["report"]
    res["tax_report"] = tax_report
    res["undefined_metrics"] = um["undefined_metrics"]
    res["open_lots"] = open_lots
    if cfg["fees_on"]:
        res["fees_paid"] = _FEE.paid
    if _is_true(cfg["harvest_mode"]):
        res["harvest_days"] = flag_date[fl["flag_harvest"]].astype("datetime64[D]")
    res._trades = trades
    return res


# ═══════════════════════════════════════════════════════════════════════════
# Hauptfunktion
# ═══════════════════════════════════════════════════════════════════════════

def simulation(
    data: Any,
    strategy: Mapping[str, Mapping[str, Any]],
    start_value: float = 10000,
    spread: float | None = None,
    details: bool = False,
    liquidate: bool = False,
    # DCA
    dca_mode: bool = False,
    dca_value: float | None = None,
    dca_span: float | None = None,
    dca_days: Any = None,
    dca_unit: str | Sequence[str] = ("month", "quarter", "year"),
    dca_anchor: str | Sequence[str] = ("start", "end"),
    dca_start: Any = None,
    dca_skip: bool = False,
    # Rebalancing
    balance_mode: bool = False,
    balance_span: float | None = None,
    balance_days: Any = None,
    balance_unit: str | Sequence[str] = ("month", "quarter", "year"),
    balance_anchor: str | Sequence[str] = ("start", "end"),
    balance_start: Any = None,
    balance_skip: bool = False,
    balance_dca: bool = False,
    balance_thresh: float | None = None,
    balance_thresh_type: str | Sequence[str] = ("absolute", "relative"),
    # Steuern
    tax_mode: str | Sequence[str] = ("none", "person", "funds"),
    tax_rate: float = _Default(26.375),
    marginal_tax_rate: float | None = _Default(None),
    use_guenstigerpruefung: bool = False,
    private_sale_threshold: float = 1000,
    sparer_pauschbetrag: float = 1000,
    use_sparer_pauschbetrag: bool = True,
    include_soli_on_income_tax: bool = _Default(False),
    soli_rate_income_tax: float = _Default(5.5),
    # Basiszins
    base_rate: float | None = None,
    base_rate_flex: bool = False,
    base_rate_data: str | None = None,
    # Fonds
    funds_fee: float = _Default(0.95),
    bonus_fee: float = _Default(5),
    # Sonstiges
    fractions: bool = True,
    risk_free: float | str | None = 0,
    split_mode: bool = False,
    split_thresh: Sequence[float] | None = None,
    # Ereignisbasiertes Rebalancing
    event_col: str | None = None,
    event_mode: str | Sequence[str] = _Default(("additional", "replace")),
    event_weight: Mapping[str, str] | None = None,
    # Deutsche Praxis
    church_tax: float | None = 0,
    order_fee: Any = None,
    dca_fee: Any = None,
    harvest_mode: bool = False,
    harvest_day: str = "12-15",
    harvest_loss_pot: bool = True,
    # Einkommensteuertarif
    taxable_income: Any = None,
    tax_tariff: Any = None,
):
    """Portfolio-Simulation (Backtest) mit Sparplan, Rebalancing und deutscher Besteuerung.

    Bitgleiche Portierung von ``simulation()`` aus dem R-Paket SimLev 0.5.0. Alle Raten und
    Schwellen werden **in Prozent** angegeben (``tax_rate=26.375``, ``balance_thresh=5``,
    ``risk_free=2`` …). Argumente und Voreinstellungen entsprechen 1:1 denen in R; ``None``
    steht für ``NULL``, ``True``/``False`` für ``TRUE``/``FALSE``, Folgen für ``c(...)``,
    ``dict`` für benannte Listen/Vektoren und ``pandas.DataFrame`` für ``data.frame``.

    Neue Argumente in 0.5.0: ``order_fee``, ``dca_fee`` (Zahl in EUR oder
    ``dict(fixed=, percent=, min=, max=)``), ``church_tax`` (Prozent), ``harvest_mode``,
    ``harvest_day`` (``"MM-TT"``), ``harvest_loss_pot``, ``taxable_income`` (Zahl, ``dict``
    Jahr -> zvE, ``pandas.Series`` oder ``DataFrame(year, taxable_income)``) und
    ``tax_tariff`` (``None``, Dateipfad oder :func:`simlev.read_tax_tariff`-Objekt).

    Hinweise (R: ``message()``) gehen nach ``sys.stderr``, Warnungen sind
    ``warnings.warn``-Warnungen, Fehler ``ValueError`` (Texte wie in R). Die
    ``details``-Ausgabe geht nach ``sys.stdout``.

    Rückgabe: :class:`simlev.SimLevResult` mit den Elementen wie in R (``dates``,
    ``filled``, ``worth``, ``twr_index``, ``invested``, ``external_flows``, ``cagr``,
    ``ttwror``, ``drawdowns``, ``statistics``, ``buys``, ``sells``, ``report``,
    ``tax_report``, ``undefined_metrics``, ``open_lots``, ggf. ``fees_paid`` und
    ``harvest_days``).
    """
    given = {
        "tax_rate": not isinstance(tax_rate, _Default),
        "marginal_tax_rate": not isinstance(marginal_tax_rate, _Default),
        "include_soli_on_income_tax": not isinstance(include_soli_on_income_tax, _Default),
        "soli_rate_income_tax": not isinstance(soli_rate_income_tax, _Default),
        "funds_fee": not isinstance(funds_fee, _Default),
        "bonus_fee": not isinstance(bonus_fee, _Default),
        "event_mode": not isinstance(event_mode, _Default),
    }
    tax_rate, marginal_tax_rate = _unwrap(tax_rate), _unwrap(marginal_tax_rate)
    include_soli_on_income_tax, soli_rate_income_tax = _unwrap(include_soli_on_income_tax), _unwrap(soli_rate_income_tax)
    funds_fee, bonus_fee, event_mode = _unwrap(funds_fee), _unwrap(bonus_fee), _unwrap(event_mode)
    try:
        cfg = _sim_check_inputs(
            data=data, strategy=strategy, start_value=start_value, spread=spread, details=details,
            dca_mode=dca_mode, dca_value=dca_value, dca_span=dca_span, dca_days=dca_days, balance_mode=balance_mode,
            balance_days=balance_days, balance_thresh=balance_thresh, balance_thresh_type=balance_thresh_type,
            tax_mode=tax_mode, tax_rate=tax_rate, marginal_tax_rate=marginal_tax_rate,
            use_guenstigerpruefung=use_guenstigerpruefung, private_sale_threshold=private_sale_threshold,
            sparer_pauschbetrag=sparer_pauschbetrag, use_sparer_pauschbetrag=use_sparer_pauschbetrag,
            include_soli_on_income_tax=include_soli_on_income_tax, soli_rate_income_tax=soli_rate_income_tax,
            base_rate=base_rate, funds_fee=funds_fee, bonus_fee=bonus_fee, fractions=fractions, risk_free=risk_free,
            split_mode=split_mode, split_thresh=split_thresh, event_col=event_col, church_tax=church_tax,
            order_fee=order_fee, dca_fee=dca_fee, harvest_mode=harvest_mode, harvest_day=harvest_day,
            taxable_income=taxable_income, tax_tariff=tax_tariff, given=given)
        if split_thresh is not None:
            split_thresh = _num_vec(split_thresh)
        prep = _sim_prepare_data(cfg["data"], cfg["pre_filled"], base_rate_flex, base_rate_data)
        sim = _sim_build_state(prep["data"], cfg["strategy"], cfg["start_value"], prep["start_date"],
                               prep["stopp_date"], cfg["sparer_pauschbetrag"], cfg["use_sparer_pauschbetrag"],
                               cfg["base_rate"], base_rate_flex, base_rate_data)
        cal = _sim_build_calendar(prep["data"], sim, cfg["strategy"], prep["start_date"], prep["stopp_date"],
                                  liquidate, cfg["dca_mode"], dca_span, dca_unit, cfg["dca_days"], cfg["dca_value"],
                                  dca_anchor, dca_start, dca_skip, cfg["balance_mode"], balance_span, balance_unit,
                                  cfg["balance_days"], balance_anchor, balance_start, balance_skip, cfg["event_col"],
                                  event_mode, event_weight, cfg["split_mode"], split_thresh)
        fr = cal["data"]
        fl = cal["flags"]
        if cfg["event_col"] is not None:
            event_weight = cal["event_weight"]
        init = _sim_init_weights(sim, fl["flag_assets"], fl["flag_date"], cfg["start_value"])
        sim = init["sim"]
        fl["initial_assets"] = init["initial_assets"]
        fl = _sim_build_schedule(sim, fl, prep["stopp_date"], cfg["tax_mode"], cfg["harvest_mode"], harvest_day)
        act = _Actions(cfg, fl, bool(details))
        sim = _sim_run_days(sim, fl, cfg, act, fr, cfg["strategy"], liquidate, event_weight, split_thresh,
                            funds_fee, bonus_fee, balance_dca, harvest_loss_pot, bool(details))
        sim = _sim_close_years(sim, fl, cfg, act, prep["stopp_date"], bool(details))
        trades = _sim_compact_trades(sim, fl["flag_assets"])
        ret = _sim_returns(sim, fl["flag_date"], fl["flag_assets"], fl["flag_filled"], prep["start_date"],
                           prep["stopp_date"], cfg["start_value"], act.tax_unpaid_total)
        risk = _sim_risk_stats(ret, cfg["risk_free"], fr)
        undef = _sim_undefined_metrics(ret, risk, trades, fl["flag_assets"])
        return _sim_result(sim, trades, fl, cfg, ret, risk, undef)
    finally:
        _FEE.current = None


# R rechnet mit NA (signalisierendes NaN) ohne Gleitkomma-Warnungen; numpy meldete sonst
# "invalid value encountered" bei jeder Rechnung mit NA.
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
