"""Optimierungskerne (Port aus ``r/src/research_core.cpp``).

- :func:`proj_box_simplex`  exakte Projektion auf {w : sum w = 1, lo <= w <= hi}
  (Knickpunkt-Verfahren), ``.proj_box_simplex``
- :func:`qp_box_simplex`    min 0.5 w'Qw + c'w auf dem beschraenkten Simplex
  (FISTA mit adaptivem Neustart), ``.qp_box_simplex``
- :func:`min_cvar_core`     minimaler CVaR (geglaettete Rockafellar-Uryasev-
  Formulierung, FISTA mit Schrittweitensuche), ``.min_cvar_core``
- :func:`min_cdar_core`     minimaler CDaR (projizierter Subgradient),
  ``.min_cdar_core``

Mit gebauter Erweiterung rechnen die gemeinsamen Kerne von R und Python
(``r/src/research_core_impl.cpp`` über ``simlev._ext``, Etappe 7.3a); sonst und
mit ``SIMLEV_NO_EXT=1`` die Python-Ports darunter (bitgleich).

Rechenreihenfolge 1:1 aus dem C++-Code (double-Akkumulation, keine FMA,
libm ``exp``/``log1p`` ueber :mod:`math`). ``std::sort`` (libstdc++-Introsort,
nicht stabil) wird exakt nachgebildet, wenn das Ergebnis von der Reihenfolge
gleichrangiger Elemente abhaengen kann (+0/-0 bzw. NaN unter den Knickpunkten);
sonst genuegt die (eindeutige) sortierte Folge.
"""
from __future__ import annotations

import math

import numpy as np

from ._r import env as _env
from ._r.rnum import c_div as _dv

__all__ = ["proj_box_simplex", "qp_box_simplex", "min_cvar_core", "min_cdar_core", "quantile7"]

_INF = math.inf


# ── libstdc++ std::sort (Introsort) ─────────────────────────────────────────

def _lt_pair(a, b):
    # std::pair<double,int>::operator<
    return a[0] < b[0] or (not (b[0] < a[0]) and a[1] < b[1])


def _std_sort(v, less=_lt_pair):
    """``std::sort`` aus libstdc++ (GCC 13) auf der Liste ``v`` (in place)."""
    n = len(v)
    if n < 2:
        return v
    depth = 2 * (n.bit_length() - 1)
    _introsort_loop(v, 0, n, depth, less)
    _final_insertion_sort(v, 0, n, less)
    return v


def _move_median_to_first(v, result, a, b, c, less):
    if less(v[a], v[b]):
        if less(v[b], v[c]):
            v[result], v[b] = v[b], v[result]
        elif less(v[a], v[c]):
            v[result], v[c] = v[c], v[result]
        else:
            v[result], v[a] = v[a], v[result]
    elif less(v[a], v[c]):
        v[result], v[a] = v[a], v[result]
    elif less(v[b], v[c]):
        v[result], v[c] = v[c], v[result]
    else:
        v[result], v[b] = v[b], v[result]


def _unguarded_partition(v, first, last, pivot, less):
    while True:
        while less(v[first], v[pivot]):
            first += 1
        last -= 1
        while less(v[pivot], v[last]):
            last -= 1
        if not (first < last):
            return first
        v[first], v[last] = v[last], v[first]
        first += 1


def _adjust_heap(v, first, hole, length, value, less):
    top = hole
    second = hole
    while second < (length - 1) // 2:
        second = 2 * (second + 1)
        if less(v[first + second], v[first + second - 1]):
            second -= 1
        v[first + hole] = v[first + second]
        hole = second
    if (length & 1) == 0 and second == (length - 2) // 2:
        second = 2 * (second + 1)
        v[first + hole] = v[first + second - 1]
        hole = second - 1
    parent = (hole - 1) // 2
    while hole > top and less(v[first + parent], value):
        v[first + hole] = v[first + parent]
        hole = parent
        parent = (hole - 1) // 2
    v[first + hole] = value


def _heap_sort(v, first, last, less):
    length = last - first
    if length >= 2:
        parent = (length - 2) // 2
        while True:
            _adjust_heap(v, first, parent, length, v[first + parent], less)
            if parent == 0:
                break
            parent -= 1
    while last - first > 1:
        last -= 1
        value = v[last]
        v[last] = v[first]
        _adjust_heap(v, first, 0, last - first, value, less)


def _introsort_loop(v, first, last, depth, less):
    while last - first > 16:
        if depth == 0:
            _heap_sort(v, first, last, less)
            return
        depth -= 1
        mid = first + (last - first) // 2
        _move_median_to_first(v, first, first + 1, mid, last - 1, less)
        cut = _unguarded_partition(v, first + 1, last, first, less)
        _introsort_loop(v, cut, last, depth, less)
        last = cut


def _unguarded_linear_insert(v, last, less):
    val = v[last]
    nxt = last - 1
    while less(val, v[nxt]):
        v[last] = v[nxt]
        last = nxt
        nxt -= 1
    v[last] = val


def _insertion_sort(v, first, last, less):
    if first == last:
        return
    for i in range(first + 1, last):
        if less(v[i], v[first]):
            val = v[i]
            v[first + 1:i + 1] = v[first:i]
            v[first] = val
        else:
            _unguarded_linear_insert(v, i, less)


def _final_insertion_sort(v, first, last, less):
    if last - first > 16:
        _insertion_sort(v, first, first + 16, less)
        for i in range(first + 16, last):
            _unguarded_linear_insert(v, i, less)
    else:
        _insertion_sort(v, first, last, less)


# ── Projektion ──────────────────────────────────────────────────────────────

def _proj(v, lo, hi, n):
    """Kern von ``proj_box_simplex`` auf Python-Listen (liefert Liste)."""
    slo = 0.0
    shi = 0.0
    for i in range(n):
        slo += lo[i]
        shi += hi[i]
    if shi <= 1.0:
        return list(hi[:n])
    if slo >= 1.0:
        return list(lo[:n])
    bp = []
    amb = False
    for i in range(n):
        a = v[i] - hi[i]
        b = v[i] - lo[i]
        if a == 0.0 or b == 0.0 or a != a or b != b:
            amb = True
        bp.append((a, 1))
        bp.append((b, -1))
    if amb and _ambiguous(bp):
        _std_sort(bp)
    else:
        bp.sort()
    t = bp[0][0]
    g = shi
    t_star = bp[0][0]
    k = 0
    found = False
    for tn, sgn in bp:
        gn = g - k * (tn - t)
        if gn <= 1.0 and k > 0:
            t_star = t + (g - 1.0) / k
            found = True
            break
        g = gn
        t = tn
        k += sgn
    if not found:
        t_star = t + ((g - 1.0) / k if k > 0 else 0.0)
    out = []
    for i in range(n):
        x = v[i] - t_star
        # std::max(lo, x): x wenn lo < x, sonst lo; std::min(hi, y): y wenn y < hi, sonst hi
        y = x if lo[i] < x else lo[i]
        out.append(y if y < hi[i] else hi[i])
    return out


def _ambiguous(bp):
    has_nan = any(a != a for a, _ in bp)
    if has_nan:
        return True
    pos = neg = False
    for a, _ in bp:
        if a == 0.0:
            if math.copysign(1.0, a) > 0:
                pos = True
            else:
                neg = True
    return pos and neg


def _fl(x):
    return [float(e) for e in np.asarray(x, dtype=np.float64).ravel()]


def _c1(x):
    """Zahlenvektor als zusammenhängendes float64-Feld für den gemeinsamen Kern."""
    return np.ascontiguousarray(np.asarray(x, dtype=np.float64).ravel())


def _cint(v):
    """Ganzzahl im Bereich von C ``int`` (sonst rechnet der Python-Port)."""
    return -2147483648 <= v <= 2147483647


def proj_box_simplex(v, lo, hi):
    """``.proj_box_simplex(v, lo, hi)``: Projektion auf den beschraenkten Simplex."""
    ext = _env.ext()
    if ext is not None:
        va, la, ha = _c1(v), _c1(lo), _c1(hi)
        if la.size == va.size == ha.size:
            out = np.empty(va.size)
            ext.proj_box_simplex(va, la, ha, out)
            return out
    v = _fl(v)
    lo = _fl(lo)
    hi = _fl(hi)
    return np.array(_proj(v, lo, hi, len(v)), dtype=np.float64)


# ── Quadratisches Programm ─────────────────────────────────────────────────

def qp_box_simplex(Q, cvec, lo, hi, w0, L, maxit, tol):
    """``.qp_box_simplex``: FISTA mit adaptivem Neustart fuer min 0.5 w'Qw + c'w."""
    Q = np.asarray(Q, dtype=np.float64)
    n = Q.shape[1]
    ext = _env.ext()
    if ext is not None and Q.ndim == 2 and Q.shape[0] >= n and _cint(int(maxit)):
        ca, la, ha, wa = _c1(cvec), _c1(lo), _c1(hi), _c1(w0)
        if min(ca.size, la.size, ha.size, wa.size) >= n:
            out = np.empty(n)
            ext.qp_box_simplex(np.ravel(Q, order="F"), Q.shape[0], n, ca, la, ha, wa, float(L), int(maxit),
                               float(tol), out)
            return out
    Qr = [[float(Q[i, j]) for j in range(n)] for i in range(n)]
    c = _fl(cvec)
    lo = _fl(lo)
    hi = _fl(hi)
    L = float(L)
    tol = float(tol)
    maxit = int(maxit)
    w = _proj(_fl(w0), lo, hi, n)
    y = list(w)
    t = 1.0
    rng = range(n)
    g = [0.0] * n
    tmp = [0.0] * n
    for _ in range(maxit):
        for i in rng:
            s = c[i]
            qi = Qr[i]
            for j in rng:
                s += qi[j] * y[j]
            g[i] = s
            tmp[i] = y[i] - _dv(s, L)
        wn = _proj(tmp, lo, hi, n)
        dmax = 0.0
        dr = 0.0
        for i in rng:
            dd = wn[i] - w[i]
            a = math.fabs(dd)
            if dmax < a:
                dmax = a
            dr += g[i] * dd
        if dmax < tol:
            w = wn
            break
        if dr > 0.0:
            t = 1.0
            y = list(wn)
            w = wn
            continue
        tn = (1.0 + math.sqrt(1.0 + 4.0 * t * t)) / 2.0
        mom = (t - 1.0) / tn
        y = [wn[i] + mom * (wn[i] - w[i]) for i in rng]
        w = wn
        t = tn
    return np.array(w, dtype=np.float64)


# ── Minimaler CVaR ─────────────────────────────────────────────────────────

def _seqsum(a):
    """Summe in Reihenfolge, Startwert 0.0 (wie ``double acc = 0; acc += a[i]``)."""
    if a.size == 0:
        return 0.0
    return float(np.cumsum(a)[-1]) + 0.0


_exp = math.exp
_log1p = math.log1p


def _softplus(z):
    if z > 30.0:
        return z
    try:
        e = _exp(z)
    except OverflowError:
        return _INF
    return _log1p(e)


def _logistic(z):
    if z >= 0.0:
        return 1.0 / (1.0 + _exp(-z))
    e = _exp(z)
    return e / (1.0 + e)


def min_cvar_core(R, alpha, lo, hi, w0, zeta0, scales, maxit):
    """``.min_cvar_core``: minimaler CVaR (geglaettet, FISTA mit Schrittweitensuche)."""
    R = np.asarray(R, dtype=np.float64)
    if R.ndim == 1:
        R = R.reshape(-1, 1)
    T, N = R.shape
    ext = _env.ext()
    if ext is not None and _cint(int(maxit)):
        la, ha, wa = _c1(lo), _c1(hi), _c1(w0)
        if min(la.size, ha.size, wa.size) >= N:
            out = np.empty(N)
            ext.min_cvar_core(np.ravel(R, order="F"), T, N, float(alpha), la, ha, wa, float(zeta0), _c1(scales),
                              int(maxit), out)
            return out
    alpha = float(alpha)
    aT = alpha * T
    lo = _fl(lo)
    hi = _fl(hi)
    w0 = _fl(w0)
    cols = [np.ascontiguousarray(R[:, i]) for i in range(N)]
    x = w0[:N] + [float(zeta0)]
    maxit = int(maxit)

    def port_loss(z):
        loss = np.zeros(T)
        for i in range(N):
            wi = z[i]
            if wi == 0.0:
                continue
            loss = loss - cols[i] * wi
        return loss

    for sc in _fl(scales):
        def f(z):
            u = ((port_loss(z) - z[N]) / sc).tolist()
            acc = 0.0
            for zz in u:
                acc += _softplus(zz)
            return z[N] + _dv(sc * acc, aT)

        def grad(z):
            u = ((port_loss(z) - z[N]) / sc).tolist()
            p = [_logistic(zz) for zz in u]
            sp = 0.0
            for q in p:
                sp += q
            pa = np.array(p, dtype=np.float64)
            gr = [0.0] * (N + 1)
            for i in range(N):
                acc = _seqsum(cols[i] * pa)
                gr[i] = _dv(-acc, aT)
            gr[N] = 1.0 - _dv(sp, aT)
            return gr

        yv = list(x)
        t = 1.0
        L = _dv(1.0, alpha * sc)
        xn = list(x)
        for _ in range(maxit):
            g = grad(yv)
            fy = f(yv)
            L /= 2.0
            for _ls in range(60):
                tmp = [yv[i] - _dv(g[i], L) for i in range(N + 1)]
                xn = _proj(tmp, lo, hi, N) + [tmp[N]]
                lin = 0.0
                sq = 0.0
                for i in range(N + 1):
                    dx = xn[i] - yv[i]
                    lin += g[i] * dx
                    sq += dx * dx
                if f(xn) <= fy + lin + L / 2.0 * sq + 1e-15:
                    break
                L *= 2.0
            dmax = 0.0
            dr = 0.0
            for i in range(N + 1):
                dd = xn[i] - x[i]
                a = math.fabs(dd)
                if dmax < a:
                    dmax = a
                dr += g[i] * dd
            if dmax < 1e-9:
                x = xn
                break
            if dr > 0.0:
                t = 1.0
                yv = list(xn)
                x = xn
                continue
            tn = (1.0 + math.sqrt(1.0 + 4.0 * t * t)) / 2.0
            mom = (t - 1.0) / tn
            yv = [xn[i] + mom * (xn[i] - x[i]) for i in range(N + 1)]
            x = xn
            t = tn
    return np.array(x[:N], dtype=np.float64)


# ── Minimaler CDaR ─────────────────────────────────────────────────────────

def _heap_select(v, first, middle, last, less):
    length = middle - first
    if length >= 2:
        parent = (length - 2) // 2
        while True:
            _adjust_heap(v, first, parent, length, v[first + parent], less)
            if parent == 0:
                break
            parent -= 1
    for i in range(middle, last):
        if less(v[i], v[first]):
            value = v[i]
            v[i] = v[first]
            _adjust_heap(v, first, 0, length, value, less)


def _nth_element(v, nth, less):
    """``std::nth_element`` aus libstdc++ (GCC 13, Introselect) auf der Liste ``v`` (in place)."""
    first, last = 0, len(v)
    if first == last or nth == last:
        return v
    depth = 2 * ((last - first).bit_length() - 1)
    while last - first > 3:
        if depth == 0:
            _heap_select(v, first, nth + 1, last, less)
            v[first], v[nth] = v[nth], v[first]
            return v
        depth -= 1
        mid = first + (last - first) // 2
        _move_median_to_first(v, first, first + 1, mid, last - 1, less)
        cut = _unguarded_partition(v, first + 1, last, first, less)
        if cut <= nth:
            first = cut
        else:
            last = cut
    _insertion_sort(v, first, last, less)
    return v


def _lt(a, b):
    return a < b


def quantile7(x, p):
    """Quantil Typ 7 wie ``quantile7`` in research_core.cpp (nth_element + min_element).

    Ohne NaN liefert die stabile Sortierung dieselben Werte; mit NaN (Vergleiche
    immer falsch) hängt das Ergebnis von der Reihenfolge ab, die ``std::nth_element``
    herstellt, deshalb dann dessen Nachbildung.
    """
    n = len(x)
    if n == 0:
        from ._r.fmt import NA_REAL
        return NA_REAL                      # leere Eingabe → NA (wie research_core.cpp)
    h = (n - 1) * p
    lo = int(math.floor(h))
    frac = h - lo
    a = np.asarray(x, dtype=np.float64)
    if np.isnan(a).any():
        v = _nth_element(a.tolist(), lo, _lt)
        xl = v[lo]
        if frac == 0.0 or lo + 1 >= n:
            return xl
        xh = v[lo + 1]
        for j in range(lo + 2, n):
            if v[j] < xh:
                xh = v[j]
        return xl + frac * (xh - xl)
    s = np.sort(a, kind="stable")
    xl = float(s[lo])
    if frac == 0.0 or lo + 1 >= n:
        return xl
    xh = float(s[lo + 1])
    return xl + frac * (xh - xl)


def _cdar_of(r, alpha):
    if np.isnan(r).any():
        # NaN: Schleife wie cdar_of in research_core.cpp (std::max hält pk bei NaN)
        D = []
        c = 0.0
        pk = 0.0
        for x in r.tolist():
            c += x
            if pk < c:
                pk = c
            D.append(pk - c)
        v = quantile7(D, 1.0 - alpha)
        acc = 0.0
        m = 0
        for d in D:
            if d >= v:
                acc += d
                m += 1
        return acc / m if m else 0.0
    c = np.cumsum(r) + 0.0
    pk = np.maximum.accumulate(np.concatenate(([0.0], c)))[1:]
    D = pk - c
    v = quantile7(D, 1.0 - alpha)
    sel = D[D >= v]
    m = sel.size
    return _seqsum(sel) / m if m else 0.0


def min_cdar_core(R, alpha, lo, hi, iters):
    """``.min_cdar_core``: minimaler CDaR (projizierter Subgradient, bestes Iterat)."""
    R = np.asarray(R, dtype=np.float64)
    if R.ndim == 1:
        R = R.reshape(-1, 1)
    T, N = R.shape
    ext = _env.ext()
    if ext is not None and _cint(int(iters)):
        la, ha = _c1(lo), _c1(hi)
        if min(la.size, ha.size) >= N:
            out = np.empty(N)
            ext.min_cdar_core(np.ravel(R, order="F"), T, N, float(alpha), la, ha, int(iters), out)
            return out
    alpha = float(alpha)
    lo = _fl(lo)
    hi = _fl(hi)
    iters = int(iters)
    CR = np.zeros((T + 1, N))
    for i in range(N):
        CR[1:, i] = np.cumsum(R[:, i]) + 0.0
    sabs = _seqsum(np.abs(R.ravel(order="F")))
    sc = _dv(sabs, float(T) * N) * math.sqrt(float(T))
    cols = [np.ascontiguousarray(R[:, i]) for i in range(N)]
    crc = [np.ascontiguousarray(CR[:, i]) for i in range(N)]

    def port(z):
        a = np.zeros(T)
        for i in range(N):
            a = a + cols[i] * z[i]
        return a

    w = _proj([1.0 / N] * N, lo, hi, N)
    fbest = _cdar_of(port(w), alpha)
    best = list(w)
    sqN = math.sqrt(float(N))
    idx = np.arange(T + 1)
    for it in range(1, iters + 1):
        C = np.zeros(T + 1)
        for i in range(N):
            C = C + crc[i] * w[i]
        if np.isnan(C).any():
            # NaN: laufendes Maximum wie in research_core.cpp (a >= pk falsch bei NaN)
            pkv = -_INF
            am = 0
            argl = [0] * (T + 1)
            Dl = [0.0] * T
            for s_, a_ in enumerate(C.tolist()):
                if a_ >= pkv:
                    pkv = a_
                    am = s_
                argl[s_] = am
                if s_ > 0:
                    Dl[s_ - 1] = pkv - a_
            arg = np.array(argl, dtype=np.int64)
            Dt = np.array(Dl, dtype=np.float64)
        else:
            pk = np.maximum.accumulate(C)
            prev = np.concatenate(([-_INF], pk[:-1]))
            arg = np.maximum.accumulate(np.where(C >= prev, idx, 0))
            Dt = (pk - C)[1:]
        v = quantile7(Dt, 1.0 - alpha)
        sel = np.nonzero(Dt >= v)[0]
        m = sel.size
        ti = sel + 1
        pi = arg[ti]
        g = [0.0] * N
        gn = 0.0
        for i in range(N):
            gi = _seqsum(crc[i][pi] - crc[i][ti])
            gi = _dv(gi, m)
            g[i] = gi
            gn += gi * gi
        den = math.sqrt(gn) / sqN
        step = _dv(_dv(0.5, sc * math.sqrt(float(it))), den if 1e-12 < den else 1e-12)
        tmp = [w[i] - step * g[i] / sqN for i in range(N)]
        w = _proj(tmp, lo, hi, N)
        f = _cdar_of(port(w), alpha)
        if f < fbest:
            fbest = f
            best = list(w)
    return np.array(best, dtype=np.float64)
