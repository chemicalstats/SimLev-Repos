"""Taktische Allokation über zeitvariable Zielgewichte (Gegenstück zu ``r/R/tactical.R``).

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

from . import _ext
from ._r import fmt as _fmt
from ._r.base import env_from_caller
from ._r import libm as _libm
from ._r.rnum import r_cumsum, r_mean_int, r_rowmeans, r_rowsums as _rowsums, r_sum
from .svg import _alloc_c, _alloc_ramp, _esc, _jl_str
from ._util import _dates, _days
from .data_prep import _civil_to_days, _find_interval_int as _find_interval, _to_date
from .data_prep import _names as _df_names   # seit 1.6.4 eine Fassung
from ._util import _MISSING, _unique
from ._util import _colmeans
from .backcast import _fill_na
from .data_prep import _e5_choice, _e5_data_dates, _e5_lookbacks, _e5_names, _e5_numcols, _e5_weights
from ._pruefen import (chk_bool1, chk_int1, chk_is_factor, chk_max, chk_name1, chk_nofactor, chk_num1,
                       chk_date1, chk_stop)


__all__ = ["SimLevWeights", "signal_state", "momentum_score", "tactical_rules", "tactical_rotation",
           "tactical_target_volatility", "tactical_conditional_volatility", "tactical_glidepath", "tactical_blend",
           "tactical_simulation", "print_SimLevWeights", "plot_SimLevWeights"]

_NAN = float("nan")      # R's NaN
_NA = _fmt.NA_REAL       # R's NA_real_



# ═══════════════════════════════════════════════════════════════════════════
# R-Hilfen
# ═══════════════════════════════════════════════════════════════════════════

def _warn(msg):
    warnings.warn(msg, UserWarning, stacklevel=3)


def _message(msg):
    from .data_prep import message
    message(msg)


# Summen und Mittel über die C-Kerne core/slc_rbase.cpp (long double wie R; wie Julia)
def _rowmeans(M):
    M = np.asarray(M, dtype=np.float64)
    if M.ndim == 1:
        M = M.reshape(-1, 1)
    return r_rowmeans(M)


def _ldsum(x):
    """``sum(x)`` (long double, sequenziell)."""
    return r_sum(np.asarray(x, dtype=np.float64).ravel())


def _mean_int(x):
    """``mean`` eines logischen/ganzzahligen Vektors (long double Summe / n)."""
    a = np.asarray(x).ravel().astype(np.int64)
    if a.size == 0:
        return _NAN
    return r_mean_int(a)


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
        return x.dtype.kind in "iuf" and not isinstance(x.index, pd.RangeIndex)   # seit 1.6.4 ohne Wahrheitswerte wie R (T3-N8)
    if isinstance(x, Mapping):
        return len(x) > 0 and all(isinstance(v, (int, float, np.integer, np.floating)) and not isinstance(v, bool)
                                  for v in x.values())
    return False


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


def _datefmt1(day):
    """``format(<Date>)`` eines Tages (float)."""
    s = _fmt.format(_dates([day]))
    return s if isinstance(s, str) else str(list(s)[0])


def _ymd(days):
    """Tage -> (Jahr, Monat 1-12, Tag) als int-Arrays."""
    d = _dates(days)
    y = d.astype("datetime64[Y]").astype(np.int64) + 1970
    m = (d.astype("datetime64[M]").astype(np.int64) % 12) + 1
    dd = (d - d.astype("datetime64[M]").astype("datetime64[D]")).astype(np.int64) + 1
    return y, m, dd


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
        jan1 = _civil_to_days(y, np.ones_like(y), np.ones_like(y))
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


def _is_chr(v):
    """R-Zeichenvektor? Text-Feld (``U``/``S``) oder Folge mit mindestens einem ``str`` (``None``/NA daneben gilt als
    ``NA_character_``)."""
    if isinstance(v, str):
        return True
    if not isinstance(v, (list, tuple, np.ndarray, pd.Series, pd.Index, pd.api.extensions.ExtensionArray)):
        return False
    if isinstance(getattr(v, "dtype", None), pd.StringDtype):   # pandas-Text, auch nur aus NA
        return True
    a = np.asarray(v.to_numpy() if isinstance(v, (pd.Series, pd.Index)) else v)
    if a.dtype.kind in "US":
        return True
    return a.dtype == object and any(isinstance(x, str) for x in a.ravel())


def _lgl(v):
    """Logischer Vektor mit NA (None/nan) -> (Werte, NA-Maske); Schnellweg für bool- und float64-Felder (seit 1.6.1)."""
    a = np.asarray(v.to_numpy() if isinstance(v, (pd.Series, pd.Index)) else v)
    if a.dtype == np.bool_:
        return a.ravel().astype(bool), np.zeros(a.size, dtype=bool)
    if a.dtype == np.float64:
        a = a.ravel()
        na = np.isnan(a)
        return ~na & (a != 0), na
    a = np.asarray(a, dtype=object).ravel()
    na = np.array([x is None or (isinstance(x, float) and math.isnan(x)) or x is pd.NA for x in a], dtype=bool)
    val = np.array([False if m else bool(x) for x, m in zip(a, na)], dtype=bool)
    return val, na


def _e5_sigvec_len(v):
    """Länge eines Signalvektors (Wahrheitswerte oder Zahlen 0/1, NA erlaubt, eindimensional) oder ``None``."""
    if chk_is_factor(v) or isinstance(v, str):
        return None
    if isinstance(v, pd.Series) and isinstance(v.dtype, pd.StringDtype):   # pandas-Text, auch nur aus NA, wie R
        return None                                                         # NA_character_ (seit 1.6.4 K43 T3-N10)
    if isinstance(v, (bool, np.bool_, int, float, np.integer, np.floating)):
        a = np.array([v], dtype=object)
    elif isinstance(v, (list, tuple, np.ndarray, pd.Series)) or (
            isinstance(v, pd.api.extensions.ExtensionArray) and not pd.api.types.is_string_dtype(v.dtype)):   # auch pd.array (boolean mit pd.NA; K43 KE), Text wie R nicht
        a = np.asarray(v.to_numpy() if isinstance(v, pd.Series) else v, dtype=object)
        if a.ndim != 1:
            return None
    else:
        return None
    for e in a:
        if e is None or e is pd.NA or isinstance(e, (bool, np.bool_)):
            continue
        if isinstance(e, (int, float, np.integer, np.floating)) and (math.isnan(float(e)) or float(e) in (0.0, 1.0)):
            continue
        return None
    return len(a)


def _e5_signal(signal, fn, i=None):
    """Signal ``{"buy": ..., "sell": ...}``: beide vorhanden, je Wahrheitswerte oder 0/1 (NA erlaubt), gleich lang
    (R ``.e5_signal``; seit 1.6.4, Entscheidung 1)."""
    ok = isinstance(signal, Mapping) and "buy" in signal and "sell" in signal
    if ok:
        lb, ls = _e5_sigvec_len(signal["buy"]), _e5_sigvec_len(signal["sell"])
        ok = lb is not None and lb == ls
    if not ok:
        if i is None:
            chk_stop("e5.signal", fn)
        chk_stop("e5.when", fn, i)
    return signal


def signal_state(signal, *, initial=False):
    """Signale in einen dauerhaften Zustand übersetzen.

    ``True`` ab einem Kaufsignal bis zum nächsten Verkaufssignal (wie die Ein-/Ausstiegslogik von
    ``simulation()``). Zeilen, in denen beide Signale ``False`` sind (z. B. innerhalb eines Hysterese-Bands) oder
    beide ``True``, ändern den Zustand nicht. So lassen sich Signale als "investiert ja/nein" auswerten oder als
    Bedingung in ``tactical_rules()`` verwenden (dort geschieht die Umwandlung automatisch).

    Args:
        signal: ``{"buy": ..., "sell": ...}`` mit logischen Vektoren gleicher Länge (z. B. aus ``signal_sma()``);
            NA vorher durch ``False`` ersetzen (die Signal-Bausteine liefern keine NA).
            Seit 1.6.4 nur TRUE/FALSE oder 0/1 (NA erlaubt) und gleiche Länge, sonst Fehler.
        initial: Logischer Zustand vor dem ersten Signal (Standard ``False`` = nicht investiert).

    Returns:
        Logischer Vektor gleicher Länge (``True`` = investiert).

    Beispiel::

        import numpy as np, simlev
        x = np.array([100, 102, 105, 103, 99, 97, 100, 104])
        print(simlev.signal_state({"buy": x > 101, "sell": x < 98}))
    """
    _e5_signal(signal, "signal_state")                     # seit 1.6.4 (Entscheidung 1; B-024)
    initial = chk_bool1(initial, "signal_state", "initial")
    bv, sv = _sig_part(signal, "buy"), _sig_part(signal, "sell")
    # Text lehnt _e5_signal ab wie R (seit 1.6.4 K43 T3-N10 ohne die Fehler von R's ifelse(b & !s, …), bis dahin bei
    # pandas-Text nur aus NA erreichbar)
    b, bna = _lgl(bv)
    s, sna = _lgl(sv)
    n = len(b)                  # buy und sell gleich lang (_e5_signal; seit 1.6.4 K43 T3-N10 ohne Recyceln)
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
        first = _civil_to_days(y2, mo2 + 1, np.ones_like(y2)).astype(np.float64)
        nxt = _civil_to_days(y2 + (mo2 + 1) // 12, (mo2 + 1) % 12 + 1, np.ones_like(y2)).astype(np.float64)
        target = first + np.minimum(mday, (nxt - first).astype(np.int64)) - 1
        back.append(_find_interval(target, d))
    return back


def momentum_score(data, assets, *, lookbacks=(1, 3, 6, 12), type=("average", "13612w")):  # noqa: A002
    """Momentum-Score: mittlere Rendite über mehrere Rückblicke (Kalendermonate).

    Mittlere Rendite über mehrere Rückblicke (Monate, kalenderbasiert) je Anlage, z. B. der "13612"-Score (1, 3,
    6, 12 Monate). Mit ``type = "13612w"`` gewichtet wie bei Keller & Keuning: (12 r_1 + 4 r_3 + 2 r_6 + r_12) /
    4.

    Args:
        data: DataFrame mit Spalte ``date`` (Klasse Date) und Kursspalten (Niveaus).
            Seit 1.6.4 Datum aufsteigend ohne NA, Kursspalten numerisch (kein Faktor).
        assets: Zeichenvektor der Kursspalten.
        lookbacks: Rückblicke in Kalendermonaten (Standard ``[1, 3, 6, 12]``); bei ``type = "13612w"`` ignoriert.
            Seit 1.6.4 ganze Zahlen von 1 bis 1200 (kein Blick in die Zukunft).
        type: ``"average"`` (Standard; ungewichtetes Mittel der Renditen) oder ``"13612w"`` (gewichtet, Rückblicke
            fest 1, 3, 6, 12).

    Returns:
        Numerische Matrix Zeilen von ``data`` x ``assets`` mit dem Score als Anteil (NA, solange die Historie für
        den längsten Rückblick zu kurz ist).

    Details:
        Die Rendite r_m je Zeile ist der aktuelle Kurs geteilt durch den Kurs der letzten Zeile mit Datum am oder
        vor dem Tag m Monate zuvor, minus 1 (als Anteil, 0.05 = 5 %). Hat der Zielmonat weniger Tage, gilt sein
        letzter Tag (31.03. minus 1 Monat = 28.02. bzw. 29.02.; in 0.5.0 (Vorfassung vor den Korrekturen) lief der
        Rückblick wie bei ``seq.Date()`` in den Folgemonat über, z. B. auf den 02.03.). Lücken in den Kursen
        werden per LOCF gefüllt; Handels- und Kalendertagsdaten funktionieren gleichermassen. Grundlage für
        ``tactical_rotation()``.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 730
        d = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=n)})
        d["aktien"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        d["anleihen"] = 100 * np.cumprod(1 + rng.normal(1e-4, 0.003, n))
        ms = simlev.momentum_score(d, ["aktien", "anleihen"])
        print(ms.tail(3))
    """
    fn = "momentum_score"
    type = _e5_choice(type, ("average", "13612w"), fn, "type")  # noqa: A001
    d = _days(_e5_data_dates(data, fn, "momentum_score: data$date"))   # seit 1.6.4 (K42 E5)
    n = len(d)
    assets = _e5_names(assets, fn, "assets")
    _e5_lookbacks(lookbacks, fn)                          # seit 1.6.4 ganze Zahlen 1 bis 1200 (B-025)
    miss = _setdiff(assets, _df_names(data))
    if miss:
        raise ValueError("momentum_score: Kursspalte(n) fehlen: %s" % ", ".join(miss))
    _e5_numcols(data, assets, fn)                         # Entscheidung 15, B-009
    if type == "13612w":
        lookbacks = [1, 3, 6, 12]
    lookbacks = list(np.atleast_1d(np.asarray(lookbacks, dtype=object)))
    # seit 1.6.0 im Kern (sl_mom_score: Rückblickzeilen ganzzahlig, LOCF, Renditen, Scores) bei sortierten,
    # endlichen Daten (Jahre 1000-9000); sonst wie bisher
    lb = [_as_int1(m)[0] for m in lookbacks]
    dv = np.asarray(d, dtype=np.float64)
    if lb and (np.isnan(dv).any() or np.any(np.diff(dv) < 0)):     # wie findInterval in R (seit 1.6.0 auch hier)
        from ._r.linalg import RError
        raise RError("'vec' must be sorted non-decreasingly and not contain NAs")
    if n and assets and lb and all(isinstance(v, (int, np.integer)) and abs(v) <= 12000 for v in lb) and \
            np.all(np.isfinite(dv)) and dv.min() >= -354285 and dv.max() <= 2568019 and np.all(np.diff(dv) >= 0):
        X = np.empty((len(assets), n))
        for j, a in enumerate(assets):
            X[j] = _num(_col(data, a))
        S = np.empty((len(assets), n))
        _ext.slc_mom_score(np.ascontiguousarray(dv), np.asarray(lb, dtype=np.int32), X, int(type == "13612w"), S)
        return pd.DataFrame(np.ascontiguousarray(S.T), columns=assets)
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


def _as_logical(v):
    if isinstance(v, (bool, np.bool_)) or (np.ndim(v) == 0 and not isinstance(v, str)):
        v = [v]
    a = np.asarray(v.to_numpy() if isinstance(v, (pd.Series, pd.Index)) else v)
    if a.dtype == np.bool_:          # Schnellweg (seit 1.6.1): gleiche Werte wie die Schleife
        return a.ravel().astype(bool)
    if a.dtype == np.float64:
        a = a.ravel()
        return ~np.isnan(a) & (a != 0)
    a = np.asarray(a, dtype=object).ravel()
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

    Geordnete Bedingungen wählen je Tag ein Zielportfolio; die erste zutreffende Regel gewinnt, sonst gilt
    ``default``. Bedingungen sind logische Vektoren, Ausdrücke als Zeichenkette (ausgewertet in ``data``, z. B.
    ``"inflation > 3"``) oder Signale aus den Signal-Bausteinen (``{"buy": ..., "sell": ...}``, als Zustand mit
    Hysterese).

    Args:
        data: DataFrame mit Spalte ``date`` (und den in Bedingungen verwendeten Spalten, z. B. aus
            ``series_align_macro()``).
        rules: Liste von Regeln ``{"when": ..., "weights": {"A": 0.6, "B": 0.4}}``, in Prioritätsreihenfolge.
            ``when``: logischer Vektor der Länge ``nrow(data)``, Zeichenkette mit einem R-Ausdruck (ausgewertet in
            ``data``, dann in der aufrufenden Umgebung) oder ``{"buy": ..., "sell": ...}`` (wird mit
            ``signal_state()`` in einen Zustand übersetzt); NA gilt als ``False``. ``weights``: benannter Vektor
            Kursspalte -> Gewicht als Anteil.
            Seit 1.6.4 je Regel nur die Felder when und weights; Gewichte endlich und >= 0. ``when`` darf auch
            eine Funktion von ``data`` sein (wie in R seit 1.6.4); Regeltexte gelten in allen drei Sprachen im
            gemeinsamen Umfang (Spalten, Variablen und eigene Funktionen aus ``env``, Operatoren, ``if`` und die
            Funktionen von :mod:`simlev._r.rexpr`; R lehnt seit 1.6.4 Texte außerhalb davon ebenso ab).
        default: Benannter Gewichtsvektor (Anteile) für Zeilen, in denen keine Regel zutrifft.
        env: Mapping für freie Variablen und Funktionen in Bedingungen (Voreinstellung: Namensraum des Aufrufers).

    Returns:
        ``SimLevWeights``: DataFrame mit ``date`` und je Anlage einer Spalte Zielgewicht (Anteil, Zeilensumme 1),
        mit Attributen ``regime`` (Nummer der aktiven Regel je Zeile, 0 = ``default``) und ``source``. ``print()``
        zeigt Mittel, Minimum, Maximum und letztes Gewicht in Prozent sowie die Zahl der Wechsel, ``plot()`` die
        Gewichte als gestapelte Flächen.

    Details:
        Entschieden wird in jeder Zeile (kein Rhythmus); das Zielgewicht gilt als nach Schluss des Tages bekannt.
        Gehandelt wird erst in ``tactical_simulation()``, dort mit Verzögerung ``lag`` und optionalem
        Pflegerhythmus ``rebalance``. Gewichte werden je Zeile auf die Summe 1 normiert (negative Werte als 0);
        Anlagen, die nur in anderen Regeln vorkommen, erhalten 0.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 500
        d = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=n)})
        d["A"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        d["B"] = 100 * np.cumprod(1 + rng.normal(1e-4, 0.003, n))
        w = simlev.tactical_rules(d, [{"when": simlev.signal_sma(d["A"], n=200), "weights": {"A": 1}}], {"B": 1})
        print(w)
    """
    fn = "tactical_rules"
    _e5_data_dates(data, fn, "date")                      # seit 1.6.4 (K42 E5)
    n = _nrow(data)
    if not isinstance(rules, (list, tuple)):   # leere Liste: nur default
        chk_stop("liste", fn, "rules")
    rules = list(rules)
    for i, r in enumerate(rules, start=1):
        if not (isinstance(r, Mapping) and "when" in r and "weights" in r):
            chk_stop("e5.regel", fn, i)
        bad = [k for k in r if k not in ("when", "weights")]   # Entscheidung 11 sinngemäß
        if bad:
            chk_stop("e5.regel_feld", fn, bad[0], i)
        _e5_weights(r["weights"], fn, "rules[[%d]]$weights" % i)
        w = r["when"]
        if isinstance(w, Mapping):
            _e5_signal(w, fn, i)
        elif not (isinstance(w, str) or callable(w) or _is_chr(w) or _e5_sigvec_len(w) is not None):
            chk_stop("e5.when", fn, i)
    _e5_weights(default, fn, "default")

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
        elif _is_chr(w):
            # R: eval(parse(text = w)) – jedes Element ein Ausdruck (NA als "NA"), Ergebnis der letzte (seit 1.6.3;
            # bis 1.6.2 wurde ein Textvektor als logischer Vektor gelesen)
            a = np.asarray(w.to_numpy() if isinstance(w, (pd.Series, pd.Index)) else w, dtype=object).ravel()
            v = []
            for z in a:
                v = _eval_when(z if isinstance(z, str) else "NA", data, env)
        else:
            v = w
        v = _as_logical(v)
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

    An jedem Entscheidungstermin (Periodenende) werden die Anlagen nach ihrem Momentum-Score sortiert und die
    besten ``top`` gehalten.

    - **Absolutes Momentum** (``absolute = True``, Dual Momentum nach Antonacci): Ein gewählter Platz mit
      negativem Score geht an die beste sichere Anlage aus ``safe``.
    - **Canary/Breite** (``canary``, Keller & Keuning): Bei b Canary-Anlagen mit negativem Score geht der Anteil
      min(1, b / B) an die sichere Anlage (B = ``breadth``).

    Args:
        data: DataFrame mit Spalte ``date`` (Klasse Date) und Kursspalten (Niveaus) aller Anlagen aus ``assets``,
            ``safe`` und ``canary``.
        assets: Zeichenvektor der Risikoanlagen für die Rotation.
        top: Anzahl gehaltener Anlagen (Standard 1; 1 bis Anzahl ``assets``).
            Seit 1.6.4 ganze Zahl ohne Abschneiden.
        safe: Zeichenvektor der sicheren Anlage(n); bei mehreren wird die mit dem besten Score gewählt. Pflicht,
            wenn ``absolute = True`` (Standard) oder ``canary`` gesetzt ist (sonst Fehler).
        absolute: Logisch: absoluten Momentum-Filter anwenden (Standard ``True``; Score < 0 => sichere Anlage).
        canary: Optional Zeichenvektor der Canary-Anlagen (Standard ``None`` = kein Canary-Schutz).
        breadth: Schutzschwelle B als Anzahl Anlagen (mindestens 1; Standard ``None`` = Anzahl Canary-Anlagen).
            Seit 1.6.4 ganze Zahl.
        lookbacks, type: Siehe ``momentum_score()`` (Rückblicke in Monaten; ``"average"`` oder ``"13612w"``).
        every: Entscheidungsrhythmus: ``"month"`` (Standard), ``"week"`` (ISO-Woche) oder ``"quarter"``.
        weighting: Gewichtung der gewählten Anlagen: ``"equal"`` (Standard) oder ``"inverse_vol"`` (umgekehrt
            proportional zur Wurzel der mittleren quadrierten Log-Renditen der letzten 63 Zeilen).
            Seit 1.6.4 liegen die Termine dann erst ab Zeile 63 (volles Fenster; bis 1.6.3 brach jeder frühere
            Termin ab, mit Wochen- und Monatskursen auch mit den Standardrückblicken).

    Returns:
        ``SimLevWeights`` (DataFrame mit ``date`` und Zielgewichten je Anlage aus ``assets`` und ``safe``,
        Anteile) mit Attributen ``scores`` (Matrix der Momentum-Scores aller Anlagen je Zeile) und
        ``decision_rows`` (Zeilennummern der Entscheidungstermine).

    Details:
        Entscheidungstermine sind die letzten vorhandenen Zeilen jeder Periode von ``every``, ab dem ersten
        Termin, an dem mindestens ``top`` Anlagen einen Score haben. Das Zielgewicht gilt ab dem Termin bis zum
        nächsten; davor liegt alles in ``safe[1]`` (ohne ``safe`` in ``assets[1]``). ``every`` legt nur den
        Entscheidungsrhythmus fest; gehandelt wird in ``tactical_simulation()`` (Verzögerung ``lag``,
        Pflegerhythmus ``rebalance``).

    Literatur:
        Antonacci, G. (2014), Dual Momentum Investing; Keller, W. J. & Keuning, J. W. (2018), Breadth Momentum and
        the Canary Universe: Defensive Asset Allocation (DAA), SSRN 3212862.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 1460
        d = pd.DataFrame({"date": pd.date_range("2015-01-01", periods=n)})
        d["aktien"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        d["anleihen"] = 100 * np.cumprod(1 + rng.normal(1e-4, 0.003, n))
        d["geld"] = 100 * np.cumprod(np.full(n, 1 + 0.01 / 365))
        print(simlev.tactical_rotation(d, ["aktien", "anleihen"], safe="geld"))
    """
    fn = "tactical_rotation"
    type = _e5_choice(type, ("average", "13612w"), fn, "type")  # noqa: A001
    every = _e5_choice(every, ("month", "week", "quarter"), fn, "every")
    weighting = _e5_choice(weighting, ("equal", "inverse_vol"), fn, "weighting")
    # seit 1.6.4 (K42 E5): Datum, Namen, Wahrheitswert, ganze Zahlen; Meldungen ohne Eingabewert (Entscheidung 8)
    _e5_data_dates(data, fn, "momentum_score: data$date")
    assets = _e5_names(assets, fn, "assets")
    safe = _e5_names(safe, fn, "safe", null_ok=True) or []
    canary = _e5_names(canary, fn, "canary", null_ok=True) or []
    absolute = chk_bool1(absolute, fn, "absolute")
    _e5_lookbacks(lookbacks, fn)
    if (absolute or len(canary)) and not len(safe):
        raise ValueError("absolute bzw. canary brauchen eine sichere Anlage 'safe'.")
    top = int(chk_int1(top, fn, "top", lo=1))
    if top > len(assets):
        raise ValueError("top muss zwischen 1 und der Anzahl der Anlagen in assets (%d) liegen." % len(assets))
    if breadth is not None:
        breadth = chk_int1(breadth, fn, "breadth", lo=1)
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
    if weighting == "inverse_vol":
        # Termine erst ab Zeile 63, wenn das Fenster der Schwankung voll ist (seit 1.6.4, Entscheidung 144; bis
        # 1.6.3 Abbruch "Zeilen ohne positive Gewichte" bei jedem früheren Termin)
        rows = rows[rows >= 63]
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
    out = _as_weights_m(_dates(d), H, out_assets, "rotation")
    out.attrs["scores"] = Sdf
    out.attrs["decision_rows"] = rows
    return out


# ═══════════════════════════════════════════════════════════════════════════
# Zielvolatilität, bedingte Volatilitätssteuerung
# ═══════════════════════════════════════════════════════════════════════════

def _e5_risk_check(fn, data, weights, safe, window, ppy):
    """Gemeinsame Prüfung der Volatilitätssteuerung (R ``.e5_risk_check``; seit 1.6.4, K42 E5)."""
    _e5_data_dates(data, fn, "data$date")
    if not _is_weights(weights):
        if not _is_numeric_named(weights):
            raise ValueError("weights: SimLevWeights oder benannter Gewichtsvektor erwartet.")
        _e5_weights(weights, fn, "weights")
    safe = chk_name1(safe, fn, "safe")
    window = chk_int1(window, fn, "window", lo=2)
    ppy = chk_num1(ppy, fn, "ppy", lo=0, lo_open=True, null_ok=True)
    wn = [str(c) for c in weights.columns[1:]] if _is_weights(weights) else _named(weights)[0]
    nms = _df_names(data)
    _e5_numcols(data, [c for c in _unique(list(wn) + [safe]) if c in nms], fn)
    return safe, window, ppy


def _risk_vol(data, weights, safe, window, ppy):
    """``.risk_vol``: Volatilität des Risikoportfolios."""
    d = _days(_to_date(_col(data, "date"), "data$date"))
    n = len(d)
    if not _is_weights(weights):
        if not _is_numeric_named(weights):
            raise ValueError("weights: SimLevWeights oder benannter Gewichtsvektor erwartet.")
        nm, vals = _named(weights)
        weights = _as_weights_m(_dates(d), np.tile(vals, (n, 1)), nm, "static")
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
    return _as_weights_m(_dates(rv["d"]), W, rv["risky"] + [safe], source)


def _g(x):
    return _fmt.sprintf("%g", float(x))


def tactical_target_volatility(data, weights, safe, *, target=10, window=63, max_exposure=1,
                      every=("month", "week", "day", "quarter"), ppy=None):
    """Zielvolatilität: Risikoanteil ``min(max_exposure, (target / 100) / vol)``.

    Skaliert den Risikoteil einer Gewichtsreihe so, dass die geschätzte Volatilität des Risikoportfolios dem Ziel
    entspricht; der Rest geht in die sichere Anlage. Die Volatilität wird aus den Tagesrenditen der Risikoanlagen
    mit den aktuellen Gewichten über ``window`` Zeilen mit Kursbewegung geschätzt (Tage ohne Bewegung, etwa
    Wochenenden, zählen nicht).

    Args:
        data: DataFrame mit Spalte ``date`` (Klasse Date) und Kursspalten (Niveaus) der Risikoanlagen und der
            sicheren Anlage.
        weights: Gewichte des Risikoportfolios: ``SimLevWeights`` (z. B. aus ``tactical_rotation()``) oder
            benannter Gewichtsvektor (Anteile, statisch). Eine darin enthaltene sichere Anlage zählt nicht zum
            Risikoteil.
        safe: Name der Kursspalte der sicheren Anlage (Zeichenkette).
        target: Zielvolatilität in Prozent p. a. (10 = 10 %; Standard 10). Werte unter 1 ergeben eine Warnung
            (vermutlich als Anteil angegeben).
        window: Fensterlänge der Volatilitätsschätzung in Zeilen mit Kursbewegung (Standard 63).
            Seit 1.6.4 ganze Zahl >= 2.
        max_exposure: Höchster Risikoanteil als Anteil (Standard 1 = ohne Hebel; Werte > 1 sind nicht erlaubt, da
            die Engine keinen Kredit kennt).
        every: Anpassungsrhythmus des Risikoanteils: ``"month"`` (Standard), ``"week"``, ``"day"`` oder
            ``"quarter"``.
        ppy: Tage mit Kursbewegung je Jahr für die Annualisierung. Standard ``None`` = aus den Daten ermittelt
            (Zahl der Tage mit Bewegung geteilt durch die Länge des Zeitraums in Jahren, z. B. rund 252 bei
            Börsentagen, 365 bei einem Index, der auch am Wochenende notiert).

    Returns:
        ``SimLevWeights`` (DataFrame mit ``date`` und Zielgewichten der Risikoanlagen und von ``safe``, Anteile)
        mit Attributen ``exposure`` (Risikoanteil je Zeile, Anteil) und ``volatility`` (geschätzte Volatilität des
        Risikoportfolios je Zeile, Anteil p. a., 0.15 = 15 %).

    Details:
        Der Risikoanteil (Exposure) ist ``min(max_exposure, (target / 100) / vol)`` mit der geschätzten
        Volatilität ``vol`` als Anteil p. a.; er wird an den Terminen von ``every`` (letzte vorhandene Zeile je
        Periode) neu gesetzt und bis zum nächsten Termin gehalten. Vor dem ersten Termin mit vollem Fenster ist
        der Risikoanteil 0 (alles in ``safe``); anders als bei ``tactical_conditional_volatility()``, wo vorher
        der Grundanteil ``base`` gilt (hier gibt es keinen Grundanteil). ``every`` legt nur den Anpassungsrhythmus
        der Zielgewichte fest; gehandelt wird in ``tactical_simulation()``.

    Literatur:
        Moreira, A. & Muir, T. (2017), Volatility-Managed Portfolios, Journal of Finance 72(4).

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 1460
        d = pd.DataFrame({"date": pd.date_range("2015-01-01", periods=n)})
        d["aktien"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        d["anleihen"] = 100 * np.cumprod(1 + rng.normal(1e-4, 0.003, n))
        d["geld"] = 100 * np.cumprod(np.full(n, 1 + 0.01 / 365))
        tv = simlev.tactical_target_volatility(d, {"aktien": 0.8, "anleihen": 0.2}, "geld", target=8)
        print(tv)
    """
    fn = "tactical_target_volatility"
    every = _e5_choice(every, ("month", "week", "day", "quarter"), fn, "every")
    safe, window, ppy = _e5_risk_check(fn, data, weights, safe, window, ppy)   # seit 1.6.4 (K42 E5)
    target = chk_num1(target, fn, "target", lo=0, lo_open=True)
    max_exposure = chk_num1(max_exposure, fn, "max_exposure", lo=0)
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


def _quantile7v(x, p):
    """Quantile Typ 7 für mehrere Wahrscheinlichkeiten in einem Aufruf (eine Teilsortierung); Achtung: bei Daten mit
    +0 und -0 kann das Vorzeichen einer Null von Einzelaufrufen abweichen."""
    from ._r import stats as _st
    q = _st.quantile(np.asarray(x, dtype=np.float64), p, names=False, type=7)
    return [float(v) for v in np.asarray(q, dtype=np.float64).ravel()]


def tactical_conditional_volatility(data, weights, safe, *, base=1, upper=0.8, lower=0.2, target=None, window=63,
                           min_exposure=0, max_exposure=1, min_history=3, scaling=("inverse", "fixed"),
                           high_exposure=None, low_exposure=None, every=("month", "week", "day", "quarter"),
                           ppy=None):
    """Bedingte Volatilitätssteuerung: nur in extremen Phasen skalieren.

    Wie ``tactical_target_volatility()``, aber nur in extremen Volatilitätsphasen: Liegt die geschätzte
    Volatilität des Risikoportfolios über ihrem ``upper``-Quantil, wird der Risikoanteil gesenkt, liegt sie unter
    dem ``lower``-Quantil, wird er erhöht; dazwischen bleibt er beim Grundanteil ``base``. Das spart die meisten
    Umschichtungen (und damit Steuern und Kosten) der ständigen Steuerung (Bongaerts, Kang & van Dijk 2020).

    Args:
        data: DataFrame mit Spalte ``date`` (Klasse Date) und Kursspalten (Niveaus) der Risikoanlagen und der
            sicheren Anlage.
        weights: Gewichte des Risikoportfolios: ``SimLevWeights`` (z. B. aus ``tactical_rotation()``) oder
            benannter Gewichtsvektor (Anteile, statisch). Eine darin enthaltene sichere Anlage zählt nicht zum
            Risikoteil.
        safe: Name der Kursspalte der sicheren Anlage (Zeichenkette).
        base: Grundanteil des Risikoportfolios in normalen Phasen als Anteil (0 bis ``max_exposure``; Standard 1).
        upper: Quantil-Wahrscheinlichkeit (zwischen 0 und 1), ab der die Volatilität als hoch gilt (Standard 0.8 =
            oberstes Fünftel der bisherigen Werte).
        lower: Quantil-Wahrscheinlichkeit (zwischen 0 und ``upper``), unter der sie als niedrig gilt (Standard
            0.2); ``None`` schaltet das Hochskalieren ab.
        target: Vergleichsvolatilität in Prozent p. a. (10 = 10 %); Standard ``None`` = Mittel der bisherigen
            Volatilität (expandierend, monatlich aktualisiert).
        window: Fensterlänge der Volatilitätsschätzung in Zeilen mit Kursbewegung (Standard 63).
        min_exposure, max_exposure: Untere und obere Grenze des Risikoanteils als Anteil (Standard 0 und 1;
            ``min_exposure`` höchstens ``base``, ``max_exposure`` höchstens 1).
        min_history: Mindesthistorie der Volatilitätsschätzung in Jahren (Standard 3), bevor gesteuert wird. Ist
            sie länger als die vorhandene Historie, wird nie gesteuert (mit Warnung).
            Seit 1.6.4 höchstens 100 Jahre.
        scaling: ``"inverse"`` (Standard): Anteil ``base * target / vol``; ``"fixed"``: feste Anteile
            ``high_exposure`` und ``low_exposure``.
        high_exposure, low_exposure: Feste Risikoanteile (Anteile) für ``scaling = "fixed"`` in hohen bzw.
            niedrigen Phasen; ``high_exposure`` höchstens ``base``, ``low_exposure`` zwischen ``base`` und
            ``max_exposure`` (Pflicht, wenn ``lower`` gesetzt ist).
        every: Anpassungsrhythmus des Risikoanteils: ``"month"`` (Standard), ``"week"``, ``"day"`` oder
            ``"quarter"``.
        ppy: Tage mit Kursbewegung je Jahr für die Annualisierung. Standard ``None`` = aus den Daten ermittelt
            (Zahl der Tage mit Bewegung geteilt durch die Länge des Zeitraums in Jahren, z. B. rund 252 bei
            Börsentagen, 365 bei einem Index, der auch am Wochenende notiert).

    Returns:
        ``SimLevWeights`` (DataFrame mit ``date`` und Zielgewichten, Anteile) mit Attributen ``exposure``
        (Risikoanteil je Zeile, Anteil), ``volatility`` (geschätzte Volatilität, Anteil p. a.), ``state`` (Phase
        am letzten Anpassungstermin, je Zeile fortgeschrieben: -1 niedrig, 0 normal, 1 hoch) und ``thresholds``
        (DataFrame mit ``date``, ``lower``, ``upper`` und ``target`` als Anteile p. a., wie sie zum jeweiligen
        Monatsende bekannt waren; NA vor ``min_history``).

    Details:
        Die Quantile und der langfristige Vergleichswert werden nur aus der Volatilität bis zum jeweiligen Tag
        berechnet (expandierendes Fenster, monatlich aktualisiert) – ohne Blick in die Zukunft. Vor
        ``min_history`` Jahren Historie gilt der Grundanteil.

        In einer extremen Phase ist der Risikoanteil ``base * target / vol``, oben höchstens ``base``, unten
        mindestens ``base``, begrenzt auf ``[min_exposure, max_exposure]``. Weil die Engine keinen Kredit kennt,
        ist ``max_exposure`` höchstens 1; Hochskalieren setzt daher ``base < max_exposure`` voraus.

        Einheiten: ``base``, ``min_exposure``, ``max_exposure``, ``high_exposure`` und ``low_exposure`` sind
        Anteile des Depots (0.8 = 80 %), ``upper`` und ``lower`` Quantil-Wahrscheinlichkeiten (0 bis 1),
        ``target`` Prozent p. a. (10 = 10 %). Die geschätzte Volatilität und die Schwellen in ``thresholds`` sind
        Anteile p. a. (0.15 = 15 %). Vor dem ersten Termin von ``every`` gilt der Grundanteil ``base``.

    Literatur:
        Bongaerts, D., Kang, X. & van Dijk, M. (2020), Conditional Volatility Targeting, Financial Analysts
        Journal 76(4), 54-71.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 4380
        d = pd.DataFrame({"date": pd.date_range("2010-01-01", periods=n)})
        d["aktien"] = 100 * np.exp(np.cumsum(rng.normal(0.0002, 0.01 * np.exp(np.sin(np.arange(1, n + 1) / 300)))))
        d["geld"] = 100 * np.cumprod(np.full(n, 1 + 0.01 / 365))
        cv = simlev.tactical_conditional_volatility(d, {"aktien": 1}, "geld", base=0.8)
        print(cv)
    """
    fn = "tactical_conditional_volatility"
    every = _e5_choice(every, ("month", "week", "day", "quarter"), fn, "every")
    scaling = _e5_choice(scaling, ("inverse", "fixed"), fn, "scaling")
    # seit 1.6.4 (K42 E5): einzelne endliche Zahlen vor den Bereichsprüfungen (B-012: NA lief in Python still)
    safe, window, ppy = _e5_risk_check(fn, data, weights, safe, window, ppy)
    base = chk_num1(base, fn, "base")
    upper = chk_num1(upper, fn, "upper")
    min_exposure = chk_num1(min_exposure, fn, "min_exposure")
    max_exposure = chk_num1(max_exposure, fn, "max_exposure")
    lower = chk_num1(lower, fn, "lower", null_ok=True)
    target = chk_num1(target, fn, "target", null_ok=True)
    high_exposure = chk_num1(high_exposure, fn, "high_exposure", null_ok=True)
    low_exposure = chk_num1(low_exposure, fn, "low_exposure", null_ok=True)
    if target is not None:
        chk_num1(target, fn, "target", lo=0, lo_open=True)
    min_history = chk_num1(min_history, fn, "min_history", lo=0)
    chk_max(min_history, 100, fn, "min_history")             # Entscheidung 46
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
    cs = r_cumsum(np.where(fin, vm, 0.0)) if n else np.zeros(0)
    cn = np.cumsum(fin.astype(np.int64))
    th = np.full((len(grid), 3), _NA)
    # seit 1.6.4 wie R/Julia seit 1.6.3 (B-081): die bisherigen Werte als Anfang von ok (aufsteigend) und beide
    # Quantile in einem Aufruf (dieselben Ordnungsstatistiken; vol_move enthält kein -0, also dieselben Bits)
    kg_ok = np.searchsorted(ok, grid, side="right")
    for gi, g in enumerate(grid):
        if not len(ok) or (d[g - 1] - first_ok) / 365.25 < min_history:
            continue
        v = vm[ok[:kg_ok[gi]] - 1]
        if lower is None:
            th[gi, 1] = _quantile7(v, upper)
        else:
            q = _quantile7v(v, [lower, upper])
            th[gi, 0] = q[0]
            th[gi, 1] = q[1]
        th[gi, 2] = cs[g - 1] / cn[g - 1] if target is None else target / 100
    thresholds = pd.DataFrame({"date": _dates(d[grid - 1]), "lower": th[:, 0], "upper": th[:, 1],
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

    Erzeugt Zielgewichte, die sich stufenweise linear von ``from`` nach ``to`` bewegen, z. B. von aktienlastig zu
    anleihenlastig bis zum Rentenbeginn. Eine Stufe beginnt in der ersten Zeile und an der letzten vorhandenen
    Zeile jeder Periode von ``every``; ihr Gewicht ist (1 - p) · from + p · to mit dem Zeitanteil p des Datums
    zwischen ``start`` (0) und ``end`` (1), begrenzt auf 0 bis 1. Vor ``start`` gilt ``from``, nach ``end`` gilt
    ``to``; bei ``start = end`` wechselt die erste Stufe an oder nach diesem Datum direkt auf ``to``, ``end`` vor
    ``start`` ist ein Fehler. Das Ergebnis geht in ``tactical_simulation()`` oder als Kern in
    ``tactical_blend()``.

    Args:
        data: DataFrame mit Spalte ``date`` (z. B. der Datensatz für ``simulation()``) oder Datumsvektor.
        from_, to: ``from`` (in Python ``from_``, da ``from`` ein Schlüsselwort ist): Benannte Gewichtsvektoren
            (Anteile) am Anfang und Ende; Anlagen, die nur in einem vorkommen, erhalten im anderen 0. Je Zeile auf
            Summe 1 normiert.
        start, end: Beginn und Ende des Uebergangs (Date oder ``"JJJJ-MM-TT"``; Standard ``None`` = erstes bzw.
            letztes Datum).
            Seit 1.6.4 keine Zahl.
        every: Rhythmus der Stufen: ``"year"`` (Standard), ``"quarter"`` oder ``"month"``.
        **kwargs: nur ``from`` (``**{"from": …}``) als Schreibweise für ``from_`` (``from`` ist in Python ein
            Schlüsselwort); andere Namen sind ein Fehler.

    Returns:
        ``SimLevWeights`` (DataFrame mit ``date`` und Zielgewichten je Anlage, Anteile).

    Beispiel::

        import pandas as pd, simlev
        gp = simlev.tactical_glidepath(pd.date_range("2025-01-01", "2045-12-31"),
                                       {"aktien": 0.9, "anleihen": 0.1}, {"aktien": 0.4, "anleihen": 0.6})
        print(gp)
    """
    if "from" in kwargs:
        from_ = kwargs.pop("from")
    if kwargs:
        raise TypeError("tactical_glidepath: unbekannte Argumente %s" % ", ".join(kwargs))
    fn = "tactical_glidepath"
    every = _e5_choice(every, ("year", "quarter", "month"), fn, "every")
    # seit 1.6.4 (K42 E5): Datum ohne NA und aufsteigend, Gewichte benannt endlich >= 0, start/end Datum
    if isinstance(data, pd.DataFrame):
        d = _days(_e5_data_dates(data, fn, "tactical_glidepath: Datum"))
    else:
        chk_nofactor(data, fn, "data")
        if data is None or (not isinstance(data, (str,)) and np.ndim(data) > 0 and len(data) == 0):
            chk_stop("zeilen_keine", fn, "data")
        d = _days(_to_date(data, "tactical_glidepath: Datum"))
        if np.isnan(d).any() or (d.size > 1 and (np.diff(d) < 0).any()):
            chk_stop("e5.datum_vektor", fn, "data")
    # R verlangt from und to (kein Standardwert); der Platzhalter steht nur, weil from_ als
    # Schlüsselwort-Ersatz einen Standardwert braucht. Meldung wie R bei fehlendem Argument.
    if from_ is _MISSING:
        raise ValueError('argument "from" is missing, with no default')
    if to is _MISSING:
        raise ValueError('argument "to" is missing, with no default')
    _e5_weights(from_, "tactical_glidepath", "from")
    _e5_weights(to, "tactical_glidepath", "to")
    start = chk_date1(start, "tactical_glidepath", "start", null_ok=True)
    end = chk_date1(end, "tactical_glidepath", "end", null_ok=True)
    fn, fv = _named(from_)
    tn, tv = _named(to)
    a = _unique((fn or []) + (tn or []))
    f = np.zeros(len(a))
    t = np.zeros(len(a))
    for k, x in zip(fn or [], fv):
        f[a.index(k)] = x
    for k, x in zip(tn or [], tv):
        t[a.index(k)] = x
    s = _days(_to_date(_dates([d[0]]) if start is None else start, "start"))[0]
    e = _days(_to_date(_dates([d[-1]]) if end is None else end, "end"))[0]
    if e < s:   # seit 1.6.4 ohne die Daten (Entscheidung 8)
        raise ValueError("tactical_glidepath: end liegt vor start; für den umgekehrten Weg from und to tauschen.")
    pl = _period_last(d, every)
    rows = np.array(_unique([1] + [int(r) for r in pl]), dtype=np.int64)
    if e > s:
        frac = np.minimum(1.0, np.maximum(0.0, (d[rows - 1] - s) / (e - s)))
    else:
        frac = (d[rows - 1] >= s).astype(np.float64)
    M = np.array([(1 - p) * f + p * t for p in frac]).reshape(len(frac), len(a))
    H = _hold_rows_m(len(d), rows, M)
    return _as_weights_m(_dates(d), H, a, "glidepath")


def tactical_blend(*args, shares=None, **kwargs):
    """Gewichtsreihen mischen (Kern-Satellit): je Zeile und Anlage ``sum_k shares_k * w_k``, dann auf Summe 1 normiert.

    Mischt mehrere Zielgewichtsreihen zu einer, z. B. einen statischen Kern oder ``tactical_glidepath()`` mit
    einem taktischen Satelliten aus ``tactical_rotation()``: Je Zeile und Anlage ist das Gewicht Σ_k shares_k ·
    w_k, anschließend auf Summe 1 normiert. Anlagen, die in einer Reihe fehlen, zählen dort mit 0. Alle Reihen
    müssen dieselben Daten haben (z. B. aus demselben Datensatz erzeugt).

    Args:
        *args: ``SimLevWeights`` (in der Regel zwei oder mehr) mit identischer Spalte ``date`` (Namen werden nicht
            verwendet).
        shares: Numerischer Vektor der Anteile je Reihe in der Reihenfolge von ``...`` (z. B. ``[0.7, 0.3]``;
            genau ein nichtnegativer Wert je Reihe); Standard ``None`` = gleiche Anteile.
        **kwargs: ``SimLevWeights`` (in der Regel zwei oder mehr) mit identischer Spalte ``date`` (Namen werden
            nicht verwendet).

    Returns:
        ``SimLevWeights`` (DataFrame mit ``date`` und Zielgewichten aller Anlagen, Anteile) für
        ``tactical_simulation()``.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 1460
        d = pd.DataFrame({"date": pd.date_range("2015-01-01", periods=n)})
        d["aktien"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        d["anleihen"] = 100 * np.cumprod(1 + rng.normal(1e-4, 0.003, n))
        d["geld"] = 100 * np.cumprod(np.full(n, 1 + 0.01 / 365))
        kern = simlev.tactical_glidepath(d, {"aktien": 0.8, "anleihen": 0.2}, {"aktien": 0.5, "anleihen": 0.5})
        satellit = simlev.tactical_rotation(d, ["aktien", "anleihen"], safe="geld")
        print(simlev.tactical_blend(kern, satellit, shares=[0.7, 0.3]))
    """
    ws = list(args) + list(kwargs.values())
    if not ws or not all(_is_weights(w) for w in ws):
        raise ValueError("tactical_blend: ... muss aus SimLevWeights bestehen.")
    if shares is None:
        shares = np.repeat(1 / len(ws), len(ws))
    sv = list(np.atleast_1d(np.asarray(shares.to_numpy() if isinstance(shares, pd.Series) else shares, dtype=object)).ravel())
    num = not chk_is_factor(shares) and all(isinstance(v, (int, float, np.integer, np.floating)) and
                                           not isinstance(v, (bool, np.bool_)) for v in sv)
    sh = np.asarray(sv, dtype=np.float64) if num else np.zeros(0)
    if not num or len(sh) != len(ws) or not np.isfinite(sh).all() or (sh < 0).any() or _ldsum(sh) <= 0:
        # seit 1.6.4 ohne Eingabewert, endlich (Entscheidung 8)
        raise ValueError("tactical_blend: shares braucht %d nichtnegative Anteile (einen je Gewichtsreihe, z. B. "
                         "c(0.7, 0.3))." % len(ws))
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
    return _as_weights_m(_dates(d), W, a, "blend")


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
    # seit 1.6.4 (B-082, Entscheidung 93) die Koordinatentexte zwischengespeichert: x einmal je Tag, y einmal je Höhe
    # (gleicher Text: dieselbe Rechnung; +0 und -0 ergeben dieselbe Höhe)
    xs = [_alloc_c(px(t[i])) for i in range(len(t))]
    yc = {}

    def ys(v):
        r = yc.get(v)
        if r is None:
            r = yc[v] = _alloc_c(py(v))
        return r
    for j in range(len(cols)):
        lo = cum.copy()
        w = W[:, j]
        cum = cum + np.where(np.isfinite(w), w, 0.0)
        up = " ".join("%s,%s" % (xs[i], ys(cum[i])) for i in range(len(t)))
        dn = " ".join("%s,%s" % (xs[i], ys(lo[i])) for i in reversed(range(len(t))))
        out.append("<polygon points=\"%s %s\" fill=\"%s\" stroke=\"none\"/>" % (up, dn, cl[j]))
    for v in (0.0, 0.25, 0.5, 0.75, 1.0):
        out.append("<text x=\"%s\" y=\"%s\" text-anchor=\"end\" font-size=\"11\">%s</text>"
                   % (_jl_str(L - 6), _alloc_c(py(v) + 4), _jl_str(v)))
    for y in dict.fromkeys((d.astype("datetime64[Y]").astype(np.int64) + 1970).tolist()):   # = _jl_unique für int
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

    Übersetzt eine Zielgewichtsreihe in Ereignis-Rebalancing von ``simulation()``: An Wechselterminen (Zielgewicht
    ändert sich) und an optionalen Pflegeterminen wird auf die Zielgewichte umgeschichtet, mit Steuern, Spreads
    und allen weiteren Einstellungen der Engine. Die Engine selbst bleibt unverändert (``event_col``, ``event_mode
    = "replace"``, ``event_weight``).

    Args:
        data: DataFrame mit Spalte ``date`` (Klasse Date) und Kursspalten (Niveaus) aller Anlagen der Gewichte (z.
            B. mit ``series_align()`` vorbereitet). Fehlende Kalendertage füllt ``simulation()`` selbst.
        weights: ``SimLevWeights`` (aus ``tactical_rules()``, ``tactical_rotation()``,
            ``tactical_target_volatility()``, ``tactical_conditional_volatility()``, ``tactical_glidepath()``,
            ``tactical_blend()`` oder ``portfolio_rolling()``). Daten von ``data``, die in ``weights`` fehlen,
            übernehmen das letzte bekannte Zielgewicht.
        rebalance: Pflegerhythmus: ``"switch"`` (Standard; nur bei Wechseln), ``"month"``, ``"quarter"`` oder
            ``"year"``.
        tolerance: Toleranzband in Prozent (5 = 5 %; Standard ``None`` = an jedem Termin handeln).
        tolerance_type: Messung der Abweichung für ``tolerance``: ``"absolute"`` (Standard; Prozentpunkte des
            Gewichts: bei 5 und Ziel 40 % wird gehandelt, wenn eine Anlage unter 35 % oder über 45 % liegt) oder
            ``"relative"`` (Prozent des Zielgewichts).
        lag: Verzögerung in Zeilen von ``data`` (ganze Zahl >= 0, Standard 1); mit Attribut ``filled`` in Zeilen
            mit echten Kursen.
            Seit 1.6.4 ohne Abschneiden (1.5 und Text sind ein Fehler).
        asset_args: Liste von Argumenten für ``asset_config()`` (über ``strategy_from_weights()``), z. B.
            ``{"spread": 0.1, "partial_exemption": {"aktien": 30, "geld": 0}}``. Ein unbenannter einzelner Wert
            gilt für alle Anlagen; benannte Vektoren werden je Anlage zugeordnet (auch mit einem Element, siehe
            ``strategy_from_weights()``).
        **kwargs: Weitere Argumente für ``simulation()`` (z. B. ``tax = tax_profile()``, ``start_value``, ``dca =
            dca_plan(...)``). Das Rebalancing (``rebalance_plan(event_col, event_mode = "replace", skip = True,
            event_weight, thresh = tolerance, thresh_type = tolerance_type)``) steuert die Funktion selbst; Pfade
            ``"rebalance.*"`` und die alten ``event_col``, ``event_mode``, ``event_weight``, ``balance_mode``,
            ``balance_thresh`` sind ein Fehler.

    Returns:
        ``SimLevResult`` wie von ``simulation()`` mit zusätzlichem Element ``tactical``, einer Liste mit
        ``weights`` (gehandelte, um ``lag`` verschobene Zielgewichte als ``SimLevWeights``), ``events`` (Daten der
        Umschichtungstermine aus Wechseln, Pflege und Sparplan, vor Anwendung von ``tolerance``), ``switches``
        (Zahl der Zielwechsel), ``lag`` und ``rebalance``. Das Ergebnis lässt sich mit ``result_analysis()`` oder
        ``result_index()`` weiterverarbeiten.

    Details:
        - ``every`` vs. ``rebalance``: Das Argument ``every`` der Gewichts-Erzeuger (``tactical_rotation()``,
          ``tactical_target_volatility()``, ``tactical_glidepath()`` usw.) bestimmt, wann sich das Zielgewicht
          ändern kann. ``rebalance`` hier bestimmt, wann zusätzlich ohne Zielwechsel auf die aktuellen
          Zielgewichte zurückgeführt wird. Gehandelt wird an jedem Wechsel (nach ``lag``) und an den
          Pflegeterminen.
        - ``lag``: Ein Zielgewicht, das nach Schluss von Tag t bekannt ist, wird nach ``lag`` Zeilen von ``data``
          gehandelt (Standard 1 = nächste Zeile, bei Kalendertagsdaten also der nächste Kalendertag; 0 = am selben
          Schlusskurs, wie bei vielen Online-Backtestern). Trägt ``data`` das Attribut ``filled`` aus
          ``series_align()``, zählen nur Zeilen, in denen alle Anlagen der Gewichte echte (nicht gefüllte) Kurse
          haben: Ein Signal vom Freitag wird mit ``lag = 1`` am Montag gehandelt, nicht am Samstag zum
          Freitagskurs. Das Attribut wird an ``simulation()`` weitergereicht.
        - ``rebalance``: ``"switch"`` (Standard; nur bei Wechseln) oder ein Rhythmus (``"month"``, ``"quarter"``,
          ``"year"``; jeweils letzte vorhandene Zeile der Periode), zu dem zusätzlich auf die aktuellen
          Zielgewichte zurückgeführt wird.
        - ``tolerance``: Toleranzband in Prozent (wird als ``rebalance_plan(thresh = tolerance)`` an
          ``simulation()`` übergeben); an Terminen, an denen keine Anlage stärker als das Band vom Ziel abweicht,
          wird nicht gehandelt. Gilt auch für Wechseltermine.
        - Umschichtungen nutzen die Rebalancing-Logik der Engine, die mit den Ist-Gewichten des letzten
          Bewertungsstands (Vortag) rechnet; nach einem Wechsel können daher Reste in der Größenordnung der
          Tagesbewegung (meist unter einem Prozent) in der verlassenen Anlage bleiben. Ein Pflegerhythmus
          (``rebalance = "month"``) gleicht sie aus.
        - Sparpläne (``dca = dca_plan(...)``) zahlen nach den Startgewichten ein; der Sparplantag wird zum
          Rebalancing-Termin, so dass die Rate sofort auf die aktuellen Zielgewichte verteilt wird.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 1460
        d = pd.DataFrame({"date": pd.date_range("2015-01-01", periods=n)})
        d["aktien"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.01, n))
        d["anleihen"] = 100 * np.cumprod(1 + rng.normal(1e-4, 0.003, n))
        d["geld"] = 100 * np.cumprod(np.full(n, 1 + 0.01 / 365))
        w = simlev.tactical_rules(d, [{"when": simlev.signal_sma(d["aktien"], n=200, band=1), "weights": {"aktien": 1}}],
                                  {"geld": 1})
        res = simlev.tactical_simulation(d, w, rebalance="switch", lag=1,
                                         asset_args={"partial_exemption": {"aktien": 30, "geld": 0}})
        print(res["tactical"]["switches"])
    """
    fn = "tactical_simulation"
    rebalance = _e5_choice(rebalance, ("switch", "month", "quarter", "year"), fn, "rebalance")
    tolerance_type = _e5_choice(tolerance_type, ("absolute", "relative"), fn, "tolerance_type")
    _e5_data_dates(data, fn, "data$date")                 # seit 1.6.4 (K42 E5)
    if not _is_weights(weights):
        raise ValueError("weights muss ein SimLevWeights sein.")
    lag = chk_int1(lag, fn, "lag", lo=0)                  # seit 1.6.4 ohne Abschneiden (Entscheidung 19)
    if asset_args is not None and not isinstance(asset_args, Mapping):
        chk_stop("liste", fn, "asset_args")
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
    lag = int(lag)
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
    tw = _as_weights_m(_dates(d), W, assets, weights.attrs.get("source"))
    res["tactical"] = {"weights": tw, "events": _dates(d[ev]), "switches": int(change.sum()), "lag": lag,
                       "rebalance": rebalance}
    return res


# plot.SimLevWeights (SVG, ``SimLevPlot``) wie Julias ``_plot_method(plot_SimLevWeights, "SimLevWeights")``
from .svg import _plot_method  # noqa: E402

SimLevWeights.plot = _plot_method(plot_SimLevWeights, "SimLevWeights")

# Rechnen mit NA (signalisierendes NaN) ohne numpy-Warnung "invalid value" wie in R (gemeinsamer Helfer)
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), list(__all__) + ["_as_weights", "_hold_rows", "_period_last", "_rowsums", "_rowmeans", "_colmeans", "_ldsum"])  # tactical_rules: env aus dem Aufrufer (env_from_caller)
