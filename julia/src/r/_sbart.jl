# ─────────────────────────────────────────────────────────────────────────────
# Glättungsspline wie R's smooth.spline (sbart.c, sslvrg.f, sgram.f, stxwx.f,
# sinerp.f, bsplvd.f, bvalue.f, bvalus.f, LINPACK dpbfa/dpbsl, interv),
# bitgleich. Felder 1-basiert wie in Fortran (Länge wie in der Vorlage
# python/simlev/_r/_sbart.py, Index 0 dort ungenutzt), Matrizen spaltenweise flach.
# Eingebunden in RStats.
# ─────────────────────────────────────────────────────────────────────────────

const _BIG_f = 1e100
const _C_GOLD = 0.381966011250105151795413165634

"interv(xt, n, x, FALSE, FALSE, ilo, mflag); xt 1-basiert. Liefert (left, mflag)."
function interv(xt::AbstractVector{Float64}, n::Int, x::Float64)
    n == 0 && return 0, 0
    i = searchsortedlast(view(xt, 1:n), x; lt = <)
    i < 1 && return 0, -1
    i >= n && return n, 1
    return i, 0
end

"bsplvb mit gespeichertem Zustand (SAVE j, deltal, deltar)."
mutable struct _Bsplvb
    j::Int
    deltal::Vector{Float64}
    deltar::Vector{Float64}
end
_Bsplvb() = _Bsplvb(1, zeros(21), zeros(21))

# Der gespeicherte Zustand gilt nur innerhalb eines bsplvd-Aufrufs (index 1, dann 2);
# er liegt deshalb beim Aufrufer statt global (thread-sicher für RParallel).
function _bsplvb!(t, jhigh, index, x, left, biatx, S::_Bsplvb)
    if index != 2
        S.j = 1
        biatx[1] = 1.0
        S.j >= jhigh && return nothing
    end
    deltal = S.deltal
    deltar = S.deltar
    while true
        j = S.j
        jp1 = j + 1
        deltar[j] = t[left+j] - x
        deltal[j] = x - t[left+1-j]
        saved = 0.0
        for i in 1:j
            term = biatx[i] / (deltar[i] + deltal[jp1-i])
            biatx[i] = saved + deltar[i] * term
            saved = deltal[jp1-i] * term
        end
        biatx[jp1] = saved
        S.j = jp1
        S.j < jhigh || break
    end
    nothing
end

@inline _Dk(k, i, m) = (i - 1) + (m - 1) * k + 1

"bsplvd; liefert dbiatx (k×nderiv spaltenweise, 1-basiert; Element (i,m) = db[_Dk(k,i,m)])."
function bsplvd(t, k::Int, x::Float64, left::Int, nderiv::Int)
    mhigh = max(min(nderiv, k), 1)
    kp1 = k + 1
    db = zeros(k * max(nderiv, 1) + 1)
    col1 = zeros(k + 2)
    S = _Bsplvb()
    _bsplvb!(t, kp1 - mhigh, 1, x, left, col1, S)
    for i in 1:k
        db[i] = col1[i]
    end
    mhigh == 1 && return db
    ideriv = mhigh
    for m in 2:mhigh
        jp1mid = 1
        for j in ideriv:k
            db[_Dk(k, j, ideriv)] = col1[jp1mid]
            jp1mid += 1
        end
        ideriv -= 1
        _bsplvb!(t, kp1 - ideriv, 2, x, left, col1, S)
    end
    for i in 1:k
        db[_Dk(k, i, 1)] = col1[i]
    end
    a = zeros(k + 1, k + 1)          # a[j, i] = a(j, i)
    jlow = 1
    for i in 1:k
        for j in jlow:k
            a[j, i] = 0.0
        end
        jlow = i
        a[i, i] = 1.0
    end
    for m in 2:mhigh
        kp1mm = kp1 - m
        fkp1mm = Float64(kp1mm)
        il = left
        i = k
        for _ in 1:kp1mm
            factor = fkp1mm / (t[il+kp1mm] - t[il])
            for j in 1:i
                a[i, j] = (a[i, j] - a[i-1, j]) * factor
            end
            il -= 1
            i -= 1
        end
        for i in 1:k
            s = 0.0
            jlow = max(i, m)
            for j in jlow:k
                s = a[j, i] * db[_Dk(k, j, m)] + s
            end
            db[_Dk(k, i, m)] = s
        end
    end
    return db
end

"bvalue (t, bcoef 1-basiert)."
function bvalue(t, bcoef, n::Int, k::Int, x::Float64, jderiv::Int)
    jderiv >= k && return 0.0
    if (x != t[n+1]) || (t[n+1] != t[n+k])
        i, mflag = interv(t, n + k, x)
        if mflag != 0
            @warn "bvalue()  mflag != 0: should never happen!"
            return 0.0
        end
    else
        i = n
    end
    km1 = k - 1
    km1 <= 0 && return bcoef[i]
    aj = zeros(21); dm = zeros(21); dp = zeros(21)
    jcmin = 1
    imk = i - k
    if imk >= 0
        for j in 1:km1
            dm[j] = x - t[i+1-j]
        end
    else
        jcmin = 1 - imk
        for j in 1:i
            dm[j] = x - t[i+1-j]
        end
        for j in i:km1
            aj[k-j] = 0.0
            dm[j] = dm[i]
        end
    end
    jcmax = k
    nmi = n - i
    if nmi >= 0
        for j in 1:km1
            dp[j] = t[i+j] - x
        end
    else
        jcmax = k + nmi
        for j in 1:jcmax
            dp[j] = t[i+j] - x
        end
        for j in jcmax:km1
            aj[j+1] = 0.0
            dp[j] = dp[jcmax]
        end
    end
    for jc in jcmin:jcmax
        aj[jc] = bcoef[imk+jc]
    end
    if jderiv >= 1
        for j in 1:jderiv
            kmj = k - j
            fkmj = Float64(kmj)
            ilo = kmj
            for jj in 1:kmj
                aj[jj] = ((aj[jj+1] - aj[jj]) / (dm[ilo] + dp[jj])) * fkmj
                ilo -= 1
            end
        end
    end
    if jderiv != km1
        for j in jderiv+1:km1
            kmj = k - j
            ilo = kmj
            for jj in 1:kmj
                aj[jj] = (aj[jj+1] * dm[ilo] + aj[jj] * dp[jj]) / (dm[ilo] + dp[jj])
                ilo -= 1
            end
        end
    end
    return aj[1]
end

bvalus(knot, coef, nk::Int, xs, order::Int) = Float64[bvalue(knot, coef, nk, 4, x, order) for x in xs]

function _sb_ddot(n, x, xb, y, yb)
    s = 0.0
    for k in 0:n-1
        s = s + x[xb+k] * y[yb+k]
    end
    s
end

"LINPACK dpbfa; abd(i,j) = abd[(i-1)+(j-1)*lda+1]."
function _dpbfa!(abd, lda, n, m)
    A(i, j) = (i - 1) + (j - 1) * lda + 1
    for j in 1:n
        info = j
        s = 0.0
        ik = m + 1
        jk = max(j - m, 1)
        mu = max(m + 2 - j, 1)
        if m >= mu
            for k in mu:m
                t = abd[A(k, j)] - _sb_ddot(k - mu, abd, A(ik, jk), abd, A(mu, j))
                t = t / abd[A(m + 1, jk)]
                abd[A(k, j)] = t
                s = s + t * t
                ik -= 1
                jk += 1
            end
        end
        s = abd[A(m + 1, j)] - s
        s <= 0.0 && return info
        abd[A(m + 1, j)] = sqrt(s)
    end
    return 0
end

function _dpbsl!(abd, lda, n, m, b)
    A(i, j) = (i - 1) + (j - 1) * lda + 1
    for k in 1:n
        lm = min(k - 1, m)
        la = m + 1 - lm
        lb = k - lm
        t = _sb_ddot(lm, abd, A(la, k), b, lb)
        b[k] = (b[k] - t) / abd[A(m + 1, k)]
    end
    for kb in 1:n
        k = n + 1 - kb
        lm = min(k - 1, m)
        la = m + 1 - lm
        lb = k - lm
        b[k] = b[k] / abd[A(m + 1, k)]
        t = -b[k]
        if lm > 0 && t != 0.0
            base = A(la, k)
            for q in 0:lm-1
                b[lb+q] = b[lb+q] + t * abd[base+q]
            end
        end
    end
    nothing
end

function sgram(tb, nb::Int)
    sg0 = zeros(nb + 1); sg1 = zeros(nb + 1); sg2 = zeros(nb + 1); sg3 = zeros(nb + 1)
    yw1 = zeros(5); yw2 = zeros(5)
    for i in 1:nb
        ileft, mflag = interv(tb, nb + 1, tb[i])
        db = bsplvd(tb, 4, tb[i], ileft, 3)
        for ii in 1:4
            yw1[ii] = db[_Dk(4, ii, 3)]
        end
        db = bsplvd(tb, 4, tb[i+1], ileft, 3)
        for ii in 1:4
            yw2[ii] = db[_Dk(4, ii, 3)] - yw1[ii]
        end
        wpt = tb[i+1] - tb[i]
        term(ii, jj) = wpt * ((yw1[ii] * yw1[jj] + (yw2[ii] * yw1[jj] + yw2[jj] * yw1[ii]) * 0.5) +
                              yw2[ii] * yw2[jj] * 0.3330)
        if ileft >= 4
            for ii in 1:4
                jj = ii
                sg0[ileft-4+ii] = sg0[ileft-4+ii] + term(ii, jj)
                jj = ii + 1
                jj <= 4 && (sg1[ileft+ii-4] = sg1[ileft+ii-4] + term(ii, jj))
                jj = ii + 2
                jj <= 4 && (sg2[ileft+ii-4] = sg2[ileft+ii-4] + term(ii, jj))
                jj = ii + 3
                jj <= 4 && (sg3[ileft+ii-4] = sg3[ileft+ii-4] + term(ii, jj))
            end
        elseif ileft == 3
            for ii in 1:3
                jj = ii
                sg0[ileft-3+ii] = sg0[ileft-3+ii] + term(ii, jj)
                jj = ii + 1
                jj <= 3 && (sg1[ileft+ii-3] = sg1[ileft+ii-3] + term(ii, jj))
                jj = ii + 2
                jj <= 3 && (sg2[ileft+ii-3] = sg2[ileft+ii-3] + term(ii, jj))
            end
        elseif ileft == 2
            for ii in 1:2
                jj = ii
                sg0[ileft-2+ii] = sg0[ileft-2+ii] + term(ii, jj)
                jj = ii + 1
                jj <= 2 && (sg1[ileft+ii-2] = sg1[ileft+ii-2] + term(ii, jj))
            end
        elseif ileft == 1
            ii = 1
            jj = ii
            sg0[ileft-1+ii] = sg0[ileft-1+ii] + term(ii, jj)
        end
    end
    return sg0, sg1, sg2, sg3
end

function stxwx(x, z, w, k::Int, xknot, n::Int)
    y = zeros(n + 1); hs0 = zeros(n + 1); hs1 = zeros(n + 1); hs2 = zeros(n + 1); hs3 = zeros(n + 1)
    eps = 0.1e-9
    for i in 1:k
        ileft, mflag = interv(xknot, n + 1, x[i])
        if mflag == 1
            if x[i] <= (xknot[ileft] + eps)
                ileft -= 1
            else
                return y, hs0, hs1, hs2, hs3
            end
        end
        db = bsplvd(xknot, 4, x[i], ileft, 1)
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
    end
    return y, hs0, hs1, hs2, hs3
end

function sinerp!(abd, ld4, nk, p1ip)
    A(i, j) = (i - 1) + (j - 1) * ld4 + 1
    c1 = c2 = c3 = 0.0
    wjm3 = zeros(4); wjm2 = zeros(3); wjm1 = zeros(2)
    for i in 1:nk
        j = nk - i + 1
        c0 = 1.0 / abd[A(4, j)]
        if j <= nk - 3
            c1 = abd[A(1, j + 3)] * c0
            c2 = abd[A(2, j + 2)] * c0
            c3 = abd[A(3, j + 1)] * c0
        elseif j == nk - 2
            c1 = 0.0
            c2 = abd[A(2, j + 2)] * c0
            c3 = abd[A(3, j + 1)] * c0
        elseif j == nk - 1
            c1 = 0.0
            c2 = 0.0
            c3 = abd[A(3, j + 1)] * c0
        elseif j == nk
            c1 = 0.0
            c2 = 0.0
            c3 = 0.0
        end
        p1ip[A(1, j)] = 0.0 - ((c1 * wjm3[1] + c2 * wjm3[2]) + c3 * wjm3[3])
        p1ip[A(2, j)] = 0.0 - ((c1 * wjm3[2] + c2 * wjm2[1]) + c3 * wjm2[2])
        p1ip[A(3, j)] = 0.0 - ((c1 * wjm3[3] + c2 * wjm2[2]) + c3 * wjm1[1])
        p1ip[A(4, j)] = ((((((c0 * c0 + (c1 * c1) * wjm3[1]) + ((2.0 * c1) * c2) * wjm3[2]) +
                            ((2.0 * c1) * c3) * wjm3[3]) + (c2 * c2) * wjm2[1]) +
                          ((2.0 * c2) * c3) * wjm2[2]) + (c3 * c3) * wjm1[1])
        wjm3[1] = wjm2[1]
        wjm3[2] = wjm2[2]
        wjm3[3] = p1ip[A(2, j)]
        wjm2[1] = wjm1[1]
        wjm2[2] = p1ip[A(3, j)]
        wjm1[1] = p1ip[A(4, j)]
    end
    nothing
end

"sslvrg; liefert (crit, info)."
function sslvrg!(penalt, dofoff, x, y, w, ssw, n, knot, nk, coef, sz, lev, icrit, lam,
                 xwy, hs0, hs1, hs2, hs3, sg0, sg1, sg2, sg3, abd, p1ip, ld4)
    A(i, j) = (i - 1) + (j - 1) * ld4 + 1
    eps = 1e-11
    crit = 0.0
    for i in 1:nk
        coef[i] = xwy[i]
        abd[A(4, i)] = hs0[i] + lam * sg0[i]
    end
    for i in 1:nk-1
        abd[A(3, i + 1)] = hs1[i] + lam * sg1[i]
    end
    for i in 1:nk-2
        abd[A(2, i + 2)] = hs2[i] + lam * sg2[i]
    end
    for i in 1:nk-3
        abd[A(1, i + 3)] = hs3[i] + lam * sg3[i]
    end
    info = _dpbfa!(abd, ld4, nk, 3)
    info != 0 && return crit, info
    _dpbsl!(abd, ld4, nk, 3, coef)
    for i in 1:n
        sz[i] = bvalue(knot, coef, nk, 4, x[i], 0)
    end
    if icrit >= 1
        sinerp!(abd, ld4, nk, p1ip)
        for i in 1:n
            xv = x[i]
            ileft, mflag = interv(knot, nk + 1, xv)
            if mflag == -1
                ileft = 4
                xv = knot[4] + eps
            elseif mflag == 1
                ileft = nk
                xv = knot[nk+1] - eps
            end
            j = ileft - 3
            db = bsplvd(knot, 4, xv, ileft, 1)
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
        end
        df = 0.0
        if icrit == 1
            rss = ssw
            sumw = 0.0
            for i in 1:n
                q = (y[i] - sz[i]) * w[i]
                rss = rss + q * q
                df = df + lev[i]
                sumw = sumw + w[i] * w[i]
            end
            t = 1.0 - (dofoff + penalt * df) / sumw
            crit = (rss / sumw) / (t * t)
        elseif icrit == 2
            crit = 0.0
            for i in 1:n
                q = ((y[i] - sz[i]) * w[i]) / (1 - lev[i])
                crit = crit + q * q
            end
            crit = crit / n
        else
            for i in 1:n
                df = df + lev[i]
            end
            if icrit == 3
                d = dofoff - df
                crit = 3 + d * d
            else
                crit = df - dofoff
            end
        end
    end
    return crit, 0
end

function _fsign(x, y)
    (isnan(x) || isnan(y)) && return x + y
    return y >= 0 ? abs(x) : -abs(x)
end

"""sbart (Eingabefelder 1-basiert mit Platzhalter an Stelle 1 entfällt: Index i
wie in Fortran). Liefert NamedTuple mit coef, sz, lev, crit, spar, lspar, ratio,
iter, ier, ws."""
function sbart(penalt, dofoff, xs, ys, ws0, ssw, n, knot, nk, icrit, spar, ispar, iter_,
               lspar, uspar, tol, eps, isetup)
    ld4 = 4
    coef = zeros(nk + 1)
    sz = zeros(n + 1)
    lev = zeros(n + 1)
    abd = zeros(ld4 * nk + 1)
    p1ip = zeros(ld4 * nk + 1)
    ws = collect(Float64, ws0)
    tracing = ispar < 0
    spar_is_lambda = false
    ratio = 1.0
    for i in 1:n
        ws[i] > 0.0 && (ws[i] = sqrt(ws[i]))
    end
    if isetup < 0
        spar_is_lambda = true
        error("sbart: isetup < 0 nicht portiert")
    end
    sg = sgram(knot, nk)
    st = stxwx(xs, ys, ws, n, knot, nk)
    spar_is_lambda = isetup == 2
    if !spar_is_lambda
        t1 = 0.0
        t2 = 0.0
        for i in 3:nk-3
            t1 += st[2][i]
            t2 += sg[1][i]
        end
        ratio = t1 / t2
    end
    sg0, sg1, sg2, sg3 = sg
    xwy, hs0, hs1, hs2, hs3 = st
    ier = 0
    critv = 0.0
    lsp = lspar
    function comp(sp)
        lam = spar_is_lambda ? sp : ratio * SimLev.r_pow(16.0, sp * 6.0 - 2.0)
        lsp = lam
        crit, info = sslvrg!(penalt, dofoff, xs, ys, ws, ssw, n, knot, nk, coef, sz, lev, icrit, lam,
                             xwy, hs0, hs1, hs2, hs3, sg0, sg1, sg2, sg3, abd, p1ip, ld4)
        if info != 0
            ier = info
        else
            critv = crit
        end
        return crit
    end
    if ispar == 1
        comp(spar)
        return (coef = coef, sz = sz, lev = lev, crit = critv, spar = spar, lspar = lsp, ratio = ratio,
                iter = iter_, ier = ier, ws = ws)
    end
    CRIT(fx) = icrit == 3 ? fx - 3.0 : fx
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
    fx = critv
    fv = fx
    fw = fx
    while ier == 0
        xm = (a + b) * 0.5
        tol1 = eps * abs(x) + tol / 3.0
        tol2 = tol1 * 2.0
        it += 1
        Fparabol = false
        if tracing
            if it == 1
                cr = get(Dict(1 => "GCV", 2 => "CV", 3 => "(df0-df)^2"), icrit, "?f?")
                _cprint("sbart (ratio = %15.8g) iterations; initial tol1 = %12.6e :\n%11s %14s  %9s %11s  Kind %11s %12s\n%s\n",
                        ratio, tol1, "spar", cr, "b - a", "e", "NEW lspar", "crit",
                        " -------------------------------------------------------------------------------")
            end
            _cprint("%11.8f %14.9g %9.4e %11.5g", x, CRIT(fx), b - a, e)
        end
        (abs(x - xm) <= tol2 - (b - a) * 0.5 || it > maxit) && break
        golden = false
        if abs(e) <= tol1 || fx >= _BIG_f || fv >= _BIG_f || fw >= _BIG_f
            golden = true
        else
            if tracing
                _cprint(" FP")
                Fparabol = true
            end
            r = (x - w) * (fx - fv)
            q = (x - v) * (fx - fw)
            p = (x - v) * q - (x - w) * r
            q = (q - r) * 2.0
            q > 0.0 && (p = -p)
            q = abs(q)
            r = e
            e = d
            if abs(p) >= abs(0.5 * q * r) || q == 0.0
                golden = true
            elseif p <= q * (a - x) || p >= q * (b - x)
                golden = true
            else
                tracing && _cprint(" PI ")
                d = p / q
                u = x + d
                (u - a < tol2 || b - u < tol2) && (d = _fsign(tol1, xm - x))
            end
        end
        if golden
            tracing && _cprint(" GS%s ", Fparabol ? "" : " --")
            e = x >= xm ? a - x : b - x
            d = _C_GOLD * e
        end
        u = x + (abs(d) >= tol1 ? d : _fsign(tol1, d))
        comp(u)
        fu = critv
        tracing && _cprint("%11g %12g\n", lsp, CRIT(fu))
        if !isfinite(fu)
            print(SimLev.RParallel.r_stderr(), SimLev.r_sprintf("spar-finding: non-finite value %g; using BIG value\n", fu))
            fu = 2.0 * _BIG_f
        end
        if fu <= fx
            if u >= x
                a = x
            else
                b = x
            end
            v = w; fv = fw
            w = x; fw = fx
            x = u; fx = fu
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
    tracing && _cprint("  >>> %12g %12g\n", lsp, CRIT(fx))
    return (coef = coef, sz = sz, lev = lev, crit = fx, spar = x, lspar = lsp, ratio = ratio,
            iter = it, ier = ier, ws = ws)
end
