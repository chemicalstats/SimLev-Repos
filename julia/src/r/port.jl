# ─────────────────────────────────────────────────────────────────────────────
# RPort – PORT-Bibliothek für nlminb (R 4.3.3: src/library/stats/src/port.c
# und die benötigten Routinen aus portsrc.f), bitgleich.
#
# Vorlage: python/simlev/_r/port.py. Konventionen:
# * Felder 1-basiert wie in Fortran; ein Aktualparameter `V(L)` wird als Sicht
#   `_at(v, L)` übergeben (Schreibzugriffe wirken auf das Grundfeld).
# * Sprungmarken als @goto/@label.
# * DMAX1 übersetzt gfortran in `maxsd`; die Operandenreihenfolge (nur bei NaN
#   von Belang) ist je Stelle aus dem Maschinencode von R's stats.so
#   übernommen (`_max1`: a > b ? a : b, `_max2`: b > a ? b : a).
# * Wo R's Maschinencode bei überlappenden Argumenten anders rechnet als die
#   Fortran-Reihenfolge (DL7TVM mit x === y), wird der Maschinencode nachgebildet.
# * DD7TPR und DV2NRM wie in R über die Referenz-BLAS (ddot, dnrm2).
# ─────────────────────────────────────────────────────────────────────────────
module RPort

import ..SimLev

const ZERO = 0.0
const ONE = 1.0
const TWO = 2.0
const THREE = 3.0
const FOUR = 4.0
const HALF = 0.5
const NEGONE = -1.0
const ONEP2 = 1.2

const _DBL_EPS = 2.220446049250313e-16
const _DBL_MIN = 2.2250738585072014e-308
const _DBL_MAX = 1.7976931348623157e308

@inline _sqrt(x::Float64) = x < 0.0 ? reinterpret(Float64, 0xFFF8000000000000) : sqrt(x)
@inline _pow(x::Float64, y::Float64) = SimLev._libm_pow(x, y)
@inline _max1(a::Float64, b::Float64) = a > b ? a : b
@inline _max2(a::Float64, b::Float64) = b > a ? b : a
@inline _at(a::AbstractVector, k::Integer) = view(a, k:lastindex(a))

function dr7mdc(k::Integer)
    k == 1 && return _DBL_MIN
    k == 2 && return _sqrt(256.0 * _DBL_MIN) / 16.0
    k == 3 && return _DBL_EPS
    k == 4 && return _sqrt(_DBL_EPS)
    k == 5 && return _sqrt(_DBL_MAX / 256.0) * 16.0
    k == 6 && return _DBL_MAX
    error("dr7mdc: k = $k")
end

# ── Ersatzroutinen aus port.c ────────────────────────────────────────────

"Skalarprodukt (Referenz-BLAS ddot: sequenziell ab 0)."
function dd7tpr(p::Integer, x::AbstractVector{Float64}, y::AbstractVector{Float64})
    t = 0.0
    for i in 1:p
        t = t + x[i] * y[i]
    end
    return t
end

dv2nrm(n::Integer, x::AbstractVector{Float64}) = n <= 0 ? 0.0 : SimLev.RLinalg.dnrm2(collect(view(x, 1:n)))

function dv2axy(n::Integer, w::AbstractVector{Float64}, a::Float64, x::AbstractVector{Float64}, y::AbstractVector{Float64})
    for i in 1:n
        w[i] = a * x[i] + y[i]
    end
end

function dv7cpy(n::Integer, dest::AbstractVector{Float64}, src::AbstractVector{Float64})
    n > 0 || return
    tmp = src[1:n]
    for i in 1:n
        dest[i] = tmp[i]
    end
end

"x[i] := x[ip[i]]"
function dv7ipr(n::Integer, ip::AbstractVector{Int}, x::AbstractVector{Float64})
    xcp = Float64[x[ip[i]] for i in 1:n]
    for i in 1:n
        x[i] = xcp[i]
    end
end

"x[ip[i]] := x[i]"
function dv7prm(n::Integer, ip::AbstractVector{Int}, x::AbstractVector{Float64})
    xcp = zeros(n)
    for i in 1:n
        xcp[ip[i]] = x[i]
    end
    for i in 1:n
        x[i] = xcp[i]
    end
end

function dv7scl(n::Integer, dest::AbstractVector{Float64}, scal::Float64, src::AbstractVector{Float64})
    for i in 1:n
        dest[i] = scal * src[i]
    end
end

function dv7scp(n::Integer, dest::AbstractVector{Float64}, c::Float64)
    for i in 1:n
        dest[i] = c
    end
end

function dv7swp(n::Integer, x::AbstractVector{Float64}, y::AbstractVector{Float64})
    for i in 1:n
        t = x[i]; x[i] = y[i]; y[i] = t
    end
end

function i7copy(n::Integer, dest::AbstractVector{Int}, src::AbstractVector{Int})
    for i in 1:n
        dest[i] = src[i]
    end
end

function i7pnvr(n::Integer, x::AbstractVector{Int}, y::AbstractVector{Int})
    for i in 1:n
        x[y[i]] = i
    end
end

"C-printf einer Zahl (glibc: negatives NaN als -nan)."
function _cg(fmt::String, width::Int, val::Float64)
    if isnan(val) && signbit(val)
        return lpad("-nan", width)
    end
    return SimLev._c_sprintf(fmt, val)
end

"Iterationsausgabe (trace) wie ditsum in port.c (Rprintf)."
function ditsum(d, g, iv, liv, lv, n, v, x)
    iv[OUTLEV] == 0 && return
    if iv[NITER] % iv[OUTLEV] == 0
        s = SimLev._c_sprintf("%3d:", Int32(iv[NITER])) * _cg("%#14.8g", 14, v[F]) * ":"
        for i in 1:n
            s *= " " * _cg("%#8g", 8, x[i])
        end
        print(stdout, s, "\n")
    end
    return
end

# ── iv-/v-Indizes ─────────────────────────────────────────────────────────

const AFCTOL = 31
const ALGSAV = 51
const COVPRT = 14
const COVREQ = 15
const DTYPE = 16
const F = 10
const F0 = 13
const FDIF = 11
const G = 28
const HC = 71
const IERR = 75
const INITH = 25
const INITS = 25
const IPIVOT = 76
const IVNEED = 3
const LASTIV = 44
const LASTV = 45
const LMAT = 42
const MXFCAL = 17
const MXITER = 18
const NEXTV = 47
const NFCALL = 6
const NFCOV = 52
const NFGCAL = 7
const NGCOV = 53
const NITER = 31
const NVDFLT = 50
const NVSAVE = 9
const OUTLEV = 19
const PARPRT = 20
const PARSAV = 49
const PERM = 58
const PRUNIT = 21
const QRTYP = 80
const RDREQ = 57
const RMAT = 78
const SOLPRT = 22
const STATPR = 23
const TOOBIG = 2
const VNEED = 4
const VSAVE = 60
const X0PRT = 24

# ── Voreinstellungen ─────────────────────────────────────────────────────

"DV7DFL: Voreinstellungen in v."
function dv7dfl(alg::Integer, lv::Integer, v::AbstractVector{Float64})
    machep = dr7mdc(3)
    v[31] = machep > 1e-10 ? machep * machep : 1e-20
    v[22] = 0.5
    sqteps = dr7mdc(4)
    v[41] = 0.6
    v[39] = 1e-6
    mepcrt = _pow(machep, ONE / THREE)
    v[40] = 1.0
    v[19] = 0.1
    v[23] = 2.0
    v[35] = 1.0
    v[36] = 1.0
    v[20] = -0.1
    v[21] = 0.1
    v[24] = 0.1
    v[25] = 4.0
    v[32] = _max1(1e-10, mepcrt * mepcrt)
    v[37] = v[32]
    v[26] = 0.1
    v[27] = 1e-4
    v[28] = 0.75
    v[29] = 0.5
    v[30] = 0.75
    v[33] = sqteps
    v[34] = 1e2 * machep
    if alg == 1
        v[47] = _max1(1e-6, 1e2 * machep)
        v[38] = 0.0
        v[44] = sqteps
        v[42] = mepcrt
        v[43] = sqteps
        v[45] = 1.5
        v[46] = dr7mdc(5)
        v[49] = 1e-3
        v[50] = 1e-4
    else
        v[43] = 0.8
        v[38] = -1.0
        v[42] = 1e3 * machep
    end
    return
end

"Rf_divset aus port.c."
function divset(alg::Integer, iv::AbstractVector{Int}, liv::Integer, lv::Integer, v::AbstractVector{Float64})
    miniv = (82, 59, 103, 103)
    minv = (98, 71, 101, 85)
    PRUNIT <= liv && (iv[PRUNIT] = 0)
    ALGSAV <= liv && (iv[ALGSAV] = alg)
    (alg < 1 || alg > 4) && error("Rf_divset: alg = $alg must be 1, 2, 3, or 4")
    miv = miniv[alg]
    if liv < miv
        iv[1] = 15
        return
    end
    mv = minv[alg]
    if lv < mv
        iv[1] = 16
        return
    end
    alg1 = (alg - 1) % 2 + 1
    dv7dfl(alg1, lv, v)
    iv[1] = 12
    alg > 2 && error("port algorithms 3 or higher are not supported")
    iv[IVNEED] = 0
    iv[LASTIV] = miv
    iv[LASTV] = mv
    iv[LMAT] = mv + 1
    iv[MXFCAL] = 200
    iv[MXITER] = 150
    iv[OUTLEV] = 0
    iv[PARPRT] = 1
    iv[PERM] = miv + 1
    iv[SOLPRT] = 0
    iv[STATPR] = 0
    iv[VNEED] = 0
    iv[X0PRT] = 1
    if alg1 >= 2
        iv[DTYPE] = 0
        iv[INITS] = 1
        iv[NFCOV] = 0
        iv[NGCOV] = 0
        iv[NVDFLT] = 25
        iv[PARSAV] = alg > 2 ? 61 : 47
        v[AFCTOL] = 0.0
    else
        iv[COVPRT] = 3
        iv[COVREQ] = 1
        iv[DTYPE] = 1
        iv[HC] = 0
        iv[IERR] = 0
        iv[INITH] = 0
        iv[IPIVOT] = 0
        iv[NVDFLT] = 32
        iv[VSAVE] = alg > 2 ? 61 : 58
        iv[PARSAV] = iv[60] + 9
        iv[QRTYP] = 1
        iv[RDREQ] = 3
        iv[RMAT] = 0
    end
    return
end

# ── kleine lineare Algebra (portsrc.f) ───────────────────────────────────

function dv7vmp(n, x, y, z, k)
    if k >= 0
        for i in 1:n
            x[i] = y[i] * z[i]
        end
    else
        for i in 1:n
            x[i] = y[i] / z[i]
        end
    end
end

function dv7shf(n, k, x)
    k >= n && return
    t = x[k]
    for i in k:n-1
        x[i] = x[i+1]
    end
    x[n] = t
    return
end

function i7shft(n, k, x)
    if k >= 0
        k >= n && return
        t = x[k]
        for i in k:n-1
            x[i] = x[i+1]
        end
        x[n] = t
        return
    end
    k1 = -k
    k1 >= n && return
    t = x[n]
    nm1 = n - k1
    for ii in 1:nm1
        i = n - ii
        x[i+1] = x[i]
    end
    x[k1] = t
    return
end

function drldst(p, d, x, x0)
    emax = ZERO
    xmax = ZERO
    for i in 1:p
        t = abs(d[i] * (x[i] - x0[i]))
        emax < t && (emax = t)
        t = d[i] * (abs(x[i]) + abs(x0[i]))
        xmax < t && (xmax = t)
    end
    r = ZERO
    xmax > ZERO && (r = emax / xmax)
    return r
end

"DH2RFG; liefert (Wert, x, y, z)."
function dh2rfg(a::Float64, b::Float64)
    b == ZERO && return (a, ZERO, ZERO, ZERO)
    t = abs(a) + abs(b)
    a1 = a / t
    b1 = b / t
    c = _sqrt(a1 * a1 + b1 * b1)
    a1 > ZERO && (c = -c)
    a1 = a1 - c
    z = b1 / a1
    x = a1 / c
    y = b1 / c
    return (t * c, x, y, z)
end

function dh2rfa(n, a, b, x, y, z)
    for i in 1:n
        t = a[i] * x + b[i] * y
        a[i] = a[i] + t
        b[i] = b[i] + t * z
    end
end

function dq7rsh(k, p, havqtr::Bool, qtr, r, w)
    k >= p && return
    km1 = k - 1
    k1 = k * km1 ÷ 2
    dv7cpy(k, w, _at(r, k1 + 1))
    wj = w[k]
    pm1 = p - 1
    j1 = k1 + km1
    x = y = z = ZERO
    for j in k:pm1
        jm1 = j - 1
        jp1 = j + 1
        jm1 > 0 && dv7cpy(jm1, _at(r, k1 + 1), _at(r, j1 + 2))
        j1 = j1 + jp1
        k1 = k1 + j
        a = r[j1]
        b = r[j1+1]
        if b == ZERO
            r[k1] = a
            x = ZERO
            z = ZERO
        else
            r[k1], x, y, z = dh2rfg(a, b)
            if j != pm1
                i1 = j1
                for i in jp1:pm1
                    i1 = i1 + i
                    dh2rfa(1, _at(r, i1), _at(r, i1 + 1), x, y, z)
                end
            end
            havqtr && dh2rfa(1, _at(qtr, j), _at(qtr, jp1), x, y, z)
        end
        t = x * wj
        w[j] = wj + t
        wj = t * z
    end
    w[p] = wj
    dv7cpy(p, _at(r, k1 + 1), w)
    return
end

"x = L * y (L untere Dreiecksmatrix, zeilenweise kompakt)."
function dl7vml(n, x, l, y)
    np1 = n + 1
    i0 = n * (n + 1) ÷ 2
    for ii in 1:n
        i = np1 - ii
        i0 = i0 - i
        t = ZERO
        for j in 1:i
            t = t + l[i0+j] * y[j]
        end
        x[i] = t
    end
end

"x = L' * y; x(i) = 0 wird wie im Maschinencode von R vor dem Laden von y(i) gespeichert."
function dl7tvm(n, x, l, y)
    i0 = 0
    for i in 1:n
        x[i] = ZERO
        yi = y[i]
        for j in 1:i
            x[j] = x[j] + yi * l[i0+j]
        end
        i0 = i0 + i
    end
end

"Löst L' x = y."
function dl7itv(n, x, l, y)
    for i in 1:n
        x[i] = y[i]
    end
    np1 = n + 1
    i0 = n * (n + 1) ÷ 2
    for ii in 1:n
        i = np1 - ii
        xi = x[i] / l[i0]
        x[i] = xi
        i <= 1 && return
        i0 = i0 - i
        xi == ZERO && continue
        for j in 1:i-1
            x[j] = x[j] - xi * l[i0+j]
        end
    end
end

"Löst L x = y."
function dl7ivm(n, x, l, y)
    k = 1
    while k <= n
        y[k] != ZERO && break
        x[k] = ZERO
        k += 1
    end
    k > n && return
    j = k * (k + 1) ÷ 2
    x[k] = y[k] / l[j]
    k >= n && return
    k = k + 1
    for i in k:n
        t = dd7tpr(i - 1, _at(l, j + 1), x)
        j = j + i
        x[i] = (y[i] - t) / l[j]
    end
end

function dw7zbf(l, n, s, w, y, z)
    eps = 0.1
    dl7tvm(n, w, l, s)
    shs = dd7tpr(n, w, w)
    ys = dd7tpr(n, y, s)
    if ys >= eps * shs
        cy = ONE / (_sqrt(ys) * _sqrt(shs))
        cs = ONE / shs
    else
        theta = (ONE - eps) * shs / (shs - ys)
        epsrt = _sqrt(eps)
        cy = theta / (shs * epsrt)
        cs = (ONE + (theta - ONE) / epsrt) / shs
    end
    dl7ivm(n, z, l, y)
    for i in 1:n
        z[i] = cy * z[i] - cs * w[i]
    end
end

function dl7upd(beta, gamma, l, lambda, lplus, n, w, z)
    nu = ONE
    eta = ZERO
    if n > 1
        nm1 = n - 1
        s = ZERO
        for i in 1:nm1
            j = n - i
            s = s + w[j+1] * w[j+1]
            lambda[j] = s
        end
        for j in 1:nm1
            wj = w[j]
            a = nu * z[j] - eta * wj
            theta = ONE + a * wj
            s = a * lambda[j]
            lj = _sqrt(theta * theta + a * s)
            theta > ZERO && (lj = -lj)
            lambda[j] = lj
            b = theta * wj + s
            gamma[j] = b * nu / lj
            beta[j] = (a - b * eta) / lj
            nu = -nu / lj
            eta = -(eta + (a * a) / (theta - lj)) / lj
        end
    end
    lambda[n] = ONE + (nu * z[n] - eta * w[n]) * w[n]
    np1 = n + 1
    jj = n * (n + 1) ÷ 2
    for k in 1:n
        j = np1 - k
        lj = lambda[j]
        ljj = l[jj]
        lplus[jj] = lj * ljj
        wj = w[j]
        w[j] = ljj * wj
        zj = z[j]
        z[j] = ljj * zj
        if k != 1
            bj = beta[j]
            gj = gamma[j]
            ij = jj + j
            for i in j+1:n
                lij = l[ij]
                lplus[ij] = lj * lij + bj * w[i] + gj * z[i]
                w[i] = w[i] + lij * wj
                z[i] = z[i] + lij * zj
                ij = ij + i
            end
        end
        jj = jj - j
    end
end

# ── DA7SST: Schritt bewerten ─────────────────────────────────────────────

function da7sst(iv, liv, lv, v)
    IRC = 29; MLSTGD = 32; MODEL = 5; NFCALL_ = 6; NFGCAL_ = 7; RADINC = 8; RESTOR = 9
    STAGE = 10; STGLIM = 11; SWITCH = 12; TOOBIG_ = 2; XIRC = 13
    AFCTOL_ = 31; DECFAC = 22; DSTNRM = 2; DST0 = 3; DSTSAV = 18; F_ = 10; FDIF_ = 11
    FLSTGD = 12; F0_ = 13; GTSLST = 14; GTSTEP = 4; INCFAC = 23; LMAXS = 36; NREDUC = 6
    PLSTGD = 15; PREDUC = 7; RADFAC = 16; RDFCMN = 24; RDFCMX = 25; RELDX = 17; RFCTOL = 32
    SCTOL = 37; STPPAR = 5; TUNER1 = 26; TUNER2 = 27; TUNER3 = 28; XCTOL = 33; XFTOL = 34
    nfc = iv[NFCALL_]
    iv[SWITCH] = 0
    iv[RESTOR] = 0
    rfac1 = ONE
    goodx = true
    emax = ZERO; emaxs = ZERO
    i = iv[IRC]
    if 1 <= i <= 12
        i == 1 && @goto l20
        i == 2 && @goto l30
        (i == 3 || i == 4) && @goto l10
        i == 5 && @goto l40
        i == 6 && @goto l280
        i <= 11 && @goto l220
        @goto l170
    end
    iv[IRC] = 13
    return
    @label l10
    iv[STAGE] = 1
    iv[RADINC] = 0
    v[FLSTGD] = v[F0_]
    iv[TOOBIG_] == 0 && @goto l110
    iv[STAGE] = -1
    iv[XIRC] = i
    @goto l60
    @label l20
    iv[MODEL] != iv[MLSTGD] && @goto l30
    iv[STAGE] = iv[STGLIM]
    iv[RADINC] = -1
    @goto l110
    @label l30
    iv[STAGE] = iv[STAGE] + 1
    @label l40
    iv[STAGE] > 0 && @goto l50
    iv[TOOBIG_] != 0 && @goto l60
    iv[STAGE] = -iv[STAGE]
    i = iv[XIRC]
    i == 1 && @goto l20
    i == 2 && @goto l30
    (i == 3 || i == 4) && @goto l110
    i == 5 && @goto l70
    @label l50
    iv[TOOBIG_] == 0 && @goto l70
    iv[TOOBIG_] = 0
    iv[RADINC] > 0 && @goto l80
    iv[STAGE] = -iv[STAGE]
    iv[XIRC] = iv[IRC]
    @label l60
    iv[TOOBIG_] = 0
    v[RADFAC] = v[DECFAC]
    iv[RADINC] = iv[RADINC] - 1
    iv[IRC] = 5
    iv[RESTOR] = 1
    v[F_] = v[FLSTGD]
    return
    @label l70
    v[F_] < v[FLSTGD] && @goto l110
    if iv[MODEL] != iv[MLSTGD]
        iv[MODEL] = iv[MLSTGD]
        iv[SWITCH] = 1
    end
    @label l80
    v[FLSTGD] >= v[F0_] && @goto l110
    if iv[STAGE] < iv[STGLIM]
        goodx = false
    elseif nfc < iv[NFGCAL_] + iv[STGLIM] + 2
        goodx = false
    elseif iv[SWITCH] != 0
        goodx = false
    end
    iv[RESTOR] = 3
    v[F_] = v[FLSTGD]
    v[PREDUC] = v[PLSTGD]
    v[GTSTEP] = v[GTSLST]
    iv[SWITCH] == 0 && (rfac1 = v[DSTNRM] / v[DSTSAV])
    v[DSTNRM] = v[DSTSAV]
    if goodx
        v[FDIF_] = v[F0_] - v[F_]
        iv[IRC] = 4
        v[RADFAC] = rfac1
        return
    end
    nfc = iv[NFGCAL_]
    @label l110
    v[FDIF_] = v[F0_] - v[F_]
    v[FDIF_] > v[TUNER2] * v[PREDUC] && @goto l140
    iv[RADINC] > 0 && @goto l140
    v[F_] < v[F0_] && @goto l120
    iv[MLSTGD] = iv[MODEL]
    v[FLSTGD] = v[F_]
    v[F_] = v[F0_]
    iv[RESTOR] = 1
    @goto l130
    @label l120
    iv[NFGCAL_] = nfc
    @label l130
    iv[IRC] = 1
    iv[STAGE] < iv[STGLIM] && @goto l160
    iv[IRC] = 5
    iv[RADINC] = iv[RADINC] - 1
    @goto l160
    @label l140
    iv[NFGCAL_] = nfc
    rfac1 = ONE
    v[DSTSAV] = v[DSTNRM]
    v[FDIF_] > v[PREDUC] * v[TUNER1] && @goto l190
    iv[STAGE] >= iv[STGLIM] && @goto l150
    iv[IRC] = 2
    @goto l160
    @label l150
    iv[IRC] = 4
    @label l160
    iv[XIRC] = iv[IRC]
    emax = v[GTSTEP] + v[FDIF_]
    v[RADFAC] = HALF * rfac1
    emax < v[GTSTEP] && (v[RADFAC] = rfac1 * _max2(v[RDFCMN], HALF * v[GTSTEP] / emax))
    @label l170
    v[RELDX] <= v[XFTOL] && @goto l180
    iv[IRC] = iv[XIRC]
    v[F_] < v[F0_] && @goto l200
    @goto l230
    @label l180
    iv[IRC] = 12
    @goto l240
    @label l190
    v[FDIF_] < (-v[TUNER3] * v[GTSTEP]) && @goto l210
    iv[RADINC] < 0 && @goto l210
    iv[RESTOR] == 1 && @goto l210
    iv[RESTOR] == 3 && @goto l210
    v[RADFAC] = v[RDFCMX]
    gts = v[GTSTEP]
    v[FDIF_] < (HALF / v[RADFAC] - ONE) * gts && (v[RADFAC] = _max2(v[INCFAC], HALF * gts / (gts + v[FDIF_])))
    iv[IRC] = 4
    v[STPPAR] == ZERO && @goto l230
    v[DST0] >= ZERO && (v[DST0] < TWO * v[DSTNRM] || v[NREDUC] < ONEP2 * v[FDIF_]) && @goto l230
    iv[IRC] = 5
    iv[RADINC] = iv[RADINC] + 1
    @label l200
    v[FLSTGD] = v[F_]
    iv[MLSTGD] = iv[MODEL]
    iv[RESTOR] == 0 && (iv[RESTOR] = 2)
    v[DSTSAV] = v[DSTNRM]
    iv[NFGCAL_] = nfc
    v[PLSTGD] = v[PREDUC]
    v[GTSLST] = v[GTSTEP]
    @goto l230
    @label l210
    v[RADFAC] = ONE
    iv[IRC] = 3
    @goto l230
    @label l220
    iv[IRC] = iv[XIRC]
    v[DSTSAV] >= ZERO && @goto l240
    iv[IRC] = 12
    @goto l240
    @label l230
    iv[XIRC] = iv[IRC]
    @label l240
    iv[RESTOR] == 1 && v[FLSTGD] < v[F0_] && (iv[RESTOR] = 3)
    abs(v[F_]) < v[AFCTOL_] && (iv[IRC] = 10)
    HALF * v[FDIF_] > v[PREDUC] && return
    emax = v[RFCTOL] * abs(v[F0_])
    emaxs = v[SCTOL] * abs(v[F0_])
    v[PREDUC] <= emaxs && (v[DSTNRM] > v[LMAXS] || v[STPPAR] == ZERO) && (iv[IRC] = 11)
    v[DST0] < ZERO && @goto l250
    i = 0
    if (v[NREDUC] > ZERO && v[NREDUC] <= emax) || (v[NREDUC] == ZERO && v[PREDUC] == ZERO)
        i = 2
    end
    v[STPPAR] == ZERO && v[RELDX] <= v[XCTOL] && goodx && (i = i + 1)
    i > 0 && (iv[IRC] = i + 6)
    @label l250
    iv[IRC] > 5 && iv[IRC] != 12 && return
    v[STPPAR] == ZERO && return
    v[DSTNRM] > v[LMAXS] && @goto l260
    v[PREDUC] >= emaxs && return
    v[DST0] <= ZERO && @goto l270
    HALF * v[DST0] <= v[LMAXS] && return
    @goto l270
    @label l260
    HALF * v[DSTNRM] <= v[LMAXS] && return
    xmax = v[LMAXS] / v[DSTNRM]
    xmax * (TWO - xmax) * v[PREDUC] >= emaxs && return
    @label l270
    v[NREDUC] < ZERO && @goto l290
    v[GTSLST] = v[GTSTEP]
    v[DSTSAV] = v[DSTNRM]
    iv[IRC] == 12 && (v[DSTSAV] = -v[DSTSAV])
    v[PLSTGD] = v[PREDUC]
    i = iv[RESTOR]
    iv[RESTOR] = 2
    i == 3 && (iv[RESTOR] = 0)
    iv[IRC] = 6
    return
    @label l280
    v[GTSTEP] = v[GTSLST]
    v[DSTNRM] = abs(v[DSTSAV])
    iv[IRC] = iv[XIRC]
    v[DSTSAV] <= ZERO && (iv[IRC] = 12)
    v[NREDUC] = -v[PREDUC]
    v[PREDUC] = v[PLSTGD]
    iv[RESTOR] = 3
    @label l290
    -v[NREDUC] <= v[SCTOL] * abs(v[F0_]) && (iv[IRC] = 11)
    return
end

# ── Doppel-Dogleg-Schritte ───────────────────────────────────────────────

function dd7dog(dig, lv, n, nwtstp, step, v)
    BIAS = 43; DGNORM = 1; DSTNRM = 2; DST0 = 3; GRDFAC = 45; GTHG = 44; GTSTEP = 4
    NREDUC = 6; NWTFAC = 46; PREDUC = 7; RADIUS = 8; STPPAR = 5
    nwtnrm = v[DST0]
    rlambd = ONE
    nwtnrm > ZERO && (rlambd = v[RADIUS] / nwtnrm)
    gnorm = v[DGNORM]
    ghinvg = TWO * v[NREDUC]
    v[GRDFAC] = ZERO
    v[NWTFAC] = ZERO
    if !(rlambd < ONE)
        v[STPPAR] = ZERO
        v[DSTNRM] = nwtnrm
        v[GTSTEP] = -ghinvg
        v[PREDUC] = v[NREDUC]
        v[NWTFAC] = -ONE
        for i in 1:n
            step[i] = -nwtstp[i]
        end
        return
    end
    v[DSTNRM] = v[RADIUS]
    cfact = gnorm / v[GTHG]
    cfact = cfact * cfact
    cnorm = gnorm * cfact
    relax = ONE - v[BIAS] * (ONE - gnorm * cnorm / ghinvg)
    if !(rlambd < relax)
        v[STPPAR] = ONE - (rlambd - relax) / (ONE - relax)
        t = -rlambd
        v[GTSTEP] = t * ghinvg
        v[PREDUC] = rlambd * (ONE - HALF * rlambd) * ghinvg
        v[NWTFAC] = t
        for i in 1:n
            step[i] = t * nwtstp[i]
        end
        return
    end
    if !(cnorm < v[RADIUS])
        t = -v[RADIUS] / gnorm
        v[GRDFAC] = t
        v[STPPAR] = ONE + cnorm / v[RADIUS]
        v[GTSTEP] = -v[RADIUS] * gnorm
        q = v[GTHG] / gnorm
        v[PREDUC] = v[RADIUS] * (gnorm - HALF * v[RADIUS] * (q * q))
        for i in 1:n
            step[i] = t * dig[i]
        end
        return
    end
    ctrnwt = cfact * relax * ghinvg / gnorm
    t1 = ctrnwt - gnorm * (cfact * cfact)
    t2 = v[RADIUS] * (v[RADIUS] / gnorm) - gnorm * (cfact * cfact)
    t = relax * nwtnrm
    femnsq = (t / gnorm) * t - ctrnwt - t1
    t = t2 / (t1 + _sqrt(t1 * t1 + femnsq * t2))
    t1 = (t - ONE) * cfact
    v[GRDFAC] = t1
    t2 = -t * relax
    v[NWTFAC] = t2
    v[STPPAR] = TWO - t
    v[GTSTEP] = t1 * (gnorm * gnorm) + t2 * ghinvg
    q = v[GTHG] * t1
    v[PREDUC] = -t1 * gnorm * ((t2 + ONE) * gnorm) - t2 * (ONE + HALF * t2) * ghinvg - HALF * (q * q)
    for i in 1:n
        step[i] = t1 * dig[i] + t2 * nwtstp[i]
    end
    return
end

const _MEPS2 = TWO * _DBL_EPS

"Doppel-Dogleg mit Schranken; liefert das neue ka."
function dd7dgb(b, d, dig, dst, g, ipiv, ka::Int, l, lv, p, pc, nwtst, step, td, tg, v, w, x0)
    DGNORM = 1; DST0 = 3; DSTNRM = 2; GRDFAC = 45; GTHG = 44; GTSTEP = 4; NREDUC = 6
    NWTFAC = 46; PREDUC = 7; RADIUS = 8; STPPAR = 5
    meps2 = _MEPS2
    gnorm0 = v[DGNORM]
    v[DSTNRM] = ZERO
    # NRED ist in Fortran undefiniert, wenn ka < 0 und pc <= 0 (Stapelrest in R);
    # +0 ergibt dieselbe Konvergenzentscheidung wie ein positiver Rest.
    dnwtst = ZERO; nred = ZERO
    if ka >= 0
        dnwtst = v[DST0]
        nred = v[NREDUC]
    end
    pred = ZERO
    v[STPPAR] = ZERO
    rad = v[RADIUS]
    gnorm = ZERO; ghinvg = ZERO; p1 = 0; k = 0; t = ZERO
    if pc <= 0
        dnwtst = ZERO
        dv7scp(p, step, ZERO)
        @goto l140
    end
    p1 = pc
    dv7cpy(p, td, d)
    dv7ipr(p, ipiv, td)
    dv7scp(pc, dst, ZERO)
    dv7cpy(p, tg, g)
    dv7ipr(p, ipiv, tg)
    @label l30
    dl7ivm(p1, nwtst, l, tg)
    ghinvg = dd7tpr(p1, nwtst, nwtst)
    v[NREDUC] = HALF * ghinvg
    dl7itv(p1, nwtst, l, nwtst)
    dv7vmp(p1, step, nwtst, td, 1)
    v[DST0] = dv2nrm(pc, step)
    if ka < 0
        ka = 0
        dnwtst = v[DST0]
        nred = v[NREDUC]
    end
    v[RADIUS] = rad - v[DSTNRM]
    v[RADIUS] <= ZERO && @goto l100
    dv7vmp(p1, dig, tg, td, -1)
    gnorm = dv2nrm(p1, dig)
    gnorm <= ZERO && @goto l100
    v[DGNORM] = gnorm
    dv7vmp(p1, dig, dig, td, -1)
    dl7tvm(p1, w, l, dig)
    v[GTHG] = dv2nrm(p1, w)
    ka = ka + 1
    dd7dog(dig, lv, p1, nwtst, step, v)
    t = ONE
    k = 0
    for i in 1:p1
        j = ipiv[i]
        x0i = x0[j] + dst[i] / td[i]
        xi = x0i + step[i]
        if xi < b[2j-1]
            ti = (b[2j-1] - x0i) / step[i]
            j = -i
        elseif xi <= b[2j]
            continue
        else
            ti = (b[2j] - x0i) / step[i]
            j = i
        end
        t <= ti && continue
        k = j
        t = ti
    end
    dv7vmp(p1, step, step, td, 1)
    dv2axy(p1, dst, t, step, dst)
    v[DSTNRM] = dv2nrm(pc, dst)
    t1 = t * v[GRDFAC]
    t2 = t * v[NWTFAC]
    q = v[GTHG] * t1
    pred = pred - t1 * gnorm * ((t2 + ONE) * gnorm) - t2 * (ONE + HALF * t2) * ghinvg - HALF * (q * q)
    k == 0 && @goto l100
    dl7vml(p1, w, l, w)
    t2 = ONE - t2
    for i in 1:p1
        tg[i] = t2 * tg[i] - t1 * w[i]
    end
    p1m1 = p1 - 1
    j = abs(k)
    if j != p1
        dq7rsh(j, p1, false, tg, l, w)
        i7shft(p1, j, ipiv)
        dv7shf(p1, j, tg)
        dv7shf(p1, j, td)
        dv7shf(p1, j, dst)
    end
    k < 0 && (ipiv[p1] = -ipiv[p1])
    p1 = p1m1
    p1 > 0 && @goto l30
    @label l100
    dv7scp(p, step, ZERO)
    for i in 1:pc
        j = abs(ipiv[i])
        step[j] = dst[i] / td[i]
    end
    p1 >= pc && @goto l140
    dv2axy(p, td, ONE, step, x0)
    k = p1 + 1
    for i in k:pc
        j = ipiv[i]
        t = meps2
        if !(j > 0)
            t = -t
            j = -j
            ipiv[i] = j
        end
        t = t * _max1(abs(td[j]), abs(x0[j]))
        step[j] = step[j] + t
    end
    @label l140
    v[DGNORM] = gnorm0
    v[NREDUC] = nred
    v[PREDUC] = pred
    v[RADIUS] = rad
    v[DST0] = dnwtst
    v[GTSTEP] = dd7tpr(p, step, g)
    return ka
end

# ── Finite-Differenzen-Gradient (Stewart) mit Schranken ──────────────────

"DS3GRD; liefert (fx, irc)."
function ds3grd(alpha, b, d, eta0::Float64, fx::Float64, g, irc::Int, p, w, x)
    C2000 = 2.0e3; HMAX0 = 0.02; HMIN0 = 5.0e1; P002 = 0.002
    FH = 3; FX0 = 4; HSAVE = 5; XISAVE = 6
    i = 0
    h = ZERO; xih = ZERO; xi = ZERO; axibar = ZERO; alphai = ZERO; gi = ZERO; h0 = ZERO
    hit = false
    irc < 0 && @goto l80
    irc > 0 && @goto l210
    w[1] = dr7mdc(3)
    w[2] = _sqrt(w[1])
    w[FX0] = fx
    @label l20
    i = abs(irc) + 1
    i > p && @goto l220
    irc = i
    if !(b[2i-1] < b[2i])
        g[i] = ZERO
        @goto l20
    end
    afx = abs(w[FX0])
    machep = w[1]
    h0 = w[2]
    hmin = HMIN0 * machep
    xi = x[i]
    w[XISAVE] = xi
    axi = abs(xi)
    axibar = _max2(axi, ONE / d[i])
    gi = g[i]
    agi = abs(gi)
    eta = abs(eta0)
    afx > ZERO && (eta = _max1(eta, agi * axi * machep / afx))
    alphai = alpha[i]
    alphai == ZERO && @goto l130
    (gi == ZERO || fx == ZERO) && @goto l140
    afxeta = afx * eta
    aai = abs(alphai)
    gi * gi <= afxeta * aai && @goto l40
    h = TWO * _sqrt(afxeta / aai)
    h = h * (ONE - aai * h / (THREE * aai * h + FOUR * agi))
    @goto l50
    @label l40
    h = TWO * _pow(afxeta * agi, ONE / THREE) * _pow(aai, -TWO / THREE)
    h = h * (ONE - TWO * agi / (THREE * aai * h + FOUR * agi))
    @label l50
    h = _max1(h, hmin * axibar)
    aai * h <= P002 * agi && @goto l120
    discon = C2000 * afxeta
    h = discon / (agi + _sqrt(gi * gi + aai * discon))
    h = _max1(h, hmin * axibar)
    h >= HMAX0 * axibar && (h = axibar * _pow(h0, TWO / THREE))
    xih = xi + h
    xi - h < b[2i-1] && @goto l60
    irc = -i
    xih <= b[2i] && @goto l200
    h = -h
    xih = xi + h
    xi + TWO * h < b[2i-1] && @goto l190
    @goto l70
    @label l60
    xi + TWO * h > b[2i] && @goto l190
    @label l70
    irc = -(i + p)
    @goto l200
    @label l80
    i = -irc
    i <= p && @goto l100
    i = i - p
    i > p && @goto l90
    w[FH] = fx
    h = TWO * w[HSAVE]
    xih = w[XISAVE] + h
    irc = irc - p
    @goto l200
    @label l90
    i = i - p
    g[i] = (FOUR * w[FH] - fx - THREE * w[FX0]) / w[HSAVE]
    irc = i
    x[i] = w[XISAVE]
    @goto l20
    @label l100
    h = -w[HSAVE]
    h > ZERO && @goto l110
    w[FH] = fx
    xih = w[XISAVE] + h
    @goto l200
    @label l110
    g[i] = (w[FH] - fx) / (TWO * h)
    x[i] = w[XISAVE]
    @goto l20
    @label l120
    h >= HMAX0 * axibar && (h = h0 * axibar)
    alphai * gi < ZERO && (h = -h)
    @goto l150
    @label l130
    h = axibar
    @goto l150
    @label l140
    h = h0 * axibar
    @label l150
    hit = false
    @label l160
    xih = xi + h
    h > ZERO && @goto l170
    xih >= b[2i-1] && @goto l200
    @goto l180
    @label l170
    xih <= b[2i] && @goto l200
    @label l180
    hit && @goto l190
    hit = true
    h = -h
    @goto l160
    @label l190
    irc = i + p
    @goto l230
    @label l200
    x[i] = xih
    w[HSAVE] = h
    return (fx, irc)
    @label l210
    g[irc] = (fx - w[FX0]) / w[HSAVE]
    x[irc] = w[XISAVE]
    @goto l20
    @label l220
    irc = 0
    @label l230
    fx = w[FX0]
    return (fx, irc)
end

# ── DPARCK: Parameter prüfen ─────────────────────────────────────────────

function _vmvx()
    vm = zeros(34); vx = zeros(34)
    for (k, val) in ((1, 1.0e-3), (2, -0.99), (3, 1.0e-3), (4, 1.0e-2), (5, 1.2), (6, 1.e-2), (7, 1.2),
                     (8, 0.0), (9, 0.0), (10, 1.e-3), (11, -1.0), (13, 0.0), (15, 0.0), (16, 0.0),
                     (19, 0.0), (20, -10.0), (21, 0.0), (22, 0.0), (23, 0.0), (27, 1.01), (28, 1.e10),
                     (30, 0.0), (31, 0.0), (32, 0.0), (34, 0.0))
        vm[k] = val
    end
    for (k, val) in ((1, 0.9), (2, -1.e-3), (3, 1.e1), (4, 0.8), (5, 1.e2), (6, 0.8), (7, 1.e2), (8, 0.5),
                     (9, 0.5), (10, 1.0), (11, 1.0), (14, 0.1), (15, 1.0), (16, 1.0), (19, 1.0), (23, 1.0),
                     (24, 1.0), (25, 1.0), (26, 1.0), (27, 1.e10), (29, 1.0), (31, 1.0), (32, 1.0),
                     (33, 1.0), (34, 1.0))
        vx[k] = val
    end
    tiny = dr7mdc(1); machep = dr7mdc(3); big = dr7mdc(6)
    vm[12] = machep; vx[12] = big; vx[13] = big; vm[14] = machep; vm[17] = tiny; vx[17] = big
    vm[18] = tiny; vx[18] = big; vx[20] = big; vx[21] = big; vx[22] = big; vm[24] = machep
    vm[25] = machep; vm[26] = machep; vx[28] = dr7mdc(5); vm[29] = machep; vx[30] = big
    vm[33] = machep
    return vm, vx
end

const _VM, _VX = _vmvx()

function _dparck300(iv, liv, lv, pu, miv1)
    iv[1] = 15
    pu == 0 && return
    liv < miv1 && return
    lv < iv[45] && (iv[1] = 16)
    return
end

function dparck(alg, d, iv, liv, lv, n, v)
    ALGSAV_ = 51; DINIT = 38; DTYPE_ = 16; DTYPE0 = 54; EPSLON = 19; IVNEED_ = 3
    LASTIV_ = 44; LASTV_ = 45; LMAT_ = 42; NEXTIV = 46; NEXTV_ = 47; NVDFLT_ = 50; OLDN = 38
    PARPRT_ = 20; PARSAV_ = 49; PERM_ = 58; PRUNIT_ = 21; VNEED_ = 4
    jlim = (0, 24, 0, 24); ndflt = (32, 25, 32, 25); miniv = (82, 59, 103, 103); ijmp = 33
    pu = 0
    PRUNIT_ <= liv && (pu = iv[PRUNIT_])
    if !(ALGSAV_ > liv) && alg != iv[ALGSAV_]
        iv[1] = 67
        return
    end
    if alg < 1 || alg > 4
        iv[1] = 67
        return
    end
    miv1 = miniv[alg]
    if iv[1] == 15
        LASTIV_ <= liv && (iv[LASTIV_] = miv1)
        LASTV_ <= liv && (iv[LASTV_] = 0)
        return
    end
    alg1 = (alg - 1) % 2 + 1
    iv[1] == 0 && divset(alg, iv, liv, lv, v)
    iv1 = iv[1]
    if iv1 == 13 || iv1 == 12
        miv2 = miv1
        PERM_ <= liv && (miv1 = max(miv1, iv[PERM_] - 1))
        IVNEED_ <= liv && (miv2 = miv1 + max(iv[IVNEED_], 0))
        LASTIV_ <= liv && (iv[LASTIV_] = miv2)
        liv < miv1 && return _dparck300(iv, liv, lv, pu, miv1)
        iv[IVNEED_] = 0
        iv[LASTV_] = max(iv[VNEED_], 0) + iv[LMAT_] - 1
        iv[VNEED_] = 0
        liv < miv2 && return _dparck300(iv, liv, lv, pu, miv1)
        if lv < iv[LASTV_]
            iv[1] = 16
            return
        end
    end
    if 12 <= iv1 <= 14
        if n < 1
            iv[1] = 81
            return
        end
        iv1 != 14 && (iv[NEXTIV] = iv[PERM_])
        iv1 != 14 && (iv[NEXTV_] = iv[LMAT_])
        iv1 == 13 && return
        k = iv[PARSAV_] - EPSLON
        dv7dfl(alg1, lv - k, _at(v, k + 1))
        iv[DTYPE0] = 2 - alg1
        iv[OLDN] = n
    else
        if n != iv[OLDN]
            iv[1] = 17
            return
        end
        if !(1 <= iv1 <= 11)
            iv[1] = 80
            return
        end
    end
    iv1 == 14 && (iv1 = 12)
    m = 0
    i = 1
    j = jlim[alg1]
    k = EPSLON
    ndfalt = ndflt[alg1]
    for _ in 1:ndfalt
        vk = v[k]
        (vk >= _VM[i] && vk <= _VX[i]) || (m = k)
        k = k + 1
        i = i + 1
        i == j && (i = ijmp)
    end
    if iv[NVDFLT_] != ndfalt
        iv[1] = 51
        return
    end
    if !((iv[DTYPE_] > 0 || v[DINIT] > ZERO) && iv1 == 12)
        for i in 1:n
            d[i] > ZERO || (m = 18)
        end
    end
    if m != 0
        iv[1] = m
        return
    end
    # pu == 0 in R: keine Ausgabe der geänderten Werte
    (pu == 0 || iv[PARPRT_] == 0) && return
    iv[DTYPE0] = iv[DTYPE_]
    parsv1 = iv[PARSAV_]
    dv7cpy(iv[NVDFLT_], _at(v, parsv1), _at(v, EPSLON))
    return
end

# ── DRMNGB: Iterationen mit Schranken (Gradient vom Aufrufer) ────────────

function drmngb(b, d, fx::Float64, g, iv, liv, lv, n, v, x)
    CNVCOD = 55; DG = 37; INITH_ = 25; IRC = 29; IVNEED_ = 3; KAGQT = 33; MODE = 35; MODEL = 5
    MXFCAL_ = 17; MXITER_ = 18; NC = 48; NEXTIV = 46; NEXTV_ = 47; NFCALL_ = 6; NFGCAL_ = 7
    NGCALL = 30; NITER_ = 31; NWTSTP = 34; PERM_ = 58; RADINC = 8; RESTOR = 9; STEP = 40
    STGLIM = 11; STLSTG = 41; TOOBIG_ = 2; XIRC = 13; X0 = 43
    DGNORM = 1; DINIT = 38; DSTNRM = 2; F_ = 10; F0_ = 13; FDIF_ = 11; GTSTEP = 4; INCFAC = 23
    LMAT_ = 42; LMAX0 = 35; LMAXS = 36; PREDUC = 7; RADFAC = 16; RADIUS = 8; RAD0 = 9
    RELDX = 17; TUNER4 = 29; TUNER5 = 30; VNEED_ = 4
    rstrst = 0; k = 0; x01 = 0; step1 = 0; ipi = 0; l = 0; temp1 = 0; g01 = 0
    i = iv[1]
    i == 1 && @goto l70
    i == 2 && @goto l80
    iv[1] == 0 && divset(2, iv, liv, lv, v)
    if 12 <= iv[1] <= 13
        iv[VNEED_] = iv[VNEED_] + n * (n + 19) ÷ 2
        iv[IVNEED_] = iv[IVNEED_] + n
    end
    dparck(2, d, iv, liv, lv, n, v)
    i = iv[1] - 2
    i > 12 && return
    1 <= i <= 6 && @goto l250
    (i == 7 || i == 9) && @goto l190
    i == 8 && @goto l150
    i == 12 && @goto l30
    @label l20
    l = iv[LMAT_]
    iv[X0] = l + n * (n + 1) ÷ 2
    iv[STEP] = iv[X0] + 2n
    iv[STLSTG] = iv[STEP] + 2n
    iv[NWTSTP] = iv[STLSTG] + n
    iv[DG] = iv[NWTSTP] + 2n
    iv[NEXTV_] = iv[DG] + 2n
    iv[NEXTIV] = iv[PERM_] + n
    if iv[1] == 13
        iv[1] = 14
        return
    end
    @label l30
    iv[NITER_] = 0
    iv[NFCALL_] = 1
    iv[NGCALL] = 1
    iv[NFGCAL_] = 1
    iv[MODE] = -1
    iv[MODEL] = 1
    iv[STGLIM] = 1
    iv[TOOBIG_] = 0
    iv[CNVCOD] = 0
    iv[RADINC] = 0
    iv[NC] = n
    v[RAD0] = ZERO
    ipi = iv[PERM_]
    for i in 1:n
        iv[ipi] = i
        ipi = ipi + 1
        b[2i-1] > b[2i] && @goto l410
    end
    v[DINIT] >= ZERO && dv7scp(n, d, v[DINIT])
    if iv[INITH_] == 1
        l = iv[LMAT_]
        dv7scp(n * (n + 1) ÷ 2, _at(v, l), ZERO)
        k = l - 1
        for i in 1:n
            k = k + i
            t = d[i]
            t <= ZERO && (t = ONE)
            v[k] = t
        end
    end
    iv[1] = 1
    @goto l440
    @label l70
    v[F_] = fx
    iv[MODE] >= 0 && @goto l250
    v[F0_] = fx
    iv[1] = 2
    iv[TOOBIG_] == 0 && return
    iv[1] = 63
    @goto l430
    @label l80
    if iv[TOOBIG_] != 0
        iv[1] = 65
        @goto l430
    end
    ipi = iv[PERM_]
    ipn = ipi + n
    n1 = n
    np1 = n + 1
    l = iv[LMAT_]
    w1 = iv[NWTSTP] + n
    k = n - iv[NC]
    for i in 1:n
        ipn = ipn - 1
        j = iv[ipn]
        if !(b[2j-1] >= b[2j])
            xi = x[j]
            gi = g[j]
            if !((xi <= b[2j-1] && gi > ZERO) || (xi >= b[2j] && gi < ZERO))
                i <= k && (iv[CNVCOD] = 0)
                continue
            end
        end
        i1 = np1 - i
        if i1 < n1
            i7shft(n1, i1, _at(iv, ipi))
            dq7rsh(i1, n1, false, g, _at(v, l), _at(v, w1))
        end
        n1 = n1 - 1
    end
    iv[NC] = n1
    v[DGNORM] = ZERO
    if n1 > 0
        dg1 = iv[DG]
        dv7vmp(n, _at(v, dg1), g, d, -1)
        dv7ipr(n, _at(iv, ipi), _at(v, dg1))
        v[DGNORM] = dv2nrm(n1, _at(v, dg1))
    end
    iv[CNVCOD] != 0 && @goto l420
    iv[MODE] == 0 && @goto l370
    v[RADIUS] = v[LMAX0]
    iv[MODE] = 0
    @label l140
    ditsum(d, g, iv, liv, lv, n, v, x)
    @label l150
    k = iv[NITER_]
    if !(k < iv[MXITER_])
        iv[1] = 10
        @goto l430
    end
    @label l160
    iv[NITER_] = k + 1
    if k != 0
        t = v[RADFAC] * v[DSTNRM]
        (v[RADFAC] < ONE || t > v[RADIUS]) && (v[RADIUS] = t)
    end
    x01 = iv[X0]
    v[F0_] = v[F_]
    iv[IRC] = 4
    iv[KAGQT] = -1
    dv7cpy(n, _at(v, x01), x)
    @label l180
    # STOPX() ist in R immer .FALSE.
    @goto l200
    @label l190
    if !(v[F_] >= v[F0_])
        v[RADFAC] = ONE
        k = iv[NITER_]
        @goto l160
    end
    @label l200
    if !(iv[NFCALL_] < iv[MXFCAL_])
        iv[1] = 9
        v[F_] >= v[F0_] && @goto l430
        iv[CNVCOD] = iv[1]
        @goto l360
    end
    @label l220
    step1 = iv[STEP]
    dg1 = iv[DG]
    nwtst1 = iv[NWTSTP]
    w1 = nwtst1 + n
    dstep1 = step1 + n
    ipi = iv[PERM_]
    l = iv[LMAT_]
    tg1 = dg1 + n
    x01 = iv[X0]
    td1 = x01 + n
    iv[KAGQT] = dd7dgb(b, d, _at(v, dg1), _at(v, dstep1), g, _at(iv, ipi), iv[KAGQT], _at(v, l), lv, n,
                       iv[NC], _at(v, nwtst1), _at(v, step1), _at(v, td1), _at(v, tg1), v, _at(v, w1),
                       _at(v, x01))
    if iv[IRC] == 6
        iv[RESTOR] != 2 && @goto l250
        rstrst = 2
        @goto l260
    end
    iv[TOOBIG_] = 0
    v[DSTNRM] <= ZERO && @goto l250
    if iv[IRC] == 5 && !(v[RADFAC] <= ONE) && !(v[PREDUC] > ONEP2 * v[FDIF_])
        iv[RESTOR] != 2 && @goto l250
        rstrst = 0
        @goto l260
    end
    dv2axy(n, x, ONE, _at(v, step1), _at(v, x01))
    iv[NFCALL_] = iv[NFCALL_] + 1
    iv[1] = 1
    @goto l440
    @label l250
    rstrst = 3
    @label l260
    x01 = iv[X0]
    v[RELDX] = drldst(n, d, x, _at(v, x01))
    da7sst(iv, liv, lv, v)
    step1 = iv[STEP]
    lstgst = iv[STLSTG]
    i = iv[RESTOR] + 1
    if i == 2
        dv7cpy(n, x, _at(v, x01))
    elseif i == 3
        dv7cpy(n, _at(v, lstgst), x)
    elseif i == 4
        dv7cpy(n, x, _at(v, lstgst))
        dv2axy(n, _at(v, step1), NEGONE, _at(v, x01), x)
        v[RELDX] = drldst(n, d, x, _at(v, x01))
        iv[RESTOR] = rstrst
    end
    k = iv[IRC]
    (k == 2 || k == 3 || k == 4) && @goto l340
    if k == 6
        v[RADIUS] = v[LMAXS]
        @goto l220
    end
    if 7 <= k <= 12
        iv[CNVCOD] = k - 4
        v[F_] >= v[F0_] && @goto l420
        iv[XIRC] == 14 && @goto l420
        iv[XIRC] = 14
        @goto l340
    end
    if k == 13
        iv[1] = 64
        @goto l430
    end
    k == 14 && @goto l370
    v[RADIUS] = v[RADFAC] * v[DSTNRM]
    @goto l180
    @label l340
    x01 = iv[X0]
    step1 = iv[STEP]
    dv2axy(n, _at(v, step1), NEGONE, _at(v, x01), x)
    if iv[IRC] == 3
        ipi = iv[PERM_]
        dv7cpy(n, _at(v, x01), _at(v, step1))
        dv7ipr(n, _at(iv, ipi), _at(v, x01))
        l = iv[LMAT_]
        dl7tvm(n, _at(v, x01), _at(v, l), _at(v, x01))
        dl7vml(n, _at(v, x01), _at(v, l), _at(v, x01))
        temp1 = iv[STLSTG]
        temp0 = temp1 - 1
        for i in 1:n
            j = iv[ipi]
            ipi = ipi + 1
            k = temp0 + j
            v[k] = v[x01]
            x01 = x01 + 1
        end
    end
    @label l360
    g01 = iv[NWTSTP] + n
    dv7cpy(n, _at(v, g01), g)
    iv[NGCALL] = iv[NGCALL] + 1
    iv[TOOBIG_] = 0
    iv[1] = 2
    return
    @label l370
    g01 = iv[NWTSTP] + n
    dv2axy(n, _at(v, g01), NEGONE, _at(v, g01), g)
    step1 = iv[STEP]
    temp1 = iv[STLSTG]
    if iv[IRC] == 3
        dv2axy(n, _at(v, temp1), NEGONE, _at(v, g01), _at(v, temp1))
        dv7vmp(n, _at(v, temp1), _at(v, temp1), d, -1)
        if dv2nrm(n, _at(v, temp1)) <= v[DGNORM] * v[TUNER4] || !(dd7tpr(n, g, _at(v, step1)) >= v[GTSTEP] * v[TUNER5])
            v[RADFAC] = v[INCFAC]
        end
    end
    w1 = iv[NWTSTP]
    z = iv[X0]
    l = iv[LMAT_]
    ipi = iv[PERM_]
    dv7ipr(n, _at(iv, ipi), _at(v, step1))
    dv7ipr(n, _at(iv, ipi), _at(v, g01))
    dw7zbf(_at(v, l), n, _at(v, step1), _at(v, w1), _at(v, g01), _at(v, z))
    dl7upd(_at(v, temp1), _at(v, step1), _at(v, l), _at(v, g01), _at(v, l), n, _at(v, w1), _at(v, z))
    iv[1] = 2
    @goto l140
    @label l410
    iv[1] = 82
    @goto l430
    @label l420
    iv[1] = iv[CNVCOD]
    iv[CNVCOD] = 0
    @label l430
    ditsum(d, g, iv, liv, lv, n, v, x)
    return
    @label l440
    for i in 1:n
        x[i] < b[2i-1] && (x[i] = b[2i-1])
        x[i] > b[2i] && (x[i] = b[2i])
    end
    return
end

# ── DRMNFB: ohne Gradient, mit Schranken ─────────────────────────────────

function drmnfb(b, d, fx::Float64, iv, liv, lv, p, v, x)
    ETA0 = 42; F_ = 10; G_ = 28; LMAT_ = 42; NEXTV_ = 47; NGCALL = 30; NITER_ = 31; PERM_ = 58
    SGIRC = 57; TOOBIG_ = 2; VNEED_ = 4
    g1 = 1
    iv1 = iv[1]
    iv1 == 1 && @goto l10
    iv1 == 2 && @goto l50
    iv[1] == 0 && divset(2, iv, liv, lv, v)
    iv1 = iv[1]
    (iv1 == 12 || iv1 == 13) && (iv[VNEED_] = iv[VNEED_] + 2p + 6)
    iv1 == 14 && @goto l10
    (iv1 > 2 && iv1 < 12) && @goto l10
    g1 = 1
    iv1 == 12 && (iv[1] = 13)
    @goto l20
    @label l10
    g1 = iv[G_]
    @label l20
    drmngb(b, d, fx, _at(v, g1), iv, liv, lv, p, v, x)
    iv[1] < 2 && return
    iv[1] > 2 && @goto l80
    iv[NITER_] == 0 && dv7scp(p, _at(v, g1), ZERO)
    j = iv[LMAT_]
    alpha0 = g1 - p - 1
    ipi = iv[PERM_]
    for i in 1:p
        k = alpha0 + iv[ipi]
        v[k] = dd7tpr(i, _at(v, j), _at(v, j))
        ipi = ipi + 1
        j = j + i
    end
    iv[NGCALL] = iv[NGCALL] - 1
    iv[SGIRC] = 0
    fx = v[F_]
    @goto l60
    @label l50
    iv[TOOBIG_] != 0 && @goto l10
    @label l60
    g1 = iv[G_]
    alpha = g1 - p
    w = alpha - 6
    fx, irc = ds3grd(_at(v, alpha), b, d, v[ETA0], fx, _at(v, g1), iv[SGIRC], p, _at(v, w), x)
    iv[SGIRC] = irc
    i = irc
    i == 0 && @goto l10
    if i > p
        iv[TOOBIG_] = 1
        @goto l10
    end
    iv[NGCALL] = iv[NGCALL] + 1
    return
    @label l80
    iv[1] != 14 && return
    iv[G_] = iv[NEXTV_] + p + 6
    iv[NEXTV_] = iv[G_] + p
    iv1 != 13 && @goto l10
    return
end

# ── Unbeschränkte Varianten: DS7GRD, DRMNG, DRMNF ────────────────────────

"DS7GRD; liefert (fx, irc)."
function ds7grd(alpha, d, eta0::Float64, fx::Float64, g, irc::Int, n, w, x)
    C2000 = 2.0e3; HMAX0 = 0.02; HMIN0 = 5.0e1; P002 = 0.002
    FH = 3; FX0 = 4; HSAVE = 5; XISAVE = 6
    i = 0; h = ZERO
    irc < 0 && @goto l140
    irc > 0 && @goto l210
    w[1] = dr7mdc(3)
    w[2] = _sqrt(w[1])
    w[FX0] = fx
    @label l110
    i = abs(irc) + 1
    if i > n
        fx = w[FX0]
        irc = 0
        return (fx, irc)
    end
    irc = i
    afx = abs(w[FX0])
    machep = w[1]
    h0 = w[2]
    hmin = HMIN0 * machep
    w[XISAVE] = x[i]
    axi = abs(x[i])
    axibar = _max2(axi, ONE / d[i])
    gi = g[i]
    agi = abs(gi)
    eta = abs(eta0)
    afx > ZERO && (eta = _max1(eta, agi * axi * machep / afx))
    alphai = alpha[i]
    if alphai == ZERO
        h = axibar
        @goto l200
    end
    if gi == ZERO || fx == ZERO
        h = h0 * axibar
        @goto l200
    end
    afxeta = afx * eta
    aai = abs(alphai)
    if !(gi * gi <= afxeta * aai)
        h = TWO * _sqrt(afxeta / aai)
        h = h * (ONE - aai * h / (THREE * aai * h + FOUR * agi))
    else
        h = TWO * _pow(afxeta * agi, ONE / THREE) * _pow(aai, -TWO / THREE)
        h = h * (ONE - TWO * agi / (THREE * aai * h + FOUR * agi))
    end
    h = _max1(h, hmin * axibar)
    if aai * h <= P002 * agi
        h >= HMAX0 * axibar && (h = h0 * axibar)
        alphai * gi < ZERO && (h = -h)
        @goto l200
    end
    discon = C2000 * afxeta
    h = discon / (agi + _sqrt(gi * gi + aai * discon))
    h = _max1(h, hmin * axibar)
    h >= HMAX0 * axibar && (h = axibar * _pow(h0, TWO / THREE))
    irc = -i
    @goto l200
    @label l140
    h = -w[HSAVE]
    i = abs(irc)
    if !(h > ZERO)
        w[FH] = fx
        @goto l200
    end
    g[i] = (w[FH] - fx) / (TWO * h)
    x[i] = w[XISAVE]
    @goto l110
    @label l200
    x[i] = w[XISAVE] + h
    w[HSAVE] = h
    return (fx, irc)
    @label l210
    g[irc] = (fx - w[FX0]) / w[HSAVE]
    x[irc] = w[XISAVE]
    @goto l110
end

function drmng(d, fx::Float64, g, iv, liv, lv, n, v, x)
    CNVCOD = 55; DG = 37; G0 = 48; INITH_ = 25; IRC = 29; KAGQT = 33; MODE = 35; MODEL = 5
    MXFCAL_ = 17; MXITER_ = 18; NFCALL_ = 6; NFGCAL_ = 7; NGCALL = 30; NITER_ = 31; NWTSTP = 34
    RADINC = 8; RESTOR = 9; STEP = 40; STGLIM = 11; STLSTG = 41; TOOBIG_ = 2; VNEED_ = 4
    XIRC = 13; X0 = 43
    DGNORM = 1; DINIT = 38; DSTNRM = 2; DST0 = 3; F_ = 10; F0_ = 13; FDIF_ = 11; GTHG = 44
    GTSTEP = 4; INCFAC = 23; LMAT_ = 42; LMAX0 = 35; LMAXS = 36; NEXTV_ = 47; NREDUC = 6
    PREDUC = 7; RADFAC = 16; RADIUS = 8; RAD0 = 9; RELDX = 17; TUNER4 = 29; TUNER5 = 30
    rstrst = 0; k = 0; x01 = 0; step1 = 0; temp1 = 0; g01 = 0; l = 0
    i = iv[1]
    i == 1 && @goto l50
    i == 2 && @goto l60
    iv[1] == 0 && divset(2, iv, liv, lv, v)
    (iv[1] == 12 || iv[1] == 13) && (iv[VNEED_] = iv[VNEED_] + n * (n + 13) ÷ 2)
    dparck(2, d, iv, liv, lv, n, v)
    i = iv[1] - 2
    i > 12 && return
    1 <= i <= 6 && @goto l190
    (i == 7 || i == 9) && @goto l120
    i == 8 && @goto l90
    i == 12 && @goto l20
    l = iv[LMAT_]
    iv[X0] = l + n * (n + 1) ÷ 2
    iv[STEP] = iv[X0] + n
    iv[STLSTG] = iv[STEP] + n
    iv[G0] = iv[STLSTG] + n
    iv[NWTSTP] = iv[G0] + n
    iv[DG] = iv[NWTSTP] + n
    iv[NEXTV_] = iv[DG] + n
    if iv[1] == 13
        iv[1] = 14
        return
    end
    @label l20
    iv[NITER_] = 0
    iv[NFCALL_] = 1
    iv[NGCALL] = 1
    iv[NFGCAL_] = 1
    iv[MODE] = -1
    iv[MODEL] = 1
    iv[STGLIM] = 1
    iv[TOOBIG_] = 0
    iv[CNVCOD] = 0
    iv[RADINC] = 0
    v[RAD0] = ZERO
    v[DINIT] >= ZERO && dv7scp(n, d, v[DINIT])
    if iv[INITH_] == 1
        l = iv[LMAT_]
        dv7scp(n * (n + 1) ÷ 2, _at(v, l), ZERO)
        k = l - 1
        for i in 1:n
            k = k + i
            t = d[i]
            t <= ZERO && (t = ONE)
            v[k] = t
        end
    end
    iv[1] = 1
    return
    @label l50
    v[F_] = fx
    iv[MODE] >= 0 && @goto l190
    v[F0_] = fx
    iv[1] = 2
    iv[TOOBIG_] == 0 && return
    iv[1] = 63
    @goto l350
    @label l60
    if iv[TOOBIG_] != 0
        iv[1] = 65
        @goto l350
    end
    dg1 = iv[DG]
    dv7vmp(n, _at(v, dg1), g, d, -1)
    v[DGNORM] = dv2nrm(n, _at(v, dg1))
    iv[CNVCOD] != 0 && @goto l340
    iv[MODE] == 0 && @goto l300
    v[RADIUS] = v[LMAX0]
    iv[MODE] = 0
    @label l80
    ditsum(d, g, iv, liv, lv, n, v, x)
    @label l90
    k = iv[NITER_]
    if !(k < iv[MXITER_])
        iv[1] = 10
        @goto l350
    end
    @label l100
    iv[NITER_] = k + 1
    k > 0 && (v[RADIUS] = v[RADFAC] * v[DSTNRM])
    g01 = iv[G0]
    x01 = iv[X0]
    v[F0_] = v[F_]
    iv[IRC] = 4
    iv[KAGQT] = -1
    dv7cpy(n, _at(v, x01), x)
    dv7cpy(n, _at(v, g01), g)
    # 110: STOPX() ist in R immer .FALSE.
    @goto l130
    @label l120
    if !(v[F_] >= v[F0_])
        v[RADFAC] = ONE
        k = iv[NITER_]
        @goto l100
    end
    @label l130
    if !(iv[NFCALL_] < iv[MXFCAL_])
        iv[1] = 9
        v[F_] >= v[F0_] && @goto l350
        iv[CNVCOD] = iv[1]
        @goto l290
    end
    @label l150
    step1 = iv[STEP]
    dg1 = iv[DG]
    nwtst1 = iv[NWTSTP]
    if iv[KAGQT] < 0
        l = iv[LMAT_]
        dl7ivm(n, _at(v, nwtst1), _at(v, l), g)
        v[NREDUC] = HALF * dd7tpr(n, _at(v, nwtst1), _at(v, nwtst1))
        dl7itv(n, _at(v, nwtst1), _at(v, l), _at(v, nwtst1))
        dv7vmp(n, _at(v, step1), _at(v, nwtst1), d, 1)
        v[DST0] = dv2nrm(n, _at(v, step1))
        dv7vmp(n, _at(v, dg1), _at(v, dg1), d, -1)
        dl7tvm(n, _at(v, step1), _at(v, l), _at(v, dg1))
        v[GTHG] = dv2nrm(n, _at(v, step1))
        iv[KAGQT] = 0
    end
    dd7dog(_at(v, dg1), lv, n, _at(v, nwtst1), _at(v, step1), v)
    if iv[IRC] == 6
        iv[RESTOR] != 2 && @goto l190
        rstrst = 2
        @goto l200
    end
    iv[TOOBIG_] = 0
    v[DSTNRM] <= ZERO && @goto l190
    if iv[IRC] == 5 && !(v[RADFAC] <= ONE) && !(v[PREDUC] > ONEP2 * v[FDIF_])
        iv[RESTOR] != 2 && @goto l190
        rstrst = 0
        @goto l200
    end
    x01 = iv[X0]
    step1 = iv[STEP]
    dv2axy(n, x, ONE, _at(v, step1), _at(v, x01))
    iv[NFCALL_] = iv[NFCALL_] + 1
    iv[1] = 1
    return
    @label l190
    rstrst = 3
    @label l200
    x01 = iv[X0]
    v[RELDX] = drldst(n, d, x, _at(v, x01))
    da7sst(iv, liv, lv, v)
    step1 = iv[STEP]
    lstgst = iv[STLSTG]
    i = iv[RESTOR] + 1
    if i == 2
        dv7cpy(n, x, _at(v, x01))
    elseif i == 3
        dv7cpy(n, _at(v, lstgst), _at(v, step1))
    elseif i == 4
        dv7cpy(n, _at(v, step1), _at(v, lstgst))
        dv2axy(n, x, ONE, _at(v, step1), _at(v, x01))
        v[RELDX] = drldst(n, d, x, _at(v, x01))
        iv[RESTOR] = rstrst
    end
    k = iv[IRC]
    (k == 2 || k == 3 || k == 4) && @goto l280
    if k == 6
        v[RADIUS] = v[LMAXS]
        @goto l150
    end
    if 7 <= k <= 12
        iv[CNVCOD] = k - 4
        v[F_] >= v[F0_] && @goto l340
        iv[XIRC] == 14 && @goto l340
        iv[XIRC] = 14
        @goto l280
    end
    if k == 13
        iv[1] = 64
        @goto l350
    end
    k == 14 && @goto l300
    v[RADIUS] = v[RADFAC] * v[DSTNRM]
    @goto l130
    @label l280
    if iv[IRC] == 3
        step1 = iv[STEP]
        temp1 = iv[STLSTG]
        l = iv[LMAT_]
        dl7tvm(n, _at(v, temp1), _at(v, l), _at(v, step1))
        dl7vml(n, _at(v, temp1), _at(v, l), _at(v, temp1))
    end
    @label l290
    iv[NGCALL] = iv[NGCALL] + 1
    iv[1] = 2
    return
    @label l300
    g01 = iv[G0]
    dv2axy(n, _at(v, g01), NEGONE, _at(v, g01), g)
    step1 = iv[STEP]
    temp1 = iv[STLSTG]
    if iv[IRC] == 3
        dv2axy(n, _at(v, temp1), NEGONE, _at(v, g01), _at(v, temp1))
        dv7vmp(n, _at(v, temp1), _at(v, temp1), d, -1)
        if dv2nrm(n, _at(v, temp1)) <= v[DGNORM] * v[TUNER4] || !(dd7tpr(n, g, _at(v, step1)) >= v[GTSTEP] * v[TUNER5])
            v[RADFAC] = v[INCFAC]
        end
    end
    w = iv[NWTSTP]
    z = iv[X0]
    l = iv[LMAT_]
    dw7zbf(_at(v, l), n, _at(v, step1), _at(v, w), _at(v, g01), _at(v, z))
    dl7upd(_at(v, temp1), _at(v, step1), _at(v, l), _at(v, g01), _at(v, l), n, _at(v, w), _at(v, z))
    iv[1] = 2
    @goto l80
    @label l340
    iv[1] = iv[CNVCOD]
    iv[CNVCOD] = 0
    @label l350
    ditsum(d, g, iv, liv, lv, n, v, x)
    return
end

function drmnf(d, fx::Float64, iv, liv, lv, n, v, x)
    ETA0 = 42; F_ = 10; G_ = 28; LMAT_ = 42; NEXTV_ = 47; NGCALL = 30; NITER_ = 31; SGIRC = 57
    TOOBIG_ = 2; VNEED_ = 4
    g1 = 1
    iv1 = iv[1]
    iv1 == 1 && @goto l10
    iv1 == 2 && @goto l50
    iv[1] == 0 && divset(2, iv, liv, lv, v)
    iv1 = iv[1]
    (iv1 == 12 || iv1 == 13) && (iv[VNEED_] = iv[VNEED_] + 2n + 6)
    iv1 == 14 && @goto l10
    (iv1 > 2 && iv1 < 12) && @goto l10
    g1 = 1
    iv1 == 12 && (iv[1] = 13)
    @goto l20
    @label l10
    g1 = iv[G_]
    @label l20
    drmng(d, fx, _at(v, g1), iv, liv, lv, n, v, x)
    iv[1] < 2 && return
    iv[1] > 2 && @goto l70
    iv[NITER_] == 0 && dv7scp(n, _at(v, g1), ZERO)
    j = iv[LMAT_]
    k = g1 - n
    for i in 1:n
        v[k] = dd7tpr(i, _at(v, j), _at(v, j))
        k = k + 1
        j = j + i
    end
    iv[NGCALL] = iv[NGCALL] - 1
    iv[SGIRC] = 0
    fx = v[F_]
    @goto l60
    @label l50
    iv[TOOBIG_] != 0 && @goto l10
    @label l60
    g1 = iv[G_]
    alpha = g1 - n
    w = alpha - 6
    fx, irc = ds7grd(_at(v, alpha), d, v[ETA0], fx, _at(v, g1), iv[SGIRC], n, _at(v, w), x)
    iv[SGIRC] = irc
    irc == 0 && @goto l10
    iv[NGCALL] = iv[NGCALL] + 1
    return
    @label l70
    iv[1] != 14 && return
    iv[G_] = iv[NEXTV_] + n + 6
    iv[NEXTV_] = iv[G_] + n
    iv1 != 13 && @goto l10
    return
end

# ── Varianten mit Hesse-Matrix: Hilfsroutinen ────────────────────────────

@inline _min1(a::Float64, b::Float64) = a < b ? a : b
@inline _min2(a::Float64, b::Float64) = b < a ? b : a

function dd7dup(d, hdiag, iv, liv, lv, n, v)
    DFAC = 41; DTOL = 59; DTYPE_ = 16; NITER_ = 31
    i = iv[DTYPE_]
    (i != 1 && iv[NITER_] > 0) && return
    dtoli = iv[DTOL]
    d0i = dtoli + n
    vdfac = v[DFAC]
    for i in 1:n
        t = _max1(_sqrt(abs(hdiag[i])), vdfac * d[i])
        t < v[dtoli] && (t = _max1(v[dtoli], v[d0i]))
        d[i] = t
        dtoli = dtoli + 1
        d0i = d0i + 1
    end
    return
end

"Cholesky-Zerlegung (Zeilen n1..n); liefert irc."
function dl7srt(n1, n, l, a)
    i0 = n1 * (n1 - 1) ÷ 2
    for i in n1:n
        td = ZERO
        if i != 1
            j0 = 0
            for j in 1:i-1
                t = ZERO
                for k in 1:j-1
                    t = t + l[i0+k] * l[j0+k]
                end
                ij = i0 + j
                j0 = j0 + j
                t = (a[ij] - t) / l[j0]
                l[ij] = t
                td = td + t * t
            end
        end
        i0 = i0 + i
        t = a[i0] - td
        if t <= ZERO
            l[i0] = t
            return i
        end
        l[i0] = _sqrt(t)
    end
    return 0
end

"Schätzung des kleinsten Singulärwerts von L."
function dl7svn(p, l, x, y)
    R9973 = 9973.0
    ix = 2
    pm1 = p - 1
    ii = 0
    j0 = p * pm1 ÷ 2
    jj = j0 + p
    l[jj] == ZERO && return ZERO
    ix = (3432 * ix) % 9973
    b = HALF * (ONE + Float64(ix) / R9973)
    xplus = b / l[jj]
    x[p] = xplus
    if p > 1
        for i in 1:pm1
            ii = ii + i
            l[ii] == ZERO && return ZERO
            ji = j0 + i
            x[i] = xplus * l[ji]
        end
        for jjj in 1:pm1
            j = p - jjj
            ix = (3432 * ix) % 9973
            b = HALF * (ONE + Float64(ix) / R9973)
            xplus = (b - x[j])
            xminus = (-b - x[j])
            splus = abs(xplus)
            sminus = abs(xminus)
            jm1 = j - 1
            j0 = j * jm1 ÷ 2
            jj = j0 + j
            xplus = xplus / l[jj]
            xminus = xminus / l[jj]
            for i in 1:jm1
                ji = j0 + i
                splus = splus + abs(x[i] + l[ji] * xplus)
                sminus = sminus + abs(x[i] + l[ji] * xminus)
            end
            sminus > splus && (xplus = xminus)
            x[j] = xplus
            jm1 > 0 && dv2axy(jm1, x, xplus, _at(l, j0 + 1), x)
        end
    end
    t = ONE / dv2nrm(p, x)
    for i in 1:p
        x[i] = t * x[i]
    end
    for j in 1:p
        jm1 = j - 1
        j0 = j * jm1 ÷ 2
        jj = j0 + j
        t = ZERO
        jm1 > 0 && (t = dd7tpr(jm1, _at(l, j0 + 1), y))
        y[j] = (x[j] - t) / l[jj]
    end
    return ONE / dv2nrm(p, y)
end

"y = S x (S symmetrisch, unteres Dreieck zeilenweise)."
function ds7lvm(p, y, s, x)
    j = 1
    for i in 1:p
        y[i] = dd7tpr(i, _at(s, j), x)
        j = j + i
    end
    p <= 1 && return
    j = 1
    for i in 2:p
        xi = x[i]
        j = j + 1
        for k in 1:i-1
            y[k] = y[k] + s[j] * xi
            j = j + 1
        end
    end
    return
end

"Symmetrische Permutation von H (kompakt) nach ip; ip wird zurückgesetzt."
function ds7ipr(p, ip, h)
    for i in 1:p
        j = ip[i]
        j == i && continue
        ip[i] = abs(j)
        j < 0 && continue
        k = i
        while true
            j1 = j
            k1 = k
            if j > k
                j1 = k
                k1 = j
            end
            kmj = k1 - j1
            l = j1 - 1
            jm = j1 * l ÷ 2
            km = k1 * (k1 - 1) ÷ 2
            for m in 1:l
                jm = jm + 1
                t = h[jm]
                km = km + 1
                h[jm] = h[km]
                h[km] = t
            end
            km = km + 1
            kk = km + kmj
            jm = jm + 1
            t = h[jm]
            h[jm] = h[kk]
            h[kk] = t
            j1 = l
            l = kmj - 1
            for m in 1:l
                jm = jm + j1 + m
                t = h[jm]
                km = km + 1
                h[jm] = h[km]
                h[km] = t
            end
            if k1 < p
                l = p - k1
                k1 = k1 - 1
                km = kk
                for m in 1:l
                    km = km + k1 + m
                    jm = km - kmj
                    t = h[jm]
                    h[jm] = h[km]
                    h[km] = t
                end
            end
            k = j
            j = ip[k]
            ip[k] = -j
            j > i || break
        end
    end
    return
end

const _BIG = dr7mdc(6)
const _DGXFAC = 50.0 * dr7mdc(3)

"Goldfeld-Quandt-Trotter-Schritt (More-Hebden); liefert das neue ka."
function dg7qts(d, dig, dihdi, ka::Int, l, p, step, v, w)
    DGNORM = 1; DSTNRM = 2; DST0 = 3; EPSLON = 19; GTSTEP = 4; NREDUC = 6; PHMNFC = 20
    PHMXFC = 21; PREDUC = 7; RADIUS = 8; RAD0 = 9; STPPAR = 5
    KAPPA = 2.0; P001 = 1.0e-3; SIX = 6.0
    big = _BIG
    dggdmx = p + 1
    emax = dggdmx + 1
    emin = emax + 1
    lk0 = emin + 1
    phipin = lk0 + 1
    uk0 = phipin + 1
    dstsav = uk0 + 1
    diag0 = dstsav
    diag = diag0 + 1
    q0 = diag0 + p
    q = q0 + 1
    X = q + p
    rad = v[RADIUS]
    radsq = rad * rad
    phimax = v[PHMXFC] * rad
    phimin = v[PHMNFC] * rad
    psifac = big
    t1 = TWO * v[EPSLON] / (THREE * (FOUR * (v[PHMNFC] + ONE) * (KAPPA + ONE) + KAPPA + TWO) * rad)
    t1 < big * _min2(rad, ONE) && (psifac = t1 / rad)
    oldphi = ZERO
    eps = v[EPSLON]
    irc = 0
    restrt = false
    kalim = ka + 50
    phi = ZERO; gtsta = ZERO; dst = ZERO; alphak = ZERO; lk = ZERO; uk = ZERO; kamin = 0
    delta = ZERO; twopsi = ZERO; si = ZERO; sw = ZERO; t = ZERO; k = 0; t2 = ZERO
    ka >= 0 && @goto l290
    k = 0
    uk = NEGONE
    ka = 0
    kalim = 50
    v[DGNORM] = dv2nrm(p, dig)
    v[NREDUC] = ZERO
    v[DST0] = ZERO
    kamin = 3
    v[DGNORM] == ZERO && (kamin = 0)
    j = 0
    for i in 1:p
        j = j + i
        w[diag0+i] = dihdi[j]
    end
    t1 = ZERO
    for i in 1:(p * (p + 1) ÷ 2)
        t = abs(dihdi[i])
        t1 < t && (t1 = t)
    end
    w[dggdmx] = t1
    @label l30
    irc = dl7srt(1, p, l, dihdi)
    irc == 0 && @goto l50
    j = irc * (irc + 1) ÷ 2
    t = l[j]
    l[j] = ONE
    for i in 1:irc
        w[i] = ZERO
    end
    w[irc] = ONE
    dl7itv(irc, w, l, w)
    t1 = dv2nrm(irc, w)
    lk = -t / t1 / t1
    v[DST0] = -lk
    restrt && @goto l210
    @goto l70
    @label l50
    lk = ZERO
    t = dl7svn(p, l, _at(w, q), _at(w, q))
    t >= ONE && @goto l60
    v[DGNORM] >= t * t * big && @goto l70
    @label l60
    dl7ivm(p, _at(w, q), l, dig)
    gtsta = dd7tpr(p, _at(w, q), _at(w, q))
    v[NREDUC] = HALF * gtsta
    dl7itv(p, _at(w, q), l, _at(w, q))
    dst = dv2nrm(p, _at(w, q))
    v[DST0] = dst
    phi = dst - rad
    phi <= phimax && @goto l260
    restrt && @goto l210
    @label l70
    k = 0
    for i in 1:p
        wi = ZERO
        for j in 1:i-1
            k = k + 1
            t = abs(dihdi[k])
            wi = wi + t
            w[j] = w[j] + t
        end
        w[i] = wi
        k = k + 1
    end
    k = 1
    t1 = w[diag] - w[1]
    for i in 2:p
        j = diag0 + i
        t = w[j] - w[i]
        t >= t1 && continue
        t1 = t
        k = i
    end
    sk = w[k]
    akk = w[diag0+k]
    k1 = k * (k - 1) ÷ 2 + 1
    inc = 1
    t = ZERO
    for i in 1:p
        if i != k
            aki = abs(dihdi[k1])
            si = w[i]
            j = diag0 + i
            t1 = HALF * (akk - w[j] + si - aki)
            t1 = t1 + _sqrt(t1 * t1 + sk * aki)
            t < t1 && (t = t1)
            if i < k
                k1 = k1 + inc
                continue
            end
        end
        inc = i
        k1 = k1 + inc
    end
    w[emin] = akk - t
    uk = v[DGNORM] / rad - w[emin]
    v[DGNORM] == ZERO && (uk = uk + P001 + P001 * uk)
    uk <= ZERO && (uk = P001)
    k = 1
    t1 = w[diag] + w[1]
    for i in 2:p
        j = diag0 + i
        t = w[j] + w[i]
        t <= t1 && continue
        t1 = t
        k = i
    end
    sk = w[k]
    akk = w[diag0+k]
    k1 = k * (k - 1) ÷ 2 + 1
    inc = 1
    t = ZERO
    for i in 1:p
        if i != k
            aki = abs(dihdi[k1])
            si = w[i]
            j = diag0 + i
            t1 = HALF * (w[j] + si - aki - akk)
            t1 = t1 + _sqrt(t1 * t1 + sk * aki)
            t < t1 && (t = t1)
            if i < k
                k1 = k1 + inc
                continue
            end
        end
        inc = i
        k1 = k1 + inc
    end
    w[emax] = akk + t
    lk = _max1(lk, v[DGNORM] / rad - w[emax])
    alphak = abs(v[STPPAR]) * v[RAD0] / rad
    alphak = _min2(uk, _max1(alphak, lk))
    irc != 0 && @goto l210
    dl7ivm(p, w, l, _at(w, q))
    t = dv2nrm(p, w)
    w[phipin] = rad / t / t
    lk = _max1(lk, phi * w[phipin])
    @label l210
    ka = ka + 1
    (-v[DST0] >= alphak || alphak < lk || alphak >= uk) && (alphak = uk * _max2(P001, _sqrt(lk / uk)))
    alphak <= ZERO && (alphak = HALF * uk)
    alphak <= ZERO && (alphak = uk)
    k = 0
    for i in 1:p
        k = k + i
        dihdi[k] = w[diag0+i] + alphak
    end
    irc = dl7srt(1, p, l, dihdi)
    irc == 0 && @goto l240
    j = (irc * (irc + 1)) ÷ 2
    t = l[j]
    l[j] = ONE
    for i in 1:irc
        w[i] = ZERO
    end
    w[irc] = ONE
    dl7itv(irc, w, l, w)
    t1 = dv2nrm(irc, w)
    lk = alphak - t / t1 / t1
    v[DST0] = -lk
    uk < lk && (uk = lk)
    alphak < lk && @goto l210
    t = P001 * alphak
    t <= ZERO && (t = P001)
    lk = alphak + t
    uk <= lk && (uk = lk + t)
    @goto l210
    @label l240
    dl7ivm(p, _at(w, q), l, dig)
    gtsta = dd7tpr(p, _at(w, q), _at(w, q))
    dl7itv(p, _at(w, q), l, _at(w, q))
    dst = dv2nrm(p, _at(w, q))
    phi = dst - rad
    phi <= phimax && phi >= phimin && @goto l270
    phi == oldphi && @goto l270
    oldphi = phi
    phi < ZERO && @goto l330
    @label l250
    ka >= kalim && @goto l270
    phi < ZERO && (uk = _min1(uk, alphak))
    kamin == 0 && @goto l210
    dl7ivm(p, w, l, _at(w, q))
    t1 = dv2nrm(p, w)
    alphak = alphak + (phi / t1) * (dst / t1) * (dst / rad)
    lk = _max2(lk, alphak)
    alphak = lk
    @goto l210
    @label l260
    alphak = ZERO
    @label l270
    for i in 1:p
        step[i] = -w[q0+i] / d[i]
    end
    v[GTSTEP] = -gtsta
    v[PREDUC] = HALF * (abs(alphak) * dst * dst + gtsta)
    @goto l410
    @label l290
    (v[DST0] <= ZERO || v[DST0] - rad > phimax) && @goto l310
    restrt = true
    ka = ka + 1
    k = 0
    for i in 1:p
        k = k + i
        dihdi[k] = w[diag0+i]
    end
    uk = NEGONE
    @goto l30
    @label l310
    kamin = ka + 3
    v[DGNORM] == ZERO && (kamin = 0)
    ka == 0 && @goto l50
    dst = w[dstsav]
    alphak = abs(v[STPPAR])
    phi = dst - rad
    t = v[DGNORM] / rad
    uk = t - w[emin]
    v[DGNORM] == ZERO && (uk = uk + P001 + P001 * uk)
    uk <= ZERO && (uk = P001)
    rad > v[RAD0] && @goto l320
    lk = ZERO
    alphak > ZERO && (lk = w[lk0])
    lk = _max1(lk, t - w[emax])
    v[DST0] > ZERO && (lk = _max1(lk, (v[DST0] - rad) * w[phipin]))
    @goto l250
    @label l320
    alphak > ZERO && (uk = _min1(uk, w[uk0]))
    lk = _max1(_max2(ZERO, -v[DST0]), t - w[emax])
    v[DST0] > ZERO && (lk = _max1(lk, (v[DST0] - rad) * w[phipin]))
    @goto l250
    @label l330
    delta = alphak + _min1(ZERO, v[DST0])
    twopsi = alphak * dst * dst + gtsta
    ka >= kamin && @goto l340
    psifac >= big && @goto l340
    delta >= psifac * twopsi && @goto l370
    @label l340
    t = dl7svn(p, l, _at(w, X), w)
    for i in 1:p
        w[i] = t * w[i]
    end
    dl7itv(p, w, l, w)
    t2 = ONE / dv2nrm(p, w)
    for i in 1:p
        w[i] = t2 * w[i]
    end
    t = t2 * t
    sw = dd7tpr(p, _at(w, q), w)
    t1 = (rad + dst) * (rad - dst)
    root = _sqrt(sw * sw + t1)
    sw < ZERO && (root = -root)
    si = t1 / (sw + root)
    q2 = t2 * si
    q2 * q2 <= eps * (dst * dst + alphak * radsq) && @goto l380
    v[DST0] <= ZERO && (v[DST0] = _min1(v[DST0], t2 * t2 - alphak))
    lk = _max1(lk, -v[DST0])
    @label l370
    delta > _DGXFAC * w[dggdmx] && @goto l250
    @goto l270
    @label l380
    alphak = -alphak
    v[PREDUC] = HALF * twopsi
    t1 = ZERO
    t = si * (alphak * sw - HALF * si * (alphak + t * dd7tpr(p, _at(w, X), w)))
    if !(t < eps * twopsi / SIX)
        v[PREDUC] = v[PREDUC] + t
        dst = rad
        t1 = -si
    end
    for i in 1:p
        j = q0 + i
        w[j] = t1 * w[i] - w[j]
        step[i] = w[j] / d[i]
    end
    v[GTSTEP] = dd7tpr(p, dig, _at(w, q))
    @label l410
    v[DSTNRM] = dst
    v[STPPAR] = alphak
    w[lk0] = lk
    w[uk0] = uk
    v[RAD0] = rad
    w[dstsav] = dst
    j = 0
    for i in 1:p
        j = j + i
        dihdi[j] = w[diag0+i]
    end
    return ka
end

"DS7BQN; liefert (kb, ns, p1)."
function ds7bqn(b, d, dst, ipiv, ipiv1, ipiv2, kb::Int, l, lv, p, p1::Int, step, td, tg, v, w, x, x0)
    DSTNRM = 2; GTSTEP = 4; PHMNFC = 20; PHMXFC = 21; PREDUC = 7; RADIUS = 8; STPPAR = 5
    FUDGE = 1.0001
    meps2 = _MEPS2
    dstmax = FUDGE * (ONE + v[PHMXFC]) * v[RADIUS]
    dstmin = (ONE + v[PHMNFC]) * v[RADIUS]
    dst1 = ZERO
    p0 = p1
    ns = 0
    for i in 1:p
        ipiv1[i] = i
        ipiv2[i] = i
    end
    for i in 1:p1
        w[i] = -step[i] * td[i]
    end
    alpha = abs(v[STPPAR])
    v[PREDUC] = ZERO
    gts = -v[GTSTEP]
    kb < 0 && dv7scp(p, dst, ZERO)
    kb = 1
    while true
        t = ONE
        k = 0
        for i in 1:p1
            j = ipiv[i]
            dx = w[i] / d[j]
            xi = x[j] - dx
            if xi < b[2j-1]
                ti = (x[j] - b[2j-1]) / dx
                k = -i
            elseif xi <= b[2j]
                continue
            else
                ti = (x[j] - b[2j]) / dx
                k = i
            end
            t <= ti && continue
            t = ti
        end
        p > p1 && dv7cpy(p - p1, _at(step, p1 + 1), _at(dst, p1 + 1))
        dv2axy(p1, step, -t, w, dst)
        dst0 = dst1
        dst1 = dv2nrm(p, step)
        if !(dst1 <= dstmax)
            if !(p1 >= p0)
                dst0 < dstmin && (kb = 0)
                break
            end
            k = 0
        end
        v[DSTNRM] = dst1
        dv7cpy(p1, dst, step)
        t1 = ONE - t
        for i in 1:p1
            tg[i] = t1 * tg[i]
        end
        alpha > ZERO && dv2axy(p1, tg, t * alpha, w, tg)
        v[PREDUC] = v[PREDUC] + t * ((ONE - HALF * t) * gts + HALF * alpha * t * dd7tpr(p1, w, w))
        k == 0 && break
        p1m1 = p1 - 1
        j = abs(k)
        if j != p1
            ns = ns + 1
            ipiv2[p1] = j
            dq7rsh(j, p1, false, tg, l, w)
            i7shft(p1, j, ipiv)
            i7shft(p1, j, ipiv1)
            dv7shf(p1, j, tg)
            dv7shf(p1, j, dst)
        end
        k < 0 && (ipiv[p1] = -ipiv[p1])
        p1 = p1m1
        p1 <= 0 && break
        dl7ivm(p1, w, l, tg)
        gts = dd7tpr(p1, w, w)
        dl7itv(p1, w, l, w)
    end
    for i in 1:p
        j = abs(ipiv[i])
        step[j] = dst[i] / d[j]
    end
    if p1 < p0
        for i in p1+1:p0
            j = ipiv[i]
            t = meps2
            if !(j > 0)
                t = -t
                j = -j
                ipiv[i] = j
            end
            t = t * _max1(abs(x[j]), abs(x0[j]))
            step[j] = step[j] + t
        end
    end
    dv2axy(p, x, ONE, step, x0)
    ns > 0 && dv7ipr(p0, ipiv1, td)
    return (kb, ns, p1)
end

"DG7QSB; liefert (ka, p0)."
function dg7qsb(b, d, dihdi, g, ipiv, ipiv1, ipiv2, ka::Int, l, lv, p, p0::Int, pc::Int, step, td, tg, v, w, x, x0)
    DST0 = 3; DSTNRM = 2; GTSTEP = 4; NREDUC = 6; PREDUC = 7; RADIUS = 8
    p1 = pc
    nred = ZERO; ds0 = ZERO
    if ka >= 0
        nred = v[NREDUC]
        ds0 = v[DST0]
    else
        p0 = 0
        ka = -1
    end
    kinit = -1
    p0 == p1 && (kinit = ka)
    dv7cpy(p, x, x0)
    pred = ZERO
    rad = v[RADIUS]
    kb = -1
    v[DSTNRM] = ZERO
    if !(p1 > 0)
        nred = ZERO
        ds0 = ZERO
        dv7scp(p, step, ZERO)
    else
        dv7cpy(p, td, d)
        dv7ipr(p, ipiv, td)
        dv7vmp(p, tg, g, d, -1)
        dv7ipr(p, ipiv, tg)
        while true
            k = kinit
            kinit = -1
            v[RADIUS] = rad - v[DSTNRM]
            k = dg7qts(td, tg, dihdi, k, l, p1, step, v, w)
            p0 = p1
            if ka < 0
                nred = v[NREDUC]
                ds0 = v[DST0]
            end
            ka = k
            v[RADIUS] = rad
            p10 = p1
            kb, ns, p1 = ds7bqn(b, d, _at(step, p + 1), ipiv, ipiv1, ipiv2, kb, l, lv, p, p1, step, td, tg, v, w, x, x0)
            ns > 0 && ds7ipr(p10, ipiv1, dihdi)
            pred = pred + v[PREDUC]
            ns != 0 && (p0 = 0)
            kb <= 0 || break
        end
    end
    v[DST0] = ds0
    v[NREDUC] = nred
    v[PREDUC] = pred
    v[GTSTEP] = dd7tpr(p, g, step)
    return (ka, p0)
end

# ── DRMNH / DRMNHB: Gradient und Hesse-Matrix vom Aufrufer ───────────────

function drmnh(d, fx::Float64, g, h, iv, liv, lv, n, v, x)
    lh = n * (n + 1) ÷ 2
    CNVCOD = 55; DG = 37; DTOL = 59; DTYPE_ = 16; IRC = 29; KAGQT = 33; LMAT_ = 42; MODE = 35
    MODEL = 5; MXFCAL_ = 17; MXITER_ = 18; NEXTV_ = 47; NFCALL_ = 6; NFGCAL_ = 7; NGCALL = 30
    NITER_ = 31; RADINC = 8; RESTOR = 9; STEP = 40; STGLIM = 11; STLSTG = 41; TOOBIG_ = 2
    VNEED_ = 4; W = 34; XIRC = 13; X0 = 43
    DGNORM = 1; DINIT = 38; DSTNRM = 2; DTINIT = 39; D0INIT = 40; F_ = 10; F0_ = 13; FDIF_ = 11
    GTSTEP = 4; INCFAC = 23; LMAX0 = 35; LMAXS = 36; PHMXFC = 21; PREDUC = 7; RADFAC = 16
    RADIUS = 8; RAD0 = 9; RELDX = 17; STPPAR = 5; TUNER4 = 29; TUNER5 = 30
    rstrst = 0; k = 0; x01 = 0; step1 = 0; lstgst = 0; temp1 = 0
    i = iv[1]
    i == 1 && @goto l30
    i == 2 && @goto l40
    iv[1] == 0 && divset(2, iv, liv, lv, v)
    (iv[1] == 12 || iv[1] == 13) && (iv[VNEED_] = iv[VNEED_] + n * (n + 21) ÷ 2 + 7)
    dparck(2, d, iv, liv, lv, n, v)
    i = iv[1] - 2
    i > 12 && return
    nn1o2 = n * (n + 1) ÷ 2
    if lh >= nn1o2
        1 <= i <= 6 && @goto l220
        (i == 7 || i == 9) && @goto l160
        i == 8 && @goto l120
        (i == 10 || i == 11) && @goto l10
        i == 12 && @goto l20
    end
    iv[1] = 66
    @goto l400
    @label l10
    iv[DTOL] = iv[LMAT_] + nn1o2
    iv[X0] = iv[DTOL] + 2n
    iv[STEP] = iv[X0] + n
    iv[STLSTG] = iv[STEP] + n
    iv[DG] = iv[STLSTG] + n
    iv[W] = iv[DG] + n
    iv[NEXTV_] = iv[W] + 4n + 7
    if iv[1] == 13
        iv[1] = 14
        return
    end
    @label l20
    iv[NITER_] = 0
    iv[NFCALL_] = 1
    iv[NGCALL] = 1
    iv[NFGCAL_] = 1
    iv[MODE] = -1
    iv[MODEL] = 1
    iv[STGLIM] = 1
    iv[TOOBIG_] = 0
    iv[CNVCOD] = 0
    iv[RADINC] = 0
    v[RAD0] = ZERO
    v[STPPAR] = ZERO
    v[DINIT] >= ZERO && dv7scp(n, d, v[DINIT])
    k = iv[DTOL]
    v[DTINIT] > ZERO && dv7scp(n, _at(v, k), v[DTINIT])
    k = k + n
    v[D0INIT] > ZERO && dv7scp(n, _at(v, k), v[D0INIT])
    iv[1] = 1
    return
    @label l30
    v[F_] = fx
    iv[MODE] >= 0 && @goto l220
    v[F0_] = fx
    iv[1] = 2
    iv[TOOBIG_] == 0 && return
    iv[1] = 63
    @goto l400
    @label l40
    if iv[TOOBIG_] != 0
        iv[1] = 65
        @goto l400
    end
    dg1 = iv[DG]
    if iv[DTYPE_] > 0
        k = dg1
        j = 0
        for i in 1:n
            j = j + i
            v[k] = h[j]
            k = k + 1
        end
        dd7dup(d, _at(v, dg1), iv, liv, lv, n, v)
    end
    dg1 = iv[DG]
    k = dg1
    for i in 1:n
        v[k] = g[i] / d[i]
        k = k + 1
    end
    v[DGNORM] = dv2nrm(n, _at(v, dg1))
    k = 1
    for i in 1:n
        t = ONE / d[i]
        for j in 1:i
            h[k] = t * h[k] / d[j]
            k = k + 1
        end
    end
    iv[CNVCOD] != 0 && @goto l390
    iv[MODE] == 0 && @goto l350
    v[RADIUS] = v[LMAX0] / (ONE + v[PHMXFC])
    iv[MODE] = 0
    @label l110
    ditsum(d, g, iv, liv, lv, n, v, x)
    @label l120
    k = iv[NITER_]
    if !(k < iv[MXITER_])
        iv[1] = 10
        @goto l400
    end
    @label l130
    iv[NITER_] = k + 1
    dg1 = iv[DG]
    x01 = iv[X0]
    v[F0_] = v[F_]
    iv[IRC] = 4
    iv[KAGQT] = -1
    dv7cpy(n, _at(v, x01), x)
    if k != 0
        step1 = iv[STEP]
        k = step1
        for i in 1:n
            v[k] = d[i] * v[k]
            k = k + 1
        end
        v[RADIUS] = v[RADFAC] * dv2nrm(n, _at(v, step1))
    end
    # 150: STOPX() ist in R immer .FALSE.
    @goto l170
    @label l160
    if !(v[F_] >= v[F0_])
        v[RADFAC] = ONE
        k = iv[NITER_]
        @goto l130
    end
    @label l170
    if !(iv[NFCALL_] < iv[MXFCAL_])
        iv[1] = 9
        v[F_] >= v[F0_] && @goto l400
        iv[CNVCOD] = iv[1]
        @goto l340
    end
    @label l190
    step1 = iv[STEP]
    dg1 = iv[DG]
    l = iv[LMAT_]
    w1 = iv[W]
    iv[KAGQT] = dg7qts(d, _at(v, dg1), h, iv[KAGQT], _at(v, l), n, _at(v, step1), v, _at(v, w1))
    if iv[IRC] == 6
        iv[RESTOR] != 2 && @goto l220
        rstrst = 2
        @goto l230
    end
    iv[TOOBIG_] = 0
    v[DSTNRM] <= ZERO && @goto l220
    if iv[IRC] == 5 && !(v[RADFAC] <= ONE) && !(v[PREDUC] > ONEP2 * v[FDIF_])
        iv[RESTOR] != 2 && @goto l220
        rstrst = 0
        @goto l230
    end
    x01 = iv[X0]
    step1 = iv[STEP]
    dv2axy(n, x, ONE, _at(v, step1), _at(v, x01))
    iv[NFCALL_] = iv[NFCALL_] + 1
    iv[1] = 1
    return
    @label l220
    rstrst = 3
    @label l230
    x01 = iv[X0]
    v[RELDX] = drldst(n, d, x, _at(v, x01))
    da7sst(iv, liv, lv, v)
    step1 = iv[STEP]
    lstgst = iv[STLSTG]
    i = iv[RESTOR] + 1
    if i == 2
        dv7cpy(n, x, _at(v, x01))
    elseif i == 3
        dv7cpy(n, _at(v, lstgst), _at(v, step1))
    elseif i == 4
        dv7cpy(n, _at(v, step1), _at(v, lstgst))
        dv2axy(n, x, ONE, _at(v, step1), _at(v, x01))
        v[RELDX] = drldst(n, d, x, _at(v, x01))
        iv[RESTOR] = rstrst
    end
    k = iv[IRC]
    (k == 2 || k == 3 || k == 4) && @goto l310
    if k == 6
        v[RADIUS] = v[LMAXS]
        @goto l190
    end
    if 7 <= k <= 12
        iv[CNVCOD] = k - 4
        v[F_] >= v[F0_] && @goto l390
        iv[XIRC] == 14 && @goto l390
        iv[XIRC] = 14
        @goto l310
    end
    if k == 13
        iv[1] = 64
        @goto l400
    end
    k == 14 && @goto l350
    v[RADIUS] = v[RADFAC] * v[DSTNRM]
    @goto l170
    @label l310
    if iv[IRC] == 3
        temp1 = lstgst
        k = x01
        for i in 1:n
            v[k] = d[i] * v[step1]
            k = k + 1
            step1 = step1 + 1
        end
        ds7lvm(n, _at(v, temp1), h, _at(v, x01))
        for i in 1:n
            v[temp1] = d[i] * v[temp1] + g[i]
            temp1 = temp1 + 1
        end
    end
    @label l340
    iv[NGCALL] = iv[NGCALL] + 1
    iv[TOOBIG_] = 0
    iv[1] = 2
    return
    @label l350
    iv[1] = 2
    iv[IRC] != 3 && @goto l110
    temp1 = iv[STLSTG]
    step1 = iv[STEP]
    k = temp1
    for i in 1:n
        v[k] = (v[k] - g[i]) / d[i]
        k = k + 1
    end
    if dv2nrm(n, _at(v, temp1)) <= v[DGNORM] * v[TUNER4] || !(dd7tpr(n, g, _at(v, step1)) >= v[GTSTEP] * v[TUNER5])
        v[RADFAC] = v[INCFAC]
    end
    @goto l110
    @label l390
    iv[1] = iv[CNVCOD]
    iv[CNVCOD] = 0
    @label l400
    ditsum(d, g, iv, liv, lv, n, v, x)
    return
end

function drmnhb(b, d, fx::Float64, g, h, iv, liv, lv, n, v, x)
    lh = n * (n + 1) ÷ 2
    CNVCOD = 55; DG = 37; DTOL = 59; DTYPE_ = 16; IRC = 29; IVNEED_ = 3; KAGQT = 33; LMAT_ = 42
    MODE = 35; MODEL = 5; MXFCAL_ = 17; MXITER_ = 18; N0 = 41; NC = 48; NEXTIV = 46; NEXTV_ = 47
    NFCALL_ = 6; NFGCAL_ = 7; NGCALL = 30; NITER_ = 31; PERM_ = 58; RADINC = 8; RESTOR = 9
    STEP = 40; STGLIM = 11; TOOBIG_ = 2; VNEED_ = 4; W = 34; XIRC = 13; X0 = 43
    DGNORM = 1; DINIT = 38; DSTNRM = 2; DTINIT = 39; D0INIT = 40; F_ = 10; F0_ = 13; FDIF_ = 11
    GTSTEP = 4; INCFAC = 23; LMAX0 = 35; LMAXS = 36; PHMXFC = 21; PREDUC = 7; RADFAC = 16
    RADIUS = 8; RAD0 = 9; RELDX = 17; STPPAR = 5; TUNER4 = 29; TUNER5 = 30
    rstrst = 0; k = 0; x01 = 0; step1 = 0; lstgst = 0; temp1 = 0; ipi = 0
    i = iv[1]
    i == 1 && @goto l50
    i == 2 && @goto l60
    iv[1] == 0 && divset(2, iv, liv, lv, v)
    if 12 <= iv[1] <= 13
        iv[VNEED_] = iv[VNEED_] + n * (n + 27) ÷ 2 + 7
        iv[IVNEED_] = iv[IVNEED_] + 3n
    end
    dparck(2, d, iv, liv, lv, n, v)
    i = iv[1] - 2
    i > 12 && return
    nn1o2 = n * (n + 1) ÷ 2
    if lh >= nn1o2
        1 <= i <= 6 && @goto l250
        (i == 7 || i == 9) && @goto l190
        i == 8 && @goto l150
        (i == 10 || i == 11) && @goto l20
        i == 12 && @goto l30
    end
    iv[1] = 81
    @goto l440
    @label l20
    iv[DTOL] = iv[LMAT_] + nn1o2
    iv[X0] = iv[DTOL] + 2n
    iv[STEP] = iv[X0] + 2n
    iv[DG] = iv[STEP] + 3n
    iv[W] = iv[DG] + 2n
    iv[NEXTV_] = iv[W] + 4n + 7
    iv[NEXTIV] = iv[PERM_] + 3n
    if iv[1] == 13
        iv[1] = 14
        return
    end
    @label l30
    iv[NITER_] = 0
    iv[NFCALL_] = 1
    iv[NGCALL] = 1
    iv[NFGCAL_] = 1
    iv[MODE] = -1
    iv[MODEL] = 1
    iv[STGLIM] = 1
    iv[TOOBIG_] = 0
    iv[CNVCOD] = 0
    iv[RADINC] = 0
    iv[NC] = n
    v[RAD0] = ZERO
    v[STPPAR] = ZERO
    v[DINIT] >= ZERO && dv7scp(n, d, v[DINIT])
    k = iv[DTOL]
    v[DTINIT] > ZERO && dv7scp(n, _at(v, k), v[DTINIT])
    k = k + n
    v[D0INIT] > ZERO && dv7scp(n, _at(v, k), v[D0INIT])
    ipi = iv[PERM_]
    for i in 1:n
        iv[ipi] = i
        ipi = ipi + 1
        b[2i-1] > b[2i] && @goto l420
    end
    iv[1] = 1
    @goto l450
    @label l50
    v[F_] = fx
    iv[MODE] >= 0 && @goto l250
    v[F0_] = fx
    iv[1] = 2
    iv[TOOBIG_] == 0 && return
    iv[1] = 63
    @goto l440
    @label l60
    if iv[TOOBIG_] != 0
        iv[1] = 65
        @goto l440
    end
    dg1 = iv[DG]
    if iv[DTYPE_] > 0
        k = dg1
        j = 0
        for i in 1:n
            j = j + i
            v[k] = h[j]
            k = k + 1
        end
        dd7dup(d, _at(v, dg1), iv, liv, lv, n, v)
    end
    dg1 = iv[DG]
    dv7vmp(n, _at(v, dg1), g, d, -1)
    k = 1
    for i in 1:n
        t = ONE / d[i]
        for j in 1:i
            h[k] = t * h[k] / d[j]
            k = k + 1
        end
    end
    ipi = iv[PERM_]
    ipn = ipi + n
    ipiv2 = ipn - 1
    i7pnvr(n, _at(iv, ipn), _at(iv, ipi))
    k = iv[NC]
    for i in 1:n
        if !(b[2i-1] >= b[2i])
            xi = x[i]
            gi = g[i]
            if !((xi <= b[2i-1] && gi > ZERO) || (xi >= b[2i] && gi < ZERO))
                iv[ipi] = i
                ipi = ipi + 1
                j = ipiv2 + i
                iv[j] > k && (iv[CNVCOD] = 0)
                continue
            end
        end
        ipn = ipn - 1
        iv[ipn] = i
    end
    iv[NC] = ipn - iv[PERM_]
    ipi = iv[PERM_]
    ds7ipr(n, _at(iv, ipi), h)
    dv7ipr(n, _at(iv, ipi), _at(v, dg1))
    v[DGNORM] = ZERO
    iv[NC] > 0 && (v[DGNORM] = dv2nrm(iv[NC], _at(v, dg1)))
    iv[CNVCOD] != 0 && @goto l430
    iv[MODE] == 0 && @goto l380
    v[RADIUS] = v[LMAX0] / (ONE + v[PHMXFC])
    iv[MODE] = 0
    @label l140
    ditsum(d, g, iv, liv, lv, n, v, x)
    @label l150
    k = iv[NITER_]
    if !(k < iv[MXITER_])
        iv[1] = 10
        @goto l440
    end
    @label l160
    iv[NITER_] = k + 1
    x01 = iv[X0]
    v[F0_] = v[F_]
    iv[IRC] = 4
    iv[KAGQT] = -1
    dv7cpy(n, _at(v, x01), x)
    if k != 0
        step1 = iv[STEP]
        k = step1
        for i in 1:n
            v[k] = d[i] * v[k]
            k = k + 1
        end
        t = v[RADFAC] * dv2nrm(n, _at(v, step1))
        (v[RADFAC] < ONE || t > v[RADIUS]) && (v[RADIUS] = t)
    end
    # 180: STOPX() ist in R immer .FALSE.
    @goto l200
    @label l190
    if !(v[F_] >= v[F0_])
        v[RADFAC] = ONE
        k = iv[NITER_]
        @goto l160
    end
    @label l200
    if !(iv[NFCALL_] < iv[MXFCAL_])
        iv[1] = 9
        v[F_] >= v[F0_] && @goto l440
        iv[CNVCOD] = iv[1]
        @goto l370
    end
    @label l220
    step1 = iv[STEP]
    l = iv[LMAT_]
    w1 = iv[W]
    ipi = iv[PERM_]
    ipn = ipi + n
    ipiv2 = ipn + n
    tg1 = iv[DG]
    td1 = tg1 + n
    x01 = iv[X0]
    x11 = x01 + n
    ka, p0 = dg7qsb(b, d, h, g, _at(iv, ipi), _at(iv, ipn), _at(iv, ipiv2), iv[KAGQT], _at(v, l), lv, n,
                    iv[N0], iv[NC], _at(v, step1), _at(v, td1), _at(v, tg1), v, _at(v, w1), _at(v, x11),
                    _at(v, x01))
    iv[KAGQT] = ka
    iv[N0] = p0
    if iv[IRC] == 6
        iv[RESTOR] != 2 && @goto l250
        rstrst = 2
        @goto l260
    end
    iv[TOOBIG_] = 0
    v[DSTNRM] <= ZERO && @goto l250
    if iv[IRC] == 5 && !(v[RADFAC] <= ONE) && !(v[PREDUC] > ONEP2 * v[FDIF_])
        iv[RESTOR] != 2 && @goto l250
        rstrst = 0
        @goto l260
    end
    dv2axy(n, x, ONE, _at(v, step1), _at(v, x01))
    iv[NFCALL_] = iv[NFCALL_] + 1
    iv[1] = 1
    @goto l450
    @label l250
    rstrst = 3
    @label l260
    x01 = iv[X0]
    v[RELDX] = drldst(n, d, x, _at(v, x01))
    da7sst(iv, liv, lv, v)
    step1 = iv[STEP]
    lstgst = step1 + 2n
    i = iv[RESTOR] + 1
    if i == 2
        dv7cpy(n, x, _at(v, x01))
    elseif i == 3
        dv7cpy(n, _at(v, lstgst), x)
    elseif i == 4
        dv7cpy(n, x, _at(v, lstgst))
        dv2axy(n, _at(v, step1), NEGONE, _at(v, x01), x)
        v[RELDX] = drldst(n, d, x, _at(v, x01))
        iv[RESTOR] = rstrst
    end
    k = iv[IRC]
    (k == 2 || k == 3 || k == 4) && @goto l340
    if k == 6
        v[RADIUS] = v[LMAXS]
        @goto l220
    end
    if 7 <= k <= 12
        iv[CNVCOD] = k - 4
        v[F_] >= v[F0_] && @goto l430
        iv[XIRC] == 14 && @goto l430
        iv[XIRC] = 14
        @goto l340
    end
    if k == 13
        iv[1] = 64
        @goto l440
    end
    k == 14 && @goto l380
    v[RADIUS] = v[RADFAC] * v[DSTNRM]
    @goto l200
    @label l340
    if iv[IRC] == 3
        temp1 = lstgst
        k = temp1
        step0 = step1 - 1
        ipi = iv[PERM_]
        for i in 1:n
            j = iv[ipi]
            ipi = ipi + 1
            step1 = step0 + j
            v[k] = d[j] * v[step1]
            k = k + 1
        end
        ds7lvm(n, _at(v, x01), h, _at(v, temp1))
        temp0 = temp1 - 1
        ipi = iv[PERM_]
        for i in 1:n
            j = iv[ipi]
            ipi = ipi + 1
            temp1 = temp0 + j
            v[temp1] = d[j] * v[x01] + g[j]
            x01 = x01 + 1
        end
    end
    @label l370
    iv[NGCALL] = iv[NGCALL] + 1
    iv[TOOBIG_] = 0
    iv[1] = 2
    @goto l450
    @label l380
    iv[1] = 2
    iv[IRC] != 3 && @goto l140
    step1 = iv[STEP]
    temp1 = step1 + 2n
    k = temp1
    for i in 1:n
        v[k] = (v[k] - g[i]) / d[i]
        k = k + 1
    end
    if dv2nrm(n, _at(v, temp1)) <= v[DGNORM] * v[TUNER4] || !(dd7tpr(n, g, _at(v, step1)) >= v[GTSTEP] * v[TUNER5])
        v[RADFAC] = v[INCFAC]
    end
    @goto l140
    @label l420
    iv[1] = 82
    @goto l440
    @label l430
    iv[1] = iv[CNVCOD]
    iv[CNVCOD] = 0
    @label l440
    ditsum(d, g, iv, liv, lv, n, v, x)
    return
    @label l450
    for i in 1:n
        x[i] < b[2i-1] && (x[i] = b[2i-1])
        x[i] > b[2i] && (x[i] = b[2i])
    end
    return
end

# ── port.c: Treiber ──────────────────────────────────────────────────────

function nlminb_iterate(b, d, fx::Float64, g, h, iv, liv, lv, n, v, x)
    if b !== nothing
        if g !== nothing
            if h !== nothing
                drmnhb(b, d, fx, g, h, iv, liv, lv, n, v, x)
            else
                drmngb(b, d, fx, g, iv, liv, lv, n, v, x)
            end
        else
            drmnfb(b, d, fx, iv, liv, lv, n, v, x)
        end
    else
        if g !== nothing
            if h !== nothing
                drmnh(d, fx, g, h, iv, liv, lv, n, v, x)
            else
                drmng(d, fx, g, iv, liv, lv, n, v, x)
            end
        else
            drmnf(d, fx, iv, liv, lv, n, v, x)
        end
    end
    return
end

"asReal einer R-Rückgabe (erstes Element; leer/NULL -> NA)."
function _as_real(val)
    val === nothing && return SimLev.NA
    val === missing && return SimLev.NA
    val isa Bool && return val ? 1.0 : 0.0
    val isa Real && return Float64(val)
    if val isa SimLev.RVector
        return isempty(val.values) ? SimLev.NA : _as_real(val.values[1])
    end
    if val isa AbstractArray
        return isempty(val) ? SimLev.NA : _as_real(first(val))
    end
    if val isa AbstractString
        r = tryparse(Float64, strip(val))
        if r === nothing
            @warn "NAs introduced by coercion"
            return SimLev.NA
        end
        return r
    end
    return Float64(val)
end

function _num_vec(val)
    val isa SimLev.RVector && return Float64[Float64(v) for v in val.values]
    val isa SimLev.NamedMat && return Float64[Float64(v) for v in vec(val.data)]
    val isa AbstractArray && return Float64[Float64(v) for v in vec(val)]
    return Float64[Float64(val)]
end

function _check_gv(gr, hs, xw, n, g, h)
    gv = _num_vec(gr(xw()))
    length(gv) != n && error("gradient function must return a numeric vector of length $n")
    for i in 1:n
        g[i] = gv[i]
    end
    for i in 1:n
        isnan(g[i]) && error("NA/NaN gradient evaluation")
    end
    if h !== nothing
        hv = hs(xw())
        M = hv isa SimLev.NamedMat ? hv.data : hv
        # port.c ruft REAL() vor der Prüfung auf: integer/logical -> R-Fehler
        T = M isa AbstractArray ? eltype(M) : typeof(M)
        kind = T <: Bool ? "logical" : T <: Integer ? "integer" : T <: AbstractString ? "character" : ""
        isempty(kind) || error("REAL() can only be applied to a 'numeric', not a '$kind'")
        ok = M isa AbstractMatrix && size(M) == (n, n) && eltype(M) <: AbstractFloat
        ok || error("Hessian function must return a square numeric matrix of order $n")
        pos = 1
        for i in 1:n, j in 1:i
            h[pos] = Float64(M[i, j])
            isnan(h[pos]) && error("NA/NaN Hessian evaluation")
            pos += 1
        end
    end
    return
end

"""
    port_nlminb(fn, gr, hs, low, upp, d, iv, v, x0, names)

`port_nlminb` aus port.c; `iv`/`v` werden verändert. `fn`, `gr`, `hs` sind
Funktionen eines Parametervektors; `low`/`upp` `nothing` oder Länge n.
Liefert den End-`par` (Vector{Float64}).
"""
function port_nlminb(fn, gr, hs, low, upp, d::Vector{Float64}, iv::Vector{Int}, v::Vector{Float64},
                     x0::Vector{Float64}, names)
    n = length(d)
    n < 1 && error("'d' must be a nonempty numeric vector")
    liv = length(iv)
    lv = length(v)
    x = copy(x0)
    dd = copy(d)
    b = nothing
    if low !== nothing && upp !== nothing && length(low) == n && length(upp) == n
        b = zeros(2n)
        for i in 1:n
            b[2i-1] = low[i]
            b[2i] = upp[i]
        end
    end
    g = gr === nothing ? nothing : zeros(n)
    h = (gr === nothing || hs === nothing) ? nothing : zeros(n * (n + 1) ÷ 2)
    xw() = names === nothing ? (n == 1 ? x[1] : copy(x)) : SimLev.RVector(copy(x); names = names)
    fx = Inf
    while true
        nlminb_iterate(b, dd, fx, g, h, iv, liv, lv, n, v, x)
        if iv[1] == 2 && g !== nothing
            _check_gv(gr, hs, xw, n, g, h)
        else
            fx = _as_real(fn(xw()))
            if isnan(fx)
                @warn "NA/NaN function evaluation"
                fx = Inf
            end
        end
        iv[1] < 3 || break
    end
    return x
end

end # module
