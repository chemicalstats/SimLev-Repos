# ─────────────────────────────────────────────────────────────────────────────
# L-BFGS-B wie in R (src/appl/lbfgsb.c, Version 2.3 von Zhu/Byrd/Lu/Nocedal in
# R's C-Fassung), bitgleich. Indizes wie in der C-Quelle (1-basiert, Matrizen
# spaltenweise flach). BLAS (ddot, daxpy, dscal, dcopy) und LINPACK (dpofa in
# R's Fassung, dtrsl) als skalare Schleifen. Vorlage: python/simlev/_r/_lbfgsb.py.
# Öffentlich: `lbfgsb` (Signatur wie R's C-Funktion lbfgsb aus optim.c).
# Eingebunden in RStats.
# ─────────────────────────────────────────────────────────────────────────────

function _lb_ddot(n, x, xb, y, yb)
    s = 0.0
    @inbounds for k in 0:n-1
        s = s + x[xb+k] * y[yb+k]
    end
    s
end

function _lb_daxpy(n, a, x, xb, y, yb)
    (n <= 0 || a == 0.0) && return nothing
    @inbounds for k in 0:n-1
        y[yb+k] = y[yb+k] + a * x[xb+k]
    end
    nothing
end

function _lb_dcopy(n, x, xb, y, yb)
    @inbounds for k in 0:n-1
        y[yb+k] = x[xb+k]
    end
    nothing
end

function _lb_dscal(n, a, x, xb)
    @inbounds for k in 0:n-1
        x[xb+k] = a * x[xb+k]
    end
    nothing
end

"R's dpofa (mit eps-Test); Element (i,j) = a[base+(i-1)+(j-1)*lda]."
function _lb_dpofa(a, base, lda, n)
    eps = 1e-14
    for j in 1:n
        info = j
        s = 0.0
        cj = base + (j - 1) * lda
        for k in 1:j-1
            ck = base + (k - 1) * lda
            t = a[cj+k-1] - _lb_ddot(k - 1, a, ck, a, cj)
            t = t / a[ck+k-1]
            a[cj+k-1] = t
            s = s + t * t
        end
        ajj = a[cj+j-1]
        s = ajj - s
        s <= eps * abs(ajj) && return info
        a[cj+j-1] = sqrt(s)
    end
    return 0
end

"LINPACK dtrsl; T(i,j) = t[base+(i-1)+(j-1)*ldt], b(k) = b[bb+k-1]."
function _lb_dtrsl(t, base, ldt, n, b, bb, job)
    T(i, j) = t[base+(i-1)+(j-1)*ldt]
    for info in 1:n
        T(info, info) == 0.0 && return info
    end
    kase = 1
    job % 10 != 0 && (kase = 2)
    (job % 100) ÷ 10 != 0 && (kase += 2)
    if kase == 1
        b[bb] = b[bb] / T(1, 1)
        for j in 2:n
            temp = -b[bb+j-2]
            _lb_daxpy(n - j + 1, temp, t, base + (j - 1) + (j - 2) * ldt, b, bb + j - 1)
            b[bb+j-1] = b[bb+j-1] / T(j, j)
        end
    elseif kase == 2
        b[bb+n-1] = b[bb+n-1] / T(n, n)
        for jj in 2:n
            j = n - jj + 1
            temp = -b[bb+j]
            _lb_daxpy(j, temp, t, base + j * ldt, b, bb)
            b[bb+j-1] = b[bb+j-1] / T(j, j)
        end
    elseif kase == 3
        b[bb+n-1] = b[bb+n-1] / T(n, n)
        for jj in 2:n
            j = n - jj + 1
            b[bb+j-1] = b[bb+j-1] - _lb_ddot(jj - 1, t, base + j + (j - 1) * ldt, b, bb + j)
            b[bb+j-1] = b[bb+j-1] / T(j, j)
        end
    else
        b[bb] = b[bb] / T(1, 1)
        for j in 2:n
            b[bb+j-1] = b[bb+j-1] - _lb_ddot(j - 1, t, base + (j - 1) * ldt, b, bb)
            b[bb+j-1] = b[bb+j-1] / T(j, j)
        end
    end
    return 0
end

@inline _cmax(a, b) = a < b ? b : a     # C-Makro max(a, b)
@inline _cmin(a, b) = a > b ? b : a     # C-Makro min(a, b)

mutable struct _LBFGSB
    n::Int; m::Int
    ws::Vector{Float64}; wy::Vector{Float64}; sy::Vector{Float64}; ss::Vector{Float64}
    wt::Vector{Float64}; wn::Vector{Float64}; snd::Vector{Float64}
    z::Vector{Float64}; r::Vector{Float64}; d::Vector{Float64}; t::Vector{Float64}; wa::Vector{Float64}
    indx::Vector{Int}; iwhere::Vector{Int}; indx2::Vector{Int}
    csave::String
    epsmch::Float64; fold::Float64; dnorm::Float64; gd::Float64; sbgnrm::Float64; stp::Float64
    xstep::Float64; stpmx::Float64; gdold::Float64; dtd::Float64; theta::Float64; tol::Float64
    col::Int; head::Int; iupdat::Int; iback::Int; itail::Int; ifun::Int; iword::Int; nact::Int
    ileave::Int; nenter::Int; iter::Int; nfgv::Int; nint::Int; nintol::Int; nskip::Int; nfree::Int
    info::Int; k::Int
    updatd::Bool; wrk::Bool; prjctd::Bool; cnstnd::Bool; boxed::Bool
    word::String
    # statische Variablen von dcsrch
    ls_brackt::Bool; ls_stage::Int
    ls_finit::Float64; ls_ginit::Float64; ls_gtest::Float64; ls_width::Float64; ls_width1::Float64
    ls_stx::Float64; ls_fx::Float64; ls_gx::Float64; ls_sty::Float64; ls_fy::Float64; ls_gy::Float64
    ls_stmin::Float64; ls_stmax::Float64
    function _LBFGSB(n::Int, m::Int)
        S = new(n, m, zeros(n * m + 1), zeros(n * m + 1), zeros(m * m + 1), zeros(m * m + 1),
                zeros(m * m + 1), zeros(4 * m * m + 1), zeros(4 * m * m + 1),
                zeros(n + 1), zeros(n + 1), zeros(n + 1), zeros(n + 1), zeros(8 * m + 1),
                zeros(Int, n + 1), zeros(Int, n + 1), zeros(Int, n + 1), "")
        S.epsmch = S.fold = S.dnorm = S.gd = S.sbgnrm = S.stp = S.xstep = S.stpmx = S.gdold = S.dtd = 0.0
        S.theta = 1.0; S.tol = 0.0
        S.col = 0; S.head = 1; S.iupdat = 0; S.iback = 0; S.itail = 0; S.ifun = 0; S.iword = 0; S.nact = 0
        S.ileave = 0; S.nenter = 0; S.iter = 0; S.nfgv = 0; S.nint = 0; S.nintol = 0; S.nskip = 0; S.nfree = n
        S.info = 0; S.k = 0
        S.updatd = false; S.wrk = false; S.prjctd = false; S.cnstnd = false; S.boxed = false
        S.word = "---"
        S.ls_brackt = false; S.ls_stage = 0
        S.ls_finit = S.ls_ginit = S.ls_gtest = S.ls_width = S.ls_width1 = 0.0
        S.ls_stx = S.ls_fx = S.ls_gx = S.ls_sty = S.ls_fy = S.ls_gy = S.ls_stmin = S.ls_stmax = 0.0
        S
    end
end

@inline _Wn(S::_LBFGSB, i, j) = i + (j - 1) * S.n
@inline _Mm(S::_LBFGSB, i, j) = i + (j - 1) * S.m
@inline _M2(S::_LBFGSB, i, j) = i + (j - 1) * 2 * S.m

"Eine Etappe von mainlb; liefert (task, f)."
function _lb_mainlb!(S::_LBFGSB, x, l, u, nbd, f, g, factr, pgtol, task, iprint, isave)
    n, m = S.n, S.m
    if startswith(task, "START")
        S.epsmch = _DBL_EPS
        S.fold = 0.0; S.dnorm = 0.0; S.gd = 0.0; S.sbgnrm = 0.0; S.stp = 0.0; S.xstep = 0.0
        S.stpmx = 0.0; S.gdold = 0.0; S.dtd = 0.0
        S.col = 0; S.head = 1; S.theta = 1.0; S.iupdat = 0; S.updatd = false; S.iback = 0; S.itail = 0
        S.ifun = 0; S.iword = 0; S.nact = 0; S.ileave = 0; S.nenter = 0; S.iter = 0; S.nfgv = 0
        S.nint = 0; S.nintol = 0; S.nskip = 0; S.nfree = n
        S.tol = factr * S.epsmch
        S.word = "---"
        S.info = 0; S.k = 0
        task = _lb_errclb!(S, n, m, factr, l, u, nbd, task)
        if startswith(task, "ERROR")
            _lb_prn3lb(S, x, f, task, iprint)
            return task, f
        end
        _lb_prn1lb(S, l, u, x, iprint)
        _lb_active!(S, l, u, nbd, x, iprint)
        task = "FG_START"
        return _lb_finish(S, x, f, task, iprint, isave)
    else
        startswith(task, "FG_LN") && return _lb_L666!(S, x, l, u, nbd, f, g, task, iprint, isave)
        startswith(task, "NEW_X") && return _lb_L777!(S, x, l, u, nbd, f, g, pgtol, task, iprint, isave)
        startswith(task, "FG_ST") && return _lb_L111!(S, x, l, u, nbd, f, g, pgtol, task, iprint, isave)
        if startswith(task, "STOP")
            if length(task) >= 9 && task[7:9] == "CPU"
                _lb_dcopy(n, S.t, 1, x, 1)
                _lb_dcopy(n, S.r, 1, g, 1)
                f = S.fold
            end
            return _lb_finish(S, x, f, task, iprint, isave)
        end
        task = "FG_START"
        return _lb_finish(S, x, f, task, iprint, isave)
    end
end

function _lb_finish(S, x, f, task, iprint, isave)
    isave[13] = S.nfgv          # isave[12] in C (0-basiert)
    _lb_prn3lb(S, x, f, task, iprint)
    return task, f
end

function _lb_reset!(S)
    S.info = 0; S.col = 0; S.head = 1; S.theta = 1.0; S.iupdat = 0; S.updatd = false
end

function _lb_L111!(S, x, l, u, nbd, f, g, pgtol, task, iprint, isave)
    S.nfgv = 1
    S.sbgnrm = _lb_projgr(S, l, u, nbd, x, g)
    iprint >= 1 && _cprint("At iterate %5d  f= %12.5g  |proj g|= %12.5g\n", S.iter, f, S.sbgnrm)
    if S.sbgnrm <= pgtol
        task = "CONVERGENCE: NORM OF PROJECTED GRADIENT <= PGTOL"
        return _lb_finish(S, x, f, task, iprint, isave)
    end
    return _lb_L222!(S, x, l, u, nbd, f, g, task, iprint, isave)
end

function _lb_L222!(S, x, l, u, nbd, f, g, task, iprint, isave)
    n = S.n
    while true
        iprint >= 99 && _cprint("Iteration %5d\n", S.iter)
        S.iword = -1
        goto333 = false
        if !S.cnstnd && S.col > 0
            _lb_dcopy(n, x, 1, S.z, 1)
            S.wrk = S.updatd
            S.nint = 0
            goto333 = true
        end
        if !goto333
            info = _lb_cauchy!(S, x, l, u, nbd, g, iprint)
            if info != 0
                iprint >= 1 && _cprint("%s\n%s\n", "Singular triangular system detected;",
                                       "   refresh the lbfgs memory and restart the iteration.")
                _lb_reset!(S)
                continue
            end
            S.nintol += S.nint
            _lb_freev!(S, iprint)
            S.nact = n - S.nfree
        end
        # L333
        restart = false
        if !(S.nfree == 0 || S.col == 0)
            S.wrk && (S.info = _lb_formk!(S))
            if S.info != 0
                iprint >= 0 && _cprint("%s\n%s\n", "Nonpositive definiteness in Cholesky factorization in formk;",
                                       "   refresh the lbfgs memory and restart the iteration.")
                _lb_reset!(S)
                continue
            end
            S.info = _lb_cmprlb!(S, x, g)
            S.info == 0 && (S.info = _lb_subsm!(S, l, u, nbd, x, iprint))
            if S.info != 0
                iprint >= 1 && _cprint("%s\n%s\n", "Singular triangular system detected;",
                                       "   refresh the lbfgs memory and restart the iteration.")
                _lb_reset!(S)
                restart = true
            end
        end
        restart && continue
        # L555
        for i in 1:n
            S.d[i] = S.z[i] - x[i]
        end
        break
    end
    return _lb_L666!(S, x, l, u, nbd, f, g, task, iprint, isave)
end

function _lb_L666!(S, x, l, u, nbd, f, g, task, iprint, isave)
    n = S.n
    task = _lb_lnsrlb!(S, l, u, nbd, x, f, g, task)
    if S.info != 0 || S.iback >= 20
        _lb_dcopy(n, S.t, 1, x, 1)
        _lb_dcopy(n, S.r, 1, g, 1)
        f = S.fold
        if S.col == 0
            if S.info == 0
                S.info = -9
                S.nfgv -= 1
                S.ifun -= 1
                S.iback -= 1
            end
            task = "ERROR: ABNORMAL_TERMINATION_IN_LNSRCH"
            S.iter += 1
            return _lb_finish(S, x, f, task, iprint, isave)
        else
            iprint >= 1 && _cprint("%s\n%s\n", "Bad direction in the line search;",
                                   "   refresh the lbfgs memory and restart the iteration.")
            S.info == 0 && (S.nfgv -= 1)
            _lb_reset!(S)
            task = "RESTART_FROM_LNSRCH"
            return _lb_L222!(S, x, l, u, nbd, f, g, task, iprint, isave)
        end
    elseif startswith(task, "FG_LN")
        return _lb_finish(S, x, f, task, iprint, isave)
    else
        S.iter += 1
        S.sbgnrm = _lb_projgr(S, l, u, nbd, x, g)
        _lb_prn2lb(S, x, f, g, iprint)
        return _lb_finish(S, x, f, task, iprint, isave)
    end
end

function _lb_L777!(S, x, l, u, nbd, f, g, pgtol, task, iprint, isave)
    n = S.n
    if S.sbgnrm <= pgtol
        task = "CONVERGENCE: NORM OF PROJECTED GRADIENT <= PGTOL"
        return _lb_finish(S, x, f, task, iprint, isave)
    end
    d1 = abs(S.fold)
    d2 = abs(f)
    d1 = _cmax(d1, d2)
    ddum = _cmax(d1, 1.0)
    if S.fold - f <= S.tol * ddum
        task = "CONVERGENCE: REL_REDUCTION_OF_F <= FACTR*EPSMCH"
        S.iback >= 10 && (S.info = -5)
        return _lb_finish(S, x, f, task, iprint, isave)
    end
    r = S.r
    for i in 1:n
        r[i] = g[i] - r[i]
    end
    rr = _lb_ddot(n, r, 1, r, 1)
    if S.stp == 1.0
        dr = S.gd - S.gdold
        ddum = -S.gdold
    else
        dr = (S.gd - S.gdold) * S.stp
        _lb_dscal(n, S.stp, S.d, 1)
        ddum = -S.gdold * S.stp
    end
    if dr <= S.epsmch * ddum
        S.nskip += 1
        S.updatd = false
        iprint >= 1 && _cprint("ys=%10.3e  -gs=%10.3e, BFGS update SKIPPED\n", dr, ddum)
        return _lb_L222!(S, x, l, u, nbd, f, g, task, iprint, isave)
    end
    S.updatd = true
    S.iupdat += 1
    _lb_matupd!(S, rr, dr)
    S.info = _lb_formt!(S)
    if S.info != 0
        iprint >= 0 && _cprint("%s\n%s\n", "Nonpositive definiteness in Cholesky factorization in formt();",
                               "   refresh the lbfgs memory and restart the iteration.")
        _lb_reset!(S)
    end
    return _lb_L222!(S, x, l, u, nbd, f, g, task, iprint, isave)
end

function _lb_active!(S, l, u, nbd, x, iprint)
    n = S.n
    nbdd = 0
    S.prjctd = false
    S.cnstnd = false
    S.boxed = true
    for i in 1:n
        if nbd[i] > 0
            if nbd[i] <= 2 && x[i] <= l[i]
                if x[i] < l[i]
                    S.prjctd = true
                    x[i] = l[i]
                end
                nbdd += 1
            elseif nbd[i] >= 2 && x[i] >= u[i]
                if x[i] > u[i]
                    S.prjctd = true
                    x[i] = u[i]
                end
                nbdd += 1
            end
        end
    end
    iwhere = S.iwhere
    for i in 1:n
        nbd[i] != 2 && (S.boxed = false)
        if nbd[i] == 0
            iwhere[i] = -1
        else
            S.cnstnd = true
            iwhere[i] = (nbd[i] == 2 && u[i] - l[i] <= 0.0) ? 3 : 0
        end
    end
    if iprint >= 0
        S.prjctd && _cprint("The initial X is infeasible.  Restart with its projection.\n")
        S.cnstnd || _cprint("This problem is unconstrained.\n")
    end
    iprint > 0 && _cprint("At X0, %d variables are exactly at the bounds\n", nbdd)
    nothing
end

"bmv(m, sy, wt, col, v, p): v(k) = v[vb+k-1], p(k) = p[pb+k-1]."
function _lb_bmv(S, col, v, vb, p, pb)
    m = S.m
    sy = S.sy
    col == 0 && return 0
    p[pb+col] = v[vb+col]
    for i in 2:col
        i2 = col + i
        s = 0.0
        for k in 1:i-1
            s = s + sy[_Mm(S, i, k)] * v[vb+k-1] / sy[_Mm(S, k, k)]
        end
        p[pb+i2-1] = v[vb+i2-1] + s
    end
    info = _lb_dtrsl(S.wt, 1, m, col, p, pb + col, 11)
    info != 0 && return info
    for i in 1:col
        p[pb+i-1] = v[vb+i-1] / _csqrt(sy[_Mm(S, i, i)])
    end
    info = _lb_dtrsl(S.wt, 1, m, col, p, pb + col, 1)
    info != 0 && return info
    for i in 1:col
        p[pb+i-1] = -p[pb+i-1] / _csqrt(sy[_Mm(S, i, i)])
    end
    for i in 1:col
        s = 0.0
        for k in i+1:col
            s = s + sy[_Mm(S, k, i)] * p[pb+col+k-1] / sy[_Mm(S, i, i)]
        end
        p[pb+i-1] = p[pb+i-1] + s
    end
    return 0
end

function _lb_cauchy!(S, x, l, u, nbd, g, iprint)
    n, m = S.n, S.m
    wy, ws = S.wy, S.ws
    xcp = S.z
    d = S.d
    t = S.t
    iwhere = S.iwhere
    iorder = S.indx2
    wa = S.wa
    P = 1
    C = 2 * m + 1
    WBP = 4 * m + 1
    V = 6 * m + 1
    col = S.col
    theta = S.theta
    if S.sbgnrm <= 0.0
        iprint >= 0 && _cprint("Subgnorm = 0.  GCP = X.\n")
        _lb_dcopy(n, x, 1, xcp, 1)
        return 0
    end
    bnded = true
    nfree = n + 1
    nbreak = 0
    ibkmin = 0
    bkmin = 0.0
    col2 = col << 1
    f1 = 0.0
    tl = 0.0
    tu = 0.0
    iprint >= 99 && _cprint("\n---------------- CAUCHY entered-------------------\n\n")
    for i in 1:col2
        wa[P+i-1] = 0.0
    end
    for i in 1:n
        neggi = -g[i]
        if iwhere[i] != 3 && iwhere[i] != -1
            nbd[i] <= 2 && (tl = x[i] - l[i])
            nbd[i] >= 2 && (tu = u[i] - x[i])
            xlower = nbd[i] <= 2 && tl <= 0.0
            xupper = nbd[i] >= 2 && tu <= 0.0
            iwhere[i] = 0
            if xlower
                neggi <= 0.0 && (iwhere[i] = 1)
            elseif xupper
                neggi >= 0.0 && (iwhere[i] = 2)
            else
                abs(neggi) <= 0.0 && (iwhere[i] = -3)
            end
        end
        pointr = S.head
        if iwhere[i] != 0 && iwhere[i] != -1
            d[i] = 0.0
        else
            d[i] = neggi
            f1 -= neggi * neggi
            for j in 1:col
                wa[P+j-1] += wy[_Wn(S, i, pointr)] * neggi
                wa[P+col+j-1] += ws[_Wn(S, i, pointr)] * neggi
                pointr = pointr % m + 1
            end
            if nbd[i] <= 2 && nbd[i] != 0 && neggi < 0.0
                nbreak += 1
                iorder[nbreak] = i
                t[nbreak] = tl / (-neggi)
                if nbreak == 1 || t[nbreak] < bkmin
                    bkmin = t[nbreak]
                    ibkmin = nbreak
                end
            elseif nbd[i] >= 2 && neggi > 0.0
                nbreak += 1
                iorder[nbreak] = i
                t[nbreak] = tu / neggi
                if nbreak == 1 || t[nbreak] < bkmin
                    bkmin = t[nbreak]
                    ibkmin = nbreak
                end
            else
                nfree -= 1
                iorder[nfree] = i
                abs(neggi) > 0.0 && (bnded = false)
            end
        end
    end
    theta != 1.0 && _lb_dscal(col, theta, wa, P + col)
    _lb_dcopy(n, x, 1, xcp, 1)
    if nbreak == 0 && nfree == n + 1
        if iprint > 100
            _cprint("Cauchy X =  ")
            for i in 1:n
                _cprint("%g ", xcp[i])
            end
            _cprint("\n")
        end
        return 0
    end
    for j in 1:col2
        wa[C+j-1] = 0.0
    end
    f2 = -theta * f1
    f2_org = f2
    if col > 0
        info = _lb_bmv(S, col, wa, P, wa, V)
        info != 0 && return info
        f2 -= _lb_ddot(col2, wa, V, wa, P)
    end
    dtm = -f1 / f2
    tsum = 0.0
    S.nint = 1
    iprint >= 99 && _cprint("There are %d  breakpoints\n", nbreak)
    goto999 = false
    if nbreak != 0
        nleft = nbreak
        it = 1
        tj = 0.0
        while true
            tj0 = tj
            if it == 1
                tj = bkmin
                ibp = iorder[ibkmin]
            else
                if it == 2
                    if ibkmin != nbreak
                        t[ibkmin] = t[nbreak]
                        iorder[ibkmin] = iorder[nbreak]
                    end
                end
                _lb_hpsolb!(nleft, t, iorder, it - 2)
                tj = t[nleft]
                ibp = iorder[nleft]
            end
            dt = tj - tj0
            if dt != 0 && iprint >= 100
                _cprint("\nPiece    %3i f1, f2 at start point %11.4e %11.4e\n", S.nint, f1, f2)
                _cprint("Distance to the next break point =  %11.4e\n", dt)
                _cprint("Distance to the stationary point =  %11.4e\n", dtm)
            end
            dtm < dt && break
            tsum += dt
            nleft -= 1
            it += 1
            dibp = d[ibp]
            d[ibp] = 0.0
            if dibp > 0.0
                zibp = u[ibp] - x[ibp]
                xcp[ibp] = u[ibp]
                iwhere[ibp] = 2
            else
                zibp = l[ibp] - x[ibp]
                xcp[ibp] = l[ibp]
                iwhere[ibp] = 1
            end
            iprint >= 100 && _cprint("Variable  %d  is fixed.\n", ibp)
            if nleft == 0 && nbreak == n
                dtm = dt
                goto999 = true
                break
            end
            S.nint += 1
            dibp2 = dibp * dibp
            f1 += ((dt * f2 + dibp2) - (theta * dibp) * zibp)
            f2 -= theta * dibp2
            if col > 0
                _lb_daxpy(col2, dt, wa, P, wa, C)
                pointr = S.head
                for j in 1:col
                    wa[WBP+j-1] = wy[_Wn(S, ibp, pointr)]
                    wa[WBP+col+j-1] = theta * ws[_Wn(S, ibp, pointr)]
                    pointr = pointr % m + 1
                end
                info = _lb_bmv(S, col, wa, WBP, wa, V)
                info != 0 && return info
                wmc = _lb_ddot(col2, wa, C, wa, V)
                wmp = _lb_ddot(col2, wa, P, wa, V)
                wmw = _lb_ddot(col2, wa, WBP, wa, V)
                _lb_daxpy(col2, -dibp, wa, WBP, wa, P)
                f1 += dibp * wmc
                f2 += ((2.0 * dibp) * wmp - dibp2 * wmw)
            end
            d1 = S.epsmch * f2_org
            f2 < d1 && (f2 = d1)
            if nleft > 0
                dtm = -f1 / f2
                continue
            elseif bnded
                f1 = 0.0
                f2 = 0.0
                dtm = 0.0
            else
                dtm = -f1 / f2
            end
            break
        end
    end
    if !goto999
        if iprint >= 99
            _cprint("\nGCP found in this segment\n")
            _cprint("Piece    %3i f1, f2 at start point %11.4e %11.4e\n", S.nint, f1, f2)
            _cprint("Distance to the stationary point =  %11.4e\n", dtm)
        end
        dtm <= 0.0 && (dtm = 0.0)
        tsum += dtm
        _lb_daxpy(n, tsum, d, 1, xcp, 1)
    end
    col > 0 && _lb_daxpy(col2, dtm, wa, P, wa, C)
    if iprint >= 100
        _cprint("Cauchy X =  ")
        for i in 1:n
            _cprint("%g ", xcp[i])
        end
        _cprint("\n")
    end
    iprint >= 99 && _cprint("\n---------------- exit CAUCHY----------------------\n\n")
    return 0
end

function _lb_cmprlb!(S, x, g)
    n, m = S.n, S.m
    r = S.r; z = S.z; wa = S.wa; indx = S.indx
    col = S.col
    if !S.cnstnd && col > 0
        for i in 1:n
            r[i] = -g[i]
        end
    else
        nf = S.nfree
        for i in 1:nf
            k = indx[i]
            r[i] = -S.theta * (z[k] - x[k]) - g[k]
        end
        info = _lb_bmv(S, col, wa, 2 * m + 1, wa, 1)
        info != 0 && return -8
        pointr = S.head
        wy, ws = S.wy, S.ws
        for j in 1:col
            a1 = wa[j]
            a2 = S.theta * wa[col+j]
            for i in 1:nf
                k = indx[i]
                r[i] += (wy[_Wn(S, k, pointr)] * a1 + ws[_Wn(S, k, pointr)] * a2)
            end
            pointr = pointr % m + 1
        end
    end
    return 0
end

function _lb_errclb!(S, n, m, factr, l, u, nbd, task)
    n <= 0 && (task = "ERROR: N .LE. 0")
    m <= 0 && (task = "ERROR: M .LE. 0")
    factr < 0.0 && (task = "ERROR: FACTR .LT. 0")
    for i in 1:n
        if nbd[i] < 0 || nbd[i] > 3
            task = "ERROR: INVALID NBD"
            S.info = -6
            S.k = i
        end
        if nbd[i] == 2 && l[i] > u[i]
            task = "ERROR: NO FEASIBLE SOLUTION"
            S.info = -7
            S.k = i
        end
    end
    return task
end

function _lb_formk!(S)
    n, m = S.n, S.m
    ind = S.indx; indx2 = S.indx2; wn = S.wn; wn1 = S.snd
    ws, wy, sy = S.ws, S.wy, S.sy
    col = S.col
    head = S.head
    if S.updatd
        if S.iupdat > m
            for jy in 1:m-1
                js = m + jy
                i2 = m - jy
                _lb_dcopy(i2, wn1, _M2(S, jy + 1, jy + 1), wn1, _M2(S, jy, jy))
                _lb_dcopy(i2, wn1, _M2(S, js + 1, js + 1), wn1, _M2(S, js, js))
                _lb_dcopy(m - 1, wn1, _M2(S, m + 2, jy + 1), wn1, _M2(S, m + 1, jy))
            end
        end
        pbegin = 1
        pend = S.nfree
        dbegin = S.nfree + 1
        dend = n
        iy = col
        is_ = m + col
        ipntr = head + col - 1
        ipntr > m && (ipntr -= m)
        jpntr = head
        for jy in 1:col
            js = m + jy
            temp1 = 0.0; temp2 = 0.0; temp3 = 0.0
            for k in pbegin:pend
                k1 = ind[k]
                temp1 += wy[_Wn(S, k1, ipntr)] * wy[_Wn(S, k1, jpntr)]
            end
            for k in dbegin:dend
                k1 = ind[k]
                temp2 += ws[_Wn(S, k1, ipntr)] * ws[_Wn(S, k1, jpntr)]
                temp3 += ws[_Wn(S, k1, ipntr)] * wy[_Wn(S, k1, jpntr)]
            end
            wn1[_M2(S, iy, jy)] = temp1
            wn1[_M2(S, is_, js)] = temp2
            wn1[_M2(S, is_, jy)] = temp3
            jpntr = jpntr % m + 1
        end
        jy = col
        jpntr = head + col - 1
        jpntr > m && (jpntr -= m)
        ipntr = head
        for i in 1:col
            is_ = m + i
            temp3 = 0.0
            for k in pbegin:pend
                k1 = ind[k]
                temp3 += ws[_Wn(S, k1, ipntr)] * wy[_Wn(S, k1, jpntr)]
            end
            ipntr = ipntr % m + 1
            wn1[_M2(S, is_, jy)] = temp3
        end
        upcl = col - 1
    else
        upcl = col
    end
    ipntr = head
    for iy in 1:upcl
        is_ = m + iy
        jpntr = head
        for jy in 1:iy
            js = m + jy
            temp1 = 0.0; temp2 = 0.0; temp3 = 0.0; temp4 = 0.0
            for k in 1:S.nenter
                k1 = indx2[k]
                temp1 += wy[_Wn(S, k1, ipntr)] * wy[_Wn(S, k1, jpntr)]
                temp2 += ws[_Wn(S, k1, ipntr)] * ws[_Wn(S, k1, jpntr)]
            end
            for k in S.ileave:n
                k1 = indx2[k]
                temp3 += wy[_Wn(S, k1, ipntr)] * wy[_Wn(S, k1, jpntr)]
                temp4 += ws[_Wn(S, k1, ipntr)] * ws[_Wn(S, k1, jpntr)]
            end
            wn1[_M2(S, iy, jy)] = (wn1[_M2(S, iy, jy)] + temp1) - temp3
            wn1[_M2(S, is_, js)] = (wn1[_M2(S, is_, js)] - temp2) + temp4
            jpntr = jpntr % m + 1
        end
        ipntr = ipntr % m + 1
    end
    ipntr = head
    for is_ in m+1:m+upcl
        jpntr = head
        for jy in 1:upcl
            temp1 = 0.0; temp3 = 0.0
            for k in 1:S.nenter
                k1 = indx2[k]
                temp1 += ws[_Wn(S, k1, ipntr)] * wy[_Wn(S, k1, jpntr)]
            end
            for k in S.ileave:n
                k1 = indx2[k]
                temp3 += ws[_Wn(S, k1, ipntr)] * wy[_Wn(S, k1, jpntr)]
            end
            if is_ <= jy + m
                wn1[_M2(S, is_, jy)] += temp1 - temp3
            else
                wn1[_M2(S, is_, jy)] += -temp1 + temp3
            end
            jpntr = jpntr % m + 1
        end
        ipntr = ipntr % m + 1
    end
    m2 = m << 1
    for iy in 1:col
        is_ = col + iy
        is1 = m + iy
        for jy in 1:iy
            js = col + jy
            js1 = m + jy
            wn[_M2(S, jy, iy)] = wn1[_M2(S, iy, jy)] / S.theta
            wn[_M2(S, js, is_)] = wn1[_M2(S, is1, js1)] * S.theta
        end
        for jy in 1:iy-1
            wn[_M2(S, jy, is_)] = -wn1[_M2(S, is1, jy)]
        end
        for jy in iy:col
            wn[_M2(S, jy, is_)] = wn1[_M2(S, is1, jy)]
        end
        wn[_M2(S, iy, iy)] += sy[_Mm(S, iy, iy)]
    end
    info = _lb_dpofa(wn, 1, m2, col)
    info != 0 && return -1
    col2 = col << 1
    for js in col+1:col2
        _lb_dtrsl(wn, 1, m2, col, wn, _M2(S, 1, js), 11)
    end
    for is_ in col+1:col2
        for js in is_:col2
            wn[_M2(S, is_, js)] += _lb_ddot(col, wn, _M2(S, 1, is_), wn, _M2(S, 1, js))
        end
    end
    info = _lb_dpofa(wn, _M2(S, col + 1, col + 1), m2, col)
    info != 0 && return -2
    return 0
end

function _lb_formt!(S)
    m = S.m
    wt, sy, ss = S.wt, S.sy, S.ss
    col = S.col
    for j in 1:col
        wt[_Mm(S, 1, j)] = S.theta * ss[_Mm(S, 1, j)]
    end
    for i in 2:col
        for j in i:col
            k1 = i > j ? j : i - 1          # C-Makro: min(i,j) - 1
            ddum = 0.0
            for k in 1:k1
                ddum += sy[_Mm(S, i, k)] * sy[_Mm(S, j, k)] / sy[_Mm(S, k, k)]
            end
            wt[_Mm(S, i, j)] = ddum + S.theta * ss[_Mm(S, i, j)]
        end
    end
    info = _lb_dpofa(wt, 1, m, col)
    info != 0 && return -3
    return 0
end

function _lb_freev!(S, iprint)
    n = S.n
    indx = S.indx; indx2 = S.indx2; iwhere = S.iwhere
    S.nenter = 0
    S.ileave = n + 1
    if S.iter > 0 && S.cnstnd
        for i in 1:S.nfree
            k = indx[i]
            if iwhere[k] > 0
                S.ileave -= 1
                indx2[S.ileave] = k
                iprint >= 100 && _cprint("Variable %d leaves the set of free variables\n", k)
            end
        end
        for i in S.nfree+1:n
            k = indx[i]
            if iwhere[k] <= 0
                S.nenter += 1
                indx2[S.nenter] = k
                iprint >= 100 && _cprint("Variable %d enters the set of free variables\n", k)
            end
            iprint >= 100 && _cprint("%d variables leave; %d variables enter\n", n + 1 - S.ileave, S.nenter)
        end
    end
    S.wrk = S.ileave < n + 1 || S.nenter > 0 || S.updatd
    S.nfree = 0
    iact = n + 1
    for i in 1:n
        if iwhere[i] <= 0
            S.nfree += 1
            indx[S.nfree] = i
        else
            iact -= 1
            indx[iact] = i
        end
    end
    iprint >= 99 && _cprint("%d  variables are free at GCP on iteration %d\n", S.nfree, S.iter + 1)
    nothing
end

function _lb_hpsolb!(n, t, iorder, iheap)
    if iheap == 0
        for k in 2:n
            ddum = t[k]
            indxin = iorder[k]
            i = k
            while i > 1
                j = i ÷ 2
                if ddum < t[j]
                    t[i] = t[j]
                    iorder[i] = iorder[j]
                    i = j
                else
                    break
                end
            end
            t[i] = ddum
            iorder[i] = indxin
        end
    end
    if n > 1
        i = 1
        out = t[1]
        indxou = iorder[1]
        ddum = t[n]
        indxin = iorder[n]
        while true
            j = i + i
            if j <= n - 1
                t[j+1] < t[j] && (j += 1)
                if t[j] < ddum
                    t[i] = t[j]
                    iorder[i] = iorder[j]
                    i = j
                    continue
                end
            end
            break
        end
        t[i] = ddum
        iorder[i] = indxin
        t[n] = out
        iorder[n] = indxou
    end
    nothing
end

function _lb_lnsrlb!(S, l, u, nbd, x, f, g, task)
    n = S.n
    d, t, r, z = S.d, S.t, S.r, S.z
    stpmin = 0.0
    ftol = 0.001
    gtol = 0.9
    xtol = 0.1
    if !startswith(task, "FG_LN")
        S.dtd = _lb_ddot(n, d, 1, d, 1)
        S.dnorm = _csqrt(S.dtd)
        S.stpmx = 1e10
        if S.cnstnd
            if S.iter == 0
                S.stpmx = 1.0
            else
                for i in 1:n
                    a1 = d[i]
                    if nbd[i] != 0
                        if a1 < 0.0 && nbd[i] <= 2
                            a2 = l[i] - x[i]
                            if a2 >= 0.0
                                S.stpmx = 0.0
                            elseif a1 * S.stpmx < a2
                                S.stpmx = a2 / a1
                            end
                        elseif a1 > 0.0 && nbd[i] >= 2
                            a2 = u[i] - x[i]
                            if a2 <= 0.0
                                S.stpmx = 0.0
                            elseif a1 * S.stpmx > a2
                                S.stpmx = a2 / a1
                            end
                        end
                    end
                end
            end
        end
        if S.iter == 0 && !S.boxed
            d1 = S.dnorm != 0.0 ? 1.0 / S.dnorm : Inf
            S.stp = _cmin(d1, S.stpmx)
        else
            S.stp = 1.0
        end
        _lb_dcopy(n, x, 1, t, 1)
        _lb_dcopy(n, g, 1, r, 1)
        S.fold = f
        S.ifun = 0
        S.iback = 0
        S.csave = "START"
    end
    # L556
    S.gd = _lb_ddot(n, g, 1, d, 1)
    if S.ifun == 0
        S.gdold = S.gd
        if S.gd >= 0.0
            S.info = -4
            return task
        end
    end
    S.csave = _lb_dcsrch!(S, f, S.gd, ftol, gtol, xtol, stpmin, S.stpmx, S.csave)
    S.xstep = S.stp * S.dnorm
    if !startswith(S.csave, "CONV") && !startswith(S.csave, "WARN")
        task = "FG_LNSRCH"
        S.ifun += 1
        S.nfgv += 1
        S.iback = S.ifun - 1
        if S.stp == 1.0
            _lb_dcopy(n, z, 1, x, 1)
        else
            for i in 1:n
                x[i] = S.stp * d[i] + t[i]
            end
        end
    else
        task = "NEW_X"
    end
    return task
end

function _lb_matupd!(S, rr, dr)
    n, m = S.n, S.m
    ws, wy, sy, ss = S.ws, S.wy, S.sy, S.ss
    d, r = S.d, S.r
    if S.iupdat <= m
        S.col = S.iupdat
        S.itail = (S.head + S.iupdat - 2) % m + 1
    else
        S.itail = S.itail % m + 1
        S.head = S.head % m + 1
    end
    _lb_dcopy(n, d, 1, ws, _Wn(S, 1, S.itail))
    _lb_dcopy(n, r, 1, wy, _Wn(S, 1, S.itail))
    S.theta = rr / dr
    col = S.col
    if S.iupdat > m
        for j in 1:col-1
            _lb_dcopy(j, ss, _Mm(S, 2, j + 1), ss, _Mm(S, 1, j))
            _lb_dcopy(col - j, sy, _Mm(S, j + 1, j + 1), sy, _Mm(S, j, j))
        end
    end
    pointr = S.head
    for j in 1:col-1
        sy[_Mm(S, col, j)] = _lb_ddot(n, d, 1, wy, _Wn(S, 1, pointr))
        ss[_Mm(S, j, col)] = _lb_ddot(n, ws, _Wn(S, 1, pointr), d, 1)
        pointr = pointr % m + 1
    end
    if S.stp == 1.0
        ss[_Mm(S, col, col)] = S.dtd
    else
        ss[_Mm(S, col, col)] = S.stp * S.stp * S.dtd
    end
    sy[_Mm(S, col, col)] = dr
    nothing
end

function _lb_projgr(S, l, u, nbd, x, g)
    sbgnrm = 0.0
    for i in 1:S.n
        gi = g[i]
        if nbd[i] != 0
            if gi < 0.0
                if nbd[i] >= 2
                    d1 = x[i] - u[i]
                    gi < d1 && (gi = d1)
                end
            else
                if nbd[i] <= 2
                    d1 = x[i] - l[i]
                    gi > d1 && (gi = d1)
                end
            end
        end
        d1 = abs(gi)
        sbgnrm < d1 && (sbgnrm = d1)
    end
    return sbgnrm
end

function _lb_subsm!(S, l, u, nbd, x, iprint)
    n, m = S.n, S.m
    ind = S.indx
    d = S.r                 # subsm(..., &z[1], &r[1], ...) → x = z, d = r
    xx = S.z
    ws, wy = S.ws, S.wy
    wn = S.wn
    wv = S.wa
    theta = S.theta
    col = S.col
    ns = S.nfree
    ns <= 0 && return 0
    pointr = S.head
    for i in 1:col
        temp1 = 0.0
        temp2 = 0.0
        for j in 1:ns
            k = ind[j]
            temp1 += wy[k+(pointr-1)*n] * d[j]
            temp2 += ws[k+(pointr-1)*n] * d[j]
        end
        wv[i] = temp1
        wv[col+i] = theta * temp2
        pointr = pointr % m + 1
    end
    m2 = m << 1
    col2 = col << 1
    info = _lb_dtrsl(wn, 1, m2, col2, wv, 1, 11)
    info != 0 && return info
    for i in 1:col
        wv[i] = -wv[i]
    end
    info = _lb_dtrsl(wn, 1, m2, col2, wv, 1, 1)
    info != 0 && return info
    pointr = S.head
    for jy in 1:col
        js = col + jy
        for i in 1:ns
            k = ind[i]
            d[i] += (wy[k+(pointr-1)*n] * wv[jy] / theta + ws[k+(pointr-1)*n] * wv[js])
        end
        pointr = pointr % m + 1
    end
    for i in 1:ns
        d[i] /= theta
    end
    alpha = 1.0
    temp1 = alpha
    ibd = 0
    for i in 1:ns
        k = ind[i]
        dk = d[i]
        if nbd[k] != 0
            if dk < 0.0 && nbd[k] <= 2
                temp2 = l[k] - xx[k]
                if temp2 >= 0.0
                    temp1 = 0.0
                elseif dk * alpha < temp2
                    temp1 = temp2 / dk
                end
            elseif dk > 0.0 && nbd[k] >= 2
                temp2 = u[k] - xx[k]
                if temp2 <= 0.0
                    temp1 = 0.0
                elseif dk * alpha > temp2
                    temp1 = temp2 / dk
                end
            end
            if temp1 < alpha
                alpha = temp1
                ibd = i
            end
        end
    end
    if alpha < 1.0
        dk = d[ibd]
        k = ind[ibd]
        if dk > 0.0
            xx[k] = u[k]
            d[ibd] = 0.0
        elseif dk < 0.0
            xx[k] = l[k]
            d[ibd] = 0.0
        end
    end
    for i in 1:ns
        xx[ind[i]] += alpha * d[i]
    end
    S.iword = alpha < 1.0 ? 1 : 0
    return 0
end

function _lb_dcsrch!(S, f, g, ftol, gtol, xtol, stpmin, stpmax, task)
    if startswith(task, "START")
        S.stp < stpmin && (task = "ERROR: STP .LT. STPMIN")
        S.stp > stpmax && (task = "ERROR: STP .GT. STPMAX")
        g >= 0.0 && (task = "ERROR: INITIAL G .GE. ZERO")
        ftol < 0.0 && (task = "ERROR: FTOL .LT. ZERO")
        gtol < 0.0 && (task = "ERROR: GTOL .LT. ZERO")
        xtol < 0.0 && (task = "ERROR: XTOL .LT. ZERO")
        stpmin < 0.0 && (task = "ERROR: STPMIN .LT. ZERO")
        stpmax < stpmin && (task = "ERROR: STPMAX .LT. STPMIN")
        startswith(task, "ERROR") && return task
        S.ls_brackt = false
        S.ls_stage = 1
        S.ls_finit = f
        S.ls_ginit = g
        S.ls_gtest = ftol * S.ls_ginit
        S.ls_width = stpmax - stpmin
        S.ls_width1 = S.ls_width / 0.5
        S.ls_stx = 0.0
        S.ls_fx = S.ls_finit
        S.ls_gx = S.ls_ginit
        S.ls_sty = 0.0
        S.ls_fy = S.ls_finit
        S.ls_gy = S.ls_ginit
        S.ls_stmin = 0.0
        S.ls_stmax = S.stp + S.stp * 4.0
        return "FG"
    end
    ftest = S.ls_finit + S.stp * S.ls_gtest
    (S.ls_stage == 1 && f <= ftest && g >= 0.0) && (S.ls_stage = 2)
    (S.ls_brackt && (S.stp <= S.ls_stmin || S.stp >= S.ls_stmax)) && (task = "WARNING: ROUNDING ERRORS PREVENT PROGRESS")
    (S.ls_brackt && S.ls_stmax - S.ls_stmin <= xtol * S.ls_stmax) && (task = "WARNING: XTOL TEST SATISFIED")
    (S.stp == stpmax && f <= ftest && g <= S.ls_gtest) && (task = "WARNING: STP = STPMAX")
    (S.stp == stpmin && (f > ftest || g >= S.ls_gtest)) && (task = "WARNING: STP = STPMIN")
    (f <= ftest && abs(g) <= gtol * (-S.ls_ginit)) && (task = "CONVERGENCE")
    (startswith(task, "WARN") || startswith(task, "CONV")) && return task
    if S.ls_stage == 1 && f <= S.ls_fx && f > ftest
        fm = f - S.stp * S.ls_gtest
        fxm = S.ls_fx - S.ls_stx * S.ls_gtest
        fym = S.ls_fy - S.ls_sty * S.ls_gtest
        gm = g - S.ls_gtest
        gxm = S.ls_gx - S.ls_gtest
        gym = S.ls_gy - S.ls_gtest
        (S.ls_stx, fxm, gxm, S.ls_sty, fym, gym, S.stp, S.ls_brackt) =
            _lb_dcstep(S.ls_stx, fxm, gxm, S.ls_sty, fym, gym, S.stp, fm, gm, S.ls_brackt, S.ls_stmin, S.ls_stmax)
        S.ls_fx = fxm + S.ls_stx * S.ls_gtest
        S.ls_fy = fym + S.ls_sty * S.ls_gtest
        S.ls_gx = gxm + S.ls_gtest
        S.ls_gy = gym + S.ls_gtest
    else
        (S.ls_stx, S.ls_fx, S.ls_gx, S.ls_sty, S.ls_fy, S.ls_gy, S.stp, S.ls_brackt) =
            _lb_dcstep(S.ls_stx, S.ls_fx, S.ls_gx, S.ls_sty, S.ls_fy, S.ls_gy, S.stp, f, g, S.ls_brackt,
                       S.ls_stmin, S.ls_stmax)
    end
    if S.ls_brackt
        if abs(S.ls_sty - S.ls_stx) >= S.ls_width1 * 0.66
            S.stp = S.ls_stx + (S.ls_sty - S.ls_stx) * 0.5
        end
        S.ls_width1 = S.ls_width
        S.ls_width = abs(S.ls_sty - S.ls_stx)
    end
    if S.ls_brackt
        S.ls_stmin = _cmin(S.ls_stx, S.ls_sty)
        S.ls_stmax = _cmax(S.ls_stx, S.ls_sty)
    else
        S.ls_stmin = S.stp + (S.stp - S.ls_stx) * 1.1
        S.ls_stmax = S.stp + (S.stp - S.ls_stx) * 4.0
    end
    S.stp < stpmin && (S.stp = stpmin)
    S.stp > stpmax && (S.stp = stpmax)
    if (S.ls_brackt && (S.stp <= S.ls_stmin || S.stp >= S.ls_stmax)) ||
       (S.ls_brackt && (S.ls_stmax - S.ls_stmin <= xtol * S.ls_stmax))
        S.stp = S.ls_stx
    end
    return "FG"
end

function _lb_prn1lb(S, l, u, x, iprint)
    if iprint >= 0
        _cprint("N = %d, M = %d machine precision = %g\n", S.n, S.m, S.epsmch)
        if iprint >= 100
            for (title, v) in (("L =", l), ("X0 =", x), ("U =", u))
                _cprint("%s ", title)
                for i in 1:S.n
                    _cprint("%g ", v[i])
                end
                _cprint("\n")
            end
        end
    end
end

function _lb_prn2lb(S, x, f, g, iprint)
    if iprint >= 99
        _cprint("LINE SEARCH %d times; norm of step = %g\n", S.iback, S.xstep)
        if iprint > 100
            for (title, v) in (("X =", x), ("G =", g))
                _cprint("%s ", title)
                for i in 1:S.n
                    _cprint("%g ", v[i])
                end
                _cprint("\n")
            end
        end
    elseif iprint > 0 && S.iter % iprint == 0
        _cprint("At iterate %5d  f = %12.5g  |proj g|=  %12.5g\n", S.iter, f, S.sbgnrm)
    end
end

function _lb_prn3lb(S, x, f, task, iprint)
    if startswith(task, "CONV")
        if iprint >= 0
            _cprint("\niterations %d\nfunction evaluations %d\nsegments explored during Cauchy searches %d\nBFGS updates skipped %d\nactive bounds at final generalized Cauchy point %d\nnorm of the final projected gradient %g\nfinal function value %g\n\n",
                    S.iter, S.nfgv, S.nintol, S.nskip, S.nact, S.sbgnrm, f)
        end
        if iprint >= 100
            _cprint("%s ", "X =")
            for i in 1:S.n
                _cprint("%g ", x[i])
            end
            _cprint("\n")
        end
        iprint >= 1 && _cprint("F = %g\n", f)
    end
    if iprint >= 0
        msgs = Dict(-1 => "Matrix in 1st Cholesky factorization in formk is not Pos. Def.",
                    -2 => "Matrix in 2st Cholesky factorization in formk is not Pos. Def.",
                    -3 => "Matrix in the Cholesky factorization in formt is not Pos. Def.",
                    -4 => "Derivative >= 0, backtracking line search impossible.",
                    -5 => "Warning:  more than 10 function and gradient evaluations\n   in the last line search\n",
                    -8 => "The triangular system is singular.",
                    -9 => "Line search cannot locate an adequate point after 20 function\nand gradient evaluations\n")
        if haskey(msgs, S.info)
            print(msgs[S.info])
        elseif S.info == -6
            _cprint("Input nbd(%d) is invalid", S.k)
        elseif S.info == -7
            _cprint("l(%d) > u(%d).  No feasible solution", S.k, S.k)
        end
    end
end

function _lb_dcstep(stx, fx, dx, sty, fy, dy, stp, fp, dp, brackt, stpmin, stpmax)
    sgnd = dp * (dx / abs(dx))
    if fp > fx
        theta = (fx - fp) * 3.0 / (stp - stx) + dx + dp
        s = _cmax(_cmax(abs(theta), abs(dx)), abs(dp))
        d1 = theta / s
        gamm = s * _csqrt(d1 * d1 - dx / s * (dp / s))
        stp < stx && (gamm = -gamm)
        p = gamm - dx + theta
        q = gamm - dx + gamm + dp
        r = p / q
        stpc = stx + r * (stp - stx)
        stpq = stx + dx / ((fx - fp) / (stp - stx) + dx) / 2.0 * (stp - stx)
        stpf = abs(stpc - stx) < abs(stpq - stx) ? stpc : stpc + (stpq - stpc) / 2.0
        brackt = true
    elseif sgnd < 0.0
        theta = (fx - fp) * 3.0 / (stp - stx) + dx + dp
        s = _cmax(_cmax(abs(theta), abs(dx)), abs(dp))
        d1 = theta / s
        gamm = s * _csqrt(d1 * d1 - dx / s * (dp / s))
        stp > stx && (gamm = -gamm)
        p = gamm - dp + theta
        q = gamm - dp + gamm + dx
        r = p / q
        stpc = stp + r * (stx - stp)
        stpq = stp + dp / (dp - dx) * (stx - stp)
        stpf = abs(stpc - stp) > abs(stpq - stp) ? stpc : stpq
        brackt = true
    elseif abs(dp) < abs(dx)
        theta = (fx - fp) * 3.0 / (stp - stx) + dx + dp
        s = _cmax(_cmax(abs(theta), abs(dx)), abs(dp))
        d1 = theta / s
        d1 = d1 * d1 - dx / s * (dp / s)
        gamm = d1 < 0 ? 0.0 : s * _csqrt(d1)
        stp > stx && (gamm = -gamm)
        p = gamm - dp + theta
        q = gamm + (dx - dp) + gamm
        r = p / q
        if r < 0.0 && gamm != 0.0
            stpc = stp + r * (stx - stp)
        elseif stp > stx
            stpc = stpmax
        else
            stpc = stpmin
        end
        stpq = stp + dp / (dp - dx) * (stx - stp)
        if brackt
            stpf = abs(stpc - stp) < abs(stpq - stp) ? stpc : stpq
            d1 = stp + (sty - stp) * 0.66
            stpf = stp > stx ? _cmin(d1, stpf) : _cmax(d1, stpf)
        else
            stpf = abs(stpc - stp) > abs(stpq - stp) ? stpc : stpq
            stpf = _cmin(stpmax, stpf)
            stpf = _cmax(stpmin, stpf)
        end
    else
        if brackt
            theta = (fp - fy) * 3.0 / (sty - stp) + dy + dp
            s = _cmax(_cmax(abs(theta), abs(dy)), abs(dp))
            d1 = theta / s
            gamm = s * _csqrt(d1 * d1 - dy / s * (dp / s))
            stp > sty && (gamm = -gamm)
            p = gamm - dp + theta
            q = gamm - dp + gamm + dy
            r = p / q
            stpc = stp + r * (sty - stp)
            stpf = stpc
        elseif stp > stx
            stpf = stpmax
        else
            stpf = stpmin
        end
    end
    if fp > fx
        sty = stp
        fy = fp
        dy = dp
    else
        if sgnd < 0.0
            sty = stx
            fy = fx
            dy = dx
        end
        stx = stp
        fx = fp
        dx = dp
    end
    stp = stpf
    return stx, fx, dx, sty, fy, dy, stp, brackt
end

"""
    lbfgsb(n, m, x, l, u, nbd, fminfn, fmingr, factr, pgtol, maxit; trace = 0, nREPORT = 10)

R's `lbfgsb()` aus optim.c. `nbd`: 0 frei, 1 unten, 2 beide, 3 oben.
Liefert `(x, Fmin, fail, fncount, grcount, msg)`.
"""
function lbfgsb(n::Int, m::Int, x, l, u, nbd, fminfn, fmingr, factr::Float64, pgtol::Float64, maxit::Int;
                trace::Int = 0, nREPORT::Int = 10)
    if n == 0
        f = fminfn(collect(Float64, u))
        return Float64[], f, 0, 1, 0, "NOTHING TO DO"
    end
    nREPORT <= 0 && error("REPORT must be > 0 (method = \"L-BFGS-B\")")
    tr = get(Dict(2 => 0, 3 => nREPORT, 4 => 99, 5 => 100, 6 => 101), trace, -1)
    X = vcat(collect(Float64, x), 0.0)
    Lw = vcat(collect(Float64, l), 0.0)
    Uw = vcat(collect(Float64, u), 0.0)
    NB = vcat(collect(Int, nbd), 0)
    G = zeros(n + 1)
    st = _LBFGSB(n, m)
    isave = zeros(Int, 21)
    task = "START"
    f = 0.0
    fail = 0
    it = 0
    while true
        task, f = _lb_mainlb!(st, X, Lw, Uw, NB, f, G, factr, pgtol, task, tr, isave)
        if startswith(task, "FG")
            f = Float64(fminfn(X[1:n]))
            isfinite(f) || error("L-BFGS-B needs finite values of 'fn'")
            gg = fmingr(X[1:n])
            for i in 1:n
                G[i] = Float64(gg[i])
            end
        elseif startswith(task, "NEW_X")
            it += 1
            (trace == 1 && it % nREPORT == 0) && _cprint("iter %4d value %f\n", it, f)
            if it > maxit
                fail = 1
                break
            end
        elseif startswith(task, "WARN")
            fail = 51
            break
        elseif startswith(task, "CONV")
            break
        else
            fail = 52
            break
        end
    end
    cnt = isave[13]
    if trace != 0
        _cprint("final  value %f \n", f)
        (it < maxit && fail == 0) ? _cprint("converged\n") : _cprint("stopped after %i iterations\n", it)
    end
    return X[1:n], f, fail, cnt, cnt, task
end
