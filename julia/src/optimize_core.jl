# OptimizeCore – Optimierungskerne aus core/research_core_impl.h (geteilte C++-Kerne, N7)
#
#   proj_box_simplex   exakte Projektion auf {w : sum w = 1, lo <= w <= hi}
#                      (Knickpunkt-Verfahren), `.proj_box_simplex`
#   qp_box_simplex     min 0.5 w'Qw + c'w auf dem beschränkten Simplex
#                      (FISTA mit adaptivem Neustart), `.qp_box_simplex`
#   min_cvar_core      minimaler CVaR (geglättete Rockafellar-Uryasev-
#                      Formulierung, FISTA mit Schrittweitensuche), `.min_cvar_core`
#   min_cdar_core      minimaler CDaR (projizierter Subgradient), `.min_cdar_core`
#
# Es rechnen die geteilten Kerne wie in R und Python über die C-ABI-Hülle core/simlev_cabi.cpp (CAbi).
# Der frühere Julia-Port (F2) samt der Nachbildung von libstdc++ `std::sort`/`std::nth_element` und
# `quantile7` ist mit N7 entfallen. Gegenstück zu python/simlev/_optimize_core.py.
module OptimizeCore

import ..SimLev
using ..SimLev: CAbi, LIBSLC

export proj_box_simplex, qp_box_simplex, min_cvar_core, min_cdar_core

# ── Eingaben ────────────────────────────────────────────────────────────────

_fl(x::Real) = Float64[Float64(x)]
_fl(x::AbstractVector) = Float64[Float64(v) for v in x]
_fl(x::SimLev.RVector) = Float64[Float64(v) for v in x.values]
_fl(x::AbstractMatrix) = Float64[Float64(v) for v in vec(x)]
_fl(x::Tuple) = Float64[Float64(v) for v in x]

_mat(x::SimLev.NamedMat) = Matrix{Float64}(x.data)
_mat(x::AbstractMatrix) = Matrix{Float64}(x)
_mat(x::AbstractVector) = reshape(Float64[Float64(v) for v in x], :, 1)
_mat(x::Real) = fill(Float64(x), 1, 1)

# Schutz vor Zugriffen außerhalb der Felder (Meldungen wie die Python-Hülle)
function _need(v::Vector{Float64}, n::Int, fn::String, name::String)
    length(v) >= n || error("$fn: '$name' ist zu kurz ($(length(v)) statt mindestens $n).")
    return v
end

"""
    proj_box_simplex(v, lo, hi)

`.proj_box_simplex(v, lo, hi)`: euklidische Projektion von `v` auf
{w : sum(w) = 1, lo <= w <= hi}.
"""
function proj_box_simplex(v, lo, hi)
    vv = _fl(v); n = length(vv)
    lo = _need(_fl(lo), n, "proj_box_simplex", "lo"); hi = _need(_fl(hi), n, "proj_box_simplex", "hi")
    out = Vector{Float64}(undef, n)
    CAbi.check(ccall((:simlev_c_proj_box_simplex, LIBSLC), Cint,
                     (Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Int64, Ptr{Float64}), vv, lo, hi, n, out))
    return out
end

"""
    qp_box_simplex(Q, cvec, lo, hi, w0, L, maxit, tol)

`.qp_box_simplex`: FISTA mit adaptivem Neustart für min 0.5 w'Qw + c'w auf
dem beschränkten Simplex; `L` Lipschitz-Konstante (größter Eigenwert von Q).
"""
function qp_box_simplex(Q, cvec, lo, hi, w0, L, maxit, tol)
    Qm = _mat(Q)
    nr, n = size(Qm)
    fn = "qp_box_simplex"
    nr >= n || error("$fn: 'Q' braucht mindestens so viele Zeilen wie Spalten.")
    c = _need(_fl(cvec), n, fn, "cvec"); lo = _need(_fl(lo), n, fn, "lo"); hi = _need(_fl(hi), n, fn, "hi")
    w0 = _need(_fl(w0), n, fn, "w0")
    out = Vector{Float64}(undef, n)
    CAbi.check(ccall((:simlev_c_qp_box_simplex, LIBSLC), Cint,
                     (Ptr{Float64}, Int64, Int64, Ptr{Float64}, Int64, Ptr{Float64}, Int64, Ptr{Float64}, Int64,
                      Ptr{Float64}, Int64, Float64, Int64, Float64, Ptr{Float64}),
                     Qm, nr, n, c, length(c), lo, length(lo), hi, length(hi), w0, length(w0), Float64(L),
                     Int(maxit), Float64(tol), out))
    return out
end

"""
    min_cvar_core(R, alpha, lo, hi, w0, zeta0, scales, maxit)

`.min_cvar_core`: minimaler CVaR der Renditematrix `R` (Zeilen = Perioden)
mit geglätteter Rockafellar-Uryasev-Formulierung; je Glättung aus `scales`
FISTA mit Schrittweitensuche, Start `w0`, `zeta0`.
"""
function min_cvar_core(R, alpha, lo, hi, w0, zeta0, scales, maxit)
    Rm = _mat(R)
    T, N = size(Rm)
    fn = "min_cvar_core"
    lo = _need(_fl(lo), N, fn, "lo"); hi = _need(_fl(hi), N, fn, "hi"); w0 = _need(_fl(w0), N, fn, "w0")
    sc = _fl(scales)
    out = Vector{Float64}(undef, N)
    CAbi.check(ccall((:simlev_c_min_cvar_core, LIBSLC), Cint,
                     (Ptr{Float64}, Int64, Int64, Float64, Ptr{Float64}, Int64, Ptr{Float64}, Int64, Ptr{Float64},
                      Int64, Float64, Ptr{Float64}, Int64, Int64, Ptr{Float64}),
                     Rm, T, N, Float64(alpha), lo, length(lo), hi, length(hi), w0, length(w0), Float64(zeta0),
                     sc, length(sc), Int(maxit), out))
    return out
end

"""
    min_cdar_core(R, alpha, lo, hi, iters)

`.min_cdar_core`: minimaler Conditional Drawdown at Risk (projizierter
Subgradient, bestes Iterat).
"""
function min_cdar_core(R, alpha, lo, hi, iters)
    Rm = _mat(R)
    T, N = size(Rm)
    fn = "min_cdar_core"
    lo = _need(_fl(lo), N, fn, "lo"); hi = _need(_fl(hi), N, fn, "hi")
    out = Vector{Float64}(undef, N)
    CAbi.check(ccall((:simlev_c_min_cdar_core, LIBSLC), Cint,
                     (Ptr{Float64}, Int64, Int64, Float64, Ptr{Float64}, Int64, Ptr{Float64}, Int64, Int64,
                      Ptr{Float64}),
                     Rm, T, N, Float64(alpha), lo, length(lo), hi, length(hi), Int(iters), out))
    return out
end

end # module
