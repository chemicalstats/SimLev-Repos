# DependenceCore – .kendall_tau_core, .quantile_reg_core, .hmm_em_core, .goal_dp und .pbo_cscv aus
# core/research_core_impl.h (.hmm_forward_backward ohne Aufrufer im Paket entfällt seit 1.6.4): geteilte C++-Kerne
# wie in R und Python über die C-ABI-Hülle core/simlev_cabi.cpp (CAbi). Der frühere Julia-Port (samt der Nachbildung von libstdc++
# `std::sort` und dem NaN-genauen HMM-Weg) ist seit 1.2.0 entfallen, der Port des DCC-Filters seit
# 1.0.0 (den DCC-Filter rechnet die C-Bibliothek slc, SimLev.SLib.dcc_filter). Gegenstück zu
# python/simlev/_dependence_core.py.
module DependenceCore

import ..SimLev
using ..SimLev: CAbi, LIBSLC

export kendall_tau_core, quantile_reg_core, hmm_em, goal_dp, pbo_cscv, QuantileRegError

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

"""
    hmm_em(X, k, mu, S, A, n_iter, tol, ridge)

Baum-Welch-EM aus einem Startwert (R: `.hmm_em_core`, seit 1.5.0): `nothing` bei Fehler, sonst NamedTuple
`(mu, S, A, p0, ll, filtered, smoothed, lB, iter)` (S Vektor von k Matrizen).
"""
function hmm_em(X, k, mu, S, A, n_iter, tol, ridge)
    Xm = _fmat(X); Tn, d = size(Xm); k = Int(k)
    mum = copy(_fmat(mu)); Am = copy(_fmat(A)); rid = _fmat(ridge)
    (size(mum) == (k, d) && size(Am) == (k, k) && size(rid) == (d, d) && length(S) == k) ||
        error("hmm_em: ungültige Abmessungen.")
    Sv = Vector{Float64}(undef, d * d * k)
    for j in 1:k
        Sj = _fmat(S[j]); size(Sj) == (d, d) || error("hmm_em: ungültige Abmessungen.")
        Sv[(j - 1) * d * d + 1:j * d * d] = vec(Sj)
    end
    p0 = Vector{Float64}(undef, k)
    f = Matrix{Float64}(undef, Tn, k); sm = Matrix{Float64}(undef, Tn, k); lB = Matrix{Float64}(undef, Tn, k)
    st = Ref{Int32}(0); ll = Ref{Float64}(0.0); it = Ref{Int64}(0)
    CAbi.check(ccall((:simlev_c_hmm_em, LIBSLC), Cint,
                     (Ptr{Float64}, Int64, Int64, Int64, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Int64,
                      Float64, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Ptr{Float64}, Ptr{Int64}),
                     Xm, Tn, d, k, mum, Sv, Am, p0, Int(n_iter), Float64(tol), rid, f, sm, lB, st, ll, it))
    st[] == 0 || return nothing
    Sl = [reshape(Sv[(j - 1) * d * d + 1:j * d * d], d, d) for j in 1:k]
    return (mu = mum, S = Sl, A = Am, p0 = p0, ll = ll[], filtered = f, smoothed = sm, lB = lB, iter = Int(it[]))
end

"""
    goal_dp(R, grid, cf, goal, wmin, wmax, start_value, tie_score)

Rückwärtsrekursion von `planning_goal()` (R: `.goal_dp`, seit 1.5.0): NamedTuple `(static, policy, value, p_dp,
collapsed)`; `policy` horizon × ng (Int), `value` ng × (horizon + 1), `collapsed` = Zahl der approx-Aufrufe mit
zusammengefassten gleichen log(grid)-Werten.
"""
function goal_dp(R, grid, cf, goal, wmin, wmax, start_value, tie_score)
    Rm = _fmat(R); S, K = size(Rm)
    g = Float64.(collect(grid)); c = Float64.(collect(cf)); tie = Float64.(collect(tie_score))
    ng = length(g); h = length(c)
    (ng >= 2 && h >= 1 && length(tie) == K) || error("goal_dp: ungültige Abmessungen.")
    stat = Vector{Float64}(undef, K); pol = Matrix{Int32}(undef, h, ng); val = Matrix{Float64}(undef, ng, h + 1)
    nc = Ref{Int64}(0); pdp = Ref{Float64}(0.0)
    CAbi.check(ccall((:simlev_c_goal_dp, LIBSLC), Cint,
                     (Ptr{Float64}, Int64, Int64, Ptr{Float64}, Int64, Ptr{Float64}, Int64, Float64, Float64, Float64,
                      Float64, Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Ptr{Int64}),
                     Rm, S, K, g, ng, c, h, Float64(goal), Float64(wmin), Float64(wmax), Float64(start_value), tie, stat,
                     pol, val, pdp, nc))
    nc[] < 0 && error("goal_dp: Fehler der Normalverteilung")
    return (static = stat, policy = Int.(pol), value = val, p_dp = pdp[], collapsed = Int(nc[]))
end

"""
    pbo_cscv(Bs, Ts, combos, half, metric, S, N) -> (lambda, is_best, oos_best, oos_median)

Aufteilungen der CSCV von `overfit_pbo()` (R: `.pbo_cscv`, seit 1.5.0); `Bs` fünf Blocksummen S × N, `Ts` deren
Spaltensummen, `combos` Vektor der Aufteilungen (je S/2 Blöcke, 1-basiert) oder Matrix S/2 × C (`Int32`, seit 1.5.1).
"""
function pbo_cscv(Bs, Ts, combos, half, metric, S, N)
    Bv = reduce(vcat, [vec(_fmat(B)) for B in Bs]); Tv = reduce(vcat, [Float64.(collect(t)) for t in Ts])
    H = S ÷ 2
    if combos isa AbstractMatrix
        size(combos, 1) == H || error("pbo_cscv: ungültige Abmessungen.")
        C = size(combos, 2); cb = combos isa Matrix{Int32} ? vec(combos) : Int32.(vec(combos))
    else
        C = length(combos)
        cb = Vector{Int32}(undef, H * C)
        for (c, cmb) in enumerate(combos), (q, b) in enumerate(cmb)
            cb[(c - 1) * H + q] = Int32(b)
        end
    end
    (length(Bv) == 5 * S * N && length(Tv) == 5 * N) || error("pbo_cscv: ungültige Abmessungen.")
    out = ntuple(_ -> Vector{Float64}(undef, C), 4)
    m = findfirst(==(String(metric)), ["sharpe", "sortino", "geometric", "mean"]) - 1
    CAbi.check(ccall((:simlev_c_pbo_cscv, LIBSLC), Cint,
                     (Ptr{Float64}, Ptr{Float64}, Ptr{Int32}, Int64, Float64, Int64, Int64, Int64, Ptr{Float64},
                      Ptr{Float64}, Ptr{Float64}, Ptr{Float64}),
                     Bv, Tv, cb, C, Float64(half), m, S, N, out[1], out[2], out[3], out[4]))
    return out
end

end # module
