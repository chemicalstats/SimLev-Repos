"""Parametersuche über Strategie- und Simulationsräume (R: ``param_search.R``).

- :func:`param_space` / :func:`param_range`   Suchraum (diskret oder kontinuierlich)
- :func:`param_search`                       Raster, Zufallssuche oder Latin Hypercube;
                                             ruft ``simulation()`` je Punkt auf, speichert
                                             Kennzahlen und tägliche TWR-Renditen
- :func:`param_plateau`                            Nachbarschafts-Glättung der Zielgröße

Die gespeicherten Renditen sind die Grundlage für ``overfit_pbo()``,
``sharpe_deflated()`` und ``overfit_walk_forward()`` (Modul ``overfitting``).
Strategien werden über eine ``builder``-Funktion beschrieben, die aus einem
Parametersatz dieselbe Spezifikation liefert wie ein Element von
``bootstrap_study(strategies = ...)``: ``dict(strategy, signal, args, map, data)``.
"""
from __future__ import annotations

import contextlib
import io
import math
import time
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

from ._sim_base import _study_scope  # Prüf-Cache je Studie (seit 1.5.1)
from .data_prep import _e5_choice  # seit 1.6.4 (K43 T2-N4)
from ._r import fmt as _fmt
from ._r import libm as _libm
from ._r.rlist import RList, _PrintFormat
from ._r.rnum import r_mean
from ._r.parallel import par_lapply as _par_lapply
from .svg import (_res_fig, _res_finish, _res_line, _res_panel, _res_points, _res_pal, _res_range, _res_rect,
                  _res_text, _res_tx, _res_ty, _rint)
from ._util import _match_arg
from ._util import _ext
from ._util import _fmt_vec
from ._util import _MISSING, _is_strategy
from ._util import _cond_msg
from ._util import _rank_avg
from ._pruefen import chk_bool1, chk_cores, chk_int1, chk_max, chk_msg, chk_name1, chk_num1, chk_scalar, chk_stop  # seit 1.6.4
from ._pruefen import SL_MAX_GITTER, SL_MAX_N, chk_kennzahlen  # seit 1.6.4 (Entscheidungen 16, 43 und 46)

__all__ = ["param_space", "param_range", "param_search", "param_plateau",
           "SimLevParamSpace", "SimLevParamRange", "SimLevParamSearch", "SummarySimLevParamSearch"]

_NAN = _fmt.NA_REAL   # R's NA_real_ (alle Verwendungen hier sind NA)
_DBL_EPS = 2.220446049250313e-16


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
    """``unique(v)`` mit Reihenfolge des ersten Auftretens. Seit 1.6.5 (CR2-M-3) über eine Menge (bis 1.6.4 Suche in
    einer Liste, quadratisch); gleiche Schlüssel, gleiche Auswahl."""
    a = np.asarray(v)
    seen = set()
    keep = []
    for i, x in enumerate(a.tolist()):
        key = ("NaN",) if isinstance(x, float) and math.isnan(x) else (x,)
        if key in seen:
            continue
        seen.add(key)
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


# ─────────────────────────────────────────────────────────────────────────────
# Suchraum
# ─────────────────────────────────────────────────────────────────────────────

class SimLevParamRange(RList):
    """Stetiger Bereich einer Dimension (R-Klasse ``SimLevParamRange``)."""

    r_class = ("SimLevParamRange",)

    def format(self):
        # seit 1.6.5 (CR2-W4-3): eine Zeile wie im Parameterraum (bis 1.6.4 "<SimLevParamRange [lo, hi]>")
        return "SimLev-Parameterbereich: " + _ps_range_text(self)


def _ps_range_text(d):
    """Bereichstext im Druck (R ``.ps_range_text``); Zahlen seit 1.6.5 (CR2-W2-3) ohne Exponentenschreibweise."""
    from .config import _fmt15
    rast = ("Schritt " + _fmt15(d["step"])) if d["step"] is not None else ("%d Punkte" % d["n"])
    return "Bereich [%s, %s]%s%s, Raster %s" % (_fmt15(d["lower"]), _fmt15(d["upper"]),
                                                " ganzzahlig" if d["integer"] else "", " log" if d["log"] else "", rast)


def _ps_fmt_num(d):
    """Rasterwerte im Druck (R ``.ps_fmt_num``): Zahlen einzeln ohne Exponentenschreibweise, sonst ``format(d)``."""
    a = np.asarray(d)
    if a.dtype.kind in "iuf" and a.size and bool(np.all(np.isfinite(a.astype(np.float64)))):
        from .config import _fmt15
        return [_fmt15(x) for x in a.tolist()]
    return [str(t) for t in np.atleast_1d(_fmt.format(d))]


class SimLevParamSpace(RList, _PrintFormat):
    """Suchraum für :func:`param_search` (R-Klasse ``SimLevParamSpace``)."""

    r_class = ("SimLevParamSpace",)

    def format(self):
        out = ["SimLev-Parameterraum"]
        for k, d in self.items():
            # seit 1.6.5 (CR2-W2-3): Grenzen und Zahlen einzeln ohne Exponentenschreibweise (bis 1.6.4 %g bzw.
            # format(d) gemeinsam)
            if isinstance(d, SimLevParamRange):
                out.append(_fmt.sprintf("  %-14s %s", k, _ps_range_text(d)))
            else:
                out.append(_fmt.sprintf("  %-14s %s", k, ", ".join(_ps_fmt_num(d)[:12])))
        return "\n".join(out)


def param_space(*args, **dims):
    """Suchraum für :func:`param_search`.

    ``param_space()`` beschreibt den Suchraum für ``param_search()``: je Parameter eine benannte Dimension mit
    diskreten Werten oder einem stetigen Bereich aus ``param_range()``. Bei ``method = "grid"`` werden alle
    Kombinationen der Rasterwerte ausgewertet; bei ``"random"`` und ``"lhs"`` werden diskrete Werte gleichverteilt
    ausgewählt und Bereiche stetig zwischen ``lower`` und ``upper`` gezogen (``n`` und ``step`` spielen dann keine
    Rolle).

    Args:
        *args: Benannte Dimensionen (alle Namen Pflicht; sie werden zu den Namen der Liste ``p`` im ``builder``,
            ohne ``builder`` zu Argumentnamen von ``simulation()`` bzw. Pfaden zu Parametern der Bausteine wie
            ``dca.value`` oder ``rebalance.thresh``). Jede ist entweder ein nicht leerer atomarer Vektor diskreter
            Werte (numerisch, Zeichen, logisch) oder ein Bereich aus ``param_range()``. Bei ``print()`` ungenutzt.
            Seit 1.6.5 sind doppelte Namen und Datumswerte ein Fehler.
        **dims: Benannte Dimensionen (alle Namen Pflicht; sie werden zu den Namen der Liste ``p`` im ``builder``,
            ohne ``builder`` zu Argumentnamen von ``simulation()`` bzw. Pfaden zu Parametern der Bausteine wie
            ``dca.value`` oder ``rebalance.thresh``). Jede ist entweder ein nicht leerer atomarer Vektor diskreter
            Werte (numerisch, Zeichen, logisch) oder ein Bereich aus ``param_range()``. Bei ``print()`` ungenutzt.
            Seit 1.6.5 sind doppelte Namen und Datumswerte ein Fehler.

    Returns:
        ``param_space``: Objekt der Klasse ``SimLevParamSpace`` (benannte Liste der Dimensionen); ``param_range``:
        Objekt der Klasse ``SimLevParamRange`` (Liste mit ``lower``, ``upper``, ``n``, ``step``, ``integer``,
        ``log``).

    Beispiel::

        import simlev
        print(simlev.param_space(n=[50, 100, 200], w=simlev.param_range(0.3, 0.9, step=0.1)))
    """
    if args or not dims:
        chk_stop("b2b.m_param_space")
    out = SimLevParamSpace()
    for k, v in dims.items():
        if k == "":
            chk_stop("b2b.m_param_space")
    for k, v in dims.items():
        if isinstance(v, SimLevParamRange):
            out[k] = v
            continue
        if isinstance(v, pd.Categorical) or (isinstance(v, pd.Series) and isinstance(v.dtype, pd.CategoricalDtype)):
            continue   # R: Faktor ist atomar; Meldung unten (Entscheidung 15)
        # seit 1.6.5 (CR2-W2-4, Entscheidung 189): Datum als Rasterwert abgelehnt wie in R und Julia
        if _is_date_dim(v):
            chk_stop("b2b.dim_datum", "param_space", k)
        a = _as_atomic(v)
        if a is None or not len(a):
            chk_stop("b2b.m_param_space_2", k)
        out[k] = a
    for k, v in dims.items():   # seit 1.6.4 (Entscheidung 15): keine Kategorie
        if (isinstance(v, pd.Categorical) or (isinstance(v, pd.Series) and isinstance(v.dtype, pd.CategoricalDtype))):
            chk_stop("faktor", "param_space", k)
    return out


def _is_date_dim(v):
    """Datum, Zeitpunkt oder Zeitspanne als Dimension (R: ``Date``, ``POSIXt``, ``difftime``)."""
    import datetime as _dt
    if isinstance(v, (_dt.date, _dt.timedelta, np.datetime64, np.timedelta64, pd.Timestamp, pd.Timedelta)):
        return True
    if isinstance(v, (pd.Series, pd.Index, np.ndarray)):
        return np.asarray(v).dtype.kind in "mM"
    if isinstance(v, (list, tuple)):
        return any(isinstance(e, (_dt.date, _dt.timedelta, np.datetime64, np.timedelta64)) for e in v)
    return False


def param_range(lower, upper, *, n=5, step=None, integer=False, log=False):
    """Stetiger Bereich einer Dimension für :func:`param_space`.

    ``param_space()`` beschreibt den Suchraum für ``param_search()``: je Parameter eine benannte Dimension mit
    diskreten Werten oder einem stetigen Bereich aus ``param_range()``. Bei ``method = "grid"`` werden alle
    Kombinationen der Rasterwerte ausgewertet; bei ``"random"`` und ``"lhs"`` werden diskrete Werte gleichverteilt
    ausgewählt und Bereiche stetig zwischen ``lower`` und ``upper`` gezogen (``n`` und ``step`` spielen dann keine
    Rolle).

    Args:
        lower, upper: Bereichsgrenzen (Zahlen in der Einheit des Parameters, ``lower <= upper``; bei ``log =
            True`` ``lower > 0``).
            Seit 1.6.4 je eine endliche Zahl.
        n: Anzahl Rasterpunkte des Bereichs bei ``method = "grid"`` (ganze Zahl von 1 bis 1e6, Standard 5); wird
            ignoriert, wenn ``step`` angegeben ist; mit ``step`` wird ``n`` seit 1.6.5 nicht geprüft (ungültige Werte
            als ``None`` abgelegt).
        step: Schrittweite des Rasters in der Einheit des Parameters (``seq(lower, upper, by = step)``, > 0); hat
            Vorrang vor ``n`` und ``log`` (``log`` gilt dann nur für Zufallsziehungen). ``None`` (Standard) =
            ``n`` Punkte.
            Seit 1.6.5 höchstens 1e6 Rasterpunkte (⌊(upper - lower)/step⌋ + 1).
        integer: Logisch (Standard ``False``): Raster- und Zufallswerte auf ganze Zahlen runden; doppelte
            Rasterwerte entfallen.
            Seit 1.6.4 nur TRUE oder FALSE.
        log: Logisch (Standard ``False``): Raster gleichabständig auf der Log-Skala und Ziehung
            log-gleichverteilt, z. B. für Fensterlängen.

    Returns:
        ``param_space``: Objekt der Klasse ``SimLevParamSpace`` (benannte Liste der Dimensionen); ``param_range``:
        Objekt der Klasse ``SimLevParamRange`` (Liste mit ``lower``, ``upper``, ``n``, ``step``, ``integer``,
        ``log``).

    Beispiel::

        import simlev
        sp = simlev.param_space(n=simlev.param_range(50, 400, n=8, integer=True, log=True), band=[0, 1, 2])
        print(sp)
    """
    # seit 1.6.4: Grenzen je eine endliche Zahl (vorher NaN/Inf still als Stufe), integer/log TRUE/FALSE, Meldungen
    # ohne Eingabewert; Länge 1 wie Einzelwert (Entscheidung 4)
    lower, upper, n, step = chk_scalar(lower), chk_scalar(upper), chk_scalar(n), chk_scalar(step)
    if not _is_numeric_vec(lower) or not _is_numeric_vec(upper):
        raise ValueError("param_range: lower <= upper erforderlich.")
    lower = chk_num1(lower, "param_range", "lower")
    upper = chk_num1(upper, "param_range", "upper")
    if upper < lower:
        raise ValueError("param_range: lower <= upper erforderlich.")
    integer = chk_bool1(integer, "param_range", "integer")
    log = chk_bool1(log, "param_range", "log")
    if log and lower <= 0:
        raise ValueError("param_range: log = TRUE erfordert lower > 0.")
    if step is None and (not _is_numeric_scalar(n) or not math.isfinite(n) or n < 1 or n != _r_round_vec([n])[0]):
        chk_stop("b2b.m_param_range")
    if step is None:
        chk_max(n, SL_MAX_GITTER, "param_range", "n")   # seit 1.6.4 (B-004, wie n_grid; Entscheidung 16)
    if step is not None and (not _is_numeric_scalar(step) or not math.isfinite(step) or step <= 0):
        chk_stop("b2b.m_param_range_2")
    if step is not None:
        # seit 1.6.5 (CR2-M-5): Stufenzahl mit step höchstens 1e6 wie n; n wird mit step nicht verwendet und nur als
        # ganze Zahl von 1 bis 1e6 abgelegt, sonst None (bis 1.6.4 int(n), Rohfehler bei NaN oder Text)
        ns = math.floor((float(upper) - float(lower)) / float(step) + 1e-10) + 1
        if ns > SL_MAX_GITTER:
            chk_stop("b2b.step_punkte", "param_range", "%.0f" % ns, "%.0f" % SL_MAX_GITTER)
        ok = (_is_numeric_scalar(n) and math.isfinite(n) and n >= 1 and n == _r_round_vec([n])[0] and n <= SL_MAX_GITTER)
        n = int(n) if ok else None
    else:
        n = int(n)
    return SimLevParamRange(lower=_py(lower), upper=_py(upper), n=n, step=None if step is None else _py(step),
                            integer=bool(integer), log=bool(log))


def _is_numeric_vec(x) -> bool:
    """R ``is.numeric``: Zahl oder Zahlenvektor (kein Wahrheitswert, kein Text)."""
    if isinstance(x, (list, tuple, np.ndarray, pd.Series)):
        a = np.asarray(x)
        return a.dtype.kind in "iuf"
    return _is_numeric_scalar(x)


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


def _ps_design(space, method, n, constraint, stream=None):
    """Versuchsplan erzeugen (Zufall aus ``stream``, sonst aus dem globalen Zustand von SimLev)."""
    from . import _lib as rng
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
                    s = np.asarray(rng.sample(m, stream=stream), dtype=np.float64)
                    U[:, j] = (s - np.asarray(rng.runif(m, stream=stream), dtype=np.float64)) / m
                else:
                    U[:, j] = np.asarray(rng.runif(m, stream=stream), dtype=np.float64)
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
        # seit 1.6.5 (CR2-A-7, Entscheidung 185 K22): Hinweis, wenn der Plan weniger als n zulässige Punkte hat
        if len(D) and len(D) < n:
            from ._util import _message
            _message(chk_msg("b2b.weniger_punkte", "param_search", len(D), int(n)))
    if not len(D):
        chk_stop("b2b.m_ok_rows")
    return D.reset_index(drop=True)


# ─────────────────────────────────────────────────────────────────────────────
# Spezifikation auswerten
# ─────────────────────────────────────────────────────────────────────────────

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
    from ._sim_blocks import _sim_args_set, _sim_call
    args = _sim_args_set(sim_args, sp.get("args"), "param_search")
    return _quiet(lambda: _sim_call(df, sp["strategy"], args))


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

    # ``plot`` (SVG, ``SimLevPlot``) wird am Modulende über ``_plot_method`` gesetzt.


@_study_scope
def param_search(data, builder=None, space=_MISSING, *, strategy=None, method=("grid", "random", "lhs"), n=50,
                 constraint=None, sim_args=None, burn_in=0, metrics=None, objective="sharpe", maximize=True,
                 keep_returns=("day", "none"), seed=None, cores="auto"):
    """Parametersuche über Strategie- und Simulationsparameter.

    Wertet eine Strategie für jeden Punkt eines Parameterraums mit ``simulation()`` aus. Neben den Kennzahlen
    werden die täglichen zeitgewichteten Renditen jedes Punkts gespeichert; darauf bauen die
    Überanpassungs-Prüfungen ``overfit_pbo()``, ``sharpe_deflated()`` und ``overfit_walk_forward()`` auf.

    Args:
        data: DataFrame wie in ``simulation()`` (Spalte ``date`` und Kursspalten als Niveaus), inklusive Vorlauf
            für Signale (siehe ``burn_in``).
            Seit 1.6.4 mindestens eine Datenzeile (vorab geprüft).
        builder: Funktion ``function(p)``, die aus einer benannten Liste ``p`` (ein Punkt des Raums) entweder eine
            Strategie oder eine Liste ``{"strategy": ..., "signal": ..., "args": ..., "map": ..., "data": ...}``
            liefert: ``signal`` wie in ``bootstrap_study()`` (Funktion ``df ->`` DataFrame oder Liste von Spalten,
            z. B. mit ``signal_sma()``), ``args`` (Liste, wie ``sim_args``, auch mit Pfaden wie
            ``"rebalance.thresh"``) überschreibt ``sim_args``, ``map`` (benannter Zeichenvektor) legt
            Spalten-Aliase an, ``data`` ist optional eine Funktion ``df -> df`` (z. B. eine Hebelreihe mit
            ``series_leverage()`` anlegen). ``None`` (Standard) = ohne ``builder``: die Parameter werden als
            Argumente von ``simulation()`` für ``strategy`` verwendet; Parameter der Bausteine dann mit Pfad, z.
            B. ``param_space(rebalance.thresh = [2, 5], dca.value = [100, 200])`` (wie in ``sensitivity_grid``);
            die Spalten von ``results`` heißen wie die Pfade.
        space: Suchraum aus ``param_space()`` (oder benannte Liste, die an ``param_space()`` weitergegeben wird).
        strategy: Feste Strategie (z. B. aus ``create_strategy()``), wenn ``builder`` fehlt; sonst ungenutzt.
        method: ``"grid"`` (Standard, volles Raster), ``"random"`` (Zufallssuche) oder ``"lhs"`` (Latin Hypercube;
            gleichmäßige Abdeckung bei vielen Dimensionen).
        n: Anzahl Punkte bei ``"random"`` und ``"lhs"`` (ganze Zahl, Standard 50); bei ``"grid"`` ignoriert.
            Doppelte Punkte werden entfernt und in höchstens 20 Runden nachgezogen; es können weniger Punkte
            entstehen (seit 1.6.5 mit Hinweis).
            Seit 1.6.4 höchstens 10^8.
        constraint: Optional ``function(p)``, die ``True`` für zulässige Punkte liefert (z. B. Gewichte summieren
            sich höchstens zu 1); Punkte ohne ``True`` entfallen. ``None`` (Standard) = alle Punkte.
        sim_args: Benannte Liste gemeinsamer Argumente für ``simulation()`` (Standard: keine): Argumente von
            ``simulation()`` außer ``data`` und ``strategy``, also auch Bausteine (z. B. ``dca = dca_plan(100,
            1)``, ``tax = tax_profile()``) und Pfade zu Parametern der Bausteine (``"dca.value"``, siehe
            ``sensitivity_grid``). Alte Einzelargumente (bis 0.8.0, vor den Bausteinen, z. B. ``dca_value``)
            ergeben einen Fehler, der den Baustein nennt.
        burn_in: Anzahl Zeilen am Anfang von ``data`` (bei Tagesdaten: Tage), die nach der Signalberechnung
            verworfen werden (Signal-Vorlauf; ganze Zahl, Standard 0).
            Seit 1.6.4 eine ganze Zahl ≥ 0; seit 1.6.5 kleiner als die Zahl der Datenzeilen (vorab geprüft).
        metrics: Funktion ``SimLevResult ->`` benannter numerischer Vektor (Standard
            ``bootstrap_study_metrics()``: u. a. ``cagr``, ``max_drawdown`` als Anteil, ``sharpe``; ``cagr`` ist
            mit Sparplan geldgewichtet, XIRR).
            Seit 1.6.4 müssen die Namen der Kennzahlen eindeutig und nicht leer sein und dürfen keiner festen Spalte
            des Ergebnisses gleichen (sonst Fehler nach dem Rechnen).
        objective: Name der Zielgröße (Element von ``metrics``, Standard ``"sharpe"``) für Ranking, Plateau und
            ``param_bootstrap()``.
            Seit 1.6.5 nach dem ersten Punkt geprüft (vorher nach allen Punkten).
        maximize: Logisch: Zielgröße maximieren (Standard ``True``; ``False`` z. B. für ``max_drawdown``).
        keep_returns: ``"day"`` (Standard): tägliche Renditen je Punkt speichern (nötig für ``overfit_pbo()``,
            ``sharpe_deflated()``, ``overfit_walk_forward()``, ``overfit_reality_check()``, ``sharpe_haircut()``);
            ``"none"``: keine. ``True``/``False`` (bis 1.0.0) ergeben einen Fehler.
        seed: Startwert für den Versuchsplan bei ``"random"``/``"lhs"`` (Standard ``None``; bei ``"grid"`` ohne
            Bedeutung). Mit Startwert (ganze Zahl, |seed| < 2^53) ist das Ergebnis reproduzierbar und der
            Zufallszustand von SimLev bleibt unverändert; mit ``None`` wird genau einmal ein Startwert aus dem
            Zufallszustand von SimLev gezogen (siehe ``simlev_seed()``), wiederholte Aufrufe liefern dann
            verschiedene Ergebnisse. ``set.seed()`` wirkt nicht. Die Auswertung der Punkte ist deterministisch,
            das Ergebnis hängt nicht von ``cores`` ab.
        cores: Anzahl paralleler Prozesse (unter Unix per Fork):
            ``"auto"`` (Standard seit 1.6.4; bis 1.6.3 1) oder eine ganze Zahl ≥ 1.
            Mit ``"auto"`` rechnet SimLev die ersten Einheiten nacheinander, misst ihre Rechenzeit und wählt dann
            die Zahl der Prozesse und der Kern-Threads je Lauf selbst (Planer, gleiche Regel in R, Python
            und Julia): höchstens Zahl der freien Prozessoren (Prozessoren minus andere laufende Prozesse gleicher oder höherer Priorität), so viele,
            wie der freie Speicher trägt, und nur, wenn die
            Startkosten kleiner sind als der Gewinn (kleine Rechnungen bleiben bei einem Prozess; ohne ``fork``
            (Windows, macOS) immer einer).
            Ausgaben, Meldungen, Warnungen und Fehler der Einheiten erscheinen dabei wie mit ``cores = 1``, in
            Einheitenreihenfolge.
            Eine feste Zahl ist seit 1.6.5 der Höchstwert der automatischen Wahl: SimLev misst und plant wie mit
            ``"auto"``, nimmt aber höchstens so viele Prozesse (bis 1.6.4 immer so viele ohne Messung; ohne ``fork``
            nacheinander); höchstens Zahl der Prozessoren: mehr wird mit einem Hinweis begrenzt.
            In Julia erscheinen Ausgaben, die
            eigene Funktionen (etwa ``metrics``) direkt mit ``println`` schreiben, bei mehreren Aufgaben in der
            Reihenfolge, in der die Einheiten fertig werden (in R und Python in Einheitenreihenfolge). Das Ergebnis
            hängt nicht von cores ab.
            Je paralleler Einheit rechnen die Kerne mit höchstens Zahl der Prozessoren / Läufe Threads (mindestens 1).

    Returns:
        Objekt der Klasse ``SimLevParamSearch``, eine Liste mit

        - ``results``: DataFrame je Punkt: ``id``, eine Spalte je Parameter, die Kennzahlen aus ``metrics``
          (``NA`` bei Fehler) und ``error`` (Fehlermeldung oder ``NA``).
        - ``returns``: Matrix Tage x Punkte der täglichen zeitgewichteten Renditen als Anteil (aus
          ``result_index()``); Zeilen = Tage nach ``burn_in`` ohne den ersten, Spalten ``p1``, ``p2``, ... (Nummer
          = ``id``); ``NA`` für fehlgeschlagene Punkte. ``None`` bei ``keep_returns = "none"``.
        - ``dates``: Datum je Zeile von ``returns`` (Kalender des ersten erfolgreichen Punkts).
        - ``space``, ``params``, ``method``, ``objective``, ``maximize``, ``builder``, ``sim_args``, ``burn_in``:
          Einstellungen (``params`` = Parameternamen).
        - ``metrics``: Namen der Kennzahlen.
        - ``elapsed``: Laufzeit in Sekunden.

        Methoden ``print``, ``summary``, ``plot``; Weiterverarbeitung mit ``param_plateau()``, ``overfit_pbo()``,
        ``sharpe_deflated()``, ``overfit_walk_forward()``, ``param_bootstrap()``.

    Details:
        Je Punkt wird die Spezifikation in dieser Reihenfolge angewandt: ``signal(df)`` auf dem vollen Datensatz,
        dann ``data(df)``, dann ``map``, dann das Verwerfen der ersten ``burn_in`` Zeilen und schließlich
        ``simulation()`` mit ``sim_args``, überschrieben durch ``args``. Fehler einzelner Punkte brechen die Suche
        nicht ab, sondern stehen in ``results["error"]``. Das Ergebnis lässt sich auch mit
        ``overfit_reality_check()`` und ``sharpe_haircut()`` weiterverarbeiten.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 3000
        d = pd.DataFrame({"date": pd.date_range("2010-01-01", periods=n)})
        d["A"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.011, n))
        st = simlev.create_strategy(A=simlev.asset_config(asset_class="etf", trading="signal", signal_buy="buy",
                                                         signal_sell="sell"))
        ps = simlev.param_search(d, lambda p: {"strategy": st, "signal": lambda df: simlev.signal_sma(df["A"], n=p["n"], band=p["band"])},
                                 simlev.param_space(n=[50, 100, 200], band=[0, 2]), burn_in=250)
        print(ps["results"][["id", "n", "band", "cagr", "sharpe"]])
    """
    _e5_choice(method, ("grid", "random", "lhs"), "param_search", "method")   # seit 1.6.4 (K43 T2-N4) Prüfung vor match.arg (Meldung auswahl)
    method = _match_arg(method, ("grid", "random", "lhs"), "method")
    # Text statt Logisch, ohne Alias (E1); logisch vor dem Text prüfen
    if isinstance(keep_returns, (bool, np.bool_)):
        chk_stop("b2b.m_param_search")
    _e5_choice(keep_returns, ("day", "none"), "param_search", "keep_returns")
    keep_returns = _match_arg(keep_returns, ("day", "none"), "keep_returns")
    keep_ret = keep_returns == "day"
    # einheitliche Eingabeprüfung (seit 1.6.4); data/strategy mit den Meldungen von simulation()
    fn = "param_search"
    from ._sim_base import _Frame
    if not isinstance(data, (pd.DataFrame, _Frame)):
        chk_stop("a.m_sim_check_inputs", chk_msg("tabelle.formen"))
    if len(data) == 0 if isinstance(data, pd.DataFrame) else data.nrow == 0:   # seit 1.6.4 vorab (Entscheidung 38)
        chk_stop("zeilen_keine", fn, "data")
    if builder is not None and not callable(builder):
        chk_stop("e2.funktion", fn, "builder")
    if space is _MISSING:   # R: space ohne Standardwert; Platzhalter nur, weil builder davor einen hat
        chk_stop("fehlt", fn, "space")
    if not isinstance(space, (SimLevParamSpace, Mapping, list, tuple, np.ndarray)):
        chk_stop("liste", fn, "space")
    if builder is None and strategy is not None:
        from .sensitivity import _e2_check_strategy
        _e2_check_strategy(strategy)
    n = chk_int1(n, fn, "n")
    chk_max(n, SL_MAX_N, fn, "n")   # seit 1.6.4 (Entscheidungen 16 und 36)
    if constraint is not None and not callable(constraint):
        chk_stop("e2.funktion", fn, "constraint")
    from .sensitivity import _e2_sim_args
    sim_args = _e2_sim_args(sim_args, fn)
    burn_in = chk_int1(burn_in, fn, "burn_in", lo=0)
    # seit 1.6.5 (CR2-A-7): burn_in kleiner als die Zahl der Datenzeilen, vorab
    nrow_d = len(data) if isinstance(data, pd.DataFrame) else data.nrow
    if burn_in >= nrow_d:
        chk_stop("b2b.burn_in", fn, int(burn_in), int(nrow_d))
    if metrics is not None and not callable(metrics):
        chk_stop("e2.funktion", fn, "metrics")
    objective = chk_name1(objective, fn, "objective")
    maximize = chk_bool1(maximize, fn, "maximize")
    cores = chk_cores(cores, fn)   # seit 1.6.4 höchstens Zahl der Prozessoren, mit Hinweis (Entscheidung 41b)
    sim_args = {} if sim_args is None else dict(sim_args)
    if metrics is None:
        metrics = _ext("bootstrap", "bootstrap_study_metrics")
    if isinstance(space, (list, tuple, np.ndarray)):   # R: unbenannter Vektor -> param_space-Meldung
        chk_stop("b2b.m_param_space")
    if not isinstance(space, SimLevParamSpace):
        space = param_space(**dict(space))
    if builder is None:
        if strategy is None:
            chk_stop("b2b.m_param_search_3")
        fixed = strategy
        from ._sim_blocks import _sim_check_names
        _sim_check_names(list(space.keys()), "param_search")   # Dimensionen = Argumente von simulation() bzw. Pfade

        def builder(p):
            return {"strategy": fixed, "args": p}
    from ._sim_blocks import _sim_args_set
    sim_run_args = _sim_args_set({}, sim_args, "param_search")
    # Zufall nur im Versuchsplan (Hauptstrom); die Auswertung je Punkt ist deterministisch
    from ._lib import main_stream
    design = _ps_design(space, method, n, constraint, None if method == "grid" else main_stream(seed, "param_search"))
    t0 = time.perf_counter()

    def run(i):
        p = _row_params(design, i)
        try:
            res = _run_spec(data, _as_spec(builder(p)), sim_run_args, burn_in)
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
        if keep_ret:
            ix = _ext("withdrawal", "result_index")(res)
            v = ix["value"].to_numpy(dtype=np.float64)
            out["date"] = np.asarray(ix["date"]).astype("datetime64[D]")
            out["ret"] = v[1:] / v[:-1] - 1
        return out
    # seit 1.6.5 (CR2-W1-3): der erste Punkt vorab, damit Namen der Kennzahlen und objective vor der ganzen Rechnung
    # geprüft werden (bis 1.6.4 erst nach allen Punkten)
    first = run(0)
    if first["m"] is not None:
        chk_kennzahlen(list(first["m"].index), len(first["m"]), ["id"] + [str(k) for k in design.columns] + ["error"], fn)
        if objective not in [str(k) for k in first["m"].index]:
            chk_stop("rs.objective", fn, objective, ", ".join(str(k) for k in first["m"].index))
    out = [first] + (list(_par_lapply(list(range(1, len(design))), run, cores)) if len(design) > 1 else [])
    okm = [o for o in out if o["m"] is not None]
    if not okm:
        raise ValueError("param_search: alle Punkte fehlgeschlagen, z. B.: %s" % out[0]["err"])
    # seit 1.6.4 (Entscheidung 43, Regel 28 wie bootstrap_study): Namen der Kennzahlen eindeutig, nicht leer und keine
    # feste Spalte (id, Parameter, error); geprüft nach dem Rechnen, bei jedem cores gleich (R: gleiche Prüfung)
    for o in okm:
        chk_kennzahlen(list(o["m"].index), len(o["m"]), ["id"] + [str(k) for k in design.columns] + ["error"], fn)
    mnames = [str(k) for k in okm[0]["m"].index]
    if objective not in mnames:
        chk_stop("rs.objective", fn, objective, ", ".join(mnames))
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
    if keep_ret:
        ref = okm[0]["date"]
        dates = ref[1:]
        Rm = np.full((len(dates), len(design)), _NAN)
        dk = dates.astype(np.int64)
        srt = bool(np.all(dk[1:] > dk[:-1]))   # Tage aufsteigend und eindeutig: Zuordnung über searchsorted (seit 1.6.3)
        pos = None if srt else {int(x): i for i, x in enumerate(dk)}
        for i, o in enumerate(out):
            if o.get("ret") is not None:
                dd = o["date"][1:].astype(np.int64)
                rv = np.asarray(o["ret"])
                if srt and rv.ndim == 1 and rv.size == dd.size:
                    kk = np.minimum(np.searchsorted(dk, dd), max(dk.size - 1, 0))
                    hit = (dk[kk] == dd) if dk.size else np.zeros(dd.size, dtype=bool)
                    Rm[kk[hit], i] = rv[hit]
                    continue
                if pos is None:
                    pos = {int(x): i for i, x in enumerate(dk)}
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
    """``match(x, table)`` (1-basiert, NA → nan). Seit 1.6.4 (B-074) über ein Wörterbuch Wert → erste Position
    (gleiche Treffer wie ``==``: gleiche Zahlen haben gleiche Hashwerte); nicht hashbare Werte wie bisher paarweise."""
    tab = [_py(t) for t in np.asarray(table).tolist()]
    xs = [_py(v) for v in np.asarray(x).tolist()]
    try:
        pos = {}
        na_hit = _NAN
        for i, t in enumerate(tab):
            if _isna(t):
                if na_hit != na_hit:
                    na_hit = float(i + 1)
            elif t not in pos:
                pos[t] = float(i + 1)
        return np.array([na_hit if _isna(v) else pos.get(v, _NAN) for v in xs], dtype=np.float64)
    except TypeError:
        pass
    out = []
    for v in xs:
        hit = _NAN
        for i, t in enumerate(tab):
            if (_isna(v) and _isna(t)) or (not _isna(v) and not _isna(t) and v == t):
                hit = float(i + 1)
                break
        out.append(hit)
    return np.array(out, dtype=np.float64)


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
        lev = [_ps_levels(x["space"][p]) for p in x["params"]]
        L = np.column_stack([_match(P[p].to_numpy(), lv) for p, lv in zip(x["params"], lev)])
        nb = _ps_nb_box(L, radius, [len(np.asarray(lv)) for lv in lev])
        if nb is not None:
            return nb
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
    # seit 1.6.5 (CR2-X1-1): immer eine Zeile je Punkt (bis 1.6.4 bei genau einem Punkt p Zeilen wie R)
    Z = np.column_stack(zs)
    D = _dist_matrix(Z)
    m = min(k, Z.shape[0])
    return [np.argsort(D[i], kind="stable")[:m].astype(np.int64) + 1 for i in range(Z.shape[0])]


def _ps_nb_box(L, radius, nl):
    """Rasternachbarn über die Zellen der (2 radius + 1)^d Versätze (seit 1.6.4, B-074; R ``.ps_neighbours``):
    dieselben Zeilen wie paarweise (alle Stufen vorhanden, Abstand <= radius je Dimension), aufsteigend, 1-basiert;
    Zeilen mit fehlender Stufe ohne Nachbarn. ``None``, wenn es mindestens so viele Versätze wie Punkte gibt (dann
    paarweise wie bisher)."""
    n, d = L.shape
    r = int(radius)
    if n == 0 or d == 0 or float(2 * r + 1) ** d > n or float(np.prod(np.asarray(nl, dtype=np.float64))) > 2.0 ** 52:
        return None
    nl = np.asarray(nl, dtype=np.int64)
    mult = np.cumprod(np.r_[1, nl[:-1]]).astype(np.int64)
    oi = np.flatnonzero(~np.isnan(L).any(axis=1))
    Li = L[oi].astype(np.int64)
    lin = (Li - 1) @ mult
    od = np.argsort(lin, kind="stable")
    ls = lin[od]
    rs = oi[od]                                   # Zeilen je Zelle aufsteigend (stabil)
    grids = np.meshgrid(*([np.arange(-r, r + 1)] * d), indexing="ij")
    offs = np.stack([g.ravel() for g in grids], axis=1)
    Is, Js = [], []
    for off in offs:
        Lo = Li + off[None, :]
        inb = ((Lo >= 1) & (Lo <= nl[None, :])).all(axis=1)
        cl = (Lo[inb] - 1) @ mult
        a = np.searchsorted(ls, cl, side="left")
        cnt = np.searchsorted(ls, cl, side="right") - a
        tot = int(cnt.sum())
        Is.append(np.repeat(oi[inb], cnt))
        Js.append(rs[np.repeat(a, cnt) + (np.arange(tot) - np.repeat(np.cumsum(cnt) - cnt, cnt))])
    Ia = np.concatenate(Is)
    Ja = np.concatenate(Js)
    o = np.lexsort((Ja, Ia))
    Ia = Ia[o]
    Ja = Ja[o].astype(np.int64) + 1
    cut = np.searchsorted(Ia, np.arange(n + 1), side="left")
    return [Ja[cut[i]:cut[i + 1]] for i in range(n)]


def _lower_better():
    """R ``.lower_better`` (``r/R/bootstrap.R``): Kennzahlen, bei denen kleiner besser ist."""
    return list(_ext("bootstrap", "_LOWER_BETTER"))


def param_plateau(x, *, metric=None, radius=1, k=5):
    """Plateau-Wert: Zielgröße über die Nachbarschaft eines Punkts.

    Eine einzelne Spitze im Parameterraum ist oft Zufall. Robuster ist ein Punkt, dessen Nachbarn ebenfalls gut
    abschneiden. Beim Raster sind Nachbarn alle Punkte, die sich in jeder Dimension um höchstens ``radius``
    Rasterstufen unterscheiden; bei Zufallssuche/LHS die ``k`` nächsten Punkte im rangskalierten Raum.

    Args:
        x: ``SimLevParamSearch`` aus ``param_search()`` (gespeicherte Renditen sind nicht nötig).
        metric: Name einer Kennzahlspalte von ``x["results"]`` (Standard: Zielgröße der Suche,
            ``x["objective"]``).
            Seit 1.6.4 muss es eine Spalte von x$results sein.
        radius: Maximaler Abstand in Rasterstufen je Dimension (ganze Zahl, Standard 1); nur ``method = "grid"``.
            Seit 1.6.4 eine ganze Zahl ≥ 0.
        k: Anzahl Nachbarn inklusive Punkt selbst (ganze Zahl, Standard 5); nur ``method = "random"`` und
            ``"lhs"``.
            Seit 1.6.4 eine ganze Zahl ≥ 1.

    Returns:
        DataFrame je Punkt mit ``id``, ``value`` (Kennzahl des Punkts), ``plateau_mean`` (Mittel der Kennzahl über
        die Nachbarschaft, fehlende Werte ignoriert), ``plateau_min`` (ungünstigster Wert der Nachbarschaft: bei
        der Zielgröße je nach ``x["maximize"]`` das Minimum bzw. Maximum; bei anderen Kennzahlen das Maximum für
        ``max_drawdown``, ``avg_drawdown``, ``dd_q50``, ``dd_q90``, ``ulcer_index`` und ``longest_drawdown``
        (kleiner = besser), sonst das Minimum), ``neighbours`` (Anzahl Punkte der Nachbarschaft) und ``valid``
        (seit 1.6.5: Anzahl Punkte der Nachbarschaft mit Wert). Die Einheit entspricht der Kennzahl. Seit 1.6.5 haben
        Punkte ohne eigenen Wert (fehlgeschlagen oder NA) kein Plateau: ``plateau_mean`` und ``plateau_min`` sind dort
        NA.

    Details:
        Rasterstufen sind die Positionen in den Rasterwerten jeder Dimension des Suchraums. Im rangskalierten Raum
        wird jede Dimension über ihre Ränge auf 0 bis 1 abgebildet (nicht numerische Parameter über ihre
        Faktorcodes) und der euklidische Abstand verwendet. Der Punkt selbst gehört immer zu seiner Nachbarschaft.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 3000
        d = pd.DataFrame({"date": pd.date_range("2010-01-01", periods=n)})
        d["A"] = 100 * np.cumprod(1 + rng.normal(3e-4, 0.011, n))
        st = simlev.create_strategy(A=simlev.asset_config(asset_class="etf", trading="signal", signal_buy="buy",
                                                         signal_sell="sell"))
        ps = simlev.param_search(d, lambda p: {"strategy": st, "signal": lambda df: simlev.signal_sma(df["A"], n=p["n"], band=p["band"])},
                                 simlev.param_space(n=[50, 100, 200], band=[0, 2]), burn_in=250)
        print(simlev.param_plateau(ps))
    """
    if not isinstance(x, SimLevParamSearch):
        chk_stop("klasse", "param_plateau", "x", "param_search()")
    if metric is None:
        metric = x["objective"]
    # seit 1.6.4: metric als Spalte der Ergebnisse, radius und k als ganze Zahlen
    metric = chk_name1(metric, "param_plateau", "metric")
    if metric not in [str(c) for c in x["results"].columns]:
        chk_stop("e2.spalte_von", "param_plateau", "metric", "x$results")
    radius = chk_int1(radius, "param_plateau", "radius", lo=0)
    k = chk_int1(k, "param_plateau", "k")
    tab = x["results"]
    v = tab[metric].to_numpy(dtype=np.float64)
    nb = _ps_neighbours(x, radius, k)
    lower_better = (x.get("maximize") is not True) if metric == x["objective"] else metric in _lower_better()

    def worst(a):
        a = a[~np.isnan(a)]
        if not a.size:
            return math.inf if lower_better is False else -math.inf
        return float(a.max()) if lower_better else float(a.min())
    # seit 1.6.5 (CR2-R-1, Entscheidung 189): Punkte ohne eigenen Wert ohne Plateau (NA); Spalte valid
    own = ~np.isnan(v)
    return pd.DataFrame({"id": tab["id"].to_numpy(), "value": v,
                         "plateau_mean": np.array([r_mean(v[j - 1], na_rm=True) if o else _NAN for j, o in zip(nb, own)],
                                                  dtype=np.float64),
                         "plateau_min": np.array([worst(v[j - 1]) if o else _NAN for j, o in zip(nb, own)], dtype=np.float64),
                         "neighbours": np.array([len(j) for j in nb], dtype=np.int64),
                         "valid": np.array([int((~np.isnan(v[j - 1])).sum()) for j in nb], dtype=np.int64)})


# ─────────────────────────────────────────────────────────────────────────────
# summary / print / plot
# ─────────────────────────────────────────────────────────────────────────────

class SummarySimLevParamSearch(RList, _PrintFormat):
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


def _num(v):
    v = _py(v)
    return _NAN if v is None else float(v)


def _fmt_scalar(v):
    v = _py(v)
    if v is None:
        return "NA"
    return str(np.atleast_1d(_fmt.format(np.array([v]) if not isinstance(v, str) else np.array([v], dtype=object)))[0])


def _summary_param_search(obj_, top=10):
    tab = obj_["results"].copy()
    obj = obj_["objective"]
    pl = param_plateau(obj_)
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
    chk_stop("e5.methode", "summary")   # seit 1.6.5 (CR2-O-7) wie simlev.summary (bis 1.6.4 TypeError)


def _ps_same(a, b):
    """Julias ``_same``: NA gleich NA, NaN gleich NaN, sonst ``==``."""
    na_a, na_b = a is None, b is None
    if na_a or na_b:
        return na_a and na_b
    fa = isinstance(a, (float, np.floating))
    fb = isinstance(b, (float, np.floating))
    if fa and fb and math.isnan(a) and math.isnan(b):
        return True
    if fa and math.isnan(a):
        return False
    return bool(a == b)


def _ps_key(a):
    """Schlüssel mit derselben Gleichheit wie ``_ps_same`` (NA, NaN je eigener Schlüssel, sonst ``==``)."""
    if a is None:
        return ("NA",)
    if isinstance(a, (float, np.floating)) and math.isnan(a):
        return ("NaN",)
    return a


def _ps_groups(g, lev):
    """Zeilen je Stufe (0-basiert, in Tabellenreihenfolge), seit 1.6.5 (CR2-D-16) in einem Durchgang statt jede Stufe
    gegen jede Zeile; gleiche Auswahl wie ``[_ps_same(e, lv) for e in g]``."""
    pos = {}
    for i, lv in enumerate(lev):
        pos.setdefault(_ps_key(lv), []).append(i)   # mehrere Stufen mit gleichem Schlüssel (z. B. 0.0 und -0.0)
    out = [[] for _ in lev]
    idx = []
    for r, e in enumerate(g):
        ks = pos.get(_ps_key(e), ())
        for k in ks:
            out[k].append(r)
        idx.append(ks)
    return [np.asarray(o, dtype=np.int64) for o in out], idx


def _ps_formatv(vals):
    """``format(x)`` (R) eines Stufenvektors → Liste von Texten."""
    arr = (np.array(vals, dtype=object) if any(isinstance(v, str) for v in vals) else np.array(vals))
    return [str(t) for t in np.atleast_1d(_fmt.format(arr))]


def _ps_col(tab, name):
    return [_py(v) for v in tab[name].tolist()]


def _plot_param_search(x, metric=None, params=None, fun=max):
    """``plot.SimLevParamSearch`` (SVG): Zielgröße nach einem Parameter (Linie), als Punktwolke
    (Zufalls-/LHS-Suche) oder als Heatmap über zwei Parameter (Raster).

    Liefert ``(svg, data)``: ``profile`` (``x``, ``value``), ``scatter`` (``x``, ``y``, ``value``)
    bzw. ``heatmap`` (gezeichnete Zellen ``x``, ``y``, ``value``); ``value`` unskaliert.
    """
    from . import overfitting as OF
    from .svg import _jl_max, _jl_min, _jl_sort_levels
    tab = x["results"]
    if metric is None:
        metric = x["objective"]
    if params is None:
        params = [str(v) for v in np.atleast_1d(x["params"])][:2]
    else:
        params = [params] if isinstance(params, str) else [str(v) for v in params]

    def agg(v):
        w = v[np.isfinite(v)]
        return _NAN if w.size == 0 else float(fun(w))
    vals = np.array([_num(v) for v in tab[metric].tolist()], dtype=np.float64)
    # seit 1.6.4 (Entscheidung 40): ohne endlichen Wert der Zielgröße ein Fehler wie in R (bis 1.6.3 ein leeres Bild)
    if not np.isfinite(vals).any():
        chk_stop("grafik_leer", "plot", metric)
    f = _res_fig(700, 460)
    if len(params) == 1:
        g = _ps_col(tab, params[0])
        lev = _jl_sort_levels(g)
        grp, _ = _ps_groups(g, lev)
        a = [agg(vals[ix]) for ix in grp]
        xs = [float(lv) if _is_numeric_scalar(lv) else float(i + 1) for i, lv in enumerate(lev)]
        p = _res_panel(f, 70, 40, 600, 360, _res_range(xs), _res_range(a), title="%s nach %s" % (metric, params[0]),
                       xlab=params[0], ylab=metric)
        _res_line(f, p, xs, a)
        _res_points(f, p, xs, a)
        return _res_finish(f), {"profile": pd.DataFrame({"x": lev, "value": np.array(a, dtype=np.float64)})}
    if x["method"] != "grid":
        xs = np.array([_num(v) for v in tab[params[0]].tolist()], dtype=np.float64)
        ys = np.array([_num(v) for v in tab[params[1]].tolist()], dtype=np.float64)
        # seit 1.6.4 wie R (B-063, Entscheidung 99): 64 Stufen über range(v), Stufe round(1 + 63 (v - lo) /
        # max(hi - lo, 1e-12)), begrenzt auf 1 … 64 (bis 1.6.3 stetig über mindestens [0, 1]); NaN grau wie bisher
        fin = [float(v) for v in vals if not math.isnan(v)]
        lo, hi = (min(fin), max(fin)) if fin else (0.0, 1.0)
        pal = _res_pal()
        cols = ["#cccccc" if math.isnan(v) else
                pal[int(min(64.0, max(1.0, _rint(1 + 63 * (v - lo) / max(hi - lo, 1e-12))))) - 1] for v in vals]
        p = _res_panel(f, 70, 40, 600, 360, _res_range(xs), _res_range(ys), title="%s (Farbe; blau = hoch)" % metric,
                       xlab=params[0], ylab=params[1])
        _res_points(f, p, xs, ys, color=cols, r=5)
        return _res_finish(f), {"scatter": pd.DataFrame({"x": xs, "y": ys, "value": vals})}
    g1 = _ps_col(tab, params[0])
    g2 = _ps_col(tab, params[1])
    l1 = _jl_sort_levels(g1)
    l2 = _jl_sort_levels(g2)
    M = np.full((len(l1), len(l2)), _NAN)
    # Zugehörigkeit je Stufe einmal (seit 1.6.3); seit 1.6.5 (CR2-D-16) Zellen in einem Durchgang (bis 1.6.4 jede
    # Stufe gegen jede Zeile und jede Zelle als Maske): gleiche Zeilen je Zelle in Tabellenreihenfolge
    _, i1 = _ps_groups(g1, l1)
    _, i2 = _ps_groups(g2, l2)
    cell = {}
    for r in range(len(g1)):
        for a in i1[r]:
            for b in i2[r]:
                cell.setdefault((a, b), []).append(r)
    for (i, j), rr in cell.items():
        M[i, j] = agg(vals[np.asarray(rr, dtype=np.int64)])
    fin = [float(v) for v in M.ravel(order="F") if not math.isnan(v)]
    if fin:
        lo = hi = fin[0]
        for v in fin[1:]:
            lo, hi = _jl_min(lo, v), _jl_max(hi, v)
    else:
        lo, hi = 0.0, 1.0
    p = _res_panel(f, 70, 40, 600, 360, (0.5, len(l1) + 0.5), (0.5, len(l2) + 0.5), title="%s (blau = hoch)" % metric,
                   xlab=params[0], ylab=params[1], xticks=[float(i) for i in range(1, len(l1) + 1)],
                   xticklabels=_ps_formatv(l1), yticks=[float(j) for j in range(1, len(l2) + 1)],
                   yticklabels=_ps_formatv(l2), grid=False)
    sc = 100 if metric in ("cagr", "ttwror", "max_drawdown", "avg_drawdown") else 1
    # seit 1.6.4 wie R's image() mit 64 Farben (B-063): zlim = range(M), bei Breite 0 erweitert, Stufe
    # floor(63 z + 0.5) (bis 1.6.3 stetig)
    pal = _res_pal()
    zl0, zl1 = lo, hi
    if zl1 - zl0 == 0:
        zl0, zl1 = (-1.0, 1.0) if zl0 == 0 else (zl0 - 0.4 * abs(zl0), zl0 + 0.4 * abs(zl0))
    ci, cj = [], []
    for i in range(len(l1)):
        for j in range(len(l2)):
            v = M[i, j]
            if math.isnan(v):
                continue
            ci.append(i)
            cj.append(j)
            zi = math.floor(63 * ((v - zl0) / (zl1 - zl0)) + 0.5)
            _res_rect(f, p, i + 1 - 0.5, j + 1 - 0.5, i + 1 + 0.5, j + 1 + 0.5,
                      fill=pal[zi] if 0 <= zi < 64 else "none")
            if M.size <= 300:
                _res_text(f, _res_tx(p, i + 1), _res_ty(p, j + 1) + 4,
                          OF._sprintf("%.1f" if sc == 100 else "%.2f", sc * v), size=9)
    data = {"heatmap": pd.DataFrame({"x": [l1[i] for i in ci], "y": [l2[j] for j in cj],
                                     "value": np.array([M[i, j] for i, j in zip(ci, cj)], dtype=np.float64)})}
    return _res_finish(f), data


# plot.SimLevParamSearch (SVG, ``SimLevPlot``) wie Julias ``_plot_method(_plot_ps, "SimLevParamSearch")``
from .svg import _plot_method  # noqa: E402

SimLevParamSearch.plot = _plot_method(_plot_param_search, "SimLevParamSearch")


# Rechnen mit NA (signalisierendes NaN) ohne numpy-Warnung "invalid value" wie in R (gemeinsamer Helfer)
from ._r.base import quiet_fp  # noqa: E402

quiet_fp(globals(), list(__all__) + ["_as_spec", "_ps_design", "_ps_levels", "_ps_map", "_ps_neighbours"])


from . import _callable_module  # noqa: E402 (aufrufbar wie die gleichnamige Funktion, PEP 562)
_callable_module("param_search")
