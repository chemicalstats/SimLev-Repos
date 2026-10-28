"""R's ``stats``-Interna (R 4.3.3), bitgleich in Python.

Portiert aus ``src/library/stats/R/*.R`` und ``src/library/stats/src/*.c``
bzw. ``*.f`` (sowie Teilen von ``src/main/sort.c``, ``seq.c``, ``cum.c``).
Rechenreihenfolge, ``long double``-Akkumulation (``numpy.longdouble``) und
libm-Aufrufe (``math``) wie in R.

Konventionen
------------
* Namen wie in R, ``.`` → ``_`` (``weighted.mean`` → :func:`weighted_mean`,
  ``lm.fit`` → :func:`lm_fit`, ``p.adjust`` → :func:`p_adjust`, …).
* Argumentnamen und Voreinstellungen wie in R (``na.rm`` → ``na_rm``).
* Eingaben: numpy-Arrays, Listen, Skalare, ``pandas.Series`` (benannte
  Vektoren) und ``pandas.DataFrame`` bzw. 2-D-Arrays (Matrizen).
* Ergebnisse: Länge-1-Vektoren als ``float``/``int``, sonst ``ndarray``;
  benannte Vektoren als ``Series``; Matrizen als 2-D-``ndarray`` bzw. mit
  dimnames als ``DataFrame``; R-Listen als :class:`~simlev._r.rlist.RList`.
* ``NA`` ist ``NA_REAL`` (NaN mit R's Nutzlast 1954), andere NaN sind R's ``NaN``. Fehler: :class:`RError` mit R's Meldungstext;
  Warnungen über :func:`warnings.warn` mit R's Text.
"""
from __future__ import annotations

import math
import warnings
from collections.abc import Mapping

import numpy as np
import pandas as pd

from .linalg import RError, _as_r, _as_matrix, _out, _vec_out
from .rlist import RList
from . import rnum as _rn
from .rnum import NA_REAL
from ._collate import str_collate, collate_key

LD = np.longdouble
_NAN = math.nan
_DBL_EPS = 2.220446049250313e-16
_DBL_MAX = 1.7976931348623157e308

__all__ = [
    "RError", "LMFit", "GLMFit", "RDist", "RHclust", "SmoothSpline", "dist_as_matrix", "glm_fit", "quantile", "median", "var", "sd", "cov", "cor", "cov2cor",
    "weighted_mean", "scale", "approx", "approxfun", "filter", "optimize", "optimise",
    "uniroot", "optim", "optimhess", "nlminb", "lm_fit", "lm", "poly", "summary_lm", "glm", "binomial",
    "smooth_spline", "predict_smooth_spline", "predict", "density", "bw_nrd0", "fft",
    "hclust", "dist", "as_dist", "p_adjust", "t_test", "rank", "order", "sort", "rle",
    "cut", "findInterval", "tabulate", "ave", "aggregate", "complete_cases", "ecdf",
    "fitted", "coef", "residuals", "seq_len_out", "str_collate",
]


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


def _is_int_like(x):
    if isinstance(x, pd.Series):
        return np.issubdtype(x.dtype, np.integer) or x.dtype == bool
    a = np.asarray(x)
    return np.issubdtype(a.dtype, np.integer) or a.dtype == bool


def _ldsum(a):
    """``sum`` in long double (sequenziell); Rückgabe ``np.longdouble``."""
    a = np.asarray(a)
    if a.size == 0:
        return LD(0)
    return np.cumsum(a.astype(LD))[-1]


def _rsum(a):
    """``sum`` für Doubles (long double; NA/NaN nach der x87-Regel wie R)."""
    return _rn.r_sum(a)


def _rmean(a):
    """``mean`` für Doubles wie R's ``real_mean`` (long double, Korrekturdurchlauf)."""
    return _rn.r_mean(a)


def _rmean_int(a):
    a = np.asarray(a)
    n = a.size
    if n == 0:
        return _NAN
    s = LD(0)
    for v in a.tolist():
        s += LD(v)
    return float(s / LD(n))


def _scalar_or(v, names=None):
    if names is not None:
        return pd.Series(v, index=names)
    if v.size == 1:
        return float(v[0])
    return v


def seq_len_out(frm, to, length_out):
    """``seq.int(from, to, length.out = n)`` (Werte wie R)."""
    n = int(length_out)
    frm = float(frm)
    to = float(to)
    if n <= 0:
        return np.zeros(0)
    out = np.empty(n)
    out[0] = frm
    if n > 1:
        out[n - 1] = to
    if n > 2:
        nint = float(n - 1)
        rby = to - frm
        if math.isfinite(rby):
            rby = rby / nint
            i = np.arange(1, n - 1, dtype=np.float64)
            out[1:n - 1] = frm + i * rby
        else:
            rby = to / nint - frm / nint
            f4 = frm / 4.0
            b4 = rby / 4.0
            i = np.arange(1, n - 1, dtype=np.float64)
            out[1:n - 1] = (f4 + i * b4) * 4.0
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
    n = len(v)
    idx = np.arange(n)
    if n == 0:
        return idx
    if not isstr:
        vv = np.where(v == 0.0, 0.0, v)          # -0 == 0
        if decreasing:
            return np.argsort(-vv, kind="stable")
        return np.argsort(vv, kind="stable")
    # R's orderVector1 mit Scollate: stabil (Gleichstand → Index aufsteigend),
    # auch absteigend (sorted(reverse=True) bleibt stabil)
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
    dec = list(decreasing) if isinstance(decreasing, (list, tuple, np.ndarray)) else [bool(decreasing)] * len(keys)
    if len(dec) == 1:
        dec = dec * len(keys)
    idx = np.arange(n)
    # Lexikographisch: von hinten stabil sortieren
    for (v, na, isstr), d in reversed(list(zip(keys, dec))):
        vv = v[idx]
        nn = na[idx]
        ok = np.where(~nn)[0]
        bad = np.where(nn)[0]
        if isstr:
            sub = _stable_argsort(vv[ok], True, d)
        else:
            sub = _stable_argsort(vv[ok].astype(np.float64), False, d)
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
    if isstr:
        out = np.asarray(x.to_numpy() if isinstance(x, pd.Series) else x, dtype=object)[o]
    else:
        arr = x.to_numpy() if isinstance(x, pd.Series) else np.asarray(x)
        out = np.asarray(arr)[o]
    if names is not None:
        return pd.Series(out, index=[names[i] for i in o])
    return out


def rank(x, na_last=True, ties_method="average"):
    """``rank(x, na.last, ties.method)``.

    ``ties_method``: ``"average"`` (double), ``"first"``, ``"last"``,
    ``"min"``, ``"max"`` (integer). ``na_last``: ``True``, ``False``,
    ``None`` (= ``NA``, entfernen) oder ``"keep"``.
    """
    names = None
    if isinstance(x, pd.Series):
        names = None if isinstance(x.index, pd.RangeIndex) else list(x.index)
    v, na, isstr = _keys(x)
    nas = na
    xs = v[~nas]
    m = len(xs)
    if ties_method in ("average", "min", "max"):
        o = _stable_argsort(xs if isstr else xs.astype(np.float64), isstr, False)
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


def rle(x):
    """``rle(x)``: ``RList`` mit ``lengths`` (int) und ``values``."""
    a = np.asarray(x.to_numpy() if isinstance(x, pd.Series) else x)
    n = a.size
    res = _RLE()
    if n == 0:
        res["lengths"] = np.zeros(0, dtype=np.int64)
        res["values"] = a
        return res
    if a.dtype.kind == "f":
        y = a[1:] != a[:-1]
        nay = np.isnan(a[1:]) | np.isnan(a[:-1])
        y = y | nay
    elif a.dtype == object:
        y = np.array([(p is None or q is None) or (p != q) for p, q in zip(a[1:], a[:-1])], dtype=bool)
    else:
        y = a[1:] != a[:-1]
    i = np.concatenate([np.where(y)[0] + 1, [n]])
    res["lengths"] = np.diff(np.concatenate([[0], i])).astype(np.int64)
    res["values"] = a[i - 1]
    return res


class _RLE(RList):
    r_class = ("rle",)


def tabulate(bin, nbins=None):
    """``tabulate(bin, nbins = max(1, bin, na.rm = TRUE))``."""
    b, _ = _vec(bin)
    with np.errstate(invalid="ignore"):
        b = np.where(np.isnan(b), np.nan, np.trunc(b))
    if nbins is None:
        bb = b[~np.isnan(b)]
        nbins = int(max([1.0] + ([float(bb.max())] if bb.size else [])))
    nbins = int(nbins)
    out = np.zeros(nbins, dtype=np.int64)
    ok = ~np.isnan(b)
    bi = b[ok].astype(np.int64)
    bi = bi[(bi >= 1) & (bi <= nbins)]
    np.add.at(out, bi - 1, 1)
    return out


def _bisect_right(vec, x):
    """Index ``lo`` (0-basiert) mit vec[lo] <= x < vec[lo+1] (Bisektion wie R)."""
    return np.searchsorted(vec, x, side="right") - 1


def findInterval(x, vec, rightmost_closed=False, all_inside=False, left_open=False):
    """``findInterval(x, vec, rightmost.closed, all.inside, left.open)``."""
    v, _ = _vec(vec)
    xx, _ = _vec(x)
    if np.isnan(v).any() or (v.size > 1 and (np.diff(v) < 0).any()):
        raise RError("'vec' must be sorted non-decreasingly and not contain NAs")
    n = v.size
    out = np.full(xx.size, -1, dtype=np.int64)
    nas = np.isnan(xx)
    xv = xx[~nas]
    if left_open:
        r = np.searchsorted(v, xv, side="left")
        if rightmost_closed and n > 0:
            r = np.where(xv == v[0], 1, r)
    else:
        r = np.searchsorted(v, xv, side="right")
        if rightmost_closed and n > 0:
            r = np.where(xv == v[n - 1], n - 1, r)
    if all_inside and n > 0:
        r = np.clip(r, 1, max(1, n - 1))
    res = np.empty(xx.size, dtype=np.float64)
    res[~nas] = r
    res[nas] = NA_REAL
    if nas.any():
        return res
    return res.astype(np.int64)


def _bincode(x, breaks, right=True, include_lowest=False):
    B = np.asarray(breaks, dtype=np.float64)
    nb1 = B.size - 1
    lft = not right
    out = np.full(x.size, NA_REAL)
    for i, xi in enumerate(x.tolist()):
        if xi != xi:
            continue
        lo, hi = 0, nb1
        if xi < B[lo] or B[hi] < xi or (xi == B[hi if lft else lo] and not include_lowest):
            continue
        while hi - lo >= 2:
            new = (hi + lo) // 2
            if xi > B[new] or (lft and xi == B[new]):
                lo = new
            else:
                hi = new
        out[i] = lo + 1
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
        rx = (float(ok.min()), float(ok.max())) if ok.size else (math.inf, -math.inf)
        dx = rx[1] - rx[0]
        if dx == 0:
            dx = abs(rx[0]) if rx[0] != 0 else 1.0
            br = seq_len_out(rx[0] - dx / 1000, rx[1] + dx / 1000, nb)
        else:
            br = seq_len_out(rx[0], rx[1], nb)
            br[0] = rx[0] - dx / 1000
            br[nb - 1] = rx[1] + dx / 1000
    else:
        br = np.sort(br)
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
        labs = [str(s) for s in labels]
        if len(labs) != nb - 1:
            raise RError("number of intervals and length of 'labels' differ")
    code = _bincode(xv, br, right, include_lowest)
    if codes_only:
        if np.isnan(code).any():
            return code
        return code.astype(np.int64)
    with np.errstate(invalid="ignore"):
        codes = np.where(np.isnan(code), -1, code - 1).astype(np.int64)
    return pd.Categorical.from_codes(codes, categories=labs, ordered=ordered_result)


def complete_cases(*args):
    """``complete.cases(...)`` für Vektoren, Matrizen und data.frames."""
    n = None
    ok = None
    for a in args:
        if isinstance(a, pd.DataFrame):
            cols = [a[c].to_numpy() for c in a.columns]
        elif isinstance(a, np.ndarray) and a.ndim == 2:
            cols = [a[:, j] for j in range(a.shape[1])]
        elif isinstance(a, (list, tuple)) and a and isinstance(a[0], (list, tuple, np.ndarray, pd.Series)):
            cols = list(a)
        else:
            cols = [a.to_numpy() if isinstance(a, pd.Series) else np.asarray(a)]
        for c in cols:
            c = np.asarray(c)
            if c.dtype.kind == "f":
                m = ~np.isnan(c)
            elif c.dtype.kind == "M":
                m = ~np.isnat(c)
            elif c.dtype == object:
                m = np.array([not (v is None or (isinstance(v, float) and v != v) or v is pd.NaT) for v in c],
                             dtype=bool)
            else:
                m = np.ones(c.shape[0], dtype=bool)
            if n is None:
                n = m.size
                ok = m.copy()
            else:
                if m.size != n:
                    raise RError("not all arguments have the same length")
                ok &= m
    if ok is None:
        raise RError("no input has determined the number of cases")
    return ok


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
# das Ergebnis von quantile()/median() vom Sortierverfahren ab; daher exakt
# wie R: bis 10 Indizes psort (rPsort2/Psort0), sonst R_qsort (Singleton).

def _rcmp(a, b):
    if a < b:
        return -1
    if a > b:
        return 1
    return 0


def _rpsort2(x, lo, hi, k):
    L, R = lo, hi
    while L < R:
        v = x[k]
        i, j = L, R
        while i <= j:
            while _rcmp(x[i], v) < 0:
                i += 1
            while _rcmp(v, x[j]) < 0:
                j -= 1
            if i <= j:
                x[i], x[j] = x[j], x[i]
                i += 1
                j -= 1
        if j < k:
            L = i
        if k < i:
            R = j


def _psort0(x, lo, hi, ind):
    nind = len(ind)
    if nind < 1 or hi - lo < 1:
        return
    if nind <= 1:
        _rpsort2(x, lo, hi, ind[0] - 1)
        return
    this = 0
    mid = (lo + hi) // 2
    for i in range(nind):
        if ind[i] - 1 <= mid:
            this = i
    z = ind[this] - 1
    _rpsort2(x, lo, hi, z)
    _psort0(x, lo, z - 1, ind[:this])
    _psort0(x, z + 1, hi, ind[this + 1:])


def _r_qsort(v):
    """R_qsort(v, 1, n) (Singleton 1969, R's qsort-body.c), in place."""
    n = len(v)
    if n < 2:
        return
    v.insert(0, 0.0)            # 1-basiert
    il = [0] * 40
    iu = [0] * 40
    R = 0.375
    i, j = 1, n
    ii = i
    m = 1
    state = "L10"
    while True:
        if state == "L10":
            if i < j:
                if R < 0.5898437:
                    R += 0.0390625
                else:
                    R -= 0.21875
                state = "L20"
            else:
                state = "L80"
            continue
        if state == "L20":
            k = i
            ij = int(i + int((j - i) * R))
            vt = v[ij]
            if v[i] > vt:
                v[ij] = v[i]
                v[i] = vt
                vt = v[ij]
            l = j
            if v[j] < vt:
                v[ij] = v[j]
                v[j] = vt
                vt = v[ij]
                if v[i] > vt:
                    v[ij] = v[i]
                    v[i] = vt
                    vt = v[ij]
            while True:
                l -= 1
                while v[l] > vt:
                    l -= 1
                vtt = v[l]
                k += 1
                while v[k] < vt:
                    k += 1
                if k > l:
                    break
                v[l] = v[k]
                v[k] = vtt
            m += 1
            if l - i <= j - k:
                il[m] = k
                iu[m] = j
                j = l
            else:
                il[m] = i
                iu[m] = l
                i = k
            state = "L90"
            continue
        if state == "L80":
            if m == 1:
                break
            i = il[m]
            j = iu[m]
            m -= 1
            state = "L90"
            continue
        if state == "L90":
            if j - i > 10:
                state = "L20"
                continue
            if i == ii:
                state = "L10"
                continue
            i -= 1
            state = "L100"
            continue
        if state == "L100":
            while True:
                i += 1
                if i == j:
                    break
                vt = v[i + 1]
                if not (v[i] <= vt):
                    break
            if i == j:
                state = "L80"
                continue
            k = i
            while True:
                v[k + 1] = v[k]
                k -= 1
                if not (vt < v[k]):
                    break
            v[k + 1] = vt
            state = "L100"
            continue
    del v[0]


def sort_partial(x, partial):
    """``sort(x, partial = partial)`` für Doubles ohne NA wie R (1-basierte Indizes)."""
    v = [float(t) for t in np.asarray(x, dtype=np.float64).ravel()]
    part = sorted({int(t) for t in np.asarray(partial).ravel()}) if np.size(partial) else []
    praw = list(np.asarray(partial).ravel()) if np.size(partial) else []
    if len(praw) <= 10:
        _psort0(v, 0, len(v) - 1, sorted(int(t) for t in praw))
    else:
        _r_qsort(v)
    del part
    return np.array(v, dtype=np.float64)


def _r_unique(a):
    """``unique()`` für Doubles (Reihenfolge des ersten Auftretens)."""
    out = []
    seen = set()
    for t in np.asarray(a, dtype=np.float64).ravel().tolist():
        key = t if t == t else "nan"
        if key not in seen:
            seen.add(key)
            out.append(t)
    return np.array(out, dtype=np.float64)

def quantile(x, probs=(0.0, 0.25, 0.5, 0.75, 1.0), na_rm=False, names=True, type=7, digits=7):
    """``quantile.default(x, probs, na.rm, names, type)`` (Typen 1–9).

    Ergebnis: ``Series`` (mit Namen wie ``"25%"``) bzw. bei ``names=False``
    ``ndarray`` (Länge 1: ``float``).
    """
    xv, _ = _vec(x)
    if na_rm:
        xv = xv[~np.isnan(xv)]
    elif np.isnan(xv).any():
        raise RError("missing values and NaN's not allowed if 'na.rm' is FALSE")
    scalar_p = np.ndim(probs) == 0
    p = np.atleast_1d(np.asarray(probs, dtype=np.float64)).ravel()
    eps = 100 * _DBL_EPS
    pok = ~np.isnan(p)
    with np.errstate(invalid="ignore"):
        if (pok & ((p < -eps) | (p > 1 + eps))).any():
            raise RError("'probs' outside [0,1]")
    n = xv.size
    pp = np.where(np.isnan(p), p, np.maximum(0.0, np.minimum(1.0, p)))
    np_ = pp.size
    if n == 0:
        xs = xv.copy()
    elif int(type) == 7:
        with np.errstate(invalid="ignore"):
            _idx = 1 + max(n - 1, 0) * pp
            _part = _r_unique(np.concatenate([np.floor(_idx), np.ceil(_idx)])[np.concatenate([pok, pok])])
        xs = sort_partial(xv, _part)
    else:
        _t = int(type)
        with np.errstate(invalid="ignore"):
            if _t <= 3:
                _nppm = n * pp - 0.5 if _t == 3 else n * pp
                _j = np.floor(_nppm)
            else:
                _a, _b = {4: (0.0, 1.0), 5: (0.5, 0.5), 6: (0.0, 0.0), 8: (1.0 / 3, 1.0 / 3),
                          9: (3.0 / 8, 3.0 / 8)}[_t]
                _j = np.floor(_a + pp * (n + 1 - _a - _b) + 4 * _DBL_EPS)
            _m1 = pok & (_j > 0) & (_j <= n)
            _m2 = pok & (_j > 0) & (_j < n)
            _part = _r_unique(np.concatenate([[1.0], _j[_m1], (_j + 1)[_m2], [float(n)]]))
        xs = sort_partial(xv, _part)
    qs = np.full(np_, NA_REAL)
    type = int(type)
    with np.errstate(invalid="ignore"):
        if type == 7:
            index = 1 + max(n - 1, 0) * pp
            lo = np.floor(index)
            hi = np.ceil(index)
            for k in range(np_):
                if not pok[k]:
                    continue
                l = int(lo[k])
                h = int(hi[k])
                xl = xs[l - 1] if 1 <= l <= n else NA_REAL      # x[lo] außerhalb: NA
                xh = xs[h - 1] if 1 <= h <= n else NA_REAL
                q = xl
                if index[k] > lo[k] and xh == xh and q == q and xh != q:
                    hh = (index - lo)[k]
                    q = (1 - hh) * q + hh * xh
                qs[k] = q
        else:
            if type <= 3:
                nppm = n * pp - 0.5 if type == 3 else n * pp
                j = np.floor(nppm)
                if type == 1:
                    h = ((~pok) | (nppm > j)).astype(np.float64)
                elif type == 2:
                    h = ((nppm > j).astype(np.float64) + 1) / 2
                else:
                    h = ((~pok) | (nppm != j) | (np.mod(j, 2.0) == 1.0)).astype(np.float64)
            else:
                a, b = {4: (0.0, 1.0), 5: (0.5, 0.5), 6: (0.0, 0.0), 7: (1.0, 1.0),
                        8: (1.0 / 3, 1.0 / 3), 9: (3.0 / 8, 3.0 / 8)}[type]
                fuzz = 4 * _DBL_EPS
                nppm = a + pp * (n + 1 - a - b)
                j = np.floor(nppm + fuzz)
                h = nppm - j
                sml = np.abs(h) < fuzz
                h = np.where(sml & ~np.isnan(h), 0.0, h)
            if n > 0:
                xx = np.concatenate([[xs[0], xs[0]], xs, [xs[n - 1], xs[n - 1]]])
            else:
                xx = np.full(2, NA_REAL)            # c(x[1], x[1], x, x[0], x[0])
            for k in range(np_):
                jk = j[k]
                if jk != jk:
                    continue
                jj = int(jk)
                i2 = jj + 2
                i3 = jj + 3
                x2 = xx[i2 - 1] if 1 <= i2 <= xx.size else NA_REAL
                x3 = xx[i3 - 1] if 1 <= i3 <= xx.size else NA_REAL
                hk = h[k]
                q = x2
                if hk == hk and hk == 1:
                    q = x3
                a = None if hk != hk else bool(0 < hk)
                b = None if hk != hk else bool(hk < 1)
                c = None if (x2 != x2 or x3 != x3) else bool(x2 != x3)
                if a is False or b is False or c is False:
                    other = False
                else:
                    other = True
                if other:
                    q = (1 - hk) * x2 + hk * x3
                qs[k] = q
    qs = np.where(pok, qs, p)
    if names and np_ > 0:
        return pd.Series(qs, index=_format_perc(pp, digits))
    if np_ == 1 and scalar_p:
        return float(qs[0])
    if np_ == 1:
        return float(qs[0])
    return qs


def median(x, na_rm=False):
    """``median.default(x, na.rm)``."""
    is_int = _is_int_like(x)
    xv, _ = _vec(x)
    if na_rm:
        xv = xv[~np.isnan(xv)]
    elif np.isnan(xv).any():
        return NA_REAL                  # x[NA_integer_]
    n = xv.size
    if n == 0:
        return NA_REAL
    half = (n + 1) // 2
    s = np.sort(xv) if is_int else sort_partial(xv, [half] if n % 2 == 1 else [half, half + 1])
    if n % 2 == 1:
        v = s[half - 1]
        return int(v) if is_int else float(v)
    pair = s[half - 1:half + 1]
    if is_int:
        return _rmean_int(pair.astype(np.int64))
    return _rmean(pair)


def weighted_mean(x, w=None, na_rm=False):
    """``weighted.mean(x, w, na.rm)``."""
    xv, _ = _vec(x)
    if w is None:
        if na_rm:
            xv = xv[~np.isnan(xv)]
        with np.errstate(all="ignore"):
            r = float(np.float64(_rsum(xv)) / np.float64(xv.size))
        return _arith_nan(r, xv)
    wv, _ = _vec(w)
    if wv.size != xv.size:
        raise RError("'x' and 'w' must have the same length")
    if na_rm:
        i = ~np.isnan(xv)
        wv = wv[i]
        xv = xv[i]
    with np.errstate(all="ignore"):
        prod = xv * wv
        # (x*w)[w != 0]: NA im Index (w NA/NaN) liefert NA
        sel = (wv != 0) | np.isnan(wv)
        prod = np.where(np.isnan(wv), NA_REAL, prod)[sel]
        r = float(np.float64(_rsum(prod)) / np.float64(_rsum(wv)))
    return _arith_nan(r, prod, wv)


def _arith_nan(r, *operands):
    """Arithmetisch entstandenes NaN (keine NA in den Operanden) → R's ``NaN`` (``math.nan``)."""
    if r == r or any(np.isnan(o).any() for o in operands):
        return r
    return math.nan


# ── cov / cor (cov.c) ────────────────────────────────────────────────────

_USE = ["all.obs", "complete.obs", "pairwise.complete.obs", "everything", "na.or.complete"]


def _pmatch_use(use):
    hits = [i for i, u in enumerate(_USE) if u.startswith(use)]
    if len(hits) != 1:
        if use in _USE:
            return _USE.index(use) + 1
        raise RError("invalid 'use' argument")
    return hits[0] + 1


def _as_cov_input(x):
    """→ (Matrix n×nc float64, ist_matrix, colnames)."""
    if isinstance(x, pd.DataFrame):
        a = np.asarray(x.to_numpy(dtype=np.float64), dtype=np.float64)
        cn = None if isinstance(x.columns, pd.RangeIndex) else [str(c) for c in x.columns]
        return a, True, cn
    if isinstance(x, pd.Series):
        return x.to_numpy(dtype=np.float64).reshape(-1, 1), False, None
    a = np.asarray(x)
    if a.dtype == object:
        a = np.array([np.nan if v is None else v for v in a.ravel()], dtype=np.float64).reshape(a.shape)
    a = a.astype(np.float64)
    if a.ndim == 2:
        return a, True, None
    return a.reshape(-1, 1), False, None


def _mean_ind(col, ind, nobs):
    """MEAN-Makro: zwei Durchläufe in long double; Ergebnis double."""
    xl = col[ind].astype(LD)
    s = np.cumsum(xl)[-1] if xl.size else LD(0)
    tmp = s / LD(nobs)
    if math.isfinite(float(tmp)):
        s2 = np.cumsum(xl - tmp)[-1] if xl.size else LD(0)
        tmp = tmp + s2 / LD(nobs)
    return float(tmp)


def _sign(a):
    return np.sign(a)


def _kendall_sum(xx, yy):
    """sum_k sum_n1 sign(xx[k]-xx[n1]) * sign(yy[k]-yy[n1]) (exakt, ganzzahlig)."""
    n = xx.size
    tot = 0
    step = max(1, 4000000 // max(1, n))
    for s in range(0, n, step):
        e = min(n, s + step)
        sx = np.sign(xx[s:e, None] - xx[None, :])
        sy = np.sign(yy[s:e, None] - yy[None, :])
        tot += int(np.sum(sx * sy, dtype=np.int64)) if True else 0
    return float(tot)


def _kendall_count_ne(xx):
    n = xx.size
    tot = 0
    step = max(1, 4000000 // max(1, n))
    for s in range(0, n, step):
        e = min(n, s + step)
        tot += int(np.count_nonzero(xx[s:e, None] != xx[None, :]))
    return float(tot)


def _corcov(x, y, method_na, kendall, cor):
    X, xmat, xcn = _as_cov_input(x)
    n, ncx = X.shape
    ansmat = xmat
    if y is None:
        Y = None
        ncy = ncx
        ycn = None
    else:
        Y, ymat, ycn = _as_cov_input(y)
        if ymat:
            if Y.shape[0] != n:
                raise RError("incompatible dimensions")
            ansmat = True
        else:
            if Y.shape[0] != n:
                raise RError("incompatible dimensions")
        ncy = Y.shape[1]
    na_fail = False
    everything = False
    empty_err = True
    pair = False
    if method_na == 1:
        na_fail = True
    elif method_na == 2:
        if X.size == 0:
            raise RError("no complete element pairs")
    elif method_na == 3:
        pair = True
    elif method_na == 4:
        everything = True
        empty_err = False
    elif method_na == 5:
        empty_err = False
    else:
        raise RError("invalid 'use' (computational method)")
    if empty_err and X.size == 0:
        raise RError("'x' is empty")
    ans = np.full((ncx, ncy), NA_REAL)
    sd0 = [False]
    with np.errstate(all="ignore"):
        if Y is None:
            if everything:
                has_na = np.isnan(X).any(axis=0) if n else np.zeros(ncx, dtype=bool)
                _cov_na_1(X, has_na, ans, sd0, cor, kendall)
            elif not pair:
                ind = _complete(X, None, na_fail)
                _cov_complete1(X, ind, ans, sd0, cor, kendall)
                if empty_err and not ind.any():
                    raise RError("no complete element pairs")
            else:
                _cov_pairwise(X, X, ans, sd0, cor, kendall, sym=True)
        else:
            if everything:
                hx = np.isnan(X).any(axis=0) if n else np.zeros(ncx, dtype=bool)
                hy = np.isnan(Y).any(axis=0) if n else np.zeros(ncy, dtype=bool)
                _cov_na_2(X, Y, hx, hy, ans, sd0, cor, kendall)
            elif not pair:
                ind = _complete(X, Y, na_fail)
                _cov_complete2(X, Y, ind, ans, sd0, cor, kendall)
                if empty_err and not ind.any():
                    raise RError("no complete element pairs")
            else:
                _cov_pairwise(X, Y, ans, sd0, cor, kendall, sym=False)
    if sd0[0]:
        _warn("the standard deviation is zero")
    if ansmat:
        if y is None:
            rn = cn = xcn
        else:
            rn, cn = xcn, ycn
        return _out(ans, rn, cn)
    v = ans.ravel(order="F")
    if v.size == 1:
        return float(v[0])
    return v


def _complete(X, Y, na_fail):
    ind = ~np.isnan(X).any(axis=1)
    if Y is not None:
        ind &= ~np.isnan(Y).any(axis=1)
    if na_fail and not ind.all():
        raise RError("missing observations in cov/cor")
    return ind


def _ld_cross(a, am, b, bm):
    """sum (LD)(a - am) * (b - bm) mit am, bm als long double."""
    if a.size == 0:
        return LD(0)
    d1 = a.astype(LD) - LD(am)
    d2 = b.astype(LD) - LD(bm)
    return np.cumsum(d1 * d2)[-1]


def _clamp(v):
    return 1.0 if v >= 1.0 else (-1.0 if v <= -1.0 else v)


def _cov_complete1(X, ind, ans, sd0, cor, kendall):
    n, ncx = X.shape
    nobs = int(ind.sum())
    if nobs <= 1:
        ans[:, :] = NA_REAL
        return
    xm = np.zeros(ncx)
    if not kendall:
        for i in range(ncx):
            xm[i] = _mean_ind(X[:, i], ind, nobs)
        n1 = nobs - 1
    Xi = X[ind]
    for i in range(ncx):
        if not kendall:
            for j in range(i + 1):
                s = _ld_cross(Xi[:, i], xm[i], Xi[:, j], xm[j])
                ans[i, j] = ans[j, i] = float(s / LD(n1))
        else:
            for j in range(i + 1):
                s = _kendall_sum(Xi[:, i], Xi[:, j])
                ans[i, j] = ans[j, i] = s
    if cor:
        for i in range(ncx):
            xm[i] = math.sqrt(ans[i, i]) if ans[i, i] >= 0 else _NAN
        for i in range(ncx):
            for j in range(i):
                if xm[i] == 0 or xm[j] == 0:
                    sd0[0] = True
                    ans[i, j] = ans[j, i] = NA_REAL
                else:
                    s = ans[i, j] / (xm[i] * xm[j])
                    ans[i, j] = ans[j, i] = _clamp(s)
            ans[i, i] = 1.0


def _mean_all(col):
    n = col.size
    xl = col.astype(LD)
    s = np.cumsum(xl)[-1]
    tmp = s / LD(n)
    if math.isfinite(float(tmp)):
        s2 = np.cumsum(xl - tmp)[-1]
        tmp = tmp + s2 / LD(n)
    return float(tmp)


def _cov_na_1(X, has_na, ans, sd0, cor, kendall):
    n, ncx = X.shape
    if n <= 1:
        ans[:, :] = NA_REAL
        return
    # kendall: R lässt xm[] für NA-Spalten uninitialisiert (kein sd_0-Treffer)
    xm = np.full(ncx, _NAN)
    if not kendall:
        for i in range(ncx):
            xm[i] = NA_REAL if has_na[i] else _mean_all(X[:, i])
        n1 = n - 1
    for i in range(ncx):
        if has_na[i]:
            ans[i, :i + 1] = NA_REAL
            ans[:i + 1, i] = NA_REAL
            continue
        for j in range(i + 1):
            if has_na[j]:
                ans[i, j] = ans[j, i] = NA_REAL
            elif not kendall:
                s = _ld_cross(X[:, i], xm[i], X[:, j], xm[j])
                ans[i, j] = ans[j, i] = float(s / LD(n1))
            else:
                ans[i, j] = ans[j, i] = _kendall_sum(X[:, i], X[:, j])
    if cor:
        for i in range(ncx):
            if not has_na[i]:
                xm[i] = math.sqrt(ans[i, i]) if ans[i, i] >= 0 else _NAN
        for i in range(ncx):
            if not has_na[i]:
                for j in range(i):
                    if xm[i] == 0 or xm[j] == 0:
                        sd0[0] = True
                        ans[i, j] = ans[j, i] = NA_REAL
                    else:
                        s = ans[i, j] / (xm[i] * xm[j])
                        ans[i, j] = ans[j, i] = _clamp(s)
            ans[i, i] = 1.0


def _sdev2(col, m, n1, kendall):
    """COV_SDEV aus cov_complete2/cov_na_2: (double) SQRTL(sum)."""
    if not kendall:
        s = _ld_cross(col, m, col, m) / LD(n1)
    else:
        s = LD(_kendall_count_ne(col))
    return float(np.sqrt(s))


def _cov_complete2(X, Y, ind, ans, sd0, cor, kendall):
    n, ncx = X.shape
    ncy = Y.shape[1]
    nobs = int(ind.sum())
    if nobs <= 1:
        ans[:, :] = NA_REAL
        return
    xm = np.zeros(ncx)
    ym = np.zeros(ncy)
    n1 = nobs - 1
    if not kendall:
        for i in range(ncx):
            xm[i] = _mean_ind(X[:, i], ind, nobs)
        for i in range(ncy):
            ym[i] = _mean_ind(Y[:, i], ind, nobs)
    Xi = X[ind]
    Yi = Y[ind]
    for i in range(ncx):
        for j in range(ncy):
            if not kendall:
                s = _ld_cross(Xi[:, i], xm[i], Yi[:, j], ym[j])
                ans[i, j] = float(s / LD(n1))
            else:
                ans[i, j] = _kendall_sum(Xi[:, i], Yi[:, j])
    if cor:
        xs = np.array([_sdev2(Xi[:, i], xm[i], n1, kendall) for i in range(ncx)])
        ys = np.array([_sdev2(Yi[:, j], ym[j], n1, kendall) for j in range(ncy)])
        for i in range(ncx):
            for j in range(ncy):
                if xs[i] == 0.0 or ys[j] == 0.0:
                    sd0[0] = True
                    ans[i, j] = NA_REAL
                else:
                    ans[i, j] = _clamp(ans[i, j] / (xs[i] * ys[j]))


def _cov_na_2(X, Y, hx, hy, ans, sd0, cor, kendall):
    n, ncx = X.shape
    ncy = Y.shape[1]
    if n <= 1:
        ans[:, :] = NA_REAL
        return
    xm = np.zeros(ncx)
    ym = np.zeros(ncy)
    n1 = n - 1
    if not kendall:
        for i in range(ncx):
            xm[i] = NA_REAL if hx[i] else _mean_all(X[:, i])
        for i in range(ncy):
            ym[i] = NA_REAL if hy[i] else _mean_all(Y[:, i])
    for i in range(ncx):
        if hx[i]:
            ans[i, :] = NA_REAL
            continue
        for j in range(ncy):
            if hy[j]:
                ans[i, j] = NA_REAL
            elif not kendall:
                ans[i, j] = float(_ld_cross(X[:, i], xm[i], Y[:, j], ym[j]) / LD(n1))
            else:
                ans[i, j] = _kendall_sum(X[:, i], Y[:, j])
    if cor:
        xs = np.array([NA_REAL if hx[i] else _sdev2(X[:, i], xm[i], n1, kendall) for i in range(ncx)])
        ys = np.array([NA_REAL if hy[j] else _sdev2(Y[:, j], ym[j], n1, kendall) for j in range(ncy)])
        for i in range(ncx):
            if hx[i]:
                continue
            for j in range(ncy):
                if hy[j]:
                    continue
                if xs[i] == 0.0 or ys[j] == 0.0:
                    sd0[0] = True
                    ans[i, j] = NA_REAL
                else:
                    ans[i, j] = _clamp(ans[i, j] / (xs[i] * ys[j]))


def _cov_pairwise(X, Y, ans, sd0, cor, kendall, sym):
    n, ncx = X.shape
    ncy = Y.shape[1]
    for i in range(ncx):
        jr = range(i + 1) if sym else range(ncy)
        for j in jr:
            xx = X[:, i]
            yy = Y[:, j]
            ok = ~(np.isnan(xx) | np.isnan(yy))
            nobs = int(ok.sum())
            if nobs >= 2:
                xo = xx[ok]
                yo = yy[ok]
                if not kendall:
                    xmean = np.cumsum(xo.astype(LD))[-1] / LD(nobs)
                    ymean = np.cumsum(yo.astype(LD))[-1] / LD(nobs)
                    n1 = nobs - 1
                    xmd = xo.astype(LD) - xmean
                    ymd = yo.astype(LD) - ymean
                    s = np.cumsum(xmd * ymd)[-1]
                    xsd = np.cumsum(xmd * xmd)[-1]
                    ysd = np.cumsum(ymd * ymd)[-1]
                else:
                    # sum over k, n1 < k (je Paar einmal)
                    s = LD(0)
                    xsd = LD(0)
                    ysd = LD(0)
                    m = xo.size
                    for k in range(m):
                        sx = np.sign(xo[k] - xo[:k])
                        sy = np.sign(yo[k] - yo[:k])
                        s += LD(float(np.sum(sx * sy)))
                        xsd += LD(float(np.sum(sx * sx)))
                        ysd += LD(float(np.sum(sy * sy)))
                if cor:
                    if xsd == 0 or ysd == 0:
                        sd0[0] = True
                        val = NA_REAL
                    else:
                        if not kendall:
                            xsd = xsd / LD(n1)
                            ysd = ysd / LD(n1)
                            s = s / LD(n1)
                        s = s / (np.sqrt(xsd) * np.sqrt(ysd))
                        s = LD(1) if s >= 1 else (LD(-1) if s <= -1 else s)
                        val = float(s)
                elif not kendall:
                    val = float(s / LD(n1))
                else:
                    val = float(s)
                ans[i, j] = val
            else:
                ans[i, j] = NA_REAL
            if sym:
                ans[j, i] = ans[i, j]


def _rank_cols(u):
    """``Rank`` aus cor(): Ränge (na.last = "keep") je Spalte."""
    if isinstance(u, pd.DataFrame):
        a = u.to_numpy(dtype=np.float64)
        out = np.column_stack([np.asarray(rank(a[:, j], na_last="keep"), dtype=np.float64)
                               for j in range(a.shape[1])]) if a.shape[0] > 1 else \
            np.tile(np.arange(1, a.shape[0] + 1, dtype=np.float64)[:, None], (1, a.shape[1]))
        return pd.DataFrame(out, index=u.index, columns=u.columns)
    a = np.asarray(u, dtype=np.float64)
    if a.size == 0:
        return a
    if a.ndim == 2:
        if a.shape[0] > 1:
            return np.column_stack([np.asarray(rank(a[:, j], na_last="keep"), dtype=np.float64)
                                    for j in range(a.shape[1])])
        return np.tile(np.arange(1, a.shape[0] + 1, dtype=np.float64)[:, None], (1, a.shape[1]))
    return np.asarray(rank(a, na_last="keep"), dtype=np.float64)


def _na_omit_rows(x):
    if isinstance(x, pd.DataFrame):
        m = ~np.isnan(x.to_numpy(dtype=np.float64)).any(axis=1)
        return x[m]
    a = np.asarray(x, dtype=np.float64)
    if a.ndim == 2:
        return a[~np.isnan(a).any(axis=1)]
    return a[~np.isnan(a)]


def _drop_rows(x, keep):
    if isinstance(x, pd.DataFrame):
        return x[keep]
    if isinstance(x, pd.Series):
        return x[keep]
    a = np.asarray(x, dtype=np.float64)
    return a[keep] if a.ndim == 1 else a[keep, :]


def _cor_cov(x, y, use, method, cor):
    na_method = _pmatch_use(use)
    if method not in ("pearson", "kendall", "spearman"):
        raise RError("'arg' should be one of “pearson”, “kendall”, “spearman”")
    is_mat = isinstance(x, pd.DataFrame) or (isinstance(x, np.ndarray) and x.ndim == 2)
    if not is_mat and y is None:
        raise RError("supply both 'x' and 'y' or a matrix-like 'x'")
    if method == "pearson":
        return _corcov(x, y, na_method, False, cor)
    kend = method == "kendall"
    if na_method in (2, 5):
        if y is None:
            return _corcov(_rank_cols(_na_omit_rows(x)), None, na_method, kend, cor)
        X, _, _ = _as_cov_input(x)
        Y, _, _ = _as_cov_input(y)
        keep = ~(np.isnan(X).any(axis=1) | np.isnan(Y).any(axis=1))
        return _corcov(_rank_cols(_drop_rows(x, keep)), _rank_cols(_drop_rows(y, keep)), na_method, kend, cor)
    if na_method != 3:
        xr = _rank_cols(x)
        yr = None if y is None else _rank_cols(y)
        return _corcov(xr, yr, na_method, kend, cor)
    if not cor:
        raise RError("cannot handle 'pairwise.complete.obs'")
    # paarweise, Rangkorrelation
    X, xmat, xcn = _as_cov_input(x)
    if y is None:
        ncx = X.shape[1]
        if ncx == 0:
            raise RError("'x' is empty")
        r = np.zeros((ncx, ncx))
        for i in range(ncx):
            for j in range(i + 1):
                x2 = X[:, i]
                y2 = X[:, j]
                ok = ~(np.isnan(x2) | np.isnan(y2))
                r[i, j] = _corcov(np.asarray(rank(x2[ok]), dtype=np.float64),
                                  np.asarray(rank(y2[ok]), dtype=np.float64), 1, kend, True) if ok.any() else NA_REAL
        if ncx == 1:
            # R: r + t(r) - diag(diag(r)); diag() eines Skalars baut eine Einheitsmatrix
            d = r[0, 0]
            if d != d:
                raise RError("invalid 'nrow' value (too large or NA)")
            m = int(d)
            if m < 0:
                raise RError("invalid 'nrow' value (< 0)")
            if m != 1:
                raise RError("non-conformable arrays")
            r = (r + r) - 1.0
        else:
            r = r + r.T - np.diag(np.diag(r))
        return _out(r, xcn, xcn)
    Y, ymat, ycn = _as_cov_input(y)
    if X.size == 0 or Y.size == 0:
        raise RError("both 'x' and 'y' must be non-empty")
    r = np.zeros((X.shape[1], Y.shape[1]))
    for i in range(X.shape[1]):
        for j in range(Y.shape[1]):
            x2 = X[:, i]
            y2 = Y[:, j]
            ok = ~(np.isnan(x2) | np.isnan(y2))
            r[i, j] = _corcov(np.asarray(rank(x2[ok]), dtype=np.float64),
                              np.asarray(rank(y2[ok]), dtype=np.float64), 1, kend, True) if ok.any() else NA_REAL
    if xmat or ymat:
        return _out(r, xcn, ycn)
    return float(r[0, 0]) if r.size == 1 else r.ravel()


def cor(x, y=None, use="everything", method="pearson"):
    """``cor(x, y, use, method)``: pearson, kendall, spearman."""
    return _cor_cov(x, y, use, method, True)


def cov(x, y=None, use="everything", method="pearson"):
    """``cov(x, y, use, method)``."""
    return _cor_cov(x, y, use, method, False)


def var(x, y=None, na_rm=False, use=None):
    """``var(x, y, na.rm, use)``."""
    if use is None:
        use = "na.or.complete" if na_rm else "everything"
    na_method = _pmatch_use(use)
    return _corcov(x, y, na_method, False, False)


def sd(x, na_rm=False):
    """``sd(x, na.rm)`` = ``sqrt(var(x, na.rm))``."""
    if isinstance(x, pd.DataFrame) or (isinstance(x, np.ndarray) and x.ndim == 2):
        x = np.asarray(x, dtype=np.float64).ravel(order="F")
    v = var(x, na_rm=na_rm)
    if v != v:
        return v                        # sqrt(NA) = NA, sqrt(NaN) = NaN
    return math.sqrt(v) if v >= 0 else _NAN


def cov2cor(V):
    """``cov2cor(V)``."""
    m = _as_r(V)
    if not m.is_matrix or m.dim[0] != m.dim[1]:
        raise RError("'V' is not a square numeric matrix")
    p = m.dim[0]
    A = m.mat()
    D = np.diag(A).copy()
    from .fmt import _nan_mask
    with np.errstate(all="ignore"):
        pos = ~np.isnan(D) & (D > 0)
        Is = D.copy()
        Is[pos] = np.sqrt(1.0 / D[pos])
        Is[~pos] = np.nan                      # R: Is[!pos] <- NaN
        if (~pos).any() or (~np.isfinite(Is)).any():
            _warn("diag(V) had non-positive or NA entries; the non-finite result may be dubious")
        r = (Is[:, None] * A) * Is[None, :]
    # R: `Is * V` (Recycling-Schleife) reicht bei zwei NaN-Operanden den aus V
    # durch, `* rep(Is, each = p)` (gleiche Länge) den linken. Ergebnis ist also
    # genau dann NA, wenn V[i,j] NA ist; jedes andere NaN ist R-NaN.
    na_v = np.isnan(A) & ~_nan_mask(A)
    r[np.isnan(r) & ~na_v] = np.nan
    r[na_v] = NA_REAL
    if p:
        r[np.arange(p), np.arange(p)] = 1.0
    return _out(r, m.rn, m.cn)


def scale(x, center=True, scale=True):
    """``scale.default(x, center, scale)``; Ergebnis-Matrix mit Attributen
    ``scaled_center``/``scaled_scale`` (als Attribute des Rückgabeobjekts
    nicht möglich – daher Tupel-frei: ``ndarray`` und ``.attrs`` bei DataFrame)."""
    m = _as_matrix(x)
    X = m.mat()
    nc = X.shape[1]
    cen = None
    sc = None
    with np.errstate(all="ignore"):
        if isinstance(center, (bool, np.bool_)):
            if center:
                cen = np.array([_colmean_narm(X[:, j]) for j in range(nc)])
                X = X - cen[None, :]
        else:
            cen = np.asarray(center, dtype=np.float64).ravel()
            if cen.size != nc:
                raise RError("length of 'center' must equal the number of columns of 'x'")
            X = X - cen[None, :]
        if isinstance(scale, (bool, np.bool_)):
            if scale:
                sc = np.empty(nc)
                for j in range(nc):
                    v = X[:, j]
                    v = v[~np.isnan(v)]
                    sc[j] = math.sqrt(_rsum(v * v) / max(1, v.size - 1))
                X = X / sc[None, :]
        else:
            sc = np.asarray(scale, dtype=np.float64).ravel()
            if sc.size != nc:
                raise RError("length of 'scale' must equal the number of columns of 'x'")
            X = X / sc[None, :]
    out = pd.DataFrame(X, index=m.rn, columns=m.cn)
    out.attrs["scaled:center"] = cen
    out.attrs["scaled:scale"] = sc
    if m.rn is None and m.cn is None:
        res = _ScaledArray(X)
        res.scaled_center = cen
        res.scaled_scale = sc
        return res
    return out


class _ScaledArray(np.ndarray):
    def __new__(cls, a):
        return np.asarray(a).view(cls)

    def __array_finalize__(self, obj):
        self.scaled_center = getattr(obj, "scaled_center", None)
        self.scaled_scale = getattr(obj, "scaled_scale", None)


def _colmean_narm(col):
    ok = col[~np.isnan(col)]
    if ok.size == 0:
        return _NAN
    return float(np.cumsum(ok.astype(LD))[-1] / LD(ok.size))


# ── approx / filter ──────────────────────────────────────────────────────

def _regularize(x, y, ties, warn_collapsing, na_rm):
    xv, _ = _vec(x)
    if y is None:
        yv = xv
        xv = np.arange(1, xv.size + 1, dtype=np.float64)
    else:
        yv, _ = _vec(y)
    if xv.size != yv.size:
        raise RError("'x' and 'y' lengths differ")
    kept_na = False
    na = np.isnan(xv) | np.isnan(yv)
    ok = ~na
    if na.any():
        if na_rm:
            xv = xv[ok]
            yv = yv[ok]
            nx = xv.size
        else:
            kept_na = True
            nx = int(ok.sum())
    else:
        nx = xv.size
    ordered = False
    fun = ties
    if isinstance(ties, str) and ties == "ordered":
        ordered = True
        fun = None
    elif isinstance(ties, (list, tuple)) and len(ties) == 2 and callable(ties[1]):
        fun = ties[1]
        ordered = ties[0] == "ordered"
    if not (isinstance(ties, str) and ties == "ordered"):
        xx = xv[ok] if kept_na else xv
        if not ordered and xx.size > 1 and (np.diff(xx) < 0).any():
            o = np.argsort(xv, kind="stable")
            xv = xv[o]
            yv = yv[o]
        ux = pd.unique(xv)
        if ux.size < nx:
            if warn_collapsing:
                _warn("collapsing to unique 'x' values")
            if fun is None or fun is _rmean or fun == "mean":
                f = _rmean
            else:
                f = fun
            groups = {}
            keys = []
            for xi, yi in zip(xv.tolist(), yv.tolist()):
                k = xi if xi == xi else "NA"
                if k not in groups:
                    groups[k] = []
                    keys.append(k)
                groups[k].append(yi)
            yv = np.array([float(f(np.array(groups[k]))) for k in keys])
            xv = np.asarray(ux, dtype=np.float64)
            if kept_na:
                ok = ~np.isnan(xv)
    return xv, yv, kept_na, (ok if kept_na else None)


def _approx_core(x, y, v, method, yleft, yright, f):
    n = x.size
    out = np.empty(v.size)
    if n == 0:
        out[:] = np.nan
        return out
    f2 = f
    f1 = 1 - f
    with np.errstate(all="ignore"):
        for k, vk in enumerate(v.tolist()):
            if vk != vk:
                out[k] = vk
                continue
            i = 0
            j = n - 1
            if vk < x[i]:
                out[k] = yleft
                continue
            if vk > x[j]:
                out[k] = yright
                continue
            while i < j - 1:
                ij = (i + j) // 2
                if vk < x[ij]:
                    j = ij
                else:
                    i = ij
            if vk == x[j]:
                out[k] = y[j]
                continue
            if vk == x[i]:
                out[k] = y[i]
                continue
            if method == 1:
                out[k] = y[i] + (y[j] - y[i]) * ((vk - x[i]) / (x[j] - x[i]))
            else:
                out[k] = (y[i] * f1 if f1 != 0.0 else 0.0) + (y[j] * f2 if f2 != 0.0 else 0.0)
    return out


def _approx_setup(x, y, method, yleft, yright, rule, f, ties, na_rm, ties_missing):
    meth = {"linear": 1, "constant": 2}
    m = [v for k, v in meth.items() if k.startswith(method)] if method else []
    if len(m) != 1:
        raise RError("invalid interpolation method")
    method = m[0]
    rule = list(np.atleast_1d(rule))
    if len(rule) == 1:
        rule = rule * 2
    xv, yv, kept_na, notna = _regularize(x, y, ties, ties_missing, na_rm)
    nona = na_rm or not kept_na
    nx = xv.size if nona else int(notna.sum())
    if nx <= 1:
        if method == 1:
            raise RError("need at least two non-NA values to interpolate")
        if nx == 0:
            raise RError("zero non-NA points")
    if yleft is None:
        yleft = NA_REAL if rule[0] == 1 else float(yv[0])
    if yright is None:
        yright = NA_REAL if rule[1] == 1 else float(yv[-1])
    if method == 2:
        if not math.isfinite(f) or f < 0 or f > 1:
            raise RError("approx(): invalid f value")
    if na_rm:
        if np.isnan(xv).any() or np.isnan(yv).any():
            raise RError("approx(): attempted to interpolate NA values")
    else:
        if np.isnan(xv).any():
            raise RError("approx(x,y, .., na.rm=FALSE): NA values in x are not allowed")
    return xv, yv, method, float(yleft), float(yright), nona, notna, nx


class _XY(RList):
    pass


def approx(x, y=None, xout=None, method="linear", n=50, yleft=None, yright=None, rule=1, f=0,
           ties=None, na_rm=True):
    """``approx(x, y, xout, method, n, yleft, yright, rule, f, ties, na.rm)``.

    ``ties=None`` entspricht R's Voreinstellung ``mean`` (mit Warnung beim
    Zusammenfassen); ``"ordered"``, eine Funktion oder ``("ordered", fun)``.
    Ergebnis: ``RList`` mit ``x`` und ``y``.
    """
    ties_missing = ties is None
    xv, yv, meth, yl, yr, nona, notna, nx = _approx_setup(
        x, y, method, yleft, yright, rule, float(f), _rmean if ties is None else ties, na_rm, ties_missing)
    if xout is None:
        if n <= 0:
            raise RError("'approx' requires n >= 1")
        if nona:
            xo = seq_len_out(xv[0], xv[nx - 1], n)
        else:
            xs = xv[notna]
            xo = seq_len_out(xs[0], xs[-1], n)
    else:
        xo, _ = _vec(xout)
    res = _XY()
    res["x"] = xo if xout is None else (xout if not np.isscalar(xout) else float(xout))
    yo = _approx_core(xv, yv, xo, meth, yl, yr, float(f))
    res["y"] = float(yo[0]) if np.isscalar(xout) else yo
    return res


def approxfun(x, y=None, method="linear", yleft=None, yright=None, rule=1, f=0, ties=None, na_rm=True):
    """``approxfun(...)``: liefert eine Funktion ``v -> y``."""
    ties_missing = ties is None
    xv, yv, meth, yl, yr, nona, notna, nx = _approx_setup(
        x, y, method, yleft, yright, rule, float(f), _rmean if ties is None else ties, na_rm, ties_missing)
    ff = float(f)

    def fun(v):
        vv, _ = _vec(v)
        out = _approx_core(xv, yv, vv, meth, yl, yr, ff)
        if np.isscalar(v):
            return float(out[0])
        return out
    fun.x = xv
    fun.y = yv
    return fun


def filter(x, filter, method="convolution", sides=2, circular=False, init=None):
    """``filter(x, filter, method, sides, circular, init)`` (ohne ts-Attribute)."""
    meth = [m for m in ("convolution", "recursive") if m.startswith(method)]
    if len(meth) != 1:
        raise RError("'arg' should be one of “convolution”, “recursive”")
    method = meth[0]
    X = np.asarray(x.to_numpy() if isinstance(x, (pd.Series, pd.DataFrame)) else x, dtype=np.float64)
    is_mat = X.ndim == 2
    if not is_mat:
        X = X.reshape(-1, 1)
    n, nser = X.shape
    fv = np.atleast_1d(np.asarray(filter, dtype=np.float64)).ravel()
    nf = fv.size
    if np.isnan(fv).any():
        raise RError("missing values in 'filter'")
    Y = np.full((n, nser), NA_REAL)
    with np.errstate(all="ignore"):
        if method == "convolution":
            if nf > n:
                raise RError("'filter' is longer than time series")
            sides = int(sides)
            if sides not in (1, 2):
                raise RError("argument 'sides' must be 1 or 2")
            nshift = nf // 2 if sides == 2 else 0
            for s in range(nser):
                xs = X[:, s]
                if not circular:
                    i = np.arange(n)
                    valid = (i + nshift - (nf - 1) >= 0) & (i + nshift < n)
                    iv = i[valid]
                    z = np.zeros(iv.size)
                    bad = np.zeros(iv.size, dtype=bool)
                    for j in range(nf):
                        t = xs[iv + nshift - j]
                        bad |= np.isnan(t)
                        z = z + fv[j] * t
                    z[bad] = NA_REAL
                    Y[iv, s] = z
                else:
                    i = np.arange(n)
                    z = np.zeros(n)
                    bad = np.zeros(n, dtype=bool)
                    for j in range(nf):
                        ii = i + nshift - j
                        ii = np.where(ii < 0, ii + n, ii)
                        ii = np.where(ii >= n, ii - n, ii)
                        t = xs[ii]
                        bad |= np.isnan(t)
                        z = z + fv[j] * t
                    z[bad] = NA_REAL
                    Y[:, s] = z
        else:
            if init is None:
                ini = np.zeros((nf, nser))
            else:
                ia = np.asarray(init, dtype=np.float64)
                ni = ia.shape[0] if ia.ndim >= 1 else 1
                if ia.ndim == 0:
                    ia = ia.reshape(1)
                    ni = 1
                if ni != nf:
                    raise RError("length of 'init' must equal length of 'filter'")
                ncol = ia.shape[1] if ia.ndim == 2 else 1
                if ncol != 1 and ncol != nser:
                    if nser == 1:
                        raise RError("'init' must have %d column" % nser)
                    raise RError("'init' must have 1 or %d columns" % nser)
                ini = ia.reshape(nf, -1) if ia.ndim == 2 else ia.reshape(nf, 1)
                if ini.shape[1] == 1 and nser > 1:
                    ini = np.repeat(ini, nser, axis=1)
            for s in range(nser):
                r = np.concatenate([ini[::-1, s], np.zeros(n)]).tolist()
                xs = X[:, s].tolist()
                fl = fv.tolist()
                for i in range(n):
                    sm = xs[i]
                    if sm != sm:
                        r[nf + i] = NA_REAL
                        continue
                    badf = False
                    for j in range(nf):
                        tmp = r[nf + i - j - 1]
                        if tmp == tmp:
                            sm += tmp * fl[j]
                        else:
                            r[nf + i] = NA_REAL
                            badf = True
                            break
                    if not badf:
                        r[nf + i] = sm
                Y[:, s] = r[nf:]
    if is_mat:
        return Y
    return Y[:, 0]


# ── optimize / uniroot / optim ───────────────────────────────────────────

class _OptRes(RList):
    pass


def _num1(v, what):
    """Rückgabe einer Zielfunktion als double (``coerceVector``)."""
    if isinstance(v, (pd.Series, pd.DataFrame)):
        v = v.to_numpy()
    a = np.asarray(v, dtype=np.float64).ravel()
    return a


def optimize(f, interval=None, *args, lower=None, upper=None, maximum=False,
             tol=0.0001220703125, **kwargs):
    """``optimize(f, interval, ..., lower, upper, maximum, tol)`` (Brent ``fmin``).

    Ergebnis: ``RList`` mit ``minimum`` (bzw. ``maximum``) und ``objective``.
    """
    if lower is None:
        lower = min(interval)
    if upper is None:
        upper = max(interval)
    lower = float(lower)
    upper = float(upper)
    sgn = -1.0 if maximum else 1.0

    def fcn1(x):
        s = f(x, *args, **kwargs)
        a = _num1(s, "optimize")
        if a.size != 1:
            raise RError("invalid function value in 'optimize'")
        v = float(sgn * a[0]) if maximum else float(a[0])
        if not math.isfinite(v):
            _warn("NA/Inf replaced by maximum positive value")
            return _DBL_MAX
        return v
    if not math.isfinite(lower):
        raise RError("invalid 'xmin' value")
    if not math.isfinite(upper):
        raise RError("invalid 'xmax' value")
    if lower >= upper:
        raise RError("'xmin' not less than 'xmax'")
    tol = float(tol)
    if not math.isfinite(tol) or tol <= 0.0:
        raise RError("invalid 'tol' value")
    from ._optim import brent_fmin
    with np.errstate(all="ignore"):
        val = brent_fmin(lower, upper, fcn1, tol)
    res = _OptRes()
    res["maximum" if maximum else "minimum"] = val
    obj = f(val, *args, **kwargs)
    a = _num1(obj, "")
    res["objective"] = float(a[0]) if a.size == 1 else obj
    return res


optimise = optimize


def uniroot(f, interval=None, *args, lower=None, upper=None, f_lower=None, f_upper=None,
            extendInt="no", check_conv=False, tol=0.0001220703125, maxiter=1000, trace=0, **kwargs):
    """``uniroot(f, interval, ..., lower, upper, f.lower, f.upper, extendInt,
    check.conv, tol, maxiter, trace)``; ``RList`` mit ``root``, ``f_root``
    (R-Name ``f.root``), ``iter``, ``init_it`` (``init.it``), ``estim_prec``
    (``estim.prec``)."""
    from ._optim import zeroin2
    if interval is not None and len(interval) != 2:
        raise RError("'interval' must be a vector of length 2")
    if lower is None:
        lower = min(interval)
    if upper is None:
        upper = max(interval)
    lower = float(lower)
    upper = float(upper)
    if not lower < upper:
        raise RError("lower < upper  is not fulfilled")

    def ff(x):
        v = _num1(f(x, *args, **kwargs), "")
        return float(v[0]) if v.size >= 1 else _NAN
    if f_lower is None:
        f_lower = ff(lower)
    if f_lower != f_lower:
        raise RError("f.lower = f(lower) is NA")
    if f_upper is None:
        f_upper = ff(upper)
    if f_upper != f_upper:
        raise RError("f.upper = f(upper) is NA")
    f_lower = float(f_lower)
    f_upper = float(f_upper)
    sigs = {"yes": None, "downX": -1.0, "no": 0.0, "upX": 1.0}
    ext = [k for k in sigs if k.startswith(extendInt)] if extendInt else []
    if len(ext) != 1:
        raise RError("'arg' should be one of “no”, “yes”, “downX”, “upX”")
    Sig = sigs[ext[0]]

    def trunc(x):
        return max(min(x, _DBL_MAX), -_DBL_MAX) if x == x else x
    flo = trunc(f_lower)
    fup = trunc(f_upper)
    with np.errstate(all="ignore"):
        doX = (Sig is None and flo * fup > 0) or (Sig is not None and (Sig * flo > 0 or Sig * fup < 0))
    it = 0
    if doX:
        if trace:
            print("search in [%s,%s]%s" % (_g(lower), _g(upper), "\n" if trace >= 2 else " ... "), end="")

        def Delta(u):
            return 0.01 * max(1e-4, abs(u))
        if Sig is None:
            delta = [Delta(lower), Delta(upper)]
            while (f_lower * f_upper > 0) and (math.isfinite(lower) or math.isfinite(upper)):
                iF = [math.isfinite(lower), math.isfinite(upper)]
                it += 1
                if it > maxiter:
                    raise RError("no sign change found in %d iterations" % (it - 1))
                if iF[0]:
                    ol, of = lower, f_lower
                    lower = lower - delta[0]
                    f_lower = ff(lower)
                    if f_lower != f_lower:
                        lower, f_lower = ol, of
                        delta[0] = delta[0] / 4
                if iF[1]:
                    ol, of = upper, f_upper
                    upper = upper + delta[1]
                    f_upper = ff(upper)
                    if f_upper != f_upper:
                        upper, f_upper = ol, of
                        delta[1] = delta[1] / 4
                if trace >= 2:
                    print(" .. modified lower,upper: (%15s,%15s)" % (_g(lower), _g(upper)))
                delta = [2 * delta[0], 2 * delta[1]]
        else:
            delta = Delta(lower)
            while Sig * f_lower > 0:
                it += 1
                if it > maxiter:
                    raise RError("no sign change found in %d iterations" % (it - 1))
                lower = lower - delta
                f_lower = ff(lower)
                if trace >= 2:
                    print(" .. modified lower: %s" % _g(lower))
                delta = 2 * delta
            delta = Delta(upper)
            while Sig * f_upper < 0:
                it += 1
                if it > maxiter:
                    raise RError("no sign change found in %d iterations" % (it - 1))
                upper = upper + delta
                f_upper = ff(upper)
                if trace >= 2:
                    print(" .. modified upper: %s" % _g(upper))
                delta = 2 * delta
        if trace and trace < 2:
            print("extended to [%s, %s] in %d steps" % (_g(lower), _g(upper), it))
    sg = lambda v: (0.0 if v == 0 else math.copysign(1.0, v)) if v == v else _NAN  # noqa: E731
    prod = sg(f_lower) * sg(f_upper)
    if not (prod == prod and prod <= 0):
        raise RError("did not succeed extending the interval endpoints for f(lower) * f(upper) <= 0"
                     if doX else "f() values at end points not of opposite sign")
    if doX and it:
        flo = trunc(f_lower)
        fup = trunc(f_upper)
    if not math.isfinite(lower):
        raise RError("invalid 'xmin' value")
    if not math.isfinite(upper):
        raise RError("invalid 'xmax' value")
    if lower >= upper:
        raise RError("'xmin' not less than 'xmax'")
    tol = float(tol)
    if not math.isfinite(tol) or tol <= 0.0:
        raise RError("invalid 'tol' value")
    maxit = int(maxiter)
    if maxit <= 0:
        raise RError("'maxiter' must be positive")
    warned = []

    def fcn2(x):
        v = _num1(f(x, *args, **kwargs), "")
        if v.size != 1:
            raise RError("invalid function value in 'zeroin'")
        val = float(v[0])
        if not math.isfinite(val):
            if val == -math.inf:
                msg = "-Inf replaced by maximally negative value"
                if check_conv:
                    warned.append(msg)
                else:
                    _warn(msg)
                return -_DBL_MAX
            msg = "NA/Inf replaced by maximum positive value"
            if check_conv:
                warned.append(msg)
            else:
                _warn(msg)
            return _DBL_MAX
        return val
    with np.errstate(all="ignore"):
        root, itr, prec = zeroin2(lower, upper, flo, fup, fcn2, tol, maxit)
    if check_conv and warned:
        raise RError("convergence problem in zero finding: " + warned[0])
    itr = int(itr)
    if itr < 0:
        msg = ("_NOT_ converged in %d iteration" if maxiter == 1 else "_NOT_ converged in %d iterations") % maxiter
        if check_conv:
            raise RError(msg)
        _warn(msg)
        itr = int(maxiter)
    if doX:
        itr = itr + it
        init_it = it
    else:
        init_it = NA_REAL               # NA_integer_
    res = _OptRes()
    res["root"] = root
    res["f.root"] = ff(root)
    res["iter"] = itr
    res["init.it"] = init_it
    res["estim.prec"] = prec
    return res


def _g(x):
    return "%g" % x


_OPTIM_METHODS = ("Nelder-Mead", "BFGS", "CG", "L-BFGS-B", "SANN", "Brent")


class _Fn:
    """fminfn/fmingr aus optim.c."""

    def __init__(self, fn, gr, fnscale, parscale, ndeps, names, lower=None, upper=None, usebounds=False):
        self.fn = fn
        self.gr = gr
        self.fnscale = fnscale
        self.parscale = parscale
        self.ndeps = ndeps
        self.names = names
        self.lower = lower
        self.upper = upper
        self.usebounds = usebounds

    def _wrap(self, x):
        a = np.array(x, dtype=np.float64)
        if self.names is not None:
            return pd.Series(a, index=self.names)
        return a

    def _call(self, x):
        s = _num1(self.fn(self._wrap(x)), "")
        if s.size != 1:
            raise RError("objective function in optim evaluates to length %d not 1" % s.size)
        return float(s[0])

    def fminfn(self, p):
        x = []
        for i, pi in enumerate(p):
            if not math.isfinite(pi):
                raise RError("non-finite value supplied by optim")
            x.append(pi * self.parscale[i])
        return self._call(x) / self.fnscale

    def fmingr(self, p):
        n = len(p)
        ps = self.parscale
        if self.gr is not None:
            x = []
            for i in range(n):
                if not math.isfinite(p[i]):
                    raise RError("non-finite value supplied by optim")
                x.append(p[i] * ps[i])
            s = _num1(self.gr(self._wrap(x)), "")
            if s.size != n:
                raise RError("gradient in optim evaluated to length %d not %d" % (s.size, n))
            return [float(s[i]) * ps[i] / self.fnscale for i in range(n)]
        df = [0.0] * n
        x = [p[i] * ps[i] for i in range(n)]
        if not self.usebounds:
            for i in range(n):
                eps = self.ndeps[i]
                x[i] = (p[i] + eps) * ps[i]
                val1 = self._call(x) / self.fnscale
                x[i] = (p[i] - eps) * ps[i]
                val2 = self._call(x) / self.fnscale
                with np.errstate(all="ignore"):
                    df[i] = float(np.float64(val1 - val2) / np.float64(2 * eps))
                if not math.isfinite(df[i]):
                    raise RError("non-finite finite-difference value [%d]" % (i + 1))
                x[i] = p[i] * ps[i]
        else:
            for i in range(n):
                epsused = eps = self.ndeps[i]
                tmp = p[i] + eps
                if tmp > self.upper[i]:
                    tmp = self.upper[i]
                    epsused = tmp - p[i]
                x[i] = tmp * ps[i]
                val1 = self._call(x) / self.fnscale
                tmp = p[i] - eps
                if tmp < self.lower[i]:
                    tmp = self.lower[i]
                    eps = p[i] - tmp
                x[i] = tmp * ps[i]
                val2 = self._call(x) / self.fnscale
                with np.errstate(all="ignore"):
                    df[i] = float(np.float64(val1 - val2) / np.float64(epsused + eps))
                if not math.isfinite(df[i]):
                    raise RError("non-finite finite-difference value [%d]" % (i + 1))
                x[i] = p[i] * ps[i]
        return df


def optim(par, fn, gr=None, *args, method="Nelder-Mead", lower=-math.inf, upper=math.inf,
          control=None, hessian=False, **kwargs):
    """``optim(par, fn, gr, ..., method, lower, upper, control, hessian)``.

    Methoden: ``"Nelder-Mead"``, ``"BFGS"``, ``"CG"``, ``"L-BFGS-B"``,
    ``"Brent"``. ``control`` wie in R (``maxit``, ``reltol``, ``abstol``,
    ``fnscale``, ``parscale``, ``ndeps``, ``factr``, ``pgtol``, ``lmm``,
    ``alpha``, ``beta``, ``gamma``, ``type``, ``trace``, ``REPORT``,
    ``warn.1d.NelderMead``). Ergebnis: ``RList`` mit ``par``, ``value``,
    ``counts`` (Series ``function``/``gradient``), ``convergence``,
    ``message`` (und ``hessian``).
    """
    names = None
    if isinstance(par, pd.Series):
        names = None if isinstance(par.index, pd.RangeIndex) else [str(i) for i in par.index]
        pv = par.to_numpy(dtype=np.float64)
    else:
        pv = np.atleast_1d(np.asarray(par, dtype=np.float64)).ravel()
    fn1 = (lambda p: fn(p, *args, **kwargs))
    gr1 = (lambda p: gr(p, *args, **kwargs)) if gr is not None else None
    meths = [m for m in _OPTIM_METHODS if m.startswith(method)]
    if len(meths) != 1:
        raise RError("'arg' should be one of “Nelder-Mead”, “BFGS”, “CG”, "
                     "“L-BFGS-B”, “SANN”, “Brent”")
    method = meths[0]
    lo = np.atleast_1d(np.asarray(lower, dtype=np.float64)).ravel()
    up = np.atleast_1d(np.asarray(upper, dtype=np.float64)).ravel()
    if ((lo > -math.inf).any() or (up < math.inf).any()) and method not in ("L-BFGS-B", "Brent"):
        _warn("bounds can only be used with method L-BFGS-B (or Brent)")
        method = "L-BFGS-B"
    npar = pv.size
    con = {"trace": 0, "fnscale": 1.0, "parscale": np.ones(npar), "ndeps": np.full(npar, 1e-3),
           "maxit": 100, "abstol": -math.inf, "reltol": math.sqrt(_DBL_EPS), "alpha": 1.0,
           "beta": 0.5, "gamma": 2.0, "REPORT": 10, "warn.1d.NelderMead": True, "type": 1,
           "lmm": 5, "factr": 1e7, "pgtol": 0.0, "tmax": 10, "temp": 10.0}
    nms = list(con.keys())
    if method == "Nelder-Mead":
        con["maxit"] = 500
    if method == "SANN":
        con["maxit"] = 10000
        con["REPORT"] = 100
    control = dict(control or {})
    ctl = {}
    for k, v in control.items():
        kk = k.replace("warn_1d_NelderMead", "warn.1d.NelderMead")
        ctl[kk] = v
    con.update(ctl)
    no = [k for k in ctl if k not in nms]
    if no:
        _warn("unknown names in control: " + ", ".join(no))
    if con["trace"] < 0:
        _warn("read the documentation for 'trace' more carefully")
    elif method == "SANN" and con["trace"] and int(con["REPORT"]) == 0:
        raise RError("'trace != 0' needs 'REPORT >= 1'")
    if method == "L-BFGS-B" and any(k in ctl for k in ("reltol", "abstol")):
        _warn("method L-BFGS-B uses 'factr' (and 'pgtol') instead of 'reltol' and 'abstol'")
    if npar == 1 and method == "Nelder-Mead" and con["warn.1d.NelderMead"] is True:
        _warn('one-dimensional optimization by Nelder-Mead is unreliable:\nuse "Brent" or optimize() directly')
    if npar > 1 and method == "Brent":
        raise RError('method = "Brent" is only available for one-dimensional optimization')
    lo = np.resize(lo, npar) if npar else lo[:0]
    up = np.resize(up, npar) if npar else up[:0]
    res = _OptRes()
    if method == "Brent":
        if not (np.isfinite(lo).all() and np.isfinite(up).all()):
            raise RError("'lower' and 'upper' must be finite values")
        fs = float(con["fnscale"])
        o = optimize(lambda p: _num1(fn(p, *args, **kwargs), "")[0] / fs, lower=float(lo[0]),
                     upper=float(up[0]), tol=float(con["reltol"]))
        res["par"] = o["minimum"]
        res["value"] = o["objective"] * fs
        res["counts"] = pd.Series([NA_REAL, NA_REAL], index=["function", "gradient"])
        res["convergence"] = 0
        res["message"] = None
    else:
        res = _optim_c(pv, names, fn1, gr1, method, con, lo, up)
    if hessian:
        res["hessian"] = optimhess(res["par"], fn, gr, *args, control=con, **kwargs)
    return res


def _asint(v):
    if v is None:
        raise RError("'maxit' is not an integer")
    return int(float(v))


def _optim_c(pv, names, fn1, gr1, method, con, lo, up):
    from ._optim import nmmin, vmmin, cgmin
    from ._lbfgsb import lbfgsb
    npar = pv.size
    trace = int(con["trace"])
    fnscale = float(con["fnscale"])
    ps = np.atleast_1d(np.asarray(con["parscale"], dtype=np.float64)).ravel()
    if ps.size != npar:
        raise RError("'parscale' is of the wrong length")
    ps = ps.tolist()
    dpar = [float(pv[i]) / ps[i] for i in range(npar)]
    abstol = float(con["abstol"])
    reltol = float(con["reltol"])
    maxit = _asint(con["maxit"])

    def get_ndeps():
        nd = np.atleast_1d(np.asarray(con["ndeps"], dtype=np.float64)).ravel()
        if nd.size != npar:
            raise RError("'ndeps' is of the wrong length")
        return nd.tolist()
    res = _OptRes()
    msg = None
    with np.errstate(all="ignore"):
        if method == "Nelder-Mead":
            F = _Fn(fn1, None, fnscale, ps, None, names)
            X, val, fail, fncount = nmmin(npar, dpar, F.fminfn, abstol, reltol, float(con["alpha"]),
                                          float(con["beta"]), float(con["gamma"]), trace, maxit)
            par = [X[i] * ps[i] for i in range(npar)]
            grcount = None
        elif method == "SANN":
            raise NotImplementedError('optim(method = "SANN") ist nicht portiert')
        elif method == "BFGS":
            nrep = int(con["REPORT"])
            nd = None if gr1 is not None else get_ndeps()
            F = _Fn(fn1, gr1, fnscale, ps, nd, names)
            b, val, fncount, grcount, fail = vmmin(npar, dpar, F.fminfn, F.fmingr, maxit, trace,
                                                   [1] * npar, abstol, reltol, nrep)
            par = [b[i] * ps[i] for i in range(npar)]
        elif method == "CG":
            typ = int(con["type"])
            nd = None if gr1 is not None else get_ndeps()
            F = _Fn(fn1, gr1, fnscale, ps, nd, names)
            X, val, fail, fncount, grcount = cgmin(npar, dpar, F.fminfn, F.fmingr, abstol, reltol,
                                                   typ, trace, maxit)
            par = [X[i] * ps[i] for i in range(npar)]
        else:  # L-BFGS-B
            nrep = int(con["REPORT"])
            factr = float(con["factr"])
            pgtol = float(con["pgtol"])
            lmm = int(con["lmm"])
            nd = None if gr1 is not None else get_ndeps()
            lower = [float(lo[i]) / ps[i] for i in range(npar)]
            upper = [float(up[i]) / ps[i] for i in range(npar)]
            nbd = []
            for i in range(npar):
                if not math.isfinite(lower[i]):
                    nbd.append(0 if not math.isfinite(upper[i]) else 3)
                else:
                    nbd.append(1 if not math.isfinite(upper[i]) else 2)
            F = _Fn(fn1, gr1, fnscale, ps, nd, names, lower, upper, usebounds=True)
            x, val, fail, fncount, grcount, msg = lbfgsb(npar, lmm, dpar, lower, upper, nbd, F.fminfn,
                                                         F.fmingr, factr, pgtol, maxit, trace, nrep)
            par = [x[i] * ps[i] for i in range(npar)]
    p = np.array(par, dtype=np.float64)
    res["par"] = pd.Series(p, index=names) if names is not None else (p if p.size != 1 else p)
    res["value"] = val * fnscale
    res["counts"] = pd.Series([float(fncount), NA_REAL if grcount is None else float(grcount)],
                              index=["function", "gradient"])
    res["convergence"] = int(fail)
    res["message"] = msg
    return res


def optimhess(par, fn, gr=None, *args, control=None, **kwargs):
    """``optimHess(par, fn, gr, ..., control)`` (Hesse-Matrix wie in optim)."""
    names = None
    if isinstance(par, pd.Series):
        names = None if isinstance(par.index, pd.RangeIndex) else [str(i) for i in par.index]
        pv = par.to_numpy(dtype=np.float64)
    else:
        pv = np.atleast_1d(np.asarray(par, dtype=np.float64)).ravel()
    npar = pv.size
    con = {"fnscale": 1.0, "parscale": np.ones(npar), "ndeps": np.full(npar, 1e-3)}
    if control:
        con.update({k: v for k, v in control.items() if k in con})
    fnscale = float(con["fnscale"])
    ps = np.atleast_1d(np.asarray(con["parscale"], dtype=np.float64)).ravel()
    if ps.size != npar:
        raise RError("'parscale' is of the wrong length")
    ps = ps.tolist()
    nd = np.atleast_1d(np.asarray(con["ndeps"], dtype=np.float64)).ravel()
    if nd.size != npar:
        raise RError("'ndeps' is of the wrong length")
    nd = nd.tolist()
    fn1 = (lambda p: fn(p, *args, **kwargs))
    gr1 = (lambda p: gr(p, *args, **kwargs)) if gr is not None else None
    F = _Fn(fn1, gr1, fnscale, ps, nd, names)
    dpar = [float(pv[i]) / ps[i] for i in range(npar)]
    ans = np.zeros((npar, npar))
    with np.errstate(all="ignore"):
        for i in range(npar):
            eps = nd[i] / ps[i]
            dpar[i] = dpar[i] + eps
            df1 = F.fmingr(dpar)
            dpar[i] = dpar[i] - 2 * eps
            df2 = F.fmingr(dpar)
            for j in range(npar):
                ans[j, i] = float(np.float64(fnscale * (df1[j] - df2[j])) /
                                  np.float64(2 * eps * ps[i] * ps[j]))
            dpar[i] = dpar[i] + eps
        for i in range(npar):
            for j in range(i):
                tmp = 0.5 * (ans[j, i] + ans[i, j])
                ans[j, i] = ans[i, j] = tmp
    return _out(ans, names, names)


# ── nlminb (PORT) ─────────────────────────────────────────────────────────

_PORT_CPOS = (("eval.max", 17), ("iter.max", 18), ("trace", 19), ("maxiter", 18),
              ("abs.tol", 31), ("rel.tol", 32), ("x.tol", 33), ("xf.tol", 34),
              ("step.min", 35), ("step.max", 36), ("sing.tol", 37),
              ("scale.init", 38), ("diff.g", 42))

_PORT_MSG = {3: "X-convergence (3)", 4: "relative convergence (4)",
             5: "both X-convergence and relative convergence (5)",
             6: "absolute function convergence (6)", 7: "singular convergence (7)",
             8: "false convergence (8)",
             9: "function evaluation limit reached without convergence (9)",
             10: "iteration limit reached without convergence (10)",
             14: "storage only has been allocated (14)", 15: "LIV too small (15)",
             16: "LV too small (16)", 63: "fn cannot be computed at initial par (63)",
             65: "gr cannot be computed at initial par (65)",
             300: "initial par violates constraints"}


class NlminbResult(RList):
    """Ergebnis von ``nlminb`` (unbenannte R-Liste)."""


def _pmatch(nms, table):
    """``pmatch(nms, table)`` (duplicates.ok = FALSE); 1-basiert, None = NA."""
    used = [False] * len(table)
    ans = [None] * len(nms)
    for i, s in enumerate(nms):
        for j, t in enumerate(table):
            if not used[j] and s == t:
                ans[i] = j + 1
                used[j] = True
                break
    for i, s in enumerate(nms):
        if ans[i] is not None or len(s) == 0:
            continue
        mtch = 0
        cnt = 0
        for j, t in enumerate(table):
            if not used[j] and t.startswith(s):
                mtch = j + 1
                cnt += 1
        if mtch > 0 and cnt == 1:
            used[mtch - 1] = True
            ans[i] = mtch
    return ans


def _r_any_ne(x, ref):
    """``any(x != ref)`` mit R's NA-Logik (None = NA)."""
    na = False
    for e in x:
        if e != e:
            na = True
        elif e != ref:
            return True
    return None if na else False


def _ctl_int(val):
    """``as.integer`` eines Steuerwerts (NA -> INT_MIN)."""
    if isinstance(val, (bool, np.bool_)):
        return int(val)
    f = float(val)
    if f != f or abs(f) >= 2147483648.0:
        if f == f:
            _warn("NAs introduced by coercion to integer range")
        return -2147483648
    return int(f)


def nlminb(start, objective, gradient=None, hessian=None, *args, scale=1, control=None,
           lower=-math.inf, upper=math.inf, **kwargs):
    """``nlminb(start, objective, gradient, hessian, ..., scale, control, lower, upper)``.

    Minimierung mit der PORT-Bibliothek (``drmnf``, ``drmng``, ``drmnh`` und
    die Varianten mit Schranken ``drmnfb``, ``drmngb``, ``drmnhb``) wie in R.

    Argumente:
        start: Startwerte (Array, Liste oder benannte ``Series``).
        objective: Zielfunktion ``objective(par, *args, **kwargs)``; ``par``
            ist wie ``start`` benannt (``Series``) oder ein Array.
        gradient: optional, Gradient ``gradient(par, ...)`` (Länge n).
        hessian: optional (nur mit ``gradient``), Hesse-Matrix (n x n).
        *args, **kwargs: weitere Argumente für die Funktionen (R's ``...``).
        scale: Skalierung der Parameter (wird auf n verlängert).
        control: ``dict`` mit ``eval.max``, ``iter.max``, ``trace``,
            ``abs.tol``, ``rel.tol``, ``x.tol``, ``xf.tol``, ``step.min``,
            ``step.max``, ``sing.tol``, ``scale.init``, ``diff.g``
            (Teilnamen wie in R erlaubt).
        lower, upper: Schranken (werden auf n verlängert).

    Ergebnis: Liste mit ``par``, ``objective``, ``convergence``,
    ``iterations``, ``evaluations`` (``Series`` ``function``/``gradient``) und
    ``message``.
    """
    from . import port as _port
    if isinstance(start, pd.Series):
        names = None if isinstance(start.index, pd.RangeIndex) else [str(i) for i in start.index]
        pv = start.to_numpy(dtype=np.float64).copy()
    elif isinstance(start, Mapping):
        names = [str(k) for k in start.keys()]
        pv = np.array([float(v) for v in start.values()], dtype=np.float64)
    else:
        names = None
        pv = np.atleast_1d(np.asarray(start, dtype=np.float64)).ravel().copy()
    n = pv.size
    liv = 78 + 3 * n
    lv = 130 + (n * (n + 27)) // 2
    iv = np.zeros(liv + 1, dtype=np.int64)   # 1-basiert (iv[0] ungenutzt)
    v = np.zeros(lv + 1, dtype=np.float64)
    _port.divset(2, iv, liv, lv, v)
    if control:
        if not isinstance(control, Mapping):
            raise RError("'control' argument must be a named list")
        nms = [str(k) for k in control.keys()]
        vals = list(control.values())
        tab = [k for k, _ in _PORT_CPOS]
        pos = _pmatch(nms, tab)
        nap = [p is None for p in pos]
        if any(nap):
            msg = "unrecognized control element named %s ignored" if len(nap) == 1 else \
                "unrecognized control elements named %s ignored"
            _warn(msg % ", ".join("‘%s’" % nms[i] for i in range(len(nms)) if nap[i]))
            vals = [vals[i] for i in range(len(vals)) if not nap[i]]
            pos = [p for p in pos if p is not None]
        ivv = [(_PORT_CPOS[p - 1][1], vals[i]) for i, p in enumerate(pos) if p <= 4]
        vvv = [(_PORT_CPOS[p - 1][1], vals[i]) for i, p in enumerate(pos) if p > 4]
        ivi = [_ctl_int(val) for _, val in ivv]
        for (k, _), val in zip(ivv, ivi):
            iv[k] = val
        for k, val in vvv:
            v[k] = float(val)
    fn = (lambda p: objective(p, *args, **kwargs))
    gr = hs = None
    if gradient is not None:
        gr = (lambda p: gradient(p, *args, **kwargs))
        if hessian is not None:
            if isinstance(hessian, (bool, np.bool_)):
                raise RError("logical 'hessian' argument not allowed.  See documentation.")
            hs = (lambda p: hessian(p, *args, **kwargs))
    lo = np.atleast_1d(np.asarray(lower, dtype=np.float64)).ravel()
    up = np.atleast_1d(np.asarray(upper, dtype=np.float64)).ravel()
    a1 = _r_any_ne(lo, -math.inf)
    bounded = True if a1 is True else _r_any_ne(up, math.inf)
    if a1 is None and bounded is False:
        bounded = None
    if bounded is None:
        raise RError("missing value where TRUE/FALSE needed")
    low = np.resize(lo, n) if bounded else None
    upp = np.resize(up, n) if bounded else None
    sc = np.atleast_1d(np.asarray(scale, dtype=np.float64)).ravel()
    d = np.resize(sc, n) if n else sc[:0]
    x = _port.port_nlminb(fn, gr, hs, low, upp, d, iv, v, pv, names)
    iv1 = int(iv[1])
    res = NlminbResult()
    res["par"] = pd.Series(x, index=names) if names is not None else x
    res["objective"] = float(v[10])
    res["convergence"] = 0 if 3 <= iv1 <= 6 else 1
    res["iterations"] = int(iv[31])
    res["evaluations"] = pd.Series([int(iv[6]), int(iv[30])], index=["function", "gradient"])
    if 19 <= iv1 <= 43:
        hit = [k for k, p in _PORT_CPOS if p == iv1]
        from .fmt import sprintf as _sprintf
        if hit:
            msg = _sprintf("'control' component '%s' = %g, is out of range", hit[0], float(v[iv1]))
        else:
            msg = _sprintf("V[IV[1]] = V[%d] = %g is out of range (see PORT docu.)", iv1,
                           float(v[iv1]))
    else:
        msg = _PORT_MSG.get(iv1, "See PORT documentation.  Code (%d)" % iv1)
    res["message"] = msg
    return res


# ── lm.fit / lm / poly / glm ─────────────────────────────────────────────

class LMFit(RList):
    r_class = ("lm",)


class GLMFit(RList):
    r_class = ("glm", "lm")


class _Family(RList):
    r_class = ("family",)


def lm_fit(x, y, offset=None, method="qr", tol=1e-07, singular_ok=True):
    """``lm.fit(x, y, offset, method, tol, singular.ok)`` (LINPACK ``dqrls``).

    Ergebnis: ``RList`` mit ``coefficients`` (Series), ``residuals``,
    ``effects`` (Series), ``rank``, ``fitted.values``, ``assign``, ``qr``
    (``RQR`` mit ``qr``, ``qraux``, ``pivot``, ``tol``, ``rank``),
    ``df.residual``.
    """
    from . import _linpack as LP
    from .linalg import RQR
    if isinstance(x, pd.DataFrame):
        X = x.to_numpy(dtype=np.float64)
        cn = None if isinstance(x.columns, pd.RangeIndex) else [str(c) for c in x.columns]
        rn_x = None if isinstance(x.index, pd.RangeIndex) else [str(i) for i in x.index]
    else:
        X = np.asarray(x, dtype=np.float64)
        cn = None
        rn_x = None
        if X.ndim != 2:
            raise RError("'x' must be a matrix")
    n = X.shape[0]
    if n == 0:
        raise RError("0 (non-NA) cases")
    p = X.shape[1]
    ynames = None
    if isinstance(y, pd.Series):
        ynames = None if isinstance(y.index, pd.RangeIndex) else [str(i) for i in y.index]
        Y = y.to_numpy(dtype=np.float64)
    elif isinstance(y, pd.DataFrame):
        Y = y.to_numpy(dtype=np.float64)
    else:
        Y = np.asarray(y, dtype=np.float64)
    ymat = Y.ndim == 2 and Y.shape[1] > 1
    if Y.ndim == 2 and Y.shape[1] == 1:
        Y = Y[:, 0]
    if p == 0:
        res = LMFit()
        res["coefficients"] = np.zeros(0)
        res["residuals"] = y
        res["fitted.values"] = 0 * Y
        res["rank"] = 0
        res["df.residual"] = Y.shape[0]
        return res
    if offset is not None:
        Y = Y - np.asarray(offset, dtype=np.float64)
    if Y.shape[0] != n:
        raise RError("incompatible dimensions")
    if method != "qr":
        _warn("method = '%s' is not supported. Using 'qr'" % method)
    if not np.isfinite(X).all():
        raise RError("NA/NaN/Inf in 'x'")
    if not np.isfinite(Y).all():
        raise RError("NA/NaN/Inf in 'y'")
    Y2 = Y.reshape(n, -1)
    with np.errstate(all="ignore"):
        z = LP.dqrls(X, Y2, float(tol))
    if not singular_ok and z["rank"] < p:
        raise RError("singular fit encountered")
    rank = z["rank"]
    pivot = z["pivot"]
    dn = cn if cn is not None else ["x%d" % (i + 1) for i in range(p)]
    nmeff = [dn[pivot[i] - 1] for i in range(rank)] + [""] * (n - rank)
    coef = z["coefficients"].copy()
    coef[rank:, :] = NA_REAL
    if z["pivoted"]:
        c2 = np.empty_like(coef)
        c2[pivot - 1, :] = coef
        coef = c2
    resid = z["residuals"]
    eff = z["effects"]
    with np.errstate(all="ignore"):
        fitted = Y2 - resid
        if offset is not None:
            fitted = fitted + np.asarray(offset, dtype=np.float64).reshape(n, -1)
    qrm = z["qr"]
    qcn = None
    if cn is not None:
        qcn = [cn[i - 1] for i in pivot] if z["pivoted"] else cn
    q = RQR()
    q["qr"] = _out(qrm, rn_x, qcn)
    q["qraux"] = z["qraux"]
    q["pivot"] = pivot
    q["tol"] = float(tol)
    q["rank"] = rank
    res = LMFit()
    if ymat:
        res["coefficients"] = pd.DataFrame(coef, index=dn)
        res["residuals"] = resid
        res["effects"] = pd.DataFrame(eff, index=nmeff)
        res["rank"] = rank
        res["fitted.values"] = fitted
    else:
        res["coefficients"] = pd.Series(coef[:, 0], index=dn)
        res["residuals"] = _vec_out(resid[:, 0], ynames)
        res["effects"] = pd.Series(eff[:, 0], index=nmeff)
        res["rank"] = rank
        res["fitted.values"] = _vec_out(fitted[:, 0], ynames)
    res["assign"] = None
    res["qr"] = q
    res["df.residual"] = n - rank
    return res


def poly(x, degree=1, coefs=None, raw=False, simple=False):
    """``poly(x, degree, coefs, raw, simple)`` (orthogonale Polynome wie R).

    Ergebnis: n×degree-Matrix (``ndarray``) mit Attribut ``coefs``
    (``dict`` mit ``alpha``, ``norm2``) als Eigenschaft ``.coefs``.
    """
    from .rnum import r_pow
    from . import linalg as LA
    xv, _ = _vec(x)
    degree = int(degree)
    if degree < 1:
        raise RError("'degree' must be at least 1")
    n = xv.size
    if raw:
        Z = np.column_stack([np.array([r_pow(v, k) for v in xv.tolist()]) for k in range(1, degree + 1)])
        return _PolyMatrix(Z, None, list(range(1, degree + 1)))
    if coefs is None:
        if np.isnan(xv).any():
            raise RError("missing values are not allowed in 'poly'")
        if degree >= np.unique(xv).size:
            raise RError("'degree' must be less than number of unique points")
        xbar = _rmean(xv)
        xc = xv - xbar
        X = np.column_stack([np.array([r_pow(v, k) for v in xc.tolist()]) for k in range(0, degree + 1)])
        QR = LA.qr(X)
        if QR["rank"] < degree:
            raise RError("'degree' must be less than number of unique points")
        zq = np.asarray(QR["qr"], dtype=np.float64)
        i, j = np.indices(zq.shape)
        zq = zq * (i == j)
        Z = np.asarray(LA.qr_qy(QR, zq), dtype=np.float64)
        Z2 = Z * Z
        norm2 = np.array([_rsum(Z2[:, k]) for k in range(Z.shape[1])])
        alpha = (np.array([_rsum(xc * Z2[:, k]) for k in range(Z.shape[1])]) / norm2 + xbar)[:degree]
        norm2 = np.concatenate([[1.0], norm2])
    else:
        alpha = np.asarray(coefs["alpha"], dtype=np.float64)
        norm2 = np.asarray(coefs["norm2"], dtype=np.float64)
        Z = np.ones((n, degree + 1))
        Z[:, 1] = xv - alpha[0]
        for i in range(2, degree + 1):
            Z[:, i] = (xv - alpha[i - 1]) * Z[:, i - 1] - (norm2[i] / norm2[i - 1]) * Z[:, i - 2]
    with np.errstate(all="ignore"):
        Z = Z / np.sqrt(norm2[1:])[None, :]
    Z = Z[:, 1:]
    out = _PolyMatrix(Z, {"alpha": alpha, "norm2": norm2}, list(range(1, degree + 1)))
    return out


class _PolyMatrix(np.ndarray):
    """Matrix mit ``coefs``/``degree`` wie R's ``poly``-Objekt."""

    def __new__(cls, a, coefs, degree):
        obj = np.asarray(a, dtype=np.float64).view(cls)
        obj.coefs = coefs
        obj.degree = degree
        return obj

    def __array_finalize__(self, obj):
        self.coefs = getattr(obj, "coefs", None)
        self.degree = getattr(obj, "degree", None)


# Minimaler Formel-Parser für die Formen, die das Paket nutzt:
#   y ~ x,  y ~ x1 + x2,  y ~ X (Matrix),  y ~ poly(x, d),  y ~ stats::poly(x, d),
#   Achsenabschnitt entfernen mit "- 1" oder "0 +".

def _split_top(s, sep):
    out = []
    depth = 0
    cur = ""
    for ch in s:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == sep and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return out


def _deparse_call(term):
    """Spaltennamen-Präfix wie R's deparse (", " zwischen Argumenten)."""
    t = term.strip()
    if "(" not in t:
        return t
    fn, rest = t.split("(", 1)
    inner = rest[:rest.rindex(")")]
    args = [a.strip() for a in _split_top(inner, ",")]
    return fn.strip() + "(" + ", ".join(args) + ")"


def _eval_term(term, ns):
    t = term.strip()
    if t in ns:
        return ns[t]
    tt = t
    for pre in ("stats::", "base::"):
        tt = tt.replace(pre, "")
    if tt.startswith("poly("):
        inner = tt[5:tt.rindex(")")]
        args = [a.strip() for a in _split_top(inner, ",")]
        xv = _eval_term(args[0], ns)
        kw = {}
        pos = []
        for a in args[1:]:
            if "=" in a and not a.startswith("="):
                k, v = a.split("=", 1)
                kw[k.strip()] = _eval_py(v.strip(), ns)
            else:
                pos.append(_eval_py(a, ns))
        if pos:
            kw["degree"] = pos[0]
        if "raw" in kw:
            kw["raw"] = bool(kw["raw"])
        return poly(xv, **kw)
    return _eval_py(tt, ns)


def _eval_py(expr, ns):
    e = expr.replace("TRUE", "True").replace("FALSE", "False")
    env = dict(ns)
    env.setdefault("np", np)
    return eval(e, {"__builtins__": {"abs": abs, "float": float, "int": int, "len": len,
                                     "min": min, "max": max, "True": True, "False": False}}, env)


def _model_frame(formula, data, env):
    if "~" not in formula:
        raise RError("invalid formula")
    lhs, rhs = formula.split("~", 1)
    ns = {}
    if env:
        ns.update(env)
    rownames = None
    nrow = None
    if data is not None:
        if isinstance(data, pd.DataFrame):
            for c in data.columns:
                ns[str(c)] = data[c].to_numpy()
            if not isinstance(data.index, pd.RangeIndex):
                rownames = [str(i) for i in data.index]
            nrow = len(data)
        else:
            ns.update(dict(data))
    intercept = True
    terms = []
    rhs_terms = [t.strip() for t in _split_top(rhs, "+")]
    expanded = []
    for t in rhs_terms:
        parts = _split_top(t, "-")
        expanded.append(parts[0].strip())
        for pp in parts[1:]:
            if pp.strip() in ("1",):
                intercept = False
            elif pp.strip():
                raise NotImplementedError("Formelterm '-%s' wird nicht unterstützt" % pp.strip())
    for t in expanded:
        if t == "":
            continue
        if t in ("0", "-1"):
            intercept = False
            continue
        if t == "1":
            continue
        terms.append(t)
    yv = _eval_term(lhs.strip(), ns)
    cols = []
    for t in terms:
        cols.append((t, _eval_term(t, ns)))
    return lhs.strip(), yv, cols, intercept, rownames, nrow


def _design(yv, cols, intercept, rownames):
    """Modellmatrix, Antwort, Spaltennamen, assign, behaltene Zeilen."""
    ylab, y = yv
    y = np.asarray(y.to_numpy() if isinstance(y, pd.Series) else y)
    if y.dtype == bool:
        y = y.astype(np.float64)
    y = y.astype(np.float64)
    n = y.shape[0]
    mats = []
    names = []
    assign = []
    ok = ~np.isnan(y) if y.ndim == 1 else ~np.isnan(y).any(axis=1)
    for k, (lab, v) in enumerate(cols, start=1):
        if isinstance(v, pd.DataFrame):
            cn = [str(c) for c in v.columns] if not isinstance(v.columns, pd.RangeIndex) else None
            a = v.to_numpy(dtype=np.float64)
        elif isinstance(v, _PolyMatrix):
            a = np.asarray(v, dtype=np.float64)
            cn = [str(d) for d in v.degree]
        else:
            a = np.asarray(v.to_numpy() if isinstance(v, pd.Series) else v)
            if a.dtype == bool:
                a = a.astype(np.float64)
            a = a.astype(np.float64)
            cn = None
        if a.ndim == 1:
            mats.append(a.reshape(-1, 1))
            names.append(_deparse_call(lab))
            assign.append(k)
            ok &= ~np.isnan(a)
        else:
            mats.append(a)
            pre = _deparse_call(lab)
            if a.shape[1] == 1:
                # model.matrix: einspaltige Matrix-Terme ohne Spaltensuffix
                names.append(pre)
                assign.append(k)
                ok &= ~np.isnan(a).any(axis=1)
                continue
            if cn is None:
                cn = [str(j + 1) for j in range(a.shape[1])]
            names.extend(pre + c for c in cn)
            assign.extend([k] * a.shape[1])
            ok &= ~np.isnan(a).any(axis=1)
    X = np.column_stack(([np.ones(n)] if intercept else []) + mats) if (mats or intercept) else np.zeros((n, 0))
    if intercept:
        names = ["(Intercept)"] + names
        assign = [0] + assign
    if rownames is None:
        rownames = [str(i + 1) for i in range(n)]
    return X, y, names, np.array(assign, dtype=np.int64), ok, rownames


def lm(formula, data=None, env=None, **kwargs):
    """``lm(formula, data)`` für einfache Formeln (``y ~ x``, ``y ~ x1 + x2``,
    ``y ~ X`` mit Matrix ``X``, ``y ~ poly(x, d)``, ohne Achsenabschnitt mit
    ``- 1``/``0 +``). Variablen aus ``data`` (DataFrame/dict), ``env`` oder
    Schlüsselwortargumenten. Fehlende Werte: ``na.omit``.

    Ergebnis ``LMFit`` (RList, Klasse ``lm``) mit den Elementen von ``lm.fit``
    plus ``model``; :func:`coef`, :func:`fitted`, :func:`residuals`,
    :func:`summary_lm`.
    """
    ns = dict(env or {})
    ns.update(kwargs)
    ylab, yv, cols, intercept, rownames, nrow = _model_frame(formula, data, ns)
    X, y, names, assign, ok, rn = _design((ylab, yv), cols, intercept, rownames)
    keep = ok
    Xk = X[keep]
    yk = y[keep]
    rnk = [r for r, b in zip(rn, keep) if b]
    fit = lm_fit(pd.DataFrame(Xk, columns=names, index=rnk), pd.Series(yk, index=rnk))
    fit["assign"] = assign
    fit["qr"]["qr"] = pd.DataFrame(np.asarray(fit["qr"]["qr"]), index=rnk,
                                   columns=list(fit["qr"]["qr"].columns))
    fit["xlevels"] = {}
    fit["call"] = None
    fit["terms"] = {"intercept": 1 if intercept else 0, "formula": formula}
    model = {ylab: yk}
    for lab, v in cols:
        model[lab] = v[keep] if not isinstance(v, pd.DataFrame) else v[keep]
    fit["model"] = model
    if not keep.all():
        fit["na.action"] = np.where(~keep)[0] + 1
    return fit


def coef(obj):
    """``coef(obj)``."""
    return obj["coefficients"]


def fitted(obj):
    """``fitted(obj)``."""
    return obj["fitted.values"]


def residuals(obj):
    """``residuals(obj)`` (Antwort-Residuen)."""
    return obj["residuals"]


class _SummaryLM(RList):
    r_class = ("summary.lm",)


def summary_lm(object):
    """``summary.lm(object)``: residuals, coefficients (DataFrame), aliased,
    sigma, df, r.squared, adj.r.squared, fstatistic, cov.unscaled."""
    from . import nmath as NM
    from . import linalg as LA
    z = object
    p = int(z["rank"])
    rdf = z["df.residual"]
    r = np.asarray(z["residuals"], dtype=np.float64)
    ans = _SummaryLM()
    intercept = int((z.get("terms") or {}).get("intercept", 1))
    if p == 0:
        n = r.size
        rss = _rsum(r * r)
        resvar = rss / rdf
        ans["residuals"] = z["residuals"]
        ans["aliased"] = np.isnan(np.asarray(z["coefficients"], dtype=np.float64))
        ans["df"] = np.array([0, n, ans["aliased"].size])
        ans["coefficients"] = pd.DataFrame(np.zeros((0, 4)), columns=["Estimate", "Std. Error", "t value", "Pr(>|t|)"])
        ans["sigma"] = math.sqrt(resvar)
        ans["r.squared"] = 0.0
        ans["adj.r.squared"] = 0.0
        return ans
    Qr = z["qr"]
    Q = np.asarray(Qr["qr"], dtype=np.float64)
    n = Q.shape[0]
    if n - p != rdf:
        _warn('residual degrees of freedom in object suggest this is not an "lm" fit')
    f = np.asarray(z["fitted.values"], dtype=np.float64)
    with np.errstate(all="ignore"):
        if intercept:
            d = f - _rmean(f)
            mss = _rsum(d * d)
        else:
            mss = _rsum(f * f)
        rss = _rsum(r * r)
        resvar = float(np.float64(rss) / np.float64(rdf))
        if math.isfinite(resvar):
            mf = _rmean(f)
            if resvar < (mf * mf + var(f)) * 1e-30:
                _warn("essentially perfect fit: summary may be unreliable")
        R = LA.chol2inv(Q[:p, :p])
        se = np.sqrt(np.diag(R) * resvar)
        cf = z["coefficients"]
        cfv = np.asarray(cf, dtype=np.float64)
        piv = np.asarray(Qr["pivot"])
        est = cfv[piv[:p] - 1]
        tval = est / se
        pv = 2 * np.asarray(NM.pt(np.abs(tval), rdf, lower_tail=False), dtype=np.float64)
    cnames = list(cf.index) if isinstance(cf, pd.Series) else [str(i) for i in range(cfv.size)]
    rn = [cnames[i - 1] for i in piv[:p]]
    ans["residuals"] = z["residuals"]
    ans["coefficients"] = pd.DataFrame({"Estimate": est, "Std. Error": se, "t value": tval, "Pr(>|t|)": pv},
                                       index=rn)
    ans["aliased"] = pd.Series(np.isnan(cfv), index=cnames)
    ans["sigma"] = math.sqrt(resvar)
    ans["df"] = np.array([p, rdf, Q.shape[1]], dtype=np.int64)
    if p != intercept:
        df_int = 1 if intercept else 0
        rsq = mss / (mss + rss)
        ans["r.squared"] = rsq
        ans["adj.r.squared"] = 1 - (1 - rsq) * ((n - df_int) / rdf)
        ans["fstatistic"] = pd.Series([(mss / (p - df_int)) / resvar, float(p - df_int), float(rdf)],
                                      index=["value", "numdf", "dendf"])
    else:
        ans["r.squared"] = 0.0
        ans["adj.r.squared"] = 0.0
    ans["cov.unscaled"] = pd.DataFrame(R, index=rn, columns=rn)
    return ans


def binomial(link="logit"):
    """``binomial(link = "logit")`` (nur der Logit-Link aus family.c)."""
    if link != "logit":
        raise NotImplementedError("binomial(): nur link = 'logit' ist portiert")
    fam = _Family()
    fam["family"] = "binomial"
    fam["link"] = "logit"
    fam["linkfun"] = _logit_link
    fam["linkinv"] = _logit_linkinv
    fam["variance"] = lambda mu: mu * (1 - mu)
    fam["dev.resids"] = _binomial_dev_resids
    fam["aic"] = _binomial_aic
    fam["mu.eta"] = _logit_mu_eta
    fam["validmu"] = lambda mu: bool(np.isfinite(mu).all() and ((mu > 0) & (mu < 1)).all())
    fam["valideta"] = lambda eta: True
    fam["dispersion"] = 1
    return fam


def _logit_link(mu):
    mu = np.asarray(mu, dtype=np.float64)
    out = np.empty_like(mu)
    for i, x in enumerate(mu.tolist()):
        if x < 0 or x > 1:
            raise RError("Value %g out of range (0, 1)" % x)
        q = x / (1 - x) if x != 1 else math.inf
        out[i] = math.log(q) if q > 0 else (-math.inf if q == 0 else math.nan)
    return out


_INVEPS = 1 / _DBL_EPS


def _logit_linkinv(eta):
    eta = np.asarray(eta, dtype=np.float64)
    out = np.empty_like(eta)
    for i, e in enumerate(eta.tolist()):
        tmp = _DBL_EPS if e < -30.0 else (_INVEPS if e > 30.0 else math.exp(e))
        out[i] = tmp / (1 + tmp)
    return out


def _logit_mu_eta(eta):
    eta = np.asarray(eta, dtype=np.float64)
    out = np.empty_like(eta)
    for i, e in enumerate(eta.tolist()):
        if e > 30.0 or e < -30.0:
            out[i] = _DBL_EPS
        else:
            ex = math.exp(e)
            opexp = 1 + ex
            out[i] = ex / (opexp * opexp)
    return out


def _y_log_y(y, mu):
    if y != 0.0:
        q = y / mu
        return y * (math.log(q) if q > 0 else (-math.inf if q == 0 else math.nan))
    return 0.0


def _binomial_dev_resids(y, mu, wt):
    y = np.atleast_1d(np.asarray(y, dtype=np.float64))
    mu = np.atleast_1d(np.asarray(mu, dtype=np.float64))
    wt = np.atleast_1d(np.asarray(wt, dtype=np.float64))
    n = y.size
    out = np.empty(n)
    with np.errstate(all="ignore"):
        for i in range(n):
            mui = mu[i] if mu.size > 1 else mu[0]
            yi = y[i]
            w = wt[i] if wt.size > 1 else wt[0]
            out[i] = 2 * w * (_y_log_y(yi, mui) + _y_log_y(1 - yi, 1 - mui))
    return out


def _binomial_aic(y, n, mu, wt, dev):
    from . import nmath as NM
    m = n if (np.asarray(n) > 1).any() else wt
    m = np.asarray(m, dtype=np.float64)
    from .fmt import r_round
    with np.errstate(all="ignore"):
        fac = np.where(m > 0, wt / m, 0.0)
        db = np.asarray(NM.dbinom(np.asarray(r_round(m * y), dtype=np.float64),
                                  np.asarray(r_round(m), dtype=np.float64), mu, log=True), dtype=np.float64)
    return -2 * _rsum(fac * db)


def glm(formula, family=None, data=None, weights=None, control=None, env=None, **kwargs):
    """``glm(formula, family = binomial(), data)`` mit IRLS wie ``glm.fit``.

    Unterstützt die Familie :func:`binomial` (Logit). Ergebnis ``GLMFit``
    mit coefficients, residuals, fitted.values, rank, linear.predictors,
    deviance, aic, null.deviance, iter, weights, prior.weights,
    df.residual, df.null, y, converged, boundary.
    """
    if family is None:
        family = binomial()
    if callable(family) and not isinstance(family, dict):
        family = family()
    ns = dict(env or {})
    ns.update(kwargs)
    ylab, yv, cols, intercept, rownames, nrow = _model_frame(formula, data, ns)
    X, y, names, assign, ok, rn = _design((ylab, yv), cols, intercept, rownames)
    X = X[ok]
    y = y[ok]
    rn = [r for r, b in zip(rn, ok) if b]
    ctl = {"epsilon": 1e-8, "maxit": 25, "trace": False}
    if control:
        ctl.update(control)
    fit = glm_fit(X, y, weights=weights, family=family, control=ctl, intercept=intercept,
                  xnames=names, ynames=rn)
    fit["call"] = None
    fit["formula"] = formula
    fit["terms"] = {"intercept": 1 if intercept else 0}
    return fit


def glm_fit(x, y, weights=None, start=None, etastart=None, mustart=None, offset=None,
            family=None, control=None, intercept=True, singular_ok=True, xnames=None, ynames=None):
    """``glm.fit`` (IRLS) wie R."""
    from . import _linpack as LP
    from . import linalg as LA
    if family is None:
        raise RError("'family' argument seems not to be a valid family object")
    ctl = {"epsilon": 1e-8, "maxit": 25, "trace": False}
    if control:
        ctl.update(control)
    eps_c = float(ctl["epsilon"])
    if eps_c <= 0:
        raise RError("value of 'epsilon' must be > 0")
    maxit = int(ctl["maxit"])
    if maxit <= 0:
        raise RError("maximum number of iterations must be > 0")
    X = np.asarray(x, dtype=np.float64)
    if X.ndim == 1:
        X = X.reshape(-1, 1)
    y = np.asarray(y, dtype=np.float64).copy()
    nobs = y.shape[0]
    nvars = X.shape[1]
    if xnames is None:
        xnames = None
    wts = np.ones(nobs) if weights is None else np.asarray(weights, dtype=np.float64).copy()
    off = np.zeros(nobs) if offset is None else np.asarray(offset, dtype=np.float64)
    variance = family["variance"]
    linkinv = family["linkinv"]
    dev_resids = family["dev.resids"]
    mu_eta = family["mu.eta"]
    valideta = family.get("valideta") or (lambda e: True)
    validmu = family.get("validmu") or (lambda m: True)
    # binomInitialize (Vektor-Antwort)
    with np.errstate(all="ignore"):
        n_ = np.ones(nobs)
        y[wts == 0] = 0
        if ((y < 0) | (y > 1)).any():
            raise RError("y values must be 0 <= y <= 1")
        ms = (wts * y + 0.5) / (wts + 1)
        mm = wts * y
        from .fmt import r_round
        if (np.abs(mm - np.asarray(r_round(mm), dtype=np.float64)) > 1e-3).any():
            _warn("non-integer #successes in a binomial glm!")
    if mustart is None:
        mustart = ms
    conv = False
    coefold = None
    if etastart is not None:
        eta = np.asarray(etastart, dtype=np.float64)
    elif start is not None:
        start = np.asarray(start, dtype=np.float64)
        if start.size != nvars:
            raise RError("length of 'start' should equal %d and correspond to initial coefs" % nvars)
        coefold = start.copy()
        eta = off + np.asarray(LA.matprod(X, start), dtype=np.float64).ravel()
    else:
        eta = family["linkfun"](mustart)
    mu = linkinv(eta)
    if not (validmu(mu) and valideta(eta)):
        raise RError("cannot find valid starting values: please specify some")
    devold = _rsum(dev_resids(y, mu, wts))
    boundary = False
    if start is None:
        start = np.full(nvars, NA_REAL)
    coef = None
    fit = None
    it = 0
    good = wts > 0
    w = None
    with np.errstate(all="ignore"):
        for it in range(1, maxit + 1):
            good = wts > 0
            varmu = variance(mu)[good]
            if np.isnan(varmu).any():
                raise RError("NAs in V(mu)")
            if (varmu == 0).any():
                raise RError("0s in V(mu)")
            mev = mu_eta(eta)
            if np.isnan(mev[good]).any():
                raise RError("NAs in d(mu)/d(eta)")
            good = (wts > 0) & (mev != 0)
            if not good.any():
                conv = False
                _warn("no observations informative at iteration %d" % it)
                break
            z = (eta - off)[good] + (y - mu)[good] / mev[good]
            w = np.sqrt((wts[good] * (mev[good] * mev[good])) / variance(mu)[good])
            fit = LP.dqrls(X[good] * w[:, None], (z * w).reshape(-1, 1), min(1e-7, eps_c / 1000))
            cf = fit["coefficients"][:, 0]
            if not np.isfinite(cf).all():
                conv = False
                _warn("non-finite coefficients at iteration %d" % it)
                break
            if nobs < fit["rank"]:
                raise RError(("X matrix has rank %d, but only %d observation" if nobs == 1 else
                              "X matrix has rank %d, but only %d observations") % (fit["rank"], nobs))
            if not singular_ok and fit["rank"] < nvars:
                raise RError("singular fit encountered")
            start = start.copy()
            start[fit["pivot"] - 1] = cf
            eta = np.asarray(LA.matprod(X, start), dtype=np.float64).ravel()
            eta = eta + off
            mu = linkinv(eta)
            dev = _rsum(dev_resids(y, mu, wts))
            if ctl["trace"]:
                print("Deviance = %s Iterations - %d" % (_fmt_num(dev), it))
            boundary = False
            if not math.isfinite(dev):
                if coefold is None:
                    raise RError("no valid set of coefficients has been found: please supply starting values")
                _warn("step size truncated due to divergence")
                ii = 1
                while not math.isfinite(dev):
                    if ii > maxit:
                        raise RError("inner loop 1; cannot correct step size")
                    ii += 1
                    start = (start + coefold) / 2
                    eta = np.asarray(LA.matprod(X, start), dtype=np.float64).ravel() + off
                    mu = linkinv(eta)
                    dev = _rsum(dev_resids(y, mu, wts))
                boundary = True
            if not (valideta(eta) and validmu(mu)):
                if coefold is None:
                    raise RError("no valid set of coefficients has been found: please supply starting values")
                _warn("step size truncated: out of bounds")
                ii = 1
                while not (valideta(eta) and validmu(mu)):
                    if ii > maxit:
                        raise RError("inner loop 2; cannot correct step size")
                    ii += 1
                    start = (start + coefold) / 2
                    eta = np.asarray(LA.matprod(X, start), dtype=np.float64).ravel() + off
                    mu = linkinv(eta)
                boundary = True
                dev = _rsum(dev_resids(y, mu, wts))
            if abs(dev - devold) / (0.1 + abs(dev)) < eps_c:
                conv = True
                coef = start.copy()
                break
            devold = dev
            coef = start.copy()
            coefold = start.copy()
    if not conv:
        _warn("glm.fit: algorithm did not converge")
    if boundary:
        _warn("glm.fit: algorithm stopped at boundary value")
    epsw = 10 * _DBL_EPS
    if (mu > 1 - epsw).any() or (mu < epsw).any():
        _warn("glm.fit: fitted probabilities numerically 0 or 1 occurred")
    if coef is None:
        coef = start.copy()
    rank = fit["rank"] if fit is not None else 0
    if fit is not None and rank < nvars:
        piv = fit["pivot"]
        coef[piv[rank:] - 1] = NA_REAL
    with np.errstate(all="ignore"):
        resid = (y - mu) / mu_eta(eta)
    xn = xnames if xnames is not None else None
    res = GLMFit()
    res["coefficients"] = pd.Series(coef, index=xn) if xn is not None else coef
    res["residuals"] = _vec_out(resid, ynames)
    res["fitted.values"] = _vec_out(mu, ynames)
    if fit is not None:
        xxnames = [xn[i - 1] for i in fit["pivot"]] if xn is not None else None
        eff = fit["effects"][:, 0]
        res["effects"] = pd.Series(eff, index=(xxnames[:rank] + [""] * (int(good.sum()) - rank))) \
            if xxnames is not None else eff
        qrm = np.asarray(fit["qr"])
        nr = min(int(good.sum()), nvars)
        if nr < nvars:
            Rmat = np.eye(nvars)
            Rmat[:nr, :nvars] = qrm[:nr, :nvars]
        else:
            Rmat = qrm[:nvars, :nvars].copy()
        i, j = np.indices(Rmat.shape)
        Rmat[i > j] = 0.0
        res["R"] = _out(Rmat, xxnames, xxnames)
    res["rank"] = rank
    from .linalg import RQR
    if fit is not None:
        q = RQR()
        q["qr"] = _out(np.asarray(fit["qr"]), None, xxnames)
        q["rank"] = rank
        q["qraux"] = fit["qraux"]
        q["pivot"] = fit["pivot"]
        q["tol"] = min(1e-7, eps_c / 1000)
        res["qr"] = q
    res["family"] = family
    res["linear.predictors"] = _vec_out(eta, ynames)
    res["deviance"] = dev if fit is not None else devold
    with np.errstate(all="ignore"):
        wtdmu = (_rsum(wts * y) / _rsum(wts)) if intercept else linkinv(off)
        nulldev = _rsum(dev_resids(y, wtdmu, wts))
    n_ok = nobs - int((wts == 0).sum())
    nulldf = n_ok - int(bool(intercept))
    resdf = n_ok - rank
    try:
        aic_model = family["aic"](y, n_, mu, wts, res["deviance"]) + 2 * rank
    except Exception:  # noqa: BLE001 - nmath.dbinom ggf. nicht vorhanden
        aic_model = _NAN
    res["aic"] = aic_model
    res["null.deviance"] = nulldev
    res["iter"] = it
    wt = np.zeros(nobs)
    if w is not None:
        wt[good] = w * w
    res["weights"] = _vec_out(wt, ynames)
    res["prior.weights"] = _vec_out(wts, ynames)
    res["df.residual"] = resdf
    res["df.null"] = nulldf
    res["y"] = _vec_out(y, ynames)
    res["converged"] = conv
    res["boundary"] = boundary
    return res


def _fmt_num(x):
    from . import fmt as _fmt
    return _fmt.as_character(x) if hasattr(_fmt, "as_character") else repr(x)


# ── fft / density ────────────────────────────────────────────────────────

def fft(z, inverse=False):
    """``fft(z, inverse)`` (R's gemischte Basis); Ergebnis ``complex128``-Array
    gleicher Form (Matrizen: räumliche Transformation wie R)."""
    from ._fft import fft_vec
    a = np.asarray(z)
    if a.dtype.kind not in "biufc":
        raise RError("non-numeric argument")
    shape = a.shape
    flat = a.ravel(order="F")
    re = np.real(flat).astype(np.float64)
    im = np.imag(flat).astype(np.float64) if np.iscomplexobj(flat) else np.zeros(flat.size)
    dims = list(shape) if a.ndim >= 2 else None
    r, i = fft_vec(re, im, bool(inverse), dims)
    out = np.array(r, dtype=np.float64) + 1j * np.array(i, dtype=np.float64)
    out = np.empty(len(r), dtype=np.complex128)
    out.real = r
    out.imag = i
    return out.reshape(shape, order="F") if a.ndim >= 1 else out[0]


def _cmul_conj(ar, ai, br, bi):
    """(a) * Conj(b) wie C99-Komplexmultiplikation (ohne FMA)."""
    cr = br
    ci = -bi
    re = ar * cr - ai * ci
    im = ar * ci + ai * cr
    return re, im


def bw_nrd0(x):
    """``bw.nrd0(x)``."""
    from .rnum import r_pow
    xv, _ = _vec(x)
    if xv.size < 2:
        raise RError("need at least 2 data points")
    hi = sd(xv)
    q = quantile(xv, [0.25, 0.75], names=False)
    iqr = float(q[1] - q[0])
    lo = min(hi, iqr / 1.34) if not (hi != hi) else hi
    if hi == hi and (iqr / 1.34) != (iqr / 1.34):
        lo = _NAN
    if not lo:
        lo = hi
        if not lo:
            lo = abs(float(xv[0]))
            if not lo:
                lo = 1.0
    return 0.9 * lo * r_pow(float(xv.size), -0.2)


class _Density(RList):
    r_class = ("density",)


def density(x, bw="nrd0", adjust=1, kernel="gaussian", weights=None, n=512, from_=None, to=None,
            cut=3, na_rm=False, **kw):
    """``density.default(x, bw, adjust, kernel, weights, n, from, to, cut, na.rm)``.

    ``from`` heißt hier ``from_`` (auch ``**{"from": ...}`` möglich).
    Ergebnis ``RList`` (Klasse ``density``) mit ``x``, ``y``, ``bw``, ``n``.
    """
    from . import nmath as NM
    from .rnum import r_pow
    if "from" in kw:
        from_ = kw.pop("from")
    kernels = ["gaussian", "epanechnikov", "rectangular", "triangular", "biweight", "cosine", "optcosine"]
    km = [k for k in kernels if k.startswith(kernel)]
    if len(km) != 1:
        raise RError("'arg' should be one of " + ", ".join("“%s”" % k for k in kernels))
    kernel = km[0]
    xv, _ = _vec(x)
    N = xv.size
    has_wts = weights is not None
    if has_wts:
        wv, _ = _vec(weights)
        if wv.size != N:
            raise RError("'x' and 'weights' have unequal length")
    xna = np.isnan(xv)
    if xna.any():
        if na_rm:
            xv = xv[~xna]
            N = xv.size
            if has_wts:
                from .linalg import all_equal_numeric
                trueD = all_equal_numeric(1.0, _rsum(wv)) is True
                wv = wv[~xna]
                if trueD:
                    wv = wv / _rsum(wv)
        else:
            raise RError("'x' contains missing values")
    nx = N
    xfin = np.isfinite(xv)
    if not xfin.all():
        xv = xv[xfin]
        nx = xv.size
    if not has_wts:
        wv = np.full(nx, 1.0 / nx) if nx else np.zeros(0)
        totMass = nx / N
    else:
        if not np.isfinite(wv).all():
            raise RError("'weights' must all be finite")
        if (wv < 0).any():
            raise RError("'weights' must not be negative")
        wsum = _rsum(wv)
        if not xfin.all():
            wv = wv[xfin]
            totMass = _rsum(wv) / wsum
        else:
            totMass = 1.0
        from .linalg import all_equal_numeric
        if all_equal_numeric(1.0, wsum) is not True:
            _warn("sum(weights) != 1  -- will not get true density")
    n_user = int(n)
    n = max(n_user, 512)
    if n > 512:
        n = int(r_pow(2.0, math.ceil(math.log2(n))))
    if isinstance(bw, str):
        if nx < 2:
            raise RError("need at least 2 points to select a bandwidth automatically")
        if has_wts and var(wv) > 0:
            _warn("Selecting bandwidth *not* using 'weights'")
        if bw.lower() != "nrd0":
            raise NotImplementedError("density(): nur bw = 'nrd0' ist portiert")
        bw = bw_nrd0(xv)
    bw = float(bw)
    if not math.isfinite(bw):
        raise RError("non-finite 'bw'")
    bw = adjust * bw
    if bw <= 0:
        raise RError("'bw' is not positive.")
    if from_ is None:
        from_ = float(xv.min()) - cut * bw
    if to is None:
        to = float(xv.max()) + cut * bw
    if not math.isfinite(from_):
        raise RError("non-finite 'from'")
    if not math.isfinite(to):
        raise RError("non-finite 'to'")
    lo = from_ - 4 * bw
    up = to + 4 * bw
    y = _bindist(xv, wv, lo, up, n) * totMass
    kords = seq_len_out(0.0, 2 * (up - lo), 2 * n)
    kords[n + 1:2 * n] = -kords[n - 1:0:-1]
    with np.errstate(all="ignore"):
        if kernel == "gaussian":
            kords = np.asarray(NM.dnorm(kords, sd=bw), dtype=np.float64)
        elif kernel == "rectangular":
            a = bw * math.sqrt(3)
            kords = np.where(np.abs(kords) < a, 0.5 / a, 0.0)
        elif kernel == "triangular":
            a = bw * math.sqrt(6)
            ax = np.abs(kords)
            kords = np.where(ax < a, (1 - ax / a) / a, 0.0)
        elif kernel == "epanechnikov":
            a = bw * math.sqrt(5)
            ax = np.abs(kords)
            q = ax / a
            kords = np.where(ax < a, 3 / 4 * (1 - q * q) / a, 0.0)
        elif kernel == "biweight":
            a = bw * math.sqrt(7)
            ax = np.abs(kords)
            q = ax / a
            t = 1 - q * q
            kords = np.where(ax < a, 15 / 16 * (t * t) / a, 0.0)
        elif kernel == "cosine":
            a = bw / math.sqrt(1 / 3 - 2 / (math.pi * math.pi))
            c = np.array([math.cos(v) for v in (math.pi * kords / a).tolist()])
            kords = np.where(np.abs(kords) < a, (1 + c) / (2 * a), 0.0)
        else:
            a = bw / math.sqrt(1 - 8 / (math.pi * math.pi))
            c = np.array([math.cos(v) for v in (math.pi * kords / (2 * a)).tolist()])
            kords = np.where(np.abs(kords) < a, math.pi / 4 * c / a, 0.0)
        fy = fft(y)
        fk = fft(kords)
        re, im = _cmul_conj(fy.real.copy(), fy.imag.copy(), fk.real.copy(), fk.imag.copy())
        prod = np.empty(re.size, dtype=np.complex128)
        prod.real = re
        prod.imag = im
        kk = fft(prod, inverse=True)
        kv = kk.real[:n] / y.size
        kv = np.where(np.isnan(kv), kv, np.maximum(0.0, kv))
    xords = seq_len_out(lo, up, n)
    xo = seq_len_out(from_, to, n_user)
    res = _Density()
    res["x"] = xo
    res["y"] = approx(xords, kv, xout=xo)["y"]
    res["bw"] = bw
    res["n"] = N
    res["call"] = None
    res["data.name"] = "x"
    res["has.na"] = False
    return res


def _bindist(x, w, xlo, xhi, n):
    y = [0.0] * (2 * n)
    ixmin = 0
    ixmax = n - 2
    xdelta = (xhi - xlo) / (n - 1)
    for xi, wi in zip(x.tolist(), w.tolist()):
        if math.isfinite(xi):
            xpos = (xi - xlo) / xdelta
            if xpos > 2147483647 or xpos < -2147483648:
                continue
            ix = int(math.floor(xpos))
            fx = xpos - ix
            if ixmin <= ix <= ixmax:
                y[ix] += (1 - fx) * wi
                y[ix + 1] += fx * wi
            elif ix == -1:
                y[0] += fx * wi
            elif ix == ixmax + 1:
                y[ix] += (1 - fx) * wi
    return np.array(y)


# ── dist / hclust ────────────────────────────────────────────────────────

class RDist(np.ndarray):
    """``dist``-Objekt: unteres Dreieck spaltenweise, Attribute ``Size``,
    ``Labels``, ``Diag``, ``Upper``, ``method``."""

    def __new__(cls, v, size, labels=None, diag=False, upper=False, method=None):
        obj = np.asarray(v, dtype=np.float64).view(cls)
        obj.Size = int(size)
        obj.Labels = labels
        obj.Diag = diag
        obj.Upper = upper
        obj.method = method
        return obj

    def __array_finalize__(self, obj):
        for k in ("Size", "Labels", "Diag", "Upper", "method"):
            setattr(self, k, getattr(obj, k, None))


_DIST_METHODS = ["euclidean", "maximum", "manhattan", "canberra", "binary", "minkowski"]


def dist(x, method="euclidean", diag=False, upper=False, p=2):
    """``dist(x, method, diag, upper, p)``; Ergebnis :class:`RDist`."""
    from .rnum import r_pow
    if "euclidian".startswith(method):
        method = "euclidean"
    hits = [i for i, m in enumerate(_DIST_METHODS) if m.startswith(method)]
    if not hits:
        raise RError("invalid distance method")
    if len(hits) > 1 and method not in _DIST_METHODS:
        raise RError("ambiguous distance method")
    mi = hits[0] + 1 if len(hits) == 1 else _DIST_METHODS.index(method) + 1
    m = _as_matrix(x)
    X = m.mat()
    nr, nc = X.shape
    if mi == 6 and (not math.isfinite(p) or p <= 0):
        raise RError("distance(): invalid p")
    out = []
    warned = [False]
    with np.errstate(all="ignore"):
        for j in range(nr):
            for i in range(j + 1, nr):
                out.append(_dist1(X[i], X[j], mi, p, warned, r_pow))
    if warned[0]:
        _warn("treating non-finite values as NA")
    return RDist(np.array(out), nr, m.rn, diag, upper, _DIST_METHODS[mi - 1])


def _dist1(a, b, method, p, warned, r_pow):
    nc = a.size
    ok = ~(np.isnan(a) | np.isnan(b))
    if method == 1:
        dev = a - b
        m = ok & ~np.isnan(dev)
        cnt = int(m.sum())
        if cnt == 0:
            return NA_REAL
        d = 0.0
        for v in dev[m].tolist():
            d += v * v
        if cnt != nc:
            d /= (cnt / nc)
        return math.sqrt(d)
    if method == 2:
        dev = np.abs(a - b)
        m = ok & ~np.isnan(dev)
        if not m.any():
            return NA_REAL
        d = -_DBL_MAX
        for v in dev[m].tolist():
            if v > d:
                d = v
        return d
    if method == 3:
        dev = np.abs(a - b)
        m = ok & ~np.isnan(dev)
        cnt = int(m.sum())
        if cnt == 0:
            return NA_REAL
        d = 0.0
        for v in dev[m].tolist():
            d += v
        if cnt != nc:
            d /= (cnt / nc)
        return d
    if method == 4:
        d = 0.0
        cnt = 0
        for x1, x2, o in zip(a.tolist(), b.tolist(), ok.tolist()):
            if not o:
                continue
            s = abs(x1) + abs(x2)
            df = abs(x1 - x2)
            if s > 2.2250738585072014e-308 or df > 2.2250738585072014e-308:
                dev = float(np.float64(df) / np.float64(s))
                if dev == dev or (not math.isfinite(df) and df == s and True):
                    if dev != dev:
                        dev = 1.0
                    d += dev
                    cnt += 1
        if cnt == 0:
            return NA_REAL
        if cnt != nc:
            d /= (cnt / nc)
        return d
    if method == 5:
        total = 0
        count = 0
        dd = 0
        for x1, x2, o in zip(a.tolist(), b.tolist(), ok.tolist()):
            if not o:
                continue
            if not (math.isfinite(x1) and math.isfinite(x2)):
                warned[0] = True
            else:
                if x1 != 0.0 or x2 != 0.0:
                    count += 1
                    if not (x1 != 0.0 and x2 != 0.0):
                        dd += 1
                total += 1
        if total == 0:
            return NA_REAL
        if count == 0:
            return 0.0
        return dd / count
    dev = a - b
    m = ok & ~np.isnan(dev)
    cnt = int(m.sum())
    if cnt == 0:
        return NA_REAL
    d = 0.0
    for v in dev[m].tolist():
        d += r_pow(abs(v), p)
    if cnt != nc:
        d /= (cnt / nc)
    return r_pow(d, 1.0 / p)


def as_dist(m, diag=False, upper=False):
    """``as.dist(m)``: unteres Dreieck einer Matrix als :class:`RDist`."""
    if isinstance(m, RDist):
        return m
    mm = _as_matrix(m)
    A = mm.mat()
    p = A.shape[0]
    if A.shape[1] != p:
        _warn("non-square matrix")
    i, j = np.indices(A.shape)
    sel = (i > j)
    vals = A.ravel(order="F")[sel.ravel(order="F")]
    labels = mm.rn if mm.rn is not None else mm.cn
    return RDist(vals, p, labels, diag, upper, None)


def dist_as_matrix(d):
    """``as.matrix(<dist>)`` (dimnames ``Labels`` bzw. ``1..n``)."""
    size = d.Size
    df = np.zeros((size, size))
    i, j = np.indices(df.shape)
    sel = (i > j).ravel(order="F")
    flat = df.ravel(order="F")
    flat[sel] = np.asarray(d, dtype=np.float64)
    df = flat.reshape((size, size), order="F")
    df = df + df.T
    lab = d.Labels if d.Labels is not None else [str(k + 1) for k in range(size)]
    return pd.DataFrame(df, index=lab, columns=lab)


class RHclust(RList):
    r_class = ("hclust",)


_HC_METHODS = ["ward.D", "single", "complete", "average", "mcquitty", "median", "centroid", "ward.D2"]


def hclust(d, method="complete", members=None):
    """``hclust(d, method, members)`` (Fortran ``hclust``/``hcass2``).

    Ergebnis ``RHclust`` mit ``merge`` (int-Matrix), ``height``, ``order``,
    ``labels``, ``method``, ``call``, ``dist.method``.
    """
    if method == "ward":
        print('The "ward" method has been renamed to "ward.D"; note new "ward.D2"')
        method = "ward.D"
    hits = [i for i, m in enumerate(_HC_METHODS) if m.startswith(method)]
    if method in _HC_METHODS:
        hits = [_HC_METHODS.index(method)]
    if not hits:
        raise RError("invalid clustering method " + method)
    if len(hits) > 1:
        raise RError("ambiguous clustering method " + method)
    iopt = hits[0] + 1
    if not isinstance(d, RDist):
        raise RError("invalid dissimilarities")
    n = int(d.Size)
    if n > 65536:
        raise RError("size cannot be NA nor exceed 65536")
    if n < 2:
        raise RError("must have n >= 2 objects to cluster")
    ln = n * (n - 1) // 2
    if d.size != ln:
        if d.size < ln:
            raise RError("dissimilarities of improper length")
        _warn("dissimilarities of improper length")
    membr = [1.0] * n if members is None else [float(v) for v in members]
    if len(membr) != n:
        raise RError("invalid length of members")
    diss = [0.0] + [float(v) for v in np.asarray(d, dtype=np.float64).tolist()]
    ia, ib, crit = _hclust_f(n, ln, iopt, membr, diss)
    order, iia, iib = _hcass2(n, ia, ib)
    res = RHclust()
    res["merge"] = np.column_stack([np.array(iia[1:n], dtype=np.int64), np.array(iib[1:n], dtype=np.int64)])
    res["height"] = np.array(crit[1:n])
    res["order"] = np.array(order[1:], dtype=np.int64)
    res["labels"] = d.Labels
    res["method"] = _HC_METHODS[iopt - 1]
    res["call"] = None
    res["dist.method"] = d.method
    return res


def _ioffst(n, i, j):
    return j + (i - 1) * n - (i * (i + 1)) // 2


def _fmin_(a, b):
    return a if a <= b else b


def _fmax_(a, b):
    return a if a >= b else b


def _hclust_f(n, ln, iopt, membr, diss):
    INF = 1.0e300
    ia = [0] * (n + 1)
    ib = [0] * (n + 1)
    crit = [0.0] * (n + 1)
    nn = [0] * (n + 1)
    disnn = [0.0] * (n + 1)
    membr = [0.0] + list(membr)
    flag = [True] * (n + 1)
    im = jj = jm = 0
    ncl = n
    if iopt == 8:
        for i in range(1, ln + 1):
            diss[i] = diss[i] * diss[i]
    for i in range(1, n):
        dmin = INF
        for j in range(i + 1, n + 1):
            ind = _ioffst(n, i, j)
            if dmin > diss[ind]:
                dmin = diss[ind]
                jm = j
        nn[i] = jm
        disnn[i] = dmin
    isWard = iopt in (1, 8)
    while True:
        dmin = INF
        for i in range(1, n):
            if flag[i] and disnn[i] < dmin:
                dmin = disnn[i]
                im = i
                jm = nn[i]
        ncl -= 1
        i2 = min(im, jm)
        j2 = max(im, jm)
        ia[n - ncl] = i2
        ib[n - ncl] = j2
        if iopt == 8:
            dmin = math.sqrt(dmin)
        crit[n - ncl] = dmin
        flag[j2] = False
        dmin = INF
        for k in range(1, n + 1):
            if flag[k] and k != i2:
                ind1 = _ioffst(n, i2, k) if i2 < k else _ioffst(n, k, i2)
                ind2 = _ioffst(n, j2, k) if j2 < k else _ioffst(n, k, j2)
                d12 = diss[_ioffst(n, i2, j2)]
                if isWard:
                    v = ((membr[i2] + membr[k]) * diss[ind1] + (membr[j2] + membr[k]) * diss[ind2]) - membr[k] * d12
                    diss[ind1] = v / ((membr[i2] + membr[j2]) + membr[k])
                elif iopt == 2:
                    diss[ind1] = _fmin_(diss[ind1], diss[ind2])
                elif iopt == 3:
                    diss[ind1] = _fmax_(diss[ind1], diss[ind2])
                elif iopt == 4:
                    diss[ind1] = (membr[i2] * diss[ind1] + membr[j2] * diss[ind2]) / (membr[i2] + membr[j2])
                elif iopt == 5:
                    diss[ind1] = (diss[ind1] + diss[ind2]) / 2
                elif iopt == 6:
                    diss[ind1] = ((diss[ind1] + diss[ind2]) - d12 / 2) / 2
                elif iopt == 7:
                    diss[ind1] = (membr[i2] * diss[ind1] + membr[j2] * diss[ind2] -
                                  membr[i2] * membr[j2] * d12 / (membr[i2] + membr[j2])) / (membr[i2] + membr[j2])
                if i2 < k:
                    if diss[ind1] < dmin:
                        dmin = diss[ind1]
                        jj = k
                else:
                    if diss[ind1] < disnn[k]:
                        disnn[k] = diss[ind1]
                        nn[k] = i2
        membr[i2] = membr[i2] + membr[j2]
        disnn[i2] = dmin
        nn[i2] = jj
        for i in range(1, n):
            if flag[i] and (nn[i] == i2 or nn[i] == j2):
                dmin = INF
                for j in range(i + 1, n + 1):
                    if flag[j]:
                        ind = _ioffst(n, i, j)
                        if diss[ind] < dmin:
                            dmin = diss[ind]
                            jj = j
                nn[i] = jj
                disnn[i] = dmin
        if not (ncl > 1):
            break
    return ia, ib, crit


def _hcass2(n, ia, ib):
    iia = [0] * (n + 1)
    iib = [0] * (n + 1)
    iorder = [0] * (n + 1)
    for i in range(1, n + 1):
        iia[i] = ia[i]
        iib[i] = ib[i]
    for i in range(1, n - 1):
        k = min(ia[i], ib[i])
        for j in range(i + 1, n):
            if ia[j] == k:
                iia[j] = -i
            if ib[j] == k:
                iib[j] = -i
    for i in range(1, n):
        iia[i] = -iia[i]
        iib[i] = -iib[i]
    for i in range(1, n):
        if iia[i] > 0 and iib[i] < 0:
            k = iia[i]
            iia[i] = iib[i]
            iib[i] = k
        if iia[i] > 0 and iib[i] > 0:
            k1 = min(iia[i], iib[i])
            k2 = max(iia[i], iib[i])
            iia[i] = k1
            iib[i] = k2
    iorder[1] = iia[n - 1]
    iorder[2] = iib[n - 1]
    loc = 2
    for i in range(n - 2, 0, -1):
        for j in range(1, loc + 1):
            if iorder[j] == i:
                iorder[j] = iia[i]
                if j == loc:
                    loc += 1
                    iorder[loc] = iib[i]
                else:
                    loc += 1
                    for k in range(loc, j + 1, -1):
                        iorder[k] = iorder[k - 1]
                    iorder[j + 1] = iib[i]
                break
    for i in range(1, n + 1):
        iorder[i] = -iorder[i]
    return iorder, iia, iib


# ── p.adjust / ecdf / ave / aggregate / t.test ───────────────────────────

_PADJ = ["holm", "hochberg", "hommel", "bonferroni", "BH", "BY", "fdr", "none"]


def p_adjust(p, method="holm", n=None):
    """``p.adjust(p, method, n)``."""
    hits = [m for m in _PADJ if m.startswith(method)]
    if method in _PADJ:
        hits = [method]
    if len(hits) != 1:
        raise RError("'arg' should be one of " + ", ".join("“%s”" % m for m in _PADJ))
    method = hits[0]
    if method == "fdr":
        method = "BH"
    pv, nm = _vec(p)
    p0 = pv.copy()
    nna = ~np.isnan(pv)
    pp = pv[nna]
    lp = pp.size
    if n is None:
        n = lp          # R: Promise length(p) wird erst nach p <- p[nna] ausgewertet
    if not n >= lp:
        raise RError("n >= lp is not TRUE")
    if n <= 1:
        return _vec_out(p0, nm) if (nm is not None or p0.size != 1) else float(p0[0])
    if n == 2 and method == "hommel":
        method = "hochberg"
    with np.errstate(all="ignore"):
        if method == "bonferroni":
            r = np.minimum(1.0, n * pp)
        elif method == "holm":
            i = np.arange(1, lp + 1)
            o = order(pp) - 1
            ro = order(o.astype(np.float64)) - 1
            r = np.minimum(1.0, _cummax((n + 1 - i) * pp[o]))[ro]
        elif method == "hommel":
            q_p = np.concatenate([pp, np.ones(int(n) - lp)]) if n > lp else pp.copy()
            nn_ = int(n)
            i = np.arange(1, nn_ + 1)
            o = order(q_p) - 1
            q_p = q_p[o]
            ro = order(o.astype(np.float64)) - 1
            mn = float(np.min(nn_ * q_p / i))
            q = np.full(nn_, mn)
            pa = np.full(nn_, mn)
            for j in range(nn_ - 1, 1, -1):
                ij = np.arange(0, nn_ - j + 1)
                i2 = np.arange(nn_ - j + 1, nn_)
                q1 = float(np.min(j * q_p[i2] / np.arange(2, j + 1)))
                q[ij] = np.minimum(j * q_p[ij], q1)
                q[i2] = q[nn_ - j]
                pa = np.maximum(pa, q)
            r = np.maximum(pa, q_p)[ro[:lp] if lp < nn_ else ro]
        elif method == "hochberg":
            i = np.arange(lp, 0, -1)
            o = order(pp, decreasing=True) - 1
            ro = order(o.astype(np.float64)) - 1
            r = np.minimum(1.0, _cummin((n + 1 - i) * pp[o]))[ro]
        elif method == "BH":
            i = np.arange(lp, 0, -1)
            o = order(pp, decreasing=True) - 1
            ro = order(o.astype(np.float64)) - 1
            r = np.minimum(1.0, _cummin(n / i * pp[o]))[ro]
        elif method == "BY":
            i = np.arange(lp, 0, -1)
            o = order(pp, decreasing=True) - 1
            ro = order(o.astype(np.float64)) - 1
            q = _rsum(1.0 / np.arange(1, int(n) + 1))
            r = np.minimum(1.0, _cummin(q * n / i * pp[o]))[ro]
        else:
            r = pp
    p0[nna] = r
    return _vec_out(p0, nm) if (nm is not None or p0.size != 1) else float(p0[0])


def _cummax(x):
    out = np.empty(x.size)
    m = -math.inf
    for k, v in enumerate(x.tolist()):
        if v != v:
            return _rn._handle_nan(np.asarray(x, dtype=np.float64), out)
        m = m if m > v else v
        out[k] = m
    return out


def _cummin(x):
    out = np.empty(x.size)
    m = math.inf
    for k, v in enumerate(x.tolist()):
        if v != v:
            return _rn._handle_nan(np.asarray(x, dtype=np.float64), out)
        m = m if m < v else v
        out[k] = m
    return out


def ecdf(x):
    """``ecdf(x)``: Funktion mit Attributen ``x`` (Sprungstellen), ``y``, ``nobs``."""
    xv, _ = _vec(x)
    xs = np.sort(xv[~np.isnan(xv)])
    n = xs.size
    if n < 1:
        raise RError("'x' must have 1 or more non-missing values")
    vals = pd.unique(xs)
    idx = np.searchsorted(vals, xs) + 1
    counts = tabulate(idx, nbins=vals.size)
    yv = np.cumsum(counts.astype(LD)).astype(np.float64) / n
    f = approxfun(vals, yv, method="constant", yleft=0.0, yright=1.0, f=0, ties="ordered")
    f.nobs = n
    f.knots = vals
    return f


def ave(x, *groups, FUN=None):
    """``ave(x, ..., FUN = mean)``; ``FUN`` erhält ein ``ndarray``."""
    xv, nm = _vec(x)
    if FUN is None:
        FUN = _rmean
    out = xv.copy()
    if not groups:
        r = np.asarray(FUN(xv), dtype=np.float64)
        out[:] = np.resize(r, xv.size)
        return _vec_out(out, nm)
    keys = list(zip(*[(g.to_numpy() if isinstance(g, pd.Series) else np.asarray(g)).tolist() for g in groups]))
    d = {}
    for i, k in enumerate(keys):
        if any(v is None or (isinstance(v, float) and v != v) for v in k):
            continue
        d.setdefault(k, []).append(i)
    # Gruppen in der Reihenfolge von interaction(...): Stufen wie factor()
    # (Zahlen numerisch, Zeichenketten nach R's Kollation), erste Variable
    # läuft am schnellsten
    pos = []
    for g in groups:
        ga = g.to_numpy() if isinstance(g, pd.Series) else np.asarray(g)
        ok = np.array([not (v is None or (isinstance(v, float) and v != v)) for v in ga.tolist()], dtype=bool)
        lv = sort(pd.unique(ga[ok])) if ok.any() else []
        pos.append({v: i for i, v in enumerate(np.asarray(lv).tolist())})
    def _gord(k):
        return tuple(pos[j][k[j]] for j in range(len(k) - 1, -1, -1))
    for k in sorted(d, key=_gord):
        ix = d[k]
        r = np.asarray(FUN(xv[ix]), dtype=np.float64)
        out[ix] = np.resize(r, len(ix))
    return _vec_out(out, nm)


def aggregate(x, by, FUN):
    """``aggregate(x, by = list(name = g, ...), FUN)`` für einen Vektor ``x``.

    ``by``: ``dict`` (Name → Gruppierungsvektor). Ergebnis-``DataFrame`` mit
    den Gruppenspalten (sortiert wie R: erste Variable läuft am schnellsten)
    und Spalte ``x``.
    """
    xv, _ = _vec(x)
    names = list(by.keys())
    gs = [np.asarray(by[k].to_numpy() if isinstance(by[k], pd.Series) else by[k]) for k in names]
    levels = []
    codes = []
    for g in gs:
        ok = np.array([not (v is None or (isinstance(v, float) and v != v)) for v in g.tolist()])
        lv = sort(pd.unique(g[ok]))
        levels.append(list(lv))
        pos = {v: i for i, v in enumerate(levels[-1])}
        codes.append(np.array([pos.get(v, -1) if o else -1 for v, o in zip(g.tolist(), ok.tolist())]))
    combos = {}
    for i in range(xv.size):
        key = tuple(c[i] for c in codes)
        if any(k < 0 for k in key):
            continue
        combos.setdefault(key, []).append(i)
    # Gruppenindex wie interaction(): erste Variable variiert am schnellsten
    def grp(key):
        g = 0
        mult = 1
        for k, lv in zip(key, levels):
            g += k * mult
            mult *= len(lv)
        return g
    keys = sorted(combos, key=grp)
    data = {nm: [levels[j][k[j]] for k in keys] for j, nm in enumerate(names)}
    data["x"] = [float(np.asarray(FUN(xv[combos[k]]), dtype=np.float64).ravel()[0]) for k in keys]
    return pd.DataFrame(data)


class _HTest(RList):
    r_class = ("htest",)


def t_test(x, y=None, alternative="two.sided", mu=0, paired=False, var_equal=False, conf_level=0.95):
    """``t.test.default(x, y, alternative, mu, paired, var.equal, conf.level)``.

    Ergebnis ``RList`` (Klasse ``htest``): statistic, parameter, p.value,
    conf.int, estimate, null.value, stderr, alternative, method, data.name.
    """
    from . import nmath as NM
    from .rnum import r_pow
    alts = ["two.sided", "less", "greater"]
    am = [a for a in alts if a.startswith(alternative)]
    if len(am) != 1:
        raise RError("'arg' should be one of “two.sided”, “less”, “greater”")
    alternative = am[0]
    if np.ndim(mu) != 0 or mu != mu:
        raise RError("'mu' must be a single number")
    if not (np.ndim(conf_level) == 0 and math.isfinite(conf_level) and 0 <= conf_level <= 1):
        raise RError("'conf.level' must be a single number between 0 and 1")
    xv, _ = _vec(x)
    if y is not None:
        yv, _ = _vec(y)
        dname = "x and y"
        if paired:
            ok = ~(np.isnan(xv) | np.isnan(yv))
            xok = yok = ok
        else:
            yok = ~np.isnan(yv)
            xok = ~np.isnan(xv)
        yv = yv[yok]
    else:
        dname = "x"
        if paired:
            raise RError("'y' is missing for paired test")
        xok = ~np.isnan(xv)
        yv = None
    xv = xv[xok]
    if paired:
        xv = xv - yv
        yv = None
    nx = xv.size
    mx = _rmean(xv)
    vx = var(xv) if nx > 1 else NA_REAL
    eps = _DBL_EPS
    with np.errstate(all="ignore"):
        if yv is None:
            if nx < 2:
                raise RError("not enough 'x' observations")
            df = nx - 1
            stderr = math.sqrt(vx / nx)
            if stderr < 10 * eps * abs(mx):
                raise RError("data are essentially constant")
            tstat = (mx - mu) / stderr
            method = "Paired t-test" if paired else "One Sample t-test"
            estimate = pd.Series([mx], index=["mean difference" if paired else "mean of x"])
        else:
            ny = yv.size
            if nx < 1 or (not var_equal and nx < 2):
                raise RError("not enough 'x' observations")
            if ny < 1 or (not var_equal and ny < 2):
                raise RError("not enough 'y' observations")
            if var_equal and nx + ny < 3:
                raise RError("not enough observations")
            my = _rmean(yv)
            vy = var(yv) if ny > 1 else NA_REAL
            method = ("Welch" + " " if not var_equal else " ") + "Two Sample t-test"
            estimate = pd.Series([mx, my], index=["mean of x", "mean of y"])
            if var_equal:
                df = nx + ny - 2
                v = 0.0
                if nx > 1:
                    v = v + (nx - 1) * vx
                if ny > 1:
                    v = v + (ny - 1) * vy
                v = v / df
                stderr = math.sqrt(v * (1 / nx + 1 / ny))
            else:
                stderrx = math.sqrt(vx / nx)
                stderry = math.sqrt(vy / ny)
                stderr = math.sqrt(stderrx * stderrx + stderry * stderry)
                df = float(np.float64(r_pow(stderr, 4)) / (np.float64(r_pow(stderrx, 4)) / (nx - 1) + np.float64(r_pow(stderry, 4)) / (ny - 1)))
            if stderr < 10 * eps * max(abs(mx), abs(my)):
                raise RError("data are essentially constant")
            tstat = (mx - my - mu) / stderr
        if alternative == "less":
            pval = float(NM.pt(tstat, df))
            cint = [-math.inf, tstat + float(NM.qt(conf_level, df))]
        elif alternative == "greater":
            pval = float(NM.pt(tstat, df, lower_tail=False))
            cint = [tstat - float(NM.qt(conf_level, df)), math.inf]
        else:
            pval = 2 * float(NM.pt(-abs(tstat), df))
            alpha = 1 - conf_level
            c = float(NM.qt(1 - alpha / 2, df))
            cint = [tstat - c, tstat + c]
            cint = [tstat + (-c), tstat + c]
        cint = np.array([mu + v * stderr for v in cint])
    res = _HTest()
    res["statistic"] = pd.Series([tstat], index=["t"])
    res["parameter"] = pd.Series([float(df)], index=["df"])
    res["p.value"] = pval
    res["conf.int"] = cint
    res["estimate"] = estimate
    res["null.value"] = pd.Series([float(mu)], index=["mean difference" if paired else
                                                      ("difference in means" if y is not None else "mean")])
    res["stderr"] = stderr
    res["alternative"] = alternative
    res["method"] = method
    res["data.name"] = dname
    return res


# ── smooth.spline ────────────────────────────────────────────────────────

class SmoothSpline(RList):
    r_class = ("smooth.spline",)


class _SmoothSplineFit(RList):
    r_class = ("smooth.spline.fit",)


def _nknots_smspl(n):
    from .rnum import r_pow
    if n < 50:
        return n
    a1 = math.log2(50)
    a2 = math.log2(100)
    a3 = math.log2(140)
    a4 = math.log2(200)
    if n < 200:
        v = r_pow(2.0, a1 + (a2 - a1) * (n - 50) / 150)
    elif n < 800:
        v = r_pow(2.0, a2 + (a3 - a2) * (n - 200) / 600)
    elif n < 3200:
        v = r_pow(2.0, a3 + (a4 - a3) * (n - 800) / 2400)
    else:
        v = 200 + r_pow(float(n - 3200), 0.2)
    return int(math.trunc(v))


def smooth_spline(x, y=None, w=None, df=None, spar=None, lambda_=None, cv=False, all_knots=False,
                  nknots=None, keep_data=True, df_offset=0, penalty=1, control_spar=None, tol=None,
                  keep_stuff=False, **kw):
    """``smooth.spline(x, y, w, df, spar, lambda, cv, all.knots, nknots, ...)``.

    ``lambda`` heißt ``lambda_`` (oder ``**{"lambda": ...}``); ``cv=None``
    entspricht ``cv = NA``. Ergebnis :class:`SmoothSpline` wie R; Vorhersage
    mit :func:`predict_smooth_spline`.
    """
    from ._sbart import sbart
    if "lambda" in kw:
        lambda_ = kw.pop("lambda")
    contr = {"low": -1.5, "high": 1.5, "tol": 1e-4, "eps": 2e-8, "maxit": 500, "trace": False}
    if control_spar:
        contr.update(control_spar)
    if contr["tol"] < 0 or contr["eps"] <= 0 or contr["maxit"] <= 0:
        raise RError("invalid 'control.spar'")
    xv, _ = _vec(x)
    if y is None:
        yv = xv
        xv = np.arange(1, xv.size + 1, dtype=np.float64)
    else:
        yv, _ = _vec(y)
        if yv.size != xv.size:
            raise RError("'x' and 'y' lengths differ")
    if not (np.isfinite(xv).all() and np.isfinite(yv).all()):
        raise RError("missing or infinite values in inputs are not allowed")
    n = xv.size
    no_wgts = w is None
    if no_wgts:
        wv = None
    else:
        wv, _ = _vec(w)
        if n != wv.size:
            raise RError("lengths of 'x' and 'w' must match")
        if (wv < 0).any():
            raise RError("all weights should be non-negative")
        if (wv == 0).all():
            raise RError("some weights should be positive")
        wv = (wv * float((wv > 0).sum())) / _rsum(wv)
    if tol is None:
        q = quantile(xv, [0.25, 0.75], names=False)
        tol = 1e-6 * float(q[1] - q[0])
    if not math.isfinite(tol) or tol <= 0:
        raise RError("'tol' must be strictly positive and finite")
    with np.errstate(all="ignore"):
        xx = np.rint((xv - _rmean(xv)) / tol)
    uns = n > 1 and bool((np.diff(xv) < 0).any())
    iOx = np.argsort(xv, kind="stable") if uns else np.arange(n)
    xxs = xx[iOx]
    nd = np.concatenate([[True], xxs[:-1] < xxs[1:]])
    ux = xv[iOx][nd]
    nx = ux.size
    if nx <= 3:
        raise RError("need at least four unique 'x' values")
    if nx == n:
        if uns:
            ox = np.empty(n, dtype=np.int64)
            ox[iOx] = np.arange(n)
        else:
            ox = np.arange(n)
        if no_wgts:
            tmp = np.column_stack([np.ones(n), 1 * yv, 1 * (yv * yv)])[iOx]
        else:
            tmp = np.column_stack([wv, wv * yv, wv * (yv * yv)])[iOx]
    else:
        ukeys = xxs[nd]
        ox = np.searchsorted(ukeys, xx)
        rows = []
        for g in range(nx):
            idx = np.where(ox == g)[0]
            if no_wgts:
                rows.append([float(idx.size), _rsum(yv[idx]), _rsum(yv[idx] * yv[idx])])
            else:
                rows.append([_rsum(wv[idx]), _rsum(wv[idx] * yv[idx]), _rsum(wv[idx] * (yv[idx] * yv[idx]))])
        tmp = np.array(rows)
    wbar = tmp[:, 0].copy()
    with np.errstate(all="ignore"):
        ybar = tmp[:, 1] / np.where(wbar > 0, wbar, 1.0)
        yssw = _rsum(tmp[:, 2] - wbar * (ybar * ybar))
    if cv is None and df is not None:
        raise RError("'cv' must not be NA when 'df' is specified")
    CV = cv is not None and bool(cv)
    if CV and nx < n:
        _warn("cross-validation with non-unique 'x' values seems doubtful")
    r_ux = ux[nx - 1] - ux[0]
    xbar = (ux - ux[0]) / r_ux
    if not isinstance(all_knots, (bool, np.bool_)):
        ak = np.asarray(all_knots, dtype=np.float64)
        if ak.size > 1 and (np.diff(ak) <= 0).any():
            raise RError("Numeric 'all.knots' must be strictly increasing")
        if nknots is not None:
            _warn("'all.knots' is vector of knots; 'nknots' specification is disregarded")
        nknots = ak.size
        if 0 < ak[0] or ak[-1] < 1:
            raise RError("numeric 'all.knots' must cover [0,1] (= the transformed data-range)")
        knot = np.concatenate([[ak[0]] * 3, ak, [ak[-1]] * 3])
    else:
        if all_knots:
            if nknots is not None:
                _warn("'all.knots' is TRUE; 'nknots' specification is disregarded")
            nknots = nx
        elif nknots is None:
            nknots = _nknots_smspl(nx)
        else:
            if callable(nknots):
                nknots = nknots(nx)
            if nknots < 1:
                raise RError("'nknots' must be at least 1")
            elif nknots > nx:
                raise RError("cannot use more inner knots than unique 'x' values")
        nknots = int(nknots)
        if all_knots:
            inner = xbar
        else:
            idx = seq_len_out(1, nx, nknots)
            inner = xbar[np.trunc(idx).astype(np.int64) - 1]
        knot = np.concatenate([[xbar[0]] * 3, inner, [xbar[nx - 1]] * 3])
    nk = nknots + 2
    spar_is_lambda = lambda_ is not None
    if spar_is_lambda:
        if spar is not None:
            raise RError("must not specify both 'spar' and 'lambda'")
        ispar = 1
    else:
        ispar = (-1 if contr["trace"] else 0) if spar is None else 1
    sparv = float(lambda_) if spar_is_lambda else (float(spar) if ispar == 1 else 0.0)
    icrit = 0 if cv is None else (2 if cv else 1)
    dofoff = float(df_offset)
    if df is not None:
        if 1 < df <= nx:
            icrit = 3
            dofoff = float(df)
        else:
            _warn("not using invalid df; must have 1 < df <= n := #{unique x} = %d" % nx)
    isetup = 2 if spar_is_lambda else 0
    with np.errstate(all="ignore"):
        fit = sbart(float(penalty), dofoff, [0.0] + xbar.tolist(), [0.0] + ybar.tolist(),
                    [0.0] + wbar.tolist(), yssw, nx, [0.0] + knot.tolist(), nk, icrit, sparv, ispar,
                    int(contr["maxit"]), float(contr["low"]), float(contr["high"]), float(contr["tol"]),
                    float(contr["eps"]), isetup)
    ty = np.array(fit["sz"][1:])
    if cv is None:
        lev = NA_REAL
        dfv = NA_REAL
    else:
        lev = np.array(fit["lev"][1:])
        dfv = _rsum(lev)
        if dfv != dfv:
            raise RError("NA lev[]; probably smoothing parameter 'spar' way too large!")
    if fit["ier"] > 0:
        sml = (not spar_is_lambda) and fit["spar"] < 0.5
        kind = "extreme" if spar_is_lambda else ("small" if sml else "large")
        wtxt = "smoothing parameter value too " + kind
        if spar_is_lambda or sml:
            raise RError(wtxt)
        ty = np.full(nx, _rmean(yv))
        dfv = 1.0
        _warn(wtxt + "\nsetting df = 1  __use with care!__")
    with np.errstate(all="ignore"):
        if cv is None:
            cvcrit = NA_REAL
        else:
            r = yv - ty[ox]
            if CV:
                ww = wbar.copy()
                ww[ww == 0] = 1
                wfac = 1.0 if no_wgts else wv
                r = r / (1 - (lev[ox] * wfac) / ww[ox])
                cvcrit = _rmean(r * r) if no_wgts else weighted_mean(r * r, wv)
            else:
                base = _rmean(r * r) if no_wgts else weighted_mean(r * r, wv)
                t = 1 - (df_offset + penalty * dfv) / n
                cvcrit = base / (t * t)
        d = ybar - ty
        pen = _rsum(wbar * (d * d))
    res = SmoothSpline()
    res["x"] = ux
    res["y"] = ty
    res["w"] = wbar
    res["yin"] = ybar
    res["tol"] = tol
    res["data"] = {"x": xv, "y": yv, "w": 1.0 if no_wgts else wv} if keep_data else None
    res["no.weights"] = no_wgts
    res["n"] = n
    res["lev"] = lev
    res["cv"] = cv
    res["cv.crit"] = cvcrit
    res["pen.crit"] = pen
    res["crit"] = fit["crit"]
    res["df"] = dfv
    res["spar"] = NA_REAL if spar_is_lambda else fit["spar"]
    res["ratio"] = NA_REAL if spar_is_lambda else fit["ratio"]
    res["lambda"] = fit["lspar"]
    res["iparms"] = pd.Series([float(icrit), float(ispar), float(fit["iter"] if ispar != 1 else contr["maxit"]),
                               float(spar_is_lambda), float(fit["ier"]) if fit["ier"] else NA_REAL],
                              index=["icrit", "ispar", "iter", "", "errorI"])
    res["auxM"] = None
    f = _SmoothSplineFit()
    f["knot"] = knot
    f["nk"] = nk
    f["min"] = float(ux[0])
    f["range"] = float(r_ux)
    f["coef"] = np.array(fit["coef"][1:])
    res["fit"] = f
    res["call"] = None
    return res


def _predict_ssfit(obj, x=None, deriv=0):
    from ._sbart import bvalus
    from .rnum import r_pow
    if x is None:
        x = seq_len_out(obj["min"], obj["min"] + obj["range"], len(obj["coef"]) - 4)
    xv, _ = _vec(x)
    with np.errstate(all="ignore"):
        xs = (xv - obj["min"]) / obj["range"]
    el = xs < 0
    er = xs > 1
    ex = el | er
    interp = ~ex
    y = xs.copy()
    if interp.any():
        knot = [0.0] + list(np.asarray(obj["knot"], dtype=np.float64))
        coef = [0.0] + list(np.asarray(obj["coef"], dtype=np.float64))
        y[interp] = bvalus(knot, coef, int(obj["nk"]), xs[interp].tolist(), int(deriv))
    if ex.any():
        xrange = np.array([obj["min"], obj["min"] + obj["range"]])
        if deriv == 0:
            eo = _predict_ssfit(obj, xrange)["y"]
            es = _predict_ssfit(obj, xrange, 1)["y"] * obj["range"]
            if el.any():
                y[el] = eo[0] + es[0] * (xs[el] - 0)
            if er.any():
                y[er] = eo[1] + es[1] * (xs[er] - 1)
        elif deriv == 1:
            es = _predict_ssfit(obj, xrange, 1)["y"] * obj["range"]
            y[el] = es[0]
            y[er] = es[1]
        else:
            y[ex] = 0.0
    if deriv > 0:
        y = y / r_pow(obj["range"], float(deriv))
    out = _XY()
    out["x"] = x
    out["y"] = y
    return out


def predict_smooth_spline(object, x=None, deriv=0):
    """``predict.smooth.spline(object, x, deriv)``: ``RList`` mit ``x``, ``y``."""
    if x is None:
        if deriv == 0:
            out = _XY()
            out["x"] = object["x"]
            out["y"] = object["y"]
            return out
        x = object["x"]
    fit = object.get("fit")
    if fit is None:
        raise RError('not a valid "smooth.spline" object')
    return _predict_ssfit(fit, x, deriv)


def predict(object, *args, **kwargs):
    """Generisches ``predict`` (``smooth.spline``; ``lm``/``glm``: angepasste Werte)."""
    if isinstance(object, SmoothSpline):
        return predict_smooth_spline(object, *args, **kwargs)
    if isinstance(object, _SmoothSplineFit):
        return _predict_ssfit(object, *args, **kwargs)
    if isinstance(object, (LMFit, GLMFit)) and not args and not kwargs:
        return object["fitted.values"] if isinstance(object, LMFit) else object["linear.predictors"]
    raise NotImplementedError("predict() für dieses Objekt ist nicht portiert")


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
