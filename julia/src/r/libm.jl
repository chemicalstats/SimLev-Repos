# Herkunft:           nachgebildet nach R 4.3.3, Randregeln von src/main/arithmetic.c um die
#                     libm-Funktionen
# Rechte:             The R Core Team, teils Robert Gentleman und Ross Ihaka, The R Foundation (laut
#                     Kopf der jeweiligen R-Quelle)
# Lizenz der Vorlage: GPL (>= 2) laut Kopf der R-Quellen; in SimLev unter GPL-3
# Änderungen:         Übertragung nach Python bzw. Julia (Julia nach der Python-Fassung) im von
#                     SimLev genutzten Umfang.
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
# gleicher Form). `pow` recycelt wie R (Länge 1 oder gleich lang).
#
# Seit 1.6.4 (C-094, Entscheidung 80) warnen die Funktionen wie R's `math1`/`math2` einmal je Aufruf mit
# "NaNs produced", wenn ein Ergebnis NaN ist, ohne dass die Eingabe (bei `log(x, base)` keine der beiden) NaN war;
# `pow` warnt wie R's Arithmetik bei Längen, die kein Vielfaches voneinander sind, und wie R's `R_pow` je Element
# `(-Inf)^y` mit endlichem `y > 2^64` (T4-R2). Der Punktaufruf `RLibm.log.(x)`
# rechnet wie ein Aufruf mit dem ganzen Feld (eine Warnung, nicht eine je Element). Ohne Warnung: die Skalarkerne
# `_exp`, `_log`, … und `_logb` (RExpr warnt selbst je Ausdruck).
module RLibm

import ..SimLev

# Bibliothek je Betriebssystem: an einer Stelle in rnum.jl (`SimLev._LIBM`)
const LIBM = SimLev._LIBM

# ── rohe glibc-Aufrufe (C-Semantik) ─────────────────────────────────────────
# (seit 1.6.4 nur die genutzten; atanh, asin, acos, sinh, cosh, lgamma und atan2 ohne Nutzer entfallen wie in Python 1.6.3)
for f in (:exp, :log, :log1p, :expm1, :log2, :log10, :sin, :cos, :tan, :tanh, :atan)
    cf = Symbol(:c_, f)
    @eval @inline $cf(x::Float64) = ccall(($(QuoteNode(f)), LIBM), Float64, (Float64,), x)
end

# ── Skalarkerne mit R-Randfällen ───────────────────────────────────────────
# seit 1.6.4 wie R (C-068, Entscheidung 101): exp/expm1 geben wie math1 ein NaN in x Bit für Bit zurück (auch NA
# 0x7FF0…07A2; bis 1.6.3 von libm still gemacht), log2/log10 wie math2/logbase NA_real_ für NA und R_NaN für jedes
# andere NaN (bis 1.6.3 x selbst, auch -NaN)
@inline _exp(x::Float64) = isnan(x) ? x : c_exp(x)
@inline _expm1(x::Float64) = isnan(x) ? x : c_expm1(x)
@inline _log(x::Float64) = x > 0 ? c_log(x) : x == 0 ? -Inf : isnan(x) ? x : NaN
@inline _log1p(x::Float64) = x > -1 ? c_log1p(x) : x == -1 ? -Inf : isnan(x) ? x : NaN
@inline _nan_lb(x::Float64) = SimLev.isna_strict(x) ? SimLev.NA : NaN
@inline _log2(x::Float64) = x > 0 ? c_log2(x) : x == 0 ? -Inf : _nan_lb(x)
@inline _log10(x::Float64) = x > 0 ? c_log10(x) : x == 0 ? -Inf : _nan_lb(x)
@inline _nanin(f, x::Float64) = (y = f(x); isnan(y) ? (isnan(x) ? x : NaN) : y)
@inline _sin(x::Float64) = _nanin(c_sin, x)
@inline _cos(x::Float64) = _nanin(c_cos, x)
@inline _tan(x::Float64) = _nanin(c_tan, x)
@inline _tanh(x::Float64) = c_tanh(x)
@inline _atan(x::Float64) = c_atan(x)

# ── Anwendung elementweise ─────────────────────────────────────────────────
"R `math1`: \"NaNs produced\", wenn ein Ergebnis NaN ist und die Eingabe nicht (seit 1.6.4, C-094); Ergebnis unverändert."
@inline function _nanw(y::Float64, x::Real, b::Real = 0.0)
    isnan(y) && !isnan(Float64(x)) && !isnan(Float64(b)) && @warn "NaNs produced"
    y
end
function _nanw(out::AbstractArray, x, b::Real = 0.0)
    isnan(Float64(b)) && return out
    @inbounds for (i, v) in zip(eachindex(out), x)
        if isnan(out[i]) && !isnan(Float64(v))
            @warn "NaNs produced"
            break
        end
    end
    out
end

"`f` (Skalarfunktion Float64 → Float64) elementweise auf `x` anwenden."
apply1(f, x::Real) = f(Float64(x))
# Text wie R ablehnen (seit 1.6.4, C-060; bis 1.6.3 MethodError bzw. Zeichencodes)
_istext(x) = x isa AbstractString || x isa AbstractChar ||
             ((x isa AbstractArray || x isa Tuple) && any(t -> t isa AbstractString || t isa AbstractChar, x))
apply1(f, x::Union{AbstractString,AbstractChar}) = error("non-numeric argument to mathematical function")
function apply1(f, x::AbstractArray)
    _istext(x) && error("non-numeric argument to mathematical function")
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
    (_istext(x) || _istext(y)) && error(f === SimLev.r_pow ? "non-numeric argument to binary operator" :
                                        "non-numeric argument to mathematical function")   # seit 1.6.4 wie R (C-060)
    a = x isa Real ? Float64[x] : x
    b = y isa Real ? Float64[y] : y
    na, nb = length(a), length(b)
    # seit 1.6.4 wie R (C-045): ein längerer Vektor als die Matrix ist ein Fehler, zwei Matrizen brauchen gleiche Maße
    (a isa AbstractMatrix && b isa AbstractMatrix && size(a) != size(b)) && error("non-conformable arrays")
    (a isa AbstractMatrix && !(b isa AbstractMatrix) && nb > na && na > 0) &&
        error("dims [product $na] do not match the length of object [$nb]")
    (b isa AbstractMatrix && !(a isa AbstractMatrix) && na > nb && nb > 0) &&
        error("dims [product $nb] do not match the length of object [$na]")
    (na == 0 || nb == 0) && return Float64[]
    n = max(na, nb)
    # seit 1.6.4 wie R's Arithmetik (C-094; apply2 dient nur pow)
    n % min(na, nb) == 0 || @warn "longer object length is not a multiple of shorter object length"
    shp = x isa AbstractMatrix ? size(x) : y isa AbstractMatrix ? size(y) :
          na >= nb ? (x isa AbstractArray ? size(x) : (n,)) : (y isa AbstractArray ? size(y) : (n,))
    out = Array{Float64}(undef, shp)
    nw = 0
    @inbounds for i in 1:n
        xi = Float64(a[mod1(i, na)]); yi = Float64(b[mod1(i, nb)])
        out[i] = f(xi, yi)
        nw += _powloss(xi, yi)
    end
    _powloss_warn(nw)
    return out
end

# R_pow ruft für (-Inf)^y mit ganzem y >= 0 myfmod(y, 2); das warnt je Element bei |y / 2| * LDBL_EPSILON > 1, also
# y > 2^64 (seit 1.6.4, T4-R2; Werte unverändert)
@inline _powloss(x::Float64, y::Float64) = x == -Inf && 1.8446744073709552e19 < y < Inf
function _powloss_warn(n::Integer)
    for _ in 1:n
        @warn "probable complete loss of accuracy in modulus"
    end
end

for (f, k) in ((:exp, :_exp), (:log1p, :_log1p), (:expm1, :_expm1), (:log2, :_log2),
               (:log10, :_log10), (:sin, :_sin), (:cos, :_cos), (:tan, :_tan), (:tanh, :_tanh),
               (:atan, :_atan))
    @eval $f(x::Real) = _nanw($k(Float64(x)), x)
    @eval $f(x::AbstractArray) = _nanw(apply1($k, x), x)
    @eval $f(x::Union{AbstractString,AbstractChar}) = apply1($k, x)   # Text: Fehler wie R (seit 1.6.4, C-060)
end

"""
    log(x[, base])

R's `log(x)` (`R_log`); mit `base` wie R's `logbase`: `base == 10` → `log10`,
`base == 2` → `log2`, sonst `R_log(x) / R_log(base)`.
"""
log(x::Real) = _nanw(_log(Float64(x)), x)
log(x::AbstractArray) = _nanw(apply1(_log, x), x)
log(x::Union{AbstractString,AbstractChar}) = apply1(_log, x)   # Text: Fehler wie R (seit 1.6.4, C-060)
function log(x, base::Real)
    base == 10 && return log10(x)
    base == 2 && return log2(x)
    lb = _log(Float64(base))
    fb = Float64(base)
    # NaN in x oder base nach R's math2 (seit 1.6.4, C-068: NA ergibt NA_real_, sonst R_NaN)
    one(v) = (isnan(v) || isnan(fb)) ? _nan_lb2(v, fb) : _log(v) / lb
    return x isa Real ? _nanw(one(Float64(x)), x, base) : _nanw(apply1(one, x), x, base)
end
log(x, ::Nothing) = log(x)
"Skalar `log(x, b)` wie `log(x, base)`, ohne Warnung (für RExpr; seit 1.6.4)."
_logb(x::Float64, b::Real) = (isnan(x) || isnan(b)) ? _nan_lb2(x, Float64(b)) :
    b == 10 ? _log10(x) : b == 2 ? _log2(x) : _log(x) / _log(Float64(b))
# NaN-Regel von R's math2 (seit 1.6.4, C-068): NA in x oder base ergibt NA_real_, sonst ein NaN R_NaN
_nan_lb2(x::Float64, b::Float64) = (SimLev.isna_strict(x) || SimLev.isna_strict(b)) ? SimLev.NA : NaN

# Punktaufruf mit einem Feld wie ein Aufruf mit dem ganzen Feld (seit 1.6.4, C-094): gleiche Werte je Element, eine
# Warnung je Aufruf wie R
for f in (:exp, :log, :log1p, :expm1, :log2, :log10, :sin, :cos, :tan, :tanh, :atan)
    @eval Base.broadcasted(::typeof($f), x::AbstractArray{<:Real}) = $f(x)
    @eval Base.broadcasted(::typeof($f), x::Base.Broadcast.Broadcasted) = $f(Base.materialize(x))
end

"`x ^ y` mit R-Semantik (`R_POW`: `x*x` für `y == 2`, Sonderfälle, sonst glibc `pow`)."
function pow(x::Real, y::Real)
    fx = Float64(x); fy = Float64(y)
    r = SimLev.r_pow(fx, fy)
    _powloss(fx, fy) && _powloss_warn(1)
    return r
end
pow(x, y) = apply2(SimLev.r_pow, x, y)

end # module
