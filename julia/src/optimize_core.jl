# OptimizeCore – Optimierungskerne aus r/src/research_core.cpp
#
#   proj_box_simplex   exakte Projektion auf {w : sum w = 1, lo <= w <= hi}
#                      (Knickpunkt-Verfahren), `.proj_box_simplex`
#   qp_box_simplex     min 0.5 w'Qw + c'w auf dem beschränkten Simplex
#                      (FISTA mit adaptivem Neustart), `.qp_box_simplex`
#   min_cvar_core      minimaler CVaR (geglättete Rockafellar-Uryasev-
#                      Formulierung, FISTA mit Schrittweitensuche), `.min_cvar_core`
#   min_cdar_core      minimaler CDaR (projizierter Subgradient), `.min_cdar_core`
#
# Rechenreihenfolge 1:1 aus dem C++-Code (double-Akkumulation, keine FMA,
# glibc-`exp`/`log1p` über RLibm). `std::sort` (libstdc++-Introsort, nicht
# stabil) wird für die Knickpunkte immer exakt nachgebildet, damit auch
# Gleichstände mit +0/-0 bzw. NaN in derselben Reihenfolge landen wie in R.
module OptimizeCore

import ..SimLev
using Dates

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

# ── libstdc++ std::sort (Introsort, GCC 13) ─────────────────────────────────
# Arbeitet auf `v` mit 0-basierten Positionen (Zugriff v[i + 1]).

# std::pair<double,int>::operator<
@inline _lt(a::Tuple{Float64,Int}, b::Tuple{Float64,Int}) = a[1] < b[1] || (!(b[1] < a[1]) && a[2] < b[2])
# double::operator< (std::nth_element in quantile7)
@inline _lt(a::Float64, b::Float64) = a < b

@inline function _swap!(v, i, j)
    @inbounds v[i+1], v[j+1] = v[j+1], v[i+1]
    nothing
end

function _move_median_to_first!(v, result, a, b, c)
    @inbounds begin
        if _lt(v[a+1], v[b+1])
            if _lt(v[b+1], v[c+1])
                _swap!(v, result, b)
            elseif _lt(v[a+1], v[c+1])
                _swap!(v, result, c)
            else
                _swap!(v, result, a)
            end
        elseif _lt(v[a+1], v[c+1])
            _swap!(v, result, a)
        elseif _lt(v[b+1], v[c+1])
            _swap!(v, result, c)
        else
            _swap!(v, result, b)
        end
    end
    nothing
end

function _unguarded_partition!(v, first, last, pivot)
    @inbounds while true
        while _lt(v[first+1], v[pivot+1])
            first += 1
        end
        last -= 1
        while _lt(v[pivot+1], v[last+1])
            last -= 1
        end
        first < last || return first
        _swap!(v, first, last)
        first += 1
    end
end

function _adjust_heap!(v, first, hole, len, value)
    top = hole
    second = hole
    @inbounds begin
        while second < div(len - 1, 2)
            second = 2 * (second + 1)
            if _lt(v[first+second+1], v[first+second])
                second -= 1
            end
            v[first+hole+1] = v[first+second+1]
            hole = second
        end
        if (len & 1) == 0 && second == div(len - 2, 2)
            second = 2 * (second + 1)
            v[first+hole+1] = v[first+second]
            hole = second - 1
        end
        parent = div(hole - 1, 2)
        while hole > top && _lt(v[first+parent+1], value)
            v[first+hole+1] = v[first+parent+1]
            hole = parent
            parent = div(hole - 1, 2)
        end
        v[first+hole+1] = value
    end
    nothing
end

function _heap_sort!(v, first, last)
    len = last - first
    @inbounds if len >= 2
        parent = div(len - 2, 2)
        while true
            _adjust_heap!(v, first, parent, len, v[first+parent+1])
            parent == 0 && break
            parent -= 1
        end
    end
    @inbounds while last - first > 1
        last -= 1
        value = v[last+1]
        v[last+1] = v[first+1]
        _adjust_heap!(v, first, 0, last - first, value)
    end
    nothing
end

function _introsort_loop!(v, first, last, depth)
    while last - first > 16
        if depth == 0
            _heap_sort!(v, first, last)
            return
        end
        depth -= 1
        mid = first + div(last - first, 2)
        _move_median_to_first!(v, first, first + 1, mid, last - 1)
        cut = _unguarded_partition!(v, first + 1, last, first)
        _introsort_loop!(v, cut, last, depth)
        last = cut
    end
    nothing
end

function _unguarded_linear_insert!(v, last)
    @inbounds begin
        val = v[last+1]
        nxt = last - 1
        while _lt(val, v[nxt+1])
            v[last+1] = v[nxt+1]
            last = nxt
            nxt -= 1
        end
        v[last+1] = val
    end
    nothing
end

function _insertion_sort!(v, first, last)
    first == last && return
    @inbounds for i in (first+1):(last-1)
        if _lt(v[i+1], v[first+1])
            val = v[i+1]
            for j in i:-1:(first+1)
                v[j+1] = v[j]
            end
            v[first+1] = val
        else
            _unguarded_linear_insert!(v, i)
        end
    end
    nothing
end

function _final_insertion_sort!(v, first, last)
    if last - first > 16
        _insertion_sort!(v, first, first + 16)
        for i in (first+16):(last-1)
            _unguarded_linear_insert!(v, i)
        end
    else
        _insertion_sort!(v, first, last)
    end
    nothing
end

function _heap_select!(v, first, middle, last)
    len = middle - first
    @inbounds if len >= 2
        parent = div(len - 2, 2)
        while true
            _adjust_heap!(v, first, parent, len, v[first+parent+1])
            parent == 0 && break
            parent -= 1
        end
    end
    @inbounds for i in middle:(last-1)
        if _lt(v[i+1], v[first+1])
            value = v[i+1]
            v[i+1] = v[first+1]
            _adjust_heap!(v, first, 0, len, value)
        end
    end
    nothing
end

"`std::nth_element` (libstdc++, GCC 13, Introselect) mit 0-basiertem `nth` (in place)."
function _nth_element!(v::Vector{Float64}, nth::Int)
    first = 0
    last = length(v)
    (first == last || nth == last) && return v
    depth = 2 * (8 * sizeof(Int) - 1 - leading_zeros(last - first))
    while last - first > 3
        if depth == 0
            _heap_select!(v, first, nth + 1, last)
            _swap!(v, first, nth)
            return v
        end
        depth -= 1
        mid = first + div(last - first, 2)
        _move_median_to_first!(v, first, first + 1, mid, last - 1)
        cut = _unguarded_partition!(v, first + 1, last, first)
        if cut <= nth
            first = cut
        else
            last = cut
        end
    end
    _insertion_sort!(v, first, last)
    v
end

"`std::sort` (libstdc++) auf einem Vektor von `(double, int)`-Paaren (in place)."
function _std_sort!(v::Vector{Tuple{Float64,Int}})
    n = length(v)
    n < 2 && return v
    depth = 2 * (8 * sizeof(Int) - 1 - leading_zeros(n))
    _introsort_loop!(v, 0, n, depth)
    _final_insertion_sort!(v, 0, n)
    v
end

# ── Projektion ──────────────────────────────────────────────────────────────

"Kern von `proj_box_simplex` (C++ `proj_box_simplex(v, lo, hi, n, out)`)."
function _proj!(out::AbstractVector{Float64}, v::AbstractVector{Float64}, lo::AbstractVector{Float64},
                hi::AbstractVector{Float64}, n::Int)
    slo = 0.0
    shi = 0.0
    @inbounds for i in 1:n
        slo += lo[i]
        shi += hi[i]
    end
    if shi <= 1.0
        @inbounds for i in 1:n
            out[i] = hi[i]
        end
        return out
    end
    if slo >= 1.0
        @inbounds for i in 1:n
            out[i] = lo[i]
        end
        return out
    end
    bp = Vector{Tuple{Float64,Int}}(undef, 2n)
    @inbounds for i in 1:n
        bp[2i-1] = (v[i] - hi[i], 1)
        bp[2i] = (v[i] - lo[i], -1)
    end
    _std_sort!(bp)
    t = bp[1][1]
    g = shi
    t_star = bp[1][1]
    k = 0
    found = false
    @inbounds for j in 1:(2n)
        tn = bp[j][1]
        gn = g - Float64(k) * (tn - t)
        if gn <= 1.0 && k > 0
            t_star = t + (g - 1.0) / Float64(k)
            found = true
            break
        end
        g = gn
        t = tn
        k += bp[j][2]
    end
    found || (t_star = t + (k > 0 ? (g - 1.0) / Float64(k) : 0.0))
    @inbounds for i in 1:n
        x = v[i] - t_star
        # std::max(lo, x): x falls lo < x, sonst lo; std::min(hi, y): y falls y < hi, sonst hi
        y = lo[i] < x ? x : lo[i]
        out[i] = y < hi[i] ? y : hi[i]
    end
    out
end

_proj(v, lo, hi, n) = _proj!(Vector{Float64}(undef, n), v, lo, hi, n)

"""
    proj_box_simplex(v, lo, hi)

`.proj_box_simplex(v, lo, hi)`: euklidische Projektion von `v` auf
{w : sum(w) = 1, lo <= w <= hi}.
"""
function proj_box_simplex(v, lo, hi)
    vv = _fl(v)
    _proj(vv, _fl(lo), _fl(hi), length(vv))
end

# ── Quadratisches Programm ──────────────────────────────────────────────────

"""
    qp_box_simplex(Q, cvec, lo, hi, w0, L, maxit, tol)

`.qp_box_simplex`: FISTA mit adaptivem Neustart für min 0.5 w'Qw + c'w auf
dem beschränkten Simplex; `L` Lipschitz-Konstante (größter Eigenwert von Q).
"""
function qp_box_simplex(Q, cvec, lo, hi, w0, L, maxit, tol)
    Qm = _mat(Q)
    n = size(Qm, 2)
    c = _fl(cvec)
    lo = _fl(lo)
    hi = _fl(hi)
    L = Float64(L)
    tol = Float64(tol)
    maxit = Int(maxit)
    w = _proj(_fl(w0), lo, hi, n)
    y = copy(w)
    wn = zeros(n)
    g = zeros(n)
    tmp = zeros(n)
    t = 1.0
    for _ in 1:maxit
        @inbounds for i in 1:n
            s = c[i]
            for j in 1:n
                s += Qm[i, j] * y[j]
            end
            g[i] = s
            tmp[i] = y[i] - s / L
        end
        _proj!(wn, tmp, lo, hi, n)
        dmax = 0.0
        dir = 0.0
        @inbounds for i in 1:n
            a = abs(wn[i] - w[i])
            dmax = dmax < a ? a : dmax
            dir += g[i] * (wn[i] - w[i])
        end
        if dmax < tol
            copyto!(w, wn)
            break
        end
        if dir > 0.0                       # Neustart
            t = 1.0
            copyto!(y, wn)
            copyto!(w, wn)
            continue
        end
        tn = (1.0 + sqrt(1.0 + 4.0 * t * t)) / 2.0
        mom = (t - 1.0) / tn
        @inbounds for i in 1:n
            y[i] = wn[i] + mom * (wn[i] - w[i])
        end
        copyto!(w, wn)
        t = tn
    end
    w
end

# ── Minimaler CVaR ──────────────────────────────────────────────────────────

@inline _softplus(z::Float64) = z > 30.0 ? z : SimLev.RLibm.log1p(SimLev.RLibm.exp(z))
@inline _logistic(z::Float64) = z >= 0.0 ? 1.0 / (1.0 + SimLev.RLibm.exp(-z)) :
                                SimLev.RLibm.exp(z) / (1.0 + SimLev.RLibm.exp(z))

"""
    min_cvar_core(R, alpha, lo, hi, w0, zeta0, scales, maxit)

`.min_cvar_core`: minimaler CVaR der Renditematrix `R` (Zeilen = Perioden)
mit geglätteter Rockafellar-Uryasev-Formulierung; je Glättung aus `scales`
FISTA mit Schrittweitensuche, Start `w0`, `zeta0`.
"""
function min_cvar_core(R, alpha, lo, hi, w0, zeta0, scales, maxit)
    Rm = _mat(R)
    T, N = size(Rm)
    alpha = Float64(alpha)
    aT = alpha * Float64(T)
    lo = _fl(lo)
    hi = _fl(hi)
    w0 = _fl(w0)
    maxit = Int(maxit)
    x = zeros(N + 1)
    for i in 1:N
        x[i] = w0[i]
    end
    x[N+1] = Float64(zeta0)
    yv = zeros(N + 1); xn = zeros(N + 1); g = zeros(N + 1); tmp = zeros(N + 1)
    loss = zeros(T)
    function port_loss(z)                   # -R w
        fill!(loss, 0.0)
        @inbounds for i in 1:N
            wi = z[i]
            wi == 0.0 && continue
            for s in 1:T
                loss[s] -= Rm[s, i] * wi
            end
        end
    end
    for sc in _fl(scales)
        f = function (z)
            port_loss(z)
            acc = 0.0
            @inbounds for s in 1:T
                acc += _softplus((loss[s] - z[N+1]) / sc)
            end
            z[N+1] + sc * acc / aT
        end
        grad! = function (z, gr)
            port_loss(z)
            fill!(gr, 0.0)
            sp = 0.0
            @inbounds for s in 1:T
                p = _logistic((loss[s] - z[N+1]) / sc)
                loss[s] = p
                sp += p
            end
            @inbounds for i in 1:N
                acc = 0.0
                for s in 1:T
                    acc += Rm[s, i] * loss[s]
                end
                gr[i] = -acc / aT
            end
            gr[N+1] = 1.0 - sp / aT
            gr
        end
        copyto!(yv, x)
        t = 1.0
        L = 1.0 / (alpha * sc)
        for _ in 1:maxit
            grad!(yv, g)
            fy = f(yv)
            L /= 2.0
            for _ls in 1:60
                @inbounds for i in 1:(N+1)
                    tmp[i] = yv[i] - g[i] / L
                end
                _proj!(xn, tmp, lo, hi, N)
                xn[N+1] = tmp[N+1]
                lin = 0.0
                sq = 0.0
                @inbounds for i in 1:(N+1)
                    dx = xn[i] - yv[i]
                    lin += g[i] * dx
                    sq += dx * dx
                end
                f(xn) <= ((fy + lin) + (L / 2.0) * sq) + 1e-15 && break
                L *= 2.0
            end
            dmax = 0.0
            dir = 0.0
            @inbounds for i in 1:(N+1)
                a = abs(xn[i] - x[i])
                dmax = dmax < a ? a : dmax
                dir += g[i] * (xn[i] - x[i])
            end
            if dmax < 1e-9
                copyto!(x, xn)
                break
            end
            if dir > 0.0
                t = 1.0
                copyto!(yv, xn)
                copyto!(x, xn)
                continue
            end
            tn = (1.0 + sqrt(1.0 + 4.0 * t * t)) / 2.0
            mom = (t - 1.0) / tn
            @inbounds for i in 1:(N+1)
                yv[i] = xn[i] + mom * (xn[i] - x[i])
            end
            copyto!(x, xn)
            t = tn
        end
    end
    x[1:N]
end

# ── Minimaler CDaR ──────────────────────────────────────────────────────────

"""
    quantile7(x, p)

Quantil Typ 7 wie `quantile7` in research_core.cpp (`nth_element` +
`min_element`); leere Eingabe → NA.
"""
function quantile7(x::AbstractVector{Float64}, p::Float64)
    n = length(x)
    n == 0 && return SimLev.NA
    h = Float64(n - 1) * p
    lo = Int(floor(h))
    frac = h - Float64(lo)
    if any(isnan, x)
        # NaN (Vergleiche falsch): Ergebnis hängt von der Reihenfolge ab, die
        # std::nth_element herstellt; R-Bau: xl + (xh - xl) * frac
        v = _nth_element!(Vector{Float64}(x), lo)
        xl = v[lo+1]
        (frac == 0.0 || lo + 1 >= n) && return xl
        xh = v[lo+2]
        @inbounds for j in (lo+3):n
            v[j] < xh && (xh = v[j])
        end
        return SimLev.nan_add(xl, (xh - xl) * frac)
    end
    # nth_element/min_element liefern Werte; die Drawdowns sind nie -0, daher genügt Sortieren
    s = Base.sort(x)
    xl = s[lo+1]
    (frac == 0.0 || lo + 1 >= n) && return xl
    xh = s[lo+2]
    xl + frac * (xh - xl)
end

function _cdar_of(r::Vector{Float64}, alpha::Float64, D::Vector{Float64})
    T = length(r)
    c = 0.0
    pk = 0.0
    @inbounds for s in 1:T
        c += r[s]
        pk = pk < c ? c : pk
        D[s] = pk - c
    end
    v = quantile7(D, 1.0 - alpha)
    acc = 0.0
    m = 0
    @inbounds for s in 1:T
        if D[s] >= v
            acc += D[s]
            m += 1
        end
    end
    m > 0 ? acc / Float64(m) : 0.0
end

"""
    min_cdar_core(R, alpha, lo, hi, iters)

`.min_cdar_core`: minimaler Conditional Drawdown at Risk (projizierter
Subgradient, bestes Iterat).
"""
function min_cdar_core(R, alpha, lo, hi, iters)
    Rm = _mat(R)
    T, N = size(Rm)
    alpha = Float64(alpha)
    lo = _fl(lo)
    hi = _fl(hi)
    iters = Int(iters)
    CR = zeros((T + 1) * N)                # Zeile 0 = 0, Index s*N + i (0-basiert)
    sabs = 0.0
    @inbounds for i in 1:N
        c = 0.0
        for s in 1:T
            c += Rm[s, i]
            CR[s*N+i] = c
            sabs += abs(Rm[s, i])
        end
    end
    sc = sabs / (Float64(T) * Float64(N)) * sqrt(Float64(T))
    r = zeros(T); D = zeros(T); C = zeros(T + 1); Dt = zeros(T); g = zeros(N); tmp = zeros(N)
    arg = zeros(Int, T + 1)
    eq = fill(1.0 / Float64(N), N)
    w = _proj(eq, lo, hi, N)
    function port(z)
        @inbounds for s in 1:T
            a = 0.0
            for i in 1:N
                a += Rm[s, i] * z[i]
            end
            r[s] = a
        end
    end
    port(w)
    fbest = _cdar_of(r, alpha, D)
    best = copy(w)
    sqN = sqrt(Float64(N))
    for it in 1:iters
        pk = -Inf
        am = 0
        @inbounds for s in 0:T
            a = 0.0
            for i in 1:N
                a += CR[s*N+i] * w[i]
            end
            C[s+1] = a
            if a >= pk
                pk = a
                am = s
            end
            arg[s+1] = am
            s > 0 && (Dt[s] = pk - a)
        end
        v = quantile7(Dt, 1.0 - alpha)
        fill!(g, 0.0)
        m = 0
        @inbounds for s in 0:(T-1)
            if Dt[s+1] >= v
                ti = s + 1
                pi_ = arg[ti+1]
                for i in 1:N
                    g[i] += CR[pi_*N+i] - CR[ti*N+i]
                end
                m += 1
            end
        end
        gn = 0.0
        @inbounds for i in 1:N
            g[i] /= Float64(m)
            gn += g[i] * g[i]
        end
        den = sqrt(gn) / sqN
        step = 0.5 / (sc * sqrt(Float64(it))) / (1e-12 < den ? den : 1e-12)
        @inbounds for i in 1:N
            tmp[i] = w[i] - step * g[i] / sqN
        end
        _proj!(w, tmp, lo, hi, N)
        port(w)
        f = _cdar_of(r, alpha, D)
        if f < fbest
            fbest = f
            best = copy(w)
        end
    end
    best
end

end # module
