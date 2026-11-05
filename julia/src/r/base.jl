# Herkunft:           übersetzt aus R 4.3.3, src/main/summary.c, cum.c, array.c, arithmetic.c;
#                     src/library/stats/src/zeroin.c (R_zeroin2); nachgebildet nach R 4.3.3,
#                     src/library/stats/R/nlm.R (uniroot)
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle); Verfahren R. P. Brent, Algorithms for
#                     Minimization without Derivatives (1973), über Netlib go/fmin.f (ohne Urheber-
#                     und Lizenzvermerk) bzw. c/brent.shar (Kopf nicht geprüft); zeroin.c:
#                     Ergänzungen von Peter Dalgaard
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang: Summen und Kumulationen rechnen die C-Kerne
#                     core/slc_rbase*.
# RBase – Basis-Numerik wie in R (long-double-Akkumulation; über die C-Kerne core/slc_rbase*.cpp)
#
# Bietet die Engine-Hilfen aus `rnum.jl` (`r_sum`, `r_mean`, `r_var`,
# `r_sd`, `r_cumsum`, `r_prod`, `r_rowsums`, `r_pow`,
# `r_mean_int`) auch unter `RBase` an (importiert, ohne `export`; Zugriff als `RBase.r_sd` usw.) und ergänzt
# weitere Funktionen von R's base:
# `colSums`, `colMeans`, `rowSums`, `rowMeans`, `r_cumprod`, `r_cummax`,
# `r_cummin`, `mean`, `pmin`, `pmax` (seit 1.6.1 ohne `r_diff`, `r_range`: nur Referenzfälle).
# Vorlage: python/simlev/_r/base.py; maßgeblich R's `src/main/array.c`
# (do_colsum), `cum.c`, `summary.c` (do_pmin, rmin/rmax).
#
# Eingaben: Vektoren, `RVector` (Namen bleiben erhalten), Matrizen,
# `NamedMat` und `RFrame` (für die Spalten-/Zeilenfunktionen).
module RBase

import ..SimLev
using ..SimLev: RVector, NamedMat, RFrame, NA, isna_strict
using ..SimLev: r_sum, r_mean, r_mean_int, r_var, r_sd, r_cumsum, r_prod, r_rowsums,
                r_pow

# ── Matrizen ────────────────────────────────────────────────────────────────

"→ (Werte n×p als Matrix{Float64}, Zeilennamen, Spaltennamen)."
function _mat(x)
    if x isa RFrame
        n = SimLev.nrow(x)
        cols = getfield(x, :cols)
        m = Matrix{Float64}(undef, n, length(cols))
        for (j, c) in enumerate(cols)
            for i in 1:n
                v = c[i]
                m[i, j] = v === missing ? NA : Float64(v)
            end
        end
        return m, getfield(x, :rownames), copy(getfield(x, :names))
    elseif x isa NamedMat
        return _fmat(x.data), x.rownames, x.colnames
    elseif x isa AbstractMatrix
        return _fmat(x), nothing, nothing
    end
    error("'x' must be an array of at least two dimensions")
end
_fmat(m::AbstractMatrix) = Float64[v === missing ? NA : Float64(v) for v in m]

_named(v::Vector{Float64}, nms) = nms === nothing ? v : RVector(v; names = nms)

# Spalten- und Zeilensummen über den C-Kern (core/slc_rbase.cpp, long double wie R); seit 1.6.1 eine Hülle
function _margins(x, na_rm::Bool, mean::Bool, rows::Bool)
    a, rn, cn = _mat(x)
    return _named(SimLev._rb_margsums(vec(a), size(a, 1), size(a, 2), na_rm, mean, rows), rows ? rn : cn)
end
"`colSums(x, na.rm)` (long double je Spalte)."
colSums(x; na_rm::Bool = false) = _margins(x, na_rm, false, false)
"`colMeans(x, na.rm)` (long-double-Summe / Anzahl)."
colMeans(x; na_rm::Bool = false) = _margins(x, na_rm, true, false)
"`rowSums(x, na.rm)` (spaltenweise in long double akkumuliert)."
rowSums(x; na_rm::Bool = false) = _margins(x, na_rm, false, true)
"`rowMeans(x, na.rm)`."
rowMeans(x; na_rm::Bool = false) = _margins(x, na_rm, true, true)

# ── Vektoren ────────────────────────────────────────────────────────────────

_fl(v) = v === missing ? NA : Float64(v)
"→ (Werte als Vector{Float64} (spaltenweise), Namen)."
_vec(x::RVector) = (Float64[_fl(v) for v in x.values], x.names)
_vec(x::NamedMat) = (Float64[_fl(v) for v in vec(x.data)], nothing)
_vec(x::AbstractArray) = (Float64[_fl(v) for v in vec(x)], nothing)
_vec(x::Real) = (Float64[x], nothing)
_vec(::Missing) = (Float64[NA], nothing)
_vec(::Nothing) = (Float64[], nothing)
_vec(x::Tuple) = _vec(collect(x))

"`cumprod(x)` (long-double-Produkt wie R, NA/NaN über `handleNaN`; C-Kern)."
r_cumprod(x) = ((v, nm) = _vec(x); _named(SimLev._rb_cumprod(v), nm))

"`cummax(x)` (double, `(max > x) ? max : x`; NA/NaN über `handleNaN`; C-Kern)."
r_cummax(x) = ((v, nm) = _vec(x); _named(SimLev._rb_cummax(v), nm))
"`cummin(x)` (C-Kern)."
r_cummin(x) = ((v, nm) = _vec(x); _named(SimLev._rb_cummin(v), nm))

"`mean(x)` auch für Matrizen/data.frames (alle Elemente spaltenweise), Integer wie R."
function mean(x; na_rm::Bool = false)
    if x isa RFrame
        a, _, _ = _mat(x)
        return r_mean(vec(a); na_rm = na_rm)
    end
    xx = x isa RVector ? x.values : x isa NamedMat ? x.data : x
    if (xx isa AbstractArray && eltype(xx) <: Union{Integer,Bool}) || xx isa Integer || xx isa Bool
        return r_mean_int(vec(collect(xx)))
    end
    v, _ = _vec(xx)
    return r_mean(v; na_rm = na_rm)
end

function _pext(args, na_rm::Bool, greater::Bool)
    isempty(args) && error("no arguments")
    vals = [_vec(a) for a in args]
    any(isempty(v) for (v, _) in vals) && return Float64[]
    n = maximum(length(v) for (v, _) in vals)
    first_, nm = vals[1]
    out = Float64[first_[mod1(i, length(first_))] for i in 1:n]
    for (t, _) in vals[2:end]
        nt = length(t)
        @inbounds for i in 1:n
            a = out[i]
            b = t[mod1(i, nt)]
            if (na_rm && isnan(a)) || (greater ? b > a : b < a) || (!na_rm && isnan(b))
                out[i] = b
            end
        end
    end
    if nm !== nothing && length(nm) == n
        return RVector(out; names = nm)
    end
    return out
end

"`pmax(..., na.rm)` mit Recycling; Namen vom ersten Argument."
pmax(args...; na_rm::Bool = false) = _pext(args, na_rm, true)
"`pmin(..., na.rm)`."
pmin(args...; na_rm::Bool = false) = _pext(args, na_rm, false)

end # module
