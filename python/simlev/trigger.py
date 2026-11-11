"""Vorberechnung der Event-Trigger-Spalte (Gegenstück zu ``compute_rebal_trigger.R``)."""
from __future__ import annotations

from typing import Any, Mapping, Sequence

import numpy as np

from ._pruefen import chk_choice, chk_df, chk_msg, chk_name1, chk_num1, chk_stop

__all__ = ["rebalance_trigger"]


def _col(df: Any, name: str):
    """Spalte ``name`` von ``df`` oder ``None``."""
    return df[name] if name in df.columns else None


_FN = "rebalance_trigger"
_TYPES = ("abs_leverage", "rel_leverage", "vol_band", "combined")
_SUB_FIELDS = ("type", "threshold", "lev_col", "vol_col", "triggers", "df")


def _first_obs(v: np.ndarray) -> int:
    """Index des ersten nicht fehlenden Werts (sonst der letzte Index)."""
    ok = np.flatnonzero(~np.isnan(v))
    return int(ok[0]) if ok.size else v.size - 1


def _trig_series(df, name, arg):
    """Spalte als Liste (numerisch, ohne ±Inf; eine Spalte nur aus NA zählt als Zahlenspalte) und erster Wert."""
    from ._sim_base import _column
    col = _col(df, name)
    if col is None:   # seit K43 T1-R5 mit Funktions- und Argumentnamen (bis dahin "Spalte '<name>' fehlt.")
        chk_stop("e2.spalte_von", _FN, arg, "df")
    kind, arr = _column(col)
    if kind == "logical" and all(v is None for v in arr):
        arr, kind = np.full(len(arr), np.nan), "numeric"
    if kind == "factor":   # Entscheidung 15
        chk_stop("spalte_faktor", _FN, name)
    if kind != "numeric":
        chk_stop("spalte_typ", _FN, name, chk_msg("typ.numerisch"))
    v = np.asarray(arr, dtype=np.float64)
    if np.isinf(v).any():
        chk_stop("e1.spalte_endlich", _FN, name)
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
            Seit 1.6.4 darf die Spalte in ``df`` noch nicht vorhanden sein (vorher still überschrieben).

    Seit 1.6.4 geprüft: ``df`` nur als ``pandas.DataFrame``; ``threshold`` eine einzelne endliche Zahl ``>= 0``;
    Spaltennamen einzeln und nicht leer; die genutzte Spalte nur Zahlen oder NA (kein ``inf``, keine Kategorie);
    Teil-Trigger nur mit den Feldern ``type``, ``threshold``, ``lev_col``, ``vol_col``, ``triggers`` und ``df`` (gleiche
    Zeilenzahl).

    Returns:
        ``df`` mit einer zusätzlichen logischen Spalte ``out_col``. ``True`` bedeutet: an diesem Tag wird
        Rebalancing ausgelöst. Tag 1 ist immer ``False`` (kein Rebalancing am Einstiegstag).

    Hinweise (Python):
        ``threshold`` **in Prozent** (intern /100): bei ``"abs_leverage"`` Prozentpunkte des Hebels,
        bei ``"rel_leverage"``/``"vol_band"`` relative Abweichung. Die Referenz ist der erste nicht
        fehlende Wert und springt nur an Trigger-Tagen; NA löst nicht aus. ``"combined"`` verknüpft
        die Sub-Trigger aus ``triggers`` per ODER. Gibt eine Kopie von ``df`` (``pandas.DataFrame``)
        mit der Spalte ``out_col`` zurück; Tag 1 ist immer ``False``.

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
    # seit 1.6.4 Eingabeprüfung vor der Rechnung (A-013, A-036): df nur als pandas.DataFrame (Entscheidung 6), type
    # aus der Liste, threshold eine einzelne endliche Zahl >= 0, Spaltennamen einzeln und nicht leer, die genutzte
    # Spalte numerisch und ohne ±Inf, Teil-Trigger von "combined" mit den Feldern type, threshold, lev_col, vol_col,
    # triggers und df (eigenes df mit gleicher Zeilenzahl; out_col dort nicht; bis 1.6.3 verwarf Python einen Teil-Trigger
    # mit eigenem out_col still)
    chk_df(df, _FN, "df")
    n = len(df)
    if n < 1:
        chk_stop("zeilen_keine", _FN, "df")   # seit K43 T1-R5 aus der Tabelle
    type = chk_choice(type, _FN, "type", _TYPES)
    threshold = chk_num1(threshold, _FN, "threshold", lo=0)
    lev_col = chk_name1(lev_col, _FN, "lev_col")
    vol_col = chk_name1(vol_col, _FN, "vol_col")
    out_col = chk_name1(out_col, _FN, "out_col")
    if out_col in df.columns:   # seit 1.6.4 (Entscheidung 26): vorhandene Spalte nicht still überschreiben
        chk_stop("spalte_vorhanden", _FN, out_col, "df", "out_col")
    threshold = threshold / 100
    trig = np.zeros(n, dtype=bool)
    if type in ("abs_leverage", "rel_leverage"):
        lv, t0 = _trig_series(df, lev_col, "lev_col")
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
        vl, t0 = _trig_series(df, vol_col, "vol_col")
        ref = vl[t0]
        for t in range(t0 + 1, n):
            v = vl[t]
            if v == v and ref != 0 and abs(v / ref - 1) > threshold:
                trig[t] = True
                ref = v
    else:
        # seit K43 T1-R5 aus der Tabelle (bis dahin "type='combined' benötigt eine nicht-leere Liste 'triggers'.")
        if triggers is None:
            chk_stop("fehlt", _FN, "triggers")
        if isinstance(triggers, (list, tuple, Mapping, np.ndarray)) and len(triggers) == 0:
            chk_stop("ut1.liste_leer", _FN, "triggers")
        if isinstance(triggers, (str, Mapping)) or not isinstance(triggers, (list, tuple)):
            chk_stop("liste", _FN, "triggers")
        subs = []
        for i, sub in enumerate(triggers, start=1):
            if not isinstance(sub, Mapping):
                chk_stop("liste", _FN, "triggers[[%d]]" % i)
            bad = [str(k) for k in sub.keys() if k not in _SUB_FIELDS]
            if bad:
                chk_stop("e1.trigger_feld", _FN, bad[0], i)
            if sub.get("type") is None:
                chk_stop("fehlt", _FN, "triggers[[%d]]$type" % i)
            subs.append({k: v for k, v in sub.items() if v is not None})   # R modifyList: NULL entfernt das Feld
        for sub in subs:
            args = {"df": df, "out_col": "..__sub__.."}
            args.update(sub)
            sub_df = rebalance_trigger(**args)
            if len(sub_df) != n:   # eigenes df eines Teil-Triggers: gleiche Zeilenzahl
                chk_stop("e1.trigger_df", _FN, n)
            trig = trig | np.asarray(_col(sub_df, "..__sub__.."), dtype=bool)
    out = df.copy()
    out[out_col] = trig
    return out
