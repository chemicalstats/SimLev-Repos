"""Parametrisierbare Signal-Bausteine (Gegenstück zu ``r/R/signals.R``).

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

from . import _ext
from ._r import libm as _libm
from ._r.fmt import NA_REAL
from ._r import stats as _st
from ._r.rnum import r_mean
from ._signals_core import roll_cov_core, roll_mean_core
from ._r.base import quiet_fp
from .data_prep import _as_numeric, _match_arg
from ._pruefen import chk_int1, chk_num1, chk_scalar, chk_stop

_IMAX = 2147483647


def _isna1(v) -> bool:
    import pandas as pd
    return v is None or v is pd.NA or (isinstance(v, (float, np.floating)) and math.isnan(v))


def _sig_x(x, fn):
    """Kursreihe prüfen (seit 1.6.4, B-009 bis B-012, B-016; R: .sig_x): numerischer Vektor (keine Matrix, keine
    Tabelle, kein Text, keine Kategorie, keine Wahrheitswerte; leer erlaubt; nur NA zählt als Zahlenvektor)."""
    import pandas as pd
    bad = isinstance(x, (pd.DataFrame, Mapping, str, bytes)) or (isinstance(x, np.ndarray) and x.ndim > 1)
    if not bad:
        if isinstance(x, pd.Series):
            if isinstance(x.dtype, pd.CategoricalDtype):   # Entscheidung 15
                chk_stop("faktor", fn, "x")
            elif x.dtype.kind in "fiu":
                return
            vals = [] if bad else list(x.to_numpy(dtype=object))
        elif isinstance(x, np.ndarray):
            if x.dtype.kind in "fiu":
                return
            vals = list(x.ravel())
        elif isinstance(x, (list, tuple)):
            vals = list(x)
        else:
            vals = [x]
        bad = bad or not all(_isna1(v) or (isinstance(v, (int, float, np.integer, np.floating))
                                           and not isinstance(v, (bool, np.bool_))) for v in vals)
    if bad:
        chk_stop("zahlen", fn, "x")


def _sig_win(x, fn, arg, lo=1, null_ok=False):
    """Fenster bzw. Verzögerung: einzelne endliche Zahl >= lo bis zur R-Ganzzahlgrenze; seit 1.6.4 ganze Zahl
    (Entscheidungen 19, 32; bis dahin abgeschnitten)."""
    x = chk_num1(x, fn, arg, lo=lo, hi=_IMAX, null_ok=null_ok)
    return chk_int1(x, fn, arg, lo=lo, null_ok=null_ok)

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


def _cmp(op, a, b):
    a = np.asarray(a, dtype=np.float64)
    b = np.asarray(b, dtype=np.float64)
    with np.errstate(invalid="ignore"):
        res = op(a, b)
    na = np.isnan(a) | np.isnan(b)
    return res & ~na


def _sig_clean(v):
    """Logischer Vektor ohne NA (NA, NaN und ``None`` → ``False``); Schnellweg für bool- und float64-Felder (seit
    1.6.1, gleiche Werte wie die Schleife: ``bool(x)`` ist dort ``x != 0``)."""
    a = np.asarray(v)
    if a.dtype == np.bool_:
        return a.ravel().astype(bool)
    if a.dtype == np.float64:
        a = a.ravel()
        return ~np.isnan(a) & (a != 0)
    return np.array([bool(x) if x is not None and not (isinstance(x, float) and math.isnan(x)) else False
                     for x in np.asarray(v, dtype=object).ravel()], dtype=bool)


def _sig_out(buy, sell, lag=0):
    """Signale um ``lag`` Zeilen verzögern und NA bereinigen."""
    lag = int(lag)
    buy = _sig_clean(buy)
    sell = _sig_clean(sell)
    if lag > 0:
        m = len(buy)
        lag = min(lag, m)   # seit 1.6.4 (B-024): lag >= Länge ergibt nur False (bis 1.6.3 falsche Länge)
        buy = np.concatenate([np.zeros(lag, dtype=bool), buy[: m - lag]])
        sell = np.concatenate([np.zeros(lag, dtype=bool), sell[: m - lag]])
    return {"buy": buy, "sell": sell}


def signal_sma(x, *, n=200, band=0, lag=0):
    """Kurs über/unter dem einfachen gleitenden Durchschnitt der letzten ``n`` Zeilen.

    Erzeugen Kauf- und Verkaufssignale aus einer Kursreihe, im Format, das ``bootstrap_study()`` und
    ``param_search()`` für ``signal = function(df) ...`` erwarten: Die Elemente ``buy`` und ``sell`` werden dort
    als gleichnamige Spalten an den Datensatz angehängt. Für ``simulation()`` hängt man sie selbst an und nennt
    sie in ``asset_config()`` (``trading = "signal"``, ``signal_buy``, ``signal_sell``); für ``tactical_rules()``
    lassen sie sich direkt als Bedingung verwenden.

    Args:
        x: Numerischer Vektor mit Kursniveaus (z. B. ``df["eu"]``).
        n: Fensterlänge in Zeilen (Standard: 200 bei ``signal_sma`` und ``signal_ema``, 250 bei
            ``signal_momentum``, 20 bei ``signal_volatility``).
        band: Hysterese-Band (Standard 0 = keins): bei Durchschnitten in Prozent des Durchschnitts (1 = 1 %), bei
            ``signal_momentum`` und ``signal_volatility`` in Prozentpunkten um ``threshold``.
        lag: Verzögerung der Signale in Zeilen (Standard 0; z. B. 1, um erst in der Folgezeile zu handeln). Die
            ersten ``lag`` Zeilen sind ``False``.

    Returns:
        ``{"buy": ..., "sell": ...}`` mit logischen Vektoren der Länge von ``x`` (NA als ``False``).

    Details:
        Eingabe ist ein numerischer Vektor mit Kursniveaus (keine Renditen), z. B. eine Spalte aus
        ``series_align()``. Alle Fenster (``n``, ``fast``, ``slow``, ``window``, ``lag``) zählen in Zeilen der
        Daten, bei Kalendertagsdaten (Wochenenden per LOCF) also in Kalendertagen, bei Handelstagsdaten in
        Handelstagen. Solange ein Fenster noch nicht gefüllt ist, sind beide Signale ``False`` (außer bei
        ``signal_drawdown``, das anfangs das Hoch der bisherigen Zeilen verwendet). ``x`` sollte keine NA
        enthalten: Bei Durchschnitten liefern Fenster mit NA kein Signal, beim exponentiellen Durchschnitt auch
        alle folgenden Zeilen; bei ``signal_drawdown`` nur die Zeile mit NA (das Hoch wird ohne sie fortgeführt).

        Eingaben (seit 1.6.4 geprüft): ``x`` ein numerischer Vektor (keine Matrix, Tabelle, kein Text, keine
        Kategorie, keine Wahrheitswerte; leer erlaubt); ``n``, ``fast``, ``slow``, ``window`` je eine endliche Zahl
        ``>= 1``, ``lag >= 0`` (seit 1.6.4 ganze Zahlen, gebrochene Werte sind ein Fehler; ``lag`` ab der Länge von ``x`` ergibt nur
        ``False``); ``band >= 0``; ``sell_dd``, ``buy_dd`` größer 0 und höchstens 100; bei ``signal_volatility``
        ``threshold >= 0`` und ``ppy > 0``; bei ``signal_combine`` ``buy`` und ``sell`` je True/False oder 0/1
        (NA bleibt NA: Ergebnis dann als object-Feld mit ``None``).

        ``band`` wirkt als Hysterese: Zwischen Kauf- und Verkaufsschwelle sind beide Signale ``False``, der
        Zustand in ``simulation()`` bzw. ``signal_state()`` bleibt dann unverändert. Bei Durchschnitten
        (``signal_sma``, ``signal_ema``, ``signal_crossover``) ist ``band`` relativ zum Durchschnitt in Prozent,
        bei ``signal_momentum`` und ``signal_volatility`` ein Abstand in Prozentpunkten zu ``threshold``.

        - signal_sma: Kurs über/unter dem einfachen gleitenden Durchschnitt der letzten ``n`` Zeilen
          (einschließlich der aktuellen): Kauf ab ``SMA * (1 + band/100)``, Verkauf unter ``SMA * (1 -
          band/100)``, dazwischen bleibt der Zustand.
        - signal_ema: Wie ``signal_sma`` mit exponentiellem Durchschnitt (Glättung 2 / (n + 1), Start mit dem
          einfachen Mittel der ersten ``n`` Werte).
        - signal_crossover: Schneller über langsamem Durchschnitt: Kauf, wenn der schnelle mindestens das ``(1 +
          band/100)``-fache des langsamen erreicht, Verkauf unter dem ``(1 - band/100)``-fachen.
        - signal_momentum: Rendite über ``n`` Zeilen in Prozent: Kauf ab ``threshold + band``, Verkauf unter
          ``threshold - band``.
        - signal_drawdown: Verkauf ab ``sell_dd`` Prozent unter dem (rollierenden) Hoch, Kauf (Wiedereinstieg),
          solange der Abstand unter ``buy_dd`` Prozent liegt; dazwischen bleibt der Zustand.
        - signal_volatility: Realisierte Volatilität der Log-Renditen über ``n`` Zeilen, annualisiert mit ``ppy``,
          in Prozent p. a.: Kauf bis ``threshold - band``, Verkauf über ``threshold + band``.
        - signal_combine: Verknüpft Signale: ``"and"`` kauft nur, wenn alle kaufen, und verkauft, sobald eines
          verkauft; ``"or"`` kauft, sobald eines kauft, und verkauft nur, wenn alle verkaufen.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 1000
        d = pd.DataFrame({"date": pd.date_range("2018-01-01", periods=n)})
        d["A"] = 100 * np.cumprod(1 + rng.normal(2e-4, 0.01, n))
        s = simlev.signal_sma(d["A"], n=200, band=1, lag=1)
        d["buy"], d["sell"] = s["buy"], s["sell"]
        res = simlev.simulation(d, simlev.create_strategy(A=simlev.asset_config(asset_class="etf", trading="signal",
                                                                                 signal_buy="buy", signal_sell="sell")))
        print(res["buys"], res["sells"])
    """
    fn = "signal_sma"
    _sig_x(x, fn)
    n = _sig_win(n, fn, "n")
    band = chk_num1(band, fn, "band", lo=0)
    lag = _sig_win(lag, fn, "lag", lo=0)
    xv = _as_numeric(x)
    s = _roll_mean(xv, n)
    return _sig_out(_cmp(np.greater_equal, xv, s * (1 + band / 100)), _cmp(np.less, xv, s * (1 - band / 100)), lag)


def signal_ema(x, *, n=200, band=0, lag=0):
    """Wie :func:`signal_sma` mit exponentiellem Durchschnitt (Glättung 2/(n+1)).

    Erzeugen Kauf- und Verkaufssignale aus einer Kursreihe, im Format, das ``bootstrap_study()`` und
    ``param_search()`` für ``signal = function(df) ...`` erwarten: Die Elemente ``buy`` und ``sell`` werden dort
    als gleichnamige Spalten an den Datensatz angehängt. Für ``simulation()`` hängt man sie selbst an und nennt
    sie in ``asset_config()`` (``trading = "signal"``, ``signal_buy``, ``signal_sell``); für ``tactical_rules()``
    lassen sie sich direkt als Bedingung verwenden.

    Args:
        x: Numerischer Vektor mit Kursniveaus (z. B. ``df["eu"]``).
        n: Fensterlänge in Zeilen (Standard: 200 bei ``signal_sma`` und ``signal_ema``, 250 bei
            ``signal_momentum``, 20 bei ``signal_volatility``).
        band: Hysterese-Band (Standard 0 = keins): bei Durchschnitten in Prozent des Durchschnitts (1 = 1 %), bei
            ``signal_momentum`` und ``signal_volatility`` in Prozentpunkten um ``threshold``.
        lag: Verzögerung der Signale in Zeilen (Standard 0; z. B. 1, um erst in der Folgezeile zu handeln). Die
            ersten ``lag`` Zeilen sind ``False``.

    Returns:
        ``{"buy": ..., "sell": ...}`` mit logischen Vektoren der Länge von ``x`` (NA als ``False``).

    Details:
        Eingabe ist ein numerischer Vektor mit Kursniveaus (keine Renditen), z. B. eine Spalte aus
        ``series_align()``. Alle Fenster (``n``, ``fast``, ``slow``, ``window``, ``lag``) zählen in Zeilen der
        Daten, bei Kalendertagsdaten (Wochenenden per LOCF) also in Kalendertagen, bei Handelstagsdaten in
        Handelstagen. Solange ein Fenster noch nicht gefüllt ist, sind beide Signale ``False`` (außer bei
        ``signal_drawdown``, das anfangs das Hoch der bisherigen Zeilen verwendet). ``x`` sollte keine NA
        enthalten: Bei Durchschnitten liefern Fenster mit NA kein Signal, beim exponentiellen Durchschnitt auch
        alle folgenden Zeilen; bei ``signal_drawdown`` nur die Zeile mit NA (das Hoch wird ohne sie fortgeführt).

        Eingaben (seit 1.6.4 geprüft): ``x`` ein numerischer Vektor (keine Matrix, Tabelle, kein Text, keine
        Kategorie, keine Wahrheitswerte; leer erlaubt); ``n``, ``fast``, ``slow``, ``window`` je eine endliche Zahl
        ``>= 1``, ``lag >= 0`` (seit 1.6.4 ganze Zahlen, gebrochene Werte sind ein Fehler; ``lag`` ab der Länge von ``x`` ergibt nur
        ``False``); ``band >= 0``; ``sell_dd``, ``buy_dd`` größer 0 und höchstens 100; bei ``signal_volatility``
        ``threshold >= 0`` und ``ppy > 0``; bei ``signal_combine`` ``buy`` und ``sell`` je True/False oder 0/1
        (NA bleibt NA: Ergebnis dann als object-Feld mit ``None``).

        ``band`` wirkt als Hysterese: Zwischen Kauf- und Verkaufsschwelle sind beide Signale ``False``, der
        Zustand in ``simulation()`` bzw. ``signal_state()`` bleibt dann unverändert. Bei Durchschnitten
        (``signal_sma``, ``signal_ema``, ``signal_crossover``) ist ``band`` relativ zum Durchschnitt in Prozent,
        bei ``signal_momentum`` und ``signal_volatility`` ein Abstand in Prozentpunkten zu ``threshold``.

        - signal_sma: Kurs über/unter dem einfachen gleitenden Durchschnitt der letzten ``n`` Zeilen
          (einschließlich der aktuellen): Kauf ab ``SMA * (1 + band/100)``, Verkauf unter ``SMA * (1 -
          band/100)``, dazwischen bleibt der Zustand.
        - signal_ema: Wie ``signal_sma`` mit exponentiellem Durchschnitt (Glättung 2 / (n + 1), Start mit dem
          einfachen Mittel der ersten ``n`` Werte).
        - signal_crossover: Schneller über langsamem Durchschnitt: Kauf, wenn der schnelle mindestens das ``(1 +
          band/100)``-fache des langsamen erreicht, Verkauf unter dem ``(1 - band/100)``-fachen.
        - signal_momentum: Rendite über ``n`` Zeilen in Prozent: Kauf ab ``threshold + band``, Verkauf unter
          ``threshold - band``.
        - signal_drawdown: Verkauf ab ``sell_dd`` Prozent unter dem (rollierenden) Hoch, Kauf (Wiedereinstieg),
          solange der Abstand unter ``buy_dd`` Prozent liegt; dazwischen bleibt der Zustand.
        - signal_volatility: Realisierte Volatilität der Log-Renditen über ``n`` Zeilen, annualisiert mit ``ppy``,
          in Prozent p. a.: Kauf bis ``threshold - band``, Verkauf über ``threshold + band``.
        - signal_combine: Verknüpft Signale: ``"and"`` kauft nur, wenn alle kaufen, und verkauft, sobald eines
          verkauft; ``"or"`` kauft, sobald eines kauft, und verkauft nur, wenn alle verkaufen.

    Beispiel::

        import numpy as np, simlev
        x = 100 * np.cumprod(1 + np.random.default_rng(1).normal(2e-4, 0.01, 1000))
        print(simlev.signal_ema(x, n=200, band=1)["buy"].sum())
    """
    fn = "signal_ema"
    _sig_x(x, fn)
    n = _sig_win(n, fn, "n")
    band = chk_num1(band, fn, "band", lo=0)
    lag = _sig_win(lag, fn, "lag", lo=0)
    xv = _as_numeric(x)
    s = _ema(xv, n)
    return _sig_out(_cmp(np.greater_equal, xv, s * (1 + band / 100)), _cmp(np.less, xv, s * (1 - band / 100)), lag)


def signal_crossover(x, *, fast=50, slow=200, type=("sma", "ema"), band=0, lag=0):  # noqa: A002
    """Schneller über langsamem Durchschnitt.

    Erzeugen Kauf- und Verkaufssignale aus einer Kursreihe, im Format, das ``bootstrap_study()`` und
    ``param_search()`` für ``signal = function(df) ...`` erwarten: Die Elemente ``buy`` und ``sell`` werden dort
    als gleichnamige Spalten an den Datensatz angehängt. Für ``simulation()`` hängt man sie selbst an und nennt
    sie in ``asset_config()`` (``trading = "signal"``, ``signal_buy``, ``signal_sell``); für ``tactical_rules()``
    lassen sie sich direkt als Bedingung verwenden.

    Args:
        x: Numerischer Vektor mit Kursniveaus (z. B. ``df["eu"]``).
        fast, slow: Fensterlängen in Zeilen für den schnellen und den langsamen Durchschnitt (Standard 50 und 200;
            ``fast < slow``).
        type: Art der Durchschnitte bei ``signal_crossover``: ``"sma"`` (Standard) oder ``"ema"``.
        band: Hysterese-Band (Standard 0 = keins): bei Durchschnitten in Prozent des Durchschnitts (1 = 1 %), bei
            ``signal_momentum`` und ``signal_volatility`` in Prozentpunkten um ``threshold``.
        lag: Verzögerung der Signale in Zeilen (Standard 0; z. B. 1, um erst in der Folgezeile zu handeln). Die
            ersten ``lag`` Zeilen sind ``False``.

    Returns:
        ``{"buy": ..., "sell": ...}`` mit logischen Vektoren der Länge von ``x`` (NA als ``False``).

    Details:
        Eingabe ist ein numerischer Vektor mit Kursniveaus (keine Renditen), z. B. eine Spalte aus
        ``series_align()``. Alle Fenster (``n``, ``fast``, ``slow``, ``window``, ``lag``) zählen in Zeilen der
        Daten, bei Kalendertagsdaten (Wochenenden per LOCF) also in Kalendertagen, bei Handelstagsdaten in
        Handelstagen. Solange ein Fenster noch nicht gefüllt ist, sind beide Signale ``False`` (außer bei
        ``signal_drawdown``, das anfangs das Hoch der bisherigen Zeilen verwendet). ``x`` sollte keine NA
        enthalten: Bei Durchschnitten liefern Fenster mit NA kein Signal, beim exponentiellen Durchschnitt auch
        alle folgenden Zeilen; bei ``signal_drawdown`` nur die Zeile mit NA (das Hoch wird ohne sie fortgeführt).

        Eingaben (seit 1.6.4 geprüft): ``x`` ein numerischer Vektor (keine Matrix, Tabelle, kein Text, keine
        Kategorie, keine Wahrheitswerte; leer erlaubt); ``n``, ``fast``, ``slow``, ``window`` je eine endliche Zahl
        ``>= 1``, ``lag >= 0`` (seit 1.6.4 ganze Zahlen, gebrochene Werte sind ein Fehler; ``lag`` ab der Länge von ``x`` ergibt nur
        ``False``); ``band >= 0``; ``sell_dd``, ``buy_dd`` größer 0 und höchstens 100; bei ``signal_volatility``
        ``threshold >= 0`` und ``ppy > 0``; bei ``signal_combine`` ``buy`` und ``sell`` je True/False oder 0/1
        (NA bleibt NA: Ergebnis dann als object-Feld mit ``None``).

        ``band`` wirkt als Hysterese: Zwischen Kauf- und Verkaufsschwelle sind beide Signale ``False``, der
        Zustand in ``simulation()`` bzw. ``signal_state()`` bleibt dann unverändert. Bei Durchschnitten
        (``signal_sma``, ``signal_ema``, ``signal_crossover``) ist ``band`` relativ zum Durchschnitt in Prozent,
        bei ``signal_momentum`` und ``signal_volatility`` ein Abstand in Prozentpunkten zu ``threshold``.

        - signal_sma: Kurs über/unter dem einfachen gleitenden Durchschnitt der letzten ``n`` Zeilen
          (einschließlich der aktuellen): Kauf ab ``SMA * (1 + band/100)``, Verkauf unter ``SMA * (1 -
          band/100)``, dazwischen bleibt der Zustand.
        - signal_ema: Wie ``signal_sma`` mit exponentiellem Durchschnitt (Glättung 2 / (n + 1), Start mit dem
          einfachen Mittel der ersten ``n`` Werte).
        - signal_crossover: Schneller über langsamem Durchschnitt: Kauf, wenn der schnelle mindestens das ``(1 +
          band/100)``-fache des langsamen erreicht, Verkauf unter dem ``(1 - band/100)``-fachen.
        - signal_momentum: Rendite über ``n`` Zeilen in Prozent: Kauf ab ``threshold + band``, Verkauf unter
          ``threshold - band``.
        - signal_drawdown: Verkauf ab ``sell_dd`` Prozent unter dem (rollierenden) Hoch, Kauf (Wiedereinstieg),
          solange der Abstand unter ``buy_dd`` Prozent liegt; dazwischen bleibt der Zustand.
        - signal_volatility: Realisierte Volatilität der Log-Renditen über ``n`` Zeilen, annualisiert mit ``ppy``,
          in Prozent p. a.: Kauf bis ``threshold - band``, Verkauf über ``threshold + band``.
        - signal_combine: Verknüpft Signale: ``"and"`` kauft nur, wenn alle kaufen, und verkauft, sobald eines
          verkauft; ``"or"`` kauft, sobald eines kauft, und verkauft nur, wenn alle verkaufen.

    Beispiel::

        import numpy as np, simlev
        x = 100 * np.cumprod(1 + np.random.default_rng(1).normal(2e-4, 0.01, 1000))
        print(simlev.signal_crossover(x, fast=50, slow=200)["buy"].sum())
    """
    fn = "signal_crossover"
    _sig_x(x, fn)
    fast = _sig_win(fast, fn, "fast")
    slow = _sig_win(slow, fn, "slow")
    type_ = _match_arg(chk_scalar(type), ("sma", "ema"))
    if fast >= slow:
        raise ValueError("fast muss kleiner als slow sein.")
    band = chk_num1(band, fn, "band", lo=0)
    lag = _sig_win(lag, fn, "lag", lo=0)
    xv = _as_numeric(x)
    f = _roll_mean(xv, fast) if type_ == "sma" else _ema(xv, fast)
    s = _roll_mean(xv, slow) if type_ == "sma" else _ema(xv, slow)
    return _sig_out(_cmp(np.greater_equal, f, s * (1 + band / 100)), _cmp(np.less, f, s * (1 - band / 100)), lag)


def signal_momentum(x, *, n=250, threshold=0, band=0, lag=0):
    """Rendite über ``n`` Zeilen in Prozent: Kauf ab ``threshold + band``, Verkauf unter ``threshold - band``.

    Erzeugen Kauf- und Verkaufssignale aus einer Kursreihe, im Format, das ``bootstrap_study()`` und
    ``param_search()`` für ``signal = function(df) ...`` erwarten: Die Elemente ``buy`` und ``sell`` werden dort
    als gleichnamige Spalten an den Datensatz angehängt. Für ``simulation()`` hängt man sie selbst an und nennt
    sie in ``asset_config()`` (``trading = "signal"``, ``signal_buy``, ``signal_sell``); für ``tactical_rules()``
    lassen sie sich direkt als Bedingung verwenden.

    Args:
        x: Numerischer Vektor mit Kursniveaus (z. B. ``df["eu"]``).
        n: Fensterlänge in Zeilen (Standard: 200 bei ``signal_sma`` und ``signal_ema``, 250 bei
            ``signal_momentum``, 20 bei ``signal_volatility``).
        threshold: Schwelle in Prozent: bei ``signal_momentum`` für die Rendite über ``n`` Zeilen (Standard 0),
            bei ``signal_volatility`` für die Volatilität in Prozent p. a. (Standard 25).
        band: Hysterese-Band (Standard 0 = keins): bei Durchschnitten in Prozent des Durchschnitts (1 = 1 %), bei
            ``signal_momentum`` und ``signal_volatility`` in Prozentpunkten um ``threshold``.
        lag: Verzögerung der Signale in Zeilen (Standard 0; z. B. 1, um erst in der Folgezeile zu handeln). Die
            ersten ``lag`` Zeilen sind ``False``.

    Returns:
        ``{"buy": ..., "sell": ...}`` mit logischen Vektoren der Länge von ``x`` (NA als ``False``).

    Details:
        Eingabe ist ein numerischer Vektor mit Kursniveaus (keine Renditen), z. B. eine Spalte aus
        ``series_align()``. Alle Fenster (``n``, ``fast``, ``slow``, ``window``, ``lag``) zählen in Zeilen der
        Daten, bei Kalendertagsdaten (Wochenenden per LOCF) also in Kalendertagen, bei Handelstagsdaten in
        Handelstagen. Solange ein Fenster noch nicht gefüllt ist, sind beide Signale ``False`` (außer bei
        ``signal_drawdown``, das anfangs das Hoch der bisherigen Zeilen verwendet). ``x`` sollte keine NA
        enthalten: Bei Durchschnitten liefern Fenster mit NA kein Signal, beim exponentiellen Durchschnitt auch
        alle folgenden Zeilen; bei ``signal_drawdown`` nur die Zeile mit NA (das Hoch wird ohne sie fortgeführt).

        Eingaben (seit 1.6.4 geprüft): ``x`` ein numerischer Vektor (keine Matrix, Tabelle, kein Text, keine
        Kategorie, keine Wahrheitswerte; leer erlaubt); ``n``, ``fast``, ``slow``, ``window`` je eine endliche Zahl
        ``>= 1``, ``lag >= 0`` (seit 1.6.4 ganze Zahlen, gebrochene Werte sind ein Fehler; ``lag`` ab der Länge von ``x`` ergibt nur
        ``False``); ``band >= 0``; ``sell_dd``, ``buy_dd`` größer 0 und höchstens 100; bei ``signal_volatility``
        ``threshold >= 0`` und ``ppy > 0``; bei ``signal_combine`` ``buy`` und ``sell`` je True/False oder 0/1
        (NA bleibt NA: Ergebnis dann als object-Feld mit ``None``).

        ``band`` wirkt als Hysterese: Zwischen Kauf- und Verkaufsschwelle sind beide Signale ``False``, der
        Zustand in ``simulation()`` bzw. ``signal_state()`` bleibt dann unverändert. Bei Durchschnitten
        (``signal_sma``, ``signal_ema``, ``signal_crossover``) ist ``band`` relativ zum Durchschnitt in Prozent,
        bei ``signal_momentum`` und ``signal_volatility`` ein Abstand in Prozentpunkten zu ``threshold``.

        - signal_sma: Kurs über/unter dem einfachen gleitenden Durchschnitt der letzten ``n`` Zeilen
          (einschließlich der aktuellen): Kauf ab ``SMA * (1 + band/100)``, Verkauf unter ``SMA * (1 -
          band/100)``, dazwischen bleibt der Zustand.
        - signal_ema: Wie ``signal_sma`` mit exponentiellem Durchschnitt (Glättung 2 / (n + 1), Start mit dem
          einfachen Mittel der ersten ``n`` Werte).
        - signal_crossover: Schneller über langsamem Durchschnitt: Kauf, wenn der schnelle mindestens das ``(1 +
          band/100)``-fache des langsamen erreicht, Verkauf unter dem ``(1 - band/100)``-fachen.
        - signal_momentum: Rendite über ``n`` Zeilen in Prozent: Kauf ab ``threshold + band``, Verkauf unter
          ``threshold - band``.
        - signal_drawdown: Verkauf ab ``sell_dd`` Prozent unter dem (rollierenden) Hoch, Kauf (Wiedereinstieg),
          solange der Abstand unter ``buy_dd`` Prozent liegt; dazwischen bleibt der Zustand.
        - signal_volatility: Realisierte Volatilität der Log-Renditen über ``n`` Zeilen, annualisiert mit ``ppy``,
          in Prozent p. a.: Kauf bis ``threshold - band``, Verkauf über ``threshold + band``.
        - signal_combine: Verknüpft Signale: ``"and"`` kauft nur, wenn alle kaufen, und verkauft, sobald eines
          verkauft; ``"or"`` kauft, sobald eines kauft, und verkauft nur, wenn alle verkaufen.

    Beispiel::

        import numpy as np, simlev
        x = 100 * np.cumprod(1 + np.random.default_rng(1).normal(2e-4, 0.01, 1000))
        print(simlev.signal_momentum(x, n=250)["buy"].sum())
    """
    fn = "signal_momentum"
    _sig_x(x, fn)
    n = _sig_win(n, fn, "n")
    threshold = chk_num1(threshold, fn, "threshold")
    band = chk_num1(band, fn, "band", lo=0)
    lag = _sig_win(lag, fn, "lag", lo=0)
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

    Erzeugen Kauf- und Verkaufssignale aus einer Kursreihe, im Format, das ``bootstrap_study()`` und
    ``param_search()`` für ``signal = function(df) ...`` erwarten: Die Elemente ``buy`` und ``sell`` werden dort
    als gleichnamige Spalten an den Datensatz angehängt. Für ``simulation()`` hängt man sie selbst an und nennt
    sie in ``asset_config()`` (``trading = "signal"``, ``signal_buy``, ``signal_sell``); für ``tactical_rules()``
    lassen sie sich direkt als Bedingung verwenden.

    Args:
        x: Numerischer Vektor mit Kursniveaus (z. B. ``df["eu"]``).
        sell_dd, buy_dd: Abstand zum Hoch in Prozent (positiv, 20 = 20 % unter dem Hoch); ``buy_dd`` darf nicht
            größer als ``sell_dd`` sein (Standard 20 und 10).
        window: Fenster in Zeilen für das rollierende Hoch (Standard ``None`` = laufendes Hoch seit Beginn).
        lag: Verzögerung der Signale in Zeilen (Standard 0; z. B. 1, um erst in der Folgezeile zu handeln). Die
            ersten ``lag`` Zeilen sind ``False``.

    Returns:
        ``{"buy": ..., "sell": ...}`` mit logischen Vektoren der Länge von ``x`` (NA als ``False``).

    Details:
        Eingabe ist ein numerischer Vektor mit Kursniveaus (keine Renditen), z. B. eine Spalte aus
        ``series_align()``. Alle Fenster (``n``, ``fast``, ``slow``, ``window``, ``lag``) zählen in Zeilen der
        Daten, bei Kalendertagsdaten (Wochenenden per LOCF) also in Kalendertagen, bei Handelstagsdaten in
        Handelstagen. Solange ein Fenster noch nicht gefüllt ist, sind beide Signale ``False`` (außer bei
        ``signal_drawdown``, das anfangs das Hoch der bisherigen Zeilen verwendet). ``x`` sollte keine NA
        enthalten: Bei Durchschnitten liefern Fenster mit NA kein Signal, beim exponentiellen Durchschnitt auch
        alle folgenden Zeilen; bei ``signal_drawdown`` nur die Zeile mit NA (das Hoch wird ohne sie fortgeführt).

        Eingaben (seit 1.6.4 geprüft): ``x`` ein numerischer Vektor (keine Matrix, Tabelle, kein Text, keine
        Kategorie, keine Wahrheitswerte; leer erlaubt); ``n``, ``fast``, ``slow``, ``window`` je eine endliche Zahl
        ``>= 1``, ``lag >= 0`` (seit 1.6.4 ganze Zahlen, gebrochene Werte sind ein Fehler; ``lag`` ab der Länge von ``x`` ergibt nur
        ``False``); ``band >= 0``; ``sell_dd``, ``buy_dd`` größer 0 und höchstens 100; bei ``signal_volatility``
        ``threshold >= 0`` und ``ppy > 0``; bei ``signal_combine`` ``buy`` und ``sell`` je True/False oder 0/1
        (NA bleibt NA: Ergebnis dann als object-Feld mit ``None``).

        ``band`` wirkt als Hysterese: Zwischen Kauf- und Verkaufsschwelle sind beide Signale ``False``, der
        Zustand in ``simulation()`` bzw. ``signal_state()`` bleibt dann unverändert. Bei Durchschnitten
        (``signal_sma``, ``signal_ema``, ``signal_crossover``) ist ``band`` relativ zum Durchschnitt in Prozent,
        bei ``signal_momentum`` und ``signal_volatility`` ein Abstand in Prozentpunkten zu ``threshold``.

        - signal_sma: Kurs über/unter dem einfachen gleitenden Durchschnitt der letzten ``n`` Zeilen
          (einschließlich der aktuellen): Kauf ab ``SMA * (1 + band/100)``, Verkauf unter ``SMA * (1 -
          band/100)``, dazwischen bleibt der Zustand.
        - signal_ema: Wie ``signal_sma`` mit exponentiellem Durchschnitt (Glättung 2 / (n + 1), Start mit dem
          einfachen Mittel der ersten ``n`` Werte).
        - signal_crossover: Schneller über langsamem Durchschnitt: Kauf, wenn der schnelle mindestens das ``(1 +
          band/100)``-fache des langsamen erreicht, Verkauf unter dem ``(1 - band/100)``-fachen.
        - signal_momentum: Rendite über ``n`` Zeilen in Prozent: Kauf ab ``threshold + band``, Verkauf unter
          ``threshold - band``.
        - signal_drawdown: Verkauf ab ``sell_dd`` Prozent unter dem (rollierenden) Hoch, Kauf (Wiedereinstieg),
          solange der Abstand unter ``buy_dd`` Prozent liegt; dazwischen bleibt der Zustand.
        - signal_volatility: Realisierte Volatilität der Log-Renditen über ``n`` Zeilen, annualisiert mit ``ppy``,
          in Prozent p. a.: Kauf bis ``threshold - band``, Verkauf über ``threshold + band``.
        - signal_combine: Verknüpft Signale: ``"and"`` kauft nur, wenn alle kaufen, und verkauft, sobald eines
          verkauft; ``"or"`` kauft, sobald eines kauft, und verkauft nur, wenn alle verkaufen.

    Beispiel::

        import numpy as np, simlev
        x = 100 * np.cumprod(1 + np.random.default_rng(1).normal(2e-4, 0.01, 1000))
        print(simlev.signal_drawdown(x, sell_dd=20, buy_dd=10)["sell"].sum())
    """
    fn = "signal_drawdown"
    _sig_x(x, fn)
    sell_dd = chk_num1(sell_dd, fn, "sell_dd", lo=0, lo_open=True, hi=100)
    buy_dd = chk_num1(buy_dd, fn, "buy_dd", lo=0, lo_open=True, hi=100)
    window = _sig_win(window, fn, "window", null_ok=True)
    lag = _sig_win(lag, fn, "lag", lo=0)
    x = _as_numeric(x)
    if buy_dd > sell_dd:
        raise ValueError("buy_dd darf nicht größer als sell_dd sein.")
    xp = np.where(np.isnan(x), -math.inf, x)
    if window is None:
        peak = np.maximum.accumulate(xp) if len(xp) else xp
    else:
        w = int(window)
        m = len(x)
        if w >= 1:   # gleitendes Maximum im Kern (seit 1.6.3, O(m)); gleiche Werte gewinnt das erste (wie R max())
            peak = np.empty(m)
            _ext.roll_max_core(np.ascontiguousarray(xp, dtype=np.float64), min(w, max(m, 1)), 0, peak)
        else:        # w < 1: Fehler aus np.max wie bisher (R: Fehler bzw. NA)
            peak = np.array([np.max(xp[max(0, i - w + 1): i + 1]) for i in range(m)], dtype=np.float64)
    with np.errstate(invalid="ignore", divide="ignore"):
        dd = 100 * (1 - x / peak)
    return _sig_out(_cmp(np.less, dd, buy_dd), _cmp(np.greater_equal, dd, sell_dd), lag)


def signal_volatility(x, *, n=20, threshold=25, band=0, ppy=365.25, lag=0):
    """Realisierte Volatilität der Log-Renditen über ``n`` Zeilen in Prozent p. a.

    Erzeugen Kauf- und Verkaufssignale aus einer Kursreihe, im Format, das ``bootstrap_study()`` und
    ``param_search()`` für ``signal = function(df) ...`` erwarten: Die Elemente ``buy`` und ``sell`` werden dort
    als gleichnamige Spalten an den Datensatz angehängt. Für ``simulation()`` hängt man sie selbst an und nennt
    sie in ``asset_config()`` (``trading = "signal"``, ``signal_buy``, ``signal_sell``); für ``tactical_rules()``
    lassen sie sich direkt als Bedingung verwenden.

    Args:
        x: Numerischer Vektor mit Kursniveaus (z. B. ``df["eu"]``).
        n: Fensterlänge in Zeilen (Standard: 200 bei ``signal_sma`` und ``signal_ema``, 250 bei
            ``signal_momentum``, 20 bei ``signal_volatility``).
        threshold: Schwelle in Prozent: bei ``signal_momentum`` für die Rendite über ``n`` Zeilen (Standard 0),
            bei ``signal_volatility`` für die Volatilität in Prozent p. a. (Standard 25).
        band: Hysterese-Band (Standard 0 = keins): bei Durchschnitten in Prozent des Durchschnitts (1 = 1 %), bei
            ``signal_momentum`` und ``signal_volatility`` in Prozentpunkten um ``threshold``.
        ppy: Zeilen je Jahr für die Annualisierung der Volatilität (Standard 365.25 für Kalendertagsdaten; bei
            Handelstagsdaten z. B. 252). Wird nicht aus den Daten ermittelt.
        lag: Verzögerung der Signale in Zeilen (Standard 0; z. B. 1, um erst in der Folgezeile zu handeln). Die
            ersten ``lag`` Zeilen sind ``False``.

    Returns:
        ``{"buy": ..., "sell": ...}`` mit logischen Vektoren der Länge von ``x`` (NA als ``False``).

    Details:
        Eingabe ist ein numerischer Vektor mit Kursniveaus (keine Renditen), z. B. eine Spalte aus
        ``series_align()``. Alle Fenster (``n``, ``fast``, ``slow``, ``window``, ``lag``) zählen in Zeilen der
        Daten, bei Kalendertagsdaten (Wochenenden per LOCF) also in Kalendertagen, bei Handelstagsdaten in
        Handelstagen. Solange ein Fenster noch nicht gefüllt ist, sind beide Signale ``False`` (außer bei
        ``signal_drawdown``, das anfangs das Hoch der bisherigen Zeilen verwendet). ``x`` sollte keine NA
        enthalten: Bei Durchschnitten liefern Fenster mit NA kein Signal, beim exponentiellen Durchschnitt auch
        alle folgenden Zeilen; bei ``signal_drawdown`` nur die Zeile mit NA (das Hoch wird ohne sie fortgeführt).

        Eingaben (seit 1.6.4 geprüft): ``x`` ein numerischer Vektor (keine Matrix, Tabelle, kein Text, keine
        Kategorie, keine Wahrheitswerte; leer erlaubt); ``n``, ``fast``, ``slow``, ``window`` je eine endliche Zahl
        ``>= 1``, ``lag >= 0`` (seit 1.6.4 ganze Zahlen, gebrochene Werte sind ein Fehler; ``lag`` ab der Länge von ``x`` ergibt nur
        ``False``); ``band >= 0``; ``sell_dd``, ``buy_dd`` größer 0 und höchstens 100; bei ``signal_volatility``
        ``threshold >= 0`` und ``ppy > 0``; bei ``signal_combine`` ``buy`` und ``sell`` je True/False oder 0/1
        (NA bleibt NA: Ergebnis dann als object-Feld mit ``None``).

        ``band`` wirkt als Hysterese: Zwischen Kauf- und Verkaufsschwelle sind beide Signale ``False``, der
        Zustand in ``simulation()`` bzw. ``signal_state()`` bleibt dann unverändert. Bei Durchschnitten
        (``signal_sma``, ``signal_ema``, ``signal_crossover``) ist ``band`` relativ zum Durchschnitt in Prozent,
        bei ``signal_momentum`` und ``signal_volatility`` ein Abstand in Prozentpunkten zu ``threshold``.

        - signal_sma: Kurs über/unter dem einfachen gleitenden Durchschnitt der letzten ``n`` Zeilen
          (einschließlich der aktuellen): Kauf ab ``SMA * (1 + band/100)``, Verkauf unter ``SMA * (1 -
          band/100)``, dazwischen bleibt der Zustand.
        - signal_ema: Wie ``signal_sma`` mit exponentiellem Durchschnitt (Glättung 2 / (n + 1), Start mit dem
          einfachen Mittel der ersten ``n`` Werte).
        - signal_crossover: Schneller über langsamem Durchschnitt: Kauf, wenn der schnelle mindestens das ``(1 +
          band/100)``-fache des langsamen erreicht, Verkauf unter dem ``(1 - band/100)``-fachen.
        - signal_momentum: Rendite über ``n`` Zeilen in Prozent: Kauf ab ``threshold + band``, Verkauf unter
          ``threshold - band``.
        - signal_drawdown: Verkauf ab ``sell_dd`` Prozent unter dem (rollierenden) Hoch, Kauf (Wiedereinstieg),
          solange der Abstand unter ``buy_dd`` Prozent liegt; dazwischen bleibt der Zustand.
        - signal_volatility: Realisierte Volatilität der Log-Renditen über ``n`` Zeilen, annualisiert mit ``ppy``,
          in Prozent p. a.: Kauf bis ``threshold - band``, Verkauf über ``threshold + band``.
        - signal_combine: Verknüpft Signale: ``"and"`` kauft nur, wenn alle kaufen, und verkauft, sobald eines
          verkauft; ``"or"`` kauft, sobald eines kauft, und verkauft nur, wenn alle verkaufen.

    Beispiel::

        import numpy as np, simlev
        x = 100 * np.cumprod(1 + np.random.default_rng(1).normal(2e-4, 0.01, 1000))
        print(simlev.signal_volatility(x, n=20, threshold=25)["buy"].sum())
    """
    fn = "signal_volatility"
    _sig_x(x, fn)
    n = _sig_win(n, fn, "n")
    threshold = chk_num1(threshold, fn, "threshold", lo=0)
    band = chk_num1(band, fn, "band", lo=0)
    ppy = chk_num1(ppy, fn, "ppy", lo=0, lo_open=True)
    lag = _sig_win(lag, fn, "lag", lo=0)
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
    """Verknüpft Signale: ``"and"`` kauft nur, wenn alle kaufen, und verkauft, sobald eines verkauft; ``"or"`` kauft, sobald eines kauft, und verkauft nur, wenn alle verkaufen.

    Erzeugen Kauf- und Verkaufssignale aus einer Kursreihe, im Format, das ``bootstrap_study()`` und
    ``param_search()`` für ``signal = function(df) ...`` erwarten: Die Elemente ``buy`` und ``sell`` werden dort
    als gleichnamige Spalten an den Datensatz angehängt. Für ``simulation()`` hängt man sie selbst an und nennt
    sie in ``asset_config()`` (``trading = "signal"``, ``signal_buy``, ``signal_sell``); für ``tactical_rules()``
    lassen sie sich direkt als Bedingung verwenden.

    Args:
        *signals: Bei ``signal_combine``: Signal-Listen ``{"buy": ..., "sell": ...}`` gleicher Länge (sonst
            Fehler).
        op: Verknüpfung bei ``signal_combine``: ``"and"`` (Standard) oder ``"or"``.

    Returns:
        ``{"buy": ..., "sell": ...}`` mit logischen Vektoren der Länge von ``x`` (NA als ``False``).

    Details:
        Eingabe ist ein numerischer Vektor mit Kursniveaus (keine Renditen), z. B. eine Spalte aus
        ``series_align()``. Alle Fenster (``n``, ``fast``, ``slow``, ``window``, ``lag``) zählen in Zeilen der
        Daten, bei Kalendertagsdaten (Wochenenden per LOCF) also in Kalendertagen, bei Handelstagsdaten in
        Handelstagen. Solange ein Fenster noch nicht gefüllt ist, sind beide Signale ``False`` (außer bei
        ``signal_drawdown``, das anfangs das Hoch der bisherigen Zeilen verwendet). ``x`` sollte keine NA
        enthalten: Bei Durchschnitten liefern Fenster mit NA kein Signal, beim exponentiellen Durchschnitt auch
        alle folgenden Zeilen; bei ``signal_drawdown`` nur die Zeile mit NA (das Hoch wird ohne sie fortgeführt).

        Eingaben (seit 1.6.4 geprüft): ``x`` ein numerischer Vektor (keine Matrix, Tabelle, kein Text, keine
        Kategorie, keine Wahrheitswerte; leer erlaubt); ``n``, ``fast``, ``slow``, ``window`` je eine endliche Zahl
        ``>= 1``, ``lag >= 0`` (seit 1.6.4 ganze Zahlen, gebrochene Werte sind ein Fehler; ``lag`` ab der Länge von ``x`` ergibt nur
        ``False``); ``band >= 0``; ``sell_dd``, ``buy_dd`` größer 0 und höchstens 100; bei ``signal_volatility``
        ``threshold >= 0`` und ``ppy > 0``; bei ``signal_combine`` ``buy`` und ``sell`` je True/False oder 0/1
        (NA bleibt NA: Ergebnis dann als object-Feld mit ``None``).

        ``band`` wirkt als Hysterese: Zwischen Kauf- und Verkaufsschwelle sind beide Signale ``False``, der
        Zustand in ``simulation()`` bzw. ``signal_state()`` bleibt dann unverändert. Bei Durchschnitten
        (``signal_sma``, ``signal_ema``, ``signal_crossover``) ist ``band`` relativ zum Durchschnitt in Prozent,
        bei ``signal_momentum`` und ``signal_volatility`` ein Abstand in Prozentpunkten zu ``threshold``.

        - signal_sma: Kurs über/unter dem einfachen gleitenden Durchschnitt der letzten ``n`` Zeilen
          (einschließlich der aktuellen): Kauf ab ``SMA * (1 + band/100)``, Verkauf unter ``SMA * (1 -
          band/100)``, dazwischen bleibt der Zustand.
        - signal_ema: Wie ``signal_sma`` mit exponentiellem Durchschnitt (Glättung 2 / (n + 1), Start mit dem
          einfachen Mittel der ersten ``n`` Werte).
        - signal_crossover: Schneller über langsamem Durchschnitt: Kauf, wenn der schnelle mindestens das ``(1 +
          band/100)``-fache des langsamen erreicht, Verkauf unter dem ``(1 - band/100)``-fachen.
        - signal_momentum: Rendite über ``n`` Zeilen in Prozent: Kauf ab ``threshold + band``, Verkauf unter
          ``threshold - band``.
        - signal_drawdown: Verkauf ab ``sell_dd`` Prozent unter dem (rollierenden) Hoch, Kauf (Wiedereinstieg),
          solange der Abstand unter ``buy_dd`` Prozent liegt; dazwischen bleibt der Zustand.
        - signal_volatility: Realisierte Volatilität der Log-Renditen über ``n`` Zeilen, annualisiert mit ``ppy``,
          in Prozent p. a.: Kauf bis ``threshold - band``, Verkauf über ``threshold + band``.
        - signal_combine: Verknüpft Signale: ``"and"`` kauft nur, wenn alle kaufen, und verkauft, sobald eines
          verkauft; ``"or"`` kauft, sobald eines kauft, und verkauft nur, wenn alle verkaufen.

    Beispiel::

        import numpy as np, simlev
        x = 100 * np.cumprod(1 + np.random.default_rng(1).normal(2e-4, 0.01, 1000))
        both = simlev.signal_combine(simlev.signal_sma(x, n=200), simlev.signal_volatility(x, n=20, threshold=25))
        print(both["buy"].sum())
    """
    op = _match_arg(chk_scalar(op), ("and", "or"))
    s = list(signals)
    if not s:
        raise ValueError("Keine Signale übergeben.")
    # seit 1.6.4 (B-008, Entscheidung 1): je Signal buy und sell, jeweils True/False oder 0/1 (NA erlaubt, bleibt NA
    # wie in R; bis 1.6.3 las Python NaN und Text als True)
    vb, vs = [], []
    for i, z in enumerate(s, start=1):
        b = _sig_vals(_get(z, "buy")) if isinstance(z, Mapping) or hasattr(z, "buy") else None
        c = _sig_vals(_get(z, "sell")) if isinstance(z, Mapping) or hasattr(z, "sell") else None
        if b is None or c is None:
            chk_stop("e1.signal", "signal_combine", i)
        vb.append(b)
        vs.append(c)
    lens = [len(b) for b in vb]
    slen = [len(c) for c in vs]
    if any(L != lens[0] for L in lens) or any(a != b for a, b in zip(slen, lens)):
        raise ValueError("signal_combine: Signale haben unterschiedliche Längen (%s); alle aus derselben "
                         "Kursreihe erzeugen." % ", ".join(str(L) for L in lens))
    if any(e is None for v in vb + vs for e in v):   # mit NA: dreiwertig wie R (&, |, all, any)
        return {"buy": _sig_comb(vb, op == "and"), "sell": _sig_comb(vs, op != "and")}
    B = np.column_stack([np.asarray(v, dtype=bool) for v in vb])
    S = np.column_stack([np.asarray(v, dtype=bool) for v in vs])
    if op == "and":
        return {"buy": B.all(axis=1), "sell": S.any(axis=1)}
    return {"buy": B.any(axis=1), "sell": S.all(axis=1)}


def _sig_vals(v):
    """Signalvektor als Liste aus True/False/None (NA); None, wenn kein Signal (Text, andere Zahlen, Matrix)."""
    import pandas as pd
    if v is None or isinstance(v, (str, bytes, Mapping, pd.DataFrame)) or (isinstance(v, np.ndarray) and v.ndim > 1):
        return None
    if isinstance(v, pd.Series):
        if isinstance(v.dtype, pd.CategoricalDtype):
            return None
        arr = list(v.to_numpy(dtype=object))
    elif isinstance(v, (np.ndarray, list, tuple)):
        arr = list(np.asarray(v, dtype=object).ravel()) if isinstance(v, np.ndarray) else list(v)
    else:
        arr = [v]
    out = []
    for e in arr:
        if _isna1(e):
            out.append(None)
        elif isinstance(e, (bool, np.bool_)):
            out.append(bool(e))
        elif isinstance(e, (int, float, np.integer, np.floating)) and e in (0, 1):
            out.append(bool(e))
        else:
            return None
    return out


def _sig_comb(vs, conj):
    """Elementweise all (conj) bzw. any mit NA wie R; Ergebnis als object-Feld aus True/False/None."""
    n = len(vs[0]) if vs else 0
    out = np.empty(n, dtype=object)
    for i in range(n):
        col = [v[i] for v in vs]
        if conj:
            out[i] = False if any(e is False for e in col) else (None if any(e is None for e in col) else True)
        else:
            out[i] = True if any(e is True for e in col) else (None if any(e is None for e in col) else False)
    return out


quiet_fp(globals(), __all__ + ["_roll_mean", "_roll_var", "_roll_cov", "_ema", "_sig_out"])
