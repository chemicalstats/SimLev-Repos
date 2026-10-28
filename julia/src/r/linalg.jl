# ─────────────────────────────────────────────────────────────────────────────
# RLinalg – lineare Hilfen wie R 4.3.3, die nach Etappe 9.6c bleiben
#
#   R                    Julia
#   ───────────────────  ─────────────────────────────────────────────────────
#   outer                outer
#   diag, isSymmetric    diag, is_symmetric
#   all.equal            all_equal_numeric (numerisch)
#
# Seit Etappe 9.6c rechnet SimLev Matrixprodukte, Cholesky, Dreieckslöser, SPD-Löser,
# Eigenwerte und QR/kleinste Quadrate in der C-Bibliothek slc (SimLev.SLib, Entwurf B.5–B.7);
# die Nachbildungen von %*%, crossprod, solve, chol, backsolve, determinant, eigen und qr
# über Referenz-BLAS, LAPACK und LINPACK sind entfallen.
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

export outer, diag, is_symmetric, all_equal_numeric


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

# ── outer ─────────────────────────────────────────────────────────────────


"""
    outer(X, Y, FUN = "*")

`outer(X, Y, FUN)`; FUN "*" (wie R über ein Matrixprodukt mit innerer Länge 1: jedes Element
ist `0 + x[i] * y[j]`, also +0 statt -0), "+", "-", "/", "^" oder eine vektorisierte Funktion
`(xx, yy) -> Vektor`.
"""
function outer(X, Y, FUN = "*")
    mx = _as_r(X); my = _as_r(Y)
    dX = ismat(mx) ? [mx.dim...] : [len(mx)]
    dY = ismat(my) ? [my.dim...] : [len(my)]
    if FUN isa AbstractString && FUN == "*"
        # seit 9.6c ohne die Nachbildung der Referenz-BLAS (bei innerer Länge 1 genau 0 + Produkt)
        xv = Float64.(mx.v); yv = Float64.(my.v)
        flat = vec(0.0 .+ xv .* transpose(yv))
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


# ── Vergleich, Symmetrie ──────────────────────────────────────────────────

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


# ── diag ──────────────────────────────────────────────────────────────────


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
