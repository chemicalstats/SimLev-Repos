"""Eindimensionale Verfahren aus R's ``src/library/stats/src/optimize.c`` / ``zeroin.c``
(``Brent_fmin``, ``R_zeroin2``) für ``optimize``/``uniroot``, bitgleich in Python (skalare
double-Arithmetik). Die mehrdimensionalen Optimierer aus ``src/appl/optim.c`` (``nmmin``,
``vmmin``, ``cgmin``) sind mit Etappe 9.6c entfallen (eigene Optimierer in slc).

Die Zielfunktionen erhalten/liefern ``float``.
"""
from __future__ import annotations

import math

__all__ = ["brent_fmin", "zeroin2"]

_DBL_EPSILON = 2.220446049250313e-16


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
