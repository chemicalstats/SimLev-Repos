"""Optimierer aus R's ``src/appl/optim.c`` (``nmmin``, ``vmmin``, ``cgmin``)
und ``src/library/stats/src/optimize.c`` / ``zeroin.c`` (``Brent_fmin``,
``R_zeroin2``), bitgleich in Python (skalare double-Arithmetik).

Die Zielfunktionen erhalten/liefern Python-Listen bzw. ``float``.
"""
from __future__ import annotations

import math

__all__ = ["nmmin", "vmmin", "cgmin", "brent_fmin", "zeroin2"]

_DBL_EPSILON = 2.220446049250313e-16
_BIG = 1.0e35
_STEPREDN = 0.2
_ACCTOL = 0.0001
_RELTEST = 10.0


def _isfinite(v):
    return v == v and v not in (math.inf, -math.inf)


def _p(fmt, *a):
    print(fmt % a, end="")


def nmmin(n, Bvec, fminfn, abstol, intol, alpha, bet, gamm, trace, maxit):
    """Nelder-Mead; liefert (X, Fmin, fail, fncount)."""
    from .linalg import RError
    Bvec = list(Bvec)
    if maxit <= 0:
        return list(Bvec), fminfn(Bvec), 0, 0
    if trace:
        _p("  Nelder-Mead direct search function minimizer\n")
    n1 = n + 1
    C = n + 2
    P = [[0.0] * (n + 2) for _ in range(n + 1)]
    fail = 0
    f = fminfn(Bvec)
    if not _isfinite(f):
        raise RError("function cannot be evaluated at initial parameters")
    if trace:
        _p("function value for initial parameters = %f\n", f)
    funcount = 1
    convtol = intol * (abs(f) + intol)
    if trace:
        _p("  Scaled convergence tolerance is %g\n", convtol)
    P[n1 - 1][0] = f
    for i in range(n):
        P[i][0] = Bvec[i]
    L = 1
    size = 0.0
    step = 0.0
    for i in range(n):
        if 0.1 * abs(Bvec[i]) > step:
            step = 0.1 * abs(Bvec[i])
    if step == 0.0:
        step = 0.1
    if trace:
        _p("Stepsize computed as %f\n", step)
    action = "BUILD          "
    for j in range(2, n1 + 1):
        action = "BUILD          "
        for i in range(n):
            P[i][j - 1] = Bvec[i]
        trystep = step
        while P[j - 2][j - 1] == Bvec[j - 2]:
            P[j - 2][j - 1] = Bvec[j - 2] + trystep
            trystep *= 10
        size += trystep
    oldsize = size
    calcvert = True
    while True:
        if calcvert:
            for j in range(n1):
                if j + 1 != L:
                    for i in range(n):
                        Bvec[i] = P[i][j]
                    f = fminfn(Bvec)
                    if not _isfinite(f):
                        f = _BIG
                    funcount += 1
                    P[n1 - 1][j] = f
            calcvert = False
        VL = P[n1 - 1][L - 1]
        VH = VL
        H = L
        for j in range(1, n1 + 1):
            if j != L:
                f = P[n1 - 1][j - 1]
                if f < VL:
                    L = j
                    VL = f
                if f > VH:
                    H = j
                    VH = f
        if VH <= VL + convtol or VL <= abstol:
            break
        if trace:
            _p("%s%s %f %f\n", action, ("%5d" % funcount)[:11], VH, VL)
        for i in range(n):
            temp = -P[i][H - 1]
            for j in range(n1):
                temp += P[i][j]
            P[i][C - 1] = temp / n
        for i in range(n):
            Bvec[i] = (1.0 + alpha) * P[i][C - 1] - alpha * P[i][H - 1]
        f = fminfn(Bvec)
        if not _isfinite(f):
            f = _BIG
        funcount += 1
        action = "REFLECTION     "
        VR = f
        if VR < VL:
            P[n1 - 1][C - 1] = f
            for i in range(n):
                f = gamm * Bvec[i] + (1 - gamm) * P[i][C - 1]
                P[i][C - 1] = Bvec[i]
                Bvec[i] = f
            f = fminfn(Bvec)
            if not _isfinite(f):
                f = _BIG
            funcount += 1
            if f < VR:
                for i in range(n):
                    P[i][H - 1] = Bvec[i]
                P[n1 - 1][H - 1] = f
                action = "EXTENSION      "
            else:
                for i in range(n):
                    P[i][H - 1] = P[i][C - 1]
                P[n1 - 1][H - 1] = VR
        else:
            action = "HI-REDUCTION   "
            if VR < VH:
                for i in range(n):
                    P[i][H - 1] = Bvec[i]
                P[n1 - 1][H - 1] = VR
                action = "LO-REDUCTION   "
            for i in range(n):
                Bvec[i] = (1 - bet) * P[i][H - 1] + bet * P[i][C - 1]
            f = fminfn(Bvec)
            if not _isfinite(f):
                f = _BIG
            funcount += 1
            if f < P[n1 - 1][H - 1]:
                for i in range(n):
                    P[i][H - 1] = Bvec[i]
                P[n1 - 1][H - 1] = f
            else:
                if VR >= VH:
                    action = "SHRINK         "
                    calcvert = True
                    size = 0.0
                    for j in range(n1):
                        if j + 1 != L:
                            for i in range(n):
                                P[i][j] = bet * (P[i][j] - P[i][L - 1]) + P[i][L - 1]
                                size += abs(P[i][j] - P[i][L - 1])
                    if size < oldsize:
                        oldsize = size
                    else:
                        if trace:
                            _p("Polytope size measure not decreased in shrink\n")
                        fail = 10
                        break
        if not (funcount <= maxit):
            break
    if trace:
        _p("Exiting from Nelder Mead minimizer\n")
        _p("    %d function evaluations used\n", funcount)
    Fmin = P[n1 - 1][L - 1]
    X = [P[i][L - 1] for i in range(n)]
    if funcount > maxit:
        fail = 1
    return X, Fmin, fail, funcount


def vmmin(n0, b, fminfn, fmingr, maxit, trace, mask, abstol, reltol, nREPORT):
    """BFGS (variable metric); liefert (b, Fmin, fncount, grcount, fail)."""
    from .linalg import RError
    b = list(b)
    if maxit <= 0:
        return b, fminfn(b), 0, 0, 0
    if nREPORT <= 0:
        raise RError('REPORT must be > 0 (method = "BFGS")')
    l = [i for i in range(n0) if mask[i]]
    n = len(l)
    t = [0.0] * n
    X = [0.0] * n
    c = [0.0] * n
    B = [[0.0] * (i + 1) for i in range(n)]
    f = fminfn(b)
    if not _isfinite(f):
        raise RError("initial value in 'vmmin' is not finite")
    if trace:
        _p("initial  value %f \n", f)
    Fmin = f
    funcount = gradcount = 1
    g = list(fmingr(b))
    it = 1
    ilast = gradcount
    count = 0
    while True:
        if ilast == gradcount:
            for i in range(n):
                for j in range(i):
                    B[i][j] = 0.0
                B[i][i] = 1.0
        for i in range(n):
            X[i] = b[l[i]]
            c[i] = g[l[i]]
        gradproj = 0.0
        for i in range(n):
            s = 0.0
            for j in range(i + 1):
                s -= B[i][j] * g[l[j]]
            for j in range(i + 1, n):
                s -= B[j][i] * g[l[j]]
            t[i] = s
            gradproj += s * g[l[i]]
        if gradproj < 0.0:
            steplength = 1.0
            accpoint = False
            while True:
                count = 0
                for i in range(n):
                    b[l[i]] = X[i] + steplength * t[i]
                    if _RELTEST + X[i] == _RELTEST + b[l[i]]:
                        count += 1
                if count < n:
                    f = fminfn(b)
                    funcount += 1
                    accpoint = _isfinite(f) and (f <= Fmin + gradproj * steplength * _ACCTOL)
                    if not accpoint:
                        steplength *= _STEPREDN
                if count == n or accpoint:
                    break
            enough = (f > abstol) and abs(f - Fmin) > reltol * (abs(Fmin) + reltol)
            if not enough:
                count = n
                Fmin = f
            if count < n:
                Fmin = f
                g = list(fmingr(b))
                gradcount += 1
                it += 1
                D1 = 0.0
                for i in range(n):
                    t[i] = steplength * t[i]
                    c[i] = g[l[i]] - c[i]
                    D1 += t[i] * c[i]
                if D1 > 0:
                    D2 = 0.0
                    for i in range(n):
                        s = 0.0
                        for j in range(i + 1):
                            s += B[i][j] * c[j]
                        for j in range(i + 1, n):
                            s += B[j][i] * c[j]
                        X[i] = s
                        D2 += s * c[i]
                    D2 = 1.0 + D2 / D1
                    for i in range(n):
                        for j in range(i + 1):
                            B[i][j] += (D2 * t[i] * t[j] - X[i] * t[j] - t[i] * X[j]) / D1
                else:
                    ilast = gradcount
            else:
                if ilast < gradcount:
                    count = 0
                    ilast = gradcount
        else:
            count = 0
            if ilast == gradcount:
                count = n
            else:
                ilast = gradcount
        if trace and (it % nREPORT == 0):
            _p("iter%4d value %f\n", it, f)
        if it >= maxit:
            break
        if gradcount - ilast > 2 * n:
            ilast = gradcount
        if not (count != n or ilast != gradcount):
            break
    if trace:
        _p("final  value %f \n", Fmin)
        if it < maxit:
            _p("converged\n")
        else:
            _p("stopped after %i iterations\n", it)
    fail = 0 if it < maxit else 1
    return b, Fmin, funcount, gradcount, fail


def cgmin(n, Bvec, fminfn, fmingr, abstol, intol, type, trace, maxit):
    """Konjugierte Gradienten; liefert (X, Fmin, fail, fncount, grcount)."""
    from .linalg import RError
    Bvec = list(Bvec)
    if maxit <= 0:
        return list(Bvec), fminfn(Bvec), 0, 0, 0
    if trace:
        _p("  Conjugate gradients function minimizer\n")
        if type == 1:
            _p("Method: Fletcher Reeves\n")
        elif type == 2:
            _p("Method: Polak Ribiere\n")
        elif type == 3:
            _p("Method: Beale Sorenson\n")
        else:
            raise RError("unknown 'type' in \"CG\" method of 'optim'")
    c = [0.0] * n
    g = [0.0] * n
    t = [0.0] * n
    X = [0.0] * n
    setstep = 1.7
    fail = 0
    cyclimit = n
    tol = intol * n * math.sqrt(intol)
    if trace:
        _p("tolerance used in gradient test=%g\n", tol)
    f = fminfn(Bvec)
    if not _isfinite(f):
        raise RError("Function cannot be evaluated at initial parameters")
    Fmin = f
    funcount = 1
    gradcount = 0
    steplength = 1.0
    while True:
        for i in range(n):
            t[i] = 0.0
            c[i] = 0.0
        cycle = 0
        oldstep = 1.0
        count = 0
        while True:
            cycle += 1
            if trace:
                _p("%d %d %f\n", gradcount, funcount, Fmin)
                _p("parameters ")
                for i in range(1, n + 1):
                    _p("%10.5f ", Bvec[i - 1])
                    if i // 7 * 7 == i and i < n:
                        _p("\n")
                _p("\n")
            gradcount += 1
            if gradcount > maxit:
                return X, Fmin, 1, funcount, gradcount
            g = list(fmingr(Bvec))
            G1 = 0.0
            G2 = 0.0
            for i in range(n):
                X[i] = Bvec[i]
                if type == 1:
                    G1 += g[i] * g[i]
                    G2 += c[i] * c[i]
                elif type == 2:
                    G1 += g[i] * (g[i] - c[i])
                    G2 += c[i] * c[i]
                elif type == 3:
                    G1 += g[i] * (g[i] - c[i])
                    G2 += t[i] * (g[i] - c[i])
                else:
                    raise RError("unknown type in \"CG\" method of 'optim'")
                c[i] = g[i]
            if G1 > tol:
                if G2 > 0.0:
                    G3 = G1 / G2
                else:
                    G3 = 1.0
                gradproj = 0.0
                for i in range(n):
                    t[i] = t[i] * G3 - g[i]
                    gradproj += t[i] * g[i]
                steplength = oldstep
                accpoint = False
                while True:
                    count = 0
                    for i in range(n):
                        Bvec[i] = X[i] + steplength * t[i]
                        if _RELTEST + X[i] == _RELTEST + Bvec[i]:
                            count += 1
                    if count < n:
                        f = fminfn(Bvec)
                        funcount += 1
                        accpoint = _isfinite(f) and f <= Fmin + gradproj * steplength * _ACCTOL
                        if not accpoint:
                            steplength *= _STEPREDN
                            if trace:
                                _p("*")
                        else:
                            Fmin = f
                    if count == n or accpoint:
                        break
                if count < n:
                    newstep = 2 * (f - Fmin - gradproj * steplength)
                    if newstep > 0:
                        newstep = -(gradproj * steplength * steplength / newstep)
                        for i in range(n):
                            Bvec[i] = X[i] + newstep * t[i]
                        Fmin = f
                        f = fminfn(Bvec)
                        funcount += 1
                        if f < Fmin:
                            Fmin = f
                            if trace:
                                _p(" i< ")
                        else:
                            if trace:
                                _p(" i> ")
                            for i in range(n):
                                Bvec[i] = X[i] + steplength * t[i]
            oldstep = setstep * steplength
            if oldstep > 1.0:
                oldstep = 1.0
            if not ((count != n) and (G1 > tol) and (cycle != cyclimit)):
                break
        if not ((cycle != 1) or ((count != n) and (G1 > tol) and Fmin > abstol)):
            break
    if trace:
        _p("Exiting from conjugate gradients minimizer\n")
        _p("    %d function evaluations used\n", funcount)
        _p("    %d gradient evaluations used\n", gradcount)
    return X, Fmin, fail, funcount, gradcount


def brent_fmin(ax, bx, f, tol):
    """``Brent_fmin`` aus optimize.c."""
    c = (3.0 - math.sqrt(5.0)) * 0.5
    eps = _DBL_EPSILON
    tol1 = eps + 1.0
    eps = math.sqrt(eps)
    a = ax
    b = bx
    v = a + c * (b - a)
    w = v
    x = v
    d = 0.0
    e = 0.0
    fx = f(x)
    fv = fx
    fw = fx
    tol3 = tol / 3.0
    while True:
        xm = (a + b) * 0.5
        tol1 = eps * abs(x) + tol3
        t2 = tol1 * 2.0
        if abs(x - xm) <= t2 - (b - a) * 0.5:
            break
        p = 0.0
        q = 0.0
        r = 0.0
        if abs(e) > tol1:
            r = (x - w) * (fx - fv)
            q = (x - v) * (fx - fw)
            p = (x - v) * q - (x - w) * r
            q = (q - r) * 2.0
            if q > 0.0:
                p = -p
            else:
                q = -q
            r = e
            e = d
        if abs(p) >= abs(q * 0.5 * r) or p <= q * (a - x) or p >= q * (b - x):
            if x < xm:
                e = b - x
            else:
                e = a - x
            d = c * e
        else:
            d = p / q
            u = x + d
            if u - a < t2 or b - u < t2:
                d = tol1
                if x >= xm:
                    d = -d
        if abs(d) >= tol1:
            u = x + d
        elif d > 0.0:
            u = x + tol1
        else:
            u = x - tol1
        fu = f(u)
        if fu <= fx:
            if u < x:
                b = x
            else:
                a = x
            v = w
            w = x
            x = u
            fv = fw
            fw = fx
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
    return x


def zeroin2(ax, bx, fa, fb, f, tol, maxit_in):
    """``R_zeroin2``; liefert (root, iter, estim_prec)."""
    EPSILON = _DBL_EPSILON
    a = ax
    b = bx
    c = a
    fc = fa
    maxit = maxit_in + 1
    Maxit = maxit_in
    if fa == 0.0:
        return a, 0, 0.0
    if fb == 0.0:
        return b, 0, 0.0
    while maxit:
        maxit -= 1
        prev_step = b - a
        if abs(fc) < abs(fb):
            a = b
            b = c
            c = a
            fa = fb
            fb = fc
            fc = fa
        tol_act = 2 * EPSILON * abs(b) + tol / 2
        new_step = (c - b) / 2
        if abs(new_step) <= tol_act or fb == 0.0:
            Maxit -= maxit
            return b, Maxit, abs(c - b)
        if abs(prev_step) >= tol_act and abs(fa) > abs(fb):
            cb = c - b
            if a == c:
                t1 = fb / fa
                p = cb * t1
                q = 1.0 - t1
            else:
                q = fa / fc
                t1 = fb / fc
                t2 = fb / fa
                p = t2 * (cb * q * (q - t1) - (b - a) * (t1 - 1.0))
                q = (q - 1.0) * (t1 - 1.0) * (t2 - 1.0)
            if p > 0.0:
                q = -q
            else:
                p = -p
            if p < (0.75 * cb * q - abs(tol_act * q) / 2) and p < abs(prev_step * q / 2):
                new_step = p / q
        if abs(new_step) < tol_act:
            if new_step > 0.0:
                new_step = tol_act
            else:
                new_step = -tol_act
        a = b
        fa = fb
        b += new_step
        fb = f(b)
        if (fb > 0 and fc > 0) or (fb < 0 and fc < 0):
            c = a
            fc = fa
    return b, -1, abs(c - b)
