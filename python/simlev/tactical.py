"""Taktische Allokation über zeitvariable Zielgewichte (Port von ``r/R/tactical.R``).

Gewichts-Erzeuger (liefern ein :class:`SimLevWeights`: ``DataFrame(date, Asset…)``
mit dem Zielgewicht, das nach Schlusskurs des Tages bekannt ist):

- :func:`tactical_rules`          geordnete Bedingungen -> Zielportfolio, Rückfall
- :func:`tactical_rotation`       Momentum-Rotation: Top-N, Dual Momentum,
  Canary-/Breitenschutz (Keller & Keuning)
- :func:`tactical_target_volatility`       Zielvolatilität (Moreira & Muir 2017)
- :func:`tactical_conditional_volatility`  nur in extremen Volatilitätsphasen skalieren
  (Bongaerts, Kang & van Dijk 2020)
- :func:`tactical_glidepath`               Gewichte zeitlich zwischen zwei Allokationen
- :func:`tactical_blend`           Kern-Satellit: Mischung mehrerer Gewichtsreihen
- :func:`signal_state`            Kauf-/Verkaufssignale -> dauerhafter Zustand
- :func:`momentum_score`          Momentum-Score je Anlage

Ausführung: :func:`tactical_simulation` übersetzt die Gewichte in
``event_col``/``event_weight`` von :func:`simlev.simulation`.

Attribute der R-Objekte (``attr(w, "regime")`` usw.) stehen in ``w.attrs``.
"""
from __future__ import annotations

import math
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

from ._r import fmt as _fmt
from ._r.base import env_from_caller
from ._r import libm as _libm
from .svg import _alloc_c, _alloc_ramp, _esc, _jl_str, _jl_unique


class _Missing:
    """Platzhalter für ein R-Argument ohne Standardwert (Gegenstück zu R's fehlendem Argument)."""

    def __repr__(self):
        return "<missing>"


_MISSING = _Missing()

__all__ = ["SimLevWeights", "signal_state", "momentum_score", "tactical_rules", "tactical_rotation",
           "tactical_target_volatility", "tactical_conditional_volatility", "tactical_glidepath", "tactical_blend",
           "tactical_simulation", "print_SimLevWeights", "plot_SimLevWeights"]

LD = np.longdouble
_NAN = float("nan")      # R's NaN
_NA = _fmt.NA_REAL       # R's NA_real_

_EPOCH = np.datetime64("1970-01-01", "D")


# ═══════════════════════════════════════════════════════════════════════════
# R-Hilfen
# ═══════════════════════════════════════════════════════════════════════════

def _warn(msg):
    warnings.warn(msg, UserWarning, stacklevel=3)


def _message(msg):
    from .data_prep import message
    message(msg)


def _match_arg(arg, choices):
    from .data_prep import _match_arg as m
    return m(arg, choices)


def _to_date(x, what="date"):
    from .data_prep import _to_date as f
    return f(x, what)


def _fill_na(v, method="locf", keep_leading=False):
    from .backcast import _fill_na as f
    return np.asarray(f(v, method, keep_leading=keep_leading), dtype=np.float64)


def _days(d):
    """datetime64[D]-Array -> float-Tage (NaT -> nan)."""
    a = np.asarray(d).astype("datetime64[D]")
    out = (a - _EPOCH).astype(np.int64).astype(np.float64)
    out[np.isnat(a)] = _NA
    return out


def _as_dates(days):
    a = np.asarray(days, dtype=np.float64)
    out = np.full(a.shape, np.datetime64("NaT", "D"), dtype="datetime64[D]")
    ok = ~np.isnan(a)
    out[ok] = _EPOCH + a[ok].astype(np.int64).astype("timedelta64[D]")
    return out


def _find_interval(x, vec):
    """``findInterval(x, vec)`` (vec aufsteigend): Anzahl vec <= x (1-basiert)."""
    return np.searchsorted(np.asarray(vec, dtype=np.float64), np.asarray(x, dtype=np.float64), side="right")


def _rowsums(M):
    """``rowSums`` (long double, spaltenweise)."""
    M = np.asarray(M, dtype=np.float64)
    if M.ndim == 1:
        M = M.reshape(-1, 1)
    acc = np.zeros(M.shape[0], dtype=LD)
    for j in range(M.shape[1]):
        acc = acc + M[:, j].astype(LD)
    return acc.astype(np.float64)


def _rowmeans(M):
    M = np.asarray(M, dtype=np.float64)
    acc = np.zeros(M.shape[0], dtype=LD)
    for j in range(M.shape[1]):
        acc = acc + M[:, j].astype(LD)
    return (acc / LD(M.shape[1])).astype(np.float64)


def _colmeans(M):
    M = np.asarray(M, dtype=np.float64)
    if M.shape[0] == 0:
        return np.full(M.shape[1], _NAN)
    s = np.cumsum(M.astype(LD), axis=0)[-1]
    return (s / LD(M.shape[0])).astype(np.float64)


def _ldsum(x):
    """``sum(x)`` (long double, sequenziell)."""
    a = np.asarray(x, dtype=np.float64).ravel()
    if a.size == 0:
        return 0.0
    return float(np.cumsum(a.astype(LD))[-1])


def _mean_int(x):
    """``mean`` eines logischen/ganzzahligen Vektors (long double Summe / n)."""
    a = np.asarray(x).ravel().astype(np.int64)
    if a.size == 0:
        return _NAN
    return float(LD(int(a.sum())) / LD(a.size))


def _is_null(x):
    return x is None


def _length(x):
    if x is None:
        return 0
    if isinstance(x, str):
        return 1
    if isinstance(x, Mapping):
        return len(x)
    if np.ndim(x) == 0:
        return 1
    return len(x)


def _chr_vec(x):
    """Zeichenvektor (``NULL`` -> leer)."""
    if x is None:
        return []
    if isinstance(x, str):
        return [x]
    if isinstance(x, pd.Series):
        return [str(v) for v in x.to_list()]
    return [str(v) for v in np.asarray(x, dtype=object).ravel()]


def _unique(seq):
    out = []
    for s in seq:
        if s not in out:
            out.append(s)
    return out


def _setdiff(a, b):
    b = set(b)
    return _unique([x for x in a if x not in b])


def _named(x):
    """Benannter Vektor -> (Namen, float-Werte); unbenannt -> (None, Werte)."""
    if isinstance(x, pd.Series):
        nm = None if isinstance(x.index, pd.RangeIndex) else [str(k) for k in x.index]
        return nm, np.asarray(x.to_numpy(dtype=np.float64), dtype=np.float64)
    if isinstance(x, Mapping):
        return [str(k) for k in x.keys()], np.array([_NA if v is None else float(v) for v in x.values()],
                                                    dtype=np.float64)
    a = np.asarray(x, dtype=np.float64).ravel()
    return None, a


def _is_numeric_named(x):
    if isinstance(x, pd.Series):
        return x.dtype.kind in "iufb" and not isinstance(x.index, pd.RangeIndex)
    if isinstance(x, Mapping):
        return len(x) > 0 and all(isinstance(v, (int, float, np.integer, np.floating)) and not isinstance(v, bool)
                                  for v in x.values())
    return False


def _df_names(data):
    if isinstance(data, pd.DataFrame):
        return [str(c) for c in data.columns]
    if isinstance(data, Mapping):
        return [str(k) for k in data.keys()]
    return []


def _col(data, name):
    v = data[name]
    if isinstance(v, (pd.Series, pd.Index)):
        return v.to_numpy()
    return np.asarray(v)


def _num(v):
    """``as.numeric`` einer Spalte."""
    from .data_prep import _as_numeric
    return np.asarray(_as_numeric(v), dtype=np.float64)


def _nrow(data):
    if isinstance(data, pd.DataFrame):
        return len(data)
    from .data_prep import _nrow as f
    return f(data)


def _as_int1(x):
    """``as.integer(x)`` für einen Wert (NA bei Unlesbarem); Liste bei Länge != 1."""
    vals = [x] if np.ndim(x) == 0 or isinstance(x, str) else list(np.asarray(x, dtype=object).ravel())
    out = []
    for v in vals:
        if v is None:
            out.append(None)
            continue
        if isinstance(v, (bool, np.bool_)):
            out.append(int(v))
            continue
        try:
            f = float(v.strip()) if isinstance(v, str) else float(v)
        except (TypeError, ValueError):
            out.append(None)
            continue
        if math.isnan(f) or math.isinf(f) or abs(f) >= 2147483648:
            out.append(None)
        else:
            out.append(int(math.trunc(f)))
    return out


def _fmt1(x):
    """``format(x)`` (Skalar oder Vektor; Elemente mit gemeinsamer Breite)."""
    r = _fmt.format(x)
    if isinstance(r, str):
        return [r]
    return [str(s) for s in (r.to_list() if isinstance(r, pd.Series) else list(r))]


def _date_str(d):
    return _fmt.format_date(d) if not isinstance(d, str) else d


def _datefmt1(day):
    """``format(<Date>)`` eines Tages (float)."""
    s = _fmt.format(_as_dates([day]))
    return s if isinstance(s, str) else str(list(s)[0])


def _ymd(days):
    """Tage -> (Jahr, Monat 1-12, Tag) als int-Arrays."""
    d = _as_dates(days)
    y = d.astype("datetime64[Y]").astype(np.int64) + 1970
    m = (d.astype("datetime64[M]").astype(np.int64) % 12) + 1
    dd = (d - d.astype("datetime64[M]").astype("datetime64[D]")).astype(np.int64) + 1
    return y, m, dd


def _civil(y, m, d):
    """(Jahr, Monat, Tag) -> Tage seit 1970-01-01 (Arrays)."""
    y = np.asarray(y, dtype=np.int64)
    m = np.asarray(m, dtype=np.int64)
    d = np.asarray(d, dtype=np.int64)
    y2 = y - (m <= 2)
    era = np.floor_divide(y2, 400)
    yoe = y2 - era * 400
    mp = (m + 9) % 12
    doy = (153 * mp + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return (era * 146097 + doe - 719468).astype(np.float64)


# ═══════════════════════════════════════════════════════════════════════════
# SimLevWeights
# ═══════════════════════════════════════════════════════════════════════════

class SimLevWeights(pd.DataFrame):
    """Zielgewichte (R-Klasse ``SimLevWeights``): ``DataFrame`` mit ``date`` und je
    Anlage einer Spalte Zielgewicht (Anteil, Zeilensumme 1). Attribute in ``attrs``
    (``source``, je nach Erzeuger ``regime``, ``scores``, ``decision_rows``,
    ``exposure``, ``volatility``, ``state``, ``thresholds``, ``failed_dates``).
    ``print()`` zeigt Mittel, Minimum, Maximum und letztes Gewicht in Prozent sowie
    die Zahl der Wechsel, ``plot()`` die Gewichte als gestapelte Flächen."""

    r_class = ("SimLevWeights", "data.frame")

    @property
    def _constructor(self):
        return SimLevWeights

    def format(self):
        if len(self.columns) < 1 or str(self.columns[0]) != "date" or len(self) == 0:
            return pd.DataFrame.__repr__(pd.DataFrame(self))
        try:
            return print_SimLevWeights(self, _return=True)
        except Exception:  # noqa: BLE001 - Teilmengen ohne Gewichtsstruktur
            return pd.DataFrame.__repr__(pd.DataFrame(self))

    def __repr__(self):
        return self.format()

    def __str__(self):
        return self.format()

    def _repr_html_(self):  # pragma: no cover - Jupyter
        return "<pre>%s</pre>" % self.format()

    # ``plot`` (SVG, ``SimLevPlot``) wird am Modulende über ``_plot_method`` gesetzt.


def _is_weights(x):
    return isinstance(x, SimLevWeights) or (isinstance(x, pd.DataFrame) and x.attrs.get("_r_class") == "SimLevWeights")


def _wmat(w, cols=None):
    """Gewichtsmatrix (float) einer SimLevWeights ohne ``date``."""
    cols = list(w.columns[1:]) if cols is None else cols
    return np.column_stack([np.asarray(w[c], dtype=np.float64) for c in cols]) if cols else np.zeros((len(w), 0))


def _as_weights(dates, W, source=""):
    """``.as_weights``: Gewichts-Frame bauen und prüfen (nicht endlich, negativ -> 0,
    Zeilen auf Summe 1)."""
    if isinstance(W, pd.DataFrame):
        cols = [str(c) for c in W.columns] if not isinstance(W.columns, pd.RangeIndex) else None
        M = W.to_numpy(dtype=np.float64)
    else:
        cols = None
        M = np.asarray(W, dtype=np.float64)
        if M.ndim == 1:
            M = M.reshape(-1, 1)
    return _as_weights_m(dates, M, cols, source)


def _as_weights_m(dates, M, cols, source=""):
    M = np.array(M, dtype=np.float64)
    if M.ndim == 1:
        M = M.reshape(-1, 1)
    M[~np.isfinite(M)] = 0.0
    M[M < 0] = 0.0
    s = _rowsums(M)
    bad = s <= 0
    if bad.any():
        raise ValueError("Gewichte: %d Zeilen ohne positive Gewichte." % int(bad.sum()))
    M = M / s[:, None]
    if cols is None:
        cols = ["X%d" % (j + 1) for j in range(M.shape[1])] if M.shape[1] > 1 else ["W"]
    d = _to_date(dates, "date")
    data = {"date": d}
    for j, c in enumerate(cols):
        data[c] = M[:, j]
    out = SimLevWeights(pd.DataFrame(data, columns=["date"] + list(cols)))
    out.attrs["source"] = source
    return out


def _period_last(dates, every):
    """``.period_last``: 1-basierte Zeilen am Ende jeder Periode."""
    if every not in ("day", "week", "month", "quarter", "year"):
        raise ValueError("every: 'day', 'week', 'month', 'quarter' oder 'year'.")
    z = _days(_to_date(dates, "date")) if not (isinstance(dates, np.ndarray) and dates.dtype.kind == "f") else dates
    n = len(z)
    if every == "day":
        return np.arange(1, n + 1, dtype=np.int64)
    zi = z.astype(np.int64)
    if every == "week":
        wd = (zi + 3) % 7
        th = zi - wd + 3
        y, _, _ = _ymd(th.astype(np.float64))
        jan1 = _civil(y, np.ones_like(y), np.ones_like(y)).astype(np.int64)
        key = y * 100 + (th - jan1) // 7 + 1
    else:
        y, m, _ = _ymd(z)
        if every == "month":
            key = y * 12 + m
        elif every == "quarter":
            key = y * 4 + (m - 1) // 3
        else:
            key = y
    if n == 0:
        return np.array([1], dtype=np.int64)[:0]
    ch = np.append(key[1:] != key[:-1], True)
    return np.flatnonzero(ch).astype(np.int64) + 1


def _hold_rows_m(n, rows, M):
    rows = np.asarray(rows, dtype=np.float64)
    idx = _find_interval(np.arange(1, n + 1), rows)
    out = np.full((n, M.shape[1]), _NA)
    ok = idx > 0
    out[ok, :] = M[idx[ok] - 1, :]
    return out


def _hold_rows(n, rows, M):
    """``.hold_rows``: Werte an Entscheidungszeilen (1-basiert) bis zur nächsten halten."""
    if isinstance(M, pd.DataFrame):
        return pd.DataFrame(_hold_rows_m(int(n), rows, M.to_numpy(dtype=np.float64)), columns=M.columns)
    return _hold_rows_m(int(n), rows, np.asarray(M, dtype=np.float64))


# ═══════════════════════════════════════════════════════════════════════════
# signal_state, momentum_score
# ═══════════════════════════════════════════════════════════════════════════

def _sig_part(signal, key):
    if isinstance(signal, Mapping):
        v = signal[key]
    else:
        v = getattr(signal, key)
    return v


def _lgl(v):
    """Logischer Vektor mit NA (None/nan) -> (Werte, NA-Maske)."""
    a = np.asarray(v.to_numpy() if isinstance(v, (pd.Series, pd.Index)) else v, dtype=object).ravel()
    na = np.array([x is None or (isinstance(x, float) and math.isnan(x)) or x is pd.NA for x in a], dtype=bool)
    val = np.array([False if m else bool(x) for x, m in zip(a, na)], dtype=bool)
    return val, na


def signal_state(signal, *, initial=False):
    """Signale in einen dauerhaften Zustand übersetzen.

    ``True`` ab einem Kaufsignal bis zum nächsten Verkaufssignal. Zeilen, in denen
    beide Signale ``False`` (oder beide ``True``) sind, ändern den Zustand nicht.

    Args:
        signal: ``{"buy": ..., "sell": ...}`` mit logischen Vektoren gleicher Länge.
        initial: Zustand vor dem ersten Signal (Standard ``False``).

    Returns:
        Logisches ``numpy.ndarray`` (``True`` = investiert).
    """
    b, bna = _lgl(_sig_part(signal, "buy"))
    s, sna = _lgl(_sig_part(signal, "sell"))
    n = len(b)
    if len(s) != n:
        s = np.resize(s, n)
        sna = np.resize(sna, n)
    na = bna | sna
    ev = np.where(b & ~s, 1, np.where(s & ~b, -1, 0))
    ev[na] = 0
    idx = np.flatnonzero(ev != 0) + 1
    st = np.repeat(bool(initial), n)
    if len(idx):
        k = _find_interval(np.arange(1, n + 1), idx)
        pos = k > 0
        st[pos] = ev[idx[k[pos] - 1] - 1] == 1
    return st


def _momentum_back(d, lookbacks):
    """Rückblickzeilen (1-basiert, 0 = keine) je Rückblick in Monaten."""
    y, m0, mday = _ymd(d)
    mon = m0 - 1
    back = []
    for m in lookbacks:
        mi = _as_int1(m)[0]
        mo = mon - mi
        y2 = y + np.floor_divide(mo, 12)
        mo2 = np.mod(mo, 12)
        first = _civil(y2, mo2 + 1, np.ones_like(y2))
        nxt = _civil(y2 + (mo2 + 1) // 12, (mo2 + 1) % 12 + 1, np.ones_like(y2))
        target = first + np.minimum(mday, (nxt - first).astype(np.int64)) - 1
        back.append(_find_interval(target, d))
    return back


def momentum_score(data, assets, *, lookbacks=(1, 3, 6, 12), type=("average", "13612w")):  # noqa: A002
    """Momentum-Score: mittlere Rendite über mehrere Rückblicke (Kalendermonate).

    Args:
        data: ``DataFrame`` mit Spalte ``date`` und Kursspalten (Niveaus).
        assets: Kursspalten.
        lookbacks: Rückblicke in Kalendermonaten (Standard 1, 3, 6, 12); bei
            ``type="13612w"`` ignoriert.
        type: ``"average"`` (ungewichtetes Mittel) oder ``"13612w"``
            ((12 r1 + 4 r3 + 2 r6 + r12) / 4).

    Returns:
        ``DataFrame`` Zeilen von ``data`` x ``assets`` mit dem Score als Anteil
        (NA, solange die Historie für den längsten Rückblick zu kurz ist).
    """
    type = _match_arg(type, ("average", "13612w"))  # noqa: A001
    d = _days(_to_date(_col(data, "date") if "date" in _df_names(data) else None, "momentum_score: data$date"))
    n = len(d)
    assets = _chr_vec(assets)
    miss = _setdiff(assets, _df_names(data))
    if miss:
        raise ValueError("momentum_score: Kursspalte(n) fehlen: %s" % ", ".join(miss))
    if type == "13612w":
        lookbacks = [1, 3, 6, 12]
    lookbacks = list(np.atleast_1d(np.asarray(lookbacks, dtype=object)))
    back = _momentum_back(d, lookbacks)
    S = np.empty((n, len(assets)))
    for j, a in enumerate(assets):
        x = _fill_na(_num(_col(data, a)), "locf", keep_leading=True)
        R = np.empty((n, len(back)))
        for c, k in enumerate(back):
            kk = np.maximum(k, 1) - 1
            with np.errstate(all="ignore"):
                r = x / x[kk] - 1 if n else np.empty(0)
            R[:, c] = np.where(k > 0, r, _NA)
        if type == "13612w":
            with np.errstate(all="ignore"):
                S[:, j] = (12 * R[:, 0] + 4 * R[:, 1] + 2 * R[:, 2] + R[:, 3]) / 4
        else:
            S[:, j] = _rowmeans(R)
    return pd.DataFrame(S, columns=assets)


# ═══════════════════════════════════════════════════════════════════════════
# tactical_rules
# ═══════════════════════════════════════════════════════════════════════════

def _eval_when(expr, data, env):
    """Bedingung als Text in R-Syntax auswerten (:mod:`simlev._r.rexpr`): Spalten von ``data``, dann ``env``."""
    from ._r import rexpr as _rexpr
    cols = data if isinstance(data, (pd.DataFrame, Mapping)) else {c: _col(data, c) for c in _df_names(data)}
    return _rexpr.eval_r(expr, cols, env=env)


def _as_logical(v, n):
    if isinstance(v, (bool, np.bool_)) or (np.ndim(v) == 0 and not isinstance(v, str)):
        v = [v]
    a = np.asarray(v.to_numpy() if isinstance(v, (pd.Series, pd.Index)) else v, dtype=object).ravel()
    out = np.zeros(len(a), dtype=bool)
    for i, x in enumerate(a):
        if x is None or x is pd.NA:
            continue
        if isinstance(x, str):
            out[i] = x in ("TRUE", "true", "T", "True")
            continue
        try:
            f = float(x)
        except (TypeError, ValueError):
            continue
        if math.isnan(f):
            continue
        out[i] = f != 0
    return out


@env_from_caller
def tactical_rules(data, rules, default, *, env=None):
    """Regelbasierte taktische Allokation.

    Geordnete Bedingungen wählen je Tag ein Zielportfolio; die erste zutreffende
    Regel gewinnt, sonst gilt ``default``.

    Args:
        data: ``DataFrame`` mit Spalte ``date`` (und den in Bedingungen verwendeten
            Spalten).
        rules: Liste von Regeln ``{"when": ..., "weights": {"A": 0.6, "B": 0.4}}`` in
            Prioritätsreihenfolge. ``when``: logischer Vektor der Länge ``len(data)``,
            Zeichenkette mit einem Ausdruck in R-Syntax (ausgewertet mit den Spalten von
            ``data``, dann in ``env``; siehe :mod:`simlev._r.rexpr`), Funktion
            ``data -> Vektor`` oder ``{"buy", "sell"}`` (wird mit :func:`signal_state`
            in einen Zustand übersetzt); NA gilt als ``False``.
        default: Gewichte für Zeilen ohne zutreffende Regel.
        env: Mapping für freie Variablen und Funktionen in Bedingungen
            (Voreinstellung: Namensraum des Aufrufers).

    Returns:
        :class:`SimLevWeights` mit ``attrs["regime"]`` (Nummer der aktiven Regel,
        0 = ``default``) und ``attrs["source"]``.
    """
    n = _nrow(data)
    rules = list(rules) if rules is not None else []

    def wget(r):
        return r["weights"] if isinstance(r, Mapping) else getattr(r, "weights")

    def when(r):
        return r["when"] if isinstance(r, Mapping) else getattr(r, "when")

    names = []
    for r in rules:
        nm, _ = _named(wget(r))
        names += nm or []
    dn, _ = _named(default)
    assets = _unique(names + (dn or []))
    cond = np.zeros((n, len(rules)), dtype=bool)
    for j, r in enumerate(rules):
        w = when(r)
        if isinstance(w, str):
            v = _eval_when(w, data, env)
        elif isinstance(w, Mapping) and w.get("buy") is not None:
            v = signal_state(w)
        elif callable(w):
            v = w(data)
        else:
            v = w
        v = _as_logical(v, n)
        if len(v) != n:
            raise ValueError("Bedingung hat nicht die Länge nrow(data).")
        cond[:, j] = v
    regime = np.zeros(n, dtype=np.int64)
    if len(rules):
        anyc = cond.any(axis=1)
        regime[anyc] = np.argmax(cond[anyc], axis=1) + 1

    def vec(w):
        nm, vals = _named(w)
        v = np.zeros(len(assets))
        for k, x in zip(nm or [], vals):
            v[assets.index(k)] = x
        return v

    P = np.vstack([vec(default)] + [vec(wget(r)) for r in rules])
    W = P[regime, :]
    out = _as_weights_m(_col(data, "date"), W, assets, "rules")
    out.attrs["regime"] = regime
    return out


# ═══════════════════════════════════════════════════════════════════════════
# tactical_rotation
# ═══════════════════════════════════════════════════════════════════════════

def tactical_rotation(data, assets, *, top=1, safe=None, absolute=True, canary=None, breadth=None,
                      lookbacks=(1, 3, 6, 12), type=("average", "13612w"),  # noqa: A002
                      every=("month", "week", "quarter"), weighting=("equal", "inverse_vol")):
    """Momentum-Rotation, Dual Momentum und Canary-Schutz.

    An jedem Entscheidungstermin (Periodenende) werden die Anlagen nach ihrem
    Momentum-Score sortiert und die besten ``top`` gehalten. Absolutes Momentum
    (``absolute=True``): ein gewählter Platz mit negativem Score geht an die beste
    sichere Anlage aus ``safe``. Canary (``canary``): bei b Canary-Anlagen mit
    negativem Score geht der Anteil min(1, b / breadth) an die sichere Anlage.

    Args:
        data: ``DataFrame`` mit ``date`` und Kursspalten aller Anlagen.
        assets: Risikoanlagen für die Rotation.
        top: Anzahl gehaltener Anlagen (1 bis Anzahl ``assets``).
        safe: sichere Anlage(n) (Pflicht bei ``absolute`` oder ``canary``).
        absolute: absoluten Momentum-Filter anwenden.
        canary: Canary-Anlagen (``None`` = kein Canary-Schutz).
        breadth: Schutzschwelle (mindestens 1; ``None`` = Anzahl Canary-Anlagen).
        lookbacks, type: siehe :func:`momentum_score`.
        every: ``"month"``, ``"week"`` (ISO-Woche) oder ``"quarter"``.
        weighting: ``"equal"`` oder ``"inverse_vol"`` (63 Zeilen).

    Returns:
        :class:`SimLevWeights` mit ``attrs["scores"]`` und ``attrs["decision_rows"]``.
    """
    type = _match_arg(type, ("average", "13612w"))  # noqa: A001
    every = _match_arg(every, ("month", "week", "quarter"))
    weighting = _match_arg(weighting, ("equal", "inverse_vol"))
    assets = _chr_vec(assets)
    safe = _chr_vec(safe)
    canary = _chr_vec(canary)
    if (bool(absolute) or len(canary)) and not len(safe):
        raise ValueError("absolute bzw. canary brauchen eine sichere Anlage 'safe'.")
    topv = _as_int1(top)
    if len(topv) != 1 or topv[0] is None or topv[0] < 1 or topv[0] > len(assets):
        ft = ", ".join("NA" if t is None else "%d" % t for t in topv)
        raise ValueError("top muss zwischen 1 und der Anzahl der Anlagen in assets (%d) liegen (ist: %s)."
                         % (len(assets), ft if len(topv) == 1 else " ".join(_fmt1(np.array(
                             [_NA if t is None else t for t in topv]))) ))
    top = topv[0]
    if len(canary) and breadth is not None:
        bv = np.atleast_1d(np.asarray(breadth, dtype=np.float64))
        if len(bv) != 1 or math.isnan(bv[0]) or bv[0] < 1:
            raise ValueError("breadth muss mindestens 1 sein (Anzahl Canary-Anlagen mit negativem Score für "
                             "vollen Schutz; ist: %s)." % ", ".join(_fmt1(bv)) if len(bv) == 1 else
                             "breadth muss mindestens 1 sein (Anzahl Canary-Anlagen mit negativem Score für "
                             "vollen Schutz; ist: %s)." % " ".join(_fmt1(bv)))
    allc = _unique(assets + safe + canary)
    Sdf = momentum_score(data, allc, lookbacks=lookbacks, type=type)
    S = Sdf.to_numpy(dtype=np.float64)
    ci = {a: j for j, a in enumerate(allc)}
    d = _days(_to_date(_col(data, "date"), "data$date"))
    n = len(d)
    rows = _period_last(d, every)
    ja = [ci[a] for a in assets]
    if len(rows):
        keep = np.isfinite(S[np.ix_(rows - 1, ja)]).sum(axis=1) >= top
        rows = rows[keep]
    if not len(rows):
        raise ValueError("Zu kurze Historie für den Rückblick.")
    out_assets = _unique(assets + safe)
    oi = {a: j for j, a in enumerate(out_assets)}
    vol = None
    if weighting == "inverse_vol":
        from .signals import _roll_mean
        vol = np.empty((n, len(assets)))
        for j, a in enumerate(assets):
            x = _fill_na(_num(_col(data, a)), "locf", keep_leading=True)
            lx = _libm.log(x)
            r = np.concatenate(([_NA], np.diff(lx)))
            r0 = np.where(np.isnan(r), 0.0, r)
            rm = np.asarray(_roll_mean(r0 * r0, 63), dtype=np.float64)
            with np.errstate(invalid="ignore"):
                vol[:, j] = np.sqrt(np.where(np.isnan(rm), rm, np.maximum(rm, 1e-12)))   # pmax: NA/NaN bleibt
    vi = {a: j for j, a in enumerate(assets)}
    B = breadth
    M = np.zeros((len(rows), len(out_assets)))
    for r_i, i1 in enumerate(rows):
        i = i1 - 1
        w = np.zeros(len(out_assets))
        sc = S[i, ja]
        ok = [k for k in range(len(assets)) if math.isfinite(sc[k])]
        ordk = sorted(ok, key=lambda k: -sc[k])
        pick = [assets[k] for k in ordk][:min(top, len(ok))]
        best_safe = None
        if len(safe):
            ss = S[i, [ci[a] for a in safe]]
            if not np.isfinite(ss).any():
                best_safe = safe[0]
            else:
                fin = [k for k in range(len(safe)) if not math.isnan(ss[k])]
                mx = max(ss[k] for k in fin)
                best_safe = safe[[k for k in fin if ss[k] == mx][0]]
        if weighting == "equal":
            pw = [1 / len(pick)] * len(pick)
        else:
            iv = 1 / vol[i, [vi[a] for a in pick]]
            pw = list(iv / _ldsum(iv))
        cash = 0.0
        if len(canary):
            cv = S[i, [ci[a] for a in canary]]
            b = int(np.sum(cv < 0))
            BB = float(np.asarray(B, dtype=np.float64).ravel()[0]) if B is not None else len(canary)
            cash = min(1.0, b / BB)
        for k, p in enumerate(pick):
            share = pw[k] * (1 - cash)
            spk = S[i, ci[p]]
            if absolute and math.isfinite(spk) and spk < 0:
                w[oi[best_safe]] = w[oi[best_safe]] + share
            else:
                w[oi[p]] = w[oi[p]] + share
        if cash > 0:
            w[oi[best_safe]] = w[oi[best_safe]] + cash
        M[r_i, :] = w
    H = _hold_rows_m(n, rows, M)
    first = int(rows[0])
    H[:first - 1, :] = 0.0
    if first > 1:
        H[:first - 1, oi[safe[0] if len(safe) else assets[0]]] = 1.0
    out = _as_weights_m(_as_dates(d), H, out_assets, "rotation")
    out.attrs["scores"] = Sdf
    out.attrs["decision_rows"] = rows
    return out


# ═══════════════════════════════════════════════════════════════════════════
# Zielvolatilität, bedingte Volatilitätssteuerung
# ═══════════════════════════════════════════════════════════════════════════

def _risk_vol(data, weights, safe, window, ppy):
    """``.risk_vol``: Volatilität des Risikoportfolios."""
    d = _days(_to_date(_col(data, "date"), "data$date"))
    n = len(d)
    if not _is_weights(weights):
        if not _is_numeric_named(weights):
            raise ValueError("weights: SimLevWeights oder benannter Gewichtsvektor erwartet.")
        nm, vals = _named(weights)
        weights = _as_weights_m(_as_dates(d), np.tile(vals, (n, 1)), nm, "static")
    if safe not in _df_names(data):
        raise ValueError("Sichere Anlage '%s' fehlt in data." % safe)
    risky = _setdiff([str(c) for c in weights.columns[1:]], [safe])
    miss = _setdiff(risky, _df_names(data))
    if miss:
        raise ValueError("Kursspalte(n) aus weights fehlen in data: %s" % ", ".join(miss))
    wd = _days(np.asarray(weights["date"]))
    if len(weights) != n or not np.array_equal(wd, d, equal_nan=True):
        raise ValueError("weights passt nicht zu data (andere Daten); Gewichte aus demselben Datensatz erzeugen.")
    Wr = _wmat(weights, risky)
    R = np.empty((n, len(risky)))
    for j, a in enumerate(risky):
        x = _fill_na(_num(_col(data, a)), "locf", keep_leading=True)
        with np.errstate(all="ignore"):
            R[:, j] = np.concatenate(([0.0], x[1:] / x[:-1] - 1))
    R[~np.isfinite(R)] = 0.0
    rs = _rowsums(Wr)
    Wn = Wr / np.where(rs > 0, rs, 1.0)[:, None]
    pr = np.concatenate(([0.0], _rowsums(Wn[:-1, :] * R[1:, :]))) if n > 0 else np.zeros(0)
    move = np.abs(pr) > 0
    if ppy is None:
        span = (d[n - 1] - d[0]) / 365.25
        ppy = int(move.sum()) / (span if span > 1e-9 else 1e-9)
    vol = np.full(n, _NA)
    idx = np.flatnonzero(move)
    window = int(window)
    if len(idx) > window:
        from .signals import _roll_var
        v = np.asarray(_roll_var(pr[idx], window), dtype=np.float64)
        with np.errstate(invalid="ignore"):
            vol[idx] = np.sqrt(np.where(np.isnan(v), v, np.maximum(v, 0.0)) * ppy)   # pmax: NA/NaN bleibt
    return {"d": d, "n": n, "risky": risky, "Wr": Wr, "rs": rs, "move": move, "ppy": ppy,
            "vol_move": vol, "vol": _fill_na(vol, "locf", keep_leading=True)}


def _risk_weights(rv, expo, safe, source):
    """``.risk_weights``: Risikoteil mit Exposure skalieren, Rest in die sichere Anlage."""
    W = np.column_stack([rv["Wr"] * expo[:, None], 1 - expo * rv["rs"]])
    W[W < 0] = 0.0
    return _as_weights_m(_as_dates(rv["d"]), W, rv["risky"] + [safe], source)


def _g(x):
    return _fmt.sprintf("%g", float(x))


def tactical_target_volatility(data, weights, safe, *, target=10, window=63, max_exposure=1,
                      every=("month", "week", "day", "quarter"), ppy=None):
    """Zielvolatilität: Risikoanteil ``min(max_exposure, (target / 100) / vol)``.

    Args:
        data: ``DataFrame`` mit ``date`` und Kursspalten der Risikoanlagen und von ``safe``.
        weights: :class:`SimLevWeights` oder benannter Gewichtsvektor (statisch).
        safe: Kursspalte der sicheren Anlage.
        target: Zielvolatilität in Prozent p. a. (Standard 10).
        window: Fensterlänge in Zeilen mit Kursbewegung (Standard 63).
        max_exposure: höchster Risikoanteil (höchstens 1).
        every: ``"month"``, ``"week"``, ``"day"`` oder ``"quarter"``.
        ppy: Tage mit Kursbewegung je Jahr (``None`` = aus den Daten).

    Returns:
        :class:`SimLevWeights` mit ``attrs["exposure"]`` und ``attrs["volatility"]``.
    """
    every = _match_arg(every, ("month", "week", "day", "quarter"))
    if max_exposure > 1:
        raise ValueError("max_exposure > 1 wäre Kredit; die Engine kennt keine Kreditaufnahme (Hebel über "
                         "Hebelprodukte abbilden).")
    if target < 1:
        _warn("target = %s ist sehr klein; target ist in Prozent p. a. (10 = 10 %%), nicht als Anteil." % _g(target))
    rv = _risk_vol(data, weights, safe, window, ppy)
    n = rv["n"]
    vol = rv["vol"]
    rows = _period_last(rv["d"], every)
    rows = rows[np.isfinite(vol[rows - 1])]
    if not len(rows):
        raise ValueError("Zu kurze Historie für das Volatilitätsfenster.")
    expo_r = np.minimum(max_exposure, target / 100 / np.maximum(vol[rows - 1], 1e-6))
    k = _find_interval(np.arange(1, n + 1), rows)
    expo = np.where(k > 0, expo_r[np.maximum(k, 1) - 1], 0.0).astype(np.float64)
    out = _risk_weights(rv, expo, safe, "target_volatility")
    out.attrs["exposure"] = expo
    out.attrs["volatility"] = vol
    return out


def _quantile7(x, p):
    from ._r import stats as _st
    q = _st.quantile(np.asarray(x, dtype=np.float64), p, names=False, type=7)
    return float(np.asarray(q, dtype=np.float64).ravel()[0])


def tactical_conditional_volatility(data, weights, safe, *, base=1, upper=0.8, lower=0.2, target=None, window=63,
                           min_exposure=0, max_exposure=1, min_history=3, scaling=("inverse", "fixed"),
                           high_exposure=None, low_exposure=None, every=("month", "week", "day", "quarter"),
                           ppy=None):
    """Bedingte Volatilitätssteuerung: nur in extremen Phasen skalieren.

    Liegt die geschätzte Volatilität über ihrem ``upper``-Quantil (expandierend,
    monatlich, ohne Blick in die Zukunft), wird der Risikoanteil gesenkt, unter dem
    ``lower``-Quantil erhöht; dazwischen gilt ``base``.

    Args:
        data, weights, safe, window, every, ppy: wie :func:`tactical_target_volatility`.
        base: Grundanteil (0 bis ``max_exposure``).
        upper, lower: Quantil-Wahrscheinlichkeiten (``lower=None`` schaltet das
            Hochskalieren ab).
        target: Vergleichsvolatilität in Prozent p. a. (``None`` = Mittel der bisherigen).
        min_exposure, max_exposure: Grenzen des Risikoanteils.
        min_history: Mindesthistorie in Jahren.
        scaling: ``"inverse"`` (``base * target / vol``) oder ``"fixed"``.
        high_exposure, low_exposure: feste Anteile für ``scaling="fixed"``.

    Returns:
        :class:`SimLevWeights` mit ``attrs`` ``exposure``, ``volatility``, ``state``
        (-1 niedrig, 0 normal, 1 hoch) und ``thresholds``.
    """
    every = _match_arg(every, ("month", "week", "day", "quarter"))
    scaling = _match_arg(scaling, ("inverse", "fixed"))
    if max_exposure > 1:
        raise ValueError("max_exposure > 1 wäre Kredit; die Engine kennt keine Kreditaufnahme (Hebel über "
                         "Hebelprodukte abbilden).")
    if base < 0 or base > max_exposure:
        raise ValueError("base muss zwischen 0 und max_exposure liegen.")
    if min_exposure < 0 or min_exposure > base:
        raise ValueError("min_exposure muss zwischen 0 und base liegen.")
    if not (upper > 0 and upper < 1):
        raise ValueError("upper muss zwischen 0 und 1 liegen.")
    if lower is not None and not (lower > 0 and lower < upper):
        raise ValueError("lower muss zwischen 0 und upper liegen.")
    if scaling == "fixed":
        if high_exposure is None or (lower is not None and low_exposure is None):
            raise ValueError("scaling = 'fixed' braucht high_exposure (und low_exposure, wenn lower gesetzt ist).")
        if high_exposure > base:
            raise ValueError("high_exposure darf nicht über base liegen.")
        if lower is not None and (low_exposure < base or low_exposure > max_exposure):
            raise ValueError("low_exposure muss zwischen base und max_exposure liegen.")
    if target is not None and target < 1:
        _warn("target = %s ist sehr klein; target ist in Prozent p. a. (10 = 10 %%), nicht als Anteil." % _g(target))
    if lower is not None and base >= max_exposure:
        _message("Hinweis: base = max_exposure; in ruhigen Phasen kann nicht hochskaliert werden (ohne Kredit). "
                 "base < max_exposure wählen oder lower = NULL setzen.")
    rv = _risk_vol(data, weights, safe, window, ppy)
    d = rv["d"]
    n = rv["n"]
    vol = rv["vol"]
    vm = rv["vol_move"]
    grid = _period_last(d, "month")
    fin = np.isfinite(vm)
    ok = np.flatnonzero(fin) + 1
    first_ok = d[ok[0] - 1] if len(ok) else d[n - 1] + 1
    cs = np.cumsum(np.where(fin, vm, 0.0).astype(LD)).astype(np.float64) if n else np.zeros(0)
    cn = np.cumsum(fin.astype(np.int64))
    th = np.full((len(grid), 3), _NA)
    for gi, g in enumerate(grid):
        if not len(ok) or (d[g - 1] - first_ok) / 365.25 < min_history:
            continue
        v = vm[ok[ok <= g] - 1]
        th[gi, 0] = _NA if lower is None else _quantile7(v, lower)
        th[gi, 1] = _quantile7(v, upper)
        th[gi, 2] = cs[g - 1] / cn[g - 1] if target is None else target / 100
    thresholds = pd.DataFrame({"date": _as_dates(d[grid - 1]), "lower": th[:, 0], "upper": th[:, 1],
                               "target": th[:, 2]})
    if np.isnan(th[:, 1]).all():
        yrs = (d[n - 1] - first_ok) / 365.25 if len(ok) else 0.0
        _warn(_fmt.sprintf("min_history = %g Jahre ist länger als die verfügbare Volatilitätshistorie "
                           "(%.1f Jahre); es wird nie gesteuert (Risikoanteil = base).", float(min_history), yrs))
    kg = _find_interval(np.arange(1, n + 1), grid)

    def cur(j):
        return np.where(kg > 0, th[np.maximum(kg, 1) - 1, j], _NA) if len(grid) else np.full(n, _NA)

    lo_t, up_t, tg = cur(0), cur(1), cur(2)
    state = np.zeros(n, dtype=np.int64)
    with np.errstate(invalid="ignore"):
        state[np.isfinite(up_t) & np.isfinite(vol) & (vol > up_t)] = 1
        if lower is not None:
            state[np.isfinite(lo_t) & np.isfinite(vol) & (vol < lo_t)] = -1
    rows = _period_last(d, every)
    rows = rows[np.isfinite(vol[rows - 1])]
    if not len(rows):
        raise ValueError("Zu kurze Historie für das Volatilitätsfenster.")
    e_r = np.repeat(float(base), len(rows))
    s_r = state[rows - 1]
    if scaling == "inverse":
        ratio = tg[rows - 1] / np.maximum(vol[rows - 1], 1e-6)
        hi = s_r == 1
        lw = s_r == -1
        e_r[hi] = base * np.minimum(1.0, ratio[hi])
        e_r[lw] = base * np.maximum(1.0, ratio[lw])
    else:
        e_r[s_r == 1] = high_exposure
        if lower is not None:
            e_r[s_r == -1] = low_exposure
    e_r = np.minimum(max_exposure, np.maximum(min_exposure, e_r))
    k = _find_interval(np.arange(1, n + 1), rows)
    expo = np.where(k > 0, e_r[np.maximum(k, 1) - 1], float(base)).astype(np.float64)
    out = _risk_weights(rv, expo, safe, "conditional_volatility")
    out.attrs["exposure"] = expo
    out.attrs["volatility"] = vol
    out.attrs["state"] = np.where(k > 0, s_r[np.maximum(k, 1) - 1], 0).astype(np.int64)
    out.attrs["thresholds"] = thresholds
    return out


# ═══════════════════════════════════════════════════════════════════════════
# tactical_glidepath, tactical_blend
# ═══════════════════════════════════════════════════════════════════════════

def tactical_glidepath(data, from_=_MISSING, to=_MISSING, *, start=None, end=None, every=("year", "quarter", "month"), **kwargs):
    """Glidepath zwischen zwei Allokationen.

    Stufenweise lineare Bewegung von ``from_`` (R: ``from``) nach ``to``; eine Stufe
    beginnt in der ersten Zeile und an der letzten vorhandenen Zeile jeder Periode von
    ``every``; Gewicht ``(1 - p) * from + p * to`` mit dem Zeitanteil ``p`` zwischen
    ``start`` und ``end`` (begrenzt auf 0 bis 1).

    Args:
        data: ``DataFrame`` mit Spalte ``date`` oder Datumsvektor.
        from_, to: Gewichte am Anfang und Ende, beide Pflicht wie in R (``from`` ist in
            Python reserviert; ``**{"from": ...}`` geht ebenfalls).
        start, end: Beginn und Ende (Datum oder "JJJJ-MM-TT"; ``None`` = erstes bzw.
            letztes Datum).
        every: ``"year"``, ``"quarter"`` oder ``"month"``.

    Returns:
        :class:`SimLevWeights`.
    """
    if "from" in kwargs:
        from_ = kwargs.pop("from")
    if kwargs:
        raise TypeError("tactical_glidepath: unbekannte Argumente %s" % ", ".join(kwargs))
    every = _match_arg(every, ("year", "quarter", "month"))
    src = _col(data, "date") if isinstance(data, pd.DataFrame) else data
    d = _days(_to_date(src, "tactical_glidepath: Datum"))
    # R verlangt from und to (kein Standardwert); der Platzhalter steht nur, weil from_ als
    # Schlüsselwort-Ersatz einen Standardwert braucht. Meldung wie R bei fehlendem Argument.
    if from_ is _MISSING:
        raise ValueError('argument "from" is missing, with no default')
    if to is _MISSING:
        raise ValueError('argument "to" is missing, with no default')
    fn, fv = _named(from_)
    tn, tv = _named(to)
    a = _unique((fn or []) + (tn or []))
    f = np.zeros(len(a))
    t = np.zeros(len(a))
    for k, x in zip(fn or [], fv):
        f[a.index(k)] = x
    for k, x in zip(tn or [], tv):
        t[a.index(k)] = x
    s = _days(_to_date(_as_dates([d[0]]) if start is None else start, "start"))[0]
    e = _days(_to_date(_as_dates([d[-1]]) if end is None else end, "end"))[0]
    if e < s:
        raise ValueError("tactical_glidepath: end (%s) liegt vor start (%s); für den umgekehrten Weg from und to tauschen."
                         % (_datefmt1(e), _datefmt1(s)))
    pl = _period_last(d, every)
    rows = np.array(_unique([1] + [int(r) for r in pl]), dtype=np.int64)
    if e > s:
        frac = np.minimum(1.0, np.maximum(0.0, (d[rows - 1] - s) / (e - s)))
    else:
        frac = (d[rows - 1] >= s).astype(np.float64)
    M = np.array([(1 - p) * f + p * t for p in frac]).reshape(len(frac), len(a))
    H = _hold_rows_m(len(d), rows, M)
    return _as_weights_m(_as_dates(d), H, a, "glidepath")


def tactical_blend(*args, shares=None, **kwargs):
    """Gewichtsreihen mischen (Kern-Satellit): je Zeile und Anlage
    ``sum_k shares_k * w_k``, dann auf Summe 1 normiert.

    Args:
        *args: :class:`SimLevWeights` mit identischer Spalte ``date`` (auch als
            benannte Argumente; Namen werden nicht verwendet).
        shares: Anteile je Reihe (``None`` = gleiche Anteile).

    Returns:
        :class:`SimLevWeights`.
    """
    ws = list(args) + list(kwargs.values())
    if not ws or not all(_is_weights(w) for w in ws):
        raise ValueError("tactical_blend: ... muss aus SimLevWeights bestehen.")
    if shares is None:
        shares = np.repeat(1 / len(ws), len(ws))
    sh = np.atleast_1d(np.asarray(shares, dtype=np.float64))
    if len(sh) != len(ws) or np.isnan(sh).any() or (sh < 0).any() or _ldsum(sh) <= 0:
        raise ValueError("tactical_blend: shares braucht %d nichtnegative Anteile (einen je Gewichtsreihe, z. B. "
                         "c(0.7, 0.3)); erhalten: %s." % (len(ws), ", ".join(_fmt1(sh))))
    d = _days(np.asarray(ws[0]["date"]))
    for w in ws:
        dw = _days(np.asarray(w["date"]))
        if len(dw) != len(d) or not np.array_equal(dw, d, equal_nan=True):
            raise ValueError("tactical_blend: unterschiedliche Daten.")
    a = _unique([str(c) for w in ws for c in w.columns[1:]])
    W = np.zeros((len(d), len(a)))
    for k, w in enumerate(ws):
        for nm in [str(c) for c in w.columns[1:]]:
            j = a.index(nm)
            W[:, j] = W[:, j] + sh[k] * np.asarray(w[nm], dtype=np.float64)
    return _as_weights_m(_as_dates(d), W, a, "blend")


# ═══════════════════════════════════════════════════════════════════════════
# print / plot
# ═══════════════════════════════════════════════════════════════════════════

def print_SimLevWeights(x, _return=False):  # noqa: N802 - R-Name
    """``print.SimLevWeights``: Mittel, Minimum, Maximum und letztes Gewicht in Prozent,
    Zahl der Wechsel, bei Volatilitätssteuerung die Phasenanteile."""
    cols = [str(c) for c in x.columns[1:]]
    W = _wmat(x, cols)
    nr = W.shape[0]
    ch = _rowsums(np.abs(W[1:, :] - W[:-1, :])) > 1e-9 if nr > 1 else np.zeros(0, dtype=bool)
    src = x.attrs.get("source")
    dts = np.asarray(x["date"])
    lines = ["SimLev-Zielgewichte (%s): %d Tage, %s bis %s, %d Wechsel" % (
        "" if src is None else src, nr, _datefmt1(_days(dts[:1])[0]), _datefmt1(_days(dts[nr - 1:nr])[0]),
        int(ch.sum()))]
    m = np.vstack([_colmeans(W), W.min(axis=0), W.max(axis=0), W[nr - 1, :]])
    mr = _fmt.r_round(100 * m, 1)
    lines.append(_fmt.print_matrix(pd.DataFrame(np.asarray(mr, dtype=np.float64),
                                                index=["Mittel", "Min", "Max", "Zuletzt"], columns=cols)))
    st = x.attrs.get("state")
    if st is not None:
        st = np.asarray(st)
        lines.append("")
        lines.append(_fmt.sprintf("Volatilitätsphasen (Anteil der Tage): niedrig %.0f %%, normal %.0f %%, "
                                  "hoch %.0f %%", 100 * _mean_int(st == -1), 100 * _mean_int(st == 0),
                                  100 * _mean_int(st == 1)))
    txt = "\n".join(lines)
    if _return:
        return txt
    print(txt)
    return x


def plot_SimLevWeights(x, width=900, height=420, main="Zielgewichte"):  # noqa: N802 - R-Name
    """``plot.SimLevWeights``: Zielgewichte als gestapelte Flächen über der Zeit (SVG).

    Liefert ``(svg, data)`` mit ``data["weights"]`` (``date`` und je Anlage eine Spalte, Anteile);
    über ``x.plot()`` bzw. ``simlev.plot(x)`` entsteht daraus ein ``SimLevPlot``.
    """
    cols = [str(c) for c in x.columns[1:]]
    W = _wmat(x, cols)
    d = np.atleast_1d(np.asarray(_to_date(x["date"], "date"))).astype("datetime64[D]")
    t = _days(d)
    L, R, T, B = 60.0, 140.0, 40.0, 40.0
    pw = width - L - R
    ph = height - T - B
    t0, t1 = float(np.min(t)), float(np.max(t))
    if t1 == t0:
        t1 = t0 + 1

    def px(v):
        return L + pw * (v - t0) / (t1 - t0)

    def py(v):
        return T + ph * (1 - v)
    cl = _alloc_ramp(len(cols))
    out = ["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%s\" height=\"%s\" viewBox=\"0 0 %s %s\" "
           "font-family=\"sans-serif\">" % (_jl_str(width), _jl_str(height), _jl_str(width), _jl_str(height)),
           "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>",
           "<text x=\"%s\" y=\"22\" text-anchor=\"middle\" font-size=\"15\" font-weight=\"bold\">%s</text>"
           % (_jl_str(L + pw / 2), _esc(main))]
    cum = np.zeros(len(t))
    for j in range(len(cols)):
        lo = cum.copy()
        w = W[:, j]
        cum = cum + np.where(np.isfinite(w), w, 0.0)
        up = " ".join("%s,%s" % (_alloc_c(px(t[i])), _alloc_c(py(cum[i]))) for i in range(len(t)))
        dn = " ".join("%s,%s" % (_alloc_c(px(t[i])), _alloc_c(py(lo[i]))) for i in reversed(range(len(t))))
        out.append("<polygon points=\"%s %s\" fill=\"%s\" stroke=\"none\"/>" % (up, dn, cl[j]))
    for v in (0.0, 0.25, 0.5, 0.75, 1.0):
        out.append("<text x=\"%s\" y=\"%s\" text-anchor=\"end\" font-size=\"11\">%s</text>"
                   % (_jl_str(L - 6), _alloc_c(py(v) + 4), _jl_str(v)))
    for y in _jl_unique((d.astype("datetime64[Y]").astype(np.int64) + 1970).tolist()):
        z = float(np.datetime64(y - 1970, "Y").astype("datetime64[D]").astype(np.int64))
        if z < t0 or z > t1:
            continue
        out.append("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" font-size=\"11\">%d</text>"
                   % (_alloc_c(px(z)), _jl_str(T + ph + 16), y))
    out.append("<text x=\"16\" y=\"%s\" font-size=\"12\" transform=\"rotate(-90 16 %s)\" text-anchor=\"middle\">"
               "Gewicht</text>" % (_jl_str(T + ph / 2), _jl_str(T + ph / 2)))
    for j, c in enumerate(cols):
        yy = T + j * 18
        out.append("<rect x=\"%s\" y=\"%s\" width=\"12\" height=\"12\" fill=\"%s\"/>" % (_jl_str(L + pw + 12), _jl_str(yy), cl[j]))
        out.append("<text x=\"%s\" y=\"%s\" font-size=\"11\">%s</text>"
                   % (_jl_str(L + pw + 30), _jl_str(yy + 10), _esc(c)))
    out.append("</svg>")
    svg = "\n".join(out) + "\n"
    data = {"weights": pd.DataFrame({"date": d, **{c: W[:, j] for j, c in enumerate(cols)}})}
    return svg, data


# ═══════════════════════════════════════════════════════════════════════════
# tactical_simulation
# ═══════════════════════════════════════════════════════════════════════════

def _filled_attr(data):
    fl = None
    if isinstance(data, pd.DataFrame):
        fl = data.attrs.get("filled")
    return fl


def tactical_simulation(data, weights, *, rebalance=("switch", "month", "quarter", "year"), tolerance=None,
                        tolerance_type=("absolute", "relative"), lag=1, asset_args=None, **kwargs):
    """Taktische Allokation simulieren.

    Übersetzt eine Zielgewichtsreihe in Ereignis-Rebalancing von :func:`simlev.simulation`
    (``event_col``, ``event_mode="replace"``, ``event_weight``): Handel an Wechselterminen
    (nach ``lag`` Zeilen; mit ``data.attrs["filled"]`` nur Zeilen mit echten Kursen) und an
    Pflegeterminen ``rebalance``, optional mit Toleranzband ``tolerance`` (Prozent).

    Args:
        data: ``DataFrame`` mit ``date`` und Kursspalten aller Anlagen der Gewichte.
        weights: :class:`SimLevWeights`.
        rebalance: ``"switch"``, ``"month"``, ``"quarter"`` oder ``"year"``.
        tolerance: Toleranzband in Prozent (``None`` = an jedem Termin handeln).
        tolerance_type: ``"absolute"`` oder ``"relative"``.
        lag: Verzögerung in Zeilen (ganze Zahl >= 0).
        asset_args: Argumente für :func:`asset_config` über ``strategy_from_weights``.
        **kwargs: weitere Argumente für :func:`simlev.simulation`, z. B. ``tax=tax_profile()``,
            ``dca=dca_plan(...)``; das Rebalancing steuert die Funktion selbst (``rebalance.*`` und die
            alten ``event_col``, ``event_mode``, ``event_weight``, ``balance_mode``, ``balance_thresh``
            sind ein Fehler).

    Returns:
        ``SimLevResult`` mit zusätzlichem Element ``tactical`` (``weights``, ``events``,
        ``switches``, ``lag``, ``rebalance``).
    """
    rebalance = _match_arg(rebalance, ("switch", "month", "quarter", "year"))
    tolerance_type = _match_arg(tolerance_type, ("absolute", "relative"))
    if not _is_weights(weights):
        raise ValueError("weights muss ein SimLevWeights sein.")
    sim_args = dict(kwargs)
    asset_args = {} if asset_args is None else dict(asset_args)
    bad = [k for k in sim_args if k in ("event_col", "event_mode", "event_weight", "balance_mode", "balance_thresh")
           or str(k).startswith("rebalance.")]
    if bad:
        raise ValueError("tactical_simulation steuert %s selbst." % ", ".join(_unique(bad)))
    from ._sim_blocks import _sim_args_set
    sim_args = _sim_args_set({}, sim_args, "tactical_simulation")
    assets = [str(c) for c in weights.columns[1:]]
    miss = _setdiff(assets, _df_names(data))
    if miss:
        raise ValueError("Kursspalten fehlen: %s" % ", ".join(miss))
    d = _days(_to_date(_col(data, "date"), "data$date"))
    wdays = _days(np.asarray(weights["date"]))
    pos = {}
    for i, v in enumerate(wdays):
        if not math.isnan(v) and v not in pos:
            pos[v] = i
    k = np.array([pos.get(v, -1) for v in d], dtype=np.int64)
    Wall = _wmat(weights, assets)
    W = np.where((k >= 0)[:, None], Wall[np.maximum(k, 0), :], _NA) if len(d) else np.zeros((0, len(assets)))
    for j in range(W.shape[1]):
        W[:, j] = _fill_na(W[:, j], "locf", keep_leading=False)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        lv = _as_int1(lag)
    if len(lv) != 1 or lv[0] is None or lv[0] < 0:
        raise ValueError("lag muss eine ganze Zahl >= 0 sein.")
    lag = lv[0]
    n = W.shape[0]
    if lag > 0:
        fl = _filled_attr(data)
        real = np.ones(n, dtype=bool)
        if fl is not None and np.ndim(fl) == 2 and np.shape(fl)[0] == n:
            fcols = [str(c) for c in fl.columns] if isinstance(fl, pd.DataFrame) else None
            fa = [a for a in assets if fcols is not None and a in fcols]
            if fa:
                F = np.column_stack([np.asarray(fl[a], dtype=bool) for a in fa]).astype(np.float64)
                real = _rowsums(F) == 0
        tr = np.flatnonzero(real) + 1
        if not len(tr):
            tr = np.arange(1, n + 1)
        pos2 = _find_interval(np.arange(1, n + 1), tr) + lag
        eff = np.where(pos2 <= len(tr), tr[np.minimum(pos2, len(tr)) - 1], n + 1)
        W = W[np.maximum(_find_interval(np.arange(1, n + 1), eff), 1) - 1, :]
    change = np.concatenate(([False], _rowsums(np.abs(W[1:, :] - W[:-1, :])) > 1e-10)) if n > 0 else np.zeros(0, bool)
    ev = change.copy()
    if rebalance != "switch":
        ev[_period_last(d, rebalance) - 1] = True
    dp = sim_args.get("dca")
    if dp is not None:
        from .engine import calculate_dates_flags
        cal = np.arange(int(d[0]), int(d[n - 1]) + 1)
        liq = sim_args.get("liquidate")
        flg = np.asarray(calculate_dates_flags(True, dp["span"], dp["unit"], dp["days"], cal, dp["value"], dp["anchor"],
                                               dp["start"], dp["skip"], False if liq is None else liq), dtype=bool)
        j = _find_interval(cal[flg].astype(np.float64) - 1e-9, d) + 1
        ev[j[j <= n] - 1] = True
    if n:
        ev[0] = False
    df = data.copy()
    fl = _filled_attr(data)
    df.attrs = dict(data.attrs) if isinstance(data, pd.DataFrame) else {}
    if fl is not None:
        df.attrs["filled"] = fl
    wcols = [".tw_" + a for a in assets]
    for j, c in enumerate(wcols):
        df[c] = W[:, j]
    df[".tev"] = ev
    w0 = np.maximum(W[0, :], 1e-9)
    w0 = w0 / _ldsum(w0)
    from .data_prep import strategy_from_weights
    st = strategy_from_weights(pd.Series(w0, index=assets), **asset_args)
    from ._sim_blocks import _sim_call, rebalance_plan
    # Ereignis-Rebalancing nur an den Terminen, ohne Umschichten am ersten Tag (skip = True)
    rb = rebalance_plan(event_col=".tev", event_mode="replace", skip=True,
                        event_weight={a: c for a, c in zip(assets, wcols)}, thresh=tolerance, thresh_type=tolerance_type)
    res = _sim_call(df, st, {"rebalance": rb, **sim_args})
    tw = _as_weights_m(_as_dates(d), W, assets, weights.attrs.get("source"))
    res["tactical"] = {"weights": tw, "events": _as_dates(d[ev]), "switches": int(change.sum()), "lag": lag,
                       "rebalance": rebalance}
    return res


# plot.SimLevWeights (SVG, ``SimLevPlot``) wie Julias ``_plot_method(plot_SimLevWeights, "SimLevWeights")``
from .svg import _plot_method  # noqa: E402

SimLevWeights.plot = _plot_method(plot_SimLevWeights, "SimLevWeights")

# Rechnen mit NA (signalisierendes NaN) ohne numpy-Warnung "invalid value" wie in R (gemeinsamer Helfer)
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), list(__all__) + ["_as_weights", "_hold_rows", "_period_last", "_rowsums", "_rowmeans", "_colmeans", "_ldsum"])  # tactical_rules: env aus dem Aufrufer (env_from_caller)
