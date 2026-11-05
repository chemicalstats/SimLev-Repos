# Herkunft:           nachgebildet nach R 4.3.3, src/library/base/R/diag.R, all.equal.R
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang.
# ─────────────────────────────────────────────────────────────────────────────
# RLinalg – lineare Hilfen wie R 4.3.3, die neben der C-Bibliothek slc bleiben
#
#   R                    Julia
#   ───────────────────  ─────────────────────────────────────────────────────
#   diag                 diag
#   all.equal            all_equal_numeric (numerisch)
#
# Seit 1.0.0 rechnet SimLev Matrixprodukte, Cholesky, Dreieckslöser, SPD-Löser,
# Eigenwerte und QR/kleinste Quadrate in der C-Bibliothek slc (SimLev.SLib);
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
import ..RStats: _out, _vec_out, _isint_t   # gleiche Hilfen wie RStats (seit 1.5.2 nur dort)

export diag, all_equal_numeric


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


_rerr(msg) = error(msg)

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
