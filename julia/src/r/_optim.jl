# ─────────────────────────────────────────────────────────────────────────────
# Optimierer aus R's src/appl/optim.c (nmmin, vmmin, cgmin) und
# src/library/stats/src/optimize.c / zeroin.c (Brent_fmin, R_zeroin2),
# bitgleich (skalare double-Arithmetik). Vorlage: python/simlev/_r/_optim.py.
# Eingebunden in RStats.
# ─────────────────────────────────────────────────────────────────────────────

const _BIG = 1.0e35
const _STEPREDN = 0.2
const _ACCTOL = 0.0001
const _RELTEST = 10.0

_cprint(fmt::String, args...) = print(SimLev.r_sprintf(fmt, args...))

"Nelder-Mead; liefert (X, Fmin, fail, fncount)."
function nmmin(n::Int, Bvec0::AbstractVector{Float64}, fminfn, abstol::Float64, intol::Float64,
               alpha::Float64, bet::Float64, gamm::Float64, trace::Int, maxit::Int)
    Bvec = collect(Float64, Bvec0)
    maxit <= 0 && return copy(Bvec), fminfn(Bvec), 0, 0
    trace != 0 && _cprint("  Nelder-Mead direct search function minimizer\n")
    n1 = n + 1
    C = n + 2
    P = zeros(n + 1, n + 2)
    fail = 0
    f = fminfn(Bvec)
    isfinite(f) || error("function cannot be evaluated at initial parameters")
    trace != 0 && _cprint("function value for initial parameters = %f\n", f)
    funcount = 1
    convtol = intol * (abs(f) + intol)
    trace != 0 && _cprint("  Scaled convergence tolerance is %g\n", convtol)
    P[n1, 1] = f
    for i in 1:n
        P[i, 1] = Bvec[i]
    end
    L = 1
    size = 0.0
    step = 0.0
    for i in 1:n
        0.1 * abs(Bvec[i]) > step && (step = 0.1 * abs(Bvec[i]))
    end
    step == 0.0 && (step = 0.1)
    trace != 0 && _cprint("Stepsize computed as %f\n", step)
    action = "BUILD          "
    for j in 2:n1
        action = "BUILD          "
        for i in 1:n
            P[i, j] = Bvec[i]
        end
        trystep = step
        while P[j-1, j] == Bvec[j-1]
            P[j-1, j] = Bvec[j-1] + trystep
            trystep *= 10
        end
        size += trystep
    end
    oldsize = size
    calcvert = true
    while true
        if calcvert
            for j in 1:n1
                if j != L
                    for i in 1:n
                        Bvec[i] = P[i, j]
                    end
                    f = fminfn(Bvec)
                    isfinite(f) || (f = _BIG)
                    funcount += 1
                    P[n1, j] = f
                end
            end
            calcvert = false
        end
        VL = P[n1, L]
        VH = VL
        H = L
        for j in 1:n1
            if j != L
                f = P[n1, j]
                if f < VL
                    L = j
                    VL = f
                end
                if f > VH
                    H = j
                    VH = f
                end
            end
        end
        (VH <= VL + convtol || VL <= abstol) && break
        trace != 0 && _cprint("%s%5d %f %f\n", action, funcount, VH, VL)
        for i in 1:n
            temp = -P[i, H]
            for j in 1:n1
                temp += P[i, j]
            end
            P[i, C] = temp / n
        end
        for i in 1:n
            Bvec[i] = (1.0 + alpha) * P[i, C] - alpha * P[i, H]
        end
        f = fminfn(Bvec)
        isfinite(f) || (f = _BIG)
        funcount += 1
        action = "REFLECTION     "
        VR = f
        if VR < VL
            P[n1, C] = f
            for i in 1:n
                f = gamm * Bvec[i] + (1 - gamm) * P[i, C]
                P[i, C] = Bvec[i]
                Bvec[i] = f
            end
            f = fminfn(Bvec)
            isfinite(f) || (f = _BIG)
            funcount += 1
            if f < VR
                for i in 1:n
                    P[i, H] = Bvec[i]
                end
                P[n1, H] = f
                action = "EXTENSION      "
            else
                for i in 1:n
                    P[i, H] = P[i, C]
                end
                P[n1, H] = VR
            end
        else
            action = "HI-REDUCTION   "
            if VR < VH
                for i in 1:n
                    P[i, H] = Bvec[i]
                end
                P[n1, H] = VR
                action = "LO-REDUCTION   "
            end
            for i in 1:n
                Bvec[i] = (1 - bet) * P[i, H] + bet * P[i, C]
            end
            f = fminfn(Bvec)
            isfinite(f) || (f = _BIG)
            funcount += 1
            if f < P[n1, H]
                for i in 1:n
                    P[i, H] = Bvec[i]
                end
                P[n1, H] = f
            else
                if VR >= VH
                    action = "SHRINK         "
                    calcvert = true
                    size = 0.0
                    for j in 1:n1
                        if j != L
                            for i in 1:n
                                P[i, j] = bet * (P[i, j] - P[i, L]) + P[i, L]
                                size += abs(P[i, j] - P[i, L])
                            end
                        end
                    end
                    if size < oldsize
                        oldsize = size
                    else
                        trace != 0 && _cprint("Polytope size measure not decreased in shrink\n")
                        fail = 10
                        break
                    end
                end
            end
        end
        funcount <= maxit || break
    end
    if trace != 0
        _cprint("Exiting from Nelder Mead minimizer\n")
        _cprint("    %d function evaluations used\n", funcount)
    end
    Fmin = P[n1, L]
    X = Float64[P[i, L] for i in 1:n]
    funcount > maxit && (fail = 1)
    return X, Fmin, fail, funcount
end

"BFGS (variable metric); liefert (b, Fmin, fncount, grcount, fail)."
function vmmin(n0::Int, b0::AbstractVector{Float64}, fminfn, fmingr, maxit::Int, trace::Int,
               mask::AbstractVector{Bool}, abstol::Float64, reltol::Float64, nREPORT::Int)
    b = collect(Float64, b0)
    maxit <= 0 && return b, fminfn(b), 0, 0, 0
    nREPORT <= 0 && error("REPORT must be > 0 (method = \"BFGS\")")
    l = [i for i in 1:n0 if mask[i]]
    n = length(l)
    t = zeros(n); X = zeros(n); c = zeros(n)
    B = zeros(n, n)          # unteres Dreieck B[i, j], j <= i
    f = fminfn(b)
    isfinite(f) || error("initial value in 'vmmin' is not finite")
    trace != 0 && _cprint("initial  value %f \n", f)
    Fmin = f
    funcount = gradcount = 1
    g = collect(Float64, fmingr(b))
    iter = 1
    ilast = gradcount
    count = 0
    while true
        if ilast == gradcount
            for i in 1:n
                for j in 1:i-1
                    B[i, j] = 0.0
                end
                B[i, i] = 1.0
            end
        end
        for i in 1:n
            X[i] = b[l[i]]
            c[i] = g[l[i]]
        end
        gradproj = 0.0
        for i in 1:n
            s = 0.0
            for j in 1:i
                s -= B[i, j] * g[l[j]]
            end
            for j in i+1:n
                s -= B[j, i] * g[l[j]]
            end
            t[i] = s
            gradproj += s * g[l[i]]
        end
        if gradproj < 0.0
            steplength = 1.0
            accpoint = false
            while true
                count = 0
                for i in 1:n
                    b[l[i]] = X[i] + steplength * t[i]
                    _RELTEST + X[i] == _RELTEST + b[l[i]] && (count += 1)
                end
                if count < n
                    f = fminfn(b)
                    funcount += 1
                    accpoint = isfinite(f) && (f <= Fmin + gradproj * steplength * _ACCTOL)
                    accpoint || (steplength *= _STEPREDN)
                end
                (count == n || accpoint) && break
            end
            enough = (f > abstol) && abs(f - Fmin) > reltol * (abs(Fmin) + reltol)
            if !enough
                count = n
                Fmin = f
            end
            if count < n
                Fmin = f
                g = collect(Float64, fmingr(b))
                gradcount += 1
                iter += 1
                D1 = 0.0
                for i in 1:n
                    t[i] = steplength * t[i]
                    c[i] = g[l[i]] - c[i]
                    D1 += t[i] * c[i]
                end
                if D1 > 0
                    D2 = 0.0
                    for i in 1:n
                        s = 0.0
                        for j in 1:i
                            s += B[i, j] * c[j]
                        end
                        for j in i+1:n
                            s += B[j, i] * c[j]
                        end
                        X[i] = s
                        D2 += s * c[i]
                    end
                    D2 = 1.0 + D2 / D1
                    for i in 1:n
                        for j in 1:i
                            B[i, j] += (D2 * t[i] * t[j] - X[i] * t[j] - t[i] * X[j]) / D1
                        end
                    end
                else
                    ilast = gradcount
                end
            else
                if ilast < gradcount
                    count = 0
                    ilast = gradcount
                end
            end
        else
            count = 0
            if ilast == gradcount
                count = n
            else
                ilast = gradcount
            end
        end
        (trace != 0 && iter % nREPORT == 0) && _cprint("iter%4d value %f\n", iter, f)
        iter >= maxit && break
        gradcount - ilast > 2 * n && (ilast = gradcount)
        (count != n || ilast != gradcount) || break
    end
    if trace != 0
        _cprint("final  value %f \n", Fmin)
        iter < maxit ? _cprint("converged\n") : _cprint("stopped after %i iterations\n", iter)
    end
    fail = iter < maxit ? 0 : 1
    return b, Fmin, funcount, gradcount, fail
end

"Konjugierte Gradienten; liefert (X, Fmin, fail, fncount, grcount)."
function cgmin(n::Int, Bvec0::AbstractVector{Float64}, fminfn, fmingr, abstol::Float64, intol::Float64,
               type::Int, trace::Int, maxit::Int)
    Bvec = collect(Float64, Bvec0)
    maxit <= 0 && return copy(Bvec), fminfn(Bvec), 0, 0, 0
    if trace != 0
        _cprint("  Conjugate gradients function minimizer\n")
        if type == 1
            _cprint("Method: Fletcher Reeves\n")
        elseif type == 2
            _cprint("Method: Polak Ribiere\n")
        elseif type == 3
            _cprint("Method: Beale Sorenson\n")
        else
            error("unknown 'type' in \"CG\" method of 'optim'")
        end
    end
    c = zeros(n); g = zeros(n); t = zeros(n); X = zeros(n)
    setstep = 1.7
    fail = 0
    cyclimit = n
    tol = intol * n * sqrt(intol)
    trace != 0 && _cprint("tolerance used in gradient test=%g\n", tol)
    f = fminfn(Bvec)
    isfinite(f) || error("Function cannot be evaluated at initial parameters")
    Fmin = f
    funcount = 1
    gradcount = 0
    steplength = 1.0
    while true
        for i in 1:n
            t[i] = 0.0
            c[i] = 0.0
        end
        cycle = 0
        oldstep = 1.0
        count = 0
        G1 = 0.0
        while true
            cycle += 1
            if trace != 0
                _cprint("%d %d %f\n", gradcount, funcount, Fmin)
                _cprint("parameters ")
                for i in 1:n
                    _cprint("%10.5f ", Bvec[i])
                    (i ÷ 7 * 7 == i && i < n) && _cprint("\n")
                end
                _cprint("\n")
            end
            gradcount += 1
            gradcount > maxit && return X, Fmin, 1, funcount, gradcount
            g = collect(Float64, fmingr(Bvec))
            G1 = 0.0
            G2 = 0.0
            for i in 1:n
                X[i] = Bvec[i]
                if type == 1
                    G1 += g[i] * g[i]
                    G2 += c[i] * c[i]
                elseif type == 2
                    G1 += g[i] * (g[i] - c[i])
                    G2 += c[i] * c[i]
                elseif type == 3
                    G1 += g[i] * (g[i] - c[i])
                    G2 += t[i] * (g[i] - c[i])
                else
                    error("unknown type in \"CG\" method of 'optim'")
                end
                c[i] = g[i]
            end
            if G1 > tol
                G3 = G2 > 0.0 ? G1 / G2 : 1.0
                gradproj = 0.0
                for i in 1:n
                    t[i] = t[i] * G3 - g[i]
                    gradproj += t[i] * g[i]
                end
                steplength = oldstep
                accpoint = false
                while true
                    count = 0
                    for i in 1:n
                        Bvec[i] = X[i] + steplength * t[i]
                        _RELTEST + X[i] == _RELTEST + Bvec[i] && (count += 1)
                    end
                    if count < n
                        f = fminfn(Bvec)
                        funcount += 1
                        accpoint = isfinite(f) && f <= Fmin + gradproj * steplength * _ACCTOL
                        if !accpoint
                            steplength *= _STEPREDN
                            trace != 0 && _cprint("*")
                        else
                            Fmin = f
                        end
                    end
                    (count == n || accpoint) && break
                end
                if count < n
                    newstep = 2 * (f - Fmin - gradproj * steplength)
                    if newstep > 0
                        newstep = -(gradproj * steplength * steplength / newstep)
                        for i in 1:n
                            Bvec[i] = X[i] + newstep * t[i]
                        end
                        Fmin = f
                        f = fminfn(Bvec)
                        funcount += 1
                        if f < Fmin
                            Fmin = f
                            trace != 0 && _cprint(" i< ")
                        else
                            trace != 0 && _cprint(" i> ")
                            for i in 1:n
                                Bvec[i] = X[i] + steplength * t[i]
                            end
                        end
                    end
                end
            end
            oldstep = setstep * steplength
            oldstep > 1.0 && (oldstep = 1.0)
            ((count != n) && (G1 > tol) && (cycle != cyclimit)) || break
        end
        ((cycle != 1) || ((count != n) && (G1 > tol) && Fmin > abstol)) || break
    end
    if trace != 0
        _cprint("Exiting from conjugate gradients minimizer\n")
        _cprint("    %d function evaluations used\n", funcount)
        _cprint("    %d gradient evaluations used\n", gradcount)
    end
    return X, Fmin, fail, funcount, gradcount
end

"Brent_fmin aus optimize.c."
function brent_fmin(ax::Float64, bx::Float64, f, tol::Float64)
    c = (3.0 - sqrt(5.0)) * 0.5
    eps = _DBL_EPS
    tol1 = eps + 1.0
    eps = sqrt(eps)
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
    while true
        xm = (a + b) * 0.5
        tol1 = eps * abs(x) + tol3
        t2 = tol1 * 2.0
        abs(x - xm) <= t2 - (b - a) * 0.5 && break
        p = 0.0
        q = 0.0
        r = 0.0
        if abs(e) > tol1
            r = (x - w) * (fx - fv)
            q = (x - v) * (fx - fw)
            p = (x - v) * q - (x - w) * r
            q = (q - r) * 2.0
            if q > 0.0
                p = -p
            else
                q = -q
            end
            r = e
            e = d
        end
        if abs(p) >= abs(q * 0.5 * r) || p <= q * (a - x) || p >= q * (b - x)
            e = x < xm ? b - x : a - x
            d = c * e
        else
            d = p / q
            u = x + d
            if u - a < t2 || b - u < t2
                d = tol1
                x >= xm && (d = -d)
            end
        end
        if abs(d) >= tol1
            u = x + d
        elseif d > 0.0
            u = x + tol1
        else
            u = x - tol1
        end
        fu = f(u)
        if fu <= fx
            if u < x
                b = x
            else
                a = x
            end
            v = w; w = x; x = u
            fv = fw; fw = fx; fx = fu
        else
            if u < x
                a = u
            else
                b = u
            end
            if fu <= fw || w == x
                v = w; fv = fw
                w = u; fw = fu
            elseif fu <= fv || v == x || v == w
                v = u; fv = fu
            end
        end
    end
    return x
end

"R_zeroin2; liefert (root, iter, estim_prec)."
function zeroin2(ax::Float64, bx::Float64, fa::Float64, fb::Float64, f, tol::Float64, maxit_in::Int)
    EPSILON = _DBL_EPS
    a = ax
    b = bx
    c = a
    fc = fa
    maxit = maxit_in + 1
    Maxit = maxit_in
    fa == 0.0 && return a, 0, 0.0
    fb == 0.0 && return b, 0, 0.0
    while maxit != 0
        maxit -= 1
        prev_step = b - a
        if abs(fc) < abs(fb)
            a = b; b = c; c = a
            fa = fb; fb = fc; fc = fa
        end
        tol_act = 2 * EPSILON * abs(b) + tol / 2
        new_step = (c - b) / 2
        if abs(new_step) <= tol_act || fb == 0.0
            Maxit -= maxit
            return b, Maxit, abs(c - b)
        end
        if abs(prev_step) >= tol_act && abs(fa) > abs(fb)
            cb = c - b
            if a == c
                t1 = fb / fa
                p = cb * t1
                q = 1.0 - t1
            else
                q = fa / fc
                t1 = fb / fc
                t2 = fb / fa
                p = t2 * (cb * q * (q - t1) - (b - a) * (t1 - 1.0))
                q = (q - 1.0) * (t1 - 1.0) * (t2 - 1.0)
            end
            if p > 0.0
                q = -q
            else
                p = -p
            end
            if p < (0.75 * cb * q - abs(tol_act * q) / 2) && p < abs(prev_step * q / 2)
                new_step = p / q
            end
        end
        if abs(new_step) < tol_act
            new_step = new_step > 0.0 ? tol_act : -tol_act
        end
        a = b
        fa = fb
        b += new_step
        fb = f(b)
        if (fb > 0 && fc > 0) || (fb < 0 && fc < 0)
            c = a
            fc = fa
        end
    end
    return b, -1, abs(c - b)
end
