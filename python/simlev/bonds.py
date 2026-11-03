"""Synthetische Anleihe-, Geldmarkt- und gesicherte Reihen (Gegenstück zu ``r/R/bonds.R``).

- :func:`index_bond`  Total-Return-Index einer Anleihe konstanter
  Laufzeit aus einer Renditereihe (Swinkels 2019)
- :func:`index_money_market`      Geldmarkt-Index aus einem Tageszins (Act/360)
- :func:`index_currency_hedged`   währungsgesicherte Reihe (gedeckte Zinsparität)

Alle Zinsen in Prozent p. a.; Eingaben als Spaltenname, Vektor, Skalar oder
``DataFrame(date, value)`` (Stufenfunktion).
"""
from __future__ import annotations

import numpy as np

from ._r.rnum import r_cumprod, r_pow_vec
from .backcast import _fill_na, _resolve_series
from ._r.base import quiet_fp
from .data_prep import _as_frame, _as_numeric, _col, _days, _to_date

__all__ = ["index_bond", "index_money_market", "index_currency_hedged", "RVector"]


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
    """Kurs einer Anleihe je 1 Nominal (R: ``.bond_price``)."""
    y = np.asarray(y, dtype=np.float64)
    coupon = np.asarray(coupon, dtype=np.float64)
    i = y / m
    n = maturity * m
    dis = r_pow_vec(1 + i, -n).reshape(i.shape)
    with np.errstate(invalid="ignore", divide="ignore"):
        ann = np.where(np.abs(i) < 1e-10, n, (1 - dis) / i)
    return coupon / m * ann + dis


def index_bond(data, *, yield_=None, maturity=10, coupon_frequency=1, method=("exact", "duration"),
                           start=100, **kw):
    """Anleihe-Index aus Renditen (konstante Laufzeit).

    Bildet einen Total-Return-Index einer Staatsanleihe mit konstanter Restlaufzeit aus einer Renditereihe. An
    jedem Tag wird eine neue Par-Anleihe (Kupon = Rendite des Vortags) gekauft und am Folgetag zur neuen Rendite
    bewertet: r_t = P(y_t; c = y_t-1, M) - 1 + y_t-1 Δ t mit Δ t = Kalendertage seit der Vorzeile / 365.25. Mit
    ``method = "duration"`` wird die Kursänderung über modifizierte Duration und Konvexität angenähert, -D Δ y +
    tfrac12 C Δ y^2 (wie bei Swinkels 2019). Roll-down-Effekte entlang der Zinskurve und Kosten sind nicht
    enthalten. Das Ergebnis kann als Kursspalte (Niveau) in ``simulation()`` oder ``bootstrap_config()`` verwendet
    werden.

    Args:
        data: DataFrame mit Spalte ``date`` (Date oder umwandelbar, eine Zeile je Tag des gewünschten Index).
        yield_: ``yield`` (in Python ``yield_``, da ``yield`` ein Schlüsselwort ist): Rendite in Prozent p. a.
            (2.5 = 2,5 Prozent): Spaltenname, Vektor der Länge ``nrow(data)``, Skalar, ``data.frame(date, value)``
            (z. B. Monatswerte, Stufenfunktion ab Datum) oder benannter Vektor mit Datumsnamen.
        maturity: Konstante Restlaufzeit in Jahren (Standard 10).
        coupon_frequency: Kupons je Jahr (Standard 1 = jährlich wie Bundesanleihen; 2 = halbjährlich wie
            US-Treasuries).
        method: ``"exact"`` (Standard, Neubewertung) oder ``"duration"`` (Duration-/Konvexitätsnäherung).
        start: Startwert des Index in der ersten Zeile (Standard 100).
        **kw: nur ``yield`` (``**{"yield": …}``) als Schreibweise für ``yield_`` (``yield`` ist in Python ein
            Schlüsselwort); andere Namen sind ein Fehler.

    Returns:
        Numerischer Indexvektor (Niveau, Länge ``nrow(data)``) mit Attribut ``duration`` (modifizierte Duration
        der Par-Anleihe zur Rendite des jeweiligen Tages, in Jahren).

    Literatur:
        Swinkels, L. (2019), Treasury Bond Return Data Starting in 1962, Data 4(3), 91.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 400
        d = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=n)})
        d["y10"] = 2 + np.cumsum(rng.normal(0, 0.03, n))
        b = simlev.index_bond(d, yield_="y10", maturity=10, coupon_frequency=1)
        print(b[-1])
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


def index_money_market(data, rate, *, spread=0, basis=360, start=100):
    """Geldmarkt-Index aus einem Tageszins: ``I_t = I_{t-1} (1 + (i_{t-1} - s)/100 Δt/B)``.

    Bildet einen Geldmarkt- bzw. Tagesgeld-Index (Niveau) aus einem Zinssatz, z. B. ESTR oder EFFR, als Kursspalte
    für ``simulation()``: I_t = I_t-1(1 + fraci_t-1 - s100·(Δ t)/(B)) mit Zins i des Vortags, Abschlag s (z. B.
    Fondskosten), Kalendertagen Δ t seit der Vorzeile und Tagesbasis B (Act/360).

    Args:
        data: DataFrame mit Spalte ``date`` (eine Zeile je Indextag).
        rate: Zins in Prozent p. a. (3 = 3 Prozent): Spaltenname, Vektor der Länge ``nrow(data)``, Skalar,
            ``data.frame(date, value)`` (Stufenfunktion ab Datum) oder benannter Vektor mit Datumsnamen.
        spread: Abschlag in Prozent p. a. (Standard 0), auf derselben Tagesbasis wie der Zins.
        basis: Tagesbasis (Standard 360; üblich 360 oder 365).
        start: Startwert des Index in der ersten Zeile (Standard 100).

    Returns:
        Numerischer Indexvektor (Niveau, Länge ``nrow(data)``).

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 730
        d = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=n)})
        d["estr"] = 3.0
        mm = simlev.index_money_market(d, "estr", spread=0.1)
        print(mm[-1])
    """
    data = _as_frame(data)
    i = _resolve_series(rate, data, "rate")
    d = _days(_to_date(_col(data, "date"), "data$date"))
    days = np.concatenate([[0.0], np.diff(d)])
    r = np.concatenate([[0.0], (i[:-1] - spread) / 100 * days[1:] / basis])
    return start * r_cumprod(1 + r)


def index_currency_hedged(data, local, domestic_rate, foreign_rate, *, cost=0, basis=360, start=None):
    """Währungsgesicherte Reihe: lokale Rendite plus Zinsdifferenz, minus Sicherungskosten.

    Näherung einer rollierend per Devisentermingeschäft gesicherten Anlage: Die Rendite in Lokalwährung plus die
    Zinsdifferenz zwischen Heimat- und Fremdwährung (gedeckte Zinsparität), abzüglich Sicherungskosten: r^h_t =
    r^lokal_t + fraci^heim_t-1 - i^fremd_t-1100·(Δ t)/(B) - (k)/(100)·(Δ t)/(365) mit Zinsen des Vortags und
    Kalendertagen Δ t seit der Vorzeile. Effekte aus der Absicherung nur des Anfangswerts einer Rollperiode
    (Restrisiko auf Kursgewinne) sind nicht enthalten.

    Args:
        data: DataFrame mit Spalte ``date``.
        local: Kursreihe in Lokalwährung (Niveau): Spaltenname in ``data`` oder numerischer Vektor der Länge
            ``nrow(data)``; Lücken werden mit dem letzten Wert gefüllt.
        domestic_rate, foreign_rate: Zinsen der Heimat- bzw. Fremdwährung in Prozent p. a. (Spaltenname, Vektor,
            Skalar, ``data.frame(date, value)`` oder benannter Vektor mit Datumsnamen).
        cost: Sicherungskosten in Prozent p. a. (Standard 0; Tagesbasis 365).
        basis: Tagesbasis der Zinsdifferenz (Standard 360).
        start: Startwert; ``None`` (Standard) = erster Wert der lokalen Reihe.

    Returns:
        Numerischer Indexvektor (Niveau, Länge ``nrow(data)``).

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 730
        d = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=n)})
        d["sp500"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        h = simlev.index_currency_hedged(d, "sp500", 3, 5, cost=0.1)
        print(d["sp500"].iloc[-1], h[-1])
    """
    data = _as_frame(data)
    x = _as_numeric(_col(data, local)) if isinstance(local, str) else _as_numeric(local)
    x = _fill_na(x, "locf")
    i_d = _resolve_series(domestic_rate, data, "domestic_rate")
    i_f = _resolve_series(foreign_rate, data, "foreign_rate")
    d = _days(_to_date(_col(data, "date"), "data$date"))
    days = np.concatenate([[0.0], np.diff(d)])
    with np.errstate(invalid="ignore", divide="ignore"):
        r = np.concatenate([[0.0], x[1:] / x[:-1] - 1 + (i_d[:-1] - i_f[:-1]) / 100 * days[1:] / basis
                            - cost / 100 * days[1:] / 365])
    s = x[0] if start is None else start
    return s * r_cumprod(1 + r)


quiet_fp(globals(), ["index_bond", "index_money_market", "index_currency_hedged"])
