"""Datumshelfer. Daten werden intern wie in R als Tage seit 1970-01-01 geführt."""
from __future__ import annotations

import datetime as _dt
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




