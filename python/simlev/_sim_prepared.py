"""Studienkern: vorbereiteter Kernlauf je Pfad bzw. Punkt (seit 1.6.5, Paket E, Entscheidung 176; FB-12; R:
``r/R/sim_prepared.R``, Julia: ``julia/src/sim_prepared.jl``).

Studien (``bootstrap_study``, ``param_search``, ``sensitivity_*``, ``planning_lumpsum_vs_dca``) rufen ``simulation()``
über ``_sim_call`` vielfach mit derselben Strategie und denselben Argumenten auf; je Pfad bzw. Punkt ändern sich oft
nur Kurse (Pfade, Hebelreihen) oder Signale (Signalparameter einer Suche). Innerhalb einer Studie merkt sich
``_sim_call_study`` ab dem zweiten Aufruf mit derselben Strategie und Argumentliste einen vollständigen Lauf als
Vorlage (``_capture``: Eingabe der Tagesengine, Zustand vor der Engine, Kalender, Bausteine und die Teile der
Auswertung ohne den Lauf). Spätere Aufrufe tauschen nur die Kurs- und Signalspalten (aufgefüllt wie in
``_sim_prepare_data``) und rechnen Engine und Auswertung in einem Kernaufruf (``_ext.sim_run_prepared``,
``core/evaluate_core_impl.h`` ``simlev_run::run_prepared``); Meldungen der Engine und der Auswertung, Ergebnis und
Fehler entstehen mit denselben Funktionen wie in ``simulation()``.

Bitgleich zu ``simulation()``: dieselben Kernaufrufe in derselben Reihenfolge. Eine Vorlage entsteht nur, wenn die
Phasen 1 und 2 still blieben (``_probe``: ohne Hinweis, Warnung, Ausgabe und Fehler), ohne ``details``, ohne
Fonds-Wrapper, mit einem ``pandas.DataFrame`` ohne Attribut ``filled`` und einer Datumsspalte ``datetime64``. Ein Lauf
nutzt sie nur, wenn Spalten, Datumsspalte und die übrigen gelesenen Spalten (risk_free, Basiszins, Ereignis- und
Gewichtsspalten) gleich sind und die neuen Kurse und Signale die Prüfungen still bestehen (Kurse: Zahlen ohne NA in
[1e-100, 1e100]; Signale: dieselbe Art, logisch oder 0/1); sonst rechnet ``simulation()`` vollständig. Ändern sich
Spalten, Datum oder die übrigen Spalten bei derselben Strategie (z. B. Zeitfenster), merkt sich die Studie für diese
Strategie keine Vorlage mehr.
"""
from __future__ import annotations

import contextlib
import copy
import io
import math
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

from . import _ext
from ._sim_base import _FEE, _Frame, _StudyCache, _column

_MAX = 16          # gemerkte Vorlagen bzw. Schlüssel je Studie (älteste fällt heraus)
_UNSTABLE = object()


def _same(a, b) -> bool:
    """Gleiche Strategie bzw. Argumente (wie R ``identical``; im Zweifel nein, dann rechnet ``simulation()``)."""
    if a is b:
        return True
    if type(a) is not type(b):
        return False
    if isinstance(a, np.ndarray):
        if a.dtype != b.dtype or a.shape != b.shape:
            return False
        if a.dtype == object:
            return all(_same(x, y) for x, y in zip(a.ravel(), b.ravel()))
        return a.tobytes() == b.tobytes()
    if isinstance(a, float):
        return np.float64(a).tobytes() == np.float64(b).tobytes()
    if isinstance(a, (bool, int, str, bytes, type(None))):
        return a == b
    if isinstance(a, (list, tuple)):
        return len(a) == len(b) and all(_same(x, y) for x, y in zip(a, b))
    if isinstance(a, Mapping):
        if list(a.keys()) != list(b.keys()) or not all(_same(a[k], b[k]) for k in a):
            return False
        return _same(getattr(a, "__dict__", None), getattr(b, "__dict__", None))
    if isinstance(a, (pd.Series, pd.DataFrame)) or callable(a):
        return False
    if hasattr(a, "__dict__"):
        return _same(vars(a), vars(b))
    return False


def _col_same(x, y) -> bool:
    """Zwei Spalten nach ``_column``: gleiche Art und gleiche Werte (Zahlen bitgleich)."""
    if x[0] != y[0]:
        return False
    return _same(x[1], y[1])


def _colof(data, c):
    """Spalte c als (Art, Feld) wie ``_to_frame``: aus einem ``_Frame`` direkt, aus einer Tabelle über ``_column``."""
    if isinstance(data, _Frame):
        return data.kinds[c], data.cols[c]
    return _column(data[c])


def _shape(data):
    """Form der Tabelle für die Vorlage: (Art, Spaltennamen, Datumsfeld) bzw. None (keine Vorlage möglich)."""
    if isinstance(data, _Frame):
        if data.filled_attr is not None or data.kinds.get("date") != "date":
            return None
        return ("frame", list(data.names), data.cols["date"])
    if not isinstance(data, pd.DataFrame) or data.attrs.get("filled") is not None or "date" not in data.columns:
        return None
    dt = data["date"].dtype
    if not pd.api.types.is_datetime64_dtype(dt) or getattr(dt, "tz", None) is not None:
        return None
    return ("pandas", list(data.columns), data["date"].to_numpy())


def _cap_take() -> bool:
    """Merker "dieser Lauf wird Vorlage" lesen und löschen (``_simulation_flat`` am Anfang)."""
    if not (_StudyCache.on and _StudyCache.cap):
        return False
    _StudyCache.cap = False
    return True


def _probe(phases):
    """Phasen 1 und 2 still rechnen: ihr Ergebnis, wenn sie ohne Hinweis, Warnung, Ausgabe und Fehler blieben, sonst
    None (dann rechnet ``_simulation_flat`` sie noch einmal mit allen Meldungen)."""
    err, out = io.StringIO(), io.StringIO()
    try:
        with warnings.catch_warnings(record=True) as wl:
            warnings.simplefilter("always")
            with contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
                got = phases()
    except Exception:  # noqa: BLE001
        return None
    if wl or err.getvalue() or out.getvalue():
        return None
    return got


def _sim_copy(sim: dict) -> dict:
    """Zustand vor der Engine je Lauf neu (die Engine schreibt Report, Status, Trades, Kurse nach Splits, Töpfe)."""
    return {k: ({a: (dict(x) if isinstance(x, dict) else x) for a, x in v.items()} if isinstance(v, dict) else v)
            for k, v in sim.items()}


def _env_copy(env):
    if env is None:
        return None
    e = copy.copy(env)
    e.rows = list(env.rows)
    e.ks = dict(env.ks)
    return e


def _capture(data, cfg, prep, sim, fl, fr, ei, details, base_rate_flex, base_rate_data, event_weight):
    """Vorlage aus einem Lauf von ``simulation()`` (vor der Tagesengine): setzt ``_StudyCache.cap_out``; Rückgabe
    ``_sim_eval_static`` für die Auswertung dieses Laufs."""
    from ._sim_evaluate import _sim_eval_static
    es = _sim_eval_static(fl, cfg, fr, prep["start_date"], prep["stopp_date"])
    shp = _shape(data)
    if details or cfg.get("no_split") or es["rf_err"] is not None or shp is None:
        return es
    names = shp[1]
    st = cfg["strategy"]
    nm = list(fl["flag_assets"])
    sb, ss = [], []
    for a in nm:
        for f, lst in (("signal_buy", sb), ("signal_sell", ss)):
            c = st[a].get(f)
            if c is not None and (not isinstance(c, str) or c not in names):
                return es
            lst.append(c)
    sig = []
    for c in sb + ss:
        if c is not None and c not in sig:
            sig.append(c)
    swap = nm + [c for c in sig if c not in nm]
    rf = cfg.get("risk_free")
    fixed = [rf] if isinstance(rf, str) else []
    if base_rate_flex and isinstance(base_rate_data, str):
        fixed.append(base_rate_data)
    if cfg.get("event_col") is not None:
        fixed.append(cfg["event_col"])
        if event_weight is not None:
            ewv = list(event_weight.values()) if isinstance(event_weight, Mapping) else [p[1] for p in event_weight]
            fixed += [c for c in ewv if isinstance(c, str)]
    fixed = [c for c in dict.fromkeys(fixed) if c in names]
    if any(c in swap for c in fixed):
        return es
    kinds = fr.kinds
    if any(kinds.get(a) != "numeric" for a in nm) or any(kinds.get(c) not in ("numeric", "logical") for c in sig):
        return es
    _StudyCache.cap_out = {
        "shape": shp[0], "cols": names, "date": shp[2].copy(), "fixed": [(c, _colof(data, c)) for c in fixed],
        "price": nm, "sig": [(c, kinds[c]) for c in sig], "sb": sb, "ss": ss, "src": prep.get("fill_src"),
        "args": list(ei["args"]), "ei": ei, "sim": _sim_copy(sim), "fl": dict(fl), "cfg": dict(cfg),
        "env0": _env_copy(cfg.get("tariff_env")), "ev": es["ev"]}
    return es


def _prep_run(P: dict, data):
    """Lauf mit einer Vorlage: nur Kurse und Signale aus data; None (Kurse/Signale passen nicht) bzw. _UNSTABLE
    (Spalten, Datum oder übrige Spalten anders), dann rechnet ``simulation()``."""
    from ._sim_engine import _REP_KEYS, _engine_reports, _signal, _sim_engine_finish
    from ._sim_evaluate import _sim_compact_trades, _sim_eval_finish, _sim_result
    from ._sim_phases import _fill_column
    shp = _shape(data)
    if shp is None or shp[0] != P["shape"] or shp[1] != P["cols"]:
        return _UNSTABLE
    raw = shp[2]
    if raw.dtype != P["date"].dtype or raw.shape != P["date"].shape or not np.array_equal(raw, P["date"]):
        return _UNSTABLE
    for c, col in P["fixed"]:
        if not _col_same(_colof(data, c), col):
            return _UNSTABLE
    # Kurse und Signale, die die Prüfungen von simulation() still bestehen (_sim_check_inputs, chk_col_signal)
    cols = {}
    for a in P["price"]:
        k, v = _colof(data, a)
        if k != "numeric" or v.size == 0 or np.isnan(v).any():
            return None
        lo, hi = float(v.min()), float(v.max())
        if not (math.isfinite(lo) and math.isfinite(hi) and lo >= 1e-100 and hi <= 1e100):
            return None
        cols[a] = (k, v)
    for c, kind in P["sig"]:
        k, v = _colof(data, c)
        if k != kind:
            return None
        if k == "numeric" and not bool(np.all(np.isnan(v) | (v == 0) | (v == 1))):
            return None
        cols[c] = (k, v)
    src = P["src"]
    if src is not None:   # wie _sim_prepare_data: Spalten auf das Kalenderraster
        have = src >= 0
        cols = {c: (k, _fill_column(src, have, v, k)) for c, (k, v) in cols.items()}
    ei = P["ei"]
    prices, sb, ss = [], [], []
    for j, a in enumerate(P["price"]):
        prices.append(np.ascontiguousarray(np.array(cols[a][1], dtype=np.float64), dtype=np.float64))
        for c, lst, pos in ((P["sb"][j], sb, 0), (P["ss"][j], ss, 1)):
            if c is None:
                lst.append(None)
                continue
            k, v = cols[c]
            w, lg = _signal(np.array(v, dtype=np.float64) if k == "numeric" else np.array(v, dtype=object))
            if lg != ei["sig_logical"][j][pos]:
                return None
            lst.append(w)
    args = list(P["args"])
    args[2], args[3], args[4] = prices, sb, ss
    reports = _engine_reports(ei)
    sim = _sim_copy(P["sim"])
    fl = dict(P["fl"])
    cfg = dict(P["cfg"])
    env = _env_copy(P["env0"])
    if env is not None:
        cfg["tariff_env"] = env
    _FEE.paid = 0.0   # wie _sim_check_inputs vor der Engine
    with np.errstate(all="ignore"):
        eo, vo = _ext.sim_run_prepared(tuple(args) + ([r[k] for r in reports for k in _REP_KEYS],), P["ev"])
        sim, tax_unpaid = _sim_engine_finish(eo, sim, fl, ei, reports, env if ei["person"] else None)
        trades = _sim_compact_trades(sim, fl["flag_assets"])
        ev = _sim_eval_finish(vo, fl["flag_assets"], None)
        return _sim_result(sim, trades, fl, cfg, ev["r"], ev["rs"], ev["um"])


def _find(lst: list, strategy, args):
    for i, e in enumerate(lst):
        if _same(e[0], strategy) and _same(e[1], args):
            return i
    return -1


def _key(strategy, args):
    """Schlüssel als Abzug des Inhalts (deepcopy): Aufrufer dürfen Argumente oder Bausteine danach an Ort und Stelle
    ändern, ohne dass ein gemerkter Schlüssel mitwandert; ohne Abzug (nicht kopierbar) None."""
    try:
        return copy.deepcopy(strategy), copy.deepcopy(args)
    except Exception:  # noqa: BLE001
        return None


def _push(lst: list, e) -> None:
    if e is None or e[0] is None:
        return
    lst.append(e)
    if len(lst) > _MAX:
        del lst[0]


def _sim_call_study(data, strategy, args: dict):
    """``simulation()`` in einer Studie: Vorlage nutzen, sonst vollständig rechnen (ab dem zweiten Aufruf mit
    derselben Strategie und denselben Argumenten als Vorlage merken)."""
    from .engine import simulation
    C = _StudyCache
    i = _find(C.prep, strategy, args)
    if i >= 0:
        P = C.prep[i][2]
        r = _prep_run(P, data)
        if r is _UNSTABLE:
            del C.prep[i]
            _push(C.never, _key(strategy, args))
        elif r is not None:
            return r
        return simulation(data, strategy, **args)
    if _find(C.never, strategy, args) >= 0:
        return simulation(data, strategy, **args)
    j = _find(C.seen, strategy, args)
    if j < 0:
        k = _key(strategy, args)
        if k is None:
            return simulation(data, strategy, **args)
        _push(C.seen, k)
        return simulation(data, strategy, **args)
    del C.seen[j]
    C.cap, C.cap_out = True, None
    try:
        res = simulation(data, strategy, **args)
        P = C.cap_out
    finally:
        C.cap, C.cap_out = False, None
    k = _key(strategy, args) if P is not None and C.on else None
    if k is not None:
        _push(C.prep, (k[0], k[1], P))
    return res
