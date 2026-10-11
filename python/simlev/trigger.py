"""Vorberechnung der Event-Trigger-Spalte (Port von compute_rebal_trigger.R)."""
from __future__ import annotations

from typing import Any, Mapping, Sequence

import numpy as np

__all__ = ["compute_rebal_trigger"]


def _col(df: Any, name: str):
    try:
        if hasattr(df, "columns"):
            if name not in df.columns:
                return None
            return df[name]
        return df.get(name)
    except Exception:
        return None


def compute_rebal_trigger(
    df: Any,
    type: str,
    threshold: float = 10,
    lev_col: str = "target_leverage",
    vol_col: str = "sigma_ewma",
    triggers: Sequence[Mapping[str, Any]] | None = None,
    out_col: str = "rebal_trigger",
):
    """Berechnet eine logische Trigger-Spalte für ereignisbasiertes Rebalancing.

    ``threshold`` wird **in Prozent** angegeben. Gibt eine Kopie von ``df``
    (``pandas.DataFrame``) bzw. ein neues ``dict`` mit der Spalte ``out_col``
    zurück. Tag 1 ist immer ``False``.
    """
    n = len(df) if hasattr(df, "columns") else len(next(iter(df.values())))
    if n < 1:
        raise ValueError("compute_rebal_trigger: leerer data.frame.")
    threshold = threshold / 100
    trig = np.zeros(n, dtype=bool)

    if type in ("abs_leverage", "rel_leverage"):
        col = _col(df, lev_col)
        if col is None:
            raise ValueError("Spalte '%s' fehlt." % lev_col)
        lev = np.asarray(col, dtype=np.float64)
        held = float(lev[0])
        for t in range(1, n):
            v = float(lev[t])
            if np.isnan(v):
                continue
            if type == "abs_leverage":
                if abs(v - held) > threshold:
                    trig[t] = True
                    held = v
            else:
                if held != 0 and abs(v / held - 1) > threshold:
                    trig[t] = True
                    held = v
    elif type == "vol_band":
        col = _col(df, vol_col)
        if col is None:
            raise ValueError("Spalte '%s' fehlt." % vol_col)
        vol = np.asarray(col, dtype=np.float64)
        ref = float(vol[0])
        for t in range(1, n):
            v = float(vol[t])
            if not np.isnan(v) and ref != 0 and abs(v / ref - 1) > threshold:
                trig[t] = True
                ref = v
    elif type == "combined":
        if not triggers:
            raise ValueError("type='combined' benoetigt eine nicht-leere Liste 'triggers'.")
        for sub in triggers:
            args = {"df": df, "out_col": "..__sub__.."}
            args.update(sub)
            sub_df = compute_rebal_trigger(**args)
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
