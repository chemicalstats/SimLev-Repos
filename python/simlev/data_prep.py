"""Daten- und Portfolio-Aufbereitung (Gegenstück zu ``r/R/data_prep.R``).

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
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

from . import _ext
from ._dates import fmt_date
from ._r import libm as _libm
from ._r.base import quiet_fp
from ._r.fmt import NA_REAL
from ._r.rlist import RList
from ._r.rnum import r_cumprod, r_isna, r_mean, r_median, r_string_to_real, r_sum
from ._util import _match_arg, _which_min  # noqa: F401 (_match_arg für bonds/signals, _which_min für backcast)
from ._util import _match_days, _message as message
from ._r.rformat import _is_num as _is_number
from ._r.rformat import r_sprintf

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

def _isna_scalar(x) -> bool:
    if x is None or x is pd.NA or x is pd.NaT:
        return True
    if isinstance(x, (float, np.floating)):
        return math.isnan(float(x))
    if isinstance(x, np.datetime64):
        return bool(np.isnat(x))
    return False


def _sprintf_g(x) -> str:
    """C-``%g`` wie R-``sprintf("%g", x)``."""
    x = float(x)
    if math.isnan(x):
        return "NA" if r_isna(x) else "NaN"
    if math.isinf(x):
        return "Inf" if x > 0 else "-Inf"
    return "%g" % x


# ── Kalender (proleptisch gregorianisch, beliebige Jahre wie R) ─────────────

# Teil:               _civil_to_days, _days_to_civil
# Herkunft:           übersetzt aus H. Hinnant, chrono-Compatible Low-Level Date Algorithms,
#                     https://howardhinnant.github.io/date_algorithms.html
# Rechte:             gemeinfrei ("Consider these donated to the public domain.")
# Lizenz der Vorlage: keine (gemeinfrei)
# Änderungen:         vektorisiert mit numpy (int64, floor_divide); Monatsverschiebung als (m + 9) %
#                     12.
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


def _strptime_ymd(s, sep="-") -> float:
    """``as.Date(s, format = "%Y-%m-%d")`` (bzw. ``/``) für einen Text; NA = nan (Kern core/slc_rbase_date.cpp)."""
    if s is None:
        return _NAN
    z = _ext.slc_r_strptime_ymd(s, sep)
    return _NAN if z is None else float(z)


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


_DATE_RX = re.compile(r"^[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2}([ T][0-9]{1,2}:[0-9]{2}.*)?$", re.S)


def _to_date(x, what="date", strict=True) -> np.ndarray:
    """Datumsangaben in Date umwandeln (R: ``.to_date``).

    POSIX-Zeitstempel mit Zeitzone ergeben den Kalendertag in ihrer eigenen
    Zeitzone, Text nur die Formate "JJJJ-MM-TT" und "JJJJ/MM/TT"
    mit vierstelliger Jahreszahl am Anfang, danach seit 1.6.5 nur das Ende oder eine Uhrzeit; numerische Werte
    (außer nur NA, seit 1.6.5 NA) und (seit 1.6.4) Faktoren werden abgelehnt.
    Mit ``strict=True`` Fehler für nicht lesbare Werte, sonst NA. Leere
    Einträge ergeben NA.

    Args:
        x: datetime64-Array, ``pandas.Series``/``Index`` (auch mit Zeitzone),
            ``date``/``datetime``/``Timestamp``, Text (Skalar, Liste, Array),
            (keine ``pandas.Categorical``, seit 1.6.4).
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
        if isinstance(dt, pd.CategoricalDtype):   # seit 1.6.4 Fehler (Entscheidung 61; bis 1.6.3 still als Text)
            _chk().chk_stop("e5.datum_faktor", what)
        else:
            x = x.to_numpy()
    elif isinstance(x, pd.Categorical):
        _chk().chk_stop("e5.datum_faktor", what)
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
    if a.dtype.kind in "iuf":   # seit 1.6.4 ohne Eingabewert (Entscheidung 8)
        if a.dtype.kind == "f" and a.size and np.isnan(a).all():   # seit 1.6.5 (CR2-C-3): nur NA ergibt NA wie R
            return np.full(a.size, np.datetime64("NaT", "D"), dtype="datetime64[D]")
        _chk().chk_stop("a.m_to_date", what)
    a = a.ravel()
    if a.dtype == object:
        vals = [v for v in a if not _isna_scalar(v)]
        if vals and all(_is_datelike(v) for v in vals):
            return _as_dates([_obj_to_days(v) for v in a])
        if vals and all(_is_number(v) for v in vals):
            _chk().chk_stop("a.m_to_date", what)
        if not vals and a.size and all(v is None or isinstance(v, (bool, np.bool_)) for v in a):
            pass   # logisches NA: as.character -> NA
    s = _as_character_vec(a)
    s = [None if v is None else v.strip(" \t\r\n") for v in s]
    s = [None if (v is not None and v == "") else v for v in s]
    d = np.array([_strptime_ymd(v, "-") for v in s], dtype=np.float64)
    for i, v in enumerate(s):
        if v is not None and math.isnan(d[i]):
            d[i] = _strptime_ymd(v, "/")
    # seit 1.6.5 (CR2-C-3, Entscheidung 185 K27) nach dem Tag nur das Ende oder eine Uhrzeit
    rx4 = _DATE_RX
    bad = [i for i, v in enumerate(s) if v is not None and (math.isnan(d[i]) or not rx4.search(v))]
    if bad and strict:
        _chk().chk_stop("e.datum_format", what, len(bad), bad[0] + 1)   # seit 1.6.5 sprachneutral (K29, CR2-D-9)
    d[bad] = _NAN
    return _as_dates(d)


# --- Eingabeprüfung Forschung, Taktik, Datenaufbereitung, Dashboard (seit 1.6.4, K42 E5; Hilfen in _pruefen.py) ---

def _chk():
    from . import _pruefen
    return _pruefen


def _e5_choice(x, choices, fn, arg):
    """Auswahl wie R ``match.arg`` (``None`` oder der ganze Auswahlvektor = erste Wahl, eindeutige Präfixe werden
    ergänzt; Länge 1 wie Einzelwert); alles andere mit der Meldung ``auswahl`` (R ``.e5_choice``, gleiche Regel wie
    ``withdrawal._e3_choice``)."""
    from ._pruefen import chk_nofactor, chk_scalar, chk_stop
    from ._util import _pmatch
    choices = tuple(choices)
    if x is None:
        return choices[0]
    chk_nofactor(x, fn, arg)
    if isinstance(x, (list, tuple, np.ndarray)) and len(x) == len(choices) and \
            all(isinstance(v, str) for v in x) and tuple(str(v) for v in x) == choices:
        return choices[0]
    x = chk_scalar(x)
    if isinstance(x, str):
        i = _pmatch(str(x), choices)
        if i is not None:
            return choices[i]
    chk_stop("auswahl", fn, arg, ", ".join('"%s"' % c for c in choices))


def _e5_numvec(x, fn, arg):
    """Zahlenvektor wie ``chk_numvec``; ein Vektor nur aus NA (``None``, ``pd.NA``, NaN) gilt wie in R (``c(NA, NA)``)
    als Zahlenvektor mit NA (Entscheidung 14 sinngemäß; R ``.e5_numvec``). Ergebnis: ``x`` bzw. bei nur ``None``/``pd.NA``
    ein Feld aus NA_real_."""
    from ._pruefen import chk_numvec
    if isinstance(x, (list, tuple)) or (isinstance(x, np.ndarray) and x.dtype == object) or \
            (isinstance(x, pd.Series) and x.dtype == object):
        vals = list(np.asarray(x.to_numpy() if isinstance(x, pd.Series) else x, dtype=object).ravel())
        if vals and all(v is None or v is pd.NA or (isinstance(v, (float, np.floating)) and math.isnan(v)) for v in vals) \
                and not all(isinstance(v, (float, np.floating)) for v in vals):
            return np.full(len(vals), NA_REAL)
    chk_numvec(x, fn, arg)
    return x


def _e5_names(x, fn, arg, null_ok=False):
    """Vektor nicht leerer Namen (mindestens einer, keine Kategorie); Ergebnis als Liste (R ``.e5_names``)."""
    from ._pruefen import chk_nofactor, chk_stop
    if x is None and null_ok:
        return None
    chk_nofactor(x, fn, arg)
    v = [x] if isinstance(x, str) else list(x) if isinstance(x, (list, tuple, np.ndarray, pd.Series, pd.Index)) else None
    if not v or not all(isinstance(c, str) and c != "" for c in v):
        chk_stop("e3.namen", fn, arg)
    return [str(c) for c in v]


def _e5_numcols(data, cols, fn):
    """Zahlenspalten (keine Kategorie, kein Text, kein Datum); eine Spalte nur aus NA gilt als Zahlenspalte
    (Entscheidung 14; R ``.e5_numcols``)."""
    from ._pruefen import chk_msg, chk_stop
    from ._sim_base import _column, _isna
    for col in cols:
        k, a = _column(data[col])
        if k == "factor":
            chk_stop("spalte_faktor", fn, col)              # Entscheidung 15
        if not (k == "numeric" or (k == "logical" and all(_isna(v) for v in a))):
            chk_stop("spalte_typ", fn, col, chk_msg("typ.numerisch"))
    return data


def _e5_sorted(d):
    """Tage (float, NaN = NA) ohne NA und aufsteigend (R ``!anyNA(d) && !is.unsorted(d)``)."""
    d = np.asarray(d, dtype=np.float64)
    return not (np.isnan(d).any() or (d.size > 1 and (np.diff(d) < 0).any()))


def _e5_data_dates(data, fn, what):
    """Tabelle mit Datumsspalte: DataFrame, Spalte ``date`` vorhanden und keine Kategorie, mindestens eine Zeile,
    Datum ohne NA und aufsteigend; Ergebnis das Datum (``datetime64[D]``; R ``.e5_data_dates``)."""
    from ._pruefen import chk_cols, chk_col_nofactor, chk_df, chk_stop
    chk_df(data, fn, "data")
    chk_cols(data, ["date"], fn)
    chk_col_nofactor(data, "date", fn)
    if len(data) < 1:
        chk_stop("zeilen_keine", fn, "data")
    d = _to_date(data["date"], what)
    if not _e5_sorted(_days(d)):
        chk_stop("e3.datum", fn)
    return d


def _e5_weights_ok(w):
    """Benannte Gewichte (``dict``/``Mapping``, ``pandas.Series`` mit Namen): Namen nicht leer, Werte endliche
    Zahlen >= 0 (kein ``bool``, kein Text)."""
    from ._pruefen import chk_is_factor
    if chk_is_factor(w):
        return None
    if isinstance(w, pd.Series):
        if isinstance(w.index, pd.RangeIndex) or w.dtype.kind not in "iuf" or not len(w):
            return None
        items = [(k, v) for k, v in zip(w.index, w.to_numpy())]
    elif isinstance(w, Mapping):
        items = list(w.items())
    else:
        return None
    if not items:
        return None
    for k, v in items:
        if not (isinstance(k, str) and k != ""):
            return None
        if isinstance(v, (bool, np.bool_)) or not isinstance(v, (int, float, np.integer, np.floating)) or \
                not math.isfinite(float(v)) or float(v) < 0:
            return None
    return items


def _e5_weights(w, fn, arg):
    """Gewichte: benannter Vektor endlicher Zahlen >= 0 (R ``.e5_weights``; doppelte Namen sind in ``dict`` nicht
    darstellbar, ``pandas.Series`` mit doppeltem Index wie R abgelehnt)."""
    from ._pruefen import chk_nofactor, chk_stop
    chk_nofactor(w, fn, arg)
    items = _e5_weights_ok(w)
    if items is None:
        chk_stop("e5.gewichte", fn, arg)
    nm = [k for k, _ in items]
    if len(set(nm)) != len(nm):
        chk_stop("e2.doppelt", fn, arg)
    return w


def _e5_lookbacks(lookbacks, fn):
    """Rückblicke in Monaten: ganze Zahlen 1 bis 1200 (R ``.e5_lookbacks``)."""
    from ._pruefen import chk_intvec, chk_max, chk_nofactor
    chk_nofactor(lookbacks, fn, "lookbacks")
    chk_intvec(lookbacks, fn, "lookbacks", lo=1)
    chk_max(lookbacks, 1200, fn, "lookbacks")
    return lookbacks


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
    """Datum plus ``k`` Kalendermonate, auf das Monatsende begrenzt (R: ``.add_months``).

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
            # seit 1.6.5 (CR2-X42-1) wie R's as.numeric (String_to_real: Hex, "1e", Überlauf, Rundung wie R; "NA" als
            # Text NA mit Warnung, leerer Text ohne; bis 1.6.4 float(), das manche Texte anders las)
            out[i], bad = r_string_to_real(str(e))
            coerced |= bad
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

    R: ``.num_text_cols(x, exclude)``; liefert die Spaltennamen.
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
    """Fehlermeldung für Zahlen als Text (R: ``.num_text_stop``); löst ``ValueError`` aus."""
    if isinstance(cols, str):
        cols = [cols]
    # seit 1.6.4 ohne Beispielwert aus den Daten (Entscheidung 8)
    _chk().chk_stop("e.zahl_text", name, ", ".join("'%s'" % c for c in cols))   # seit 1.6.5 sprachneutral (K29, CR2-D-9)


def _is_named_numeric(x) -> bool:
    """Benannter numerischer Vektor (``pandas.Series`` mit Namen oder ``dict`` aus Zahlen)."""
    if isinstance(x, pd.Series):
        return not isinstance(x.index, pd.RangeIndex) and _is_numeric_col(x)
    if isinstance(x, Mapping) and not isinstance(x, pd.DataFrame):
        vals = list(x.values())
        # seit 1.6.5 (CR2-X17-2): None und pd.NA zählen als NA (wie NA in R und missing in Julia); mindestens ein
        # Wert, Wahrheitswerte nicht
        return (bool(vals) and all(v is None or v is pd.NA or (_is_number(v) and not isinstance(v, (bool, np.bool_)))
                                   or isinstance(v, float) for v in vals))
    return False


def _named_parts(x):
    if isinstance(x, pd.Series):
        return [str(i) for i in x.index], _as_numeric(x)
    return [str(k) for k in x.keys()], np.array([_NAN if (v is None or v is pd.NA) else float(v) for v in x.values()],
                                                dtype=np.float64)


def _as_frame(x):
    """dict aus Spalten -> DataFrame (andere Eingaben unverändert)."""
    if isinstance(x, Mapping) and not isinstance(x, pd.DataFrame) and not _is_named_numeric(x):
        try:
            return pd.DataFrame(dict(x))
        except Exception:  # noqa: BLE001
            return x
    return x


def _dup_names(v):
    """Mehrfach vorkommende Werte (je einmal, in der Reihenfolge ihrer ersten Wiederholung; seit 1.6.1 für die drei
    Namensprüfungen)."""
    u = []
    for k, dflag in zip(v, _duplicated(v)):
        if dflag and k not in u:
            u.append(k)
    return u


def _duplicated(v, from_last=False) -> np.ndarray:
    """R ``duplicated(v, fromLast)``; NaN/NA als ein Schlüssel, 0 und -0 gleich. Gleitkommafelder seit 1.5.2 ohne
    Schleife (``np.unique``: erstes Vorkommen je Wert)."""
    if isinstance(v, np.ndarray) and v.ndim == 1 and v.dtype.kind == "f":
        w = v[::-1] if from_last else v
        out = np.ones(len(w), dtype=bool)
        out[np.unique(w, return_index=True, equal_nan=True)[1]] = False
        return out[::-1].copy() if from_last else out
    seen = set()
    out = np.zeros(len(v), dtype=bool)
    for i in (range(len(v) - 1, -1, -1) if from_last else range(len(v))):
        key = v[i]
        if isinstance(key, float) and math.isnan(key):
            key = "NA"
        if key in seen:
            out[i] = True
        else:
            seen.add(key)
    return out


def _dp_frame(x, name, fn=None):
    """Eine Quelle in ``DataFrame(date, ...)`` mit numerischen Spalten wandeln (R: ``.dp_frame``).

    Returns:
        ``(days, cols)``: float-Tage (sortiert, eindeutig) und ``dict`` Spaltenname -> float-Array.
    """
    if _is_named_numeric(x):
        nm, vals = _named_parts(x)
        x = pd.DataFrame({"date": _to_date(np.array(nm, dtype=object), "'%s' (Namen)" % name), "value": vals})
    x = _as_frame(x)
    if not isinstance(x, pd.DataFrame):
        _chk().chk_stop("a.m_dp_frame", name)
    names = _names(x)
    if "date" in names:
        dcol = "date"
    else:
        dc = [k for k in names if _is_date_col(_col(x, k))]
        dcol = dc[0] if dc else (names[0] if names else None)
    if dcol is None:
        _chk().chk_stop("a.m_dp_frame_3", name)
    if fn is not None and _chk().chk_is_factor(x[dcol]):   # seit 1.6.4 (Entscheidung 15)
        _chk().chk_stop("spalte_faktor", fn, dcol)
    if _is_numeric_col(_col(x, dcol)):
        _chk().chk_stop("a.m_dp_frame_2", name, dcol)
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
        _chk().chk_stop("a.m_dp_frame_3", name)
    days = _days(_to_date(_col(x, dcol), "'%s': Spalte '%s'" % (name, dcol)))
    cols = {k: _as_numeric(_col(x, k)) for k in num}
    if len(num) == 1:
        cols = {name: cols[num[0]]}
    keep = ~np.isnan(days)
    days = days[keep]
    cols = {k: v[keep] for k, v in cols.items()}
    if not len(days) and fn is not None:   # seit 1.6.5 (CR2-I-5): Quelle ohne Zeilen mit Meldung
        _chk().chk_stop("zeilen_keine", fn, "'%s'" % name)
    o = np.argsort(days, kind="stable")
    days = days[o]
    cols = {k: v[o] for k, v in cols.items()}
    dup = _duplicated(days, from_last=True)
    if dup.any():
        message("Hinweis: '%s' hat %d doppelte Daten; der letzte Wert je Datum wird verwendet." % (name, int(dup.sum())))
        days = days[~dup]
        cols = {k: v[~dup] for k, v in cols.items()}
    return days, cols


# ═══════════════════════════════════════════════════════════════════════════
# series_align
# ═══════════════════════════════════════════════════════════════════════════

def series_align(*args, calendar=("day", "union", "intersect"), range=("common", "all"),  # noqa: A002
                 fill=("locf", "linear", "none"), max_gap=math.inf, start=None, end=None, **sources):
    """Datenquellen nach Datum zusammenführen.

    Einstieg für eigene Daten: Führt Kursreihen aus verschiedenen Quellen (z. B. mit ``utils::read.csv()``
    eingelesene Dateien) auf einen gemeinsamen Kalender zusammen und liefert einen DataFrame mit Spalte ``date``
    (Klasse Date) und je einer numerischen Spalte pro Reihe. Erwartet werden Niveaus (Kurse, Indexstände), keine
    Renditen: Lücken werden mit dem letzten Kurs (LOCF) oder linear gefüllt, was nur für Niveaus sinnvoll ist.
    Renditereihen vorher in einen Index umrechnen, z. B. ``100 * cumprod(1 + r)``.

    Args:
        *args: Benannte Quellen (Name = Spaltenname im Ergebnis): ``data.frame(date, value)`` mit genau einer
            numerischen Spalte (sie wird nach dem Argument benannt), ``data.frame(date, A, B, ...)`` mit mehreren
            numerischen Spalten (Spaltennamen bleiben erhalten und müssen über alle Quellen eindeutig sein) oder
            benannte numerische Vektoren mit Datumsnamen (``["2024-01-02" = 100, ...]``).
        calendar: Zeilen des Ergebnisses: ``"day"`` (Standard; alle Kalendertage), ``"union"`` (alle Daten, an
            denen mindestens eine Quelle notiert) oder ``"intersect"`` (nur Daten, an denen alle Quellen
            notieren).
        range: Zeitraum: ``"common"`` (Standard; vom spätesten Start bis zum frühesten Ende aller Quellen) oder
            ``"all"`` (gesamter Zeitraum; außerhalb der Laufzeit einer Reihe NA).
        fill: Füllung fehlender Werte: ``"locf"`` (Standard; letzter Wert), ``"linear"`` (lineare Interpolation)
            oder ``"none"``. Gefüllt wird nur innerhalb der Laufzeit einer Reihe (erstes bis letztes vorhandenes
            Datum).
        max_gap: Höchste Lücke in Kalendertagen zwischen zwei vorhandenen Werten, die noch gefüllt wird; längere
            Lücken bleiben NA (mit Hinweis). Standard ``Inf`` = alle Lücken füllen.
            Seit 1.6.4 Zahl >= 0 oder Inf.
        start, end: Optional Beginn und Ende des Zeitraums (Date oder ``"JJJJ-MM-TT"``); ``None`` = durch
            ``range`` bestimmt.
        **sources: Benannte Quellen (Name = Spaltenname im Ergebnis): ``data.frame(date, value)`` mit genau einer
            numerischen Spalte (sie wird nach dem Argument benannt), ``data.frame(date, A, B, ...)`` mit mehreren
            numerischen Spalten (Spaltennamen bleiben erhalten und müssen über alle Quellen eindeutig sein) oder
            benannte numerische Vektoren mit Datumsnamen (``["2024-01-02" = 100, ...]``).

    Returns:
        DataFrame mit Spalte ``date`` (Klasse Date) und je einer numerischen Spalte pro Reihe, mit Attribut
        ``filled`` (logische Matrix Zeilen x Reihen, True = gefüllter Wert).

    Details:
        Mit ``calendar = "day"`` (Standard) entsteht ein lückenloser Kalendertags-Kalender: Wochenenden und
        Feiertage werden gefüllt, und unterschiedliche Börsenkalender (z. B. US- und EU-Feiertage) werden ohne
        Zeilenverlust vereinheitlicht. Das Ergebnis passt direkt in ``simulation()``, ``series_check()``,
        ``result_analysis()`` (je Reihe als ``data.frame(date, value)``) und die Gewichts-Erzeuger wie
        ``tactical_rules()``. ``simulation()``, ``tactical_simulation()`` und ``result_analysis()`` werten das
        Attribut ``filled`` aus: Ein Tag, an dem keine Anlage der Strategie einen echten Kurs hat, gilt als
        aufgefüllt (kein Handel, nicht in den Risikokennzahlen) - genau wie Kalendertage, die ``simulation()`` bei
        Handelstagsdaten selbst per LOCF auffüllt.

        Je Quelle gilt: Fehlt eine Spalte ``date``, wird die erste Spalte der Klasse Date bzw. POSIXct als Datum
        verwendet, sonst die erste Spalte (eine numerische erste Spalte, etwa Zeilennummern ``X`` aus
        ``utils::write.csv()``, wird als Datum abgelehnt; eine Spalte ``X`` mit den Zeilennummern 1, 2, ... wird
        neben weiteren Wertspalten mit Hinweis ignoriert). Zeichenketten müssen das Format ``"JJJJ-MM-TT"`` haben;
        andere Formate wie ``"31.12.2024"`` vorher mit dem Argument ``format`` von ``as.Date()`` umwandeln, siehe
        Beispiel (nicht lesbare Daten und Texte ohne vierstellige Jahreszahl am Anfang sind ein Fehler).
        POSIXct-Zeitstempel zählen mit dem Kalendertag in ihrer eigenen Zeitzone. Übernommen werden nur numerische
        Spalten; andere Text-Spalten fallen weg, Text- oder Faktorspalten, die wie Zahlen aussehen (etwa Kurse mit
        Dezimalkomma, als Text eingelesen), sind ein Fehler. Zeilen ohne Datum werden entfernt, die Zeilen nach
        Datum sortiert, bei doppeltem Datum gilt der letzte Wert (mit Hinweis).

    Hinweise (Python):
        Führt Kursreihen aus verschiedenen Quellen auf einen gemeinsamen Kalender
        zusammen und liefert einen ``DataFrame`` mit Spalte ``date`` und je einer
        numerischen Spalte pro Reihe. Erwartet werden Niveaus (Kurse,
        Indexstände), keine Renditen: Lücken werden mit dem letzten Kurs (LOCF)
        oder linear gefüllt.

    Beispiel::

        import pandas as pd, simlev
        a = pd.DataFrame({"date": pd.to_datetime(["2024-01-01", "2024-01-02", "2024-01-03", "2024-01-06"]),
                          "value": [100, 101, 102, 103]})
        b = pd.DataFrame({"date": pd.date_range("2024-01-02", periods=6), "value": [50, 51, 52, 53, 54, 55]})
        print(simlev.series_align(us=a, eu=b))
    """
    C = _chk()
    fn = "series_align"
    calendar = _e5_choice(calendar, ("day", "union", "intersect"), fn, "calendar")
    rng = _e5_choice(range, ("common", "all"), fn, "range")
    fill = _e5_choice(fill, ("locf", "linear", "none"), fn, "fill")
    # seit 1.6.4 (K42 E5): max_gap Zahl >= 0 oder Inf, start/end Datum (keine Zahl, Entscheidung 7)
    max_gap = C.chk_scalar(max_gap)
    if C.chk_is_factor(max_gap) or not (isinstance(max_gap, (int, float, np.integer, np.floating)) and
                                       not isinstance(max_gap, (bool, np.bool_)) and not math.isnan(float(max_gap))
                                       and float(max_gap) >= 0):
        C.chk_stop("e5.max_gap", fn)
    start = C.chk_date1(start, fn, "start", null_ok=True)
    end = C.chk_date1(end, fn, "end", null_ok=True)
    if args or not sources or any(k == "" for k in sources):
        raise ValueError("series_align: Quellen benennen, z. B. series_align(us = df1, eu = df2).")
    fr = [(nm,) + _dp_frame(src, nm, fn) for nm, src in sources.items()]
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
        _chk().chk_stop("a.m_series_align")
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
        mi = in_life = None                                    # seit 1.6.4 einmal je Quelle (B-110)
        for k, vals in fc.items():
            if k in out:
                _chk().chk_stop("a.m_series_align_2", k)
            if mi is None:
                mi = _match_days(dates, fd)
                in_life = (dates >= fd[0]) & (dates <= fd[-1])
            v = np.where(mi >= 0, vals[np.maximum(mi, 0)] if len(vals) else _NAN, _NAN).astype(np.float64)
            obs = ~np.isnan(v)
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
        C = _chk()
        max_issues = int(C.chk_int1(max_issues, "print", "max_issues", lo=0))   # seit 1.6.5 (CR2-W1-2)
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

    Erstellt einen Prüfbericht für eigene Kursreihen, bevor sie in ``simulation()`` oder die Analysefunktionen
    gehen. Erwartet wird ein DataFrame mit Spalte ``date`` und Kursspalten (Niveaus, keine Renditen), z. B. aus
    ``series_align()``. Gemeldet werden: fehlende oder nicht lesbare Daten (z. B. Leerzeile am Dateiende),
    doppelte oder unsortierte Daten, Kalenderlücken (seit 1.6.5 über max(5, 1,5 × Median der Datumsabstände)
    Tage, also bei Tagesdaten über 5, bei Wochendaten über 10,5, bei Monatsdaten über rund 46 Tage), fehlende
    Werte innerhalb der Laufzeit, Sprünge,
    wahrscheinliche Splits (Sprung nahe einem ganzzahligen Verhältnis 2:1 bis 10:1 bzw. 1:2 bis 1:10, ohne
    Rücklauf), Spikes (Sprung mit sofortigem Rücklauf, typischer Datenfehler), Werte <= 0 und stehende Kurse. Die
    Funktion ändert die Daten nicht.

    Args:
        data: DataFrame mit Spalte ``date`` (Date oder ``"JJJJ-MM-TT"``) und Kursspalten.
        columns: Zeichenvektor der zu prüfenden Spalten (Standard ``None`` = alle numerischen Spalten außer
            ``date``).
            Seit 1.6.4 müssen die Spalten vorhanden und numerisch sein und dürfen nicht doppelt vorkommen.
        jump: Sprungschwelle in Prozent (20 = 20 %): Veränderung zum vorigen vorhandenen Wert, ab der ein Sprung
            gemeldet wird.
        stale: Mindestlänge in Zeilen einer Folge unveränderter Werte, die als stehender Kurs gemeldet wird (bei
            Kalendertagsdaten sind 2-4 Zeilen über Wochenenden und Feiertage normal).
        revert: Rücklauf am Folgetag als Anteil des Sprungs (0.8 = 80 %, gemessen in Log-Renditen), ab dem ein
            Sprung als Spike gilt.

    Returns:
        Objekt der Klasse ``SimLevDataCheck``, eine Liste mit

        - summary: DataFrame je Spalte: ``column``, ``start``, ``end`` (erstes/letztes Datum mit Wert), ``n``
          (Werte), ``missing`` (NA innerhalb der Laufzeit), ``jumps`` (alle Sprünge über ``jump``, einschließlich
          Spikes und Splits), ``spikes``, ``splits``, ``stale_max`` (längste Folge gleicher Werte in Zeilen),
          ``nonpositive`` (Anzahl Werte <= 0).
        - issues: DataFrame je Fund: ``column``, ``date``, ``type`` (Art des Funds), ``value`` (Kurs) und ``info``
          (bei Sprüngen die Veränderung in Prozent, bei Kalenderlücken die Tage, bei stehenden Kursen die Zeilen).
        - settings: benannter Vektor ``jump``, ``stale``, ``revert`` und (seit 1.6.5) ``gap`` (verwendete Schwelle der
          Kalenderlücke in Tagen).

        ``print()`` zeigt die Zusammenfassung und die ersten ``max_issues`` (Standard 25) Funde.

    Details:
        Sprünge werden zwischen aufeinanderfolgenden vorhandenen Werten (NA übersprungen) gemessen, also je Zeile,
        nicht je Kalendertag, und nur zwischen zwei positiven Werten; Werte <= 0 (z. B. eine Zinsreihe mit
        negativen Sätzen) erscheinen nur als "Wert <= 0".

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 400
        d = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=n)})
        d["A"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        d.loc[299:, "A"] /= 2               # Split 2:1
        print(simlev.series_check(d)["summary"])
    """
    C = _chk()
    fn = "series_check"
    # seit 1.6.4 (K42 E5): Tabelle mit Spalte date (keine Kategorie), Spalten vorhanden, numerisch, ohne Doppel
    # (B-046, B-052), Schwellen als Zahlen
    C.chk_df(data, fn, "data")
    C.chk_cols(data, ["date"], fn)
    C.chk_col_nofactor(data, "date", fn)
    if columns is not None and (isinstance(columns, str) or len(columns)):   # leer: keine Spalten (wie bisher)
        columns = _e5_names(columns, fn, "columns")
        if len(set(columns)) != len(columns):   # Entscheidung 53 (B-052)
            C.chk_stop("e1.doppelt", fn, "columns")
        C.chk_cols(data, columns, fn)
        _e5_numcols(data, columns, fn)
    jump = C.chk_num1(jump, fn, "jump", lo=0)
    stale = C.chk_int1(stale, fn, "stale", lo=1)
    revert = C.chk_num1(revert, fn, "revert", lo=0)
    data = _as_frame(data)
    d = _days(_to_date(_col(data, "date"), "series_check: date", strict=False))
    if columns is None:
        columns = [k for k in _names(data) if _is_numeric_col(_col(data, k)) and k != "date"]
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
    # seit 1.6.5 (CR2-B-6, Entscheidung 185 K24): Kalenderlücke, wenn der Abstand größer ist als
    # max(5, 1.5 * Median der positiven Abstände) Tage (Tagesdaten 5 wie bisher, Wochen 10.5, Monate rund 46)
    dpos = dg[~np.isnan(dg) & (dg > 0)]
    gap = max(5.0, 1.5 * float(r_median(dpos))) if len(dpos) else 5.0
    for i in np.flatnonzero(dg > gap):
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
        with np.errstate(all="ignore"):   # seit 1.6.5 (CR2-B-10) auch Überlauf ohne numpy-Warnung
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
            with np.errstate(all="ignore"):
                ratio = float(x[j] / x[j + 1])
            near = cand[_which_min([abs(_libm.log(ratio / c)) for c in cand], -1)]
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
        sk = set(skip)   # einmal statt je Element (seit 1.6.3)
        jumps = len([j for j in J if j not in sk])
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
    res["settings"] = pd.Series([float(jump), float(stale), float(revert), gap], index=["jump", "stale", "revert", "gap"])
    return res


# ═══════════════════════════════════════════════════════════════════════════
# series_align_macro
# ═══════════════════════════════════════════════════════════════════════════

def _find_interval_int(x, vec) -> np.ndarray:
    """``findInterval(x, vec)`` (vec aufsteigend): Anzahl vec <= x als int64, ohne NA-Sonderfall (tactical)."""
    return np.searchsorted(np.asarray(vec, dtype=np.float64), np.asarray(x, dtype=np.float64), side="right")


def _find_interval(x, vec) -> np.ndarray:
    """``findInterval(x, vec)`` (vec aufsteigend); NA -> nan, sonst float-Index (0 = davor)."""
    x = np.asarray(x, dtype=np.float64)
    j = _find_interval_int(x, vec).astype(np.float64)
    j[np.isnan(x)] = _NAN
    return j


def series_align_macro(data, macro, *, name="macro", lag=0, lag_unit=("day", "month"),
                transform=("level", "yoy", "mom", "diff", "yoy_diff"), periods=None):
    """Makroreihen mit Veröffentlichungsverzug auf den Tageskalender legen.

    Ordnet niederfrequente Reihen (Inflation, Leitzins, Zinsstruktur, Arbeitslosigkeit, ...) einem Tageskalender
    zu, und zwar so, wie sie zum jeweiligen Tag bekannt waren: Ein Wert für den Referenzmonat Januar, der Mitte
    Februar veröffentlicht wird, gilt erst ab Mitte Februar. Ohne diesen Verzug enthalten bedingte Analysen und
    Signale Informationen aus der Zukunft.

    Args:
        data: Datumsvektor oder DataFrame mit Spalte ``date`` (z. B. aus ``series_align()``).
        macro: ``data.frame(date, value)`` (es zählt die erste numerische Spalte; fehlt ``date``, gilt die erste
            Spalte als Datum) oder benannter numerischer Vektor mit Datumsnamen. ``date`` ist der
            Referenzzeitpunkt (z. B. Monatsanfang des Referenzmonats).
        name: Name der neuen Spalte, wenn ``data`` ein DataFrame ist (Standard ``"macro"``); seit 1.6.4 darf es
            keine Spalte von ``data`` sein.
        lag: Veröffentlichungsverzug als Zahl in Einheiten von ``lag_unit`` (Standard 0 = ab dem Referenzdatum
            bekannt).
            Seit 1.6.4 ganze Zahl >= 0 (kein Blick in die Zukunft), höchstens 36600 Tage bzw. 1200 Monate.
        lag_unit: Einheit von ``lag``: ``"day"`` (Standard; Kalendertage) oder ``"month"`` (Kalendermonate; der
            Tag wird auf das Monatsende begrenzt, z. B. 31.01. + 1 Monat = 29.02. bzw. 28.02.).
        transform: ``"level"`` (Standard; Wert unverändert), ``"yoy"`` (Veränderung gegen Vorjahr in Prozent, 2 =
            2 %), ``"mom"`` (gegen Vorperiode in Prozent), ``"diff"`` (absolute Differenz zur Vorperiode, z. B.
            Zinsänderung in Prozentpunkten) oder ``"yoy_diff"`` (absolute Differenz zum Vorjahr).
        periods: Perioden je Jahr der Makroreihe, bestimmt den Abstand für ``"yoy"`` und ``"yoy_diff"``. Standard
            ``None`` = aus dem mittleren Datumsabstand geschätzt (1, 4, 12, 52 oder 252, z. B. 12 für
            Monatsdaten). Bei 1, 4 und 12 wird der Bezugswert per Datum gesucht (Vorjahr bzw. Vormonat/-quartal
            desselben Kalenders; fehlt er, etwa bei einem fehlenden Monat, ist das Ergebnis NA), sonst per Zeile
            (``periods`` bzw. eine Zeile zurück).
            Seit 1.6.4 ganze Zahl >= 1; ohne Angabe braucht macro mindestens zwei Werte.

    Returns:
        Bei Datumsvektor ein numerischer Vektor gleicher Länge, sonst ``data`` mit neuer Spalte ``name`` (NA vor
        dem ersten bekannten Wert).

    Details:
        Ein Wert gilt ab ``Referenzdatum + lag`` bis zum nächsten verfügbaren Wert (Stufenfunktion); davor ist das
        Ergebnis NA. Die Umrechnung (``transform``) erfolgt auf der Makroreihe selbst, vor der Zuordnung. Das
        Ergebnis eignet sich z. B. für Bedingungen in ``tactical_rules()`` (``"inflation > 3"``) oder als
        Preisindex für ``series_deflate()``.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        cpi = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=36, freq="MS"), "value": 100 * 1.002 ** np.arange(36)})
        d = pd.DataFrame({"date": pd.date_range("2021-01-01", periods=400)})
        d = simlev.series_align_macro(d, cpi, name="inflation", lag=45, transform="yoy")
        print(d.dropna().head(3))
    """
    C = _chk()
    fn = "series_align_macro"
    lag_unit = _e5_choice(lag_unit, ("day", "month"), fn, "lag_unit")
    transform = _e5_choice(transform, ("level", "yoy", "mom", "diff", "yoy_diff"), fn, "transform")
    # seit 1.6.4 (K42 E5): data Tabelle mit Datum oder Datumsvektor, name, lag ganze Zahl >= 0 (kein Vorausblick,
    # B-025; höchstens 36600 Tage bzw. 1200 Monate, Entscheidung 46), periods ganze Zahl >= 1
    if isinstance(data, pd.DataFrame):
        C.chk_cols(data, ["date"], fn)
        C.chk_col_nofactor(data, "date", fn)
        name = C.chk_name1(name, fn, "name")
        if name in [str(c) for c in data.columns]:   # Entscheidung 58
            C.chk_stop("spalte_vorhanden", fn, name, "data", "name")
    else:
        C.chk_nofactor(data, fn, "data")
    lag = C.chk_int1(lag, fn, "lag", lo=0)
    C.chk_max(lag, 36600 if lag_unit == "day" else 1200, fn, "lag")
    periods = C.chk_int1(periods, fn, "periods", lo=1, null_ok=True)
    md, mc = _dp_frame(macro, "macro", fn)
    if periods is None and len(md) < 2:
        C.chk_stop("e5.makro_kurz", fn)
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

    Rechnet Kursspalten eines DataFrames tageweise mit einem Wechselkurs in eine andere Währung um, z. B. einen
    US-Index in USD nach EUR, bevor er in ``simulation()`` geht. Erwartet wird ein DataFrame mit Spalte ``date``
    und Kursniveaus (z. B. aus ``series_align()``). Je Zeile wird der Kurs durch den Wechselkurs geteilt
    (``"divide"``) oder mit ihm multipliziert (``"multiply"``); eine Kurssicherung wird nicht abgebildet.

    Seit 1.6.5 ergibt eine Stufentabelle als ``fx``, die erst nach dem ersten Datentag beginnt, eine Warnung
    (davor gilt ihr erster Wert).

    Args:
        data: DataFrame mit Spalte ``date`` und den Kursspalten.
        columns: Zeichenvektor der umzurechnenden Spalten.
        fx: Wechselkurs als Niveau: Spaltenname in ``data`` (NA per LOCF gefüllt), ``data.frame(date, value)``
            (Stufenfunktion: Wert gilt ab seinem Datum bis zum nächsten; vor dem ersten Datum gilt der erste
            Wert), benannter Vektor mit Datumsnamen, Vektor der Länge ``nrow(data)`` oder Skalar (fester Kurs).
            Alle Werte müssen positiv sein.
        method: ``"divide"`` (Standard; Wechselkurs als Fremdwährung je Zielwährung, z. B. USD-Index mit EURUSD =
            USD je EUR in EUR umrechnen) oder ``"multiply"`` (Wechselkurs als Zielwährung je Fremdwährung).
        suffix: Endung für neue Spalten (z. B. ``"_eur"``); Standard ``None`` = die Spalten in ``columns`` werden
            überschrieben.

    Returns:
        ``data`` mit umgerechneten (bzw. zusätzlichen) Spalten.

    Beispiel::

        import pandas as pd, simlev
        d = pd.DataFrame({"date": pd.date_range("2024-01-01", periods=5), "sp500_usd": [4700, 4710, 4690, 4720, 4730],
                          "eurusd": [1.10, 1.11, 1.10, 1.09, 1.10]})
        print(simlev.series_convert_currency(d, "sp500_usd", "eurusd", suffix="_eur"))
    """
    from .backcast import _resolve_series
    C = _chk()
    fn = "series_convert_currency"
    method = _e5_choice(method, ("divide", "multiply"), fn, "method")
    # seit 1.6.4 (K42 E5): Tabelle, Spaltennamen, Zahlenspalten, fx keine Kategorie, suffix Text
    C.chk_df(data, fn, "data")
    columns = _e5_names(columns, fn, "columns")
    suffix = C.chk_text1(suffix, fn, "suffix", null_ok=True)
    data = _as_frame(data)
    nms = _names(data)
    miss = []
    for c in columns:
        if c not in nms and c not in miss:
            miss.append(c)
    if miss:
        _chk().chk_stop("a.m_series_convert_currency", ", ".join("'%s'" % m for m in miss), ", ".join(nms))
    _e5_numcols(data, columns, fn)
    C.chk_nofactor(fx, fn, "fx")
    fx = C.chk_scalar(fx) if isinstance(fx, (list, tuple)) and len(fx) == 1 and isinstance(fx[0], str) else fx
    if isinstance(fx, str) and fx in nms:
        _e5_numcols(data, [fx], fn)
    from .bonds import _step_start_warn
    _step_start_warn(fx, data, fn, "fx")   # seit 1.6.5 (CR2-V3-4 Punkt 4, Entscheidung 189)
    f = _resolve_series(fx, data, "fx")
    with np.errstate(invalid="ignore"):
        bad = np.flatnonzero(~np.isfinite(f) | (f <= 0))
    if len(bad):
        raise ValueError("series_convert_currency: Wechselkurs fx muss positiv sein; %d Zeilen ung\u00fcltig (erstmals Zeile %d)."
                         % (len(bad), bad[0] + 1))
    data = data.copy()
    for k in columns:
        nm = k if suffix is None else k + suffix
        x = _as_numeric(_col(data, k))
        data[nm] = x / f if method == "divide" else x * f
    return data


def index_total_return(price, *, dividends=None, yield_=None, withholding=0, dates=None, start=None, **kw):
    """Total-Return-Index aus Kursindex und Ausschüttungen.

    r_t = (P_t + D_t (1 - w)) / P_{t-1} - 1 + y_t/100 · (1 - w) · Δt/365.25 mit Ausschüttung je Anteil D_t am
    Ex-Tag, Quellensteuer w und alternativ laufend aufgezinster Dividendenrendite y_t (Prozent p. a.). Δ t ist der
    Abstand zur Vorzeile in Kalendertagen.

    Args:
        price: Kursreihe als numerischer Vektor (Niveaus); NA werden per LOCF gefüllt.
        dividends: Ausschüttung je Anteil in Währungseinheiten am Ex-Tag (numerischer Vektor gleicher Länge, 0
            oder NA an Tagen ohne Ausschüttung). Standard ``None`` = keine.
            Seit 1.6.4 ein Fehler bei anderer Länge.
        yield_: ``yield`` (in Python ``yield_``, da ``yield`` ein Schlüsselwort ist): Dividendenrendite in Prozent
            p. a. (2 = 2 %; Skalar oder Vektor gleicher Länge), anteilig je Zeile aufgezinst. Standard ``None`` =
            keine.
            Seit 1.6.4 endlich, Länge 1 oder wie price.
        withholding: Quellensteuer in Prozent (15 = 15 %), mindert ``dividends`` und ``yield``. Standard 0.
        dates: Datumsvektor gleicher Länge für Δ t, aufsteigend sortiert wie ``price`` (sonst Fehler); Standard
            ``None`` = 1 Tag je Zeile (nur für ``yield`` von Bedeutung).
        start: Startwert des Index (Standard ``None`` = erster Kurs).
        **kw: nur ``yield`` (``**{"yield": …}``) als Schreibweise für ``yield_`` (``yield`` ist in Python ein
            Schlüsselwort); andere Namen sind ein Fehler.

    Returns:
        Numerischer Indexvektor gleicher Länge wie ``price``.

    Details:
        Wandelt einen Kursindex (Preisindex ohne Ausschüttungen) in einen Total-Return-Index um (Ausschüttungen
        nach Quellensteuer reinvestiert). Arbeitet auf Vektoren; das Ergebnis kann direkt als neue Kursspalte in
        den DataFrame für ``simulation()`` geschrieben werden. Werden ``dividends`` und ``yield`` zugleich
        angegeben, wirken beide.

    Beispiel::

        import simlev
        p = [100, 101, 99, 100, 102, 103]
        div = [0, 0, 0, 2, 0, 0]             # 2 je Anteil am Ex-Tag (Zeile 4)
        print(simlev.index_total_return(p, dividends=div, withholding=15))
    """
    from .backcast import _fill_na
    if "yield" in kw:
        yield_ = kw.pop("yield")
    if kw:
        raise TypeError("unused argument(s): %s" % ", ".join(kw))
    C = _chk()
    fn = "index_total_return"
    # seit 1.6.4 (K42 E5): Zahlenvektoren (keine Kategorie, B-009), dividends gleich lang wie price (B-023), yield
    # ein Wert oder je Zeile und endlich, withholding 0 bis 100, start Zahl > 0
    C.chk_nofactor(price, fn, "price")
    price = _e5_numvec(price, fn, "price")
    if np.ndim(price) > 1 or isinstance(price, pd.DataFrame):
        C.chk_stop("zahlen", fn, "price")
    np_ = 1 if np.ndim(price) == 0 else len(price)
    if dividends is not None:
        C.chk_nofactor(dividends, fn, "dividends")
        dividends = _e5_numvec(dividends, fn, "dividends")
        if (1 if np.ndim(dividends) == 0 else len(dividends)) != np_:
            C.chk_stop("laenge", fn, "dividends", C.chk_fmt(np_))
    if yield_ is not None:
        C.chk_nofactor(yield_, fn, "yield")
        yield_ = _e5_numvec(yield_, fn, "yield")
        yv = np.asarray(_as_numeric(np.atleast_1d(yield_)), dtype=np.float64)
        if not np.isfinite(yv).all():
            C.chk_stop("e2.zahlen_endlich", fn, "yield")
        if yv.size != 1 and yv.size != np_:
            C.chk_stop("laenge", fn, "yield", C.chk_fmt(np_))
    withholding = C.chk_num1(withholding, fn, "withholding", lo=0, hi=100)
    start = C.chk_num1(start, fn, "start", lo=0, lo_open=True, null_ok=True)
    if dates is not None:
        C.chk_nofactor(dates, fn, "dates")
    p = _as_numeric(price)
    n = len(p)
    w = withholding / 100
    if np.isnan(p).any():
        p = _fill_na(p, "locf")
    # seit 1.6.5 (CR2-I-4, Entscheidung 189): Kurse endlich und > 0 (bis 1.6.4 still NaN, mit numpy-Rohwarnung)
    with np.errstate(invalid="ignore"):
        bad = np.flatnonzero(~np.isnan(p) & (np.isinf(p) | (p <= 0)))
    if bad.size:
        C.chk_stop("a.werte_positiv", fn, "price", int(bad[0]) + 1)
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
            _chk().chk_stop("a.m_index_total_return")
        dt = np.concatenate([[0.0], np.diff(dd)])
    else:
        dt = np.ones(n)
    r = np.concatenate([[0.0], (p[1:] + D[1:] * (1 - w)) / p[:-1] - 1 + y[1:] / 100 * (1 - w) * dt[1:] / 365.25])
    s = p[0] if start is None else start
    return s * r_cumprod(1 + r)


def _cpi_level(cpi, data, dts, what):
    """Preisindex-Niveau je Zeile; vor dem ersten bekannten Wert NA (R: ``.cpi_level``).

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
            _chk().chk_stop("a.m_cpi_level", what, cpi)
        v0 = _as_numeric(_col(data, cpi))
        ok = np.flatnonzero(~np.isnan(np.asarray(v0, dtype=np.float64)))
        _cpi_end_warn(float(dts_days[ok[-1]]) if ok.size else None, dts_days, what)
        return _fill_na(v0, "locf", keep_leading=True)
    cpi = _as_frame(cpi)
    first = last = None
    if isinstance(cpi, pd.DataFrame):
        nm = _names(cpi)
        dcol = "date" if "date" in nm else nm[0]
        fd = _days(_to_date(_col(cpi, dcol), "%s: Datum" % what))
        fd = fd[~np.isnan(fd)]
        first = float(np.min(fd)) if len(fd) else math.inf
        last = float(np.max(fd)) if len(fd) else None
    elif _is_named_numeric(cpi):
        names, _ = _named_parts(cpi)
        nd = _names_as_dates_optional(names)
        if not np.isnan(nd).any():
            first = float(np.min(nd))
            last = float(np.max(nd))
    v = _resolve_series(cpi, pd.DataFrame({"date": _as_dates(dts_days)}), what)
    if first is not None:
        v = np.array(v, dtype=np.float64)
        v[dts_days < first] = _NAN
    _cpi_end_warn(last, dts_days, what)
    return v


def _cpi_end_warn(last, dts_days, what):
    """Preisindex endet mehr als 92 Tage vor dem letzten Datum der Reihe: Warnung (seit 1.6.5, CR2-X5-1, Entscheidung
    189; R ``.cpi_end_warn``); danach gilt sein letzter Stand."""
    d = np.asarray(dts_days, dtype=np.float64)
    if last is None or d.size == 0 or np.isnan(d).all():
        return
    d1 = float(np.nanmax(d))
    gap = d1 - float(last)
    if math.isfinite(gap) and gap > 92:
        import warnings
        from ._dates import fmt_date
        warnings.warn(_chk().chk_msg("e.preisindex_ende", what, fmt_date(int(last)), "%.0f" % gap, fmt_date(int(d1))),
                      UserWarning, stacklevel=3)


def series_deflate(data, columns, cpi, *, base_date=None, suffix="_real"):
    """Reale Werte über einen Preisindex: real_t = nominal_t * cpi_b / cpi_t.

    Rechnet nominale Kurs- oder Wertspalten in reale Werte (Kaufkraft des Bezugsdatums) um: real_t = nominal_t ·
    cpi_b / cpi_t mit der Bezugszeile b. Erwartet wird ein DataFrame mit Spalte ``date`` und einem Preisindex als
    Niveau (z. B. Verbraucherpreisindex), keine Inflationsrate. Die realen Spalten kommen als neue Spalten hinzu
    und können wie Kursspalten in ``simulation()`` oder ``result_analysis()`` verwendet werden; für die reale
    Auswertung fertiger Ergebnisse hat ``result_analysis()`` ein eigenes Argument ``inflation``.

    Seit 1.6.5 muss der Preisindex endliche Werte > 0 haben und ``suffix`` darf nicht leer sein (sonst Fehler).

    Args:
        data: DataFrame mit Spalte ``date`` und den Spalten aus ``columns``.
        columns: Zeichenvektor der Spalten, die deflationiert werden.
        cpi: Preisindex-Niveau: Spaltenname in ``data`` (NA per LOCF gefüllt; z. B. mit ``series_align_macro()``
            und Veröffentlichungsverzug vorbereitet), ``data.frame(date, value)`` (Stufenfunktion: Wert gilt ab
            seinem Datum), benannter Vektor mit Datumsnamen oder Vektor der Länge ``nrow(data)``. Vor dem ersten
            bekannten Wert wird nicht zurückgefüllt: Die realen Werte dieser Zeilen sind NA (mit Hinweis).
        base_date: Bezugsdatum, an dem real = nominal (Date oder ``"JJJJ-MM-TT"``; verwendet wird die Zeile mit
            dem nächstgelegenen Datum; dort muss der Preisindex bekannt sein). Standard ``None`` = erste Zeile mit
            bekanntem Preisindex.
        suffix: Endung für die neuen Spalten (Standard ``"_real"``).

    Returns:
        ``data`` mit zusätzlichen realen Spalten ``paste0(columns, suffix)``.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        cpi = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=36, freq="MS"), "value": 100 * 1.003 ** np.arange(36)})
        d = pd.DataFrame({"date": pd.date_range("2021-01-01", periods=400), "depot": 10000 * 1.0002 ** np.arange(400)})
        d = simlev.series_align_macro(d, cpi, name="cpi", lag=1, lag_unit="month")
        print(simlev.series_deflate(d, "depot", "cpi").tail(3))
    """
    C = _chk()
    fn = "series_deflate"
    # seit 1.6.4 (K42 E5): Tabelle mit date, Spalten vorhanden und numerisch (B-046), cpi keine Kategorie,
    # base_date Datum, suffix Text
    C.chk_df(data, fn, "data")
    C.chk_cols(data, ["date"], fn)
    C.chk_col_nofactor(data, "date", fn)
    columns = _e5_names(columns, fn, "columns")
    C.chk_cols(data, columns, fn)
    _e5_numcols(data, columns, fn)
    C.chk_nofactor(cpi, fn, "cpi")
    if isinstance(cpi, str) and cpi in _names(data):
        _e5_numcols(data, [cpi], fn)
    base_date = C.chk_date1(base_date, fn, "base_date", null_ok=True)
    suffix = C.chk_text1(suffix, fn, "suffix")
    if suffix == "":   # seit 1.6.5 (CR2-V1-4; bis 1.6.4 überschrieb "" die Spalten)
        C.chk_stop("name", fn, "suffix")
    data = _as_frame(data)
    dts = _days(_to_date(_col(data, "date"), "series_deflate: data$date"))
    c0 = _cpi_level(cpi, data, dts, "cpi")
    # seit 1.6.5 (CR2-V1-4): Preisindex endlich und > 0 (bis 1.6.4 Inf mit numpy-Rohwarnung bzw. falsches Vorzeichen)
    with np.errstate(invalid="ignore"):
        bad = np.flatnonzero(~np.isnan(c0) & (np.isinf(c0) | (c0 <= 0)))
    if bad.size:
        C.chk_stop("a.werte_positiv", fn, "cpi", int(bad[0]) + 1)
    known = np.flatnonzero(~np.isnan(c0))
    if not len(known):
        _chk().chk_stop("a.m_series_deflate")
    if known[0] > 0:
        message("Hinweis: series_deflate: Preisindex erst ab %s bekannt; %d Zeilen davor bleiben NA."
                % (_date_str(dts[known[0]]), known[0]))
    if base_date is None:
        b = known[0]
    else:
        bd = _days(_to_date(base_date, "base_date"))
        b = _which_min(list(np.abs(dts - bd[0])), -1)
    if math.isnan(c0[b]):
        _chk().chk_stop("a.m_series_deflate_2", _date_str(dts[b]), _date_str(dts[known[0]]))
    data = data.copy()
    for k in columns:
        data[k + suffix] = _as_numeric(_col(data, k)) / c0 * c0[b]
    return data


# ═══════════════════════════════════════════════════════════════════════════
# series_splice
# ═══════════════════════════════════════════════════════════════════════════

def series_splice(*args, dates=None, **series):
    """Reihen verketten (Proxy -> Index -> Fonds).

    Verbindet mehrere Reihen renditebasiert zu einer langen Historie. Die erste Reihe hat Vorrang: Wo sie
    vorliegt, wird sie unverändert übernommen. Davor (und in ihren Lücken) werden die Tagesrenditen der nächsten
    verfügbaren Reihe verkettet, usw. Typisch: Fonds, dann zurückgerechneter Fonds aus ``backcast()``, dann ein
    Proxy-Index.

    Args:
        *args: Mindestens zwei benannte Reihen in Prioritätsreihenfolge, entweder alle als numerische Vektoren
            gleicher Länge (z. B. Spalten eines gemeinsamen DataFrames; dann ``dates`` angeben) oder alle als
            ``data.frame(date, value)`` (sie werden mit ``series_align()`` und ``range = "all"`` auf Kalendertage
            gelegt und per LOCF gefüllt). Bei DataFrames gelten Folgen von mehr als 4 Kalendertagen (länger als
            ein langes Wochenende), an denen die erste Reihe nur gefüllt ist, während eine andere Reihe echte
            Kurse hat, als Lücken der ersten Reihe und werden mit den Renditen der nächsten Reihe verkettet.
            Kürzere Folgen (Wochenenden und Feiertage einer Handelstagsreihe, auch wenn die nächste Reihe
            Kalendertagswerte hat) und Tage ohne echte Kurse aller Reihen behalten den letzten Wert der ersten
            Reihe (LOCF); deren Bewegung in der nächsten Reihe geht am folgenden Handelstag der ersten Reihe ein.
        dates: Datumsvektor, wenn Vektoren übergeben werden (sonst ignoriert).
            Seit 1.6.4 müssen alle Vektoren so lang wie dates sein.
        **series: Mindestens zwei benannte Reihen in Prioritätsreihenfolge, entweder alle als numerische Vektoren
            gleicher Länge (z. B. Spalten eines gemeinsamen DataFrames; dann ``dates`` angeben) oder alle als
            ``data.frame(date, value)`` (sie werden mit ``series_align()`` und ``range = "all"`` auf Kalendertage
            gelegt und per LOCF gefüllt). Bei DataFrames gelten Folgen von mehr als 4 Kalendertagen (länger als
            ein langes Wochenende), an denen die erste Reihe nur gefüllt ist, während eine andere Reihe echte
            Kurse hat, als Lücken der ersten Reihe und werden mit den Renditen der nächsten Reihe verkettet.
            Kürzere Folgen (Wochenenden und Feiertage einer Handelstagsreihe, auch wenn die nächste Reihe
            Kalendertagswerte hat) und Tage ohne echte Kurse aller Reihen behalten den letzten Wert der ersten
            Reihe (LOCF); deren Bewegung in der nächsten Reihe geht am folgenden Handelstag der ersten Reihe ein.

    Returns:
        DataFrame mit ``date``, ``value`` (verkettete Reihe) und ``source``: Name der Reihe, deren Wert (erste
        Reihe) bzw. Rendite vom Vortag auf diesen Tag verwendet wurde (NA, wo keine Rendite vorliegt, z. B. in der
        ersten Zeile).

    Details:
        Alle Reihen müssen Niveaus (Kurse, Indexstände) sein, keine Renditen; das Niveau der Kette richtet sich
        nach der ersten Reihe. Vor dem Start der ersten Reihe wird rückwärts verkettet, solange Renditen
        vorliegen. Das Ergebnis lässt sich als Kursspalte in ``simulation()`` oder als ``data.frame(date, value)``
        in ``result_analysis()`` verwenden.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        proxy = pd.DataFrame({"date": pd.date_range("2010-01-01", periods=1500), "value": 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, 1500))})
        fonds = proxy[proxy["date"] >= "2012-01-01"].copy(); fonds["value"] *= 0.5
        lang = simlev.series_splice(fonds=fonds, proxy=proxy)
        print(lang["source"].value_counts())
    """
    src = series
    if args or len(src) < 2:
        raise ValueError("series_splice: mindestens zwei benannte Reihen.")
    names = list(src.keys())
    C = _chk()
    fn = "series_splice"
    # seit 1.6.4 (K42 E5): Vektoren numerisch und gleich lang wie dates (B-047)
    if not all(isinstance(_as_frame(v), pd.DataFrame) for v in src.values()):
        if dates is None:
            _chk().chk_stop("a.m_series_splice")
        C.chk_nofactor(dates, fn, "dates")
        nd = 1 if isinstance(dates, str) or np.ndim(dates) == 0 else len(dates)
        for k, v in src.items():
            C.chk_nofactor(v, fn, k)
            v = src[k] = _e5_numvec(v, fn, k)
            if isinstance(v, pd.DataFrame) or np.ndim(v) > 1:
                C.chk_stop("zahlen", fn, k)
            if (1 if np.ndim(v) == 0 else len(v)) != nd:
                C.chk_stop("laenge", fn, k, C.chk_fmt(nd))
    Fl = None
    # seit 1.6.5 (CR2-C-5): je Reihe mindestens eine Zeile
    if all(isinstance(_as_frame(v), pd.DataFrame) for v in src.values()):
        for k, v in src.items():
            if _as_frame(v).shape[0] == 0:
                C.chk_stop("zeilen_keine", fn, "'%s'" % k)
    elif nd == 0:
        C.chk_stop("zeilen_keine", fn, "dates")
    if all(isinstance(_as_frame(v), pd.DataFrame) for v in src.values()):
        al = series_align(**{k: _as_frame(v) for k, v in src.items()}, range="all")
        # Quelle mit mehreren Wertspalten (seit 1.6.4 Meldung wie R und Julia, T3-N7; bis 1.6.3 KeyError)
        for k in names:
            if k not in [str(c) for c in al.columns]:
                C.chk_stop("ut3.splice_spalte", fn, k)
        dts = _days(al["date"].to_numpy())
        V = np.column_stack([al[k].to_numpy(dtype=np.float64) for k in names])
        Fl = np.column_stack([al.attrs["filled"][k].to_numpy(dtype=bool) for k in names])
    else:
        if dates is None:
            _chk().chk_stop("a.m_series_splice")
        V = np.column_stack([_as_numeric(v) for v in src.values()])
        dts = None
    n = V.shape[0]
    # seit 1.6.5 (CR2-C-5): Werte endlich und > 0 oder NA (bis 1.6.4 ungeprüft verkettet)
    for j in range(V.shape[1]):
        with np.errstate(invalid="ignore"):
            bad = np.flatnonzero(~np.isnan(V[:, j]) & (np.isinf(V[:, j]) | (V[:, j] <= 0)))
        if bad.size:
            dd = dts if dts is not None else _days(_to_date(dates, "series_splice: dates"))
            C.chk_stop("a.werte_positiv_datum", fn, "'%s'" % names[j], fmt_date(int(dd[int(bad[0])])))
    with np.errstate(invalid="ignore", divide="ignore"):
        Rm = np.vstack([np.full((1, V.shape[1]), _NAN), V[1:, :] / V[:-1, :] - 1]) if n else V.copy()
    p = V[:, 0].copy()
    if Fl is not None:
        other = ((~np.isnan(V[:, 1:])) & ~Fl[:, 1:]).sum(axis=1) > 0
        run = np.cumsum(~Fl[:, 0])
        a1 = (other & Fl[:, 0]).astype(np.float64)
        a2 = Fl[:, 0].astype(np.float64)
        # Maximum und Summe je Gruppe (ave(..., run, max/sum)); seit 1.6.4 vektorisiert (B-083; Werte 0/1, also
        # dieselben Summen in jeder Reihenfolge)
        u, inv = np.unique(run, return_inverse=True)
        gm = np.full(len(u), -math.inf)
        np.maximum.at(gm, inv, a1)
        gs = np.bincount(inv, weights=a2, minlength=len(u))
        gap = Fl[:, 0] & (gm[inv] > 0) & (gs[inv] > 4)
        p[gap] = _NAN
        Rm[gap, 0] = _NAN
    fin = np.isfinite(Rm)
    has = fin.any(axis=1)
    pick = np.where(has, np.argmax(fin, axis=1), -1)
    r = np.where(has, Rm[np.arange(n), np.maximum(pick, 0)], _NAN)
    nz = np.flatnonzero(~np.isnan(p))
    if not len(nz):
        _chk().chk_stop("a.m_series_splice_2")
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

    Baut aus einem benannten Gewichtsvektor eine statische Strategie für ``simulation()``, ohne jedes Asset
    einzeln mit ``asset_config()`` anlegen zu müssen. Die Namen müssen den Kursspalten des Datensatzes entsprechen
    (z. B. aus ``series_align()``). Jedes Asset erhält ``share = Gewicht``; alle weiteren Einstellungen kommen aus
    ``...`` oder den Standardwerten von ``asset_config()`` (ETF, Buy and Hold, ohne Spread).

    Args:
        weights: Benannter numerischer Vektor Spaltenname -> Gewicht als Anteil (0.6 = 60 %), z. B. ``{"world":
            0.6, "bonds": 0.4}``. Alle Gewichte müssen positiv sein (Assets mit Gewicht 0 weglassen), die Namen
            eindeutig, und die Summe muss 1 sein (wie in ``simulation()``; sonst Fehler schon hier).
        **kwargs: Weitere Argumente für ``asset_config()`` (z. B. ``asset_class``, ``spread`` in Prozent,
            ``partial_exemption`` in Prozent). Ein unbenannter einzelner Wert gilt für alle Assets; benannte
            Vektoren werden je Asset zugeordnet, auch mit einem einzigen Element wie ``partial_exemption =
            {"aktien": 30}`` (fehlende Assets behalten den Standardwert). Seit 1.6.5 sind Namen, die kein Asset
            sind, und doppelte Namen ein Fehler (bis 1.6.4 still übergangen; ein einzelner benannter Wert mit
            fremdem Namen galt für alle Assets).
            Seit 1.6.4 ist ein unbekanntes Argument oder share (setzt die Funktion aus weights) ein Fehler mit
            einheitlicher Meldung.

            ``wrapper`` (Fonds-Wrapper, ``wrapper_config``) ist eine Ausnahme, weil ein ``SimLevWrapperConfig``
            selbst eine benannte Liste ist: Ein einzelnes ``SimLevWrapperConfig`` gilt für alle Assets; eine
            benannte Liste solcher Objekte (Name = Asset, z. B. ``wrapper = {"world": w}``) gilt je Asset, Assets
            ohne Eintrag bleiben ohne Wrapper. Fehler: Namen, die kein Asset sind, Elemente, die kein
            ``SimLevWrapperConfig`` sind, eine Liste ohne Namen, und ``wrapper`` zusammen mit ``trading =
            "signal"`` für dasselbe Asset (die Meldung nennt das Asset).

    Returns:
        Objekt der Klasse ``strategy`` (wie ``create_strategy()``).

    Beispiel::

        import simlev
        st = simlev.strategy_from_weights({"aktien": 0.7, "gold": 0.3}, asset_class={"aktien": "etf", "gold": "etc"},
                                          partial_exemption={"aktien": 30, "gold": 0})
        print({k: a["asset_class"] for k, a in st.items()})
    """
    from .config import _AC_MSG_WRAPPER_SIGNAL, asset_config, create_strategy
    nms, vals = _named(weights)
    if nms is None or any(k is None or k == "" for k in nms):
        _chk().chk_stop("a.m_strategy_from_weights")
    u = _dup_names(nms)
    if u:
        raise ValueError("weights: doppelte Namen %s; jedes Asset nur einmal angeben." % ", ".join("'%s'" % k for k in u))
    from ._pruefen import chk_numvec
    chk_numvec(vals, "strategy_from_weights", "weights")   # seit 1.6.4 (bis 1.6.3: Text als Zahl gelesen)
    w = np.array([_NAN if _isna_scalar(v) else float(v) for v in vals], dtype=np.float64)
    if np.isnan(w).any() or (w <= 0).any():
        _chk().chk_stop("a.m_strategy_from_weights_2")
    s = r_sum(w)
    # seit 1.6.5 (CR2-E-6, CR2-X3-1) mit 8 Stellen und R-Zahlform (bis 1.6.4 %.4f, unendlich als "inf")
    if abs(s - 1) > 1e-6:
        raise ValueError(r_sprintf("Gewichte summieren sich zu %.8g; simulation() verlangt die Summe 1 (Anteile, 0.6 = 60 %%).", s))

    # seit 1.6.4 (Entscheidung 21): Argumente für asset_config() vor dem Aufruf prüfen (bis 1.6.3 TypeError); share
    # setzt die Funktion selbst
    from ._pruefen import chk_dots
    chk_dots(list(kwargs), ("asset_class", "trading", "spread", "partial_exemption", "deliverable", "start", "tax_regime",
                            "signal_buy", "signal_sell", "wrapper"), "strategy_from_weights", taken=("share",))
    # Fonds-Wrapper: ein SimLevWrapperConfig gilt für alle Assets, ein dict je Asset
    wmap = {}
    if "wrapper" in kwargs:
        kwargs = dict(kwargs)
        wmap = _sfw_wrappers(kwargs.pop("wrapper"), nms)

    # Benannt -> je Asset (auch bei einem Element); unbenannt ein Wert für alle. Seit 1.6.5 (CR2-E-5, Entscheidung
    # 185 K30) sind Namen, die kein Asset sind, und doppelte Namen ein Fehler (bis 1.6.4 still übergangen; ein
    # einzelner benannter Wert mit fremdem Namen galt für alle)
    def per_asset(v):
        return _named(v)[0] is not None

    for key, v in kwargs.items():
        vn = _named(v)[0]
        if vn is None:
            continue
        vn = ["NA" if k is None else k for k in vn]
        dup = _dup_names(vn)
        if dup:
            C = _chk()
            C.chk_stop("a.sfw_doppelt", "strategy_from_weights", key, ", ".join("'%s'" % k for k in dup))
        unk = []
        for k in vn:
            if k not in nms and k not in unk:
                unk.append(k)
        if unk:
            C = _chk()
            C.chk_stop("a.sfw_fremd", "strategy_from_weights", key, ", ".join("'%s'" % k for k in unk), ", ".join(nms))

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
    """Argument ``wrapper`` von :func:`strategy_from_weights` je Asset (R: ``.sfw_wrappers``).

    ``None`` oder leer -> ohne Wrapper; ein ``SimLevWrapperConfig`` -> für alle Assets; ein ``dict`` (bzw.
    ``Series``) Asset -> ``SimLevWrapperConfig`` -> je Asset, Assets ohne Eintrag ohne Wrapper. Sonst Fehler
    (Reihenfolge: Art, Namen vorhanden, doppelte Namen, unbekannte Namen, Elemente). Ergebnis: ``dict``.
    """
    from .config import _is_wrapper
    if wv is None:
        return {}
    if _is_wrapper(wv):
        return {nm: wv for nm in assets}
    if isinstance(wv, pd.DataFrame) or not isinstance(wv, (Mapping, pd.Series, list, tuple)):
        _chk().chk_stop("a.m_sfw_wrappers_2")   # seit 1.6.4 ohne Klasse
    if len(wv) == 0:
        return {}
    nm, vals = _named(wv) if not isinstance(wv, (list, tuple)) else (None, list(wv))
    if nm is None or any(k is None or k == "" for k in nm):
        raise ValueError("wrapper: als Liste braucht jedes Element einen Namen (Name = Asset, z. B. "
                         "list(%s = wrapper_config(...)))." % assets[0])
    u = _dup_names(nm)
    if u:
        raise ValueError("wrapper: doppelte Namen %s; jedes Asset nur einmal angeben." % ", ".join("'%s'" % k for k in u))
    unk = [k for k in nm if k not in assets]
    if unk:
        raise ValueError("wrapper: %s %s (Assets: %s)." % (", ".join("'%s'" % k for k in unk),
                                                           "ist kein Asset der Strategie" if len(unk) == 1
                                                           else "sind keine Assets der Strategie", ", ".join(assets)))
    for k, v in zip(nm, vals):
        if not _is_wrapper(v):
            _chk().chk_stop("a.m_sfw_wrappers", k)
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


def portfolio_template(name=None, *, map=None, **kwargs):  # noqa: A002 - R-Argumentname
    """Portfolio-Vorlagen.

    Bekannte statische Allokationen mit Rollen-Namen (z. B. ``stocks``, ``long_bonds``, ``gold``). Über ``map``
    werden die Rollen den Spalten des Datensatzes zugeordnet. Die Vorlagen sind Ausgangspunkte zum Vergleich,
    keine Empfehlungen.

    Args:
        name: Name der Vorlage als Zeichenkette (siehe Tabelle). Ohne ``name`` (Standard ``None``) liefert
            ``portfolio_template()`` die Liste aller Vorlagen; ``map`` und ``...`` sind dann nicht erlaubt.
        map: Benannter Zeichenvektor Rolle -> Spaltenname im Datensatz, z. B. ``{"stocks": "msci_world"}``.
            Standard ``None``; Rollen ohne Eintrag behalten ihren Namen und müssen dann als Spalte vorliegen.
            Unbekannte Rollen und mehrere Rollen auf derselben Spalte sind ein Fehler.
        **kwargs: Weitere Argumente für ``strategy_from_weights()`` bzw. ``asset_config()`` (z. B. ``spread``,
            ``partial_exemption``, ``wrapper``). Benannte Werte je Asset, auch die Namen einer ``wrapper``-Liste,
            beziehen sich auf die Namen nach ``map`` (Spaltennamen); Rollen ohne ``map``-Eintrag behalten ihren
            Namen.

    Returns:
        Mit ``name``: Objekt der Klasse ``strategy`` für ``simulation()``; ohne ``name``: DataFrame aller Vorlagen
        mit ``template``, ``role`` und ``weight`` (Anteil, 0.6 = 60 %).

    Details:
        - ``60_40`` | Aktien 60, Anleihen 40
        - ``permanent`` | Permanent Portfolio (H. Browne): je 25 Aktien, lange Anleihen, Geldmarkt, Gold
        - ``all_weather`` | vereinfachtes All Weather: 30/40/15/7.5/7.5
        - ``golden_butterfly`` | je 20 Aktien, Small Value, lange und kurze Anleihen, Gold
        - ``three_fund`` | Aktien Heimat 48, international 32, Anleihen 20
        - ``hfea`` | 55 3x-Aktien, 45 3x-lange Anleihen
        - ``stocks_gold`` | Aktien 80, Gold 20

        Gewichte in der Tabelle in Prozent; in der Strategie als Anteile.

    Beispiel::

        import simlev
        st = simlev.portfolio_template(name="permanent", map={"stocks": "msci_world", "long_bonds": "bund_10y",
                                                             "cash": "geldmarkt", "gold": "gold_eur"})
        print(st)
    """
    if name is None:
        if map is not None or kwargs:
            _chk().chk_stop("a.m_portfolio_template")
        return _template_list()
    name = _chk().chk_name1(name, "portfolio_template", "name")   # seit 1.6.4 (K42 E5)
    w = _PORTFOLIO_TEMPLATES.get(name)
    if w is None:
        _chk().chk_stop("a.m_portfolio_template_2", name, ", ".join(_PORTFOLIO_TEMPLATES))
    roles = list(w.keys())
    vals = list(w.values())
    if map is not None:
        mn, mv = _named(map)
        mvals = list(map.values()) if isinstance(map, Mapping) else list(np.asarray(map, dtype=object).ravel())
        if mn is None or any(k is None or k == "" for k in mn) or \
                not all(isinstance(v, str) and v != "" for v in mvals):
            _chk().chk_stop("a.m_portfolio_template_3")
        unk = []
        for k in mn:
            if k not in roles and k not in unk:
                unk.append(k)
        if unk:
            _chk().chk_stop("a.m_portfolio_template_4", ", ".join("'%s'" % k for k in unk), name, ", ".join(roles))
        lookup = {}
        for k, v in zip(mn, mv):
            lookup.setdefault(k, v)
        roles = [str(lookup[r]) if r in lookup else r for r in roles]
        u = _dup_names(roles)
        if u:
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
