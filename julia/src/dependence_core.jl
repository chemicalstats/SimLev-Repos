# DependenceCore – .kendall_tau_core, .quantile_reg_core und .hmm_forward_backward aus
# core/research_core_impl.h: geteilte C++-Kerne wie in R und Python über die C-ABI-Hülle
# core/simlev_cabi.cpp (CAbi, N7). Der frühere Julia-Port (F2, samt der Nachbildung von libstdc++
# `std::sort` und dem NaN-genauen HMM-Weg) ist mit N7 entfallen; der Port des DCC-Filters schon mit
# Etappe 9.6c (den DCC-Filter rechnet die C-Bibliothek slc, SimLev.SLib.dcc_filter). Gegenstück zu
# python/simlev/_dependence_core.py.
module DependenceCore

import ..SimLev
using ..SimLev: CAbi, LIBSLC

export kendall_tau_core, quantile_reg_core, hmm_forward_backward, QuantileRegError

"Fehler aus dem Quantilsregressions-Kern (Rcpp `stop`)."
struct QuantileRegError <: Exception
    msg::String
end
Base.showerror(io::IO, e::QuantileRegError) = print(io, e.msg)

_fmat(X::SimLev.NamedMat) = Matrix{Float64}(X.data)
_fmat(X::AbstractMatrix) = Matrix{Float64}(X)
_fmat(X::AbstractVector) = reshape(Vector{Float64}(X), :, 1)
_fmat(X::Real) = fill(Float64(X), 1, 1)
_fvec(x::AbstractVector) = Vector{Float64}(x)
_fvec(x::AbstractMatrix) = Vector{Float64}(vec(x isa SimLev.NamedMat ? x.data : x))
_fvec(x::Real) = [Float64(x)]

"`.kendall_tau_core(x, y)`: Kendalls Tau-b in O(n log n); NA bei weniger als zwei Werten oder ohne Streuung."
function kendall_tau_core(x, y)
    x = _fvec(x); y = _fvec(y)
    n = length(x)
    length(y) >= n || error("kendall_tau_core: 'y' muss mindestens die Länge $n haben (erhalten: $(length(y))).")
    out = Ref(0.0)
    CAbi.check(ccall((:simlev_c_kendall_tau_core, LIBSLC), Cint, (Ptr{Float64}, Ptr{Float64}, Int64, Ref{Float64}),
                     x, y, n, out))
    return out[]
end

"""
    quantile_reg_core(y, X, tau, beta0, sc, tol, maxit) -> (beta, optimal)

`.quantile_reg_core`; `optimal` ist `nothing`, wenn `X` keine Spalten hat (wie
das fehlende Attribut in R).
"""
function quantile_reg_core(y, X, tau::Real, beta0, sc::Real, tol::Real, maxit::Integer)
    y = _fvec(y)
    X = _fmat(X)
    size(X, 1) != length(y) && length(y) > 0 && (X = reshape(vec(X), length(y), :))
    n, p = size(X)
    beta = _fvec(beta0)
    p == 0 && return Float64[], nothing
    length(y) >= n || error("quantile_reg_core: 'y' ist zu kurz ($(length(y)) statt mindestens $n).")
    length(beta) >= p || error("quantile_reg_core: 'beta0' ist zu kurz ($(length(beta)) statt mindestens $p).")
    out = Vector{Float64}(undef, p)
    opt = Ref{Cint}(0)
    CAbi.check(ccall((:simlev_c_quantile_reg_core, LIBSLC), Cint,
                     (Ptr{Float64}, Int64, Ptr{Float64}, Int64, Int64, Float64, Ptr{Float64}, Int64, Float64,
                      Float64, Int64, Ptr{Float64}, Ref{Cint}),
                     y, length(y), X, n, p, Float64(tau), beta, length(beta), Float64(sc), Float64(tol), Int(maxit),
                     out, opt), QuantileRegError)
    return out, opt[] == 1
end

"`.hmm_forward_backward(B, A, p0)` → RList `filtered`, `smoothed`, `xi`, `scale`."
function hmm_forward_backward(B, A, p0)
    Bm = _fmat(B); Am = _fmat(A); p0 = _fvec(p0)
    T, K = size(Bm)
    (T >= 1 && size(Am, 1) >= K && size(Am, 2) >= K && length(p0) >= K) ||
        error("hmm_forward_backward: ungültige Abmessungen.")
    al = Matrix{Float64}(undef, T, K); ga = Matrix{Float64}(undef, T, K); xi = Matrix{Float64}(undef, K, K)
    cs = Vector{Float64}(undef, T)
    CAbi.check(ccall((:simlev_c_hmm_forward_backward, LIBSLC), Cint,
                     (Ptr{Float64}, Int64, Int64, Ptr{Float64}, Int64, Int64, Ptr{Float64}, Int64,
                      Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}),
                     Bm, T, K, Am, size(Am, 1), size(Am, 2), p0, length(p0), al, ga, xi, cs))
    SimLev.RList("filtered" => al, "smoothed" => ga, "xi" => xi, "scale" => cs)
end

end # module
