"""Grundfunktionen der Engine: Ausgabe- und Datumshilfen, Spaltendaten, Gebühren, Termine, Tarifweg (Prüfung,
``_TariffEnv``) und Kennzahlen (nachgebildet aus ``r/R/sim_base.R``; Julia: ``engine.jl``). Die Handels- und
Steuerfunktionen der Tagesschleife rechnet der gemeinsame C++-Kern (``_sim_engine.py``).
"""
from __future__ import annotations

import datetime as _dt
import functools
import math
import re
import sys
import warnings
from typing import Any, Mapping

import numpy as np
import pandas as pd

from . import _ext
from ._dates import days_from_civil, from_days
from ._meldungen import EVAL_WARN as _MELD_EVAL_WARN
from ._r.rformat import r_as_character, r_format, r_format1, r_sprintf
from ._r.rnum import r_mean, r_pow, r_pow_vec, r_sd, r_sum
from .config import _match_arg
from ._tax_tariff import SimLevTaxTariff
from ._r.rnum import NA_REAL as NA  # R's NA_real_ (Nutzlast 1954)

__all__ = [
    "calculate_skewness", "calculate_kurtosis", "calculate_dates_flags",
    "xirr_rate",
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


def _num_vec(x: Any) -> list | None:
    """Zahlenvektor aus Skalar/Folge (None, wenn nicht numerisch)."""
    if _is_num(x):
        return [float(x)]
    if isinstance(x, (list, tuple, np.ndarray, pd.Series)):
        vals = list(np.asarray(x, dtype=object).ravel())
        if all(_is_num(v) or v is None for v in vals):
            return [NA if v is None else float(v) for v in vals]
    return None


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
    """``as.Date(s, format = "%Y-%m-%d")`` wie R's strptime (Ziffernfelder, Rest ignoriert; Kern
    core/slc_rbase_date.cpp)."""
    return _ext.slc_r_strptime_ymd(s, "-")


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

    def copy(self) -> "_Frame":
        """Kopie mit eigenen Spalten (Fonds-Wrapper: normalisierte Daten für die innere Rechnung)."""
        return _Frame(list(self.names), {nm: np.copy(self.cols[nm]) for nm in self.names}, dict(self.kinds),
                      self.filled_attr)

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


class _StudyCache:
    """Prüf-Cache je Studie (seit 1.5.1; R ``.sim_study_env``): Studien (``bootstrap_study``, ``param_search``,
    ``sensitivity_*``, ``planning_lumpsum_vs_dca``) rufen ``simulation()`` vielfach mit denselben Daten auf. Solange
    eine Studie läuft, merkt sich ``simulation()`` je Art den zuletzt gesehenen Schlüssel und das Ergebnis von
    Umwandlungen und Prüfungen, die ohne Meldung durchgingen (Datumsspalte, eindeutige Tage); Meldungen und
    Warnungen entstehen weiter je Lauf, Fehler brechen vor dem Merken ab. Außerhalb einer Studie wirkungslos."""
    on = False
    m: dict = {}


def _sim_study() -> bool:
    if _StudyCache.on:
        return False
    _StudyCache.on = True
    _StudyCache.m = {}
    return True


def _sim_study_end(own: bool) -> None:
    if own:
        _StudyCache.on = False
        _StudyCache.m = {}


def _study_scope(f):
    """Dekorator der Studien: Prüf-Cache für die Dauer des Aufrufs (geschachtelte Studien teilen ihn)."""
    @functools.wraps(f)
    def wrapper(*args, **kwargs):
        own = _sim_study()
        try:
            return f(*args, **kwargs)
        finally:
            _sim_study_end(own)
    return wrapper


def _memo_arr(what: str, key: np.ndarray):
    """Eintrag ``what`` des Prüf-Caches, wenn sein Schlüssel gleich ``key`` ist (Typ, Form, Werte), sonst None."""
    if not _StudyCache.on:
        return None
    e = _StudyCache.m.get(what)
    if e is None:
        return None
    k = e[0]
    if k.dtype != key.dtype or k.shape != key.shape or not np.array_equal(k, key):
        return None
    return e[1]


def _memo_set(what: str, key: np.ndarray, val: Any) -> None:
    if _StudyCache.on:
        _StudyCache.m[what] = (np.array(key, copy=True), val)


def _memo_slice(what: str, key: np.ndarray):
    """Anfang ``i``, wenn ``key`` ein zusammenhängender Ausschnitt des Schlüssels von ``what`` ist (Studien über
    Zeitfenster derselben Daten, planning_lumpsum_vs_dca), sonst None."""
    if not _StudyCache.on or key.size == 0:
        return None
    e = _StudyCache.m.get(what)
    if e is None:
        return None
    k = e[0]
    if k.dtype != key.dtype or k.ndim != 1 or key.ndim != 1 or key.size > k.size:
        return None
    for i in np.flatnonzero(k[:k.size - key.size + 1] == key[0])[:1]:
        if np.array_equal(k[i:i + key.size], key):
            return int(i)
    return None


def _memo_seed_dates(col: Any) -> None:
    """Studie über Zeitfenster (seit 1.5.1): Datumsspalte der ganzen Daten einmal umwandeln und, wenn sie nur
    Tage ohne Uhrzeit, keine NA und keine doppelten Tage enthält, als Ganzes merken ("datecol_full",
    "dates_full"); Fenster daraus brauchen dann weder Umwandlung noch Prüfung auf doppelte Tage."""
    if not _StudyCache.on or not isinstance(col, pd.Series):
        return
    dt = col.dtype
    if not pd.api.types.is_datetime64_any_dtype(dt) or getattr(dt, "tz", None) is not None:
        return
    raw = col.to_numpy()
    kind, days = _column_dt(col, dt)
    if kind != "date" or np.isnan(days).any() or np.unique(days).size != days.size:
        return
    _StudyCache.m["datecol_full"] = (np.array(raw, copy=True), days)
    _StudyCache.m["dates_full"] = (days.copy(), True)


def _column_dt(v: pd.Series, dt: Any) -> tuple[str, np.ndarray]:
    """Datums-/Zeitspalte (pandas datetime64) in ("date" bzw. "posixct", Tage seit 1970)."""
    s = v
    midnight = True
    if getattr(dt, "tz", None) is not None:
        s = v.dt.tz_localize(None)
        midnight = False
    norm = s.dt.normalize()
    if not (norm.isna() | (norm == s)).all():
        midnight = False
    # Tage seit 1970 des (auf Mitternacht gesetzten) Zeitpunkts, NaT -> NA;
    # auf dem ganzen Feld statt je Element über to_pydatetime()
    na = norm.isna().to_numpy()
    days = norm.to_numpy().astype("datetime64[D]").astype(np.int64).astype(np.float64)
    if na.any():
        days[na] = NA
    return ("date" if midnight else "posixct"), days


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
            raw = v.to_numpy() if getattr(dt, "tz", None) is None else None
            if raw is not None:                 # Studie: einmal je Datumsspalte (seit 1.5.1)
                hit = _memo_arr("datecol", raw)
                if hit is not None:
                    return hit[0], hit[1].copy()
                i0 = _memo_slice("datecol_full", raw)      # Zeitfenster der ganzen Daten (nur Tage ohne Uhrzeit)
                if i0 is not None:
                    return "date", _StudyCache.m["datecol_full"][1][i0:i0 + raw.size].copy()
            out = _column_dt(v, dt)
            if raw is not None:
                _memo_set("datecol", raw, (out[0], out[1].copy()))
            return out
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
    if isinstance(data, _Frame):   # schon normalisiert (Fonds-Wrapper, innere Rechnung)
        return data.copy()
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
    """Paket-Umgebung ``.fee_env``: Summe der gezahlten Gebühren (die Gebühren je Order rechnet der Kern)."""

    def __init__(self):
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


# ═══════════════════════════════════════════════════════════════════════════
# Termine und Flags
# ═══════════════════════════════════════════════════════════════════════════

def _sched_spec(mode, span, unit, days, dates: np.ndarray, value, anchor, start_date, skip_start) -> tuple:
    """Angaben eines Terminplans für den Kern (core/prepare_core_impl.h): (si, start, days, dcode)
    wie ``.sched_spec`` in R; den Schritt liest R aus ``"<span> months"`` (``as.integer``), den Tag von ``days`` für
    anchor = "start" aus ``as.Date("2000-1-<days>")`` (0 = NA)."""
    if not mode or unit is None or (value is not None and value <= 0):
        return np.zeros(7, dtype=np.int32), 0.0, None, None
    if span is None:
        span = 1
    unit = _match_arg(unit, ("month", "quarter", "year"), "unit")
    anchor = _match_arg(anchor, ("start", "end"), "anchor")
    dmax = int(dates.max())
    start = int(dates.min()) if start_date is None else _date_or_fail(start_date)
    step = int(float(r_as_character(span * 3 if unit == "quarter" else span)))
    sd, td = from_days(start), from_days(dmax)
    first = days_from_civil(sd.year, 1 if unit == "year" else sd.month, 1)
    on = 1
    if step < 1 or first > dmax:   # wie seq(): Fehler, sonst hoechstens first (= letzter Tag)
        same = (sd.year, 1 if unit == "year" else sd.month) == (td.year, 1 if unit == "year" else td.month)
        if not same:
            _stop("invalid '(to - from)/by'" if step == 0 else "wrong sign in 'by' argument")
        on, step = int(first == dmax), 1
    dd = dcode = None
    if days is not None:
        dd = np.ascontiguousarray(np.atleast_1d(np.asarray(days, dtype=np.float64)))
        dcode = np.array([0 if (z := _r_strptime_ymd("2000-1-" + r_as_character(v))) is None else z - 10956
                          for v in dd], dtype=np.int32)
    si = np.array([on, unit == "year", unit == "quarter", anchor == "end", bool(skip_start), days is not None,
                   min(step, 2 ** 31 - 1)], dtype=np.int32)
    return si, float(start), dd, dcode


def _calculate_dates_flags(mode, span, unit, days, dates: np.ndarray, value, anchor, start_date,
                           skip_start, liquidate) -> np.ndarray:
    si, start, dd, dcode = _sched_spec(mode, span, unit, days, dates, value, anchor, start_date, skip_start)
    out = _ext.sim_dates_flags(np.ascontiguousarray(dates, dtype=np.float64), si, start, dd, dcode,
                               int(bool(si[0]) and bool(liquidate)))
    return np.frombuffer(out, dtype=np.int32).astype(bool)


def _check_taxable_income(x: Any, years: list[int], who: str = "simulation", plan_ok: bool = False) -> dict:
    """zvE prüfen (R: ``.check_taxable_income``). ``plan_ok`` (``income_tariff()``): ein Vektor ohne Namen
    (ein Wert je Planjahr von ``withdrawal_simulation()``) ist zulässig; Ergebnis dann mit ``plan`` (Werte)."""
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
                _stop(who + ": taxable_income als data.frame braucht die Spalten year und taxable_income (oder "
                      "genau zwei Spalten Jahr, Betrag); vorhanden: %s." % ", ".join(str(c) for c in x.columns))
            yc, vc = 0, 1
        kind, col = _column(x.iloc[:, vc])
        if kind != "numeric":
            _stop(who + ": taxable_income: Spalte '%s' (Betrag) muss numerisch sein." % x.columns[vc])
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
        _stop(who + ": taxable_income muss %s sein, nicht %s." % (form, ", ".join(shown[:3])))
    for i, v in enumerate(vals):
        if not math.isfinite(v):
            _stop(who + ": taxable_income enth\u00e4lt einen ung\u00fcltigen Wert (%s%s); erwartet werden endliche "
                  "Betr\u00e4ge in EUR." % (r_format1(v), (" f\u00fcr %s" % names[i]) if names is not None else ""))
    if len(vals) == 1 and names is None:
        return {"all": vals[0], "by_year": None}
    if plan_ok and names is None:
        return {"all": None, "by_year": None, "plan": vals}
    if names is None or any(nm is None or nm == "" for nm in names):
        _stop(who + ": taxable_income mit %d Werten muss nach Kalenderjahren benannt sein; erwartet wird %s%s."
              % (len(vals), form, " (ein Vektor ohne Namen, ein Wert je Planjahr, gilt nur in withdrawal_simulation())"
                 if names is None else ""))
    yy = []
    for nm in names:
        t = nm.strip()
        try:
            y = int(float(t)) if re.match(r"^[-+]?\d+(\.\d*)?([eE][-+]?\d+)?$", t) else None
        except ValueError:
            y = None
        if y is None or str(y) != t:
            _stop(who + ": taxable_income: Name '%s' ist kein Kalenderjahr (erwartet z. B. \"2024\")." % nm)
        yy.append(y)
    for i, y in enumerate(yy):
        if y in yy[:i]:
            _stop(who + ": taxable_income: Jahr %d kommt mehrfach vor." % y)
    miss = [y for y in years if y not in yy]
    if miss:
        _stop(who + ": taxable_income fehlt f\u00fcr %s %s (angegeben: %s); je Kalenderjahr der Simulation "
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


# ═══════════════════════════════════════════════════════════════════════════
# Jahreswechsel (_handle_year_change)
# ═══════════════════════════════════════════════════════════════════════════


# ═══════════════════════════════════════════════════════════════════════════
# Kennzahlen
# ═══════════════════════════════════════════════════════════════════════════

# Warnungen von uniroot (Codes 1-3 der Auswertung, core/meldungen.tsv)
_XIRR_WARN = {k: _MELD_EVAL_WARN[str(k)] for k in (1, 2, 3)}


def _xirr_rate(t: np.ndarray, amount: np.ndarray, end_value: float, horizon: float) -> float:
    """``.xirr_rate()``: interner Zinsfuß p. a. (Brent über u = T log(1 + r)); im Kern
    (``core/evaluate_core_impl.h``, ``_ext.sim_xirr``), Warnungen von ``uniroot`` mit den Texten von R."""
    v, msgs = _ext.sim_xirr(np.ascontiguousarray(t, dtype=np.float64), np.ascontiguousarray(amount, dtype=np.float64),
                            float(end_value), float(horizon))
    for m in msgs:
        _warn(_XIRR_WARN[m[0]])
    return v


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


# R rechnet mit NA (signalisierendes NaN) ohne Gleitkomma-Warnungen; numpy meldete sonst
# "invalid value encountered" bei jeder Rechnung mit NA.
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
