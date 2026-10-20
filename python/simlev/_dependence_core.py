"""Kerne für Abhängigkeiten, Quantilsregression und HMM.

Port von ``r/src/dependence_core.cpp`` (``.dcc_filter``, ``chol_small``) und
aus ``r/src/research_core.cpp`` von ``.kendall_tau_core``,
``.quantile_reg_core`` (mit allen Hilfsroutinen) und
``.hmm_forward_backward``. Rechenreihenfolge 1:1 aus dem C++-Code;
Summen über Beobachtungen werden streng sequenziell gebildet
(``numpy.cumsum``), elementweise Operationen dürfen vektorisiert sein.

``std::sort`` (libstdc++-Introsort, nicht stabil) ist in :func:`_std_sort`
exakt nachgebildet, weil die Auswahl der Basisbeobachtungen in ``qr_pick``
bei gleichen Residuen von der Reihenfolge abhängt.
"""
from __future__ import annotations

import math

import numpy as np

__all__ = ["dcc_filter", "chol_small", "kendall_tau_core", "quantile_reg_core",
           "hmm_forward_backward", "QuantileRegError"]

from ._r.fmt import NA_REAL as _NA   # R's NA_real_ (NA_REAL in research_core.cpp)


class QuantileRegError(RuntimeError):
    """Fehler aus dem Quantilsregressions-Kern (Rcpp ``stop``)."""


def _seqsum(v, start=0.0):
    """Sequenzielle Summe ``s = start; for x in v: s += x`` (wie eine C-Schleife)."""
    v = np.asarray(v, dtype=np.float64)
    if v.size == 0:
        return float(start)
    if start == 0.0:
        return float(np.cumsum(v)[-1]) + 0.0
    return float(np.cumsum(np.concatenate(([start], v)))[-1])


# ─────────────────────────────────────────────────────────────────────────────
# std::sort (libstdc++ 13, Introsort) mit Vergleichsfunktion
# ─────────────────────────────────────────────────────────────────────────────

_S_THRESHOLD = 16


def _std_sort(a, less):
    """Sortiert die Liste ``a`` an Ort und Stelle exakt wie ``std::sort``."""
    n = len(a)
    if n == 0:
        return a
    _introsort_loop(a, 0, n, (n.bit_length() - 1) * 2, less)
    _final_insertion_sort(a, 0, n, less)
    return a


def _introsort_loop(a, first, last, depth, less):
    while last - first > _S_THRESHOLD:
        if depth == 0:
            _partial_sort(a, first, last, less)
            return
        depth -= 1
        cut = _unguarded_partition_pivot(a, first, last, less)
        _introsort_loop(a, cut, last, depth, less)
        last = cut


def _move_median_to_first(a, result, x, y, z, less):
    if less(a[x], a[y]):
        if less(a[y], a[z]):
            a[result], a[y] = a[y], a[result]
        elif less(a[x], a[z]):
            a[result], a[z] = a[z], a[result]
        else:
            a[result], a[x] = a[x], a[result]
    elif less(a[x], a[z]):
        a[result], a[x] = a[x], a[result]
    elif less(a[y], a[z]):
        a[result], a[z] = a[z], a[result]
    else:
        a[result], a[y] = a[y], a[result]


def _unguarded_partition(a, first, last, pivot, less):
    while True:
        while less(a[first], a[pivot]):
            first += 1
        last -= 1
        while less(a[pivot], a[last]):
            last -= 1
        if not first < last:
            return first
        a[first], a[last] = a[last], a[first]
        first += 1


def _unguarded_partition_pivot(a, first, last, less):
    mid = first + (last - first) // 2
    _move_median_to_first(a, first, first + 1, mid, last - 1, less)
    return _unguarded_partition(a, first + 1, last, first, less)


def _push_heap(a, first, hole, top, value, less):
    parent = (hole - 1) // 2
    while hole > top and less(a[first + parent], value):
        a[first + hole] = a[first + parent]
        hole = parent
        parent = (hole - 1) // 2
    a[first + hole] = value


def _adjust_heap(a, first, hole, ln, value, less):
    top = hole
    second = hole
    while second < (ln - 1) // 2:
        second = 2 * (second + 1)
        if less(a[first + second], a[first + second - 1]):
            second -= 1
        a[first + hole] = a[first + second]
        hole = second
    if (ln & 1) == 0 and second == (ln - 2) // 2:
        second = 2 * (second + 1)
        a[first + hole] = a[first + second - 1]
        hole = second - 1
    _push_heap(a, first, hole, top, value, less)


def _make_heap(a, first, last, less):
    ln = last - first
    if ln < 2:
        return
    parent = (ln - 2) // 2
    while True:
        value = a[first + parent]
        _adjust_heap(a, first, parent, ln, value, less)
        if parent == 0:
            return
        parent -= 1


def _pop_heap(a, first, last, result, less):
    value = a[result]
    a[result] = a[first]
    _adjust_heap(a, first, 0, last - first, value, less)


def _partial_sort(a, first, last, less):
    # __heap_select(first, last, last) = make_heap; danach __sort_heap
    _make_heap(a, first, last, less)
    while last - first > 1:
        last -= 1
        _pop_heap(a, first, last, last, less)


def _insertion_sort(a, first, last, less):
    if first == last:
        return
    for i in range(first + 1, last):
        if less(a[i], a[first]):
            val = a[i]
            a[first + 1:i + 1] = a[first:i]
            a[first] = val
        else:
            _unguarded_linear_insert(a, i, less)


def _unguarded_linear_insert(a, last, less):
    val = a[last]
    nxt = last - 1
    while less(val, a[nxt]):
        a[last] = a[nxt]
        last = nxt
        nxt -= 1
    a[last] = val


def _final_insertion_sort(a, first, last, less):
    if last - first > _S_THRESHOLD:
        _insertion_sort(a, first, first + _S_THRESHOLD, less)
        for i in range(first + _S_THRESHOLD, last):
            _unguarded_linear_insert(a, i, less)
    else:
        _insertion_sort(a, first, last, less)


def _argsort_by_key(r):
    """``std::sort(ord, [&](a, b) { return r[a] < r[b]; })`` mit ord = 0..n-1."""
    r = np.asarray(r, dtype=np.float64)
    n = r.size
    if not np.isnan(r).any() and np.unique(r).size == n:
        return np.argsort(r, kind="stable").tolist()   # ohne Gleichstände eindeutig
    rl = r.tolist()
    ordl = list(range(n))
    _std_sort(ordl, lambda i, j: rl[i] < rl[j])
    return ordl


# ─────────────────────────────────────────────────────────────────────────────
# DCC-Filter
# ─────────────────────────────────────────────────────────────────────────────

def chol_small(A, L, k):
    """Cholesky einer kleinen symmetrischen Matrix (zeilenweise Liste, k x k).

    Schreibt in ``L``; ``False``, wenn nicht positiv definit.
    """
    for i in range(k * k):
        L[i] = 0.0
    for i in range(k):
        for j in range(i + 1):
            s = A[i * k + j]
            for m in range(j):
                s -= L[i * k + m] * L[j * k + m]
            if i == j:
                if s <= 1e-14:
                    return False
                L[i * k + i] = math.sqrt(s)
            else:
                L[i * k + j] = s / L[j * k + j]
    return True


def dcc_filter(Z, a, b, Qbar, keep):
    """``.dcc_filter(Z, a, b, Qbar, keep)`` → dict mit ``nll``, ``R``, ``ok``."""
    Zm = np.asarray(Z, dtype=np.float64)
    if Zm.ndim == 1:
        Zm = Zm.reshape(-1, 1)
    n, k = Zm.shape
    np_ = k * (k - 1) // 2
    Qb = np.asarray(Qbar, dtype=np.float64).tolist()
    Zl = Zm.tolist()
    a = float(a)
    b = float(b)
    Q = [Qb[i][j] for i in range(k) for j in range(k)]
    R = [0.0] * (k * k)
    L = [0.0] * (k * k)
    y = [0.0] * k
    out = np.full((n if keep else 0, np_ if keep else 0), _NA)
    nll = 0.0
    ok = True
    c0 = 1.0 - a - b
    sqrt = math.sqrt
    log = math.log
    for t in range(n):
        if t > 0:
            zp = Zl[t - 1]
            for i in range(k):
                zi = a * zp[i]
                Qbi = Qb[i]
                for j in range(k):
                    Q[i * k + j] = c0 * Qbi[j] + zi * zp[j] + b * Q[i * k + j]
        for i in range(k):
            qii = Q[i * k + i]
            for j in range(k):
                R[i * k + j] = Q[i * k + j] / sqrt(qii * Q[j * k + j])
        if not chol_small(R, L, k):
            ok = False
            break
        logdet = 0.0
        quad = 0.0
        zz = 0.0
        zt = Zl[t]
        for i in range(k):
            s = zt[i]
            for m in range(i):
                s -= L[i * k + m] * y[m]
            y[i] = s / L[i * k + i]
            quad += y[i] * y[i]
            zz += zt[i] * zt[i]
            logdet += 2.0 * log(L[i * k + i])
        nll += 0.5 * (logdet + quad - zz)
        if keep:
            p = 0
            for i in range(k):
                for j in range(i + 1, k):
                    out[t, p] = R[i * k + j]
                    p += 1
    if not ok:
        nll = 1e10
    return {"nll": nll, "R": out, "ok": ok}


# ─────────────────────────────────────────────────────────────────────────────
# Kendalls Tau-b (Knight 1966)
# ─────────────────────────────────────────────────────────────────────────────

def _count_inversions(y):
    """Anzahl Paare i < j mit y[i] > y[j] (wie ``merge_count``)."""
    y = list(y)
    n = len(y)
    buf = [0.0] * n
    s = 0
    width = 1
    # Bottom-up-Merge zählt dieselben (eindeutig bestimmten) Vertauschungen
    while width < n:
        for lo in range(0, n, 2 * width):
            mid = min(lo + width, n)
            hi = min(lo + 2 * width, n)
            i, j, k = lo, mid, lo
            while i < mid and j < hi:
                if y[j] < y[i]:
                    buf[k] = y[j]
                    j += 1
                    s += mid - i
                else:
                    buf[k] = y[i]
                    i += 1
                k += 1
            while i < mid:
                buf[k] = y[i]
                i += 1
                k += 1
            while j < hi:
                buf[k] = y[j]
                j += 1
                k += 1
        y, buf = buf, y
        width *= 2
    return s, y


def kendall_tau_core(x, y):
    """``.kendall_tau_core(x, y)``: Kendalls Tau-b in O(n log n)."""
    x = np.asarray(x, dtype=np.float64).ravel()
    y = np.asarray(y, dtype=np.float64).ravel()
    n = x.size
    if n < 2:
        return _NA
    o = np.lexsort((y, x))          # Gleichstände in (x, y) sind für ys gleichwertig
    xs = x[o].tolist()
    ys = y[o].tolist()
    n1 = n3 = 0
    tx = txy = 1
    for i in range(1, n):
        if xs[i] == xs[i - 1]:
            tx += 1
            if ys[i] == ys[i - 1]:
                txy += 1
            else:
                n3 += txy * (txy - 1) // 2
                txy = 1
        else:
            n1 += tx * (tx - 1) // 2
            n3 += txy * (txy - 1) // 2
            tx = 1
            txy = 1
    n1 += tx * (tx - 1) // 2
    n3 += txy * (txy - 1) // 2
    swaps, ysort = _count_inversions(ys)
    n2 = 0
    ty = 1
    for i in range(1, n):
        if ysort[i] == ysort[i - 1]:
            ty += 1
        else:
            n2 += ty * (ty - 1) // 2
            ty = 1
    n2 += ty * (ty - 1) // 2
    n0 = n * (n - 1) // 2
    LD = np.longdouble
    num = LD(n0) - LD(n1) - LD(n2) + LD(n3) - LD(2.0) * LD(swaps)
    den = np.sqrt(LD(n0 - n1) * LD(n0 - n2))
    if den == 0:
        return _NA
    return float(np.float64(num / den))


# ─────────────────────────────────────────────────────────────────────────────
# Quantilsregression
# ─────────────────────────────────────────────────────────────────────────────

def _solve_spd(A, b, p):
    """Löst A x = b (zeilenweise Listen); ``b`` wird überschrieben."""
    A = list(A)
    Lm = [0.0] * (p * p)
    ok = True
    for i in range(p):
        if not ok:
            break
        for j in range(i + 1):
            s = A[i * p + j]
            for k in range(j):
                s -= Lm[i * p + k] * Lm[j * p + k]
            if i == j:
                if s <= 0.0:
                    ok = False
                    break
                Lm[i * p + i] = math.sqrt(s)
            else:
                Lm[i * p + j] = s / Lm[j * p + j]
    if ok:
        for i in range(p):
            s = b[i]
            for k in range(i):
                s -= Lm[i * p + k] * b[k]
            b[i] = s / Lm[i * p + i]
        for i in range(p - 1, -1, -1):
            s = b[i]
            for k in range(i + 1, p):
                s -= Lm[k * p + i] * b[k]
            b[i] = s / Lm[i * p + i]
        return True
    return _gauss(A, b, p)


def _gauss(A, b, p):
    """Gauss-Elimination mit Pivotsuche; ``A`` (Kopie) und ``b`` werden verändert."""
    for c in range(p):
        piv = c
        for r in range(c + 1, p):
            if abs(A[r * p + c]) > abs(A[piv * p + c]):
                piv = r
        if abs(A[piv * p + c]) < 1e-300:
            return False
        if piv != c:
            for k in range(p):
                A[c * p + k], A[piv * p + k] = A[piv * p + k], A[c * p + k]
            b[c], b[piv] = b[piv], b[c]
        for r in range(c + 1, p):
            f = A[r * p + c] / A[c * p + c]
            for k in range(c, p):
                A[r * p + k] -= f * A[c * p + k]
            b[r] -= f * b[c]
    for i in range(p - 1, -1, -1):
        s = b[i]
        for k in range(i + 1, p):
            s -= A[i * p + k] * b[k]
        b[i] = s / A[i * p + i]
    return True


def _solve_general(A, b, p):
    return _gauss(list(A), b, p)


def _fit(X, b):
    """fit_i = sum_j X(i, j) * b[j] (Schleife über j, je Zeile)."""
    n, p = X.shape
    fit = np.zeros(n)
    for j in range(p):
        fit = fit + X[:, j] * b[j]
    return fit


def _qr_objective(y, X, b, tau):
    r = y - _fit(X, b)
    return _seqsum(r * (tau - (r < 0.0).astype(np.float64)))


def _qr_pick(y, X, beta):
    n, p = X.shape
    r = np.abs(y - _fit(X, beta))
    ordl = _argsort_by_key(r)
    pick = []
    Q = []
    Xl = X.tolist()
    for idx in range(n):
        if len(pick) >= p:
            break
        i = ordl[idx]
        v = list(Xl[i])
        nv = 0.0
        n0 = 0.0
        for j in range(p):
            n0 += v[j] * v[j]
        for q in range(len(pick)):
            d = 0.0
            for j in range(p):
                d += Q[q * p + j] * v[j]
            for j in range(p):
                v[j] -= d * Q[q * p + j]
        for j in range(p):
            nv += v[j] * v[j]
        if nv <= 1e-10 * max(n0, 1e-300):
            continue
        nv = math.sqrt(nv)
        for j in range(p):
            Q.append(v[j] / nv)
        pick.append(i)
    return pick


def _invert_small(A, p):
    """Gauss-Jordan; liefert die Inverse (zeilenweise Liste) oder ``None``."""
    A = list(A)
    Inv = [0.0] * (p * p)
    for i in range(p):
        Inv[i * p + i] = 1.0
    for c in range(p):
        piv = c
        for r in range(c + 1, p):
            if abs(A[r * p + c]) > abs(A[piv * p + c]):
                piv = r
        if abs(A[piv * p + c]) < 1e-300:
            return None
        if piv != c:
            for k in range(p):
                A[c * p + k], A[piv * p + k] = A[piv * p + k], A[c * p + k]
                Inv[c * p + k], Inv[piv * p + k] = Inv[piv * p + k], Inv[c * p + k]
        d = A[c * p + c]
        for k in range(p):
            A[c * p + k] /= d
            Inv[c * p + k] /= d
        for r in range(p):
            if r != c and A[r * p + c] != 0.0:
                f = A[r * p + c]
                for k in range(p):
                    A[r * p + k] -= f * A[c * p + k]
                    Inv[r * p + k] -= f * Inv[c * p + k]
    return Inv


def _qr_subgrad_lp(Xl, G, v, tau, p):
    o = sorted(G, key=lambda a: (tuple(Xl[a]), a))
    A = []
    U = []
    for t in range(len(o)):
        same = t > 0
        j = 0
        while j < p and same:
            same = Xl[o[t]][j] == Xl[o[t - 1]][j]
            j += 1
        if same:
            U[-1] += 1.0
            continue
        A.extend(Xl[o[t]][:p])
        U.append(1.0)
    m = len(U)
    nv = m + p
    w = list(v)
    sgn = [0.0] * p
    S = 0.0
    for i in range(p):
        si = abs(v[i])
        for q in range(m):
            w[i] -= (tau - 1.0) * U[q] * A[q * p + i]
            si += U[q] * abs(A[q * p + i])
        sgn[i] = 1.0 if w[i] >= 0.0 else -1.0
        S = max(S, si)
    ftol = 1e-9 * max(S, 1e-300)

    def col(k, i):
        if k < m:
            return A[k * p + i]
        return sgn[i] if k - m == i else 0.0

    basis = [m + i for i in range(p)]
    upper = [0] * nv
    inb = [0] * nv
    for i in range(p):
        inb[m + i] = 1
    B = [0.0] * (p * p)
    rhs = [0.0] * p
    xB = [0.0] * p
    pi = [0.0] * p
    al = [0.0] * p
    maxit = 50 * nv + 1000
    obj_old = math.inf
    stall = 0
    for _it in range(maxit):
        for i in range(p):
            for r in range(p):
                B[i * p + r] = col(basis[r], i)
        Bi = _invert_small(B, p)
        if Bi is None:
            return False
        for i in range(p):
            rhs[i] = w[i]
            for q in range(m):
                if upper[q]:
                    rhs[i] -= U[q] * A[q * p + i]
        obj = 0.0
        for r in range(p):
            s = 0.0
            for i in range(p):
                s += Bi[r * p + i] * rhs[i]
            xB[r] = s
            if basis[r] >= m:
                obj += s
        if obj <= ftol:
            return True
        if obj < obj_old - 1e-12 * S:
            stall = 0
        else:
            stall += 1
        obj_old = min(obj_old, obj)
        for i in range(p):
            s = 0.0
            for r in range(p):
                if basis[r] >= m:
                    s += Bi[r * p + i]
            pi[i] = s
        bland = stall > 2 * p + 10
        ent = -1
        dirn = 0.0
        dbest = 0.0
        for q in range(m):
            if not inb[q]:
                d = 0.0
                for i in range(p):
                    d -= pi[i] * A[q * p + i]
                gain = d if upper[q] else -d
                if gain > 1e-11 and gain > dbest:
                    ent = q
                    dirn = -1.0 if upper[q] else 1.0
                    dbest = gain
                    if bland:
                        break
        if ent < 0:
            return False
        amax = 0.0
        for r in range(p):
            s = 0.0
            for i in range(p):
                s += Bi[r * p + i] * A[ent * p + i]
            al[r] = dirn * s
            amax = max(amax, abs(s))
        ptol = 1e-12 * max(amax, 1.0)
        tmax = U[ent]
        leave = -1
        to_upper = False
        for r in range(p):
            k = basis[r]
            if al[r] > ptol:
                lim = max(xB[r], 0.0) / al[r]
            elif al[r] < -ptol and k < m:
                lim = max(U[k] - xB[r], 0.0) / -al[r]
            else:
                continue
            if lim < tmax or (lim == tmax and leave >= 0 and k < basis[leave]):
                tmax = lim
                leave = r
                to_upper = al[r] < 0.0
        if leave < 0:
            upper[ent] = 0 if upper[ent] else 1
            continue
        k = basis[leave]
        inb[k] = 0
        if k < m:
            upper[k] = 1 if to_upper else 0
        basis[leave] = ent
        inb[ent] = 1
        upper[ent] = 0
    return False


def _psi_sum(X, r, mask, tau):
    """g[j] = sum_{i in mask} psi_tau(r_i) X(i, j), sequenziell über i."""
    psi = tau - (r[mask] < 0.0).astype(np.float64)
    Xm = X[mask]
    return [_seqsum(psi * Xm[:, j]) for j in range(X.shape[1])]


def _qr_polish(y, X, Xl, beta, tau):
    """Rückgabe (Status, Ecke)."""
    n, p = X.shape
    pick = _qr_pick(y, X, beta)
    if len(pick) < p:
        return 0, None
    A = [0.0] * (p * p)
    b = [0.0] * p
    for a in range(p):
        b[a] = float(y[pick[a]])
        for j in range(p):
            A[a * p + j] = Xl[pick[a]][j]
    if not _solve_general(A, b, p):
        return 0, None
    f_mm = _qr_objective(y, X, beta, tau)
    f_v = _qr_objective(y, X, b, tau)
    if not (f_v <= f_mm):
        return 0, None
    out = list(b)
    inh = np.zeros(n, dtype=bool)
    inh[pick] = True
    yscale = float(np.max(np.abs(y))) if n else 0.0
    yscale = max(0.0, yscale)
    ri = y - _fit(X, b)
    zero = (~inh) & (np.abs(ri) <= 1e-12 * (1.0 + yscale))
    use = (~inh) & ~zero
    g = _psi_sum(X, ri, use, tau)
    Z = np.nonzero(zero)[0].tolist()
    if Z:
        G = list(pick) + Z
        v = [-gj for gj in g]
        return (2 if _qr_subgrad_lp(Xl, G, v, tau, p) else 1), out
    At = [0.0] * (p * p)
    for a in range(p):
        for j in range(p):
            At[j * p + a] = A[a * p + j]
    lam = [-gj for gj in g]
    if not _solve_general(At, lam, p):
        return 1, out
    for a in range(p):
        if lam[a] < tau - 1.0 - 1e-9 or lam[a] > tau + 1e-9:
            return 1, out
    return 2, out


def _qr_exchange(y, X, Xl, tau, h):
    """Rückgabe (Status, letzte Ecke oder ``None``)."""
    n, p = X.shape
    out = None
    if len(h) != p:
        return 0, out
    h = list(h)
    yscale = max(0.0, float(np.max(np.abs(y)))) if n else 0.0
    f_old = math.inf
    maxit = 20 * n + 100
    for _it in range(maxit):
        A = [0.0] * (p * p)
        b = [0.0] * p
        for a in range(p):
            b[a] = float(y[h[a]])
            for j in range(p):
                A[a * p + j] = Xl[h[a]][j]
        if not _solve_general(A, b, p):
            return 0, out
        D = [0.0] * (p * p)
        for c in range(p):
            e = [0.0] * p
            e[c] = 1.0
            if not _solve_general(A, e, p):
                return 0, out
            for j in range(p):
                D[j * p + c] = e[j]
        inh = np.zeros(n, dtype=bool)
        inh[h] = True
        fit = _fit(X, b)
        r = y - fit
        fscale = max(yscale, float(np.max(np.abs(fit))))
        f = _seqsum(r * (tau - (r < 0.0).astype(np.float64)))
        if f > f_old + 1e-12 * (1.0 + abs(f_old)):
            return 0, out
        out = list(b)
        f_old = f
        ztol = 1e-12 * (1.0 + fscale)
        zero = (~inh) & (np.abs(r) <= ztol)
        use = (~inh) & ~zero
        g = _psi_sum(X, r, use, tau)
        Z = np.nonzero(zero)[0]
        lam = [0.0] * p
        for a in range(p):
            s = 0.0
            for j in range(p):
                s += D[j * p + a] * g[j]
            lam[a] = -s
        nz = Z.size
        # K[z, a] = sum_j X(Z[z], j) * D[j, a]
        XZ = X[Z]
        K = np.zeros((nz, p))
        for a in range(p):
            s = np.zeros(nz)
            for j in range(p):
                s = s + XZ[:, j] * D[j * p + a]
            K[:, a] = s
        best = -1e-9
        ba = -1
        bs = 0
        for a in range(p):
            for s in (1, -1):
                sl = (1.0 - tau) + lam[a] if s > 0 else tau - lam[a]
                if nz:
                    cj = s * K[:, a]
                    terms = np.where(cj > 0.0, (1.0 - tau) * cj, -tau * cj)
                    sl = _seqsum(terms, sl) if sl != 0.0 else _seqsum(terms)
                if sl < best:
                    best = sl
                    ba = a
                    bs = s
        if ba < 0:
            if p == 1 or nz == 0:
                return 2, out
            G = list(h) + Z.tolist()
            v = [-gj for gj in g]
            return (2 if _qr_subgrad_lp(Xl, G, v, tau, p) else 1), out
        ci = np.zeros(n)
        for j in range(p):
            ci = ci + X[:, j] * D[j * p + ba]
        c = bs * ci
        okk = (~inh) & ~(np.abs(r) <= ztol) & (c != 0.0)
        with np.errstate(divide="ignore", invalid="ignore"):
            t = r / c
        okk &= t > 0.0
        idx = np.nonzero(okk)[0]
        if idx.size == 0:
            return 0, out
        tk = t[idx]
        o = np.lexsort((idx, tk))
        ks = idx[o]
        cs = np.cumsum(np.concatenate(([best], np.abs(c[ks]))))[1:]
        hit = np.nonzero(cs >= 0.0)[0]
        if hit.size == 0:
            return 0, out
        h[ba] = int(ks[hit[0]])
    return 0, out


def quantile_reg_core(y, X, tau, beta0, sc, tol, maxit):
    """``.quantile_reg_core``; liefert ``(beta, optimal)``."""
    y = np.asarray(y, dtype=np.float64).ravel()
    X = np.asarray(X, dtype=np.float64)
    if X.ndim == 1:
        X = X.reshape(-1, 1)
    n, p = X.shape
    tau = float(tau)
    sc = float(sc)
    tol = float(tol)
    maxit = int(maxit)
    beta = [float(v) for v in np.asarray(beta0, dtype=np.float64).ravel()]
    if p == 0:
        return np.zeros(0), None
    Xl = X.tolist()
    proven = False
    c1 = [_seqsum(X[:, j]) * (tau - 0.5) for j in range(p)]
    epss = (1e-2, 1e-4, 1e-6, 1e-8)
    for e in range(4):
        eps = sc * epss[e]
        early = False
        for it in range(maxit):
            r = y - _fit(X, beta)
            w = 1.0 / (2.0 * (eps + np.abs(r)))
            A = [0.0] * (p * p)
            nb = [0.0] * p
            for j in range(p):
                Xw = X[:, j] * w
                nb[j] = _seqsum(Xw * y, c1[j]) if c1[j] != 0.0 else _seqsum(Xw * y)
                for k in range(j + 1):
                    a = _seqsum(Xw * X[:, k])
                    A[j * p + k] = a
                    A[k * p + j] = a
            if not _solve_spd(A, nb, p):
                raise QuantileRegError("Quantilsregression: singuläres Gleichungssystem.")
            dmax = 0.0
            bmax = 0.0
            for j in range(p):
                dmax = max(dmax, abs(nb[j] - beta[j]))
                bmax = max(bmax, abs(beta[j]))
            done = dmax <= (max(tol, 1e-7) if e < 3 else tol) * (1.0 + bmax)
            beta = list(nb)
            if done:
                break
            if it % 25 == 24:
                st_, vb = _qr_polish(y, X, Xl, beta, tau)
                if st_ == 2:
                    beta = vb
                    proven = True
                    early = True
                    break
        if early:
            break
        st, vb = _qr_polish(y, X, Xl, beta, tau)
        if st == 2:
            beta = vb
            proven = True
            break
        if e == 3:
            f_mm = _qr_objective(y, X, beta, tau)
            sx, xb = _qr_exchange(y, X, Xl, tau, _qr_pick(y, X, beta))
            if sx == 2:
                beta = xb
                proven = True
            elif xb is not None and len(xb) == p and _qr_objective(y, X, xb, tau) <= f_mm:
                beta = xb
            elif st == 1:
                beta = vb
    return np.array(beta, dtype=np.float64), proven


# ─────────────────────────────────────────────────────────────────────────────
# HMM: skalierter Vorwärts-Rückwärts-Schritt
# ─────────────────────────────────────────────────────────────────────────────

def hmm_forward_backward(B, A, p0):
    """``.hmm_forward_backward(B, A, p0)`` → dict filtered, smoothed, xi, scale."""
    Bm = np.asarray(B, dtype=np.float64)
    T, K = Bm.shape
    Al = np.asarray(A, dtype=np.float64).tolist()
    p0 = [float(v) for v in np.asarray(p0, dtype=np.float64).ravel()]
    Bl = Bm.tolist()
    al = [[0.0] * K for _ in range(T)]
    be = [[0.0] * K for _ in range(T)]
    cs = [0.0] * T
    a = [0.0] * K
    s = 0.0
    B0 = Bl[0]
    for j in range(K):
        a[j] = p0[j] * B0[j]
        s += a[j]
    cs[0] = s
    row = al[0]
    for j in range(K):
        row[j] = a[j] / s
    rK = range(K)
    for t in range(1, T):
        s = 0.0
        prev = al[t - 1]
        Bt = Bl[t]
        for j in rK:
            v = 0.0
            for i in rK:
                v += prev[i] * Al[i][j]
            a[j] = v * Bt[j]
            s += a[j]
        cs[t] = s
        row = al[t]
        for j in rK:
            row[j] = a[j] / s
    for j in rK:
        be[T - 1][j] = 1.0
    tmp = [0.0] * K
    for t in range(T - 2, -1, -1):
        Bn = Bl[t + 1]
        bn = be[t + 1]
        for j in rK:
            tmp[j] = Bn[j] * bn[j]
        c = cs[t + 1]
        bt = be[t]
        for i in rK:
            v = 0.0
            Ai = Al[i]
            for j in rK:
                v += Ai[j] * tmp[j]
            bt[i] = v / c
    alm = np.array(al, dtype=np.float64).reshape(T, K)
    bem = np.array(be, dtype=np.float64).reshape(T, K)
    csv = np.array(cs, dtype=np.float64)
    ga = alm * bem
    rs = np.zeros(T)
    for j in rK:
        rs = rs + ga[:, j]
    ga = ga / rs[:, None]
    xi = np.zeros((K, K))
    if T > 1:
        tmpm = Bm[1:] * bem[1:]
        for i in rK:
            for j in rK:
                terms = alm[:-1, i] * tmpm[:, j] * Al[i][j] / csv[1:]
                xi[i, j] = _seqsum(terms)
    return {"filtered": alm, "smoothed": ga, "xi": xi, "scale": csv}
