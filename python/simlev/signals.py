"""Parametrisierbare Signal-Bausteine (Port von ``r/R/signals.R``).

Jeder Baustein nimmt eine Kursreihe und liefert ``{"buy": ..., "sell": ...}``
mit logischen Vektoren gleicher Länge (NA -> False). Das ist das Format, das
``bootstrap_study()`` und ``param_search()`` über ``signal = function(df)``
erwarten. Fenster zählen in Zeilen.

Semantik in :func:`simulation`: Kauf nur, wenn das Asset nicht gehalten wird
und ``buy`` wahr ist; Verkauf, wenn es gehalten wird und ``sell`` wahr ist.
Sind beide falsch (Band/Hysterese), bleibt der Zustand unverändert.
"""
from __future__ import annotations

import math
from collections.abc import Mapping

import numpy as np

from ._r import libm as _libm
from ._r.fmt import NA_REAL
from ._r.rnum import r_mean
from ._signals_core import roll_cov_core, roll_mean_core
from ._r.base import quiet_fp
from .data_prep import _as_numeric, _match_arg

__all__ = ["signal_sma", "signal_ema", "signal_crossover", "signal_momentum", "signal_drawdown",
           "signal_volatility", "signal_combine"]

_NAN = NA_REAL   # R-NA_real_


def _roll_mean(x, n):
    """Rollierender Mittelwert (Fenster ``n`` inkl. aktueller Zeile; NA für Fenster mit fehlendem Wert)."""
    return roll_mean_core(_as_numeric(x), int(n))


def _roll_var(x, n):
    """Rollierende Varianz (Populationsform, Zwei-Pass)."""
    x = _as_numeric(x)
    with np.errstate(invalid="ignore", over="ignore"):
        return roll_cov_core(x, x, int(n))


def _roll_cov(x, y, n):
    """Rollierende Kovarianz (Populationsform, Zwei-Pass)."""
    with np.errstate(invalid="ignore", over="ignore"):
        return roll_cov_core(_as_numeric(x), _as_numeric(y), int(n))


def _rfilter_recursive1(x, f, init):
    """``stats::filter(x, f, method = "recursive", init = init)`` mit einem Koeffizienten."""
    from ._r import stats as _st
    return np.asarray(_st.filter(x, f, method="recursive", init=init), dtype=np.float64).ravel()


def _ema(x, n):
    """Exponentieller gleitender Durchschnitt (Start mit dem einfachen Mittel der ersten ``n`` Werte)."""
    n = int(n)
    x = np.asarray(x, dtype=np.float64)
    m = len(x)
    out = np.full(m, _NAN)
    if n < 1 or n > m:
        return out
    a = 2 / (n + 1)
    out[n - 1] = r_mean(x[:n])
    if n < m:
        out[n:] = _rfilter_recursive1(a * x[n:], 1 - a, out[n - 1])
    return out


def _lgl(v):
    """Vergleichsergebnis -> (Werte, NA-Maske)."""
    return np.asarray(v, dtype=bool)


def _cmp(op, a, b):
    a = np.asarray(a, dtype=np.float64)
    b = np.asarray(b, dtype=np.float64)
    with np.errstate(invalid="ignore"):
        res = op(a, b)
    na = np.isnan(a) | np.isnan(b)
    return res & ~na


def _sig_out(buy, sell, lag=0):
    """Signale um ``lag`` Zeilen verzögern und NA bereinigen."""
    lag = int(lag)
    buy = np.array([bool(v) if v is not None and not (isinstance(v, float) and math.isnan(v)) else False
                    for v in np.asarray(buy, dtype=object).ravel()], dtype=bool)
    sell = np.array([bool(v) if v is not None and not (isinstance(v, float) and math.isnan(v)) else False
                     for v in np.asarray(sell, dtype=object).ravel()], dtype=bool)
    if lag > 0:
        m = len(buy)
        buy = np.concatenate([np.zeros(lag, dtype=bool), buy[: m - lag]])
        sell = np.concatenate([np.zeros(lag, dtype=bool), sell[: m - lag]])
    return {"buy": buy, "sell": sell}


def signal_sma(x, *, n=200, band=0, lag=0):
    """Kurs über/unter dem einfachen gleitenden Durchschnitt der letzten ``n`` Zeilen.

    Kauf ab ``SMA * (1 + band/100)``, Verkauf unter ``SMA * (1 - band/100)``.

    Args:
        x: Kursniveaus.
        n: Fensterlänge in Zeilen.
        band: Hysterese-Band in Prozent des Durchschnitts.
        lag: Verzögerung der Signale in Zeilen.

    Returns:
        ``dict`` mit ``buy`` und ``sell`` (bool-Arrays).
    """
    xv = _as_numeric(x)
    s = _roll_mean(xv, n)
    return _sig_out(_cmp(np.greater_equal, xv, s * (1 + band / 100)), _cmp(np.less, xv, s * (1 - band / 100)), lag)


def signal_ema(x, *, n=200, band=0, lag=0):
    """Wie :func:`signal_sma` mit exponentiellem Durchschnitt (Glättung 2/(n+1))."""
    xv = _as_numeric(x)
    s = _ema(xv, n)
    return _sig_out(_cmp(np.greater_equal, xv, s * (1 + band / 100)), _cmp(np.less, xv, s * (1 - band / 100)), lag)


def signal_crossover(x, *, fast=50, slow=200, type=("sma", "ema"), band=0, lag=0):  # noqa: A002
    """Schneller über langsamem Durchschnitt.

    Args:
        x: Kursniveaus.
        fast, slow: Fensterlängen (``fast < slow``).
        type: ``"sma"`` oder ``"ema"``.
        band: Hysterese-Band in Prozent.
        lag: Verzögerung in Zeilen.
    """
    type_ = _match_arg(type, ("sma", "ema"))
    if fast >= slow:
        raise ValueError("fast muss kleiner als slow sein.")
    xv = _as_numeric(x)
    f = _roll_mean(xv, fast) if type_ == "sma" else _ema(xv, fast)
    s = _roll_mean(xv, slow) if type_ == "sma" else _ema(xv, slow)
    return _sig_out(_cmp(np.greater_equal, f, s * (1 + band / 100)), _cmp(np.less, f, s * (1 - band / 100)), lag)


def signal_momentum(x, *, n=250, threshold=0, band=0, lag=0):
    """Rendite über ``n`` Zeilen in Prozent: Kauf ab ``threshold + band``, Verkauf unter ``threshold - band``."""
    x = _as_numeric(x)
    m = len(x)
    n = int(n)
    r = np.full(m, _NAN)
    if n < m:
        with np.errstate(invalid="ignore", divide="ignore"):
            r[n:] = 100 * (x[n:] / x[: m - n] - 1)
    return _sig_out(_cmp(np.greater_equal, r, threshold + band), _cmp(np.less, r, threshold - band), lag)


def signal_drawdown(x, *, sell_dd=20, buy_dd=10, window=None, lag=0):
    """Verkauf ab ``sell_dd`` Prozent unter dem (rollierenden) Hoch, Kauf unter ``buy_dd`` Prozent.

    Args:
        x: Kursniveaus.
        sell_dd, buy_dd: Abstand zum Hoch in Prozent (``buy_dd <= sell_dd``).
        window: Fenster für das rollierende Hoch (``None`` = laufendes Hoch).
        lag: Verzögerung in Zeilen.
    """
    x = _as_numeric(x)
    if buy_dd > sell_dd:
        raise ValueError("buy_dd darf nicht größer als sell_dd sein.")
    xp = np.where(np.isnan(x), -math.inf, x)
    if window is None:
        peak = np.maximum.accumulate(xp) if len(xp) else xp
    else:
        w = int(window)
        m = len(x)
        peak = np.array([np.max(xp[max(0, i - w + 1): i + 1]) for i in range(m)], dtype=np.float64)
    with np.errstate(invalid="ignore", divide="ignore"):
        dd = 100 * (1 - x / peak)
    return _sig_out(_cmp(np.less, dd, buy_dd), _cmp(np.greater_equal, dd, sell_dd), lag)


def signal_volatility(x, *, n=20, threshold=25, band=0, ppy=365.25, lag=0):
    """Realisierte Volatilität der Log-Renditen über ``n`` Zeilen in Prozent p. a.

    Kauf bis ``threshold - band``, Verkauf über ``threshold + band``.
    """
    x = _as_numeric(x)
    r = np.concatenate([[_NAN], np.diff(_libm.log(x))]) if len(x) else np.empty(0)
    r0 = r.copy()
    r0[np.isnan(r0)] = 0
    rv = _roll_var(r0, n)
    with np.errstate(invalid="ignore"):
        pm = np.where(np.isnan(rv), _NAN, np.maximum(rv, 0))
        v = 100 * np.sqrt(pm * n / max(n - 1, 1) * ppy)
    v[: min(int(n), len(v))] = _NAN
    return _sig_out(_cmp(np.less_equal, v, threshold - band), _cmp(np.greater, v, threshold + band), lag)


def _get(z, k):
    if isinstance(z, Mapping):
        return z.get(k)
    return getattr(z, k, None)


def signal_combine(*signals, op=("and", "or")):
    """Verknüpft Signale: ``"and"`` kauft nur, wenn alle kaufen, und verkauft, sobald eines verkauft;
    ``"or"`` kauft, sobald eines kauft, und verkauft nur, wenn alle verkaufen.

    Args:
        *signals: Signal-Listen ``{"buy", "sell"}`` gleicher Länge.
        op: ``"and"`` oder ``"or"``.
    """
    op = _match_arg(op, ("and", "or"))
    s = list(signals)
    if not s:
        raise ValueError("Keine Signale übergeben.")
    lens = [len(np.atleast_1d(_get(z, "buy"))) if _get(z, "buy") is not None else 0 for z in s]
    slen = [len(np.atleast_1d(_get(z, "sell"))) if _get(z, "sell") is not None else 0 for z in s]
    if any(L != lens[0] for L in lens) or any(a != b for a, b in zip(slen, lens)):
        raise ValueError("signal_combine: Signale haben unterschiedliche Längen (%s); alle aus derselben "
                         "Kursreihe erzeugen." % ", ".join(str(L) for L in lens))
    B = np.column_stack([np.asarray(_get(z, "buy"), dtype=bool) for z in s])
    S = np.column_stack([np.asarray(_get(z, "sell"), dtype=bool) for z in s])
    if op == "and":
        return {"buy": B.all(axis=1), "sell": S.any(axis=1)}
    return {"buy": B.any(axis=1), "sell": S.all(axis=1)}


quiet_fp(globals(), __all__ + ["_roll_mean", "_roll_var", "_roll_cov", "_ema", "_sig_out"])
