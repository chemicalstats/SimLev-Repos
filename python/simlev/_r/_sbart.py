"""Glättungsspline wie R's ``smooth.spline`` (``sbart.c``, ``sslvrg.f``,
``sgram.f``, ``stxwx.f``, ``sinerp.f``, ``bsplvd.f``, ``bvalue.f``,
``bvalus.f``, LINPACK ``dpbfa``/``dpbsl``, ``interv``), bitgleich in Python.

Felder 1-basiert (Platzhalter an Stelle 0), Matrizen spaltenweise flach wie
in Fortran.
"""
from __future__ import annotations

import bisect
import math

__all__ = ["sbart", "bvalue", "bvalus", "interv"]

_BIG_f = 1e100
_C_GOLD = 0.381966011250105151795413165634


def interv(xt, n, x):
    """``interv(xt, n, x, FALSE, FALSE, ilo, mflag)``; ``xt`` 1-basiert.

    Liefert (left, mflag). Das Ergebnis hängt nicht vom Startwert ab.
    """
    if n == 0:
        return 0, 0
    # größtes i mit xt[i] <= x (1-basiert); xt[1..n]
    i = bisect.bisect_right(xt, x, 1, n + 1) - 1
    if i < 1:
        return 0, -1
    if i >= n:
        return n, 1
    return i, 0


class _Bsplvb:
    """``bsplvb`` mit gespeichertem Zustand (``SAVE j, deltal, deltar``)."""

    def __init__(self):
        self.j = 1
        self.deltal = [0.0] * 21
        self.deltar = [0.0] * 21

    def __call__(self, t, jhigh, index, x, left, biatx):
        # t 1-basiert; biatx 1-basiert (Liste, Elemente 1..jhigh)
        if index != 2:
            self.j = 1
            biatx[1] = 1.0
            if self.j >= jhigh:
                return
        deltal = self.deltal
        deltar = self.deltar
        while True:
            j = self.j
            jp1 = j + 1
            deltar[j] = t[left + j] - x
            deltal[j] = x - t[left + 1 - j]
            saved = 0.0
            for i in range(1, j + 1):
                term = biatx[i] / (deltar[i] + deltal[jp1 - i])
                biatx[i] = saved + deltar[i] * term
                saved = deltal[jp1 - i] * term
            biatx[jp1] = saved
            self.j = jp1
            if not (self.j < jhigh):
                break


_bsplvb = _Bsplvb()


def bsplvd(t, k, x, left, nderiv):
    """``bsplvd``; liefert ``dbiatx`` als dict-artige Matrix (k×nderiv, 1-basiert)."""
    mhigh = max(min(nderiv, k), 1)
    kp1 = k + 1
    # dbiatx(k, nderiv) spaltenweise: index (i, m) -> (i-1) + (m-1)*k + 1
    db = [0.0] * (k * max(nderiv, 1) + 1)
    col1 = [0.0] * (k + 2)
    # bsplvb schreibt in dbiatx(.,1) (erste Spalte); wir nutzen col1 als Sicht
    _bsplvb(t, kp1 - mhigh, 1, x, left, col1)
    for i in range(1, k + 1):
        db[i] = col1[i]

    def D(i, m):
        return (i - 1) + (m - 1) * k + 1
    if mhigh == 1:
        return db, D
    ideriv = mhigh
    for m in range(2, mhigh + 1):
        jp1mid = 1
        for j in range(ideriv, k + 1):
            db[D(j, ideriv)] = col1[jp1mid]
            jp1mid += 1
        ideriv -= 1
        _bsplvb(t, kp1 - ideriv, 2, x, left, col1)
    for i in range(1, k + 1):
        db[D(i, 1)] = col1[i]
    a = [[0.0] * (k + 1) for _ in range(k + 1)]   # a[j][i] = a(j,i)
    jlow = 1
    for i in range(1, k + 1):
        for j in range(jlow, k + 1):
            a[j][i] = 0.0
        jlow = i
        a[i][i] = 1.0
    for m in range(2, mhigh + 1):
        kp1mm = kp1 - m
        fkp1mm = float(kp1mm)
        il = left
        i = k
        for _ in range(1, kp1mm + 1):
            factor = fkp1mm / (t[il + kp1mm] - t[il])
            for j in range(1, i + 1):
                a[i][j] = (a[i][j] - a[i - 1][j]) * factor
            il -= 1
            i -= 1
        for i in range(1, k + 1):
            s = 0.0
            jlow = max(i, m)
            for j in range(jlow, k + 1):
                s = a[j][i] * db[D(j, m)] + s
            db[D(i, m)] = s
    return db, D


def bvalue(t, bcoef, n, k, x, jderiv):
    """``bvalue`` (t, bcoef 1-basiert)."""
    import warnings
    if jderiv >= k:
        return 0.0
    if (x != t[n + 1]) or (t[n + 1] != t[n + k]):
        i, mflag = interv(t, n + k, x)
        if mflag != 0:
            warnings.warn("bvalue()  mflag != 0: should never happen!")
            return 0.0
    else:
        i = n
    km1 = k - 1
    if km1 <= 0:
        return bcoef[i]
    aj = [0.0] * 21
    dm = [0.0] * 21
    dp = [0.0] * 21
    jcmin = 1
    imk = i - k
    if imk >= 0:
        for j in range(1, km1 + 1):
            dm[j] = x - t[i + 1 - j]
    else:
        jcmin = 1 - imk
        for j in range(1, i + 1):
            dm[j] = x - t[i + 1 - j]
        for j in range(i, km1 + 1):
            aj[k - j] = 0.0
            dm[j] = dm[i]
    jcmax = k
    nmi = n - i
    if nmi >= 0:
        for j in range(1, km1 + 1):
            dp[j] = t[i + j] - x
    else:
        jcmax = k + nmi
        for j in range(1, jcmax + 1):
            dp[j] = t[i + j] - x
        for j in range(jcmax, km1 + 1):
            aj[j + 1] = 0.0
            dp[j] = dp[jcmax]
    for jc in range(jcmin, jcmax + 1):
        aj[jc] = bcoef[imk + jc]
    if jderiv >= 1:
        for j in range(1, jderiv + 1):
            kmj = k - j
            fkmj = float(kmj)
            ilo = kmj
            for jj in range(1, kmj + 1):
                aj[jj] = ((aj[jj + 1] - aj[jj]) / (dm[ilo] + dp[jj])) * fkmj
                ilo -= 1
    if jderiv != km1:
        for j in range(jderiv + 1, km1 + 1):
            kmj = k - j
            ilo = kmj
            for jj in range(1, kmj + 1):
                aj[jj] = (aj[jj + 1] * dm[ilo] + aj[jj] * dp[jj]) / (dm[ilo] + dp[jj])
                ilo -= 1
    return aj[1]


def bvalus(knot, coef, nk, xs, order):
    return [bvalue(knot, coef, nk, 4, x, order) for x in xs]


def _ddot(n, x, xb, y, yb):
    s = 0.0
    for k in range(n):
        s = s + x[xb + k] * y[yb + k]
    return s


def _dpbfa(abd, lda, n, m):
    """LINPACK dpbfa; abd(i,j) = abd[(i-1)+(j-1)*lda+1]."""
    def A(i, j):
        return (i - 1) + (j - 1) * lda + 1
    for j in range(1, n + 1):
        info = j
        s = 0.0
        ik = m + 1
        jk = max(j - m, 1)
        mu = max(m + 2 - j, 1)
        if m >= mu:
            for k in range(mu, m + 1):
                t = abd[A(k, j)] - _ddot(k - mu, abd, A(ik, jk), abd, A(mu, j))
                t = t / abd[A(m + 1, jk)]
                abd[A(k, j)] = t
                s = s + t * t
                ik -= 1
                jk += 1
        s = abd[A(m + 1, j)] - s
        if s <= 0.0:
            return info
        abd[A(m + 1, j)] = math.sqrt(s)
    return 0


def _dpbsl(abd, lda, n, m, b):
    def A(i, j):
        return (i - 1) + (j - 1) * lda + 1
    for k in range(1, n + 1):
        lm = min(k - 1, m)
        la = m + 1 - lm
        lb = k - lm
        t = _ddot(lm, abd, A(la, k), b, lb)
        b[k] = (b[k] - t) / abd[A(m + 1, k)]
    for kb in range(1, n + 1):
        k = n + 1 - kb
        lm = min(k - 1, m)
        la = m + 1 - lm
        lb = k - lm
        b[k] = b[k] / abd[A(m + 1, k)]
        t = -b[k]
        if lm > 0 and t != 0.0:
            base = A(la, k)
            for q in range(lm):
                b[lb + q] = b[lb + q] + t * abd[base + q]


def sgram(tb, nb):
    sg0 = [0.0] * (nb + 1)
    sg1 = [0.0] * (nb + 1)
    sg2 = [0.0] * (nb + 1)
    sg3 = [0.0] * (nb + 1)
    for i in range(1, nb + 1):
        ileft, mflag = interv(tb, nb + 1, tb[i])
        db, D = bsplvd(tb, 4, tb[i], ileft, 3)
        yw1 = [0.0] + [db[D(ii, 3)] for ii in range(1, 5)]
        db, D = bsplvd(tb, 4, tb[i + 1], ileft, 3)
        yw2 = [0.0] + [db[D(ii, 3)] - yw1[ii] for ii in range(1, 5)]
        wpt = tb[i + 1] - tb[i]

        def term(ii, jj):
            return wpt * ((yw1[ii] * yw1[jj] + (yw2[ii] * yw1[jj] + yw2[jj] * yw1[ii]) * 0.5)
                          + yw2[ii] * yw2[jj] * 0.3330)
        if ileft >= 4:
            for ii in range(1, 5):
                jj = ii
                sg0[ileft - 4 + ii] = sg0[ileft - 4 + ii] + term(ii, jj)
                jj = ii + 1
                if jj <= 4:
                    sg1[ileft + ii - 4] = sg1[ileft + ii - 4] + term(ii, jj)
                jj = ii + 2
                if jj <= 4:
                    sg2[ileft + ii - 4] = sg2[ileft + ii - 4] + term(ii, jj)
                jj = ii + 3
                if jj <= 4:
                    sg3[ileft + ii - 4] = sg3[ileft + ii - 4] + term(ii, jj)
        elif ileft == 3:
            for ii in range(1, 4):
                jj = ii
                sg0[ileft - 3 + ii] = sg0[ileft - 3 + ii] + term(ii, jj)
                jj = ii + 1
                if jj <= 3:
                    sg1[ileft + ii - 3] = sg1[ileft + ii - 3] + term(ii, jj)
                jj = ii + 2
                if jj <= 3:
                    sg2[ileft + ii - 3] = sg2[ileft + ii - 3] + term(ii, jj)
        elif ileft == 2:
            for ii in range(1, 3):
                jj = ii
                sg0[ileft - 2 + ii] = sg0[ileft - 2 + ii] + term(ii, jj)
                jj = ii + 1
                if jj <= 2:
                    sg1[ileft + ii - 2] = sg1[ileft + ii - 2] + term(ii, jj)
        elif ileft == 1:
            ii = 1
            jj = ii
            sg0[ileft - 1 + ii] = sg0[ileft - 1 + ii] + term(ii, jj)
    return sg0, sg1, sg2, sg3


def stxwx(x, z, w, k, xknot, n):
    y = [0.0] * (n + 1)
    hs0 = [0.0] * (n + 1)
    hs1 = [0.0] * (n + 1)
    hs2 = [0.0] * (n + 1)
    hs3 = [0.0] * (n + 1)
    eps = 0.1e-9
    for i in range(1, k + 1):
        ileft, mflag = interv(xknot, n + 1, x[i])
        if mflag == 1:
            if x[i] <= (xknot[ileft] + eps):
                ileft -= 1
            else:
                return y, hs0, hs1, hs2, hs3
        db, D = bsplvd(xknot, 4, x[i], ileft, 1)
        v1, v2, v3, v4 = db[1], db[2], db[3], db[4]
        w2 = w[i] * w[i]
        j = ileft - 4 + 1
        y[j] = y[j] + w2 * z[i] * v1
        hs0[j] = hs0[j] + w2 * (v1 * v1)
        hs1[j] = hs1[j] + w2 * v1 * v2
        hs2[j] = hs2[j] + w2 * v1 * v3
        hs3[j] = hs3[j] + w2 * v1 * v4
        j = ileft - 4 + 2
        y[j] = y[j] + w2 * z[i] * v2
        hs0[j] = hs0[j] + w2 * (v2 * v2)
        hs1[j] = hs1[j] + w2 * v2 * v3
        hs2[j] = hs2[j] + w2 * v2 * v4
        j = ileft - 4 + 3
        y[j] = y[j] + w2 * z[i] * v3
        hs0[j] = hs0[j] + w2 * (v3 * v3)
        hs1[j] = hs1[j] + w2 * v3 * v4
        j = ileft - 4 + 4
        y[j] = y[j] + w2 * z[i] * v4
        hs0[j] = hs0[j] + w2 * (v4 * v4)
    return y, hs0, hs1, hs2, hs3


def sinerp(abd, ld4, nk, p1ip, flag=0):
    def A(i, j):
        return (i - 1) + (j - 1) * ld4 + 1
    c1 = c2 = c3 = 0.0
    wjm3 = [0.0, 0.0, 0.0, 0.0]
    wjm2 = [0.0, 0.0, 0.0]
    wjm1 = [0.0, 0.0]
    for i in range(1, nk + 1):
        j = nk - i + 1
        c0 = 1.0 / abd[A(4, j)]
        if j <= nk - 3:
            c1 = abd[A(1, j + 3)] * c0
            c2 = abd[A(2, j + 2)] * c0
            c3 = abd[A(3, j + 1)] * c0
        elif j == nk - 2:
            c1 = 0.0
            c2 = abd[A(2, j + 2)] * c0
            c3 = abd[A(3, j + 1)] * c0
        elif j == nk - 1:
            c1 = 0.0
            c2 = 0.0
            c3 = abd[A(3, j + 1)] * c0
        elif j == nk:
            c1 = 0.0
            c2 = 0.0
            c3 = 0.0
        p1ip[A(1, j)] = 0.0 - ((c1 * wjm3[1] + c2 * wjm3[2]) + c3 * wjm3[3])
        p1ip[A(2, j)] = 0.0 - ((c1 * wjm3[2] + c2 * wjm2[1]) + c3 * wjm2[2])
        p1ip[A(3, j)] = 0.0 - ((c1 * wjm3[3] + c2 * wjm2[2]) + c3 * wjm1[1])
        p1ip[A(4, j)] = ((((((c0 * c0 + (c1 * c1) * wjm3[1]) + ((2.0 * c1) * c2) * wjm3[2])
                            + ((2.0 * c1) * c3) * wjm3[3]) + (c2 * c2) * wjm2[1])
                          + ((2.0 * c2) * c3) * wjm2[2]) + (c3 * c3) * wjm1[1])
        wjm3[1] = wjm2[1]
        wjm3[2] = wjm2[2]
        wjm3[3] = p1ip[A(2, j)]
        wjm2[1] = wjm1[1]
        wjm2[2] = p1ip[A(3, j)]
        wjm1[1] = p1ip[A(4, j)]


def sslvrg(penalt, dofoff, x, y, w, ssw, n, knot, nk, coef, sz, lev, icrit, lam,
           xwy, hs0, hs1, hs2, hs3, sg0, sg1, sg2, sg3, abd, p1ip, ld4):
    """Liefert (crit, info)."""
    def A(i, j):
        return (i - 1) + (j - 1) * ld4 + 1
    eps = 1e-11
    crit = 0.0
    for i in range(1, nk + 1):
        coef[i] = xwy[i]
        abd[A(4, i)] = hs0[i] + lam * sg0[i]
    for i in range(1, nk):
        abd[A(3, i + 1)] = hs1[i] + lam * sg1[i]
    for i in range(1, nk - 1):
        abd[A(2, i + 2)] = hs2[i] + lam * sg2[i]
    for i in range(1, nk - 2):
        abd[A(1, i + 3)] = hs3[i] + lam * sg3[i]
    info = _dpbfa(abd, ld4, nk, 3)
    if info != 0:
        return crit, info
    _dpbsl(abd, ld4, nk, 3, coef)
    for i in range(1, n + 1):
        sz[i] = bvalue(knot, coef, nk, 4, x[i], 0)
    if icrit >= 1:
        sinerp(abd, ld4, nk, p1ip, 0)
        for i in range(1, n + 1):
            xv = x[i]
            ileft, mflag = interv(knot, nk + 1, xv)
            if mflag == -1:
                ileft = 4
                xv = knot[4] + eps
            elif mflag == 1:
                ileft = nk
                xv = knot[nk + 1] - eps
            j = ileft - 3
            db, D = bsplvd(knot, 4, xv, ileft, 1)
            b0, b1, b2, b3 = db[1], db[2], db[3], db[4]
            P = p1ip
            s = P[A(4, j)] * (b0 * b0)
            s = s + 2.0 * P[A(3, j)] * b0 * b1
            s = s + 2.0 * P[A(2, j)] * b0 * b2
            s = s + 2.0 * P[A(1, j)] * b0 * b3
            s = s + P[A(4, j + 1)] * (b1 * b1)
            s = s + 2.0 * P[A(3, j + 1)] * b1 * b2
            s = s + 2.0 * P[A(2, j + 1)] * b1 * b3
            s = s + P[A(4, j + 2)] * (b2 * b2)
            s = s + 2.0 * P[A(3, j + 2)] * b2 * b3
            s = s + P[A(4, j + 3)] * (b3 * b3)
            lev[i] = s * (w[i] * w[i])
        df = 0.0
        if icrit == 1:
            rss = ssw
            sumw = 0.0
            for i in range(1, n + 1):
                q = (y[i] - sz[i]) * w[i]
                rss = rss + q * q
                df = df + lev[i]
                sumw = sumw + w[i] * w[i]
            t = 1.0 - (dofoff + penalt * df) / sumw
            crit = (rss / sumw) / (t * t)
        elif icrit == 2:
            crit = 0.0
            for i in range(1, n + 1):
                q = ((y[i] - sz[i]) * w[i]) / (1 - lev[i])
                crit = crit + q * q
            crit = crit / n
        else:
            for i in range(1, n + 1):
                df = df + lev[i]
            if icrit == 3:
                d = dofoff - df
                crit = 3 + d * d
            else:
                crit = df - dofoff
    return crit, 0


def _fsign(x, y):
    if x != x or y != y:
        return x + y
    return abs(x) if y >= 0 else -abs(x)


def sbart(penalt, dofoff, xs, ys, ws, ssw, n, knot, nk, icrit, spar, ispar, iter_,
          lspar, uspar, tol, eps, isetup):
    """``sbart`` (Eingabefelder 1-basiert). Liefert dict mit coef, sz, lev,
    crit, spar, lspar (= lambda), ratio, iter, ier."""
    from ._lbfgsb import _p  # Ausgabehilfe
    from .._rnum import r_pow
    ld4 = 4
    coef = [0.0] * (nk + 1)
    sz = [0.0] * (n + 1)
    lev = [0.0] * (n + 1)
    abd = [0.0] * (ld4 * nk + 1)
    p1ip = [0.0] * (ld4 * nk + 1)
    ws = list(ws)
    tracing = ispar < 0
    spar_is_lambda = False
    ratio = 1.0
    for i in range(1, n + 1):
        if ws[i] > 0.0:
            ws[i] = math.sqrt(ws[i])
    sg = None
    st = None
    if isetup < 0:
        spar_is_lambda = True
    elif isetup != 1:
        sg = sgram(knot, nk)
        st = stxwx(xs, ys, ws, n, knot, nk)
        spar_is_lambda = isetup == 2
        if not spar_is_lambda:
            t1 = 0.0
            t2 = 0.0
            for i in range(3, nk - 3 + 1):
                t1 += st[1][i]
                t2 += sg[0][i]
            ratio = t1 / t2
    sg0, sg1, sg2, sg3 = sg
    xwy, hs0, hs1, hs2, hs3 = st
    state = {"ier": 0, "crit": 0.0, "lspar": lspar}

    def comp(sp):
        lam = sp if spar_is_lambda else ratio * r_pow(16.0, sp * 6.0 - 2.0)
        state["lspar"] = lam
        crit, info = sslvrg(penalt, dofoff, xs, ys, ws, ssw, n, knot, nk, coef, sz, lev, icrit, lam,
                            xwy, hs0, hs1, hs2, hs3, sg0, sg1, sg2, sg3, abd, p1ip, ld4)
        if info != 0:
            state["ier"] = info
        else:
            state["crit"] = crit
        return crit
    if ispar == 1:
        comp(spar)
        return {"coef": coef, "sz": sz, "lev": lev, "crit": state["crit"], "spar": spar,
                "lspar": state["lspar"], "ratio": ratio, "iter": iter_, "ier": state["ier"], "ws": ws}

    def CRIT(fx):
        return fx - 3.0 if icrit == 3 else fx
    ax = lspar
    bx = uspar
    maxit = iter_
    it = 0
    a = ax
    b = bx
    v = a + _C_GOLD * (b - a)
    w = v
    x = v
    e = 0.0
    d = 0.0
    comp(x)
    fx = state["crit"]
    fv = fx
    fw = fx
    while state["ier"] == 0:
        xm = (a + b) * 0.5
        tol1 = eps * abs(x) + tol / 3.0
        tol2 = tol1 * 2.0
        it += 1
        Fparabol = False
        if tracing:
            if it == 1:
                cr = {1: "GCV", 2: "CV", 3: "(df0-df)^2"}.get(icrit, "?f?")
                _p("sbart (ratio = %15.8g) iterations; initial tol1 = %12.6e :\n%11s %14s  %9s %11s  Kind %11s %12s\n%s\n",
                   ratio, tol1, "spar", cr, "b - a", "e", "NEW lspar", "crit",
                   " -------------------------------------------------------------------------------")
            _p("%11.8f %14.9g %9.4e %11.5g", x, CRIT(fx), b - a, e)
        if abs(x - xm) <= tol2 - (b - a) * 0.5 or it > maxit:
            break
        golden = False
        if abs(e) <= tol1 or fx >= _BIG_f or fv >= _BIG_f or fw >= _BIG_f:
            golden = True
        else:
            if tracing:
                _p(" FP")
                Fparabol = True
            r = (x - w) * (fx - fv)
            q = (x - v) * (fx - fw)
            p = (x - v) * q - (x - w) * r
            q = (q - r) * 2.0
            if q > 0.0:
                p = -p
            q = abs(q)
            r = e
            e = d
            if abs(p) >= abs(0.5 * q * r) or q == 0.0:
                golden = True
            elif p <= q * (a - x) or p >= q * (b - x):
                golden = True
            else:
                if tracing:
                    _p(" PI ")
                d = p / q
                u = x + d
                if u - a < tol2 or b - u < tol2:
                    d = _fsign(tol1, xm - x)
        if golden:
            if tracing:
                _p(" GS%s ", "" if Fparabol else " --")
            if x >= xm:
                e = a - x
            else:
                e = b - x
            d = _C_GOLD * e
        u = x + (d if abs(d) >= tol1 else _fsign(tol1, d))
        comp(u)
        fu = state["crit"]
        if tracing:
            _p("%11g %12g\n", state["lspar"], CRIT(fu))
        if not math.isfinite(fu):
            import sys
            sys.stderr.write("spar-finding: non-finite value %g; using BIG value\n" % fu)
            fu = 2.0 * _BIG_f
        if fu <= fx:
            if u >= x:
                a = x
            else:
                b = x
            v = w
            fv = fw
            w = x
            fw = fx
            x = u
            fx = fu
        else:
            if u < x:
                a = u
            else:
                b = u
            if fu <= fw or w == x:
                v = w
                fv = fw
                w = u
                fw = fu
            elif fu <= fv or v == x or v == w:
                v = u
                fv = fu
    if tracing:
        _p("  >>> %12g %12g\n", state["lspar"], CRIT(fx))
    return {"coef": coef, "sz": sz, "lev": lev, "crit": fx, "spar": x, "lspar": state["lspar"],
            "ratio": ratio, "iter": it, "ier": state["ier"], "ws": ws}
