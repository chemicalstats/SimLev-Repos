# ─────────────────────────────────────────────────────────────────────────────
# Eindimensionale Verfahren aus R's src/library/stats/src/optimize.c / zeroin.c (Brent_fmin,
# R_zeroin2) für optimize/uniroot, bitgleich (skalare double-Arithmetik). Vorlage:
# python/simlev/_r/_optim.py. Eingebunden in RStats. Die mehrdimensionalen Optimierer aus
# src/appl/optim.c (nmmin, vmmin, cgmin) sind mit Etappe 9.6c entfallen (eigene Optimierer in slc).
# ─────────────────────────────────────────────────────────────────────────────


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
