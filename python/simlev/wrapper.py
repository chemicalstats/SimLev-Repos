"""Fonds-Wrapper (Port von ``r/R/wrapper.R``, Etappe 6.5c): Anteilswert (NAV) aus einer inneren Strategie.

- ``wrapper_config(strategy, rebalance, costs, order_fee, volume)``  → :class:`SimLevWrapperConfig`
- ``asset_config(..., wrapper=wrapper_config(...))``                Wrapper als ein Asset der Strategie
- ``wrapper_nav(data, wrapper, splits)``                             → :class:`SimLevWrapperNav`

``simulation()`` rechnet je Wrapper-Asset den Anteilswert (``_wrapper_nav_calc``) und hängt ihn als Kursspalte
mit dem Asset-Namen an ``data`` an (``_sim_phases._sim_check_inputs``, nach der Prüfung der Datumsspalte).
Danach rechnet die Engine mit einem gewöhnlichen Asset ohne ``wrapper``; für die NAV-Spalte gibt es keine
Splits (``cfg["no_split"]``).

Rechenregeln des Anteilswerts (wörtlich wie im Kopf von ``r/R/wrapper.R``; Reihenfolge der Operationen wie dort):

1. Innere Bruttorechnung ``simulation(d, strategy, start_value=S, costs=sim_costs(order_fee=order_fee),
   rebalance=rebalance, splits=splits, tax=None, fractions=True)`` mit ``S = volume``, ohne ``volume``
   ``S = 100``; ``d`` = ``data`` ab der ersten Zeile, in der mindestens eine innere Kursspalte nicht NA ist.
   ``G`` = ``worth`` an den NAV-Tagen (Datenzeilen von ``d``, die in ``result.filled`` nicht als aufgefüllt
   gelten).
2. Start: ``U = 100``, ``H = 100``, ``G_prev = S``, ``d_prev`` = erster Tag von ``d``.
3. Je NAV-Tag ``t``: ``a = U * (G_t / G_prev)``, ``k = fee / 100 * dd / D`` (``D`` = 366 im Schaltjahr von
   ``t``, sonst 365), ``fee_t = a * k``, ``U = a - fee_t``, ``acc_t = performance_fee / 100 * max(0, U - H)``,
   ``nav_t = U - acc_t``; am letzten NAV-Tag eines Kalenderjahres (nicht am letzten insgesamt) Festschreibung
   ``paid_t = acc_t``, ``U = nav_t``, ``H = max(H, U)``; ``gross_t = 100 * G_t / S``, ``hwm_t = H``.

Der Paketzustand der Ordergebühren (``_sim_base._FEE``, R ``.fee_env``) wird vor der inneren Rechnung gesichert
und danach (auch bei Fehlern) wiederhergestellt. Meldungen der inneren Rechnung erscheinen als
``"Hinweis: <tag> (innere Rechnung): …"``, Warnungen und Fehler als ``"<who> (innere Rechnung): …"``.
"""
from __future__ import annotations

import contextlib
import io
import math
import sys
import warnings
from typing import Any, Mapping

import numpy as np
import pandas as pd

from ._dates import fmt_date, year_of
from ._r.rformat import r_format1, r_sprintf
from ._r.rlist import RList
from ._r.rnum import NA_REAL as NA, r_sum
from ._sim_base import _FEE, _Frame, _fee_spec, _filled_matrix, _isna, _message, _to_frame
from ._sim_blocks import (SimLevFundsCosts, SimLevRebalancePlan, SimLevSplitRule, _blk_print, _cls, _fee_text,
                          _fmt, _one_num, _sched_text, _show, funds_costs, sim_costs)
from .config import (Strategy, _is_wrapper, _strategy_columns, _strategy_wrappers, _wrapper_assets_text,
                     create_strategy, strategy_validate)
from .data_prep import _to_date

__all__ = ["wrapper_config", "wrapper_nav", "SimLevWrapperConfig", "SimLevWrapperNav"]


def _is_leap(y: int) -> bool:
    """``.wrapper_is_leap``."""
    return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0


# ── wrapper_config ───────────────────────────────────────────────────────────

class SimLevWrapperConfig(RList):
    """Fonds-Wrapper (R: ``wrapper_config()``): Felder ``strategy``, ``rebalance``, ``costs``, ``order_fee``,
    ``volume``; ``print()`` wie ``print.SimLevWrapperConfig``."""
    r_class = ("SimLevWrapperConfig",)

    def format(self) -> str:
        rb = self["rebalance"]
        if rb is None:
            umsch = "keines"
        elif rb["event_col"] is not None and rb["event_mode"] == "replace":
            umsch = "an Ereignissen (Spalte '%s')" % rb["event_col"]
        else:
            umsch = _sched_text(rb["span"], rb["unit"], rb["days"], rb["anchor"])
        vol = self["volume"]
        return _blk_print("Fonds-Wrapper (wrapper_config)",
                          [("Innere Assets", _wrapper_assets_text(self["strategy"])),
                           ("Umschichten", umsch),
                           ("Fondskosten", "%s %% p. a. (täglich je Kalendertag)" % _fmt(self["costs"]["fee"])),
                           ("Performancegebühr", "%s %% über dem Höchststand (täglich abgegrenzt, jährlich "
                            "festgeschrieben)" % _fmt(self["costs"]["performance_fee"])),
                           ("Ordergebühr innen", _fee_text(self["order_fee"])),
                           ("Fondsvolumen", "nicht angegeben (Start mit 100)" if vol is None
                            else r_sprintf("%.2f EUR", vol))])

    def print(self) -> "SimLevWrapperConfig":
        print(self.format())
        return self


class _FundsCostsDefault:
    """Standard ``costs = funds_costs()`` (wird im Rumpf angelegt; Text wie in R)."""

    __slots__ = ()

    def __repr__(self) -> str:
        return "funds_costs()"


_FUNDS_COSTS = _FundsCostsDefault()


def wrapper_config(strategy: Any, *, rebalance: Any = None, costs: Any = _FUNDS_COSTS, order_fee: Any = None,
                   volume: Any = None) -> SimLevWrapperConfig:
    """Fonds-Wrapper konfigurieren (R: ``wrapper_config()``, Etappe 6.5c).

    Args:
        strategy: innere Strategie aus :func:`simlev.create_strategy` oder ein ``dict``, das
            ``create_strategy(assets=...)`` annimmt; Gewichte (``share``) mit Summe 1, ohne verschachtelte
            Wrapper. Innere Signale sind erlaubt.
        rebalance: ``None`` oder :func:`simlev.rebalance_plan` (Umschichten innen).
        costs: :func:`simlev.funds_costs` (Verwaltungsgebühr in % p. a., täglich je Kalendertag; Performancegebühr
            in % über dem Höchststand, täglich abgegrenzt, am 31.12. festgeschrieben).
        order_fee: Ordergebühr der inneren Käufe im Format von :func:`simlev.sim_costs` (Zahl oder ``dict`` mit
            ``fixed``, ``percent``, ``min``, ``max``).
        volume: ``None`` oder Fondsvolumen in EUR (Zahl > 0); Pflicht für feste Beträge, ``min`` und ``max`` der
            Ordergebühr. Die innere Rechnung startet mit diesem Volumen, sonst mit 100.

    Returns:
        :class:`SimLevWrapperConfig`. Innere Assets mit Spread > 0 ergeben einen Hinweis (``sys.stderr``).
    """
    if isinstance(costs, _FundsCostsDefault):
        costs = funds_costs()
    if strategy is None:
        raise ValueError("wrapper_config: strategy fehlt (innere Strategie aus create_strategy() oder eine Liste, die "
                         "create_strategy() annimmt).")
    if not isinstance(strategy, Strategy):
        if not isinstance(strategy, (Mapping, list, tuple)):
            raise ValueError("wrapper_config: strategy muss ein Objekt aus create_strategy() oder eine benannte Liste von "
                             "Asset-Konfigurationen sein, nicht %s." % _cls(strategy).split("/")[0])
        strategy = create_strategy(assets=strategy)
    strategy_validate(strategy)
    nested = _strategy_wrappers(strategy)
    if nested:
        raise ValueError("wrapper_config: Asset '%s' der inneren Strategie hat selbst einen Wrapper; verschachtelte "
                         "Wrapper sind nicht möglich." % nested[0])
    total = r_sum(np.array([float(a["share"]) for a in strategy.values()], dtype=np.float64))
    if abs(total - 1) > 1e-6:
        raise ValueError(r_sprintf("wrapper_config: Gewichte (share) der inneren Strategie summieren sich auf %.4f, "
                                   "müssen aber 1 ergeben.", total))
    if rebalance is not None and not isinstance(rebalance, SimLevRebalancePlan):
        raise ValueError("wrapper_config: rebalance muss NULL oder ein Objekt aus rebalance_plan() sein, nicht %s."
                         % _cls(rebalance))
    if not isinstance(costs, SimLevFundsCosts):
        raise ValueError("wrapper_config: costs muss ein Objekt aus funds_costs() sein, nicht %s."
                         % ("NULL" if costs is None else _cls(costs)))
    fs = _fee_spec(order_fee)
    if volume is not None and (not _one_num(volume) or volume <= 0):
        raise ValueError("wrapper_config: 'volume' muss NULL oder eine einzelne endliche Zahl > 0 sein (Fondsvolumen in "
                         "EUR), nicht %s." % _show(volume))
    if fs is not None and volume is None and (fs["fixed"] > 0 or fs["min"] > 0 or math.isfinite(fs["max"])):
        raise ValueError("wrapper_config: order_fee enthält feste Beträge in EUR (fixed, min oder max); dafür ist das "
                         "Fondsvolumen 'volume' in EUR nötig (die innere Rechnung startet dann mit diesem Volumen). Ohne "
                         "volume gehen nur Prozentgebühren (order_fee = list(percent = ...)).")
    spr = [(nm, 0.0 if a.get("spread") is None else float(a["spread"])) for nm, a in strategy.items()]
    if any(v > 0 for _, v in spr):
        _message("Hinweis: wrapper_config: innere Assets mit Spread > 0: %s; der Spread gilt in der inneren "
                 "Rechnung (Kauf und Umschichten)." % ", ".join("'%s' (%s %%)" % (nm, _fmt(v)) for nm, v in spr if v > 0))
    out = SimLevWrapperConfig()
    for k, v in (("strategy", strategy), ("rebalance", rebalance), ("costs", costs), ("order_fee", order_fee),
                 ("volume", None if volume is None else float(volume))):
        out[k] = v
    return out


# ── Anteilswert ──────────────────────────────────────────────────────────────

class _NavAttrs(dict):
    """``attrs`` eines :class:`SimLevWrapperNav` (``inner``, ``wrapper``). pandas gibt ``attrs`` bei jeder Auswahl
    (Zeilen, Spalten, ``head``, ``query``, ``copy`` …) per ``copy.deepcopy`` an das Ergebnis weiter; hier ergibt
    das ein leeres ``dict``: Eine Auswahl ist eine gewöhnliche Tabelle ohne Attribute (R: ``[.SimLevWrapperNav``,
    Etappe 8.0), und das innere Ergebnis wird nicht mehr bei jeder Spaltenauswahl tief kopiert."""

    __slots__ = ()

    def __deepcopy__(self, memo) -> dict:
        return {}


class SimLevWrapperNav(pd.DataFrame):
    """Anteilswert eines Fonds-Wrappers (R-Klasse ``c("SimLevWrapperNav", "data.frame")``): Spalten ``date``,
    ``nav``, ``gross``, ``fee``, ``perf_fee``, ``perf_paid``, ``hwm``; ``attrs["inner"]`` (inneres
    :class:`simlev.SimLevResult`) und ``attrs["wrapper"]`` (:class:`SimLevWrapperConfig`). Jede Auswahl (Zeilen,
    Spalten, ``head()``, ``query()``, ``loc``/``iloc``) ist ein gewöhnlicher ``pandas.DataFrame`` (bzw. eine
    ``Series``) ohne ``attrs`` (R: ``[.SimLevWrapperNav`` liefert einen data.frame ohne Klasse und Attribute;
    Julia: ``rows()`` ohne Klasse und Attribute)."""

    r_class = ("SimLevWrapperNav", "data.frame")

    @property
    def _constructor(self):
        return pd.DataFrame

    @property
    def attrs(self) -> dict:
        """``attrs`` als :class:`_NavAttrs` (auch nach ``pickle``, das ``attrs`` als ``dict`` zurückgibt)."""
        a = self._attrs
        if type(a) is not _NavAttrs:
            a = _NavAttrs(a)
            object.__setattr__(self, "_attrs", a)
        return a

    @attrs.setter
    def attrs(self, value) -> None:
        object.__setattr__(self, "_attrs", _NavAttrs(value))

    def format(self) -> str:
        w = self.attrs.get("wrapper")
        if not _is_wrapper(w) or not len(self) or not all(c in self.columns for c in ("date", "nav", "gross")):
            from ._r.fmt import print_data_frame
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                print_data_frame(pd.DataFrame(self))
            return buf.getvalue().rstrip("\n")
        n = len(self)
        dates = np.asarray(self["date"]).astype("datetime64[D]")
        nav = np.asarray(self["nav"], dtype=np.float64)
        gross = np.asarray(self["gross"], dtype=np.float64)
        return _blk_print("Anteilswert (wrapper_nav)",
                          [("Zeitraum", "%s bis %s (%d %s)" % (str(dates[0]), str(dates[n - 1]), n,
                                                              "Datentag" if n == 1 else "Datentage")),
                           ("Fondskosten", "%s %% p. a." % _fmt(w["costs"]["fee"])),
                           ("Performancegebühr", "%s %% über dem Höchststand" % _fmt(w["costs"]["performance_fee"])),
                           ("Endwert", r_sprintf("%.4f (brutto %.4f, Start 100)", float(nav[n - 1]),
                                                 float(gross[n - 1])))])

    def __repr__(self) -> str:
        return self.format()

    __str__ = __repr__

    def _repr_html_(self):  # pragma: no cover - Jupyter
        return "<pre>%s</pre>" % self.format()


class _MsgPrefix(io.TextIOBase):
    """Meldungen der inneren Rechnung mit Präfix weitergeben (R: ``withCallingHandlers(message = )``): eine
    Meldung endet mit einem Zeilenumbruch; ``"Hinweis: "`` am Anfang wird durch das Präfix ersetzt."""

    def __init__(self, target, tag: str):
        super().__init__()
        self._t = target
        self._tag = tag
        self._buf = ""

    def writable(self) -> bool:
        return True

    def write(self, s: str) -> int:
        self._buf += s
        if self._buf.endswith("\n"):
            self._emit()
        return len(s)

    def _emit(self) -> None:
        m, self._buf = self._buf, ""
        if m.startswith("Hinweis: "):
            m = m[len("Hinweis: "):]
        self._t.write("Hinweis: %s (innere Rechnung): %s" % (self._tag, m))

    def flush(self) -> None:
        if self._buf:
            self._emit()
        self._t.flush()


def _cond_msg(e: BaseException) -> str:
    """``conditionMessage(e)``."""
    if isinstance(e, KeyError) and e.args:
        return str(e.args[0])
    return str(e)


def _frame_rows(fr: _Frame, i0: int) -> _Frame:
    """Zeilen ``i0:`` von ``fr`` (ohne Attribut ``filled``)."""
    return _Frame(list(fr.names), {nm: fr.cols[nm][i0:].copy() for nm in fr.names}, dict(fr.kinds), None)


def _wrapper_nav_calc(data: _Frame, wrapper: SimLevWrapperConfig, splits: Any, tag: str, who: str) -> SimLevWrapperNav:
    """Anteilswert eines Wrappers rechnen (R: ``.wrapper_nav_calc``); Rechenregeln im Kopf der Datei.

    ``data``: Spaltendaten (``_Frame``) mit ``date`` (Tage, aufsteigend, ohne Doppelte) und den inneren
    Kursspalten; ``data.filled_attr`` geht an die innere Rechnung. ``splits``: ``None`` oder
    :class:`simlev.SimLevSplitRule` (für die inneren Spalten). ``tag``/``who``: Kennung für Meldungen bzw.
    Warnungen und Fehler.
    """
    from .engine import simulation
    st = wrapper["strategy"]
    cols = _strategy_columns(st)
    miss = [c for c in cols if c not in data]
    if miss:
        raise ValueError("%s: %s %s der inneren Strategie %s in data (vorhanden: %s)."
                         % (who, "Kursspalte" if len(miss) == 1 else "Kursspalten",
                            ", ".join("'%s'" % m for m in miss), "fehlt" if len(miss) == 1 else "fehlen",
                            ", ".join(nm for nm in data.names if nm != "date")))
    n0 = data.nrow
    has = np.zeros(n0, dtype=bool)
    for cc in cols:
        col = data.get(cc)
        isna = np.isnan(col) if data.is_numeric(cc) else np.array([_isna(v) for v in col], dtype=bool)
        has |= ~isna
    if not has.any():
        raise ValueError("%s: die inneren Kursspalten (%s) enthalten nur NA." % (who, ", ".join(cols)))
    r0 = int(np.flatnonzero(has)[0])
    d = data
    if r0 > 0:
        fa = data.filled_attr
        d = _frame_rows(data, r0)
        fa_m, fa_cols, fa_n = _filled_matrix(fa)
        if fa_m is not None and fa_n == n0:
            d.filled_attr = pd.DataFrame(fa_m[r0:, :], columns=fa_cols) if fa_cols is not None else fa_m[r0:, :]
    S = 100.0 if wrapper["volume"] is None else float(wrapper["volume"])

    # Paketzustand der Ordergebühren sichern; die innere Rechnung setzt ihn zurück
    fee_old = dict(vars(_FEE))
    pre = _MsgPrefix(sys.stderr, tag)
    caught: list = []
    err = None
    try:
        with warnings.catch_warnings(record=True) as wl:
            warnings.simplefilter("always")
            try:
                with contextlib.redirect_stderr(pre):
                    res = simulation(d, st, start_value=S, costs=sim_costs(order_fee=wrapper["order_fee"]),
                                     rebalance=wrapper["rebalance"], splits=splits, tax=None, fractions=True)
            except Exception as e:  # noqa: BLE001 - R: tryCatch(error = )
                err = e
            finally:
                pre.flush()
            caught = list(wl)
    finally:
        vars(_FEE).clear()
        vars(_FEE).update(fee_old)
    for w in caught:
        warnings.warn("%s (innere Rechnung): %s" % (who, str(w.message)), UserWarning, stacklevel=2)
    if err is not None:
        raise ValueError("%s (innere Rechnung): %s" % (who, _cond_msg(err))) from err

    rdays = np.asarray(res["dates"]).astype("datetime64[D]").astype(np.int64)
    rfilled = np.asarray(res["filled"], dtype=bool)
    pos = {int(z): i for i, z in enumerate(rdays)}
    idx = np.array([pos[int(z)] for z in d.get("date")], dtype=np.int64)
    idx = idx[~rfilled[idx]]
    if idx.size == 0:
        raise ValueError("%s: keine Handelstage in der inneren Rechnung (alle Tage aufgefüllt)." % who)
    day = rdays[idx]
    G = np.asarray(res["worth"], dtype=np.float64)[idx]
    yr = [year_of(int(z)) for z in day]
    fee = float(wrapper["costs"]["fee"])
    pf = float(wrapper["costs"]["performance_fee"])
    n = idx.size
    nav = np.zeros(n)
    gross = np.zeros(n)
    fee_t = np.zeros(n)
    acc_t = np.zeros(n)
    paid_t = np.zeros(n)
    hwm = np.zeros(n)
    U = 100.0
    H = 100.0
    G_prev = S
    d_prev = float(rdays[0])
    for t in range(n):
        g = float(G[t])
        if not (G_prev > 0) or not math.isfinite(g) or not (g > 0):
            raise ValueError("%s: innerer Wert am %s ist %s (vorher %s); der Anteilswert ist dann nicht definiert."
                             % (who, fmt_date(int(day[t])), r_format1(g), r_format1(G_prev)))
        D = 366.0 if _is_leap(yr[t]) else 365.0
        a = U * (g / G_prev)
        k = fee / 100 * (float(day[t]) - d_prev) / D
        fee_t[t] = a * k
        U = a - fee_t[t]
        acc_t[t] = pf / 100 * max(0.0, U - H)
        nav[t] = U - acc_t[t]
        if t < n - 1 and yr[t + 1] != yr[t]:     # letzter NAV-Tag des Kalenderjahres (nicht der letzte insgesamt)
            paid_t[t] = acc_t[t]
            U = nav[t]
            H = max(H, U)
        gross[t] = 100 * g / S
        hwm[t] = H
        G_prev = g
        d_prev = float(day[t])
    out = SimLevWrapperNav({"date": day.astype("datetime64[D]"), "nav": nav, "gross": gross, "fee": fee_t,
                            "perf_fee": acc_t, "perf_paid": paid_t, "hwm": hwm})
    object.__setattr__(out, "_attrs", _NavAttrs(inner=res, wrapper=wrapper))   # Auswahl ohne attrs (_NavAttrs)
    object.__setattr__(out, "_nav_raw", (day.copy(), nav.copy()))   # für die Engine (ohne Kopie der attrs)
    return out


def _nav_raw(x: SimLevWrapperNav) -> tuple:
    """(Tage, Anteilswerte) eines Ergebnisses von ``_wrapper_nav_calc`` (Tage seit 1970 als int64)."""
    raw = getattr(x, "_nav_raw", None)
    if raw is not None:
        return raw
    return (np.asarray(x["date"]).astype("datetime64[D]").astype(np.int64), np.asarray(x["nav"], dtype=np.float64))


def wrapper_nav(data: Any, wrapper: Any, *, splits: Any = None) -> SimLevWrapperNav:
    """Anteilswert eines Fonds-Wrappers (R: ``wrapper_nav()``, Etappe 6.5c).

    Args:
        data: ``DataFrame`` mit ``date`` und den Kursspalten der inneren Strategie (unsortiert wird nach Datum
            sortiert; ``attrs["filled"]`` aus :func:`simlev.series_align` geht an die innere Rechnung).
        wrapper: :class:`SimLevWrapperConfig` aus :func:`wrapper_config`.
        splits: ``None`` oder :func:`simlev.split_rule` (für die inneren Spalten).

    Returns:
        :class:`SimLevWrapperNav` (``date``, ``nav``, ``gross``, ``fee``, ``perf_fee``, ``perf_paid``, ``hwm``;
        Start 100). ``print()`` zeigt Zeitraum, Kosten und Endwert.
    """
    if not _is_wrapper(wrapper):
        raise ValueError("wrapper_nav: wrapper muss ein Objekt aus wrapper_config() sein, nicht %s."
                         % ("NULL" if wrapper is None else _cls(wrapper)))
    if splits is not None and not isinstance(splits, SimLevSplitRule):
        raise ValueError("wrapper_nav: splits muss NULL oder ein Objekt aus split_rule() sein, nicht %s." % _cls(splits))
    if not isinstance(data, pd.DataFrame) or "date" not in [str(c) for c in data.columns]:
        raise ValueError("wrapper_nav: data muss ein data.frame mit Spalte 'date' und den Kursspalten der inneren "
                         "Strategie sein.")
    fa = data.attrs.get("filled")
    data = pd.DataFrame(data).copy()
    data["date"] = _to_date(data["date"], "wrapper_nav: data$date")
    days = np.asarray(data["date"]).astype("datetime64[D]")
    na = np.isnat(days)
    if na.any():
        raise ValueError("wrapper_nav: Spalte 'date' enthält NA (erstmals in Zeile %d)." % (int(np.flatnonzero(na)[0]) + 1))
    zd = days.astype(np.int64)
    fr_filled = fa
    if np.any(np.diff(zd) < 0):                  # nach Datum sortieren (wie simulation())
        o = np.argsort(zd, kind="stable")
        data = data.iloc[o].reset_index(drop=True)
        fa_m, fa_cols, fa_n = _filled_matrix(fa)
        fr_filled = None
        if fa_m is not None and fa_n == len(o):
            fr_filled = pd.DataFrame(fa_m[o, :], columns=fa_cols) if fa_cols is not None else fa_m[o, :]
    data.attrs = {}
    fr = _to_frame(data)
    fr.filled_attr = fr_filled
    return _wrapper_nav_calc(fr, wrapper, splits, tag="wrapper_nav", who="wrapper_nav")


# R rechnet mit NA (signalisierendes NaN) ohne Gleitkomma-Warnungen
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__ + ["_wrapper_nav_calc"])
