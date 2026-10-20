# Port von R's src/nmath/toms708.c (R 4.3.3): unvollständige Betafunktion.
#
# ACM TOMS 708 (Didonato & Morris 1992) mit den Änderungen des R Core Teams
# (log_p-Zweige, Warnungen). `bratio` liefert `(w, w1, ierr)` statt
# Zeigerargumenten. In `RNmath` eingebunden; Vorlage python/simlev/_r/_toms708.py.

@inline _tmin(a::Float64, b::Float64) = a < b ? a : b
@inline _tmax(a::Float64, b::Float64) = a > b ? a : b

# in toms708.c mit rexpm1() umdefiniert
@inline _T_Log1_Exp(x::Float64) = x > -M_LN2 ? clog(-rexpm1(x)) : clog1p(-cexp(x))

"""
    bratio(a, b, x, y, log_p) -> (w, w1, ierr)

Unvollständiges Beta-Verhältnis `w = I_x(a, b)`, `w1 = 1 - I_x(a, b)`
(ggf. logarithmiert).
"""
function bratio(a::Float64, b::Float64, x::Float64, y::Float64, log_p::Bool)
    eps = 2.0 * (0.5 * DBL_EPSILON)
    R_D__0 = log_p ? NINF : 0.0
    R_D__1 = log_p ? 0.0 : 1.0
    w = R_D__0
    w1 = R_D__0

    (isnan(x) || isnan(y) || isnan(a) || isnan(b)) && return w, w1, 9
    (a < 0.0 || b < 0.0) && return w, w1, 1
    (a == 0.0 && b == 0.0) && return w, w1, 2
    (x < 0.0 || x > 1.0) && return w, w1, 3
    (y < 0.0 || y > 1.0) && return w, w1, 4

    z = x + y - 0.5 - 0.5
    abs(z) > eps * 3.0 && return w, w1, 5

    ierr = 0
    if x == 0.0
        a == 0.0 && return w, w1, 6
        return R_D__0, R_D__1, 0
    end
    if y == 0.0
        b == 0.0 && return w, w1, 7
        return R_D__1, R_D__0, 0
    end
    a == 0.0 && return R_D__1, R_D__0, 0
    b == 0.0 && return R_D__0, R_D__1, 0

    eps = eps > 1e-15 ? eps : 1e-15
    a_lt_b = a < b
    if (a_lt_b ? b : a) < eps * 0.001
        if log_p
            if a_lt_b
                w = clog1p(-a / (a + b))
                w1 = clog(a / (a + b))
            else
                w = clog(b / (a + b))
                w1 = clog1p(-b / (a + b))
            end
        else
            w = b / (a + b)
            w1 = a / (a + b)
        end
        return w, w1, ierr
    end

    # Sprungziele: :end, :end_w, :end_w1, :end_w1_log, :w_bpser, :w1_bpser, :bfrac, :L140
    target = :none
    lam = 0.0
    local a0::Float64, b0::Float64, x0::Float64, y0::Float64, do_swap::Bool
    if (a < b ? a : b) <= 1.0   # ------------------------ a <= 1  or  b <= 1 ----
        do_swap = x > 0.5
        if do_swap
            a0 = b; x0 = y; b0 = a; y0 = x
        else
            a0 = a; x0 = x; b0 = b; y0 = y
        end

        if b0 < (eps < eps * a0 ? eps : eps * a0)   # L80
            w = fpser(a0, b0, x0, eps, log_p)
            w1 = log_p ? _T_Log1_Exp(w) : 0.5 - w + 0.5
            target = :end
        elseif a0 < (eps < eps * b0 ? eps : eps * b0) && b0 * x0 <= 1.0   # L90
            w1 = apser(a0, b0, x0, eps)
            target = :end_w1
        else
            did_bup = false
            n = 0
            go131 = false
            if (a0 > b0 ? a0 : b0) > 1.0   # L20
                if b0 <= 1.0
                    target = :w_bpser
                elseif x0 >= 0.29
                    target = :w1_bpser
                elseif x0 < 0.1 && cpow(x0 * b0, a0) <= 0.7
                    target = :w_bpser
                elseif b0 > 15.0
                    w1 = 0.0
                    go131 = true
                end
            else   # a, b <= 1
                if a0 >= (0.2 < b0 ? 0.2 : b0)
                    target = :w_bpser
                elseif cpow(x0, a0) <= 0.9
                    target = :w_bpser
                elseif x0 >= 0.3
                    target = :w1_bpser
                end
            end
            if target === :none
                if !go131
                    n = 20
                    w1 = bup(b0, a0, y0, x0, n, eps, false)
                    did_bup = true
                    b0 += n
                end
                # L131:
                w1, ierr1 = bgrat(b0, a0, y0, x0, w1, 15 * eps, false)
                if w1 == 0 || (0 < w1 < DBL_MIN)
                    if did_bup
                        w1 = bup(b0 - n, a0, y0, x0, n, eps, true)
                    else
                        w1 = NINF
                    end
                    w1, ierr1 = bgrat(b0, a0, y0, x0, w1, 15 * eps, true)
                    ierr1 != 0 && (ierr = 10 + ierr1)
                    target = :end_w1_log
                else
                    ierr1 != 0 && (ierr = 10 + ierr1)
                    w1 < 0 && ml_warning("bratio(a=$(_g(a)), b=$(_g(b)), x=$(_g(x))): bgrat() -> w1 = $(_g(w1))")
                    target = :end_w1
                end
            end
        end
    else   # L30: -------------------- both  a, b > 1 ---
        if isfinite(a + b)
            lam = (a > b) ? ((a + b) * y - b) : (a - (a + b) * x)
        else
            lam = a * y - b * x
        end
        do_swap = lam < 0.0
        if do_swap
            lam = -lam
            a0 = b; x0 = y; b0 = a; y0 = x
        else
            a0 = a; x0 = x; b0 = b; y0 = y
        end

        if b0 < 40.0
            if b0 * x0 <= 0.7 || (log_p && lam > 650.0)
                target = :w_bpser
            else
                target = :L140
            end
        elseif a0 > b0
            (b0 <= 100.0 || lam > b0 * 0.03) && (target = :bfrac)
        elseif a0 <= 100.0
            target = :bfrac
        elseif lam > a0 * 0.03
            target = :bfrac
        end

        if target === :none   # L180
            w = basym(a0, b0, lam, eps * 100.0, log_p)
            w1 = log_p ? _T_Log1_Exp(w) : 0.5 - w + 0.5
            target = :end
        end
    end

    if target === :L140
        n = c_int(b0)
        b0 -= n
        if b0 == 0.0
            n -= 1
            b0 = 1.0
        end
        w = bup(b0, a0, y0, x0, n, eps, false)
        if w < DBL_MIN && log_p
            b0 += n
            target = :w_bpser
        elseif x0 <= 0.7
            w += bpser(a0, b0, x0, eps, false)
            target = :end_w
        else
            if a0 <= 15.0
                n = 20
                w += bup(a0, b0, x0, y0, n, eps, false)
                a0 += n
            end
            w, ierr1 = bgrat(a0, b0, x0, y0, w, 15 * eps, false)
            ierr1 != 0 && (ierr = 10 + ierr1)
            target = :end_w
        end
    end

    if target === :w_bpser
        w = bpser(a0, b0, x0, eps, log_p)
        w1 = log_p ? _T_Log1_Exp(w) : 0.5 - w + 0.5
    elseif target === :w1_bpser
        w1 = bpser(b0, a0, y0, eps, log_p)
        w = log_p ? _T_Log1_Exp(w1) : 0.5 - w1 + 0.5
    elseif target === :bfrac
        w = bfrac(a0, b0, x0, y0, lam, eps * 15.0, log_p)
        w1 = log_p ? _T_Log1_Exp(w) : 0.5 - w + 0.5
    elseif target === :end_w
        if log_p
            w1 = clog1p(-w)
            w = clog(w)
        else
            w1 = 0.5 - w + 0.5
        end
    elseif target === :end_w1
        if log_p
            w = clog1p(-w1)
            w1 = clog(w1)
        else
            w = 0.5 - w1 + 0.5
        end
    elseif target === :end_w1_log
        if log_p
            w = _T_Log1_Exp(w1)
        else
            w = -cexpm1(w1)
            w1 = cexp(w1)
        end
    end

    # L_end:
    do_swap && ((w, w1) = (w1, w))
    return w, w1, ierr
end

function fpser(a::Float64, b::Float64, x::Float64, eps::Float64, log_p::Bool)
    # EVALUATION OF I (A,B) FOR B < MIN(EPS, EPS*A) AND X <= 0.5
    if log_p
        ans = a * clog(x)
    elseif a > eps * 0.001
        t = a * clog(x)
        t < exparg(1) && return 0.0
        ans = cexp(t)
    else
        ans = 1.0
    end
    if log_p
        ans += clog(b) - clog(a)
    else
        ans *= b / a
    end
    tol = eps / a
    an = a + 1.0
    t = x
    s = t / an
    while true
        an += 1.0
        t = x * t
        c = t / an
        s += c
        abs(c) > tol || break
    end
    if log_p
        ans += clog1p(a * s)
    else
        ans *= a * s + 1.0
    end
    return ans
end

function apser(a::Float64, b::Float64, x::Float64, eps::Float64)
    g = 0.577215664901533
    bx = b * x
    t = x - bx
    if b * eps <= 0.02
        c = clog(x) + psi(b) + g + t
    else
        c = clog(bx) + g + t
    end
    tol = eps * 5.0 * abs(c)
    j = 1.0
    s = 0.0
    while true
        j += 1.0
        t *= x - bx / j
        aj = t / j
        s += aj
        abs(aj) > tol || break
    end
    return -a * (c + s)
end

function bpser(a::Float64, b::Float64, x::Float64, eps::Float64, log_p::Bool)
    # Power SERies expansion for evaluating I_x(a,b) when b <= 1 or b*x <= 0.7
    x == 0.0 && return log_p ? NINF : 0.0
    local ans::Float64
    a0 = _tmin(a, b)
    if a0 >= 1.0
        z = a * clog(x) - betaln(a, b)
        ans = log_p ? z - clog(a) : cexp(z) / a
    else
        b0 = _tmax(a, b)
        if b0 < 8.0
            if b0 <= 1.0   # a0 < 1 and b0 <= 1
                if log_p
                    ans = a * clog(x)
                else
                    ans = cpow(x, a)
                    ans == 0.0 && return ans
                end
                apb = a + b
                if apb > 1.0
                    u = a + b - 1.0
                    z = (gam1(u) + 1.0) / apb
                else
                    z = gam1(apb) + 1.0
                end
                c = (gam1(a) + 1.0) * (gam1(b) + 1.0) / z
                if log_p
                    ans += clog(c * (b / apb))
                else
                    ans *= c * (b / apb)
                end
            else   # a0 < 1 < b0 < 8
                u = gamln1(a0)
                m = c_int(b0 - 1.0)
                if m >= 1
                    c = 1.0
                    for _ in 1:m
                        b0 += -1.0
                        c *= b0 / (a0 + b0)
                    end
                    u += clog(c)
                end
                z = a * clog(x) - u
                b0 += -1.0
                apb = a0 + b0
                if apb > 1.0
                    u = a0 + b0 - 1.0
                    t = (gam1(u) + 1.0) / apb
                else
                    t = gam1(apb) + 1.0
                end
                if log_p
                    ans = z + clog(a0 / a) + clog1p(gam1(b0)) - clog(t)
                else
                    ans = cexp(z) * (a0 / a) * (gam1(b0) + 1.0) / t
                end
            end
        else   # a0 < 1 < 8 <= b0
            u = gamln1(a0) + algdiv(a0, b0)
            z = a * clog(x) - u
            if log_p
                ans = z + clog(a0 / a)
            else
                ans = a0 / a * cexp(z)
            end
        end
    end

    (ans == (log_p ? NINF : 0.0) || (!log_p && a <= eps * 0.1)) && return ans

    # COMPUTE THE SERIES
    tol = eps / a
    n = 0.0
    sum_ = 0.0
    c = 1.0
    w = 0.0
    while true
        n += 1.0
        c *= (0.5 - b / n + 0.5) * x
        w = c / (a + n)
        sum_ += w
        (n < 1e7 && abs(w) > tol) || break
    end
    if abs(w) > tol
        if (log_p && !(a * sum_ > -1.0 && abs(clog1p(a * sum_)) < eps * abs(ans))) ||
           (!log_p && abs(a * sum_ + 1.0) != 1.0)
            ml_warning(" bpser(a=$(_g(a)), b=$(_g(b)), x=$(_g(x)),...) did not converge (n=1e7, |w|/tol=$(_g(abs(w) / tol)) > 1; A=$(_g(ans)))")
        end
    end
    if log_p
        if a * sum_ > -1.0
            ans += clog1p(a * sum_)
        else
            ans > NINF && ml_warning("pbeta(*, log.p=TRUE) -> bpser(a=$(_g(a)), b=$(_g(b)), x=$(_g(x)),...) underflow to -Inf")
            ans = NINF
        end
    elseif a * sum_ > -1.0
        ans *= (a * sum_ + 1.0)
    else
        ans = 0.0
    end
    return ans
end

function bup(a::Float64, b::Float64, x::Float64, y::Float64, n::Int, eps::Float64, give_log::Bool)
    # EVALUATION OF I_x(A,B) - I_x(A+N,B) WHERE N IS A POSITIVE INT.
    apb = a + b
    ap1 = a + 1.0
    if n > 1 && a >= 1.0 && apb >= ap1 * 1.1
        mu = c_int(abs(exparg(1)))
        k = c_int(exparg(0))
        mu > k && (mu = k)
        d = cexp(-Float64(mu))
    else
        mu = 0
        d = 1.0
    end
    ret_val = give_log ? (brcmp1(mu, a, b, x, y, true) - clog(a)) : brcmp1(mu, a, b, x, y, false) / a
    (n == 1 || (give_log && ret_val == NINF) || (!give_log && ret_val == 0.0)) && return ret_val

    nm1 = n - 1
    w = d
    k = 0
    if b > 1.0
        if y > 1e-4
            r = (b - 1.0) * x / y - a
            if r >= 1.0
                k = (r < nm1) ? c_int(r) : nm1
            end
        else
            k = nm1
        end
        for i in 0:k-1
            l = Float64(i)
            d *= (apb + l) / (ap1 + l) * x
            w += d
        end
    end
    for i in k:nm1-1
        l = Float64(i)
        d *= (apb + l) / (ap1 + l) * x
        w += d
        d <= eps * w && break
    end
    if give_log
        ret_val += clog(w)
    else
        ret_val *= w
    end
    return ret_val
end

function bfrac(a::Float64, b::Float64, x::Float64, y::Float64, lam::Float64, eps::Float64, log_p::Bool)
    # Continued fraction expansion for I_x(a,b) when a, b > 1.
    isfinite(lam) || return NaN
    brc = brcomp(a, b, x, y, log_p)
    isnan(brc) && return NaN
    (!log_p && brc == 0.0) && return 0.0

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

    while true
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
        r = anp1 / bnp1
        abs(r - r0) <= eps * r && break

        an = an / bnp1
        bn = bn / bnp1
        anp1 = r
        bnp1 = 1.0
        n < 10000 || break
    end
    if n >= 10000 && abs(r - r0) > eps * r
        ml_warning(" bfrac(a=$(_g(a)), b=$(_g(b)), x=$(_g(x)), y=$(_g(y)), lambda=$(_g(lam))) did *not* converge (in 10000 steps)")
    end
    return log_p ? (brc + clog(r)) : brc * r
end

function brcomp(a::Float64, b::Float64, x::Float64, y::Float64, log_p::Bool)
    # Evaluation of x^a * y^b / Beta(a,b)
    const__ = 0.398942280401433
    (x == 0.0 || y == 0.0) && return log_p ? NINF : 0.0
    a0 = _tmin(a, b)
    if a0 < 8.0
        if x <= 0.375
            lnx = clog(x)
            lny = alnrel(-x)
        else
            if y > 0.375
                lnx = clog(x)
                lny = clog(y)
            else
                lnx = alnrel(-y)
                lny = clog(y)
            end
        end
        z = a * lnx + b * lny
        if a0 >= 1.0
            z -= betaln(a, b)
            return log_p ? z : cexp(z)
        end
        b0 = _tmax(a, b)
        if b0 >= 8.0   # L80
            u = gamln1(a0) + algdiv(a0, b0)
            return log_p ? (clog(a0) + (z - u)) : a0 * cexp(z - u)
        end
        if b0 <= 1.0
            e_z = log_p ? z : cexp(z)
            (!log_p && e_z == 0.0) && return 0.0
            apb = a + b
            if apb > 1.0
                u = a + b - 1.0
                z = (gam1(u) + 1.0) / apb
            else
                z = gam1(apb) + 1.0
            end
            c = (gam1(a) + 1.0) * (gam1(b) + 1.0) / z
            return log_p ? (e_z + clog(a0 * c) - clog1p(a0 / b0)) : e_z * (a0 * c) / (a0 / b0 + 1.0)
        end
        # ALGORITHM FOR 1 < b0 < 8
        u = gamln1(a0)
        n = c_int(b0 - 1.0)
        if n >= 1
            c = 1.0
            for _ in 1:n
                b0 += -1.0
                c *= b0 / (a0 + b0)
            end
            u = clog(c) + u
        end
        z -= u
        b0 += -1.0
        apb = a0 + b0
        if apb > 1.0
            u = a0 + b0 - 1.0
            t = (gam1(u) + 1.0) / apb
        else
            t = gam1(apb) + 1.0
        end
        return log_p ? (clog(a0) + z + clog1p(gam1(b0)) - clog(t)) : a0 * cexp(z) * (gam1(b0) + 1.0) / t
    else
        # PROCEDURE FOR A >= 8 AND B >= 8
        if a <= b
            h = a / b
            x0 = h / (h + 1.0)
            y0 = 1.0 / (h + 1.0)
            lam = a - (a + b) * x
        else
            h = b / a
            x0 = 1.0 / (h + 1.0)
            y0 = h / (h + 1.0)
            lam = (a + b) * y - b
        end
        e = -lam / a
        if abs(e) > 0.6
            u = e - clog(x / x0)
        else
            u = rlog1(e)
        end
        e = lam / b
        if abs(e) <= 0.6
            v = rlog1(e)
        else
            v = e - clog(y / y0)
        end
        z = log_p ? -(a * u + b * v) : cexp(-(a * u + b * v))
        return log_p ? (-M_LN_SQRT_2PI + 0.5 * clog(b * x0) + z - bcorr(a, b)) :
               const__ * csqrt(b * x0) * z * cexp(-bcorr(a, b))
    end
end

function brcmp1(mu::Int, a::Float64, b::Float64, x::Float64, y::Float64, give_log::Bool)
    # Evaluation of exp(mu) * x^a * y^b / beta(a,b)
    const__ = 0.398942280401433
    a0 = _tmin(a, b)
    if a0 < 8.0
        if x <= 0.375
            lnx = clog(x)
            lny = alnrel(-x)
        elseif y > 0.375
            lnx = clog(x)
            lny = clog(y)
        else
            lnx = alnrel(-y)
            lny = clog(y)
        end
        z = a * lnx + b * lny
        if a0 >= 1.0
            z -= betaln(a, b)
            return esum(mu, z, give_log)
        end
        b0 = _tmax(a, b)
        if b0 >= 8.0
            u = gamln1(a0) + algdiv(a0, b0)
            return give_log ? (clog(a0) + esum(mu, z - u, true)) : a0 * esum(mu, z - u, false)
        elseif b0 <= 1.0
            ans = esum(mu, z, give_log)
            ans == (give_log ? NINF : 0.0) && return ans
            apb = a + b
            if apb > 1.0
                u = a + b - 1.0
                z = (gam1(u) + 1.0) / apb
            else
                z = gam1(apb) + 1.0
            end
            c = give_log ? (clog1p(gam1(a)) + clog1p(gam1(b)) - clog(z)) : (gam1(a) + 1.0) * (gam1(b) + 1.0) / z
            return give_log ? (ans + clog(a0) + c - clog1p(a0 / b0)) : ans * (a0 * c) / (a0 / b0 + 1.0)
        end
        # a0 < 1 < b0 < 8
        u = gamln1(a0)
        n = c_int(b0 - 1.0)
        if n >= 1
            c = 1.0
            for _ in 1:n
                b0 += -1.0
                c *= b0 / (a0 + b0)
            end
            u += clog(c)
        end
        z -= u
        b0 += -1.0
        apb = a0 + b0
        if apb > 1.0
            t = (gam1(apb - 1.0) + 1.0) / apb
        else
            t = gam1(apb) + 1.0
        end
        return give_log ? (clog(a0) + esum(mu, z, true) + clog1p(gam1(b0)) - clog(t)) :
               a0 * esum(mu, z, false) * (gam1(b0) + 1.0) / t
    else
        # PROCEDURE FOR A >= 8 AND B >= 8
        if a > b
            h = b / a
            x0 = 1.0 / (h + 1.0)
            y0 = h / (h + 1.0)
            lam = (a + b) * y - b
        else
            h = a / b
            x0 = h / (h + 1.0)
            y0 = 1.0 / (h + 1.0)
            lam = a - (a + b) * x
        end
        lx0 = -clog1p(b / a)
        e = -lam / a
        if abs(e) > 0.6
            u = e - clog(x / x0)
        else
            u = rlog1(e)
        end
        e = lam / b
        if abs(e) > 0.6
            v = e - clog(y / y0)
        else
            v = rlog1(e)
        end
        z = esum(mu, -(a * u + b * v), give_log)
        return give_log ? (clog(const__) + (clog(b) + lx0) / 2.0 + z - bcorr(a, b)) :
               const__ * csqrt(b * x0) * z * cexp(-bcorr(a, b))
    end
end

"Asymptotische Entwicklung für I_x(a,b), a groß gegenüber b → `(w_neu, ierr)`."
function bgrat(a::Float64, b::Float64, x::Float64, y::Float64, w::Float64, eps::Float64, log_w::Bool)
    n_terms_bgrat = 30
    c = zeros(n_terms_bgrat)
    d = zeros(n_terms_bgrat)
    bm1 = b - 0.5 - 0.5
    nu = a + bm1 * 0.5
    lnx = (y > 0.375) ? clog(x) : alnrel(-y)
    z = -nu * lnx

    if b * z == 0.0
        ml_warning("bgrat(a=$(_g(a)), b=$(_g(b)), x=$(_g(x)), y=$(_g(y))): z=$(_g(z)), b*z == 0 underflow, hence inaccurate pbeta()")
        return w, 1
    end

    log_r = clog(b) + clog1p(gam1(b)) + b * clog(z) + nu * lnx
    log_u = log_r - (algdiv(b, a) + b * clog(nu))
    u = cexp(log_u)
    log_u == NINF && return w, 2

    u_0 = (u == 0.0)
    if log_w
        l = (w == NINF) ? 0.0 : cexp(w - log_u)
    else
        l = (w == 0.0) ? 0.0 : cexp(clog(w) - log_u)
    end

    q_r = grat_r(b, z, log_r, eps)
    v = 0.25 / (nu * nu)
    t2 = lnx * 0.25 * lnx
    j = q_r
    sum_ = j
    t = 1.0
    cn = 1.0
    n2 = 0.0
    ierr = 0
    for n in 1:n_terms_bgrat
        bp2n = b + n2
        j = (bp2n * (bp2n + 1.0) * j + (z + bp2n + 1.0) * t) * v
        n2 += 2.0
        t *= t2
        cn /= n2 * (n2 + 1.0)
        nm1 = n - 1
        c[nm1+1] = cn
        s = 0.0
        if n > 1
            coef = b - n
            for i in 1:nm1
                s += coef * c[i] * d[nm1-i+1]
                coef += b
            end
        end
        d[nm1+1] = bm1 * cn + s / n
        dj = d[nm1+1] * j
        sum_ += dj
        sum_ <= 0.0 && return w, 3
        if abs(dj) <= eps * (sum_ + l)
            ierr = 0
            break
        elseif n == n_terms_bgrat
            ierr = 4
            ml_warning("bgrat(a=$(_g(a)), b=$(_g(b)), x=$(_g(x))) *no* convergence: NOTIFY R-core!\n dj=$(_g(dj)), rel.err=$(_g(abs(dj) / (sum_ + l)))")
        end
    end
    if log_w
        w = _logspace_add(w, log_u + clog(sum_))
    else
        w += u_0 ? cexp(log_u + clog(sum_)) : u * sum_
    end
    return w, ierr
end

function grat_r(a::Float64, x::Float64, log_r::Float64, eps::Float64)
    # Scaled complement of incomplete gamma ratio function Q(a,x)/r
    if a * x == 0.0
        return x <= a ? cexp(-log_r) : 0.0
    elseif a == 0.5
        if x < 0.25
            p = erf__(csqrt(x))
            return (0.5 - p + 0.5) * cexp(-log_r)
        else
            sx = csqrt(x)
            return erfc1(1, sx) / sx * M_SQRT_PI
        end
    elseif x < 1.1
        an = 3.0
        c = x
        sum_ = x / (a + 3.0)
        tol = eps * 0.1 / (a + 1.0)
        while true
            an += 1.0
            c *= -(x / an)
            t = c / (a + an)
            sum_ += t
            abs(t) > tol || break
        end
        j = a * x * ((sum_ / 6.0 - 0.5 / (a + 2.0)) * x + 1.0 / (a + 1.0))
        z = a * clog(x)
        h = gam1(a)
        g = h + 1.0
        if (x >= 0.25 && (a < x / 2.59)) || (z > -0.13394)
            l = rexpm1(z)
            q = ((l + 0.5 + 0.5) * j - l) * g - h
            return q <= 0.0 ? 0.0 : q * cexp(-log_r)
        else
            p = cexp(z) * g * (0.5 - j + 0.5)
            return (0.5 - p + 0.5) * cexp(-log_r)
        end
    else
        # Continued Fraction Expansion
        a2n_1 = 1.0
        a2n = 1.0
        b2n_1 = x
        b2n = x + (1.0 - a)
        c = 1.0
        while true
            a2n_1 = x * a2n + c * a2n_1
            b2n_1 = x * b2n + c * b2n_1
            am0 = a2n_1 / b2n_1
            c += 1.0
            c_a = c - a
            a2n = a2n_1 + c_a * a2n
            b2n = b2n_1 + c_a * b2n
            an0 = a2n / b2n
            abs(an0 - am0) >= eps * an0 || return an0
        end
    end
end

function basym(a::Float64, b::Float64, lam::Float64, eps::Float64, log_p::Bool)
    # ASYMPTOTIC EXPANSION FOR I_x(A,B) FOR LARGE A AND B.
    num_IT = 20
    e0 = 1.12837916709551
    e1 = 0.353553390593274
    ln_e0 = 0.120782237635245

    a0 = zeros(num_IT + 1)
    b0 = zeros(num_IT + 1)
    c = zeros(num_IT + 1)
    d = zeros(num_IT + 1)

    f = a * rlog1(-lam / a) + b * rlog1(lam / b)
    if log_p
        t = -f
    else
        t = cexp(-f)
        t == 0.0 && return 0.0
    end
    z0 = csqrt(f)
    z = z0 / e1 * 0.5
    z2 = f + f

    if a < b
        h = a / b
        r0 = 1.0 / (h + 1.0)
        r1 = (b - a) / b
        w0 = 1.0 / csqrt(a * (h + 1.0))
    else
        h = b / a
        r0 = 1.0 / (h + 1.0)
        r1 = (b - a) / a
        w0 = 1.0 / csqrt(b * (h + 1.0))
    end

    a0[1] = r1 * 0.66666666666666663
    c[1] = a0[1] * -0.5
    d[1] = -c[1]
    j0 = 0.5 / e0 * erfc1(1, z0)
    j1 = e1
    sum_ = j0 + d[1] * w0 * j1

    s = 1.0
    h2 = h * h
    hn = 1.0
    w = w0
    znm1 = z
    zn = z2
    for n in 2:2:num_IT
        hn *= h2
        a0[n] = r0 * 2.0 * (h * hn + 1.0) / (n + 2.0)
        np1 = n + 1
        s += hn
        a0[np1] = r1 * 2.0 * s / (n + 3.0)

        for i in n:np1
            r = (i + 1.0) * -0.5
            b0[1] = r * a0[1]
            for m in 2:i
                bsum = 0.0
                for jj in 1:m-1
                    mmj = m - jj
                    bsum += (jj * r - mmj) * a0[jj] * b0[mmj]
                end
                b0[m] = r * a0[m] + bsum / m
            end
            c[i] = b0[i] / (i + 1.0)
            dsum = 0.0
            for jj in 1:i-1
                dsum += d[i-jj] * c[jj]
            end
            d[i] = -(dsum + c[i])
        end

        j0 = e1 * znm1 + (n - 1.0) * j0
        j1 = e1 * zn + n * j1
        znm1 = z2 * znm1
        zn = z2 * zn
        w *= w0
        t0 = d[n] * w * j0
        w *= w0
        t1 = d[np1] * w * j1
        sum_ += t0 + t1
        abs(t0) + abs(t1) <= eps * sum_ && break
    end

    if log_p
        return ln_e0 + t - bcorr(a, b) + clog(sum_)
    else
        u = cexp(-bcorr(a, b))
        return e0 * t * u * sum_
    end
end

const _LNB = 0.69314718055995
const _EXPARG0 = 1024 * _LNB * 0.99999          # i1mach(16) = DBL_MAX_EXP
const _EXPARG1 = (-1021 - 1) * _LNB * 0.99999   # i1mach(15) - 1 = DBL_MIN_EXP - 1

exparg(l::Integer) = l == 0 ? _EXPARG0 : _EXPARG1

function esum(mu::Int, x::Float64, give_log::Bool)
    # EVALUATION OF EXP(MU + X)
    give_log && return x + Float64(mu)
    local w::Float64
    if x > 0.0
        mu > 0 && return cexp(Float64(mu)) * cexp(x)
        w = mu + x
        w < 0.0 && return cexp(Float64(mu)) * cexp(x)
    else
        mu < 0 && return cexp(Float64(mu)) * cexp(x)
        w = mu + x
        w > 0.0 && return cexp(Float64(mu)) * cexp(x)
    end
    return cexp(w)
end

function rexpm1(x::Float64)
    # EVALUATION OF THE FUNCTION EXP(X) - 1
    p1 = 9.14041914819518e-10
    p2 = 0.0238082361044469
    q1 = -0.499999999085958
    q2 = 0.107141568980644
    q3 = -0.0119041179760821
    q4 = 5.95130811860248e-4
    if abs(x) <= 0.15
        return x * (((p2 * x + p1) * x + 1.0) / ((((q4 * x + q3) * x + q2) * x + q1) * x + 1.0))
    else
        w = cexp(x)
        if x > 0.0
            return w * (0.5 - 1.0 / w + 0.5)
        else
            return w - 0.5 - 0.5
        end
    end
end

function alnrel(a::Float64)
    # Evaluation of the function ln(1 + a)
    abs(a) > 0.375 && return clog(1.0 + a)
    p1 = -1.29418923021993
    p2 = 0.405303492862024
    p3 = -0.0178874546012214
    q1 = -1.62752256355323
    q2 = 0.747811014037616
    q3 = -0.0845104217945565
    t = a / (a + 2.0)
    t2 = t * t
    w = (((p3 * t2 + p2) * t2 + p1) * t2 + 1.0) / (((q3 * t2 + q2) * t2 + q1) * t2 + 1.0)
    return t * 2.0 * w
end

function rlog1(x::Float64)
    # Evaluation of the function x - ln(1 + x)
    a = 0.0566749439387324
    b = 0.0456512608815524
    p0 = 0.333333333333333
    p1 = -0.224696413112536
    p2 = 0.00620886815375787
    q1 = -1.27408923933623
    q2 = 0.354508718369557
    if x < -0.39 || x > 0.57
        w = x + 0.5 + 0.5
        return x - clog(w)
    end
    if x < -0.18
        h = x + 0.3
        h /= 0.7
        w1 = a - h * 0.3
    elseif x > 0.18
        h = x * 0.75 - 0.25
        w1 = b + h / 3.0
    else
        h = x
        w1 = 0.0
    end
    r = h / (h + 2.0)
    t = r * r
    w = ((p2 * t + p1) * t + p0) / ((q2 * t + q1) * t + 1.0)
    return t * 2.0 * (1.0 / (1.0 - r) - r * w) + w1
end

const _ERF_C = 0.564189583547756
const _ERF_A = (7.7105849500132e-5, -0.00133733772997339, 0.0323076579225834, 0.0479137145607681,
                0.128379167095513)
const _ERF_B = (0.00301048631703895, 0.0538971687740286, 0.375795757275549)
const _ERF_P = (-1.36864857382717e-7, 0.564195517478974, 7.21175825088309, 43.1622272220567,
                152.98928504694, 339.320816734344, 451.918953711873, 300.459261020162)
const _ERF_Q = (1.0, 12.7827273196294, 77.0001529352295, 277.585444743988, 638.980264465631,
                931.35409485061, 790.950925327898, 300.459260956983)
const _ERF_R = (2.10144126479064, 26.2370141675169, 21.3688200555087, 4.6580782871847,
                0.282094791773523)
const _ERF_S = (94.153775055546, 187.11481179959, 99.0191814623914, 18.0124575948747)

function erf__(x::Float64)
    # EVALUATION OF THE REAL ERROR FUNCTION
    a = _ERF_A; b = _ERF_B; p = _ERF_P; q = _ERF_Q; r = _ERF_R; s = _ERF_S
    ax = abs(x)
    if ax <= 0.5
        t = x * x
        top = (((a[1] * t + a[2]) * t + a[3]) * t + a[4]) * t + a[5] + 1.0
        bot = ((b[1] * t + b[2]) * t + b[3]) * t + 1.0
        return x * (top / bot)
    end
    if ax <= 4.0
        top = ((((((p[1] * ax + p[2]) * ax + p[3]) * ax + p[4]) * ax + p[5]) * ax + p[6]) * ax + p[7]) * ax + p[8]
        bot = ((((((q[1] * ax + q[2]) * ax + q[3]) * ax + q[4]) * ax + q[5]) * ax + q[6]) * ax + q[7]) * ax + q[8]
        R = 0.5 - cexp(-x * x) * top / bot + 0.5
        return x < 0 ? -R : R
    end
    ax >= 5.8 && return x > 0 ? 1.0 : -1.0
    x2 = x * x
    t = 1.0 / x2
    top = (((r[1] * t + r[2]) * t + r[3]) * t + r[4]) * t + r[5]
    bot = (((s[1] * t + s[2]) * t + s[3]) * t + s[4]) * t + 1.0
    t = (_ERF_C - top / (x2 * bot)) / ax
    R = 0.5 - cexp(-x2) * t + 0.5
    return x < 0 ? -R : R
end

function erfc1(ind::Int, x::Float64)
    # ERFC1(IND,X) = ERFC(X) IF IND = 0, EXP(X*X)*ERFC(X) OTHERWISE
    a = _ERF_A; b = _ERF_B; p = _ERF_P; q = _ERF_Q; r = _ERF_R; s = _ERF_S
    ax = abs(x)
    if ax <= 0.5
        t = x * x
        top = (((a[1] * t + a[2]) * t + a[3]) * t + a[4]) * t + a[5] + 1.0
        bot = ((b[1] * t + b[2]) * t + b[3]) * t + 1.0
        ret_val = 0.5 - x * (top / bot) + 0.5
        ind != 0 && (ret_val = cexp(t) * ret_val)
        return ret_val
    end
    if ax <= 4.0
        top = ((((((p[1] * ax + p[2]) * ax + p[3]) * ax + p[4]) * ax + p[5]) * ax + p[6]) * ax + p[7]) * ax + p[8]
        bot = ((((((q[1] * ax + q[2]) * ax + q[3]) * ax + q[4]) * ax + q[5]) * ax + q[6]) * ax + q[7]) * ax + q[8]
        ret_val = top / bot
    else
        if x <= -5.6
            ret_val = 2.0
            ind != 0 && (ret_val = cexp(x * x) * 2.0)
            return ret_val
        end
        (ind == 0 && (x > 100.0 || x * x > -exparg(1))) && return 0.0
        t = 1.0 / (x * x)
        top = (((r[1] * t + r[2]) * t + r[3]) * t + r[4]) * t + r[5]
        bot = (((s[1] * t + s[2]) * t + s[3]) * t + s[4]) * t + 1.0
        ret_val = (_ERF_C - t * top / bot) / ax
    end
    if ind != 0
        x < 0.0 && (ret_val = cexp(x * x) * 2.0 - ret_val)
    else
        w = x * x
        t = w
        e = w - t
        ret_val = (0.5 - e + 0.5) * cexp(-t) * ret_val
        x < 0.0 && (ret_val = 2.0 - ret_val)
    end
    return ret_val
end

const _G1_R = (-0.422784335098468, -0.771330383816272, -0.244757765222226, 0.118378989872749,
               9.30357293360349e-4, -0.0118290993445146, 0.00223047661158249, 2.66505979058923e-4,
               -1.32674909766242e-4)
const _G1_S1 = 0.273076135303957
const _G1_S2 = 0.0559398236957378
const _G1_P = (0.577215664901533, -0.409078193005776, -0.230975380857675, 0.0597275330452234,
               0.0076696818164949, -0.00514889771323592, 5.89597428611429e-4)
const _G1_Q = (1.0, 0.427569613095214, 0.158451672430138, 0.0261132021441447, 0.00423244297896961)

function gam1(a::Float64)
    # COMPUTATION OF 1/GAMMA(A+1) - 1  FOR -0.5 <= A <= 1.5
    t = a
    d = a - 0.5
    d > 0.0 && (t = d - 0.5)
    if t < 0.0
        r = _G1_R
        top = (((((((r[9] * t + r[8]) * t + r[7]) * t + r[6]) * t + r[5]) * t + r[4]) * t + r[3]) * t + r[2]) * t + r[1]
        bot = (_G1_S2 * t + _G1_S1) * t + 1.0
        w = top / bot
        return d > 0.0 ? t * w / a : a * (w + 0.5 + 0.5)
    elseif t == 0
        return 0.0
    else
        p = _G1_P
        q = _G1_Q
        top = (((((p[7] * t + p[6]) * t + p[5]) * t + p[4]) * t + p[3]) * t + p[2]) * t + p[1]
        bot = (((q[5] * t + q[4]) * t + q[3]) * t + q[2]) * t + 1.0
        w = top / bot
        return d > 0.0 ? t / a * (w - 0.5 - 0.5) : a * w
    end
end

function gamln1(a::Float64)
    # EVALUATION OF LN(GAMMA(1 + A)) FOR -0.2 <= A <= 1.25
    if a < 0.6
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
        w = ((((((p6 * a + p5) * a + p4) * a + p3) * a + p2) * a + p1) * a + p0) /
            ((((((q6 * a + q5) * a + q4) * a + q3) * a + q2) * a + q1) * a + 1.0)
        return -a * w
    else
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
        w = (((((r5 * x + r4) * x + r3) * x + r2) * x + r1) * x + r0) /
            (((((s5 * x + s4) * x + s3) * x + s2) * x + s1) * x + 1.0)
        return x * w
    end
end

const _PSI_P1 = (0.0089538502298197, 4.77762828042627, 142.441585084029, 1186.45200713425,
                 3633.51846806499, 4138.10161269013, 1305.60269827897)
const _PSI_Q1 = (44.8452573429826, 520.752771467162, 2210.0079924783, 3641.27349079381,
                 1908.310765963, 6.91091682714533e-6)
const _PSI_P2 = (-2.12940445131011, -7.01677227766759, -4.48616543918019, -0.648157123766197)
const _PSI_Q2 = (32.2703493791143, 89.2920700481861, 54.6117738103215, 7.77788548522962)

function psi(x::Float64)
    # Evaluation of the Digamma function psi(x)
    piov4 = 0.785398163397448
    dx0 = 1.461632144968362341262659542325721325
    p1 = _PSI_P1; q1 = _PSI_Q1; p2 = _PSI_P2; q2 = _PSI_Q2

    xmax1 = Float64(INT_MAX)
    d2 = 0.5 / (0.5 * DBL_EPSILON)
    xmax1 > d2 && (xmax1 = d2)
    xsmall = 1e-9
    aug = 0.0
    if x < 0.5
        if abs(x) <= xsmall
            x == 0.0 && return 0.0
            aug = -1.0 / x
        else
            w = -x
            sgn = piov4
            if w <= 0.0
                w = -w
                sgn = -sgn
            end
            w >= xmax1 && return 0.0
            nq = c_int(w)
            w -= Float64(nq)
            nq = c_int(w * 4.0)
            w = (w - Float64(nq) * 0.25) * 4.0
            n = nq ÷ 2
            n + n != nq && (w = 1.0 - w)
            z = piov4 * w
            m = n ÷ 2
            m + m != n && (sgn = -sgn)
            n = (nq + 1) ÷ 2
            m = n ÷ 2
            m += m
            if m == n
                z == 0.0 && return 0.0
                aug = sgn * (ccos(z) / csin(z) * 4.0)
            else
                aug = sgn * (csin(z) / ccos(z) * 4.0)
            end
        end
        x = 1.0 - x
    end

    if x <= 3.0
        den = x
        upper = p1[1] * x
        for i in 1:5
            den = (den + q1[i]) * x
            upper = (upper + p1[i+1]) * x
        end
        den = (upper + p1[7]) / (den + q1[6])
        xmx0 = x - dx0
        return den * xmx0 + aug
    end

    if x < xmax1
        w = 1.0 / (x * x)
        den = w
        upper = p2[1] * w
        for i in 1:3
            den = (den + q2[i]) * w
            upper = (upper + p2[i+1]) * w
        end
        aug = upper / (den + q2[4]) - 0.5 / x + aug
    end
    return aug + clog(x)
end

function betaln(a0::Float64, b0::Float64)
    # Evaluation of the logarithm of the beta function ln(beta(a0,b0))
    e = 0.918938533204673
    a = _tmin(a0, b0)
    b = _tmax(a0, b0)
    if a < 8.0
        if a < 1.0
            if b < 8.0
                return gamln(a) + (gamln(b) - gamln(a + b))
            else
                return gamln(a) + algdiv(a, b)
            end
        end
        if a < 2.0
            b <= 2.0 && return gamln(a) + gamln(b) - gsumln(a, b)
            b < 8.0 && return _betaln_L40(a, b, 0.0)
            return gamln(a) + algdiv(a, b)
        end
        if b <= 1e3
            n = c_int(a - 1.0)
            w = 1.0
            for _ in 1:n
                a += -1.0
                h = a / b
                w *= h / (h + 1.0)
            end
            w = clog(w)
            b >= 8.0 && return w + gamln(a) + algdiv(a, b)
            return _betaln_L40(a, b, w)
        else
            n = c_int(a - 1.0)
            w = 1.0
            for _ in 1:n
                a += -1.0
                w *= a / (a / b + 1.0)
            end
            return clog(w) - n * clog(b) + (gamln(a) + algdiv(a, b))
        end
    else
        w = bcorr(a, b)
        h = a / b
        u = -(a - 0.5) * clog(h / (h + 1.0))
        v = b * alnrel(h)
        if u > v
            return clog(b) * -0.5 + e + w - v - u
        else
            return clog(b) * -0.5 + e + w - u - v
        end
    end
end

function _betaln_L40(a::Float64, b::Float64, w::Float64)
    # 1 < A <= B < 8 :  reduction of B
    n = c_int(b - 1.0)
    z = 1.0
    for _ in 1:n
        b += -1.0
        z *= b / (a + b)
    end
    return w + clog(z) + (gamln(a) + (gamln(b) - gsumln(a, b)))
end

function gsumln(a::Float64, b::Float64)
    # EVALUATION OF THE FUNCTION LN(GAMMA(A + B)) FOR 1 <= A <= 2  AND  1 <= B <= 2
    x = a + b - 2.0
    x <= 0.25 && return gamln1(x + 1.0)
    x <= 1.25 && return gamln1(x) + alnrel(x)
    return gamln1(x - 1.0) + clog(x * (x + 1.0))
end

const _C0 = 0.0833333333333333
const _C1 = -0.00277777777760991
const _C2 = 7.9365066682539e-4
const _C3 = -5.9520293135187e-4
const _C4 = 8.37308034031215e-4
const _C5 = -0.00165322962780713

function bcorr(a0::Float64, b0::Float64)
    # EVALUATION OF  DEL(A0) + DEL(B0) - DEL(A0 + B0)
    c0 = _C0; c1 = _C1; c2 = _C2; c3 = _C3; c4 = _C4; c5 = _C5
    a = _tmin(a0, b0)
    b = _tmax(a0, b0)
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
    w = ((((c5 * s11 * t + c4 * s9) * t + c3 * s7) * t + c2 * s5) * t + c1 * s3) * t + c0
    w *= c / b
    r1 = 1.0 / a
    t = r1 * r1
    return (((((c5 * t + c4) * t + c3) * t + c2) * t + c1) * t + c0) / a + w
end

function algdiv(a::Float64, b::Float64)
    # COMPUTATION OF LN(GAMMA(B)/GAMMA(A+B)) WHEN B >= 8
    c0 = _C0; c1 = _C1; c2 = _C2; c3 = _C3; c4 = _C4; c5 = _C5
    if a > b
        h = b / a
        c = 1.0 / (h + 1.0)
        x = h / (h + 1.0)
        d = a + (b - 0.5)
    else
        h = a / b
        c = h / (h + 1.0)
        x = 1.0 / (h + 1.0)
        d = b + (a - 0.5)
    end
    x2 = x * x
    s3 = x + x2 + 1.0
    s5 = x + x2 * s3 + 1.0
    s7 = x + x2 * s5 + 1.0
    s9 = x + x2 * s7 + 1.0
    s11 = x + x2 * s9 + 1.0
    t = 1.0 / (b * b)
    w = ((((c5 * s11 * t + c4 * s9) * t + c3 * s7) * t + c2 * s5) * t + c1 * s3) * t + c0
    w *= c / b
    u = d * alnrel(a / b)
    v = a * (clog(b) - 1.0)
    return u > v ? w - v - u : w - u - v
end

function gamln(a::Float64)
    # Evaluation of ln(gamma(a)) for positive a
    d = 0.418938533204673
    if a <= 0.8
        return gamln1(a) - clog(a)
    elseif a <= 2.25
        return gamln1(a - 0.5 - 0.5)
    elseif a < 10.0
        n = c_int(a - 1.25)
        t = a
        w = 1.0
        for _ in 1:n
            t += -1.0
            w *= t
        end
        return gamln1(t - 1.0) + clog(w)
    else
        t = 1.0 / (a * a)
        w = (((((_C5 * t + _C4) * t + _C3) * t + _C2) * t + _C1) * t + _C0) / a
        return d + w + (a - 0.5) * (clog(a) - 1.0)
    end
end
