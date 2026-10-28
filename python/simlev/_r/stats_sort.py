"""Gemeinsame Hilfen, Sortieren, Ränge, Einteilen und Lagemaße (``order``, ``sort``, ``rank``, ``rle``,
``tabulate``, ``findInterval``, ``cut``, ``complete.cases``, ``quantile``, ``median``, ``weighted.mean``),
nachgebildet aus R 4.3.3 (``src/main/sort.c``, ``qsort-body.c``, ``seq.c``; ``base/R/sort.R``, ``rle.R``,
``cut.R``, ``findInt.R``; ``stats/R/quantile.R``, ``median.R``, ``weighted.mean.R``).
"""
from __future__ import annotations

import math
import warnings

import numpy as np
import pandas as pd

from .linalg import RError
from .rlist import RList
from . import rnum as _rn
from .rnum import NA_REAL
from ._collate import collate_key

__all__ = [
    "quantile", "median", "weighted_mean", "rank", "order", "sort", "rle", "cut", "findInterval",
    "tabulate", "complete_cases", "seq_len_out",
]


LD = np.longdouble
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


from .base import quiet_fp  # noqa: E402

quiet_fp(globals(), __all__)
