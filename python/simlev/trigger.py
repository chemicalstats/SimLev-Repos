"""Vorberechnung der Event-Trigger-Spalte (Port von ``compute_rebal_trigger.R``)."""
from __future__ import annotations

from typing import Any, Mapping, Sequence

import numpy as np

__all__ = ["rebalance_trigger"]


def _col(df: Any, name: str):
    if hasattr(df, "columns"):
        return df[name] if name in df.columns else None
    return df.get(name) if isinstance(df, Mapping) else None


def _nrow(df: Any) -> int:
    if hasattr(df, "columns"):
        return len(df)
    if isinstance(df, Mapping):
        return len(np.atleast_1d(next(iter(df.values())))) if len(df) else 0
    raise ValueError("rebalance_trigger: df muss ein data.frame sein.")


def _first_obs(v: np.ndarray) -> int:
    """Index (0-basiert) des ersten nicht fehlenden Werts; nur NA: letzter Index."""
    ok = np.flatnonzero(~np.isnan(v))
    return int(ok[0]) if ok.size else v.size - 1


def rebalance_trigger(
    df: Any,
    type: str,
    *,
    threshold: float = 10,
    lev_col: str = "target_leverage",
    vol_col: str = "sigma_ewma",
    triggers: Sequence[Mapping[str, Any]] | None = None,
    out_col: str = "rebal_trigger",
):
    """Logische Trigger-Spalte für ``simulation(..., rebalance=rebalance_plan(event_col=...))`` vorberechnen.

    ``threshold`` **in Prozent** (intern /100): bei ``"abs_leverage"`` Prozentpunkte des Hebels,
    bei ``"rel_leverage"``/``"vol_band"`` relative Abweichung. Die Referenz ist der erste nicht
    fehlende Wert und springt nur an Trigger-Tagen; NA löst nicht aus. ``"combined"`` verknüpft
    die Sub-Trigger aus ``triggers`` per ODER. Gibt eine Kopie von ``df`` (``pandas.DataFrame``)
    bzw. ein neues ``dict`` mit der Spalte ``out_col`` zurück; Tag 1 ist immer ``False``.
    """
    n = _nrow(df)
    if n < 1:
        raise ValueError("rebalance_trigger: leerer data.frame.")
    threshold = threshold / 100
    trig = np.zeros(n, dtype=bool)
    if type in ("abs_leverage", "rel_leverage"):
        col = _col(df, lev_col)
        if col is None:
            raise ValueError("Spalte '%s' fehlt." % lev_col)
        lev = np.asarray(col, dtype=np.float64)
        t0 = _first_obs(lev)
        held = float(lev[t0])
        for t in range(t0 + 1, n):
            v = float(lev[t])
            if np.isnan(v):
                continue
            if type == "abs_leverage":
                if abs(v - held) > threshold:
                    trig[t] = True
                    held = v
            elif held != 0 and abs(v / held - 1) > threshold:
                trig[t] = True
                held = v
    elif type == "vol_band":
        col = _col(df, vol_col)
        if col is None:
            raise ValueError("Spalte '%s' fehlt." % vol_col)
        vol = np.asarray(col, dtype=np.float64)
        t0 = _first_obs(vol)
        ref = float(vol[t0])
        for t in range(t0 + 1, n):
            v = float(vol[t])
            if not np.isnan(v) and ref != 0 and abs(v / ref - 1) > threshold:
                trig[t] = True
                ref = v
    elif type == "combined":
        if not triggers:
            raise ValueError("type='combined' benötigt eine nicht-leere Liste 'triggers'.")
        for sub in triggers:
            args = {"df": df, "out_col": "..__sub__.."}
            args.update(sub)
            sub_df = rebalance_trigger(**args)
            trig = trig | np.asarray(_col(sub_df, "..__sub__.."), dtype=bool)
    else:
        raise ValueError("Unbekannter type='%s'." % type)
    if hasattr(df, "columns"):
        out = df.copy()
        out[out_col] = trig
        return out
    out = dict(df)
    out[out_col] = trig
    return out
