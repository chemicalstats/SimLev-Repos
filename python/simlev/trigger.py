"""Vorberechnung der Event-Trigger-Spalte (Gegenstück zu ``compute_rebal_trigger.R``)."""
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


def _trig_series(df, name):
    """Spalte ``name`` als Liste von Python-Zahlen (statt float()/np.isnan je Tag, seit 1.5.2) und erste Beobachtung."""
    col = _col(df, name)
    if col is None:
        raise ValueError("Spalte '%s' fehlt." % name)
    v = np.asarray(col, dtype=np.float64)
    return v.tolist(), _first_obs(v)


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

    Berechnet eine binäre Trigger-Spalte, die ``simulation`` über ``event_col`` konsumiert. Die gesamte
    Schwellenwert-/Bandlogik liegt hier, außerhalb der Engine — der Nutzer kann sie nach Bedarf anpassen oder
    ersetzen.

    Vier Trigger-Typen sind implementiert:

    - ``"abs_leverage"``: Trigger, wenn die absolute Abweichung des Ziel-Hebels vom zuletzt gehaltenen Hebel
      größer als ``threshold`` ist.
    - ``"rel_leverage"``: Trigger, wenn die relative Abweichung des Ziel-Hebels vom zuletzt gehaltenen Hebel
      größer als ``threshold`` ist.
    - ``"vol_band"``: Trigger, wenn die Volatilität relativ zum letzten Rebalancing-Referenzwert um mehr als
      ``threshold`` abweicht.
    - ``"combined"``: OR-Verknüpfung mehrerer Sub-Trigger-Specs aus ``triggers``.

    Der Referenzwert (gehaltener Hebel bzw. Volatilität) ist der erste nicht fehlende Wert (in der Regel der erste
    Tag; bei führenden ``NA``, etwa in der Anlaufphase einer EWMA-Volatilität, der erste Tag mit Wert; bis dahin
    wird nicht ausgelöst) und wird nur an Tagen fortgeschrieben, an denen dieser Trigger auslöst (nicht an
    kalendarischen Rebalancing-Tagen in ``simulation``). Ausgelöst wird bei einer Abweichung *größer* als die
    Schwelle; ``NA``-Werte lösen nicht aus. Bei ``"rel_leverage"`` und ``"vol_band"`` wird nicht ausgelöst,
    solange der Referenzwert 0 ist.

    Args:
        df: ``data.frame`` mit täglichen Feldern (mindestens eine Zeile). Muss die relevanten numerischen Spalten
            (``lev_col`` bzw. ``vol_col``) enthalten, sonst Fehler.
        type: Character. Trigger-Typ: ``"abs_leverage"``, ``"rel_leverage"``, ``"vol_band"`` oder ``"combined"``.
            Kein Standardwert; andere Werte führen zu einem Fehler.
        threshold: Numerisch. Auslöseschwelle **in Prozent** (Paket-Konvention). Bedeutung je Typ:
            ``"abs_leverage"`` in Prozentpunkten des Hebels (``10`` = 0,10 Hebelabweichung);
            ``"rel_leverage"``/``"vol_band"`` relative Abweichung (``10`` = 10 %). Bei ``type = "combined"``
            ignoriert (Schwellen je Sub-Trigger). Standard: ``10``.
        lev_col: Character. Name der Ziel-Hebel-Spalte in ``df``. Wird von ``"abs_leverage"`` und
            ``"rel_leverage"`` verwendet. Standard: ``"target_leverage"``.
        vol_col: Character. Name der Volatilitätsspalte in ``df``. Wird von ``"vol_band"`` verwendet. Standard:
            ``"sigma_ewma"``.
        triggers: Liste von Sub-Trigger-Specs (nur bei ``type = "combined"``). Jeder Eintrag ist eine Liste mit
            ``type`` und ggf. ``threshold`` (in Prozent, fehlt er: ``10``), ``lev_col``, ``vol_col``. Jeder
            Sub-Trigger führt seinen eigenen Referenzwert; die Ergebnisse werden OR-verknüpft. Standard: ``None``.
        out_col: Character. Name der zu erzeugenden logischen Spalte in ``df``. Standard: ``"rebal_trigger"``.

    Returns:
        ``df`` mit einer zusätzlichen logischen Spalte ``out_col``. ``True`` bedeutet: an diesem Tag wird
        Rebalancing ausgelöst. Tag 1 ist immer ``False`` (kein Rebalancing am Einstiegstag).

    Hinweise (Python):
        ``threshold`` **in Prozent** (intern /100): bei ``"abs_leverage"`` Prozentpunkte des Hebels,
        bei ``"rel_leverage"``/``"vol_band"`` relative Abweichung. Die Referenz ist der erste nicht
        fehlende Wert und springt nur an Trigger-Tagen; NA löst nicht aus. ``"combined"`` verknüpft
        die Sub-Trigger aus ``triggers`` per ODER. Gibt eine Kopie von ``df`` (``pandas.DataFrame``)
        bzw. ein neues ``dict`` mit der Spalte ``out_col`` zurück; Tag 1 ist immer ``False``.

    Beispiel::

        import numpy as np, pandas as pd, simlev
        rng = np.random.default_rng(1)
        n = 500
        d = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=n)})
        d["ETF"] = 100 * np.cumprod(1 + rng.normal(4e-4, 0.012, n))
        d["target_leverage"] = 2 + 0.5 * np.sin(np.linspace(0, 4 * np.pi, n))
        d["sigma_ewma"] = 0.01 + 0.005 * np.abs(rng.normal(size=n))
        d = simlev.rebalance_trigger(d, "abs_leverage", threshold=10)
        print(d["rebal_trigger"].sum())     # Anzahl der Rebalancing-Tage
    """
    n = _nrow(df)
    if n < 1:
        raise ValueError("rebalance_trigger: leerer data.frame.")
    threshold = threshold / 100
    trig = np.zeros(n, dtype=bool)
    if type in ("abs_leverage", "rel_leverage"):
        lv, t0 = _trig_series(df, lev_col)
        held = lv[t0]
        for t in range(t0 + 1, n):
            v = lv[t]
            if v != v:
                continue
            if type == "abs_leverage":
                if abs(v - held) > threshold:
                    trig[t] = True
                    held = v
            elif held != 0 and abs(v / held - 1) > threshold:
                trig[t] = True
                held = v
    elif type == "vol_band":
        vl, t0 = _trig_series(df, vol_col)
        ref = vl[t0]
        for t in range(t0 + 1, n):
            v = vl[t]
            if v == v and ref != 0 and abs(v / ref - 1) > threshold:
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
