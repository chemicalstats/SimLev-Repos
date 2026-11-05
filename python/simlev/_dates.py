"""Datumshelfer. Daten werden intern wie in R als Tage seit 1970-01-01 geführt."""
from __future__ import annotations

import datetime as _dt

EPOCH = _dt.date(1970, 1, 1)
EPOCH_ORD = EPOCH.toordinal()


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
