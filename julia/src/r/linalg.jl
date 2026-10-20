# ─────────────────────────────────────────────────────────────────────────────
# RLinalg – Lineare Algebra wie R 4.3.3 (Referenz-BLAS/LAPACK 3.12), bitgleich
#
#   R                    Julia
#   ───────────────────  ─────────────────────────────────────────────────────
#   x %*% y              matprod (R_Matprod "default": bei NaN/Inf simple_matprod,
#                        sonst dgemm/dgemv)
#   crossprod            crossprod (dsyrk + Spiegeln bzw. dgemm/dgemv)
#   tcrossprod           tcrossprod
#   outer                outer
#   solve                solve (dgesv + dgecon), solve_qr
#   chol                 chol (dpotrf, pivot = FALSE)
#   chol2inv             chol2inv (dpotri)
#   backsolve            backsolve, forwardsolve (dtrsm)
#   determinant, det     determinant (dgetrf), det
#   eigen                eigen (symmetrisch, La_rs → dsyevr; Vektoren über die
#                        System-Referenz-LAPACK)
#   qr                   qr (LINPACK dqrdc2), qr_coef, qr_qty, qr_qy, qr_resid,
#                        qr_fitted, qr_solve, qr_R, qr_Q
#   diag, isSymmetric    diag, is_symmetric
#
# Eingaben: Matrix, NamedMat, RFrame (Matrix), Vektoren, RVector (benannt),
# Skalare. Matrizen kommen als Matrix{Float64} zurück, mit dimnames als
# NamedMat; benannte Vektoren als RVector; Länge 1 als Skalar.
# Vorlage: python/simlev/_r/linalg.py.
# ─────────────────────────────────────────────────────────────────────────────
module RLinalg

import ..SimLev
import ..SimLev: RList, RVector, NamedMat, RFrame, NA, isna_strict
using Dates

export matprod, crossprod, tcrossprod, outer, solve, solve_qr, chol, chol2inv, backsolve,
       forwardsolve, determinant, det, eigen, qr, qr_coef, qr_qty, qr_qy, qr_resid, qr_fitted,
       qr_solve, qr_R, qr_Q, diag, is_symmetric, all_equal_numeric

include("_blas.jl")
include("_lapack.jl")
include("_linpack.jl")

const _DBL_EPS = 2.220446049250313e-16

# ── Ein-/Ausgabe ──────────────────────────────────────────────────────────

"R-Objekt: Werte (spaltenweise), dim (oder nothing), dimnames, names."
struct _M
    v::Vector{Float64}
    dim::Union{Nothing,Tuple{Int,Int}}
    rn::Union{Nothing,Vector{String}}
    cn::Union{Nothing,Vector{String}}
    names::Union{Nothing,Vector{String}}
    is_int::Bool
end
_M(v, dim; rn = nothing, cn = nothing, names = nothing, is_int = false) = _M(v, dim, rn, cn, names, is_int)

_f64(v) = v === missing || v === nothing ? NA : Float64(v)
_isint_t(T) = (S = Base.nonmissingtype(T); S <: Integer)

ismat(m::_M) = m.dim !== nothing
len(m::_M) = length(m.v)

"Als n×p-Matrix (Kopie); Vektoren als Spalte."
mat(m::_M) = m.dim === nothing ? reshape(copy(m.v), :, 1) : reshape(copy(m.v), m.dim)

_as_r(x::_M) = x
_as_r(x::NamedMat) = _M(Float64[_f64(v) for v in vec(x.data)], size(x.data); rn = x.rownames, cn = x.colnames,
                        is_int = _isint_t(eltype(x.data)))
function _as_r(x::RFrame)
    cols = x.cols
    nr = SimLev.nrow(x)
    v = Float64[]
    for c in cols
        append!(v, (_f64(t) for t in c))
    end
    _M(v, (nr, length(cols)); rn = x.rownames, cn = names(x))
end
_as_r(x::RVector) = _M(Float64[_f64(v) for v in x.values], nothing; names = x.names, is_int = _isint_t(eltype(x.values)))
_as_r(x::AbstractMatrix) = _M(Float64[_f64(v) for v in vec(x)], size(x); is_int = _isint_t(eltype(x)))
_as_r(x::AbstractVector) = _M(Float64[_f64(v) for v in x], nothing; is_int = _isint_t(eltype(x)))
_as_r(x::Tuple) = _as_r(collect(x))
_as_r(x::Union{Number,Missing}) = _M([_f64(x)], nothing; is_int = x isa Integer)
_as_r(x::AbstractArray) = error("arrays with more than 2 dimensions are not supported")

"as.matrix: Vektoren werden zu n×1 (names → rownames)."
function _as_matrix(x)
    m = _as_r(x)
    m.dim === nothing && return _M(m.v, (len(m), 1), m.names, nothing, nothing, m.is_int)
    m
end

_out(Z, rn = nothing, cn = nothing) = (rn === nothing && cn === nothing) ? Z : NamedMat(Z; rownames = rn, colnames = cn)

function _vec_out(v::AbstractVector, names = nothing)
    names !== nothing && return RVector(collect(v); names = names)
    length(v) == 1 && return v[1]
    return collect(v)
end

_rerr(msg) = error(msg)

# ── Matrixprodukte ────────────────────────────────────────────────────────

"mayHaveNaNOrInf aus array.c (ungenau: Summe benachbarter Paare)."
function _may_have_nan_or_inf(v::AbstractVector{Float64})
    n = length(v)
    n == 0 && return false
    (isodd(n) && !isfinite(v[1])) && return true
    @inbounds for i in (isodd(n) ? 2 : 1):2:n
        isfinite(v[i] + v[i+1]) || return true
    end
    return false
end

function _matprod_core(X::Matrix{Float64}, Y::Matrix{Float64})
    nrx, ncx = size(X)
    nry, ncy = size(Y)
    (nrx == 0 || ncx == 0 || nry == 0 || ncy == 0) && return zeros(nrx, ncy)
    (_may_have_nan_or_inf(vec(X)) || _may_have_nan_or_inf(vec(Y))) && return _simple_matprod(X, Y)
    Z = zeros(nrx, ncy)
    if ncy == 1
        dgemv('N', 1.0, X, view(Y, :, 1), 0.0, view(Z, :, 1))
    elseif nrx == 1
        dgemv('T', 1.0, Y, view(X, 1, :), 0.0, view(Z, 1, :))
    else
        dgemm('N', 'N', 1.0, X, Y, 0.0, Z)
    end
    Z
end

"`x %*% y` wie R 4.3 (matprod, Voreinstellung \"default\")."
function matprod(x, y)
    mx = _as_r(x); my = _as_r(y)
    if !ismat(mx) && !ismat(my)
        nry = len(my); ncy = 1; nrx = 1; ncx = len(mx)
        if ncx == 1
            ncy = nry; nry = 1
        end
    elseif !ismat(mx)
        nry, ncy = my.dim
        nrx = ncx = 0
        if len(mx) == nry
            nrx, ncx = 1, nry
        elseif nry == 1
            nrx, ncx = len(mx), 1
        end
    elseif !ismat(my)
        nrx, ncx = mx.dim
        nry = ncy = 0
        if len(my) == ncx
            nry, ncy = ncx, 1
        elseif ncx == 1
            nry, ncy = 1, len(my)
        end
    else
        nrx, ncx = mx.dim
        nry, ncy = my.dim
    end
    ncx != nry && _rerr("non-conformable arguments")
    X = reshape(copy(mx.v), nrx, ncx)
    Y = reshape(copy(my.v), nry, ncy)
    Z = _matprod_core(X, Y)
    _out(Z, ismat(mx) ? mx.rn : nothing, ismat(my) ? my.cn : nothing)
end

"`crossprod(x, y)` = `t(x) %*% y` wie R (dsyrk bei y = nothing)."
function crossprod(x, y = nothing)
    mx = _as_r(x)
    sym = y === nothing
    my = sym ? mx : _as_r(y)
    if !ismat(mx) && !ismat(my)
        if len(mx) == 1
            nrx = ncx = nry = 1
            ncy = len(my)
        else
            nry, ncy = len(my), 1
            nrx, ncx = len(mx), 1
        end
    elseif !ismat(mx)
        nry, ncy = my.dim
        nrx = ncx = 0
        len(mx) == nry && ((nrx, ncx) = (nry, 1))
    elseif !ismat(my)
        nrx, ncx = mx.dim
        nry = ncy = 0
        if len(my) == nrx
            nry, ncy = nrx, 1
        elseif nrx == 1
            nry, ncy = 1, len(my)
        end
    else
        nrx, ncx = mx.dim
        nry, ncy = my.dim
    end
    nrx != nry && _rerr("non-conformable arguments")
    X = reshape(copy(mx.v), nrx, ncx)
    Z = sym ? _symcrossprod(X) : _crossprod_core(X, reshape(copy(my.v), nry, ncy))
    _out(Z, ismat(mx) ? mx.cn : nothing, ismat(my) ? my.cn : nothing)
end

function _symcrossprod(X::Matrix{Float64})
    nr, nc = size(X)
    (nr == 0 || nc == 0) && return zeros(nc, nc)
    _may_have_nan_or_inf(vec(X)) && return _simple_crossprod(X, X)
    Z = zeros(nc, nc)
    dsyrk('U', 'T', 1.0, X, 0.0, Z)
    for j in 1:nc, i in j+1:nc
        Z[i, j] = Z[j, i]
    end
    Z
end

function _crossprod_core(X::Matrix{Float64}, Y::Matrix{Float64})
    nrx, ncx = size(X)
    nry, ncy = size(Y)
    (nrx == 0 || ncx == 0 || nry == 0 || ncy == 0) && return zeros(ncx, ncy)
    (_may_have_nan_or_inf(vec(X)) || _may_have_nan_or_inf(vec(Y))) && return _simple_crossprod(X, Y)
    Z = zeros(ncx, ncy)
    if ncy == 1
        dgemv('T', 1.0, X, view(Y, :, 1), 0.0, view(Z, :, 1))
    elseif ncx == 1
        dgemv('T', 1.0, Y, view(X, :, 1), 0.0, view(Z, 1, :))
    else
        dgemm('T', 'N', 1.0, X, Y, 0.0, Z)
    end
    Z
end

"`tcrossprod(x, y)` = `x %*% t(y)` wie R (dsyrk bei y = nothing)."
function tcrossprod(x, y = nothing)
    mx = _as_r(x)
    sym = y === nothing
    my = sym ? mx : _as_r(y)
    if !ismat(mx) && !ismat(my)
        nry, ncy = len(my), 1
        nrx, ncx = len(mx), 1
    elseif !ismat(mx)
        nry, ncy = my.dim
        nrx = ncx = 0
        if len(mx) == ncy
            nrx, ncx = 1, ncy
        elseif ncy == 1
            nrx, ncx = len(mx), 1
        end
    elseif !ismat(my)
        nrx, ncx = mx.dim
        if nrx == 1
            nry, ncy = 1, len(my)
        else
            nry, ncy = len(my), 1
        end
    else
        nrx, ncx = mx.dim
        nry, ncy = my.dim
    end
    ncx != ncy && _rerr("non-conformable arguments")
    X = reshape(copy(mx.v), nrx, ncx)
    Z = sym ? _symtcrossprod(X) : _tcrossprod_core(X, reshape(copy(my.v), nry, ncy))
    _out(Z, ismat(mx) ? mx.rn : nothing, ismat(my) ? my.rn : nothing)
end

function _symtcrossprod(X::Matrix{Float64})
    nr, nc = size(X)
    (nr == 0 || nc == 0) && return zeros(nr, nr)
    _may_have_nan_or_inf(vec(X)) && return _simple_tcrossprod(X, X)
    Z = zeros(nr, nr)
    dsyrk('U', 'N', 1.0, X, 0.0, Z)
    for j in 1:nr, i in j+1:nr
        Z[i, j] = Z[j, i]
    end
    Z
end

function _tcrossprod_core(X::Matrix{Float64}, Y::Matrix{Float64})
    nrx, ncx = size(X)
    nry, ncy = size(Y)
    (nrx == 0 || ncx == 0 || nry == 0 || ncy == 0) && return zeros(nrx, nry)
    (_may_have_nan_or_inf(vec(X)) || _may_have_nan_or_inf(vec(Y))) && return _simple_tcrossprod(X, Y)
    Z = zeros(nrx, nry)
    if nry == 1
        dgemv('N', 1.0, X, view(Y, 1, :), 0.0, view(Z, :, 1))
    elseif nrx == 1
        dgemv('N', 1.0, Y, view(X, 1, :), 0.0, view(Z, 1, :))
    else
        dgemm('N', 'T', 1.0, X, Y, 0.0, Z)
    end
    Z
end

"""
    outer(X, Y, FUN = "*")

`outer(X, Y, FUN)`; FUN "*" (über tcrossprod wie R), "+", "-", "/", "^" oder
eine vektorisierte Funktion `(xx, yy) -> Vektor`.
"""
function outer(X, Y, FUN = "*")
    mx = _as_r(X); my = _as_r(Y)
    dX = ismat(mx) ? [mx.dim...] : [len(mx)]
    dY = ismat(my) ? [my.dim...] : [len(my)]
    if FUN isa AbstractString && FUN == "*"
        Z = tcrossprod(mx.v, my.v)
        flat = vec(Z isa NamedMat ? Z.data : (Z isa AbstractMatrix ? Z : fill(Float64(Z), 1, 1)))
    else
        nx = len(mx); ny = len(my)
        xx = Float64[mx.v[(k - 1) % max(nx, 1) + 1] for k in 1:nx*ny]
        yy = Float64[my.v[(k - 1) ÷ max(nx, 1) + 1] for k in 1:nx*ny]
        if FUN == "+"
            flat = xx .+ yy
        elseif FUN == "-"
            flat = xx .- yy
        elseif FUN == "/"
            flat = xx ./ yy
        elseif FUN == "^"
            flat = Float64[SimLev.r_pow(a, b) for (a, b) in zip(xx, yy)]
        elseif FUN isa Function
            flat = Float64.(collect(FUN(xx, yy)))
        else
            _rerr("unsupported FUN")
        end
    end
    dims = vcat(dX, dY)
    if length(dims) == 2
        Z = reshape(collect(flat), dims[1], dims[2])
        (ismat(mx) || ismat(my)) && return Z
        return _out(Z, mx.names, my.names)
    end
    return reshape(collect(flat), dims...)
end

# ── solve ─────────────────────────────────────────────────────────────────

_is_qr(x) = x isa RList && "qr" in SimLev.r_class(x)

"`solve.default(a, b, tol)` (La_solve: dgesv + dgecon)."
function solve(a, b = nothing; tol::Real = _DBL_EPS)
    if _is_qr(a)
        @warn "solve.default called with a \"qr\" object: use 'qr.solve'"
        return solve_qr(a, b)
    end
    ma = _as_matrix(a)
    n, n2 = ma.dim
    if b === nothing
        Bm = Matrix{Float64}(undef, n, n)
        for j in 1:n, i in 1:n
            Bm[i, j] = i == j ? 1.0 : 0.0
        end
        bnames_c = ma.rn
        b_is_mat = true
        b_rows = n
    else
        mb = _as_r(b)
        b_is_mat = ismat(mb)
        if b_is_mat
            b_rows = mb.dim[1]
            Bm = mat(mb)
            bnames_c = mb.cn
        else
            Bm = reshape(copy(mb.v), :, 1)
            bnames_c = nothing
            b_rows = len(mb)
        end
    end
    n == 0 && _rerr("'a' is 0-diml")
    n2 != n && _rerr("'a' ($n x $n2) must be square")
    p = b_is_mat ? size(Bm, 2) : 1
    b_is_mat && p == 0 && _rerr("no right-hand side in 'b'")
    b_rows != n && _rerr("'b' ($b_rows x $p) must be compatible with 'a' ($n x $n)")
    A = mat(ma)
    avals = copy(A)
    ipiv = zeros(Int, n)
    info = dgesv(avals, Bm, ipiv)
    info > 0 && _rerr("Lapack routine dgesv: system is exactly singular: U[$info,$info] = 0")
    if all(isfinite, avals) && tol > 0
        anorm = dlange('1', ma.is_int ? avals : A)
        rcond = dgecon('1', avals, anorm)
        rcond < tol && _rerr("system is computationally singular: reciprocal condition number = " *
                             SimLev.r_sprintf("%g", rcond))
    end
    if b_is_mat
        return _out(Bm, ma.cn, bnames_c)
    end
    return _vec_out(Bm[:, 1], ma.cn)
end

# ── Cholesky ─────────────────────────────────────────────────────────────

"`chol.default(x)` (La_chol mit dpotrf('U'))."
function chol(x; pivot::Bool = false, tol::Real = -1)
    pivot && error("chol(pivot = TRUE) ist nicht portiert")
    m = _as_matrix(x)
    nr, nc = m.dim
    nr != nc && _rerr("'a' must be a square matrix")
    nr <= 0 && _rerr("'a' must have dims > 0")
    A = mat(m)
    for j in 1:nc, i in j+1:nr
        A[i, j] = 0.0
    end
    info = dpotrf('U', A)
    if info != 0
        info > 0 && _rerr("the leading minor of order $info is not positive")
        _rerr("argument $(-info) of Lapack routine dpotrf had invalid value")
    end
    _out(A, m.rn, m.cn)
end

"`chol2inv(x, size)` (La_chol2inv mit dpotri('U'))."
function chol2inv(x; size = nothing)
    mm = _as_r(x)
    size === nothing && (size = ismat(mm) ? mm.dim[2] : 1)
    sz = Int(size)
    sz < 1 && _rerr("'size' argument must be a positive integer")
    if ismat(mm)
        m, n = mm.dim
        Am = mat(mm)
    elseif sz == 1
        m = n = 1
        Am = reshape(mm.v[1:1], 1, 1)
    else
        _rerr("'a' must be a numeric matrix")
    end
    sz > n && _rerr("'size' cannot exceed ncol(x) = $n")
    sz > m && _rerr("'size' cannot exceed nrow(x) = $m")
    ans = zeros(sz, sz)
    for j in 1:sz, i in 1:j
        ans[i, j] = Am[i, j]
    end
    info = dpotri('U', ans)
    if info != 0
        info > 0 && _rerr("element ($info, $info) is zero, so the inverse cannot be computed")
        _rerr("argument $(-info) of Lapack routine dpotri had invalid value")
    end
    for j in 1:sz, i in j+1:sz
        ans[i, j] = ans[j, i]
    end
    ans
end

# ── backsolve ────────────────────────────────────────────────────────────

function _backsolve(r, x, k, upper::Bool, transpose::Bool)
    mr = _as_matrix(r)
    mx = _as_r(x)
    x_mat = ismat(mx)
    X = mat(mx)
    nrr, ncr = mr.dim
    nrb, ncb = size(X)
    k === nothing && (k = ncr)
    k = Int(k)
    (k <= 0 || k > nrr || k > ncr || k > nrb) && _rerr("invalid 'k' argument")
    R = mat(mr)
    for i in 1:k
        R[i, i] == 0.0 && _rerr("singular matrix in 'backsolve'. First zero in diagonal [$i]")
    end
    ans = X[1:k, :]
    (k > 0 && ncb > 0) && dtrsm('L', upper ? 'U' : 'L', transpose ? 'T' : 'N', 'N', 1.0, view(R, 1:k, 1:k), ans)
    x_mat && return ans
    return size(ans, 2) == 1 ? _vec_out(ans[:, 1]) : ans
end

"`backsolve(r, x, k, upper.tri, transpose)` (dtrsm)."
backsolve(r, x; k = nothing, upper_tri::Bool = true, transpose::Bool = false) = _backsolve(r, x, k, upper_tri, transpose)

"`forwardsolve(l, x, k, upper.tri, transpose)` (dtrsm)."
forwardsolve(l, x; k = nothing, upper_tri::Bool = false, transpose::Bool = false) = _backsolve(l, x, k, upper_tri, transpose)

# ── Determinante ─────────────────────────────────────────────────────────

"`determinant(x, logarithm)`: RList (Klasse \"det\") mit `modulus` und `sign`."
function determinant(x; logarithm::Bool = true)
    m = _as_matrix(x)
    nr, nc = m.dim
    nc != nr && _rerr("'x' must be a square matrix")
    if nc < 1
        return RList("modulus" => (logarithm ? 0.0 : 1.0), "sign" => 1; class = "det")
    end
    A = mat(m)
    n = nr
    ipiv = zeros(Int, n)
    sign = 1
    info = dgetrf(A, ipiv)
    if info > 0
        modulus = logarithm ? -Inf : 0.0
    else
        for i in 1:n
            ipiv[i] != i && (sign = -sign)
        end
        if logarithm
            modulus = 0.0
            for i in 1:n
                dii = A[i, i]
                a = dii < 0 ? -dii : dii
                modulus += a > 0 ? SimLev.RLibm.log(a) : (a == 0 ? -Inf : NaN)
                dii < 0 && (sign = -sign)
            end
        else
            modulus = 1.0
            for i in 1:n
                modulus *= A[i, i]
            end
            if modulus < 0
                modulus = -modulus
                sign = -sign
            end
        end
    end
    RList("modulus" => modulus, "sign" => sign; class = "det")
end

"`det(x)` = `sign * exp(modulus)` aus `determinant(x, TRUE)`."
function det(x)
    z = determinant(x; logarithm = true)
    return z["sign"] * SimLev.RLibm.exp(z["modulus"])
end

# ── Eigenwerte ───────────────────────────────────────────────────────────

"Kern von `all.equal.numeric` (ohne Attribute); `true` oder Text."
function all_equal_numeric(target, current; tolerance::Real = 1.4901161193847656e-08)
    t = _as_r(target).v
    c = _as_r(current).v
    length(t) != length(c) && return "Numeric: lengths ($(length(t)), $(length(c))) differ"
    out = isnan.(t)
    if any(out .!= isnan.(c))
        return "'is.NA' value mismatch: $(count(isnan, c)) in current $(count(out)) in target"
    end
    out = out .| (t .== c)
    all(out) && return true
    keep = .!out
    t = t[keep]; c = c[keep]
    N = length(t)
    scale = SimLev.r_sum(abs.(t) ./ N)
    what = "relative"
    if !(isfinite(scale) && scale > tolerance)
        scale = 1.0
        what = "absolute"
    end
    xy = SimLev.r_sum(abs.(t .- c) ./ (N * scale))
    (isnan(xy) || xy > tolerance) && return "Mean $what difference: " * SimLev.r_sprintf("%.7g", xy)
    return true
end

"`isSymmetric.matrix(x, tol)`."
function is_symmetric(x; tol::Real = 100 * _DBL_EPS, tol1 = nothing)
    tol1 === nothing && (tol1 = 8 * tol)
    m = _as_r(x)
    ismat(m) || return false
    n, nc = m.dim
    n != nc && return false
    A = mat(m)
    (m.rn !== nothing || m.cn !== nothing) && m.rn != m.cn && return false
    if n > 1
        for i in unique([1, 2, n - 1, n])
            (i < 1 || i > n) && continue
            all_equal_numeric(A[i, :], A[:, i]; tolerance = tol1) === true || return false
        end
    end
    return all_equal_numeric(A, permutedims(A); tolerance = tol) === true
end

"""
    eigen(x; symmetric = nothing, only_values = false, backend = "auto")

`eigen(x, symmetric, only.values)` für symmetrische Matrizen: RList (Klasse
\"eigen\") mit `values` (absteigend) und `vectors` (Spalten; `nothing` bei
`only_values`).
"""
function eigen(x; symmetric = nothing, only_values::Bool = false, backend::String = "auto")
    m = _as_matrix(x)
    n, nc = m.dim
    n != nc && _rerr("non-square matrix in 'eigen'")
    n == 0 && _rerr("0 x 0 matrix")
    A = mat(m)
    all(isfinite, A) || _rerr("infinite or missing values in 'x'")
    symmetric === nothing && (symmetric = is_symmetric(A))
    symmetric || error("eigen(): nur symmetrische Matrizen sind portiert (La_rs)")
    w, z, info, used = dsyevr(A; only_values = only_values, backend = backend)
    info != 0 && _rerr("error code $info from Lapack routine 'dsyevr'")
    vals = reverse(collect(Float64, w))
    vecs = only_values ? nothing : Matrix{Float64}(z[:, end:-1:1])
    RList("values" => (length(vals) == 1 ? vals[1] : vals), "vectors" => vecs; class = "eigen")
end

# ── QR (LINPACK) ─────────────────────────────────────────────────────────

"`qr.default(x, tol)` mit LINPACK dqrdc2: RList (Klasse \"qr\") mit qr, rank, qraux, pivot."
function qr(x; tol::Real = 1e-07, LAPACK::Bool = false)
    LAPACK && error("qr(LAPACK = TRUE) ist nicht portiert")
    m = _as_matrix(x)
    X = mat(m)
    k, qraux, jpvt = dqrdc2!(X, Float64(tol))
    cn = m.cn === nothing ? nothing : [m.cn[i] for i in jpvt]
    RList("qr" => _out(X, m.rn, cn), "rank" => k, "qraux" => qraux, "pivot" => jpvt; class = "qr")
end

function _qr_parts(q)
    Q = q["qr"]
    if Q isa NamedMat
        cn = Q.colnames
        X = Matrix{Float64}(Q.data)
    else
        cn = nothing
        X = Q isa AbstractMatrix ? Matrix{Float64}(Q) : reshape(Float64[Q], 1, 1)
    end
    qa = q["qraux"]; pv = q["pivot"]
    return X, cn, Int(q["rank"]), collect(Float64, qa isa Number ? [qa] : qa), collect(Int, pv isa Number ? [pv] : pv)
end

function _check_qr(q, msg = "first argument must be a QR decomposition")
    (q isa AbstractDict && haskey(q, "qr") && haskey(q, "qraux")) || _rerr(msg)
end

"`qr.coef(qr, y)` (LINPACK dqrcf); NA für ausgeschlossene Spalten."
function qr_coef(qr, y)
    _check_qr(qr)
    X, nam, k, qraux, pivot = _qr_parts(qr)
    n, p = size(X)
    my = _as_r(y)
    im = ismat(my)
    Y = mat(my)
    ny = size(Y, 2)
    size(Y, 1) != n && _rerr("'qr' and 'y' must have the same number of rows")
    coef = fill(NA, p, ny)
    pivotted = nothing
    if p == 0
        pivotted = false
    elseif k > 0
        b, info = dqrcf(X, k, qraux, Y)
        info != 0 && _rerr("exact singularity in 'qr.coef'")
        pivotted = k < p
        if pivotted
            for i in 1:k, c in 1:ny
                coef[pivot[i], c] = b[i, c]
            end
        else
            coef = b
        end
    end
    rn = nothing
    if nam !== nothing
        pivotted === nothing && (pivotted = any(i -> pivot[i+1] < pivot[i], 1:length(pivot)-1))
        if pivotted
            rn = fill("", p)
            for (i, pv) in enumerate(pivot)
                rn[pv] = nam[i]
            end
        else
            rn = collect(String, nam)
        end
    end
    im && return _out(coef, rn, my.cn)
    ny == 1 && return _vec_out(coef[:, 1], rn)
    return _out(coef, rn, nothing)
end

function _qr_apply(qr, y, fn)
    X, nam, k, qraux, pivot = _qr_parts(qr)
    n = size(X, 1)
    my = _as_r(y)
    Y = mat(my)
    size(Y, 1) != n && _rerr("'qr' and 'y' must have the same number of rows")
    Z = fn(X, k, qraux, Y)
    ismat(my) && return _out(Z, my.rn, my.cn)
    return _vec_out(Z[:, 1], my.names)
end

"`qr.qty(qr, y)` = Q'y."
qr_qty(qr, y) = (_check_qr(qr, "argument is not a QR decomposition"); _qr_apply(qr, y, dqrqty))
"`qr.qy(qr, y)` = Qy."
qr_qy(qr, y) = (_check_qr(qr, "argument is not a QR decomposition"); _qr_apply(qr, y, dqrqy))

"`qr.resid(qr, y)`."
function qr_resid(qr, y)
    _check_qr(qr, "argument is not a QR decomposition")
    Int(qr["rank"]) == 0 && return y
    _qr_apply(qr, y, dqrrsd)
end

"`qr.fitted(qr, y, k = qr\$rank)`."
function qr_fitted(qr, y; k = nothing)
    _check_qr(qr, "argument is not a QR decomposition")
    kk = k === nothing ? Int(qr["rank"]) : Int(k)
    kk > Int(qr["rank"]) && _rerr("'k' is too large")
    _qr_apply(qr, y, (X, _k, qa, Y) -> dqrxb(X, kk, qa, Y))
end

_eye(n) = (E = zeros(n, n); for i in 1:n; E[i, i] = 1.0; end; E)

function _na0(res)
    f(v) = isnan(v) ? 0.0 : v
    res isa NamedMat && return NamedMat(map(f, res.data); rownames = res.rownames, colnames = res.colnames)
    res isa RVector && return RVector(map(f, res.values); names = res.names)
    res isa AbstractArray && return map(f, res)
    return f(res)
end

"`qr.solve(a, b, tol)`."
function qr_solve(a, b = nothing; tol::Real = 1e-7)
    q = _is_qr(a) ? a : qr(a; tol = tol)
    X, _, k, _, _ = _qr_parts(q)
    nr, nc = size(X)
    k != min(nc, nr) && _rerr("singular matrix 'a' in solve")
    if b === nothing
        nc != nr && _rerr("only square matrices can be inverted")
        b = _eye(nc)
    end
    return _na0(qr_coef(q, b))
end

"`solve.qr(a, b)`."
function solve_qr(a, b = nothing)
    _is_qr(a) || _rerr("this is the \"qr\" method for the generic function solve()")
    X, _, k, _, _ = _qr_parts(a)
    nr, nc = size(X)
    k != min(nc, nr) && _rerr("singular matrix 'a' in 'solve'")
    if b === nothing
        nc != nr && _rerr("only square matrices can be inverted")
        b = _eye(nc)
    end
    return _na0(qr_coef(a, b))
end

"`qr.R(qr, complete)`."
function qr_R(qr; complete::Bool = false)
    X, cn, _, _, _ = _qr_parts(qr)
    R = complete ? copy(X) : X[1:min(size(X)...), :]
    for j in 1:size(R, 2), i in j+1:size(R, 1)
        R[i, j] = 0.0
    end
    _out(R, nothing, cn)
end

"`qr.Q(qr, complete)`."
function qr_Q(qr; complete::Bool = false)
    X, _, _, _, _ = _qr_parts(qr)
    n = size(X, 1)
    if complete
        D = _eye(n)
    else
        nc = min(size(X)...)
        D = zeros(n, nc)
        for i in 1:nc
            D[i, i] = 1.0
        end
    end
    qr_qy(qr, D)
end

"`diag(x, nrow, ncol)` wie R."
function diag(x = 1; nrow = nothing, ncol = nothing, names::Bool = true)
    if x isa AbstractMatrix || x isa RFrame
        (nrow !== nothing || ncol !== nothing) && _rerr("'nrow' or 'ncol' cannot be specified when 'x' is a matrix")
        m = _as_r(x)
        A = mat(m)
        mm = min(size(A)...)
        mm == 0 && return Float64[]
        y = Float64[A[i, i] for i in 1:mm]
        if names && m.rn !== nothing && m.cn !== nothing && m.rn[1:mm] == m.cn[1:mm]
            return RVector(y; names = m.rn[1:mm])
        end
        return length(y) == 1 ? y[1] : y
    end
    if x isa Number && nrow === nothing && ncol === nothing
        n = trunc(Int, x)
        v = [1.0]
    else
        v = _as_r(x).v
        n = length(v)
    end
    nrow !== nothing && (n = trunc(Int, nrow))
    nc = ncol === nothing ? n : trunc(Int, ncol)
    isempty(v) && _rerr("'x' must have positive length")
    out = zeros(n, nc)
    for i in 1:min(n, nc)
        out[i, i] = v[(i - 1) % length(v) + 1]
    end
    out
end

end # module
