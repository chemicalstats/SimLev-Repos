# ─────────────────────────────────────────────────────────────────────────────
# RTruncnorm – Nachbildung von truncnorm::rtruncnorm (truncnorm 1.0-9), bitgleich
#
# Herkunft: R-Paket truncnorm 1.0-9 (CRAN, 2023-03-20), R/truncnorm.R
# (rtruncnorm) und src/rtruncnorm.c; Autoren: Olaf Mersmann [aut, cre], Heike
# Trautmann [aut], Detlef Steuer [aut], Björn Bornkamp [aut]. Lizenz: GPL (>=
# 2), in SimLev unter GPL-3. Nach Julia übertragen und angepasst für SimLev
# (siehe julia/COPYRIGHTS.md); im R-Paket übernommen als .truncnorm_rtruncnorm
# (r/R/vendor_truncnorm.R, r/src/vendor_truncnorm.c).
#
# Gestutzte Normalverteilung nach src/rtruncnorm.c (Bornkamp, Mersmann): je
# nach Lage der Schranken Normal-, Halbnormal-, Gleichverteilungs- oder
# Exponential-Verwerfungsverfahren (Robert 1995, Schwellen t1 bis t4). Die
# Zufallszahlen kommen wie in R aus SimLev.RRng (runif1, rnorm1, rexp1 über
# unif_rand, norm_rand, exp_rand), dnorm aus SimLev.RNmath, exp und pow aus
# der glibc-libm (der C-Code ruft pow direkt auf, nicht R_pow).
#
# Nachgebildet sind der R-Wrapper (stopifnot der Längen, n als Länge bzw.
# as.integer(n), NULL bei n == 0) und do_rtruncnorm (Recycling auf die größte
# Länge, NA bei b <= a und bei NA/NaN-Schranken).
# Vorlage: python/simlev/_r/truncnorm.py.
# ─────────────────────────────────────────────────────────────────────────────
module RTruncnorm

import ..SimLev
import ..SimLev: NA

export rtruncnorm

const _T1 = 0.15
const _T2 = 2.18
const _T3 = 0.725
const _T4 = 0.45
const _M_1_SQRT_2PI = 0.398942280401432677939946059934
const _DBL_MAX = 1.7976931348623157e308

@inline _cpow2(x::Float64) = SimLev.RLibm.c_pow(x, 2.0)
@inline _cexp(x::Float64) = SimLev.RLibm.c_exp(x)
@inline _dnorm(x::Float64) = SimLev.RNmath.dnorm4(x, 0.0, 1.0, false)
@inline _runif(a, b) = SimLev.RRng.runif1(a, b)
@inline _rnorm01() = SimLev.RRng.rnorm1(0.0, 1.0)

function _ers_a_inf(a::Float64)
    ainv = 1.0 / a
    while true
        x = SimLev.nan_add(SimLev.RRng.rexp1(ainv), a)        # R-Bau: rexp(...) + a
        rho = _cexp(-0.5 * _cpow2(x - a))
        _runif(0.0, 1.0) > rho || return x
    end
end

function _ers_a_b(a::Float64, b::Float64)
    ainv = 1.0 / a
    while true
        x = SimLev.nan_add(SimLev.RRng.rexp1(ainv), a)        # R-Bau: rexp(...) + a
        rho = _cexp(-0.5 * _cpow2(x - a))
        (_runif(0.0, 1.0) > rho || x > b) || return x
    end
end

# ers_a_b(-beta, bmax) bzw. ers_a_inf(-beta) (bmax = nothing) wie im R-Bau: gcc rechnet mit
# beta statt a = -beta (ainv = -1.0 / beta, x = rexp(ainv) - beta; ein NaN in beta behält
# so sein Vorzeichen).
function _ers_neg(beta::Float64, bmax)
    ainv = -1.0 / beta
    while true
        x = SimLev.RRng.rexp1(ainv) - beta
        rho = _cexp(-0.5 * _cpow2(x + beta))
        (_runif(0.0, 1.0) > rho || (bmax !== nothing && x > bmax)) || return x
    end
end

function _nrs_a_b(a::Float64, b::Float64)
    x = -_DBL_MAX
    while x < a || x > b
        x = _rnorm01()
    end
    x
end

function _nrs_a_inf(a::Float64)
    x = -_DBL_MAX
    while x < a
        x = _rnorm01()
    end
    x
end

function _hnrs_a_b(a::Float64, b::Float64)
    x = a - 1.0
    while x < a || x > b
        x = _rnorm01()
        x = abs(x)
    end
    x
end

function _urs_a_b(a::Float64, b::Float64)
    phi_a = _dnorm(a)
    ub = (a < 0 && b > 0) ? _M_1_SQRT_2PI : phi_a
    while true
        x = _runif(a, b)
        _runif(0.0, 1.0) * ub > _dnorm(x) || return x
    end
end

# Rückgaben mean ± sd * x: bei zwei NaN (etwa NA in sd und das NaN von rexp) behält R
# den ersten Operanden der Maschinenanweisung; Folge je Zweig wie im R-Bau (objdump von
# C_truncnorm_rtruncnorm): _sx = (sd * x) + mean, _xs = (x * sd) + mean (wie in Python).
@inline _sx(sd, x, mean) = SimLev.nan_add(SimLev.nan_mul(sd, x), mean)
@inline _xs(x, sd, mean) = SimLev.nan_add(SimLev.nan_mul(x, sd), mean)

function _r_lefttruncnorm(a::Float64, mean::Float64, sd::Float64)
    alpha = (a - mean) / sd
    alpha < _T4 && return _xs(_nrs_a_inf(alpha), sd, mean)
    return _sx(sd, _ers_a_inf(alpha), mean)
end

function _r_righttruncnorm(b::Float64, mean::Float64, sd::Float64)
    # left(-beta, 0, 1) eingesetzt: mean - ((x + 0.0) * sd)
    beta = (b - mean) / sd
    x = -beta < _T4 ? _nrs_a_inf(-beta) : _ers_neg(beta, nothing)
    return mean - SimLev.nan_mul(x + 0.0, sd)
end

function _r_truncnorm(a::Float64, b::Float64, mean::Float64, sd::Float64)
    alpha = (a - mean) / sd
    beta = (b - mean) / sd
    phi_a = _dnorm(alpha)
    phi_b = _dnorm(beta)
    if beta <= alpha
        return NA
    elseif alpha <= 0 && 0 <= beta                    # 2
        (phi_a <= _T1 || phi_b <= _T1) && return _xs(_nrs_a_b(alpha, beta), sd, mean)   # 2 (a)
        return _sx(sd, _urs_a_b(alpha, beta), mean)   # 2 (b)
    elseif alpha > 0                                  # 3
        phi_a / phi_b <= _T2 && return _sx(sd, _urs_a_b(alpha, beta), mean)         # 3 (a)
        alpha < _T3 && return _xs(_hnrs_a_b(alpha, beta), sd, mean)                  # 3 (b)
        return _sx(sd, _ers_a_b(alpha, beta), mean)   # 3 (c)
    else                                              # 3s
        phi_b / phi_a <= _T2 && return mean - SimLev.nan_mul(sd, _urs_a_b(-beta, -alpha))   # 3s (a)
        beta > -_T3 && return mean - SimLev.nan_mul(sd, _hnrs_a_b(-beta, -alpha))            # 3s (b)
        return mean - SimLev.nan_mul(_ers_neg(beta, -alpha), sd)                             # 3s (c)
    end
end

_num(x::Real) = Float64[x]
_num(x::SimLev.RVector) = Float64.(x.values)
_num(x) = Float64[v === missing ? NA : Float64(v) for v in vec(collect(x))]

"""
    rtruncnorm(n, a = -Inf, b = Inf, mean = 0, sd = 1)

`truncnorm::rtruncnorm(n, a, b, mean, sd)`: Zufallszahlen der gestutzten
Normalverteilung. `n` ist eine Zahl (ein Vektor der Länge > 1 zählt über seine
Länge); `a`, `b`, `mean`, `sd` werden wie in R auf die größte Länge recycelt.
Ergebnis: `Vector{Float64}` bzw. `nothing` bei `n == 0`; `NA` für `b <= a`.
"""
function rtruncnorm(n, a_ = -Inf, b_ = Inf, mean_ = 0.0, sd_ = 1.0; a = a_, b = b_, mean = mean_, sd = sd_)
    av = _num(a); bv = _num(b); mv = _num(mean); sv = _num(sd)
    for (v, nm) in ((av, "a"), (bv, "b"), (mv, "mean"), (sv, "sd"))
        isempty(v) && error("length($nm) > 0 is not TRUE")
    end
    if !(n isa Real) && length(n) > 1
        nn_ = length(n)
    else
        x = n isa Real ? n : first(n)
        (x isa Bool || !(x isa Real)) && error("non-numeric argument n.")
        xf = Float64(x)
        isnan(xf) && error("missing value where TRUE/FALSE needed")       # if (n == 0) mit NA
        xf == 0 && return nothing
        if xf >= 2147483648.0 || xf <= -2147483648.0                       # as.integer(n) = NA
            @warn "NAs introduced by coercion to integer range"
            error("n is NA - aborting.")
        end
        nn_ = trunc(Int, xf)
    end
    nn = max(nn_, max(max(length(av), length(bv)), max(length(mv), length(sv))))
    out = Vector{Float64}(undef, max(nn, 0))
    SimLev.RRng._get_state()                                               # GetRNGstate()
    for i in 0:nn-1
        ca = av[i % length(av) + 1]; cb = bv[i % length(bv) + 1]
        cm = mv[i % length(mv) + 1]; cs = sv[i % length(sv) + 1]
        if isfinite(ca) && isfinite(cb)
            out[i+1] = _r_truncnorm(ca, cb, cm, cs)
        elseif ca == -Inf && isfinite(cb)
            out[i+1] = _r_righttruncnorm(cb, cm, cs)
        elseif isfinite(ca) && cb == Inf
            out[i+1] = _r_lefttruncnorm(ca, cm, cs)
        elseif ca == -Inf && cb == Inf
            out[i+1] = SimLev.RRng.rnorm1(cm, cs)
        else
            out[i+1] = NA
        end
    end
    out
end

end # module
