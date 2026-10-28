"""Grundfunktionen der Engine: Ausgabe- und Datumshilfen, Spaltendaten, Gebühren, Termine, Handels- und
Steuerfunktionen, Tarifweg, Jahreswechsel und Kennzahlen (nachgebildet aus ``r/R/sim_base.R``; Julia: ``engine.jl``).
"""
from __future__ import annotations

import datetime as _dt
import math
import re
import sys
import warnings
from typing import Any, Mapping

import numpy as np
import pandas as pd

from . import _core as core
from ._dates import days_from_civil, fmt_date, from_days, is_leap, year_of
from ._r.rformat import r_as_character, r_deparse, r_format, r_format1, r_sprintf
from ._r.rnum import r_colsums, r_mean, r_pow, r_pow_vec, r_sd, r_sum, r_uniroot
from .config import _match_arg
from .tax_tariff import SimLevTaxTariff, tariff_income_tax, tariff_soli
from ._r.rnum import NA_REAL as NA  # R's NA_real_ (Nutzlast 1954)

__all__ = [
    "calculate_skewness", "calculate_kurtosis", "calculate_partials", "calculate_dates_flags",
    "xirr_rate", "apply_spread",
]


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
# Handels- und Steuerfunktionen (sim_base.R, früher simulation.R)
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


# R rechnet mit NA (signalisierendes NaN) ohne Gleitkomma-Warnungen; numpy meldete sonst
# "invalid value encountered" bei jeder Rechnung mit NA.
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
