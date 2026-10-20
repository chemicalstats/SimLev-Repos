"""Synthetische Anleihe-, Geldmarkt- und gesicherte Reihen (Port von ``r/R/bonds.R``).

- :func:`bond_index_from_yields`  Total-Return-Index einer Anleihe konstanter
  Laufzeit aus einer Renditereihe (Swinkels 2019)
- :func:`money_market_index`      Geldmarkt-Index aus einem Tageszins (Act/360)
- :func:`currency_hedged_index`   währungsgesicherte Reihe (gedeckte Zinsparität)

Alle Zinsen in Prozent p. a.; Eingaben als Spaltenname, Vektor, Skalar oder
``DataFrame(date, value)`` (Stufenfunktion).
"""
from __future__ import annotations

import numpy as np

from ._rnum import r_cumprod, r_pow_vec
from .backcast import _fill_na, _resolve_series
from .data_prep import _as_frame, _as_numeric, _col, _days, _quiet_fp, _to_date

__all__ = ["bond_index_from_yields", "money_market_index", "currency_hedged_index", "RVector"]


class RVector(np.ndarray):
    """Numerischer Vektor mit R-Attributen (``x.attrs``, z. B. ``duration``)."""

    def __new__(cls, a, **attrs):
        obj = np.asarray(a, dtype=np.float64).view(cls)
        obj.attrs = dict(attrs)
        return obj

    def __array_finalize__(self, obj):
        if obj is None:
            return
        self.attrs = dict(getattr(obj, "attrs", {}))

    @property
    def duration(self):
        return self.attrs.get("duration")


def _bond_price(y, coupon, maturity, m):
    """Kurs einer Anleihe je 1 Nominal (Port von ``.bond_price``)."""
    y = np.asarray(y, dtype=np.float64)
    coupon = np.asarray(coupon, dtype=np.float64)
    i = y / m
    n = maturity * m
    dis = r_pow_vec(1 + i, -n).reshape(i.shape)
    with np.errstate(invalid="ignore", divide="ignore"):
        ann = np.where(np.abs(i) < 1e-10, n, (1 - dis) / i)
    return coupon / m * ann + dis


def bond_index_from_yields(data, yield_=None, maturity=10, coupon_frequency=1, method=("exact", "duration"),
                           start=100, **kw):
    """Anleihe-Index aus Renditen (konstante Laufzeit).

    An jedem Tag wird eine neue Par-Anleihe (Kupon = Rendite des Vortags)
    gekauft und am Folgetag zur neuen Rendite bewertet:
    ``r_t = P(y_t; c = y_{t-1}, M) - 1 + y_{t-1} Δt``. Mit
    ``method="duration"`` Näherung über Duration und Konvexität.

    Args:
        data: ``DataFrame`` mit Spalte ``date``.
        yield_: Rendite in Prozent p. a. (Spaltenname, Vektor, Skalar,
            ``DataFrame(date, value)`` oder benannter Vektor); in R ``yield``
            (auch als ``**{"yield": ...}`` angebbar).
        maturity: Restlaufzeit in Jahren.
        coupon_frequency: Kupons je Jahr.
        method: ``"exact"`` oder ``"duration"``.
        start: Startwert des Index.

    Returns:
        :class:`RVector` (Indexniveau) mit ``attrs["duration"]``.
    """
    from .data_prep import _match_arg
    if "yield" in kw:
        yield_ = kw.pop("yield")
    if kw:
        raise TypeError("unused argument(s): %s" % ", ".join(kw))
    method = _match_arg(method, ("exact", "duration"))
    data = _as_frame(data)
    y = _resolve_series(yield_, data, "yield") / 100
    d = _days(_to_date(_col(data, "date"), "data$date"))
    n = len(y)
    dt = np.concatenate([[0.0], np.diff(d)]) / 365.25
    m = coupon_frequency
    y0 = np.concatenate([y[:1], y[:-1]])
    c0 = y0
    if method == "exact":
        price = _bond_price(y, c0, maturity, m)
    else:
        h = 1e-4
        p0 = _bond_price(y0, c0, maturity, m)
        up = _bond_price(y0 + h, c0, maturity, m)
        dn = _bond_price(y0 - h, c0, maturity, m)
        dur = -(up - dn) / (2 * h) / p0
        cvx = (up - 2 * p0 + dn) / (h * h) / p0
        dy = y - y0
        price = 1 - dur * dy + 0.5 * cvx * (dy * dy)
    r = price - 1 + c0 * dt
    if n:
        r[0] = 0
    out = start * r_cumprod(1 + r)
    h = 1e-4
    dur = -(_bond_price(y + h, y, maturity, m) - _bond_price(y - h, y, maturity, m)) / (2 * h)
    return RVector(out, duration=dur)


def money_market_index(data, rate, spread=0, basis=360, start=100):
    """Geldmarkt-Index aus einem Tageszins: ``I_t = I_{t-1} (1 + (i_{t-1} - s)/100 Δt/B)``.

    Args:
        data: ``DataFrame`` mit Spalte ``date``.
        rate: Zins in Prozent p. a. (Spaltenname, Vektor, Skalar, ``DataFrame(date, value)``
            oder benannter Vektor mit Datumsnamen).
        spread: Abschlag in Prozent p. a.
        basis: Tagesbasis (360 oder 365).
        start: Startwert.

    Returns:
        ``numpy.ndarray`` (Indexniveau).
    """
    data = _as_frame(data)
    i = _resolve_series(rate, data, "rate")
    d = _days(_to_date(_col(data, "date"), "data$date"))
    days = np.concatenate([[0.0], np.diff(d)])
    r = np.concatenate([[0.0], (i[:-1] - spread) / 100 * days[1:] / basis])
    return start * r_cumprod(1 + r)


def currency_hedged_index(data, local, domestic_rate, foreign_rate, cost=0, basis=360, start=None):
    """Währungsgesicherte Reihe: lokale Rendite plus Zinsdifferenz, minus Sicherungskosten.

    Args:
        data: ``DataFrame`` mit Spalte ``date``.
        local: Kursreihe in Lokalwährung (Spaltenname oder Vektor; Lücken per LOCF).
        domestic_rate, foreign_rate: Zinsen in Prozent p. a.
        cost: Sicherungskosten in Prozent p. a. (Tagesbasis 365).
        basis: Tagesbasis der Zinsdifferenz.
        start: Startwert (``None`` = erster Wert der lokalen Reihe).

    Returns:
        ``numpy.ndarray`` (Indexniveau).
    """
    data = _as_frame(data)
    x = _as_numeric(_col(data, local)) if isinstance(local, str) else _as_numeric(local)
    x = _fill_na(x, "locf")
    i_d = _resolve_series(domestic_rate, data, "domestic_rate")
    i_f = _resolve_series(foreign_rate, data, "foreign_rate")
    d = _days(_to_date(_col(data, "date"), "data$date"))
    n = len(x)
    days = np.concatenate([[0.0], np.diff(d)])
    with np.errstate(invalid="ignore", divide="ignore"):
        r = np.concatenate([[0.0], x[1:] / x[:-1] - 1 + (i_d[:-1] - i_f[:-1]) / 100 * days[1:] / basis
                            - cost / 100 * days[1:] / 365])
    s = x[0] if start is None else start
    return s * r_cumprod(1 + r)


_quiet_fp(globals(), ["bond_index_from_yields", "money_market_index", "currency_hedged_index"])
