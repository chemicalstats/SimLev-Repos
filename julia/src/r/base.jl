# RBase – Basis-Numerik wie in R (long-double-Akkumulation über F80)
#
# Re-exportiert die Engine-Hilfen aus `rnum.jl` (`r_sum`, `r_mean`, `r_var`,
# `r_sd`, `r_cumsum`, `r_prod`, `r_rowsums`, `r_pow`, `r_pow_vec`, `r_mod1`,
# `r_mean_int`) und ergänzt weitere Funktionen von R's base:
# `colSums`, `colMeans`, `rowSums`, `rowMeans`, `r_cumprod`, `r_cummax`,
# `r_cummin`, `mean`, `r_diff`, `pmin`, `pmax`, `r_range`.
# Vorlage: python/simlev/_r/base.py; maßgeblich R's `src/main/array.c`
# (do_colsum), `cum.c`, `summary.c` (do_pmin, rmin/rmax).
#
# Eingaben: Vektoren, `RVector` (Namen bleiben erhalten), Matrizen,
# `NamedMat` und `RFrame` (für die Spalten-/Zeilenfunktionen).
module RBase

import ..SimLev
using ..SimLev: F80, RVector, NamedMat, RFrame, NA, isna_strict, _ldq
using ..SimLev: r_sum, r_mean, r_mean_int, r_var, r_sd, r_cumsum, r_prod, r_rowsums,
                r_pow, r_pow_vec, r_mod1

const _LD0 = F80(0.0)
const _LD1 = F80(1.0)

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

# Hardware-Schleife; NaN-Ergebnisse werden mit F80Soft wiederholt (feste x87-
# Regel für zwei NaN, siehe `_HW80` in rnum.jl).
function _col_sums(a::Matrix{Float64}, na_rm::Bool, mean::Bool)
    out = _col_sums(F80, a, na_rm, mean)
    if SimLev._HW80 && any(isnan, out)
        soft = _col_sums(SimLev.F80Soft, a, na_rm, mean)
        @inbounds for j in eachindex(out)
            isnan(out[j]) && (out[j] = soft[j])
        end
    end
    return out
end

function _col_sums(::Type{T}, a::Matrix{Float64}, na_rm::Bool, mean::Bool) where {T}
    n, p = size(a)
    out = Vector{Float64}(undef, p)
    @inbounds for j in 1:p
        s = T(0.0)
        cnt = n
        if na_rm
            cnt = 0
            for i in 1:n
                v = a[i, j]
                if !isnan(v)
                    cnt += 1
                    s = s + T(v)
                end
            end
        else
            for i in 1:n
                s = s + T(a[i, j])
            end
        end
        mean && (s = s / T(cnt))
        out[j] = Float64(s)
    end
    return out
end

"`colSums(x, na.rm)` (long double je Spalte)."
function colSums(x; na_rm::Bool = false)
    a, rn, cn = _mat(x)
    return _named(_col_sums(a, na_rm, false), cn)
end

"`colMeans(x, na.rm)` (long-double-Summe / Anzahl)."
function colMeans(x; na_rm::Bool = false)
    a, rn, cn = _mat(x)
    return _named(_col_sums(a, na_rm, true), cn)
end

function _row_sums(a::Matrix{Float64}, na_rm::Bool, mean::Bool)
    out = _row_sums(F80, a, na_rm, mean)
    if SimLev._HW80 && any(isnan, out)
        soft = _row_sums(SimLev.F80Soft, a, na_rm, mean)
        @inbounds for i in eachindex(out)
            isnan(out[i]) && (out[i] = soft[i])
        end
    end
    return out
end

function _row_sums(::Type{T}, a::Matrix{Float64}, na_rm::Bool, mean::Bool) where {T}
    n, p = size(a)
    acc = fill(T(0.0), n)
    cnt = zeros(Int, n)
    @inbounds for j in 1:p
        for i in 1:n
            v = a[i, j]
            if na_rm
                isnan(v) && continue
                cnt[i] += 1
            end
            acc[i] = acc[i] + T(v)
        end
    end
    out = Vector{Float64}(undef, n)
    @inbounds for i in 1:n
        s = acc[i]
        mean && (s = s / T(na_rm ? cnt[i] : p))
        out[i] = Float64(s)
    end
    return out
end

"`rowSums(x, na.rm)` (spaltenweise in long double akkumuliert)."
function rowSums(x; na_rm::Bool = false)
    a, rn, cn = _mat(x)
    return _named(_row_sums(a, na_rm, false), rn)
end

"`rowMeans(x, na.rm)`."
function rowMeans(x; na_rm::Bool = false)
    a, rn, cn = _mat(x)
    return _named(_row_sums(a, na_rm, true), rn)
end

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

# R's `handleNaN` (cum.c): gemeinsam mit `r_cumsum` in rnum.jl
const _handle_nan! = SimLev._handle_nan!

"`cumprod(x)` (long-double-Produkt wie R's `cum.c`, NA/NaN über `handleNaN`)."
function r_cumprod(x)
    v, nm = _vec(x)
    out = similar(v)
    s = _LD1
    @inbounds for i in eachindex(v)
        s = s * F80(v[i])
        out[i] = Float64(s)
    end
    isnan(Float64(s)) && _handle_nan!(out, v)
    return _named(out, nm)
end

function _cumext(x, greater::Bool)
    v, nm = _vec(x)
    out = similar(v)
    m = greater ? -Inf : Inf
    @inbounds for i in eachindex(v)
        t = v[i]
        if isnan(t)
            _handle_nan!(out, v)
            break
        end
        m = greater ? (m > t ? m : t) : (m < t ? m : t)
        out[i] = m
    end
    return _named(out, nm)
end

"`cummax(x)` (double, `(max > x) ? max : x`; NA/NaN über `handleNaN`)."
r_cummax(x) = _cumext(x, true)
"`cummin(x)`."
r_cummin(x) = _cumext(x, false)
const cummax = r_cummax
const cummin = r_cummin

_isint(x) = x isa Integer || (x isa AbstractArray && eltype(x) <: Union{Integer,Missing} && !(eltype(x) <: Missing))

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
const r_mean_all = mean

"`diff(x, lag, differences)` für Vektoren und Matrizen (zeilenweise)."
function r_diff(x; lag::Integer = 1, differences::Integer = 1)
    if x isa AbstractMatrix || x isa RFrame
        a, rn, cn = _mat(x)
        for _ in 1:differences
            size(a, 1) <= lag && return a[1:0, :]
            a = a[lag+1:end, :] .- a[1:end-lag, :]
        end
        if rn !== nothing || cn !== nothing
            return NamedMat(a; rownames = rn === nothing ? nothing : rn[lag*differences+1:end], colnames = cn)
        end
        return a
    end
    v, nm = _vec(x)
    for _ in 1:differences
        length(v) <= lag && return Float64[]
        v = v[lag+1:end] .- v[1:end-lag]
        nm === nothing || (nm = nm[lag+1:end])
    end
    return _named(v, nm)
end
r_diff(x, lag::Integer, differences::Integer = 1) = r_diff(x; lag = lag, differences = differences)

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
const r_pmax = pmax
const r_pmin = pmin

"`range(..., na.rm, finite)` = `c(min, max)`."
function r_range(args...; na_rm::Bool = false, finite::Bool = false)
    v = isempty(args) ? Float64[] : reduce(vcat, [_vec(a)[1] for a in args])
    if finite
        v = filter(isfinite, v)
    elseif na_rm
        v = filter(!isnan, v)
    else
        if any(isna_strict, v)
            return [NA, NA]
        elseif any(isnan, v)
            return [NaN, NaN]
        end
    end
    if isempty(v)
        @warn "no non-missing arguments to min; returning Inf"
        @warn "no non-missing arguments to max; returning -Inf"
        return [Inf, -Inf]
    end
    lo = v[1]; hi = v[1]
    for t in v
        t < lo && (lo = t)
        t > hi && (hi = t)
    end
    return [lo, hi]
end

end # module
