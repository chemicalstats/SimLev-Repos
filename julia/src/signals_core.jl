# SignalsCore – .roll_mean_core, .roll_cov_core: geteilte C++-Kerne aus core/research_core_impl.h über die
# C-ABI-Hülle (CAbi; bis 1.1.0 Julia-Port). Gegenstück zu python/simlev/_signals_core.py.
module SignalsCore

import ..SimLev
using ..SimLev: NA, CAbi, LIBSLC
using Dates

export roll_mean_core, roll_cov_core, roll_max_core

# Fensterlänge wie R's as.integer für den Kern: außerhalb von Int32 bleibt sie außerhalb von
# 1 … Länge (der Kern liefert dann nur NA), wie python/simlev/_signals_core.py
_n32(n::Integer) = Cint(clamp(Int128(n), typemin(Cint), typemax(Cint)))

"""
    roll_mean_core(x, n)

`.roll_mean_core(x, n)`: rollierender Mittelwert mit kompensierter Summe
(Neumaier); Fenster der Länge `n` einschließlich der aktuellen Zeile, NA für
Fenster mit nicht endlichen Werten. Die Summe wird alle 4096 Schritte neu
aufgebaut.
"""
function roll_mean_core(x::AbstractVector, n::Integer)
    x = Vector{Float64}(x)
    out = Vector{Float64}(undef, length(x))
    CAbi.check(ccall((:simlev_c_roll_mean_core, LIBSLC), Cint, (Ptr{Float64}, Int64, Cint, Ptr{Float64}),
                     x, length(x), _n32(n), out))
    return out
end

"""
    roll_cov_core(x, y, n)

`.roll_cov_core(x, y, n)`: rollierende Kovarianz (Populationsform,
Zwei-Pass) `(Σ dx dy - Σ dx Σ dy / n) / n`; NA, wenn das Fenster einen
nicht endlichen Wert enthält.
"""
function roll_cov_core(x::AbstractVector, y::AbstractVector, n::Integer)
    x = Vector{Float64}(x); y = Vector{Float64}(y)
    out = Vector{Float64}(undef, length(x))
    CAbi.check(ccall((:simlev_c_roll_cov_core, LIBSLC), Cint,
                     (Ptr{Float64}, Int64, Ptr{Float64}, Int64, Cint, Ptr{Float64}),
                     x, length(x), y, length(y), _n32(n), out))
    return out
end

"""
    roll_max_core(x, w)

Gleitendes Maximum über `w >= 1` Zeilen einschließlich der aktuellen (am Anfang kürzer; seit 1.6.3): Kern
`roll_max_core` (core/research_core_impl.h, monotone Schlange, O(m)) mit der Ordnung von Julias `maximum`
(`zero = 1`: −0 < +0); NaN/NA zählen wie −Inf. Gleich `maximum(x[max(1, i - w + 1):i])` je Zeile.
"""
function roll_max_core(x::Vector{Float64}, w::Int)
    out = Vector{Float64}(undef, length(x))
    CAbi.check(ccall((:simlev_c_roll_max_core, LIBSLC), Cint, (Ptr{Float64}, Int64, Int64, Cint, Ptr{Float64}),
                     x, length(x), w, Cint(1), out))
    return out
end

end # module
