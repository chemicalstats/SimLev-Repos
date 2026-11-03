"""Renditeannahmen, Länder-Bootstrap und Zielplanung (Gegenstück zu ``r/R/planning.R``).

- :func:`series_shift_return`  verschiebt historische Renditen auf eine eigene
  Renditeannahme (Streuung, Abhängigkeiten und Verlaufsmuster bleiben erhalten)
- :func:`bootstrap_pooled`     stationärer Block-Bootstrap über mehrere Länder
  (Anarkulova, Cederburg & O'Doherty 2022); liefert Pfade für
  ``withdrawal_simulation()``
- :func:`portfolio_returns`    Periodenrenditen von Kandidaten-Portfolios
- :func:`planning_goal`        dynamische Programmierung: welches Portfolio
  maximiert je Zeitpunkt und Vermögen die Wahrscheinlichkeit, ein Ziel zu
  erreichen (Das, Ostrov, Radhakrishnan & Srivastav 2020)
"""
from __future__ import annotations

import math
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

from ._r import fmt as _fmt
from ._r.fmt import NA_REAL
from ._r import libm as _libm
from . import _lib as _sl
from ._r.rlist import RList
from ._r.stats_sort import _warn as _rwarn
from . import _dependence_core as _dcore
from ._r.rnum import r_mean, r_sd, r_sum
from .deep_analysis import (
    _ext, _fill_na, _is_num_scalar, _key_month, _key_year, _last_of_key, _match_arg, _mean_lgl,
    _sp, _stats, _to_date_days,
)
from .svg import _AnaSvg, _ana_hline, _ana_legend, _ana_panel, _ana_ramp, _ana_rect, _ana_svg_done

__all__ = ["series_shift_return", "bootstrap_pooled", "portfolio_returns", "planning_goal", "SimLevGoalPlan"]

_NAN = NA_REAL   # R-NA_real_


def _num_col(v):
    """``as.numeric`` einer Spalte; NA/NaN-Bitmuster numerischer Spalten bleiben erhalten (sonst NA)."""
    if getattr(v, "dtype", None) is not None and v.dtype.kind == "f":
        return v.to_numpy(dtype=np.float64, copy=True)
    return pd.to_numeric(v, errors="coerce").to_numpy(dtype=np.float64, na_value=NA_REAL)


def _numvals(x):
    """Werte und Namen eines numerischen Arguments (Skalar, Liste, Array, Series, dict)."""
    if isinstance(x, pd.Series):
        nm = None if isinstance(x.index, pd.RangeIndex) else [str(i) for i in x.index]
        return x.to_numpy(dtype=object), nm
    if isinstance(x, Mapping):
        return np.array(list(x.values()), dtype=object), [str(k) for k in x.keys()]
    return np.atleast_1d(np.asarray(x, dtype=object)).ravel(), None


def _all_num(a):
    return all(_is_num_scalar(e) for e in a)


def _as_num(a):
    return np.array([float(e) for e in a], dtype=np.float64)


# ═══════════════════════════════════════════════════════════════════════════
# series_shift_return
# ═══════════════════════════════════════════════════════════════════════════

def series_shift_return(data, columns, target, *, type=("returns", "prices"), ppy=None):  # noqa: A002 - R-Name
    """Historische Renditen auf eine Renditeannahme verschieben.

    Historische Mittelwerte sind für die Zukunft oft zu optimistisch (z. B. US-Aktien des 20. Jahrhunderts). Diese
    Funktion verschiebt die logarithmierten Renditen jeder Spalte um eine Konstante, so dass die geometrische
    Rendite der Historie der Annahme entspricht. Streuung der Log-Renditen, Schiefe, Abhängigkeiten und zeitliche
    Muster bleiben unverändert; ein anschließender ``bootstrap()`` zieht dann Pfade mit der gewünschten
    Renditeerwartung. Eingabe ist ein DataFrame mit Brutto-Renditen je Zeile oder mit Kursniveaus; zurück kommt
    derselbe DataFrame mit verschobenen Spalten.

    Args:
        data: DataFrame mit den Spalten aus ``columns``; die Spalte ``date`` (Klasse Date oder in Date
            umwandelbar) wird für den Standardwert von ``ppy`` und bei ``type = "prices"`` für die zeitliche
            Reihenfolge gebraucht (Zeilen müssen nicht sortiert sein, die Zeilenreihenfolge des Ergebnisses bleibt
            erhalten; ohne ``date`` gilt die Zeilenreihenfolge als Zeitfolge). Eine Matrix ist nicht zulässig.
        columns: Zeichenvektor mit den Namen der zu verschiebenden Spalten.
        target: Geometrische Zielrendite in Prozent p. a. (4 = 4 % p. a.): Skalar (gilt für alle ``columns``) oder
            benannter Vektor mit einem Eintrag je Spalte aus ``columns`` (z. B. ``{"us": 5, "eu": 5}``); fehlt
            eine Spalte, bricht die Funktion ab.
        type: Art der Spalten: ``"returns"`` (Standard; Brutto-Renditen je Zeile, z. B. 1.001 für +0,1 %, wie für
            ``bootstrap()``) oder ``"prices"`` (Kursniveaus; die Verschiebung wird dann als Trend über die Zeilen
            aufmultipliziert).
        ppy: Renditen (Zeilen) je Jahr. ``None`` (Standard): bei einem DataFrame mit ``date`` Anzahl der Renditen
            geteilt durch die Spanne von ``date`` in Jahren (Tage / 365.25), sonst 252.

    Returns:
        ``data`` mit angepassten Spalten. Attribut ``shift``: benannter Vektor der angewendeten Verschiebung je
        Spalte in Prozent p. a. (geometrisch; negativ = Rendite abgesenkt). Fehlende Werte werden bei der
        Mittelwertbildung ignoriert.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        d = pd.DataFrame({"date": pd.date_range("2000-01-01", periods=3650), "us": np.exp(rng.normal(3e-4, 0.01, 3650))})
        d2 = simlev.series_shift_return(d, "us", 4)
        print(np.prod(d2["us"]) ** (365.25 / 3650) - 1)   # etwa 0.04 = 4 % p. a.
    """
    type = _match_arg(type, ("returns", "prices"))  # noqa: A001
    if not isinstance(data, pd.DataFrame):
        raise ValueError("data muss ein data.frame sein.")
    columns = [columns] if isinstance(columns, str) else [str(c) for c in columns]
    names = [str(c) for c in data.columns]
    miss = [c for c in dict.fromkeys(columns) if c not in names]
    if miss:
        raise ValueError("Spalte(n) nicht in data: %s." % ", ".join(miss))
    tv, tn = _numvals(target)
    if not _all_num(tv) or np.isnan(_as_num(tv)).any():
        raise ValueError("target muss numerisch sein (Prozent p. a., z. B. 4).")
    tv = _as_num(tv)
    if len(tv) == 1 and tn is None:
        tg = {c: float(tv[0]) for c in columns}
    elif tn is None or [c for c in columns if c not in tn]:
        lst = columns if tn is None else [c for c in columns if c not in tn]
        raise ValueError("target braucht einen Skalar oder einen benannten Eintrag je Spalte aus columns; fehlt für: %s."
                         % ", ".join(lst))
    else:
        tg = {}
        for k, v in zip(tn, tv):
            tg.setdefault(k, float(v))
    n = len(data)
    dd = _to_date_days(data["date"], "series_shift_return: data$date") if "date" in names else None
    if dd is not None:
        o = np.argsort(np.where(np.isnan(dd), np.inf, dd), kind="stable")
        o = np.concatenate([o[~np.isnan(dd[o])], o[np.isnan(dd[o])]])
    else:
        o = np.arange(n)
    if type == "prices" and dd is not None:
        vals = ["NA" if math.isnan(v) else v for v in dd.tolist()]
        if len(set(vals)) < len(vals):
            raise ValueError("type = 'prices': date enthält doppelte Daten; Kursniveaus brauchen eine eindeutige Zeitfolge.")
    if ppy is None:
        if dd is not None:
            ok = dd[~np.isnan(dd)]
            ppy = (n - (1 if type == "prices" else 0)) / ((float(np.max(ok)) - float(np.min(ok))) / 365.25)
        else:
            ppy = 252.0
    ppy = float(ppy)
    out = data.copy()
    shift = {}
    for k in columns:
        v = _num_col(data[k])
        lr = _libm.log(v) if type == "returns" else np.diff(_libm.log(v[o]))
        g_hist = r_mean(lr, na_rm=True)
        g_tgt = float(_libm.log1p(tg[k] / 100)) / ppy
        delta = g_tgt - g_hist
        if type == "returns":
            out[k] = v * float(_libm.exp(delta))
        else:
            pos = np.zeros(n, dtype=np.float64)
            pos[o] = np.arange(1, n + 1, dtype=np.float64)
            out[k] = v * _libm.exp(delta * (pos - 1))
        shift[k] = 100 * float(_libm.expm1(delta * ppy))
    out.attrs["shift"] = pd.Series([shift[k] for k in dict.fromkeys(columns)], index=list(dict.fromkeys(columns)),
                                   dtype=np.float64)
    return out


# ═══════════════════════════════════════════════════════════════════════════
# Periodenrenditen
# ═══════════════════════════════════════════════════════════════════════════

def _period_keys(d, frequency):
    if frequency == "month":
        return _key_month(d)
    if frequency == "quarter":
        ym = _key_month(d)
        return ["%s %d" % (k[:4], (int(k[5:7]) - 1) // 3) for k in ym]
    return _key_year(d)


def _period_gross(df, columns, frequency):
    """Periodenrenditen (brutto) aus Kursreihen, ``.period_gross``; ``DataFrame`` Perioden x Spalten."""
    columns = [columns] if isinstance(columns, str) else list(columns)
    d = _to_date_days(df["date"], "data$date")
    key = _period_keys(d, frequency)
    end = _last_of_key(key)
    V = np.column_stack([_fill_na(_num_col(df[k]),
                                  "locf", keep_leading=True)[end] for k in columns]) if columns else np.zeros((len(end), 0))
    G = V[1:, :] / V[:-1, :]
    ok = ~np.isnan(G).any(axis=1)
    return pd.DataFrame(G[ok, :], columns=columns)


def _wd_ppy(frequency):
    try:
        return _ext("withdrawal", "_wd_ppy")(frequency)
    except (ImportError, AttributeError):  # pragma: no cover - Teil B noch nicht verfügbar
        return {"year": 1, "quarter": 4, "month": 12}[frequency]


def _paths_class():
    """Klasse für ``withdrawal_paths`` (Teil B), sonst die lokale."""
    try:
        cls = _ext("withdrawal", "WithdrawalPaths")
        return cls
    except (ImportError, AttributeError):
        return WithdrawalPathsPB


class WithdrawalPathsPB(RList):
    """Ergebnis von :func:`bootstrap_pooled` (R-Klasse ``withdrawal_paths``), falls Teil B keine Klasse liefert."""

    r_class = ("withdrawal_paths",)

    def format(self):
        return "<withdrawal_paths: %s>" % ", ".join(self.keys())


def bootstrap_pooled(datasets, columns, *, weights=None, inflation=None, frequency=("year", "quarter", "month"),
                     n=1000, years=30, L=None, country_weights=None, target=None, seed=None):
    """Länder-Bootstrap für lange Horizonte.

    Stationärer Block-Bootstrap über mehrere Länder: Jeder Block stammt aus einem zufällig gezogenen Land
    (Standard: gleich wahrscheinlich) und beginnt an einer zufälligen Stelle seiner Historie; Blockgrenzen sind
    geometrisch verteilt (Politis & Romano 1994). Innerhalb eines Blocks bleiben alle Spalten eines Landes
    gemeinsam (Aktien, Anleihen, Inflation). So gehen auch Märkte mit schlechten Phasen (Kriege, Hyperinflation,
    lange Baissen) in die Planung ein - US-Daten allein überschätzen langfristige Renditen (Anarkulova, Cederburg
    & O'Doherty 2022).

    Args:
        datasets: Benannte Liste von DataFrames (Name = Land), jeweils mit Spalte ``date`` (Klasse Date oder
            umwandelbar), den Kursspalten aus ``columns`` (Total-Return-Niveaus, keine Renditen) und ggf. der
            Preisindex-Spalte aus ``inflation``. Jedes Land braucht mindestens 2 vollständige Periodenrenditen.
        columns: Zeichenvektor der Kursspalten (in allen Ländern gleich benannt).
        weights: Vektor der Portfolio-Gewichte (>= 0) mit einem Eintrag je Spalte aus ``columns``: benannt mit
            genau diesen Spaltennamen oder unbenannt in der Reihenfolge von ``columns`` (wird auf Summe 1
            normiert; Rebalancing auf die Gewichte in jeder Periode). ``None`` (Standard) = gleiche Gewichte. Die
            Portfoliorendite ist die Renditequelle für ``withdrawal_simulation()``.
        inflation: ``None`` (Standard; keine Inflation, Faktor 1) oder Name einer Preisindex-Spalte (Niveau, z. B.
            CPI), die in allen Ländern vorhanden ist. Sie wird im selben Block wie die Kurse gezogen.
        frequency: Periodenlänge: ``"year"`` (Standard), ``"quarter"`` oder ``"month"``.
        n: Anzahl simulierter Pfade (Standard 1000).
        years: Länge jedes Pfads in Jahren (Standard 30); ergibt ``years`` x Perioden je Jahr (1, 4 bzw. 12)
            Perioden.
        L: Mittlere Blocklänge in Perioden der gewählten ``frequency`` (Blocklänge = 1 + geometrisch verteilte
            Zahl mit Mittel ``L`` - 1). ``None`` (Standard) = 10 Jahre, also 10 Jahre, 40 Quartale bzw. 120
            Monate.
        country_weights: Numerischer Vektor der Ziehungswahrscheinlichkeiten je Land in der Reihenfolge von
            ``datasets`` (wird auf Summe 1 normiert). ``None`` (Standard) = alle Länder gleich wahrscheinlich.
        target: Optional Renditeannahmen in Prozent p. a. (geometrisch): Skalar für alle ``columns`` oder
            benannter Vektor je Spalte. Die Verschiebung wird über die gepoolten Renditen aller Länder bestimmt
            und für alle Länder gleich angewendet (wie ``series_shift_return()``). ``None`` (Standard) =
            historische Renditen.
        seed: Startwert der Ziehung (Standard ``None``). Mit Startwert (ganze Zahl, |seed| < 2^53) ist das
            Ergebnis reproduzierbar und der Zufallszustand von SimLev bleibt unverändert; mit ``None`` wird genau
            einmal ein Startwert aus dem Zufallszustand von SimLev gezogen (siehe ``simlev_seed()``), wiederholte
            Aufrufe liefern dann verschiedene Ergebnisse. ``set.seed()`` wirkt nicht.

    Returns:
        Objekt der Klasse ``withdrawal_paths`` (Liste) mit ``returns`` (Matrix Perioden x Pfade der
        Brutto-Portfoliorenditen), ``inflation`` (Matrix gleicher Form, Brutto-Inflation je Periode; ohne
        ``inflation`` überall 1), ``frequency``, ``source = "pooled_bootstrap"``, ``historical = False``,
        ``cape``, ``base_rate``, ``start_dates``, ``weights`` (alle ``None``) sowie den zusätzlichen Elementen
        ``assets`` (benannte Liste der Brutto-Renditematrizen je Spalte aus ``columns``), ``countries``
        (Zeichenmatrix Perioden x Pfade: gezogenes Land) und ``country_names``.

    Details:
        Die Kursreihen jedes Landes werden zuerst auf Periodenrenditen der gewählten ``frequency`` verdichtet
        (Wert am letzten Datum jeder Kalenderperiode; eine unvollständige letzte Periode zählt mit; nur Perioden
        ohne fehlende Werte). Ein Block beginnt an einer zufälligen Periode und läuft am Ende der Landeshistorie
        zyklisch am Anfang weiter. Das Ergebnis ist ein ``withdrawal_paths``-Objekt und kann direkt an
        ``withdrawal_simulation()``, ``withdrawal_max_rate()`` oder ``withdrawal_perfect_rate()`` übergeben
        werden.

    Literatur:
        Anarkulova, A., Cederburg, S. & O'Doherty, M. S. (2022), Stocks for the long run? Evidence from a broad
        sample of developed markets, Journal of Financial Economics 143(1), 409-433.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        def land(mu):
            return pd.DataFrame({"date": pd.date_range("1950-12-31", periods=70, freq="YE"),
                                 "aktien": 100 * np.cumprod(np.exp(rng.normal(mu, 0.18, 70))),
                                 "anleihen": 100 * np.cumprod(np.exp(rng.normal(0.02, 0.06, 70))),
                                 "cpi": 100 * np.cumprod(np.exp(rng.normal(0.025, 0.02, 70)))})
        pb = simlev.bootstrap_pooled({"de": land(0.05), "us": land(0.07)}, ["aktien", "anleihen"],
                                     weights={"aktien": 0.6, "anleihen": 0.4}, inflation="cpi", n=200, years=30, L=5, seed=1)
        print(pb["returns"].shape)   # 30 Jahre x 200 Pfade
    """
    frequency = _match_arg(frequency, ("year", "quarter", "month"))
    if not isinstance(datasets, Mapping) or any(str(k) == "" for k in datasets.keys()):
        raise ValueError("datasets muss eine benannte Liste sein (Land -> data.frame).")
    columns = [columns] if isinstance(columns, str) else list(columns)
    ppy = _wd_ppy(frequency)
    if weights is not None:
        wv, wn = _numvals(weights)
        if (not _all_num(wv) or len(wv) != len(columns) or np.isnan(_as_num(wv)).any() or (_as_num(wv) < 0).any()
                or r_sum(_as_num(wv)) <= 0):
            raise ValueError("weights muss je Spalte aus columns (%d) ein Gewicht >= 0 enthalten (Summe > 0)." % len(columns))
        wv = _as_num(wv)
        if wn is None:
            wn = list(columns)
        elif set(wn) != set(columns):
            raise ValueError("Namen von weights (%s) passen nicht zu columns (%s)." % (", ".join(wn), ", ".join(columns)))
        weights = (wn, wv)
    cols = columns + ([inflation] if inflation is not None else [])
    ctry_names = [str(k) for k in datasets.keys()]
    G = [np.array(_period_gross(df, cols, frequency).to_numpy(dtype=np.float64)) for df in datasets.values()]
    if any(g.shape[0] < 2 for g in G):
        raise ValueError("Ein Land hat zu wenige Perioden.")
    ci = {c: i for i, c in reversed(list(enumerate(cols)))}
    if target is not None:
        tv, tn = _numvals(target)
        tv = _as_num(tv)
        if len(tv) == 1 and tn is None:
            tg = [(c, float(tv[0])) for c in columns]
        else:
            tg = list(zip(tn, tv.tolist())) if tn is not None else []
        for k, t in tg:
            j = ci[k]
            all_lr = np.concatenate([_libm.log(g[:, j]) for g in G])
            delta = float(_libm.log1p(t / 100)) / ppy - r_mean(all_lr)
            ed = float(_libm.exp(delta))
            for g in G:
                g[:, j] = g[:, j] * ed
    if L is None:
        L = 10 * ppy
    L = float(L)
    nper = int(years * ppy)
    nc = len(G)
    cw = np.repeat(1 / nc, nc) if country_weights is None else np.asarray(country_weights, dtype=np.float64).ravel()
    cw = cw / r_sum(cw)
    nrs = [g.shape[0] for g in G]

    def draw_all(S):
        out = []
        for _ in range(int(n)):
            ctry = np.zeros(nper, dtype=np.int64)
            row = np.zeros(nper, dtype=np.int64)
            t = 1
            while t <= nper:
                cidx = int(_sl.sample(nc, 1, prob=cw, stream=S)[0])
                ln = 1 + float(_sl.rgeom(1, 1 / L, stream=S)[0])
                nr = nrs[cidx - 1]
                st = int(_sl.sample(nr, 1, stream=S)[0])
                take = int(min(ln, nper - t + 1))
                idx = ((st - 1 + np.arange(1, take + 1) - 1) % nr) + 1
                ctry[t - 1:t - 1 + take] = cidx
                row[t - 1:t - 1 + take] = idx
                t += take
            out.append((ctry, row))
        return out

    draw = draw_all(_sl.main_stream(seed))          # Hauptstrom
    Gall = np.vstack(G)
    off = np.concatenate([[0], np.cumsum(nrs)])[:nc]
    gi = np.column_stack([off[c - 1] + r for c, r in draw]) if draw else np.zeros((nper, 0), dtype=np.int64)
    A = {k: Gall[gi - 1, j].reshape(nper, int(n)) for k, j in ((c, ci[c]) for c in dict.fromkeys(cols))}
    if weights is None:
        wn, wv = list(columns), np.repeat(1 / len(columns), len(columns))
    else:
        wn, wv = weights
        wv = wv / r_sum(wv)
    Rp = None
    for k, wk in zip(wn, wv):
        term = wk * A[k]
        Rp = term if Rp is None else Rp + term
    Inf_m = A[inflation] if inflation is not None else np.ones((nper, int(n)))
    cmat = np.array([[ctry_names[c - 1] for c in col] for col in (dr[0] for dr in draw)], dtype=object).T \
        if draw else np.zeros((nper, 0), dtype=object)
    cls = _paths_class()
    return cls([("returns", Rp), ("inflation", Inf_m), ("cape", None), ("base_rate", None), ("frequency", frequency),
                ("historical", False), ("start_dates", None), ("weights", None), ("source", "pooled_bootstrap"),
                ("assets", {k: A[k] for k in columns}), ("countries", cmat), ("country_names", ctry_names)])


# ═══════════════════════════════════════════════════════════════════════════
# portfolio_returns
# ═══════════════════════════════════════════════════════════════════════════

def _dgemv_n(A, x):
    """``A %m% x`` (Matrix mal Vektor) wie R (slc-Matrixprodukt)."""
    r = _sl.matmul(A, x.reshape(-1, 1))
    return np.asarray(r.to_numpy() if isinstance(r, pd.DataFrame) else r, dtype=np.float64).ravel()


def portfolio_returns(data, candidates, *, frequency=("year", "quarter", "month")):
    """Periodenrenditen von Kandidaten-Portfolios (feste Gewichte, Rebalancing je Periode).

    Berechnet aus Kursreihen die Brutto-Periodenrenditen mehrerer Kandidaten-Portfolios mit festen Gewichten
    (Rebalancing auf die Gewichte zu Beginn jeder Periode). Eingabe ist ein DataFrame mit Spalte ``date`` (Klasse
    Date) und Kursspalten (Niveaus, keine Renditen); Periodenwerte sind die Kurse am letzten Datum jeder
    Kalenderperiode (fehlende Kurse werden fortgeschrieben, eine unvollständige letzte Periode zählt mit). Das
    Ergebnis dient als Szenario-Stichprobe für ``planning_goal()``.

    Args:
        data: DataFrame mit Spalte ``date`` und allen in ``candidates`` genannten Kursspalten (Niveaus).
        candidates: Liste von benannten Gewichtsvektoren (Namen = Kursspalten; je Kandidat auf Summe 1 normiert),
            z. B. aus ``lapply(seq(0, 1, 0.1), function(a) {"aktien": a, "anleihen": 1 - a})``. Die Listennamen
            werden Spaltennamen des Ergebnisses; ohne Namen ``"P1"``, ``"P2"``, ...
        frequency: Periodenlänge und Rebalancing-Rhythmus: ``"year"`` (Standard), ``"quarter"`` oder ``"month"``.

    Returns:
        Numerische Matrix Perioden x Kandidaten mit Brutto-Renditen (z. B. 1.05 = +5 %); nur Perioden, in denen
        alle beteiligten Kursspalten Werte haben.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 3650
        d = pd.DataFrame({"date": pd.date_range("2010-01-01", periods=n)})
        d["aktien"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        d["anleihen"] = 100 * np.cumprod(1 + rng.normal(1e-4, 0.002, n))
        cand = {"a20": {"aktien": 0.2, "anleihen": 0.8}, "a60": {"aktien": 0.6, "anleihen": 0.4}}
        print(simlev.portfolio_returns(d, cand)[:3])
    """
    frequency = _match_arg(frequency, ("year", "quarter", "month"))
    if isinstance(candidates, Mapping):
        cnames = [str(k) for k in candidates.keys()]
        cands = list(candidates.values())
    else:
        cands = list(candidates)
        cnames = ["P%d" % (i + 1) for i in range(len(cands))]
    ws = []
    for w in cands:
        wv, wn = _numvals(w)
        ws.append((wn, _as_num(wv)))
    a = list(dict.fromkeys(k for wn, _ in ws for k in (wn or [])))
    G = _period_gross(data, a, frequency)
    Gm = G.to_numpy(dtype=np.float64)
    cols = []
    for wn, wv in ws:
        sub = np.column_stack([Gm[:, a.index(k)] for k in wn]) if wn else np.zeros((Gm.shape[0], 0))
        cols.append(_dgemv_n(sub, wv / r_sum(wv)))
    M = np.column_stack(cols) if cols else np.zeros((Gm.shape[0], 0))
    return pd.DataFrame(M, columns=cnames)


# ═══════════════════════════════════════════════════════════════════════════
# planning_goal
# ═══════════════════════════════════════════════════════════════════════════

def _fmt_vals(v):
    a = np.atleast_1d(np.asarray(v, dtype=object)).ravel()
    try:
        f = np.asarray(a, dtype=np.float64)
        out = _fmt.format(f) if f.size != 1 else _fmt.format(float(f[0]))
    except (TypeError, ValueError):
        out = _fmt.format(a)
    return ", ".join(str(s) for s in np.atleast_1d(out))


def planning_goal(returns, start_value, goal, horizon, *, contributions=0, n_grid=301, n_sim=5000, seed=None):
    """Zielbasierte Allokation per dynamischer Programmierung (Das et al. 2020).

    Bestimmt für jeden Zeitpunkt und jedes Vermögen das Portfolio aus einer Kandidatenliste, das die
    Wahrscheinlichkeit maximiert, zum Horizont ein Zielvermögen zu erreichen (Das et al. 2020). Ein- und
    Auszahlungen je Periode sind möglich; mit Auszahlungen und ``goal = 0`` wird die Wahrscheinlichkeit maximiert,
    dass das Geld bis zum Horizont reicht. Die Renditen werden je Periode aus der Stichprobe ``returns`` gezogen
    (unabhängig über die Zeit; Zeilen = Szenarien, gemeinsam über die Kandidaten). Die Wertfunktion wird auf einem
    logarithmischen Vermögensraster gespeichert und dazwischen linear in log(Vermögen) auf der Probit-Skala
    (``qnorm`` der Wahrscheinlichkeit) interpoliert; in der letzten Periode wird die 0/1-Zielbedingung exakt
    ausgewertet.

    Args:
        returns: Numerische Matrix (Szenarien x Kandidaten) von Brutto-Periodenrenditen (z. B. 1.05 = +5 %), z. B.
            aus ``portfolio_returns()`` (historische Perioden) oder aus Bootstrap-Pfaden. Jede Zeile ist ein
            gleich wahrscheinliches Szenario für eine Periode. Spaltennamen benennen die Kandidaten (fehlen sie:
            ``"P1"``, ``"P2"``, ...); für die Grafik aufsteigend nach Risiko sortieren.
        start_value: Startvermögen (Geldbetrag, > 0).
        goal: Zielvermögen zum Horizont (Geldbetrag in denselben Einheiten wie ``start_value``; real oder nominal,
            passend zu den Renditen). Erfolg heißt Endvermögen >= ``goal``.
        horizon: Anzahl Perioden bis zum Ziel (ganze Zahl >= 1; Periodenlänge wie die Zeilen von ``returns``, z.
            B. Jahre bei Jahresrenditen). Nicht zu verwechseln mit ``horizon`` in ``withdrawal_simulation()``
            (Objekt aus ``withdrawal_horizon()`` oder Jahre).
        contributions: Zahlung je Periode als Geldbetrag (Standard 0): Skalar oder Vektor (wird mit ``rep_len()``
            auf ``horizon`` Perioden gebracht); positiv = Einzahlung, negativ = Entnahme, jeweils zu
            Periodenbeginn vor der Rendite.
        n_grid: Anzahl Punkte des logarithmischen Vermögensrasters (Standard 301, mindestens 2; dazu Ziel und
            Startwert); mehr Punkte = genauer, aber langsamer.
        n_sim: Anzahl Pfade der Vorwärtssimulation der optimalen Politik (Standard 5000).
        seed: Startwert für die Vorwärtssimulation (Standard ``None``). Mit Startwert (ganze Zahl, |seed| < 2^53)
            ist das Ergebnis reproduzierbar und der Zufallszustand von SimLev bleibt unverändert; mit ``None``
            wird genau einmal ein Startwert aus dem Zufallszustand von SimLev gezogen (siehe ``simlev_seed()``),
            wiederholte Aufrufe liefern dann verschiedene Ergebnisse. ``set.seed()`` wirkt nicht.

    Returns:
        Objekt der Klasse ``SimLevGoalPlan`` (Liste):

        - ``probability``: Zielwahrscheinlichkeit der gefundenen Politik als Anteil (0.8 = 80 Prozent):
          Erfolgsquote der Vorwärtssimulation (``mean(simulation["success"])``, siehe Details, Verzerrung).
        - ``probability_se``: Standardfehler von ``probability`` (Anteil, aus ``n_sim``).
        - ``probability_dp``: Wert der dynamischen Programmierung (Anteil; Näherung, meist über dem Optimum).
        - ``static``: Benannter Vektor: Zielwahrscheinlichkeit (Anteil), wenn durchgehend derselbe Kandidat
          gehalten wird.
        - ``policy``: Ganzzahlige Matrix Perioden x Rasterpunkte: Nummer des optimalen Kandidaten (Spalte von
          ``returns``).
        - ``grid``: Vermögensraster (Geldbeträge, aufsteigend; Länge ``n_grid`` plus Ziel und Startwert).
        - ``value``: Liste der Länge ``horizon + 1``: Element ``t`` ist die Zielwahrscheinlichkeit je Rasterpunkt
          zu Beginn von Periode ``t`` (letztes Element: 0/1 am Horizont).
        - ``simulation``: Liste mit ``terminal`` (Endvermögen je Pfad), ``choice`` (Matrix Perioden x Pfade:
          gewählter Kandidat) und ``success`` (logisch: nie ruiniert und Endvermögen >= ``goal``).
        - ``goal``, ``start_value``, ``horizon``: Eingaben.
        - ``contributions``: Zahlungen je Periode (Länge ``horizon``).
        - ``candidates``: Namen der Kandidaten.

        Ausgabe mit ``print()``, Grafik der Politik mit ``plot()``.

    Details:
        Das Raster reicht logarithmisch gleichabständig von ``max(1e-6, m / 1000)`` (m = kleinster positiver Wert
        von ``goal`` und ``start_value``) bis ``20 * max(goal, start_value)``; ``goal`` (falls > 0) und
        ``start_value`` sind zusätzlich exakte Rasterpunkte. Fällt das Vermögen nach einer Zahlung auf 0 oder
        darunter, gilt der Pfad als gescheitert. Bei Gleichstand (Unterschied unter 1e-9) wählt die Politik den
        Kandidaten mit der geringsten Streuung der Log-Renditen. Die Vorwärtssimulation wendet die Politik auf
        ``n_sim`` zufällige Pfade an (Kandidat des nächstniedrigeren Rasterpunkts des Vermögens vor der Zahlung).

        Verzerrung: Der DP-Wert (``probability_dp``) ist eine Näherung des Optimums und liegt typischerweise
        darüber, weil die interpolierte Wertfunktion die Zielstufe zwischen den Rasterpunkten glättet und das
        Maximum über Kandidaten diese Fehler bevorzugt (bei grobem Raster einige Prozentpunkte). Gemeldet wird
        daher als ``probability`` die in der Vorwärtssimulation erreichte Erfolgsquote der gefundenen Politik:
        eine unverzerrte Schätzung der Zielwahrscheinlichkeit einer tatsächlich umsetzbaren Politik, also im
        Erwartungswert höchstens das Optimum (Stichprobenfehler ``probability_se``). Weicht der DP-Wert um mehr
        als 4 Standardfehler plus 1 Prozentpunkt davon ab, warnt die Funktion (``n_grid`` erhöhen). Auch
        ``static`` beruht auf der interpolierten Wertfunktion und kann leicht überschätzt sein.

    Literatur:
        Das, S. R., Ostrov, D., Radhakrishnan, A. & Srivastav, D. (2020), Dynamic portfolio allocation in
        goals-based wealth management, Computational Management Science 17, 613-640.

    Beispiel::

        import numpy as np, simlev
        rng = np.random.default_rng(1)
        a = np.array([0.2, 0.6, 1.0])
        R = np.exp(rng.normal(0.01 + 0.04 * a, 0.02 + 0.16 * a, (500, 3)))
        gp = simlev.planning_goal(R, 100000, 150000, 10, contributions=2000, n_grid=101, n_sim=1000, seed=1)
        print(gp["probability"])
    """
    if isinstance(returns, pd.DataFrame):
        cn0 = [str(c) for c in returns.columns] if not isinstance(returns.columns, pd.RangeIndex) else None
        try:
            R = returns.to_numpy(dtype=np.float64, na_value=NA_REAL)
            isnum = all(pd.api.types.is_numeric_dtype(t) and not pd.api.types.is_bool_dtype(t) for t in returns.dtypes)
        except (TypeError, ValueError):
            R, isnum = None, False
    else:
        a = np.asarray(returns)
        if a.ndim == 1:
            a = a.reshape(-1, 1)
        isnum = a.dtype.kind in "iuf"
        R = a.astype(np.float64) if isnum else None
        cn0 = None
    S, K = (R.shape if R is not None else (0, 0))
    if not isnum or not S or not K or (~np.isfinite(R)).any() or (R < 0).any():
        raise ValueError("returns muss eine Matrix (Szenarien x Kandidaten) endlicher Brutto-Renditen >= 0 ohne NA sein "
                         "(z. B. 1.05).")

    def num1(v):
        a = np.atleast_1d(np.asarray(v, dtype=object)).ravel()
        return len(a) == 1 and _is_num_scalar(a[0]) and math.isfinite(float(a[0]))

    if not num1(start_value) or float(np.ravel(start_value)[0]) <= 0:
        raise ValueError("start_value muss ein Geldbetrag > 0 sein (erhalten: %s)." % _fmt_vals(start_value))
    if not num1(goal) or float(np.ravel(goal)[0]) < 0:
        raise ValueError("goal muss ein Geldbetrag >= 0 sein (erhalten: %s)." % _fmt_vals(goal))
    if not num1(horizon) or float(np.ravel(horizon)[0]) < 1 or float(np.ravel(horizon)[0]) != _fmt.r_round(float(np.ravel(horizon)[0])):
        raise ValueError("horizon muss eine ganze Zahl >= 1 sein (Anzahl Perioden; erhalten: %s)." % _fmt_vals(horizon))
    if not num1(n_grid) or float(np.ravel(n_grid)[0]) < 2:
        raise ValueError("n_grid muss eine ganze Zahl >= 2 sein (erhalten: %s)." % _fmt_vals(n_grid))
    if not num1(n_sim) or float(np.ravel(n_sim)[0]) < 1:
        raise ValueError("n_sim muss eine ganze Zahl >= 1 sein (erhalten: %s)." % _fmt_vals(n_sim))
    cv = np.atleast_1d(np.asarray(contributions.to_numpy() if isinstance(contributions, pd.Series) else contributions,
                                  dtype=object)).ravel()
    if not _all_num(cv) or not len(cv) or (~np.isfinite(_as_num(cv))).any():
        raise ValueError("contributions muss ein endlicher Geldbetrag oder Vektor von Geldbeträgen sein.")
    start_value = float(np.ravel(start_value)[0])
    goal = float(np.ravel(goal)[0])
    horizon = int(float(np.ravel(horizon)[0]))
    n_grid = float(np.ravel(n_grid)[0])
    n_sim = int(float(np.ravel(n_sim)[0]))
    cn = cn0 if cn0 is not None else ["P%d" % (j + 1) for j in range(K)]
    cvf = _as_num(cv)
    cf = np.array([cvf[i % len(cvf)] for i in range(horizon)], dtype=np.float64)
    wmax = max(goal, start_value) * 20
    pos = [v for v in (goal, start_value) if v > 0]
    wmin = max(1e-6, min(pos) / 1000)
    lg = _stats("seq_len_out")(float(_libm.log(wmin)), float(_libm.log(wmax)), int(math.ceil(n_grid)))
    pts = list(_libm.exp(np.asarray(lg, dtype=np.float64)))
    if goal > 0:
        pts.append(goal)
    pts.append(start_value)
    grid = np.array(sorted(set(float(p) for p in pts)), dtype=np.float64)
    ng = len(grid)
    lgrid = _libm.log(grid)

    # Rückwärtsrekursion im Kern (core/research_core_impl.h, goal_dp; bis 1.4.3 hier in Python); Gleichstand
    # (innerhalb 1e-9): Kandidat mit der geringsten Streuung der Log-Renditen
    lr = _libm.log(np.maximum(R, 1e-300))
    sds = np.array([r_sd(lr[:, j]) for j in range(K)])
    risk_rank = np.empty(K, dtype=np.int64)
    risk_rank[np.argsort(sds, kind="stable")] = np.arange(1, K + 1)
    dp = _dcore.goal_dp(R, grid, cf, goal, wmin, wmax, start_value, (K + 1 - risk_rank).astype(np.float64))
    for _ in range(dp["collapsed"]):                     # wie stats::approx bei gleichen log(grid)-Werten
        _rwarn("collapsing to unique 'x' values")
    static = dp["static"]
    pol = dp["policy"]
    Vt = [dp["value"][:, t].copy() for t in range(horizon + 1)]
    p_dp = float(dp["p_dp"])

    def run(st):
        W = np.repeat(start_value, n_sim)
        choice = np.zeros((horizon, n_sim), dtype=np.int64)
        ruined = np.zeros(n_sim, dtype=bool)
        for t in range(horizon):
            base = W + cf[t]
            alive = (base > 0) & ~ruined
            ruined = ruined | ~alive
            g = np.maximum(1, np.minimum(ng, np.searchsorted(lgrid, _libm.log(np.maximum(W, wmin)), side="right")))
            k = pol[t, g - 1]
            choice[t, :] = k
            draw = _sl.sample(S, n_sim, replace=True, stream=st)
            W = np.where(alive, base * R[draw - 1, k - 1], 0.0)
        return {"terminal": W, "choice": choice, "success": ~ruined & (W >= goal)}

    sim = run(_sl.main_stream(seed))                # Hauptstrom
    p_sim = _mean_lgl(sim["success"])
    se = math.sqrt(p_sim * (1 - p_sim) / n_sim)
    tol = 4 * math.sqrt(max(p_sim * (1 - p_sim), 1 / n_sim) / n_sim) + 0.01
    if abs(p_dp - p_sim) > tol:
        warnings.warn(_sp("planning_goal: DP-Wert %.1f %% weicht von der Vorwärtssimulation %.1f %% ab; "
                          "probability ist der simulierte Wert (n_grid erhöhen).", 100 * p_dp, 100 * p_sim))
    return SimLevGoalPlan([
        ("probability", p_sim), ("probability_se", se), ("probability_dp", p_dp),
        ("static", pd.Series(static, index=cn)), ("policy", pol), ("grid", grid), ("value", Vt),
        ("simulation", sim), ("goal", goal), ("start_value", start_value), ("horizon", horizon),
        ("contributions", cf), ("candidates", cn)])


def _eur(v):
    a = _fmt.r_round(np.atleast_1d(np.asarray(v, dtype=np.float64)))
    out = _fmt.formatC(a, format="d", big_mark=" ")
    return [str(s) for s in np.atleast_1d(out)]


class SimLevGoalPlan(RList):
    """Ergebnis von :func:`planning_goal` (R-Klasse ``SimLevGoalPlan``)."""

    r_class = ("SimLevGoalPlan",)

    def format(self):
        cf = np.asarray(self["contributions"], dtype=np.float64)
        pay = ""
        if (cf != 0).any():
            pay = ", Zahlungen %s je Periode" % "/".join(_eur(list(dict.fromkeys(cf.tolist()))))
        out = [_sp("Zielplanung: Ziel %s in %d Perioden, Start %s%s\n", _eur(self["goal"])[0], int(self["horizon"]),
                   _eur(self["start_value"])[0], pay)]
        pse = self.get("probability_se")
        out.append(_sp("Zielwahrscheinlichkeit dynamisch: %.1f %% (Vorwärtssimulation, SE %.1f Prozentpunkte; "
                       "DP-Wert %.1f %%)\n", 100 * self["probability"], 100 * (_NAN if pse is None else pse),
                       100 * self["probability_dp"]))
        st = self["static"]
        sv = np.asarray(st, dtype=np.float64)
        best = int(np.argmax(sv))
        out.append(_sp("Bester fester Kandidat: %s mit %.1f %%\n\n", str(st.index[best]), 100 * sv[best]))
        out.append(_fmt.print_vector(pd.Series(_fmt.r_round(100 * sv, 1), index=list(st.index))) + "\n")
        cands = list(self["candidates"])
        first = np.asarray(self["simulation"]["choice"])[0, :]
        cnt = np.bincount(first - 1, minlength=len(cands))
        out.append("\nWahl im ersten Schritt: %s" % cands[int(np.argmax(cnt))])
        return "".join(out)

    # ``plot`` (SVG, ``SimLevPlot``) wird am Modulende über ``_plot_method`` gesetzt.


def _plot_goalplan(x):
    """``plot.SimLevGoalPlan`` (SVG): optimale Kandidatenwahl je Periode und Vermögen (log10).

    Zeichnet wie Julia mit den Bausteinen der Analysegrafiken aus svg.py (``_AnaSvg``, ``_ana_panel``,
    ``_ana_rect``, …).
    Liefert ``(svg, data)``: ``policy`` mit den gezeichneten Zellen (``period``, ``wealth`` = Gitterwert,
    ``choice`` = Nummer des Kandidaten, ``candidate`` = sein Name).
    """
    g = np.asarray(_goal_grid(x), dtype=np.float64)
    goal = float(x["goal"])
    keep = [i for i, v in enumerate(g.tolist()) if v >= goal / 20 and v <= goal * 3]
    P = np.asarray(x["policy"])[:, keep]
    cands = [str(c) for c in np.atleast_1d(x["candidates"])]
    K = len(cands)
    H = int(x["horizon"])
    pal = _ana_ramp(["#2C6E9B", "#F2E9DC", "#B5562B"], max(K, 1))
    gk = g[keep]
    lg = [math.log10(v) for v in gk.tolist()]
    s = _AnaSvg(900, 520)
    yr = (0.0, 1.0) if not lg else (min(lg), max(lg))
    p = _ana_panel(s, 0, 0, 800, 520, (0.5, H + 0.5), yr, title="Optimale Wahl je Zeit und Vermögen",
                   xlab="Periode", ylab="Vermögen (log10)", xticks=list(range(1, H + 1)))
    nq = len(lg)
    for t in range(1, H + 1):
        for q, y in enumerate(lg):
            lo = y if q == 0 else (lg[q - 1] + y) / 2
            hi = y if q == nq - 1 else (lg[q + 1] + y) / 2
            _ana_rect(s, p, t - 0.5, lo, t + 0.5, hi, fill=pal[min(max(int(P[t - 1, q]), 1), len(pal)) - 1])
    if goal > 0:
        _ana_hline(s, p, math.log10(goal), col="#000", dash="5,4")
    _ana_legend(s, p, cands, pal, x=800.0, y=50.0, box=True)
    ch = [int(P[t, q]) for t in range(H) for q in range(nq)]
    data = {"policy": pd.DataFrame({"period": np.array([t + 1 for t in range(H) for _ in range(nq)], dtype=np.int64),
                                    "wealth": np.array([gk[q] for _ in range(H) for q in range(nq)], dtype=np.float64),
                                    "choice": np.array(ch, dtype=np.int64),
                                    "candidate": [cands[min(max(c, 1), K) - 1] for c in ch]})}
    return _ana_svg_done(s), data


def _goal_grid(x):
    """Vermögensgitter als Zahlen (``DA._f64(x$grid)``)."""
    return [NA_REAL if v is None else float(v) for v in np.atleast_1d(x["grid"]).tolist()]


# plot.SimLevGoalPlan (SVG, ``SimLevPlot``) wie Julias ``_plot_method(_plot_goalplan, "SimLevGoalPlan")``
from .svg import _plot_method  # noqa: E402

SimLevGoalPlan.plot = _plot_method(_plot_goalplan, "SimLevGoalPlan")


from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__ + ["_period_gross"])
