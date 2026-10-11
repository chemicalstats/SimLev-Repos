"""Datumshelfer. Daten werden intern wie in R als Tage seit 1970-01-01 geführt."""
from __future__ import annotations

import datetime as _dt
import re
from typing import Any

import numpy as np

EPOCH = _dt.date(1970, 1, 1)
EPOCH_ORD = EPOCH.toordinal()


def to_days(d: Any) -> int:
    """Konvertiert date/datetime/str/np.datetime64/int in Tage seit Epoch."""
    if isinstance(d, (int, np.integer)) and not isinstance(d, bool):
        return int(d)
    if isinstance(d, (float, np.floating)):
        return int(d)
    if isinstance(d, np.datetime64):
        return int(d.astype("datetime64[D]").astype(np.int64))
    if isinstance(d, _dt.datetime):
        return d.date().toordinal() - EPOCH_ORD
    if isinstance(d, _dt.date):
        return d.toordinal() - EPOCH_ORD
    if hasattr(d, "to_pydatetime"):          # pandas.Timestamp
        return d.to_pydatetime().date().toordinal() - EPOCH_ORD
    if isinstance(d, str):
        return _dt.date.fromisoformat(d.strip()[:10]).toordinal() - EPOCH_ORD
    raise TypeError("Kann %r nicht als Datum interpretieren" % (d,))


def dates_to_days(values: Any) -> np.ndarray:
    """Vektor von Datumswerten -> int64-Array (Tage seit Epoch)."""
    arr = np.asarray(values)
    if np.issubdtype(arr.dtype, np.datetime64):
        return arr.astype("datetime64[D]").astype(np.int64)
    if np.issubdtype(arr.dtype, np.integer):
        return arr.astype(np.int64)
    try:
        import pandas as pd  # noqa: WPS433
        return pd.to_datetime(pd.Series(list(values))).values.astype("datetime64[D]").astype(np.int64)
    except Exception:
        return np.array([to_days(v) for v in values], dtype=np.int64)


def from_days(z: int) -> _dt.date:
    return _dt.date.fromordinal(int(z) + EPOCH_ORD)


def ymd(z: int) -> tuple[int, int, int]:
    d = from_days(z)
    return d.year, d.month, d.day


def year_of(z: int) -> int:
    return from_days(z).year


def fmt_date(z: int) -> str:
    return from_days(z).isoformat()


def days_from_civil(y: int, m: int, d: int) -> int:
    return _dt.date(y, m, d).toordinal() - EPOCH_ORD


def is_leap(y: int) -> bool:
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)


def valid_civil(y: int, m: int, d: int) -> int | None:
    try:
        return days_from_civil(y, m, d)
    except ValueError:
        return None


def r_num_str(x: Any) -> str:
    """``as.character(x)``/``paste()`` für Zahlen wie R (15 signifikante Stellen)."""
    if isinstance(x, (bool, np.bool_)):
        return "TRUE" if x else "FALSE"
    if isinstance(x, (int, np.integer)):
        return str(int(x))
    xf = float(x)
    if xf != xf:
        return "NA"
    if xf == int(xf) and abs(xf) < 1e15:
        return str(int(xf))
    s = "%.15g" % xf
    if "e" in s:
        mant, exp = s.split("e")
        exp_i = int(exp)
        s = "%se%s%02d" % (mant, "-" if exp_i < 0 else "+", abs(exp_i))
    return s


_LEAD_INT = re.compile(r"^\s*([+-]?)(\d+)")


def r_strptime_ymd(y: Any, m: Any, d: Any) -> int | None:
    """``as.Date(paste(y, m, d, sep='-'), format='%Y-%m-%d')`` wie R.

    R liest ``%m`` und ``%d`` mit höchstens zwei Ziffern und ignoriert
    nachfolgende Zeichen; ungültige Kalenderdaten ergeben ``NA`` (``None``).
    """
    ys, ms, ds = r_num_str(y), r_num_str(m), r_num_str(d)
    my = re.match(r"^(\d{1,4})$", ys)
    if not my:
        return None
    mm = re.match(r"^(\d{1,2})$", ms)
    if not mm:
        return None
    md = re.match(r"^(\d{1,2})", ds)
    if not md:
        return None
    return valid_civil(int(my.group(1)), int(mm.group(1)), int(md.group(1)))


def first_of_month(z: int) -> int:
    y, m, _ = ymd(z)
    return days_from_civil(y, m, 1)


def add_months_first(z_first: int, k: int) -> int:
    y, m, _ = ymd(z_first)
    tot = (y * 12 + (m - 1)) + k
    return days_from_civil(tot // 12, tot % 12 + 1, 1)


def ym_key(z: int) -> int:
    y, m, _ = ymd(z)
    return y * 12 + m
