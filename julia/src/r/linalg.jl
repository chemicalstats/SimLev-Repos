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
import ..SimLev: RVector, NamedMat, RFrame, NA, _f64   # _f64: r/rnum.jl (seit 1.6.4)
using Dates
import ..RStats: _isint_t   # gleiche Hilfe wie RStats (seit 1.5.2 nur dort)

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

_rerr(msg) = error(msg)

# ── Vergleich, Symmetrie ──────────────────────────────────────────────────

"Kern von `all.equal.numeric` (ohne Attribute); `true` oder Text."
function all_equal_numeric(target, current; tolerance = 1.4901161193847656e-08)
    # seit 1.6.4 (Befund C-095) wie R: tolerance eine Zahl, NaN bei Unterschieden R's Fehler, Abweichung wie format()
    (tolerance isa Real && !(tolerance isa Bool)) || error("'tolerance' should be numeric")
    t = _as_r(target).v
    c = _as_r(current).v
    length(t) != length(c) && return "Numeric: lengths ($(length(t)), $(length(c))) differ"
    out = isnan.(t)
    if any(out .!= isnan.(c))
        return "'is.NA' value mismatch: $(count(isnan, c)) in current $(count(out)) in target"
    end
    out = out .| (t .== c)
    all(out) && return true
    isnan(Float64(tolerance)) && error("missing value where TRUE/FALSE needed")
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
    (isnan(xy) || xy > tolerance) && return "Mean $what difference: " * SimLev.r_format1(Float64(xy); digits = 7)
    return true
end

# ── diag ──────────────────────────────────────────────────────────────────


"asInteger von R für nrow/ncol: erste Zahl abgeschnitten; NA, nicht lesbarer Text und |x| >= 2^31 ergeben `nothing`."
function _as_integer1(v)
    t = v isa AbstractArray ? (isempty(v) ? nothing : first(v)) : v
    (t === nothing || t === missing) && return nothing
    t isa Bool && return Int(t)
    if t isa AbstractString
        f, bad = SimLev.RExpr._str2num(String(t))
        bad && @warn "NAs introduced by coercion"
    else
        f = Float64(t)
    end
    isnan(f) && return nothing
    if !(-2147483648.0 < f < 2147483648.0)
        @warn "NAs introduced by coercion to integer range"
        return nothing
    end
    return Int(trunc(f))
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
    # seit 1.6.4 wie R (C-044, Entscheidung 97): nrow/ncol wie asInteger mit R's Meldungen, ein leerer Vektor ergibt bei
    # Größe 0 eine 0×0-Matrix (bis 1.6.3 InexactError/ArgumentError bzw. „'x' must have positive length“)
    if (x isa Number || x === missing) && nrow === nothing && ncol === nothing
        n = _as_integer1(x)
        v = [1.0]
    else
        v = _as_r(x).v
        n = length(v)
    end
    nrow !== nothing && (n = _as_integer1(nrow))
    nc = ncol === nothing ? n : _as_integer1(ncol)
    n === nothing && _rerr("invalid 'nrow' value (too large or NA)")
    n < 0 && _rerr("invalid 'nrow' value (< 0)")
    nc === nothing && _rerr("invalid 'ncol' value (too large or NA)")
    nc < 0 && _rerr("invalid 'ncol' value (< 0)")
    (min(n, nc) > 0 && isempty(v)) && _rerr("'x' must have positive length")
    out = zeros(n, nc)
    for i in 1:min(n, nc)
        out[i, i] = v[(i - 1) % length(v) + 1]
    end
    out
end

end # module
