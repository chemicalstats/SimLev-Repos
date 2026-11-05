"""Interne Hilfen, die mehrere Module teilen (seit 1.5.2; vorher je Modul eine Kopie oder Weiterleitung).

Nur Standardbibliothek, numpy, pandas und :mod:`simlev._r` (keine Paketmodule: keine Importzyklen). Seit 1.6.1
eine Fassung von ``match.arg`` (``_match_arg``, Prüfungen und Meldungen wie R; bis 1.6.0 zwei Fassungen) und von
``which.max``/``which.min``.
"""
from __future__ import annotations

import importlib
import math
from typing import Any, Iterable

import numpy as np
import pandas as pd

from ._r import fmt as _fmt
from ._r import libm as _libm
from ._r.rnum import NA_REAL, r_pow, r_prod, r_sum


# Genauere Renditeformeln (seit 1.6.2; gleicher Ausdruck wie .cagr_q, .pow1m, .pow1m_v, .geo_ret, .geo_ann, .log1mr2
# in r/R/utils.R und im Kern): außerhalb der Bereiche, in denen die genaue Fassung dasselbe bedeutet, die bisherige Formel.
def _cagr_q(q, yrs):
    """``q^(1/yrs) - 1`` als ``expm1(log(q) / yrs)`` (q >= 0, yrs endlich und != 0)."""
    with np.errstate(all="ignore"):
        if q >= 0 and math.isfinite(yrs) and yrs != 0:
            return _libm.expm1(_libm.log(q) / yrs)
        return r_pow(q, np.float64(1) / yrs) - 1


def _pow1m1(x, e):
    if x >= -1 and math.isfinite(e) and e != 0:
        return _libm.expm1(_libm.log1p(x) * e)
    return r_pow(1 + x, e) - 1


def _pow1m(x, e):
    """``(1 + x)^e - 1`` als ``expm1(log1p(x) * e)`` (x >= -1, e endlich und != 0)."""
    with np.errstate(all="ignore"):
        return _pow1m1(x, e)


def _pow1m_v(x, e):
    """``_pow1m`` elementweise (gleich lange Felder)."""
    x = np.asarray(x, dtype=np.float64)
    e = np.asarray(e, dtype=np.float64)
    with np.errstate(all="ignore"):
        return np.array([_pow1m1(a, b) for a, b in zip(x.tolist(), e.tolist())], dtype=np.float64)


def _geo_ok(x):
    return not np.isnan(x).any() and bool(np.all(x >= -1))


def _geo_ret(x):
    """``prod(1 + x) - 1`` als ``expm1(sum(log1p(x)))`` (kein NA, alle x >= -1)."""
    x = np.asarray(x, dtype=np.float64)
    with np.errstate(all="ignore"):
        if _geo_ok(x):
            return _libm.expm1(r_sum(_libm.log1p(x)))
        return r_prod(1 + x) - 1


def _geo_ann(x, yrs):
    """``prod(1 + x)^(1/yrs) - 1`` als ``expm1(sum(log1p(x)) / yrs)`` (wie ``_geo_ret`` und ``_cagr_q``)."""
    x = np.asarray(x, dtype=np.float64)
    with np.errstate(all="ignore"):
        if _geo_ok(x) and math.isfinite(yrs) and yrs != 0:
            return _libm.expm1(r_sum(_libm.log1p(x)) / yrs)
        return r_pow(r_prod(1 + x), np.float64(1) / yrs) - 1


def _log1mr2(r):
    """``log(1 - r^2)``: ``log1p(-r^2)`` für r^2 < 1/2, sonst ``log((1 - r)(1 + r))`` (höchstens 1,4 ulp)."""
    with np.errstate(all="ignore"):
        if r * r < 0.5:
            return _libm.log1p(-(r * r))
        return _libm.log((1 - r) * (1 + r))

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
