# RLibm – libm-Funktionen von glibc (statt Julias eigener exp/log/pow), elementweise
#
# Julia rechnet exp, log, log1p, expm1, ^, tanh, sin, … selbst (bzw. über
# openlibm); diese weichen in den letzten Bits von glibc-libm ab, die R
# benutzt. Die Funktionen hier rufen glibc (Linux; macOS libSystem, Windows
# UCRT – dort nicht bitgleich) direkt per `ccall` auf und bilden
# R's Randfälle nach (`R_log`: log(0) = -Inf, log(<0) = NaN; NA/NaN bleiben
# erhalten). Vorlage: python/simlev/_r/libm.py.
#
# Jede Funktion hat eine Skalarvariante (`Real` → `Float64`, Broadcast-fähig:
# `RLibm.exp.(x)`) und eine Vektor-/Matrixvariante (`AbstractArray` → Array
# gleicher Form). `pow`/`atan2` recyceln wie R (Länge 1 oder gleich lang).
module RLibm

import ..SimLev

# Bibliothek je Betriebssystem: an einer Stelle in rnum.jl (`SimLev._LIBM`)
const LIBM = SimLev._LIBM

# ── rohe glibc-Aufrufe (C-Semantik) ─────────────────────────────────────────
for f in (:exp, :log, :log1p, :expm1, :log2, :log10, :sin, :cos, :tan, :tanh, :atanh, :atan,
          :asin, :acos, :sinh, :cosh, :lgamma, :sqrt, :cbrt, :erf, :erfc, :tgamma, :exp2,
          :asinh, :acosh)
    cf = Symbol(:c_, f)
    @eval @inline $cf(x::Float64) = ccall(($(QuoteNode(f)), LIBM), Float64, (Float64,), x)
end
for f in (:pow, :atan2, :fmod, :hypot)
    cf = Symbol(:c_, f)
    @eval @inline $cf(x::Float64, y::Float64) = ccall(($(QuoteNode(f)), LIBM), Float64, (Float64, Float64), x, y)
end
"C `ldexp(x, e)`."
@inline c_ldexp(x::Float64, e::Integer) = ccall((:ldexp, LIBM), Float64, (Float64, Cint), x, Cint(e))
"C `frexp(x)` → (Mantisse, Exponent)."
@inline function c_frexp(x::Float64)
    e = Ref{Cint}(0)
    r = ccall((:frexp, LIBM), Float64, (Float64, Ref{Cint}), x, e)
    return r, Int(e[])
end

# ── Skalarkerne mit R-Randfällen ───────────────────────────────────────────
@inline _exp(x::Float64) = c_exp(x)
@inline _expm1(x::Float64) = c_expm1(x)
@inline _log(x::Float64) = x > 0 ? c_log(x) : x == 0 ? -Inf : isnan(x) ? x : NaN
@inline _log1p(x::Float64) = x > -1 ? c_log1p(x) : x == -1 ? -Inf : isnan(x) ? x : NaN
@inline _log2(x::Float64) = x > 0 ? c_log2(x) : x == 0 ? -Inf : isnan(x) ? x : NaN
@inline _log10(x::Float64) = x > 0 ? c_log10(x) : x == 0 ? -Inf : isnan(x) ? x : NaN
@inline _atanh(x::Float64) = x == 1.0 ? Inf : x == -1.0 ? -Inf : (abs(x) > 1.0 ? NaN : c_atanh(x))
@inline _nanin(f, x::Float64) = (y = f(x); isnan(y) ? (isnan(x) ? x : NaN) : y)
@inline _sin(x::Float64) = _nanin(c_sin, x)
@inline _cos(x::Float64) = _nanin(c_cos, x)
@inline _tan(x::Float64) = _nanin(c_tan, x)
@inline _asin(x::Float64) = _nanin(c_asin, x)
@inline _acos(x::Float64) = _nanin(c_acos, x)
@inline _sinh(x::Float64) = c_sinh(x)
@inline _cosh(x::Float64) = c_cosh(x)
@inline _tanh(x::Float64) = c_tanh(x)
@inline _atan(x::Float64) = c_atan(x)
@inline _lgamma_c(x::Float64) = c_lgamma(x)

# ── Anwendung elementweise ─────────────────────────────────────────────────
"`f` (Skalarfunktion Float64 → Float64) elementweise auf `x` anwenden."
apply1(f, x::Real) = f(Float64(x))
function apply1(f, x::AbstractArray)
    out = Array{Float64}(undef, size(x))
    @inbounds for (i, v) in enumerate(x)
        out[i] = f(Float64(v))
    end
    return out
end
apply1(f, x::Tuple) = apply1(f, collect(x))

"`f(x, y)` elementweise mit R-Recycling (Länge 1 oder gleich)."
apply2(f, x::Real, y::Real) = f(Float64(x), Float64(y))
function apply2(f, x, y)
    a = x isa Real ? Float64[x] : x
    b = y isa Real ? Float64[y] : y
    na, nb = length(a), length(b)
    (na == 0 || nb == 0) && return Float64[]
    n = max(na, nb)
    shp = na >= nb ? (x isa AbstractArray ? size(x) : (n,)) : (y isa AbstractArray ? size(y) : (n,))
    out = Array{Float64}(undef, shp)
    @inbounds for i in 1:n
        out[i] = f(Float64(a[mod1(i, na)]), Float64(b[mod1(i, nb)]))
    end
    return out
end

for (f, k) in ((:exp, :_exp), (:log1p, :_log1p), (:expm1, :_expm1), (:log2, :_log2),
               (:log10, :_log10), (:sin, :_sin), (:cos, :_cos), (:tan, :_tan), (:tanh, :_tanh),
               (:atanh, :_atanh), (:atan, :_atan), (:asin, :_asin), (:acos, :_acos),
               (:sinh, :_sinh), (:cosh, :_cosh), (:lgamma_c, :_lgamma_c))
    @eval $f(x::Real) = $k(Float64(x))
    @eval $f(x::AbstractArray) = apply1($k, x)
end

"""
    log(x[, base])

R's `log(x)` (`R_log`); mit `base` wie R's `logbase`: `base == 10` → `log10`,
`base == 2` → `log2`, sonst `R_log(x) / R_log(base)`.
"""
log(x::Real) = _log(Float64(x))
log(x::AbstractArray) = apply1(_log, x)
function log(x, base::Real)
    base == 10 && return log10(x)
    base == 2 && return log2(x)
    lb = _log(Float64(base))
    return x isa Real ? _log(Float64(x)) / lb : apply1(v -> _log(v) / lb, x)
end
log(x, ::Nothing) = log(x)

"`x ^ y` mit R-Semantik (`R_POW`: `x*x` für `y == 2`, Sonderfälle, sonst glibc `pow`)."
pow(x::Real, y::Real) = SimLev.r_pow(Float64(x), Float64(y))
pow(x, y) = apply2(SimLev.r_pow, x, y)

"`atan2(y, x)` (glibc)."
atan2(y::Real, x::Real) = c_atan2(Float64(y), Float64(x))
atan2(y, x) = apply2(c_atan2, y, x)

end # module
