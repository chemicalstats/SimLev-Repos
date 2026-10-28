"""Daten- und Portfolio-Aufbereitung (Port von ``r/R/data_prep.R``).

- :func:`series_align`        Quellen nach Datum zusammenführen, Kalender, Füllung
- :func:`series_check`        Prüfbericht: Lücken, Ausreißer, Spikes, Splits,
                              stehende Kurse, Datumsprobleme
- :func:`series_align_macro`         Makroreihen mit Veröffentlichungsverzug auf den
                              Tageskalender legen
- :func:`series_convert_currency`    Währungsumrechnung über eine Kursreihe
- :func:`index_total_return`  Kurs- zu Total-Return-Index
- :func:`series_deflate`             reale Werte über einen Preisindex
- :func:`series_splice`       Ketten aus mehreren Reihen (Proxy -> Index -> Fonds)
- :func:`strategy_from_weights`, :func:`portfolio_template`
                              Portfolios aus Gewichten bzw. Vorlagen

Datumswerte: R-``Date``-Vektoren entsprechen ``numpy.ndarray`` mit dtype
``datetime64[D]`` (``NaT`` = ``NA``). Interne Helfer (``_to_date``,
``_add_months``, …) liefern immer solche Arrays (auch bei Länge 1).
"""
from __future__ import annotations

import datetime as _dt
import math
import re
import sys
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

from ._r import libm as _libm
from ._r.base import quiet_fp
from ._r.fmt import NA_REAL
from ._r.rlist import RList
from ._r.rnum import r_cumprod, r_isna, r_mean, r_median, r_sum

__all__ = [
    "series_align", "series_check", "SimLevDataCheck", "series_align_macro", "series_convert_currency",
    "index_total_return", "series_deflate", "series_splice", "strategy_from_weights",
    "portfolio_template",
]

_NAN = NA_REAL   # R-NA_real_ (alle fehlenden Werte in data_prep.R sind NA)
_EPOCH = np.datetime64("1970-01-01", "D")


# ═══════════════════════════════════════════════════════════════════════════
# Allgemeine Hilfen (R-Semantik)
# ═══════════════════════════════════════════════════════════════════════════

def message(text: str) -> None:
    """R-``message()``: Text mit Zeilenumbruch auf ``sys.stderr``."""
    sys.stderr.write(str(text) + "\n")
    sys.stderr.flush()


def _match_arg(arg, choices):
    """R-``match.arg(arg)`` mit den Voreinstellungen ``choices``.

    ``None`` oder der vollständige Auswahlvektor ergeben die erste Wahl;
    eindeutige Präfixe werden ergänzt. Fehlermeldung wortgleich zu R.
    """
    choices = tuple(choices)
    if arg is None:
        return choices[0]
    if isinstance(arg, (list, tuple, np.ndarray)):
        if tuple(arg) == choices:
            return choices[0]
        if len(arg) != 1:
            raise ValueError("'arg' must be of length 1")
        arg = arg[0]
    if not isinstance(arg, str):
        raise ValueError("'arg' must be NULL or a character vector")
    if arg in choices:
        return arg
    hits = [c for c in choices if c.startswith(arg)] if arg else []
    if len(hits) == 1:
        return hits[0]
    raise ValueError("'arg' should be one of %s" % ", ".join("\u201c%s\u201d" % c for c in choices))


def _isna_scalar(x) -> bool:
    if x is None or x is pd.NA or x is pd.NaT:
        return True
    if isinstance(x, (float, np.floating)):
        return math.isnan(float(x))
    if isinstance(x, np.datetime64):
        return bool(np.isnat(x))
    return False


def _is_number(x) -> bool:
    return isinstance(x, (int, float, np.integer, np.floating)) and not isinstance(x, (bool, np.bool_))


def _fmt_num(x) -> str:
    """R-``format(x)`` für eine einzelne Zahl (7 signifikante Stellen)."""
    from ._r import fmt as _fmt
    return str(_fmt.format(float(x) if not isinstance(x, (int, np.integer)) else int(x)))


def _sprintf_g(x) -> str:
    """C-``%g`` wie R-``sprintf("%g", x)``."""
    x = float(x)
    if math.isnan(x):
        return "NA" if r_isna(x) else "NaN"
    if math.isinf(x):
        return "Inf" if x > 0 else "-Inf"
    return "%g" % x


# ── Kalender (proleptisch gregorianisch, beliebige Jahre wie R) ─────────────

def _civil_to_days(y, m, d):
    """(Jahr, Monat, Tag) -> Tage seit 1970-01-01 (vektorisiert, int64)."""
    y = np.asarray(y, dtype=np.int64)
    m = np.asarray(m, dtype=np.int64)
    d = np.asarray(d, dtype=np.int64)
    y = y - (m <= 2)
    era = np.floor_divide(y, 400)
    yoe = y - era * 400
    mp = (m + 9) % 12
    doy = (153 * mp + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _days_to_civil(z):
    """Tage seit 1970-01-01 -> (Jahr, Monat, Tag) als int64-Arrays."""
    z = np.asarray(z, dtype=np.int64) + 719468
    era = np.floor_divide(z, 146097)
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = np.where(mp < 10, mp + 3, mp - 9)
    y = y + (m <= 2)
    return y, m, d


def _days_in_month(y, m):
    y = np.asarray(y, dtype=np.int64)
    m = np.asarray(m, dtype=np.int64)
    y2 = y + (m == 12)
    m2 = np.where(m == 12, 1, m + 1)
    return _civil_to_days(y2, m2, 1) - _civil_to_days(y, m, 1)


def _days(x) -> np.ndarray:
    """datetime64-Array (oder Date-artiges) -> float64-Tage (NA = nan)."""
    a = np.asarray(x)
    if a.dtype.kind == "M":
        unit, cnt = np.datetime_data(a.dtype)
        per_day = {"D": 1, "h": 24, "m": 1440, "s": 86400, "ms": 86400000, "us": 86400000000,
                   "ns": 86400000000000, "W": None, "M": None, "Y": None}.get(unit)
        nat = np.isnat(a)
        if per_day is None:
            iv = a.astype("datetime64[D]").astype(np.int64)
        else:
            iv = np.floor_divide(a.astype(np.int64) * cnt, per_day)
        out = iv.astype(np.float64)
        out[nat] = _NAN
        return out.ravel()
    if a.dtype.kind in "iuf":
        return a.astype(np.float64).ravel()
    return _days(_to_date(x))


def _as_dates(days) -> np.ndarray:
    """float-Tage -> datetime64[D] (nan -> NaT; Bruchteile abgerundet)."""
    d = np.asarray(days, dtype=np.float64).ravel()
    out = np.empty(d.shape, dtype="datetime64[D]")
    ok = ~np.isnan(d)
    out[~ok] = np.datetime64("NaT", "D")
    out[ok] = _EPOCH + np.floor(d[ok]).astype(np.int64).astype("timedelta64[D]")
    return out


def _date_str(day) -> str:
    """``format(<Date>)`` für einen Tag (NA -> "NA")."""
    if day is None or (isinstance(day, float) and math.isnan(day)):
        return "NA"
    y, m, d = _days_to_civil([int(math.floor(day))])
    y, m, d = int(y[0]), int(m[0]), int(d[0])
    if y < 0:
        return "-%04d-%02d-%02d" % (-y, m, d)
    if y < 1000:
        return "%d-%02d-%02d" % (y, m, d)
    return "%04d-%02d-%02d" % (y, m, d)


_RX_YMD = {sep: re.compile(r"^ *([0-9]{1,4})" + re.escape(sep) + r" *([0-9]{1,2})" + re.escape(sep) +
                           r" *([0-9]{1,2})") for sep in "-/"}


def _strptime_ymd(s, sep="-") -> float:
    """``as.Date(s, format = "%Y-%m-%d")`` (bzw. ``/``) für einen Text; NA = nan."""
    if s is None:
        return _NAN
    m = _RX_YMD[sep].match(s)
    if not m:
        return _NAN
    y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
    if not (1 <= mo <= 12 and 1 <= d <= 31):
        return _NAN
    if d > int(_days_in_month(y, mo)):
        return _NAN
    return float(_civil_to_days(y, mo, d))


def _as_date_chr(strs) -> np.ndarray:
    """``as.Date(<character>)`` mit ``tryFormats`` (Format nach dem ersten Wert)."""
    s = [None if (v is None or v == "") else v for v in strs]
    first = next((v for v in s if v is not None), None)
    if first is None:
        return np.full(len(s), _NAN)
    for sep in "-/":
        if not math.isnan(_strptime_ymd(first, sep)):
            return np.array([_strptime_ymd(v, sep) for v in s], dtype=np.float64)
    return None


def _names_as_dates_optional(names):
    """``as.Date(names(x), optional = TRUE)`` -> float-Tage (nan bei Fehlschlag)."""
    r = _as_date_chr([None if _isna_scalar(v) else str(v) for v in names])
    if r is None:
        return np.full(len(names), _NAN)
    return r


def _as_character_vec(a) -> list:
    """``as.character(x)`` elementweise (NA -> None)."""
    from ._r import fmt as _fmt
    out = []
    for v in a:
        if _isna_scalar(v):
            out.append(None)
        elif isinstance(v, str):
            out.append(v)
        elif isinstance(v, (bool, np.bool_)):
            out.append("TRUE" if v else "FALSE")
        elif _is_number(v):
            out.append(str(_fmt.as_character(float(v) if isinstance(v, (float, np.floating)) else int(v))))
        else:
            out.append(str(v))
    return out


def _obj_to_days(v) -> float:
    if _isna_scalar(v):
        return _NAN
    if isinstance(v, pd.Timestamp):
        return float(_civil_to_days(v.year, v.month, v.day))
    if isinstance(v, _dt.datetime):
        return float(_civil_to_days(v.year, v.month, v.day))
    if isinstance(v, _dt.date):
        return float(_civil_to_days(v.year, v.month, v.day))
    if isinstance(v, np.datetime64):
        return float(_days(np.array([v]))[0])
    raise TypeError


def _is_datelike(v) -> bool:
    return isinstance(v, (_dt.date, np.datetime64, pd.Timestamp))


def _to_date(x, what="date", strict=True) -> np.ndarray:
    """Datumsangaben in Date umwandeln (Port von ``.to_date``).

    POSIX-Zeitstempel mit Zeitzone ergeben den Kalendertag in ihrer eigenen
    Zeitzone, Text und Faktoren nur die Formate "JJJJ-MM-TT" und "JJJJ/MM/TT"
    mit vierstelliger Jahreszahl am Anfang; numerische Werte werden abgelehnt.
    Mit ``strict=True`` Fehler für nicht lesbare Werte, sonst NA. Leere
    Einträge ergeben NA.

    Args:
        x: datetime64-Array, ``pandas.Series``/``Index`` (auch mit Zeitzone),
            ``date``/``datetime``/``Timestamp``, Text (Skalar, Liste, Array),
            ``pandas.Categorical``.
        what: Bezeichnung für Fehlermeldungen.
        strict: Fehler (True) oder NA (False) für nicht lesbare Werte.

    Returns:
        ``numpy.ndarray`` mit dtype ``datetime64[D]`` (NaT = NA).
    """
    if x is None:
        return np.empty(0, dtype="datetime64[D]")
    # Zeitzonenbehaftete Zeitstempel: Kalendertag der eigenen Zeitzone
    if isinstance(x, (pd.Series, pd.Index)):
        dt = x.dtype
        if isinstance(dt, pd.DatetimeTZDtype):
            loc = x.dt.tz_localize(None) if isinstance(x, pd.Series) else x.tz_localize(None)
            return _as_dates(_days(np.asarray(loc, dtype="datetime64[ns]")))
        if isinstance(dt, pd.CategoricalDtype):
            x = np.asarray(x.astype(object))
        else:
            x = x.to_numpy()
    elif isinstance(x, pd.Categorical):
        x = np.asarray(x, dtype=object)
    elif isinstance(x, pd.Timestamp):
        x = np.array([x], dtype=object)
    elif isinstance(x, (str, _dt.date, np.datetime64)) or _is_number(x) or isinstance(x, (bool, np.bool_)):
        x = np.array([x], dtype=object)
    elif isinstance(x, (list, tuple)):
        x = np.array(list(x), dtype=object)
    a = np.asarray(x)
    if a.ndim == 0:
        a = a.reshape(1)
    if a.dtype.kind == "M":
        return _as_dates(_days(a))
    if a.dtype.kind in "iuf":
        raise ValueError("%s: Datum ist numerisch (z. B. %s); erwartet Date, POSIXct oder Text 'JJJJ-MM-TT'."
                         % (what, _fmt_num(a.ravel()[0]) if a.size else "NA"))
    a = a.ravel()
    if a.dtype == object:
        vals = [v for v in a if not _isna_scalar(v)]
        if vals and all(_is_datelike(v) for v in vals):
            return _as_dates([_obj_to_days(v) for v in a])
        if vals and all(_is_number(v) for v in vals):
            raise ValueError("%s: Datum ist numerisch (z. B. %s); erwartet Date, POSIXct oder Text 'JJJJ-MM-TT'."
                             % (what, _fmt_num(a[0]) if not _isna_scalar(a[0]) else "NA"))
        if not vals and a.size and all(v is None or isinstance(v, (bool, np.bool_)) for v in a):
            pass   # logisches NA: as.character -> NA
    s = _as_character_vec(a)
    s = [None if v is None else v.strip(" \t\r\n") for v in s]
    s = [None if (v is not None and v == "") else v for v in s]
    d = np.array([_strptime_ymd(v, "-") for v in s], dtype=np.float64)
    for i, v in enumerate(s):
        if v is not None and math.isnan(d[i]):
            d[i] = _strptime_ymd(v, "/")
    rx4 = re.compile(r"^[0-9]{4}[-/]")
    bad = [i for i, v in enumerate(s) if v is not None and (math.isnan(d[i]) or not rx4.search(v))]
    if bad and strict:
        raise ValueError(
            "%s: %d Datumswerte nicht als 'JJJJ-MM-TT' lesbar (z. B. '%s'). Andere Formate vorher umwandeln, "
            "z. B. as.Date(x, format = \"%%d.%%m.%%Y\") f\u00fcr '31.12.2024' oder format = \"%%d-%%m-%%Y\"."
            % (what, len(bad), s[bad[0]]))
    d[bad] = _NAN
    return _as_dates(d)


def _as_date_any(x) -> np.ndarray:
    """``as.Date(x)`` (Date, Zeitstempel oder Text mit ``tryFormats``) -> float-Tage."""
    if isinstance(x, (str,)) or (isinstance(x, (list, tuple, np.ndarray, pd.Series)) and len(x) and
                                 all(isinstance(v, str) or _isna_scalar(v) for v in np.asarray(x, dtype=object).ravel())
                                 and np.asarray(x).dtype.kind not in "Mf"):
        arr = [x] if isinstance(x, str) else [None if _isna_scalar(v) else v for v in np.asarray(x, dtype=object).ravel()]
        r = _as_date_chr(arr)
        if r is None:
            raise ValueError("character string is not in a standard unambiguous format")
        return r
    return _days(_to_date(x, strict=False))


def _add_months(x, k) -> np.ndarray:
    """Datum plus ``k`` Kalendermonate, auf das Monatsende begrenzt (Port von ``.add_months``).

    31.01. + 1 Monat = 28.02. bzw. 29.02., 29.02. + 12 Monate = 28.02.
    Vektorisiert über ``x`` und ``k`` (ganze Zahlen, auch negativ; Recycling wie R).

    Returns:
        ``numpy.ndarray`` mit dtype ``datetime64[D]``.
    """
    dx = _as_date_any(x)
    kk = np.atleast_1d(np.asarray(k, dtype=np.float64)).ravel()
    n = max(len(dx), len(kk)) if len(dx) and len(kk) else 0
    if n == 0:
        return np.empty(0, dtype="datetime64[D]")
    dx = np.resize(dx, n)
    kk = np.resize(kk, n)
    na = np.isnan(dx) | np.isnan(kk)
    z = np.where(na, 0, np.floor(np.where(na, 0, dx))).astype(np.int64)
    ki = np.where(na, 0, np.trunc(np.where(na, 0, kk))).astype(np.int64)
    y, mo, md = _days_to_civil(z)
    m = (mo - 1) + ki
    y2 = y + np.floor_divide(m, 12)
    mo2 = np.mod(m, 12)
    first = _civil_to_days(y2, mo2 + 1, 1)
    nxt = _civil_to_days(y2 + (mo2 + 1) // 12, (mo2 + 1) % 12 + 1, 1)
    out = (first + np.minimum(md, nxt - first) - 1).astype(np.float64)
    out[na] = _NAN
    return _as_dates(out)


# ── Spaltentypen (R-Semantik für pandas) ───────────────────────────────────

def _col(x, k) -> np.ndarray:
    v = x[k]
    if isinstance(v, pd.DataFrame):
        v = v.iloc[:, 0]
    return v


def _is_numeric_col(v) -> bool:
    """``is.numeric()`` für eine Spalte (int/float, nicht logisch/Faktor/Datum)."""
    dt = getattr(v, "dtype", None)
    if dt is None:
        v = np.asarray(v)
        dt = v.dtype
    if isinstance(dt, pd.CategoricalDtype):
        return False
    if pd.api.types.is_bool_dtype(dt):
        return False
    if dt == object:
        vals = [e for e in np.asarray(v, dtype=object) if not _isna_scalar(e)]
        return bool(vals) and all(_is_number(e) for e in vals)
    return bool(pd.api.types.is_numeric_dtype(dt)) and not pd.api.types.is_complex_dtype(dt)


def _is_chr_col(v) -> bool:
    """``is.character(v) || is.factor(v)``."""
    dt = getattr(v, "dtype", None)
    if dt is None:
        v = np.asarray(v)
        dt = v.dtype
    if isinstance(dt, pd.CategoricalDtype):
        return True
    if isinstance(dt, pd.StringDtype):
        return True
    if dt.kind == "U":
        return True
    if dt == object:
        vals = [e for e in np.asarray(v, dtype=object) if not _isna_scalar(e)]
        return bool(vals) and all(isinstance(e, str) for e in vals)
    if str(dt) in ("str", "string"):
        return True
    return False


def _is_date_col(v) -> bool:
    """``inherits(v, c("Date", "POSIXt"))``."""
    dt = getattr(v, "dtype", None)
    if dt is None:
        v = np.asarray(v)
        dt = v.dtype
    if isinstance(dt, pd.DatetimeTZDtype):
        return True
    if getattr(dt, "kind", None) == "M":
        return True
    if dt == object:
        vals = [e for e in np.asarray(v, dtype=object) if not _isna_scalar(e)]
        return bool(vals) and all(_is_datelike(e) for e in vals)
    return False


def _as_numeric(v) -> np.ndarray:
    """``as.numeric(v)`` (Text -> Zahl mit Warnung bei NA durch Umwandlung)."""
    if isinstance(v, (pd.Series, pd.Index)):
        if isinstance(v.dtype, pd.CategoricalDtype):
            return v.cat.codes.to_numpy().astype(np.float64) + 1.0
        v = v.to_numpy()
    a = np.asarray(v)
    if a.dtype.kind in "iufb":
        return a.astype(np.float64).ravel()
    if a.dtype.kind == "M":
        return _days(a)
    out = np.empty(a.size, dtype=np.float64)
    coerced = False
    for i, e in enumerate(a.ravel()):
        if _isna_scalar(e):
            out[i] = _NAN
        elif isinstance(e, (bool, np.bool_)) or _is_number(e):
            out[i] = float(e)
        else:
            try:
                out[i] = float(str(e).strip())
            except ValueError:
                out[i] = _NAN
                coerced = True
    if coerced:
        warnings.warn("NAs introduced by coercion")
    return out


def _nrow(data) -> int:
    if isinstance(data, pd.DataFrame):
        return int(data.shape[0])
    if isinstance(data, Mapping):
        for v in data.values():
            return len(np.atleast_1d(v))
        return 0
    return len(data)


def _names(data) -> list:
    if isinstance(data, pd.DataFrame):
        return [str(c) for c in data.columns]
    if isinstance(data, Mapping):
        return [str(c) for c in data.keys()]
    return []


_RX_NUMTXT = re.compile(r"^[-+]?[0-9][0-9.,' ]*([eE][-+]?[0-9]+)?$")
_RX_DOTDATE = re.compile(r"^[0-9]{1,2}[.][0-9]{1,2}[.][0-9]{2,4}$")


def _trimws(s):
    return None if s is None else s.strip(" \t\r\n")


def _num_text_cols(x, exclude=()) -> list:
    """Text- oder Faktorspalten, die wie Zahlen aussehen (z. B. Kurse mit Dezimalkomma).

    Port von ``.num_text_cols(x, exclude)``; liefert die Spaltennamen.
    """
    if isinstance(exclude, str):
        exclude = [exclude]
    exclude = set(exclude or ())
    cand = [k for k in _names(x) if _is_chr_col(_col(x, k)) and k not in exclude]
    out = []
    for k in cand:
        s = [_trimws(e) for e in _as_character_vec(np.asarray(_col(x, k), dtype=object))]
        s = [e for e in s if e is not None and e != ""]
        if not s:
            continue
        hit = [1.0 if (_RX_NUMTXT.search(e) and not _RX_DOTDATE.search(e)) else 0.0 for e in s]
        if r_mean(hit) >= 0.9:
            out.append(k)
    return out


def _num_text_stop(x, cols, name):
    """Fehlermeldung für Zahlen als Text (Port von ``.num_text_stop``); löst ``ValueError`` aus."""
    if isinstance(cols, str):
        cols = [cols]
    ex = [_trimws(e) for e in _as_character_vec(np.asarray(_col(x, cols[0]), dtype=object))]
    ex = [e for e in ex if e is not None and e != ""]
    ex = ([e for e in ex if "," in e] + ex)
    ex0 = ex[0] if ex else "NA"
    raise ValueError(
        "'%s': Spalte %s enth\u00e4lt Zahlen als Text bzw. Faktor (z. B. '%s'), vermutlich mit Dezimalkomma. "
        "Vorher umwandeln, z. B. mit read.csv2() oder as.numeric(sub(\",\", \".\", x, fixed = TRUE))."
        % (name, ", ".join("'%s'" % c for c in cols), ex0))


def _is_named_numeric(x) -> bool:
    """Benannter numerischer Vektor (``pandas.Series`` mit Namen oder ``dict`` aus Zahlen)."""
    if isinstance(x, pd.Series):
        return not isinstance(x.index, pd.RangeIndex) and _is_numeric_col(x)
    if isinstance(x, Mapping) and not isinstance(x, pd.DataFrame):
        vals = list(x.values())
        return bool(vals) and all(_is_number(v) or (isinstance(v, float)) for v in vals)
    return False


def _named_parts(x):
    if isinstance(x, pd.Series):
        return [str(i) for i in x.index], _as_numeric(x)
    return [str(k) for k in x.keys()], np.array([float(v) for v in x.values()], dtype=np.float64)


def _as_frame(x):
    """dict aus Spalten -> DataFrame (andere Eingaben unverändert)."""
    if isinstance(x, Mapping) and not isinstance(x, pd.DataFrame) and not _is_named_numeric(x):
        try:
            return pd.DataFrame(dict(x))
        except Exception:  # noqa: BLE001
            return x
    return x


def _duplicated_from_last(v) -> np.ndarray:
    seen = set()
    out = np.zeros(len(v), dtype=bool)
    for i in range(len(v) - 1, -1, -1):
        key = v[i]
        if isinstance(key, float) and math.isnan(key):
            key = "NA"
        if key in seen:
            out[i] = True
        else:
            seen.add(key)
    return out


def _duplicated(v) -> np.ndarray:
    seen = set()
    out = np.zeros(len(v), dtype=bool)
    for i in range(len(v)):
        key = v[i]
        if isinstance(key, float) and math.isnan(key):
            key = "NA"
        if key in seen:
            out[i] = True
        else:
            seen.add(key)
    return out


def _dp_frame(x, name):
    """Eine Quelle in ``DataFrame(date, ...)`` mit numerischen Spalten wandeln (Port von ``.dp_frame``).

    Returns:
        ``(days, cols)``: float-Tage (sortiert, eindeutig) und ``dict`` Spaltenname -> float-Array.
    """
    if _is_named_numeric(x):
        nm, vals = _named_parts(x)
        x = pd.DataFrame({"date": _to_date(np.array(nm, dtype=object), "'%s' (Namen)" % name), "value": vals})
    x = _as_frame(x)
    if not isinstance(x, pd.DataFrame):
        raise ValueError("'%s' muss ein data.frame mit Spalte 'date' sein." % name)
    names = _names(x)
    if "date" in names:
        dcol = "date"
    else:
        dc = [k for k in names if _is_date_col(_col(x, k))]
        dcol = dc[0] if dc else (names[0] if names else None)
    if dcol is None:
        raise ValueError("'%s': keine numerische Spalte." % name)
    if _is_numeric_col(_col(x, dcol)):
        raise ValueError("'%s': keine Datumsspalte; Spalte '%s' ist numerisch (z. B. Zeilennummern aus write.csv). "
                         "Spalte 'date' (Date oder 'JJJJ-MM-TT') angeben." % (name, dcol))
    num = [k for k in names if _is_numeric_col(_col(x, k)) and k != dcol]
    nr = x.shape[0]
    seq = np.arange(1, nr + 1, dtype=np.float64)
    rn = [k for k in num if k == "X" and nr > 0 and np.all(_as_numeric(_col(x, k)) == seq)]
    if rn and len(num) > 1:
        message("Hinweis: '%s': Spalte 'X' (Zeilennummern, z. B. aus write.csv) wird ignoriert." % name)
        num = [k for k in num if k not in rn]
    txt = _num_text_cols(x, [dcol])
    if txt:
        _num_text_stop(x, txt, name)
    if not num:
        raise ValueError("'%s': keine numerische Spalte." % name)
    days = _days(_to_date(_col(x, dcol), "'%s': Spalte '%s'" % (name, dcol)))
    cols = {k: _as_numeric(_col(x, k)) for k in num}
    if len(num) == 1:
        cols = {name: cols[num[0]]}
    keep = ~np.isnan(days)
    days = days[keep]
    cols = {k: v[keep] for k, v in cols.items()}
    o = np.argsort(days, kind="stable")
    days = days[o]
    cols = {k: v[o] for k, v in cols.items()}
    dup = _duplicated_from_last(days)
    if dup.any():
        message("Hinweis: '%s' hat %d doppelte Daten; der letzte Wert je Datum wird verwendet." % (name, int(dup.sum())))
        days = days[~dup]
        cols = {k: v[~dup] for k, v in cols.items()}
    return days, cols


# ═══════════════════════════════════════════════════════════════════════════
# series_align
# ═══════════════════════════════════════════════════════════════════════════

def _match_days(a, b) -> np.ndarray:
    """``match(a, b)`` für float-Tage (0-basiert, -1 = kein Treffer)."""
    pos = {}
    for i, v in enumerate(b):
        if v not in pos:
            pos[v] = i
    return np.array([pos.get(v, -1) for v in a], dtype=np.int64)


def series_align(*args, calendar=("day", "union", "intersect"), range=("common", "all"),  # noqa: A002
                 fill=("locf", "linear", "none"), max_gap=math.inf, start=None, end=None, **sources):
    """Datenquellen nach Datum zusammenführen.

    Führt Kursreihen aus verschiedenen Quellen auf einen gemeinsamen Kalender
    zusammen und liefert einen ``DataFrame`` mit Spalte ``date`` und je einer
    numerischen Spalte pro Reihe. Erwartet werden Niveaus (Kurse,
    Indexstände), keine Renditen: Lücken werden mit dem letzten Kurs (LOCF)
    oder linear gefüllt.

    Args:
        **sources: Benannte Quellen (Name = Spaltenname im Ergebnis):
            ``DataFrame(date, value)`` mit genau einer numerischen Spalte (sie
            wird nach dem Argument benannt), ``DataFrame(date, A, B, ...)`` mit
            mehreren numerischen Spalten oder benannte numerische Vektoren
            (``pandas.Series``/``dict``) mit Datumsnamen.
        calendar: ``"day"`` (alle Kalendertage), ``"union"`` oder ``"intersect"``.
        range: ``"common"`` (vom spätesten Start bis zum frühesten Ende) oder ``"all"``.
        fill: ``"locf"``, ``"linear"`` oder ``"none"`` (nur innerhalb der Laufzeit).
        max_gap: Höchste Lücke in Kalendertagen, die noch gefüllt wird.
        start, end: Optional Beginn und Ende des Zeitraums.

    Returns:
        ``pandas.DataFrame`` mit Spalte ``date`` und je einer Spalte pro Reihe;
        ``df.attrs["filled"]``: ``DataFrame`` (bool, Spalten = Reihen, TRUE =
        gefüllter Wert).
    """
    calendar = _match_arg(calendar, ("day", "union", "intersect"))
    rng = _match_arg(range, ("common", "all"))
    fill = _match_arg(fill, ("locf", "linear", "none"))
    if args or not sources or any(k == "" for k in sources):
        raise ValueError("series_align: Quellen benennen, z. B. series_align(us = df1, eu = df2).")
    fr = [(nm,) + _dp_frame(src, nm) for nm, src in sources.items()]
    first = [f[1][0] if len(f[1]) else _NAN for f in fr]
    last = [f[1][-1] if len(f[1]) else _NAN for f in fr]
    if any(math.isnan(v) for v in first):
        raise ValueError("missing value where TRUE/FALSE needed")
    lo = max(first) if rng == "common" else min(first)
    hi = min(last) if rng == "common" else max(last)
    if start is not None:
        s0 = _days(_to_date(start, "series_align: start"))
        lo = max([lo] + list(s0)) if not np.isnan(s0).any() else _NAN
    if end is not None:
        e0 = _days(_to_date(end, "series_align: end"))
        hi = min([hi] + list(e0)) if not np.isnan(e0).any() else _NAN
    if math.isnan(lo) or math.isnan(hi):
        raise ValueError("missing value where TRUE/FALSE needed")
    if lo > hi:
        raise ValueError("series_align: Die Quellen \u00fcberlappen sich nicht.")
    if calendar == "day":
        dates = lo + np.arange(int(math.floor(hi - lo)) + 1, dtype=np.float64)
    elif calendar == "union":
        dates = np.unique(np.concatenate([f[1] for f in fr]))
    else:
        dates = fr[0][1].copy()
        for f in fr[1:]:
            bset = set(f[1].tolist())
            dates = np.array([v for v in dates if v in bset], dtype=np.float64)
    dates = dates[(dates >= lo) & (dates <= hi)]
    out = {"date": _as_dates(dates)}
    filled = {}
    from .backcast import _fill_na
    for nm, fd, fc in fr:
        for k, vals in fc.items():
            if k in out:
                raise ValueError("series_align: Spaltenname '%s' kommt mehrfach vor." % k)
            mi = _match_days(dates, fd)
            v = np.where(mi >= 0, vals[np.maximum(mi, 0)] if len(vals) else _NAN, _NAN).astype(np.float64)
            obs = ~np.isnan(v)
            in_life = (dates >= fd[0]) & (dates <= fd[-1])
            if fill != "none" and obs.any():
                w = _fill_na(v, fill, keep_leading=True)
                w[~in_life] = _NAN
                if math.isfinite(max_gap):
                    oi = np.flatnonzero(obs)
                    gd = np.diff(dates[oi])
                    long = np.flatnonzero((gd > max_gap) & (np.diff(oi) > 1))
                    for j in long:
                        w[oi[j] + 1: oi[j + 1]] = _NAN
                    if len(long):
                        message("Hinweis: '%s': %d L\u00fccken > %s Tage bleiben NA." % (k, len(long), _sprintf_g(max_gap)))
                v = w
            out[k] = v
            filled[k] = ~obs & ~np.isnan(v)
    df = pd.DataFrame(out)
    df.attrs["filled"] = pd.DataFrame(filled, columns=list(filled.keys())).astype(bool)
    return df


# ═══════════════════════════════════════════════════════════════════════════
# series_check
# ═══════════════════════════════════════════════════════════════════════════

class SimLevDataCheck(RList):
    """Prüfbericht aus :func:`series_check` (R-Klasse ``SimLevDataCheck``)."""

    r_class = ("SimLevDataCheck",)

    def format(self, max_issues=25) -> str:
        from ._r import fmt as _fmt
        out = ["SimLev-Datenpr\u00fcfung\n\n"]
        S = self["summary"]
        if S is None:
            out.append("NULL\n")
        else:
            out.append(_fmt.print_data_frame(S, row_names=False, types=_check_types(S)) + "\n")
        I = self["issues"]
        n = int(I.shape[0])
        if not n:
            out.append("\nKeine Auff\u00e4lligkeiten.\n")
        else:
            out.append("\n%d Auff\u00e4lligkeiten%s:\n" % (n, (" (erste %d)" % max_issues) if n > max_issues else ""))
            y = I.iloc[:max_issues].copy()
            info = y["info"].to_numpy(dtype=np.float64)
            fi = _fmt.formatC(info, digits=2, format="f")
            y["info"] = np.array(["" if math.isnan(info[i]) else str(fi[i]) for i in np.arange(len(info))], dtype=object)
            out.append(_fmt.print_data_frame(y.reset_index(drop=True), row_names=False,
                                             types=_check_types(y)) + "\n")
        txt = "".join(out)
        return txt[:-1] if txt.endswith("\n") else txt

    def print(self, max_issues=25):
        print(self.format(max_issues))
        return self


def _check_types(df):
    t = {}
    for c in df.columns:
        if c in ("start", "end") and df[c].dtype != object and df[c].dtype.kind == "f":
            t[c] = "double"
            continue
        if c in ("start", "end") and df[c].dtype == object:
            t[c] = "logical"
            continue
        if c in ("n", "missing", "jumps", "spikes", "splits", "stale_max", "nonpositive"):
            t[c] = "integer"
        elif c in ("start", "end", "date"):
            t[c] = "Date"
        elif c in ("value",):
            t[c] = "double"
        elif c in ("column", "type", "info"):
            t[c] = "character"
    return t


def _which_min(a) -> int:
    best = -1
    bv = math.inf
    for i, v in enumerate(a):
        if not math.isnan(v) and (best < 0 or v < bv):
            best, bv = i, v
    return best


def _rsign(x):
    if math.isnan(x):
        return x          # sign(NA) = NA, sign(NaN) = NaN
    return 1.0 if x > 0 else (-1.0 if x < 0 else 0.0)


def _rle_true_runs(b):
    """``rle(b)``: Längen und Werte (b ohne NA)."""
    lengths, values = [], []
    for v in b:
        if values and values[-1] == v:
            lengths[-1] += 1
        else:
            values.append(bool(v))
            lengths.append(1)
    return lengths, values


def series_check(data, *, columns=None, jump=20, stale=10, revert=0.8):
    """Kursreihen prüfen.

    Erstellt einen Prüfbericht für eigene Kursreihen: fehlende oder nicht
    lesbare Daten, doppelte oder unsortierte Daten, Kalenderlücken über 5
    Tage, fehlende Werte innerhalb der Laufzeit, Sprünge, wahrscheinliche
    Splits, Spikes, Werte <= 0 und stehende Kurse. Die Daten werden nicht
    geändert.

    Args:
        data: ``DataFrame`` mit Spalte ``date`` und Kursspalten.
        columns: zu prüfende Spalten (Standard ``None`` = alle numerischen außer ``date``).
        jump: Sprungschwelle in Prozent (20 = 20 %).
        stale: Mindestlänge in Zeilen einer Folge unveränderter Werte.
        revert: Rücklauf am Folgetag als Anteil des Sprungs (Log-Renditen).

    Returns:
        :class:`SimLevDataCheck` mit ``summary``, ``issues`` und ``settings``.
    """
    data = _as_frame(data)
    if not isinstance(data, pd.DataFrame) or "date" not in _names(data):
        raise ValueError("series_check: data.frame mit Spalte 'date' erwartet.")
    d = _days(_to_date(_col(data, "date"), "series_check: date", strict=False))
    if columns is None:
        columns = [k for k in _names(data) if _is_numeric_col(_col(data, k)) and k != "date"]
    elif isinstance(columns, str):
        columns = [columns]
    issues = []

    def add(col, i, type_, value, info=_NAN):
        issues.append((col, d[i], type_, value, info))

    for i in np.flatnonzero(np.isnan(d))[:20]:
        add("date", i, "Datum fehlt oder nicht lesbar (Zeile %d)" % (i + 1), _NAN)
    okd = np.flatnonzero(~np.isnan(d))
    dd = d[okd]
    dupl = _duplicated(dd)
    if dupl.any():
        for i in okd[dupl]:
            add("date", i, "doppeltes Datum", _NAN)
    dg = np.diff(dd)
    if (dg < 0).any():
        add("date", okd[np.flatnonzero(dg < 0)[0] + 1], "Datum nicht sortiert", _NAN)
    for i in np.flatnonzero(dg > 5):
        add("date", okd[i + 1], "Kalenderl\u00fccke (Tage)", float(dg[i]))
    cand = [2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0] + [1.0 / k for k in (2, 3, 4, 5, 6, 7, 8, 9, 10)]
    rows = []
    for k in columns:
        v = _as_numeric(_col(data, k))
        ok = np.flatnonzero(~np.isnan(v))
        if not len(ok):
            rows.append(dict(column=k, start=_NAN, end=_NAN, n=0, missing=len(v), jumps=0,
                             spikes=0, splits=0, stale_max=0, nonpositive=0))
            continue
        inner = np.arange(ok[0], ok[-1] + 1)
        miss = int(np.isnan(v[inner]).sum())
        with np.errstate(invalid="ignore"):
            npos = np.flatnonzero(v <= 0)
        for i in npos[:20]:
            add(k, i, "Wert <= 0", float(v[i]))
        x = v[ok]
        with np.errstate(invalid="ignore", divide="ignore"):
            r = x[1:] / x[:-1] - 1
            r[~((x[1:] > 0) & (x[:-1] > 0))] = _NAN
        ri = ok[1:]
        J = np.flatnonzero(np.isfinite(r) & (np.abs(r) > jump / 100))
        n_spike = n_split = 0
        skip = []
        for j in J:
            if j in skip:
                continue
            nxt = float(r[j + 1]) if j < len(r) - 1 else _NAN
            ratio = float(x[j] / x[j + 1])
            near = cand[_which_min([abs(_libm.log(ratio / c)) for c in cand])]
            rj = float(r[j])
            if (not math.isnan(nxt) and _rsign(nxt) != _rsign(rj)
                    and abs(_libm.log1p(nxt)) >= revert * abs(_libm.log1p(rj))):
                n_spike += 1
                skip.append(j + 1)
                add(k, ri[j], "Spike (R\u00fccklauf am Folgetag)", float(v[ri[j]]), 100 * rj)
            elif abs(_libm.log(ratio / near)) < 0.02:
                n_split += 1
                lab = ("%s:1" % _sprintf_g(near)) if near >= 1 else ("1:%s" % _sprintf_g(1 / near))
                add(k, ri[j], "m\u00f6glicher Split (Verh\u00e4ltnis %s)" % lab, float(v[ri[j]]), 100 * rj)
            else:
                add(k, ri[j], "Sprung", float(v[ri[j]]), 100 * rj)
        lengths, values = _rle_true_runs(list(np.diff(x) == 0))
        runs = [L for L, b in zip(lengths, values) if b]
        smax = (max(runs) + 1) if runs else 1
        if runs:
            cs = np.cumsum(lengths)
            ends = [int(cs[i]) for i, b in enumerate(values) if b]
            long = [q for q in np.arange(len(runs)) if runs[q] + 1 >= stale]
            for q in long[:20]:
                add(k, ok[ends[q] - runs[q]], "stehender Kurs (Zeilen)", float(x[ends[q] - 1]), float(runs[q] + 1))
        jumps = len([j for j in J if j not in set(skip)])
        rows.append(dict(column=k, start=d[ok[0]], end=d[ok[-1]], n=len(ok), missing=miss, jumps=jumps,
                         spikes=n_spike, splits=n_split, stale_max=smax, nonpositive=len(npos)))
    if rows:
        # wie rbind() in R: beginnt die Tabelle mit einer Spalte ohne Werte (start = NA, logisch),
        # werden start/end numerisch (Tage) statt Date
        if rows[0]["n"] == 0:
            st = np.array([r["start"] for r in rows], dtype=np.float64)
            en = np.array([r["end"] for r in rows], dtype=np.float64)
            if np.isnan(st).all():
                st = np.array([None] * len(rows), dtype=object)
                en = np.array([None] * len(rows), dtype=object)
        else:
            st = _as_dates([r["start"] for r in rows])
            en = _as_dates([r["end"] for r in rows])
        S = pd.DataFrame({
            "column": np.array([r["column"] for r in rows], dtype=object),
            "start": st,
            "end": en,
            **{c: np.array([r[c] for r in rows], dtype=np.int64)
               for c in ("n", "missing", "jumps", "spikes", "splits", "stale_max", "nonpositive")},
        })
    else:
        S = None
    I = pd.DataFrame({
        "column": np.array([t[0] for t in issues], dtype=object),
        "date": _as_dates([t[1] for t in issues]),
        "type": np.array([t[2] for t in issues], dtype=object),
        "value": np.array([t[3] for t in issues], dtype=np.float64),
        "info": np.array([t[4] for t in issues], dtype=np.float64),
    })
    res = SimLevDataCheck()
    res["summary"] = S
    res["issues"] = I
    res["settings"] = pd.Series([float(jump), float(stale), float(revert)], index=["jump", "stale", "revert"])
    return res


def print_SimLevDataCheck(x, max_issues=25):  # noqa: N802 - R-Name
    """``print.SimLevDataCheck(x, max_issues = 25)``."""
    print(x.format(max_issues))
    return x


# ═══════════════════════════════════════════════════════════════════════════
# series_align_macro
# ═══════════════════════════════════════════════════════════════════════════

def _find_interval(x, vec) -> np.ndarray:
    """``findInterval(x, vec)`` (vec aufsteigend); NA -> nan, sonst float-Index (0 = davor)."""
    x = np.asarray(x, dtype=np.float64)
    j = np.searchsorted(np.asarray(vec, dtype=np.float64), x, side="right").astype(np.float64)
    j[np.isnan(x)] = _NAN
    return j


def series_align_macro(data, macro, *, name="macro", lag=0, lag_unit=("day", "month"),
                transform=("level", "yoy", "mom", "diff", "yoy_diff"), periods=None):
    """Makroreihen mit Veröffentlichungsverzug auf den Tageskalender legen.

    Ein Wert gilt ab ``Referenzdatum + lag`` bis zum nächsten verfügbaren Wert
    (Stufenfunktion); davor ist das Ergebnis NA. Die Umrechnung
    (``transform``) erfolgt auf der Makroreihe selbst, vor der Zuordnung.

    Args:
        data: Datumsvektor oder ``DataFrame`` mit Spalte ``date``.
        macro: ``DataFrame(date, value)`` oder benannter numerischer Vektor mit Datumsnamen.
        name: Name der neuen Spalte, wenn ``data`` ein ``DataFrame`` ist.
        lag: Veröffentlichungsverzug in Einheiten von ``lag_unit``.
        lag_unit: ``"day"`` oder ``"month"`` (auf das Monatsende begrenzt).
        transform: ``"level"``, ``"yoy"``, ``"mom"``, ``"diff"`` oder ``"yoy_diff"``.
        periods: Perioden je Jahr (``None`` = aus dem mittleren Datumsabstand).

    Returns:
        Bei Datumsvektor ``numpy.ndarray`` gleicher Länge, sonst ``data`` mit neuer Spalte ``name``.
    """
    lag_unit = _match_arg(lag_unit, ("day", "month"))
    transform = _match_arg(transform, ("level", "yoy", "mom", "diff", "yoy_diff"))
    md, mc = _dp_frame(macro, "macro")
    v = list(mc.values())[0]
    if periods is None:
        sp = r_median(np.diff(md))
        periods = 1 if sp >= 300 else 4 if sp >= 80 else 12 if sp >= 25 else 52 if sp >= 6 else 252
    p = int(periods)
    k = len(v)
    y, mo, _ = _days_to_civil(md.astype(np.int64))
    mon = mo - 1
    key = {1: y, 4: 4 * y + mon // 3, 12: 12 * y + mon}.get(p)

    def _match_key(a, b):
        pos = {}
        for i, e in enumerate(b):
            pos.setdefault(int(e), i)
        return np.array([pos.get(int(e), -1) for e in a], dtype=np.int64)

    if key is not None:
        prev = _match_key(key - 1, key)
        prev_y = _match_key(key - p, key)
    else:
        idx = np.arange(k)
        prev = idx - 1
        prev_y = np.where(idx + 1 > p, idx - p, -1)

    def shift(ix):
        return np.where(ix >= 0, v[np.maximum(ix, 0)] if k else _NAN, _NAN)

    with np.errstate(invalid="ignore", divide="ignore"):
        if transform == "level":
            vv = v
        elif transform == "yoy":
            vv = 100 * (v / shift(prev_y) - 1)
        elif transform == "mom":
            vv = 100 * (v / shift(prev) - 1)
        elif transform == "diff":
            vv = v - shift(prev)
        else:
            vv = v - shift(prev_y)
    lagf = float(np.asarray(lag, dtype=np.float64).ravel()[0])
    if lag_unit == "day" or lagf == 0:
        avail = md + (lagf if lag_unit == "day" else 0.0)
    else:
        avail = _days(_add_months(_as_dates(md), lag))
    is_df = isinstance(_as_frame(data), pd.DataFrame)
    if is_df:
        data = _as_frame(data)
    dates = _days(_to_date(_col(data, "date") if is_df else data, "series_align_macro: data"))
    o = np.argsort(avail, kind="stable")
    avail = avail[o]
    vv = np.asarray(vv, dtype=np.float64)[o]
    j = _find_interval(dates, avail)
    out = np.full(len(dates), _NAN)
    good = ~np.isnan(j) & (np.nan_to_num(j) > 0)
    out[good] = vv[j[good].astype(np.int64) - 1]
    if is_df:
        data = data.copy()
        data[name] = out
        return data
    return out


# ═══════════════════════════════════════════════════════════════════════════
# series_convert_currency, index_total_return, series_deflate
# ═══════════════════════════════════════════════════════════════════════════

def series_convert_currency(data, columns, fx, *, method=("divide", "multiply"), suffix=None):
    """Währung umrechnen.

    Je Zeile wird der Kurs durch den Wechselkurs geteilt (``"divide"``) oder
    mit ihm multipliziert (``"multiply"``).

    Args:
        data: ``DataFrame`` mit Spalte ``date`` und den Kursspalten.
        columns: umzurechnende Spalten.
        fx: Wechselkurs als Niveau: Spaltenname, ``DataFrame(date, value)``
            (Stufenfunktion), benannter Vektor mit Datumsnamen, Vektor der
            Länge ``nrow(data)`` oder Skalar. Alle Werte positiv.
        method: ``"divide"`` oder ``"multiply"``.
        suffix: Endung für neue Spalten; ``None`` = Spalten überschreiben.

    Returns:
        ``data`` (Kopie) mit umgerechneten bzw. zusätzlichen Spalten.
    """
    from .backcast import _resolve_series
    method = _match_arg(method, ("divide", "multiply"))
    if isinstance(columns, str):
        columns = [columns]
    data = _as_frame(data)
    nms = _names(data)
    miss = []
    for c in columns:
        if c not in nms and c not in miss:
            miss.append(c)
    if miss:
        raise ValueError("series_convert_currency: Spalte(n) %s fehlen in data (vorhanden: %s)."
                         % (", ".join("'%s'" % m for m in miss), ", ".join(nms)))
    f = _resolve_series(fx, data, "fx")
    with np.errstate(invalid="ignore"):
        bad = np.flatnonzero(~np.isfinite(f) | (f <= 0))
    if len(bad):
        raise ValueError("series_convert_currency: Wechselkurs fx muss positiv sein; %d Zeilen ung\u00fcltig (z. B. Zeile %d: %s)."
                         % (len(bad), bad[0] + 1, _fmt_num(f[bad[0]])))
    data = data.copy()
    for k in columns:
        nm = k if suffix is None else k + suffix
        x = _as_numeric(_col(data, k))
        data[nm] = x / f if method == "divide" else x * f
    return data


def index_total_return(price, *, dividends=None, yield_=None, withholding=0, dates=None, start=None, **kw):
    """Total-Return-Index aus Kursindex und Ausschüttungen.

    r_t = (P_t + D_t (1 - w)) / P_{t-1} - 1 + y_t/100 (1-w) Δt/365.25

    Args:
        price: Kursreihe (Niveaus); NA werden per LOCF gefüllt.
        dividends: Ausschüttung je Anteil am Ex-Tag (0 oder NA sonst).
        yield_: Dividendenrendite in Prozent p. a. (auch als ``yield=`` über
            ``**{"yield": ...}`` angebbar, wie in R).
        withholding: Quellensteuer in Prozent.
        dates: Datumsvektor gleicher Länge für Δt (aufsteigend).
        start: Startwert (Standard erster Kurs).

    Returns:
        ``numpy.ndarray`` (Index gleicher Länge wie ``price``).
    """
    from .backcast import _fill_na
    if "yield" in kw:
        yield_ = kw.pop("yield")
    if kw:
        raise TypeError("unused argument(s): %s" % ", ".join(kw))
    p = _as_numeric(price)
    n = len(p)
    w = withholding / 100
    if np.isnan(p).any():
        p = _fill_na(p, "locf")
    if dividends is None:
        D = np.zeros(n)
    else:
        D = _as_numeric(dividends).copy()
        D[np.isnan(D)] = 0
    y = np.zeros(n) if yield_ is None else np.resize(_as_numeric(np.atleast_1d(yield_)), n)
    if dates is not None:
        dd = _days(_to_date(dates, "index_total_return: dates"))
        if len(dd) != n:
            raise ValueError("index_total_return: dates hat L\u00e4nge %d, price %d." % (len(dd), n))
        if np.isnan(dd).any() or (np.diff(dd) < 0).any():
            raise ValueError("index_total_return: dates m\u00fcssen vollst\u00e4ndig und aufsteigend sortiert sein (wie price).")
        dt = np.concatenate([[0.0], np.diff(dd)])
    else:
        dt = np.ones(n)
    r = np.concatenate([[0.0], (p[1:] + D[1:] * (1 - w)) / p[:-1] - 1 + y[1:] / 100 * (1 - w) * dt[1:] / 365.25])
    s = p[0] if start is None else start
    return s * r_cumprod(1 + r)


def _cpi_level(cpi, data, dts, what):
    """Preisindex-Niveau je Zeile; vor dem ersten bekannten Wert NA (Port von ``.cpi_level``).

    Args:
        cpi: Spaltenname, ``DataFrame(date, value)``, benannter Vektor oder Vektor.
        data: ``DataFrame`` (für Spaltennamen).
        dts: Datumswerte der Zeilen (datetime64 oder float-Tage).
        what: Bezeichnung für Meldungen.

    Returns:
        float-Array der Länge ``len(dts)``.
    """
    from .backcast import _fill_na, _resolve_series
    dts_days = _days(dts)
    if isinstance(cpi, str):
        if cpi not in _names(data):
            raise ValueError("%s: Spalte '%s' fehlt im Datensatz." % (what, cpi))
        return _fill_na(_as_numeric(_col(data, cpi)), "locf", keep_leading=True)
    cpi = _as_frame(cpi)
    first = None
    if isinstance(cpi, pd.DataFrame):
        nm = _names(cpi)
        dcol = "date" if "date" in nm else nm[0]
        fd = _days(_to_date(_col(cpi, dcol), "%s: Datum" % what))
        fd = fd[~np.isnan(fd)]
        first = float(np.min(fd)) if len(fd) else math.inf
    elif _is_named_numeric(cpi):
        names, _ = _named_parts(cpi)
        nd = _names_as_dates_optional(names)
        if not np.isnan(nd).any():
            first = float(np.min(nd))
    v = _resolve_series(cpi, pd.DataFrame({"date": _as_dates(dts_days)}), what)
    if first is not None:
        v = np.array(v, dtype=np.float64)
        v[dts_days < first] = _NAN
    return v


def series_deflate(data, columns, cpi, *, base_date=None, suffix="_real"):
    """Reale Werte über einen Preisindex: real_t = nominal_t * cpi_b / cpi_t.

    Args:
        data: ``DataFrame`` mit Spalte ``date`` und den Spalten aus ``columns``.
        columns: Spalten, die deflationiert werden.
        cpi: Preisindex-Niveau (Spaltenname, ``DataFrame(date, value)``,
            benannter Vektor mit Datumsnamen oder Vektor der Länge ``nrow(data)``).
        base_date: Bezugsdatum (``None`` = erste Zeile mit bekanntem Preisindex).
        suffix: Endung der neuen Spalten.

    Returns:
        ``data`` (Kopie) mit zusätzlichen realen Spalten.
    """
    if isinstance(columns, str):
        columns = [columns]
    data = _as_frame(data)
    dts = _days(_to_date(_col(data, "date"), "series_deflate: data$date"))
    c0 = _cpi_level(cpi, data, dts, "cpi")
    known = np.flatnonzero(~np.isnan(c0))
    if not len(known):
        raise ValueError("series_deflate: Preisindex cpi hat keinen Wert im Zeitraum von data.")
    if known[0] > 0:
        message("Hinweis: series_deflate: Preisindex erst ab %s bekannt; %d Zeilen davor bleiben NA."
                % (_date_str(dts[known[0]]), known[0]))
    if base_date is None:
        b = known[0]
    else:
        bd = _days(_to_date(base_date, "base_date"))
        b = _which_min(list(np.abs(dts - bd[0])))
    if math.isnan(c0[b]):
        raise ValueError("series_deflate: am Bezugsdatum %s ist kein Preisindex bekannt (erster Wert am %s); base_date sp\u00e4ter w\u00e4hlen."
                         % (_date_str(dts[b]), _date_str(dts[known[0]])))
    data = data.copy()
    for k in columns:
        data[k + suffix] = _as_numeric(_col(data, k)) / c0 * c0[b]
    return data


# ═══════════════════════════════════════════════════════════════════════════
# series_splice
# ═══════════════════════════════════════════════════════════════════════════

def series_splice(*args, dates=None, **series):
    """Reihen verketten (Proxy -> Index -> Fonds).

    Verbindet mehrere Reihen renditebasiert zu einer langen Historie; die
    erste Reihe hat Vorrang.

    Args:
        **series: Mindestens zwei benannte Reihen in Prioritätsreihenfolge,
            alle als numerische Vektoren gleicher Länge (dann ``dates``
            angeben) oder alle als ``DataFrame(date, value)``.
        dates: Datumsvektor bei Vektoren.

    Returns:
        ``DataFrame`` mit ``date``, ``value`` und ``source``.
    """
    src = series
    if args or len(src) < 2:
        raise ValueError("series_splice: mindestens zwei benannte Reihen.")
    names = list(src.keys())
    Fl = None
    if all(isinstance(_as_frame(v), pd.DataFrame) for v in src.values()):
        al = series_align(**{k: _as_frame(v) for k, v in src.items()}, range="all")
        dts = _days(al["date"].to_numpy())
        V = np.column_stack([al[k].to_numpy(dtype=np.float64) for k in names])
        Fl = np.column_stack([al.attrs["filled"][k].to_numpy(dtype=bool) for k in names])
    else:
        if dates is None:
            raise ValueError("series_splice: 'dates' angeben, wenn Vektoren \u00fcbergeben werden.")
        V = np.column_stack([_as_numeric(v) for v in src.values()])
        dts = None
    n = V.shape[0]
    with np.errstate(invalid="ignore", divide="ignore"):
        Rm = np.vstack([np.full((1, V.shape[1]), _NAN), V[1:, :] / V[:-1, :] - 1]) if n else V.copy()
    p = V[:, 0].copy()
    if Fl is not None:
        other = ((~np.isnan(V[:, 1:])) & ~Fl[:, 1:]).sum(axis=1) > 0
        run = np.cumsum(~Fl[:, 0])
        a1 = (other & Fl[:, 0]).astype(np.float64)
        a2 = Fl[:, 0].astype(np.float64)
        gmax, gsum = {}, {}
        for i in np.arange(n):
            g = int(run[i])
            gmax[g] = max(gmax.get(g, -math.inf), a1[i])
            gsum[g] = gsum.get(g, 0.0) + a2[i]
        gap = Fl[:, 0] & np.array([gmax[int(g)] > 0 for g in run], dtype=bool) & \
            np.array([gsum[int(g)] > 4 for g in run], dtype=bool)
        p[gap] = _NAN
        Rm[gap, 0] = _NAN
    fin = np.isfinite(Rm)
    has = fin.any(axis=1)
    pick = np.where(has, np.argmax(fin, axis=1), -1)
    r = np.where(has, Rm[np.arange(n), np.maximum(pick, 0)], _NAN)
    nz = np.flatnonzero(~np.isnan(p))
    if not len(nz):
        raise ValueError("series_splice: Die erste Reihe hat keine Werte.")
    a = int(nz[0])
    lv = np.full(n, _NAN)
    lv[a] = p[a]
    for t in np.arange(a + 1, n):
        if not math.isnan(p[t]):
            lv[t] = p[t]
        elif not math.isnan(r[t]):
            lv[t] = lv[t - 1] * (1 + r[t])
        else:
            lv[t] = lv[t - 1]
    if a > 0:
        for t in np.arange(a, 0, -1):
            if math.isnan(r[t]):
                break
            lv[t - 1] = lv[t] / (1 + r[t])
    srcname = np.array([names[0] if not math.isnan(p[i]) else (None if pick[i] < 0 else names[pick[i]])
                        for i in np.arange(n)], dtype=object)
    srcname[np.isnan(lv)] = None
    out_dates = _as_dates(dts) if dts is not None else _to_date(dates, "series_splice: dates")
    return pd.DataFrame({"date": out_dates, "value": lv, "source": srcname})


# ═══════════════════════════════════════════════════════════════════════════
# Portfolios
# ═══════════════════════════════════════════════════════════════════════════

def _named(x):
    """Benannter Vektor -> (Namen, Werte als Liste); unbenannt -> (None, Werte)."""
    if isinstance(x, pd.Series):
        if isinstance(x.index, pd.RangeIndex):
            return None, list(x.to_numpy())
        return [None if _isna_scalar(i) else str(i) for i in x.index], list(x.to_numpy())
    if isinstance(x, Mapping):
        return [str(k) for k in x.keys()], list(x.values())
    if isinstance(x, (list, tuple, np.ndarray)):
        return None, list(np.asarray(x, dtype=object).ravel())
    return None, [x]


def strategy_from_weights(weights, **kwargs):
    """Strategie aus Gewichten.

    Baut aus einem benannten Gewichtsvektor eine statische Strategie für
    :func:`simulation`; jedes Asset erhält ``share = Gewicht``.

    Args:
        weights: Benannter Vektor (``dict``/``Series``) Spaltenname -> Gewicht
            als Anteil; alle positiv, Namen eindeutig, Summe 1.
        **kwargs: Weitere Argumente für :func:`asset_config`. Ein einzelner
            Wert gilt für alle Assets; benannte Vektoren (``dict``/``Series``)
            werden je Asset zugeordnet. Ausnahme ``wrapper`` (Fonds-Wrapper aus
            :func:`simlev.wrapper_config`): ein ``SimLevWrapperConfig`` gilt für
            alle Assets, ein ``dict`` Asset -> ``SimLevWrapperConfig`` je Asset
            (Assets ohne Eintrag bleiben ohne Wrapper). Unbekannte Namen,
            Einträge, die kein ``SimLevWrapperConfig`` sind, und ``wrapper`` mit
            ``trading="signal"`` für dasselbe Asset sind ein Fehler.

    Returns:
        ``Strategy`` (wie :func:`create_strategy`).

    Beispiel::

        w = wrapper_config(create_strategy(A=asset_config(share=0.6), B=asset_config(share=0.4)),
                           costs=funds_costs(fee=0.5))
        st = strategy_from_weights({"fonds": 0.8, "gold": 0.2},
                                   asset_class={"fonds": "certificate", "gold": "etc"},
                                   wrapper={"fonds": w})      # nur 'fonds' ist ein Wrapper
    """
    from .config import _AC_MSG_WRAPPER_SIGNAL, asset_config, create_strategy
    nms, vals = _named(weights)
    if nms is None or any(k is None or k == "" for k in nms):
        raise ValueError("weights muss benannt sein.")
    dup = _duplicated(nms)
    if dup.any():
        u = []
        for k, dflag in zip(nms, dup):
            if dflag and k not in u:
                u.append(k)
        raise ValueError("weights: doppelte Namen %s; jedes Asset nur einmal angeben." % ", ".join("'%s'" % k for k in u))
    w = np.array([_NAN if _isna_scalar(v) else float(v) for v in vals], dtype=np.float64)
    if np.isnan(w).any() or (w <= 0).any():
        raise ValueError("Gewichte m\u00fcssen positiv sein (Assets mit Gewicht 0 weglassen).")
    s = r_sum(w)
    if abs(s - 1) > 1e-6:
        raise ValueError("Gewichte summieren sich zu %.4f; simulation() verlangt die Summe 1 (Anteile, 0.6 = 60 %%)." % s)

    # Fonds-Wrapper (Etappe 8.0): ein SimLevWrapperConfig gilt für alle Assets, ein dict je Asset
    wmap = {}
    if "wrapper" in kwargs:
        kwargs = dict(kwargs)
        wmap = _sfw_wrappers(kwargs.pop("wrapper"), nms)

    def per_asset(v):
        vn, vv = _named(v)
        return vn is not None and (len(vv) > 1 or (len(vv) == 1 and vn[0] in nms))

    def scalar(v):
        if isinstance(v, Mapping) and len(v) == 1:
            v = list(v.values())[0]
            return v.item() if isinstance(v, np.generic) else v
        if isinstance(v, (list, tuple, np.ndarray, pd.Series)):
            a = list(np.asarray(v, dtype=object).ravel()) if not isinstance(v, pd.Series) else list(v.to_numpy())
            if len(a) == 1:
                a0 = a[0]
                if isinstance(a0, np.generic):
                    a0 = a0.item()
                return a0
            return v
        if isinstance(v, np.generic):
            return v.item()
        return v

    assets = {}
    for i, nm in enumerate(nms):
        a = {}
        for key, v in kwargs.items():
            if per_asset(v):
                vn, vv = _named(v)
                val = vv[vn.index(nm)] if nm in vn else None
                if isinstance(val, np.generic):
                    val = val.item()
            else:
                val = scalar(v)
            if val is None or (not isinstance(val, (list, tuple, np.ndarray, pd.Series, Mapping)) and _isna_scalar(val)):
                continue
            a[key] = val
        wr = wmap.get(nm)
        if wr is None:
            assets[nm] = asset_config(share=float(w[i]), **a)
            continue
        try:
            assets[nm] = asset_config(share=float(w[i]), **a, wrapper=wr)
        except ValueError as e:
            if str(e) == _AC_MSG_WRAPPER_SIGNAL:
                raise ValueError("wrapper: Asset '%s' hat trading = \"signal\"; mit wrapper ist nur trading = \"bnh\" "
                                 "möglich (keine Signale auf den Anteilswert; Signale gehen in der inneren Strategie)."
                                 % nm) from None
            raise
    return create_strategy(assets=assets)


def _sfw_wrappers(wv, assets):
    """Argument ``wrapper`` von :func:`strategy_from_weights` je Asset (R: ``.sfw_wrappers``, Etappe 8.0).

    ``None`` oder leer -> ohne Wrapper; ein ``SimLevWrapperConfig`` -> für alle Assets; ein ``dict`` (bzw.
    ``Series``) Asset -> ``SimLevWrapperConfig`` -> je Asset, Assets ohne Eintrag ohne Wrapper. Sonst Fehler
    (Reihenfolge: Art, Namen vorhanden, doppelte Namen, unbekannte Namen, Elemente). Ergebnis: ``dict``.
    """
    from .config import _cls_all, _is_wrapper
    if wv is None:
        return {}
    if _is_wrapper(wv):
        return {nm: wv for nm in assets}
    if isinstance(wv, pd.DataFrame) or not isinstance(wv, (Mapping, pd.Series, list, tuple)):
        raise ValueError("wrapper muss ein Objekt aus wrapper_config() (gilt f\u00fcr alle Assets) oder eine benannte "
                         "Liste solcher Objekte sein (Name = Asset), nicht %s." % _cls_all(wv))
    if len(wv) == 0:
        return {}
    nm, vals = _named(wv) if not isinstance(wv, (list, tuple)) else (None, list(wv))
    if nm is None or any(k is None or k == "" for k in nm):
        raise ValueError("wrapper: als Liste braucht jedes Element einen Namen (Name = Asset, z. B. "
                         "list(%s = wrapper_config(...)))." % assets[0])
    dup = _duplicated(nm)
    if dup.any():
        u = []
        for k, dflag in zip(nm, dup):
            if dflag and k not in u:
                u.append(k)
        raise ValueError("wrapper: doppelte Namen %s; jedes Asset nur einmal angeben." % ", ".join("'%s'" % k for k in u))
    unk = [k for k in nm if k not in assets]
    if unk:
        raise ValueError("wrapper: %s %s (Assets: %s)." % (", ".join("'%s'" % k for k in unk),
                                                           "ist kein Asset der Strategie" if len(unk) == 1
                                                           else "sind keine Assets der Strategie", ", ".join(assets)))
    for k, v in zip(nm, vals):
        if not _is_wrapper(v):
            raise ValueError("wrapper: Eintrag '%s' muss ein Objekt aus wrapper_config() sein, nicht %s." % (k, _cls_all(v)))
    return dict(zip(nm, vals))


_PORTFOLIO_TEMPLATES = {
    "60_40": {"stocks": 0.60, "bonds": 0.40},
    "permanent": {"stocks": 0.25, "long_bonds": 0.25, "cash": 0.25, "gold": 0.25},
    "all_weather": {"stocks": 0.30, "long_bonds": 0.40, "inter_bonds": 0.15, "gold": 0.075, "commodities": 0.075},
    "golden_butterfly": {"stocks": 0.20, "small_value": 0.20, "long_bonds": 0.20, "short_bonds": 0.20, "gold": 0.20},
    "three_fund": {"stocks": 0.48, "intl_stocks": 0.32, "bonds": 0.20},
    "hfea": {"stocks_3x": 0.55, "long_bonds_3x": 0.45},
    "stocks_gold": {"stocks": 0.80, "gold": 0.20},
}


def portfolio_template(*, name=None, map=None, **kwargs):  # noqa: A002 - R-Argumentname
    """Portfolio-Vorlagen.

    Bekannte statische Allokationen mit Rollen-Namen; über ``map`` werden die
    Rollen den Spalten des Datensatzes zugeordnet.

    Args:
        name: Name der Vorlage. Ohne ``name`` (Standard ``None``) liefert die
            Funktion die Liste aller Vorlagen; ``map`` und weitere Argumente
            sind dann nicht erlaubt.
        map: Benannter Vektor Rolle -> Spaltenname (``dict``/``Series``).
        **kwargs: Weitere Argumente für :func:`strategy_from_weights`. Namen je
            Asset (auch die Schlüssel eines ``wrapper``-``dict``) beziehen sich
            auf die Namen nach ``map``; Rollen ohne ``map``-Eintrag behalten
            ihren Namen, z. B. ``portfolio_template(name="60_40",
            map={"stocks": "aktienfonds"}, wrapper={"aktienfonds": w})``.

    Returns:
        Mit ``name``: ``Strategy`` für :func:`simulation`; ohne ``name``:
        ``DataFrame`` aller Vorlagen mit ``template``, ``role`` und ``weight``.
    """
    if name is None:
        if map is not None or kwargs:
            raise ValueError("portfolio_template: map und weitere Argumente nur zusammen mit name; ohne name "
                             "liefert portfolio_template() die Liste der Vorlagen.")
        return _template_list()
    w = _PORTFOLIO_TEMPLATES.get(name)
    if w is None:
        raise ValueError("Unbekannte Vorlage '%s'. Verf\u00fcgbar: %s" % (name, ", ".join(_PORTFOLIO_TEMPLATES)))
    roles = list(w.keys())
    vals = list(w.values())
    if map is not None:
        mn, mv = _named(map)
        if mn is None or any(k is None or k == "" for k in mn):
            raise ValueError("map muss benannt sein: Rolle -> Spaltenname, z. B. c(stocks = \"msci_world\").")
        unk = []
        for k in mn:
            if k not in roles and k not in unk:
                unk.append(k)
        if unk:
            raise ValueError("map: unbekannte Rolle(n) %s f\u00fcr Vorlage '%s'; Rollen: %s."
                             % (", ".join("'%s'" % k for k in unk), name, ", ".join(roles)))
        lookup = {}
        for k, v in zip(mn, mv):
            lookup.setdefault(k, v)
        roles = [str(lookup[r]) if r in lookup else r for r in roles]
        dup = _duplicated(roles)
        if dup.any():
            u = []
            for k, dflag in zip(roles, dup):
                if dflag and k not in u:
                    u.append(k)
            raise ValueError("map: mehrere Rollen zeigen auf dieselbe Spalte %s; je Spalte nur eine Rolle "
                             "(Gewichte sonst selbst zusammenfassen und strategy_from_weights() verwenden)."
                             % ", ".join("'%s'" % k for k in u))
    return strategy_from_weights(pd.Series(vals, index=roles, dtype=np.float64), **kwargs)


def _template_list():
    """Alle Portfolio-Vorlagen als ``DataFrame`` mit ``template``, ``role`` und ``weight``."""
    t, r, w = [], [], []
    for n, d in _PORTFOLIO_TEMPLATES.items():
        for k, v in d.items():
            t.append(n)
            r.append(k)
            w.append(v)
    return pd.DataFrame({"template": np.array(t, dtype=object), "role": np.array(r, dtype=object),
                         "weight": np.array(w, dtype=np.float64)})


quiet_fp(globals(), __all__)
