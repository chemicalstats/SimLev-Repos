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
import pandas as pd

from ._r import libm as _libm
from ._r.rnum import NA_REAL, r_cumprod
from .backcast import _fill_na, _resolve_series
from ._r.base import quiet_fp
from .data_prep import _as_frame, _as_numeric, _col, _days, _to_date
from ._pruefen import chk_cols, chk_df, chk_is_factor, chk_len, chk_name1, chk_num1, chk_numvec, chk_scalar, chk_stop, chk_msg


def _idx_data(data, fn):
    """data nur als Tabelle mit Spalte date (seit 1.6.4, Entscheidung 6; R: .idx_data)."""
    chk_df(data, fn, "data")
    chk_cols(data, ["date"], fn)
    if chk_is_factor(data["date"]):   # seit 1.6.4 (Entscheidung 15; bis 1.6.3 still in Text umgewandelt)
        chk_stop("spalte_faktor", fn, "date")
    if len(data) == 0:   # seit 1.6.4 Fehler (Entscheidung 25; bis 1.6.3 Python-Fehler, R 100)
        chk_stop("zeilen_keine", fn, "data")
    # seit 1.6.5 (CR2-V1-4, CR2-V3-4): Datum aufsteigend und ohne NA (bis 1.6.4 gingen negative Tageszahlen still ein)
    d = _days(_to_date(_col(_as_frame(data), "date"), "data$date"))
    if np.isnan(d).any() or (np.diff(d) < 0).any():
        chk_stop("e3.datum", fn)


def _step_start_warn(x, data, fn, arg):
    """Stufentabelle (``DataFrame(date, Wert)`` oder benannter Vektor mit Datumsnamen), die erst nach dem ersten
    Datentag beginnt: Warnung (seit 1.6.5, CR2-V3-4 Punkt 4, Entscheidung 189; R ``.step_start_warn``); ungültige
    Tabellen meldet danach ``_resolve_series`` wie bisher."""
    from .data_prep import _is_named_numeric, _named_parts, _names, _names_as_dates_optional
    from ._dates import fmt_date
    first = None
    try:
        xf = _as_frame(x)
        if isinstance(xf, pd.DataFrame):
            if xf.shape[1] >= 2:
                nm = _names(xf)
                fd = _days(_to_date(_col(xf, "date" if "date" in nm else nm[0]), "x"))
                if fd.size and not np.isnan(fd).any():
                    first = float(fd.min())
        elif _is_named_numeric(x):
            nd = np.asarray(_names_as_dates_optional(_named_parts(x)[0]), dtype=np.float64)
            if nd.size and not np.isnan(nd).any():
                first = float(nd.min())
    except Exception:  # noqa: BLE001 - ungültige Tabelle: Meldung später in _resolve_series
        first = None
    if first is None:
        return
    try:
        d = _days(_to_date(_col(_as_frame(data), "date"), "x"))
    except Exception:  # noqa: BLE001
        return
    if not d.size or np.isnan(d).all():
        return
    d0 = float(np.nanmin(d))
    if first > d0:
        import warnings
        warnings.warn(chk_msg("a.stufe_spaet", fn, arg, fmt_date(int(first)), fmt_date(int(d0))), UserWarning,
                      stacklevel=3)


def _idx_numcol(data, col, fn):
    """Spalte numerisch (eine Spalte nur aus NA zählt als Zahlenspalte, Entscheidung 14)."""
    from ._sim_base import _column
    kind, arr = _column(data[col])
    if kind == "factor":   # Entscheidung 15
        chk_stop("spalte_faktor", fn, col)
    if not (kind == "numeric" or (kind == "logical" and all(v is None for v in arr))):
        chk_stop("spalte_typ", fn, col, chk_msg("typ.numerisch"))


def _no_factor(x, fn, arg):
    """Entscheidung 15: keine Kategorie (pandas CategoricalDtype) als Angabe oder Tabellenspalte."""
    if chk_is_factor(x):
        chk_stop("faktor", fn, arg)
    if isinstance(x, pd.DataFrame):
        for c in x.columns:
            if isinstance(x[c].dtype, pd.CategoricalDtype):
                chk_stop("spalte_faktor", fn, str(c))


def _idx_rate(x, data, fn, arg):
    """Zinsangabe (R: .idx_rate): Spaltenname einer numerischen Spalte oder einzelne endliche Zahl; die übrigen
    Formen prüft _resolve_series. None (R NULL) fehlt; ein Wahrheitswert ist wie in R nicht interpretierbar."""
    if x is None:
        chk_stop("fehlt", fn, arg)
    _no_factor(x, fn, arg)
    x1 = chk_scalar(x)
    if isinstance(x1, str):
        chk_name1(x1, fn, arg)
        if x1 in [str(c) for c in data.columns]:
            _idx_numcol(data, x1, fn)
    elif isinstance(x1, (bool, np.bool_)):
        raise ValueError("%s: nicht interpretierbare Angabe (Skalar, Vektor der Länge %d, Spaltenname, data.frame(date, "
                         "Wert) oder benannter Vektor mit Datumsnamen)." % (arg, len(data)))
    elif isinstance(x1, (int, float, np.integer, np.floating)) or x1 is pd.NA:
        chk_num1(x1, fn, arg)

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

    @property
    def convexity(self):
        return self.attrs.get("convexity")


def _bond_price(y, coupon, maturity, m):
    """Kurs einer Anleihe je 1 Nominal (R: ``.bond_price``); seit 1.6.5 (CR2-X44-1) über ``L = log1p(i)``:
    Abzinsung ``exp(-n L)``, Rentenbarwert ``-expm1(-n L) / i`` (bei ``i == 0``: ``n``), ohne Auslöschung bei sehr
    kleinen Renditen (bis 1.6.4 ``(1 + i)^(-n)`` und ``(1 - dis) / i`` mit Schwelle 1e-10)."""
    y = np.asarray(y, dtype=np.float64)
    coupon = np.asarray(coupon, dtype=np.float64)
    i = y / m
    n = maturity * m
    with np.errstate(invalid="ignore", divide="ignore", over="ignore"):
        L = _libm.log1p(i)
        dis = _libm.exp(-n * L)
        ann = -_libm.expm1(-n * L) / i
    ann = np.where(i == 0, float(n), ann)
    return coupon / m * ann + dis


def _bond_dur(i, n, maturity, m):
    """Modifizierte Duration der Par-Anleihe geschlossen (seit 1.6.4, K43 T1-R3, Entscheidung 136; R ``.bond_dur``):
    ``-expm1(-n log1p(i)) / (i m)``, bei ``i == 0`` die Laufzeit, NA und NaN ergeben NA."""
    i = np.asarray(i, dtype=np.float64)
    with np.errstate(invalid="ignore", divide="ignore"):
        v = -_libm.expm1(-n * _libm.log1p(i)) / (i * m)
        out = np.where(i == 0, float(maturity), v)
    out[np.isnan(i)] = NA_REAL
    return out


def _bond_cvx(i, n, m):
    """Konvexität der Par-Anleihe geschlossen bzw. als Reihe für ``|i| (n + 1) < 0.05`` (seit 1.6.4, K43 T1-R3; R
    ``.bond_cvx``, gleiche Rechenfolge)."""
    i = np.asarray(i, dtype=np.float64)
    with np.errstate(invalid="ignore", divide="ignore", over="ignore"):
        L = _libm.log1p(i)
        cv = 2 * (-_libm.expm1(-n * L) / i - n * _libm.exp(-(n + 1) * L)) / (i * (m * m))
        sm = ~np.isnan(i) & (np.abs(i) * (n + 1) < 0.05)
        if sm.any():
            ii = i[sm]
            t = np.full(ii.size, n * (n + 1) / 2)
            s = t.copy()
            for k in range(1, 16):
                t = t * (-ii) * (n + k + 1) * (k + 1) / (k * (k + 2))
                s = s + t
            cv[sm] = 2 * s / (m * m)
    cv[np.isnan(i)] = NA_REAL
    return cv


def index_bond(data, *, yield_=None, maturity=10, coupon_frequency=1, method=("exact", "duration"),
                           start=100, **kw):
    """Anleihe-Index aus Renditen (konstante Laufzeit).

    Bildet einen Total-Return-Index einer Staatsanleihe mit konstanter Restlaufzeit aus einer Renditereihe. An
    jedem Tag wird eine neue Par-Anleihe (Kupon = Rendite des Vortags) gekauft und am Folgetag zur neuen Rendite
    bewertet: r_t = P(y_t; c = y_{t-1}, M) - 1 + y_{t-1} Δt mit Δt = Kalendertage seit der Vorzeile / 365.25. Mit
    ``method = "duration"`` wird die Kursänderung über modifizierte Duration und Konvexität angenähert, -D Δy +
    (1/2) C Δy^2 (wie bei Swinkels 2019). Roll-down-Effekte entlang der Zinskurve und Kosten sind nicht
    enthalten. Das Ergebnis kann als Kursspalte (Niveau) in ``simulation()`` oder ``bootstrap_config()`` verwendet
    werden.

    Args:
        data: DataFrame mit Spalte ``date`` (Date oder umwandelbar, eine Zeile je Tag des gewünschten Index).
        yield_: ``yield`` (in Python ``yield_``, da ``yield`` ein Schlüsselwort ist): Rendite in Prozent p. a.
            (2.5 = 2,5 Prozent): Spaltenname, Vektor der Länge ``nrow(data)``, Skalar, ``data.frame(date, value)``
            (z. B. Monatswerte, Stufenfunktion ab Datum) oder benannter Vektor mit Datumsnamen. Je Kuponperiode muss
            die Rendite größer als -100 Prozent sein (``yield / coupon_frequency > -100``; seit 1.6.4 geprüft).
        maturity: Konstante Restlaufzeit in Jahren (Standard 10).
        coupon_frequency: Kupons je Jahr (Standard 1 = jährlich wie Bundesanleihen; 2 = halbjährlich wie
            US-Treasuries).
        method: ``"exact"`` (Standard, Neubewertung) oder ``"duration"`` (Duration-/Konvexitätsnäherung).
        start: Startwert des Index in der ersten Zeile (Standard 100; > 0). Seit 1.6.4 geprüft: ``data`` nur
            als ``pandas.DataFrame`` mit Spalte ``date`` (mindestens eine Datenzeile; seit 1.6.4 ist 0 Zeilen ein Fehler), Zahlen endlich (Laufzeit, Kupons,
            Basis > 0), eine Spalte als Zinsangabe numerisch, ``None`` als Zins fehlt.
        **kw: nur ``yield`` (``**{"yield": …}``) als Schreibweise für ``yield_`` (``yield`` ist in Python ein
            Schlüsselwort); andere Namen sind ein Fehler.

    Returns:
        Numerischer Indexvektor (Niveau, Länge ``nrow(data)``) mit Attribut ``duration`` (modifizierte Duration
        der Par-Anleihe zur Rendite des jeweiligen Tages, in Jahren) und seit 1.6.5 ``convexity`` (Konvexität der
        Par-Anleihe zur Rendite des jeweiligen Tages, in Jahren², geschlossen wie beim Verfahren ``"duration"``;
        Zugriff ``x.attrs["convexity"]`` bzw. ``x.convexity``). Duration (und beim Verfahren ``"duration"`` die
        Konvexität) seit 1.6.4 geschlossen gerechnet, auf alle Stellen genau; bis 1.6.3 über zentrale Differenzen
        (relativer Fehler bis etwa 2e-6 bei 30 Jahren). Seit 1.6.5 muss ``date`` aufsteigend und ohne NA sein; der
        Kurs der Anleihe wird über ``log1p`` ohne Auslöschung bei sehr kleinen Renditen gerechnet (Änderung in den
        letzten Stellen); eine Stufentabelle als ``yield``, die erst nach dem ersten Datentag beginnt, ergibt eine
        Warnung (davor gilt ihr erster Wert).

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
    fn = "index_bond"
    _idx_data(data, fn)
    _idx_rate(yield_, data, fn, "yield")
    maturity = chk_num1(maturity, fn, "maturity", lo=0, lo_open=True)
    coupon_frequency = chk_num1(coupon_frequency, fn, "coupon_frequency", lo=0, lo_open=True)
    start = chk_num1(start, fn, "start", lo=0, lo_open=True)
    method = _match_arg(chk_scalar(method), ("exact", "duration"))
    data = _as_frame(data)
    _step_start_warn(yield_, data, fn, "yield")
    y = _resolve_series(yield_, data, "yield") / 100
    m = coupon_frequency
    # seit 1.6.4 (K43 T1-R8): Renditen von -100 % je Kuponperiode oder weniger ablehnen (R wie Julia)
    with np.errstate(invalid="ignore"):
        if np.any(y / m <= -1):
            chk_stop("ut1.rendite", fn)
    d = _days(_to_date(_col(data, "date"), "data$date"))
    n = len(y)
    dt = np.concatenate([[0.0], np.diff(d)]) / 365.25
    y0 = np.concatenate([y[:1], y[:-1]])
    c0 = y0
    nm = maturity * m
    if method == "exact":
        price = _bond_price(y, c0, maturity, m)
    else:
        # seit 1.6.4 (K43 T1-R3, Entscheidung 136) Duration und Konvexität geschlossen
        i0 = y0 / m
        dur = _bond_dur(i0, nm, maturity, m)
        cvx = _bond_cvx(i0, nm, m)
        dy = y - y0
        price = 1 - dur * dy + 0.5 * cvx * (dy * dy)
    r = price - 1 + c0 * dt
    if n:
        r[0] = 0
    out = start * r_cumprod(1 + r)
    dur = _bond_dur(y / m, nm, maturity, m)   # seit 1.6.4 geschlossen (K43 T1-R3)
    cvx = _bond_cvx(y / m, nm, m)   # seit 1.6.5 (Entscheidung 151): Konvexität je Tag
    return RVector(out, duration=dur, convexity=cvx)


def index_money_market(data, rate, *, spread=0, basis=360, start=100):
    """Geldmarkt-Index aus einem Tageszins: ``I_t = I_{t-1} (1 + (i_{t-1} - s)/100 Δt/B)``.

    Bildet einen Geldmarkt- bzw. Tagesgeld-Index (Niveau) aus einem Zinssatz, z. B. ESTR oder EFFR, als Kursspalte
    für ``simulation()``: I_t = I_{t-1} · (1 + (i_{t-1} - s)/100 · Δt/B) mit Zins i des Vortags, Abschlag s (z. B.
    Fondskosten), Kalendertagen Δt seit der Vorzeile und Tagesbasis B (Act/360).

    Seit 1.6.5 muss ``date`` aufsteigend und ohne NA sein (sonst Fehler); eine Stufentabelle als ``rate``, die erst
    nach dem ersten Datentag beginnt, ergibt eine Warnung (davor gilt ihr erster Wert).

    Args:
        data: DataFrame mit Spalte ``date`` (eine Zeile je Indextag).
        rate: Zins in Prozent p. a. (3 = 3 Prozent): Spaltenname, Vektor der Länge ``nrow(data)``, Skalar,
            ``data.frame(date, value)`` (Stufenfunktion ab Datum) oder benannter Vektor mit Datumsnamen.
        spread: Abschlag in Prozent p. a. (Standard 0), auf derselben Tagesbasis wie der Zins.
        basis: Tagesbasis (Standard 360; üblich 360 oder 365).
        start: Startwert des Index in der ersten Zeile (Standard 100; > 0). Seit 1.6.4 geprüft: ``data`` nur
            als ``pandas.DataFrame`` mit Spalte ``date`` (mindestens eine Datenzeile; seit 1.6.4 ist 0 Zeilen ein Fehler), Zahlen endlich (Laufzeit, Kupons,
            Basis > 0), eine Spalte als Zinsangabe numerisch, ``None`` als Zins fehlt.

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
    fn = "index_money_market"
    _idx_data(data, fn)
    _idx_rate(rate, data, fn, "rate")
    spread = chk_num1(spread, fn, "spread")
    basis = chk_num1(basis, fn, "basis", lo=0, lo_open=True)
    start = chk_num1(start, fn, "start", lo=0, lo_open=True)
    data = _as_frame(data)
    _step_start_warn(rate, data, fn, "rate")
    i = _resolve_series(rate, data, "rate")
    d = _days(_to_date(_col(data, "date"), "data$date"))
    # seit 1.6.5 (CR2-V3-4 Punkt 3, wie Entscheidung 186 M8): Zinsreihe ohne Lücken, Tagesfaktor > 0
    from ._dates import fmt_date
    raw = (np.asarray(_col(data, rate), dtype=np.float64) if isinstance(rate, str) and rate in list(data.columns)
           else np.asarray(i, dtype=np.float64))
    k = np.flatnonzero(np.isnan(raw))
    if k.size:
        chk_stop("a.mm_luecke", fn, "rate", fmt_date(int(d[k[0]])))
    days = np.concatenate([[0.0], np.diff(d)])
    r = np.concatenate([[0.0], (i[:-1] - spread) / 100 * days[1:] / basis])
    k = np.flatnonzero(~(1 + r > 0))
    if k.size:
        chk_stop("a.mm_faktor", fn, fmt_date(int(d[k[0]])))
    return start * r_cumprod(1 + r)


def index_currency_hedged(data, local, domestic_rate, foreign_rate, *, cost=0, basis=360, start=None):
    """Währungsgesicherte Reihe: lokale Rendite plus Zinsdifferenz, minus Sicherungskosten.

    Näherung einer rollierend per Devisentermingeschäft gesicherten Anlage: Die Rendite in Lokalwährung plus die
    Zinsdifferenz zwischen Heimat- und Fremdwährung (gedeckte Zinsparität), abzüglich Sicherungskosten: r^h_t =
    r^lokal_t + (i^heim_{t-1} - i^fremd_{t-1})/100 · Δt/B - k/100 · Δt/365 mit Zinsen des Vortags und
    Kalendertagen Δt seit der Vorzeile. Effekte aus der Absicherung nur des Anfangswerts einer Rollperiode
    (Restrisiko auf Kursgewinne) sind nicht enthalten.

    Seit 1.6.5 muss ``date`` aufsteigend und ohne NA sein und ``local`` (nach dem Füllen) endliche Werte > 0
    haben (sonst Fehler); eine Stufentabelle als Zins, die erst nach dem ersten Datentag beginnt, ergibt eine
    Warnung (davor gilt ihr erster Wert).

    Args:
        data: DataFrame mit Spalte ``date``.
        local: Kursreihe in Lokalwährung (Niveau): Spaltenname in ``data`` oder numerischer Vektor der Länge
            ``nrow(data)``; Lücken werden mit dem letzten Wert gefüllt.
        domestic_rate, foreign_rate: Zinsen der Heimat- bzw. Fremdwährung in Prozent p. a. (Spaltenname, Vektor,
            Skalar, ``data.frame(date, value)`` oder benannter Vektor mit Datumsnamen).
        cost: Sicherungskosten in Prozent p. a. (Standard 0; Tagesbasis 365).
        basis: Tagesbasis der Zinsdifferenz (Standard 360).
        start: Startwert; ``None`` (Standard) = erster Wert der lokalen Reihe; sonst > 0. Seit 1.6.4 geprüft:
            ``local`` als Vektor mit der Länge ``nrow(data)``, ``cost`` endlich, ``basis`` > 0.

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
    fn = "index_currency_hedged"
    _idx_data(data, fn)
    if local is None:
        chk_stop("fehlt", fn, "local")
    # local: Spaltenname einer numerischen Spalte oder numerischer Vektor der Länge nrow(data)
    if isinstance(chk_scalar(local), str):
        local = chk_name1(local, fn, "local")
        chk_cols(data, [local], fn)
        _idx_numcol(data, local, fn)
    else:
        if chk_is_factor(local):   # Entscheidung 15
            chk_stop("faktor", fn, "local")
        if (isinstance(local, np.ndarray) and local.ndim > 1) or isinstance(local, (pd.DataFrame, dict)):
            chk_stop("zahlen", fn, "local")
        chk_numvec(local, fn, "local")
        chk_len(np.atleast_1d(np.asarray(local, dtype=object)), len(data), fn, "local")
    _idx_rate(domestic_rate, data, fn, "domestic_rate")
    _idx_rate(foreign_rate, data, fn, "foreign_rate")
    cost = chk_num1(cost, fn, "cost")
    basis = chk_num1(basis, fn, "basis", lo=0, lo_open=True)
    start = chk_num1(start, fn, "start", lo=0, lo_open=True, null_ok=True)
    data = _as_frame(data)
    x = _as_numeric(_col(data, local)) if isinstance(local, str) else _as_numeric(local)
    x = _fill_na(x, "locf")
    # seit 1.6.5 (CR2-V1-4): Kurse endlich und > 0 (bis 1.6.4 still -Inf bzw. sinnlose Werte)
    with np.errstate(invalid="ignore"):
        bad = np.flatnonzero(~np.isnan(x) & (np.isinf(x) | (x <= 0)))
    if bad.size:
        chk_stop("a.werte_positiv", fn, "local", int(bad[0]) + 1)
    _step_start_warn(domestic_rate, data, fn, "domestic_rate")
    _step_start_warn(foreign_rate, data, fn, "foreign_rate")
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
