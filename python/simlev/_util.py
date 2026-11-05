"""Interne Hilfen, die mehrere Module teilen (seit 1.5.2; vorher je Modul eine Kopie oder Weiterleitung).

Nur Standardbibliothek, numpy, pandas und :mod:`simlev._r` (keine Paketmodule: keine Importzyklen). Seit 1.6.1
eine Fassung von ``match.arg`` (``_match_arg``, Prüfungen und Meldungen wie R; bis 1.6.0 zwei Fassungen) und von
``which.max``/``which.min``.
"""
from __future__ import annotations

import importlib
from typing import Any, Iterable

import numpy as np
import pandas as pd

from ._r import fmt as _fmt
from ._r.rnum import NA_REAL


def _ext(mod, name):
    """Funktion ``name`` aus ``simlev.<mod>`` (spät geladen; parallel portierte Module)."""
    return getattr(importlib.import_module("simlev." + mod), name)


def _stats():
    """Modul :mod:`simlev._r.stats` (spät geladen)."""
    from ._r import stats
    return stats


def _pmatch(value: str, choices: tuple) -> int | None:
    """``pmatch(value, choices)`` für eine Zeichenkette: Index der genauen bzw. eindeutigen Teilübereinstimmung."""
    if value in choices:
        return choices.index(value)
    if not value:
        return None
    hits = [i for i, c in enumerate(choices) if c.startswith(value)]
    return hits[0] if len(hits) == 1 else None


def _match_arg(arg: Any, choices: Iterable[str], argname: str | None = None) -> str:
    """R's ``match.arg(arg, choices)`` (R 4.3.3, ``base/R/match.R``): ``None`` oder der vollständige Auswahlvektor
    ergeben die erste Wahl, eindeutige Präfixe werden ergänzt; Prüfungen und Meldungen wortgleich zu R.
    ``argname`` wird nicht ausgewertet. Seit 1.6.1 die einzige Fassung (bis 1.6.0 daneben eine zweite aus
    ``data_prep`` ohne R's Meldungen bei einer Wahl, leerem oder nicht textförmigem Vektor).
    """
    choices = tuple(choices)
    if arg is None:
        return choices[0]
    if isinstance(arg, (list, tuple, np.ndarray)):
        vals = list(arg)
        if not all(isinstance(v, str) for v in vals):
            raise ValueError("'arg' must be NULL or a character vector")
        if tuple(vals) == choices:
            return choices[0]
        if len(vals) > 1:
            raise ValueError("'arg' must be of length 1")
        arg = vals[0] if vals else ""
    if not isinstance(arg, str):
        raise ValueError("'arg' must be NULL or a character vector")
    i = _pmatch(arg, choices)
    if i is None:
        chs = [c for c in dict.fromkeys(choices) if c]
        raise ValueError(("'arg' should be %s" if len(chs) == 1 else "'arg' should be one of %s")
                         % ", ".join("\u201c%s\u201d" % c for c in chs))
    return choices[i]


def _which_max(v, empty=None):
    """R's ``which.max`` (0-basiert): erster Index des größten Werts, NA und NaN übergangen; ``empty``, wenn es
    keinen gibt (R: ``integer(0)``). Seit 1.6.1 eine Fassung für alle Module (bis 1.6.0 je Modul eine Kopie)."""
    a = np.asarray(v, dtype=np.float64).ravel()
    ok = ~np.isnan(a)
    if not ok.any():
        return empty
    idx = np.flatnonzero(ok)
    return int(idx[np.argmax(a[idx])])


def _which_min(v, empty=None):
    """R's ``which.min`` (0-basiert) wie :func:`_which_max`."""
    a = np.asarray(v, dtype=np.float64).ravel()
    ok = ~np.isnan(a)
    if not ok.any():
        return empty
    idx = np.flatnonzero(ok)
    return int(idx[np.argmin(a[idx])])


_EPOCH = np.datetime64("1970-01-01", "D")


def _days(d):
    """Datum (``datetime64``-Feld) → Tage seit 1970 als float64 (NaT → NA); andere Eingaben als float64. Seit 1.6.1
    eine Fassung für ``deep_analysis`` und ``tactical`` (``data_prep._days`` liest zusätzlich Text und Einheiten,
    ``dependence``/``overfitting``/``sensitivity`` liefern NaN bzw. ganze Zahlen und bleiben eigene Fassungen)."""
    a = np.asarray(d)
    if a.dtype.kind == "M":
        a = a.astype("datetime64[D]")
        out = (a - _EPOCH).astype(np.int64).astype(np.float64)
        out[np.isnat(a)] = NA_REAL
        return out
    return np.asarray(a, dtype=np.float64)


def _dates(days):
    """Tage seit 1970 (float) → ``datetime64[D]``-Feld (NaN → NaT; Bruchteile zur Null hin abgeschnitten). Seit 1.6.1
    eine Fassung für ``deep_analysis`` und ``tactical`` (``data_prep._as_dates`` rundet ab und bleibt eigen)."""
    a = np.asarray(days, dtype=np.float64)
    out = np.full(a.shape, np.datetime64("NaT", "D"), dtype="datetime64[D]")
    ok = ~np.isnan(a)
    out[ok] = _EPOCH + a[ok].astype(np.int64).astype("timedelta64[D]")
    return out


def _fmt_vec(f, v):
    """``sprintf(f, v)`` als object-Feld (auch für eine Zahl)."""
    out = _fmt.sprintf(f, np.asarray(v, dtype=np.float64))
    if isinstance(out, str):
        out = np.array([out], dtype=object)
    return np.asarray(out, dtype=object)


def _cov2cor(V):
    """``stats::cov2cor``."""
    V = np.asarray(V, dtype=np.float64)
    p = V.shape[0]
    Is = np.sqrt(1 / np.diag(V))
    r = Is.reshape(-1, 1) * V * Is.reshape(1, -1)
    r[np.arange(p), np.arange(p)] = 1.0
    return r


def _num_col(v):
    """``as.numeric`` einer Spalte; NA/NaN-Bitmuster numerischer Spalten bleiben erhalten (sonst NA)."""
    if getattr(v, "dtype", None) is not None and v.dtype.kind == "f":
        return v.to_numpy(dtype=np.float64, copy=True)
    return pd.to_numeric(v, errors="coerce").to_numpy(dtype=np.float64, na_value=NA_REAL)


def _n_tage(n: Any) -> str:
    """``.n_tage()``: "1 Tag" bzw. "n Tage"."""
    s = n if isinstance(n, str) else "%d" % int(n)
    return "1 Tag" if s == "1" else s + " Tage"
