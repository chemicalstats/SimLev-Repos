"""Parametersuche über Strategie- und Simulationsräume (R: ``param_search.R``).

- :func:`param_space` / :func:`param_range`   Suchraum (diskret oder kontinuierlich)
- :func:`param_search`                       Raster, Zufallssuche oder Latin Hypercube;
                                             ruft ``simulation()`` je Punkt auf, speichert
                                             Kennzahlen und tägliche TWR-Renditen
- :func:`plateau`                            Nachbarschafts-Glättung der Zielgröße

Die gespeicherten Renditen sind die Grundlage für ``pbo()``,
``deflated_sharpe()`` und ``walk_forward()`` (Modul ``overfitting``).
Strategien werden über eine ``builder``-Funktion beschrieben, die aus einem
Parametersatz dieselbe Spezifikation liefert wie ein Element von
``bootstrap_study(strategies = ...)``: ``dict(strategy, signal, args, map, data)``.
"""
from __future__ import annotations

import contextlib
import importlib
import io
import math
import time
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

from ._r import fmt as _fmt
from ._r import libm as _libm
from ._r.rlist import RList
from ._r.rnum import r_mean

__all__ = ["param_space", "param_range", "param_search", "plateau",
           "SimLevParamSpace", "SimLevParamRange", "SimLevParamSearch", "SummarySimLevParamSearch"]

_NAN = _fmt.NA_REAL   # R's NA_real_ (alle Verwendungen hier sind NA)
_DBL_EPS = 2.220446049250313e-16


def _ext(mod, name):
    m = importlib.import_module("simlev." + mod)
    return getattr(m, name)


def _match_arg(value, choices, argname="arg"):
    from .config import _match_arg as ma
    return ma(value, choices, argname)


# ─────────────────────────────────────────────────────────────────────────────
# Kleine R-Hilfen
# ─────────────────────────────────────────────────────────────────────────────

def _isna(v):
    if v is None:
        return True
    if isinstance(v, float) and math.isnan(v):
        return True
    if isinstance(v, np.floating) and np.isnan(v):
        return True
    return v is pd.NA or v is pd.NaT


def _py(v):
    """numpy-Skalar → Python-Skalar."""
    if isinstance(v, np.generic):
        return v.item()
    return v


def _is_numeric_scalar(v):
    return isinstance(v, (int, float, np.integer, np.floating)) and not isinstance(v, (bool, np.bool_))


def _order(v, decreasing=False, na_last=True):
    """``order(v, decreasing, na.last)`` (stabil wie R's Radix-Sortierung); 0-basiert.

    ``na_last``: True = NA ans Ende, False = an den Anfang, None = NA entfernen."""
    from ._r.stats import order
    a = np.asarray(v)
    if a.dtype == object and all(isinstance(x, (int, float, np.integer, np.floating)) or x is None for x in a.tolist()):
        a = np.array([_NAN if x is None else float(x) for x in a.tolist()], dtype=np.float64)
    return np.asarray(order(a, na_last=na_last, decreasing=decreasing), dtype=np.int64) - 1


def _modify_list(x, val):
    """``utils::modifyList(x, val)``: rekursiv für dicts, ``None`` entfernt."""
    out = dict(x)
    for k, v in dict(val).items():
        if k == "":
            continue
        if k in out and isinstance(out[k], Mapping) and not isinstance(out[k], pd.DataFrame) \
                and isinstance(v, Mapping) and not isinstance(v, pd.DataFrame):
            out[k] = _modify_list(out[k], v)
        elif v is None:
            out.pop(k, None)
        else:
            out[k] = v
    return out


def _seq_by(frm, to, by):
    """``seq(from, to, by = by)`` für Doubles (seq.default)."""
    frm = float(frm)
    to = float(to)
    by = float(by)
    dl = to - frm
    if dl == 0 and to == 0:
        return np.array([to])
    finite = math.isfinite(dl)
    n = dl / by if finite else to / by - frm / by
    if not math.isfinite(n):
        if not math.isnan(by) and by == 0 and dl == 0:
            return np.array([frm])
        raise ValueError("invalid '(to - from)/by'")
    if n < 0:
        raise ValueError("wrong sign in 'by' argument")
    if n > 2147483647:
        raise ValueError("'by' argument is much too small")
    if finite and abs(dl) / max(abs(to), abs(frm)) < 100 * _DBL_EPS:
        return np.array([frm])
    n = int(n + 1e-10)
    k = np.arange(n + 1, dtype=np.float64)
    x = frm + k * by if finite else (frm / 4 + k * (by / 4)) * 4
    return np.minimum(x, to) if by > 0 else np.maximum(x, to)


def _seq_len_out(frm, to, length_out):
    """``seq(from, to, length.out = n)`` für Doubles (seq.default)."""
    from ._r.stats import seq_len_out
    return np.asarray(seq_len_out(frm, to, int(math.ceil(length_out))), dtype=np.float64)


def _r_round_vec(v):
    from ._r.fmt import r_round
    return np.array([float(r_round(float(x))) for x in np.asarray(v, dtype=np.float64)], dtype=np.float64)


def _unique(v):
    """``unique(v)`` mit Reihenfolge des ersten Auftretens."""
    a = np.asarray(v)
    seen = []
    keep = []
    for i, x in enumerate(a.tolist()):
        key = ("NaN",) if isinstance(x, float) and math.isnan(x) else (x,)
        if key in seen:
            continue
        seen.append(key)
        keep.append(i)
    return a[keep]


def _as_atomic(v):
    """Python-Wert einer diskreten Dimension → numpy-Vektor (None, falls nicht atomar)."""
    if isinstance(v, pd.Series):
        return v.to_numpy()
    if isinstance(v, np.ndarray):
        return v.ravel() if v.ndim <= 1 else None
    if isinstance(v, (list, tuple)):
        if any(isinstance(e, (list, tuple, dict, np.ndarray, pd.Series, pd.DataFrame)) for e in v):
            return None
        if all(isinstance(e, str) or e is None for e in v):
            return np.array(v, dtype=object)
        if all(isinstance(e, (bool, np.bool_)) for e in v):
            return np.array(v, dtype=bool)
        if all(_is_numeric_scalar(e) or e is None for e in v):
            if all(isinstance(e, (int, np.integer)) for e in v):
                return np.array(v, dtype=np.int64)
            return np.array([_NAN if e is None else float(e) for e in v], dtype=np.float64)
        return np.array(v, dtype=object)
    if isinstance(v, (str, bool, int, float, np.generic)):
        return _as_atomic([_py(v)])
    return None


def _expand_grid(cols):
    """``expand.grid(cols, stringsAsFactors = FALSE)`` (erste Spalte läuft am schnellsten)."""
    names = list(cols.keys())
    vals = [np.asarray(cols[k]) for k in names]
    d = [len(v) for v in vals]
    total = int(np.prod(d)) if d else 0
    out = {}
    rep_fac = 1
    orep = total
    for k, v in zip(names, vals):
        nx = len(v)
        if total == 0:
            out[k] = v[:0]
            continue
        orep = orep // nx
        idx = np.tile(np.repeat(np.arange(nx), rep_fac), orep)
        out[k] = v[idx]
        rep_fac *= nx
    return pd.DataFrame(out, columns=names)


def _row_params(D, i, params=None):
    """Zeile ``i`` (0-basiert) eines data.frame als dict mit Python-Skalaren (``as.list(D[i, ])``)."""
    cols = list(D.columns) if params is None else list(params)
    out = {}
    for c in cols:
        v = D[c].iloc[i]
        if isinstance(v, (list, tuple, np.ndarray)):
            out[c] = v
        else:
            v = _py(v)
            if isinstance(v, float) and math.isnan(v) and D[c].dtype == object:
                v = None
            out[c] = v
    return out


def _quiet(fn):
    """``suppressWarnings(suppressMessages(fn()))``."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        with contextlib.redirect_stderr(io.StringIO()):
            return fn()


def _cond_msg(e):
    """``conditionMessage(e)``."""
    if isinstance(e, KeyError) and e.args:
        return str(e.args[0])
    return str(e)


# ─────────────────────────────────────────────────────────────────────────────
# Suchraum
# ─────────────────────────────────────────────────────────────────────────────

class SimLevParamRange(RList):
    """Stetiger Bereich einer Dimension (R-Klasse ``SimLevParamRange``)."""

    r_class = ("SimLevParamRange",)

    def format(self):
        return "<SimLevParamRange [%s, %s]>" % (self["lower"], self["upper"])


class SimLevParamSpace(RList):
    """Suchraum für :func:`param_search` (R-Klasse ``SimLevParamSpace``)."""

    r_class = ("SimLevParamSpace",)

    def format(self):
        out = ["SimLev-Parameterraum"]
        for k, d in self.items():
            if isinstance(d, SimLevParamRange):
                rast = ("Schritt " + _fmt.paste(d["step"])) if d["step"] is not None else ("%d Punkte" % d["n"])
                out.append(_fmt.sprintf("  %-14s Bereich [%g, %g]%s%s, Raster %s", k, float(d["lower"]), float(d["upper"]),
                                        " ganzzahlig" if d["integer"] else "", " log" if d["log"] else "", rast))
            else:
                f = [str(s) for s in np.atleast_1d(_fmt.format(d))]
                out.append(_fmt.sprintf("  %-14s %s", k, ", ".join(f[:12])))
        return "\n".join(out)

    def print(self):
        print(self.format())
        return self


def param_space(*args, **dims):
    """Suchraum für :func:`param_search`.

    Je Parameter eine benannte Dimension mit diskreten Werten (Liste/Vektor)
    oder einem stetigen Bereich aus :func:`param_range`. Bei ``method = "grid"``
    werden alle Kombinationen der Rasterwerte ausgewertet; bei ``"random"`` und
    ``"lhs"`` werden diskrete Werte gleichverteilt ausgewählt und Bereiche
    stetig zwischen ``lower`` und ``upper`` gezogen.

    Args:
        **dims: benannte Dimensionen (Vektor diskreter Werte oder ``param_range()``).

    Returns:
        :class:`SimLevParamSpace`.
    """
    if args or not dims:
        raise ValueError("param_space: alle Dimensionen müssen benannt sein.")
    out = SimLevParamSpace()
    for k, v in dims.items():
        if k == "":
            raise ValueError("param_space: alle Dimensionen müssen benannt sein.")
    for k, v in dims.items():
        if isinstance(v, SimLevParamRange):
            out[k] = v
            continue
        a = _as_atomic(v)
        if a is None or not len(a):
            raise ValueError("param_space: Dimension '%s' muss ein Vektor oder param_range() sein." % k)
        out[k] = a
    return out


def _fmt_any(v):
    return ", ".join(str(s) for s in np.atleast_1d(_fmt.format(v)))


def param_range(lower, upper, n=5, step=None, integer=False, log=False):
    """Stetiger Bereich einer Dimension für :func:`param_space`.

    Args:
        lower, upper: Bereichsgrenzen (``lower <= upper``; bei ``log = True`` ``lower > 0``).
        n: Anzahl Rasterpunkte bei ``method = "grid"`` (ganze Zahl >= 1, Standard 5).
        step: Schrittweite des Rasters (hat Vorrang vor ``n`` und ``log``).
        integer: Raster- und Zufallswerte auf ganze Zahlen runden.
        log: Raster gleichabständig auf der Log-Skala, Ziehung log-gleichverteilt.

    Returns:
        :class:`SimLevParamRange`.
    """
    if not _is_numeric_scalar(lower) or not _is_numeric_scalar(upper) or upper < lower:
        raise ValueError("param_range: lower <= upper erforderlich.")
    if log and lower <= 0:
        raise ValueError("param_range: log = TRUE erfordert lower > 0.")
    if step is None and (not _is_numeric_scalar(n) or not math.isfinite(n) or n < 1 or n != _r_round_vec([n])[0]):
        raise ValueError("param_range: n (Anzahl Rasterpunkte) muss eine ganze Zahl >= 1 sein (erhalten: %s)." % _fmt_any(n))
    if step is not None and (not _is_numeric_scalar(step) or not math.isfinite(step) or step <= 0):
        raise ValueError("param_range: step muss eine Zahl > 0 sein (erhalten: %s)." % _fmt_any(step))
    return SimLevParamRange(lower=_py(lower), upper=_py(upper), n=int(n), step=None if step is None else _py(step),
                            integer=bool(integer), log=bool(log))


def _ps_levels(d):
    """Rasterwerte einer Dimension."""
    if not isinstance(d, SimLevParamRange):
        return d
    if d["step"] is not None:
        v = _seq_by(d["lower"], d["upper"], d["step"])
    elif d["log"]:
        v = _libm.exp(_seq_len_out(_libm.log(float(d["lower"])), _libm.log(float(d["upper"])), d["n"]))
        v = np.atleast_1d(np.asarray(v, dtype=np.float64))
    else:
        v = _seq_len_out(d["lower"], d["upper"], d["n"])
    if d["integer"]:
        v = _r_round_vec(v)
    return _unique(v)


def _ps_map(d, u):
    """Werte einer Dimension aus gleichverteilten u in (0, 1) abbilden."""
    u = np.asarray(u, dtype=np.float64)
    if not isinstance(d, SimLevParamRange):
        L = len(d)
        k = np.minimum(L, np.floor(u * L) + 1).astype(np.int64) - 1
        return np.asarray(d)[k]
    lo = float(d["lower"])
    hi = float(d["upper"])
    if d["log"]:
        ll = _libm.log(lo)
        v = np.asarray(_libm.exp(ll + u * (_libm.log(hi) - ll)), dtype=np.float64)
    else:
        v = lo + u * (hi - lo)
    if d["integer"]:
        v = _r_round_vec(v)
    return v


def _ok_rows(D, constraint):
    if constraint is None:
        return np.ones(len(D), dtype=bool)
    return np.array([_is_true(constraint(_row_params(D, i))) for i in range(len(D))], dtype=bool)


def _is_true(v):
    """``isTRUE(v)``."""
    if isinstance(v, (bool, np.bool_)):
        return bool(v)
    if isinstance(v, (np.ndarray, list, tuple, pd.Series)):
        a = np.asarray(v)
        return a.size == 1 and a.dtype == bool and bool(a.ravel()[0])
    return False


def _row_key(D, i):
    out = []
    for c in D.columns:
        x = _py(D[c].iloc[i])
        out.append(("NaN",) if isinstance(x, float) and math.isnan(x) else x)
    return tuple(out)


def _ps_design(space, method, n, constraint):
    """Versuchsplan erzeugen."""
    from ._r import rng
    names = list(space.keys())
    if method == "grid":
        D = _expand_grid({k: _ps_levels(space[k]) for k in names})
        D = D[_ok_rows(D, constraint)]
    else:
        D = None
        tries = 0
        while (D is None or len(D) < n) and tries < 20:
            m = n if D is None else max(n, 2 * (n - len(D)))
            m = int(m)
            U = np.empty((m, len(names)))
            for j in range(len(names)):
                if method == "lhs":
                    s = np.asarray(rng.sample_int(m), dtype=np.float64)
                    U[:, j] = (s - np.asarray(rng.runif(m), dtype=np.float64)) / m
                else:
                    U[:, j] = np.asarray(rng.runif(m), dtype=np.float64)
            Dn = pd.DataFrame({k: _ps_map(space[k], U[:, j]) for j, k in enumerate(names)}, columns=names)
            Dn = Dn[_ok_rows(Dn, constraint)]
            Dc = Dn if D is None else pd.concat([D, Dn], ignore_index=True)
            seen = set()
            keep = []
            for i in range(len(Dc)):
                key = _row_key(Dc, i)
                keep.append(key not in seen)
                seen.add(key)
            D = Dc[np.array(keep, dtype=bool)].reset_index(drop=True) if len(Dc) else Dc
            tries += 1
        D = D.iloc[:int(n)] if n >= 0 else D.iloc[:max(len(D) + int(n), 0)]
    if not len(D):
        raise ValueError("param_search: kein zulässiger Punkt im Suchraum (constraint prüfen).")
    return D.reset_index(drop=True)


# ─────────────────────────────────────────────────────────────────────────────
# Spezifikation auswerten
# ─────────────────────────────────────────────────────────────────────────────

def _is_strategy(s):
    try:
        from .config import Strategy
    except ImportError:          # pragma: no cover
        return False
    return isinstance(s, Strategy)


def _as_spec(s):
    """Builder-Ergebnis in eine Spezifikation umwandeln (``.as_spec``)."""
    if isinstance(s, Mapping) and not _is_strategy(s) and s.get("strategy") is not None:
        return s
    return {"strategy": s}


def _logical_fill(v):
    """Logischen Vektor mit NA → FALSE (andere Typen unverändert)."""
    if isinstance(v, pd.Series):
        v = v.to_numpy()
    a = np.asarray(v) if isinstance(v, (list, tuple, np.ndarray)) else v
    if isinstance(a, np.ndarray):
        if a.dtype == bool:
            return a
        if a.dtype == object and all(x is None or isinstance(x, (bool, np.bool_)) or x is pd.NA for x in a.tolist()):
            if all(x is None or x is pd.NA for x in a.tolist()) and len(a):
                return np.zeros(len(a), dtype=bool)
            return np.array([bool(x) if not (x is None or x is pd.NA) else False for x in a.tolist()], dtype=bool)
    return v


def _run_spec(df, sp, sim_args, burn_in):
    """Eine Strategie-Spezifikation auf einem data.frame auswerten (``.run_spec``)."""
    df = df.copy() if isinstance(df, pd.DataFrame) else pd.DataFrame(df)
    if sp.get("signal") is not None:
        sg = sp["signal"](df)
        if isinstance(sg, pd.DataFrame):
            df = sg
        else:
            for k in list(sg.keys()):
                df[k] = _logical_fill(sg[k])
    if sp.get("data") is not None:
        df = sp["data"](df)
    if sp.get("map") is not None:
        for a, src in dict(sp["map"]).items():
            df[a] = df[src]
    if burn_in > 0:
        df = df.iloc[int(burn_in):].reset_index(drop=True)
    args = _modify_list(sim_args, sp.get("args") or {})
    simulation = _ext("engine", "simulation")
    return _quiet(lambda: simulation(data=df, strategy=sp["strategy"], **args))


# ─────────────────────────────────────────────────────────────────────────────
# Parametersuche
# ─────────────────────────────────────────────────────────────────────────────

class SimLevParamSearch(RList):
    """Ergebnis von :func:`param_search` (R-Klasse ``SimLevParamSearch``)."""

    r_class = ("SimLevParamSearch",)

    def summary(self, top=10):
        return _summary_param_search(self, top=top)

    def format(self):
        return self.summary().format()

    def print(self, **kwargs):
        print(self.summary(**kwargs).format())
        return self

    def plot(self, metric=None, params=None, fun=max, **kwargs):
        return _plot_param_search(self, metric=metric, params=params, fun=fun, **kwargs)


def param_search(data, builder=None, space=None, strategy=None, method=("grid", "random", "lhs"), n=50,
                 constraint=None, sim_args=None, burn_in=0, metrics=None, objective="sharpe", maximize=True,
                 cores=1, seed=None, keep_returns=True):
    """Parametersuche über Strategie- und Simulationsparameter.

    Wertet eine Strategie für jeden Punkt eines Parameterraums mit
    ``simulation()`` aus. Neben den Kennzahlen werden die täglichen
    zeitgewichteten Renditen jedes Punkts gespeichert (Grundlage für
    ``pbo()``, ``deflated_sharpe()``, ``walk_forward()``).

    Je Punkt: ``signal(df)`` auf dem vollen Datensatz, dann ``data(df)``, dann
    ``map``, dann Verwerfen der ersten ``burn_in`` Zeilen, schließlich
    ``simulation()`` mit ``sim_args``, überschrieben durch ``args``. Fehler
    einzelner Punkte stehen in ``results["error"]``.

    Args:
        data: data.frame wie in ``simulation()`` (inklusive Signal-Vorlauf).
        builder: ``function(p)`` → Strategie oder dict ``(strategy, signal, args,
            map, data)``; ``None`` = Parameter als ``simulation()``-Argumente für ``strategy``.
        space: Suchraum aus :func:`param_space` (oder dict).
        strategy: feste Strategie, wenn ``builder`` fehlt.
        method: ``"grid"`` (Standard), ``"random"`` oder ``"lhs"``.
        n: Anzahl Punkte bei ``"random"``/``"lhs"`` (Standard 50).
        constraint: optional ``function(p)`` → ``True`` für zulässige Punkte.
        sim_args: gemeinsame Argumente für ``simulation()``.
        burn_in: Anzahl verworfener Zeilen am Anfang (Standard 0).
        metrics: Funktion ``SimLevResult`` → benannter Vektor (Standard ``study_metrics``).
        objective: Name der Zielgröße (Standard ``"sharpe"``).
        maximize: Zielgröße maximieren (Standard ``True``).
        cores: Anzahl Prozesse (Standard 1).
        seed: Startwert für den Versuchsplan (Zufallszustand danach wiederhergestellt).
        keep_returns: tägliche Renditen speichern (Standard ``True``).

    Returns:
        :class:`SimLevParamSearch`.
    """
    method = _match_arg(method, ("grid", "random", "lhs"), "method")
    sim_args = {} if sim_args is None else dict(sim_args)
    if metrics is None:
        metrics = _ext("bootstrap", "study_metrics")
    if not isinstance(space, SimLevParamSpace):
        space = param_space(**dict(space))
    if builder is None:
        if strategy is None:
            raise ValueError("param_search: 'builder' oder 'strategy' angeben.")
        fixed = strategy

        def builder(p):
            return {"strategy": fixed, "args": p}
    with_rng = _ext("bootstrap", "_with_rng_restore")
    design = with_rng(lambda: _ps_design(space, method, n, constraint), seed=seed)
    t0 = time.perf_counter()

    def run(i):
        p = _row_params(design, i)
        try:
            res = _run_spec(data, _as_spec(builder(p)), sim_args, burn_in)
        except Exception as e:  # noqa: BLE001 - tryCatch(error = ...)
            return {"m": None, "err": _cond_msg(e)}
        try:
            m = metrics(res)
        except Exception:  # noqa: BLE001
            m = None
        if m is None:
            return {"m": None, "err": "metrics() fehlgeschlagen"}
        if not isinstance(m, pd.Series):
            m = pd.Series(dict(m)) if isinstance(m, Mapping) else pd.Series(m)
        out = {"m": m, "err": None, "date": None, "ret": None}
        if keep_returns:
            ix = _ext("withdrawal", "result_index")(res)
            v = ix["value"].to_numpy(dtype=np.float64)
            out["date"] = np.asarray(ix["date"]).astype("datetime64[D]")
            out["ret"] = v[1:] / v[:-1] - 1
        return out
    par_lapply = _ext("bootstrap", "_par_lapply")
    out = list(par_lapply(list(range(len(design))), run, cores))
    okm = [o for o in out if o["m"] is not None]
    if not okm:
        raise ValueError("param_search: alle Punkte fehlgeschlagen, z. B.: %s" % out[0]["err"])
    mnames = [str(k) for k in okm[0]["m"].index]
    if objective not in mnames:
        raise ValueError("objective '%s' nicht in metrics(): %s" % (objective, ", ".join(mnames)))
    M = np.array([[_NAN] * len(mnames) if o["m"] is None else _metric_values(o["m"], mnames) for o in out],
                 dtype=np.float64).reshape(len(out), len(mnames))
    cols = {"id": np.arange(1, len(design) + 1, dtype=np.int64)}
    for c in design.columns:
        cols[c] = design[c].to_numpy()
    for j, c in enumerate(mnames):
        cols[c] = M[:, j]
    cols["error"] = np.array([o["err"] for o in out], dtype=object)
    tab = pd.DataFrame(cols)
    R = dates = None
    if keep_returns:
        ref = okm[0]["date"]
        dates = ref[1:]
        Rm = np.full((len(dates), len(design)), _NAN)
        pos = {int(x): i for i, x in enumerate(dates.astype(np.int64))}
        for i, o in enumerate(out):
            if o.get("ret") is not None:
                dd = o["date"][1:].astype(np.int64)
                for r, dv in enumerate(dd):
                    kk = pos.get(int(dv))
                    if kk is not None:
                        Rm[kk, i] = o["ret"][r]
        R = pd.DataFrame(Rm, columns=["p%d" % (j + 1) for j in range(len(design))])
    return SimLevParamSearch(results=tab, returns=R, dates=dates, space=space, params=list(space.keys()),
                             method=method, objective=objective, maximize=maximize, builder=builder,
                             sim_args=sim_args, burn_in=burn_in, metrics=mnames,
                             elapsed=time.perf_counter() - t0)


def _metric_values(m, mnames):
    out = []
    for k in mnames:
        v = m[k] if k in m.index else _NAN
        out.append(_NAN if v is None else float(v))
    return out


# ─────────────────────────────────────────────────────────────────────────────
# Nachbarschaften und Plateau
# ─────────────────────────────────────────────────────────────────────────────

def _match(x, table):
    """``match(x, table)`` (1-basiert, NA → nan)."""
    tab = [_py(t) for t in np.asarray(table).tolist()]
    out = []
    for v in np.asarray(x).tolist():
        v = _py(v)
        hit = _NAN
        for i, t in enumerate(tab):
            if (_isna(v) and _isna(t)) or (not _isna(v) and not _isna(t) and v == t):
                hit = float(i + 1)
                break
        out.append(hit)
    return np.array(out, dtype=np.float64)


def _rank_avg(x):
    from .overfitting import _rank_avg as ra
    return ra(x)


def _which_max_py(v):
    """``which.max`` (0-basiert, ``None`` wenn leer oder nur NA)."""
    from .overfitting import _which_max
    return _which_max(v)


def _factor_codes(col):
    vals = [_py(v) for v in np.asarray(col).tolist()]
    from ._r._collate import r_key   # Stufen wie factor(): R's Kollation
    lev = sorted(dict.fromkeys(v for v in vals if not _isna(v)), key=r_key)
    pos = {v: i + 1 for i, v in enumerate(lev)}
    return np.array([_NAN if _isna(v) else float(pos[v]) for v in vals], dtype=np.float64)


def _dist_matrix(Z):
    """``as.matrix(stats::dist(Z))`` (euklidisch)."""
    from ._r.stats import dist, dist_as_matrix
    return dist_as_matrix(dist(np.asarray(Z, dtype=np.float64))).to_numpy(dtype=np.float64)


def _ps_neighbours(x, radius=1, k=5):
    """Nachbarschaften im Parameterraum (``.ps_neighbours``): Liste 1-basierter Zeilennummern."""
    P = x["results"][list(x["params"])]
    if x["method"] == "grid":
        L = np.column_stack([_match(P[p].to_numpy(), _ps_levels(x["space"][p])) for p in x["params"]])
        out = []
        for i in range(L.shape[0]):
            with np.errstate(invalid="ignore"):
                ok = np.abs(L - L[i][None, :]) <= radius
            ok = ok & ~np.isnan(L - L[i][None, :])
            out.append(np.nonzero(ok.all(axis=1))[0].astype(np.int64) + 1)
        return out
    zs = []
    for c in P.columns:
        col = P[c].to_numpy()
        num = col.dtype.kind in "iuf"
        r = _rank_avg(col.astype(np.float64) if num else _factor_codes(col))
        if r.max() > r.min():
            zs.append((r - r.min()) / (r.max() - r.min()))
        else:
            zs.append(r * 0)
    nr = len(P)
    if nr == 1:
        Z = np.array([z[0] for z in zs], dtype=np.float64).reshape(-1, 1)   # vapply liefert einen Vektor
    else:
        Z = np.column_stack(zs)
    D = _dist_matrix(Z)
    m = min(k, Z.shape[0])
    return [np.argsort(D[i], kind="stable")[:m].astype(np.int64) + 1 for i in range(Z.shape[0])]


def _lower_better():
    try:
        return list(_ext("bootstrap", "_lower_better"))
    except (ImportError, AttributeError):
        return ["max_drawdown", "avg_drawdown", "dd_q50", "dd_q90", "ulcer_index", "longest_drawdown"]


def plateau(x, metric=None, radius=1, k=5):
    """Plateau-Wert: Zielgröße über die Nachbarschaft eines Punkts.

    Beim Raster sind Nachbarn alle Punkte, die sich in jeder Dimension um
    höchstens ``radius`` Rasterstufen unterscheiden; bei Zufallssuche/LHS die
    ``k`` nächsten Punkte im rangskalierten Raum.

    Args:
        x: ``SimLevParamSearch``.
        metric: Kennzahlspalte von ``x.results`` (Standard: Zielgröße).
        radius: maximaler Abstand in Rasterstufen (Standard 1; nur Raster).
        k: Anzahl Nachbarn inklusive Punkt selbst (Standard 5; nur random/lhs).

    Returns:
        ``pandas.DataFrame`` mit ``id``, ``value``, ``plateau_mean``, ``plateau_min``, ``neighbours``.
    """
    if not isinstance(x, SimLevParamSearch):
        raise ValueError("x muss ein SimLevParamSearch sein.")
    if metric is None:
        metric = x["objective"]
    tab = x["results"]
    v = tab[metric].to_numpy(dtype=np.float64)
    nb = _ps_neighbours(x, radius, k)
    lower_better = (x.get("maximize") is not True) if metric == x["objective"] else metric in _lower_better()

    def worst(a):
        a = a[~np.isnan(a)]
        if not a.size:
            return math.inf if lower_better is False else -math.inf
        return float(a.max()) if lower_better else float(a.min())
    return pd.DataFrame({"id": tab["id"].to_numpy(), "value": v,
                         "plateau_mean": np.array([r_mean(v[j - 1], na_rm=True) for j in nb], dtype=np.float64),
                         "plateau_min": np.array([worst(v[j - 1]) for j in nb], dtype=np.float64),
                         "neighbours": np.array([len(j) for j in nb], dtype=np.int64)})


# ─────────────────────────────────────────────────────────────────────────────
# summary / print / plot
# ─────────────────────────────────────────────────────────────────────────────

class SummarySimLevParamSearch(RList):
    """Ergebnis von ``summary(<SimLevParamSearch>)`` (R-Klasse ``summary.SimLevParamSearch``)."""

    r_class = ("summary.SimLevParamSearch",)

    def format(self):
        x = self
        out = [_fmt.sprintf("SimLev-Parametersuche (%s): %d Punkte, %d fehlgeschlagen, %.1f s\n",
                            x["method"], x["n"], x["n_failed"], float(x["elapsed"]))]
        out.append("Zielgröße: %s\n\n" % x["objective"])
        y = x["top"].copy()
        params = list(x["params"])
        for k in [c for c in ("cagr", "max_drawdown") if c in y.columns]:
            y[k] = _fmt_vec("%.2f %%", 100 * y[k].to_numpy(dtype=np.float64))
        for k in [c for c in y.columns if c not in ["id"] + params + ["cagr", "max_drawdown"]]:
            if y[k].dtype.kind in "iufb" and y[k].dtype.kind != "b":
                y[k] = _fmt_vec("%.3f", y[k].to_numpy(dtype=np.float64))
        out.append(_fmt.print_data_frame(y, row_names=False) + "\n")
        if "cagr" in y.columns or x["objective"] == "cagr":
            out.append("cagr: mit Sparplan geldgewichtet (XIRR), sonst CAGR des Depotwerts\n")

        def fmtp(r):
            return ", ".join("%s = %s" % (p, _fmt_scalar(r[p].iloc[0])) for p in params)
        b = x["best"]
        bp = x["best_plateau"]
        obj = x["objective"]
        out.append(_fmt.sprintf("\nBester Punkt:   #%d (%s), %s = %.3f\n", int(b["id"].iloc[0]), fmtp(b), obj,
                                _num(b[obj].iloc[0])))
        out.append(_fmt.sprintf("Bestes Plateau: #%d (%s), %s = %.3f, Nachbarschaft = %.3f\n", int(bp["id"].iloc[0]),
                                fmtp(bp), obj, _num(bp[obj].iloc[0]), _num(bp["plateau"].iloc[0])))
        return "".join(out)[:-1]

    def print(self):
        print(self.format())
        return self


def _num(v):
    v = _py(v)
    return _NAN if v is None else float(v)


def _fmt_scalar(v):
    v = _py(v)
    if v is None:
        return "NA"
    return str(np.atleast_1d(_fmt.format(np.array([v]) if not isinstance(v, str) else np.array([v], dtype=object)))[0])


def _fmt_vec(f, v):
    out = _fmt.sprintf(f, np.asarray(v, dtype=np.float64))
    if isinstance(out, str):
        out = np.array([out], dtype=object)
    return np.asarray(out, dtype=object)


def _summary_param_search(obj_, top=10):
    tab = obj_["results"].copy()
    obj = obj_["objective"]
    pl = plateau(obj_)
    tab["plateau"] = pl["plateau_mean"].to_numpy()
    mx = obj_.get("maximize") is True
    ordv = _order(tab[obj].to_numpy(dtype=np.float64), decreasing=mx, na_last=True)
    ordp = _order(tab["plateau"].to_numpy(dtype=np.float64), decreasing=mx, na_last=True)
    std = ["cagr", "max_drawdown", "sharpe", "ulcer_index", "trades"]
    cols = ["id"] + list(obj_["params"]) + [c for c in std if c in tab.columns] + ([obj] if obj not in std else []) + ["plateau"]
    topt = tab.iloc[ordv[:int(top)]][cols]
    return SummarySimLevParamSearch(top=topt, best=tab.iloc[[ordv[0]]], best_plateau=tab.iloc[[ordp[0]]],
                                    n=len(tab), n_failed=int(tab["error"].map(lambda e: not _isna(e)).sum())
                                    if "error" in tab.columns else 0,
                                    objective=obj, method=obj_["method"], params=list(obj_["params"]),
                                    elapsed=obj_.get("elapsed"))


def summary(object, top=10, **kwargs):  # noqa: A002 - R-Argumentname
    """``summary()`` einer Parametersuche (:class:`SummarySimLevParamSearch`)."""
    if isinstance(object, SimLevParamSearch):
        return _summary_param_search(object, top=top)
    if hasattr(object, "summary"):
        return object.summary(**kwargs)
    raise TypeError("summary: kein passendes Objekt")


def _plot_param_search(x, metric=None, params=None, fun=max, **kwargs):
    import matplotlib.pyplot as plt
    tab = x["results"]
    metric = metric or x["objective"]
    params = list(params) if params is not None else list(x["params"])[:2]
    if isinstance(params, str):
        params = [params]

    def agg(v):
        v = np.asarray(v, float)
        v = v[np.isfinite(v)]
        return fun(v) if v.size else _NAN
    if len(params) == 1:
        a = tab.groupby(params[0])[metric].agg(agg).reset_index()
        from ._r._collate import r_key   # Gruppen wie aggregate(): R's Kollation
        a = a.iloc[sorted(range(len(a)), key=lambda i: r_key(a[params[0]].iloc[i]))].reset_index(drop=True)
        fig, ax = plt.subplots()
        ax.plot(a[params[0]], a[metric], "o-", color="#2C6E9B")
        ax.set_xlabel(params[0])
        ax.set_ylabel(metric)
        ax.set_title("%s nach %s" % (metric, params[0]))
        ax.grid(color="0.88")
        return a
    if x["method"] != "grid":
        fig, ax = plt.subplots()
        sc = ax.scatter(tab[params[0]], tab[params[1]], c=tab[metric], cmap="RdBu")
        ax.set_xlabel(params[0])
        ax.set_ylabel(params[1])
        ax.set_title("%s (Farbe; blau = hoch)" % metric)
        fig.colorbar(sc)
        return None
    a = tab.groupby([params[0], params[1]])[metric].agg(agg).reset_index()
    from ._r._collate import r_key
    l1 = sorted(a[params[0]].unique(), key=r_key)
    l2 = sorted(a[params[1]].unique(), key=r_key)
    M = np.full((len(l1), len(l2)), _NAN)
    for _, r in a.iterrows():
        M[l1.index(r[params[0]]), l2.index(r[params[1]])] = r[metric]
    fig, ax = plt.subplots()
    ax.imshow(M.T, origin="lower", cmap="RdBu", aspect="auto")
    ax.set_xticks(range(len(l1)), [str(v) for v in l1])
    ax.set_yticks(range(len(l2)), [str(v) for v in l2])
    ax.set_xlabel(params[0])
    ax.set_ylabel(params[1])
    ax.set_title("%s (blau = hoch)" % metric)
    if M.size <= 300:
        sc_ = 100 if metric in ("cagr", "ttwror", "max_drawdown", "avg_drawdown") else 1
        for i in range(len(l1)):
            for j in range(len(l2)):
                if not math.isnan(M[i, j]):
                    ax.text(i, j, ("%.1f" if sc_ == 100 else "%.2f") % (sc_ * M[i, j]), ha="center", va="center", fontsize=7)
    return M


# Rechnen mit NA (signalisierendes NaN) ohne numpy-Warnung "invalid value" wie in R (gemeinsamer Helfer)
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), list(__all__) + ["_as_spec", "_ps_design", "_ps_levels", "_ps_map", "_ps_neighbours"])
