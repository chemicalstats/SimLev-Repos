# Herkunft:           übersetzt aus R 4.3.3, src/main/sort.c, qsort-body.c, seq.c; nachgebildet nach
#                     R 4.3.3, src/library/base/R/sort.R, cut.R;
#                     src/library/stats/R/quantile.R, median.R
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle); qsort-body.c nach R. C. Singleton,
#                     CACM-Algorithmus 347 (1969)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang: Ordnung, Rang, partielle Sortierung und Quantile
#                     rechnet der C-Kern core/slc_rbase_sort.cpp.
"""Gemeinsame Hilfen, Sortieren, Ränge, Einteilen und Lagemaße (``order``, ``sort``, ``rank``, ``cut``,
``quantile``, ``median``), nachgebildet aus R 4.3.3 (``src/main/sort.c``, ``qsort-body.c``, ``seq.c``;
``base/R/sort.R``, ``cut.R``; ``stats/R/quantile.R``, ``median.R``).
"""
from __future__ import annotations

import math
import warnings

import datetime as _dt

import numpy as np
import pandas as pd

from .linalg import RError
from . import rnum as _rn
from .rnum import NA_REAL
from .. import _ext   # C-Kerne core/slc_rbase_sort.cpp
from ._collate import collate_key

__all__ = [
    "quantile", "median", "rank", "order", "sort", "cut", "seq_len_out",
]


_NAN = math.nan
_DBL_EPS = 2.220446049250313e-16
_DBL_MAX = 1.7976931348623157e308


def _warn(msg):
    warnings.warn(msg, stacklevel=3)


# ── Hilfen ────────────────────────────────────────────────────────────────

def _vec(x):
    """Numerischer Vektor (float64, 1-D) und Namen (oder None)."""
    if isinstance(x, pd.Series):
        nm = None if isinstance(x.index, pd.RangeIndex) else [str(i) for i in x.index]
        return np.asarray(x.to_numpy(dtype=np.float64, na_value=np.nan), dtype=np.float64), nm
    if isinstance(x, pd.DataFrame):
        return np.asarray(x.to_numpy(dtype=np.float64), dtype=np.float64).ravel(order="F"), None
    if x is None:
        return np.zeros(0), None
    a = np.asarray(x)
    if a.dtype == object:
        a = np.array([NA_REAL if v is None else v for v in a.ravel(order="F")], dtype=np.float64)
    return np.asarray(a, dtype=np.float64).ravel(order="F"), None


def _stat_kind(x):
    """Art der Eingabe von median/quantile (seit 1.6.4, RP, C-060): "factor", "ordered", "date", "text" oder "num"."""
    if isinstance(x, pd.Series):
        if isinstance(x.dtype, pd.CategoricalDtype):
            return "ordered" if x.cat.ordered else "factor"
        x = x.to_numpy()
    if isinstance(x, pd.Categorical):
        return "ordered" if x.ordered else "factor"
    if x is None or isinstance(x, pd.DataFrame):
        return "num"
    a = np.asarray(x)
    if a.dtype.kind == "M":
        return "date"
    if a.dtype.kind in "US":
        return "text"
    if a.dtype == object:
        vals = [v for v in a.ravel() if v is not None and not (isinstance(v, float) and v != v)]
        if any(isinstance(v, str) for v in vals):
            return "text"
        if any(isinstance(v, (_dt.date, np.datetime64)) for v in vals):
            return "date"
    return "num"


def _stat_reject(fn, what):
    from .._meldungen import EINGABE
    raise RError(EINGABE["rp.stat_art"] % (fn, what))


def _is_int_like(x):
    if isinstance(x, pd.Series):
        return np.issubdtype(x.dtype, np.integer) or x.dtype == bool
    a = np.asarray(x)
    return np.issubdtype(a.dtype, np.integer) or a.dtype == bool


def _rsum(a):
    """``sum`` für Doubles (long double; NA/NaN nach der x87-Regel wie R)."""
    return _rn.r_sum(a)


def _rmean(a):
    """``mean`` für Doubles wie R's ``real_mean`` (long double, Korrekturdurchlauf)."""
    return _rn.r_mean(a)


def seq_len_out(frm, to, length_out):
    """``seq.int(from, to, length.out = n)`` (Werte wie R; seit 1.6.4 wie R aufgerundet und geprüft, C-061)."""
    lo = float(length_out)
    if lo != lo or lo < 0:
        raise RError("'length.out' must be a non-negative number")
    n = int(math.ceil(lo))
    frm = float(frm)
    to = float(to)
    if not math.isfinite(frm):
        raise RError("'from' must be a finite number")
    if not math.isfinite(to):
        raise RError("'to' must be a finite number")
    if n <= 0:
        return np.zeros(0)
    out = np.empty(n)
    _ext.slc_r_seq_len(frm, to, out)   # C-Kern sl_r_seq_len (seit 1.6.0)
    return out


# ── Sortieren, Ränge ─────────────────────────────────────────────────────

def _keys(x):
    """Werte für Sortierung: (float-Array oder object-Array, isna-Maske)."""
    if isinstance(x, pd.Series):
        x = x.to_numpy()
    if isinstance(x, pd.Categorical):
        codes = x.codes.astype(np.float64)
        codes[x.codes < 0] = np.nan
        return codes, np.isnan(codes), False
    a = np.asarray(x)
    if a.ndim > 1:   # seit 1.6.4 wie R spaltenweise (C-045; bis 1.6.3 zeilenweise bzw. Fehler „falsche Länge“)
        a = a.ravel(order="F")
    if a.dtype.kind in "biuf":
        a = a.astype(np.float64)
        return a, np.isnan(a), False
    if a.dtype.kind == "M":
        v = a.astype("datetime64[D]").astype(np.int64).astype(np.float64)
        v[np.isnat(a)] = np.nan
        return v, np.isnan(v), False
    # Zeichenketten (Kollation wie R's Scollate, siehe _collate.py)
    a = a.astype(object)
    na = np.array([v is None or (isinstance(v, float) and v != v) for v in a], dtype=bool)
    return a, na, True


def _stable_argsort(v, isstr, decreasing):
    """Stabile Ordnung von Zeichenketten (R's orderVector1 mit Scollate; Zahlen: C-Kern)."""
    n = len(v)
    if n == 0:
        return np.arange(0)
    # stabil (Gleichstand → Index aufsteigend), auch absteigend (sorted(reverse=True) bleibt stabil)
    ks = [collate_key(str(t)) for t in v]
    return np.array(sorted(range(n), key=ks.__getitem__, reverse=bool(decreasing)), dtype=np.int64)


def _ssort2(vals, decreasing):
    """R's ``ssort2`` (Shellsort mit Scollate) für ``sort()`` unbenannter Zeichenketten."""
    x = list(vals)
    k = [collate_key(str(t)) for t in x]
    n = len(x)
    if n < 2:
        return x
    incs = (1073790977, 268460033, 67121153, 16783361, 4197377, 1050113,
            262913, 65921, 16577, 4193, 1073, 281, 77, 23, 8, 1, 0)
    t = 0
    while incs[t] > n:
        t += 1
    h = incs[t]
    while t < 16:
        for i in range(h, n):
            v, kv = x[i], k[i]
            j = i
            if decreasing:
                while j >= h and k[j - h] < kv:
                    x[j], k[j] = x[j - h], k[j - h]
                    j -= h
            else:
                while j >= h and k[j - h] > kv:
                    x[j], k[j] = x[j - h], k[j - h]
                    j -= h
            x[j], k[j] = v, kv
        t += 1
        h = incs[t]
    return x


def order(*args, na_last=True, decreasing=False):
    """``order(..., na.last, decreasing)`` (stabil wie ``method = "radix"``).

    Liefert 1-basierte Indizes (``int64``-Array) wie R.
    """
    keys = [_keys(a) for a in args]
    n = len(keys[0][0])
    for k in keys:
        if len(k[0]) != n:
            raise RError("argument lengths differ")
    dec = list(decreasing) if isinstance(decreasing, (list, tuple, np.ndarray)) else [bool(decreasing)]
    # seit 1.6.4 (C-018) wie R: mit Textschlüsseln (method "shell") höchstens ein Wert, sonst (radix) rep_len auf die
    # Zahl der Schlüssel; ein leerer Vektor ergibt NA (bis 1.6.3 las der Kern bei zu kurzem decreasing dahinter)
    if any(k[2] for k in keys) and len(dec) > 1:
        raise RError("'decreasing' of length > 1 is only for method = \"radix\"")
    if not dec or any(d is None or (isinstance(d, float) and math.isnan(d)) for d in dec):
        raise RError("'decreasing' elements must be TRUE or FALSE")
    dec = [bool(dec[i % len(dec)]) for i in range(len(keys))]
    if not any(k[2] for k in keys):
        # nur Zahlenschlüssel -> C-Kern sl_r_order (stabil, -0 == 0, NA/NaN fehlend)
        kk = np.ascontiguousarray(np.concatenate([np.asarray(k[0], dtype=np.float64) for k in keys]) if keys else np.zeros(0))
        out = np.empty(n, dtype=np.int64)
        nl = -1 if na_last is None else (1 if na_last else 0)
        m = _ext.slc_r_order(kk, n, len(keys), np.ascontiguousarray([bool(d) for d in dec], dtype=np.int32), nl, out)
        return out[:m]
    idx = np.arange(n)
    # Lexikographisch: von hinten stabil sortieren
    for (v, na, isstr), d in reversed(list(zip(keys, dec))):
        vv = v[idx]
        nn = na[idx]
        ok = np.where(~nn)[0]
        bad = np.where(nn)[0]
        if isstr:
            sub = _stable_argsort(vv[ok], True, d)
        else:   # gemischt Zahlen und Zeichenketten: Zahlenschlüssel über den C-Kern
            sub = order(vv[ok].astype(np.float64), decreasing=d) - 1
        okp = ok[sub]
        if na_last is None:
            new = okp
        elif na_last:
            new = np.concatenate([okp, bad])
        else:
            new = np.concatenate([bad, okp])
        idx = idx[new]
        if na_last is None:
            # Elemente mit NA in irgendeinem Schlüssel entfernen
            pass
    if na_last is None:
        anyna = np.zeros(n, dtype=bool)
        for v, na, _ in keys:
            anyna |= na
        idx = idx[~anyna[idx]]
    return (idx + 1).astype(np.int64)


def sort(x, decreasing=False, na_last=None):
    """``sort(x, decreasing, na.last = NA)``; Namen bleiben erhalten."""
    names = None
    if isinstance(x, pd.Series):
        names = None if isinstance(x.index, pd.RangeIndex) else list(x.index)
    v, na, isstr = _keys(x)
    if isstr and names is None:
        # sort.int(method = "shell") ohne Namen: .Internal(sort()) = ssort2
        arr = np.asarray(x.to_numpy() if isinstance(x, pd.Series) else x, dtype=object)
        if arr.ndim > 1:   # spaltenweise wie R (seit 1.6.4, C-045)
            arr = arr.ravel(order="F")
        ok = arr[~na]
        y = _ssort2(ok, bool(decreasing)) if ok.size >= 2 else list(ok)
        nas = list(arr[na])
        if na_last is None or not nas:
            out = y
        elif na_last:
            out = y + nas
        else:
            out = nas + y
        res = np.empty(len(out), dtype=object)
        res[:] = out
        return res
    o = order(x if not isinstance(x, pd.Series) else x.to_numpy(), na_last=na_last, decreasing=decreasing) - 1
    arr = np.asarray(x.to_numpy() if isinstance(x, pd.Series) else x, dtype=object if isstr else None)
    if arr.ndim > 1:   # spaltenweise wie R (seit 1.6.4, C-045; bis 1.6.3 Fehler)
        arr = arr.ravel(order="F")
    out = arr[o]
    if names is not None:
        return pd.Series(out, index=[names[i] for i in o])
    return out


_TIES = {"average": 0, "first": 1, "last": 2, "min": 3, "max": 4}


def rank(x, na_last=True, ties_method="average"):
    """``rank(x, na.last, ties.method)``.

    ``ties_method``: ``"average"`` (double), ``"first"``, ``"last"``,
    ``"min"``, ``"max"`` (integer). ``na_last``: ``True``, ``False``,
    ``None`` (= ``NA``, entfernen) oder ``"keep"``. Seit 1.6.4 wie R über match.arg (RP, C-056; bis 1.6.3 nur volle
    Namen); ``"random"`` braucht R's Zufallszahlen und wird abgelehnt (``rp.rank_random``).
    """
    from .fmt import _r_match_arg
    try:
        ties_method = _r_match_arg(ties_method, ("average", "first", "last", "random", "max", "min"))
    except ValueError as e:
        raise RError(str(e)) from None
    if ties_method == "random":
        from .._meldungen import EINGABE
        raise RError(EINGABE["rp.rank_random"])
    names = None
    if isinstance(x, pd.Series):
        names = None if isinstance(x.index, pd.RangeIndex) else list(x.index)
    v, na, isstr = _keys(x)
    nas = na
    xs = v[~nas]
    m = len(xs)
    if not isstr and ties_method in _TIES:
        # C-Kern sl_r_rank (Zahlen ohne NA)
        yd = np.empty(m)
        _ext.slc_r_rank(np.ascontiguousarray(xs, dtype=np.float64), _TIES[ties_method], yd)
        y = yd if ties_method == "average" else yd.astype(np.int64)
    elif ties_method in ("average", "min", "max"):
        o = _stable_argsort(xs, isstr, False)
        if ties_method == "average":
            y = np.empty(m, dtype=np.float64)
        else:
            y = np.empty(m, dtype=np.int64)
        i = 0
        sv = xs[o]
        if isstr:   # Gleichstand wie R's equal(): Scollate == 0
            sv = [collate_key(str(t)) for t in sv]
        while i < m:
            j = i
            while j < m - 1 and sv[j] == sv[j + 1]:
                j += 1
            if ties_method == "average":
                y[o[i:j + 1]] = (float(i) + j + 2) / 2.0
            elif ties_method == "max":
                y[o[i:j + 1]] = j + 1
            else:
                y[o[i:j + 1]] = i + 1
            i = j + 1
    elif ties_method == "first":
        o = order(xs) - 1
        y = (np.argsort(o, kind="stable") + 1).astype(np.int64)
    elif ties_method == "last":
        o1 = order(xs, decreasing=True)
        o2 = order(o1[::-1].astype(np.float64))
        y = o2.astype(np.int64)
    else:
        raise RError("ties.method %r is not supported" % ties_method)
    if na_last is not None and nas.any():
        keep = na_last == "keep"
        yy = np.full(len(v), NA_REAL)
        if keep or na_last is True:
            yy[~nas] = y
            if not keep:
                yy[nas] = np.arange(m + 1, len(v) + 1)
        else:
            ln = int(nas.sum())
            yy[~nas] = y + ln
            yy[nas] = np.arange(1, ln + 1)
        y = yy
        if names is not None:
            return pd.Series(y, index=names)
        return y
    if names is not None:
        return pd.Series(y, index=[n for n, b in zip(names, nas) if not b])
    return y


def _bincode(x, breaks, right=True, include_lowest=False):
    """``.bincode`` (C-Kern ``sl_r_bincode``, seit 1.6.0): Intervallnummern als float, NA außerhalb."""
    out = np.empty(np.size(x))
    _ext.slc_r_bincode(np.ascontiguousarray(x, dtype=np.float64), np.ascontiguousarray(breaks, dtype=np.float64),
                       bool(right), bool(include_lowest), out)
    return out


def cut(x, breaks, labels=None, include_lowest=False, right=True, dig_lab=3, ordered_result=False):
    """``cut.default``; ``labels=False`` liefert die Codes (int, NA → nan),
    sonst ein ``pandas.Categorical`` mit R's Beschriftungen."""
    xv, _ = _vec(x)
    br = np.asarray(breaks, dtype=np.float64).ravel()
    if br.size == 1:
        b0 = float(br[0])
        if b0 != b0 or b0 < 2:
            raise RError("invalid number of intervals")
        nb = int(b0 + 1)
        ok = xv[~np.isnan(xv)]
        if not ok.size:   # range(x, na.rm = TRUE) ohne Werte (Warnungen wie R, seit 1.6.0)
            _warn("no non-missing arguments to min; returning Inf")
            _warn("no non-missing arguments to max; returning -Inf")
        rx = (float(ok.min()), float(ok.max())) if ok.size else (math.inf, -math.inf)
        with np.errstate(invalid="ignore"):
            dx = rx[1] - rx[0]
        if dx != dx:   # if (dx == 0) mit NaN (nur +Inf bzw. nur -Inf; seit 1.6.0 wie R)
            raise RError("missing value where TRUE/FALSE needed")
        if dx == 0:
            dx = abs(rx[0]) if rx[0] != 0 else 1.0
            br = seq_len_out(rx[0] - dx / 1000, rx[1] + dx / 1000, nb)
        else:
            # seq.int prüft die Enden (seit 1.6.0 wie R)
            if not math.isfinite(rx[0]):
                raise RError("'from' must be a finite number")
            if not math.isfinite(rx[1]):
                raise RError("'to' must be a finite number")
            br = seq_len_out(rx[0], rx[1], nb)
            br[0] = rx[0] - dx / 1000
            br[nb - 1] = rx[1] + dx / 1000
    else:
        br = np.sort(br[~np.isnan(br)])   # seit 1.6.4 wie R sort.int: NA/NaN entfallen (C-009)
        nb = br.size
    if np.unique(br).size < br.size:
        raise RError("'breaks' are not unique")
    codes_only = False
    if labels is None:
        from . import fmt as _fmt
        ok = False
        ch = None
        for dig in range(dig_lab, max(12, dig_lab) + 1):
            ch = list(_fmt.formatC(0.0 + br, digits=dig, width=1))
            ok = all(a != b for a, b in zip(ch[1:], ch[:-1]))
            if ok:
                break
        if ok:
            labs = [("(" if right else "[") + ch[i] + "," + ch[i + 1] + ("]" if right else ")")
                    for i in range(nb - 1)]
            if include_lowest:
                if right:
                    labs[0] = "[" + labs[0][1:]
                else:
                    labs[-1] = labs[-1][:-1] + "]"
        else:
            labs = ["Range_%d" % (i + 1) for i in range(nb - 1)]
    elif labels is False:
        codes_only = True
        labs = None
    else:
        labs = [None if s is None or s is pd.NA or (isinstance(s, (float, np.floating)) and s != s) else str(s)
                for s in labels]
        if len(labs) != nb - 1:
            raise RError("number of intervals and length of 'labels' differ")
        if any(s is None for s in labs):   # seit 1.6.4 abgelehnt (Entscheidung 67; R bildet eine Stufe NA)
            raise RError("cut: labels darf kein NA enthalten.")
    code = _bincode(xv, br, right, include_lowest)
    if codes_only:
        if np.isnan(code).any():
            return code
        return code.astype(np.int64)
    # seit 1.6.4 wie R factor(code, seq_along(labels), labels): gleiche Beschriftungen ergeben eine Stufe
    # (C-009); NA als Beschriftung ist ein Fehler (oben)
    cats = list(dict.fromkeys(labs))
    pos = [cats.index(s) for s in labs]
    with np.errstate(invalid="ignore"):
        codes = np.array([-1 if c != c else pos[int(c) - 1] for c in code], dtype=np.int64)
    return pd.Categorical.from_codes(codes, categories=cats, ordered=ordered_result)


# ── Lage- und Streuungsmaße ──────────────────────────────────────────────

def _format_perc(probs, digits=7):
    from . import fmt as _fmt
    with np.errstate(invalid="ignore"):
        x = 100 * np.asarray(probs, dtype=np.float64)
    if x.size == 0:
        return []
    if x.size < 100:
        s = list(_fmt.formatC(x, format="fg", width=1, digits=digits))
    else:
        s = list(_fmt.format(x, trim=True, digits=digits))
    return [("" if (xi != xi) else si + "%") for si, xi in zip(s, x.tolist())]


# ── R's partielle Sortierung (sort.default(x, partial =)) ─────────────────
# Für Werte, die sich nur im Vorzeichen der Null unterscheiden (-0/+0), hängt
# das Ergebnis von quantile()/median() vom Sortierverfahren ab; der C-Kern
# sl_r_psort sortiert wie R (bis 10 Indizes Auswahl, sonst Quicksort).

def sort_partial(x, partial):
    """``sort(x, partial = partial)`` für Doubles wie R (1-basierte Indizes; NA/NaN entfallen wie bei
    ``na.last = NA``). Seit 1.6.4 (C-015) mit den Prüfungen von R: nicht endliche Stellen „non-finite 'partial'“,
    bis 10 Stellen ganzzahlig (zur Null hin) im Bereich 1 … Länge, sonst „index k outside bounds“ bzw. außerhalb des
    int-Bereichs „NA index“ (mit Warnung); bis 1.6.3 hing der Kern, stürzte ab oder las fremden Speicher."""
    v = np.array(np.asarray(x, dtype=np.float64).ravel(), dtype=np.float64)
    v = v[~np.isnan(v)]
    p = np.asarray(partial, dtype=np.float64).ravel() if np.size(partial) else np.zeros(0)
    if not np.isfinite(p).all():
        raise RError("non-finite 'partial'")
    if p.size <= 10:
        ki = [int(math.trunc(t)) if -2147483648.0 < t < 2147483648.0 else None for t in np.sort(p).tolist()]
        if any(t is None for t in ki):   # as.integer: außerhalb des int-Bereichs NA mit Warnung
            warnings.warn("NAs introduced by coercion to integer range")
        for t in ki:
            if t is None:
                raise RError("NA index")
            if t < 1 or t > v.size:
                raise RError("index %d outside bounds" % t)
        k = np.ascontiguousarray(ki, dtype=np.int64)
    else:
        k = np.zeros(p.size, dtype=np.int64)   # mehr als 10 Stellen: vollständig sortiert wie R (ohne Prüfung)
    _ext.slc_r_psort(v, k)
    return v


def _switch_int(t):
    """``asInteger`` des numerischen ``switch``-Ausdrucks: abgeschnitten, ausserhalb des int-Bereichs NA mit Warnung."""
    if t != t:
        return None
    if not (-2147483648.0 < t < 2147483648.0):
        _warn("NAs introduced by coercion to integer range")
        return None
    return int(math.trunc(t))


def quantile_type(type):
    """``type`` von ``quantile.default`` wie R auswerten (seit 1.6.4, Befund C-028): wirksamer Typ 1–9, 0 für den
    Zweig ``type <= 3`` ohne passende ``switch``-Wahl (R nimmt dann die untere Ordnungsstatistik ``x[j]``) oder der
    Fehler, den R an derselben Stelle meldet (``if (type == 7)``, ``switch``, ``type - 3``)."""
    v = list(type) if isinstance(type, (list, tuple, np.ndarray, pd.Series)) else [type]
    if len(v) > 1:
        raise RError("the condition has length > 1")
    if not v:
        raise RError("argument is of length zero")
    t = v[0]
    if t is None or t is pd.NA:
        raise RError("missing value where TRUE/FALSE needed")
    if isinstance(t, str):   # Textvergleich wie R ("7" == 7 ist TRUE, sonst Kollation gegen "3")
        if t == "7":
            return 7
        from ._collate import str_collate
        if str_collate(t, "3") <= 0:
            raise RError("numeric EXPR required for 'switch' without named alternatives")
        raise RError("non-numeric argument to binary operator")
    t = float(t)
    if t != t:
        raise RError("missing value where TRUE/FALSE needed")
    if t == 7:
        return 7
    if t <= 3:
        k = _switch_int(t)
        return k if k in (1, 2, 3) else 0
    k = _switch_int(t - 3)
    if k is None or not 1 <= k <= 6:
        raise RError("object 'a' not found")
    return k + 3


def _quantile_lower(xv, pp):
    """R ``quantile.default`` im Zweig ``type <= 3`` ohne ``h``: ``x[j]`` mit ``j = floor(n * p)`` (Rand: x[1])."""
    n = xv.size
    out = np.full(pp.size, NA_REAL)
    if n == 0:
        return out
    xs = np.sort(xv)
    pad = np.concatenate([[xs[0], xs[0]], xs, [xs[-1], xs[-1]]])
    for i, p in enumerate(pp):
        if p == p:
            out[i] = pad[int(math.floor(n * p)) + 1]
    return out


def quantile(x, probs=(0.0, 0.25, 0.5, 0.75, 1.0), na_rm=False, names=True, type=7, digits=7):
    """``quantile.default(x, probs, na.rm, names, type)`` (Typen 1–9).

    Ergebnis: ``Series`` (mit Namen wie ``"25%"``) bzw. bei ``names=False``
    ``ndarray`` (Länge 1: ``float``). Seit 1.6.4 (RP, C-060) wie R: ungeordnete Faktoren „(unordered) factors are not
    allowed“, geordnete außer type 1/3 „'type' must be 1 or 3 …“; Text und Datum mit type 4 bis 9 R's Fehler der
    Rechnung. Geordnete Faktoren (type 1/3), Text und Datum mit type 1 bis 3 rechnet R, hier abgelehnt (``rp.stat_art``);
    bis 1.6.3 Abbruch beim Umwandeln in Zahlen.
    """
    kind = _stat_kind(x)
    if kind == "factor":
        raise RError("(unordered) factors are not allowed")
    if kind == "ordered":
        tv = list(type) if isinstance(type, (list, tuple, np.ndarray)) else [type]
        # type == c(1L, 3L) wie R (Zahl, Wahrheitswert oder Text "1"/"3")
        if not any((t in ("1", "3")) if isinstance(t, str) else
                   (isinstance(t, (int, float, np.integer, np.floating, bool, np.bool_)) and t == t and t in (1, 3))
                   for t in tv):
            raise RError("'type' must be 1 or 3 for ordered factors")
        _stat_reject("quantile", "geordnete Faktoren")
    if kind in ("text", "date"):
        a = np.asarray(x.to_numpy() if isinstance(x, pd.Series) else x).ravel()
        if a.dtype.kind == "M":
            nav = np.isnat(a)
        else:
            nav = np.array([v is None or (isinstance(v, float) and v != v) or (isinstance(v, np.datetime64) and np.isnat(v))
                            for v in a], dtype=bool)
        if not na_rm and nav.any():
            raise RError("missing values and NaN's not allowed if 'na.rm' is FALSE")
        p = np.atleast_1d(np.asarray(probs, dtype=np.float64)).ravel()
        eps = 100 * _DBL_EPS
        with np.errstate(invalid="ignore"):
            if (~np.isnan(p) & ((p < -eps) | (p > 1 + eps))).any():
                raise RError("'probs' outside [0,1]")
        if quantile_type(type) >= 4:
            raise RError('* not defined for "Date" objects' if kind == "date" else "non-numeric argument to binary operator")
        _stat_reject("quantile", "Datumswerte" if kind == "date" else "Texte")
    xv, _ = _vec(x)
    if na_rm:
        xv = xv[~np.isnan(xv)]
    elif np.isnan(xv).any():
        raise RError("missing values and NaN's not allowed if 'na.rm' is FALSE")
    p = np.atleast_1d(np.asarray(probs, dtype=np.float64)).ravel()
    eps = 100 * _DBL_EPS
    pok = ~np.isnan(p)
    with np.errstate(invalid="ignore"):
        if (pok & ((p < -eps) | (p > 1 + eps))).any():
            raise RError("'probs' outside [0,1]")
    pp = np.where(np.isnan(p), p, np.maximum(0.0, np.minimum(1.0, p)))
    np_ = pp.size
    typ = quantile_type(type)   # seit 1.6.4 wie R (C-028)
    # C-Kern sl_r_quantile (partielle Sortierung wie R, Typen 1–9)
    qs = np.empty(np_)
    if typ == 0:
        qs = _quantile_lower(np.asarray(xv, dtype=np.float64), pp)
    else:
        _ext.slc_r_quantile(np.ascontiguousarray(xv, dtype=np.float64), np.ascontiguousarray(pp), typ, qs)
    qs = np.where(pok, qs, p)
    if names and np_ > 0:
        return pd.Series(qs, index=_format_perc(pp, digits))
    if np_ == 1:
        return float(qs[0])
    return qs


def median(x, na_rm=False):
    """``median.default(x, na.rm)``. Seit 1.6.4 (RP, C-060) wie R: Faktoren „need numeric data“; Text: mittlerer Wert
    nach R's Sortierung, bei gerader Anzahl NA mit R's Warnung; Datumswerte abgelehnt (``rp.stat_art``; R liefert ein
    Datum mit Bruchteil). Bis 1.6.3 Abbruch beim Umwandeln in Zahlen."""
    kind = _stat_kind(x)
    if kind in ("factor", "ordered"):
        raise RError("need numeric data")
    if kind == "date":
        _stat_reject("median", "Datumswerte")
    if kind == "text":
        a = list(np.asarray(x.to_numpy() if isinstance(x, pd.Series) else x, dtype=object).ravel())
        na = [v is None or (isinstance(v, float) and v != v) for v in a]
        if na_rm:
            a = [v for v, m in zip(a, na) if not m]
        elif any(na):
            return None                   # x[NA_integer_]: NA
        n = len(a)
        if n == 0:
            return None
        xs = _ssort2([str(v) for v in a], False)
        if n % 2 == 1:
            return xs[n // 2]
        _warn("argument is not numeric or logical: returning NA")
        return NA_REAL
    is_int = _is_int_like(x)
    xv, _ = _vec(x)
    r = _ext.slc_r_median(np.ascontiguousarray(xv), bool(na_rm), bool(is_int))   # C-Kern sl_r_median (seit 1.6.0)
    if r is None:
        return NA_REAL                  # x[NA_integer_] bzw. leer
    if is_int and np.count_nonzero(~np.isnan(xv)) % 2 == 1:
        return int(r)
    return r


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
