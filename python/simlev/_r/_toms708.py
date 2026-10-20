"""Port von R's ``src/nmath/toms708.c`` (R 4.3.3): unvollständige Betafunktion.

ACM TOMS 708 (Didonato & Morris 1992) mit den Änderungen des R Core Teams
(``log_p``-Zweige, Warnungen). Zeile für Zeile aus dem C-Code übernommen;
``bratio`` liefert ``(w, w1, ierr)`` statt Zeigerargumenten.
"""
from __future__ import annotations

import math

from ._cmath import (
    DBL_EPSILON, DBL_MIN, INF, NAN, NINF, INT_MAX, M_LN_SQRT_2PI, M_LN2, M_SQRT_PI,
    c_int, cos, dv, exp, expm1, log, log1p, logspace_add, ml_warning, pow, sin, sqrt,
)

__all__ = ["bratio"]

_isnan = math.isnan
_isfinite = math.isfinite


def _min(a, b):
    return a if a < b else b


def _max(a, b):
    return a if a > b else b


def _R_Log1_Exp(x):
    # in toms708.c mit rexpm1() umdefiniert
    return log(-rexpm1(x)) if x > -M_LN2 else log1p(-exp(x))


def bratio(a, b, x, y, log_p):
    """Unvollständiges Beta-Verhältnis: ``(w, w1, ierr)`` mit
    ``w = I_x(a, b)`` und ``w1 = 1 - I_x(a, b)`` (ggf. logarithmiert)."""
    eps = 2.0 * (0.5 * DBL_EPSILON)
    R_D__0 = NINF if log_p else 0.0
    R_D__1 = 0.0 if log_p else 1.0
    w = R_D__0
    w1 = R_D__0

    if _isnan(x) or _isnan(y) or _isnan(a) or _isnan(b):
        return w, w1, 9
    if a < 0.0 or b < 0.0:
        return w, w1, 1
    if a == 0.0 and b == 0.0:
        return w, w1, 2
    if x < 0.0 or x > 1.0:
        return w, w1, 3
    if y < 0.0 or y > 1.0:
        return w, w1, 4

    z = x + y - 0.5 - 0.5
    if abs(z) > eps * 3.0:
        return w, w1, 5

    ierr = 0
    if x == 0.0:
        if a == 0.0:
            return w, w1, 6
        return R_D__0, R_D__1, 0
    if y == 0.0:
        if b == 0.0:
            return w, w1, 7
        return R_D__1, R_D__0, 0
    if a == 0.0:
        return R_D__1, R_D__0, 0
    if b == 0.0:
        return R_D__0, R_D__1, 0

    eps = eps if eps > 1e-15 else 1e-15
    a_lt_b = a < b
    if (b if a_lt_b else a) < eps * 0.001:
        if log_p:
            if a_lt_b:
                w = log1p(-a / (a + b))
                w1 = log(a / (a + b))
            else:
                w = log(b / (a + b))
                w1 = log1p(-b / (a + b))
        else:
            w = b / (a + b)
            w1 = a / (a + b)
        return w, w1, ierr

    # Sprungziele: 'end', 'end_w', 'end_w1', 'end_w1_log', 'w_bpser', 'w1_bpser', 'bfrac'
    target = None
    lam = 0.0
    if (a if a < b else b) <= 1.0:  # ------------------------ a <= 1  or  b <= 1 ----
        do_swap = x > 0.5
        if do_swap:
            a0 = b; x0 = y; b0 = a; y0 = x
        else:
            a0 = a; x0 = x; b0 = b; y0 = y

        if b0 < (eps if eps < eps * a0 else eps * a0):  # L80
            w = fpser(a0, b0, x0, eps, log_p)
            w1 = _R_Log1_Exp(w) if log_p else 0.5 - w + 0.5
            target = "end"
        elif a0 < (eps if eps < eps * b0 else eps * b0) and b0 * x0 <= 1.0:  # L90
            w1 = apser(a0, b0, x0, eps)
            target = "end_w1"
        else:
            did_bup = False
            n = 0
            go131 = False
            if (a0 if a0 > b0 else b0) > 1.0:  # L20
                if b0 <= 1.0:
                    target = "w_bpser"
                elif x0 >= 0.29:
                    target = "w1_bpser"
                elif x0 < 0.1 and pow(x0 * b0, a0) <= 0.7:
                    target = "w_bpser"
                elif b0 > 15.0:
                    w1 = 0.0
                    go131 = True
            else:  # a, b <= 1
                if a0 >= (0.2 if 0.2 < b0 else b0):
                    target = "w_bpser"
                elif pow(x0, a0) <= 0.9:
                    target = "w_bpser"
                elif x0 >= 0.3:
                    target = "w1_bpser"
            if target is None:
                if not go131:
                    n = 20
                    w1 = bup(b0, a0, y0, x0, n, eps, False)
                    did_bup = True
                    b0 += n
                # L131:
                w1, ierr1 = bgrat(b0, a0, y0, x0, w1, 15 * eps, False)
                if w1 == 0 or (0 < w1 < DBL_MIN):
                    if did_bup:
                        w1 = bup(b0 - n, a0, y0, x0, n, eps, True)
                    else:
                        w1 = NINF
                    w1, ierr1 = bgrat(b0, a0, y0, x0, w1, 15 * eps, True)
                    if ierr1:
                        ierr = 10 + ierr1
                    target = "end_w1_log"
                else:
                    if ierr1:
                        ierr = 10 + ierr1
                    if w1 < 0:
                        ml_warning("bratio(a=%g, b=%g, x=%g): bgrat() -> w1 = %g" % (a, b, x, w1))
                    target = "end_w1"
    else:  # L30: -------------------- both  a, b > 1 ---
        if _isfinite(a + b):
            lam = ((a + b) * y - b) if (a > b) else (a - (a + b) * x)
        else:
            lam = a * y - b * x
        do_swap = lam < 0.0
        if do_swap:
            lam = -lam
            a0 = b; x0 = y; b0 = a; y0 = x
        else:
            a0 = a; x0 = x; b0 = b; y0 = y

        if b0 < 40.0:
            if b0 * x0 <= 0.7 or (log_p and lam > 650.0):
                target = "w_bpser"
            else:
                target = "L140"
        elif a0 > b0:
            if b0 <= 100.0 or lam > b0 * 0.03:
                target = "bfrac"
        elif a0 <= 100.0:
            target = "bfrac"
        elif lam > a0 * 0.03:
            target = "bfrac"

        if target is None:  # L180
            w = basym(a0, b0, lam, eps * 100.0, log_p)
            w1 = _R_Log1_Exp(w) if log_p else 0.5 - w + 0.5
            target = "end"

    if target == "L140":
        n = c_int(b0)
        b0 -= n
        if b0 == 0.0:
            n -= 1
            b0 = 1.0
        w = bup(b0, a0, y0, x0, n, eps, False)
        if w < DBL_MIN and log_p:
            b0 += n
            target = "w_bpser"
        elif x0 <= 0.7:
            w += bpser(a0, b0, x0, eps, False)
            target = "end_w"
        else:
            if a0 <= 15.0:
                n = 20
                w += bup(a0, b0, x0, y0, n, eps, False)
                a0 += n
            w, ierr1 = bgrat(a0, b0, x0, y0, w, 15 * eps, False)
            if ierr1:
                ierr = 10 + ierr1
            target = "end_w"

    if target == "w_bpser":
        w = bpser(a0, b0, x0, eps, log_p)
        w1 = _R_Log1_Exp(w) if log_p else 0.5 - w + 0.5
    elif target == "w1_bpser":
        w1 = bpser(b0, a0, y0, eps, log_p)
        w = _R_Log1_Exp(w1) if log_p else 0.5 - w1 + 0.5
    elif target == "bfrac":
        w = bfrac(a0, b0, x0, y0, lam, eps * 15.0, log_p)
        w1 = _R_Log1_Exp(w) if log_p else 0.5 - w + 0.5
    elif target == "end_w":
        if log_p:
            w1 = log1p(-w)
            w = log(w)
        else:
            w1 = 0.5 - w + 0.5
    elif target == "end_w1":
        if log_p:
            w = log1p(-w1)
            w1 = log(w1)
        else:
            w = 0.5 - w1 + 0.5
    elif target == "end_w1_log":
        if log_p:
            w = _R_Log1_Exp(w1)
        else:
            w = -expm1(w1)
            w1 = exp(w1)

    # L_end:
    if do_swap:
        w, w1 = w1, w
    return w, w1, ierr


def fpser(a, b, x, eps, log_p):
    # EVALUATION OF I (A,B) FOR B < MIN(EPS, EPS*A) AND X <= 0.5
    if log_p:
        ans = a * log(x)
    elif a > eps * 0.001:
        t = a * log(x)
        if t < exparg(1):
            return 0.0
        ans = exp(t)
    else:
        ans = 1.0

    if log_p:
        ans += log(b) - log(a)
    else:
        ans *= b / a

    tol = eps / a
    an = a + 1.0
    t = x
    s = t / an
    while True:
        an += 1.0
        t = x * t
        c = t / an
        s += c
        if not (abs(c) > tol):
            break

    if log_p:
        ans += log1p(a * s)
    else:
        ans *= a * s + 1.0
    return ans


def apser(a, b, x, eps):
    g = 0.577215664901533
    bx = b * x
    t = x - bx
    if b * eps <= 0.02:
        c = log(x) + psi(b) + g + t
    else:
        c = log(bx) + g + t

    tol = eps * 5.0 * abs(c)
    j = 1.0
    s = 0.0
    while True:
        j += 1.0
        t *= x - bx / j
        aj = t / j
        s += aj
        if not (abs(aj) > tol):
            break
    return -a * (c + s)


def bpser(a, b, x, eps, log_p):
    # Power SERies expansion for evaluating I_x(a,b) when b <= 1 or b*x <= 0.7
    if x == 0.0:
        return NINF if log_p else 0.0
    a0 = _min(a, b)
    if a0 >= 1.0:
        z = a * log(x) - betaln(a, b)
        ans = z - log(a) if log_p else exp(z) / a
    else:
        b0 = _max(a, b)
        if b0 < 8.0:
            if b0 <= 1.0:  # a0 < 1 and b0 <= 1
                if log_p:
                    ans = a * log(x)
                else:
                    ans = pow(x, a)
                    if ans == 0.0:
                        return ans
                apb = a + b
                if apb > 1.0:
                    u = a + b - 1.0
                    z = (gam1(u) + 1.0) / apb
                else:
                    z = gam1(apb) + 1.0
                c = (gam1(a) + 1.0) * (gam1(b) + 1.0) / z
                if log_p:
                    ans += log(c * (b / apb))
                else:
                    ans *= c * (b / apb)
            else:  # a0 < 1 < b0 < 8
                u = gamln1(a0)
                m = c_int(b0 - 1.0)
                if m >= 1:
                    c = 1.0
                    for _i in range(m):
                        b0 += -1.0
                        c *= b0 / (a0 + b0)
                    u += log(c)
                z = a * log(x) - u
                b0 += -1.0
                apb = a0 + b0
                if apb > 1.0:
                    u = a0 + b0 - 1.0
                    t = (gam1(u) + 1.0) / apb
                else:
                    t = gam1(apb) + 1.0
                if log_p:
                    ans = z + log(a0 / a) + log1p(gam1(b0)) - log(t)
                else:
                    ans = exp(z) * (a0 / a) * (gam1(b0) + 1.0) / t
        else:  # a0 < 1 < 8 <= b0
            u = gamln1(a0) + algdiv(a0, b0)
            z = a * log(x) - u
            if log_p:
                ans = z + log(a0 / a)
            else:
                ans = a0 / a * exp(z)

    if ans == (NINF if log_p else 0.0) or (not log_p and a <= eps * 0.1):
        return ans

    # COMPUTE THE SERIES
    tol = eps / a
    n = 0.0
    sum_ = 0.0
    c = 1.0
    while True:
        n += 1.0
        c *= (0.5 - b / n + 0.5) * x
        w = c / (a + n)
        sum_ += w
        if not (n < 1e7 and abs(w) > tol):
            break
    if abs(w) > tol:
        if (log_p and not (a * sum_ > -1.0 and abs(log1p(a * sum_)) < eps * abs(ans))) or \
                (not log_p and abs(a * sum_ + 1.0) != 1.0):
            ml_warning(" bpser(a=%g, b=%g, x=%g,...) did not converge (n=1e7, |w|/tol=%g > 1; A=%g)"
                       % (a, b, x, abs(w) / tol, ans))
    if log_p:
        if a * sum_ > -1.0:
            ans += log1p(a * sum_)
        else:
            if ans > NINF:
                ml_warning("pbeta(*, log.p=TRUE) -> bpser(a=%g, b=%g, x=%g,...) underflow to -Inf"
                           % (a, b, x))
            ans = NINF
    elif a * sum_ > -1.0:
        ans *= (a * sum_ + 1.0)
    else:
        ans = 0.0
    return ans


def bup(a, b, x, y, n, eps, give_log):
    # EVALUATION OF I_x(A,B) - I_x(A+N,B) WHERE N IS A POSITIVE INT.
    apb = a + b
    ap1 = a + 1.0
    if n > 1 and a >= 1.0 and apb >= ap1 * 1.1:
        mu = c_int(abs(exparg(1)))
        k = c_int(exparg(0))
        if mu > k:
            mu = k
        d = exp(-float(mu))
    else:
        mu = 0
        d = 1.0

    ret_val = (brcmp1(mu, a, b, x, y, True) - log(a)) if give_log else \
        brcmp1(mu, a, b, x, y, False) / a
    if n == 1 or (give_log and ret_val == NINF) or (not give_log and ret_val == 0.0):
        return ret_val

    nm1 = n - 1
    w = d

    k = 0
    if b > 1.0:
        if y > 1e-4:
            r = (b - 1.0) * x / y - a
            if r >= 1.0:
                k = c_int(r) if (r < nm1) else nm1
        else:
            k = nm1
        for i in range(k):
            l = float(i)
            d *= (apb + l) / (ap1 + l) * x
            w += d

    for i in range(k, nm1):
        l = float(i)
        d *= (apb + l) / (ap1 + l) * x
        w += d
        if d <= eps * w:
            break

    if give_log:
        ret_val += log(w)
    else:
        ret_val *= w
    return ret_val


def bfrac(a, b, x, y, lam, eps, log_p):
    # Continued fraction expansion for I_x(a,b) when a, b > 1.
    if not _isfinite(lam):
        return NAN
    brc = brcomp(a, b, x, y, log_p)
    if _isnan(brc):
        return NAN
    if not log_p and brc == 0.0:
        return 0.0

    c = lam + 1.0
    c0 = b / a
    c1 = 1.0 / a + 1.0
    yp1 = y + 1.0

    n = 0.0
    p = 1.0
    s = a + 1.0
    an = 0.0
    bn = 1.0
    anp1 = 1.0
    bnp1 = c / c1
    r = c1 / c
    r0 = r

    while True:
        n += 1.0
        t = n / a
        w = n * (b - n) * x
        e = a / s
        alpha = p * (p + c0) * e * e * (w * x)
        e = (t + 1.0) / (c1 + t + t)
        beta = n + w / s + e * (c + n * yp1)
        p = t + 1.0
        s += 2.0

        t = alpha * an + beta * anp1
        an = anp1
        anp1 = t
        t = alpha * bn + beta * bnp1
        bn = bnp1
        bnp1 = t

        r0 = r
        r = dv(anp1, bnp1)
        if abs(r - r0) <= eps * r:
            break

        an = dv(an, bnp1)
        bn = dv(bn, bnp1)
        anp1 = r
        bnp1 = 1.0
        if not (n < 10000):
            break
    if n >= 10000 and abs(r - r0) > eps * r:
        ml_warning(" bfrac(a=%g, b=%g, x=%g, y=%g, lambda=%g) did *not* converge (in 10000 steps)\n"
                   .rstrip("\n") % (a, b, x, y, lam))
    return (brc + log(r)) if log_p else brc * r


def brcomp(a, b, x, y, log_p):
    # Evaluation of x^a * y^b / Beta(a,b)
    const__ = 0.398942280401433
    if x == 0.0 or y == 0.0:
        return NINF if log_p else 0.0
    a0 = _min(a, b)
    if a0 < 8.0:
        if x <= 0.375:
            lnx = log(x)
            lny = alnrel(-x)
        else:
            if y > 0.375:
                lnx = log(x)
                lny = log(y)
            else:
                lnx = alnrel(-y)
                lny = log(y)

        z = a * lnx + b * lny
        if a0 >= 1.0:
            z -= betaln(a, b)
            return z if log_p else exp(z)

        b0 = _max(a, b)
        if b0 >= 8.0:  # L80
            u = gamln1(a0) + algdiv(a0, b0)
            return (log(a0) + (z - u)) if log_p else a0 * exp(z - u)

        if b0 <= 1.0:
            e_z = z if log_p else exp(z)
            if not log_p and e_z == 0.0:
                return 0.0
            apb = a + b
            if apb > 1.0:
                u = a + b - 1.0
                z = (gam1(u) + 1.0) / apb
            else:
                z = gam1(apb) + 1.0
            c = (gam1(a) + 1.0) * (gam1(b) + 1.0) / z
            return (e_z + log(a0 * c) - log1p(a0 / b0)) if log_p else \
                e_z * (a0 * c) / (a0 / b0 + 1.0)

        # ALGORITHM FOR 1 < b0 < 8
        u = gamln1(a0)
        n = c_int(b0 - 1.0)
        if n >= 1:
            c = 1.0
            for _i in range(n):
                b0 += -1.0
                c *= b0 / (a0 + b0)
            u = log(c) + u
        z -= u
        b0 += -1.0
        apb = a0 + b0
        if apb > 1.0:
            u = a0 + b0 - 1.0
            t = (gam1(u) + 1.0) / apb
        else:
            t = gam1(apb) + 1.0
        return (log(a0) + z + log1p(gam1(b0)) - log(t)) if log_p else \
            a0 * exp(z) * (gam1(b0) + 1.0) / t
    else:
        # PROCEDURE FOR A >= 8 AND B >= 8
        if a <= b:
            h = a / b
            x0 = h / (h + 1.0)
            y0 = 1.0 / (h + 1.0)
            lam = a - (a + b) * x
        else:
            h = b / a
            x0 = 1.0 / (h + 1.0)
            y0 = h / (h + 1.0)
            lam = (a + b) * y - b

        e = -lam / a
        if abs(e) > 0.6:
            u = e - log(x / x0)
        else:
            u = rlog1(e)

        e = lam / b
        if abs(e) <= 0.6:
            v = rlog1(e)
        else:
            v = e - log(y / y0)

        z = -(a * u + b * v) if log_p else exp(-(a * u + b * v))

        return (-M_LN_SQRT_2PI + 0.5 * log(b * x0) + z - bcorr(a, b)) if log_p else \
            const__ * sqrt(b * x0) * z * exp(-bcorr(a, b))


def brcmp1(mu, a, b, x, y, give_log):
    # Evaluation of exp(mu) * x^a * y^b / beta(a,b)
    const__ = 0.398942280401433
    a0 = _min(a, b)
    if a0 < 8.0:
        if x <= 0.375:
            lnx = log(x)
            lny = alnrel(-x)
        elif y > 0.375:
            lnx = log(x)
            lny = log(y)
        else:
            lnx = alnrel(-y)
            lny = log(y)

        z = a * lnx + b * lny
        if a0 >= 1.0:
            z -= betaln(a, b)
            return esum(mu, z, give_log)
        b0 = _max(a, b)
        if b0 >= 8.0:
            u = gamln1(a0) + algdiv(a0, b0)
            return (log(a0) + esum(mu, z - u, True)) if give_log else \
                a0 * esum(mu, z - u, False)
        elif b0 <= 1.0:
            ans = esum(mu, z, give_log)
            if ans == (NINF if give_log else 0.0):
                return ans
            apb = a + b
            if apb > 1.0:
                u = a + b - 1.0
                z = (gam1(u) + 1.0) / apb
            else:
                z = gam1(apb) + 1.0
            c = (log1p(gam1(a)) + log1p(gam1(b)) - log(z)) if give_log else \
                (gam1(a) + 1.0) * (gam1(b) + 1.0) / z
            return (ans + log(a0) + c - log1p(a0 / b0)) if give_log else \
                ans * (a0 * c) / (a0 / b0 + 1.0)
        # a0 < 1 < b0 < 8
        u = gamln1(a0)
        n = c_int(b0 - 1.0)
        if n >= 1:
            c = 1.0
            for _i in range(n):
                b0 += -1.0
                c *= b0 / (a0 + b0)
            u += log(c)
        z -= u
        b0 += -1.0
        apb = a0 + b0
        if apb > 1.0:
            t = (gam1(apb - 1.0) + 1.0) / apb
        else:
            t = gam1(apb) + 1.0
        return (log(a0) + esum(mu, z, True) + log1p(gam1(b0)) - log(t)) if give_log else \
            a0 * esum(mu, z, False) * (gam1(b0) + 1.0) / t
    else:
        # PROCEDURE FOR A >= 8 AND B >= 8
        if a > b:
            h = b / a
            x0 = 1.0 / (h + 1.0)
            y0 = h / (h + 1.0)
            lam = (a + b) * y - b
        else:
            h = a / b
            x0 = h / (h + 1.0)
            y0 = 1.0 / (h + 1.0)
            lam = a - (a + b) * x
        lx0 = -log1p(b / a)

        e = -lam / a
        if abs(e) > 0.6:
            u = e - log(x / x0)
        else:
            u = rlog1(e)

        e = lam / b
        if abs(e) > 0.6:
            v = e - log(y / y0)
        else:
            v = rlog1(e)

        z = esum(mu, -(a * u + b * v), give_log)
        return (log(const__) + (log(b) + lx0) / 2.0 + z - bcorr(a, b)) if give_log else \
            const__ * sqrt(b * x0) * z * exp(-bcorr(a, b))


def bgrat(a, b, x, y, w, eps, log_w):
    """Asymptotische Entwicklung für I_x(a,b), a groß gegenüber b.
    Liefert ``(w_neu, ierr)``; bei Fehler bleibt ``w`` unverändert."""
    n_terms_bgrat = 30
    c = [0.0] * n_terms_bgrat
    d = [0.0] * n_terms_bgrat
    bm1 = b - 0.5 - 0.5
    nu = a + bm1 * 0.5
    lnx = log(x) if (y > 0.375) else alnrel(-y)
    z = -nu * lnx

    if b * z == 0.0:
        ml_warning("bgrat(a=%g, b=%g, x=%g, y=%g): z=%g, b*z == 0 underflow, hence inaccurate pbeta()"
                   % (a, b, x, y, z))
        return w, 1

    log_r = log(b) + log1p(gam1(b)) + b * log(z) + nu * lnx
    log_u = log_r - (algdiv(b, a) + b * log(nu))
    u = exp(log_u)

    if log_u == NINF:
        return w, 2

    u_0 = (u == 0.0)
    if log_w:
        l = 0.0 if (w == NINF) else exp(w - log_u)
    else:
        l = 0.0 if (w == 0.0) else exp(log(w) - log_u)

    q_r = grat_r(b, z, log_r, eps)
    v = 0.25 / (nu * nu)
    t2 = lnx * 0.25 * lnx
    j = q_r
    sum_ = j
    t = 1.0
    cn = 1.0
    n2 = 0.0
    ierr = 0
    for n in range(1, n_terms_bgrat + 1):
        bp2n = b + n2
        j = (bp2n * (bp2n + 1.0) * j + (z + bp2n + 1.0) * t) * v
        n2 += 2.0
        t *= t2
        cn /= n2 * (n2 + 1.0)
        nm1 = n - 1
        c[nm1] = cn
        s = 0.0
        if n > 1:
            coef = b - n
            for i in range(1, nm1 + 1):
                s += coef * c[i - 1] * d[nm1 - i]
                coef += b
        d[nm1] = bm1 * cn + s / n
        dj = d[nm1] * j
        sum_ += dj
        if sum_ <= 0.0:
            return w, 3
        if abs(dj) <= eps * (sum_ + l):
            ierr = 0
            break
        elif n == n_terms_bgrat:
            ierr = 4
            ml_warning("bgrat(a=%g, b=%g, x=%g) *no* convergence: NOTIFY R-core!\n dj=%g, rel.err=%g\n"
                       .rstrip("\n") % (a, b, x, dj, abs(dj) / (sum_ + l)))

    if log_w:
        w = logspace_add(w, log_u + log(sum_))
    else:
        w += (exp(log_u + log(sum_)) if u_0 else u * sum_)
    return w, ierr


def grat_r(a, x, log_r, eps):
    # Scaled complement of incomplete gamma ratio function Q(a,x)/r
    if a * x == 0.0:
        if x <= a:
            return exp(-log_r)
        else:
            return 0.0
    elif a == 0.5:
        if x < 0.25:
            p = erf__(sqrt(x))
            return (0.5 - p + 0.5) * exp(-log_r)
        else:
            sx = sqrt(x)
            q_r = erfc1(1, sx) / sx * M_SQRT_PI
            return q_r
    elif x < 1.1:
        an = 3.0
        c = x
        sum_ = x / (a + 3.0)
        tol = eps * 0.1 / (a + 1.0)
        while True:
            an += 1.0
            c *= -(x / an)
            t = c / (a + an)
            sum_ += t
            if not (abs(t) > tol):
                break
        j = a * x * ((sum_ / 6.0 - 0.5 / (a + 2.0)) * x + 1.0 / (a + 1.0))
        z = a * log(x)
        h = gam1(a)
        g = h + 1.0

        if (x >= 0.25 and (a < x / 2.59)) or (z > -0.13394):
            l = rexpm1(z)
            q = ((l + 0.5 + 0.5) * j - l) * g - h
            if q <= 0.0:
                return 0.0
            else:
                return q * exp(-log_r)
        else:
            p = exp(z) * g * (0.5 - j + 0.5)
            return (0.5 - p + 0.5) * exp(-log_r)
    else:
        # Continued Fraction Expansion
        a2n_1 = 1.0
        a2n = 1.0
        b2n_1 = x
        b2n = x + (1.0 - a)
        c = 1.0
        while True:
            a2n_1 = x * a2n + c * a2n_1
            b2n_1 = x * b2n + c * b2n_1
            am0 = dv(a2n_1, b2n_1)
            c += 1.0
            c_a = c - a
            a2n = a2n_1 + c_a * a2n
            b2n = b2n_1 + c_a * b2n
            an0 = dv(a2n, b2n)
            if not (abs(an0 - am0) >= eps * an0):
                break
        return an0


def basym(a, b, lam, eps, log_p):
    # ASYMPTOTIC EXPANSION FOR I_x(A,B) FOR LARGE A AND B.
    num_IT = 20
    e0 = 1.12837916709551
    e1 = 0.353553390593274
    ln_e0 = 0.120782237635245

    a0 = [0.0] * (num_IT + 1)
    b0 = [0.0] * (num_IT + 1)
    c = [0.0] * (num_IT + 1)
    d = [0.0] * (num_IT + 1)

    f = a * rlog1(-lam / a) + b * rlog1(lam / b)
    if log_p:
        t = -f
    else:
        t = exp(-f)
        if t == 0.0:
            return 0.0
    z0 = sqrt(f)
    z = z0 / e1 * 0.5
    z2 = f + f

    if a < b:
        h = a / b
        r0 = 1.0 / (h + 1.0)
        r1 = (b - a) / b
        w0 = 1.0 / sqrt(a * (h + 1.0))
    else:
        h = b / a
        r0 = 1.0 / (h + 1.0)
        r1 = (b - a) / a
        w0 = 1.0 / sqrt(b * (h + 1.0))

    a0[0] = r1 * 0.66666666666666663
    c[0] = a0[0] * -0.5
    d[0] = -c[0]
    j0 = 0.5 / e0 * erfc1(1, z0)
    j1 = e1
    sum_ = j0 + d[0] * w0 * j1

    s = 1.0
    h2 = h * h
    hn = 1.0
    w = w0
    znm1 = z
    zn = z2
    for n in range(2, num_IT + 1, 2):
        hn *= h2
        a0[n - 1] = r0 * 2.0 * (h * hn + 1.0) / (n + 2.0)
        np1 = n + 1
        s += hn
        a0[np1 - 1] = r1 * 2.0 * s / (n + 3.0)

        for i in range(n, np1 + 1):
            r = (i + 1.0) * -0.5
            b0[0] = r * a0[0]
            for m in range(2, i + 1):
                bsum = 0.0
                for jj in range(1, m):
                    mmj = m - jj
                    bsum += (jj * r - mmj) * a0[jj - 1] * b0[mmj - 1]
                b0[m - 1] = r * a0[m - 1] + bsum / m
            c[i - 1] = b0[i - 1] / (i + 1.0)

            dsum = 0.0
            for jj in range(1, i):
                dsum += d[i - jj - 1] * c[jj - 1]
            d[i - 1] = -(dsum + c[i - 1])

        j0 = e1 * znm1 + (n - 1.0) * j0
        j1 = e1 * zn + n * j1
        znm1 = z2 * znm1
        zn = z2 * zn
        w *= w0
        t0 = d[n - 1] * w * j0
        w *= w0
        t1 = d[np1 - 1] * w * j1
        sum_ += t0 + t1
        if abs(t0) + abs(t1) <= eps * sum_:
            break

    if log_p:
        return ln_e0 + t - bcorr(a, b) + log(sum_)
    else:
        u = exp(-bcorr(a, b))
        return e0 * t * u * sum_


_LNB = 0.69314718055995
_EXPARG0 = 1024 * _LNB * 0.99999          # i1mach(16) = DBL_MAX_EXP
_EXPARG1 = (-1021 - 1) * _LNB * 0.99999   # i1mach(15) - 1 = DBL_MIN_EXP - 1


def exparg(l):
    return _EXPARG0 if l == 0 else _EXPARG1


def esum(mu, x, give_log):
    # EVALUATION OF EXP(MU + X)
    if give_log:
        return x + float(mu)
    if x > 0.0:
        if mu > 0:
            return exp(float(mu)) * exp(x)
        w = mu + x
        if w < 0.0:
            return exp(float(mu)) * exp(x)
    else:
        if mu < 0:
            return exp(float(mu)) * exp(x)
        w = mu + x
        if w > 0.0:
            return exp(float(mu)) * exp(x)
    return exp(w)


def rexpm1(x):
    # EVALUATION OF THE FUNCTION EXP(X) - 1
    p1 = 9.14041914819518e-10
    p2 = 0.0238082361044469
    q1 = -0.499999999085958
    q2 = 0.107141568980644
    q3 = -0.0119041179760821
    q4 = 5.95130811860248e-4
    if abs(x) <= 0.15:
        return x * (((p2 * x + p1) * x + 1.0) /
                    ((((q4 * x + q3) * x + q2) * x + q1) * x + 1.0))
    else:
        w = exp(x)
        if x > 0.0:
            return w * (0.5 - 1.0 / w + 0.5)
        else:
            return w - 0.5 - 0.5


def alnrel(a):
    # Evaluation of the function ln(1 + a)
    if abs(a) > 0.375:
        return log(1.0 + a)
    p1 = -1.29418923021993
    p2 = 0.405303492862024
    p3 = -0.0178874546012214
    q1 = -1.62752256355323
    q2 = 0.747811014037616
    q3 = -0.0845104217945565
    t = a / (a + 2.0)
    t2 = t * t
    w = (((p3 * t2 + p2) * t2 + p1) * t2 + 1.0) / \
        (((q3 * t2 + q2) * t2 + q1) * t2 + 1.0)
    return t * 2.0 * w


def rlog1(x):
    # Evaluation of the function x - ln(1 + x)
    a = 0.0566749439387324
    b = 0.0456512608815524
    p0 = 0.333333333333333
    p1 = -0.224696413112536
    p2 = 0.00620886815375787
    q1 = -1.27408923933623
    q2 = 0.354508718369557
    if x < -0.39 or x > 0.57:
        w = x + 0.5 + 0.5
        return x - log(w)
    if x < -0.18:
        h = x + 0.3
        h /= 0.7
        w1 = a - h * 0.3
    elif x > 0.18:
        h = x * 0.75 - 0.25
        w1 = b + h / 3.0
    else:
        h = x
        w1 = 0.0
    r = h / (h + 2.0)
    t = r * r
    w = ((p2 * t + p1) * t + p0) / ((q2 * t + q1) * t + 1.0)
    return t * 2.0 * (1.0 / (1.0 - r) - r * w) + w1


_ERF_C = 0.564189583547756
_ERF_A = (7.7105849500132e-5, -0.00133733772997339, 0.0323076579225834, 0.0479137145607681,
          0.128379167095513)
_ERF_B = (0.00301048631703895, 0.0538971687740286, 0.375795757275549)
_ERF_P = (-1.36864857382717e-7, 0.564195517478974, 7.21175825088309, 43.1622272220567,
          152.98928504694, 339.320816734344, 451.918953711873, 300.459261020162)
_ERF_Q = (1.0, 12.7827273196294, 77.0001529352295, 277.585444743988, 638.980264465631,
          931.35409485061, 790.950925327898, 300.459260956983)
_ERF_R = (2.10144126479064, 26.2370141675169, 21.3688200555087, 4.6580782871847,
          0.282094791773523)
_ERF_S = (94.153775055546, 187.11481179959, 99.0191814623914, 18.0124575948747)


def erf__(x):
    # EVALUATION OF THE REAL ERROR FUNCTION
    a = _ERF_A; b = _ERF_B; p = _ERF_P; q = _ERF_Q; r = _ERF_R; s = _ERF_S
    ax = abs(x)
    if ax <= 0.5:
        t = x * x
        top = (((a[0] * t + a[1]) * t + a[2]) * t + a[3]) * t + a[4] + 1.0
        bot = ((b[0] * t + b[1]) * t + b[2]) * t + 1.0
        return x * (top / bot)
    if ax <= 4.0:
        top = ((((((p[0] * ax + p[1]) * ax + p[2]) * ax + p[3]) * ax + p[4]) * ax
                + p[5]) * ax + p[6]) * ax + p[7]
        bot = ((((((q[0] * ax + q[1]) * ax + q[2]) * ax + q[3]) * ax + q[4]) * ax
                + q[5]) * ax + q[6]) * ax + q[7]
        R = 0.5 - exp(-x * x) * top / bot + 0.5
        return -R if (x < 0) else R
    if ax >= 5.8:
        return 1.0 if x > 0 else -1.0
    x2 = x * x
    t = 1.0 / x2
    top = (((r[0] * t + r[1]) * t + r[2]) * t + r[3]) * t + r[4]
    bot = (((s[0] * t + s[1]) * t + s[2]) * t + s[3]) * t + 1.0
    t = (_ERF_C - top / (x2 * bot)) / ax
    R = 0.5 - exp(-x2) * t + 0.5
    return -R if (x < 0) else R


def erfc1(ind, x):
    # ERFC1(IND,X) = ERFC(X) IF IND = 0, EXP(X*X)*ERFC(X) OTHERWISE
    a = _ERF_A; b = _ERF_B; p = _ERF_P; q = _ERF_Q; r = _ERF_R; s = _ERF_S
    ax = abs(x)
    if ax <= 0.5:
        t = x * x
        top = (((a[0] * t + a[1]) * t + a[2]) * t + a[3]) * t + a[4] + 1.0
        bot = ((b[0] * t + b[1]) * t + b[2]) * t + 1.0
        ret_val = 0.5 - x * (top / bot) + 0.5
        if ind != 0:
            ret_val = exp(t) * ret_val
        return ret_val
    if ax <= 4.0:
        top = ((((((p[0] * ax + p[1]) * ax + p[2]) * ax + p[3]) * ax + p[4]) * ax
                + p[5]) * ax + p[6]) * ax + p[7]
        bot = ((((((q[0] * ax + q[1]) * ax + q[2]) * ax + q[3]) * ax + q[4]) * ax
                + q[5]) * ax + q[6]) * ax + q[7]
        ret_val = top / bot
    else:
        if x <= -5.6:
            ret_val = 2.0
            if ind != 0:
                ret_val = exp(x * x) * 2.0
            return ret_val
        if ind == 0 and (x > 100.0 or x * x > -exparg(1)):
            return 0.0
        t = 1.0 / (x * x)
        top = (((r[0] * t + r[1]) * t + r[2]) * t + r[3]) * t + r[4]
        bot = (((s[0] * t + s[1]) * t + s[2]) * t + s[3]) * t + 1.0
        ret_val = (_ERF_C - t * top / bot) / ax

    if ind != 0:
        if x < 0.0:
            ret_val = exp(x * x) * 2.0 - ret_val
    else:
        w = x * x
        t = w
        e = w - t
        ret_val = (0.5 - e + 0.5) * exp(-t) * ret_val
        if x < 0.0:
            ret_val = 2.0 - ret_val
    return ret_val


_G1_R = (-0.422784335098468, -0.771330383816272, -0.244757765222226, 0.118378989872749,
         9.30357293360349e-4, -0.0118290993445146, 0.00223047661158249, 2.66505979058923e-4,
         -1.32674909766242e-4)
_G1_S1 = 0.273076135303957
_G1_S2 = 0.0559398236957378
_G1_P = (0.577215664901533, -0.409078193005776, -0.230975380857675, 0.0597275330452234,
         0.0076696818164949, -0.00514889771323592, 5.89597428611429e-4)
_G1_Q = (1.0, 0.427569613095214, 0.158451672430138, 0.0261132021441447, 0.00423244297896961)


def gam1(a):
    # COMPUTATION OF 1/GAMMA(A+1) - 1  FOR -0.5 <= A <= 1.5
    t = a
    d = a - 0.5
    if d > 0.0:
        t = d - 0.5
    if t < 0.0:
        r = _G1_R
        top = (((((((r[8] * t + r[7]) * t + r[6]) * t + r[5]) * t + r[4]
                  ) * t + r[3]) * t + r[2]) * t + r[1]) * t + r[0]
        bot = (_G1_S2 * t + _G1_S1) * t + 1.0
        w = top / bot
        if d > 0.0:
            return t * w / a
        else:
            return a * (w + 0.5 + 0.5)
    elif t == 0:
        return 0.0
    else:
        p = _G1_P
        q = _G1_Q
        top = (((((p[6] * t + p[5]) * t + p[4]) * t + p[3]) * t + p[2]
                ) * t + p[1]) * t + p[0]
        bot = (((q[4] * t + q[3]) * t + q[2]) * t + q[1]) * t + 1.0
        w = top / bot
        if d > 0.0:
            return t / a * (w - 0.5 - 0.5)
        else:
            return a * w


def gamln1(a):
    # EVALUATION OF LN(GAMMA(1 + A)) FOR -0.2 <= A <= 1.25
    if a < 0.6:
        p0 = 0.577215664901533
        p1 = 0.844203922187225
        p2 = -0.168860593646662
        p3 = -0.780427615533591
        p4 = -0.402055799310489
        p5 = -0.0673562214325671
        p6 = -0.00271935708322958
        q1 = 2.88743195473681
        q2 = 3.12755088914843
        q3 = 1.56875193295039
        q4 = 0.361951990101499
        q5 = 0.0325038868253937
        q6 = 6.67465618796164e-4
        w = ((((((p6 * a + p5) * a + p4) * a + p3) * a + p2) * a + p1) * a + p0) / \
            ((((((q6 * a + q5) * a + q4) * a + q3) * a + q2) * a + q1) * a + 1.0)
        return -a * w
    else:
        r0 = 0.422784335098467
        r1 = 0.848044614534529
        r2 = 0.565221050691933
        r3 = 0.156513060486551
        r4 = 0.017050248402265
        r5 = 4.97958207639485e-4
        s1 = 1.24313399877507
        s2 = 0.548042109832463
        s3 = 0.10155218743983
        s4 = 0.00713309612391
        s5 = 1.16165475989616e-4
        x = a - 0.5 - 0.5
        w = (((((r5 * x + r4) * x + r3) * x + r2) * x + r1) * x + r0) / \
            (((((s5 * x + s4) * x + s3) * x + s2) * x + s1) * x + 1.0)
        return x * w


_PSI_P1 = (0.0089538502298197, 4.77762828042627, 142.441585084029, 1186.45200713425,
           3633.51846806499, 4138.10161269013, 1305.60269827897)
_PSI_Q1 = (44.8452573429826, 520.752771467162, 2210.0079924783, 3641.27349079381,
           1908.310765963, 6.91091682714533e-6)
_PSI_P2 = (-2.12940445131011, -7.01677227766759, -4.48616543918019, -0.648157123766197)
_PSI_Q2 = (32.2703493791143, 89.2920700481861, 54.6117738103215, 7.77788548522962)


def psi(x):
    # Evaluation of the Digamma function psi(x)
    piov4 = 0.785398163397448
    dx0 = 1.461632144968362341262659542325721325
    p1 = _PSI_P1; q1 = _PSI_Q1; p2 = _PSI_P2; q2 = _PSI_Q2

    xmax1 = float(INT_MAX)
    d2 = 0.5 / (0.5 * DBL_EPSILON)
    if xmax1 > d2:
        xmax1 = d2
    xsmall = 1e-9
    aug = 0.0
    if x < 0.5:
        if abs(x) <= xsmall:
            if x == 0.0:
                return 0.0
            aug = -1.0 / x
        else:
            w = -x
            sgn = piov4
            if w <= 0.0:
                w = -w
                sgn = -sgn
            if w >= xmax1:
                return 0.0
            nq = c_int(w)
            w -= float(nq)
            nq = c_int(w * 4.0)
            w = (w - float(nq) * 0.25) * 4.0
            n = nq // 2
            if n + n != nq:
                w = 1.0 - w
            z = piov4 * w
            m = n // 2
            if m + m != n:
                sgn = -sgn
            n = (nq + 1) // 2
            m = n // 2
            m += m
            if m == n:
                if z == 0.0:
                    return 0.0
                aug = sgn * (cos(z) / sin(z) * 4.0)
            else:
                aug = sgn * (sin(z) / cos(z) * 4.0)
        x = 1.0 - x

    if x <= 3.0:
        den = x
        upper = p1[0] * x
        for i in range(1, 6):
            den = (den + q1[i - 1]) * x
            upper = (upper + p1[i]) * x
        den = (upper + p1[6]) / (den + q1[5])
        xmx0 = x - dx0
        return den * xmx0 + aug

    if x < xmax1:
        w = 1.0 / (x * x)
        den = w
        upper = p2[0] * w
        for i in range(1, 4):
            den = (den + q2[i - 1]) * w
            upper = (upper + p2[i]) * w
        aug = upper / (den + q2[3]) - 0.5 / x + aug
    return aug + log(x)


def betaln(a0, b0):
    # Evaluation of the logarithm of the beta function ln(beta(a0,b0))
    e = 0.918938533204673
    a = _min(a0, b0)
    b = _max(a0, b0)
    if a < 8.0:
        if a < 1.0:
            if b < 8.0:
                return gamln(a) + (gamln(b) - gamln(a + b))
            else:
                return gamln(a) + algdiv(a, b)
        if a < 2.0:
            if b <= 2.0:
                return gamln(a) + gamln(b) - gsumln(a, b)
            if b < 8.0:
                w = 0.0
                return _betaln_L40(a, b, w)
            return gamln(a) + algdiv(a, b)
        if b <= 1e3:
            n = c_int(a - 1.0)
            w = 1.0
            for _i in range(n):
                a += -1.0
                h = a / b
                w *= h / (h + 1.0)
            w = log(w)
            if b >= 8.0:
                return w + gamln(a) + algdiv(a, b)
            return _betaln_L40(a, b, w)
        else:
            n = c_int(a - 1.0)
            w = 1.0
            for _i in range(n):
                a += -1.0
                w *= a / (a / b + 1.0)
            return log(w) - n * log(b) + (gamln(a) + algdiv(a, b))
    else:
        w = bcorr(a, b)
        h = a / b
        u = -(a - 0.5) * log(h / (h + 1.0))
        v = b * alnrel(h)
        if u > v:
            return log(b) * -0.5 + e + w - v - u
        else:
            return log(b) * -0.5 + e + w - u - v


def _betaln_L40(a, b, w):
    # 1 < A <= B < 8 :  reduction of B
    n = c_int(b - 1.0)
    z = 1.0
    for _i in range(n):
        b += -1.0
        z *= b / (a + b)
    return w + log(z) + (gamln(a) + (gamln(b) - gsumln(a, b)))


def gsumln(a, b):
    # EVALUATION OF THE FUNCTION LN(GAMMA(A + B)) FOR 1 <= A <= 2  AND  1 <= B <= 2
    x = a + b - 2.0
    if x <= 0.25:
        return gamln1(x + 1.0)
    if x <= 1.25:
        return gamln1(x) + alnrel(x)
    return gamln1(x - 1.0) + log(x * (x + 1.0))


_C0 = 0.0833333333333333
_C1 = -0.00277777777760991
_C2 = 7.9365066682539e-4
_C3 = -5.9520293135187e-4
_C4 = 8.37308034031215e-4
_C5 = -0.00165322962780713


def bcorr(a0, b0):
    # EVALUATION OF  DEL(A0) + DEL(B0) - DEL(A0 + B0)
    c0 = _C0; c1 = _C1; c2 = _C2; c3 = _C3; c4 = _C4; c5 = _C5
    a = _min(a0, b0)
    b = _max(a0, b0)
    h = a / b
    c = h / (h + 1.0)
    x = 1.0 / (h + 1.0)
    x2 = x * x
    s3 = x + x2 + 1.0
    s5 = x + x2 * s3 + 1.0
    s7 = x + x2 * s5 + 1.0
    s9 = x + x2 * s7 + 1.0
    s11 = x + x2 * s9 + 1.0
    r1 = 1.0 / b
    t = r1 * r1
    w = ((((c5 * s11 * t + c4 * s9) * t + c3 * s7) * t + c2 * s5) * t + c1 *
         s3) * t + c0
    w *= c / b
    r1 = 1.0 / a
    t = r1 * r1
    return (((((c5 * t + c4) * t + c3) * t + c2) * t + c1) * t + c0) / a + w


def algdiv(a, b):
    # COMPUTATION OF LN(GAMMA(B)/GAMMA(A+B)) WHEN B >= 8
    c0 = _C0; c1 = _C1; c2 = _C2; c3 = _C3; c4 = _C4; c5 = _C5
    if a > b:
        h = b / a
        c = 1.0 / (h + 1.0)
        x = h / (h + 1.0)
        d = a + (b - 0.5)
    else:
        h = a / b
        c = h / (h + 1.0)
        x = 1.0 / (h + 1.0)
        d = b + (a - 0.5)
    x2 = x * x
    s3 = x + x2 + 1.0
    s5 = x + x2 * s3 + 1.0
    s7 = x + x2 * s5 + 1.0
    s9 = x + x2 * s7 + 1.0
    s11 = x + x2 * s9 + 1.0
    t = 1.0 / (b * b)
    w = ((((c5 * s11 * t + c4 * s9) * t + c3 * s7) * t + c2 * s5) * t + c1 *
         s3) * t + c0
    w *= c / b
    u = d * alnrel(a / b)
    v = a * (log(b) - 1.0)
    if u > v:
        return w - v - u
    else:
        return w - u - v


def gamln(a):
    # Evaluation of ln(gamma(a)) for positive a
    d = 0.418938533204673
    if a <= 0.8:
        return gamln1(a) - log(a)
    elif a <= 2.25:
        return gamln1(a - 0.5 - 0.5)
    elif a < 10.0:
        n = c_int(a - 1.25)
        t = a
        w = 1.0
        for _i in range(n):
            t += -1.0
            w *= t
        return gamln1(t - 1.0) + log(w)
    else:
        t = 1.0 / (a * a)
        w = (((((_C5 * t + _C4) * t + _C3) * t + _C2) * t + _C1) * t + _C0) / a
        return d + w + (a - 0.5) * (log(a) - 1.0)


# Reine Funktionen ohne Warnungen, deren Argumente in bratio() stets > 0 sind
# (nur von den Formparametern abhängig): Ergebnisse zwischenspeichern.
import functools as _ft  # noqa: E402

betaln = _ft.lru_cache(maxsize=4096)(betaln)
algdiv = _ft.lru_cache(maxsize=4096)(algdiv)
bcorr = _ft.lru_cache(maxsize=4096)(bcorr)
psi = _ft.lru_cache(maxsize=4096)(psi)
