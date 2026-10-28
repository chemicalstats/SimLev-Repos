# ─────────────────────────────────────────────────────────────────────────────
# LAPACK-Routinen, wie R sie über die Referenz-LAPACK 3.12 nutzt.
#
# * reine Ports (bitgleich zur Referenz-LAPACK): dpotrf/dpotrf2, dgetrf/dgetrf2,
#   dlaswp, dgetrs, dgesv, dlange, dgecon (dlacn2, dlatrs, drscl), dpotri
#   (dtrtri/dtrti2, dlauum/dlauu2) und für Eigenwerte ohne Vektoren der
#   dsyevr-Pfad dlansy → dsytrd (dlatrd, dsytd2, dlarfg) → dsterf.
# * System-LAPACK über ccall (dsyevr mit Eigenvektoren): $SIMLEV_LAPACK, dann
#   die Referenz-LAPACK des Systems. Fehlt sie: LinearAlgebra.eigen mit
#   einmaliger Warnung (nicht bitgleich).
# Vorlage: python/simlev/_r/_lapack.py. Eingebunden in RLinalg.
# ─────────────────────────────────────────────────────────────────────────────

const _SFMIN = 2.2250738585072014e-308      # DLAMCH('S')
const _EPS = 2.0^-53                         # DLAMCH('E')
const _PREC = 2.0^-52                        # DLAMCH('P')
const _HUGE = 1.7976931348623157e308         # DLAMCH('O')

_fmax(a, b) = a >= b ? a : b      # gfortran MAX(a, b) für endliche Werte
_fmin(a, b) = a <= b ? a : b

# ── Cholesky ──────────────────────────────────────────────────────────────

"Rekursive Cholesky-Zerlegung (DPOTRF2); A in place; liefert INFO."
function dpotrf2(uplo::Char, A::_AM)
    n = size(A, 1)
    n == 0 && return 0
    if n == 1
        a = A[1, 1]
        (a <= 0.0 || isnan(a)) && return 1
        A[1, 1] = sqrt(a)
        return 0
    end
    n1 = n ÷ 2
    iinfo = dpotrf2(uplo, view(A, 1:n1, 1:n1))
    iinfo != 0 && return iinfo
    if _up(uplo) == 'U'
        dtrsm('L', 'U', 'T', 'N', 1.0, view(A, 1:n1, 1:n1), view(A, 1:n1, n1+1:n))
        dsyrk('U', 'T', -1.0, view(A, 1:n1, n1+1:n), 1.0, view(A, n1+1:n, n1+1:n))
    else
        dtrsm('R', 'L', 'T', 'N', 1.0, view(A, 1:n1, 1:n1), view(A, n1+1:n, 1:n1))
        dsyrk('L', 'N', -1.0, view(A, n1+1:n, 1:n1), 1.0, view(A, n1+1:n, n1+1:n))
    end
    iinfo = dpotrf2(uplo, view(A, n1+1:n, n1+1:n))
    iinfo != 0 && return iinfo + n1
    return 0
end

"Cholesky-Zerlegung (DPOTRF, Blockgröße 64 wie ILAENV); liefert INFO."
function dpotrf(uplo::Char, A::_AM; nb::Int = 64)
    n = size(A, 1)
    n == 0 && return 0
    (nb <= 1 || nb >= n) && return dpotrf2(uplo, A)
    up = _up(uplo) == 'U'
    for j in 1:nb:n
        jb = min(nb, n - j + 1)
        J = j:j+jb-1
        if up
            dsyrk('U', 'T', -1.0, view(A, 1:j-1, J), 1.0, view(A, J, J))
            info = dpotrf2('U', view(A, J, J))
            info != 0 && return info + j - 1
            if j + jb <= n
                dgemm('T', 'N', -1.0, view(A, 1:j-1, J), view(A, 1:j-1, j+jb:n), 1.0, view(A, J, j+jb:n))
                dtrsm('L', 'U', 'T', 'N', 1.0, view(A, J, J), view(A, J, j+jb:n))
            end
        else
            dsyrk('L', 'N', -1.0, view(A, J, 1:j-1), 1.0, view(A, J, J))
            info = dpotrf2('L', view(A, J, J))
            info != 0 && return info + j - 1
            if j + jb <= n
                dgemm('N', 'T', -1.0, view(A, j+jb:n, 1:j-1), view(A, J, 1:j-1), 1.0, view(A, j+jb:n, J))
                dtrsm('R', 'L', 'T', 'N', 1.0, view(A, J, J), view(A, j+jb:n, J))
            end
        end
    end
    return 0
end

# ── LU ────────────────────────────────────────────────────────────────────

"Zeilenvertauschungen (DLASWP); k1, k2, ipiv 1-basiert."
function dlaswp(A::_AM, k1::Int, k2::Int, ipiv::AbstractVector{Int}, incx::Int = 1)
    size(A, 2) == 0 && return nothing
    rng = incx > 0 ? (k1:k2) : (k2:-1:k1)
    nc = size(A, 2)
    @inbounds for i in rng
        ip = ipiv[i]
        if ip != i
            for c in 1:nc
                t = A[i, c]; A[i, c] = A[ip, c]; A[ip, c] = t
            end
        end
    end
    nothing
end

"Rekursive LU-Zerlegung mit Zeilenpivotisierung (DGETRF2); INFO."
function dgetrf2(A::_AM, ipiv::AbstractVector{Int})
    m, n = size(A)
    (m == 0 || n == 0) && return 0
    info = 0
    if m == 1
        ipiv[1] = 1
        A[1, 1] == 0.0 && (info = 1)
    elseif n == 1
        i = idamax(view(A, :, 1))
        ipiv[1] = i
        if A[i, 1] != 0.0
            if i != 1
                t = A[1, 1]; A[1, 1] = A[i, 1]; A[i, 1] = t
            end
            if abs(A[1, 1]) >= _SFMIN
                dscal(1.0 / A[1, 1], view(A, 2:m, 1))
            else
                for r in 2:m
                    A[r, 1] = A[r, 1] / A[1, 1]
                end
            end
        else
            info = 1
        end
    else
        mn = min(m, n)
        n1 = mn ÷ 2
        iinfo = dgetrf2(view(A, :, 1:n1), view(ipiv, 1:n1))
        (info == 0 && iinfo > 0) && (info = iinfo)
        dlaswp(view(A, :, n1+1:n), 1, n1, ipiv)
        dtrsm('L', 'L', 'N', 'U', 1.0, view(A, 1:n1, 1:n1), view(A, 1:n1, n1+1:n))
        dgemm('N', 'N', -1.0, view(A, n1+1:m, 1:n1), view(A, 1:n1, n1+1:n), 1.0, view(A, n1+1:m, n1+1:n))
        iinfo = dgetrf2(view(A, n1+1:m, n1+1:n), view(ipiv, n1+1:mn))
        (info == 0 && iinfo > 0) && (info = iinfo + n1)
        for i in n1+1:mn
            ipiv[i] += n1
        end
        dlaswp(view(A, :, 1:n1), n1 + 1, mn, ipiv)
    end
    return info
end

"LU-Zerlegung (DGETRF, Blockgröße 64); ipiv 1-basiert; INFO."
function dgetrf(A::_AM, ipiv::AbstractVector{Int}; nb::Int = 64)
    m, n = size(A)
    (m == 0 || n == 0) && return 0
    mn = min(m, n)
    (nb <= 1 || nb >= mn) && return dgetrf2(A, ipiv)
    info = 0
    for j in 1:nb:mn
        jb = min(mn - j + 1, nb)
        iinfo = dgetrf2(view(A, j:m, j:j+jb-1), view(ipiv, j:j+jb-1))
        (info == 0 && iinfo > 0) && (info = iinfo + j - 1)
        for i in j:min(m, j + jb - 1)
            ipiv[i] += j - 1
        end
        dlaswp(view(A, :, 1:j-1), j, j + jb - 1, ipiv)
        if j + jb <= n
            dlaswp(view(A, :, j+jb:n), j, j + jb - 1, ipiv)
            dtrsm('L', 'L', 'N', 'U', 1.0, view(A, j:j+jb-1, j:j+jb-1), view(A, j:j+jb-1, j+jb:n))
            if j + jb <= m
                dgemm('N', 'N', -1.0, view(A, j+jb:m, j:j+jb-1), view(A, j:j+jb-1, j+jb:n), 1.0,
                      view(A, j+jb:m, j+jb:n))
            end
        end
    end
    return info
end

"Löst mit der LU-Zerlegung (DGETRS); Bm in place."
function dgetrs(trans::Char, A::_AM, ipiv::AbstractVector{Int}, Bm::_AM)
    n = size(A, 1)
    (n == 0 || size(Bm, 2) == 0) && return nothing
    if _up(trans) == 'N'
        dlaswp(Bm, 1, n, ipiv, 1)
        dtrsm('L', 'L', 'N', 'U', 1.0, A, Bm)
        dtrsm('L', 'U', 'N', 'N', 1.0, A, Bm)
    else
        dtrsm('L', 'U', 'T', 'N', 1.0, A, Bm)
        dtrsm('L', 'L', 'T', 'U', 1.0, A, Bm)
        dlaswp(Bm, 1, n, ipiv, -1)
    end
    nothing
end

"DGESV: A (LU) und Bm (Lösung) in place; INFO."
function dgesv(A::_AM, Bm::_AM, ipiv::AbstractVector{Int})
    info = dgetrf(A, ipiv)
    info == 0 && dgetrs('N', A, ipiv, Bm)
    return info
end

# ── Normen und Konditionsschätzung ─────────────────────────────────────────

function dlange(norm::Char, A::_AM)
    m, n = size(A)
    min(m, n) == 0 && return 0.0
    c = _up(norm)
    value = 0.0
    if c == 'M'
        for j in 1:n, i in 1:m
            t = abs(A[i, j])
            (value < t || isnan(t)) && (value = t)
        end
    elseif c == 'O' || c == '1'
        for j in 1:n
            s = 0.0
            for i in 1:m
                s = s + abs(A[i, j])
            end
            (value < s || isnan(s)) && (value = s)
        end
    elseif c == 'I'
        work = zeros(m)
        for j in 1:n, i in 1:m
            work[i] = work[i] + abs(A[i, j])
        end
        for t in work
            (value < t || isnan(t)) && (value = t)
        end
    else
        error("dlange: Norm $norm nicht portiert")
    end
    return value
end

"`x := x / sa` ohne Über-/Unterlauf (DRSCL)."
function drscl(sa::Float64, x::_AV)
    length(x) <= 0 && return nothing
    smlnum = _SFMIN
    bignum = 1.0 / smlnum
    cden = sa
    cnum = 1.0
    while true
        cden1 = cden * smlnum
        cnum1 = cnum / bignum
        if abs(cden1) > abs(cnum) && cnum != 0.0
            mul = smlnum; done = false; cden = cden1
        elseif abs(cnum1) > abs(cden)
            mul = bignum; done = false; cnum = cnum1
        else
            mul = cnum / cden; done = true
        end
        dscal(mul, x)
        done && return nothing
    end
end

"Dreieckslöser mit Skalierung gegen Überlauf (DLATRS); x, cnorm in place; liefert scale."
function dlatrs(uplo::Char, trans::Char, diag::Char, normin::Char, A::_AM, x::_AV, cnorm::_AV)
    n = size(A, 1)
    upper = _up(uplo) == 'U'
    notran = _up(trans) == 'N'
    nounit = _up(diag) == 'N'
    scale = 1.0
    n == 0 && return scale
    smlnum = _SFMIN / _PREC
    bignum = 1.0 / smlnum
    if _up(normin) == 'N'
        if upper
            for j in 1:n
                cnorm[j] = dasum(view(A, 1:j-1, j))
            end
        else
            for j in 1:n-1
                cnorm[j] = dasum(view(A, j+1:n, j))
            end
            cnorm[n] = 0.0
        end
    end
    imax = idamax(cnorm)
    tmax = cnorm[imax]
    if tmax <= bignum
        tscal = 1.0
    else
        if tmax <= _HUGE
            tscal = 1.0 / (smlnum * tmax)
            dscal(tscal, cnorm)
        else
            tmax = 0.0
            if upper
                for j in 2:n
                    tmax = _fmax(dlange('M', view(A, 1:j-1, j:j)), tmax)
                end
            else
                for j in 1:n-1
                    tmax = _fmax(dlange('M', view(A, j+1:n, j:j)), tmax)
                end
            end
            if tmax <= _HUGE
                tscal = 1.0 / (smlnum * tmax)
                for j in 1:n
                    if cnorm[j] <= _HUGE
                        cnorm[j] = cnorm[j] * tscal
                    else
                        cnorm[j] = 0.0
                        for i in (upper ? (1:j-1) : (j+1:n))
                            cnorm[j] = cnorm[j] + tscal * abs(A[i, j])
                        end
                    end
                end
            else
                dtrsv(uplo, trans, diag, A, x)
                return scale
            end
        end
    end
    j = idamax(x)
    xmax = abs(x[j])
    xbnd = xmax
    if notran
        jr = upper ? (n:-1:1) : (1:n)
        if tscal != 1.0
            grow = 0.0
        elseif nounit
            grow = 1.0 / _fmax(xbnd, smlnum)
            xbnd = grow
            stopped = false
            for j in jr
                if grow <= smlnum
                    stopped = true; break
                end
                tjj = abs(A[j, j])
                xbnd = _fmin(xbnd, _fmin(1.0, tjj) * grow)
                if tjj + cnorm[j] >= smlnum
                    grow = grow * (tjj / (tjj + cnorm[j]))
                else
                    grow = 0.0
                end
            end
            stopped || (grow = xbnd)
        else
            grow = _fmin(1.0, 1.0 / _fmax(xbnd, smlnum))
            for j in jr
                grow <= smlnum && break
                grow = grow * (1.0 / (1.0 + cnorm[j]))
            end
        end
    else
        jr = upper ? (1:n) : (n:-1:1)
        if tscal != 1.0
            grow = 0.0
        elseif nounit
            grow = 1.0 / _fmax(xbnd, smlnum)
            xbnd = grow
            stopped = false
            for j in jr
                if grow <= smlnum
                    stopped = true; break
                end
                xj = 1.0 + cnorm[j]
                grow = _fmin(grow, xbnd / xj)
                tjj = abs(A[j, j])
                xj > tjj && (xbnd = xbnd * (tjj / xj))
            end
            stopped || (grow = _fmin(grow, xbnd))
        else
            grow = _fmin(1.0, 1.0 / _fmax(xbnd, smlnum))
            for j in jr
                grow <= smlnum && break
                xj = 1.0 + cnorm[j]
                grow = grow / xj
            end
        end
    end
    if grow * tscal > smlnum
        dtrsv(uplo, trans, diag, A, x)
    else
        if xmax > bignum
            scale = bignum / xmax
            dscal(scale, x)
            xmax = bignum
        end
        if notran
            for j in jr
                xj = abs(x[j])
                skip = false
                if nounit
                    tjjs = A[j, j] * tscal
                else
                    tjjs = tscal
                    tscal == 1.0 && (skip = true)
                end
                if !skip
                    tjj = abs(tjjs)
                    if tjj > smlnum
                        if tjj < 1.0 && xj > tjj * bignum
                            rec = 1.0 / xj
                            dscal(rec, x)
                            scale = scale * rec
                            xmax = xmax * rec
                        end
                        x[j] = x[j] / tjjs
                        xj = abs(x[j])
                    elseif tjj > 0.0
                        if xj > tjj * bignum
                            rec = (tjj * bignum) / xj
                            cnorm[j] > 1.0 && (rec = rec / cnorm[j])
                            dscal(rec, x)
                            scale = scale * rec
                            xmax = xmax * rec
                        end
                        x[j] = x[j] / tjjs
                        xj = abs(x[j])
                    else
                        fill!(x, 0.0)
                        x[j] = 1.0
                        xj = 1.0
                        scale = 0.0
                        xmax = 0.0
                    end
                end
                if xj > 1.0
                    rec = 1.0 / xj
                    if cnorm[j] > (bignum - xmax) * rec
                        rec = rec * 0.5
                        dscal(rec, x)
                        scale = scale * rec
                    end
                elseif xj * cnorm[j] > (bignum - xmax)
                    dscal(0.5, x)
                    scale = scale * 0.5
                end
                if upper
                    if j > 1
                        daxpy(-x[j] * tscal, view(A, 1:j-1, j), view(x, 1:j-1))
                        i = idamax(view(x, 1:j-1))
                        xmax = abs(x[i])
                    end
                else
                    if j < n
                        daxpy(-x[j] * tscal, view(A, j+1:n, j), view(x, j+1:n))
                        i = j + idamax(view(x, j+1:n))
                        xmax = abs(x[i])
                    end
                end
            end
        else
            for j in jr
                xj = abs(x[j])
                uscal = tscal
                rec = 1.0 / _fmax(xmax, 1.0)
                tjjs = 0.0
                if cnorm[j] > (bignum - xj) * rec
                    rec = rec * 0.5
                    tjjs = nounit ? A[j, j] * tscal : tscal
                    tjj = abs(tjjs)
                    if tjj > 1.0
                        rec = _fmin(1.0, rec * tjj)
                        uscal = uscal / tjjs
                    end
                    if rec < 1.0
                        dscal(rec, x)
                        scale = scale * rec
                        xmax = xmax * rec
                    end
                end
                sumj = 0.0
                if uscal == 1.0
                    if upper
                        sumj = ddot(view(A, 1:j-1, j), view(x, 1:j-1))
                    elseif j < n
                        sumj = ddot(view(A, j+1:n, j), view(x, j+1:n))
                    end
                else
                    for i in (upper ? (1:j-1) : (j+1:n))
                        sumj = sumj + (A[i, j] * uscal) * x[i]
                    end
                end
                if uscal == tscal
                    x[j] = x[j] - sumj
                    xj = abs(x[j])
                    skip = false
                    if nounit
                        tjjs = A[j, j] * tscal
                    else
                        tjjs = tscal
                        tscal == 1.0 && (skip = true)
                    end
                    if !skip
                        tjj = abs(tjjs)
                        if tjj > smlnum
                            if tjj < 1.0 && xj > tjj * bignum
                                rec = 1.0 / xj
                                dscal(rec, x)
                                scale = scale * rec
                                xmax = xmax * rec
                            end
                            x[j] = x[j] / tjjs
                        elseif tjj > 0.0
                            if xj > tjj * bignum
                                rec = (tjj * bignum) / xj
                                dscal(rec, x)
                                scale = scale * rec
                                xmax = xmax * rec
                            end
                            x[j] = x[j] / tjjs
                        else
                            fill!(x, 0.0)
                            x[j] = 1.0
                            scale = 0.0
                            xmax = 0.0
                        end
                    end
                else
                    x[j] = x[j] / tjjs - sumj
                end
                xmax = _fmax(xmax, abs(x[j]))
            end
        end
        scale = scale / tscal
    end
    tscal != 1.0 && dscal(1.0 / tscal, cnorm)
    return scale
end

"Zustand von DLACN2 (umgekehrte Kommunikation)."
mutable struct _Lacn2
    n::Int
    v::Vector{Float64}
    isgn::Vector{Int}
    isave::Vector{Int}      # isave[1] Zustand, isave[2] j (1-basiert), isave[3] iter
    est::Float64
end
_Lacn2(n) = _Lacn2(n, zeros(n), zeros(Int, n), [0, 0, 0], 0.0)

_sgn1(v) = v >= 0.0 ? 1.0 : -1.0

function _lacn2_step!(st::_Lacn2, x::Vector{Float64}, kase::Int)
    n = st.n
    is = st.isave
    if kase == 0
        fill!(x, 1.0 / Float64(n))
        is[1] = 1
        return 1
    end
    s = is[1]
    if s == 1
        if n == 1
            st.v[1] = x[1]
            st.est = abs(st.v[1])
            return 0
        end
        st.est = dasum(x)
        for i in 1:n
            x[i] = _sgn1(x[i]); st.isgn[i] = Int(x[i])
        end
        is[1] = 2
        return 2
    elseif s == 2
        is[2] = idamax(x)
        is[3] = 2
        return _lacn2_l50!(st, x)
    elseif s == 3
        copyto!(st.v, x)
        estold = st.est
        st.est = dasum(st.v)
        same = all(i -> Int(_sgn1(x[i])) == st.isgn[i], 1:n)
        same && return _lacn2_l120!(st, x)
        st.est <= estold && return _lacn2_l120!(st, x)
        for i in 1:n
            x[i] = _sgn1(x[i]); st.isgn[i] = Int(x[i])
        end
        is[1] = 4
        return 2
    elseif s == 4
        jlast = is[2]
        is[2] = idamax(x)
        if x[jlast] != abs(x[is[2]]) && is[3] < 5
            is[3] += 1
            return _lacn2_l50!(st, x)
        end
        return _lacn2_l120!(st, x)
    elseif s == 5
        temp = 2.0 * (dasum(x) / Float64(3 * n))
        if temp > st.est
            copyto!(st.v, x)
            st.est = temp
        end
        return 0
    end
    error("dlacn2")
end

function _lacn2_l50!(st, x)
    fill!(x, 0.0)
    x[st.isave[2]] = 1.0
    st.isave[1] = 3
    return 1
end

function _lacn2_l120!(st, x)
    n = st.n
    altsgn = 1.0
    for i in 1:n
        x[i] = altsgn * (1.0 + Float64(i - 1) / Float64(n - 1))
        altsgn = -altsgn
    end
    st.isave[1] = 5
    return 1
end

"Kehrwert der Konditionszahl aus der LU-Zerlegung A (DGECON)."
function dgecon(norm::Char, A::_AM, anorm::Float64)
    n = size(A, 1)
    onenrm = norm == '1' || norm == 'O' || norm == 'o'
    n == 0 && return 1.0
    anorm == 0.0 && return 0.0
    isnan(anorm) && return anorm
    anorm > _HUGE && return 0.0
    smlnum = _SFMIN
    ainvnm = 0.0
    normin = 'N'
    kase1 = onenrm ? 1 : 2
    kase = 0
    x = zeros(n); cl = zeros(n); cu = zeros(n)
    st = _Lacn2(n)
    while true
        kase = _lacn2_step!(st, x, kase)
        ainvnm = st.est
        kase == 0 && break
        if kase == kase1
            sl = dlatrs('L', 'N', 'U', normin, A, x, cl)
            su = dlatrs('U', 'N', 'N', normin, A, x, cu)
        else
            su = dlatrs('U', 'T', 'N', normin, A, x, cu)
            sl = dlatrs('L', 'T', 'U', normin, A, x, cl)
        end
        scale = sl * su
        normin = 'Y'
        if scale != 1.0
            ix = idamax(x)
            (scale < abs(x[ix]) * smlnum || scale == 0.0) && return 0.0
            drscl(scale, x)
        end
    end
    ainvnm != 0.0 && return (1.0 / ainvnm) / anorm
    return 0.0
end

# ── Inverse aus Cholesky ──────────────────────────────────────────────────

function dtrti2(uplo::Char, diag::Char, A::_AM)
    n = size(A, 1)
    nounit = _up(diag) == 'N'
    if _up(uplo) == 'U'
        for j in 1:n
            if nounit
                A[j, j] = 1.0 / A[j, j]
                ajj = -A[j, j]
            else
                ajj = -1.0
            end
            dtrmv('U', 'N', diag, view(A, 1:j-1, 1:j-1), view(A, 1:j-1, j))
            dscal(ajj, view(A, 1:j-1, j))
        end
    else
        for j in n:-1:1
            if nounit
                A[j, j] = 1.0 / A[j, j]
                ajj = -A[j, j]
            else
                ajj = -1.0
            end
            if j < n
                dtrmv('L', 'N', diag, view(A, j+1:n, j+1:n), view(A, j+1:n, j))
                dscal(ajj, view(A, j+1:n, j))
            end
        end
    end
    return 0
end

function dtrtri(uplo::Char, diag::Char, A::_AM; nb::Int = 64)
    n = size(A, 1)
    n == 0 && return 0
    if _up(diag) == 'N'
        for i in 1:n
            A[i, i] == 0.0 && return i
        end
    end
    (nb <= 1 || nb >= n) && return dtrti2(uplo, diag, A)
    if _up(uplo) == 'U'
        for j in 1:nb:n
            jb = min(nb, n - j + 1)
            J = j:j+jb-1
            dtrmm('L', 'U', 'N', diag, 1.0, view(A, 1:j-1, 1:j-1), view(A, 1:j-1, J))
            dtrsm('R', 'U', 'N', diag, -1.0, view(A, J, J), view(A, 1:j-1, J))
            dtrti2('U', diag, view(A, J, J))
        end
    else
        nn = ((n - 1) ÷ nb) * nb + 1
        for j in nn:-nb:1
            jb = min(nb, n - j + 1)
            J = j:j+jb-1
            if j + jb <= n
                dtrmm('L', 'L', 'N', diag, 1.0, view(A, j+jb:n, j+jb:n), view(A, j+jb:n, J))
                dtrsm('R', 'L', 'N', diag, -1.0, view(A, J, J), view(A, j+jb:n, J))
            end
            dtrti2('L', diag, view(A, J, J))
        end
    end
    return 0
end

function dlauu2(uplo::Char, A::_AM)
    n = size(A, 1)
    n == 0 && return nothing
    if _up(uplo) == 'U'
        for i in 1:n
            aii = A[i, i]
            if i < n
                A[i, i] = ddot(view(A, i, i:n), view(A, i, i:n))
                dgemv('N', 1.0, view(A, 1:i-1, i+1:n), view(A, i, i+1:n), aii, view(A, 1:i-1, i))
            else
                dscal(aii, view(A, 1:i, i))
            end
        end
    else
        for i in 1:n
            aii = A[i, i]
            if i < n
                A[i, i] = ddot(view(A, i:n, i), view(A, i:n, i))
                dgemv('T', 1.0, view(A, i+1:n, 1:i-1), view(A, i+1:n, i), aii, view(A, i, 1:i-1))
            else
                dscal(aii, view(A, i, 1:i))
            end
        end
    end
    nothing
end

function dlauum(uplo::Char, A::_AM; nb::Int = 64)
    n = size(A, 1)
    n == 0 && return nothing
    if nb <= 1 || nb >= n
        dlauu2(uplo, A)
        return nothing
    end
    if _up(uplo) == 'U'
        for i in 1:nb:n
            ib = min(nb, n - i + 1)
            I = i:i+ib-1
            dtrmm('R', 'U', 'T', 'N', 1.0, view(A, I, I), view(A, 1:i-1, I))
            dlauu2('U', view(A, I, I))
            if i + ib <= n
                dgemm('N', 'T', 1.0, view(A, 1:i-1, i+ib:n), view(A, I, i+ib:n), 1.0, view(A, 1:i-1, I))
                dsyrk('U', 'N', 1.0, view(A, I, i+ib:n), 1.0, view(A, I, I))
            end
        end
    else
        for i in 1:nb:n
            ib = min(nb, n - i + 1)
            I = i:i+ib-1
            dtrmm('L', 'L', 'T', 'N', 1.0, view(A, I, I), view(A, I, 1:i-1))
            dlauu2('L', view(A, I, I))
            if i + ib <= n
                dgemm('T', 'N', 1.0, view(A, i+ib:n, I), view(A, i+ib:n, 1:i-1), 1.0, view(A, I, 1:i-1))
                dsyrk('L', 'T', 1.0, view(A, i+ib:n, I), 1.0, view(A, I, I))
            end
        end
    end
    nothing
end

function dpotri(uplo::Char, A::_AM)
    n = size(A, 1)
    n == 0 && return 0
    info = dtrtri(uplo, 'N', A)
    info > 0 && return info
    dlauum(uplo, A)
    return 0
end

# ── Symmetrische Eigenwerte (nur Werte) ──────────────────────────────────

function dlansy(norm::Char, uplo::Char, A::_AM)
    n = size(A, 1)
    n == 0 && return 0.0
    _up(norm) == 'M' || error("dlansy: Norm $norm nicht portiert")
    value = 0.0
    lower = _up(uplo) != 'U'
    for j in 1:n
        for i in (lower ? (j:n) : (1:j))
            s = abs(A[i, j])
            isnan(s) && return NaN
            value < s && (value = s)
        end
    end
    return value
end

function dlapy2(x::Float64, y::Float64)
    xn = isnan(x); yn = isnan(y)
    r = 0.0
    xn && (r = x)
    yn && (r = y)
    if !(xn || yn)
        xa = abs(x); ya = abs(y)
        w = _fmax(xa, ya)
        z = _fmin(xa, ya)
        if z == 0.0 || w > _HUGE
            r = w
        else
            q = z / w
            r = w * sqrt(1.0 + q * q)
        end
    end
    return r
end

"Householder-Reflektor (DLARFG); x in place; liefert (beta, tau)."
function dlarfg(n::Int, alpha::Float64, x::_AV)
    n <= 1 && return alpha, 0.0
    xnorm = dnrm2(x)
    xnorm == 0.0 && return alpha, 0.0
    beta = -copysign(dlapy2(alpha, xnorm), alpha)
    safmin = _SFMIN / _EPS
    knt = 0
    if abs(beta) < safmin
        rsafmn = 1.0 / safmin
        while true
            knt += 1
            dscal(rsafmn, x)
            beta = beta * rsafmn
            alpha = alpha * rsafmn
            (abs(beta) < safmin && knt < 20) || break
        end
        xnorm = dnrm2(x)
        beta = -copysign(dlapy2(alpha, xnorm), alpha)
    end
    tau = (beta - alpha) / beta
    dscal(1.0 / (alpha - beta), x)
    for _ in 1:knt
        beta = beta * safmin
    end
    return beta, tau
end

function _dsytd2_lower!(A::_AM, d::_AV, e::_AV, tau::_AV)
    n = size(A, 1)
    n <= 0 && return nothing
    for i in 1:n-1
        beta, taui = dlarfg(n - i, A[i+1, i], view(A, min(i + 2, n + 1):n, i))
        A[i+1, i] = beta
        e[i] = A[i+1, i]
        if taui != 0.0
            A[i+1, i] = 1.0
            v = view(A, i+1:n, i)
            w = view(tau, i:n-1)
            dsymv('L', taui, view(A, i+1:n, i+1:n), v, 0.0, w)
            alpha = -((0.5 * taui) * ddot(w, v))
            daxpy(alpha, v, w)
            dsyr2('L', -1.0, v, w, view(A, i+1:n, i+1:n))
            A[i+1, i] = e[i]
        end
        d[i] = A[i, i]
        tau[i] = taui
    end
    d[n] = A[n, n]
    nothing
end

function _dsytd2_upper!(A::_AM, d::_AV, e::_AV, tau::_AV)
    n = size(A, 1)
    n <= 0 && return nothing
    for I in n-1:-1:1
        beta, taui = dlarfg(I, A[I, I+1], view(A, 1:I-1, I+1))
        A[I, I+1] = beta
        e[I] = A[I, I+1]
        if taui != 0.0
            A[I, I+1] = 1.0
            v = view(A, 1:I, I+1)
            w = view(tau, 1:I)
            dsymv('U', taui, view(A, 1:I, 1:I), v, 0.0, w)
            alpha = -((0.5 * taui) * ddot(w, v))
            daxpy(alpha, v, w)
            dsyr2('U', -1.0, v, w, view(A, 1:I, 1:I))
            A[I, I+1] = e[I]
        end
        d[I+1] = A[I+1, I+1]
        tau[I] = taui
    end
    d[1] = A[1, 1]
    nothing
end

function _dlatrd_lower!(A::_AM, nb::Int, e::_AV, tau::_AV, W::_AM)
    n = size(A, 1)
    n <= 0 && return nothing
    for i in 1:nb
        dgemv('N', -1.0, view(A, i:n, 1:i-1), view(W, i, 1:i-1), 1.0, view(A, i:n, i))
        dgemv('N', -1.0, view(W, i:n, 1:i-1), view(A, i, 1:i-1), 1.0, view(A, i:n, i))
        if i < n
            beta, t = dlarfg(n - i, A[i+1, i], view(A, min(i + 2, n + 1):n, i))
            A[i+1, i] = beta
            tau[i] = t
            e[i] = A[i+1, i]
            A[i+1, i] = 1.0
            v = view(A, i+1:n, i)
            wcol = view(W, i+1:n, i)
            dsymv('L', 1.0, view(A, i+1:n, i+1:n), v, 0.0, wcol)
            dgemv('T', 1.0, view(W, i+1:n, 1:i-1), v, 0.0, view(W, 1:i-1, i))
            dgemv('N', -1.0, view(A, i+1:n, 1:i-1), view(W, 1:i-1, i), 1.0, wcol)
            dgemv('T', 1.0, view(A, i+1:n, 1:i-1), v, 0.0, view(W, 1:i-1, i))
            dgemv('N', -1.0, view(W, i+1:n, 1:i-1), view(W, 1:i-1, i), 1.0, wcol)
            dscal(tau[i], wcol)
            alpha = -((0.5 * tau[i]) * ddot(wcol, v))
            daxpy(alpha, v, wcol)
        end
    end
    nothing
end

"Reduktion auf Tridiagonalform (DSYTRD; uplo = 'L' blockweise)."
function dsytrd(uplo::Char, A::_AM, d::_AV, e::_AV, tau::_AV, lwork::Int)
    n = size(A, 1)
    n == 0 && return nothing
    nb = 32
    nx = n
    ldwork = n
    if 1 < nb < n
        nx = max(nb, 32)
        if nx < n
            iws = ldwork * nb
            if lwork < iws
                nb = max(lwork ÷ ldwork, 1)
                nb < 2 && (nx = n)
            end
        else
            nx = n
        end
    else
        nb = 1
    end
    if _up(uplo) == 'U'
        nx < n && error("dsytrd: Blockfassung nur für uplo='L'")
        _dsytd2_upper!(A, d, e, tau)
        return nothing
    end
    i = 1
    if n - nx >= 1
        for ii in 1:nb:(n - nx)
            i = ii
            W = zeros(n - i + 1, nb)
            _dlatrd_lower!(view(A, i:n, i:n), nb, view(e, i:n), view(tau, i:n), W)
            dsyr2k('L', 'N', -1.0, view(A, i+nb:n, i:i+nb-1), view(W, nb+1:size(W, 1), :), 1.0,
                   view(A, i+nb:n, i+nb:n))
            for j in i:i+nb-1
                A[j+1, j] = e[j]
                d[j] = A[j, j]
            end
        end
        i = i + nb
    end
    _dsytd2_lower!(view(A, i:n, i:n), view(d, i:n), view(e, i:n), view(tau, i:n))
    nothing
end

function dlae2(a::Float64, b::Float64, c::Float64)
    sm = a + c
    df = a - c
    adf = abs(df)
    tb = b + b
    ab = abs(tb)
    if abs(a) > abs(c)
        acmx, acmn = a, c
    else
        acmx, acmn = c, a
    end
    if adf > ab
        q = ab / adf
        rt = adf * sqrt(1.0 + q * q)
    elseif adf < ab
        q = adf / ab
        rt = ab * sqrt(1.0 + q * q)
    else
        rt = ab * sqrt(2.0)
    end
    if sm < 0.0
        rt1 = 0.5 * (sm - rt)
        rt2 = (acmx / rt1) * acmn - (b / rt1) * b
    elseif sm > 0.0
        rt1 = 0.5 * (sm + rt)
        rt2 = (acmx / rt1) * acmn - (b / rt1) * b
    else
        rt1 = 0.5 * rt
        rt2 = -0.5 * rt
    end
    return rt1, rt2
end

"DLASCL Typ 'G' auf einen Vektor (in place)."
function _dlascl_g!(cfrom::Float64, cto::Float64, v::_AV)
    length(v) == 0 && return nothing
    smlnum = _SFMIN
    bignum = 1.0 / smlnum
    cfromc = cfrom
    ctoc = cto
    while true
        cfrom1 = cfromc * smlnum
        if cfrom1 == cfromc
            mul = ctoc / cfromc; done = true
        else
            cto1 = ctoc / bignum
            if cto1 == ctoc
                mul = ctoc; done = true; cfromc = 1.0
            elseif abs(cfrom1) > abs(ctoc) && ctoc != 0.0
                mul = smlnum; done = false; cfromc = cfrom1
            elseif abs(cto1) > abs(cfromc)
                mul = bignum; done = false; ctoc = cto1
            else
                mul = ctoc / cfromc; done = true
                mul == 1.0 && return nothing
            end
        end
        @inbounds for i in eachindex(v)
            v[i] = v[i] * mul
        end
        done && return nothing
    end
end

function _dlanst_m(d::_AV, e::_AV)
    n = length(d)
    n <= 0 && return 0.0
    anorm = abs(d[n])
    for i in 1:n-1
        s = abs(d[i])
        (anorm < s || isnan(s)) && (anorm = s)
        s = abs(e[i])
        (anorm < s || isnan(s)) && (anorm = s)
    end
    return anorm
end

"Eigenwerte einer symmetrischen Tridiagonalmatrix (DSTERF); d in place; INFO."
function dsterf!(d::_AV, e::_AV)
    n = length(d)
    n <= 1 && return 0
    D = collect(Float64, d)                 # 1-basiert
    E = vcat(collect(Float64, e[1:n-1]), 0.0)
    eps = _EPS
    eps2 = eps * eps
    safmin = _SFMIN
    safmax = 1.0 / safmin
    ssfmax = sqrt(safmax) / 3.0
    ssfmin = sqrt(safmin) / eps2
    nmaxit = n * 30
    sigma = 0.0
    jtot = 0
    l1 = 1
    while true
        if l1 > n
            sort!(D)
            copyto!(d, D)
            return 0
        end
        l1 > 1 && (E[l1-1] = 0.0)
        m = n
        for mm in l1:n-1
            if abs(E[mm]) <= (sqrt(abs(D[mm])) * sqrt(abs(D[mm+1]))) * eps
                E[mm] = 0.0
                m = mm
                break
            end
        end
        l = l1
        lsv = l
        lend = m
        lendsv = lend
        l1 = m + 1
        lend == l && continue
        anorm = _dlanst_m(view(D, l:lend), view(E, l:lend-1))
        iscale = 0
        anorm == 0.0 && continue
        if anorm > ssfmax
            iscale = 1
            _dlascl_g!(anorm, ssfmax, view(D, l:lend))
            _dlascl_g!(anorm, ssfmax, view(E, l:lend-1))
        elseif anorm < ssfmin
            iscale = 2
            _dlascl_g!(anorm, ssfmin, view(D, l:lend))
            _dlascl_g!(anorm, ssfmin, view(E, l:lend-1))
        end
        for i in l:lend-1
            E[i] = E[i] * E[i]
        end
        if abs(D[lend]) < abs(D[l])
            lend = lsv
            l = lendsv
        end
        if lend >= l
            # QL-Iteration
            while true
                m = lend
                if l != lend
                    for mm in l:lend-1
                        if abs(E[mm]) <= eps2 * abs(D[mm] * D[mm+1])
                            m = mm
                            break
                        end
                    end
                end
                m < lend && (E[m] = 0.0)
                p = D[l]
                if m == l
                    D[l] = p
                    l = l + 1
                    l <= lend && continue
                    break
                end
                if m == l + 1
                    rte = sqrt(E[l])
                    rt1, rt2 = dlae2(D[l], rte, D[l+1])
                    D[l] = rt1
                    D[l+1] = rt2
                    E[l] = 0.0
                    l = l + 2
                    l <= lend && continue
                    break
                end
                jtot == nmaxit && break
                jtot += 1
                rte = sqrt(E[l])
                sigma = (D[l+1] - p) / (2.0 * rte)
                r = dlapy2(sigma, 1.0)
                sigma = p - (rte / (sigma + copysign(r, sigma)))
                c = 1.0
                s = 0.0
                gamma = D[m] - sigma
                p = gamma * gamma
                for i in m-1:-1:l
                    bb = E[i]
                    r = p + bb
                    i != m - 1 && (E[i+1] = s * r)
                    oldc = c
                    c = p / r
                    s = bb / r
                    oldgam = gamma
                    alpha = D[i]
                    gamma = c * (alpha - sigma) - s * oldgam
                    D[i+1] = oldgam + (alpha - gamma)
                    if c != 0.0
                        p = (gamma * gamma) / c
                    else
                        p = oldc * bb
                    end
                end
                E[l] = s * p
                D[l] = sigma + gamma
            end
        else
            # QR-Iteration
            while true
                m = lend
                for mm in l:-1:lend+1
                    if abs(E[mm-1]) <= eps2 * abs(D[mm] * D[mm-1])
                        m = mm
                        break
                    end
                end
                m > lend && (E[m-1] = 0.0)
                p = D[l]
                if m == l
                    D[l] = p
                    l = l - 1
                    l >= lend && continue
                    break
                end
                if m == l - 1
                    rte = sqrt(E[l-1])
                    rt1, rt2 = dlae2(D[l], rte, D[l-1])
                    D[l] = rt1
                    D[l-1] = rt2
                    E[l-1] = 0.0
                    l = l - 2
                    l >= lend && continue
                    break
                end
                jtot == nmaxit && break
                jtot += 1
                rte = sqrt(E[l-1])
                sigma = (D[l-1] - p) / (2.0 * rte)
                r = dlapy2(sigma, 1.0)
                sigma = p - (rte / (sigma + copysign(r, sigma)))
                c = 1.0
                s = 0.0
                gamma = D[m] - sigma
                p = gamma * gamma
                for i in m:l-1
                    bb = E[i]
                    r = p + bb
                    i != m && (E[i-1] = s * r)
                    oldc = c
                    c = p / r
                    s = bb / r
                    oldgam = gamma
                    alpha = D[i+1]
                    gamma = c * (alpha - sigma) - s * oldgam
                    D[i] = oldgam + (alpha - gamma)
                    if c != 0.0
                        p = (gamma * gamma) / c
                    else
                        p = oldc * bb
                    end
                end
                E[l-1] = s * p
                D[l] = sigma + gamma
            end
        end
        iscale == 1 && _dlascl_g!(ssfmax, anorm, view(D, lsv:lendsv))
        iscale == 2 && _dlascl_g!(ssfmin, anorm, view(D, lsv:lendsv))
        jtot < nmaxit && continue
        info = count(i -> E[i] != 0.0, 1:n-1)
        copyto!(d, D)
        return info
    end
end

"Eigenwerte (aufsteigend) wie dsyevr(JOBZ='N', RANGE='A', UPLO='L'); liefert (w, info)."
function dsyevr_values(A0::AbstractMatrix)
    A = Matrix{Float64}(A0)
    n = size(A, 1)
    n == 0 && return Float64[], 0
    n == 1 && return [A[1, 1]], 0
    safmin = _SFMIN
    eps = _PREC
    smlnum = safmin / eps
    bignum = 1.0 / smlnum
    rmin = sqrt(smlnum)
    rmax = min(sqrt(bignum), 1.0 / sqrt(sqrt(safmin)))
    iscale = 0
    anrm = dlansy('M', 'L', A)
    sigma = 1.0
    if 0.0 < anrm < rmin
        iscale = 1
        sigma = rmin / anrm
    elseif anrm > rmax
        iscale = 1
        sigma = rmax / anrm
    end
    if iscale == 1
        for j in 1:n, i in j:n
            A[i, j] = A[i, j] * sigma
        end
    end
    lwork = max(33 * n, 26 * n)
    llwork = lwork - 5 * n
    d = zeros(n); e = zeros(n); tau = zeros(n)
    dsytrd('L', A, d, e, tau, llwork)
    w = copy(d)
    ee = e[1:n-1]
    info = dsterf!(w, ee)
    if iscale == 1
        f = 1.0 / sigma
        for i in eachindex(w)
            w[i] = w[i] * f
        end
    end
    return w, info
end

# ── System-LAPACK (ccall) ────────────────────────────────────────────────

const _SYSLAPACK = Ref{Any}(false)
const _LAPACK_WARNED = Ref(false)
const _LAPACK_LOCK = ReentrantLock()     # einmaliges Laden, auch aus RParallel-Aufgaben

"Lädt die Referenz-LAPACK des Systems (Handle oder `nothing`)."
function system_lapack()
    _SYSLAPACK[] === false || return _SYSLAPACK[]
    return lock(_system_lapack!, _LAPACK_LOCK)
end
function _system_lapack!()
    _SYSLAPACK[] === false || return _SYSLAPACK[]
    cands = String[]
    env = SimLev.REnv.lapack_path()
    isempty(env) || push!(cands, env)
    append!(cands, ["/usr/lib/x86_64-linux-gnu/lapack/liblapack.so.3",
                    "/usr/lib/aarch64-linux-gnu/lapack/liblapack.so.3",
                    "/usr/lib64/liblapack.so.3", "/usr/lib/liblapack.so.3", "liblapack.so.3"])
    lib = nothing
    for c in cands
        h = Libc.Libdl.dlopen(c, Libc.Libdl.RTLD_LAZY | Libc.Libdl.RTLD_LOCAL | Libc.Libdl.RTLD_DEEPBIND; throw_error = false)
        if h !== nothing && Libc.Libdl.dlsym(h, :dsyevr_; throw_error = false) !== nothing
            lib = h
            break
        end
        if !isempty(env) && c == env
            @warn "SIMLEV_LAPACK=$env: keine LAPACK-Bibliothek mit dsyevr_ ladbar; suche die System-LAPACK."
        end
    end
    _SYSLAPACK[] = lib
    return lib
end

function _sys_dsyevr(lib, A0::AbstractMatrix, jobz::Char)
    n = size(A0, 1)
    a = Matrix{Float64}(A0)
    w = zeros(n)
    z = jobz == 'V' ? zeros(n, n) : zeros(1, 1)
    isuppz = zeros(Int32, max(1, 2 * n))
    f = Libc.Libdl.dlsym(lib, :dsyevr_)
    nn = Ref{Int32}(n); vl = Ref(0.0); vu = Ref(0.0); il = Ref{Int32}(0); iu = Ref{Int32}(0)
    abstol = Ref(0.0); m = Ref{Int32}(0); info = Ref{Int32}(0)
    ldz = Ref{Int32}(jobz == 'V' ? n : 1)
    cj = Ref{UInt8}(UInt8(jobz)); ca = Ref{UInt8}(UInt8('A')); cu = Ref{UInt8}(UInt8('L'))
    call(work, lw, iwork, liw) = ccall(f, Cvoid,
        (Ref{UInt8}, Ref{UInt8}, Ref{UInt8}, Ref{Int32}, Ptr{Float64}, Ref{Int32}, Ref{Float64}, Ref{Float64},
         Ref{Int32}, Ref{Int32}, Ref{Float64}, Ref{Int32}, Ptr{Float64}, Ptr{Float64}, Ref{Int32}, Ptr{Int32},
         Ptr{Float64}, Ref{Int32}, Ptr{Int32}, Ref{Int32}, Ref{Int32}, Csize_t, Csize_t, Csize_t),
        cj, ca, cu, nn, a, nn, vl, vu, il, iu, abstol, m, w, z, ldz, isuppz, work, lw, iwork, liw, info, 1, 1, 1)
    tmp = zeros(1); itmp = zeros(Int32, 1)
    call(tmp, Ref{Int32}(-1), itmp, Ref{Int32}(-1))
    info[] != 0 && return nothing, nothing, Int(info[])
    lwork = Int(tmp[1]); liwork = Int(itmp[1])
    work = zeros(max(1, lwork)); iwork = zeros(Int32, max(1, liwork))
    call(work, Ref{Int32}(lwork), iwork, Ref{Int32}(liwork))
    return w, (jobz == 'V' ? z : nothing), Int(info[])
end

function _warn_fallback(name)
    if lock(() -> (w = _LAPACK_WARNED[]; _LAPACK_WARNED[] = true; !w), _LAPACK_LOCK)
        @warn "eigen(): keine System-LAPACK gefunden, Eigenvektoren über $name berechnet (nicht bitgleich zu R; Pfad zur Referenz-LAPACK über SIMLEV_LAPACK setzen)."
    end
end

"""
    dsyevr(A; only_values = false, backend = "auto")

Symmetrische Eigenzerlegung wie R's `La_rs` (dsyevr, uplo 'L'). Liefert
`(werte_aufsteigend, vektoren_oder_nothing, info, backend)`. `backend`:
"auto" (Werte: reiner Port; Vektoren: System-LAPACK, sonst LinearAlgebra),
"port", "system", "fallback".
"""
function dsyevr(A::AbstractMatrix; only_values::Bool = false, backend::String = "auto")
    n = size(A, 1)
    if backend in ("auto", "port") && only_values
        w, info = dsyevr_values(A)
        (info == 0 || backend == "port") && return w, nothing, info, "port"
    end
    if backend in ("auto", "system")
        lib = system_lapack()
        if lib !== nothing
            w, z, info = _sys_dsyevr(lib, A, only_values ? 'N' : 'V')
            return w, z, info, "system"
        end
        backend == "system" && error("System-LAPACK nicht gefunden")
    end
    # Ersatzweg: nicht bitgleich garantiert
    L = Matrix{Float64}(undef, n, n)
    for j in 1:n, i in 1:n
        L[i, j] = i >= j ? Float64(A[i, j]) : Float64(A[j, i])
    end
    _warn_fallback("LinearAlgebra")
    LA = Base.require(Base.PkgId(Base.UUID("37e2e46d-f89d-539d-b4ee-838fcccc9c8e"), "LinearAlgebra"))
    E = Base.invokelatest(LA.eigen, Base.invokelatest(LA.Symmetric, L))
    return collect(E.values), (only_values ? nothing : Matrix(E.vectors)), 0, "LinearAlgebra"
end
